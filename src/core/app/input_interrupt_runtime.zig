const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");

const CancellationTarget = enum {
    none,
    agent_turn,
    context_compaction,
};

fn cancellationTarget(
    stream_active: bool,
    compaction_status: worker_runtime.ContextCompactionStatus,
) CancellationTarget {
    if (stream_active) return .agent_turn;
    return switch (compaction_status) {
        .idle => .none,
        .queued, .running => .context_compaction,
    };
}

test "cancellation target distinguishes agent turns and manual compaction" {
    try std.testing.expectEqual(
        CancellationTarget.none,
        cancellationTarget(false, .idle),
    );
    try std.testing.expectEqual(
        CancellationTarget.agent_turn,
        cancellationTarget(true, .idle),
    );
    try std.testing.expectEqual(
        CancellationTarget.context_compaction,
        cancellationTarget(false, .queued),
    );
    try std.testing.expectEqual(
        CancellationTarget.context_compaction,
        cancellationTarget(false, .running),
    );
    try std.testing.expectEqual(
        CancellationTarget.agent_turn,
        cancellationTarget(true, .running),
    );
}

pub fn InterruptRuntime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn hasActiveOperation(app: *App, agent: *AppAgent) bool {
            if (comptime @hasField(App, "auth")) {
                if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                    if (app.auth.providerPreparationPending()) return true;
                }
            }
            // A setting change that waits for its hooks is active work too (R2.4).
            if (comptime @hasField(App, "hook_gate")) {
                if (app.hook_gate.isPending()) return true;
            }
            // A `/hook test` counts as active work, so Esc and Ctrl-C reach it. Other `/hook` verbs do not.
            if (comptime @hasField(App, "hook_job")) {
                if (app.hook_job.cancelable()) return true;
            }
            return activeCancellationTarget(agent) != .none;
        }

        pub fn dismissCompactionFeedback(app: *App, agent: *AppAgent) bool {
            if (comptime !@hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) return false;
            const observed = agent.worker.compactionActivitySnapshot();
            const op = observed.operation orelse return false;
            if (!op.visible(@import("../shared/io.zig").milliTimestamp())) return false;
            if (!agent.worker.dismissCompactionActivity(op.id, observed.revision)) return false;
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn cancelActiveOperation(app: *App, agent: *AppAgent) !void {
            if (comptime @hasField(App, "auth")) {
                if (comptime @hasDecl(@TypeOf(app.auth), "cancelProviderPreparation")) {
                    if (app.auth.cancelProviderPreparation()) {
                        if (comptime @hasDecl(App, "cancelPendingSubmission")) _ = App.cancelPendingSubmission(app, agent);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                }
            }
            if (comptime @hasField(App, "hook_gate")) {
                if (app.hook_gate.cancel()) {
                    app.shell.render_requests.request(.footer);
                    return;
                }
            }
            if (comptime @hasField(App, "hook_job")) {
                if (app.hook_job.cancel()) {
                    app.shell.render_requests.request(.footer);
                    return;
                }
            }
            if (activeCancellationTarget(agent) == .context_compaction) {
                if (comptime !@hasDecl(
                    @TypeOf(agent.worker),
                    "cancelContextCompaction",
                )) return;
                const cancelled = agent.worker.cancelContextCompaction(
                    std.heap.c_allocator,
                );
                if (!cancelled) return;
                app_worker_runtime.Runtime(App).clearPacer(app, agent, "cancel_compaction");
                if (comptime @hasDecl(App, "playCancelSound")) app.playCancelSound();
                app.shell.render_requests.request(.footer);
                return;
            }
            if (!agent.stream.active) return;
            // Pending approval keeps the stream active until resolution.
            // Avoid duplicate cancellation notices once the worker is cancelled.
            if (turnCancelled(agent)) return;
            const compacting = if (comptime @hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) blk: {
                const observed = agent.worker.compactionActivitySnapshot();
                break :blk if (observed.operation) |op| op.active() else false;
            } else false;
            const tool_active = activeToolStatusCount(app) > 0;
            debug_trace.logf("input", "cancel active operation queued={d}", .{agent.worker.queuedPromptCount()});
            traceInterruptRequested(app, agent, "input_active_stream");
            if (comptime @hasDecl(App, "noteUserStop")) app.noteUserStop(agent);
            if (comptime @hasDecl(@TypeOf(agent.worker), "requestInteractiveCancel")) {
                agent.worker.requestInteractiveCancel();
            } else {
                agent.worker.requestCancel();
            }
            app_worker_runtime.Runtime(App).clearPacer(app, agent, "cancel");
            if (comptime @hasDecl(App, "playCancelSound")) app.playCancelSound();
            if (compacting) {
                app.shell.render_requests.request(.footer);
                return;
            }
            if (tool_active) {
                _ = try shell_runtime.presentActiveToolCancellation(
                    app.alloc,
                    &app.shell,
                );
            } else {
                if (comptime @hasField(App, "metrics")) {
                    try shell_runtime.writeTurnCancellation(
                        app.alloc,
                        &app.shell,
                        &app.metrics,
                        true,
                    );
                }
            }
            if (tool_active) {
                app.shell.render_requests.request(.footer);
                return;
            }
            agent.stream = .{};
            app.shell.render_requests.request(.footer);
        }

        pub fn traceInterruptRequested(app: *App, agent: *AppAgent, source: []const u8) void {
            const approval_active = agent.approval_prompt.isActive();
            const question_active = agent.question_prompt.isActive();
            const tool_status_count = activeToolStatusCount(app);
            const pending_tool_call = approval_active or tool_status_count > 0;
            const running_tool = tool_status_count > 0 and !approval_active and !question_active;
            const active_streamed_text_response = agent.stream.active and !pending_tool_call and !question_active;
            debug_trace.eventf(
                "interrupt",
                "cancel_requested",
                .{},
                "source={s} stream_active={s} active_streamed_text_response={s} pending_tool_call={s} approval_prompt={s} running_tool={s} stream_activity_count={d} last_activity_kind={s}",
                .{
                    source,
                    if (agent.stream.active) "true" else "false",
                    if (active_streamed_text_response) "true" else "false",
                    if (pending_tool_call) "true" else "false",
                    if (approval_active) "true" else "false",
                    if (running_tool) "true" else "false",
                    agent.stream.chunks,
                    if (agent.stream.last_activity_kind) |kind| @tagName(kind) else "none",
                },
            );
        }

        fn activeToolStatusCount(app: *App) usize {
            if (comptime !@hasDecl(@TypeOf(app.shell), "activeToolActivityCount")) {
                return 0;
            }
            return shell_runtime.activeToolActivityCount(&app.shell);
        }

        /// Whether the agent's turn is already cancelled. A steer's
        /// interrupt of the model is not a cancel, so the user's cancel
        /// still stops the turn and its workspace captures.
        fn turnCancelled(agent: *AppAgent) bool {
            if (comptime @hasDecl(@TypeOf(agent.worker), "isTurnCancelRequested")) return agent.worker.isTurnCancelRequested();
            return agent.worker.isCancelRequested();
        }

        fn activeCancellationTarget(agent: *AppAgent) CancellationTarget {
            const status = if (comptime @hasDecl(
                @TypeOf(agent.worker),
                "contextCompactionStatus",
            ))
                agent.worker.contextCompactionStatus()
            else
                worker_runtime.ContextCompactionStatus.idle;
            return cancellationTarget(agent.stream.active, status);
        }
    };
}

test "idle compaction feedback dismissal is scoped and never cancels active work" {
    const FakeApp = struct {
        main_agent: struct {
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},
        shell: struct { render_requests: @import("../../ui/render_request.zig").RenderRequestState = .{} } = .{},

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };
    var app: FakeApp = .{};
    defer app.agent().worker.deinit(std.testing.allocator);
    const id = app.agent().worker.beginCompactionActivity(.manual, null);
    try std.testing.expect(!InterruptRuntime(FakeApp).dismissCompactionFeedback(&app, (&app).agent()));
    app.agent().worker.settleCompactionActivity(id, .{ .outcome = .cancelled });
    try std.testing.expect(InterruptRuntime(FakeApp).dismissCompactionFeedback(&app, (&app).agent()));
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!app.agent().worker.isCancelRequested());
    try std.testing.expect(!InterruptRuntime(FakeApp).dismissCompactionFeedback(&app, (&app).agent()));
}

test "a steer's interrupt of the model leaves the user's cancel to stop the turn" {
    const alloc = std.testing.allocator;
    const FakeApp = struct {
        main_agent: struct {
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };
    var app: FakeApp = .{};
    const worker = &app.agent().worker;
    defer worker.deinit(alloc);
    try std.testing.expect(worker.beginDirectProcessing(41));
    defer worker.finishProcessing();
    try worker.admitInteractivePrompt(alloc, .{
        .prompt = try alloc.dupe(u8, "follow-up"),
        .images = &.{},
        .model = try alloc.dupe(u8, "model"),
        .api_key = try alloc.dupe(u8, "key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(@import("../shared/types.zig").HistoryTurn, 0),
        .grants = try alloc.alloc(@import("../shared/types.zig").PermissionGrant, 0),
    });
    try std.testing.expect(worker.isCancelRequested());
    try std.testing.expect(!InterruptRuntime(FakeApp).turnCancelled((&app).agent()));
    worker.requestInteractiveCancel();
    try std.testing.expect(InterruptRuntime(FakeApp).turnCancelled((&app).agent()));
}

test "a cancel drops the finished turn the pacer held, so a later report is not held" {
    const alloc = std.testing.allocator;
    const types = @import("../shared/types.zig");
    const Prompt = struct {
        fn isActive(_: *const @This()) bool {
            return false;
        }
    };
    const App = struct {
        alloc: std.mem.Allocator,
        main_agent: struct {
            worker: worker_runtime.WorkerRuntime = .{},
            stream: struct { active: bool = false, chunks: usize = 0, last_activity_kind: ?enum { text } = null } = .{},
            approval_prompt: Prompt = .{},
            question_prompt: Prompt = .{},
        } = .{},
        pacer: @import("../../ui/assistant/pacer.zig").AssistantPacer = .{},
        shell: struct {
            render_requests: struct {
                fn request(_: *@This(), _: anytype) void {}
            } = .{},
        } = .{},
    };
    var app: App = .{ .alloc = alloc };
    defer app.pacer.deinit(alloc);
    defer app.main_agent.worker.deinit(alloc);
    const agent = &app.main_agent;
    agent.worker.enableCommitGate();
    agent.stream.active = true;

    // A turn finished. The loop took its finish into the pacer, which is
    // still showing the answer, so nothing has committed it.
    const turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("prompt") }, .assistant = @constCast("answer") } };
    try agent.worker.pushEvent(alloc, .{ .finish_prompt = .{ .turn = turn } });
    var taken = agent.worker.takeEvents();
    for (taken.items) |event| worker_runtime.freeWorkerEvent(alloc, event);
    taken.deinit(alloc);
    try app.pacer.enqueue(alloc, "still showing");
    try std.testing.expect(try app.pacer.deferFinish(alloc, .{ .turn = turn }));
    try std.testing.expectEqual(@as(u32, 1), agent.worker.unacknowledged_finishes);

    // The user cancels. The pacer's turn is dropped, and the worker is told.
    try InterruptRuntime(App).cancelActiveOperation(&app, agent);
    try std.testing.expect(app.pacer.deferred_turn == null);
    try std.testing.expectEqual(@as(u32, 0), agent.worker.unacknowledged_finishes);

    // A later turn finishes and is committed, and a report missed it.
    agent.worker.worker_processing = true;
    agent.worker.active_turn_id = 9;
    agent.worker.direct_steering_closed = true;
    try agent.worker.pushEvent(alloc, .{ .finish_prompt = .{ .turn = turn } });
    try agent.worker.postMail(alloc, .{
        .prompt = try alloc.dupe(u8, "a report"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    });
    agent.worker.finishProcessing();
    agent.worker.acknowledgeFinishCommitted();
    const work = (try agent.worker.tryTakeNextWork(alloc)) orelse return error.TestExpectedReportToStart;
    defer worker_runtime.freeWorkItem(alloc, work);
    try std.testing.expectEqualStrings("a report", work.prompt.prompt);
}

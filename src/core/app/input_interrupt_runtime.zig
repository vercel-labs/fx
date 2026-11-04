const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");

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
            if (activeCancellationTarget(agent) == .context_compaction) {
                if (comptime !@hasDecl(
                    @TypeOf(agent.worker),
                    "cancelContextCompaction",
                )) return;
                const cancelled = agent.worker.cancelContextCompaction(
                    std.heap.c_allocator,
                );
                if (!cancelled) return;
                app.pacer.clear(app.alloc);
                if (comptime @hasDecl(App, "playCancelSound")) app.playCancelSound();
                app.shell.render_requests.request(.footer);
                return;
            }
            if (!agent.stream.active) return;
            // Pending approval keeps the stream active until resolution.
            // Avoid duplicate cancellation notices once the worker is cancelled.
            if (agent.worker.isCancelRequested()) return;
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
            app.pacer.clear(app.alloc);
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

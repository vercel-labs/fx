const std = @import("std");
const session_notices = @import("../session/session.zig");
const agents = @import("../agents/agents.zig");
const credentials = @import("../auth/credentials.zig");
const activity_status = @import("../output/activity_status.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const text_utils = @import("../shared/text_utils.zig");
const shared_theme = @import("../shared/theme.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const ui_render = @import("../../ui/render.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const worker_status = @import("../output/worker_status.zig");
const core_input_runtime = @import("../input/runtime.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const program_status = @import("../../ui/terminal/program_status.zig");

const WorkerEvent = worker_runtime.WorkerEvent;
const InputRuntime = core_input_runtime.Runtime;

const CancelledEventAdmission = enum {
    admit,
    drop,
    defer_until_closure,
};

const reset_style = ui_render.reset_style;

test {
    _ = activity_runtime;
}

fn discardTable(_: *anyopaque, table: assistant_presentation.TablePayload) !void {
    var owned = table;
    owned.deinit(std.heap.c_allocator);
}

fn discardCodeBlock(_: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
    var owned = block;
    owned.deinit(std.heap.c_allocator);
}

fn discardThematicRule(_: *anyopaque) !void {}
fn discardContextCompaction(_: *anyopaque, _: worker_runtime.ContextCompaction) !void {}
fn discardCredentialRefresh(_: *anyopaque, _: credentials.Credential) !void {}

/// A retained delivery owns its own payload; a settled delivery acknowledges history.
pub const HistoryDelivery = union(enum) {
    retained,
    settled: assistant_pacer.FinishResult,
};

pub const WorkerEventHandlers = struct {
    ctx: *anyopaque,
    tool_lifecycle: activity_runtime.LifecyclePresenter,
    write_user_prompt: *const fn (*anyopaque, types.UserTurn) anyerror!void,
    write_user_prompt_with_skill_bindings: ?*const fn (*anyopaque, types.UserTurn, []const worker_runtime.SkillBinding, []const worker_runtime.SkillDisplaySpan) anyerror!void = null,
    append_text: *const fn (*anyopaque, []const u8) anyerror!void,
    append_table: *const fn (*anyopaque, assistant_presentation.TablePayload) anyerror!void = discardTable,
    append_code_block: *const fn (*anyopaque, assistant_presentation.CodeBlockPayload) anyerror!void = discardCodeBlock,
    append_thematic_rule: *const fn (*anyopaque) anyerror!void = discardThematicRule,
    drain_assistant_text: *const fn (*anyopaque) anyerror!AssistantTextDrainResult,
    open_model_picker: *const fn (*anyopaque) anyerror!void,
    semantic_notice: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
    credential_refreshed: *const fn (*anyopaque, credentials.Credential) anyerror!void = discardCredentialRefresh,
    command_output: *const fn (*anyopaque, ?types.ToolLifecycleId, command_output_content.Stream, []const u8) anyerror!void,
    command_output_complete: *const fn (*anyopaque, ?types.ToolLifecycleId) anyerror!void,
    diff_block: *const fn (*anyopaque, diff_mod.DiffEntryPayload) anyerror!void,
    context_compaction: worker_runtime.ContextCompactionHandler = discardContextCompaction,
    append_history_turn: *const fn (*anyopaque, types.FinishedPrompt) anyerror!HistoryDelivery,
    session_grant: *const fn (*anyopaque, types.PermissionGrant) anyerror!void,
    error_text: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
};

pub const AssistantTextDrainResult = enum {
    drained,
    blocked,
};

/// Writes one full-detail record for a terminal route recovery outcome, which
/// preserves the failure in the ctrl+o full transcript's detail section. The
/// recovery module's statuses live only in the status row and refresh every
/// second, so they are never recorded.
fn recordRouteRecoveryNotice(app: anytype, status: types.RouteRecoveryStatus) !void {
    if (status.fromModule() or status.kind == .recovered or status.kind == .failed) return;
    var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer body.deinit();
    try writeRouteRecoveryBody(&body.writer, status);
    try app.shell.appendFullDetailRecord(app.alloc, .{
        .topic = "recovery",
        .tone = routeRecoveryNoticeTone(status),
        .body = body.written(),
        .visibility = .full_only,
    });
}

fn routeRecoveryNoticeTone(status: types.RouteRecoveryStatus) types.NoticeTone {
    return switch (status.tone()) {
        .live => .neutral,
        .warning => .warning,
        .success => .success,
        .danger => .@"error",
    };
}

/// Pure formatter for the recovery record body: footer label, then the
/// structured facts the label cannot carry.
fn writeRouteRecoveryBody(
    writer: *std.Io.Writer,
    status: types.RouteRecoveryStatus,
) !void {
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try writer.writeAll(status.label(&label_buf));
    try writer.print("\nkind: {s}", .{@tagName(status.kind)});
    if (status.cause) |cause| try writer.print(" · cause: {s}", .{@tagName(cause)});
    if (status.attempt > 0) try writer.print(" · attempt: {d}", .{status.attempt});
    if (status.diagnostic) |diagnostic| {
        try writer.print(" · diagnostic: {s}", .{diagnostic.view()});
    }
}

test "shutdown settles queued and pacer-owned finishes exactly once" {
    const session_runtime = @import("../session/session.zig");
    const session_adapter = @import("../session/session_adapter.zig");
    const ShutdownApp = struct {
        alloc: std.mem.Allocator,
        pacer: assistant_pacer.AssistantPacer = .{},
        main_agent: struct {
            total_input_tokens: u64 = 7,
            total_output_tokens: u64 = 11,
            session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
            session_persistence: app_session_runtime.Persistence = .{},
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };
    const Ownership = struct {
        references: usize = 0,
        transfers: usize = 0,

        fn retain(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.references += 1;
        }
        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.references -= 1;
        }
        fn transfer(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.transfers += 1;
        }
        fn handle(self: *@This()) types.SnapshotFileOwnership {
            return .{ .ctx = self, .retain_fn = retain, .release_fn = release, .transfer_fn = transfer };
        }
    };
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |pacer_owned| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        var app: ShutdownApp = .{ .alloc = alloc };
        defer app.agent().session.deinit(alloc);
        defer app.agent().session_persistence.deinit(alloc);
        defer app.agent().worker.deinit(std.heap.c_allocator);
        defer app.pacer.deinit(alloc);
        _ = try app.agent().session_persistence.adoptStore(alloc, try session_adapter.Store.open(alloc, root));
        var model = "test-model".*;
        app.agent().session_persistence.v2 = try session_adapter.Session.create(alloc, app.agent().session_persistence.v2_store.?, root, .app, .{
            .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
            .language = .literal("en"),
            .permission_state = .{},
        });

        var ownership: Ownership = .{};
        const summary: types.TurnSummary = .{ .token_progress = .{ .input_tokens = 7, .output_tokens = 11 } };
        const finished: types.FinishedPrompt = .{
            .turn = .{ .interrupted = .{
                .user = .{ .text = @constCast("cancel this response") },
                .assistant = @constCast("partial response"),
                .terminal_reason = .failed,
            } },
            .summary = summary,
            .terminal_outcome = .interrupted,
            .snapshot_file_ownership = ownership.handle(),
        };
        if (pacer_owned) {
            try app.pacer.enqueue(alloc, "unrendered tail");
            try std.testing.expect(try app.pacer.deferFinish(alloc, finished));
        } else {
            try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = finished });
        }
        // A later queued finish must follow the pacer-owned turn. Neither a
        // begin nor a presentation event may invoke UI or admit another prompt.
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = .{ .text = @constCast("later prompt") } });
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{ .text = @constCast("do not render") } });
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("later prompt") },
            .assistant = @constCast("later answer"),
        } } } });
        app.agent().worker.requestShutdown();
        app_session_runtime.Runtime(ShutdownApp).recordShutdownFailure((&app).agent(), error.PreviousSessionSaveFailed);
        try std.testing.expectEqual(@as(usize, 0), app.agent().session.historyLen());

        try Runtime(ShutdownApp).settleFinishedPromptsForShutdown(&app, (&app).agent());
        try Runtime(ShutdownApp).settleFinishedPromptsForShutdown(&app, (&app).agent());
        try std.testing.expectEqual(@as(usize, 2), app.agent().session.historyLen());
        try std.testing.expectEqual(@as(usize, 1), ownership.transfers);
        try std.testing.expectEqual(@as(usize, 0), ownership.references);
        try std.testing.expectEqual(@as(usize, 0), app.agent().worker.worker_events.items.len);
        try std.testing.expect(app.pacer.deferred_turn == null);
        // Close the session before reloading so only what it saved can pass.
        const id = try alloc.dupe(u8, app.agent().session_persistence.v2.?.id());
        defer alloc.free(id);
        app.agent().session_persistence.v2.?.close();
        app.agent().session_persistence.v2 = null;
        const resumed = try session_adapter.Session.resumeSession(alloc, app.agent().session_persistence.v2_store.?, .{ .id = id }, root, .app);
        defer resumed.close();
        var loaded = try resumed.restore(alloc);
        defer loaded.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), loaded.history.len);
        try std.testing.expectEqualStrings("partial response", loaded.history[0].interrupted.assistant.?);
        try std.testing.expectEqualDeep(summary, types.historyTurnSummary(loaded.history[0]).?);
        try std.testing.expectEqualStrings("later answer", loaded.history[1].assistant.assistant);
    }
}

const DetachedWorkerEventBatch = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(WorkerEvent),
    next_unvisited: usize = 0,

    fn init(
        alloc: std.mem.Allocator,
        events: std.ArrayList(WorkerEvent),
    ) DetachedWorkerEventBatch {
        return .{
            .alloc = alloc,
            .events = events,
        };
    }

    fn claim(self: *DetachedWorkerEventBatch) ?WorkerEvent {
        if (self.next_unvisited >= self.events.items.len) return null;
        const event = self.events.items[self.next_unvisited];
        self.next_unvisited += 1;
        return event;
    }

    fn claimedAndRemaining(self: *const DetachedWorkerEventBatch) []const WorkerEvent {
        std.debug.assert(self.next_unvisited > 0);
        return self.events.items[self.next_unvisited - 1 ..];
    }

    fn markClaimedAndRemainingTransferred(self: *DetachedWorkerEventBatch) void {
        self.next_unvisited = self.events.items.len;
    }

    fn deinit(self: *DetachedWorkerEventBatch) void {
        while (self.next_unvisited < self.events.items.len) : (self.next_unvisited += 1) {
            debug_trace.logf("worker", "undelivered worker event discarded kind={s}", .{@tagName(self.events.items[self.next_unvisited])});
            worker_runtime.freeWorkerEvent(self.alloc, self.events.items[self.next_unvisited]);
        }
        self.events.deinit(self.alloc);
        self.* = undefined;
    }
};

fn batchContainsTerminalClosure(
    events: []const WorkerEvent,
    id: types.ToolLifecycleId,
) bool {
    for (events) |event| {
        const lifecycle = switch (event) {
            .tool_lifecycle => |value| value,
            else => continue,
        };
        switch (lifecycle) {
            .terminal => |terminal| {
                if (terminal.id.turn_id == id.turn_id and
                    std.mem.eql(u8, terminal.id.call_id, id.call_id)) return true;
            },
            .turn_finished => |finished| {
                if (finished.turn_id == id.turn_id) return true;
            },
            .provisional, .authoritative_started, .progress => {},
        }
    }
    return false;
}

fn batchSegmentIsInterrupted(events: []const WorkerEvent, cancelled_turn_id: ?u64) bool {
    var turn_id: ?u64 = null;
    scan: for (events, 0..) |event, index| {
        if (index > 0) switch (event) {
            .begin_prompt, .begin_prompt_with_skill_bindings, .begin_presented_prompt, .begin_resumed_prompt => break :scan,
            else => {},
        };
        switch (event) {
            .begin_presented_prompt, .begin_resumed_prompt => |id| turn_id = id,
            .turn_phase_update => |phase| turn_id = phase.turn_id,
            .tool_lifecycle => |lifecycle| {
                turn_id = switch (lifecycle) {
                    .turn_finished => |finished| return finished.outcome == .interrupted,
                    .provisional => |value| value.id.turn_id,
                    .authoritative_started => |value| value.id.turn_id,
                    .progress => |value| value.id.turn_id,
                    .terminal => |value| value.id.turn_id,
                };
            },
            else => {},
        }
    }
    const cancelled = cancelled_turn_id orelse return false;
    return turn_id == null or turn_id.? == cancelled;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        fn cancelledToolStartAdmission(
            presenter: activity_runtime.LifecyclePresenter,
            id: types.ToolLifecycleId,
            batch_events: []const WorkerEvent,
        ) CancelledEventAdmission {
            if (batchContainsTerminalClosure(batch_events, id)) return .admit;
            if (id.turn_id <= presenter.snapshot().finalized_turn_watermark) return .drop;
            return .defer_until_closure;
        }

        fn cancelledEventAdmission(
            presenter: activity_runtime.LifecyclePresenter,
            event: WorkerEvent,
            batch_events: []const WorkerEvent,
        ) CancelledEventAdmission {
            return switch (event) {
                .assistant_presentation,
                .open_model_picker,
                .semantic_notice,
                .full_detail_record,
                .command_output,
                .turn_token_update,
                .turn_phase_update,
                .diff_block,
                .restore_failed_prompt,
                => .drop,
                .route_recovery_status => .drop,
                .command_output_complete => |lifecycle_id| if (cancelledCommandCompletionMatches(presenter, lifecycle_id))
                    .admit
                else
                    .drop,
                .tool_lifecycle => |lifecycle| switch (lifecycle) {
                    .provisional => |started| cancelledToolStartAdmission(presenter, started.id, batch_events),
                    .authoritative_started => |started| cancelledToolStartAdmission(presenter, started.id, batch_events),
                    .progress => .drop,
                    .terminal => |terminal| if (presenter.record(terminal.id) == null)
                        .drop
                    else
                        .admit,
                    .turn_finished => .admit,
                },
                .begin_prompt,
                .begin_prompt_with_skill_bindings,
                .begin_presented_prompt,
                .begin_resumed_prompt,
                .append_user_feedback,
                .notification,
                .question_requested,
                .clear_route_recovery_status,
                .provider_resolved,
                .api_status_text,
                .context_compaction,
                .credential_refreshed,
                .finish_prompt,
                .session_grant,
                .error_text,
                => .admit,
            };
        }

        fn cancelledCommandCompletionMatches(
            presenter: activity_runtime.LifecyclePresenter,
            lifecycle_id: ?types.ToolLifecycleId,
        ) bool {
            const id = lifecycle_id orelse return false;
            const record = presenter.record(id) orelse return false;
            return record.phase == .terminal and record.activity_kind == .command;
        }

        /// After the worker joins, persist finished turns without presenting output
        /// or admitting work. The pacer owns the finish preceding queued events.
        pub fn settleFinishedPromptsForShutdown(app: *App, agent: *AppAgent) !void {
            try settleDeferredFinish(app, agent);

            var batch = DetachedWorkerEventBatch.init(
                std.heap.c_allocator,
                agent.worker.takeEvents(),
            );
            defer batch.deinit();
            while (batch.claim()) |event| {
                defer worker_runtime.freeWorkerEvent(batch.alloc, event);
                switch (event) {
                    .finish_prompt => |finished| try persistFinishedPrompt(app, agent, finished),
                    else => debug_trace.logf("worker", "shutdown worker event dropped kind={s}", .{@tagName(event)}),
                }
            }
        }

        fn persistFinishedPrompt(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) !void {
            const appended = if (comptime agents.hasAgentField(App, "session"))
                app_session_runtime.Runtime(App).appendFinishedPrompt(app, agent, finished)
            else
                app.appendFinishedPrompt(finished);
            appended catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(agent, err);
                return err;
            };
        }

        fn settleDeferredFinish(app: *App, agent: *AppAgent) !void {
            if (comptime !@hasField(@TypeOf(app.pacer), "deferred_turn")) return;
            if (app.pacer.deferred_turn) |finished| {
                app.pacer.deferred_turn = null;
                app.pacer.deferred_started_ns = null;
                defer types.freeFinishedPrompt(app.alloc, finished);
                try persistFinishedPrompt(app, agent, finished);
            }
        }

        fn preserveFinishedAfterDrainFailure(app: *App, agent: *AppAgent, batch: *DetachedWorkerEventBatch, may_persist: bool) void {
            var can_persist = may_persist;
            if (can_persist) settleDeferredFinish(app, agent) catch {
                can_persist = false;
            };
            while (batch.claim()) |event| {
                defer worker_runtime.freeWorkerEvent(batch.alloc, event);
                switch (event) {
                    .finish_prompt => |finished| {
                        if (can_persist) {
                            persistFinishedPrompt(app, agent, finished) catch {
                                can_persist = false;
                            };
                        } else {
                            debug_trace.logf("worker", "finished turn not persisted after earlier save failure", .{});
                        }
                    },
                    else => debug_trace.logf("worker", "presentation failure discarded worker event kind={s}", .{@tagName(event)}),
                }
            }
        }

        pub fn authorizeInteractiveAdmission(app: *App, agent: *AppAgent) !bool {
            if (comptime @hasDecl(@TypeOf(agent.worker), "interactiveAdmissionSnapshot")) {
                switch (agent.worker.interactiveAdmissionSnapshot()) {
                    .open => return true,
                    .stopped => return false,
                    .finalization_failed => {
                        if (comptime @hasField(App, "should_exit")) {
                            app.should_exit = true;
                        }
                        return error.TurnFinalizationDeliveryFailed;
                    },
                }
            }
            return true;
        }

        pub fn syncQueuedPromptModel(agent: *AppAgent, model: []const u8) !void {
            try agent.worker.syncQueuedPromptModel(std.heap.c_allocator, model);
        }

        pub fn syncQueuedPromptPermissionSnapshot(agent: *AppAgent, snapshot: worker_runtime.PermissionSnapshot) void {
            agent.worker.syncQueuedPromptPermissionSnapshot(snapshot);
        }

        pub fn syncQueuedPromptPermissionState(
            app: *App,
            agent: *AppAgent,
            snapshot: worker_runtime.PermissionSnapshot,
        ) !void {
            try agent.worker.syncQueuedPromptPermissionState(
                std.heap.c_allocator,
                app_permission_runtime.Runtime(App).grantsOf(app, agent),
                snapshot,
            );
        }

        pub fn propagateHistoryTurn(app: *App, agent: *AppAgent, turn: types.HistoryTurn, max_history_turns: usize) !void {
            if (comptime @hasDecl(App, "propagateHistoryTurn")) {
                try app.propagateHistoryTurn(turn);
                return;
            }
            try agent.worker.propagateHistoryTurn(std.heap.c_allocator, turn, max_history_turns);
        }

        pub fn commitContextCompaction(
            agent: *AppAgent,
            summary: types.CompactedSummaryHistoryTurn,
            active_prefix: ?types.AssistantHistoryTurn,
            retained_from: ?types.ContextHistoryCut,
            max_history_turns: usize,
        ) !void {
            if (comptime @hasDecl(@TypeOf(agent.worker), "commitContextCompaction")) {
                try agent.worker.commitContextCompaction(
                    std.heap.c_allocator,
                    summary,
                    active_prefix,
                    retained_from,
                    max_history_turns,
                );
                return;
            }
            return error.ContextCompactionPersistenceUnavailable;
        }

        pub fn propagateGrant(app: *App, agent: *AppAgent, tool_name: []const u8, target_path: []const u8) !void {
            if (comptime @hasDecl(App, "propagateGrant")) {
                try app.propagateGrant(tool_name, target_path);
                return;
            }
            try agent.worker.propagateGrant(std.heap.c_allocator, tool_name, target_path);
        }

        pub fn pushEvent(app: *App, agent: *AppAgent, event: WorkerEvent) !void {
            if (comptime @hasDecl(App, "pushWorkerEvent")) {
                const owned = try worker_runtime.dupeWorkerEvent(std.heap.c_allocator, event);
                errdefer worker_runtime.freeWorkerEvent(std.heap.c_allocator, owned);
                try app.pushWorkerEvent(owned);
                return;
            }
            try agent.worker.pushEvent(std.heap.c_allocator, event);
        }

        pub fn pushOwnedEvent(app: *App, agent: *AppAgent, event: WorkerEvent) !void {
            if (comptime @hasDecl(App, "pushWorkerEvent")) {
                try app.pushWorkerEvent(event);
                return;
            }
            try agent.worker.pushOwnedEvent(std.heap.c_allocator, event);
        }

        pub fn pushText(app: *App, agent: *AppAgent, text: []const u8) !void {
            if (comptime @hasDecl(App, "pushText")) {
                try app.pushText(agent, text);
            } else {
                try pushEvent(app, agent, .{ .assistant_presentation = .{
                    .text = @constCast(text),
                } });
            }
            debug_trace.eventf(
                "worker",
                "assistant_chunk_received",
                .{},
                "chunk_bytes={d}",
                .{text.len},
            );
        }

        pub fn pushTable(app: *App, agent: *AppAgent, table: assistant_presentation.TablePayload) !void {
            try pushEvent(app, agent, .{ .assistant_presentation = .{ .table = table } });
        }

        pub fn pushCodeBlock(app: *App, agent: *AppAgent, block: assistant_presentation.CodeBlockPayload) !void {
            try pushEvent(app, agent, .{ .assistant_presentation = .{ .code_block = block } });
        }

        pub fn pushThematicRule(app: *App, agent: *AppAgent) !void {
            try pushEvent(app, agent, .{ .assistant_presentation = .thematic_rule });
        }

        pub fn pushCommandOutput(
            app: *App,
            agent: *AppAgent,
            lifecycle_id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            chunk: []const u8,
        ) !void {
            if (chunk.len == 0) return;
            if (comptime @hasDecl(App, "pushCommandOutputWithLifecycle")) {
                try app.pushCommandOutputWithLifecycle(lifecycle_id, stream, chunk);
                return;
            }
            if (comptime @hasDecl(App, "pushCommandOutput")) {
                try app.pushCommandOutput(stream, stream.agent(), chunk);
                return;
            }
            try pushEvent(app, agent, .{ .command_output = .{
                .lifecycle_id = lifecycle_id,
                .stream = stream,
                .text = @constCast(chunk),
            } });
        }

        pub fn pushCommandOutputComplete(app: *App, agent: *AppAgent, lifecycle_id: ?types.ToolLifecycleId) !void {
            try pushEvent(app, agent, .{ .command_output_complete = lifecycle_id });
        }

        pub fn pushToolLifecycle(
            app: *App,
            agent: *AppAgent,
            event: types.ToolLifecycleEvent,
        ) !void {
            try pushEvent(app, agent, .{ .tool_lifecycle = event });
        }

        pub fn pushWebSearchProgress(app: *App, agent: *AppAgent, call_id: []const u8, progress: types.WebSearchProgress) !void {
            const turn_id = agent.worker.activeTurnId();
            if (turn_id == 0 or call_id.len == 0) {
                debug_trace.logf(
                    "ui_activity",
                    "web search progress missing active lifecycle identity",
                    .{},
                );
                return;
            }
            const label = try formatWebSearchProgress(std.heap.c_allocator, progress);
            defer std.heap.c_allocator.free(label);
            try pushToolLifecycle(app, agent, .{ .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .text = label,
            } });
        }

        pub fn pushWebFetchProgress(app: *App, agent: *AppAgent, call_id: []const u8, progress: types.WebFetchProgress) !void {
            const turn_id = agent.worker.activeTurnId();
            if (turn_id == 0 or call_id.len == 0) {
                debug_trace.logf(
                    "ui_activity",
                    "web fetch progress missing active lifecycle identity",
                    .{},
                );
                return;
            }
            const label = try formatWebFetchProgress(std.heap.c_allocator, progress);
            defer std.heap.c_allocator.free(label);
            try pushToolLifecycle(app, agent, .{ .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .text = label,
            } });
        }

        pub fn pushSemanticNotice(app: *App, agent: *AppAgent, notice: types.SemanticNotice) !void {
            try pushEvent(app, agent, .{ .semantic_notice = notice });
        }

        pub fn pushDiffBlock(app: *App, agent: *AppAgent, payload: diff_mod.DiffEntryPayload) !void {
            try pushOwnedEvent(app, agent, .{ .diff_block = payload });
        }

        pub fn syncState(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
        ) void {
            const snapshot = agent.worker.snapshotState(app.alloc) catch return;
            defer snapshot.deinit(app.alloc);

            const was_approval_active = agent.approval_prompt.isActive();
            // Every agent's approval comes from its own worker, a subagent's
            // as main's. A subagent's is labeled with its name, on its
            // own screen and when main's screen shows it.
            const in_child = isSubagent(app, agent);
            var pending_request: ?permission_request.PermissionRequest = if (snapshot.pending_permission_request) |*request|
                request.view()
            else
                null;
            if (comptime @hasDecl(App, "subagentDisplayName")) {
                if (in_child) if (pending_request) |*view| {
                    view.origin = .{ .subagent = app.subagentDisplayName(subagentIdOf(app, agent).?) };
                };
            }
            // An approval lent between main and a subagent stays as it is
            // until main gets its own or the subagent stops waiting on it.
            const keep_lent = if (comptime @hasDecl(App, "keepLentApproval"))
                app.keepLentApproval(agent, pending_request)
            else
                false;
            const management_active = if (comptime @hasField(
                @TypeOf(agent.approval_prompt),
                "rule_management",
            ))
                agent.approval_prompt.rule_management != null
            else
                false;
            const approval_changed = if (keep_lent or (management_active and pending_request == null))
                false
            else
                agent.approval_prompt.syncRequest(app.alloc, pending_request) catch false;
            const review_changed = if (comptime @hasDecl(@TypeOf(agent.approval_prompt), "syncReview")) blk: {
                if (keep_lent) break :blk false;
                const review = if (comptime @hasField(@TypeOf(snapshot), "pending_permission_review"))
                    if (snapshot.pending_permission_review) |pending|
                        if (pending_request) |request|
                            if (pending.request_id == request.id) pending.review else null
                        else
                            null
                    else
                        null
                else
                    null;
                break :blk agent.approval_prompt.syncReview(review);
            } else false;
            if (approval_changed and in_child and agent.approval_prompt.isActive()) {
                debug_trace.eventf("host", "approval_requested", .{}, "agent={s}", .{subagentIdOf(app, agent).?});
            }
            // The approval screen shows the agent on screen, so a hidden
            // agent's change leaves it be.
            if (comptime @hasField(App, "approval_screen")) {
                const file_review_changed = review_changed and
                    (pending_request == null or pending_request.?.file != null);
                if ((approval_changed or file_review_changed) and !offScreen(app, agent)) {
                    app.approval_screen.clear();
                }
            }
            if (approval_changed or review_changed) {
                app.shell.render_requests.request(.modal);
            }
            if (!was_approval_active and agent.approval_prompt.isActive()) {
                if (comptime @hasDecl(App, "dispatchAttentionRequired")) {
                    app.dispatchAttentionRequired(snapshot.active_turn_id, .permission);
                }
            }

            // A subagent's question lent to main's prompt is its worker's, not
            // main's; the agents runtime ends it when that worker stops asking.
            const lent_question = if (comptime @hasDecl(App, "questionLentToMain"))
                app.questionLentToMain() and !isSubagent(app, agent)
            else
                false;
            if (agent.question_prompt.isActive() and !lent_question) {
                if (agent.worker.snapshotPendingQuestionBatch(app.alloc) catch return) |question_snapshot| {
                    question_snapshot.deinit(app.alloc);
                } else {
                    agent.question_prompt.discard(app.alloc, "worker_cleared");
                    app.shell.render_requests.request(.modal);
                }
            }

            const modal_active = agent.approval_prompt.isActive() or agent.question_prompt.isActive();
            const worker_events_pending = if (comptime @hasField(@TypeOf(snapshot), "pending_event_count"))
                snapshot.pending_event_count > 0
            else
                false;
            const cancellation_stops_turn = snapshot.cancel_requested and
                !snapshot.cancel_continues_turn;
            const visible_worker_active = agent.stream.active and
                !cancellation_stops_turn and
                (snapshot.processing or
                    worker_events_pending or
                    snapshot.queued_count > 0);
            const awaiting_tool_terminal = snapshot.cancel_requested and
                activeToolStatusCount(presenter) > 0;
            if (!modal_active and
                !visible_worker_active and
                !awaiting_tool_terminal and
                agent.stream.active)
            {
                // The worker can become idle before its final UI events reach
                // this thread. Keep any open command block until the queued
                // turn boundary finalizes it instead of discarding output.
                agent.stream = .{};
                app.shell.render_requests.request(.footer);
            } else if (modal_active and !agent.stream.active) {
                agent.stream.active = true;
                agent.stream.turn_started_ms = io_mod.milliTimestamp();
                app.shell.render_requests.request(.footer);
            }
            // Waiting on an approval or question is not thinking: freeze the
            // elapsed clock for the duration of the wait.
            activity_status.syncWaitingClock(&agent.stream, modal_active, io_mod.milliTimestamp());

            if (comptime @hasField(App, "program_status")) {
                reportProgramStatus(app, agent, !cancellation_stops_turn and
                    (agent.stream.active or snapshot.processing or snapshot.queued_count > 0));
            }
        }

        /// The session id of subagent `agent`, or null for main.
        fn subagentIdOf(app: *App, agent: *AppAgent) ?[]const u8 {
            if (comptime !@hasDecl(App, "subagentIdOf")) return null;
            return app.subagentIdOf(agent);
        }

        /// True when `agent` is a subagent's, on screen or not.
        fn isSubagent(_: *const App, agent: *const AppAgent) bool {
            if (comptime !@hasField(App, "screen_owner")) return false;
            return agent.role == .subagent;
        }

        /// True when `agent` is not the one on screen. What fx shows app-wide,
        /// such as the terminal's program status, follows the agent on screen.
        fn offScreen(app: *const App, agent: *const AppAgent) bool {
            if (comptime !@hasField(App, "agent_on_screen")) return false;
            const on_screen: *const agents.Agent = if (app.agent_on_screen) |child| &child.agent else &app.main_agent;
            return agent != on_screen;
        }

        /// Tells the terminal what the user would see: a decision prompt,
        /// running work, or the result of the last turn.
        fn reportProgramStatus(app: *App, agent: *AppAgent, busy: bool) void {
            if (offScreen(app, agent)) return;
            if (comptime @hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) {
                app.program_status.noteCompaction(agent.worker.compactionActivitySnapshot());
            }
            const activity: program_status.Activity = if (agent.approval_prompt.isActive())
                .{ .blocked = .{
                    .kind = .permission,
                    .message = if (agent.approval_prompt.request) |*request| request.view().label else "",
                } }
            else if (agent.question_prompt.isActive())
                .{ .blocked = .{ .kind = .question, .message = activeQuestionText(app, agent) } }
            else if (busy)
                .working
            else
                .settled;
            const report = app.program_status.update(activity) orelse return;
            debug_trace.logf("program_status", "report activity={s} settled={s}", .{
                @tagName(activity),
                @tagName(app.program_status.settled),
            });
            app.writeProgramStatus(report);
        }

        fn activeQuestionText(_: *const App, agent: *const AppAgent) []const u8 {
            const projection = agent.question_prompt.projection() orelse return "";
            const entry = projection.current_entry orelse return "";
            return entry.question;
        }

        fn noteTurnStarted(app: *App, agent: *AppAgent) void {
            if (offScreen(app, agent)) return;
            if (comptime @hasField(App, "program_status")) app.program_status.noteTurnStarted();
        }

        fn activeToolStatusCount(
            presenter: activity_runtime.LifecyclePresenter,
        ) usize {
            return presenter.snapshot().active_tool_count;
        }

        pub fn tick(
            app: *App,
            agent: *AppAgent,
            event_handlers: WorkerEventHandlers,
        ) !void {
            if (!try authorizeInteractiveAdmission(app, agent)) return;
            try drainEvents(app, agent, event_handlers);
            syncState(app, agent, event_handlers.tool_lifecycle);

            const now_ms = io_mod.milliTimestamp();
            _ = advanceVisibleAnimation(
                app,
                agent,
                event_handlers.tool_lifecycle,
                now_ms,
            );
        }

        fn advanceVisibleAnimation(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
            now_ms: i64,
        ) bool {
            const compaction: @import("../output/compaction_activity.zig").Snapshot = if (comptime @hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) agent.worker.compactionActivitySnapshot() else .{};
            app.shell.render_requests.observeCompactionRevision(compaction.revision);
            if (comptime @hasDecl(@TypeOf(agent.worker), "expireCompactionActivity")) {
                if (compaction.operation) |op| {
                    if (agent.worker.expireCompactionActivity(op.id, compaction.revision, now_ms)) app.shell.render_requests.request(.footer);
                }
            }
            const compaction_active = if (compaction.operation) |op| op.active() and op.visible(now_ms) else false;
            if (!compaction_active and !agent.stream.active and !app.pacer.hasCompletedAssistantPresentationTail()) {
                return false;
            }
            if (agent.approval_prompt.isActive() or
                agent.question_prompt.isActive() or
                !app.shell.shimmer_active)
            {
                return false;
            }

            var label_buf: [256]u8 = undefined;
            _ = activityShimmerLabel(app, agent, presenter, compaction, now_ms, &label_buf) orelse return false;
            const previous_deadline = app.shell.render_requests.animation_next_deadline_ms;
            if (!app.shell.render_requests.requestAnimationDue(now_ms)) return false;
            debug_trace.logf(
                "frame_schedule",
                "animation_due previous_ms={d} now_ms={d} interval_ms={d}",
                .{ previous_deadline, now_ms, render_request.animation_interval_ms },
            );
            return true;
        }

        fn activityShimmerLabel(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
            compaction: @import("../output/compaction_activity.zig").Snapshot,
            now_ms: i64,
            buf: []u8,
        ) ?[]const u8 {
            switch (app.shell.activityProjection()) {
                .turn_thinking => |thinking| if (thinking.tone != .thinking) return null,
                .none, .tool_slot => {},
            }
            switch (activity_status.compactionProjection(buf, compaction, agent.stream, now_ms)) {
                .turn_thinking => |thinking| return if (thinking.tone == .thinking) thinking.label else null,
                .none, .tool_slot => {},
            }
            // Existence guard only: pass no clock so the label skips the counter.
            if (!agent.stream.active and app.pacer.hasCompletedAssistantPresentationTail()) {
                return activity_status.buildTurnLabel(buf, .{ .active = true }, 0);
            }
            if (activity_status.buildTurnLabel(buf, agent.stream, 0)) |label| return label;
            if (agent.stream.last_activity_kind == .ask) return ui_render.ask_activity_label;
            switch (presenter.snapshot().activity) {
                .tool_slot => |slot| return slot.fallback_label,
                .none, .turn_thinking => {},
            }
            return activity_status.buildProgressLabel(buf, agent.stream);
        }

        /// Logs a `host` trace line for one of main's events. Only a worker
        /// the app named logs anything.
        fn traceMainEvent(app: *App, comptime line: []const u8, event: WorkerEvent, reason: ?[]const u8) void {
            if (comptime !@hasField(@TypeOf(agents.screenAgentOf(app).worker), "trace_agent")) return;
            const agent = agents.screenAgentOf(app).worker.trace_agent orelse return;
            if (reason) |why| {
                debug_trace.eventf("host", line, .{}, "agent={s} kind={s} reason={s}", .{ agent, worker_runtime.traceKind(event), why });
            } else {
                debug_trace.eventf("host", line, .{}, "agent={s} kind={s}", .{ agent, worker_runtime.traceKind(event) });
            }
        }

        fn drainEvents(app: *App, agent: *AppAgent, handlers: WorkerEventHandlers) !void {
            errdefer if (comptime @hasDecl(@TypeOf(agent.worker), "failPendingHistoryPublication")) {
                agent.worker.failPendingHistoryPublication(error.HistoryPublicationDeliveryFailed);
            };
            const taken = agent.worker.takeEventBatch();
            var batch = DetachedWorkerEventBatch.init(
                std.heap.c_allocator,
                taken.events,
            );
            app.shell.render_requests.beginFrameAdmissionBlock();
            defer app.shell.render_requests.endFrameAdmissionBlock();

            var lifecycle_cleanup_attempted = false;
            errdefer if (!lifecycle_cleanup_attempted) {
                handlers.tool_lifecycle.finish_batch(app.alloc) catch |err| {
                    debug_trace.logf(
                        "ui_activity",
                        "lifecycle cleanup after drain failure err={s}",
                        .{@errorName(err)},
                    );
                };
            };
            defer batch.deinit();

            var can_persist_finished = true;
            errdefer preserveFinishedAfterDrainFailure(app, agent, &batch, can_persist_finished);

            var interrupted_segment = batchSegmentIsInterrupted(batch.events.items, taken.cancelled_turn_id);
            var first_event = true;

            events: while (batch.claim()) |event| {
                if (!first_event) switch (event) {
                    .begin_prompt, .begin_prompt_with_skill_bindings, .begin_presented_prompt, .begin_resumed_prompt => {
                        interrupted_segment = batchSegmentIsInterrupted(batch.claimedAndRemaining(), taken.cancelled_turn_id);
                    },
                    else => {},
                };
                first_event = false;
                var drain_owns_current = true;
                defer if (drain_owns_current) {
                    worker_runtime.freeWorkerEvent(batch.alloc, event);
                };
                if (interrupted_segment) {
                    switch (cancelledEventAdmission(
                        handlers.tool_lifecycle,
                        event,
                        batch.claimedAndRemaining(),
                    )) {
                        .admit => {},
                        .drop => {
                            debug_trace.logf(
                                "worker",
                                "cancelled worker event dropped kind={s}",
                                .{@tagName(event)},
                            );
                            traceMainEvent(app, "agent_event_dropped", event, "cancelled");
                            continue;
                        },
                        .defer_until_closure => {
                            try retainClaimedEventAndSuffix(
                                agent,
                                &batch,
                                "cancelled_tool_closure_pending",
                            );
                            drain_owns_current = false;
                            break :events;
                        },
                    }
                }

                switch (event) {
                    .begin_prompt => |prompt| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        try handlers.write_user_prompt(handlers.ctx, prompt);
                    },
                    .begin_prompt_with_skill_bindings => |begin| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        if (handlers.write_user_prompt_with_skill_bindings) |write_bound_prompt| {
                            try write_bound_prompt(handlers.ctx, begin.prompt, begin.skill_bindings, begin.skill_display_spans);
                        } else {
                            try handlers.write_user_prompt(handlers.ctx, begin.prompt);
                        }
                    },
                    .begin_presented_prompt => |turn_id| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        if (comptime @hasDecl(App, "acceptPresentedPrompt")) {
                            try App.acceptPresentedPrompt(app, agent, turn_id);
                        } else {
                            return error.PresentedPromptUnsupported;
                        }
                    },
                    .begin_resumed_prompt => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        try handlers.semantic_notice(handlers.ctx, session_notices.resumed_request_notice);
                    },
                    .append_user_feedback => |text| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.write_user_prompt(handlers.ctx, .{ .text = text });
                        if (agent.stream.active and agent.stream.phase != .thinking) {
                            agent.stream.phase = .thinking;
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    .assistant_presentation => |presentation| {
                        if (presentation.requiresTextDrain() and !try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        switch (presentation) {
                            .text => |text| {
                                try handlers.append_text(handlers.ctx, text);
                                debug_trace.eventf(
                                    "worker",
                                    "assistant_chunk_applied",
                                    .{},
                                    "chunk_bytes={d}",
                                    .{text.len},
                                );
                            },
                            .table => |table| {
                                drain_owns_current = false;
                                try handlers.append_table(handlers.ctx, table);
                            },
                            .code_block => |block| {
                                drain_owns_current = false;
                                try handlers.append_code_block(handlers.ctx, block);
                            },
                            .thematic_rule => {
                                drain_owns_current = false;
                                try handlers.append_thematic_rule(handlers.ctx);
                            },
                            .attempt_start => {
                                // Earlier text has shown, so the transcript
                                // ends where this attempt's output begins.
                                if (comptime @hasDecl(@TypeOf(app.shell), "markAssistantAttemptStart")) {
                                    app.shell.markAssistantAttemptStart();
                                }
                            },
                            .attempt_restart => |fallback| {
                                if (!try replaceRestartedAttempt(app)) {
                                    try handlers.append_text(handlers.ctx, fallback);
                                }
                            },
                        }
                        traceMainEvent(app, "agent_event_applied", event, null);
                    },
                    .notification => |notification| {
                        if (comptime @hasDecl(App, "queueNotification")) {
                            app.queueNotification(notification);
                        }
                    },
                    .question_requested => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        const pending_question = agent.worker.snapshotPendingQuestionBatch(app.alloc) catch |err| {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            return err;
                        };
                        if (pending_question) |question_snapshot| {
                            defer question_snapshot.deinit(app.alloc);
                            if (comptime @hasDecl(App, "returnLentQuestion")) {
                                if (!isSubagent(app, agent)) app.returnLentQuestion();
                            }
                            const was_active = agent.question_prompt.isActive();
                            agent.question_prompt.syncFrom(app.alloc, question_snapshot.entries) catch |err| {
                                try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                                drain_owns_current = false;
                                return err;
                            };
                            if (!was_active and agent.question_prompt.isActive()) {
                                app.shell.render_requests.request(.modal);
                                if (comptime @hasDecl(App, "dispatchAttentionRequired")) {
                                    app.dispatchAttentionRequired(
                                        agent.worker.activeTurnId(),
                                        switch (question_snapshot.source) {
                                            .agent_question, .mcp_elicitation => .question,
                                            .route_recovery => .route_recovery,
                                        },
                                    );
                                }
                            }
                        }
                        traceMainEvent(app, "agent_event_applied", event, null);
                    },
                    .open_model_picker => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.open_model_picker(handlers.ctx);
                        app.shell.render_requests.request(.modal);
                    },
                    .semantic_notice => |notice| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.semantic_notice(handlers.ctx, notice);
                    },
                    .full_detail_record => |notice| {
                        try app.shell.appendFullDetailRecord(app.alloc, notice);
                    },
                    .route_recovery_status => |status| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        // The TUI shows nothing for how a request ended,
                        // recovered or failed; the error itself arrives on
                        // its own. The status line returns to normal activity.
                        const was_waiting_for_sign_in = app.shell.worker_status_state().waitsForSignIn();
                        if (status.kind == .recovered or status.kind == .failed) {
                            _ = app.shell.worker_status_state().clear_route_recovery();
                        } else {
                            app.shell.worker_status_state().set_route_recovery(status);
                        }
                        // A request that starts waiting for a sign-in opens it,
                        // once; signing in continues the request. Only the
                        // agent on screen opens it: the sign-in shows on the
                        // screen and continues the request of the agent there.
                        if (!was_waiting_for_sign_in and app.shell.worker_status_state().waitsForSignIn()) {
                            if (comptime @hasDecl(App, "beginRecoverySignIn")) {
                                if (agent == app.screenAgent()) try app.beginRecoverySignIn(agent);
                            }
                        }
                        app.shell.render_requests.request(.footer);
                        try recordRouteRecoveryNotice(app, status);
                        if (comptime agents.hasAgentField(App, "child_run")) app_agents_runtime.Runtime(App).noteChildFailure(app, agent, status);
                    },
                    .clear_route_recovery_status => {
                        if (app.shell.worker_status_state().clear_route_recovery()) {
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    // The serving provider already appears on the ctrl+o
                    // network record; nothing interactive consumes the event
                    // today. The batch drain frees the payload.
                    .provider_resolved => {},
                    .api_status_text => |text| {
                        resetStream(app, agent, false);
                        app.shell.worker_status_state().set_api(text, .danger);
                        app.shell.render_requests.request(.footer);
                    },
                    .credential_refreshed => |credential| {
                        try handlers.credential_refreshed(handlers.ctx, credential);
                    },
                    .command_output => |chunk| {
                        try handlers.command_output(handlers.ctx, chunk.lifecycle_id, chunk.stream, chunk.text);
                    },
                    .command_output_complete => |lifecycle_id| {
                        try handlers.command_output_complete(handlers.ctx, lifecycle_id);
                    },
                    .turn_token_update => |update| {
                        applyTurnTokenProgress(app, agent, update);
                    },
                    .turn_phase_update => |update| {
                        applyTurnPhase(app, agent, update);
                    },
                    .diff_block => |payload| {
                        drain_owns_current = false;
                        try handlers.diff_block(handlers.ctx, payload);
                    },
                    .context_compaction => |value| {
                        if (comptime @hasDecl(@TypeOf(agent.worker), "resolveContextCompaction")) {
                            agent.worker.resolveContextCompaction(
                                std.heap.c_allocator,
                                value,
                                handlers.ctx,
                                handlers.context_compaction,
                            );
                        } else {
                            try handlers.context_compaction(handlers.ctx, value);
                        }
                    },
                    .tool_lifecycle => |lifecycle| {
                        switch (lifecycle) {
                            .provisional, .authoritative_started => {
                                if (!try requireAssistantTextDrain(handlers)) {
                                    try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                                    drain_owns_current = false;
                                    break :events;
                                }
                            },
                            .progress, .terminal, .turn_finished => {},
                        }
                        try applyToolLifecycle(app, agent, handlers.tool_lifecycle, lifecycle);
                    },
                    .finish_prompt => |finished| {
                        var accepted = false;
                        errdefer if (!accepted) {
                            settleDeferredFinish(app, agent) catch {
                                can_persist_finished = false;
                            };
                            if (can_persist_finished) persistFinishedPrompt(app, agent, finished) catch {
                                can_persist_finished = false;
                            };
                        };
                        try flushPendingCommandOutputAtTurnBoundary(app, handlers);
                        resetStream(app, agent, false);
                        app.shell.render_requests.request(.footer);
                        const delivery = try handlers.append_history_turn(handlers.ctx, finished);
                        accepted = true;
                        switch (delivery) {
                            .retained => {},
                            .settled => |result| switch (result) {
                                .committed => {},
                                .presentation_failed => |err| return err,
                            },
                        }
                    },
                    .session_grant => |grant| {
                        try handlers.session_grant(handlers.ctx, grant);
                    },
                    .error_text => |notice| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, false);
                        if (comptime @hasField(App, "program_status")) {
                            if (notice.tone == .@"error" and !offScreen(app, agent)) app.program_status.noteFailure();
                        }
                        app.shell.render_requests.request(.footer);
                        try handlers.error_text(handlers.ctx, notice);
                    },
                    .restore_failed_prompt => |prompt| {
                        // Never clobber a draft the user typed while the doomed
                        // turn was still retrying; only an empty composer gets
                        // the failed prompt back.
                        if (app.input_runtime.edit_state.input.items.len == 0) {
                            try app.input_runtime.textReplacementState().replace(app.alloc, prompt);
                            app.shell.render_requests.request(.footer);
                        } else {
                            debug_trace.logf(
                                "worker",
                                "event=restore_failed_prompt_skipped reason=composer_occupied",
                                .{},
                            );
                        }
                    },
                }
            }

            lifecycle_cleanup_attempted = true;
            try handlers.tool_lifecycle.finish_batch(app.alloc);
        }

        /// Replaces what the TUI showed of an answer attempt that restarts:
        /// the transcript gives back what the attempt added, and its unshown
        /// text is dropped, so the new answer streams in its place. Returns
        /// false, changing nothing, when part of the attempt is final.
        fn replaceRestartedAttempt(app: *App) !bool {
            if (comptime !@hasDecl(@TypeOf(app.shell), "discardAssistantAttempt")) return false;
            if (!try app.shell.discardAssistantAttempt(app.alloc)) return false;
            if (comptime @hasField(App, "pacer")) app.pacer.discardPendingText();
            debug_trace.logf("worker", "restarted answer replaces the broken-off attempt", .{});
            return true;
        }

        fn flushPendingCommandOutputAtTurnBoundary(
            app: *App,
            handlers: WorkerEventHandlers,
        ) !void {
            const Shell = @TypeOf(app.shell);
            if (comptime !@hasDecl(Shell, "openCommandOutputLifecycleId")) return;
            const lifecycle_id = app.shell.openCommandOutputLifecycleId() orelse return;
            debug_trace.logf(
                "command_output",
                "finalizing open command output at turn boundary",
                .{},
            );
            try handlers.command_output_complete(handlers.ctx, lifecycle_id);
        }

        fn requireAssistantTextDrain(handlers: WorkerEventHandlers) !bool {
            return switch (try handlers.drain_assistant_text(handlers.ctx)) {
                .drained => true,
                .blocked => false,
            };
        }

        fn retainClaimedEventAndSuffix(
            agent: *AppAgent,
            batch: *DetachedWorkerEventBatch,
            reason: []const u8,
        ) !void {
            const retained = batch.claimedAndRemaining();
            try agent.worker.prependOwnedEvents(batch.alloc, retained);
            batch.markClaimedAndRemainingTransferred();
            debug_trace.logf(
                "worker",
                "retained detached worker events reason={s} count={d}",
                .{ reason, retained.len },
            );
        }

        fn applyToolLifecycle(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
            lifecycle: types.ToolLifecycleEvent,
        ) !void {
            const tool_work_active = switch (lifecycle) {
                .provisional, .authoritative_started, .progress => true,
                .terminal, .turn_finished => false,
            };
            const transition = try presenter.apply(
                app.alloc,
                lifecycle,
            );
            if (comptime @hasField(App, "program_status")) {
                if (lifecycle == .turn_finished and !offScreen(app, agent)) app.program_status.noteTurnFinished(lifecycle.turn_finished.outcome);
            }
            if (comptime agents.hasAgentField(App, "child_run")) {
                if (lifecycle == .turn_finished) app_agents_runtime.Runtime(App).noteChildTurnFinished(app, agent, lifecycle.turn_finished.outcome);
            }
            if (transition.applied_activity_kind) |kind| {
                applyToolActivity(&agent.stream, kind);
            }
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                switch (lifecycle) {
                    .terminal => {
                        if (transition.terminal_record) |record| {
                            app_session_runtime.Runtime(App).recordToolTerminal(
                                app,
                                agent,
                                lifecycle,
                                record.captured_command,
                            );
                        }
                    },
                    .provisional, .authoritative_started, .progress, .turn_finished => {},
                }
            }

            const focused_activity_kind = transition.snapshot.focused_activity_kind;
            if (tool_work_active) agent.stream.phase = .running;
            agent.stream.last_activity_kind = focused_activity_kind;
            if (transition.focus_changed()) {
                app.shell.render_requests.requestAnimationReset();
            }
            app.shell.render_requests.request(.footer);
        }

        fn resetStream(app: *App, agent: *AppAgent, clear_route_recovery: bool) void {
            agent.stream = .{};
            if (clear_route_recovery and app.shell.worker_status_state().clear()) {
                app.shell.render_requests.request(.footer);
            }
            app.shell.resetCommandOutputDisplay(app.alloc, "worker inactive");
        }

        fn applyToolActivity(stream: *types.StreamState, kind: types.ToolActivityKind) void {
            stream.chunks += 1;
            stream.last_activity_kind = kind;
            switch (kind) {
                .read => stream.read_count += 1,
                .list => stream.list_count += 1,
                .write => stream.write_count += 1,
                .edit => stream.edit_count += 1,
                .open => stream.open_count += 1,
                .command => stream.command_count += 1,
                .subagent => stream.subagent_count += 1,
                .mcp => stream.mcp_count += 1,
                .ask => {},
            }
        }

        fn applyTurnTokenProgress(app: *App, agent: *AppAgent, update: types.TurnTokenProgress) void {
            if (!agent.stream.active) return;

            const changed = !std.meta.eql(agent.stream.token_progress, update);
            agent.stream.token_progress = update;

            // An armed animation tick already repaints the label within 50ms.
            const animation_armed = app.shell.render_requests.animation_visible and
                app.shell.render_requests.animation_next_deadline_ms != 0;
            if (changed and !animation_armed) app.shell.render_requests.request(.footer);
        }

        fn applyTurnPhase(app: *App, agent: *AppAgent, update: types.TurnPhaseUpdate) void {
            if (!agent.stream.active or update.turn_id != agent.worker.activeTurnId()) return;
            if (update.step_id < agent.stream.phase_step_id) return;

            const changed = agent.stream.phase != update.phase;
            agent.stream.phase = update.phase;
            agent.stream.phase_step_id = update.step_id;
            if (changed) app.shell.render_requests.request(.footer);
        }
    };
}

fn formatWebSearchProgress(alloc: std.mem.Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| alloc.print(
            "● Searching\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&query_buf, query, 120) },
        ),
        .results_received => |entry| alloc.print(
            "● Found {d} result{s}\x1b[0m {s}{s}\x1b[0m",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

fn formatWebFetchProgress(alloc: std.mem.Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| alloc.print(
            "● Fetching\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&url_buf, url, 120) },
        ),
        .converting => |url| alloc.print(
            "● Converting\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&url_buf, url, 120) },
        ),
    };
}

test "core.app_worker_runtime web progress labels keep the non-bold status style" {
    const alloc = std.testing.allocator;
    const searching = try formatWebSearchProgress(alloc, .{ .query_started = @constCast("zig terminal") });
    defer alloc.free(searching);
    const results = try formatWebSearchProgress(alloc, .{ .results_received = .{
        .query = @constCast("zig terminal"),
        .result_count = 2,
    } });
    defer alloc.free(results);
    const fetching = try formatWebFetchProgress(alloc, .{ .fetching = @constCast("https://example.com") });
    defer alloc.free(fetching);
    const converting = try formatWebFetchProgress(alloc, .{ .converting = @constCast("https://example.com") });
    defer alloc.free(converting);
    const cases = [_][]u8{
        searching,
        results,
        fetching,
        converting,
    };

    for (cases) |label| {
        try std.testing.expect(std.mem.find(u8, label, "\x1b[1m") == null);
    }
    try std.testing.expectEqualStrings(
        "● Searching\x1b[0m \x1b[38;5;245mzig terminal\x1b[0m",
        cases[0],
    );
    try std.testing.expectEqualStrings(
        "● Found 2 results\x1b[0m \x1b[38;5;245mzig terminal\x1b[0m",
        cases[1],
    );
    try std.testing.expectEqualStrings(
        "● Fetching\x1b[0m \x1b[38;5;245mhttps://example.com\x1b[0m",
        cases[2],
    );
    try std.testing.expectEqualStrings(
        "● Converting\x1b[0m \x1b[38;5;245mhttps://example.com\x1b[0m",
        cases[3],
    );
}

const FakeSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    cancel_requested: bool = false,
    cancel_continues_turn: bool = false,
    pending_permission_request: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?worker_runtime.PendingPermissionReview = null,

    fn deinit(self: FakeSnapshot, alloc: std.mem.Allocator) void {
        if (self.pending_permission_request) |request| {
            var owned = request;
            owned.deinit(alloc);
        }
    }
};

const FakeQuestionSnapshot = struct {
    entries: []const u8 = "",
    source: worker_runtime.QuestionPromptSource = .agent_question,

    fn deinit(self: FakeQuestionSnapshot, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

const FakeWorker = struct {
    compaction: @import("../output/compaction_activity.zig").State = .{},
    compaction_reads: usize = 0,

    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WorkerEvent) = .empty,
    queued_count: usize = 0,
    processing: bool = false,
    cancel_continues_turn: bool = false,
    pending_permission_request: ?permission_request.PermissionRequest = null,
    pending_permission_review: ?*const diff_mod.FileReview = null,
    pending_question: bool = false,
    pending_question_source: worker_runtime.QuestionPromptSource = .agent_question,
    active_turn_id: u64 = 1,
    propagated_history_turns: usize = 0,
    propagated_grants: usize = 0,
    reset_cancel_after_take_events: bool = false,
    admission_snapshot: worker_runtime.InteractiveAdmissionSnapshot = .open,

    pub fn compactionActivitySnapshot(self: *FakeWorker) @import("../output/compaction_activity.zig").Snapshot {
        self.compaction_reads += 1;
        return self.compaction.snapshot;
    }

    pub fn expireCompactionActivity(self: *FakeWorker, id: @import("../output/compaction_activity.zig").OperationId, revision: u64, now_ms: i64) bool {
        return self.compaction.expire(id, revision, now_ms);
    }

    fn deinit(self: *FakeWorker) void {
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        self.events.deinit(std.heap.c_allocator);
    }

    fn pushEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try worker_runtime.dupeWorkerEvent(alloc, event);
        errdefer worker_runtime.freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    fn pushOwnedEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        try self.events.append(alloc, event);
    }

    fn prependOwnedEvents(
        self: *FakeWorker,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        try self.events.insertSlice(alloc, 0, events);
    }

    fn takeEvents(self: *FakeWorker) std.ArrayList(WorkerEvent) {
        const events = self.events;
        self.events = .empty;
        if (self.reset_cancel_after_take_events) {
            self.reset_cancel_after_take_events = false;
            self.worker_cancel_requested.store(false, .seq_cst);
        }
        return events;
    }

    fn takeEventBatch(self: *FakeWorker) worker_runtime.WorkerEventBatch {
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        return .{
            .events = self.takeEvents(),
            .cancelled_turn_id = if (cancel_requested and self.active_turn_id != 0) self.active_turn_id else null,
        };
    }

    fn snapshotState(self: *FakeWorker, alloc: std.mem.Allocator) !FakeSnapshot {
        return .{
            .processing = self.processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queued_count,
            .pending_event_count = self.events.items.len,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
            .cancel_continues_turn = self.cancel_continues_turn,
            .pending_permission_request = if (self.pending_permission_request) |request|
                try permission_request.OwnedPermissionRequest.dupe(alloc, request)
            else
                null,
            .pending_permission_review = if (self.pending_permission_request) |request|
                if (self.pending_permission_review) |review|
                    .{
                        .request_id = request.id,
                        .review = review,
                    }
                else
                    null
            else
                null,
        };
    }

    pub fn interactiveAdmissionSnapshot(self: *FakeWorker) worker_runtime.InteractiveAdmissionSnapshot {
        return self.admission_snapshot;
    }

    fn snapshotPendingQuestionBatch(self: *FakeWorker, alloc: std.mem.Allocator) !?FakeQuestionSnapshot {
        _ = alloc;
        return if (self.pending_question) FakeQuestionSnapshot{
            .source = self.pending_question_source,
        } else null;
    }

    fn syncQueuedPromptModel(self: *FakeWorker, alloc: std.mem.Allocator, model: []const u8) !void {
        _ = self;
        _ = alloc;
        _ = model;
    }

    fn syncQueuedPromptPermissionSnapshot(self: *FakeWorker, snapshot: worker_runtime.PermissionSnapshot) void {
        _ = self;
        _ = snapshot;
    }

    fn syncQueuedPromptPermissionState(self: *FakeWorker, alloc: std.mem.Allocator, grants: []const types.PermissionGrant, snapshot: worker_runtime.PermissionSnapshot) !void {
        _ = self;
        _ = alloc;
        _ = grants;
        _ = snapshot;
    }

    fn activeTurnId(self: *FakeWorker) u64 {
        return self.active_turn_id;
    }

    pub fn propagateHistoryTurn(self: *FakeWorker, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        _ = alloc;
        _ = turn;
        _ = max_history_turns;
        self.propagated_history_turns += 1;
    }

    pub fn propagateGrant(self: *FakeWorker, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        _ = alloc;
        _ = tool_name;
        _ = target_path;
        self.propagated_grants += 1;
    }
};

const FakeApprovalPrompt = struct {
    sync_count: usize = 0,
    force_active: bool = false,
    request: ?permission_request.OwnedPermissionRequest = null,
    review: ?*const diff_mod.FileReview = null,
    review_request_id: u64 = 0,

    fn deinit(self: *FakeApprovalPrompt, alloc: std.mem.Allocator) void {
        if (self.request) |*request| request.deinit(alloc);
        self.request = null;
    }

    fn syncRequest(
        self: *FakeApprovalPrompt,
        alloc: std.mem.Allocator,
        request: ?permission_request.PermissionRequest,
    ) permission_request.RequestCloneError!bool {
        self.sync_count += 1;
        if (request) |value| {
            const owned = try permission_request.OwnedPermissionRequest.dupe(alloc, value);
            if (self.request) |*current| current.deinit(alloc);
            self.request = owned;
            return true;
        }
        const changed = self.request != null;
        if (self.request) |*current| current.deinit(alloc);
        self.request = null;
        self.review = null;
        self.review_request_id = 0;
        return changed;
    }

    pub fn syncReview(self: *FakeApprovalPrompt, review: ?*const diff_mod.FileReview) bool {
        const request = self.request orelse {
            const changed = self.review != null;
            self.review = null;
            self.review_request_id = 0;
            return changed;
        };
        if (self.review == review and self.review_request_id == request.id) return false;
        self.review = review;
        self.review_request_id = if (review == null) 0 else request.id;
        return true;
    }

    fn isActive(self: FakeApprovalPrompt) bool {
        return self.force_active or self.request != null;
    }
};

const FakeQuestionPrompt = struct {
    active: bool = false,
    activate_on_sync: bool = true,
    sync_count: usize = 0,
    clear_count: usize = 0,
    question: []const u8 = "",

    fn projection(self: *const FakeQuestionPrompt) ?struct { current_entry: ?struct { question: []const u8 } } {
        if (!self.active) return null;
        return .{ .current_entry = .{ .question = self.question } };
    }

    fn syncFrom(self: *FakeQuestionPrompt, alloc: std.mem.Allocator, entries: anytype) !void {
        _ = alloc;
        _ = entries;
        self.sync_count += 1;
        self.active = self.activate_on_sync;
    }

    fn discard(
        self: *FakeQuestionPrompt,
        alloc: std.mem.Allocator,
        reason: []const u8,
    ) void {
        _ = alloc;
        _ = reason;
        self.clear_count += 1;
        self.active = false;
    }

    fn isActive(self: FakeQuestionPrompt) bool {
        return self.active;
    }
};

const FakeCommandOutputDisplay = struct {
    touched: bool = false,
};

const FakeShell = struct {
    command_output_display: FakeCommandOutputDisplay = .{},
    shimmer_active: bool = false,
    native_history_active: bool = false,
    render_requests: render_request.RenderRequestState = .{},
    lifecycle: transcript_runtime.TranscriptRuntime = .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    },
    raw_entries: std.ArrayList([]u8) = .empty,
    updated_entries: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    trim_calls: usize = 0,
    fail_next_update: bool = false,

    fn deinit(self: *FakeShell, alloc: std.mem.Allocator) void {
        self.lifecycle.deinit(alloc);
        for (self.raw_entries.items) |entry| alloc.free(entry);
        self.raw_entries.deinit(alloc);
    }

    fn nativeHistoryActive(self: *const FakeShell) bool {
        return self.native_history_active;
    }

    fn trimTrailingBlankLines(self: *FakeShell) void {
        self.trim_calls += 1;
    }

    fn appendRawTranscriptEntry(self: *FakeShell, alloc: std.mem.Allocator, line: []const u8) !u32 {
        try self.raw_entries.append(alloc, try alloc.dupe(u8, line));
        return @intCast(self.raw_entries.items.len);
    }

    fn appendFullDetailRecord(self: *FakeShell, alloc: std.mem.Allocator, notice: types.SemanticNotice) !void {
        return self.lifecycle.appendFullDetailRecord(alloc, notice);
    }

    fn appendRawTranscriptEntryClassified(self: *FakeShell, alloc: std.mem.Allocator, line: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendRawTranscriptEntry(alloc, line);
    }

    fn updateRawBytesEntry(self: *FakeShell, alloc: std.mem.Allocator, entry_id: u32, line: []const u8) !bool {
        const index = entry_id - 1;
        alloc.free(self.raw_entries.items[index]);
        self.raw_entries.items[index] = try alloc.dupe(u8, line);
        self.updated_entries += 1;
        return true;
    }

    fn setRawEntryClass(self: *FakeShell, entry_id: u32, class: transcript_runtime.RawEntryClass) bool {
        _ = entry_id;
        self.last_class = class;
        return true;
    }

    pub fn applyToolLifecycle(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        if (self.fail_next_update) {
            switch (event) {
                .progress, .terminal, .turn_finished => {
                    self.fail_next_update = false;
                    return error.InjectedTranscriptUpdateFailure;
                },
                .provisional, .authoritative_started => {},
            }
        }
        return self.lifecycle.applyToolLifecycle(alloc, event);
    }

    pub fn finishLifecycleBatch(
        self: *FakeShell,
        alloc: std.mem.Allocator,
    ) !void {
        return self.lifecycle.finishLifecycleBatch(alloc);
    }

    pub fn activityProjection(
        self: *const FakeShell,
    ) activity_runtime.ActivityProjection {
        return self.lifecycle.activityProjection();
    }

    pub fn worker_status_state(self: *FakeShell) *worker_status.State {
        return self.lifecycle.worker_status_state();
    }

    pub fn focusedToolEntryId(self: *const FakeShell) ?u32 {
        return self.lifecycle.focusedToolEntryId();
    }

    pub fn focusedToolActivityKind(
        self: *const FakeShell,
    ) ?types.ToolActivityKind {
        return self.lifecycle.focusedToolActivityKind();
    }

    pub fn activeToolActivityCount(self: *const FakeShell) usize {
        return self.lifecycle.activeToolActivityCount();
    }

    fn toolActivityRecord(
        self: *const FakeShell,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle.toolActivityRecord(id);
    }

    fn toolActivityRecordCount(self: *const FakeShell) usize {
        return self.lifecycle.toolActivityRecordCount();
    }

    fn toolStatusEntryLabel(self: *const FakeShell, entry_id: u32) ?[]const u8 {
        return self.lifecycle.toolStatusEntryLabel(entry_id);
    }

    fn finalizedToolTurnWatermark(self: *const FakeShell) u64 {
        return self.lifecycle.finalizedToolTurnWatermark();
    }

    fn lifecyclePinCount(self: *const FakeShell) usize {
        return self.lifecycle.lifecyclePinCount();
    }

    fn replaceableEntryId(self: *FakeShell) ?u32 {
        _ = self;
        return null;
    }

    fn resetCommandOutputDisplay(self: *FakeShell, alloc: std.mem.Allocator, reason: []const u8) void {
        _ = alloc;
        _ = reason;
        self.command_output_display = .{};
    }

    pub fn openCommandOutputLifecycleId(self: *const FakeShell) ?types.ToolLifecycleId {
        return self.lifecycle.openCommandOutputLifecycleId();
    }
};

const FakePacer = struct {
    flushed: usize = 0,
    completed_assistant_presentation_tail: bool = false,

    fn flushPendingText(self: *FakePacer, callbacks: anytype) !void {
        _ = callbacks;
        self.flushed += 1;
    }

    fn hasCompletedAssistantPresentationTail(self: *const FakePacer) bool {
        return self.completed_assistant_presentation_tail;
    }
};

const FakeSubagents = struct {
    view_active: bool = false,
    child_busy: bool = false,
    child_shell: FakeShell = .{},
    child_render_requests: render_request.RenderRequestState = .{},

    fn isViewActive(self: FakeSubagents) bool {
        return self.view_active;
    }

    fn childConversationRuntime(self: *FakeSubagents) ?*FakeShell {
        if (!self.view_active) return null;
        return &self.child_shell;
    }

    fn activeRenderRequests(self: *FakeSubagents) *render_request.RenderRequestState {
        return &self.child_render_requests;
    }

    fn deinit(self: *FakeSubagents, alloc: std.mem.Allocator) void {
        self.child_shell.deinit(alloc);
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    main_agent: struct {
        approval_prompt: FakeApprovalPrompt = .{},
        question_prompt: FakeQuestionPrompt = .{},
        session_persistence: app_session_runtime.Persistence = .{},
        worker: FakeWorker = .{},
        stream: types.StreamState = .{},
    } = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    input_runtime: InputRuntime = .{},
    shell: FakeShell = .{},
    pacer: FakePacer = .{},
    subagents: FakeSubagents = .{},
    should_exit: bool = false,
    frame_commits: usize = 0,
    transcript: std.ArrayList(u8) = .empty,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    attention_count: usize = 0,
    last_attention_turn_id: u64 = 0,
    last_attention_kind: ?@import("../hooks/hooks.zig").AttentionKind = null,
    persisted_finishes: std.ArrayList(types.FinishedPrompt) = .empty,
    finish_persistence_error: ?anyerror = null,
    program_status: program_status.Reporter = .{},
    program_status_reports: std.ArrayList(u8) = .empty,
    program_status_capture_failed: bool = false,

    fn init(alloc: std.mem.Allocator) FakeApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *FakeApp) void {
        for (self.persisted_finishes.items) |finished| types.freeFinishedPrompt(self.alloc, finished);
        self.persisted_finishes.deinit(self.alloc);
        self.program_status_reports.deinit(self.alloc);
        self.agent().session_persistence.deinit(self.alloc);
        self.agent().worker.deinit();
        self.agent().approval_prompt.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
    }

    fn pacerCallbacks(self: *FakeApp) void {
        _ = self;
    }

    pub fn appendFinishedPrompt(self: *FakeApp, finished: types.FinishedPrompt) !void {
        if (self.finish_persistence_error) |err| return err;
        const owned = try types.dupeFinishedPrompt(self.alloc, finished);
        errdefer types.freeFinishedPrompt(self.alloc, owned);
        try self.persisted_finishes.append(self.alloc, owned);
        if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
    }

    fn writeTranscript(self: *FakeApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        try self.transcript.appendSlice(self.alloc, notice.topic);
        try self.transcript.appendSlice(self.alloc, ":");
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn writeTranscriptClassified(self: *FakeApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(text, record);
    }

    fn appendReplaceableTranscriptLine(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    fn appendReplaceableTranscriptLineClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLine(text);
    }

    fn appendReplaceableTranscriptLineSilent(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    fn appendReplaceableTranscriptLineSilentClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLineSilent(text);
    }

    fn replaceTrailingTranscriptLine(self: *FakeApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn replaceTrailingTranscriptLineSilent(self: *FakeApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn dispatchAttentionRequired(
        self: *FakeApp,
        turn_id: u64,
        kind: @import("../hooks/hooks.zig").AttentionKind,
    ) void {
        self.attention_count += 1;
        self.last_attention_turn_id = turn_id;
        self.last_attention_kind = kind;
    }

    fn writeProgramStatus(self: *FakeApp, report: []const u8) void {
        self.program_status_reports.appendSlice(self.alloc, report) catch {
            self.program_status_capture_failed = true;
        };
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn expectProgramStatusReports(app: *FakeApp, expected: []const u8) !void {
    try std.testing.expect(!app.program_status_capture_failed);
    const reports = try app.program_status_reports.toOwnedSlice(app.alloc);
    defer app.alloc.free(reports);
    try std.testing.expectEqualStrings(expected, reports);
}

test "core.app_worker_runtime program status follows decision prompts to the turn result" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try tickNoop(&app);
    try expectProgramStatusReports(&app, "\x1b]7501;state=idle:app=fx\x1b\\");

    app.agent().worker.processing = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = .{ .text = @constCast("push it") } });
    try tickNoop(&app);
    try expectProgramStatusReports(&app, "\x1b]7501;state=working:app=fx\x1b\\");

    app.agent().worker.pending_permission_request = .{ .label = "shell.run git push" };
    try tickNoop(&app);
    try tickNoop(&app);
    try expectProgramStatusReports(
        &app,
        "\x1b]7501;state=blocked:kind=permission:app=fx:msg=c2hlbGwucnVuIGdpdCBwdXNo\x1b\\",
    );

    app.agent().worker.pending_permission_request = null;
    app.agent().worker.pending_question = true;
    app.agent().question_prompt.question = "Which branch?";
    try app.agent().worker.pushEvent(std.heap.c_allocator, .question_requested);
    try tickNoop(&app);
    try expectProgramStatusReports(&app, "\x1b]7501;state=blocked:kind=question:app=fx:msg=V2hpY2ggYnJhbmNoPw==\x1b\\");

    app.agent().worker.pending_question = false;
    try tickNoop(&app);
    try expectProgramStatusReports(&app, "\x1b]7501;state=working:app=fx\x1b\\");

    try queueTurnFinished(&app, 1, .completed);
    app.agent().worker.processing = false;
    try tickNoop(&app);
    try expectProgramStatusReports(&app, "\x1b]7501;state=done:app=fx\x1b\\");

    // Work that starts no turn and reports no result settles as idle instead
    // of reporting the earlier result again.
    app.agent().worker.processing = true;
    try tickNoop(&app);
    app.agent().worker.processing = false;
    try tickNoop(&app);
    try expectProgramStatusReports(
        &app,
        "\x1b]7501;state=working:app=fx\x1b\\\x1b]7501;state=idle:app=fx\x1b\\",
    );

    // A failed `/compact` reports an error although no turn ran.
    app.agent().worker.processing = true;
    const compaction = app.agent().worker.compaction.begin(.manual, null, 0);
    try tickNoop(&app);
    app.agent().worker.compaction.settle(compaction, @import("../output/compaction_activity.zig").failure(error.ConnectionRefused, .summary, false), 1);
    app.agent().worker.processing = false;
    try tickNoop(&app);
    try expectProgramStatusReports(
        &app,
        "\x1b]7501;state=working:app=fx\x1b\\\x1b]7501;state=error:app=fx\x1b\\",
    );

    app.agent().worker.processing = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = .{ .text = @constCast("again") } });
    try tickNoop(&app);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed: ConnectionRefused",
    } });
    app.agent().worker.processing = false;
    try tickNoop(&app);
    try expectProgramStatusReports(
        &app,
        "\x1b]7501;state=working:app=fx\x1b\\\x1b]7501;state=error:app=fx\x1b\\",
    );

    // An approval prompt that opens outside a turn does not bring the
    // reported error back once it closes.
    app.agent().worker.pending_permission_request = .{ .label = "Remember allow for this saved session" };
    try tickNoop(&app);
    app.agent().worker.pending_permission_request = null;
    try tickNoop(&app);
    try expectProgramStatusReports(
        &app,
        "\x1b]7501;state=blocked:kind=permission:app=fx:msg=UmVtZW1iZXIgYWxsb3cgZm9yIHRoaXMgc2F2ZWQgc2Vzc2lvbg==\x1b\\" ++
            "\x1b]7501;state=idle:app=fx\x1b\\",
    );
}

const NoopBridge = struct {
    fn user(_: *anyopaque, _: types.UserTurn) !void {}
    fn text(_: *anyopaque, _: []const u8) !void {}
    fn drain(_: *anyopaque) !AssistantTextDrainResult {
        return .drained;
    }
    fn openModelPicker(_: *anyopaque) !void {}
    fn notice(_: *anyopaque, _: types.SemanticNotice) !void {}
    fn output(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) !void {}
    fn outputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn diff(_: *anyopaque, payload: @import("../output/diff.zig").DiffEntryPayload) !void {
        @import("../output/diff.zig").freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
    fn history(_: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
        return .{ .settled = .committed };
    }
    fn grant(_: *anyopaque, _: types.PermissionGrant) !void {}
    fn err(_: *anyopaque, _: types.SemanticNotice) !void {}

    fn lifecycleSnapshot(raw: *anyopaque) activity_runtime.LifecycleSnapshot {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        return .{
            .finalized_turn_watermark = app.shell.finalizedToolTurnWatermark(),
            .active_tool_count = app.shell.activeToolActivityCount(),
            .focused_entry_id = app.shell.focusedToolEntryId(),
            .focused_activity_kind = app.shell.focusedToolActivityKind(),
            .activity = app.shell.activityProjection(),
        };
    }

    fn lifecycleRecord(
        raw: *anyopaque,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        return app.shell.toolActivityRecord(id);
    }

    fn applyLifecycle(
        raw: *anyopaque,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !activity_runtime.LifecycleTransition {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        const previous_focused_entry_id = app.shell.focusedToolEntryId();
        const applied_activity_kind = try app.shell.applyToolLifecycle(alloc, event);
        return .{
            .previous_focused_entry_id = previous_focused_entry_id,
            .snapshot = lifecycleSnapshot(raw),
            .applied_activity_kind = applied_activity_kind,
            .terminal_record = switch (event) {
                .terminal => |terminal| app.shell.toolActivityRecord(terminal.id),
                .provisional, .authoritative_started, .progress, .turn_finished => null,
            },
        };
    }

    fn finishLifecycleBatch(raw: *anyopaque, alloc: std.mem.Allocator) !void {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        try app.shell.finishLifecycleBatch(alloc);
    }

    fn lifecyclePresenter(app: *FakeApp) activity_runtime.LifecyclePresenter {
        return .{
            .ctx = @ptrCast(app),
            .snapshot_fn = lifecycleSnapshot,
            .record_fn = lifecycleRecord,
            .apply_fn = applyLifecycle,
            .finish_batch_fn = finishLifecycleBatch,
        };
    }

    fn handlers(app: *FakeApp) WorkerEventHandlers {
        return .{
            .ctx = undefined,
            .tool_lifecycle = lifecyclePresenter(app),
            .write_user_prompt = user,
            .append_text = text,
            .drain_assistant_text = drain,
            .open_model_picker = openModelPicker,
            .semantic_notice = notice,
            .command_output = output,
            .command_output_complete = outputComplete,
            .diff_block = diff,
            .append_history_turn = history,
            .session_grant = grant,
            .error_text = err,
        };
    }
};

const PacedTranscriptBridge = struct {
    app: *FakeApp,
    pacer: assistant_pacer.AssistantPacer = .{},
    metrics: types.Metrics = .{},
    drain_count: usize = 0,
    user_prompt_count: usize = 0,
    pacer_pending_when_user_prompt_written: bool = false,
    assistant_present_when_user_prompt_written: bool = false,
    notice_count: usize = 0,
    history_count: usize = 0,
    finish_count: usize = 0,
    order: [8]u8 = undefined,
    order_len: usize = 0,

    fn init(app: *FakeApp) PacedTranscriptBridge {
        return .{ .app = app };
    }

    fn deinit(self: *PacedTranscriptBridge) void {
        self.pacer.deinit(self.app.alloc);
    }

    fn callbacks(self: *PacedTranscriptBridge) assistant_pacer.TickCallbacks {
        return .{
            .emit_ctx = @ptrCast(self),
            .emit_fn = emit,
            .finish_ctx = @ptrCast(self),
            .finish_fn = finish,
        };
    }

    fn handlers(self: *PacedTranscriptBridge) WorkerEventHandlers {
        var bridge = NoopBridge.handlers(self.app);
        bridge.ctx = @ptrCast(self);
        bridge.write_user_prompt = writeUserPrompt;
        bridge.append_text = appendText;
        bridge.drain_assistant_text = drainAssistantText;
        bridge.semantic_notice = semanticNotice;
        bridge.append_history_turn = appendHistoryTurn;
        return bridge;
    }

    fn tickPacer(self: *PacedTranscriptBridge, now_ns: i128) !void {
        try self.pacer.tick(self.app.alloc, now_ns, self.callbacks());
    }

    fn record(self: *PacedTranscriptBridge, value: u8) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = value;
            self.order_len += 1;
        }
    }

    fn orderSlice(self: *const PacedTranscriptBridge) []const u8 {
        return self.order[0..self.order_len];
    }

    fn appendText(raw: *anyopaque, text: []const u8) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        try self.pacer.enqueue(self.app.alloc, text);
    }

    fn writeUserPrompt(raw: *anyopaque, _: types.UserTurn) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.user_prompt_count += 1;
        self.record('U');
        self.pacer_pending_when_user_prompt_written = self.pacer.hasPending();
        self.assistant_present_when_user_prompt_written =
            self.app.shell.lifecycle.notebook.entries.items.len > 0 and
            self.app.shell.lifecycle.notebook.entries.items[self.app.shell.lifecycle.notebook.entries.items.len - 1] == .assistant_turn;
    }

    fn drainAssistantText(raw: *anyopaque) !AssistantTextDrainResult {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.drain_count += 1;
        try self.pacer.flushPresentationAtBoundary(
            self.app.alloc,
            0,
            self.callbacks(),
        );
        return .drained;
    }

    fn semanticNotice(raw: *anyopaque, _: types.SemanticNotice) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.notice_count += 1;
    }

    fn appendHistoryTurn(raw: *anyopaque, finished: types.FinishedPrompt) !HistoryDelivery {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.history_count += 1;
        if (try self.pacer.deferFinish(self.app.alloc, finished)) return .retained;
        self.finish_count += 1;
        return .{ .settled = .committed };
    }

    fn emit(raw: *anyopaque, text: []const u8) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        _ = try self.app.shell.lifecycle.streamAssistantChunk(
            self.app.alloc,
            &self.metrics,
            text,
        );
    }

    fn finish(raw: *anyopaque, _: types.FinishedPrompt) !assistant_pacer.FinishResult {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.finish_count += 1;
        self.record('F');
        return .committed;
    }
};

fn tickNoop(app: *FakeApp) !void {
    try Runtime(FakeApp).tick(app, app.agent(), NoopBridge.handlers(app));
}

const testRecoveryText = types.testRecoveryText;

fn testWaitingStatus(attempt: usize) types.RouteRecoveryStatus {
    return .{
        .kind = .waiting,
        .text = testRecoveryText("Connection lost · next try in 4s · attempt 1 · 3s"),
        .attempt = attempt,
    };
}

fn queueLifecycle(app: *FakeApp, event: types.ToolLifecycleEvent) !void {
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .tool_lifecycle = event });
}

fn queueToolStart(
    app: *FakeApp,
    turn_id: u64,
    call_id: []const u8,
    tool_name: []const u8,
) !void {
    try queueLifecycle(app, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call_id },
        .reconciles_provisional_call_id = null,
        .tool_name = tool_name,
        .activity_kind = if (std.mem.eql(u8, tool_name, "read_file"))
            .read
        else if (std.mem.eql(u8, tool_name, "write_file"))
            .write
        else
            .command,
    } });
}

fn queueToolTerminal(
    app: *FakeApp,
    turn_id: u64,
    call_id: []const u8,
    kind: types.ToolOutcomeKind,
    summary: []const u8,
) !void {
    try queueLifecycle(app, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call_id },
        .outcome = .{ .kind = kind, .summary = summary },
    } });
}

fn queueTurnFinished(
    app: *FakeApp,
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
) !void {
    try queueLifecycle(app, .{ .turn_finished = .{
        .turn_id = turn_id,
        .outcome = outcome,
    } });
}

test "detached worker batch frees claimed current and unvisited suffix exactly once" {
    const alloc = std.testing.allocator;
    var events: std.ArrayList(WorkerEvent) = .empty;
    errdefer {
        for (events.items) |event| worker_runtime.freeWorkerEvent(alloc, event);
        events.deinit(alloc);
    }

    try events.append(alloc, try worker_runtime.dupeWorkerEvent(
        alloc,
        .{ .assistant_presentation = .{ .text = @constCast("current") } },
    ));
    try events.append(alloc, try worker_runtime.dupeWorkerEvent(
        alloc,
        .{ .tool_lifecycle = .{ .progress = .{
            .id = .{ .turn_id = 1, .call_id = "suffix-lifecycle" },
            .text = "suffix progress",
        } } },
    ));
    try events.append(alloc, try worker_runtime.dupeWorkerEvent(
        alloc,
        .{ .diff_block = .{
            .preview = @constCast("preview"),
        } },
    ));

    var batch = DetachedWorkerEventBatch.init(alloc, events);
    defer batch.deinit();

    const current = batch.claim().?;
    worker_runtime.freeWorkerEvent(batch.alloc, current);
}

test "core.app_worker_runtime fatal admission rejects tick before work" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.admission_snapshot = .{ .finalization_failed = .{
        .turn_id = 31,
        .outcome = .failed,
    } };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
        .text = @constCast("pending"),
    } });

    try std.testing.expectError(
        error.TurnFinalizationDeliveryFailed,
        tickNoop(&app),
    );

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.events.items.len);
}

test "core.app_worker_runtime fatal linearization blocks the next frame admission" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(try Runtime(FakeApp).authorizeInteractiveAdmission(&app, (&app).agent()));

    const Render = struct {
        fn frame(inner: *FakeApp) !void {
            inner.agent().worker.admission_snapshot = .{ .finalization_failed = .{
                .turn_id = 32,
                .outcome = .failed,
            } };
            inner.frame_commits += 1;
        }
    };

    if (try Runtime(FakeApp).authorizeInteractiveAdmission(&app, (&app).agent())) {
        try Render.frame(&app);
    }
    try std.testing.expectEqual(@as(usize, 1), app.frame_commits);

    try std.testing.expectError(
        error.TurnFinalizationDeliveryFailed,
        Runtime(FakeApp).authorizeInteractiveAdmission(&app, (&app).agent()),
    );
    try std.testing.expectEqual(@as(usize, 1), app.frame_commits);
    try std.testing.expect(app.should_exit);
}

test "core.app_worker_runtime pushes worker events" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try Runtime(FakeApp).pushText(&app, (&app).agent(), "hello");

    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.events.items.len);
    try std.testing.expectEqualStrings("hello", app.agent().worker.events.items[0].assistant_presentation.text);
}

test "core.app_worker_runtime assistant chunk trace is metadata only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trace_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        ".",
    );
    defer alloc.free(trace_path);
    const trace_file_path = try std.Io.Dir.path.join(
        alloc,
        &.{ trace_path, "worker-trace.log" },
    );
    defer alloc.free(trace_file_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(
        alloc,
        trace_file_path,
        "worker",
    );

    var app = FakeApp.init(alloc);
    defer app.deinit();
    const secret = "FX_ASSISTANT_CHUNK_SECRET";
    try Runtime(FakeApp).pushText(&app, (&app).agent(), secret);
    try tickNoop(&app);
    debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        trace_file_path,
        .{},
    );
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "event=assistant_chunk_received",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "event=assistant_chunk_applied",
    ) != null);
    try std.testing.expect(std.mem.find(u8, trace, "chunk_bytes=25") != null);
    try std.testing.expect(std.mem.find(u8, trace, secret) == null);
}

test "core.app_worker_runtime applies turn token input as absolute set" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().stream.active = true;
    app.agent().stream.token_progress.input_tokens = 99;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_token_update = .{ .input_tokens = 10 } });

    try tickNoop(&app);

    try std.testing.expectEqual(@as(u64, 10), app.agent().stream.token_progress.input_tokens);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime applies turn token output as an absolute snapshot" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().stream.active = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_token_update = .{ .output_tokens = 3 } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_token_update = .{ .output_tokens = 4 } });

    try tickNoop(&app);

    try std.testing.expectEqual(@as(u64, 4), app.agent().stream.token_progress.output_tokens);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime applies only current monotonic turn phase updates" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.active_turn_id = 7;
    app.agent().stream.active = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_phase_update = .{
        .turn_id = 7,
        .step_id = 12,
        .phase = .generating,
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_phase_update = .{
        .turn_id = 7,
        .step_id = 11,
        .phase = .running,
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_phase_update = .{
        .turn_id = 6,
        .step_id = 13,
        .phase = .running,
    } });

    try tickNoop(&app);

    try std.testing.expectEqual(types.TurnPhase.generating, app.agent().stream.phase);
    try std.testing.expectEqual(@as(u64, 12), app.agent().stream.phase_step_id);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime next admitted model step returns running to thinking" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.active_turn_id = 7;
    app.agent().stream = .{ .active = true, .phase = .running, .phase_step_id = 12 };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_phase_update = .{
        .turn_id = 7,
        .step_id = 13,
        .phase = .thinking,
    } });

    try tickNoop(&app);

    try std.testing.expectEqual(types.TurnPhase.thinking, app.agent().stream.phase);
    try std.testing.expectEqual(@as(u64, 13), app.agent().stream.phase_step_id);
}

test "manual compaction schedules initial repaint animation and terminal expiry without a stream" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    const id = app.agent().worker.compaction.begin(.manual, null, 1_000);
    app.agent().worker.compaction.running(id, .summary);
    const presenter = NoopBridge.lifecyclePresenter(&app);
    try std.testing.expect(!Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), presenter, 1_000));
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.compaction_reads);
    try std.testing.expect(!app.agent().stream.active);
    app.shell.shimmer_active = true;
    app.shell.render_requests.animation_visible = true;
    app.shell.render_requests.animation_next_deadline_ms = 1_050;
    try std.testing.expect(Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), presenter, 1_050));
    try std.testing.expect(app.shell.render_requests.hasReason(.animation));
    app.shell.render_requests.clearReason(.animation);
    app.agent().worker.compaction.settle(id, .{ .outcome = .no_op }, 1_100);
    try std.testing.expect(!Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), presenter, 2_599));
    try std.testing.expect(!app.agent().worker.compaction.snapshot.operation.?.dismissed);
    try std.testing.expect(!Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), presenter, 2_600));
    try std.testing.expect(app.agent().worker.compaction.snapshot.operation.?.dismissed);
    try std.testing.expect(!app.agent().stream.active);
}

test "core.app_worker_runtime advances visible animation exactly at its deadline" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().stream = .{
        .active = true,
        .last_activity_kind = .ask,
    };
    app.shell.shimmer_active = true;
    app.shell.render_requests.animation_visible = true;
    app.shell.render_requests.animation_next_deadline_ms = 1_050;
    const before = app.shell.render_requests.visibleAnimationPhase();

    try std.testing.expect(!Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app), 1_049));
    try std.testing.expectEqual(before, app.shell.render_requests.visibleAnimationPhase());
    try std.testing.expect(!app.shell.render_requests.hasReason(.animation));

    try std.testing.expect(Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app), 1_050));
    try std.testing.expectEqual(before, app.shell.render_requests.visibleAnimationPhase());
    try std.testing.expect(app.shell.render_requests.hasReason(.animation));

    try std.testing.expect(!Runtime(FakeApp).advanceVisibleAnimation(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app), 1_050));
    try std.testing.expectEqual(before, app.shell.render_requests.visibleAnimationPhase());
}

test "core.app_worker_runtime keeps visible animation alive after native history starts" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().stream = .{
        .active = true,
        .last_activity_kind = .ask,
    };
    app.shell.shimmer_active = true;
    app.shell.native_history_active = true;
    app.shell.render_requests.animation_visible = true;
    app.shell.render_requests.animation_next_deadline_ms = 1;

    try std.testing.expect(Runtime(FakeApp).advanceVisibleAnimation(
        &app,
        (&app).agent(),
        NoopBridge.lifecyclePresenter(&app),
        1,
    ));
    try std.testing.expect(app.shell.render_requests.hasReason(.animation));
}

test "core.app_worker_runtime ticks animation for completed assistant presentation tail only" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.shell.shimmer_active = true;
    app.shell.render_requests.animation_visible = true;
    app.shell.render_requests.animation_next_deadline_ms = 1;
    app.pacer.completed_assistant_presentation_tail = true;
    try tickNoop(&app);
    try std.testing.expect(app.shell.render_requests.hasReason(.animation));

    app.shell.render_requests.clearReason(.animation);
    app.shell.render_requests.animation_next_deadline_ms = 1;
    app.pacer.completed_assistant_presentation_tail = false;
    try tickNoop(&app);
    try std.testing.expect(!app.shell.render_requests.hasReason(.animation));

    app.shell.render_requests.animation_next_deadline_ms = 1;
    app.pacer.completed_assistant_presentation_tail = true;
    app.agent().question_prompt.active = true;
    try tickNoop(&app);
    try std.testing.expect(!app.shell.render_requests.hasReason(.animation));

    app.agent().question_prompt.active = false;
    app.agent().approval_prompt.force_active = true;
    app.shell.render_requests.animation_next_deadline_ms = 1;
    try tickNoop(&app);
    try std.testing.expect(!app.shell.render_requests.hasReason(.animation));
}

test "core.app_worker_runtime ignores turn token updates when stream inactive" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_token_update = .{ .input_tokens = 10, .output_tokens = 4 } });

    try tickNoop(&app);

    try std.testing.expectEqual(types.TurnTokenProgress{}, app.agent().stream.token_progress);
    try std.testing.expect(!app.agent().stream.active);
}

test "core.app_worker_runtime resets turn token counters on begin and finish" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().stream = .{
        .active = true,
        .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
    };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = try types.dupeUserTurn(std.heap.c_allocator, .{ .text = @constCast("next"), .images = &.{} }) });
    try tickNoop(&app);
    try std.testing.expectEqual(types.TurnTokenProgress{}, app.agent().stream.token_progress);
    try std.testing.expect(!app.shell.render_requests.blocksFrameCommit());

    app.agent().stream = .{
        .active = true,
        .token_progress = .{ .input_tokens = 30, .output_tokens = 40 },
    };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .compacted_summary = .{
        .summary = try std.heap.c_allocator.dupe(u8, "summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } } } });
    try tickNoop(&app);
    try std.testing.expectEqual(types.TurnTokenProgress{}, app.agent().stream.token_progress);
}

test "core.app_worker_runtime projects route recovery status activity and clears it on begin" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = testWaitingStatus(1) });
    try tickNoop(&app);

    switch (app.shell.activityProjection()) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(activity_runtime.ActivityProjection.Tone.warning, thinking.tone);
            try std.testing.expectEqualStrings("⚠ Connection lost · next try in 4s · attempt 1 · 3s", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.render_requests.clearReason(.footer);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = try types.dupeUserTurn(std.heap.c_allocator, .{ .text = @constCast("next"), .images = &.{} }) });
    try tickNoop(&app);

    try std.testing.expect(app.shell.activityProjection() == .none);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime clears route recovery activity on clear event but not error text" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = testWaitingStatus(2) });
    try tickNoop(&app);
    switch (app.shell.activityProjection()) {
        .turn_thinking => {},
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    try app.agent().worker.pushEvent(std.heap.c_allocator, .clear_route_recovery_status);
    try tickNoop(&app);
    try std.testing.expect(app.shell.activityProjection() == .none);

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .terminal_provider_error,
        .attempt = 3,
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed",
    } });
    try tickNoop(&app);
    switch (app.shell.activityProjection()) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings("⚠ Provider unavailable · stopped after 3 attempts", thinking.label),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "core.app_worker_runtime replaces a waiting status with its terminal attempt" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = testWaitingStatus(1) });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .terminal_provider_error,
        .attempt = 1,
        .diagnostic = types.ModelFailureDiagnostic.init("TestProviderSerializationFailed"),
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed",
    } });
    try tickNoop(&app);

    switch (app.shell.activityProjection()) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings(
            "⚠ Provider unavailable · test provider serialization failed · stopped after 1 attempt",
            thinking.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "core.app_worker_runtime a recovery leaves no status and no recovered summary" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().stream.active = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = testWaitingStatus(2) });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .recovered,
        .text = testRecoveryText("Connection lost · retrying · attempt 2 · 5s"),
        .attempt = 2,
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .compacted_summary = .{
        .summary = try std.heap.c_allocator.dupe(u8, "summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } }, .summary = .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    } } });

    const Capture = struct {
        fn history(ctx: *anyopaque, finished: types.FinishedPrompt) !HistoryDelivery {
            const inner: *FakeApp = @ptrCast(@alignCast(ctx));
            if (finished.summary) |summary| {
                _ = try inner.shell.lifecycle.appendTurnSummaryEntry(inner.alloc, summary);
            }
            return .{ .settled = .committed };
        }
    };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&app);
    handlers.append_history_turn = Capture.history;
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(app.shell.activityProjection() == .none);
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expect(std.mem.find(u8, app.shell.lifecycle.notebook.entries.items[0].raw_bytes.bytes, ui_render.dim_style) != null);
    try std.testing.expect(std.mem.find(u8, app.shell.lifecycle.notebook.entries.items[0].raw_bytes.bytes, "  2m 10s (↑10k ↓5k)") != null);
    try std.testing.expect(std.mem.find(u8, app.shell.lifecycle.notebook.entries.items[0].raw_bytes.bytes, "✓ recovered") == null);
}

test "core.app_worker_runtime records a terminal route recovery as a full-detail record" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .terminal_provider_error,
        .attempt = 2,
        .cause = .rate_limited,
    } });
    try tickNoop(&app);

    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.full_detail_records.items.len);
    const record = app.shell.lifecycle.notebook.full_detail_records.items[0].notice;
    try std.testing.expectEqualStrings("recovery", record.topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", record.tone);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, record.visibility);
    try std.testing.expect(std.mem.find(u8, record.body, "stopped after 2 attempts") != null);
    try std.testing.expect(std.mem.find(u8, record.body, "kind: terminal_provider_error") != null);
    try std.testing.expect(std.mem.find(u8, record.body, "cause: rate_limited") != null);
    try std.testing.expect(std.mem.find(u8, record.body, "attempt: 2") != null);
    // The record stays out of the transcript entry store.
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecycle.notebook.entries.items.len);
}

test "core.app_worker_runtime keeps recovery module statuses out of the transcript" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = testWaitingStatus(1) });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .recovered,
        .text = testRecoveryText("Connection lost · retrying · attempt 2 · 5s"),
        .attempt = 2,
    } });
    try tickNoop(&app);

    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecycle.notebook.full_detail_records.items.len);
    try std.testing.expect(app.shell.activityProjection() == .none);
}

test "core.app_worker_runtime skips the recovery record for statuses dropped by cancellation" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    app.agent().stream.active = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .terminal_provider_error,
        .attempt = 1,
    } });
    try tickNoop(&app);
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecycle.notebook.full_detail_records.items.len);
}

test "writeRouteRecoveryBody omits absent facts" {
    const alloc = std.testing.allocator;
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    try writeRouteRecoveryBody(&body.writer, .{
        .kind = .terminal_provider_error,
        .attempt = 3,
        .diagnostic = types.ModelFailureDiagnostic.init("TestProviderSerializationFailed"),
    });

    try std.testing.expect(std.mem.find(u8, body.written(), "kind: terminal_provider_error") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), "attempt: 3") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), "diagnostic: TestProviderSerializationFailed") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), "cause:") == null);
}

test "core.app_worker_runtime projects API status text as sticky status row" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .api_status_text = try std.heap.c_allocator.dupe(u8, "⚠ API access denied · HTTP 403 · Provider: wafer") });
    try tickNoop(&app);

    switch (app.shell.activityProjection()) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(activity_runtime.ActivityProjection.Tone.danger, thinking.tone);
            try std.testing.expectEqualStrings("⚠ API access denied · HTTP 403 · Provider: wafer", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = try types.dupeUserTurn(std.heap.c_allocator, .{ .text = @constCast("next"), .images = &.{} }) });
    try tickNoop(&app);
    try std.testing.expect(app.shell.activityProjection() == .none);
}

test "core.app_worker_runtime suppresses route recovery activity while question is active" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .route_recovery_status = .{
        .kind = .content_filter,
    } });
    try tickNoop(&app);

    var active_buf: [256]u8 = undefined;
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    const ctx = render_input.RenderContext{
        .stream = app.agent().stream,
        .has_api_key = true,
        .model = "gpt-5.1",
        .question = .{
            .current_entry = null,
            .current_index = 0,
            .entry_count = 0,
        },
        .activity = app.shell.activityProjection(),
        .input = &input,
    };
    try std.testing.expect(render_input.frameOwnedActivityProjection(&active_buf, &app.shell.lifecycle, ctx, null) == .none);
}

test "core.app_worker_runtime drops turn token updates during cancellation" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    app.agent().stream.active = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_token_update = .{ .input_tokens = 10, .output_tokens = 4 } });

    try tickNoop(&app);

    try std.testing.expectEqual(types.TurnTokenProgress{}, app.agent().stream.token_progress);
}

test "core.app_worker_runtime syncState does not start activity for idle queued prompt" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.queued_count = 1;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime syncState does not start activity for idle processing snapshot" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime syncState preserves already visible processing activity" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().stream = .{
        .active = true,
        .token_progress = .{ .input_tokens = 8, .output_tokens = 13 },
    };

    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(@as(u64, 8), app.agent().stream.token_progress.input_tokens);
    try std.testing.expectEqual(@as(u64, 13), app.agent().stream.token_progress.output_tokens);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime syncState preserves activity when cancellation continues the turn" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    app.agent().worker.cancel_continues_turn = true;
    app.agent().stream = .{
        .active = true,
        .phase = .generating,
        .token_progress = .{ .input_tokens = 8, .output_tokens = 13 },
    };

    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(types.TurnPhase.generating, app.agent().stream.phase);
    try std.testing.expectEqual(@as(u64, 13), app.agent().stream.token_progress.output_tokens);
}

test "core.app_worker_runtime syncState preserves footer until cancelled tool terminal" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    app.agent().stream.active = true;
    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "command" };
    _ = try app.shell.applyToolLifecycle(std.testing.allocator, .{ .authoritative_started = .{
        .id = lifecycle_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    app.shell.render_requests.clearReason(.footer);

    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(app.agent().stream.active);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));

    _ = try app.shell.applyToolLifecycle(std.testing.allocator, .{ .terminal = .{
        .id = lifecycle_id,
        .outcome = .{ .kind = .cancelled, .summary = "Cancelled sleep 30" },
    } });
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime queued command completion preserves three thousand canonical records" {
    const alloc = std.testing.allocator;
    var app = FakeApp.init(alloc);
    defer app.deinit();

    var chunks: [4]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty };
    defer for (&chunks) |*chunk| chunk.deinit(alloc);
    for (0..750) |_| try chunks[0].appendSlice(alloc, "stdout-a\n");
    for (0..750) |_| try chunks[1].appendSlice(alloc, "stderr-a\n");
    for (0..749) |_| try chunks[2].appendSlice(alloc, "stdout-b\n");
    try chunks[2].appendSlice(alloc, "replaced\rstdout-b\n");
    for (0..749) |_| try chunks[3].appendSlice(alloc, "stderr-b\n");
    try chunks[3].appendSlice(alloc, "unterminated");

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 31,
        .call_id = "compact-count",
    };
    inline for (
        [_]command_output_content.Stream{ .stdout, .stderr, .stdout, .stderr },
        0..,
    ) |stream, index| {
        try Runtime(FakeApp).pushCommandOutput(
            &app,
            (&app).agent(),
            lifecycle_id,
            stream,
            chunks[index].items,
        );
    }

    const Capture = struct {
        app: *FakeApp,
        metrics: types.Metrics = .{},
        output_count: usize = 0,

        const styles: transcript_runtime.Styles = .{
            .system_notice_label_style = "",
            .system_notice_text_style = "",
            .reset_style = "",
            .dim_style = "",
            .red_style = "",
        };

        fn output(
            raw: *anyopaque,
            id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            text: []const u8,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.app.shell.command_output_display.touched = true;
            try self.app.shell.lifecycle.writeCommandOutputChunkForLifecycle(
                self.app.alloc,
                &self.metrics,
                styles,
                id,
                stream,
                text,
                true,
            );
            self.output_count += 1;
            if (self.output_count == 4) {
                try Runtime(FakeApp).pushCommandOutputComplete(self.app, (self.app).agent(), id);
            }
        }

        fn outputComplete(raw: *anyopaque, id: ?types.ToolLifecycleId) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.app.shell.lifecycle.flushCommandOutputSummaryForLifecycle(
                self.app.alloc,
                &self.metrics,
                styles,
                id,
                true,
            );
        }
    };
    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.command_output = Capture.output;
    handlers.command_output_complete = Capture.outputComplete;

    app.agent().stream.active = true;
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expect(app.agent().stream.active);
    try std.testing.expect(app.shell.command_output_display.touched);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.events.items.len);
    var block = &app.shell.lifecycle.notebook.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 3_000), block.total_lines);
    try std.testing.expectEqual(@as(usize, 2_995), block.total_lines - 5);
    try std.testing.expectEqualStrings("stdout-a", block.lines.items[0].text);
    try std.testing.expectEqual(.stderr, block.lines.items[750].stream);
    try std.testing.expectEqualStrings("stdout-b", block.lines.items[2_249].text);
    try std.testing.expectEqualStrings("unterminated", block.lines.items[2_999].text);
    try std.testing.expect(!block.lines.items[2_999].terminated);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    block = &app.shell.lifecycle.notebook.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 3_000), block.total_lines);
    try std.testing.expectEqualStrings("unterminated", block.lines.items[2_999].text);
}

test "core.app_worker_runtime syncState mirrors approvals without opening a pending question" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    var review = try diff_mod.FileReview.init(std.testing.allocator, "before\n", "after\n");
    defer review.deinit(std.testing.allocator);
    var replacement_review = try diff_mod.FileReview.init(std.testing.allocator, "before\n", "after again\n");
    defer replacement_review.deinit(std.testing.allocator);

    var path = "note.txt".*;
    var removed = "before".*;
    var added = "after".*;
    var lines = [_]diff_mod.PreviewLine{
        .{ .op = .deletion, .old_line = 2, .text = &removed },
        .{ .op = .addition, .new_line = 2, .text = &added },
    };
    app.agent().worker.processing = true;
    app.agent().worker.pending_permission_review = &review;
    app.agent().worker.pending_permission_request = .{
        .label = "edit_file note.txt",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = &path,
                .lines = &lines,
                .additions = 1,
                .deletions = 1,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    app.agent().worker.pending_question = true;

    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    path[0] = 'N';
    removed[0] = 'B';
    added[0] = 'A';
    lines[0].old_line = 9;

    try std.testing.expect(app.agent().stream.active);
    try std.testing.expect(app.agent().approval_prompt.isActive());
    try std.testing.expect(!app.agent().question_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 0), app.agent().question_prompt.sync_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
    try std.testing.expectEqualStrings(
        "edit_file note.txt",
        app.agent().approval_prompt.request.?.label,
    );
    try std.testing.expectEqualStrings(
        "note.txt",
        app.agent().approval_prompt.request.?.file.?.preview.path,
    );
    try std.testing.expectEqualStrings(
        "before",
        app.agent().approval_prompt.request.?.file.?.preview.lines[0].text,
    );
    try std.testing.expectEqual(
        @as(?u32, 2),
        app.agent().approval_prompt.request.?.file.?.preview.lines[0].old_line,
    );
    try std.testing.expect(app.agent().approval_prompt.review == &review);
    try std.testing.expectEqual(
        app.agent().approval_prompt.request.?.id,
        app.agent().approval_prompt.review_request_id,
    );

    const approval_id = app.agent().approval_prompt.request.?.id;
    app.approval_screen.scrollDocument(4);
    app.approval_screen.recordScreenCommit(approval_id, .{
        .request_id = approval_id,
        .rows = 24,
        .cols = 80,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });
    app.agent().worker.pending_permission_review = &replacement_review;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(app.agent().approval_prompt.review == &replacement_review);
    try std.testing.expectEqual(@as(usize, 0), app.approval_screen.document_scroll_rows);
    try std.testing.expect(app.approval_screen.screen_commit == null);

    app.shell.render_requests.clearReason(.footer);
    app.shell.render_requests.clearReason(.modal);
    app.agent().worker.processing = false;
    app.agent().worker.pending_permission_request = null;
    app.agent().worker.pending_question = false;
    app.agent().question_prompt.active = true;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(!app.agent().approval_prompt.isActive());
    try std.testing.expect(!app.agent().question_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 1), app.agent().question_prompt.clear_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "core.app_worker_runtime syncState clears a completed approval" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().worker.pending_permission_request = .{
        .id = 42,
        .label = "shell.run test",
    };
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    try std.testing.expect(app.agent().approval_prompt.isActive());

    app.agent().worker.processing = false;
    app.agent().worker.pending_permission_request = null;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().approval_prompt.isActive());
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "core.app_worker_runtime syncState freezes the turn clock while an approval waits" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    // A turn is processing when an approval opens: the elapsed clock must
    // freeze so approval wait time is not counted as thinking.
    app.agent().worker.processing = true;
    app.agent().worker.pending_permission_request = .{
        .id = 7,
        .label = "shell.run test",
    };
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    try std.testing.expect(app.agent().approval_prompt.isActive());
    try std.testing.expect(app.agent().stream.active);
    try std.testing.expect(app.agent().stream.waiting_since_ms > 0);

    // Approval resolved but the turn keeps processing: the freeze releases and
    // the running clock resumes with no wait state left behind.
    app.agent().worker.pending_permission_request = null;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    try std.testing.expect(!app.agent().approval_prompt.isActive());
    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(@as(i64, 0), app.agent().stream.waiting_since_ms);
}

test "core.app_worker_runtime emits permission attention once when approval opens" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().worker.active_turn_id = 73;

    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    try std.testing.expectEqual(@as(usize, 0), app.attention_count);

    app.agent().worker.pending_permission_request = .{
        .id = 1,
        .label = "run command",
    };
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    try std.testing.expectEqual(@as(usize, 1), app.attention_count);
    try std.testing.expectEqual(@as(u64, 73), app.last_attention_turn_id);
    try std.testing.expectEqual(
        @as(?@import("../hooks/hooks.zig").AttentionKind, .permission),
        app.last_attention_kind,
    );

    app.agent().worker.pending_permission_request = .{
        .id = 2,
        .label = "replacement",
    };
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));
    try std.testing.expectEqual(@as(usize, 1), app.attention_count);
}

test "core.app_worker_runtime emits question and route recovery attention only for active prompts" {
    const cases = [_]struct {
        source: worker_runtime.QuestionPromptSource,
        expected: @import("../hooks/hooks.zig").AttentionKind,
    }{
        .{ .source = .agent_question, .expected = .question },
        .{ .source = .mcp_elicitation, .expected = .question },
        .{ .source = .route_recovery, .expected = .route_recovery },
    };

    for (cases) |case| {
        var app = FakeApp.init(std.testing.allocator);
        defer app.deinit();
        app.agent().worker.processing = true;
        app.agent().worker.active_turn_id = 81;
        app.agent().worker.pending_question = true;
        app.agent().worker.pending_question_source = case.source;
        try app.agent().worker.pushEvent(std.heap.c_allocator, .question_requested);
        try app.agent().worker.pushEvent(std.heap.c_allocator, .question_requested);

        try Runtime(FakeApp).tick(&app, (&app).agent(), NoopBridge.handlers(&app));

        try std.testing.expectEqual(@as(usize, 1), app.attention_count);
        try std.testing.expectEqual(@as(u64, 81), app.last_attention_turn_id);
        try std.testing.expectEqual(@as(?@import("../hooks/hooks.zig").AttentionKind, case.expected), app.last_attention_kind);
    }

    var invalid = FakeApp.init(std.testing.allocator);
    defer invalid.deinit();
    invalid.agent().worker.processing = true;
    invalid.agent().worker.pending_question = true;
    invalid.agent().question_prompt.activate_on_sync = false;
    try invalid.agent().worker.pushEvent(std.heap.c_allocator, .question_requested);
    try Runtime(FakeApp).tick(&invalid, (&invalid).agent(), NoopBridge.handlers(&invalid));
    try std.testing.expectEqual(@as(usize, 0), invalid.attention_count);
}

test "core.app_worker_runtime syncState clears a completed question" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().question_prompt.active = true;
    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().question_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 1), app.agent().question_prompt.clear_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "core.app_worker_runtime cancellation ignores late tool progress before turn finalization" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "visible-call" };
    try queueToolStart(&app, lifecycle_id.turn_id, lifecycle_id.call_id, "read_file");
    try tickNoop(&app);
    const entry_id = app.shell.toolActivityRecord(lifecycle_id).?.entry_id;
    const label_before = try std.testing.allocator.dupe(
        u8,
        app.shell.toolStatusEntryLabel(entry_id) orelse return error.TestExpectedEqual,
    );
    defer std.testing.allocator.free(label_before);

    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    try queueLifecycle(&app, .{ .progress = .{
        .id = lifecycle_id,
        .text = "late progress",
    } });
    try tickNoop(&app);

    const label_after = app.shell.toolStatusEntryLabel(entry_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(label_before, label_after);
}

test "core.app_worker_runtime cancellation defers split tool lifecycle until terminal closure" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);

    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "late-call" };
    try queueToolStart(&app, lifecycle_id.turn_id, lifecycle_id.call_id, "read_file");
    try tickNoop(&app);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());

    try queueLifecycle(&app, .{ .progress = .{
        .id = lifecycle_id,
        .text = "late progress",
    } });
    try tickNoop(&app);
    try std.testing.expectEqual(@as(usize, 2), app.agent().worker.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());

    try queueToolTerminal(&app, lifecycle_id.turn_id, lifecycle_id.call_id, .cancelled, "Cancelled read");
    try tickNoop(&app);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
    const entry_id = app.shell.toolActivityRecord(lifecycle_id).?.entry_id;
    const label = app.shell.toolStatusEntryLabel(entry_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.find(u8, label, "Cancelled read") != null);
    try std.testing.expect(std.mem.find(u8, label, "late progress") == null);

    try queueTurnFinished(&app, lifecycle_id.turn_id, .interrupted);
    try tickNoop(&app);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecyclePinCount());
}

test "core.app_worker_runtime cancellation drops tool starts after interrupted turn finalization" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);

    try queueTurnFinished(&app, 1, .interrupted);
    try tickNoop(&app);
    try std.testing.expectEqual(@as(u64, 1), app.shell.finalizedToolTurnWatermark());

    try queueToolStart(&app, 1, "late-call", "read_file");
    try tickNoop(&app);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
}

test "core.app_worker_runtime cancellation admits terminal closure for visible tool" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "visible-call" };
    try queueToolStart(&app, lifecycle_id.turn_id, lifecycle_id.call_id, "read_file");
    try tickNoop(&app);
    const entry_id = app.shell.toolActivityRecord(lifecycle_id).?.entry_id;

    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    try queueToolTerminal(&app, lifecycle_id.turn_id, lifecycle_id.call_id, .cancelled, "Cancelled read");
    try queueTurnFinished(&app, lifecycle_id.turn_id, .interrupted);
    try tickNoop(&app);

    const label = app.shell.toolStatusEntryLabel(entry_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.find(u8, label, "Cancelled read") != null);
}

test "core.app_worker_runtime cancellation suppresses payloads but retains turn finalization" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);

    try queueToolStart(&app, 1, "call", "read_file");
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
        .text = @constCast("hidden"),
    } });
    try queueToolTerminal(&app, 1, "call", .cancelled, "Cancelled read");
    try queueTurnFinished(&app, 1, .interrupted);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{
        .turn = .{ .compacted_summary = .{
            .summary = @constCast("history"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
    } });

    const Capture = struct {
        text_count: usize = 0,
        history_count: usize = 0,

        fn text(raw: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.text_count += 1;
        }

        fn history(raw: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.history_count += 1;
            return .{ .settled = .committed };
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.append_text = Capture.text;
    handlers.append_history_turn = Capture.history;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 0), capture.text_count);
    try std.testing.expectEqual(@as(usize, 1), capture.history_count);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecyclePinCount());
    try std.testing.expectEqual(@as(u64, 1), app.shell.finalizedToolTurnWatermark());
}

test "core.app_worker_runtime cancellation snapshot stays coupled to detached event prefix" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    app.agent().worker.reset_cancel_after_take_events = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
        .text = @constCast("late text"),
    } });

    const Capture = struct {
        text_count: usize = 0,

        fn text(raw: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.text_count += 1;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.append_text = Capture.text;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expect(!app.agent().worker.worker_cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), capture.text_count);
}

test "core.app_worker_runtime publishes rendered block before opening tool entries" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("assistant before tools") },
    });
    try queueLifecycle(&app, .{ .provisional = .{
        .id = .{ .turn_id = 1, .call_id = "read_a" },
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try queueToolStart(&app, 1, "grep_b", "grep");

    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 2), bridge.drain_count);
    try std.testing.expect(!bridge.pacer.hasPending());
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expect(app.shell.lifecycle.notebook.entries.items[0] == .assistant_turn);
    try std.testing.expect(app.shell.lifecycle.notebook.entries.items[1] == .raw_bytes);
    try std.testing.expect(app.shell.lifecycle.notebook.entries.items[2] == .raw_bytes);
    try std.testing.expectEqualStrings(
        "assistant before tools",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.tool_status,
        app.shell.lifecycle.notebook.entries.items[1].raw_bytes.class,
    );
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.tool_status,
        app.shell.lifecycle.notebook.entries.items[2].raw_bytes.class,
    );
    try std.testing.expectEqualStrings(
        "● read_file\x1b[0m\n",
        app.shell.lifecycle.notebook.entries.items[1].raw_bytes.bytes,
    );
    try std.testing.expectEqualStrings(
        "● grep\x1b[0m\n",
        app.shell.lifecycle.notebook.entries.items[2].raw_bytes.bytes,
    );
    try std.testing.expectEqual(@as(usize, 2), app.shell.lifecyclePinCount());
}

test "core.app_worker_runtime structural separator preserves running phase during tool composition" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().stream = .{
        .active = true,
        .phase = .running,
    };

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("\n") },
    });

    try tickNoop(&app);

    try std.testing.expectEqual(types.TurnPhase.running, app.agent().stream.phase);
}

test "core.app_worker_runtime provisional tool start switches generating to running" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().stream = .{
        .active = true,
        .phase = .generating,
    };

    try queueLifecycle(&app, .{ .provisional = .{
        .id = .{ .turn_id = 1, .call_id = "read_a" },
        .tool_name = "read_file",
        .activity_kind = .read,
    } });

    try tickNoop(&app);

    try std.testing.expectEqual(types.TurnPhase.running, app.agent().stream.phase);
    try std.testing.expectEqual(
        @as(?types.ToolActivityKind, .read),
        app.agent().stream.last_activity_kind,
    );
}

test "core.app_worker_runtime lifecycle boundary survives an incomplete assistant ANSI tail exactly once" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("visible\x1b[1") },
    });
    try queueToolStart(&app, 1, "read_a", "read_file");

    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 1), bridge.drain_count);
    try std.testing.expectEqual(@as(usize, 2), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expect(app.shell.lifecycle.notebook.entries.items[0] == .assistant_turn);
    try std.testing.expect(app.shell.lifecycle.notebook.entries.items[1] == .raw_bytes);
    try std.testing.expectEqual(@as(usize, 1), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecyclePinCount());
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

test "app worker drains prior paced batch without splitting assistant turn" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("paced before start") },
    });
    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());
    try bridge.tickPacer(0);

    try std.testing.expect(!bridge.pacer.hasPending());
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expectEqualStrings(
        "paced before start",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );

    try queueToolStart(&app, 1, "later", "read_file");
    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 1), bridge.drain_count);
    try std.testing.expectEqual(@as(usize, 2), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expectEqualStrings(
        "paced before start",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.tool_status,
        app.shell.lifecycle.notebook.entries.items[1].raw_bytes.class,
    );
    try std.testing.expect(!bridge.pacer.hasPending());
}

test "core.app_worker_runtime question boundary drains paced text before opening the prompt" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("paced before question") },
    });
    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());
    try bridge.tickPacer(0);
    try std.testing.expect(!bridge.pacer.hasPending());

    app.agent().worker.pending_question = true;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .question_requested);
    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 1), bridge.drain_count);
    try std.testing.expect(app.agent().question_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 1), app.agent().question_prompt.sync_count);
    try std.testing.expect(!bridge.pacer.hasPending());
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expectEqualStrings(
        "paced before question",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );
}

test "core.app_worker_runtime prompt boundary drains paced text before writing the user card" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("paced before prompt") },
    });
    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());
    try bridge.tickPacer(0);
    try std.testing.expect(!bridge.pacer.hasPending());

    app.agent().stream = .{
        .active = true,
        .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
    };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .begin_prompt = try types.dupeUserTurn(std.heap.c_allocator, .{
            .text = @constCast("next prompt"),
            .images = &.{},
        }),
    });
    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 1), bridge.drain_count);
    try std.testing.expectEqual(@as(usize, 1), bridge.user_prompt_count);
    try std.testing.expect(!bridge.pacer_pending_when_user_prompt_written);
    try std.testing.expect(!bridge.pacer.hasPending());
    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(types.TurnTokenProgress{}, app.agent().stream.token_progress);
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expectEqualStrings(
        "paced before prompt",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );
}

test "core.app_worker_runtime feedback boundary drains paced text before writing the user card" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().stream = .{ .active = true, .phase = .generating };
    app.shell.render_requests.clearReason(.footer);

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("cancelled response tail") },
    });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .append_user_feedback = @constCast("steer now"),
    });

    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 1), bridge.drain_count);
    try std.testing.expectEqual(@as(usize, 1), bridge.user_prompt_count);
    try std.testing.expect(!bridge.pacer_pending_when_user_prompt_written);
    try std.testing.expect(bridge.assistant_present_when_user_prompt_written);
    try std.testing.expect(!bridge.pacer.hasPending());
    try std.testing.expectEqual(types.TurnPhase.thinking, app.agent().stream.phase);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expectEqualStrings(
        "cancelled response tail",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );
}

test "core.app_worker_runtime blocked prompt drain retains the prompt before reset or write" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().stream = .{
        .active = true,
        .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
    };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .begin_prompt = try types.dupeUserTurn(std.heap.c_allocator, .{
            .text = @constCast("next prompt"),
            .images = &.{},
        }),
    });

    const Capture = struct {
        drain_count: usize = 0,
        user_prompt_count: usize = 0,

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.drain_count += 1;
            return if (self.drain_count == 1) .blocked else .drained;
        }

        fn writeUserPrompt(raw: *anyopaque, _: types.UserTurn) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.user_prompt_count += 1;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;
    handlers.write_user_prompt = Capture.writeUserPrompt;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);
    try std.testing.expectEqual(@as(usize, 1), capture.drain_count);
    try std.testing.expectEqual(@as(usize, 0), capture.user_prompt_count);
    try std.testing.expectEqual(@as(u64, 10), app.agent().stream.token_progress.input_tokens);
    try std.testing.expectEqual(@as(u64, 20), app.agent().stream.token_progress.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.events.items.len);
    try std.testing.expect(app.agent().worker.events.items[0] == .begin_prompt);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);
    try std.testing.expectEqual(@as(usize, 2), capture.drain_count);
    try std.testing.expectEqual(@as(usize, 1), capture.user_prompt_count);
    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(types.TurnTokenProgress{}, app.agent().stream.token_progress);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

test "core.app_worker_runtime lifecycle updates and turn finalization do not drain paced text" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    try queueToolStart(&app, 1, "call", "read_file");
    try tickNoop(&app);

    const Capture = struct {
        drain_count: usize = 0,

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.drain_count += 1;
            return .drained;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;

    try queueLifecycle(&app, .{ .progress = .{
        .id = .{ .turn_id = 1, .call_id = "call" },
        .text = "Reading",
    } });
    try queueToolTerminal(&app, 1, "call", .completed, "Read");
    try queueTurnFinished(&app, 1, .completed);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 0), capture.drain_count);
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecyclePinCount());
}

test "core.app_worker_runtime blocked assistant drain retains current event and suffix in order" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try queueToolStart(&app, 1, "blocked", "read_file");
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .semantic_notice = .{
        .topic = "system",
        .tone = .information,
        .body = "notice",
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .semantic_notice = .{
        .topic = "context",
        .tone = .warning,
        .body = "context",
        .visibility = .full_only,
    } });

    const Capture = struct {
        drain_count: usize = 0,
        notice_count: usize = 0,
        context_notice_count: usize = 0,

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.drain_count += 1;
            return if (self.drain_count == 1) .blocked else .drained;
        }

        fn notice(raw: *anyopaque, notice_value: types.SemanticNotice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.notice_count += 1;
            if (notice_value.visibility == .full_only) self.context_notice_count += 1;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;
    handlers.semantic_notice = Capture.notice;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);
    try std.testing.expectEqual(@as(usize, 0), capture.notice_count);
    try std.testing.expectEqual(@as(usize, 0), capture.context_notice_count);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 3), app.agent().worker.events.items.len);
    try std.testing.expect(app.agent().worker.events.items[0] == .tool_lifecycle);
    try std.testing.expect(app.agent().worker.events.items[1] == .semantic_notice);
    try std.testing.expect(app.agent().worker.events.items[2] == .semantic_notice);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, app.agent().worker.events.items[2].semantic_notice.visibility);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 2), capture.notice_count);
    try std.testing.expectEqual(@as(usize, 1), capture.context_notice_count);
    try std.testing.expectEqual(@as(usize, 1), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecyclePinCount());
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

test "core.app_worker_runtime retains a thematic rule until paced text drains" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .thematic_rule,
    });

    const Capture = struct {
        drain_count: usize = 0,
        rule_count: usize = 0,

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.drain_count += 1;
            return if (self.drain_count == 1) .blocked else .drained;
        }

        fn appendThematicRule(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rule_count += 1;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;
    handlers.append_thematic_rule = Capture.appendThematicRule;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);
    try std.testing.expectEqual(@as(usize, 0), capture.rule_count);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.events.items.len);
    try std.testing.expect(app.agent().worker.events.items[0] == .assistant_presentation);
    try std.testing.expect(app.agent().worker.events.items[0].assistant_presentation == .thematic_rule);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);
    try std.testing.expectEqual(@as(usize, 1), capture.rule_count);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

test "core.app_worker_runtime model picker event drains before one callback and modal request" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const Capture = struct {
        app: *FakeApp,
        order: [2]u8 = undefined,
        order_len: usize = 0,
        open_count: usize = 0,

        fn record(self: *@This(), value: u8) void {
            self.order[self.order_len] = value;
            self.order_len += 1;
        }

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.record('D');
            return .drained;
        }

        fn open(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(!self.app.shell.render_requests.hasReason(.modal));
            self.open_count += 1;
            self.record('O');
        }
    };

    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;
    handlers.open_model_picker = Capture.open;
    try app.agent().worker.pushEvent(std.heap.c_allocator, .open_model_picker);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqualStrings("DO", capture.order[0..capture.order_len]);
    try std.testing.expectEqual(@as(usize, 1), capture.open_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "core.app_worker_runtime assistant drain preserves callback errors before lifecycle reduction" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try queueToolStart(&app, 1, "emit-failure", "read_file");
    var handlers = NoopBridge.handlers(&app);
    handlers.drain_assistant_text = struct {
        fn drain(_: *anyopaque) !AssistantTextDrainResult {
            return error.InjectedPacerEmitFailure;
        }
    }.drain;

    try std.testing.expectError(
        error.InjectedPacerEmitFailure,
        Runtime(FakeApp).tick(&app, (&app).agent(), handlers),
    );
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecycle.notebook.entries.items.len);
}

test "core.app_worker_runtime semantic notice handler failure returns through drain cleanup" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    try app.agent().worker.pushEvent(
        std.heap.c_allocator,
        .{ .semantic_notice = .{
            .topic = "permissions",
            .tone = .success,
            .body = "approval",
            .visibility = .full_only,
        } },
    );
    try app.agent().worker.pushEvent(
        std.heap.c_allocator,
        .{ .semantic_notice = .{
            .topic = "system",
            .tone = .information,
            .body = "unvisited suffix",
        } },
    );

    const Capture = struct {
        suffix_count: usize = 0,

        fn notice(raw: *anyopaque, notice_value: types.SemanticNotice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, notice_value.body, "approval")) {
                try std.testing.expectEqual(types.NoticeVisibility.full_only, notice_value.visibility);
                return error.InjectedSemanticNoticeTranscriptFailure;
            }
            self.suffix_count += 1;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.semantic_notice = Capture.notice;

    try std.testing.expectError(
        error.InjectedSemanticNoticeTranscriptFailure,
        Runtime(FakeApp).tick(&app, (&app).agent(), handlers),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.suffix_count);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

test "core.app_worker_runtime text turn finishes after its rendered block" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("slow") },
    });
    try queueTurnFinished(&app, 1, .completed);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{
        .turn = .{ .compacted_summary = .{
            .summary = @constCast("history"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
    } });

    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqual(@as(usize, 0), bridge.drain_count);
    try std.testing.expectEqual(@as(usize, 1), bridge.history_count);
    try std.testing.expectEqual(@as(usize, 0), bridge.finish_count);
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecycle.notebook.entries.items.len);
    try std.testing.expect(bridge.pacer.hasPending());
    try std.testing.expect(bridge.pacer.deferred_turn != null);

    try bridge.tickPacer(0);
    try std.testing.expectEqualStrings(
        "slow",
        app.shell.lifecycle.notebook.entries.items[0].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(@as(usize, 1), bridge.finish_count);
    try std.testing.expect(bridge.pacer.deferred_turn == null);
    try std.testing.expect(!bridge.pacer.hasPending());
}

test "core.app_worker_runtime queued begin waits for deferred completed turn summary" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    var bridge = PacedTranscriptBridge.init(&app);
    defer bridge.deinit();

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .assistant_presentation = .{ .text = @constCast("prior answer") },
    });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prior prompt"), .images = &.{} },
            .assistant = @constCast("prior answer"),
        } },
        .summary = .{
            .thinking_duration_ms = 1_000,
            .turn_duration_ms = 2_000,
            .token_progress = .{ .output_tokens = 3 },
        },
        .terminal_outcome = .completed,
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .begin_prompt = .{ .text = @constCast("queued prompt"), .images = &.{} },
    });

    try Runtime(FakeApp).tick(&app, (&app).agent(), bridge.handlers());

    try std.testing.expectEqualStrings("FU", bridge.orderSlice());
    try std.testing.expectEqual(@as(usize, 1), bridge.finish_count);
    try std.testing.expectEqual(@as(usize, 1), bridge.user_prompt_count);
    try std.testing.expect(!bridge.pacer_pending_when_user_prompt_written);
    try std.testing.expect(!bridge.pacer.hasPending());
}

test "core.app_worker_runtime split batches finalize lifecycle before history" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    try queueToolStart(&app, 1, "split", "read_file");
    try queueToolTerminal(&app, 1, "split", .completed, "Read");
    try queueTurnFinished(&app, 1, .completed);
    try tickNoop(&app);

    try std.testing.expectEqual(@as(u64, 1), app.shell.finalizedToolTurnWatermark());
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecyclePinCount());

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{
        .turn = .{ .compacted_summary = .{
            .summary = @constCast("history"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
    } });
    const Capture = struct {
        app: *FakeApp,
        history_count: usize = 0,
        saw_finalized_fence: bool = false,

        fn history(raw: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.history_count += 1;
            self.saw_finalized_fence =
                self.app.shell.finalizedToolTurnWatermark() == 1 and
                self.app.shell.toolActivityRecordCount() == 0 and
                self.app.shell.lifecyclePinCount() == 0;
            return .{ .settled = .committed };
        }
    };
    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.append_history_turn = Capture.history;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 1), capture.history_count);
    try std.testing.expect(capture.saw_finalized_fence);
}

test "core.app_worker_runtime reset before drain fences interrupted prefix and keeps next turn live" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);

    try queueToolStart(&app, 1, "cancelled", "read_file");
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
        .text = @constCast("late turn one"),
    } });
    try queueToolTerminal(&app, 1, "cancelled", .cancelled, "Cancelled");
    try queueTurnFinished(&app, 1, .interrupted);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = try types.dupeUserTurn(
        std.heap.c_allocator,
        .{ .text = @constCast("next"), .images = &.{} },
    ) });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
        .text = @constCast("turn two"),
    } });
    try queueToolStart(&app, 2, "active", "run_command");

    const Capture = struct {
        late_text_seen: bool = false,
        next_text_seen: bool = false,

        fn text(raw: *anyopaque, value: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, value, "late turn one")) self.late_text_seen = true;
            if (std.mem.eql(u8, value, "turn two")) self.next_text_seen = true;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.append_text = Capture.text;

    app.agent().worker.worker_cancel_requested.store(false, .seq_cst);
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expect(!capture.late_text_seen);
    try std.testing.expect(capture.next_text_seen);
    try std.testing.expect(
        app.shell.toolActivityRecord(.{ .turn_id = 1, .call_id = "cancelled" }) == null,
    );
    try std.testing.expect(
        app.shell.toolActivityRecord(.{ .turn_id = 2, .call_id = "active" }) != null,
    );
    try std.testing.expectEqual(@as(usize, 1), app.shell.activeToolActivityCount());
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecyclePinCount());
    try std.testing.expectEqual(types.ToolActivityKind.command, app.agent().stream.last_activity_kind.?);
}

test "core.app_worker_runtime reducer error settles batch and skips suffix" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    try queueToolStart(&app, 1, "call", "read_file");
    try queueLifecycle(&app, .{ .progress = .{
        .id = .{ .turn_id = 1, .call_id = "call" },
        .text = "Reading",
    } });
    try queueToolTerminal(&app, 1, "call", .completed, "Read");
    app.shell.fail_next_update = true;

    try std.testing.expectError(
        error.InjectedTranscriptUpdateFailure,
        tickNoop(&app),
    );

    const record = app.shell.toolActivityRecord(.{ .turn_id = 1, .call_id = "call" }).?;
    try std.testing.expectEqual(activity_runtime.ToolLifecyclePhase.authoritative, record.phase);
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecyclePinCount());
}

test "core.app_worker_runtime cancellation leaves an earlier completed segment drainable" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().worker.active_turn_id = 2;
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    try queueToolStart(&app, 1, "completed-call", "read_file");
    try queueToolTerminal(&app, 1, "completed-call", .completed, "Read");
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{ .text = @constCast("earlier completed answer") } });
    try queueTurnFinished(&app, 1, .completed);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = .{ .text = @constCast("later request") } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .turn_phase_update = .{ .turn_id = 2, .step_id = 1, .phase = .thinking } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{ .text = @constCast("cancelled later answer") } });
    try queueTurnFinished(&app, 2, .interrupted);
    const Capture = struct {
        fn text(raw: *anyopaque, bytes: []const u8) !void {
            const target: *FakeApp = @ptrCast(@alignCast(raw));
            try target.transcript.appendSlice(target.alloc, bytes);
        }
    };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = &app;
    handlers.append_text = Capture.text;
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "earlier completed answer") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "cancelled later answer") == null);
}

test "core.app_worker_runtime reducer failure preserves a completed turn in the suffix" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    try queueToolStart(&app, 1, "call", "read_file");
    try queueLifecycle(&app, .{ .progress = .{
        .id = .{ .turn_id = 1, .call_id = "call" },
        .text = "Reading",
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .assistant = .{
        .user = .{ .text = @constCast("accepted request") },
        .assistant = @constCast("completed answer"),
    } } } });
    app.shell.fail_next_update = true;
    try std.testing.expectError(error.InjectedTranscriptUpdateFailure, tickNoop(&app));
    try std.testing.expectEqual(@as(usize, 1), app.persisted_finishes.items.len);
    try std.testing.expectEqualStrings("completed answer", app.persisted_finishes.items[0].turn.assistant.assistant);
}

test "core.app_worker_runtime failed turn terminalizes tool lifecycle before error text" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().stream.active = true;
    try queueToolStart(&app, 1, "call_1", "read_file");
    try queueLifecycle(&app, .{ .progress = .{
        .id = .{ .turn_id = 1, .call_id = "call_1" },
        .text = "● Reading",
    } });

    try tickNoop(&app);
    const entry_id = app.shell.focusedToolEntryId().?;

    try queueTurnFinished(&app, 1, .failed);
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed",
    } });
    app.agent().worker.processing = false;

    try tickNoop(&app);

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(app.agent().stream.last_activity_kind == null);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 0), app.shell.lifecyclePinCount());
    var failed_status_expected: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.mem.print(
            &failed_status_expected,
            "{s}●{s} Tool failed",
            .{ ui_render.red_style, reset_style },
        ),
        app.shell.toolStatusEntryLabel(entry_id).?,
    );
}

test "core.app_worker_runtime error text resets active stream and requests footer" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const Capture = struct {
        app: *FakeApp,
        drain_count: usize = 0,
        saw_reset_stream: bool = false,
        saw_footer_request: bool = false,
        error_saw_drain: bool = false,

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.drain_count += 1;
            return .drained;
        }

        fn errorText(raw: *anyopaque, _: types.SemanticNotice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.error_saw_drain = self.drain_count == 1;
            self.saw_reset_stream =
                !self.app.agent().stream.active and
                self.app.agent().stream.last_activity_kind == null;
            self.saw_footer_request =
                self.app.shell.render_requests.hasReason(.footer);
        }
    };
    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;
    handlers.error_text = Capture.errorText;

    app.agent().worker.processing = true;
    app.agent().stream = .{
        .active = true,
        .phase = .generating,
        .last_activity_kind = .ask,
    };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed",
    } });

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 1), capture.drain_count);
    try std.testing.expect(capture.error_saw_drain);
    try std.testing.expect(capture.saw_reset_stream);
    try std.testing.expect(capture.saw_footer_request);
    try std.testing.expect(!app.shell.render_requests.blocksFrameCommit());
}

test "core.app_worker_runtime blocked error drain retains the error and suffix in order" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const Capture = struct {
        drain_count: usize = 0,
        error_count: usize = 0,
        feedback_count: usize = 0,

        fn drain(raw: *anyopaque) !AssistantTextDrainResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.drain_count += 1;
            return if (self.drain_count == 1) .blocked else .drained;
        }

        fn errorText(raw: *anyopaque, _: types.SemanticNotice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.error_count += 1;
            try std.testing.expectEqual(@as(usize, 2), self.drain_count);
        }

        fn feedback(raw: *anyopaque, _: types.UserTurn) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.feedback_count += 1;
            try std.testing.expectEqual(@as(usize, 1), self.error_count);
            try std.testing.expectEqual(@as(usize, 3), self.drain_count);
        }
    };

    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.drain_assistant_text = Capture.drain;
    handlers.error_text = Capture.errorText;
    handlers.write_user_prompt = Capture.feedback;

    app.agent().worker.processing = true;
    app.agent().stream = .{
        .active = true,
        .phase = .generating,
        .last_activity_kind = .ask,
    };
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed",
    } });
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .append_user_feedback = @constCast("after error"),
    });

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 1), capture.drain_count);
    try std.testing.expectEqual(@as(usize, 0), capture.error_count);
    try std.testing.expectEqual(@as(usize, 0), capture.feedback_count);
    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(@as(usize, 2), app.agent().worker.events.items.len);
    try std.testing.expect(app.agent().worker.events.items[0] == .error_text);
    try std.testing.expect(app.agent().worker.events.items[1] == .append_user_feedback);

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 3), capture.drain_count);
    try std.testing.expectEqual(@as(usize, 1), capture.error_count);
    try std.testing.expectEqual(@as(usize, 1), capture.feedback_count);
    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

test "core.app_worker_runtime tick drains events and updates thinking state" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    app.agent().worker.processing = true;
    app.agent().stream.active = true;
    try queueToolStart(&app, 1, "command", "run_command");
    try queueToolStart(&app, 1, "read", "read_file");

    try tickNoop(&app);

    try std.testing.expect(app.agent().stream.active);
    try std.testing.expectEqual(@as(usize, 2), app.agent().stream.chunks);
    try std.testing.expectEqual(@as(usize, 1), app.agent().stream.command_count);
    try std.testing.expectEqual(@as(usize, 1), app.agent().stream.read_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_worker_runtime writes queued approval feedback after a tool terminal without reset" {
    const Capture = struct {
        app: *FakeApp,
        user_count: usize = 0,
        saw_feedback: bool = false,
        stream_remained_active: bool = false,

        fn user(raw: *anyopaque, prompt: types.UserTurn) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.user_count += 1;
            self.saw_feedback = std.mem.eql(u8, prompt.text, "read it after writing");
            self.stream_remained_active = self.app.agent().stream.active and
                self.app.agent().stream.token_progress.output_tokens == 7;
        }
    };

    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.agent().stream = .{ .active = true, .token_progress = .{ .output_tokens = 7 } };
    try queueToolStart(&app, 1, "call_feedback", "write_file");
    try queueToolTerminal(&app, 1, "call_feedback", .completed, "Wrote note.txt");
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{
        .append_user_feedback = @constCast("read it after writing"),
    });

    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.write_user_prompt = Capture.user;
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 1), capture.user_count);
    try std.testing.expect(capture.saw_feedback);
    try std.testing.expect(capture.stream_remained_active);
}

test "core.app_worker_runtime drains diff block through bridge handler" {
    const c_alloc = std.heap.c_allocator;
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try Runtime(FakeApp).pushDiffBlock(&app, (&app).agent(), .{
        .preview = try c_alloc.dupe(u8, "diff preview"),
    });

    const Capture = struct {
        diff_count: usize = 0,
        preview_buf: std.ArrayList(u8) = .empty,
        payload: ?diff_mod.DiffEntryPayload = null,

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            if (self.payload) |payload| diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
            self.preview_buf.deinit(alloc);
        }

        fn user(_: *anyopaque, _: types.UserTurn) !void {}
        fn text(_: *anyopaque, _: []const u8) !void {}
        fn notice(_: *anyopaque, _: types.SemanticNotice) !void {}
        fn output(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) !void {}
        fn outputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
        fn diff(raw: *anyopaque, payload: diff_mod.DiffEntryPayload) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.diff_count += 1;
            self.payload = payload;
            try self.preview_buf.appendSlice(std.testing.allocator, payload.preview);
        }
        fn history(_: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
            return .{ .settled = .committed };
        }
        fn grant(_: *anyopaque, _: types.PermissionGrant) !void {}
        fn err(_: *anyopaque, _: types.SemanticNotice) !void {}
    };
    var capture = Capture{};
    defer capture.deinit(std.testing.allocator);

    try Runtime(FakeApp).tick(&app, (&app).agent(), .{
        .ctx = @ptrCast(&capture),
        .tool_lifecycle = NoopBridge.lifecyclePresenter(&app),
        .write_user_prompt = Capture.user,
        .append_text = Capture.text,
        .drain_assistant_text = NoopBridge.drain,
        .open_model_picker = NoopBridge.openModelPicker,
        .semantic_notice = Capture.notice,
        .command_output = Capture.output,
        .command_output_complete = Capture.outputComplete,
        .diff_block = Capture.diff,
        .append_history_turn = Capture.history,
        .session_grant = Capture.grant,
        .error_text = Capture.err,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.diff_count);
    try std.testing.expectEqualStrings("diff preview", capture.preview_buf.items);
}

test "core.app_worker_runtime failure before diff transfer leaves batch ownership intact" {
    const c_alloc = std.heap.c_allocator;
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try app.agent().worker.pushEvent(c_alloc, .{ .assistant_presentation = .{
        .text = @constCast("fail"),
    } });
    try Runtime(FakeApp).pushDiffBlock(&app, (&app).agent(), .{
        .preview = try c_alloc.dupe(u8, "diff preview"),
    });

    const Capture = struct {
        diff_count: usize = 0,

        fn text(_: *anyopaque, _: []const u8) !void {
            return error.InjectedBeforeDiffTransfer;
        }

        fn diff(raw: *anyopaque, payload: diff_mod.DiffEntryPayload) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.diff_count += 1;
            diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.append_text = Capture.text;
    handlers.diff_block = Capture.diff;

    try std.testing.expectError(
        error.InjectedBeforeDiffTransfer,
        Runtime(FakeApp).tick(&app, (&app).agent(), handlers),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.diff_count);
}

test "core.app_worker_runtime diff receiver cleans transferred payload on error" {
    const c_alloc = std.heap.c_allocator;
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try Runtime(FakeApp).pushDiffBlock(&app, (&app).agent(), .{
        .preview = try c_alloc.dupe(u8, "diff preview"),
    });
    try app.agent().worker.pushEvent(c_alloc, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "suffix",
    } });

    const Capture = struct {
        diff_count: usize = 0,
        suffix_count: usize = 0,

        fn diff(raw: *anyopaque, payload: diff_mod.DiffEntryPayload) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
            self.diff_count += 1;
            return error.InjectedAfterDiffTransfer;
        }

        fn err(raw: *anyopaque, _: types.SemanticNotice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.suffix_count += 1;
        }
    };
    var capture = Capture{};
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.diff_block = Capture.diff;
    handlers.error_text = Capture.err;

    try std.testing.expectError(
        error.InjectedAfterDiffTransfer,
        Runtime(FakeApp).tick(&app, (&app).agent(), handlers),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.diff_count);
    try std.testing.expectEqual(@as(usize, 0), capture.suffix_count);
}

test "core.app_worker_runtime records accepted command output once and drops rejected or cancelled suffix" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 5, .call_id = "cmd-5" };

    const Capture = struct {
        app: *FakeApp,
        fail_output: bool = false,
        chunk_count: usize = 0,
        completion_count: usize = 0,
        terminal_completion_count: usize = 0,

        fn matchesLifecycle(id: ?types.ToolLifecycleId) bool {
            const actual = id orelse return false;
            return actual.turn_id == 5 and std.mem.eql(u8, actual.call_id, "cmd-5");
        }

        fn output(raw: *anyopaque, id: ?types.ToolLifecycleId, stream: command_output_content.Stream, text: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fail_output) return error.InjectedCommandOutputFailure;
            const expected_streams = [_]command_output_content.Stream{ .stdout, .stderr, .stdout, .stderr };
            const expected_chunks = [_][]const u8{ "stdout-one\n", "stderr-one\n", "stdout-two\n", "stderr-two\n" };
            try std.testing.expect(self.chunk_count < expected_chunks.len);
            try std.testing.expect(matchesLifecycle(id));
            try std.testing.expectEqual(expected_streams[self.chunk_count], stream);
            try std.testing.expectEqualStrings(expected_chunks[self.chunk_count], text);
            self.chunk_count += 1;
        }

        fn outputComplete(raw: *anyopaque, id: ?types.ToolLifecycleId) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(matchesLifecycle(id));
            if (self.completion_count == 1) {
                const record = self.app.shell.toolActivityRecord(id.?) orelse return error.TestExpectedEqual;
                try std.testing.expectEqual(activity_runtime.ToolLifecyclePhase.terminal, record.phase);
                try std.testing.expectEqual(types.ToolActivityKind.command, record.activity_kind);
                self.terminal_completion_count += 1;
            }
            self.completion_count += 1;
        }
    };
    var capture = Capture{ .app = &app };

    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.command_output = Capture.output;
    handlers.command_output_complete = Capture.outputComplete;

    capture.fail_output = true;
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stdout, "rejected\n");
    try std.testing.expectError(
        error.InjectedCommandOutputFailure,
        Runtime(FakeApp).tick(&app, (&app).agent(), handlers),
    );
    try std.testing.expect(app.agent().session_persistence.pending_cancelled_command == null);

    capture.fail_output = false;
    try queueToolStart(&app, lifecycle_id.turn_id, lifecycle_id.call_id, "run_command");
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stdout, "stdout-one\n");
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stderr, "stderr-one\n");
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stdout, "stdout-two\n");
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stderr, "stderr-two\n");
    try Runtime(FakeApp).pushCommandOutputComplete(&app, (&app).agent(), lifecycle_id);
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 4), capture.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), capture.completion_count);
    try std.testing.expect(app.agent().session_persistence.pending_cancelled_command == null);

    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stdout, "late-stdout\n");
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stderr, "late-stderr\n");
    try Runtime(FakeApp).pushCommandOutputComplete(&app, (&app).agent(), lifecycle_id);
    try Runtime(FakeApp).pushCommandOutputComplete(&app, (&app).agent(), null);
    try Runtime(FakeApp).pushCommandOutputComplete(&app, (&app).agent(), .{ .turn_id = 5, .call_id = "other" });
    try queueToolTerminal(&app, lifecycle_id.turn_id, lifecycle_id.call_id, .cancelled, "Cancelled run_command");
    try Runtime(FakeApp).pushCommandOutputComplete(&app, (&app).agent(), lifecycle_id);
    try queueTurnFinished(&app, lifecycle_id.turn_id, .interrupted);
    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 4), capture.chunk_count);
    try std.testing.expectEqual(@as(usize, 2), capture.completion_count);
    try std.testing.expectEqual(@as(usize, 1), capture.terminal_completion_count);
    try std.testing.expectEqual(@as(usize, 0), app.shell.toolActivityRecordCount());
}

test "core.app_worker_runtime finalizes open command output at the turn boundary" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 6,
        .call_id = "boundary-command",
    };
    var metrics: types.Metrics = .{};
    const styles: transcript_runtime.Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    try app.shell.lifecycle.writeCommandOutputChunkForLifecycle(
        app.alloc,
        &metrics,
        styles,
        lifecycle_id,
        .stdout,
        "retained output\n",
        true,
    );

    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{
        .turn = .{ .compacted_summary = .{
            .summary = @constCast("finished"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
    } });

    const Capture = struct {
        app: *FakeApp,
        metrics: types.Metrics = .{},
        completions: usize = 0,

        fn outputComplete(
            raw: *anyopaque,
            id: ?types.ToolLifecycleId,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.completions += 1;
            try self.app.shell.lifecycle.flushCommandOutputSummaryForLifecycle(
                self.app.alloc,
                &self.metrics,
                .{
                    .system_notice_label_style = "",
                    .system_notice_text_style = "",
                    .reset_style = "",
                    .dim_style = "",
                    .red_style = "",
                },
                id,
                true,
            );
        }
    };
    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.command_output_complete = Capture.outputComplete;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 1), capture.completions);
    try std.testing.expect(app.shell.lifecycle.notebook.command_output_display.open_command_block == null);
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.command_output_blocks.items.len);
    try std.testing.expect(app.shell.lifecycle.notebook.command_output_blocks.items[0].entry_id != null);
}

test "core.app_worker_runtime idle sync preserves command output pending its turn boundary" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 6,
        .call_id = "pending-boundary-command",
    };
    var metrics: types.Metrics = .{};
    try app.shell.lifecycle.writeCommandOutputChunkForLifecycle(
        app.alloc,
        &metrics,
        .{
            .system_notice_label_style = "",
            .system_notice_text_style = "",
            .reset_style = "",
            .dim_style = "",
            .red_style = "",
        },
        lifecycle_id,
        .stdout,
        "retained output\n",
        true,
    );
    app.agent().stream.active = true;
    app.agent().worker.processing = false;

    Runtime(FakeApp).syncState(&app, (&app).agent(), NoopBridge.lifecyclePresenter(&app));

    try std.testing.expect(!app.agent().stream.active);
    try std.testing.expect(app.shell.lifecycle.notebook.command_output_display.open_command_block != null);
    try std.testing.expectEqual(@as(usize, 1), app.shell.lifecycle.notebook.command_output_blocks.items.len);
}

test "core.app_worker_runtime blocks frame attempts until worker event batch settles" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;

    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 9, .call_id = "cmd-9" };
    try queueToolStart(&app, lifecycle_id.turn_id, lifecycle_id.call_id, "run_command");
    try Runtime(FakeApp).pushCommandOutput(&app, (&app).agent(), lifecycle_id, .stdout, "one\n");
    try Runtime(FakeApp).pushCommandOutputComplete(&app, (&app).agent(), lifecycle_id);
    try queueToolTerminal(&app, lifecycle_id.turn_id, lifecycle_id.call_id, .failed, "failed");
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "request failed",
    } });

    const Capture = struct {
        app: *FakeApp,
        reentrant_checks: usize = 0,
        blocked_checks: usize = 0,
        admitted_frames: usize = 0,

        fn checkFrameAdmission(self: *@This()) !void {
            self.reentrant_checks += 1;
            if (self.app.shell.render_requests.blocksFrameCommit()) {
                self.blocked_checks += 1;
            }
            if (try self.app.shell.render_requests.beginAttempt()) |value| {
                var attempt = value;
                defer attempt.deinit();
                self.admitted_frames += 1;
                attempt.restore();
            }
        }

        fn output(raw: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.app.shell.render_requests.request(.transcript);
            try self.checkFrameAdmission();
        }

        fn outputComplete(raw: *anyopaque, _: ?types.ToolLifecycleId) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.app.shell.render_requests.request(.transcript);
            try self.checkFrameAdmission();
        }

        fn err(raw: *anyopaque, _: types.SemanticNotice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.app.shell.render_requests.request(.transcript);
            try self.checkFrameAdmission();
        }
    };

    var capture = Capture{ .app = &app };
    var handlers = NoopBridge.handlers(&app);
    handlers.ctx = @ptrCast(&capture);
    handlers.command_output = Capture.output;
    handlers.command_output_complete = Capture.outputComplete;
    handlers.error_text = Capture.err;

    try Runtime(FakeApp).tick(&app, (&app).agent(), handlers);

    try std.testing.expectEqual(@as(usize, 3), capture.reentrant_checks);
    try std.testing.expectEqual(capture.reentrant_checks, capture.blocked_checks);
    try std.testing.expectEqual(@as(usize, 0), capture.admitted_frames);
    try std.testing.expect(!app.shell.render_requests.blocksFrameCommit());

    var settled_attempt = (try app.shell.render_requests.beginAttempt()) orelse
        return error.MissingSettledFrameSnapshot;
    defer settled_attempt.deinit();
    try std.testing.expect(settled_attempt.snapshot.reasons.contains(.transcript));
    try std.testing.expect(settled_attempt.snapshot.reasons.contains(.footer));
    try std.testing.expect(settled_attempt.snapshot.reasons.contains(.animation));
    try std.testing.expectEqual(@as(usize, 3), settled_attempt.snapshot.reasons.count());
    settled_attempt.restore();
}

test "core.app_worker_runtime cancelled drain preserves notification events" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expectEqual(
        CancelledEventAdmission.admit,
        Runtime(FakeApp).cancelledEventAdmission(
            NoopBridge.lifecyclePresenter(&app),
            .{ .notification = .{ .kind = .turn_end } },
            &.{},
        ),
    );
}

test "core.app_worker_runtime cancelled drain skips diff block" {
    const c_alloc = std.heap.c_allocator;
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);

    try Runtime(FakeApp).pushDiffBlock(&app, (&app).agent(), .{
        .preview = try c_alloc.dupe(u8, "diff preview"),
    });

    const Capture = struct {
        diff_count: usize = 0,

        fn user(_: *anyopaque, _: types.UserTurn) !void {}
        fn text(_: *anyopaque, _: []const u8) !void {}
        fn notice(_: *anyopaque, _: types.SemanticNotice) !void {}
        fn output(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) !void {}
        fn outputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
        fn diff(raw: *anyopaque, payload: @import("../output/diff.zig").DiffEntryPayload) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer @import("../output/diff.zig").freeDiffEntryPayload(std.heap.c_allocator, payload);
            self.diff_count += 1;
        }
        fn history(_: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
            return .{ .settled = .committed };
        }
        fn grant(_: *anyopaque, _: types.PermissionGrant) !void {}
        fn err(_: *anyopaque, _: types.SemanticNotice) !void {}
    };
    var capture = Capture{};

    try Runtime(FakeApp).tick(&app, (&app).agent(), .{
        .ctx = @ptrCast(&capture),
        .tool_lifecycle = NoopBridge.lifecyclePresenter(&app),
        .write_user_prompt = Capture.user,
        .append_text = Capture.text,
        .drain_assistant_text = NoopBridge.drain,
        .open_model_picker = NoopBridge.openModelPicker,
        .semantic_notice = Capture.notice,
        .command_output = Capture.output,
        .command_output_complete = Capture.outputComplete,
        .diff_block = Capture.diff,
        .append_history_turn = Capture.history,
        .session_grant = Capture.grant,
        .error_text = Capture.err,
    });

    try std.testing.expectEqual(@as(usize, 0), capture.diff_count);
}

test "worker finish delivery separates unaccepted work from committed presentation failure" {
    for ([_]bool{ false, true }) |committed| {
        var app = FakeApp.init(std.testing.allocator);
        defer app.deinit();
        app.agent().worker.processing = true;
        const Capture = struct {
            app: *FakeApp,
            committed: bool,
            fn history(raw: *anyopaque, finished: types.FinishedPrompt) !HistoryDelivery {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (!self.committed) return error.InjectedDeliveryFailure;
                try self.app.appendFinishedPrompt(finished);
                return .{ .settled = .{ .presentation_failed = error.InjectedDeliveryFailure } };
            }
        };
        var capture = Capture{ .app = &app, .committed = committed };
        var handlers = NoopBridge.handlers(&app);
        handlers.ctx = &capture;
        handlers.append_history_turn = Capture.history;
        for ([_][]const u8{ "first answer", "second answer" }) |answer| {
            try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("request") },
                .assistant = @constCast(answer),
            } } } });
        }
        try std.testing.expectError(error.InjectedDeliveryFailure, Runtime(FakeApp).tick(&app, (&app).agent(), handlers));
        try std.testing.expectEqual(@as(usize, 2), app.persisted_finishes.items.len);
        try std.testing.expectEqualStrings("first answer", app.persisted_finishes.items[0].turn.assistant.assistant);
        try std.testing.expectEqualStrings("second answer", app.persisted_finishes.items[1].turn.assistant.assistant);
        try std.testing.expectEqual(@as(?anyerror, null), app.agent().session_persistence.shutdown_failure);
    }
}

test "unaccepted worker finish records save failure and stops the detached suffix" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.agent().worker.processing = true;
    app.finish_persistence_error = error.InputOutput;
    const Capture = struct {
        fn history(_: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
            return error.InjectedDeliveryFailure;
        }
    };
    var handlers = NoopBridge.handlers(&app);
    handlers.append_history_turn = Capture.history;
    for (0..2) |_| {
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("request") },
            .assistant = @constCast("answer"),
        } } } });
    }
    try std.testing.expectError(error.InjectedDeliveryFailure, Runtime(FakeApp).tick(&app, (&app).agent(), handlers));
    try std.testing.expectEqual(@as(?anyerror, error.InputOutput), app.agent().session_persistence.shutdown_failure);
    try std.testing.expectEqual(@as(usize, 0), app.persisted_finishes.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.events.items.len);
}

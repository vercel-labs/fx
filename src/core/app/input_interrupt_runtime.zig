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
        pub fn hasActiveOperation(app: *App) bool {
            if (comptime @hasField(App, "auth")) {
                if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                    if (app.auth.providerPreparationPending()) return true;
                }
            }
            return activeCancellationTarget(app) != .none;
        }

        pub fn cancelActiveOperation(app: *App) !void {
            if (comptime @hasField(App, "auth")) {
                if (comptime @hasDecl(@TypeOf(app.auth), "cancelProviderPreparation")) {
                    if (app.auth.cancelProviderPreparation()) {
                        if (comptime @hasDecl(App, "cancelPendingSubmission")) _ = App.cancelPendingSubmission(app);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                }
            }
            if (activeCancellationTarget(app) == .context_compaction) {
                if (comptime !@hasDecl(
                    @TypeOf(app.worker),
                    "cancelContextCompaction",
                )) return;
                const cancelled = app.worker.cancelContextCompaction(
                    std.heap.c_allocator,
                );
                if (!cancelled) return;
                app.pacer.clear(app.alloc);
                if (comptime @hasDecl(App, "playCancelSound")) app.playCancelSound();
                try app.writeDomainNotice(.{
                    .topic = "context",
                    .tone = .neutral,
                    .body = "Context compaction cancelled.",
                }, true);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (!app.stream.active) return;
            // Pending approval keeps the stream active until resolution.
            // Avoid duplicate cancellation notices once the worker is cancelled.
            if (app.worker.isCancelRequested()) return;
            const tool_active = activeToolStatusCount(app) > 0;
            debug_trace.logf("input", "cancel active operation queued={d}", .{app.worker.queuedPromptCount()});
            traceInterruptRequested(app, "input_active_stream");
            if (comptime @hasDecl(@TypeOf(app.worker), "requestInteractiveCancel")) {
                app.worker.requestInteractiveCancel();
            } else {
                app.worker.requestCancel();
            }
            app.pacer.clear(app.alloc);
            if (comptime @hasDecl(App, "playCancelSound")) app.playCancelSound();
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
            app.stream = .{};
            app.shell.render_requests.request(.footer);
        }

        pub fn pauseActiveRecovery(app: *App) bool {
            if (!app.stream.active) return false;
            if (comptime !@hasDecl(@TypeOf(app.worker), "isConnectivityWaitActive")) return false;
            if (!app.worker.isConnectivityWaitActive()) return false;
            if (comptime !@hasDecl(@TypeOf(app.worker), "requestRecoveryPause")) return false;
            app.worker.requestRecoveryPause();
            debug_trace.logf("input", "model recovery pause requested", .{});
            return true;
        }

        pub fn traceInterruptRequested(app: *App, source: []const u8) void {
            const approval_active = app.approval_prompt.isActive();
            const question_active = app.question_prompt.isActive();
            const tool_status_count = activeToolStatusCount(app);
            const pending_tool_call = approval_active or tool_status_count > 0;
            const running_tool = tool_status_count > 0 and !approval_active and !question_active;
            const active_streamed_text_response = app.stream.active and !pending_tool_call and !question_active;
            debug_trace.eventf(
                "interrupt",
                "cancel_requested",
                .{},
                "source={s} stream_active={s} active_streamed_text_response={s} pending_tool_call={s} approval_prompt={s} running_tool={s} stream_activity_count={d} last_activity_kind={s}",
                .{
                    source,
                    if (app.stream.active) "true" else "false",
                    if (active_streamed_text_response) "true" else "false",
                    if (pending_tool_call) "true" else "false",
                    if (approval_active) "true" else "false",
                    if (running_tool) "true" else "false",
                    app.stream.chunks,
                    if (app.stream.last_activity_kind) |kind| @tagName(kind) else "none",
                },
            );
        }

        fn activeToolStatusCount(app: *App) usize {
            if (comptime !@hasDecl(@TypeOf(app.shell), "activeToolActivityCount")) {
                return 0;
            }
            return shell_runtime.activeToolActivityCount(&app.shell);
        }

        fn activeCancellationTarget(app: *App) CancellationTarget {
            const status = if (comptime @hasDecl(
                @TypeOf(app.worker),
                "contextCompactionStatus",
            ))
                app.worker.contextCompactionStatus()
            else
                worker_runtime.ContextCompactionStatus.idle;
            return cancellationTarget(app.stream.active, status);
        }
    };
}

test "interactive connectivity wait maps try later to recovery pause" {
    const FakeWorker = struct {
        connectivity_wait_active: bool = false,
        pause_requested: bool = false,

        pub fn isConnectivityWaitActive(self: *const @This()) bool {
            return self.connectivity_wait_active;
        }

        pub fn requestRecoveryPause(self: *@This()) void {
            self.pause_requested = true;
        }
    };
    const FakeApp = struct {
        stream: struct { active: bool } = .{ .active = true },
        worker: FakeWorker = .{},
    };

    var app = FakeApp{};
    app.worker.connectivity_wait_active = true;
    try std.testing.expect(InterruptRuntime(FakeApp).pauseActiveRecovery(&app));
    try std.testing.expect(app.worker.pause_requested);

    app.worker.pause_requested = false;
    app.worker.connectivity_wait_active = false;
    try std.testing.expect(!InterruptRuntime(FakeApp).pauseActiveRecovery(&app));
    try std.testing.expect(!app.worker.pause_requested);
}

const std = @import("std");
const app_session_runtime = @import("app_session_runtime.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const action_executor = @import("../terminal/action_executor.zig");
const contracts = @import("../terminal/contracts.zig");
const identity = @import("../terminal/identity.zig");
const managed_observer = @import("../terminal/managed_observer.zig");
const operation = @import("../terminal/operation.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");

const max_direct_output_bytes: usize = 64 * 1024;
const start_wait_ceiling_ms: u64 = 20_000;

pub const ExitPreparation = enum {
    ready,
    deferred,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn submitDirect(app: *App, command: []const u8) !void {
            var profile_user_buffer: [64]u8 = undefined;
            const profile_user = identity.profileUser(&profile_user_buffer) orelse {
                try writeAdmissionFailure(app, "unsupported host");
                return;
            };
            const durable_session_id = app_session_runtime.Runtime(App).activeSessionId(app) orelse {
                try writeAdmissionFailure(app, "no durable fx session");
                return;
            };
            const child_capability = app_session_runtime.Runtime(App).childCapability(app) orelse {
                try writeAdmissionFailure(app, "durable session is unavailable");
                return;
            };

            app.managed_executions.reserveTtyCapacity() catch |err| {
                try writeAdmissionFailure(app, @errorName(err));
                return;
            };
            var capacity_reserved = true;
            defer if (capacity_reserved) app.managed_executions.releaseTtyCapacity();

            var persistence = operation.prepareStartPersistence(app.alloc, .{
                .profile_user = profile_user,
                .durable_session_id = durable_session_id,
                .workspace_root = app.workspace_root,
                .cwd = app.workspace_root,
                .transport_role = .interactive,
                .backend = .native,
                .actor = .human,
                .controls = .full(),
                .lifetime = .session,
                .direct_human_model_read_only = true,
            }) catch |err| {
                try writeAdmissionFailure(app, @errorName(err));
                return;
            };
            defer persistence.deinit();

            var shell_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer shell_arena.deinit();
            const shell = shell_resolver.profileShell(
                shell_arena.allocator(),
                null,
                .user,
            ) catch |err| {
                try writeAdmissionFailure(app, @errorName(err));
                return;
            };
            var result = action_executor.execute(.{
                .alloc = app.alloc,
                .lifecycle_allocator = app.alloc,
                .runtime = &app.terminal_client,
            }, .{ .start = .{
                .cwd = app.workspace_root,
                .command = command,
                .shell = shell,
                .backend = .native,
                .return_when = .started,
                .wait_ceiling_ms = start_wait_ceiling_ms,
                .persistence = persistence.view(),
            } }) catch |err| {
                try writeAdmissionFailure(app, @errorName(err));
                return;
            };
            defer result.deinit(app.alloc);

            const start = switch (result.view()) {
                .failure => |failure| {
                    try writeAdmissionFailure(app, @tagName(failure.code));
                    return;
                },
                .success => |success| switch (success) {
                    .start => |start| start,
                    else => {
                        try writeAdmissionFailure(app, "invalid terminal result");
                        return;
                    },
                },
            };
            var session_owned = true;
            defer if (session_owned) closeUnpublishedSession(
                app,
                start.session.session_id,
                persistence.view(),
            );

            var prepared = app.managed_executions.registerTty(app.alloc, .{
                .execution_id = start.session.session_id,
                .command = command,
                .cwd = app.workspace_root,
                .state = stateFromLifecycle(start.session.lifecycle),
                .max_output_bytes = max_direct_output_bytes,
                .published_running = true,
                .capacity_reserved = true,
                .replay_capability = child_capability,
            }) catch |err| {
                try writeAdmissionFailure(app, @errorName(err));
                return;
            };
            defer prepared.deinit(app.alloc);
            capacity_reserved = false;
            session_owned = false;
            try app.managed_executions.commitDelivery(
                prepared.snapshot.execution_id,
                prepared.reservation_id,
            );

            clearSubmission(app);
            try writeEvent(app, "Running", command, start.session.session_id);
            app.shell.render_requests.request(.footer);
        }

        pub fn collectFacts(_: *App) !void {}

        pub fn refreshManagedFacts(app: *App) !void {
            if (comptime !@hasField(App, "managed_executions") or
                !@hasField(App, "terminal_client") or
                !@hasField(App, "session_persistence")) return;
            const owner = app_session_runtime.Runtime(App).childCapability(app) orelse
                return;
            const durable_session_id = app_session_runtime.Runtime(App).activeSessionId(app) orelse
                return;
            try managed_observer.refreshAll(.{
                .alloc = app.alloc,
                .lifecycle_allocator = app.alloc,
                .terminal_client = &app.terminal_client,
                .managed_runtime = &app.managed_executions,
                .owner = owner,
                .durable_session_id = durable_session_id,
                .workspace_root = app.workspace_root,
                .transport_role = .interactive,
                .max_output_bytes = max_direct_output_bytes,
            });
        }

        pub fn prepareGracefulExit(_: *App) ExitPreparation {
            return .ready;
        }

        fn clearSubmission(app: *App) void {
            if (comptime @hasDecl(@TypeOf(app.input_runtime), "inputResetState")) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
            } else {
                app.input_runtime.clearCurrentInput(app.alloc);
            }
            paste_blocks.clearBlocks(
                app.alloc,
                &app.input_runtime.entities.pasted_blocks,
            );
            if (app.pending_images.items.len == 0) return;
            debug_trace.logf(
                "input",
                "draft images dropped count={d} reason=direct_terminal",
                .{app.pending_images.items.len},
            );
            app.clearPendingImages();
        }

        fn writeAdmissionFailure(app: *App, reason: []const u8) !void {
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            try body.writer.print("Direct terminal was not started: {s}", .{reason});
            try app.writeDomainNotice(.{
                .topic = "terminal",
                .tone = .@"error",
                .body = body.written(),
            }, true);
            app.shell.render_requests.request(.footer);
        }

        fn closeUnpublishedSession(
            app: *App,
            session_id: []const u8,
            persistence: contracts.StartPersistence,
        ) void {
            var result = action_executor.execute(.{
                .alloc = app.alloc,
                .lifecycle_allocator = app.alloc,
                .runtime = &app.terminal_client,
            }, .{ .close = .{
                .session_id = session_id,
                .policy = .force,
                .authority = .{
                    .principal = persistence.grant.principal,
                    .actor = persistence.grant.actor,
                    .generation = persistence.grant.generation,
                    .proof = persistence.proof,
                },
            } }) catch |err| {
                debug_trace.logf(
                    "terminal",
                    "unpublished direct session cleanup failed session={s} err={s}",
                    .{ session_id, @errorName(err) },
                );
                return;
            };
            result.deinit(app.alloc);
        }

        fn writeEvent(
            app: *App,
            state: []const u8,
            command: []const u8,
            session_id: []const u8,
        ) !void {
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            try body.writer.print("{s} {s}: {s}", .{ state, session_id, command });
            try app.writeDomainNotice(.{
                .topic = "terminal",
                .tone = types.NoticeTone.information,
                .body = body.written(),
            }, true);
        }
    };
}

fn stateFromLifecycle(lifecycle: contracts.Lifecycle) managed_execution.SnapshotState {
    return switch (lifecycle) {
        .starting, .running => .running,
        .exited => .{ .completed = .finished },
        .lost => .lost,
        .closed => .{ .stopped = null },
    };
}

test "direct lifecycle mapping contains terminal authority" {
    try std.testing.expect(stateFromLifecycle(.starting) == .running);
    try std.testing.expect(stateFromLifecycle(.running) == .running);
    try std.testing.expect(stateFromLifecycle(.exited) != .running);
    try std.testing.expect(stateFromLifecycle(.lost) == .lost);
    try std.testing.expect(stateFromLifecycle(.closed) != .running);
}

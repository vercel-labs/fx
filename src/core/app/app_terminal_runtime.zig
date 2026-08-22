const std = @import("std");
const direct_runtime = @import("../terminal/direct_runtime.zig");
const identity = @import("../terminal/identity.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const OpenRequestResult = enum {
    accepted,
    occupied,
    rejected,
};

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
                try writeAdmissionFailure(app, "no durable Fx session");
                return;
            };
            _ = app_session_runtime.Runtime(App).childCapability(app) orelse {
                try writeAdmissionFailure(app, "durable session is unavailable");
                return;
            };
            _ = app.terminal_direct.admit(&app.terminal_client, .{
                .alloc = app.alloc,
                .profile_user = profile_user,
                .durable_session_id = durable_session_id,
                .workspace_root = app.workspace_root,
                .command = command,
            }) catch |err| {
                try writeAdmissionFailure(app, @errorName(err));
                return;
            };

            if (comptime @hasDecl(@TypeOf(app.input_runtime), "inputResetState")) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
            } else {
                app.input_runtime.clearCurrentInput(app.alloc);
            }
            paste_blocks.clearBlocks(
                app.alloc,
                &app.input_runtime.entities.pasted_blocks,
            );
            if (app.pending_images.items.len > 0) {
                debug_trace.logf(
                    "input",
                    "draft images dropped count={d} reason=direct_terminal",
                    .{app.pending_images.items.len},
                );
                app.clearPendingImages();
            }
            publishPendingNotices(app) catch |err| debug_trace.logf(
                "terminal",
                "direct lifecycle notice retained phase=starting err={s}",
                .{@errorName(err)},
            );
        }

        pub fn collectFacts(app: *App) !void {
            publishPendingNotices(app) catch |err| debug_trace.logf(
                "terminal",
                "direct lifecycle notice retained err={s}",
                .{@errorName(err)},
            );
        }

        pub fn requestOpen(app: *App, session_id: []const u8) OpenRequestResult {
            const result = app.terminal_direct.requestOpen(
                app.alloc,
                session_id,
            ) catch |err| {
                retainOpenRejection(app, @errorName(err));
                return .rejected;
            };
            return switch (result) {
                .accepted => .accepted,
                .occupied => blk: {
                    retainOpenRejection(app, "another terminal is already opening");
                    break :blk .occupied;
                },
            };
        }

        pub fn prepareGracefulExit(app: *App) ExitPreparation {
            return prepareGracefulExitWithCeiling(
                app,
                gracefulExitWaitCeilingMs(),
            );
        }

        fn prepareGracefulExitWithCeiling(
            app: *App,
            wait_ceiling_ms: i64,
        ) ExitPreparation {
            if (!app.terminal_direct.hasAcceptedPending()) {
                flushShutdownOutcome(app);
                return .ready;
            }

            const deadline = io_mod.milliTimestamp() + wait_ceiling_ms;
            var notice_error: ?anyerror = null;
            while (app.terminal_direct.hasAcceptedPending()) {
                if (publishPendingNotices(app)) |_| {
                    notice_error = null;
                } else |err| {
                    notice_error = err;
                }
                if (!app.terminal_direct.hasAcceptedPending() or
                    io_mod.milliTimestamp() >= deadline)
                {
                    break;
                }
                io_mod.sleep(5 * std.time.ns_per_ms);
            }
            if (!app.terminal_direct.hasAcceptedPending()) {
                flushShutdownOutcome(app);
                return .ready;
            }

            if (notice_error) |err| {
                debug_trace.logf(
                    "terminal",
                    "direct graceful exit deferred pending={d} wait_ceiling_ms={d} transcript_error={s}",
                    .{
                        app.terminal_direct.pendingCount(),
                        wait_ceiling_ms,
                        @errorName(err),
                    },
                );
            } else {
                debug_trace.logf(
                    "terminal",
                    "direct graceful exit deferred pending={d} wait_ceiling_ms={d}",
                    .{ app.terminal_direct.pendingCount(), wait_ceiling_ms },
                );
            }
            return .deferred;
        }

        fn flushShutdownOutcome(app: *App) void {
            if (comptime @hasDecl(App, "flushDirectTerminalShutdownOutcome")) {
                app.flushDirectTerminalShutdownOutcome() catch |err| debug_trace.logf(
                    "terminal",
                    "direct shutdown visible outcome flush failed err={s}",
                    .{@errorName(err)},
                );
            }
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

        fn retainOpenRejection(app: *App, reason: []const u8) void {
            writeAdmissionFailure(app, reason) catch |err| debug_trace.logf(
                "terminal",
                "terminal open rejection notice retained reason={s} err={s}",
                .{ reason, @errorName(err) },
            );
        }

        fn publishPendingNotices(app: *App) !void {
            while (app.terminal_direct.nextNotice(&app.terminal_client)) |notice| {
                switch (notice) {
                    .starting => |value| try writeEvent(
                        app,
                        .information,
                        "Starting",
                        value.command,
                        null,
                    ),
                    .running => |value| try writeEvent(
                        app,
                        .information,
                        "Running",
                        value.command,
                        value.session_id,
                    ),
                    .failed => |value| try writeEvent(
                        app,
                        .@"error",
                        "Failed",
                        value.command,
                        @tagName(value.code),
                    ),
                }
                app.terminal_direct.acknowledgeNotice(
                    app.alloc,
                    notice.correlationId(),
                    notice.phase(),
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn writeEvent(
            app: *App,
            tone: types.NoticeTone,
            state: []const u8,
            command: []const u8,
            detail: ?[]const u8,
        ) !void {
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            if (detail) |value| {
                try body.writer.print("{s} {s}: {s}", .{ state, value, command });
            } else {
                try body.writer.print("{s}: {s}", .{ state, command });
            }
            try app.writeDomainNotice(.{
                .topic = "terminal",
                .tone = tone,
                .body = body.written(),
            }, true);
        }
    };
}

fn gracefulExitWaitCeilingMs() i64 {
    const default: i64 = @intCast(direct_runtime.start_wait_ceiling_ms);
    const raw = io_mod.getenv(
        "FX_TERMINAL_TEST_GRACEFUL_EXIT_WAIT_CEILING_MS",
    ) orelse return default;
    const configured = std.fmt.parseInt(u64, raw, 10) catch return default;
    return @intCast(@min(configured, direct_runtime.start_wait_ceiling_ms));
}

const TestDirectRuntime = struct {
    notice: ?direct_runtime.Notice = null,
    acknowledgements: usize = 0,
    open_result: direct_runtime.OpenIntentAdmission = .accepted,

    fn requestOpen(
        self: *TestDirectRuntime,
        _: std.mem.Allocator,
        _: []const u8,
    ) !direct_runtime.OpenIntentAdmission {
        return self.open_result;
    }

    fn nextNotice(
        self: *TestDirectRuntime,
        _: anytype,
    ) ?direct_runtime.Notice {
        return self.notice;
    }

    fn acknowledgeNotice(
        self: *TestDirectRuntime,
        _: std.mem.Allocator,
        correlation_id: @import("../terminal/contracts.zig").CorrelationId,
        phase: direct_runtime.NoticePhase,
    ) void {
        std.debug.assert(self.notice.?.correlationId().value == correlation_id.value);
        std.debug.assert(self.notice.?.phase() == phase);
        self.notice = null;
        self.acknowledgements += 1;
    }
};

const TestRenderRequests = struct {
    count: usize = 0,

    fn request(self: *TestRenderRequests, _: anytype) void {
        self.count += 1;
    }
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    terminal_direct: TestDirectRuntime = .{},
    terminal_client: u8 = 0,
    shell: struct { render_requests: TestRenderRequests = .{} } = .{},
    fail_writes: usize = 0,
    bodies: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TestApp) void {
        for (self.bodies.items) |body| std.testing.allocator.free(body);
        self.bodies.deinit(std.testing.allocator);
    }

    fn writeDomainNotice(
        self: *TestApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        if (self.fail_writes > 0) {
            self.fail_writes -= 1;
            return error.InjectedWriteFailure;
        }
        const body = try std.testing.allocator.dupe(u8, notice.body);
        errdefer std.testing.allocator.free(body);
        try self.bodies.append(std.testing.allocator, body);
    }
};

test "direct starting notice survives allocation failure and is appended once" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var app = TestApp{ .alloc = failing.allocator() };
    defer app.deinit();
    app.terminal_direct.notice = .{ .starting = .{
        .correlation_id = .{ .value = 1 },
        .command = "zig build test",
    } };

    try std.testing.expectError(
        error.WriteFailed,
        Runtime(TestApp).publishPendingNotices(&app),
    );
    try std.testing.expectEqual(@as(usize, 0), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 0), app.bodies.items.len);

    app.alloc = std.testing.allocator;
    try Runtime(TestApp).publishPendingNotices(&app);
    try Runtime(TestApp).publishPendingNotices(&app);
    try std.testing.expectEqual(@as(usize, 1), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
    try std.testing.expectEqualStrings("Starting: zig build test", app.bodies.items[0]);
}

test "direct final notice survives transcript write failure and is appended once" {
    var app = TestApp{
        .alloc = std.testing.allocator,
        .fail_writes = 1,
    };
    defer app.deinit();
    app.terminal_direct.notice = .{ .failed = .{
        .correlation_id = .{ .value = 2 },
        .command = "bun test",
        .code = .session_lost,
    } };

    try std.testing.expectError(
        error.InjectedWriteFailure,
        Runtime(TestApp).publishPendingNotices(&app),
    );
    try std.testing.expectEqual(@as(usize, 0), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 0), app.bodies.items.len);

    try Runtime(TestApp).publishPendingNotices(&app);
    try Runtime(TestApp).publishPendingNotices(&app);
    try std.testing.expectEqual(@as(usize, 1), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
    try std.testing.expectEqualStrings(
        "Failed session_lost: bun test",
        app.bodies.items[0],
    );
}

test "repeated terminal open is explicitly occupied and records one rejection" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.terminal_direct.open_result = .occupied;

    try std.testing.expectEqual(
        OpenRequestResult.occupied,
        Runtime(TestApp).requestOpen(&app, "terminal-b"),
    );
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
    try std.testing.expectEqualStrings(
        "Direct terminal was not started: another terminal is already opening",
        app.bodies.items[0],
    );
}

const ShutdownTestDirectRuntime = struct {
    accepted_pending: bool = true,
    starting_pending: bool = true,
    final_pending: bool = false,
    final_failure_pending: bool = false,
    acknowledgements: usize = 0,

    fn hasAcceptedPending(self: *const ShutdownTestDirectRuntime) bool {
        return self.accepted_pending;
    }

    fn pendingCount(self: *const ShutdownTestDirectRuntime) usize {
        return @intFromBool(self.accepted_pending);
    }

    fn nextNotice(
        self: *ShutdownTestDirectRuntime,
        _: anytype,
    ) ?direct_runtime.Notice {
        if (!self.accepted_pending) return null;
        if (self.starting_pending) return .{ .starting = .{
            .correlation_id = .{ .value = 17 },
            .command = "shutdown command",
        } };
        if (self.final_pending) {
            if (self.final_failure_pending) return .{ .failed = .{
                .correlation_id = .{ .value = 17 },
                .command = "shutdown command",
                .code = .unsupported_host,
            } };
            return .{ .running = .{
                .correlation_id = .{ .value = 17 },
                .command = "shutdown command",
                .session_id = "terminal-17",
            } };
        }
        return null;
    }

    fn acknowledgeNotice(
        self: *ShutdownTestDirectRuntime,
        _: std.mem.Allocator,
        _: @import("../terminal/contracts.zig").CorrelationId,
        phase: direct_runtime.NoticePhase,
    ) void {
        self.acknowledgements += 1;
        switch (phase) {
            .starting => self.starting_pending = false,
            .final => self.accepted_pending = false,
        }
    }
};

const ShutdownTestApp = struct {
    alloc: std.mem.Allocator = std.testing.allocator,
    terminal_direct: ShutdownTestDirectRuntime = .{},
    terminal_client: u8 = 0,
    shell: struct { render_requests: TestRenderRequests = .{} } = .{},
    fail_writes: usize = 0,
    fail_flushes: usize = 0,
    flush_attempts: usize = 0,
    bodies: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ShutdownTestApp) void {
        for (self.bodies.items) |body| std.testing.allocator.free(body);
        self.bodies.deinit(std.testing.allocator);
    }

    fn writeDomainNotice(
        self: *ShutdownTestApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        if (self.fail_writes > 0) {
            self.fail_writes -= 1;
            return error.InjectedWriteFailure;
        }
        const body = try std.testing.allocator.dupe(u8, notice.body);
        errdefer std.testing.allocator.free(body);
        try self.bodies.append(std.testing.allocator, body);
    }

    fn flushDirectTerminalShutdownOutcome(self: *ShutdownTestApp) !void {
        self.flush_attempts += 1;
        if (self.fail_flushes > 0) {
            self.fail_flushes -= 1;
            return error.InjectedFlushFailure;
        }
    }
};

test "graceful exit commits an authoritative result after transcript retry" {
    var app = ShutdownTestApp{
        .terminal_direct = .{ .final_pending = true },
        .fail_writes = 1,
    };
    defer app.deinit();

    try std.testing.expectEqual(
        ExitPreparation.ready,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 50),
    );

    try std.testing.expect(!app.terminal_direct.accepted_pending);
    try std.testing.expectEqual(@as(usize, 2), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 2), app.bodies.items.len);
    try std.testing.expectEqualStrings("Starting: shutdown command", app.bodies.items[0]);
    try std.testing.expectEqualStrings(
        "Running terminal-17: shutdown command",
        app.bodies.items[1],
    );
    try std.testing.expectEqual(@as(usize, 1), app.flush_attempts);
}

test "unsupported direct start publishes failure and does not defer graceful exit" {
    var app = ShutdownTestApp{
        .terminal_direct = .{
            .starting_pending = false,
            .final_pending = true,
            .final_failure_pending = true,
        },
    };
    defer app.deinit();

    try std.testing.expectEqual(
        ExitPreparation.ready,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 0),
    );
    try std.testing.expect(!app.terminal_direct.accepted_pending);
    try std.testing.expectEqual(@as(usize, 1), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
    try std.testing.expectEqualStrings(
        "Failed unsupported_host: shutdown command",
        app.bodies.items[0],
    );
    try std.testing.expectEqual(@as(usize, 1), app.flush_attempts);
}

test "unresolved graceful exit defers without cancelling and later succeeds" {
    var app = ShutdownTestApp{};
    defer app.deinit();

    try std.testing.expectEqual(
        ExitPreparation.deferred,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 0),
    );
    try std.testing.expect(app.terminal_direct.accepted_pending);
    try std.testing.expectEqual(@as(usize, 1), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.flush_attempts);

    app.terminal_direct.final_pending = true;
    try std.testing.expectEqual(
        ExitPreparation.ready,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 0),
    );

    try std.testing.expect(!app.terminal_direct.accepted_pending);
    try std.testing.expectEqual(@as(usize, 2), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 2), app.bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.flush_attempts);
}

test "transcript commit failure retains the authoritative outcome" {
    var app = ShutdownTestApp{
        .terminal_direct = .{
            .starting_pending = false,
            .final_pending = true,
        },
        .fail_writes = 1,
    };
    defer app.deinit();

    try std.testing.expectEqual(
        ExitPreparation.deferred,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 0),
    );
    try std.testing.expect(app.terminal_direct.accepted_pending);
    try std.testing.expectEqual(@as(usize, 0), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 0), app.bodies.items.len);

    try std.testing.expectEqual(
        ExitPreparation.ready,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 0),
    );
    try std.testing.expectEqual(@as(usize, 1), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
}

test "already settled graceful exit attempts one best effort final frame" {
    var app = ShutdownTestApp{
        .terminal_direct = .{
            .starting_pending = false,
            .final_pending = true,
        },
        .fail_flushes = std.math.maxInt(usize),
    };
    defer app.deinit();

    try Runtime(ShutdownTestApp).publishPendingNotices(&app);
    try std.testing.expect(!app.terminal_direct.accepted_pending);
    try std.testing.expectEqual(@as(usize, 0), app.flush_attempts);
    try std.testing.expectEqual(
        ExitPreparation.ready,
        Runtime(ShutdownTestApp).prepareGracefulExitWithCeiling(&app, 0),
    );
    try std.testing.expectEqual(@as(usize, 1), app.terminal_direct.acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), app.bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.flush_attempts);
}

//! First-party lifecycle hook providers.
//!
//! The Herdr provider reports semantic foreground state for interactive work.
//! Notification hooks live in `notifications` and keep sound policy outside
//! the Core hook harness.

const std = @import("std");
const hooks = @import("../core/hooks/hooks.zig");
const herdr = @import("hooks/herdr.zig");

pub const notifications = @import("hooks/notifications.zig");
pub const user = @import("hooks/user.zig");
pub const Client = herdr.Client;

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Must run before the lifecycle runtime is frozen (currently the
        /// notification runtime performs the sole freeze right after this).
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            app.herdr.initFromEnv(app.alloc);
            if (!app.herdr.enabled) return;

            if (active_session_id) |session_id| {
                app.herdr.reportSession(session_id);
            }
            app.herdr.reportState(.idle, null);
            app.herdr.announce();

            try register(app);
        }

        fn register(app: *App) !void {
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.herdr.turn_end",
                .ctx = app,
                .run = postTurnEndHandler,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.herdr.attention_required",
                .ctx = app,
                .run = attentionRequiredHandler,
            });
        }

        pub fn reportWorking(app: *App) void {
            app.herdr.reportState(.working, null);
        }

        fn postTurnEndHandler(
            raw: *anyopaque,
            input: hooks.PostTurnEndInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            app.herdr.reportState(.idle, null);
        }

        fn attentionRequiredHandler(
            raw: *anyopaque,
            input: hooks.AttentionRequiredInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            app.herdr.reportState(.blocked, attentionStatus(input.kind));
        }

        fn attentionStatus(kind: hooks.AttentionKind) []const u8 {
            return switch (kind) {
                .permission => "permission",
                .question => "question",
                .route_recovery => "recovery",
            };
        }
    };
}

const RecordingClient = struct {
    const Report = struct {
        state: herdr.State,
        status: ?[]const u8,
    };

    reports: [6]Report = undefined,
    report_count: usize = 0,
    enabled: bool = false,
    enable_on_init: bool = true,
    initialized: bool = false,
    announced: bool = false,
    session_id: ?[]const u8 = null,

    fn initFromEnv(self: *RecordingClient, _: std.mem.Allocator) void {
        self.initialized = true;
        self.enabled = self.enable_on_init;
    }

    fn reportSession(self: *RecordingClient, session_id: []const u8) void {
        self.session_id = session_id;
    }

    fn announce(self: *RecordingClient) void {
        self.announced = true;
    }

    fn reportState(self: *RecordingClient, state: herdr.State, status: ?[]const u8) void {
        self.reports[self.report_count] = .{ .state = state, .status = status };
        self.report_count += 1;
    }
};

test "built-in Herdr hooks report only interactive lifecycle state" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        lifecycle_runtime: hooks.Runtime,
        herdr: RecordingClient = .{},
    };
    const Provider = Runtime(TestApp);

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();

    try Provider.configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.herdr.initialized);
    try std.testing.expect(app.herdr.announced);
    try std.testing.expectEqualStrings("session-42", app.herdr.session_id orelse return error.TestExpectedEqual);
    try std.testing.expect(view.hasPostTurnEnd());
    try std.testing.expect(view.hasAttentionRequired());

    Provider.reportWorking(&app);
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.ask),
        .outcome = .completed,
    });
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.interactive),
        .outcome = .completed,
    });
    view.runAttentionRequired(.{
        .invocation = testInvocation(.acp),
        .kind = .permission,
    });
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .permission,
    });
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .question,
    });
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .route_recovery,
    });

    try std.testing.expectEqual(@as(usize, 6), app.herdr.report_count);
    try expectReport(app.herdr.reports[0], .idle, null);
    try expectReport(app.herdr.reports[1], .working, null);
    try expectReport(app.herdr.reports[2], .idle, null);
    try expectReport(app.herdr.reports[3], .blocked, "permission");
    try expectReport(app.herdr.reports[4], .blocked, "question");
    try expectReport(app.herdr.reports[5], .blocked, "recovery");
}

test "disabled built-in Herdr provider registers no lifecycle hooks" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        lifecycle_runtime: hooks.Runtime,
        herdr: RecordingClient = .{ .enable_on_init = false },
    };

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();

    try Runtime(TestApp).configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.herdr.initialized);
    try std.testing.expect(!app.herdr.announced);
    try std.testing.expect(app.herdr.session_id == null);
    try std.testing.expectEqual(@as(usize, 0), app.herdr.report_count);
    try std.testing.expect(!view.hasPostTurnEnd());
    try std.testing.expect(!view.hasAttentionRequired());
}

fn testInvocation(kind: hooks.ScopeKind) hooks.Invocation {
    return .{
        .scope = .{
            .kind = kind,
            .workspace_root = "/tmp/workspace",
            .session_id = "session",
        },
        .turn_id = 42,
    };
}

fn expectReport(actual: RecordingClient.Report, state: herdr.State, status: ?[]const u8) !void {
    try std.testing.expectEqual(state, actual.state);
    if (status) |expected| {
        try std.testing.expectEqualStrings(expected, actual.status orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expect(actual.status == null);
    }
}

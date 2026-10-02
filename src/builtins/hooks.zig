//! First-party lifecycle hook providers.
//!
//! The terminal status providers (Herdr, cmux, and Otty) report semantic
//! foreground state for interactive work. Notification hooks live in
//! `notifications` and keep sound policy outside the Core hook harness.

const std = @import("std");
const hooks = @import("../core/hooks/hooks.zig");
const types = @import("../core/shared/types.zig");
const herdr = @import("hooks/herdr.zig");
const cmux = @import("hooks/cmux.zig");

pub const notifications = @import("hooks/notifications.zig");
pub const otty = @import("hooks/otty.zig");
pub const HerdrClient = herdr.Client;
pub const CmuxClient = cmux.Client;

/// Fans interactive lifecycle state out to every enabled terminal status
/// provider. Each provider detects its host from the environment.
pub fn Runtime(comptime App: type) type {
    return struct {
        /// Must run before the lifecycle runtime is frozen (currently the
        /// notification runtime performs the sole freeze right after this),
        /// and after `otty.Hooks(App).configure` so the shared foreground
        /// observer knows whether Otty is enabled.
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            app.herdr.initFromEnv(app.alloc);
            if (app.herdr.enabled) {
                if (active_session_id) |session_id| {
                    app.herdr.reportSession(session_id);
                }
                app.herdr.reportState(.idle, null);
                app.herdr.announce();
            }

            app.cmux.initFromEnv(app.alloc);
            if (app.cmux.enabled) app.cmux.reportState(.idle);

            if (app.herdr.enabled or app.cmux.enabled) try register(app);
            if (app.herdr.enabled or app.cmux.enabled or ottyEnabled(app)) {
                installForegroundObserver(app);
            }
        }

        /// The worker has a single foreground observer slot. It reports when
        /// foreground work starts or resumes after a permission or question
        /// answer, and when preparation fails before the turn-end hook runs.
        fn installForegroundObserver(app: *App) void {
            app.worker.foreground_observer = .{
                .context = app,
                .working = foregroundWorking,
                .settled = foregroundSettled,
            };
        }

        fn ottyEnabled(app: *const App) bool {
            if (comptime !@hasField(App, "otty")) return false;
            return app.otty.enabled;
        }

        fn foregroundWorking(raw: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(raw));
            reportWorking(app);
            if (comptime @hasField(App, "otty")) {
                if (app.otty.enabled) otty.Hooks(App).foreground_working(raw);
            }
        }

        fn foregroundSettled(raw: *anyopaque, outcome: types.TurnPresentationOutcome) void {
            const app: *App = @ptrCast(@alignCast(raw));
            reportSettled(app, outcome);
            if (comptime @hasField(App, "otty")) {
                if (app.otty.enabled) otty.Hooks(App).foreground_settled(raw, outcome);
            }
        }

        fn reportSettled(app: *App, outcome: types.TurnPresentationOutcome) void {
            app.herdr.reportState(.idle, null);
            app.cmux.reportState(cmuxTurnEndState(outcome));
        }

        fn register(app: *App) !void {
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.terminal_status.turn_end",
                .ctx = app,
                .run = postTurnEndHandler,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.terminal_status.attention_required",
                .ctx = app,
                .run = attentionRequiredHandler,
            });
        }

        pub fn reportWorking(app: *App) void {
            app.herdr.reportState(.working, null);
            app.cmux.reportState(.working);
        }

        fn postTurnEndHandler(
            raw: *anyopaque,
            input: hooks.PostTurnEndInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            reportSettled(app, input.outcome);
        }

        fn attentionRequiredHandler(
            raw: *anyopaque,
            input: hooks.AttentionRequiredInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            app.herdr.reportState(.blocked, attentionStatus(input.kind));
            app.cmux.reportState(.needs_input);
            app.cmux.notifyAttention(input.kind);
        }

        fn cmuxTurnEndState(outcome: types.TurnPresentationOutcome) cmux.State {
            return switch (outcome) {
                .completed, .interrupted => .idle,
                .failed => .failed,
                .paused => .needs_input,
            };
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

    // Mirrors the real client, which drops reports while disabled.
    fn reportState(self: *RecordingClient, state: herdr.State, status: ?[]const u8) void {
        if (!self.enabled) return;
        self.reports[self.report_count] = .{ .state = state, .status = status };
        self.report_count += 1;
    }
};

const TestWorker = struct {
    const ForegroundObserver = struct {
        context: *anyopaque,
        working: *const fn (*anyopaque) void,
        settled: *const fn (*anyopaque, types.TurnPresentationOutcome) void,
    };

    foreground_observer: ?ForegroundObserver = null,
};

const RecordingCmuxClient = struct {
    states: [8]cmux.State = undefined,
    state_count: usize = 0,
    attention: [4]hooks.AttentionKind = undefined,
    attention_count: usize = 0,
    enabled: bool = false,
    enable_on_init: bool = false,
    initialized: bool = false,

    fn initFromEnv(self: *RecordingCmuxClient, _: std.mem.Allocator) void {
        self.initialized = true;
        self.enabled = self.enable_on_init;
    }

    fn reportState(self: *RecordingCmuxClient, state: cmux.State) void {
        if (!self.enabled) return;
        self.states[self.state_count] = state;
        self.state_count += 1;
    }

    fn notifyAttention(self: *RecordingCmuxClient, kind: hooks.AttentionKind) void {
        if (!self.enabled) return;
        self.attention[self.attention_count] = kind;
        self.attention_count += 1;
    }
};

test "built-in Herdr hooks report only interactive lifecycle state" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        lifecycle_runtime: hooks.Runtime,
        worker: TestWorker = .{},
        herdr: RecordingClient = .{},
        cmux: RecordingCmuxClient = .{},
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
    try std.testing.expectEqual(@as(usize, 0), app.cmux.state_count);
    try std.testing.expect(app.worker.foreground_observer != null);
}

test "built-in cmux hooks report interactive state and attention without Herdr" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        lifecycle_runtime: hooks.Runtime,
        worker: TestWorker = .{},
        herdr: RecordingClient = .{ .enable_on_init = false },
        cmux: RecordingCmuxClient = .{ .enable_on_init = true },
    };
    const Provider = Runtime(TestApp);

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();

    try Provider.configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.cmux.initialized);
    try std.testing.expect(view.hasPostTurnEnd());
    try std.testing.expect(view.hasAttentionRequired());

    Provider.reportWorking(&app);
    view.runAttentionRequired(.{
        .invocation = testInvocation(.acp),
        .kind = .permission,
    });
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .question,
    });
    // Answering the question resumes foreground work through the observer.
    const observer = app.worker.foreground_observer orelse return error.TestExpectedEqual;
    observer.working(observer.context);
    // Preparation failures settle through the observer before turn end.
    observer.settled(observer.context, .failed);
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.ask),
        .outcome = .failed,
    });
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.interactive),
        .outcome = .failed,
    });
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.interactive),
        .outcome = .paused,
    });
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.interactive),
        .outcome = .interrupted,
    });

    const expected = [_]cmux.State{ .idle, .working, .needs_input, .working, .failed, .failed, .needs_input, .idle };
    try std.testing.expectEqualSlices(cmux.State, &expected, app.cmux.states[0..app.cmux.state_count]);
    try std.testing.expectEqualSlices(hooks.AttentionKind, &.{.question}, app.cmux.attention[0..app.cmux.attention_count]);
    try std.testing.expectEqual(@as(usize, 0), app.herdr.report_count);
    try std.testing.expect(!app.herdr.announced);
}

test "disabled terminal status providers register no lifecycle hooks" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        lifecycle_runtime: hooks.Runtime,
        worker: TestWorker = .{},
        herdr: RecordingClient = .{ .enable_on_init = false },
        cmux: RecordingCmuxClient = .{},
    };

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();

    try Runtime(TestApp).configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.herdr.initialized);
    try std.testing.expect(app.cmux.initialized);
    try std.testing.expect(!app.herdr.announced);
    try std.testing.expect(app.herdr.session_id == null);
    try std.testing.expectEqual(@as(usize, 0), app.herdr.report_count);
    try std.testing.expectEqual(@as(usize, 0), app.cmux.state_count);
    try std.testing.expect(app.worker.foreground_observer == null);
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

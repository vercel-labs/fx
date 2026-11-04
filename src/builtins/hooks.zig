//! First-party lifecycle hook providers.
//!
//! The Herdr provider reports semantic foreground state for interactive work.
//! Notification hooks live in `notifications` and keep sound policy outside
//! the Core hook harness.

const std = @import("std");
const hooks = @import("../core/hooks/hooks.zig");
const herdr = @import("hooks/herdr.zig");

pub const notifications = @import("hooks/notifications.zig");
pub const Client = herdr.Client;

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Turns herdr on from the environment and reports the session and
        /// an idle pane. Later changes come from `reconcile`, so one agent's
        /// turn ending can't mark the pane idle while another works.
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            app.herdr.initFromEnv(app.alloc);
            if (!app.herdr.enabled) return;

            if (active_session_id) |session_id| {
                app.herdr.reportSession(session_id);
            }
            app.herdr.reportState(.idle, null);
            app.herdr.announce();
        }

        /// Reports the busiest agent's state when it changed: blocked over
        /// working, and working over idle. The main loop runs it after each
        /// pass, since it owns every agent's prompts.
        pub fn reconcile(app: *App) void {
            if (!app.herdr.enabled) return;
            const Report = struct { state: herdr.State, status: ?[]const u8 = null };
            const report: Report = switch (app.agentsBusiest()) {
                .needs_approval => .{ .state = .blocked, .status = attentionStatus(.permission) },
                .has_question => .{ .state = .blocked, .status = attentionStatus(.question) },
                .needs_you => .{ .state = .blocked, .status = attentionStatus(.route_recovery) },
                .working => .{ .state = .working },
                .idle => .{ .state = .idle },
            };
            app.herdr.reportStateIfChanged(report.state, report.status);
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
    last: herdr.LastReport = .{},

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
        _ = self.last.changed(state, status);
        self.reports[self.report_count] = .{ .state = state, .status = status };
        self.report_count += 1;
    }

    fn reportStateIfChanged(self: *RecordingClient, state: herdr.State, status: ?[]const u8) void {
        if (!self.last.changed(state, status)) return;
        self.reports[self.report_count] = .{ .state = state, .status = status };
        self.report_count += 1;
    }
};

test "an app that knows its busiest agent reports the pane state only on a change" {
    // The tags of `app_agents_runtime.Busiest`.
    const Busiest = enum { needs_approval, has_question, needs_you, working, idle };
    const TestApp = struct {
        alloc: std.mem.Allocator,
        lifecycle_runtime: hooks.Runtime,
        herdr: RecordingClient = .{},
        busiest: Busiest = .idle,

        pub fn agentsBusiest(self: *@This()) Busiest {
            return self.busiest;
        }
    };
    const Provider = Runtime(TestApp);

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();

    try Provider.configure(&app, null);
    const view = app.lifecycle_runtime.freeze();
    // One agent's turn ending says nothing about the others, so no
    // lifecycle hook reports.
    try std.testing.expect(!view.hasPostTurnEnd());
    try std.testing.expect(!view.hasAttentionRequired());

    Provider.reconcile(&app);
    app.busiest = .working;
    Provider.reconcile(&app);
    Provider.reconcile(&app);
    app.busiest = .has_question;
    Provider.reconcile(&app);
    app.busiest = .needs_approval;
    Provider.reconcile(&app);
    app.busiest = .needs_you;
    Provider.reconcile(&app);
    app.busiest = .idle;
    Provider.reconcile(&app);

    try std.testing.expectEqual(@as(usize, 6), app.herdr.report_count);
    try expectReport(app.herdr.reports[0], .idle, null);
    try expectReport(app.herdr.reports[1], .working, null);
    try expectReport(app.herdr.reports[2], .blocked, "question");
    try expectReport(app.herdr.reports[3], .blocked, "permission");
    try expectReport(app.herdr.reports[4], .blocked, "recovery");
    try expectReport(app.herdr.reports[5], .idle, null);
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

fn expectReport(actual: RecordingClient.Report, state: herdr.State, status: ?[]const u8) !void {
    try std.testing.expectEqual(state, actual.state);
    if (status) |expected| {
        try std.testing.expectEqualStrings(expected, actual.status orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expect(actual.status == null);
    }
}

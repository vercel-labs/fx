//! First-party lifecycle hook providers.
//!
//! The Herdr provider mirrors the interactive session's foreground activity
//! and active session into herdr. Notification hooks live in `notifications`
//! and keep sound policy outside the Core hook harness.

const std = @import("std");
const herdr = @import("hooks/herdr.zig");
const ForegroundActivity = @import("../core/app/app_worker_runtime.zig").ForegroundActivity;

pub const notifications = @import("hooks/notifications.zig");
pub const Client = herdr.Client;
pub const SessionStart = herdr.SessionStart;

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(app: *App, active_session_id: ?[]const u8) void {
            app.herdr.initFromEnv(app.alloc);
            reportSession(app, active_session_id, .startup);
        }

        /// Tells herdr which session to resume in this pane after the active
        /// session changes.
        pub fn reportSession(app: *App, session_id: ?[]const u8, start: SessionStart) void {
            app.herdr.reportSession(session_id orelse return, start);
        }

        pub fn syncActivity(app: *App, activity: ForegroundActivity) void {
            app.herdr.publish(switch (activity) {
                .idle => .idle,
                .working => .working,
                .awaiting_approval => .awaiting_approval,
                .awaiting_answer => .awaiting_answer,
            });
        }
    };
}

const RecordingClient = struct {
    statuses: [4]herdr.Status = undefined,
    status_count: usize = 0,
    initialized: bool = false,
    session_id: ?[]const u8 = null,
    session_start: ?herdr.SessionStart = null,

    fn initFromEnv(self: *RecordingClient, _: std.mem.Allocator) void {
        self.initialized = true;
    }

    fn reportSession(self: *RecordingClient, session_id: []const u8, start: herdr.SessionStart) void {
        self.session_id = session_id;
        self.session_start = start;
    }

    fn publish(self: *RecordingClient, status: herdr.Status) void {
        self.statuses[self.status_count] = status;
        self.status_count += 1;
    }
};

const TestApp = struct {
    alloc: std.mem.Allocator = std.testing.allocator,
    herdr: RecordingClient = .{},
};

test "herdr provider reports the startup session and mirrors foreground activity" {
    const Provider = Runtime(TestApp);
    var app: TestApp = .{};

    Provider.configure(&app, "session-42");
    try std.testing.expect(app.herdr.initialized);
    try std.testing.expectEqualStrings("session-42", app.herdr.session_id.?);
    try std.testing.expectEqual(herdr.SessionStart.startup, app.herdr.session_start.?);

    Provider.syncActivity(&app, .working);
    Provider.syncActivity(&app, .awaiting_approval);
    Provider.syncActivity(&app, .awaiting_answer);
    Provider.syncActivity(&app, .idle);
    try std.testing.expectEqualSlices(
        herdr.Status,
        &.{ .working, .awaiting_approval, .awaiting_answer, .idle },
        app.herdr.statuses[0..app.herdr.status_count],
    );
}

test "herdr provider reports session changes with their start source" {
    const Provider = Runtime(TestApp);
    var app: TestApp = .{};

    Provider.configure(&app, null);
    try std.testing.expect(app.herdr.session_id == null);

    Provider.reportSession(&app, "session-new", .new);
    try std.testing.expectEqualStrings("session-new", app.herdr.session_id.?);
    try std.testing.expectEqual(herdr.SessionStart.new, app.herdr.session_start.?);

    Provider.reportSession(&app, null, .resumed);
    try std.testing.expectEqualStrings("session-new", app.herdr.session_id.?);
    try std.testing.expectEqual(herdr.SessionStart.new, app.herdr.session_start.?);
}

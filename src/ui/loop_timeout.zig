const std = @import("std");

pub const active_ms: i32 = 8;
pub const focused_ms: i32 = 1;
pub const idle_ms: i32 = 250;
pub const idle_wasm_ms: i32 = 16;

pub const Facts = struct {
    next_iteration_due: bool = false,
    first_frame_pending: bool = false,
    auth_refresh_active: bool = false,
    skills_refresh_active: bool = false,
    transcript_page_work_active: bool = false,
    file_listing_hold_pending: bool = false,
    pending_input_restore_active: bool = false,
    render_pending: bool = false,
    animation_visible: bool = false,
    pacer_pending: bool = false,
    agent_active: bool = false,
    /// Covers buffered terminal input across the action decoder (30 ms Esc flush),
    /// theme monitor (75 ms candidate buffer), cursor probe, native clear probe,
    /// and active bracketed paste.
    input_pending: bool = false,
    gesture_armed: bool = false,
    resize_pending: bool = false,
    open_ui_waiting: bool = false,

    fn focused(self: Facts) bool {
        return self.first_frame_pending or
            self.auth_refresh_active or
            self.skills_refresh_active or
            self.transcript_page_work_active or
            self.file_listing_hold_pending or
            self.pending_input_restore_active;
    }

    fn active(self: Facts) bool {
        return self.render_pending or
            self.animation_visible or
            self.pacer_pending or
            self.agent_active or
            self.input_pending or
            self.gesture_armed or
            self.resize_pending or
            self.open_ui_waiting;
    }
};

/// Returns the native poll timeout in ms. An idle session waits up to
/// `idle_ms`; any background work not listed here waits at most that long and
/// never hangs.
pub fn timeoutMs(facts: Facts) i32 {
    if (facts.next_iteration_due) return 0;
    if (facts.focused()) return @min(active_ms, focused_ms);
    if (facts.active()) return active_ms;
    return idle_ms;
}

test "focused UI workers retain a bounded native poll timeout" {
    try std.testing.expectEqual(@as(i32, 250), timeoutMs(.{}));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{ .first_frame_pending = true }));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{ .auth_refresh_active = true }));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{ .skills_refresh_active = true }));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{ .transcript_page_work_active = true }));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{ .file_listing_hold_pending = true }));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{ .pending_input_restore_active = true }));
    try std.testing.expectEqual(@as(i32, 1), timeoutMs(.{
        .first_frame_pending = true,
        .auth_refresh_active = true,
        .skills_refresh_active = true,
        .transcript_page_work_active = true,
        .file_listing_hold_pending = true,
        .pending_input_restore_active = true,
        .render_pending = true,
    }));
    try std.testing.expectEqual(@as(i32, 0), timeoutMs(.{ .next_iteration_due = true }));
    try std.testing.expectEqual(@as(i32, 0), timeoutMs(.{
        .next_iteration_due = true,
        .first_frame_pending = true,
        .auth_refresh_active = true,
        .skills_refresh_active = true,
        .transcript_page_work_active = true,
        .file_listing_hold_pending = true,
        .pending_input_restore_active = true,
        .render_pending = true,
    }));
}

test "timeoutMs returns active 8 ms timeout for each active fact" {
    const active_cases = [_]Facts{
        .{ .render_pending = true },
        .{ .animation_visible = true },
        .{ .pacer_pending = true },
        .{ .agent_active = true },
        .{ .input_pending = true },
        .{ .gesture_armed = true },
        .{ .resize_pending = true },
        .{ .open_ui_waiting = true },
    };
    for (active_cases) |facts| {
        try std.testing.expectEqual(@as(i32, 8), timeoutMs(facts));
    }
}

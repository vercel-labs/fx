const std = @import("std");
const activity_runtime = @import("activity_runtime.zig");
const types = @import("../shared/types.zig");

const recovered_status_visible_ms: i64 = 1_500;

const RouteRecoveryStatus = struct {
    status: types.RouteRecoveryStatus,
    label: [types.RouteRecoveryStatus.label_max_bytes + 64]u8 = undefined,
    label_len: usize = 0,
    expires_at_ms: i64 = 0,

    fn init(status: types.RouteRecoveryStatus, now_ms: i64) RouteRecoveryStatus {
        var result = RouteRecoveryStatus{
            .status = status,
            .expires_at_ms = if (status.isRecovered())
                now_ms + recovered_status_visible_ms
            else
                0,
        };
        var base_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
        const label = if (status.isRecovered())
            format_recovered_label(&result.label, status)
        else if (status.action == .waiting_for_connectivity)
            std.fmt.bufPrint(
                &result.label,
                "{s} · Esc to try later",
                .{status.label(&base_buf)},
            ) catch status.label(&result.label)
        else if (status.action == .paused)
            switch (status.required_action) {
                .continue_later => std.fmt.bufPrint(
                    &result.label,
                    "{s} · /continue to resume",
                    .{status.label(&base_buf)},
                ) catch status.label(&result.label),
                .inspect_uncertain_tool => std.fmt.bufPrint(
                    &result.label,
                    "{s} · inspect tool state before /continue",
                    .{status.label(&base_buf)},
                ) catch status.label(&result.label),
                .change_request => std.fmt.bufPrint(
                    &result.label,
                    "{s} · change the request to continue",
                    .{status.label(&base_buf)},
                ) catch status.label(&result.label),
                .none => status.label(&result.label),
            }
        else
            status.label(&result.label);
        store_label(result.label[0..], &result.label_len, label);
        return result;
    }

    fn projection(self: *const RouteRecoveryStatus) activity_runtime.ActivityProjection {
        return .{ .turn_thinking = .{
            .label = self.label[0..self.label_len],
            .tone = switch (self.status.tone()) {
                .warning => .warning,
                .success => .success,
                .danger => .danger,
            },
        } };
    }

    fn is_expired(self: RouteRecoveryStatus, now_ms: i64) bool {
        return self.expires_at_ms != 0 and now_ms >= self.expires_at_ms;
    }
};

const ApiStatus = struct {
    label: [512]u8 = undefined,
    label_len: usize = 0,
    tone: activity_runtime.ActivityProjection.Tone = .danger,

    fn init(label: []const u8, tone: activity_runtime.ActivityProjection.Tone) ApiStatus {
        var result = ApiStatus{ .tone = tone };
        store_label(result.label[0..], &result.label_len, label);
        return result;
    }

    fn projection(self: *const ApiStatus) activity_runtime.ActivityProjection {
        return .{ .turn_thinking = .{
            .label = self.label[0..self.label_len],
            .tone = self.tone,
        } };
    }
};

pub const State = union(enum) {
    none,
    route_recovery: RouteRecoveryStatus,
    api: ApiStatus,

    pub fn projection(self: *const State) ?activity_runtime.ActivityProjection {
        return switch (self.*) {
            .none => null,
            .route_recovery => |*status| status.projection(),
            .api => |*status| status.projection(),
        };
    }

    /// Returns the terminal status that must be committed to transcript
    /// history. Retry and recovered statuses are intentionally transient.
    pub fn retained_projection(self: *const State) ?activity_runtime.ActivityProjection {
        return switch (self.*) {
            .none => null,
            .route_recovery => |*status| switch (status.status.kind) {
                .terminal_provider_error,
                .unsafe_assistant_output,
                .unsafe_tool_start,
                .content_filter,
                => status.projection(),
                .auto_retry,
                .auto_recovered,
                .manual_retry_without_fast,
                .manual_recovered_without_fast,
                => null,
            },
            .api => |*status| status.projection(),
        };
    }

    pub fn set_route_recovery(
        self: *State,
        status: types.RouteRecoveryStatus,
        now_ms: i64,
    ) void {
        self.* = .{ .route_recovery = RouteRecoveryStatus.init(status, now_ms) };
    }

    pub fn set_api(
        self: *State,
        label: []const u8,
        tone: activity_runtime.ActivityProjection.Tone,
    ) void {
        self.* = .{ .api = ApiStatus.init(label, tone) };
    }

    pub fn clear_route_recovery(self: *State) bool {
        return switch (self.*) {
            .route_recovery => blk: {
                self.* = .none;
                break :blk true;
            },
            .none, .api => false,
        };
    }

    pub fn clear_recovered_route(self: *State) bool {
        return switch (self.*) {
            .route_recovery => |status| if (status.status.isRecovered()) blk: {
                self.* = .none;
                break :blk true;
            } else false,
            .none, .api => false,
        };
    }

    pub fn clear(self: *State) bool {
        return switch (self.*) {
            .none => false,
            .route_recovery, .api => blk: {
                self.* = .none;
                break :blk true;
            },
        };
    }

    pub fn reset(self: *State) void {
        self.* = .none;
    }

    pub fn expire_transient(self: *State, now_ms: i64) bool {
        return switch (self.*) {
            .route_recovery => |status| if (status.is_expired(now_ms)) blk: {
                self.* = .none;
                break :blk true;
            } else false,
            .none, .api => false,
        };
    }
};

fn format_recovered_label(buf: []u8, status: types.RouteRecoveryStatus) []const u8 {
    return switch (status.kind) {
        .auto_recovered => if (status.succeeded_attempt > 0 and status.attempt_limit > 0)
            std.fmt.bufPrint(
                buf,
                "✓ recovered · attempt {d}/{d}",
                .{ status.succeeded_attempt, status.attempt_limit },
            ) catch "✓ recovered"
        else
            "✓ recovered",
        .manual_recovered_without_fast => "✓ recovered · Fast disabled",
        else => status.label(buf),
    };
}

fn store_label(buffer: []u8, len: *usize, label: []const u8) void {
    if (label.ptr != buffer.ptr) {
        const copied_len = @min(label.len, buffer.len);
        @memcpy(buffer[0..copied_len], label[0..copied_len]);
        len.* = copied_len;
        return;
    }
    len.* = label.len;
}

test "worker status projects route recovery and expires recovered state" {
    var state: State = .none;
    state.set_route_recovery(.{
        .kind = .auto_retry,
        .failed_attempt = 1,
        .attempt_limit = 3,
    }, 1_000);

    switch (state.projection().?) {
        .turn_thinking => |projection| {
            try std.testing.expectEqual(activity_runtime.ActivityProjection.Tone.warning, projection.tone);
            try std.testing.expectEqualStrings("⚠ Provider unavailable · retrying request · attempt 1/3", projection.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    state.set_route_recovery(.{
        .kind = .auto_recovered,
        .succeeded_attempt = 3,
        .attempt_limit = 3,
    }, 1_000);
    try std.testing.expect(!state.expire_transient(2_499));
    try std.testing.expect(state.expire_transient(2_500));
    try std.testing.expect(state.projection() == null);
}

test "worker status API state is sticky until explicitly cleared" {
    var state: State = .none;
    state.set_api("⚠ API access denied · HTTP 403 · Provider: wafer", .danger);

    try std.testing.expect(!state.expire_transient(std.math.maxInt(i64)));
    switch (state.projection().?) {
        .turn_thinking => |projection| {
            try std.testing.expectEqual(activity_runtime.ActivityProjection.Tone.danger, projection.tone);
            try std.testing.expectEqualStrings("⚠ API access denied · HTTP 403 · Provider: wafer", projection.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.clear());
    try std.testing.expect(state.projection() == null);
}

test "worker status retains only terminal failures for the next prompt" {
    var state: State = .none;

    state.set_route_recovery(.{
        .kind = .auto_retry,
        .failed_attempt = 1,
        .attempt_limit = 3,
    }, 0);
    try std.testing.expect(state.retained_projection() == null);

    state.set_route_recovery(.{
        .kind = .auto_recovered,
        .succeeded_attempt = 2,
        .attempt_limit = 3,
    }, 0);
    try std.testing.expect(state.retained_projection() == null);

    state.set_route_recovery(.{ .kind = .content_filter }, 0);
    switch (state.retained_projection().?) {
        .turn_thinking => |projection| try std.testing.expectEqualStrings(
            "⚠ blocked · content filter",
            projection.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    state.set_api("⚠ API access denied", .danger);
    switch (state.retained_projection().?) {
        .turn_thinking => |projection| try std.testing.expectEqualStrings(
            "⚠ API access denied",
            projection.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "worker status route recovery labels expose required controls" {
    var state: State = .none;
    state.set_route_recovery(.{
        .kind = .auto_retry,
        .failed_attempt = 2,
        .attempt_limit = 10,
        .cause = .system_resumed,
        .action = .waiting_for_connectivity,
    }, 0);
    switch (state.projection().?) {
        .turn_thinking => |projection| try std.testing.expectEqualStrings(
            "⚠ Mac woke from sleep · waiting for connection · attempt 2/10 · Esc to try later",
            projection.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    state.set_route_recovery(.{
        .kind = .terminal_provider_error,
        .failed_attempt = 2,
        .attempt_limit = 10,
        .cause = .system_resumed,
        .action = .paused,
        .required_action = .continue_later,
    }, 0);
    switch (state.projection().?) {
        .turn_thinking => |projection| try std.testing.expectEqualStrings(
            "⚠ Mac woke from sleep · connection still unavailable · recovery paused · attempt 2/10 · /continue to resume",
            projection.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    state.set_route_recovery(.{
        .kind = .terminal_provider_error,
        .failed_attempt = 10,
        .attempt_limit = 10,
        .cause = .response_interrupted,
        .action = .paused,
        .required_action = .inspect_uncertain_tool,
    }, 0);
    switch (state.projection().?) {
        .turn_thinking => |projection| try std.testing.expectEqualStrings(
            "⚠ Response ended early · recovery paused after 10/10 attempts · inspect tool state before /continue",
            projection.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    state.set_route_recovery(.{ .kind = .manual_recovered_without_fast }, 0);
    switch (state.projection().?) {
        .turn_thinking => |projection| try std.testing.expectEqualStrings(
            "✓ recovered · Fast disabled",
            projection.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

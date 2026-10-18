const std = @import("std");
const activity_runtime = @import("activity_runtime.zig");
const types = @import("../shared/types.zig");

/// The warning sign before a waiting or "needs you" status.
const warning_sign = "⚠ ";
/// The thinking row's bullet, before a request that is on the wire again.
const live_bullet = "• ";
const label_capacity = types.RouteRecoveryStatus.label_max_bytes + @max(warning_sign.len, live_bullet.len);

/// The status row for a route recovery status. A recovery-module status shows
/// its `text`, or its `short` form when the row is narrower than `text`,
/// behind the sign its tone calls for. The module refreshes its own countdown
/// and clock once a second, so the row never computes time itself.
const RouteRecoveryStatus = struct {
    status: types.RouteRecoveryStatus,
    label: [label_capacity]u8 = undefined,
    label_len: usize = 0,
    short: [label_capacity]u8 = undefined,
    short_len: usize = 0,

    fn init(status: types.RouteRecoveryStatus) RouteRecoveryStatus {
        var result = RouteRecoveryStatus{ .status = status };
        if (status.fromModule()) {
            const sign = switch (status.tone()) {
                .live => live_bullet,
                .warning, .success, .danger => warning_sign,
            };
            result.label_len = signed(&result.label, sign, status.text.slice());
            if (status.short.len > 0) result.short_len = signed(&result.short, sign, status.short.slice());
        } else {
            const label = status.label(&result.label);
            store_label(result.label[0..], &result.label_len, label);
        }
        return result;
    }

    fn signed(buf: *[label_capacity]u8, sign: []const u8, text: []const u8) usize {
        @memcpy(buf[0..sign.len], sign);
        const len = @min(text.len, buf.len - sign.len);
        @memcpy(buf[sign.len..][0..len], text[0..len]);
        return sign.len + len;
    }

    fn projection(self: *const RouteRecoveryStatus) activity_runtime.ActivityProjection {
        return .{ .turn_thinking = .{
            .label = self.label[0..self.label_len],
            .short_label = if (self.short_len > 0) self.short[0..self.short_len] else null,
            .tone = switch (self.status.tone()) {
                .live => .live,
                .warning => .warning,
                .success => .success,
                .danger => .danger,
            },
        } };
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

    pub fn set_route_recovery(self: *State, status: types.RouteRecoveryStatus) void {
        self.* = .{ .route_recovery = RouteRecoveryStatus.init(status) };
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
};

fn store_label(buffer: []u8, len: *usize, label: []const u8) void {
    if (label.ptr != buffer.ptr) {
        const copied_len = @min(label.len, buffer.len);
        @memcpy(buffer[0..copied_len], label[0..copied_len]);
        len.* = copied_len;
        return;
    }
    len.* = label.len;
}

const testText = types.testRecoveryText;

fn expectLabel(state: *const State, label: []const u8, short: ?[]const u8, tone: activity_runtime.ActivityProjection.Tone) !void {
    switch (state.projection().?) {
        .turn_thinking => |projection| {
            try std.testing.expectEqualStrings(label, projection.label);
            if (short) |expected| {
                try std.testing.expectEqualStrings(expected, projection.short_label.?);
            } else {
                try std.testing.expect(projection.short_label == null);
            }
            try std.testing.expectEqual(tone, projection.tone);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "worker status shows the recovery module's text behind the sign its kind calls for" {
    var state: State = .none;
    state.set_route_recovery(.{
        .kind = .waiting,
        .text = testText("Connection lost · next try in 4s · attempt 2 · 12s"),
        .attempt = 2,
    });
    try expectLabel(&state, "⚠ Connection lost · next try in 4s · attempt 2 · 12s", null, .warning);

    // A resend wears the thinking row's bullet in its live tone. Each refresh
    // from the module replaces the row; nothing counts locally.
    state.set_route_recovery(.{
        .kind = .retrying,
        .text = testText("Connection lost · retrying · attempt 2 · 14s"),
        .attempt = 2,
    });
    try expectLabel(&state, "• Connection lost · retrying · attempt 2 · 14s", null, .live);

    state.set_route_recovery(.{
        .kind = .need_user,
        .need = .content_filter,
        .text = testText("Blocked by the content filter · press Esc and rephrase"),
        .short = testText("Blocked by content filter · Esc, then rephrase"),
    });
    try expectLabel(
        &state,
        "⚠ Blocked by the content filter · press Esc and rephrase",
        "⚠ Blocked by content filter · Esc, then rephrase",
        .warning,
    );

    try std.testing.expect(state.clear_route_recovery());
    try std.testing.expect(state.projection() == null);
}

test "worker status keeps fx's wording for terminal outcomes" {
    var state: State = .none;
    state.set_route_recovery(.{
        .kind = .terminal_provider_error,
        .attempt = 3,
        .cause = .response_interrupted,
    });
    try expectLabel(&state, "⚠ Response ended early · stopped after 3 attempts", null, .danger);
}

test "worker status API state is sticky until explicitly cleared" {
    var state: State = .none;
    state.set_api("⚠ API access denied · HTTP 403 · Provider: wafer", .danger);

    try std.testing.expect(!state.clear_route_recovery());
    try expectLabel(&state, "⚠ API access denied · HTTP 403 · Provider: wafer", null, .danger);
    try std.testing.expect(state.clear());
    try std.testing.expect(state.projection() == null);
}

//! The footer's open-checkpoint indicator (D120). It reads the tool
//! lifecycle events a local client and an attached one both receive: a
//! `checkpoint` that completes opens it, and a `rewind` that completes or
//! the turn's end closes it, as a checkpoint lasts for one turn.
const std = @import("std");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const max_goal_bytes = 96;
const max_call_id_bytes = 128;

pub const Indicator = struct {
    goal: [max_goal_bytes]u8 = undefined,
    goal_len: usize = 0,
    open: bool = false,
    /// The newest `checkpoint` or `rewind` call still running.
    pending: ?struct {
        rewind: bool,
        call_id: [max_call_id_bytes]u8,
        call_id_len: usize,
        goal: [max_goal_bytes]u8,
        goal_len: usize,
    } = null,

    /// Applies one event. Returns whether the label changed.
    pub fn observe(self: *Indicator, event: types.ToolLifecycleEvent) bool {
        switch (event) {
            .authoritative_started => |started| {
                const rewind = std.mem.eql(u8, started.tool_name, "rewind");
                if (!rewind and !std.mem.eql(u8, started.tool_name, "checkpoint")) return false;
                if (started.id.call_id.len > max_call_id_bytes) return false;
                self.pending = .{ .rewind = rewind, .call_id = undefined, .call_id_len = started.id.call_id.len, .goal = undefined, .goal_len = 0 };
                const pending = &self.pending.?;
                @memcpy(pending.call_id[0..started.id.call_id.len], started.id.call_id);
                if (!rewind) pending.goal_len = copyGoal(&pending.goal, started.arguments_json orelse "");
                return false;
            },
            .terminal => |terminal| {
                const pending = self.pending orelse return false;
                if (!std.mem.eql(u8, pending.call_id[0..pending.call_id_len], terminal.id.call_id)) return false;
                self.pending = null;
                if (terminal.outcome.kind != .completed) return false;
                if (pending.rewind) return self.close();
                self.goal = pending.goal;
                self.goal_len = pending.goal_len;
                self.open = true;
                return true;
            },
            .turn_finished => {
                self.pending = null;
                return self.close();
            },
            .provisional, .progress => return false,
        }
    }

    fn close(self: *Indicator) bool {
        const was_open = self.open;
        self.open = false;
        return was_open;
    }

    /// The open checkpoint's goal, or null.
    pub fn openGoal(self: *const Indicator) ?[]const u8 {
        return if (self.open) self.goal[0..self.goal_len] else null;
    }
};

/// The call's goal on one line, clipped to `out`.
fn copyGoal(out: *[max_goal_bytes]u8, arguments_json: []const u8) usize {
    var buf: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fixed.allocator(), arguments_json, .{}) catch return 0;
    if (parsed != .object) return 0;
    const value = parsed.object.get("goal") orelse return 0;
    if (value != .string) return 0;
    const goal = text_utils.utf8PrefixByBytes(std.mem.trim(u8, value.string, " \t\r\n"), max_goal_bytes);
    for (goal, 0..) |byte, i| out[i] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
    return goal.len;
}

test "a completed checkpoint opens the indicator until its rewind or the turn's end" {
    var indicator: Indicator = .{};
    const id: types.ToolLifecycleId = .{ .turn_id = 4, .call_id = "c1" };
    try std.testing.expect(!indicator.observe(.{ .authoritative_started = .{ .id = id, .reconciles_provisional_call_id = null, .tool_name = "checkpoint", .activity_kind = .read, .arguments_json = "{\"goal\":\"map the\\nparser\"}" } }));
    try std.testing.expectEqual(@as(?[]const u8, null), indicator.openGoal());
    try std.testing.expect(indicator.observe(.{ .terminal = .{ .id = id, .outcome = .{ .kind = .completed, .summary = "" } } }));
    try std.testing.expectEqualStrings("map the parser", indicator.openGoal().?);

    const rewind: types.ToolLifecycleId = .{ .turn_id = 4, .call_id = "w1" };
    _ = indicator.observe(.{ .authoritative_started = .{ .id = rewind, .reconciles_provisional_call_id = null, .tool_name = "rewind", .activity_kind = .read } });
    // A refused rewind leaves it open.
    try std.testing.expect(!indicator.observe(.{ .terminal = .{ .id = rewind, .outcome = .{ .kind = .failed, .summary = "" } } }));
    try std.testing.expect(indicator.openGoal() != null);
    try std.testing.expect(indicator.observe(.{ .turn_finished = .{ .turn_id = 4, .outcome = .completed } }));
    try std.testing.expectEqual(@as(?[]const u8, null), indicator.openGoal());
}

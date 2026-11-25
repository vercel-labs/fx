//! Bounded, always-on breadcrumbs of replies cut off at their output limit,
//! for the user-initiated /trace report. Each one says what fx did next: ran
//! the complete calls, asked for smaller steps, asked the model to go on from
//! its text or to take a smaller step, or ended the turn. The provider still answered such a reply with a success,
//! so the network record alone does not show it as a problem. Callers pass
//! model slugs, tool names, and counts only, never arguments or text.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const ring_capacity = 16;
const max_model_bytes = 96;
const max_tool_bytes = 64;

pub const Action = enum {
    ran_complete_calls,
    asked_smaller_steps,
    /// The reply was cut before any tool call; the model goes on from its text.
    continued_text,
    /// The reply was cut before any text or tool call; the model takes a
    /// smaller step.
    asked_to_act,
    ended_turn,
};

/// What the caller reports. Strings are copied, and cut on a UTF-8 boundary.
pub const Record = struct {
    model: []const u8,
    subagent_id: u64 = 0,
    turn_id: u64,
    step_id: u64,
    /// The limit the request asked for, or null when fx sent none.
    output_limit: ?u32,
    /// The limit fx raised the rest of the turn to, if it did.
    raised_to: ?u32,
    output_tokens: ?u64,
    complete_calls: usize,
    cut_calls: usize,
    /// Cut replies in a row, this one included.
    in_a_row: usize,
    /// The tool the first cut call named.
    cut_tool: ?[]const u8,
    action: Action,
};

pub const Stop = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    subagent_id: u64 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    output_limit: u32 = 0,
    raised_to: u32 = 0,
    output_tokens: u64 = 0,
    has_output_tokens: bool = false,
    complete_calls: u32 = 0,
    cut_calls: u32 = 0,
    in_a_row: u32 = 0,
    action: Action = .ran_complete_calls,
    model_len: u8 = 0,
    model_buf: [max_model_bytes]u8 = @splat(0),
    cut_tool_len: u8 = 0,
    cut_tool_buf: [max_tool_bytes]u8 = @splat(0),

    pub fn model(self: *const Stop) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn cutTool(self: *const Stop) ?[]const u8 {
        if (self.cut_tool_len == 0) return null;
        return self.cut_tool_buf[0..self.cut_tool_len];
    }

    pub fn outputLimit(self: *const Stop) ?u32 {
        return if (self.output_limit == 0) null else self.output_limit;
    }

    pub fn raisedTo(self: *const Stop) ?u32 {
        return if (self.raised_to == 0) null else self.raised_to;
    }

    pub fn outputTokens(self: *const Stop) ?u64 {
        return if (self.has_output_tokens) self.output_tokens else null;
    }
};

const Ring = struct {
    stops: [ring_capacity]Stop = std.mem.zeroes([ring_capacity]Stop),
    head: usize = 0,
    stored: usize = 0,
    total: u64 = 0,

    fn append(self: *Ring, stop: Stop) void {
        self.total +|= 1;
        self.stops[self.head] = stop;
        self.stops[self.head].sequence = self.total;
        self.head = (self.head + 1) % ring_capacity;
        self.stored = @min(self.stored + 1, ring_capacity);
    }

    fn snapshot(self: *const Ring, out: []Stop) usize {
        const count = @min(self.stored, out.len);
        for (out[0..count], 0..) |*stop, index| {
            stop.* = self.stops[(self.head + ring_capacity - count + index) % ring_capacity];
        }
        return count;
    }

    fn clear(self: *Ring) void {
        self.* = .{};
    }
};

var mutex: std.Io.Mutex = .init;
// Zero-initialized storage stays in .bss; unused slots are never read.
var ring: Ring = std.mem.zeroes(Ring);

fn saturate32(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

fn stopFrom(input: Record) Stop {
    var stop: Stop = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .subagent_id = input.subagent_id,
        .turn_id = input.turn_id,
        .step_id = input.step_id,
        .output_limit = input.output_limit orelse 0,
        .raised_to = input.raised_to orelse 0,
        .output_tokens = input.output_tokens orelse 0,
        .has_output_tokens = input.output_tokens != null,
        .complete_calls = saturate32(input.complete_calls),
        .cut_calls = saturate32(input.cut_calls),
        .in_a_row = saturate32(input.in_a_row),
        .action = input.action,
    };
    const model_text = text_utils.utf8PrefixByBytes(input.model, max_model_bytes);
    @memcpy(stop.model_buf[0..model_text.len], model_text);
    stop.model_len = @intCast(model_text.len);
    if (input.cut_tool) |tool| {
        const tool_text = text_utils.utf8PrefixByBytes(tool, max_tool_bytes);
        @memcpy(stop.cut_tool_buf[0..tool_text.len], tool_text);
        stop.cut_tool_len = @intCast(tool_text.len);
    }
    return stop;
}

pub fn record(input: Record) void {
    const stop = stopFrom(input);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.append(stop);
}

/// Copies the newest kept stops into `out`, oldest first.
pub fn snapshot(out: []Stop) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.snapshot(out);
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.clear();
}

test "output limit stops keep the newest in order, cut long names, and reset" {
    reset();
    defer reset();
    for (0..ring_capacity + 2) |index| {
        record(.{
            .model = "google/gemini-4-neon",
            .subagent_id = 110,
            .turn_id = 429,
            .step_id = index,
            .output_limit = 32_768,
            .raised_to = if (index == 0) 65_536 else null,
            .output_tokens = 32_768,
            .complete_calls = 6,
            .cut_calls = 1,
            .in_a_row = 1,
            .cut_tool = "edit_file",
            .action = .ran_complete_calls,
        });
    }
    var stops: [ring_capacity]Stop = undefined;
    try std.testing.expectEqual(ring_capacity, snapshot(&stops));
    try std.testing.expectEqual(@as(u64, 2), stops[0].step_id);
    try std.testing.expectEqual(@as(u64, ring_capacity + 2), stops[ring_capacity - 1].sequence);
    try std.testing.expectEqualStrings("google/gemini-4-neon", stops[0].model());
    try std.testing.expectEqualStrings("edit_file", stops[0].cutTool().?);
    try std.testing.expectEqual(@as(?u32, 32_768), stops[0].outputLimit());
    try std.testing.expectEqual(@as(?u32, null), stops[0].raisedTo());

    const long_name: [max_tool_bytes + 20]u8 = @splat('t');
    record(.{
        .model = "m",
        .turn_id = 1,
        .step_id = 1,
        .output_limit = null,
        .raised_to = null,
        .output_tokens = null,
        .complete_calls = 0,
        .cut_calls = 1,
        .in_a_row = 3,
        .cut_tool = &long_name,
        .action = .ended_turn,
    });
    var newest: [1]Stop = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshot(&newest));
    try std.testing.expectEqual(@as(usize, max_tool_bytes), newest[0].cutTool().?.len);
    try std.testing.expectEqual(@as(?u32, null), newest[0].outputLimit());
    try std.testing.expectEqual(@as(?u64, null), newest[0].outputTokens());
    try std.testing.expectEqual(Action.ended_turn, newest[0].action);

    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshot(&stops));
}

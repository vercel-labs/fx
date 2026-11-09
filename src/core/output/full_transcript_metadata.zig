//! The gray metadata lines of the Ctrl+O full transcript: when something
//! happened, and for a model call what it cost and the id its provider gave
//! it. Pure formatting; the screen places the lines.

const std = @import("std");
const local_time = @import("../shared/local_time.zig");
const types = @import("../shared/types.zig");

/// The topic of the full-only notice that carries one model call record,
/// live and when a saved session is replayed.
pub const model_call_topic = "model call";

/// `10:42:07`, the local clock time of `timestamp_ms`. Null for timestamps
/// outside the supported range or when `buf` is too small.
pub fn formatClock(buf: []u8, timestamp_ms: i64) ?[]const u8 {
    if (timestamp_ms <= 0) return null;
    const reading = local_time.local(timestamp_ms) orelse return null;
    return std.mem.print(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ reading.hour, reading.minute, reading.second }) catch null;
}

/// `Nov 4 10:42:07`, the local date and clock time of `timestamp_ms`.
pub fn formatDateClock(buf: []u8, timestamp_ms: i64) ?[]const u8 {
    if (timestamp_ms <= 0) return null;
    const reading = local_time.local(timestamp_ms) orelse return null;
    const month = @tagName(reading.month);
    return std.mem.print(buf, "{c}{s} {d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        std.ascii.toUpper(month[0]),
        month[1..],
        reading.day,
        reading.hour,
        reading.minute,
        reading.second,
    }) catch null;
}

/// The time a line shows: its clock, with the date first when its local
/// day isn't that of `previous_ms`, the line before it. With no line before
/// it to go by, the clock alone.
pub fn formatLineTime(buf: []u8, timestamp_ms: i64, previous_ms: ?i64) ?[]const u8 {
    const previous = previous_ms orelse return formatClock(buf, timestamp_ms);
    const day = local_time.local(timestamp_ms) orelse return null;
    const before = local_time.local(previous) orelse return formatClock(buf, timestamp_ms);
    const same_day = day.year == before.year and day.month == before.month and day.day == before.day;
    return if (same_day) formatClock(buf, timestamp_ms) else formatDateClock(buf, timestamp_ms);
}

/// `0.4 s`, `41.8 s`, `2m 44s`, `1h 3m`.
pub fn writeDuration(writer: *std.Io.Writer, elapsed_ms: u64) !void {
    if (elapsed_ms < std.time.ms_per_min) {
        return writer.print("{d}.{d} s", .{ elapsed_ms / std.time.ms_per_s, elapsed_ms % std.time.ms_per_s / 100 });
    }
    const seconds = elapsed_ms / std.time.ms_per_s;
    if (seconds < std.time.s_per_hour) return writer.print("{d}m {d}s", .{ seconds / 60, seconds % 60 });
    return writer.print("{d}h {d}m", .{ seconds / std.time.s_per_hour, seconds % std.time.s_per_hour / 60 });
}

/// `33,542`.
pub fn writeCount(writer: *std.Io.Writer, count: u64) !void {
    var digits: [20]u8 = undefined;
    const text = std.mem.print(&digits, "{d}", .{count}) catch unreachable;
    for (text, 0..) |digit, index| {
        if (index > 0 and (text.len - index) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

/// What a call line says when the provider sent no id, so a missing one
/// reads as missing rather than left out.
const no_generation_id = "no gen ID returned";

/// The model's name without its provider: `claude-opus-4.8`.
fn bareModel(model: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, model, '/') orelse return model;
    return model[slash + 1 ..];
}

/// The text after a call record's time. A finished call is one line:
/// `claude-opus-4.8 · 2.1 s · in 1,204 · out 188 · gen_01…`, with what the
/// call was for when it wasn't the turn's own. A failed call is two: what
/// failed, then where it went and what fx does next.
pub fn writeModelCallText(writer: *std.Io.Writer, record: types.ModelCallRecord) !void {
    const model = bareModel(record.model);
    if (record.outcome == .failed) {
        try writeFailureLabel(writer, record.failure orelse "request failed");
        try writer.print("\n{s} · {s}", .{ record.provider, model });
        if (record.served_by) |served_by| try writer.print(" via {s}", .{served_by});
        if (record.retry_after_s) |seconds| try writer.print(" · retrying in {d} s", .{seconds});
        try writer.writeAll(" · ");
        try writer.writeAll(record.generation_id orelse no_generation_id);
        return;
    }
    try writer.writeAll(model);
    if (record.served_by) |served_by| try writer.print(" via {s}", .{served_by});
    try writer.writeAll(" · ");
    try writeDuration(writer, record.elapsed_ms);
    if (record.input_tokens) |count| {
        try writer.writeAll(" · in ");
        try writeCount(writer, count);
    }
    if (record.output_tokens) |count| {
        try writer.writeAll(" · out ");
        try writeCount(writer, count);
    }
    try writer.print(" · {s}", .{record.generation_id orelse no_generation_id});
    if (record.outcome == .cancelled) try writer.writeAll(" · cancelled");
    if (record.purpose != .turn) try writer.print(" ({s})", .{purposeLabel(record.purpose)});
}

fn purposeLabel(purpose: types.ModelCallPurpose) []const u8 {
    return switch (purpose) {
        .turn => "turn",
        .compaction => "compaction",
    };
}

/// A step's call records, split where Ctrl+O shows them.
pub const StepCalls = struct {
    /// Before the step's text: failed attempts, and calls made for the step
    /// ahead of the one that wrote it, such as a compaction.
    before: []const types.ModelCallRecord = &.{},
    /// After the step's text: the call that wrote it.
    after: []const types.ModelCallRecord = &.{},
};

/// The records of step `step` from a turn's records in step order. The last
/// one wrote the step's text unless it failed (`tests/tla/full_detail/
/// FullDetailOrder.tla` ReplayMatchesSaved).
pub fn stepModelCalls(records: []const types.ModelCallRecord, step: usize) StepCalls {
    var start: usize = 0;
    while (start < records.len and records[start].after_tool_step_count < step) start += 1;
    var end = start;
    while (end < records.len and records[end].after_tool_step_count == step) end += 1;
    const own = records[start..end];
    if (own.len == 0 or own[own.len - 1].outcome == .failed) return .{ .before = own };
    return .{ .before = own[0 .. own.len - 1], .after = own[own.len - 1 ..] };
}

/// A failure kind's name as words: `rate_limited` reads `rate limited`.
fn writeFailureLabel(writer: *std.Io.Writer, kind: []const u8) !void {
    for (kind) |byte| try writer.writeByte(if (byte == '_') ' ' else byte);
}

test "full transcript metadata formats clock and date in local time" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("03:04:05", formatClock(&buf, 1_704_164_645_006).?);
    try std.testing.expectEqualStrings("Jan 2 03:04:05", formatDateClock(&buf, 1_704_164_645_006).?);
    local_time.test_zone = .{ .offset_s = -5 * 3600, .name = "EST" };
    defer local_time.test_zone = .utc;
    try std.testing.expectEqualStrings("Jan 1 22:04:05", formatDateClock(&buf, 1_704_164_645_006).?);
}

test "a line shows the date only when its day isn't the line before's" {
    var buf: [32]u8 = undefined;
    const evening: i64 = 1_704_236_398_000; // 2024-01-02 22:59:58 UTC
    try std.testing.expectEqualStrings("22:59:58", formatLineTime(&buf, evening, evening - 60_000).?);
    try std.testing.expectEqualStrings("22:59:58", formatLineTime(&buf, evening, null).?);
    // An hour and five seconds later it is the next day.
    try std.testing.expectEqualStrings("Jan 3 00:00:03", formatLineTime(&buf, evening + 3_605_000, evening).?);
}

test "full transcript metadata rejects unsupported timestamps" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(formatClock(&buf, 0) == null);
    try std.testing.expect(formatClock(&buf, -1) == null);
    try std.testing.expect(formatDateClock(&buf, local_time.max_timestamp_ms + 1) == null);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(formatClock(&tiny, 1_704_164_645_006) == null);
}

test "full transcript metadata formats durations and counts" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]u64{ 0, 380, 2_140, 41_800, 164_000, 3_780_000 }) |ms| {
        try writeDuration(&out.writer, ms);
        try out.writer.writeAll("|");
    }
    for ([_]u64{ 0, 188, 1_204, 33_542, 1_000_000 }) |count| {
        try writeCount(&out.writer, count);
        try out.writer.writeAll("|");
    }
    try std.testing.expectEqualStrings(
        "0.0 s|0.3 s|2.1 s|41.8 s|2m 44s|1h 3m|0|188|1,204|33,542|1,000,000|",
        out.written(),
    );
}

test "full transcript metadata writes a call record's text" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeModelCallText(&out.writer, .{
        .at_ms = 1,
        .elapsed_ms = 2_140,
        .provider = "gateway",
        .model = "anthropic/claude-opus-4.8",
        .generation_id = "gen_01JC7P5XQ2M8VZ",
        .input_tokens = 1_204,
        .output_tokens = 188,
    });
    try out.writer.writeAll("|");
    try writeModelCallText(&out.writer, .{
        .at_ms = 1,
        .elapsed_ms = 9_700,
        .purpose = .compaction,
        .provider = "gateway",
        .model = "anthropic/claude-opus-4.8",
        .input_tokens = 141_880,
    });
    try out.writer.writeAll("|");
    try writeModelCallText(&out.writer, .{
        .at_ms = 1,
        .outcome = .failed,
        .provider = "gateway",
        .model = "anthropic/claude-opus-4.8",
        .failure = "rate_limited",
        .retry_after_s = 12,
    });
    try std.testing.expectEqualStrings(
        "claude-opus-4.8 · 2.1 s · in 1,204 · out 188 · gen_01JC7P5XQ2M8VZ|" ++
            "claude-opus-4.8 · 9.7 s · in 141,880 · no gen ID returned (compaction)|" ++
            "rate limited\ngateway · claude-opus-4.8 · retrying in 12 s · no gen ID returned",
        out.written(),
    );
}

test "a step's failed attempts show before its text and the call that wrote it after" {
    const call = struct {
        fn at(step: usize, outcome: types.ModelCallOutcome, purpose: types.ModelCallPurpose) types.ModelCallRecord {
            return .{ .at_ms = 1, .provider = "gateway", .model = "m", .after_tool_step_count = step, .outcome = outcome, .purpose = purpose };
        }
    }.at;
    const records = [_]types.ModelCallRecord{
        call(0, .completed, .turn),
        call(1, .failed, .turn),
        call(1, .completed, .compaction),
        call(1, .completed, .turn),
        call(3, .failed, .turn),
        call(4, .cancelled, .turn),
    };
    const first = stepModelCalls(&records, 0);
    try std.testing.expectEqual(@as(usize, 0), first.before.len);
    try std.testing.expectEqual(@as(usize, 1), first.after.len);

    const retried = stepModelCalls(&records, 1);
    try std.testing.expectEqual(@as(usize, 2), retried.before.len);
    try std.testing.expectEqual(types.ModelCallOutcome.failed, retried.before[0].outcome);
    try std.testing.expectEqual(types.ModelCallPurpose.compaction, retried.before[1].purpose);
    try std.testing.expectEqual(types.ModelCallPurpose.turn, retried.after[0].purpose);

    // A step with no calls, and one whose only call failed.
    try std.testing.expectEqual(@as(usize, 0), stepModelCalls(&records, 2).before.len + stepModelCalls(&records, 2).after.len);
    try std.testing.expectEqual(@as(usize, 1), stepModelCalls(&records, 3).before.len);
    try std.testing.expectEqual(@as(usize, 0), stepModelCalls(&records, 3).after.len);
    // A cancelled call still wrote what text the step has.
    try std.testing.expectEqual(@as(usize, 1), stepModelCalls(&records, 4).after.len);
    try std.testing.expectEqual(@as(usize, 0), stepModelCalls(&records, 9).after.len);
}

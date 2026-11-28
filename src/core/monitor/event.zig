//! What one monitor event says and when it may go. Pure: the caller reads the
//! clock and owns every effect, so tests choose the time.

const std = @import("std");
const agent_frame = @import("../shared/agent_frame.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// The least time between two events of one monitor. Output that arrives
/// sooner waits and goes in the next event.
pub const min_gap_ms: i64 = 10_000;

/// Most events one monitor holds while the agent cannot take them. Older
/// ones are dropped and counted.
pub const max_held: usize = 20;

/// Most bytes of events one message carries. Older events that do not fit
/// are dropped and counted.
pub const max_digest_bytes: usize = 16 * 1024;

/// How often the main loop looks at its monitors.
pub const poll_gap_ms: i64 = 1_000;

/// Most lines one event shows. The rest are counted.
pub const max_lines: usize = 20;

/// Most bytes of output one event shows.
pub const max_bytes: usize = 2048;

/// Whether a monitor with output waiting may send an event now. A monitor
/// whose command ended always may, so the end is never held back. A clock
/// that moved back counts as due, so a jump never silences a monitor.
pub fn due(now_ms: i64, last_event_ms: ?i64, ended: bool, gap_ms: i64) bool {
    if (ended) return true;
    const last = last_event_ms orelse return true;
    if (now_ms < last) return true;
    return now_ms - last >= gap_ms;
}

/// Whether the main loop looks at its monitors now.
pub fn pollDue(now_ms: i64, last_poll_ms: i64, gap_ms: i64) bool {
    return now_ms < last_poll_ms or now_ms - last_poll_ms >= gap_ms;
}

pub const Composed = struct {
    /// The shown lines, terminal-safe, then `+k more lines` when some were
    /// left out. Owned.
    text: []u8,
    /// Lines of `output` that are not in `text`.
    more_lines: usize,

    pub fn deinit(self: Composed, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

/// The event text for `output`: at most `max_lines` lines and `max_bytes`
/// bytes, cut at a line end, with the count of what was left out. A single
/// line longer than the byte cap is cut on a character boundary. Caller owns
/// the result.
pub fn compose(alloc: Allocator, output: []const u8) Allocator.Error!Composed {
    const trimmed = std.mem.trimEnd(u8, output, "\r\n");
    var shown_end: usize = 0;
    var shown: usize = 0;
    var total: usize = 0;
    var full = false;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.findScalarPos(u8, trimmed, start, '\n');
        const line_end = newline orelse trimmed.len;
        total += 1;
        if (!full) {
            if (shown < max_lines and line_end <= max_bytes) {
                shown += 1;
                shown_end = line_end;
            } else {
                full = true;
                if (shown == 0) {
                    // The first line alone is over the cap.
                    shown = 1;
                    shown_end = characterBoundary(trimmed[0..line_end], max_bytes);
                }
            }
        }
        start = (newline orelse break) + 1;
    }
    const kept = std.mem.trimEnd(u8, trimmed[0..shown_end], "\r\n");
    var shown_text: std.ArrayList(u8) = .empty;
    defer shown_text.deinit(alloc);
    // Each line is encoded alone: the encoder shows a line break as an
    // escape, and the event keeps its lines.
    // An escape is longer than the byte it shows, so the cap counts the
    // encoded text, and a line that no longer fits is counted as left out.
    var kept_lines = std.mem.splitScalar(u8, kept, '\n');
    var emitted: usize = 0;
    while (kept_lines.next()) |line| {
        const separator: usize = if (emitted > 0) 1 else 0;
        if (shown_text.items.len + separator >= max_bytes) break;
        var encoded = try text_utils.encodeTerminalSafe(alloc, std.mem.trimEnd(u8, line, "\r"), max_bytes - shown_text.items.len - separator);
        defer encoded.deinit(alloc);
        if (separator == 1) try shown_text.append(alloc, '\n');
        try shown_text.appendSlice(alloc, encoded.bytes);
        emitted += 1;
        if (encoded.truncated) break;
    }
    const more = total - emitted;
    const text = if (more == 0)
        try alloc.dupe(u8, shown_text.items)
    else if (shown_text.items.len == 0)
        try alloc.print("+{d} more {s}", .{ more, if (more == 1) "line" else "lines" })
    else
        try alloc.print("{s}\n+{d} more {s}", .{ shown_text.items, more, if (more == 1) "line" else "lines" });
    return .{ .text = text, .more_lines = more };
}

fn characterBoundary(line: []const u8, limit: usize) usize {
    var end = @min(line.len, limit);
    while (end > 0 and end < line.len and (line[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

/// One event a monitor held while the agent could not take it.
pub const Held = struct {
    /// Owned by whoever holds the event.
    text: []u8,
    at_ms: i64,
};

fn writeAgo(writer: *std.Io.Writer, seconds: i64) std.Io.Writer.Error!void {
    if (seconds < 120) return writer.print("{d}s", .{@max(seconds, 0)});
    return writer.print("{d}m", .{@divFloor(seconds, 60)});
}

/// The one message that carries the events a monitor held: a first line that
/// counts the events dropped before them, then the newest events that fit
/// `max_digest_bytes`, oldest first, each marked with its age. A single event
/// and nothing dropped goes as it is. Caller owns the result.
pub fn digest(alloc: Allocator, held: []const Held, dropped: u64, now_ms: i64) Allocator.Error![]u8 {
    var first: usize = held.len;
    var used: usize = 0;
    while (first > 0) {
        const next = used + held[first - 1].text.len + 32;
        if (next > max_digest_bytes and first < held.len) break;
        used = next;
        first -= 1;
    }
    const total_dropped = dropped + first;
    const shown = held[first..];
    if (total_dropped == 0 and shown.len == 1) return alloc.dupe(u8, shown[0].text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    if (total_dropped > 0) writer.print("+{d} earlier {s} dropped\n", .{ total_dropped, if (total_dropped == 1) "event" else "events" }) catch return error.OutOfMemory;
    for (shown, 0..) |event, index| {
        if (index > 0 or total_dropped > 0) writer.writeByte('\n') catch return error.OutOfMemory;
        writer.writeByte('[') catch return error.OutOfMemory;
        writeAgo(writer, @divFloor(now_ms - event.at_ms, 1000)) catch return error.OutOfMemory;
        writer.print(" ago]\n{s}\n", .{event.text}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// A hash of an event's text, to drop an event that repeats the last one.
pub fn textHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

/// The text of the last event: how the command ended.
pub fn endedText(alloc: Allocator, how: Ended) Allocator.Error![]u8 {
    return switch (how) {
        .exit_code => |code| alloc.print("monitor ended: the command exited with code {d}", .{code}),
        .signal => |number| alloc.print("monitor ended: the command was killed by signal {d}", .{number}),
        .unknown => alloc.dupe(u8, "monitor ended: the command is no longer running"),
    };
}

pub const Ended = union(enum) {
    exit_code: i64,
    signal: u32,
    unknown,
};

/// The message the agent receives: a frame of its own (`agent_frame`), drawn
/// like a subagent's message, with `"source":"monitor"` naming what it is
/// and `output_file` naming the file that holds everything the command printed. The command's output sits in one JSON string, so it
/// can never pass as the frame or as the user's words. Caller owns the
/// result.
pub fn frame(alloc: Allocator, label: []const u8, id: []const u8, body: []const u8, output_file: ?[]const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll(agent_frame.monitor_header) catch return error.OutOfMemory;
    std.json.Stringify.value(.{
        .agent = label,
        .child_id = id,
        .source = "monitor",
        .output_file = output_file,
        .message = body,
    }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "an event may go when nothing went yet, when the gap passed, or when the command ended" {
    try std.testing.expect(due(1_000, null, false, min_gap_ms));
    try std.testing.expect(!due(1_000 + min_gap_ms - 1, 1_000, false, min_gap_ms));
    try std.testing.expect(due(1_000 + min_gap_ms, 1_000, false, min_gap_ms));
    try std.testing.expect(due(1_001, 1_000, true, min_gap_ms));
    try std.testing.expect(due(500, 1_000, false, min_gap_ms));
    try std.testing.expect(due(1_200, 1_000, false, 200));
}

test "the loop polls once a second and a clock that moved back polls at once" {
    try std.testing.expect(!pollDue(1_999, 1_000, poll_gap_ms));
    try std.testing.expect(pollDue(2_000, 1_000, poll_gap_ms));
    try std.testing.expect(pollDue(10, 1_000, poll_gap_ms));
    try std.testing.expect(pollDue(1_150, 1_000, 100));
}

test "a short output goes whole" {
    const composed = try compose(std.testing.allocator, "build ok\nlint ok\n");
    defer composed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("build ok\nlint ok", composed.text);
    try std.testing.expectEqual(@as(usize, 0), composed.more_lines);
}

test "output over the line cap shows the first lines and counts the rest" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    for (0..25) |index| try big.print(std.testing.allocator, "line {d}\n", .{index});
    const composed = try compose(std.testing.allocator, big.items);
    defer composed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), composed.more_lines);
    try std.testing.expect(std.mem.startsWith(u8, composed.text, "line 0\nline 1\n"));
    try std.testing.expect(std.mem.endsWith(u8, composed.text, "line 19\n+5 more lines"));
}

test "output over the byte cap stops at a line end" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    for (0..15) |_| {
        try big.appendNTimes(std.testing.allocator, 'x', 199);
        try big.append(std.testing.allocator, '\n');
    }
    const composed = try compose(std.testing.allocator, big.items);
    defer composed.deinit(std.testing.allocator);
    // 10 lines of 200 bytes fit in 2048.
    try std.testing.expectEqual(@as(usize, 5), composed.more_lines);
    try std.testing.expect(composed.text.len <= max_bytes + "\n+5 more lines".len);
}

test "one long line is cut on a character boundary" {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    for (0..2000) |_| try line.appendSlice(std.testing.allocator, "é");
    const composed = try compose(std.testing.allocator, line.items);
    defer composed.deinit(std.testing.allocator);
    try std.testing.expect(composed.text.len <= max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(composed.text));
    try std.testing.expectEqual(@as(usize, 0), composed.more_lines);
}

test "a single extra line says line, not lines" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    for (0..21) |index| try big.print(std.testing.allocator, "{d}\n", .{index});
    const composed = try compose(std.testing.allocator, big.items);
    defer composed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, composed.text, "+1 more line"));
}

test "escapes count toward the byte cap" {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(std.testing.allocator);
    for (0..10) |_| {
        for (0..100) |_| try raw.append(std.testing.allocator, 0x01);
        try raw.append(std.testing.allocator, '\n');
    }
    const composed = try compose(std.testing.allocator, raw.items);
    defer composed.deinit(std.testing.allocator);
    // Each byte shows as four, so the event stops well before ten lines.
    try std.testing.expect(composed.text.len <= max_bytes + "\n+10 more lines".len);
    try std.testing.expect(composed.more_lines > 0);
}

test "escape bytes in output never reach the event" {
    const composed = try compose(std.testing.allocator, "ok \x1b[31mred\x1b[0m\n");
    defer composed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.findScalar(u8, composed.text, 0x1b) == null);
}

test "the frame is a monitor event that names its source and its output file" {
    const text = try frame(std.testing.allocator, "ci", "shell-3", "check failed\nline \"two\"", "/Users/example/.fx/monitors/s/shell-3.log");
    defer std.testing.allocator.free(text);
    try std.testing.expect(agent_frame.isFrame(text));
    try std.testing.expect(std.mem.startsWith(u8, text, agent_frame.monitor_header));
    try std.testing.expect(std.mem.find(u8, text, "\"source\":\"monitor\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"output_file\":\"/Users/example/.fx/monitors/s/shell-3.log\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\"}\n"));
    // The output stays inside one JSON line.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
}

test "a frame with no output file leaves the field out" {
    const text = try frame(std.testing.allocator, "ci", "shell-3", "ok", null);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "output_file") == null);
}

test "a single held event goes as it is" {
    var text = "build ok".*;
    const held = [_]Held{.{ .text = &text, .at_ms = 5_000 }};
    const body = try digest(std.testing.allocator, &held, 0, 9_000);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("build ok", body);
}

test "held events go together with their ages and the count dropped before them" {
    var a = "first".*;
    var b = "second".*;
    const held = [_]Held{ .{ .text = &a, .at_ms = 1_000 }, .{ .text = &b, .at_ms = 61_000 } };
    const body = try digest(std.testing.allocator, &held, 340, 121_000);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("+340 earlier events dropped\n\n[2m ago]\nfirst\n\n[60s ago]\nsecond\n", body);
    const one = try digest(std.testing.allocator, held[1..], 1, 66_000);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("+1 earlier event dropped\n\n[5s ago]\nsecond\n", one);
}

test "events past the byte cap are dropped oldest first and counted" {
    var big: [4096]u8 = undefined;
    @memset(&big, 'x');
    var held: [8]Held = undefined;
    for (&held, 0..) |*slot, index| slot.* = .{ .text = &big, .at_ms = @intCast(index * 1000) };
    const body = try digest(std.testing.allocator, &held, 0, 10_000);
    defer std.testing.allocator.free(body);
    try std.testing.expect(body.len <= max_digest_bytes + 256);
    // Three of the eight events fit, so five were dropped.
    try std.testing.expect(std.mem.startsWith(u8, body, "+5 earlier events dropped\n"));
    // The newest event always goes, even when it alone is over the cap.
    var huge: [max_digest_bytes + 100]u8 = undefined;
    @memset(&huge, 'y');
    const only = [_]Held{.{ .text = &huge, .at_ms = 0 }};
    const kept = try digest(std.testing.allocator, &only, 0, 0);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqual(huge.len, kept.len);
}

test "equal text hashes equal and different text differs" {
    try std.testing.expectEqual(textHash("a"), textHash("a"));
    try std.testing.expect(textHash("a") != textHash("b"));
}

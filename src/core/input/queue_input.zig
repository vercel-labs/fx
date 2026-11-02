//! Parsing for queued prompts (D297): the `->` / `=>` composer shorthand, the
//! `/queue` command's arguments, compound delays (`3h`, `1h30m`), and
//! enumerated lists that split into one queued message per item. Ported
//! from proto's `queue-input.ts` and `duration-args.ts` so both products
//! queue the same text the same way. No clock and no I/O; only
//! `splitQueuedMessages` allocates.

const std = @import("std");
const local_time = @import("../shared/local_time.zig");

const Allocator = std.mem.Allocator;

/// Composer prefixes that queue a message for after the agent yields,
/// instead of steering the running turn.
pub const queue_prefixes = [_][]const u8{ "->", "=>" };

/// Longest delay `/queue` accepts, so a typo like `/queue 99999999h ship`
/// cannot queue a message that never comes due.
pub const max_queue_delay_ms: i64 = 365 * std.time.ms_per_day;

pub const queue_usage =
    "Usage: /queue [delay] <message>, or start a prompt with -> or =>. " ++
    "Examples: /queue ship it, /queue 3h run the benchmarks, /queue --cancel 1.";

/// What `/queue <args>` asks for. Text borrows `args`.
pub const QueueCommand = union(enum) {
    /// Show what is queued.
    status,
    /// Deliver `text` once the agent yields, after `delay_ms` when it is
    /// more than zero.
    add: struct { text: []const u8, delay_ms: i64 = 0 },
    /// Drop one entry by its 1-based position, or all of them.
    cancel: union(enum) { all, position: usize },
    /// Refuse, with this explanation for the user.
    err: []const u8,
};

/// Reads `/queue` arguments. A leading token is a delay only when it is a
/// bare compound duration followed by a message, so a message that merely
/// mentions a duration queues as written.
pub fn parseQueueArgs(args: []const u8) QueueCommand {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return .status;
    const token, const rest = splitFirstToken(trimmed);
    if (std.ascii.eqlIgnoreCase(token, "--cancel")) return parseCancelTarget(rest);
    if (rest.len == 0) return .{ .add = .{ .text = trimmed } };
    return switch (parseDuration(token)) {
        .unknown => .{ .add = .{ .text = trimmed } },
        .non_positive => .{ .err = "A queue delay must be more than zero. " ++ queue_usage },
        .ms => |delay_ms| if (delay_ms > max_queue_delay_ms)
            .{ .err = "A queue delay can be at most 365d." }
        else
            .{ .add = .{ .text = rest, .delay_ms = delay_ms } },
    };
}

/// The message after a leading `->` or `=>`, or null when the draft does
/// not start with one.
pub fn parseQueueShorthand(text: []const u8) ?[]const u8 {
    for (queue_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return std.mem.trim(u8, text[prefix.len..], " \t\r\n");
    }
    return null;
}

/// The messages `text` queues: one per item of a sequential enumerated
/// list (`1.` `2.`, `a)` `b)`, `i.` `ii.`), each with its continuation
/// lines, or else the whole text. Never empty for non-blank text. The
/// caller owns the slice and every message in it.
pub fn splitQueuedMessages(alloc: Allocator, text: []const u8) Allocator.Error![][]u8 {
    const source = std.mem.trim(u8, text, " \t\r\n");
    var messages: std.ArrayList([]u8) = .empty;
    errdefer freeMessages(alloc, messages.items);
    errdefer messages.deinit(alloc);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));

    var items: std.ArrayList(ListItem) = .empty;
    defer items.deinit(alloc);
    for (lines.items, 0..) |line, index| {
        const item = parseListItem(line, index) orelse continue;
        if (items.items.len == 0 or item.indent == items.items[0].indent) try items.append(alloc, item);
    }

    if (isQueuedList(items.items)) {
        for (items.items, 0..) |item, index| {
            const end = if (index + 1 < items.items.len) items.items[index + 1].line else lines.items.len;
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(alloc);
            try joined.appendSlice(alloc, item.content);
            for (lines.items[item.line + 1 .. end]) |line| {
                try joined.append(alloc, '\n');
                try joined.appendSlice(alloc, line);
            }
            const message = std.mem.trim(u8, joined.items, " \t\r\n");
            // An empty item means the text was not really a list.
            if (message.len == 0) break;
            try messages.append(alloc, try alloc.dupe(u8, message));
        } else return messages.toOwnedSlice(alloc);
        freeMessages(alloc, messages.items);
        messages.clearRetainingCapacity();
    }
    if (source.len > 0) try messages.append(alloc, try alloc.dupe(u8, source));
    return messages.toOwnedSlice(alloc);
}

pub fn freeMessages(alloc: Allocator, messages: []const []u8) void {
    for (messages) |message| alloc.free(message);
}

/// When a queued message comes due: a countdown and its local clock time,
/// `2h58m (14:32)`, or `1d17h (Sat 09:15)` on another day.
pub fn formatQueueDue(writer: *std.Io.Writer, due_at_ms: i64, now_ms: i64) std.Io.Writer.Error!void {
    // Round up to the second, so `/queue 2h` reads 2h, not 1h59m.
    const remaining = @max(0, due_at_ms - now_ms);
    try formatDuration(writer, @divCeil(remaining, std.time.ms_per_s) * std.time.ms_per_s);
    try writer.writeAll(" (");
    try formatClockTime(writer, due_at_ms, now_ms);
    try writer.writeByte(')');
}

/// `45s`, `3m5s`, `2h58m`, `1d2h`: the two largest units, as proto shows a
/// countdown.
pub fn formatDuration(writer: *std.Io.Writer, ms: i64) std.Io.Writer.Error!void {
    const units = [_]struct { ms: i64, name: []const u8 }{
        .{ .ms = std.time.ms_per_day, .name = "d" },
        .{ .ms = std.time.ms_per_hour, .name = "h" },
        .{ .ms = std.time.ms_per_min, .name = "m" },
        .{ .ms = std.time.ms_per_s, .name = "s" },
    };
    for (units, 0..) |unit, index| {
        if (ms < unit.ms and index + 1 < units.len) continue;
        try writer.print("{d}{s}", .{ @divFloor(ms, unit.ms), unit.name });
        if (index + 1 < units.len) {
            const next = units[index + 1];
            const rest = @divFloor(@mod(ms, unit.ms), next.ms);
            if (rest > 0) try writer.print("{d}{s}", .{ rest, next.name });
        }
        return;
    }
}

/// `14:32` when the due time falls on today's date, `Sat 09:15` otherwise.
pub fn formatClockTime(writer: *std.Io.Writer, due_at_ms: i64, now_ms: i64) std.Io.Writer.Error!void {
    const due = local_time.local(due_at_ms) orelse return writer.writeByte('?');
    const today = if (local_time.local(now_ms)) |now| localDay(now) else null;
    if (today != localDay(due)) {
        const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        try writer.print("{s} ", .{names[@intCast(@mod(localDay(due), 7))]});
    }
    try writer.print("{d:0>2}:{d:0>2}", .{ due.hour, due.minute });
}

/// Days from 1970-01-01 to a reading's local date (a Thursday is day 0).
fn localDay(reading: local_time.Reading) i64 {
    // Howard Hinnant's days_from_civil.
    const month: i64 = reading.month.numeric();
    const year: i64 = @as(i64, reading.year) - @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const day_of_year = @divFloor(153 * (month + (if (month > 2) @as(i64, -3) else 9)) + 2, 5) + @as(i64, reading.day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

const DurationParse = union(enum) { ms: i64, non_positive, unknown };

/// Milliseconds for one or more `<amount><unit>` segments (`3h`, `1h30m`).
fn parseDuration(token: []const u8) DurationParse {
    var total: i64 = 0;
    var rest = token;
    if (rest.len == 0) return .unknown;
    while (rest.len > 0) {
        const digits = runLength(rest, std.ascii.isDigit);
        const letters = runLength(rest[digits..], std.ascii.isAlphabetic);
        if (digits == 0 or letters == 0) return .unknown;
        const amount = std.fmt.parseInt(i64, rest[0..digits], 10) catch return .unknown;
        const unit = unitMs(rest[digits..][0..letters]) orelse return .unknown;
        if (amount == 0) return .non_positive;
        total = std.math.add(i64, total, std.math.mul(i64, amount, unit) catch return .unknown) catch return .unknown;
        rest = rest[digits + letters ..];
    }
    return .{ .ms = total };
}

const duration_units = std.StaticStringMap(i64).initComptime(.{
    .{ "s", std.time.ms_per_s },         .{ "sec", std.time.ms_per_s },     .{ "secs", std.time.ms_per_s },
    .{ "second", std.time.ms_per_s },    .{ "seconds", std.time.ms_per_s }, .{ "m", std.time.ms_per_min },
    .{ "min", std.time.ms_per_min },     .{ "mins", std.time.ms_per_min },  .{ "minute", std.time.ms_per_min },
    .{ "minutes", std.time.ms_per_min }, .{ "h", std.time.ms_per_hour },    .{ "hr", std.time.ms_per_hour },
    .{ "hrs", std.time.ms_per_hour },    .{ "hour", std.time.ms_per_hour }, .{ "hours", std.time.ms_per_hour },
    .{ "d", std.time.ms_per_day },       .{ "day", std.time.ms_per_day },   .{ "days", std.time.ms_per_day },
});

fn unitMs(unit: []const u8) ?i64 {
    var buf: [8]u8 = undefined;
    if (unit.len > buf.len) return null;
    return duration_units.get(std.ascii.lowerString(&buf, unit));
}

fn parseCancelTarget(rest: []const u8) QueueCommand {
    const usage: QueueCommand = .{ .err = "Usage: /queue --cancel <n|all>" };
    if (rest.len == 0 or std.ascii.eqlIgnoreCase(rest, "all")) return .{ .cancel = .all };
    const position = std.fmt.parseInt(usize, rest, 10) catch return usage;
    if (position == 0) return usage;
    return .{ .cancel = .{ .position = position } };
}

fn splitFirstToken(text: []const u8) struct { []const u8, []const u8 } {
    const boundary = std.mem.findAny(u8, text, " \t\r\n") orelse return .{ text, "" };
    return .{ text[0..boundary], std.mem.trim(u8, text[boundary + 1 ..], " \t\r\n") };
}

fn runLength(text: []const u8, comptime keep: fn (u8) bool) usize {
    var index: usize = 0;
    while (index < text.len and keep(text[index])) : (index += 1) {}
    return index;
}

/// One line of an enumerated list: `  2) text`.
const ListItem = struct {
    line: usize,
    indent: usize,
    marker: []const u8,
    punctuation: u8,
    content: []const u8,
};

fn parseListItem(line: []const u8, index: usize) ?ListItem {
    const body = std.mem.trimStart(u8, line, " \t");
    const marker_len = if (body.len > 0 and std.ascii.isDigit(body[0]))
        runLength(body, std.ascii.isDigit)
    else
        runLength(body, std.ascii.isAlphabetic);
    if (marker_len == 0 or marker_len >= body.len) return null;
    const punctuation = body[marker_len];
    if (punctuation != '.' and punctuation != ')') return null;
    return .{
        .line = index,
        .indent = line.len - body.len,
        .marker = body[0..marker_len],
        .punctuation = punctuation,
        .content = std.mem.trimStart(u8, body[marker_len + 1 ..], " \t"),
    };
}

/// At least two items with one punctuation mark, numbered in one family:
/// decimal, Roman, or letters of one case.
fn isQueuedList(items: []const ListItem) bool {
    if (items.len < 2) return false;
    for (items) |item| if (item.punctuation != items[0].punctuation) return false;
    if (std.ascii.isDigit(items[0].marker[0])) return isSequential(items, decodeDecimal);
    const upper = std.ascii.isUpper(items[0].marker[0]);
    for (items) |item| for (item.marker) |byte| {
        if (!std.ascii.isAlphabetic(byte) or std.ascii.isUpper(byte) != upper) return false;
    };
    return isSequential(items, decodeRoman) or isSequential(items, decodeLetters);
}

fn isSequential(items: []const ListItem, comptime decode: fn ([]const u8) ?i64) bool {
    var previous = decode(items[0].marker) orelse return false;
    for (items[1..]) |item| {
        const current = decode(item.marker) orelse return false;
        if (current != previous + 1) return false;
        previous = current;
    }
    return true;
}

fn decodeDecimal(marker: []const u8) ?i64 {
    for (marker) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(i64, marker, 10) catch null;
}

/// The value of a canonical Roman numeral (`IV`, not `IIII`), in either case.
fn decodeRoman(marker: []const u8) ?i64 {
    var buf: [16]u8 = undefined;
    if (marker.len > buf.len) return null;
    var rest: []const u8 = std.ascii.upperString(&buf, marker);
    const places = [_][]const []const u8{
        &.{ "MMM", "MM", "M" },
        &.{ "CM", "CD", "DCCC", "DCC", "DC", "D", "CCC", "CC", "C" },
        &.{ "XC", "XL", "LXXX", "LXX", "LX", "L", "XXX", "XX", "X" },
        &.{ "IX", "IV", "VIII", "VII", "VI", "V", "III", "II", "I" },
    };
    const values = [_][]const i64{
        &.{ 3000, 2000, 1000 },
        &.{ 900, 400, 800, 700, 600, 500, 300, 200, 100 },
        &.{ 90, 40, 80, 70, 60, 50, 30, 20, 10 },
        &.{ 9, 4, 8, 7, 6, 5, 3, 2, 1 },
    };
    var total: i64 = 0;
    for (places, values) |patterns, place_values| {
        for (patterns, place_values) |pattern, value| {
            if (std.mem.startsWith(u8, rest, pattern)) {
                total += value;
                rest = rest[pattern.len..];
                break;
            }
        }
    }
    return if (rest.len == 0 and total > 0) total else null;
}

/// `a` = 1 … `z` = 26, `aa` = 27, in either case.
fn decodeLetters(marker: []const u8) ?i64 {
    var value: i64 = 0;
    for (marker) |byte| {
        value = std.math.mul(i64, value, 26) catch return null;
        value += std.ascii.toLower(byte) - 'a' + 1;
    }
    return value;
}

test "the shorthand strips -> and => and nothing else" {
    try std.testing.expectEqualStrings("do it", parseQueueShorthand("-> do it").?);
    try std.testing.expectEqualStrings("do it", parseQueueShorthand("=>do it").?);
    try std.testing.expectEqualStrings("", parseQueueShorthand("-> ").?);
    try std.testing.expect(parseQueueShorthand("plain text") == null);
    try std.testing.expect(parseQueueShorthand("- > not shorthand") == null);
}

test "queue arguments read a delay only as a bare duration before a message" {
    try std.testing.expect(parseQueueArgs("  ") == .status);
    const plain = parseQueueArgs("ship it").add;
    try std.testing.expectEqualStrings("ship it", plain.text);
    try std.testing.expectEqual(@as(i64, 0), plain.delay_ms);
    const later = parseQueueArgs("1h30m run the benchmarks").add;
    try std.testing.expectEqualStrings("run the benchmarks", later.text);
    try std.testing.expectEqual(@as(i64, 90 * std.time.ms_per_min), later.delay_ms);
    try std.testing.expectEqualStrings("wait 3h then stop", parseQueueArgs("wait 3h then stop").add.text);
    try std.testing.expectEqualStrings("3h", parseQueueArgs("3h").add.text);
    try std.testing.expectEqualStrings("3x later", parseQueueArgs("3x later").add.text);
    try std.testing.expect(parseQueueArgs("0m ship") == .err);
    try std.testing.expect(parseQueueArgs("366d ship") == .err);
    try std.testing.expectEqual(@as(i64, 2 * std.time.ms_per_day), parseQueueArgs("2DAYS ship").add.delay_ms);
}

test "queue arguments cancel one entry or all" {
    try std.testing.expect(parseQueueArgs("--cancel").cancel == .all);
    try std.testing.expect(parseQueueArgs("--cancel all").cancel == .all);
    try std.testing.expectEqual(@as(usize, 2), parseQueueArgs("--cancel 2").cancel.position);
    try std.testing.expect(parseQueueArgs("--cancel 0") == .err);
    try std.testing.expect(parseQueueArgs("--cancel two") == .err);
}

fn expectSplit(text: []const u8, expected: []const []const u8) !void {
    const alloc = std.testing.allocator;
    const messages = try splitQueuedMessages(alloc, text);
    defer alloc.free(messages);
    defer freeMessages(alloc, messages);
    try std.testing.expectEqual(expected.len, messages.len);
    for (expected, messages) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a sequential list queues one message per item with its continuation lines" {
    try expectSplit("1. do the first\n   and go on\n2. do the second", &.{ "do the first\n   and go on", "do the second" });
    try expectSplit("a) one\nb) two\nc) three", &.{ "one", "two", "three" });
    try expectSplit("III. three\nIV. four", &.{ "three", "four" });
    try expectSplit("ix. nine\nx. ten", &.{ "nine", "ten" });
}

test "text that is not a sequential list queues whole" {
    try expectSplit("plain message", &.{"plain message"});
    try expectSplit("1. first", &.{"1. first"});
    try expectSplit("1. first\n3. third", &.{"1. first\n3. third"});
    try expectSplit("1. first\n2) second", &.{"1. first\n2) second"});
    try expectSplit("a. first\nB. second", &.{"a. first\nB. second"});
    try expectSplit("1.\n2. second", &.{"1.\n2. second"});
    try expectSplit("  \n", &.{});
}

test "countdowns show their two largest units" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { ms: i64, text: []const u8 }{
        .{ .ms = 0, .text = "0s" },
        .{ .ms = 45_000, .text = "45s" },
        .{ .ms = 65_000, .text = "1m5s" },
        .{ .ms = 2 * std.time.ms_per_hour + 58 * std.time.ms_per_min, .text = "2h58m" },
        .{ .ms = 17 * std.time.ms_per_hour, .text = "17h" },
        .{ .ms = 2 * std.time.ms_per_day + 3 * std.time.ms_per_hour, .text = "2d3h" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buf);
        try formatDuration(&writer, case.ms);
        try std.testing.expectEqualStrings(case.text, writer.buffered());
    }
}

test "a due time names its weekday only on another day" {
    local_time.test_zone = .utc;
    // 2024-01-02 03:04 UTC, a Tuesday.
    const due: i64 = 1_704_164_645_006;
    var buf: [32]u8 = undefined;
    var same_day = std.Io.Writer.fixed(&buf);
    try formatQueueDue(&same_day, due, due - 59_995);
    try std.testing.expectEqualStrings("1m (03:04)", same_day.buffered());
    var other_day = std.Io.Writer.fixed(&buf);
    try formatQueueDue(&other_day, due, due - std.time.ms_per_day);
    try std.testing.expectEqualStrings("1d (Tue 03:04)", other_day.buffered());
}

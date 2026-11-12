//! How much of its notes the model has written, counted from the reply as it
//! streams in. The request asks for one line per tool call, starting with
//! its ID (`T12:`, or `T3–T7:` for calls that share a line), then the
//! sections Rules, Facts, Decisions, Status and Open, and Earlier when a
//! compaction folds the one before it (`ledger.writeRequest`). Each call
//! noted and each section begun is one step of the count. Only the start of
//! each line is read, so a chunk can end anywhere, even inside an ID.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Receives every chunk of a reply as it arrives.
pub const TextSink = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, chunk: []const u8) void,

    pub fn write(self: TextSink, chunk: []const u8) void {
        self.write_fn(self.context, chunk);
    }
};

/// Receives the count, from 1 to 99, each time it goes up. It never sees
/// 100: the notes are not done until fx has read and saved them.
pub const Sink = struct {
    context: *anyopaque,
    written_fn: *const fn (context: *anyopaque, percent: u8) void,
};

/// The sections every request asks for, in order, and Earlier, which only a
/// request that folds the compaction before it asks for.
const sections = [_][]const u8{ "rules", "facts", "decisions", "status", "open", "earlier" };

/// The start of a line kept to read it. A tool ID range and a section name,
/// with Markdown around them, fit.
const line_start_bytes = 48;

/// The highest count before the notes are saved.
const most_before_saved = 99;

pub const Counter = struct {
    sink: ?Sink = null,
    /// Tool calls the whole compaction notes, in every part.
    total_tools: usize = 0,
    /// Sections the last part writes.
    total_sections: usize = sections.len - 1,
    /// Calls noted in the parts before this one.
    tools_before: usize = 0,
    /// This part's calls are numbered from here, one after another.
    first_tool: usize = 0,
    /// Which of this part's calls a line has noted. Borrowed from the part.
    covered: []bool = &.{},
    covered_count: usize = 0,
    /// Only the last part's sections count: each part writes them.
    sections_count: bool = false,
    seen: [sections.len]bool = @splat(false),
    seen_count: usize = 0,
    line: [line_start_bytes]u8 = undefined,
    line_len: usize = 0,
    /// The line's start was read; the rest of the line is skipped.
    line_read: bool = false,
    reported: u8 = 0,

    /// Sets what the compaction notes: `tools` calls across all its parts,
    /// and Earlier too when it folds the compaction before it.
    pub fn begin(self: *Counter, tools: usize, folds: bool) void {
        self.total_tools = tools;
        self.total_sections = if (folds) sections.len else sections.len - 1;
    }

    /// Starts a part whose `count` calls are numbered from `first_tool`.
    /// `covered` must hold `count` flags and outlive the part; `endPart`
    /// gives it back.
    pub fn startPart(self: *Counter, covered: []bool, first_tool: usize, last: bool) void {
        @memset(covered, false);
        self.covered = covered;
        self.covered_count = 0;
        self.first_tool = first_tool;
        self.sections_count = last;
        self.seen = @splat(false);
        self.seen_count = 0;
        // A part can number more calls than the turns showed before it was
        // prepared; the count never goes down for it.
        self.total_tools = @max(self.total_tools, self.tools_before + covered.len);
        self.endLine();
    }

    pub fn endPart(self: *Counter) void {
        self.tools_before += self.covered.len;
        self.covered = &.{};
        self.covered_count = 0;
        self.endLine();
    }

    pub fn textSink(self: *Counter) TextSink {
        return .{ .context = self, .write_fn = writeChunk };
    }

    fn writeChunk(context: *anyopaque, chunk: []const u8) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.feed(chunk);
    }

    /// Reads one chunk of a reply and reports the count when it went up.
    pub fn feed(self: *Counter, chunk: []const u8) void {
        for (chunk) |byte| {
            if (byte == '\n') {
                self.endLine();
                continue;
            }
            if (self.line_read) continue;
            self.line[self.line_len] = byte;
            self.line_len += 1;
            if (byte == ':' or self.line_len == self.line.len) self.readLine();
        }
        const now = self.percent();
        if (now <= self.reported) return;
        self.reported = now;
        if (self.sink) |sink| sink.written_fn(sink.context, now);
    }

    /// The share of the notes written so far, from 0 to 99.
    pub fn percent(self: *const Counter) u8 {
        const total = self.total_tools + self.total_sections;
        if (total == 0) return 0;
        const done = self.tools_before + self.covered_count + self.seen_count;
        return @intCast(@min(most_before_saved, done * 100 / total));
    }

    fn endLine(self: *Counter) void {
        if (!self.line_read and self.line_len > 0) self.readLine();
        self.line_len = 0;
        self.line_read = false;
    }

    fn readLine(self: *Counter) void {
        self.line_read = true;
        const text = trimDecoration(self.line[0..self.line_len]);
        if (toolRange(text)) |range| return self.cover(range.first, range.last);
        if (!self.sections_count) return;
        if (sectionIndex(text)) |index| {
            if (self.seen[index]) return;
            self.seen[index] = true;
            self.seen_count += 1;
        }
    }

    fn cover(self: *Counter, first: usize, last: usize) void {
        const len = self.covered.len;
        if (len == 0 or last < self.first_tool) return;
        const from = @max(first, self.first_tool) - self.first_tool;
        if (from >= len) return;
        const to = @min(last - self.first_tool, len - 1);
        for (self.covered[from .. to + 1]) |*flag| {
            if (flag.*) continue;
            flag.* = true;
            self.covered_count += 1;
        }
    }
};

fn isDecoration(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '-', '*', '#', '>', '`', '_', '+' => true,
        else => false,
    };
}

/// Drops the Markdown a model may put around a line's start: bullets,
/// headings, bold, quotes, and code marks.
fn trimDecoration(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and isDecoration(text[start])) start += 1;
    return text[start..];
}

const Range = struct { first: usize, last: usize };

/// `T12:` or a range of calls on one line, `T3–T7:` (an en dash, an em
/// dash, or a hyphen, the second `T` optional).
fn toolRange(text: []const u8) ?Range {
    if (text.len == 0 or text[0] != 'T') return null;
    var rest = text[1..];
    const first = leadingNumber(&rest) orelse return null;
    var last = first;
    rest = trimDecorationExceptDash(rest);
    if (dashLength(rest)) |dash| {
        rest = std.mem.trimStart(u8, rest[dash..], " ");
        if (rest.len > 0 and rest[0] == 'T') rest = rest[1..];
        last = leadingNumber(&rest) orelse return null;
        rest = trimDecorationExceptDash(rest);
    }
    if (rest.len == 0 or rest[0] != ':' or last < first) return null;
    return .{ .first = first, .last = last };
}

fn trimDecorationExceptDash(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and text[start] != '-' and isDecoration(text[start])) start += 1;
    return text[start..];
}

fn dashLength(text: []const u8) ?usize {
    for ([_][]const u8{ "\u{2013}", "\u{2014}", "-" }) |dash| {
        if (std.mem.startsWith(u8, text, dash)) return dash.len;
    }
    return null;
}

/// Reads the digits at the start of `rest` and moves past them. Null for
/// none, for 0, and for a number too long to be a tool ID.
fn leadingNumber(rest: *[]const u8) ?usize {
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest.*[end])) end += 1;
    if (end == 0 or end > 9) return null;
    const value = std.fmt.parseUnsigned(usize, rest.*[0..end], 10) catch return null;
    rest.* = rest.*[end..];
    return if (value == 0) null else value;
}

/// A line that begins a section: its name, with or without a colon after it.
fn sectionIndex(text: []const u8) ?usize {
    var end: usize = 0;
    while (end < text.len and std.ascii.isAlphabetic(text[end])) end += 1;
    if (end == 0) return null;
    const rest = trimDecoration(text[end..]);
    if (rest.len > 0 and rest[0] != ':') return null;
    for (sections, 0..) |name, index| {
        if (std.ascii.eqlIgnoreCase(text[0..end], name)) return index;
    }
    return null;
}

// Tests

const testing = std.testing;

const Reports = struct {
    values: [128]u8 = undefined,
    len: usize = 0,

    fn sink(self: *Reports) Sink {
        return .{ .context = self, .written_fn = record };
    }

    fn record(context: *anyopaque, value: u8) void {
        const self: *Reports = @ptrCast(@alignCast(context));
        if (self.len < self.values.len) self.values[self.len] = value;
        self.len += 1;
    }
};

/// A counter for one part of `tools` calls numbered from `first`.
fn onePart(covered: []bool, first: usize, folds: bool) Counter {
    var counter: Counter = .{};
    counter.begin(covered.len, folds);
    counter.startPart(covered, first, true);
    return counter;
}

const sample_notes =
    \\Turn 1
    \\In between: Ran the build and found the missing semicolon.
    \\T1: ran the build; it stopped at src/a.zig:4
    \\T2–T3: read src/a.zig twice
    \\
    \\Turn 2
    \\In between: none
    \\- **T4**: fixed the semicolon
    \\
    \\Rules:
    \\none
    \\
    \\## Facts
    \\F1 (T1): the build fails on a missing semicolon
    \\
    \\Decisions:
    \\none
    \\
    \\Status:
    \\S1 (T4): fixed
    \\
    \\Open:
    \\none
;

test "each tool call noted and each section begun is one step" {
    var covered: [4]bool = undefined;
    var counter = onePart(&covered, 1, false);
    var reports: Reports = .{};
    counter.sink = reports.sink();
    // Nothing yet: the model is still reading.
    try testing.expectEqual(@as(u8, 0), counter.percent());
    counter.feed("Turn 1\nIn between: Ran the build.\nT1: ran the build\n");
    // 1 of 4 calls and 5 sections.
    try testing.expectEqual(@as(u8, 11), counter.percent());
    counter.feed("T2\u{2013}T3: read src/a.zig twice\n");
    try testing.expectEqual(@as(u8, 33), counter.percent());
    counter.feed("- **T4**: fixed it\n\nRules:\nnone\n\n## Facts\nF1 (T1): x\n");
    try testing.expectEqual(@as(u8, 66), counter.percent());
    counter.feed("Decisions:\nnone\n\nStatus:\nS1: y\n\nOpen:\nnone");
    // Everything is written, but the notes are not saved yet.
    try testing.expectEqual(@as(u8, 99), counter.percent());
    try testing.expectEqualSlices(u8, &.{ 11, 33, 66, 99 }, reports.values[0..reports.len]);
}

test "a chunk can end anywhere, even inside an ID or a dash" {
    var whole_covered: [4]bool = undefined;
    var whole = onePart(&whole_covered, 1, false);
    whole.feed(sample_notes);
    for (1..sample_notes.len) |split| {
        var covered: [4]bool = undefined;
        var counter = onePart(&covered, 1, false);
        counter.feed(sample_notes[0..split]);
        counter.feed(sample_notes[split..]);
        try testing.expectEqual(whole.percent(), counter.percent());
    }
    try testing.expectEqual(@as(u8, 99), whole.percent());
}

test "a range is clipped to the part's calls, and a call noted twice counts once" {
    var covered: [5]bool = undefined;
    // This part's calls are T11 to T15.
    var counter = onePart(&covered, 11, false);
    counter.feed("T1\u{2014}T999: everything at once\n");
    try testing.expectEqual(@as(usize, 5), counter.covered_count);
    counter.feed("T12: again\nT12: and again\nT3: an earlier part's call\nT40: a later one\n");
    try testing.expectEqual(@as(usize, 5), counter.covered_count);
    try testing.expectEqual(@as(u8, 50), counter.percent());
}

test "without tool calls only the sections count" {
    var counter = onePart(&.{}, 1, false);
    counter.feed("Turn 1\nIn between: none\n\nRules:\nnone\n\nFacts:\n");
    try testing.expectEqual(@as(u8, 40), counter.percent());
    // A fold asks for Earlier too: six sections.
    var folds = onePart(&.{}, 1, true);
    folds.feed("Earlier:\nThe user asked for a fix.\n\nRules:\n");
    try testing.expectEqual(@as(u8, 33), folds.percent());
}

test "a reply that ignores the format stays at zero" {
    var covered: [3]bool = undefined;
    var counter = onePart(&covered, 1, false);
    counter.feed("Here is a summary of the work so far. The user wanted the build fixed: done.\n" ++
        "1. ran it\n2. fixed it\nTurn 1 had three calls, T1 T2 T3, and none failed.\nT: nothing\nT0: zero\nTx: not a number\n");
    try testing.expectEqual(@as(u8, 0), counter.percent());
}

test "a long line, a line without a newline, and a word that only starts like a section" {
    var covered: [2]bool = undefined;
    var counter = onePart(&covered, 1, false);
    // Only the start of a line is read; what follows it never counts.
    var long: [260]u8 = @splat('x');
    const tail = " T2: inside the line\n";
    @memcpy(long[0..4], "T1: ");
    @memcpy(long[long.len - tail.len ..], tail);
    counter.feed(&long);
    try testing.expectEqual(@as(usize, 1), counter.covered_count);
    counter.feed("Factsheet: not a section\nStatuses:\nOpen questions: none\n");
    try testing.expectEqual(@as(usize, 0), counter.seen_count);
    // The last line of a reply needs no newline.
    counter.feed("T2: last");
    try testing.expectEqual(@as(usize, 2), counter.covered_count);
    counter.feed("\nOpen");
    try testing.expectEqual(@as(usize, 0), counter.seen_count);
    counter.feed(":");
    try testing.expectEqual(@as(usize, 1), counter.seen_count);
}

test "a second reply, from a follow-up or a fallback model, never lowers the count" {
    var covered: [4]bool = undefined;
    var counter = onePart(&covered, 1, false);
    var reports: Reports = .{};
    counter.sink = reports.sink();
    counter.feed("T1: a\nT2: b\nT3: c\n");
    const before = counter.percent();
    // A new reply starts on a new line; it repeats what was counted.
    counter.feed("\n");
    counter.feed("T1: a again\nT2: b again\n");
    try testing.expectEqual(before, counter.percent());
    counter.feed("T4: d\n");
    try testing.expect(counter.percent() > before);
    for (1..reports.len) |i| try testing.expect(reports.values[i] > reports.values[i - 1]);
}

test "a compaction in two parts counts every call, and only the last part's sections" {
    var counter: Counter = .{};
    counter.begin(6, false);
    var first: [4]bool = undefined;
    counter.startPart(&first, 1, false);
    counter.feed("T1\u{2013}T4: all of them\nRules:\nnone\nFacts:\nF1: x\n");
    // 4 of 6 calls and 5 sections; the first part's sections do not count.
    try testing.expectEqual(@as(u8, 36), counter.percent());
    counter.endPart();
    var second: [2]bool = undefined;
    counter.startPart(&second, 5, true);
    try testing.expectEqual(@as(u8, 36), counter.percent());
    counter.feed("T5: e\nRules:\nnone\n");
    try testing.expectEqual(@as(u8, 54), counter.percent());
    counter.feed("T6: f\nFacts:\nDecisions:\nStatus:\nOpen:\n");
    try testing.expectEqual(@as(u8, 99), counter.percent());
}

test "a part with more calls than counted at the start never lowers the count" {
    var counter: Counter = .{};
    counter.begin(1, false);
    var covered: [3]bool = undefined;
    counter.startPart(&covered, 1, true);
    try testing.expectEqual(@as(usize, 3), counter.total_tools);
    counter.feed("T1\u{2013}T3: all\n");
    try testing.expectEqual(@as(u8, 37), counter.percent());
}

test "any split of the notes gives the same count as the whole reply" {
    const seed: u64 = 0x5eed_c0de;
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var whole_covered: [4]bool = undefined;
    var whole = onePart(&whole_covered, 1, false);
    whole.feed(sample_notes);
    for (0..500) |round| {
        var covered: [4]bool = undefined;
        var counter = onePart(&covered, 1, false);
        var last: u8 = 0;
        var at: usize = 0;
        while (at < sample_notes.len) {
            const size = random.intRangeAtMost(usize, 1, 24);
            const end = @min(sample_notes.len, at + size);
            counter.feed(sample_notes[at..end]);
            const now = counter.percent();
            if (now < last) std.debug.print("seed={x} round={d}\n", .{ seed, round });
            try testing.expect(now >= last);
            last = now;
            at = end;
        }
        try testing.expectEqual(whole.percent(), counter.percent());
    }
}

test "ten thousand calls, one byte at a time" {
    const tools = 10_000;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (1..tools + 1) |number| {
        if (number % 50 == 1) try text.print(testing.allocator, "\nTurn {d}\nIn between: worked.\n", .{number / 50 + 1});
        try text.print(testing.allocator, "T{d}: read a file and found what it needed\n", .{number});
    }
    try text.appendSlice(testing.allocator, "\nRules:\nnone\n\nFacts:\nF1: x\n\nDecisions:\nnone\n\nStatus:\nS1: done\n\nOpen:\nnone\n");
    const covered = try testing.allocator.alloc(bool, tools);
    defer testing.allocator.free(covered);
    var counter = onePart(covered, 1, false);
    var reports: Reports = .{};
    counter.sink = reports.sink();
    for (text.items) |byte| counter.feed(&.{byte});
    try testing.expectEqual(@as(usize, tools), counter.covered_count);
    try testing.expectEqual(@as(u8, 99), counter.percent());
    // Reported only when the count went up, never once per byte.
    try testing.expectEqual(@as(usize, 99), reports.len);
}

fn fuzzCount(_: void, smith: *testing.Smith) !void {
    var buffer: [1024]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const text = buffer[0..len];
    var flags: [2][64]bool = undefined;
    const count: usize = smith.valueRangeAtMost(u8, 0, 64);
    const first: usize = smith.valueRangeAtMost(u16, 1, 300);
    const folds = smith.valueRangeAtMost(u8, 0, 1) == 1;
    var whole = onePart(flags[0][0..count], first, folds);
    whole.feed(text);
    var split = onePart(flags[1][0..count], first, folds);
    var last: u8 = 0;
    var at: usize = 0;
    while (at < text.len) {
        const size: usize = if (smith.eos()) text.len else smith.valueRangeAtMost(u8, 1, 32);
        const end = @min(text.len, at + size);
        split.feed(text[at..end]);
        const now = split.percent();
        try testing.expect(now >= last);
        try testing.expect(now <= most_before_saved);
        last = now;
        at = end;
    }
    try testing.expectEqual(whole.percent(), split.percent());
    try testing.expect(whole.covered_count <= count);
}

test "the notes count keeps its laws on fuzzed replies" {
    try testing.fuzz({}, fuzzCount, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            sample_notes,
            "T1\u{2013}T999:\nRules:\nFacts:\nDecisions:\nStatus:\nOpen:\nEarlier:\n",
        }) ++ @import("fuzz_corpus").compaction_progress.*),
    });
}

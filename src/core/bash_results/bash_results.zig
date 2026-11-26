//! The results of a bash program as the model reads them: a header line, a
//! shape line, and a preview of a long output. Pure: no I/O, no clock, no
//! allocation. The caller holds the first and last parts of an output and
//! writes what this module plans.

const std = @import("std");

const Writer = std.Io.Writer;

/// The folder the model reads a saved output from, as the program and the model see it.
pub const shown_folder = "$FX_OUT";

/// What the model sees inline, and how much of a long output it sees.
pub const Limits = struct {
    /// A whole output up to this many characters (UTF-8 code points) is inline.
    inline_chars: usize = 12_000,
    /// A whole output up to this many bytes is inline. A preview shows at most
    /// this many bytes of the output, its head and its tail together. The caller
    /// passes its result cap minus its reserve.
    inline_bytes: usize,
    /// Characters a preview shows, its head and its tail together.
    preview_chars: usize = 1_500,
    /// Lines the head of a preview shows, and at most a quarter of `preview_chars`
    /// characters and of `inline_bytes` bytes.
    head_lines: usize = 5,
};

const error_words = [_][]const u8{ "error", "fail", "traceback", "exception" };
const longest_error_word = "traceback".len;

const kib: u64 = 1024;
const mib: u64 = 1024 * kib;

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn isJsonSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

/// One pass over an output's bytes. Feeding the same bytes in any split gives the same counts.
pub const Stats = struct {
    bytes: u64 = 0,
    chars: u64 = 0,
    line_ends: u64 = 0,
    /// The last byte fed is not a line end, so the last line has no line end yet.
    open_line: bool = false,
    error_lines: u64 = 0,
    /// The open line contains an error word.
    line_matched: bool = false,
    /// The last bytes of the open line, lowercased, as long as the longest error word.
    window: [longest_error_word]u8 = undefined,
    window_len: usize = 0,
    first_byte: ?u8 = null,
    last_byte: ?u8 = null,

    pub fn feed(self: *Stats, chunk: []const u8) void {
        for (chunk) |byte| self.feedByte(byte);
    }

    /// Line ends, and one more for a last line that has no line end.
    pub fn lines(self: Stats) u64 {
        return self.line_ends + @intFromBool(self.open_line);
    }

    /// Lines that contain `error`, `fail`, `traceback`, or `exception`, ASCII case-insensitive.
    pub fn errorLines(self: Stats) u64 {
        return self.error_lines + @intFromBool(self.line_matched);
    }

    /// The first non-space byte is `[` or `{`, and the last non-space byte is `]` or `}`.
    pub fn looksJson(self: Stats) bool {
        const first = self.first_byte orelse return false;
        const last = self.last_byte orelse return false;
        return (first == '[' or first == '{') and (last == ']' or last == '}');
    }

    fn feedByte(self: *Stats, byte: u8) void {
        self.bytes += 1;
        if (!isContinuation(byte)) self.chars += 1;
        if (!isJsonSpace(byte)) {
            if (self.first_byte == null) self.first_byte = byte;
            self.last_byte = byte;
        }
        if (byte == '\n') {
            self.line_ends += 1;
            if (self.line_matched) self.error_lines += 1;
            self.line_matched = false;
            self.window_len = 0;
            self.open_line = false;
            return;
        }
        self.open_line = true;
        self.pushWindow(std.ascii.toLower(byte));
    }

    fn pushWindow(self: *Stats, byte: u8) void {
        if (self.window_len < longest_error_word) {
            self.window[self.window_len] = byte;
            self.window_len += 1;
        } else {
            for (0..longest_error_word - 1) |index| self.window[index] = self.window[index + 1];
            self.window[longest_error_word - 1] = byte;
        }
        for (error_words) |word| {
            if (self.window_len >= word.len and std.mem.eql(u8, self.window[self.window_len - word.len .. self.window_len], word)) {
                self.line_matched = true;
            }
        }
    }
};

/// The part of an output the model sees, as slices of what the caller holds.
pub const Preview = struct {
    head: []const u8,
    tail: []const u8,
    hidden_lines: u64,
    hidden_chars: u64,
};

pub const Plan = union(enum) {
    /// The whole output.
    whole: []const u8,
    preview: Preview,
};

/// Plans what the model sees. `head` is the start of the output and `tail` its
/// end. When the output is whole and fits, the caller passes the whole output as
/// both. A head that is a piece of a longer output ends at a character boundary.
/// `tail` may be a piece of a longer output, a suffix that starts anywhere:
/// the text before its first line end is a partial line and is never shown as a
/// whole line. A preview shows at most `preview_chars` characters and at most
/// `inline_bytes` bytes, head and tail together, and never shows a byte twice.
pub fn plan(head: []const u8, tail: []const u8, stats: Stats, limits: Limits) Plan {
    const inline_bytes: u64 = @intCast(limits.inline_bytes);
    const inline_chars: u64 = @intCast(limits.inline_chars);
    if (stats.bytes <= inline_bytes and stats.chars <= inline_chars) return .{ .whole = head };
    const head_end = headCut(head, limits.head_lines, limits.preview_chars / 4, limits.inline_bytes / 4);
    const shown_head = head[0..head_end];
    const head_chars = charCount(shown_head);
    const piece = @as(u64, tail.len) < stats.bytes;
    const tail_start = @max(
        tailCut(tail, piece, limits.preview_chars -| head_chars, limits.inline_bytes -| head_end),
        clearOfHead(head_end, tail, stats),
    );
    const shown_tail = tail[tail_start..];
    const shown_lines = linesTouched(shown_head) + linesTouched(shown_tail);
    const shown_chars: u64 = @intCast(head_chars + charCount(shown_tail));
    return .{ .preview = .{
        .head = shown_head,
        .tail = shown_tail,
        .hidden_lines = stats.lines() -| shown_lines,
        .hidden_chars = stats.chars -| shown_chars,
    } };
}

fn charCount(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (!isContinuation(byte)) count += 1;
    }
    return count;
}

/// The lines that have a byte in `bytes`: the line ends inside it, and the line it starts on.
fn linesTouched(bytes: []const u8) u64 {
    if (bytes.len == 0) return 0;
    return @intCast(std.mem.count(u8, bytes[0 .. bytes.len - 1], "\n") + 1);
}

/// Moves a cut past continuation bytes, so that it never lands inside a character.
fn settle(bytes: []const u8, index: usize) usize {
    var at = index;
    while (at < bytes.len and isContinuation(bytes[at])) at += 1;
    return at;
}

/// The last cut at or before `at` that does not land inside a character.
fn boundaryAtOrBefore(bytes: []const u8, at: usize) usize {
    var index = @min(at, bytes.len);
    while (index > 0 and index < bytes.len and isContinuation(bytes[index])) index -= 1;
    return index;
}

/// `settle`, but never past `limit`: when settling would pass it, the cut backs
/// up to a character boundary instead.
fn settleWithin(bytes: []const u8, index: usize, limit: usize) usize {
    const settled = settle(bytes, index);
    return if (settled <= limit) settled else boundaryAtOrBefore(bytes, limit);
}

/// The end of the head's shown part: its first `lines_max` lines, and at most
/// `chars_max` characters and `bytes_max` bytes, cut between characters.
fn headCut(head: []const u8, lines_max: usize, chars_max: usize, bytes_max: usize) usize {
    if (lines_max == 0) return 0;
    var chars: usize = 0;
    var lines: usize = 0;
    for (head, 0..) |byte, index| {
        if (index >= bytes_max) return boundaryAtOrBefore(head, bytes_max);
        if (isContinuation(byte)) continue;
        if (chars == chars_max) return index;
        chars += 1;
        if (byte == '\n') {
            lines += 1;
            if (lines == lines_max) return settleWithin(head, index + 1, bytes_max);
        }
    }
    return head.len;
}

/// The start of the tail's shown part: the last whole lines that fit in
/// `chars_max` characters and `bytes_max` bytes, or when none fits, the end of
/// its last line. A piece's text before its first line end is a partial line, so
/// whole lines start only after that line end, and the end fallback stays there.
fn tailCut(tail: []const u8, piece: bool, chars_max: usize, bytes_max: usize) usize {
    const first_line_end: ?usize = if (std.mem.findScalar(u8, tail, '\n')) |at| at + 1 else null;
    const lines_floor = if (piece) (first_line_end orelse tail.len) else 0;
    const fallback_floor = if (piece) (first_line_end orelse 0) else 0;
    var start = tail.len;
    var chars_used: usize = 0;
    var bytes_used: usize = 0;
    var line_end = tail.len;
    while (line_end > lines_floor) {
        const search_end = if (tail[line_end - 1] == '\n') line_end - 1 else line_end;
        const line_start = if (std.mem.findScalarLast(u8, tail[lines_floor..search_end], '\n')) |previous| lines_floor + previous + 1 else lines_floor;
        const line_chars = charCount(tail[line_start..line_end]);
        const line_bytes = line_end - line_start;
        if (chars_used + line_chars > chars_max or bytes_used + line_bytes > bytes_max) break;
        chars_used += line_chars;
        bytes_used += line_bytes;
        start = line_start;
        line_end = line_start;
    }
    if (start < tail.len) return settle(tail, start);
    return endCut(tail, fallback_floor, chars_max, bytes_max);
}

/// The end fallback when no whole line fits: the last characters after `floor`,
/// within both budgets, starting at a character.
fn endCut(tail: []const u8, floor: usize, chars_max: usize, bytes_max: usize) usize {
    var at = tail.len;
    var count: usize = 0;
    while (at > floor and count < chars_max and tail.len - at < bytes_max) {
        at -= 1;
        if (!isContinuation(tail[at])) count += 1;
    }
    return settle(tail, at);
}

/// Where the tail's shown part must start to stay clear of the head's. The tail
/// is the end of the output, so it begins `stats.bytes - tail.len` bytes in.
fn clearOfHead(head_end: usize, tail: []const u8, stats: Stats) usize {
    const before_tail = stats.bytes -| @as(u64, tail.len);
    if (@as(u64, head_end) <= before_tail) return 0;
    return @min(tail.len, head_end - @as(usize, @intCast(before_tail)));
}

/// How a program ended, in the words the bash tool already uses.
pub const State = union(enum) {
    exit: u8,
    signal: u8,
    stopped,
    unknown,
};

/// Where the full output went, and what it kept.
pub const FileCut = struct {
    number: u64,
    /// Bytes kept from each end of the file.
    kept_each_bytes: u64,
};

pub const Saved = union(enum) {
    file: u64,
    file_cut: FileCut,
    not_saved_full,
    /// A short reason, written as it is.
    not_saved_error: []const u8,
};

pub const Header = struct {
    state: State,
    bytes: u64,
    lines: u64,
    saved: Saved,
};

pub fn writeHeader(w: *Writer, header: Header) Writer.Error!void {
    try w.writeByte('[');
    switch (header.state) {
        .exit => |code| try w.print("exit {d}", .{code}),
        .signal => |signal| try w.print("killed by signal {d}", .{signal}),
        .stopped => try w.writeAll("stopped"),
        .unknown => try w.writeAll("ended; exit status unknown"),
    }
    try w.writeAll(", ");
    try writeCount(w, header.lines, "line", "lines");
    try w.writeAll(", ");
    try writeSize(w, header.bytes);
    try w.writeAll(", ");
    switch (header.saved) {
        .file => |number| try w.print("{s}/{d}.txt", .{ shown_folder, number }),
        .file_cut => |cut| {
            try w.print("{s}/{d}.txt, the file keeps the first and last ", .{ shown_folder, cut.number });
            try writeMib(w, cut.kept_each_bytes);
        },
        .not_saved_full => try w.writeAll("not saved: the results folder is full"),
        .not_saved_error => |reason| try w.print("not saved: {s}", .{reason}),
    }
    try w.writeByte(']');
}

fn writeCount(w: *Writer, count: u64, singular: []const u8, plural: []const u8) Writer.Error!void {
    try w.print("{d} {s}", .{ count, if (count == 1) singular else plural });
}

fn writeSize(w: *Writer, bytes: u64) Writer.Error!void {
    if (bytes < kib) return w.print("{d} B", .{bytes});
    if (bytes < mib) return w.print("{d} KB", .{bytes / kib});
    return w.print("{d} MB", .{bytes / mib});
}

fn writeMib(w: *Writer, bytes: u64) Writer.Error!void {
    try w.print("{d} MiB", .{bytes / mib});
}

/// Where a preview's full output is, if anywhere.
pub const Notice = union(enum) {
    file: u64,
    not_saved,
    /// A program that has not ended. Its output is not in a file yet.
    running,
};

/// The line about the output's shape, when there is one.
pub fn writeShape(w: *Writer, stats: Stats, notice: Notice) Writer.Error!void {
    if (stats.looksJson()) {
        switch (notice) {
            .file => |number| try w.print("json: use jq on {s}/{d}.txt\n", .{ shown_folder, number }),
            .not_saved, .running => try w.writeAll("json: the output looks like JSON\n"),
        }
    } else if (stats.errorLines() > 0) {
        const count = stats.errorLines();
        try w.print("{d} {s} {s} error|fail|traceback|exception\n", .{
            count,
            if (count == 1) "line" else "lines",
            if (count == 1) "matches" else "match",
        });
    }
}

/// Writes the output: the whole text for `.whole`, otherwise the head, a note
/// with the hidden count, and the tail.
pub fn writePreview(w: *Writer, the_plan: Plan, notice: Notice) Writer.Error!void {
    switch (the_plan) {
        .whole => |text| try w.writeAll(text),
        .preview => |preview| {
            try w.writeAll(preview.head);
            if (preview.hidden_lines == 0 and preview.hidden_chars == 0) return w.writeAll(preview.tail);
            if (preview.head.len > 0 and preview.head[preview.head.len - 1] != '\n') try w.writeByte('\n');
            try writeHiddenNote(w, preview, notice);
            try w.writeByte('\n');
            try w.writeAll(preview.tail);
        },
    }
}

fn writeHiddenNote(w: *Writer, preview: Preview, notice: Notice) Writer.Error!void {
    try w.writeAll("[... ");
    if (preview.hidden_lines > 0) {
        try writeCount(w, preview.hidden_lines, "line", "lines");
    } else {
        try writeCount(w, preview.hidden_chars, "character", "characters");
    }
    try w.writeAll(" not shown; ");
    switch (notice) {
        .file => |number| try w.print("the full output is {s}/{d}.txt ...]", .{ shown_folder, number }),
        .not_saved => try w.writeAll("the output was not saved ...]"),
        .running => try w.writeAll("the program is still running ...]"),
    }
}

const max_test_lines = 400;

fn statsOf(text: []const u8) Stats {
    var stats: Stats = .{};
    stats.feed(text);
    return stats;
}

fn expectSameStats(want: Stats, got: Stats) !void {
    try std.testing.expectEqual(want.bytes, got.bytes);
    try std.testing.expectEqual(want.chars, got.chars);
    try std.testing.expectEqual(want.lines(), got.lines());
    try std.testing.expectEqual(want.errorLines(), got.errorLines());
    try std.testing.expectEqual(want.looksJson(), got.looksJson());
}

fn headerText(alloc: std.mem.Allocator, header: Header) ![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeHeader(&out.writer, header);
    return out.toOwnedSlice();
}

fn previewText(alloc: std.mem.Allocator, the_plan: Plan, notice: Notice) ![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writePreview(&out.writer, the_plan, notice);
    return out.toOwnedSlice();
}

/// Writes `count` lines of the form `line NNN ` then 50 `x` and a line end.
fn writeNumberedLines(w: *Writer, from: usize, to: usize, line_end: []const u8) !void {
    var number = from;
    while (number <= to) : (number += 1) {
        try w.print("line {d:0>3} ", .{number});
        try w.writeAll("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
        try w.writeAll(line_end);
    }
}

test "a small output that fits both inline limits is whole" {
    const text = "hello\nworld\n";
    try std.testing.expect(std.meta.activeTag(plan(text, text, statsOf(text), .{ .inline_bytes = 1_000 })) == .whole);
}

test "an empty output is whole, and a whole output writes exactly its text" {
    try std.testing.expect(std.meta.activeTag(plan("", "", statsOf(""), .{ .inline_bytes = 0 })) == .whole);
    const text = "one line\n";
    const written = try previewText(std.testing.allocator, .{ .whole = text }, .{ .file = 1 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(text, written);
}

test "exactly 12,000 characters is inline, and 12,001 is not" {
    const inline_text: [12_000]u8 = @splat('a');
    const longer: [12_001]u8 = @splat('a');
    const limits: Limits = .{ .inline_bytes = 20_000 };
    try std.testing.expect(std.meta.activeTag(plan(&inline_text, &inline_text, statsOf(&inline_text), limits)) == .whole);
    try std.testing.expect(std.meta.activeTag(plan(&longer, &longer, statsOf(&longer), limits)) == .preview);
}

test "a configured byte cap below 12,000 characters makes a long output a preview" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNumberedLines(&text.writer, 1, 50, "\n");
    const output = text.written();
    try std.testing.expectEqual(@as(usize, 3_000), output.len);
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 2_000 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(u64, 25), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(usize, 300), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 1_200), planned.preview.tail.len);
}

test "a preview shows the first five lines and the last whole lines that fit, with the hidden count between" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNumberedLines(&text.writer, 1, max_test_lines, "\n");
    const output = text.written();
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 1_500 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(u64, 375), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(u64, 22_500), planned.preview.hidden_chars);

    var want: Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    try writeNumberedLines(&want.writer, 1, 5, "\n");
    try want.writer.writeAll("[... 375 lines not shown; the full output is $FX_OUT/7.txt ...]\n");
    try writeNumberedLines(&want.writer, 381, 400, "\n");
    const written = try previewText(std.testing.allocator, planned, .{ .file = 7 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(want.written(), written);
}

test "CRLF lines count once each, and a head cut lands after a line end" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNumberedLines(&text.writer, 1, max_test_lines, "\r\n");
    const output = text.written();
    try std.testing.expectEqual(@as(u64, max_test_lines), statsOf(output).lines());
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 1_500 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqualStrings("\r\n", planned.preview.head[planned.preview.head.len - 2 ..]);
    try std.testing.expectEqual(@as(usize, 305), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 1_159), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 376), planned.preview.hidden_lines);
}

test "a last line too long for the budget shows its end, and the lines before it count as hidden" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (0..10) |_| try text.writer.writeAll("a\n");
    const long_line: [2_000]u8 = @splat('y');
    try text.writer.writeAll(&long_line);
    const output = text.written();
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 100 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 10), planned.preview.head.len);
    try std.testing.expectEqual(@as(u64, 5), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(u64, 1_920), planned.preview.hidden_chars);
    const want_tail: [90]u8 = @splat('y');
    try std.testing.expectEqualStrings(&want_tail, planned.preview.tail);
}

test "a huge line with no line end shows its start and its end, and names the characters between" {
    const huge: [100_000]u8 = @splat('x');
    const planned = plan(&huge, &huge, statsOf(&huge), .{ .inline_bytes = 1_000_000 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 375), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 1_125), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 0), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(u64, 98_500), planned.preview.hidden_chars);

    var want: Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    try want.writer.writeAll(huge[0..375]);
    try want.writer.writeAll("\n[... 98500 characters not shown; the full output is $FX_OUT/7.txt ...]\n");
    try want.writer.writeAll(huge[0..1_125]);
    const written = try previewText(std.testing.allocator, planned, .{ .file = 7 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(want.written(), written);
}

test "multibyte text cuts only between characters" {
    var buffer: [6_000]u8 = undefined;
    for (0..2_000) |index| @memcpy(buffer[index * 3 ..][0..3], "€");
    const output: []const u8 = &buffer;
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 100 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 24), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 75), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 1_967), planned.preview.hidden_chars);
    try std.testing.expect(planned.preview.head.len + planned.preview.tail.len <= 100);
    try std.testing.expect(std.unicode.utf8ValidateSlice(planned.preview.head));
    try std.testing.expect(std.unicode.utf8ValidateSlice(planned.preview.tail));
}

test "a four-byte character that ends on the head's last byte is kept whole" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    const letters: [21]u8 = @splat('a');
    try text.writer.writeAll(&letters);
    try text.writer.writeAll("\u{1F600}");
    const tail_text: [2_000]u8 = @splat('b');
    try text.writer.writeAll(&tail_text);
    const output = text.written();
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 100 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 25), planned.preview.head.len);
    try std.testing.expect(std.mem.endsWith(u8, planned.preview.head, "\u{1F600}"));
}

test "a four-byte character that crosses the head's byte budget is left out whole" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    const letters: [22]u8 = @splat('a');
    try text.writer.writeAll(&letters);
    try text.writer.writeAll("\u{1F600}");
    const tail_text: [2_000]u8 = @splat('b');
    try text.writer.writeAll(&tail_text);
    const output = text.written();
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 100 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 22), planned.preview.head.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(planned.preview.head));
}

test "a cut near every character boundary stays valid UTF-8 and inside the budget" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (0..500) |_| try text.writer.writeAll("aé€\u{1F600}");
    const output = text.written();
    for (4..61) |preview_chars| {
        const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 1, .preview_chars = preview_chars });
        try std.testing.expect(std.meta.activeTag(planned) == .preview);
        try std.testing.expect(std.unicode.utf8ValidateSlice(planned.preview.head));
        try std.testing.expect(std.unicode.utf8ValidateSlice(planned.preview.tail));
        const shown = (try std.unicode.utf8CountCodepoints(planned.preview.head)) + (try std.unicode.utf8CountCodepoints(planned.preview.tail));
        try std.testing.expect(shown <= preview_chars);
        try std.testing.expect(planned.preview.head.len + planned.preview.tail.len <= 1);
    }
}

test "an output over the byte cap is a preview, even when its characters fit the preview budget" {
    const text = "short text\nsecond line\n";
    const planned = plan(text, text, statsOf(text), .{ .inline_bytes = 5 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqualStrings("s", planned.preview.head);
    try std.testing.expectEqualStrings("ine\n", planned.preview.tail);
}

test "a running program's preview names no file and says it is still running" {
    const planned: Plan = .{ .preview = .{ .head = "a\n", .tail = "z\n", .hidden_lines = 375, .hidden_chars = 0 } };
    const written = try previewText(std.testing.allocator, planned, .running);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("a\n[... 375 lines not shown; the program is still running ...]\nz\n", written);
}

test "an output that was not saved says so in the preview note" {
    const planned: Plan = .{ .preview = .{ .head = "a\n", .tail = "z\n", .hidden_lines = 375, .hidden_chars = 0 } };
    const written = try previewText(std.testing.allocator, planned, .not_saved);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("a\n[... 375 lines not shown; the output was not saved ...]\nz\n", written);
}

test "one hidden line uses the singular in the preview note" {
    const planned: Plan = .{ .preview = .{ .head = "a\n", .tail = "z\n", .hidden_lines = 1, .hidden_chars = 0 } };
    const written = try previewText(std.testing.allocator, planned, .{ .file = 7 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("a\n[... 1 line not shown; the full output is $FX_OUT/7.txt ...]\nz\n", written);
}

test "the stats are the same for every split of the same bytes" {
    const sample = "Error line\r\nTraceback (most recent)\nno match here\n\u{20AC} tail fail\n[1, 2]\n";
    const whole = statsOf(sample);
    for (0..sample.len + 1) |split| {
        var stats: Stats = .{};
        stats.feed(sample[0..split]);
        stats.feed(sample[split..]);
        try expectSameStats(whole, stats);
    }
    var three_way: usize = 1;
    while (three_way < sample.len) : (three_way += 7) {
        const second = @min(sample.len, three_way + 9);
        var stats: Stats = .{};
        stats.feed(sample[0..three_way]);
        stats.feed(sample[three_way..second]);
        stats.feed(sample[second..]);
        try expectSameStats(whole, stats);
    }
}

test "error words split across chunks count once per line" {
    var stats: Stats = .{};
    for ([_][]const u8{ "Trace", "back\n", "EXC", "eption and FA", "il\n", "err", "or\n", "exception\n", "errors errors\n", "exceptio\n", "tracebac\n", "err\n" }) |chunk| stats.feed(chunk);
    try std.testing.expectEqual(@as(u64, 8), stats.lines());
    try std.testing.expectEqual(@as(u64, 5), stats.errorLines());
}

test "a line with several error words counts once" {
    try std.testing.expectEqual(@as(u64, 1), statsOf("error fail traceback exception\n").errorLines());
}

test "a last line with no line end counts as a line" {
    try std.testing.expectEqual(@as(u64, 2), statsOf("a\nb").lines());
    try std.testing.expectEqual(@as(u64, 1), statsOf("a\n").lines());
    try std.testing.expectEqual(@as(u64, 1), statsOf("\n").lines());
    try std.testing.expectEqual(@as(u64, 0), statsOf("").lines());
}

test "characters are UTF-8 code points, and a CRLF pair is two characters" {
    const stats = statsOf("\u{1F600}a\r\n");
    try std.testing.expectEqual(@as(u64, 7), stats.bytes);
    try std.testing.expectEqual(@as(u64, 4), stats.chars);
}

test "JSON shows as an array or an object between spaces" {
    try std.testing.expect(statsOf("  [1, 2]\n").looksJson());
    try std.testing.expect(statsOf(" \n {\"a\":1} \r\n").looksJson());
    try std.testing.expect(!statsOf("{").looksJson());
    try std.testing.expect(!statsOf("[1").looksJson());
    try std.testing.expect(!statsOf("[a] b").looksJson());
    try std.testing.expect(!statsOf("").looksJson());
}

test "the header of a saved output names its file" {
    const text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 0 }, .bytes = 45 * 1024, .lines = 340, .saved = .{ .file = 7 } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[exit 0, 340 lines, 45 KB, $FX_OUT/7.txt]", text);
}

test "the header of a failed program names its exit code" {
    const text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 2 }, .bytes = 1024, .lines = 12, .saved = .{ .file = 8 } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[exit 2, 12 lines, 1 KB, $FX_OUT/8.txt]", text);
}

test "the header of a cut file says what it keeps" {
    const text = try headerText(std.testing.allocator, .{
        .state = .{ .exit = 0 },
        .bytes = 16 * 1024 * 1024,
        .lines = 300_000,
        .saved = .{ .file_cut = .{ .number = 9, .kept_each_bytes = 8 * 1024 * 1024 } },
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[exit 0, 300000 lines, 16 MB, $FX_OUT/9.txt, the file keeps the first and last 8 MiB]", text);
}

test "the header of an output the folder had no room for says so" {
    const text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 0 }, .bytes = 45 * 1024, .lines = 340, .saved = .not_saved_full });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[exit 0, 340 lines, 45 KB, not saved: the results folder is full]", text);
}

test "the header of an output that failed to save gives the short reason" {
    const text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 0 }, .bytes = 45 * 1024, .lines = 340, .saved = .{ .not_saved_error = "disk is read-only" } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[exit 0, 340 lines, 45 KB, not saved: disk is read-only]", text);
}

test "the header words for a killed, stopped, and unknown program are the bash tool's" {
    const killed = try headerText(std.testing.allocator, .{ .state = .{ .signal = 9 }, .bytes = 10, .lines = 3, .saved = .{ .file = 3 } });
    defer std.testing.allocator.free(killed);
    try std.testing.expectEqualStrings("[killed by signal 9, 3 lines, 10 B, $FX_OUT/3.txt]", killed);
    const stopped = try headerText(std.testing.allocator, .{ .state = .stopped, .bytes = 5, .lines = 1, .saved = .not_saved_full });
    defer std.testing.allocator.free(stopped);
    try std.testing.expectEqualStrings("[stopped, 1 line, 5 B, not saved: the results folder is full]", stopped);
    const unknown = try headerText(std.testing.allocator, .{ .state = .unknown, .bytes = 0, .lines = 0, .saved = .{ .file = 4 } });
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings("[ended; exit status unknown, 0 lines, 0 B, $FX_OUT/4.txt]", unknown);
}

test "header sizes are bytes, KB, or MB with no decimals" {
    const bytes_text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 0 }, .bytes = 1023, .lines = 1, .saved = .{ .file = 1 } });
    defer std.testing.allocator.free(bytes_text);
    try std.testing.expectEqualStrings("[exit 0, 1 line, 1023 B, $FX_OUT/1.txt]", bytes_text);
    const kb_text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 0 }, .bytes = 1024 * 1023 + 1, .lines = 1, .saved = .{ .file = 1 } });
    defer std.testing.allocator.free(kb_text);
    try std.testing.expectEqualStrings("[exit 0, 1 line, 1023 KB, $FX_OUT/1.txt]", kb_text);
    const mb_text = try headerText(std.testing.allocator, .{ .state = .{ .exit = 0 }, .bytes = 1024 * 1024, .lines = 1, .saved = .{ .file = 1 } });
    defer std.testing.allocator.free(mb_text);
    try std.testing.expectEqualStrings("[exit 0, 1 line, 1 MB, $FX_OUT/1.txt]", mb_text);
}

test "the shape line names the file for JSON, counts error lines, and is empty otherwise" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeShape(&out.writer, statsOf("[1, 2]\n"), .{ .file = 7 });
    try std.testing.expectEqualStrings("json: use jq on $FX_OUT/7.txt\n", out.written());

    var errors: Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try writeShape(&errors.writer, statsOf("error one\nfail two\nno\n"), .{ .file = 7 });
    try std.testing.expectEqualStrings("2 lines match error|fail|traceback|exception\n", errors.written());

    var plain: Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    try writeShape(&plain.writer, statsOf("plain text\n"), .{ .file = 7 });
    try std.testing.expectEqualStrings("", plain.written());
}

test "a shape line for JSON from a running program names no file" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeShape(&out.writer, statsOf("{\"a\": 1}\n"), .running);
    try std.testing.expectEqualStrings("json: the output looks like JSON\n", out.written());
}

test "a stray continuation byte after a line end ends the tail cut, and does not hang it" {
    const output = "a\n\x80";
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 0, .preview_chars = 1 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 0), planned.preview.tail.len);
}

test "a byte cap of 1,000 shows a head of at most 250 bytes and whole lines in the rest" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNumberedLines(&text.writer, 1, max_test_lines, "\n");
    const output = text.written();
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 1_000 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 250), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 720), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 383), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(u64, 23_030), planned.preview.hidden_chars);
}

test "an output just over the byte cap shares no byte between head and tail" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNumberedLines(&text.writer, 1, 16, "\n");
    const last_line: [41]u8 = @splat('z');
    try text.writer.writeAll(&last_line);
    const output = text.written();
    try std.testing.expectEqual(@as(usize, 1_001), output.len);
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 1_000 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 250), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 701), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 50), planned.preview.hidden_chars);
    try std.testing.expect(planned.preview.head.len + planned.preview.tail.len <= output.len);
}

test "an output just over the character cap shares no byte between head and tail" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    const line: [99]u8 = @splat('x');
    for (0..120) |_| {
        try text.writer.writeAll(&line);
        try text.writer.writeAll("\n");
    }
    try text.writer.writeAll("z");
    const output = text.written();
    try std.testing.expectEqual(@as(usize, 12_001), output.len);
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 20_000 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 375), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 1_101), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 10_525), planned.preview.hidden_chars);
    try std.testing.expect(planned.preview.head.len + planned.preview.tail.len <= output.len);
}

test "a tail piece that starts mid-line shows only whole lines after its first line end" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNumberedLines(&text.writer, 1, 10, "\n");
    const output = text.written();
    const planned = plan("", output[30..], statsOf(output), .{ .inline_bytes = 599 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 0), planned.preview.head.len);
    try std.testing.expectEqual(@as(usize, 540), planned.preview.tail.len);
    try std.testing.expectEqualStrings("line 002 ", planned.preview.tail[0..9]);
    try std.testing.expectEqual(@as(u64, 1), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(u64, 60), planned.preview.hidden_chars);
}

test "a tail piece that starts mid-character shows no partial line and no broken character" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (0..10) |_| {
        for (0..49) |_| try text.writer.writeAll("é");
        try text.writer.writeAll("\n");
    }
    const output = text.written();
    try std.testing.expectEqual(@as(usize, 990), output.len);
    const planned = plan("", output[1..], statsOf(output), .{ .inline_bytes = 989 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 891), planned.preview.tail.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(planned.preview.tail));
    try std.testing.expectEqual(@as(u64, 1), planned.preview.hidden_lines);
    try std.testing.expectEqual(@as(u64, 50), planned.preview.hidden_chars);
}

test "a tail piece with no line end shows its last characters within the budget" {
    const output: [1_000]u8 = @splat('x');
    const planned = plan("", output[700..], statsOf(&output), .{ .inline_bytes = 999, .preview_chars = 100 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, 100), planned.preview.tail.len);
    try std.testing.expectEqual(@as(u64, 900), planned.preview.hidden_chars);
}

test "a short output over the character cap is written once, not twice" {
    const text = "one\ntwo\nthree\n";
    const planned = plan(text, text, statsOf(text), .{ .inline_chars = 5, .inline_bytes = 1_000 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqual(@as(usize, text.len), planned.preview.head.len + planned.preview.tail.len);
    const written = try previewText(std.testing.allocator, planned, .{ .file = 7 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(text, written);
}

test "a stray continuation byte after a head line end keeps the head within its byte budget" {
    const output = "a\n\x80\x80\x80zzzzzzzzzz";
    const planned = plan(output, output, statsOf(output), .{ .inline_bytes = 8, .head_lines = 1 });
    try std.testing.expect(std.meta.activeTag(planned) == .preview);
    try std.testing.expectEqualStrings("a", planned.preview.head);
    try std.testing.expect(planned.preview.head.len + planned.preview.tail.len <= 8);
}

const max_fuzz_bytes = 8_192;
const max_written_bytes = 16_384;

fn newlinesIn(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn expectCutsAtCharacters(input: []const u8, preview: Preview) !void {
    try std.testing.expect(std.mem.startsWith(u8, input, preview.head));
    try std.testing.expect(std.mem.endsWith(u8, input, preview.tail));
    if (preview.head.len > 0 and preview.head.len < input.len) try std.testing.expect(!isContinuation(input[preview.head.len]));
    if (preview.tail.len > 0) try std.testing.expect(!isContinuation(preview.tail[0]));
    if (std.unicode.utf8ValidateSlice(input)) {
        try std.testing.expect(std.unicode.utf8ValidateSlice(preview.head));
        try std.testing.expect(std.unicode.utf8ValidateSlice(preview.tail));
    }
}

fn fuzzBashResults(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_bytes]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];

    var whole: Stats = .{};
    whole.feed(input);
    var chunked: Stats = .{};
    var start: usize = 0;
    while (start < input.len) {
        const size: usize = smith.valueRangeAtMost(u32, 1, 64);
        const end = @min(input.len, start + size);
        chunked.feed(input[start..end]);
        start = end;
    }
    try expectSameStats(whole, chunked);

    var limits: Limits = .{
        .inline_bytes = smith.valueRangeAtMost(u32, 0, 400),
        .inline_chars = smith.valueRangeAtMost(u32, 0, 400),
        .preview_chars = smith.valueRangeAtMost(u32, 0, 200),
        .head_lines = smith.valueRangeAtMost(u32, 0, 8),
    };
    // A piece: the head is a prefix that ends at a boundary, and the tail is any suffix.
    const piece = input.len > 0 and smith.valueRangeAtMost(u32, 0, 1) == 1;
    const head_at: usize = @min(input.len, smith.valueRangeAtMost(u32, 0, max_fuzz_bytes));
    const tail_at: usize = @min(input.len, smith.valueRangeAtMost(u32, 0, max_fuzz_bytes));
    if (piece) limits.inline_bytes = @min(limits.inline_bytes, input.len - 1);
    const head = if (piece) input[0..boundaryAtOrBefore(input, head_at)] else input;
    const tail = if (piece) input[tail_at..] else input;

    const planned = plan(head, tail, whole, limits);
    var out_buffer: [max_written_bytes]u8 = undefined;
    var writer: Writer = .fixed(&out_buffer);
    try writePreview(&writer, planned, .{ .file = 7 });

    switch (planned) {
        .whole => |text| {
            try std.testing.expectEqualSlices(u8, input, text);
            try std.testing.expect(whole.bytes <= limits.inline_bytes);
            try std.testing.expect(whole.chars <= limits.inline_chars);
            try std.testing.expectEqualSlices(u8, input, writer.buffered());
        },
        .preview => |preview| {
            try expectCutsAtCharacters(input, preview);
            const shown_bytes = preview.head.len + preview.tail.len;
            const shown_chars = charCount(preview.head) + charCount(preview.tail);
            try std.testing.expect(shown_bytes <= limits.inline_bytes);
            try std.testing.expect(shown_bytes <= input.len);
            try std.testing.expect(shown_chars <= limits.preview_chars);
            try std.testing.expect(charCount(preview.head) <= limits.preview_chars / 4);
            try std.testing.expect(preview.head.len <= limits.inline_bytes / 4);
            try std.testing.expect(newlinesIn(preview.head) <= limits.head_lines);
            try std.testing.expectEqual(whole.chars - @as(u64, shown_chars), preview.hidden_chars);
            try std.testing.expect(preview.hidden_lines <= whole.lines());
            if (tail.len < input.len) {
                if (std.mem.findScalar(u8, tail, '\n')) |line_end| {
                    try std.testing.expect(preview.tail.len <= tail.len - (line_end + 1));
                }
            }
            try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), preview.head));
            try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), preview.tail));
        },
    }
}

test "the bash results keep their laws on fuzzed output, split however it arrives" {
    try std.testing.fuzz({}, fuzzBashResults, .{
        .corpus = &(@import("fuzz_corpus").bash_results.*),
    });
}

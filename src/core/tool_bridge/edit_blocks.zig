//! Reads the edit blocks a program sends to `edit PATH` on stdin, and writes
//! them back in the same format:
//!
//!     <<<<<<< SEARCH
//!     old lines
//!     =======
//!     new lines
//!     >>>>>>> REPLACE
//!
//! The module imports only `std` and does no I/O. Its edits point into the
//! input, so the input must outlive them.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// The most blocks one edit may hold.
pub const max_blocks: usize = 64;

/// The size of the buffer a failure message is written into, in tests and the fuzz target.
const max_message_bytes = 512;

const search_marker = "<<<<<<< SEARCH";
const divider_marker = "=======";
const replace_marker = ">>>>>>> REPLACE";
const shape_hint = "each block needs " ++ search_marker ++ ", " ++ divider_marker ++ ", and " ++ replace_marker ++ " lines.";

/// One block: `search` is found and replaced by `replace`.
pub const Edit = struct {
    /// Exact bytes to find, through the newline of their last line. Never empty.
    search: []const u8,
    /// Exact bytes to put in their place. Empty deletes `search`.
    replace: []const u8,
};

pub const Kind = enum {
    no_blocks,
    text_outside_block,
    nested_search,
    replace_before_divider,
    missing_divider,
    empty_search,
    missing_replace,
    invalid_utf8,
    too_many_blocks,
};

/// Why an edit is refused. `line` is 1-based and names the line to fix.
pub const Failure = struct {
    line: usize,
    kind: Kind,
};

pub const Result = union(enum) {
    /// Points into the input. The caller frees the list with `deinit`.
    edits: []const Edit,
    failure: Failure,

    pub fn deinit(self: Result, alloc: Allocator) void {
        switch (self) {
            .edits => |edits| alloc.free(edits),
            .failure => {},
        }
    }
};

/// Reads every block in `input`. On success the caller frees the result with
/// `Result.deinit`. The only allocation is that list.
pub fn decode(alloc: Allocator, input: []const u8) Allocator.Error!Result {
    // Checked first: the bridge sends this text as JSON strings, which must be UTF-8.
    if (firstInvalidUtf8Line(input)) |line| return .{ .failure = fail(line, .invalid_utf8) };

    var edits: std.ArrayList(Edit) = .empty;
    errdefer edits.deinit(alloc);
    if (try readBlocks(alloc, input, &edits)) |failure| {
        edits.deinit(alloc);
        return .{ .failure = failure };
    }
    if (edits.items.len == 0) {
        edits.deinit(alloc);
        return .{ .failure = fail(1, .no_blocks) };
    }
    return .{ .edits = try edits.toOwnedSlice(alloc) };
}

/// Writes `blocks` in the format `decode` reads. Each search must be non-empty
/// and end with a newline, and each replace must be empty or end with one, as
/// `decode` returns them.
pub fn encode(blocks: []const Edit, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (blocks) |block| {
        std.debug.assert(block.search.len > 0 and block.search[block.search.len - 1] == '\n');
        std.debug.assert(block.replace.len == 0 or block.replace[block.replace.len - 1] == '\n');
        try writer.writeAll(search_marker ++ "\n");
        try writer.writeAll(block.search);
        try writer.writeAll(divider_marker ++ "\n");
        try writer.writeAll(block.replace);
        try writer.writeAll(replace_marker ++ "\n");
    }
}

/// Writes the message for `failure`: its line, then what to fix.
pub fn writeFailure(writer: *std.Io.Writer, failure: Failure) std.Io.Writer.Error!void {
    try writer.print("line {d}: ", .{failure.line});
    switch (failure.kind) {
        .no_blocks => try writer.writeAll("the edit has no blocks; " ++ shape_hint),
        .text_outside_block => try writer.writeAll("text outside a block; only blank lines may come before, between, and after blocks; " ++ shape_hint),
        .nested_search => try writer.writeAll("a " ++ search_marker ++ " line starts inside a block; close that block with " ++ replace_marker ++ " first; " ++ shape_hint),
        .replace_before_divider => try writer.writeAll(replace_marker ++ " comes before the " ++ divider_marker ++ " line of its block; " ++ shape_hint),
        .missing_divider => try writer.writeAll("the block that starts on this line has no " ++ divider_marker ++ " line; " ++ shape_hint),
        .empty_search => try writer.writeAll("the block that starts on this line has empty search text; put the exact lines to replace between " ++ search_marker ++ " and " ++ divider_marker ++ "."),
        .missing_replace => try writer.writeAll("the " ++ divider_marker ++ " line has no " ++ replace_marker ++ " line after it; " ++ shape_hint),
        .invalid_utf8 => try writer.writeAll("the first byte that is not valid UTF-8 is on this line; send the edit as UTF-8 text."),
        .too_many_blocks => try writer.print("an edit takes at most {d} blocks; send the rest in a separate edit.", .{max_blocks}),
    }
}

fn fail(line: usize, kind: Kind) Failure {
    return .{ .line = line, .kind = kind };
}

/// Collects the blocks into `edits`. Returns the first refusal, or null.
fn readBlocks(alloc: Allocator, input: []const u8, edits: *std.ArrayList(Edit)) Allocator.Error!?Failure {
    var lines: LineIterator = .{ .input = input };
    var state: State = .outside;
    while (lines.next()) |line| {
        const text = line.text(input);
        const marker = markerOf(text);
        const step: Step = switch (state) {
            .outside => stepOutside(line, text, marker, edits.items.len),
            .searching => |span| stepSearching(input, line, marker, span),
            .replacing => |block| try stepReplacing(alloc, input, line, marker, block, edits),
        };
        switch (step) {
            .next => |next| state = next,
            .failed => |failure| return failure,
        }
    }
    return switch (state) {
        .outside => null,
        .searching => |span| fail(span.line, .missing_divider),
        .replacing => |block| fail(block.divider_line, .missing_replace),
    };
}

const State = union(enum) {
    /// Between blocks, where only blank lines may appear.
    outside,
    /// In a block's search text.
    searching: Span,
    /// In a block's replace text, after its divider line.
    replacing: Replacing,
};

/// A block's SEARCH line, and the byte where its search text starts.
const Span = struct {
    line: usize,
    start: usize,
};

const Replacing = struct {
    search: []const u8,
    divider_line: usize,
    replace_start: usize,
};

const Step = union(enum) {
    next: State,
    failed: Failure,
};

fn stepOutside(line: Line, text: []const u8, marker: Marker, edit_count: usize) Step {
    switch (marker) {
        .search => {
            if (edit_count == max_blocks) return .{ .failed = fail(line.number, .too_many_blocks) };
            return .{ .next = .{ .searching = .{ .line = line.number, .start = line.after } } };
        },
        .none => {
            if (isBlank(text)) return .{ .next = .outside };
            return .{ .failed = fail(line.number, .text_outside_block) };
        },
        .divider, .replace => return .{ .failed = fail(line.number, .text_outside_block) },
    }
}

fn stepSearching(input: []const u8, line: Line, marker: Marker, span: Span) Step {
    switch (marker) {
        .search => return .{ .failed = fail(line.number, .nested_search) },
        .replace => return .{ .failed = fail(line.number, .replace_before_divider) },
        .divider => {
            if (line.start == span.start) return .{ .failed = fail(span.line, .empty_search) };
            return .{ .next = .{ .replacing = .{
                .search = input[span.start..line.start],
                .divider_line = line.number,
                .replace_start = line.after,
            } } };
        },
        .none => return .{ .next = .{ .searching = span } },
    }
}

fn stepReplacing(
    alloc: Allocator,
    input: []const u8,
    line: Line,
    marker: Marker,
    block: Replacing,
    edits: *std.ArrayList(Edit),
) Allocator.Error!Step {
    switch (marker) {
        .search => return .{ .failed = fail(line.number, .nested_search) },
        .replace => {
            try edits.append(alloc, .{
                .search = block.search,
                .replace = input[block.replace_start..line.start],
            });
            return .{ .next = .outside };
        },
        // A divider inside the replace text is content.
        .divider, .none => return .{ .next = .{ .replacing = block } },
    }
}

const Marker = enum { none, search, divider, replace };

/// The marker a line is, if any. One trailing `\r` (CRLF input) is allowed.
fn markerOf(text: []const u8) Marker {
    const bare = if (std.mem.endsWith(u8, text, "\r")) text[0 .. text.len - 1] else text;
    if (std.mem.eql(u8, bare, search_marker)) return .search;
    if (std.mem.eql(u8, bare, divider_marker)) return .divider;
    if (std.mem.eql(u8, bare, replace_marker)) return .replace;
    return .none;
}

/// Blank means only spaces, tabs, and a `\r`.
fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r").len == 0;
}

const Line = struct {
    /// 1-based.
    number: usize,
    /// Byte offset of the line's first byte.
    start: usize,
    /// Byte offset just past the line's text. A newline, if any, sits here.
    text_end: usize,
    /// Byte offset of the next line.
    after: usize,

    fn text(self: Line, input: []const u8) []const u8 {
        return input[self.start..self.text_end];
    }
};

const LineIterator = struct {
    input: []const u8,
    pos: usize = 0,
    number: usize = 0,

    fn next(self: *LineIterator) ?Line {
        if (self.pos >= self.input.len) return null;
        const start = self.pos;
        const text_end = std.mem.findScalarPos(u8, self.input, start, '\n') orelse self.input.len;
        const after = @min(text_end + 1, self.input.len);
        self.pos = after;
        self.number += 1;
        return .{ .number = self.number, .start = start, .text_end = text_end, .after = after };
    }
};

/// The line of the first byte that does not start valid UTF-8, or null.
fn firstInvalidUtf8Line(input: []const u8) ?usize {
    var line: usize = 1;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '\n') line += 1;
        const width: usize = std.unicode.utf8ByteSequenceLength(input[index]) catch return line;
        if (index + width > input.len) return line;
        if (!std.unicode.utf8ValidateSlice(input[index..][0..width])) return line;
        index += width;
    }
    return null;
}

test "one block keeps the exact search and replace bytes" {
    try expectEdits(
        "<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE\n",
        &.{.{ .search = "old\n", .replace = "new\n" }},
    );
}

test "blank lines may come before, between, and after blocks" {
    try expectEdits(
        "\n<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE\n  \t\r\n\n<<<<<<< SEARCH\nc\n=======\n>>>>>>> REPLACE\n\n",
        &.{
            .{ .search = "a\n", .replace = "b\n" },
            .{ .search = "c\n", .replace = "" },
        },
    );
}

test "text outside a block is refused and names its line" {
    try expectFailure(
        "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE\nstray\n",
        6,
        .text_outside_block,
        "line 6: text outside a block; only blank lines may come before, between, and after blocks; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "a marker line must match exactly" {
    try expectFailure(
        "<<<<<<< SEARCH \na\n=======\nb\n>>>>>>> REPLACE\n",
        1,
        .text_outside_block,
        "line 1: text outside a block; only blank lines may come before, between, and after blocks; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "CRLF marker lines work, and their text keeps its CRLF bytes" {
    try expectEdits(
        "<<<<<<< SEARCH\r\nold\r\n=======\r\nnew\r\n>>>>>>> REPLACE\r\n",
        &.{.{ .search = "old\r\n", .replace = "new\r\n" }},
    );
}

test "the last marker line may lack its final newline" {
    try expectEdits(
        "<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE",
        &.{.{ .search = "old\n", .replace = "new\n" }},
    );
    try expectEdits(
        "<<<<<<< SEARCH\nold\n=======\n>>>>>>> REPLACE",
        &.{.{ .search = "old\n", .replace = "" }},
    );
}

test "a divider line inside the replace text is content" {
    try expectEdits(
        "<<<<<<< SEARCH\na\n=======\nx\n=======\ny\n>>>>>>> REPLACE\n",
        &.{.{ .search = "a\n", .replace = "x\n=======\ny\n" }},
    );
}

test "a SEARCH line inside a block is refused and names its line" {
    try expectFailure(
        "<<<<<<< SEARCH\na\n<<<<<<< SEARCH\nb\n=======\nc\n>>>>>>> REPLACE\n",
        3,
        .nested_search,
        "line 3: a <<<<<<< SEARCH line starts inside a block; close that block with >>>>>>> REPLACE first; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
    try expectFailure(
        "<<<<<<< SEARCH\na\n=======\nb\n<<<<<<< SEARCH\n>>>>>>> REPLACE\n",
        5,
        .nested_search,
        "line 5: a <<<<<<< SEARCH line starts inside a block; close that block with >>>>>>> REPLACE first; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "a REPLACE line before the divider line is refused and names its line" {
    try expectFailure(
        "<<<<<<< SEARCH\na\n>>>>>>> REPLACE\n",
        3,
        .replace_before_divider,
        "line 3: >>>>>>> REPLACE comes before the ======= line of its block; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "a block with no divider line is refused at its SEARCH line" {
    try expectFailure(
        "\n<<<<<<< SEARCH\na\nb\n",
        2,
        .missing_divider,
        "line 2: the block that starts on this line has no ======= line; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "an empty search text is refused, and an empty replace text is allowed" {
    try expectFailure(
        "<<<<<<< SEARCH\n=======\nx\n>>>>>>> REPLACE\n",
        1,
        .empty_search,
        "line 1: the block that starts on this line has empty search text; put the exact lines to replace between <<<<<<< SEARCH and =======.",
    );
}

test "a block with no REPLACE line is refused at its divider line" {
    try expectFailure(
        "<<<<<<< SEARCH\na\n=======\nb\n",
        3,
        .missing_replace,
        "line 3: the ======= line has no >>>>>>> REPLACE line after it; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "invalid UTF-8 is refused at the line of its first bad byte" {
    try expectFailure(
        "<<<<<<< SEARCH\na\n=======\n\xff\n>>>>>>> REPLACE\n",
        4,
        .invalid_utf8,
        "line 4: the first byte that is not valid UTF-8 is on this line; send the edit as UTF-8 text.",
    );
    try expectFailure(
        "<<<<<<< SEARCH\n\xe2\x82",
        2,
        .invalid_utf8,
        "line 2: the first byte that is not valid UTF-8 is on this line; send the edit as UTF-8 text.",
    );
    try expectEdits(
        "<<<<<<< SEARCH\ncaf\u{e9}\n=======\ncafe\n>>>>>>> REPLACE\n",
        &.{.{ .search = "caf\u{e9}\n", .replace = "cafe\n" }},
    );
}

test "an edit takes 64 blocks, and a 65th is refused at its SEARCH line" {
    const one: Edit = .{ .search = "a\n", .replace = "b\n" };
    const full: [max_blocks]Edit = @splat(one);
    const too_many: [max_blocks + 1]Edit = @splat(one);

    var full_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer full_text.deinit();
    try encode(&full, &full_text.writer);
    try expectEdits(full_text.written(), &full);

    var too_many_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer too_many_text.deinit();
    try encode(&too_many, &too_many_text.writer);
    // Each block is five lines, so the 65th block's SEARCH line is line 321.
    try expectFailure(
        too_many_text.written(),
        321,
        .too_many_blocks,
        "line 321: an edit takes at most 64 blocks; send the rest in a separate edit.",
    );
}

test "an empty or blank input has no blocks" {
    try expectFailure(
        "",
        1,
        .no_blocks,
        "line 1: the edit has no blocks; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
    try expectFailure(
        "\n  \n",
        1,
        .no_blocks,
        "line 1: the edit has no blocks; each block needs <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.",
    );
}

test "encode writes the exact format" {
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try encode(&.{.{ .search = "old\n", .replace = "new\n" }}, &written.writer);
    try std.testing.expectEqualStrings(
        "<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE\n",
        written.written(),
    );
}

test "decoding what encode wrote gives the same blocks" {
    const blocks = [_]Edit{
        .{ .search = "a\r\nb\r\n", .replace = "x\n=======\ny\n" },
        .{ .search = "<<<<<<< SEARCH x\n", .replace = "" },
        .{ .search = "last\n", .replace = "new\n" },
    };
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try encode(&blocks, &written.writer);
    try expectEdits(written.written(), &blocks);
}

fn expectSameEdits(want: []const Edit, got: []const Edit) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |expected, actual| {
        try std.testing.expectEqualStrings(expected.search, actual.search);
        try std.testing.expectEqualStrings(expected.replace, actual.replace);
    }
}

fn expectInside(input: []const u8, slice: []const u8) !void {
    const start = @intFromPtr(input.ptr);
    const at = @intFromPtr(slice.ptr);
    try std.testing.expect(at >= start and at + slice.len <= start + input.len);
}

fn expectEdits(input: []const u8, want: []const Edit) !void {
    const result = try decode(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);
    const edits = switch (result) {
        .edits => |edits| edits,
        .failure => return error.TestExpectedEdits,
    };
    try expectSameEdits(want, edits);
    for (edits) |edit| {
        try expectInside(input, edit.search);
        try expectInside(input, edit.replace);
    }
}

fn expectFailure(input: []const u8, want_line: usize, want_kind: Kind, want_message: []const u8) !void {
    const result = try decode(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);
    const failure = switch (result) {
        .edits => return error.TestExpectedFailure,
        .failure => |failure| failure,
    };
    try std.testing.expectEqual(want_line, failure.line);
    try std.testing.expectEqual(want_kind, failure.kind);
    var buffer: [max_message_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeFailure(&writer, failure);
    try std.testing.expectEqualStrings(want_message, writer.buffered());
}

const max_fuzz_edit_bytes = 4096;

fn fuzzEditBlocks(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var buffer: [max_fuzz_edit_bytes]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    const result = try decode(alloc, input);
    defer result.deinit(alloc);
    switch (result) {
        .failure => |failure| {
            var message: [max_message_bytes]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&message);
            try writeFailure(&writer, failure);
            try std.testing.expect(failure.line >= 1);
        },
        .edits => |edits| try expectRoundTrip(alloc, input, edits),
    }
}

fn expectRoundTrip(alloc: Allocator, input: []const u8, edits: []const Edit) !void {
    for (edits) |edit| {
        try std.testing.expect(edit.search.len > 0);
        try expectInside(input, edit.search);
        try expectInside(input, edit.replace);
    }
    var written: std.Io.Writer.Allocating = .init(alloc);
    defer written.deinit();
    try encode(edits, &written.writer);
    const again = try decode(alloc, written.written());
    defer again.deinit(alloc);
    switch (again) {
        .failure => return error.TestRoundTripRefused,
        .edits => |round| try expectSameEdits(edits, round),
    }
}

test "edit blocks are refused or decode, and decode back the same, on fuzzed text" {
    try std.testing.fuzz({}, fuzzEditBlocks, .{
        .corpus = &(@import("fuzz_corpus").edit_blocks.*),
    });
}

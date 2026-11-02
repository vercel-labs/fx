//! A reasoning trace as prose. Fenced code folds into an elision marker, as
//! proto shows a thinking trace, so a person reads the plan without the code
//! the model drafted alongside it. Only the footer's live preview folds the
//! trace this way; the transcript itself carries no thinking.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Largest folded trace the fixed-buffer preview path retains.
pub const preview_capacity: usize = 8192;

const Fence = struct { ch: u8, len: usize };

/// Enough of a line to recognize a fence, even when its prefix no longer
/// fits in the live reasoning tail.
const FenceLine = struct {
    stage: enum { indent, run, suffix, other } = .indent,
    indent: u3 = 0,
    ch: u8 = 0,
    len: usize = 0,
    suffix_whitespace: bool = true,
    suffix_backtick: bool = false,

    fn started(self: FenceLine) bool {
        return self.stage != .indent or self.indent != 0;
    }

    fn append(self: *FenceLine, bytes: []const u8) void {
        for (bytes) |byte| {
            switch (self.stage) {
                .indent => {
                    if (byte == ' ') {
                        self.indent += 1;
                        if (self.indent > 3) self.stage = .other;
                    } else if (byte == '`' or byte == '~') {
                        self.ch = byte;
                        self.len = 1;
                        self.stage = .run;
                    } else {
                        self.stage = .other;
                    }
                    continue;
                },
                .run => if (byte == self.ch) {
                    self.len +|= 1;
                    continue;
                } else {
                    self.stage = .suffix;
                },
                .suffix => {},
                .other => continue,
            }
            if (byte != ' ' and byte != '\t' and byte != '\r') self.suffix_whitespace = false;
            if (byte == '`') self.suffix_backtick = true;
        }
    }

    fn opening(self: FenceLine) ?Fence {
        if (self.stage == .other or self.len < 3) return null;
        if (self.ch == '`' and self.suffix_backtick) return null;
        return .{ .ch = self.ch, .len = self.len };
    }

    fn closes(self: FenceLine, fence: Fence) bool {
        return self.stage != .other and self.ch == fence.ch and
            self.len >= fence.len and self.suffix_whitespace;
    }
};

/// Markdown state at the start of a retained trace. Advancing over discarded
/// bytes preserves both complete fences and a partially discarded fence line,
/// without retaining the discarded text or allocating.
pub const ProseState = struct {
    fence: ?Fence = null,
    hidden: usize = 0,
    line: FenceLine = .{},

    pub fn advance(self: *ProseState, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            self.line.append(line);
            if (lines.peek() != null) _ = self.finishLine();
        }
    }

    const LineResult = union(enum) { prose, hidden, elision: usize };

    fn finishLine(self: *ProseState) LineResult {
        defer self.line = .{};
        if (self.fence) |fence| {
            if (self.line.closes(fence)) {
                const hidden = self.hidden;
                self.fence = null;
                self.hidden = 0;
                return .{ .elision = hidden };
            }
            self.hidden +|= 1;
            return .hidden;
        }
        if (self.line.opening()) |fence| {
            self.fence = fence;
            self.hidden = 0;
            return .hidden;
        }
        return .prose;
    }
};

/// One or two fence characters on the last line: a fence still arriving.
fn partialFence(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed.len > 2) return false;
    for (trimmed) |byte| if (byte != '`' and byte != '~') return false;
    return true;
}

/// Writes the kept lines, with the blank rows between them, and the markers
/// that stand in for folded code.
const ProseWriter = struct {
    writer: *std.Io.Writer,
    wrote_any: bool = false,
    pending_blanks: usize = 0,

    fn line(self: *ProseWriter, text: []const u8) !void {
        if (self.wrote_any) {
            try self.writer.writeByte('\n');
            try self.writer.splatByteAll('\n', self.pending_blanks);
        }
        self.pending_blanks = 0;
        self.wrote_any = true;
        try self.writer.writeAll(text);
    }

    /// The code-fold marker, at the end of the current line.
    fn elision(self: *ProseWriter, hidden: usize) !void {
        if (self.wrote_any) try self.writer.writeByte(' ');
        self.wrote_any = true;
        try self.writer.print("... ({d} line{s} of code)", .{ hidden, if (hidden == 1) "" else "s" });
    }
};

fn writeProse(writer: *std.Io.Writer, text: []const u8, initial_state: ProseState) !void {
    var out: ProseWriter = .{ .writer = writer };
    var state = initial_state;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const last = lines.peek() == null;
        const continues_dropped_line = state.line.started();
        // splitScalar's terminal empty field is not another source line.
        if (last and raw.len == 0 and !continues_dropped_line) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        state.line.append(line);
        switch (state.finishLine()) {
            .hidden => continue,
            .elision => |hidden| {
                try out.elision(hidden);
                continue;
            },
            .prose => {},
        }
        if (last and !continues_dropped_line and partialFence(line)) continue;
        if (std.mem.trim(u8, line, " \t").len == 0) {
            out.pending_blanks += 1;
            continue;
        }
        try out.line(line);
    }
    if (state.fence != null) try out.elision(state.hidden);
}

/// The trace as prose, owned by the caller. Returns a copy when no fence is
/// present so the result always owns its bytes. The allocating reference the
/// fixed-buffer path below is checked against.
fn proseOnly(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeProse(&out.writer, text, .{});
    return out.toOwnedSlice();
}

/// The trace as prose in a caller-provided buffer, starting in `initial_state`:
/// the fence state of whatever came before `text`. A trace larger than the
/// buffer keeps its leading complete codepoints and ends there.
pub fn proseOnlyInto(buf: []u8, text: []const u8, initial_state: ProseState) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    writeProse(&writer, text, initial_state) catch {};
    var written = writer.buffered();
    while (written.len > 0 and !std.unicode.utf8ValidateSlice(written)) {
        written = written[0 .. written.len - 1];
    }
    return written;
}

test "fenced code folds into an elision marker on the line before it" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Plan the edit.\n\n```zig\nconst a = 1;\nconst b = 2;\n```\n\nThen check it.");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings(
        "Plan the edit. ... (2 lines of code)\n\n\nThen check it.",
        folded,
    );
}

test "a trace that is only code keeps its marker as the first line" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "~~~\ncode\n~~~");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("... (1 line of code)", folded);
}

test "closing fences allow at most three leading spaces" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "```", "~~~" }) |fence| {
        const text = try alloc.print("Plan.\n{s}\n    {s}\nx\n{s}\nAfter.", .{ fence, fence, fence });
        defer alloc.free(text);
        const folded = try proseOnly(alloc, text);
        defer alloc.free(folded);
        try std.testing.expectEqualStrings("Plan. ... (2 lines of code)\nAfter.", folded);

        const indented_close = try alloc.print("{s}\ncode\n   {s}\nAfter.", .{ fence, fence });
        defer alloc.free(indented_close);
        const closed = try proseOnly(alloc, indented_close);
        defer alloc.free(closed);
        try std.testing.expectEqualStrings("... (1 line of code)\nAfter.", closed);
    }
}

test "unfinished fences count code lines without a phantom terminal blank" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "```\ncode\n", .expected = "... (1 line of code)" },
        .{ .source = "```\n", .expected = "... (0 lines of code)" },
        .{ .source = "~~~\ncode\r\n", .expected = "... (1 line of code)" },
        .{ .source = "```\ncode\n\n", .expected = "... (2 lines of code)" },
        .{ .source = "```\n\ncode\n", .expected = "... (2 lines of code)" },
    };
    for (cases) |case| {
        const folded = try proseOnly(std.testing.allocator, case.source);
        defer std.testing.allocator.free(folded);
        try std.testing.expectEqualStrings(case.expected, folded);
    }
}

test "an unfinished fence still folds and a partial fence is dropped" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Thinking.\n```\ncode\n``");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("Thinking. ... (2 lines of code)", folded);
}

test "a partial fence arriving outside code is dropped" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Thinking.\n``");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("Thinking.", folded);
}

test "inline backticks and indented fences are not code blocks" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Use `zig build` here.\n    ``` not a fence\nplain");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("Use `zig build` here.\n    ``` not a fence\nplain", folded);
}

test "discarded prefixes retain fence state across partial lines" {
    const sources = [_][]const u8{
        "````zig\nline\n   ```\n    ````\nmore\n   ````\nAfter.",
        "~~~~info\nline\n   ~~~\n    ~~~~\nmore\n   ~~~~\nAfter.",
    };
    for (sources) |source| {
        const end = std.mem.find(u8, source, "\nAfter.").?;
        for (0..end) |cut| {
            var state: ProseState = .{};
            // Byte-sized advances exercise split fence runs as well as lines.
            for (source[0..cut]) |byte| state.advance(&.{byte});
            var buf: [128]u8 = undefined;
            const folded = proseOnlyInto(&buf, source[cut..], state);
            try std.testing.expectEqualStrings("... (4 lines of code)\nAfter.", folded);
        }
    }
}

test "folding leaves nothing for whitespace and an unclosed fence opener" {
    for ([_][]const u8{ "", " \t\r\n \n", "\n  ``", "\n ~" }) |text| {
        const folded = try proseOnly(std.testing.allocator, text);
        defer std.testing.allocator.free(folded);
        try std.testing.expectEqualStrings("", folded);
    }
}

test "the fixed-buffer path matches the allocating path and stays valid UTF-8" {
    const alloc = std.testing.allocator;
    const source = "Read the note.\n```\nline\nline\n```\n界海語";
    const folded = try proseOnly(alloc, source);
    defer alloc.free(folded);
    var buf: [128]u8 = undefined;
    const fixed = proseOnlyInto(&buf, source, .{});
    try std.testing.expectEqualStrings(folded, fixed);

    var small: [24]u8 = undefined;
    const clipped = proseOnlyInto(&small, "界海語界海語界海語界海語界海語", .{});
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
}

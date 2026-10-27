//! Structural summary of a large code file read without a range (D162):
//! declarations stay, bodies of four or more lines fold, and block comments
//! of six or more lines keep only their first and last lines. A folded brace
//! body collapses onto one numbered row, `12-40\tfn run() { … }`. The footer
//! names the folded ranges so the model reads exactly those.
//!
//! Proto folds with a parser; this works from indentation, which brace and
//! indentation languages share, so it needs no grammar per language.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const min_body_lines: usize = 4;
pub const min_comment_lines: usize = 6;
const max_footer_ranges: usize = 24;

const code_extensions = [_][]const u8{
    ".zig",  ".ts",  ".tsx",   ".js",     ".jsx",  ".mjs",   ".cjs", ".py",  ".rs",  ".go",
    ".java", ".kt",  ".kts",   ".swift",  ".c",    ".h",     ".cc",  ".cpp", ".hpp", ".cs",
    ".rb",   ".php", ".scala", ".lua",    ".dart", ".m",     ".mm",  ".ex",  ".exs", ".sh",
    ".bash", ".zsh", ".vue",   ".svelte", ".sql",  ".proto", ".fs",  ".ml",  ".hs",  ".jl",
};

const container_words = [_][]const u8{
    "struct", "class ", "impl ", "impl<", "interface ", "enum", "union", "namespace ", "module ", "mod ", "trait ", "object ", "extension ", "protocol ", "opaque",
};

pub fn isCodePath(path: []const u8) bool {
    const ext = std.Io.Dir.path.extension(path);
    for (code_extensions) |candidate| if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    return false;
}

pub const Unit = union(enum) {
    line: usize,
    folded: struct { start: usize, end: usize },
    /// `head … tail` on one row for lines start through end.
    merged: struct { start: usize, end: usize },
};

pub const Summary = struct {
    text: []u8,
    shown_lines: usize,
    total_lines: usize,

    pub fn deinit(self: Summary, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

/// Null when folding would hide nothing. `max_rows` bounds the rows shown.
pub fn summarize(alloc: Allocator, content: []const u8, max_rows: usize) !?Summary {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    const all = lines.items;
    if (all.len == 0) return null;

    const indents = try arena.alloc(?usize, all.len);
    for (all, 0..) |line, i| indents[i] = indentOf(line);

    var units: std.ArrayList(Unit) = .empty;
    try fold(arena, all, indents, 0, all.len, &units);

    var folded_any = false;
    for (units.items) |unit| if (unit != .line) {
        folded_any = true;
        break;
    };
    if (!folded_any) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var ranges: std.ArrayList([2]usize) = .empty;
    var shown: usize = 0;
    var rows: usize = 0;
    var cut_at: ?usize = null;
    for (units.items) |unit| {
        if (rows == max_rows) {
            cut_at = switch (unit) {
                .line => |n| n,
                .folded => |f| f.start,
                .merged => |m| m.start,
            };
            break;
        }
        rows += 1;
        switch (unit) {
            .line => |n| {
                shown += 1;
                try w.print("{d}\t{s}\n", .{ n + 1, all[n] });
            },
            .folded => |f| {
                try ranges.append(arena, .{ f.start + 1, f.end + 1 });
                const pad = indentText(all[f.start]);
                try w.print("{d}-{d}\t{s}…\n", .{ f.start + 1, f.end + 1, pad });
            },
            .merged => |m| {
                shown += 2;
                try ranges.append(arena, .{ m.start + 2, m.end });
                try w.print("{d}-{d}\t{s} … {s}\n", .{ m.start + 1, m.end + 1, std.mem.trimEnd(u8, all[m.start], " \t"), std.mem.trim(u8, all[m.end], " \t") });
            },
        }
    }
    try w.print("... [structural summary: {d} of {d} lines shown; folded ", .{ shown, all.len });
    for (ranges.items, 0..) |range, i| {
        if (i == max_footer_ranges) {
            try w.print(", +{d} more", .{ranges.items.len - i});
            break;
        }
        try w.print("{s}{d}-{d}", .{ if (i == 0) "" else ", ", range[0], range[1] });
    }
    if (cut_at) |line| try w.print("; summary stops at line {d}, read on with path:{d}-", .{ line + 1, line + 1 });
    try w.writeAll(". Read only the ranges you need with path:N-M; never guess folded lines.]\n");
    return .{ .text = try out.toOwnedSlice(), .shown_lines = shown, .total_lines = all.len };
}

fn fold(arena: Allocator, lines: []const []const u8, indents: []const ?usize, start: usize, end: usize, units: *std.ArrayList(Unit)) !void {
    var i = start;
    while (i < end) {
        const indent = indents[i] orelse {
            try units.append(arena, .{ .line = i });
            i += 1;
            continue;
        };
        if (commentRun(lines, indents, i, end)) |last| {
            if (last + 1 - i >= min_comment_lines) {
                try units.append(arena, .{ .line = i });
                try units.append(arena, .{ .folded = .{ .start = i + 1, .end = last - 1 } });
                try units.append(arena, .{ .line = last });
                i = last + 1;
                continue;
            }
        }
        const body_end = blockEnd(indents, i, end, indent);
        if (body_end == i) {
            try units.append(arena, .{ .line = i });
            i += 1;
            continue;
        }
        if (isContainer(lines[i])) {
            try units.append(arena, .{ .line = i });
            try fold(arena, lines, indents, i + 1, body_end + 1, units);
        } else if (body_end - i >= min_body_lines) {
            const closer = body_end + 1;
            if (closer < end and indents[closer] == indent and isCloser(lines[closer]) and opensBrace(lines[i])) {
                try units.append(arena, .{ .merged = .{ .start = i, .end = closer } });
                i = closer + 1;
                continue;
            }
            try units.append(arena, .{ .line = i });
            try units.append(arena, .{ .folded = .{ .start = i + 1, .end = body_end } });
        } else {
            var j = i;
            while (j <= body_end) : (j += 1) try units.append(arena, .{ .line = j });
        }
        i = body_end + 1;
    }
}

/// The last line indented deeper than `indent` after `header`, skipping
/// blank lines inside; `header` itself when none is.
fn blockEnd(indents: []const ?usize, header: usize, end: usize, indent: usize) usize {
    var last = header;
    var j = header + 1;
    while (j < end) : (j += 1) {
        const value = indents[j] orelse continue;
        if (value <= indent) break;
        last = j;
    }
    return last;
}

/// Consecutive comment lines at one indentation starting at `first`.
fn commentRun(lines: []const []const u8, indents: []const ?usize, first: usize, end: usize) ?usize {
    if (!isComment(lines[first])) return null;
    var last = first;
    var j = first + 1;
    while (j < end and indents[j] != null and indents[j].? == indents[first].? and isComment(lines[j])) : (j += 1) last = j;
    return last;
}

fn isComment(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#") or
        std.mem.startsWith(u8, t, "/*") or std.mem.startsWith(u8, t, "*") or std.mem.startsWith(u8, t, "--");
}

fn isContainer(line: []const u8) bool {
    if (isComment(line)) return false;
    for (container_words) |word| {
        var search: usize = 0;
        while (std.mem.findPos(u8, line, search, word)) |at| : (search = at + 1) {
            if (at == 0 or !isIdentByte(line[at - 1])) return true;
        }
    }
    return false;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@';
}

fn opensBrace(line: []const u8) bool {
    const t = std.mem.trimEnd(u8, line, " \t");
    return t.len > 0 and (t[t.len - 1] == '{' or t[t.len - 1] == '(' or t[t.len - 1] == '[');
}

fn isCloser(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len > 0 and (t[0] == '}' or t[0] == ')' or t[0] == ']') and t.len <= 4;
}

fn indentOf(line: []const u8) ?usize {
    var width: usize = 0;
    for (line) |c| switch (c) {
        ' ' => width += 1,
        '\t' => width += 4,
        else => return width,
    };
    return null;
}

fn indentText(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return line[0..n];
}

test "brace bodies merge onto one row and containers keep their members" {
    const alloc = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\
        \\pub const Box = struct {
        \\    size: usize,
        \\
        \\    pub fn grow(self: *Box) void {
        \\        self.size += 1;
        \\        self.size += 1;
        \\        self.size += 1;
        \\        self.size += 1;
        \\    }
        \\};
        \\
        \\fn small() void {
        \\    return;
        \\}
        \\
    ;
    const summary = (try summarize(alloc, source, 400)).?;
    defer summary.deinit(alloc);
    try std.testing.expectEqualStrings(
        "1\tconst std = @import(\"std\");\n" ++
            "2\t\n" ++
            "3\tpub const Box = struct {\n" ++
            "4\t    size: usize,\n" ++
            "5\t\n" ++
            "6-11\t    pub fn grow(self: *Box) void { … }\n" ++
            "12\t};\n" ++
            "13\t\n" ++
            "14\tfn small() void {\n" ++
            "15\t    return;\n" ++
            "16\t}\n" ++
            "... [structural summary: 12 of 16 lines shown; folded 7-10. Read only the ranges you need with path:N-M; never guess folded lines.]\n",
        summary.text,
    );
}

test "indentation bodies and long comments fold" {
    const alloc = std.testing.allocator;
    const source =
        \\# one
        \\# two
        \\# three
        \\# four
        \\# five
        \\# six
        \\class Shape:
        \\    def area(self):
        \\        a = 1
        \\        b = 2
        \\        c = 3
        \\        return a + b + c
        \\
    ;
    const summary = (try summarize(alloc, source, 400)).?;
    defer summary.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, summary.text, "2-5\t…") != null);
    try std.testing.expect(std.mem.find(u8, summary.text, "8\t    def area(self):\n9-12\t        …") != null);
    try std.testing.expect((try summarize(alloc, "a\nb\n", 400)) == null);
}

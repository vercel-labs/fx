//! The shape of a Python run at a glance, as proto draws it: the code a
//! shell command hands to Python (a heredoc or `-c`), outlined one row per
//! statement, nested by its blocks. `x = f(y)` reads `x ← f(y)`. It reads
//! lines and indentation only, so it never fails: code it cannot follow
//! still outlines by its lines.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// The widest statement text, in bytes, before it ends in "…".
const max_statement_bytes = 72;

pub const Statement = struct {
    depth: usize,
    text: []const u8,
};

pub const Script = struct {
    /// The interpreter as a person names it: "python3.13", not its path.
    interpreter: []const u8,
    /// How the code reached it: "heredoc" or "-c".
    form: []const u8,
    code: []const u8,
};

/// The Python a shell command runs, or null when it runs no inline Python.
pub fn script(command: []const u8) ?Script {
    var lines = std.mem.splitScalar(u8, command, '\n');
    const first = lines.first();
    var tokens = std.mem.tokenizeAny(u8, first, " \t");
    while (tokens.next()) |token| {
        const name = std.Io.Dir.path.basename(token);
        if (!isPythonName(name)) continue;
        const after = first[tokens.index..];
        if (heredocDelimiter(after)) |delimiter| {
            const body_start = (std.mem.findScalar(u8, command, '\n') orelse return null) + 1;
            const body = command[body_start..];
            const end = closingLine(body, delimiter) orelse body.len;
            return .{ .interpreter = name, .form = "heredoc", .code = body[0..end] };
        }
        if (inlineCode(command[tokens.index..])) |code| {
            return .{ .interpreter = name, .form = "-c", .code = code };
        }
        return null;
    }
    return null;
}

fn isPythonName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "python")) return false;
    for (name["python".len..]) |byte| {
        if (!std.ascii.isDigit(byte) and byte != '.') return false;
    }
    return true;
}

/// "<<'PY'", "<< PY", `<<"EOF"` and "<<-PY" name the closing line.
fn heredocDelimiter(text: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, text, "<<") orelse return null;
    var rest = std.mem.trimStart(u8, text[at + 2 ..], "- \t");
    if (rest.len == 0) return null;
    if (rest[0] == '\'' or rest[0] == '"') {
        const quote = rest[0];
        const close = std.mem.findScalarPos(u8, rest, 1, quote) orelse return null;
        return rest[1..close];
    }
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
    rest = rest[0..end];
    return if (rest.len == 0) null else rest;
}

fn closingLine(body: []const u8, delimiter: []const u8) ?usize {
    var start: usize = 0;
    while (start <= body.len) {
        const end = std.mem.findScalarPos(u8, body, start, '\n') orelse body.len;
        if (std.mem.eql(u8, std.mem.trim(u8, body[start..end], " \t\r"), delimiter)) return start;
        if (end == body.len) break;
        start = end + 1;
    }
    return null;
}

/// The quoted argument after `-c`, unquoted. Shell escapes inside it are
/// left as written; the outline only needs its shape.
fn inlineCode(text: []const u8) ?[]const u8 {
    const flag = std.mem.find(u8, text, "-c ") orelse return null;
    const rest = std.mem.trimStart(u8, text[flag + 3 ..], " \t");
    if (rest.len < 2 or (rest[0] != '\'' and rest[0] != '"')) return null;
    const quote = rest[0];
    var index: usize = 1;
    while (index < rest.len) : (index += 1) {
        if (rest[index] == '\\' and quote == '"') {
            index += 1;
            continue;
        }
        if (rest[index] == quote) return rest[1..index];
    }
    return rest[1..];
}

/// One row per statement, in order. A statement over several lines reads as
/// one row, and a `-c` one-liner's `;` separates statements as Python does.
/// Allocated in `arena`.
pub fn outline(arena: Allocator, code: []const u8) ![]Statement {
    var statements: std.ArrayList(Statement) = .empty;
    var indents: std.ArrayList(usize) = .empty;
    try indents.append(arena, 0);
    var open: Open = .{};
    var logical: std.ArrayList(u8) = .empty;
    var logical_depth: usize = 0;
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (open.isOpen()) {
            try logical.append(arena, ' ');
            try logical.appendSlice(arena, std.mem.trim(u8, line, " \t"));
            open.scan(line);
            if (!open.isOpen()) try emit(arena, &statements, logical_depth, logical.items);
            continue;
        }
        const body = std.mem.trimStart(u8, line, " \t");
        if (body.len == 0 or body[0] == '#') continue;
        const indent = line.len - body.len;
        while (indents.items.len > 1 and indent < indents.items[indents.items.len - 1]) _ = indents.pop();
        if (indent > indents.items[indents.items.len - 1]) try indents.append(arena, indent);
        open.scan(line);
        if (open.isOpen()) {
            logical = .empty;
            try logical.appendSlice(arena, body);
            logical_depth = indents.items.len - 1;
            continue;
        }
        try emit(arena, &statements, indents.items.len - 1, body);
    }
    if (open.isOpen()) try emit(arena, &statements, logical_depth, logical.items);
    return statements.items;
}

fn emit(arena: Allocator, statements: *std.ArrayList(Statement), depth: usize, text: []const u8) !void {
    var parts = std.mem.splitScalar(u8, stripComment(text), ';');
    while (parts.next()) |part| {
        const statement = std.mem.trim(u8, part, " \t\\");
        if (statement.len == 0) continue;
        try statements.append(arena, .{ .depth = depth, .text = try describe(arena, statement) });
    }
}

/// What is still open at the end of a line: brackets, a triple-quoted
/// string, or a backslash continuation.
const Open = struct {
    brackets: usize = 0,
    triple: ?u8 = null,
    backslash: bool = false,

    fn isOpen(self: Open) bool {
        return self.brackets > 0 or self.triple != null or self.backslash;
    }

    fn scan(self: *Open, line: []const u8) void {
        var index: usize = 0;
        var string: ?u8 = null;
        while (index < line.len) : (index += 1) {
            const byte = line[index];
            if (self.triple) |quote| {
                if (std.mem.startsWith(u8, line[index..], &.{ quote, quote, quote })) {
                    self.triple = null;
                    index += 2;
                }
                continue;
            }
            if (string) |quote| {
                if (byte == '\\') index += 1 else if (byte == quote) string = null;
                continue;
            }
            switch (byte) {
                '#' => break,
                '\'', '"' => if (std.mem.startsWith(u8, line[index..], &.{ byte, byte, byte })) {
                    self.triple = byte;
                    index += 2;
                } else {
                    string = byte;
                },
                '(', '[', '{' => self.brackets += 1,
                ')', ']', '}' => self.brackets -|= 1,
                else => {},
            }
        }
        self.backslash = self.triple == null and std.mem.endsWith(u8, line, "\\");
    }
};

/// The statement before a `#` comment that sits outside any string.
fn stripComment(text: []const u8) []const u8 {
    var string: ?u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (string) |quote| {
            if (byte == '\\') index += 1 else if (byte == quote) string = null;
            continue;
        }
        if (byte == '\'' or byte == '"') string = byte;
        if (byte == '#') return std.mem.trimEnd(u8, text[0..index], " \t");
    }
    return text;
}

/// A statement as its row reads: a block's header without its colon, an
/// assignment as `name ← value`, anything else as written.
fn describe(arena: Allocator, statement: []const u8) ![]const u8 {
    var text = statement;
    if (blockHeader(text)) text = std.mem.trimEnd(u8, text[0 .. text.len - 1], " ");
    if (assignmentSplit(text)) |eq| {
        const target = std.mem.trim(u8, text[0..eq], " ");
        const value = std.mem.trim(u8, text[eq + 1 ..], " ");
        return clip(arena, try arena.print("{s} ← {s}", .{ target, value }));
    }
    return clip(arena, text);
}

fn blockHeader(text: []const u8) bool {
    if (!std.mem.endsWith(u8, text, ":")) return false;
    const keywords = [_][]const u8{ "def ", "class ", "for ", "async ", "if ", "elif ", "else", "while ", "with ", "try", "except", "finally", "match ", "case " };
    for (keywords) |keyword| {
        if (std.mem.startsWith(u8, text, keyword)) return true;
    }
    return false;
}

/// The `=` of a plain assignment, outside brackets and strings, or null for
/// a comparison, a keyword argument or an augmented assignment.
fn assignmentSplit(text: []const u8) ?usize {
    var depth: usize = 0;
    var in_string: ?u8 = null;
    for (text, 0..) |byte, index| {
        if (in_string) |quote| {
            if (byte == quote) in_string = null;
            continue;
        }
        switch (byte) {
            '\'', '"' => in_string = byte,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '=' => {
                if (depth != 0) continue;
                const before = if (index > 0) text[index - 1] else ' ';
                const after = if (index + 1 < text.len) text[index + 1] else ' ';
                if (after == '=' or std.mem.findScalar(u8, "=!<>+-*/%&|^@:", before) != null) return null;
                return index;
            },
            else => {},
        }
    }
    return null;
}

fn clip(arena: Allocator, text: []const u8) ![]const u8 {
    if (text.len <= max_statement_bytes) return text;
    var end: usize = max_statement_bytes;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return arena.print("{s}…", .{std.mem.trimEnd(u8, text[0..end], " ")});
}

test "a heredoc's Python is found and named by its interpreter" {
    const command = "/opt/homebrew/bin/python3.13 - <<'PY'\nimport os\nos.nope()\nPY\necho done";
    const found = script(command).?;
    try std.testing.expectEqualStrings("python3.13", found.interpreter);
    try std.testing.expectEqualStrings("heredoc", found.form);
    try std.testing.expectEqualStrings("import os\nos.nope()\n", found.code);
    const inline_run = script("python3 -c 'import sys; print(sys.version)'").?;
    try std.testing.expectEqualStrings("-c", inline_run.form);
    try std.testing.expectEqualStrings("import sys; print(sys.version)", inline_run.code);
    try std.testing.expect(script("ls -la") == null);
    try std.testing.expect(script("python3 tool.py") == null);
    try std.testing.expect(script("cat python3.txt") == null);
}

test "statements outline by their blocks, assignments read as arrows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code =
        \\from pathlib import Path
        \\import re, sqlite3
        \\root = Path.home() / '.proto/agent'
        \\for name in ['config.yml',
        \\             'models.yml']:
        \\    text = (root / name).read_text()  # read it
        \\    if re.search(r'cento', text):
        \\        print(name)
        \\con = sqlite3.connect(root / 'models.db')
        \\with con:
        \\    con.execute("DELETE FROM t WHERE a = 'x'")
        \\
    ;
    const statements = try outline(arena, code);
    const expected = [_]Statement{
        .{ .depth = 0, .text = "from pathlib import Path" },
        .{ .depth = 0, .text = "import re, sqlite3" },
        .{ .depth = 0, .text = "root ← Path.home() / '.proto/agent'" },
        .{ .depth = 0, .text = "for name in ['config.yml', 'models.yml']" },
        .{ .depth = 1, .text = "text ← (root / name).read_text()" },
        .{ .depth = 1, .text = "if re.search(r'cento', text)" },
        .{ .depth = 2, .text = "print(name)" },
        .{ .depth = 0, .text = "con ← sqlite3.connect(root / 'models.db')" },
        .{ .depth = 0, .text = "with con" },
        .{ .depth = 1, .text = "con.execute(\"DELETE FROM t WHERE a = 'x'\")" },
    };
    try std.testing.expectEqual(expected.len, statements.len);
    for (expected, statements) |want, got| {
        try std.testing.expectEqual(want.depth, got.depth);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
    const one_liner = try outline(arena, "import sys; print(sys.version)");
    try std.testing.expectEqual(@as(usize, 2), one_liner.len);
    try std.testing.expect(!std.mem.containsAtLeast(u8, (try outline(arena, "x == 1"))[0].text, 1, "←"));
}

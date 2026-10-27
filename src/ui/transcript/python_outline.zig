//! The shape of a Python run at a glance, as proto draws it: the code a
//! shell command hands to Python (a heredoc or `-c`) as a tree of its
//! statements under `Module · N nodes`. Blocks (def, class, if, for, while,
//! with, try) carry `·L<line>`, `x = f(y)` reads `x ← f(y)`, and a run of
//! imports folds into one row. It reads lines and indentation, not a full
//! grammar; code whose brackets, strings or indentation do not close is
//! reported as unparsed so the caller shows the source instead.
const std = @import("std");

const Allocator = std.mem.Allocator;

// Text caps, in bytes, as proto's outline uses them.
const cap_cond = 64;
const cap_value = 64;
const cap_expr = 80;
const cap_import = 56;
const cap_name = 40;
const cap_param = 32;

pub const Script = struct {
    /// The interpreter as a person names it: "python3.13", not its path.
    interpreter: []const u8,
    /// How the code reached it: "heredoc" or "-c".
    form: []const u8,
    code: []const u8,
    /// The shell around the code: the command up to the code (for a heredoc,
    /// its whole first line), and what follows it (the closing delimiter and
    /// any later commands).
    before: []const u8 = "",
    after: []const u8 = "",

    /// True when the command does more than hand this code to Python, so
    /// the shell around it is worth showing.
    pub fn mixed(self: Script) bool {
        const after = std.mem.trim(u8, self.after, " \t\r\n");
        const tail_is_delimiter = after.len == 0 or (std.mem.eql(u8, self.form, "heredoc") and
            std.mem.findScalar(u8, after, '\n') == null and std.mem.findAny(u8, after, " \t;&|") == null);
        if (!tail_is_delimiter) return true;
        var tokens = std.mem.tokenizeAny(u8, self.before, " \t");
        while (tokens.next()) |token| {
            if (isPythonName(std.Io.Dir.path.basename(token))) return false;
            if (std.mem.findScalar(u8, token, '=') == null) return true;
        }
        return false;
    }
};

/// The Python a shell command runs, or null when it runs no inline Python.
/// The first interpreter on any line counts, so `cd x && python3 - <<PY`
/// and a heredoc after other commands are found.
pub fn script(command: []const u8) ?Script {
    var line_start: usize = 0;
    while (line_start < command.len) {
        const line_end = std.mem.findScalarPos(u8, command, line_start, '\n') orelse command.len;
        if (scriptOnLine(command, line_start, line_end)) |found| return found;
        line_start = line_end + 1;
    }
    return null;
}

fn scriptOnLine(command: []const u8, line_start: usize, line_end: usize) ?Script {
    const line = command[line_start..line_end];
    var tokens = std.mem.tokenizeAny(u8, line, " \t;&|(");
    while (tokens.next()) |token| {
        const name = std.Io.Dir.path.basename(token);
        if (!isPythonName(name)) continue;
        const after_name = line[tokens.index..];
        if (heredocDelimiter(after_name)) |delimiter| {
            if (line_end >= command.len) return .{ .interpreter = name, .form = "heredoc", .code = "", .before = line };
            const body_start = line_end + 1;
            const body = command[body_start..];
            const end = closingLine(body, delimiter) orelse body.len;
            return .{
                .interpreter = name,
                .form = "heredoc",
                .code = body[0..end],
                .before = command[0..line_end],
                .after = body[end..],
            };
        }
        const offset = line_start + tokens.index;
        if (inlineCode(command[offset..])) |found| {
            const code_start = @intFromPtr(found.code.ptr) - @intFromPtr(command.ptr);
            return .{
                .interpreter = name,
                .form = "-c",
                .code = found.code,
                .before = command[0..code_start -| 1],
                .after = command[@min(command.len, code_start + found.code.len + found.closed)..],
            };
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

const InlineCode = struct { code: []const u8, closed: usize };

/// The quoted argument after `-c`, unquoted. Shell escapes inside it are
/// left as written; the outline only needs its shape.
fn inlineCode(text: []const u8) ?InlineCode {
    const line = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    const flag = std.mem.find(u8, line, "-c ") orelse return null;
    var start = flag + 3;
    while (start < text.len and (text[start] == ' ' or text[start] == '\t')) start += 1;
    if (text.len - start < 2 or (text[start] != '\'' and text[start] != '"')) return null;
    const quote = text[start];
    var index: usize = start + 1;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\\' and quote == '"') {
            index += 1;
            continue;
        }
        if (text[index] == quote) return .{ .code = text[start + 1 .. index], .closed = 1 };
    }
    return .{ .code = text[start + 1 ..], .closed = 0 };
}

// ---- outline ----------------------------------------------------------------

pub const Node = struct {
    kind: []const u8,
    name: []const u8 = "",
    detail: []const u8 = "",
    /// 1-based line in the code.
    line: u32,
    depth: usize,
};

pub const Outline = struct {
    /// Statements in source order, each with its nesting depth.
    nodes: []const Node,
    /// Every statement counted, before imports fold.
    total: usize,
};

const header_kinds = [_][]const u8{ "def", "async def", "class", "if", "elif", "else", "for", "async for", "while", "try", "except", "finally", "with", "async with", "match", "case" };
const aug_ops = [_][]const u8{ "**=", "//=", ">>=", "<<=", "+=", "-=", "*=", "/=", "%=", "@=", "&=", "|=", "^=" };

/// The outline of `code`, or null when it does not read as Python: an
/// unclosed bracket or string, or an indentation no block opened.
/// Allocated in `arena`.
pub fn parse(arena: Allocator, code: []const u8) !?Outline {
    var nodes: std.ArrayList(Node) = .empty;
    var indents: std.ArrayList(usize) = .empty;
    try indents.append(arena, 0);
    var open: Open = .{};
    var logical: std.ArrayList(u8) = .empty;
    var logical_line: u32 = 0;
    var logical_indent: usize = 0;
    var expect_block = false;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (open.isOpen()) {
            try logical.append(arena, ' ');
            try logical.appendSlice(arena, std.mem.trim(u8, line, " \t\\"));
            open.scan(line);
            if (!open.isOpen()) {
                if (!try placeStatement(arena, &nodes, &indents, &expect_block, logical_indent, logical_line, logical.items)) return null;
            }
            continue;
        }
        const body = std.mem.trimStart(u8, line, " \t");
        if (body.len == 0 or body[0] == '#') continue;
        open.scan(line);
        if (open.isOpen()) {
            logical = .empty;
            try logical.appendSlice(arena, std.mem.trimEnd(u8, body, "\\ "));
            logical_line = line_no;
            logical_indent = line.len - body.len;
            continue;
        }
        if (!try placeStatement(arena, &nodes, &indents, &expect_block, line.len - body.len, line_no, body)) return null;
    }
    if (open.isOpen() or expect_block or nodes.items.len == 0) return null;
    const total = nodes.items.len;
    return .{ .nodes = try foldImports(arena, nodes.items), .total = total };
}

/// Places one logical statement by its indentation. False when the
/// indentation does not follow the blocks around it.
fn placeStatement(
    arena: Allocator,
    nodes: *std.ArrayList(Node),
    indents: *std.ArrayList(usize),
    expect_block: *bool,
    indent: usize,
    line: u32,
    text: []const u8,
) !bool {
    const top = indents.items[indents.items.len - 1];
    if (expect_block.*) {
        if (indent <= top) return false;
        try indents.append(arena, indent);
        expect_block.* = false;
    } else if (indent > top) {
        return false;
    } else {
        while (indent < indents.items[indents.items.len - 1]) _ = indents.pop();
        if (indent != indents.items[indents.items.len - 1]) return false;
    }
    const depth = indents.items.len - 1;
    var parts = SplitStatements{ .text = stripComment(text) };
    while (parts.next()) |part| {
        const statement = std.mem.trim(u8, part, " \t");
        if (statement.len == 0) continue;
        if (blockHeaderEnd(statement)) |colon| {
            try nodes.append(arena, try describe(arena, statement[0..colon], line, depth, true));
            const inline_body = std.mem.trim(u8, statement[colon + 1 ..], " \t");
            if (inline_body.len == 0) {
                expect_block.* = true;
            } else {
                // `if x: y` keeps its body on the header's line.
                var inner = SplitStatements{ .text = inline_body };
                while (inner.next()) |piece| {
                    const trimmed = std.mem.trim(u8, piece, " \t");
                    if (trimmed.len > 0) try nodes.append(arena, try describe(arena, trimmed, line, depth + 1, false));
                }
            }
            return true;
        }
        try nodes.append(arena, try describe(arena, statement, line, depth, false));
    }
    return true;
}

/// Splits on top-level `;`, outside strings and brackets.
const SplitStatements = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *SplitStatements) ?[]const u8 {
        if (self.index > self.text.len) return null;
        const start = self.index;
        var scan: Scan = .{};
        while (self.index < self.text.len) : (self.index += 1) {
            if (scan.step(self.text, &self.index) and self.text[self.index] == ';') {
                defer self.index += 1;
                return self.text[start..self.index];
            }
        }
        self.index += 1;
        return self.text[start..];
    }
};

/// Steps over strings and brackets; true when the byte at `index` sits at
/// the top level outside any string.
const Scan = struct {
    depth: usize = 0,
    string: ?u8 = null,

    fn step(self: *Scan, text: []const u8, index: *usize) bool {
        const byte = text[index.*];
        if (self.string) |quote| {
            if (byte == '\\') index.* += 1 else if (byte == quote) self.string = null;
            return false;
        }
        switch (byte) {
            '\'', '"' => {
                self.string = byte;
                return false;
            },
            '(', '[', '{' => {
                self.depth += 1;
                return false;
            },
            ')', ']', '}' => {
                self.depth -|= 1;
                return false;
            },
            else => return self.depth == 0,
        }
    }
};

/// The top-level `:` ending a block header, or null for other statements.
fn blockHeaderEnd(statement: []const u8) ?usize {
    for (header_kinds) |kind| {
        if (!std.mem.startsWith(u8, statement, kind)) continue;
        const after = statement[kind.len..];
        if (after.len == 0 or after[0] == ' ' or after[0] == ':' or after[0] == '(') break;
    } else return null;
    var scan: Scan = .{};
    var index: usize = 0;
    while (index < statement.len) : (index += 1) {
        if (scan.step(statement, &index) and statement[index] == ':') {
            // A lambda's or slice's colon sits inside brackets; a dict too.
            if (index + 1 < statement.len and statement[index + 1] == '=') continue;
            return index;
        }
    }
    return null;
}

/// What is still open at the end of a line: brackets, a triple-quoted
/// string, or a backslash continuation.
const Open = struct {
    brackets: usize = 0,
    triple: ?u8 = null,
    backslash: bool = false,
    unclosed_string: bool = false,

    fn isOpen(self: Open) bool {
        return self.brackets > 0 or self.triple != null or self.backslash;
    }

    fn scan(self: *Open, line: []const u8) void {
        var index: usize = 0;
        var string: ?u8 = null;
        while (index < line.len) : (index += 1) {
            const byte = line[index];
            if (self.triple) |quote| {
                if (byte == '\\') {
                    index += 1;
                } else if (std.mem.startsWith(u8, line[index..], &.{ quote, quote, quote })) {
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
        // A one-quote string never spans lines; treat it as an open bracket
        // so the code reads as unparsed.
        if (string != null) self.brackets += 1;
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

/// A statement as an outline node, as proto names its parts.
fn describe(arena: Allocator, statement: []const u8, line: u32, depth: usize, header: bool) !Node {
    var node: Node = .{ .kind = "expr", .line = line, .depth = depth };
    if (header) for (header_kinds) |kind| {
        if (!std.mem.startsWith(u8, statement, kind)) continue;
        const rest_raw = statement[kind.len..];
        if (rest_raw.len > 0 and rest_raw[0] != ' ' and rest_raw[0] != '(') continue;
        const rest = std.mem.trim(u8, rest_raw, " ");
        node.kind = kind;
        if (std.mem.endsWith(u8, kind, "def")) {
            const paren = std.mem.findScalar(u8, rest, '(') orelse rest.len;
            const close = std.mem.findScalarLast(u8, rest, ')') orelse rest.len;
            const params = if (close > paren) try summarizeParams(arena, rest[paren + 1 .. close]) else "";
            node.name = try arena.print("{s}({s})", .{ std.mem.trim(u8, rest[0..paren], " "), params });
            if (std.mem.find(u8, rest, "->")) |arrow| node.detail = try arena.print("→ {s}", .{try cap(arena, rest[arrow + 2 ..], 40)});
        } else if (std.mem.eql(u8, kind, "class")) {
            const paren = std.mem.findScalar(u8, rest, '(') orelse rest.len;
            node.name = std.mem.trim(u8, rest[0..paren], " ");
            node.detail = try cap(arena, rest[paren..], 48);
        } else if (std.mem.endsWith(u8, kind, "for")) {
            if (topLevelWord(rest, " in ")) |at| {
                node.name = try collapseSpaces(arena, try cap(arena, rest[0..at], cap_name));
                node.detail = try cap(arena, rest[at + 4 ..], cap_cond);
            } else node.detail = try cap(arena, rest, cap_cond);
        } else {
            node.detail = try cap(arena, rest, cap_cond);
        }
        return node;
    };
    if (wordStatement(statement, "import")) |rest| {
        node.kind = "import";
        node.name = try cap(arena, rest, cap_import);
        return node;
    }
    if (wordStatement(statement, "from")) |rest| {
        if (topLevelWord(rest, " import ")) |at| {
            node.kind = "from-import";
            node.name = std.mem.trim(u8, rest[0..at], " ");
            node.detail = try cap(arena, std.mem.trim(u8, rest[at + 8 ..], " ()"), cap_import);
            return node;
        }
    }
    for ([_][]const u8{ "return", "raise", "yield", "del", "assert", "global", "nonlocal", "await" }) |kind| {
        if (wordStatement(statement, kind)) |rest| {
            node.kind = kind;
            node.detail = try cap(arena, rest, cap_expr);
            return node;
        }
    }
    for ([_][]const u8{ "pass", "break", "continue" }) |kind| {
        if (std.mem.eql(u8, statement, kind)) {
            node.kind = kind;
            return node;
        }
    }
    if (augmentedSplit(statement)) |aug| {
        node.kind = aug.op;
        node.name = try cap(arena, std.mem.trim(u8, statement[0..aug.at], " "), cap_name);
        node.detail = try cap(arena, statement[aug.at + aug.op.len ..], cap_value);
        return node;
    }
    if (assignmentSplit(statement)) |eq| {
        var target = std.mem.trim(u8, statement[0..eq], " ");
        // An annotation names the target's type, not a second target.
        if (topLevelColon(target)) |colon| target = std.mem.trim(u8, target[0..colon], " ");
        node.kind = "assign";
        node.name = try cap(arena, target, cap_name);
        node.detail = try cap(arena, statement[eq + 1 ..], cap_value);
        return node;
    }
    node.detail = try cap(arena, statement, cap_expr);
    return node;
}

fn wordStatement(statement: []const u8, word: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, statement, word)) return null;
    const rest = statement[word.len..];
    if (rest.len == 0) return "";
    if (rest[0] != ' ' and rest[0] != '(') return null;
    return std.mem.trim(u8, rest, " ");
}

fn summarizeParams(arena: Allocator, params: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = SplitTopLevel{ .text = params, .separator = ',' };
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, try cap(arena, trimmed, cap_param));
    }
    return out.items;
}

const SplitTopLevel = struct {
    text: []const u8,
    separator: u8,
    index: usize = 0,

    fn next(self: *SplitTopLevel) ?[]const u8 {
        if (self.index > self.text.len) return null;
        const start = self.index;
        var scan: Scan = .{};
        while (self.index < self.text.len) : (self.index += 1) {
            if (scan.step(self.text, &self.index) and self.text[self.index] == self.separator) {
                defer self.index += 1;
                return self.text[start..self.index];
            }
        }
        self.index += 1;
        return self.text[start..];
    }
};

fn topLevelWord(text: []const u8, word: []const u8) ?usize {
    var scan: Scan = .{};
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (scan.step(text, &index) and std.mem.startsWith(u8, text[index..], word)) return index;
    }
    return null;
}

fn topLevelColon(text: []const u8) ?usize {
    var scan: Scan = .{};
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (scan.step(text, &index) and text[index] == ':') return index;
    }
    return null;
}

const Augmented = struct { at: usize, op: []const u8 };

fn augmentedSplit(text: []const u8) ?Augmented {
    var scan: Scan = .{};
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (!scan.step(text, &index)) continue;
        for (aug_ops) |op| {
            if (std.mem.startsWith(u8, text[index..], op)) return .{ .at = index, .op = op };
        }
        if (text[index] == '=') return null;
    }
    return null;
}

/// The `=` of a plain assignment, outside brackets and strings, or null for
/// a comparison, a keyword argument or an augmented assignment.
fn assignmentSplit(text: []const u8) ?usize {
    var scan: Scan = .{};
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (!scan.step(text, &index) or text[index] != '=') continue;
        const before = if (index > 0) text[index - 1] else ' ';
        const after = if (index + 1 < text.len) text[index + 1] else ' ';
        if (after == '=' or std.mem.findScalar(u8, "=!<>+-*/%&|^@:", before) != null) return null;
        return index;
    }
    return null;
}

/// One line of text, at most `limit` bytes, ending in "…" when cut.
fn cap(arena: Allocator, text: []const u8, limit: usize) ![]const u8 {
    const flat = try collapseWhitespace(arena, std.mem.trim(u8, text, " \t"));
    if (flat.len <= limit) return flat;
    var end: usize = limit - 1;
    while (end > 0 and (flat[end] & 0xc0) == 0x80) end -= 1;
    return arena.print("{s}…", .{std.mem.trimEnd(u8, flat[0..end], " ")});
}

fn collapseWhitespace(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "  ") == null and std.mem.findAny(u8, text, "\t\n") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |byte| {
        const blank = byte == ' ' or byte == '\t' or byte == '\n';
        if (blank) {
            if (!space) try out.append(arena, ' ');
            space = true;
        } else {
            try out.append(arena, byte);
            space = false;
        }
    }
    return out.items;
}

/// "i, line" reads "i,line", as proto prints a loop target.
fn collapseSpaces(arena: Allocator, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, text, ", ", ",");
}

/// Three or more imports in a row at one depth read as one row.
fn foldImports(arena: Allocator, nodes: []const Node) ![]const Node {
    var out: std.ArrayList(Node) = .empty;
    var index: usize = 0;
    while (index < nodes.len) {
        var end = index;
        while (end < nodes.len and isImport(nodes[end]) and nodes[end].depth == nodes[index].depth) end += 1;
        if (end - index >= 3) {
            var names: std.ArrayList(u8) = .empty;
            for (nodes[index..end]) |node| {
                if (names.items.len > 0) try names.appendSlice(arena, ", ");
                if (std.mem.eql(u8, node.kind, "from-import"))
                    try names.print(arena, "{s}.{s}", .{ node.name, node.detail })
                else
                    try names.appendSlice(arena, node.name);
            }
            try out.append(arena, .{
                .kind = "imports",
                .name = try cap(arena, names.items, cap_import),
                .line = nodes[index].line,
                .depth = nodes[index].depth,
            });
            index = end;
            continue;
        }
        try out.append(arena, nodes[index]);
        index += 1;
    }
    return out.items;
}

fn isImport(node: Node) bool {
    return std.mem.eql(u8, node.kind, "import") or std.mem.eql(u8, node.kind, "from-import");
}

fn isHeaderKind(kind: []const u8) bool {
    for (header_kinds) |header| if (std.mem.eql(u8, header, kind)) return true;
    return false;
}

/// A node's row text, without its tree connector.
pub fn nodeText(arena: Allocator, node: Node) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, node.kind, "assign")) {
        try out.appendSlice(arena, node.name);
        if (node.detail.len > 0) try out.print(arena, " ← {s}", .{node.detail});
    } else if (std.mem.endsWith(u8, node.kind, "=") and node.kind.len <= 3) {
        try out.print(arena, "{s} {s} {s}", .{ node.name, node.kind, node.detail });
    } else if (std.mem.eql(u8, node.kind, "expr")) {
        try out.appendSlice(arena, node.detail);
    } else {
        try out.appendSlice(arena, node.kind);
        if (node.name.len > 0) try out.print(arena, " {s}", .{node.name});
        if (node.detail.len > 0) try out.print(arena, " {s}", .{node.detail});
    }
    if (isHeaderKind(node.kind)) try out.print(arena, " ·L{d}", .{node.line});
    return out.items;
}

/// The outline as rows: `Module · N nodes`, then the tree, at most
/// `max_rows` rows in all; a cut tree ends in "… N more".
pub fn rows(arena: Allocator, outline: Outline, max_rows: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, try arena.print("Module · {d} node{s}", .{ outline.total, if (outline.total == 1) "" else "s" }));
    const nodes = outline.nodes;
    // A node is its parent's last child when no sibling follows it.
    const last = try arena.alloc(bool, nodes.len);
    var max_depth: usize = 0;
    for (nodes) |node| max_depth = @max(max_depth, node.depth);
    const seen = try arena.alloc(bool, max_depth + 1);
    @memset(seen, false);
    var back = nodes.len;
    while (back > 0) {
        back -= 1;
        const depth = nodes[back].depth;
        last[back] = !seen[depth];
        seen[depth] = true;
        for (seen[depth + 1 ..]) |*deeper| deeper.* = false;
    }
    var open_rails: std.ArrayList(bool) = .empty;
    const budget = max_rows -| 1;
    for (nodes, 0..) |node, index| {
        if (out.items.len - 1 + 1 == budget and index + 1 < nodes.len) {
            try out.append(arena, try arena.print("… {d} more", .{nodes.len - index}));
            break;
        }
        open_rails.shrinkRetainingCapacity(@min(open_rails.items.len, node.depth));
        var prefix: std.ArrayList(u8) = .empty;
        for (open_rails.items) |rail| try prefix.appendSlice(arena, if (rail) "│  " else "   ");
        try prefix.appendSlice(arena, if (last[index]) "└─ " else "├─ ");
        try out.append(arena, try arena.print("{s}{s}", .{ prefix.items, try nodeText(arena, node) }));
        try open_rails.append(arena, !last[index]);
    }
    return out.items;
}

test "a heredoc's Python is found with the shell around it" {
    const command = "/opt/homebrew/bin/python3.13 - <<'PY'\nimport os\nos.nope()\nPY\necho done";
    const found = script(command).?;
    try std.testing.expectEqualStrings("python3.13", found.interpreter);
    try std.testing.expectEqualStrings("heredoc", found.form);
    try std.testing.expectEqualStrings("import os\nos.nope()\n", found.code);
    try std.testing.expectEqualStrings("PY\necho done", found.after);
    try std.testing.expect(found.mixed());
    const plain_run = script("python3 - <<'PY'\nprint(1)\nPY").?;
    try std.testing.expect(!plain_run.mixed());
    const chained = script("proto models --help && python3.13 <<'PY'\nprint(1)\nPY").?;
    try std.testing.expectEqualStrings("proto models --help && python3.13 <<'PY'", chained.before);
    try std.testing.expect(chained.mixed());
    const inline_run = script("python3 -c 'import sys; print(sys.version)'").?;
    try std.testing.expectEqualStrings("-c", inline_run.form);
    try std.testing.expectEqualStrings("import sys; print(sys.version)", inline_run.code);
    try std.testing.expect(!inline_run.mixed());
    try std.testing.expect(script("cd /tmp && python3 -c 'print(1)' | head").?.mixed());
    try std.testing.expect(script("ls -la") == null);
    try std.testing.expect(script("python3 tool.py") == null);
    try std.testing.expect(script("cat python3.txt") == null);
    // A heredoc still streaming has no code yet.
    try std.testing.expectEqualStrings("", script("python3 - <<'PY'").?.code);
}

test "statements outline as proto's tree with line numbers and arrows" {
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
        \\    for i, line in enumerate(text.splitlines()):
        \\        if re.search(r'cento', line): print(name)
        \\count += 1
        \\def load(path: str, *, strict=False) -> dict:
        \\    return {}
        \\with sqlite3.connect(root / 'models.db') as con:
        \\    con.execute("DELETE FROM t WHERE a = 'x'")
        \\
    ;
    const outline = (try parse(arena, code)).?;
    try std.testing.expectEqual(@as(usize, 13), outline.total);
    const shown = try rows(arena, outline, 40);
    const expected = [_][]const u8{
        "Module · 13 nodes",
        "├─ from-import pathlib Path",
        "├─ import re, sqlite3",
        "├─ root ← Path.home() / '.proto/agent'",
        "├─ for name ['config.yml', 'models.yml'] ·L4",
        "│  ├─ text ← (root / name).read_text()",
        "│  └─ for i,line enumerate(text.splitlines()) ·L7",
        "│     └─ if re.search(r'cento', line) ·L8",
        "│        └─ print(name)",
        "├─ count += 1",
        "├─ def load(path: str, *, strict=False) → dict ·L10",
        "│  └─ return {}",
        "└─ with sqlite3.connect(root / 'models.db') as con ·L12",
        "   └─ con.execute(\"DELETE FROM t WHERE a = 'x'\")",
    };
    try std.testing.expectEqual(expected.len, shown.len);
    for (expected, shown) |want, got| try std.testing.expectEqualStrings(want, got);

    const cut = try rows(arena, outline, 5);
    try std.testing.expectEqual(@as(usize, 5), cut.len);
    try std.testing.expectEqualStrings("… 10 more", cut[4]);
}

test "imports fold and broken code reads as unparsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const folded = (try parse(arena, "import os\nimport sys\nfrom pathlib import Path\nprint(os.getcwd())\n")).?;
    try std.testing.expectEqual(@as(usize, 4), folded.total);
    const shown = try rows(arena, folded, 10);
    try std.testing.expectEqualStrings("├─ imports os, sys, pathlib.Path", shown[1]);
    try std.testing.expectEqualStrings("└─ print(os.getcwd())", shown[2]);

    try std.testing.expect(try parse(arena, "print(1\n") == null);
    try std.testing.expect(try parse(arena, "if x:\nprint(1)\n") == null);
    try std.testing.expect(try parse(arena, "x = 1\n    y = 2\n") == null);
    try std.testing.expect(try parse(arena, "s = 'unterminated\n") == null);
    try std.testing.expect(try parse(arena, "") == null);
    const one_liner = (try parse(arena, "import sys; print(sys.version)")).?;
    try std.testing.expectEqual(@as(usize, 2), one_liner.total);
    try std.testing.expectEqualStrings("expr", (try parse(arena, "x == 1")).?.nodes[0].kind);
}

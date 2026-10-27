//! The YAML subset rule frontmatter uses, read into `std.json.Value`.
//!
//! Block mappings and sequences by indentation, flow `[ ]` and `{ }`
//! collections, double- and single-quoted scalars, plain scalars, `|` and
//! `>` block scalars, and `#` comments. Plain `true`, `false`, `null`, `~`
//! and integers are typed; everything else is a string. Anchors, aliases
//! and tags are not YAML here: a plain scalar such as Cursor's
//! `globs: *.ts` stays the string it looks like.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Error = error{ InvalidYaml, OutOfMemory };

const Line = struct {
    indent: usize,
    /// The line without indentation and trailing comment.
    text: []const u8,
    /// The raw line, for block scalars.
    raw: []const u8,
};

/// Parses `source` as a YAML document whose root is a mapping. All memory
/// comes from `arena`.
pub fn parse(arena: Allocator, source: []const u8) Error!Value {
    var lines: std.ArrayList(Line) = .empty;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |raw_line| {
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        if (indent < raw.len and raw[indent] == '\t') return error.InvalidYaml;
        const text = std.mem.trimEnd(u8, stripComment(raw[indent..]), " \t");
        try lines.append(arena, .{ .indent = indent, .text = text, .raw = raw });
    }
    var parser: Parser = .{ .arena = arena, .lines = lines.items };
    parser.skipBlank();
    if (parser.index >= parser.lines.len) return .{ .object = .empty };
    const root = try parser.block(parser.lines[parser.index].indent);
    parser.skipBlank();
    if (parser.index < parser.lines.len) return error.InvalidYaml;
    return root;
}

fn stripComment(text: []const u8) []const u8 {
    var quote: ?u8 = null;
    var depth: usize = 0;
    for (text, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) {
                if (q == '\'' and i + 1 < text.len and text[i + 1] == '\'') continue;
                quote = null;
            } else if (c == '\\' and q == '"') {
                continue;
            }
            continue;
        }
        switch (c) {
            '"', '\'' => if (i == 0 or isQuoteStart(text[i - 1]) or depth > 0) {
                quote = c;
            },
            '[', '{' => depth += 1,
            ']', '}' => depth -|= 1,
            '#' => if (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t') return text[0..i],
            else => {},
        }
    }
    return text;
}

fn isQuoteStart(prev: u8) bool {
    return prev == ' ' or prev == ':' or prev == '-' or prev == '[' or prev == '{' or prev == ',';
}

const Parser = struct {
    arena: Allocator,
    lines: []const Line,
    index: usize = 0,

    fn skipBlank(self: *Parser) void {
        while (self.index < self.lines.len and self.lines[self.index].text.len == 0) self.index += 1;
    }

    /// A block node whose lines start at `indent`.
    fn block(self: *Parser, indent: usize) Error!Value {
        self.skipBlank();
        const line = self.lines[self.index];
        if (isSequenceItem(line.text)) return self.sequence(indent);
        return self.mapping(indent);
    }

    fn sequence(self: *Parser, indent: usize) Error!Value {
        var items = std.json.Array.init(self.arena);
        while (true) {
            self.skipBlank();
            if (self.index >= self.lines.len) break;
            const line = self.lines[self.index];
            if (line.indent != indent or !isSequenceItem(line.text)) break;
            const rest = std.mem.trimStart(u8, line.text[1..], " ");
            const item_indent = indent + (line.text.len - rest.len);
            if (rest.len == 0) {
                self.index += 1;
                self.skipBlank();
                if (self.index < self.lines.len and self.lines[self.index].indent > indent) {
                    try items.append(try self.block(self.lines[self.index].indent));
                } else {
                    try items.append(.null);
                }
                continue;
            }
            if (isSequenceItem(rest) or mappingKey(rest) != null) {
                // An inline mapping or nested sequence item: re-read this
                // line as if it began at the item's column.
                const shifted = try self.arena.dupe(Line, self.lines);
                shifted[self.index] = .{ .indent = item_indent, .text = rest, .raw = line.raw };
                var nested: Parser = .{ .arena = self.arena, .lines = shifted, .index = self.index };
                try items.append(try nested.block(item_indent));
                self.index = nested.index;
                continue;
            }
            self.index += 1;
            try items.append(try self.inlineValue(rest, indent));
        }
        return .{ .array = items };
    }

    fn mapping(self: *Parser, indent: usize) Error!Value {
        var map: std.json.ObjectMap = .empty;
        while (true) {
            self.skipBlank();
            if (self.index >= self.lines.len) break;
            const line = self.lines[self.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.InvalidYaml;
            if (isSequenceItem(line.text)) break;
            const split = mappingKey(line.text) orelse return error.InvalidYaml;
            const key = try self.scalarKey(split.key);
            const rest = split.rest;
            self.index += 1;
            if (rest.len == 0) {
                self.skipBlank();
                if (self.index < self.lines.len) {
                    const next = self.lines[self.index];
                    // A sequence may sit at the key's own indentation.
                    if (next.indent > indent or (next.indent == indent and isSequenceItem(next.text))) {
                        try map.put(self.arena, key, try self.block(next.indent));
                        continue;
                    }
                }
                try map.put(self.arena, key, .null);
                continue;
            }
            try map.put(self.arena, key, try self.inlineValue(rest, indent));
        }
        return .{ .object = map };
    }

    fn scalarKey(self: *Parser, raw: []const u8) Error![]const u8 {
        const trimmed = std.mem.trim(u8, raw, " ");
        if (trimmed.len >= 2 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
            var flow: Flow = .{ .arena = self.arena, .src = trimmed };
            const value = try flow.value();
            if (value != .string) return error.InvalidYaml;
            return value.string;
        }
        return trimmed;
    }

    /// The value after `key:` or `- ` on one line; block scalars and
    /// multi-line flow collections continue onto following lines.
    fn inlineValue(self: *Parser, text: []const u8, parent_indent: usize) Error!Value {
        if (text[0] == '|' or text[0] == '>') return self.blockScalar(text, parent_indent);
        var src = text;
        if ((text[0] == '[' or text[0] == '{') and !flowClosed(text)) {
            var joined: std.ArrayList(u8) = .empty;
            try joined.appendSlice(self.arena, text);
            while (self.index < self.lines.len and !flowClosed(joined.items)) {
                try joined.append(self.arena, ' ');
                try joined.appendSlice(self.arena, std.mem.trim(u8, self.lines[self.index].text, " "));
                self.index += 1;
            }
            src = joined.items;
        }
        var flow: Flow = .{ .arena = self.arena, .src = src };
        const value = try flow.value();
        flow.skipSpace();
        if (flow.pos != src.len) return error.InvalidYaml;
        return value;
    }

    fn blockScalar(self: *Parser, header: []const u8, parent_indent: usize) Error!Value {
        const folded = header[0] == '>';
        var keep_trailing = false;
        var strip = false;
        for (header[1..]) |c| switch (c) {
            '+' => keep_trailing = true,
            '-' => strip = true,
            else => {},
        };
        var out: std.ArrayList(u8) = .empty;
        var block_indent: ?usize = null;
        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            const blank = std.mem.trim(u8, line.raw, " ").len == 0;
            if (!blank) {
                if (line.indent <= parent_indent) break;
                if (block_indent == null) block_indent = line.indent;
                if (line.indent < block_indent.?) break;
            }
            self.index += 1;
            const content = if (blank) "" else line.raw[block_indent.?..];
            if (folded and out.items.len > 0 and content.len > 0 and out.items[out.items.len - 1] == '\n' and
                (out.items.len < 2 or out.items[out.items.len - 2] != '\n'))
            {
                out.items[out.items.len - 1] = ' ';
            }
            try out.appendSlice(self.arena, content);
            try out.append(self.arena, '\n');
        }
        var text: []const u8 = out.items;
        if (!keep_trailing) {
            text = std.mem.trimEnd(u8, text, "\n");
            if (!strip and text.len > 0) text = out.items[0 .. text.len + 1];
        }
        return .{ .string = text };
    }
};

fn isSequenceItem(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

const KeySplit = struct { key: []const u8, rest: []const u8 };

/// Splits `key: rest` at the first `:` followed by a space or the end,
/// outside quotes and flow collections.
fn mappingKey(text: []const u8) ?KeySplit {
    if (text.len == 0 or text[0] == '[' or text[0] == '{') return null;
    var quote: ?u8 = null;
    for (text, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (i == 0 and (c == '"' or c == '\'')) {
            quote = c;
            continue;
        }
        if (c == ':' and (i + 1 == text.len or text[i + 1] == ' ')) {
            return .{ .key = text[0..i], .rest = std.mem.trim(u8, text[i + 1 ..], " ") };
        }
    }
    return null;
}

fn flowClosed(text: []const u8) bool {
    var depth: isize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (text) |c| {
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\' and q == '"') {
                escaped = true;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
    }
    return depth <= 0;
}

const Flow = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    in_flow: bool = false,

    fn skipSpace(self: *Flow) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
    }

    fn value(self: *Flow) Error!Value {
        self.skipSpace();
        if (self.pos >= self.src.len) return .null;
        return switch (self.src[self.pos]) {
            '[' => self.list(),
            '{' => self.map(),
            '"' => .{ .string = try self.doubleQuoted() },
            '\'' => .{ .string = try self.singleQuoted() },
            else => self.plain(),
        };
    }

    fn list(self: *Flow) Error!Value {
        self.pos += 1;
        var items = std.json.Array.init(self.arena);
        const was = self.in_flow;
        self.in_flow = true;
        defer self.in_flow = was;
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len) return error.InvalidYaml;
            if (self.src[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            try items.append(try self.value());
            self.skipSpace();
            if (self.pos < self.src.len and self.src[self.pos] == ',') self.pos += 1;
        }
        return .{ .array = items };
    }

    fn map(self: *Flow) Error!Value {
        self.pos += 1;
        var object: std.json.ObjectMap = .empty;
        const was = self.in_flow;
        self.in_flow = true;
        defer self.in_flow = was;
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len) return error.InvalidYaml;
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            const key_value = try self.value();
            const key = switch (key_value) {
                .string => |s| s,
                else => return error.InvalidYaml,
            };
            self.skipSpace();
            if (self.pos >= self.src.len or self.src[self.pos] != ':') return error.InvalidYaml;
            self.pos += 1;
            try object.put(self.arena, key, try self.value());
            self.skipSpace();
            if (self.pos < self.src.len and self.src[self.pos] == ',') self.pos += 1;
        }
        return .{ .object = object };
    }

    fn plain(self: *Flow) Error!Value {
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (self.in_flow and (c == ',' or c == ']' or c == '}')) break;
            if (c == ':' and (self.pos + 1 == self.src.len or self.src[self.pos + 1] == ' ') and self.in_flow) break;
        }
        const text = std.mem.trim(u8, self.src[start..self.pos], " \t");
        if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
        if (std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "~")) return .null;
        if (std.fmt.parseInt(i64, text, 10)) |number| return .{ .integer = number } else |_| {}
        return .{ .string = text };
    }

    fn singleQuoted(self: *Flow) Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '\'') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                    try out.append(self.arena, '\'');
                    self.pos += 1;
                    continue;
                }
                self.pos += 1;
                return out.items;
            }
            try out.append(self.arena, c);
        }
        return error.InvalidYaml;
    }

    fn doubleQuoted(self: *Flow) Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '"') return out.items;
            if (c != '\\') {
                try out.append(self.arena, c);
                continue;
            }
            if (self.pos >= self.src.len) return error.InvalidYaml;
            const e = self.src[self.pos];
            self.pos += 1;
            switch (e) {
                'n' => try out.append(self.arena, '\n'),
                't' => try out.append(self.arena, '\t'),
                'r' => try out.append(self.arena, '\r'),
                '0' => try out.append(self.arena, 0),
                '"', '\\', '/', ' ' => try out.append(self.arena, e),
                'x', 'u', 'U' => {
                    const digits: usize = switch (e) {
                        'x' => 2,
                        'u' => 4,
                        else => 8,
                    };
                    if (self.pos + digits > self.src.len) return error.InvalidYaml;
                    const code = std.fmt.parseInt(u21, self.src[self.pos .. self.pos + digits], 16) catch return error.InvalidYaml;
                    self.pos += digits;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(code, &buf) catch return error.InvalidYaml;
                    try out.appendSlice(self.arena, buf[0..len]);
                },
                else => return error.InvalidYaml,
            }
        }
        return error.InvalidYaml;
    }
};

test "yaml reads the frontmatter shapes rules use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc =
        \\description: "Never use `Box::leak`" # trailing comment
        \\scope: "tool:bash"
        \\interruptMode: never
        \\match:
        \\  if: { lang: [rs, rust] }
        \\  then:
        \\    regex: "Box::leak"
        \\    in: code
        \\  else:
        \\    all:
        \\      - regex: ['a\.b', "c\\(d"]
        \\        in: [code, string]
        \\      - llm: "Is it?"
        \\      - ast:
        \\        - "for $I := 0; $I < $N; $I++ { $$$BODY }"
        \\globs: *.ts,*.tsx
        \\count: 2
        \\enabled: false
    ;
    const value = try parse(arena, doc);
    const root = value.object;
    try std.testing.expectEqualStrings("Never use `Box::leak`", root.get("description").?.string);
    try std.testing.expectEqualStrings("never", root.get("interruptMode").?.string);
    try std.testing.expectEqualStrings("*.ts,*.tsx", root.get("globs").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("count").?.integer);
    try std.testing.expectEqual(false, root.get("enabled").?.bool);
    const match = root.get("match").?.object;
    try std.testing.expectEqualStrings("rust", match.get("if").?.object.get("lang").?.array.items[1].string);
    try std.testing.expectEqualStrings("Box::leak", match.get("then").?.object.get("regex").?.string);
    const all = match.get("else").?.object.get("all").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("a\\.b", all[0].object.get("regex").?.array.items[0].string);
    try std.testing.expectEqualStrings("c\\(d", all[0].object.get("regex").?.array.items[1].string);
    try std.testing.expectEqualStrings("string", all[0].object.get("in").?.array.items[1].string);
    try std.testing.expectEqualStrings("Is it?", all[1].object.get("llm").?.string);
    try std.testing.expectEqualStrings("for $I := 0; $I < $N; $I++ { $$$BODY }", all[2].object.get("ast").?.array.items[0].string);
}

test "yaml reads sequences at key indentation, block scalars and multi-line flows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc =
        \\match:
        \\  all:
        \\  - lang: [go]
        \\  - ast:
        \\    - "a"
        \\    - 'it''s'
        \\body: |
        \\  line one
        \\  line two
        \\folded: >
        \\  a
        \\  b
        \\list: [one,
        \\  two]
    ;
    const root = (try parse(arena, doc)).object;
    const all = root.get("match").?.object.get("all").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("it's", all[1].object.get("ast").?.array.items[1].string);
    try std.testing.expectEqualStrings("line one\nline two\n", root.get("body").?.string);
    try std.testing.expectEqualStrings("a b\n", root.get("folded").?.string);
    try std.testing.expectEqualStrings("two", root.get("list").?.array.items[1].string);
    try std.testing.expectError(error.InvalidYaml, parse(arena, "a: [1, 2"));
    try std.testing.expectError(error.InvalidYaml, parse(arena, "a: 1\n   b: 2"));
}

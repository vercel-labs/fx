const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    max_output_bytes: usize = 10 * 1024 * 1024,
};

pub fn convert(alloc: Allocator, html: []const u8, options: Options) ![]u8 {
    var parser = Parser.init(alloc, options.max_output_bytes);
    defer parser.deinit();
    try parser.convert(html);
    return parser.out.toOwnedSlice(alloc);
}

const Parser = struct {
    alloc: Allocator,
    out: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    link_text: std.ArrayList(u8) = .empty,
    max_output_bytes: usize,
    suppress_depth: usize = 0,
    title_active: bool = false,
    pre_depth: usize = 0,
    active_link_href: ?[]u8 = null,
    table_cell_open: bool = false,
    last_was_space: bool = true,

    fn init(alloc: Allocator, max_output_bytes: usize) Parser {
        return .{ .alloc = alloc, .max_output_bytes = max_output_bytes };
    }

    fn deinit(self: *Parser) void {
        self.out.deinit(self.alloc);
        self.title.deinit(self.alloc);
        self.link_text.deinit(self.alloc);
        if (self.active_link_href) |href| self.alloc.free(href);
    }

    fn convert(self: *Parser, html: []const u8) !void {
        var index: usize = 0;
        while (index < html.len and !self.full()) {
            if (html[index] != '<') {
                const next = std.mem.findScalar(u8, html[index..], '<') orelse html.len - index;
                try self.appendText(html[index .. index + next]);
                index += next;
                continue;
            }

            if (std.mem.startsWith(u8, html[index..], "<!--")) {
                const end = std.mem.find(u8, html[index + 4 ..], "-->") orelse {
                    index = html.len;
                    continue;
                };
                index += 4 + end + 3;
                continue;
            }

            const tag_end = std.mem.findScalar(u8, html[index..], '>') orelse {
                try self.appendText(html[index..]);
                break;
            };
            try self.handleTag(html[index + 1 .. index + tag_end]);
            index += tag_end + 1;
        }
        self.trimTrailingWhitespace();
        try self.prependTitle();
        self.trimTrailingWhitespace();
        if (self.out.items.len > 0) try self.appendByte('\n');
    }

    fn handleTag(self: *Parser, raw_tag: []const u8) !void {
        var tag = std.mem.trim(u8, raw_tag, " \t\r\n");
        if (tag.len == 0) return;
        if (tag[0] == '!' or tag[0] == '?') return;

        const closing = tag[0] == '/';
        if (closing) tag = std.mem.trim(u8, tag[1..], " \t\r\n");
        const self_closing = tag.len > 0 and tag[tag.len - 1] == '/';
        if (self_closing) tag = std.mem.trimEnd(u8, tag[0 .. tag.len - 1], " \t\r\n");

        const name_end = tagNameEnd(tag);
        if (name_end == 0) return;
        const raw_name = tag[0..name_end];
        const attrs = tag[name_end..];
        var name_buf: [32]u8 = undefined;
        const name = lowerTagName(&name_buf, raw_name);

        if (std.mem.eql(u8, name, "title")) {
            if (closing) {
                self.title_active = false;
            } else if (!self_closing and self.title.items.len == 0) {
                self.title_active = true;
            }
            return;
        }

        if (suppressedTag(name)) {
            if (closing) {
                if (self.suppress_depth > 0) self.suppress_depth -= 1;
            } else if (!self_closing) {
                self.suppress_depth += 1;
            }
            return;
        }
        if (self.suppress_depth > 0) return;

        if (headingLevel(name)) |level| {
            if (!closing) {
                try self.blockBreak();
                var count: u8 = 0;
                while (count < level) : (count += 1) try self.appendByte('#');
                try self.appendByte(' ');
            } else {
                try self.blockBreak();
            }
            return;
        }

        if (std.mem.eql(u8, name, "p") or
            std.mem.eql(u8, name, "div") or
            std.mem.eql(u8, name, "section") or
            std.mem.eql(u8, name, "article") or
            std.mem.eql(u8, name, "main") or
            std.mem.eql(u8, name, "header") or
            std.mem.eql(u8, name, "footer") or
            std.mem.eql(u8, name, "blockquote"))
        {
            try self.blockBreak();
            return;
        }
        if (std.mem.eql(u8, name, "br")) {
            try self.softBreak();
            return;
        }
        if (std.mem.eql(u8, name, "ul") or std.mem.eql(u8, name, "ol")) {
            try self.blockBreak();
            return;
        }
        if (std.mem.eql(u8, name, "li")) {
            if (!closing) {
                try self.blockBreak();
                try self.appendSlice("- ");
            } else {
                try self.blockBreak();
            }
            return;
        }
        if (std.mem.eql(u8, name, "a")) {
            if (!closing) {
                if (self.active_link_href == null) {
                    self.active_link_href = try attributeValue(self.alloc, attrs, "href");
                    self.link_text.clearRetainingCapacity();
                }
            } else {
                try self.flushLink();
            }
            return;
        }
        if (std.mem.eql(u8, name, "code")) {
            if (self.pre_depth == 0) try self.appendByte('`');
            return;
        }
        if (std.mem.eql(u8, name, "pre")) {
            if (!closing) {
                try self.blockBreak();
                try self.appendSlice("```\n");
                self.pre_depth += 1;
            } else {
                if (self.pre_depth > 0) self.pre_depth -= 1;
                self.trimTrailingWhitespace();
                try self.appendSlice("\n```");
                try self.blockBreak();
            }
            return;
        }
        if (std.mem.eql(u8, name, "tr")) {
            if (!closing) {
                try self.blockBreak();
            } else {
                if (self.table_cell_open) {
                    try self.appendByte(' ');
                    self.table_cell_open = false;
                }
                try self.appendByte('|');
                try self.blockBreak();
            }
            return;
        }
        if (std.mem.eql(u8, name, "th") or std.mem.eql(u8, name, "td")) {
            if (!closing) {
                try self.appendSlice("| ");
                self.table_cell_open = true;
            } else if (self.table_cell_open) {
                try self.appendByte(' ');
                self.table_cell_open = false;
            }
            return;
        }
        if (std.mem.eql(u8, name, "img") and !closing) {
            if (try attributeValue(self.alloc, attrs, "alt")) |alt| {
                defer self.alloc.free(alt);
                try self.appendText(alt);
            }
        }
    }

    fn appendText(self: *Parser, raw: []const u8) !void {
        if (self.title_active) return self.appendTitleText(raw);
        if (self.suppress_depth > 0) return;

        var index: usize = 0;
        while (index < raw.len and !self.full()) {
            if (raw[index] == '&') {
                if (try self.appendEntity(raw, &index)) continue;
            }
            const byte = raw[index];
            index += 1;
            if (self.pre_depth > 0) {
                try self.appendByte(byte);
            } else if (std.ascii.isWhitespace(byte)) {
                try self.appendSpace();
            } else {
                try self.appendByte(byte);
            }
        }
    }

    fn appendTitleText(self: *Parser, raw: []const u8) !void {
        var index: usize = 0;
        while (index < raw.len and self.title.items.len < self.max_output_bytes) {
            const start = index;
            var entity_buf: [4]u8 = undefined;
            const bytes = blk: {
                index += 1;
                if (raw[start] == '&') {
                    if (std.mem.findScalar(u8, raw[start..@min(raw.len, start + 32)], ';')) |semi_rel| {
                        const end = start + semi_rel;
                        const entity = raw[start + 1 .. end];
                        index = end + 1;
                        if (decodeNumericEntity(entity)) |codepoint| {
                            const len = std.unicode.utf8Encode(codepoint, &entity_buf) catch break :blk raw[start .. end + 1];
                            break :blk entity_buf[0..len];
                        }
                        if (namedEntity(entity)) |value| break :blk value;
                        break :blk raw[start .. end + 1];
                    }
                }
                break :blk raw[start..index];
            };
            for (bytes) |byte| try self.appendTitleByte(byte);
        }
    }

    fn appendTitleByte(self: *Parser, byte: u8) !void {
        if (self.title.items.len >= self.max_output_bytes) return;
        if (std.ascii.isWhitespace(byte)) {
            if (self.title.items.len > 0 and self.title.items[self.title.items.len - 1] != ' ')
                try self.title.append(self.alloc, ' ');
        } else {
            try self.title.append(self.alloc, byte);
        }
    }

    fn appendEntity(self: *Parser, raw: []const u8, index: *usize) !bool {
        const start = index.*;
        const semi_rel = std.mem.findScalar(u8, raw[start..@min(raw.len, start + 32)], ';') orelse return false;
        const end = start + semi_rel;
        const entity = raw[start + 1 .. end];
        index.* = end + 1;

        if (decodeNumericEntity(entity)) |cp| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch {
                try self.appendSlice(raw[start .. end + 1]);
                return true;
            };
            try self.appendSlice(buf[0..n]);
            return true;
        }
        if (namedEntity(entity)) |value| {
            try self.appendSlice(value);
            return true;
        }
        try self.appendSlice(raw[start .. end + 1]);
        return true;
    }

    fn appendSpace(self: *Parser) !void {
        if (self.last_was_space) return;
        try self.appendByte(' ');
    }

    fn blockBreak(self: *Parser) !void {
        self.trimTrailingInlineWhitespace();
        if (self.out.items.len == 0) return;
        if (std.mem.endsWith(u8, self.out.items, "\n\n")) return;
        if (std.mem.endsWith(u8, self.out.items, "\n")) {
            try self.appendByte('\n');
        } else {
            try self.appendSlice("\n\n");
        }
    }

    fn softBreak(self: *Parser) !void {
        self.trimTrailingInlineWhitespace();
        if (self.out.items.len == 0 or std.mem.endsWith(u8, self.out.items, "\n")) return;
        try self.appendByte('\n');
    }

    fn flushLink(self: *Parser) !void {
        const href = self.active_link_href orelse return;
        self.active_link_href = null;
        defer self.alloc.free(href);
        defer self.link_text.clearRetainingCapacity();

        self.trimLinkText();
        if (self.link_text.items.len == 0) return;
        try self.appendByte('[');
        try self.appendSlice(self.link_text.items);
        try self.appendSlice("](");
        try self.appendSlice(href);
        try self.appendByte(')');
    }

    fn appendByte(self: *Parser, byte: u8) !void {
        var one = [_]u8{byte};
        try self.appendSlice(one[0..]);
    }

    fn appendSlice(self: *Parser, bytes: []const u8) !void {
        if (bytes.len == 0 or self.full()) return;
        const remaining = self.max_output_bytes - self.out.items.len;
        const take = @min(bytes.len, remaining);
        if (self.active_link_href != null and self.pre_depth == 0) {
            try self.link_text.appendSlice(self.alloc, bytes[0..take]);
        } else {
            try self.out.appendSlice(self.alloc, bytes[0..take]);
        }
        if (take > 0) self.last_was_space = std.ascii.isWhitespace(bytes[take - 1]);
    }

    fn full(self: Parser) bool {
        return self.out.items.len >= self.max_output_bytes;
    }

    fn trimTrailingWhitespace(self: *Parser) void {
        while (self.out.items.len > 0 and std.ascii.isWhitespace(self.out.items[self.out.items.len - 1])) {
            _ = self.out.pop();
        }
        self.last_was_space = true;
    }

    fn trimTrailingInlineWhitespace(self: *Parser) void {
        while (self.out.items.len > 0) {
            const byte = self.out.items[self.out.items.len - 1];
            if (byte != ' ' and byte != '\t') break;
            _ = self.out.pop();
        }
        self.last_was_space = self.out.items.len == 0 or std.ascii.isWhitespace(self.out.items[self.out.items.len - 1]);
    }

    fn trimLinkText(self: *Parser) void {
        while (self.link_text.items.len > 0 and std.ascii.isWhitespace(self.link_text.items[self.link_text.items.len - 1])) {
            _ = self.link_text.pop();
        }
        var start: usize = 0;
        while (start < self.link_text.items.len and std.ascii.isWhitespace(self.link_text.items[start])) : (start += 1) {}
        if (start > 0) std.mem.copyForwards(u8, self.link_text.items, self.link_text.items[start..]);
        self.link_text.items.len -= start;
    }

    fn trimTitle(self: *Parser) void {
        while (self.title.items.len > 0 and std.ascii.isWhitespace(self.title.items[self.title.items.len - 1])) {
            _ = self.title.pop();
        }
        var start: usize = 0;
        while (start < self.title.items.len and std.ascii.isWhitespace(self.title.items[start])) : (start += 1) {}
        if (start > 0) std.mem.copyForwards(u8, self.title.items, self.title.items[start..]);
        self.title.items.len -= start;
    }

    fn prependTitle(self: *Parser) !void {
        self.trimTitle();
        if (self.title.items.len == 0 or self.max_output_bytes == 0) return;

        var merged: std.ArrayList(u8) = .empty;
        errdefer merged.deinit(self.alloc);
        try self.appendWithinOutputLimit(&merged, "# ");
        try self.appendWithinOutputLimit(&merged, self.title.items);
        if (self.out.items.len > 0) {
            try self.appendWithinOutputLimit(&merged, "\n\n");
            try self.appendWithinOutputLimit(&merged, self.out.items);
        }
        self.out.deinit(self.alloc);
        self.out = merged;
    }

    fn appendWithinOutputLimit(self: *Parser, output: *std.ArrayList(u8), bytes: []const u8) !void {
        const remaining = self.max_output_bytes - output.items.len;
        try output.appendSlice(self.alloc, bytes[0..@min(bytes.len, remaining)]);
    }
};

fn tagNameEnd(tag: []const u8) usize {
    var index: usize = 0;
    while (index < tag.len) : (index += 1) {
        if (!std.ascii.isAlphanumeric(tag[index])) break;
    }
    return index;
}

fn lowerTagName(buf: []u8, raw: []const u8) []const u8 {
    const len = @min(buf.len, raw.len);
    for (raw[0..len], 0..) |char, index| buf[index] = std.ascii.toLower(char);
    return buf[0..len];
}

fn suppressedTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "script") or
        std.mem.eql(u8, name, "style") or
        std.mem.eql(u8, name, "head") or
        std.mem.eql(u8, name, "noscript") or
        std.mem.eql(u8, name, "template") or
        std.mem.eql(u8, name, "svg") or
        std.mem.eql(u8, name, "canvas");
}

fn headingLevel(name: []const u8) ?u8 {
    if (name.len != 2 or name[0] != 'h') return null;
    return switch (name[1]) {
        '1'...'6' => name[1] - '0',
        else => null,
    };
}

fn attributeValue(alloc: Allocator, attrs: []const u8, wanted_name: []const u8) !?[]u8 {
    var index: usize = 0;
    while (index < attrs.len) {
        while (index < attrs.len and std.ascii.isWhitespace(attrs[index])) : (index += 1) {}
        const name_start = index;
        while (index < attrs.len and (std.ascii.isAlphanumeric(attrs[index]) or attrs[index] == '-' or attrs[index] == '_')) : (index += 1) {}
        if (index == name_start) {
            index += 1;
            continue;
        }
        const name = attrs[name_start..index];
        while (index < attrs.len and std.ascii.isWhitespace(attrs[index])) : (index += 1) {}
        if (index >= attrs.len or attrs[index] != '=') continue;
        index += 1;
        while (index < attrs.len and std.ascii.isWhitespace(attrs[index])) : (index += 1) {}
        if (index >= attrs.len) break;

        const value_start = if (attrs[index] == '"' or attrs[index] == '\'') blk: {
            const quote = attrs[index];
            index += 1;
            const start = index;
            while (index < attrs.len and attrs[index] != quote) : (index += 1) {}
            break :blk start;
        } else blk: {
            const start = index;
            while (index < attrs.len and !std.ascii.isWhitespace(attrs[index])) : (index += 1) {}
            break :blk start;
        };
        const value_end = index;
        if (index < attrs.len and (attrs[index] == '"' or attrs[index] == '\'')) index += 1;

        if (!std.ascii.eqlIgnoreCase(name, wanted_name)) continue;
        var out = Parser.init(alloc, value_end - value_start + 16);
        defer out.deinit();
        try out.appendText(attrs[value_start..value_end]);
        return try out.out.toOwnedSlice(alloc);
    }
    return null;
}

fn decodeNumericEntity(entity: []const u8) ?u21 {
    if (entity.len < 2 or entity[0] != '#') return null;
    const value = if (entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X'))
        std.fmt.parseInt(u21, entity[2..], 16) catch return null
    else
        std.fmt.parseInt(u21, entity[1..], 10) catch return null;
    if (value == 0 or value > 0x10ffff) return null;
    if (value >= 0xd800 and value <= 0xdfff) return null;
    return value;
}

fn namedEntity(entity: []const u8) ?[]const u8 {
    const entries = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "amp", .value = "&" },
        .{ .name = "lt", .value = "<" },
        .{ .name = "gt", .value = ">" },
        .{ .name = "quot", .value = "\"" },
        .{ .name = "apos", .value = "'" },
        .{ .name = "nbsp", .value = " " },
        .{ .name = "copy", .value = "©" },
        .{ .name = "reg", .value = "®" },
        .{ .name = "trade", .value = "™" },
        .{ .name = "mdash", .value = "—" },
        .{ .name = "ndash", .value = "–" },
        .{ .name = "hellip", .value = "…" },
        .{ .name = "lsquo", .value = "‘" },
        .{ .name = "rsquo", .value = "’" },
        .{ .name = "ldquo", .value = "“" },
        .{ .name = "rdquo", .value = "”" },
        .{ .name = "laquo", .value = "«" },
        .{ .name = "raquo", .value = "»" },
        .{ .name = "times", .value = "×" },
        .{ .name = "divide", .value = "÷" },
        .{ .name = "bull", .value = "•" },
        .{ .name = "middot", .value = "·" },
        .{ .name = "sect", .value = "§" },
        .{ .name = "para", .value = "¶" },
        .{ .name = "deg", .value = "°" },
        .{ .name = "plusmn", .value = "±" },
        .{ .name = "euro", .value = "€" },
        .{ .name = "pound", .value = "£" },
        .{ .name = "yen", .value = "¥" },
        .{ .name = "cent", .value = "¢" },
    };
    for (entries) |entry| {
        if (std.mem.eql(u8, entity, entry.name)) return entry.value;
    }
    return null;
}

test "web_fetch converts representative html to bounded markdown" {
    const alloc = std.testing.allocator;
    const html =
        \\<!doctype html>
        \\<html>
        \\<head><title>Ignored</title><style>.x{}</style><script>alert(1)</script></head>
        \\<body>
        \\<h1>Release &amp; Notes</h1>
        \\<p>Hello <a href="/docs">docs</a> and <code>di ask</code>.</p>
        \\<ul><li>One</li><li>Two&nbsp;items</li></ul>
        \\<pre><code>const x = 1 &lt; 2;</code></pre>
        \\<table><tr><th>Name</th><th>Value</th></tr><tr><td>A</td><td>42</td></tr></table>
        \\<img src="x.png" alt="diagram">
        \\<p>&#169; &#x00AE; &unknown;</p>
        \\</body></html>
    ;

    const markdown = try convert(alloc, html, .{ .max_output_bytes = 4096 });
    defer alloc.free(markdown);

    try std.testing.expect(std.mem.find(u8, markdown, "# Release & Notes") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "# Ignored") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "[docs](/docs)") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "`di ask`") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "- One") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "Two items") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "const x = 1 < 2;") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "| Name | Value |") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "diagram") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "© ® &unknown;") != null);
    try std.testing.expect(std.mem.find(u8, markdown, "alert(1)") == null);
    try std.testing.expect(std.mem.find(u8, markdown, ".x{}") == null);
}

test "web_fetch decodes entities in html titles" {
    const alloc = std.testing.allocator;
    const markdown = try convert(
        alloc,
        "<html><head><title>News &amp; Updates &mdash; Site</title></head><body><p>Body</p></body></html>",
        .{ .max_output_bytes = 4096 },
    );
    defer alloc.free(markdown);

    try std.testing.expectEqualStrings("# News & Updates — Site\n\nBody\n", markdown);
}

test "web_fetch malformed html conversion remains bounded" {
    const alloc = std.testing.allocator;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(alloc);
    var index: usize = 0;
    while (index < 2048) : (index += 1) {
        try html.appendSlice(alloc, "<div><span>unclosed &amp; text ");
    }

    const markdown = try convert(alloc, html.items, .{ .max_output_bytes = 1024 });
    defer alloc.free(markdown);

    try std.testing.expect(markdown.len <= 1024);
    try std.testing.expect(std.mem.find(u8, markdown, "unclosed & text") != null);
}

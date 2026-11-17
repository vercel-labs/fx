const std = @import("std");
const block = @import("../agent/presentation/block_parse.zig");
const text_util = @import("../agent/presentation/text_util.zig");
const ansi = @import("../agent/presentation/ansi.zig");

pub const Target = struct {
    name: []const u8,
    text: []const u8,
};

const max_name_len = 48;
// Reserve one extra byte for a trailing underscore removed after truncation.
const suffix_group_len = max_name_len - 1 - 20 - 1;

const Names = struct {
    used: std.StringHashMap(void),
    next_suffix: std.StringHashMap(usize),
};

/// The caller owns the returned slice, names, and text until `free`.
/// Replies are supplied newest first; the caller selects at most three.
/// Candidate names are ASCII, at most 48 bytes, and unique within this result.
/// Unclosed fences run to the end of their container. Tables require pipe rows.
pub fn collect(alloc: std.mem.Allocator, replies: []const []const u8) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |target| {
            alloc.free(target.name);
            alloc.free(target.text);
        }
        targets.deinit(alloc);
    }
    var names: Names = .{ .used = .init(alloc), .next_suffix = .init(alloc) };
    defer names.used.deinit();
    defer names.next_suffix.deinit();
    try add(alloc, &targets, &names, "all", "", if (replies.len == 0) "" else replies[0]);

    for (replies) |reply| try scan(alloc, &targets, &names, reply, 0);
    return targets.toOwnedSlice(alloc);
}

const max_nesting = 16;

fn scan(alloc: std.mem.Allocator, targets: *std.ArrayList(Target), names: *Names, reply: []const u8, depth: usize) anyerror!void {
    var pos: usize = 0;
    var previous_blank = true;
    while (pos < reply.len) {
        const start = pos;
        const line = nextLine(reply, &pos);
        const was_blank = previous_blank;
        previous_blank = text_util.isBlankMarkdownLine(line);
        if (previous_blank) continue;

        // Match the renderer's treatment of indented code after a blank line.
        const list_item = listContent(line);
        if (was_blank and block.hasIndentedCodePrefix(line) and
            (list_item == null or std.mem.startsWith(u8, text_util.leftTrim(line), "+ ")))
        {
            var label = firstContent(line);
            while (pos < reply.len) {
                var next = pos;
                const code_line = nextLine(reply, &next);
                if (!text_util.isBlankMarkdownLine(code_line) and !block.hasIndentedCodePrefix(code_line)) break;
                previous_blank = text_util.isBlankMarkdownLine(code_line);
                if (label.len == 0) label = firstContent(code_line);
                pos = next;
            }
            const code = try deindent(alloc, reply[start..pos], 0, true);
            defer alloc.free(code);
            try add(alloc, targets, names, "code", label, code);
            continue;
        }
        if (block.parseFootnoteDefinition(line)) |footnote| {
            while (pos < reply.len) {
                var next = pos;
                if (block.footnoteContinuationBody(nextLine(reply, &next)) == null) break;
                pos = next;
            }
            if (depth == 0) try add(alloc, targets, names, "footnote", footnote.label, reply[start..pos]);
            if (depth < max_nesting) {
                const inner = try unwrapFootnote(alloc, reply[start..pos]);
                defer alloc.free(inner);
                try scan(alloc, targets, names, inner, depth + 1);
            }
            continue;
        }
        if (block.parseCodeFence(line)) |fence| {
            const content_start = pos;
            var content_end = reply.len;
            while (pos < reply.len) {
                const closing_start = pos;
                if (block.closesCodeFence(nextLine(reply, &pos), fence)) {
                    content_end = closing_start;
                    break;
                }
            }
            const code = try deindent(alloc, reply[content_start..content_end], fence.indent, false);
            defer alloc.free(code);
            try addCode(alloc, targets, names, block.codeFenceLanguage(line), code);
            previous_blank = false;
            continue;
        }
        if (block.parseBlockquote(line)) |quote| {
            var label = firstContent(quote.content);
            var state: QuoteState = .{};
            state.advance(quote.content);
            while (pos < reply.len) {
                var next = pos;
                const quote_line = nextLine(reply, &next);
                if (block.parseBlockquote(quote_line)) |parsed| {
                    if (label.len == 0) label = firstContent(parsed.content);
                    state.advance(parsed.content);
                } else if (!state.lazy or !block.isLazyBlockquoteContinuation(quote_line)) {
                    break;
                } else if (label.len == 0) {
                    label = firstContent(quote_line);
                }
                pos = next;
            }
            if (depth == 0) try add(alloc, targets, names, "quote", label, reply[start..pos]);
            if (depth < max_nesting) {
                const inner = try unwrapQuote(alloc, reply[start..pos]);
                defer alloc.free(inner);
                try scan(alloc, targets, names, inner, depth + 1);
            }
            continue;
        }
        if (block.isPipeLine(line) and !listOwnsPipe(line, reply, pos)) {
            const pipe = pipeBlock(reply, line, pos);
            pos = pipe.end;
            if (pipe.is_table or depth == 0) try add(alloc, targets, names, if (pipe.is_table) "table" else "paragraph", line, reply[start..pos]);
            continue;
        }
        if (block.isHorizontalRule(line)) {
            if (depth == 0) try add(alloc, targets, names, "thematic_break", "", reply[start..pos]);
            continue;
        }
        if (list_item) |content| {
            const Level = struct { indent: usize, column: usize };
            const base_indent = indentation(line);
            var levels: std.ArrayList(Level) = .empty;
            defer levels.deinit(alloc);
            try levels.append(alloc, .{ .indent = base_indent, .column = listContentColumn(line).? });
            var fence: ?block.CodeFence = block.parseCodeFence(content);
            while (pos < reply.len) {
                var next = pos;
                var item_start = pos;
                var item_line = nextLine(reply, &next);
                var had_blank = false;
                while (text_util.isBlankMarkdownLine(item_line) and next < reply.len) {
                    had_blank = true;
                    item_start = next;
                    item_line = nextLine(reply, &next);
                }
                if (text_util.isBlankMarkdownLine(item_line)) {
                    if (fence != null) pos = next;
                    break;
                }
                const indent = indentation(item_line);
                if (fence) |open| {
                    if (indent < levels.items[levels.items.len - 1].column) {
                        pos = item_start;
                        break;
                    }
                    if (block.closesCodeFence(item_line, open)) fence = null;
                } else if (listContentColumn(item_line)) |column| {
                    if (indent < base_indent) break;
                    while (levels.items.len > 0 and levels.items[levels.items.len - 1].indent >= indent) {
                        _ = levels.pop();
                    }
                    try levels.append(alloc, .{ .indent = indent, .column = column });
                    const item_content = listContent(item_line).?;
                    fence = block.parseCodeFence(item_content);
                } else {
                    while (levels.items.len > 1 and indent < levels.items[levels.items.len - 1].column and
                        indent >= levels.items[levels.items.len - 2].column)
                    {
                        _ = levels.pop();
                    }
                    if (indent >= levels.items[levels.items.len - 1].column) {
                        fence = block.parseCodeFence(item_line);
                    } else if (had_blank or startsBlock(item_line, reply, next)) {
                        break;
                    }
                }
                pos = next;
            }
            try add(alloc, targets, names, "list", content, reply[start..pos]);
            if (depth < max_nesting) {
                const inner = try unwrapList(alloc, reply[start..pos], base_indent);
                defer alloc.free(inner);
                try scan(alloc, targets, names, inner, depth + 1);
            }
            continue;
        }
        if (block.parseHeader(line)) |header| {
            try add(alloc, targets, names, "heading", header.content, reply[start..pos]);
            continue;
        }
        if (pos < reply.len and block.isSetextCandidate(line)) {
            var after_next = pos;
            const next_line = nextLine(reply, &after_next);
            if (block.parseSetextUnderline(next_line) != null) {
                pos = after_next;
                try add(alloc, targets, names, "heading", line, reply[start..pos]);
                continue;
            }
            if (block.definitionMarkerBody(next_line) != null) {
                pos = after_next;
                while (pos < reply.len) {
                    var next = pos;
                    const definition = nextLine(reply, &next);
                    if (block.isPipeLine(definition) or block.definitionMarkerBody(definition) == null) break;
                    pos = next;
                }
                if (depth == 0) try add(alloc, targets, names, "definition", line, reply[start..pos]);
                continue;
            }
        }
        while (pos < reply.len) {
            var next = pos;
            const paragraph_line = nextLine(reply, &next);
            if (text_util.isBlankMarkdownLine(paragraph_line) or startsBlock(paragraph_line, reply, next)) break;
            pos = next;
        }
        if (depth == 0) try add(alloc, targets, names, "paragraph", line, reply[start..pos]);
    }
}

pub fn free(alloc: std.mem.Allocator, targets: []Target) void {
    for (targets) |target| {
        alloc.free(target.name);
        alloc.free(target.text);
    }
    alloc.free(targets);
}

const QuoteState = struct {
    fence: ?block.CodeFence = null,
    pipe: bool = false,
    lazy: bool = false,

    fn advance(self: *QuoteState, line: []const u8) void {
        if (self.fence) |fence| {
            if (block.closesCodeFence(line, fence)) self.fence = null;
            self.lazy = false;
            return;
        }
        if (self.pipe and block.isPipeLine(line)) {
            self.lazy = false;
            return;
        }
        self.pipe = false;
        var content = line;
        while (listContent(content)) |item| content = item;
        if (block.parseCodeFence(content)) |fence| {
            self.fence = fence;
            self.lazy = false;
        } else if (block.isPipeLine(line)) {
            self.pipe = true;
            self.lazy = false;
        } else {
            self.lazy = block.isBlockquoteParagraph(line);
        }
    }
};

fn listContent(line: []const u8) ?[]const u8 {
    const content = if (block.parseUnorderedList(line)) |item| item.content else if (block.parseOrderedList(line)) |item| item.content else return null;
    return if (block.parseTaskListItem(content)) |task| task.content else content;
}

fn listOwnsPipe(line: []const u8, reply: []const u8, after_line: usize) bool {
    const content = listContent(line) orelse return false;
    if (std.mem.startsWith(u8, text_util.leftTrim(content), "|") or
        block.parseBlockquote(content) != null or block.parseCodeFence(content) != null or
        listContent(content) != null) return true;
    if (after_line == reply.len) return false;
    var next = after_line;
    const separator = nextLine(reply, &next);
    return indentation(separator) >= listContentColumn(line).? and
        block.isPipeLine(separator) and isTableSeparator(separator);
}

fn indentation(line: []const u8) usize {
    return line.len - text_util.leftTrim(line).len;
}

fn listContentColumn(line: []const u8) ?usize {
    const content = if (block.parseUnorderedList(line)) |item| item.content else if (block.parseOrderedList(line)) |item| item.content else return null;
    return @intFromPtr(content.ptr) - @intFromPtr(line.ptr);
}

fn startsBlock(line: []const u8, reply: []const u8, after_line: usize) bool {
    if (block.parseFootnoteDefinition(line) != null or block.parseCodeFence(line) != null or
        block.parseBlockquote(line) != null or block.parseHeader(line) != null or
        block.isHorizontalRule(line) or listContent(line) != null) return true;
    if (after_line == reply.len) return false;
    var next = after_line;
    const following = nextLine(reply, &next);
    if (block.isSetextCandidate(line) and
        (block.parseSetextUnderline(following) != null or block.definitionMarkerBody(following) != null)) return true;
    return block.isPipeLine(line);
}

fn firstContent(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn isShellLanguage(language: []const u8) bool {
    for ([_][]const u8{ "sh", "shell", "bash", "zsh", "fish" }) |name| {
        if (std.ascii.eqlIgnoreCase(language, name)) return true;
    }
    return false;
}

fn firstCodeLine(content: []const u8, shell: bool) []const u8 {
    var pos: usize = 0;
    while (pos < content.len) {
        const line = firstContent(nextLine(content, &pos));
        if (line.len == 0 or (shell and line[0] == '#')) continue;
        return line;
    }
    return "";
}

fn addCode(alloc: std.mem.Allocator, targets: *std.ArrayList(Target), names: *Names, language: []const u8, content: []const u8) !void {
    const shell = isShellLanguage(language);
    var label = firstCodeLine(content, shell);
    const prompt = language.len == 0 and std.mem.startsWith(u8, label, "$ ");
    if ((prompt or shell) and std.mem.startsWith(u8, label, "$ ")) label = label[2..];
    try add(alloc, targets, names, if (shell or prompt) "cmd" else "code", if (label.len == 0) language else label, content);
}

// Only ASCII letters and digits enter labels; source control bytes cannot reach the terminal.
fn add(alloc: std.mem.Allocator, targets: *std.ArrayList(Target), names: *Names, kind: []const u8, content: []const u8, text: []const u8) !void {
    var buf: [max_name_len]u8 = undefined;
    @memcpy(buf[0..kind.len], kind);
    var len = kind.len;
    var words: usize = 0;
    var in_word = false;
    for (content) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            in_word = false;
            continue;
        }
        if (!in_word) {
            if (words == 4 or len + 2 > buf.len) break;
            buf[len] = '_';
            len += 1;
            words += 1;
            in_word = true;
        }
        if (len == buf.len) break;
        buf[len] = std.ascii.toLower(byte);
        len += 1;
    }
    const base = buf[0..len];
    var candidate: []const u8 = base;
    var suffixed: [max_name_len]u8 = undefined;
    if (names.used.getEntry(base)) |entry| {
        // Every truncated suffix collision shares this prefix, even as digit counts grow.
        const stored = entry.key_ptr.*;
        const group = stored[0..@min(stored.len, suffix_group_len)];
        const next = try names.next_suffix.getOrPut(group);
        if (!next.found_existing) next.value_ptr.* = 2;
        while (true) {
            const number = next.value_ptr.*;
            next.value_ptr.* += 1;
            var digits: [20]u8 = undefined;
            var writer = std.Io.Writer.fixed(&digits);
            try writer.print("{d}", .{number});
            const suffix = writer.buffered();
            const base_len = @min(base.len, max_name_len - suffix.len - 1);
            const prefix = std.mem.trimEnd(u8, base[0..base_len], "_");
            @memcpy(suffixed[0..prefix.len], prefix);
            suffixed[prefix.len] = '_';
            @memcpy(suffixed[prefix.len + 1 ..][0..suffix.len], suffix);
            candidate = suffixed[0 .. prefix.len + 1 + suffix.len];
            if (!names.used.contains(candidate)) break;
        }
    }
    const owned_name = try alloc.dupe(u8, candidate);
    errdefer alloc.free(owned_name);
    const owned_text = try alloc.dupe(u8, text);
    errdefer alloc.free(owned_text);
    try names.used.put(owned_name, {});
    errdefer _ = names.used.remove(owned_name);
    try targets.append(alloc, .{ .name = owned_name, .text = owned_text });
}

// Strip one container layer at a time. The depth cap bounds repeated scanning.
fn unwrapQuote(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    while (pos < source.len) {
        const start = pos;
        const line = nextLine(source, &pos);
        var body = line;
        if (block.parseBlockquote(line) != null) {
            var prefix = indentation(line) + 1;
            if (prefix < line.len and line[prefix] == ' ') prefix += 1;
            body = line[prefix..];
        }
        try out.appendSlice(alloc, body);
        try out.appendSlice(alloc, source[start + line.len .. pos]);
    }
    return out.toOwnedSlice(alloc);
}

fn unwrapFootnote(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    var first = true;
    while (pos < source.len) {
        const start = pos;
        const line = nextLine(source, &pos);
        const body = if (first)
            block.parseFootnoteDefinition(line).?.body
        else
            block.footnoteContinuationBody(line).?;
        first = false;
        try out.appendSlice(alloc, body);
        try out.appendSlice(alloc, source[start + line.len .. pos]);
    }
    return out.toOwnedSlice(alloc);
}

fn unwrapList(alloc: std.mem.Allocator, source: []const u8, base_indent: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < source.len) {
        const start = pos;
        const line = nextLine(source, &pos);
        const item_column = if (indentation(line) == base_indent) listContentColumn(line) else null;
        const body = if (item_column) |next_column| blk: {
            column = next_column;
            break :blk line[column..];
        } else block.stripFenceIndent(line, column);
        try out.appendSlice(alloc, body);
        try out.appendSlice(alloc, source[start + line.len .. pos]);
    }
    return out.toOwnedSlice(alloc);
}

// Remove only Markdown indentation; preserve each original line ending.
fn deindent(alloc: std.mem.Allocator, source: []const u8, indent: usize, indented: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    while (pos < source.len) {
        const start = pos;
        const line = nextLine(source, &pos);
        const body = if (indented and block.hasIndentedCodePrefix(line) and !text_util.isBlankMarkdownLine(line))
            block.deindentCodeLine(line)
        else if (!indented)
            block.stripFenceIndent(line, indent)
        else
            line;
        try out.appendSlice(alloc, body);
        try out.appendSlice(alloc, source[start + line.len .. pos]);
    }
    return out.toOwnedSlice(alloc);
}

// Return the line without its LF or CRLF, while retaining offsets into source.
fn nextLine(source: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
    pos.* = if (end < source.len) end + 1 else end;
    const content_end = if (end < source.len and end > start and source[end - 1] == '\r') end - 1 else end;
    return source[start..content_end];
}

// The renderer buffers consecutive pipe lines before validating the second line.
fn pipeBlock(reply: []const u8, first: []const u8, after_first: usize) struct { end: usize, is_table: bool } {
    var pos = after_first;
    var bytes = first.len + 1;
    var is_table = false;
    var second = true;
    while (pos < reply.len) {
        var next = pos;
        const line = nextLine(reply, &next);
        if (!block.isPipeLine(line) or bytes > ansi.max_pipe_buffer_bytes or
            line.len + 1 > ansi.max_pipe_buffer_bytes - bytes) break;
        if (second) is_table = isTableSeparator(line);
        second = false;
        bytes += line.len + 1;
        pos = next;
    }
    return .{ .end = pos, .is_table = is_table };
}

// Mirrors the private separator check in presentation/block_parse.zig.
fn isTableSeparator(line: []const u8) bool {
    var dash = false;
    var pipe = false;
    for (line) |byte| switch (byte) {
        '-' => dash = true,
        '|' => pipe = true,
        ':', ' ', '\t' => {},
        else => return false,
    };
    return dash and pipe;
}

test "empty replies and newest reply own names and text" {
    const alloc = std.testing.allocator;
    const empty = try collect(alloc, &.{});
    defer free(alloc, empty);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqualStrings("all", empty[0].name);
    try std.testing.expectEqualStrings("", empty[0].text);

    const replies = [_][]const u8{ "newest", "older" };
    const targets = try collect(alloc, &replies);
    defer free(alloc, targets);
    try std.testing.expectEqualStrings("newest", targets[0].text);
    try std.testing.expect(replies[0].ptr != targets[0].text.ptr);
}

test "candidates preserve source and order across replies" {
    const replies = [_][]const u8{
        "intro\r\n| A | B |\r\n| :--- | ---: |\r\n| x | y |\r\n\r\n" ++
            "~~~~ zig\r\n| not | a table |\r\n| --- | --- |\r\n```\r\n~~~~\r\n" ++
            "```\nsecond\n```\n",
        "```\nolder\n```\n| C |\n| - |\n| z |",
    };
    const targets = try collect(std.testing.allocator, &replies);
    defer free(std.testing.allocator, targets);
    const expected = [_]Target{
        .{ .name = "all", .text = replies[0] },
        .{ .name = "paragraph_intro", .text = "intro\r\n" },
        .{ .name = "table_a_b", .text = "| A | B |\r\n| :--- | ---: |\r\n| x | y |\r\n" },
        .{ .name = "code_not_a_table", .text = "| not | a table |\r\n| --- | --- |\r\n```\r\n" },
        .{ .name = "code_second", .text = "second\n" },
        .{ .name = "code_older", .text = "older\n" },
        .{ .name = "table_c", .text = "| C |\n| - |\n| z |" },
    };
    try std.testing.expectEqual(expected.len, targets.len);
    for (expected, targets) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
}

test "incomplete and empty fences retain exact contents" {
    const replies = [_][]const u8{ "```\n```\n~~~\nlast\r\nline", "```" };
    const targets = try collect(std.testing.allocator, &replies);
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 4), targets.len);
    try std.testing.expectEqualStrings("", targets[1].text);
    try std.testing.expectEqualStrings("last\r\nline", targets[2].text);
    try std.testing.expectEqualStrings("", targets[3].text);
}

test "fence closing requires the same marker and a sufficient run" {
    const reply = "  ````lang\n  keep\n```\n~~~~\n````extra\n  `````\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("keep\n```\n~~~~\n````extra\n", targets[1].text);
}

test "table separators and escaped pipes" {
    const reply = "a | b\n--- | :---:\nx\\|y | z\n\n" ++
        "a | b\n--- | nope\n\n" ++
        "a | b\n--- | --- | ---\n\n" ++
        "a\\|b | c\n--- | ---\nrow | x\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 5), targets.len);
    try std.testing.expectEqualStrings("a | b\n--- | :---:\nx\\|y | z\n", targets[1].text);
    try std.testing.expectEqualStrings("paragraph_a_b", targets[2].name);
    try std.testing.expectEqualStrings("table_a_b_2", targets[3].name);
    try std.testing.expectEqualStrings("a\\|b | c\n--- | ---\nrow | x\n", targets[4].text);
}

test "table recognition takes precedence over list or heading markers" {
    const reply = "- A | B\n--- | ---\nrow | value\n\n# C | D\n--- | ---\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    try std.testing.expectEqualStrings("table_a_b", targets[1].name);
    try std.testing.expectEqualStrings("- A | B\n--- | ---\nrow | value\n", targets[1].text);
    try std.testing.expectEqualStrings("table_c_d", targets[2].name);
}

test "pipe blocks follow renderer separator and row rules" {
    const reply = "| A | B |\r\n| --- |\r\n``` | row |\r\n| x | y |\r\n\r\n" ++
        "A\n| - |\n| value |\n\n" ++
        "| first |\n| not separator |\n| later |\n| --- |\n";
    try std.testing.expect(block.isValidTable("| A | B |\n| --- |\n"));
    try std.testing.expect(!block.isPipeLine("A"));
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 5), targets.len);
    try std.testing.expectEqualStrings("table_a_b", targets[1].name);
    try std.testing.expectEqualStrings("| A | B |\r\n| --- |\r\n``` | row |\r\n| x | y |\r\n", targets[1].text);
    try std.testing.expectEqualStrings("paragraph_a", targets[2].name);
    try std.testing.expectEqualStrings("paragraph", targets[3].name);
    try std.testing.expectEqualStrings("paragraph_first", targets[4].name);
    try std.testing.expectEqualStrings("| first |\n| not separator |\n| later |\n| --- |\n", targets[4].text);
}

test "pipe candidates match renderer completion" {
    const presentation = @import("../agent/assistant_presentation.zig");
    const Capture = struct {
        count: usize = 0,
        fn deliver(ctx: *anyopaque, table: presentation.TablePayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            var owned = table;
            owned.deinit(std.testing.allocator);
        }
    };
    const cases = [_][]const u8{
        "| A | B |\n| --- |\n| x | y |\n",
        "A\n| - |\n| value |\n",
        "| A | B |\r\n| --- |\r\n``` | row |\r\n| x | y |\r\n",
        "| first |\n| not separator |\n| later |\n| --- |\n",
    };
    for (cases) |reply| {
        var processor: presentation.MarkdownProcessor = .{};
        defer processor.deinit(std.testing.allocator);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        var capture: Capture = .{};
        const completion: presentation.TableCompletion = .{ .ctx = &capture, .deliver = Capture.deliver };
        try processor.pushWithTableCompletion(std.testing.allocator, reply, &output, &completion);
        try processor.flushWithTableCompletion(std.testing.allocator, &output, &completion);
        const targets = try collect(std.testing.allocator, &.{reply});
        defer free(std.testing.allocator, targets);
        var found: usize = 0;
        for (targets) |target| {
            if (std.mem.eql(u8, target.name, "table") or std.mem.startsWith(u8, target.name, "table_")) found += 1;
        }
        try std.testing.expectEqual(capture.count, found);
    }
}

test "pipe block respects the renderer buffer limit" {
    const alloc = std.testing.allocator;
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(alloc);
    try reply.append(alloc, '|');
    try reply.appendNTimes(alloc, 'x', ansi.max_pipe_buffer_bytes - 9);
    try reply.appendSlice(alloc, "|\n| - |\n| row |\n");
    const targets = try collect(alloc, &.{reply.items});
    defer free(alloc, targets);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    try std.testing.expect(std.mem.startsWith(u8, targets[1].name, "table_"));
    try std.testing.expectEqual(ansi.max_pipe_buffer_bytes, targets[1].text.len);
    try std.testing.expectEqualStrings("| row |\n", targets[2].text);
}

test "nested fences emit owned targets including unclosed and inline openings" {
    const reply = "- ```sh\r\n  echo one\r\n  ```\r\n- next\r\n  ~~~zig\r\n  const x = 1;\r\n\r\nend";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 5), targets.len);
    try std.testing.expectEqualStrings("list_sh", targets[1].name);
    try std.testing.expectEqualStrings("cmd_echo_one", targets[2].name);
    try std.testing.expectEqualStrings("echo one\r\n", targets[2].text);
    try std.testing.expectEqualStrings("code_const_x_1", targets[3].name);
    try std.testing.expectEqualStrings("const x = 1;\r\n\r\n", targets[3].text);
    try std.testing.expectEqualStrings("paragraph_end", targets[4].name);
}

test "fences with pipes keep their contents instead of starting pipe blocks" {
    const reply = "~~~foo | bar\nsecret\n~~~\nafter\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    try std.testing.expectEqualStrings(reply, targets[0].text);
    try std.testing.expectEqualStrings("code_secret", targets[1].name);
    try std.testing.expectEqualStrings("secret\n", targets[1].text);
    try std.testing.expectEqualStrings("paragraph_after", targets[2].name);
}

test "malformed fence and CR-only behavior is explicit against renderer" {
    const presentation = @import("../agent/assistant_presentation.zig");
    const Capture = struct {
        count: usize = 0,
        code: std.ArrayList(u8) = .empty,
        fn deliver(ctx: *anyopaque, payload: presentation.CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.code.appendSlice(std.testing.allocator, payload.code);
            self.count += 1;
            var owned = payload;
            owned.deinit(std.testing.allocator);
        }
    };
    const cases = [_]struct { reply: []const u8, rendered: []const u8, copied: []const u8 }{
        .{ .reply = "```js`bad\nprint(1)\n```\n", .rendered = "print(1)\n", .copied = "print(1)\n" },
        .{ .reply = "~~~\rsecret\r~~~\rafter", .rendered = "", .copied = "" },
        // The renderer gives pipe blocks priority; copying instead honors the opening fence.
        .{ .reply = "~~~foo | bar\nsecret\n~~~\nafter\n", .rendered = "after\n", .copied = "secret\n" },
    };
    for (cases) |case| {
        var processor: presentation.MarkdownProcessor = .{};
        defer processor.deinit(std.testing.allocator);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        var capture: Capture = .{};
        defer capture.code.deinit(std.testing.allocator);
        const completion: presentation.CodeBlockCompletion = .{ .ctx = &capture, .deliver = Capture.deliver };
        try processor.pushWithCompletions(std.testing.allocator, case.reply, &output, .{ .code = &completion });
        try processor.flushWithCompletions(std.testing.allocator, &output, .{ .code = &completion });
        try std.testing.expectEqual(@as(usize, 1), capture.count);
        try std.testing.expectEqualStrings(case.rendered, capture.code.items);
        const targets = try collect(std.testing.allocator, &.{case.reply});
        defer free(std.testing.allocator, targets);
        try std.testing.expectEqualStrings(case.reply, targets[0].text);
        try std.testing.expectEqualStrings(case.copied, targets[1].text);
    }
}

test "targets remain valid after reply storage changes" {
    var reply = "```python\nprint(1)\n```\n".*;
    const targets = try collect(std.testing.allocator, &.{&reply});
    defer free(std.testing.allocator, targets);
    @memset(&reply, 'x');
    try std.testing.expectEqualStrings("```python\nprint(1)\n```\n", targets[0].text);
    try std.testing.expectEqualStrings("print(1)\n", targets[1].text);
}

test "quoted and listed containers expose tables and usable python" {
    const reply = "> > | A | B |\r\n> > | - | - |\r\n> > | x | y |\r\n> >\r\n" ++
        "> > ```python\r\n> > if True:\r\n> >     print(1)\r\n> > ```\r\n\r\n" ++
        "- Parent\n  | H | V |\n  | - | - |\n  | x | y |\n\n" ++
        "  - nested\n    > ```python\n    > if True:\n    >     print(2)\n    > ```\n\n" ++
        "        if True:\n            print(3)\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    const expected = [_]Target{
        .{ .name = "all", .text = reply },
        .{ .name = "quote_a_b", .text = "> > | A | B |\r\n> > | - | - |\r\n> > | x | y |\r\n> >\r\n> > ```python\r\n> > if True:\r\n> >     print(1)\r\n> > ```\r\n" },
        .{ .name = "table_a_b", .text = "| A | B |\r\n| - | - |\r\n| x | y |\r\n" },
        .{ .name = "code_if_true", .text = "if True:\r\n    print(1)\r\n" },
        .{ .name = "list_parent", .text = "- Parent\n  | H | V |\n  | - | - |\n  | x | y |\n\n  - nested\n    > ```python\n    > if True:\n    >     print(2)\n    > ```\n\n        if True:\n            print(3)\n" },
        .{ .name = "table_h_v", .text = "| H | V |\n| - | - |\n| x | y |\n" },
        .{ .name = "list_nested", .text = "- nested\n  > ```python\n  > if True:\n  >     print(2)\n  > ```\n\n      if True:\n          print(3)\n" },
        .{ .name = "code_if_true_2", .text = "if True:\n    print(2)\n" },
        .{ .name = "code_if_true_3", .text = "if True:\n    print(3)\n" },
    };
    try std.testing.expectEqual(expected.len, targets.len);
    for (expected, targets) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
}

test "inline list tables and quotes nested in lists are separate targets" {
    const reply = "- | Name | Value |\n  | --- | --- |\n  | x | y |\n\n" ++
        "- > ~~~python | info\n  > if True:\n  >     print(1)\n  > ~~~\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqualStrings(reply, targets[0].text);
    try std.testing.expectEqual(@as(usize, 4), targets.len);
    try std.testing.expectEqualStrings("table_name_value", targets[2].name);
    try std.testing.expectEqualStrings("| Name | Value |\n| --- | --- |\n| x | y |\n", targets[2].text);
    try std.testing.expectEqualStrings("code_if_true", targets[3].name);
    try std.testing.expectEqualStrings("if True:\n    print(1)\n", targets[3].text);
}

test "list-first borderless tables and quoted pipe fences are nested blocks" {
    const replies = [_][]const u8{
        "- A | B\n  --- | ---\n  x | y\n",
        "- > ~~~python | info\n  > print(1)\n  > ~~~\n",
    };
    const targets = try collect(std.testing.allocator, &replies);
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 5), targets.len);
    try std.testing.expectEqualStrings("list_a_b", targets[1].name);
    try std.testing.expectEqualStrings("table_a_b", targets[2].name);
    try std.testing.expectEqualStrings("A | B\n--- | ---\nx | y\n", targets[2].text);
    try std.testing.expectEqualStrings("code_print_1", targets[4].name);
    try std.testing.expectEqualStrings("print(1)\n", targets[4].text);
}

test "indented code removes markdown indentation but keeps python nesting" {
    const reply = "    if True:\r\n        print(1)\r\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqualStrings(reply, targets[0].text);
    try std.testing.expectEqualStrings("if True:\r\n    print(1)\r\n", targets[1].text);
}

test "nested quote depth is bounded" {
    const alloc = std.testing.allocator;
    for ([_]usize{ max_nesting, max_nesting + 1, 200 }) |depth| {
        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(alloc);
        for ([_][]const u8{ "```\n", "hello\n", "```\n" }) |line| {
            for (0..depth) |_| try reply.appendSlice(alloc, "> ");
            try reply.appendSlice(alloc, line);
        }
        const targets = try collect(alloc, &.{reply.items});
        defer free(alloc, targets);
        try std.testing.expectEqualStrings(reply.items, targets[0].text);
        try std.testing.expectEqual(@as(usize, if (depth <= max_nesting) 3 else 2), targets.len);
        if (depth <= max_nesting) try std.testing.expectEqualStrings("hello\n", targets[2].text);
    }
}

test "unquoted prose cannot continue an open quoted fence" {
    const reply = "> ```sh\n> echo quoted\noutside paragraph\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 4), targets.len);
    try std.testing.expectEqualStrings("> ```sh\n> echo quoted\n", targets[1].text);
    try std.testing.expectEqualStrings("cmd_echo_quoted", targets[2].name);
    try std.testing.expectEqualStrings("echo quoted\n", targets[2].text);
    try std.testing.expectEqualStrings("paragraph_outside_paragraph", targets[3].name);
    try std.testing.expectEqualStrings("outside paragraph\n", targets[3].text);
}

test "quoted fences stop lazy prose without breaking pipe rows or quoted paragraphs" {
    const reply = "> before\nlazy prose\n\n" ++
        "> ```sh\n> echo a\n> ```\n> after\nlazy after\n\n" ++
        "> | h |\n> | - |\n> ``` | row |\n> | end |\noutside\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 7), targets.len);
    try std.testing.expectEqualStrings("> before\nlazy prose\n", targets[1].text);
    try std.testing.expectEqualStrings("> ```sh\n> echo a\n> ```\n> after\nlazy after\n", targets[2].text);
    try std.testing.expectEqualStrings("cmd_echo_a", targets[3].name);
    try std.testing.expectEqualStrings("table_h", targets[5].name);
    try std.testing.expectEqualStrings("| h |\n| - |\n``` | row |\n| end |\n", targets[5].text);
    try std.testing.expectEqualStrings("paragraph_outside", targets[6].name);
}

test "a shorter quoted fence does not close the open fence" {
    const reply = "> ~~~~sh\r\n> echo yes\r\n> ~~~\r\noutside\r\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 4), targets.len);
    try std.testing.expectEqualStrings("cmd_echo_yes", targets[2].name);
    try std.testing.expectEqualStrings("echo yes\r\n~~~\r\n", targets[2].text);
    try std.testing.expectEqualStrings("paragraph_outside", targets[3].name);
}

test "a quoted list fence cannot consume unquoted prose" {
    const reply = "> - ```sh\n>   echo quoted\noutside\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 5), targets.len);
    try std.testing.expectEqualStrings("list_sh", targets[2].name);
    try std.testing.expectEqualStrings("cmd_echo_quoted", targets[3].name);
    try std.testing.expectEqualStrings("echo quoted\n", targets[3].text);
    try std.testing.expectEqualStrings("paragraph_outside", targets[4].name);
}

test "nested headings and lists receive distinct targets" {
    const reply = "> # Project\n> - Parent\n>   - Child\n>\n> Nested title\n> ===\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    const expected = [_]Target{
        .{ .name = "all", .text = reply },
        .{ .name = "quote_project", .text = reply },
        .{ .name = "heading_project", .text = "# Project\n" },
        .{ .name = "list_parent", .text = "- Parent\n  - Child\n" },
        .{ .name = "list_child", .text = "- Child\n" },
        .{ .name = "heading_nested_title", .text = "Nested title\n===\n" },
    };
    try std.testing.expectEqual(expected.len, targets.len);
    for (expected, targets) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
}

test "footnote definitions expose nested fences" {
    const reply = "[^note]: explanation\r\n  ```python\r\n  if True:\r\n      print(1)\r\n  ```\r\noutside\r\n" ++
        "\r\n[^cmd]: ```sh\n  echo yes\n  ```\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    const expected = [_]Target{
        .{ .name = "all", .text = reply },
        .{ .name = "footnote_note", .text = "[^note]: explanation\r\n  ```python\r\n  if True:\r\n      print(1)\r\n  ```\r\n" },
        .{ .name = "code_if_true", .text = "if True:\r\n    print(1)\r\n" },
        .{ .name = "paragraph_outside", .text = "outside\r\n" },
        .{ .name = "footnote_cmd", .text = "[^cmd]: ```sh\n  echo yes\n  ```\n" },
        .{ .name = "cmd_echo_yes", .text = "echo yes\n" },
    };
    try std.testing.expectEqual(expected.len, targets.len);
    for (expected, targets) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
}

test "footnote bodies expose nested headings and lists" {
    const reply = "[^n]: # Note\n  - one\n  - two\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 4), targets.len);
    try std.testing.expectEqualStrings("footnote_n", targets[1].name);
    try std.testing.expectEqualStrings("heading_note", targets[2].name);
    try std.testing.expectEqualStrings("# Note\n", targets[2].text);
    try std.testing.expectEqualStrings("list_one", targets[3].name);
    try std.testing.expectEqualStrings("- one\n- two\n", targets[3].text);
}

test "footnotes nested in quotes expose fences" {
    const reply = "> [^nested]: Example\n>   ```zig\n>   const x = 1;\n>   ```\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    try std.testing.expectEqualStrings("code_const_x_1", targets[2].name);
    try std.testing.expectEqualStrings("const x = 1;\n", targets[2].text);
}

test "allocation failures release names and the target slice" {
    const Case = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const targets = try collect(alloc, &.{"```\ncode\n```\n```\ncode\n```\n| a |\n| - |\n> quote\n\n- list\n  > ```\n  > nested\n  > ```\n\n  | h |\n  | - |\n\n[^note]: example\n  ```\n  code\n  ```\n"});
            defer free(alloc, targets);
        }
    };
    try std.testing.checkAllAllocationFailures(@import("../shared/testing_allocator.zig").no_resize, Case.run, .{});
}

test "no alphabetic limit and tables inside fences stay hidden" {
    const alloc = std.testing.allocator;
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(alloc);
    for (0..30) |_| try reply.appendSlice(alloc, "```\n| hidden |\n| --- |\n```\n");
    for (0..30) |_| try reply.appendSlice(alloc, "| h |\n| - |\n\n");
    const targets = try collect(alloc, &.{reply.items});
    defer free(alloc, targets);
    try std.testing.expectEqual(@as(usize, 61), targets.len);
    try std.testing.expectEqualStrings("code_hidden_30", targets[30].name);
    try std.testing.expectEqualStrings("table_h", targets[31].name);
    try std.testing.expectEqualStrings("table_h_30", targets[60].name);
}

test "commands require a shell language or an unlabelled prompt" {
    const reply = "```bash\n# comment\nfind . -name '*.zig'\n```\n" ++
        "```\n$ find . -name '*.zig'\n```\n" ++
        "```python\nfind . -name '*.zig'\n```\n" ++
        "```\nfind . -name '*.zig'\n```\n" ++
        "```python\n$ echo hi\n```\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 6), targets.len);
    try std.testing.expectEqualStrings("cmd_find_name_zig", targets[1].name);
    try std.testing.expectEqualStrings("cmd_find_name_zig_2", targets[2].name);
    try std.testing.expectEqualStrings("code_find_name_zig", targets[3].name);
    try std.testing.expectEqualStrings("code_find_name_zig_2", targets[4].name);
    try std.testing.expectEqualStrings("code_echo_hi", targets[5].name);
}

test "three replies extract owned targets in appearance order" {
    const replies = [_][]const u8{
        "> Once upon a time...\r\n> the end\r\n\r\n| A | B | C |\r\n| - | - | - |\r\n| 1 | 2 | 3 |\r\n",
        "# Second heading\n\n- [x] One item\n- Two items\n\n    indented code\n    more code\n",
        "Older heading\n---\n\n> Old quote\ncontinued lazily\n\n```sh\nfind . -name ...\n```",
    };
    const targets = try collect(std.testing.allocator, &replies);
    defer free(std.testing.allocator, targets);
    const expected = [_]Target{
        .{ .name = "all", .text = replies[0] },
        .{ .name = "quote_once_upon_a_time", .text = "> Once upon a time...\r\n> the end\r\n" },
        .{ .name = "table_a_b_c", .text = "| A | B | C |\r\n| - | - | - |\r\n| 1 | 2 | 3 |\r\n" },
        .{ .name = "heading_second_heading", .text = "# Second heading\n" },
        .{ .name = "list_one_item", .text = "- [x] One item\n- Two items\n\n    indented code\n    more code\n" },
        .{ .name = "heading_older_heading", .text = "Older heading\n---\n" },
        .{ .name = "quote_old_quote", .text = "> Old quote\ncontinued lazily\n" },
        .{ .name = "cmd_find_name", .text = "find . -name ...\n" },
    };
    try std.testing.expectEqual(expected.len, targets.len);
    for (expected, targets) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
}

test "paragraphs definitions footnotes and thematic breaks use block boundaries" {
    const reply = "First paragraph\r\ncontinues here\r\nTerm\r\n: first\r\n: second\r\n" ++
        "```\r\ncode\r\n```\r\n: orphan\r\n\r\n" ++
        "[^id]: footnote body\r\n  continuation\r\n\tlast\r\n" ++
        "After footnote\r\n\r\n***\r\n\r\n***\r\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    const expected = [_]Target{
        .{ .name = "all", .text = reply },
        .{ .name = "paragraph_first_paragraph", .text = "First paragraph\r\ncontinues here\r\n" },
        .{ .name = "definition_term", .text = "Term\r\n: first\r\n: second\r\n" },
        .{ .name = "code_code", .text = "code\r\n" },
        .{ .name = "paragraph_orphan", .text = ": orphan\r\n" },
        .{ .name = "footnote_id", .text = "[^id]: footnote body\r\n  continuation\r\n\tlast\r\n" },
        .{ .name = "paragraph_after_footnote", .text = "After footnote\r\n" },
        .{ .name = "thematic_break", .text = "***\r\n" },
        .{ .name = "thematic_break_2", .text = "***\r\n" },
    };
    try std.testing.expectEqual(expected.len, targets.len);
    for (expected, targets) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.text, got.text);
    }
}

test "list retains nested items continuation blanks and nested fences" {
    const list = "1. Start\n   continuation\n   - nested\n     nested text\n\n" ++
        "     ```sh\n     echo hello\n     ```\n   ```sh\n   echo parent\n   ```\n\n2. Next\nlazy continuation\n";
    const reply = list ++ "\nOutside paragraph\n\n    standalone code\n    second line\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    try std.testing.expectEqual(@as(usize, 7), targets.len);
    try std.testing.expectEqualStrings("list_start", targets[1].name);
    try std.testing.expectEqualStrings(list, targets[1].text);
    try std.testing.expectEqualStrings("list_nested", targets[2].name);
    try std.testing.expectEqualStrings("- nested\n  nested text\n\n  ```sh\n  echo hello\n  ```\n", targets[2].text);
    try std.testing.expectEqualStrings("cmd_echo_hello", targets[3].name);
    try std.testing.expectEqualStrings("echo hello\n", targets[3].text);
    try std.testing.expectEqualStrings("cmd_echo_parent", targets[4].name);
    try std.testing.expectEqualStrings("echo parent\n", targets[4].text);
    try std.testing.expectEqualStrings("paragraph_outside_paragraph", targets[5].name);
    try std.testing.expectEqualStrings("code_standalone_code", targets[6].name);
    try std.testing.expectEqualStrings("standalone code\nsecond line\n", targets[6].text);
}

test "truncated names share a collision counter" {
    const alloc = std.testing.allocator;
    var targets: std.ArrayList(Target) = .empty;
    var names: Names = .{ .used = .init(alloc), .next_suffix = .init(alloc) };
    defer {
        names.next_suffix.deinit();
        names.used.deinit();
        for (targets.items) |target| {
            alloc.free(target.name);
            alloc.free(target.text);
        }
        targets.deinit(alloc);
    }
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var content: [42]u8 = undefined;
    @memset(content[0..40], 'a');
    for (0..1000) |i| {
        content[40] = digits[i / digits.len];
        content[41] = digits[i % digits.len];
        try add(alloc, &targets, &names, "quote", &content, "");
        try add(alloc, &targets, &names, "quote", &content, "");
    }
    try std.testing.expectEqual(@as(usize, 2000), targets.items.len);
    const group = targets.items[0].name[0..suffix_group_len];
    try std.testing.expectEqual(@as(?usize, 1002), names.next_suffix.get(group));
    try std.testing.expect(std.mem.endsWith(u8, targets.items[1999].name, "_1001"));
}

test "names are bounded safe and collision suffixes do not shadow content" {
    const reply = "> \x1b]0;danger\x07 Once\n\n> \xe2\x98\x83\n\n> \xe2\x98\x83\n\n" ++
        "> abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n\n" ++
        "> abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n\n" ++
        "> a\n\n> a 2\n\n> a\n";
    const targets = try collect(std.testing.allocator, &.{reply});
    defer free(std.testing.allocator, targets);
    for (targets) |target| {
        try std.testing.expect(target.name.len <= max_name_len);
        for (target.name) |byte| try std.testing.expect(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_');
    }
    try std.testing.expectEqualStrings("quote", targets[2].name);
    try std.testing.expectEqualStrings("quote_2", targets[3].name);
    try std.testing.expectEqual(@as(usize, max_name_len), targets[4].name.len);
    try std.testing.expectEqual(@as(usize, max_name_len), targets[5].name.len);
    try std.testing.expectEqualStrings("quote_a", targets[6].name);
    try std.testing.expectEqualStrings("quote_a_2", targets[7].name);
    try std.testing.expectEqualStrings("quote_a_3", targets[8].name);
}

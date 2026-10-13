const std = @import("std");
const tu = @import("text_util.zig");

pub const CodeFence = struct {
    marker: u8,
    /// Number of marker characters in the run; a closing fence needs at least this many.
    run: usize,
    /// Leading spaces before the fence, stripped from the block's code lines.
    indent: usize,
};

/// Parses an opening or closing fence of three or more backticks or tildes,
/// allowing any leading spaces so fences inside list items are recognized.
pub fn parseCodeFence(line: []const u8) ?CodeFence {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const indent = i;
    if (i >= line.len) return null;
    const marker = line[i];
    if (marker != '`' and marker != '~') return null;
    var run: usize = 0;
    while (i < line.len and line[i] == marker) : (i += 1) run += 1;
    if (run < 3) return null;
    return .{ .marker = marker, .run = run, .indent = indent };
}

pub fn codeFenceMarker(line: []const u8) ?u8 {
    const fence = parseCodeFence(line) orelse return null;
    return fence.marker;
}

/// True when `line` closes a block opened by `open`: same marker, a run at
/// least as long, and nothing but whitespace after it.
pub fn closesCodeFence(line: []const u8, open: CodeFence) bool {
    const fence = parseCodeFence(line) orelse return false;
    if (fence.marker != open.marker or fence.run < open.run) return false;
    return tu.isBlankMarkdownLine(line[fence.indent + fence.run ..]);
}

fn isCodeFence(line: []const u8) bool {
    return codeFenceMarker(line) != null;
}

pub fn codeFenceLanguage(line: []const u8) []const u8 {
    const fence = parseCodeFence(line) orelse return "";
    const info = std.mem.trim(u8, line[fence.indent + fence.run ..], " \t");
    const end = std.mem.findAny(u8, info, " \t") orelse info.len;
    return info[0..end];
}

/// Strips up to `indent` leading spaces or tabs so code inside an indented
/// list item renders flush with the fence.
pub fn stripFenceIndent(line: []const u8, indent: usize) []const u8 {
    var i: usize = 0;
    while (i < line.len and i < indent and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[i..];
}

pub fn hasIndentedCodePrefix(line: []const u8) bool {
    return line.len > 0 and (line[0] == '\t' or (line.len >= 4 and std.mem.eql(u8, line[0..4], "    ")));
}

pub fn deindentCodeLine(line: []const u8) []const u8 {
    if (line[0] == '\t') return line[1..];
    return line[4..];
}

const ParsedHeader = struct {
    level: usize,
    content: []const u8,
};

/// ATX heading: up to three leading spaces, one to six `#`, a space, then
/// content with any closing `#` run removed.
pub fn parseHeader(line: []const u8) ?ParsedHeader {
    var start: usize = 0;
    while (start < 3 and start < line.len and line[start] == ' ') : (start += 1) {}
    var level: usize = 0;
    while (level < 6 and start + level < line.len and line[start + level] == '#') : (level += 1) {}
    if (level == 0) return null;
    const marker_end = start + level;
    if (marker_end >= line.len or line[marker_end] != ' ') return null;
    return .{ .level = level, .content = withoutClosingHashes(line[marker_end + 1 ..]) };
}

fn withoutClosingHashes(content: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, content, " \t");
    var end = trimmed.len;
    while (end > 0 and trimmed[end - 1] == '#') : (end -= 1) {}
    if (end == trimmed.len) return content;
    if (end == 0) return trimmed[0..0];
    if (trimmed[end - 1] != ' ' and trimmed[end - 1] != '\t') return content;
    return std.mem.trimEnd(u8, trimmed[0..end], " \t");
}

pub fn parseSetextUnderline(line: []const u8) ?usize {
    var level: ?usize = null;
    for (line) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        const next_level: usize = switch (byte) {
            '=' => 1,
            '-' => 2,
            else => return null,
        };
        if (level) |existing| {
            if (existing != next_level) return null;
        } else {
            level = next_level;
        }
    }
    return level;
}

pub fn isSetextCandidate(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == ':') return false;
    if (parseHeader(line) != null or parseBlockquote(line) != null) return false;
    if (parseUnorderedList(line) != null or parseOrderedList(line) != null) return false;
    return !isCodeFence(line) and
        !isPipeLine(line) and
        !isHorizontalRule(line) and
        parseSetextUnderline(line) == null;
}

pub fn definitionMarkerBody(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != ':') return null;
    var body_start: usize = 1;
    while (body_start < line.len and (line[body_start] == ' ' or line[body_start] == '\t')) : (body_start += 1) {}
    if (body_start == 1 or body_start == line.len) return null;
    return line[body_start..];
}

pub const ParsedFootnoteDefinition = struct {
    label: []const u8,
    body: []const u8,
};

pub fn parseFootnoteDefinition(line: []const u8) ?ParsedFootnoteDefinition {
    if (line.len < 6 or line[0] != '[' or line[1] != '^') return null;
    const close = std.mem.findScalarPos(u8, line, 2, ']') orelse return null;
    if (close == 2 or close + 1 >= line.len or line[close + 1] != ':') return null;

    var body_start = close + 2;
    while (body_start < line.len and (line[body_start] == ' ' or line[body_start] == '\t')) : (body_start += 1) {}
    if (body_start == line.len) return null;
    return .{ .label = line[2..close], .body = line[body_start..] };
}

pub fn footnoteContinuationBody(line: []const u8) ?[]const u8 {
    if (line.len > 0 and line[0] == '\t') return line[1..];
    if (line.len >= 2 and line[0] == ' ' and line[1] == ' ') return line[2..];
    return null;
}

const ParsedBlockquote = struct {
    indent: []const u8,
    depth: usize,
    content: []const u8,
};

pub const BlockquotePrefix = struct {
    indent: usize,
    depth: usize,
};

pub fn parseBlockquote(line: []const u8) ?ParsedBlockquote {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const indent_end = i;
    if (i == line.len or line[i] != '>') return null;
    i += 1;
    if (i == line.len) return .{ .indent = line[0..indent_end], .depth = 1, .content = line[i..] };
    if (line[i] != ' ') return null;
    i += 1;

    var depth: usize = 1;
    while (i < line.len and line[i] == '>') {
        const after_marker = i + 1;
        if (after_marker < line.len and line[after_marker] != ' ') break;
        depth += 1;
        i = after_marker;
        if (i == line.len) break;
        i += 1;
    }
    return .{ .indent = line[0..indent_end], .depth = depth, .content = line[i..] };
}

pub fn isBlockquoteParagraph(line: []const u8) bool {
    return isLazyBlockquoteContinuation(line);
}

pub fn isLazyBlockquoteContinuation(line: []const u8) bool {
    if (std.mem.trim(u8, line, " \t").len == 0) return false;
    if (parseBlockquote(line) != null or parseHeader(line) != null) return false;
    if (parseUnorderedList(line) != null or parseOrderedList(line) != null) return false;
    return codeFenceMarker(tu.leftTrim(line)) == null and
        !isPipeLine(line) and
        !isHorizontalRule(line);
}

const ParsedUnorderedList = struct {
    indent: []const u8,
    content: []const u8,
};

/// Accepts Markdown `-`, `*`, and `+` markers plus a literal bullet so model
/// output that already uses `•` gets the same styling and wrap continuation.
pub fn parseUnorderedList(line: []const u8) ?ParsedUnorderedList {
    const literal_bullet = "\xe2\x80\xa2";
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const rest = line[i..];
    const marker_len: usize = if (rest.len > 0 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+'))
        1
    else if (std.mem.startsWith(u8, rest, literal_bullet))
        literal_bullet.len
    else
        return null;
    if (marker_len >= rest.len or !tu.isSpace(rest[marker_len])) return null;
    return .{ .indent = line[0..i], .content = rest[marker_len + 1 ..] };
}

const ParsedOrderedList = struct {
    indent: []const u8,
    marker: []const u8,
    content: []const u8,
};

pub fn parseOrderedList(line: []const u8) ?ParsedOrderedList {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const indent_end = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == indent_end or i - indent_end > 9) return null;
    if (i + 1 >= line.len) return null;
    if (line[i] != '.' and line[i] != ')') return null;
    if (!tu.isSpace(line[i + 1])) return null;
    return .{
        .indent = line[0..indent_end],
        .marker = line[indent_end .. i + 1],
        .content = line[i + 2 ..],
    };
}

pub const ParsedTaskListItem = struct {
    completed: bool,
    has_separator: bool,
    content: []const u8,
};

pub fn parseTaskListItem(content: []const u8) ?ParsedTaskListItem {
    if (content.len < 3 or content[0] != '[' or content[2] != ']') return null;
    const completed = switch (content[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (content.len == 3) {
        return .{ .completed = completed, .has_separator = false, .content = content[3..] };
    }
    if (content[3] != ' ') return null;
    return .{ .completed = completed, .has_separator = true, .content = content[4..] };
}

pub fn isHorizontalRule(line: []const u8) bool {
    const trimmed = tu.leftTrim(line);
    if (trimmed.len < 3) return false;
    const rule_char = trimmed[0];
    if (rule_char != '-' and rule_char != '*' and rule_char != '_') return false;
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == rule_char) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

pub fn isPipeLine(line: []const u8) bool {
    const trimmed = tu.leftTrim(line);
    if (trimmed.len == 0) return false;
    for (trimmed, 0..) |byte, index| {
        if (byte == '|' and !tu.isEscapedPunctuationAt(trimmed, index)) return true;
    }
    return false;
}

fn isSeparatorLine(line: []const u8) bool {
    const trimmed = tu.leftTrim(line);
    if (trimmed.len == 0) return false;
    var seen_dash = false;
    var seen_pipe = false;
    for (trimmed) |c| {
        switch (c) {
            '|' => seen_pipe = true,
            ':', ' ', '\t' => {},
            '-' => seen_dash = true,
            else => return false,
        }
    }
    return seen_dash and seen_pipe;
}

pub fn isValidTable(buf: []const u8) bool {
    var line_count: usize = 0;
    var saw_separator = false;
    var start: usize = 0;
    while (start < buf.len) {
        const end = std.mem.findScalarPos(u8, buf, start, '\n') orelse buf.len;
        const line = buf[start..end];
        if (line_count == 1 and isSeparatorLine(line)) saw_separator = true;
        line_count += 1;
        start = end + 1;
    }
    return line_count >= 2 and saw_separator;
}

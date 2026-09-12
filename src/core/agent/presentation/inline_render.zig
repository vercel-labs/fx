const std = @import("std");
const Allocator = std.mem.Allocator;
const ansi = @import("ansi.zig");
const string_pool = @import("../../shared/comptime_string_pool.zig");
const tu = @import("text_util.zig");
const unicode_classes = @import("unicode_classes.zig");
const payload = @import("payload.zig");

/// Renders heading content: emphasis is resolved normally, but bold tags are
/// suppressed because the heading style already owns bold.
pub fn writeInlineNoBold(
    alloc: Allocator,
    text: []const u8,
    out: *std.ArrayList(u8),
    restore_underline_after_link: bool,
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    try renderInline(alloc, text, out, .{
        .restore_underline_after_link = restore_underline_after_link,
        .suppress_bold = true,
    }, footnotes, link_id);
}

pub fn writeInline(
    alloc: Allocator,
    text: []const u8,
    out: *std.ArrayList(u8),
    restore_underline_after_link: bool,
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    try renderInline(alloc, text, out, .{
        .restore_underline_after_link = restore_underline_after_link,
    }, footnotes, link_id);
}

const InlineOptions = struct {
    restore_underline_after_link: bool = false,
    suppress_bold: bool = false,
};

/// Inline rendering runs in three passes over one line:
///
/// 1. Tokenize. Escapes, entities, code spans, links, images, autolinks,
///    footnotes, and bare URLs become atomic tokens; runs of `*`, `_`, and
///    `~~` become delimiter tokens whose ability to open or close is decided
///    once from the bytes around them.
/// 2. Match delimiters with the CommonMark delimiter stack, so every span is
///    a real pair and unmatched runs fall out as literal text without any
///    lookahead or state dependent rescanning.
/// 3. Emit ANSI, tracking nesting depth so closing an inner span re-opens an
///    outer span of the same style.
fn renderInline(
    alloc: Allocator,
    text: []const u8,
    out: *std.ArrayList(u8),
    options: InlineOptions,
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(alloc);
    try tokenize(alloc, text, &tokens, footnotes);

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(alloc);
    try matchDelimiters(alloc, tokens.items, &matches);

    try emitTokens(alloc, text, tokens.items, matches.items, out, options, link_id);
}

const Style = enum { bold, italic, strike };

const Delimiter = struct {
    marker: u8,
    start: usize,
    orig_len: usize,
    remaining: usize,
    can_open: bool,
    can_close: bool,
    /// Matches this run opens, newest first, so emission in list order puts
    /// the outermost span first.
    open_head: ?u32 = null,
    /// Matches this run closes, oldest first, so the innermost span closes
    /// first.
    close_head: ?u32 = null,
    close_tail: ?u32 = null,
};

const Token = union(enum) {
    /// Literal bytes copied from the source line, including the character
    /// produced by a backslash escape.
    text: []const u8,
    entity: DecodedEntity,
    code: []const u8,
    link: struct { link: InlineLink, visible_prefix: ?[]const u8 },
    footnote: usize,
    delimiter: Delimiter,
};

const Match = struct {
    style: Style,
    next_open: ?u32 = null,
    next_close: ?u32 = null,
};

fn tokenize(
    alloc: Allocator,
    text: []const u8,
    tokens: *std.ArrayList(Token),
    footnotes: ?*const payload.FootnoteSink,
) !void {
    var i: usize = 0;
    var literal_start: usize = 0;
    var link_admission_suppressed_until: usize = 0;
    // Every bracket construct starting at `i` ends at the first `]` at or
    // after `i`, so that position is found once and shared: a `[` whose `]`
    // is not followed by `(` cannot be a link or image, and a footnote label
    // ends there too. Without this every `[` in a long run rescans to the
    // same `]`.
    const last_close_bracket = std.mem.lastIndexOfScalar(u8, text, ']');
    var next_close_bracket: ?usize = null;
    // End of the most recent delimiter run that can open emphasis. A bare URL
    // may follow such a run directly, and the tokenizer owns that decision
    // rather than a second flanking rule inside the URL parser.
    var opening_delimiter_end: usize = 0;

    while (i < text.len) {
        const c = text[i];
        const after_opening_delimiter = i > 0 and opening_delimiter_end == i;
        if (last_close_bracket != null and i <= last_close_bracket.? and (next_close_bracket == null or next_close_bracket.? < i)) {
            next_close_bracket = std.mem.indexOfScalarPos(u8, text, i, ']');
        }
        const bracket_link_possible = next_close_bracket != null and next_close_bracket.? >= i and
            next_close_bracket.? + 1 < text.len and text[next_close_bracket.? + 1] == '(';

        if (c == '`') {
            if (codeSpanAt(text, i)) |span| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .code = text[span.content_start..span.content_end] });
                i = span.end;
                literal_start = i;
                continue;
            }
            // A backtick run without a partner is literal text.
            i += backtickRunLength(text, i);
            continue;
        }

        if (c == '&') {
            if (decodeEntity(text, i)) |entity| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .entity = entity });
                i = entity.end;
                literal_start = i;
                continue;
            }
        }

        if (c == '\\' and i + 1 < text.len and tu.isEscapedPunctuationAt(text, i + 1)) {
            try flushLiteral(alloc, text, tokens, literal_start, i);
            if (text[i + 1] == '<') {
                link_admission_suppressed_until = @max(
                    link_admission_suppressed_until,
                    angleAutolinkCandidateEnd(text, i + 1),
                );
            }
            if (bracket_link_possible and text[i + 1] == '!' and i + 2 < text.len and text[i + 2] == '[') {
                if (malformedInlineLinkCandidateEnd(text, i + 2)) |candidate_end| {
                    try tokens.append(alloc, .{ .text = text[i + 1 .. candidate_end] });
                    link_admission_suppressed_until = @max(link_admission_suppressed_until, candidate_end);
                    i = candidate_end;
                    literal_start = i;
                    continue;
                }
            }
            if (bracket_link_possible and text[i + 1] == '[') {
                if (malformedInlineLinkCandidateEnd(text, i + 1)) |candidate_end| {
                    link_admission_suppressed_until = @max(link_admission_suppressed_until, candidate_end);
                }
            }
            try tokens.append(alloc, .{ .text = text[i + 1 .. i + 2] });
            i += 2;
            literal_start = i;
            continue;
        }

        if (bracket_link_possible and i >= link_admission_suppressed_until and c == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseInlineImage(text, i)) |image| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .link = .{ .link = image, .visible_prefix = "▧ " } });
                i = image.end;
                literal_start = i;
                continue;
            }
            if (malformedInlineLinkCandidateEnd(text, i + 1)) |candidate_end| {
                link_admission_suppressed_until = @max(link_admission_suppressed_until, candidate_end);
            }
        }

        if (c == '[' and next_close_bracket != null) {
            if (footnotes) |sink| {
                if (parseFootnoteReference(text, i, next_close_bracket.?)) |reference| {
                    try flushLiteral(alloc, text, tokens, literal_start, i);
                    const number = try sink.register(sink.ctx, alloc, reference.label);
                    try tokens.append(alloc, .{ .footnote = number });
                    i = reference.end;
                    literal_start = i;
                    continue;
                }
            }
        }

        if (bracket_link_possible and i >= link_admission_suppressed_until and c == '[') {
            if (parseInlineLink(text, i)) |link| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .link = .{ .link = link, .visible_prefix = null } });
                i = link.end;
                literal_start = i;
                continue;
            }
            if (malformedInlineLinkCandidateEnd(text, i)) |candidate_end| {
                link_admission_suppressed_until = @max(link_admission_suppressed_until, candidate_end);
            }
        }

        if (i >= link_admission_suppressed_until and c == '<') {
            if (parseAngleAutolink(text, i)) |link| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .link = .{ .link = link, .visible_prefix = null } });
                i = link.end;
                literal_start = i;
                continue;
            }
            link_admission_suppressed_until = @max(
                link_admission_suppressed_until,
                angleAutolinkCandidateEnd(text, i),
            );
        }

        if (i >= link_admission_suppressed_until) {
            if (parseBareUrl(text, i, after_opening_delimiter)) |link| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .link = .{ .link = link, .visible_prefix = null } });
                i = link.end;
                literal_start = i;
                continue;
            }
        }

        if (c == '*' or c == '_' or c == '~') {
            const run_end = markerRunEnd(text, i);
            if (delimiterAt(text, i, run_end)) |delimiter| {
                try flushLiteral(alloc, text, tokens, literal_start, i);
                try tokens.append(alloc, .{ .delimiter = delimiter });
                literal_start = run_end;
                if (delimiter.can_open) opening_delimiter_end = run_end;
            }
            i = run_end;
            continue;
        }

        i += 1;
    }
    try flushLiteral(alloc, text, tokens, literal_start, text.len);
}

fn flushLiteral(alloc: Allocator, text: []const u8, tokens: *std.ArrayList(Token), start: usize, end: usize) !void {
    if (end > start) try tokens.append(alloc, .{ .text = text[start..end] });
}

/// End of the run of `text[i]` bytes starting at `i`.
fn markerRunEnd(text: []const u8, i: usize) usize {
    const marker = text[i];
    var end = i;
    while (end < text.len and text[end] == marker) : (end += 1) {}
    return end;
}

/// Classifies the marker run `text[start..end]` with the CommonMark flanking
/// rules. Returns null for a run that can neither open nor close, or for a
/// tilde run that is not exactly two long, so it stays literal text.
fn delimiterAt(text: []const u8, start: usize, end: usize) ?Delimiter {
    const marker = text[start];
    const len = end - start;
    if (marker == '~' and len != 2) return null;

    const before = codepointBefore(text, start);
    const after = codepointAt(text, end);
    const before_space = isFlankingWhitespace(before);
    const after_space = isFlankingWhitespace(after);
    const before_punct = isFlankingPunctuation(before);
    const after_punct = isFlankingPunctuation(after);

    const left_flanking = !after_space and (!after_punct or before_space or before_punct);
    const right_flanking = !before_space and (!before_punct or after_space or after_punct);

    var can_open = left_flanking;
    var can_close = right_flanking;
    if (marker == '_') {
        // Intraword underscores never delimit, so snake_case stays literal.
        can_open = left_flanking and (!right_flanking or before_punct);
        can_close = right_flanking and (!left_flanking or after_punct);
    }
    if (!can_open and !can_close) return null;
    return .{
        .marker = marker,
        .start = start,
        .orig_len = len,
        .remaining = len,
        .can_open = can_open,
        .can_close = can_close,
    };
}

/// Code point ending just before `index`, or a space at the line start.
fn codepointBefore(text: []const u8, index: usize) u21 {
    if (index == 0) return ' ';
    var start = index - 1;
    var steps: usize = 0;
    while (start > 0 and steps < 3 and text[start] & 0xC0 == 0x80) : (steps += 1) start -= 1;
    return std.unicode.utf8Decode(text[start..index]) catch text[index - 1];
}

/// Code point starting at `index`, or a space at the line end.
fn codepointAt(text: []const u8, index: usize) u21 {
    if (index >= text.len) return ' ';
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return text[index];
    if (index + len > text.len) return text[index];
    return std.unicode.utf8Decode(text[index .. index + len]) catch text[index];
}

fn isFlankingWhitespace(cp: u21) bool {
    return unicode_classes.isWhitespace(cp);
}

fn isFlankingPunctuation(cp: u21) bool {
    return unicode_classes.isPunctuationOrSymbol(cp);
}

/// CommonMark "process emphasis" over an explicit stack of open delimiters.
/// A closer searches the stack from the top for a compatible opener; the pair
/// is recorded and every entry above the opener is popped, since a run
/// between a matched pair can no longer open anything. Each entry is pushed
/// and popped at most once, and `openers_bottom` records, per closer kind,
/// how deep a failed search reached so the same entries are never rescanned
/// for that kind, which keeps the pass linear.
fn matchDelimiters(alloc: Allocator, tokens: []Token, matches: *std.ArrayList(Match)) !void {
    const StackEntry = struct { token: u32, seq: u32 };
    var stack: std.ArrayList(StackEntry) = .empty;
    defer stack.deinit(alloc);
    var next_seq: u32 = 1;
    // Sequence number of the top entry when a search for this closer kind
    // last failed; entries at or below it stay unusable for that kind.
    var openers_bottom: [3][2][3]u32 = .{.{.{ 0, 0, 0 }} ** 2} ** 3;

    for (tokens, 0..) |*token, token_index| {
        const closer = switch (token.*) {
            .delimiter => |*d| d,
            else => continue,
        };

        if (closer.can_close) {
            const bottom = &openers_bottom[markerSlot(closer.marker)][@intFromBool(closer.can_open)][closer.orig_len % 3];
            // Each part of the closer runs its own search: once a match pops
            // the stack, the remainder searches again from the new top, and a
            // failed remainder is cached like any other failed search.
            var matched_in_search = false;
            var depth = stack.items.len;
            while (closer.remaining > 0 and depth > 0) {
                depth -= 1;
                const entry = stack.items[depth];
                if (entry.seq <= bottom.*) break;
                const opener = &tokens[entry.token].delimiter;
                if (opener.marker != closer.marker) continue;
                if (opener.marker != '~' and violatesRuleOfThree(opener.*, closer.*)) continue;

                const use_len: usize = if (opener.marker == '~' or (opener.remaining >= 2 and closer.remaining >= 2)) 2 else 1;
                const style: Style = switch (opener.marker) {
                    '~' => .strike,
                    else => if (use_len == 2) .bold else .italic,
                };
                const match_index: u32 = @intCast(matches.items.len);
                try matches.append(alloc, .{ .style = style, .next_open = opener.open_head });
                opener.open_head = match_index;
                if (closer.close_tail) |tail| {
                    matches.items[tail].next_close = match_index;
                } else {
                    closer.close_head = match_index;
                }
                closer.close_tail = match_index;
                opener.remaining -= use_len;
                closer.remaining -= use_len;

                // Everything above the opener sat between the pair.
                const keep = if (opener.remaining == 0) depth else depth + 1;
                stack.shrinkRetainingCapacity(keep);
                depth = stack.items.len;
                matched_in_search = closer.remaining == 0;
            }
            if (!matched_in_search and stack.items.len > 0) bottom.* = stack.items[stack.items.len - 1].seq;
        }

        if (closer.can_open and closer.remaining > 0) {
            try stack.append(alloc, .{ .token = @intCast(token_index), .seq = next_seq });
            next_seq += 1;
        }
    }
}

fn markerSlot(marker: u8) usize {
    return switch (marker) {
        '*' => 0,
        '_' => 1,
        else => 2,
    };
}

/// A run that can both open and close only pairs with another run when their
/// combined length is not a multiple of three, unless both lengths are.
fn violatesRuleOfThree(opener: Delimiter, closer: Delimiter) bool {
    if (!opener.can_close and !closer.can_open) return false;
    const sum = opener.orig_len + closer.orig_len;
    if (sum % 3 != 0) return false;
    return opener.orig_len % 3 != 0 or closer.orig_len % 3 != 0;
}

fn emitTokens(
    alloc: Allocator,
    text: []const u8,
    tokens: []const Token,
    matches: []const Match,
    out: *std.ArrayList(u8),
    options: InlineOptions,
    link_id: *u32,
) !void {
    var depth: [3]usize = .{ 0, 0, 0 };
    for (tokens) |token| switch (token) {
        .text => |slice| try out.appendSlice(alloc, slice),
        .entity => |entity| try out.appendSlice(alloc, entity.utf8[0..entity.len]),
        .code => |content| {
            try out.appendSlice(alloc, ansi.inline_code_open);
            try out.appendSlice(alloc, content);
            try out.appendSlice(alloc, ansi.inline_code_close);
        },
        .link => |item| try emitInlineLink(alloc, out, item.link, options.restore_underline_after_link, item.visible_prefix, link_id),
        .footnote => |number| try writeFootnoteMarker(alloc, out, number),
        .delimiter => |delimiter| {
            var close = delimiter.close_head;
            while (close) |index| : (close = matches[index].next_close) {
                try emitStyle(alloc, out, matches[index].style, false, &depth, options);
            }
            try out.appendSlice(alloc, text[delimiter.start .. delimiter.start + delimiter.remaining]);
            var open = delimiter.open_head;
            while (open) |index| : (open = matches[index].next_open) {
                try emitStyle(alloc, out, matches[index].style, true, &depth, options);
            }
        },
    };
}

fn emitStyle(alloc: Allocator, out: *std.ArrayList(u8), style: Style, opening: bool, depth: *[3]usize, options: InlineOptions) !void {
    const slot = @intFromEnum(style);
    const open_seq: []const u8 = switch (style) {
        .bold => ansi.bold_open,
        .italic => ansi.italic_open,
        .strike => ansi.strike_open,
    };
    const close_seq: []const u8 = switch (style) {
        .bold => ansi.bold_close,
        .italic => ansi.italic_close,
        .strike => ansi.strike_close,
    };
    const visible = !(style == .bold and options.suppress_bold);
    if (opening) {
        depth[slot] += 1;
        if (visible) try out.appendSlice(alloc, open_seq);
        return;
    }
    depth[slot] -= 1;
    if (!visible) return;
    try out.appendSlice(alloc, close_seq);
    // Closing an inner span must not switch off an enclosing span of the
    // same style.
    if (depth[slot] > 0) try out.appendSlice(alloc, open_seq);
}

const ParsedFootnoteReference = struct {
    label: []const u8,
    end: usize,
};

/// `close` is the first `]` at or after `start`, found by the tokenizer.
fn parseFootnoteReference(text: []const u8, start: usize, close: usize) ?ParsedFootnoteReference {
    if (start + 4 > text.len or text[start] != '[' or text[start + 1] != '^') return null;
    if (close <= start + 2 or close >= text.len or text[close] != ']') return null;
    if (close + 1 < text.len and text[close + 1] == ':') return null;
    return .{ .label = text[start + 2 .. close], .end = close + 1 };
}

fn writeFootnoteMarker(alloc: Allocator, out: *std.ArrayList(u8), number: usize) !void {
    var marker: [32]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&marker, "[{d}]", .{number});
    try ansi.writeDim(alloc, out, bytes);
}

const InlineLink = struct {
    text: []const u8,
    url: []const u8,
    end: usize,
    destination_prefix: []const u8 = "",
    label_mode: enum { escaped, literal } = .escaped,
};

fn emitInlineLink(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    link: InlineLink,
    restore_underline_after_link: bool,
    visible_prefix: ?[]const u8,
    link_id: *u32,
) !void {
    const id = link_id.*;
    link_id.* +%= 1;
    var id_buf: [32]u8 = undefined;
    const open = std.fmt.bufPrint(&id_buf, "\x1b]8;id=fx-{d};", .{id}) catch unreachable;
    try out.appendSlice(alloc, open);
    try out.appendSlice(alloc, link.destination_prefix);
    try out.appendSlice(alloc, link.url);
    try out.appendSlice(alloc, "\x1b\\");
    try out.appendSlice(alloc, ansi.underline_open);
    if (visible_prefix) |prefix| try out.appendSlice(alloc, prefix);
    const visible_text = if (link.text.len == 0 and visible_prefix != null) "image" else link.text;
    switch (link.label_mode) {
        .escaped => try tu.appendEscapedPunctuation(alloc, out, visible_text),
        .literal => try out.appendSlice(alloc, visible_text),
    }
    try out.appendSlice(alloc, ansi.underline_close);
    try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
    if (restore_underline_after_link) try out.appendSlice(alloc, ansi.underline_open);
}

/// Rejects control bytes so a URL cannot terminate its OSC 8 wrapper.
fn parseInlineLink(text: []const u8, start: usize) ?InlineLink {
    return parseInlineBracketDestination(text, start, false);
}

fn parseInlineImage(text: []const u8, start: usize) ?InlineLink {
    if (start + 1 >= text.len or text[start] != '!' or text[start + 1] != '[') return null;
    return parseInlineBracketDestination(text, start + 1, true);
}

fn parseInlineBracketDestination(text: []const u8, start: usize, allow_empty_text: bool) ?InlineLink {
    if (start >= text.len or text[start] != '[') return null;
    var j = start + 1;
    while (j < text.len and text[j] != ']' and text[j] != '\n') : (j += 1) {}
    if (j >= text.len or text[j] != ']') return null;
    const text_end = j;
    if (!allow_empty_text and text_end == start + 1) return null;
    if (text_end + 1 >= text.len or text[text_end + 1] != '(') return null;
    const destination = parseLinkDestination(text, text_end + 2) orelse return null;
    if (!isValidLinkUrl(destination.url)) return null;
    return .{
        .text = text[start + 1 .. text_end],
        .url = destination.url,
        .end = destination.end,
    };
}

const LinkDestination = struct {
    url: []const u8,
    /// Index just past the closing `)`.
    end: usize,
};

/// Parses `(destination "optional title")` starting just after the `(`.
/// The destination is either `<...>` or a run without spaces whose
/// parentheses balance; the title is validated and dropped.
fn parseLinkDestination(text: []const u8, start: usize) ?LinkDestination {
    var k = skipInlineSpaces(text, start);
    if (k >= text.len) return null;

    var url: []const u8 = undefined;
    if (text[k] == '<') {
        const close = std.mem.indexOfScalarPos(u8, text, k + 1, '>') orelse return null;
        url = text[k + 1 .. close];
        for (url) |byte| if (byte == '<' or byte == '\n') return null;
        k = close + 1;
    } else {
        const url_start = k;
        var depth: usize = 0;
        while (k < text.len) : (k += 1) {
            const byte = text[k];
            if (byte == '\\' and k + 1 < text.len) {
                k += 1;
                continue;
            }
            if (byte <= ' ' or byte == 0x7f) break;
            if (byte == '(') {
                depth += 1;
            } else if (byte == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        if (depth != 0 or k == url_start) return null;
        url = text[url_start..k];
    }

    const after_url = k;
    k = skipInlineSpaces(text, k);
    if (k > after_url and k < text.len and text[k] != ')') {
        k = linkTitleEnd(text, k) orelse return null;
        k = skipInlineSpaces(text, k);
    }
    if (k >= text.len or text[k] != ')') return null;
    return .{ .url = url, .end = k + 1 };
}

fn skipInlineSpaces(text: []const u8, start: usize) usize {
    var k = start;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) : (k += 1) {}
    return k;
}

/// Returns the index just past a `"..."`, `'...'`, or `(...)` link title.
fn linkTitleEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    const closer: u8 = switch (text[start]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var k = start + 1;
    while (k < text.len) : (k += 1) {
        if (text[k] == '\\' and k + 1 < text.len) {
            k += 1;
            continue;
        }
        if (text[k] == '\n') return null;
        if (text[k] == closer) return k + 1;
    }
    return null;
}

const CodeSpan = struct {
    content_start: usize,
    content_end: usize,
    /// Index just past the closing backtick run.
    end: usize,
};

fn backtickRunLength(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and text[end] == '`') : (end += 1) {}
    return end - start;
}

/// Finds the code span opened by the backtick run at `start`: the content
/// ends at the next run of exactly the same length. One leading and one
/// trailing space are stripped when both are present and the content is
/// not all spaces.
fn codeSpanAt(text: []const u8, start: usize) ?CodeSpan {
    const run = backtickRunLength(text, start);
    if (run == 0) return null;
    var k = start + run;
    while (k < text.len) {
        if (text[k] != '`') {
            k += 1;
            continue;
        }
        const candidate = backtickRunLength(text, k);
        if (candidate == run) {
            var content_start = start + run;
            var content_end = k;
            const content = text[content_start..content_end];
            if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and
                std.mem.trim(u8, content, " ").len > 0)
            {
                content_start += 1;
                content_end -= 1;
            }
            return .{ .content_start = content_start, .content_end = content_end, .end = k + run };
        }
        k += candidate;
    }
    return null;
}

const DecodedEntity = struct {
    utf8: [4]u8,
    len: usize,
    /// Index just past the terminating `;`.
    end: usize,
};

/// Longest reference body accepted between `&` and `;`: the numeric form
/// `#x10FFFF` is eight characters and every named entity in the table is
/// shorter, so the terminator search never needs to look further.
const max_entity_name_len = 8;

/// Decodes the HTML entities models commonly emit plus numeric references.
const named_entity_strings = [_]struct { name: []const u8, codepoint: u21 }{
    .{ .name = "amp", .codepoint = '&' },
    .{ .name = "lt", .codepoint = '<' },
    .{ .name = "gt", .codepoint = '>' },
    .{ .name = "quot", .codepoint = '"' },
    .{ .name = "apos", .codepoint = '\'' },
    .{ .name = "nbsp", .codepoint = 0xA0 },
    .{ .name = "copy", .codepoint = 0xA9 },
    .{ .name = "reg", .codepoint = 0xAE },
    .{ .name = "hellip", .codepoint = 0x2026 },
    .{ .name = "mdash", .codepoint = 0x2014 },
    .{ .name = "ndash", .codepoint = 0x2013 },
    .{ .name = "larr", .codepoint = 0x2190 },
    .{ .name = "rarr", .codepoint = 0x2192 },
};

const named_entity_pool = string_pool.Interned(blk: {
    var flat: []const []const u8 = &.{};
    for (named_entity_strings) |entry| flat = flat ++ &[1][]const u8{entry.name};
    break :blk flat;
});

const named_entity_entries = blk: {
    var out: [named_entity_strings.len]struct {
        name: named_entity_pool.Ref,
        codepoint: u21,
    } = undefined;
    for (named_entity_strings, 0..) |entry, i| {
        out[i] = .{ .name = named_entity_pool.ref(entry.name), .codepoint = entry.codepoint };
    }
    break :blk out;
};

fn decodeEntity(text: []const u8, start: usize) ?DecodedEntity {
    if (start >= text.len or text[start] != '&') return null;
    // Bound the terminator search so a line full of ampersands stays linear.
    const window_end = @min(text.len, start + 1 + max_entity_name_len + 1);
    const semicolon = std.mem.indexOfScalarPos(u8, text[0..window_end], start + 1, ';') orelse return null;
    const name = text[start + 1 .. semicolon];
    if (name.len == 0) return null;

    var codepoint: u21 = undefined;
    if (name[0] == '#') {
        const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
        const digits = if (hex) name[2..] else name[1..];
        if (digits.len == 0) return null;
        const value = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
        // Control characters would reach the terminal as real control bytes,
        // so the reference stays literal instead of decoding.
        if (value != 0 and (value < 0x20 or (value >= 0x7F and value <= 0x9F))) return null;
        codepoint = if (value == 0 or (value >= 0xD800 and value <= 0xDFFF)) 0xFFFD else value;
    } else {
        codepoint = for (named_entity_entries) |entry| {
            if (std.mem.eql(u8, entry.name.get(), name)) break entry.codepoint;
        } else return null;
    }

    var decoded: DecodedEntity = .{ .utf8 = undefined, .len = 0, .end = semicolon + 1 };
    decoded.len = std.unicode.utf8Encode(codepoint, &decoded.utf8) catch return null;
    return decoded;
}

fn parseAngleAutolink(text: []const u8, start: usize) ?InlineLink {
    if (start >= text.len or text[start] != '<') return null;

    const end = angleAutolinkCandidateEnd(text, start);
    if (end <= start + 1 or end > text.len or text[end - 1] != '>') return null;

    const value = text[start + 1 .. end - 1];
    if (isValidAngleAutolinkUri(value) and isValidLinkUrl(value)) {
        return .{
            .text = value,
            .url = value,
            .end = end,
            .label_mode = .literal,
        };
    }
    if (isValidAngleAutolinkEmail(value) and isValidLinkUrlWithPrefix("mailto:", value)) {
        return .{
            .text = value,
            .url = value,
            .end = end,
            .destination_prefix = "mailto:",
            .label_mode = .literal,
        };
    }
    return null;
}

fn angleAutolinkCandidateEnd(text: []const u8, start: usize) usize {
    if (start >= text.len or text[start] != '<') return start;

    var end = start + 1;
    while (end < text.len and text[end] != '>' and text[end] != '\n') : (end += 1) {}
    return if (end < text.len and text[end] == '>') end + 1 else end;
}

fn isValidAngleAutolinkUri(value: []const u8) bool {
    var colon: usize = 0;
    while (colon < value.len and value[colon] != ':') : (colon += 1) {}
    if (colon < 2 or colon > 32 or colon == value.len or !tu.isAsciiAlpha(value[0])) return false;

    for (value[1..colon]) |byte| {
        if (!tu.isAsciiAlphaNumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    for (value[colon + 1 ..]) |byte| {
        if (byte <= ' ' or byte == '<' or byte == '>') return false;
    }
    return true;
}

fn isValidAngleAutolinkEmail(value: []const u8) bool {
    var at_index: ?usize = null;
    for (value, 0..) |byte, index| {
        if (byte == '@') {
            if (at_index != null) return false;
            at_index = index;
        }
    }

    const at = at_index orelse return false;
    if (at == 0 or at + 1 >= value.len) return false;
    for (value[0..at]) |byte| if (!isAngleAutolinkEmailLocalByte(byte)) return false;

    var label_start = at + 1;
    var index = label_start;
    while (index <= value.len) : (index += 1) {
        if (index != value.len and value[index] != '.') continue;
        if (!isValidAngleAutolinkEmailDomainLabel(value[label_start..index])) return false;
        label_start = index + 1;
    }
    return true;
}

fn isAngleAutolinkEmailLocalByte(byte: u8) bool {
    return tu.isAsciiAlphaNumeric(byte) or switch (byte) {
        '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

fn isValidAngleAutolinkEmailDomainLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 63) return false;
    for (label, 0..) |byte, index| {
        if (index == 0 or index + 1 == label.len) {
            if (!tu.isAsciiAlphaNumeric(byte)) return false;
        } else if (!tu.isAsciiAlphaNumeric(byte) and byte != '-') {
            return false;
        }
    }
    return true;
}

/// Bare URL starting at `start`, or null. The extent does not depend on any
/// emphasis state: it ends at whitespace or a closing bracket, and trailing
/// punctuation, including `*`, `_`, and `~`, is left outside the link the
/// way GFM autolinks do, so a delimiter that follows a URL can still close
/// the span that contains it.
fn parseBareUrl(text: []const u8, start: usize, after_opening_delimiter: bool) ?InlineLink {
    if (!isBareUrlBoundary(text, start, after_opening_delimiter)) return null;
    const scheme_len: usize = if (std.mem.startsWith(u8, text[start..], "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, text[start..], "http://"))
        "http://".len
    else
        return null;

    var end = start + scheme_len;
    while (end < text.len and !isBareUrlTerminator(text[end])) : (end += 1) {}
    while (end > start + scheme_len and isTrailingBareUrlByte(text[end - 1])) : (end -= 1) {}

    const url = text[start..end];
    if (!isValidLinkUrl(url)) return null;
    return .{
        .text = url,
        .url = url,
        .end = end,
    };
}

fn malformedInlineLinkCandidateEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '[') return null;

    var label_end = start + 1;
    while (label_end < text.len and text[label_end] != ']' and text[label_end] != '\n') : (label_end += 1) {}
    if (label_end >= text.len or text[label_end] != ']') return null;
    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;

    var candidate_end = label_end + 2;
    while (candidate_end < text.len and text[candidate_end] != ')' and text[candidate_end] != '\n') : (candidate_end += 1) {}
    if (candidate_end < text.len and text[candidate_end] == ')') return candidate_end + 1;
    return candidate_end;
}

fn isValidLinkUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > ansi.max_link_url_bytes) return false;
    for (url) |b| if (b < 0x20 or b == 0x7f) return false;
    return true;
}

fn isValidLinkUrlWithPrefix(prefix: []const u8, url: []const u8) bool {
    if (prefix.len + url.len > ansi.max_link_url_bytes) return false;
    for (prefix) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return isValidLinkUrl(url);
}

/// A bare URL may start at the line start, directly after a delimiter run
/// that can open emphasis, or after a non word byte other than `<`.
fn isBareUrlBoundary(text: []const u8, start: usize, after_opening_delimiter: bool) bool {
    if (start == 0 or after_opening_delimiter) return true;
    const previous = text[start - 1];
    return !tu.isAsciiWordByte(previous) and previous != '<';
}

fn isBareUrlTerminator(c: u8) bool {
    return tu.isAsciiWhitespace(c) or c == ')' or c == ']' or c == '}' or c == '>';
}

fn isTrailingBareUrlByte(c: u8) bool {
    return tu.isTrailingUrlPunctuation(c) or c == '*' or c == '_' or c == '~';
}

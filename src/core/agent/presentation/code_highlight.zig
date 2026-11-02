const std = @import("std");
const shared_theme = @import("../../shared/theme.zig");
const languages = @import("code_highlight_languages.zig");

const Allocator = std.mem.Allocator;

pub const Theme = enum {
    dark,
    light,
};

const Palette = shared_theme.SyntaxPalette;

const dark_palette: Palette = shared_theme.fx_dark.syntax;
const light_palette: Palette = shared_theme.fx_light.syntax;

fn paletteForTheme(theme: Theme) Palette {
    const active = shared_theme.current();
    // When the requested variant matches the active theme, custom themes
    // contribute their syntax palette; otherwise render the builtin variant.
    if (active.light == (theme == .light)) return active.syntax;
    return switch (theme) {
        .dark => dark_palette,
        .light => light_palette,
    };
}

/// When `base` is set, the span opens with it and every token close restores
/// it, so untokenized text keeps the caller's ambient color. Null leaves plain
/// text at the terminal default, as before.
pub fn highlight(
    alloc: Allocator,
    source: []const u8,
    profile: *const languages.Profile,
    theme: Theme,
    base: ?[]const u8,
) ![]u8 {
    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(alloc);
    const palette = paletteForTheme(theme);
    if (base) |base_style| try styled.appendSlice(alloc, base_style);
    // A theme can disable syntax highlighting entirely; the span then keeps
    // only the caller's base, byte-identical to a token-free source.
    if (!palette.enabled) {
        try styled.appendSlice(alloc, source);
        return styled.toOwnedSlice(alloc);
    }

    var index: usize = 0;
    // Command-position state, used only by command_words profiles (shell):
    // the next word is a command name unless a token says otherwise.
    var command_position = profile.command_words;
    while (index < source.len) {
        const byte = source[index];
        if (byte == '\n') {
            try styled.append(alloc, '\n');
            command_position = profile.command_words;
            index += 1;
            continue;
        }
        if (blockCommentEnd(source, index, profile.block_comment)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end], base);
            command_position = false;
            index = end;
            continue;
        }
        if (lineCommentEnd(source, index, profile.line_comments)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end], base);
            command_position = false;
            index = end;
            continue;
        }
        if (isQuote(byte, profile.quotes)) {
            const end = quotedEnd(source, index);
            if (byte == '"' and profile.dollar_vars) {
                try appendDoubleQuoted(alloc, &styled, palette, source[index..end], base);
            } else {
                try appendStyled(alloc, &styled, palette.string_style, source[index..end], base);
            }
            command_position = false;
            index = end;
            continue;
        }
        if (isNumberStart(source, index)) {
            const end = numberEnd(source, index);
            // Shell: bare number arguments stay plain (a run id is not a
            // literal); only file descriptors glued to a redirect color.
            if (profile.bare_numbers or fdContext(source, index, end)) {
                try appendStyled(alloc, &styled, palette.number_style, source[index..end], base);
            } else {
                try styled.appendSlice(alloc, source[index..end]);
            }
            command_position = false;
            index = end;
            continue;
        }
        if (profile.dollar_vars and byte == '$') {
            // Command substitution reopens command position for its contents.
            if (index + 1 < source.len and source[index + 1] == '(') {
                try appendStyled(alloc, &styled, palette.operator_style, "$(", base);
                command_position = true;
                index += 2;
                continue;
            }
            if (dollarVarEnd(source, index)) |end| {
                try appendStyled(alloc, &styled, palette.variable_style, source[index..end], base);
                command_position = false;
                index = end;
                continue;
            }
        }
        if (profile.dollar_vars and byte == '~' and tildeStart(source, index, profile.operators)) {
            try appendStyled(alloc, &styled, palette.variable_style, "~", base);
            command_position = false;
            index += 1;
            continue;
        }
        if (profile.dash_flags and byte == '-') {
            if (flagEnd(source, index, profile.operators)) |end| {
                try appendStyled(alloc, &styled, palette.number_style, source[index..end], base);
                command_position = false;
                index = end;
                continue;
            }
        }
        if (isOperatorChar(byte, profile.operators)) {
            const end = operatorRunEnd(source, index, profile.operators);
            const run = source[index..end];
            try appendStyled(alloc, &styled, palette.operator_style, run, base);
            // Redirect targets are paths, not commands; `2>&1`-style runs too.
            command_position = std.mem.findScalar(u8, run, '<') == null and
                std.mem.findScalar(u8, run, '>') == null;
            index = end;
            continue;
        }
        if (profile.command_words and byte == '`') {
            // Backticks parse as code; their contents reopen command position.
            try styled.append(alloc, byte);
            command_position = true;
            index += 1;
            continue;
        }
        if (isIdentifierStart(byte)) {
            const end = identifierEnd(source, index);
            const token = source[index..end];
            // A word glued to a path separator is a path segment, not syntax:
            // /dev/null keeps "null" plain.
            const after_separator = index > 0 and source[index - 1] == '/';
            var styled_word = false;
            if (profile.command_words) {
                if (command_position and !after_separator) {
                    // Control keywords read as keywords; other command words
                    // as functions, matching the grammar's scopes.
                    const style = if (inList(token, &command_prefixes, .sensitive))
                        palette.keyword_style
                    else
                        palette.function_style;
                    try appendStyled(alloc, &styled, style, token, base);
                    styled_word = true;
                }
            } else if (!after_separator and (profile.keywords.len > 0 or profile.literals.len > 0)) {
                const token_hash = languages.packedWordHash(token);
                if (inPackedList(token, token_hash, profile.keywords, profile.keyword_case)) {
                    try appendStyled(alloc, &styled, palette.keyword_style, token, base);
                    styled_word = true;
                } else if (inPackedList(token, token_hash, profile.literals, profile.keyword_case)) {
                    try appendStyled(alloc, &styled, palette.number_style, token, base);
                    styled_word = true;
                }
            }
            if (!styled_word) try styled.appendSlice(alloc, token);
            // Control keywords are followed by the command they govern; an
            // ordinary command word is followed by its arguments.
            if (profile.command_words) {
                command_position = styled_word and command_position and
                    inList(token, &command_prefixes, .sensitive);
            }
            index = end;
            continue;
        }
        try styled.append(alloc, byte);
        if (!std.ascii.isWhitespace(byte)) command_position = false;
        index += 1;
    }

    return styled.toOwnedSlice(alloc);
}

/// Control keywords after which the next word is again a command.
const command_prefixes = [_][]const u8{ "if", "then", "elif", "else", "while", "until", "do" };

/// File descriptors glued to a redirect keep the number color when bare
/// number arguments stay plain: the 2 in `2>` and the 1 in `>&1`.
fn fdContext(source: []const u8, start: usize, end: usize) bool {
    if (end < source.len and (source[end] == '>' or source[end] == '<')) return true;
    if (start > 0 and (source[start - 1] == '>' or source[start - 1] == '<')) return true;
    if (start > 1 and source[start - 1] == '&' and (source[start - 2] == '>' or source[start - 2] == '<')) return true;
    return false;
}

/// A tilde opens a home path at a word boundary when a path or name follows.
fn tildeStart(source: []const u8, index: usize, operators: []const u8) bool {
    if (index > 0) {
        const prev = source[index - 1];
        if (!std.ascii.isWhitespace(prev) and !isOperatorChar(prev, operators) and prev != '(' and prev != '`') return false;
    }
    const next = index + 1;
    return next < source.len and
        (source[next] == '/' or isIdentifierStart(source[next]) or std.ascii.isDigit(source[next]));
}

/// Double-quoted spans interpolate in shell: `$name`, `${name}`, and `$(`
/// take the keyword color while the rest keeps the string color.
fn appendDoubleQuoted(alloc: Allocator, out: *std.ArrayList(u8), palette: Palette, text: []const u8, base: ?[]const u8) !void {
    const inner_end = text.len - 1;
    // The opening quote rides the first text chunk so the pair stays one span.
    var chunk_start: usize = 0;
    var i: usize = 1;
    while (i < inner_end) {
        if (text[i] == '$' and (i == 0 or text[i - 1] != '\\')) {
            var var_end: ?usize = null;
            if (i + 1 < inner_end and text[i + 1] == '(') {
                var_end = i + 2;
            } else if (dollarVarEndWithin(text, i, inner_end)) |end| {
                var_end = end;
            }
            if (var_end) |end| {
                if (chunk_start < i) try appendStyled(alloc, out, palette.string_style, text[chunk_start..i], base);
                try appendStyled(alloc, out, palette.variable_style, text[i..end], base);
                i = end;
                chunk_start = end;
                continue;
            }
        }
        i += 1;
    }
    if (chunk_start < inner_end) try appendStyled(alloc, out, palette.string_style, text[chunk_start..inner_end], base);
    try appendStyled(alloc, out, palette.string_style, text[inner_end..], base);
}

fn appendStyled(alloc: Allocator, out: *std.ArrayList(u8), style: []const u8, text: []const u8, base: ?[]const u8) !void {
    try out.appendSlice(alloc, style);
    try out.appendSlice(alloc, text);
    // Close whatever the slot opened: fg-only slots keep the plain reset,
    // themed slots carrying bold/italic get those reset too.
    try out.appendSlice(alloc, shared_theme.closingFor(style));
    if (base) |base_style| try out.appendSlice(alloc, base_style);
}

/// Line-oriented diff painting: `+`/`-` lines take the caller's
/// capability-resolved diff marker colors, `@@` hunks the keyword color, and
/// file metadata lines the comment color. Honors the theme's syntax switch.
pub fn highlightDiff(
    alloc: Allocator,
    source: []const u8,
    theme: Theme,
    added: []const u8,
    removed: []const u8,
) ![]u8 {
    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(alloc);
    const palette = paletteForTheme(theme);
    if (!palette.enabled) {
        try styled.appendSlice(alloc, source);
        return styled.toOwnedSlice(alloc);
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const style: ?[]const u8 = if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---"))
            palette.comment_style
        else if (std.mem.startsWith(u8, line, "+"))
            added
        else if (std.mem.startsWith(u8, line, "-"))
            removed
        else if (std.mem.startsWith(u8, line, "@@"))
            palette.keyword_style
        else if (std.mem.startsWith(u8, line, "diff ") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "new file") or
            std.mem.startsWith(u8, line, "deleted file") or
            std.mem.startsWith(u8, line, "similarity") or
            std.mem.startsWith(u8, line, "rename "))
            palette.comment_style
        else
            null;
        if (style) |line_style| {
            try styled.appendSlice(alloc, line_style);
            try styled.appendSlice(alloc, line);
            try styled.appendSlice(alloc, shared_theme.closingFor(line_style));
        } else {
            try styled.appendSlice(alloc, line);
        }
        if (lines.peek() != null) try styled.append(alloc, '\n');
    }
    return styled.toOwnedSlice(alloc);
}

fn blockCommentEnd(source: []const u8, index: usize, block_comment: ?languages.BlockComment) ?usize {
    const comment = block_comment orelse return null;
    if (!std.mem.startsWith(u8, source[index..], comment.start)) return null;
    const content_start = index + comment.start.len;
    const close_start = std.mem.findPos(u8, source, content_start, comment.end) orelse return source.len;
    return close_start + comment.end.len;
}

fn lineCommentEnd(source: []const u8, index: usize, prefixes: []const []const u8) ?usize {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, source[index..], prefix)) return lineEnd(source, index);
    }
    return null;
}

fn lineEnd(source: []const u8, start: usize) usize {
    return std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
}

fn isQuote(byte: u8, quotes: []const u8) bool {
    return std.mem.findScalar(u8, quotes, byte) != null;
}

fn quotedEnd(source: []const u8, start: usize) usize {
    const quote = source[start];
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\n') return index;
        if (source[index] == '\\' and index + 1 < source.len) {
            index += 1;
            continue;
        }
        if (source[index] == quote) return index + 1;
    }
    return source.len;
}

fn isNumberStart(source: []const u8, index: usize) bool {
    if (!std.ascii.isDigit(source[index])) return false;
    if (index == 0) return true;
    const prev = source[index - 1];
    if (isIdentifierContinue(prev)) return false;
    // A digit run glued to a word by a dash is a name segment, not a number:
    // paths like build-20260918 stay plain while flags like -80 still color.
    if (prev == '-' and index >= 2 and isIdentifierContinue(source[index - 2])) return false;
    return true;
}

fn numberEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '_')) : (index += 1) {}
    return index;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isOperatorChar(byte: u8, operators: []const u8) bool {
    return std.mem.findScalar(u8, operators, byte) != null;
}

fn operatorRunEnd(source: []const u8, start: usize, operators: []const u8) usize {
    var end = start;
    while (end < source.len and isOperatorChar(source[end], operators)) end += 1;
    return end;
}

/// "$" opens a variable when a name, braced name, positional digit, or
/// special parameter follows; a bare "$" stays plain text.
fn dollarVarEnd(source: []const u8, start: usize) ?usize {
    return dollarVarEndWithin(source, start, source.len);
}

fn dollarVarEndWithin(source: []const u8, start: usize, limit: usize) ?usize {
    const next = start + 1;
    if (next >= limit) return null;
    const b = source[next];
    if (b == '{') {
        const close = std.mem.findScalarPos(u8, source, next + 1, '}') orelse return null;
        return if (close < limit) close + 1 else null;
    }
    if (std.ascii.isAlphabetic(b) or b == '_') {
        var end = next;
        while (end < limit and isIdentifierContinue(source[end])) end += 1;
        return end;
    }
    if (std.ascii.isDigit(b) or std.mem.findScalar(u8, "?#@*!$", b) != null) return next + 1;
    return null;
}

/// A dash opens a flag token only at a word boundary (after whitespace, an
/// operator, or the start) with a letter, digit, or second dash next. Dashes
/// inside words, like date suffixes in paths, stay plain.
fn flagEnd(source: []const u8, start: usize, operators: []const u8) ?usize {
    if (start > 0) {
        const prev = source[start - 1];
        if (!std.ascii.isWhitespace(prev) and !isOperatorChar(prev, operators)) return null;
    }
    const next = start + 1;
    if (next >= source.len) return null;
    const b = source[next];
    if (!std.ascii.isAlphanumeric(b) and b != '-') return null;
    var end = next;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '-')) end += 1;
    return end;
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn identifierEnd(source: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < source.len and isIdentifierContinue(source[index])) : (index += 1) {}
    return index;
}

fn inList(token: []const u8, options: []const []const u8, keyword_case: languages.KeywordCase) bool {
    for (options) |option| {
        const matches = switch (keyword_case) {
            .sensitive => std.mem.eql(u8, token, option),
            .ascii_insensitive => std.ascii.eqlIgnoreCase(token, option),
        };
        if (matches) return true;
    }
    return false;
}

fn inPackedList(token: []const u8, target_hash: u32, options: []const u8, keyword_case: languages.KeywordCase) bool {
    var offset: usize = 0;
    while (offset < options.len) {
        const hash = std.mem.readInt(u32, options[offset..][0..@sizeOf(u32)], .little);
        offset += @sizeOf(u32);
        const len = options[offset];
        offset += 1;
        const end = offset + len;
        const option = options[offset..end];
        if (hash == target_hash) {
            const matches = switch (keyword_case) {
                .sensitive => std.mem.eql(u8, token, option),
                .ascii_insensitive => std.ascii.eqlIgnoreCase(token, option),
            };
            if (matches) return true;
        }
        offset = end;
    }
    return false;
}

fn ansiSequenceEnd(text: []const u8, start: usize) usize {
    if (start + 2 > text.len or text[start] != 0x1b or text[start + 1] != '[') return start;
    var index = start + 2;
    while (index < text.len) : (index += 1) {
        if (text[index] >= '@' and text[index] <= '~') return index + 1;
    }
    return start;
}

fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    errdefer plain.deinit(alloc);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            const end = ansiSequenceEnd(text, index);
            if (end > index) {
                index = end;
                continue;
            }
        }
        try plain.append(alloc, text[index]);
        index += 1;
    }
    return plain.toOwnedSlice(alloc);
}

fn count(text: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.findPos(u8, text, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

test "supported source gains balanced colors without changing code bytes" {
    const alloc = std.testing.allocator;
    const source = "const value = \"const\"; // return\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .dark, null);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;") != null);
    try std.testing.expectEqual(count(styled, "\x1b[38;5;"), count(styled, "\x1b[39m"));
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252mconst") != null);
    try std.testing.expectEqual(@as(usize, 1), count(styled, "\x1b[38;5;252mconst"));
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m\"const\"\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252mreturn") == null);
}

test "light theme uses a readable syntax palette without changing code bytes" {
    const alloc = std.testing.allocator;
    const source = "const value = \"ready\"; // comment\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .light, null);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;238mconst\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;241m\"ready\"\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;243m// comment\x1b[39m") != null);
    try std.testing.expectEqual(count(styled, "\x1b[38;5;"), count(styled, "\x1b[39m"));
}

test "every registered profile highlights representative source" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        label: []const u8,
        source: []const u8,
    }{
        .{ .label = "zig", .source = "pub fn main() void { return; }" },
        .{ .label = "ts", .source = "const ready = true;" },
        .{ .label = "json", .source = "{\"ready\": true}" },
        .{ .label = "sh", .source = "if true; then echo \"ready\"; fi" },
        .{ .label = "python", .source = "def ready(): return True" },
        .{ .label = "yaml", .source = "ready: true # comment" },
        .{ .label = "toml", .source = "ready = true # comment" },
        .{ .label = "sql", .source = "SELECT id FROM users" },
        .{ .label = "dockerfile", .source = "FROM alpine:3.20" },
        .{ .label = "rust", .source = "fn main() { let ready = true; }" },
        .{ .label = "go", .source = "package main\nfunc main() {}" },
        .{ .label = "c", .source = "int main(void) { return 0; }" },
        .{ .label = "cpp", .source = "class Ready { public: bool value = true; };" },
        .{ .label = "csharp", .source = "public class Ready { }" },
        .{ .label = "java", .source = "public class Ready { }" },
        .{ .label = "kotlin", .source = "fun ready(): Boolean = true" },
        .{ .label = "php", .source = "<?php function ready() { return true; }" },
        .{ .label = "ruby", .source = "def ready\n  true\nend" },
        .{ .label = "swift", .source = "func ready() -> Bool { true }" },
        .{ .label = "powershell", .source = "Function Ready { return $true }" },
        .{ .label = "lua", .source = "local ready = true" },
        .{ .label = "html", .source = "<main class=\"ready\"></main>" },
        .{ .label = "xml", .source = "<?xml version=\"1.0\"?>" },
        .{ .label = "css", .source = ".ready { color: red; }" },
        .{ .label = "hcl", .source = "resource \"ready\" \"main\" {}" },
    };

    for (cases) |case| {
        const styled = try highlight(alloc, case.source, languages.resolve(case.label).?, .dark, null);
        defer alloc.free(styled);
        const plain = try stripAnsi(alloc, styled);
        defer alloc.free(plain);
        try std.testing.expectEqualStrings(case.source, plain);
        try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;") != null);
    }
}

test "profiles use configured block comments and case-insensitive keywords" {
    const alloc = std.testing.allocator;
    const source = "/* comment */\nSELECT id FROM users\n<!-- note -->";
    const css = try highlight(alloc, source[0..13], languages.resolve("css").?, .dark, null);
    defer alloc.free(css);
    const sql = try highlight(alloc, source[14..34], languages.resolve("sql").?, .dark, null);
    defer alloc.free(sql);
    const html = try highlight(alloc, source[35..], languages.resolve("html").?, .dark, null);
    defer alloc.free(html);

    try std.testing.expect(std.mem.find(u8, css, "\x1b[38;5;245m/* comment */\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, sql, "\x1b[38;5;252mSELECT\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, html, "\x1b[38;5;245m<!-- note -->\x1b[39m") != null);
}

test "themed attribute slots close fully without bleeding into later text" {
    const alloc = std.testing.allocator;
    const previous = shared_theme.current();
    defer shared_theme.activate(previous);

    var custom = shared_theme.fx_dark;
    custom.syntax.comment_style = "\x1b[3;38;2;106;153;85m";
    custom.syntax.keyword_style = "\x1b[1;38;2;130;210;206m";
    shared_theme.activate(custom);

    const styled = try highlight(alloc, "const x = 1; // note\n", languages.resolve("zig").?, .dark, null);
    defer alloc.free(styled);

    // Italic comment and bold keyword each close with their attributes reset.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[3;38;2;106;153;85m// note\x1b[39m\x1b[23m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[1;38;2;130;210;206mconst\x1b[39m\x1b[22m") != null);
    // Nothing stays bold or italic past the final close.
    try std.testing.expect(!std.mem.endsWith(u8, styled, "\x1b[3;38;2;106;153;85m"));
}

test "base style wraps the span and restores after each token" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "echo 'hi there' 42", languages.resolve("sh").?, .dark, "<base>");
    defer alloc.free(styled);

    // The span opens with the base, and every token close re-establishes it.
    try std.testing.expect(std.mem.startsWith(u8, styled, "<base>\x1b[38;5;252mecho\x1b[39m<base> "));
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m'hi there'\x1b[39m<base>") != null);
    // Bare number arguments stay plain in shell.
    try std.testing.expect(std.mem.endsWith(u8, styled, "<base> 42"));
}

test "a theme with syntax disabled passes the source through" {
    const alloc = std.testing.allocator;
    var no_syntax = shared_theme.fx_dark;
    no_syntax.syntax.enabled = false;

    const previous = shared_theme.current();
    defer shared_theme.activate(previous);
    shared_theme.activate(no_syntax);

    const plain = try highlight(alloc, "echo 'hi there' 42", languages.resolve("sh").?, .dark, null);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("echo 'hi there' 42", plain);

    const with_base = try highlight(alloc, "echo 'hi there' 42", languages.resolve("sh").?, .dark, "<base>");
    defer alloc.free(with_base);
    try std.testing.expectEqualStrings("<base>echo 'hi there' 42", with_base);
}

test "shell operators and variables take the keyword color" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "cd /tmp && echo $HOME | head -2 > out; echo $? # done", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m&&\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m|\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m>\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m;\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m$HOME\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m$?\x1b[39m") != null);
    // Comments keep their color, flags take the number color as a unit, and
    // a $ inside quotes stays string.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;245m# done\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m-2\x1b[39m") != null);

    const quoted = try highlight(alloc, "echo '$HOME'", languages.resolve("sh").?, .dark, null);
    defer alloc.free(quoted);
    try std.testing.expect(std.mem.find(u8, quoted, "\x1b[38;5;250m'$HOME'\x1b[39m") != null);

    // Other languages do not pick up shell operators.
    const zig_src = try highlight(alloc, "a < b", languages.resolve("zig").?, .dark, null);
    defer alloc.free(zig_src);
    try std.testing.expectEqualStrings("a < b", zig_src);
}

test "digit runs glued to words by a dash stay plain" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "cd build-20260918 && head -80 2>/dev/null", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    // The date suffix in the path is a name segment and keeps the plain text,
    // as does the literal-looking "null" in /dev/null.
    try std.testing.expect(std.mem.find(u8, styled, "build-20260918") != null);
    try std.testing.expect(std.mem.find(u8, styled, "/dev/null") != null);
    // The numeric flag colors as a unit, and the redirect fd still colors.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m-80\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m2\x1b[39m") != null);
}

test "dash flags color as units only at word boundaries" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "tail -8 --json && cat - < in", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m-8\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m--json\x1b[39m") != null);
    // A lone dash (stdin marker) stays plain between the verb and the
    // redirect, and the redirect target is an argument, not a keyword.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252mcat\x1b[39m - \x1b[38;5;252m<\x1b[39m in") != null);

    // Flags after operators still count as boundaries.
    const after_pipe = try highlight(alloc, "echo x | head -1", languages.resolve("sh").?, .dark, null);
    defer alloc.free(after_pipe);
    try std.testing.expect(std.mem.find(u8, after_pipe, "\x1b[38;5;250m-1\x1b[39m") != null);

    // Other languages keep minus signs plain.
    const zig_src = try highlight(alloc, "a - b", languages.resolve("zig").?, .dark, null);
    defer alloc.free(zig_src);
    try std.testing.expectEqualStrings("a - b", zig_src);
}

test "command position colors any command word and only command words" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "gh run list | xargs echo > out.txt", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    // Unknown binaries color in command position, matching the bash grammar's
    // variable.function; a builtin used as an argument stays plain, and the
    // redirect target is a path, not a command.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252mgh\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252mxargs\x1b[39m") != null);
    // echo is an argument here and stays plain; the redirect target too.
    try std.testing.expect(std.mem.find(u8, styled, " echo \x1b[38;5;252m>\x1b[39m out.txt") != null);

    // Control keywords hand command position to the command they govern.
    const chain = try highlight(alloc, "if cd /x; then echo hi; fi", languages.resolve("sh").?, .dark, null);
    defer alloc.free(chain);
    for ([_][]const u8{ "if", "cd", "then", "echo", "fi" }) |word| {
        const wrapped = try alloc.print("\x1b[38;5;252m{s}\x1b[39m", .{word});
        defer alloc.free(wrapped);
        try std.testing.expect(std.mem.find(u8, chain, wrapped) != null);
    }
}

test "bare number arguments stay plain but redirect fds color" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "sleep 5; exit 7 2>&1", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    try std.testing.expect(std.mem.find(u8, styled, " 5") != null);
    try std.testing.expect(std.mem.find(u8, styled, " 7 ") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m2\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m1\x1b[39m") != null);
}

test "braced variables tildes globs and substitution parse like the grammar" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "cp ${SRC}/*.log ~/out && echo $(date +%F)", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m${SRC}\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m*\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m~\x1b[39m/out") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m$(\x1b[39m") != null);
    // The substitution contents open in command position.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252mdate\x1b[39m") != null);

    // Backtick contents parse as code rather than one flat string.
    const ticks = try highlight(alloc, "echo `uname -s`", languages.resolve("sh").?, .dark, null);
    defer alloc.free(ticks);
    try std.testing.expect(std.mem.find(u8, ticks, "`\x1b[38;5;252muname\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, ticks, "\x1b[38;5;250m-s\x1b[39m") != null);
}

test "double quotes interpolate variables inside the string color" {
    const alloc = std.testing.allocator;
    const styled = try highlight(alloc, "echo \"hi $USER from ${HOME}\"", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;250m\"hi \x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m$USER\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m${HOME}\x1b[39m") != null);
    // Single quotes do not interpolate.
    const single = try highlight(alloc, "echo '$USER'", languages.resolve("sh").?, .dark, null);
    defer alloc.free(single);
    try std.testing.expect(std.mem.find(u8, single, "\x1b[38;5;250m'$USER'\x1b[39m") != null);
}

test "diff lines paint with the caller's marker colors" {
    const alloc = std.testing.allocator;
    const patch = "diff --git a/f b/f\nindex 111..222 100644\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-old line\n+new line\n context";
    const styled = try highlightDiff(alloc, patch, .dark, "<added>", "<removed>");
    defer alloc.free(styled);

    try std.testing.expect(std.mem.find(u8, styled, "<added>+new line") != null);
    try std.testing.expect(std.mem.find(u8, styled, "<removed>-old line") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;252m@@ -1,2 +1,2 @@\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;245m--- a/f\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;245mdiff --git a/f b/f\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\n context") != null);

    var no_syntax = shared_theme.fx_dark;
    no_syntax.syntax.enabled = false;
    const previous = shared_theme.current();
    defer shared_theme.activate(previous);
    shared_theme.activate(no_syntax);
    const plain = try highlightDiff(alloc, patch, .dark, "<added>", "<removed>");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(patch, plain);
}

test "text blocks stay byte-identical and markdown colors inline code" {
    const alloc = std.testing.allocator;
    const text = try highlight(alloc, "plain prose with 42 numbers and # no comment", languages.resolve("text").?, .dark, null);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("plain prose with 42 numbers and # no comment", text);

    const md = try highlight(alloc, "run `fx upgrade` to update", languages.resolve("md").?, .dark, null);
    defer alloc.free(md);
    try std.testing.expect(std.mem.find(u8, md, "\x1b[38;5;250m`fx upgrade`\x1b[39m") != null);
}

test "split slots let themes color commands variables and operators apart" {
    const alloc = std.testing.allocator;
    var themed = shared_theme.fx_dark;
    themed.syntax.function_style = "\x1b[38;5;201m";
    themed.syntax.variable_style = "\x1b[38;5;202m";
    themed.syntax.operator_style = "\x1b[38;5;203m";
    themed.syntax.keyword_style = "\x1b[38;5;204m";

    const previous = shared_theme.current();
    defer shared_theme.activate(previous);
    shared_theme.activate(themed);

    const styled = try highlight(alloc, "while true; do echo $HOME | head -2; done", languages.resolve("sh").?, .dark, null);
    defer alloc.free(styled);

    // Control keywords keep the keyword color; command words take the
    // function color; variables and operators take their own.
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;204mwhile\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;201mtrue\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;201mecho\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;202m$HOME\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, styled, "\x1b[38;5;203m|\x1b[39m") != null);
}

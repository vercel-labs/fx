const std = @import("std");
const shared_theme = @import("../../core/shared/theme.zig");
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

pub fn highlight(
    alloc: Allocator,
    source: []const u8,
    profile: *const languages.Profile,
    theme: Theme,
) ![]u8 {
    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(alloc);
    const palette = paletteForTheme(theme);

    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\n') {
            try styled.append(alloc, '\n');
            index += 1;
            continue;
        }
        if (blockCommentEnd(source, index, profile.block_comment)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end]);
            index = end;
            continue;
        }
        if (lineCommentEnd(source, index, profile.line_comments)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end]);
            index = end;
            continue;
        }
        if (isQuote(source[index], profile.quotes)) {
            const end = quotedEnd(source, index);
            try appendStyled(alloc, &styled, palette.string_style, source[index..end]);
            index = end;
            continue;
        }
        if (isNumberStart(source, index)) {
            const end = numberEnd(source, index);
            try appendStyled(alloc, &styled, palette.number_style, source[index..end]);
            index = end;
            continue;
        }
        if (isIdentifierStart(source[index])) {
            const end = identifierEnd(source, index);
            const token = source[index..end];
            if (inList(token, profile.keywords, profile.keyword_case)) {
                try appendStyled(alloc, &styled, palette.keyword_style, token);
            } else if (inList(token, profile.literals, profile.keyword_case)) {
                try appendStyled(alloc, &styled, palette.number_style, token);
            } else {
                try styled.appendSlice(alloc, token);
            }
            index = end;
            continue;
        }
        try styled.append(alloc, source[index]);
        index += 1;
    }

    return styled.toOwnedSlice(alloc);
}

fn appendStyled(alloc: Allocator, out: *std.ArrayList(u8), style: []const u8, text: []const u8) !void {
    try out.appendSlice(alloc, style);
    try out.appendSlice(alloc, text);
    // Close whatever the slot opened: fg-only slots keep the plain reset,
    // themed slots carrying bold/italic get those reset too.
    try out.appendSlice(alloc, shared_theme.closingFor(style));
}

fn blockCommentEnd(source: []const u8, index: usize, block_comment: ?languages.BlockComment) ?usize {
    const comment = block_comment orelse return null;
    const start = comment.start.get();
    if (!std.mem.startsWith(u8, source[index..], start)) return null;
    const content_start = index + start.len;
    const end = comment.end.get();
    const close_start = std.mem.indexOfPos(u8, source, content_start, end) orelse return source.len;
    return close_start + end.len;
}

fn lineCommentEnd(source: []const u8, index: usize, prefixes: []const languages.Ref) ?usize {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, source[index..], prefix.get())) return lineEnd(source, index);
    }
    return null;
}

fn lineEnd(source: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
}

fn isQuote(byte: u8, quotes: []const u8) bool {
    return std.mem.indexOfScalar(u8, quotes, byte) != null;
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
    return std.ascii.isDigit(source[index]) and (index == 0 or !isIdentifierContinue(source[index - 1]));
}

fn numberEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '_')) : (index += 1) {}
    return index;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn identifierEnd(source: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < source.len and isIdentifierContinue(source[index])) : (index += 1) {}
    return index;
}

fn inList(token: []const u8, options: []const languages.Ref, keyword_case: languages.KeywordCase) bool {
    for (options) |option| {
        const matches = switch (keyword_case) {
            .sensitive => std.mem.eql(u8, token, option.get()),
            .ascii_insensitive => std.ascii.eqlIgnoreCase(token, option.get()),
        };
        if (matches) return true;
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
    while (std.mem.indexOfPos(u8, text, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

test "supported source gains balanced colors without changing code bytes" {
    const alloc = std.testing.allocator;
    const source = "const value = \"const\"; // return\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .dark);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;") != null);
    try std.testing.expectEqual(count(styled, "\x1b[38;5;"), count(styled, "\x1b[39m"));
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;252mconst") != null);
    try std.testing.expectEqual(@as(usize, 1), count(styled, "\x1b[38;5;252mconst"));
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;250m\"const\"\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;252mreturn") == null);
}

test "light theme uses a readable syntax palette without changing code bytes" {
    const alloc = std.testing.allocator;
    const source = "const value = \"ready\"; // comment\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .light);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;238mconst\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;241m\"ready\"\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;243m// comment\x1b[39m") != null);
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
        const styled = try highlight(alloc, case.source, languages.resolve(case.label).?, .dark);
        defer alloc.free(styled);
        const plain = try stripAnsi(alloc, styled);
        defer alloc.free(plain);
        try std.testing.expectEqualStrings(case.source, plain);
        try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;") != null);
    }
}

test "profiles use configured block comments and case-insensitive keywords" {
    const alloc = std.testing.allocator;
    const source = "/* comment */\nSELECT id FROM users\n<!-- note -->";
    const css = try highlight(alloc, source[0..13], languages.resolve("css").?, .dark);
    defer alloc.free(css);
    const sql = try highlight(alloc, source[14..34], languages.resolve("sql").?, .dark);
    defer alloc.free(sql);
    const html = try highlight(alloc, source[35..], languages.resolve("html").?, .dark);
    defer alloc.free(html);

    try std.testing.expect(std.mem.indexOf(u8, css, "\x1b[38;5;245m/* comment */\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\x1b[38;5;252mSELECT\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\x1b[38;5;245m<!-- note -->\x1b[39m") != null);
}

test "themed attribute slots close fully without bleeding into later text" {
    const alloc = std.testing.allocator;
    const previous = shared_theme.current();
    defer shared_theme.activate(previous);

    var custom = shared_theme.fx_dark;
    custom.syntax.comment_style = "\x1b[3;38;2;106;153;85m";
    custom.syntax.keyword_style = "\x1b[1;38;2;130;210;206m";
    shared_theme.activate(custom);

    const styled = try highlight(alloc, "const x = 1; // note\n", languages.resolve("zig").?, .dark);
    defer alloc.free(styled);

    // Italic comment and bold keyword each close with their attributes reset.
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[3;38;2;106;153;85m// note\x1b[39m\x1b[23m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[1;38;2;130;210;206mconst\x1b[39m\x1b[22m") != null);
    // Nothing stays bold or italic past the final close.
    try std.testing.expect(!std.mem.endsWith(u8, styled, "\x1b[3;38;2;106;153;85m"));
}

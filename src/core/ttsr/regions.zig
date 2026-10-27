//! Lexical regions for `in:` constraints: which bytes of a buffer are code,
//! comment, string, or prose.
//!
//! A regex over a stream cannot tell a real `as any` cast from the same words
//! in a comment, a string, or prose explaining the rule, so a condition may
//! require its match to sit in one region kind. Scanning is lexical, not a
//! parse: it runs on partially written source and on languages without a
//! grammar here. A language without a profile classifies as null, and an
//! `in:` constraint then fails closed.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum { code, comment, string, prose };

pub const Region = struct { start: usize, end: usize, kind: Kind };

pub const Mode = union(enum) { code: *const Profile, prose };

pub const Source = enum { text, thinking, tool };

const StringSyntax = struct { open: []const u8, close: []const u8, escape: bool };
const BlockComment = struct { open: []const u8, close: []const u8, nested: bool };

pub const Profile = struct {
    line_comments: []const []const u8 = &.{},
    block_comments: []const BlockComment = &.{},
    strings: []const StringSyntax = &quotes,
    /// `'` opens a char literal only when the text looks like one.
    char_literal: bool = false,
    rust_raw_strings: bool = false,
    python_strings: bool = false,
    verbatim_strings: bool = false,
    regex_literals: bool = false,
    /// `#` starts a comment only at a word boundary, as in shell.
    word_start_line_comment: bool = false,
};

const quotes = [_]StringSyntax{
    .{ .open = "\"", .close = "\"", .escape = true },
    .{ .open = "'", .close = "'", .escape = true },
};
const slash_block = [_]BlockComment{.{ .open = "/*", .close = "*/", .nested = false }};
const double_only = [_]StringSyntax{.{ .open = "\"", .close = "\"", .escape = true }};

const js: Profile = .{
    .line_comments = &.{"//"},
    .block_comments = &slash_block,
    .strings = &(quotes ++ [_]StringSyntax{.{ .open = "`", .close = "`", .escape = true }}),
    .regex_literals = true,
};
const rust: Profile = .{
    .line_comments = &.{"//"},
    .block_comments = &.{.{ .open = "/*", .close = "*/", .nested = true }},
    .strings = &double_only,
    .char_literal = true,
    .rust_raw_strings = true,
};
const go: Profile = .{
    .line_comments = &.{"//"},
    .block_comments = &slash_block,
    .strings = &.{ .{ .open = "\"", .close = "\"", .escape = true }, .{ .open = "`", .close = "`", .escape = false } },
    .char_literal = true,
};
const clike: Profile = .{ .line_comments = &.{"//"}, .block_comments = &slash_block, .char_literal = true };
const csharp: Profile = .{ .line_comments = &.{"//"}, .block_comments = &slash_block, .char_literal = true, .verbatim_strings = true };
const python: Profile = .{ .line_comments = &.{"#"}, .python_strings = true };
const shell: Profile = .{ .line_comments = &.{"#"}, .word_start_line_comment = true };
const ruby: Profile = .{ .line_comments = &.{"#"}, .block_comments = &.{.{ .open = "\n=begin", .close = "\n=end", .nested = false }} };
const lua: Profile = .{
    .line_comments = &.{"--"},
    .block_comments = &.{.{ .open = "--[[", .close = "]]", .nested = false }},
    .strings = &(quotes ++ [_]StringSyntax{.{ .open = "[[", .close = "]]", .escape = false }}),
};
const sql: Profile = .{ .line_comments = &.{"--"}, .block_comments = &slash_block };
const hash: Profile = .{ .line_comments = &.{"#"} };
const css: Profile = .{ .block_comments = &slash_block };
const json: Profile = .{ .strings = &double_only };
const jsonc: Profile = .{ .line_comments = &.{"//"}, .block_comments = &slash_block, .strings = &double_only };
const xml: Profile = .{ .block_comments = &.{.{ .open = "<!--", .close = "-->", .nested = false }} };

const lang_profiles = [_]struct { []const u8, *const Profile }{
    .{ "ts", &js },         .{ "tsx", &js },    .{ "mts", &js },        .{ "cts", &js },      .{ "typescript", &js },
    .{ "js", &js },         .{ "jsx", &js },    .{ "mjs", &js },        .{ "cjs", &js },      .{ "javascript", &js },
    .{ "rs", &rust },       .{ "rust", &rust }, .{ "go", &go },         .{ "golang", &go },   .{ "c", &clike },
    .{ "h", &clike },       .{ "cc", &clike },  .{ "cpp", &clike },     .{ "cxx", &clike },   .{ "hpp", &clike },
    .{ "java", &clike },    .{ "kt", &clike },  .{ "kts", &clike },     .{ "swift", &clike }, .{ "scala", &clike },
    .{ "dart", &clike },    .{ "zig", &clike }, .{ "php", &clike },     .{ "proto", &clike }, .{ "hcl", &clike },
    .{ "tf", &clike },      .{ "cs", &csharp }, .{ "csharp", &csharp }, .{ "py", &python },   .{ "pyi", &python },
    .{ "python", &python }, .{ "sh", &shell },  .{ "bash", &shell },    .{ "zsh", &shell },   .{ "fish", &shell },
    .{ "rb", &ruby },       .{ "ruby", &ruby }, .{ "lua", &lua },       .{ "sql", &sql },     .{ "yaml", &hash },
    .{ "yml", &hash },      .{ "toml", &hash }, .{ "ini", &hash },      .{ "css", &css },     .{ "scss", &css },
    .{ "less", &css },      .{ "json", &json }, .{ "jsonc", &jsonc },   .{ "json5", &jsonc }, .{ "html", &xml },
    .{ "htm", &xml },       .{ "xml", &xml },   .{ "svg", &xml },       .{ "vue", &xml },
};

const prose_langs = [_][]const u8{ "md", "mdx", "mdc", "markdown", "txt", "text", "rst" };

fn profileFor(lang: []const u8) ?*const Profile {
    var buf: [16]u8 = undefined;
    if (lang.len > buf.len) return null;
    const key = std.ascii.lowerString(&buf, lang);
    for (lang_profiles) |entry| if (std.mem.eql(u8, entry[0], key)) return entry[1];
    return null;
}

fn isProse(lang: []const u8) bool {
    var buf: [16]u8 = undefined;
    if (lang.len > buf.len) return false;
    const key = std.ascii.lowerString(&buf, lang);
    for (prose_langs) |name| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

/// Whether `lang` has a lexical profile or is prose.
pub fn canClassify(lang: ?[]const u8) bool {
    const name = lang orelse return false;
    return isProse(name) or profileFor(name) != null;
}

pub fn modeFor(source: Source, lang: ?[]const u8) ?Mode {
    if (source != .tool) return .prose;
    const name = lang orelse return null;
    if (isProse(name)) return .prose;
    return if (profileFor(name)) |p| .{ .code = p } else null;
}

/// The comment and string (or fenced code) regions of `text`, sorted and
/// non-overlapping; bytes outside them are code (or prose). Caller owns the
/// slice.
pub fn classify(alloc: Allocator, text: []const u8, mode: Mode) ![]Region {
    var regions: std.ArrayList(Region) = .empty;
    errdefer regions.deinit(alloc);
    switch (mode) {
        .prose => try markdownRegions(alloc, &regions, text),
        .code => |p| try codeRegions(alloc, &regions, text, p),
    }
    return regions.toOwnedSlice(alloc);
}

/// The kind of the region covering all of `[start, end)`, or null when the
/// span straddles kinds.
pub fn spanKind(regions: []const Region, start: usize, end: usize, fallback: Kind) ?Kind {
    var kind: ?Kind = null;
    var cursor = start;
    while (cursor < end) {
        const region = regionAt(regions, cursor);
        const current = if (region) |r| r.kind else fallback;
        if (kind != null and kind.? != current) return null;
        kind = current;
        cursor = if (region) |r| @min(r.end, end) else nextStart(regions, cursor, end);
    }
    return kind orelse fallback;
}

fn regionAt(regions: []const Region, offset: usize) ?Region {
    var low: usize = 0;
    var high: usize = regions.len;
    while (low < high) {
        const mid = (low + high) / 2;
        const r = regions[mid];
        if (offset < r.start) {
            high = mid;
        } else if (offset >= r.end) {
            low = mid + 1;
        } else return r;
    }
    return null;
}

fn nextStart(regions: []const Region, offset: usize, limit: usize) usize {
    for (regions) |r| if (r.start > offset) return @min(r.start, limit);
    return limit;
}

fn markdownRegions(alloc: Allocator, regions: *std.ArrayList(Region), text: []const u8) !void {
    var index: usize = 0;
    var fence_start: ?usize = null;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    while (index < text.len) {
        const newline = std.mem.findScalarPos(u8, text, index, '\n');
        const end = if (newline) |n| n + 1 else text.len;
        const line = text[index..end];
        var lead: usize = 0;
        while (lead < line.len and lead < 4 and line[lead] == ' ') lead += 1;
        var run: usize = 0;
        var run_char: u8 = 0;
        if (lead <= 3 and lead < line.len and (line[lead] == '`' or line[lead] == '~')) {
            run_char = line[lead];
            while (lead + run < line.len and line[lead + run] == run_char) run += 1;
            if (run < 3) run = 0;
        }
        if (fence_start == null) {
            if (run > 0) {
                fence_start = index;
                fence_char = run_char;
                fence_len = run;
            }
        } else if (run > 0 and run_char == fence_char and run >= fence_len) {
            try regions.append(alloc, .{ .start = fence_start.?, .end = end, .kind = .code });
            fence_start = null;
        }
        index = end;
    }
    if (fence_start) |start| try regions.append(alloc, .{ .start = start, .end = text.len, .kind = .code });
}

fn codeRegions(alloc: Allocator, regions: *std.ArrayList(Region), text: []const u8, p: *const Profile) !void {
    var index: usize = 0;
    var last_code: ?usize = null;
    while (index < text.len) {
        if (scanBlockComment(text, index, p)) |end| {
            try regions.append(alloc, .{ .start = index, .end = end, .kind = .comment });
            index = end;
            continue;
        }
        if (scanLineComment(text, index, p)) |end| {
            try regions.append(alloc, .{ .start = index, .end = end, .kind = .comment });
            index = end;
            continue;
        }
        if (scanString(text, index, p, last_code)) |end| {
            try regions.append(alloc, .{ .start = index, .end = end, .kind = .string });
            index = end;
            continue;
        }
        if (!std.ascii.isWhitespace(text[index])) last_code = index;
        index += 1;
    }
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn scanBlockComment(text: []const u8, index: usize, p: *const Profile) ?usize {
    for (p.block_comments) |block| {
        if (!std.mem.startsWith(u8, text[index..], block.open)) continue;
        var depth: usize = 1;
        var cursor = index + block.open.len;
        while (cursor < text.len and depth > 0) {
            if (block.nested and std.mem.startsWith(u8, text[cursor..], block.open)) {
                depth += 1;
                cursor += block.open.len;
                continue;
            }
            if (std.mem.startsWith(u8, text[cursor..], block.close)) {
                depth -= 1;
                cursor += block.close.len;
                continue;
            }
            cursor += 1;
        }
        return if (depth > 0) text.len else cursor;
    }
    return null;
}

fn scanLineComment(text: []const u8, index: usize, p: *const Profile) ?usize {
    for (p.line_comments) |marker| {
        if (!std.mem.startsWith(u8, text[index..], marker)) continue;
        // `a#b` is one shell word; `echo a # b` has a comment.
        if (p.word_start_line_comment and index > 0 and isIdent(text[index - 1])) continue;
        return std.mem.findScalarPos(u8, text, index, '\n') orelse text.len;
    }
    return null;
}

fn scanString(text: []const u8, index: usize, p: *const Profile, last_code: ?usize) ?usize {
    const c = text[index];
    if (p.python_strings) if (scanPythonString(text, index)) |end| return end;
    if (p.rust_raw_strings) if (scanRustRawString(text, index)) |end| return end;
    if (p.verbatim_strings and c == '@' and index + 1 < text.len and text[index + 1] == '"') {
        var cursor = index + 2;
        while (cursor < text.len) {
            if (text[cursor] == '"') {
                if (cursor + 1 < text.len and text[cursor + 1] == '"') {
                    cursor += 2;
                    continue;
                }
                return cursor + 1;
            }
            cursor += 1;
        }
        return text.len;
    }
    if (p.regex_literals and c == '/' and !std.mem.startsWith(u8, text[index..], "//") and !std.mem.startsWith(u8, text[index..], "/*")) {
        return if (isRegexLiteralStart(text, last_code)) scanRegexLiteral(text, index) else null;
    }
    for (p.strings) |syntax| {
        if (!std.mem.startsWith(u8, text[index..], syntax.open)) continue;
        if (std.mem.eql(u8, syntax.open, "'") and p.char_literal and !isCharLiteral(text, index)) continue;
        return scanQuoted(text, index, syntax);
    }
    return null;
}

fn scanQuoted(text: []const u8, index: usize, syntax: StringSyntax) usize {
    var cursor = index + syntax.open.len;
    while (cursor < text.len) {
        if (syntax.escape and text[cursor] == '\\') {
            cursor += 2;
            continue;
        }
        if (std.mem.startsWith(u8, text[cursor..], syntax.close)) return cursor + syntax.close.len;
        cursor += 1;
    }
    return text.len;
}

fn scanPythonString(text: []const u8, index: usize) ?usize {
    var start = index;
    while (start > 0 and isIdent(text[start - 1])) start -= 1;
    const prefix = text[start..index];
    if (prefix.len > 2) return null;
    for (prefix) |c| switch (c) {
        'r', 'R', 'b', 'B', 'u', 'U', 'f', 'F' => {},
        else => return null,
    };
    const raw = std.mem.findAny(u8, prefix, "rR") != null;
    for ([_][]const u8{ "\"\"\"", "'''", "\"", "'" }) |quote| {
        if (!std.mem.startsWith(u8, text[index..], quote)) continue;
        return scanQuoted(text, index, .{ .open = quote, .close = quote, .escape = !raw });
    }
    return null;
}

fn scanRustRawString(text: []const u8, index: usize) ?usize {
    var cursor = index;
    if (cursor < text.len and (text[cursor] == 'b' or text[cursor] == 'c')) cursor += 1;
    if (cursor >= text.len or text[cursor] != 'r') return null;
    if (index > 0 and isIdent(text[index - 1])) return null;
    cursor += 1;
    const hashes_start = cursor;
    while (cursor < text.len and text[cursor] == '#') cursor += 1;
    if (cursor >= text.len or text[cursor] != '"') return null;
    const hashes = cursor - hashes_start;
    cursor += 1;
    while (cursor < text.len) : (cursor += 1) {
        if (text[cursor] != '"') continue;
        var count: usize = 0;
        while (count < hashes and cursor + 1 + count < text.len and text[cursor + 1 + count] == '#') count += 1;
        if (count == hashes) return cursor + 1 + hashes;
    }
    return text.len;
}

fn isCharLiteral(text: []const u8, index: usize) bool {
    var cursor = index + 1;
    if (cursor >= text.len) return false;
    if (text[cursor] == '\\') {
        cursor += 1;
        if (cursor >= text.len) return false;
        if (text[cursor] == 'u' and cursor + 1 < text.len and text[cursor + 1] == '{') {
            cursor += 2;
            while (cursor < text.len and std.ascii.isHex(text[cursor])) cursor += 1;
            if (cursor >= text.len or text[cursor] != '}') return false;
            cursor += 1;
        } else if (text[cursor] == 'x') {
            cursor += 3;
        } else {
            cursor += 1;
        }
    } else {
        if (text[cursor] == '\'') return false;
        // One UTF-8 sequence.
        const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch 1;
        cursor += len;
    }
    return cursor < text.len and text[cursor] == '\'';
}

const regex_after_keyword = [_][]const u8{ "await", "case", "delete", "do", "else", "in", "instanceof", "new", "of", "return", "throw", "typeof", "void", "yield" };

fn isRegexLiteralStart(text: []const u8, last_code: ?usize) bool {
    const last = last_code orelse return true;
    const previous = text[last];
    if (isIdent(previous)) {
        var start = last;
        while (start > 0 and isIdent(text[start - 1])) start -= 1;
        const word = text[start .. last + 1];
        for (regex_after_keyword) |keyword| if (std.mem.eql(u8, keyword, word)) return true;
        return false;
    }
    return previous != ')' and previous != ']';
}

fn scanRegexLiteral(text: []const u8, index: usize) ?usize {
    var cursor = index + 1;
    var in_class = false;
    while (cursor < text.len) {
        const c = text[cursor];
        if (c == '\\') {
            cursor += 2;
            continue;
        }
        if (c == '\n') return null;
        if (c == '[') in_class = true else if (c == ']') in_class = false else if (c == '/' and !in_class) return cursor + 1;
        cursor += 1;
    }
    return null;
}

fn kindAt(alloc: Allocator, text: []const u8, lang: []const u8, needle: []const u8) !?Kind {
    const regions = try classify(alloc, text, modeFor(.tool, lang).?);
    defer alloc.free(regions);
    const start = std.mem.find(u8, text, needle).?;
    return spanKind(regions, start, start + needle.len, if (isProse(lang)) .prose else .code);
}

test "regions classify comments strings and code per language" {
    const alloc = std.testing.allocator;
    const ts = "const a = x as any; // as any\nconst s = \"as any\"; const r = /as any/;";
    try std.testing.expectEqual(Kind.code, (try kindAt(alloc, ts, "ts", "x as any")).?);
    try std.testing.expectEqual(Kind.comment, (try kindAt(alloc, ts, "ts", "// as any")).?);
    try std.testing.expectEqual(Kind.string, (try kindAt(alloc, ts, "ts", "\"as any\"")).?);
    try std.testing.expectEqual(Kind.string, (try kindAt(alloc, ts, "ts", "/as any/")).?);
    const div = "const q = a / b / c;";
    try std.testing.expectEqual(Kind.code, (try kindAt(alloc, div, "ts", "/ b /")).?);

    const rs = "let s = r#\"Box::leak\"#; /* outer /* inner */ Box::leak */ fn f<'a>(x: &'a str) { Box::leak(y) }";
    try std.testing.expectEqual(Kind.string, (try kindAt(alloc, rs, "rs", "r#\"Box::leak\"#")).?);
    try std.testing.expectEqual(Kind.comment, (try kindAt(alloc, rs, "rs", "/* outer /* inner */ Box::leak */")).?);
    try std.testing.expectEqual(Kind.code, (try kindAt(alloc, rs, "rs", "Box::leak(y)")).?);

    const py = "x = f'''import os''' # import os\nimport os";
    try std.testing.expectEqual(Kind.string, (try kindAt(alloc, py, "py", "'''import os'''")).?);
    try std.testing.expectEqual(Kind.comment, (try kindAt(alloc, py, "py", "# import os")).?);
    const py_regions = try classify(alloc, py, modeFor(.tool, "py").?);
    defer alloc.free(py_regions);
    const last_import = std.mem.findLast(u8, py, "import os").?;
    try std.testing.expectEqual(Kind.code, spanKind(py_regions, last_import, last_import + 9, .code).?);

    const sh = "echo a#b # comment";
    try std.testing.expectEqual(Kind.code, (try kindAt(alloc, sh, "sh", "a#b")).?);
    try std.testing.expectEqual(Kind.comment, (try kindAt(alloc, sh, "sh", "# comment")).?);
}

test "regions split prose and fenced code, and straddling spans have no kind" {
    const alloc = std.testing.allocator;
    const md = "Talk about `as any` here.\n```ts\nconst a = x as any;\n```\nmore";
    const regions = try classify(alloc, md, .prose);
    defer alloc.free(regions);
    const inline_at = std.mem.find(u8, md, "`as any`").?;
    try std.testing.expectEqual(Kind.prose, spanKind(regions, inline_at, inline_at + 8, .prose).?);
    const fenced_at = std.mem.find(u8, md, "x as any").?;
    try std.testing.expectEqual(Kind.code, spanKind(regions, fenced_at, fenced_at + 8, .prose).?);
    try std.testing.expect(spanKind(regions, fenced_at - 30, fenced_at + 2, .prose) == null);
    try std.testing.expect(modeFor(.tool, "unknownlang") == null);
    try std.testing.expect(modeFor(.text, null).? == .prose);
    try std.testing.expect(canClassify("TSX"));
}

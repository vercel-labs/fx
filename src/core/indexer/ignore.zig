//! Gitignore pattern lists and exclusion decisions, ported from git's dir.c:
//! line parsing (BOM, CRLF, comments, escaped trailing spaces), negation,
//! directory-only patterns, basename versus anchored matching (including
//! git's literal-prefix split), and last-match precedence across sources.

const std = @import("std");
const wildmatch = @import("wildmatch.zig");

const Allocator = std.mem.Allocator;

/// Largest pattern file read, per source (D7).
pub const max_pattern_file_bytes: usize = 1024 * 1024;

const Pattern = struct {
    /// Pattern bytes without a leading `!` or a trailing `/`; escapes kept.
    text: []const u8,
    /// Length of the leading part free of glob characters (git's
    /// `nowildcardlen`), never more than `text.len`.
    literal_len: usize,
    negative: bool,
    must_be_dir: bool,
    /// No slash in `text`: the pattern matches a basename at any depth.
    basename_only: bool,
};

pub const PatternList = struct {
    /// Directory the list belongs to, relative to the worktree root, ending
    /// in `/`; empty for root-level sources such as `info/exclude`.
    base: []const u8,
    patterns: []const Pattern,

    /// Parses gitignore `contents` for the directory `base` (relative, empty
    /// or ending in `/`). All memory belongs to `arena`.
    pub fn parse(arena: Allocator, base: []const u8, contents: []const u8) Allocator.Error!PatternList {
        std.debug.assert(base.len == 0 or base[base.len - 1] == '/');
        var patterns: std.ArrayList(Pattern) = .empty;
        var rest = contents;
        if (std.mem.startsWith(u8, rest, "\xef\xbb\xbf")) rest = rest[3..];
        var lines = std.mem.splitScalar(u8, rest, '\n');
        while (lines.next()) |raw_line| {
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (std.mem.findScalar(u8, line, 0)) |nul| line = line[0..nul];
            if (line.len == 0 or line[0] == '#') continue;
            line = trimTrailingSpaces(line);
            if (parsePattern(line)) |pattern| {
                try patterns.append(arena, .{
                    .text = try arena.dupe(u8, pattern.text),
                    .literal_len = pattern.literal_len,
                    .negative = pattern.negative,
                    .must_be_dir = pattern.must_be_dir,
                    .basename_only = pattern.basename_only,
                });
            }
        }
        return .{
            .base = try arena.dupe(u8, base),
            .patterns = try patterns.toOwnedSlice(arena),
        };
    }
};

/// git's trim_trailing_spaces: drops unescaped trailing spaces (not tabs).
fn trimTrailingSpaces(line: []const u8) []const u8 {
    var last_space: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ' ' => {
                if (last_space == null) last_space = i;
            },
            '\\' => {
                i += 1;
                if (i >= line.len) return line;
                last_space = null;
            },
            else => last_space = null,
        }
    }
    return if (last_space) |cut| line[0..cut] else line;
}

/// git's parse_path_pattern. Returns null for a pattern that can never match.
fn parsePattern(line: []const u8) ?Pattern {
    var text = line;
    var negative = false;
    if (text.len > 0 and text[0] == '!') {
        negative = true;
        text = text[1..];
    }
    var must_be_dir = false;
    if (text.len > 0 and text[text.len - 1] == '/') {
        must_be_dir = true;
        text = text[0 .. text.len - 1];
    }
    if (text.len == 0) return null;
    return .{
        .text = text,
        .literal_len = @min(literalLength(text), text.len),
        .negative = negative,
        .must_be_dir = must_be_dir,
        .basename_only = std.mem.findScalar(u8, text, '/') == null,
    };
}

fn literalLength(text: []const u8) usize {
    for (text, 0..) |c, i| {
        if (c == '*' or c == '?' or c == '[' or c == '\\') return i;
    }
    return text.len;
}

pub const Decision = enum {
    /// No pattern matched.
    none,
    excluded,
    /// The last matching pattern was a negation.
    included,
};

/// Returns the decision of the last pattern that matches `path` (relative to
/// the worktree root, no leading or trailing slash). `lists` run from lowest
/// to highest precedence: the global excludes file, then `info/exclude`,
/// then `.gitignore` files from the root down. Lists whose `base` does not
/// contain `path` are skipped. This decides `path` alone; callers walking a
/// tree stop at excluded directories, as git does.
pub fn decide(lists: []const *const PatternList, path: []const u8, is_dir: bool, fold_case: bool) Decision {
    const basename = if (std.mem.findScalarLast(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    var result: Decision = .none;
    for (lists) |list| {
        if (list.base.len > 0) {
            if (path.len <= list.base.len or !eqlFold(path[0..list.base.len], list.base, fold_case)) continue;
        }
        for (list.patterns) |*pattern| {
            if (pattern.must_be_dir and !is_dir) continue;
            const matched = if (pattern.basename_only)
                matchBasename(pattern, basename, fold_case)
            else
                matchPathname(pattern, path, list.base, fold_case);
            if (matched) result = if (pattern.negative) .included else .excluded;
        }
    }
    return result;
}

/// Reports whether `path` is excluded, including through an excluded
/// ancestor directory, which git never looks inside.
pub fn isPathExcluded(lists: []const *const PatternList, path: []const u8, is_dir: bool, fold_case: bool) bool {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
        if (decide(lists, path[0..slash], true, fold_case) == .excluded) return true;
    }
    return decide(lists, path, is_dir, fold_case) == .excluded;
}

/// git's match_basename. Basenames contain no slash, so WM_PATHNAME is moot.
fn matchBasename(pattern: *const Pattern, basename: []const u8, fold_case: bool) bool {
    if (pattern.literal_len == pattern.text.len) return eqlFold(pattern.text, basename, fold_case);
    return wildmatch.match(pattern.text, basename, .{ .casefold = fold_case });
}

/// git's match_pathname, keeping its literal-prefix split: the literal head
/// is compared directly and only the remainder goes through wildmatch, so a
/// remainder that starts with `**` is treated as a leading `**`.
fn matchPathname(pattern: *const Pattern, path: []const u8, base: []const u8, fold_case: bool) bool {
    var text = pattern.text;
    var literal_len = pattern.literal_len;
    if (text.len > 0 and text[0] == '/') {
        text = text[1..];
        literal_len -|= 1;
    }
    // `base` ends in `/`, or is empty; `decide` already checked the prefix.
    var name = path[base.len..];
    if (literal_len > 0) {
        if (literal_len > name.len) return false;
        if (!eqlFold(text[0..literal_len], name[0..literal_len], fold_case)) return false;
        text = text[literal_len..];
        name = name[literal_len..];
        if (text.len == 0 and name.len == 0) return true;
    }
    return wildmatch.match(text, name, .{ .pathname = true, .casefold = fold_case });
}

fn eqlFold(a: []const u8, b: []const u8, fold_case: bool) bool {
    return if (fold_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn testList(arena: Allocator, base: []const u8, contents: []const u8) !*PatternList {
    const list = try arena.create(PatternList);
    list.* = try PatternList.parse(arena, base, contents);
    return list;
}

test "gitignore parsing handles comments, escapes, trailing spaces, BOM and CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try testList(arena, "", "# comment\n\n\\#hash\n\\!bang\ntrail   \nkeep\\ \n!neg\ndir/\n/anchored\n  \n");
    const texts = [_][]const u8{ "\\#hash", "\\!bang", "trail", "keep\\ ", "neg", "dir", "/anchored" };
    try std.testing.expectEqual(texts.len, list.patterns.len);
    for (texts, list.patterns) |expected, pattern| try std.testing.expectEqualStrings(expected, pattern.text);
    try std.testing.expect(list.patterns[4].negative);
    try std.testing.expect(list.patterns[5].must_be_dir);
    try std.testing.expect(!list.patterns[6].basename_only);

    const crlf = try testList(arena, "", "\xef\xbb\xbfa.log\r\nb\r\n");
    try std.testing.expectEqual(@as(usize, 2), crlf.patterns.len);
    try std.testing.expectEqualStrings("a.log", crlf.patterns[0].text);
    try std.testing.expectEqualStrings("b", crlf.patterns[1].text);
}

test "gitignore decisions follow git's basename, anchoring and directory rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testList(arena, "", "*.log\n/top.txt\nbuild/\ndocs/*.md\na/**/z\n\\#literal\nkeep\\ \n");
    const lists = [_]*const PatternList{root};
    const cases = [_]struct { path: []const u8, is_dir: bool, expected: Decision }{
        .{ .path = "x.log", .is_dir = false, .expected = .excluded },
        .{ .path = "deep/er/x.log", .is_dir = false, .expected = .excluded },
        .{ .path = "top.txt", .is_dir = false, .expected = .excluded },
        .{ .path = "sub/top.txt", .is_dir = false, .expected = .none },
        .{ .path = "build", .is_dir = true, .expected = .excluded },
        .{ .path = "build", .is_dir = false, .expected = .none },
        .{ .path = "sub/build", .is_dir = true, .expected = .excluded },
        .{ .path = "docs/a.md", .is_dir = false, .expected = .excluded },
        .{ .path = "docs/sub/a.md", .is_dir = false, .expected = .none },
        .{ .path = "a/z", .is_dir = false, .expected = .excluded },
        .{ .path = "a/b/c/z", .is_dir = false, .expected = .excluded },
        .{ .path = "#literal", .is_dir = false, .expected = .excluded },
        .{ .path = "keep ", .is_dir = false, .expected = .excluded },
        .{ .path = "keep", .is_dir = false, .expected = .none },
    };
    for (cases) |case| {
        const actual = decide(&lists, case.path, case.is_dir, false);
        if (actual != case.expected) {
            std.debug.print("path={s} dir={} expected={s} actual={s}\n", .{ case.path, case.is_dir, @tagName(case.expected), @tagName(actual) });
            return error.TestExpectedEqual;
        }
    }
}

test "gitignore precedence: deeper lists win, negation re-includes, excluded parents stay excluded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const global = try testList(arena, "", "*.tmp\nsecret\n");
    const info = try testList(arena, "", "!keep.tmp\n");
    const root = try testList(arena, "", "logs/\n*.out\n!important.out\n");
    const sub = try testList(arena, "sub/", "!x.tmp\n/only-here\n");
    const lists = [_]*const PatternList{ global, info, root, sub };

    try std.testing.expectEqual(Decision.excluded, decide(&lists, "a.tmp", false, false));
    try std.testing.expectEqual(Decision.included, decide(&lists, "keep.tmp", false, false));
    try std.testing.expectEqual(Decision.included, decide(&lists, "sub/x.tmp", false, false));
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "x.tmp", false, false));
    try std.testing.expectEqual(Decision.included, decide(&lists, "important.out", false, false));
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "sub/only-here", false, false));
    // A sub list never applies to the directory that holds it.
    try std.testing.expectEqual(Decision.none, decide(&lists, "only-here", false, false));
    // Re-including a file inside an excluded directory does not work in git.
    const reinclude = try testList(arena, "", "logs/\n!logs/keep.txt\n");
    const reinclude_lists = [_]*const PatternList{reinclude};
    try std.testing.expect(isPathExcluded(&reinclude_lists, "logs/keep.txt", false, false));
    try std.testing.expect(isPathExcluded(&lists, "logs/a/b.txt", false, false));
    try std.testing.expect(!isPathExcluded(&lists, "src/a.txt", false, false));
}

test "gitignore case folding applies to patterns and list bases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testList(arena, "", "*.LOG\n/Build/\n");
    const sub = try testList(arena, "Sub/", "x\n");
    const lists = [_]*const PatternList{ root, sub };
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "a.log", false, true));
    try std.testing.expectEqual(Decision.none, decide(&lists, "a.log", false, false));
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "build", true, true));
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "sub/x", false, true));
    try std.testing.expectEqual(Decision.none, decide(&lists, "sub/x", false, false));
}

test "gitignore keeps git's literal-prefix split before double asterisks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Literal head `a`, remainder `**/b` matched as a leading `**/`, so the
    // pattern crosses a slash that a plain wildmatch of `a**/b` would not.
    // Verified against git 2.50: both paths below are ignored.
    const root = try testList(arena, "", "a**/b\nfoo/**\n");
    const lists = [_]*const PatternList{root};
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "a/x/b", false, false));
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "ax/b", false, false));
    try std.testing.expectEqual(Decision.excluded, decide(&lists, "foo/x/y", false, false));
    try std.testing.expectEqual(Decision.none, decide(&lists, "foo", true, false));
    try std.testing.expect(!wildmatch.match("a**/b", "a/x/b", .{ .pathname = true }));
}

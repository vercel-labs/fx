//! Port of git's wildmatch (wildmatch.c), used for ignore patterns and config
//! include conditions. Matching is byte-wise and case folding is ASCII-only,
//! as in git. Quirks are preserved on purpose: parity with git matters more
//! than tidiness here.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");

pub const Flags = struct {
    /// `WM_PATHNAME`: `*`, `?` and bracket expressions never match `/`, and
    /// `**` between slashes matches any number of directories.
    pathname: bool = false,
    /// `WM_CASEFOLD`: ASCII case-insensitive matching.
    casefold: bool = false,
};

const Result = enum { match, no_match, abort_all, abort_to_starstar };

/// Recursive steps one match may take. Git's algorithm backtracks
/// exponentially on patterns such as many chained `**/`, and a repository
/// chooses its own ignore patterns, so a match that runs out counts as no
/// match: the path is listed rather than hidden, and the cost per path stays
/// bounded. Ordinary patterns need a small fraction of this.
const max_steps: u32 = 20_000;

/// Reports whether `text` matches `pattern`. Like git, a NUL byte ends either
/// string.
pub fn match(pattern: []const u8, text: []const u8, flags: Flags) bool {
    var budget: u32 = max_steps;
    const result = doWild(pattern, 0, text, 0, flags, &budget);
    if (budget == 0 and result != .match) {
        debug_trace.logf("indexer", "wildmatch step budget exhausted pattern_bytes={d} text_bytes={d}", .{ pattern.len, text.len });
    }
    return result == .match;
}

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn isGlobSpecial(c: u8) bool {
    return c == '*' or c == '?' or c == '[' or c == '\\';
}

fn hasSlashFrom(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len and s[i] != 0) : (i += 1) {
        if (s[i] == '/') return i;
    }
    return null;
}

fn doWild(pattern: []const u8, p_start: usize, text: []const u8, t_start: usize, flags: Flags, budget: *u32) Result {
    if (budget.* == 0) return .abort_all;
    budget.* -= 1;
    var p = p_start;
    var t = t_start;
    outer: while (at(pattern, p) != 0) : ({
        t += 1;
        p += 1;
    }) {
        var p_ch = at(pattern, p);
        var t_ch = at(text, t);
        if (t_ch == 0 and p_ch != '*') return .abort_all;
        if (flags.casefold) {
            t_ch = lower(t_ch);
            p_ch = lower(p_ch);
        }
        switch (p_ch) {
            '\\' => {
                // Literal match with the following character, which git does
                // not case-fold.
                p += 1;
                if (t_ch != at(pattern, p)) return .no_match;
            },
            '?' => {
                if (flags.pathname and t_ch == '/') return .no_match;
            },
            '*' => {
                p += 1;
                var match_slash: bool = undefined;
                if (at(pattern, p) == '*') {
                    const prev_is_boundary = p < p_start + 2 or pattern[p - 2] == '/';
                    while (at(pattern, p) == '*') p += 1;
                    const next = at(pattern, p);
                    if (prev_is_boundary and (next == 0 or next == '/' or
                        (next == '\\' and at(pattern, p + 1) == '/')))
                    {
                        // `**/` may match no directories at all.
                        if (next == '/' and doWild(pattern, p + 1, text, t, flags, budget) == .match) return .match;
                        match_slash = true;
                    } else {
                        match_slash = !flags.pathname;
                    }
                } else {
                    match_slash = !flags.pathname;
                }

                const next = at(pattern, p);
                if (next == 0) {
                    // A trailing `**` matches everything; a trailing `*` only
                    // when no slash remains.
                    if (!match_slash and hasSlashFrom(text, t) != null) return .no_match;
                    return .match;
                } else if (!match_slash and next == '/') {
                    // One `*` followed by a slash matches the next directory;
                    // the loop's increment consumes both slashes.
                    t = hasSlashFrom(text, t) orelse return .no_match;
                    continue :outer;
                }

                while (true) {
                    if (t_ch == 0) break;
                    // Skip ahead to the next occurrence of a literal that
                    // follows the asterisk.
                    if (!isGlobSpecial(at(pattern, p))) {
                        var literal = at(pattern, p);
                        if (flags.casefold) literal = lower(literal);
                        while (true) {
                            t_ch = at(text, t);
                            if (t_ch == 0) break;
                            if (!match_slash and t_ch == '/') break;
                            if (flags.casefold) t_ch = lower(t_ch);
                            if (t_ch == literal) break;
                            t += 1;
                        }
                        if (t_ch != literal) return if (match_slash) .abort_all else .abort_to_starstar;
                    }
                    const matched = doWild(pattern, p, text, t, flags, budget);
                    if (matched != .no_match) {
                        if (!match_slash or matched != .abort_to_starstar) return matched;
                    } else if (!match_slash and t_ch == '/') {
                        return .abort_to_starstar;
                    }
                    t += 1;
                    t_ch = at(text, t);
                }
                return .abort_all;
            },
            '[' => {
                p += 1;
                p_ch = at(pattern, p);
                if (p_ch == '^') p_ch = '!';
                const negated = p_ch == '!';
                if (negated) {
                    p += 1;
                    p_ch = at(pattern, p);
                }
                var prev_ch: u8 = 0;
                var matched = false;
                // Mirrors git's do-while: the first member may be `]`.
                while (true) {
                    if (p_ch == 0) return .abort_all;
                    if (p_ch == '\\') {
                        p += 1;
                        p_ch = at(pattern, p);
                        if (p_ch == 0) return .abort_all;
                        if (t_ch == p_ch) matched = true;
                    } else if (p_ch == '-' and prev_ch != 0 and at(pattern, p + 1) != 0 and at(pattern, p + 1) != ']') {
                        p += 1;
                        p_ch = at(pattern, p);
                        if (p_ch == '\\') {
                            p += 1;
                            p_ch = at(pattern, p);
                            if (p_ch == 0) return .abort_all;
                        }
                        if (t_ch <= p_ch and t_ch >= prev_ch) {
                            matched = true;
                        } else if (flags.casefold and std.ascii.isLower(t_ch)) {
                            const upper = std.ascii.toUpper(t_ch);
                            if (upper <= p_ch and upper >= prev_ch) matched = true;
                        }
                        p_ch = 0;
                    } else if (p_ch == '[' and at(pattern, p + 1) == ':') {
                        p += 2;
                        const class_start = p;
                        while (at(pattern, p) != 0 and at(pattern, p) != ']') p += 1;
                        p_ch = at(pattern, p);
                        if (p_ch == 0) return .abort_all;
                        if (p < class_start + 1 or pattern[p - 1] != ':') {
                            // No closing `:]`: treat `[` as a plain member.
                            p = class_start - 2;
                            p_ch = '[';
                            if (t_ch == p_ch) matched = true;
                        } else {
                            const class = pattern[class_start .. p - 1];
                            const in_class = classMatches(class, t_ch, flags.casefold) orelse return .abort_all;
                            if (in_class) matched = true;
                            p_ch = 0;
                        }
                    } else if (t_ch == p_ch) {
                        matched = true;
                    }
                    prev_ch = p_ch;
                    p += 1;
                    p_ch = at(pattern, p);
                    if (p_ch == ']') break;
                }
                if (matched == negated or (flags.pathname and t_ch == '/')) return .no_match;
            },
            else => {
                if (t_ch != p_ch) return .no_match;
            },
        }
    }
    return if (at(text, t) != 0) .no_match else .match;
}

/// Returns whether `c` belongs to the POSIX class, or null for an unknown
/// class name, which git treats as a malformed pattern.
fn classMatches(class: []const u8, c: u8, casefold: bool) ?bool {
    const eql = std.mem.eql;
    if (eql(u8, class, "alnum")) return std.ascii.isAlphanumeric(c);
    if (eql(u8, class, "alpha")) return std.ascii.isAlphabetic(c);
    if (eql(u8, class, "blank")) return c == ' ' or c == '\t';
    if (eql(u8, class, "cntrl")) return c < 0x20 or c == 0x7f;
    if (eql(u8, class, "digit")) return std.ascii.isDigit(c);
    if (eql(u8, class, "graph")) return c > 0x20 and c < 0x7f;
    if (eql(u8, class, "lower")) return std.ascii.isLower(c);
    if (eql(u8, class, "print")) return c >= 0x20 and c < 0x7f;
    if (eql(u8, class, "punct")) return c > 0x20 and c < 0x7f and !std.ascii.isAlphanumeric(c);
    if (eql(u8, class, "space")) return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    if (eql(u8, class, "upper")) return std.ascii.isUpper(c) or (casefold and std.ascii.isLower(c));
    if (eql(u8, class, "xdigit")) return std.ascii.isHex(c);
    return null;
}

const Case = struct { pattern: []const u8, text: []const u8, expected: bool };

fn expectCases(cases: []const Case, flags: Flags) !void {
    for (cases) |case| {
        if (match(case.pattern, case.text, flags) != case.expected) {
            std.debug.print("pattern={s} text={s} expected={}\n", .{ case.pattern, case.text, case.expected });
            return error.TestExpectedEqual;
        }
    }
}

test "wildmatch literal, single-character and bracket rules" {
    try expectCases(&.{
        .{ .pattern = "foo", .text = "foo", .expected = true },
        .{ .pattern = "foo", .text = "bar", .expected = false },
        .{ .pattern = "", .text = "", .expected = true },
        .{ .pattern = "???", .text = "foo", .expected = true },
        .{ .pattern = "??", .text = "foo", .expected = false },
        .{ .pattern = "*", .text = "foo", .expected = true },
        .{ .pattern = "f*", .text = "foo", .expected = true },
        .{ .pattern = "*f", .text = "foo", .expected = false },
        .{ .pattern = "*foo*", .text = "foo", .expected = true },
        .{ .pattern = "*ob*a*r*", .text = "foobar", .expected = true },
        .{ .pattern = "*ab", .text = "aaaaaaabababab", .expected = true },
        .{ .pattern = "foo\\*", .text = "foo*", .expected = true },
        .{ .pattern = "foo\\*bar", .text = "foobar", .expected = false },
        .{ .pattern = "f\\\\oo", .text = "f\\oo", .expected = true },
        .{ .pattern = "*[al]?", .text = "ball", .expected = true },
        .{ .pattern = "[ten]", .text = "ten", .expected = false },
        .{ .pattern = "t[a-g]n", .text = "ten", .expected = true },
        .{ .pattern = "t[!a-g]n", .text = "ten", .expected = false },
        .{ .pattern = "t[!a-g]n", .text = "ton", .expected = true },
        .{ .pattern = "t[^a-g]n", .text = "ton", .expected = true },
        .{ .pattern = "a[]]b", .text = "a]b", .expected = true },
        .{ .pattern = "a[]-]b", .text = "a-b", .expected = true },
        .{ .pattern = "a[]-]b", .text = "aab", .expected = false },
        .{ .pattern = "a[]a-]b", .text = "aab", .expected = true },
        .{ .pattern = "]", .text = "]", .expected = true },
        .{ .pattern = "[[:digit:]]x", .text = "7x", .expected = true },
        .{ .pattern = "[[:digit:]]x", .text = "ax", .expected = false },
        .{ .pattern = "[[:bogus:]]", .text = "a", .expected = false },
        .{ .pattern = "[abc", .text = "a", .expected = false },
    }, .{ .pathname = true });
}

test "wildmatch pathname rules for slashes and double asterisks" {
    try expectCases(&.{
        .{ .pattern = "foo*bar", .text = "foo/baz/bar", .expected = false },
        .{ .pattern = "foo**bar", .text = "foo/baz/bar", .expected = false },
        .{ .pattern = "foo**bar", .text = "foobazbar", .expected = true },
        .{ .pattern = "foo/**/bar", .text = "foo/baz/bar", .expected = true },
        .{ .pattern = "foo/**/bar", .text = "foo/b/a/z/bar", .expected = true },
        .{ .pattern = "foo/**/bar", .text = "foo/bar", .expected = true },
        .{ .pattern = "foo/**/**/bar", .text = "foo/bar", .expected = true },
        .{ .pattern = "foo?bar", .text = "foo/bar", .expected = false },
        .{ .pattern = "foo[/]bar", .text = "foo/bar", .expected = false },
        .{ .pattern = "foo[^a-z]bar", .text = "foo/bar", .expected = false },
        .{ .pattern = "**/foo", .text = "foo", .expected = true },
        .{ .pattern = "**/foo", .text = "bar/baz/foo", .expected = true },
        .{ .pattern = "*/foo", .text = "bar/baz/foo", .expected = false },
        .{ .pattern = "**/bar*", .text = "foo/bar/baz", .expected = false },
        .{ .pattern = "**/bar/*", .text = "deep/foo/bar/baz", .expected = true },
        .{ .pattern = "**/bar/*", .text = "deep/foo/bar/baz/", .expected = false },
        .{ .pattern = "**/bar/**", .text = "deep/foo/bar/baz/", .expected = true },
        .{ .pattern = "**/bar/*", .text = "deep/foo/bar", .expected = false },
        .{ .pattern = "**/bar**", .text = "foo/bar/baz", .expected = false },
        .{ .pattern = "*/bar/**", .text = "foo/bar/baz/x", .expected = true },
        .{ .pattern = "*/bar/**", .text = "deep/foo/bar/baz/x", .expected = false },
        .{ .pattern = "**", .text = "a/b/c", .expected = true },
        .{ .pattern = "a/*", .text = "a/b/c", .expected = false },
    }, .{ .pathname = true });
}

test "wildmatch case folding is ASCII-only and keeps git's escape quirk" {
    try expectCases(&.{
        .{ .pattern = "FOO", .text = "foo", .expected = true },
        .{ .pattern = "f*O", .text = "Foo", .expected = true },
        .{ .pattern = "[a-c]x", .text = "Bx", .expected = true },
        .{ .pattern = "[[:upper:]]x", .text = "bx", .expected = true },
        // git compares an escaped character without folding it.
        .{ .pattern = "\\Ax", .text = "ax", .expected = false },
        .{ .pattern = "\xc3\x89", .text = "\xc3\xa9", .expected = false },
    }, .{ .pathname = true, .casefold = true });
}

test "wildmatch stops at a NUL byte like git's C strings" {
    try std.testing.expect(match("ab\x00zz", "ab", .{ .pathname = true }));
}

test "hostile patterns stop at the step budget instead of backtracking forever" {
    const long_text = "a/" ** 200 ++ "b";
    const hostile = [_][]const u8{ "*/" ** 40 ++ "c", "**/" ** 30 ++ "c", "*a*a*a*a*a*a*a*a*a*a*a*a*c", "a/**/a/**/a/**/a/**/a/**/a/**/c" };
    for (hostile) |pattern| {
        try std.testing.expect(!match(pattern, long_text, .{ .pathname = true }));
        try std.testing.expect(!match(pattern, long_text, .{}));
    }
    // Ordinary patterns on a long path still match.
    try std.testing.expect(match("**/b", long_text, .{ .pathname = true }));
    try std.testing.expect(match("a/**/a/b", long_text, .{ .pathname = true }));
}

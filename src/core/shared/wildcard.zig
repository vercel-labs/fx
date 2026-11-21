const std = @import("std");

/// Matches a permission-rule pattern against a candidate: `*` matches any run of characters, including none, and `?` matches one character. Everything else matches itself.
pub fn match(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == candidate[candidate_index]))
        {
            pattern_index += 1;
            candidate_index += 1;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_candidate_index = candidate_index;
            continue;
        }

        const star = star_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = star + 1;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

test "wildcard match follows permission rule patterns" {
    try std.testing.expect(match("*", ""));
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("?", "a"));
    try std.testing.expect(!match("?", ""));
    try std.testing.expect(!match("?", "ab"));
    try std.testing.expect(match("npm test*", "npm test"));
    try std.testing.expect(match("npm test*", "npm test --watch"));
    try std.testing.expect(!match("npm test*", "npm install"));
    try std.testing.expect(match("git status", "git status"));
    try std.testing.expect(!match("git status", "git status -s"));
}

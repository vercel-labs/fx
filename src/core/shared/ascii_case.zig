//! ASCII case-insensitive search. It imports only `std`, so modules that
//! must stay free of fx's I/O, such as the fuzzy matcher, can share it with
//! `text_utils.zig`.

const std = @import("std");

/// Whether `haystack` contains `needle`, ignoring ASCII case. Linear on
/// purpose: `std.ascii.findIgnoreCase` fills a 2 KiB skip table on every
/// call, which costs more than the short fields menus search take to scan.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const first = std.ascii.toLower(needle[0]);
    const rest = needle[1..];
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.toLower(haystack[start]) != first) continue;
        if (std.ascii.eqlIgnoreCase(haystack[start + 1 ..][0..rest.len], rest)) return true;
    }
    return false;
}

test "containsIgnoreCase finds a needle anywhere, ignoring ASCII case" {
    try std.testing.expect(containsIgnoreCase("Session/Model-Picker", "model"));
    try std.testing.expect(containsIgnoreCase("fx-commit", "FX-C"));
    try std.testing.expect(containsIgnoreCase("abc", "abc"));
    try std.testing.expect(containsIgnoreCase("abc", ""));
    try std.testing.expect(containsIgnoreCase("", ""));
    try std.testing.expect(!containsIgnoreCase("ab", "abc"));
    try std.testing.expect(!containsIgnoreCase("aab", "abb"));
    try std.testing.expect(!containsIgnoreCase("", "a"));
}

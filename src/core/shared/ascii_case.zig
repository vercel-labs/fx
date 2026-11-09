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

/// Whether `text` holds `family`, ignoring case, followed by a version whose
/// major number is `min_major` or more, such as `openai/gpt-6.1-sol` for
/// `gpt-` at 5. A model check written this way keeps matching each new major
/// release. `family` must not be empty.
pub fn hasMajorVersionAtLeast(text: []const u8, family: []const u8, min_major: u32) bool {
    std.debug.assert(family.len > 0);
    var start: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, start, family)) |found| {
        start = found + family.len;
        var end = start;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        const major = std.fmt.parseUnsigned(u32, text[start..end], 10) catch continue;
        if (major >= min_major) return true;
    }
    return false;
}

test "hasMajorVersionAtLeast reads the major version after the family" {
    for ([_][]const u8{ "openai/gpt-5", "openai/gpt-5.4-mini", "openai/gpt-6.1-sol", "openai/GPT-10" }) |text| {
        try std.testing.expect(hasMajorVersionAtLeast(text, "gpt-", 5));
    }
    for ([_][]const u8{ "openai/gpt-4.1", "openai/gpt-4o", "openai/gpt-oss-120b", "openai/gpt-", "openai/o3" }) |text| {
        try std.testing.expect(!hasMajorVersionAtLeast(text, "gpt-", 5));
    }
    try std.testing.expect(hasMajorVersionAtLeast("xai/grok-4.20-reasoning", "grok-", 4));
    try std.testing.expect(!hasMajorVersionAtLeast("xai/grok-code-fast-1", "grok-", 4));
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

//! A nesting limit for JSON that a provider sends, and for an MCP config file
//! that `fx mcp add` and `remove` rewrite, checked on the raw text before fx
//! stringifies or walks the parsed value. std.json parses any depth, but
//! std.json.Stringify stops past 256 levels in safe builds, and a recursive
//! walk can run out of stack, so
//! text deeper than this must never reach either one.
const std = @import("std");
const text_utils = @import("text_utils.zig");

/// Deep enough for any real tool input or provider metadata, and far enough
/// under Stringify's 256 levels that fx can wrap a value when it saves it.
pub const max_depth = 64;

/// Whether `text` nests objects and arrays deeper than `max_depth`. Brackets
/// inside strings do not count, and a stray closer never drops below zero.
pub fn exceeds(text: []const u8) bool {
    return exceedsDepth(text, max_depth);
}

/// The same for any limit: whether `text` nests deeper than `max` levels.
pub fn exceedsDepth(text: []const u8, max: usize) bool {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (text) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == max) return true;
                depth += 1;
            },
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

test "json depth allows the limit and rejects one level past it" {
    const at_limit = text_utils.repeat("[", max_depth) ++ text_utils.repeat("]", max_depth);
    const past_limit = text_utils.repeat("[", max_depth + 1) ++ text_utils.repeat("]", max_depth + 1);
    try std.testing.expect(!exceeds(at_limit));
    try std.testing.expect(exceeds(past_limit));
    try std.testing.expect(exceeds("{\"a\":" ++ text_utils.repeat("{\"a\":", max_depth) ++ "0" ++ text_utils.repeat("}", max_depth + 1)));
}

test "json depth ignores brackets in strings and stray closers" {
    const quoted = "{\"text\":\"" ++ text_utils.repeat("[{", 200) ++ "\\\"\"}";
    try std.testing.expect(!exceeds(quoted));
    try std.testing.expect(!exceeds(text_utils.repeat("]}", 200) ++ "[]"));
    // Sequential objects never nest, however many there are.
    try std.testing.expect(!exceeds(text_utils.repeat("{}", 10_000)));
}

test "json depth takes any limit, and the default is max_depth" {
    const nested_128 = text_utils.repeat("[", 128) ++ text_utils.repeat("]", 128);
    const nested_129 = text_utils.repeat("[", 129) ++ text_utils.repeat("]", 129);
    try std.testing.expect(!exceedsDepth(nested_128, 128));
    try std.testing.expect(exceedsDepth(nested_129, 128));
    try std.testing.expect(exceedsDepth(nested_128, 127));
    try std.testing.expect(!exceedsDepth("[]", 1));
    try std.testing.expect(exceedsDepth("[[]]", 1));
    // Zero levels allowed: any container is too deep, a scalar and a string with brackets are not.
    try std.testing.expect(exceedsDepth("{}", 0));
    try std.testing.expect(!exceedsDepth("\"[{\"", 0));
    for ([_][]const u8{ nested_128, nested_129, "[[[]]]", "{\"a\":[1]}" }) |text| {
        try std.testing.expectEqual(exceedsDepth(text, max_depth), exceeds(text));
    }
}

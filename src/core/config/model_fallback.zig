const std = @import("std");

/// Circuit-breaker pairs: when the primary route is provably down, the agent
/// runtime fails over to the paired model for the rest of the turn instead of
/// pausing recovery. Keys are exact model ids; values are the failover ids.
const pairs = [_][2][]const u8{
    .{ "openpaths/stealth/ox-alpha", "deepseek-v4-flash-vision-exp" },
    .{ "stealth/ox-alpha", "deepseek/deepseek-v4-flash-vision-exp" },
};

pub fn fallbackFor(model: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, model, pair[0])) return pair[1];
    }
    return null;
}

test "circuit breaker maps stealth ox alpha to deepseek flash exp" {
    try std.testing.expectEqualStrings(
        "deepseek-v4-flash-vision-exp",
        fallbackFor("openpaths/stealth/ox-alpha").?,
    );
    try std.testing.expectEqualStrings(
        "deepseek/deepseek-v4-flash-vision-exp",
        fallbackFor("stealth/ox-alpha").?,
    );
}

test "circuit breaker ignores unknown models and the fallback targets themselves" {
    try std.testing.expect(fallbackFor("zai/glm-5.2") == null);
    try std.testing.expect(fallbackFor("deepseek-v4-flash-vision-exp") == null);
    try std.testing.expect(fallbackFor("") == null);
}

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const interval_secs_env = "FX_E2E_LOOP_INTERVAL_SECS";
const gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";

/// Returns the production interval unless an explicit E2E-only override is paired
/// with a loopback Gateway fixture. The override stays bounded so it cannot hot-loop.
pub fn interval_secs(default_secs: u64) u64 {
    return interval_secs_from_values(
        io_mod.getenv(interval_secs_env),
        io_mod.getenv(gateway_models_url_env),
        default_secs,
    );
}

fn interval_secs_from_values(
    value: ?[]const u8,
    gateway_models_url: ?[]const u8,
    default_secs: u64,
) u64 {
    if (!is_loopback_http_url(gateway_models_url orelse return default_secs)) {
        return default_secs;
    }
    const text = value orelse return default_secs;
    const parsed = std.fmt.parseInt(u64, text, 10) catch return default_secs;
    if (parsed == 0 or parsed > 60) return default_secs;
    return parsed;
}

fn is_loopback_http_url(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://127.0.0.1:") or
        std.mem.startsWith(u8, url, "http://[::1]:") or
        std.mem.startsWith(u8, url, "http://localhost:");
}

test "loop interval E2E override requires a loopback fixture and stays bounded" {
    const loopback = "http://127.0.0.1:1234/coding-agent/v1/models";
    try std.testing.expectEqual(@as(u64, 300), interval_secs_from_values(null, loopback, 300));
    try std.testing.expectEqual(@as(u64, 1), interval_secs_from_values("1", loopback, 300));
    try std.testing.expectEqual(@as(u64, 300), interval_secs_from_values("1", null, 300));
    try std.testing.expectEqual(
        @as(u64, 300),
        interval_secs_from_values("1", "https://ai-gateway.vercel.sh/v1/models", 300),
    );
    try std.testing.expectEqual(@as(u64, 300), interval_secs_from_values("0", loopback, 300));
    try std.testing.expectEqual(@as(u64, 300), interval_secs_from_values("61", loopback, 300));
    try std.testing.expectEqual(@as(u64, 300), interval_secs_from_values("invalid", loopback, 300));
}

const std = @import("std");

/// Minimum interval in seconds. Sub-minute values are clamped to this floor so
/// the scheduler cannot hot-loop. Matches the product contract: /loop is for
/// polling and babysitting, not for sub-second polling.
const minimum_interval_secs: u64 = 60;

/// Parse an interval string like "5m", "2h", "30s", "1d" into seconds.
/// The minimum interval is 60 seconds; values below are clamped.
pub fn parse_interval(s: []const u8) error{InvalidInterval}!u64 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidInterval;

    const digits = trimmed[0 .. trimmed.len - 1];
    const suffix = trimmed[trimmed.len - 1];

    const value = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidInterval;
    if (value == 0) return error.InvalidInterval;

    const unit_secs: u64 = switch (suffix) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return error.InvalidInterval,
    };

    const secs = std.math.mul(u64, value, unit_secs) catch return error.InvalidInterval;
    return @max(secs, minimum_interval_secs);
}

/// Convert seconds to a human-readable interval string.
/// e.g. 300 -> "every 5 minutes", 3600 -> "every 1 hour".
/// Caller frees the returned slice with `alloc`.
pub fn interval_to_human_alloc(alloc: std.mem.Allocator, secs: u64) ![]u8 {
    if (secs % 86400 == 0) {
        const n = secs / 86400;
        return switch (n) {
            1 => alloc.dupe(u8, "every 1 day"),
            else => std.fmt.allocPrint(alloc, "every {d} days", .{n}),
        };
    }
    if (secs % 3600 == 0) {
        const n = secs / 3600;
        return switch (n) {
            1 => alloc.dupe(u8, "every 1 hour"),
            else => std.fmt.allocPrint(alloc, "every {d} hours", .{n}),
        };
    }
    if (secs % 60 == 0) {
        const n = secs / 60;
        return switch (n) {
            1 => alloc.dupe(u8, "every 1 minute"),
            else => std.fmt.allocPrint(alloc, "every {d} minutes", .{n}),
        };
    }
    if (secs == 1) return alloc.dupe(u8, "every 1 second");
    return std.fmt.allocPrint(alloc, "every {d} seconds", .{secs});
}

/// Whether a token is a schedulable interval: non-zero digits followed by one
/// of s/m/h/d. Zero is rejected so the preview never shows a cadence the tool
/// would reject. Used by the slash command parser to extract a leading token.
pub fn is_interval_token(s: []const u8) bool {
    if (s.len < 2) return false;
    const digits = s[0 .. s.len - 1];
    const suffix = s[s.len - 1];
    switch (suffix) {
        's', 'm', 'h', 'd' => {},
        else => return false,
    }
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    const value = std.fmt.parseInt(u64, digits, 10) catch return false;
    return value > 0;
}

test "parse minutes" {
    try std.testing.expectEqual(@as(u64, 300), try parse_interval("5m"));
    try std.testing.expectEqual(@as(u64, 600), try parse_interval("10m"));
    try std.testing.expectEqual(@as(u64, 60), try parse_interval("1m"));
}

test "parse hours" {
    try std.testing.expectEqual(@as(u64, 7200), try parse_interval("2h"));
    try std.testing.expectEqual(@as(u64, 3600), try parse_interval("1h"));
}

test "parse days" {
    try std.testing.expectEqual(@as(u64, 86400), try parse_interval("1d"));
    try std.testing.expectEqual(@as(u64, 604800), try parse_interval("7d"));
}

test "parse seconds clamped to minimum" {
    try std.testing.expectEqual(@as(u64, 60), try parse_interval("30s"));
    try std.testing.expectEqual(@as(u64, 60), try parse_interval("1s"));
    try std.testing.expectEqual(@as(u64, 60), try parse_interval("60s"));
    try std.testing.expectEqual(@as(u64, 120), try parse_interval("120s"));
}

test "parse empty returns error" {
    try std.testing.expectError(error.InvalidInterval, parse_interval(""));
    try std.testing.expectError(error.InvalidInterval, parse_interval("   "));
}

test "parse invalid format returns error" {
    try std.testing.expectError(error.InvalidInterval, parse_interval("abc"));
    try std.testing.expectError(error.InvalidInterval, parse_interval("5x"));
    try std.testing.expectError(error.InvalidInterval, parse_interval("m"));
}

test "parse zero returns error" {
    try std.testing.expectError(error.InvalidInterval, parse_interval("0m"));
    try std.testing.expectError(error.InvalidInterval, parse_interval("0s"));
}

test "parse overflow returns error" {
    // Digits parse as u64 but the unit multiplication overflows.
    try std.testing.expectError(error.InvalidInterval, parse_interval("1000000000000000000d"));
    try std.testing.expectError(error.InvalidInterval, parse_interval("9999999999999999999999999999999999d"));
}

test "parse with whitespace" {
    try std.testing.expectEqual(@as(u64, 300), try parse_interval("  5m  "));
}

test "interval_to_human_alloc formats" {
    const alloc = std.testing.allocator;

    const m5 = try interval_to_human_alloc(alloc, 300);
    defer alloc.free(m5);
    try std.testing.expectEqualStrings("every 5 minutes", m5);

    const m1 = try interval_to_human_alloc(alloc, 60);
    defer alloc.free(m1);
    try std.testing.expectEqualStrings("every 1 minute", m1);

    const h2 = try interval_to_human_alloc(alloc, 7200);
    defer alloc.free(h2);
    try std.testing.expectEqualStrings("every 2 hours", h2);

    const h1 = try interval_to_human_alloc(alloc, 3600);
    defer alloc.free(h1);
    try std.testing.expectEqualStrings("every 1 hour", h1);

    const d1 = try interval_to_human_alloc(alloc, 86400);
    defer alloc.free(d1);
    try std.testing.expectEqualStrings("every 1 day", d1);

    const d7 = try interval_to_human_alloc(alloc, 604800);
    defer alloc.free(d7);
    try std.testing.expectEqualStrings("every 7 days", d7);

    const s60 = try interval_to_human_alloc(alloc, 60);
    defer alloc.free(s60);
    try std.testing.expectEqualStrings("every 1 minute", s60);
}

test "is_interval_token accepts valid tokens" {
    try std.testing.expect(is_interval_token("5m"));
    try std.testing.expect(is_interval_token("2h"));
    try std.testing.expect(is_interval_token("1d"));
    try std.testing.expect(is_interval_token("60s"));
    try std.testing.expect(is_interval_token("999m"));
}

test "is_interval_token rejects malformed tokens" {
    // Bad suffix
    try std.testing.expect(!is_interval_token("5x"));
    // No suffix
    try std.testing.expect(!is_interval_token("5"));
    // Too short / no digits
    try std.testing.expect(!is_interval_token("m"));
    try std.testing.expect(!is_interval_token("s"));
    // Multi-char suffix
    try std.testing.expect(!is_interval_token("55mm"));
    // Zero value
    try std.testing.expect(!is_interval_token("0m"));
    try std.testing.expect(!is_interval_token("0s"));
    // Alphabetic
    try std.testing.expect(!is_interval_token("abc"));
    // Empty
    try std.testing.expect(!is_interval_token(""));
}

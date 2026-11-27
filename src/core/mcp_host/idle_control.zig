//! The idle limit of an MCP server: ten minutes after its last use, so
//! servers left behind by old sessions stop instead of holding a process
//! each. `FX_TEST_MCP_IDLE_MS`, a positive number of milliseconds, replaces
//! it; only tests set that, so a real profile keeps the ten minutes
//! (`tests/e2e/mcp-stdio.test.ts`, "an idle stdio server stops and the next
//! call starts it again").
const std = @import("std");
const io_mod = @import("../shared/io.zig");

/// Ten minutes: long enough that a person who comes back to a terminal finds
/// its servers running, short enough that a forgotten one stops.
const default_idle_ms: u32 = 600_000;

/// How long a server may hold nothing before it stops, in milliseconds.
pub fn idleMs() u32 {
    return parseIdleMs(io_mod.getenv("FX_TEST_MCP_IDLE_MS"));
}

/// The limit `text` names, or ten minutes when it is absent, not a number,
/// or not a positive one that fits.
fn parseIdleMs(text: ?[]const u8) u32 {
    const value = text orelse return default_idle_ms;
    const ms = std.fmt.parseInt(u32, value, 10) catch return default_idle_ms;
    return if (ms > 0) ms else default_idle_ms;
}

test "the idle limit is ten minutes unless a positive number of milliseconds is given" {
    try std.testing.expectEqual(@as(u32, 600_000), parseIdleMs(null));
    try std.testing.expectEqual(@as(u32, 300), parseIdleMs("300"));
    try std.testing.expectEqual(@as(u32, 600_000), parseIdleMs("0"));
    try std.testing.expectEqual(@as(u32, 600_000), parseIdleMs("-5"));
    try std.testing.expectEqual(@as(u32, 600_000), parseIdleMs("abc"));
    try std.testing.expectEqual(@as(u32, 600_000), parseIdleMs(""));
    try std.testing.expectEqual(@as(u32, 600_000), parseIdleMs("99999999999"));
}

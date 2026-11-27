//! Test controls for MCP owner spawning in `src/core/mcp_host/owner_client.zig`.
//! Tests set `spawn_hook` to drive an in-process owner thread with a ready
//! pipe; outside test builds the field compiles to `void`.
const std = @import("std");
const builtin = @import("builtin");

pub const SpawnHook = *const fn (
    io: std.Io,
    fx_home: []const u8,
    ready_write_fd: std.posix.fd_t,
) ?std.c.pid_t;

/// Test builds only: overrides `Client.spawn` so unit tests can drive an
/// in-process owner thread with a real ready pipe.
pub var spawn_hook: if (builtin.is_test) ?SpawnHook else void = if (builtin.is_test) null else {};

test "a test build starts with an empty spawn hook" {
    try std.testing.expect(spawn_hook == null);
}

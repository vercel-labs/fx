//! Test controls for MCP owner spawning in `src/core/mcp_host/owner_client.zig`.
//! Tests set these hooks to drive in-process owner threads and inspect
//! `Client.ensureReady` without wall-clock speed assumptions; outside test
//! builds every field compiles to `void`.
const std = @import("std");
const builtin = @import("builtin");

pub const ReadyOutcome = enum { ready, eof, timeout };

pub const SpawnHook = *const fn (
    io: std.Io,
    fx_home: []const u8,
    ready_write_fd: std.posix.fd_t,
) ?std.c.pid_t;

/// Test builds only: overrides `Client.spawn` so unit tests can drive an
/// in-process owner thread with a real ready pipe.
pub var spawn_hook: if (builtin.is_test) ?SpawnHook else void = if (builtin.is_test) null else {};

/// Test builds only: called in `owner.serveInternal` once its Unix socket is
/// listening with 0o600 permissions.
pub var on_listening_hook: if (builtin.is_test) ?*const fn (io: std.Io) void else void = if (builtin.is_test) null else {};

/// Test builds only: called in `Client.ensureReady` after each `connect` probe.
pub var on_connect_attempt: if (builtin.is_test) ?*const fn (connected: bool) void else void = if (builtin.is_test) null else {};

/// Test builds only: called in `Client.ensureReady` when `waitReadyPipe` returns.
pub var on_ready_outcome: if (builtin.is_test) ?*const fn (outcome: ReadyOutcome) void else void = if (builtin.is_test) null else {};

/// Test builds only: overrides `Client.now` when set.
pub var now_ms_hook: if (builtin.is_test) ?*const fn () i64 else void = if (builtin.is_test) null else {};

/// Test builds only: overrides `Client.ensureReady`'s backoff sleep when set.
pub var sleep_ms_hook: if (builtin.is_test) ?*const fn (pause_ms: u64) void else void = if (builtin.is_test) null else {};

test "a test build starts with empty owner test hooks" {
    try std.testing.expect(spawn_hook == null);
    try std.testing.expect(on_listening_hook == null);
    try std.testing.expect(on_connect_attempt == null);
    try std.testing.expect(on_ready_outcome == null);
    try std.testing.expect(now_ms_hook == null);
    try std.testing.expect(sleep_ms_hook == null);
}

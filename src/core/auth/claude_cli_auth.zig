const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Overrides the `claude` executable. Tests point it at a stand-in script.
pub const binary_env = "FX_CLAUDE_BIN";

const max_status_bytes: usize = 64 * 1024;
const probe_ttl_ms: i64 = 30 * 1000;
/// A failed probe is remembered briefly so a hung CLI costs one timeout, not one
/// per status check.
const probe_failure_ttl_ms: i64 = 5 * 1000;
const probe_timeout_ms: i64 = 10 * 1000;
const max_cached_account_bytes = 256;

/// Variables that would point Claude Code at an API account, another cloud, or
/// another endpoint instead of the subscription the user signed in with.
const account_overrides = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
};

pub fn scrubAccountOverrides(map: *std.process.Environ.Map) void {
    for (account_overrides) |name| _ = map.swapRemove(name);
}

/// The environment for every `claude` command fx starts, with account overrides
/// removed so the sign-in check and the turns see the same account. Failing to
/// copy the environment fails the command: inheriting it unchanged could charge
/// the wrong account. The caller frees it with `deinit`.
pub fn scrubbedEnvironment(alloc: Allocator) error{ OutOfMemory, EnvironmentUnavailable }!std.process.Environ.Map {
    var map = io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EnvironmentUnavailable,
    };
    scrubAccountOverrides(&map);
    return map;
}

pub fn binaryPath() []const u8 {
    const configured = io_mod.getenv(binary_env) orelse return "claude";
    return if (configured.len == 0) "claude" else configured;
}

/// What `claude auth status` reports about the signed-in account. fx never
/// reads, stores, or forwards the CLI's tokens; the CLI owns them.
pub const Status = struct {
    /// Stable, non-secret identity for the signed-in organization.
    account_id: []u8,
    email: ?[]u8 = null,
    subscription_type: ?[]u8 = null,

    pub fn deinit(self: *Status, alloc: Allocator) void {
        alloc.free(self.account_id);
        if (self.email) |value| alloc.free(value);
        if (self.subscription_type) |value| alloc.free(value);
        self.* = undefined;
    }
};

const Wire = struct {
    loggedIn: bool = false,
    email: ?[]const u8 = null,
    orgId: ?[]const u8 = null,
    subscriptionType: ?[]const u8 = null,
};

/// Parses `claude auth status --json`. Returns null when the CLI reports that
/// nobody is signed in. The caller owns the result.
pub fn parseStatus(alloc: Allocator, bytes: []const u8) !?Status {
    var parsed = std.json.parseFromSlice(Wire, alloc, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidClaudeStatus,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    if (!wire.loggedIn) return null;
    const identity = wire.orgId orelse wire.email orelse return error.InvalidClaudeStatus;
    if (!types.validCredentialAccountId(identity)) return error.InvalidClaudeStatus;

    const account_id = try alloc.dupe(u8, identity);
    errdefer alloc.free(account_id);
    const email = if (wire.email) |value| try alloc.dupe(u8, value) else null;
    errdefer if (email) |value| alloc.free(value);
    const subscription_type = if (wire.subscriptionType) |value| try alloc.dupe(u8, value) else null;
    return .{ .account_id = account_id, .email = email, .subscription_type = subscription_type };
}

pub const ProbeError = error{
    ClaudeCliMissing,
    ClaudeCliFailed,
    InvalidClaudeStatus,
    OutOfMemory,
};

/// Asks the CLI who is signed in. Spawns `claude auth status`, so callers on a
/// hot path should use `presence` or `cachedAccountId` instead.
pub fn probe(alloc: Allocator) ProbeError!?Status {
    if (comptime host_target.is_wasm) return null;
    var environment = scrubbedEnvironment(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentUnavailable => return error.ClaudeCliFailed,
    };
    defer environment.deinit();
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ binaryPath(), "auth", "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_status_bytes),
        .stderr_limit = .limited(max_status_bytes),
        // A CLI stuck on a keychain prompt or the network must not freeze fx.
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(probe_timeout_ms) } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.ClaudeCliMissing,
        else => {
            debug_trace.logf("auth", "claude auth status failed to run err={s}", .{@errorName(err)});
            return error.ClaudeCliFailed;
        },
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    // A signed-out CLI may exit non-zero but still print its status document,
    // so the exit code only matters when there is nothing to parse.
    if (std.mem.trim(u8, result.stdout, " \t\r\n").len == 0) {
        if (result.term == .exited and result.term.exited == 0) return null;
        return error.ClaudeCliFailed;
    }
    return parseStatus(alloc, result.stdout);
}

const Cache = struct {
    mutex: std.Io.Mutex = .init,
    valid: bool = false,
    checked_at_ms: i64 = 0,
    ttl_ms: i64 = probe_ttl_ms,
    signed_in: bool = false,
    account: [max_cached_account_bytes]u8 = undefined,
    account_len: usize = 0,
};

var cache: Cache = .{};

fn remember(status: ?Status) void {
    const io = io_mod.getIo();
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    cache.valid = true;
    cache.checked_at_ms = io_mod.milliTimestamp();
    cache.ttl_ms = probe_ttl_ms;
    cache.signed_in = status != null;
    cache.account_len = 0;
    if (status) |value| {
        if (value.account_id.len <= max_cached_account_bytes) {
            @memcpy(cache.account[0..value.account_id.len], value.account_id);
            cache.account_len = value.account_id.len;
        }
    }
}

/// Forgets the last probe. Sign-in and sign-out call it so the next check asks
/// the CLI again.
pub fn invalidate() void {
    const io = io_mod.getIo();
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    cache.valid = false;
}

fn rememberFailure() void {
    const io = io_mod.getIo();
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    cache.valid = true;
    cache.checked_at_ms = io_mod.milliTimestamp();
    cache.ttl_ms = probe_failure_ttl_ms;
    cache.signed_in = false;
    cache.account_len = 0;
}

fn fresh() ?bool {
    const io = io_mod.getIo();
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    if (!cache.valid) return null;
    if (io_mod.milliTimestamp() - cache.checked_at_ms >= cache.ttl_ms) return null;
    return cache.signed_in;
}

fn cachedAccountId(alloc: Allocator) Allocator.Error!?[]u8 {
    const io = io_mod.getIo();
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    if (!cache.valid or !cache.signed_in or cache.account_len == 0) return null;
    if (io_mod.milliTimestamp() - cache.checked_at_ms >= cache.ttl_ms) return null;
    return try alloc.dupe(u8, cache.account[0..cache.account_len]);
}

/// Whether the CLI is signed in, answered from a short-lived cache. A missing
/// or broken CLI reads as signed out, so callers never fail on this probe.
pub fn presence() host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    if (fresh()) |signed_in| return if (signed_in) .present else .missing;
    var status = probe(std.heap.c_allocator) catch |err| {
        // A failed probe says little about the sign-in, so it is remembered only
        // for a few seconds.
        debug_trace.logf("auth", "source probe failed source=claude_cli err={s}", .{@errorName(err)});
        rememberFailure();
        return .missing;
    };
    defer if (status) |*value| value.deinit(std.heap.c_allocator);
    remember(status);
    return if (status != null) .present else .missing;
}

/// The signed-in organization, or null when signed out. The caller owns the
/// result.
pub fn loadAccountId(alloc: Allocator) ProbeError!?[]u8 {
    if (try cachedAccountId(alloc)) |cached| return cached;
    var status = (try probe(alloc)) orelse {
        remember(null);
        return null;
    };
    defer status.deinit(alloc);
    remember(status);
    return try alloc.dupe(u8, status.account_id);
}

pub const LoginError = error{ ClaudeCliMissing, ClaudeLoginFailed, OutOfMemory };

/// Confirms Claude Code is signed in, running `claude auth login` on the user's
/// terminal first when it is not. The CLI opens the browser and owns the whole
/// exchange, so fx only waits. A CLI that is already signed in is left alone.
pub fn runLogin(alloc: Allocator) LoginError!void {
    if (comptime host_target.is_wasm) return error.ClaudeLoginFailed;
    if (probe(alloc)) |existing| {
        if (existing) |signed_in| {
            var status = signed_in;
            status.deinit(alloc);
            invalidate();
            return;
        }
    } else |err| switch (err) {
        error.ClaudeCliMissing => return error.ClaudeCliMissing,
        error.OutOfMemory => return error.OutOfMemory,
        // An unreadable status is not proof of a signed-out CLI; let the login
        // command decide.
        error.ClaudeCliFailed, error.InvalidClaudeStatus => {},
    }
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = &.{ binaryPath(), "auth", "login" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ClaudeCliMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("auth", "claude auth login failed to start err={s}", .{@errorName(err)});
            return error.ClaudeLoginFailed;
        },
    };
    const term = child.wait(io) catch return error.ClaudeLoginFailed;
    invalidate();
    if (term != .exited or term.exited != 0) return error.ClaudeLoginFailed;
    var status = (probe(alloc) catch return error.ClaudeLoginFailed) orelse return error.ClaudeLoginFailed;
    status.deinit(alloc);
}

pub const missing_cli_message = "fx could not find the claude command. Install Claude Code, or set FX_CLAUDE_BIN to its path.";

test "status parsing reads the signed-in organization and ignores unknown fields" {
    var status = (try parseStatus(std.testing.allocator,
        \\{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","orgId":"org-1","subscriptionType":"max","extra":{"a":1}}
    )).?;
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("org-1", status.account_id);
    try std.testing.expectEqualStrings("person@example.com", status.email.?);
    try std.testing.expectEqualStrings("max", status.subscription_type.?);
}

test "status parsing falls back to the email and reports signed out as null" {
    var status = (try parseStatus(std.testing.allocator,
        \\{"loggedIn":true,"email":"person@example.com"}
    )).?;
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("person@example.com", status.account_id);

    try std.testing.expect((try parseStatus(std.testing.allocator,
        \\{"loggedIn":false}
    )) == null);
}

test "status parsing rejects malformed documents and unusable identities" {
    try std.testing.expectError(error.InvalidClaudeStatus, parseStatus(std.testing.allocator, "not json"));
    try std.testing.expectError(error.InvalidClaudeStatus, parseStatus(std.testing.allocator,
        \\{"loggedIn":true}
    ));
    try std.testing.expectError(error.InvalidClaudeStatus, parseStatus(std.testing.allocator,
        \\{"loggedIn":true,"orgId":"has space"}
    ));
}

test "status parsing frees every allocation on failure" {
    const Check = struct {
        fn run(alloc: Allocator) !void {
            var status = (try parseStatus(alloc,
                \\{"loggedIn":true,"email":"a@example.com","orgId":"org-1","subscriptionType":"pro"}
            )).?;
            status.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(@import("../shared/testing_allocator.zig").no_resize, Check.run, .{});
}

test "account overrides are removed from the environment and other variables stay" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ANTHROPIC_API_KEY", "sk-test");
    try map.put("ANTHROPIC_AUTH_TOKEN", "token");
    try map.put("ANTHROPIC_BASE_URL", "https://proxy.example.com");
    try map.put("CLAUDE_CODE_USE_BEDROCK", "1");
    try map.put("CLAUDE_CODE_USE_VERTEX", "1");
    try map.put("CLAUDE_CODE_USE_FOUNDRY", "1");
    try map.put("CLAUDE_CODE_OAUTH_TOKEN", "subscription-token");
    try map.put("PATH", "/usr/bin");
    scrubAccountOverrides(&map);
    try std.testing.expect(map.get("ANTHROPIC_API_KEY") == null);
    try std.testing.expect(map.get("ANTHROPIC_AUTH_TOKEN") == null);
    try std.testing.expect(map.get("ANTHROPIC_BASE_URL") == null);
    try std.testing.expect(map.get("CLAUDE_CODE_USE_BEDROCK") == null);
    try std.testing.expect(map.get("CLAUDE_CODE_USE_VERTEX") == null);
    try std.testing.expect(map.get("CLAUDE_CODE_USE_FOUNDRY") == null);
    // A subscription's own long-lived token is the user's login, not an override.
    try std.testing.expectEqualStrings("subscription-token", map.get("CLAUDE_CODE_OAUTH_TOKEN").?);
    try std.testing.expectEqualStrings("/usr/bin", map.get("PATH").?);
}

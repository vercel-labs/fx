const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const max_credentials_bytes: usize = 64 * 1024;
const max_claude_json_bytes: usize = 1024 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const default_user_agent = "claude-cli/2.1.0 (external, cli)";

pub const user_agent = default_user_agent;
pub const originator = "claude-code";
pub const messages_beta = "oauth-2025-04-20,claude-code-20250219";

pub const Stored = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    account_id: []u8,

    pub fn deinit(self: *Stored, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn expired(self: Stored, now_ms: i64) bool {
        return refreshDeadlineMs(self.expires_at_ms) <= now_ms;
    }
};

pub fn refreshDeadlineMs(expires_at_ms: i64) i64 {
    return @max(expires_at_ms - expiry_skew_ms, 0);
}

pub fn e2eIsolated() bool {
    return io_mod.getenv("FX_E2E_CLAUDE_TOKEN_URL") != null;
}

const tools_unset: u8 = 0;
const tools_on: u8 = 1;
const tools_off: u8 = 2;

var cli_tools_override: std.atomic.Value(u8) = .init(tools_unset);
var settings_tools_override: std.atomic.Value(u8) = .init(tools_unset);

pub fn setClaudeCodeToolsFromCli(on: bool) void {
    cli_tools_override.store(if (on) tools_on else tools_off, .seq_cst);
}

pub fn setClaudeCodeToolsFromSettings(on: bool) void {
    settings_tools_override.store(if (on) tools_on else tools_off, .seq_cst);
}

pub fn claudeCodeToolsEnabled() bool {
    if (io_mod.getenv("FX_CLAUDE_CODE_TOOLS")) |raw| {
        if (parseToolsToggle(raw)) |value| return value;
    }
    return switch (cli_tools_override.load(.seq_cst)) {
        tools_off => false,
        tools_on => true,
        else => switch (settings_tools_override.load(.seq_cst)) {
            tools_on => true,
            else => false,
        },
    };
}

pub fn parseToolsToggle(raw: []const u8) ?bool {
    if (eqlIgnoreCase(raw, "on") or eqlIgnoreCase(raw, "true") or eqlIgnoreCase(raw, "1") or eqlIgnoreCase(raw, "claude"))
        return true;
    if (eqlIgnoreCase(raw, "off") or eqlIgnoreCase(raw, "false") or eqlIgnoreCase(raw, "0") or
        eqlIgnoreCase(raw, "none") or eqlIgnoreCase(raw, "fx") or eqlIgnoreCase(raw, "host"))
        return false;
    return null;
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn enabled() bool {
    if (e2eIsolated()) return false;
    if (comptime builtin.is_test) return io_mod.getenv("FX_TEST_CLAUDE_CODE_STORE") != null;
    return true;
}

pub fn findCli(alloc: Allocator) !?[]u8 {
    if (comptime host_target.is_wasm) return null;
    if (io_mod.getenv("FX_CLAUDE_CLI")) |override| {
        if (override.len > 0 and cliExists(override)) return try alloc.dupe(u8, override);
    }
    if (io_mod.getenv("PATH")) |path_env| {
        if (try findCliInPath(alloc, path_env)) |found| return found;
    }
    if (io_mod.getenv("HOME")) |home| {
        const candidate = try std.fs.path.join(alloc, &.{ home, ".local", "bin", "claude" });
        defer alloc.free(candidate);
        if (cliExists(candidate)) return try alloc.dupe(u8, candidate);
    }
    return null;
}

pub fn hasCredentials(alloc: Allocator) !bool {
    var stored = (try load(alloc)) orelse return false;
    stored.deinit(alloc);
    return true;
}

pub fn load(alloc: Allocator) !?Stored {
    if (comptime host_target.is_wasm) return null;
    if (!enabled()) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    const credentials_path = try std.fs.path.join(alloc, &.{ home, ".claude", "credentials.json" });
    defer alloc.free(credentials_path);
    const bytes = (try readPrivateFile(alloc, credentials_path, max_credentials_bytes)) orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    var stored = parseCredentials(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Claude Code credentials parse failed err={s}", .{@errorName(err)});
            return null;
        },
    };
    errdefer stored.deinit(alloc);
    if (stored.account_id.len == 0) {
        alloc.free(stored.account_id);
        stored.account_id = try loadAccountId(alloc, home);
    }
    return stored;
}

pub fn save(alloc: Allocator, stored: Stored) !void {
    if (comptime host_target.is_wasm) return error.ClaudeOAuthUnavailable;
    if (!enabled()) return error.InvalidE2EClaudeEndpoint;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const path = try std.fs.path.join(alloc, &.{ home, ".claude", "credentials.json" });
    defer alloc.free(path);
    const text = try stringifyCredentials(alloc, stored);
    defer secret.zeroAndFree(alloc, text);
    io_mod.writeFileAtomic(alloc, path, text) catch |err| {
        debug_trace.logf("auth", "Claude Code credentials save failed err={s}", .{@errorName(err)});
        return err;
    };
}

pub fn parseCredentials(alloc: Allocator, bytes: []const u8) !Stored {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClaudeCodeCredentials;
    const object = parsed.value.object;
    const access_token = try dupeRequiredString(alloc, object, "oauth_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "oauth_refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_at_ms = try expiresAtMs(object);
    const account_id = if (object.get("account_uuid")) |value|
        try dupeOptionalId(alloc, value)
    else
        try alloc.dupe(u8, "");
    errdefer alloc.free(account_id);
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
}

pub fn stringifyCredentials(alloc: Allocator, stored: Stored) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"oauth_token\":");
    try std.json.Stringify.value(stored.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"oauth_refresh_token\":");
    try std.json.Stringify.value(stored.refresh_token, .{}, &out.writer);
    const expires_at_s = @divTrunc(stored.expires_at_ms, 1000);
    try out.writer.print(",\"oauth_expires_at\":{d}", .{expires_at_s});
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn loadAccountId(alloc: Allocator, home: []const u8) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ home, ".claude.json" });
    defer alloc.free(path);
    const bytes = (try readPrivateFile(alloc, path, max_claude_json_bytes)) orelse
        return alloc.dupe(u8, "");
    defer secret.zeroAndFree(alloc, bytes);
    return parseAccountId(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => alloc.dupe(u8, ""),
    };
}

pub fn parseAccountId(alloc: Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClaudeCodeCredentials;
    const account = parsed.value.object.get("oauthAccount") orelse
        return error.InvalidClaudeCodeCredentials;
    if (account != .object) return error.InvalidClaudeCodeCredentials;
    const value = account.object.get("accountUuid") orelse
        return error.InvalidClaudeCodeCredentials;
    if (value != .string or value.string.len == 0) return error.InvalidClaudeCodeCredentials;
    return alloc.dupe(u8, value.string);
}

fn expiresAtMs(object: std.json.ObjectMap) !i64 {
    const value = object.get("oauth_expires_at") orelse return error.InvalidClaudeCodeCredentials;
    const raw: i64 = switch (value) {
        .integer => value.integer,
        else => return error.InvalidClaudeCodeCredentials,
    };
    if (raw <= 0) return error.InvalidClaudeCodeCredentials;
    if (raw > 1_000_000_000_000) return raw;
    return std.math.mul(i64, raw, 1000) catch return error.InvalidClaudeCodeCredentials;
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidClaudeCodeCredentials;
    if (value != .string or value.string.len == 0) return error.InvalidClaudeCodeCredentials;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalId(alloc: Allocator, value: std.json.Value) ![]u8 {
    if (value != .string) return error.InvalidClaudeCodeCredentials;
    return alloc.dupe(u8, value.string);
}

fn readPrivateFile(alloc: Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "Claude Code file open failed path_kind={s} err={s}", .{
                std.fs.path.basename(path),
                @errorName(err),
            });
            return null;
        },
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return null;
    if (stat.kind != .file) return null;
    if (stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "Claude Code file ignored step=permissions path_kind={s}", .{
            std.fs.path.basename(path),
        });
        return null;
    }
    return io_mod.readFileToEnd(alloc, &file, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Claude Code file read failed path_kind={s} err={s}", .{
                std.fs.path.basename(path),
                @errorName(err),
            });
            return null;
        },
    };
}

fn findCliInPath(alloc: Allocator, path_env: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(alloc, &.{ dir, "claude" });
        if (cliExists(candidate)) return candidate;
        alloc.free(candidate);
    }
    return null;
}

fn cliExists(path: []const u8) bool {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return false;
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch return false;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return false;
    return stat.kind == .file;
}

test "Claude Code credentials parse oauth_expires_at seconds" {
    const alloc = std.testing.allocator;
    var stored = try parseCredentials(
        alloc,
        "{\"oauth_token\":\"access\",\"oauth_refresh_token\":\"refresh\",\"oauth_expires_at\":1782251014}",
    );
    defer stored.deinit(alloc);
    try std.testing.expectEqualStrings("access", stored.access_token);
    try std.testing.expectEqualStrings("refresh", stored.refresh_token);
    try std.testing.expectEqual(@as(i64, 1_782_251_014_000), stored.expires_at_ms);
}

test "Claude Code credentials stringify uses seconds" {
    const alloc = std.testing.allocator;
    var stored = Stored{
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1_782_251_014_000,
        .account_id = try alloc.dupe(u8, "acct"),
    };
    defer stored.deinit(alloc);
    const text = try stringifyCredentials(alloc, stored);
    defer secret.zeroAndFree(alloc, text);
    try std.testing.expect(std.mem.find(u8, text, "\"oauth_expires_at\":1782251014") != null);
    try std.testing.expect(std.mem.find(u8, text, "account") == null);
}

test "Claude Code account uuid comes from oauthAccount" {
    const alloc = std.testing.allocator;
    const account_id = try parseAccountId(
        alloc,
        "{\"oauthAccount\":{\"accountUuid\":\"acct-uuid\",\"organizationUuid\":\"org\"}}",
    );
    defer alloc.free(account_id);
    try std.testing.expectEqualStrings("acct-uuid", account_id);
}

test "Claude Code tools toggle parses on and off aliases" {
    try std.testing.expectEqual(true, parseToolsToggle("on").?);
    try std.testing.expectEqual(true, parseToolsToggle("Claude").?);
    try std.testing.expectEqual(false, parseToolsToggle("off").?);
    try std.testing.expectEqual(false, parseToolsToggle("fx").?);
    try std.testing.expect(parseToolsToggle("maybe") == null);
}

test "Claude Code tools default to off" {
    if (io_mod.getenv("FX_CLAUDE_CODE_TOOLS") != null) return error.SkipZigTest;
    try std.testing.expect(!claudeCodeToolsEnabled());
}

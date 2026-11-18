//! The Vercel token for the Sandbox API. fx never stores it: it reads
//! `VERCEL_TOKEN`, or the Vercel CLI's own login, each time it needs one.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

pub const Source = enum { env, vercel_cli };

pub const Token = struct {
    value: []const u8,
    source: Source,
    /// Seconds since the epoch, or null when the login has no expiry.
    expires_at_s: ?i64 = null,
};

pub const Error = error{ VercelLoginMissing, VercelLoginExpired, OutOfMemory };

pub const Inputs = struct {
    env_token: ?[]const u8,
    cli_auth_path: []const u8,
    now_s: i64,
};

/// The side effects `resolve` needs, so tests can replace them.
pub const Effects = struct {
    context: *anyopaque,
    /// The file's bytes, or null when it cannot be read.
    read_file: *const fn (context: *anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]u8,
    /// Asks the Vercel CLI to renew its login. False when that fails.
    renew: *const fn (context: *anyopaque) bool,
};

/// A login file larger than this is not read.
const max_login_bytes = 64 * 1024;

/// A token this close to its expiry counts as expired.
const expiry_margin_s = 60;

/// The Vercel CLI's login file for this platform.
pub fn cliAuthPath(
    arena: std.mem.Allocator,
    os: std.Target.Os.Tag,
    home: []const u8,
    xdg_data_home: ?[]const u8,
) error{OutOfMemory}![]u8 {
    if (os == .macos) {
        return arena.print("{s}/Library/Application Support/com.vercel.cli/auth.json", .{home});
    }
    if (xdg_data_home) |xdg| {
        if (xdg.len > 0) return arena.print("{s}/com.vercel.cli/auth.json", .{xdg});
    }
    return arena.print("{s}/.local/share/com.vercel.cli/auth.json", .{home});
}

/// The token in the Vercel CLI's login file, or null when the bytes hold none.
pub fn parseCliAuth(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?Token {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const object = switch (root) {
        .object => |map| map,
        else => return null,
    };
    const raw = switch (object.get("token") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;
    return .{ .value = value, .source = .vercel_cli, .expires_at_s = expiryOf(object) };
}

fn expiryOf(object: std.json.ObjectMap) ?i64 {
    const expiry = object.get("expiresAt") orelse return null;
    return switch (expiry) {
        .integer => |seconds| seconds,
        else => null,
    };
}

/// True when the token can still be used at `now_s`, with a safety margin.
pub fn usable(token: Token, now_s: i64) bool {
    const expires_at = token.expires_at_s orelse return true;
    return expires_at > now_s + expiry_margin_s;
}

/// The token to use now. `VERCEL_TOKEN` wins. Otherwise the CLI login is
/// read, and an expired login is renewed once with `vercel whoami`.
pub fn resolve(arena: std.mem.Allocator, inputs: Inputs, effects: Effects) Error!Token {
    if (inputs.env_token) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len > 0) return .{ .value = value, .source = .env };
    }

    const login = (try readLogin(arena, inputs.cli_auth_path, effects)) orelse return error.VercelLoginMissing;
    if (usable(login, inputs.now_s)) return login;

    if (!effects.renew(effects.context)) return error.VercelLoginExpired;
    const renewed = (try readLogin(arena, inputs.cli_auth_path, effects)) orelse return error.VercelLoginExpired;
    if (usable(renewed, inputs.now_s)) return renewed;
    return error.VercelLoginExpired;
}

fn readLogin(arena: std.mem.Allocator, path: []const u8, effects: Effects) Error!?Token {
    const bytes = effects.read_file(effects.context, arena, path) orelse return null;
    return parseCliAuth(arena, bytes);
}

/// The message to show for a failed `resolve`.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.VercelLoginMissing => "No Vercel login for the sandbox. Set VERCEL_TOKEN, or run `vercel login`.",
        error.VercelLoginExpired => "The Vercel login expired, and `vercel whoami` could not renew it. Run `vercel login`.",
        error.OutOfMemory => "Out of memory while reading the Vercel login.",
    };
}

/// The inputs from this process: its environment, its home folder, and the clock.
pub fn systemInputs(arena: std.mem.Allocator) error{OutOfMemory}!Inputs {
    const home = io_mod.getenv("HOME") orelse "";
    return .{
        .env_token = io_mod.getenv("VERCEL_TOKEN"),
        .cli_auth_path = try cliAuthPath(arena, builtin.target.os.tag, home, io_mod.getenv("XDG_DATA_HOME")),
        .now_s = @divFloor(io_mod.milliTimestamp(), 1000),
    };
}

/// The state behind the system effects. They keep none, so it is never read.
var system_context: u8 = 0;

pub fn systemEffects() Effects {
    return .{
        .context = &system_context,
        .read_file = systemReadFile,
        .renew = systemRenew,
    };
}

fn systemReadFile(context: *anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    _ = context;
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &file, max_login_bytes) catch null;
}

fn systemRenew(context: *anyopaque) bool {
    _ = context;
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io_mod.getIo(), .{
        .argv = &.{ "vercel", "whoami" },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const FakeLogin = struct {
    bytes: [2]?[]const u8 = .{ null, null },
    reads: usize = 0,
    renews: usize = 0,
    renew_ok: bool = true,

    /// The first read gets `bytes[0]`, and every later read gets `bytes[1]`.
    fn readFile(context: *anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]u8 {
        _ = path;
        const self: *FakeLogin = @ptrCast(@alignCast(context));
        const index = @min(self.reads, 1);
        self.reads += 1;
        const text = self.bytes[index] orelse return null;
        return arena.dupe(u8, text) catch null;
    }

    fn renew(context: *anyopaque) bool {
        const self: *FakeLogin = @ptrCast(@alignCast(context));
        self.renews += 1;
        return self.renew_ok;
    }

    fn effects(self: *FakeLogin) Effects {
        return .{ .context = self, .read_file = readFile, .renew = renew };
    }
};

const expired_login = "{\"token\":\"old\",\"expiresAt\":900}";

test "VERCEL_TOKEN wins and skips the CLI login" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeLogin = .{};

    const token = try resolve(arena_state.allocator(), .{
        .env_token = " tok \n",
        .cli_auth_path = "/auth.json",
        .now_s = 1000,
    }, fake.effects());
    try std.testing.expectEqualStrings("tok", token.value);
    try std.testing.expectEqual(Source.env, token.source);
    try std.testing.expectEqual(@as(usize, 0), fake.reads);
}

test "a blank VERCEL_TOKEN falls back to the CLI login" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeLogin = .{ .bytes = .{ "{\"token\":\"abc\",\"expiresAt\":2000}", null } };

    const token = try resolve(arena_state.allocator(), .{
        .env_token = " \t ",
        .cli_auth_path = "/auth.json",
        .now_s = 1000,
    }, fake.effects());
    try std.testing.expectEqualStrings("abc", token.value);
    try std.testing.expectEqual(Source.vercel_cli, token.source);
    try std.testing.expectEqual(@as(usize, 1), fake.reads);
}

test "a valid CLI login is used" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeLogin = .{ .bytes = .{ "{\"token\":\"abc\",\"expiresAt\":2000}", null } };

    const token = try resolve(arena_state.allocator(), .{
        .env_token = null,
        .cli_auth_path = "/auth.json",
        .now_s = 1000,
    }, fake.effects());
    try std.testing.expectEqualStrings("abc", token.value);
    try std.testing.expectEqual(Source.vercel_cli, token.source);
    try std.testing.expectEqual(@as(usize, 0), fake.renews);
}

test "an expired CLI login is renewed once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeLogin = .{ .bytes = .{
        expired_login,
        "{\"token\":\"new\",\"expiresAt\":5000}",
    } };

    const token = try resolve(arena_state.allocator(), .{
        .env_token = null,
        .cli_auth_path = "/auth.json",
        .now_s = 1000,
    }, fake.effects());
    try std.testing.expectEqualStrings("new", token.value);
    try std.testing.expectEqual(@as(usize, 1), fake.renews);
    try std.testing.expectEqual(@as(usize, 2), fake.reads);
}

test "a login that stays expired fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const inputs: Inputs = .{ .env_token = null, .cli_auth_path = "/auth.json", .now_s = 1000 };

    var still_expired: FakeLogin = .{ .bytes = .{ expired_login, expired_login } };
    try std.testing.expectError(error.VercelLoginExpired, resolve(arena_state.allocator(), inputs, still_expired.effects()));
    try std.testing.expectEqual(@as(usize, 1), still_expired.renews);

    var renew_fails: FakeLogin = .{ .bytes = .{ expired_login, expired_login }, .renew_ok = false };
    try std.testing.expectError(error.VercelLoginExpired, resolve(arena_state.allocator(), inputs, renew_fails.effects()));
    try std.testing.expectEqual(@as(usize, 1), renew_fails.reads);

    var renewed_gone: FakeLogin = .{ .bytes = .{ expired_login, null } };
    try std.testing.expectError(error.VercelLoginExpired, resolve(arena_state.allocator(), inputs, renewed_gone.effects()));
    try std.testing.expectEqual(@as(usize, 1), renewed_gone.renews);
}

test "no login fails without renewing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const inputs: Inputs = .{ .env_token = null, .cli_auth_path = "/auth.json", .now_s = 1000 };

    var no_file: FakeLogin = .{};
    try std.testing.expectError(error.VercelLoginMissing, resolve(arena_state.allocator(), inputs, no_file.effects()));
    try std.testing.expectEqual(@as(usize, 0), no_file.renews);

    var no_token: FakeLogin = .{ .bytes = .{ "{\"cachedUser\":{}}", null } };
    try std.testing.expectError(error.VercelLoginMissing, resolve(arena_state.allocator(), inputs, no_token.effects()));
    try std.testing.expectEqual(@as(usize, 0), no_token.renews);
}

test "CLI login files without a usable token are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const unusable = [_][]const u8{ "[1,2]", "not json", "{\"token\":5}", "{\"token\":\"  \"}" };
    for (unusable) |bytes| {
        try std.testing.expect((try parseCliAuth(arena, bytes)) == null);
    }

    const token = (try parseCliAuth(arena, "{\"token\":\"abc\",\"expiresAt\":\"soon\"}")) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abc", token.value);
    try std.testing.expectEqual(@as(?i64, null), token.expires_at_s);
}

test "a token near its expiry is not usable" {
    try std.testing.expect(!usable(.{ .value = "x", .source = .vercel_cli, .expires_at_s = 1030 }, 1000));
    try std.testing.expect(usable(.{ .value = "x", .source = .vercel_cli, .expires_at_s = 1120 }, 1000));
    try std.testing.expect(usable(.{ .value = "x", .source = .vercel_cli }, 1000));
}

test "the CLI login path follows the platform" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mac = try cliAuthPath(arena, .macos, "/Users/me", null);
    try std.testing.expectEqualStrings("/Users/me/Library/Application Support/com.vercel.cli/auth.json", mac);
    const xdg = try cliAuthPath(arena, .linux, "/home/me", "/x");
    try std.testing.expectEqualStrings("/x/com.vercel.cli/auth.json", xdg);
    const fallback = try cliAuthPath(arena, .linux, "/home/me", "");
    try std.testing.expectEqualStrings("/home/me/.local/share/com.vercel.cli/auth.json", fallback);
}

test "describe names the fix" {
    try std.testing.expect(std.mem.find(u8, describe(error.VercelLoginMissing), "vercel login") != null);
    try std.testing.expect(std.mem.find(u8, describe(error.VercelLoginExpired), "vercel whoami") != null);
}

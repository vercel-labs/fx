const std = @import("std");
const builtin = @import("builtin");
const io = @import("../shared/io.zig");
const browser = @import("../auth/browser_callback.zig");
const transport_mod = @import("../auth/oauth_transport.zig");
const host = @import("../hosts/host.zig");
const output = @import("../output/output_contracts.zig");
const Allocator = std.mem.Allocator;
const callback_url = "https://fx.sh/api/slack/oauth/callback";
const bot_scope = "app_mentions:read";
const authorization_lifetime: std.Io.Clock.Duration = .{ .raw = .fromSeconds(300), .clock = .boot };

pub const Action = enum { install, status, refresh };
pub const Options = struct { action: Action, format: output.OutputFormat = .text };
pub fn parse(args: []const [:0]const u8) !Options {
    if (args.len < 1 or args.len > 2) return error.InvalidSlackArguments;
    const action = std.meta.stringToEnum(Action, args[0]) orelse return error.InvalidSlackArguments;
    if (args.len == 2 and !std.mem.eql(u8, args[1], "--json")) return error.InvalidSlackArguments;
    return .{ .action = action, .format = if (args.len == 2) .json else .text };
}

const Config = struct { client_id: []const u8, app_id: []const u8, team_id: []const u8, redirect_uri: []const u8, scope: []const u8 };
const Installation = struct {
    version: u8 = 1,
    bridge_origin: []const u8,
    client_id: []const u8,
    app_id: []const u8,
    team_id: []const u8,
    bot_user_id: []const u8,
    bot_id: []const u8,
    installed_by: []const u8,
    scope: []const u8,
    access_token: []const u8,
    refresh_token: ?[]const u8,
    expires_at_ms: ?i64,
    refresh_expires_at_ms: ?i64,
};

// The caller supplies an arena; the returned snapshot borrows its allocations.
pub fn run(alloc: Allocator, action: Action, transport: transport_mod.Provider, opener: host.UrlOpener) !output.SlackSnapshot {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SlackInstallationUnsupported;
    const origin = io.getenv("FX_E2E_SLACK_ORIGIN") orelse "https://fx.sh";
    if (!std.mem.eql(u8, origin, "https://fx.sh") and !test_origin(origin)) return error.InvalidSlackTestOrigin;
    const home = io.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    var root = try io.openOrCreateVerifiedPrivateDir(&home_dir, ".fx");
    defer root.close();
    var dir = try io.openOrCreateVerifiedPrivateDir(&root, "slack");
    defer dir.close();
    var lock = try io.acquireTimedAdvisoryLock(&dir, "installation.lock", 2_000);
    defer lock.release();
    const previous = try load(alloc, &dir);
    if (action == .status) return snapshot(action, previous);
    if (previous) |value| {
        if (!std.mem.eql(u8, value.bridge_origin, origin)) return error.SlackInstallationOriginMismatch;
    }
    if (action == .refresh and previous == null) return error.SlackInstallationMissing;
    const config_url = try std.fmt.allocPrint(alloc, "{s}/api/slack/install/config", .{origin});
    const config = (try std.json.parseFromSlice(Config, alloc, try request(alloc, transport, .get, config_url, null, null), .{ .allocate = .alloc_always })).value;
    try validate_config(config);
    const token_url = if (test_origin(origin)) try std.fmt.allocPrint(alloc, "{s}/api/oauth.v2.access", .{origin}) else "https://slack.com/api/oauth.v2.access";
    const identity_url = if (test_origin(origin)) try std.fmt.allocPrint(alloc, "{s}/api/auth.test", .{origin}) else "https://slack.com/api/auth.test";
    var form: std.Io.Writer.Allocating = .init(alloc);
    try append(&form.writer, "client_id", config.client_id, true);
    var accepted: ?browser.Accepted(Callback) = null;
    var saved = false;
    defer if (accepted) |*value| {
        value.respond(if (saved) .ok else .failed) catch {};
        value.deinit();
    };
    if (action == .install) {
        const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), authorization_lifetime);
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io.getIo(), .{ .reuse_address = false });
        defer listener.deinit(io.getIo());
        var entropy: [32]u8 = undefined;
        try io.getIo().randomSecure(&entropy);
        var verifier_buf: [43]u8 = undefined;
        const verifier = std.base64.url_safe_no_pad.Encoder.encode(&verifier_buf, &entropy);
        defer std.crypto.secureZero(u8, @volatileCast(verifier_buf[0..]));
        defer std.crypto.secureZero(u8, @volatileCast(entropy[0..]));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        var challenge_buf: [43]u8 = undefined;
        const challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buf, &digest);
        try io.getIo().randomSecure(&entropy);
        var state_buf: [43]u8 = undefined;
        const state = std.base64.url_safe_no_pad.Encoder.encode(&state_buf, &entropy);
        const start_url = try std.fmt.allocPrint(alloc, "{s}/api/slack/install?state={s}&challenge={s}&port={d}", .{ origin, state, challenge, listener.socket.address.getPort() });
        try std.Io.File.stderr().writeStreamingAll(io.getIo(), "Authorize the workspace installation in your browser. Keep fx running.\n");
        if (io.getenv("FX_NO_OPEN_BROWSER") != null or !try opener.open(alloc, start_url)) {
            try std.Io.File.stderr().writeStreamingAll(io.getIo(), try std.fmt.allocPrint(alloc, "Open on this computer: {s}\n", .{start_url}));
        }
        var context = CallbackContext{ .state = state };
        var cancelled: std.atomic.Value(bool) = .init(false);
        while (accepted == null) {
            if (deadline.durationFromNow(io.getIo()).raw.nanoseconds <= 0) return error.SlackAuthorizationExpired;
            accepted = try browser.await_form(Callback, parse_callback, alloc, &listener, &context, &cancelled, origin);
        }
        if (deadline.durationFromNow(io.getIo()).raw.nanoseconds <= 0) return error.SlackAuthorizationExpired;
        if (accepted.?.callback.denied) return error.SlackAuthorizationDenied;
        try append(&form.writer, "redirect_uri", callback_url, false);
        try append(&form.writer, "code", accepted.?.callback.code, false);
        try append(&form.writer, "code_verifier", verifier, false);
    } else {
        const current = previous.?;
        if (!std.mem.eql(u8, current.client_id, config.client_id) or !std.mem.eql(u8, current.app_id, config.app_id) or !std.mem.eql(u8, current.team_id, config.team_id)) return error.SlackInstallationIdentityMismatch;
        const refresh = current.refresh_token orelse return snapshot(action, previous);
        if (current.refresh_expires_at_ms.? <= io.milliTimestamp()) return error.SlackRefreshExpired;
        try append(&form.writer, "grant_type", "refresh_token", false);
        try append(&form.writer, "refresh_token", refresh, false);
    }
    const issued_at = io.milliTimestamp();
    const exchange = try request(alloc, transport, .post_form, token_url, form.written(), null);
    var record = try installation(alloc, exchange, config, origin, if (action == .refresh) previous else null, issued_at);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{record.access_token});
    const identity = try request(alloc, transport, .post_form, identity_url, "", authorization);
    try validate_identity(alloc, identity, &record, if (action == .refresh) previous else null);
    var serialized: std.Io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(record, .{}, &serialized.writer);
    try io.durableReplaceVerified(alloc, &dir, "installation.json", serialized.written());
    saved = true;
    return snapshot(action, record);
}

fn test_origin(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "http://127.0.0.1:")) return false;
    const port = std.fmt.parseInt(u16, value[17..], 10) catch return false;
    return port >= 1024;
}

fn request(alloc: Allocator, transport: transport_mod.Provider, method: transport_mod.Method, url: []const u8, payload: ?[]const u8, authorization: ?[]const u8) ![]u8 {
    var response = try transport.execute(alloc, .{ .method = method, .url = url, .payload = payload, .authorization = authorization, .deadline = .{ .raw = std.Io.Clock.awake.now(io.getIo()).addDuration(.fromSeconds(15)), .clock = .awake } });
    if (response.disposition != .accepted or response.body.len > 65536) {
        response.deinit(alloc);
        return error.SlackRequestFailed;
    }
    return response.takeBody();
}

fn valid_id(value: []const u8, prefixes: []const u8) bool {
    if (value.len < 2 or value.len > 64 or std.mem.findScalar(u8, prefixes, value[0]) == null) return false;
    for (value[1..]) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return false;
    return true;
}

fn validate_config(value: Config) !void {
    var digits = std.mem.splitScalar(u8, value.client_id, '.');
    var count: usize = 0;
    while (digits.next()) |part| {
        if (part.len == 0 or part.len > 32) return error.InvalidSlackConfiguration;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidSlackConfiguration;
        count += 1;
    }
    if (count != 2 or !valid_id(value.app_id, "A") or !valid_id(value.team_id, "T") or !std.mem.eql(u8, value.scope, bot_scope) or !std.mem.eql(u8, value.redirect_uri, callback_url)) return error.InvalidSlackConfiguration;
}

fn object(alloc: Allocator, bytes: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
    if (parsed.value != .object) return error.InvalidSlackResponse;
    const value = parsed.value.object;
    const ok = value.get("ok") orelse return error.InvalidSlackResponse;
    if (ok != .bool or !ok.bool) return error.SlackRequestFailed;
    return value;
}

fn string(value: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const entry = value.get(key) orelse return error.InvalidSlackResponse;
    if (entry != .string or entry.string.len == 0 or entry.string.len > 4096) return error.InvalidSlackResponse;
    for (entry.string) |c| if (c < 0x21 or c > 0x7e) return error.InvalidSlackResponse;
    return entry.string;
}

fn identity_field(value: std.json.ObjectMap, key: []const u8, previous: ?[]const u8) ![]const u8 {
    if (!value.contains(key)) return previous orelse error.InvalidSlackResponse;
    return string(value, key);
}

fn installation(alloc: Allocator, bytes: []const u8, config: Config, origin: []const u8, previous: ?Installation, now: i64) !Installation {
    const value = try object(alloc, bytes);
    const token_type = try identity_field(value, "token_type", if (previous != null) "bot" else null);
    const scope = try identity_field(value, "scope", if (previous) |old| old.scope else null);
    const app_id = try identity_field(value, "app_id", if (previous) |old| old.app_id else null);
    const bot_user_id = try identity_field(value, "bot_user_id", if (previous) |old| old.bot_user_id else null);
    var team_id = if (previous) |old| old.team_id else @as([]const u8, "");
    if (value.get("team")) |team| {
        if (team != .object) return error.InvalidSlackResponse;
        team_id = try string(team.object, "id");
    }
    if (!std.mem.eql(u8, token_type, "bot") or !std.mem.eql(u8, scope, bot_scope) or
        !std.mem.eql(u8, app_id, config.app_id) or !std.mem.eql(u8, team_id, config.team_id) or !valid_id(bot_user_id, "UW")) return error.SlackInstallationIdentityMismatch;
    if (value.get("is_enterprise_install")) |enterprise| {
        if (enterprise != .bool or enterprise.bool) return error.SlackInstallationIdentityMismatch;
    }
    if (previous) |old| if (!std.mem.eql(u8, bot_user_id, old.bot_user_id)) return error.SlackInstallationIdentityMismatch;
    const installed_by = if (previous) |old| old.installed_by else blk: {
        const authorizer = value.get("authed_user") orelse return error.InvalidSlackResponse;
        if (authorizer != .object) return error.InvalidSlackResponse;
        break :blk try string(authorizer.object, "id");
    };
    if (!valid_id(installed_by, "UW")) return error.InvalidSlackResponse;
    const rotating = value.contains("refresh_token") or value.contains("expires_in");
    var expires: ?i64 = null;
    var refresh: ?[]const u8 = null;
    if (rotating) {
        refresh = try string(value, "refresh_token");
        const expiry = value.get("expires_in") orelse return error.InvalidSlackResponse;
        if (expiry != .integer or expiry.integer <= 0 or expiry.integer > 86400) return error.InvalidSlackResponse;
        expires = now + expiry.integer * 1000;
    } else if (previous) |old| {
        if (old.refresh_token != null) return error.InvalidSlackResponse;
    }
    return .{ .bridge_origin = origin, .client_id = config.client_id, .app_id = app_id, .team_id = team_id, .bot_user_id = bot_user_id, .bot_id = "", .installed_by = installed_by, .scope = scope, .access_token = try string(value, "access_token"), .refresh_token = refresh, .expires_at_ms = expires, .refresh_expires_at_ms = if (rotating) now + 30 * 86400_000 else null };
}

fn validate_identity(alloc: Allocator, bytes: []const u8, record: *Installation, previous: ?Installation) !void {
    const value = try object(alloc, bytes);
    const bot_id = try string(value, "bot_id");
    if (!valid_id(bot_id, "B") or !std.mem.eql(u8, try string(value, "team_id"), record.team_id) or !std.mem.eql(u8, try string(value, "user_id"), record.bot_user_id)) return error.SlackInstallationIdentityMismatch;
    if (value.get("is_enterprise_install")) |enterprise| if (enterprise != .bool or enterprise.bool) return error.SlackInstallationIdentityMismatch;
    if (previous) |old| if (!std.mem.eql(u8, bot_id, old.bot_id)) return error.SlackInstallationIdentityMismatch;
    record.bot_id = bot_id;
}

fn load(alloc: Allocator, dir: *io.VerifiedDir) !?Installation {
    var file = io.openExistingReadOnlyRegularFile(dir.dir, "installation.json", .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) return error.UnsafeSlackCredentialFile;
    const bytes = try io.readFileToEnd(alloc, &file, 65536);
    const record = (try std.json.parseFromSlice(Installation, alloc, bytes, .{ .allocate = .alloc_always })).value;
    if (record.version != 1 or !valid_id(record.app_id, "A") or !valid_id(record.team_id, "T") or !valid_id(record.bot_user_id, "UW") or !valid_id(record.bot_id, "B") or !valid_id(record.installed_by, "UW") or !std.mem.eql(u8, record.scope, bot_scope) or record.access_token.len == 0 or
        (record.refresh_token != null) != (record.expires_at_ms != null) or (record.refresh_token != null) != (record.refresh_expires_at_ms != null)) return error.InvalidSlackCredentialFile;
    return record;
}

fn snapshot(action: Action, record: ?Installation) output.SlackSnapshot {
    return .{ .action = @tagName(action), .installed = record != null, .app_id = if (record) |r| r.app_id else null, .team_id = if (record) |r| r.team_id else null, .bot_user_id = if (record) |r| r.bot_user_id else null, .expires_at_ms = if (record) |r| r.expires_at_ms else null, .refresh_expires_at_ms = if (record) |r| r.refresh_expires_at_ms else null };
}

const Callback = struct { code: []const u8 = "", denied: bool = false };
const CallbackContext = struct { state: []const u8, consumed: bool = false };
fn parse_callback(raw: ?*anyopaque, alloc: Allocator, body: []const u8) browser.ParseResult(Callback) {
    const context: *CallbackContext = @ptrCast(@alignCast(raw.?));
    if (context.consumed) return .unrelated;
    const result = callback(alloc, body, context.state) catch |err| return if (err == error.SlackStateMismatch) .unrelated else .{ .failed = err };
    context.consumed = true;
    return .{ .accepted = result };
}
fn callback(alloc: Allocator, body: []const u8, expected: []const u8) !Callback {
    var state: ?[]const u8 = null;
    var code: ?[]const u8 = null;
    var denial: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, body, '&');
    while (fields.next()) |field| {
        const split = std.mem.findScalar(u8, field, '=') orelse return error.InvalidSlackCallback;
        const name = try decode(alloc, field[0..split]);
        const value = try decode(alloc, field[split + 1 ..]);
        const target = if (std.mem.eql(u8, name, "state")) &state else if (std.mem.eql(u8, name, "code")) &code else if (std.mem.eql(u8, name, "error")) &denial else return error.InvalidSlackCallback;
        if (target.* != null or value.len == 0) return error.InvalidSlackCallback;
        target.* = value;
    }
    if (!std.mem.eql(u8, state orelse return error.SlackStateMismatch, expected)) return error.SlackStateMismatch;
    if ((code == null) == (denial == null)) return error.InvalidSlackCallback;
    if (code) |value| if (value.len > 2048) return error.InvalidSlackCallback;
    return .{ .code = code orelse "", .denied = denial != null };
}
fn decode(alloc: Allocator, value: []const u8) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(alloc);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        var byte = value[i];
        if (byte == '%') {
            if (i + 2 >= value.len) return error.InvalidSlackCallback;
            byte = std.fmt.parseInt(u8, value[i + 1 ..][0..2], 16) catch return error.InvalidSlackCallback;
            i += 2;
        } else if (byte == '+') byte = ' ';
        if (byte < 0x21 or byte > 0x7e) return error.InvalidSlackCallback;
        try result.writer.writeByte(byte);
    }
    return result.toOwnedSlice();
}
fn append(writer: *std.Io.Writer, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte('&');
    try writer.print("{s}=", .{key});
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.findScalar(u8, "-_.~", byte) != null) try writer.writeByte(byte) else try writer.print("%{X:0>2}", .{byte});
    }
}

test "Slack callback consumes matching state once and rejects ambiguous fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var context = CallbackContext{ .state = "expected" };
    try std.testing.expect(parse_callback(&context, alloc, "state=wrong&code=code") == .unrelated);
    try std.testing.expect(!context.consumed);
    const accepted = parse_callback(&context, alloc, "state=expected&code=code%2Bvalue");
    try std.testing.expectEqualStrings("code+value", accepted.accepted.code);
    try std.testing.expect(parse_callback(&context, alloc, "state=expected&code=code") == .unrelated);
    try std.testing.expectError(error.InvalidSlackCallback, callback(alloc, "state=expected&state=expected&code=code", "expected"));
    try std.testing.expectError(error.InvalidSlackCallback, callback(alloc, "state=expected&code=code&error=denied", "expected"));
    try std.testing.expectError(error.SlackStateMismatch, callback(alloc, "code=code", "expected"));
    try std.testing.expectError(error.InvalidSlackCallback, callback(alloc, "state=expected&code=%0A", "expected"));
    try std.testing.expect((try callback(alloc, "state=expected&error=access_denied", "expected")).denied);
    try std.testing.expect(valid_id("UBOT", "UW"));
    try std.testing.expect(valid_id("WBOT", "UW"));
    try std.testing.expect(!valid_id("BBOT", "UW"));
}

test "Slack authorization deadline includes suspended time" {
    const Clock = struct {
        awake_ns: i96 = 0,
        boot_ns: i96 = 0,

        fn now(raw: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = if (clock == .boot) self.boot_ns else self.awake_ns };
        }
    };
    var clock = Clock{};
    var vtable = std.Io.failing.vtable.*;
    vtable.now = Clock.now;
    const test_io = std.Io{ .userdata = &clock, .vtable = &vtable };
    const deadline = std.Io.Clock.Timestamp.fromNow(test_io, authorization_lifetime);
    clock.awake_ns = 60 * std.time.ns_per_s;
    clock.boot_ns = clock.awake_ns;
    try std.testing.expectEqual(240 * std.time.ns_per_s, deadline.durationFromNow(test_io).raw.nanoseconds);
    clock.boot_ns += 240 * std.time.ns_per_s;
    try std.testing.expectEqual(0, deadline.durationFromNow(test_io).raw.nanoseconds);
    clock.boot_ns += std.time.ns_per_s;
    try std.testing.expect(deadline.durationFromNow(test_io).raw.nanoseconds < 0);
}

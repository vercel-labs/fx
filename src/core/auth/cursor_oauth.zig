//! Cursor sign-in (D202), as proto's `registry/oauth/cursor.ts` does it:
//! open `cursor.com/loginDeepControl` with a PKCE S256 challenge and a fresh
//! UUID, then poll `api2.cursor.sh/auth/poll?uuid=&verifier=` until it
//! returns `{accessToken, refreshToken}` (404 while the browser is still
//! pending). A pasted Cursor API key works too: it is exchanged for an
//! access token the same way a refresh token is.
//!
//! The saved credential is one string in the provider key file,
//! `<access>|<refresh>`, or a bare API key before its first exchange. The
//! access token is a JWT whose `exp` says when to refresh, five minutes early.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const openrouter_oauth = @import("openrouter_oauth.zig");
const provider_keys = @import("provider_keys.zig");
const secret = @import("secret.zig");
const Allocator = std.mem.Allocator;

pub const provider_id = "cursor";
pub const api_key_env = "CURSOR_API_KEY";
const login_url = "https://cursor.com/loginDeepControl";
const poll_url = "https://api2.cursor.sh/auth/poll";
const e2e_login_url_env = "FX_E2E_CURSOR_LOGIN_URL";
const e2e_poll_url_env = "FX_E2E_CURSOR_POLL_URL";
const login_timeout_seconds: i64 = 5 * 60;
/// Refresh this long before the token's `exp`, as proto does.
pub const refresh_margin_seconds: i64 = 5 * 60;

/// Views into a saved credential string.
pub const Credential = struct {
    /// Empty before the first exchange.
    access: []const u8,
    /// A refresh token or an API key; either exchanges for a new access token.
    refresh: []const u8,
};

pub fn parse(stored: []const u8) Credential {
    const at = std.mem.findScalar(u8, stored, '|') orelse return .{ .access = "", .refresh = stored };
    return .{ .access = stored[0..at], .refresh = stored[at + 1 ..] };
}

/// The saved form of a credential. Caller owns and zeroes it.
pub fn format(alloc: Allocator, access: []const u8, refresh: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ access, "|", refresh });
}

/// The `exp` claim of a JWT access token, in seconds, or null.
pub fn expiresAt(access: []const u8) ?i64 {
    var parts = std.mem.splitScalar(u8, access, '.');
    _ = parts.next() orelse return null;
    const payload = parts.next() orelse return null;
    if (parts.next() == null or parts.next() != null) return null;
    var buffer: [4096]u8 = undefined;
    const trimmed = std.mem.trimEnd(u8, payload, "=");
    const len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch return null;
    if (len > buffer.len) return null;
    std.base64.url_safe_no_pad.Decoder.decode(buffer[0..len], trimmed) catch return null;
    var fixed = std.heap.FixedBufferAllocator.init(buffer[len..]);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fixed.allocator(), buffer[0..len], .{}) catch return null;
    if (parsed != .object) return null;
    const exp = parsed.object.get("exp") orelse return null;
    return switch (exp) {
        .integer => |value| value,
        .float => |value| @intFromFloat(value),
        else => null,
    };
}

/// Whether `access` must be exchanged before use at `now_seconds`: it is
/// missing, has no readable expiry, or expires within the margin.
pub fn needsRefresh(access: []const u8, now_seconds: i64) bool {
    if (access.len == 0) return true;
    const exp = expiresAt(access) orelse return true;
    return exp - now_seconds < refresh_margin_seconds;
}

/// Reads `{accessToken, refreshToken}` from a poll or exchange reply into
/// the saved form. A reply without a refresh token keeps `previous`. Caller
/// owns the result.
pub fn credentialFromReply(alloc: Allocator, body: []const u8, previous: ?[]const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidCursorAuthReply;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCursorAuthReply;
    const access = parsed.value.object.get("accessToken") orelse return error.InvalidCursorAuthReply;
    if (access != .string or access.string.len == 0 or std.mem.findScalar(u8, access.string, '|') != null) return error.InvalidCursorAuthReply;
    const refresh_value = parsed.value.object.get("refreshToken");
    const refresh = if (refresh_value != null and refresh_value.? == .string and refresh_value.?.string.len != 0) refresh_value.?.string else previous orelse return error.InvalidCursorAuthReply;
    const out = try format(alloc, access.string, refresh);
    if (!provider_keys.validKey(out)) {
        secret.zeroAndFree(alloc, out);
        return error.InvalidCursorAuthReply;
    }
    return out;
}

/// The browser URL. Caller owns it.
pub fn loginUrl(alloc: Allocator, base: []const u8, challenge: []const u8, uuid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}?", .{base});
    var form: oauth.FormBody = .{};
    try form.append(&out.writer, "challenge", challenge);
    try form.append(&out.writer, "uuid", uuid);
    try form.append(&out.writer, "mode", "login");
    try form.append(&out.writer, "redirectTarget", "cli");
    return out.toOwnedSlice();
}

fn randomUuid(io: std.Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var at: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            out[at] = '-';
            at += 1;
        }
        out[at] = hex[byte >> 4];
        out[at + 1] = hex[byte & 0x0f];
        at += 2;
    }
    return out;
}

const Context = struct {
    poll_url: []u8,
    manual_mutex: std.Io.Mutex = .init,
    manual: ?[]u8 = null,

    fn deinit(self: *Context, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.poll_url);
        if (self.manual) |value| secret.zeroAndFree(alloc, value);
        self.* = undefined;
    }

    fn takeManual(self: *Context) ?[]u8 {
        self.manual_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_mutex.unlock(io_mod.getIo());
        const value = self.manual;
        self.manual = null;
        return value;
    }
};

/// Starts the browser flow on `runtime`; it completes with the credential,
/// saved to the provider key file.
pub fn startSignIn(runtime: *login_flow.SignInRuntime, alloc: Allocator, transport: oauth_transport.Provider) !bool {
    if (comptime host_target.is_wasm) return error.CursorLoginUnavailable;
    const verifier = try oauth.randomUrlSafeSecret(alloc);
    defer secret.zeroAndFree(alloc, verifier);
    const challenge = try oauth.pkceChallengeAlloc(alloc, verifier);
    defer alloc.free(challenge);
    const uuid = randomUuid(io_mod.getIo());
    const login_base = oauth.configuredEndpoint(alloc, e2e_login_url_env, login_url) catch |err| return endpointError(err);
    defer alloc.free(login_base);
    const poll_base = oauth.configuredEndpoint(alloc, e2e_poll_url_env, poll_url) catch |err| return endpointError(err);
    defer alloc.free(poll_base);
    const url = try loginUrl(alloc, login_base, challenge, &uuid);
    var url_owned = true;
    errdefer if (url_owned) alloc.free(url);
    var poll_target: std.Io.Writer.Allocating = .init(alloc);
    errdefer poll_target.deinit();
    try poll_target.writer.print("{s}?", .{poll_base});
    var form: oauth.FormBody = .{};
    try form.append(&poll_target.writer, "uuid", &uuid);
    try form.append(&poll_target.writer, "verifier", verifier);
    const token_endpoint = try alloc.dupe(u8, poll_base);
    var token_endpoint_owned = true;
    errdefer if (token_endpoint_owned) alloc.free(token_endpoint);
    var prepared = try login_flow.prepareBrowserLogin(alloc, .{
        .issuer = login_base,
        .authorization_endpoint_suffix = "",
        .token_endpoint = token_endpoint,
        .verification_uri = url,
        .client_id = "",
        .expires_in = login_timeout_seconds,
    });
    url_owned = false;
    token_endpoint_owned = false;
    errdefer prepared.deinit(alloc);
    const context = try alloc.create(Context);
    errdefer alloc.destroy(context);
    context.* = .{ .poll_url = try poll_target.toOwnedSlice() };
    return runtime.startPrepared(alloc, prepared, .{
        .ctx = context,
        .deinit_ctx = deinitContext,
        .oauth_transport = transport,
        .poll = .{ .ctx = context, .poll_device_token = poll },
        .complete = complete,
        .save = save,
        .submit_manual_code = submitManual,
    });
}

fn endpointError(err: anyerror) anyerror {
    return if (err == error.OutOfMemory) err else error.InvalidE2ECursorEndpoint;
}

fn deinitContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.deinit(alloc);
    alloc.destroy(context);
}

/// A pasted Cursor API key, saved as is and exchanged on first use.
fn submitManual(raw: ?*anyopaque, alloc: Allocator, input: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (!provider_keys.validKey(value) or std.mem.findScalar(u8, value, '|') != null) return error.InvalidProviderKey;
    const owned = try alloc.dupe(u8, value);
    context.manual_mutex.lockUncancelable(io_mod.getIo());
    defer context.manual_mutex.unlock(io_mod.getIo());
    if (context.manual) |pending| secret.zeroAndFree(alloc, pending);
    context.manual = owned;
}

fn poll(
    raw: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    _: oauth.Metadata,
    _: []const u8,
    _: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *Context = @ptrCast(@alignCast(raw.?));
    if (context.takeManual()) |key| {
        defer secret.zeroAndFree(alloc, key);
        return keyResult(alloc, key);
    }
    var response = try transport.execute(alloc, .{ .method = .get, .url = context.poll_url, .cancel_flag = cancel_flag, .deadline = deadline });
    defer response.deinit(alloc);
    // 404 until the browser finishes; any other refusal also keeps waiting
    // until the login's own deadline.
    if (response.disposition != .accepted) return .pending;
    const credential = credentialFromReply(alloc, response.body, null) catch |err| {
        debug_trace.logf("auth", "Cursor poll reply rejected err={s}", .{@errorName(err)});
        return err;
    };
    defer secret.zeroAndFree(alloc, credential);
    return keyResult(alloc, credential);
}

fn keyResult(alloc: Allocator, key: []const u8) !oauth.PollResult {
    const access = try alloc.dupe(u8, key);
    return .{ .success = .{ .access_token = access, .expires_in = 0, .scope = try alloc.alloc(u8, 0), .token_type = try alloc.alloc(u8, 0) } };
}

fn complete(_: ?*anyopaque, _: Allocator, _: []const u8, _: []const u8, token: *oauth.TokenSet) !login_flow.SignInCompletion {
    const completion: login_flow.SignInCompletion = .{ .provider_key = .{
        .provider = .fromProvider(model_provider.parse(provider_id).?),
        .key = token.access_token,
    } };
    token.access_token = &.{};
    return completion;
}

fn save(_: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const value = switch (completion) {
        .provider_key => |value| value,
        else => return error.InvalidSignInCompletion,
    };
    try provider_keys.save(alloc, value.provider.label(), value.key);
}

/// `fx login cursor`: prints the URL, opens the browser, and polls, or
/// takes a pasted API key from standard input.
pub fn runLogin(alloc: Allocator, transport: oauth_transport.Provider, url_opener: host.UrlOpener) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignIn(&runtime, alloc, transport)) return error.CursorLoginBusy;
    const url = (try runtime.browserUrlAlloc(alloc)) orelse return error.CursorAuthorizationUrlMissing;
    defer alloc.free(url);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io_mod.getIo(), "Open this URL to sign in to Cursor:\n");
    try stdout.writeStreamingAll(io_mod.getIo(), url);
    try stdout.writeStreamingAll(io_mod.getIo(), "\n\nWaiting for the browser. Or paste a Cursor API key and press enter.\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) _ = url_opener.open(alloc, url) catch false;
    var line: openrouter_oauth.LineReader = .{};
    defer line.clear();
    while (true) {
        if (try line.poll()) |text| {
            // A blank line keeps waiting for the browser.
            if (std.mem.trim(u8, text, " \t\r\n").len != 0) _ = try runtime.submitManualCode(alloc, text);
            line.clear();
        }
        switch (runtime.pollTransition(alloc)) {
            .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
            .succeeded => |completion| {
                var owned = completion;
                owned.deinit(alloc);
                return;
            },
            .failed => |err| return err,
            .cancelled => return error.Cancelled,
        }
    }
}

fn testJwt(alloc: Allocator, payload: []const u8) ![]u8 {
    const encoded = try alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer alloc.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.mem.concat(alloc, u8, &.{ "eyJhbGciOiJIUzI1NiJ9.", encoded, ".sig" });
}

test "saved Cursor credentials split into access and refresh, and a bare key refreshes" {
    const both = parse("acc.ess.tok|refresh-1");
    try std.testing.expectEqualStrings("acc.ess.tok", both.access);
    try std.testing.expectEqualStrings("refresh-1", both.refresh);
    const key = parse("key_abc");
    try std.testing.expectEqualStrings("", key.access);
    try std.testing.expectEqualStrings("key_abc", key.refresh);
}

test "the JWT expiry decides when to refresh, five minutes early" {
    const alloc = std.testing.allocator;
    const token = try testJwt(alloc, "{\"sub\":\"auth0|user_1\",\"exp\":2000}");
    defer alloc.free(token);
    try std.testing.expectEqual(@as(?i64, 2000), expiresAt(token));
    try std.testing.expect(!needsRefresh(token, 1000));
    try std.testing.expect(needsRefresh(token, 1701));
    try std.testing.expect(needsRefresh("", 0));
    try std.testing.expect(needsRefresh("not-a-jwt", 0));
}

test "poll and exchange replies become the saved credential" {
    const alloc = std.testing.allocator;
    const saved = try credentialFromReply(alloc, "{\"accessToken\":\"a.b.c\",\"refreshToken\":\"r1\"}", null);
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("a.b.c|r1", saved);
    const kept = try credentialFromReply(alloc, "{\"accessToken\":\"a.b.d\"}", "key_1");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("a.b.d|key_1", kept);
    try std.testing.expectError(error.InvalidCursorAuthReply, credentialFromReply(alloc, "{\"accessToken\":\"\"}", "r"));
    try std.testing.expectError(error.InvalidCursorAuthReply, credentialFromReply(alloc, "{\"accessToken\":\"x\"}", null));
    const url = try loginUrl(alloc, login_url, "ch-_", "u-1");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://cursor.com/loginDeepControl?challenge=ch-_&uuid=u-1&mode=login&redirectTarget=cli", url);
}

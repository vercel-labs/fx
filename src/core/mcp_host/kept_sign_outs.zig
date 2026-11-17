//! MCP sign-outs whose server did not confirm the revocation, kept so that fx
//! can revoke their tokens later (`auth/pending_revocation.zig`).
//!
//! A logout keeps what each revocation it sends needs before it removes the
//! saved login, next to the credential store that held it: in the Keychain
//! when the store is there, else in `mcp-revocations.json` in the profile
//! folder. It forgets it once the server answers with a 2xx. What stays
//! kept is sent again here, as the engine's `Auth.signOut` sends it (RFC
//! 7009), by `fx mcp login` and `fx mcp logout` and on a worker at each TUI
//! start. The endpoint is checked again with the engine's own rule
//! (`discovery.fetchable`), so a record changed on disk can't send a token
//! where its server's sign-in could not.

const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const auth_oauth = @import("../auth/oauth.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const credentials = @import("credentials.zig");
const pending_revocation = @import("../auth/pending_revocation.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;
const oauth = mcp.auth.oauth;
const discovery = mcp.auth.discovery;
const wire = mcp.wire;

pub const Tokens = pending_revocation.Tokens;
pub const RetryOutcome = pending_revocation.RetryOutcome;

/// Room for `oauth.basicAuthorization`'s work on a kept client id and
/// secret: each at most `pending_revocation` field size, three bytes per
/// byte escaped, in a writer that grows by doubling, then base64. Under
/// 128 KiB.
const authorization_scratch_bytes: usize = 160 * 1024;

/// What a sign-out of `saved`, a credential the engine wrote (`Auth.save`)
/// for the server at `server_url`, revokes: its refresh token when it has
/// one, else its access token. Null when it revokes nothing: the credential
/// can't be read, names no client, or has no revocation endpoint that the
/// server's discovery may reach. The slices are in `arena` or in `saved`.
pub fn tokensOf(arena: Allocator, saved: []const u8, server_url: []const u8) Allocator.Error!?Tokens {
    const names = [_][]const u8{ "access", "refresh", "revocation_endpoint", "client_id", "client_secret", "method" };
    var raw: [names.len]?[]const u8 = undefined;
    wire.objectFields(saved, &names, &raw) catch return null;
    var text: [names.len]?[]const u8 = undefined;
    for (raw, &text) |r, *t| t.* = if (r) |v| try wire.decodeString(arena, v) else null;
    const endpoint = text[2] orelse return null;
    if (!discovery.fetchable(endpoint, server_url)) return null;
    const client_id = text[3] orelse return null;
    const method = text[5] orelse return null;
    _ = std.meta.stringToEnum(oauth.Method, method) orelse return null;
    const refresh = nonEmpty(text[1]);
    const token = refresh orelse nonEmpty(text[0]) orelse return null;
    return .{
        .refresh_token = token,
        .token_type_hint = if (refresh != null) "refresh_token" else "access_token",
        .revocation_endpoint = endpoint,
        .client_id = client_id,
        .client_secret = text[4] orelse "",
        .client_auth = method,
        .server_url = server_url,
    };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Where `store`'s logins keep their sign-outs: in the Keychain when it is
/// there, else in a private file in the profile folder of its home.
fn placeOf(store: credentials.Store) pending_revocation.Place {
    return pending_revocation.mcpPlace(store.home, store.backend == .keychain);
}

/// Keeps a sign-out of one of `store`'s logins before its revocation is sent.
/// Returns whether it was kept; the debug trace says why when it wasn't.
pub fn keep(alloc: Allocator, store: credentials.Store, tokens: Tokens) bool {
    return pending_revocation.keepIn(alloc, placeOf(store), tokens);
}

/// Forgets a kept sign-out once its server confirmed the revocation.
pub fn forget(alloc: Allocator, store: credentials.Store, token: []const u8) void {
    pending_revocation.forgetIn(alloc, placeOf(store), token);
}

/// Revokes every sign-out kept for the logins saved under `home`, oldest
/// first (`pending_revocation.retry`). With none kept, it reads neither the
/// Keychain nor which store is in use, so a start pays only for two file
/// checks.
pub fn retry(alloc: Allocator, home: []const u8, transport: oauth_transport.Provider, before: ?auth_oauth.BeforeRevocation) RetryOutcome {
    if (!pending_revocation.mcpMayHaveKept(home)) return .{};
    const store = credentials.Store.detect(alloc, home);
    return pending_revocation.retryIn(alloc, placeOf(store), .{ .context = &transport, .run = revokeKept }, before);
}

fn revokeKept(context: *const anyopaque, alloc: Allocator, tokens: Tokens) anyerror!void {
    const transport: *const oauth_transport.Provider = @ptrCast(@alignCast(context));
    return revoke(alloc, transport.*, tokens);
}

/// Sends one kept sign-out's revocation. `error.KeptSignOutUnusable` means
/// it can never be sent, and the retry drops it.
fn revoke(alloc: Allocator, transport: oauth_transport.Provider, tokens: Tokens) !void {
    const method = std.meta.stringToEnum(oauth.Method, tokens.client_auth) orelse return error.KeptSignOutUnusable;
    const hint_known = std.mem.eql(u8, tokens.token_type_hint, "refresh_token") or std.mem.eql(u8, tokens.token_type_hint, "access_token");
    if (!hint_known or tokens.client_id.len == 0) return error.KeptSignOutUnusable;
    if (!discovery.fetchable(tokens.revocation_endpoint, tokens.server_url)) return error.KeptSignOutUnusable;
    const client: oauth.Client = .{
        .id = tokens.client_id,
        .secret = if (tokens.client_secret.len != 0) tokens.client_secret else null,
        .method = method,
    };
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer {
        std.crypto.secureZero(u8, body.writer.buffer);
        body.deinit();
    }
    oauth.writeTokenRequest(&body.writer, .{ .revoke = .{ .token = tokens.refresh_token, .hint = tokens.token_type_hint } }, "", client) catch return error.OutOfMemory;
    // `basicAuthorization` leaves its scratch to an arena, as the engine's
    // flow arena takes it. This one is zeroed after, since the scratch and
    // the header hold the client secret.
    const scratch = try alloc.alloc(u8, authorization_scratch_bytes);
    defer secret.zeroAndFree(alloc, scratch);
    var fixed: std.heap.FixedBufferAllocator = .init(scratch);
    const authorization = try oauth.basicAuthorization(fixed.allocator(), client);
    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = tokens.revocation_endpoint,
        .payload = body.written(),
        .authorization = authorization,
    });
    defer response.deinit(alloc);
    if (!confirmed(response)) {
        debug_trace.logf("mcp", "MCP kept sign-out refused by its server status={d}", .{response.status});
        return error.RevocationRefused;
    }
}

/// Whether the server confirmed the revocation: any 2xx, as the logout itself
/// takes it (RFC 7009 section 2.2), or `accepted` from a transport that
/// gives no status.
fn confirmed(response: oauth_transport.Response) bool {
    if (response.status == 0) return response.disposition == .accepted;
    return response.status >= 200 and response.status < 300;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn savedCredential(comptime fields: []const u8) []const u8 {
    return "{\"access\":\"at\",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"https://auth.example.com/token\",\"resource\":\"https://mcp.example.com/mcp\",\"scope\":[],\"step_up\":[]," ++ fields ++ "}";
}

test "a saved credential's sign-out revokes its refresh token, or else its access token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = "https://mcp.example.com/mcp";

    const both = (try tokensOf(a, savedCredential("\"refresh\":\"rt\",\"revocation_endpoint\":\"https://auth.example.com/revoke\",\"client_id\":\"cid\",\"client_secret\":\"cs\",\"method\":\"client_secret_basic\""), server)).?;
    try testing.expectEqualStrings("rt", both.refresh_token);
    try testing.expectEqualStrings("refresh_token", both.token_type_hint);
    try testing.expectEqualStrings("https://auth.example.com/revoke", both.revocation_endpoint);
    try testing.expectEqualStrings("cid", both.client_id);
    try testing.expectEqualStrings("cs", both.client_secret);
    try testing.expectEqualStrings("client_secret_basic", both.client_auth);
    try testing.expectEqualStrings(server, both.server_url);

    const access_only = (try tokensOf(a, savedCredential("\"refresh\":null,\"revocation_endpoint\":\"https://auth.example.com/revoke\",\"client_id\":\"cid\",\"client_secret\":null,\"method\":\"none\""), server)).?;
    try testing.expectEqualStrings("at", access_only.refresh_token);
    try testing.expectEqualStrings("access_token", access_only.token_type_hint);
    try testing.expectEqualStrings("", access_only.client_secret);
}

test "a saved credential with nothing to revoke, or an endpoint its server may not use, keeps nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = "https://mcp.example.com/mcp";
    // No revocation endpoint: the server takes none.
    try testing.expect(try tokensOf(a, savedCredential("\"refresh\":\"rt\",\"revocation_endpoint\":null,\"client_id\":\"cid\",\"method\":\"none\""), server) == null);
    // One the engine refuses to contact for this server.
    try testing.expect(try tokensOf(a, savedCredential("\"refresh\":\"rt\",\"revocation_endpoint\":\"https://169.254.169.254/revoke\",\"client_id\":\"cid\",\"method\":\"none\""), server) == null);
    // No client, or an unknown way to authenticate it.
    try testing.expect(try tokensOf(a, savedCredential("\"refresh\":\"rt\",\"revocation_endpoint\":\"https://auth.example.com/revoke\",\"method\":\"none\""), server) == null);
    try testing.expect(try tokensOf(a, savedCredential("\"refresh\":\"rt\",\"revocation_endpoint\":\"https://auth.example.com/revoke\",\"client_id\":\"cid\",\"method\":\"magic\""), server) == null);
    // Not a credential at all.
    try testing.expect(try tokensOf(a, "not json", server) == null);
}

/// A transport that records the one request it gets and answers with
/// `accept`.
const FakeTransport = struct {
    accept: bool = true,
    /// The HTTP status to give, 0 for none.
    status: u16 = 0,
    url: ?[]u8 = null,
    payload: ?[]u8 = null,
    authorization: ?[]u8 = null,

    fn provider(self: *FakeTransport) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }

    fn deinit(self: *FakeTransport) void {
        inline for (.{ "url", "payload", "authorization" }) |name| if (@field(self, name)) |v| testing.allocator.free(v);
    }

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) anyerror!oauth_transport.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        try testing.expectEqual(oauth_transport.Method.post_form, request.method);
        self.url = try testing.allocator.dupe(u8, request.url);
        self.payload = try testing.allocator.dupe(u8, request.payload.?);
        if (request.authorization) |v| self.authorization = try testing.allocator.dupe(u8, v);
        return .{ .disposition = if (self.accept) .accepted else .rejected, .body = try alloc.dupe(u8, ""), .status = self.status };
    }
};

test "a kept sign-out is revoked as the engine's sign-out sends it" {
    var basic: FakeTransport = .{};
    defer basic.deinit();
    try revoke(testing.allocator, basic.provider(), .{
        .refresh_token = "rt&1",
        .token_type_hint = "refresh_token",
        .revocation_endpoint = "https://auth.example.com/revoke",
        .client_id = "cid",
        .client_secret = "cs",
        .client_auth = "client_secret_basic",
        .server_url = "https://mcp.example.com/mcp",
    });
    try testing.expectEqualStrings("https://auth.example.com/revoke", basic.url.?);
    try testing.expectEqualStrings("token=rt%261&token_type_hint=refresh_token", basic.payload.?);
    try testing.expectEqualStrings("Basic Y2lkOmNz", basic.authorization.?);

    var public: FakeTransport = .{};
    defer public.deinit();
    try revoke(testing.allocator, public.provider(), .{
        .refresh_token = "at",
        .token_type_hint = "access_token",
        .revocation_endpoint = "https://auth.example.com/revoke",
        .client_id = "cid",
        .client_auth = "none",
        .server_url = "https://mcp.example.com/mcp",
    });
    try testing.expectEqualStrings("token=at&token_type_hint=access_token&client_id=cid", public.payload.?);
    try testing.expect(public.authorization == null);
}

test "any 2xx confirms a kept revocation, as it confirms the logout's own" {
    const tokens: Tokens = .{
        .refresh_token = "rt",
        .token_type_hint = "refresh_token",
        .revocation_endpoint = "https://auth.example.com/revoke",
        .client_id = "cid",
        .client_auth = "none",
        .server_url = "https://mcp.example.com/mcp",
    };
    // The transport calls only a 200 accepted, but the status says 204.
    for ([_]u16{ 200, 204, 299 }) |status| {
        var fake: FakeTransport = .{ .accept = status == 200, .status = status };
        defer fake.deinit();
        try revoke(testing.allocator, fake.provider(), tokens);
    }
    for ([_]u16{ 199, 300, 401, 503 }) |status| {
        var fake: FakeTransport = .{ .accept = false, .status = status };
        defer fake.deinit();
        try testing.expectError(error.RevocationRefused, revoke(testing.allocator, fake.provider(), tokens));
    }
    // A transport without a status is taken at its word.
    var bare: FakeTransport = .{ .accept = true };
    defer bare.deinit();
    try revoke(testing.allocator, bare.provider(), tokens);
}

test "a refused revocation is retried later, and an unusable record is never sent" {
    var refusing: FakeTransport = .{ .accept = false };
    defer refusing.deinit();
    const tokens: Tokens = .{
        .refresh_token = "rt",
        .token_type_hint = "refresh_token",
        .revocation_endpoint = "https://auth.example.com/revoke",
        .client_id = "cid",
        .client_auth = "none",
        .server_url = "https://mcp.example.com/mcp",
    };
    try testing.expectError(error.RevocationRefused, revoke(testing.allocator, refusing.provider(), tokens));
    try testing.expect(pending_revocation.retryable(error.RevocationRefused));

    var unused: FakeTransport = .{};
    defer unused.deinit();
    var moved = tokens;
    moved.revocation_endpoint = "https://169.254.169.254/revoke";
    try testing.expectError(error.KeptSignOutUnusable, revoke(testing.allocator, unused.provider(), moved));
    var no_method = tokens;
    no_method.client_auth = "";
    try testing.expectError(error.KeptSignOutUnusable, revoke(testing.allocator, unused.provider(), no_method));
    try testing.expect(unused.url == null);
    try testing.expect(!pending_revocation.retryable(error.KeptSignOutUnusable));
}

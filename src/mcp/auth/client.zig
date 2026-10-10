//! OAuth for one MCP server: the `core/auth.zig` machines, the tokens and
//! registrations they name, and the discovery, registration, and token
//! requests, made with `fetch` on the server's `io/http.zig` client.
//!
//! `server.zig` asks before every request and says how each one ended; this
//! answers with actions: what to post and with which token, which requests
//! gave up, and what the host should hear. Signing in is the host's to start
//! (`signIn`) and finish (`finishSignIn` with the URL the browser came back
//! to); the module never opens a browser.

const std = @import("std");
const core = @import("../core/auth.zig");
const discovery = @import("discovery.zig");
const oauth = @import("oauth.zig");
const http = @import("../io/http.zig");
const trace = @import("../io/trace.zig");
const wire = @import("../protocol/wire.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// A pre-registered client for this server's authorization server,
    /// tried before anything else.
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    /// The client ID metadata document's URL, used when the
    /// authorization server supports them. None until fx hosts one.
    client_metadata_url: ?[]const u8 = null,
    client_name: []const u8 = "fx",
    flow: core.FlowConfig = .{},
    /// A credential `save` wrote before, which the host kept
    /// securely; its tokens are used again.
    saved: ?[]const u8 = null,
};

/// Why a sign-in ended without a token.
pub const Failure = enum { discovery, registration, response, redemption, cancelled, refused };

pub const Action = union(enum) {
    /// Post request `key`, again if it went out before, with the token of
    /// generation `token`: its header is `authorization(token)`.
    post: struct { key: u64, token: u32 },
    /// Request `key` ends without a usable token.
    give_up: struct { key: u64, why: core.GiveUp },
    /// Requests need a sign-in: a 401 a refresh can't fix, or a 403 asking for
    /// more scopes (`step_up`).
    needs_sign_in: struct { step_up: bool },
    /// The host opens this authorization URL; it stays valid until the next
    /// sign-in starts.
    authorize: []const u8,
    signed_in,
    /// `message` is the authorization server's error, only from a response
    /// that passed the checks, or the token endpoint's when it
    /// gave no token.
    sign_in_failed: struct { why: Failure, message: ?[]const u8 = null },
    /// The credential to keep changed; the host writes it with
    /// `save`, which says when there is none to keep.
    save,
};

/// How a request ended, as the gate needs it.
pub const Ending = union(enum) {
    /// Anything but a rejection.
    answered,
    /// 401, or 403 with a challenge, and the challenge.
    rejected: struct { status: u16, challenge: []const u8 },
    /// The client gave up on it.
    forgotten,
};

/// Keys of this module's own requests: above `server.zig`'s auxiliary keys.
pub const fetch_base: u64 = 3 << 62;

const Stage = enum { idle, resource_metadata, server_metadata, registration, token };

/// What a refresh needs, from the sign-in that brought the tokens.
const Credential = struct {
    token_endpoint: []const u8,
    /// Where sign-out revokes, when the authorization server says.
    revocation_endpoint: ?[]const u8 = null,
    resource: []const u8,
    client: oauth.Client,
};

pub const Auth = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    client: *http.Client,
    server_url: []const u8,
    trace: ?*trace.Writer,
    gate: core.Gate = .{},
    flow: core.Flow,
    /// Issuers, registrations, and scope names: kept for the session.
    keep: std.heap.ArenaAllocator,
    /// One sign-in's data: reset when the next starts.
    flow_arena: std.heap.ArenaAllocator,
    /// The credential's data: replaced at each sign-in.
    cred_arena: std.heap.ArenaAllocator,
    issuers: [core.max_issuers][]const u8 = undefined,
    issuer_count: u8 = 0,
    registrations: [core.max_issuers]?oauth.Registration = @splat(null),
    scopes: oauth.ScopeSet = .{},
    /// The tokens, zeroed when they go.
    access: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    bearer: ?[]u8 = null,
    expires_at_ms: ?i64 = null,
    /// How long before expiry a request refreshes first.
    skew_ms: i64 = 30_000,
    cred: ?Credential = null,
    /// The latest challenge's resource_metadata.
    challenge_url: ?[]u8 = null,
    announced: bool = false,
    // The sign-in in progress.
    stage: Stage = .idle,
    redirect_uri: []const u8 = "",
    candidates: []const []const u8 = &.{},
    candidate: usize = 0,
    prm: ?discovery.ResourceMetadata = null,
    meta: ?discovery.ServerMetadata = null,
    pkce: oauth.Pkce = undefined,
    state: [22]u8 = undefined,
    authorization_url: []const u8 = "",
    response_error: ?[]const u8 = null,
    /// Why the code wasn't redeemed, in the token endpoint's words.
    token_error: ?[]const u8 = null,
    pending_code: ?[]const u8 = null,
    flow_key: u64 = 0,
    refresh_key: u64 = 0,
    /// The revocation a sign-out sent, until its answer: closing waits for it.
    revoke_key: u64 = 0,
    next_key: u64 = fetch_base,
    actions: std.ArrayList(Action) = .empty,

    pub fn init(io: std.Io, gpa: Allocator, client: *http.Client, server_url: []const u8, options: Options, tracer: ?*trace.Writer) Auth {
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .client = client,
            .server_url = server_url,
            .trace = tracer,
            .flow = .{ .config = options.flow },
            .keep = .init(gpa),
            .flow_arena = .init(gpa),
            .cred_arena = .init(gpa),
        };
    }

    pub fn deinit(a: *Auth) void {
        a.dropTokens();
        if (a.challenge_url) |u| a.gpa.free(u);
        a.keep.deinit();
        a.flow_arena.deinit();
        a.cred_arena.deinit();
        a.actions.deinit(a.gpa);
    }

    /// The actions so far, emptied by the next call.
    pub fn drain(a: *Auth) []const Action {
        defer a.actions.clearRetainingCapacity();
        return a.actions.items;
    }

    // ---- Requests (the gate) ----

    /// The `Authorization` value for a post of token generation `token`: none
    /// for 0, or for a token since replaced.
    pub fn authorization(a: *const Auth, token: u32) ?[]const u8 {
        return if (token != 0 and token == a.gate.gen and a.gate.held) a.bearer else null;
    }

    /// Request `key` is about to go out.
    pub fn beforeSend(a: *Auth, key: u64) Error!void {
        const expiring = if (a.expires_at_ms) |at| a.now() + a.skew_ms >= at else false;
        try a.stepGate(.{ .send = .{ .key = key, .expiring = expiring } });
    }

    /// Request `key` ended. False when a rejection isn't the gate's: a 403
    /// that asks for nothing the client can sign in for.
    pub fn ended(a: *Auth, key: u64, how: Ending) Error!bool {
        switch (how) {
            .answered => {
                try a.stepGate(.{ .accepted = key });
                if (a.flow.auths > 0 and a.flow.token_issuer != 0) try a.stepFlow(.accepted);
            },
            .forgotten => try a.stepGate(.{ .forget = key }),
            .rejected => |r| {
                const c = (try discovery.parseChallenge(a.flow_arena.allocator(), r.challenge)) orelse discovery.Challenge{};
                if (c.resource_metadata) |url| {
                    if (a.challenge_url) |old| a.gpa.free(old);
                    a.challenge_url = try a.gpa.dupe(u8, url);
                }
                if (r.status == 403) {
                    if (!c.insufficient_scope) {
                        try a.stepGate(.{ .accepted = key });
                        return false;
                    }
                    // A refresh brings no new scopes; this needs a sign-in.
                    try a.stepFlow(.{ .challenged = try a.scopeBits(c.scope) });
                    try a.stepGate(.{ .accepted = key });
                    try a.actions.append(a.gpa, .{ .give_up = .{ .key = key, .why = .needs_sign_in } });
                    try a.announce(true);
                    return true;
                }
                // The challenge's scopes, or none, which leaves the
                // resource metadata's.
                try a.stepFlow(.{ .challenged = try a.scopeBits(c.scope) });
                try a.stepGate(.{ .rejected = key });
            },
        }
        return true;
    }

    fn scopeBits(a: *Auth, list: ?[]const u8) Allocator.Error!u32 {
        return a.scopes.ofList(a.keep.allocator(), list orelse return 0);
    }

    fn stepGate(a: *Auth, event: core.GateEvent) Error!void {
        var out: core.GateOutput = .{};
        a.gate.step(event, &out);
        if (trace.on(a.trace)) |t| try core.writeGateTrace(t, "remote", &a.gate, &out);
        for (out.effects()) |effect| switch (effect) {
            .post => |p| try a.actions.append(a.gpa, .{ .post = .{ .key = p.key, .token = p.token } }),
            .refresh => try a.startRefresh(),
            .give_up => |g| {
                try a.actions.append(a.gpa, .{ .give_up = .{ .key = g.key, .why = g.why } });
                if (g.why == .needs_sign_in) try a.announce(false);
            },
        };
    }

    fn announce(a: *Auth, step_up: bool) Allocator.Error!void {
        if (a.announced) return;
        a.announced = true;
        try a.actions.append(a.gpa, .{ .needs_sign_in = .{ .step_up = step_up } });
    }

    fn startRefresh(a: *Auth) Error!void {
        const cred = a.cred orelse return a.refreshEnded(.failed);
        const token = a.refresh_token orelse return a.refreshEnded(.failed);
        var body: std.Io.Writer.Allocating = .init(a.gpa);
        defer body.deinit();
        try oauth.writeTokenRequest(&body.writer, .{ .refresh = token }, cred.resource, cred.client);
        a.refresh_key = a.newKey();
        a.post(a.refresh_key, cred.token_endpoint, body.written(), "application/x-www-form-urlencoded", try oauth.basicAuthorization(a.flow_arena.allocator(), cred.client)) catch
            return a.refreshEnded(.failed);
    }

    fn refreshEnded(a: *Auth, how: core.Refreshed) Error!void {
        a.refresh_key = 0;
        if (how == .refused) {
            a.dropTokens();
            try a.actions.append(a.gpa, .save);
        }
        try a.stepGate(.{ .refreshed = how });
    }

    // ---- Signing in (the flow) ----

    /// Starts a sign-in that will come back to `redirect_uri`, a loopback or
    /// HTTPS URL. The host hears `authorize` with the URL to open,
    /// then `signed_in` or `sign_in_failed`.
    pub fn signIn(a: *Auth, redirect_uri: []const u8) Error!void {
        if (!discovery.secureOrLoopback(redirect_uri)) return error.InvalidRedirect;
        if (a.flow.phase == .idle) {
            _ = a.flow_arena.reset(.retain_capacity);
            a.token_error = null;
            a.redirect_uri = try a.flow_arena.allocator().dupe(u8, redirect_uri);
        }
        try a.stepFlow(.sign_in);
    }

    /// The URL the browser came back to after the authorization request.
    pub fn finishSignIn(a: *Auth, callback: []const u8) Error!void {
        if (a.flow.phase != .authorizing) return;
        const issuer = a.issuers[a.flow.flow_issuer - 1];
        const fa = a.flow_arena.allocator();
        const r = oauth.parseResponse(fa, callback, a.redirect_uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Not the redirect the flow asked for: it fails every check.
            else => oauth.Response{},
        };
        a.response_error = r.err_description orelse r.err;
        a.pending_code = r.code;
        try a.stepFlow(.{ .responded = oauth.checkResponse(r, &a.state, issuer, a.meta.?.iss_supported) });
    }

    pub fn cancelSignIn(a: *Auth) Error!void {
        if (a.flow.phase != .idle) try a.stepFlow(.cancel);
    }

    /// Revokes the refresh token, or else the access token, where the
    /// authorization server takes revocations (RFC 7009), without waiting
    /// for the answer, and forgets the tokens. Registrations stay. Closing
    /// waits for the answer.
    pub fn signOut(a: *Auth) Error!void {
        if (a.cred) |cred| if (cred.revocation_endpoint) |endpoint| if (a.refresh_token orelse a.access) |token| {
            var body: std.Io.Writer.Allocating = .init(a.gpa);
            defer body.deinit();
            const hint = if (a.refresh_token != null) "refresh_token" else "access_token";
            try oauth.writeTokenRequest(&body.writer, .{ .revoke = .{ .token = token, .hint = hint } }, "", cred.client);
            const key = a.newKey();
            a.revoke_key = key;
            a.post(key, endpoint, body.written(), "application/x-www-form-urlencoded", try oauth.basicAuthorization(a.flow_arena.allocator(), cred.client)) catch {
                a.revoke_key = 0;
            };
        };
        a.dropTokens();
        try a.actions.append(a.gpa, .save);
        try a.stepFlow(.signed_out);
        try a.stepGate(.signed_out);
    }

    /// Writes the credential to keep, a JSON object with the
    /// tokens, their expiry, and what a refresh and a revocation need. False
    /// when there is none, and the host forgets what it kept.
    pub fn save(a: *const Auth, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        const cred = a.cred orelse return false;
        const access = a.access orelse return false;
        var json: std.json.Stringify = .{ .writer = w };
        try json.write(.{
            .access = access,
            .refresh = a.refresh_token,
            .expires_at_ms = a.expires_at_ms,
            .skew_ms = a.skew_ms,
            .token_endpoint = cred.token_endpoint,
            .revocation_endpoint = cred.revocation_endpoint,
            .resource = cred.resource,
            .client_id = cred.client.id,
            .client_secret = cred.client.secret,
            .method = @tagName(cred.client.method),
        });
        return true;
    }

    /// Takes back a credential `save` wrote: its tokens are held again, so
    /// requests carry them and a refresh can renew them. One that can't be
    /// read is ignored.
    pub fn restore(a: *Auth, saved: []const u8) Error!void {
        const names = [_][]const u8{ "access", "refresh", "expires_at_ms", "skew_ms", "token_endpoint", "revocation_endpoint", "resource", "client_id", "client_secret", "method" };
        var raw: [names.len]?[]const u8 = undefined;
        wire.objectFields(saved, &names, &raw) catch return;
        _ = a.cred_arena.reset(.retain_capacity);
        const ca = a.cred_arena.allocator();
        var text: [names.len]?[]const u8 = undefined;
        for (raw, &text) |r, *t| t.* = if (r) |v| try wire.decodeString(ca, v) else null;
        const access = text[0] orelse return;
        const method = std.meta.stringToEnum(oauth.Method, text[9] orelse return) orelse return;
        a.cred = .{
            .token_endpoint = text[4] orelse return,
            .revocation_endpoint = text[5],
            .resource = text[6] orelse return,
            .client = .{ .id = text[7] orelse return, .secret = text[8], .method = method },
        };
        a.dropTokens();
        try a.storeTokens(.{ .access = access, .refresh = text[1], .expires_in = null });
        a.expires_at_ms = if (raw[2]) |v| std.fmt.parseInt(i64, v, 10) catch null else null;
        if (raw[3]) |v| a.skew_ms = std.fmt.parseInt(i64, v, 10) catch a.skew_ms;
        try a.stepGate(.{ .signed_in = .{ .refreshable = a.refresh_token != null } });
    }

    fn stepFlow(a: *Auth, event: core.FlowEvent) Error!void {
        var out: core.FlowOutput = .{};
        a.flow.step(event, &out);
        if (trace.on(a.trace)) |t| try core.writeFlowTrace(t, "remote", &a.flow, &out);
        for (out.effects()) |effect| switch (effect) {
            .discover => {
                a.prm = null;
                a.meta = null;
                a.candidates = try discovery.resourceMetadataUrls(a.flow_arena.allocator(), a.server_url, a.challenge_url);
                a.candidate = 0;
                try a.fetchCandidate(.resource_metadata);
            },
            .register => try a.register(),
            .authorize => |mask| try a.authorize(mask),
            .redeem => try a.redeem(),
            .drop_token => {
                a.dropTokens();
                try a.actions.append(a.gpa, .save);
                try a.stepGate(.signed_out);
            },
            .signed_in => {
                a.announced = false;
                try a.stepGate(.{ .signed_in = .{ .refreshable = a.refresh_token != null } });
                try a.actions.append(a.gpa, .signed_in);
            },
            .failed => |f| {
                a.stage = .idle;
                try a.actions.append(a.gpa, .{ .sign_in_failed = .{
                    .why = switch (f.stage) {
                        inline else => |s| @field(Failure, @tagName(s)),
                    },
                    .message = if (f.show_error) a.response_error else if (f.stage == .redemption) a.token_error else null,
                } });
            },
            .refused => try a.actions.append(a.gpa, .{ .sign_in_failed = .{ .why = .refused } }),
        };
    }

    /// Fetches the stage's next candidate URL, or ends discovery without one.
    fn fetchCandidate(a: *Auth, stage: Stage) Error!void {
        while (a.candidate < a.candidates.len) {
            const url = a.candidates[a.candidate];
            a.candidate += 1;
            // The authorization server's metadata only from hosts discovery may reach.
            if (stage == .server_metadata and !discovery.fetchable(url, a.server_url)) continue;
            a.stage = stage;
            a.flow_key = a.newKey();
            a.client.fetch(a.flow_key, .get, url, null, "", &.{.{ .name = "accept", .value = "application/json" }}) catch continue;
            return;
        }
        a.stage = .idle;
        try a.stepFlow(.{ .discovered = .{ .issuer = 0, .scopes = 0 } });
    }

    /// A pre-registered client, else a client ID metadata document
    /// when the server supports them, else Dynamic Client Registration.
    fn register(a: *Auth) Error!void {
        const meta = a.meta.?;
        const issuer = a.flow.flow_issuer;
        if (a.options.client_id) |id| {
            a.registrations[issuer - 1] = .{ .client_id = id, .client_secret = a.options.client_secret };
            return a.stepFlow(.{ .registered = true });
        }
        if (meta.cimd_supported) if (a.options.client_metadata_url) |url| {
            a.registrations[issuer - 1] = .{ .client_id = url, .method = .none };
            return a.stepFlow(.{ .registered = true });
        };
        const endpoint = meta.registration_endpoint orelse return a.stepFlow(.{ .registered = false });
        var body: std.Io.Writer.Allocating = .init(a.gpa);
        defer body.deinit();
        try oauth.writeRegistration(&body.writer, a.options.client_name, a.redirect_uri);
        a.stage = .registration;
        a.flow_key = a.newKey();
        a.post(a.flow_key, endpoint, body.written(), "application/json", null) catch return a.stepFlow(.{ .registered = false });
    }

    fn authorize(a: *Auth, mask: u32) Error!void {
        const fa = a.flow_arena.allocator();
        const meta = a.meta.?;
        const reg = a.registrations[a.flow.flow_issuer - 1].?;
        var random: [48]u8 = undefined;
        a.io.random(&random);
        a.pkce = .init(random[0..32].*);
        a.state = oauth.state(random[32..48].*);
        // Offline_access when the authorization server lists it.
        const offline = if (meta.scopes) |s| (wire.arrayHasString(s, "offline_access") catch false) else false;
        var url: std.Io.Writer.Allocating = .init(fa);
        try oauth.writeAuthorizationUrl(&url.writer, .{
            .endpoint = meta.authorization_endpoint,
            .client_id = reg.client_id,
            .redirect_uri = a.redirect_uri,
            .scope = try a.scopes.list(fa, mask, offline),
            .state = &a.state,
            .challenge = &a.pkce.challenge,
            .resource = a.prm.?.resource,
        });
        a.authorization_url = url.written();
        try a.actions.append(a.gpa, .{ .authorize = a.authorization_url });
    }

    fn redeem(a: *Auth) Error!void {
        const meta = a.meta.?;
        const reg = a.registrations[a.flow.flow_issuer - 1].?;
        const client: oauth.Client = .{ .id = reg.client_id, .secret = reg.client_secret, .method = oauth.chooseMethod(reg.method, reg.client_secret != null, meta.auth_methods) };
        var body: std.Io.Writer.Allocating = .init(a.gpa);
        defer body.deinit();
        try oauth.writeTokenRequest(&body.writer, .{ .code = .{ .code = a.pending_code.?, .verifier = &a.pkce.verifier, .redirect_uri = a.redirect_uri } }, a.prm.?.resource, client);
        a.stage = .token;
        a.flow_key = a.newKey();
        a.post(a.flow_key, meta.token_endpoint, body.written(), "application/x-www-form-urlencoded", try oauth.basicAuthorization(a.flow_arena.allocator(), client)) catch {
            a.token_error = "its token endpoint couldn't be reached";
            return a.stepFlow(.{ .redeemed = false });
        };
    }

    /// The revocation still on its way, if a sign-out sent one.
    pub fn revoking(a: *const Auth) ?u64 {
        return if (a.revoke_key == 0) null else a.revoke_key;
    }

    /// The answer to one of this module's requests. False when `key` isn't one.
    /// `answer` lasts only until the client's next `next`; what is read from it
    /// is read from a copy kept as long as it's needed.
    pub fn fetched(a: *Auth, key: u64, status: u16, answer: []const u8) Error!bool {
        if (key == 0) return false;
        if (key == a.revoke_key) {
            a.revoke_key = 0;
            return true;
        }
        if (key == a.refresh_key) {
            try a.onRefreshAnswer(status, answer);
            return true;
        }
        if (key != a.flow_key) return key >= fetch_base;
        a.flow_key = 0;
        const fa = a.flow_arena.allocator();
        // A registration outlives the sign-in; the rest lasts as long as it.
        const body = try (if (a.stage == .registration) a.keep.allocator() else fa).dupe(u8, answer);
        switch (a.stage) {
            .idle => {},
            .resource_metadata => {
                if (status == 200) if (discovery.parseResourceMetadata(fa, body, a.server_url)) |prm| {
                    a.prm = prm;
                    a.candidates = try discovery.serverMetadataUrls(fa, prm.issuer);
                    a.candidate = 0;
                    try a.fetchCandidate(.server_metadata);
                    return true;
                } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
                try a.fetchCandidate(.resource_metadata);
            },
            .server_metadata => {
                const prm = a.prm.?;
                if (status == 200) if (discovery.parseServerMetadata(fa, body, prm.issuer)) |meta| {
                    a.meta = meta;
                    a.stage = .idle;
                    const issuer = try a.internIssuer(prm.issuer);
                    const defaults = if (prm.scopes) |s| try a.scopes.ofArray(a.keep.allocator(), s) else 0;
                    try a.stepFlow(.{ .discovered = .{ .issuer = issuer, .scopes = defaults } });
                    return true;
                } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
                try a.fetchCandidate(.server_metadata);
            },
            .registration => {
                a.stage = .idle;
                if (status == 200 or status == 201) if (oauth.parseRegistration(a.keep.allocator(), body)) |reg| {
                    a.registrations[a.flow.flow_issuer - 1] = reg;
                    try a.stepFlow(.{ .registered = true });
                    return true;
                } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
                try a.stepFlow(.{ .registered = false });
            },
            .token => {
                a.stage = .idle;
                if (status == 200) if (oauth.parseToken(fa, body)) |token| {
                    try a.keepCredential(token);
                    try a.stepFlow(.{ .redeemed = true });
                    return true;
                } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
                a.token_error = try oauth.tokenFailure(fa, status, body);
                try a.stepFlow(.{ .redeemed = false });
            },
        }
        return true;
    }

    fn onRefreshAnswer(a: *Auth, status: u16, body: []const u8) Error!void {
        a.refresh_key = 0;
        if (status == 200) if (oauth.parseToken(a.flow_arena.allocator(), body)) |token| {
            const rotated = token.refresh != null;
            try a.storeTokens(token);
            try a.actions.append(a.gpa, .save);
            return a.stepGate(.{ .refreshed = if (rotated) .rotated else .ok });
        } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        // invalid_grant: the refresh token is gone for good (RFC 6749 §5.2).
        try a.refreshEnded(if (status >= 400 and status < 500 and oauth.refusesGrant(body)) .refused else .failed);
    }

    /// What a refresh needs comes from the sign-in that brought the tokens.
    fn keepCredential(a: *Auth, token: oauth.Token) Error!void {
        _ = a.cred_arena.reset(.retain_capacity);
        const ca = a.cred_arena.allocator();
        const reg = a.registrations[a.flow.flow_issuer - 1].?;
        const meta = a.meta.?;
        a.cred = .{
            .token_endpoint = try ca.dupe(u8, meta.token_endpoint),
            .revocation_endpoint = if (meta.revocation_endpoint) |r| try ca.dupe(u8, r) else null,
            .resource = try ca.dupe(u8, a.prm.?.resource),
            .client = .{
                .id = try ca.dupe(u8, reg.client_id),
                .secret = if (reg.client_secret) |s| try ca.dupe(u8, s) else null,
                .method = oauth.chooseMethod(reg.method, reg.client_secret != null, meta.auth_methods),
            },
        };
        a.dropTokens();
        try a.storeTokens(token);
        try a.actions.append(a.gpa, .save);
    }

    /// A refresh token that comes back replaces the one held; none
    /// keeps it.
    fn storeTokens(a: *Auth, token: oauth.Token) Allocator.Error!void {
        const access = try a.gpa.dupe(u8, token.access);
        errdefer a.gpa.free(access);
        const bearer = try std.mem.concat(a.gpa, u8, &.{ "Bearer ", token.access });
        errdefer a.gpa.free(bearer);
        const refresh: ?[]u8 = if (token.refresh) |r| try a.gpa.dupe(u8, r) else null;
        free(a.gpa, &a.access);
        free(a.gpa, &a.bearer);
        a.access = access;
        a.bearer = bearer;
        if (refresh) |r| {
            free(a.gpa, &a.refresh_token);
            a.refresh_token = r;
        }
        // Refresh in the last 30 s, or the last half of a shorter-lived
        // token, so a short one isn't refreshed before every request.
        const lifetime_ms: ?i64 = if (token.expires_in) |s| @as(i64, @intCast(@min(s, std.math.maxInt(i32)))) * 1000 else null;
        a.expires_at_ms = if (lifetime_ms) |ms| a.now() +| ms else null;
        a.skew_ms = if (lifetime_ms) |ms| @min(30_000, @divTrunc(ms, 2)) else 30_000;
    }

    fn dropTokens(a: *Auth) void {
        free(a.gpa, &a.access);
        free(a.gpa, &a.bearer);
        free(a.gpa, &a.refresh_token);
        a.expires_at_ms = null;
    }

    fn internIssuer(a: *Auth, issuer: []const u8) Error!u8 {
        for (a.issuers[0..a.issuer_count], 1..) |name, i| if (std.mem.eql(u8, name, issuer)) return @intCast(i);
        if (a.issuer_count == core.max_issuers) return error.TooManyIssuers;
        a.issuers[a.issuer_count] = try a.keep.allocator().dupe(u8, issuer);
        a.issuer_count += 1;
        return a.issuer_count;
    }

    /// POSTs to the authorization server; `basic` is client_secret_basic's
    /// header, if that is the method.
    fn post(a: *Auth, key: u64, url: []const u8, body: []const u8, content_type: []const u8, basic: ?[]const u8) http.Error!void {
        var headers: [2]std.http.Header = .{ .{ .name = "accept", .value = "application/json" }, undefined };
        var n: usize = 1;
        if (basic) |v| {
            headers[1] = .{ .name = "authorization", .value = v };
            n = 2;
        }
        try a.client.fetch(key, .post, url, body, content_type, headers[0..n]);
    }

    fn newKey(a: *Auth) u64 {
        a.next_key += 1;
        return a.next_key;
    }

    fn now(a: *const Auth) i64 {
        return std.Io.Clock.real.now(a.io).toMilliseconds();
    }
};

pub const Error = http.Error || std.Io.Writer.Error || error{ InvalidRedirect, TooManyIssuers };

fn free(gpa: Allocator, slot: *?[]u8) void {
    if (slot.*) |s| {
        std.crypto.secureZero(u8, s);
        gpa.free(s);
    }
    slot.* = null;
}

test {
    std.testing.refAllDecls(Auth);
}

test "a saved credential comes back whole: requests carry its token, and it saves the same" {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:9/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{}, null);
    defer a.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(!try a.save(&out.writer));
    // Unreadable or incomplete: ignored.
    try a.restore("not json");
    try a.restore("{\"access\":\"at\"}");
    try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
    const fields = ",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"https://as/token\",\"revocation_endpoint\":\"https://as/revoke\"," ++
        "\"resource\":\"http://127.0.0.1:9/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\"}";
    // A JSON escape in the token is read as what it stands for.
    try a.restore("{\"access\":\"at\\/1\",\"refresh\":\"rt\"" ++ fields);
    try testing.expectEqualStrings("Bearer at/1", a.authorization(a.gate.gen).?);
    try testing.expect(a.gate.refreshable);
    try testing.expect(try a.save(&out.writer));
    try testing.expectEqualStrings("{\"access\":\"at/1\",\"refresh\":\"rt\"" ++ fields, out.written());
}

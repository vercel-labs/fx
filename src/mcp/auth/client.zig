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
    /// The resource to ask tokens for, when a bridge already asked the
    /// authorization server for it spelled another way (fx.sh asks Slack for
    /// `https://mcp.slack.com/`). Used only when it names the server's own
    /// resource, give or take a trailing slash.
    resource: ?[]const u8 = null,
    /// The scopes to ask for, space-separated, in place of those the
    /// resource metadata lists; a challenge's scopes still win.
    scopes: ?[]const u8 = null,
    /// The host decides each refresh: `refresh_due` says one is due,
    /// and the host answers with `refreshNow`, or with `restore` and a newer
    /// credential another process saved. Off, a refresh goes out at once.
    refresh_via_host: bool = false,
};

/// Why a sign-in ended without a token. `insecure_endpoint` and
/// `internal_endpoint` are a discovery that found only an authorization
/// server fx won't contact: plain HTTP, or an internal address.
pub const Failure = enum {
    discovery,
    registration,
    /// The authorization server's answer was an error, or had no code.
    response,
    /// The answer wasn't for this sign-in: its state or issuer didn't match,
    /// so nothing in it was used.
    mismatch,
    redemption,
    cancelled,
    refused,
    insecure_endpoint,
    internal_endpoint,
    /// Its metadata came as something other than JSON; the message names
    /// what (RFC 8414 §3.2, RFC 9728 §3.2).
    metadata_not_json,
};

pub const Action = union(enum) {
    /// Post request `key`, again if it went out before, with the token of
    /// generation `token`: its header is `authorization(token)`.
    post: struct { key: u64, token: u32 },
    /// Request `key` ends without a usable token.
    give_up: struct { key: u64, why: core.GiveUp },
    /// Requests need a sign-in: a 401 a refresh can't fix, or a 403 asking for
    /// more scopes (`step_up`). `refused` is the refresh that ended the
    /// login, when one did.
    needs_sign_in: struct { step_up: bool, refused: ?oauth.Refusal = null },
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
    /// A refresh is due (`refresh_via_host`): the host answers with
    /// `refreshNow`, or with `restore` and a newer credential.
    refresh_due,
    /// That refresh ended, or a sign-in or sign-out replaced it.
    refresh_ended,
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

/// `probe`: the request a sign-in sends first, for the server's challenge.
const Stage = enum { idle, probe, resource_metadata, server_metadata, registration, token };

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
    state: [43]u8 = undefined,
    authorization_url: []const u8 = "",
    response_error: ?[]const u8 = null,
    /// Why the code wasn't redeemed, in the token endpoint's words.
    token_error: ?[]const u8 = null,
    /// Why this discovery passed over an authorization server, if it did.
    discovery_refusal: ?enum { insecure, internal, not_json } = null,
    /// The Content-Type of metadata refused as `not_json`, in the flow arena.
    refused_media: []const u8 = "",
    pending_code: ?[]const u8 = null,
    flow_key: u64 = 0,
    refresh_key: u64 = 0,
    /// A refresh waits for the host's answer (`refresh_via_host`).
    refresh_due: bool = false,
    /// The refresh refusal that ended the login, until a sign-in or a
    /// restored credential brings another.
    refusal: ?oauth.Refusal = null,
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
                const c = try a.takeChallenge(r.challenge);
                if (r.status == 403) {
                    if (!c.insufficient_scope) {
                        try a.stepGate(.{ .accepted = key });
                        return false;
                    }
                    // A refresh brings no new scopes; this needs a sign-in.
                    try a.stepFlow(.{ .challenged = try a.challengeScopes(c.scope) });
                    try a.stepGate(.{ .accepted = key });
                    // Kept with the login, so a sign-in in another process
                    // asks for these too.
                    try a.actions.append(a.gpa, .save);
                    try a.announce(true);
                    try a.actions.append(a.gpa, .{ .give_up = .{ .key = key, .why = .needs_sign_in } });
                    return true;
                }
                // The challenge's scopes, or none, which leaves the
                // resource metadata's.
                try a.stepFlow(.{ .challenged = try a.challengeScopes(c.scope) });
                try a.stepGate(.{ .rejected = key });
            },
        }
        return true;
    }

    /// Reads a challenge, keeping its resource_metadata for discovery.
    fn takeChallenge(a: *Auth, raw: []const u8) Error!discovery.Challenge {
        const c = (try discovery.parseChallenge(a.flow_arena.allocator(), raw)) orelse discovery.Challenge{};
        if (c.resource_metadata) |url| {
            if (a.challenge_url) |old| a.gpa.free(old);
            a.challenge_url = try a.gpa.dupe(u8, url);
        }
        return c;
    }

    /// The scopes a challenge has the next sign-in ask for: its own, which
    /// the spec makes authoritative, with the configured ones.
    fn challengeScopes(a: *Auth, list: ?[]const u8) Allocator.Error!u32 {
        const configured = a.options.scopes orelse return a.scopeBits(list);
        return try a.scopeBits(configured) | try a.scopeBits(list);
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
            // The sign-in is announced before anything gives up for it, so a
            // host woken by the give-up already knows.
            .give_up => |g| {
                if (g.why == .needs_sign_in) try a.announce(false);
                try a.actions.append(a.gpa, .{ .give_up = .{ .key = g.key, .why = g.why } });
            },
        };
        // A sign-in or sign-out replaced the refresh the host was deciding.
        if (a.refresh_due and !a.gate.refreshing) {
            a.refresh_due = false;
            try a.actions.append(a.gpa, .refresh_ended);
        }
    }

    fn announce(a: *Auth, step_up: bool) Allocator.Error!void {
        if (a.announced) return;
        a.announced = true;
        try a.actions.append(a.gpa, .{ .needs_sign_in = .{ .step_up = step_up, .refused = if (step_up) null else a.refusal } });
    }

    fn startRefresh(a: *Auth) Error!void {
        if (!a.options.refresh_via_host) return a.sendRefresh();
        a.refresh_due = true;
        try a.actions.append(a.gpa, .refresh_due);
    }

    /// Sends the refresh `refresh_due` announced; nothing once a sign-in or
    /// sign-out replaced it.
    pub fn refreshNow(a: *Auth) Error!void {
        if (!a.refresh_due) return;
        a.refresh_due = false;
        try a.sendRefresh();
    }

    fn sendRefresh(a: *Auth) Error!void {
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
        if (a.options.refresh_via_host) try a.actions.append(a.gpa, .refresh_ended);
    }

    // ---- Signing in (the flow) ----

    /// Starts a sign-in that will come back to `redirect_uri`, a loopback or
    /// HTTPS URL. The host hears `authorize` with the URL to open,
    /// then `signed_in` or `sign_in_failed`.
    pub fn signIn(a: *Auth, redirect_uri: []const u8) Error!void {
        if (!discovery.secureOrLoopback(redirect_uri)) return error.InvalidRedirect;
        if (a.flow.phase == .idle) {
            if (a.stage == .probe) return;
            _ = a.flow_arena.reset(.retain_capacity);
            a.token_error = null;
            a.redirect_uri = try a.flow_arena.allocator().dupe(u8, redirect_uri);
            // With no challenge seen, one request without a token asks the
            // server where its metadata is and what scope it wants, so the
            // sign-in starts knowing both.
            if (a.challenge_url == null) {
                a.stage = .probe;
                a.flow_key = a.newKey();
                a.client.fetch(a.flow_key, .post, a.server_url, probe_body, "application/json", &.{.{ .name = "accept", .value = "application/json, text/event-stream" }}) catch {
                    a.stage = .idle;
                    return a.stepFlow(.sign_in);
                };
                return;
            }
        }
        try a.stepFlow(.sign_in);
    }

    const probe_body = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"server/discover\",\"params\":{}}";

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
        if (a.stage == .probe) {
            a.client.cancel(a.flow_key);
            a.flow_key = 0;
            a.stage = .idle;
            return a.actions.append(a.gpa, .{ .sign_in_failed = .{ .why = .cancelled } });
        }
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
        // The scopes the token was asked with, and those a step-up still
        // owes, for the next sign-in.
        var granted: [oauth.max_scopes][]const u8 = undefined;
        var owed: [oauth.max_scopes][]const u8 = undefined;
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
            .scope = a.scopes.namesOf(a.flow.granted, &granted),
            .step_up = a.scopes.namesOf(a.flow.challenge & ~a.flow.granted, &owed),
        });
        return true;
    }

    /// Takes back a credential `save` wrote: its tokens are held again, so
    /// requests carry them and a refresh can renew them. One that can't be
    /// read, whose access token isn't valid, or whose endpoints
    /// discovery may not reach for this server, is ignored: false, and the
    /// credential in use stays.
    pub fn restore(a: *Auth, saved: []const u8) Error!bool {
        const names = [_][]const u8{ "access", "refresh", "expires_at_ms", "skew_ms", "token_endpoint", "revocation_endpoint", "resource", "client_id", "client_secret", "method", "scope", "step_up" };
        var raw: [names.len]?[]const u8 = undefined;
        wire.objectFields(saved, &names, &raw) catch return false;
        // Checked before the credential in use is replaced, so an ignored one
        // leaves it whole.
        var scratch: std.heap.ArenaAllocator = .init(a.gpa);
        defer scratch.deinit();
        var text: [names.len]?[]const u8 = undefined;
        for (raw, &text) |r, *t| t.* = if (r) |v| try wire.decodeString(scratch.allocator(), v) else null;
        const access = text[0] orelse return false;
        if (!oauth.validToken(access)) return false;
        const method = std.meta.stringToEnum(oauth.Method, text[9] orelse return false) orelse return false;
        const token_endpoint = text[4] orelse return false;
        if (!discovery.fetchable(token_endpoint, a.server_url)) return false;
        if (text[5]) |revocation| if (!discovery.fetchable(revocation, a.server_url)) return false;
        const resource = text[6] orelse return false;
        const client_id = text[7] orelse return false;
        _ = a.cred_arena.reset(.retain_capacity);
        const ca = a.cred_arena.allocator();
        a.cred = .{
            .token_endpoint = try ca.dupe(u8, token_endpoint),
            .revocation_endpoint = if (text[5]) |v| try ca.dupe(u8, v) else null,
            .resource = try ca.dupe(u8, resource),
            .client = .{ .id = try ca.dupe(u8, client_id), .secret = if (text[8]) |v| try ca.dupe(u8, v) else null, .method = method },
        };
        a.dropTokens();
        try a.storeTokens(.{ .access = access, .refresh = text[1], .expires_in = null });
        a.expires_at_ms = if (raw[2]) |v| std.fmt.parseInt(i64, v, 10) catch null else null;
        if (raw[3]) |v| a.skew_ms = std.fmt.parseInt(i64, v, 10) catch a.skew_ms;
        // Before any sign-in step, as the model's Init.
        a.flow.granted = if (raw[10]) |v| try a.scopes.ofArray(a.keep.allocator(), v) else 0;
        a.flow.challenge = if (raw[11]) |v| try a.scopes.ofArray(a.keep.allocator(), v) else 0;
        // A new login, as after a sign-in: when it stops working, that is
        // announced too, with its own reason.
        a.announced = false;
        a.refusal = null;
        try a.stepGate(.{ .signed_in = .{ .refreshable = a.refresh_token != null } });
        return true;
    }

    fn stepFlow(a: *Auth, event: core.FlowEvent) Error!void {
        var out: core.FlowOutput = .{};
        a.flow.step(event, &out);
        if (trace.on(a.trace)) |t| try core.writeFlowTrace(t, "remote", &a.flow, &out);
        for (out.effects()) |effect| switch (effect) {
            .discover => {
                a.prm = null;
                a.meta = null;
                a.discovery_refusal = null;
                a.refused_media = "";
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
                a.refusal = null;
                try a.stepGate(.{ .signed_in = .{ .refreshable = a.refresh_token != null } });
                try a.actions.append(a.gpa, .signed_in);
            },
            .failed => |f| {
                a.stage = .idle;
                const why: Failure = switch (f.stage) {
                    // The core lets a response's error show exactly when its
                    // state and issuer were checked and matched.
                    .response => if (f.show_error) .response else .mismatch,
                    inline else => |s| @field(Failure, @tagName(s)),
                };
                const refusal = if (why == .discovery) a.discovery_refusal else null;
                try a.actions.append(a.gpa, .{ .sign_in_failed = .{
                    .why = if (refusal) |r| switch (r) {
                        .insecure => .insecure_endpoint,
                        .internal => .internal_endpoint,
                        .not_json => .metadata_not_json,
                    } else why,
                    .message = if (f.show_error) a.response_error else if (f.stage == .redemption) a.token_error else if (refusal == .not_json) a.refused_media else null,
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
            if (stage == .server_metadata) if (discovery.refusal(url, a.server_url)) |r| {
                a.discovery_refusal = switch (r) {
                    .insecure => .insecure,
                    .internal => .internal,
                };
                continue;
            };
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
        var random: [64]u8 = undefined;
        a.io.random(&random);
        a.pkce = .init(random[0..32].*);
        a.state = oauth.state(random[32..64].*);
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
            .resource = a.tokenResource(),
        });
        a.authorization_url = url.written();
        try a.actions.append(a.gpa, .{ .authorize = a.authorization_url });
    }

    /// The resource tokens are asked for: the metadata's, or the host's
    /// spelling of the same one.
    fn tokenResource(a: *const Auth) []const u8 {
        const own = a.prm.?.resource;
        const wanted = a.options.resource orelse return own;
        return if (std.mem.eql(u8, std.mem.trimEnd(u8, wanted, "/"), std.mem.trimEnd(u8, own, "/"))) wanted else own;
    }

    fn redeem(a: *Auth) Error!void {
        const meta = a.meta.?;
        const reg = a.registrations[a.flow.flow_issuer - 1].?;
        const client: oauth.Client = .{ .id = reg.client_id, .secret = reg.client_secret, .method = oauth.chooseMethod(reg.method, reg.client_secret != null, meta.auth_methods) };
        var body: std.Io.Writer.Allocating = .init(a.gpa);
        defer body.deinit();
        try oauth.writeTokenRequest(&body.writer, .{ .code = .{ .code = a.pending_code.?, .verifier = &a.pkce.verifier, .redirect_uri = a.redirect_uri } }, a.tokenResource(), client);
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
    /// is read from a copy kept as long as it's needed. `media` is its
    /// Content-Type: metadata must be JSON; `challenge` its
    /// `WWW-Authenticate`, which only a sign-in's probe reads.
    pub fn fetched(a: *Auth, key: u64, status: u16, media: []const u8, challenge: ?[]const u8, answer: []const u8) Error!bool {
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
        // Metadata that came as something else isn't read; the sign-in
        // names what came if no other candidate has JSON.
        if ((a.stage == .resource_metadata or a.stage == .server_metadata) and status == 200 and !http.isJson(media)) {
            a.discovery_refusal = .not_json;
            a.refused_media = try fa.dupe(u8, media);
            try a.fetchCandidate(a.stage);
            return true;
        }
        switch (a.stage) {
            .idle => {},
            .probe => {
                a.stage = .idle;
                // A 401, or a 403 asking for scopes, says where the metadata
                // is and what to ask for; anything else leaves the
                // well-known places.
                if (status == 401 or status == 403) if (challenge) |raw| {
                    const c = try a.takeChallenge(raw);
                    // The probe's challenge is for the probe: a step-up
                    // still owed is asked for with it.
                    try a.stepFlow(.{ .challenged = try a.challengeScopes(c.scope) | a.flow.challenge });
                };
                try a.stepFlow(.sign_in);
            },
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
                if (status == 200) if (discovery.parseServerMetadata(fa, body, prm.issuer, a.server_url)) |meta| {
                    a.meta = meta;
                    a.stage = .idle;
                    const issuer = try a.internIssuer(prm.issuer);
                    const defaults = if (a.options.scopes) |s|
                        try a.scopes.ofList(a.keep.allocator(), s)
                    else if (prm.scopes) |s|
                        try a.scopes.ofArray(a.keep.allocator(), s)
                    else
                        0;
                    try a.stepFlow(.{ .discovered = .{ .issuer = issuer, .scopes = defaults } });
                    return true;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InsecureEndpoint => a.discovery_refusal = .insecure,
                    error.InternalEndpoint => a.discovery_refusal = .internal,
                    else => {},
                };
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
            try a.stepGate(.{ .refreshed = if (rotated) .rotated else .ok });
            if (a.options.refresh_via_host) try a.actions.append(a.gpa, .refresh_ended);
            return;
        } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        // An answer naming a refusal refuses the refresh token for good, and
        // the sign-in it asks for says why.
        const refusal = oauth.refreshRefusal(status, body);
        if (refusal) |r| a.refusal = r;
        try a.refreshEnded(if (refusal != null) .refused else .failed);
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
            .resource = try ca.dupe(u8, a.tokenResource()),
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
    try std.testing.expect(!try a.restore("not json"));
    try std.testing.expect(!try a.restore("{\"access\":\"at\"}"));
    try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
    const fields = ",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"https://as/token\",\"revocation_endpoint\":\"https://as/revoke\"," ++
        "\"resource\":\"http://127.0.0.1:9/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\"}";
    // Whole, but with a token that would break its header: ignored too.
    try std.testing.expect(!try a.restore("{\"access\":\"at\\r\\n1\",\"refresh\":\"rt\"" ++ fields));
    try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
    try testing.expect(!try a.save(&out.writer));
    // A JSON escape in the token is read as what it stands for.
    try std.testing.expect(try a.restore("{\"access\":\"at\\/1\",\"refresh\":\"rt\"" ++ fields));
    try testing.expectEqualStrings("Bearer at/1", a.authorization(a.gate.gen).?);
    try testing.expect(a.gate.refreshable);
    try testing.expect(try a.save(&out.writer));
    const none = ",\"scope\":[],\"step_up\":[]}";
    try testing.expectEqualStrings("{\"access\":\"at/1\",\"refresh\":\"rt\"" ++ fields[0 .. fields.len - 1] ++ none, out.written());
    // The scopes granted and those a step-up owes come back in the flow,
    // for the next sign-in, and are saved again.
    const scoped = "{\"access\":\"at2\",\"refresh\":\"rt\"" ++ fields[0 .. fields.len - 1] ++ ",\"scope\":[\"a\",\"b\"],\"step_up\":[\"c\"]}";
    try std.testing.expect(try a.restore(scoped));
    try testing.expectEqual(try a.scopeBits("a b"), a.flow.granted);
    try testing.expectEqual(try a.scopeBits("c"), a.flow.challenge);
    out.clearRetainingCapacity();
    try testing.expect(try a.save(&out.writer));
    try testing.expectEqualStrings(scoped, out.written());
}

test "a refresh the host decides waits for it, and ends however it does: replaced, signed out of, answered, refused, or failed" {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:9/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{ .refresh_via_host = true }, null);
    defer a.deinit();
    const saved = "{{\"access\":\"{s}\",\"refresh\":\"rt\",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"http://127.0.0.1:9/token\"," ++
        "\"revocation_endpoint\":null,\"resource\":\"http://127.0.0.1:9/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\"}}";
    var buffer: [512]u8 = undefined;
    const actions = &a.actions.items;
    for ([_]enum { replaced, signed_out, answered, refused, refused_200, failed_200, failed_429 }{ .replaced, .signed_out, .answered, .refused, .refused_200, .failed_200, .failed_429 }) |case| {
        try std.testing.expect(try a.restore(try std.mem.print(&buffer, saved, .{"at1"})));
        try a.beforeSend(1);
        a.actions.clearRetainingCapacity();
        // The server rejects the token: the refresh waits, and nothing goes out.
        _ = try a.ended(1, .{ .rejected = .{ .status = 401, .challenge = "" } });
        try testing.expectEqual(@as(usize, 1), actions.len);
        try testing.expect(actions.*[0] == .refresh_due);
        try testing.expectEqual(@as(u64, 0), a.refresh_key);
        a.actions.clearRetainingCapacity();
        switch (case) {
            // Another process saved a newer one: the request goes again
            // with it, and the refresh is over.
            .replaced => {
                try std.testing.expect(try a.restore(try std.mem.print(&buffer, saved, .{"at2"})));
                try testing.expectEqual(@as(usize, 2), actions.len);
                try testing.expect(actions.*[0] == .post and actions.*[0].post.key == 1);
                try testing.expect(actions.*[1] == .refresh_ended);
                try testing.expectEqualStrings("Bearer at2", a.authorization(actions.*[0].post.token).?);
            },
            .signed_out => {
                try a.signOut();
                try testing.expect(actions.*[actions.len - 1] == .refresh_ended);
                try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
            },
            // The host sent it, and the token endpoint answered: saved, the
            // request goes again, and the refresh is over.
            .answered => {
                a.refresh_due = false;
                a.refresh_key = a.newKey();
                _ = try a.fetched(a.refresh_key, 200, "application/json", null, "{\"access_token\":\"at3\",\"token_type\":\"Bearer\",\"refresh_token\":\"rt3\",\"expires_in\":3600}");
                try testing.expectEqual(@as(usize, 3), actions.len);
                try testing.expect(actions.*[0] == .save);
                try testing.expect(actions.*[1] == .post and actions.*[1].post.key == 1);
                try testing.expect(actions.*[2] == .refresh_ended);
                try testing.expectEqualStrings("Bearer at3", a.authorization(actions.*[1].post.token).?);
            },
            // Refused: the tokens go, and the refresh is over all the same.
            .refused => {
                a.refresh_due = false;
                a.refresh_key = a.newKey();
                _ = try a.fetched(a.refresh_key, 400, "application/json", null, "{\"error\":\"invalid_grant\"}");
                try testing.expect(actions.*[0] == .save);
                try testing.expect(actions.*[actions.len - 1] == .refresh_ended);
                try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
            },
            // Slack refuses with HTTP 200 and ok:false: refused all the same,
            // so the dead refresh token is never sent again.
            .refused_200 => {
                a.refresh_due = false;
                a.refresh_key = a.newKey();
                _ = try a.fetched(a.refresh_key, 200, "application/json", null, "{\"ok\":false,\"error\":\"invalid_refresh_token\"}");
                try testing.expect(actions.*[0] == .save);
                try testing.expect(actions.*[actions.len - 1] == .refresh_ended);
                try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
                try testing.expectEqual(@as(?[]u8, null), a.refresh_token);
            },
            // Slack's temporary errors come with HTTP 200 too, and may pass
            // later: the tokens stay, and nothing is saved.
            .failed_200 => {
                a.refresh_due = false;
                a.refresh_key = a.newKey();
                _ = try a.fetched(a.refresh_key, 200, "application/json", null, "{\"ok\":false,\"error\":\"internal_error\"}");
                for (actions.*) |x| try testing.expect(x != .save);
                try testing.expect(actions.*[actions.len - 1] == .refresh_ended);
                try testing.expectEqualStrings("rt", a.refresh_token.?);
            },
            // A 429 may pass later: the tokens stay, and nothing is saved.
            .failed_429 => {
                a.refresh_due = false;
                a.refresh_key = a.newKey();
                _ = try a.fetched(a.refresh_key, 429, "application/json", null, "{\"error\":\"slow_down\"}");
                for (actions.*) |x| try testing.expect(x != .save);
                try testing.expect(actions.*[actions.len - 1] == .refresh_ended);
                try testing.expectEqualStrings("rt", a.refresh_token.?);
            },
        }
        if (case != .signed_out) _ = try a.ended(1, .answered);
        // An answer that comes too late sends nothing.
        a.actions.clearRetainingCapacity();
        try a.refreshNow();
        try testing.expectEqual(@as(u64, 0), a.refresh_key);
        try testing.expectEqual(@as(usize, 0), actions.len);
    }
}

test "a refused refresh asks for a sign-in naming the refusal, and so does a login taken since when it is refused too" {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:9/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{ .refresh_via_host = true }, null);
    defer a.deinit();
    const saved = "{{\"access\":\"{s}\",\"refresh\":\"rt-{s}\",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"http://127.0.0.1:9/token\"," ++
        "\"revocation_endpoint\":null,\"resource\":\"http://127.0.0.1:9/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\"}}";
    var buffer: [512]u8 = undefined;
    const actions = &a.actions.items;
    // Its own login, then one another process saved, taken in its place.
    for ([_][]const u8{ "at1", "at2" }, [_]u16{ 400, 401 }, [_][]const u8{ "invalid_grant", "invalid_client" }, 0..) |access, status, code, k| {
        try testing.expect(try a.restore(try std.mem.print(&buffer, saved, .{ access, access })));
        try testing.expectEqual(@as(?oauth.Refusal, null), a.refusal);
        const key: u64 = 10 + k;
        try a.beforeSend(key);
        _ = try a.ended(key, .{ .rejected = .{ .status = 401, .challenge = "" } });
        a.actions.clearRetainingCapacity();
        a.refresh_due = false;
        a.refresh_key = a.newKey();
        var answer: [160]u8 = undefined;
        // The description names a token; only the code and status go on.
        _ = try a.fetched(a.refresh_key, status, "application/json", null, try std.mem.print(&answer, "{{\"error\":\"{s}\",\"error_description\":\"rt-{s} was used\"}}", .{ code, access }));
        var asked: usize = 0;
        for (actions.*) |x| if (x == .needs_sign_in) {
            asked += 1;
            try testing.expect(!x.needs_sign_in.step_up);
            const refused = x.needs_sign_in.refused orelse return error.TestUnexpectedResult;
            try testing.expectEqual(status, refused.status);
            try testing.expectEqualStrings(code, refused.code);
        };
        try testing.expectEqual(@as(usize, 1), asked);
        try testing.expectEqual(@as(?[]u8, null), a.access);
    }
}

/// A saved credential of any shape: `restore` takes it or returns false, and
/// a false keeps the credential in use.
fn fuzzRestore(_: void, smith: *std.testing.Smith) !void {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:9/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{ .refresh_via_host = true }, null);
    defer a.deinit();
    try testing.expect(try a.restore("{\"access\":\"at1\",\"refresh\":\"rt\",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"http://127.0.0.1:9/token\",\"revocation_endpoint\":null,\"resource\":\"http://127.0.0.1:9/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\"}"));
    var buffer: [1024]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, '{', 3),
        .value(u8, '}', 3),
        .value(u8, '"', 5),
        .value(u8, '\\', 2),
        .value(u8, ':', 3),
        .value(u8, ',', 3),
    });
    const taken = a.restore(buffer[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.TestUnexpectedResult,
    };
    if (taken) {
        try testing.expect(oauth.validToken(a.access.?));
        try testing.expect(a.cred != null);
    } else {
        try testing.expectEqualStrings("at1", a.access.?);
        try testing.expectEqualStrings("http://127.0.0.1:9/token", a.cred.?.token_endpoint);
    }
}

test "a saved credential of any shape is taken whole or not at all" {
    try std.testing.fuzz({}, fuzzRestore, .{
        .corpus = &.{
            "",
            "{}",
            "not json",
            "{\"access\":\"at2\"}",
            "{\"access\":\"at\\r\\n2\",\"method\":\"none\",\"token_endpoint\":\"http://127.0.0.1:9/token\",\"resource\":\"r\",\"client_id\":\"c\"}",
            "{\"access\":\"at2\",\"refresh\":null,\"expires_at_ms\":\"soon\",\"skew_ms\":-1,\"token_endpoint\":\"http://127.0.0.1:9/token\",\"revocation_endpoint\":null,\"resource\":\"r\",\"client_id\":\"c\",\"client_secret\":null,\"method\":\"none\",\"scope\":[\"a\",7],\"step_up\":{}}",
            "{\"access\":\"at2\",\"token_endpoint\":\"https://0.0.0.0:1/token\",\"resource\":\"r\",\"client_id\":\"c\",\"method\":\"none\"}",
            "{\"access\":\"at2\",\"token_endpoint\":\"http://127.0.0.1:9/token\",\"resource\":\"r\",\"client_id\":\"c\",\"method\":\"dpop\"}",
        },
    });
}

test "a request a sign-in is needed for gives up only after the sign-in is announced" {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:9/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{}, null);
    defer a.deinit();
    // No login: the server's 401 leaves nothing to refresh.
    try a.beforeSend(1);
    a.actions.clearRetainingCapacity();
    _ = try a.ended(1, .{ .rejected = .{ .status = 401, .challenge = "" } });
    const actions = a.actions.items;
    var announced: ?usize = null;
    var gave_up: ?usize = null;
    for (actions, 0..) |x, i| switch (x) {
        .needs_sign_in => announced = announced orelse i,
        .give_up => |g| if (g.key == 1 and g.why == .needs_sign_in) {
            gave_up = gave_up orelse i;
        },
        else => {},
    };
    try testing.expect(announced.? < gave_up.?);
}

test "a step-up is saved with the login, so a sign-in in a new process asks for it with the scopes held" {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:9/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{}, null);
    defer a.deinit();
    const login = "{\"access\":\"at\",\"refresh\":\"rt\",\"expires_at_ms\":4102444800000,\"skew_ms\":30000,\"token_endpoint\":\"https://as/token\"," ++
        "\"revocation_endpoint\":null,\"resource\":\"http://127.0.0.1:9/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\",\"scope\":[\"a\"],\"step_up\":[]}";
    try std.testing.expect(try a.restore(login));
    try a.beforeSend(1);
    a.actions.clearRetainingCapacity();
    _ = try a.ended(1, .{ .rejected = .{ .status = 403, .challenge = "Bearer error=\"insufficient_scope\", scope=\"b\"" } });
    var saves: usize = 0;
    for (a.actions.items) |x| saves += @intFromBool(x == .save);
    try testing.expectEqual(@as(usize, 1), saves);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try a.save(&out.writer));

    var b: Auth = .init(testing.io, testing.allocator, &client, "http://127.0.0.1:9/mcp", .{}, null);
    defer b.deinit();
    try std.testing.expect(try b.restore(out.written()));
    try testing.expectEqual(try b.scopeBits("a"), b.flow.granted);
    try testing.expectEqual(try b.scopeBits("b"), b.flow.challenge);
    var step: core.FlowOutput = .{};
    b.flow.step(.sign_in, &step);
    try testing.expectEqual(try b.scopeBits("a b"), b.flow.flow_scopes);
}

test "a saved credential whose endpoints discovery may not reach is ignored" {
    const testing = std.testing;
    var client: http.Client = undefined;
    try client.init(testing.io, testing.allocator, .{ .url = "https://mcp.example.com/mcp" });
    defer client.deinit();
    var a: Auth = .init(testing.io, testing.allocator, &client, "https://mcp.example.com/mcp", .{}, null);
    defer a.deinit();
    const saved = "{{\"access\":\"at\",\"refresh\":\"rt\",\"expires_at_ms\":0,\"skew_ms\":30000,\"token_endpoint\":\"{s}\",\"revocation_endpoint\":{s},\"resource\":\"https://mcp.example.com/mcp\",\"client_id\":\"c1\",\"client_secret\":null,\"method\":\"none\"}}";
    var buffer: [512]u8 = undefined;
    for ([_][2][]const u8{
        .{ "https://0.0.0.0:1/token", "null" },
        .{ "https://10.0.0.5/token", "null" },
        .{ "http://localhost:9/token", "null" },
        .{ "http://auth.example.com/token", "null" },
        .{ "https://auth.example.com/token", "\"https://169.254.169.254/revoke\"" },
    }) |case| {
        try std.testing.expect(!try a.restore(try std.mem.print(&buffer, saved, .{ case[0], case[1] })));
        try testing.expectEqual(@as(?[]const u8, null), a.authorization(a.gate.gen));
    }
    try std.testing.expect(try a.restore(try std.mem.print(&buffer, saved, .{ "https://auth.example.com/token", "\"https://auth.example.com/revoke\"" })));
    try testing.expectEqualStrings("Bearer at", a.authorization(a.gate.gen).?);
    // An ignored one after it leaves it whole, its endpoints included.
    try std.testing.expect(!try a.restore(try std.mem.print(&buffer, saved, .{ "https://0.0.0.0:1/tokenxxxxxx", "null" })));
    try testing.expectEqualStrings("Bearer at", a.authorization(a.gate.gen).?);
    try testing.expectEqualStrings("https://auth.example.com/token", a.cred.?.token_endpoint);
    try testing.expectEqualStrings("https://auth.example.com/revoke", a.cred.?.revocation_endpoint.?);
}

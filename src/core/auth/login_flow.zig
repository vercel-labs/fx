const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("credentials.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const claude_session = @import("claude_session.zig");
const grok_session = @import("grok_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const js_host_auth = @import("js_host_auth.zig");
const oauth = @import("oauth.zig");
const oauth_session = @import("oauth_session.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const teams_endpoint = "https://api.vercel.com/v2/teams";
const poll_wait_slice_ms: u64 = 100;
pub const poll_request_timeout_ms: i64 = 15_000;
const max_poll_interval_ms = std.math.maxInt(u64) / std.time.ns_per_ms;

pub const LoginError = error{
    ClientIdMissing,
    LoginTimedOut,
    NoSession,
    SessionChanged,
    NoRefreshToken,
    NoTeams,
    InvalidTeamSelection,
};

const LogoutError = error{SessionDeleteFailed};

pub const remote_revocation_warning = "Warning: signed out locally, but the remote session could not be revoked.";

pub const LogoutResult = struct {
    session_deleted: bool = false,
    local_durability_failed: bool = false,
    remote_revocation_failed: bool = false,
};

pub const Team = struct {
    id: []u8,
    slug: []u8,
    name: []u8,

    pub fn deinit(self: *Team, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.slug);
        alloc.free(self.name);
        self.* = undefined;
    }
};

pub const SelectedTeam = struct {
    id: []u8,
    slug: []u8,

    pub fn deinit(self: *SelectedTeam, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.slug);
        self.* = undefined;
    }
};

pub const TeamSelection = struct {
    session: ?oauth_session.Session = null,
    teams: std.ArrayList(Team) = .empty,

    pub fn deinit(self: *TeamSelection, alloc: Allocator) void {
        if (self.session) |*session| session.deinit(alloc);
        freeTeams(alloc, &self.teams);
        self.* = .{};
    }

    pub fn take(self: *TeamSelection) TeamSelection {
        const selection = self.*;
        self.* = .{};
        return selection;
    }

    pub fn currentTeam(self: *const TeamSelection) ?[]const u8 {
        const session = self.session orelse return null;
        return session.team_id orelse session.team_slug;
    }

    pub fn select(self: *const TeamSelection, alloc: Allocator, selected_index: usize) !SelectedTeam {
        const session = self.session orelse return LoginError.NoSession;
        if (selected_index >= self.teams.items.len) return LoginError.InvalidTeamSelection;
        const selected = self.teams.items[selected_index];

        var mutation = (try oauth_session.beginExistingMutation()) orelse return LoginError.SessionChanged;
        defer mutation.deinit();
        var current = (try mutation.load(alloc)) orelse return LoginError.SessionChanged;
        defer current.deinit(alloc);
        if (!sameCredentialState(session, current)) return LoginError.SessionChanged;

        const selected_team_id = try alloc.dupe(u8, selected.id);
        const selected_team_slug = alloc.dupe(u8, selected.slug) catch |err| {
            alloc.free(selected_team_id);
            return err;
        };
        if (current.team_id) |value| alloc.free(value);
        if (current.team_slug) |value| alloc.free(value);
        current.team_id = selected_team_id;
        current.team_slug = selected_team_slug;

        try mutation.save(alloc, current);
        current.team_id = null;
        current.team_slug = null;
        return .{
            .id = selected_team_id,
            .slug = selected_team_slug,
        };
    }
};

pub const SignInState = enum {
    idle,
    polling,
    succeeded,
    failed,
    cancelled,
};

pub const SignInSnapshot = struct {
    state: SignInState = .idle,
    verification_uri: []const u8 = "",
    verification_uri_complete: ?[]const u8 = null,
    user_code: []const u8 = "",
};

pub const SignInCompletion = union(enum) {
    vercel: TeamSelection,
    chatgpt: chatgpt_session.Session,
    grok: grok_session.Session,
    claude: claude_session.Session,

    pub fn deinit(self: *SignInCompletion, alloc: Allocator) void {
        switch (self.*) {
            .vercel => |*selection| selection.deinit(alloc),
            .chatgpt => |*session| session.deinit(alloc),
            .grok => |*session| session.deinit(alloc),
            .claude => |*session| session.deinit(alloc),
        }
        self.* = .{ .vercel = .{} };
    }

    pub fn take(self: *SignInCompletion) SignInCompletion {
        const completion = self.*;
        self.* = .{ .vercel = .{} };
        return completion;
    }
};

pub const SignInTransition = union(enum) {
    none,
    succeeded: SignInCompletion,
    failed: anyerror,
    cancelled,
};

pub const PreparedLogin = struct {
    metadata: oauth.Metadata,
    device: oauth.DeviceAuthorization,
    client_id: []u8,

    pub fn deinit(self: *PreparedLogin, alloc: Allocator) void {
        self.metadata.deinit(alloc);
        self.device.deinit(alloc);
        alloc.free(self.client_id);
        self.* = undefined;
    }
};

pub const CompleteSignInFn = *const fn (
    ?*anyopaque,
    Allocator,
    []const u8,
    []const u8,
    *oauth.TokenSet,
) anyerror!SignInCompletion;
pub const SaveSignInFn = *const fn (?*anyopaque, Allocator, SignInCompletion) anyerror!void;
pub const DeinitSignInContextFn = *const fn (?*anyopaque, Allocator) void;

pub const SignInRuntimeDeps = struct {
    ctx: ?*anyopaque = null,
    deinit_ctx: ?DeinitSignInContextFn = null,
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    poll: LoginPollDeps = .{},
    complete: CompleteSignInFn = completeSignIn,
    save: SaveSignInFn = saveSignIn,
};

pub const SignInRuntime = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    state: SignInState = .idle,
    flow: ?PreparedLogin = null,
    completion: ?SignInCompletion = null,
    failure: ?anyerror = null,
    poll_state: ?LoginPollState = null,
    deps: SignInRuntimeDeps = .{},

    pub fn start(
        self: *Self,
        alloc: Allocator,
        transport: oauth_transport.Provider,
    ) !bool {
        const prepared = try prepareLogin(alloc, transport);
        return self.startPrepared(alloc, prepared, .{
            .oauth_transport = transport,
        });
    }

    pub fn startPrepared(
        self: *Self,
        alloc: Allocator,
        prepared: PreparedLogin,
        deps: SignInRuntimeDeps,
    ) !bool {
        return self.startPreparedWithMode(alloc, prepared, deps, host_target.is_wasm);
    }

    fn startPreparedCooperative(
        self: *Self,
        alloc: Allocator,
        prepared: PreparedLogin,
        deps: SignInRuntimeDeps,
    ) !bool {
        return self.startPreparedWithMode(alloc, prepared, deps, true);
    }

    fn startPreparedWithMode(
        self: *Self,
        alloc: Allocator,
        prepared: PreparedLogin,
        deps: SignInRuntimeDeps,
        comptime cooperative: bool,
    ) !bool {
        const poll_state = if (cooperative)
            LoginPollState.init(deps.poll, prepared.device) catch |err| {
                var rejected = prepared;
                rejected.deinit(alloc);
                if (deps.deinit_ctx) |deinit_ctx| deinit_ctx(deps.ctx, alloc);
                return err;
            }
        else
            null;
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.thread != null or self.state == .polling or self.completion != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = prepared;
            rejected.deinit(alloc);
            if (deps.deinit_ctx) |deinit_ctx| deinit_ctx(deps.ctx, alloc);
            return false;
        }
        self.state = .polling;
        self.failure = null;
        self.flow = prepared;
        self.poll_state = poll_state;
        self.deps = deps;
        self.deps.poll.cancel_flag = &self.cancel_requested;
        self.cancel_requested.store(false, .seq_cst);
        self.mutex.unlock(io_mod.getIo());

        if (cooperative) return true;
        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, alloc }) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = .idle;
            self.mutex.unlock(io_mod.getIo());
            self.clearFlow(alloc);
            return err;
        };
        return true;
    }

    pub fn cancel(self: *Self, alloc: Allocator) bool {
        self.cancel_requested.store(true, .seq_cst);
        self.mutex.lockUncancelable(io_mod.getIo());
        const cancelled = self.state == .polling;
        if (cancelled) self.state = .cancelled;
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io_mod.getIo());

        if (comptime !host_target.is_wasm) {
            if (thread) |handle| handle.join();
        }
        self.clearFlow(alloc);
        return cancelled;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        _ = self.cancel(alloc);
        if (self.completion) |*selection| selection.deinit(alloc);
        self.completion = null;
        self.failure = null;
        self.state = .idle;
    }

    pub fn snapshot(self: *const Self) SignInSnapshot {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        const flow = self.flow orelse return .{ .state = self.state };
        return .{
            .state = self.state,
            .verification_uri = flow.device.verification_uri,
            .verification_uri_complete = flow.device.verification_uri_complete,
            .user_code = flow.device.user_code,
        };
    }

    pub fn browserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const flow = self.flow orelse return null;
        const url = flow.device.verification_uri_complete orelse flow.device.verification_uri;
        return try alloc.dupe(u8, url);
    }

    pub fn pollTransition(self: *Self, alloc: Allocator) SignInTransition {
        self.mutex.lockUncancelable(io_mod.getIo());
        const terminal = switch (self.state) {
            .succeeded, .failed, .cancelled => true,
            .idle, .polling => false,
        };
        const thread = if (terminal) self.thread else null;
        if (terminal) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (!terminal) return .none;

        if (comptime !host_target.is_wasm) {
            if (thread) |handle| handle.join();
        }
        self.clearFlow(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const state = self.state;
        self.state = .idle;
        return switch (state) {
            .succeeded => blk: {
                const completion = self.completion orelse break :blk .{ .failed = error.LoginCompletionMissing };
                self.completion = null;
                break :blk .{ .succeeded = completion };
            },
            .failed => blk: {
                const failure = self.failure orelse error.OAuthRequestFailed;
                self.failure = null;
                break :blk .{ .failed = failure };
            },
            .cancelled => .cancelled,
            .idle, .polling => .none,
        };
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        const flow = if (self.flow) |*prepared| prepared else return;
        var prompt = BrowserOpenPrompt{ .url = flow.device.verification_uri };
        var token = pollForTokenWithDeps(
            alloc,
            self.deps.oauth_transport,
            flow.metadata,
            flow.client_id,
            flow.device,
            &prompt,
            self.deps.poll,
        ) catch |err| {
            self.publishFailure(err);
            return;
        };
        defer token.deinit(alloc);

        self.completeToken(alloc, &token);
    }

    pub fn pulse(self: *Self, alloc: Allocator) void {
        if (comptime !host_target.is_wasm) return;
        self.pulseCooperative(alloc);
    }

    fn pulseCooperative(self: *Self, alloc: Allocator) void {
        if (self.state != .polling) return;
        const flow = if (self.flow) |*prepared| prepared else return;
        const poll_state = if (self.poll_state) |*state| state else {
            self.publishFailure(error.LoginPollStateMissing);
            return;
        };
        const step = pollTokenStep(
            alloc,
            self.deps.oauth_transport,
            flow.metadata,
            flow.client_id,
            flow.device,
            self.deps.poll,
            poll_state,
        ) catch |err| {
            self.publishFailure(err);
            return;
        };
        switch (step) {
            .waiting => {},
            .succeeded => |token| {
                var owned = token;
                defer owned.deinit(alloc);
                self.completeToken(alloc, &owned);
            },
        }
    }

    fn completeToken(self: *Self, alloc: Allocator, token: *oauth.TokenSet) void {
        const flow = if (self.flow) |*prepared| prepared else {
            self.publishFailure(error.LoginFlowMissing);
            return;
        };
        if (self.cancel_requested.load(.seq_cst)) {
            debug_trace.logf("auth", "sign-in discarded token after cancel", .{});
            return;
        }
        var completion = self.deps.complete(
            self.deps.ctx,
            alloc,
            flow.metadata.issuer,
            flow.client_id,
            token,
        ) catch |err| {
            self.publishFailure(err);
            return;
        };
        defer completion.deinit(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .polling or self.cancel_requested.load(.seq_cst)) {
            debug_trace.logf("auth", "sign-in discarded session after cancel state={t}", .{self.state});
            return;
        }
        self.deps.save(self.deps.ctx, alloc, completion) catch |err| {
            debug_trace.logf("auth", "sign-in session save failed err={s}", .{@errorName(err)});
            self.failure = err;
            self.state = .failed;
            return;
        };
        self.completion = completion.take();
        self.state = .succeeded;
    }

    fn publishFailure(self: *Self, err: anyerror) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .polling or self.cancel_requested.load(.seq_cst)) {
            debug_trace.logf(
                "auth",
                "sign-in suppressed post-cancel failure err={s} state={t}",
                .{ @errorName(err), self.state },
            );
            return;
        }
        if (err == error.Cancelled) {
            self.state = .cancelled;
            return;
        }
        self.failure = err;
        self.state = .failed;
    }

    fn clearFlow(self: *Self, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var flow = self.flow;
        const deps = self.deps;
        self.flow = null;
        self.poll_state = null;
        self.deps = .{};
        self.mutex.unlock(io_mod.getIo());
        if (flow) |*prepared| prepared.deinit(alloc);
        if (deps.deinit_ctx) |deinit_ctx| deinit_ctx(deps.ctx, alloc);
    }
};

fn prepareLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !PreparedLogin {
    var client_id = oauth_session.configuredClientId() orelse return LoginError.ClientIdMissing;
    const issuer_url = try oauth_session.configuredIssuerUrl();

    var metadata = try oauth.discover(alloc, transport, issuer_url);
    errdefer metadata.deinit(alloc);
    try oauth_session.validateE2EEndpoint(issuer_url, metadata.device_authorization_endpoint);
    try oauth_session.validateE2EEndpoint(issuer_url, metadata.token_endpoint);

    var device = oauth.requestDeviceAuthorization(alloc, transport, metadata, client_id) catch |err| fallback: {
        if (err != oauth.OAuthError.InvalidClient or std.mem.eql(u8, client_id, oauth_session.default_client_id)) return err;
        client_id = oauth_session.default_client_id;
        break :fallback try oauth.requestDeviceAuthorization(alloc, transport, metadata, client_id);
    };
    errdefer device.deinit(alloc);
    const owned_client_id = try alloc.dupe(u8, client_id);
    return .{
        .metadata = metadata,
        .device = device,
        .client_id = owned_client_id,
    };
}

fn completeSignIn(
    _: ?*anyopaque,
    alloc: Allocator,
    issuer_url: []const u8,
    client_id: []const u8,
    token: *oauth.TokenSet,
) !SignInCompletion {
    var teams = fetchTeams(alloc, token.access_token, issuer_url) catch std.ArrayList(Team).empty;
    errdefer freeTeams(alloc, &teams);
    const now_ms = io_mod.milliTimestamp();
    const session = try take_login_session(alloc, issuer_url, client_id, token, null, now_ms);
    return .{ .vercel = .{
        .session = session,
        .teams = teams,
    } };
}

fn saveSignIn(_: ?*anyopaque, alloc: Allocator, completion: SignInCompletion) !void {
    const session = switch (completion) {
        .vercel => |selection| selection.session orelse return LoginError.NoSession,
        .chatgpt, .grok, .claude => return error.InvalidSignInCompletion,
    };
    try oauth_session.saveNewSession(alloc, session);
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var prepared = try prepareLogin(alloc, transport);
    defer prepared.deinit(alloc);

    const display_url = prepared.device.verification_uri_complete orelse prepared.device.verification_uri;
    try writeStdout("Open ");
    try writeStdout(display_url);
    try writeStdout("\nCode: ");
    try writeStdout(prepared.device.user_code);
    try writeStdout("\n\n");

    var browser_prompt = try BrowserOpenPrompt.init(display_url);
    try browser_prompt.writeWaitingMessage();

    var token = try pollForTokenWithPrompt(
        alloc,
        transport,
        prepared.metadata,
        prepared.client_id,
        prepared.device,
        &browser_prompt,
        url_opener,
    );
    defer token.deinit(alloc);

    var teams = fetchTeams(alloc, token.access_token, prepared.metadata.issuer) catch std.ArrayList(Team).empty;
    defer freeTeams(alloc, &teams);
    const selected_team_index = try selectTeam(alloc, teams.items, null);
    const selected_team = if (selected_team_index) |index| &teams.items[index] else null;

    const now_ms = io_mod.milliTimestamp();
    var session = try take_login_session(
        alloc,
        prepared.metadata.issuer,
        prepared.client_id,
        &token,
        selected_team,
        now_ms,
    );
    defer session.deinit(alloc);

    try oauth_session.saveNewSession(alloc, session);
    try writeStdout("Signed in to Vercel.\n");
    try writeStdout("AI Gateway access may still require billing or API setup for the selected account.\n");
}

fn take_login_session(
    alloc: Allocator,
    issuer_url: []const u8,
    client_id: []const u8,
    token: *oauth.TokenSet,
    selected_team: ?*const Team,
    now_ms: i64,
) !oauth_session.Session {
    const refresh_token = token.refresh_token orelse return LoginError.NoRefreshToken;
    const expires_at_ms = try oauth.expiry_timestamp_ms(now_ms, token.expires_in);
    const owned_issuer = try alloc.dupe(u8, issuer_url);
    errdefer alloc.free(owned_issuer);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);
    const team_slug = if (selected_team) |team| try alloc.dupe(u8, team.slug) else null;
    errdefer if (team_slug) |value| alloc.free(value);
    const team_id = if (selected_team) |team| try alloc.dupe(u8, team.id) else null;
    errdefer if (team_id) |value| alloc.free(value);

    const session = oauth_session.Session{
        .issuer = owned_issuer,
        .client_id = owned_client_id,
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = token.scope,
        .token_type = token.token_type,
        .team_slug = team_slug,
        .team_id = team_id,
    };
    token.access_token = &.{};
    token.refresh_token = null;
    token.scope = &.{};
    token.token_type = &.{};
    if (oauth.missingGrantedScope(oauth.default_scope, session.scope)) |missing| {
        debug_trace.logf(
            "auth",
            "issuer reduced the grant missing_scope={s} granted={s}",
            .{ missing, session.scope },
        );
    }
    return session;
}

pub fn runTeams(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !void {
    var selection = try loadTeamSelection(alloc, transport);
    defer selection.deinit(alloc);

    const selected_index = (try selectTeam(alloc, selection.teams.items, selection.currentTeam())) orelse
        return LoginError.NoTeams;
    const selected = selection.teams.items[selected_index];
    var changed_team = try selection.select(alloc, selected_index);
    defer changed_team.deinit(alloc);
    try writeStdoutFmt("Selected Vercel team: {s} ({s}).\n", .{ selected.name, selected.slug });
}

pub fn loadTeamSelection(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !TeamSelection {
    var session = blk: {
        var mutation = (try oauth_session.beginExistingMutation()) orelse return LoginError.NoSession;
        defer mutation.deinit();

        var loaded = (try mutation.load(alloc)) orelse return LoginError.NoSession;
        errdefer loaded.deinit(alloc);
        if (loaded.expired(io_mod.milliTimestamp())) {
            try credentials.refreshFxSession(alloc, transport, &mutation, &loaded);
        }
        break :blk loaded;
    };
    errdefer session.deinit(alloc);

    const teams = try fetchTeams(alloc, session.access_token, session.issuer);
    return .{
        .session = session,
        .teams = teams,
    };
}

fn sameCredentialState(left: oauth_session.Session, right: oauth_session.Session) bool {
    return left.expires_at_ms == right.expires_at_ms and
        std.mem.eql(u8, left.issuer, right.issuer) and
        std.mem.eql(u8, left.client_id, right.client_id) and
        std.mem.eql(u8, left.access_token, right.access_token) and
        std.mem.eql(u8, left.refresh_token, right.refresh_token) and
        std.mem.eql(u8, left.scope, right.scope) and
        std.mem.eql(u8, left.token_type, right.token_type);
}

pub fn logout(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !LogoutResult {
    var session: ?oauth_session.Session = null;
    var session_load_failed = false;
    defer if (session) |*loaded| loaded.deinit(alloc);
    const delete_result = blk: {
        var mutation = (oauth_session.beginExistingMutation() catch {
            return LogoutError.SessionDeleteFailed;
        }) orelse return .{};
        defer mutation.deinit();
        session = mutation.load(alloc) catch load: {
            session_load_failed = true;
            break :load null;
        };
        break :blk mutation.delete(alloc) catch oauth_session.DeleteResult{
            .local_cleanup_failed = true,
        };
    };

    var remote_revocation_failed = session_load_failed;
    if (session != null) {
        const loaded = session.?;
        revokeLogoutSession(alloc, transport, loaded) catch {
            remote_revocation_failed = true;
        };
    }

    return .{
        .session_deleted = delete_result.session_deleted,
        .local_durability_failed = delete_result.local_cleanup_failed,
        .remote_revocation_failed = remote_revocation_failed,
    };
}

fn revokeLogoutSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    session: oauth_session.Session,
) !void {
    var metadata = try oauth.discover(alloc, transport, session.issuer);
    defer metadata.deinit(alloc);
    const endpoint = metadata.revocation_endpoint orelse return error.RevocationEndpointMissing;
    try oauth_session.validateE2EEndpoint(session.issuer, endpoint);
    const refresh_result = oauth.revokeToken(
        alloc,
        transport,
        endpoint,
        session.client_id,
        session.refresh_token,
        .refresh_token,
    );
    const access_result = oauth.revokeToken(
        alloc,
        transport,
        endpoint,
        session.client_id,
        session.access_token,
        .access_token,
    );
    try refresh_result;
    try access_result;
}

fn pollForTokenWithPrompt(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    client_id: []const u8,
    device: oauth.DeviceAuthorization,
    prompt: *BrowserOpenPrompt,
    url_opener: host.UrlOpener,
) !oauth.TokenSet {
    return pollForTokenWithDeps(alloc, transport, metadata, client_id, device, prompt, .{
        .url_opener = url_opener,
    });
}

pub const LoginPollDeps = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (?*anyopaque) i64 = realNowMs,
    poll_device_token: *const fn (
        ?*anyopaque,
        Allocator,
        oauth_transport.Provider,
        oauth.Metadata,
        []const u8,
        []const u8,
        *std.atomic.Value(bool),
        std.Io.Clock.Timestamp,
    ) anyerror!oauth.PollResult = realPollDeviceToken,
    sleep_ms: *const fn (?*anyopaque, u64) void = realSleepMs,
    wait_for_enter: *const fn (?*anyopaque, u64) bool = if (host_target.is_wasm)
        unavailableWaitForEnter
    else
        realWaitForEnter,
    url_opener: host.UrlOpener = host.unavailable_url_opener,
    is_cancelled: *const fn (?*anyopaque) bool = neverCancelled,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    request_timeout_ms: i64 = poll_request_timeout_ms,
};

const LoginPollState = struct {
    expires_at_ms: i64,
    interval_ms: u64,
    next_poll_at_ms: i64,

    fn init(deps: LoginPollDeps, device: oauth.DeviceAuthorization) !LoginPollState {
        const now_ms = deps.now_ms(deps.ctx);
        return .{
            .expires_at_ms = try oauth.expiry_timestamp_ms(now_ms, device.expires_in),
            .interval_ms = try poll_interval_ms(device.interval),
            .next_poll_at_ms = now_ms,
        };
    }

    fn scheduleNext(self: *LoginPollState, now_ms: i64) !void {
        const interval_ms = std.math.cast(i64, self.interval_ms) orelse
            return oauth.OAuthError.InvalidOAuthResponse;
        self.next_poll_at_ms = std.math.add(i64, now_ms, interval_ms) catch
            return oauth.OAuthError.InvalidOAuthResponse;
    }

    fn waitMs(self: LoginPollState, now_ms: i64) u64 {
        if (now_ms >= self.next_poll_at_ms) return 0;
        return @intCast(self.next_poll_at_ms - now_ms);
    }
};

const LoginPollStep = union(enum) {
    waiting,
    succeeded: oauth.TokenSet,
};

fn pollForTokenWithDeps(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    client_id: []const u8,
    device: oauth.DeviceAuthorization,
    prompt: *BrowserOpenPrompt,
    deps: LoginPollDeps,
) !oauth.TokenSet {
    var state = try LoginPollState.init(deps, device);
    while (true) {
        switch (try pollTokenStep(alloc, transport, metadata, client_id, device, deps, &state)) {
            .succeeded => |token| return token,
            .waiting => {
                const wait_ms = state.waitMs(deps.now_ms(deps.ctx));
                if (wait_ms > 0) try waitBetweenPolls(alloc, prompt, deps, wait_ms);
            },
        }
    }
}

fn pollTokenStep(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    client_id: []const u8,
    device: oauth.DeviceAuthorization,
    deps: LoginPollDeps,
    state: *LoginPollState,
) !LoginPollStep {
    const now_ms = deps.now_ms(deps.ctx);
    if (now_ms >= state.expires_at_ms) return LoginError.LoginTimedOut;
    if (pollCancelled(deps)) return error.Cancelled;
    if (now_ms < state.next_poll_at_ms) return .waiting;

    var local_cancel_flag = std.atomic.Value(bool).init(false);
    const cancel_flag = deps.cancel_flag orelse &local_cancel_flag;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(deps.request_timeout_ms),
    });
    switch (try deps.poll_device_token(
        deps.ctx,
        alloc,
        transport,
        metadata,
        client_id,
        device.device_code,
        cancel_flag,
        deadline,
    )) {
        .success => |token| {
            if (pollCancelled(deps)) {
                var owned = token;
                owned.deinit(alloc);
                debug_trace.logf("auth", "sign-in poll discarded granted token after cancel", .{});
                return error.Cancelled;
            }
            return .{ .succeeded = token };
        },
        .pending => {},
        .slow_down => {
            state.interval_ms = std.math.add(u64, state.interval_ms, 5 * std.time.ms_per_s) catch
                return oauth.OAuthError.InvalidOAuthResponse;
            if (state.interval_ms > max_poll_interval_ms) return oauth.OAuthError.InvalidOAuthResponse;
        },
    }
    try state.scheduleNext(deps.now_ms(deps.ctx));
    return .waiting;
}

fn poll_interval_ms(interval_seconds: i64) oauth.OAuthError!u64 {
    const seconds = @max(interval_seconds, 1);
    const signed_interval_ms = std.math.mul(i64, seconds, std.time.ms_per_s) catch
        return oauth.OAuthError.InvalidOAuthResponse;
    const interval_ms = std.math.cast(u64, signed_interval_ms) orelse
        return oauth.OAuthError.InvalidOAuthResponse;
    if (interval_ms > max_poll_interval_ms) return oauth.OAuthError.InvalidOAuthResponse;
    return interval_ms;
}

fn waitBetweenPolls(
    alloc: Allocator,
    prompt: *BrowserOpenPrompt,
    deps: LoginPollDeps,
    interval_ms: u64,
) error{Cancelled}!void {
    var remaining_ms = interval_ms;
    while (remaining_ms > 0) {
        if (pollCancelled(deps)) return error.Cancelled;
        const slice_ms = @min(remaining_ms, poll_wait_slice_ms);
        if (prompt.enabled and !prompt.opened) {
            if (deps.wait_for_enter(deps.ctx, slice_ms)) {
                prompt.opened = true;
                _ = deps.url_opener.open(alloc, prompt.url) catch false;
            }
        } else {
            deps.sleep_ms(deps.ctx, slice_ms);
        }
        remaining_ms -= slice_ms;
    }
    if (pollCancelled(deps)) return error.Cancelled;
}

fn pollCancelled(deps: LoginPollDeps) bool {
    if (deps.is_cancelled(deps.ctx)) return true;
    const flag = deps.cancel_flag orelse return false;
    return flag.load(.seq_cst);
}

const BrowserOpenPrompt = struct {
    url: []const u8,
    enabled: bool = false,
    opened: bool = false,

    fn init(url: []const u8) !BrowserOpenPrompt {
        const stdin_is_tty = try std.Io.File.stdin().isTty(io_mod.getIo());
        return .{
            .url = url,
            .enabled = browserOpenEnabled(io_mod.getenv("FX_NO_OPEN_BROWSER") != null, stdin_is_tty, host.current()),
        };
    }

    fn writeWaitingMessage(self: BrowserOpenPrompt) !void {
        if (self.enabled) {
            try writeStdout("Waiting for authentication. Press Enter to open this in your browser, or use the URL manually.\n");
        } else {
            try writeStdout("Waiting for authentication...\n");
        }
    }
};

fn browserOpenEnabled(no_open_browser: bool, stdin_is_tty: bool, host_capabilities: host.Capabilities) bool {
    return !no_open_browser and stdin_is_tty and host_capabilities.native_url_open;
}

fn realNowMs(_: ?*anyopaque) i64 {
    return io_mod.milliTimestamp();
}

fn realPollDeviceToken(
    _: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    client_id: []const u8,
    device_code: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    return oauth.pollDeviceTokenBounded(
        alloc,
        transport,
        metadata,
        client_id,
        device_code,
        cancel_flag,
        deadline,
    );
}

fn neverCancelled(_: ?*anyopaque) bool {
    return false;
}

fn realSleepMs(_: ?*anyopaque, ms: u64) void {
    io_mod.sleep(ms *| std.time.ns_per_ms);
}

fn unavailableWaitForEnter(_: ?*anyopaque, _: u64) bool {
    return false;
}

fn realWaitForEnter(_: ?*anyopaque, timeout_ms: u64) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const timeout: i32 = @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
    const ready = std.posix.poll(&fds, timeout) catch return false;
    if (ready == 0 or (fds[0].revents & std.posix.POLL.IN) == 0) return false;
    discardStdinLine();
    return true;
}

fn discardStdinLine() void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return;
        if (n == 0) return;
        if (std.mem.findScalar(u8, buf[0..n], '\n') != null) return;
    }
}

fn fetchTeams(alloc: Allocator, access_token: []const u8, issuer_url: []const u8) !std.ArrayList(Team) {
    if (comptime host_target.is_wasm) return fetchTeamsFromJsHost(alloc, access_token, issuer_url);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const e2e_endpoint = if (oauth_session.isLoopbackE2EIssuer(issuer_url))
        try std.fmt.allocPrint(alloc, "{s}/v2/teams", .{issuer_url})
    else
        null;
    defer if (e2e_endpoint) |endpoint| alloc.free(endpoint);
    const endpoint = e2e_endpoint orelse teams_endpoint;

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer secret.zeroAndFree(alloc, auth_header);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .accept_encoding = .omit,
        },
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
    });
    if (result.status != .ok) return error.TeamRequestFailed;
    const body = try out.toOwnedSlice();
    defer alloc.free(body);
    return parseTeams(alloc, body);
}

fn fetchTeamsFromJsHost(
    alloc: Allocator,
    access_token: []const u8,
    issuer_url: []const u8,
) !std.ArrayList(Team) {
    const e2e_endpoint = if (oauth_session.isLoopbackE2EIssuer(issuer_url))
        try std.fmt.allocPrint(alloc, "{s}/v2/teams", .{issuer_url})
    else
        null;
    defer if (e2e_endpoint) |endpoint| alloc.free(endpoint);
    const endpoint = e2e_endpoint orelse teams_endpoint;

    var response = try js_host_auth.executeBearerGet(alloc, endpoint, access_token);
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.TeamRequestFailed;
    return parseTeams(alloc, response.body);
}

fn parseTeams(alloc: Allocator, bytes: []const u8) !std.ArrayList(Team) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();

    const teams_value = if (parsed.value == .object)
        parsed.value.object.get("teams") orelse return error.InvalidTeamsResponse
    else
        return error.InvalidTeamsResponse;
    if (teams_value != .array) return error.InvalidTeamsResponse;

    var teams: std.ArrayList(Team) = .empty;
    errdefer freeTeams(alloc, &teams);
    for (teams_value.array.items) |entry| {
        if (entry != .object) continue;
        const id = entry.object.get("id") orelse continue;
        const slug = entry.object.get("slug") orelse continue;
        if (id != .string or slug != .string) continue;
        const name_value = entry.object.get("name");
        const name = if (name_value != null and name_value.? == .string and name_value.?.string.len > 0)
            name_value.?.string
        else
            slug.string;
        var team = try dupeTeam(alloc, id.string, slug.string, name);
        teams.append(alloc, team) catch |err| {
            team.deinit(alloc);
            return err;
        };
    }
    return teams;
}

fn selectTeam(alloc: Allocator, teams: []const Team, current: ?[]const u8) !?usize {
    if (teams.len == 0) return null;
    if (teams.len == 1) return 0;

    const default_index = defaultTeamIndex(teams, current);
    const index = if (canUseInteractiveTeamPicker())
        selectTeamInteractive(alloc, teams, default_index) catch |err| switch (err) {
            error.NotATerminal => try selectTeamByLine(alloc, teams, default_index),
            else => return err,
        }
    else
        try selectTeamByLine(alloc, teams, default_index);
    return index;
}

fn defaultTeamIndex(teams: []const Team, current: ?[]const u8) usize {
    const needle = current orelse return 0;
    for (teams, 0..) |team, i| {
        if (std.mem.eql(u8, team.id, needle) or std.mem.eql(u8, team.slug, needle)) return i;
    }
    return 0;
}

fn selectTeamByLine(alloc: Allocator, teams: []const Team, default_index: usize) !usize {
    try writeStdout("\nSelect a Vercel team for AI Gateway:\n");
    try writeStdout("Model requests will use the selected team; Gateway access may still require billing or API setup.\n\n");
    for (teams, 0..) |team, i| {
        const marker = if (i == default_index) " (default)" else "";
        try writeStdoutFmt("  {d}. {s} ({s}){s}\n", .{ i + 1, team.name, team.slug, marker });
    }

    while (true) {
        try writeStdoutFmt("Team [{d}]: ", .{default_index + 1});
        const input = try readLine(alloc);
        defer alloc.free(input);
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) return default_index;
        const parsed_index = std.fmt.parseUnsigned(usize, trimmed, 10) catch {
            try writeStdout("Enter a team number from the list.\n");
            continue;
        };
        if (parsed_index >= 1 and parsed_index <= teams.len) return parsed_index - 1;
        try writeStdout("Enter a team number from the list.\n");
    }
}

fn selectTeamInteractive(alloc: Allocator, teams: []const Team, default_index: usize) !usize {
    var raw = try TeamPickerRawMode.enable();
    defer raw.disable();

    try writeStdout("\nSelect a Vercel team for AI Gateway:\n");
    try writeStdout("Model requests will use the selected team; Gateway access may still require billing or API setup.\n\n");

    var selected = default_index;
    var first_render = true;
    try renderTeamPicker(alloc, teams, selected, default_index, &first_render);

    while (true) {
        switch (try readTeamPickerKey()) {
            .up => {
                selected = if (selected == 0) teams.len - 1 else selected - 1;
                try renderTeamPicker(alloc, teams, selected, default_index, &first_render);
            },
            .down => {
                selected = if (selected + 1 == teams.len) 0 else selected + 1;
                try renderTeamPicker(alloc, teams, selected, default_index, &first_render);
            },
            .enter => return selected,
            .cancel => return LoginError.InvalidTeamSelection,
            .number => |number| {
                if (number >= 1 and number <= teams.len) return number - 1;
            },
            .ignored => {},
        }
    }
}

fn canUseInteractiveTeamPicker() bool {
    const stdin_tty = std.Io.File.stdin().isTty(io_mod.getIo()) catch false;
    return stdin_tty and std.c.isatty(std.posix.STDOUT_FILENO) != 0;
}

fn renderTeamPicker(
    alloc: Allocator,
    teams: []const Team,
    selected: usize,
    default_index: usize,
    first_render: *bool,
) !void {
    if (!first_render.*) {
        const move_up = try std.fmt.allocPrint(alloc, "\x1b[{d}A\r", .{teams.len});
        defer alloc.free(move_up);
        try writeStdout(move_up);
    }

    for (teams, 0..) |team, i| {
        const prefix = if (i == selected) "  › " else "    ";
        const marker = if (i == default_index) " (current)" else "";
        try writeStdoutFmt("\x1b[2K{s}{d}. {s} ({s}){s}\n", .{ prefix, i + 1, team.name, team.slug, marker });
    }
    first_render.* = false;
}

const TeamPickerKey = union(enum) {
    up,
    down,
    enter,
    cancel,
    number: usize,
    ignored,
};

fn readTeamPickerKey() !TeamPickerKey {
    var buf: [8]u8 = undefined;
    const first_read = try std.posix.read(std.posix.STDIN_FILENO, buf[0..1]);
    if (first_read == 0) return .ignored;

    var len = first_read;
    if (buf[0] == 0x1b) {
        while (len < buf.len) {
            if (escapeSequenceComplete(buf[0..len])) break;
            var fds = [_]std.posix.pollfd{.{
                .fd = std.posix.STDIN_FILENO,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try std.posix.poll(&fds, 25);
            if (ready == 0 or (fds[0].revents & std.posix.POLL.IN) == 0) break;
            const n = try std.posix.read(std.posix.STDIN_FILENO, buf[len .. len + 1]);
            if (n == 0) break;
            len += n;
        }
    }

    return parseTeamPickerKey(buf[0..len]);
}

fn escapeSequenceComplete(bytes: []const u8) bool {
    if (bytes.len < 3 or bytes[0] != 0x1b) return false;
    if (bytes[1] != '[' and bytes[1] != 'O') return true;
    const final = bytes[bytes.len - 1];
    return (final >= 'A' and final <= 'Z') or final == '~';
}

fn parseTeamPickerKey(bytes: []const u8) TeamPickerKey {
    if (bytes.len == 0) return .ignored;
    return switch (bytes[0]) {
        '\r', '\n' => .enter,
        3, 4 => .cancel,
        '1'...'9' => .{ .number = @intCast(bytes[0] - '0') },
        0x1b => parseEscapeTeamPickerKey(bytes),
        else => .ignored,
    };
}

fn parseEscapeTeamPickerKey(bytes: []const u8) TeamPickerKey {
    if (bytes.len >= 3 and (bytes[1] == '[' or bytes[1] == 'O')) {
        return switch (bytes[2]) {
            'A' => .up,
            'B' => .down,
            else => .ignored,
        };
    }
    return .cancel;
}

const TeamPickerRawMode = struct {
    original: std.posix.termios = undefined,
    active: bool = false,

    fn enable() !TeamPickerRawMode {
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
            return error.NotATerminal;
        }

        var self = TeamPickerRawMode{};
        self.original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = self.original;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        const vmin_idx = vminIndex();
        const vtime_idx = vtimeIndex();
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        self.active = true;
        return self;
    }

    fn disable(self: *TeamPickerRawMode) void {
        if (!self.active) return;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

fn vminIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 6,
        .macos, .ios, .tvos, .watchos, .visionos => 16,
        .freebsd, .netbsd, .dragonfly, .openbsd => 16,
        else => 16,
    };
}

fn vtimeIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 5,
        .macos, .ios, .tvos, .watchos, .visionos => 17,
        .freebsd, .netbsd, .dragonfly, .openbsd => 17,
        else => 17,
    };
}

fn dupeTeam(alloc: Allocator, source_id: []const u8, source_slug: []const u8, source_name: []const u8) !Team {
    const id = try alloc.dupe(u8, source_id);
    errdefer alloc.free(id);
    const slug = try alloc.dupe(u8, source_slug);
    errdefer alloc.free(slug);
    const name = try alloc.dupe(u8, source_name);
    errdefer alloc.free(name);
    return .{
        .id = id,
        .slug = slug,
        .name = name,
    };
}

fn check_parse_teams_allocation_failures(alloc: Allocator) !void {
    var teams = try parseTeams(
        alloc,
        "{\"teams\":[{\"id\":\"team-1\",\"slug\":\"one\",\"name\":\"One\"},{\"id\":\"team-2\",\"slug\":\"two\",\"name\":\"Two\"}]}",
    );
    defer freeTeams(alloc, &teams);
}

fn check_take_login_session_allocation_failures(alloc: Allocator) !void {
    var token = oauth.TokenSet{
        .access_token = &.{},
        .expires_in = 3600,
        .scope = &.{},
        .token_type = &.{},
    };
    defer token.deinit(alloc);
    token.access_token = try alloc.dupe(u8, "access");
    token.refresh_token = try alloc.dupe(u8, "refresh");
    token.scope = try alloc.dupe(u8, oauth.default_scope);
    token.token_type = try alloc.dupe(u8, "Bearer");

    var team_id = [_]u8{'i'};
    var team_slug = [_]u8{'s'};
    var team_name = [_]u8{'n'};
    const team = Team{
        .id = &team_id,
        .slug = &team_slug,
        .name = &team_name,
    };
    var session = try take_login_session(
        alloc,
        "https://vercel.com",
        "client",
        &token,
        &team,
        1_000,
    );
    defer session.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), token.access_token.len);
    try std.testing.expect(token.refresh_token == null);
}

fn freeTeams(alloc: Allocator, teams: *std.ArrayList(Team)) void {
    for (teams.items) |*team| team.deinit(alloc);
    teams.deinit(alloc);
}

test "team parsing cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_parse_teams_allocation_failures, .{});
}

test "single team selection does not allocate" {
    var id = [_]u8{'i'};
    var slug = [_]u8{'s'};
    var name = [_]u8{'n'};
    const teams = [_]Team{.{
        .id = &id,
        .slug = &slug,
        .name = &name,
    }};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expect((try selectTeam(failing.allocator(), &teams, null)) != null);
}

test "login session transfer cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_take_login_session_allocation_failures, .{});
}

fn readLine(alloc: Allocator) ![]u8 {
    var read_buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return try alloc.dupe(u8, "");
    return try alloc.dupe(u8, line orelse "");
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeStdoutFmt(comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeStdout(text);
}

test "login flow parses teams" {
    var teams = try parseTeams(
        std.testing.allocator,
        "{\"teams\":[{\"id\":\"team_1\",\"slug\":\"vercel-labs\",\"name\":\"Vercel Labs\"},{\"id\":\"team_2\",\"slug\":\"personal\"}]}",
    );
    defer freeTeams(std.testing.allocator, &teams);
    try std.testing.expectEqual(@as(usize, 2), teams.items.len);
    try std.testing.expectEqualStrings("team_1", teams.items[0].id);
    try std.testing.expectEqualStrings("Vercel Labs", teams.items[0].name);
    try std.testing.expectEqualStrings("personal", teams.items[1].name);
}

const ScriptedPollResult = enum {
    pending,
    slow_down,
    success,
};

const LoginPollTestState = struct {
    alloc: Allocator,
    results: []const ScriptedPollResult,
    poll_index: usize = 0,
    sleep_calls: std.ArrayList(u64) = .empty,
    wait_calls: std.ArrayList(u64) = .empty,
    enter_on_wait: ?usize = null,
    open_count: usize = 0,
    opened_url: ?[]const u8 = null,
    open_available: bool = true,
    open_error: bool = false,
    now_ms: i64 = 0,

    fn init(alloc: Allocator, results: []const ScriptedPollResult) LoginPollTestState {
        return .{ .alloc = alloc, .results = results };
    }

    fn deinit(self: *LoginPollTestState) void {
        self.sleep_calls.deinit(self.alloc);
        self.wait_calls.deinit(self.alloc);
    }

    fn deps(self: *LoginPollTestState) LoginPollDeps {
        return .{
            .ctx = self,
            .now_ms = testNowMs,
            .poll_device_token = testPollDeviceToken,
            .sleep_ms = testSleepMs,
            .wait_for_enter = testWaitForEnter,
            .url_opener = .{
                .context = self,
                .open_fn = testOpenBrowser,
            },
        };
    }

    fn testNowMs(raw: ?*anyopaque) i64 {
        const self = testState(raw);
        return self.now_ms;
    }

    fn testPollDeviceToken(
        raw: ?*anyopaque,
        alloc: Allocator,
        _: oauth_transport.Provider,
        _: oauth.Metadata,
        _: []const u8,
        _: []const u8,
        _: *std.atomic.Value(bool),
        _: std.Io.Clock.Timestamp,
    ) !oauth.PollResult {
        const self = testState(raw);
        if (self.poll_index >= self.results.len) return error.TestUnexpectedDevicePoll;
        const result = self.results[self.poll_index];
        self.poll_index += 1;
        return switch (result) {
            .pending => .pending,
            .slow_down => .slow_down,
            .success => .{ .success = try testTokenSet(alloc) },
        };
    }

    fn testSleepMs(raw: ?*anyopaque, ms: u64) void {
        const self = testState(raw);
        self.sleep_calls.append(self.alloc, ms) catch unreachable;
        self.now_ms += @intCast(ms);
    }

    fn testWaitForEnter(raw: ?*anyopaque, timeout_ms: u64) bool {
        const self = testState(raw);
        self.wait_calls.append(self.alloc, timeout_ms) catch unreachable;
        self.now_ms += @intCast(timeout_ms);
        return if (self.enter_on_wait) |index| self.wait_calls.items.len == index else false;
    }

    fn testOpenBrowser(
        raw: ?*anyopaque,
        _: Allocator,
        url: []const u8,
    ) host.UrlOpenError!bool {
        const self = testState(raw);
        self.open_count += 1;
        self.opened_url = url;
        if (self.open_error) return error.OutOfMemory;
        return self.open_available;
    }

    fn testState(raw: ?*anyopaque) *LoginPollTestState {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn testMetadata() oauth.Metadata {
    return .{
        .issuer = @constCast("https://vercel.test"),
        .device_authorization_endpoint = @constCast("https://vercel.test/device"),
        .token_endpoint = @constCast("https://vercel.test/token"),
    };
}

fn testDevice() oauth.DeviceAuthorization {
    return .{
        .device_code = @constCast("device"),
        .user_code = @constCast("USER-CODE"),
        .verification_uri = @constCast("https://vercel.test/oauth/device"),
        .expires_in = 60,
        .interval = 1,
    };
}

fn testTokenSet(alloc: Allocator) !oauth.TokenSet {
    return .{
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_in = 3600,
        .scope = try alloc.dupe(u8, oauth.default_scope),
        .token_type = try alloc.dupe(u8, "Bearer"),
    };
}

const SignInTestPollMode = enum {
    pending_then_wait,
    in_flight,
    success,
};

const SignInTestState = struct {
    mode: SignInTestPollMode,
    poll_started: std.atomic.Value(bool) = .init(false),
    poll_count: std.atomic.Value(usize) = .init(0),
    complete_count: std.atomic.Value(usize) = .init(0),
    save_count: std.atomic.Value(usize) = .init(0),

    fn deps(self: *@This()) SignInRuntimeDeps {
        return .{
            .ctx = self,
            .poll = .{
                .ctx = self,
                .poll_device_token = poll,
            },
            .complete = complete,
            .save = save,
        };
    }

    fn poll(
        raw: ?*anyopaque,
        alloc: Allocator,
        _: oauth_transport.Provider,
        _: oauth.Metadata,
        _: []const u8,
        _: []const u8,
        cancel_flag: *std.atomic.Value(bool),
        _: std.Io.Clock.Timestamp,
    ) !oauth.PollResult {
        const self = state(raw);
        _ = self.poll_count.fetchAdd(1, .seq_cst);
        self.poll_started.store(true, .seq_cst);
        return switch (self.mode) {
            .pending_then_wait => .pending,
            .in_flight => {
                while (!cancel_flag.load(.seq_cst)) blockingSleep(1);
                return error.Cancelled;
            },
            .success => .{ .success = try testTokenSet(alloc) },
        };
    }

    fn complete(
        raw: ?*anyopaque,
        alloc: Allocator,
        issuer_url: []const u8,
        client_id: []const u8,
        token: *oauth.TokenSet,
    ) !SignInCompletion {
        const self = state(raw);
        _ = self.complete_count.fetchAdd(1, .seq_cst);
        return .{ .vercel = .{
            .session = try take_login_session(
                alloc,
                issuer_url,
                client_id,
                token,
                null,
                0,
            ),
        } };
    }

    fn save(raw: ?*anyopaque, _: Allocator, _: SignInCompletion) !void {
        const self = state(raw);
        _ = self.save_count.fetchAdd(1, .seq_cst);
    }

    fn state(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
};

const CooperativeSignInTestState = struct {
    poll: LoginPollTestState,
    complete_count: usize = 0,
    save_count: usize = 0,
    fail_save: bool = false,

    fn init(alloc: Allocator, results: []const ScriptedPollResult) @This() {
        return .{ .poll = LoginPollTestState.init(alloc, results) };
    }

    fn deinit(self: *@This()) void {
        self.poll.deinit();
    }

    fn deps(self: *@This()) SignInRuntimeDeps {
        return .{
            .ctx = self,
            .poll = self.poll.deps(),
            .complete = complete,
            .save = save,
        };
    }

    fn complete(
        raw: ?*anyopaque,
        alloc: Allocator,
        issuer_url: []const u8,
        client_id: []const u8,
        token: *oauth.TokenSet,
    ) !SignInCompletion {
        const self = state(raw);
        self.complete_count += 1;
        return .{ .vercel = .{ .session = try take_login_session(
            alloc,
            issuer_url,
            client_id,
            token,
            null,
            0,
        ) } };
    }

    fn save(raw: ?*anyopaque, _: Allocator, _: SignInCompletion) !void {
        const self = state(raw);
        self.save_count += 1;
        if (self.fail_save) return error.TestStoreCommitFailed;
    }

    fn state(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn makeTestPreparedLogin(alloc: Allocator) !PreparedLogin {
    var metadata = try oauth.parseMetadata(
        alloc,
        "{\"issuer\":\"https://vercel.test\",\"device_authorization_endpoint\":\"https://vercel.test/device\",\"token_endpoint\":\"https://vercel.test/token\"}",
    );
    errdefer metadata.deinit(alloc);
    var device = try oauth.parseDeviceAuthorization(
        alloc,
        "{\"device_code\":\"device\",\"user_code\":\"USER-CODE\",\"verification_uri\":\"https://vercel.test/oauth/device\",\"verification_uri_complete\":\"https://vercel.test/oauth/device?code=USER-CODE\",\"expires_in\":60,\"interval\":1}",
    );
    errdefer device.deinit(alloc);
    return .{
        .metadata = metadata,
        .device = device,
        .client_id = try alloc.dupe(u8, "client"),
    };
}

fn blockingSleep(milliseconds: u64) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}

fn waitForAtomic(flag: *std.atomic.Value(bool), timeout_ms: u64) bool {
    var remaining_ms = timeout_ms;
    while (remaining_ms > 0) : (remaining_ms -= 1) {
        if (flag.load(.seq_cst)) return true;
        blockingSleep(1);
    }
    return flag.load(.seq_cst);
}

fn waitForSignInTransition(
    runtime: *SignInRuntime,
    alloc: Allocator,
    timeout_ms: u64,
) SignInTransition {
    var remaining_ms = timeout_ms;
    while (remaining_ms > 0) : (remaining_ms -= 1) {
        const transition = runtime.pollTransition(alloc);
        if (transition != .none) return transition;
        blockingSleep(1);
    }
    return runtime.pollTransition(alloc);
}

test "sign-in runtime releases an owned provider context exactly once" {
    const Cleanup = struct {
        fn run(raw: ?*anyopaque, _: Allocator) void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };

    const alloc = std.testing.allocator;
    var cleanup_count: usize = 0;
    var runtime: SignInRuntime = .{};
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        .{
            .ctx = &cleanup_count,
            .deinit_ctx = Cleanup.run,
        },
    ));
    try std.testing.expect(runtime.cancel(alloc));
    runtime.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

const WithholdingTokenFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn init() !@This() {
        var fixture: @This() = .{ .server = undefined };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;
        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn tokenEndpoint(self: *@This(), alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/oauth/token", .{
            self.server.socket.address.getPort(),
        });
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn wakeAccept(self: *@This()) void {
        var wake_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_backend.io();
        const address = std.Io.net.IpAddress{
            .ip4 = .loopback(self.server.socket.address.getPort()),
        };
        var stream = address.connect(zio, .{ .mode = .stream }) catch return;
        stream.close(zio);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and err == error.SocketNotListening) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        self.accepted.store(true, .seq_cst);
        while (!self.stopping.load(.seq_cst)) blockingSleep(10);
    }
};

fn makeLoopbackPreparedLogin(alloc: Allocator, token_endpoint: []const u8) !PreparedLogin {
    const issuer = try alloc.dupe(u8, token_endpoint[0..std.mem.lastIndexOfScalar(u8, token_endpoint, '/').?]);
    errdefer alloc.free(issuer);
    const device_endpoint = try std.fmt.allocPrint(alloc, "{s}/device", .{issuer});
    errdefer alloc.free(device_endpoint);
    const owned_token_endpoint = try alloc.dupe(u8, token_endpoint);
    errdefer alloc.free(owned_token_endpoint);
    var device = try oauth.parseDeviceAuthorization(
        alloc,
        "{\"device_code\":\"device\",\"user_code\":\"USER-CODE\",\"verification_uri\":\"https://vercel.test/oauth/device\",\"expires_in\":60,\"interval\":1}",
    );
    errdefer device.deinit(alloc);
    return .{
        .metadata = .{
            .issuer = issuer,
            .device_authorization_endpoint = device_endpoint,
            .token_endpoint = owned_token_endpoint,
        },
        .device = device,
        .client_id = try alloc.dupe(u8, "client"),
    };
}

fn elapsedAwakeMs(started: std.Io.Clock.Timestamp) i64 {
    return started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
}

test "cooperative sign-in polls once per pulse and shares pending and slow_down timing" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{ .pending, .slow_down, .success });
    defer state.deinit();
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));

    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 1), state.poll.poll_index);
    try std.testing.expectEqual(@as(i64, 1000), runtime.poll_state.?.next_poll_at_ms);
    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 1), state.poll.poll_index);

    state.poll.now_ms = 1000;
    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 2), state.poll.poll_index);
    try std.testing.expectEqual(@as(u64, 6000), runtime.poll_state.?.interval_ms);
    try std.testing.expectEqual(@as(i64, 7000), runtime.poll_state.?.next_poll_at_ms);
    state.poll.now_ms = 6999;
    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 2), state.poll.poll_index);

    state.poll.now_ms = 7000;
    runtime.pulseCooperative(alloc);
    var transition = runtime.pollTransition(alloc);
    switch (transition) {
        .succeeded => |*selection| selection.deinit(alloc),
        else => return error.TestExpectedSuccessfulSignIn,
    }
    try std.testing.expectEqual(@as(usize, 1), state.complete_count);
    try std.testing.expectEqual(@as(usize, 1), state.save_count);
}

test "cooperative sign-in cancellation publishes no session" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{.pending});
    defer state.deinit();
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    runtime.pulseCooperative(alloc);

    try std.testing.expect(runtime.cancel(alloc));
    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.complete_count);
    try std.testing.expectEqual(@as(usize, 0), state.save_count);
}

test "cooperative sign-in reports device-code expiry without another poll" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{.success});
    defer state.deinit();
    var prepared = try makeTestPreparedLogin(alloc);
    prepared.device.expires_in = 1;
    try std.testing.expect(try runtime.startPreparedCooperative(alloc, prepared, state.deps()));
    state.poll.now_ms = 1000;
    runtime.pulseCooperative(alloc);

    switch (runtime.pollTransition(alloc)) {
        .failed => |err| try std.testing.expectEqual(LoginError.LoginTimedOut, err),
        else => return error.TestExpectedExpiredSignIn,
    }
    try std.testing.expectEqual(@as(usize, 0), state.poll.poll_index);
    try std.testing.expectEqual(@as(usize, 0), state.save_count);
}

test "cooperative sign-in store failure is traced and becomes a recoverable transition" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "sign-in-store-failure.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "auth");

    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{.success});
    defer state.deinit();
    state.fail_save = true;
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    runtime.pulseCooperative(alloc);

    switch (runtime.pollTransition(alloc)) {
        .failed => |err| try std.testing.expectEqual(error.TestStoreCommitFailed, err),
        else => return error.TestExpectedStoreFailure,
    }
    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "sign-in session save failed err=TestStoreCommitFailed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "access") == null);
    try std.testing.expect(std.mem.find(u8, trace, "refresh") == null);
}

test "VT-8(b) cancelling sign-in during the inter-poll wait publishes and saves nothing" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = SignInTestState{ .mode = .pending_then_wait };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    try std.testing.expect(runtime.cancel(alloc));

    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.flow == null);
}

test "VT-8(b) cancelling sign-in during an in-flight poll publishes and saves nothing" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = SignInTestState{ .mode = .in_flight };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    try std.testing.expect(runtime.cancel(alloc));

    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.flow == null);
}

test "VT-8(c) cancelled sign-in is reaped before a second flow completes" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = SignInTestState{ .mode = .in_flight };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    try std.testing.expect(runtime.cancel(alloc));
    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expect(runtime.thread == null);

    state.mode = .success;
    state.poll_started.store(false, .seq_cst);
    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    const transition = waitForSignInTransition(&runtime, alloc, 500);
    switch (transition) {
        .succeeded => |completed| {
            var selection = completed;
            defer selection.deinit(alloc);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(usize, 1), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), state.save_count.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
}

test "VT-8(d) sign-in deinit cancels and joins a live worker" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    var state = SignInTestState{ .mode = .in_flight };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    runtime.deinit(alloc);

    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.flow == null);
    try std.testing.expectEqual(SignInState.idle, runtime.state);
    try std.testing.expectEqual(@as(usize, 0), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
}

test "VT-8(e) withheld token HTTP poll has bounded timeout cancel restart and deinit" {
    const alloc = std.testing.allocator;

    var timeout_fixture = try WithholdingTokenFixture.init();
    defer timeout_fixture.deinit();
    try timeout_fixture.start();
    const timeout_endpoint = try timeout_fixture.tokenEndpoint(alloc);
    defer alloc.free(timeout_endpoint);
    var timeout_runtime: SignInRuntime = .{};
    defer timeout_runtime.deinit(alloc);
    const timeout_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expect(try timeout_runtime.startPrepared(
        alloc,
        try makeLoopbackPreparedLogin(alloc, timeout_endpoint),
        .{
            .oauth_transport = test_builtin_gateway.oauth_transport_provider,
            .poll = .{ .request_timeout_ms = 40 },
        },
    ));
    const timeout_transition = waitForSignInTransition(&timeout_runtime, alloc, 1000);
    switch (timeout_transition) {
        .failed => |err| try std.testing.expect(err == error.Timeout),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(waitForAtomic(&timeout_fixture.accepted, 500));
    try std.testing.expect(elapsedAwakeMs(timeout_started) < 500);
    timeout_fixture.deinit();
    if (timeout_fixture.failure) |err| return err;

    var cancel_fixture = try WithholdingTokenFixture.init();
    defer cancel_fixture.deinit();
    try cancel_fixture.start();
    const cancel_endpoint = try cancel_fixture.tokenEndpoint(alloc);
    defer alloc.free(cancel_endpoint);
    var cancel_runtime: SignInRuntime = .{};
    defer cancel_runtime.deinit(alloc);
    try std.testing.expect(try cancel_runtime.startPrepared(
        alloc,
        try makeLoopbackPreparedLogin(alloc, cancel_endpoint),
        .{
            .oauth_transport = test_builtin_gateway.oauth_transport_provider,
            .poll = .{ .request_timeout_ms = 1000 },
        },
    ));
    try std.testing.expect(waitForAtomic(&cancel_fixture.accepted, 500));
    const cancel_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expect(cancel_runtime.cancel(alloc));
    try std.testing.expect(elapsedAwakeMs(cancel_started) < 500);
    try std.testing.expectEqual(SignInTransition.cancelled, cancel_runtime.pollTransition(alloc));

    var restart_state = SignInTestState{ .mode = .success };
    try std.testing.expect(try cancel_runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        restart_state.deps(),
    ));
    const restart_transition = waitForSignInTransition(&cancel_runtime, alloc, 500);
    switch (restart_transition) {
        .succeeded => |completed| {
            var selection = completed;
            defer selection.deinit(alloc);
        },
        else => try std.testing.expect(false),
    }
    cancel_fixture.deinit();
    if (cancel_fixture.failure) |err| return err;

    var deinit_fixture = try WithholdingTokenFixture.init();
    defer deinit_fixture.deinit();
    try deinit_fixture.start();
    const deinit_endpoint = try deinit_fixture.tokenEndpoint(alloc);
    defer alloc.free(deinit_endpoint);
    var deinit_runtime: SignInRuntime = .{};
    try std.testing.expect(try deinit_runtime.startPrepared(
        alloc,
        try makeLoopbackPreparedLogin(alloc, deinit_endpoint),
        .{
            .oauth_transport = test_builtin_gateway.oauth_transport_provider,
            .poll = .{ .request_timeout_ms = 1000 },
        },
    ));
    try std.testing.expect(waitForAtomic(&deinit_fixture.accepted, 500));
    const deinit_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    deinit_runtime.deinit(alloc);
    try std.testing.expect(elapsedAwakeMs(deinit_started) < 500);
    try std.testing.expect(deinit_runtime.thread == null);
    try std.testing.expect(deinit_runtime.flow == null);
    deinit_fixture.deinit();
    if (deinit_fixture.failure) |err| return err;
}

test "login polling starts before waiting for browser input" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{.success});
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device", .enabled = true };

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", testDevice(), &prompt, state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), state.poll_index);
    try std.testing.expectEqual(@as(usize, 0), state.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.sleep_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.open_count);
}

test "login polling opens browser once when enter arrives while waiting" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .pending, .pending, .success });
    state.enter_on_wait = 1;
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device", .enabled = true };

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", testDevice(), &prompt, state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), state.poll_index);
    try std.testing.expectEqual(@as(usize, 1), state.open_count);
    try std.testing.expectEqualStrings("https://vercel.test/oauth/device", state.opened_url.?);
    try std.testing.expectEqual(@as(usize, 1), state.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 19), state.sleep_calls.items.len);
    for (state.sleep_calls.items) |sleep_ms| {
        try std.testing.expectEqual(@as(u64, 100), sleep_ms);
    }
}

test "login polling continues when the URL opener is unavailable" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .pending, .pending, .success });
    state.enter_on_wait = 1;
    state.open_available = false;
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device", .enabled = true };

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", testDevice(), &prompt, state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), state.poll_index);
    try std.testing.expectEqual(@as(usize, 1), state.open_count);
    try std.testing.expect(prompt.opened);
}

test "login polling continues when the URL opener fails" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .pending, .pending, .success });
    state.enter_on_wait = 1;
    state.open_error = true;
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device", .enabled = true };

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", testDevice(), &prompt, state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), state.poll_index);
    try std.testing.expectEqual(@as(usize, 1), state.open_count);
    try std.testing.expect(prompt.opened);
}

test "login polling slow_down increases the next interval" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .slow_down, .success });
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device" };

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", testDevice(), &prompt, state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), state.poll_index);
    try std.testing.expectEqual(@as(usize, 60), state.sleep_calls.items.len);
    for (state.sleep_calls.items) |sleep_ms| {
        try std.testing.expectEqual(@as(u64, 100), sleep_ms);
    }
}

test "login polling disabled browser prompt still polls immediately" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .pending, .success });
    state.enter_on_wait = 1;
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device", .enabled = false };

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", testDevice(), &prompt, state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), state.poll_index);
    try std.testing.expectEqual(@as(usize, 0), state.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.open_count);
    try std.testing.expectEqual(@as(usize, 10), state.sleep_calls.items.len);
    for (state.sleep_calls.items) |sleep_ms| {
        try std.testing.expectEqual(@as(u64, 100), sleep_ms);
    }
}

test "login polling rejects invalid provider timing values" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{});
    defer state.deinit();
    var prompt = BrowserOpenPrompt{ .url = "https://vercel.test/oauth/device" };

    var device = testDevice();
    device.expires_in = -1;
    try std.testing.expectError(
        oauth.OAuthError.InvalidOAuthResponse,
        pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", device, &prompt, state.deps()),
    );

    device = testDevice();
    device.interval = @intCast(max_poll_interval_ms / std.time.ms_per_s + 1);
    try std.testing.expectError(
        oauth.OAuthError.InvalidOAuthResponse,
        pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testMetadata(), "client", device, &prompt, state.deps()),
    );
    try std.testing.expectEqual(@as(usize, 0), state.poll_index);
}

test "login browser opener respects environment tty and platform gates" {
    try std.testing.expect(!browserOpenEnabled(true, true, host.nativeForOs(.macos)));
    try std.testing.expect(!browserOpenEnabled(false, false, host.nativeForOs(.macos)));
    try std.testing.expect(!browserOpenEnabled(false, true, host.nativeForOs(.linux)));
    try std.testing.expect(browserOpenEnabled(false, true, host.nativeForOs(.macos)));
}

const std = @import("std");
const api_key_validator = @import("api_key_validator.zig");
const credentials = @import("credentials.zig");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const claude_oauth = @import("claude_oauth.zig");
const grok_oauth = @import("grok_oauth.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const login_flow = @import("login_flow.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const SourceSet = std.EnumSet(credentials.Source);

pub const CredentialRefreshMode = enum {
    if_needed,
    force,
};

const credential_source_order = [_]credentials.Source{
    .vercel_oidc_token,
    .ai_gateway_api_key,
    .fx_login,
    .stored_key,
    .chatgpt_subscription,
    .grok_subscription,
    .claude_subscription,
};

const SourceProbeFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!bool;
const CredentialLoaderFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!?credentials.Credential;
const StoredKeyStoreFn = *const fn (?*anyopaque, Allocator, []const u8) anyerror!void;

const max_api_key_entry_bytes: usize = 8 * 1024;
const max_api_key_mask_glyphs: usize = 32;
const max_team_query_bytes: usize = 256;

fn sourceLabelOrMissing(source: ?credentials.Source) []const u8 {
    return credentials.sourceLabel(source orelse return "missing");
}

pub const FailureReason = enum {
    credential_refresh_failed,
    http_unauthorized,
};

pub const FailureSnapshot = struct {
    source: credentials.Source,
    reason: FailureReason,
    http_status: ?std.http.Status = null,

    pub fn fromHttp(status: std.http.Status, source: ?credentials.Source) ?FailureSnapshot {
        if (status != .unauthorized) return null;
        return .{
            .source = source orelse return null,
            .reason = .http_unauthorized,
            .http_status = status,
        };
    }

    /// Returns owned, detail-free text. The caller owns the returned slice.
    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} {s}", .{
            credentials.sourceLabel(self.source),
            switch (self.reason) {
                .credential_refresh_failed => "credential refresh failed",
                .http_unauthorized => "authentication failed",
            },
        });
        if (self.http_status) |status| {
            try out.writer.print(" · HTTP {d}", .{@intFromEnum(status)});
        }
        return try out.toOwnedSlice();
    }

    /// Returns owned JSON containing only the shared auth-failure facts.
    pub fn renderJson(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(credentials.sourceLabel(self.source), .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        if (self.http_status) |status| {
            try writer.print(",\"http_status\":{d}", .{@intFromEnum(status)});
        }
        try writer.writeByte('}');
    }
};

/// Returns an owned token when the selected provider credential can refresh.
/// The caller must release it with `secret.zeroAndFree`.
pub fn refreshCredentialToken(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
) !?[]u8 {
    return refreshCredentialTokenForAccount(transport, alloc, source, mode, null);
}

pub fn refreshCredentialTokenForAccount(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    if (!credentials.sourceRefreshable(source)) return null;

    var credential = switch (source) {
        .fx_login => switch (mode) {
            .if_needed => (try credentials.loadFxLoginCredential(alloc, transport)) orelse return null,
            .force => (try credentials.refreshFxLoginCredential(alloc, transport)) orelse return null,
        },
        .chatgpt_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshChatGptCredential(alloc, transport)) orelse return null,
        },
        .grok_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshGrokCredential(alloc, transport)) orelse return null,
        },
        .claude_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshClaudeCredential(alloc, transport)) orelse return null,
        },
        else => unreachable,
    };
    defer credential.deinit(alloc);
    if (expected_account_id) |expected| {
        const actual = credential.accountId() orelse return error.ChatGptAccountChanged;
        if (!std.mem.eql(u8, expected, actual)) return error.ChatGptAccountChanged;
    }

    const token = credential.token;
    credential.token = &.{};
    return token;
}

pub const AcquisitionAction = enum {
    login,
    chatgpt_login,
    grok_login,
    claude_login,
    setup,
    change_team,
    switch_credential,
    switch_provider,
    /// Clears a remembered choice so resolution returns to plain precedence.
    /// Without it the only way back would be editing settings.json by hand.
    automatic,
};

pub const PickerStage = enum {
    root,
    provider,
    sign_in,
    api_key,
    change_team,
    switch_credential,
};

pub const ApiKeySaveStart = enum {
    started,
    /// Nothing typed, so Enter is a no-op the user already understands.
    empty,
    /// A previous save is still in flight. The entered key is discarded rather
    /// than queued, so the caller must say so instead of failing silently.
    busy,
};

pub const ApiKeySaveResult = union(enum) {
    empty,
    saved: bool,
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
};

/// The save does a gateway round trip and a key-store write, either of which can
/// take seconds. It runs on a worker so the event loop keeps drawing; the worker
/// performs I/O only and hands the loaded credential back for the main thread to
/// adopt, keeping `selected_credential` single-threaded.
pub const ApiKeySaveOutcome = union(enum) {
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
    loaded: credentials.Credential,

    pub fn deinit(self: *ApiKeySaveOutcome, alloc: Allocator) void {
        switch (self.*) {
            .loaded => |*credential| credential.deinit(alloc),
            else => {},
        }
        self.* = .reload_failed;
    }
};

const ApiKeySaveDeps = struct {
    ctx: ?*anyopaque = null,
    validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    store: StoredKeyStoreFn = storeUnavailableSecret,
    loader: CredentialLoaderFn = loadCredentialSource,
};

/// The whole save sequence with no runtime state, so outcome behaviour can be
/// tested synchronously while the worker owns only threading.
fn performApiKeySave(alloc: Allocator, key: []const u8, deps: ApiKeySaveDeps) ApiKeySaveOutcome {
    switch (deps.validator.validate(alloc, key)) {
        .accepted => {},
        .refused => return .gateway_refused,
        .unavailable => return .gateway_unavailable,
    }
    deps.store(deps.ctx, alloc, key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=store err={s}", .{@errorName(err)});
        return .store_failed;
    };
    const loaded = deps.loader(deps.ctx, alloc, .stored_key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=reload err={s}", .{@errorName(err)});
        return .reload_failed;
    };
    const credential = loaded orelse return .reload_failed;
    if (credential.source != .stored_key) {
        var wrong = credential;
        wrong.deinit(alloc);
        return .reload_failed;
    }
    return .{ .loaded = credential };
}

const ApiKeySaveRuntime = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    /// Owned for the worker's lifetime and zeroed by it, so the entry stage can
    /// drop its own buffer the moment the save starts.
    key: std.ArrayList(u8) = .empty,
    outcome: ?ApiKeySaveOutcome = null,
    deps: ApiKeySaveDeps = .{},

    fn start(self: *Self, alloc: Allocator, key: std.ArrayList(u8), deps: ApiKeySaveDeps) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = key;
            secret.zeroAndFree(alloc, rejected.allocatedSlice());
            return false;
        }
        self.running = true;
        self.key = key;
        self.deps = deps;
        self.mutex.unlock(io_mod.getIo());

        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, alloc }) catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.running = false;
            var abandoned = self.key;
            self.key = .empty;
            self.mutex.unlock(io_mod.getIo());
            secret.zeroAndFree(alloc, abandoned.allocatedSlice());
            debug_trace.logf("auth", "api key save worker failed to spawn", .{});
            return false;
        };
        return true;
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        const result = performApiKeySave(alloc, self.key.items, self.deps);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.outcome = result;
        self.running = false;
    }

    /// Returns the finished outcome once, joining the worker first. Ownership of a
    /// loaded credential passes to the caller.
    fn take(self: *Self, alloc: Allocator) ?ApiKeySaveOutcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running) {
            self.mutex.unlock(io_mod.getIo());
            return null;
        }
        const thread = self.thread;
        self.thread = null;
        const outcome = self.outcome;
        self.outcome = null;
        self.mutex.unlock(io_mod.getIo());

        if (thread) |handle| handle.join();
        _ = alloc;
        return outcome;
    }

    fn isSaving(self: *const Self) bool {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    fn deinit(self: *Self, alloc: Allocator) void {
        const thread = self.thread;
        self.thread = null;
        if (thread) |handle| handle.join();
        if (self.outcome) |*outcome| outcome.deinit(alloc);
        self.outcome = null;
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.running = false;
    }
};

const ApiKeyExitReason = enum {
    cancel,
    saved,
    save_failed,
    screen_replacement,
    runtime_deinit,
};

pub const Choice = union(enum) {
    provider: model_provider.ProviderId,
    source: credentials.Source,
    action: AcquisitionAction,
    team: usize,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .provider => |provider| switch (other) {
                .provider => |other_provider| provider == other_provider,
                .source, .action, .team => false,
            },
            .source => |source| switch (other) {
                .source => |other_source| source == other_source,
                .provider, .action, .team => false,
            },
            .action => |action| switch (other) {
                .provider, .source, .team => false,
                .action => |other_action| action == other_action,
            },
            .team => |team| switch (other) {
                .provider, .source, .action => false,
                .team => |other_team| team == other_team,
            },
        };
    }
};

pub const PickerView = struct {
    active: bool,
    available_sources: SourceSet,
    selected_choice: ?Choice,
    active_source: ?credentials.Source,
    active_provider: model_provider.ProviderId = .gateway,
    include_skip: bool,
    stage: PickerStage = .root,
    fx_login_session_available: bool = false,
    teams: []const login_flow.Team = &.{},
    current_team: ?[]const u8 = null,
    team_query: []const u8 = &.{},
    sign_in: login_flow.SignInSnapshot = .{},
    sign_in_source: credentials.Source = .fx_login,
    api_key_mask_count: usize = 0,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip)
                if (comptime host_target.is_wasm) 2 else 5
            else if (comptime host_target.is_wasm)
                4
            else
                8,
            .provider => if (comptime host_target.is_wasm) 2 else 4,
            .sign_in, .api_key => 0,
            .change_team => blk: {
                var count: usize = 0;
                for (self.teams) |team| {
                    if (teamMatchesQuery(team, self.team_query)) count += 1;
                }
                break :blk count;
            },
            .switch_credential => gatewaySourceCount(self.available_sources) + 1,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) {
            .root => if (self.include_skip)
                if (comptime host_target.is_wasm)
                    switch (index) {
                        0 => .{ .action = .login },
                        1 => .{ .action = .setup },
                        else => null,
                    }
                else switch (index) {
                    0 => .{ .action = .login },
                    1 => .{ .action = .chatgpt_login },
                    2 => .{ .action = .grok_login },
                    3 => .{ .action = .claude_login },
                    4 => .{ .action = .setup },
                    else => null,
                }
            else if (comptime host_target.is_wasm)
                switch (index) {
                    0 => .{ .action = .login },
                    1 => .{ .action = .setup },
                    2 => .{ .action = .change_team },
                    3 => .{ .action = .switch_credential },
                    else => null,
                }
            else switch (index) {
                0 => .{ .action = .login },
                1 => .{ .action = .chatgpt_login },
                2 => .{ .action = .grok_login },
                3 => .{ .action = .claude_login },
                4 => .{ .action = .setup },
                5 => .{ .action = .switch_provider },
                6 => .{ .action = .change_team },
                7 => .{ .action = .switch_credential },
                else => null,
            },
            .provider => switch (index) {
                0 => .{ .provider = .gateway },
                1 => .{ .provider = .codex },
                2 => if (comptime host_target.is_wasm) null else .{ .provider = .grok },
                3 => if (comptime host_target.is_wasm) null else .{ .provider = .claude },
                else => null,
            },
            .sign_in, .api_key => null,
            .change_team => blk: {
                var visible_index: usize = 0;
                for (self.teams, 0..) |team, team_index| {
                    if (!teamMatchesQuery(team, self.team_query)) continue;
                    if (visible_index == index) break :blk .{ .team = team_index };
                    visible_index += 1;
                }
                break :blk null;
            },
            .switch_credential => if (index < gatewaySourceCount(self.available_sources))
                .{ .source = gatewaySourceAtIndex(self.available_sources, index).? }
            else if (index == gatewaySourceCount(self.available_sources))
                .{ .action = .automatic }
            else
                null,
        };
    }

    pub fn choiceIsSelected(self: PickerView, choice: Choice) bool {
        const selected = self.selected_choice orelse return false;
        return selected.eql(choice);
    }

    pub fn selectedIndex(self: PickerView) usize {
        const selected = self.selected_choice orelse return 0;
        var index: usize = 0;
        while (self.choiceAt(index)) |choice| : (index += 1) {
            if (choice.eql(selected)) return index;
        }
        return 0;
    }

    pub fn choiceLabel(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| model_provider.label(provider),
            .source => |source| credentials.sourceLabel(source),
            .action => |action| switch (action) {
                .login => "Sign in with Vercel",
                .chatgpt_login => "Sign in with Codex",
                .grok_login => "Sign in with Grok",
                .claude_login => "Sign in with Claude",
                .setup => if (self.include_skip) "Add an API key" else "API key",
                .change_team => "Change team",
                .switch_credential => "Switch credential",
                .switch_provider => "Switch provider",
                .automatic => "Automatic",
            },
            .team => |index| if (index < self.teams.len) self.teams[index].name else "",
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| if (provider == self.active_provider) "current" else "available",
            .source => |source| if (self.active_source == source) "current" else "available",
            .action => |action| switch (action) {
                .login => if (self.fx_login_session_available) "connected" else "",
                .chatgpt_login => if (self.available_sources.contains(.chatgpt_subscription)) "connected" else "",
                .grok_login => if (self.available_sources.contains(.grok_subscription)) "connected" else "",
                .claude_login => if (self.available_sources.contains(.claude_subscription)) "connected" else "",
                .setup, .switch_credential, .switch_provider => "",
                .automatic => "use normal precedence",
                .change_team => if (self.fx_login_session_available) "choose a team" else "sign in first",
            },
            .team => |index| if (self.teamIsCurrent(index)) "current" else "",
        };
    }

    pub fn choiceEnabled(self: PickerView, choice: Choice) bool {
        return switch (choice) {
            .action => |action| (action != .change_team or self.fx_login_session_available) and
                (action != .chatgpt_login or !host_target.is_wasm) and
                (action != .grok_login or !host_target.is_wasm) and
                (action != .claude_login or !host_target.is_wasm),
            .provider, .source, .team => true,
        };
    }

    fn teamIsCurrent(self: PickerView, index: usize) bool {
        if (index >= self.teams.len) return false;
        const current = self.current_team orelse return false;
        const team = self.teams[index];
        return std.mem.eql(u8, current, team.id) or std.mem.eql(u8, current, team.slug);
    }
};

fn teamMatchesQuery(team: login_flow.Team, query: []const u8) bool {
    return text_utils.containsIgnoreCase(team.name, query) or
        text_utils.containsIgnoreCase(team.slug, query);
}

pub const GatewayTeamStatus = enum {
    set,
    unset,
    unknown,

    pub fn label(self: GatewayTeamStatus) []const u8 {
        return switch (self) {
            .set => "set",
            .unset => "unset",
            .unknown => "unknown",
        };
    }
};

pub const MissingHelpSurface = enum {
    cli,
    interactive,
};

pub const StatusSnapshot = struct {
    active_source: ?credentials.Source = null,
    required_source: ?credentials.Source = null,
    team: ?[]const u8 = null,
    owned_team: ?[]u8 = null,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    gateway_connected: bool = false,
    chatgpt_connected: bool = false,
    grok_connected: bool = false,
    /// The active credential is past its refresh deadline. Distinct from `refreshable`,
    /// which answers whether this source type can refresh at all.
    expired: bool = false,

    pub fn deinit(self: *StatusSnapshot, alloc: Allocator) void {
        if (self.owned_team) |team| alloc.free(team);
        self.* = .{};
    }

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn refreshable(self: StatusSnapshot) bool {
        const source = self.active_source orelse return false;
        return credentials.sourceRefreshable(source);
    }

    pub fn missingHelp(self: StatusSnapshot, surface: MissingHelpSurface) ?[]const u8 {
        if (self.active_source != null) return null;
        if (self.stored_key_status == .unavailable) return credentials.unreadable_store_message;
        if (self.required_source == .chatgpt_subscription) {
            return switch (surface) {
                .cli => credentials.missing_chatgpt_credential_message,
                .interactive => credentials.missing_chatgpt_interactive_credential_message,
            };
        }
        if (self.required_source == .grok_subscription) {
            return switch (surface) {
                .cli => credentials.missing_grok_credential_message,
                .interactive => credentials.missing_grok_interactive_credential_message,
            };
        }
        return switch (surface) {
            .cli => credentials.missing_credential_message,
            .interactive => credentials.missing_interactive_credential_message,
        };
    }

    /// Returns owned doctor status text containing no credential bytes.
    pub fn formatDoctorDetail(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        if (self.missingHelp(.cli)) |help| return alloc.dupe(u8, help);

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} is configured", .{self.activeSourceLabel()});
        if (self.expired) try out.writer.writeAll("; session expired");
        try out.writer.print("; refreshable={s}", .{if (self.refreshable()) "true" else "false"});
        if (self.team) |team| try out.writer.print("; team={s}", .{team});
        return try out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshot(
    alloc: Allocator,
    secret_store: host.SecretStore,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    return loadStatusSnapshotForProvider(alloc, secret_store, null, preferred);
}

pub fn loadStatusSnapshotForProvider(
    alloc: Allocator,
    secret_store: host.SecretStore,
    provider: ?model_provider.ProviderId,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    const chatgpt_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .chatgpt_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const grok_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .grok_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    // Resolves in `.stored` mode: a diagnostic must not refresh, because refreshing
    // rewrites the session file and performs network I/O. It reports the expired state
    // instead of repairing it.
    const resolution = (if (provider) |selected_provider|
        credentials.resolveForProvider(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            selected_provider,
            preferred,
        )
    else
        credentials.resolvePreferring(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            preferred,
        )) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // The store could not be interrogated, so its contents are unknown rather than absent.
        else => blk: {
            debug_trace.logf("auth", "status snapshot failed step=resolve err={s}", .{@errorName(err)});
            break :blk credentials.Resolution{ .stored_key_status = .unavailable };
        },
    };
    const resolved_source = if (resolution.credential) |credential| credential.source else null;
    var gateway_connected = resolved_source != null and resolved_source != .chatgpt_subscription and resolved_source != .grok_subscription and resolved_source != .claude_subscription;
    const gateway_probe_required = provider == .codex or provider == .grok or provider == .claude or
        resolved_source == .chatgpt_subscription or resolved_source == .grok_subscription or resolved_source == .claude_subscription;
    if (gateway_probe_required) {
        for ([_]credentials.Source{ .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key }) |source| {
            if (credentials.sourceExists(alloc, secret_store, source) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => false,
            }) {
                gateway_connected = true;
                break;
            }
        }
    }
    if (resolution.credential) |loaded| {
        var credential = loaded;
        defer credential.deinit(alloc);
        const expired = credential.needsRefreshAt(io_mod.milliTimestamp());
        const owned_team = takeDisplayTeam(alloc, &credential);
        return .{
            .active_source = credential.source,
            .team = owned_team,
            .owned_team = owned_team,
            .stored_key_status = resolution.stored_key_status,
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = expired,
        };
    }
    return .{
        .required_source = if (provider == .codex)
            .chatgpt_subscription
        else if (provider == .grok)
            .grok_subscription
        else if (provider == .claude)
            .claude_subscription
        else
            null,
        .stored_key_status = resolution.stored_key_status,
        .gateway_connected = gateway_connected,
        .chatgpt_connected = chatgpt_connected,
        .grok_connected = grok_connected,
    };
}

pub const View = struct {
    active_source: ?credentials.Source,
    available_inactive_sources: SourceSet,
    selected_team: ?[]const u8,
    refreshable: bool,
    stored_key_status: credentials.StoredKeyReadStatus,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn gatewayTeamStatus(self: View) GatewayTeamStatus {
        if (self.active_source == null) return .unknown;
        return if (self.selected_team == null) .unset else .set;
    }
};

pub const GatewayCredential = struct {
    api_key: []const u8,
    gateway_team: ?[]const u8,
    source: credentials.Source,
};

pub const Runtime = struct {
    const Self = @This();

    api_key_validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host.SecretStore = host.unavailable_secret_store,
    selected_credential: ?credentials.Credential = null,
    credential_refresh_failure_source: ?credentials.Source = null,
    source_inventory: SourceSet = .empty,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    provider_picker_active: model_provider.ProviderId = .gateway,
    fx_login_session_available: bool = false,
    team_selection: ?login_flow.TeamSelection = null,
    team_query: std.ArrayList(u8) = .empty,
    sign_in_flow: login_flow.SignInRuntime = .{},
    sign_in_source: credentials.Source = .fx_login,
    sign_in_returns_to_root: bool = false,
    api_key_input: std.ArrayList(u8) = .empty,
    api_key_returns_to_root: bool = false,
    api_key_save: ApiKeySaveRuntime = .{},

    pub fn init(
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) Self {
        return .{
            .api_key_validator = validator,
            .oauth_transport = transport,
            .secret_store = secret_store,
        };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.api_key_save.deinit(alloc);
        self.sign_in_flow.deinit(alloc);
        self.exitApiKeyStage(alloc, .runtime_deinit);
        self.clearTeamSelection(alloc);
        self.team_query.deinit(alloc);
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.* = .{};
    }

    /// Borrows the current credential until this runtime replaces or releases it.
    pub fn gatewayCredential(self: *const Self) ?GatewayCredential {
        return self.gatewayCredentialAt(io_mod.milliTimestamp());
    }

    fn gatewayCredentialAt(self: *const Self, now_ms: i64) ?GatewayCredential {
        const credential = self.selected_credential orelse return null;
        if (credential.needsRefreshAt(now_ms)) return null;
        return .{
            .api_key = credential.token,
            .gateway_team = credential.gatewayTeam(),
            .source = credential.source,
        };
    }

    pub fn apiKey(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.api_key;
    }

    pub fn oauthTransport(self: *const Self) oauth_transport.Provider {
        return self.oauth_transport;
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.secret_store;
    }

    pub fn modelCatalogAccess(self: *const Self) credentials.CatalogAccess {
        if (self.credential_refresh_failure_source) |source| {
            return credentials.catalogAccessAfterRefreshFailure(source);
        }
        return credentials.catalogAccessAt(self.selected_credential, io_mod.milliTimestamp());
    }

    pub fn recordCredentialRefreshFailure(self: *Self, source: credentials.Source) void {
        std.debug.assert(self.credentialSource() == source);
        self.credential_refresh_failure_source = source;
    }

    pub fn credentialSource(self: *const Self) ?credentials.Source {
        const credential = self.selected_credential orelse return null;
        return credential.source;
    }

    pub fn accountId(self: *const Self) ?[]const u8 {
        const credential = self.selected_credential orelse return null;
        return credential.accountId();
    }

    pub fn gatewayTeam(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.gateway_team;
    }

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        return self.credentialNeedsRefreshAt(io_mod.milliTimestamp());
    }

    fn credentialNeedsRefreshAt(self: *const Self, now_ms: i64) bool {
        const credential = self.selected_credential orelse return false;
        return credential.needsRefreshAt(now_ms);
    }

    pub fn statusSnapshot(self: *const Self) StatusSnapshot {
        return self.statusSnapshotAt(io_mod.milliTimestamp());
    }

    fn statusSnapshotAt(self: *const Self, now_ms: i64) StatusSnapshot {
        const gateway_connected = self.source_inventory.contains(.vercel_oidc_token) or
            self.source_inventory.contains(.ai_gateway_api_key) or
            self.source_inventory.contains(.fx_login) or
            self.source_inventory.contains(.stored_key);
        const chatgpt_connected = self.source_inventory.contains(.chatgpt_subscription);
        const grok_connected = self.source_inventory.contains(.grok_subscription);
        const credential = self.selected_credential orelse return .{
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
        };
        return .{
            .active_source = credential.source,
            .team = displayTeam(credential),
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = credential.needsRefreshAt(now_ms),
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var available_inactive_sources = self.source_inventory;
        if (active_source) |source| available_inactive_sources.remove(source);

        return .{
            .active_source = active_source,
            .available_inactive_sources = available_inactive_sources,
            .selected_team = if (self.selected_credential) |credential| credential.gatewayTeam() else null,
            .refreshable = if (active_source) |source| credentials.sourceRefreshable(source) else false,
            .stored_key_status = self.stored_key_status,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(
        self: *Self,
        stored_key_status: credentials.StoredKeyReadStatus,
        onboarding_skipped: bool,
    ) void {
        self.stored_key_status = stored_key_status;
        self.onboarding_skipped = onboarding_skipped;
    }

    pub fn skipOnboarding(self: *Self) void {
        self.onboarding_skipped = true;
    }

    pub fn refreshSourceInventory(self: *Self, alloc: Allocator) !void {
        try self.refreshSourceInventoryWithProbe(alloc, self, probeCredentialSource);
    }

    pub fn refreshChatGptSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .chatgpt_subscription)) {
            self.source_inventory.insert(.chatgpt_subscription);
        } else if (self.credentialSource() != .chatgpt_subscription) {
            self.source_inventory.remove(.chatgpt_subscription);
        }
    }

    pub fn refreshGrokSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .grok_subscription)) {
            self.source_inventory.insert(.grok_subscription);
        } else if (self.credentialSource() != .grok_subscription) {
            self.source_inventory.remove(.grok_subscription);
        }
    }

    pub fn refreshClaudeSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .claude_subscription)) {
            self.source_inventory.insert(.claude_subscription);
        } else if (self.credentialSource() != .claude_subscription) {
            self.source_inventory.remove(.claude_subscription);
        }
    }

    fn refreshSourceInventoryWithProbe(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
    ) !void {
        var detected: SourceSet = .empty;
        for (credential_source_order) |source| {
            if (try probe(ctx, alloc, source)) detected.insert(source);
        }
        self.fx_login_session_available = detected.contains(.fx_login);
        if (self.credentialSource()) |source| detected.insert(source);
        self.source_inventory = detected;
    }

    pub fn openPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, false);
    }

    pub fn openOnboardingPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, true);
    }

    fn openPickerWithSkip(self: *Self, alloc: Allocator, include_skip: bool) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = include_skip;
        self.picker_stage = .root;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn pickerView(self: *const Self) PickerView {
        return .{
            .active = self.picker_active,
            .available_sources = self.source_inventory,
            .selected_choice = self.picker_selection,
            .active_source = self.credentialSource(),
            .active_provider = self.provider_picker_active,
            .include_skip = self.picker_include_skip,
            .stage = self.picker_stage,
            .fx_login_session_available = self.fx_login_session_available,
            .teams = if (self.team_selection) |*selection| selection.teams.items else &.{},
            .current_team = if (self.team_selection) |*selection| selection.currentTeam() else null,
            .team_query = self.team_query.items,
            .sign_in = self.sign_in_flow.snapshot(),
            .sign_in_source = self.sign_in_source,
            .api_key_mask_count = @min(self.api_key_input.items.len, max_api_key_mask_glyphs),
        };
    }

    pub fn movePicker(self: *Self, delta: i32) bool {
        if (!self.picker_active or delta == 0) return false;
        const picker = self.pickerView();
        const choice_count = picker.choiceCount();
        if (choice_count < 2) return false;
        const selected_index = picker.selectedIndex();
        const next_index = if (delta < 0)
            if (selected_index == 0) choice_count - 1 else selected_index - 1
        else if (selected_index + 1 == choice_count)
            0
        else
            selected_index + 1;
        self.picker_selection = picker.choiceAt(next_index);
        return true;
    }

    pub fn openTeamPicker(self: *Self, alloc: Allocator, selection: *login_flow.TeamSelection) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.team_selection = selection.take();
        self.picker_stage = .change_team;
        self.picker_selection = self.currentTeamChoice() orelse self.pickerView().choiceAt(0);
    }

    pub fn openProviderPicker(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = false;
        self.picker_stage = .provider;
        self.provider_picker_active = active_provider;
        self.picker_selection = .{ .provider = active_provider };
    }

    pub fn teamPickerActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .change_team;
    }

    pub fn appendTeamQueryByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.teamPickerActive()) return false;
        if (byte < 0x20 or byte == 0x7f) return false;
        if (self.team_query.items.len < max_team_query_bytes) {
            try self.team_query.append(alloc, byte);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn deleteTeamQueryByte(self: *Self) bool {
        if (!self.teamPickerActive()) return false;
        if (self.team_query.items.len > 0) {
            const end = text_utils.utf8BackwardBoundary(
                self.team_query.items,
                self.team_query.items.len - 1,
            );
            self.team_query.shrinkRetainingCapacity(end);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn openSwitchCredentialPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_stage = .switch_credential;
        const active_source = self.credentialSource();
        self.picker_selection = if (active_source) |source|
            if (source != .chatgpt_subscription and source != .grok_subscription and source != .claude_subscription and self.source_inventory.contains(source))
                .{ .source = source }
            else
                self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    pub fn openApiKeyPicker(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, false);
    }

    pub fn openApiKeyPickerFromRoot(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, true);
    }

    fn openApiKeyPickerWithParent(self: *Self, alloc: Allocator, returns_to_root: bool) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .api_key;
        self.picker_selection = null;
        self.api_key_returns_to_root = returns_to_root;
    }

    pub fn openSignInPicker(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, false, .fx_login);
    }

    pub fn openSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, true, .fx_login);
    }

    pub fn openChatGptSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .chatgpt_subscription);
    }

    pub fn openChatGptSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .chatgpt_subscription);
    }

    pub fn openGrokSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .grok_subscription);
    }

    pub fn openGrokSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .grok_subscription);
    }

    pub fn openClaudeSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ClaudeOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .claude_subscription);
    }

    pub fn openClaudeSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ClaudeOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .claude_subscription);
    }

    fn openSignInPickerWithParent(
        self: *Self,
        alloc: Allocator,
        returns_to_root: bool,
        source: credentials.Source,
    ) !bool {
        self.exitSignInStage(alloc);
        const started = switch (source) {
            .fx_login => try self.sign_in_flow.start(alloc, self.oauth_transport),
            .chatgpt_subscription => try chatgpt_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            .grok_subscription => try grok_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            .claude_subscription => try claude_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            else => return error.InvalidSignInSource,
        };
        if (!started) return false;
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .sign_in;
        self.picker_selection = null;
        self.sign_in_source = source;
        self.sign_in_returns_to_root = returns_to_root;
        return true;
    }

    pub fn signInEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .sign_in;
    }

    pub fn signInReturnsToRoot(self: *const Self) bool {
        return self.sign_in_returns_to_root;
    }

    pub fn signInBrowserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        if (!self.signInEntryActive()) return null;
        return self.sign_in_flow.browserUrlAlloc(alloc);
    }

    pub fn pollSignInTransition(self: *Self, alloc: Allocator) login_flow.SignInTransition {
        return self.sign_in_flow.pollTransition(alloc);
    }

    pub fn pulseSignIn(self: *Self, alloc: Allocator) void {
        self.sign_in_flow.pulse(alloc);
    }

    pub fn apiKeyEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .api_key;
    }

    pub fn appendApiKeyByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len >= max_api_key_entry_bytes) return true;
        if (byte < 0x20 or byte == 0x7f) return true;
        // Reserve the entry ceiling up front so growth never abandons an
        // unzeroed buffer holding part of the key.
        try self.api_key_input.ensureTotalCapacityPrecise(alloc, max_api_key_entry_bytes);
        self.api_key_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteApiKeyByte(self: *Self) bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len > 0) _ = self.api_key_input.pop();
        return true;
    }

    /// Hands the entered key to a worker and pops the stage immediately. The key
    /// store write can block for seconds on a locked keychain, and the gateway
    /// check is a network round trip; neither may run on the event loop.
    pub fn beginApiKeySave(self: *Self, alloc: Allocator) ApiKeySaveStart {
        return self.beginApiKeySaveWithDeps(alloc, .{
            .ctx = self,
            .validator = self.api_key_validator,
            .store = storeRuntimeSecret,
            .loader = loadRuntimeCredentialSource,
        });
    }

    fn beginApiKeySaveWithDeps(self: *Self, alloc: Allocator, deps: ApiKeySaveDeps) ApiKeySaveStart {
        if (!self.apiKeyEntryActive() or self.api_key_input.items.len == 0) return .empty;

        // Ownership moves to the worker, so the stage exit below has nothing to zero.
        const key = self.api_key_input;
        self.api_key_input = .empty;

        const returns_to_root = self.api_key_returns_to_root;
        self.exitApiKeyStage(alloc, .saved);
        self.picker_active = returns_to_root;
        self.picker_stage = .root;
        self.picker_selection = if (returns_to_root) .{ .action = .setup } else null;

        return if (self.api_key_save.start(alloc, key, deps)) .started else .busy;
    }

    pub fn apiKeySaveInFlight(self: *const Self) bool {
        return self.api_key_save.isSaving();
    }

    /// Applies a finished save on the main thread. Adopting the credential here
    /// keeps `selected_credential` off the worker.
    pub fn takeApiKeySaveResult(self: *Self, alloc: Allocator) ?ApiKeySaveResult {
        var outcome = self.api_key_save.take(alloc) orelse return null;
        return switch (outcome) {
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
            .loaded => |*credential| blk: {
                var owned = credential.*;
                outcome = .reload_failed;
                defer owned.deinit(alloc);
                break :blk .{ .saved = self.adoptCredential(alloc, &owned) };
            },
        };
    }

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        const stage = self.picker_stage;
        if (stage == .root) {
            self.closePicker(alloc);
            return true;
        }
        if (stage == .provider) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .switch_provider };
            return true;
        }

        if (stage == .sign_in) {
            const returns_to_root = self.sign_in_returns_to_root;
            _ = self.sign_in_flow.cancel(alloc);
            self.sign_in_returns_to_root = false;
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
        }

        if (stage == .api_key) {
            const returns_to_root = self.api_key_returns_to_root;
            self.exitApiKeyStage(alloc, .cancel);
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
        }

        self.clearTeamSelection(alloc);
        self.picker_stage = .root;
        self.picker_selection = .{ .action = switch (stage) {
            .root => unreachable,
            .provider => unreachable,
            .sign_in => if (self.sign_in_source == .chatgpt_subscription)
                .chatgpt_login
            else if (self.sign_in_source == .grok_subscription)
                .grok_login
            else if (self.sign_in_source == .claude_subscription)
                .claude_login
            else
                .login,
            .api_key => .setup,
            .change_team => .change_team,
            .switch_credential => .switch_credential,
        } };
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active) return null;
        if (self.picker_stage == .sign_in or self.picker_stage == .api_key) return null;
        const choice = self.picker_selection;
        const selected = choice orelse return null;
        if (!self.pickerView().choiceEnabled(selected)) return null;

        switch (self.picker_stage) {
            .sign_in, .api_key => unreachable,
            .provider => switch (selected) {
                .provider => self.closePicker(alloc),
                .source, .action, .team => unreachable,
            },
            .root => switch (selected) {
                .provider => unreachable,
                .source => self.closePicker(alloc),
                .action => |action| switch (action) {
                    .change_team => {},
                    .switch_provider => {},
                    .switch_credential => {
                        self.openSwitchCredentialPicker(alloc);
                        return null;
                    },
                    .setup => {},
                    // Only reachable from the switch screen, never the root.
                    .automatic => unreachable,
                    .login, .chatgpt_login, .grok_login, .claude_login => self.closePicker(alloc),
                },
                .team => unreachable,
            },
            .change_team => switch (selected) {
                .team => {},
                .provider, .source, .action => unreachable,
            },
            .switch_credential => switch (selected) {
                .source => self.closePicker(alloc),
                // Automatic is the only action this stage offers; the app
                // handler clears the stored choice and closes the picker.
                .action => |action| std.debug.assert(action == .automatic),
                .provider, .team => unreachable,
            },
        }
        return choice;
    }

    fn exitSignInStage(self: *Self, alloc: Allocator) void {
        if (self.picker_stage != .sign_in) return;
        _ = self.sign_in_flow.cancel(alloc);
        self.sign_in_returns_to_root = false;
    }

    pub fn teamSelection(self: *Self) ?*login_flow.TeamSelection {
        if (!self.picker_active or self.picker_stage != .change_team) return null;
        return if (self.team_selection) |*selection| selection else null;
    }

    /// Moves the credential into this session and returns whether its source,
    /// token, effective Gateway team, or readiness changed.
    pub fn adoptCredential(self: *Self, alloc: Allocator, credential: *credentials.Credential) bool {
        const changed = if (self.selected_credential) |selected|
            selected.source != credential.source or
                !std.mem.eql(u8, selected.token, credential.token) or
                !optionalBytesEqual(selected.accountId(), credential.accountId()) or
                !optionalBytesEqual(selected.gatewayTeam(), credential.gatewayTeam()) or
                selected.refresh_after_ms != credential.refresh_after_ms
        else
            true;
        const source = credential.source;
        if (self.selected_credential) |*selected| selected.deinit(alloc);

        self.selected_credential = credential.*;
        self.credential_refresh_failure_source = null;
        credential.token = &.{};
        credential.account_id = null;
        credential.team_id = null;
        credential.team_slug = null;
        self.source_inventory.insert(source);
        if (source == .stored_key) self.stored_key_status = .not_attempted;
        return changed;
    }

    pub fn adoptSelectedTeam(self: *Self, alloc: Allocator, selected_team: *login_flow.SelectedTeam) bool {
        const credential = if (self.selected_credential) |*selected| selected else return false;
        if (credential.source != .fx_login) return false;

        const changed = !optionalBytesEqual(credential.team_id, selected_team.id) or
            !optionalBytesEqual(credential.team_slug, selected_team.slug);
        if (credential.team_id) |team| alloc.free(team);
        if (credential.team_slug) |team| alloc.free(team);
        credential.team_id = selected_team.id;
        credential.team_slug = selected_team.slug;
        selected_team.id = &.{};
        selected_team.slug = &.{};
        return changed;
    }

    fn selectSourceWithLoader(
        self: *Self,
        alloc: Allocator,
        source: credentials.Source,
        ctx: ?*anyopaque,
        loader: CredentialLoaderFn,
    ) !?bool {
        var credential = (try loader(ctx, alloc, source)) orelse return null;
        defer credential.deinit(alloc);
        if (credential.source != source) return error.CredentialSourceMismatch;
        return self.adoptCredential(alloc, &credential);
    }

    pub fn selectSource(self: *Self, alloc: Allocator, source: credentials.Source) !?bool {
        return self.selectSourceWithLoader(alloc, source, self, loadRuntimeCredentialSource);
    }

    pub fn selectForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) !?bool {
        return switch (provider) {
            .codex => if (self.credentialSource() == .chatgpt_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .chatgpt_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .grok => if (self.credentialSource() == .grok_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .grok_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .claude => if (self.credentialSource() == .claude_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .claude_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .gateway => if (self.credentialSource() != .chatgpt_subscription and self.credentialSource() != .grok_subscription and self.credentialSource() != .claude_subscription)
                false
            else
                @as(?bool, try self.reselectByPrecedenceWithDeps(
                    alloc,
                    self,
                    probeCredentialSource,
                    loadRuntimeCredentialSource,
                )),
        };
    }

    pub fn refreshFxLoginIfNeeded(self: *Self, alloc: Allocator) !bool {
        const source = self.credentialSource() orelse return false;
        if (!credentials.sourceRefreshable(source)) return false;

        const loaded = (try credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source)) orelse {
            if (self.credentialNeedsRefresh()) return error.CredentialRefreshUnavailable;
            return false;
        };
        var credential = loaded;
        defer credential.deinit(alloc);
        return self.adoptCredential(alloc, &credential);
    }

    /// Drops the current selection and re-runs precedence after the user clears
    /// a remembered credential source.
    pub fn reselectByPrecedence(self: *Self, alloc: Allocator) !bool {
        return self.reselectByPrecedenceWithDeps(alloc, self, probeCredentialSource, loadRuntimeCredentialSource);
    }

    fn reselectByPrecedenceWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const previous = self.credentialSource();
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_refresh_failure_source = null;

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription or source == .claude_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) {
                return self.credentialSource() != previous;
            }
            self.source_inventory.remove(source);
        }
        self.onboarding_skipped = false;
        return previous != null;
    }

    pub fn reconcileAfterChatGptLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.chatgpt_subscription);
        const was_active = self.credentialSource() == .chatgpt_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterGrokLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.grok_subscription);
        const was_active = self.credentialSource() == .grok_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterClaudeLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.claude_subscription);
        const was_active = self.credentialSource() == .claude_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterFxLoginLogout(self: *Self, alloc: Allocator) !bool {
        return self.reconcileAfterFxLoginLogoutWithDeps(
            alloc,
            self,
            probeCredentialSource,
            loadRuntimeCredentialSource,
        );
    }

    fn reconcileAfterFxLoginLogoutWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const login_was_active = self.credentialSource() == .fx_login;
        if (login_was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        if (!login_was_active) return false;

        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription or source == .claude_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) return true;
            self.source_inventory.remove(source);
        }

        self.onboarding_skipped = false;
        return true;
    }

    fn currentTeamChoice(self: *const Self) ?Choice {
        const picker = self.pickerView();
        for (picker.teams, 0..) |_, index| {
            if (picker.teamIsCurrent(index)) return .{ .team = index };
        }
        return null;
    }

    fn clearTeamSelection(self: *Self, alloc: Allocator) void {
        if (self.team_selection) |*selection| selection.deinit(alloc);
        self.team_selection = null;
        self.team_query.clearRetainingCapacity();
    }

    fn resetTeamPickerSelection(self: *Self) void {
        self.picker_selection = if (self.team_query.items.len == 0)
            self.currentTeamChoice() orelse self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    fn exitApiKeyStage(self: *Self, alloc: Allocator, reason: ApiKeyExitReason) void {
        const byte_count = self.api_key_input.items.len;
        if (self.api_key_input.capacity > 0) {
            const allocated = self.api_key_input.allocatedSlice();
            secret.zeroAndFree(alloc, allocated);
            self.api_key_input = .empty;
        }
        self.api_key_returns_to_root = false;
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "api key entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }
};

fn probeCredentialSource(raw_context: ?*anyopaque, alloc: Allocator, source: credentials.Source) !bool {
    const self: *Runtime = @ptrCast(@alignCast(raw_context.?));
    return credentials.sourceExists(alloc, self.secret_store, source);
}

fn loadCredentialSource(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    return credentials.loadSource(
        alloc,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        source,
    );
}

fn loadRuntimeCredentialSource(raw: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source);
}

fn storeRuntimeSecret(raw: ?*anyopaque, alloc: Allocator, value: []const u8) !void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.secret_store.store(alloc, value);
}

fn storeUnavailableSecret(_: ?*anyopaque, _: Allocator, _: []const u8) !void {
    return error.StoredKeyWriteFailed;
}

fn displayTeam(credential: credentials.Credential) ?[]const u8 {
    return credential.team_slug orelse credential.team_id;
}

fn takeDisplayTeam(alloc: Allocator, credential: *credentials.Credential) ?[]u8 {
    if (credential.team_slug) |team| {
        credential.team_slug = null;
        if (credential.team_id) |id| alloc.free(id);
        credential.team_id = null;
        return team;
    }
    const team = credential.team_id;
    credential.team_id = null;
    return team;
}

fn gatewaySourceCount(sources: SourceSet) usize {
    var count: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or source == .claude_subscription or !sources.contains(source)) continue;
        count += 1;
    }
    return count;
}

fn gatewaySourceAtIndex(sources: SourceSet, wanted_index: usize) ?credentials.Source {
    var index: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or source == .claude_subscription or !sources.contains(source)) continue;
        if (index == wanted_index) return source;
        index += 1;
    }
    return null;
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn makeTestCredential(
    alloc: Allocator,
    token: []const u8,
    source: credentials.Source,
    team_id: ?[]const u8,
    team_slug: ?[]const u8,
) !credentials.Credential {
    const owned_token = try alloc.dupe(u8, token);
    errdefer secret.zeroAndFree(alloc, owned_token);
    const owned_team_id = if (team_id) |team| try alloc.dupe(u8, team) else null;
    errdefer if (owned_team_id) |team| alloc.free(team);
    const owned_team_slug = if (team_slug) |team| try alloc.dupe(u8, team) else null;
    errdefer if (owned_team_slug) |team| alloc.free(team);
    return .{
        .token = owned_token,
        .source = source,
        .team_id = owned_team_id,
        .team_slug = owned_team_slug,
    };
}

const ApiKeySaveFixture = struct {
    validation: api_key_validator.Result = .accepted,
    fail_store: bool = false,
    fail_load: bool = false,
    /// Holds the worker inside `store` so a test can observe the in-flight
    /// window without racing it.
    gate: ?*std.atomic.Value(bool) = null,
    validate_calls: usize = 0,
    store_calls: usize = 0,
    load_calls: usize = 0,

    fn validate(raw_ctx: ?*anyopaque, _: Allocator, _: []const u8) api_key_validator.Result {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.validate_calls += 1;
        return self.validation;
    }

    fn validator(self: *@This()) api_key_validator.Provider {
        return .{
            .context = self,
            .validate_fn = validate,
        };
    }

    fn secretStore(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = secretStoreIsDisabled,
            .load_fn = secretStoreLoad,
            .store_fn = secretStoreWrite,
            .store_interactive_fn = secretStoreInteractiveWrite,
        };
    }

    fn secretStoreIsDisabled(_: ?*anyopaque) bool {
        return false;
    }

    fn secretStoreLoad(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
    ) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.load_calls += 1;
        if (self.fail_load) return error.StoredKeyUnreadable;
        return try alloc.dupe(u8, "loaded-key");
    }

    fn secretStoreWrite(
        raw_ctx: ?*anyopaque,
        _: Allocator,
        _: []const u8,
    ) host.SecretStoreWriteError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        if (self.gate) |gate| while (!gate.load(.seq_cst)) {};
        self.store_calls += 1;
        if (self.fail_store) return error.StoredKeyWriteFailed;
    }

    fn secretStoreInteractiveWrite(
        _: ?*anyopaque,
    ) host.SecretStoreWriteError!bool {
        return false;
    }

    fn store(raw_ctx: ?*anyopaque, _: Allocator, _: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        if (self.gate) |gate| while (!gate.load(.seq_cst)) {};
        self.store_calls += 1;
        if (self.fail_store) return error.TestStoreFailed;
    }

    fn load(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
        source: credentials.Source,
    ) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.load_calls += 1;
        if (self.fail_load) return error.TestLoadFailed;
        return try makeTestCredential(alloc, "loaded-key", source, null, null);
    }
};

fn enterTestApiKey(runtime: *Runtime, alloc: Allocator, value: []const u8) !void {
    runtime.openApiKeyPicker(alloc);
    for (value) |byte| try std.testing.expect(try runtime.appendApiKeyByte(alloc, byte));
}

fn appendTestTeam(
    selection: *login_flow.TeamSelection,
    alloc: Allocator,
    id_value: []const u8,
    slug_value: []const u8,
    name_value: []const u8,
) !void {
    const id = try alloc.dupe(u8, id_value);
    errdefer alloc.free(id);
    const slug = try alloc.dupe(u8, slug_value);
    errdefer alloc.free(slug);
    const name = try alloc.dupe(u8, name_value);
    errdefer alloc.free(name);
    try selection.teams.append(alloc, .{ .id = id, .slug = slug, .name = name });
}

fn expectApiKeyAllocationCleared(
    runtime: *const Runtime,
    backing: []const u8,
    sentinel: []const u8,
) !void {
    try std.testing.expectEqual(@as(usize, 0), runtime.api_key_input.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.api_key_input.capacity);
    try std.testing.expect(std.mem.indexOf(u8, backing, sentinel) == null);
}

test "auth runtime token refresher ignores non-refreshable credential sources" {
    for ([_]credentials.Source{ .vercel_oidc_token, .ai_gateway_api_key, .stored_key }) |source| {
        try std.testing.expect((try refreshCredentialToken(
            oauth_transport.unavailable_provider,
            std.testing.allocator,
            source,
            .force,
        )) == null);
    }
}

test "auth failure snapshot names every selected source without exposing styling" {
    const sources = [_]credentials.Source{
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .fx_login,
        .stored_key,
    };
    for (sources) |source| {
        const snapshot = FailureSnapshot.fromHttp(.unauthorized, source).?;
        try std.testing.expectEqual(FailureReason.http_unauthorized, snapshot.reason);
        try std.testing.expectEqual(std.http.Status.unauthorized, snapshot.http_status.?);

        const message = try snapshot.renderText(std.testing.allocator);
        defer std.testing.allocator.free(message);
        try std.testing.expect(std.mem.find(u8, message, credentials.sourceLabel(source)) != null);
        try std.testing.expect(std.mem.find(u8, message, "HTTP 401") != null);
        try std.testing.expect(std.mem.find(u8, message, "\x1b") == null);

        const json = try snapshot.renderJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(credentials.sourceLabel(source), parsed.value.object.get("source").?.string);
        try std.testing.expectEqualStrings("http_unauthorized", parsed.value.object.get("reason").?.string);
        try std.testing.expectEqual(@as(i64, 401), parsed.value.object.get("http_status").?.integer);
        try std.testing.expect(std.mem.find(u8, json, "\x1b") == null);
    }
}

test "auth failure snapshot keeps refresh failures distinct from HTTP rejection" {
    const snapshot = FailureSnapshot{
        .source = .fx_login,
        .reason = .credential_refresh_failed,
    };

    const message = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("fx login credential refresh failed", message);

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fx login", parsed.value.object.get("source").?.string);
    try std.testing.expectEqualStrings("credential_refresh_failed", parsed.value.object.get("reason").?.string);
    try std.testing.expect(parsed.value.object.get("http_status") == null);

    try std.testing.expect(FailureSnapshot.fromHttp(.forbidden, .fx_login) == null);
    try std.testing.expect(FailureSnapshot.fromHttp(.unauthorized, null) == null);
}

test "catalog access records a refresh failure until another credential is adopted" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var login = try makeTestCredential(alloc, "login-token", .fx_login, null, null);
    defer login.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &login);
    runtime.recordCredentialRefreshFailure(.fx_login);

    const failed = runtime.modelCatalogAccess();
    try std.testing.expectEqual(credentials.CatalogPublicOnlyReason.credential_refresh_failed, failed.publicOnlyReason().?);

    var api_key = try makeTestCredential(alloc, "api-key", .ai_gateway_api_key, null, null);
    defer api_key.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &api_key);

    const authenticated = runtime.modelCatalogAccess();
    try std.testing.expectEqualStrings("api-key", authenticated.authorizationCredential().?);
}

test "auth runtime adopts credential ownership and prefers team id" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var credential = try makeTestCredential(alloc, "token-a", .stored_key, "team_123", "vercel-labs");
    defer credential.deinit(alloc);

    try std.testing.expect(runtime.adoptCredential(alloc, &credential));
    try std.testing.expectEqualStrings("token-a", runtime.apiKey().?);
    try std.testing.expectEqual(credentials.Source.stored_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("team_123", runtime.gatewayTeam().?);
    try std.testing.expectEqual(@as(usize, 0), credential.token.len);
    try std.testing.expect(credential.team_id == null);
    try std.testing.expect(credential.team_slug == null);

    var different_source = try makeTestCredential(alloc, "token-a", .fx_login, null, "team_123");
    defer different_source.deinit(alloc);

    try std.testing.expect(runtime.adoptCredential(alloc, &different_source));
    try std.testing.expectEqual(credentials.Source.fx_login, runtime.credentialSource().?);

    var unchanged = try makeTestCredential(alloc, "token-a", .fx_login, null, "team_123");
    defer unchanged.deinit(alloc);
    try std.testing.expect(!runtime.adoptCredential(alloc, &unchanged));
}

test "auth runtime exposes one current Gateway credential for prompt admission" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    try std.testing.expect(runtime.gatewayCredential() == null);

    var credential = try makeTestCredential(alloc, "token-a", .fx_login, "team_123", "vercel-labs");
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);

    const gateway_credential = runtime.gatewayCredential().?;
    try std.testing.expectEqualStrings("token-a", gateway_credential.api_key);
    try std.testing.expectEqualStrings("team_123", gateway_credential.gateway_team.?);
    try std.testing.expectEqual(credentials.Source.fx_login, gateway_credential.source);
}

test "auth runtime withholds an Fx credential across its expiry boundary" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var credential = try makeTestCredential(alloc, "stale-token", .fx_login, "team_123", "vercel-labs");
    defer credential.deinit(alloc);
    credential.refresh_after_ms = 40_000;
    _ = runtime.adoptCredential(alloc, &credential);

    try std.testing.expect(!runtime.credentialNeedsRefreshAt(39_999));
    try std.testing.expect(runtime.gatewayCredentialAt(39_999) != null);
    try std.testing.expect(runtime.credentialNeedsRefreshAt(40_000));
    try std.testing.expect(runtime.gatewayCredentialAt(40_000) == null);
    try std.testing.expectEqual(credentials.Source.fx_login, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("team_123", runtime.view().selected_team.?);
    try std.testing.expectEqual(credentials.Source.fx_login, runtime.statusSnapshotAt(40_000).active_source.?);

    // The source is still reported; only its freshness changes across the boundary.
    try std.testing.expect(!runtime.statusSnapshotAt(39_999).expired);
    try std.testing.expect(runtime.statusSnapshotAt(40_000).expired);
    try std.testing.expect(runtime.statusSnapshotAt(40_000).refreshable());

    var refreshed = try makeTestCredential(alloc, "stale-token", .fx_login, "team_123", "vercel-labs");
    defer refreshed.deinit(alloc);
    refreshed.refresh_after_ms = 140_000;
    try std.testing.expect(runtime.adoptCredential(alloc, &refreshed));
    try std.testing.expect(!runtime.credentialNeedsRefreshAt(40_000));
    try std.testing.expectEqualStrings("stale-token", runtime.gatewayCredentialAt(40_000).?.api_key);
}

test "auth runtime view preserves missing and loaded states" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.recordStartupStatus(.unavailable, true);
    const missing = runtime.view();
    try std.testing.expect(missing.active_source == null);
    try std.testing.expect(missing.selected_team == null);
    try std.testing.expect(!missing.refreshable);
    try std.testing.expectEqual(credentials.StoredKeyReadStatus.unavailable, missing.stored_key_status);
    try std.testing.expect(missing.onboarding_skipped);
    try std.testing.expectEqual(GatewayTeamStatus.unknown, missing.gatewayTeamStatus());
    try std.testing.expectEqual(@as(usize, 0), missing.available_inactive_sources.count());

    runtime.source_inventory.insert(.fx_login);
    var credential = try makeTestCredential(alloc, "token", .fx_login, "team_123", null);
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);
    const loaded = runtime.view();
    try std.testing.expectEqual(credentials.Source.fx_login, loaded.active_source.?);
    try std.testing.expectEqualStrings("team_123", loaded.selected_team.?);
    try std.testing.expect(loaded.refreshable);
    try std.testing.expectEqual(GatewayTeamStatus.set, loaded.gatewayTeamStatus());
    try std.testing.expect(!loaded.available_inactive_sources.contains(.fx_login));
}

test "auth status snapshot labels every credential source without exposing tokens" {
    const alloc = std.testing.allocator;
    const sources = [_]credentials.Source{
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .fx_login,
        .stored_key,
    };

    for (sources) |source| {
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var credential = try makeTestCredential(alloc, "credential-secret", source, null, null);
        defer credential.deinit(alloc);
        _ = runtime.adoptCredential(alloc, &credential);

        const snapshot = runtime.statusSnapshot();
        try std.testing.expectEqualStrings(credentials.sourceLabel(source), snapshot.activeSourceLabel());
        try std.testing.expectEqual(credentials.sourceRefreshable(source), snapshot.refreshable());
        const detail = try snapshot.formatDoctorDetail(alloc);
        defer alloc.free(detail);
        try std.testing.expect(std.mem.find(u8, detail, snapshot.activeSourceLabel()) != null);
        try std.testing.expect(std.mem.find(u8, detail, "credential-secret") == null);
    }
}

test "auth status snapshot preserves display team and surface-specific missing help" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    const missing = runtime.statusSnapshot();
    try std.testing.expectEqualStrings(credentials.missing_credential_message, missing.missingHelp(.cli).?);
    try std.testing.expectEqualStrings(credentials.missing_interactive_credential_message, missing.missingHelp(.interactive).?);

    var credential = try makeTestCredential(alloc, "token", .fx_login, "team_123", "vercel-labs");
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);

    const selected = runtime.statusSnapshot();
    try std.testing.expectEqualStrings("vercel-labs", selected.team.?);
    try std.testing.expect(selected.missingHelp(.cli) == null);
}

test "auth status snapshot distinguishes an absent store from an unreadable one" {
    const alloc = std.testing.allocator;

    const absent = StatusSnapshot{ .stored_key_status = .not_found };
    try std.testing.expectEqualStrings(credentials.missing_credential_message, absent.missingHelp(.cli).?);

    const unreadable = StatusSnapshot{ .stored_key_status = .unavailable };
    try std.testing.expectEqualStrings(credentials.unreadable_store_message, unreadable.missingHelp(.cli).?);
    try std.testing.expectEqualStrings(credentials.unreadable_store_message, unreadable.missingHelp(.interactive).?);

    const detail = try unreadable.formatDoctorDetail(alloc);
    defer alloc.free(detail);
    try std.testing.expectEqualStrings(credentials.unreadable_store_message, detail);

    const resolved = StatusSnapshot{ .active_source = .fx_login, .stored_key_status = .unavailable };
    try std.testing.expect(resolved.missingHelp(.cli) == null);
}

test "auth status snapshot reports an expired session without claiming it is unrefreshable" {
    const alloc = std.testing.allocator;

    const fresh = StatusSnapshot{ .active_source = .fx_login, .team = "vercel-labs" };
    const fresh_detail = try fresh.formatDoctorDetail(alloc);
    defer alloc.free(fresh_detail);
    try std.testing.expectEqualStrings(
        "fx login is configured; refreshable=true; team=vercel-labs",
        fresh_detail,
    );

    const stale = StatusSnapshot{ .active_source = .fx_login, .team = "vercel-labs", .expired = true };
    const stale_detail = try stale.formatDoctorDetail(alloc);
    defer alloc.free(stale_detail);
    try std.testing.expectEqualStrings(
        "fx login is configured; session expired; refreshable=true; team=vercel-labs",
        stale_detail,
    );

    // The expired signal is additional state, never a downgrade of `refreshable`.
    try std.testing.expect(stale.refreshable());
    try std.testing.expect(stale.missingHelp(.cli) == null);
}

test "auth runtime view lists only detected credential sources" {
    var runtime: Runtime = .{};

    try std.testing.expectEqual(@as(usize, 0), runtime.view().available_inactive_sources.count());
}

test "auth runtime detects only credential sources that exist" {
    const Probe = struct {
        existing: SourceSet,

        fn exists(ctx: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.existing.contains(source);
        }
    };

    var runtime: Runtime = .{};
    var probe = Probe{ .existing = SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login }) };

    try runtime.refreshSourceInventoryWithProbe(std.testing.allocator, &probe, Probe.exists);

    const inventory = runtime.view().available_inactive_sources;
    try std.testing.expectEqual(@as(usize, 2), inventory.count());
    try std.testing.expect(inventory.contains(.ai_gateway_api_key));
    try std.testing.expect(inventory.contains(.fx_login));
    try std.testing.expect(!inventory.contains(.vercel_oidc_token));
    try std.testing.expect(!inventory.contains(.stored_key));
}

test "auth runtime owns onboarding skip state" {
    var runtime: Runtime = .{};

    try std.testing.expect(!runtime.view().onboarding_skipped);
    runtime.skipOnboarding();
    try std.testing.expect(runtime.view().onboarding_skipped);
}

test "auth runtime pins every supported credential source to the session" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    const sources = [_]credentials.Source{
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .fx_login,
        .stored_key,
    };
    for (sources) |source| {
        var credential = try makeTestCredential(alloc, @tagName(source), source, null, null);
        defer credential.deinit(alloc);
        _ = runtime.adoptCredential(alloc, &credential);

        try std.testing.expectEqual(source, runtime.credentialSource().?);
        try std.testing.expectEqualStrings(@tagName(source), runtime.apiKey().?);
    }
}

test "auth runtime explicitly selects the requested credential source" {
    const Loader = struct {
        fn load(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
            return try makeTestCredential(alloc, @tagName(source), source, null, null);
        }
    };

    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var startup = try makeTestCredential(alloc, "startup-token", .vercel_oidc_token, null, null);
    defer startup.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &startup);

    try std.testing.expect((try runtime.selectSourceWithLoader(alloc, .fx_login, null, Loader.load)).?);
    try std.testing.expectEqual(credentials.Source.fx_login, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("fx_login", runtime.apiKey().?);
}

test "auth runtime failed selection preserves the active credential" {
    const Loader = struct {
        missing: credentials.Source,
        failing: credentials.Source,

        fn load(ctx: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (source == self.failing) return error.SourceReadFailed;
            if (source == self.missing) return null;
            return try makeTestCredential(alloc, @tagName(source), source, null, null);
        }
    };

    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var active = try makeTestCredential(alloc, "active-token", .ai_gateway_api_key, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    var loader = Loader{ .missing = .fx_login, .failing = .stored_key };
    try std.testing.expect((try runtime.selectSourceWithLoader(alloc, .fx_login, &loader, Loader.load)) == null);
    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-token", runtime.apiKey().?);

    try std.testing.expectError(
        error.SourceReadFailed,
        runtime.selectSourceWithLoader(alloc, .stored_key, &loader, Loader.load),
    );
    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-token", runtime.apiKey().?);
}

const LogoutFixture = struct {
    existing: SourceSet,
    load_count: usize = 0,

    fn probe(ctx: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.existing.contains(source);
    }

    fn load(ctx: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.load_count += 1;
        if (!self.existing.contains(source)) return null;
        return try makeTestCredential(alloc, @tagName(source), source, null, null);
    }
};

test "logout replaces an active fx login with the next available source" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.skipOnboarding();

    var active = try makeTestCredential(alloc, "fx-token", .fx_login, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    var fixture = LogoutFixture{
        .existing = SourceSet.initMany(&.{ .ai_gateway_api_key, .stored_key }),
    };
    try std.testing.expect(try runtime.reconcileAfterFxLoginLogoutWithDeps(
        alloc,
        &fixture,
        LogoutFixture.probe,
        LogoutFixture.load,
    ));

    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("ai_gateway_api_key", runtime.apiKey().?);
    try std.testing.expect(!runtime.source_inventory.contains(.fx_login));
    try std.testing.expect(runtime.source_inventory.contains(.stored_key));
    try std.testing.expect(runtime.view().onboarding_skipped);
}

test "logout preserves an active non-login credential" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var active = try makeTestCredential(alloc, "active-api-key", .ai_gateway_api_key, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);
    runtime.source_inventory.insert(.fx_login);

    var fixture = LogoutFixture{ .existing = SourceSet.initOne(.ai_gateway_api_key) };
    try std.testing.expect(!try runtime.reconcileAfterFxLoginLogoutWithDeps(
        alloc,
        &fixture,
        LogoutFixture.probe,
        LogoutFixture.load,
    ));

    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-api-key", runtime.apiKey().?);
    try std.testing.expect(!runtime.source_inventory.contains(.fx_login));
    try std.testing.expectEqual(@as(usize, 0), fixture.load_count);
}

test "logout clears the active login and re-enables auth selection when no source remains" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.skipOnboarding();

    var active = try makeTestCredential(alloc, "fx-token", .fx_login, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    var fixture = LogoutFixture{ .existing = .empty };
    try std.testing.expect(try runtime.reconcileAfterFxLoginLogoutWithDeps(
        alloc,
        &fixture,
        LogoutFixture.probe,
        LogoutFixture.load,
    ));

    try std.testing.expect(runtime.credentialSource() == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.source_inventory.count());
    try std.testing.expect(!runtime.view().onboarding_skipped);
}

test "logout reconciliation adopts a newer concurrent fx login" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var active = try makeTestCredential(alloc, "old-fx-token", .fx_login, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    var fixture = LogoutFixture{ .existing = SourceSet.initOne(.fx_login) };
    try std.testing.expect(try runtime.reconcileAfterFxLoginLogoutWithDeps(
        alloc,
        &fixture,
        LogoutFixture.probe,
        LogoutFixture.load,
    ));

    try std.testing.expectEqual(credentials.Source.fx_login, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("fx_login", runtime.apiKey().?);
    try std.testing.expect(runtime.source_inventory.contains(.fx_login));
}

test "auth picker root starts on sign in and keeps sources in the switch stage" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.source_inventory = SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    var credential = try makeTestCredential(alloc, "token", .ai_gateway_api_key, null, null);
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);

    runtime.openPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expect(picker.active);
    try std.testing.expect((Choice{ .action = .login }).eql(picker.selected_choice.?));
    try std.testing.expectEqual(@as(usize, 8), picker.choiceCount());
    try std.testing.expectEqualStrings("Switch provider", picker.choiceLabel(picker.choiceAt(5).?));
    try std.testing.expect(picker.choiceAt(8) == null);
}

test "credential switcher excludes provider-routed subscription sessions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.source_inventory = SourceSet.initMany(&.{ .ai_gateway_api_key, .chatgpt_subscription, .grok_subscription });
    runtime.openPicker(alloc);
    runtime.openSwitchCredentialPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expectEqual(@as(usize, 2), picker.choiceCount());
    try std.testing.expect((Choice{ .source = .ai_gateway_api_key }).eql(picker.choiceAt(0).?));
    try std.testing.expect((Choice{ .action = .automatic }).eql(picker.choiceAt(1).?));
}

test "auth picker navigation wraps across the eight hub actions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.source_inventory = SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    runtime.openPicker(alloc);

    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .grok_login }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .claude_login }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .setup }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expectEqualStrings("Switch provider", runtime.pickerView().choiceLabel(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .change_team }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .switch_credential }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .login }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(-1));
    try std.testing.expect((Choice{ .action = .switch_credential }).eql(runtime.pickerView().selected_choice.?));
}

test "auth picker selection closes before returning its typed choice" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.source_inventory = SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });

    try std.testing.expect(runtime.takePickerChoice(alloc) == null);
    runtime.openPicker(alloc);

    try std.testing.expect((Choice{ .action = .login }).eql(runtime.takePickerChoice(alloc).?));
    try std.testing.expect(!runtime.pickerView().active);
}

test "auth picker without credentials exposes acquisition actions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.openPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expect(picker.active_source == null);
    try std.testing.expect((Choice{ .action = .login }).eql(picker.selected_choice.?));
    try std.testing.expectEqual(@as(usize, 0), picker.available_sources.count());
    try std.testing.expectEqual(@as(usize, 8), picker.choiceCount());
    try std.testing.expect(!picker.choiceEnabled(.{ .action = .change_team }));
    try std.testing.expectEqualStrings("missing", picker.activeSourceLabel());
}

test "auth onboarding picker exposes the setup paths" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.openOnboardingPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expect(picker.include_skip);
    try std.testing.expectEqual(@as(usize, 5), picker.choiceCount());
    try std.testing.expect((Choice{ .action = .login }).eql(picker.choiceAt(0).?));
    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(picker.choiceAt(1).?));
    try std.testing.expect((Choice{ .action = .grok_login }).eql(picker.choiceAt(2).?));
    try std.testing.expect((Choice{ .action = .claude_login }).eql(picker.choiceAt(3).?));
    try std.testing.expect((Choice{ .action = .setup }).eql(picker.choiceAt(4).?));
    try std.testing.expectEqualStrings("Add an API key", picker.choiceLabel(picker.choiceAt(4).?));
    try std.testing.expect(picker.choiceAt(5) == null);
}

test "clearing a remembered choice re-resolves even when no login was active" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    // stored_key is last in precedence, so a session sitting on it must move
    // once the remembered choice that pinned it there is gone.
    var pinned = try makeTestCredential(alloc, "stored-token", .stored_key, null, null);
    defer pinned.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &pinned);
    try std.testing.expectEqual(credentials.Source.stored_key, runtime.credentialSource().?);

    var fixture = LogoutFixture{
        .existing = SourceSet.initMany(&.{ .ai_gateway_api_key, .stored_key }),
    };
    const changed = try runtime.reselectByPrecedenceWithDeps(
        alloc,
        &fixture,
        LogoutFixture.probe,
        LogoutFixture.load,
    );
    try std.testing.expect(changed);
    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, runtime.credentialSource().?);
}

test "switch credential stage includes the active source and pops to its root action" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var active = try makeTestCredential(alloc, "active-token", .stored_key, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);
    runtime.openPicker(alloc);
    runtime.openSwitchCredentialPicker(alloc);

    const switch_view = runtime.pickerView();
    try std.testing.expectEqual(PickerStage.switch_credential, switch_view.stage);
    // One resolvable source plus the trailing Automatic row.
    try std.testing.expectEqual(@as(usize, 2), switch_view.choiceCount());
    try std.testing.expect((Choice{ .action = .automatic }).eql(switch_view.choiceAt(1).?));
    try std.testing.expect((Choice{ .source = .stored_key }).eql(switch_view.selected_choice.?));
    try std.testing.expectEqualStrings(
        credentials.sourceLabel(.stored_key),
        switch_view.choiceLabel(switch_view.selected_choice.?),
    );

    try std.testing.expect(runtime.popPickerStage(alloc));
    const root_view = runtime.pickerView();
    try std.testing.expect(root_view.active);
    try std.testing.expectEqual(PickerStage.root, root_view.stage);
    try std.testing.expect((Choice{ .action = .switch_credential }).eql(root_view.selected_choice.?));
}

test "provider stage pops to its setup root action" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.openPicker(alloc);
    runtime.openProviderPicker(alloc, .codex);

    try std.testing.expect(runtime.popPickerStage(alloc));
    const root_view = runtime.pickerView();
    try std.testing.expect(root_view.active);
    try std.testing.expectEqual(PickerStage.root, root_view.stage);
    try std.testing.expectEqualStrings("Switch provider", root_view.choiceLabel(root_view.selected_choice.?));
}

test "change team stage owns fetched rows and releases them when popped" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.openPicker(alloc);

    var selection: login_flow.TeamSelection = .{};
    defer selection.deinit(alloc);
    try appendTestTeam(&selection, alloc, "team_123", "vercel-labs", "Vercel Labs");

    runtime.openTeamPicker(alloc, &selection);
    const team_view = runtime.pickerView();
    try std.testing.expectEqual(PickerStage.change_team, team_view.stage);
    try std.testing.expectEqual(@as(usize, 1), team_view.choiceCount());
    try std.testing.expectEqualStrings("Vercel Labs", team_view.choiceLabel(.{ .team = 0 }));

    try std.testing.expect(runtime.popPickerStage(alloc));
    try std.testing.expectEqual(PickerStage.root, runtime.pickerView().stage);
    try std.testing.expectEqual(@as(usize, 0), runtime.pickerView().teams.len);
}

test "change team search filters by name and slug without losing original indexes" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.openPicker(alloc);

    var selection: login_flow.TeamSelection = .{};
    defer selection.deinit(alloc);
    try appendTestTeam(&selection, alloc, "team_456", "other-team", "Other Team");
    try appendTestTeam(
        &selection,
        alloc,
        "team_123",
        "example-internal-team",
        "Example Internal Team",
    );
    try appendTestTeam(&selection, alloc, "team_789", "zero-conf", "Zero Conf");

    runtime.openTeamPicker(alloc, &selection);
    for ("EXAMPLE") |byte| try std.testing.expect(try runtime.appendTeamQueryByte(alloc, byte));

    const name_match = runtime.pickerView();
    try std.testing.expectEqualStrings("EXAMPLE", name_match.team_query);
    try std.testing.expectEqual(@as(usize, 1), name_match.choiceCount());
    try std.testing.expect((Choice{ .team = 1 }).eql(name_match.choiceAt(0).?));
    try std.testing.expectEqualStrings("Example Internal Team", name_match.choiceLabel(name_match.choiceAt(0).?));

    for (0..7) |_| try std.testing.expect(runtime.deleteTeamQueryByte());
    for ("zero-conf") |byte| try std.testing.expect(try runtime.appendTeamQueryByte(alloc, byte));
    const slug_match = runtime.pickerView();
    try std.testing.expectEqual(@as(usize, 1), slug_match.choiceCount());
    try std.testing.expect((Choice{ .team = 2 }).eql(slug_match.selected_choice.?));

    try std.testing.expect(runtime.popPickerStage(alloc));
    try std.testing.expectEqualStrings("", runtime.pickerView().team_query);
}

test "change team view marks the session team as current" {
    var team_id = [_]u8{ 't', 'e', 'a', 'm', '_', '1' };
    var team_slug = [_]u8{ 'v', 'e', 'r', 'c', 'e', 'l' };
    var team_name = [_]u8{ 'V', 'e', 'r', 'c', 'e', 'l' };
    const teams = [_]login_flow.Team{.{
        .id = &team_id,
        .slug = &team_slug,
        .name = &team_name,
    }};
    const view = PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = .{ .team = 0 },
        .active_source = .stored_key,
        .include_skip = false,
        .stage = .change_team,
        .teams = &teams,
        .current_team = "team_1",
    };

    try std.testing.expectEqualStrings("current", view.choiceDescription(.{ .team = 0 }));
}

test "auth picker cancellation preserves the active credential source" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.source_inventory = SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    var active = try makeTestCredential(alloc, "active-token", .ai_gateway_api_key, null, null);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    runtime.openPicker(alloc);
    _ = runtime.movePicker(1);
    runtime.closePicker(alloc);

    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-token", runtime.apiKey().?);
}

test "an api key save runs off the event loop and is reaped" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var fixture: ApiKeySaveFixture = .{};

    runtime.openApiKeyPicker(alloc);
    for ("vck_worker_probe") |byte| _ = try runtime.appendApiKeyByte(alloc, byte);

    try std.testing.expectEqual(ApiKeySaveStart.started, runtime.beginApiKeySaveWithDeps(alloc, .{
        .ctx = @ptrCast(&fixture),
        .validator = fixture.validator(),
        .store = ApiKeySaveFixture.store,
        .loader = ApiKeySaveFixture.load,
    }));
    // The stage releases its buffer immediately; the worker owns the key now.
    try std.testing.expectEqual(@as(usize, 0), runtime.api_key_input.capacity);
    try std.testing.expect(!runtime.apiKeyEntryActive());

    const result = while (true) {
        if (runtime.takeApiKeySaveResult(alloc)) |value| break value;
    };
    try std.testing.expect(result == .saved);
    try std.testing.expectEqual(@as(usize, 1), fixture.validate_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.store_calls);
    try std.testing.expect(!runtime.apiKeySaveInFlight());
    try std.testing.expect(runtime.api_key_save.thread == null);
}

test "auth runtime saves and reloads through its injected secret store" {
    const alloc = std.testing.allocator;
    var fixture: ApiKeySaveFixture = .{};
    var runtime = Runtime.init(
        fixture.validator(),
        oauth_transport.unavailable_provider,
        fixture.secretStore(),
    );
    defer runtime.deinit(alloc);

    try enterTestApiKey(&runtime, alloc, "host-port-test-value");
    try std.testing.expectEqual(ApiKeySaveStart.started, runtime.beginApiKeySave(alloc));

    const result = while (true) {
        if (runtime.takeApiKeySaveResult(alloc)) |value| break value;
    };

    try std.testing.expect(result == .saved);
    try std.testing.expectEqual(@as(usize, 1), fixture.validate_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.store_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.load_calls);
    try std.testing.expectEqual(credentials.Source.stored_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("loaded-key", runtime.apiKey().?);
}

test "an empty api key entry starts no save worker" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.openApiKeyPicker(alloc);
    try std.testing.expectEqual(ApiKeySaveStart.empty, runtime.beginApiKeySave(alloc));
    try std.testing.expect(!runtime.apiKeySaveInFlight());
}

test "a second key submitted mid-save is refused, not silently dropped" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var gate = std.atomic.Value(bool).init(false);
    var fixture: ApiKeySaveFixture = .{ .gate = &gate };
    const deps: ApiKeySaveDeps = .{
        .ctx = @ptrCast(&fixture),
        .validator = fixture.validator(),
        .store = ApiKeySaveFixture.store,
        .loader = ApiKeySaveFixture.load,
    };

    runtime.openApiKeyPicker(alloc);
    for ("vck_first") |byte| _ = try runtime.appendApiKeyByte(alloc, byte);
    try std.testing.expectEqual(ApiKeySaveStart.started, runtime.beginApiKeySaveWithDeps(alloc, deps));
    while (!runtime.apiKeySaveInFlight()) {}

    runtime.openApiKeyPicker(alloc);
    for ("vck_second") |byte| _ = try runtime.appendApiKeyByte(alloc, byte);
    try std.testing.expectEqual(ApiKeySaveStart.busy, runtime.beginApiKeySaveWithDeps(alloc, deps));
    // The refused key is wiped rather than leaked or left in the entry buffer.
    try std.testing.expectEqual(@as(usize, 0), runtime.api_key_input.capacity);
    try std.testing.expect(runtime.takeApiKeySaveResult(alloc) == null);

    gate.store(true, .seq_cst);
    const result = while (true) {
        if (runtime.takeApiKeySaveResult(alloc)) |value| break value;
    };
    try std.testing.expect(result == .saved);
    // Exactly one save ran: the second key never reached the store.
    try std.testing.expectEqual(@as(usize, 1), fixture.store_calls);
}

test "deinit joins a save worker that is still running" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    var fixture: ApiKeySaveFixture = .{};

    runtime.openApiKeyPicker(alloc);
    for ("vck_deinit_probe") |byte| _ = try runtime.appendApiKeyByte(alloc, byte);
    try std.testing.expectEqual(ApiKeySaveStart.started, runtime.beginApiKeySaveWithDeps(alloc, .{
        .ctx = @ptrCast(&fixture),
        .validator = fixture.validator(),
        .store = ApiKeySaveFixture.store,
        .loader = ApiKeySaveFixture.load,
    }));

    // Must not hang, must not leak the loaded credential the worker produced.
    runtime.deinit(alloc);
    try std.testing.expect(runtime.api_key_save.thread == null);
}

test "api key entry never reallocates while the key is in memory" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.openApiKeyPicker(alloc);
    try std.testing.expect(try runtime.appendApiKeyByte(alloc, 'a'));
    const base = runtime.api_key_input.items.ptr;
    try std.testing.expectEqual(max_api_key_entry_bytes, runtime.api_key_input.capacity);

    for (0..1200) |_| try std.testing.expect(try runtime.appendApiKeyByte(alloc, 'b'));

    try std.testing.expectEqual(base, runtime.api_key_input.items.ptr);
    try std.testing.expectEqual(max_api_key_entry_bytes, runtime.api_key_input.capacity);
}

test "api key stage zeroes its allocation on every exit path" {
    const sentinel = "FX_API_KEY_ZERO_SENTINEL";

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        try enterTestApiKey(&runtime, alloc, sentinel);

        try std.testing.expect(runtime.popPickerStage(alloc));
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var fixture: ApiKeySaveFixture = .{ .validation = .unavailable };
        try enterTestApiKey(&runtime, alloc, sentinel);

        var outcome = performApiKeySave(alloc, runtime.api_key_input.items, .{
            .ctx = @ptrCast(&fixture),
            .validator = fixture.validator(),
            .store = ApiKeySaveFixture.store,
            .loader = ApiKeySaveFixture.load,
        });
        defer outcome.deinit(alloc);
        runtime.exitApiKeyStage(alloc, .saved);
        const result: ApiKeySaveResult = switch (outcome) {
            .loaded => .{ .saved = true },
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
        };
        try std.testing.expect(result == .gateway_unavailable);
        try std.testing.expectEqual(@as(usize, 0), fixture.store_calls);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var fixture: ApiKeySaveFixture = .{};
        try enterTestApiKey(&runtime, alloc, sentinel);

        var outcome = performApiKeySave(alloc, runtime.api_key_input.items, .{
            .ctx = @ptrCast(&fixture),
            .validator = fixture.validator(),
            .store = ApiKeySaveFixture.store,
            .loader = ApiKeySaveFixture.load,
        });
        defer outcome.deinit(alloc);
        runtime.exitApiKeyStage(alloc, .saved);
        const result: ApiKeySaveResult = switch (outcome) {
            .loaded => .{ .saved = true },
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
        };
        try std.testing.expect(result == .saved);
        try std.testing.expectEqual(@as(usize, 1), fixture.store_calls);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var fixture: ApiKeySaveFixture = .{ .validation = .refused };
        try enterTestApiKey(&runtime, alloc, sentinel);

        var outcome = performApiKeySave(alloc, runtime.api_key_input.items, .{
            .ctx = @ptrCast(&fixture),
            .validator = fixture.validator(),
            .store = ApiKeySaveFixture.store,
            .loader = ApiKeySaveFixture.load,
        });
        defer outcome.deinit(alloc);
        runtime.exitApiKeyStage(alloc, .saved);
        const result: ApiKeySaveResult = switch (outcome) {
            .loaded => .{ .saved = true },
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
        };
        try std.testing.expect(result == .gateway_refused);
        try std.testing.expectEqual(@as(usize, 0), fixture.store_calls);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var fixture: ApiKeySaveFixture = .{ .fail_store = true };
        try enterTestApiKey(&runtime, alloc, sentinel);

        var outcome = performApiKeySave(alloc, runtime.api_key_input.items, .{
            .ctx = @ptrCast(&fixture),
            .validator = fixture.validator(),
            .store = ApiKeySaveFixture.store,
            .loader = ApiKeySaveFixture.load,
        });
        defer outcome.deinit(alloc);
        runtime.exitApiKeyStage(alloc, .saved);
        const result: ApiKeySaveResult = switch (outcome) {
            .loaded => .{ .saved = true },
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
        };
        try std.testing.expect(result == .store_failed);
        try std.testing.expectEqual(@as(usize, 1), fixture.store_calls);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var fixture: ApiKeySaveFixture = .{ .fail_load = true };
        try enterTestApiKey(&runtime, alloc, sentinel);

        var outcome = performApiKeySave(alloc, runtime.api_key_input.items, .{
            .ctx = @ptrCast(&fixture),
            .validator = fixture.validator(),
            .store = ApiKeySaveFixture.store,
            .loader = ApiKeySaveFixture.load,
        });
        defer outcome.deinit(alloc);
        runtime.exitApiKeyStage(alloc, .saved);
        const result: ApiKeySaveResult = switch (outcome) {
            .loaded => .{ .saved = true },
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
        };
        try std.testing.expect(result == .reload_failed);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        try enterTestApiKey(&runtime, alloc, sentinel);

        runtime.openSwitchCredentialPicker(alloc);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }

    {
        var backing: [16384]u8 = [_]u8{0xa5} ** 16384;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fixed.allocator();
        var runtime: Runtime = .{};
        try enterTestApiKey(&runtime, alloc, sentinel);

        runtime.deinit(alloc);
        try expectApiKeyAllocationCleared(&runtime, &backing, sentinel);
    }
}

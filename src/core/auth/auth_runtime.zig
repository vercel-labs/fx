const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const adapter_auth = @import("../gateway/adapter_auth.zig");
const adapter_registry = @import("../gateway/adapter_registry.zig");
const connection_registry = @import("../gateway/connection_registry.zig");
const host = @import("../hosts/host.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const max_entered_secret_bytes: usize = 8 * 1024;
const max_secret_mask_glyphs: usize = 32;
const max_team_query_bytes: usize = 256;

pub const FailureReason = enum {
    credential_refresh_failed,
    authentication_failed,
};

pub const FailureSnapshot = struct {
    source: adapter_auth.Source,
    reason: FailureReason,

    pub fn fromAuthenticationFailure(source: ?adapter_auth.Source) ?FailureSnapshot {
        return .{
            .source = source orelse return null,
            .reason = .authentication_failed,
        };
    }

    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{s} {s}", .{
            self.source.label,
            switch (self.reason) {
                .credential_refresh_failed => "credential refresh failed",
                .authentication_failed => "authentication failed",
            },
        });
        return out.toOwnedSlice();
    }

    pub fn renderJson(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(self.source.label, .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        try writer.writeByte('}');
    }
};

pub const AcquisitionAction = enum {
    login,
    setup,
    change_team,
    switch_credential,
    automatic,
};

pub const PickerStage = enum {
    root,
    sign_in,
    entered_secret,
    change_team,
    switch_credential,
};

pub const EnteredSecretSaveStart = enum {
    started,
    empty,
    invalid,
    busy,
    start_failed,
    unavailable,
};

pub const EnteredSecretSaveOutcome = union(enum) {
    saved: struct {
        changed: bool,
        persistence_indeterminate: bool = false,
    },
    saved_but_not_active: adapter_auth.DurableWriteState,
    validation_refused,
    validation_unavailable,
    store_failed: adapter_auth.DurableWriteState,
    reload_failed: adapter_auth.DurableWriteState,
    cancelled: adapter_auth.DurableWriteState,
    unavailable,
};

pub const EnteredSecretSaveResult = struct {
    presentation: adapter_auth.EnteredSecretPresentation,
    outcome: EnteredSecretSaveOutcome,

    pub fn deinit(self: *EnteredSecretSaveResult, alloc: Allocator) void {
        self.presentation.deinit(alloc);
        self.* = undefined;
    }
};

const EnteredSecretExitReason = enum {
    cancel,
    submitted,
    invalid_input,
    start_failed,
    screen_replacement,
    runtime_deinit,
};

pub const Choice = union(enum) {
    source: []const u8,
    action: AcquisitionAction,
    team: usize,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .source => |source_id| switch (other) {
                .source => |other_id| std.mem.eql(u8, source_id, other_id),
                .action, .team => false,
            },
            .action => |action| switch (other) {
                .action => |other_action| action == other_action,
                .source, .team => false,
            },
            .team => |team| switch (other) {
                .team => |other_team| team == other_team,
                .source, .action => false,
            },
        };
    }
};

pub const PickerView = struct {
    active: bool,
    sources: []const adapter_auth.CredentialSourceDescriptor = &.{},
    selected_choice: ?Choice,
    active_source: ?adapter_auth.Source,
    auth_service_label: []const u8 = "",
    entered_secret: ?adapter_auth.EnteredSecretPresentation = null,
    include_skip: bool,
    stage: PickerStage = .root,
    team_selection_available: bool = false,
    teams: []const adapter_auth.Team = &.{},
    current_team: ?[]const u8 = null,
    team_query: []const u8 = &.{},
    sign_in: adapter_auth.SignInSnapshot = .{},
    entered_secret_mask_count: usize = 0,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return if (self.active_source) |source_value| source_value.label else "missing";
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip) 2 else 4,
            .sign_in, .entered_secret => 0,
            .change_team => blk: {
                var count: usize = 0;
                for (self.teams) |team| {
                    if (teamMatchesQuery(team, self.team_query)) count += 1;
                }
                break :blk count;
            },
            .switch_credential => self.availableSourceCount() + 1,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) {
            .root => if (self.include_skip)
                switch (index) {
                    0 => .{ .action = .login },
                    1 => .{ .action = .setup },
                    else => null,
                }
            else switch (index) {
                0 => .{ .action = .login },
                1 => .{ .action = .setup },
                2 => .{ .action = .change_team },
                3 => .{ .action = .switch_credential },
                else => null,
            },
            .sign_in, .entered_secret => null,
            .change_team => blk: {
                var visible_index: usize = 0;
                for (self.teams, 0..) |team, team_index| {
                    if (!teamMatchesQuery(team, self.team_query)) continue;
                    if (visible_index == index) break :blk .{ .team = team_index };
                    visible_index += 1;
                }
                break :blk null;
            },
            .switch_credential => if (self.availableSourceAt(index)) |source_value|
                .{ .source = source_value.id }
            else if (index == self.availableSourceCount())
                .{ .action = .automatic }
            else
                null,
        };
    }

    pub fn choiceIsSelected(self: PickerView, choice: Choice) bool {
        return if (self.selected_choice) |selected| selected.eql(choice) else false;
    }

    pub fn selectedIndex(self: PickerView) usize {
        const selected = self.selected_choice orelse return 0;
        var index: usize = 0;
        while (self.choiceAt(index)) |choice| : (index += 1) if (choice.eql(selected)) return index;
        return 0;
    }

    /// Presentation only. Login callers format the fixed sentence around the
    /// service label; no control decision reads the returned text.
    pub fn choiceLabel(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .source => |source_id| if (self.sourceDescriptor(source_id)) |source_value| source_value.presentation_label else "",
            .action => |action| switch (action) {
                .login => self.auth_service_label,
                .setup => if (self.entered_secret) |value| value.secret_kind_label else "Credential",
                .change_team => "Change team",
                .switch_credential => "Switch credential",
                .automatic => "Automatic",
            },
            .team => |index| if (index < self.teams.len) self.teams[index].name else "",
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .source => |source_id| if (self.active_source) |active|
                if (std.mem.eql(u8, active.id, source_id)) "current" else "available"
            else
                "available",
            .action => |action| switch (action) {
                .login, .setup, .switch_credential => "",
                .automatic => "use normal precedence",
                .change_team => if (self.team_selection_available) "choose a team" else "sign in first",
            },
            .team => |index| if (self.teamIsCurrent(index)) "current" else "",
        };
    }

    pub fn choiceEnabled(self: PickerView, choice: Choice) bool {
        return switch (choice) {
            .action => |action| action != .change_team or self.team_selection_available,
            .source, .team => true,
        };
    }

    pub fn sourceDescriptor(self: PickerView, source_id: []const u8) ?*const adapter_auth.CredentialSourceDescriptor {
        for (self.sources) |*source_value| if (std.mem.eql(u8, source_value.id, source_id)) return source_value;
        return null;
    }

    fn availableSourceCount(self: PickerView) usize {
        var count: usize = 0;
        for (self.sources) |source_value| {
            if (source_value.available) count += 1;
        }
        return count;
    }

    fn availableSourceAt(self: PickerView, wanted_index: usize) ?*const adapter_auth.CredentialSourceDescriptor {
        var index: usize = 0;
        for (self.sources) |*source_value| {
            if (!source_value.available) continue;
            if (index == wanted_index) return source_value;
            index += 1;
        }
        return null;
    }

    fn teamIsCurrent(self: PickerView, index: usize) bool {
        if (index >= self.teams.len) return false;
        const current = self.current_team orelse return false;
        return std.mem.eql(u8, current, self.teams[index].id) or
            std.mem.eql(u8, current, self.teams[index].slug);
    }
};

fn teamMatchesQuery(team: adapter_auth.Team, query: []const u8) bool {
    return text_utils.containsIgnoreCase(team.name, query) or
        text_utils.containsIgnoreCase(team.slug, query);
}

pub const TenantStatus = enum {
    set,
    unset,
    unknown,

    pub fn label(self: TenantStatus) []const u8 {
        return @tagName(self);
    }
};

pub const MissingHelpSurface = enum { cli, interactive };

pub const StatusSnapshot = struct {
    active_source: ?adapter_auth.Source = null,
    team: ?[]const u8 = null,
    owned_team: ?[]u8 = null,
    missing_help: ?[]const u8 = null,
    owned_missing_help: ?[]u8 = null,
    connection_display_name: []const u8 = "",
    store_status: adapter_auth.StoreStatus = .not_attempted,
    failure: ?adapter_auth.FailureCategory = null,
    expired: bool = false,

    pub fn deinit(self: *StatusSnapshot, alloc: Allocator) void {
        if (self.owned_team) |team| alloc.free(team);
        if (self.owned_missing_help) |help| alloc.free(help);
        self.* = .{};
    }

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        if (self.active_source) |source_value| return source_value.label;
        if (self.failure) |failure| return if (failure == .configuration) "invalid_configuration" else @tagName(failure);
        return "missing";
    }

    pub fn refreshable(self: StatusSnapshot) bool {
        return if (self.active_source) |source_value| source_value.refreshable else false;
    }

    pub fn missingHelpAlloc(self: StatusSnapshot, alloc: Allocator, surface: MissingHelpSurface) !?[]u8 {
        if (self.active_source != null) return null;
        if (self.missing_help) |help| return try alloc.dupe(u8, help);
        if (self.failure != null) return null;
        return try std.fmt.allocPrint(
            alloc,
            "fx needs access to {s}. Run {s}login to sign in, {s}setup to use an API key, or set AI_GATEWAY_API_KEY.",
            .{
                self.connection_display_name,
                if (surface == .interactive) "/" else "fx ",
                if (surface == .interactive) "/" else "fx ",
            },
        );
    }

    pub fn formatDoctorDetail(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        if (try self.missingHelpAlloc(alloc, .cli)) |help| return help;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{s} is configured", .{self.activeSourceLabel()});
        if (self.expired) try out.writer.writeAll("; session expired");
        try out.writer.print("; refreshable={s}", .{if (self.refreshable()) "true" else "false"});
        if (self.team) |team| try out.writer.print("; team={s}", .{team});
        return out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshot(
    alloc: Allocator,
    auth: adapter_auth.Provider,
    profile: connection_registry.Profile,
    secret_store: host.SecretStore,
) !StatusSnapshot {
    var status = switch (try auth.status(alloc, profile, .{ .secret_store = secret_store })) {
        .loaded => |value| value,
        .failed => |failure| return .{
            .connection_display_name = profile.display_name,
            .failure = failure.category,
        },
        .cancelled => return error.Cancelled,
    };
    return takeAdapterStatus(&status, profile.display_name);
}

pub fn takeAdapterStatus(status: *adapter_auth.Status, connection_display_name: []const u8) StatusSnapshot {
    const owned_team = status.team;
    const owned_missing_help = status.missing_help;
    const result = StatusSnapshot{
        .active_source = status.source,
        .team = owned_team,
        .owned_team = owned_team,
        .missing_help = owned_missing_help,
        .owned_missing_help = owned_missing_help,
        .connection_display_name = connection_display_name,
        .store_status = status.store_status,
        .expired = status.expired,
    };
    status.team = null;
    status.missing_help = null;
    return result;
}

pub const View = struct {
    active_source: ?adapter_auth.Source,
    available_inactive_source_count: usize,
    selected_team: ?[]const u8,
    refreshable: bool,
    store_status: adapter_auth.StoreStatus,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return if (self.active_source) |source_value| source_value.label else "missing";
    }

    pub fn tenantStatus(self: View) TenantStatus {
        if (self.active_source == null) return .unknown;
        return if (self.selected_team == null) .unset else .set;
    }
};

pub const CredentialView = struct {
    secret_bytes: []const u8,
    tenant: ?[]const u8,
    source: adapter_auth.Source,
};

pub const TeamAdoption = enum {
    unchanged,
    adopted,
    stale,
};

const EnteredSecretWorker = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    submission: ?adapter_auth.EnteredSecretSubmission = null,
    completion: ?adapter_auth.EnteredSecretCompletion = null,
    provider: adapter_auth.Provider = .{ .kind = "unavailable" },
    cancel_flag: std.atomic.Value(bool) = .init(false),
    invalidated: bool = false,
    dispatch_gate: ?*EnteredSecretDispatchGate = null,

    fn start(
        self: *Self,
        alloc: Allocator,
        provider: adapter_auth.Provider,
        submission: adapter_auth.EnteredSecretSubmission,
    ) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = submission;
            rejected.deinit(alloc);
            return false;
        }
        self.cancel_flag.store(false, .seq_cst);
        self.invalidated = false;
        self.provider = provider;
        self.submission = submission;
        self.running = true;
        self.mutex.unlock(io_mod.getIo());

        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, alloc }) catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.running = false;
            var abandoned = self.submission.?;
            self.submission = null;
            self.mutex.unlock(io_mod.getIo());
            abandoned.deinit(alloc);
            return false;
        };
        return true;
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var submission = self.submission.?;
        self.submission = null;
        const provider = self.provider;
        const dispatch_gate = self.dispatch_gate;
        self.mutex.unlock(io_mod.getIo());

        if (dispatch_gate) |gate| gate.wait();
        var completion = provider.submitEnteredSecret(alloc, &submission);
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.completion) |*previous| previous.deinit(alloc);
        self.completion = completion;
        completion = undefined;
        self.running = false;
        self.mutex.unlock(io_mod.getIo());
    }

    fn invalidate(self: *Self) void {
        self.cancel_flag.store(true, .seq_cst);
        self.mutex.lockUncancelable(io_mod.getIo());
        self.invalidated = true;
        self.mutex.unlock(io_mod.getIo());
    }

    const Finished = struct {
        completion: adapter_auth.EnteredSecretCompletion,
        invalidated: bool,
    };

    fn take(self: *Self) ?Finished {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running) {
            self.mutex.unlock(io_mod.getIo());
            return null;
        }
        const thread = self.thread;
        self.thread = null;
        const completion = self.completion orelse {
            self.mutex.unlock(io_mod.getIo());
            return null;
        };
        self.completion = null;
        const invalidated = self.invalidated;
        self.invalidated = false;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
        return .{ .completion = completion, .invalidated = invalidated };
    }

    fn isRunning(self: *const Self) bool {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        return mutable.running;
    }

    fn deinit(self: *Self, alloc: Allocator) void {
        self.invalidate();
        const thread = self.thread;
        self.thread = null;
        if (thread) |handle| handle.join();
        if (self.submission) |*submission| submission.deinit(alloc);
        if (self.completion) |*completion| completion.deinit(alloc);
        self.submission = null;
        self.completion = null;
        self.running = false;
    }
};

const EnteredSecretDispatchGate = struct {
    reached: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    fn wait(self: *EnteredSecretDispatchGate) void {
        self.reached.store(true, .seq_cst);
        while (!self.released.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
    }
};

pub const Runtime = struct {
    const Self = @This();

    secret_store: host.SecretStore = host.unavailable_secret_store,
    adapter_registry: adapter_registry.AdapterRegistry = .{ .adapters = &.{} },
    connections: ?connection_registry.Runtime = null,
    selected_credential: ?adapter_auth.Credential = null,
    credential_connection_id: [connection_registry.max_connection_id_bytes]u8 = undefined,
    credential_connection_id_len: usize = 0,
    credential_refresh_failure_source: ?adapter_auth.Source = null,
    source_inventory: ?adapter_auth.CredentialSourceInventory = null,
    store_status: adapter_auth.StoreStatus = .not_attempted,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    team_selection: ?adapter_auth.TeamSelection = null,
    team_query: std.ArrayList(u8) = .empty,
    sign_in_session: adapter_auth.SignInSession = adapter_auth.unavailable_sign_in_session,
    sign_in_session_active: bool = false,
    sign_in_returns_to_root: bool = false,
    entered_secret_input: std.ArrayList(u8) = .empty,
    entered_secret_control_rejected: bool = false,
    entered_secret_returns_to_root: bool = false,
    entered_secret_worker: EnteredSecretWorker = .{},
    next_request_id: u64 = 1,
    live_request_id: ?u64 = null,

    pub fn init(
        secret_store: host.SecretStore,
        registry: adapter_registry.AdapterRegistry,
    ) Self {
        return .{ .secret_store = secret_store, .adapter_registry = registry };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.entered_secret_worker.deinit(alloc);
        self.clearSignInSession(alloc);
        self.exitEnteredSecretStage(alloc, .runtime_deinit);
        self.clearTeamSelection(alloc);
        self.team_query.deinit(alloc);
        self.clearCredential(alloc);
        self.clearSourceInventory(alloc);
        if (self.connections) |*connections| connections.deinit();
        self.* = .{};
    }

    pub fn adoptConnections(self: *Self, alloc: Allocator, connections: *connection_registry.Runtime) void {
        self.invalidateEnteredSecretWork(alloc);
        self.clearCredential(alloc);
        self.clearSourceInventory(alloc);
        if (self.connections) |*current| current.deinit();
        self.connections = connections.*;
        connections.* = undefined;
    }

    pub fn connectionList(self: *const Self) []const connection_registry.Profile {
        return if (self.connections) |*connections| connections.list() else &.{};
    }

    pub fn selectedConnectionProfile(self: *const Self) !connection_registry.Profile {
        const connections = if (self.connections) |*value| value else return error.ConnectionRegistryUnavailable;
        return connections.selectedProfile();
    }

    pub fn connectionProfile(self: *const Self, id: []const u8) !connection_registry.Profile {
        const connections = if (self.connections) |*value| value else return error.ConnectionRegistryUnavailable;
        return connections.profile(id);
    }

    fn authHost(self: *const Self) adapter_auth.AuthHost {
        return .{ .secret_store = self.secret_store };
    }

    pub fn connectionProfileForRoute(self: *const Self, id: []const u8) !connection_registry.Profile {
        var profile = try self.connectionProfile(id);
        if (!self.credentialMatchesSelectedConnection()) return profile;
        const selected = try self.selectedConnectionProfile();
        if (!std.mem.eql(u8, profile.id, selected.id)) return profile;
        const credential = self.selected_credential orelse return profile;
        profile.credential_ref = @constCast(credential.source.id);
        return profile;
    }

    pub fn resolveProfileCredential(
        self: *const Self,
        alloc: Allocator,
        profile: connection_registry.Profile,
        mode: adapter_auth.RefreshMode,
        current_source_id: ?[]const u8,
    ) !adapter_auth.Credential {
        return self.resolveProfileCredentialWithSourceResolution(alloc, profile, mode, current_source_id, .allow_fallback);
    }

    pub fn resolveExactProfileCredential(
        self: *const Self,
        alloc: Allocator,
        profile: connection_registry.Profile,
        mode: adapter_auth.RefreshMode,
        current_source_id: ?[]const u8,
    ) !adapter_auth.Credential {
        return self.resolveProfileCredentialWithSourceResolution(alloc, profile, mode, current_source_id, .exact);
    }

    pub fn resolveAdmittedProfileCredential(
        self: *const Self,
        alloc: Allocator,
        profile: connection_registry.Profile,
        mode: adapter_auth.RefreshMode,
        current_source_id: ?[]const u8,
    ) !adapter_auth.Credential {
        _ = try self.adapter_registry.resolveAuthForProfile(profile);
        return self.resolveExactProfileCredential(alloc, profile, mode, current_source_id) catch |err| switch (err) {
            error.MissingCredential => if (mode == .if_needed)
                (try self.duplicateValidCredentialForAdmittedProfile(alloc, profile)) orelse return err
            else
                return err,
            else => return err,
        };
    }

    fn resolveProfileCredentialWithSourceResolution(
        self: *const Self,
        alloc: Allocator,
        profile: connection_registry.Profile,
        mode: adapter_auth.RefreshMode,
        current_source_id: ?[]const u8,
        source_resolution: adapter_auth.SourceResolution,
    ) !adapter_auth.Credential {
        const auth = try self.adapter_registry.resolveAuthForProfile(profile);
        return switch (try auth.acquire(alloc, .{
            .profile = profile,
            .host = self.authHost(),
            .mode = mode,
            .source_resolution = source_resolution,
            .current_source_id = current_source_id,
        })) {
            .acquired => |credential| credential,
            .missing => error.MissingCredential,
            .failed => |failure| if (failure.category == .configuration)
                error.InvalidCredentialReference
            else
                error.CredentialAcquisitionFailed,
            .cancelled => error.Cancelled,
        };
    }

    fn duplicateValidCredentialForAdmittedProfile(
        self: *const Self,
        alloc: Allocator,
        profile: connection_registry.Profile,
    ) !?adapter_auth.Credential {
        if (self.credential_connection_id_len == 0 or
            !std.mem.eql(u8, self.credential_connection_id[0..self.credential_connection_id_len], profile.id)) return null;
        const credential = self.selected_credential orelse return null;
        if (!std.mem.eql(u8, profile.credential_ref, credential.source.id) or
            credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return try cloneCredential(alloc, credential);
    }

    pub fn selectConnection(self: *Self, alloc: Allocator, id: []const u8) !bool {
        const connections = if (self.connections) |*value| value else return error.ConnectionRegistryUnavailable;
        const changed = connections.select(id) catch |err| {
            if (std.mem.eql(u8, connections.selectedProfile().id, id)) {
                self.invalidateEnteredSecretWork(alloc);
                self.clearCredential(alloc);
                self.clearSourceInventory(alloc);
                connections.markSelectedDisconnected(.not_checked);
            }
            return err;
        };
        if (!changed) return false;
        self.invalidateEnteredSecretWork(alloc);
        self.clearCredential(alloc);
        self.clearSourceInventory(alloc);
        connections.markSelectedDisconnected(.not_checked);
        return true;
    }

    pub fn rememberSelectedConnectionModel(self: *Self, model: []const u8) !void {
        const connections = if (self.connections) |*value| value else return error.ConnectionRegistryUnavailable;
        try connections.rememberSelectedModel(model);
    }

    pub fn rememberSelectedCredentialReference(self: *Self, reference: []const u8) !void {
        const connections = if (self.connections) |*value| value else return error.ConnectionRegistryUnavailable;
        try connections.rememberSelectedCredentialReference(reference);
    }

    pub fn recordSelectedAuthenticationFailure(self: *Self, alloc: Allocator) void {
        const profile = self.selectedConnectionProfile() catch return;
        const auth = self.adapter_registry.resolveAuthForProfile(profile) catch return;
        const invalidation = auth.invalidate(profile, .{ .category = .denied }) catch return;
        if (invalidation.drop_credential) self.clearCredential(alloc);
        if (self.connections) |*connections| connections.markSelectedDisconnected(.authentication_failed);
    }

    pub fn usableCredential(self: *const Self) ?CredentialView {
        return self.usableCredentialAt(io_mod.milliTimestamp());
    }

    fn usableCredentialAt(self: *const Self, now_ms: i64) ?CredentialView {
        if (!self.credentialMatchesSelectedConnection()) return null;
        const credential = self.selected_credential orelse return null;
        if (credential.needsRefreshAt(now_ms)) return null;
        return .{
            .secret_bytes = credential.secret_bytes,
            .tenant = credential.tenantContext(),
            .source = credential.source,
        };
    }

    pub fn credentialSecret(self: *const Self) ?[]const u8 {
        return if (self.usableCredential()) |credential| credential.secret_bytes else null;
    }

    pub fn modelCatalogAccess(self: *const Self) adapter_auth.CatalogAccess {
        if (!self.credentialMatchesSelectedConnection()) return .{ .public_only = .{ .reason = .no_credential } };
        if (self.credential_refresh_failure_source) |source_value| return .{ .public_only = .{
            .reason = .refresh_failed,
            .source = source_value,
        } };
        const credential = self.selected_credential orelse return .{ .public_only = .{ .reason = .no_credential } };
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return .{ .public_only = .{
            .reason = .refresh_required,
            .source = credential.source,
        } };
        return credential.catalog_access;
    }

    pub fn recordCredentialRefreshFailure(self: *Self, source_value: adapter_auth.Source) void {
        const current = self.credentialSource() orelse return;
        std.debug.assert(std.mem.eql(u8, current.id, source_value.id));
        self.credential_refresh_failure_source = source_value;
    }

    pub fn credentialSource(self: *const Self) ?adapter_auth.Source {
        if (!self.credentialMatchesSelectedConnection()) return null;
        return if (self.selected_credential) |credential| credential.source else null;
    }

    pub fn tenantContext(self: *const Self) ?[]const u8 {
        return if (self.usableCredential()) |credential| credential.tenant else null;
    }

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        if (!self.credentialMatchesSelectedConnection()) return false;
        return if (self.selected_credential) |credential|
            credential.needsRefreshAt(io_mod.milliTimestamp())
        else
            false;
    }

    pub fn statusSnapshot(self: *const Self) StatusSnapshot {
        const profile = self.selectedConnectionProfile() catch return .{};
        if (!self.credentialMatchesSelectedConnection()) return self.disconnectedStatusSnapshot(profile.display_name);
        const credential = self.selected_credential orelse return self.disconnectedStatusSnapshot(profile.display_name);
        return .{
            .active_source = credential.source,
            .team = credential.tenantContext(),
            .connection_display_name = profile.display_name,
            .expired = credential.needsRefreshAt(io_mod.milliTimestamp()),
        };
    }

    fn disconnectedStatusSnapshot(self: *const Self, connection_display_name: []const u8) StatusSnapshot {
        const failure: ?adapter_auth.FailureCategory = if (self.connections) |*connections|
            switch (connections.selectedProfile().auth) {
                .disconnected => |reason| if (reason == .invalid_credential_reference) .configuration else null,
                .connected => null,
            }
        else
            null;
        return .{
            .connection_display_name = connection_display_name,
            .store_status = self.store_status,
            .failure = failure,
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var inactive_count: usize = 0;
        if (self.source_inventory) |inventory| for (inventory.sources) |source_value| {
            if (!source_value.available) continue;
            if (active_source) |active| if (std.mem.eql(u8, active.id, source_value.id)) continue;
            inactive_count += 1;
        };
        return .{
            .active_source = active_source,
            .available_inactive_source_count = inactive_count,
            .selected_team = self.selectedConnectionTeam(),
            .refreshable = if (active_source) |source_value| source_value.refreshable else false,
            .store_status = self.store_status,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(self: *Self, store_status: adapter_auth.StoreStatus, onboarding_skipped: bool) void {
        self.store_status = store_status;
        self.onboarding_skipped = onboarding_skipped;
    }

    pub fn skipOnboarding(self: *Self) void {
        self.onboarding_skipped = true;
    }

    pub fn refreshSourceInventory(self: *Self, alloc: Allocator) !void {
        const profile = try self.selectedConnectionProfile();
        const auth = try self.adapter_registry.resolveAuthForProfile(profile);
        var request = adapter_auth.SourceInventoryRequest{
            .profile = try adapter_auth.AuthProfileIdentity.init(alloc, profile),
            .host = self.authHost(),
            .current_source_id = if (self.credentialSource()) |source_value| source_value.id else null,
        };
        defer request.deinit(alloc);
        var outcome = try auth.sourceInventory(alloc, &request);
        defer outcome.deinit(alloc);
        switch (outcome) {
            .loaded => |*inventory| {
                const current = try self.selectedConnectionProfile();
                if (!inventory.origin_profile.eqlProfile(current)) return error.StaleAuthInventory;
                self.clearSourceInventory(alloc);
                self.source_inventory = inventory.*;
                outcome = .invalid_configuration;
            },
            .invalid_configuration => return error.InvalidAuthInventory,
            .missing_capability => return error.AuthInventoryUnavailable,
            .failed => |failure| return errorForAuthFailure(failure),
            .cancelled => return error.Cancelled,
        }
    }

    pub fn openPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, false);
    }

    pub fn openOnboardingPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, true);
    }

    fn openPickerWithSkip(self: *Self, alloc: Allocator, include_skip: bool) void {
        self.exitSignInStage(alloc);
        self.exitEnteredSecretStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = include_skip;
        self.picker_stage = .root;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn pickerView(self: *const Self) PickerView {
        const inventory = self.source_inventory;
        return .{
            .active = self.picker_active,
            .sources = if (inventory) |value| value.sources else &.{},
            .selected_choice = self.picker_selection,
            .active_source = self.credentialSource(),
            .auth_service_label = self.authServiceLabel(),
            .entered_secret = if (inventory) |value| enteredSecretPresentation(value.sources) else null,
            .include_skip = self.picker_include_skip,
            .stage = self.picker_stage,
            .team_selection_available = if (inventory) |value| teamSelectionAvailable(value.sources) else false,
            .teams = if (self.team_selection) |*selection| selection.teams else &.{},
            .current_team = if (self.team_selection) |*selection| selection.current_team else null,
            .team_query = self.team_query.items,
            .sign_in = if (self.sign_in_session_active) self.sign_in_session.snapshot() else .{},
            .entered_secret_mask_count = @min(self.entered_secret_input.items.len, max_secret_mask_glyphs),
        };
    }

    pub fn authServiceLabel(self: *const Self) []const u8 {
        if (self.source_inventory) |inventory| return inventory.auth_service.service_label;
        const profile = self.selectedConnectionProfile() catch return "";
        const auth = self.adapter_registry.resolveAuthForProfile(profile) catch return "";
        return auth.auth_service_label orelse "";
    }

    pub fn teamSelectionSourceId(self: *const Self) ?[]const u8 {
        const inventory = if (self.source_inventory) |value| value else return null;
        for (inventory.sources) |source_value| {
            if (source_value.supports_team_selection) return source_value.id;
        }
        return null;
    }

    pub fn sourcePresentationLabel(self: *const Self, source_id: []const u8) ?[]const u8 {
        return if (self.sourceDescriptor(source_id)) |descriptor| descriptor.presentation_label else null;
    }

    pub fn movePicker(self: *Self, delta: i32) bool {
        if (!self.picker_active or delta == 0) return false;
        const picker = self.pickerView();
        const count = picker.choiceCount();
        if (count < 2) return false;
        const current = picker.selectedIndex();
        const next = if (delta < 0)
            if (current == 0) count - 1 else current - 1
        else if (current + 1 == count)
            0
        else
            current + 1;
        self.picker_selection = picker.choiceAt(next);
        return true;
    }

    pub fn openTeamPicker(self: *Self, alloc: Allocator, selection: *adapter_auth.TeamSelection) void {
        self.exitSignInStage(alloc);
        self.exitEnteredSecretStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.team_selection = selection.take();
        self.picker_stage = .change_team;
        self.picker_selection = self.currentTeamChoice() orelse self.pickerView().choiceAt(0);
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
            const end = text_utils.utf8BackwardBoundary(self.team_query.items, self.team_query.items.len - 1);
            self.team_query.shrinkRetainingCapacity(end);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn openSwitchCredentialPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitEnteredSecretStage(alloc, .screen_replacement);
        self.picker_stage = .switch_credential;
        self.picker_selection = if (self.credentialSource()) |source_value|
            .{ .source = source_value.id }
        else
            self.pickerView().choiceAt(0);
    }

    pub fn openEnteredSecretPicker(self: *Self, alloc: Allocator) void {
        self.openEnteredSecretPickerWithParent(alloc, false);
    }

    pub fn openEnteredSecretPickerFromRoot(self: *Self, alloc: Allocator) void {
        self.openEnteredSecretPickerWithParent(alloc, true);
    }

    fn openEnteredSecretPickerWithParent(self: *Self, alloc: Allocator, returns_to_root: bool) void {
        self.exitSignInStage(alloc);
        self.exitEnteredSecretStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .entered_secret;
        self.picker_selection = null;
        self.entered_secret_returns_to_root = returns_to_root;
    }

    pub fn openSignInPicker(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, false);
    }

    pub fn openSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, true);
    }

    fn openSignInPickerWithParent(self: *Self, alloc: Allocator, returns_to_root: bool) !bool {
        self.exitSignInStage(alloc);
        const profile = try self.selectedConnectionProfile();
        const auth = try self.adapter_registry.resolveAuthForProfile(profile);
        switch (try auth.startSignIn(alloc, profile, self.authHost())) {
            .started => |session| {
                self.sign_in_session = session;
                self.sign_in_session_active = true;
            },
            .busy => return false,
            .cancelled => return error.Cancelled,
            .failed => |failure| return errorForAuthFailure(failure),
        }
        self.exitEnteredSecretStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .sign_in;
        self.picker_selection = null;
        self.sign_in_returns_to_root = returns_to_root;
        return true;
    }

    pub fn signInEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .sign_in;
    }

    pub fn signInBrowserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        if (!self.signInEntryActive()) return null;
        return self.sign_in_session.browserUrlAlloc(alloc);
    }

    pub fn pollSignInTransition(self: *Self, alloc: Allocator) !adapter_auth.SignInTransition {
        if (!self.sign_in_session_active) return .none;
        return self.sign_in_session.poll(alloc);
    }

    pub fn enteredSecretEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .entered_secret;
    }

    pub fn appendEnteredSecretByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.enteredSecretEntryActive()) return false;
        if (self.entered_secret_input.items.len >= max_entered_secret_bytes) return true;
        if (byte < 0x20 or byte == 0x7f) {
            self.entered_secret_control_rejected = true;
            return true;
        }
        try self.entered_secret_input.ensureTotalCapacityPrecise(alloc, max_entered_secret_bytes);
        self.entered_secret_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteEnteredSecretByte(self: *Self) bool {
        if (!self.enteredSecretEntryActive()) return false;
        if (self.entered_secret_input.items.len > 0) _ = self.entered_secret_input.pop();
        return true;
    }

    pub fn beginEnteredSecretSave(self: *Self, alloc: Allocator) EnteredSecretSaveStart {
        if (!self.enteredSecretEntryActive()) return .empty;
        if (self.entered_secret_control_rejected) {
            const returns_to_root = self.entered_secret_returns_to_root;
            self.exitEnteredSecretStage(alloc, .invalid_input);
            self.picker_active = returns_to_root;
            self.picker_stage = .root;
            self.picker_selection = if (returns_to_root) .{ .action = .setup } else null;
            return .invalid;
        }
        if (self.entered_secret_input.items.len == 0) return .empty;
        if (self.entered_secret_worker.isRunning()) {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .busy;
        }
        const inventory = if (self.source_inventory) |*value| value else {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .unavailable;
        };
        const current = self.selectedConnectionProfile() catch {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        };
        if (!inventory.origin_profile.eqlProfile(current)) {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        }
        const target = enteredSecretDescriptor(inventory.sources) orelse {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .unavailable;
        };
        const provider = self.adapter_registry.resolveAuthForProfile(current) catch {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        };

        const profile_identity = inventory.origin_profile.clone(alloc) catch {
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        };
        const source_id = alloc.dupe(u8, target.id) catch {
            var identity = profile_identity;
            identity.deinit(alloc);
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        };
        var presentation = target.entered_secret.?.clone(alloc) catch {
            var identity = profile_identity;
            identity.deinit(alloc);
            alloc.free(source_id);
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        };
        const secret_bytes = self.entered_secret_input.toOwnedSlice(alloc) catch {
            var identity = profile_identity;
            identity.deinit(alloc);
            alloc.free(source_id);
            presentation.deinit(alloc);
            self.exitEnteredSecretStage(alloc, .start_failed);
            return .start_failed;
        };
        self.entered_secret_input = .empty;
        const request_id = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        const returns_to_root = self.entered_secret_returns_to_root;
        self.exitEnteredSecretStage(alloc, .submitted);
        self.picker_active = returns_to_root;
        self.picker_stage = .root;
        self.picker_selection = if (returns_to_root) .{ .action = .setup } else null;

        const submission = adapter_auth.EnteredSecretSubmission{
            .request_id = request_id,
            .profile = profile_identity,
            .source_id = source_id,
            .presentation = presentation,
            .secret_value = .{ .bytes = secret_bytes },
            .host = self.authHost(),
            .cancel_flag = &self.entered_secret_worker.cancel_flag,
        };
        if (!self.entered_secret_worker.start(alloc, provider, submission)) return .start_failed;
        self.live_request_id = request_id;
        return .started;
    }

    pub fn enteredSecretSaveInFlight(self: *const Self) bool {
        return self.entered_secret_worker.isRunning();
    }

    pub fn takeEnteredSecretSaveResult(self: *Self, alloc: Allocator) ?EnteredSecretSaveResult {
        const finished = self.entered_secret_worker.take() orelse return null;
        var completion = finished.completion;
        const correlated = self.live_request_id != null and self.live_request_id.? == completion.request_id;
        self.live_request_id = null;
        const outcome: EnteredSecretSaveOutcome = outcome: {
            if (!correlated or finished.invalidated) {
                break :outcome .{ .cancelled = completion.outcome.durable_write };
            }

            const connections = if (self.connections) |*value| value else break :outcome .{ .saved_but_not_active = completion.outcome.durable_write };
            const current = connections.profile(completion.profile.connection_id) catch
                break :outcome .{ .saved_but_not_active = completion.outcome.durable_write };
            const selected = connections.selectedProfile();
            if (!completion.profile.eqlProfile(current) or
                !std.mem.eql(u8, selected.id, completion.profile.connection_id))
            {
                break :outcome .{ .saved_but_not_active = completion.outcome.durable_write };
            }

            break :outcome switch (completion.outcome.terminal) {
                .acquired => |*credential| blk: {
                    if (completion.outcome.durable_write != .replaced or
                        !std.mem.eql(u8, completion.source_id, credential.source.id))
                        break :blk .{ .saved_but_not_active = completion.outcome.durable_write };
                    const update = connections.compareAndRememberCredentialReference(.{
                        .connection_id = completion.profile.connection_id,
                        .adapter_id = completion.profile.adapter_id,
                        .credential_ref = completion.profile.credential_ref,
                        .endpoint = completion.profile.endpoint,
                        .protocol = completion.profile.protocol,
                    }, completion.source_id);
                    const persistence_indeterminate = switch (update) {
                        .unchanged_same_reference, .updated => false,
                        .updated_persistence_indeterminate => true,
                        .stale_origin, .failed_before_commit => break :blk .{ .saved_but_not_active = .replaced },
                    };
                    var owned = credential.*;
                    completion.outcome.terminal = .cancelled;
                    defer owned.deinit(alloc);
                    break :blk .{ .saved = .{
                        .changed = self.adoptCredential(alloc, &owned),
                        .persistence_indeterminate = persistence_indeterminate,
                    } };
                },
                .invalid => .validation_refused,
                .missing => .unavailable,
                .failed => |failure| switch (failure.stage) {
                    .validation => switch (failure.cause) {
                        .adapter => |adapter_failure| if (adapter_failure.category == .denied) .validation_refused else .validation_unavailable,
                        .allocation => .validation_unavailable,
                    },
                    .persistence => .{ .store_failed = completion.outcome.durable_write },
                    .reacquisition => .{ .reload_failed = completion.outcome.durable_write },
                },
                .cancelled => .{ .cancelled = completion.outcome.durable_write },
            };
        };
        const presentation = completion.presentation;
        completion.profile.deinit(alloc);
        alloc.free(completion.source_id);
        completion.outcome.deinit(alloc);
        completion = undefined;
        return .{ .presentation = presentation, .outcome = outcome };
    }

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        const stage = self.picker_stage;
        if (stage == .root) {
            if (self.live_request_id != null or self.entered_secret_worker.isRunning()) {
                self.entered_secret_worker.invalidate();
            }
            self.closePicker(alloc);
            return true;
        }
        if (stage == .sign_in) {
            const returns_to_root = self.sign_in_returns_to_root;
            self.clearSignInSession(alloc);
            self.sign_in_returns_to_root = false;
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
        }
        if (stage == .entered_secret) {
            const returns_to_root = self.entered_secret_returns_to_root;
            self.exitEnteredSecretStage(alloc, .cancel);
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
            .sign_in => .login,
            .entered_secret => .setup,
            .change_team => .change_team,
            .switch_credential => .switch_credential,
        } };
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitEnteredSecretStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active or self.picker_stage == .sign_in or self.picker_stage == .entered_secret) return null;
        const selected = self.picker_selection orelse return null;
        if (!self.pickerView().choiceEnabled(selected)) return null;
        switch (self.picker_stage) {
            .sign_in, .entered_secret => unreachable,
            .root => switch (selected) {
                .source => self.closePicker(alloc),
                .action => |action| switch (action) {
                    .change_team, .setup => {},
                    .switch_credential => {
                        self.openSwitchCredentialPicker(alloc);
                        return null;
                    },
                    .automatic => unreachable,
                    .login => self.closePicker(alloc),
                },
                .team => unreachable,
            },
            .change_team => {},
            .switch_credential => switch (selected) {
                .source => self.closePicker(alloc),
                .action => |action| std.debug.assert(action == .automatic),
                .team => unreachable,
            },
        }
        return selected;
    }

    pub fn teamSelection(self: *Self) ?*adapter_auth.TeamSelection {
        if (!self.teamPickerActive()) return null;
        return if (self.team_selection) |*selection| selection else null;
    }

    pub fn adoptCredential(self: *Self, alloc: Allocator, credential: *adapter_auth.Credential) bool {
        const changed = if (self.selected_credential) |selected|
            !std.mem.eql(u8, selected.source.id, credential.source.id) or
                !std.mem.eql(u8, selected.secret_bytes, credential.secret_bytes) or
                !optionalBytesEqual(selected.tenantContext(), credential.tenantContext()) or
                selected.refresh_after_ms != credential.refresh_after_ms
        else
            true;
        if (self.selected_credential) |*selected| selected.deinit(alloc);
        self.selected_credential = credential.*;
        self.credential_refresh_failure_source = null;
        self.bindCredentialToSelectedConnection();
        credential.secret_bytes = &.{};
        credential.tenant_id = null;
        credential.tenant_slug = null;
        return changed;
    }

    pub fn adoptSelectedTeam(
        self: *Self,
        alloc: Allocator,
        selected_team: *adapter_auth.SelectedTeam,
    ) TeamAdoption {
        if (!self.credentialMatchesSelectedConnection()) return .stale;
        const profile = self.selectedConnectionProfile() catch return .stale;
        const credential = if (self.selected_credential) |*selected| selected else return .stale;
        if (!selected_team.origin_profile.eqlProfileRoute(profile) or
            !std.mem.eql(u8, credential.source.id, selected_team.source.id) or
            credential.needsRefreshAt(io_mod.milliTimestamp())) return .stale;
        const catalog_source = credential.catalog_access.credentialSource() orelse return .stale;
        if (!std.mem.eql(u8, catalog_source.id, credential.source.id)) return .stale;
        const changed = !optionalBytesEqual(credential.tenant_id, selected_team.id) or
            !optionalBytesEqual(credential.tenant_slug, selected_team.slug) or
            credential.catalog_access != .authenticated;
        if (!changed) return .unchanged;
        if (credential.tenant_id) |team| alloc.free(team);
        if (credential.tenant_slug) |team| alloc.free(team);
        credential.tenant_id = selected_team.id;
        credential.tenant_slug = selected_team.slug;
        selected_team.id = &.{};
        selected_team.slug = &.{};
        credential.catalog_access = .{ .authenticated = .{
            .source = credential.source,
            .credential = credential.secret_bytes,
            .team_context = credential.tenantContext(),
        } };
        return .adopted;
    }

    pub fn selectedTeamMatchesSelectedProfile(
        self: *const Self,
        selected_team: adapter_auth.SelectedTeam,
    ) bool {
        const profile = self.selectedConnectionProfile() catch return false;
        return selected_team.origin_profile.eqlProfileRoute(profile);
    }

    pub fn selectSource(self: *Self, alloc: Allocator, source_id: []const u8) !?bool {
        const descriptor = self.sourceDescriptor(source_id) orelse return null;
        if (!descriptor.available) return null;
        var profile = try self.selectedConnectionProfile();
        profile.credential_ref = @constCast(source_id);
        var credential = self.resolveProfileCredentialWithSourceResolution(alloc, profile, .if_needed, source_id, .exact) catch |err| switch (err) {
            error.MissingCredential => return null,
            else => return err,
        };
        defer credential.deinit(alloc);
        if (!std.mem.eql(u8, credential.source.id, source_id)) return error.CredentialSourceMismatch;
        return self.adoptCredential(alloc, &credential);
    }

    pub fn refreshSelectedCredentialIfNeeded(self: *Self, alloc: Allocator) !bool {
        const source_value = self.credentialSource() orelse return false;
        if (!source_value.refreshable) return false;
        const profile = try self.selectedConnectionProfile();
        var credential = self.resolveProfileCredentialWithSourceResolution(alloc, profile, .if_needed, source_value.id, .exact) catch |err| switch (err) {
            error.MissingCredential => {
                if (self.credentialNeedsRefresh()) return error.CredentialRefreshUnavailable;
                return false;
            },
            else => return err,
        };
        defer credential.deinit(alloc);
        return self.adoptCredential(alloc, &credential);
    }

    pub fn logoutSelected(self: *Self, alloc: Allocator) !adapter_auth.LogoutOutcome {
        const profile = try self.selectedConnectionProfile();
        const auth = try self.adapter_registry.resolveAuthForProfile(profile);
        return auth.logout(alloc, profile, self.authHost());
    }

    pub fn loadSelectedTeams(self: *Self, alloc: Allocator) !adapter_auth.TeamsOutcome {
        const profile = try self.selectedConnectionProfile();
        const auth = try self.adapter_registry.resolveAuthForProfile(profile);
        return auth.loadTeams(alloc, profile, self.authHost());
    }

    pub fn reselectByPrecedence(self: *Self, alloc: Allocator) !bool {
        const previous_id = if (self.credentialSource()) |source_value| source_value.id else null;
        self.clearCredential(alloc);
        var profile = try self.selectedConnectionProfile();
        profile.credential_ref = @constCast("automatic");
        var credential = self.resolveProfileCredential(alloc, profile, .if_needed, null) catch |err| switch (err) {
            error.MissingCredential => {
                self.onboarding_skipped = false;
                return previous_id != null;
            },
            else => return err,
        };
        defer credential.deinit(alloc);
        _ = self.adoptCredential(alloc, &credential);
        try self.refreshSourceInventory(alloc);
        return !optionalBytesEqual(previous_id, if (self.credentialSource()) |source_value| source_value.id else null);
    }

    pub fn reconcileAfterLogout(
        self: *Self,
        alloc: Allocator,
        logged_out_source_id: []const u8,
    ) !bool {
        try connection_registry.validateCredentialReference(logged_out_source_id);
        const profile = try self.selectedConnectionProfile();
        const active_source_id = if (self.credentialSource()) |source_value| source_value.id else null;
        const decision = logoutReconciliationDecision(
            active_source_id,
            profile.credential_ref,
            logged_out_source_id,
        );

        if (decision.drop_live_credential) self.clearCredential(alloc);
        if (decision.clear_remembered_reference) {
            try self.rememberSelectedCredentialReference("automatic");
        }
        if (!decision.resolve_automatic) {
            try self.refreshSourceInventory(alloc);
            return false;
        }

        const automatic_profile = try self.selectedConnectionProfile();
        var credential = self.resolveProfileCredential(
            alloc,
            automatic_profile,
            .if_needed,
            null,
        ) catch |err| switch (err) {
            error.MissingCredential => {
                self.onboarding_skipped = false;
                try self.refreshSourceInventory(alloc);
                return true;
            },
            else => return err,
        };
        defer credential.deinit(alloc);
        _ = self.adoptCredential(alloc, &credential);
        try self.refreshSourceInventory(alloc);
        return true;
    }

    fn sourceDescriptor(self: *const Self, source_id: []const u8) ?*const adapter_auth.CredentialSourceDescriptor {
        const inventory = if (self.source_inventory) |*value| value else return null;
        for (inventory.sources) |*source_value| if (std.mem.eql(u8, source_value.id, source_id)) return source_value;
        return null;
    }

    fn bindCredentialToSelectedConnection(self: *Self) void {
        const connections = if (self.connections) |*value| value else {
            self.credential_connection_id_len = 0;
            return;
        };
        const id = connections.selectedProfile().id;
        std.debug.assert(id.len <= self.credential_connection_id.len);
        @memcpy(self.credential_connection_id[0..id.len], id);
        self.credential_connection_id_len = id.len;
        connections.markSelectedConnected();
    }

    fn credentialMatchesSelectedConnection(self: *const Self) bool {
        const connections = if (self.connections) |*value| value else return true;
        return self.credential_connection_id_len > 0 and std.mem.eql(
            u8,
            self.credential_connection_id[0..self.credential_connection_id_len],
            connections.selectedProfile().id,
        );
    }

    fn selectedConnectionTeam(self: *const Self) ?[]const u8 {
        if (!self.credentialMatchesSelectedConnection()) return null;
        return if (self.selected_credential) |credential| credential.tenantContext() else null;
    }

    fn clearCredential(self: *Self, alloc: Allocator) void {
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_refresh_failure_source = null;
        self.credential_connection_id_len = 0;
        if (self.connections) |*connections| connections.markSelectedDisconnected(.missing_credential);
    }

    fn clearSourceInventory(self: *Self, alloc: Allocator) void {
        if (self.source_inventory) |*inventory| inventory.deinit(alloc);
        self.source_inventory = null;
    }

    fn invalidateEnteredSecretWork(self: *Self, alloc: Allocator) void {
        if (self.live_request_id != null or self.entered_secret_worker.isRunning()) {
            self.entered_secret_worker.invalidate();
        }
        self.exitEnteredSecretStage(alloc, .screen_replacement);
    }

    fn currentTeamChoice(self: *const Self) ?Choice {
        const picker = self.pickerView();
        for (picker.teams, 0..) |_, index| if (picker.teamIsCurrent(index)) return .{ .team = index };
        return null;
    }

    fn clearTeamSelection(self: *Self, alloc: Allocator) void {
        if (self.team_selection) |*selection| selection.deinit(alloc);
        self.team_selection = null;
        self.team_query.clearRetainingCapacity();
    }

    fn clearSignInSession(self: *Self, alloc: Allocator) void {
        if (!self.sign_in_session_active) return;
        _ = self.sign_in_session.cancel(alloc);
        self.sign_in_session.deinit(alloc);
        self.sign_in_session_active = false;
    }

    fn exitSignInStage(self: *Self, alloc: Allocator) void {
        if (self.picker_stage != .sign_in) return;
        self.clearSignInSession(alloc);
        self.sign_in_returns_to_root = false;
    }

    fn resetTeamPickerSelection(self: *Self) void {
        self.picker_selection = if (self.team_query.items.len == 0)
            self.currentTeamChoice() orelse self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    fn exitEnteredSecretStage(self: *Self, alloc: Allocator, reason: EnteredSecretExitReason) void {
        const byte_count = self.entered_secret_input.items.len;
        if (self.entered_secret_input.capacity > 0) {
            const allocated = self.entered_secret_input.allocatedSlice();
            secret.zeroAndFree(alloc, allocated);
            self.entered_secret_input = .empty;
        }
        self.entered_secret_control_rejected = false;
        self.entered_secret_returns_to_root = false;
        if (byte_count > 0) debug_trace.logf(
            "auth",
            "entered secret cleared reason={s} bytes={d}",
            .{ @tagName(reason), byte_count },
        );
    }
};

test "entered secret input state rejects every control byte at every position" {
    var accepted = Runtime{};
    defer accepted.deinit(std.testing.allocator);
    accepted.picker_active = true;
    accepted.picker_stage = .entered_secret;
    for ([_]u8{ 0x20, 0x7e, 0x80, 0xff }) |byte| {
        try std.testing.expect(try accepted.appendEnteredSecretByte(std.testing.allocator, byte));
    }
    try std.testing.expect(!accepted.entered_secret_control_rejected);
    try std.testing.expectEqual(@as(usize, 4), accepted.entered_secret_input.items.len);

    for (0..0x21) |control_index| {
        const control: u8 = if (control_index == 0x20) 0x7f else @intCast(control_index);
        for (0..3) |position| {
            var rejected = Runtime{};
            defer rejected.deinit(std.testing.allocator);
            rejected.picker_active = true;
            rejected.picker_stage = .entered_secret;
            var candidate = [_]u8{ 'a', 'b', 'c' };
            candidate[position] = control;
            for (candidate) |byte| {
                try std.testing.expect(try rejected.appendEnteredSecretByte(std.testing.allocator, byte));
            }
            try std.testing.expectEqual(
                EnteredSecretSaveStart.invalid,
                rejected.beginEnteredSecretSave(std.testing.allocator),
            );
            try std.testing.expectEqual(@as(usize, 0), rejected.entered_secret_input.items.len);
        }
    }
}

fn enteredSecretDescriptor(sources: []const adapter_auth.CredentialSourceDescriptor) ?*const adapter_auth.CredentialSourceDescriptor {
    for (sources) |*source_value| if (source_value.entered_secret != null) return source_value;
    return null;
}

fn enteredSecretPresentation(sources: []const adapter_auth.CredentialSourceDescriptor) ?adapter_auth.EnteredSecretPresentation {
    return if (enteredSecretDescriptor(sources)) |source_value| source_value.entered_secret else null;
}

fn teamSelectionAvailable(sources: []const adapter_auth.CredentialSourceDescriptor) bool {
    for (sources) |source_value| if (source_value.supports_team_selection) return true;
    return false;
}

fn cloneCredential(alloc: Allocator, credential: adapter_auth.Credential) !adapter_auth.Credential {
    const owned_secret = try alloc.dupe(u8, credential.secret_bytes);
    errdefer secret.zeroAndFree(alloc, owned_secret);
    const tenant_id = if (credential.tenant_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (tenant_id) |value| alloc.free(value);
    const tenant_slug = if (credential.tenant_slug) |value| try alloc.dupe(u8, value) else null;
    const catalog_access: adapter_auth.CatalogAccess = switch (credential.catalog_access) {
        .public_only => |access| .{ .public_only = access },
        .authenticated => |access| .{ .authenticated = .{
            .source = access.source,
            .credential = owned_secret,
            .team_context = tenant_id orelse tenant_slug,
        } },
    };
    return .{
        .secret_bytes = owned_secret,
        .source = credential.source,
        .tenant_id = tenant_id,
        .tenant_slug = tenant_slug,
        .refresh_after_ms = credential.refresh_after_ms,
        .catalog_access = catalog_access,
    };
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

const LogoutReconciliationDecision = struct {
    drop_live_credential: bool,
    clear_remembered_reference: bool,
    resolve_automatic: bool,
};

fn logoutReconciliationDecision(
    active_source_id: ?[]const u8,
    remembered_reference: []const u8,
    logged_out_source_id: []const u8,
) LogoutReconciliationDecision {
    const live_matches = if (active_source_id) |active|
        std.mem.eql(u8, active, logged_out_source_id)
    else
        false;
    const remembered_matches = std.mem.eql(
        u8,
        remembered_reference,
        logged_out_source_id,
    );
    return .{
        .drop_live_credential = live_matches,
        .clear_remembered_reference = remembered_matches,
        .resolve_automatic = live_matches or (active_source_id == null and remembered_matches),
    };
}

fn errorForAuthFailure(failure: adapter_auth.Failure) anyerror {
    return switch (failure.category) {
        .configuration => error.AuthConfiguration,
        .denied => error.AuthDenied,
        .expired => error.AuthExpired,
        .missing_session => error.AuthSessionMissing,
        .no_teams => error.AuthTeamsMissing,
        .session_changed => error.AuthSessionChanged,
        .invalid_selection => error.AuthSelectionInvalid,
        .persistence => error.AuthPersistence,
        .unavailable => error.AuthUnavailable,
    };
}

const LogoutReconciliationProbe = struct {
    acquire_calls: usize = 0,
    inventory_calls: usize = 0,
    persistence_calls: usize = 0,

    fn acquire(
        raw: *const anyopaque,
        _: Allocator,
        _: adapter_auth.Request,
    ) Allocator.Error!adapter_auth.Acquisition {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.acquire_calls += 1;
        return .{ .missing = .not_found };
    }

    fn sourceInventory(
        raw: *const anyopaque,
        alloc: Allocator,
        request: *adapter_auth.SourceInventoryRequest,
    ) Allocator.Error!adapter_auth.SourceInventoryOutcome {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.inventory_calls += 1;
        const source_count: usize = if (request.current_source_id == null) 0 else 1;
        const sources = try alloc.alloc(adapter_auth.CredentialSourceDescriptor, source_count);
        errdefer alloc.free(sources);
        if (request.current_source_id) |source_id| {
            sources[0] = adapter_auth.CredentialSourceDescriptor.init(
                alloc,
                source_id,
                "API key",
                true,
                false,
                null,
                false,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .invalid_configuration,
            };
        }
        errdefer for (sources) |*source_value| source_value.deinit(alloc);
        var origin_profile = try request.profile.clone(alloc);
        errdefer origin_profile.deinit(alloc);
        var auth_service = adapter_auth.AuthServicePresentation.init(alloc, "Test auth") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .invalid_configuration,
        };
        errdefer auth_service.deinit(alloc);
        return .{ .loaded = .{
            .origin_profile = origin_profile,
            .auth_service = auth_service,
            .sources = sources,
        } };
    }

    fn persist(
        raw: ?*anyopaque,
        _: Allocator,
        snapshot: connection_registry.Snapshot,
    ) anyerror!connection_registry.PersistenceOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.persistence_calls += 1;
        try std.testing.expectEqualStrings("automatic", snapshot.profiles[0].credential_ref);
        return .committed;
    }
};

fn logoutTestAdapter(probe: *LogoutReconciliationProbe) agent_stream_provider.ProviderAdapter {
    const auth = adapter_auth.Provider{
        .kind = "test_auth",
        .context = probe,
        .acquire_fn = LogoutReconciliationProbe.acquire,
        .source_inventory_fn = LogoutReconciliationProbe.sourceInventory,
    };
    return .{
        .kind = "test_auth",
        .supported_protocol = "test_auth",
        .auth = auth,
        .stream_fn = agent_stream_provider.unavailable_adapter.stream_fn,
    };
}

fn adoptLogoutTestConnections(
    runtime: *Runtime,
    probe: *LogoutReconciliationProbe,
    credential_ref: []const u8,
) !void {
    var connections = try connection_registry.Runtime.init(std.testing.allocator, .{
        .id = "test",
        .display_name = "Test",
        .adapter_id = "test_auth",
        .protocol = "test_auth",
        .credential_ref = credential_ref,
        .remembered_model = "test/model",
    }, null, .{
        .context = probe,
        .write_fn = LogoutReconciliationProbe.persist,
    });
    runtime.adoptConnections(std.testing.allocator, &connections);
}

fn adoptLogoutTestCredential(
    runtime: *Runtime,
    source_value: adapter_auth.Source,
    secret_bytes: []const u8,
) !void {
    const owned_secret = try std.testing.allocator.dupe(u8, secret_bytes);
    var credential = adapter_auth.Credential{
        .secret_bytes = owned_secret,
        .source = source_value,
        .catalog_access = .{ .authenticated = .{
            .source = source_value,
            .credential = owned_secret,
            .team_context = null,
        } },
    };
    _ = runtime.adoptCredential(std.testing.allocator, &credential);
}

const EnteredSecretPausePoint = enum(u8) {
    none,
    store_publication,
    reacquisition,
};

const EnteredSecretIdentityProbe = struct {
    pause_at: EnteredSecretPausePoint = .none,
    cancellation_durable_write: adapter_auth.DurableWriteState = .replaced,
    secret_kind_label: []const u8 = "API key",
    verification_service_label: []const u8 = "AI Gateway",
    storage_destination_label: []const u8 = "the test store",
    reached: std.atomic.Value(u8) = .init(@intFromEnum(EnteredSecretPausePoint.none)),
    released: std.atomic.Value(bool) = .init(false),
    inventory_calls: std.atomic.Value(usize) = .init(0),
    acquire_calls: std.atomic.Value(usize) = .init(0),
    submit_calls: std.atomic.Value(usize) = .init(0),

    fn acquire(
        raw: *const anyopaque,
        _: Allocator,
        _: adapter_auth.Request,
    ) Allocator.Error!adapter_auth.Acquisition {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        _ = self.acquire_calls.fetchAdd(1, .seq_cst);
        return .{ .missing = .not_found };
    }

    fn sourceInventory(
        raw: *const anyopaque,
        alloc: Allocator,
        request: *adapter_auth.SourceInventoryRequest,
    ) Allocator.Error!adapter_auth.SourceInventoryOutcome {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        _ = self.inventory_calls.fetchAdd(1, .seq_cst);
        var presentation = adapter_auth.EnteredSecretPresentation.init(
            alloc,
            self.secret_kind_label,
            self.verification_service_label,
            self.storage_destination_label,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .invalid_configuration,
        };
        defer presentation.deinit(alloc);
        const sources = try alloc.alloc(adapter_auth.CredentialSourceDescriptor, 1);
        errdefer alloc.free(sources);
        sources[0] = adapter_auth.CredentialSourceDescriptor.init(
            alloc,
            "stored_key",
            "Stored API key",
            false,
            false,
            presentation,
            false,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .invalid_configuration,
        };
        errdefer sources[0].deinit(alloc);
        var origin_profile = try request.profile.clone(alloc);
        errdefer origin_profile.deinit(alloc);
        var auth_service = adapter_auth.AuthServicePresentation.init(alloc, "Test auth") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .invalid_configuration,
        };
        errdefer auth_service.deinit(alloc);
        return .{ .loaded = .{
            .origin_profile = origin_profile,
            .auth_service = auth_service,
            .sources = sources,
        } };
    }

    fn pause(self: *@This(), point: EnteredSecretPausePoint) void {
        if (self.pause_at != point) return;
        self.reached.store(@intFromEnum(point), .seq_cst);
        while (!self.released.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
    }

    fn submitEnteredSecret(
        raw: *const anyopaque,
        alloc: Allocator,
        submission: *adapter_auth.EnteredSecretSubmission,
    ) adapter_auth.EnteredSecretCompletion {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        _ = self.submit_calls.fetchAdd(1, .seq_cst);
        self.pause(.store_publication);
        if (submission.cancelled()) return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
            .durable_write = if (self.pause_at == .store_publication)
                self.cancellation_durable_write
            else
                .unchanged,
            .terminal = .cancelled,
        });
        self.pause(.reacquisition);
        if (submission.cancelled()) return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
            .durable_write = .replaced,
            .terminal = .cancelled,
        });
        const owned_secret = alloc.dupe(u8, "acquired-secret") catch
            return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
                .durable_write = .replaced,
                .terminal = .{ .failed = .{
                    .stage = .reacquisition,
                    .cause = .allocation,
                } },
            });
        const source_value = adapter_auth.Source{
            .id = "stored_key",
            .label = "Stored API key",
            .refreshable = false,
        };
        return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
            .durable_write = .replaced,
            .terminal = .{ .acquired = .{
                .secret_bytes = owned_secret,
                .source = source_value,
                .catalog_access = .{ .authenticated = .{
                    .source = source_value,
                    .credential = owned_secret,
                    .team_context = null,
                } },
            } },
        });
    }

    fn waitUntilReached(self: *@This(), point: EnteredSecretPausePoint) !void {
        for (0..5_000) |_| {
            if (self.reached.load(.seq_cst) == @intFromEnum(point)) return;
            io_mod.sleep(std.time.ns_per_ms);
        }
        return error.EnteredSecretPauseTimedOut;
    }
};

const EnteredSecretPersistenceProbe = struct {
    calls: usize = 0,

    fn write(
        raw: ?*anyopaque,
        _: Allocator,
        _: connection_registry.Snapshot,
    ) anyerror!connection_registry.PersistenceOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return .committed;
    }
};

const EnteredSecretIdentityHarness = struct {
    const Self = @This();

    selected: EnteredSecretIdentityProbe = .{},
    peer: EnteredSecretIdentityProbe = .{},
    persistence: EnteredSecretPersistenceProbe = .{},
    adapters: [2]agent_stream_provider.ProviderAdapter = undefined,
    runtime: Runtime = .{},

    fn init(self: *Self) !void {
        self.* = .{};
        self.adapters = .{
            enteredSecretTestAdapter("test_auth", &self.selected),
            enteredSecretTestAdapter("peer_auth", &self.peer),
        };
        self.runtime = Runtime.init(
            host.unavailable_secret_store,
            try adapter_registry.AdapterRegistry.init(&self.adapters),
        );
        var connections = try connection_registry.Runtime.init(std.testing.allocator, .{
            .id = "test",
            .display_name = "Test",
            .adapter_id = "test_auth",
            .protocol = "test_auth",
            .credential_ref = "automatic",
            .remembered_model = "test/model",
        }, null, .{
            .context = &self.persistence,
            .write_fn = EnteredSecretPersistenceProbe.write,
        });
        errdefer connections.deinit();
        try connections.add(.{
            .id = "peer",
            .display_name = "Peer",
            .adapter_id = "peer_auth",
            .protocol = "peer_auth",
            .credential_ref = "automatic",
            .remembered_model = "peer/model",
        });
        self.persistence.calls = 0;
        self.runtime.adoptConnections(std.testing.allocator, &connections);
    }

    fn deinit(self: *Self) void {
        self.runtime.deinit(std.testing.allocator);
    }

    fn prepare(self: *Self) !void {
        try self.prepareEnteredSecret(false);
    }

    fn prepareFromRoot(self: *Self) !void {
        try self.prepareEnteredSecret(true);
    }

    fn prepareEnteredSecret(self: *Self, from_root: bool) !void {
        try self.runtime.refreshSourceInventory(std.testing.allocator);
        if (from_root)
            self.runtime.openEnteredSecretPickerFromRoot(std.testing.allocator)
        else
            self.runtime.openEnteredSecretPicker(std.testing.allocator);
        for ("entered-secret") |byte| {
            try std.testing.expect(try self.runtime.appendEnteredSecretByte(std.testing.allocator, byte));
        }
    }

    fn start(self: *Self) !void {
        try std.testing.expectEqual(
            EnteredSecretSaveStart.started,
            self.runtime.beginEnteredSecretSave(std.testing.allocator),
        );
    }

    fn waitForCompletion(self: *Self) !void {
        for (0..5_000) |_| {
            if (!self.runtime.enteredSecretSaveInFlight()) return;
            io_mod.sleep(std.time.ns_per_ms);
        }
        return error.EnteredSecretCompletionTimedOut;
    }

    fn expectNoPeerEffects(self: *const Self) !void {
        try std.testing.expectEqual(@as(usize, 0), self.peer.inventory_calls.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 0), self.peer.acquire_calls.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 0), self.peer.submit_calls.load(.seq_cst));
    }
};

fn enteredSecretTestAdapter(
    kind: []const u8,
    probe: *EnteredSecretIdentityProbe,
) agent_stream_provider.ProviderAdapter {
    return .{
        .kind = kind,
        .supported_protocol = kind,
        .auth = .{
            .kind = kind,
            .auth_service_label = "Test auth",
            .context = probe,
            .acquire_fn = EnteredSecretIdentityProbe.acquire,
            .source_inventory_fn = EnteredSecretIdentityProbe.sourceInventory,
            .submit_entered_secret_fn = EnteredSecretIdentityProbe.submitEnteredSecret,
        },
        .stream_fn = agent_stream_provider.unavailable_adapter.stream_fn,
    };
}

fn expectEnteredSecretCancellation(result: EnteredSecretSaveResult, durable_write: adapter_auth.DurableWriteState) !void {
    var owned = result;
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("API key", owned.presentation.secret_kind_label);
    try std.testing.expectEqualStrings("AI Gateway", owned.presentation.verification_service_label);
    try std.testing.expectEqualStrings("the test store", owned.presentation.storage_destination_label);
    switch (owned.outcome) {
        .cancelled => |actual| try std.testing.expectEqual(durable_write, actual),
        else => return error.ExpectedEnteredSecretCancellation,
    }
}

fn expectEnteredSecretSaved(result: EnteredSecretSaveResult) !void {
    var owned = result;
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("API key", owned.presentation.secret_kind_label);
    try std.testing.expectEqualStrings("AI Gateway", owned.presentation.verification_service_label);
    try std.testing.expectEqualStrings("the test store", owned.presentation.storage_destination_label);
    switch (owned.outcome) {
        .saved => {},
        else => return error.ExpectedEnteredSecretSaved,
    }
}

test "entered secret identity rejects an auth replacement after inventory and before snapshot" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare();

    try harness.runtime.rememberSelectedCredentialReference("replacement");
    try std.testing.expectEqual(
        EnteredSecretSaveStart.start_failed,
        harness.runtime.beginEnteredSecretSave(std.testing.allocator),
    );

    try std.testing.expectEqual(@as(usize, 0), harness.selected.submit_calls.load(.seq_cst));
    try std.testing.expectEqualStrings("replacement", (try harness.runtime.selectedConnectionProfile()).credential_ref);
    try harness.expectNoPeerEffects();
}

test "entered secret identity cancels after snapshot and before adapter dispatch" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var gate = EnteredSecretDispatchGate{};
    harness.runtime.entered_secret_worker.dispatch_gate = &gate;
    try harness.prepare();
    try harness.start();
    for (0..5_000) |_| {
        if (gate.reached.load(.seq_cst)) break;
        io_mod.sleep(std.time.ns_per_ms);
    } else return error.EnteredSecretDispatchTimedOut;

    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "peer"));
    gate.released.store(true, .seq_cst);
    try harness.waitForCompletion();
    try expectEnteredSecretCancellation(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
        .unchanged,
    );

    try std.testing.expectEqual(@as(usize, 0), harness.selected.submit_calls.load(.seq_cst));
    try std.testing.expectEqualStrings("automatic", (try harness.runtime.connectionProfile("test")).credential_ref);
    try harness.expectNoPeerEffects();
}

test "closing setup root cancels an entered secret before adapter dispatch" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var gate = EnteredSecretDispatchGate{};
    defer gate.released.store(true, .seq_cst);
    harness.runtime.entered_secret_worker.dispatch_gate = &gate;
    try harness.prepareFromRoot();
    try harness.start();
    for (0..5_000) |_| {
        if (gate.reached.load(.seq_cst)) break;
        io_mod.sleep(std.time.ns_per_ms);
    } else return error.EnteredSecretDispatchTimedOut;

    try std.testing.expect(harness.runtime.popPickerStage(std.testing.allocator));
    gate.released.store(true, .seq_cst);
    try harness.waitForCompletion();
    try expectEnteredSecretCancellation(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
        .unchanged,
    );
    try std.testing.expectEqual(@as(usize, 0), harness.selected.submit_calls.load(.seq_cst));
    try harness.expectNoPeerEffects();
}

test "entered secret identity cancellation during publication preserves replacement" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.selected.pause_at = .store_publication;
    try harness.prepare();
    try harness.start();
    try harness.selected.waitUntilReached(.store_publication);

    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "peer"));
    harness.selected.released.store(true, .seq_cst);
    try harness.waitForCompletion();
    try expectEnteredSecretCancellation(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
        .replaced,
    );

    try std.testing.expectEqualStrings("automatic", (try harness.runtime.connectionProfile("test")).credential_ref);
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try harness.expectNoPeerEffects();
}

test "entered secret selection mutation preserves indeterminate result presentation" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.selected.pause_at = .store_publication;
    harness.selected.cancellation_durable_write = .indeterminate;
    try harness.prepare();
    try harness.start();
    try harness.selected.waitUntilReached(.store_publication);

    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "peer"));
    harness.selected.released.store(true, .seq_cst);
    try harness.waitForCompletion();
    try expectEnteredSecretCancellation(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
        .indeterminate,
    );

    try std.testing.expectEqualStrings("automatic", (try harness.runtime.connectionProfile("test")).credential_ref);
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try harness.expectNoPeerEffects();
}

test "entered secret inventory mutation preserves operation presentation" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.selected.pause_at = .store_publication;
    try harness.prepare();
    try harness.start();
    try harness.selected.waitUntilReached(.store_publication);

    harness.selected.secret_kind_label = "selected token";
    harness.selected.verification_service_label = "Selected API";
    harness.selected.storage_destination_label = "the selected vault";
    try harness.runtime.refreshSourceInventory(std.testing.allocator);
    harness.selected.released.store(true, .seq_cst);
    try harness.waitForCompletion();
    try expectEnteredSecretSaved(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
    );

    try std.testing.expectEqualStrings("stored_key", harness.runtime.credentialSource().?.id);
    try harness.expectNoPeerEffects();
}

test "entered secret identity cancellation during reacquisition preserves replacement" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.selected.pause_at = .reacquisition;
    try harness.prepare();
    try harness.start();
    try harness.selected.waitUntilReached(.reacquisition);

    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "peer"));
    harness.selected.released.store(true, .seq_cst);
    try harness.waitForCompletion();
    try expectEnteredSecretCancellation(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
        .replaced,
    );

    try std.testing.expectEqualStrings("automatic", (try harness.runtime.connectionProfile("test")).credential_ref);
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try harness.expectNoPeerEffects();
}

test "entered secret identity cannot revive after worker completion and selection round trip" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare();
    try harness.start();
    try harness.waitForCompletion();

    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "peer"));
    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "test"));
    try expectEnteredSecretCancellation(
        harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?,
        .replaced,
    );

    try std.testing.expectEqualStrings("automatic", (try harness.runtime.selectedConnectionProfile()).credential_ref);
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try harness.expectNoPeerEffects();
}

test "entered secret identity permits a model-only clone before collection" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare();
    try harness.start();
    try harness.waitForCompletion();

    try harness.runtime.rememberSelectedConnectionModel("test/next");
    try expectEnteredSecretSaved(harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?);

    const profile = try harness.runtime.selectedConnectionProfile();
    try std.testing.expectEqualStrings("test/next", profile.remembered_model);
    try std.testing.expectEqualStrings("stored_key", profile.credential_ref);
    try std.testing.expectEqualStrings("stored_key", harness.runtime.credentialSource().?.id);
    try harness.expectNoPeerEffects();
}

test "entered secret identity auth replacement after completion blocks adoption" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare();
    try harness.start();
    try harness.waitForCompletion();

    try harness.runtime.rememberSelectedCredentialReference("replacement");
    var result = harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("API key", result.presentation.secret_kind_label);
    try std.testing.expectEqualStrings("AI Gateway", result.presentation.verification_service_label);
    try std.testing.expectEqualStrings("the test store", result.presentation.storage_destination_label);
    switch (result.outcome) {
        .saved_but_not_active => |durable_write| try std.testing.expectEqual(
            adapter_auth.DurableWriteState.replaced,
            durable_write,
        ),
        else => return error.ExpectedSavedButNotActive,
    }

    try std.testing.expectEqualStrings("replacement", (try harness.runtime.selectedConnectionProfile()).credential_ref);
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try harness.expectNoPeerEffects();
}

test "entered secret identity clears an adopted credential after later selection" {
    var harness: EnteredSecretIdentityHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare();
    try harness.start();
    try harness.waitForCompletion();
    try expectEnteredSecretSaved(harness.runtime.takeEnteredSecretSaveResult(std.testing.allocator).?);
    try std.testing.expectEqualStrings("stored_key", harness.runtime.credentialSource().?.id);

    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "peer"));
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try std.testing.expect(try harness.runtime.selectConnection(std.testing.allocator, "test"));
    try std.testing.expect(harness.runtime.credentialSource() == null);
    try std.testing.expectEqualStrings("stored_key", (try harness.runtime.selectedConnectionProfile()).credential_ref);
    try harness.expectNoPeerEffects();
}

test "logout reconciliation invalidates a matching session without cached inventory" {
    var probe = LogoutReconciliationProbe{};
    const adapters = [_]agent_stream_provider.ProviderAdapter{logoutTestAdapter(&probe)};
    var runtime = Runtime.init(
        host.unavailable_secret_store,
        try adapter_registry.AdapterRegistry.init(&adapters),
    );
    defer runtime.deinit(std.testing.allocator);
    try adoptLogoutTestConnections(&runtime, &probe, "fx_login");
    try adoptLogoutTestCredential(
        &runtime,
        .{ .id = "fx_login", .label = "fx login", .refreshable = true },
        "session-secret",
    );
    try std.testing.expect(runtime.source_inventory == null);

    try std.testing.expect(try runtime.reconcileAfterLogout(std.testing.allocator, "fx_login"));

    try std.testing.expect(runtime.credentialSource() == null);
    try std.testing.expectEqualStrings("automatic", (try runtime.selectedConnectionProfile()).credential_ref);
    try std.testing.expectEqual(@as(usize, 1), probe.persistence_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.acquire_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.inventory_calls);
    try std.testing.expect(!runtime.onboarding_skipped);
}

test "logout reconciliation preserves an unrelated active credential" {
    var probe = LogoutReconciliationProbe{};
    const adapters = [_]agent_stream_provider.ProviderAdapter{logoutTestAdapter(&probe)};
    var runtime = Runtime.init(
        host.unavailable_secret_store,
        try adapter_registry.AdapterRegistry.init(&adapters),
    );
    defer runtime.deinit(std.testing.allocator);
    try adoptLogoutTestConnections(&runtime, &probe, "automatic");
    try adoptLogoutTestCredential(
        &runtime,
        .{ .id = "api_key", .label = "API key", .refreshable = false },
        "api-key-secret",
    );
    try std.testing.expect(runtime.source_inventory == null);

    try std.testing.expect(!try runtime.reconcileAfterLogout(std.testing.allocator, "fx_login"));

    try std.testing.expectEqualStrings("api_key", runtime.credentialSource().?.id);
    try std.testing.expectEqualStrings("api-key-secret", runtime.credentialSecret().?);
    try std.testing.expectEqual(@as(usize, 0), probe.persistence_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.acquire_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.inventory_calls);
}

test "logout reconciliation decision is exact and resolves precedence at most once" {
    const matching = logoutReconciliationDecision("session", "session", "session");
    try std.testing.expect(matching.drop_live_credential);
    try std.testing.expect(matching.clear_remembered_reference);
    try std.testing.expect(matching.resolve_automatic);

    const unrelated = logoutReconciliationDecision("api_key", "automatic", "session");
    try std.testing.expect(!unrelated.drop_live_credential);
    try std.testing.expect(!unrelated.clear_remembered_reference);
    try std.testing.expect(!unrelated.resolve_automatic);

    const unloaded = logoutReconciliationDecision(null, "session", "session");
    try std.testing.expect(!unloaded.drop_live_credential);
    try std.testing.expect(unloaded.clear_remembered_reference);
    try std.testing.expect(unloaded.resolve_automatic);
}

test "adopted team atomically rebuilds catalog access for the selected profile and source" {
    var probe = LogoutReconciliationProbe{};
    const adapters = [_]agent_stream_provider.ProviderAdapter{logoutTestAdapter(&probe)};
    var runtime = Runtime.init(
        host.unavailable_secret_store,
        try adapter_registry.AdapterRegistry.init(&adapters),
    );
    defer runtime.deinit(std.testing.allocator);
    try adoptLogoutTestConnections(&runtime, &probe, "fx_login");

    const source_value = adapter_auth.Source{
        .id = "fx_login",
        .label = "fx login",
        .refreshable = true,
    };
    const owned_secret = try std.testing.allocator.dupe(u8, "session-secret");
    var credential = adapter_auth.Credential{
        .secret_bytes = owned_secret,
        .source = source_value,
        .catalog_access = .{ .public_only = .{
            .reason = .tenant_required,
            .source = source_value,
        } },
    };
    _ = runtime.adoptCredential(std.testing.allocator, &credential);
    const profile_before = try runtime.selectedConnectionProfile();
    var selected_team = adapter_auth.SelectedTeam{
        .origin_profile = try adapter_auth.AuthProfileIdentity.init(
            std.testing.allocator,
            profile_before,
        ),
        .source = source_value,
        .id = try std.testing.allocator.dupe(u8, "team_123"),
        .slug = try std.testing.allocator.dupe(u8, "team-slug"),
    };
    defer selected_team.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        TeamAdoption.adopted,
        runtime.adoptSelectedTeam(std.testing.allocator, &selected_team),
    );
    const access = runtime.modelCatalogAccess();
    try std.testing.expect(access == .authenticated);
    try std.testing.expectEqualStrings(source_value.id, access.authenticated.source.id);
    try std.testing.expectEqualStrings("session-secret", access.authenticated.credential);
    try std.testing.expectEqualStrings("team_123", access.authenticated.team_context.?);
    try std.testing.expectEqualStrings("team_123", runtime.tenantContext().?);
    const profile_after = try runtime.selectedConnectionProfile();
    try std.testing.expectEqualStrings(profile_before.id, profile_after.id);
    try std.testing.expectEqualStrings(profile_before.adapter_id, profile_after.adapter_id);
    try std.testing.expectEqualStrings(profile_before.credential_ref, profile_after.credential_ref);
    try std.testing.expect(optionalBytesEqual(profile_before.endpoint, profile_after.endpoint));
    try std.testing.expect(optionalBytesEqual(profile_before.protocol, profile_after.protocol));
}

test "stale team selection publishes neither tenant nor catalog state" {
    var probe = LogoutReconciliationProbe{};
    const adapters = [_]agent_stream_provider.ProviderAdapter{logoutTestAdapter(&probe)};
    var runtime = Runtime.init(
        host.unavailable_secret_store,
        try adapter_registry.AdapterRegistry.init(&adapters),
    );
    defer runtime.deinit(std.testing.allocator);
    try adoptLogoutTestConnections(&runtime, &probe, "fx_login");
    const source_value = adapter_auth.Source{
        .id = "fx_login",
        .label = "fx login",
        .refreshable = true,
    };
    const owned_secret = try std.testing.allocator.dupe(u8, "session-secret");
    var credential = adapter_auth.Credential{
        .secret_bytes = owned_secret,
        .source = source_value,
        .catalog_access = .{ .public_only = .{
            .reason = .tenant_required,
            .source = source_value,
        } },
    };
    _ = runtime.adoptCredential(std.testing.allocator, &credential);
    var stale_profile = try runtime.selectedConnectionProfile();
    stale_profile.id = @constCast("other-connection");
    var selected_team = adapter_auth.SelectedTeam{
        .origin_profile = try adapter_auth.AuthProfileIdentity.init(
            std.testing.allocator,
            stale_profile,
        ),
        .source = source_value,
        .id = try std.testing.allocator.dupe(u8, "team_123"),
        .slug = try std.testing.allocator.dupe(u8, "team-slug"),
    };
    defer selected_team.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        TeamAdoption.stale,
        runtime.adoptSelectedTeam(std.testing.allocator, &selected_team),
    );
    try std.testing.expect(runtime.tenantContext() == null);
    try std.testing.expect(runtime.modelCatalogAccess() == .public_only);
    try std.testing.expectEqual(
        adapter_auth.CatalogPublicOnlyReason.tenant_required,
        runtime.modelCatalogAccess().public_only.reason,
    );
    try std.testing.expectEqualStrings("team_123", selected_team.id);
    try std.testing.expectEqualStrings("team-slug", selected_team.slug);
}

test "picker source identity is opaque and labels are presentation only" {
    const sources = [_]adapter_auth.CredentialSourceDescriptor{
        .{
            .id = @constCast("peer.session"),
            .presentation_label = @constCast("Peer session"),
            .available = true,
            .refreshable = true,
            .supports_team_selection = true,
        },
        .{
            .id = @constCast("peer.secret"),
            .presentation_label = @constCast("Stored peer secret"),
            .available = true,
            .refreshable = false,
            .supports_team_selection = false,
        },
    };
    const view = PickerView{
        .active = true,
        .sources = &sources,
        .selected_choice = .{ .source = "peer.secret" },
        .active_source = .{ .id = "peer.session", .label = "Peer session", .refreshable = true },
        .include_skip = false,
        .stage = .switch_credential,
    };
    try std.testing.expectEqual(@as(usize, 3), view.choiceCount());
    try std.testing.expect((Choice{ .source = "peer.secret" }).eql(view.choiceAt(1).?));
    try std.testing.expectEqualStrings("Stored peer secret", view.choiceLabel(view.choiceAt(1).?));
    try std.testing.expectEqualStrings("current", view.choiceDescription(view.choiceAt(0).?));
}

test "failure rendering contains normalized source facts and no secret" {
    const failure = FailureSnapshot{
        .source = .{ .id = "peer", .label = "Peer login", .refreshable = true },
        .reason = .authentication_failed,
    };
    const text = try failure.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Peer login authentication failed", text);
}

test "status help is driven by connection presentation" {
    const status = StatusSnapshot{ .connection_display_name = "Example Cloud Gateway" };
    const text = (try status.missingHelpAlloc(std.testing.allocator, .interactive)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "fx needs access to Example Cloud Gateway. Run /login to sign in, /setup to use an API key, or set AI_GATEWAY_API_KEY.",
        text,
    );
}

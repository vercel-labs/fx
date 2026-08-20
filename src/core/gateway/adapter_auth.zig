const std = @import("std");
const connection_registry = @import("connection_registry.zig");
const host_contract = @import("../hosts/host.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const RefreshMode = enum {
    stored,
    if_needed,
    force,
};

pub const SourceResolution = enum {
    allow_fallback,
    exact,
};

pub const StoreStatus = enum {
    not_attempted,
    not_found,
    unavailable,
};

pub const FailureCategory = enum {
    configuration,
    denied,
    expired,
    unavailable,
    missing_session,
    no_teams,
    session_changed,
    invalid_selection,
    persistence,
    cancelled,
};

pub const Failure = struct {
    category: FailureCategory,
};

pub const Source = struct {
    id: []const u8,
    label: []const u8,
    refreshable: bool,
};

pub const CatalogPublicOnlyReason = enum {
    no_credential,
    tenant_required,
    refresh_required,
    refresh_failed,
    credential_rejected,
};

pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnlyReason,
    authenticated,
};

/// One adapter-produced credential. The auth runtime owns an acquired value and
/// must call `deinit` on replacement and every terminal path.
pub const Credential = struct {
    secret_bytes: []u8,
    source: Source,
    tenant_id: ?[]u8 = null,
    tenant_slug: ?[]u8 = null,
    refresh_after_ms: ?i64 = null,
    catalog_access: CatalogAccess,

    pub fn deinit(self: *Credential, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.secret_bytes);
        if (self.tenant_id) |value| alloc.free(value);
        if (self.tenant_slug) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Acquisition = union(enum) {
    acquired: Credential,
    missing: StoreStatus,
    failed: Failure,
    cancelled,
};

pub const AuthHost = struct {
    secret_store: host_contract.SecretStore,
    url_opener: host_contract.UrlOpener = host_contract.unavailable_url_opener,
};

pub const Request = struct {
    profile: connection_registry.Profile,
    host: AuthHost,
    mode: RefreshMode,
    source_resolution: SourceResolution,
    current_source_id: ?[]const u8 = null,
    cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancelled(self: Request) bool {
        return if (self.cancel_flag) |flag| flag.load(.seq_cst) else false;
    }
};

pub const OperationOutcome = union(enum) {
    succeeded,
    failed: Failure,
    cancelled,
};

pub const LogoutResult = struct {
    session_deleted: bool = false,
    local_durability_failed: bool = false,
    remote_revocation_failed: bool = false,
};

pub const LogoutOutcome = union(enum) {
    completed: LogoutResult,
    failed: Failure,
    cancelled,
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

pub const Team = struct {
    id: []const u8,
    slug: []const u8,
    name: []const u8,
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
    context: ?*anyopaque = null,
    teams: []const Team = &.{},
    current_team: ?[]const u8 = null,
    select_fn: *const fn (?*anyopaque, Allocator, usize) Allocator.Error!SelectOutcome,
    deinit_fn: *const fn (?*anyopaque, Allocator) void,

    pub fn deinit(self: *TeamSelection, alloc: Allocator) void {
        self.deinit_fn(self.context, alloc);
        self.* = unavailable_team_selection;
    }

    pub fn take(self: *TeamSelection) TeamSelection {
        const result = self.*;
        self.* = unavailable_team_selection;
        return result;
    }

    pub fn select(self: TeamSelection, alloc: Allocator, index: usize) Allocator.Error!SelectOutcome {
        if (index >= self.teams.len) return .{ .failed = .{ .category = .invalid_selection } };
        return self.select_fn(self.context, alloc, index);
    }
};

pub const SelectOutcome = union(enum) {
    selected: SelectedTeam,
    failed: Failure,
};

fn unavailableTeamSelect(_: ?*anyopaque, _: Allocator, _: usize) Allocator.Error!SelectOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableTeamDeinit(_: ?*anyopaque, _: Allocator) void {}

pub const unavailable_team_selection = TeamSelection{
    .select_fn = unavailableTeamSelect,
    .deinit_fn = unavailableTeamDeinit,
};

pub const SignInTransition = union(enum) {
    none,
    succeeded: TeamSelection,
    failed: Failure,
    cancelled,
};

pub const SignInSession = struct {
    context: ?*anyopaque = null,
    snapshot_fn: *const fn (?*anyopaque) SignInSnapshot,
    browser_url_fn: *const fn (?*anyopaque, Allocator) Allocator.Error!?[]u8,
    poll_fn: *const fn (?*anyopaque, Allocator) Allocator.Error!SignInTransition,
    cancel_fn: *const fn (?*anyopaque, Allocator) bool,
    deinit_fn: *const fn (?*anyopaque, Allocator) void,

    pub fn snapshot(self: SignInSession) SignInSnapshot {
        return self.snapshot_fn(self.context);
    }

    pub fn browserUrlAlloc(self: SignInSession, alloc: Allocator) Allocator.Error!?[]u8 {
        return self.browser_url_fn(self.context, alloc);
    }

    pub fn poll(self: SignInSession, alloc: Allocator) Allocator.Error!SignInTransition {
        return self.poll_fn(self.context, alloc);
    }

    pub fn cancel(self: SignInSession, alloc: Allocator) bool {
        return self.cancel_fn(self.context, alloc);
    }

    pub fn deinit(self: *SignInSession, alloc: Allocator) void {
        self.deinit_fn(self.context, alloc);
        self.* = unavailable_sign_in_session;
    }
};

fn unavailableSignInSnapshot(_: ?*anyopaque) SignInSnapshot {
    return .{};
}

fn unavailableSignInUrl(_: ?*anyopaque, _: Allocator) Allocator.Error!?[]u8 {
    return null;
}

fn unavailableSignInPoll(_: ?*anyopaque, _: Allocator) Allocator.Error!SignInTransition {
    return .none;
}

fn unavailableSignInCancel(_: ?*anyopaque, _: Allocator) bool {
    return false;
}

fn unavailableSignInDeinit(_: ?*anyopaque, _: Allocator) void {}

pub const unavailable_sign_in_session = SignInSession{
    .snapshot_fn = unavailableSignInSnapshot,
    .browser_url_fn = unavailableSignInUrl,
    .poll_fn = unavailableSignInPoll,
    .cancel_fn = unavailableSignInCancel,
    .deinit_fn = unavailableSignInDeinit,
};

pub const StartSignInOutcome = union(enum) {
    started: SignInSession,
    busy,
    failed: Failure,
    cancelled,
};

pub const Status = struct {
    source: ?Source = null,
    team: ?[]u8 = null,
    store_status: StoreStatus = .not_attempted,
    expired: bool = false,

    pub fn deinit(self: *Status, alloc: Allocator) void {
        if (self.team) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const StatusOutcome = union(enum) {
    loaded: Status,
    failed: Failure,
    cancelled,
};

pub const Invalidation = struct {
    drop_credential: bool,
};

const AcquireFn = *const fn (*const anyopaque, Allocator, Request) Allocator.Error!Acquisition;
const LoginFn = *const fn (*const anyopaque, Allocator, connection_registry.Profile, AuthHost) Allocator.Error!OperationOutcome;
const LogoutFn = *const fn (*const anyopaque, Allocator, connection_registry.Profile, AuthHost) Allocator.Error!LogoutOutcome;
const TeamsFn = *const fn (*const anyopaque, Allocator, connection_registry.Profile, AuthHost) Allocator.Error!OperationOutcome;
const StartSignInFn = *const fn (*const anyopaque, Allocator, connection_registry.Profile, AuthHost) Allocator.Error!StartSignInOutcome;
pub const TeamsOutcome = union(enum) {
    loaded: TeamSelection,
    failed: Failure,
    cancelled,
};
const LoadTeamsFn = *const fn (*const anyopaque, Allocator, connection_registry.Profile, AuthHost) Allocator.Error!TeamsOutcome;
const InvalidateFn = *const fn (*const anyopaque, connection_registry.Profile, Failure) Invalidation;
const StatusFn = *const fn (*const anyopaque, Allocator, connection_registry.Profile, AuthHost) Allocator.Error!StatusOutcome;

const unavailable_context: u8 = 0;

fn unavailableAcquire(_: *const anyopaque, _: Allocator, _: Request) Allocator.Error!Acquisition {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableLogin(_: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!OperationOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableLogout(_: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!LogoutOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableTeams(_: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!OperationOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableStartSignIn(_: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!StartSignInOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableLoadTeams(_: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!TeamsOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

fn unavailableInvalidate(_: *const anyopaque, _: connection_registry.Profile, _: Failure) Invalidation {
    return .{ .drop_credential = false };
}

fn unavailableStatus(_: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!StatusOutcome {
    return .{ .failed = .{ .category = .unavailable } };
}

pub const Provider = struct {
    kind: []const u8,
    context: *const anyopaque = &unavailable_context,
    acquire_fn: AcquireFn = unavailableAcquire,
    login_fn: LoginFn = unavailableLogin,
    logout_fn: LogoutFn = unavailableLogout,
    teams_fn: TeamsFn = unavailableTeams,
    start_sign_in_fn: StartSignInFn = unavailableStartSignIn,
    load_teams_fn: LoadTeamsFn = unavailableLoadTeams,
    invalidate_fn: InvalidateFn = unavailableInvalidate,
    status_fn: StatusFn = unavailableStatus,

    pub fn acquire(self: Provider, alloc: Allocator, request: Request) (Allocator.Error || error{AdapterMismatch})!Acquisition {
        try self.validateProfile(request.profile);
        if (request.cancelled()) return .cancelled;
        var acquisition = try self.acquire_fn(self.context, alloc, request);
        if (!request.cancelled()) return acquisition;
        switch (acquisition) {
            .acquired => |*credential| credential.deinit(alloc),
            .missing, .failed, .cancelled => {},
        }
        return .cancelled;
    }

    pub fn login(self: Provider, alloc: Allocator, profile: connection_registry.Profile, auth_host: AuthHost) (Allocator.Error || error{AdapterMismatch})!OperationOutcome {
        try self.validateProfile(profile);
        return self.login_fn(self.context, alloc, profile, auth_host);
    }

    pub fn logout(self: Provider, alloc: Allocator, profile: connection_registry.Profile, auth_host: AuthHost) (Allocator.Error || error{AdapterMismatch})!LogoutOutcome {
        try self.validateProfile(profile);
        return self.logout_fn(self.context, alloc, profile, auth_host);
    }

    pub fn teams(self: Provider, alloc: Allocator, profile: connection_registry.Profile, auth_host: AuthHost) (Allocator.Error || error{AdapterMismatch})!OperationOutcome {
        try self.validateProfile(profile);
        return self.teams_fn(self.context, alloc, profile, auth_host);
    }

    pub fn startSignIn(self: Provider, alloc: Allocator, profile: connection_registry.Profile, auth_host: AuthHost) (Allocator.Error || error{AdapterMismatch})!StartSignInOutcome {
        try self.validateProfile(profile);
        return self.start_sign_in_fn(self.context, alloc, profile, auth_host);
    }

    pub fn loadTeams(self: Provider, alloc: Allocator, profile: connection_registry.Profile, auth_host: AuthHost) (Allocator.Error || error{AdapterMismatch})!TeamsOutcome {
        try self.validateProfile(profile);
        return self.load_teams_fn(self.context, alloc, profile, auth_host);
    }

    pub fn invalidate(self: Provider, profile: connection_registry.Profile, failure: Failure) error{AdapterMismatch}!Invalidation {
        try self.validateProfile(profile);
        return self.invalidate_fn(self.context, profile, failure);
    }

    pub fn status(self: Provider, alloc: Allocator, profile: connection_registry.Profile, auth_host: AuthHost) (Allocator.Error || error{AdapterMismatch})!StatusOutcome {
        try self.validateProfile(profile);
        return self.status_fn(self.context, alloc, profile, auth_host);
    }

    fn validateProfile(self: Provider, profile: connection_registry.Profile) error{AdapterMismatch}!void {
        if (!std.mem.eql(u8, profile.adapter_id, self.kind)) return error.AdapterMismatch;
    }
};

/// Pure retry state owned by one admitted workload. It permits no more than one
/// forced refresh after an unauthorized response.
pub const UnauthorizedRefresh = struct {
    force_used: bool = false,

    pub fn next(self: *UnauthorizedRefresh, refreshable: bool) ?RefreshMode {
        if (!refreshable or self.force_used) return null;
        self.force_used = true;
        return .force;
    }
};

test "unauthorized refresh permits exactly one forced attempt" {
    var refresh: UnauthorizedRefresh = .{};
    try std.testing.expectEqual(RefreshMode.force, refresh.next(true).?);
    try std.testing.expect(refresh.next(true) == null);

    var fixed: UnauthorizedRefresh = .{};
    try std.testing.expect(fixed.next(false) == null);
    try std.testing.expect(fixed.next(true) != null);
}

test "credential destruction zeroes secret bytes" {
    var backing: [32]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const alloc = fixed.allocator();
    var credential = Credential{
        .secret_bytes = try alloc.dupe(u8, "adapter-secret"),
        .source = .{ .id = "test", .label = "test", .refreshable = false },
        .catalog_access = .authenticated,
    };
    credential.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, &backing, "adapter-secret") == null);
}

test "status serialization is redacted" {
    const alloc = std.testing.allocator;
    const status = Status{
        .source = .{ .id = "opaque", .label = "peer login", .refreshable = true },
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(status, .{}, &out.writer);
    const text = try out.toOwnedSlice();
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "credential-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "peer login") != null);
}

const TestProviderState = struct {
    acquire_calls: usize = 0,
    invalidate_calls: usize = 0,
    cancel_during_acquire: ?*std.atomic.Value(bool) = null,

    fn acquire(raw: *const anyopaque, alloc: Allocator, _: Request) Allocator.Error!Acquisition {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.acquire_calls += 1;
        if (self.cancel_during_acquire) |flag| flag.store(true, .seq_cst);
        return .{ .acquired = .{
            .secret_bytes = try alloc.dupe(u8, "peer-secret"),
            .source = .{ .id = "peer_login", .label = "peer login", .refreshable = true },
            .catalog_access = .authenticated,
        } };
    }

    fn invalidate(raw: *const anyopaque, _: connection_registry.Profile, _: Failure) Invalidation {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.invalidate_calls += 1;
        return .{ .drop_credential = true };
    }
};

fn testProfile(kind: []const u8) connection_registry.Profile {
    return .{
        .id = @constCast("test"),
        .display_name = @constCast("Test"),
        .adapter_id = @constCast(kind),
        .endpoint = null,
        .protocol = null,
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    };
}

test "profile mismatch and cancellation precede adapter effects" {
    var state: TestProviderState = .{};
    const provider = Provider{
        .kind = "peer",
        .context = &state,
        .acquire_fn = TestProviderState.acquire,
        .invalidate_fn = TestProviderState.invalidate,
    };
    const auth_host = AuthHost{ .secret_store = host_contract.unavailable_secret_store };

    try std.testing.expectError(error.AdapterMismatch, provider.acquire(std.testing.allocator, .{
        .profile = testProfile("other"),
        .host = auth_host,
        .mode = .if_needed,
        .source_resolution = .exact,
    }));
    try std.testing.expectEqual(@as(usize, 0), state.acquire_calls);

    var cancelled = std.atomic.Value(bool).init(true);
    const outcome = try provider.acquire(std.testing.allocator, .{
        .profile = testProfile("peer"),
        .host = auth_host,
        .mode = .if_needed,
        .source_resolution = .exact,
        .cancel_flag = &cancelled,
    });
    try std.testing.expect(outcome == .cancelled);
    try std.testing.expectEqual(@as(usize, 0), state.acquire_calls);

    state.cancel_during_acquire = &cancelled;
    cancelled.store(false, .seq_cst);
    const late_cancelled = try provider.acquire(std.testing.allocator, .{
        .profile = testProfile("peer"),
        .host = auth_host,
        .mode = .if_needed,
        .source_resolution = .exact,
        .cancel_flag = &cancelled,
    });
    try std.testing.expect(late_cancelled == .cancelled);
    try std.testing.expectEqual(@as(usize, 1), state.acquire_calls);

    const invalidation = try provider.invalidate(testProfile("peer"), .{ .category = .denied });
    try std.testing.expect(invalidation.drop_credential);
    try std.testing.expectEqual(@as(usize, 1), state.invalidate_calls);
}

test "adapter acquisition reports allocation failure without publishing a credential" {
    var state: TestProviderState = .{};
    const provider = Provider{
        .kind = "peer",
        .context = &state,
        .acquire_fn = TestProviderState.acquire,
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, provider.acquire(failing.allocator(), .{
        .profile = testProfile("peer"),
        .host = .{ .secret_store = host_contract.unavailable_secret_store },
        .mode = .if_needed,
        .source_resolution = .exact,
    }));
    try std.testing.expectEqual(@as(usize, 1), state.acquire_calls);
}

test "normalized sign-in transition carries only generic team state" {
    const Poll = struct {
        fn poll(_: ?*anyopaque, _: Allocator) Allocator.Error!SignInTransition {
            return .{ .succeeded = unavailable_team_selection };
        }
    };
    var session = unavailable_sign_in_session;
    session.poll_fn = Poll.poll;
    var transition = try session.poll(std.testing.allocator);
    switch (transition) {
        .succeeded => |*selection| {
            try std.testing.expectEqual(@as(usize, 0), selection.teams.len);
            selection.deinit(std.testing.allocator);
        },
        else => return error.UnexpectedSignInTransition,
    }
}

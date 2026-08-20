const std = @import("std");
const connection_registry = @import("connection_registry.zig");
const host_contract = @import("../hosts/host.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const max_credential_sources: usize = 16;
pub const max_credential_source_id_bytes: usize = 128;
pub const max_credential_source_label_bytes: usize = 256;
pub const max_credential_presentation_fact_bytes: usize = 256;
pub const max_auth_service_label_bytes: usize = 256;

pub const DurableWriteState = host_contract.DurableWriteState;

pub const AuthServicePresentation = struct {
    service_label: []u8,

    pub fn init(alloc: Allocator, service_label: []const u8) !AuthServicePresentation {
        try validatePresentation(service_label, max_auth_service_label_bytes);
        return .{ .service_label = try alloc.dupe(u8, service_label) };
    }

    pub fn deinit(self: *AuthServicePresentation, alloc: Allocator) void {
        alloc.free(self.service_label);
        self.* = undefined;
    }
};

pub const EnteredSecretPresentation = struct {
    secret_kind_label: []u8,
    verification_service_label: []u8,
    storage_destination_label: []u8,

    pub fn init(
        alloc: Allocator,
        secret_kind_label: []const u8,
        verification_service_label: []const u8,
        storage_destination_label: []const u8,
    ) !EnteredSecretPresentation {
        try validatePresentation(secret_kind_label, max_credential_presentation_fact_bytes);
        try validatePresentation(verification_service_label, max_credential_presentation_fact_bytes);
        try validatePresentation(storage_destination_label, max_credential_presentation_fact_bytes);
        const owned_secret_kind = try alloc.dupe(u8, secret_kind_label);
        errdefer alloc.free(owned_secret_kind);
        const owned_verification = try alloc.dupe(u8, verification_service_label);
        errdefer alloc.free(owned_verification);
        return .{
            .secret_kind_label = owned_secret_kind,
            .verification_service_label = owned_verification,
            .storage_destination_label = try alloc.dupe(u8, storage_destination_label),
        };
    }

    pub fn clone(self: EnteredSecretPresentation, alloc: Allocator) !EnteredSecretPresentation {
        return init(
            alloc,
            self.secret_kind_label,
            self.verification_service_label,
            self.storage_destination_label,
        );
    }

    pub fn deinit(self: *EnteredSecretPresentation, alloc: Allocator) void {
        alloc.free(self.secret_kind_label);
        alloc.free(self.verification_service_label);
        alloc.free(self.storage_destination_label);
        self.* = undefined;
    }
};

pub const AuthProfileIdentity = struct {
    connection_id: []u8,
    adapter_id: []u8,
    credential_ref: []u8,
    endpoint: ?[]u8,
    protocol: ?[]u8,

    pub fn init(alloc: Allocator, source_profile: connection_registry.Profile) !AuthProfileIdentity {
        const connection_id = try alloc.dupe(u8, source_profile.id);
        errdefer alloc.free(connection_id);
        const adapter_id = try alloc.dupe(u8, source_profile.adapter_id);
        errdefer alloc.free(adapter_id);
        const credential_ref = try alloc.dupe(u8, source_profile.credential_ref);
        errdefer alloc.free(credential_ref);
        const endpoint = if (source_profile.endpoint) |value| try alloc.dupe(u8, value) else null;
        errdefer if (endpoint) |value| alloc.free(value);
        const protocol = if (source_profile.protocol) |value| try alloc.dupe(u8, value) else null;
        return .{
            .connection_id = connection_id,
            .adapter_id = adapter_id,
            .credential_ref = credential_ref,
            .endpoint = endpoint,
            .protocol = protocol,
        };
    }

    pub fn clone(self: AuthProfileIdentity, alloc: Allocator) !AuthProfileIdentity {
        return init(alloc, self.profile());
    }

    pub fn eqlProfile(self: AuthProfileIdentity, source_profile: connection_registry.Profile) bool {
        return std.mem.eql(u8, self.connection_id, source_profile.id) and
            std.mem.eql(u8, self.adapter_id, source_profile.adapter_id) and
            std.mem.eql(u8, self.credential_ref, source_profile.credential_ref) and
            optionalBytesEqual(self.endpoint, source_profile.endpoint) and
            optionalBytesEqual(self.protocol, source_profile.protocol);
    }

    pub fn eqlProfileRoute(self: AuthProfileIdentity, source_profile: connection_registry.Profile) bool {
        return std.mem.eql(u8, self.connection_id, source_profile.id) and
            std.mem.eql(u8, self.adapter_id, source_profile.adapter_id) and
            optionalBytesEqual(self.endpoint, source_profile.endpoint) and
            optionalBytesEqual(self.protocol, source_profile.protocol);
    }

    pub fn profile(self: AuthProfileIdentity) connection_registry.Profile {
        return .{
            .id = self.connection_id,
            .display_name = self.connection_id,
            .adapter_id = self.adapter_id,
            .endpoint = self.endpoint,
            .protocol = self.protocol,
            .credential_ref = self.credential_ref,
            .remembered_model = self.connection_id,
            .internal_models = .{},
        };
    }

    pub fn deinit(self: *AuthProfileIdentity, alloc: Allocator) void {
        alloc.free(self.connection_id);
        alloc.free(self.adapter_id);
        alloc.free(self.credential_ref);
        if (self.endpoint) |value| alloc.free(value);
        if (self.protocol) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const CredentialSourceDescriptor = struct {
    id: []u8,
    presentation_label: []u8,
    available: bool,
    refreshable: bool,
    entered_secret: ?EnteredSecretPresentation = null,
    supports_team_selection: bool,

    pub fn init(
        alloc: Allocator,
        id: []const u8,
        presentation_label: []const u8,
        available: bool,
        refreshable: bool,
        entered_secret: ?EnteredSecretPresentation,
        supports_team_selection: bool,
    ) !CredentialSourceDescriptor {
        try validateSourceId(id);
        try validatePresentation(presentation_label, max_credential_source_label_bytes);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_label = try alloc.dupe(u8, presentation_label);
        errdefer alloc.free(owned_label);
        return .{
            .id = owned_id,
            .presentation_label = owned_label,
            .available = available,
            .refreshable = refreshable,
            .entered_secret = if (entered_secret) |value| try value.clone(alloc) else null,
            .supports_team_selection = supports_team_selection,
        };
    }

    pub fn deinit(self: *CredentialSourceDescriptor, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.presentation_label);
        if (self.entered_secret) |*value| value.deinit(alloc);
        self.* = undefined;
    }
};

pub const CredentialSourceInventory = struct {
    origin_profile: AuthProfileIdentity,
    auth_service: AuthServicePresentation,
    sources: []CredentialSourceDescriptor,

    pub fn validate(self: CredentialSourceInventory, current_source_id: ?[]const u8) !void {
        if (self.sources.len > max_credential_sources) return error.TooManyCredentialSources;
        var entered_secret_count: usize = 0;
        var active_found = current_source_id == null;
        for (self.sources, 0..) |source_value, index| {
            try validateSourceId(source_value.id);
            try validatePresentation(source_value.presentation_label, max_credential_source_label_bytes);
            if (source_value.entered_secret) |presentation| {
                try validatePresentation(presentation.secret_kind_label, max_credential_presentation_fact_bytes);
                try validatePresentation(presentation.verification_service_label, max_credential_presentation_fact_bytes);
                try validatePresentation(presentation.storage_destination_label, max_credential_presentation_fact_bytes);
                entered_secret_count += 1;
            }
            for (self.sources[0..index]) |previous| {
                if (std.mem.eql(u8, previous.id, source_value.id)) return error.DuplicateCredentialSource;
            }
            if (current_source_id) |active| {
                if (std.mem.eql(u8, source_value.id, active)) active_found = true;
            }
        }
        if (entered_secret_count > 1) return error.AmbiguousEnteredSecretSource;
        if (!active_found) return error.UnknownActiveCredentialSource;
    }

    pub fn deinit(self: *CredentialSourceInventory, alloc: Allocator) void {
        self.origin_profile.deinit(alloc);
        self.auth_service.deinit(alloc);
        for (self.sources) |*source_value| source_value.deinit(alloc);
        alloc.free(self.sources);
        self.* = undefined;
    }
};

pub const SourceInventoryRequest = struct {
    profile: AuthProfileIdentity,
    host: AuthHost,
    current_source_id: ?[]const u8 = null,
    cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancelled(self: SourceInventoryRequest) bool {
        return if (self.cancel_flag) |flag| flag.load(.seq_cst) else false;
    }

    pub fn deinit(self: *SourceInventoryRequest, alloc: Allocator) void {
        self.profile.deinit(alloc);
        self.* = undefined;
    }
};

pub const SourceInventoryOutcome = union(enum) {
    loaded: CredentialSourceInventory,
    invalid_configuration,
    missing_capability,
    failed: Failure,
    cancelled,

    pub fn deinit(self: *SourceInventoryOutcome, alloc: Allocator) void {
        if (self.* == .loaded) self.loaded.deinit(alloc);
        self.* = .invalid_configuration;
    }
};

pub const OwnedEnteredSecret = struct {
    bytes: []u8,

    pub fn deinit(self: *OwnedEnteredSecret, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.bytes);
        self.* = undefined;
    }
};

pub const EnteredSecretSubmission = struct {
    request_id: u64,
    profile: AuthProfileIdentity,
    source_id: []u8,
    presentation: EnteredSecretPresentation,
    secret_value: OwnedEnteredSecret,
    host: AuthHost,
    cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancelled(self: EnteredSecretSubmission) bool {
        return if (self.cancel_flag) |flag| flag.load(.seq_cst) else false;
    }

    pub fn deinit(self: *EnteredSecretSubmission, alloc: Allocator) void {
        self.profile.deinit(alloc);
        alloc.free(self.source_id);
        self.presentation.deinit(alloc);
        self.secret_value.deinit(alloc);
        self.* = undefined;
    }
};

pub const EnteredSecretFailureStage = enum { validation, persistence, reacquisition };
pub const EnteredSecretFailureCause = union(enum) { allocation, adapter: Failure };
pub const EnteredSecretFailure = struct {
    stage: EnteredSecretFailureStage,
    cause: EnteredSecretFailureCause,
};
pub const EnteredSecretInvalid = enum { input, configuration, adapter_mismatch };
pub const EnteredSecretMissing = enum { capability, source };

pub const EnteredSecretTerminal = union(enum) {
    acquired: Credential,
    invalid: EnteredSecretInvalid,
    missing: EnteredSecretMissing,
    failed: EnteredSecretFailure,
    cancelled,
};

pub const EnteredSecretOutcome = struct {
    durable_write: DurableWriteState,
    terminal: EnteredSecretTerminal,

    pub fn deinit(self: *EnteredSecretOutcome, alloc: Allocator) void {
        if (self.terminal == .acquired) self.terminal.acquired.deinit(alloc);
        self.* = undefined;
    }
};

pub const EnteredSecretCompletion = struct {
    request_id: u64,
    profile: AuthProfileIdentity,
    source_id: []u8,
    presentation: EnteredSecretPresentation,
    outcome: EnteredSecretOutcome,

    pub fn deinit(self: *EnteredSecretCompletion, alloc: Allocator) void {
        self.profile.deinit(alloc);
        alloc.free(self.source_id);
        self.presentation.deinit(alloc);
        self.outcome.deinit(alloc);
        self.* = undefined;
    }
};

fn validatePresentation(value: []const u8, max_bytes: usize) !void {
    if (value.len == 0 or value.len > max_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidAuthPresentation;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidAuthPresentation;
}

fn validateSourceId(value: []const u8) !void {
    if (value.len == 0 or value.len > max_credential_source_id_bytes) return error.InvalidCredentialSourceId;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) {
            return error.InvalidCredentialSourceId;
        }
    }
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

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
};

test "cancellation is not an ordinary adapter auth failure" {
    try std.testing.expect(std.meta.stringToEnum(FailureCategory, "cancelled") == null);
}

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

pub const CatalogPublicOnly = struct {
    reason: CatalogPublicOnlyReason,
    source: ?Source = null,
};

pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: Source,
        credential: []const u8,
        team_context: ?[]const u8,
    },

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => |access| access.source,
            .authenticated => |access| access.source,
        };
    }

    pub fn publicOnlyReason(self: CatalogAccess) ?CatalogPublicOnlyReason {
        return switch (self) {
            .public_only => |access| access.reason,
            .authenticated => null,
        };
    }

    pub fn teamContext(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.team_context,
        };
    }

    pub fn authorizationCredential(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.credential,
        };
    }

    pub fn publicFallbackAfterRejection(self: CatalogAccess) ?CatalogAccess {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| .{ .public_only = .{
                .reason = .credential_rejected,
                .source = access.source,
            } },
        };
    }
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

    pub fn tenantContext(self: Credential) ?[]const u8 {
        return self.tenant_id orelse self.tenant_slug;
    }

    pub fn takeTenantContext(self: *Credential) ?[]u8 {
        if (self.tenant_id) |value| {
            self.tenant_id = null;
            return value;
        }
        if (self.tenant_slug) |value| {
            self.tenant_slug = null;
            return value;
        }
        return null;
    }

    pub fn needsRefreshAt(self: Credential, now_ms: i64) bool {
        const refresh_after_ms = self.refresh_after_ms orelse return false;
        return now_ms >= refresh_after_ms;
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
    logged_out_source_id: ?[]const u8 = null,
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
    origin_profile: AuthProfileIdentity,
    source: Source,
    id: []u8,
    slug: []u8,

    pub fn deinit(self: *SelectedTeam, alloc: Allocator) void {
        self.origin_profile.deinit(alloc);
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
    missing_help: ?[]u8 = null,
    store_status: StoreStatus = .not_attempted,
    expired: bool = false,

    pub fn deinit(self: *Status, alloc: Allocator) void {
        if (self.team) |value| alloc.free(value);
        if (self.missing_help) |value| alloc.free(value);
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
const SourceInventoryFn = *const fn (*const anyopaque, Allocator, *SourceInventoryRequest) Allocator.Error!SourceInventoryOutcome;
const SubmitEnteredSecretFn = *const fn (*const anyopaque, Allocator, *EnteredSecretSubmission) EnteredSecretCompletion;

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

fn unavailableSourceInventory(_: *const anyopaque, _: Allocator, _: *SourceInventoryRequest) Allocator.Error!SourceInventoryOutcome {
    return .missing_capability;
}

fn unavailableSubmitEnteredSecret(_: *const anyopaque, alloc: Allocator, submission: *EnteredSecretSubmission) EnteredSecretCompletion {
    return takeEnteredSecretCompletion(alloc, submission, .{
        .durable_write = .unchanged,
        .terminal = .{ .missing = .capability },
    });
}

pub const Provider = struct {
    kind: []const u8,
    auth_service_label: ?[]const u8 = null,
    context: *const anyopaque = &unavailable_context,
    acquire_fn: AcquireFn = unavailableAcquire,
    login_fn: LoginFn = unavailableLogin,
    logout_fn: LogoutFn = unavailableLogout,
    teams_fn: TeamsFn = unavailableTeams,
    start_sign_in_fn: StartSignInFn = unavailableStartSignIn,
    load_teams_fn: LoadTeamsFn = unavailableLoadTeams,
    invalidate_fn: InvalidateFn = unavailableInvalidate,
    status_fn: StatusFn = unavailableStatus,
    source_inventory_fn: SourceInventoryFn = unavailableSourceInventory,
    submit_entered_secret_fn: SubmitEnteredSecretFn = unavailableSubmitEnteredSecret,

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

    pub fn authServicePresentation(self: Provider, alloc: Allocator) !AuthServicePresentation {
        return AuthServicePresentation.init(alloc, try self.authServiceLabel());
    }

    /// Borrowed from the immutable adapter registration for its full lifetime.
    pub fn authServiceLabel(self: Provider) ![]const u8 {
        const label = self.auth_service_label orelse return error.MissingAuthPresentation;
        try validatePresentation(label, max_auth_service_label_bytes);
        return label;
    }

    pub fn sourceInventory(
        self: Provider,
        alloc: Allocator,
        request: *SourceInventoryRequest,
    ) (Allocator.Error || error{AdapterMismatch})!SourceInventoryOutcome {
        try self.validateProfile(request.profile.profile());
        if (request.cancelled()) return .cancelled;
        var outcome = try self.source_inventory_fn(self.context, alloc, request);
        if (!request.cancelled()) return outcome;
        outcome.deinit(alloc);
        return .cancelled;
    }

    pub fn submitEnteredSecret(
        self: Provider,
        alloc: Allocator,
        submission: *EnteredSecretSubmission,
    ) EnteredSecretCompletion {
        self.validateProfile(submission.profile.profile()) catch {
            return takeEnteredSecretCompletion(alloc, submission, .{
                .durable_write = .unchanged,
                .terminal = .{ .invalid = .adapter_mismatch },
            });
        };
        if (submission.cancelled()) {
            return takeEnteredSecretCompletion(alloc, submission, .{
                .durable_write = .unchanged,
                .terminal = .cancelled,
            });
        }
        return self.submit_entered_secret_fn(self.context, alloc, submission);
    }

    fn validateProfile(self: Provider, profile: connection_registry.Profile) error{AdapterMismatch}!void {
        if (!std.mem.eql(u8, profile.adapter_id, self.kind)) return error.AdapterMismatch;
    }
};

pub fn takeEnteredSecretCompletion(
    alloc: Allocator,
    submission: *EnteredSecretSubmission,
    outcome: EnteredSecretOutcome,
) EnteredSecretCompletion {
    submission.secret_value.deinit(alloc);
    const completion = EnteredSecretCompletion{
        .request_id = submission.request_id,
        .profile = submission.profile,
        .source_id = submission.source_id,
        .presentation = submission.presentation,
        .outcome = outcome,
    };
    submission.profile = undefined;
    submission.source_id = &.{};
    submission.presentation = undefined;
    return completion;
}

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
        .catalog_access = .{ .authenticated = .{
            .source = .{ .id = "test", .label = "test", .refreshable = false },
            .credential = "adapter-secret",
            .team_context = null,
        } },
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

fn inventoryForValidationTest(sources: []CredentialSourceDescriptor) CredentialSourceInventory {
    return .{
        .origin_profile = .{
            .connection_id = @constCast("test"),
            .adapter_id = @constCast("test"),
            .credential_ref = @constCast("automatic"),
            .endpoint = null,
            .protocol = null,
        },
        .auth_service = .{ .service_label = @constCast("Test Service") },
        .sources = sources,
    };
}

test "credential source inventory enforces every bound and identity invariant" {
    var empty = inventoryForValidationTest(&.{});
    try empty.validate(null);
    try std.testing.expectError(error.UnknownActiveCredentialSource, empty.validate("missing"));

    var sources: [max_credential_sources + 1]CredentialSourceDescriptor = undefined;
    const ids = [_][]const u8{
        "source-00", "source-01", "source-02", "source-03",
        "source-04", "source-05", "source-06", "source-07",
        "source-08", "source-09", "source-10", "source-11",
        "source-12", "source-13", "source-14", "source-15",
        "source-16",
    };
    for (&sources, ids) |*source_value, id| source_value.* = .{
        .id = @constCast(id),
        .presentation_label = @constCast("Credential source"),
        .available = true,
        .refreshable = false,
        .supports_team_selection = false,
    };

    var bounded = inventoryForValidationTest(sources[0..max_credential_sources]);
    try bounded.validate("source-15");
    var oversized = inventoryForValidationTest(&sources);
    try std.testing.expectError(error.TooManyCredentialSources, oversized.validate(null));

    sources[1].id = sources[0].id;
    try std.testing.expectError(error.DuplicateCredentialSource, bounded.validate(null));
    sources[1].id = @constCast(ids[1]);
    sources[1].id = @constCast("invalid source");
    try std.testing.expectError(error.InvalidCredentialSourceId, bounded.validate(null));
    sources[1].id = @constCast(ids[1]);

    sources[1].presentation_label = @constCast("bad\nlabel");
    try std.testing.expectError(error.InvalidAuthPresentation, bounded.validate(null));
    sources[1].presentation_label = @constCast("Credential source");
    const long_label = "x" ** (max_credential_source_label_bytes + 1);
    sources[1].presentation_label = @constCast(long_label);
    try std.testing.expectError(error.InvalidAuthPresentation, bounded.validate(null));
    sources[1].presentation_label = @constCast("Credential source");

    sources[0].entered_secret = .{
        .secret_kind_label = @constCast(""),
        .verification_service_label = @constCast("Verification service"),
        .storage_destination_label = @constCast("Credential store"),
    };
    try std.testing.expectError(error.InvalidAuthPresentation, bounded.validate(null));
    sources[0].entered_secret.?.secret_kind_label = @constCast("API key");
    sources[1].entered_secret = .{
        .secret_kind_label = @constCast("Peer key"),
        .verification_service_label = @constCast("Verification service"),
        .storage_destination_label = @constCast("Credential store"),
    };
    try std.testing.expectError(error.AmbiguousEnteredSecretSource, bounded.validate(null));
}

fn exerciseSubmissionOwnershipAllocation(alloc: Allocator) !void {
    const profile = testProfile("peer");
    var identity = try AuthProfileIdentity.init(alloc, profile);
    errdefer identity.deinit(alloc);
    const source_id = try alloc.dupe(u8, "peer_key");
    errdefer alloc.free(source_id);
    var presentation = try EnteredSecretPresentation.init(
        alloc,
        "API key",
        "Example Cloud Gateway",
        "test credential store",
    );
    errdefer presentation.deinit(alloc);
    const secret_bytes = try alloc.dupe(u8, "submission-secret");
    var submission = EnteredSecretSubmission{
        .request_id = 1,
        .profile = identity,
        .source_id = source_id,
        .presentation = presentation,
        .secret_value = .{ .bytes = secret_bytes },
        .host = .{ .secret_store = host_contract.unavailable_secret_store },
    };
    submission.deinit(alloc);
}

test "entered-secret submission ownership cleans every induced allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSubmissionOwnershipAllocation,
        .{},
    );
}

const TestProviderState = struct {
    acquire_calls: usize = 0,
    invalidate_calls: usize = 0,
    status_calls: usize = 0,
    cancel_during_acquire: ?*std.atomic.Value(bool) = null,

    fn acquire(raw: *const anyopaque, alloc: Allocator, _: Request) Allocator.Error!Acquisition {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.acquire_calls += 1;
        if (self.cancel_during_acquire) |flag| flag.store(true, .seq_cst);
        return .{ .acquired = .{
            .secret_bytes = try alloc.dupe(u8, "peer-secret"),
            .source = .{ .id = "peer_login", .label = "peer login", .refreshable = true },
            .catalog_access = .{ .authenticated = .{
                .source = .{ .id = "peer_login", .label = "peer login", .refreshable = true },
                .credential = "peer-secret",
                .team_context = null,
            } },
        } };
    }

    fn invalidate(raw: *const anyopaque, _: connection_registry.Profile, _: Failure) Invalidation {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.invalidate_calls += 1;
        return .{ .drop_credential = true };
    }

    fn status(raw: *const anyopaque, _: Allocator, _: connection_registry.Profile, _: AuthHost) Allocator.Error!StatusOutcome {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.status_calls += 1;
        return .{ .loaded = .{} };
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
        .status_fn = TestProviderState.status,
    };
    const auth_host = AuthHost{ .secret_store = host_contract.unavailable_secret_store };

    try std.testing.expectError(error.AdapterMismatch, provider.acquire(std.testing.allocator, .{
        .profile = testProfile("other"),
        .host = auth_host,
        .mode = .if_needed,
        .source_resolution = .exact,
    }));
    try std.testing.expectEqual(@as(usize, 0), state.acquire_calls);

    try std.testing.expectError(
        error.AdapterMismatch,
        provider.status(std.testing.allocator, testProfile("other"), auth_host),
    );
    try std.testing.expectEqual(@as(usize, 0), state.status_calls);

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

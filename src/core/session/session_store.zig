const std = @import("std");
const builtin = @import("builtin");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const core_types = @import("../shared/types.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const artifact_digest = @import("artifact_digest.zig");
const command_replay_store = @import("command_replay_store.zig");
const result_store = @import("result_store.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_child_store = @import("session_child_store.zig");
const relationship_index_codec = @import("session_relationship_index_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_layout = @import("session_layout.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_usage = @import("session_usage.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const discovery = @import("session_discovery.zig");
const latest_pointer = @import("session_latest_pointer.zig");
const migration = @import("session_migration.zig");
const paths = @import("session_store_paths.zig");
const store_types = @import("session_store_types.zig");
const summary_codec = @import("session_summary_codec.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const authorityTransitionsEqual = authority_module.authorityTransitionsEqual;
const classifyAuthority = authority_module.classifyAuthority;
const classifyAuthorityAllowingLargeLegacy = authority_module.classifyAuthorityAllowingLargeLegacy;
const deleteSessionEntry = authority_module.deleteSessionEntry;
const loadAuthorityTransitionOptional = authority_module.loadAuthorityTransitionOptional;
const mapReplayError = authority_module.mapReplayError;
const openSessionFile = authority_module.openSessionFile;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
const requireAuthorityTransitionSession = authority_module.requireAuthorityTransitionSession;
const restoreLegacyAuthority = authority_module.restoreLegacyAuthority;
const DiscoveryCandidateMetadata = discovery.DiscoveryCandidateMetadata;
const DiscoveryMode = discovery.DiscoveryMode;
const ReadOnlyCandidate = discovery.ReadOnlyCandidate;
const WritableCandidate = discovery.WritableCandidate;
const appendDoctorDiagnostic = discovery.appendDoctorDiagnostic;
const classifyLegacyCandidate = discovery.classifyLegacyCandidate;
const classifyReadOnlyCandidate = discovery.classifyReadOnlyCandidate;
const classifySchemaV3Candidate = discovery.classifySchemaV3Candidate;
const dupeWritableCandidate = discovery.dupeWritableCandidate;
const freeDoctorDiagnostics = discovery.freeDoctorDiagnostics;
const inspectDoctorSession = discovery.inspectDoctorSession;
const logDiscovery = discovery.logDiscovery;
const logDiscoveryError = discovery.logDiscoveryError;
const storageFormatForLegacy = discovery.storageFormatForLegacy;
const summaryFromState = discovery.summaryFromState;
const writableCandidateNewer = discovery.writableCandidateNewer;
const InitialIndexEffect = latest_pointer.InitialIndexEffect;
const LatestCache = latest_pointer.LatestCache;
const LatestPointer = latest_pointer.LatestPointer;
const latestCacheAbort = latest_pointer.latestCacheAbort;
const latestCacheDeinit = latest_pointer.latestCacheDeinit;
const latestCachePrepare = latest_pointer.latestCachePrepare;
const latestCachePublish = latest_pointer.latestCachePublish;
const latestCacheWriteDeferred = latest_pointer.latestCacheWriteDeferred;
const latest_sessions_lock_file = latest_pointer.latest_sessions_lock_file;
const latest_sessions_dir = latest_pointer.latest_sessions_dir;
const recovery_staging_dir = "recovery+staging";
const recovery_staging_lock_file = "recovery-staging.lock";
const usage_recovery_dir = profile_paths.usage_recovery_dir_name;
const usage_recovery_marker_prefix = "v1 ";
const max_usage_recovery_marker_bytes =
    usage_recovery_marker_prefix.len + 20 + 1;
const max_usage_recovery_sessions: usize = 512;
const synchronous_display_metadata_replay_max_bytes: u64 = 1024 * 1024;
const readLatestPointerFromSessions = latest_pointer.readLatestPointerFromSessions;
const readPendingLatestSessionIdFromSessions = latest_pointer.readPendingLatestSessionIdFromSessions;
const LegacyStoredSession = migration.LegacyStoredSession;
const MigrationPreferenceSource = migration.MigrationPreferenceSource;
const legacyToDurableState = migration.legacyToDurableState;
const loadedMigrationTarget = migration.loadedMigrationTarget;
const migrateLegacyLocked = migration.migrateLegacyLocked;
const migratedSourceBytes = migration.migratedSourceBytes;
const migratedSourceSchemaVersion = migration.migratedSourceSchemaVersion;
const validateMigrationTarget = migration.validateMigrationTarget;
const normalizeWorkspaceRoot = paths.normalizeWorkspaceRoot;
pub const sessionDirPath = paths.sessionDirPath;
const sessionJsonPath = paths.sessionJsonPath;
const session_list_json_file = paths.session_list_json_file;
const session_summary_file = paths.session_summary_file;
const summaryPath = paths.summaryPath;
pub const validateSessionId = paths.validateSessionId;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
pub const generateSessionId = paths.generateSessionId;
pub const CandidateStorage = store_types.CandidateStorage;
pub const DiscoveryCause = store_types.DiscoveryCause;
pub const DoctorDiagnostic = store_types.DoctorDiagnostic;
pub const DoctorInspectionResult = store_types.DoctorInspectionResult;
const DoctorInspectionOptions = store_types.DoctorInspectionOptions;
pub const DoctorIssueKind = store_types.DoctorIssueKind;
pub const LoadedWritableSession = store_types.LoadedWritableSession;
pub const MigrationOptions = store_types.MigrationOptions;
pub const ProjectionState = store_types.ProjectionState;

pub const UsageRecoverySession = struct {
    id: []u8,
    protected_updated_at_ms: ?i64,

    pub fn deinit(self: *UsageRecoverySession, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }
};

pub const UsageRecoveryCheckpoint = struct {
    recovery_pending: bool,
    timestamp_ms: i64,
};

pub fn imageSnapshotStorageDir(
    alloc: Allocator,
    sessions_dir: ?[]const u8,
    session_id: ?[]const u8,
    temp_dir: *?[]u8,
) ![]u8 {
    if ((sessions_dir == null) != (session_id == null)) return error.InvalidSessionSnapshotOwner;
    if (sessions_dir) |root| {
        const durable_dir = try sessionDirPath(alloc, root, session_id.?);
        defer alloc.free(durable_dir);
        return std.fs.path.join(alloc, &.{ durable_dir, "images" });
    }
    if (temp_dir.* == null) {
        temp_dir.* = try image_attachments.createTempSnapshotDir(alloc);
    }
    return alloc.dupe(u8, temp_dir.*.?);
}
pub const ReadOnlyDetail = store_types.ReadOnlyDetail;
pub const ResumeOptions = store_types.ResumeOptions;
pub const ResumeTarget = store_types.ResumeTarget;
pub const ResumeViewAdmission = session_log.ResumeViewAdmission;
pub const SessionMigrationResult = store_types.SessionMigrationResult;
pub const SessionMigrationStatus = store_types.SessionMigrationStatus;
pub const SessionRecoveryResult = store_types.SessionRecoveryResult;
pub const SessionRecoveryStatus = store_types.SessionRecoveryStatus;
pub const SessionSummary = store_types.SessionSummary;
pub const HistoryPage = store_types.HistoryPage;

pub const LoadHistoryPageError = error{
    OutOfMemory,
    InvalidSessionId,
    InvalidHistoryPageLimit,
    InvalidHistoryPageCursor,
    StaleHistoryPageCursor,
    SessionNotFound,
    SessionPathUnsafe,
    SessionStoreUnavailable,
    UnsupportedSessionFormat,
    CorruptSession,
};

const HistoryPageCursor = struct {
    session_id: []const u8,
    history_len: usize,
    revision_ms: i64,
    prefix_digest: [32]u8,
    start: usize,
};

fn parseHistoryPageCursor(raw: []const u8) LoadHistoryPageError!HistoryPageCursor {
    if (raw.len == 0 or raw.len > 512) return error.InvalidHistoryPageCursor;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHistoryPageCursor, "v2")) return error.InvalidHistoryPageCursor;
    const session_id = fields.next() orelse return error.InvalidHistoryPageCursor;
    const history_len = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    const revision_ms = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    const digest_hex = fields.next() orelse return error.InvalidHistoryPageCursor;
    const start = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    if (fields.next() != null) return error.InvalidHistoryPageCursor;
    if (digest_hex.len != 64 or revision_ms < 0 or start > history_len) return error.InvalidHistoryPageCursor;
    validateSessionId(session_id) catch return error.InvalidHistoryPageCursor;
    var prefix_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&prefix_digest, digest_hex) catch return error.InvalidHistoryPageCursor;
    const cursor: HistoryPageCursor = .{ .session_id = session_id, .history_len = history_len, .revision_ms = revision_ms, .prefix_digest = prefix_digest, .start = start };
    var canonical: [512]u8 = undefined;
    const encoded = formatHistoryPageCursor(&canonical, cursor) catch return error.InvalidHistoryPageCursor;
    if (!std.mem.eql(u8, raw, encoded)) return error.InvalidHistoryPageCursor;
    return cursor;
}

fn formatHistoryPageCursor(buffer: []u8, cursor: HistoryPageCursor) ![]u8 {
    return std.fmt.bufPrint(buffer, "v2:{s}:{d}:{d}:{x}:{d}", .{ cursor.session_id, cursor.history_len, cursor.revision_ms, cursor.prefix_digest, cursor.start });
}

fn duplicateHistoryPage(alloc: Allocator, turns: []const session.HistoryTurn) ![]session.HistoryTurn {
    const copy = try alloc.alloc(session.HistoryTurn, turns.len);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(copy);
    }
    for (turns) |turn| {
        copy[copied] = try session.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    return copy;
}

fn historyPrefixDigest(turns: []const session.HistoryTurn) error{ WriteFailed, NoSpaceLeft }![32]u8 {
    var buffer: [256]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buffer);
    try hashing.writer.writeAll("fx.history-page-prefix.v2\x00");
    for (turns) |turn| {
        try session_codec.writeHistoryTurn(&hashing.writer, turn);
        // Canonical JSON never contains a literal NUL, so this makes the
        // concatenation unambiguous without introducing another serializer.
        try hashing.writer.writeByte(0);
    }
    try hashing.writer.flush();
    return hashing.hasher.finalResult();
}

fn mapHistoryPageLoadError(err: anyerror) LoadHistoryPageError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId => error.InvalidSessionId,
        error.SessionNotFound => error.SessionNotFound,
        error.SessionPathUnsafe => error.SessionPathUnsafe,
        error.UnsupportedSessionFormat, error.UnsupportedSessionSchema => error.UnsupportedSessionFormat,
        error.InvalidSessionFormat,
        error.InvalidDurableField,
        error.InvalidDurableBytes,
        error.InvalidSessionIndex,
        => error.CorruptSession,
        // `loadReadOnly` intentionally has an inferred upstream error set.
        // Its uncategorized I/O and replay failures are unavailable storage,
        // never evidence that the committed session itself is corrupt.
        else => error.SessionStoreUnavailable,
    };
}

const HistoryPageWindow = struct {
    start: usize,
    end: usize,
};

fn selectHistoryPageWindow(history_len: usize, exclusive_end: usize, limit: usize) HistoryPageWindow {
    std.debug.assert(exclusive_end <= history_len);
    return .{ .start = exclusive_end -| limit, .end = exclusive_end };
}
pub const OpenSubagentControlError = error{
    OutOfMemory,
    InvalidSessionId,
    SessionNotFound,
    SessionPathUnsafe,
    SessionStoreUnavailable,
    PrivateStatePermissionsUnsupported,
    SessionChildStoreFailed,
};
pub const LoadSubagentBootstrapError = error{
    OutOfMemory,
    InvalidSessionId,
    SessionNotFound,
    SessionPathUnsafe,
    SessionMetadataUnavailable,
};
pub const ListSubagentControlIdsError = error{
    OutOfMemory,
    SessionStoreUnavailable,
};
pub const SubagentBootstrapMetadata = struct {
    name: []u8,
    preferences: session_codec.DurableSessionPreferences,

    pub fn deinit(self: *SubagentBootstrapMetadata, alloc: Allocator) void {
        alloc.free(self.name);
        self.preferences.deinit(alloc);
        self.* = undefined;
    }
};
pub const ResumableSessionContinuation = store_types.ResumableSessionContinuation;
pub const ResumableSessionPage = store_types.ResumableSessionPage;
pub const SessionListScope = store_types.SessionListScope;
pub const SessionListPage = store_types.SessionListPage;
pub const session_list_default_limit: usize = 100;
pub const session_list_max_limit: usize = 100;
pub const ListWorkspacePageError = error{
    OutOfMemory,
    InvalidSessionListLimit,
    SessionStoreUnavailable,
};
pub const RelationshipMigrationCursor = summary_codec.RelationshipMigrationCursor;
pub const RelationshipMigrationCandidatePage =
    summary_codec.RelationshipMigrationCandidatePage;
pub const relationship_migration_candidate_limit =
    summary_codec.relationship_migration_candidate_limit;
const ResumableSessionScope = enum {
    all_workspaces,
    current_workspace,
};
pub const StateSummary = store_types.StateSummary;
pub const StorageFormat = store_types.StorageFormat;
const automatic_legacy_max_bytes = store_types.automatic_legacy_max_bytes;
const max_session_bytes = store_types.max_session_bytes;
const StoreContext = store_types.StoreContext;
const freeSummaries = summary_codec.freeSummaries;
const readSessionStateSummary = summary_codec.readSessionStateSummary;
const readSessionIndex = summary_codec.readSessionIndex;
const readSessionIndexWorkspaceCandidates = summary_codec.readSessionIndexWorkspaceCandidates;
const removeSessionIndexMarker = summary_codec.removeSessionIndexMarker;
const resumablePageFromSummaries = summary_codec.resumablePageFromSummaries;
const sessionListPageFromSummaries = summary_codec.sessionListPageFromSummaries;
const sortSummariesNewestFirst = summary_codec.sortSummariesNewestFirst;
const writeSessionIndex = summary_codec.writeSessionIndex;

const SessionSummaryScan = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    skipped_invalid: usize = 0,

    fn deinit(self: *SessionSummaryScan, alloc: Allocator) void {
        freeSummaries(alloc, &self.summaries);
        self.* = undefined;
    }
};

const DeferredReplayScope = union(enum) {
    tokens: std.ArrayList(summary_codec.DeferredCacheToken),
    all,

    fn deinit(self: *DeferredReplayScope, alloc: Allocator) void {
        switch (self.*) {
            .tokens => |*tokens| summary_codec.freeDeferredCacheTokens(alloc, tokens),
            .all => {},
        }
        self.* = undefined;
    }
};

fn tokenScopeRequiresCanonicalReplay(
    scope: DeferredReplayScope,
    session_id: []const u8,
) bool {
    return switch (scope) {
        .all => true,
        .tokens => |tokens| for (tokens.items) |token| {
            if (std.mem.eql(u8, token.session_id, session_id)) break true;
        } else false,
    };
}

fn readOnlyScopeRequiresCanonicalReplay(
    scope: DeferredReplayScope,
    session_id: []const u8,
    projection_state: ProjectionState,
) bool {
    return switch (scope) {
        .all => true,
        .tokens => |tokens| tokens.items.len > 0 and
            (projection_state == .stale or
                tokenScopeRequiresCanonicalReplay(scope, session_id)),
    };
}

test "deferred replay scope preserves token identity and stale projection safety" {
    var token_values = [_]summary_codec.DeferredCacheToken{
        testDeferredCacheToken("dirty-session"),
        testDeferredCacheToken("second-dirty-session"),
    };
    const empty = DeferredReplayScope{ .tokens = .empty };
    const populated = DeferredReplayScope{ .tokens = .{
        .items = token_values[0..],
        .capacity = token_values.len,
    } };
    const untrusted = DeferredReplayScope.all;
    const cases = [_]struct {
        scope: DeferredReplayScope,
        session_id: []const u8,
        projection_state: ProjectionState,
        expected: bool,
    }{
        .{ .scope = empty, .session_id = "clean-session", .projection_state = .current, .expected = false },
        .{ .scope = empty, .session_id = "clean-session", .projection_state = .stale, .expected = false },
        .{ .scope = populated, .session_id = "dirty-session", .projection_state = .current, .expected = true },
        .{ .scope = populated, .session_id = "second-dirty-session", .projection_state = .current, .expected = true },
        .{ .scope = populated, .session_id = "clean-session", .projection_state = .current, .expected = false },
        .{ .scope = populated, .session_id = "clean-session", .projection_state = .stale, .expected = true },
        .{ .scope = untrusted, .session_id = "clean-session", .projection_state = .current, .expected = true },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            readOnlyScopeRequiresCanonicalReplay(
                case.scope,
                case.session_id,
                case.projection_state,
            ),
        );
    }
}

fn testDeferredCacheToken(session_id: []const u8) summary_codec.DeferredCacheToken {
    return .{
        .session_id = @constCast(session_id),
        .workspace_root = @constCast("/tmp/workspace"),
        .position = .{
            .log_generation = [_]u8{0x11} ** 16,
            .through_seq = 2,
            .through_event_id = [_]u8{0x22} ** 16,
            .through_event_log_bytes = 100,
        },
    };
}

test {
    _ = session_child_store;
    _ = session_layout;
    _ = session_log;
    _ = session_display_metadata;
    _ = store_types;
    _ = paths;
    _ = authority_module;
    _ = summary_codec;
    _ = latest_pointer;
    _ = migration;
    _ = discovery;
}

fn retainWorkspaceSummaries(alloc: Allocator, summaries: *std.ArrayList(SessionSummary), workspace_root: []const u8) void {
    var write_index: usize = 0;
    for (summaries.items, 0..) |*summary, read_index| {
        const summary_workspace = summary.workspace_root orelse {
            summary.deinit(alloc);
            continue;
        };
        if (!std.mem.eql(u8, summary_workspace, workspace_root)) {
            summary.deinit(alloc);
            continue;
        }
        if (write_index != read_index) summaries.items[write_index] = summary.*;
        write_index += 1;
    }
    summaries.items.len = write_index;
}

fn summariesMissingDisplayMetadata(summaries: []const SessionSummary) bool {
    for (summaries) |summary| {
        if (summaryNeedsDisplayMetadata(summary)) return true;
    }
    return false;
}

fn summaryNeedsDisplayMetadata(summary: SessionSummary) bool {
    if (summary.history_len == 0) return false;
    if (!summary.display_metadata_present) return true;
    return summary.title == null;
}

fn initialIndexEffect(state: session_codec.DurableSessionState) InitialIndexEffect {
    return if (state.history.len == 0) .preserve else .maintain;
}

pub const default_resume_page_limit: usize = 10;

fn openUsageRecoveryProfileRoot(
    home_path: []const u8,
) !?io_mod.VerifiedDir {
    const zio = io_mod.getIo();
    var home = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
        .iterate = true,
    });
    defer home.close(zio);
    var profile = home.openDir(zio, profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
        else => return err,
    };
    errdefer profile.close(zio);
    const stat = try profile.stat(zio);
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != 0o700)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    return .{ .dir = profile };
}

fn openUsageRecoveryDir(
    home_path: []const u8,
) !?io_mod.VerifiedDir {
    var profile = try openUsageRecoveryProfileRoot(home_path) orelse return null;
    defer profile.close();
    var dir = profile.dir.openDir(io_mod.getIo(), usage_recovery_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != 0o700)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    return .{ .dir = dir };
}

fn validateUsageRecoveryMarker(
    recovery: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !?i64 {
    var marker = recovery.dir.openFile(io_mod.getIo(), session_id, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.UsageRecoveryMarkerNotFound,
        else => return error.InvalidUsageRecoveryIndex,
    };
    defer marker.close(io_mod.getIo());
    const stat = try marker.stat(io_mod.getIo());
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.size == 0 or
        stat.size > max_usage_recovery_marker_bytes or
        stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    var bytes: [max_usage_recovery_marker_bytes]u8 = undefined;
    const marker_len: usize = @intCast(stat.size);
    const read = marker.readPositionalAll(
        io_mod.getIo(),
        bytes[0..marker_len],
        0,
    ) catch return error.InvalidUsageRecoveryIndex;
    if (read != marker_len) {
        return error.InvalidUsageRecoveryIndex;
    }
    const marker_bytes = bytes[0..marker_len];
    if (!std.mem.startsWith(
        u8,
        marker_bytes,
        usage_recovery_marker_prefix,
    ) or !std.mem.endsWith(u8, marker_bytes, "\n")) {
        return error.InvalidUsageRecoveryIndex;
    }
    const timestamp_bytes = marker_bytes[usage_recovery_marker_prefix.len .. marker_bytes.len - 1];
    if (timestamp_bytes.len == 0) return error.InvalidUsageRecoveryIndex;
    const timestamp_ms = std.fmt.parseInt(
        i64,
        timestamp_bytes,
        10,
    ) catch return error.InvalidUsageRecoveryIndex;
    if (timestamp_ms < 0) return error.InvalidUsageRecoveryIndex;
    return timestamp_ms;
}

pub const Store = struct {
    sessions_dir: []u8,
    home_dir: []u8,
    workspace_root: []u8,
    canonical_root: session_log.Root,
    // How many sessions one resume page yields before flagging `has_more`.
    // Carried on the value so it propagates through the by-value page chain;
    // the UI sets it from the visible screen height.
    resume_page_limit: usize = default_resume_page_limit,

    /// Narrow, copyable view of this store for the discovery/migration helpers,
    /// so they depend on `StoreContext` instead of the full facade.
    fn ctx(self: Store) StoreContext {
        return .{
            .sessions_dir = self.sessions_dir,
            .home_dir = self.home_dir,
            .workspace_root = self.workspace_root,
            .canonical_root = self.canonical_root,
        };
    }

    /// Opens a writable store rooted at `$HOME`, creating the layout if needed.
    pub fn init(alloc: Allocator, workspace_root: []const u8) !Store {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        return initWithHome(alloc, home, workspace_root, true);
    }

    /// Opens a read-only store rooted at `$HOME`; never creates layout.
    pub fn initReadOnly(alloc: Allocator, workspace_root: []const u8) !Store {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        return initWithHome(alloc, home, workspace_root, false);
    }

    /// Read-only store with an injected home directory (tests / non-HOME callers).
    pub fn initReadOnlyFromHome(
        alloc: Allocator,
        home_dir: []const u8,
        workspace_root: []const u8,
    ) !Store {
        return initWithHome(alloc, home_dir, workspace_root, false);
    }

    /// Opens the store using an injected home directory for tests.
    /// Writable store with an injected home directory (tests).
    pub fn initFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Store {
        return initWithHome(alloc, home_dir, workspace_root, true);
    }

    /// Frees store path strings.
    /// Frees the store path strings and the canonical root.
    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.canonical_root.deinit(alloc);
        alloc.free(self.sessions_dir);
        alloc.free(self.home_dir);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }

    /// Starts a brand-new writable session from `state`, with default log options.
    pub fn startWritableSession(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
    ) !LoadedWritableSession {
        return self.startWritableSessionWithOptions(alloc, state, .{});
    }

    /// Starts a new writable session, attaching the latest-pointer lifecycle and
    /// the writable managed-child capability. Caller owns the returned session.
    pub fn startWritableSessionWithOptions(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var root = self.canonical_root;
        const lifecycle = try self.makeLatestCacheLifecycle(
            alloc,
            initialIndexEffect(state),
            options.test_controls,
        );
        var loaded = try root.startWritableSessionWithLifecycle(
            alloc,
            state,
            options,
            lifecycle,
        );
        errdefer loaded.deinit(alloc);
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn startRecoveryStagedSession(
        self: Store,
        alloc: Allocator,
        staging_root: *session_log.Root,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var loaded = try staging_root.startWritableSessionWithLifecycle(
            alloc,
            state,
            options,
            null,
        );
        errdefer loaded.deinit(alloc);
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn initRecoveryStagingRoot(
        self: Store,
        alloc: Allocator,
    ) !session_log.Root {
        var root = self.canonical_root;
        const sessions = &(root.sessions orelse
            return error.SessionStoreUnavailable);
        var staging = try io_mod.openOrCreateVerifiedPrivateDir(
            sessions,
            recovery_staging_dir,
        );
        errdefer staging.close();
        return .{
            .sessions = staging,
            .display_root = try std.fs.path.join(
                alloc,
                &.{ self.sessions_dir, recovery_staging_dir },
            ),
            .mode = .writable,
        };
    }

    fn deinitRecoveryStagingRoot(
        self: Store,
        alloc: Allocator,
        staging_root: *session_log.Root,
    ) void {
        staging_root.deinit(alloc);
        const sessions = &(self.canonical_root.sessions orelse return);
        sessions.dir.deleteDir(
            io_mod.getIo(),
            recovery_staging_dir,
        ) catch return;
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_cleanup disposition=indeterminate err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn acquireRecoveryStagingLock(
        self: Store,
        deadline_ms: u64,
    ) !io_mod.TimedAdvisoryLock {
        var root = self.canonical_root;
        const sessions = &(root.sessions orelse
            return error.SessionStoreUnavailable);
        return io_mod.acquireTimedAdvisoryLock(
            sessions,
            recovery_staging_lock_file,
            deadline_ms,
        ) catch |err| switch (err) {
            error.LockBusy => error.SessionBusy,
            error.LockUnsupported => error.SessionLockUnsupported,
            else => return err,
        };
    }

    fn cleanupAbandonedRecoveryStages(
        staging_root: *session_log.Root,
    ) !void {
        const staging = &(staging_root.sessions orelse
            return error.SessionStoreUnavailable);
        var entries = staging.dir.iterate();
        var changed = false;
        while (try entries.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            validateSessionId(entry.name) catch continue;
            try staging.dir.deleteTree(io_mod.getIo(), entry.name);
            changed = true;
            debug_trace.logf(
                "session",
                "event=recovery_staging_abandoned_target_removed",
                .{},
            );
        }
        if (changed) try io_mod.syncVerifiedDir(staging.dir);
    }

    fn promoteRecoveryStagedSession(
        self: Store,
        staging_root: *session_log.Root,
        session_id: []const u8,
    ) !RecoveryPromotionStatus {
        const staging = &(staging_root.sessions orelse
            return error.SessionStoreUnavailable);
        const sessions = &(self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable);
        try staging.dir.rename(
            session_id,
            sessions.dir,
            session_id,
            io_mod.getIo(),
        );
        io_mod.syncVerifiedDir(sessions.dir) catch
            return .indeterminate;
        io_mod.syncVerifiedDir(staging.dir) catch
            return .indeterminate;
        return .promoted;
    }

    /// Consumes `loaded` on every return.
    fn discardRecoveryStagedSession(
        staging_root: *session_log.Root,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        defer loaded.deinit(alloc);
        if (staging_root.mode != .writable or
            loaded.commit_lifecycle != null)
        {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=guard_failed",
                .{},
            );
            return .retained;
        }
        const writer_belongs_to_store = loadedWriterBelongsToRoot(
            alloc,
            loaded,
            staging_root.display_root,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=store_root_unverified err={s}",
                .{@errorName(err)},
            );
            return .retained;
        };
        if (!writer_belongs_to_store) {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=store_root_mismatch",
                .{},
            );
            return .retained;
        }
        const sessions = &(staging_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=sessions_root",
                .{},
            );
            return .indeterminate;
        });
        sessions.dir.deleteTree(io_mod.getIo(), loaded.active_id) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=delete err={s}",
                .{@errorName(err)},
            );
            return .indeterminate;
        };
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=sync err={s}",
                .{@errorName(err)},
            );
            return .indeterminate;
        };
        debug_trace.logf(
            "session",
            "event=recovery_staging_discard disposition=discarded",
            .{},
        );
        return .discarded;
    }

    /// Consumes `loaded` on every return. A confirmed result means the canonical
    /// session directory was removed and the sessions parent was synced.
    pub fn discardPristineStartedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        if (!isPristineStartedSession(loaded)) {
            loaded.deinit(alloc);
            debug_trace.logf(
                "session",
                "event=pristine_session_discard disposition=retained reason=guard_failed",
                .{},
            );
            return .retained;
        }
        return self.deleteWriterOwnedSession(
            alloc,
            loaded,
            "pristine_session_discard",
        );
    }

    /// Consumes an exact writable session on every return. Policy checks such
    /// as terminal one-off admission remain with the caller that owns them.
    pub fn deleteCommittedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        return self.deleteWriterOwnedSession(
            alloc,
            loaded,
            "committed_session_delete",
        );
    }

    fn deleteWriterOwnedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
        event_name: []const u8,
    ) PristineDiscardDisposition {
        defer loaded.deinit(alloc);
        if (self.canonical_root.mode != .writable or
            !std.mem.eql(u8, self.workspace_root, loaded.state.workspace_root))
        {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=guard_failed",
                .{event_name},
            );
            return .retained;
        }
        const writer_belongs_to_store = loadedWriterBelongsToStore(
            self,
            alloc,
            loaded,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=store_root_unverified err={s}",
                .{ event_name, @errorName(err) },
            );
            return .retained;
        };
        if (!writer_belongs_to_store) {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=store_root_mismatch",
                .{event_name},
            );
            return .retained;
        }
        const lifecycle = if (loaded.commit_lifecycle) |*value| value else {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=cache_lifecycle_unavailable",
                .{event_name},
            );
            return .retained;
        };
        const sessions = &(self.canonical_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sessions_root",
                .{event_name},
            );
            return .indeterminate;
        });
        const log_options: session_log.Options = .{};
        lifecycle.prepare(
            alloc,
            loaded.active_id,
            loaded.state.workspace_root,
            loaded.state.workspace_root,
            log_options.commit_lock_deadline_ms,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=cache_pending err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        sessions.dir.deleteTree(io_mod.getIo(), loaded.active_id) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=delete err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sync err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        latest_pointer.removeDeferredToken(
            sessions,
            loaded.active_id,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=deferred_token_cleanup err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        debug_trace.logf(
            "session",
            "event={s} disposition=discarded",
            .{event_name},
        );
        return .discarded;
    }

    /// Resumes a specific session by id for writing, rebinding it to this store's
    /// workspace if needed.
    pub fn resumeForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !LoadedWritableSession {
        return self.resumeTargetForWrite(
            alloc,
            .{ .id = session_id },
            self.workspace_root,
            .{},
        );
    }

    pub fn admitResumeView(
        self: Store,
        alloc: Allocator,
        target: ResumeTarget,
    ) !?ResumeViewAdmission {
        var root = self.canonical_root;
        return switch (target) {
            .id => |id| try root.admitResumeView(alloc, id),
            .last => blk: {
                if (self.deferredCacheInvalidatesReads()) {
                    var latest = try self.latestReadOnlyWorkspaceSummary(alloc);
                    defer latest.deinit(alloc);
                    break :blk try root.admitResumeView(
                        alloc,
                        latest.id,
                    );
                }
                var latest = (try readLatestPointer(self, alloc, self.workspace_root)) orelse
                    return null;
                defer latest.deinit(alloc);
                break :blk try root.admitResumeView(
                    alloc,
                    latest.session_id,
                );
            },
        };
    }

    /// Resumes a target (a specific id, or the latest) for writing under
    /// `workspace_root`, migrating legacy storage and recovering interrupted
    /// authority transitions as needed. Caller owns the returned session.
    pub fn resumeTargetForWrite(
        self: Store,
        alloc: Allocator,
        target: ResumeTarget,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateWorkspaceRoot(workspace_root);
        const loaded = switch (target) {
            .id => |session_id| try self.resumeExactForWrite(
                alloc,
                session_id,
                workspace_root,
                true,
                options,
            ),
            .last => try self.resumeLatestForWrite(alloc, workspace_root, options),
        };
        return self.finishResumedForWrite(alloc, loaded, options);
    }

    pub fn resumeAdmittedForWrite(
        self: Store,
        alloc: Allocator,
        admission: *ResumeViewAdmission,
        expected_session_id: []const u8,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateWorkspaceRoot(workspace_root);
        if (!std.mem.eql(u8, admission.sessionId(), expected_session_id)) {
            return error.SessionTargetChanged;
        }
        const loaded = try admission.resumeForWrite(alloc, options.log);
        const rebound = try self.finishWorkspaceResume(
            alloc,
            loaded,
            workspace_root,
            true,
            options,
        );
        return self.finishResumedForWrite(alloc, rebound, options);
    }

    fn finishResumedForWrite(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        const needs_permission_migration =
            loaded.state.permission_state.version !=
            session_permission_state.schema_version;
        if (needs_permission_migration) {
            const migrated_permission_state = try session_permission_state.migrateV1ToV2(
                alloc,
                loaded.state.permission_state,
            );
            loaded.state.permission_state.deinit(alloc);
            loaded.state.permission_state = migrated_permission_state;
        }
        var migration_state = try loaded.state.dupe(alloc);
        defer migration_state.deinit(alloc);
        const session_dir = try sessionDirPath(
            alloc,
            self.sessions_dir,
            loaded.active_id,
        );
        defer alloc.free(session_dir);
        const snapshot_dir = try std.fs.path.join(alloc, &.{ session_dir, "images" });
        defer alloc.free(snapshot_dir);
        const needs_image_migration = try session.repair_legacy_images_transactionally(
            alloc,
            migration_state.history,
            snapshot_dir,
        );
        const needs_migration_commit = needs_permission_migration or
            needs_image_migration;
        if (needs_migration_commit) {
            var migration_committed = false;
            errdefer if (!migration_committed) {
                deleteSnapshotFilesAddedByMigration(
                    migration_state.history,
                    loaded.state.history,
                );
            };
            _ = try loaded.commitStateReplacement(
                alloc,
                migration_state,
                .migration,
                .rollback_before_adapter_continue,
                options.log,
            );
            migration_committed = true;
            std.mem.swap(
                session_codec.DurableSessionState,
                &loaded.state,
                &migration_state,
            );
        }
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn resumeLatestForWrite(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        if (self.deferredCacheInvalidatesReads()) {
            return self.resumeLatestDiscoveryAfterBarrier(
                alloc,
                workspace_root,
                options,
            );
        }
        const cached = readLatestPointer(self, alloc, workspace_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (cached) |pointer_value| {
            var pointer = pointer_value;
            defer pointer.deinit(alloc);
            var loaded = self.resumeExactForWrite(
                alloc,
                pointer.session_id,
                workspace_root,
                false,
                options,
            ) catch |cached_error| {
                if (!try latestPointerStillMatches(self, alloc, workspace_root, pointer)) {
                    return self.resumeLatestByDiscovery(alloc, workspace_root, options);
                }
                return switch (cached_error) {
                    error.SessionNotFound,
                    error.SessionTargetChanged,
                    error.InvalidSessionFormat,
                    error.SessionPathUnsafe,
                    => self.resumeLatestByDiscovery(alloc, workspace_root, options),
                    else => cached_error,
                };
            };
            if (std.mem.eql(u8, loaded.state.id, pointer.session_id) and
                std.mem.eql(u8, loaded.state.workspace_root, workspace_root) and
                loaded.state.updated_at_ms == pointer.updated_at_ms)
            {
                const still_matches = latestPointerStillMatches(
                    self,
                    alloc,
                    workspace_root,
                    pointer,
                ) catch |err| {
                    loaded.deinit(alloc);
                    return err;
                };
                if (still_matches) return loaded;
            }
            loaded.deinit(alloc);
        }
        const pending_id = readPendingLatestSessionId(
            self,
            alloc,
            workspace_root,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (pending_id) |observed_id| {
            defer alloc.free(observed_id);
            const barrier_contended = try self.crossLatestBarrier(options.log.test_controls);
            const current_pending = readPendingLatestSessionId(
                self,
                alloc,
                workspace_root,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (current_pending) |session_id| {
                defer alloc.free(session_id);
                try options.log.test_controls.boundary(.latest_barrier_completed);
                var recovered = self.resumeExactForWrite(
                    alloc,
                    session_id,
                    workspace_root,
                    false,
                    options,
                ) catch |err| {
                    return switch (err) {
                        error.SessionNotFound,
                        error.SessionTargetChanged,
                        error.FileNotFound,
                        => if (barrier_contended)
                            self.resumeLatestDiscoveryAfterBarrier(
                                alloc,
                                workspace_root,
                                options,
                            )
                        else
                            self.resumeLatestByDiscovery(alloc, workspace_root, options),
                        else => err,
                    };
                };
                recovered.deinit(alloc);
                return self.resumeLatestByDiscovery(alloc, workspace_root, options);
            }
            return self.resumeLatestDiscoveryAttempt(
                alloc,
                workspace_root,
                options,
            ) catch |err| switch (err) {
                error.SessionNotFound,
                error.FileNotFound,
                => self.resumeLatestByDiscovery(alloc, workspace_root, options),
                else => err,
            };
        }
        return self.resumeLatestByDiscovery(alloc, workspace_root, options);
    }

    fn resumeLatestByDiscovery(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        for (0..2) |attempt| {
            _ = try self.crossLatestBarrier(options.log.test_controls);
            const loaded = self.resumeLatestDiscoveryAttempt(
                alloc,
                workspace_root,
                options,
            ) catch |err| {
                if (attempt == 0 and
                    (err == error.SessionNotFound or err == error.FileNotFound))
                {
                    continue;
                }
                return err;
            };
            return loaded;
        }
        unreachable;
    }

    fn resumeLatestDiscoveryAttempt(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try options.log.test_controls.boundary(.latest_barrier_completed);
        return self.resumeLatestDiscoveryAfterBarrier(alloc, workspace_root, options);
    }

    fn resumeLatestDiscoveryAfterBarrier(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        const selected = try self.selectWritableLastId(
            alloc,
            workspace_root,
            options,
        ) orelse return error.NoSavedSessions;
        defer alloc.free(selected);
        var loaded = try self.resumeExactForWrite(
            alloc,
            selected,
            workspace_root,
            false,
            options,
        );
        errdefer loaded.deinit(alloc);
        self.repairLatestPointer(
            alloc,
            loaded.state,
            loaded.position,
            options.log,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=latest_cache_repair_failed err={s}",
                .{@errorName(err)},
            );
        };
        return loaded;
    }

    fn crossLatestBarrier(
        self: Store,
        test_controls: session_log.TestControls,
    ) !bool {
        var sessions = self.canonical_root.sessions orelse return error.SessionNotFound;
        var context = LatestBarrierLockContext{ .test_controls = test_controls };
        var barrier = io_mod.acquireTimedAdvisoryLockWithOps(
            &sessions,
            latest_sessions_lock_file,
            2000,
            .{
                .ctx = &context,
                .try_lock = LatestBarrierLockContext.tryLock,
            },
        ) catch |err| switch (err) {
            error.LockBusy => return error.SessionBusy,
            error.LockUnsupported => return error.SessionLockUnsupported,
            else => return err,
        };
        barrier.release();
        return context.contention_reported;
    }

    /// Loads a session's full durable state read-only. Caller owns the state.
    pub fn loadReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_codec.DurableSessionState {
        var detail = try self.loadReadOnlyDetail(alloc, session_id, .{});
        detail.summary.deinit(alloc);
        const state = detail.state;
        detail.state = undefined;
        return state;
    }

    /// Reads one bounded chronological history page without acquiring the
    /// session writer lock. The cursor is opaque and anchored to the history
    /// length that produced it, so later appends cannot duplicate older pages.
    pub fn loadHistoryPage(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cursor: ?[]const u8,
        limit: usize,
    ) LoadHistoryPageError!store_types.HistoryPage {
        validateSessionId(session_id) catch return error.InvalidSessionId;
        if (limit == 0 or limit > 100) return error.InvalidHistoryPageLimit;
        const position = if (cursor) |raw| try parseHistoryPageCursor(raw) else null;
        if (position) |value| {
            if (!std.mem.eql(u8, value.session_id, session_id)) return error.InvalidHistoryPageCursor;
        }

        var state = self.loadReadOnly(alloc, session_id) catch |err| return mapHistoryPageLoadError(err);
        defer state.deinit(alloc);

        const snapshot: HistoryPageCursor = if (position) |value| blk: {
            if (value.history_len > state.history.len)
                return error.StaleHistoryPageCursor;
            const digest = historyPrefixDigest(state.history[0..value.history_len]) catch return error.SessionStoreUnavailable;
            if (!std.mem.eql(u8, &value.prefix_digest, &digest)) return error.StaleHistoryPageCursor;
            break :blk value;
        } else .{
            .session_id = state.id,
            .history_len = state.history.len,
            .revision_ms = state.updated_at_ms,
            .prefix_digest = historyPrefixDigest(state.history) catch return error.SessionStoreUnavailable,
            .start = state.history.len,
        };
        const window = selectHistoryPageWindow(state.history.len, snapshot.start, limit);
        const turns = try duplicateHistoryPage(alloc, state.history[window.start..window.end]);
        errdefer session.freeHistoryTurnSlice(alloc, turns);
        const next_cursor = if (window.start > 0) blk: {
            var encoded: [512]u8 = undefined;
            const raw = formatHistoryPageCursor(&encoded, .{
                .session_id = snapshot.session_id,
                .history_len = snapshot.history_len,
                .revision_ms = snapshot.revision_ms,
                .prefix_digest = snapshot.prefix_digest,
                .start = window.start,
            }) catch return error.SessionStoreUnavailable;
            break :blk try alloc.dupe(u8, raw);
        } else null;
        errdefer if (next_cursor) |value| alloc.free(value);
        return .{
            .session_id = try alloc.dupe(u8, state.id),
            .revision_ms = snapshot.revision_ms,
            .history_len = snapshot.history_len,
            .turns = turns,
            .next_cursor = next_cursor,
        };
    }

    /// Opens read-only managed-child storage for a session, validating it loads.
    pub fn openChildCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_child_store.SessionChildCapability {
        var detail = try self.loadReadOnlyDetail(alloc, session_id, .{});
        detail.deinit(alloc);

        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            alloc,
            session_dir.dir,
            display_path,
            .read_only,
        );
    }

    /// Opens child storage for a session id that was already accepted by list
    /// or another caller-owned read-only selection. This avoids replaying the
    /// canonical event log when only managed child routes are needed.
    pub fn openListedChildCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_child_store.SessionChildCapability {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            alloc,
            session_dir.dir,
            display_path,
            .read_only,
        );
    }

    /// Opens verified read-only storage restricted to subagent control files.
    pub fn openSubagentControlCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        return self.openSubagentControlCapabilityMode(
            alloc,
            session_id,
            .read_only,
            options,
        );
    }

    /// Opens verified writable storage restricted to subagent control files.
    /// The returned capability never owns `session.lock` and cannot mutate the
    /// transcript or any other managed-child route.
    pub fn openSubagentControlCapabilityWritable(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        if (self.canonical_root.mode != .writable) return error.SessionStoreUnavailable;
        return self.openSubagentControlCapabilityMode(
            alloc,
            session_id,
            .writable,
            options,
        );
    }

    fn openSubagentControlCapabilityMode(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        mode: session_child_store.Mode,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        validateSessionId(session_id) catch return error.InvalidSessionId;

        var session_dir = self.openSessionDir(session_id) catch |err| return switch (err) {
            error.InvalidSessionId => error.InvalidSessionId,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionStoreUnavailable,
        };
        defer session_dir.close();
        var candidate = classifyReadOnlyCandidate(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionStoreUnavailable,
        };
        candidate.deinit(alloc);
        const display_path = sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSessionId => error.InvalidSessionId,
        };
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.initSubagentControl(
            alloc,
            session_dir.dir,
            display_path,
            mode,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            error.SessionChildStoreFailed => error.SessionChildStoreFailed,
        };
    }

    /// Returns owned session metadata needed to initialize a control record.
    /// This validates ordinary-session visibility without replaying transcript history.
    pub fn loadSubagentBootstrapMetadata(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) LoadSubagentBootstrapError!SubagentBootstrapMetadata {
        validateSessionId(session_id) catch return error.InvalidSessionId;
        var session_dir = self.openSessionDir(session_id) catch |err| return switch (err) {
            error.InvalidSessionId => error.InvalidSessionId,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionMetadataUnavailable,
        };
        defer session_dir.close();
        var candidate = classifyReadOnlyCandidate(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionMetadataUnavailable,
        };
        defer candidate.deinit(alloc);

        const name_source = candidate.summary.title orelse session_id;
        const name = try alloc.dupe(u8, name_source);
        errdefer alloc.free(name);
        return .{
            .name = name,
            .preferences = switch (candidate.storage) {
                .schema_v3 => self.loadSubagentManifestPreferences(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.SessionNotFound => error.SessionNotFound,
                    error.SessionPathUnsafe => error.SessionPathUnsafe,
                    else => error.SessionMetadataUnavailable,
                },
                .legacy_v1, .legacy_v2 => self.loadSubagentLegacyPreferences(
                    alloc,
                    candidate.summary.workspace_root orelse self.workspace_root,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionMetadataUnavailable,
                },
            },
        };
    }

    fn loadSubagentManifestPreferences(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
    ) !session_codec.DurableSessionPreferences {
        _ = self;
        var file = openSessionFile(session_dir, "session.json", .read_only) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(
            alloc,
            &file,
            session_projection.manifest_max_bytes,
        );
        defer alloc.free(bytes);
        var manifest = try session_projection.decodeManifest(alloc, bytes);
        defer manifest.deinit(alloc);
        if (!std.mem.eql(u8, manifest.id, session_id)) return error.InvalidSessionFormat;
        return manifest.preferences.dupe(alloc);
    }

    fn loadSubagentLegacyPreferences(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !session_codec.DurableSessionPreferences {
        var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
            alloc,
            self.home_dir,
            workspace_root,
        );
        defer detailed.deinit(alloc);
        return .{
            .model = try alloc.dupe(
                u8,
                detailed.settings.models.get(.gateway) orelse "anthropic/claude-opus-4.7",
            ),
            .effort = detailed.settings.effort orelse .auto,
            .fast_mode = detailed.settings.fast_mode orelse false,
        };
    }

    fn attachWritableChildCapability(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) !void {
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            loaded.active_id,
        );
        defer alloc.free(display_path);
        const capability = try alloc.create(
            session_child_store.SessionChildCapability,
        );
        errdefer alloc.destroy(capability);
        capability.* = try session_child_store.SessionChildCapability.init(
            alloc,
            loaded.log.dir.dir,
            display_path,
            .writable,
        );
        loaded.child_capability = capability;
    }

    fn makeLatestCacheLifecycle(
        self: Store,
        alloc: Allocator,
        initial_index_effect: InitialIndexEffect,
        test_controls: session_log.TestControls,
    ) !session_log.CommitLifecycle {
        const sessions = &(self.canonical_root.sessions orelse return error.SessionStoreUnavailable);
        const cache = try LatestCache.init(
            alloc,
            sessions,
            test_controls,
            initial_index_effect,
        );
        return .{
            .context = cache,
            .prepare_fn = latestCachePrepare,
            .publish_fn = latestCachePublish,
            .write_deferred_fn = latestCacheWriteDeferred,
            .abort_fn = latestCacheAbort,
            .deinit_fn = latestCacheDeinit,
        };
    }

    fn installLatestCacheLifecycle(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
        test_controls: session_log.TestControls,
    ) !void {
        var lifecycle = try self.makeLatestCacheLifecycle(
            alloc,
            .maintain,
            test_controls,
        );
        errdefer lifecycle.deinit(alloc);
        try loaded.installCommitLifecycle(lifecycle);
    }

    fn repairLatestPointer(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
        options: session_log.Options,
    ) !void {
        try self.publishLatestPointer(
            alloc,
            state,
            position,
            options,
            .maintain,
        );
    }

    fn publishRecoveredLatestPointer(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
        source_session_id: []const u8,
        options: session_log.Options,
    ) !void {
        const sessions = &(self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable);
        for (0..4) |_| {
            const observed_snapshot = try latest_pointer.readLatestSnapshotToken(
                sessions,
                state.workspace_root,
            );
            try options.test_controls.boundary(
                .after_recovery_latest_snapshot,
            );
            var discovered_latest: ?SessionSummary =
                self.latestReadOnlyWorkspaceSummaryFor(
                    alloc,
                    state.workspace_root,
                ) catch |err| switch (err) {
                    error.NoSavedSessions => null,
                    else => return err,
                };
            defer if (discovered_latest) |*summary| summary.deinit(alloc);
            self.publishLatestPointer(
                alloc,
                state,
                position,
                options,
                .{ .replace_latest_if_current = .{
                    .expected_current_id = source_session_id,
                    .discovered_latest = if (discovered_latest) |summary| .{
                        .session_id = summary.id,
                        .updated_at_ms = summary.updated_at_ms,
                    } else null,
                    .observed_snapshot = observed_snapshot,
                } },
            ) catch |err| switch (err) {
                error.SessionLatestBaselineChanged => continue,
                else => return err,
            };
            return;
        }
        return error.SessionLatestBaselineChanged;
    }

    fn publishLatestPointer(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
        options: session_log.Options,
        effect: InitialIndexEffect,
    ) !void {
        const sessions = &(self.canonical_root.sessions orelse return error.SessionStoreUnavailable);
        const cache = try LatestCache.init(
            alloc,
            sessions,
            options.test_controls,
            effect,
        );
        defer cache.deinit(alloc);
        try cache.begin(
            alloc,
            state.id,
            state.workspace_root,
            state.workspace_root,
            options.commit_lock_deadline_ms,
        );
        try cache.publish(alloc, state, position);
    }

    /// Loads a session's summary, state, and storage format read-only, handling
    /// both schema-v3 and legacy snapshots. Caller owns the returned detail.
    pub fn loadReadOnlyDetail(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const authority = try classifyAuthority(alloc, &session_dir, session_id);
        return switch (authority) {
            .schema_v3 => {
                var root = self.canonical_root;
                var state = root.loadReadOnly(alloc, session_id, options.log) catch |err| {
                    return mapReplayError(err);
                };
                errdefer state.deinit(alloc);
                try resolveSessionSnapshotLocators(
                    alloc,
                    state.history,
                    self.sessions_dir,
                    session_id,
                );
                return .{
                    .summary = try summaryFromState(alloc, state),
                    .state = state,
                    .storage_format = .schema_v3,
                };
            },
            .legacy => try self.loadLegacyReadOnlyDetail(
                alloc,
                &session_dir,
                session_id,
                options,
            ),
        };
    }

    /// Lists supported readable sessions newest-first; caller frees each item and the list.
    /// Lists all readable sessions newest-first. Caller frees each item and the list.
    pub fn list(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false);
        return scan.summaries;
    }

    fn deferredCacheInvalidatesReads(self: Store) bool {
        const sessions = &(self.canonical_root.sessions orelse return false);
        return summary_codec.deferredCachePresent(sessions) catch true;
    }

    fn loadDeferredReplayScope(self: Store, alloc: Allocator) DeferredReplayScope {
        const sessions = &(self.canonical_root.sessions orelse return .{ .tokens = .empty });
        const tokens = summary_codec.readDeferredCacheTokens(
            alloc,
            sessions,
        ) catch return .all;
        return .{ .tokens = tokens };
    }

    /// Invalidates the derived resume catalog after managed child ownership
    /// changes. The relationship index remains the canonical authority.
    pub fn invalidateResumableIndex(self: Store, alloc: Allocator) !void {
        if (self.canonical_root.mode != .writable) return error.SessionStoreReadOnly;
        var sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var cache_lock = try io_mod.acquireTimedAdvisoryLock(
            &sessions,
            latest_sessions_lock_file,
            2000,
        );
        defer cache_lock.release();
        try summary_codec.writeSessionIndexMarker(alloc, &sessions);
    }

    /// Returns owned IDs for every readable ordinary session. Caller frees each
    /// ID and the list with the allocator passed here.
    pub fn listSubagentControlSessionIds(
        self: Store,
        alloc: Allocator,
    ) ListSubagentControlIdsError!std.ArrayList([]u8) {
        const scan = self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        };
        var summaries = scan.summaries;
        defer freeSummaries(alloc, &summaries);
        var ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (ids.items) |id| alloc.free(id);
            ids.deinit(alloc);
        }
        for (summaries.items) |summary| {
            const id = try alloc.dupe(u8, summary.id);
            errdefer alloc.free(id);
            try ids.append(alloc, id);
        }
        return ids;
    }

    /// Returns a bounded page of ordinary-session IDs for derived relationship
    /// migration only. These candidates never establish relationship truth.
    pub fn listRelationshipMigrationCandidates(
        self: Store,
        alloc: Allocator,
        continuation: RelationshipMigrationCursor,
    ) ListSubagentControlIdsError!RelationshipMigrationCandidatePage {
        if (self.deferredCacheInvalidatesReads()) {
            return self.listRelationshipMigrationCandidatesFromCanonical(
                alloc,
                continuation,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        }
        var sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        if (self.canonical_root.mode == .read_only) {
            return summary_codec.readRelationshipMigrationCandidatePage(
                alloc,
                &sessions,
                continuation,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        }
        var lock = io_mod.acquireTimedAdvisoryLock(
            &sessions,
            latest_sessions_lock_file,
            2000,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SessionStoreUnavailable,
        };
        defer lock.release();
        return summary_codec.readRelationshipMigrationCandidatePage(
            alloc,
            &sessions,
            continuation,
        ) catch |read_err| switch (read_err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                summary_codec.refreshRelationshipMigrationSnapshot(
                    alloc,
                    &sessions,
                ) catch |refresh_err| return switch (refresh_err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionStoreUnavailable,
                };
                return summary_codec.readRelationshipMigrationCandidatePage(
                    alloc,
                    &sessions,
                    .{},
                ) catch |retry_err| switch (retry_err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionStoreUnavailable,
                };
            },
        };
    }

    fn listRelationshipMigrationCandidatesFromCanonical(
        self: Store,
        alloc: Allocator,
        continuation: RelationshipMigrationCursor,
    ) !RelationshipMigrationCandidatePage {
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        const total = std.math.cast(u64, summaries.items.len) orelse
            return error.SessionStoreUnavailable;
        const same_snapshot = continuation.inode == 0 and
            continuation.mtime_ns == 0 and
            continuation.size == total and
            continuation.offset <= total;
        const start = if (same_snapshot) continuation.offset else 0;
        const remaining = total - start;
        const count = @min(
            remaining,
            summary_codec.relationship_migration_candidate_limit,
        );
        const end = start + count;
        var page = RelationshipMigrationCandidatePage{
            .cursor = .{
                .size = total,
                .offset = end,
            },
            .has_more = end < total,
        };
        errdefer page.deinit(alloc);
        for (summaries.items[@intCast(start)..@intCast(end)]) |summary| {
            try page.ids.append(alloc, try alloc.dupe(u8, summary.id));
        }
        return page;
    }

    /// Persists the unresolved marker before its matching session checkpoint.
    /// The caller must persist the returned timestamp with that checkpoint.
    pub fn prepareUsageRecoveryCheckpoint(
        self: Store,
        alloc: Allocator,
        writable: *const LoadedWritableSession,
        snapshot: session_usage.Snapshot,
    ) !UsageRecoveryCheckpoint {
        const now_ms = @max(io_mod.milliTimestamp(), 0);
        const timestamp_ms = if (now_ms > writable.state.updated_at_ms)
            now_ms
        else
            std.math.add(
                i64,
                writable.state.updated_at_ms,
                1,
            ) catch return error.InvalidSessionFormat;
        const recovery_pending = session_usage.needsProfileRecovery(snapshot);
        if (recovery_pending) {
            const durable_recovery_pending = if (writable.state.usage) |usage|
                session_usage.needsProfileRecovery(usage)
            else
                false;
            const protected_updated_at_ms = if (durable_recovery_pending)
                writable.state.updated_at_ms
            else
                timestamp_ms;
            try self.writeUsageRecoveryPending(
                alloc,
                writable.active_id,
                protected_updated_at_ms,
                !durable_recovery_pending,
            );
        }
        return .{
            .recovery_pending = recovery_pending,
            .timestamp_ms = timestamp_ms,
        };
    }

    /// Completes the marker transition after the matching session checkpoint
    /// is durable.
    pub fn finishUsageRecoveryCheckpoint(
        self: Store,
        session_id: []const u8,
        checkpoint: UsageRecoveryCheckpoint,
    ) !void {
        if (!checkpoint.recovery_pending) {
            try self.clearUsageRecoveryPending(session_id);
        }
    }

    /// Records that this session has profile usage which is not yet proven
    /// durable in the profile ledger.
    pub fn markUsageRecoveryPending(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        protected_updated_at_ms: i64,
    ) !void {
        try self.writeUsageRecoveryPending(
            alloc,
            session_id,
            protected_updated_at_ms,
            true,
        );
    }

    fn writeUsageRecoveryPending(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        protected_updated_at_ms: i64,
        replace_existing: bool,
    ) !void {
        try validateSessionId(session_id);
        if (protected_updated_at_ms < 0) return error.InvalidSessionFormat;
        if (self.canonical_root.mode != .writable) {
            return error.SessionStoreReadOnly;
        }
        _ = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var profile = try openUsageRecoveryProfileRoot(self.home_dir) orelse
            return error.SessionStoreUnavailable;
        defer profile.close();
        var recovery = try io_mod.openOrCreateVerifiedPrivateDir(
            &profile,
            usage_recovery_dir,
        );
        defer recovery.close();
        const existing = validateUsageRecoveryMarker(
            &recovery,
            session_id,
        ) catch |err| switch (err) {
            error.UsageRecoveryMarkerNotFound => null,
            else => return err,
        };
        if (!replace_existing and existing != null) return;
        if (existing) |timestamp_ms| {
            if (timestamp_ms == protected_updated_at_ms) return;
        }
        const marker_bytes = try std.fmt.allocPrint(
            alloc,
            "{s}{d}\n",
            .{ usage_recovery_marker_prefix, protected_updated_at_ms },
        );
        defer alloc.free(marker_bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            &recovery,
            session_id,
            marker_bytes,
        );
    }

    /// Clears a session's recovery marker only after its settled checkpoint is
    /// durable. Missing markers are already clear.
    pub fn clearUsageRecoveryPending(
        self: Store,
        session_id: []const u8,
    ) !void {
        try validateSessionId(session_id);
        if (self.canonical_root.mode != .writable) {
            return error.SessionStoreReadOnly;
        }
        _ = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var recovery = try openUsageRecoveryDir(self.home_dir) orelse return;
        defer recovery.close();
        _ = validateUsageRecoveryMarker(&recovery, session_id) catch |err| switch (err) {
            error.UsageRecoveryMarkerNotFound => return,
            else => return err,
        };
        recovery.dir.deleteFile(io_mod.getIo(), session_id) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
            else => return err,
        };
        try io_mod.syncVerifiedDir(recovery.dir);
    }

    /// Returns the bounded durable recovery marker set. The caller owns every
    /// entry and the list.
    pub fn listUsageRecoverySessions(
        self: Store,
        alloc: Allocator,
    ) !std.ArrayList(UsageRecoverySession) {
        var recovery = try openUsageRecoveryDir(self.home_dir) orelse
            return std.ArrayList(UsageRecoverySession).empty;
        defer recovery.close();

        var marked: std.ArrayList(UsageRecoverySession) = .empty;
        errdefer {
            for (marked.items) |*entry| entry.deinit(alloc);
            marked.deinit(alloc);
        }
        var iter = recovery.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .file or
                marked.items.len == max_usage_recovery_sessions)
            {
                return error.InvalidUsageRecoveryIndex;
            }
            validateSessionId(entry.name) catch
                return error.InvalidUsageRecoveryIndex;
            const protected_updated_at_ms = validateUsageRecoveryMarker(
                &recovery,
                entry.name,
            ) catch return error.InvalidUsageRecoveryIndex;
            try marked.append(alloc, .{
                .id = try alloc.dupe(u8, entry.name),
                .protected_updated_at_ms = protected_updated_at_ms,
            });
        }
        sort_utils.sort(UsageRecoverySession, marked.items, {}, struct {
            fn lessThan(
                _: void,
                left: UsageRecoverySession,
                right: UsageRecoverySession,
            ) bool {
                return std.mem.order(u8, left.id, right.id) == .lt;
            }
        }.lessThan);
        return marked;
    }

    /// Lists readable sessions for this store's workspace newest-first. Caller frees each item and the list.
    pub fn listForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false);
        var summaries = scan.summaries;
        errdefer freeSummaries(alloc, &summaries);
        retainWorkspaceSummaries(alloc, &summaries, self.workspace_root);
        return summaries;
    }

    /// Lists session candidates for workspace-owned managed children. Child
    /// payloads remain the authority when the global index update is pending.
    pub fn listManagedChildCandidatesForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        if (self.canonical_root.sessions) |*sessions| {
            const summaries = readSessionIndexWorkspaceCandidates(
                alloc,
                sessions,
                self.workspace_root,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (summaries) |index| {
                return index;
            }
        }
        return self.listForWorkspace(alloc);
    }

    /// Lists one bounded workspace page newest-first. The canonical summary
    /// index is preferred; discovery remains a read-only fallback for legacy
    /// or damaged indexes.
    pub fn listWorkspacePage(
        self: Store,
        alloc: Allocator,
        continuation: ?ResumableSessionContinuation,
        limit: usize,
    ) ListWorkspacePageError!SessionListPage {
        return self.listSessionPage(
            alloc,
            .current_workspace,
            continuation,
            limit,
        );
    }

    pub fn listSessionPage(
        self: Store,
        alloc: Allocator,
        scope: SessionListScope,
        continuation: ?ResumableSessionContinuation,
        limit: usize,
    ) ListWorkspacePageError!SessionListPage {
        if (limit == 0 or limit > session_list_max_limit) {
            return error.InvalidSessionListLimit;
        }
        const workspace_root: ?[]const u8 = switch (scope) {
            .current_workspace => self.workspace_root,
            .all_workspaces => null,
        };
        if (self.canonical_root.sessions) |*sessions| {
            var indexed_page = summary_codec.readSessionIndexPage(alloc, sessions, .{
                .workspace_root = workspace_root,
                .continuation = continuation,
                .limit = limit,
                .resumable_only = false,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (indexed_page) |*bounded| {
                defer bounded.deinit(alloc);
                var page: SessionListPage = .{
                    .summaries = bounded.summaries,
                    .has_more = bounded.has_more,
                };
                bounded.summaries = .empty;
                if (!summariesMissingDisplayMetadata(page.summaries.items)) {
                    return page;
                }
                page.deinit(alloc);
            }
        }

        var scan = self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionStoreUnavailable,
        };
        defer scan.deinit(alloc);
        var page = sessionListPageFromSummaries(
            alloc,
            scan.summaries.items,
            workspace_root,
            continuation,
            limit,
        ) catch return error.OutOfMemory;
        page.skipped_invalid = scan.skipped_invalid;
        return page;
    }

    /// Lists up to ten resumable sessions after filtering the current and empty sessions.
    pub fn listResumablePage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageForScope(
            alloc,
            .all_workspaces,
            active_id,
            continuation,
        );
    }

    pub fn tryListResumableIndexPage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !?ResumableSessionPage {
        return self.tryListResumableIndexPageForScope(
            alloc,
            .all_workspaces,
            active_id,
            continuation,
        );
    }

    pub fn listResumableWorkspacePage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageForScope(
            alloc,
            .current_workspace,
            active_id,
            continuation,
        );
    }

    pub fn tryListResumableWorkspaceIndexPage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !?ResumableSessionPage {
        return self.tryListResumableIndexPageForScope(
            alloc,
            .current_workspace,
            active_id,
            continuation,
        );
    }

    fn listResumablePageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        if (try self.tryListResumableIndexPageForScope(alloc, scope, active_id, continuation)) |page| {
            return page;
        }
        if (self.canonical_root.mode == .writable) {
            return self.backfillResumablePageForScope(alloc, scope, active_id, continuation);
        }
        return self.listResumablePageFromDiscoveryForScope(alloc, scope, active_id, continuation);
    }

    /// Rewrites the cached title for one indexed session. The index freezes
    /// display metadata once present, so a rename must update it here or the
    /// resume picker keeps serving the previously derived title.
    pub fn updateIndexedTitle(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        title: []const u8,
    ) !void {
        var sessions = self.canonical_root.sessions orelse return error.SessionStoreUnavailable;
        if (self.canonical_root.mode != .writable) return error.SessionStoreReadOnly;
        var summaries = try readSessionIndex(alloc, &sessions);
        defer freeSummaries(alloc, &summaries);

        var found = false;
        for (summaries.items) |*summary| {
            if (!std.mem.eql(u8, summary.id, session_id)) continue;
            const owned = try alloc.dupe(u8, title);
            if (summary.title) |value| alloc.free(value);
            summary.title = owned;
            summary.display_metadata_present = true;
            found = true;
            break;
        }
        if (!found) return;
        try summary_codec.writeSessionIndex(alloc, &sessions, summaries.items);
    }

    fn tryListResumableIndexPageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !?ResumableSessionPage {
        const sessions = &(self.canonical_root.sessions orelse return null);
        const workspace_root = switch (scope) {
            .all_workspaces => null,
            .current_workspace => self.workspace_root,
        };
        const page = summary_codec.readSessionIndexPage(alloc, sessions, .{
            .workspace_root = workspace_root,
            .active_id = active_id,
            .continuation = continuation,
            .limit = self.resume_page_limit,
            .resumable_only = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return try self.hydrateResumablePage(alloc, page);
    }

    fn backfillResumablePageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        var sessions = self.canonical_root.sessions orelse return error.SessionStoreUnavailable;
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        try self.refreshMissingDisplayMetadata(alloc, &summaries);
        var page = try self.resumablePageFromSummariesForScope(
            alloc,
            scope,
            summaries.items,
            active_id,
            continuation,
        );
        errdefer page.deinit(alloc);

        var cache_lock = io_mod.acquireTimedAdvisoryLock(
            &sessions,
            latest_sessions_lock_file,
            0,
        ) catch return page;
        var cache_lock_held = true;
        defer if (cache_lock_held) cache_lock.release();

        if (try self.tryListResumableIndexPageForScope(alloc, scope, active_id, continuation)) |indexed| {
            page.deinit(alloc);
            return indexed;
        }
        var observed = summary_codec.readDeferredCacheTokens(
            alloc,
            &sessions,
        ) catch return page;
        defer summary_codec.freeDeferredCacheTokens(alloc, &observed);
        var repair_summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &repair_summaries);
        try self.refreshMissingDisplayMetadata(alloc, &repair_summaries);
        try writeSessionIndex(alloc, &sessions, repair_summaries.items);
        try removeSessionIndexMarker(&sessions);
        cache_lock.release();
        cache_lock_held = false;
        for (observed.items) |token| {
            var root = self.canonical_root;
            var boundary = root.captureReadBoundary(
                alloc,
                token.session_id,
                .{ .commit_lock_deadline_ms = 0 },
            ) catch |err| switch (err) {
                error.SessionNotFound => {
                    latest_pointer.clearObservedDeferredToken(
                        alloc,
                        &sessions,
                        token,
                    ) catch |clear_err| {
                        debug_trace.logf(
                            "session",
                            "event=deferred_cache_orphan_clear_failed err={s}",
                            .{@errorName(clear_err)},
                        );
                    };
                    continue;
                },
                else => continue,
            };
            defer boundary.deinit();
            if (!latest_pointer.commitPositionCovers(
                boundary.position,
                token.position,
            )) continue;
            latest_pointer.clearObservedDeferredToken(
                alloc,
                &sessions,
                token,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=deferred_cache_token_clear_failed err={s}",
                    .{@errorName(err)},
                );
            };
        }
        return page;
    }

    fn listResumablePageFromDiscoveryForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        return try self.resumablePageFromSummariesForScope(
            alloc,
            scope,
            summaries.items,
            active_id,
            continuation,
        );
    }

    fn resumablePageFromSummariesForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        summaries: []const SessionSummary,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        const workspace_root = switch (scope) {
            .all_workspaces => null,
            .current_workspace => self.workspace_root,
        };
        return try resumablePageFromSummaries(
            alloc,
            summaries,
            workspace_root,
            active_id,
            continuation,
            self.resume_page_limit,
        );
    }

    /// Takes ownership of `page` and refreshes stale display rows when the
    /// source is small enough for bounded first-paint work. Large histories
    /// keep their honest fallback title instead of blocking the whole page.
    fn hydrateResumablePage(
        self: Store,
        alloc: Allocator,
        page: ResumableSessionPage,
    ) !?ResumableSessionPage {
        var owned = page;
        errdefer owned.deinit(alloc);
        if (summariesMissingDisplayMetadata(owned.summaries.items)) {
            try self.refreshMissingDisplayMetadata(alloc, &owned.summaries);
        }
        return owned;
    }

    fn refreshMissingDisplayMetadata(
        self: Store,
        alloc: Allocator,
        summaries: *std.ArrayList(SessionSummary),
    ) !void {
        for (summaries.items) |*summary| {
            if (!summaryNeedsDisplayMetadata(summary.*)) continue;
            if (try self.adoptFrozenSidecar(alloc, summary)) continue;
            const source_bytes = self.displayMetadataReplaySourceBytes(summary.id) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=display_metadata_refresh_deferred id={s} reason=source_unavailable err={s}",
                    .{ summary.id, @errorName(err) },
                );
                continue;
            };
            if (source_bytes > synchronous_display_metadata_replay_max_bytes) {
                debug_trace.logf(
                    "session",
                    "event=display_metadata_refresh_deferred id={s} reason=source_large bytes={d} limit={d}",
                    .{ summary.id, source_bytes, synchronous_display_metadata_replay_max_bytes },
                );
                continue;
            }
            var detail = self.loadReadOnlyDetail(alloc, summary.id, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf(
                        "session",
                        "event=display_metadata_refresh_load_failed id={s} err={s}",
                        .{ summary.id, @errorName(err) },
                    );
                    continue;
                },
            };
            const replacement = detail.summary;
            detail.summary = undefined;
            detail.state.deinit(alloc);

            summary.deinit(alloc);
            summary.* = replacement;
            if (!summary.display_metadata_present) continue;
            if (self.canonical_root.mode == .writable) {
                self.writeDisplaySidecarFromSummary(alloc, summary.*) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => debug_trace.logf(
                        "session",
                        "event=display_sidecar_write_failed id={s} err={s}",
                        .{ summary.id, @errorName(err) },
                    ),
                };
            }
        }
    }

    fn displayMetadataReplaySourceBytes(self: Store, session_id: []const u8) !u64 {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        var events = openSessionFile(&session_dir, "events.jsonl", .read_only) catch |err| switch (err) {
            error.FileNotFound => {
                var legacy = try openSessionFile(&session_dir, "session.json", .read_only);
                defer legacy.close(io_mod.getIo());
                return (try legacy.stat(io_mod.getIo())).size;
            },
            else => return err,
        };
        defer events.close(io_mod.getIo());
        return (try events.stat(io_mod.getIo())).size;
    }

    /// Fills display metadata from an existing frozen sidecar so hydration
    /// replays the event log only when no sidecar is readable.
    fn adoptFrozenSidecar(
        self: Store,
        alloc: Allocator,
        summary: *SessionSummary,
    ) !bool {
        var session_dir = self.openSessionDir(summary.id) catch return false;
        defer session_dir.close();
        var display = session_display_metadata.readSidecarOrFallback(alloc, &session_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf(
                    "session",
                    "event=display_sidecar_adopt_failed id={s} err={s}",
                    .{ summary.id, @errorName(err) },
                );
                return false;
            },
        };
        if (!display.present) {
            display.deinit(alloc);
            return false;
        }
        if (display.origin_workspace_root) |root| alloc.free(root);
        if (summary.title) |value| alloc.free(value);
        if (summary.preview) |value| alloc.free(value);
        summary.title = display.title;
        summary.preview = display.preview;
        summary.display_metadata_present = true;
        return true;
    }

    fn writeDisplaySidecarFromSummary(
        self: Store,
        alloc: Allocator,
        summary: SessionSummary,
    ) !void {
        const title = summary.title orelse return;
        var session_dir = try self.openSessionDir(summary.id);
        defer session_dir.close();
        try session_display_metadata.writeSidecar(
            alloc,
            &session_dir,
            .{
                .present = true,
                .title = title,
                .preview = summary.preview,
                .origin_workspace_root = summary.origin_workspace_root,
            },
        );
    }

    /// Returns the single newest readable session summary, or
    /// `error.NoSavedSessions`. Caller owns it.
    pub fn latestReadOnlySummary(
        self: Store,
        alloc: Allocator,
    ) !SessionSummary {
        var summaries = try self.scanSessionSummaries(
            alloc,
            .global_read_only_last,
        );
        defer summaries.deinit(alloc);
        if (summaries.items.len == 0) return error.NoSavedSessions;
        const latest = summaries.orderedRemove(0);
        for (summaries.items) |*summary| summary.deinit(alloc);
        return latest;
    }

    /// Returns the newest readable session summary for this store's workspace, or
    /// `error.NoSavedSessions`. Caller owns it.
    pub fn latestReadOnlyWorkspaceSummary(
        self: Store,
        alloc: Allocator,
    ) !SessionSummary {
        return self.latestReadOnlyWorkspaceSummaryFor(
            alloc,
            self.workspace_root,
        );
    }

    fn latestReadOnlyWorkspaceSummaryFor(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !SessionSummary {
        var scan = try self.scanSessionSummariesWithDiagnostics(
            alloc,
            .global_read_only_last,
            true,
        );
        defer scan.summaries.deinit(alloc);
        retainWorkspaceSummaries(alloc, &scan.summaries, workspace_root);
        if (scan.summaries.items.len == 0) {
            if (scan.skipped_invalid > 0) return error.NoReadableSessions;
            return error.NoSavedSessions;
        }
        const latest = scan.summaries.orderedRemove(0);
        for (scan.summaries.items) |*summary| summary.deinit(alloc);
        return latest;
    }

    fn scanSessionSummaries(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
    ) !std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, mode, true);
        return scan.summaries;
    }

    /// Scans session directories into summaries. `probe_managed_children`
    /// controls whether each session's subagent relationship index is opened to
    /// resolve `has_managed_children`. Callers that persist summaries via
    /// `writeSessionIndex` or filter with `resumable_only` must pass true;
    /// list-only consumers that never read the field should pass false.
    fn scanSessionSummariesWithDiagnostics(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
        probe_managed_children: bool,
    ) !SessionSummaryScan {
        var scan = SessionSummaryScan{};
        errdefer scan.deinit(alloc);
        var replay_scope = self.loadDeferredReplayScope(alloc);
        defer replay_scope.deinit(alloc);
        var metadata: std.ArrayList(DiscoveryCandidateMetadata) = .empty;
        defer metadata.deinit(alloc);
        if (self.canonical_root.sessions == null) return scan;
        var iter = self.canonical_root.sessions.?.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            var session_dir = self.openSessionDir(entry.name) catch |err| switch (err) {
                else => {
                    logDiscoveryError(mode, entry.name, null, null, err);
                    scan.skipped_invalid += 1;
                    continue;
                },
            };
            var candidate = classifyReadOnlyCandidate(
                alloc,
                &session_dir,
                entry.name,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    session_dir.close();
                    return error.OutOfMemory;
                },
                else => {
                    session_dir.close();
                    logDiscoveryError(mode, entry.name, null, null, err);
                    scan.skipped_invalid += 1;
                    continue;
                },
            };
            session_dir.close();
            if (candidate.storage == .schema_v3 and
                readOnlyScopeRequiresCanonicalReplay(
                    replay_scope,
                    entry.name,
                    candidate.projection_state,
                ))
            {
                var detail = self.loadReadOnlyDetail(
                    alloc,
                    entry.name,
                    .{},
                ) catch |err| {
                    candidate.deinit(alloc);
                    switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            logDiscoveryError(mode, entry.name, null, null, err);
                            scan.skipped_invalid += 1;
                            continue;
                        },
                    }
                };
                candidate.deinit(alloc);
                candidate = .{
                    .summary = detail.summary,
                    .storage = .schema_v3,
                    .projection_state = .current,
                };
                detail.summary = undefined;
                detail.state.deinit(alloc);
                detail = undefined;
            }
            if (probe_managed_children) {
                candidate.summary.has_managed_children =
                    self.sessionHasManagedChildren(alloc, entry.name) catch |err| switch (err) {
                        error.OutOfMemory => {
                            candidate.deinit(alloc);
                            return error.OutOfMemory;
                        },
                        else => false,
                    };
            }
            logDiscovery(
                mode,
                entry.name,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .retained,
                null,
            );
            metadata.append(alloc, .{
                .id = candidate.summary.id,
                .storage = candidate.storage,
                .projection_state = candidate.projection_state,
            }) catch |err| {
                candidate.deinit(alloc);
                return err;
            };
            scan.summaries.append(alloc, candidate.summary) catch |err| {
                candidate.deinit(alloc);
                return err;
            };
            candidate.summary = undefined;
        }
        sortSummariesNewestFirst(scan.summaries.items);
        if (mode == .global_read_only_last and scan.summaries.items.len > 0) {
            for (metadata.items) |candidate| {
                if (!std.mem.eql(u8, candidate.id, scan.summaries.items[0].id)) {
                    continue;
                }
                logDiscovery(
                    mode,
                    candidate.id,
                    candidate.storage,
                    candidate.projection_state,
                    .listable,
                    .selected,
                    null,
                );
                break;
            }
        }
        return scan;
    }

    fn sessionHasManagedChildren(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        var capability = try self.openListedChildCapabilityReadOnly(
            alloc,
            session_id,
        );
        defer capability.deinit();
        var header_file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            session_child_store.subagent_relationship_index_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer header_file.deinit();
        const header_bytes = try header_file.readToEnd(
            alloc,
            relationship_index_codec.max_header_bytes,
        );
        defer alloc.free(header_bytes);
        const header = try relationship_index_codec.decodeHeader(header_bytes);
        if (header.active_count_known) return header.active_count != 0;

        var page_number: u64 = 0;
        var offset: u64 = 0;
        while (offset < header.high_watermark) : (page_number += 1) {
            const page_name = relationship_index_codec.pageFileName(page_number);
            var page_file = try capability.openFileReadOnly(
                alloc,
                .subagent_control,
                &page_name,
            );
            defer page_file.deinit();
            const page_bytes = try page_file.readToEnd(
                alloc,
                relationship_index_codec.max_page_bytes,
            );
            defer alloc.free(page_bytes);
            const page = try relationship_index_codec.decodePage(
                page_bytes,
                page_number,
                header.storage_epoch,
            );
            const remaining = header.high_watermark - offset;
            const slots_to_read: usize = @intCast(@min(
                remaining,
                relationship_index_codec.page_slots,
            ));
            for (page.slots[0..slots_to_read]) |slot| {
                if (slot.occupied) return true;
            }
            offset += @intCast(slots_to_read);
        }
        return false;
    }

    /// Reads the aggregate summary cache, or null when absent/unreadable.
    pub fn readStateSummary(self: Store, alloc: Allocator) !?StateSummary {
        const path = try summaryPath(alloc, self.sessions_dir);
        defer alloc.free(path);
        return readSessionStateSummary(alloc, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionIndexNotFound, error.InvalidSessionIndex => return null,
            else => return null,
        };
    }

    /// Runs `doctor` over every session and returns one diagnostic per problem
    /// found. Caller frees the list.
    pub fn inspectForDoctor(
        self: Store,
        alloc: Allocator,
    ) !std.ArrayList(DoctorDiagnostic) {
        var result = try self.inspectForDoctorReportWithOptions(alloc, .{}, null);
        return result.takeDiagnostics();
    }

    fn inspectForDoctorWithOptions(
        self: Store,
        alloc: Allocator,
        options: DoctorInspectionOptions,
    ) !std.ArrayList(DoctorDiagnostic) {
        var result = try self.inspectForDoctorReportWithOptions(alloc, options, null);
        return result.takeDiagnostics();
    }

    /// Runs `doctor` over up to `max_valid_sessions` valid session directories.
    /// Caller frees the returned result.
    pub fn inspectForDoctorBounded(
        self: Store,
        alloc: Allocator,
        max_valid_sessions: usize,
    ) !DoctorInspectionResult {
        return self.inspectForDoctorReportWithOptions(alloc, .{}, max_valid_sessions);
    }

    fn inspectForDoctorReportWithOptions(
        self: Store,
        alloc: Allocator,
        options: DoctorInspectionOptions,
        max_valid_sessions: ?usize,
    ) !DoctorInspectionResult {
        var result: DoctorInspectionResult = .{};
        errdefer result.deinit(alloc);
        if (self.canonical_root.sessions == null) return result;

        var iterator = self.canonical_root.sessions.?.dir.iterate();
        while (try iterator.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            if (max_valid_sessions) |limit| {
                if (result.inspected_count >= limit) {
                    result.truncated = true;
                    break;
                }
            }
            result.inspected_count += 1;
            var session_dir = self.openSessionDir(entry.name) catch |err| {
                try appendDoctorDiagnostic(
                    &result.diagnostics,
                    alloc,
                    entry.name,
                    if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                    null,
                );
                continue;
            };
            inspectDoctorSession(
                self.ctx(),
                alloc,
                &result.diagnostics,
                &session_dir,
                entry.name,
                options,
            ) catch |err| {
                session_dir.close();
                if (err == error.OutOfMemory) return err;
                try appendDoctorDiagnostic(
                    &result.diagnostics,
                    alloc,
                    entry.name,
                    if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                    null,
                );
                continue;
            };
            session_dir.close();
        }
        return result;
    }

    /// Opens the named session writable and deletes its orphaned artifacts,
    /// returning a report of what was removed.
    pub fn cleanupForDoctor(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_log.CleanupReport {
        var writable_store = try Store.initFromHome(
            alloc,
            self.home_dir,
            self.workspace_root,
        );
        defer writable_store.deinit(alloc);
        var loaded = try writable_store.canonical_root.resumeForWrite(
            alloc,
            session_id,
            .{ .resolve_authority_intent = false },
        );
        defer loaded.deinit(alloc);
        return loaded.cleanupOrphans(alloc, .delete);
    }

    fn openSessionDir(
        self: Store,
        session_id: []const u8,
    ) !io_mod.VerifiedDir {
        try validateSessionId(session_id);
        const sessions = self.canonical_root.sessions orelse
            return error.SessionNotFound;
        var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer dir.close(io_mod.getIo());
        const stat = try dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.SessionPathUnsafe;
        return .{ .dir = dir };
    }

    fn loadLegacyReadOnlyDetail(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        try requireAuthorityFenceAbsent(alloc, session_dir, session_id);
        var file = openSessionFile(
            session_dir,
            "session.json",
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        const max_bytes = if (options.allow_large_legacy)
            stat.size
        else
            automatic_legacy_max_bytes;
        if (stat.size > max_bytes) return error.LegacySessionTooLarge;
        const bytes = readExactLegacyFile(alloc, &file, stat.size) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionReadResourceExhausted,
            else => return err,
        };
        defer alloc.free(bytes);
        var legacy = session_json.parseLegacyExact(
            LegacyStoredSession,
            alloc,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionReadResourceExhausted,
            else => return err,
        };
        errdefer legacy.deinit(alloc);
        if (!std.mem.eql(u8, legacy.id, session_id)) return error.InvalidSessionFormat;
        try requireAuthorityFenceAbsent(alloc, session_dir, session_id);

        const schema = try session_json.parseLegacySchemaVersion(alloc, bytes);
        var state = try legacyToDurableState(
            self.ctx(),
            alloc,
            &legacy,
            self.workspace_root,
            .preserved_workspace,
            options.seed_preferences,
        );
        errdefer state.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            state.history,
            self.sessions_dir,
            session_id,
        );
        return .{
            .summary = try summaryFromState(alloc, state),
            .state = state,
            .storage_format = storageFormatForLegacy(schema),
        };
    }

    fn resumeExactForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        allow_rebind: bool,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const authority = classifyAuthority(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| switch (err) {
            error.SessionAuthorityBoundaryUnavailable => {
                const recovered = try self.resolveAuthorityTransitionForWrite(
                    alloc,
                    session_id,
                    workspace_root,
                    .requesting_workspace,
                    options,
                );
                return self.finishWorkspaceResume(
                    alloc,
                    recovered,
                    workspace_root,
                    allow_rebind,
                    options,
                );
            },
            else => return err,
        };
        const loaded = switch (authority) {
            .schema_v3 => blk: {
                var root = self.canonical_root;
                break :blk root.resumeForWrite(
                    alloc,
                    session_id,
                    options.log,
                ) catch |err| return mapReplayError(err);
            },
            .legacy => try self.migrateLegacyForWrite(
                alloc,
                session_id,
                workspace_root,
                .requesting_workspace,
                options,
            ),
        };
        return self.finishWorkspaceResume(
            alloc,
            loaded,
            workspace_root,
            allow_rebind,
            options,
        );
    }

    fn finishWorkspaceResume(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        workspace_root: []const u8,
        allow_rebind: bool,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            loaded.state.history,
            self.sessions_dir,
            loaded.active_id,
        );

        if (loaded.commit_lifecycle == null) {
            try self.installLatestCacheLifecycle(
                alloc,
                &loaded,
                options.log.test_controls,
            );
        }

        if (std.mem.eql(u8, loaded.state.workspace_root, workspace_root)) {
            return loaded;
        }
        if (!allow_rebind) return error.SessionTargetChanged;

        const rebound = session_event.Event{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast(workspace_root),
        } };
        _ = loaded.appendEvent(
            alloc,
            rebound,
            io_mod.milliTimestamp(),
            .rollback_before_adapter_continue,
            options.log,
        ) catch |err| switch (err) {
            error.SessionPersistenceDegraded => return error.SessionWorkspaceRebindFailed,
            else => return err,
        };
        return loaded;
    }

    fn selectWritableLastId(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !?[]u8 {
        try validateWorkspaceRoot(workspace_root);
        if (self.canonical_root.sessions == null) return null;
        var replay_scope = self.loadDeferredReplayScope(alloc);
        defer replay_scope.deinit(alloc);

        var selected: ?WritableCandidate = null;
        defer if (selected) |*candidate| candidate.deinit(alloc);
        var iter = self.canonical_root.sessions.?.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            var candidate = self.resolveWritableCandidate(
                alloc,
                entry.name,
                workspace_root,
                options,
            ) catch |err| switch (err) {
                error.OutOfMemory,
                error.SessionAuthorityBoundaryUnavailable,
                error.SessionCommitBoundaryUnavailable,
                => return err,
                else => {
                    logDiscoveryError(
                        .workspace_writable_last,
                        entry.name,
                        null,
                        null,
                        err,
                    );
                    return err;
                },
            };
            if (candidate.storage == .schema_v3 and
                candidate.projection_state == .current and
                tokenScopeRequiresCanonicalReplay(replay_scope, entry.name))
            {
                var root = self.canonical_root;
                var state = root.loadReadOnly(
                    alloc,
                    entry.name,
                    options.log,
                ) catch |err| {
                    candidate.deinit(alloc);
                    return mapReplayError(err);
                };
                defer state.deinit(alloc);
                candidate.deinit(alloc);
                candidate = try dupeWritableCandidate(
                    alloc,
                    state.id,
                    state.workspace_root,
                    state.updated_at_ms,
                    .schema_v3,
                    .current,
                );
            }
            if (!std.mem.eql(u8, candidate.workspace_root, workspace_root)) {
                logDiscovery(
                    .workspace_writable_last,
                    candidate.id,
                    candidate.storage,
                    candidate.projection_state,
                    .workspace_mismatch,
                    .skipped,
                    null,
                );
                candidate.deinit(alloc);
                continue;
            }
            logDiscovery(
                .workspace_writable_last,
                candidate.id,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .retained,
                null,
            );
            if (selected == null or writableCandidateNewer(candidate, selected.?)) {
                if (selected) |*old| old.deinit(alloc);
                selected = candidate;
            } else {
                candidate.deinit(alloc);
            }
        }
        if (selected) |candidate| {
            logDiscovery(
                .workspace_writable_last,
                candidate.id,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .selected,
                null,
            );
            return try alloc.dupe(u8, candidate.id);
        }
        return null;
    }

    fn resolveWritableCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !WritableCandidate {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        return switch (try classifyAuthority(alloc, &session_dir, session_id)) {
            .legacy => {
                var candidate = try classifyLegacyCandidate(
                    alloc,
                    &session_dir,
                    session_id,
                );
                defer candidate.deinit(alloc);
                return dupeWritableCandidate(
                    alloc,
                    candidate.summary.id,
                    candidate.summary.workspace_root orelse self.workspace_root,
                    candidate.summary.updated_at_ms,
                    candidate.storage,
                    .current,
                );
            },
            .schema_v3 => {
                var projected: ?ReadOnlyCandidate = null;
                defer if (projected) |*candidate| candidate.deinit(alloc);
                if (classifySchemaV3Candidate(
                    alloc,
                    &session_dir,
                    session_id,
                )) |candidate_value| {
                    projected = candidate_value;
                    const candidate = projected.?;
                    if (candidate.projection_state == .current) {
                        return dupeWritableCandidate(
                            alloc,
                            candidate.summary.id,
                            candidate.summary.workspace_root.?,
                            candidate.summary.updated_at_ms,
                            .schema_v3,
                            .current,
                        );
                    }
                } else |err| switch (err) {
                    error.OutOfMemory,
                    error.UnsupportedSessionSchema,
                    error.SessionAuthorityBoundaryUnavailable,
                    => return err,
                    else => {},
                }

                var root = self.canonical_root;
                var state = root.loadReadOnly(
                    alloc,
                    session_id,
                    options.log,
                ) catch |err| {
                    const mapped = mapReplayError(err);
                    if (mapped != error.SessionCommitBoundaryUnavailable) return mapped;
                    const candidate = projected orelse return mapped;
                    if (std.mem.eql(
                        u8,
                        candidate.summary.workspace_root.?,
                        workspace_root,
                    )) return mapped;
                    return dupeWritableCandidate(
                        alloc,
                        candidate.summary.id,
                        candidate.summary.workspace_root.?,
                        candidate.summary.updated_at_ms,
                        .schema_v3,
                        .stale,
                    );
                };
                defer state.deinit(alloc);
                return dupeWritableCandidate(
                    alloc,
                    state.id,
                    state.workspace_root,
                    state.updated_at_ms,
                    .schema_v3,
                    .stale,
                );
            },
        };
    }

    fn migrateLegacyForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded: LoadedWritableSession = undefined;
        try self.migrateLegacyForWriteInto(
            &loaded,
            alloc,
            session_id,
            workspace_root,
            preference_source,
            options,
        );
        return loaded;
    }

    // Keep cold fallible constructors behind noinline out-parameter boundaries
    // so error returns do not materialize the full LoadedWritableSession payload.
    noinline fn migrateLegacyForWriteInto(
        self: Store,
        out: *LoadedWritableSession,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !void {
        if (self.canonical_root.mode != .writable or
            self.canonical_root.sessions == null)
        {
            return error.SessionStoreUnavailable;
        }
        var dir = self.canonical_root.sessions.?.dir.openDir(
            io_mod.getIo(),
            session_id,
            .{
                .iterate = true,
                .follow_symlinks = false,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        prepareWritableSessionDir(dir) catch |err| {
            dir.close(io_mod.getIo());
            return err;
        };
        var verified = io_mod.VerifiedDir{ .dir = dir };
        var writer_lock = io_mod.acquireTimedAdvisoryLock(
            &verified,
            "session.lock",
            options.log.session_lock_deadline_ms,
        ) catch |err| switch (err) {
            error.LockBusy => return error.SessionBusy,
            error.LockUnsupported => return error.SessionLockUnsupported,
            else => return err,
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close(io_mod.getIo());
            return err;
        };
        var writable = session_log.WritableSessionDir{
            .dir = verified,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
        const loaded = self.migrateLegacyWithLatestCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        ) catch |err| {
            writable.deinit(alloc);
            return err;
        };
        out.* = loaded;
    }

    fn migrateLegacyWithLatestCache(
        self: Store,
        alloc: Allocator,
        writable: *session_log.WritableSessionDir,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var lifecycle: ?session_log.CommitLifecycle = try self.makeLatestCacheLifecycle(
            alloc,
            .maintain,
            options.log.test_controls,
        );
        errdefer if (lifecycle) |*value| value.deinit(alloc);
        return migrateLegacyLocked(
            self.ctx(),
            alloc,
            writable,
            workspace_root,
            preference_source,
            options,
            &lifecycle,
        );
    }

    fn resolveAuthorityTransitionForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded: LoadedWritableSession = undefined;
        try self.resolveAuthorityTransitionForWriteInto(
            &loaded,
            alloc,
            session_id,
            workspace_root,
            preference_source,
            options,
        );
        return loaded;
    }

    noinline fn resolveAuthorityTransitionForWriteInto(
        self: Store,
        out: *LoadedWritableSession,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !void {
        var read_dir = try self.openSessionDir(session_id);
        var transition = (try loadAuthorityTransitionOptional(
            alloc,
            &read_dir,
        )) orelse {
            read_dir.close();
            return error.SessionAuthorityBoundaryUnavailable;
        };
        read_dir.close();
        defer transition.deinit(alloc);
        try requireAuthorityTransitionSession(transition, session_id);

        if (transition.kind == .session_create) {
            var root = self.canonical_root;
            const loaded = try root.resumeForWrite(
                alloc,
                session_id,
                options.log,
            );
            out.* = loaded;
            return;
        }

        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.log.session_lock_deadline_ms,
        );
        var commit_lock = io_mod.acquireTimedAdvisoryLock(
            &writable.dir,
            "commit.lock",
            options.log.commit_lock_deadline_ms,
        ) catch |err| {
            writable.deinit(alloc);
            return switch (err) {
                error.LockBusy, error.LockUnsupported => error.SessionCommitBoundaryUnavailable,
                else => err,
            };
        };
        var commit_lock_held = true;
        defer if (commit_lock_held) commit_lock.release();
        errdefer writable.deinit(alloc);

        var current = (try loadAuthorityTransitionOptional(
            alloc,
            &writable.dir,
        )) orelse return error.SessionAuthorityBoundaryUnavailable;
        defer current.deinit(alloc);
        try requireAuthorityTransitionSession(current, session_id);
        if (!authorityTransitionsEqual(current, transition)) {
            return error.InvalidSessionFormat;
        }

        const target_state: ?session_codec.DurableSessionState =
            validateMigrationTarget(
                alloc,
                &writable.dir,
                session_id,
                current.authority_id,
                current.proposed,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
                else => null,
            };
        if (target_state) |validated_state| {
            var state = validated_state;
            errdefer state.deinit(alloc);
            var lifecycle = try self.makeLatestCacheLifecycle(
                alloc,
                .maintain,
                options.log.test_controls,
            );
            errdefer lifecycle.deinit(alloc);
            try lifecycle.prepare(
                alloc,
                writable.session_id,
                state.workspace_root,
                state.workspace_root,
                options.log.commit_lock_deadline_ms,
            );
            io_mod.syncVerifiedDir(writable.dir.dir) catch
                return error.LegacySessionMigrationIndeterminate;
            deleteSessionEntry(
                &writable.dir,
                "authority.pending.json",
            ) catch return error.SessionAuthorityIntentCleanupPending;
            commit_lock.release();
            commit_lock_held = false;
            var loaded = try loadedMigrationTarget(
                alloc,
                &writable,
                state,
                current,
            );
            state = undefined;
            errdefer loaded.deinit(alloc);
            try loaded.installCommitLifecycle(lifecycle);
            _ = loaded.publishCommitLifecycle(alloc);
            out.* = loaded;
            return;
        }

        try restoreLegacyAuthority(alloc, &writable, current);
        commit_lock.release();
        commit_lock_held = false;
        const loaded = try self.migrateLegacyWithLatestCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        );
        out.* = loaded;
    }

    fn openWritableSessionDir(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        session_lock_deadline_ms: u64,
    ) !session_log.WritableSessionDir {
        const sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        prepareWritableSessionDir(dir) catch |err| {
            dir.close(io_mod.getIo());
            return err;
        };
        var verified = io_mod.VerifiedDir{ .dir = dir };
        var writer_lock = io_mod.acquireTimedAdvisoryLock(
            &verified,
            "session.lock",
            session_lock_deadline_ms,
        ) catch |err| {
            dir.close(io_mod.getIo());
            return switch (err) {
                error.LockBusy => error.SessionBusy,
                error.LockUnsupported => error.SessionLockUnsupported,
                else => err,
            };
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close(io_mod.getIo());
            return err;
        };
        return .{
            .dir = verified,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
    }

    /// Migrates a legacy session to schema-v3 in place without returning a live
    /// session, reporting the source schema/bytes. Idempotent on already-current
    /// sessions. Caller owns the returned result.
    pub fn migrateLegacyStorageOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: MigrationOptions,
    ) !SessionMigrationResult {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        const authority = (if (options.allow_large)
            classifyAuthorityAllowingLargeLegacy(alloc, &session_dir, session_id)
        else
            classifyAuthority(alloc, &session_dir, session_id)) catch |err| switch (err) {
            error.SessionAuthorityBoundaryUnavailable => {
                var transition = (try loadAuthorityTransitionOptional(
                    alloc,
                    &session_dir,
                )) orelse {
                    session_dir.close();
                    return error.SessionAuthorityBoundaryUnavailable;
                };
                defer transition.deinit(alloc);
                try requireAuthorityTransitionSession(transition, session_id);
                session_dir.close();
                var resolved = try self.resolveAuthorityTransitionForWrite(
                    alloc,
                    session_id,
                    self.workspace_root,
                    .preserved_workspace,
                    .{
                        .allow_large_legacy = options.allow_large,
                        .seed_preferences = options.seed_preferences,
                        .log = options.log,
                    },
                );
                defer resolved.deinit(alloc);
                if (transition.kind == .session_create) {
                    return .{
                        .session_id = try alloc.dupe(u8, session_id),
                        .source_schema_version = 3,
                        .source_bytes = 0,
                        .status = .already_current,
                    };
                }
                const source_schema_version = resolved.migration_source_schema_version orelse try migratedSourceSchemaVersion(
                    alloc,
                    &resolved.log.dir,
                    options.allow_large,
                );
                const source_bytes = resolved.migration_source_bytes orelse try migratedSourceBytes(&resolved.log.dir);
                return .{
                    .session_id = try alloc.dupe(u8, session_id),
                    .source_schema_version = source_schema_version,
                    .source_bytes = source_bytes,
                    .status = .migrated,
                };
            },
            else => {
                session_dir.close();
                return err;
            },
        };
        session_dir.close();
        if (authority == .schema_v3) {
            return .{
                .session_id = try alloc.dupe(u8, session_id),
                .source_schema_version = 3,
                .source_bytes = 0,
                .status = .already_current,
            };
        }
        var migrated = try self.migrateLegacyForWrite(
            alloc,
            session_id,
            self.workspace_root,
            .preserved_workspace,
            .{
                .allow_large_legacy = options.allow_large,
                .seed_preferences = options.seed_preferences,
                .log = options.log,
            },
        );
        defer migrated.deinit(alloc);
        const source_schema_version = migrated.migration_source_schema_version orelse try migratedSourceSchemaVersion(
            alloc,
            &migrated.log.dir,
            options.allow_large,
        );
        const source_bytes = migrated.migration_source_bytes orelse try migratedSourceBytes(&migrated.log.dir);
        return .{
            .session_id = try alloc.dupe(u8, session_id),
            .source_schema_version = source_schema_version,
            .source_bytes = source_bytes,
            .status = .migrated,
        };
    }

    /// Creates a new schema-v3 session from the exact validated manifest
    /// boundary of a source whose commit watermark is corrupt. The source is
    /// locked for the read and is never modified.
    pub fn recoverSessionCopy(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_log.Options,
    ) !SessionRecoveryResult {
        try validateSessionId(session_id);
        var source = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
        );
        defer source.deinit(alloc);
        const authority = try classifyAuthority(
            alloc,
            &source.dir,
            session_id,
        );
        if (authority != .schema_v3) {
            return error.SessionRecoveryRequiresCurrentSchema;
        }
        var manifest_file = openSessionFile(
            &source.dir,
            "session.json",
            .read_only,
        ) catch return error.SessionRecoveryBoundaryInvalid;
        defer manifest_file.close(io_mod.getIo());
        const manifest_stat = try manifest_file.stat(io_mod.getIo());
        if (manifest_stat.size > session_projection.manifest_max_bytes) {
            return error.SessionRecoveryBoundaryInvalid;
        }
        const manifest_bytes = readExactLegacyFile(
            alloc,
            &manifest_file,
            manifest_stat.size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionRecoveryBoundaryInvalid,
        };
        defer alloc.free(manifest_bytes);
        const manifest_schema = authority_module.manifestSchemaVersion(
            alloc,
            manifest_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionRecoveryBoundaryInvalid,
        };
        if (manifest_schema != 3) {
            return error.SessionRecoveryUnsupportedSchema;
        }

        var recovered = session_log.recoverManifestBoundary(
            alloc,
            &source,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory,
            error.SessionRecoveryNotNeeded,
            error.SessionAuthorityBoundaryUnavailable,
            error.SessionCommitBoundaryUnavailable,
            error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            => return err,
            error.UnsupportedSessionSchema => return error.SessionRecoveryUnsupportedSchema,
            else => return error.SessionRecoveryBoundaryInvalid,
        };
        defer recovered.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            recovered.history,
            self.sessions_dir,
            session_id,
        );
        const source_dir_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(source_dir_path);
        var source_children = try session_child_store.SessionChildCapability.init(
            alloc,
            source.dir.dir,
            source_dir_path,
            .read_only,
        );
        defer source_children.deinit();

        const source_id = try alloc.dupe(u8, recovered.id);
        errdefer alloc.free(source_id);
        const recovered_id = try generateSessionId(alloc);
        errdefer alloc.free(recovered_id);
        const replacement_id = try alloc.dupe(u8, recovered_id);
        alloc.free(recovered.id);
        recovered.id = replacement_id;

        var initial = try recoveryInitialState(alloc, recovered);
        defer initial.deinit(alloc);
        var staging_lock = try self.acquireRecoveryStagingLock(
            options.session_lock_deadline_ms,
        );
        defer staging_lock.release();
        var staging_root = try self.initRecoveryStagingRoot(alloc);
        defer self.deinitRecoveryStagingRoot(alloc, &staging_root);
        try cleanupAbandonedRecoveryStages(&staging_root);
        var target = try self.startRecoveryStagedSession(
            alloc,
            &staging_root,
            initial,
            options,
        );
        var target_owned = true;
        var target_promoted = false;
        errdefer if (target_owned) {
            if (target_promoted) {
                target.deinit(alloc);
            } else {
                const disposition = discardRecoveryStagedSession(
                    &staging_root,
                    alloc,
                    &target,
                );
                if (disposition != .discarded) {
                    debug_trace.logf(
                        "session",
                        "event=session_recovery_unpublished_target_cleanup disposition={s}",
                        .{@tagName(disposition)},
                    );
                }
            }
            target_owned = false;
        };

        const staged_target_dir = try sessionDirPath(
            alloc,
            staging_root.display_root,
            recovered_id,
        );
        defer alloc.free(staged_target_dir);
        const staged_target_images = try std.fs.path.join(
            alloc,
            &.{ staged_target_dir, "images" },
        );
        defer alloc.free(staged_target_images);
        const target_dir = try sessionDirPath(
            alloc,
            self.sessions_dir,
            recovered_id,
        );
        defer alloc.free(target_dir);
        const target_images = try std.fs.path.join(
            alloc,
            &.{ target_dir, "images" },
        );
        defer alloc.free(target_images);
        try copyRecoveredImageSnapshots(
            alloc,
            recovered.history,
            staged_target_images,
        );
        try rebaseRecoveredImageSnapshots(
            alloc,
            recovered.history,
            staged_target_images,
            target_images,
        );
        const contains_unverified_artifacts = try copyRecoveredManagedChildren(
            alloc,
            recovered.history,
            &source_children,
            target.child_capability orelse
                return error.SessionChildStoreFailed,
        );
        _ = target.commitStateReplacement(
            alloc,
            recovered,
            .recovery,
            .rollback_before_adapter_continue,
            options,
        ) catch |commit_err| {
            target.namespace_confirmation_required = true;
            target.validateResumeBoundary(alloc, options) catch |resolve_err| {
                debug_trace.logf(
                    "session",
                    "event=session_recovery_target_indeterminate target={s} commit_err={s} resolve_err={s}",
                    .{
                        recovered_id,
                        @errorName(commit_err),
                        @errorName(resolve_err),
                    },
                );
                const disposition = discardRecoveryStagedSession(
                    &staging_root,
                    alloc,
                    &target,
                );
                target_owned = false;
                if (disposition != .discarded) {
                    debug_trace.logf(
                        "session",
                        "event=session_recovery_staged_target_cleanup disposition={s}",
                        .{@tagName(disposition)},
                    );
                }
                return error.SessionRecoveryIndeterminate;
            };
        };
        if (!try session_log.durableStatesEqual(target.state, recovered)) {
            const disposition = discardRecoveryStagedSession(
                &staging_root,
                alloc,
                &target,
            );
            target_owned = false;
            if (disposition != .discarded) {
                debug_trace.logf(
                    "session",
                    "event=session_recovery_staged_target_cleanup disposition={s}",
                    .{@tagName(disposition)},
                );
            }
            return error.SessionRecoveryIndeterminate;
        }
        target.validateResumeBoundary(alloc, options) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} validation_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            const disposition = discardRecoveryStagedSession(
                &staging_root,
                alloc,
                &target,
            );
            target_owned = false;
            if (disposition != .discarded) {
                debug_trace.logf(
                    "session",
                    "event=session_recovery_staged_target_cleanup disposition={s}",
                    .{@tagName(disposition)},
                );
            }
            return error.SessionRecoveryIndeterminate;
        };
        const promotion = self.promoteRecoveryStagedSession(
            &staging_root,
            recovered_id,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_promotion_failed target={s} err={s}",
                .{ recovered_id, @errorName(err) },
            );
            return error.SessionRecoveryIndeterminate;
        };
        target_promoted = true;
        if (promotion == .indeterminate) {
            target.deinit(alloc);
            target_owned = false;
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        }
        try options.test_controls.boundary(
            .before_recovery_latest_publication,
        );
        self.publishRecoveredLatestPointer(
            alloc,
            recovered,
            target.position,
            source_id,
            options,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} latest_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            target.deinit(alloc);
            target_owned = false;
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        };
        target.deinit(alloc);
        target_owned = false;

        var verified = self.resumeExactForWrite(
            alloc,
            recovered_id,
            recovered.workspace_root,
            false,
            .{ .log = options },
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} verify_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        };
        defer verified.deinit(alloc);
        if (!try session_log.durableStatesEqual(verified.state, recovered)) {
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        }

        return .{
            .source_session_id = source_id,
            .recovered_session_id = recovered_id,
            .history_len = recovered.history.len,
            .status = if (contains_unverified_artifacts)
                .recovered_with_unverified_artifacts
            else
                .recovered,
        };
    }
};

pub const PristineDiscardDisposition = enum {
    discarded,
    retained,
    indeterminate,
};

const RecoveryPromotionStatus = enum {
    promoted,
    indeterminate,
};

fn recoveryInitialState(
    alloc: Allocator,
    recovered: session_codec.DurableSessionState,
) !session_codec.DurableSessionState {
    const id = try alloc.dupe(u8, recovered.id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, recovered.origin_workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, recovered.workspace_root);
    errdefer alloc.free(workspace);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = recovered.created_at_ms,
        .updated_at_ms = recovered.updated_at_ms,
        .conversation_language = recovered.conversation_language,
        .preferences = try recovered.preferences.dupe(alloc),
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn copyRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .background_command => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        for (images) |*image| {
            if (image.snapshot_path == null) continue;
            const copied = image_attachments.copyVerifiedImageAttachmentToDir(
                alloc,
                image.*,
                image.id,
                target_images,
            ) catch |err| switch (err) {
                error.FileNotFound,
                error.InvalidImageId,
                error.MissingImageSnapshot,
                error.InvalidImageSnapshotDigest,
                error.NotRegularFile,
                error.ImageTooLarge,
                error.ImageSnapshotCorrupt,
                error.UnsupportedImageType,
                error.ImageSnapshotMediaTypeMismatch,
                => return error.SessionRecoveryBoundaryInvalid,
                else => return err,
            };
            core_types.freeImageAttachment(alloc, image.*);
            image.* = copied;
        }
    }
}

fn rebaseRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    staged_images: []const u8,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .background_command => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        for (images) |*image| {
            const staged_path = image.snapshot_path orelse continue;
            const parent = std.fs.path.dirname(staged_path) orelse
                return error.SessionRecoveryBoundaryInvalid;
            if (!std.mem.eql(u8, parent, staged_images)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const leaf = std.fs.path.basename(staged_path);
            const target_path = try std.fs.path.join(
                alloc,
                &.{ target_images, leaf },
            );
            alloc.free(staged_path);
            image.snapshot_path = target_path;
        }
    }
}

fn copyRecoveredManagedChildren(
    alloc: Allocator,
    history: []session.HistoryTurn,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
) !bool {
    var contains_unverified_artifacts = false;
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| &entry.execution,
            .background_command => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
        };
        for (execution.tool_steps) |*step| {
            for (step.tool_results) |*result| {
                if (result.output_handle) |handle| {
                    try copyRecoveredManagedChild(
                        alloc,
                        source,
                        target,
                        .tool_results,
                        handle,
                        result.stored_output_bytes,
                    );
                }
                if (result.command_output_replay) |replay| {
                    contains_unverified_artifacts =
                        (try copyRecoveredCommandReplay(
                            alloc,
                            source,
                            target,
                            replay,
                        )) or contains_unverified_artifacts;
                }
            }
        }
        if (turn.* == .interrupted) {
            const presentation = if (turn.interrupted.cancelled_command) |*value|
                value
            else
                continue;
            if (presentation.output_replay) |replay| {
                contains_unverified_artifacts =
                    (try copyRecoveredCommandReplay(
                        alloc,
                        source,
                        target,
                        replay,
                    )) or contains_unverified_artifacts;
            }
            if (presentation.command_artifact_handle) |handle| {
                const authenticated = artifact_digest.hasContentDigest(
                    handle,
                    ".log",
                );
                try copyRecoveredManagedChild(
                    alloc,
                    source,
                    target,
                    .command_artifacts,
                    handle,
                    null,
                );
                if (!authenticated) contains_unverified_artifacts = true;
            }
        }
    }
    return contains_unverified_artifacts;
}

fn copyRecoveredCommandReplay(
    alloc: Allocator,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    replay: core_types.CommandOutputReplay,
) !bool {
    switch (replay) {
        .available => |descriptor| {
            const authenticated = command_replay_store.hasContentDigest(
                descriptor.handle,
            );
            try copyRecoveredManagedChild(
                alloc,
                source,
                target,
                .command_artifacts,
                descriptor.handle,
                descriptor.framed_bytes,
            );
            var reader = command_replay_store.Reader.open(
                alloc,
                target,
                descriptor,
            ) catch return error.SessionRecoveryBoundaryInvalid;
            defer reader.deinit();
            while (reader.nextByte() catch
                return error.SessionRecoveryBoundaryInvalid) |_|
            {}
            return !authenticated;
        },
        .unavailable => return false,
    }
}

fn copyRecoveredManagedChild(
    alloc: Allocator,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    kind: session_child_store.ManagedChildKind,
    handle: []const u8,
    expected_bytes: ?usize,
) !void {
    var source_file = source.openFileReadOnly(
        alloc,
        kind,
        handle,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionRecoveryBoundaryInvalid,
        else => return err,
    };
    defer source_file.deinit();
    const source_stat = try source_file.stat();
    if (expected_bytes) |expected| {
        const expected_u64 = std.math.cast(u64, expected) orelse
            return error.SessionRecoveryBoundaryInvalid;
        if (source_stat.size != expected_u64) {
            return error.SessionRecoveryBoundaryInvalid;
        }
    }
    var target_file = target.createExclusiveFile(
        alloc,
        kind,
        handle,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var existing = try target.openFileReadOnly(alloc, kind, handle);
            defer existing.deinit();
            const existing_stat = try existing.stat();
            if (existing_stat.size != source_stat.size) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const source_digest = try managedFileDigest(
                &source_file,
                source_stat.size,
            );
            const existing_digest = try managedFileDigest(
                &existing,
                existing_stat.size,
            );
            if (!std.mem.eql(u8, &source_digest, &existing_digest)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            try validateRecoveredManagedChildDigest(
                kind,
                handle,
                expected_bytes,
                source_digest,
            );
            return;
        },
        else => return err,
    };
    var copied = false;
    defer {
        target_file.deinit();
        if (!copied) target.delete(kind, handle) catch {};
    }

    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (offset < source_stat.size) {
        const remaining = source_stat.size - offset;
        const chunk_len = std.math.cast(
            usize,
            @min(remaining, buffer.len),
        ) orelse return error.SessionChildStoreFailed;
        const read_len = source_file.readRangeInto(
            offset,
            buffer[0..chunk_len],
        ) catch return error.SessionRecoveryBoundaryInvalid;
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        source_hasher.update(buffer[0..read_len]);
        try target_file.writeAll(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionChildStoreFailed;
    }
    try target_file.sync();
    var source_digest: [32]u8 = undefined;
    source_hasher.final(&source_digest);
    try validateRecoveredManagedChildDigest(
        kind,
        handle,
        expected_bytes,
        source_digest,
    );
    var target_reader = try target.openFileReadOnly(alloc, kind, handle);
    defer target_reader.deinit();
    const target_digest = try managedFileDigest(
        &target_reader,
        source_stat.size,
    );
    if (!std.mem.eql(u8, &source_digest, &target_digest)) {
        return error.SessionChildStoreFailed;
    }
    copied = true;
}

fn managedFileDigest(
    file: *session_child_store.ManagedFile,
    size: u64,
) ![32]u8 {
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (offset < size) {
        const remaining = size - offset;
        const chunk_len = std.math.cast(
            usize,
            @min(remaining, buffer.len),
        ) orelse return error.SessionRecoveryBoundaryInvalid;
        const read_len = file.readRangeInto(
            offset,
            buffer[0..chunk_len],
        ) catch return error.SessionRecoveryBoundaryInvalid;
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        hasher.update(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionRecoveryBoundaryInvalid;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn validateRecoveredManagedChildDigest(
    kind: session_child_store.ManagedChildKind,
    handle: []const u8,
    expected_bytes: ?usize,
    digest: [32]u8,
) !void {
    switch (kind) {
        .tool_results => if (!result_store.handleMatchesContentDigest(
            handle,
            digest,
        )) return error.SessionRecoveryBoundaryInvalid,
        .command_artifacts => {
            if (expected_bytes != null and
                command_replay_store.hasContentDigest(handle) and
                !command_replay_store.handleMatchesContentDigest(
                    handle,
                    digest,
                ))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
            if (expected_bytes == null and
                artifact_digest.hasContentDigest(handle, ".log") and
                !artifact_digest.handleMatchesContentDigest(
                    handle,
                    ".log",
                    digest,
                ))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
        else => return error.SessionRecoveryBoundaryInvalid,
    }
}

fn canonicalSnapshotLeaf(image: session.ImageAttachment, stored: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(stored)) return error.InvalidSessionFormat;
    const prefix = "images/";
    if (!std.mem.startsWith(u8, stored, prefix)) return error.InvalidSessionFormat;
    const leaf = stored[prefix.len..];
    if (leaf.len == 0 or
        std.mem.indexOfAny(u8, leaf, "/\\") != null or
        std.mem.eql(u8, leaf, ".") or
        std.mem.eql(u8, leaf, ".."))
    {
        return error.InvalidSessionFormat;
    }

    const digest = image.snapshot_sha256 orelse return error.InvalidSessionFormat;
    if (image.id == 0 or digest.len != 64) return error.InvalidSessionFormat;
    for (digest) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.InvalidSessionFormat;
        }
    }
    var expected_buffer: [128]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &expected_buffer,
        "image-{d}-{s}.bin",
        .{ image.id, digest[0..16] },
    ) catch return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, leaf, expected)) return error.InvalidSessionFormat;
    return leaf;
}

fn resolveSessionSnapshotLocators(
    alloc: Allocator,
    history: []session.HistoryTurn,
    sessions_dir: []const u8,
    session_id: []const u8,
) !void {
    const session_dir = try sessionDirPath(alloc, sessions_dir, session_id);
    defer alloc.free(session_dir);
    const image_dir = try std.fs.path.join(alloc, &.{ session_dir, "images" });
    defer alloc.free(image_dir);

    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .background_command => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        for (images) |*image| {
            const stored = image.snapshot_path orelse continue;
            const leaf = try canonicalSnapshotLeaf(image.*, stored);
            const resolved = try std.fs.path.join(alloc, &.{ image_dir, leaf });
            alloc.free(stored);
            image.snapshot_path = resolved;
        }
    }
}

fn deleteSnapshotFilesAddedByMigration(
    candidate: []const session.HistoryTurn,
    original: []const session.HistoryTurn,
) void {
    for (candidate, original) |candidate_turn, original_turn| {
        const candidate_images = switch (candidate_turn) {
            .compacted_summary => &.{},
            .assistant => |entry| entry.user.images,
            .background_command => |entry| entry.user.images,
            .interrupted => |entry| entry.user.images,
        };
        const original_images = switch (original_turn) {
            .compacted_summary => &.{},
            .assistant => |entry| entry.user.images,
            .background_command => |entry| entry.user.images,
            .interrupted => |entry| entry.user.images,
        };
        image_attachments.deleteUnreferencedImageSnapshots(
            candidate_images,
            original_images,
        );
    }
}

test "session snapshot locators resolve through their owning store" {
    const alloc = std.testing.allocator;
    var history = try alloc.alloc(session.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try session.makeAssistantTurn(alloc, "images", "done");
    defer session.freeHistoryTurnSlice(alloc, history);
    history[0].assistant.user.images = try session.dupeImageAttachmentSlice(alloc, &.{
        .{
            .id = 1,
            .path = @constCast("/tmp/source-a.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = @constCast("images/image-1-aaaaaaaaaaaaaaaa.bin"),
            .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        },
        .{
            .id = 2,
            .path = @constCast("/tmp/source-b.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = @constCast("images/image-2-bbbbbbbbbbbbbbbb.bin"),
            .snapshot_sha256 = @constCast("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        },
        .{
            .id = 3,
            .path = @constCast("/tmp/legacy-path-only.png"),
            .media_type = @constCast("image/png"),
        },
    });

    try resolveSessionSnapshotLocators(
        alloc,
        history,
        "/new/fx-home/sessions",
        "id",
    );

    try std.testing.expectEqualStrings(
        "/new/fx-home/sessions/id/images/image-1-aaaaaaaaaaaaaaaa.bin",
        history[0].assistant.user.images[0].snapshot_path.?,
    );
    try std.testing.expectEqualStrings(
        "/new/fx-home/sessions/id/images/image-2-bbbbbbbbbbbbbbbb.bin",
        history[0].assistant.user.images[1].snapshot_path.?,
    );
    try std.testing.expect(history[0].assistant.user.images[2].snapshot_path == null);
}

test "current session snapshot locators reject absolute paths" {
    const alloc = std.testing.allocator;
    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, "images", "done");
    defer session.freeHistoryTurnSlice(alloc, history);
    history[0].assistant.user.images = try session.dupeImageAttachmentSlice(alloc, &.{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/image-1-aaaaaaaaaaaaaaaa.bin"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }});

    try std.testing.expectError(
        error.InvalidSessionFormat,
        resolveSessionSnapshotLocators(
            alloc,
            history,
            "/new/fx-home/sessions",
            "id",
        ),
    );
}

test "session snapshot locator resolver rejects noncanonical tampering" {
    const alloc = std.testing.allocator;
    const tampered = [_][]const u8{
        "",
        "images/",
        "images/.",
        "images/..",
        "images/../image-1-aaaaaaaaaaaaaaaa.bin",
        "images/nested/image-1-aaaaaaaaaaaaaaaa.bin",
        "images//image-1-aaaaaaaaaaaaaaaa.bin",
        "other/image-1-aaaaaaaaaaaaaaaa.bin",
        "/tmp/image-1-aaaaaaaaaaaaaaaa.bin",
        "images/image-2-aaaaaaaaaaaaaaaa.bin",
        "images/image-1-bbbbbbbbbbbbbbbb.bin",
        "images/image-1-aaaaaaaaaaaaaaaa.png",
    };

    for (tampered) |locator| {
        var history = try alloc.alloc(session.HistoryTurn, 1);
        history[0] = try session.makeAssistantTurn(alloc, "images", "done");
        defer session.freeHistoryTurnSlice(alloc, history);
        history[0].assistant.user.images = try session.dupeImageAttachmentSlice(alloc, &.{.{
            .id = 1,
            .path = @constCast("/tmp/source.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = @constCast(locator),
            .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        }});
        try std.testing.expectError(
            error.InvalidSessionFormat,
            resolveSessionSnapshotLocators(
                alloc,
                history,
                "/new/fx-home/sessions",
                "id",
            ),
        );
    }
}

test "session snapshot locator resolver rejects symlink leaves and directories" {
    const alloc = std.testing.allocator;
    const image_bytes = "\x89PNG\r\n\x1a\noutside";
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_bytes, &digest_bytes, .{});
    const digest = std.fmt.bytesToHex(digest_bytes, .lower);
    var canonical_leaf_buffer: [64]u8 = undefined;
    const canonical_leaf = try std.fmt.bufPrint(
        &canonical_leaf_buffer,
        "image-1-{s}.bin",
        .{digest[0..16]},
    );
    var locator_buffer: [80]u8 = undefined;
    const locator = try std.fmt.bufPrint(
        &locator_buffer,
        "images/{s}",
        .{canonical_leaf},
    );

    for ([_]bool{ false, true }) |symlink_directory| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const sessions_name = if (symlink_directory)
            "sessions-symlink-dir"
        else
            "sessions-symlink-leaf";
        try tmp.dir.createDir(
            std.testing.io,
            sessions_name,
            std.Io.File.Permissions.fromMode(0o700),
        );
        var sessions = try tmp.dir.openDir(std.testing.io, sessions_name, .{});
        defer sessions.close(std.testing.io);
        try sessions.createDir(
            std.testing.io,
            "session",
            std.Io.File.Permissions.fromMode(0o700),
        );
        var session_dir = try sessions.openDir(std.testing.io, "session", .{});
        defer session_dir.close(std.testing.io);

        if (symlink_directory) {
            try tmp.dir.createDir(
                std.testing.io,
                "outside-images",
                std.Io.File.Permissions.fromMode(0o700),
            );
            var outside_images = try tmp.dir.openDir(std.testing.io, "outside-images", .{});
            defer outside_images.close(std.testing.io);
            {
                var file = try outside_images.createFile(
                    std.testing.io,
                    canonical_leaf,
                    .{},
                );
                defer file.close(std.testing.io);
                try file.writeStreamingAll(std.testing.io, image_bytes);
            }
            const outside_images_path = try io_mod.dirRealpathAlloc(
                alloc,
                tmp.dir,
                "outside-images",
            );
            defer alloc.free(outside_images_path);
            session_dir.symLink(
                std.testing.io,
                outside_images_path,
                "images",
                .{ .is_directory = true },
            ) catch |err| switch (err) {
                error.AccessDenied => return error.SkipZigTest,
                else => return err,
            };
        } else {
            try session_dir.createDir(
                std.testing.io,
                "images",
                std.Io.File.Permissions.fromMode(0o700),
            );
            var images_dir = try session_dir.openDir(std.testing.io, "images", .{});
            defer images_dir.close(std.testing.io);
            const outside_name = "outside.bin";
            {
                var file = try tmp.dir.createFile(std.testing.io, outside_name, .{});
                defer file.close(std.testing.io);
                try file.writeStreamingAll(std.testing.io, image_bytes);
            }
            const outside_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, outside_name);
            defer alloc.free(outside_path);
            images_dir.symLink(
                std.testing.io,
                outside_path,
                canonical_leaf,
                .{ .is_directory = false },
            ) catch |err| switch (err) {
                error.AccessDenied => return error.SkipZigTest,
                else => return err,
            };
        }

        const sessions_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, sessions_name);
        defer alloc.free(sessions_path);
        var history = try alloc.alloc(session.HistoryTurn, 1);
        history[0] = try session.makeAssistantTurn(alloc, "images", "done");
        defer session.freeHistoryTurnSlice(alloc, history);
        history[0].assistant.user.images = try session.dupeImageAttachmentSlice(alloc, &.{.{
            .id = 1,
            .path = @constCast("/tmp/source.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = @constCast(locator),
            .snapshot_sha256 = @constCast(digest[0..]),
        }});

        try resolveSessionSnapshotLocators(
            alloc,
            history,
            sessions_path,
            "session",
        );
        try std.testing.expectError(
            error.ImageSnapshotPathUnsafe,
            image_attachments.loadVerifiedSnapshot(
                alloc,
                history[0].assistant.user.images[0],
                .{},
            ),
        );
    }
}

pub fn isPristineStartedSession(loaded: *const LoadedWritableSession) bool {
    return loaded.freshly_started and
        std.mem.eql(u8, loaded.active_id, loaded.state.id) and
        std.mem.eql(u8, loaded.log.session_id, loaded.state.id) and
        loaded.state.history.len == 0 and
        loaded.state.context_history_start == 0 and
        loaded.state.total_input_tokens == 0 and
        loaded.state.total_output_tokens == 0 and
        loaded.state.recovery_checkpoint == null and
        !loaded.namespace_confirmation_required and
        loaded.degraded_tail == null and
        loaded.migration_source_schema_version == null and
        loaded.migration_source_bytes == null;
}

fn loadedWriterBelongsToStore(
    store: Store,
    alloc: Allocator,
    loaded: *const LoadedWritableSession,
) !bool {
    return loadedWriterBelongsToRoot(
        alloc,
        loaded,
        store.sessions_dir,
    );
}

fn loadedWriterBelongsToRoot(
    alloc: Allocator,
    loaded: *const LoadedWritableSession,
    root_path: []const u8,
) !bool {
    const actual_path = try io_mod.dirRealpathAlloc(
        alloc,
        loaded.log.dir.dir,
        "",
    );
    defer alloc.free(actual_path);
    const expected_path = try sessionDirPath(
        alloc,
        root_path,
        loaded.active_id,
    );
    defer alloc.free(expected_path);
    return std.mem.eql(u8, expected_path, actual_path);
}

fn prepareWritableSessionDir(dir: std.Io.Dir) !void {
    const permissions = std.Io.File.Permissions.fromMode(0o700);
    dir.setPermissions(io_mod.getIo(), permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn initWithHome(alloc: Allocator, home: []const u8, workspace_root: []const u8, ensure_layout: bool) !Store {
    const trimmed_workspace = normalizeWorkspaceRoot(workspace_root);
    if (trimmed_workspace.len == 0) return error.InvalidWorkspaceRoot;

    var canonical_root = session_log.Root.initFromHome(
        alloc,
        home,
        if (ensure_layout) .writable else .read_only,
    ) catch |err| switch (err) {
        error.OutOfMemory,
        error.PrivateStatePermissionsUnsupported,
        error.SessionPathUnsafe,
        => return err,
        else => {
            if (!ensure_layout) return err;
            debug_trace.logf(
                "session",
                "event=writable_layout_failed source_error={s} mapped_error=DurableLayoutFailed",
                .{@errorName(err)},
            );
            return error.DurableLayoutFailed;
        },
    };
    errdefer canonical_root.deinit(alloc);
    const sessions_dir = try alloc.dupe(u8, canonical_root.display_root);
    errdefer alloc.free(sessions_dir);
    const home_dir = try alloc.dupe(u8, home);
    errdefer alloc.free(home_dir);
    const owned_workspace = try alloc.dupe(u8, trimmed_workspace);
    errdefer alloc.free(owned_workspace);
    return .{
        .sessions_dir = sessions_dir,
        .home_dir = home_dir,
        .workspace_root = owned_workspace,
        .canonical_root = canonical_root,
    };
}

fn readLatestPointer(
    self: Store,
    alloc: Allocator,
    workspace_root: []const u8,
) !?LatestPointer {
    const sessions = self.canonical_root.sessions orelse return null;
    if (try summary_codec.deferredCachePresent(&sessions)) {
        return error.InvalidSessionIndex;
    }
    return readLatestPointerFromSessions(&sessions, alloc, workspace_root);
}

fn readPendingLatestSessionId(
    self: Store,
    alloc: Allocator,
    workspace_root: []const u8,
) !?[]u8 {
    const sessions = self.canonical_root.sessions orelse return null;
    return readPendingLatestSessionIdFromSessions(&sessions, alloc, workspace_root);
}

fn latestPointerStillMatches(
    self: Store,
    alloc: Allocator,
    workspace_root: []const u8,
    expected: LatestPointer,
) !bool {
    const revalidated = readLatestPointer(self, alloc, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (revalidated) |latest_value| {
        var latest = latest_value;
        defer latest.deinit(alloc);
        return latest.updated_at_ms == expected.updated_at_ms and
            std.mem.eql(u8, latest.session_id, expected.session_id);
    }
    return false;
}

const LatestBarrierLockContext = struct {
    test_controls: session_log.TestControls,
    contention_reported: bool = false,

    fn tryLock(context: ?*anyopaque, file: std.Io.File) !bool {
        const self: *LatestBarrierLockContext = @ptrCast(@alignCast(context.?));
        const locked = try file.tryLock(io_mod.getIo(), .exclusive);
        if (!locked and !self.contention_reported) {
            self.contention_reported = true;
            try self.test_controls.boundary(.latest_barrier_contended);
        }
        return locked;
    }
};

const TempStore = struct {
    home: []u8,
    workspace: []u8,
    store: Store,

    fn deinit(self: *TempStore, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.workspace);
        alloc.free(self.home);
    }
};

fn initTempStore(alloc: Allocator, tmp: *std.testing.TmpDir) !TempStore {
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    errdefer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    errdefer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, workspace);
    errdefer store.deinit(alloc);
    return .{ .home = home, .workspace = workspace, .store = store };
}

fn testDurableState(
    alloc: Allocator,
    id: []const u8,
    workspace_root: []const u8,
) !session_codec.DurableSessionState {
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, workspace_root),
        .workspace_root = try alloc.dupe(u8, workspace_root),
        .created_at_ms = 10,
        .updated_at_ms = 10,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = core_types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn expectDeferredCacheTokenMissing(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !void {
    if (try summary_codec.readDeferredCacheToken(
        alloc,
        sessions,
        session_id,
    )) |token_value| {
        var token = token_value;
        defer token.deinit(alloc);
        return error.TestExpectedEqual;
    }
}

fn testIndexedSessionSummary(
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) SessionSummary {
    return .{
        .id = @constCast(id),
        .workspace_root = @constCast(workspace_root),
        .origin_workspace_root = @constCast(workspace_root),
        .title = @constCast(id),
        .preview = @constCast(id),
        .display_metadata_present = true,
        .created_at_ms = updated_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history_len = 0,
    };
}

fn makeSessionDir(alloc: Allocator, store: Store, id: []const u8) !void {
    const dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(dir);
    try config_runtime.makeAbsolutePath(dir);
}

fn makeRawSessionsEntry(store: Store, name: []const u8) !void {
    const sessions = store.canonical_root.sessions orelse return error.TestExpectedEqual;
    sessions.dir.createDir(
        io_mod.getIo(),
        name,
        std.Io.File.Permissions.fromMode(0o700),
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeRawFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn writeSessionFixture(alloc: Allocator, store: Store, id: []const u8, text: []const u8) ![]u8 {
    try makeSessionDir(alloc, store, id);
    const path = try sessionJsonPath(alloc, store.sessions_dir, id);
    try writeRawFile(path, text);
    return path;
}

test "resume commits legacy permission state migration before publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "permission-migration", ctx.workspace);
    defer state.deinit(alloc);
    var started = try ctx.store.startWritableSession(alloc, state);
    started.log.park();
    started.deinit(alloc);

    var legacy = try ctx.store.resumeExactForWrite(
        alloc,
        "permission-migration",
        ctx.workspace,
        true,
        .{},
    );
    legacy.state.permission_state.version = 1;
    var migrated = try ctx.store.finishResumedForWrite(alloc, legacy, .{});
    try std.testing.expectEqual(
        session_permission_state.schema_version,
        migrated.state.permission_state.version,
    );
    migrated.log.park();
    migrated.deinit(alloc);

    var resumed = try ctx.store.resumeForWrite(alloc, "permission-migration");
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(
        session_permission_state.schema_version,
        resumed.state.permission_state.version,
    );
}

fn chmodPath(alloc: Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

fn writeLegacyFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: ?[]const u8,
    updated_at_ms: i64,
) !void {
    const text = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root orelse "",
        &.{},
        .{},
    );
    defer alloc.free(text);
    if (workspace_root == null) {
        const needle = ",\"workspace_root\":\"\"";
        const start = std.mem.find(u8, text, needle) orelse return error.InvalidSessionFormat;
        const without_root = try std.mem.concat(alloc, u8, &.{
            text[0..start],
            text[start + needle.len ..],
        });
        defer alloc.free(without_root);
        const path = try writeSessionFixture(alloc, store, id, without_root);
        alloc.free(path);
        return;
    }
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn writeLegacyIncompleteAuthorityFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    const history = [_]session.HistoryTurn{.{ .compacted_summary = .{
        .summary = @constCast("legacy summary"),
        .removed_turn_count = 2,
        .compaction_count = 1,
        .root_user_messages_complete = false,
        .permission_feedback_complete = false,
    } }};
    const rendered = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root,
        &history,
        .{},
    );
    defer alloc.free(rendered);
    const path = try writeSessionFixture(alloc, store, id, rendered);
    alloc.free(path);
}

fn writeSummaryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: ?[]const u8,
    updated_at_ms: i64,
    history_len: usize,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"schema_version\":1,\"id\":\"{s}\",\"created_at_ms\":1,\"updated_at_ms\":{d}",
        .{ id, updated_at_ms },
    );
    if (workspace_root) |root| {
        try out.writer.writeAll(",\"workspace_root\":");
        try std.json.Stringify.value(root, .{}, &out.writer);
    }
    try out.writer.print(
        ",\"conversation_language\":\"en\",\"history_len\":{d},\"history\":",
        .{history_len},
    );
    if (history_len == 0) {
        try out.writer.writeAll("[]}");
    } else {
        try out.writer.writeAll("[{\"role\":\"user\",\"content\":\"saved\"}]}");
    }
    const text = try out.toOwnedSlice();
    defer alloc.free(text);
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn writeWritableHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    prompt: []const u8,
) !void {
    return writeWritableHistoryResponseFixture(
        alloc,
        store,
        id,
        workspace_root,
        updated_at_ms,
        prompt,
        "saved response",
    );
}

fn writeWritableHistoryResponseFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    prompt: []const u8,
    response: []const u8,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    errdefer writable.deinit(alloc);

    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, prompt, response);
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);
}

fn writeLargeWritableHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    response_bytes: usize,
) !void {
    const response = try alloc.alloc(u8, response_bytes);
    defer alloc.free(response);
    @memset(response, 'x');
    return writeWritableHistoryResponseFixture(
        alloc,
        store,
        id,
        workspace_root,
        updated_at_ms,
        "unrelated prompt",
        response,
    );
}

fn writeStaleWritableHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var session_dir = try store.openSessionDir(id);
    defer session_dir.close();
    var manifest_file = try session_dir.dir.openFile(io_mod.getIo(), "session.json", .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    const stale_manifest = try io_mod.readFileToEnd(
        alloc,
        &manifest_file,
        session_projection.manifest_max_bytes + 1,
    );
    manifest_file.close(io_mod.getIo());
    defer alloc.free(stale_manifest);
    const turn = try session.makeAssistantTurn(
        alloc,
        "new canonical prompt",
        "new canonical response",
    );
    defer session.freeHistoryTurn(alloc, turn);
    _ = try writable.appendEvent(
        alloc,
        .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 3,
            .total_output_tokens = 4,
            .turn = turn,
        } },
        updated_at_ms,
        .retry_expected_tail,
        .{},
    );
    try io_mod.durableReplaceVerified(
        alloc,
        &session_dir,
        "session.json",
        stale_manifest,
    );
}

fn writeDeferredTokenForTest(
    alloc: Allocator,
    store: Store,
    session_id: []const u8,
    workspace_root: []const u8,
) !void {
    var target = try store.resumeTargetForWrite(
        alloc,
        .{ .id = session_id },
        workspace_root,
        .{},
    );
    const position = target.position;
    target.deinit(alloc);
    var sessions = store.canonical_root.sessions orelse return error.TestExpectedEqual;
    const cache = try LatestCache.init(alloc, &sessions, .{}, .maintain);
    defer cache.deinit(alloc);
    try cache.writeDeferredToken(
        alloc,
        session_id,
        workspace_root,
        position,
    );
}

fn writeWritableIncompleteAuthorityFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    errdefer writable.deinit(alloc);

    const history = blk: {
        const owned = try alloc.alloc(session.HistoryTurn, 1);
        errdefer alloc.free(owned);
        const summary = try alloc.dupe(u8, "legacy summary");
        errdefer alloc.free(summary);
        const permission_feedback = try alloc.alloc([]u8, 1);
        errdefer alloc.free(permission_feedback);
        permission_feedback[0] = try alloc.dupe(
            u8,
            "Never mutate the production remote.",
        );
        owned[0] = .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = 2,
            .compaction_count = 1,
            .root_user_messages_complete = false,
            .permission_feedback = permission_feedback,
            .permission_feedback_complete = false,
        } };
        break :blk owned;
    };
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);
}

const ManagedHistoryFixtureArtifacts = struct {
    legacy_replay: bool = false,
    legacy_command_artifact: bool = false,
};

fn writeWritableManagedHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    write_sidecars: bool,
    artifacts: ManagedHistoryFixtureArtifacts,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    const capability = writable.child_capability orelse
        return error.SessionChildStoreFailed;
    const output_text = "complete recovered tool result";
    var output_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output_text, &output_digest, .{});
    const output_digest_hex = std.fmt.bytesToHex(
        output_digest[0..8].*,
        .lower,
    );
    const output_handle = try std.fmt.allocPrint(
        alloc,
        "result-run_command-0000000000000000-{s}.txt",
        .{&output_digest_hex},
    );
    defer alloc.free(output_handle);
    const replay_payload = "recovered command replay";
    var replay_bytes: [8 + 9 + replay_payload.len]u8 = undefined;
    @memcpy(replay_bytes[0..8], "FXRPLY01");
    replay_bytes[8] = 0;
    std.mem.writeInt(
        u64,
        replay_bytes[9..17],
        replay_payload.len,
        .little,
    );
    @memcpy(replay_bytes[17..], replay_payload);
    var replay_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&replay_bytes, &replay_digest, .{});
    const replay_digest_hex = std.fmt.bytesToHex(
        replay_digest[0..8].*,
        .lower,
    );
    const replay_handle = if (artifacts.legacy_replay)
        try alloc.dupe(u8, "fx-command-replay-legacy.bin")
    else
        try std.fmt.allocPrint(
            alloc,
            "fx-command-replay-test-{s}.bin",
            .{&replay_digest_hex},
        );
    defer alloc.free(replay_handle);
    const interrupted_artifact_handle = "fx-command-cancelled.log";
    const interrupted_artifact = "interrupted command artifact";
    if (write_sidecars) {
        var output_file = try capability.createExclusiveFile(
            alloc,
            .tool_results,
            output_handle,
        );
        defer output_file.deinit();
        try output_file.writeAll(output_text);
        try output_file.sync();
        var replay_file = try capability.createExclusiveFile(
            alloc,
            .command_artifacts,
            replay_handle,
        );
        defer replay_file.deinit();
        try replay_file.writeAll(&replay_bytes);
        try replay_file.sync();
        if (artifacts.legacy_command_artifact) {
            var interrupted_file = try capability.createExclusiveFile(
                alloc,
                .command_artifacts,
                interrupted_artifact_handle,
            );
            defer interrupted_file.deinit();
            try interrupted_file.writeAll(interrupted_artifact);
            try interrupted_file.sync();
        }
    }

    const history_len: usize = if (artifacts.legacy_command_artifact) 2 else 1;
    var history = try alloc.alloc(session.HistoryTurn, history_len);
    var initialized_history_len: usize = 0;
    var history_complete = false;
    errdefer if (!history_complete) {
        for (history[0..initialized_history_len]) |turn| {
            session.freeHistoryTurn(alloc, turn);
        }
        alloc.free(history);
    };
    history[0] = try session.makeAssistantTurn(
        alloc,
        "run a command",
        "command complete",
    );
    initialized_history_len += 1;
    if (artifacts.legacy_command_artifact) {
        history[1] = try session.dupeHistoryTurn(alloc, .{ .interrupted = .{
            .user = .{ .text = @constCast("cancel a command") },
            .tool_call = .{
                .id = "call-cancelled",
                .name = "run_command",
                .arguments_json = "{\"command\":\"sleep 30\"}",
            },
            .cancelled_command = .{
                .output_replay = .{ .available = .{
                    .handle = replay_handle,
                    .framed_bytes = replay_bytes.len,
                } },
                .command_artifact_handle = interrupted_artifact_handle,
            },
        } });
        initialized_history_len += 1;
    }
    history_complete = true;
    defer session.freeHistoryTurnSlice(alloc, history);
    const steps = try alloc.alloc(core_types.ToolExecutionStep, 1);
    history[0].assistant.execution.tool_steps = steps;
    steps[0] = .{};
    const results = try alloc.alloc(core_types.PersistedToolResult, 1);
    steps[0].tool_results = results;
    results[0] = try makeManagedRecoveryResult(
        alloc,
        output_handle,
        replay_handle,
    );
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = 20,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
}

fn makeManagedRecoveryResult(
    alloc: Allocator,
    output_handle: []const u8,
    replay_handle: []const u8,
) !core_types.PersistedToolResult {
    const tool_call_id = try alloc.dupe(u8, "call-recovery");
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, "run_command");
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, "preview");
    errdefer alloc.free(output);
    const owned_output_handle = try alloc.dupe(u8, output_handle);
    errdefer alloc.free(owned_output_handle);
    const preview = try alloc.dupe(u8, "preview");
    errdefer alloc.free(preview);
    const owned_replay_handle = try alloc.dupe(u8, replay_handle);
    errdefer alloc.free(owned_replay_handle);
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = .success,
        .output = output,
        .output_handle = owned_output_handle,
        .preview = preview,
        .output_bytes = "complete recovered tool result".len,
        .stored_output_bytes = "complete recovered tool result".len,
        .truncated = true,
        .command_output_replay = .{ .available = .{
            .handle = owned_replay_handle,
            .framed_bytes = 8 + 9 + "recovered command replay".len,
        } },
    };
}

fn corruptFixtureWatermark(
    alloc: Allocator,
    store: Store,
    session_id: []const u8,
) !void {
    var source = try store.resumeForWrite(alloc, session_id);
    const generation = source.position.log_generation;
    source.deinit(alloc);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        store,
        session_id,
        watermark_name,
        "{}\n",
    );
}

fn replaceHistoryPageFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    updated_at_ms: i64,
    count: usize,
    label: []const u8,
) !void {
    var writable = try store.resumeForWrite(alloc, id);
    defer writable.deinit(alloc);
    var history = try alloc.alloc(session.HistoryTurn, count);
    var initialized: usize = 0;
    errdefer {
        for (history[0..initialized]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(history);
    }
    for (history, 0..) |*turn, index| {
        const prompt = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ label, index });
        defer alloc.free(prompt);
        turn.* = try session.makeAssistantTurn(alloc, prompt, "saved response");
        initialized += 1;
    }
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
}

fn makeTaggedHistoryPageTurns(
    alloc: Allocator,
    count: usize,
    label: []const u8,
) ![]session.HistoryTurn {
    const history = try alloc.alloc(session.HistoryTurn, count);
    var initialized: usize = 0;
    errdefer {
        for (history[0..initialized]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(history);
    }
    for (history, 0..) |*turn, index| {
        const prompt = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ label, index });
        defer alloc.free(prompt);
        turn.* = try session.makeAssistantTurn(alloc, prompt, "saved response");
        initialized += 1;
        try session.copyWorkIdToTurn(alloc, turn, prompt);
    }
    return history;
}

fn replaceHistoryPageTurnsFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    updated_at_ms: i64,
    history: []const session.HistoryTurn,
) !void {
    var writable = try store.resumeForWrite(alloc, id);
    defer writable.deinit(alloc);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = @constCast(history),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
}

fn createHistoryPageFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    count: usize,
    label: []const u8,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    writable.deinit(alloc);
    try replaceHistoryPageFixture(alloc, store, id, 20, count, label);
}

fn expectHistoryPagePrompts(page: HistoryPage, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, page.turns.len);
    for (page.turns, expected) |turn, prompt| {
        switch (turn) {
            .assistant => |assistant| try std.testing.expectEqualStrings(prompt, assistant.user.text),
            else => return error.TestExpectedEqual,
        }
    }
}

fn writeLegacyV2Fixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    const text = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root,
        &.{},
        .{},
    );
    defer alloc.free(text);
    const schema = "\"schema_version\":1";
    const schema_start = std.mem.find(u8, text, schema) orelse
        return error.InvalidSessionFormat;
    text[schema_start + schema.len - 1] = '2';
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn writeLargeLegacyFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    const base = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root,
        &.{},
        .{},
    );
    defer alloc.free(base);
    if (base.len == 0 or base[0] != '{') return error.InvalidSessionFormat;
    const filler = try alloc.alloc(u8, session_projection.manifest_max_bytes + 1024);
    defer alloc.free(filler);
    @memset(filler, 'x');

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ignored_large_field\":\"");
    try out.writer.writeAll(filler);
    try out.writer.writeAll("\",");
    try out.writer.writeAll(base[1..]);
    const text = try out.toOwnedSlice();
    defer alloc.free(text);
    try std.testing.expect(text.len > session_projection.manifest_max_bytes);
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn readFixtureFile(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    const session_dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(session_dir);
    const path = try std.fs.path.join(alloc, &.{ session_dir, name });
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn writeFixtureEntry(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const session_dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(session_dir);
    const path = try std.fs.path.join(alloc, &.{ session_dir, name });
    defer alloc.free(path);
    try writeRawFile(path, bytes);
}

fn corruptPendingReplacementTimestampForTest(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    prior_bytes: u64,
) !void {
    const session_dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(session_dir);
    const path = try std.fs.path.join(alloc, &.{ session_dir, "events.jsonl" });
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_write });
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    if (length <= prior_bytes) return error.TestUnexpectedResult;
    const tail_len = std.math.cast(usize, length - prior_bytes) orelse
        return error.TestUnexpectedResult;
    const tail = try alloc.alloc(u8, tail_len);
    defer alloc.free(tail);
    const count = try file.readPositionalAll(io_mod.getIo(), tail, prior_bytes);
    if (count != tail.len) return error.TestUnexpectedResult;
    const needle = "\"timestamp_ms\":20";
    const match = std.mem.lastIndexOf(u8, tail, needle) orelse
        return error.TestUnexpectedResult;
    tail[match + needle.len - 1] = '1';
    try file.writePositionalAll(io_mod.getIo(), tail, prior_bytes);
    try file.sync(io_mod.getIo());
}

const MigrationBoundaryFailure = struct {
    target: session_log.Boundary,
    remaining_matches: usize = 0,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *MigrationBoundaryFailure = @ptrCast(@alignCast(context.?));
        if (boundary != self.target) return;
        if (self.remaining_matches > 0) {
            self.remaining_matches -= 1;
            return;
        }
        return error.InjectedBoundaryFailure;
    }

    fn options(self: *MigrationBoundaryFailure) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = callback,
                },
            },
        };
    }
};

const ArmedBoundaryFailure = struct {
    target: session_log.Boundary,
    armed: bool = false,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *ArmedBoundaryFailure = @ptrCast(@alignCast(context.?));
        if (self.armed and boundary == self.target) return error.InjectedBoundaryFailure;
    }

    fn logOptions(self: *ArmedBoundaryFailure) session_log.Options {
        return .{
            .test_controls = .{
                .context = self,
                .boundary_fn = callback,
            },
        };
    }
};

const RecoveryResolutionFailure = struct {
    fn callback(_: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary == .after_target_namespace_sync or
            boundary == .before_recovery_proposed_validation)
        {
            return error.InjectedBoundaryFailure;
        }
    }

    fn options() session_log.Options {
        return .{
            .test_controls = .{ .boundary_fn = callback },
        };
    }
};

const LatestBarrierFailure = struct {
    injected_error: anyerror,
    completed_count: usize = 0,
    contended_count: usize = 0,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *LatestBarrierFailure = @ptrCast(@alignCast(context.?));
        switch (boundary) {
            .latest_barrier_contended => self.contended_count += 1,
            .latest_barrier_completed => {
                self.completed_count += 1;
                return self.injected_error;
            },
            else => {},
        }
    }

    fn options(self: *LatestBarrierFailure) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = callback,
                },
            },
        };
    }
};

fn waitForTestFlag(flag: *const std.atomic.Value(bool)) !void {
    const deadline_ms = io_mod.milliTimestamp() + 5000;
    while (!flag.load(.seq_cst)) {
        if (io_mod.milliTimestamp() >= deadline_ms) return error.TestTimedOut;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

fn waitForTestFlagInCallback(flag: *const std.atomic.Value(bool)) bool {
    waitForTestFlag(flag) catch return false;
    return true;
}

const DiscardPauseControl = struct {
    armed: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *DiscardPauseControl = @ptrCast(@alignCast(context.?));
        if (boundary != .after_latest_cache_pending or !self.armed.load(.seq_cst)) return;
        self.pending.store(true, .seq_cst);
        if (!waitForTestFlagInCallback(&self.release)) {
            self.timed_out.store(true, .seq_cst);
            return error.TestTimedOut;
        }
    }

    fn logOptions(self: *DiscardPauseControl) session_log.Options {
        return .{
            .test_controls = .{
                .context = self,
                .boundary_fn = callback,
            },
        };
    }
};

const ResumeInterleavingControl = struct {
    pause_on_session: bool = false,
    barrier_contended: std.atomic.Value(bool) = .init(false),
    barrier_completed_count: std.atomic.Value(usize) = .init(0),
    session_opened: std.atomic.Value(bool) = .init(false),
    release_session: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn boundary(context: ?*anyopaque, point: session_log.Boundary) !void {
        const self: *ResumeInterleavingControl = @ptrCast(@alignCast(context.?));
        switch (point) {
            .latest_barrier_contended => self.barrier_contended.store(true, .seq_cst),
            .latest_barrier_completed => _ = self.barrier_completed_count.fetchAdd(1, .seq_cst),
            else => {},
        }
    }

    fn lock(context: ?*anyopaque, kind: session_log.LockKind) void {
        const self: *ResumeInterleavingControl = @ptrCast(@alignCast(context.?));
        if (kind != .session or !self.pause_on_session) return;
        if (self.session_opened.swap(true, .seq_cst)) return;
        if (!waitForTestFlagInCallback(&self.release_session)) {
            self.timed_out.store(true, .seq_cst);
        }
    }

    fn options(self: *ResumeInterleavingControl) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = boundary,
                    .lock_fn = lock,
                },
            },
        };
    }
};

const DiscardWorker = struct {
    store: *Store,
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    disposition: ?PristineDiscardDisposition = null,

    fn run(self: *DiscardWorker) void {
        self.disposition = self.store.discardPristineStartedSession(
            self.alloc,
            self.loaded,
        );
    }
};

const ResumeWorker = struct {
    const Result = union(enum) {
        pending,
        loaded: LoadedWritableSession,
        failed: anyerror,
    };

    store: *Store,
    alloc: Allocator,
    workspace_root: []const u8,
    options: ResumeOptions,
    result: Result = .pending,

    fn run(self: *ResumeWorker) void {
        const loaded = self.store.resumeTargetForWrite(
            self.alloc,
            .last,
            self.workspace_root,
            self.options,
        ) catch |err| {
            self.result = .{ .failed = err };
            return;
        };
        self.result = .{ .loaded = loaded };
    }

    fn takeLoaded(self: *ResumeWorker) !LoadedWritableSession {
        return switch (self.result) {
            .pending => error.TestExpectedEqual,
            .failed => |err| err,
            .loaded => |loaded| blk: {
                self.result = .pending;
                break :blk loaded;
            },
        };
    }

    fn deinitResult(self: *ResumeWorker) void {
        switch (self.result) {
            .loaded => |*loaded| loaded.deinit(self.alloc),
            else => {},
        }
        self.result = .pending;
    }
};

const MigrationStableCopyCorruption = struct {
    legacy_copy_path: []const u8,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary != .after_authority_namespace_sync) return;
        const self: *MigrationStableCopyCorruption = @ptrCast(@alignCast(context.?));
        try writeRawFile(self.legacy_copy_path, "{broken");
    }

    fn options(self: *MigrationStableCopyCorruption) session_log.Options {
        return .{
            .test_controls = .{
                .context = self,
                .boundary_fn = callback,
            },
        };
    }
};

const MigrationInterruptedStableCopyCorruption = struct {
    legacy_copy_path: []const u8,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary != .after_authority_namespace_sync) return;
        const self: *MigrationInterruptedStableCopyCorruption = @ptrCast(@alignCast(context.?));
        try writeRawFile(self.legacy_copy_path, "{broken");
        return error.InjectedBoundaryFailure;
    }

    fn options(self: *MigrationInterruptedStableCopyCorruption) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = callback,
                },
            },
        };
    }
};

test "fresh session usage survives the initial durable event" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "initial-usage", ctx.workspace);
    defer state.deinit(alloc);
    try std.testing.expect(state.usage == null);

    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var loaded = try ctx.store.loadReadOnly(alloc, state.id);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.usage != null);
    try std.testing.expectEqual(
        session_usage.Availability.complete,
        loaded.usage.?.billing,
    );
}

test "workspace latest pointer is materialized on session creation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "latest-pointer-created", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var latest = try ctx.store.canonical_root.sessions.?.dir.openDir(
        io_mod.getIo(),
        "latest",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer latest.close(io_mod.getIo());
    var iterator = latest.iterate();
    try std.testing.expect((try iterator.next(io_mod.getIo())) != null);
}

test "workspace latest pointer preserves allocator failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "latest-pointer-oom", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var counting = std.testing.FailingAllocator.init(alloc, .{});
    var counted = (try readLatestPointer(
        ctx.store,
        counting.allocator(),
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    counted.deinit(counting.allocator());
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);

    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        try std.testing.expectError(
            error.OutOfMemory,
            readLatestPointer(ctx.store, failing.allocator(), ctx.workspace),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "discarding a pristine started session ignores stale projection state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "discard-pristine", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.projection_status = .stale;

    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.discardPristineStartedSession(alloc, &writable),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.loadReadOnly(alloc, state.id),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.openSessionDir(state.id),
    );
    var listed = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &listed);
    try std.testing.expectEqual(@as(usize, 0), listed.items.len);
    try std.testing.expectError(
        error.NoSavedSessions,
        ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{}),
    );
}

test "discarding a pristine started session permits usage checkpoints" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "discard-pristine-usage", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    usage.finishInvocation(sequence, 0, .unbilled);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try writable.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{},
    );

    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.discardPristineStartedSession(alloc, &writable),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.loadReadOnly(alloc, state.id),
    );
}

test "pristine discard retains active recovery and permits cleared recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 1,
        .user = .{ .text = @constCast("prompt") },
        .assistant_source = @constCast(""),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 1,
    };

    var active_state = try testDurableState(alloc, "active-recovery", ctx.workspace);
    defer active_state.deinit(alloc);
    var active = try ctx.store.startWritableSession(alloc, active_state);
    _ = try active.appendEvent(
        alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        20,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(
        PristineDiscardDisposition.retained,
        ctx.store.discardPristineStartedSession(alloc, &active),
    );

    var cleared_state = try testDurableState(alloc, "cleared-recovery", ctx.workspace);
    defer cleared_state.deinit(alloc);
    var cleared = try ctx.store.startWritableSession(alloc, cleared_state);
    _ = try cleared.appendEvent(
        alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        30,
        .retry_expected_tail,
        .{},
    );
    _ = try cleared.appendEvent(
        alloc,
        .{ .recovery_checkpoint_cleared = .{} },
        40,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.discardPristineStartedSession(alloc, &cleared),
    );
}

test "pristine discard repairs latest and index to the completed predecessor" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "discard-predecessor",
        ctx.workspace,
        20,
        "saved prompt",
    );
    var warm_page = try ctx.store.listResumablePage(alloc, null, null);
    defer warm_page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), warm_page.summaries.items.len);

    var target_state = try testDurableState(alloc, "discard-newer-target", ctx.workspace);
    defer target_state.deinit(alloc);
    target_state.updated_at_ms = 30;
    var target = try ctx.store.startWritableSession(alloc, target_state);
    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.discardPristineStartedSession(alloc, &target),
    );
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(ctx.store, alloc, ctx.workspace),
    );
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readSessionIndex(alloc, &ctx.store.canonical_root.sessions.?),
    );

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    try std.testing.expectEqualStrings("discard-predecessor", resumed.state.id);
    resumed.deinit(alloc);

    var rebuilt_page = try ctx.store.listResumablePage(alloc, null, null);
    defer rebuilt_page.deinit(alloc);
    var rebuilt_index = try readSessionIndex(alloc, &ctx.store.canonical_root.sessions.?);
    defer freeSummaries(alloc, &rebuilt_index);
    try std.testing.expectEqual(@as(usize, 1), rebuilt_index.items.len);
    try std.testing.expectEqualStrings("discard-predecessor", rebuilt_index.items[0].id);
}

test "pristine discard refuses resumed and committed writers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var resumed_state = try testDurableState(alloc, "discard-resumed", ctx.workspace);
    defer resumed_state.deinit(alloc);
    var created = try ctx.store.startWritableSession(alloc, resumed_state);
    created.deinit(alloc);
    var resumed = try ctx.store.resumeForWrite(alloc, resumed_state.id);
    try std.testing.expectEqual(
        PristineDiscardDisposition.retained,
        ctx.store.discardPristineStartedSession(alloc, &resumed),
    );
    var resumed_loaded = try ctx.store.loadReadOnly(alloc, resumed_state.id);
    resumed_loaded.deinit(alloc);
    var resumed_latest = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    defer resumed_latest.deinit(alloc);
    try std.testing.expectEqualStrings(resumed_state.id, resumed_latest.session_id);

    var committed_state = try testDurableState(alloc, "discard-committed", ctx.workspace);
    defer committed_state.deinit(alloc);
    var committed = try ctx.store.startWritableSession(alloc, committed_state);
    _ = try committed.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(
        PristineDiscardDisposition.retained,
        ctx.store.discardPristineStartedSession(alloc, &committed),
    );
    var committed_loaded = try ctx.store.loadReadOnly(alloc, committed_state.id);
    defer committed_loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), committed_loaded.history.len);
    try std.testing.expect(committed_loaded.preferences.fast_mode);

    var latest = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings(committed_state.id, latest.session_id);
}

test "committed session deletion consumes its exact writer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "delete-committed", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );

    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.deleteCommittedSession(alloc, &writable),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.loadReadOnly(alloc, state.id),
    );
}

test "pristine discard refuses a writer from a different Store root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "home-b");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home-a");
    defer alloc.free(home_a);
    const home_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home-b");
    defer alloc.free(home_b);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store_a = try Store.initFromHome(alloc, home_a, workspace);
    defer store_a.deinit(alloc);
    var store_b = try Store.initFromHome(alloc, home_b, workspace);
    defer store_b.deinit(alloc);

    var state_a = try testDurableState(alloc, "shared-root-session", workspace);
    defer state_a.deinit(alloc);
    var state_b = try testDurableState(alloc, "shared-root-session", workspace);
    defer state_b.deinit(alloc);
    var writer_a = try store_a.startWritableSession(alloc, state_a);
    var writer_b = try store_b.startWritableSession(alloc, state_b);
    writer_b.deinit(alloc);

    const disposition = store_b.discardPristineStartedSession(alloc, &writer_a);
    try std.testing.expectEqual(PristineDiscardDisposition.retained, disposition);

    var loaded_a = try store_a.loadReadOnly(alloc, state_a.id);
    defer loaded_a.deinit(alloc);
    var loaded_b = try store_b.loadReadOnly(alloc, state_b.id);
    defer loaded_b.deinit(alloc);
    var latest_a = try readLatestPointer(store_a, alloc, workspace) orelse
        return error.TestExpectedEqual;
    defer latest_a.deinit(alloc);
    var latest_b = try readLatestPointer(store_b, alloc, workspace) orelse
        return error.TestExpectedEqual;
    defer latest_b.deinit(alloc);
    try std.testing.expectEqualStrings(state_a.id, latest_a.session_id);
    try std.testing.expectEqualStrings(state_b.id, latest_b.session_id);
}

test "pristine discard failure after pending retains repairable canonical state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var failure = ArmedBoundaryFailure{ .target = .after_latest_cache_pending };
    var state = try testDurableState(alloc, "discard-pending-failure", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSessionWithOptions(
        alloc,
        state,
        failure.logOptions(),
    );
    var warm_page = try ctx.store.listResumablePage(alloc, null, null);
    defer warm_page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), warm_page.summaries.items.len);
    var warm_index = try readSessionIndex(alloc, &ctx.store.canonical_root.sessions.?);
    defer freeSummaries(alloc, &warm_index);
    try std.testing.expectEqual(@as(usize, 1), warm_index.items.len);
    try std.testing.expectEqualStrings(state.id, warm_index.items[0].id);
    var warm_latest = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    defer warm_latest.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, warm_latest.session_id);
    failure.armed = true;
    try std.testing.expectEqual(
        PristineDiscardDisposition.indeterminate,
        ctx.store.discardPristineStartedSession(alloc, &writable),
    );

    var loaded = try ctx.store.loadReadOnly(alloc, state.id);
    loaded.deinit(alloc);
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(ctx.store, alloc, ctx.workspace),
    );
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readSessionIndex(alloc, &ctx.store.canonical_root.sessions.?),
    );

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, resumed.state.id);
    var repaired = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    defer repaired.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, repaired.session_id);
}

test "latest discovery retries only one namespace loss" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const retryable = [_]anyerror{
        error.SessionNotFound,
        error.FileNotFound,
    };
    for (retryable) |injected_error| {
        var failure = LatestBarrierFailure{ .injected_error = injected_error };
        try std.testing.expectError(
            injected_error,
            ctx.store.resumeTargetForWrite(
                alloc,
                .last,
                ctx.workspace,
                failure.options(),
            ),
        );
        try std.testing.expectEqual(@as(usize, 2), failure.completed_count);
        try std.testing.expectEqual(@as(usize, 0), failure.contended_count);
    }

    const non_retryable = [_]anyerror{
        error.OutOfMemory,
        error.SessionBusy,
        error.SessionLockUnsupported,
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        error.InvalidSessionFormat,
        error.SessionPathUnsafe,
    };
    for (non_retryable) |injected_error| {
        var failure = LatestBarrierFailure{ .injected_error = injected_error };
        try std.testing.expectError(
            injected_error,
            ctx.store.resumeTargetForWrite(
                alloc,
                .last,
                ctx.workspace,
                failure.options(),
            ),
        );
        try std.testing.expectEqual(@as(usize, 1), failure.completed_count);
        try std.testing.expectEqual(@as(usize, 0), failure.contended_count);
    }

    var empty_control = ResumeInterleavingControl{};
    try std.testing.expectError(
        error.NoSavedSessions,
        ctx.store.resumeTargetForWrite(
            alloc,
            .last,
            ctx.workspace,
            empty_control.options(),
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        empty_control.barrier_completed_count.load(.seq_cst),
    );
}

test "latest reader waits for a discard already pending" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var reader_store = try Store.initFromHome(alloc, ctx.home, ctx.workspace);
    defer reader_store.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "pending-predecessor",
        ctx.workspace,
        20,
        "saved prompt",
    );
    var discard_control = DiscardPauseControl{};
    var target_state = try testDurableState(alloc, "pending-target", ctx.workspace);
    defer target_state.deinit(alloc);
    target_state.updated_at_ms = 30;
    var target = try ctx.store.startWritableSessionWithOptions(
        alloc,
        target_state,
        discard_control.logOptions(),
    );
    var target_owned = true;
    defer if (target_owned) target.deinit(alloc);

    discard_control.armed.store(true, .seq_cst);
    var discard_worker = DiscardWorker{
        .store = &ctx.store,
        .alloc = alloc,
        .loaded = &target,
    };
    const discard_thread = try std.Thread.spawn(.{}, DiscardWorker.run, .{&discard_worker});
    target_owned = false;
    var discard_joined = false;
    defer {
        discard_control.release.store(true, .seq_cst);
        if (!discard_joined) discard_thread.join();
    }
    try waitForTestFlag(&discard_control.pending);

    var reader_control = ResumeInterleavingControl{};
    var reader_worker = ResumeWorker{
        .store = &reader_store,
        .alloc = alloc,
        .workspace_root = ctx.workspace,
        .options = reader_control.options(),
    };
    defer reader_worker.deinitResult();
    const reader_thread = try std.Thread.spawn(.{}, ResumeWorker.run, .{&reader_worker});
    var reader_joined = false;
    defer {
        discard_control.release.store(true, .seq_cst);
        reader_control.release_session.store(true, .seq_cst);
        if (!reader_joined) reader_thread.join();
    }
    try waitForTestFlag(&reader_control.barrier_contended);

    discard_control.release.store(true, .seq_cst);
    discard_thread.join();
    discard_joined = true;
    reader_thread.join();
    reader_joined = true;

    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        discard_worker.disposition orelse return error.TestExpectedEqual,
    );
    try std.testing.expect(!discard_control.timed_out.load(.seq_cst));
    try std.testing.expect(!reader_control.timed_out.load(.seq_cst));
    try std.testing.expectEqual(
        @as(usize, 1),
        reader_control.barrier_completed_count.load(.seq_cst),
    );
    var resumed = try reader_worker.takeLoaded();
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("pending-predecessor", resumed.state.id);
}

test "cached latest reader revalidates a target discarded after open" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var reader_store = try Store.initFromHome(alloc, ctx.home, ctx.workspace);
    defer reader_store.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "cached-predecessor",
        ctx.workspace,
        20,
        "saved prompt",
    );
    var target_state = try testDurableState(alloc, "cached-target", ctx.workspace);
    defer target_state.deinit(alloc);
    target_state.updated_at_ms = 30;
    var target = try ctx.store.startWritableSession(alloc, target_state);
    var target_owned = true;
    defer if (target_owned) target.deinit(alloc);

    var reader_control = ResumeInterleavingControl{ .pause_on_session = true };
    var reader_worker = ResumeWorker{
        .store = &reader_store,
        .alloc = alloc,
        .workspace_root = ctx.workspace,
        .options = reader_control.options(),
    };
    defer reader_worker.deinitResult();
    const reader_thread = try std.Thread.spawn(.{}, ResumeWorker.run, .{&reader_worker});
    var reader_joined = false;
    defer {
        reader_control.release_session.store(true, .seq_cst);
        if (!reader_joined) reader_thread.join();
    }
    try waitForTestFlag(&reader_control.session_opened);

    const disposition = ctx.store.discardPristineStartedSession(alloc, &target);
    target_owned = false;
    try std.testing.expectEqual(PristineDiscardDisposition.discarded, disposition);
    reader_control.release_session.store(true, .seq_cst);
    reader_thread.join();
    reader_joined = true;

    try std.testing.expect(!reader_control.timed_out.load(.seq_cst));
    try std.testing.expect(!reader_control.barrier_contended.load(.seq_cst));
    try std.testing.expectEqual(
        @as(usize, 1),
        reader_control.barrier_completed_count.load(.seq_cst),
    );
    var resumed = try reader_worker.takeLoaded();
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("cached-predecessor", resumed.state.id);
}

test "latest reader retries when discard starts after an idle barrier" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var reader_store = try Store.initFromHome(alloc, ctx.home, ctx.workspace);
    defer reader_store.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "reader-first-predecessor",
        ctx.workspace,
        20,
        "saved prompt",
    );
    var publication_failure = MigrationBoundaryFailure{
        .target = .before_latest_cache_ready,
    };
    var target_state = try testDurableState(alloc, "reader-first-target", ctx.workspace);
    defer target_state.deinit(alloc);
    target_state.updated_at_ms = 30;
    var target = try ctx.store.startWritableSessionWithOptions(
        alloc,
        target_state,
        publication_failure.options().log,
    );
    var target_owned = true;
    defer if (target_owned) target.deinit(alloc);

    var reader_control = ResumeInterleavingControl{ .pause_on_session = true };
    var reader_worker = ResumeWorker{
        .store = &reader_store,
        .alloc = alloc,
        .workspace_root = ctx.workspace,
        .options = reader_control.options(),
    };
    defer reader_worker.deinitResult();
    const reader_thread = try std.Thread.spawn(.{}, ResumeWorker.run, .{&reader_worker});
    var reader_joined = false;
    defer {
        reader_control.release_session.store(true, .seq_cst);
        if (!reader_joined) reader_thread.join();
    }
    try waitForTestFlag(&reader_control.session_opened);
    try std.testing.expectEqual(
        @as(usize, 1),
        reader_control.barrier_completed_count.load(.seq_cst),
    );

    const disposition = ctx.store.discardPristineStartedSession(alloc, &target);
    target_owned = false;
    try std.testing.expectEqual(PristineDiscardDisposition.discarded, disposition);
    reader_control.release_session.store(true, .seq_cst);
    reader_thread.join();
    reader_joined = true;

    try std.testing.expect(!reader_control.timed_out.load(.seq_cst));
    try std.testing.expect(!reader_control.barrier_contended.load(.seq_cst));
    try std.testing.expectEqual(
        @as(usize, 2),
        reader_control.barrier_completed_count.load(.seq_cst),
    );
    var resumed = try reader_worker.takeLoaded();
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("reader-first-predecessor", resumed.state.id);
}

test "workspace latest pointer retains the higher session ID on an equal timestamp" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var higher = try testDurableState(alloc, "same-time-z", ctx.workspace);
    defer higher.deinit(alloc);
    higher.updated_at_ms = 20;
    var higher_writable = try ctx.store.startWritableSession(alloc, higher);
    higher_writable.deinit(alloc);

    var second_store = try Store.initFromHome(alloc, ctx.home, ctx.workspace);
    defer second_store.deinit(alloc);
    var lower = try testDurableState(alloc, "same-time-a", ctx.workspace);
    defer lower.deinit(alloc);
    lower.updated_at_ms = 20;
    var lower_writable = try second_store.startWritableSession(alloc, lower);
    lower_writable.deinit(alloc);

    var resumed = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(higher.id, resumed.state.id);
}

test "durable resume repairs legacy zero image ids without changing valid ids" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const session_id = "legacy-zero-image-ids";
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "legacy-first.png", .data = "\x89PNG\r\n\x1a\nfirst" });
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "legacy-second.png", .data = "\x89PNG\r\n\x1a\nsecond" });
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "legacy-valid.png", .data = "\x89PNG\r\n\x1a\nvalid" });
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "legacy-nine.png", .data = "\x89PNG\r\n\x1a\nnine" });
    const first_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "legacy-first.png");
    defer alloc.free(first_path);
    const second_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "legacy-second.png");
    defer alloc.free(second_path);
    const valid_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "legacy-valid.png");
    defer alloc.free(valid_path);
    const nine_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "legacy-nine.png");
    defer alloc.free(nine_path);
    var fixture: std.Io.Writer.Allocating = .init(alloc);
    defer fixture.deinit();
    try fixture.writer.writeAll(
        "{\"schema_version\":2,\"id\":\"legacy-zero-image-ids\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":",
    );
    try std.json.Stringify.value(ctx.workspace, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"conversation_language\":\"en\",\"history_len\":4,\"history\":[" ++
            "{\"kind\":\"assistant\",\"user\":{\"text\":\"first [Image #1]\",\"images\":[" ++
            "{\"path\":",
    );
    try std.json.Stringify.value(first_path, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"first answer\"}," ++
            "{\"kind\":\"assistant\",\"user\":{\"text\":\"second [Image #1]\",\"images\":[" ++
            "{\"path\":",
    );
    try std.json.Stringify.value(second_path, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"second answer\"}," ++
            "{\"kind\":\"assistant\",\"user\":{\"text\":\"existing [Image #3]\",\"images\":[" ++
            "{\"id\":3,\"path\":",
    );
    try std.json.Stringify.value(valid_path, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"existing answer\"}," ++
            "{\"kind\":\"assistant\",\"user\":{\"text\":\"later [Image #9]\",\"images\":[" ++
            "{\"path\":",
    );
    try std.json.Stringify.value(nine_path, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"later answer\"}" ++
            "],\"total_input_tokens\":0,\"total_output_tokens\":0}",
    );
    const fixture_text = try fixture.toOwnedSlice();
    defer alloc.free(fixture_text);
    const fixture_path = try writeSessionFixture(alloc, ctx.store, session_id, fixture_text);
    defer alloc.free(fixture_path);

    var resumed = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = session_id },
        ctx.workspace,
        .{},
    );
    var resumed_owned = true;
    defer if (resumed_owned) resumed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), resumed.state.history[0].assistant.user.images[0].id);
    try std.testing.expectEqual(@as(usize, 2), resumed.state.history[1].assistant.user.images[0].id);
    try std.testing.expectEqual(@as(usize, 3), resumed.state.history[2].assistant.user.images[0].id);
    try std.testing.expectEqual(@as(usize, 9), resumed.state.history[3].assistant.user.images[0].id);
    try std.testing.expectEqualStrings(
        "first [Image #1]",
        resumed.state.history[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "second [Image #2]",
        resumed.state.history[1].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        second_path,
        resumed.state.history[1].assistant.user.images[0].path,
    );

    const catalog = try session.collect_image_catalog(alloc, resumed.state.history, &.{});
    defer session.freeImageAttachmentSlice(alloc, catalog);
    try std.testing.expectEqual(@as(usize, 4), catalog.len);
    try std.testing.expectEqual(@as(usize, 1), catalog[0].id);
    try std.testing.expectEqual(@as(usize, 2), catalog[1].id);
    try std.testing.expectEqual(@as(usize, 3), catalog[2].id);
    try std.testing.expectEqual(@as(usize, 9), catalog[3].id);
    const image_bounds = try image_attachments.calculate_next_image_id(catalog);
    try std.testing.expectEqual(@as(usize, 9), image_bounds.maximum_id);
    try std.testing.expectEqual(@as(usize, 10), image_bounds.next_id);

    resumed.deinit(alloc);
    resumed_owned = false;
    var persisted = try ctx.store.loadReadOnly(alloc, session_id);
    defer persisted.deinit(alloc);
    try std.testing.expectEqualStrings(
        "first [Image #1]",
        persisted.history[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "second [Image #2]",
        persisted.history[1].assistant.user.text,
    );
    try std.testing.expectEqual(@as(usize, 1), persisted.history[0].assistant.user.images[0].id);
    try std.testing.expectEqual(@as(usize, 2), persisted.history[1].assistant.user.images[0].id);
}

test "durable resume does not follow a symlinked snapshot directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const session_id = "legacy-symlinked-images";
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "legacy.png",
        .data = "\x89PNG\r\n\x1a\nlegacy",
    });
    try tmp.dir.createDir(io_mod.getIo(), "outside", .default_dir);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "outside/sentinel",
        .data = "unchanged",
    });
    const image_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "legacy.png");
    defer alloc.free(image_path);
    const outside_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside");
    defer alloc.free(outside_path);

    var fixture: std.Io.Writer.Allocating = .init(alloc);
    defer fixture.deinit();
    try fixture.writer.writeAll(
        "{\"schema_version\":2,\"id\":\"legacy-symlinked-images\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":",
    );
    try std.json.Stringify.value(ctx.workspace, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
            "{\"kind\":\"assistant\",\"user\":{\"text\":\"legacy [Image #1]\",\"images\":[" ++
            "{\"path\":",
    );
    try std.json.Stringify.value(image_path, .{}, &fixture.writer);
    try fixture.writer.writeAll(
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"answer\"}]," ++
            "\"total_input_tokens\":0,\"total_output_tokens\":0}",
    );
    const fixture_text = try fixture.toOwnedSlice();
    defer alloc.free(fixture_text);
    const fixture_path = try writeSessionFixture(alloc, ctx.store, session_id, fixture_text);
    defer alloc.free(fixture_path);

    const session_dir_path = try sessionDirPath(alloc, ctx.store.sessions_dir, session_id);
    defer alloc.free(session_dir_path);
    var session_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), session_dir_path, .{});
    defer session_dir.close(io_mod.getIo());
    session_dir.symLink(io_mod.getIo(), outside_path, "images", .{
        .is_directory = true,
    }) catch |err| switch (err) {
        error.AccessDenied => return,
        else => return err,
    };

    var resumed = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = session_id },
        ctx.workspace,
        .{},
    );
    defer resumed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), resumed.state.history[0].assistant.user.images.len);
    var sentinel = try tmp.dir.openFile(io_mod.getIo(), "outside/sentinel", .{});
    defer sentinel.close(io_mod.getIo());
    const sentinel_bytes = try io_mod.readFileToEnd(alloc, &sentinel, 64);
    defer alloc.free(sentinel_bytes);
    try std.testing.expectEqualStrings("unchanged", sentinel_bytes);
}

test "workspace latest repair follows post-commit cache publication failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var creation_failure = MigrationBoundaryFailure{
        .target = .before_latest_cache_ready,
    };
    var state = try testDurableState(alloc, "latest-ready-failure", ctx.workspace);
    defer state.deinit(alloc);
    var created = try ctx.store.startWritableSessionWithOptions(
        alloc,
        state,
        creation_failure.options().log,
    );
    created.deinit(alloc);

    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(ctx.store, alloc, ctx.workspace),
    );

    var repaired_creation = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    repaired_creation.deinit(alloc);

    var replacement_failure = MigrationBoundaryFailure{
        .target = .before_latest_cache_ready,
    };
    var writer = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = state.id },
        ctx.workspace,
        replacement_failure.options(),
    );
    var replacement = try testDurableState(alloc, state.id, ctx.workspace);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 30;
    _ = try writer.commitStateReplacement(
        alloc,
        replacement,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writer.deinit(alloc);

    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(ctx.store, alloc, ctx.workspace),
    );

    var repaired_replacement = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer repaired_replacement.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 30), repaired_replacement.state.updated_at_ms);
}

test "workspace latest resolves a pending valid publication before discovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var initial = try testDurableState(alloc, "latest-pending-valid", ctx.workspace);
    defer initial.deinit(alloc);
    var writer = try ctx.store.startWritableSession(alloc, initial);
    var replacement = try testDurableState(alloc, initial.id, ctx.workspace);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 20;
    var failure = MigrationBoundaryFailure{ .target = .after_target_namespace_sync };
    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        writer.commitStateReplacement(
            alloc,
            replacement,
            .recovery,
            .retry_expected_tail,
            failure.options().log,
        ),
    );
    writer.deinit(alloc);

    const pending = try readPendingLatestSessionId(ctx.store, alloc, ctx.workspace) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(pending);
    try std.testing.expectEqualStrings(initial.id, pending);
    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(initial.id, resumed.state.id);
    try std.testing.expectEqual(@as(i64, 20), resumed.state.updated_at_ms);
    var ready = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestUnexpectedResult;
    defer ready.deinit(alloc);
    try std.testing.expectEqualStrings(initial.id, ready.session_id);
    try std.testing.expectEqual(@as(i64, 20), ready.updated_at_ms);
}

test "workspace latest rolls back a pending invalid publication then reranks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var newer_state = try testDurableState(alloc, "latest-newer-session", ctx.workspace);
    defer newer_state.deinit(alloc);
    newer_state.updated_at_ms = 30;
    var newer = try ctx.store.startWritableSession(alloc, newer_state);
    newer.deinit(alloc);

    var target_state = try testDurableState(alloc, "latest-invalid-target", ctx.workspace);
    defer target_state.deinit(alloc);
    var target = try ctx.store.startWritableSession(alloc, target_state);
    var replacement = try testDurableState(alloc, target_state.id, ctx.workspace);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 20;
    var failure = MigrationBoundaryFailure{ .target = .after_target_namespace_sync };
    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        target.commitStateReplacement(
            alloc,
            replacement,
            .recovery,
            .retry_expected_tail,
            failure.options().log,
        ),
    );
    const failed = target.degradedTail() orelse return error.TestUnexpectedResult;
    try corruptPendingReplacementTimestampForTest(
        alloc,
        ctx.store,
        target_state.id,
        failed.prior.through_event_log_bytes,
    );
    target.deinit(alloc);

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(newer_state.id, resumed.state.id);
    var rolled_back = try ctx.store.loadReadOnly(alloc, target_state.id);
    defer rolled_back.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 10), rolled_back.updated_at_ms);
    var ready = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestUnexpectedResult;
    defer ready.deinit(alloc);
    try std.testing.expectEqualStrings(newer_state.id, ready.session_id);
    try std.testing.expectEqual(@as(i64, 30), ready.updated_at_ms);
}

test "failed latest enrollment removes the uncommitted session directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var failure = MigrationBoundaryFailure{
        .target = .after_latest_cache_pending,
    };
    var state = try testDurableState(alloc, "latest-enrollment-failure", ctx.workspace);
    defer state.deinit(alloc);
    try std.testing.expectError(
        error.InjectedBoundaryFailure,
        ctx.store.startWritableSessionWithOptions(
            alloc,
            state,
            failure.options().log,
        ),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.openSessionDir(state.id),
    );
}

test "a writable session publishes latest after its Store is deinitialized" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try Store.initFromHome(alloc, home, workspace);
    var state = try testDurableState(alloc, "writer-outlives-store", workspace);
    defer state.deinit(alloc);
    var writer = try store.startWritableSession(alloc, state);
    store.deinit(alloc);

    _ = try writer.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    writer.deinit(alloc);

    var verifier = try Store.initFromHome(alloc, home, workspace);
    defer verifier.deinit(alloc);
    var resumed = try verifier.resumeTargetForWrite(
        alloc,
        .last,
        workspace,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("writer-outlives-store", resumed.state.id);
    try std.testing.expectEqual(@as(i64, 20), resumed.state.updated_at_ms);
}

test "workspace latest uses its bounded pointer when the summary cache is oversized" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "bounded-pointer", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    const oversized_summary = try alloc.alloc(u8, 256 * 1024 + 1);
    defer alloc.free(oversized_summary);
    @memset(oversized_summary, 'x');
    const summary_path = try std.fs.path.join(
        alloc,
        &.{ ctx.store.sessions_dir, session_summary_file },
    );
    defer alloc.free(summary_path);
    try writeRawFile(summary_path, oversized_summary);

    const broken = try writeSessionFixture(
        alloc,
        ctx.store,
        "would-fail-repair",
        "{\"schema_version\":1,",
    );
    defer alloc.free(broken);

    var resumed = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, resumed.state.id);
}

test "workspace rebind invalidates the old latest pointer before publishing the new one" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var state = try testDurableState(alloc, "workspace-rebound", workspace_a);
    defer state.deinit(alloc);
    var initial = try store_a.startWritableSession(alloc, state);
    const initial_generation = initial.position.log_generation;
    initial.deinit(alloc);

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    var rebound = try store_b.resumeTargetForWrite(
        alloc,
        .{ .id = state.id },
        workspace_b,
        .{ .log = .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        } },
    );
    defer rebound.deinit(alloc);

    try std.testing.expect(!std.mem.eql(
        u8,
        &initial_generation,
        &rebound.position.log_generation,
    ));
    try std.testing.expect(!rebound.needsFinalStateReplacement(false));
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(store_a, alloc, workspace_a),
    );
    const pointer_value = try readLatestPointer(store_b, alloc, workspace_b) orelse
        return error.TestExpectedEqual;
    var pointer = pointer_value;
    defer pointer.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, pointer.session_id);
}

fn expectWorkspaceRebindPublicationFailureRepair(
    session_id: []const u8,
    force_compaction: bool,
) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var state = try testDurableState(alloc, session_id, workspace_a);
    defer state.deinit(alloc);
    var initial = try store_a.startWritableSession(alloc, state);
    const initial_generation = initial.position.log_generation;
    initial.deinit(alloc);

    var failure = ArmedBoundaryFailure{
        .target = .before_latest_cache_ready,
        .armed = true,
    };
    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    var rebind_options = failure.logOptions();
    if (force_compaction) {
        rebind_options.compaction_frame_threshold = 1;
        rebind_options.compaction_byte_threshold = 1;
    }
    var rebound = try store_b.resumeTargetForWrite(
        alloc,
        .{ .id = state.id },
        workspace_b,
        .{ .log = rebind_options },
    );
    defer rebound.deinit(alloc);

    try std.testing.expectEqualStrings(workspace_b, rebound.state.workspace_root);
    try std.testing.expectEqual(
        force_compaction,
        !std.mem.eql(
            u8,
            &initial_generation,
            &rebound.position.log_generation,
        ),
    );
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(store_b, alloc, workspace_b),
    );
    try std.testing.expect(rebound.needsFinalStateReplacement(false));

    failure.armed = false;
    var current = try rebound.state.dupe(alloc);
    defer current.deinit(alloc);
    _ = try rebound.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!rebound.needsFinalStateReplacement(false));

    const pointer_value = try readLatestPointer(store_b, alloc, workspace_b) orelse
        return error.TestExpectedEqual;
    var pointer = pointer_value;
    defer pointer.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, pointer.session_id);
}

test "workspace rebind publication failure remains pending for shutdown repair" {
    try expectWorkspaceRebindPublicationFailureRepair(
        "workspace-rebind-publication-failure",
        false,
    );
}

test "workspace rebind publication failure after compaction remains pending for shutdown repair" {
    try expectWorkspaceRebindPublicationFailureRepair(
        "workspace-rebind-compaction-publication-failure",
        true,
    );
}

test "workspace rebind honors an immediate commit lock deadline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var state = try testDurableState(alloc, "workspace-rebind-lock-deadline", workspace_a);
    defer state.deinit(alloc);
    var initial = try store_a.startWritableSession(alloc, state);
    initial.deinit(alloc);

    var session_dir = try store_a.openSessionDir(state.id);
    defer session_dir.close();
    const Contention = struct {
        dir: *io_mod.VerifiedDir,
        commit_attempts: usize = 0,
        commit_lock: ?io_mod.TimedAdvisoryLock = null,

        fn lock(raw: ?*anyopaque, kind: session_log.LockKind) void {
            if (kind != .commit) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.commit_attempts += 1;
            if (self.commit_attempts != 2) return;
            self.commit_lock = io_mod.acquireTimedAdvisoryLock(
                self.dir,
                "commit.lock",
                2000,
            ) catch return;
        }
    };
    var contention = Contention{ .dir = &session_dir };
    defer if (contention.commit_lock) |*lock| lock.release();

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        store_b.resumeTargetForWrite(
            alloc,
            .{ .id = state.id },
            workspace_b,
            .{ .log = .{
                .test_controls = .{
                    .context = &contention,
                    .lock_fn = Contention.lock,
                },
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            } },
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), contention.commit_attempts);
    try std.testing.expect(contention.commit_lock != null);
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "workspace rebind honors an immediate latest cache lock deadline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var state = try testDurableState(alloc, "workspace-rebind-latest-lock-deadline", workspace_a);
    defer state.deinit(alloc);
    var initial = try store_a.startWritableSession(alloc, state);
    initial.deinit(alloc);

    var sessions = store_a.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        store_b.resumeTargetForWrite(
            alloc,
            .{ .id = state.id },
            workspace_b,
            .{ .log = .{
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            } },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "same-workspace append defers latest cache contention and marks cache dirty" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "existing-lifecycle-latest-deadline", ctx.workspace);
    defer state.deinit(alloc);
    var loaded = try ctx.store.startWritableSession(alloc, state);
    defer loaded.deinit(alloc);

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();

    const prior = loaded.position;
    const started_at_ms = io_mod.milliTimestamp();
    const committed = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
    try std.testing.expect(committed.through_seq > prior.through_seq);
    try std.testing.expectEqual(@as(?bool, true), loaded.state.preferences.fast_mode);

    var latest = try sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer latest.close(io_mod.getIo());
    var deferred = try latest.openDir(io_mod.getIo(), "deferred", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer deferred.close(io_mod.getIo());
    var token = try deferred.openFile(io_mod.getIo(), state.id, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer token.close(io_mod.getIo());
    const token_stat = try token.stat(io_mod.getIo());
    try std.testing.expectEqual(std.Io.File.Kind.file, token_stat.kind);
    try std.testing.expectEqual(@as(u32, 0o600), token_stat.permissions.toMode() & 0o777);
    const token_bytes = try io_mod.readFileToEnd(
        alloc,
        &token,
        summary_codec.max_deferred_cache_token_bytes,
    );
    defer alloc.free(token_bytes);
    var decoded = try summary_codec.decodeDeferredCacheToken(alloc, token_bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, decoded.session_id);
    try std.testing.expectEqualStrings(ctx.workspace, decoded.workspace_root);
    try std.testing.expectEqualDeep(committed, decoded.position);
}

test "deferred token failure prevents a same-workspace canonical commit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "deferred-token-failure", ctx.workspace);
    defer state.deinit(alloc);
    var loaded = try ctx.store.startWritableSession(alloc, state);
    defer loaded.deinit(alloc);

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest = try sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer latest.close(io_mod.getIo());
    var obstacle = try latest.createFile(io_mod.getIo(), "deferred", .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .resolve_beneath = true,
    });
    obstacle.close(io_mod.getIo());

    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    const prior = loaded.position;
    const prior_fast_mode = loaded.state.preferences.fast_mode;
    try std.testing.expectError(
        error.DurablePathUnsafe,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            20,
            .retry_expected_tail,
            .{ .commit_lock_deadline_ms = 0 },
        ),
    );
    try std.testing.expectEqualDeep(prior, loaded.position);
    try std.testing.expectEqual(prior_fast_mode, loaded.state.preferences.fast_mode);
}

test "same-workspace compaction replacement defers latest cache contention" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "deferred-replacement", ctx.workspace);
    defer state.deinit(alloc);
    var loaded = try ctx.store.startWritableSession(alloc, state);
    defer loaded.deinit(alloc);
    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 30;

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    const committed = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .compaction,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    try std.testing.expectEqual(@as(i64, 30), loaded.state.updated_at_ms);

    var latest = try sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer latest.close(io_mod.getIo());
    var deferred = try latest.openDir(io_mod.getIo(), "deferred", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer deferred.close(io_mod.getIo());
    var token = try deferred.openFile(io_mod.getIo(), state.id, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer token.close(io_mod.getIo());
    const token_bytes = try io_mod.readFileToEnd(
        alloc,
        &token,
        summary_codec.max_deferred_cache_token_bytes,
    );
    defer alloc.free(token_bytes);
    var decoded = try summary_codec.decodeDeferredCacheToken(alloc, token_bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualDeep(committed, decoded.position);
}

test "migration and recovery replacements keep latest cache contention strict" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "strict-replacement-cache-lock", ctx.workspace);
    defer state.deinit(alloc);
    var loaded = try ctx.store.startWritableSession(alloc, state);
    defer loaded.deinit(alloc);
    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 30;

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    const prior = loaded.position;
    for ([_]session_event.ReplacementReason{ .migration, .recovery }) |reason| {
        try std.testing.expectError(
            error.SessionCommitBoundaryUnavailable,
            loaded.commitStateReplacement(
                alloc,
                replacement,
                reason,
                .retry_expected_tail,
                .{ .commit_lock_deadline_ms = 0 },
            ),
        );
        try std.testing.expectEqualDeep(prior, loaded.position);
    }
}

test "session creation keeps latest cache contention strict" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "strict-creation-cache-lock", ctx.workspace);
    defer state.deinit(alloc);

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        ctx.store.startWritableSessionWithOptions(
            alloc,
            state,
            .{ .commit_lock_deadline_ms = 0 },
        ),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.openSessionDir(state.id),
    );
}

test "read-only session page replays canonical state for a deferred token" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "dirty-read-only-page", ctx.workspace);
    defer state.deinit(alloc);
    var loaded = try ctx.store.startWritableSession(alloc, state);
    defer loaded.deinit(alloc);

    var warm = try ctx.store.listResumablePage(alloc, null, null);
    warm.deinit(alloc);
    var session_dir = try ctx.store.openSessionDir(state.id);
    defer session_dir.close();
    var manifest_file = try session_dir.dir.openFile(io_mod.getIo(), "session.json", .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    const stale_manifest = try io_mod.readFileToEnd(
        alloc,
        &manifest_file,
        session_projection.manifest_max_bytes + 1,
    );
    manifest_file.close(io_mod.getIo());
    defer alloc.free(stale_manifest);

    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 30;
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .compaction,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    try io_mod.durableReplaceVerified(
        alloc,
        &session_dir,
        "session.json",
        stale_manifest,
    );

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    var page = try read_only.listSessionPage(
        alloc,
        .all_workspaces,
        null,
        session_list_default_limit,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqual(@as(i64, 30), page.summaries.items[0].updated_at_ms);
}

test "dirty readers do not replay an unrelated current long session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "dirty-bounded-target",
        ctx.workspace,
        30,
        "target prompt",
    );

    try writeLargeWritableHistoryFixture(
        alloc,
        ctx.store,
        "unrelated-current-long",
        ctx.workspace,
        20,
        512 * 1024,
    );

    try writeDeferredTokenForTest(
        alloc,
        ctx.store,
        "dirty-bounded-target",
        ctx.workspace,
    );

    var scratch: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var page = try ctx.store.listSessionPage(
        fixed.allocator(),
        .all_workspaces,
        null,
        10,
    );
    try std.testing.expectEqual(@as(usize, 2), page.summaries.items.len);
    try std.testing.expectEqualStrings(
        "dirty-bounded-target",
        page.summaries.items[0].id,
    );
    try std.testing.expectEqualStrings(
        "unrelated-current-long",
        page.summaries.items[1].id,
    );
    page.deinit(fixed.allocator());

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    var resume_scratch: [256 * 1024]u8 = undefined;
    var resume_fixed = std.heap.FixedBufferAllocator.init(&resume_scratch);
    var resumed = try ctx.store.resumeTargetForWrite(
        resume_fixed.allocator(),
        .last,
        ctx.workspace,
        .{ .log = .{ .commit_lock_deadline_ms = 0 } },
    );
    defer resumed.deinit(resume_fixed.allocator());
    try std.testing.expectEqualStrings(
        "dirty-bounded-target",
        resumed.active_id,
    );
    try std.testing.expectEqual(@as(i64, 30), resumed.state.updated_at_ms);
    try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
}

test "dirty list still replays an unrelated stale session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "dirty-stale-target",
        ctx.workspace,
        30,
        "target prompt",
    );

    try writeStaleWritableHistoryFixture(
        alloc,
        ctx.store,
        "unrelated-stale",
        ctx.workspace,
        40,
    );

    try writeDeferredTokenForTest(
        alloc,
        ctx.store,
        "dirty-stale-target",
        ctx.workspace,
    );

    var page = try ctx.store.listSessionPage(
        alloc,
        .all_workspaces,
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), page.summaries.items.len);
    try std.testing.expectEqualStrings(
        "unrelated-stale",
        page.summaries.items[0].id,
    );
    try std.testing.expectEqual(@as(i64, 40), page.summaries.items[0].updated_at_ms);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items[0].history_len);
}

test "malformed deferred token scope replays all stale sessions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeStaleWritableHistoryFixture(
        alloc,
        ctx.store,
        "malformed-token-stale",
        ctx.workspace,
        40,
    );
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest = try io_mod.openOrCreateVerifiedPrivateDir(
        &sessions,
        latest_sessions_dir,
    );
    defer latest.close();
    var deferred = try io_mod.openOrCreateVerifiedPrivateDir(
        &latest,
        summary_codec.deferred_cache_dir,
    );
    defer deferred.close();
    try io_mod.durableReplaceVerified(
        alloc,
        &deferred,
        "malformed-token",
        "{}",
    );

    var page = try ctx.store.listSessionPage(
        alloc,
        .all_workspaces,
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings(
        "malformed-token-stale",
        page.summaries.items[0].id,
    );
    try std.testing.expectEqual(@as(i64, 40), page.summaries.items[0].updated_at_ms);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items[0].history_len);
}

test "writable picker returns canonical results while deferred repair is busy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "dirty-writable-picker",
        ctx.workspace,
        20,
        "picker prompt",
    );
    var warm = try ctx.store.listResumablePage(alloc, null, null);
    warm.deinit(alloc);
    var writer = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = "dirty-writable-picker" },
        ctx.workspace,
        .{},
    );

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    _ = try writer.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    writer.deinit(alloc);

    var page = try ctx.store.listResumablePage(alloc, null, null);
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqual(@as(i64, 30), page.summaries.items[0].updated_at_ms);

    var latest = try sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer latest.close(io_mod.getIo());
    var deferred = try latest.openDir(io_mod.getIo(), "deferred", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer deferred.close(io_mod.getIo());
    var token = try deferred.openFile(io_mod.getIo(), "dirty-writable-picker", .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    token.close(io_mod.getIo());

    latest_lock.release();
    var repaired = try ctx.store.listResumablePage(alloc, null, null);
    repaired.deinit(alloc);
    try std.testing.expectError(
        error.FileNotFound,
        deferred.openFile(io_mod.getIo(), "dirty-writable-picker", .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }),
    );
}

test "writable resume last selects canonically while deferred repair is busy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "dirty-resume-a",
        ctx.workspace,
        20,
        "first prompt",
    );
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "dirty-resume-b",
        ctx.workspace,
        25,
        "second prompt",
    );
    var writer = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = "dirty-resume-a" },
        ctx.workspace,
        .{},
    );

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    _ = try writer.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    writer.deinit(alloc);

    var admission = (try ctx.store.admitResumeView(alloc, .last)) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("dirty-resume-a", admission.sessionId());
    admission.deinit(alloc);

    var resumed = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{ .log = .{ .commit_lock_deadline_ms = 0 } },
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("dirty-resume-a", resumed.active_id);
    try std.testing.expectEqual(@as(i64, 30), resumed.state.updated_at_ms);
}

test "incremental cache publication clears a stable deferred token" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "incremental-clears-deferred",
        ctx.workspace,
        20,
        "incremental prompt",
    );
    var warm = try ctx.store.listResumablePage(alloc, null, null);
    warm.deinit(alloc);
    var writer = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = "incremental-clears-deferred" },
        ctx.workspace,
        .{},
    );
    defer writer.deinit(alloc);
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    _ = try writer.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    latest_lock.release();
    _ = try writer.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = false } },
        40,
        .retry_expected_tail,
        .{},
    );
    try expectDeferredCacheTokenMissing(alloc, &sessions, writer.active_id);
}

test "deferred token compare-before-clear retains a newer token" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "newer-deferred-token", ctx.workspace);
    defer state.deinit(alloc);
    var writer = try ctx.store.startWritableSession(alloc, state);
    var writer_open = true;
    defer if (writer_open) writer.deinit(alloc);
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    _ = try writer.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );
    latest_lock.release();
    var observed = try summary_codec.readDeferredCacheTokens(alloc, &sessions);
    defer summary_codec.freeDeferredCacheTokens(alloc, &observed);
    try std.testing.expectEqual(@as(usize, 1), observed.items.len);
    writer.deinit(alloc);
    writer_open = false;

    var newer = observed.items[0].position;
    newer.through_seq += 1;
    newer.through_event_id = [_]u8{0xcd} ** 16;
    newer.through_event_log_bytes += 1;
    const cache = try LatestCache.init(alloc, &sessions, .{}, .maintain);
    defer cache.deinit(alloc);
    try cache.writeDeferredToken(
        alloc,
        state.id,
        ctx.workspace,
        newer,
    );
    try latest_pointer.clearObservedDeferredToken(
        alloc,
        &sessions,
        observed.items[0],
    );
    var current = (try summary_codec.readDeferredCacheToken(
        alloc,
        &sessions,
        state.id,
    )) orelse return error.TestExpectedEqual;
    defer current.deinit(alloc);
    try std.testing.expectEqualDeep(newer, current.position);
}

test "failed canonical publication retains a safe false-positive deferred token" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "false-positive-deferred", ctx.workspace);
    defer state.deinit(alloc);
    var writer = try ctx.store.startWritableSession(alloc, state);
    defer writer.deinit(alloc);
    const prior = writer.position;
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    var failure = MigrationBoundaryFailure{ .target = .after_event_sync };
    var options = failure.options().log;
    options.commit_lock_deadline_ms = 0;
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        writer.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            30,
            .retry_expected_tail,
            options,
        ),
    );
    latest_lock.release();
    try std.testing.expectEqualDeep(prior, writer.position);

    var page = try ctx.store.listResumablePage(alloc, null, null);
    page.deinit(alloc);
    var token = (try summary_codec.readDeferredCacheToken(
        alloc,
        &sessions,
        state.id,
    )) orelse return error.TestExpectedEqual;
    defer token.deinit(alloc);
    try std.testing.expect(token.position.through_seq > prior.through_seq);
}

test "dirty relationship and managed-child candidates use canonical summaries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "dirty-candidate-summary", ctx.workspace);
    defer state.deinit(alloc);
    var writer = try ctx.store.startWritableSession(alloc, state);
    defer writer.deinit(alloc);
    var replacement = try writer.state.dupe(alloc);
    defer replacement.deinit(alloc);
    replacement.updated_at_ms = 30;
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    _ = try writer.commitStateReplacement(
        alloc,
        replacement,
        .compaction,
        .retry_expected_tail,
        .{ .commit_lock_deadline_ms = 0 },
    );

    var managed = try ctx.store.listManagedChildCandidatesForWorkspace(alloc);
    defer freeSummaries(alloc, &managed);
    try std.testing.expectEqual(@as(usize, 1), managed.items.len);
    try std.testing.expectEqual(@as(i64, 30), managed.items[0].updated_at_ms);

    var relationship = try ctx.store.listRelationshipMigrationCandidates(
        alloc,
        .{},
    );
    defer relationship.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), relationship.ids.items.len);
    try std.testing.expectEqualStrings(
        "dirty-candidate-summary",
        relationship.ids.items[0],
    );
}

test "writable repair removes a stable orphan deferred token" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    const cache = try LatestCache.init(alloc, &sessions, .{}, .maintain);
    defer cache.deinit(alloc);
    try cache.writeDeferredToken(
        alloc,
        "orphan-deferred-token",
        ctx.workspace,
        .{
            .log_generation = [_]u8{0x12} ** 16,
            .through_seq = 1,
            .through_event_id = [_]u8{0xab} ** 16,
            .through_event_log_bytes = 100,
        },
    );

    var page = try ctx.store.listResumablePage(alloc, null, null);
    page.deinit(alloc);
    try expectDeferredCacheTokenMissing(
        alloc,
        &sessions,
        "orphan-deferred-token",
    );
}

test "pristine discard removes its deferred token" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "discard-deferred-token", ctx.workspace);
    defer state.deinit(alloc);
    var loaded = try ctx.store.startWritableSession(alloc, state);
    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    const cache = try LatestCache.init(alloc, &sessions, .{}, .maintain);
    defer cache.deinit(alloc);
    try cache.writeDeferredToken(
        alloc,
        loaded.active_id,
        loaded.state.workspace_root,
        loaded.position,
    );

    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.discardPristineStartedSession(alloc, &loaded),
    );
    try expectDeferredCacheTokenMissing(alloc, &sessions, state.id);
}

test "degraded-tail recovery republishes the workspace latest pointer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "latest-degraded-tail", ctx.workspace);
    defer state.deinit(alloc);
    var writer = try ctx.store.startWritableSession(alloc, state);
    var failure = MigrationBoundaryFailure{ .target = .after_event_sync };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        writer.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            20,
            .retry_expected_tail,
            failure.options().log,
        ),
    );
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(ctx.store, alloc, ctx.workspace),
    );

    var recovered_state = try testDurableState(alloc, state.id, ctx.workspace);
    defer recovered_state.deinit(alloc);
    recovered_state.updated_at_ms = 20;
    recovered_state.preferences.fast_mode = true;
    try writer.retryDegradedWithStateReplacement(
        alloc,
        recovered_state,
        .{},
    );
    writer.deinit(alloc);

    const pointer_value = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    var pointer = pointer_value;
    defer pointer.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, pointer.session_id);
    try std.testing.expectEqual(@as(i64, 20), pointer.updated_at_ms);
}

test "workspace latest pointer bypasses unrelated authority repair" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var selected = try testDurableState(alloc, "pointer-workspace-a", workspace_a);
    defer selected.deinit(alloc);
    var selected_writable = try store_a.startWritableSession(alloc, selected);
    selected_writable.deinit(alloc);

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    try writeLegacyFixture(alloc, store_b, "unrelated-fenced", workspace_b, 20);
    try writeFixtureEntry(
        alloc,
        store_b,
        "unrelated-fenced",
        "authority.pending.json",
        "{\"schema_version\":1,\"session_id\":\"unrelated-fenced\",\"operation_id\":\"11111111111111111111111111111111\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"22222222222222222222222222222222\",\"prior\":{\"storage_format\":\"legacy_snapshot_v1\",\"primary_bytes\":1,\"primary_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"proposed\":{\"storage_format\":\"event_log_v1\",\"log_generation\":\"33333333333333333333333333333333\",\"through_seq\":1,\"through_event_id\":\"44444444444444444444444444444444\",\"through_event_log_bytes\":1}}",
    );

    var resumed = try store_a.resumeTargetForWrite(
        alloc,
        .last,
        workspace_a,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(selected.id, resumed.state.id);
}

test "legacy migration publishes a workspace latest pointer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-pointer", ctx.workspace, 20);

    var migrated = try ctx.store.resumeForWrite(alloc, "legacy-pointer");
    migrated.deinit(alloc);

    const pointer_value = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    var pointer = pointer_value;
    defer pointer.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-pointer", pointer.session_id);
    try std.testing.expectEqual(@as(i64, 20), pointer.updated_at_ms);
}

test "legacy migration leaves a repairable pointer when ready publication fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-pointer-pending", ctx.workspace, 20);

    var failure = MigrationBoundaryFailure{
        .target = .before_latest_cache_ready,
    };
    var migrated = try ctx.store.resumeTargetForWrite(
        alloc,
        .{ .id = "legacy-pointer-pending" },
        ctx.workspace,
        failure.options(),
    );
    migrated.deinit(alloc);

    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(ctx.store, alloc, ctx.workspace),
    );
    var repaired = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer repaired.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-pointer-pending", repaired.state.id);
}

test "workspace latest repair does not skip candidates with unknown workspace identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var valid = try testDurableState(alloc, "known-workspace", ctx.workspace);
    defer valid.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, valid);
    writable.deinit(alloc);

    const broken = try writeSessionFixture(
        alloc,
        ctx.store,
        "unknown-workspace",
        "{\"schema_version\":1,",
    );
    defer alloc.free(broken);

    try std.testing.expectError(
        error.InvalidSessionFormat,
        ctx.store.resumeLatestByDiscovery(alloc, ctx.workspace, .{}),
    );
}

test "writable session child capability remains stable after owner move" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(
        alloc,
        "session-child-capability-owner-move",
        ctx.workspace,
    );
    defer state.deinit(alloc);

    var original = try ctx.store.startWritableSession(alloc, state);
    const borrowed_before_move = try original.childCapability();
    var moved = original;
    original = undefined;
    defer moved.deinit(alloc);

    const borrowed_after_move = try moved.childCapability();
    try std.testing.expect(borrowed_before_move == borrowed_after_move);

    var control_entries = try borrowed_before_move.iterate(alloc, .subagent_control);
    defer control_entries.deinit();
    try std.testing.expectEqual(@as(usize, 0), control_entries.names.len);
}

test "session store delegates schema v3 authority operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "session-store-schema-v3", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    const authority_path = try std.fs.path.join(
        alloc,
        &.{ ctx.store.sessions_dir, state.id, "authority.json" },
    );
    defer alloc.free(authority_path);
    var authority = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        authority_path,
        .{},
    );
    authority.close(io_mod.getIo());

    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, "hello", "world");
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = 20,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 11,
        .total_output_tokens = 7,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );

    var loaded = try ctx.store.loadReadOnly(alloc, state.id);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), loaded.history.len);
    try std.testing.expectEqualStrings("world", loaded.history[0].assistant.assistant);
    try std.testing.expectEqual(@as(u64, 11), loaded.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 7), loaded.total_output_tokens);
}

test "schema v3 load repairs duplicate-key tool arguments before gateway projection" {
    const types = @import("../shared/types.zig");
    const alloc = std.testing.allocator;
    const duplicate_arguments = "{\"depth\":1,\"depth\":2}";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const trace_path = try std.fs.path.join(alloc, &.{ ctx.home, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var calls = [_]session.ToolCall{.{
        .id = @constCast("persisted_duplicate_call"),
        .name = @constCast("list_files"),
        .arguments_json = @constCast(duplicate_arguments),
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("persisted_duplicate_call"),
        .tool_name = @constCast("list_files"),
        .status = .success,
        .output = @constCast("stale success"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
        .created_at_ms = 1,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("failed"),
        .execution = .{ .tool_steps = steps[0..] },
    } };

    var state = try testDurableState(alloc, "schema-v3-duplicate-arguments", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    const owned_turn = try session.dupeHistoryTurn(alloc, turn);
    var owns_turn = true;
    errdefer if (owns_turn) session.freeHistoryTurn(alloc, owned_turn);
    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = owned_turn;
    owns_turn = false;
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = 20,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 1,
        .total_output_tokens = 1,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);

    var loaded = try ctx.store.loadReadOnly(alloc, state.id);
    defer loaded.deinit(alloc);
    const loaded_step = loaded.history[0].assistant.execution.tool_steps[0];
    try std.testing.expectEqualStrings("{}", loaded_step.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, loaded_step.tool_calls[0].argument_integrity);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, loaded_step.tool_results[0].status);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try session.appendHistoryChatMessages(arena, &messages, loaded.history);
    try messages.append(arena, .{ .role = .user, .content = "continue" });
    try std.testing.expectEqualStrings("{}", messages.items[1].tool_calls[0].arguments_json);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?, "tool_execution_failed") != null);

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=persisted_tool_arguments_repaired") != null);
    try std.testing.expect(std.mem.find(u8, trace, "source=schema_v3") != null);
    try std.testing.expect(std.mem.find(u8, trace, duplicate_arguments) == null);
}

test "doctor cleanup reopens an inspected session with guarded write authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "doctor-cleanup", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var read_store = try Store.initReadOnlyFromHome(
        alloc,
        ctx.home,
        ctx.workspace,
    );
    defer read_store.deinit(alloc);
    const report = try read_store.cleanupForDoctor(alloc, state.id);
    try std.testing.expectEqual(@as(usize, 0), report.removed);
    try std.testing.expectEqual(@as(usize, 0), report.report_only);
}

test "doctor skips the workspace latest publication directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "doctor-skips-latest", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var diagnostics = try ctx.store.inspectForDoctor(alloc);
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    for (diagnostics.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(
            u8,
            diagnostic.session_id,
            "latest",
        ));
        try std.testing.expect(!std.mem.eql(
            u8,
            diagnostic.session_id,
            state.id,
        ));
    }
}

test "bounded doctor inspection exhausts under limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try makeSessionDir(alloc, ctx.store, "doctor-bounded-under-0");
    try makeSessionDir(alloc, ctx.store, "doctor-bounded-under-1");

    var result = try ctx.store.inspectForDoctorBounded(alloc, 3);
    defer result.deinit(alloc);

    try std.testing.expect(!result.truncated);
    try std.testing.expectEqual(@as(usize, 2), result.inspected_count);
    try std.testing.expectEqual(@as(usize, 2), result.diagnostics.items.len);
    for (result.diagnostics.items) |diagnostic| {
        try std.testing.expectEqual(DoctorIssueKind.missing_authority, diagnostic.kind);
    }
}

test "bounded doctor inspection stops at valid session limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try makeRawSessionsEntry(ctx.store, "latest");
    try makeRawSessionsEntry(ctx.store, "not a session");
    try makeSessionDir(alloc, ctx.store, "doctor-bounded-over-0");
    try makeSessionDir(alloc, ctx.store, "doctor-bounded-over-1");
    try makeSessionDir(alloc, ctx.store, "doctor-bounded-over-2");

    var bounded = try ctx.store.inspectForDoctorBounded(alloc, 2);
    defer bounded.deinit(alloc);

    try std.testing.expect(bounded.truncated);
    try std.testing.expectEqual(@as(usize, 2), bounded.inspected_count);
    try std.testing.expectEqual(@as(usize, 2), bounded.diagnostics.items.len);

    var full = try ctx.store.inspectForDoctor(alloc);
    defer freeDoctorDiagnostics(alloc, &full);
    try std.testing.expectEqual(@as(usize, 3), full.items.len);
}

test "doctor reports unsafe managed child artifacts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "doctor-child-unsafe", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    const session_path = try sessionDirPath(alloc, ctx.store.sessions_dir, state.id);
    defer alloc.free(session_path);
    var session_dir = try std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        session_path,
        .{ .iterate = true },
    );
    defer session_dir.close(io_mod.getIo());
    try session_dir.createDir(
        io_mod.getIo(),
        "tool-results",
        std.Io.File.Permissions.fromMode(0o755),
    );
    var managed_dir = try session_dir.openDir(
        io_mod.getIo(),
        "tool-results",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer managed_dir.close(io_mod.getIo());
    try managed_dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o755));

    var diagnostics = try ctx.store.inspectForDoctor(alloc);
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    var found = false;
    for (diagnostics.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.session_id, state.id) and
            diagnostic.kind == .unsafe_path)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "doctor reports corrupt subagent control records without hiding the session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "doctor-subagent-corrupt", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    {
        var capability = try writable.childCapability();
        var corrupt = try capability.createExclusiveFile(
            alloc,
            .subagent_control,
            "control.json",
        );
        defer corrupt.deinit();
        try corrupt.writeAll("{\"schema_version\":1");
        try corrupt.sync();
    }
    writable.deinit(alloc);

    var summaries = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    var listed = false;
    for (summaries.items) |summary| {
        if (std.mem.eql(u8, summary.id, "doctor-subagent-corrupt")) listed = true;
    }
    try std.testing.expect(listed);

    var diagnostics = try ctx.store.inspectForDoctor(alloc);
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    var found = false;
    for (diagnostics.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.session_id, "doctor-subagent-corrupt") and
            diagnostic.kind == .canonical_state_invalid)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "doctor ignores legacy task records" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeLegacyFixture(alloc, ctx.store, "doctor-legacy-child-corrupt", ctx.workspace, 20);
    const session_path = try sessionDirPath(
        alloc,
        ctx.store.sessions_dir,
        "doctor-legacy-child-corrupt",
    );
    defer alloc.free(session_path);
    var session_dir = try std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        session_path,
        .{ .iterate = true },
    );
    defer session_dir.close(io_mod.getIo());
    try session_dir.setPermissions(
        io_mod.getIo(),
        std.Io.File.Permissions.fromMode(0o700),
    );
    try session_dir.createDir(
        io_mod.getIo(),
        "tasks",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const corrupt_path = try std.fs.path.join(alloc, &.{
        session_path,
        "tasks",
        "1.json",
    });
    defer alloc.free(corrupt_path);
    try writeRawFile(
        corrupt_path,
        "{broken",
    );
    chmodPath(alloc, corrupt_path, 0o600) catch return error.SkipZigTest;

    var diagnostics = try ctx.store.inspectForDoctor(alloc);
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    var found = false;
    for (diagnostics.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.session_id, "doctor-legacy-child-corrupt") and
            diagnostic.kind == .canonical_state_invalid)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(!found);
}

test "doctor distinguishes missing invalid and mismatched commit watermarks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const fixture_kinds = [_]DoctorIssueKind{
        .commit_watermark_missing,
        .commit_watermark_invalid,
        .commit_watermark_mismatched,
    };
    for (fixture_kinds, 0..) |expected_kind, index| {
        const session_id = try std.fmt.allocPrint(
            alloc,
            "doctor-watermark-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var state = try testDurableState(alloc, session_id, ctx.workspace);
        defer state.deinit(alloc);
        var writable = try ctx.store.startWritableSession(alloc, state);
        const generation_hex = std.fmt.bytesToHex(
            writable.position.log_generation,
            .lower,
        );
        writable.deinit(alloc);

        const watermark_name = try std.fmt.allocPrint(
            alloc,
            "commit.{s}.json",
            .{generation_hex},
        );
        defer alloc.free(watermark_name);
        const watermark_path = try std.fs.path.join(alloc, &.{
            ctx.store.sessions_dir,
            session_id,
            watermark_name,
        });
        defer alloc.free(watermark_path);
        switch (expected_kind) {
            .commit_watermark_missing => try std.Io.Dir.deleteFileAbsolute(
                io_mod.getIo(),
                watermark_path,
            ),
            .commit_watermark_invalid => try writeRawFile(watermark_path, "{}\n"),
            .commit_watermark_mismatched => try writeRawFile(
                watermark_path,
                "{\"schema_version\":1,\"session_id\":\"wrong-session\",\"log_generation\":\"00000000000000000000000000000000\",\"through_seq\":1,\"through_event_id\":\"00000000000000000000000000000000\",\"through_event_log_bytes\":1}\n",
            ),
            else => unreachable,
        }
    }

    var diagnostics = try ctx.store.inspectForDoctor(alloc);
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    for (fixture_kinds, 0..) |expected_kind, index| {
        const expected_id = try std.fmt.allocPrint(
            alloc,
            "doctor-watermark-{d}",
            .{index},
        );
        defer alloc.free(expected_id);
        var found = false;
        for (diagnostics.items) |diagnostic| {
            if (std.mem.eql(u8, diagnostic.session_id, expected_id) and
                diagnostic.kind == expected_kind)
            {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "recovery copies the exact manifest boundary and leaves the source unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-watermark-invalid";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "saved prompt",
    );
    var source = try ctx.store.resumeForWrite(alloc, source_id);
    try source.writeCheckpointIfDue(alloc, true, .{});
    const generation = source.position.log_generation;
    source.deinit(alloc);
    const checkpoint_path = try std.fs.path.join(
        alloc,
        &.{ ctx.store.sessions_dir, source_id, "checkpoint.json" },
    );
    defer alloc.free(checkpoint_path);
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), checkpoint_path);

    const events_before = try readFixtureFile(
        alloc,
        ctx.store,
        source_id,
        "events.jsonl",
        1024 * 1024,
    );
    defer alloc.free(events_before);
    const manifest_before = try readFixtureFile(
        alloc,
        ctx.store,
        source_id,
        "session.json",
        session_projection.manifest_max_bytes,
    );
    defer alloc.free(manifest_before);

    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        source_id,
        watermark_name,
        "{}\n",
    );
    try std.testing.expectError(
        error.InvalidSessionFormat,
        ctx.store.resumeForWrite(alloc, source_id),
    );

    var result = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(source_id, result.source_session_id);
    try std.testing.expectEqual(@as(usize, 1), result.history_len);
    try std.testing.expect(!std.mem.eql(
        u8,
        source_id,
        result.recovered_session_id,
    ));

    const events_after = try readFixtureFile(
        alloc,
        ctx.store,
        source_id,
        "events.jsonl",
        1024 * 1024,
    );
    defer alloc.free(events_after);
    const manifest_after = try readFixtureFile(
        alloc,
        ctx.store,
        source_id,
        "session.json",
        session_projection.manifest_max_bytes,
    );
    defer alloc.free(manifest_after);
    try std.testing.expectEqualSlices(u8, events_before, events_after);
    try std.testing.expectEqualSlices(u8, manifest_before, manifest_after);

    {
        var recovered = try ctx.store.resumeForWrite(
            alloc,
            result.recovered_session_id,
        );
        defer recovered.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), recovered.state.history.len);
        try std.testing.expectEqualStrings(
            "saved prompt",
            recovered.state.history[0].assistant.user.text,
        );
    }
    var latest = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings(
        result.recovered_session_id,
        latest.session_id,
    );
    var resumed_last = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed_last.deinit(alloc);
    try std.testing.expectEqualStrings(
        result.recovered_session_id,
        resumed_last.state.id,
    );
    try std.testing.expectEqualStrings(
        "saved prompt",
        resumed_last.state.history[0].assistant.user.text,
    );
}

test "recovery copy preserves incomplete compacted authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-incomplete-authority";
    try writeWritableIncompleteAuthorityFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
    );
    var source = try ctx.store.resumeForWrite(alloc, source_id);
    try source.writeCheckpointIfDue(alloc, true, .{});
    const generation = source.position.log_generation;
    source.deinit(alloc);

    const checkpoint_path = try std.fs.path.join(
        alloc,
        &.{ ctx.store.sessions_dir, source_id, "checkpoint.json" },
    );
    defer alloc.free(checkpoint_path);
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), checkpoint_path);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        source_id,
        watermark_name,
        "{}\n",
    );

    var result = try ctx.store.recoverSessionCopy(alloc, source_id, .{});
    defer result.deinit(alloc);
    var recovered = try ctx.store.resumeForWrite(
        alloc,
        result.recovered_session_id,
    );
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), recovered.state.history.len);
    try std.testing.expect(
        !recovered.state.history[0].compacted_summary.root_user_messages_complete,
    );
    try std.testing.expect(
        !recovered.state.history[0].compacted_summary.permission_feedback_complete,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        recovered.state.history[0].compacted_summary.permission_feedback.len,
    );
}

test "recovery accepts missing and mismatched commit watermarks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    for ([_]DoctorIssueKind{
        .commit_watermark_missing,
        .commit_watermark_mismatched,
    }, 0..) |kind, index| {
        var id_buffer: [64]u8 = undefined;
        const source_id = try std.fmt.bufPrint(
            &id_buffer,
            "recover-watermark-{d}",
            .{index},
        );
        try writeWritableHistoryFixture(
            alloc,
            ctx.store,
            source_id,
            ctx.workspace,
            20,
            "saved boundary",
        );
        var source = try ctx.store.resumeForWrite(alloc, source_id);
        const generation = source.position.log_generation;
        source.deinit(alloc);
        const generation_hex = std.fmt.bytesToHex(generation, .lower);
        const watermark_name = try std.fmt.allocPrint(
            alloc,
            "commit.{s}.json",
            .{generation_hex},
        );
        defer alloc.free(watermark_name);

        switch (kind) {
            .commit_watermark_missing => {
                const session_dir = try sessionDirPath(
                    alloc,
                    ctx.store.sessions_dir,
                    source_id,
                );
                defer alloc.free(session_dir);
                const watermark_path = try std.fs.path.join(
                    alloc,
                    &.{ session_dir, watermark_name },
                );
                defer alloc.free(watermark_path);
                try std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    watermark_path,
                );
            },
            .commit_watermark_mismatched => try writeFixtureEntry(
                alloc,
                ctx.store,
                source_id,
                watermark_name,
                "{\"schema_version\":1,\"session_id\":\"wrong-session\",\"log_generation\":\"00000000000000000000000000000000\",\"through_seq\":1,\"through_event_id\":\"00000000000000000000000000000000\",\"through_event_log_bytes\":1}\n",
            ),
            else => unreachable,
        }

        var result = try ctx.store.recoverSessionCopy(
            alloc,
            source_id,
            .{},
        );
        defer result.deinit(alloc);
        try std.testing.expectEqual(
            SessionRecoveryStatus.recovered,
            result.status,
        );
        var recovered = try ctx.store.resumeForWrite(
            alloc,
            result.recovered_session_id,
        );
        defer recovered.deinit(alloc);
        try std.testing.expectEqualStrings(
            "saved boundary",
            recovered.state.history[0].assistant.user.text,
        );
    }
}

test "recovery resolves a target commit reported indeterminate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-commit-resolution";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "saved through uncertain commit",
    );
    var source = try ctx.store.resumeForWrite(alloc, source_id);
    const generation = source.position.log_generation;
    source.deinit(alloc);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        source_id,
        watermark_name,
        "{}\n",
    );

    var failure = MigrationBoundaryFailure{
        .target = .after_target_namespace_sync,
    };
    var result = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        failure.options().log,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionRecoveryStatus.recovered, result.status);

    var recovered = try ctx.store.resumeForWrite(
        alloc,
        result.recovered_session_id,
    );
    defer recovered.deinit(alloc);
    try std.testing.expectEqualStrings(
        "saved through uncertain commit",
        recovered.state.history[0].assistant.user.text,
    );
}

test "indeterminate recovery resolution leaves no published target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-target-reported";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "saved target",
    );
    var source = try ctx.store.resumeForWrite(alloc, source_id);
    const generation = source.position.log_generation;
    source.deinit(alloc);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        source_id,
        watermark_name,
        "{}\n",
    );
    var sessions_before = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_before);
    var latest_before = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_before.deinit(alloc);

    try std.testing.expectError(
        error.SessionRecoveryIndeterminate,
        ctx.store.recoverSessionCopy(
            alloc,
            source_id,
            RecoveryResolutionFailure.options(),
        ),
    );

    var sessions_after = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_after);
    var latest_after = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_after.deinit(alloc);
    try std.testing.expectEqualStrings(
        latest_before.session_id,
        latest_after.session_id,
    );
    try std.testing.expectEqual(
        sessions_before.items.len,
        sessions_after.items.len,
    );
    for (sessions_before.items, sessions_after.items) |before, after| {
        try std.testing.expectEqualStrings(before.id, after.id);
    }
}

test "pre-intent recovery failure removes the unpublished pristine target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-pre-intent-cleanup";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "saved before target commit",
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    var sessions_before = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_before);
    var latest_before = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_before.deinit(alloc);
    var failure = MigrationBoundaryFailure{
        .target = .after_event_sync,
        .remaining_matches = 1,
    };

    try std.testing.expectError(
        error.SessionRecoveryIndeterminate,
        ctx.store.recoverSessionCopy(
            alloc,
            source_id,
            failure.options().log,
        ),
    );

    var sessions_after = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_after);
    var latest_after = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_after.deinit(alloc);
    try std.testing.expectEqualStrings(
        latest_before.session_id,
        latest_after.session_id,
    );
    try std.testing.expectEqual(
        sessions_before.items.len,
        sessions_after.items.len,
    );
    for (sessions_before.items, sessions_after.items) |before, after| {
        try std.testing.expectEqualStrings(before.id, after.id);
    }
}

test "abandoned recovery staging stays invisible and does not replace unrelated latest" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-staging-source";
    const healthy_id = "recover-staging-healthy";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "damaged older conversation",
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        healthy_id,
        ctx.workspace,
        30,
        "newer healthy conversation",
    );

    var staged_state = try testDurableState(
        alloc,
        "abandoned-recovery-target",
        ctx.workspace,
    );
    defer staged_state.deinit(alloc);
    var staging_root = try ctx.store.initRecoveryStagingRoot(alloc);
    const abandoned_path = try sessionDirPath(
        alloc,
        staging_root.display_root,
        staged_state.id,
    );
    defer alloc.free(abandoned_path);
    var abandoned = try ctx.store.startRecoveryStagedSession(
        alloc,
        &staging_root,
        staged_state,
        .{},
    );
    abandoned.deinit(alloc);
    staging_root.deinit(alloc);

    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.resumeForWrite(alloc, "abandoned-recovery-target"),
    );
    var before = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &before);
    for (before.items) |summary| {
        try std.testing.expect(!std.mem.eql(
            u8,
            summary.id,
            "abandoned-recovery-target",
        ));
    }

    var recovered = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        .{},
    );
    defer recovered.deinit(alloc);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openDirAbsolute(
            io_mod.getIo(),
            abandoned_path,
            .{ .follow_symlinks = false },
        ),
    );
    var resumed_last = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed_last.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_id,
        resumed_last.state.id,
    );
    try std.testing.expectEqualStrings(
        "newer healthy conversation",
        resumed_last.state.history[0].assistant.user.text,
    );
}

test "recovery preserves discovered latest when pointer and index are unavailable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-missing-latest-source";
    const healthy_id = "recover-missing-latest-healthy";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "damaged older conversation",
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        healthy_id,
        ctx.workspace,
        30,
        "newer healthy conversation",
    );

    const sessions = &ctx.store.canonical_root.sessions.?;
    try summary_codec.writeSessionIndexMarker(alloc, sessions);
    var latest = io_mod.VerifiedDir{ .dir = try sessions.dir.openDir(
        io_mod.getIo(),
        latest_sessions_dir,
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer latest.close();
    var pointer_name: ?[]u8 = null;
    defer if (pointer_name) |name| alloc.free(name);
    var entries = latest.dir.iterate();
    while (try entries.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file) continue;
        pointer_name = try alloc.dupe(u8, entry.name);
        break;
    }
    try latest.dir.deleteFile(
        io_mod.getIo(),
        pointer_name orelse return error.TestExpectedEqual,
    );
    try io_mod.syncVerifiedDir(latest.dir);
    var missing_latest = try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    );
    defer if (missing_latest) |*pointer| pointer.deinit(alloc);
    try std.testing.expect(missing_latest == null);
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readSessionIndex(alloc, sessions),
    );

    var recovered = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        .{},
    );
    defer recovered.deinit(alloc);
    var latest_after = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_after.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_id,
        latest_after.session_id,
    );
    var resumed_last = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed_last.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_id,
        resumed_last.state.id,
    );
}

test "cross-workspace recovery preserves each workspace latest pointer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace-a",
    );
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace-b",
    );
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    const source_id = "cross-workspace-recovery-source";
    const healthy_a_id = "cross-workspace-recovery-healthy-a";
    try writeWritableHistoryFixture(
        alloc,
        store_a,
        source_id,
        workspace_a,
        20,
        "damaged workspace A conversation",
    );
    try corruptFixtureWatermark(alloc, store_a, source_id);
    try writeWritableHistoryFixture(
        alloc,
        store_a,
        healthy_a_id,
        workspace_a,
        30,
        "healthy workspace A conversation",
    );

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    const newest_b_id = "cross-workspace-recovery-newest-b";
    try writeWritableHistoryFixture(
        alloc,
        store_b,
        newest_b_id,
        workspace_b,
        80,
        "newest workspace B conversation",
    );

    var recovered = try store_b.recoverSessionCopy(
        alloc,
        source_id,
        .{},
    );
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(
        SessionRecoveryStatus.recovered,
        recovered.status,
    );

    var latest_a = (try readLatestPointer(
        store_a,
        alloc,
        workspace_a,
    )) orelse return error.TestExpectedEqual;
    defer latest_a.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_a_id,
        latest_a.session_id,
    );
    var latest_b = (try readLatestPointer(
        store_b,
        alloc,
        workspace_b,
    )) orelse return error.TestExpectedEqual;
    defer latest_b.deinit(alloc);
    try std.testing.expectEqualStrings(
        newest_b_id,
        latest_b.session_id,
    );

    var resumed_a = try store_a.resumeTargetForWrite(
        alloc,
        .last,
        workspace_a,
        .{},
    );
    defer resumed_a.deinit(alloc);
    try std.testing.expectEqualStrings(healthy_a_id, resumed_a.state.id);
    var resumed_b = try store_b.resumeTargetForWrite(
        alloc,
        .last,
        workspace_b,
        .{},
    );
    defer resumed_b.deinit(alloc);
    try std.testing.expectEqualStrings(newest_b_id, resumed_b.state.id);
}

test "concurrent latest publication wins over recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-latest-race-source";
    const healthy_id = "recover-latest-race-healthy";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "damaged conversation",
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    const Race = struct {
        alloc: Allocator,
        store: Store,
        workspace: []const u8,
        healthy_id: []const u8,
        fired: bool = false,

        fn boundary(raw: ?*anyopaque, point: session_log.Boundary) !void {
            if (point != .before_recovery_latest_publication) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fired) return;
            self.fired = true;
            try writeWritableHistoryFixture(
                self.alloc,
                self.store,
                self.healthy_id,
                self.workspace,
                30,
                "concurrent healthy conversation",
            );
        }
    };
    var race = Race{
        .alloc = alloc,
        .store = ctx.store,
        .workspace = ctx.workspace,
        .healthy_id = healthy_id,
    };
    var recovered = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        .{ .test_controls = .{
            .context = &race,
            .boundary_fn = Race.boundary,
        } },
    );
    defer recovered.deinit(alloc);
    try std.testing.expect(race.fired);

    var resumed_last = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed_last.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_id,
        resumed_last.state.id,
    );
}

test "recovery retries latest selection after concurrent pending publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-latest-pending-race-source";
    const healthy_id = "recover-latest-pending-race-healthy";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "damaged conversation",
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    const Race = struct {
        alloc: Allocator,
        store: Store,
        workspace: []const u8,
        healthy_id: []const u8,
        fired: bool = false,

        fn boundary(raw: ?*anyopaque, point: session_log.Boundary) !void {
            if (point != .after_recovery_latest_snapshot) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fired) return;
            self.fired = true;
            try writeWritableHistoryFixture(
                self.alloc,
                self.store,
                self.healthy_id,
                self.workspace,
                30,
                "concurrent healthy conversation",
            );
            var failure = MigrationBoundaryFailure{
                .target = .before_latest_cache_ready,
            };
            var writer = try self.store.resumeTargetForWrite(
                self.alloc,
                .{ .id = self.healthy_id },
                self.workspace,
                failure.options(),
            );
            defer writer.deinit(self.alloc);
            var replacement = try writer.state.dupe(self.alloc);
            defer replacement.deinit(self.alloc);
            replacement.updated_at_ms = 40;
            _ = try writer.commitStateReplacement(
                self.alloc,
                replacement,
                .recovery,
                .retry_expected_tail,
                .{},
            );
        }
    };
    var race = Race{
        .alloc = alloc,
        .store = ctx.store,
        .workspace = ctx.workspace,
        .healthy_id = healthy_id,
    };
    var recovered = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        .{ .test_controls = .{
            .context = &race,
            .boundary_fn = Race.boundary,
        } },
    );
    defer recovered.deinit(alloc);
    try std.testing.expect(race.fired);

    var latest_after = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_after.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_id,
        latest_after.session_id,
    );
    try std.testing.expectEqual(@as(i64, 40), latest_after.updated_at_ms);
    var resumed_last = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed_last.deinit(alloc);
    try std.testing.expectEqualStrings(
        healthy_id,
        resumed_last.state.id,
    );
    try std.testing.expectEqual(
        @as(i64, 40),
        resumed_last.state.updated_at_ms,
    );
}

test "recovery reports a complete target when latest publication fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-latest-reported";
    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        20,
        "saved before latest publication",
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    var failure = MigrationBoundaryFailure{
        .target = .before_latest_cache_ready,
    };

    var result = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        failure.options().log,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        SessionRecoveryStatus.indeterminate,
        result.status,
    );

    var recovered = try ctx.store.resumeForWrite(
        alloc,
        result.recovered_session_id,
    );
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        recovered.state.history.len,
    );
    try std.testing.expectEqualStrings(
        "saved before latest publication",
        recovered.state.history[0].assistant.user.text,
    );
}

test "recovery refuses a session whose commit watermark is valid" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(
        alloc,
        "recover-valid-refused",
        ctx.workspace,
    );
    defer state.deinit(alloc);
    var source = try ctx.store.startWritableSession(alloc, state);
    source.deinit(alloc);

    try std.testing.expectError(
        error.SessionRecoveryNotNeeded,
        ctx.store.recoverSessionCopy(
            alloc,
            "recover-valid-refused",
            .{},
        ),
    );
}

test "recovery verifies and copies persisted image snapshots into the new session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const source_id = "recover-image-copy";
    var initial = try testDurableState(alloc, source_id, ctx.workspace);
    defer initial.deinit(alloc);
    var source = try ctx.store.startWritableSession(alloc, initial);
    var source_owned = true;
    defer if (source_owned) source.deinit(alloc);

    const source_images = try std.fs.path.join(
        alloc,
        &.{ ctx.store.sessions_dir, source_id, "images" },
    );
    defer alloc.free(source_images);
    try std.Io.Dir.createDirAbsolute(
        io_mod.getIo(),
        source_images,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const image_bytes = "\x89PNG\r\n\x1a\nrecovery-image";
    var digest_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_bytes, &digest_bytes, .{});
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    const image_name = try std.fmt.allocPrint(
        alloc,
        "image-1-{s}.bin",
        .{digest_hex[0..16]},
    );
    defer alloc.free(image_name);
    const source_image_path = try std.fs.path.join(
        alloc,
        &.{ source_images, image_name },
    );
    defer alloc.free(source_image_path);
    var image_file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        source_image_path,
        .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        },
    );
    try image_file.writeStreamingAll(io_mod.getIo(), image_bytes);
    try image_file.sync(io_mod.getIo());
    image_file.close(io_mod.getIo());

    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(
        alloc,
        "inspect the image",
        "saved image response",
    );
    defer session.freeHistoryTurnSlice(alloc, history);
    history[0].assistant.user.images = try session.dupeImageAttachmentSlice(
        alloc,
        &.{.{
            .id = 1,
            .path = @constCast("/tmp/source.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = source_image_path,
            .snapshot_sha256 = @constCast(digest_hex[0..]),
        }},
    );
    const desired = session_codec.DurableSessionState{
        .id = source.state.id,
        .origin_workspace_root = source.state.origin_workspace_root,
        .workspace_root = source.state.workspace_root,
        .created_at_ms = source.state.created_at_ms,
        .updated_at_ms = 20,
        .conversation_language = source.state.conversation_language,
        .preferences = source.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try source.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    try source.writeCheckpointIfDue(alloc, true, .{});
    const generation = source.position.log_generation;
    source.deinit(alloc);
    source_owned = false;

    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        source_id,
        watermark_name,
        "{}\n",
    );

    var result = try ctx.store.recoverSessionCopy(
        alloc,
        source_id,
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        SessionRecoveryStatus.recovered,
        result.status,
    );
    var recovered = try ctx.store.resumeForWrite(
        alloc,
        result.recovered_session_id,
    );
    defer recovered.deinit(alloc);
    const copied = recovered.state.history[0].assistant.user.images[0];
    try std.testing.expect(std.mem.find(
        u8,
        copied.snapshot_path.?,
        result.recovered_session_id,
    ) != null);
    try std.testing.expect(!std.mem.eql(
        u8,
        copied.snapshot_path.?,
        source_image_path,
    ));
    var verified = try image_attachments.loadVerifiedSnapshot(
        alloc,
        copied,
        .{},
    );
    defer verified.deinit(alloc);
    try std.testing.expectEqualSlices(u8, image_bytes, verified.bytes);

    var source_image = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        source_image_path,
        .{},
    );
    source_image.close(io_mod.getIo());
    var source_verified = try image_attachments.loadVerifiedSnapshot(
        alloc,
        history[0].assistant.user.images[0],
        .{},
    );
    defer source_verified.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        image_bytes,
        source_verified.bytes,
    );

    var sessions_before_missing_image = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_before_missing_image);
    try std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        source_image_path,
    );
    try std.testing.expectError(
        error.SessionRecoveryBoundaryInvalid,
        ctx.store.recoverSessionCopy(alloc, source_id, .{}),
    );
    var sessions_after_missing_image = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_after_missing_image);
    try std.testing.expectEqual(
        sessions_before_missing_image.items.len,
        sessions_after_missing_image.items.len,
    );
    for (
        sessions_before_missing_image.items,
        sessions_after_missing_image.items,
    ) |before, after| {
        try std.testing.expectEqualStrings(before.id, after.id);
    }
}

test "recovery copies referenced tool results and command replays" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const source_id = "recover-managed-children";
    try writeWritableManagedHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        true,
        .{
            .legacy_replay = true,
            .legacy_command_artifact = true,
        },
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);

    var result = try ctx.store.recoverSessionCopy(alloc, source_id, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        SessionRecoveryStatus.recovered_with_unverified_artifacts,
        result.status,
    );
    var recovered = try ctx.store.resumeForWrite(
        alloc,
        result.recovered_session_id,
    );
    defer recovered.deinit(alloc);
    const capability = recovered.child_capability orelse
        return error.SessionChildStoreFailed;
    const stored_result = recovered.state.history[0]
        .assistant.execution.tool_steps[0]
        .tool_results[0];
    var output_file = try capability.openFileReadOnly(
        alloc,
        .tool_results,
        stored_result.output_handle orelse return error.TestExpectedEqual,
    );
    defer output_file.deinit();
    const output = try output_file.readToEnd(alloc, 1024);
    defer alloc.free(output);
    try std.testing.expectEqualStrings(
        "complete recovered tool result",
        output,
    );
    const replay = stored_result.command_output_replay orelse
        return error.TestExpectedEqual;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedEqual,
    };
    try std.testing.expect(
        !command_replay_store.hasContentDigest(descriptor.handle),
    );
    var replay_reader = try command_replay_store.Reader.open(
        alloc,
        capability,
        descriptor,
    );
    defer replay_reader.deinit();
    var replay_output: std.ArrayList(u8) = .empty;
    defer replay_output.deinit(alloc);
    while (try replay_reader.nextByte()) |byte| {
        try replay_output.append(alloc, byte.value);
    }
    try std.testing.expectEqualStrings(
        "recovered command replay",
        replay_output.items,
    );
    const interrupted = recovered.state.history[1].interrupted;
    const cancelled = interrupted.cancelled_command orelse
        return error.TestExpectedEqual;
    const artifact_handle = cancelled.command_artifact_handle orelse
        return error.TestExpectedEqual;
    var artifact_file = try capability.openFileReadOnly(
        alloc,
        .command_artifacts,
        artifact_handle,
    );
    defer artifact_file.deinit();
    const artifact = try artifact_file.readToEnd(alloc, 1024);
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings(
        "interrupted command artifact",
        artifact,
    );

    const source_artifact_path = try std.fs.path.join(
        alloc,
        &.{
            ctx.store.sessions_dir,
            source_id,
            "logs",
            "commands",
            artifact_handle,
        },
    );
    defer alloc.free(source_artifact_path);
    try std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        source_artifact_path,
    );
    var sessions_before_missing_artifact = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_before_missing_artifact);
    try std.testing.expectError(
        error.SessionRecoveryBoundaryInvalid,
        ctx.store.recoverSessionCopy(alloc, source_id, .{}),
    );
    var sessions_after_missing_artifact = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_after_missing_artifact);
    try std.testing.expectEqual(
        sessions_before_missing_artifact.items.len,
        sessions_after_missing_artifact.items.len,
    );
}

test "recovery reports legacy artifact mutations as unverified" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    for ([_]enum { replay, command_artifact }{
        .replay,
        .command_artifact,
    }, 0..) |legacy_kind, index| {
        var id_buffer: [64]u8 = undefined;
        const source_id = try std.fmt.bufPrint(
            &id_buffer,
            "recover-legacy-artifact-{d}",
            .{index},
        );
        try writeWritableManagedHistoryFixture(
            alloc,
            ctx.store,
            source_id,
            ctx.workspace,
            true,
            switch (legacy_kind) {
                .replay => .{ .legacy_replay = true },
                .command_artifact => .{
                    .legacy_command_artifact = true,
                },
            },
        );
        var source = try ctx.store.loadReadOnly(alloc, source_id);
        const handle = switch (legacy_kind) {
            .replay => switch (source.history[0]
                .assistant.execution.tool_steps[0]
                .tool_results[0]
                .command_output_replay orelse
                return error.TestExpectedEqual) {
                .available => |descriptor| descriptor.handle,
                .unavailable => return error.TestExpectedEqual,
            },
            .command_artifact => source.history[1]
                .interrupted.cancelled_command.?
                .command_artifact_handle orelse
                return error.TestExpectedEqual,
        };
        const owned_handle = try alloc.dupe(u8, handle);
        source.deinit(alloc);
        defer alloc.free(owned_handle);
        const entry = try std.fmt.allocPrint(
            alloc,
            "logs/commands/{s}",
            .{owned_handle},
        );
        defer alloc.free(entry);

        switch (legacy_kind) {
            .replay => {
                const payload = "recovered command replaX";
                var replay: [8 + 9 + payload.len]u8 = undefined;
                @memcpy(replay[0..8], "FXRPLY01");
                replay[8] = 0;
                std.mem.writeInt(
                    u64,
                    replay[9..17],
                    payload.len,
                    .little,
                );
                @memcpy(replay[17..], payload);
                try writeFixtureEntry(
                    alloc,
                    ctx.store,
                    source_id,
                    entry,
                    &replay,
                );
            },
            .command_artifact => try writeFixtureEntry(
                alloc,
                ctx.store,
                source_id,
                entry,
                "interrupted command artifacX",
            ),
        }
        try corruptFixtureWatermark(alloc, ctx.store, source_id);
        var recovered = try ctx.store.recoverSessionCopy(
            alloc,
            source_id,
            .{},
        );
        defer recovered.deinit(alloc);
        try std.testing.expectEqual(
            SessionRecoveryStatus.recovered_with_unverified_artifacts,
            recovered.status,
        );
    }
}

test "recovery authenticates content-addressed command artifacts" {
    const alloc = std.testing.allocator;
    const contents = "interrupted command artifact";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    const handle = try artifact_digest.contentAddressedHandle(
        alloc,
        "fx-command-cancelled.log",
        ".log",
        digest,
    );
    defer alloc.free(handle);

    try validateRecoveredManagedChildDigest(
        .command_artifacts,
        handle,
        null,
        digest,
    );
    std.crypto.hash.sha2.Sha256.hash(
        "interrupted command artifacX",
        &digest,
        .{},
    );
    try std.testing.expectError(
        error.SessionRecoveryBoundaryInvalid,
        validateRecoveredManagedChildDigest(
            .command_artifacts,
            handle,
            null,
            digest,
        ),
    );
}

test "recovery rejects corrupt managed children without leaking a target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    for ([_]enum { result_content, replay_content }{
        .result_content,
        .replay_content,
    }, 0..) |failure, index| {
        var id_buffer: [64]u8 = undefined;
        const source_id = try std.fmt.bufPrint(
            &id_buffer,
            "recover-corrupt-managed-{d}",
            .{index},
        );
        try writeWritableManagedHistoryFixture(
            alloc,
            ctx.store,
            source_id,
            ctx.workspace,
            true,
            .{},
        );
        var fixture = try ctx.store.loadReadOnly(alloc, source_id);
        const fixture_result = fixture.history[0]
            .assistant.execution.tool_steps[0]
            .tool_results[0];
        const output_handle = try alloc.dupe(
            u8,
            fixture_result.output_handle orelse
                return error.TestExpectedEqual,
        );
        defer alloc.free(output_handle);
        const replay_descriptor = switch (fixture_result.command_output_replay orelse
            return error.TestExpectedEqual) {
            .available => |value| value,
            .unavailable => return error.TestExpectedEqual,
        };
        const replay_handle = try alloc.dupe(
            u8,
            replay_descriptor.handle,
        );
        defer alloc.free(replay_handle);
        fixture.deinit(alloc);
        switch (failure) {
            .result_content => {
                const path = try std.fmt.allocPrint(
                    alloc,
                    "tool-results/{s}",
                    .{output_handle},
                );
                defer alloc.free(path);
                try writeFixtureEntry(
                    alloc,
                    ctx.store,
                    source_id,
                    path,
                    "complete recovered tool resulu",
                );
            },
            .replay_content => {
                const replay_payload = "recovered command replaX";
                var replay_bytes: [8 + 9 + replay_payload.len]u8 = undefined;
                @memcpy(replay_bytes[0..8], "FXRPLY01");
                replay_bytes[8] = 0;
                std.mem.writeInt(
                    u64,
                    replay_bytes[9..17],
                    replay_payload.len,
                    .little,
                );
                @memcpy(replay_bytes[17..], replay_payload);
                const path = try std.fmt.allocPrint(
                    alloc,
                    "logs/commands/{s}",
                    .{replay_handle},
                );
                defer alloc.free(path);
                try writeFixtureEntry(
                    alloc,
                    ctx.store,
                    source_id,
                    path,
                    &replay_bytes,
                );
            },
        }
        try corruptFixtureWatermark(alloc, ctx.store, source_id);
        var sessions_before = try ctx.store.list(alloc);
        defer freeSummaries(alloc, &sessions_before);

        try std.testing.expectError(
            error.SessionRecoveryBoundaryInvalid,
            ctx.store.recoverSessionCopy(alloc, source_id, .{}),
        );

        var sessions_after = try ctx.store.list(alloc);
        defer freeSummaries(alloc, &sessions_after);
        try std.testing.expectEqual(
            sessions_before.items.len,
            sessions_after.items.len,
        );
        for (sessions_before.items, sessions_after.items) |before, after| {
            try std.testing.expectEqualStrings(before.id, after.id);
        }
    }
}

test "failed recovery does not publish a pristine target as latest" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const source_id = "recover-unpublished-failure";
    try writeWritableManagedHistoryFixture(
        alloc,
        ctx.store,
        source_id,
        ctx.workspace,
        false,
        .{},
    );
    try corruptFixtureWatermark(alloc, ctx.store, source_id);
    var sessions_before = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_before);
    var latest_before = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_before.deinit(alloc);

    try std.testing.expectError(
        error.SessionRecoveryBoundaryInvalid,
        ctx.store.recoverSessionCopy(alloc, source_id, .{}),
    );

    var latest_after = (try readLatestPointer(
        ctx.store,
        alloc,
        ctx.workspace,
    )) orelse return error.TestExpectedEqual;
    defer latest_after.deinit(alloc);
    var sessions_after = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &sessions_after);
    try std.testing.expectEqualStrings(
        latest_before.session_id,
        latest_after.session_id,
    );
    try std.testing.expectEqual(
        sessions_before.items.len,
        sessions_after.items.len,
    );
    for (sessions_before.items, sessions_after.items) |before, after| {
        try std.testing.expectEqualStrings(before.id, after.id);
    }
}

test "doctor reports failed automatic compaction with committed growth" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(
        alloc,
        "doctor-compaction-failed",
        ctx.workspace,
    );
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    const FailCompaction = struct {
        fn boundary(_: ?*anyopaque, point: session_log.Boundary) !void {
            if (point == .after_compaction_watermark_sync) {
                return error.InjectedCompactionFailure;
            }
        }
    };
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{
            .test_controls = .{ .boundary_fn = FailCompaction.boundary },
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );
    const expected_bytes = writable.position.through_event_log_bytes;
    const expected_growth_bytes =
        expected_bytes - writable.generation_base_bytes;
    const expected_growth_frames =
        writable.position.through_seq - writable.generation_base_seq;
    writable.deinit(alloc);

    var diagnostics = try ctx.store.inspectForDoctorWithOptions(alloc, .{
        .compaction_frame_threshold = 1,
        .compaction_byte_threshold = 1,
    });
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    for (diagnostics.items) |diagnostic| {
        if (diagnostic.kind != .canonical_log_compaction_failed) continue;
        try std.testing.expectEqual(expected_bytes, diagnostic.bytes.?);
        try std.testing.expectEqual(
            expected_growth_bytes,
            diagnostic.growth_bytes.?,
        );
        try std.testing.expectEqual(
            expected_growth_frames,
            diagnostic.growth_frames.?,
        );
        return;
    }
    return error.TestExpectedEqual;
}

test "doctor distinguishes overdue growth from a failed compaction artifact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(
        alloc,
        "doctor-compaction-overdue",
        ctx.workspace,
    );
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);

    var diagnostics = try ctx.store.inspectForDoctorWithOptions(alloc, .{
        .compaction_frame_threshold = 1,
        .compaction_byte_threshold = 1,
    });
    defer freeDoctorDiagnostics(alloc, &diagnostics);
    var found_overdue = false;
    for (diagnostics.items) |diagnostic| {
        if (!std.mem.eql(
            u8,
            diagnostic.session_id,
            "doctor-compaction-overdue",
        )) continue;
        try std.testing.expect(
            diagnostic.kind != .canonical_log_compaction_failed,
        );
        if (diagnostic.kind == .canonical_log_compaction_overdue) {
            found_overdue = true;
        }
    }
    try std.testing.expect(found_overdue);
}

test "session store schema v3 facade accepts dotted session IDs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "session.v3.branch", ctx.workspace);
    defer state.deinit(alloc);

    var started = try ctx.store.startWritableSession(alloc, state);
    started.deinit(alloc);

    var read_only = try ctx.store.loadReadOnly(alloc, state.id);
    defer read_only.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, read_only.id);

    var resumed = try ctx.store.resumeForWrite(alloc, state.id);
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, resumed.state.id);
}

test "session store schema v3 facade accepts 255 byte session IDs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var session_id: [255]u8 = undefined;
    @memset(&session_id, 'a');
    var state = try testDurableState(alloc, &session_id, ctx.workspace);
    defer state.deinit(alloc);

    var started = try ctx.store.startWritableSession(alloc, state);
    started.deinit(alloc);

    var read_only = try ctx.store.loadReadOnly(alloc, state.id);
    defer read_only.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &session_id, read_only.id);

    var resumed = try ctx.store.resumeForWrite(alloc, state.id);
    defer resumed.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &session_id, resumed.state.id);
}

test "list newest-first" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    inline for (.{
        .{ "older", "{\"schema_version\":1,\"id\":\"older\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}" },
        .{ "newer", "{\"schema_version\":1,\"id\":\"newer\",\"created_at_ms\":3,\"updated_at_ms\":9,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"es\",\"history_len\":0,\"history\":[]}" },
    }) |fixture| {
        const path = try writeSessionFixture(alloc, ctx.store, fixture[0], fixture[1]);
        defer alloc.free(path);
    }
    var listed = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &listed);
    try std.testing.expectEqual(@as(usize, 2), listed.items.len);
    try std.testing.expectEqualStrings("newer", listed.items[0].id);
    try std.testing.expectEqualStrings("older", listed.items[1].id);
}

test "session scan probes managed children only when requested" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "managed-child-probe", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    {
        const header_bytes = try relationship_index_codec.encodeHeader(alloc, .{
            .high_watermark = 1,
            .active_count = 1,
        });
        defer alloc.free(header_bytes);
        var capability = try writable.childCapability();
        var header_file = try capability.createExclusiveFile(
            alloc,
            .subagent_control,
            session_child_store.subagent_relationship_index_file,
        );
        defer header_file.deinit();
        try header_file.writeAll(header_bytes);
        try header_file.sync();
    }
    writable.deinit(alloc);

    var shallow = try ctx.store.scanSessionSummariesWithDiagnostics(
        alloc,
        .read_only_list,
        false,
    );
    defer shallow.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), shallow.summaries.items.len);
    try std.testing.expect(!shallow.summaries.items[0].has_managed_children);

    var probing = try ctx.store.scanSessionSummariesWithDiagnostics(
        alloc,
        .read_only_list,
        true,
    );
    defer probing.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), probing.summaries.items.len);
    try std.testing.expect(probing.summaries.items[0].has_managed_children);
}

test "session discovery accepts the usage recovery name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "usage-recovery", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var listed = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &listed);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings(state.id, listed.items[0].id);

    var inspection = try ctx.store.inspectForDoctorBounded(alloc, 1);
    defer inspection.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), inspection.inspected_count);

    var resumed = try ctx.store.resumeLatestByDiscovery(
        alloc,
        ctx.workspace,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, resumed.state.id);
}

test "list does not write a session summary index" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const fixture =
        "{\"schema_version\":1,\"id\":\"valid\",\"created_at_ms\":3,\"updated_at_ms\":9," ++
        "\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"es\",\"history_len\":0,\"history\":[]}";
    const path = try writeSessionFixture(alloc, ctx.store, "valid", fixture);
    defer alloc.free(path);

    var listed = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &listed);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);

    const index_path = try std.fs.path.join(alloc, &.{ ctx.store.sessions_dir, "index.json" });
    defer alloc.free(index_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io_mod.getIo(), index_path, .{}),
    );
}

test "workspace list filters by workspace without changing global list" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    try writeSummaryFixture(alloc, ctx.store, "workspace-a-older", ctx.workspace, 20, 0);
    try writeSummaryFixture(alloc, ctx.store, "workspace-a-newer", ctx.workspace, 40, 0);
    try writeSummaryFixture(alloc, ctx.store, "workspace-b-newest", workspace_b, 60, 0);
    try writeSummaryFixture(alloc, ctx.store, "missing-workspace", null, 80, 0);

    var global = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &global);
    try std.testing.expectEqual(@as(usize, 4), global.items.len);
    try std.testing.expectEqualStrings("missing-workspace", global.items[0].id);
    try std.testing.expectEqualStrings("workspace-b-newest", global.items[1].id);

    var workspace_a = try ctx.store.listForWorkspace(alloc);
    defer freeSummaries(alloc, &workspace_a);
    try std.testing.expectEqual(@as(usize, 2), workspace_a.items.len);
    try std.testing.expectEqualStrings("workspace-a-newer", workspace_a.items[0].id);
    try std.testing.expectEqualStrings("workspace-a-older", workspace_a.items[1].id);

    var store_b = try Store.initReadOnlyFromHome(alloc, ctx.home, workspace_b);
    defer store_b.deinit(alloc);
    var workspace_b_list = try store_b.listForWorkspace(alloc);
    defer freeSummaries(alloc, &workspace_b_list);
    try std.testing.expectEqual(@as(usize, 1), workspace_b_list.items.len);
    try std.testing.expectEqualStrings("workspace-b-newest", workspace_b_list.items[0].id);

    const index_path = try std.fs.path.join(alloc, &.{ ctx.store.sessions_dir, "index.json" });
    defer alloc.free(index_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io_mod.getIo(), index_path, .{}),
    );
}

test "managed child candidate list prefers the workspace index snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const summaries = [_]SessionSummary{
        testIndexedSessionSummary("indexed-current", ctx.workspace, 20),
        testIndexedSessionSummary("indexed-other", "/tmp/other-workspace", 10),
    };
    var sessions = ctx.store.canonical_root.sessions orelse
        return error.TestExpectedEqual;
    try summary_codec.writeSessionIndex(alloc, &sessions, &summaries);
    try summary_codec.writeSessionIndexMarker(alloc, &sessions);
    try std.testing.expectError(
        error.InvalidSessionIndex,
        summary_codec.readSessionIndex(alloc, &sessions),
    );

    var listed = try ctx.store.listManagedChildCandidatesForWorkspace(alloc);
    defer freeSummaries(alloc, &listed);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("indexed-current", listed.items[0].id);
}

test "workspace latest ignores newer sessions from other workspaces" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    try writeSummaryFixture(alloc, ctx.store, "workspace-a-older", ctx.workspace, 20, 0);
    try writeSummaryFixture(alloc, ctx.store, "workspace-a-selected", ctx.workspace, 40, 0);
    try writeSummaryFixture(alloc, ctx.store, "workspace-b-newest", workspace_b, 80, 0);
    try writeSummaryFixture(alloc, ctx.store, "missing-workspace", null, 100, 0);

    var latest_global = try ctx.store.latestReadOnlySummary(alloc);
    defer latest_global.deinit(alloc);
    try std.testing.expectEqualStrings("missing-workspace", latest_global.id);

    var latest_a = try ctx.store.latestReadOnlyWorkspaceSummary(alloc);
    defer latest_a.deinit(alloc);
    try std.testing.expectEqualStrings("workspace-a-selected", latest_a.id);

    var store_b = try Store.initReadOnlyFromHome(alloc, ctx.home, workspace_b);
    defer store_b.deinit(alloc);
    var latest_b = try store_b.latestReadOnlyWorkspaceSummary(alloc);
    defer latest_b.deinit(alloc);
    try std.testing.expectEqualStrings("workspace-b-newest", latest_b.id);
}

test "workspace session pages prefer the bounded index and include empty sessions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const other_workspace = "/tmp/other-workspace";
    const summaries = [_]SessionSummary{
        testIndexedSessionSummary("session-005", ctx.workspace, 50),
        testIndexedSessionSummary("other-004", other_workspace, 45),
        testIndexedSessionSummary("session-004", ctx.workspace, 40),
        testIndexedSessionSummary("session-003", ctx.workspace, 30),
        testIndexedSessionSummary("session-002", ctx.workspace, 20),
        testIndexedSessionSummary("session-001", ctx.workspace, 10),
    };
    var sessions = ctx.store.canonical_root.sessions orelse
        return error.TestExpectedEqual;
    try summary_codec.writeSessionIndex(alloc, &sessions, &summaries);

    var first = try ctx.store.listWorkspacePage(alloc, null, 2);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), first.summaries.items.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqualStrings("session-005", first.summaries.items[0].id);
    try std.testing.expectEqualStrings("session-004", first.summaries.items[1].id);
    try std.testing.expectEqual(@as(usize, 0), first.summaries.items[0].history_len);

    var profile = try ctx.store.listSessionPage(alloc, .all_workspaces, null, 3);
    defer profile.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), profile.summaries.items.len);
    try std.testing.expectEqualStrings("session-005", profile.summaries.items[0].id);
    try std.testing.expectEqualStrings("other-004", profile.summaries.items[1].id);

    var second = try ctx.store.listWorkspacePage(
        alloc,
        .{
            .updated_at_ms = first.summaries.items[1].updated_at_ms,
            .id = first.summaries.items[1].id,
        },
        2,
    );
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), second.summaries.items.len);
    try std.testing.expect(second.has_more);
    try std.testing.expectEqualStrings("session-003", second.summaries.items[0].id);
    try std.testing.expectEqualStrings("session-002", second.summaries.items[1].id);

    var third = try ctx.store.listWorkspacePage(
        alloc,
        .{
            .updated_at_ms = second.summaries.items[1].updated_at_ms,
            .id = second.summaries.items[1].id,
        },
        2,
    );
    defer third.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), third.summaries.items.len);
    try std.testing.expect(!third.has_more);
    try std.testing.expectEqualStrings("session-001", third.summaries.items[0].id);

    try std.testing.expectError(
        error.InvalidSessionListLimit,
        ctx.store.listWorkspacePage(alloc, null, 0),
    );
    try std.testing.expectError(
        error.InvalidSessionListLimit,
        ctx.store.listWorkspacePage(
            alloc,
            null,
            session_list_max_limit + 1,
        ),
    );
}

test "resumable session pages filter before paging and preserve continuation order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    inline for (0..21) |index| {
        const id = try std.fmt.allocPrint(alloc, "session-{d:0>2}", .{index});
        defer alloc.free(id);
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"schema_version\":1,\"id\":\"{s}\",\"created_at_ms\":1,\"updated_at_ms\":{d},\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[{{\"role\":\"user\",\"content\":\"saved\"}}]}}",
            .{ id, index },
        );
        defer alloc.free(body);
        const path = try writeSessionFixture(alloc, ctx.store, id, body);
        defer alloc.free(path);
    }
    inline for (.{
        .{ "tie-a", 1000, 1 },
        .{ "tie-b", 1000, 1 },
        .{ "current", 2000, 1 },
        .{ "empty", 1500, 0 },
    }) |fixture| {
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"schema_version\":1,\"id\":\"{s}\",\"created_at_ms\":1,\"updated_at_ms\":{d},\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":{d},\"history\":[{{\"role\":\"user\",\"content\":\"saved\"}}]}}",
            .{ fixture[0], fixture[1], fixture[2] },
        );
        defer alloc.free(body);
        const path = try writeSessionFixture(alloc, ctx.store, fixture[0], body);
        defer alloc.free(path);
    }

    var first = try ctx.store.listResumablePage(alloc, "current", null);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), first.summaries.items.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqualStrings("tie-b", first.summaries.items[0].id);
    try std.testing.expectEqualStrings("tie-a", first.summaries.items[1].id);
    try std.testing.expectEqualStrings("session-20", first.summaries.items[2].id);
    try std.testing.expectEqualStrings("session-13", first.summaries.items[9].id);

    const first_last = first.summaries.items[first.summaries.items.len - 1];
    var second = try ctx.store.listResumablePage(
        alloc,
        "current",
        .{ .updated_at_ms = first_last.updated_at_ms, .id = first_last.id },
    );
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), second.summaries.items.len);
    try std.testing.expect(second.has_more);
    try std.testing.expectEqualStrings("session-12", second.summaries.items[0].id);
    try std.testing.expectEqualStrings("session-03", second.summaries.items[9].id);

    const second_last = second.summaries.items[second.summaries.items.len - 1];
    var third = try ctx.store.listResumablePage(
        alloc,
        "current",
        .{ .updated_at_ms = second_last.updated_at_ms, .id = second_last.id },
    );
    defer third.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), third.summaries.items.len);
    try std.testing.expect(!third.has_more);
    try std.testing.expectEqualStrings("session-02", third.summaries.items[0].id);
    try std.testing.expectEqualStrings("session-00", third.summaries.items[2].id);
}

test "workspace resumable pages filter workspace before paging and preserve continuation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    inline for (0..12) |index| {
        const id = try std.fmt.allocPrint(alloc, "workspace-b-{d:0>2}", .{index});
        defer alloc.free(id);
        try writeSummaryFixture(alloc, ctx.store, id, workspace_b, 1000 + @as(i64, @intCast(index)), 1);
    }
    inline for (0..11) |index| {
        const id = try std.fmt.allocPrint(alloc, "workspace-a-{d:0>2}", .{index});
        defer alloc.free(id);
        try writeSummaryFixture(alloc, ctx.store, id, ctx.workspace, 100 + @as(i64, @intCast(index)), 1);
    }
    try writeSummaryFixture(alloc, ctx.store, "workspace-a-current", ctx.workspace, 2000, 1);
    try writeSummaryFixture(alloc, ctx.store, "workspace-a-empty", ctx.workspace, 1500, 0);
    try writeSummaryFixture(alloc, ctx.store, "missing-workspace", null, 1600, 1);

    var first = try ctx.store.listResumableWorkspacePage(alloc, "workspace-a-current", null);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), first.summaries.items.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqualStrings("workspace-a-10", first.summaries.items[0].id);
    try std.testing.expectEqualStrings("workspace-a-01", first.summaries.items[9].id);
    for (first.summaries.items) |summary| {
        try std.testing.expectEqualStrings(ctx.workspace, summary.workspace_root.?);
    }

    const first_last = first.summaries.items[first.summaries.items.len - 1];
    var second = try ctx.store.listResumableWorkspacePage(
        alloc,
        "workspace-a-current",
        .{ .updated_at_ms = first_last.updated_at_ms, .id = first_last.id },
    );
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), second.summaries.items.len);
    try std.testing.expect(!second.has_more);
    try std.testing.expectEqualStrings("workspace-a-00", second.summaries.items[0].id);
}

test "resumable session pages use a complete index without summary cache writes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        "index.json",
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"indexed-newer\",\"created_at_ms\":1,\"updated_at_ms\":20,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Indexed newer\",\"preview\":\"Indexed newer\"},{\"id\":\"indexed-older\",\"created_at_ms\":1,\"updated_at_ms\":10,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Indexed older\",\"preview\":\"Indexed older\"}]}",
    );

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    var page = (try read_only.tryListResumableIndexPage(alloc, null, null)) orelse return error.TestExpectedEqual;
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), page.summaries.items.len);
    try std.testing.expectEqualStrings("indexed-newer", page.summaries.items[0].id);
    try std.testing.expectEqualStrings("indexed-older", page.summaries.items[1].id);

    const summary_path = try summaryPath(alloc, ctx.store.sessions_dir);
    defer alloc.free(summary_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io_mod.getIo(), summary_path, .{}),
    );
}

test "read-only resumable index hydrates missing display metadata for the page" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "stale-indexed-session",
        ctx.workspace,
        20,
        "stale index prompt",
    );

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    var index_text: std.Io.Writer.Allocating = .init(alloc);
    defer index_text.deinit();
    try index_text.writer.writeAll("{\"schema_version\":3,\"sessions\":[{\"id\":\"stale-indexed-session\",\"created_at_ms\":1,\"updated_at_ms\":20,\"workspace_root\":");
    try std.json.Stringify.value(ctx.workspace, .{}, &index_text.writer);
    try index_text.writer.writeAll(",\"conversation_language\":\"en\",\"history_len\":1}]}");
    const index_bytes = try index_text.toOwnedSlice();
    defer alloc.free(index_bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        "index.json",
        index_bytes,
    );
    try removeSessionIndexMarker(sessions);

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    var page = (try read_only.tryListResumableWorkspaceIndexPage(alloc, null, null)) orelse return error.TestExpectedEqual;
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expect(page.summaries.items[0].display_metadata_present);
    try std.testing.expectEqualStrings("stale index prompt", page.summaries.items[0].title.?);
}

test "resume page does not replay a large history to repair missing display metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "large-metadata-gap",
        ctx.workspace,
        20,
        "first prompt would require replay",
    );
    var session_dir = try ctx.store.openSessionDir("large-metadata-gap");
    try session_dir.dir.deleteFile(io_mod.getIo(), session_display_metadata.sidecar_file);
    session_dir.close();

    const oversized = try alloc.alloc(
        u8,
        synchronous_display_metadata_replay_max_bytes + 1,
    );
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try writeFixtureEntry(
        alloc,
        ctx.store,
        "large-metadata-gap",
        "events.jsonl",
        oversized,
    );

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    var index_text: std.Io.Writer.Allocating = .init(alloc);
    defer index_text.deinit();
    try index_text.writer.writeAll("{\"schema_version\":3,\"sessions\":[{\"id\":\"large-metadata-gap\",\"created_at_ms\":1,\"updated_at_ms\":20,\"workspace_root\":");
    try std.json.Stringify.value(ctx.workspace, .{}, &index_text.writer);
    try index_text.writer.writeAll(",\"conversation_language\":\"en\",\"history_len\":50000}]}");
    const index_bytes = try index_text.toOwnedSlice();
    defer alloc.free(index_bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        summary_codec.session_index_file,
        index_bytes,
    );
    try removeSessionIndexMarker(sessions);

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    var page = (try read_only.tryListResumableWorkspaceIndexPage(
        alloc,
        null,
        null,
    )) orelse return error.TestExpectedEqual;
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("large-metadata-gap", page.summaries.items[0].id);
    try std.testing.expect(!page.summaries.items[0].display_metadata_present);
    try std.testing.expect(page.summaries.items[0].title == null);
}

test "resumable page hydration adopts the frozen sidecar without rederiving" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try writeWritableHistoryFixture(
        alloc,
        ctx.store,
        "frozen-sidecar-session",
        ctx.workspace,
        20,
        "rederived prompt title",
    );

    var session_dir = try ctx.store.openSessionDir("frozen-sidecar-session");
    try session_display_metadata.writeSidecar(alloc, &session_dir, .{
        .present = true,
        .title = @constCast("Frozen custom title"),
        .preview = @constCast("Frozen custom preview"),
    });
    session_dir.close();

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    var index_text: std.Io.Writer.Allocating = .init(alloc);
    defer index_text.deinit();
    try index_text.writer.writeAll("{\"schema_version\":3,\"sessions\":[{\"id\":\"frozen-sidecar-session\",\"created_at_ms\":1,\"updated_at_ms\":20,\"workspace_root\":");
    try std.json.Stringify.value(ctx.workspace, .{}, &index_text.writer);
    try index_text.writer.writeAll(",\"conversation_language\":\"en\",\"history_len\":1}]}");
    const index_bytes = try index_text.toOwnedSlice();
    defer alloc.free(index_bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        "index.json",
        index_bytes,
    );
    try removeSessionIndexMarker(sessions);

    var page = (try ctx.store.tryListResumableWorkspaceIndexPage(alloc, null, null)) orelse return error.TestExpectedEqual;
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expect(page.summaries.items[0].display_metadata_present);
    try std.testing.expectEqualStrings("Frozen custom title", page.summaries.items[0].title.?);
    try std.testing.expectEqualStrings("Frozen custom preview", page.summaries.items[0].preview.?);

    var refreshed_dir = try ctx.store.openSessionDir("frozen-sidecar-session");
    defer refreshed_dir.close();
    var display = try session_display_metadata.readSidecarOrFallback(alloc, &refreshed_dir);
    defer display.deinit(alloc);
    try std.testing.expectEqualStrings("Frozen custom title", display.title);
}

test "writable resumable backfill refreshes missing display metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "metadata-backfill", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    errdefer writable.deinit(alloc);
    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(
        alloc,
        "first prompt title has more than eight words for cap\npreview line two",
        "saved response",
    );
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = 10,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);

    var session_dir = try ctx.store.openSessionDir("metadata-backfill");
    try session_dir.dir.deleteFile(io_mod.getIo(), session_display_metadata.sidecar_file);
    session_dir.close();

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    var old_index: std.Io.Writer.Allocating = .init(alloc);
    defer old_index.deinit();
    try old_index.writer.writeAll("{\"schema_version\":3,\"sessions\":[{\"id\":\"metadata-backfill\",\"created_at_ms\":10,\"updated_at_ms\":10,\"workspace_root\":");
    try std.json.Stringify.value(ctx.workspace, .{}, &old_index.writer);
    try old_index.writer.writeAll(",\"conversation_language\":\"en\",\"history_len\":1}]}");
    const old_index_bytes = try old_index.toOwnedSlice();
    defer alloc.free(old_index_bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        summary_codec.session_index_file,
        old_index_bytes,
    );

    var page = try ctx.store.listResumablePage(alloc, null, null);
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expect(page.summaries.items[0].display_metadata_present);
    try std.testing.expectEqualStrings(
        "first prompt title has more than eight words",
        page.summaries.items[0].title.?,
    );

    var refreshed_index = try summary_codec.readSessionIndex(alloc, sessions);
    defer freeSummaries(alloc, &refreshed_index);
    try std.testing.expectEqual(@as(usize, 1), refreshed_index.items.len);
    try std.testing.expect(refreshed_index.items[0].display_metadata_present);
    try std.testing.expectEqualStrings(
        "first prompt title has more than eight words",
        refreshed_index.items[0].title.?,
    );

    var refreshed_dir = try ctx.store.openSessionDir("metadata-backfill");
    defer refreshed_dir.close();
    var display = try session_display_metadata.readSidecarOrFallback(alloc, &refreshed_dir);
    defer display.deinit(alloc);
    try std.testing.expect(display.present);
    try std.testing.expectEqualStrings(
        "first prompt title has more than eight words",
        display.title,
    );
}

test "workspace resumable index and backfill return the same scoped page" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    try writeWritableHistoryFixture(alloc, ctx.store, "workspace-a-newer", ctx.workspace, 30, "workspace a newer");
    try writeWritableHistoryFixture(alloc, ctx.store, "workspace-a-older", ctx.workspace, 20, "workspace a older");
    var store_b = try Store.initFromHome(alloc, ctx.home, workspace_b);
    defer store_b.deinit(alloc);
    try writeWritableHistoryFixture(alloc, store_b, "workspace-b-newest", workspace_b, 40, "workspace b newest");

    var backfilled = try ctx.store.listResumableWorkspacePage(alloc, null, null);
    defer backfilled.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), backfilled.summaries.items.len);
    try std.testing.expectEqualStrings("workspace-a-newer", backfilled.summaries.items[0].id);
    try std.testing.expectEqualStrings("workspace-a-older", backfilled.summaries.items[1].id);

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    var indexed = (try read_only.tryListResumableWorkspaceIndexPage(alloc, null, null)) orelse return error.TestExpectedEqual;
    defer indexed.deinit(alloc);
    try std.testing.expectEqual(backfilled.summaries.items.len, indexed.summaries.items.len);
    for (backfilled.summaries.items, indexed.summaries.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected.id, actual.id);
        try std.testing.expectEqualStrings(ctx.workspace, actual.workspace_root.?);
    }
}

test "resumable session pages accept an index beyond four mebibytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var index = std.Io.Writer.Allocating.init(alloc);
    defer index.deinit();
    try index.writer.writeAll(
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"large-index-session\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Large index session\",\"preview\":\"Large index session\"}],\"padding\":\"",
    );
    try index.writer.splatByteAll('x', 4 * 1024 * 1024);
    try index.writer.writeAll("\"}");
    const bytes = try index.toOwnedSlice();
    defer alloc.free(bytes);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    try io_mod.durableReplaceVerified(alloc, sessions, summary_codec.session_index_file, bytes);

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    var page = (try read_only.tryListResumableIndexPage(alloc, null, null)) orelse return error.TestExpectedEqual;
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("large-index-session", page.summaries.items[0].id);
}

test "empty writable session preserves the index until its next publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    const seeded_index =
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"indexed-newer\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Indexed newer\",\"preview\":\"Indexed newer\"},{\"id\":\"indexed-older\",\"created_at_ms\":1,\"updated_at_ms\":1,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Indexed older\",\"preview\":\"Indexed older\"}]}";
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        summary_codec.session_index_file,
        seeded_index,
    );

    var state = try testDurableState(alloc, "indexed-lifecycle", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);

    const preserved_index = blk: {
        var preserved_file = try sessions.dir.openFile(
            io_mod.getIo(),
            summary_codec.session_index_file,
            .{},
        );
        defer preserved_file.close(io_mod.getIo());
        break :blk try io_mod.readFileToEnd(
            alloc,
            &preserved_file,
            summary_codec.max_session_index_bytes,
        );
    };
    defer alloc.free(preserved_index);
    try std.testing.expectEqualStrings(seeded_index, preserved_index);
    try std.testing.expectError(
        error.FileNotFound,
        sessions.dir.access(io_mod.getIo(), "index.pending", .{}),
    );
    var latest = try readLatestPointer(ctx.store, alloc, ctx.workspace) orelse
        return error.TestExpectedEqual;
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, latest.session_id);

    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );

    var index = try summary_codec.readSessionIndex(alloc, sessions);
    defer freeSummaries(alloc, &index);
    try std.testing.expectEqual(@as(usize, 3), index.items.len);
    try std.testing.expectEqualStrings(state.id, index.items[0].id);
    try std.testing.expectEqual(@as(i64, 20), index.items[0].updated_at_ms);
}

test "history-bearing session publishes its summary during creation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        summary_codec.session_index_file,
        "{\"schema_version\":3,\"sessions\":[]}",
    );

    var state = try testDurableState(alloc, "indexed-initial-history", ctx.workspace);
    defer state.deinit(alloc);
    state.history = blk: {
        const history = try alloc.alloc(session.HistoryTurn, 1);
        errdefer alloc.free(history);
        history[0] = try session.makeAssistantTurn(alloc, "saved prompt", "saved response");
        break :blk history;
    };
    var writable = try ctx.store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);

    var index = try summary_codec.readSessionIndex(alloc, sessions);
    defer freeSummaries(alloc, &index);
    try std.testing.expectEqual(@as(usize, 1), index.items.len);
    try std.testing.expectEqualStrings(state.id, index.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), index.items[0].history_len);
}

test "failed empty initial publication restores normal index maintenance" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        summary_codec.session_index_file,
        "{\"schema_version\":3,\"sessions\":[]}",
    );

    var failure = ArmedBoundaryFailure{
        .target = .before_latest_cache_ready,
        .armed = true,
    };
    var state = try testDurableState(alloc, "indexed-failed-empty-start", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSessionWithOptions(
        alloc,
        state,
        failure.logOptions(),
    );
    defer writable.deinit(alloc);
    failure.armed = false;

    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );

    var index = try summary_codec.readSessionIndex(alloc, sessions);
    defer freeSummaries(alloc, &index);
    try std.testing.expectEqual(@as(usize, 1), index.items.len);
    try std.testing.expectEqualStrings(state.id, index.items[0].id);
    try std.testing.expectEqual(@as(i64, 20), index.items[0].updated_at_ms);
}

test "summary index marker preparation rejects an uncommitted session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    try sessions.dir.createDir(
        io_mod.getIo(),
        "index.pending",
        std.Io.File.Permissions.fromMode(0o700),
    );

    var state = try testDurableState(alloc, "marker-prepare-failure", ctx.workspace);
    defer state.deinit(alloc);
    state.history = blk: {
        const history = try alloc.alloc(session.HistoryTurn, 1);
        errdefer alloc.free(history);
        history[0] = try session.makeAssistantTurn(alloc, "saved prompt", "saved response");
        break :blk history;
    };
    try std.testing.expectError(
        error.DurablePathUnsafe,
        ctx.store.startWritableSession(alloc, state),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.openSessionDir(state.id),
    );
}

test "summary index publication failure leaves a repairable cache miss" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const sessions = &(ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual);
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        summary_codec.session_index_file,
        "{\"schema_version\":3,\"sessions\":[]}",
    );

    var failure = MigrationBoundaryFailure{ .target = .before_latest_cache_ready };
    var state = try testDurableState(alloc, "index-publication-failure", ctx.workspace);
    defer state.deinit(alloc);
    var history = try alloc.alloc(session.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try session.makeAssistantTurn(alloc, "saved prompt", "saved response");
    state.history = history;
    var created = try ctx.store.startWritableSessionWithOptions(
        alloc,
        state,
        failure.options().log,
    );
    created.deinit(alloc);

    var read_only = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer read_only.deinit(alloc);
    try std.testing.expect((try read_only.tryListResumableIndexPage(alloc, null, null)) == null);

    var repaired = try ctx.store.listResumablePage(alloc, null, null);
    defer repaired.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), repaired.summaries.items.len);
    try std.testing.expectEqualStrings(state.id, repaired.summaries.items[0].id);

    var warm = (try read_only.tryListResumableIndexPage(alloc, null, null)) orelse return error.TestExpectedEqual;
    defer warm.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), warm.summaries.items.len);
}

test "list breaks updated_at ties by descending id" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    inline for (.{
        .{ "1700000000000-100-aaaaaaaaaaaaaaaa", "1" },
        .{ "1700000000001-100-bbbbbbbbbbbbbbbb", "2" },
    }) |fixture| {
        const body = try std.fmt.allocPrint(alloc, "{{\"schema_version\":1,\"id\":\"{s}\",\"created_at_ms\":{s},\"updated_at_ms\":40,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}}", .{ fixture[0], fixture[1] });
        defer alloc.free(body);
        const path = try writeSessionFixture(alloc, ctx.store, fixture[0], body);
        defer alloc.free(path);
    }

    var listed = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &listed);

    try std.testing.expectEqual(@as(usize, 2), listed.items.len);
    try std.testing.expectEqualStrings("1700000000001-100-bbbbbbbbbbbbbbbb", listed.items[0].id);
    try std.testing.expectEqualStrings("1700000000000-100-aaaaaaaaaaaaaaaa", listed.items[1].id);
}

test "invalid/corrupt record skipping" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const trace_path = try std.fs.path.join(alloc, &.{ ctx.home, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();
    inline for (.{
        .{ "broken", "{\"schema_version\":1," },
        .{ "unsupported", "{\"schema_version\":99,\"id\":\"unsupported\",\"created_at_ms\":1,\"updated_at_ms\":8,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}" },
        .{ "valid", "{\"schema_version\":1,\"id\":\"valid\",\"created_at_ms\":3,\"updated_at_ms\":9,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"es\",\"history_len\":0,\"history\":[]}" },
    }) |fixture| {
        const path = try writeSessionFixture(alloc, ctx.store, fixture[0], fixture[1]);
        alloc.free(path);
    }
    var page = try ctx.store.listSessionPage(alloc, .all_workspaces, null, 10);
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqual(@as(usize, 2), page.skipped_invalid);
    var listed = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &listed);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("valid", listed.items[0].id);
    var latest = try ctx.store.latestReadOnlySummary(alloc);
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings("valid", latest.id);
    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "validated_candidate_id=broken") != null);
    try std.testing.expect(std.mem.find(u8, trace, "storage_format=legacy_v1") != null);
    try std.testing.expect(std.mem.find(u8, trace, "projection_state=current") != null);
    try std.testing.expect(std.mem.find(u8, trace, "cause=invalid_manifest") != null);
    try std.testing.expect(std.mem.find(u8, trace, "outcome=excluded") != null);
    try std.testing.expect(std.mem.find(u8, trace, "outcome=retained") != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "session discovery mode=global_read_only_last cause=listable storage_format=legacy_v1 projection_state=current validated_candidate_id=valid outcome=selected error=none",
    ) != null);
    try std.testing.expect(std.mem.find(u8, trace, "{\"schema_version\":1,") == null);
    try std.testing.expect(std.mem.find(u8, trace, ctx.home) == null);
}

test "workspace latest distinguishes corrupt-only storage from no saved sessions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const path = try writeSessionFixture(
        alloc,
        ctx.store,
        "broken-only",
        "{\"schema_version\":1,",
    );
    defer alloc.free(path);

    try std.testing.expectError(
        error.NoReadableSessions,
        ctx.store.latestReadOnlyWorkspaceSummary(alloc),
    );
}

test "missing session ID error and unsupported schema error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.loadReadOnlyDetail(alloc, "missing", .{}),
    );
    const path = try writeSessionFixture(alloc, ctx.store, "unsupported", "{\"schema_version\":99,\"id\":\"unsupported\",\"created_at_ms\":1,\"updated_at_ms\":8,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}");
    defer alloc.free(path);
    try std.testing.expectError(
        error.UnsupportedSessionSchema,
        ctx.store.loadReadOnlyDetail(alloc, "unsupported", .{}),
    );
    const bad = try writeSessionFixture(alloc, ctx.store, "bad", "{");
    defer alloc.free(bad);
    try std.testing.expectError(
        error.InvalidSessionFormat,
        ctx.store.loadReadOnlyDetail(alloc, "bad", .{}),
    );
}

test "list propagates OOM and access errors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const valid = try writeSessionFixture(alloc, ctx.store, "valid", "{\"schema_version\":1,\"id\":\"valid\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}");
    defer alloc.free(valid);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ctx.store.list(failing.allocator()));

    const blocked = try writeSessionFixture(alloc, ctx.store, "blocked", "{\"schema_version\":1,\"id\":\"blocked\",\"created_at_ms\":1,\"updated_at_ms\":3,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}");
    defer alloc.free(blocked);
    chmodPath(alloc, blocked, 0) catch return error.SkipZigTest;
    defer chmodPath(alloc, blocked, 0o600) catch {};
    if (ctx.store.list(alloc)) |items| {
        var mutable_items = items;
        freeSummaries(alloc, &mutable_items);
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.AccessDenied => {},
        else => return err,
    }
}

test "classifies schema v3 and legacy candidates" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "schema.v3", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);
    try writeLegacyV2Fixture(
        alloc,
        ctx.store,
        "legacy.v2",
        ctx.workspace,
        20,
    );

    var summaries = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 2), summaries.items.len);
    try std.testing.expectEqualStrings("legacy.v2", summaries.items[0].id);
    try std.testing.expectEqualStrings("schema.v3", summaries.items[1].id);

    var legacy_dir = try ctx.store.openSessionDir("legacy.v2");
    defer legacy_dir.close();
    var legacy_candidate = try classifyReadOnlyCandidate(
        alloc,
        &legacy_dir,
        "legacy.v2",
    );
    defer legacy_candidate.deinit(alloc);
    try std.testing.expectEqual(
        CandidateStorage.legacy_v2,
        legacy_candidate.storage,
    );
}

test "list uses schema v3 summary without opening canonical contents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "summary-only", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);
    try writeFixtureEntry(alloc, ctx.store, state.id, "events.jsonl", "corrupt\n");
    const session_dir_path = try sessionDirPath(
        alloc,
        ctx.store.sessions_dir,
        state.id,
    );
    defer alloc.free(session_dir_path);
    const events_path = try std.fs.path.join(
        alloc,
        &.{ session_dir_path, "events.jsonl" },
    );
    defer alloc.free(events_path);
    chmodPath(alloc, events_path, 0) catch return error.SkipZigTest;
    defer chmodPath(alloc, events_path, 0o600) catch {};
    var session_dir = try std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        session_dir_path,
        .{ .iterate = true },
    );
    defer session_dir.close(io_mod.getIo());
    var iter = session_dir.iterate();
    var watermark_name: ?[]u8 = null;
    defer if (watermark_name) |name| alloc.free(name);
    while (try iter.next(io_mod.getIo())) |entry| {
        if (std.mem.startsWith(u8, entry.name, "commit.") and
            std.mem.endsWith(u8, entry.name, ".json"))
        {
            watermark_name = try alloc.dupe(u8, entry.name);
            break;
        }
    }
    const watermark_path = try std.fs.path.join(
        alloc,
        &.{ session_dir_path, watermark_name orelse return error.TestExpectedEqual },
    );
    defer alloc.free(watermark_path);
    chmodPath(alloc, watermark_path, 0) catch return error.SkipZigTest;
    defer chmodPath(alloc, watermark_path, 0o600) catch {};

    var summaries = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expectEqualStrings(state.id, summaries.items[0].id);
    var latest = try ctx.store.latestReadOnlySummary(alloc);
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, latest.id);
}

test "workspace latest ranks stale projection by canonical time" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var projected_newer = try testDurableState(alloc, "projected-newer", ctx.workspace);
    defer projected_newer.deinit(alloc);
    projected_newer.updated_at_ms = 100;
    var projected = try ctx.store.startWritableSession(alloc, projected_newer);
    projected.deinit(alloc);

    var canonical_newer = try testDurableState(alloc, "canonical-newer", ctx.workspace);
    defer canonical_newer.deinit(alloc);
    canonical_newer.updated_at_ms = 50;
    var canonical = try ctx.store.startWritableSession(alloc, canonical_newer);
    const stale_manifest = try readFixtureFile(
        alloc,
        ctx.store,
        canonical_newer.id,
        "session.json",
        64 * 1024,
    );
    defer alloc.free(stale_manifest);
    const desired = session_codec.DurableSessionState{
        .id = canonical.state.id,
        .origin_workspace_root = canonical.state.origin_workspace_root,
        .workspace_root = canonical.state.workspace_root,
        .created_at_ms = canonical.state.created_at_ms,
        .updated_at_ms = 200,
        .conversation_language = canonical.state.conversation_language,
        .preferences = canonical.state.preferences,
        .history = canonical.state.history,
        .total_input_tokens = canonical.state.total_input_tokens,
        .total_output_tokens = canonical.state.total_output_tokens,
    };
    _ = try canonical.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    canonical.deinit(alloc);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        canonical_newer.id,
        "session.json",
        stale_manifest,
    );

    var selected = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer selected.deinit(alloc);
    try std.testing.expectEqualStrings(canonical_newer.id, selected.state.id);
}

test "workspace latest replays a missing projection" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var older = try testDurableState(alloc, "projection-present", ctx.workspace);
    defer older.deinit(alloc);
    older.updated_at_ms = 100;
    var older_writable = try ctx.store.startWritableSession(alloc, older);
    older_writable.deinit(alloc);

    var newer = try testDurableState(alloc, "projection-missing", ctx.workspace);
    defer newer.deinit(alloc);
    newer.updated_at_ms = 200;
    var newer_writable = try ctx.store.startWritableSession(alloc, newer);
    newer_writable.deinit(alloc);
    var newer_dir = try ctx.store.openSessionDir(newer.id);
    try deleteSessionEntry(&newer_dir, "session.json");
    newer_dir.close();

    var selected = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer selected.deinit(alloc);
    try std.testing.expectEqualStrings(newer.id, selected.state.id);
}

test "workspace latest pointer ignores a mutated session from another workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace-a",
    );
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace-b",
    );
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var older = try testDurableState(alloc, "older-workspace-a", workspace_a);
    defer older.deinit(alloc);
    older.updated_at_ms = 100;
    var older_writable = try store_a.startWritableSession(alloc, older);
    older_writable.deinit(alloc);

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    var selected = try testDurableState(
        alloc,
        "selected-workspace-changed",
        workspace_b,
    );
    defer selected.deinit(alloc);
    selected.updated_at_ms = 200;
    var selected_writable = try store_b.startWritableSession(alloc, selected);
    selected_writable.deinit(alloc);

    const manifest_bytes = try readFixtureFile(
        alloc,
        store_a,
        selected.id,
        "session.json",
        session_projection.manifest_max_bytes,
    );
    defer alloc.free(manifest_bytes);
    var manifest = try session_projection.decodeManifest(alloc, manifest_bytes);
    defer manifest.deinit(alloc);
    alloc.free(manifest.workspace_root);
    manifest.workspace_root = try alloc.dupe(u8, workspace_a);
    const projected = try session_projection.encodeManifest(alloc, manifest);
    defer alloc.free(projected);
    try writeFixtureEntry(
        alloc,
        store_a,
        selected.id,
        "session.json",
        projected,
    );

    var resumed = try store_a.resumeTargetForWrite(
        alloc,
        .last,
        workspace_a,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(older.id, resumed.state.id);
}

test "writable last returns busy for the selected target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var older = try testDurableState(alloc, "older-available", ctx.workspace);
    defer older.deinit(alloc);
    older.updated_at_ms = 100;
    var older_writable = try ctx.store.startWritableSession(alloc, older);
    older_writable.deinit(alloc);

    var selected = try testDurableState(alloc, "newer-busy", ctx.workspace);
    defer selected.deinit(alloc);
    selected.updated_at_ms = 200;
    var selected_writable = try ctx.store.startWritableSession(alloc, selected);
    selected_writable.deinit(alloc);

    var selected_dir = try ctx.store.openSessionDir(selected.id);
    defer selected_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &selected_dir,
        "session.lock",
        2000,
    );
    defer lock.release();

    try std.testing.expectError(
        error.SessionBusy,
        ctx.store.resumeTargetForWrite(
            alloc,
            .last,
            ctx.workspace,
            .{ .log = .{ .session_lock_deadline_ms = 0 } },
        ),
    );
}

test "writable last does not fall back when boundary capture is unavailable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var older = try testDurableState(alloc, "older-boundary", ctx.workspace);
    defer older.deinit(alloc);
    older.updated_at_ms = 100;
    var older_writable = try ctx.store.startWritableSession(alloc, older);
    older_writable.deinit(alloc);

    var selected = try testDurableState(alloc, "newer-boundary", ctx.workspace);
    defer selected.deinit(alloc);
    selected.updated_at_ms = 200;
    var selected_writable = try ctx.store.startWritableSession(alloc, selected);
    selected_writable.deinit(alloc);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        selected.id,
        "events.jsonl",
        "stale projection\n",
    );

    var selected_dir = try ctx.store.openSessionDir(selected.id);
    defer selected_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &selected_dir,
        "commit.lock",
        2000,
    );
    defer lock.release();

    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        ctx.store.resumeTargetForWrite(
            alloc,
            .last,
            ctx.workspace,
            .{},
        ),
    );
}

test "writable last ignores unavailable boundary from another workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace-a",
    );
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace-b",
    );
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var selected = try testDurableState(alloc, "selected-workspace-a", workspace_a);
    defer selected.deinit(alloc);
    selected.updated_at_ms = 100;
    var selected_writable = try store_a.startWritableSession(alloc, selected);
    selected_writable.deinit(alloc);

    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    var unrelated = try testDurableState(
        alloc,
        "unrelated-workspace-b",
        workspace_b,
    );
    defer unrelated.deinit(alloc);
    unrelated.updated_at_ms = 200;
    var unrelated_writable = try store_b.startWritableSession(alloc, unrelated);
    unrelated_writable.deinit(alloc);
    try writeFixtureEntry(
        alloc,
        store_b,
        unrelated.id,
        "events.jsonl",
        "stale projection\n",
    );

    var unrelated_dir = try store_b.openSessionDir(unrelated.id);
    defer unrelated_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &unrelated_dir,
        "commit.lock",
        2000,
    );
    defer lock.release();

    var resumed = try store_a.resumeTargetForWrite(
        alloc,
        .last,
        workspace_a,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(selected.id, resumed.state.id);
}

test "legacy authority fence hides candidate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-fenced", ctx.workspace, 20);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        "legacy-fenced",
        "authority.pending.json",
        "{\"schema_version\":1,\"session_id\":\"legacy-fenced\",\"operation_id\":\"11111111111111111111111111111111\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"22222222222222222222222222222222\",\"prior\":{\"storage_format\":\"legacy_snapshot_v1\",\"primary_bytes\":1,\"primary_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"proposed\":{\"storage_format\":\"event_log_v1\",\"log_generation\":\"33333333333333333333333333333333\",\"through_seq\":1,\"through_event_id\":\"44444444444444444444444444444444\",\"through_event_log_bytes\":1}}",
    );

    var summaries = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 0), summaries.items.len);
}

test "writable last does not fall back across authority boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "older-eligible", ctx.workspace, 10);
    try writeLegacyFixture(alloc, ctx.store, "newer-fenced", ctx.workspace, 20);
    try writeFixtureEntry(
        alloc,
        ctx.store,
        "newer-fenced",
        "authority.pending.json",
        "{\"schema_version\":1,\"session_id\":\"newer-fenced\",\"operation_id\":\"11111111111111111111111111111111\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"22222222222222222222222222222222\",\"prior\":{\"storage_format\":\"legacy_snapshot_v1\",\"primary_bytes\":1,\"primary_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"proposed\":{\"storage_format\":\"event_log_v1\",\"log_generation\":\"33333333333333333333333333333333\",\"through_seq\":1,\"through_event_id\":\"44444444444444444444444444444444\",\"through_event_log_bytes\":1}}",
    );

    try std.testing.expectError(
        error.SessionAuthorityBoundaryUnavailable,
        ctx.store.resumeTargetForWrite(
            alloc,
            .last,
            ctx.workspace,
            .{},
        ),
    );
}

test "empty home read only operations create nothing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try Store.initReadOnlyFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var summaries = try store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 0), summaries.items.len);
    try std.testing.expectError(
        error.NoSavedSessions,
        store.latestReadOnlySummary(alloc),
    );
    try std.testing.expectError(error.SessionNotFound, store.loadReadOnly(alloc, "missing"));

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io_mod.getIo(), "home/.fx", .{}),
    );
}

test "missing home is empty for reads and bootstrapped privately for writes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const missing_home = try std.fs.path.join(alloc, &.{ tmp_root, "missing-home" });
    defer alloc.free(missing_home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var read_only = try Store.initReadOnlyFromHome(alloc, missing_home, workspace);
    defer read_only.deinit(alloc);
    var empty = try read_only.list(alloc);
    defer freeSummaries(alloc, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io_mod.getIo(), missing_home, .{}),
    );

    var writable = try Store.initFromHome(alloc, missing_home, workspace);
    defer writable.deinit(alloc);
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), missing_home, .{});
    defer home_dir.close(io_mod.getIo());
    const home_stat = try home_dir.stat(io_mod.getIo());
    try std.testing.expectEqual(std.Io.File.Kind.directory, home_stat.kind);
    try std.testing.expectEqual(@as(u32, 0o700), home_stat.permissions.toMode() & 0o777);
    const sessions_path = try std.fs.path.join(alloc, &.{ missing_home, ".fx", "sessions" });
    defer alloc.free(sessions_path);
    try std.Io.Dir.accessAbsolute(io_mod.getIo(), sessions_path, .{});
}

test "first write traces and maps shared layout failure" {
    if (comptime builtin.os.tag == .windows) return;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const trace_path = try std.fs.path.join(alloc, &.{ tmp_root, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "session");
    defer debug_trace.resetForTest();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const home_z = try alloc.dupeZ(u8, home);
    defer alloc.free(home_z);
    if (std.c.chmod(home_z.ptr, 0o500) != 0) return error.TestUnexpectedResult;
    defer _ = std.c.chmod(home_z.ptr, 0o700);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    try std.testing.expectError(
        error.DurableLayoutFailed,
        Store.initFromHome(alloc, home, workspace),
    );

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        trace_path,
        .{},
    );
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=writable_layout_failed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "source_error=AccessDenied") != null);
    try std.testing.expect(std.mem.find(u8, trace, "mapped_error=DurableLayoutFailed") != null);
    try std.testing.expect(std.mem.find(u8, trace, home) == null);
    try std.testing.expect(std.mem.find(u8, trace, workspace) == null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io_mod.getIo(), "home/.fx", .{}),
    );
}

test "first write creates only the private session layout" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var store = try Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var state = try testDurableState(alloc, "first-write", workspace);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);

    var home_dir = try std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        home,
        .{ .iterate = true },
    );
    defer home_dir.close(io_mod.getIo());
    var home_iter = home_dir.iterate();
    const durable_entry = (try home_iter.next(io_mod.getIo())) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(".fx", durable_entry.name);
    try std.testing.expect((try home_iter.next(io_mod.getIo())) == null);

    var durable_dir = try home_dir.openDir(io_mod.getIo(), ".fx", .{
        .iterate = true,
    });
    defer durable_dir.close(io_mod.getIo());
    const durable_stat = try durable_dir.stat(io_mod.getIo());
    try std.testing.expectEqual(
        @as(u64, 0o700),
        durable_stat.permissions.toMode() & 0o777,
    );
    var durable_iter = durable_dir.iterate();
    const sessions_entry = (try durable_iter.next(io_mod.getIo())) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("sessions", sessions_entry.name);
    try std.testing.expect((try durable_iter.next(io_mod.getIo())) == null);

    var sessions_dir = try durable_dir.openDir(
        io_mod.getIo(),
        "sessions",
        .{ .iterate = true },
    );
    defer sessions_dir.close(io_mod.getIo());
    const sessions_stat = try sessions_dir.stat(io_mod.getIo());
    try std.testing.expectEqual(
        @as(u64, 0o700),
        sessions_stat.permissions.toMode() & 0o777,
    );
    var sessions_iter = sessions_dir.iterate();
    var saw_session = false;
    var saw_latest = false;
    while (try sessions_iter.next(io_mod.getIo())) |entry| {
        if (std.mem.eql(u8, entry.name, state.id)) saw_session = true;
        if (std.mem.eql(u8, entry.name, latest_sessions_dir)) saw_latest = true;
    }
    try std.testing.expect(saw_session);
    try std.testing.expect(saw_latest);
}

test "exact legacy read does not create state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-detail", ctx.workspace, 20);

    var loaded = try ctx.store.loadReadOnly(alloc, "legacy-detail");
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-detail", loaded.id);
    const session_dir = try sessionDirPath(
        alloc,
        ctx.store.sessions_dir,
        "legacy-detail",
    );
    defer alloc.free(session_dir);
    const commit_lock = try std.fs.path.join(alloc, &.{ session_dir, "commit.lock" });
    defer alloc.free(commit_lock);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io_mod.getIo(), commit_lock, .{}),
    );
}

test "malformed settings do not block legacy detail or migration" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const settings_path = try std.fs.path.join(alloc, &.{ ctx.home, ".fx", "settings.json" });
    defer alloc.free(settings_path);
    try writeRawFile(settings_path, "{broken");
    try writeLegacyFixture(alloc, ctx.store, "legacy-with-bad-settings", ctx.workspace, 20);

    var loaded = try ctx.store.loadReadOnly(alloc, "legacy-with-bad-settings");
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-with-bad-settings", loaded.id);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", loaded.preferences.model);

    var resumed = try ctx.store.resumeForWrite(alloc, "legacy-with-bad-settings");
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-with-bad-settings", resumed.state.id);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", resumed.state.preferences.model);
}

test "explicit schema v3 resume rebinds workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var source = try Store.initFromHome(alloc, home, workspace_a);
    var state = try testDurableState(alloc, "rebind-target", workspace_a);
    defer state.deinit(alloc);
    var created = try source.startWritableSession(alloc, state);
    created.deinit(alloc);
    source.deinit(alloc);

    var target = try Store.initFromHome(alloc, home, workspace_b);
    defer target.deinit(alloc);
    var resumed = try target.resumeForWrite(alloc, state.id);
    try std.testing.expectEqualStrings(workspace_b, resumed.state.workspace_root);
    try std.testing.expect(!resumed.needsFinalStateReplacement(false));
    resumed.deinit(alloc);

    var reopened = try target.loadReadOnly(alloc, state.id);
    defer reopened.deinit(alloc);
    try std.testing.expectEqualStrings(workspace_b, reopened.workspace_root);
}

test "writable resume migrates legacy storage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-migrate", ctx.workspace, 20);

    var resumed = try ctx.store.resumeForWrite(alloc, "legacy-migrate");
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-migrate", resumed.state.id);
    try std.testing.expectEqualStrings(ctx.workspace, resumed.state.workspace_root);
    const authority = try readFixtureFile(
        alloc,
        ctx.store,
        "legacy-migrate",
        "authority.json",
        16 * 1024,
    );
    defer alloc.free(authority);
    const stable_copy = try readFixtureFile(
        alloc,
        ctx.store,
        "legacy-migrate",
        "session.legacy.json",
        max_session_bytes,
    );
    defer alloc.free(stable_copy);
    try std.testing.expect(authority.len > 0);
    try std.testing.expect(stable_copy.len > 0);
}

test "writable legacy resume preserves incomplete authority through migration and reload" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const session_id = "legacy-incomplete-authority";
    try writeLegacyIncompleteAuthorityFixture(
        alloc,
        ctx.store,
        session_id,
        ctx.workspace,
        20,
    );

    {
        var resumed = try ctx.store.resumeForWrite(alloc, session_id);
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
        try std.testing.expect(
            !resumed.state.history[0].compacted_summary.root_user_messages_complete,
        );
        try std.testing.expect(
            !resumed.state.history[0].compacted_summary.permission_feedback_complete,
        );
    }

    var reloaded = try ctx.store.loadReadOnly(alloc, session_id);
    defer reloaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), reloaded.history.len);
    try std.testing.expect(
        !reloaded.history[0].compacted_summary.root_user_messages_complete,
    );
    try std.testing.expect(
        !reloaded.history[0].compacted_summary.permission_feedback_complete,
    );
}

test "legacy resume honors immediate session and commit lock deadlines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-lock-deadlines", ctx.workspace, 20);

    var session_dir = try ctx.store.openSessionDir("legacy-lock-deadlines");
    defer session_dir.close();
    var session_lock = try io_mod.acquireTimedAdvisoryLock(
        &session_dir,
        "session.lock",
        2000,
    );
    const session_started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionBusy,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-lock-deadlines" },
            ctx.workspace,
            .{ .log = .{
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            } },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - session_started_at_ms < 1000);
    session_lock.release();

    {
        var commit_lock = try io_mod.acquireTimedAdvisoryLock(
            &session_dir,
            "commit.lock",
            2000,
        );
        defer commit_lock.release();
        const commit_started_at_ms = io_mod.milliTimestamp();
        try std.testing.expectError(
            error.SessionCommitBoundaryUnavailable,
            ctx.store.resumeTargetForWrite(
                alloc,
                .{ .id = "legacy-lock-deadlines" },
                ctx.workspace,
                .{ .log = .{
                    .session_lock_deadline_ms = 0,
                    .commit_lock_deadline_ms = 0,
                } },
            ),
        );
        try std.testing.expect(io_mod.milliTimestamp() - commit_started_at_ms < 1000);
    }

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    const latest_started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-lock-deadlines" },
            ctx.workspace,
            .{ .log = .{
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            } },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - latest_started_at_ms < 1000);
}

test "storage-only migration preserves legacy v2 source metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyV2Fixture(
        alloc,
        ctx.store,
        "legacy-v2-migrate",
        ctx.workspace,
        20,
    );

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-v2-migrate",
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionMigrationStatus.migrated, result.status);
    try std.testing.expectEqual(@as(u8, 2), result.source_schema_version);
    try std.testing.expect(result.source_bytes > 0);
}

test "storage only migration accepts legacy snapshots larger than v3 manifest cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLargeLegacyFixture(
        alloc,
        ctx.store,
        "legacy-large-migrate",
        ctx.workspace,
        20,
    );

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-large-migrate",
        .{ .allow_large = true },
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionMigrationStatus.migrated, result.status);
    try std.testing.expectEqual(@as(u8, 1), result.source_schema_version);
    try std.testing.expect(result.source_bytes > session_projection.manifest_max_bytes);
}

test "normal legacy classification parses top level schema beyond manifest prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLargeLegacyFixture(
        alloc,
        ctx.store,
        "legacy-prefix-schema",
        ctx.workspace,
        20,
    );

    var detail = try ctx.store.loadReadOnlyDetail(
        alloc,
        "legacy-prefix-schema",
        .{},
    );
    defer detail.deinit(alloc);
    try std.testing.expectEqual(StorageFormat.legacy_v1, detail.storage_format);

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-prefix-schema",
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionMigrationStatus.migrated, result.status);
}

test "migration result uses captured source metadata after committed success" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLargeLegacyFixture(
        alloc,
        ctx.store,
        "legacy-large-result",
        ctx.workspace,
        20,
    );

    const session_dir = try sessionDirPath(alloc, ctx.store.sessions_dir, "legacy-large-result");
    defer alloc.free(session_dir);
    const legacy_copy_path = try std.fs.path.join(alloc, &.{ session_dir, "session.legacy.json" });
    defer alloc.free(legacy_copy_path);
    var corruption = MigrationStableCopyCorruption{ .legacy_copy_path = legacy_copy_path };

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-large-result",
        .{ .log = corruption.options() },
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionMigrationStatus.migrated, result.status);
    try std.testing.expectEqual(@as(u8, 1), result.source_schema_version);
    try std.testing.expect(result.source_bytes > session_projection.manifest_max_bytes);
}

test "session list ignores stale json cache without matching sessions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    const cache_path = try std.fs.path.join(alloc, &.{ ctx.store.sessions_dir, session_list_json_file });
    defer alloc.free(cache_path);
    try writeRawFile(
        cache_path,
        "{\"kind\":\"sessions\",\"count\":1,\"sessions\":[{\"id\":\"ghost-session\",\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":0,\"conversation_language\":\"en\"}]}",
    );

    var summaries = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 0), summaries.items.len);
}

test "interrupted migration restores exact legacy authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-restore", ctx.workspace, 20);
    var failure = MigrationBoundaryFailure{
        .target = .after_authority_marker_rename,
    };

    try std.testing.expectError(
        error.LegacySessionMigrationIndeterminate,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-restore" },
            ctx.workspace,
            failure.options(),
        ),
    );

    var resumed = try ctx.store.resumeForWrite(alloc, "legacy-restore");
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-restore", resumed.state.id);
    try std.testing.expectEqualStrings(ctx.workspace, resumed.state.workspace_root);
}

test "interrupted migration recovery honors immediate lock deadlines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-recovery-locks", ctx.workspace, 20);
    var failure = MigrationBoundaryFailure{
        .target = .after_authority_marker_rename,
    };
    try std.testing.expectError(
        error.LegacySessionMigrationIndeterminate,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-recovery-locks" },
            ctx.workspace,
            failure.options(),
        ),
    );

    var session_dir = try ctx.store.openSessionDir("legacy-recovery-locks");
    defer session_dir.close();
    var session_lock = try io_mod.acquireTimedAdvisoryLock(
        &session_dir,
        "session.lock",
        2000,
    );
    const session_started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionBusy,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-recovery-locks" },
            ctx.workspace,
            .{ .log = .{
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            } },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - session_started_at_ms < 1000);
    session_lock.release();

    {
        var commit_lock = try io_mod.acquireTimedAdvisoryLock(
            &session_dir,
            "commit.lock",
            2000,
        );
        defer commit_lock.release();
        const commit_started_at_ms = io_mod.milliTimestamp();
        try std.testing.expectError(
            error.SessionCommitBoundaryUnavailable,
            ctx.store.resumeTargetForWrite(
                alloc,
                .{ .id = "legacy-recovery-locks" },
                ctx.workspace,
                .{ .log = .{
                    .session_lock_deadline_ms = 0,
                    .commit_lock_deadline_ms = 0,
                } },
            ),
        );
        try std.testing.expect(io_mod.milliTimestamp() - commit_started_at_ms < 1000);
    }

    var sessions = ctx.store.canonical_root.sessions orelse return error.TestExpectedEqual;
    var latest_lock = try io_mod.acquireTimedAdvisoryLock(
        &sessions,
        latest_sessions_lock_file,
        2000,
    );
    defer latest_lock.release();
    const latest_started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-recovery-locks" },
            ctx.workspace,
            .{ .log = .{
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            } },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - latest_started_at_ms < 1000);
}

test "interrupted migration confirms exact proposed authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "legacy-confirm", ctx.workspace, 20);
    var failure = MigrationBoundaryFailure{
        .target = .after_authority_namespace_sync,
    };

    try std.testing.expectError(
        error.LegacySessionMigrationIndeterminate,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-confirm" },
            ctx.workspace,
            failure.options(),
        ),
    );

    var resumed = try ctx.store.resumeForWrite(alloc, "legacy-confirm");
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-confirm", resumed.state.id);
    try std.testing.expectEqualStrings(ctx.workspace, resumed.state.workspace_root);
}

test "storage-only migration resolves an interrupted switch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(
        alloc,
        ctx.store,
        "legacy-storage-recovery",
        ctx.workspace,
        20,
    );
    var failure = MigrationBoundaryFailure{
        .target = .after_authority_marker_rename,
    };
    try std.testing.expectError(
        error.LegacySessionMigrationIndeterminate,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-storage-recovery" },
            ctx.workspace,
            failure.options(),
        ),
    );

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-storage-recovery",
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionMigrationStatus.migrated, result.status);
    try std.testing.expectEqual(@as(u8, 1), result.source_schema_version);
    try std.testing.expect(result.source_bytes > 0);
}

test "storage only migration recovery reports transition source metadata without rereading legacy copy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(
        alloc,
        ctx.store,
        "legacy-storage-metadata-recovery",
        ctx.workspace,
        20,
    );
    const original = try readFixtureFile(
        alloc,
        ctx.store,
        "legacy-storage-metadata-recovery",
        "session.json",
        max_session_bytes,
    );
    defer alloc.free(original);
    const session_dir = try sessionDirPath(
        alloc,
        ctx.store.sessions_dir,
        "legacy-storage-metadata-recovery",
    );
    defer alloc.free(session_dir);
    const legacy_copy_path = try std.fs.path.join(alloc, &.{
        session_dir,
        "session.legacy.json",
    });
    defer alloc.free(legacy_copy_path);
    var corruption = MigrationInterruptedStableCopyCorruption{
        .legacy_copy_path = legacy_copy_path,
    };
    try std.testing.expectError(
        error.LegacySessionMigrationIndeterminate,
        ctx.store.resumeTargetForWrite(
            alloc,
            .{ .id = "legacy-storage-metadata-recovery" },
            ctx.workspace,
            corruption.options(),
        ),
    );

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-storage-metadata-recovery",
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(SessionMigrationStatus.migrated, result.status);
    try std.testing.expectEqual(@as(u8, 1), result.source_schema_version);
    try std.testing.expectEqual(@as(u64, original.len), result.source_bytes);
}

test "history page validates request input before replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    try std.testing.expectError(error.InvalidSessionId, ctx.store.loadHistoryPage(alloc, "../unsafe", null, 1));
    try std.testing.expectError(error.InvalidHistoryPageLimit, ctx.store.loadHistoryPage(alloc, "missing", null, 0));
    try std.testing.expectError(error.InvalidHistoryPageLimit, ctx.store.loadHistoryPage(alloc, "missing", null, 101));
    try std.testing.expectError(error.InvalidHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "missing", "v2:missing:1:1:0000000000000000000000000000000000000000000000000000000000000000:2", 1));
}

test "history page returns bounded chronological pages from one snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-pages", ctx.workspace, 5, "turn");

    var newest = try ctx.store.loadHistoryPage(alloc, "history-pages", null, 2);
    defer newest.deinit(alloc);
    try expectHistoryPagePrompts(newest, &.{ "turn-3", "turn-4" });
    const newest_cursor = newest.next_cursor orelse return error.TestExpectedEqual;
    const newest_snapshot = try parseHistoryPageCursor(newest_cursor);
    try std.testing.expectEqual(@as(usize, 5), newest.history_len);

    var middle = try ctx.store.loadHistoryPage(alloc, "history-pages", newest_cursor, 2);
    defer middle.deinit(alloc);
    try expectHistoryPagePrompts(middle, &.{ "turn-1", "turn-2" });
    try std.testing.expectEqual(newest.revision_ms, middle.revision_ms);
    try std.testing.expectEqual(newest.history_len, middle.history_len);
    const middle_cursor = middle.next_cursor orelse return error.TestExpectedEqual;
    const middle_snapshot = try parseHistoryPageCursor(middle_cursor);
    try std.testing.expectEqualSlices(u8, newest_snapshot.session_id, middle_snapshot.session_id);
    try std.testing.expectEqual(newest_snapshot.history_len, middle_snapshot.history_len);
    try std.testing.expectEqual(newest_snapshot.revision_ms, middle_snapshot.revision_ms);
    try std.testing.expectEqualSlices(u8, &newest_snapshot.prefix_digest, &middle_snapshot.prefix_digest);

    var oldest = try ctx.store.loadHistoryPage(alloc, "history-pages", middle_cursor, 2);
    defer oldest.deinit(alloc);
    try expectHistoryPagePrompts(oldest, &.{"turn-0"});
    try std.testing.expect(oldest.next_cursor == null);
}

test "history pages expose per-turn provenance through replacement checkpoint and compaction" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(
        alloc,
        ctx.store,
        "history-provenance-pages",
        ctx.workspace,
        0,
        "unused",
    );
    const history = try makeTaggedHistoryPageTurns(alloc, 5, "work");
    defer session.freeHistoryTurnSlice(alloc, history);
    {
        var writable = try ctx.store.resumeForWrite(alloc, "history-provenance-pages");
        defer writable.deinit(alloc);
        const desired = session_codec.DurableSessionState{
            .id = writable.state.id,
            .origin_workspace_root = writable.state.origin_workspace_root,
            .workspace_root = writable.state.workspace_root,
            .created_at_ms = writable.state.created_at_ms,
            .updated_at_ms = 20,
            .conversation_language = writable.state.conversation_language,
            .preferences = writable.state.preferences,
            .history = history,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .last_subagent_work_id = @constCast("work-4"),
        };
        _ = try writable.commitStateReplacement(
            alloc,
            desired,
            .recovery,
            .retry_expected_tail,
            .{},
        );
    }

    var newest = try ctx.store.loadHistoryPage(
        alloc,
        "history-provenance-pages",
        null,
        2,
    );
    defer newest.deinit(alloc);
    try std.testing.expectEqualStrings(
        "work-3",
        newest.turns[0].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings(
        "work-4",
        newest.turns[1].assistant.user.work_id.?,
    );
    var older = try ctx.store.loadHistoryPage(
        alloc,
        "history-provenance-pages",
        newest.next_cursor.?,
        2,
    );
    defer older.deinit(alloc);
    try std.testing.expectEqualStrings(
        "work-1",
        older.turns[0].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings(
        "work-2",
        older.turns[1].assistant.user.work_id.?,
    );

    var writable = try ctx.store.resumeForWrite(alloc, "history-provenance-pages");
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{
            .checkpoint_interval = 1,
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );
    try std.testing.expectEqual(
        writable.position.through_seq,
        writable.generation_base_seq,
    );
    try std.testing.expectEqual(
        @as(?u64, writable.position.through_seq),
        writable.checkpoint_seq,
    );
    try std.testing.expect(!writable.compaction_warning_active);
    writable.deinit(alloc);

    var reloaded = try ctx.store.loadReadOnly(alloc, "history-provenance-pages");
    defer reloaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 5), reloaded.history.len);
    try std.testing.expectEqualStrings("work-4", reloaded.last_subagent_work_id.?);
    for (reloaded.history, 0..) |turn, index| {
        const expected = try std.fmt.allocPrint(alloc, "work-{d}", .{index});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(
            expected,
            turn.assistant.user.work_id.?,
        );
    }

    const direct_history = try alloc.alloc(session.HistoryTurn, 6);
    var copied: usize = 0;
    errdefer {
        for (direct_history[0..copied]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(direct_history);
    }
    for (reloaded.history, 0..) |turn, index| {
        direct_history[index] = try session.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    direct_history[5] = try session.makeAssistantTurn(
        alloc,
        "direct human resume",
        "direct reply",
    );
    copied += 1;
    defer session.freeHistoryTurnSlice(alloc, direct_history);
    {
        var direct = try ctx.store.resumeForWrite(alloc, "history-provenance-pages");
        defer direct.deinit(alloc);
        const desired = session_codec.DurableSessionState{
            .id = direct.state.id,
            .origin_workspace_root = direct.state.origin_workspace_root,
            .workspace_root = direct.state.workspace_root,
            .created_at_ms = direct.state.created_at_ms,
            .updated_at_ms = 40,
            .conversation_language = direct.state.conversation_language,
            .preferences = direct.state.preferences,
            .history = direct_history,
            .context_history_start = direct.state.context_history_start,
            .total_input_tokens = direct.state.total_input_tokens,
            .total_output_tokens = direct.state.total_output_tokens,
            .last_subagent_work_id = direct.state.last_subagent_work_id,
            .usage = direct.state.usage,
        };
        _ = try direct.commitStateReplacement(
            alloc,
            desired,
            .recovery,
            .retry_expected_tail,
            .{},
        );
    }
    var direct_reloaded = try ctx.store.loadReadOnly(
        alloc,
        "history-provenance-pages",
    );
    defer direct_reloaded.deinit(alloc);
    try std.testing.expectEqualStrings(
        "work-0",
        direct_reloaded.history[0].assistant.user.work_id.?,
    );
    try std.testing.expect(
        direct_reloaded.history[5].assistant.user.work_id == null,
    );
    try std.testing.expectEqualStrings(
        "work-4",
        direct_reloaded.last_subagent_work_id.?,
    );
}

test "history cursor survives append but rejects provenance-only prefix changes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(
        alloc,
        ctx.store,
        "history-provenance-cursor",
        ctx.workspace,
        0,
        "unused",
    );
    const history = try makeTaggedHistoryPageTurns(alloc, 4, "same");
    defer session.freeHistoryTurnSlice(alloc, history);
    try replaceHistoryPageTurnsFixture(
        alloc,
        ctx.store,
        "history-provenance-cursor",
        20,
        history,
    );
    var initial = try ctx.store.loadHistoryPage(
        alloc,
        "history-provenance-cursor",
        null,
        2,
    );
    defer initial.deinit(alloc);
    const cursor = initial.next_cursor.?;

    const appended = try makeTaggedHistoryPageTurns(alloc, 5, "same");
    defer session.freeHistoryTurnSlice(alloc, appended);
    try replaceHistoryPageTurnsFixture(
        alloc,
        ctx.store,
        "history-provenance-cursor",
        30,
        appended,
    );
    var continuation = try ctx.store.loadHistoryPage(
        alloc,
        "history-provenance-cursor",
        cursor,
        2,
    );
    defer continuation.deinit(alloc);
    try expectHistoryPagePrompts(continuation, &.{ "same-0", "same-1" });

    alloc.free(appended[0].assistant.user.work_id.?);
    appended[0].assistant.user.work_id = try alloc.dupe(u8, "changed-only-provenance");
    try replaceHistoryPageTurnsFixture(
        alloc,
        ctx.store,
        "history-provenance-cursor",
        40,
        appended[0..4],
    );
    try std.testing.expectError(
        error.StaleHistoryPageCursor,
        ctx.store.loadHistoryPage(
            alloc,
            "history-provenance-cursor",
            cursor,
            2,
        ),
    );
}

test "history page continuation survives append but rejects changed snapshot prefixes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-stale", ctx.workspace, 4, "base");

    var initial = try ctx.store.loadHistoryPage(alloc, "history-stale", null, 2);
    defer initial.deinit(alloc);
    const cursor = initial.next_cursor orelse return error.TestExpectedEqual;
    try replaceHistoryPageFixture(alloc, ctx.store, "history-stale", 30, 5, "base");
    var appended = try ctx.store.loadHistoryPage(alloc, "history-stale", cursor, 2);
    defer appended.deinit(alloc);
    try expectHistoryPagePrompts(appended, &.{ "base-0", "base-1" });
    try std.testing.expectEqual(@as(usize, 4), appended.history_len);
    try std.testing.expectEqual(@as(i64, 20), appended.revision_ms);

    try replaceHistoryPageFixture(alloc, ctx.store, "history-stale", 40, 4, "replaced");
    try std.testing.expectError(error.StaleHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "history-stale", cursor, 2));
    try replaceHistoryPageFixture(alloc, ctx.store, "history-stale", 50, 3, "base");
    try std.testing.expectError(error.StaleHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "history-stale", cursor, 2));
}

test "history page cursor rejects another session and noncanonical encodings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-one", ctx.workspace, 2, "one");
    try createHistoryPageFixture(alloc, ctx.store, "history-two", ctx.workspace, 2, "two");
    var page = try ctx.store.loadHistoryPage(alloc, "history-one", null, 1);
    defer page.deinit(alloc);
    const cursor = page.next_cursor orelse return error.TestExpectedEqual;
    try std.testing.expectError(error.InvalidHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "history-two", cursor, 1));
    inline for (.{ "", "v2:history-one:02:20:0000000000000000000000000000000000000000000000000000000000000000:1", "v2:history-one:2:-1:0000000000000000000000000000000000000000000000000000000000000000:1", "v2:history-one:2:20:0000000000000000000000000000000000000000000000000000000000000000:3", "v2:history-one:2:20:0000000000000000000000000000000000000000000000000000000000000000:1:extra", "v2:history-one:999999999999999999999999999999999999999:20:0000000000000000000000000000000000000000000000000000000000000000:1" }) |bad| {
        try std.testing.expectError(error.InvalidHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "history-one", bad, 1));
    }
}

test "history page handles empty and legacy readable sessions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-empty", ctx.workspace, 0, "none");
    var empty = try ctx.store.loadHistoryPage(alloc, "history-empty", null, 100);
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.turns.len);
    try std.testing.expect(empty.next_cursor == null);

    try writeLegacyFixture(alloc, ctx.store, "history-legacy", ctx.workspace, 20);
    var legacy = try ctx.store.loadHistoryPage(alloc, "history-legacy", null, 1);
    defer legacy.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), legacy.turns.len);
}

test "history page maps missing unsafe unavailable unsupported and corrupt sessions distinctly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try std.testing.expectError(error.SessionNotFound, ctx.store.loadHistoryPage(alloc, "missing-history-page", null, 1));

    try tmp.dir.createDirPath(io_mod.getIo(), "empty-home");
    const empty_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "empty-home");
    defer alloc.free(empty_home);
    var empty_store = try Store.initReadOnlyFromHome(alloc, empty_home, ctx.workspace);
    defer empty_store.deinit(alloc);
    try std.testing.expectError(error.SessionNotFound, empty_store.loadHistoryPage(alloc, "missing-history-page", null, 1));

    const unsupported = try writeSessionFixture(
        alloc,
        ctx.store,
        "history-unsupported",
        "{\"schema_version\":99,\"id\":\"history-unsupported\",\"created_at_ms\":1,\"updated_at_ms\":8,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}",
    );
    defer alloc.free(unsupported);
    try std.testing.expectError(error.UnsupportedSessionFormat, ctx.store.loadHistoryPage(alloc, "history-unsupported", null, 1));

    const corrupt = try writeSessionFixture(alloc, ctx.store, "history-corrupt", "{");
    defer alloc.free(corrupt);
    try std.testing.expectError(error.CorruptSession, ctx.store.loadHistoryPage(alloc, "history-corrupt", null, 1));

    try createHistoryPageFixture(alloc, ctx.store, "history-authority-corrupt", ctx.workspace, 1, "authority");
    try writeFixtureEntry(alloc, ctx.store, "history-authority-corrupt", "authority.json", "{");
    try std.testing.expectError(error.CorruptSession, ctx.store.loadHistoryPage(alloc, "history-authority-corrupt", null, 1));

    try tmp.dir.createDirPath(io_mod.getIo(), "outside-history-session");
    tmp.dir.symLink(
        io_mod.getIo(),
        "../../../outside-history-session",
        "home/.fx/sessions/history-unsafe",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectError(error.SessionPathUnsafe, ctx.store.loadHistoryPage(alloc, "history-unsafe", null, 1));

    try chmodPath(alloc, ctx.store.sessions_dir, 0o000);
    var restore_sessions_permissions = true;
    defer if (restore_sessions_permissions) {
        chmodPath(alloc, ctx.store.sessions_dir, 0o700) catch {};
    };
    try std.testing.expectError(error.SessionStoreUnavailable, ctx.store.loadHistoryPage(alloc, "history-corrupt", null, 1));
    try chmodPath(alloc, ctx.store.sessions_dir, 0o700);
    restore_sessions_permissions = false;
}

test "history page covers less than exactly and more than one page" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-sizes", ctx.workspace, 3, "size");

    var less = try ctx.store.loadHistoryPage(alloc, "history-sizes", null, 4);
    defer less.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), less.turns.len);
    try std.testing.expect(less.next_cursor == null);

    var exact = try ctx.store.loadHistoryPage(alloc, "history-sizes", null, 3);
    defer exact.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), exact.turns.len);
    try std.testing.expect(exact.next_cursor == null);

    var more = try ctx.store.loadHistoryPage(alloc, "history-sizes", null, 2);
    defer more.deinit(alloc);
    try expectHistoryPagePrompts(more, &.{ "size-1", "size-2" });
    try std.testing.expect(more.next_cursor != null);
}

test "history page rejects longer changed prefix and malformed cursor before replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-longer-stale", ctx.workspace, 4, "old");
    var page = try ctx.store.loadHistoryPage(alloc, "history-longer-stale", null, 2);
    defer page.deinit(alloc);
    const cursor = page.next_cursor orelse return error.TestExpectedEqual;
    try replaceHistoryPageFixture(alloc, ctx.store, "history-longer-stale", 30, 6, "new");
    try std.testing.expectError(error.StaleHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "history-longer-stale", cursor, 2));

    try std.testing.expectError(
        error.InvalidHistoryPageCursor,
        ctx.store.loadHistoryPage(alloc, "not-created", "not-a-v2-cursor", 2),
    );
    var oversized: [513]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(error.InvalidHistoryPageCursor, ctx.store.loadHistoryPage(alloc, "not-created", &oversized, 2));
}

test "history page preserves specialized canonical turns and deep-copy ownership" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-specialized", ctx.workspace, 0, "none");

    var calls = [_]session.ToolCall{.{
        .id = "call-1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"unicode-λ\"}",
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("tool output"),
        .output_bytes = 11,
        .stored_output_bytes = 11,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .assistant = @constCast("using tool"),
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    const turns = [_]session.HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("specialized") },
            .assistant = @constCast("assistant λ"),
            .execution = .{ .tool_steps = &steps },
        } },
        .{ .background_command = .{
            .user = .{ .text = @constCast("background") },
            .assistant = @constCast("started"),
            .log_path = @constCast("/tmp/background.log"),
            .expect_url = true,
            .url = @constCast("https://example.test"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("interrupted") },
            .assistant = @constCast("partial"),
            .tool_call = .{ .id = "call-2", .name = "shell", .arguments_json = "{}" },
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("compacted λ"),
            .removed_turn_count = 7,
            .compaction_count = 2,
        } },
    };
    try replaceHistoryPageTurnsFixture(alloc, ctx.store, "history-specialized", 30, &turns);

    var first = try ctx.store.loadHistoryPage(alloc, "history-specialized", null, 4);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), first.turns.len);
    try std.testing.expectEqualStrings("tool output", first.turns[0].assistant.execution.tool_steps[0].tool_results[0].output);
    try std.testing.expectEqualStrings("/tmp/background.log", first.turns[1].background_command.log_path);
    try std.testing.expectEqualStrings("partial", first.turns[2].interrupted.assistant.?);
    try std.testing.expectEqualStrings("compacted λ", first.turns[3].compacted_summary.summary);
    first.turns[0].assistant.assistant[0] = 'X';

    var second = try ctx.store.loadHistoryPage(alloc, "history-specialized", null, 4);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("assistant λ", second.turns[0].assistant.assistant);
}

test "history page read ignores an externally held session lock" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "history-locked", ctx.workspace, 1, "locked");
    var session_dir = try ctx.store.openSessionDir("history-locked");
    defer session_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(&session_dir, "session.lock", 2000);
    defer lock.release();

    var page = try ctx.store.loadHistoryPage(alloc, "history-locked", null, 1);
    defer page.deinit(alloc);
    try expectHistoryPagePrompts(page, &.{"locked-0"});
}

test "history page streaming digest has fixed memory and cursor parser fuzz coverage" {
    const repeated = session.HistoryTurn{ .assistant = .{
        .user = .{ .text = @constCast("large-history") },
        .assistant = @constCast("response"),
    } };
    var large: [4096]session.HistoryTurn = undefined;
    @memset(&large, repeated);
    const digest = try historyPrefixDigest(&large);
    try std.testing.expect(!std.mem.allEqual(u8, &digest, 0));

    var oversized: [513]u8 = undefined;
    @memset(&oversized, '0');
    try std.testing.expectError(error.InvalidHistoryPageCursor, parseHistoryPageCursor(&oversized));
    var bytes: [512]u8 = undefined;
    var random_state: u64 = 0x9e3779b97f4a7c15;
    for (0..2048) |_| {
        random_state = random_state *% 6364136223846793005 +% 1442695040888963407;
        const len = @as(usize, @intCast((random_state >> 32) % bytes.len)) + 1;
        for (bytes[0..len]) |*byte| {
            random_state = random_state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(random_state >> 24);
        }
        if (parseHistoryPageCursor(bytes[0..len])) |parsed| {
            var canonical: [512]u8 = undefined;
            const encoded = try formatHistoryPageCursor(&canonical, parsed);
            try std.testing.expectEqualSlices(u8, bytes[0..len], encoded);
            try std.testing.expect(parsed.start <= parsed.history_len);
            try std.testing.expect(parsed.revision_ms >= 0);
        } else |err| {
            try std.testing.expectEqual(error.InvalidHistoryPageCursor, err);
        }
    }
}

test "history page allocation failure sweep frees replay and page ownership" {
    const backing = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(backing, &tmp);
    defer ctx.deinit(backing);
    try createHistoryPageFixture(backing, ctx.store, "history-allocation", ctx.workspace, 3, "allocation");
    const tagged = try makeTaggedHistoryPageTurns(backing, 3, "allocation");
    defer session.freeHistoryTurnSlice(backing, tagged);
    try replaceHistoryPageTurnsFixture(
        backing,
        ctx.store,
        "history-allocation",
        30,
        tagged,
    );

    var probe = std.testing.FailingAllocator.init(backing, .{});
    var probe_page = try ctx.store.loadHistoryPage(probe.allocator(), "history-allocation", null, 2);
    probe_page.deinit(probe.allocator());
    const allocation_count = probe.alloc_index;
    try std.testing.expect(allocation_count > 0);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (ctx.store.loadHistoryPage(failing.allocator(), "history-allocation", null, 2)) |page_value| {
            var page = page_value;
            page.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory, error.SessionStoreUnavailable => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

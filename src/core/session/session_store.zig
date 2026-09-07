const std = @import("std");
const builtin = @import("builtin");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
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
const catalog_cache = @import("session_catalog_cache.zig");
const session_child_store = @import("session_child_store.zig");
const relationship_index_codec = @import("session_relationship_index_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_layout = @import("session_layout.zig");
const session_log = @import("session_log.zig");
const session_replay = @import("session_replay.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const discovery = @import("session_discovery.zig");
const migration = @import("session_migration.zig");
const paths = @import("session_store_paths.zig");
const store_types = @import("session_store_types.zig");
const summary_codec = @import("session_summary_codec.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const classifyAuthority = authority_module.classifyAuthority;
const classifyAuthorityAllowingLargeLegacy = authority_module.classifyAuthorityAllowingLargeLegacy;
const deleteSessionEntry = authority_module.deleteSessionEntry;
const openSessionFile = authority_module.openSessionFile;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
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
const retired_latest_sessions_dir = "latest";
const recovery_staging_dir = "recovery+staging";
const recovery_staging_lock_file = "recovery-staging.lock";
const usage_recovery_dir = profile_paths.usage_recovery_dir_name;
const usage_recovery_marker_prefix = "v1 ";
const max_usage_recovery_marker_bytes =
    usage_recovery_marker_prefix.len + 20 + 1;
const max_usage_recovery_sessions: usize = 512;
const LegacyStoredSession = migration.LegacyStoredSession;
const MigrationPreferenceSource = migration.MigrationPreferenceSource;
const legacyToDurableState = migration.legacyToDurableState;
const loadSchemaV3ReadOnly = migration.loadSchemaV3ReadOnly;
const migrateLegacyLocked = migration.migrateLegacyLocked;
const migrateSchemaV3Locked = migration.migrateSchemaV3Locked;
const normalizeWorkspaceRoot = paths.normalizeWorkspaceRoot;
pub const sessionDirPath = paths.sessionDirPath;
const sessionJsonPath = paths.sessionJsonPath;
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
    marker_modified_at_ns: i128 = 0,

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

const ConversationHistoryPageCursor = struct {
    session_id: []const u8,
    history_len: usize,
    start: usize,
};

fn parseConversationHistoryPageCursor(
    raw: []const u8,
) LoadHistoryPageError!ConversationHistoryPageCursor {
    if (raw.len == 0 or raw.len > 512) return error.InvalidHistoryPageCursor;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHistoryPageCursor, "v3")) {
        return error.InvalidHistoryPageCursor;
    }
    const session_id = fields.next() orelse return error.InvalidHistoryPageCursor;
    const history_len = std.fmt.parseInt(
        usize,
        fields.next() orelse return error.InvalidHistoryPageCursor,
        10,
    ) catch return error.InvalidHistoryPageCursor;
    const start = std.fmt.parseInt(
        usize,
        fields.next() orelse return error.InvalidHistoryPageCursor,
        10,
    ) catch return error.InvalidHistoryPageCursor;
    if (fields.next() != null or start > history_len) {
        return error.InvalidHistoryPageCursor;
    }
    validateSessionId(session_id) catch return error.InvalidHistoryPageCursor;
    return .{
        .session_id = session_id,
        .history_len = history_len,
        .start = start,
    };
}

fn formatConversationHistoryPageCursor(
    buffer: []u8,
    cursor: ConversationHistoryPageCursor,
) ![]u8 {
    return std.fmt.bufPrint(buffer, "v3:{s}:{d}:{d}", .{
        cursor.session_id,
        cursor.history_len,
        cursor.start,
    });
}

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

fn latestCheckpointHistoryIndex(history: []const session.HistoryTurn) usize {
    var result: usize = 0;
    for (history, 0..) |turn, index| {
        if (turn == .compacted_summary) result = index;
    }
    return result;
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
const ResumableSessionScope = enum {
    all_workspaces,
    current_workspace,
};
pub const StorageFormat = store_types.StorageFormat;
const automatic_legacy_max_bytes = store_types.automatic_legacy_max_bytes;
const max_session_bytes = store_types.max_session_bytes;
const StoreContext = store_types.StoreContext;
const freeSummaries = summary_codec.freeSummaries;
const resumablePageFromSummaries = summary_codec.resumablePageFromSummaries;
const sessionListPageFromSummaries = summary_codec.sessionListPageFromSummaries;
const sortSummariesNewestFirst = summary_codec.sortSummariesNewestFirst;

const SessionSummaryScan = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    skipped_invalid: usize = 0,

    fn deinit(self: *SessionSummaryScan, alloc: Allocator) void {
        freeSummaries(alloc, &self.summaries);
        self.* = undefined;
    }
};

/// Borrows its store's directory handles. The caller owns each returned candidate.
pub const CandidateIterator = struct {
    store: Store,
    entries: ?std.Io.Dir.Iterator,
    mode: DiscoveryMode = .read_only_list,
    skipped_invalid: usize = 0,

    pub fn next(self: *CandidateIterator, alloc: Allocator) !?ReadOnlyCandidate {
        while (try self.nextName(null)) |name| {
            return self.store.readOnlyCandidate(alloc, name, null) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    logDiscoveryError(self.mode, name, null, null, err);
                    self.skipped_invalid += 1;
                    continue;
                },
            };
        }
        return null;
    }

    /// Returns an owned ID; callers sharing an iterator must serialize advancement.
    pub fn nextId(
        self: *CandidateIterator,
        alloc: Allocator,
        cancelled: ?*const std.atomic.Value(bool),
    ) !?[]u8 {
        const name = (try self.nextName(cancelled)) orelse return null;
        return try alloc.dupe(u8, name);
    }

    fn nextName(self: *CandidateIterator, cancelled: ?*const std.atomic.Value(bool)) !?[]const u8 {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        const entries = if (self.entries) |*value| value else return null;
        while (true) {
            if (cancelled) |stop| {
                if (stop.load(.acquire)) return error.Cancelled;
            }
            const entry = (try entries.next(io_mod.getIo())) orelse return null;
            if (entry.kind != .directory or std.mem.eql(u8, entry.name, retired_latest_sessions_dir)) continue;
            validateSessionId(entry.name) catch continue;
            return entry.name;
        }
    }
};

test {
    _ = session_child_store;
    _ = session_layout;
    _ = session_log;
    _ = session_display_metadata;
    _ = store_types;
    _ = paths;
    _ = authority_module;
    _ = summary_codec;
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

    /// Starts a new conversation and attaches its writable managed-child
    /// capability. Caller owns the returned session.
    pub fn startWritableSessionWithOptions(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var root = self.canonical_root;
        var loaded = try root.startConversationSession(
            alloc,
            state,
            options,
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
        var loaded = try staging_root.startConversationSession(alloc, state, options);
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
        if (staging_root.mode != .writable) {
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
            true,
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
            true,
        );
    }

    fn deleteWriterOwnedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
        event_name: []const u8,
        cascade_children: bool,
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
        const sessions = &(self.canonical_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sessions_root",
                .{event_name},
            );
            return .indeterminate;
        });
        if (cascade_children and !self.deleteOwnedSubagentChildren(
            alloc,
            loaded.active_id,
            event_name,
        )) {
            return .indeterminate;
        }
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
        debug_trace.logf(
            "session",
            "event={s} disposition=discarded",
            .{event_name},
        );
        return .discarded;
    }

    fn deleteOwnedSubagentChildren(
        self: Store,
        alloc: Allocator,
        parent_id: []const u8,
        event_name: []const u8,
    ) bool {
        const children = self.loadOwnedSubagentChildIds(alloc, parent_id) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=child_index err={s}",
                .{ event_name, @errorName(err) },
            );
            return false;
        };
        defer {
            for (children) |child_id| alloc.free(child_id);
            if (children.len > 0) alloc.free(children);
        }
        for (children) |child_id| {
            if (!(self.childOwnerMatches(alloc, child_id, parent_id) catch |err| {
                debug_trace.logf(
                    "session",
                    "event={s} disposition=indeterminate stage=child_owner child_id={s} err={s}",
                    .{ event_name, child_id, @errorName(err) },
                );
                return false;
            })) {
                debug_trace.logf(
                    "session",
                    "event={s} disposition=indeterminate stage=child_owner child_id={s} err=OwnerMismatch",
                    .{ event_name, child_id },
                );
                return false;
            }
            var child = self.resumeForWrite(alloc, child_id) catch |err| switch (err) {
                error.SessionNotFound => continue,
                else => {
                    debug_trace.logf(
                        "session",
                        "event={s} disposition=indeterminate stage=child_resume child_id={s} err={s}",
                        .{ event_name, child_id, @errorName(err) },
                    );
                    return false;
                },
            };
            if (self.deleteWriterOwnedSession(
                alloc,
                &child,
                event_name,
                false,
            ) != .discarded) {
                return false;
            }
        }
        return true;
    }

    fn loadOwnedSubagentChildIds(
        self: Store,
        alloc: Allocator,
        parent_id: []const u8,
    ) ![][]u8 {
        var capability = try self.openSubagentControlCapabilityReadOnly(
            alloc,
            parent_id,
            .{},
        );
        defer capability.deinit();
        var file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "children.json",
        ) catch |err| switch (err) {
            error.FileNotFound => return alloc.alloc([]u8, 0),
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, 512 * 1024);
        defer alloc.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSubagentState;
        const stored_parent = parsed.value.object.get("parent_id") orelse
            return error.InvalidSubagentState;
        const children_value = parsed.value.object.get("children") orelse
            return error.InvalidSubagentState;
        if (stored_parent != .string or
            !std.mem.eql(u8, stored_parent.string, parent_id) or
            children_value != .array or children_value.array.items.len > 256)
        {
            return error.InvalidSubagentState;
        }
        const result = try alloc.alloc([]u8, children_value.array.items.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |child_id| alloc.free(child_id);
            alloc.free(result);
        }
        for (children_value.array.items) |item| {
            if (item != .object) return error.InvalidSubagentState;
            const id = item.object.get("id") orelse return error.InvalidSubagentState;
            if (id != .string) return error.InvalidSubagentState;
            session_layout.validateSessionId(id.string) catch
                return error.InvalidSubagentState;
            result[initialized] = try alloc.dupe(u8, id.string);
            initialized += 1;
        }
        return result;
    }

    fn childOwnerMatches(
        self: Store,
        alloc: Allocator,
        child_id: []const u8,
        parent_id: []const u8,
    ) !bool {
        var capability = self.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            .{},
        ) catch |err| switch (err) {
            error.SessionNotFound => return true,
            else => return err,
        };
        defer capability.deinit();
        var file = try capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "owner.json",
        );
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, 4096);
        defer alloc.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const stored_parent = parsed.value.object.get("parent_id") orelse return false;
        return stored_parent == .string and
            std.mem.eql(u8, stored_parent.string, parent_id);
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
            .last => try self.resumeLatestByDiscovery(alloc, workspace_root, options),
        };
        return self.finishResumedForWrite(alloc, loaded, options);
    }

    fn finishResumedForWrite(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        _: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        const needs_permission_migration =
            loaded.state.permission_state.version !=
            session_permission_state.schema_version;
        if (needs_permission_migration) {
            var migrated_permission_state = try session_permission_state.migrateV1ToV2(
                alloc,
                loaded.state.permission_state,
            );
            defer migrated_permission_state.deinit(alloc);
            try loaded.replacePermissionState(
                alloc,
                migrated_permission_state,
                io_mod.milliTimestamp(),
            );
        }
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn resumeLatestByDiscovery(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        for (0..2) |attempt| {
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
        const selected = try self.selectWritableLastId(
            alloc,
            workspace_root,
            options,
        ) orelse return session_log.failLoadedWritableSession(error.NoSavedSessions);
        defer alloc.free(selected);
        var loaded = self.resumeExactForWrite(
            alloc,
            selected,
            workspace_root,
            false,
            options,
        ) catch |err| {
            logDiscoveryError(.workspace_writable_last, selected, null, null, err);
            return err;
        };
        errdefer loaded.deinit(alloc);
        return loaded;
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

    /// Replays complete canonical conversation turns without retaining the archive.
    /// The visitor borrows each turn only for the duration of append().
    pub fn visitConversationHistory(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        visitor: anytype,
    ) !void {
        try validateSessionId(session_id);
        var dir = try self.openSessionDir(session_id);
        defer dir.close();
        var buffer: [8192]u8 = undefined;
        var reader = try session_log.ConversationHistoryReader.init(alloc, &dir, &buffer);
        defer reader.deinit();
        while (try reader.next()) |turn| {
            var turns = [_]session.HistoryTurn{turn};
            defer session.freeHistoryTurn(alloc, turns[0]);
            try resolveSessionSnapshotLocators(alloc, &turns, self.sessions_dir, session_id);
            try visitor.append(turns[0]);
        }
    }

    /// Reads only the immutable initial-event child identity for a materialized
    /// schema-v3 session. Index-only and legacy rows have no such payload.
    pub fn loadSubagentChildIdentity(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        return self.canonical_root.loadSubagentChildIdentity(alloc, session_id);
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
        if (cursor) |raw| {
            if (std.mem.startsWith(u8, raw, "v3:")) {
                _ = try parseConversationHistoryPageCursor(raw);
            } else {
                _ = try parseHistoryPageCursor(raw);
            }
        }
        var session_dir = self.openSessionDir(session_id) catch |err|
            return mapHistoryPageLoadError(err);
        defer session_dir.close();
        if (session_log.hasConversationMetadata(alloc, &session_dir) catch |err|
            return mapHistoryPageLoadError(err))
        {
            var candidate = classifyReadOnlyCandidate(
                alloc,
                &session_dir,
                session_id,
            ) catch |err| return mapHistoryPageLoadError(err);
            defer candidate.deinit(alloc);
            const snapshot = if (cursor) |raw|
                try parseConversationHistoryPageCursor(raw)
            else
                ConversationHistoryPageCursor{
                    .session_id = candidate.summary.id,
                    .history_len = candidate.summary.history_len,
                    .start = candidate.summary.history_len,
                };
            if (!std.mem.eql(u8, snapshot.session_id, session_id)) {
                return error.InvalidHistoryPageCursor;
            }
            if (snapshot.history_len > candidate.summary.history_len) {
                return error.StaleHistoryPageCursor;
            }
            const window = selectHistoryPageWindow(
                snapshot.history_len,
                snapshot.start,
                limit,
            );
            const turns = session_log.loadConversationHistoryRange(
                alloc,
                &session_dir,
                window.start,
                window.end,
            ) catch |err| return mapHistoryPageLoadError(err);
            errdefer session.freeHistoryTurnSlice(alloc, turns);
            resolveSessionSnapshotLocators(
                alloc,
                turns,
                self.sessions_dir,
                session_id,
            ) catch |err| return mapHistoryPageLoadError(err);
            const next_cursor = if (window.start > 0) blk: {
                var encoded: [512]u8 = undefined;
                const raw = formatConversationHistoryPageCursor(&encoded, .{
                    .session_id = session_id,
                    .history_len = snapshot.history_len,
                    .start = window.start,
                }) catch return error.SessionStoreUnavailable;
                break :blk try alloc.dupe(u8, raw);
            } else null;
            errdefer if (next_cursor) |value| alloc.free(value);
            return .{
                .session_id = try alloc.dupe(u8, session_id),
                .revision_ms = candidate.summary.updated_at_ms,
                .history_len = snapshot.history_len,
                .turns = turns,
                .next_cursor = next_cursor,
            };
        }
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
                .conversation => self.loadConversationPreferences(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.SessionNotFound => error.SessionNotFound,
                    error.SessionPathUnsafe => error.SessionPathUnsafe,
                    else => error.SessionMetadataUnavailable,
                },
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

    fn loadConversationPreferences(
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
            session_codec.max_session_metadata_bytes,
        );
        defer alloc.free(bytes);
        var metadata = try session_codec.decodeSessionMetadata(alloc, bytes);
        defer metadata.deinit();
        if (!std.mem.eql(u8, metadata.value.id, session_id)) {
            return error.InvalidSessionMetadata;
        }
        return .{
            .provider = model_provider.parse(metadata.value.provider) orelse
                return error.InvalidSessionMetadata,
            .model = try alloc.dupe(u8, metadata.value.model),
            .effort = core_types.ReasoningEffort.parse(metadata.value.effort) orelse
                return error.InvalidSessionMetadata,
            .fast_mode = metadata.value.fast_mode,
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
        if (try session_log.hasConversationMetadata(alloc, &session_dir)) {
            var root = self.canonical_root;
            var state = try root.loadReadOnly(alloc, session_id, options.log);
            errdefer state.deinit(alloc);
            const archive = try session_log.loadConversationArchive(
                alloc,
                &session_dir,
            );
            session.freeHistoryTurnSlice(alloc, state.history);
            state.history = archive;
            state.context_history_start = latestCheckpointHistoryIndex(archive);
            try resolveSessionSnapshotLocators(
                alloc,
                state.history,
                self.sessions_dir,
                session_id,
            );
            return .{
                .summary = try summaryFromState(alloc, state),
                .state = state,
                .storage_format = .conversation,
            };
        }
        const authority = try classifyAuthority(alloc, &session_dir, session_id);
        return switch (authority) {
            .schema_v3 => {
                var source = try loadSchemaV3ReadOnly(
                    alloc,
                    &session_dir,
                    session_id,
                );
                var source_owned = true;
                defer if (source_owned) source.deinit(alloc);
                var state = source.takeState();
                source_owned = false;
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

    pub fn readOnlyCandidates(self: Store) CandidateIterator {
        return .{
            .store = self,
            .entries = if (self.canonical_root.sessions) |dir| dir.dir.iterate() else null,
        };
    }

    /// The caller owns the candidate. No directory handle escapes this read.
    pub fn readOnlyCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cancelled: ?*const std.atomic.Value(bool),
    ) !ReadOnlyCandidate {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        var dir = try self.openSessionDir(session_id);
        defer dir.close();
        return if (cancelled) |stop|
            discovery.classifyReadOnlyCandidateCancellable(alloc, &dir, session_id, stop)
        else
            classifyReadOnlyCandidate(alloc, &dir, session_id);
    }

    /// Invalidates the derived resume catalog after managed child ownership
    /// changes. The relationship index remains the canonical authority.
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
            const marker_stat = try recovery.dir.statFile(
                io_mod.getIo(),
                entry.name,
                .{ .follow_symlinks = false },
            );
            try marked.append(alloc, .{
                .id = try alloc.dupe(u8, entry.name),
                .protected_updated_at_ms = protected_updated_at_ms,
                .marker_modified_at_ns = marker_stat.mtime.nanoseconds,
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

    pub fn usageCheckpointModifiedAtNs(
        self: Store,
        session_id: []const u8,
    ) !?i128 {
        var session_dir = self.openSessionDir(session_id) catch |err| switch (err) {
            error.SessionNotFound => return null,
            else => return err,
        };
        defer session_dir.close();
        const stat = session_dir.dir.statFile(
            io_mod.getIo(),
            session_usage_sidecar.sidecar_file,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
        return stat.mtime.nanoseconds;
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
    /// payloads remain the authority for child ownership.
    pub fn listManagedChildCandidatesForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
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

    fn listResumablePageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageFromDiscoveryForScope(alloc, scope, active_id, continuation);
    }

    /// Rewrites the cached title for one indexed session. The index freezes
    /// display metadata once present, so a rename must update it here or the
    /// resume picker keeps serving the previously derived title.
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
    /// controls whether each session's subagent relationship index is opened.
    fn scanSessionSummariesWithDiagnostics(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
        probe_managed_children: bool,
    ) !SessionSummaryScan {
        var scan = SessionSummaryScan{};
        errdefer scan.deinit(alloc);
        var metadata: std.ArrayList(DiscoveryCandidateMetadata) = .empty;
        defer metadata.deinit(alloc);
        var iter = self.readOnlyCandidates();
        iter.mode = mode;
        while (try iter.next(alloc)) |value| {
            var candidate = value;
            const session_id = candidate.summary.id;
            if (probe_managed_children) {
                candidate.summary.has_managed_children =
                    self.sessionHasManagedChildren(alloc, session_id) catch |err| switch (err) {
                        error.OutOfMemory => {
                            candidate.deinit(alloc);
                            return error.OutOfMemory;
                        },
                        else => false,
                    };
            }
            logDiscovery(
                mode,
                session_id,
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
        scan.skipped_invalid = iter.skipped_invalid;
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
        var children_file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "children.json",
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (children_file) |*file| {
            defer file.deinit();
            const bytes = try file.readToEnd(alloc, 512 * 1024);
            defer alloc.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidSubagentState;
            const children = parsed.value.object.get("children") orelse
                return error.InvalidSubagentState;
            if (children != .array or children.array.items.len > 256) {
                return error.InvalidSubagentState;
            }
            return children.array.items.len != 0;
        }
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
            if (std.mem.eql(u8, entry.name, retired_latest_sessions_dir)) {
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
        var loaded = try writable_store.resumeForWrite(alloc, session_id);
        defer loaded.deinit(alloc);
        return .{};
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
        if (try session_log.legacyImportRecoveryNeeded(&session_dir)) {
            session_dir.close();
            {
                var writable = try self.openWritableSessionDir(
                    alloc,
                    session_id,
                    options.log.session_lock_deadline_ms,
                );
                defer writable.deinit(alloc);
                try session_log.recoverInterruptedLegacyImport(
                    alloc,
                    &writable,
                );
            }
            session_dir = try self.openSessionDir(session_id);
        }
        defer session_dir.close();
        if (try session_log.hasConversationMetadata(alloc, &session_dir)) {
            var root = self.canonical_root;
            const loaded = try root.resumeForWrite(alloc, session_id, options.log);
            return self.finishWorkspaceResume(
                alloc,
                loaded,
                workspace_root,
                allow_rebind,
            );
        }
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
                );
            },
            else => return err,
        };
        const loaded = switch (authority) {
            .schema_v3 => try self.migrateSchemaV3ForWrite(
                alloc,
                session_id,
                options,
            ),
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
        );
    }

    fn finishWorkspaceResume(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        workspace_root: []const u8,
        allow_rebind: bool,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            loaded.state.history,
            self.sessions_dir,
            loaded.active_id,
        );

        if (std.mem.eql(u8, loaded.state.workspace_root, workspace_root)) {
            return loaded;
        }
        if (!allow_rebind) {
            return session_log.failLoadedWritableSession(error.SessionTargetChanged);
        }

        const rebound = session_log.SessionUpdate{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast(workspace_root),
        } };
        _ = loaded.appendEvent(
            alloc,
            rebound,
            io_mod.milliTimestamp(),
        ) catch |err| return err;
        return loaded;
    }

    fn only_unpublished_creation(session_dir: *io_mod.VerifiedDir, allow_metadata: bool) !bool {
        if (try authority_module.entryExistsRelative(session_dir, "events.jsonl")) return false;
        var dir = try session_dir.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true });
        defer dir.close(io_mod.getIo());
        var entries = dir.iterate();
        while (try entries.next(io_mod.getIo())) |entry| {
            if (entry.kind != .file) return false;
            const is_lock = std.mem.eql(u8, entry.name, "session.lock");
            const is_metadata = allow_metadata and std.mem.eql(u8, entry.name, "session.json");
            const prefix = ".session.json.tmp.";
            if (!is_lock and !is_metadata) {
                if (entry.name.len != prefix.len + 32 or !std.mem.startsWith(u8, entry.name, prefix)) return false;
                for (entry.name[prefix.len..]) |byte| if (!std.ascii.isHex(byte)) return false;
            }
            const stat = try dir.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false });
            if (stat.kind != .file or stat.nlink != 1 or (is_lock and stat.size != 0)) return false;
        }
        return true;
    }

    const RankingScan = struct {
        cache: catalog_cache.Loaded,
        rows: std.ArrayList(catalog_cache.Entry) = .empty,
        remaining_bytes: usize = catalog_cache.max_bytes,
        publishable: bool = true,
        reused: usize = 0,
        refreshed: usize = 0,

        fn deinit(self: *RankingScan, alloc: Allocator) void {
            for (self.rows.items) |*row| row.deinit(alloc);
            self.rows.deinit(alloc);
            self.cache.deinit(alloc);
        }

        fn observe(self: *RankingScan, alloc: Allocator, stamp: [32]u8, id: []const u8, workspace: []const u8, updated_at_ms: i64, generation: session_event.Identifier) !void {
            if (!self.publishable) return;
            const bytes = id.len + workspace.len + 128;
            if (self.rows.items.len == catalog_cache.max_records or bytes > self.remaining_bytes) {
                self.publishable = false;
                return;
            }
            var row = catalog_cache.Entry{ .fingerprint = stamp, .value = .{ .legacy_ranking = try catalog_cache.Entry.LegacyRanking.clone(alloc, id, workspace, updated_at_ms, generation) } };
            errdefer row.deinit(alloc);
            try self.rows.append(alloc, row);
            self.remaining_bytes -= bytes;
        }

        fn publish(self: *RankingScan, store: Store, alloc: Allocator) void {
            debug_trace.logf("session", "legacy ranking cache reused={d} refreshed={d}", .{ self.reused, self.refreshed });
            if (!self.publishable) {
                debug_trace.logf("session", "legacy ranking cache not saved reason=observation_limit", .{});
                return;
            }
            if (self.refreshed == 0 and self.rows.items.len == self.cache.rankingCount()) return;
            var writer = (catalog_cache.Writer.init(store) catch |err| {
                debug_trace.logf("session", "legacy ranking cache not saved err={s}", .{@errorName(err)});
                return;
            }) orelse return;
            defer writer.deinit();
            var cancelled = std.atomic.Value(bool).init(false);
            writer.saveRanking(alloc, self.rows.items, &cancelled) catch |err| {
                debug_trace.logf("session", "legacy ranking cache not saved err={s}", .{@errorName(err)});
            };
        }
    };

    fn selectWritableLastId(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !?[]u8 {
        try validateWorkspaceRoot(workspace_root);
        const sessions = self.canonical_root.sessions orelse return null;
        var scan = RankingScan{ .cache = try catalog_cache.Loaded.load(alloc, sessions, null) };
        defer scan.deinit(alloc);
        var selected: ?WritableCandidate = null;
        defer if (selected) |*candidate| candidate.deinit(alloc);
        var dir = try sessions.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(io_mod.getIo());
        var iter = dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, retired_latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            var candidate = self.resolveWritableCandidate(
                alloc,
                entry.name,
                workspace_root,
                options,
                &scan,
            ) catch |err| {
                logDiscoveryError(
                    .workspace_writable_last,
                    entry.name,
                    null,
                    null,
                    err,
                );
                return err;
            } orelse continue;
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
        // No cache publication is reachable from an incomplete or failed scan.
        scan.publish(self, alloc);
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

    // Publication-only proof: replay does not validate the authority/manifest
    // gates skipped by early hits. Recheck them inside the fingerprint window.
    // Recoverable missing/bad manifests still resolve canonically, without caching.
    fn rankingPublicationFingerprint(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
        before: [32]u8,
        observed_generation: session_event.Identifier,
        replayed_generation: session_event.Identifier,
    ) ?[32]u8 {
        if (!std.mem.eql(u8, &observed_generation, &replayed_generation)) return null;
        if (session_log.readConversationMetadata(alloc, session_dir) catch return null) |value| {
            var metadata = value;
            metadata.deinit();
            return null;
        }
        if ((classifyAuthority(alloc, session_dir, session_id) catch return null) != .schema_v3) return null;
        var candidate = classifySchemaV3Candidate(alloc, session_dir, session_id) catch return null;
        defer candidate.deinit(alloc);
        if (candidate.projection_state != .stale) return null;
        const after = (catalog_cache.rankingFingerprintForOpenSession(self.canonical_root.sessions.?.dir, session_id, session_dir.dir, replayed_generation) catch return null) orelse return null;
        if (!std.mem.eql(u8, &before, &after)) return null;
        return after;
    }

    fn resolveWritableCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        _: ResumeOptions,
        scan: *RankingScan,
    ) !?WritableCandidate {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        if (scan.cache.rankingGeneration(session_id)) |generation| {
            const current = catalog_cache.rankingFingerprintForOpenSession(self.canonical_root.sessions.?.dir, session_id, session_dir.dir, generation) catch null;
            if (current) |stamp| if (try scan.cache.reuseRanking(alloc, session_id, stamp)) |value| {
                var row = value;
                defer row.deinit(alloc);
                const ranking = row.value.legacy_ranking;
                try scan.observe(alloc, stamp, ranking.id, ranking.workspace_root, ranking.updated_at_ms, ranking.generation);
                scan.reused += 1;
                return try dupeWritableCandidate(alloc, ranking.id, ranking.workspace_root, ranking.updated_at_ms, .schema_v3, .stale);
            };
        }
        if (try session_log.readConversationMetadata(alloc, &session_dir)) |value| {
            var metadata = value;
            defer metadata.deinit();
            if (std.mem.eql(u8, metadata.value.id, session_id) and
                try only_unpublished_creation(&session_dir, true))
            {
                debug_trace.logf("session", "latest selection retained incomplete creation id={s} disposition=skipped", .{session_id});
                return null;
            }
            return try discovery.writable_conversation_candidate(
                alloc,
                &session_dir,
                session_id,
                metadata.value,
                workspace_root,
            );
        }
        if (try authority_module.entryExistsRelative(&session_dir, "authority.pending.json")) {
            return try discovery.fenced_legacy_writable_candidate(
                alloc,
                &session_dir,
                session_id,
                self.workspace_root,
            );
        }
        return switch (try classifyAuthority(alloc, &session_dir, session_id)) {
            .legacy => {
                var candidate = classifyLegacyCandidate(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| {
                    if (err == error.FileNotFound and try only_unpublished_creation(&session_dir, false)) {
                        debug_trace.logf("session", "latest selection retained incomplete creation id={s} disposition=skipped", .{session_id});
                        return null;
                    }
                    return err;
                };
                defer candidate.deinit(alloc);
                return try dupeWritableCandidate(
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
                        return try dupeWritableCandidate(
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

                // Only misses read the first envelope. Probe failures leave the
                // canonical replay below in charge of errors and foreign fallback.
                const generation: ?session_event.Identifier = blk: {
                    var events = openSessionFile(&session_dir, "events.jsonl", .read_only) catch break :blk null;
                    defer events.close(io_mod.getIo());
                    break :blk session_replay.readFirstGeneration(alloc, events) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                };
                const before = if (generation) |value|
                    catalog_cache.rankingFingerprintForOpenSession(self.canonical_root.sessions.?.dir, session_id, session_dir.dir, value) catch null
                else
                    null;
                var source = loadSchemaV3ReadOnly(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| {
                    const candidate = projected orelse return err;
                    if (std.mem.eql(
                        u8,
                        candidate.summary.workspace_root.?,
                        workspace_root,
                    )) return err;
                    return try dupeWritableCandidate(
                        alloc,
                        candidate.summary.id,
                        candidate.summary.workspace_root.?,
                        candidate.summary.updated_at_ms,
                        .schema_v3,
                        .stale,
                    );
                };
                defer source.deinit(alloc);
                scan.refreshed += 1;
                // Only canonical successful replay reaches this point. The foreign
                // workspace fallback above must never become reusable evidence.
                if (before) |stamp| {
                    if (self.rankingPublicationFingerprint(alloc, &session_dir, session_id, stamp, generation.?, source.generation)) |current| {
                        try scan.observe(alloc, current, source.state.id, source.state.workspace_root, source.state.updated_at_ms, source.generation);
                    }
                }
                return try dupeWritableCandidate(
                    alloc,
                    source.state.id,
                    source.state.workspace_root,
                    source.state.updated_at_ms,
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

    fn migrateSchemaV3ForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.log.session_lock_deadline_ms,
        );
        errdefer writable.deinit(alloc);
        return migrateSchemaV3Locked(self.ctx(), alloc, &writable);
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
        const loaded = self.migrateLegacyWithoutCache(
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

    fn migrateLegacyWithoutCache(
        self: Store,
        alloc: Allocator,
        writable: *session_log.WritableSessionDir,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        return migrateLegacyLocked(
            self.ctx(),
            alloc,
            writable,
            workspace_root,
            preference_source,
            options,
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
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.log.session_lock_deadline_ms,
        );
        errdefer writable.deinit(alloc);

        var stable = openSessionFile(
            &writable.dir,
            "session.legacy.json",
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionAuthorityBoundaryUnavailable,
            else => return err,
        };
        defer stable.close(io_mod.getIo());
        const stat = try stable.stat(io_mod.getIo());
        const allowed_size = if (options.allow_large_legacy)
            stat.size
        else
            automatic_legacy_max_bytes;
        if (stat.size > allowed_size) return error.LegacySessionTooLarge;
        const bytes = readExactLegacyFile(
            alloc,
            &stable,
            stat.size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
            else => return error.LegacySessionMigrationFailed,
        };
        defer alloc.free(bytes);
        _ = try session_json.parseLegacySchemaVersion(alloc, bytes);

        try io_mod.durableReplaceVerified(
            alloc,
            &writable.dir,
            "session.json",
            bytes,
        );
        try deleteSessionEntry(&writable.dir, "authority.pending.json");
        try deleteSessionEntry(&writable.dir, "authority.json");
        try deleteSessionEntry(&writable.dir, "checkpoint.json");
        try io_mod.syncVerifiedDir(writable.dir.dir);

        return self.migrateLegacyWithoutCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        );
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
    /// Converts any supported older session to the current conversation format.
    /// Current sessions are reported without rewriting them.
    pub fn migrateLegacyStorageOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: MigrationOptions,
    ) !SessionMigrationResult {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        if (try session_log.legacyImportRecoveryNeeded(&session_dir)) {
            session_dir.close();
            {
                var writable = try self.openWritableSessionDir(
                    alloc,
                    session_id,
                    options.log.session_lock_deadline_ms,
                );
                defer writable.deinit(alloc);
                try session_log.recoverInterruptedLegacyImport(
                    alloc,
                    &writable,
                );
            }
            session_dir = try self.openSessionDir(session_id);
        }
        if (try session_log.hasConversationMetadata(alloc, &session_dir)) {
            session_dir.close();
            return .{
                .session_id = try alloc.dupe(u8, session_id),
                .source_schema_version = session_codec.session_metadata_schema_version,
                .source_bytes = 0,
                .status = .already_current,
            };
        }
        const authority = (if (options.allow_large)
            classifyAuthorityAllowingLargeLegacy(alloc, &session_dir, session_id)
        else
            classifyAuthority(alloc, &session_dir, session_id)) catch |err| {
            session_dir.close();
            if (err != error.SessionAuthorityBoundaryUnavailable) return err;
            var recovered = try self.resolveAuthorityTransitionForWrite(
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
            defer recovered.deinit(alloc);
            return migrationResultFromLoaded(alloc, session_id, recovered);
        };
        session_dir.close();

        var migrated = switch (authority) {
            .schema_v3 => try self.migrateSchemaV3ForWrite(
                alloc,
                session_id,
                .{ .log = options.log },
            ),
            .legacy => try self.migrateLegacyForWrite(
                alloc,
                session_id,
                self.workspace_root,
                .preserved_workspace,
                .{
                    .allow_large_legacy = options.allow_large,
                    .seed_preferences = options.seed_preferences,
                    .log = options.log,
                },
            ),
        };
        defer migrated.deinit(alloc);
        return migrationResultFromLoaded(alloc, session_id, migrated);
    }

    fn migrationResultFromLoaded(
        alloc: Allocator,
        session_id: []const u8,
        loaded: LoadedWritableSession,
    ) !SessionMigrationResult {
        const source_schema_version = loaded.migration_source_schema_version orelse
            return error.LegacySessionMigrationFailed;
        const source_bytes = loaded.migration_source_bytes orelse
            return error.LegacySessionMigrationFailed;
        return .{
            .session_id = try alloc.dupe(u8, session_id),
            .source_schema_version = source_schema_version,
            .source_bytes = source_bytes,
            .status = .migrated,
        };
    }

    /// Copies a validated conversation prefix or legacy manifest boundary to a
    /// new session. The source is locked for the read and is never modified.
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
        var metadata = session_log.readConversationMetadata(alloc, &source.dir) catch |err| switch (err) {
            error.InvalidSessionMetadata, error.InvalidSessionFormat => return error.SessionRecoveryBoundaryInvalid,
            else => return err,
        };
        defer if (metadata) |*current| current.deinit();
        var current_boundary: ?session_log.ConversationRecoveryBoundary = null;
        var recovered = recovery_state: {
            if (metadata) |current| {
                if (!std.mem.eql(u8, current.value.id, session_id)) return error.SessionRecoveryBoundaryInvalid;
                if (current.value.subagent_child) return error.SessionNotFound;
                current_boundary = try session_log.find_conversation_recovery_boundary(alloc, &source.dir);
                break :recovery_state try session_log.load_conversation_recovery_state(alloc, &source.dir, session_id, current_boundary.?);
            }
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

            var manifest = session_projection.decodeManifest(alloc, manifest_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SessionRecoveryBoundaryInvalid,
            };
            defer manifest.deinit(alloc);
            if (!std.mem.eql(u8, manifest.id, session_id)) return error.SessionRecoveryBoundaryInvalid;
            var events = openSessionFile(&source.dir, "events.jsonl", .read_only) catch
                return error.SessionRecoveryBoundaryInvalid;
            defer events.close(io_mod.getIo());
            var imported = session_replay.replayCommittedPrefix(
                alloc,
                events,
                manifest.log_generation,
                manifest.last_event_seq,
                manifest.event_log_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedSessionSchema => return error.SessionRecoveryUnsupportedSchema,
                else => return error.SessionRecoveryBoundaryInvalid,
            };
            var imported_owned = true;
            defer if (imported_owned) imported.deinit(alloc);
            if (!session_projection.stateMatchesManifest(imported.state, manifest)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const recovered_state = imported.takeState();
            imported_owned = false;
            break :recovery_state recovered_state;
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
        if (try subagent_child_state.capabilityHasManagedChildMarker(alloc, &source_children)) {
            return error.SessionNotFound;
        }

        const source_id = try alloc.dupe(u8, recovered.id);
        errdefer alloc.free(source_id);
        const recovered_id = try generateSessionId(alloc);
        errdefer alloc.free(recovered_id);
        const replacement_id = try alloc.dupe(u8, recovered_id);
        alloc.free(recovered.id);
        recovered.id = replacement_id;

        var initial = try recovered.dupe(alloc);
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

        if (recovered.usage == null) {
            if (target.state.usage) |usage| {
                // Keep the normal new-session default when optional usage is absent.
                recovered.usage = try session_usage.dupeSnapshotOwned(alloc, usage);
            }
        }

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
        if (current_boundary) |boundary| {
            try session_log.copy_conversation_recovery_prefix(alloc, &source.dir, &target.log.dir, boundary);
            if (metadata.?.value.title) |title| _ = try target.renameConversation(alloc, title);
        }
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
        target.deinit(alloc);
        target_owned = false;

        var verified = self.loadReadOnly(alloc, recovered_id) catch |err| {
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
        if (!try session_log.durableStatesEqual(verified, recovered)) {
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

fn copyRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
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
            .interrupted => |*entry| &entry.execution,
        };
        for (execution.tool_steps) |*step| {
            for (step.tool_results) |*result| {
                if (result.tool_image_handle) |handle| {
                    try copyRecoveredManagedChild(
                        alloc,
                        source,
                        target,
                        .tool_results,
                        handle,
                        null,
                    );
                }
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
            ) catch |err| return recoveryArtifactReadError(err);
            defer reader.deinit();
            while (reader.nextByte() catch |err|
                return recoveryArtifactReadError(err)) |_|
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
        ) catch |err| return recoveryArtifactReadError(err);
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
        ) catch |err| return recoveryArtifactReadError(err);
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        hasher.update(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionRecoveryBoundaryInvalid;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn recoveryArtifactReadError(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound,
        error.InvalidReplayHeader,
        error.ReplaySizeMismatch,
        error.ReplayTooLarge,
        error.ReplayOffsetTooLarge,
        error.UnexpectedEndOfReplay,
        error.EndOfStream,
        error.TruncatedReplayFrame,
        error.InvalidReplayStream,
        error.EmptyReplayFrame,
        error.ReplayFrameTooLarge,
        error.Overflow,
        => error.SessionRecoveryBoundaryInvalid,
        else => err,
    };
}

test "recovery artifact errors distinguish damaged bytes from operational failures" {
    for ([_]anyerror{ error.FileNotFound, error.InvalidReplayHeader, error.ReplaySizeMismatch, error.ReplayTooLarge, error.ReplayOffsetTooLarge, error.UnexpectedEndOfReplay, error.EndOfStream, error.TruncatedReplayFrame, error.InvalidReplayStream, error.EmptyReplayFrame, error.ReplayFrameTooLarge, error.Overflow }) |err| {
        try std.testing.expectEqual(error.SessionRecoveryBoundaryInvalid, recoveryArtifactReadError(err));
    }
    for ([_]anyerror{ error.OutOfMemory, error.ReadFailed, error.AccessDenied, error.Canceled, error.Unseekable, error.Unexpected, error.SystemResources }) |err| {
        try std.testing.expectEqual(err, recoveryArtifactReadError(err));
    }
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
            .interrupted => |entry| entry.user.images,
        };
        const original_images = switch (original_turn) {
            .compacted_summary => &.{},
            .assistant => |entry| entry.user.images,
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
    const history = [_]session.HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("legacy summary"),
            .removed_turn_count = 2,
            .compaction_count = 1,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("recent request") },
            .assistant = @constCast("recent answer"),
        } },
    };
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
    for (0..count) |index| {
        const prompt = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ label, index });
        defer alloc.free(prompt);
        const turn = try session.makeAssistantTurn(alloc, prompt, "saved response");
        defer session.freeHistoryTurn(alloc, turn);
        _ = try writable.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = turn,
        } }, updated_at_ms + @as(i64, @intCast(index)));
    }
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
    for (history, 0..) |turn, index| {
        _ = try writable.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .work_id = if (session.historyTurnWorkId(turn)) |id_value|
                @constCast(id_value)
            else
                null,
            .turn = turn,
        } }, updated_at_ms + @as(i64, @intCast(index)));
    }
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

const LatestBarrierFailure = struct {
    injected_error: anyerror,
    completed_count: usize = 0,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *LatestBarrierFailure = @ptrCast(@alignCast(context.?));
        switch (boundary) {
            .latest_barrier_completed => {
                self.completed_count += 1;
                return self.injected_error;
            },
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

const ResumeInterleavingControl = struct {
    pause_on_session: bool = false,
    barrier_completed_count: std.atomic.Value(usize) = .init(0),
    session_opened: std.atomic.Value(bool) = .init(false),
    release_session: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn boundary(context: ?*anyopaque, point: session_log.Boundary) !void {
        const self: *ResumeInterleavingControl = @ptrCast(@alignCast(context.?));
        switch (point) {
            .latest_barrier_completed => _ = self.barrier_completed_count.fetchAdd(1, .seq_cst),
        }
    }

    fn lock(context: ?*anyopaque, kind: session_log.LockKind) void {
        const self: *ResumeInterleavingControl = @ptrCast(@alignCast(context.?));
        _ = kind;
        if (!self.pause_on_session) return;
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

test "store start does not publish session caches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "cache-free-store", ctx.workspace);
    defer state.deinit(alloc);

    var writable = try ctx.store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);

    var count: usize = 0;
    var iterator = ctx.store.canonical_root.sessions.?.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        try std.testing.expectEqualStrings("cache-free-store", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

const ranking_test_generation: session_event.Identifier = @splat(1);
const ranking_test_watermark = "commit.01010101010101010101010101010101.json";

fn writeRankingWatermark(alloc: Allocator, dir: *io_mod.VerifiedDir, id: []const u8, seq: u64, event_id: session_event.Identifier, bytes: u64) !void {
    const generation_hex = std.fmt.bytesToHex(ranking_test_generation, .lower);
    const event_hex = std.fmt.bytesToHex(event_id, .lower);
    const text = try std.json.Stringify.valueAlloc(alloc, .{
        .schema_version = @as(u32, 1),
        .session_id = id,
        .log_generation = @as([]const u8, &generation_hex),
        .through_seq = seq,
        .through_event_id = @as([]const u8, &event_hex),
        .through_event_log_bytes = bytes,
    }, .{});
    defer alloc.free(text);
    // Deliberately overwrite in place, so directory mtime cannot detect this change.
    var file = try dir.dir.createFile(std.testing.io, ranking_test_watermark, .{ .permissions = .fromMode(0o600) });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, text);
}

fn writeRankingFixture(alloc: Allocator, store: Store, id: []const u8, projected_workspace: []const u8, workspace: []const u8, updated_at_ms: i64) !void {
    try makeSessionDir(alloc, store, id);
    var dir = try store.openSessionDir(id);
    defer dir.close();
    try dir.dir.setPermissions(std.testing.io, .fromMode(0o700));
    const preferences = session_codec.DurableSessionPreferences{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false };
    const first = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = ranking_test_generation,
        .seq = 1,
        .event_id = @splat(2),
        .timestamp_ms = 10,
        .event = .{ .session_started = .{
            .id = @constCast(id),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast(projected_workspace),
            .workspace_root = @constCast(projected_workspace),
            .conversation_language = .literal("en"),
            .preferences = preferences,
        } },
    });
    defer alloc.free(first);
    const second = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = ranking_test_generation,
        .seq = 2,
        .event_id = @splat(3),
        .timestamp_ms = updated_at_ms,
        .event = if (std.mem.eql(u8, projected_workspace, workspace)) .{ .preferences_changed = .{ .fast_mode = true } } else .{ .workspace_rebound = .{ .previous_workspace_root = @constCast(projected_workspace), .workspace_root = @constCast(workspace) } },
    });
    defer alloc.free(second);
    var events = try dir.dir.createFile(std.testing.io, "events.jsonl", .{ .permissions = .fromMode(0o600) });
    defer events.close(std.testing.io);
    try events.writeStreamingAll(std.testing.io, first);
    try events.writeStreamingAll(std.testing.io, second);
    try writeRankingWatermark(alloc, &dir, id, 2, @splat(3), first.len + second.len);
    const authority_id: session_event.Identifier = @splat(4);
    const authority_hex = std.fmt.bytesToHex(authority_id, .lower);
    const marker = try std.json.Stringify.valueAlloc(alloc, .{ .schema_version = @as(u32, 1), .storage_format = "event_log_v1", .session_id = id, .authority_id = @as([]const u8, &authority_hex), .source = "native_create" }, .{});
    defer alloc.free(marker);
    try io_mod.durableReplaceVerified(alloc, &dir, "authority.json", marker);
    const manifest = try session_projection.encodeManifest(alloc, .{
        .id = @constCast(id),
        .authority_id = authority_id,
        .log_generation = ranking_test_generation,
        .created_at_ms = 10,
        .updated_at_ms = 10,
        .origin_workspace_root = @constCast(projected_workspace),
        .workspace_root = @constCast(projected_workspace),
        .conversation_language = .literal("en"),
        .history_len = 0,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .last_event_seq = 1,
        .event_log_bytes = first.len,
        .event_log_stat_fingerprint = @splat(0),
        .generation_base_seq = 1,
        .generation_base_bytes = first.len,
        .checkpoint_seq = null,
        .checkpoint_sha256 = null,
        .preferences = preferences,
    });
    defer alloc.free(manifest);
    try io_mod.durableReplaceVerified(alloc, &dir, "session.json", manifest);
}

fn expectRankingSelection(store: Store, workspace: []const u8, expected: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    const selected = try store.selectWritableLastId(alloc, workspace, .{});
    defer if (selected) |id| alloc.free(id);
    if (expected) |id| try std.testing.expectEqualStrings(id, selected.?) else try std.testing.expect(selected == null);
}

test "legacy ranking cache cold warm empty ties rebind and selected admission remain identical" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeRankingFixture(alloc, ctx.store, "rank-a", "/old-workspace", ctx.workspace, 20);
    try writeRankingFixture(alloc, ctx.store, "rank-b", "/old-workspace", ctx.workspace, 20);
    {
        var legacy = try ctx.store.openSessionDir("rank-a");
        defer legacy.close();
        var name_buffer: [64]u8 = undefined;
        for (0..129) |index| {
            const name = try std.fmt.bufPrint(&name_buffer, "commit.{x:0>32}.json", .{index});
            var obsolete = try legacy.dir.createFile(std.testing.io, name, .{ .permissions = .fromMode(0o600) });
            defer obsolete.close(std.testing.io);
            try obsolete.writeStreamingAll(std.testing.io, "obsolete malformed watermark");
        }
    }
    const trace_path = try std.fs.path.join(alloc, &.{ ctx.home, "ranking-trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "session");
    defer debug_trace.resetForTest();
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-b");
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-b");
    try expectRankingSelection(ctx.store, "/old-workspace", null);
    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "legacy ranking cache reused=0 refreshed=2") != null);
    try std.testing.expect(std.mem.find(u8, trace, "legacy ranking cache reused=2 refreshed=0") != null);
    var cache = try catalog_cache.Loaded.load(alloc, ctx.store.canonical_root.sessions, null);
    defer cache.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), cache.rankingCount());
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    {
        var picker_state = try testDurableState(alloc, "rank-picker", "/picker-workspace");
        defer picker_state.deinit(alloc);
        picker_state.history = blk: {
            const history = try alloc.alloc(session.HistoryTurn, 1);
            errdefer alloc.free(history);
            history[0] = try session.makeAssistantTurn(alloc, "saved question", "saved answer");
            break :blk history;
        };
        var started = try ctx.store.startWritableSession(alloc, picker_state);
        started.deinit(alloc);
        var writer = (try catalog_cache.Writer.init(ctx.store)).?;
        defer writer.deinit();
        var picker = try @import("../subagent/resume_admission.zig").listActionableCatalog(ctx.store, alloc, null, null, &writer);
        defer picker.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), picker.summaries.items.len);
        try std.testing.expectEqualStrings("rank-picker", picker.summaries.items[0].id);
        var preserved = try catalog_cache.Loaded.load(alloc, ctx.store.canonical_root.sessions, null);
        defer preserved.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), preserved.rankingCount());
        try std.testing.expectEqual(@as(usize, 1), preserved.count());
        try expectRankingSelection(ctx.store, ctx.workspace, "rank-b");
    }
    var dir = try ctx.store.openSessionDir("rank-b");
    defer dir.close();
    {
        var lock = try io_mod.acquireTimedAdvisoryLock(&dir, "session.lock", 0);
        defer lock.release();
        try std.testing.expectError(error.SessionBusy, ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{ .log = .{ .session_lock_deadline_ms = 0 } }));
    }
    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("rank-b", resumed.active_id);
    try std.testing.expectEqualStrings(ctx.workspace, resumed.state.workspace_root);
    try std.testing.expectEqual(@as(usize, 0), resumed.state.history.len);
}

test "legacy ranking cache read only cold warm never writes and corruption rebuilds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeRankingFixture(alloc, ctx.store, "rank-readonly", ctx.workspace, ctx.workspace, 20);
    var readonly = try Store.initReadOnlyFromHome(alloc, ctx.home, ctx.workspace);
    defer readonly.deinit(alloc);
    try std.testing.expect((try catalog_cache.Writer.init(readonly)) == null);
    try expectRankingSelection(readonly, ctx.workspace, "rank-readonly");
    const root = ctx.store.canonical_root.sessions.?;
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(std.testing.io, ".resume-catalog", .{}));
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-readonly");
    const before = try root.dir.statFile(std.testing.io, ".resume-catalog", .{});
    try expectRankingSelection(readonly, ctx.workspace, "rank-readonly");
    const after = try root.dir.statFile(std.testing.io, ".resume-catalog", .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.mtime, after.mtime);
    try std.testing.expectEqual(before.ctime, after.ctime);
    var cache_dir = root;
    try io_mod.durableReplaceVerified(alloc, &cache_dir, ".resume-catalog", "invalid");
    try expectRankingSelection(readonly, ctx.workspace, "rank-readonly");
    var invalid = try catalog_cache.Loaded.load(alloc, root, null);
    defer invalid.deinit(alloc);
    try std.testing.expect(!invalid.present());
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-readonly");
    var rebuilt = try catalog_cache.Loaded.load(alloc, root, null);
    defer rebuilt.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.rankingCount());
    var session_dir = try ctx.store.openSessionDir("rank-readonly");
    defer session_dir.close();
    try io_mod.durableReplaceVerified(alloc, &session_dir, ranking_test_watermark, "{}");
    try std.testing.expectError(error.InvalidSessionFormat, readonly.selectWritableLastId(alloc, ctx.workspace, .{}));
    try root.dir.deleteFile(std.testing.io, ".resume-catalog");
    try std.testing.expectError(error.InvalidSessionFormat, readonly.selectWritableLastId(alloc, ctx.workspace, .{}));
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(std.testing.io, ".resume-catalog", .{}));
}

test "legacy ranking cache watermark-only commit revalidates workspace and ordering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeRankingFixture(alloc, ctx.store, "rank-watermark", ctx.workspace, ctx.workspace, 20);
    var dir = try ctx.store.openSessionDir("rank-watermark");
    defer dir.close();
    const next = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = ranking_test_generation,
        .seq = 3,
        .event_id = @splat(5),
        .timestamp_ms = 40,
        .event = .{ .workspace_rebound = .{ .previous_workspace_root = ctx.workspace, .workspace_root = @constCast("/rebound") } },
    });
    defer alloc.free(next);
    var events = try dir.dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
    defer events.close(std.testing.io);
    const bytes = (try events.stat(std.testing.io)).size;
    try events.writePositionalAll(std.testing.io, next, bytes);
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-watermark");
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-watermark");
    const before = try events.stat(std.testing.io);
    try writeRankingWatermark(alloc, &dir, "rank-watermark", 3, @splat(5), bytes + next.len);
    try expectRankingSelection(ctx.store, ctx.workspace, null);
    try expectRankingSelection(ctx.store, "/rebound", "rank-watermark");
    try std.testing.expectEqual(before.mtime, (try events.stat(std.testing.io)).mtime);
    try std.testing.expectEqual(before.ctime, (try events.stat(std.testing.io)).ctime);
}

test "legacy ranking cache changed event generation selects and caches only the new watermark" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const id = "rank-generation";
    try writeRankingFixture(alloc, ctx.store, id, ctx.workspace, ctx.workspace, 20);
    try expectRankingSelection(ctx.store, ctx.workspace, id);
    const root = ctx.store.canonical_root.sessions.?;
    var old = try catalog_cache.Loaded.load(alloc, root, null);
    defer old.deinit(alloc);
    try std.testing.expectEqual(ranking_test_generation, old.rankingGeneration(id).?);
    var dir = try ctx.store.openSessionDir(id);
    defer dir.close();
    const generation: session_event.Identifier = @splat(6);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const first = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = generation,
        .timestamp_ms = 40,
        .event = .{ .session_started = .{
            .id = @constCast(id),
            .created_at_ms = 10,
            .origin_workspace_root = ctx.workspace,
            .workspace_root = @constCast("/new-generation"),
            .conversation_language = .literal("en"),
            .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
        } },
    });
    defer alloc.free(first);
    // Keep the old watermark and stale manifest; only the event generation decides.
    var events = try dir.dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
    defer events.close(std.testing.io);
    try events.writePositionalAll(std.testing.io, first, 0);
    try events.setLength(std.testing.io, first.len);
    const watermark = try std.json.Stringify.valueAlloc(alloc, .{
        .schema_version = @as(u32, 1),
        .session_id = id,
        .log_generation = @as([]const u8, &generation_hex),
        .through_seq = @as(u64, 1),
        .through_event_id = @as([]const u8, &generation_hex),
        .through_event_log_bytes = first.len,
    }, .{});
    defer alloc.free(watermark);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "commit.{s}.json", .{generation_hex});
    try io_mod.durableReplaceVerified(alloc, &dir, name, watermark);
    const changed = (try catalog_cache.rankingFingerprint(root.dir, id, ranking_test_generation)).?;
    try std.testing.expect((try old.reuseRanking(alloc, id, changed)) == null);
    try expectRankingSelection(ctx.store, ctx.workspace, null);
    try expectRankingSelection(ctx.store, "/new-generation", id);
    var refreshed = try catalog_cache.Loaded.load(alloc, root, null);
    defer refreshed.deinit(alloc);
    try std.testing.expectEqual(generation, refreshed.rankingGeneration(id).?);
    var scan = Store.RankingScan{ .cache = try catalog_cache.Loaded.load(alloc, root, null) };
    defer scan.deinit(alloc);
    var candidate = (try ctx.store.resolveWritableCandidate(alloc, id, "/new-generation", .{}, &scan)).?;
    defer candidate.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), scan.reused);
    try std.testing.expectEqual(@as(usize, 0), scan.refreshed);
    try std.testing.expectEqual(@as(i64, 40), candidate.updated_at_ms);
}

test "legacy ranking cache never caches foreign failed replay and failed scans never publish" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeRankingFixture(alloc, ctx.store, "rank-good", ctx.workspace, ctx.workspace, 20);
    try writeRankingFixture(alloc, ctx.store, "rank-broken", "/foreign", "/foreign", 40);
    var dir = try ctx.store.openSessionDir("rank-broken");
    defer dir.close();
    try io_mod.durableReplaceVerified(alloc, &dir, ranking_test_watermark, "{}");
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-good");
    var cached = try catalog_cache.Loaded.load(alloc, ctx.store.canonical_root.sessions, null);
    defer cached.deinit(alloc);
    const stamp = (try catalog_cache.rankingFingerprint(ctx.store.canonical_root.sessions.?.dir, "rank-broken", ranking_test_generation)).?;
    try std.testing.expect((try cached.reuseRanking(alloc, "rank-broken", stamp)) == null);
    const root = ctx.store.canonical_root.sessions.?.dir;
    const before = try root.statFile(std.testing.io, ".resume-catalog", .{});
    try std.testing.expectError(error.InvalidSessionFormat, ctx.store.selectWritableLastId(alloc, "/foreign", .{}));
    const after = try root.statFile(std.testing.io, ".resume-catalog", .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.mtime, after.mtime);
    try root.deleteFile(std.testing.io, ".resume-catalog");
    try std.testing.expectError(error.InvalidSessionFormat, ctx.store.selectWritableLastId(alloc, "/foreign", .{}));
    try std.testing.expectError(error.FileNotFound, root.statFile(std.testing.io, ".resume-catalog", .{}));
}

test "legacy ranking cache observations clean allocation failures and never publish truncated scans" {
    const alloc = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: Allocator) !void {
            var scan = Store.RankingScan{ .cache = .{} };
            defer scan.deinit(a);
            try scan.observe(a, @splat(1), "rank", "/workspace", 20, ranking_test_generation);
            try std.testing.expectEqual(@as(usize, 1), scan.rows.items.len);
        }
    }.check, .{});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var scan = Store.RankingScan{ .cache = .{}, .remaining_bytes = 0 };
    defer scan.deinit(alloc);
    try scan.observe(alloc, @splat(1), "rank", "/workspace", 20, ranking_test_generation);
    try std.testing.expect(!scan.publishable);
    scan.publish(ctx.store, alloc);
    try std.testing.expectError(error.FileNotFound, ctx.store.canonical_root.sessions.?.dir.statFile(std.testing.io, ".resume-catalog", .{}));
}

test "legacy ranking publication rejects route changes during priming" {
    const alloc = std.testing.allocator;
    const Mutation = enum { fence, unsupported_manifest, missing_manifest, bad_manifest, invalid_authority };
    for (std.enums.values(Mutation)) |mutation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var ctx = try initTempStore(alloc, &tmp);
        defer ctx.deinit(alloc);
        const id = "rank-priming";
        try writeRankingFixture(alloc, ctx.store, id, ctx.workspace, ctx.workspace, 20);
        var dir = try ctx.store.openSessionDir(id);
        defer dir.close();
        try std.testing.expectEqual(.schema_v3, try classifyAuthority(alloc, &dir, id));
        var initial = try classifySchemaV3Candidate(alloc, &dir, id);
        defer initial.deinit(alloc);
        try std.testing.expectEqual(.stale, initial.projection_state);

        // Reproduce the gap without a hook: mutate after initial classification
        // but before the first fingerprint, leaving replay's inputs unchanged.
        switch (mutation) {
            .fence => try io_mod.durableReplaceVerified(alloc, &dir, "authority.pending.json", "pending"),
            .unsupported_manifest => try io_mod.durableReplaceVerified(alloc, &dir, "session.json", "{\"schema_version\":99}"),
            .missing_manifest => try dir.dir.deleteFile(std.testing.io, "session.json"),
            .bad_manifest => try io_mod.durableReplaceVerified(alloc, &dir, "session.json", "{\"schema_version\":3}"),
            .invalid_authority => try io_mod.durableReplaceVerified(alloc, &dir, "authority.json", "{}"),
        }
        const root = ctx.store.canonical_root.sessions.?;
        const before = (try catalog_cache.rankingFingerprintForOpenSession(root.dir, id, dir.dir, ranking_test_generation)).?;
        var source = try loadSchemaV3ReadOnly(alloc, &dir, id);
        defer source.deinit(alloc);
        try std.testing.expectEqualStrings(id, source.state.id);
        try std.testing.expectEqual(@as(i64, 20), source.state.updated_at_ms);
        const after = (try catalog_cache.rankingFingerprintForOpenSession(root.dir, id, dir.dir, source.generation)).?;
        try std.testing.expectEqual(before, after);

        var scan = Store.RankingScan{ .cache = .{}, .refreshed = 1 };
        defer scan.deinit(alloc);
        if (ctx.store.rankingPublicationFingerprint(alloc, &dir, id, before, ranking_test_generation, source.generation)) |stamp| {
            try scan.observe(alloc, stamp, id, source.state.workspace_root, source.state.updated_at_ms, source.generation);
        }
        try std.testing.expectEqual(@as(usize, 0), scan.rows.items.len);
        scan.publish(ctx.store, alloc);
        var loaded = try catalog_cache.Loaded.load(alloc, root, null);
        defer loaded.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), loaded.rankingCount());
        try std.testing.expect((try loaded.reuseRanking(alloc, id, after)) == null);
        if (mutation == .missing_manifest or mutation == .bad_manifest) {
            // Stricter cache eligibility must not exclude recoverable sessions.
            try expectRankingSelection(ctx.store, ctx.workspace, id);
            try expectRankingSelection(ctx.store, ctx.workspace, id);
            var uncached = try catalog_cache.Loaded.load(alloc, root, null);
            defer uncached.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 0), uncached.rankingCount());
        }
    }
}

test "legacy ranking early hits expose postpriming manifest and fence errors" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |fenced| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var ctx = try initTempStore(alloc, &tmp);
        defer ctx.deinit(alloc);
        const id = "rank-early-error";
        try writeRankingFixture(alloc, ctx.store, id, ctx.workspace, ctx.workspace, 20);
        var dir = try ctx.store.openSessionDir(id);
        defer dir.close();
        // This snapshot is irrelevant until the fence appears.
        if (fenced) try io_mod.durableReplaceVerified(alloc, &dir, "session.legacy.json", "{broken");
        try expectRankingSelection(ctx.store, ctx.workspace, id);
        const root = ctx.store.canonical_root.sessions.?;
        var primed = try catalog_cache.Loaded.load(alloc, root, null);
        defer primed.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), primed.rankingCount());
        const cache_stat = try root.dir.statFile(std.testing.io, ".resume-catalog", .{});
        if (fenced) {
            try io_mod.durableReplaceVerified(alloc, &dir, "authority.pending.json", "pending");
        } else {
            try io_mod.durableReplaceVerified(alloc, &dir, "session.json", "{\"schema_version\":99}");
        }
        const cached_error = blk: {
            const selected = ctx.store.selectWritableLastId(alloc, ctx.workspace, .{}) catch |err| break :blk err;
            if (selected) |value| alloc.free(value);
            return error.TestExpectedError;
        };
        const retained = try root.dir.statFile(std.testing.io, ".resume-catalog", .{});
        try std.testing.expectEqual(cache_stat.inode, retained.inode);
        try std.testing.expectEqual(cache_stat.mtime, retained.mtime);
        try root.dir.deleteFile(std.testing.io, ".resume-catalog");
        try std.testing.expectError(cached_error, ctx.store.selectWritableLastId(alloc, ctx.workspace, .{}));
        try std.testing.expectError(error.FileNotFound, root.dir.statFile(std.testing.io, ".resume-catalog", .{}));
    }
}

test "legacy ranking publication rechecks are optional and source bound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const id = "rank-proof";
    try writeRankingFixture(alloc, ctx.store, id, ctx.workspace, ctx.workspace, 20);
    var dir = try ctx.store.openSessionDir(id);
    defer dir.close();
    const root = ctx.store.canonical_root.sessions.?;
    const before = (try catalog_cache.rankingFingerprint(root.dir, id, ranking_test_generation)).?;
    var source = try loadSchemaV3ReadOnly(alloc, &dir, id);
    defer source.deinit(alloc);
    try std.testing.expectEqual(before, ctx.store.rankingPublicationFingerprint(alloc, &dir, id, before, ranking_test_generation, source.generation).?);
    try std.testing.expect(ctx.store.rankingPublicationFingerprint(alloc, &dir, id, before, @splat(9), source.generation) == null);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect(ctx.store.rankingPublicationFingerprint(failing.allocator(), &dir, id, before, ranking_test_generation, source.generation) == null);
    try std.testing.expectEqual(@as(i64, 20), source.state.updated_at_ms);
    try expectRankingSelection(ctx.store, ctx.workspace, id);
    var manifest = try dir.dir.openFile(std.testing.io, "session.json", .{});
    defer manifest.close(std.testing.io);
    try manifest.setPermissions(std.testing.io, .fromMode(0o640));
    try std.testing.expect(ctx.store.rankingPublicationFingerprint(alloc, &dir, id, before, ranking_test_generation, source.generation) == null);
    var scan = Store.RankingScan{ .cache = try catalog_cache.Loaded.load(alloc, root, null) };
    defer scan.deinit(alloc);
    var candidate = (try ctx.store.resolveWritableCandidate(alloc, id, ctx.workspace, .{}, &scan)).?;
    defer candidate.deinit(alloc);
    try std.testing.expectEqualStrings(id, candidate.id);
    try std.testing.expectEqual(@as(usize, 0), scan.reused);
    try std.testing.expectEqual(@as(usize, 1), scan.refreshed);
}

test "legacy ranking publication excludes current projections and conversation metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const root = ctx.store.canonical_root.sessions.?;
    const id = "rank-current-projection";
    try writeRankingFixture(alloc, ctx.store, id, ctx.workspace, ctx.workspace, 20);
    var dir = try ctx.store.openSessionDir(id);
    defer dir.close();
    const bytes = (try authority_module.readOptionalSessionFile(alloc, &dir, "session.json", session_projection.manifest_max_bytes)).?;
    defer alloc.free(bytes);
    var manifest = try session_projection.decodeManifest(alloc, bytes);
    defer manifest.deinit(alloc);
    const stat = try authority_module.eventFileStat(&dir, "events.jsonl");
    manifest.event_log_bytes = stat.size;
    manifest.last_event_seq = 2;
    manifest.updated_at_ms = 20;
    manifest.event_log_stat_fingerprint = try session_projection.eventFileStatFingerprint(stat, stat.size);
    const encoded = try session_projection.encodeManifest(alloc, manifest);
    defer alloc.free(encoded);
    try io_mod.durableReplaceVerified(alloc, &dir, "session.json", encoded);
    const before = (try catalog_cache.rankingFingerprint(root.dir, id, ranking_test_generation)).?;
    var current = try classifySchemaV3Candidate(alloc, &dir, id);
    defer current.deinit(alloc);
    try std.testing.expectEqual(.current, current.projection_state);
    try std.testing.expect(ctx.store.rankingPublicationFingerprint(alloc, &dir, id, before, ranking_test_generation, ranking_test_generation) == null);

    var state = try testDurableState(alloc, "rank-current-format", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);
    writable.deinit(alloc);
    var conversation = try ctx.store.openSessionDir(state.id);
    defer conversation.close();
    const conversation_before = (try catalog_cache.rankingFingerprint(root.dir, state.id, ranking_test_generation)).?;
    try std.testing.expect(ctx.store.rankingPublicationFingerprint(alloc, &conversation, state.id, conversation_before, ranking_test_generation, ranking_test_generation) == null);
}

test "legacy ranking cache changed authority preserves errors and best effort publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeRankingFixture(alloc, ctx.store, "rank-authority", ctx.workspace, ctx.workspace, 20);
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-authority");
    var dir = try ctx.store.openSessionDir("rank-authority");
    defer dir.close();
    var authority = try dir.dir.openFile(std.testing.io, "authority.json", .{ .mode = .read_write });
    defer authority.close(std.testing.io);
    try authority.writePositionalAll(std.testing.io, "!", 0);
    try std.testing.expectError(error.InvalidSessionFormat, ctx.store.selectWritableLastId(alloc, ctx.workspace, .{}));
    const root = ctx.store.canonical_root.sessions.?.dir;
    try root.deleteFile(std.testing.io, ".resume-catalog");
    try std.testing.expectError(error.InvalidSessionFormat, ctx.store.selectWritableLastId(alloc, ctx.workspace, .{}));
    try writeRankingFixture(alloc, ctx.store, "rank-authority", ctx.workspace, ctx.workspace, 20);
    // A directory at the disposable cache path prevents publication, not selection.
    try root.createDir(std.testing.io, ".resume-catalog", .fromMode(0o700));
    try expectRankingSelection(ctx.store, ctx.workspace, "rank-authority");
}

test "resume last selects conversation metadata without cache files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var older = try testDurableState(alloc, "cache-free-older", ctx.workspace);
    defer older.deinit(alloc);
    older.updated_at_ms = 10;
    var newer = try testDurableState(alloc, "cache-free-newer", ctx.workspace);
    defer newer.deinit(alloc);
    newer.updated_at_ms = 20;
    {
        var writable = try ctx.store.startWritableSession(alloc, older);
        writable.deinit(alloc);
    }
    {
        var writable = try ctx.store.startWritableSession(alloc, newer);
        writable.deinit(alloc);
    }

    var resumed = try ctx.store.resumeTargetForWrite(
        alloc,
        .last,
        ctx.workspace,
        .{},
    );
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("cache-free-newer", resumed.active_id);
    try std.testing.expectError(
        error.FileNotFound,
        ctx.store.canonical_root.sessions.?.dir.statFile(
            std.testing.io,
            "latest",
            .{},
        ),
    );
}

test "conversation history pages remain complete after model compaction" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var state = try testDurableState(alloc, "cache-free-pages", ctx.workspace);
    defer state.deinit(alloc);
    {
        var writable = try ctx.store.startWritableSession(alloc, state);
        defer writable.deinit(alloc);
        const turns = [_]session.HistoryTurn{
            .{ .assistant = .{
                .user = .{ .text = @constCast("old question") },
                .assistant = @constCast("old answer"),
            } },
            .{ .compacted_summary = .{
                .summary = @constCast("<context_handoff>summary</context_handoff>"),
                .removed_turn_count = 1,
                .compaction_count = 1,
            } },
            .{ .assistant = .{
                .user = .{ .text = @constCast("new question") },
                .assistant = @constCast("new answer"),
            } },
        };
        for (turns, 0..) |turn, index| {
            _ = try writable.appendEvent(alloc, .{ .history_turn_committed = .{
                .conversation_language = .literal("en"),
                .total_input_tokens = @intCast(index + 1),
                .total_output_tokens = @intCast(index + 1),
                .turn = turn,
            } }, @intCast(20 + index));
        }
    }

    var newest = try ctx.store.loadHistoryPage(
        alloc,
        state.id,
        null,
        1,
    );
    defer newest.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), newest.history_len);
    try std.testing.expectEqual(@as(usize, 1), newest.turns.len);
    try std.testing.expectEqualStrings("new question", newest.turns[0].assistant.user.text);
    try std.testing.expect(newest.next_cursor != null);

    var older = try ctx.store.loadHistoryPage(
        alloc,
        state.id,
        newest.next_cursor,
        1,
    );
    defer older.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), older.turns.len);
    try std.testing.expectEqualStrings("old question", older.turns[0].assistant.user.text);
    try std.testing.expect(older.next_cursor == null);
}

test "writable legacy resume converts once to conversation storage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(
        alloc,
        ctx.store,
        "legacy-conversation-convert",
        ctx.workspace,
        20,
    );

    {
        var resumed = try ctx.store.resumeForWrite(
            alloc,
            "legacy-conversation-convert",
        );
        defer resumed.deinit(alloc);
    }
    var detail = try ctx.store.loadReadOnlyDetail(
        alloc,
        "legacy-conversation-convert",
        .{},
    );
    defer detail.deinit(alloc);
    try std.testing.expectEqual(StorageFormat.conversation, detail.storage_format);
    var session_dir = try ctx.store.openSessionDir("legacy-conversation-convert");
    defer session_dir.close();
    var metadata_file = try session_dir.dir.openFile(
        std.testing.io,
        "session.json",
        .{},
    );
    defer metadata_file.close(std.testing.io);
    const metadata_bytes = try io_mod.readFileToEnd(
        alloc,
        &metadata_file,
        session_codec.max_session_metadata_bytes,
    );
    defer alloc.free(metadata_bytes);
    var metadata = try session_codec.decodeSessionMetadata(alloc, metadata_bytes);
    defer metadata.deinit();
    try std.testing.expectEqual(
        session_codec.session_metadata_schema_version,
        metadata.value.schema_version,
    );
    try std.testing.expectError(
        error.FileNotFound,
        session_dir.dir.statFile(std.testing.io, "authority.json", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        session_dir.dir.statFile(std.testing.io, "checkpoint.json", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        session_dir.dir.statFile(std.testing.io, "session.legacy.json", .{}),
    );
}

test "legacy conversion externalizes available inline tool results" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    var calls = [_]core_types.ToolCall{.{
        .id = "legacy-call",
        .name = "read_file",
        .arguments_json = "{\"path\":\"legacy.txt\"}",
    }};
    var results = [_]core_types.PersistedToolResult{.{
        .tool_call_id = @constCast("legacy-call"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("legacy available bytes"),
        .output_bytes = 64,
        .stored_output_bytes = 22,
    }};
    var steps = [_]core_types.ToolExecutionStep{.{
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("read legacy") },
        .assistant = @constCast("read complete"),
        .execution = .{ .tool_steps = &steps },
    } }};
    const rendered = try session_json.renderSessionJson(
        alloc,
        "legacy-result-convert",
        10,
        20,
        .literal("en"),
        ctx.workspace,
        &history,
        .{},
    );
    defer alloc.free(rendered);
    const path = try writeSessionFixture(
        alloc,
        ctx.store,
        "legacy-result-convert",
        rendered,
    );
    alloc.free(path);

    {
        var resumed = try ctx.store.resumeForWrite(alloc, "legacy-result-convert");
        resumed.deinit(alloc);
    }
    var detail = try ctx.store.loadReadOnlyDetail(
        alloc,
        "legacy-result-convert",
        .{},
    );
    defer detail.deinit(alloc);
    const result = detail.state.history[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expect(result.output_handle != null);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("legacy available bytes", result.preview.?);
    var capability = try ctx.store.openChildCapabilityReadOnly(
        alloc,
        "legacy-result-convert",
    );
    defer capability.deinit();
    const stored = try result_store.readByRangeManaged(
        alloc,
        &capability,
        result.output_handle.?,
        0,
        64,
    );
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "legacy available bytes") != null);
}

test "discarding a pristine started conversation removes its directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "discard-pristine", ctx.workspace);
    defer state.deinit(alloc);
    var writable = try ctx.store.startWritableSession(alloc, state);

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
    );
    _ = try cleared.appendEvent(
        alloc,
        .{ .recovery_checkpoint_cleared = .{} },
        40,
    );
    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.discardPristineStartedSession(alloc, &cleared),
    );
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

    var committed_state = try testDurableState(alloc, "discard-committed", ctx.workspace);
    defer committed_state.deinit(alloc);
    var committed = try ctx.store.startWritableSession(alloc, committed_state);
    _ = try committed.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
    );
    try std.testing.expectEqual(
        PristineDiscardDisposition.retained,
        ctx.store.discardPristineStartedSession(alloc, &committed),
    );
    var committed_loaded = try ctx.store.loadReadOnly(alloc, committed_state.id);
    defer committed_loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), committed_loaded.history.len);
    try std.testing.expect(committed_loaded.preferences.fast_mode);
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

test "committed parent deletion removes exactly its marked direct child" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var parent_state = try testDurableState(alloc, "delete-parent", ctx.workspace);
    defer parent_state.deinit(alloc);
    var parent = try ctx.store.startWritableSession(alloc, parent_state);
    _ = try parent.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
    );

    var child_state = try testDurableState(alloc, "delete-child", ctx.workspace);
    defer child_state.deinit(alloc);
    var child = try ctx.store.startWritableSession(alloc, child_state);
    child.deinit(alloc);

    var parent_capability = try ctx.store.openSubagentControlCapabilityWritable(
        alloc,
        parent_state.id,
        .{},
    );
    defer parent_capability.deinit();
    var children_entry = try parent_capability.atomicReplace(
        alloc,
        .subagent_control,
        "children.json",
        "{\"schema_version\":1,\"parent_id\":\"delete-parent\",\"generation\":1,\"children\":[{\"id\":\"delete-child\"}]}",
    );
    children_entry.deinit(alloc);

    var child_capability = try ctx.store.openSubagentControlCapabilityWritable(
        alloc,
        child_state.id,
        .{},
    );
    defer child_capability.deinit();
    var owner_entry = try child_capability.atomicReplace(
        alloc,
        .subagent_control,
        "owner.json",
        "{\"schema_version\":1,\"parent_id\":\"delete-parent\"}",
    );
    owner_entry.deinit(alloc);

    try std.testing.expectEqual(
        PristineDiscardDisposition.discarded,
        ctx.store.deleteCommittedSession(alloc, &parent),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.loadReadOnly(alloc, parent_state.id),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        ctx.store.loadReadOnly(alloc, child_state.id),
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
    try std.testing.expect(std.fs.path.isAbsolute(
        resumed.state.history[1].assistant.user.images[0].snapshot_path.?,
    ));

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
        try std.testing.expectEqual(DoctorIssueKind.canonical_state_invalid, diagnostic.kind);
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

test "recovery command replay allocation failures propagate without changing source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source");
    try tmp.dir.createDirPath(std.testing.io, "target");
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "source");
    defer alloc.free(source_path);
    const target_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target");
    defer alloc.free(target_path);
    var source = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, source_path, .command_artifacts, .writable);
    defer source.deinit();
    var target = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, target_path, .command_artifacts, .writable);
    defer target.deinit();
    const capture = try command_replay_store.Capture.create(alloc, 1024, &source);
    defer alloc.destroy(capture);
    defer capture.discard(alloc);
    capture.appendAccepted(alloc, .stdout, "retained command bytes");
    const replay = capture.retain(alloc) orelse return error.TestExpectedReplay;
    try std.testing.expect(replay == .available);
    var source_file = try source.openFileReadOnly(alloc, .command_artifacts, replay.available.handle);
    defer source_file.deinit();
    const before = try managedFileDigest(&source_file, replay.available.framed_bytes);
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(test_alloc: Allocator, input: *session_child_store.SessionChildCapability, output: *session_child_store.SessionChildCapability, value: core_types.CommandOutputReplay) !void {
            // Each failure run starts from the same absent-target state.
            defer output.delete(.command_artifacts, value.available.handle) catch {};
            try std.testing.expect(!try copyRecoveredCommandReplay(test_alloc, input, output, value));
        }
    }.check, .{ &source, &target, replay });
    try std.testing.expectEqual(before, try managedFileDigest(&source_file, replay.available.framed_bytes));
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

test "recovery copies tool image artifacts and rejects changed content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source");
    try tmp.dir.createDirPath(std.testing.io, "target");
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "source");
    defer alloc.free(source_path);
    const target_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target");
    defer alloc.free(target_path);
    var source = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, source_path, .tool_results, .writable);
    defer source.deinit();
    var target = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, target_path, .tool_results, .writable);
    defer target.deinit();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
    const handle = try result_store.storeToolImages(alloc, &source, "screenshot", "mcp_browser", &.{.{
        .data = @constCast(png),
        .mime_type = @constCast("image/png"),
    }});
    defer alloc.free(handle);
    var results = [_]core_types.PersistedToolResult{.{
        .tool_call_id = @constCast("screenshot"),
        .tool_name = @constCast("mcp_browser"),
        .status = .success,
        .output = @constCast(""),
        .output_bytes = 0,
        .stored_output_bytes = 0,
        .tool_image_handle = handle,
    }};
    var steps = [_]core_types.ToolExecutionStep{.{ .tool_results = &results }};
    var history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("Take a screenshot.") },
        .assistant = @constCast("Captured."),
        .execution = .{ .tool_steps = &steps },
    } }};
    try std.testing.expect(!try copyRecoveredManagedChildren(alloc, &history, &source, &target));
    const copied = try result_store.loadToolImages(alloc, &target, handle);
    defer core_types.freeToolImages(alloc, copied);
    try std.testing.expectEqual(@as(usize, 1), copied.len);
    try std.testing.expectEqualStrings(png, copied[0].data);
    try std.testing.expect(!try copyRecoveredManagedChildren(alloc, &history, &source, &target));
    try target.delete(.tool_results, handle);
    var changed = try source.atomicReplace(alloc, .tool_results, handle, "[]");
    changed.deinit(alloc);
    try std.testing.expectError(error.SessionRecoveryBoundaryInvalid, copyRecoveredManagedChildren(alloc, &history, &source, &target));
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

test "classifies conversation and legacy candidates" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);

    var state = try testDurableState(alloc, "conversation", ctx.workspace);
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
    var saw_conversation = false;
    var saw_legacy = false;
    for (summaries.items) |summary| {
        if (std.mem.eql(u8, summary.id, "conversation")) saw_conversation = true;
        if (std.mem.eql(u8, summary.id, "legacy.v2")) saw_legacy = true;
    }
    try std.testing.expect(saw_conversation);
    try std.testing.expect(saw_legacy);

    var conversation_dir = try ctx.store.openSessionDir("conversation");
    defer conversation_dir.close();
    var conversation_candidate = try classifyReadOnlyCandidate(
        alloc,
        &conversation_dir,
        "conversation",
    );
    defer conversation_candidate.deinit(alloc);
    try std.testing.expectEqual(
        CandidateStorage.conversation,
        conversation_candidate.storage,
    );

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

test "writable last skips only unpublished lock directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "local", ctx.workspace, 1, "saved");
    try ctx.store.canonical_root.sessions.?.dir.createDir(std.testing.io, "empty", .fromMode(0o700));
    try ctx.store.canonical_root.sessions.?.dir.createDir(std.testing.io, "lock-only", .fromMode(0o700));
    try writeFixtureEntry(alloc, ctx.store, "lock-only", "session.lock", "");
    {
        var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqualStrings("local", resumed.active_id);
    }
    try writeFixtureEntry(alloc, ctx.store, "lock-only", "events.jsonl", "unidentified saved data\n");
    try std.testing.expectError(error.FileNotFound, ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{}));
    const retained = try readFixtureFile(alloc, ctx.store, "lock-only", "events.jsonl", 1024);
    defer alloc.free(retained);
    try std.testing.expectEqualStrings("unidentified saved data\n", retained);
}

test "writable last skips retained incomplete creation without weakening saved-data checks" {
    const alloc = std.testing.allocator;
    for ([_]struct { metadata: bool, temporary: bool }{
        .{ .metadata = false, .temporary = true },
        .{ .metadata = true, .temporary = false },
        .{ .metadata = true, .temporary = true },
    }) |shape| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var ctx = try initTempStore(alloc, &tmp);
        defer ctx.deinit(alloc);
        try createHistoryPageFixture(alloc, ctx.store, "healthy", ctx.workspace, 1, "saved");
        try ctx.store.canonical_root.sessions.?.dir.createDir(std.testing.io, "failed-start", .fromMode(0o700));
        var incomplete_dir = try ctx.store.openSessionDir("failed-start");
        defer incomplete_dir.close();
        const lock_file = try incomplete_dir.dir.createFile(std.testing.io, "session.lock", .{ .permissions = .fromMode(0o600) });
        lock_file.close(std.testing.io);
        const temp_name = ".session.json.tmp.0123456789abcdef0123456789abcdef";
        if (shape.temporary) try writeFixtureEntry(alloc, ctx.store, "failed-start", temp_name, "partial metadata");
        if (shape.metadata) {
            var healthy_dir = try ctx.store.openSessionDir("healthy");
            defer healthy_dir.close();
            var decoded = (try session_log.readConversationMetadata(alloc, &healthy_dir)).?;
            defer decoded.deinit();
            var metadata = decoded.value;
            metadata.id = "failed-start";
            const bytes = try session_codec.encodeSessionMetadata(alloc, metadata);
            defer alloc.free(bytes);
            try writeFixtureEntry(alloc, ctx.store, "failed-start", "session.json", bytes);
        }
        const retained_name = if (shape.metadata) "session.json" else temp_name;
        const before = try readFixtureFile(alloc, ctx.store, "failed-start", retained_name, 4096);
        defer alloc.free(before);
        {
            var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
            defer resumed.deinit(alloc);
            try std.testing.expectEqualStrings("healthy", resumed.active_id);
            try std.testing.expectEqualStrings("saved-0", resumed.state.history[0].assistant.user.text);
        }
        const retained = try readFixtureFile(alloc, ctx.store, "failed-start", retained_name, 4096);
        defer alloc.free(retained);
        try std.testing.expectEqualStrings(before, retained);
        if (ctx.store.resumeForWrite(alloc, "failed-start")) |value| {
            var loaded = value;
            loaded.deinit(alloc);
            return error.IncompleteSessionWasResumed;
        } else |err| try std.testing.expect(err == error.FileNotFound or err == error.SessionNotFound);
        try writeFixtureEntry(alloc, ctx.store, "failed-start", "permissions.json", "{}");
        try std.testing.expectError(error.FileNotFound, ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{}));
        const controls = try readFixtureFile(alloc, ctx.store, "failed-start", "permissions.json", 1024);
        defer alloc.free(controls);
        try std.testing.expectEqualStrings("{}", controls);
    }
}

test "writable last ignores unrelated conversation history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "local", ctx.workspace, 1, "local-turn");
    var foreign_state = try testDurableState(alloc, "foreign", "/foreign-workspace");
    defer foreign_state.deinit(alloc);
    var foreign = try ctx.store.startWritableSession(alloc, foreign_state);
    foreign.deinit(alloc);
    var foreign_dir = try ctx.store.openSessionDir("foreign");
    defer foreign_dir.close();
    var metadata = (try session_log.readConversationMetadata(alloc, &foreign_dir)).?;
    defer metadata.deinit();
    try std.testing.expectEqualStrings("/foreign-workspace", metadata.value.workspace_root);
    try writeFixtureEntry(alloc, ctx.store, "foreign", "events.jsonl", "unreadable foreign history\n");

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("local", resumed.active_id);
    try std.testing.expectEqualStrings("local-turn-0", resumed.state.history[0].assistant.user.text);
    const unchanged = try readFixtureFile(alloc, ctx.store, "foreign", "events.jsonl", 1024);
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings("unreadable foreign history\n", unchanged);
}

test "writable last ignores an unrelated legacy authority fence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "local", ctx.workspace, 10);
    try writeLegacyFixture(alloc, ctx.store, "foreign-fenced", "/foreign-workspace", 20);
    try writeFixtureEntry(alloc, ctx.store, "foreign-fenced", "authority.pending.json", "pending");

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("local", resumed.active_id);
    const unchanged = try readFixtureFile(alloc, ctx.store, "foreign-fenced", "authority.pending.json", 1024);
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings("pending", unchanged);
}

test "writable last reaches selected legacy authority recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try writeLegacyFixture(alloc, ctx.store, "older", ctx.workspace, 10);
    try writeLegacyFixture(alloc, ctx.store, "recover-latest", ctx.workspace, 20);
    const stable = try readFixtureFile(alloc, ctx.store, "recover-latest", "session.json", 4096);
    defer alloc.free(stable);
    try writeFixtureEntry(alloc, ctx.store, "recover-latest", "session.legacy.json", stable);
    try writeFixtureEntry(alloc, ctx.store, "recover-latest", "authority.pending.json", "pending");
    try writeFixtureEntry(alloc, ctx.store, "recover-latest", "session.json", "interrupted replacement");

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("recover-latest", resumed.active_id);
    var dir = try ctx.store.openSessionDir("recover-latest");
    defer dir.close();
    try requireAuthorityFenceAbsent(alloc, &dir, "recover-latest");
}

test "writable last only inspects the history needed for ranking" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(alloc, ctx.store, "older-prefix", ctx.workspace, 1, "older");
    const prefix = try readFixtureFile(alloc, ctx.store, "older-prefix", "events.jsonl", 64 * 1024);
    defer alloc.free(prefix);
    const with_suffix = try std.mem.concat(alloc, u8, &.{ prefix, "unreadable suffix\n" });
    defer alloc.free(with_suffix);
    try writeFixtureEntry(alloc, ctx.store, "older-prefix", "events.jsonl", with_suffix);
    var selected = try testDurableState(alloc, "newest", ctx.workspace);
    defer selected.deinit(alloc);
    selected.updated_at_ms = std.math.maxInt(i64);
    var writable = try ctx.store.startWritableSession(alloc, selected);
    writable.deinit(alloc);

    var resumed = try ctx.store.resumeTargetForWrite(alloc, .last, ctx.workspace, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("newest", resumed.active_id);
    const unchanged = try readFixtureFile(alloc, ctx.store, "older-prefix", "events.jsonl", 64 * 1024);
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings(with_suffix, unchanged);
}

test "writable last preserves conversation recency and allocation cleanup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    const user = "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":20,\"event\":{\"user\":{\"text\":\"unfinished\"}}}\n";
    const checkpoint = "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":21,\"event\":{\"context_checkpoint\":{\"covers_through_seq\":1,\"summary\":\"saved context\"}}}\n";
    for ([_][]const u8{ "empty", "unfinished", "completed", "checkpoint" }) |id| {
        try createHistoryPageFixture(alloc, ctx.store, id, ctx.workspace, if (std.mem.eql(u8, id, "completed")) 1 else 0, "turn");
        if (std.mem.eql(u8, id, "unfinished")) try writeFixtureEntry(alloc, ctx.store, id, "events.jsonl", user);
        if (std.mem.eql(u8, id, "checkpoint")) try writeFixtureEntry(alloc, ctx.store, id, "events.jsonl", user ++ checkpoint);
        var dir = try ctx.store.openSessionDir(id);
        defer dir.close();
        var reference = try classifyReadOnlyCandidate(alloc, &dir, id);
        defer reference.deinit(alloc);
        var scan = Store.RankingScan{ .cache = .{} };
        defer scan.deinit(alloc);
        var candidate = (try ctx.store.resolveWritableCandidate(alloc, id, ctx.workspace, .{}, &scan)).?;
        defer candidate.deinit(alloc);
        try std.testing.expectEqual(reference.summary.updated_at_ms, candidate.updated_at_ms);
        try std.testing.expectEqualStrings(reference.summary.workspace_root.?, candidate.workspace_root);
        var metadata = (try session_log.readConversationMetadata(alloc, &dir)).?;
        defer metadata.deinit();
        try std.testing.checkAllAllocationFailures(alloc, struct {
            fn check(a: Allocator, d: *io_mod.VerifiedDir, m: session_codec.SessionMetadata) !void {
                var value = try discovery.writable_conversation_candidate(a, d, m.id, m, m.workspace_root);
                defer value.deinit(a);
            }
        }.check, .{ &dir, metadata.value });
    }
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
        if (std.mem.eql(u8, entry.name, retired_latest_sessions_dir)) saw_latest = true;
    }
    try std.testing.expect(saw_session);
    try std.testing.expect(!saw_latest);
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

test "explicit conversation resume rebinds workspace" {
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
    var detail = try ctx.store.loadReadOnlyDetail(alloc, "legacy-migrate", .{});
    defer detail.deinit(alloc);
    try std.testing.expectEqual(StorageFormat.conversation, detail.storage_format);
}

test "writable legacy resume preserves summary tail and incomplete authority through migration and reload" {
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
        try std.testing.expectEqual(@as(usize, 2), resumed.state.history.len);
        try std.testing.expectEqualStrings("legacy summary", resumed.state.history[0].compacted_summary.summary);
        try std.testing.expectEqualStrings("recent request", resumed.state.history[1].assistant.user.text);
        try std.testing.expectEqualStrings("recent answer", resumed.state.history[1].assistant.assistant);
        try std.testing.expect(
            !resumed.state.history[0].compacted_summary.root_user_messages_complete,
        );
        try std.testing.expect(
            !resumed.state.history[0].compacted_summary.permission_feedback_complete,
        );
    }

    var reloaded = try ctx.store.loadReadOnly(alloc, session_id);
    defer reloaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), reloaded.history.len);
    try std.testing.expectEqualStrings("legacy summary", reloaded.history[0].compacted_summary.summary);
    try std.testing.expectEqualStrings("recent request", reloaded.history[1].assistant.user.text);
    try std.testing.expectEqualStrings("recent answer", reloaded.history[1].assistant.assistant);
    try std.testing.expect(
        !reloaded.history[0].compacted_summary.root_user_messages_complete,
    );
    try std.testing.expect(
        !reloaded.history[0].compacted_summary.permission_feedback_complete,
    );
}

test "legacy resume honors the single writer lock deadline" {
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
            } },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - session_started_at_ms < 1000);
    session_lock.release();
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

test "migration result reports captured source metadata" {
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

    var result = try ctx.store.migrateLegacyStorageOnly(
        alloc,
        "legacy-large-result",
        .{},
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

    const cache_path = try std.fs.path.join(alloc, &.{ ctx.store.sessions_dir, "list.json" });
    defer alloc.free(cache_path);
    try writeRawFile(
        cache_path,
        "{\"kind\":\"sessions\",\"count\":1,\"sessions\":[{\"id\":\"ghost-session\",\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":0,\"conversation_language\":\"en\"}]}",
    );

    var summaries = try ctx.store.list(alloc);
    defer freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 0), summaries.items.len);
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
    const newest_snapshot = try parseConversationHistoryPageCursor(newest_cursor);
    try std.testing.expectEqual(@as(usize, 5), newest.history_len);

    var middle = try ctx.store.loadHistoryPage(alloc, "history-pages", newest_cursor, 2);
    defer middle.deinit(alloc);
    try expectHistoryPagePrompts(middle, &.{ "turn-1", "turn-2" });
    try std.testing.expectEqual(newest.revision_ms, middle.revision_ms);
    try std.testing.expectEqual(newest.history_len, middle.history_len);
    const middle_cursor = middle.next_cursor orelse return error.TestExpectedEqual;
    const middle_snapshot = try parseConversationHistoryPageCursor(middle_cursor);
    try std.testing.expectEqualSlices(u8, newest_snapshot.session_id, middle_snapshot.session_id);
    try std.testing.expectEqual(newest_snapshot.history_len, middle_snapshot.history_len);

    var oldest = try ctx.store.loadHistoryPage(alloc, "history-pages", middle_cursor, 2);
    defer oldest.deinit(alloc);
    try expectHistoryPagePrompts(oldest, &.{"turn-0"});
    try std.testing.expect(oldest.next_cursor == null);
}

test "conversation history cursor remains stable across append" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(alloc, &tmp);
    defer ctx.deinit(alloc);
    try createHistoryPageFixture(
        alloc,
        ctx.store,
        "history-append-stable",
        ctx.workspace,
        4,
        "base",
    );
    var initial = try ctx.store.loadHistoryPage(
        alloc,
        "history-append-stable",
        null,
        2,
    );
    defer initial.deinit(alloc);
    const cursor = initial.next_cursor.?;
    {
        var writable = try ctx.store.resumeForWrite(alloc, "history-append-stable");
        defer writable.deinit(alloc);
        const turn = try session.makeAssistantTurn(alloc, "later", "saved response");
        defer session.freeHistoryTurn(alloc, turn);
        _ = try writable.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = turn,
        } }, 30);
    }
    var older = try ctx.store.loadHistoryPage(
        alloc,
        "history-append-stable",
        cursor,
        2,
    );
    defer older.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), older.history_len);
    try expectHistoryPagePrompts(older, &.{ "base-0", "base-1" });
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
    try replaceHistoryPageTurnsFixture(
        alloc,
        ctx.store,
        "history-provenance-pages",
        20,
        history,
    );

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
    var writable_owned = true;
    defer if (writable_owned) writable.deinit(alloc);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
    );
    writable.deinit(alloc);
    writable_owned = false;

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

    const direct_turn = try session.makeAssistantTurn(
        alloc,
        "direct human resume",
        "direct reply",
    );
    defer session.freeHistoryTurn(alloc, direct_turn);
    {
        var direct = try ctx.store.resumeForWrite(alloc, "history-provenance-pages");
        defer direct.deinit(alloc);
        _ = try direct.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = .literal("en"),
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .turn = direct_turn,
            } },
            40,
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
        .output_handle = @constCast("result-call-1.txt"),
        .preview = @constCast("tool output"),
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
        .{ .assistant = .{
            .user = .{ .text = @constCast("background") },
            .assistant = @constCast("historical command"),
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
    try std.testing.expectEqual(@as(usize, 3), first.turns.len);
    try std.testing.expectEqualStrings("tool output", first.turns[0].assistant.execution.tool_steps[0].tool_results[0].output);
    try std.testing.expectEqualStrings("historical command", first.turns[1].assistant.assistant);
    try std.testing.expectEqualStrings("partial", first.turns[2].interrupted.assistant.?);
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

test "conversation visitation releases turns on consumer and allocation failure" {
    const backing = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try initTempStore(backing, &tmp);
    defer ctx.deinit(backing);
    try createHistoryPageFixture(backing, ctx.store, "streamed-history", ctx.workspace, 3, "stream");
    const Visitor = struct {
        tracking: *std.testing.FailingAllocator,
        count: usize = 0,
        retained_bytes: ?usize = null,
        reject: bool = false,

        pub fn append(self: *@This(), turn: session.HistoryTurn) !void {
            if (self.reject) return error.ConsumerFailed;
            const expected = [_][]const u8{ "stream-0", "stream-1", "stream-2" };
            try std.testing.expect(self.count < expected.len);
            try std.testing.expect(turn == .assistant);
            try std.testing.expectEqualStrings(expected[self.count], turn.assistant.user.text);
            const retained = self.tracking.allocated_bytes - self.tracking.freed_bytes;
            if (self.retained_bytes) |first| {
                try std.testing.expectEqual(first, retained);
            } else {
                self.retained_bytes = retained;
            }
            self.count += 1;
        }
    };

    var probe = std.testing.FailingAllocator.init(backing, .{});
    var visitor = Visitor{ .tracking = &probe };
    try ctx.store.visitConversationHistory(probe.allocator(), "streamed-history", &visitor);
    try std.testing.expectEqual(@as(usize, 3), visitor.count);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    var rejected = std.testing.FailingAllocator.init(backing, .{});
    var rejecting = Visitor{ .tracking = &rejected, .reject = true };
    try std.testing.expectError(error.ConsumerFailed, ctx.store.visitConversationHistory(
        rejected.allocator(),
        "streamed-history",
        &rejecting,
    ));
    try std.testing.expectEqual(rejected.allocated_bytes, rejected.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var partial = Visitor{ .tracking = &failing };
        try std.testing.expectError(error.OutOfMemory, ctx.store.visitConversationHistory(
            failing.allocator(),
            "streamed-history",
            &partial,
        ));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
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

const std = @import("std");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");

const Allocator = std.mem.Allocator;

/// Upper bound on a single legacy `session.json` read in the non-`allow_large`
/// path. Larger snapshots are rejected with `error.LegacySessionTooLarge`.
pub const max_session_bytes: usize = 512 * 1024;

/// Default ceiling for an automatic (non-opt-in) legacy snapshot. Snapshots
/// above this are surfaced by `doctor` and refused by automatic migration.
pub const automatic_legacy_max_bytes: u64 = 256 * 1024 * 1024;

/// On-disk storage format a readable session was found in.
pub const StorageFormat = enum {
    schema_v3,
    legacy_v1,
    legacy_v2,
};

/// Storage format of a discovery candidate (kept distinct from `StorageFormat`
/// so discovery and read APIs can evolve independently).
pub const CandidateStorage = enum {
    schema_v3,
    legacy_v1,
    legacy_v2,
};

/// Freshness of a session's cached projection relative to its event log.
pub const ProjectionState = enum {
    current,
    stale,
    missing,
    invalid,
};

/// Why a candidate was retained, excluded, or selected during discovery. Used
/// only for structured tracing.
pub const DiscoveryCause = enum {
    listable,
    empty_session,
    workspace_mismatch,
    authority_transition,
    missing_authority,
    invalid_authority,
    missing_manifest,
    invalid_manifest,
    unsupported_schema,
    legacy_too_large,
    unsafe_path,
};

/// Lightweight session metadata returned by `Store.list`. Owns its string
/// fields; the caller frees with `deinit`.
pub const SessionSummary = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    origin_workspace_root: ?[]u8 = null,
    title: ?[]u8 = null,
    preview: ?[]u8 = null,
    display_metadata_present: bool = false,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history_len: usize,
    /// True when the canonical log contains an event after `session_started`.
    /// This distinguishes a genuinely pristine zero-turn entry from a valid
    /// session whose durable activity has not produced chat history yet.
    has_durable_activity: bool = false,
    has_managed_children: bool = false,

    /// Frees owned summary strings and poisons the value.
    pub fn deinit(self: *SessionSummary, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.workspace_root) |wr| alloc.free(wr);
        if (self.origin_workspace_root) |wr| alloc.free(wr);
        if (self.title) |title| alloc.free(title);
        if (self.preview) |preview| alloc.free(preview);
        self.* = undefined;
    }
};

pub const ResumableSessionContinuation = struct {
    updated_at_ms: i64,
    id: []const u8,
};

pub const ResumableSessionPage = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    has_more: bool = false,

    pub fn deinit(self: *ResumableSessionPage, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        self.* = undefined;
    }
};

pub const SessionListScope = enum {
    current_workspace,
    all_workspaces,
};

pub const SessionListPage = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    has_more: bool = false,
    skipped_invalid: usize = 0,

    pub fn deinit(self: *SessionListPage, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        self.* = undefined;
    }
};

/// Aggregate cache summary: how many sessions exist and which is latest.
pub const StateSummary = struct {
    count: usize,
    latest_id: ?[]u8 = null,

    /// Frees the owned latest id, if any, and poisons the value.
    pub fn deinit(self: *StateSummary, alloc: Allocator) void {
        if (self.latest_id) |id| alloc.free(id);
        self.* = undefined;
    }
};

/// A resumable writable session handle, re-exported from `session_log` so the
/// store's public surface is self-contained.
pub const LoadedWritableSession = session_log.LoadedWritableSession;

/// Selector for a resume request: the most recent session, or a specific id.
pub const ResumeTarget = union(enum) {
    last,
    id: []const u8,
};

/// Options controlling a resume. `log` is threaded into the canonical log layer;
/// `seed_preferences` overrides the merged-config preferences on migration.
pub const ResumeOptions = struct {
    allow_large_legacy: bool = false,
    seed_preferences: ?session_codec.DurableSessionPreferences = null,
    log: session_log.Options = .{},
};

/// Options controlling a storage-only migration.
pub const MigrationOptions = struct {
    allow_large: bool = false,
    seed_preferences: ?session_codec.DurableSessionPreferences = null,
    log: session_log.Options = .{},
};

/// A read-only load of a session: its summary, full durable state, and the
/// format it was stored in. Owns both nested values.
pub const ReadOnlyDetail = struct {
    summary: SessionSummary,
    state: session_codec.DurableSessionState,
    storage_format: StorageFormat,

    /// Frees the owned summary and state and poisons the value.
    pub fn deinit(self: *ReadOnlyDetail, alloc: Allocator) void {
        self.summary.deinit(alloc);
        self.state.deinit(alloc);
        self.* = undefined;
    }
};

/// A bounded, independently-owned chronological slice of canonical history.
/// The session store remains the authority; callers must deinit this page.
pub const HistoryPage = struct {
    session_id: []u8,
    revision_ms: i64,
    history_len: usize,
    turns: []session.HistoryTurn,
    next_cursor: ?[]u8 = null,

    pub fn deinit(self: *HistoryPage, alloc: Allocator) void {
        alloc.free(self.session_id);
        session.freeHistoryTurnSlice(alloc, self.turns);
        if (self.next_cursor) |cursor| alloc.free(cursor);
        self.* = undefined;
    }
};

/// Outcome of a migration request.
pub const SessionMigrationStatus = enum {
    migrated,
    already_current,
};

/// Result of a storage-only migration, including the source it migrated from.
pub const SessionMigrationResult = struct {
    session_id: []u8,
    source_schema_version: u8,
    source_bytes: u64,
    status: SessionMigrationStatus,

    /// Frees the owned session id and poisons the value.
    pub fn deinit(self: *SessionMigrationResult, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const SessionRecoveryStatus = enum {
    recovered,
    recovered_with_unverified_artifacts,
    indeterminate,
};

pub const SessionRecoveryResult = struct {
    source_session_id: []u8,
    recovered_session_id: []u8,
    history_len: usize,
    status: SessionRecoveryStatus = .recovered,

    pub fn deinit(self: *SessionRecoveryResult, alloc: Allocator) void {
        alloc.free(self.source_session_id);
        alloc.free(self.recovered_session_id);
        self.* = undefined;
    }
};

/// One class of integrity problem `doctor` can report for a session.
pub const DoctorIssueKind = enum {
    authority_less_creation_orphan,
    authority_transition_pending,
    invalid_authority_transition,
    missing_authority,
    invalid_authority,
    commit_intent_pending,
    invalid_commit_intent,
    oversized_legacy_snapshot,
    projection_missing,
    projection_invalid,
    projection_stale,
    commit_watermark_missing,
    commit_watermark_invalid,
    commit_watermark_mismatched,
    canonical_state_invalid,
    canonical_log_large,
    canonical_log_compaction_overdue,
    canonical_log_compaction_failed,
    cleanup_candidate,
    unsafe_path,
};

/// A single `doctor` finding. `bytes`/`growth_*` carry sizes for the size- and
/// growth-based kinds and are null otherwise. Owns `session_id`.
pub const DoctorDiagnostic = struct {
    session_id: []u8,
    kind: DoctorIssueKind,
    bytes: ?u64 = null,
    growth_bytes: ?u64 = null,
    growth_frames: ?u64 = null,

    /// Frees the owned session id and poisons the value.
    pub fn deinit(self: *DoctorDiagnostic, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

/// Bounded `doctor` inspection output. Owns `diagnostics`; caller frees with
/// `deinit`, or moves the list out with `takeDiagnostics`.
pub const DoctorInspectionResult = struct {
    diagnostics: std.ArrayList(DoctorDiagnostic) = .empty,
    inspected_count: usize = 0,
    truncated: bool = false,

    pub fn deinit(self: *DoctorInspectionResult, alloc: Allocator) void {
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        self.diagnostics.deinit(alloc);
        self.* = undefined;
    }

    pub fn takeDiagnostics(self: *DoctorInspectionResult) std.ArrayList(DoctorDiagnostic) {
        const diagnostics = self.diagnostics;
        self.diagnostics = .empty;
        return diagnostics;
    }
};

/// Thresholds that decide when committed-log growth is reported as overdue or
/// failed compaction. Defaults match the historical behavior.
pub const DoctorInspectionOptions = struct {
    compaction_frame_threshold: u64 = 4096,
    compaction_byte_threshold: u64 = 128 * 1024 * 1024,
};

/// Copyable store state shared with discovery and migration without introducing
/// a dependency on the `Store` facade. `canonical_root` retains value semantics.
pub const StoreContext = struct {
    sessions_dir: []const u8,
    home_dir: []const u8,
    workspace_root: []const u8,
    canonical_root: session_log.Root,
};

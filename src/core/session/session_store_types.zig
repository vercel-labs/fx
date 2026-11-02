const std = @import("std");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");

const Allocator = std.mem.Allocator;

/// Default ceiling for an automatic (non-opt-in) legacy snapshot. Snapshots
/// above this are surfaced by `doctor` and refused by automatic migration.
pub const automatic_legacy_max_bytes: u64 = 256 * 1024 * 1024;

/// On-disk storage format a readable session was found in.
pub const StorageFormat = enum {
    conversation,
    schema_v3,
    legacy_v1,
    legacy_v2,
};

/// Storage format of a discovery candidate (kept distinct from `StorageFormat`
/// so discovery and read APIs can evolve independently).
pub const CandidateStorage = enum {
    conversation,
    schema_v3,
    legacy_v1,
    legacy_v2,
};

/// Freshness of a session's cached projection relative to its event log.
pub const ProjectionState = enum {
    current,
    stale,
    /// The projection lagged its log or could not be read, and the summary
    /// came from replaying the committed log instead.
    replayed,
    missing,
    invalid,
};

/// Why a candidate was retained, excluded, or selected during discovery. Used
/// only for structured tracing.
pub const DiscoveryCause = enum {
    listable,
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
    has_checkpoint: bool = false,
    has_managed_children: bool = false,

    pub fn hasResumableContent(self: SessionSummary) bool {
        return self.history_len != 0 or self.has_checkpoint or self.has_managed_children;
    }

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

/// Selector for a resume request: the most recent session, or a specific id.
pub const ResumeTarget = union(enum) {
    last,
    id: []const u8,
};

/// Options for reading a v1 session. `allow_large_legacy` lifts the size
/// bound on a legacy snapshot, for a conversion.
pub const ResumeOptions = struct {
    allow_large_legacy: bool = false,
};

/// A read-only load of a session: its summary, full durable state, and the
/// format it was stored in. Owns both nested values.
pub const ReadOnlyDetail = struct {
    summary: SessionSummary,
    state: session_codec.DurableSessionState,
    storage_format: StorageFormat,
};

pub const SessionRecoveryStatus = enum {
    recovered,
    recovered_with_unverified_artifacts,
};

pub const SessionRecoveryResult = struct {
    source_session_id: []u8,
    recovered_session_id: []u8,
    history_len: usize,
    status: SessionRecoveryStatus = .recovered,
    /// The source's saved permission rules could not be read, so the copy
    /// has none (D72).
    permission_rules_dropped: bool = false,

    pub fn deinit(self: *SessionRecoveryResult, alloc: Allocator) void {
        alloc.free(self.source_session_id);
        alloc.free(self.recovered_session_id);
        self.* = undefined;
    }
};

/// Copyable store state shared with discovery and migration without introducing
/// a dependency on the `Store` facade. `canonical_root` retains value semantics.
pub const StoreContext = struct {
    sessions_dir: []const u8,
    home_dir: []const u8,
    workspace_root: []const u8,
    canonical_root: session_log.Root,
};

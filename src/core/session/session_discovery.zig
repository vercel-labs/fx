const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_child_store = @import("session_child_store.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_log = @import("session_log.zig");
const migration = @import("session_migration.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_replay = @import("session_replay.zig");
const child_state = @import("../subagent/child_state.zig");
const Allocator = std.mem.Allocator;

const authority = @import("session_authority.zig");
const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");

const classifyAuthority = authority.classifyAuthority;
const entryExistsRelative = authority.entryExistsRelative;
const eventLogSize = authority.eventLogSize;
const loadAuthorityMarkerOptional = authority.loadAuthorityMarkerOptional;
const manifestSchemaVersion = authority.manifestSchemaVersion;
const openSessionFile = authority.openSessionFile;
const readOptionalSessionFile = authority.readOptionalSessionFile;
const requireAuthorityFenceAbsent = authority.requireAuthorityFenceAbsent;
const sessionDirPath = paths.sessionDirPath;
const CandidateStorage = types.CandidateStorage;
const DiscoveryCause = types.DiscoveryCause;
const DoctorDiagnostic = types.DoctorDiagnostic;
const DoctorInspectionOptions = types.DoctorInspectionOptions;
const DoctorIssueKind = types.DoctorIssueKind;
const ProjectionState = types.ProjectionState;
const SessionSummary = types.SessionSummary;
const StorageFormat = types.StorageFormat;
const automatic_legacy_max_bytes = types.automatic_legacy_max_bytes;
const StoreContext = types.StoreContext;

pub const DiscoveryMode = enum {
    read_only_list,
    global_read_only_last,
    workspace_writable_last,
};

const DiscoveryOutcome = enum {
    selected,
    retained,
    excluded,
    skipped,
};

pub const DiscoveryCandidateMetadata = struct {
    id: []const u8,
    storage: CandidateStorage,
    projection_state: ProjectionState,
};

/// Why a schema-v3 summary came from the committed log instead of its manifest.
pub const ManifestLoss = enum { missing, invalid };

pub const ReadOnlyCandidate = struct {
    summary: SessionSummary,
    storage: CandidateStorage,
    projection_state: ProjectionState,
    subagent_child: ?bool = null,
    /// Set only when the manifest was missing or invalid and the session was
    /// recovered from its committed log.
    manifest_loss: ?ManifestLoss = null,

    pub fn deinit(self: *ReadOnlyCandidate, alloc: Allocator) void {
        self.summary.deinit(alloc);
        self.* = undefined;
    }
};

const LegacyCandidateSummary = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history_len: usize,
    schema_version: session_json.LegacySchemaVersion = .v1,

    fn intoSessionSummary(self: *LegacyCandidateSummary) SessionSummary {
        const summary = SessionSummary{
            .id = self.id,
            .workspace_root = self.workspace_root,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .conversation_language = self.conversation_language,
            .history_len = self.history_len,
        };
        self.id = undefined;
        self.workspace_root = null;
        return summary;
    }

    fn deinit(self: *LegacyCandidateSummary, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.workspace_root) |root| alloc.free(root);
        self.* = undefined;
    }
};

/// Frees every diagnostic in the list and the list itself. Call once on the
/// slice returned by `Store.inspectForDoctor`.
pub fn freeDoctorDiagnostics(
    alloc: Allocator,
    diagnostics: *std.ArrayList(DoctorDiagnostic),
) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
    diagnostics.deinit(alloc);
}

/// Appends one diagnostic for `session_id`; dupes the id so the caller keeps
/// ownership of its slice. `bytes` carries an optional size for size-based kinds.
pub fn appendDoctorDiagnostic(
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    alloc: Allocator,
    session_id: []const u8,
    kind: DoctorIssueKind,
    bytes: ?u64,
) !void {
    const owned_id = try alloc.dupe(u8, session_id);
    errdefer mem_utils.free(alloc, owned_id);
    try diagnostics.append(alloc, .{
        .session_id = owned_id,
        .kind = kind,
        .bytes = bytes,
    });
}

/// Inspects one session directory and appends a diagnostic for the first
/// integrity problem it finds, dispatching to the authority-state it detects.
/// Owns only sequencing: the actual checks live in the three inspect* helpers
/// below. Fails only on `error.OutOfMemory` from diagnostic allocation; all
/// inspection errors are converted into diagnostics, never propagated.
pub fn inspectDoctorSession(
    ctx: StoreContext,
    alloc: Allocator,
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    _: DoctorInspectionOptions,
) !void {
    if (try session_log.hasConversationMetadata(alloc, session_dir)) {
        var root = ctx.canonical_root;
        var state = root.loadReadOnly(alloc, session_id, .{}) catch |err| {
            try appendDoctorDiagnostic(
                diagnostics,
                alloc,
                session_id,
                if (err == error.SessionPathUnsafe)
                    .unsafe_path
                else
                    .canonical_state_invalid,
                null,
            );
            return;
        };
        state.deinit(alloc);
        try inspectDoctorManagedChildren(
            ctx,
            alloc,
            diagnostics,
            session_dir,
            session_id,
        );
        return;
    }

    if ((entryExistsRelative(session_dir, "authority.pending.json") catch false) or
        (entryExistsRelative(session_dir, "commit.pending.json") catch false))
    {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            .authority_transition_pending,
            null,
        );
        return;
    }

    var candidate = classifyOrRecoverReadOnlyCandidate(
        alloc,
        session_dir,
        session_id,
        null,
    ) catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (err == error.LegacySessionTooLarge)
                .oversized_legacy_snapshot
            else if (err == error.SessionPathUnsafe)
                .unsafe_path
            else
                .canonical_state_invalid,
            null,
        );
        return;
    };
    const stale_schema_v3 = candidate.storage == .schema_v3 and candidate.projection_state == .stale;
    const manifest_loss = candidate.manifest_loss;
    const subagent_child = candidate.subagent_child orelse false;
    candidate.deinit(alloc);
    // The conversation survives a lost manifest: listing and resume read the
    // committed log, and resuming rewrites the summary. Resume refuses a
    // managed child, marked in its first event or, from older releases, only
    // by a marker file, so its lost manifest is still reported as invalid.
    if (manifest_loss) |loss| {
        const managed_child = subagent_child or hasManagedChildMarker(ctx, alloc, session_dir, session_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // An unreadable marker cannot rule a child out.
            else => true,
        };
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (managed_child) .canonical_state_invalid else switch (loss) {
                .missing => .projection_missing,
                .invalid => .projection_invalid,
            },
            null,
        );
        return;
    }
    // A stale schema-v3 session resumes from its committed log, so a log that
    // cannot be replayed leaves the session unreadable even though its
    // manifest is valid; latest resume skips it for the same reason.
    if (stale_schema_v3) {
        if (migration.loadSchemaV3ReadOnly(alloc, session_dir, session_id)) |value| {
            var replay = value;
            replay.deinit(alloc);
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendDoctorDiagnostic(
                diagnostics,
                alloc,
                session_id,
                if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                null,
            );
            return;
        }
    }
    try inspectDoctorManagedChildren(
        ctx,
        alloc,
        diagnostics,
        session_dir,
        session_id,
    );
}

/// Reports whether the session carries a managed-child marker file, the
/// check resume admission makes before refusing a session.
fn hasManagedChildMarker(
    ctx: StoreContext,
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !bool {
    const display_path = try sessionDirPath(alloc, ctx.sessions_dir, session_id);
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initSubagentControl(
        alloc,
        session_dir.dir,
        display_path,
        .read_only,
        .{},
    );
    defer capability.deinit();
    return child_state.capabilityHasManagedChildMarker(alloc, &capability);
}

fn inspectDoctorManagedChildren(
    ctx: StoreContext,
    alloc: Allocator,
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !void {
    const display_path = try sessionDirPath(alloc, ctx.sessions_dir, session_id);
    defer alloc.free(display_path);
    var capability = session_child_store.SessionChildCapability.init(
        alloc,
        session_dir.dir,
        display_path,
        .read_only,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .unsafe_path, null);
        return;
    };
    defer capability.deinit();

    const child_kinds = [_]session_child_store.ManagedChildKind{
        .command_artifacts,
        .browser_artifacts,
        .tool_results,
        .subagent_control,
    };
    for (child_kinds) |kind| {
        var entries = capability.iterate(alloc, kind) catch |err| {
            if (err == error.OutOfMemory) return err;
            try appendDoctorDiagnostic(diagnostics, alloc, session_id, .unsafe_path, null);
            return;
        };
        entries.deinit();
    }
}

/// Classifies a session directory into a read-only candidate, dispatching on
/// its authority state to the schema-v3 or legacy classifier.
pub fn classifyReadOnlyCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !ReadOnlyCandidate {
    return classifyReadOnlyCandidateWithCancellation(alloc, session_dir, session_id, null);
}

/// Classifies a session for read-only use and recovers a schema-v3 session
/// whose manifest is missing or invalid from its committed log, so every
/// read-only surface agrees on which sessions exist. Every other
/// classification error is returned. The caller owns the candidate.
pub fn classifyOrRecoverReadOnlyCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    return classifyReadOnlyCandidateWithCancellation(alloc, session_dir, session_id, cancelled) catch |err| {
        const loss: ManifestLoss = switch (err) {
            error.SessionNotFound => .missing,
            error.InvalidSessionFormat => .invalid,
            else => return err,
        };
        var recovered = (try recoverSchemaV3Candidate(alloc, session_dir, session_id, cancelled)) orelse return err;
        recovered.manifest_loss = loss;
        return recovered;
    };
}

fn classifyReadOnlyCandidateWithCancellation(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    if (try session_log.readConversationMetadata(alloc, session_dir)) |value| {
        var metadata = value;
        defer metadata.deinit();
        return classifyConversationCandidate(alloc, session_dir, session_id, metadata.value, cancelled);
    }
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    const candidate = switch (try classifyAuthority(alloc, session_dir, session_id)) {
        .schema_v3 => classifySchemaV3Candidate(alloc, session_dir, session_id),
        .legacy => classifyLegacyCandidateWithCancellation(alloc, session_dir, session_id, cancelled),
    };
    var owned = try candidate;
    errdefer owned.deinit(alloc);
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    return owned;
}

fn classifyConversationCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    metadata: session_codec.SessionMetadata,
    cancelled: ?*const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    if (!std.mem.eql(u8, metadata.id, session_id)) {
        return error.InvalidSessionFormat;
    }

    const event_stat = try session_dir.dir.statFile(
        io_mod.getIo(),
        "events.jsonl",
        .{ .follow_symlinks = false },
    );
    if (event_stat.kind != .file or event_stat.nlink != 1) {
        return error.SessionPathUnsafe;
    }
    var history_len: usize = 0;
    var has_checkpoint = false;
    if (event_stat.size > 0) {
        var event_file = try openSessionFile(session_dir, "events.jsonl", .read_only);
        defer event_file.close(io_mod.getIo());
        var offset: u64 = 0;
        var buffer: [8192]u8 = undefined;
        var reader = event_file.reader(io_mod.getIo(), &buffer);
        while (offset < event_stat.size) {
            const read = session_replay.readBufferedLine(alloc, &reader, event_stat.size, cancelled);
            const line = read catch |err| switch (err) {
                error.TruncatedEventFrame => break,
                else => return err,
            } orelse break;
            defer alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
            defer decoded.deinit();
            switch (decoded.value.event) {
                .context_checkpoint => has_checkpoint = true,
                .turn_completed, .interrupted => history_len = std.math.add(
                    usize,
                    history_len,
                    1,
                ) catch return error.InvalidSessionFormat,
                else => {},
            }
            offset = line.next_offset;
        }
    }

    const id = try alloc.dupe(u8, metadata.id);
    errdefer mem_utils.free(alloc, id);
    const origin = try alloc.dupe(u8, metadata.origin_workspace_root);
    errdefer mem_utils.free(alloc, origin);
    const workspace = try alloc.dupe(u8, metadata.workspace_root);
    errdefer mem_utils.free(alloc, workspace);
    const title = if (metadata.title) |value| try alloc.dupe(u8, value) else null;
    return .{
        .summary = .{
            .id = id,
            .workspace_root = workspace,
            .origin_workspace_root = origin,
            .title = title,
            .created_at_ms = metadata.created_at_ms,
            .updated_at_ms = if (history_len == 0 and !has_checkpoint)
                metadata.updated_at_ms
            else
                @max(
                    metadata.updated_at_ms,
                    std.math.cast(
                        i64,
                        @divFloor(event_stat.mtime.nanoseconds, std.time.ns_per_ms),
                    ) orelse std.math.maxInt(i64),
                ),
            .conversation_language = session.ConversationLanguage.fromSlice(
                metadata.conversation_language,
            ) catch return error.InvalidSessionFormat,
            .history_len = history_len,
            .has_checkpoint = has_checkpoint,
        },
        .storage = .conversation,
        .projection_state = .current,
        .subagent_child = metadata.subagent_child,
    };
}

/// Builds a read-only candidate from a schema-v3 manifest, validating the
/// authority marker, manifest identity, and projection freshness.
/// Fails with `error.InvalidSessionFormat` / `error.UnsupportedSessionSchema` on mismatch.
fn classifySchemaV3Candidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !ReadOnlyCandidate {
    var marker = (try loadAuthorityMarkerOptional(alloc, session_dir)) orelse
        return error.InvalidSessionFormat;
    defer marker.deinit(alloc);
    if (!std.mem.eql(u8, marker.session_id, session_id)) {
        return error.InvalidSessionFormat;
    }

    const manifest_bytes = readOptionalSessionFile(
        alloc,
        session_dir,
        "session.json",
        session_projection.manifest_max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    } orelse return error.SessionNotFound;
    defer alloc.free(manifest_bytes);
    if (manifestSchemaVersion(alloc, manifest_bytes)) |schema_version| {
        if (schema_version != 3) return error.UnsupportedSessionSchema;
    } else |_| {}
    var manifest = session_projection.decodeManifest(
        alloc,
        manifest_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &marker.authority_id))
    {
        return error.InvalidSessionFormat;
    }
    const event_log_size = try eventLogSize(session_dir, "events.jsonl");
    const projection_state: ProjectionState = if (session_projection.isManifestStale(
        manifest,
        event_log_size,
    )) .stale else .current;
    try requireAuthorityFenceAbsent(alloc, session_dir, session_id);

    const history_len = std.math.cast(usize, manifest.history_len) orelse
        return error.InvalidSessionFormat;
    const id = try alloc.dupe(u8, manifest.id);
    errdefer mem_utils.free(alloc, id);
    const origin_workspace_root = try alloc.dupe(u8, manifest.origin_workspace_root);
    errdefer mem_utils.free(alloc, origin_workspace_root);
    const workspace_root = try alloc.dupe(u8, manifest.workspace_root);
    errdefer mem_utils.free(alloc, workspace_root);
    var display = try session_display_metadata.readSidecarOrFallback(alloc, session_dir);
    if (display.origin_workspace_root) |root| {
        alloc.free(root);
        display.origin_workspace_root = null;
    }

    return .{
        .summary = .{
            .id = id,
            .workspace_root = workspace_root,
            .origin_workspace_root = origin_workspace_root,
            .title = display.title,
            .preview = display.preview,
            .display_metadata_present = display.present,
            .created_at_ms = manifest.created_at_ms,
            .updated_at_ms = manifest.updated_at_ms,
            .conversation_language = manifest.conversation_language,
            .history_len = history_len,
        },
        .storage = .schema_v3,
        .projection_state = projection_state,
    };
}

/// Recovers a schema-v3 session whose manifest is missing or cannot be read:
/// its committed log is the authority, so the summary is replayed from it, as
/// latest selection always did. Returns null when the session is not
/// schema-v3, sits behind an interrupted upgrade (the route classification
/// refuses it), or its log cannot be replayed either, leaving the caller to
/// report the classification error.
fn recoverSchemaV3Candidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) !?ReadOnlyCandidate {
    if (try session_log.hasConversationMetadata(alloc, session_dir)) return null;
    const route = classifyAuthority(alloc, session_dir, session_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (route != .schema_v3) return null;

    var candidate: ReadOnlyCandidate = candidate: {
        const id = try alloc.dupe(u8, session_id);
        errdefer mem_utils.free(alloc, id);
        var display = try session_display_metadata.readSidecarOrFallback(alloc, session_dir);
        if (display.origin_workspace_root) |root| {
            alloc.free(root);
            display.origin_workspace_root = null;
        }
        break :candidate .{
            .summary = .{
                .id = id,
                .title = display.title,
                .preview = display.preview,
                .display_metadata_present = display.present,
                .created_at_ms = 0,
                .updated_at_ms = 0,
                .conversation_language = .default(),
                .history_len = 0,
            },
            .storage = .schema_v3,
            .projection_state = .stale,
        };
    };
    errdefer candidate.deinit(alloc);
    if (!try replayCommittedLog(alloc, session_dir, &candidate, cancelled)) {
        candidate.deinit(alloc);
        return null;
    }
    debug_trace.logf("session", "schema_v3 manifest unreadable id={s}; listed from the committed log", .{session_id});
    return candidate;
}

/// Listing's summary of a stale schema-v3 projection: a stale manifest carries
/// the wrong workspace and recency, so the summary is replaced by one replayed
/// from the committed log, and the child identity comes from its first event.
/// If the replay fails the stale summary stays listed: exact opens report the
/// failure, and latest resume skips the session. Exact opens replay the log
/// themselves, so only listing calls this.
pub fn summarizeStaleProjection(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    candidate: *ReadOnlyCandidate,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    if (candidate.storage != .schema_v3 or candidate.projection_state != .stale) return;
    _ = try replayCommittedLog(alloc, session_dir, candidate, cancelled);
}

/// Serializes summary replays in this process: each replay holds a full
/// session state, so parallel listing workers would otherwise hold one per
/// stale log at once.
var summary_replay_gate: std.Io.Mutex = .init;

/// Replaces the log-derived fields of a schema-v3 candidate with a replay of
/// its committed log and marks it replayed. Returns false, leaving the
/// candidate unchanged, when the log cannot be replayed. One replay runs at a
/// time; a waiting caller observes cancellation once it enters.
fn replayCommittedLog(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    candidate: *ReadOnlyCandidate,
    cancelled: ?*const std.atomic.Value(bool),
) !bool {
    summary_replay_gate.lockUncancelable(io_mod.getIo());
    defer summary_replay_gate.unlock(io_mod.getIo());
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    var replay = migration.loadSchemaV3ReadOnly(alloc, session_dir, candidate.summary.id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "schema_v3 log replay failed id={s} err={s}", .{ candidate.summary.id, @errorName(err) });
            return false;
        },
    };
    defer replay.deinit(alloc);
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    const state = &replay.state;
    const origin_workspace_root = try alloc.dupe(u8, state.origin_workspace_root);
    errdefer alloc.free(origin_workspace_root);
    const workspace_root = try alloc.dupe(u8, state.workspace_root);

    const summary = &candidate.summary;
    if (summary.origin_workspace_root) |root| alloc.free(root);
    if (summary.workspace_root) |root| alloc.free(root);
    summary.origin_workspace_root = origin_workspace_root;
    summary.workspace_root = workspace_root;
    summary.created_at_ms = state.created_at_ms;
    summary.updated_at_ms = state.updated_at_ms;
    summary.conversation_language = state.conversation_language;
    summary.history_len = state.history.len;
    candidate.projection_state = .replayed;
    candidate.subagent_child = state.subagent_child;
    return true;
}

/// Builds a read-only candidate from a legacy `session.json` snapshot via a
/// streaming summary parse. Rejects directories carrying an authority fence.
fn classifyLegacyCandidateWithCancellation(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    return classifyLegacySnapshot(alloc, session_dir, session_id, "session.json", .must_be_absent, cancelled);
}

/// Summarizes a legacy session whose upgrade was interrupted, from its stable
/// snapshot, without recovering it. Listing uses this so the session stays
/// reachable; resuming it runs the canonical recovery or reports the boundary.
/// Caller owns the candidate.
pub fn classifyFencedLegacyCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    if (!try entryExistsRelative(session_dir, "authority.pending.json")) {
        return error.SessionAuthorityBoundaryUnavailable;
    }
    const name: []const u8 = if (try entryExistsRelative(session_dir, "session.legacy.json"))
        "session.legacy.json"
    else
        "session.json";
    return classifyLegacySnapshot(alloc, session_dir, session_id, name, .pending_allowed, cancelled);
}

fn classifyLegacySnapshot(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    name: []const u8,
    fence: enum { must_be_absent, pending_allowed },
    cancelled: ?*const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    if (try entryExistsRelative(session_dir, "authority.json")) {
        return error.InvalidSessionFormat;
    }
    // Opening a FIFO or device for reading can block, so the helper checks
    // the entry and opens it without blocking.
    var file = io_mod.openExistingRegularFile(session_dir.dir, name, .read_only) catch |err| switch (err) {
        error.DurablePathUnsafe => return error.SessionPathUnsafe,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    if (stat.size > automatic_legacy_max_bytes) return error.LegacySessionTooLarge;
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io_mod.getIo(), &buffer);
    var legacy = try readLegacySummary(alloc, &reader.interface, cancelled);
    errdefer legacy.deinit(alloc);
    if (!std.mem.eql(u8, legacy.id, session_id)) {
        return error.InvalidSessionFormat;
    }
    if (fence == .must_be_absent) try requireAuthorityFenceAbsent(alloc, session_dir, session_id);
    const storage = candidateStorageForLegacy(legacy.schema_version);
    return .{
        .summary = legacy.intoSessionSummary(),
        .storage = storage,
        .projection_state = if (fence == .must_be_absent) .current else .stale,
    };
}

const CancellableReader = struct {
    source: *std.Io.Reader,
    cancelled: ?*const std.atomic.Value(bool),
    interface: std.Io.Reader,

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CancellableReader = @fieldParentPtr("interface", reader);
        if (self.cancelled) |stop| {
            if (stop.load(.acquire)) return error.ReadFailed;
        }
        return self.source.stream(writer, limit.min(.limited(8192)));
    }
};

fn readLegacySummary(
    alloc: Allocator,
    source: *std.Io.Reader,
    cancelled: ?*const std.atomic.Value(bool),
) !LegacyCandidateSummary {
    var buffer: [8192]u8 = undefined;
    var reader = CancellableReader{
        .source = source,
        .cancelled = cancelled,
        .interface = .{ .vtable = &.{ .stream = CancellableReader.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
    };
    var result = session_json.parseLegacySummaryStreaming(LegacyCandidateSummary, alloc, &reader.interface) catch |err| {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        return err;
    };
    errdefer result.deinit(alloc);
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    return result;
}

test "legacy summary cancellation stops after streaming starts" {
    const alloc = std.testing.allocator;
    const bytes = "{\"schema_version\":2,\"history\":[{\"user\":\"request\",\"assistant\":\"response\"}]," ++
        "\"id\":\"legacy\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":null," ++
        "\"conversation_language\":\"en\",\"history_len\":1}";
    const Source = struct {
        input: std.Io.Reader,
        stopped: *std.atomic.Value(bool),
        reads: usize = 0,
        interface: std.Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },

        fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *@This() = @fieldParentPtr("interface", reader);
            self.reads += 1;
            const count = try self.input.stream(writer, limit.min(.limited(32)));
            self.stopped.store(true, .release);
            return count;
        }
    };
    var stopped = std.atomic.Value(bool).init(false);
    var source = Source{ .input = .fixed(bytes), .stopped = &stopped };
    try std.testing.expectError(error.Cancelled, readLegacySummary(alloc, &source.interface, &stopped));
    try std.testing.expectEqual(@as(usize, 1), source.reads);
    try std.testing.expect(source.input.seek > 0 and source.input.seek < bytes.len);
    stopped.store(false, .release);
    var complete = std.Io.Reader.fixed(bytes);
    var summary = try readLegacySummary(alloc, &complete, &stopped);
    defer summary.deinit(alloc);
    try std.testing.expectEqualStrings("legacy", summary.id);
    try std.testing.expectEqual(@as(usize, 1), summary.history_len);
}

/// Projects a durable session state into the lightweight `SessionSummary`
/// returned by listing APIs. Allocates owned copies of the id and roots.
pub fn summaryFromState(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
) !SessionSummary {
    const id = try alloc.dupe(u8, state.id);
    errdefer mem_utils.free(alloc, id);
    const origin_workspace_root = try alloc.dupe(u8, state.origin_workspace_root);
    errdefer mem_utils.free(alloc, origin_workspace_root);
    const workspace_root = try alloc.dupe(u8, state.workspace_root);
    errdefer mem_utils.free(alloc, workspace_root);
    var display = try session_display_metadata.deriveFromHistory(alloc, state.history);
    errdefer display.deinit(alloc);

    return .{
        .id = id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = display.title,
        .preview = display.preview,
        .display_metadata_present = display.present,
        .created_at_ms = state.created_at_ms,
        .updated_at_ms = state.updated_at_ms,
        .conversation_language = state.conversation_language,
        .history_len = state.history.len,
    };
}

fn candidateStorageForLegacy(
    schema: session_json.LegacySchemaVersion,
) CandidateStorage {
    return switch (schema) {
        .v1 => .legacy_v1,
        .v2 => .legacy_v2,
    };
}

/// Maps a legacy schema version to its public `StorageFormat` tag.
pub fn storageFormatForLegacy(
    schema: session_json.LegacySchemaVersion,
) StorageFormat {
    return switch (schema) {
        .v1 => .legacy_v1,
        .v2 => .legacy_v2,
    };
}

/// Emits one structured discovery trace line. Pure logging; never fails.
pub fn logDiscovery(
    mode: DiscoveryMode,
    session_id: []const u8,
    storage: ?CandidateStorage,
    projection: ?ProjectionState,
    cause: DiscoveryCause,
    outcome: DiscoveryOutcome,
    err: ?anyerror,
) void {
    if (err == null and outcome != .selected) return;
    debug_trace.logf(
        "core",
        "session discovery mode={s} cause={s} storage_format={s} projection_state={s} validated_candidate_id={s} outcome={s} error={s}",
        .{
            @tagName(mode),
            @tagName(cause),
            if (storage) |value| @tagName(value) else "unknown",
            if (projection) |value| @tagName(value) else "unknown",
            session_id,
            @tagName(outcome),
            if (err) |value| @errorName(value) else "none",
        },
    );
}

/// Logs a discovery exclusion, mapping the error to a `DiscoveryCause` and
/// to a retained/excluded outcome.
pub fn logDiscoveryError(
    mode: DiscoveryMode,
    session_id: []const u8,
    storage: ?CandidateStorage,
    projection: ?ProjectionState,
    err: anyerror,
) void {
    logDiscovery(
        mode,
        session_id,
        storage,
        projection,
        discoveryCause(err),
        if (err == error.SessionProjectionStale) .retained else .excluded,
        err,
    );
}

fn discoveryCause(err: anyerror) DiscoveryCause {
    return switch (err) {
        error.SessionProjectionStale => .listable,
        error.SessionAuthorityBoundaryUnavailable => .authority_transition,
        error.SessionNotFound => .missing_manifest,
        error.UnsupportedSessionSchema => .unsupported_schema,
        error.LegacySessionTooLarge => .legacy_too_large,
        error.SessionPathUnsafe, error.DurablePathUnsafe => .unsafe_path,
        else => .invalid_manifest,
    };
}

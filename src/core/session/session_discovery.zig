const std = @import("std");
const background_store = @import("../background/background_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_child_store = @import("session_child_store.zig");
const session_json = @import("session_json.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const subagent_control_store = @import("../subagent/control_store.zig");
const Allocator = std.mem.Allocator;

const authority = @import("session_authority.zig");
const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");

const classifyAuthority = authority.classifyAuthority;
const entryExistsRelative = authority.entryExistsRelative;
const eventFileStat = authority.eventFileStat;
const loadAuthorityMarkerOptional = authority.loadAuthorityMarkerOptional;
const loadAuthorityTransitionOptional = authority.loadAuthorityTransitionOptional;
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

pub const ReadOnlyCandidate = struct {
    summary: SessionSummary,
    storage: CandidateStorage,
    projection_state: ProjectionState,

    pub fn deinit(self: *ReadOnlyCandidate, alloc: Allocator) void {
        self.summary.deinit(alloc);
        self.* = undefined;
    }
};

pub const WritableCandidate = struct {
    id: []u8,
    workspace_root: []u8,
    updated_at_ms: i64,
    history_len: usize,
    has_durable_activity: bool,
    has_managed_children: bool,
    storage: CandidateStorage,
    projection_state: ProjectionState,

    pub fn isResumable(self: WritableCandidate) bool {
        return self.history_len != 0 or
            self.has_durable_activity or
            self.has_managed_children;
    }

    pub fn deinit(self: *WritableCandidate, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.workspace_root);
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
        // Legacy snapshots cannot distinguish a pristine start from a
        // zero-history session with durable activity. Preserve zero-history
        // legacy sessions conservatively; schema-v3 projections can prove the
        // pristine case from their event sequence.
        const summary = SessionSummary{
            .id = self.id,
            .workspace_root = self.workspace_root,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .conversation_language = self.conversation_language,
            .history_len = self.history_len,
            .has_durable_activity = self.history_len == 0,
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

test "legacy zero-history summaries remain conservatively resumable" {
    const alloc = std.testing.allocator;
    var legacy = LegacyCandidateSummary{
        .id = try alloc.dupe(u8, "legacy-zero-history"),
        .workspace_root = try alloc.dupe(u8, "/tmp/workspace"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history_len = 0,
    };
    var summary = legacy.intoSessionSummary();
    defer summary.deinit(alloc);

    try std.testing.expect(summary.has_durable_activity);
}

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
    errdefer alloc.free(owned_id);
    try diagnostics.append(alloc, .{
        .session_id = owned_id,
        .kind = kind,
        .bytes = bytes,
    });
}

fn appendDoctorGrowthDiagnostic(
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    alloc: Allocator,
    session_id: []const u8,
    kind: DoctorIssueKind,
    bytes: u64,
    growth_bytes: u64,
    growth_frames: u64,
) !void {
    const owned_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_id);
    try diagnostics.append(alloc, .{
        .session_id = owned_id,
        .kind = kind,
        .bytes = bytes,
        .growth_bytes = growth_bytes,
        .growth_frames = growth_frames,
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
    options: DoctorInspectionOptions,
) !void {
    const transition = loadAuthorityTransitionOptional(alloc, session_dir) catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (err == error.SessionPathUnsafe) .unsafe_path else .invalid_authority_transition,
            null,
        );
        return;
    };
    if (transition) |transition_value| {
        var owned = transition_value;
        defer owned.deinit(alloc);
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .authority_transition_pending, null);
        return;
    }

    const marker = loadAuthorityMarkerOptional(alloc, session_dir) catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (err == error.SessionPathUnsafe) .unsafe_path else .invalid_authority,
            null,
        );
        return;
    };
    if (marker == null) {
        return inspectAuthoritylessSession(ctx, alloc, diagnostics, session_dir, session_id);
    }

    var owned_marker = marker.?;
    defer owned_marker.deinit(alloc);
    if (!std.mem.eql(u8, owned_marker.session_id, session_id)) {
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .invalid_authority, null);
        return;
    }

    return inspectSchemaV3Session(ctx, alloc, diagnostics, session_dir, session_id, options);
}

/// Diagnoses a session that carries no authority marker: either an in-flight
/// schema-v3 creation orphan, an oversized legacy snapshot, or a missing
/// authority record. Terminal: appends exactly one classification and returns.
fn inspectAuthoritylessSession(
    ctx: StoreContext,
    alloc: Allocator,
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !void {
    const manifest_bytes = try readOptionalSessionFile(
        alloc,
        session_dir,
        "session.json",
        session_projection.manifest_max_bytes,
    );
    if (manifest_bytes) |bytes| {
        defer alloc.free(bytes);
        const schema_version = manifestSchemaVersion(alloc, bytes) catch {
            try appendDoctorDiagnostic(diagnostics, alloc, session_id, .missing_authority, null);
            return;
        };
        if (schema_version == 3) {
            var manifest = session_projection.decodeManifest(alloc, bytes) catch {
                try appendDoctorDiagnostic(diagnostics, alloc, session_id, .missing_authority, null);
                return;
            };
            defer manifest.deinit(alloc);
            try appendDoctorDiagnostic(
                diagnostics,
                alloc,
                session_id,
                if (std.mem.eql(u8, manifest.id, session_id))
                    .authority_less_creation_orphan
                else
                    .missing_authority,
                null,
            );
            return;
        }

        var legacy_file = try openSessionFile(session_dir, "session.json", .read_only);
        defer legacy_file.close(io_mod.getIo());
        const legacy_stat = try legacy_file.stat(io_mod.getIo());
        if (legacy_stat.size > automatic_legacy_max_bytes) {
            try appendDoctorDiagnostic(diagnostics, alloc, session_id, .oversized_legacy_snapshot, legacy_stat.size);
        }
        try inspectDoctorManagedChildren(ctx, alloc, diagnostics, session_dir, session_id);
        return;
    }

    const has_prepared_log = entryExistsRelative(session_dir, "events.jsonl") catch false;
    try appendDoctorDiagnostic(
        diagnostics,
        alloc,
        session_id,
        if (has_prepared_log) .authority_less_creation_orphan else .missing_authority,
        null,
    );
}

/// Diagnoses a session that owns a valid authority marker: validates the
/// projection manifest, event log size, commit watermark, compaction growth,
/// stale/cleanup artifacts, managed children, and finally a canonical replay.
/// Terminal: stops at the first disqualifying problem.
fn inspectSchemaV3Session(
    ctx: StoreContext,
    alloc: Allocator,
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    options: DoctorInspectionOptions,
) !void {
    const manifest_bytes = try readOptionalSessionFile(
        alloc,
        session_dir,
        "session.json",
        session_projection.manifest_max_bytes,
    );
    if (manifest_bytes == null) {
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .projection_missing, null);
    }

    var manifest: ?session_projection.Manifest = null;
    defer if (manifest) |*value| value.deinit(alloc);
    if (manifest_bytes) |bytes| {
        defer alloc.free(bytes);
        manifest = session_projection.decodeManifest(alloc, bytes) catch {
            try appendDoctorDiagnostic(diagnostics, alloc, session_id, .projection_invalid, null);
            return;
        };
    }

    const event_stat = eventFileStat(session_dir, "events.jsonl") catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
            null,
        );
        return;
    };
    if (event_stat.size >= 128 * 1024 * 1024) {
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .canonical_log_large, event_stat.size);
        return;
    }

    const watermark = session_log.inspectCommitWatermark(alloc, session_dir, session_id) catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
            null,
        );
        return;
    };
    switch (watermark.status) {
        .missing, .invalid, .mismatched => {
            try appendDoctorDiagnostic(
                diagnostics,
                alloc,
                session_id,
                switch (watermark.status) {
                    .missing => .commit_watermark_missing,
                    .invalid => .commit_watermark_invalid,
                    .mismatched => .commit_watermark_mismatched,
                    .valid => unreachable,
                },
                null,
            );
            return;
        },
        .valid => {},
    }

    const committed_position = watermark.position.?;
    const has_failed_compaction = try session_log.hasValidatedCompactionTemp(alloc, session_dir, session_id);
    if (manifest) |value| {
        try appendCompactionGrowthIfNeeded(
            diagnostics,
            alloc,
            session_id,
            value,
            committed_position,
            has_failed_compaction,
            options,
        );
    }
    if (manifest) |value| {
        if (session_projection.isManifestStale(value, event_stat)) {
            try appendDoctorDiagnostic(diagnostics, alloc, session_id, .projection_stale, null);
        }
        try appendCleanupCandidateIfPresent(diagnostics, alloc, session_id, session_dir, value);
    }

    try inspectDoctorManagedChildren(ctx, alloc, diagnostics, session_dir, session_id);

    const has_commit_intent = entryExistsRelative(session_dir, "commit.pending.json") catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (err == error.SessionPathUnsafe) .unsafe_path else .invalid_commit_intent,
            null,
        );
        return;
    };

    var root = ctx.canonical_root;
    var state = root.loadReadOnly(alloc, session_id, .{}) catch |err| {
        try appendDoctorDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (has_commit_intent and err == error.SessionCommitBoundaryUnavailable)
                .commit_intent_pending
            else if (has_commit_intent)
                .invalid_commit_intent
            else if (err == error.SessionPathUnsafe)
                .unsafe_path
            else
                .canonical_state_invalid,
            null,
        );
        return;
    };
    state.deinit(alloc);
}

/// Appends a compaction diagnostic when the committed log has grown past the
/// configured byte/frame thresholds within the manifest's current generation.
/// No-op when the generation differs or growth is under threshold.
fn appendCompactionGrowthIfNeeded(
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    alloc: Allocator,
    session_id: []const u8,
    manifest: session_projection.Manifest,
    committed_position: session_log.CommitPosition,
    has_failed_compaction: bool,
    options: DoctorInspectionOptions,
) !void {
    const same_generation = std.mem.eql(u8, &manifest.log_generation, &committed_position.log_generation);
    if (!same_generation) return;
    const growth_bytes = committed_position.through_event_log_bytes -
        @min(committed_position.through_event_log_bytes, manifest.generation_base_bytes);
    const growth_frames = committed_position.through_seq -
        @min(committed_position.through_seq, manifest.generation_base_seq);
    if (growth_bytes >= options.compaction_byte_threshold or
        growth_frames >= options.compaction_frame_threshold)
    {
        try appendDoctorGrowthDiagnostic(
            diagnostics,
            alloc,
            session_id,
            if (has_failed_compaction)
                .canonical_log_compaction_failed
            else
                .canonical_log_compaction_overdue,
            committed_position.through_event_log_bytes,
            growth_bytes,
            growth_frames,
        );
    }
}

/// Appends a single cleanup-candidate diagnostic if the directory contains a
/// compaction artifact from a generation other than the manifest's current one.
fn appendCleanupCandidateIfPresent(
    diagnostics: *std.ArrayList(DoctorDiagnostic),
    alloc: Allocator,
    session_id: []const u8,
    session_dir: *io_mod.VerifiedDir,
    manifest: session_projection.Manifest,
) !void {
    var entries = session_dir.dir.iterate();
    while (try entries.next(io_mod.getIo())) |entry| {
        const generation = session_log.cleanupCandidateGeneration(entry.name) orelse continue;
        if (std.mem.eql(u8, &generation, &manifest.log_generation)) continue;
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .cleanup_candidate, null);
        break;
    }
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
        .background_records,
        .background_logs,
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
    background_store.validateAllManagedRecords(alloc, &capability) catch |err| {
        if (err == error.OutOfMemory) return err;
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, .canonical_state_invalid, null);
        return;
    };
    subagent_control_store.validateManagedRecord(
        alloc,
        &capability,
        session_id,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        const kind: DoctorIssueKind = switch (err) {
            error.ControlPathUnsafe, error.PrivateStatePermissionsUnsupported => .unsafe_path,
            else => .canonical_state_invalid,
        };
        try appendDoctorDiagnostic(diagnostics, alloc, session_id, kind, null);
        return;
    };
}

/// Classifies a session directory into a read-only candidate, dispatching on
/// its authority state to the schema-v3 or legacy classifier.
pub fn classifyReadOnlyCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !ReadOnlyCandidate {
    return switch (try classifyAuthority(alloc, session_dir, session_id)) {
        .schema_v3 => classifySchemaV3Candidate(alloc, session_dir, session_id),
        .legacy => classifyLegacyCandidate(alloc, session_dir, session_id),
    };
}

/// Builds a read-only candidate from a schema-v3 manifest, validating the
/// authority marker, manifest identity, and projection freshness.
/// Fails with `error.InvalidSessionFormat` / `error.UnsupportedSessionSchema` on mismatch.
pub fn classifySchemaV3Candidate(
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
    const current_stat = try eventFileStat(session_dir, "events.jsonl");
    const projection_state: ProjectionState = if (session_projection.isManifestStale(
        manifest,
        current_stat,
    )) .stale else .current;
    try requireAuthorityFenceAbsent(alloc, session_dir, session_id);

    const history_len = std.math.cast(usize, manifest.history_len) orelse
        return error.InvalidSessionFormat;
    const id = try alloc.dupe(u8, manifest.id);
    errdefer alloc.free(id);
    const origin_workspace_root = try alloc.dupe(u8, manifest.origin_workspace_root);
    errdefer alloc.free(origin_workspace_root);
    const workspace_root = try alloc.dupe(u8, manifest.workspace_root);
    errdefer alloc.free(workspace_root);
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
            .has_durable_activity = manifest.last_event_seq > 1,
        },
        .storage = .schema_v3,
        .projection_state = projection_state,
    };
}

/// Builds a read-only candidate from a legacy `session.json` snapshot via a
/// streaming summary parse. Rejects directories carrying an authority fence.
pub fn classifyLegacyCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !ReadOnlyCandidate {
    if (try entryExistsRelative(session_dir, "authority.json")) {
        return error.InvalidSessionFormat;
    }
    var file = try openSessionFile(session_dir, "session.json", .read_only);
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    if (stat.size > automatic_legacy_max_bytes) return error.LegacySessionTooLarge;
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io_mod.getIo(), &buffer);
    var legacy = session_json.parseLegacySummaryStreaming(
        LegacyCandidateSummary,
        alloc,
        &reader.interface,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    errdefer legacy.deinit(alloc);
    if (!std.mem.eql(u8, legacy.id, session_id)) {
        return error.InvalidSessionFormat;
    }
    try requireAuthorityFenceAbsent(alloc, session_dir, session_id);
    const storage = candidateStorageForLegacy(legacy.schema_version);
    return .{
        .summary = legacy.intoSessionSummary(),
        .storage = storage,
        .projection_state = .current,
    };
}

/// Projects a durable session state into the lightweight `SessionSummary`
/// returned by listing APIs. Allocates owned copies of the id and roots.
pub fn summaryFromState(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
) !SessionSummary {
    const id = try alloc.dupe(u8, state.id);
    errdefer alloc.free(id);
    const origin_workspace_root = try alloc.dupe(u8, state.origin_workspace_root);
    errdefer alloc.free(origin_workspace_root);
    const workspace_root = try alloc.dupe(u8, state.workspace_root);
    errdefer alloc.free(workspace_root);
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

/// Constructs a writable candidate, taking owned copies of the id and
/// workspace root from caller-provided slices.
pub fn dupeWritableCandidate(
    alloc: Allocator,
    id_source: []const u8,
    workspace_source: []const u8,
    updated_at_ms: i64,
    history_len: usize,
    has_durable_activity: bool,
    has_managed_children: bool,
    storage: CandidateStorage,
    projection_state: ProjectionState,
) !WritableCandidate {
    const id = try alloc.dupe(u8, id_source);
    errdefer alloc.free(id);
    const workspace_root = try alloc.dupe(u8, workspace_source);
    return .{
        .id = id,
        .workspace_root = workspace_root,
        .updated_at_ms = updated_at_ms,
        .history_len = history_len,
        .has_durable_activity = has_durable_activity,
        .has_managed_children = has_managed_children,
        .storage = storage,
        .projection_state = projection_state,
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

/// Orders writable candidates: newer `updated_at_ms` wins, ties broken by
/// descending id. Used to select the most recent writable session.
pub fn writableCandidateNewer(
    candidate: WritableCandidate,
    current: WritableCandidate,
) bool {
    if (candidate.updated_at_ms != current.updated_at_ms) {
        return candidate.updated_at_ms > current.updated_at_ms;
    }
    return std.mem.order(u8, candidate.id, current.id) == .gt;
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

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_log = @import("session_log.zig");
const migration = @import("session_migration.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_replay = @import("session_replay.zig");
const Allocator = std.mem.Allocator;

const authority = @import("session_authority.zig");
const types = @import("session_store_types.zig");

const classifyAuthority = authority.classifyAuthority;
const entryExistsRelative = authority.entryExistsRelative;
const eventLogSize = authority.eventLogSize;
const loadAuthorityMarkerOptional = authority.loadAuthorityMarkerOptional;
const manifestSchemaVersion = authority.manifestSchemaVersion;
const openSessionFile = authority.openSessionFile;
const readOptionalSessionFile = authority.readOptionalSessionFile;
const requireAuthorityFenceAbsent = authority.requireAuthorityFenceAbsent;
const CandidateStorage = types.CandidateStorage;
const DiscoveryCause = types.DiscoveryCause;
const ProjectionState = types.ProjectionState;
const SessionSummary = types.SessionSummary;
const StorageFormat = types.StorageFormat;
const automatic_legacy_max_bytes = types.automatic_legacy_max_bytes;

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

pub const ReadOnlyCandidate = struct {
    summary: SessionSummary,
    storage: CandidateStorage,
    projection_state: ProjectionState,
    subagent_child: ?bool = null,

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

/// Classifies a session directory into a read-only candidate, dispatching on
/// its authority state to the schema-v3 or legacy classifier.
pub fn classifyReadOnlyCandidate(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !ReadOnlyCandidate {
    return classifyReadOnlyCandidateWithCancellation(alloc, session_dir, session_id, null);
}

pub fn classifyReadOnlyCandidateCancellable(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancelled: *const std.atomic.Value(bool),
) !ReadOnlyCandidate {
    return classifyReadOnlyCandidateWithCancellation(alloc, session_dir, session_id, cancelled);
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

/// Listing's recovery of a schema-v3 session whose manifest is missing or
/// cannot be read: its committed log is the authority, so the summary is
/// replayed from it, as latest selection always did. Returns null when the
/// session is not schema-v3, sits behind an interrupted upgrade (the route
/// classification refuses it), or its log cannot be replayed either, leaving
/// the caller to report the classification error.
pub fn recoverSchemaV3Candidate(
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

/// Replaces the log-derived fields of a schema-v3 candidate with a replay of
/// its committed log and marks it replayed. Returns false, leaving the
/// candidate unchanged, when the log cannot be replayed.
fn replayCommittedLog(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    candidate: *ReadOnlyCandidate,
    cancelled: ?*const std.atomic.Value(bool),
) !bool {
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
fn logDiscovery(
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

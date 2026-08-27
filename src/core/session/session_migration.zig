const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");

const AuthorityTransition = authority_module.AuthorityTransition;
const deleteSessionEntry = authority_module.deleteSessionEntry;
const entryExistsRelative = authority_module.entryExistsRelative;
const eventFileStat = authority_module.eventFileStat;
const exactJsonObject = authority_module.exactJsonObject;
const jsonU64 = authority_module.jsonU64;
const loadAuthorityMarkerOptional = authority_module.loadAuthorityMarkerOptional;
const mapReplayError = authority_module.mapReplayError;
const objectString = authority_module.objectString;
const openSessionFile = authority_module.openSessionFile;
const parseIdentifier = authority_module.parseIdentifier;
const positionsEqual = authority_module.positionsEqual;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const readOptionalSessionFile = authority_module.readOptionalSessionFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
const LoadedWritableSession = types.LoadedWritableSession;
const ResumeOptions = types.ResumeOptions;
const automatic_legacy_max_bytes = types.automatic_legacy_max_bytes;
const StoreContext = types.StoreContext;

pub const LegacyStoredSession = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history: []session.HistoryTurn,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,

    /// Frees owned session fields and history turns.
    pub fn deinit(self: *LegacyStoredSession, alloc: Allocator) void {
        if (self.id.len > 0) alloc.free(self.id);
        if (self.workspace_root) |wr| alloc.free(wr);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

pub const MigrationPreferenceSource = enum {
    requesting_workspace,
    preserved_workspace,
};

const MigrationCanonical = struct {
    events: []u8,
    watermark: []u8,
    watermark_name: []u8,
    checkpoint: []u8,
    authority: []u8,
    intent: []u8,
    authority_id: session_event.Identifier,
    position: session_log.CommitPosition,
    generation_base_bytes: u64,

    fn deinit(self: *MigrationCanonical, alloc: Allocator) void {
        alloc.free(self.events);
        alloc.free(self.watermark);
        alloc.free(self.watermark_name);
        alloc.free(self.checkpoint);
        alloc.free(self.authority);
        alloc.free(self.intent);
        self.* = undefined;
    }
};

const RandomEventIds = struct {
    fn next(_: *anyopaque) session_event.Identifier {
        return randomIdentifier();
    }
};

fn runBoundary(test_controls: session_log.TestControls, boundary: session_log.Boundary) !void {
    try test_controls.boundary(boundary);
}

/// Migrates legacy state to schema v3 while the caller holds the writer lock.
/// Commit order is fixed: migration fence, stable snapshot, projection write,
/// unchanged recheck, then intent, marker, manifest, validation, and intent removal.
/// Resume handles partial disk state. Ownership transfers only on success.
pub fn migrateLegacyLocked(
    ctx: StoreContext,
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    workspace_root: []const u8,
    preference_source: MigrationPreferenceSource,
    options: ResumeOptions,
    lifecycle: *?session_log.CommitLifecycle,
) !LoadedWritableSession {
    try assertMigratable(
        alloc,
        writable,
        options.log.commit_lock_deadline_ms,
    );

    var primary = try openSessionFile(&writable.dir, "session.json", .read_only);
    defer primary.close(io_mod.getIo());
    const primary_stat = try primary.stat(io_mod.getIo());
    const allowed_size = if (options.allow_large_legacy)
        primary_stat.size
    else
        automatic_legacy_max_bytes;
    if (primary_stat.size > allowed_size) return error.LegacySessionTooLarge;
    const primary_bytes = readExactLegacyFile(
        alloc,
        &primary,
        primary_stat.size,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
        else => return error.LegacySessionMigrationFailed,
    };
    defer alloc.free(primary_bytes);
    const primary_digest = session_projection.sha256(primary_bytes);
    const schema = session_json.parseLegacySchemaVersion(
        alloc,
        primary_bytes,
    ) catch |err| return err;

    try ensureStableLegacyCopy(alloc, writable, primary_bytes, primary_stat.size);

    var legacy = session_json.parseLegacyExact(
        LegacyStoredSession,
        alloc,
        primary_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
        else => return err,
    };
    errdefer legacy.deinit(alloc);
    if (!std.mem.eql(u8, legacy.id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    const legacy_had_workspace = legacy.workspace_root != null;
    var state = try legacyToDurableState(
        ctx,
        alloc,
        &legacy,
        workspace_root,
        preference_source,
        options.seed_preferences,
    );
    errdefer state.deinit(alloc);
    if (!legacy_had_workspace) {
        if (!std.mem.eql(u8, state.workspace_root, workspace_root)) {
            return error.InvalidDurableField;
        }
    }
    if (lifecycle.*) |*value| {
        try value.prepare(
            alloc,
            writable.session_id,
            state.workspace_root,
            state.workspace_root,
            options.log.commit_lock_deadline_ms,
        );
    }

    var canonical = try buildMigrationCanonical(
        alloc,
        state,
        schema,
        primary_bytes,
    );
    defer canonical.deinit(alloc);

    const manifest = try writeCanonicalProjection(alloc, writable, state, canonical);
    defer alloc.free(manifest);

    try assertLegacyUnchanged(alloc, writable, primary_stat.size, primary_digest);

    try commitMigrationAuthorityLocked(alloc, writable, canonical, manifest, options);

    var root = ctx.canonical_root;
    var replayed = root.loadReadOnly(
        alloc,
        writable.session_id,
        options.log,
    ) catch |err| return mapReplayError(err);
    state.deinit(alloc);
    state = replayed;
    replayed = undefined;
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    var result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .log = writable.*,
        .position = canonical.position,
        .authority_id = canonical.authority_id,
        .generation_base_seq = 1,
        .generation_base_bytes = canonical.generation_base_bytes,
        .checkpoint_seq = canonical.position.through_seq,
        .checkpoint_sha256 = session_projection.sha256(canonical.checkpoint),
        .projection_status = .current,
        .migration_source_schema_version = @intFromEnum(schema),
        .migration_source_bytes = primary_stat.size,
        .commit_lifecycle = lifecycle.*,
    };
    lifecycle.* = null;
    writable.* = undefined;
    _ = result.publishCommitLifecycle(alloc);
    return result;
}

/// Asserts the session may be migrated: takes the commit lock, requires no
/// pending authority fence, and rejects a directory that already owns a
/// schema-v3 authority marker. Releases the lock before returning.
fn assertMigratable(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    commit_lock_deadline_ms: u64,
) !void {
    var commit_lock = io_mod.acquireTimedAdvisoryLock(
        &writable.dir,
        "commit.lock",
        commit_lock_deadline_ms,
    ) catch |err| switch (err) {
        error.LockBusy, error.LockUnsupported => return error.SessionCommitBoundaryUnavailable,
        else => return error.LegacySessionMigrationFailed,
    };
    defer commit_lock.release();
    try requireAuthorityFenceAbsent(alloc, &writable.dir, writable.session_id);
    if (try entryExistsRelative(&writable.dir, "authority.json")) {
        return error.InvalidSessionFormat;
    }
}

/// Ensures `session.legacy.json` holds an exact copy of the primary snapshot,
/// writing it durably if absent and rejecting a mismatched existing copy. This
/// is the rollback source if the authority swap is interrupted.
fn ensureStableLegacyCopy(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    primary_bytes: []const u8,
    primary_size: u64,
) !void {
    if (try readOptionalSessionFile(
        alloc,
        &writable.dir,
        "session.legacy.json",
        std.math.cast(usize, primary_size + 1) orelse
            return error.LegacySessionMigrationResourceExhausted,
    )) |existing_copy| {
        defer alloc.free(existing_copy);
        if (!std.mem.eql(u8, existing_copy, primary_bytes)) {
            return error.InvalidSessionFormat;
        }
    } else {
        io_mod.durableReplaceVerified(
            alloc,
            &writable.dir,
            "session.legacy.json",
            primary_bytes,
        ) catch return error.LegacySessionMigrationFailed;
    }
}

/// Durably writes the canonical projection files (event log, watermark,
/// checkpoint) and returns the encoded manifest bytes for the caller to commit.
/// Caller owns and frees the returned slice.
fn writeCanonicalProjection(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    state: session_codec.DurableSessionState,
    canonical: MigrationCanonical,
) ![]u8 {
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "events.jsonl",
        canonical.events,
    ) catch return error.LegacySessionMigrationFailed;
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        canonical.watermark_name,
        canonical.watermark,
    ) catch return error.LegacySessionMigrationFailed;
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "checkpoint.json",
        canonical.checkpoint,
    ) catch return error.LegacySessionMigrationFailed;
    return encodeMigrationManifest(
        alloc,
        &writable.dir,
        state,
        canonical,
    ) catch return error.LegacySessionMigrationFailed;
}

/// Re-reads the primary snapshot and fails with `error.LegacySessionChanged`
/// if its size or digest no longer matches what was staged, guarding against a
/// concurrent writer between staging and commit.
fn assertLegacyUnchanged(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    primary_size: u64,
    primary_digest: session_projection.Digest,
) !void {
    var current_primary = try openSessionFile(
        &writable.dir,
        "session.json",
        .read_only,
    );
    defer current_primary.close(io_mod.getIo());
    const current_stat = try current_primary.stat(io_mod.getIo());
    if (current_stat.size != primary_size) return error.LegacySessionChanged;
    const current_bytes = readExactLegacyFile(
        alloc,
        &current_primary,
        current_stat.size,
    ) catch return error.LegacySessionChanged;
    defer alloc.free(current_bytes);
    const current_digest = session_projection.sha256(current_bytes);
    if (!std.mem.eql(u8, &current_digest, &primary_digest)) {
        return error.LegacySessionChanged;
    }
}

/// Atomically swaps legacy authority to schema-v3 under the commit lock:
/// intent -> marker -> manifest -> validate -> drop intent, each step gated by
/// a crash-injection test boundary. Once the marker is written, failures map to
/// `LegacySessionMigrationIndeterminate` so recovery re-runs validation rather
/// than restarting. Releases the lock before returning.
fn commitMigrationAuthorityLocked(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    canonical: MigrationCanonical,
    manifest: []const u8,
    options: ResumeOptions,
) !void {
    var commit_lock = io_mod.acquireTimedAdvisoryLock(
        &writable.dir,
        "commit.lock",
        options.log.commit_lock_deadline_ms,
    ) catch |err| switch (err) {
        error.LockBusy, error.LockUnsupported => return error.SessionCommitBoundaryUnavailable,
        else => return error.LegacySessionMigrationFailed,
    };
    defer commit_lock.release();
    try requireAuthorityFenceAbsent(alloc, &writable.dir, writable.session_id);
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "authority.pending.json",
        canonical.intent,
    ) catch return error.LegacySessionMigrationFailed;
    runBoundary(options.log.test_controls, .after_authority_intent_sync) catch
        return error.LegacySessionMigrationIndeterminate;
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "authority.json",
        canonical.authority,
    ) catch return error.LegacySessionMigrationIndeterminate;
    runBoundary(options.log.test_controls, .after_authority_marker_rename) catch
        return error.LegacySessionMigrationIndeterminate;
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "session.json",
        manifest,
    ) catch return error.LegacySessionMigrationIndeterminate;
    io_mod.syncVerifiedDir(writable.dir.dir) catch
        return error.LegacySessionMigrationIndeterminate;
    var validated_state = try validateMigrationTarget(
        alloc,
        &writable.dir,
        writable.session_id,
        canonical.authority_id,
        canonical.position,
    );
    validated_state.deinit(alloc);
    runBoundary(options.log.test_controls, .after_authority_namespace_sync) catch
        return error.LegacySessionMigrationIndeterminate;
    deleteSessionEntry(&writable.dir, "authority.pending.json") catch
        return error.SessionAuthorityIntentCleanupPending;
    runBoundary(options.log.test_controls, .after_authority_intent_remove) catch
        return error.SessionAuthorityIntentCleanupPending;
}

fn buildMigrationCanonical(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    schema: session_json.LegacySchemaVersion,
    primary_bytes: []const u8,
) !MigrationCanonical {
    const generation = randomIdentifier();
    const first_event_id = randomIdentifier();
    const authority_id = randomIdentifier();
    const started = session_event.Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = first_event_id,
        .timestamp_ms = state.created_at_ms,
        .event = .{ .session_started = .{
            .id = state.id,
            .created_at_ms = state.created_at_ms,
            .origin_workspace_root = state.origin_workspace_root,
            .workspace_root = state.workspace_root,
            .conversation_language = state.conversation_language,
            .preferences = state.preferences,
            .usage = state.usage,
        } },
    };
    const first_line = try session_event.encodeFrame(alloc, started);
    defer alloc.free(first_line);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(first_line);
    var random_ids: u8 = 0;
    const replacement = try session_event.writeStateReplacement(
        alloc,
        &out.writer,
        state,
        .{
            .log_generation = generation,
            .first_seq = 2,
            .replacement_id = randomIdentifier(),
            .event_ids = .{
                .context = &random_ids,
                .next_fn = RandomEventIds.next,
            },
            .timestamp_ms = state.updated_at_ms,
            .reason = .migration,
        },
    );
    const events = try out.toOwnedSlice();
    errdefer alloc.free(events);
    const position = session_log.CommitPosition{
        .log_generation = generation,
        .through_seq = replacement.last_seq,
        .through_event_id = replacement.last_event_id,
        .through_event_log_bytes = events.len,
    };
    const watermark = try encodeMigrationWatermark(alloc, state.id, position);
    errdefer alloc.free(watermark);
    const watermark_name = try migrationWatermarkName(alloc, generation);
    errdefer alloc.free(watermark_name);

    const checkpoint_value = session_projection.Checkpoint{
        .session_id = state.id,
        .log_generation = generation,
        .through_seq = position.through_seq,
        .through_event_id = position.through_event_id,
        .through_event_log_bytes = position.through_event_log_bytes,
        .state = state,
    };
    const checkpoint = try session_projection.encodeCheckpoint(alloc, checkpoint_value);
    errdefer alloc.free(checkpoint);
    const authority = try encodeMigrationAuthority(
        alloc,
        state.id,
        authority_id,
    );
    errdefer alloc.free(authority);
    const intent = try encodeMigrationIntent(
        alloc,
        state.id,
        schema,
        primary_bytes,
        authority_id,
        position,
    );
    errdefer alloc.free(intent);
    return .{
        .events = events,
        .watermark = watermark,
        .watermark_name = watermark_name,
        .checkpoint = checkpoint,
        .authority = authority,
        .intent = intent,
        .authority_id = authority_id,
        .position = position,
        .generation_base_bytes = first_line.len,
    };
}

fn encodeMigrationManifest(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    state: session_codec.DurableSessionState,
    canonical: MigrationCanonical,
) ![]u8 {
    const stat = try eventFileStat(session_dir, "events.jsonl");
    const fingerprint = try session_projection.eventFileStatFingerprint(
        stat,
        canonical.position.through_event_log_bytes,
    );
    return session_projection.encodeManifest(alloc, .{
        .id = state.id,
        .authority_id = canonical.authority_id,
        .log_generation = canonical.position.log_generation,
        .created_at_ms = state.created_at_ms,
        .updated_at_ms = state.updated_at_ms,
        .origin_workspace_root = state.origin_workspace_root,
        .workspace_root = state.workspace_root,
        .conversation_language = state.conversation_language,
        .history_len = state.history.len,
        .total_input_tokens = state.total_input_tokens,
        .total_output_tokens = state.total_output_tokens,
        .last_event_seq = canonical.position.through_seq,
        .event_log_bytes = canonical.position.through_event_log_bytes,
        .event_log_stat_fingerprint = fingerprint,
        .generation_base_seq = 1,
        .generation_base_bytes = canonical.generation_base_bytes,
        .checkpoint_seq = canonical.position.through_seq,
        .checkpoint_sha256 = session_projection.sha256(canonical.checkpoint),
        .preferences = state.preferences,
    });
}

fn encodeMigrationWatermark(
    alloc: Allocator,
    session_id: []const u8,
    position: session_log.CommitPosition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const generation = std.fmt.bytesToHex(position.log_generation, .lower);
    const event_id = std.fmt.bytesToHex(position.through_event_id, .lower);
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.print(
        ",\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}\n",
        .{
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
    return out.toOwnedSlice();
}

fn migrationWatermarkName(
    alloc: Allocator,
    generation: session_event.Identifier,
) ![]u8 {
    const hex = std.fmt.bytesToHex(generation, .lower);
    return std.fmt.allocPrint(alloc, "commit.{s}.json", .{hex});
}

fn encodeMigrationAuthority(
    alloc: Allocator,
    session_id: []const u8,
    authority_id: session_event.Identifier,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const authority = std.fmt.bytesToHex(authority_id, .lower);
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.print(
        ",\"authority_id\":\"{s}\",\"storage_format\":\"event_log_v1\",\"source\":\"legacy_migration\"}}\n",
        .{authority},
    );
    return out.toOwnedSlice();
}

fn encodeMigrationIntent(
    alloc: Allocator,
    session_id: []const u8,
    schema: session_json.LegacySchemaVersion,
    primary_bytes: []const u8,
    authority_id: session_event.Identifier,
    position: session_log.CommitPosition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const operation = std.fmt.bytesToHex(randomIdentifier(), .lower);
    const authority = std.fmt.bytesToHex(authority_id, .lower);
    const digest = std.fmt.bytesToHex(session_projection.sha256(primary_bytes), .lower);
    const generation = std.fmt.bytesToHex(position.log_generation, .lower);
    const event_id = std.fmt.bytesToHex(position.through_event_id, .lower);
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.print(
        ",\"operation_id\":\"{s}\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"{s}\",\"prior\":{{\"storage_format\":\"legacy_snapshot_v{d}\",\"primary_bytes\":{d},\"primary_sha256\":\"{s}\"}},\"proposed\":{{\"storage_format\":\"event_log_v1\",\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}}}\n",
        .{
            operation,
            authority,
            @intFromEnum(schema),
            primary_bytes.len,
            digest,
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
    return out.toOwnedSlice();
}

/// Validates that an on-disk schema-v3 target exactly matches a proposed
/// commit position (marker, manifest, event fingerprint, watermark, replay,
/// checkpoint). Returns the replayed state on success; any mismatch yields
/// `error.LegacySessionMigrationIndeterminate`. Caller owns the returned state.
pub fn validateMigrationTarget(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    authority_id: session_event.Identifier,
    position: session_log.CommitPosition,
) !session_codec.DurableSessionState {
    var marker = (try loadAuthorityMarkerOptional(alloc, session_dir)) orelse
        return error.LegacySessionMigrationIndeterminate;
    defer marker.deinit(alloc);
    if (!std.mem.eql(u8, marker.session_id, session_id) or
        !std.mem.eql(u8, &marker.authority_id, &authority_id) or
        marker.source != .legacy_migration)
    {
        return error.LegacySessionMigrationIndeterminate;
    }
    const manifest_bytes = (try readOptionalSessionFile(
        alloc,
        session_dir,
        "session.json",
        session_projection.manifest_max_bytes,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(manifest_bytes);
    var manifest = session_projection.decodeManifest(alloc, manifest_bytes) catch
        return error.LegacySessionMigrationIndeterminate;
    defer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &authority_id) or
        !std.mem.eql(u8, &manifest.log_generation, &position.log_generation) or
        manifest.last_event_seq != position.through_seq or
        manifest.event_log_bytes != position.through_event_log_bytes)
    {
        return error.LegacySessionMigrationIndeterminate;
    }
    var events = try openSessionFile(session_dir, "events.jsonl", .read_only);
    defer events.close(io_mod.getIo());
    const events_stat = try eventFileStat(session_dir, "events.jsonl");
    const fingerprint = session_projection.eventFileStatFingerprint(
        events_stat,
        position.through_event_log_bytes,
    ) catch return error.LegacySessionMigrationIndeterminate;
    if (!std.mem.eql(
        u8,
        &fingerprint,
        &manifest.event_log_stat_fingerprint,
    )) {
        return error.LegacySessionMigrationIndeterminate;
    }
    const watermark_name = try migrationWatermarkName(alloc, position.log_generation);
    defer alloc.free(watermark_name);
    const watermark = (try readOptionalSessionFile(
        alloc,
        session_dir,
        watermark_name,
        16 * 1024,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(watermark);
    const watermark_position = decodeMigrationWatermark(
        alloc,
        watermark,
        session_id,
    ) catch return error.LegacySessionMigrationIndeterminate;
    if (!positionsEqual(watermark_position, position)) {
        return error.LegacySessionMigrationIndeterminate;
    }
    var state = replayMigrationEvents(
        alloc,
        events,
        position,
    ) catch return error.LegacySessionMigrationIndeterminate;
    errdefer state.deinit(alloc);
    if (!session_projection.stateMatchesManifest(state, manifest)) {
        return error.LegacySessionMigrationIndeterminate;
    }

    const checkpoint_bytes = (try readOptionalSessionFile(
        alloc,
        session_dir,
        "checkpoint.json",
        session_projection.checkpoint_max_bytes,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(checkpoint_bytes);
    var checkpoint = session_projection.decodeCheckpoint(
        alloc,
        checkpoint_bytes,
    ) catch return error.LegacySessionMigrationIndeterminate;
    defer checkpoint.deinit(alloc);
    const boundary = session_projection.EventBoundary{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_id = position.through_event_id,
        .event_log_bytes = position.through_event_log_bytes,
        .semantic = true,
    };
    session_projection.validateCheckpointReference(
        manifest,
        checkpoint_bytes,
        checkpoint,
        boundary,
        boundary,
    ) catch return error.LegacySessionMigrationIndeterminate;
    return state;
}

/// Assembles a `LoadedWritableSession` from an already-committed migration
/// target, reading manifest metadata and carrying source schema/bytes from the
/// transition. Consumes `writable`.
pub fn loadedMigrationTarget(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    state: session_codec.DurableSessionState,
    transition: AuthorityTransition,
) !LoadedWritableSession {
    const manifest_bytes = (try readOptionalSessionFile(
        alloc,
        &writable.dir,
        "session.json",
        session_projection.manifest_max_bytes,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(manifest_bytes);
    var manifest = session_projection.decodeManifest(
        alloc,
        manifest_bytes,
    ) catch return error.LegacySessionMigrationIndeterminate;
    defer manifest.deinit(alloc);
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    const source_schema_version: ?u8 = if (transition.prior) |prior|
        @intFromEnum(prior.schema)
    else
        null;
    const source_bytes: ?u64 = if (transition.prior) |prior|
        prior.primary_bytes
    else
        null;
    const loaded = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .log = writable.*,
        .position = transition.proposed,
        .authority_id = transition.authority_id,
        .generation_base_seq = manifest.generation_base_seq,
        .generation_base_bytes = manifest.generation_base_bytes,
        .checkpoint_seq = manifest.checkpoint_seq,
        .checkpoint_sha256 = manifest.checkpoint_sha256,
        .projection_status = .current,
        .migration_source_schema_version = source_schema_version,
        .migration_source_bytes = source_bytes,
    };
    writable.* = undefined;
    return loaded;
}

fn decodeMigrationWatermark(
    alloc: Allocator,
    bytes: []const u8,
    session_id: []const u8,
) !session_log.CommitPosition {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch return error.InvalidSessionFormat;
    defer parsed.deinit();
    const expected_keys = [_][]const u8{
        "schema_version",
        "session_id",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    };
    const object = try exactJsonObject(parsed.value, &expected_keys);
    if (try jsonU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try objectString(object, "session_id"), session_id))
    {
        return error.InvalidSessionFormat;
    }
    return .{
        .log_generation = try parseIdentifier(
            try objectString(object, "log_generation"),
        ),
        .through_seq = try jsonU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(
            try objectString(object, "through_event_id"),
        ),
        .through_event_log_bytes = try jsonU64(
            object,
            "through_event_log_bytes",
        ),
    };
}

const EventLine = struct {
    bytes: []u8,
    next_offset: u64,
};

fn readEventLineAt(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
) !?EventLine {
    if (offset >= max_end) return null;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    var cursor = offset;
    var chunk: [8192]u8 = undefined;
    while (cursor < max_end) {
        const limit = @min(@as(u64, chunk.len), max_end - cursor);
        const count = try file.readPositionalAll(
            io_mod.getIo(),
            chunk[0..@intCast(limit)],
            cursor,
        );
        if (count == 0) return error.InvalidSessionFormat;
        if (std.mem.findScalar(u8, chunk[0..count], '\n')) |newline| {
            try line.appendSlice(alloc, chunk[0 .. newline + 1]);
            cursor += newline + 1;
            if (line.items.len > session_event.event_frame_max_bytes) {
                return error.InvalidSessionFormat;
            }
            return .{
                .bytes = try line.toOwnedSlice(alloc),
                .next_offset = cursor,
            };
        }
        try line.appendSlice(alloc, chunk[0..count]);
        if (line.items.len > session_event.event_frame_max_bytes) {
            return error.InvalidSessionFormat;
        }
        cursor += count;
    }
    return error.InvalidSessionFormat;
}

fn replayMigrationEvents(
    alloc: Allocator,
    file: std.Io.File,
    position: session_log.CommitPosition,
) !session_codec.DurableSessionState {
    const length = try file.length(io_mod.getIo());
    if (position.through_event_log_bytes == 0 or
        length < position.through_event_log_bytes)
    {
        return error.InvalidSessionFormat;
    }
    var validator: session_event.SequenceValidator = .{};
    var offset: u64 = 0;
    var last_seq: u64 = 0;
    var last_event_id: session_event.Identifier = undefined;
    var replacement_open = false;
    var replacement_id: session_event.Identifier = undefined;
    while (offset < position.through_event_log_bytes) {
        const line = try readEventLineAt(
            alloc,
            file,
            offset,
            position.through_event_log_bytes,
        ) orelse return error.InvalidSessionFormat;
        defer alloc.free(line.bytes);
        var envelope = session_event.decodeFrame(
            alloc,
            line.bytes,
        ) catch |err| switch (err) {
            error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
            else => return error.InvalidSessionFormat,
        };
        defer envelope.deinit(alloc);
        validator.validate(envelope) catch return error.InvalidSessionFormat;
        if (!std.mem.eql(
            u8,
            &envelope.log_generation,
            &position.log_generation,
        )) {
            return error.InvalidSessionFormat;
        }
        switch (envelope.event) {
            .state_replacement_started => |start| {
                if (replacement_open) return error.InvalidSessionFormat;
                replacement_open = true;
                replacement_id = start.replacement_id;
            },
            .state_replacement_chunk => |chunk| {
                if (!replacement_open or
                    !std.mem.eql(
                        u8,
                        &replacement_id,
                        &chunk.replacement_id,
                    ))
                {
                    return error.InvalidSessionFormat;
                }
            },
            .state_replacement_committed => |commit| {
                if (!replacement_open or
                    !std.mem.eql(
                        u8,
                        &replacement_id,
                        &commit.replacement_id,
                    ))
                {
                    return error.InvalidSessionFormat;
                }
                replacement_open = false;
                last_seq = envelope.seq;
                last_event_id = envelope.event_id;
            },
            else => {
                if (replacement_open) return error.InvalidSessionFormat;
                last_seq = envelope.seq;
                last_event_id = envelope.event_id;
            },
        }
        offset = line.next_offset;
    }
    if (offset != position.through_event_log_bytes or
        replacement_open or
        last_seq != position.through_seq or
        !std.mem.eql(u8, &last_event_id, &position.through_event_id))
    {
        return error.InvalidSessionFormat;
    }

    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &file_buffer);
    var limit_buffer: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(
        .limited64(position.through_event_log_bytes),
        &limit_buffer,
    );
    var reduction = session_event.reduceJsonl(
        alloc,
        &limited.interface,
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
    errdefer reduction.deinit(alloc);
    if (reduction.truncate_from != null) return error.InvalidSessionFormat;
    const state = reduction.state;
    reduction.state = undefined;
    return state;
}

/// Converts a parsed legacy session into a validated `DurableSessionState`,
/// resolving the origin/current workspace roots and merging preferences from
/// the requested or preserved workspace. Consumes `legacy` (transfers its
/// owned id/history into the returned state).
pub fn legacyToDurableState(
    ctx: StoreContext,
    alloc: Allocator,
    legacy: *LegacyStoredSession,
    requesting_workspace: []const u8,
    preference_source: MigrationPreferenceSource,
    seed_preferences: ?session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionState {
    const root = legacy.workspace_root orelse ctx.workspace_root;
    try validateWorkspaceRoot(root);
    const origin = if (legacy.workspace_root != null)
        legacy.workspace_root.?
    else
        try alloc.dupe(u8, root);
    errdefer if (legacy.workspace_root == null) alloc.free(origin);
    const current = try alloc.dupe(u8, root);
    errdefer alloc.free(current);
    const preferences = try loadMigrationPreferences(
        ctx,
        alloc,
        switch (preference_source) {
            .requesting_workspace => requesting_workspace,
            .preserved_workspace => root,
        },
        seed_preferences,
    );
    errdefer {
        var owned = preferences;
        owned.deinit(alloc);
    }
    const state = session_codec.DurableSessionState{
        .id = legacy.id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = legacy.created_at_ms,
        .updated_at_ms = legacy.updated_at_ms,
        .conversation_language = legacy.conversation_language,
        .preferences = preferences,
        .history = legacy.history,
        .total_input_tokens = legacy.total_input_tokens,
        .total_output_tokens = legacy.total_output_tokens,
    };
    legacy.id = &.{};
    legacy.workspace_root = null;
    legacy.history = &.{};
    try session_codec.validateState(state);
    return state;
}

fn loadMigrationPreferences(
    ctx: StoreContext,
    alloc: Allocator,
    workspace_root: []const u8,
    seed_preferences: ?session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionPreferences {
    if (seed_preferences) |preferences| return preferences.dupe(alloc);
    var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
        alloc,
        ctx.home_dir,
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

fn randomIdentifier() session_event.Identifier {
    var id: session_event.Identifier = undefined;
    io_mod.getIo().random(&id);
    return id;
}

/// Reads the retained `session.legacy.json` to report the migrated source
/// schema version. Used to populate `SessionMigrationResult` after the fact.
pub fn migratedSourceSchemaVersion(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    allow_large: bool,
) !u8 {
    const source_bytes = try migratedSourceBytes(session_dir);
    const max_bytes = if (allow_large)
        (std.math.cast(usize, source_bytes + 1) orelse return error.LegacySessionMigrationResourceExhausted)
    else
        automatic_legacy_max_bytes + 1;
    const bytes = (try readOptionalSessionFile(
        alloc,
        session_dir,
        "session.legacy.json",
        max_bytes,
    )) orelse return error.SessionNotFound;
    defer alloc.free(bytes);
    return @intFromEnum(try session_json.parseLegacySchemaVersion(alloc, bytes));
}

/// Returns the byte size of the retained `session.legacy.json` source.
pub fn migratedSourceBytes(session_dir: *io_mod.VerifiedDir) !u64 {
    const stat = try session_dir.dir.statFile(
        io_mod.getIo(),
        "session.legacy.json",
        .{ .follow_symlinks = false },
    );
    return stat.size;
}

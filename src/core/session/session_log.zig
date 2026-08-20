const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session = @import("session.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");
const session_event = @import("session_event.zig");
const session_layout = @import("session_layout.zig");
const session_projection = @import("session_projection.zig");
const session_replay = @import("session_replay.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_resume_view = @import("session_resume_view.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const lock_deadline_ms: u64 = 2000;
const authority_max_bytes: usize = 16 * 1024;
const authority_intent_max_bytes: usize = 32 * 1024;
const watermark_max_bytes: usize = 16 * 1024;
const publication_intent_max_bytes: usize = 32 * 1024;
const events_file = "events.jsonl";
const authority_file = "authority.json";
const authority_intent_file = "authority.pending.json";
const publication_intent_file = "commit.pending.json";
const manifest_file = "session.json";
const checkpoint_file = "checkpoint.json";
const session_lock_file = "session.lock";
const commit_lock_file = "commit.lock";

pub const Boundary = enum {
    after_event_append,
    after_event_sync,
    after_commit_intent_sync,
    after_watermark_rename,
    after_target_namespace_sync,
    before_usage_sidecar_write,
    after_commit_intent_remove,
    after_authority_intent_sync,
    after_authority_marker_rename,
    after_authority_namespace_sync,
    after_authority_intent_remove,
    after_compaction_temp_sync,
    after_compaction_watermark_sync,
    after_compaction_intent_sync,
    after_compaction_log_rename,
    after_compaction_namespace_sync,
    after_compaction_live_confirmation,
    after_compaction_intent_remove,
    after_latest_cache_pending,
    before_latest_cache_ready,
    before_recovery_proposed_validation,
    before_recovery_prior_validation,
    after_recovery_latest_snapshot,
    before_recovery_latest_publication,
    latest_barrier_contended,
    latest_barrier_completed,
};

pub const LockKind = enum {
    session,
    commit,
};

pub const TestControls = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (?*anyopaque, Boundary) anyerror!void = null,
    lock_fn: ?*const fn (?*anyopaque, LockKind) void = null,

    pub fn boundary(self: TestControls, point: Boundary) !void {
        if (self.boundary_fn) |callback| try callback(self.context, point);
    }

    fn lock(self: TestControls, kind: LockKind) void {
        if (self.lock_fn) |callback| callback(self.context, kind);
    }
};

pub const Options = struct {
    test_controls: TestControls = .{},
    session_lock_deadline_ms: u64 = lock_deadline_ms,
    commit_lock_deadline_ms: u64 = lock_deadline_ms,
    checkpoint_interval: u64 = 32,
    compaction_frame_threshold: u64 = 4096,
    compaction_byte_threshold: u64 = 128 * 1024 * 1024,
    resolve_authority_intent: bool = true,
};

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const CommitPosition = session_replay.CommitPosition;

test {
    _ = session_replay;
}

pub const FailedTailDisposition = enum {
    retry_expected_tail,
    rollback_before_adapter_continue,
};

pub const FailedTailKind = union(enum) {
    event: Identifier,
    state_replacement: struct {
        replacement_id: Identifier,
        final_event_id: Identifier,
    },
};

pub const FailedTail = struct {
    prior: CommitPosition,
    proposed: CommitPosition,
    kind: FailedTailKind,
    bytes: []u8,
    sha256: session_projection.Digest,

    pub fn deinit(self: *FailedTail, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const PublicationKind = enum {
    watermark_advance,
    log_generation_replace,
};

pub const ProjectionStatus = enum {
    current,
    stale,
};

const ReplaySource = enum {
    checkpoint,
    event_log,
};

const OpenState = struct {
    state: session_codec.DurableSessionState,
    generation_base_seq: u64,
    generation_base_bytes: u64,
    checkpoint_seq: ?u64,
    checkpoint_sha256: ?session_projection.Digest,
    projection_status: ProjectionStatus,
    source: ReplaySource,
    tail_bytes: u64,
};

const CheckpointReplay = struct {
    state: session_codec.DurableSessionState,
    through_event_log_bytes: u64,
};

const OpenManifest = struct {
    manifest: session_projection.Manifest,
    event_file_matches: bool,
};

pub const CommitWatermarkStatus = enum {
    valid,
    missing,
    invalid,
    mismatched,
};

pub const CommitWatermarkInspection = struct {
    status: CommitWatermarkStatus,
    position: ?CommitPosition = null,
};

pub const CleanupMode = enum {
    report_only,
    delete,
};

pub const CleanupReport = struct {
    removed: usize = 0,
    report_only: usize = 0,
    ignored: usize = 0,
};

const AuthoritySource = enum {
    native_create,
    legacy_migration,
};

const AuthorityKind = enum {
    session_create,
    legacy_to_v3,
};

const AuthorityMarker = struct {
    session_id: []u8,
    authority_id: Identifier,
    source: AuthoritySource,

    fn deinit(self: *AuthorityMarker, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const LegacyFingerprint = struct {
    storage_format: []u8,
    primary_bytes: u64,
    primary_sha256: session_projection.Digest,

    fn deinit(self: *LegacyFingerprint, alloc: Allocator) void {
        alloc.free(self.storage_format);
        self.* = undefined;
    }
};

const AuthorityIntent = struct {
    session_id: []u8,
    operation_id: Identifier,
    kind: AuthorityKind,
    authority_id: Identifier,
    prior: ?LegacyFingerprint,
    proposed: CommitPosition,

    fn deinit(self: *AuthorityIntent, alloc: Allocator) void {
        alloc.free(self.session_id);
        if (self.prior) |*prior| prior.deinit(alloc);
        self.* = undefined;
    }
};

const PublicationIntent = struct {
    session_id: []u8,
    operation_id: Identifier,
    kind: PublicationKind,
    prior: CommitPosition,
    proposed: CommitPosition,

    fn deinit(self: *PublicationIntent, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const DecodedWatermark = struct {
    session_id: []u8,
    position: CommitPosition,

    fn deinit(self: *DecodedWatermark, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const WritableSessionDir = struct {
    dir: io_mod.VerifiedDir,
    writer_lock: ?io_mod.TimedAdvisoryLock,
    session_id: []u8,

    pub fn deinit(self: *WritableSessionDir, alloc: Allocator) void {
        if (self.writer_lock) |*lock| lock.release();
        self.dir.close();
        alloc.free(self.session_id);
        self.* = undefined;
    }

    pub fn isParked(self: *const WritableSessionDir) bool {
        return self.writer_lock == null;
    }

    /// Release `session.lock` while keeping the session directory open for a
    /// later `unpark` in the same process (idle job-control suspend).
    pub fn park(self: *WritableSessionDir) void {
        const lock = &(self.writer_lock orelse return);
        lock.release();
        self.writer_lock = null;
    }

    /// Reacquire `session.lock` after `park`. Fails with `SessionBusy` when
    /// another process already owns the writer lock.
    pub fn unpark(self: *WritableSessionDir) !void {
        if (self.writer_lock != null) return;
        self.writer_lock = acquireLock(&self.dir, session_lock_file, true) catch |err| {
            return mapSessionLockError(err);
        };
    }

    pub fn eventLogLengthForTest(self: *WritableSessionDir) !u64 {
        var file = try openManagedFile(&self.dir, events_file, .read_only);
        defer file.close(io_mod.getIo());
        return file.length(io_mod.getIo());
    }

    fn entryExistsForTest(self: *WritableSessionDir, name: []const u8) !bool {
        return entryExists(&self.dir, name);
    }
};

pub const ResumeViewAdmission = struct {
    writable: ?WritableSessionDir,
    view: session_resume_view.LoadOutcome,

    pub fn deinit(self: *ResumeViewAdmission, alloc: Allocator) void {
        if (self.writable) |*writable| writable.deinit(alloc);
        self.view.deinit(alloc);
        self.* = undefined;
    }

    pub fn sessionId(self: *const ResumeViewAdmission) []const u8 {
        return self.writable.?.session_id;
    }

    pub fn resumeForWrite(
        self: *ResumeViewAdmission,
        alloc: Allocator,
        options: Options,
    ) !LoadedWritableSession {
        var writable = self.writable orelse return error.SessionResumeAdmissionConsumed;
        self.writable = null;
        return openWritableSession(alloc, &writable, options) catch |err| {
            writable.deinit(alloc);
            return err;
        };
    }
};

pub const ReadBoundary = struct {
    log_file: std.Io.File,
    position: CommitPosition,
    usage_sidecar: session_usage_sidecar.Captured,
    alloc: Allocator,

    pub fn deinit(self: *ReadBoundary) void {
        self.log_file.close(io_mod.getIo());
        self.usage_sidecar.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Loads the exact manifest boundary while deliberately ignoring a corrupt
/// commit watermark. The source directory remains unchanged.
pub fn recoverManifestBoundary(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !session_codec.DurableSessionState {
    if (writable.writer_lock == null) return error.SessionBusy;
    try requireIntentAbsent(alloc, &writable.dir, authority_intent_file);
    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &writable.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
    ) catch |err| return mapCommitLockError(err);
    defer commit_lock.release();
    try requireIntentAbsent(alloc, &writable.dir, authority_intent_file);
    try requireIntentAbsent(alloc, &writable.dir, publication_intent_file);

    var authority = try loadAuthority(
        alloc,
        &writable.dir,
        writable.session_id,
    );
    defer authority.deinit(alloc);
    const watermark = try inspectCommitWatermark(
        alloc,
        &writable.dir,
        writable.session_id,
    );
    if (watermark.status == .valid) return error.SessionRecoveryNotNeeded;

    var manifest = try loadManifest(alloc, &writable.dir);
    defer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, writable.session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &authority.authority_id))
    {
        return error.InvalidSessionFormat;
    }

    var event_log = try openManagedFile(
        &writable.dir,
        events_file,
        .read_only,
    );
    defer event_log.close(io_mod.getIo());
    const stat = try eventStat(event_log, manifest.event_log_bytes);
    if (session_projection.isManifestStale(manifest, stat)) {
        return error.InvalidSessionFormat;
    }

    var replayed = try session_replay.replayExactBoundary(
        alloc,
        event_log,
        manifest.log_generation,
        manifest.last_event_seq,
        manifest.event_log_bytes,
    );
    errdefer replayed.deinit(alloc);
    if (!session_projection.stateMatchesManifest(replayed, manifest)) {
        return error.InvalidSessionFormat;
    }
    return replayed;
}

pub const CommitLifecycle = struct {
    context: ?*anyopaque = null,
    prepare_fn: ?*const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        []const u8,
        []const u8,
        u64,
    ) anyerror!void = null,
    publish_fn: ?*const fn (
        ?*anyopaque,
        Allocator,
        session_codec.DurableSessionState,
        CommitPosition,
    ) anyerror!void = null,
    write_deferred_fn: ?*const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        []const u8,
        CommitPosition,
    ) anyerror!void = null,
    abort_fn: ?*const fn (?*anyopaque) void = null,
    deinit_fn: ?*const fn (?*anyopaque, Allocator) void = null,

    pub fn prepare(
        self: *CommitLifecycle,
        alloc: Allocator,
        session_id: []const u8,
        previous_workspace_root: []const u8,
        next_workspace_root: []const u8,
        commit_lock_deadline_ms: u64,
    ) !void {
        if (self.prepare_fn) |callback| {
            callback(
                self.context,
                alloc,
                session_id,
                previous_workspace_root,
                next_workspace_root,
                commit_lock_deadline_ms,
            ) catch |err| return switch (err) {
                error.LatestCacheLockBusy => error.SessionCommitBoundaryUnavailable,
                else => err,
            };
        }
    }

    fn prepareOpportunistic(
        self: *CommitLifecycle,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        commit_lock_deadline_ms: u64,
    ) !bool {
        if (self.prepare_fn) |callback| {
            callback(
                self.context,
                alloc,
                session_id,
                workspace_root,
                workspace_root,
                commit_lock_deadline_ms,
            ) catch |err| return switch (err) {
                error.LatestCacheLockBusy => true,
                else => err,
            };
        }
        return false;
    }

    fn writeDeferred(
        self: *CommitLifecycle,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        position: CommitPosition,
    ) !void {
        if (self.write_deferred_fn) |callback| {
            try callback(
                self.context,
                alloc,
                session_id,
                workspace_root,
                position,
            );
        }
    }

    pub fn publish(
        self: *CommitLifecycle,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: CommitPosition,
    ) !void {
        if (self.publish_fn) |callback| {
            try callback(self.context, alloc, state, position);
        }
    }

    pub fn abort(self: *CommitLifecycle) void {
        if (self.abort_fn) |callback| callback(self.context);
    }

    pub fn deinit(self: *CommitLifecycle, alloc: Allocator) void {
        self.abort();
        if (self.deinit_fn) |callback| callback(self.context, alloc);
        self.* = undefined;
    }
};

pub const LoadedWritableSession = struct {
    pub const ExternalPromptOrigin = enum {
        root,
        persistent_child,
    };

    active_id: []u8,
    state: session_codec.DurableSessionState,
    log: WritableSessionDir,
    freshly_started: bool = false,
    state_replacement_pending: bool = false,
    child_capability: ?*session_child_store.SessionChildCapability = null,
    commit_lifecycle: ?CommitLifecycle = null,
    position: CommitPosition,
    authority_id: Identifier,
    generation_base_seq: u64,
    generation_base_bytes: u64,
    checkpoint_seq: ?u64 = null,
    checkpoint_sha256: ?session_projection.Digest = null,
    projection_status: ProjectionStatus = .current,
    namespace_confirmation_required: bool = false,
    degraded_tail: ?FailedTail = null,
    compaction_warning_active: bool = false,
    migration_source_schema_version: ?u8 = null,
    migration_source_bytes: ?u64 = null,
    usage_sidecar_reseal_pending: bool = false,
    resume_view_stale: bool = false,
    /// Runtime-only provenance installed by subagent resume admission. These
    /// fields are never written into the session event log.
    external_prompt_origin: ExternalPromptOrigin = .root,
    external_root_user_messages: [][]u8 = &.{},
    external_root_user_evidence_complete: bool = false,

    pub fn deinit(self: *LoadedWritableSession, alloc: Allocator) void {
        if (self.degraded_tail) |*tail| tail.deinit(alloc);
        if (self.commit_lifecycle) |*lifecycle| lifecycle.deinit(alloc);
        if (self.child_capability) |capability| {
            capability.deinit();
            alloc.destroy(capability);
        }
        for (self.external_root_user_messages) |message| alloc.free(message);
        if (self.external_root_user_messages.len > 0) {
            alloc.free(self.external_root_user_messages);
        }
        alloc.free(self.active_id);
        self.state.deinit(alloc);
        self.log.deinit(alloc);
        self.* = undefined;
    }

    pub fn writeResumeView(
        self: *LoadedWritableSession,
        alloc: Allocator,
        capture: session_resume_view.Capture,
        text: []const u8,
    ) !void {
        try session_resume_view.write(
            alloc,
            &self.log.dir,
            self.active_id,
            resumeViewBoundary(self.position),
            capture,
            text,
        );
    }

    /// Returns a borrowed address that remains stable until deinit.
    pub fn childCapability(
        self: *LoadedWritableSession,
    ) !*session_child_store.SessionChildCapability {
        return if (self.child_capability) |capability|
            capability
        else
            error.SessionChildCapabilityUnavailable;
    }

    pub fn installCommitLifecycle(
        self: *LoadedWritableSession,
        lifecycle: CommitLifecycle,
    ) !void {
        if (self.commit_lifecycle != null) return error.SessionCommitLifecycleAlreadyInstalled;
        self.commit_lifecycle = lifecycle;
    }

    pub fn appendEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: session_event.Event,
        timestamp_ms: i64,
        failed_tail: FailedTailDisposition,
        options: Options,
    ) !CommitPosition {
        const preserves_pristine_start = switch (event) {
            .usage_checkpointed,
            .recovery_checkpoint_set,
            .recovery_checkpoint_cleared,
            => true,
            else => false,
        };
        const replacement_was_pending = self.state_replacement_pending;
        const next_workspace_root = switch (event) {
            .workspace_rebound => |payload| payload.workspace_root,
            else => self.state.workspace_root,
        };
        const usage_sidecar_bytes = switch (event) {
            .usage_checkpointed => |payload| encodeUsageSidecarBestEffort(
                alloc,
                self.state.id,
                payload.usage,
            ),
            else => if (self.state.usage) |usage|
                encodeUsageSidecarBestEffort(
                    alloc,
                    self.state.id,
                    usage,
                )
            else
                null,
        };
        const write_usage_sidecar = switch (event) {
            .usage_checkpointed => true,
            else => self.usage_sidecar_reseal_pending,
        };
        defer if (usage_sidecar_bytes) |bytes| alloc.free(bytes);
        self.state_replacement_pending = true;
        const cache_deferred = switch (event) {
            .workspace_rebound => blk: {
                try self.prepareCommitLifecycle(alloc, next_workspace_root, options);
                break :blk false;
            },
            else => try self.prepareCommitLifecycleOpportunistic(alloc, options),
        };
        _ = appendEventImpl(
            self,
            alloc,
            event,
            timestamp_ms,
            failed_tail,
            options,
            usage_sidecar_bytes,
            write_usage_sidecar,
            cache_deferred,
        ) catch |err| {
            self.abortCommitLifecycle();
            return err;
        };
        if (!preserves_pristine_start) self.freshly_started = false;
        const lifecycle_published = !cache_deferred and self.publishCommitLifecycle(alloc);
        maintainCanonicalLogAfterCommit(self, alloc, options) catch |err| {
            self.state_replacement_pending = true;
            return err;
        };
        if (!lifecycle_published) {
            self.state_replacement_pending = true;
        } else {
            self.state_replacement_pending =
                self.state_replacement_pending and replacement_was_pending;
        }
        return self.position;
    }

    pub fn commitStateReplacement(
        self: *LoadedWritableSession,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        reason: session_event.ReplacementReason,
        failed_tail: FailedTailDisposition,
        options: Options,
    ) !CommitPosition {
        const usage_sidecar_bytes = if (state.usage) |usage|
            encodeUsageSidecarBestEffort(
                alloc,
                state.id,
                usage,
            )
        else
            null;
        defer if (usage_sidecar_bytes) |bytes| alloc.free(bytes);
        self.state_replacement_pending = true;
        const same_workspace = std.mem.eql(
            u8,
            self.state.workspace_root,
            state.workspace_root,
        );
        const may_defer_cache = same_workspace and switch (reason) {
            .compaction, .log_compaction => true,
            .migration, .recovery => false,
        };
        const cache_deferred = if (may_defer_cache)
            try self.prepareCommitLifecycleOpportunistic(alloc, options)
        else blk: {
            try self.prepareCommitLifecycle(alloc, state.workspace_root, options);
            break :blk false;
        };
        _ = commitStateReplacementImpl(
            self,
            alloc,
            state,
            reason,
            failed_tail,
            options,
            usage_sidecar_bytes,
            true,
            cache_deferred,
        ) catch |err| {
            self.abortCommitLifecycle();
            return err;
        };
        self.freshly_started = false;
        const lifecycle_published = !cache_deferred and self.publishCommitLifecycle(alloc);
        maintainCanonicalLogAfterCommit(self, alloc, options) catch |err| {
            self.state_replacement_pending = true;
            return err;
        };
        if (!lifecycle_published) self.state_replacement_pending = true;
        return self.position;
    }

    pub fn degradedTail(self: *const LoadedWritableSession) ?*const FailedTail {
        return if (self.degraded_tail) |*tail| tail else null;
    }

    fn prepareCommitLifecycle(
        self: *LoadedWritableSession,
        alloc: Allocator,
        next_workspace_root: []const u8,
        options: Options,
    ) !void {
        if (self.commit_lifecycle) |*lifecycle| {
            try lifecycle.prepare(
                alloc,
                self.active_id,
                self.state.workspace_root,
                next_workspace_root,
                options.commit_lock_deadline_ms,
            );
        }
    }

    fn prepareCommitLifecycleOpportunistic(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !bool {
        if (self.commit_lifecycle) |*lifecycle| {
            return lifecycle.prepareOpportunistic(
                alloc,
                self.active_id,
                self.state.workspace_root,
                options.commit_lock_deadline_ms,
            );
        }
        return false;
    }

    fn writeDeferredCommitLifecycle(
        self: *LoadedWritableSession,
        alloc: Allocator,
        position: CommitPosition,
    ) !void {
        if (self.commit_lifecycle) |*lifecycle| {
            try lifecycle.writeDeferred(
                alloc,
                self.active_id,
                self.state.workspace_root,
                position,
            );
        }
    }

    pub fn publishCommitLifecycle(self: *LoadedWritableSession, alloc: Allocator) bool {
        if (self.commit_lifecycle) |*lifecycle| {
            lifecycle.publish(alloc, self.state, self.position) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=latest_cache_publish_failed err={s}",
                    .{@errorName(err)},
                );
                return false;
            };
        }
        return true;
    }

    fn abortCommitLifecycle(self: *LoadedWritableSession) void {
        if (self.commit_lifecycle) |*lifecycle| lifecycle.abort();
    }

    pub fn retryDegradedWithStateReplacement(
        self: *LoadedWritableSession,
        alloc: Allocator,
        current_state: session_codec.DurableSessionState,
        options: Options,
    ) !void {
        return retryDegradedWithStateReplacementImpl(
            self,
            alloc,
            current_state,
            options,
        );
    }

    pub fn compactCanonicalLogIfDue(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        return compactCanonicalLogIfDueImpl(self, alloc, options);
    }

    pub fn writeCheckpointIfDue(
        self: *LoadedWritableSession,
        alloc: Allocator,
        ensure_present: bool,
        options: Options,
    ) !void {
        try confirmWritableNamespace(self, alloc, options);
        if (!checkpointDue(self, options.checkpoint_interval) and
            !(ensure_present and !self.hasCurrentCheckpoint()))
        {
            return;
        }
        writeCheckpointProjection(alloc, self) catch |err| switch (err) {
            error.CheckpointTooLarge => return,
            else => return err,
        };
        try writeManifestProjection(alloc, self);
        self.projection_status = .current;
    }

    pub fn validateResumeBoundary(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        try confirmWritableNamespace(self, alloc, options);
        _ = try validateLivePosition(
            alloc,
            &self.log.dir,
            self.active_id,
            self.position,
        );
    }

    /// Repairs only a corrupt watermark whose writer authority, complete
    /// event log, and in-memory state prove the same exact boundary.
    pub fn repairResumeBoundary(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        try confirmWritableNamespace(self, alloc, options);
        options.test_controls.lock(.commit);
        var commit_lock = acquireLockWithDeadline(
            &self.log.dir,
            commit_lock_file,
            true,
            options.commit_lock_deadline_ms,
        ) catch |err| return mapCommitLockError(err);
        defer commit_lock.release();
        try requireIntentAbsent(alloc, &self.log.dir, authority_intent_file);
        try requireIntentAbsent(alloc, &self.log.dir, publication_intent_file);

        var event_log = try openManagedFile(
            &self.log.dir,
            events_file,
            .read_only,
        );
        defer event_log.close(io_mod.getIo());
        var recovered = try session_replay.replayExactPosition(
            alloc,
            event_log,
            self.position.log_generation,
            self.position.through_seq,
            self.position.through_event_log_bytes,
        );
        defer recovered.deinit(alloc);
        if (!positionsEqual(recovered.position, self.position) or
            !try durableStatesEqual(recovered.state, self.state))
        {
            return error.InvalidSessionFormat;
        }

        const watermark_bytes = try encodeWatermark(
            alloc,
            self.log.session_id,
            self.position,
        );
        defer alloc.free(watermark_bytes);
        const name = try watermarkName(alloc, self.position.log_generation);
        defer alloc.free(name);
        try durableReplace(alloc, &self.log.dir, name, watermark_bytes);
        _ = try validateLivePosition(
            alloc,
            &self.log.dir,
            self.active_id,
            self.position,
        );
    }

    pub fn hasCurrentCheckpoint(self: *const LoadedWritableSession) bool {
        return self.checkpoint_seq != null and
            self.checkpoint_sha256 != null and
            self.projection_status == .current;
    }

    pub fn needsFinalStateReplacement(
        self: *const LoadedWritableSession,
        usage_dirty: bool,
    ) bool {
        return usage_dirty or self.state_replacement_pending;
    }

    pub fn cleanupOrphans(
        self: *LoadedWritableSession,
        alloc: Allocator,
        mode: CleanupMode,
    ) !CleanupReport {
        try confirmWritableNamespace(self, alloc, .{});
        return cleanupOrphansImpl(self, alloc, mode, .{});
    }

    fn createCleanupCandidatesForTest(
        self: *LoadedWritableSession,
        alloc: Allocator,
    ) !CleanupCandidates {
        return makeCleanupCandidatesForTest(self, alloc);
    }

    fn validateCheckpointForTest(self: *LoadedWritableSession, alloc: Allocator) !void {
        const bytes = try readManagedFileAlloc(
            alloc,
            &self.log.dir,
            checkpoint_file,
            session_projection.checkpoint_max_bytes,
        );
        defer alloc.free(bytes);
        var checkpoint = try session_projection.decodeCheckpoint(alloc, bytes);
        defer checkpoint.deinit(alloc);
        var manifest = try loadManifest(alloc, &self.log.dir);
        defer manifest.deinit(alloc);
        const boundary = try validateCommitPosition(
            alloc,
            &self.log.dir,
            self.log.session_id,
            self.position,
        );
        try session_projection.validateCheckpointReference(
            manifest,
            bytes,
            checkpoint,
            boundary,
            .{
                .log_generation = checkpoint.log_generation,
                .seq = checkpoint.through_seq,
                .event_id = checkpoint.through_event_id,
                .event_log_bytes = checkpoint.through_event_log_bytes,
                .semantic = true,
            },
        );
    }
};

pub const Root = struct {
    sessions: ?io_mod.VerifiedDir,
    display_root: []u8,
    mode: OpenMode,

    pub fn initFromHome(
        alloc: Allocator,
        home_path: []const u8,
        mode: OpenMode,
    ) !Root {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.fs.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                std.Io.Dir.createDirAbsolute(zio, home_path, private_dir_permissions) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                break :blk try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
            },
            else => return err,
        };
        defer home.close(zio);

        var durable_home = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.fs.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var verified_home = io_mod.VerifiedDir{
                    .dir = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
                        .iterate = true,
                    }),
                };
                defer verified_home.close();
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &verified_home,
                    profile_paths.root_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer durable_home.close(zio);
        if (mode == .writable) {
            durable_home.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(durable_home, mode);

        var sessions_dir = durable_home.openDir(zio, profile_paths.sessions_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.fs.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var parent = io_mod.VerifiedDir{ .dir = durable_home };
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &parent,
                    profile_paths.sessions_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer sessions_dir.close(zio);
        if (mode == .writable) {
            sessions_dir.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(sessions_dir, mode);
        const display_root = try io_mod.dirRealpathAlloc(alloc, sessions_dir, ".");
        return .{
            .sessions = .{ .dir = sessions_dir },
            .display_root = display_root,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Root, alloc: Allocator) void {
        if (self.sessions) |*dir| dir.close();
        alloc.free(self.display_root);
        self.* = undefined;
    }

    pub fn startWritableSession(
        self: *Root,
        alloc: Allocator,
        initial_state: session_codec.DurableSessionState,
        options: Options,
    ) !LoadedWritableSession {
        return self.startWritableSessionWithLifecycle(
            alloc,
            initial_state,
            options,
            null,
        );
    }

    pub fn startWritableSessionWithLifecycle(
        self: *Root,
        alloc: Allocator,
        initial_state: session_codec.DurableSessionState,
        options: Options,
        lifecycle: ?CommitLifecycle,
    ) !LoadedWritableSession {
        var lifecycle_value = lifecycle;
        errdefer if (lifecycle_value) |*value| value.deinit(alloc);
        if (self.mode != .writable or self.sessions == null) {
            return error.SessionStoreUnavailable;
        }
        try session_codec.validateState(initial_state);
        const sessions = &self.sessions.?;
        if (try entryExists(sessions, initial_state.id)) return error.SessionAlreadyExists;

        sessions.dir.createDir(
            io_mod.getIo(),
            initial_state.id,
            private_dir_permissions,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => return error.SessionAlreadyExists,
            else => return error.SessionStartFailed,
        };
        io_mod.syncVerifiedDir(sessions.dir) catch return error.SessionStartFailed;

        var session_dir = try openSessionDir(sessions, initial_state.id, .writable);
        options.test_controls.lock(.session);
        var writer_lock = acquireLockWithDeadline(
            &session_dir,
            session_lock_file,
            true,
            options.session_lock_deadline_ms,
        ) catch |err| {
            session_dir.close();
            return mapSessionLockError(err);
        };
        const session_id = alloc.dupe(u8, initial_state.id) catch |err| {
            writer_lock.release();
            session_dir.close();
            return err;
        };
        var writable = WritableSessionDir{
            .dir = session_dir,
            .writer_lock = writer_lock,
            .session_id = session_id,
        };
        var writable_owned = true;
        errdefer if (writable_owned) writable.deinit(alloc);
        if (lifecycle_value) |*value| {
            value.prepare(
                alloc,
                initial_state.id,
                initial_state.workspace_root,
                initial_state.workspace_root,
                options.commit_lock_deadline_ms,
            ) catch |err| {
                writable.deinit(alloc);
                writable_owned = false;
                sessions.dir.deleteTree(io_mod.getIo(), initial_state.id) catch |cleanup_err| {
                    debug_trace.logf(
                        "session",
                        "event=uncommitted_session_cleanup_failed err={s}",
                        .{@errorName(cleanup_err)},
                    );
                    return cleanup_err;
                };
                io_mod.syncVerifiedDir(sessions.dir) catch |cleanup_err| {
                    debug_trace.logf(
                        "session",
                        "event=uncommitted_session_cleanup_sync_failed err={s}",
                        .{@errorName(cleanup_err)},
                    );
                    return cleanup_err;
                };
                return err;
            };
        }
        var created = try createNativeSession(
            alloc,
            &writable,
            initial_state,
            options,
        );
        writable_owned = false;
        errdefer created.deinit(alloc);
        if (lifecycle_value) |value| {
            try created.installCommitLifecycle(value);
            lifecycle_value = null;
            if (!created.publishCommitLifecycle(alloc)) {
                created.state_replacement_pending = true;
            }
        }
        return created;
    }

    pub fn resumeForWrite(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !LoadedWritableSession {
        options.test_controls.lock(.session);
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
        );
        return openWritableSession(alloc, &writable, options) catch |err| {
            writable.deinit(alloc);
            return err;
        };
    }

    pub fn captureReadBoundary(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !ReadBoundary {
        if (self.sessions == null) return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var session_dir = openSessionDir(
            &self.sessions.?,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        try requireIntentAbsent(alloc, &session_dir, authority_intent_file);
        options.test_controls.lock(.commit);
        var lock = acquireLockWithDeadline(
            &session_dir,
            commit_lock_file,
            false,
            options.commit_lock_deadline_ms,
        ) catch |err| switch (err) {
            error.FileNotFound, error.LockBusy, error.LockUnsupported => {
                try requireIntentAbsent(alloc, &session_dir, authority_intent_file);
                return error.SessionCommitBoundaryUnavailable;
            },
            else => return err,
        };
        defer lock.release();
        try requireIntentAbsent(alloc, &session_dir, authority_intent_file);
        var marker = try loadAuthority(alloc, &session_dir, session_id);
        defer marker.deinit(alloc);
        try requireIntentAbsent(alloc, &session_dir, publication_intent_file);
        var log_file = try openManagedFile(&session_dir, events_file, .read_only);
        errdefer log_file.close(io_mod.getIo());
        const generation = try session_replay.readFirstGeneration(alloc, log_file);
        const position = try loadAndValidateWatermark(
            alloc,
            &session_dir,
            session_id,
            generation,
            log_file,
        );
        const usage_sidecar = try session_usage_sidecar.capture(
            alloc,
            &session_dir,
        );
        return .{
            .log_file = log_file,
            .position = position,
            .usage_sidecar = usage_sidecar,
            .alloc = alloc,
        };
    }

    pub fn loadReadOnly(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !session_codec.DurableSessionState {
        var boundary = try self.captureReadBoundary(alloc, session_id, options);
        defer boundary.deinit();
        var state = try session_replay.replayBoundary(
            alloc,
            boundary.log_file,
            boundary.position,
        );
        errdefer state.deinit(alloc);
        if (state.usage) |*usage| {
            _ = try session_usage_sidecar.restoreCaptured(
                alloc,
                boundary.usage_sidecar,
                state.id,
                state.updated_at_ms,
                pendingConnectionAuthority(state),
                usage,
            );
        }
        return state;
    }

    pub fn admitResumeView(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
    ) !ResumeViewAdmission {
        var writable = try self.openWritableSessionDir(alloc, session_id, 0);
        errdefer writable.deinit(alloc);
        const position = try loadCurrentPositionReference(alloc, &writable.dir, session_id);
        return .{
            .writable = writable,
            .view = try session_resume_view.loadMatching(
                alloc,
                &writable.dir,
                session_id,
                resumeViewBoundary(position),
            ),
        };
    }

    fn openWritableSessionDir(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        deadline_ms: u64,
    ) !WritableSessionDir {
        if (self.mode != .writable or self.sessions == null) return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var dir = openSessionDir(&self.sessions.?, session_id, .writable) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        var writer_lock = acquireLockWithDeadline(
            &dir,
            session_lock_file,
            true,
            deadline_ms,
        ) catch |err| {
            dir.close();
            return mapSessionLockError(err);
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close();
            return err;
        };
        return .{
            .dir = dir,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
    }

    fn entryExistsForTest(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        name: []const u8,
    ) !bool {
        _ = alloc;
        if (self.sessions == null) return false;
        var dir = openSessionDir(&self.sessions.?, session_id, .read_only) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close();
        return entryExists(&dir, name);
    }
};

fn resumeViewBoundary(position: CommitPosition) session_resume_view.Boundary {
    return .{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_log_bytes = position.through_event_log_bytes,
    };
}

fn validateLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\") != null)
    {
        return error.SessionPathUnsafe;
    }
}

fn verifyPrivateDir(dir: std.Io.Dir, mode: OpenMode) !void {
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn verifyManagedFile(file: std.Io.File, mode: OpenMode) !void {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn openSessionDir(
    sessions: *io_mod.VerifiedDir,
    session_id: []const u8,
    mode: OpenMode,
) !io_mod.VerifiedDir {
    try session_layout.validateSessionId(session_id);
    var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    if (mode == .writable) {
        dir.setPermissions(io_mod.getIo(), private_dir_permissions) catch
            return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateDir(dir, mode);
    return .{ .dir = dir };
}

fn openManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.openFile(io_mod.getIo(), name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    try verifyManagedFile(file, if (mode == .read_only) .read_only else .writable);
    return file;
}

fn createManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.createFile(io_mod.getIo(), name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    file.setPermissions(io_mod.getIo(), private_file_permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    try verifyManagedFile(file, .writable);
    return file;
}

fn entryExists(dir: *io_mod.VerifiedDir, name: []const u8) !bool {
    try validateLeaf(name);
    const stat = dir.dir.statFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    if (stat.kind != .file and stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.kind == .file and stat.nlink != 1) return error.SessionPathUnsafe;
    return true;
}

fn acquireLock(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
) !io_mod.TimedAdvisoryLock {
    return acquireLockWithDeadline(dir, name, create, lock_deadline_ms);
}

fn acquireLockWithDeadline(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
    deadline_ms: u64,
) !io_mod.TimedAdvisoryLock {
    if (create) {
        return io_mod.acquireTimedAdvisoryLock(dir, name, deadline_ms);
    }
    var file = try openManagedFile(dir, name, .read_write);
    errdefer file.close(io_mod.getIo());
    const started = io_mod.milliTimestamp();
    while (true) {
        const locked = file.tryLock(io_mod.getIo(), .exclusive) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (io_mod.milliTimestamp() - started >= deadline_ms) return error.LockBusy;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn mapSessionLockError(err: anyerror) anyerror {
    return switch (err) {
        error.LockBusy => error.SessionBusy,
        error.LockUnsupported => error.SessionLockUnsupported,
        else => err,
    };
}

fn readManagedFileAlloc(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try openManagedFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => error.InvalidSessionFormat,
        else => err,
    };
}

fn requireIntentAbsent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !void {
    if (!try entryExists(dir, name)) return;
    if (std.mem.eql(u8, name, authority_intent_file)) {
        var intent = try loadAuthorityIntent(alloc, dir);
        defer intent.deinit(alloc);
        return error.SessionAuthorityBoundaryUnavailable;
    }
    var intent = try loadPublicationIntent(alloc, dir);
    defer intent.deinit(alloc);
    return error.SessionCommitBoundaryUnavailable;
}

fn randomIdentifier() Identifier {
    var id: Identifier = undefined;
    io_mod.getIo().random(&id);
    return id;
}

fn randomSequenceSeed() u128 {
    const id = randomIdentifier();
    return std.mem.readInt(u128, &id, .big);
}

fn identifierHex(id: Identifier) [32]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

fn parseIdentifier(raw: []const u8) !Identifier {
    if (raw.len != 32) return error.InvalidSessionFormat;
    var result: Identifier = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionFormat;
    const canonical = identifierHex(result);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionFormat;
    return result;
}

fn parseDigest(raw: []const u8) !session_projection.Digest {
    if (raw.len != 64) return error.InvalidSessionFormat;
    var result: session_projection.Digest = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionFormat;
    return result;
}

fn encodeAuthority(alloc: Allocator, marker: AuthorityMarker) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(marker.session_id, .{}, &out.writer);
    const authority_hex = identifierHex(marker.authority_id);
    try out.writer.print(
        ",\"authority_id\":\"{s}\",\"storage_format\":\"event_log_v1\",\"source\":\"{s}\"}}\n",
        .{ authority_hex, @tagName(marker.source) },
    );
    if (out.written().len > authority_max_bytes) return error.InvalidSessionFormat;
    return out.toOwnedSlice();
}

fn decodeAuthority(alloc: Allocator, bytes: []const u8) !AuthorityMarker {
    if (bytes.len == 0 or bytes.len > authority_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "authority_id",
        "storage_format",
        "source",
    });
    if (try requireU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try session_codec.requireString(object, "storage_format"), "event_log_v1"))
    {
        return error.InvalidSessionFormat;
    }
    const id = try alloc.dupe(u8, try session_codec.requireString(object, "session_id"));
    errdefer alloc.free(id);
    try session_layout.validateSessionId(id);
    return .{
        .session_id = id,
        .authority_id = try parseIdentifier(try session_codec.requireString(object, "authority_id")),
        .source = std.meta.stringToEnum(
            AuthoritySource,
            try session_codec.requireString(object, "source"),
        ) orelse return error.InvalidSessionFormat,
    };
}

fn encodeCommitPosition(writer: *std.Io.Writer, position: CommitPosition) !void {
    const generation = identifierHex(position.log_generation);
    const event_id = identifierHex(position.through_event_id);
    try writer.print(
        "{{\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}",
        .{
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
}

fn parseCommitPosition(value: std.json.Value) !CommitPosition {
    const object = try session_codec.exactObject(value, &.{
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    });
    return .{
        .log_generation = try parseIdentifier(try session_codec.requireString(object, "log_generation")),
        .through_seq = try requireU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(try session_codec.requireString(object, "through_event_id")),
        .through_event_log_bytes = try requireU64(object, "through_event_log_bytes"),
    };
}

fn encodeAuthorityPosition(
    writer: *std.Io.Writer,
    position: CommitPosition,
) !void {
    const generation = identifierHex(position.log_generation);
    const event_id = identifierHex(position.through_event_id);
    try writer.print(
        "{{\"storage_format\":\"event_log_v1\",\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}",
        .{
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
}

fn parseAuthorityPosition(value: std.json.Value) !CommitPosition {
    const object = try session_codec.exactObject(value, &.{
        "storage_format",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    });
    if (!std.mem.eql(
        u8,
        try session_codec.requireString(object, "storage_format"),
        "event_log_v1",
    )) {
        return error.InvalidSessionFormat;
    }
    return .{
        .log_generation = try parseIdentifier(try session_codec.requireString(object, "log_generation")),
        .through_seq = try requireU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(try session_codec.requireString(object, "through_event_id")),
        .through_event_log_bytes = try requireU64(object, "through_event_log_bytes"),
    };
}

fn encodeAuthorityIntent(alloc: Allocator, intent: AuthorityIntent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(intent.session_id, .{}, &out.writer);
    const operation = identifierHex(intent.operation_id);
    const authority = identifierHex(intent.authority_id);
    try out.writer.print(
        ",\"operation_id\":\"{s}\",\"kind\":\"{s}\",\"authority_id\":\"{s}\",\"prior\":",
        .{ operation, @tagName(intent.kind), authority },
    );
    if (intent.prior) |prior| {
        const digest = std.fmt.bytesToHex(prior.primary_sha256, .lower);
        try out.writer.writeAll("{\"storage_format\":");
        try std.json.Stringify.value(prior.storage_format, .{}, &out.writer);
        try out.writer.print(
            ",\"primary_bytes\":{d},\"primary_sha256\":\"{s}\"}}",
            .{ prior.primary_bytes, digest },
        );
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"proposed\":");
    try encodeAuthorityPosition(&out.writer, intent.proposed);
    try out.writer.writeAll("}\n");
    if (out.written().len > authority_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    return out.toOwnedSlice();
}

fn decodeAuthorityIntent(alloc: Allocator, bytes: []const u8) !AuthorityIntent {
    if (bytes.len == 0 or bytes.len > authority_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "operation_id",
        "kind",
        "authority_id",
        "prior",
        "proposed",
    });
    if (try requireU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(u8, try session_codec.requireString(object, "session_id"));
    errdefer alloc.free(session_id);
    try session_layout.validateSessionId(session_id);
    const kind = std.meta.stringToEnum(
        AuthorityKind,
        try session_codec.requireString(object, "kind"),
    ) orelse return error.InvalidSessionFormat;
    const prior_value = object.get("prior") orelse return error.InvalidSessionFormat;
    var prior: ?LegacyFingerprint = null;
    errdefer if (prior) |*owned| owned.deinit(alloc);
    if (prior_value != .null) {
        const prior_object = try session_codec.exactObject(prior_value, &.{
            "storage_format",
            "primary_bytes",
            "primary_sha256",
        });
        prior = .{
            .storage_format = try alloc.dupe(
                u8,
                try session_codec.requireString(prior_object, "storage_format"),
            ),
            .primary_bytes = try requireU64(prior_object, "primary_bytes"),
            .primary_sha256 = try parseDigest(
                try session_codec.requireString(prior_object, "primary_sha256"),
            ),
        };
    }
    if ((kind == .session_create) != (prior == null)) {
        return error.InvalidSessionFormat;
    }
    return .{
        .session_id = session_id,
        .operation_id = try parseIdentifier(try session_codec.requireString(object, "operation_id")),
        .kind = kind,
        .authority_id = try parseIdentifier(try session_codec.requireString(object, "authority_id")),
        .prior = prior,
        .proposed = try parseAuthorityPosition(
            object.get("proposed") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn encodeWatermark(
    alloc: Allocator,
    session_id: []const u8,
    position: CommitPosition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const generation = identifierHex(position.log_generation);
    const event_id = identifierHex(position.through_event_id);
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
    if (out.written().len > watermark_max_bytes) return error.InvalidSessionFormat;
    return out.toOwnedSlice();
}

fn decodeWatermark(
    alloc: Allocator,
    bytes: []const u8,
    expected_session_id: []const u8,
    expected_generation: Identifier,
) !CommitPosition {
    var decoded = try parseWatermark(alloc, bytes);
    defer decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.session_id, expected_session_id) or
        !std.mem.eql(u8, &decoded.position.log_generation, &expected_generation))
    {
        return error.InvalidSessionFormat;
    }
    return decoded.position;
}

fn parseWatermark(
    alloc: Allocator,
    bytes: []const u8,
) !DecodedWatermark {
    if (bytes.len == 0 or bytes.len > watermark_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    });
    if (try requireU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(
        u8,
        try session_codec.requireString(object, "session_id"),
    );
    errdefer alloc.free(session_id);
    try session_layout.validateSessionId(session_id);
    return .{
        .session_id = session_id,
        .position = .{
            .log_generation = try parseIdentifier(
                try session_codec.requireString(object, "log_generation"),
            ),
            .through_seq = try requireU64(object, "through_seq"),
            .through_event_id = try parseIdentifier(
                try session_codec.requireString(object, "through_event_id"),
            ),
            .through_event_log_bytes = try requireU64(
                object,
                "through_event_log_bytes",
            ),
        },
    };
}

pub fn inspectCommitWatermark(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !CommitWatermarkInspection {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log);
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    if (!try entryExists(dir, name)) return .{ .status = .missing };
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        name,
        watermark_max_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.SessionPathUnsafe => return err,
        else => return .{ .status = .invalid },
    };
    defer alloc.free(bytes);
    var decoded = parseWatermark(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .status = .invalid },
    };
    defer decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.session_id, session_id) or
        !std.mem.eql(u8, &decoded.position.log_generation, &generation))
    {
        return .{ .status = .mismatched };
    }
    _ = validateCommitPosition(
        alloc,
        dir,
        session_id,
        decoded.position,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .status = .mismatched },
    };
    return .{ .status = .valid, .position = decoded.position };
}

fn encodePublicationIntent(alloc: Allocator, intent: PublicationIntent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(intent.session_id, .{}, &out.writer);
    const operation = identifierHex(intent.operation_id);
    try out.writer.print(
        ",\"operation_id\":\"{s}\",\"kind\":\"{s}\",\"prior\":",
        .{ operation, @tagName(intent.kind) },
    );
    try encodeCommitPosition(&out.writer, intent.prior);
    try out.writer.writeAll(",\"proposed\":");
    try encodeCommitPosition(&out.writer, intent.proposed);
    try out.writer.writeAll("}\n");
    if (out.written().len > publication_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    return out.toOwnedSlice();
}

fn decodePublicationIntent(alloc: Allocator, bytes: []const u8) !PublicationIntent {
    if (bytes.len == 0 or bytes.len > publication_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "operation_id",
        "kind",
        "prior",
        "proposed",
    });
    if (try requireU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(u8, try session_codec.requireString(object, "session_id"));
    errdefer alloc.free(session_id);
    try session_layout.validateSessionId(session_id);
    return .{
        .session_id = session_id,
        .operation_id = try parseIdentifier(try session_codec.requireString(object, "operation_id")),
        .kind = std.meta.stringToEnum(
            PublicationKind,
            try session_codec.requireString(object, "kind"),
        ) orelse return error.InvalidSessionFormat,
        .prior = try parseCommitPosition(
            object.get("prior") orelse return error.InvalidSessionFormat,
        ),
        .proposed = try parseCommitPosition(
            object.get("proposed") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .number_string) return error.InvalidSessionFormat;
    return std.fmt.parseUnsigned(u64, value.number_string, 10) catch
        return error.InvalidSessionFormat;
}

fn watermarkName(alloc: Allocator, generation: Identifier) ![]u8 {
    const hex = identifierHex(generation);
    return std.fmt.allocPrint(alloc, "commit.{s}.json", .{hex});
}

fn loadAuthority(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !AuthorityMarker {
    const bytes = try readManagedFileAlloc(alloc, dir, authority_file, authority_max_bytes);
    defer alloc.free(bytes);
    var marker = try decodeAuthority(alloc, bytes);
    errdefer marker.deinit(alloc);
    if (!std.mem.eql(u8, marker.session_id, session_id)) {
        return error.InvalidSessionFormat;
    }
    return marker;
}

fn loadAuthorityIntent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !AuthorityIntent {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        authority_intent_file,
        authority_intent_max_bytes,
    );
    defer alloc.free(bytes);
    return decodeAuthorityIntent(alloc, bytes);
}

fn loadPublicationIntent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !PublicationIntent {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        publication_intent_file,
        publication_intent_max_bytes,
    );
    defer alloc.free(bytes);
    return decodePublicationIntent(alloc, bytes);
}

fn loadManifest(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !session_projection.Manifest {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_projection.manifest_max_bytes,
    );
    defer alloc.free(bytes);
    return session_projection.decodeManifest(alloc, bytes);
}

const BoundarySyncContext = struct {
    test_controls: TestControls,
    boundary: Boundary,
};

fn syncDirAfterBoundary(raw: ?*anyopaque, dir: std.Io.Dir) !void {
    const context: *BoundarySyncContext = @ptrCast(@alignCast(raw.?));
    try context.test_controls.boundary(context.boundary);
    try io_mod.syncVerifiedDir(dir);
}

fn durableReplace(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    bytes: []const u8,
) !void {
    try io_mod.durableReplaceVerified(alloc, dir, name, bytes);
}

fn durableReplaceWithBoundary(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    bytes: []const u8,
    test_controls: TestControls,
    boundary: Boundary,
) !void {
    var context = BoundarySyncContext{ .test_controls = test_controls, .boundary = boundary };
    try io_mod.durableReplaceVerifiedWithOps(
        alloc,
        dir,
        name,
        bytes,
        .{ .ctx = &context, .sync_dir = syncDirAfterBoundary },
    );
}

fn deleteAndSync(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    test_controls: TestControls,
    boundary: ?Boundary,
) !void {
    try validateLeaf(name);
    dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    if (boundary) |point| try test_controls.boundary(point);
    try io_mod.syncVerifiedDir(dir.dir);
}

fn createNativeSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
    initial_state: session_codec.DurableSessionState,
    options: Options,
) !LoadedWritableSession {
    var synthesized_usage: ?session_usage.Snapshot = null;
    if (initial_state.usage == null) {
        var fresh_usage = session_usage.Usage.initFresh();
        defer fresh_usage.deinit(alloc);
        synthesized_usage = try fresh_usage.snapshot(alloc);
    }
    defer if (synthesized_usage) |*usage| usage.deinit(alloc);

    const generation = randomIdentifier();
    const event_id = randomIdentifier();
    const authority_id = randomIdentifier();
    const envelope = session_event.Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = event_id,
        .timestamp_ms = initial_state.updated_at_ms,
        .event = .{ .session_started = .{
            .id = initial_state.id,
            .created_at_ms = initial_state.created_at_ms,
            .origin_workspace_root = initial_state.origin_workspace_root,
            .workspace_root = initial_state.workspace_root,
            .conversation_language = initial_state.conversation_language,
            .preferences = initial_state.preferences,
            .usage = initial_state.usage orelse synthesized_usage.?,
        } },
    };
    const line = try session_event.encodeFrame(alloc, envelope);
    defer alloc.free(line);

    {
        var lock = acquireLock(&writable.dir, commit_lock_file, true) catch |err| {
            return mapCommitLockError(err);
        };
        lock.release();
    }
    var event_log = createManagedFile(&writable.dir, events_file) catch
        return error.SessionStartFailed;
    defer event_log.close(io_mod.getIo());
    event_log.writePositionalAll(io_mod.getIo(), line, 0) catch
        return error.SessionStartFailed;
    options.test_controls.boundary(.after_event_append) catch
        return error.SessionStartFailed;
    event_log.sync(io_mod.getIo()) catch return error.SessionStartFailed;
    options.test_controls.boundary(.after_event_sync) catch
        return error.SessionStartFailed;

    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = event_id,
        .through_event_log_bytes = line.len,
    };
    const watermark_bytes = try encodeWatermark(alloc, initial_state.id, position);
    defer alloc.free(watermark_bytes);
    const watermark_name = try watermarkName(alloc, generation);
    defer alloc.free(watermark_name);
    durableReplaceWithBoundary(
        alloc,
        &writable.dir,
        watermark_name,
        watermark_bytes,
        options.test_controls,
        .after_watermark_rename,
    ) catch return error.SessionStartFailed;

    options.test_controls.lock(.commit);
    var commit_lock = acquireLock(&writable.dir, commit_lock_file, true) catch |err| {
        return mapCommitLockError(err);
    };
    defer commit_lock.release();

    const intent = AuthorityIntent{
        .session_id = writable.session_id,
        .operation_id = randomIdentifier(),
        .kind = .session_create,
        .authority_id = authority_id,
        .prior = null,
        .proposed = position,
    };
    const intent_bytes = try encodeAuthorityIntent(alloc, intent);
    defer alloc.free(intent_bytes);
    if (try entryExists(&writable.dir, authority_intent_file)) {
        return error.SessionStartIndeterminate;
    }
    durableReplace(
        alloc,
        &writable.dir,
        authority_intent_file,
        intent_bytes,
    ) catch return error.SessionStartIndeterminate;
    options.test_controls.boundary(.after_authority_intent_sync) catch
        return error.SessionStartIndeterminate;

    const marker = AuthorityMarker{
        .session_id = writable.session_id,
        .authority_id = authority_id,
        .source = .native_create,
    };
    const marker_bytes = try encodeAuthority(alloc, marker);
    defer alloc.free(marker_bytes);
    durableReplaceWithBoundary(
        alloc,
        &writable.dir,
        authority_file,
        marker_bytes,
        options.test_controls,
        .after_authority_marker_rename,
    ) catch return error.SessionStartIndeterminate;
    validateAuthorityTarget(
        alloc,
        &writable.dir,
        writable.session_id,
        intent,
    ) catch return error.SessionStartIndeterminate;
    options.test_controls.boundary(.after_authority_namespace_sync) catch
        return error.SessionStartIndeterminate;

    var cleanup_pending = false;
    deleteAndSync(
        &writable.dir,
        authority_intent_file,
        options.test_controls,
        .after_authority_intent_remove,
    ) catch {
        cleanup_pending = true;
    };

    var state = try initial_state.dupe(alloc);
    errdefer {
        var owned = state;
        owned.deinit(alloc);
    }
    if (state.usage == null) {
        state.usage = synthesized_usage;
        synthesized_usage = null;
    }
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    var result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .log = writable.*,
        .freshly_started = true,
        .state_replacement_pending = false,
        .position = position,
        .authority_id = authority_id,
        .generation_base_seq = position.through_seq,
        .generation_base_bytes = position.through_event_log_bytes,
        .projection_status = if (cleanup_pending) .stale else .current,
        .namespace_confirmation_required = cleanup_pending,
    };
    if (result.state.usage) |usage| {
        session_usage_sidecar.write(
            alloc,
            &result.log.dir,
            result.state.id,
            usage,
        ) catch |err| {
            result.usage_sidecar_reseal_pending = true;
            debug_trace.logf(
                "session",
                "event=usage_sidecar_initial_write_failed err={s}",
                .{@errorName(err)},
            );
        };
    }
    writeManifestProjection(alloc, &result) catch {
        result.projection_status = .stale;
    };
    writable.* = undefined;
    return result;
}

fn openWritableSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !LoadedWritableSession {
    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &writable.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
    ) catch |err| {
        return mapCommitLockError(err);
    };
    defer commit_lock.release();

    const marker = try resolveAuthorityIntent(alloc, writable, options);
    defer {
        var owned = marker;
        owned.deinit(alloc);
    }
    const position = if (try entryExists(&writable.dir, publication_intent_file))
        try resolvePublicationIntent(alloc, writable, options)
    else
        try loadCurrentPositionReference(
            alloc,
            &writable.dir,
            writable.session_id,
        );
    try io_mod.syncVerifiedDir(writable.dir.dir);

    var event_log = try openManagedFile(&writable.dir, events_file, .read_write);
    defer event_log.close(io_mod.getIo());
    const length = try event_log.length(io_mod.getIo());
    if (length < position.through_event_log_bytes) return error.InvalidSessionFormat;
    const replay_started_ns = io_mod.nanoTimestamp();
    var open_state = loadOpenState(
        alloc,
        &writable.dir,
        writable.session_id,
        marker.authority_id,
        event_log,
        position,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.SessionReplayResourceExhausted,
        else => return err,
    };
    errdefer open_state.state.deinit(alloc);
    const usage_sidecar_reseal_pending = try restoreUsageSidecar(
        alloc,
        &writable.dir,
        &open_state.state,
    );
    const replay_finished_ns = io_mod.nanoTimestamp();
    debug_trace.logf(
        "session",
        "event=session_replay source={s} checkpoint_seq={?d} tail_bytes={d} elapsed_us={d}",
        .{
            @tagName(open_state.source),
            open_state.checkpoint_seq,
            open_state.tail_bytes,
            @divTrunc(replay_finished_ns - replay_started_ns, std.time.ns_per_us),
        },
    );
    if (length > position.through_event_log_bytes) {
        try event_log.setLength(io_mod.getIo(), position.through_event_log_bytes);
        try event_log.sync(io_mod.getIo());
    }
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);

    var result = LoadedWritableSession{
        .active_id = active_id,
        .state = open_state.state,
        .log = writable.*,
        .position = position,
        .authority_id = marker.authority_id,
        .generation_base_seq = open_state.generation_base_seq,
        .generation_base_bytes = open_state.generation_base_bytes,
        .checkpoint_seq = open_state.checkpoint_seq,
        .checkpoint_sha256 = open_state.checkpoint_sha256,
        .projection_status = open_state.projection_status,
        .usage_sidecar_reseal_pending = usage_sidecar_reseal_pending,
    };
    open_state.state = undefined;
    if (result.projection_status == .stale) {
        writeManifestProjection(alloc, &result) catch {
            result.projection_status = .stale;
        };
    }
    writable.* = undefined;
    return result;
}

fn restoreUsageSidecar(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    state: *session_codec.DurableSessionState,
) !bool {
    if (state.usage) |*usage| {
        const outcome = try session_usage_sidecar.restoreIfMatching(
            alloc,
            dir,
            state.id,
            state.updated_at_ms,
            pendingConnectionAuthority(state.*),
            usage,
        );
        return outcome != .restored;
    }
    return false;
}

fn encodeUsageSidecarBestEffort(
    alloc: Allocator,
    session_id: []const u8,
    usage: session_usage.Snapshot,
) ?[]u8 {
    return session_usage_sidecar.encode(
        alloc,
        session_id,
        usage,
    ) catch |err| {
        traceUsageSidecarWriteFailure(err);
        return null;
    };
}

fn writeEncodedUsageSidecarBestEffort(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    encoded: []const u8,
) bool {
    session_usage_sidecar.writeEncoded(
        alloc,
        &loaded.log.dir,
        encoded,
    ) catch |err| {
        traceUsageSidecarWriteFailure(err);
        return false;
    };
    return true;
}

fn restoreEncodedUsageSidecarBestEffort(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    encoded: []const u8,
) void {
    if (loaded.state.usage) |*usage| {
        _ = session_usage_sidecar.restoreCaptured(
            alloc,
            .{ .encoded = @constCast(encoded) },
            loaded.state.id,
            loaded.state.updated_at_ms,
            pendingConnectionAuthority(loaded.state),
            usage,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=usage_sidecar_memory_restore_failed err={s}",
                .{@errorName(err)},
            );
        };
    }
}

fn pendingConnectionAuthority(
    state: session_codec.DurableSessionState,
) session_usage_sidecar.PendingConnectionAuthority {
    return if (state.preferences.connection_id) |connection_id|
        .{ .current = connection_id }
    else
        .historical_vercel;
}

fn traceUsageSidecarWriteFailure(err: anyerror) void {
    debug_trace.logf(
        "session",
        "event=usage_sidecar_write_failed err={s}",
        .{@errorName(err)},
    );
}

fn loadOpenState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    authority_id: Identifier,
    event_log: std.Io.File,
    position: CommitPosition,
) !OpenState {
    var manifest: ?OpenManifest = loadCurrentManifestForOpen(
        alloc,
        dir,
        session_id,
        authority_id,
        event_log,
        position,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            debug_trace.logf(
                "session",
                "event=session_replay_checkpoint_fallback reason={s}",
                .{@errorName(err)},
            );
            break :blk null;
        },
    };
    defer if (manifest) |*value| value.manifest.deinit(alloc);

    var checkpoint_failed = false;
    if (manifest) |candidate| {
        const value = candidate.manifest;
        if (!candidate.event_file_matches) {
            checkpoint_failed = true;
            debug_trace.logf(
                "session",
                "event=session_replay_checkpoint_fallback reason=StaleEventFileFingerprint",
                .{},
            );
        }
        if (candidate.event_file_matches and value.checkpoint_seq != null) {
            if (replayCurrentCheckpoint(
                alloc,
                dir,
                event_log,
                value,
                position,
            )) |replayed| {
                return .{
                    .state = replayed.state,
                    .generation_base_seq = value.generation_base_seq,
                    .generation_base_bytes = value.generation_base_bytes,
                    .checkpoint_seq = value.checkpoint_seq,
                    .checkpoint_sha256 = value.checkpoint_sha256,
                    .projection_status = .current,
                    .source = .checkpoint,
                    .tail_bytes = position.through_event_log_bytes -
                        replayed.through_event_log_bytes,
                };
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    checkpoint_failed = true;
                    debug_trace.logf(
                        "session",
                        "event=session_replay_checkpoint_fallback reason={s}",
                        .{@errorName(err)},
                    );
                },
            }
        }
    }

    var state = try session_replay.replayBoundary(alloc, event_log, position);
    errdefer state.deinit(alloc);
    if (manifest) |candidate| {
        const value = candidate.manifest;
        if (session_projection.stateMatchesManifest(state, value)) {
            return .{
                .state = state,
                .generation_base_seq = value.generation_base_seq,
                .generation_base_bytes = value.generation_base_bytes,
                .checkpoint_seq = if (checkpoint_failed) null else value.checkpoint_seq,
                .checkpoint_sha256 = if (checkpoint_failed) null else value.checkpoint_sha256,
                .projection_status = if (checkpoint_failed) .stale else .current,
                .source = .event_log,
                .tail_bytes = position.through_event_log_bytes,
            };
        }
        debug_trace.logf(
            "session",
            "event=session_replay_checkpoint_fallback reason=ManifestStateMismatch",
            .{},
        );
    }
    return .{
        .state = state,
        .generation_base_seq = position.through_seq,
        .generation_base_bytes = position.through_event_log_bytes,
        .checkpoint_seq = null,
        .checkpoint_sha256 = null,
        .projection_status = .stale,
        .source = .event_log,
        .tail_bytes = position.through_event_log_bytes,
    };
}

fn loadCurrentManifestForOpen(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    authority_id: Identifier,
    event_log: std.Io.File,
    position: CommitPosition,
) !OpenManifest {
    var manifest = try loadManifest(alloc, dir);
    errdefer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &authority_id) or
        !std.mem.eql(u8, &manifest.log_generation, &position.log_generation) or
        manifest.last_event_seq != position.through_seq or
        manifest.event_log_bytes != position.through_event_log_bytes)
    {
        return error.StaleManifest;
    }
    const length = try event_log.length(io_mod.getIo());
    if (length > position.through_event_log_bytes) {
        return .{
            .manifest = manifest,
            .event_file_matches = false,
        };
    }
    const stat = try eventStat(event_log, position.through_event_log_bytes);
    return .{
        .manifest = manifest,
        .event_file_matches = !session_projection.isManifestStale(manifest, stat),
    };
}

fn replayCurrentCheckpoint(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    event_log: std.Io.File,
    manifest: session_projection.Manifest,
    position: CommitPosition,
) !CheckpointReplay {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        checkpoint_file,
        session_projection.checkpoint_max_bytes,
    );
    defer alloc.free(bytes);
    var checkpoint = try session_projection.decodeCheckpoint(alloc, bytes);
    var checkpoint_owns_state = true;
    defer {
        alloc.free(checkpoint.session_id);
        if (checkpoint_owns_state) checkpoint.state.deinit(alloc);
    }
    const checkpoint_position = CommitPosition{
        .log_generation = checkpoint.log_generation,
        .through_seq = checkpoint.through_seq,
        .through_event_id = checkpoint.through_event_id,
        .through_event_log_bytes = checkpoint.through_event_log_bytes,
    };
    try session_projection.validateCheckpointReference(
        manifest,
        bytes,
        checkpoint,
        projectionBoundary(position),
        projectionBoundary(checkpoint_position),
    );
    const checkpoint_state = checkpoint.state;
    checkpoint_owns_state = false;
    var state = try session_replay.replayFromCheckpoint(
        alloc,
        event_log,
        checkpoint_position,
        checkpoint_state,
        position,
    );
    errdefer state.deinit(alloc);
    if (!session_projection.stateMatchesManifest(state, manifest)) {
        return error.StaleCheckpoint;
    }
    return .{
        .state = state,
        .through_event_log_bytes = checkpoint_position.through_event_log_bytes,
    };
}

fn projectionBoundary(position: CommitPosition) session_projection.EventBoundary {
    return .{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_id = position.through_event_id,
        .event_log_bytes = position.through_event_log_bytes,
        .semantic = true,
    };
}

fn mapCommitLockError(err: anyerror) anyerror {
    return switch (err) {
        error.LockBusy, error.LockUnsupported => error.SessionCommitBoundaryUnavailable,
        else => err,
    };
}

fn resolveAuthorityIntent(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !AuthorityMarker {
    if (!try entryExists(&writable.dir, authority_intent_file)) {
        return loadAuthority(alloc, &writable.dir, writable.session_id);
    }
    if (!options.resolve_authority_intent) {
        return error.SessionAuthorityBoundaryUnavailable;
    }
    var intent = try loadAuthorityIntent(alloc, &writable.dir);
    defer intent.deinit(alloc);
    if (!std.mem.eql(u8, intent.session_id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    if (intent.kind != .session_create) return error.InvalidSessionFormat;

    if (!try entryExists(&writable.dir, authority_file)) {
        try io_mod.syncVerifiedDir(writable.dir.dir);
        if (try entryExists(&writable.dir, authority_file)) {
            return error.SessionStartIndeterminate;
        }
        try deleteAndSync(
            &writable.dir,
            authority_intent_file,
            options.test_controls,
            null,
        );
        return error.SessionNotFound;
    }
    try validateAuthorityTarget(
        alloc,
        &writable.dir,
        writable.session_id,
        intent,
    );
    var marker = try loadAuthority(alloc, &writable.dir, writable.session_id);
    errdefer marker.deinit(alloc);
    try deleteAndSync(
        &writable.dir,
        authority_intent_file,
        options.test_controls,
        null,
    );
    return marker;
}

fn validateAuthorityTarget(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    intent: AuthorityIntent,
) !void {
    var marker = try loadAuthority(alloc, dir, session_id);
    defer marker.deinit(alloc);
    const expected_source: AuthoritySource = switch (intent.kind) {
        .session_create => .native_create,
        .legacy_to_v3 => .legacy_migration,
    };
    if (!std.mem.eql(u8, marker.session_id, intent.session_id) or
        !std.mem.eql(u8, &marker.authority_id, &intent.authority_id) or
        marker.source != expected_source)
    {
        return error.InvalidSessionFormat;
    }
    _ = try validateLivePosition(alloc, dir, session_id, intent.proposed);
    try io_mod.syncVerifiedDir(dir.dir);
}

fn resolvePublicationIntent(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !CommitPosition {
    if (!try entryExists(&writable.dir, publication_intent_file)) {
        return loadCurrentPosition(alloc, &writable.dir, writable.session_id);
    }
    var intent = try loadPublicationIntent(alloc, &writable.dir);
    defer intent.deinit(alloc);
    if (!std.mem.eql(u8, intent.session_id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    const current_generation = try liveGeneration(alloc, &writable.dir);
    var chosen: CommitPosition = undefined;
    if (intent.kind == .watermark_advance) {
        if (!std.mem.eql(u8, &current_generation, &intent.prior.log_generation) or
            !std.mem.eql(u8, &current_generation, &intent.proposed.log_generation))
        {
            return error.SessionCommitIndeterminate;
        }
        var log = try openManagedFile(&writable.dir, events_file, .read_write);
        defer log.close(io_mod.getIo());
        const current = try loadWatermarkPosition(
            alloc,
            &writable.dir,
            writable.session_id,
            current_generation,
        );
        if (positionsEqual(current, intent.proposed)) {
            try options.test_controls.boundary(.before_recovery_proposed_validation);
            switch (try session_replay.validateCommitPositionForRecovery(
                alloc,
                log,
                intent.proposed,
            )) {
                .valid => chosen = intent.proposed,
                .invalid => {
                    try options.test_controls.boundary(.before_recovery_prior_validation);
                    try requireValidRecoveryPosition(
                        alloc,
                        log,
                        intent.prior,
                    );
                    debug_trace.logf(
                        "session",
                        "event=publication_recovery_rollback reason=invalid_proposed proposed_seq={d} proposed_bytes={d} prior_seq={d} prior_bytes={d}",
                        .{
                            intent.proposed.through_seq,
                            intent.proposed.through_event_log_bytes,
                            intent.prior.through_seq,
                            intent.prior.through_event_log_bytes,
                        },
                    );
                    try rollbackPublicationToPrior(
                        writable,
                        alloc,
                        log,
                        intent.prior,
                        options,
                    );
                    return intent.prior;
                },
            }
        } else if (positionsEqual(current, intent.prior)) {
            chosen = intent.prior;
            try options.test_controls.boundary(.before_recovery_prior_validation);
            try requireValidRecoveryPosition(alloc, log, intent.prior);
            const length = try log.length(io_mod.getIo());
            if (length < intent.prior.through_event_log_bytes) {
                return error.InvalidSessionFormat;
            }
            if (length > intent.prior.through_event_log_bytes) {
                try log.setLength(io_mod.getIo(), intent.prior.through_event_log_bytes);
                try log.sync(io_mod.getIo());
            }
            try requireValidRecoveryPosition(alloc, log, intent.prior);
        } else {
            return error.SessionCommitIndeterminate;
        }
    } else if (std.mem.eql(u8, &current_generation, &intent.proposed.log_generation)) {
        chosen = intent.proposed;
        _ = try validateLivePosition(
            alloc,
            &writable.dir,
            writable.session_id,
            chosen,
        );
    } else if (std.mem.eql(u8, &current_generation, &intent.prior.log_generation)) {
        chosen = intent.prior;
        var log = try openManagedFile(&writable.dir, events_file, .read_write);
        defer log.close(io_mod.getIo());
        const current_position = loadAndValidateWatermark(
            alloc,
            &writable.dir,
            writable.session_id,
            current_generation,
            log,
        ) catch null;
        if (current_position == null or
            !positionsEqual(current_position.?, intent.prior))
        {
            return error.SessionCommitIndeterminate;
        }
        const length = try log.length(io_mod.getIo());
        if (length < intent.prior.through_event_log_bytes) {
            return error.InvalidSessionFormat;
        }
        if (length > intent.prior.through_event_log_bytes) {
            try log.setLength(io_mod.getIo(), intent.prior.through_event_log_bytes);
            try log.sync(io_mod.getIo());
        }
        _ = try validateCommitPosition(
            alloc,
            &writable.dir,
            writable.session_id,
            chosen,
        );
    } else {
        return error.SessionCommitIndeterminate;
    }
    try io_mod.syncVerifiedDir(writable.dir.dir);
    try deleteAndSync(
        &writable.dir,
        publication_intent_file,
        options.test_controls,
        null,
    );
    return chosen;
}

fn requireValidRecoveryPosition(
    alloc: Allocator,
    log: std.Io.File,
    position: CommitPosition,
) !void {
    switch (try session_replay.validateCommitPositionForRecovery(alloc, log, position)) {
        .valid => {},
        .invalid => return error.InvalidSessionFormat,
    }
}

fn positionsEqual(lhs: CommitPosition, rhs: CommitPosition) bool {
    return std.mem.eql(u8, &lhs.log_generation, &rhs.log_generation) and
        lhs.through_seq == rhs.through_seq and
        std.mem.eql(u8, &lhs.through_event_id, &rhs.through_event_id) and
        lhs.through_event_log_bytes == rhs.through_event_log_bytes;
}

fn liveGeneration(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !Identifier {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    return session_replay.readFirstGeneration(alloc, log);
}

fn loadCurrentPosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !CommitPosition {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log);
    return loadAndValidateWatermark(alloc, dir, session_id, generation, log);
}

fn loadCurrentPositionReference(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !CommitPosition {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log);
    return loadWatermarkPosition(alloc, dir, session_id, generation);
}

fn validateLivePosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    expected: CommitPosition,
) !session_projection.EventBoundary {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log);
    if (!std.mem.eql(u8, &generation, &expected.log_generation)) {
        return error.InvalidSessionFormat;
    }
    const actual = try loadAndValidateWatermark(
        alloc,
        dir,
        session_id,
        generation,
        log,
    );
    if (!positionsEqual(actual, expected)) return error.InvalidSessionFormat;
    return validateCommitPosition(alloc, dir, session_id, expected);
}

fn loadAndValidateWatermark(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    generation: Identifier,
    event_log: std.Io.File,
) !CommitPosition {
    const position = try loadWatermarkPosition(alloc, dir, session_id, generation);
    _ = try session_replay.scanCommitPosition(alloc, event_log, position);
    return position;
}

fn loadWatermarkPosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    generation: Identifier,
) !CommitPosition {
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    const bytes = try readManagedFileAlloc(alloc, dir, name, watermark_max_bytes);
    defer alloc.free(bytes);
    return decodeWatermark(alloc, bytes, session_id, generation);
}

fn validateCommitPosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    position: CommitPosition,
) !session_projection.EventBoundary {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log);
    if (!std.mem.eql(u8, &generation, &position.log_generation)) {
        return error.InvalidSessionFormat;
    }
    const watermark = try loadAndValidateWatermark(
        alloc,
        dir,
        session_id,
        generation,
        log,
    );
    if (!positionsEqual(position, watermark)) return error.InvalidSessionFormat;
    return session_replay.scanCommitPosition(alloc, log, position);
}

fn appendEventImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    event: session_event.Event,
    timestamp_ms: i64,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
    cache_deferred: bool,
) !CommitPosition {
    try prepareCanonicalWrite(loaded, alloc, options);
    const envelope = session_event.Envelope{
        .log_generation = loaded.position.log_generation,
        .seq = std.math.add(u64, loaded.position.through_seq, 1) catch
            return error.InvalidSessionFormat,
        .event_id = randomIdentifier(),
        .timestamp_ms = timestamp_ms,
        .event = event,
    };
    const frame = try session_event.encodeFrame(alloc, envelope);
    var prepared = try prepareFailedTail(
        loaded,
        alloc,
        frame,
        envelope.seq,
        envelope.event_id,
        .{ .event = envelope.event_id },
    );
    if (cache_deferred) {
        loaded.writeDeferredCommitLifecycle(
            alloc,
            prepared.proposed,
        ) catch |err| {
            prepared.deinit(alloc);
            return err;
        };
    }
    return publishPreparedTail(
        loaded,
        alloc,
        &prepared,
        failed_tail,
        options,
        usage_sidecar_bytes,
        write_usage_sidecar,
    );
}

const IdSequence = struct {
    next_value: u128,

    fn next(raw: *anyopaque) Identifier {
        const self: *IdSequence = @ptrCast(@alignCast(raw));
        self.next_value +%= 1;
        var bytes: Identifier = undefined;
        std.mem.writeInt(u128, &bytes, self.next_value, .big);
        return bytes;
    }

    fn source(self: *IdSequence) session_event.IdentifierSource {
        return .{ .context = self, .next_fn = next };
    }
};

fn commitStateReplacementImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    reason: session_event.ReplacementReason,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
    cache_deferred: bool,
) !CommitPosition {
    try prepareCanonicalWrite(loaded, alloc, options);
    const timestamp_ms = state.updated_at_ms;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var ids = IdSequence{ .next_value = randomSequenceSeed() };
    const replacement_id = randomIdentifier();
    const summary = try session_event.writeStateReplacement(
        alloc,
        &out.writer,
        state,
        .{
            .log_generation = loaded.position.log_generation,
            .first_seq = loaded.position.through_seq + 1,
            .replacement_id = replacement_id,
            .event_ids = ids.source(),
            .timestamp_ms = timestamp_ms,
            .reason = reason,
        },
    );
    const frames = try out.toOwnedSlice();
    var prepared = try prepareFailedTail(
        loaded,
        alloc,
        frames,
        summary.last_seq,
        summary.last_event_id,
        .{ .state_replacement = .{
            .replacement_id = replacement_id,
            .final_event_id = summary.last_event_id,
        } },
    );
    if (cache_deferred) {
        loaded.writeDeferredCommitLifecycle(
            alloc,
            prepared.proposed,
        ) catch |err| {
            prepared.deinit(alloc);
            return err;
        };
    }
    return publishPreparedTail(
        loaded,
        alloc,
        &prepared,
        failed_tail,
        options,
        usage_sidecar_bytes,
        write_usage_sidecar,
    );
}

fn prepareCanonicalWrite(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    if (loaded.degraded_tail != null) return error.SessionPersistenceDegraded;
    try confirmWritableNamespace(loaded, alloc, options);
}

fn prepareFailedTail(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    frames: []u8,
    last_seq: u64,
    last_event_id: Identifier,
    kind: FailedTailKind,
) !FailedTail {
    errdefer alloc.free(frames);
    const prior = loaded.position;
    return .{
        .prior = prior,
        .proposed = .{
            .log_generation = prior.log_generation,
            .through_seq = last_seq,
            .through_event_id = last_event_id,
            .through_event_log_bytes = std.math.add(
                u64,
                prior.through_event_log_bytes,
                frames.len,
            ) catch return error.InvalidSessionFormat,
        },
        .kind = kind,
        .bytes = frames,
        .sha256 = session_projection.sha256(frames),
    };
}

fn publishPreparedTail(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    prepared: *FailedTail,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
) !CommitPosition {
    const result = publishFrames(
        loaded,
        alloc,
        prepared,
        failed_tail,
        options,
        usage_sidecar_bytes,
        write_usage_sidecar,
    ) catch |err| {
        if (failed_tail == .retry_expected_tail and
            (err == error.SessionPersistenceDegraded or
                err == error.SessionCommitIndeterminate))
        {
            if (loaded.degraded_tail) |*existing| existing.deinit(alloc);
            loaded.degraded_tail = prepared.*;
            prepared.* = undefined;
        } else {
            prepared.deinit(alloc);
        }
        return err;
    };
    loaded.state_replacement_pending = switch (prepared.kind) {
        .event => true,
        .state_replacement => false,
    };
    prepared.deinit(alloc);
    return result;
}

fn publishFrames(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    prepared: *const FailedTail,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
) !CommitPosition {
    const prior = prepared.prior;
    const proposed = prepared.proposed;
    const frames = prepared.bytes;
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    const current_length = try log.length(io_mod.getIo());
    var reused_tail = false;
    if (current_length == proposed.through_event_log_bytes) {
        const existing = try alloc.alloc(u8, frames.len);
        defer alloc.free(existing);
        const count = try log.readPositionalAll(
            io_mod.getIo(),
            existing,
            prior.through_event_log_bytes,
        );
        reused_tail = count == frames.len and std.mem.eql(u8, existing, frames);
    }
    if (!reused_tail) {
        if (current_length < prior.through_event_log_bytes) {
            return error.InvalidSessionFormat;
        }
        if (current_length > prior.through_event_log_bytes) {
            try log.setLength(io_mod.getIo(), prior.through_event_log_bytes);
            try log.sync(io_mod.getIo());
        }
        log.writePositionalAll(
            io_mod.getIo(),
            frames,
            prior.through_event_log_bytes,
        ) catch return handlePreIntentFailure(log, prior, failed_tail);
    }
    options.test_controls.boundary(.after_event_append) catch
        return handlePreIntentFailure(log, prior, failed_tail);
    log.sync(io_mod.getIo()) catch
        return handlePreIntentFailure(log, prior, failed_tail);
    options.test_controls.boundary(.after_event_sync) catch
        return handlePreIntentFailure(log, prior, failed_tail);

    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &loaded.log.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
    ) catch |err| return switch (failed_tail) {
        .rollback_before_adapter_continue => blk: {
            rollbackTail(log, prior) catch return error.SessionCommitIndeterminate;
            break :blk mapCommitLockError(err);
        },
        .retry_expected_tail => error.SessionPersistenceDegraded,
    };
    defer commit_lock.release();

    const current = loadCurrentPositionReference(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
    ) catch |err| return handleIntentFailure(
        loaded,
        alloc,
        log,
        prior,
        failed_tail,
        err,
        options,
    );
    if (!positionsEqual(current, prior) or
        try entryExists(&loaded.log.dir, publication_intent_file))
    {
        return handleIntentFailure(
            loaded,
            alloc,
            log,
            prior,
            failed_tail,
            error.SessionCommitIndeterminate,
            options,
        );
    }
    const intent = PublicationIntent{
        .session_id = loaded.log.session_id,
        .operation_id = randomIdentifier(),
        .kind = .watermark_advance,
        .prior = prior,
        .proposed = proposed,
    };
    const intent_bytes = try encodePublicationIntent(alloc, intent);
    defer alloc.free(intent_bytes);
    const watermark_bytes = try encodeWatermark(
        alloc,
        loaded.log.session_id,
        proposed,
    );
    defer alloc.free(watermark_bytes);
    const name = try watermarkName(alloc, proposed.log_generation);
    defer alloc.free(name);
    durableReplace(
        alloc,
        &loaded.log.dir,
        publication_intent_file,
        intent_bytes,
    ) catch |err| return handleIntentFailure(
        loaded,
        alloc,
        log,
        prior,
        failed_tail,
        err,
        options,
    );
    loaded.namespace_confirmation_required = true;
    options.test_controls.boundary(.after_commit_intent_sync) catch |err|
        return handleIntentFailure(
            loaded,
            alloc,
            log,
            prior,
            failed_tail,
            err,
            options,
        );

    durableReplaceWithBoundary(
        alloc,
        &loaded.log.dir,
        name,
        watermark_bytes,
        options.test_controls,
        .after_watermark_rename,
    ) catch |err| return handlePublishedTailFailure(
        loaded,
        alloc,
        log,
        prior,
        failed_tail,
        err,
        options,
    );
    loaded.resume_view_stale = true;
    switch (prepared.kind) {
        .event => {
            const published = loadCurrentPositionReference(
                alloc,
                &loaded.log.dir,
                loaded.log.session_id,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
            const exact_tail = expectedTailMatches(
                loaded,
                alloc,
                prepared.*,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
            if (!positionsEqual(published, proposed) or !exact_tail) {
                return handlePublishedTailFailure(
                    loaded,
                    alloc,
                    log,
                    prior,
                    failed_tail,
                    error.SessionCommitIndeterminate,
                    options,
                );
            }
        },
        .state_replacement => {
            _ = validateLivePosition(
                alloc,
                &loaded.log.dir,
                loaded.log.session_id,
                proposed,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
        },
    }
    options.test_controls.boundary(.after_target_namespace_sync) catch
        return error.SessionCommitIndeterminate;

    var replayed_state: ?session_codec.DurableSessionState = null;
    switch (prepared.kind) {
        .event => |event_id| {
            _ = session_event.applyEventFrame(
                alloc,
                &loaded.state,
                frames,
                .{
                    .generation = prior.log_generation,
                    .next_seq = std.math.add(u64, prior.through_seq, 1) catch
                        return handlePublishedTailFailure(
                            loaded,
                            alloc,
                            log,
                            prior,
                            failed_tail,
                            error.InvalidSessionFormat,
                            options,
                        ),
                },
                event_id,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
        },
        .state_replacement => {
            replayed_state = session_replay.replayBoundary(
                alloc,
                log,
                proposed,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
        },
    }

    var cleanup_pending = false;
    deleteAndSync(
        &loaded.log.dir,
        publication_intent_file,
        options.test_controls,
        .after_commit_intent_remove,
    ) catch {
        cleanup_pending = true;
    };
    loaded.position = proposed;
    if (replayed_state) |next_state| {
        loaded.state.deinit(alloc);
        loaded.state = next_state;
    }
    if (usage_sidecar_bytes) |bytes| {
        if (write_usage_sidecar) {
            options.test_controls.boundary(.before_usage_sidecar_write) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=usage_sidecar_test_boundary_failed err={s}",
                    .{@errorName(err)},
                );
            };
            loaded.usage_sidecar_reseal_pending =
                !writeEncodedUsageSidecarBestEffort(loaded, alloc, bytes);
        }
        restoreEncodedUsageSidecarBestEffort(loaded, alloc, bytes);
    } else if (write_usage_sidecar) {
        loaded.usage_sidecar_reseal_pending = true;
    }
    refreshProjections(alloc, loaded, options) catch {
        loaded.projection_status = .stale;
    };
    if (cleanup_pending) {
        loaded.projection_status = .stale;
    } else {
        loaded.namespace_confirmation_required = false;
    }
    return proposed;
}

fn retryDegradedWithStateReplacementImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    current_state: session_codec.DurableSessionState,
    options: Options,
) !void {
    var failed = loaded.degraded_tail orelse return;
    loaded.degraded_tail = null;
    var owns_failed = true;
    defer if (owns_failed) failed.deinit(alloc);

    confirmWritableNamespace(loaded, alloc, options) catch |err| {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return err;
    };

    if (positionsEqual(loaded.position, failed.proposed)) {
        const exact = expectedTailMatches(loaded, alloc, failed) catch |err| {
            loaded.degraded_tail = failed;
            owns_failed = false;
            return err;
        };
        if (!exact) {
            loaded.degraded_tail = failed;
            owns_failed = false;
            return error.SessionCommitIndeterminate;
        }
        if (try durableStatesRichEqual(loaded.state, current_state)) return;

        failed.deinit(alloc);
        owns_failed = false;
        _ = try loaded.commitStateReplacement(
            alloc,
            current_state,
            .recovery,
            .retry_expected_tail,
            options,
        );
        return;
    }

    if (!positionsEqual(loaded.position, failed.prior)) {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return error.SessionCommitIndeterminate;
    }

    const exact = expectedTailMatches(loaded, alloc, failed) catch |err| {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return err;
    };
    if (exact) {
        owns_failed = false;
        const usage_sidecar_bytes = if (current_state.usage) |usage|
            encodeUsageSidecarBestEffort(
                alloc,
                current_state.id,
                usage,
            )
        else
            null;
        defer if (usage_sidecar_bytes) |bytes| alloc.free(bytes);
        try loaded.prepareCommitLifecycle(
            alloc,
            loaded.state.workspace_root,
            options,
        );
        _ = publishPreparedTail(
            loaded,
            alloc,
            &failed,
            .retry_expected_tail,
            options,
            usage_sidecar_bytes,
            true,
        ) catch |err| {
            loaded.abortCommitLifecycle();
            return err;
        };
        _ = loaded.publishCommitLifecycle(alloc);
        try maintainCanonicalLogAfterCommit(loaded, alloc, options);
        if (try durableStatesEqual(loaded.state, current_state)) return;
        _ = try loaded.commitStateReplacement(
            alloc,
            current_state,
            .recovery,
            .retry_expected_tail,
            options,
        );
        return;
    }

    var log = openManagedFile(
        &loaded.log.dir,
        events_file,
        .read_write,
    ) catch |err| {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return err;
    };
    defer log.close(io_mod.getIo());
    const length = log.length(io_mod.getIo()) catch |err| {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return err;
    };
    if (length < failed.prior.through_event_log_bytes) {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return error.SessionCommitIndeterminate;
    }
    rollbackTail(log, failed.prior) catch {
        loaded.degraded_tail = failed;
        owns_failed = false;
        return error.SessionPersistenceDegraded;
    };

    failed.deinit(alloc);
    owns_failed = false;
    _ = try loaded.commitStateReplacement(
        alloc,
        current_state,
        .recovery,
        .retry_expected_tail,
        options,
    );
}

fn expectedTailMatches(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    failed: FailedTail,
) !bool {
    if (!positionsEqual(loaded.position, failed.prior) and
        !positionsEqual(loaded.position, failed.proposed))
    {
        return false;
    }
    if (!std.mem.eql(
        u8,
        &failed.proposed.log_generation,
        &failed.prior.log_generation,
    ) or
        failed.proposed.through_event_log_bytes !=
            failed.prior.through_event_log_bytes + failed.bytes.len or
        !std.mem.eql(
            u8,
            &session_projection.sha256(failed.bytes),
            &failed.sha256,
        ))
    {
        return false;
    }
    switch (failed.kind) {
        .event => |event_id| {
            if (!std.mem.eql(
                u8,
                &event_id,
                &failed.proposed.through_event_id,
            )) return false;
        },
        .state_replacement => |replacement| {
            if (!std.mem.eql(
                u8,
                &replacement.final_event_id,
                &failed.proposed.through_event_id,
            )) return false;
        },
    }

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const length = try log.length(io_mod.getIo());
    if (length != failed.proposed.through_event_log_bytes) return false;
    const actual = try alloc.alloc(u8, failed.bytes.len);
    defer alloc.free(actual);
    const count = try log.readPositionalAll(
        io_mod.getIo(),
        actual,
        failed.prior.through_event_log_bytes,
    );
    return count == failed.bytes.len and
        std.mem.eql(u8, actual, failed.bytes) and
        std.mem.eql(
            u8,
            &session_projection.sha256(actual),
            &failed.sha256,
        );
}

pub fn durableStatesEqual(
    first: session_codec.DurableSessionState,
    second: session_codec.DurableSessionState,
) !bool {
    var first_buffer: [4096]u8 = undefined;
    var first_discard = std.Io.Writer.Discarding.init(&first_buffer);
    const first_summary = try session_codec.encodeState(
        first,
        &first_discard.writer,
    );
    var second_buffer: [4096]u8 = undefined;
    var second_discard = std.Io.Writer.Discarding.init(&second_buffer);
    const second_summary = try session_codec.encodeState(
        second,
        &second_discard.writer,
    );
    return first_summary.encoded_bytes == second_summary.encoded_bytes and
        std.mem.eql(
            u8,
            &first_summary.sha256,
            &second_summary.sha256,
        );
}

fn durableStatesRichEqual(
    first: session_codec.DurableSessionState,
    second: session_codec.DurableSessionState,
) !bool {
    if (!try durableStatesEqual(first, second)) return false;
    if (first.usage == null or second.usage == null) {
        return first.usage == null and second.usage == null;
    }
    return session_usage.snapshotEql(first.usage.?, second.usage.?);
}

fn confirmWritableNamespace(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    if (!loaded.namespace_confirmation_required) return;

    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &loaded.log.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
    ) catch |err| return mapCommitLockError(err);
    defer commit_lock.release();

    var marker = try resolveAuthorityIntent(alloc, &loaded.log, options);
    defer marker.deinit(alloc);
    if (!std.mem.eql(u8, &marker.authority_id, &loaded.authority_id)) {
        return error.SessionCommitIndeterminate;
    }
    const position = try resolvePublicationIntent(alloc, &loaded.log, options);
    if (!positionsEqual(position, loaded.position)) {
        var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
        defer log.close(io_mod.getIo());
        const length = try log.length(io_mod.getIo());
        if (length < position.through_event_log_bytes) {
            return error.SessionCommitIndeterminate;
        }
        if (length > position.through_event_log_bytes) {
            try log.setLength(io_mod.getIo(), position.through_event_log_bytes);
            try log.sync(io_mod.getIo());
        }
        const next_state = session_replay.replayBoundary(alloc, log, position) catch |err| switch (err) {
            error.OutOfMemory => return error.SessionReplayResourceExhausted,
            else => return err,
        };
        const generation_changed = !std.mem.eql(
            u8,
            &position.log_generation,
            &loaded.position.log_generation,
        );
        loaded.state.deinit(alloc);
        loaded.state = next_state;
        loaded.position = position;
        loaded.resume_view_stale = true;
        if (generation_changed) {
            loaded.generation_base_seq = position.through_seq;
            loaded.generation_base_bytes = position.through_event_log_bytes;
            loaded.checkpoint_seq = null;
            loaded.checkpoint_sha256 = null;
        }
        loaded.projection_status = .stale;
    }
    try io_mod.syncVerifiedDir(loaded.log.dir.dir);
    loaded.namespace_confirmation_required = false;
}

fn handlePreIntentFailure(
    log: std.Io.File,
    prior: CommitPosition,
    failed_tail: FailedTailDisposition,
) anyerror {
    return switch (failed_tail) {
        .retry_expected_tail => error.SessionPersistenceDegraded,
        .rollback_before_adapter_continue => blk: {
            rollbackTail(log, prior) catch break :blk error.SessionCommitIndeterminate;
            break :blk error.SessionPersistenceDegraded;
        },
    };
}

fn rollbackTail(log: std.Io.File, prior: CommitPosition) !void {
    try log.setLength(io_mod.getIo(), prior.through_event_log_bytes);
    try log.sync(io_mod.getIo());
}

fn handleIntentFailure(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    log: std.Io.File,
    prior: CommitPosition,
    failed_tail: FailedTailDisposition,
    cause: anyerror,
    options: Options,
) anyerror {
    if (cause == error.OutOfMemory) return error.OutOfMemory;
    if (failed_tail == .retry_expected_tail) {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    }
    rollbackPublicationToPrior(
        &loaded.log,
        alloc,
        log,
        prior,
        options,
    ) catch {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    };
    loaded.namespace_confirmation_required = false;
    return error.SessionPersistenceDegraded;
}

fn handlePublishedTailFailure(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    log: std.Io.File,
    prior: CommitPosition,
    failed_tail: FailedTailDisposition,
    _: anyerror,
    options: Options,
) anyerror {
    if (failed_tail == .retry_expected_tail) {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    }
    rollbackPublicationToPrior(
        &loaded.log,
        alloc,
        log,
        prior,
        options,
    ) catch {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    };
    loaded.namespace_confirmation_required = false;
    return error.SessionPersistenceDegraded;
}

fn rollbackPublicationToPrior(
    writable: *WritableSessionDir,
    alloc: Allocator,
    log: std.Io.File,
    prior: CommitPosition,
    options: Options,
) !void {
    const bytes = try encodeWatermark(alloc, writable.session_id, prior);
    defer alloc.free(bytes);
    const name = try watermarkName(alloc, prior.log_generation);
    defer alloc.free(name);
    try rollbackTail(log, prior);
    try durableReplace(alloc, &writable.dir, name, bytes);
    _ = try validateLivePosition(
        alloc,
        &writable.dir,
        writable.session_id,
        prior,
    );
    if (try entryExists(&writable.dir, publication_intent_file)) {
        try deleteAndSync(
            &writable.dir,
            publication_intent_file,
            options.test_controls,
            null,
        );
    }
}

fn refreshProjections(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    options: Options,
) !void {
    if (checkpointDue(loaded, options.checkpoint_interval)) {
        writeCheckpointProjection(alloc, loaded) catch |err| switch (err) {
            error.CheckpointTooLarge => {},
            else => return err,
        };
    }
    try writeManifestProjection(alloc, loaded);
    loaded.projection_status = .current;
}

fn checkpointDue(loaded: *LoadedWritableSession, interval: u64) bool {
    return interval > 0 and
        (loaded.checkpoint_seq == null or
            loaded.position.through_seq - loaded.checkpoint_seq.? >= interval);
}

fn writeCheckpointProjection(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
) !void {
    const checkpoint = session_projection.Checkpoint{
        .session_id = loaded.log.session_id,
        .log_generation = loaded.position.log_generation,
        .through_seq = loaded.position.through_seq,
        .through_event_id = loaded.position.through_event_id,
        .through_event_log_bytes = loaded.position.through_event_log_bytes,
        .state = loaded.state,
    };
    const bytes = try session_projection.encodeCheckpoint(alloc, checkpoint);
    defer alloc.free(bytes);
    try durableReplace(alloc, &loaded.log.dir, checkpoint_file, bytes);
    loaded.checkpoint_seq = loaded.position.through_seq;
    loaded.checkpoint_sha256 = session_projection.sha256(bytes);
}

fn writeManifestProjection(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
) !void {
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const stat = try eventStat(log, loaded.position.through_event_log_bytes);
    const fingerprint = try session_projection.eventFileStatFingerprint(
        stat,
        loaded.position.through_event_log_bytes,
    );
    const manifest = session_projection.Manifest{
        .id = loaded.log.session_id,
        .authority_id = loaded.authority_id,
        .log_generation = loaded.position.log_generation,
        .created_at_ms = loaded.state.created_at_ms,
        .updated_at_ms = loaded.state.updated_at_ms,
        .origin_workspace_root = loaded.state.origin_workspace_root,
        .workspace_root = loaded.state.workspace_root,
        .conversation_language = loaded.state.conversation_language,
        .history_len = loaded.state.history.len,
        .total_input_tokens = loaded.state.total_input_tokens,
        .total_output_tokens = loaded.state.total_output_tokens,
        .last_event_seq = loaded.position.through_seq,
        .event_log_bytes = loaded.position.through_event_log_bytes,
        .event_log_stat_fingerprint = fingerprint,
        .generation_base_seq = loaded.generation_base_seq,
        .generation_base_bytes = loaded.generation_base_bytes,
        .checkpoint_seq = loaded.checkpoint_seq,
        .checkpoint_sha256 = loaded.checkpoint_sha256,
        .preferences = loaded.state.preferences,
    };
    const bytes = try session_projection.encodeManifest(alloc, manifest);
    defer alloc.free(bytes);
    try durableReplace(alloc, &loaded.log.dir, manifest_file, bytes);

    var display = try displayMetadataForProjection(alloc, loaded);
    defer display.metadata.deinit(alloc);
    // A present sidecar is frozen and already durable; only first derivations
    // (or repairs after a failed read) are written.
    if (display.metadata.present and !display.from_sidecar) {
        if (display.metadata.origin_workspace_root == null) {
            display.metadata.origin_workspace_root = try alloc.dupe(u8, loaded.state.origin_workspace_root);
        }
        try session_display_metadata.writeSidecar(alloc, &loaded.log.dir, display.metadata);
    }
}

const ProjectionDisplayMetadata = struct {
    metadata: session_display_metadata.DisplayMetadata,
    from_sidecar: bool,
};

fn displayMetadataForProjection(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
) !ProjectionDisplayMetadata {
    var existing = session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "session",
                "event=display_sidecar_read_failed id={s} err={s}",
                .{ loaded.log.session_id, @errorName(err) },
            );
            return .{
                .metadata = try session_display_metadata.deriveFromHistory(alloc, loaded.state.history),
                .from_sidecar = false,
            };
        },
    };
    if (existing.present) return .{ .metadata = existing, .from_sidecar = true };
    existing.deinit(alloc);
    return .{
        .metadata = try session_display_metadata.deriveFromHistory(alloc, loaded.state.history),
        .from_sidecar = false,
    };
}

fn eventStat(
    file: std.Io.File,
    expected_size: u64,
) !session_projection.EventFileStat {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.size != expected_size) {
        return error.InvalidEventFileStat;
    }
    return .{
        .device = try eventDevice(file),
        .inode = @intCast(stat.inode),
        .kind = .regular,
        .mode = stat.permissions.toMode(),
        .link_count = @intCast(stat.nlink),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
    };
}

fn eventDevice(file: std.Io.File) !u64 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            while (true) {
                var statx = std.mem.zeroes(linux.Statx);
                switch (linux.errno(linux.statx(
                    file.handle,
                    "",
                    linux.AT.EMPTY_PATH,
                    linux.STATX.BASIC_STATS,
                    &statx,
                ))) {
                    .SUCCESS => {
                        const major: u64 = statx.dev_major;
                        const minor: u64 = statx.dev_minor;
                        break :blk (minor & 0xff) |
                            ((major & 0xfff) << 8) |
                            ((minor & ~@as(u64, 0xff)) << 12) |
                            ((major & ~@as(u64, 0xfff)) << 32);
                    },
                    .INTR => {},
                    else => return error.InvalidEventFileStat,
                }
            }
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => blk: {
            while (true) {
                var native = std.mem.zeroes(std.c.Stat);
                switch (std.c.errno(std.c.fstat(file.handle, &native))) {
                    .SUCCESS => break :blk @intCast(native.dev),
                    .INTR => {},
                    else => return error.InvalidEventFileStat,
                }
            }
        },
        else => 0,
    };
}

fn compactCanonicalLogIfDueImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    try confirmWritableNamespace(loaded, alloc, options);
    const frame_growth = loaded.position.through_seq - loaded.generation_base_seq;
    const byte_growth =
        loaded.position.through_event_log_bytes - loaded.generation_base_bytes;
    if (frame_growth < options.compaction_frame_threshold and
        byte_growth < options.compaction_byte_threshold)
    {
        return;
    }
    compactCanonicalLog(loaded, alloc, options) catch |err| switch (err) {
        error.OutOfMemory,
        error.SessionLogCompactionIndeterminate,
        => return err,
        else => return error.SessionLogCompactionFailed,
    };
}

fn maintainCanonicalLogAfterCommit(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    if (loaded.namespace_confirmation_required) return;
    compactCanonicalLogIfDueImpl(loaded, alloc, options) catch |err| {
        if (!loaded.compaction_warning_active) {
            const frame_growth =
                loaded.position.through_seq - loaded.generation_base_seq;
            const byte_growth =
                loaded.position.through_event_log_bytes -
                loaded.generation_base_bytes;
            debug_trace.logf(
                "session",
                "event=canonical_log_compaction_failed kind={s} current_bytes={d} growth_bytes={d} growth_frames={d}",
                .{
                    @errorName(err),
                    loaded.position.through_event_log_bytes,
                    byte_growth,
                    frame_growth,
                },
            );
            loaded.compaction_warning_active = true;
        }
        if (err == error.SessionLogCompactionIndeterminate) return err;
        return;
    };
    loaded.compaction_warning_active = false;
}

fn compactCanonicalLog(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    const new_generation = randomIdentifier();
    const first_id = randomIdentifier();
    const session_started = session_event.Envelope{
        .log_generation = new_generation,
        .seq = 1,
        .event_id = first_id,
        .timestamp_ms = loaded.state.updated_at_ms,
        .event = .{ .session_started = .{
            .id = loaded.state.id,
            .created_at_ms = loaded.state.created_at_ms,
            .origin_workspace_root = loaded.state.origin_workspace_root,
            .workspace_root = loaded.state.workspace_root,
            .conversation_language = loaded.state.conversation_language,
            .preferences = loaded.state.preferences,
            .usage = loaded.state.usage,
        } },
    };
    const first_line = try session_event.encodeFrame(alloc, session_started);
    defer alloc.free(first_line);
    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    try content.writer.writeAll(first_line);
    var ids = IdSequence{ .next_value = randomSequenceSeed() };
    const replacement = try session_event.writeStateReplacement(
        alloc,
        &content.writer,
        loaded.state,
        .{
            .log_generation = new_generation,
            .first_seq = 2,
            .replacement_id = randomIdentifier(),
            .event_ids = ids.source(),
            .timestamp_ms = loaded.state.updated_at_ms,
            .reason = .log_compaction,
        },
    );
    const suffix = identifierHex(new_generation);
    const temp_name = try std.fmt.allocPrint(
        alloc,
        "events.compact.{s}.tmp",
        .{suffix},
    );
    defer alloc.free(temp_name);
    var temp = try createManagedFile(&loaded.log.dir, temp_name);
    defer temp.close(io_mod.getIo());
    try temp.writePositionalAll(io_mod.getIo(), content.written(), 0);
    try temp.sync(io_mod.getIo());
    try options.test_controls.boundary(.after_compaction_temp_sync);
    const proposed = CommitPosition{
        .log_generation = new_generation,
        .through_seq = replacement.last_seq,
        .through_event_id = replacement.last_event_id,
        .through_event_log_bytes = content.written().len,
    };
    _ = try session_replay.scanCommitPosition(alloc, temp, proposed);
    const watermark_bytes = try encodeWatermark(
        alloc,
        loaded.log.session_id,
        proposed,
    );
    defer alloc.free(watermark_bytes);
    const new_watermark = try watermarkName(alloc, new_generation);
    defer alloc.free(new_watermark);
    try durableReplace(
        alloc,
        &loaded.log.dir,
        new_watermark,
        watermark_bytes,
    );
    try options.test_controls.boundary(.after_compaction_watermark_sync);

    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &loaded.log.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
    ) catch |err| return mapCommitLockError(err);
    defer commit_lock.release();
    const current = try loadCurrentPosition(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
    );
    if (!positionsEqual(current, loaded.position)) {
        return error.SessionLogCompactionFailed;
    }
    const intent = PublicationIntent{
        .session_id = loaded.log.session_id,
        .operation_id = randomIdentifier(),
        .kind = .log_generation_replace,
        .prior = loaded.position,
        .proposed = proposed,
    };
    const intent_bytes = try encodePublicationIntent(alloc, intent);
    defer alloc.free(intent_bytes);
    if (try entryExists(&loaded.log.dir, publication_intent_file)) {
        return error.SessionLogCompactionIndeterminate;
    }
    try durableReplace(
        alloc,
        &loaded.log.dir,
        publication_intent_file,
        intent_bytes,
    );
    loaded.namespace_confirmation_required = true;
    options.test_controls.boundary(.after_compaction_intent_sync) catch
        return error.SessionLogCompactionIndeterminate;
    loaded.log.dir.dir.rename(
        temp_name,
        loaded.log.dir.dir,
        events_file,
        io_mod.getIo(),
    ) catch return error.SessionLogCompactionIndeterminate;
    loaded.resume_view_stale = true;
    options.test_controls.boundary(.after_compaction_log_rename) catch
        return error.SessionLogCompactionIndeterminate;
    io_mod.syncVerifiedDir(loaded.log.dir.dir) catch
        return error.SessionLogCompactionIndeterminate;
    options.test_controls.boundary(.after_compaction_namespace_sync) catch
        return error.SessionLogCompactionIndeterminate;
    _ = validateLivePosition(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
        proposed,
    ) catch return error.SessionLogCompactionIndeterminate;
    options.test_controls.boundary(.after_compaction_live_confirmation) catch
        return error.SessionLogCompactionIndeterminate;
    var cleanup_pending = false;
    deleteAndSync(
        &loaded.log.dir,
        publication_intent_file,
        options.test_controls,
        .after_compaction_intent_remove,
    ) catch {
        loaded.projection_status = .stale;
        cleanup_pending = true;
    };
    if (!cleanup_pending) {
        loaded.namespace_confirmation_required = false;
    }
    loaded.position = proposed;
    loaded.generation_base_seq = proposed.through_seq;
    loaded.generation_base_bytes = proposed.through_event_log_bytes;
    loaded.checkpoint_seq = null;
    loaded.checkpoint_sha256 = null;
    var live = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer live.close(io_mod.getIo());
    const compacted_state = try session_replay.replayBoundary(alloc, live, proposed);
    loaded.state.deinit(alloc);
    loaded.state = compacted_state;
    writeCheckpointProjection(alloc, loaded) catch {};
    writeManifestProjection(alloc, loaded) catch {
        loaded.projection_status = .stale;
    };
    loaded.state_replacement_pending = false;
}

const CleanupCandidates = struct {
    temp_name: []u8,
    watermark_name: []u8,
};

fn makeCleanupCandidatesForTest(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
) !CleanupCandidates {
    const generation = randomIdentifier();
    const first_id = randomIdentifier();
    const envelope = session_event.Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = first_id,
        .timestamp_ms = loaded.state.created_at_ms,
        .event = .{ .session_started = .{
            .id = loaded.state.id,
            .created_at_ms = loaded.state.created_at_ms,
            .origin_workspace_root = loaded.state.origin_workspace_root,
            .workspace_root = loaded.state.workspace_root,
            .conversation_language = loaded.state.conversation_language,
            .preferences = loaded.state.preferences,
            .usage = loaded.state.usage,
        } },
    };
    const line = try session_event.encodeFrame(alloc, envelope);
    defer alloc.free(line);
    const suffix = identifierHex(generation);
    const temp_name = try std.fmt.allocPrint(
        alloc,
        "events.compact.{s}.tmp",
        .{suffix},
    );
    errdefer alloc.free(temp_name);
    var file = try createManagedFile(&loaded.log.dir, temp_name);
    defer file.close(io_mod.getIo());
    try file.writePositionalAll(io_mod.getIo(), line, 0);
    try file.sync(io_mod.getIo());
    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = first_id,
        .through_event_log_bytes = line.len,
    };
    const watermark_name = try watermarkName(alloc, generation);
    errdefer alloc.free(watermark_name);
    const bytes = try encodeWatermark(alloc, loaded.log.session_id, position);
    defer alloc.free(bytes);
    try durableReplace(alloc, &loaded.log.dir, watermark_name, bytes);
    return .{ .temp_name = temp_name, .watermark_name = watermark_name };
}

fn cleanupOrphansImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    mode: CleanupMode,
    options: Options,
) !CleanupReport {
    options.test_controls.lock(.commit);
    var commit_lock = acquireLock(
        &loaded.log.dir,
        commit_lock_file,
        true,
    ) catch return .{ .report_only = 1 };
    defer commit_lock.release();
    if (try entryExists(&loaded.log.dir, authority_intent_file) or
        try entryExists(&loaded.log.dir, publication_intent_file))
    {
        return .{ .report_only = 1 };
    }
    var marker = try loadAuthority(alloc, &loaded.log.dir, loaded.log.session_id);
    defer marker.deinit(alloc);
    const current = try loadCurrentPosition(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
    );
    try io_mod.syncVerifiedDir(loaded.log.dir.dir);

    var report: CleanupReport = .{};
    var iterator = loaded.log.dir.dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        const generation = cleanupCandidateGeneration(entry.name) orelse continue;
        if (std.mem.eql(u8, &generation, &current.log_generation)) {
            report.ignored += 1;
            continue;
        }
        const stat = loaded.log.dir.dir.statFile(io_mod.getIo(), entry.name, .{
            .follow_symlinks = false,
        }) catch {
            report.ignored += 1;
            continue;
        };
        if (stat.kind != .file or stat.nlink != 1 or
            stat.permissions.toMode() & 0o777 != 0o600)
        {
            report.ignored += 1;
            continue;
        }
        const valid = if (std.mem.startsWith(u8, entry.name, "commit."))
            validateOrphanWatermark(
                alloc,
                &loaded.log.dir,
                entry.name,
                loaded.log.session_id,
                generation,
            )
        else
            validateOrphanTemp(
                alloc,
                &loaded.log.dir,
                entry.name,
                loaded.log.session_id,
                generation,
            );
        valid catch {
            report.ignored += 1;
            continue;
        };
        if (mode == .report_only) {
            report.report_only += 1;
            continue;
        }
        try loaded.log.dir.dir.deleteFile(io_mod.getIo(), entry.name);
        report.removed += 1;
    }
    if (report.removed > 0) try io_mod.syncVerifiedDir(loaded.log.dir.dir);
    return report;
}

pub fn cleanupCandidateGeneration(name: []const u8) ?session_event.Identifier {
    if (std.mem.startsWith(u8, name, "commit.") and
        std.mem.endsWith(u8, name, ".json") and name.len == 44)
    {
        return parseIdentifier(name[7..39]) catch null;
    }
    const prefix = "events.compact.";
    const suffix = ".tmp";
    if (std.mem.startsWith(u8, name, prefix) and
        std.mem.endsWith(u8, name, suffix) and
        name.len == prefix.len + 32 + suffix.len)
    {
        return parseIdentifier(name[prefix.len .. prefix.len + 32]) catch null;
    }
    return null;
}

pub fn hasValidatedCompactionTemp(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !bool {
    var entries = dir.dir.iterate();
    while (try entries.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "events.compact.")) continue;
        const generation = cleanupCandidateGeneration(entry.name) orelse
            continue;
        validateOrphanTemp(
            alloc,
            dir,
            entry.name,
            session_id,
            generation,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        return true;
    }
    return false;
}

fn validateOrphanWatermark(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    session_id: []const u8,
    generation: Identifier,
) !void {
    const bytes = try readManagedFileAlloc(alloc, dir, name, watermark_max_bytes);
    defer alloc.free(bytes);
    _ = try decodeWatermark(alloc, bytes, session_id, generation);
}

fn validateOrphanTemp(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    session_id: []const u8,
    generation: Identifier,
) !void {
    var file = try openManagedFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    var validator: session_event.SequenceValidator = .{};
    var offset: u64 = 0;
    var replacement_open = false;
    var replacement_id: Identifier = undefined;
    var last: ?CommitPosition = null;
    while (offset < length) {
        const line = try session_replay.readLineAt(alloc, file, offset, length) orelse
            return error.InvalidSessionFormat;
        defer alloc.free(line.bytes);
        var envelope = session_event.decodeFrame(alloc, line.bytes) catch
            return error.InvalidSessionFormat;
        defer envelope.deinit(alloc);
        validator.validate(envelope) catch return error.InvalidSessionFormat;
        if (!std.mem.eql(u8, &envelope.log_generation, &generation)) {
            return error.InvalidSessionFormat;
        }
        if (envelope.seq == 1 and
            (envelope.kind() != .session_started or
                !std.mem.eql(u8, envelope.event.session_started.id, session_id)))
        {
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
                    !std.mem.eql(u8, &replacement_id, &chunk.replacement_id))
                {
                    return error.InvalidSessionFormat;
                }
            },
            .state_replacement_committed => |commit| {
                if (!replacement_open or
                    !std.mem.eql(u8, &replacement_id, &commit.replacement_id))
                {
                    return error.InvalidSessionFormat;
                }
                replacement_open = false;
                last = .{
                    .log_generation = generation,
                    .through_seq = envelope.seq,
                    .through_event_id = envelope.event_id,
                    .through_event_log_bytes = line.next_offset,
                };
            },
            else => {
                if (replacement_open) return error.InvalidSessionFormat;
                last = .{
                    .log_generation = generation,
                    .through_seq = envelope.seq,
                    .through_event_id = envelope.event_id,
                    .through_event_log_bytes = line.next_offset,
                };
            },
        }
        offset = line.next_offset;
    }
    if (offset != length or replacement_open) return error.InvalidSessionFormat;
    _ = try session_replay.scanCommitPosition(
        alloc,
        file,
        last orelse return error.InvalidSessionFormat,
    );
}

const BoundaryFailure = struct {
    target: Boundary,

    fn hit(raw: ?*anyopaque, point: Boundary) !void {
        const self: *BoundaryFailure = @ptrCast(@alignCast(raw.?));
        if (point == self.target) return error.InjectedBoundaryFailure;
    }

    fn test_controls(self: *BoundaryFailure) TestControls {
        return .{ .context = self, .boundary_fn = hit };
    }
};

const LockTrace = struct {
    items: [16]LockKind = undefined,
    len: usize = 0,

    fn record(raw: ?*anyopaque, kind: LockKind) void {
        const self: *LockTrace = @ptrCast(@alignCast(raw.?));
        self.items[self.len] = kind;
        self.len += 1;
    }

    fn test_controls(self: *LockTrace) TestControls {
        return .{ .context = self, .lock_fn = record };
    }
};

const TempRoot = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    root: Root,

    fn init(alloc: Allocator) !TempRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io_mod.getIo(), "home", std.Io.File.Permissions.fromMode(0o700));
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        var root = try Root.initFromHome(alloc, home, .writable);
        errdefer root.deinit(alloc);
        return .{ .tmp = tmp, .home = home, .root = root };
    }

    fn deinit(self: *TempRoot, alloc: Allocator) void {
        self.root.deinit(alloc);
        alloc.free(self.home);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "root init rejects symlinked durable and sessions roots" {
    const alloc = std.testing.allocator;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home");
        try tmp.dir.createDirPath(io_mod.getIo(), "outside");
        tmp.dir.symLink(
            io_mod.getIo(),
            "../outside",
            "home/.fx",
            .{ .is_directory = true },
        ) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);

        try std.testing.expectError(
            error.SessionPathUnsafe,
            Root.initFromHome(alloc, home, .writable),
        );
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "outside");
        tmp.dir.symLink(
            io_mod.getIo(),
            "../../outside",
            "home/.fx/sessions",
            .{ .is_directory = true },
        ) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);

        try std.testing.expectError(
            error.SessionPathUnsafe,
            Root.initFromHome(alloc, home, .writable),
        );
    }
}

fn testState(alloc: Allocator, id: []const u8, updated_at_ms: i64) !session_codec.DurableSessionState {
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, "/tmp/fx-plan-03"),
        .workspace_root = try alloc.dupe(u8, "/tmp/fx-plan-03"),
        .created_at_ms = 10,
        .updated_at_ms = updated_at_ms,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn stateWithTurn(
    alloc: Allocator,
    prior: session_codec.DurableSessionState,
    updated_at_ms: i64,
) !session_codec.DurableSessionState {
    return stateWithPrompt(alloc, prior, updated_at_ms, "hello", "world");
}

fn stateWithPrompt(
    alloc: Allocator,
    prior: session_codec.DurableSessionState,
    updated_at_ms: i64,
    prompt: []const u8,
    response: []const u8,
) !session_codec.DurableSessionState {
    var next = try prior.dupe(alloc);
    errdefer next.deinit(alloc);
    const history = try alloc.alloc(session.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try session.makeAssistantTurn(alloc, prompt, response);
    session.freeHistoryTurnSlice(alloc, next.history);
    next.history = history;
    next.updated_at_ms = updated_at_ms;
    next.total_input_tokens = 11;
    next.total_output_tokens = 7;
    return next;
}

const PendingReplacementTestPositions = struct {
    prior: CommitPosition,
    proposed: CommitPosition,
};

fn leavePendingReplacementForTest(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    updated_at_ms: i64,
) !PendingReplacementTestPositions {
    var replacement = try stateWithTurn(alloc, loaded.state, updated_at_ms);
    defer replacement.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_target_namespace_sync };
    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.commitStateReplacement(
            alloc,
            replacement,
            .recovery,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    const failed = loaded.degradedTail() orelse return error.TestUnexpectedResult;
    return .{ .prior = failed.prior, .proposed = failed.proposed };
}

fn replaceFrameByteForTest(
    alloc: Allocator,
    log: std.Io.File,
    frame_offset: u64,
    boundary: u64,
    needle: []const u8,
    replacement: u8,
) !void {
    const line = try session_replay.readLineAt(
        alloc,
        log,
        frame_offset,
        boundary,
    ) orelse return error.TestUnexpectedResult;
    defer alloc.free(line.bytes);
    const match = std.mem.find(u8, line.bytes, needle) orelse
        return error.TestUnexpectedResult;
    line.bytes[match + needle.len - 1] = replacement;
    try log.writePositionalAll(io_mod.getIo(), line.bytes, frame_offset);
    try log.sync(io_mod.getIo());
}

fn corruptReplacementCommitTimestampForTest(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    positions: PendingReplacementTestPositions,
) !void {
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    var offset = positions.prior.through_event_log_bytes;
    while (offset < positions.proposed.through_event_log_bytes) {
        const line = try session_replay.readLineAt(
            alloc,
            log,
            offset,
            positions.proposed.through_event_log_bytes,
        ) orelse return error.TestUnexpectedResult;
        defer alloc.free(line.bytes);
        var envelope = try session_event.decodeFrame(alloc, line.bytes);
        defer envelope.deinit(alloc);
        if (envelope.kind() == .state_replacement_committed) {
            const needle = "\"timestamp_ms\":20";
            const match = std.mem.find(u8, line.bytes, needle) orelse
                return error.TestUnexpectedResult;
            line.bytes[match + needle.len - 1] = '1';
            try log.writePositionalAll(io_mod.getIo(), line.bytes, offset);
            try log.sync(io_mod.getIo());
            return;
        }
        offset = line.next_offset;
    }
    return error.TestUnexpectedResult;
}

fn corruptReplacementChunkSchemaForTest(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    positions: PendingReplacementTestPositions,
) !void {
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    const start = try session_replay.readLineAt(
        alloc,
        log,
        positions.prior.through_event_log_bytes,
        positions.proposed.through_event_log_bytes,
    ) orelse return error.TestUnexpectedResult;
    defer alloc.free(start.bytes);
    try replaceFrameByteForTest(
        alloc,
        log,
        start.next_offset,
        positions.proposed.through_event_log_bytes,
        "\"schema_version\":1",
        '9',
    );
}

const PublicationBytesSnapshot = struct {
    events: []u8,
    watermark: []u8,
    intent: []u8,

    fn deinit(self: *PublicationBytesSnapshot, alloc: Allocator) void {
        alloc.free(self.events);
        alloc.free(self.watermark);
        alloc.free(self.intent);
        self.* = undefined;
    }

    fn expectEqual(self: PublicationBytesSnapshot, other: PublicationBytesSnapshot) !void {
        try std.testing.expectEqualSlices(u8, self.events, other.events);
        try std.testing.expectEqualSlices(u8, self.watermark, other.watermark);
        try std.testing.expectEqualSlices(u8, self.intent, other.intent);
    }
};

fn capturePublicationBytesForTest(
    alloc: Allocator,
    root: *Root,
    session_id: []const u8,
    generation: Identifier,
) !PublicationBytesSnapshot {
    var dir = try openSessionDir(&root.sessions.?, session_id, .read_only);
    defer dir.close();
    var log = try openManagedFile(&dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const events = try io_mod.readFileToEnd(alloc, &log, 16 * 1024 * 1024);
    errdefer alloc.free(events);
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    const watermark = try readManagedFileAlloc(alloc, &dir, name, watermark_max_bytes);
    errdefer alloc.free(watermark);
    const intent = try readManagedFileAlloc(
        alloc,
        &dir,
        publication_intent_file,
        publication_intent_max_bytes,
    );
    return .{ .events = events, .watermark = watermark, .intent = intent };
}

test "state replacement uses the durable state timestamp for every frame" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-replacement-timestamp", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const first_replacement_byte = loaded.position.through_event_log_bytes;
    var replacement = try stateWithTurn(alloc, loaded.state, 4242);
    defer replacement.deinit(alloc);

    const committed = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(@as(i64, 4242), loaded.state.updated_at_ms);

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var offset = first_replacement_byte;
    var frame_count: usize = 0;
    while (offset < committed.through_event_log_bytes) {
        const line = try session_replay.readLineAt(
            alloc,
            log,
            offset,
            committed.through_event_log_bytes,
        ) orelse return error.TestUnexpectedResult;
        defer alloc.free(line.bytes);
        var envelope = try session_event.decodeFrame(alloc, line.bytes);
        defer envelope.deinit(alloc);
        try std.testing.expectEqual(@as(i64, 4242), envelope.timestamp_ms);
        offset = line.next_offset;
        frame_count += 1;
    }
    try std.testing.expect(frame_count >= 3);

    var replayed = try session_replay.replayBoundary(alloc, log, committed);
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 4242), replayed.updated_at_ms);
}

test "usage sidecar restores exact optional metrics after read-only and writable resume" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-resume", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        7,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "vercel",
        "https://ai-gateway.vercel.sh",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.02,
        .input_tokens = 20,
        .output_tokens = 5,
        .cache_read_tokens = 4,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{},
    );
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        21,
        .retry_expected_tail,
        .{},
    );
    loaded.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(
        alloc,
        initial.id,
        .{},
    );
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), read_only.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), read_only.usage.?.reasoning_tokens);
    try std.testing.expectEqual(
        @as(?u64, 1),
        read_only.usage.?.models[0].request_count,
    );
    try std.testing.expectEqual(
        @as(?u64, 3),
        read_only.usage.?.models[0].reasoning_tokens,
    );

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), resumed.state.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), resumed.state.usage.?.reasoning_tokens);
}

test "failed canonical append leaves the previous usage sidecar unchanged" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-append-failure", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const before = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        session_usage_sidecar.sidecar_file,
        session_usage_sidecar.max_sidecar_bytes,
    );
    defer alloc.free(before);

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    usage.finishInvocation(sequence, 1, .unbilled);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_append };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            .{ .usage_checkpointed = .{ .usage = snapshot } },
            20,
            .rollback_before_adapter_continue,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    const after = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        session_usage_sidecar.sidecar_file,
        session_usage_sidecar.max_sidecar_bytes,
    );
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "usage sidecar publication stays inside the canonical commit boundary" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-commit-pair", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const Probe = struct {
        root: *Root,
        alloc: Allocator,
        session_id: []const u8,
        read_blocked: bool = false,
        read_succeeded: bool = false,

        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .before_usage_sidecar_write) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var state = self.root.loadReadOnly(
                self.alloc,
                self.session_id,
                .{ .commit_lock_deadline_ms = 0 },
            ) catch |err| {
                self.read_blocked =
                    err == error.SessionCommitBoundaryUnavailable;
                return;
            };
            state.deinit(self.alloc);
            self.read_succeeded = true;
        }
    };
    var probe = Probe{
        .root = &temp.root,
        .alloc = alloc,
        .session_id = initial.id,
    };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    usage.finishInvocation(sequence, 1, .unbilled);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{ .test_controls = .{
            .context = &probe,
            .boundary_fn = Probe.boundary,
        } },
    );
    try std.testing.expect(probe.read_blocked);
    try std.testing.expect(!probe.read_succeeded);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 2), read_only.usage.?.next_sequence);
    try std.testing.expectEqual(@as(usize, 0), read_only.usage.?.incidents.len);
}

test "indeterminate canonical usage retry repairs the rich sidecar" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-retry", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        7,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "vercel",
        "https://ai-gateway.vercel.sh",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.02,
        .input_tokens = 20,
        .output_tokens = 5,
        .cache_read_tokens = 4,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    var current = try loaded.state.dupe(alloc);
    defer current.deinit(alloc);
    if (current.usage) |*prior| prior.deinit(alloc);
    current.usage = try session_usage.dupeSnapshotOwned(alloc, snapshot);
    current.updated_at_ms = 20;

    var failure = BoundaryFailure{ .target = .after_target_namespace_sync };
    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.appendEvent(
            alloc,
            .{ .usage_checkpointed = .{ .usage = snapshot } },
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    try loaded.retryDegradedWithStateReplacement(alloc, current, .{});
    try std.testing.expectEqual(@as(?u64, 1), loaded.state.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), loaded.state.usage.?.reasoning_tokens);
    loaded.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), read_only.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), read_only.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(usize, 0), read_only.usage.?.incidents.len);
}

test "unwritable usage sidecar keeps canonical usage resumable and incomplete" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-failure", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});

    try loaded.log.dir.dir.deleteFile(
        io_mod.getIo(),
        session_usage_sidecar.sidecar_file,
    );
    try loaded.log.dir.dir.createDir(
        io_mod.getIo(),
        session_usage_sidecar.sidecar_file,
        std.Io.File.Permissions.fromMode(0o700),
    );

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        7,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "vercel",
        "https://ai-gateway.vercel.sh",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.02,
        .input_tokens = 20,
        .output_tokens = 5,
        .cache_read_tokens = 4,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{},
    );
    loaded.deinit(alloc);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.02),
        resumed.state.usage.?.total_cost,
        1e-12,
    );
    try std.testing.expect(resumed.state.usage.?.request_count == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        resumed.state.usage.?.incidents.len,
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        resumed.state.usage.?.incidents[0].occurred_at_ms,
    );
}

test "writable recovery rolls an invalid replacement back to its valid prior" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-invalid-replacement-recovery", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
    try corruptReplacementCommitTimestampForTest(alloc, &loaded, positions);
    loaded.deinit(alloc);
    loaded_owned = false;

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    try std.testing.expect(positionsEqual(positions.prior, resumed.position));
    try std.testing.expectEqual(@as(usize, 0), resumed.state.history.len);
    try std.testing.expectEqual(
        positions.prior.through_event_log_bytes,
        try resumed.log.eventLogLengthForTest(),
    );
    try std.testing.expect(!(try resumed.log.entryExistsForTest(publication_intent_file)));
    resumed.deinit(alloc);

    var repeated = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer repeated.deinit(alloc);
    try std.testing.expect(positionsEqual(positions.prior, repeated.position));
    try std.testing.expectEqual(@as(usize, 0), repeated.state.history.len);
}

test "publication recovery preserves bytes on reader and resource failures" {
    const RecoveryFailure = struct {
        target: Boundary,
        failure: anyerror,

        fn hit(raw: ?*anyopaque, point: Boundary) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (point == self.target) return self.failure;
        }

        fn testControls(self: *@This()) TestControls {
            return .{ .context = self, .boundary_fn = hit };
        }
    };
    const rows = [_]struct {
        id: []const u8,
        target: Boundary,
        failure: anyerror,
        current_at_prior: bool = false,
    }{
        .{
            .id = "session-proposed-read-failure",
            .target = .before_recovery_proposed_validation,
            .failure = error.ReadFailed,
        },
        .{
            .id = "session-prior-read-failure",
            .target = .before_recovery_prior_validation,
            .failure = error.ReadFailed,
        },
        .{
            .id = "session-proposed-resource-failure",
            .target = .before_recovery_proposed_validation,
            .failure = error.OutOfMemory,
        },
        .{
            .id = "session-current-prior-read-failure",
            .target = .before_recovery_prior_validation,
            .failure = error.ReadFailed,
            .current_at_prior = true,
        },
    };

    for (rows) |row| {
        const alloc = std.testing.allocator;
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, row.id, 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        var loaded_owned = true;
        defer if (loaded_owned) loaded.deinit(alloc);
        const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
        if (row.current_at_prior) {
            const watermark = try encodeWatermark(alloc, initial.id, positions.prior);
            defer alloc.free(watermark);
            const name = try watermarkName(alloc, positions.prior.log_generation);
            defer alloc.free(name);
            try durableReplace(alloc, &loaded.log.dir, name, watermark);
        } else {
            try corruptReplacementCommitTimestampForTest(alloc, &loaded, positions);
        }
        loaded.deinit(alloc);
        loaded_owned = false;
        var before = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer before.deinit(alloc);
        var failure = RecoveryFailure{ .target = row.target, .failure = row.failure };

        try std.testing.expectError(
            row.failure,
            temp.root.resumeForWrite(
                alloc,
                initial.id,
                .{ .test_controls = failure.testControls() },
            ),
        );
        var after = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer after.deinit(alloc);
        try before.expectEqual(after);
    }
}

test "publication recovery preserves unsupported and invalid prior transactions" {
    const Case = enum {
        unsupported_proposed,
        unsupported_replacement_chunk,
        invalid_prior,
    };
    const cases = [_]Case{
        .unsupported_proposed,
        .unsupported_replacement_chunk,
        .invalid_prior,
    };
    for (cases) |case| {
        const alloc = std.testing.allocator;
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        const session_id = switch (case) {
            .unsupported_proposed => "session-unsupported-proposed",
            .unsupported_replacement_chunk => "session-unsupported-replacement-chunk",
            .invalid_prior => "session-invalid-prior",
        };
        var initial = try testState(alloc, session_id, 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        var loaded_owned = true;
        defer if (loaded_owned) loaded.deinit(alloc);
        const initial_position = loaded.position;
        if (case == .invalid_prior) {
            _ = try loaded.appendEvent(
                alloc,
                .{ .preferences_changed = .{ .fast_mode = true } },
                15,
                .retry_expected_tail,
                .{},
            );
        }
        const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
        switch (case) {
            .unsupported_proposed => {
                var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
                defer log.close(io_mod.getIo());
                try replaceFrameByteForTest(
                    alloc,
                    log,
                    positions.prior.through_event_log_bytes,
                    positions.proposed.through_event_log_bytes,
                    "\"schema_version\":1",
                    '9',
                );
            },
            .unsupported_replacement_chunk => {
                try corruptReplacementChunkSchemaForTest(alloc, &loaded, positions);
            },
            .invalid_prior => {
                try corruptReplacementCommitTimestampForTest(alloc, &loaded, positions);
                var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
                defer log.close(io_mod.getIo());
                try replaceFrameByteForTest(
                    alloc,
                    log,
                    initial_position.through_event_log_bytes,
                    positions.prior.through_event_log_bytes,
                    "\"seq\":2",
                    '3',
                );
            },
        }
        loaded.deinit(alloc);
        loaded_owned = false;
        var before = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer before.deinit(alloc);

        const expected_error = switch (case) {
            .unsupported_proposed,
            .unsupported_replacement_chunk,
            => error.UnsupportedSessionSchema,
            .invalid_prior => error.InvalidSessionFormat,
        };
        try std.testing.expectError(
            expected_error,
            temp.root.resumeForWrite(alloc, initial.id, .{}),
        );
        var after = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer after.deinit(alloc);
        try before.expectEqual(after);
    }
}

test "publication recovery preserves a watermark outside the intent pair" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-mismatched-intent-watermark", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    const initial_position = loaded.position;
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        15,
        .retry_expected_tail,
        .{},
    );
    const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
    const watermark = try encodeWatermark(alloc, initial.id, initial_position);
    defer alloc.free(watermark);
    const name = try watermarkName(alloc, initial_position.log_generation);
    defer alloc.free(name);
    try durableReplace(alloc, &loaded.log.dir, name, watermark);
    loaded.deinit(alloc);
    loaded_owned = false;
    var before = try capturePublicationBytesForTest(
        alloc,
        &temp.root,
        initial.id,
        positions.proposed.log_generation,
    );
    defer before.deinit(alloc);

    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        temp.root.resumeForWrite(alloc, initial.id, .{}),
    );
    var after = try capturePublicationBytesForTest(
        alloc,
        &temp.root,
        initial.id,
        positions.proposed.log_generation,
    );
    defer after.deinit(alloc);
    try before.expectEqual(after);
}

test "display projection waits for first prompt and preserves derived title" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-display-title-freeze", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    var initial_display = try session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir);
    defer initial_display.deinit(alloc);
    try std.testing.expect(!initial_display.present);

    var first_state = try stateWithPrompt(
        alloc,
        loaded.state,
        20,
        "first prompt title should freeze after this",
        "first response",
    );
    defer first_state.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        first_state,
        .recovery,
        .retry_expected_tail,
        .{},
    );

    var first_display = try session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir);
    defer first_display.deinit(alloc);
    try std.testing.expect(first_display.present);
    try std.testing.expectEqualStrings(
        "first prompt title should freeze after this",
        first_display.title,
    );

    var replacement_state = try stateWithPrompt(
        alloc,
        loaded.state,
        30,
        "replacement prompt must not become the title",
        "replacement response",
    );
    defer replacement_state.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement_state,
        .recovery,
        .retry_expected_tail,
        .{},
    );

    var preserved_display = try session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir);
    defer preserved_display.deinit(alloc);
    try std.testing.expect(preserved_display.present);
    try std.testing.expectEqualStrings(
        "first prompt title should freeze after this",
        preserved_display.title,
    );
}

fn historyEvent(state: session_codec.DurableSessionState) session_event.Event {
    return .{ .history_turn_committed = .{
        .conversation_language = state.conversation_language,
        .total_input_tokens = state.total_input_tokens,
        .total_output_tokens = state.total_output_tokens,
        .turn = state.history[state.history.len - 1],
    } };
}

test "schema v3 exact operations accept dotted session IDs" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session.v3.branch", 10);
    defer initial.deinit(alloc);

    var started = try temp.root.startWritableSession(alloc, initial, .{});
    started.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqualStrings(initial.id, read_only.id);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(initial.id, resumed.state.id);
}

test "schema v3 exact operations accept 255 byte session IDs" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var session_id: [255]u8 = undefined;
    @memset(&session_id, 'a');
    var initial = try testState(alloc, &session_id, 10);
    defer initial.deinit(alloc);

    var started = try temp.root.startWritableSession(alloc, initial, .{});
    started.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &session_id, read_only.id);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &session_id, resumed.state.id);
}

test "schema v3 exact operations reject unsafe session IDs" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);

    const invalid_ids = [_][]const u8{
        ".",
        "..",
        "nested/session",
        "nested\\session",
    };
    for (invalid_ids) |session_id| {
        try std.testing.expectError(
            error.InvalidSessionId,
            temp.root.loadReadOnly(alloc, session_id, .{}),
        );
        try std.testing.expectError(
            error.InvalidSessionId,
            temp.root.resumeForWrite(alloc, session_id, .{}),
        );
    }

    const unsupported = [_]u8{ 0xff, 'a' };
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.loadReadOnly(alloc, &unsupported, .{}),
    );
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.resumeForWrite(alloc, &unsupported, .{}),
    );

    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.loadReadOnly(alloc, &too_long, .{}),
    );
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.resumeForWrite(alloc, &too_long, .{}),
    );
}

test "authority creation resolves marker absence as an uncommitted orphan" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var state = try testState(alloc, "session-authority-absent", 10);
    defer state.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_authority_intent_sync };

    try std.testing.expectError(
        error.SessionStartIndeterminate,
        temp.root.startWritableSession(alloc, state, .{ .test_controls = failure.test_controls() }),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        temp.root.resumeForWrite(alloc, state.id, .{}),
    );
    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.pending.json",
    )));
    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.json",
    )));
}

test "authority creation resolves an exact proposed marker and canonical pair" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var state = try testState(alloc, "session-authority-proposed", 10);
    defer state.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_authority_marker_rename };

    try std.testing.expectError(
        error.SessionStartIndeterminate,
        temp.root.startWritableSession(alloc, state, .{ .test_controls = failure.test_controls() }),
    );
    var loaded = try temp.root.resumeForWrite(alloc, state.id, .{});
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, loaded.state.id);
    try std.testing.expect(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.json",
    ));
    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.pending.json",
    )));
}

test "commit boundary hides synced bytes until watermark publication" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-commit-boundary", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);

    var observed_history_len: usize = std.math.maxInt(usize);
    const PauseReader = struct {
        root: *Root,
        alloc: Allocator,
        session_id: []const u8,
        observed: *usize,

        fn hit(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .after_event_sync) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var state = try self.root.loadReadOnly(self.alloc, self.session_id, .{});
            defer state.deinit(self.alloc);
            self.observed.* = state.history.len;
        }
    };
    var pause = PauseReader{
        .root = &temp.root,
        .alloc = alloc,
        .session_id = initial.id,
        .observed = &observed_history_len,
    };
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{ .test_controls = .{ .context = &pause, .boundary_fn = PauseReader.hit } },
    );

    try std.testing.expectEqual(@as(usize, 0), observed_history_len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
}

test "publication intent remains a read fence until writable resolution" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-publication-intent", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_commit_intent_sync };

    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    loaded.deinit(alloc);
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.loadReadOnly(alloc, initial.id, .{}),
    );
    var resolved = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), resolved.state.history.len);
}

test "publication indeterminacy blocks later append until explicit retry" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-publication-same-writer", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_target_namespace_sync };

    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    const ConfirmationTrace = struct {
        commit_locks: usize = 0,

        fn lock(raw: ?*anyopaque, kind: LockKind) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (kind == .commit) self.commit_locks += 1;
        }
    };
    var trace: ConfirmationTrace = .{};
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            30,
            .retry_expected_tail,
            .{ .test_controls = .{
                .context = &trace,
                .lock_fn = ConfirmationTrace.lock,
            } },
        ),
    );
    try loaded.retryDegradedWithStateReplacement(alloc, next, .{
        .test_controls = .{
            .context = &trace,
            .lock_fn = ConfirmationTrace.lock,
        },
    });
    try std.testing.expect(trace.commit_locks > 0);
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    try std.testing.expect(loaded.state.preferences.fast_mode);
}

test "intent cleanup pending confirms the namespace before a later append" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-intent-cleanup", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_commit_intent_remove };

    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{ .test_controls = failure.test_controls() },
    );

    const ConfirmationTrace = struct {
        commit_locks: usize = 0,
        confirmed_before_append: bool = false,

        fn lock(raw: ?*anyopaque, kind: LockKind) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (kind == .commit) self.commit_locks += 1;
        }

        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .after_event_append) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.confirmed_before_append = self.commit_locks > 0;
        }
    };
    var trace: ConfirmationTrace = .{};
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{ .test_controls = .{
            .context = &trace,
            .boundary_fn = ConfirmationTrace.boundary,
            .lock_fn = ConfirmationTrace.lock,
        } },
    );
    try std.testing.expect(trace.confirmed_before_append);
}

test "writable recovery truncates a complete provisional tail without resetting compaction accounting" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-provisional-tail", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        15,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const generation_base_seq = loaded.generation_base_seq;
    const generation_base_bytes = loaded.generation_base_bytes;
    const committed_bytes = loaded.position.through_event_log_bytes;
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    loaded.deinit(alloc);
    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), read_only.history.len);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(
        committed_bytes,
        try resumed.log.eventLogLengthForTest(),
    );
    try std.testing.expectEqual(generation_base_seq, resumed.generation_base_seq);
    try std.testing.expectEqual(generation_base_bytes, resumed.generation_base_bytes);

    var manifest = try loadManifest(alloc, &resumed.log.dir);
    defer manifest.deinit(alloc);
    try std.testing.expectEqual(generation_base_seq, manifest.generation_base_seq);
    try std.testing.expectEqual(generation_base_bytes, manifest.generation_base_bytes);
}

test "writable resume preserves the event log when the watermark is invalid" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-invalid-watermark-preserves-log", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    var invalid_position = loaded.position;
    invalid_position.through_event_log_bytes -= 1;
    const watermark = try encodeWatermark(alloc, initial.id, invalid_position);
    defer alloc.free(watermark);
    const watermark_name = try watermarkName(alloc, invalid_position.log_generation);
    defer alloc.free(watermark_name);
    try durableReplace(alloc, &loaded.log.dir, watermark_name, watermark);
    const before_events = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        events_file,
        16 * 1024 * 1024,
    );
    defer alloc.free(before_events);
    const before_watermark = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        watermark_name,
        watermark_max_bytes,
    );
    defer alloc.free(before_watermark);
    loaded.deinit(alloc);
    loaded_owned = false;

    try std.testing.expectError(
        error.InvalidSessionFormat,
        temp.root.resumeForWrite(alloc, initial.id, .{}),
    );
    var dir = try openSessionDir(&temp.root.sessions.?, initial.id, .read_only);
    defer dir.close();
    const after_events = try readManagedFileAlloc(
        alloc,
        &dir,
        events_file,
        16 * 1024 * 1024,
    );
    defer alloc.free(after_events);
    const after_watermark = try readManagedFileAlloc(
        alloc,
        &dir,
        watermark_name,
        watermark_max_bytes,
    );
    defer alloc.free(after_watermark);
    try std.testing.expectEqualSlices(u8, before_events, after_events);
    try std.testing.expectEqualSlices(u8, before_watermark, after_watermark);
}

test "retry eligible failure captures the exact expected event tail" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-failed-tail-capture", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    const prior = loaded.position;
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    const failed = loaded.degradedTail() orelse return error.TestExpectedEqual;
    try std.testing.expect(positionsEqual(prior, failed.prior));
    try std.testing.expectEqual(
        prior.through_event_log_bytes + failed.bytes.len,
        failed.proposed.through_event_log_bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        &session_projection.sha256(failed.bytes),
        &failed.sha256,
    );
    switch (failed.kind) {
        .event => |event_id| try std.testing.expectEqualSlices(
            u8,
            &failed.proposed.through_event_id,
            &event_id,
        ),
        .state_replacement => return error.TestExpectedEqual,
    }
}

test "degraded retry publishes only the exact expected event tail" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-expected-tail-retry", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    const expected = loaded.degradedTail().?.proposed;

    try loaded.retryDegradedWithStateReplacement(alloc, next, .{});

    try std.testing.expect(loaded.degradedTail() == null);
    try std.testing.expect(positionsEqual(expected, loaded.position));
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
}

test "degraded retry replaces current state when the expected tail is not exact" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-replacement-fallback", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    const failed = loaded.degradedTail().?;
    const prior = failed.prior;
    const failed_proposed = failed.proposed;
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    try log.writePositionalAll(
        io_mod.getIo(),
        "!",
        prior.through_event_log_bytes,
    );
    try log.sync(io_mod.getIo());
    log.close(io_mod.getIo());

    try loaded.retryDegradedWithStateReplacement(alloc, next, .{});

    try std.testing.expect(loaded.degradedTail() == null);
    try std.testing.expect(loaded.position.through_seq > failed_proposed.through_seq);
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
    try std.testing.expectEqualStrings(
        "world",
        replayed.history[0].assistant.assistant,
    );
}

test "rollback required failure is excluded from generic degraded retry" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-commit-first-exclusion", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    const prior = loaded.position;
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .rollback_before_adapter_continue,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    try std.testing.expect(loaded.degradedTail() == null);
    try std.testing.expect(positionsEqual(prior, loaded.position));
    try std.testing.expectEqual(
        prior.through_event_log_bytes,
        try loaded.log.eventLogLengthForTest(),
    );
}

test "checkpoint scheduling publishes an exact committed checkpoint" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(
        alloc,
        initial,
        .{ .checkpoint_interval = 1 },
    );
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);

    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{ .checkpoint_interval = 1 },
    );
    try std.testing.expect(try temp.root.entryExistsForTest(
        alloc,
        initial.id,
        "checkpoint.json",
    ));
    try loaded.validateCheckpointForTest(alloc);
}

test "checkpoint clean shutdown publishes when missing" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint-shutdown", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        initial.id,
        "checkpoint.json",
    )));
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try std.testing.expect(try temp.root.entryExistsForTest(
        alloc,
        initial.id,
        "checkpoint.json",
    ));
    try loaded.validateCheckpointForTest(alloc);
}

test "checkpoint clean shutdown preserves a valid bounded tail" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint-bounded-tail", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const checkpoint_seq = loaded.checkpoint_seq.?;
    const checkpoint_sha256 = loaded.checkpoint_sha256.?;
    const checkpoint_bytes = loaded.position.through_event_log_bytes;

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try std.testing.expectEqual(checkpoint_seq, loaded.checkpoint_seq.?);
    try std.testing.expectEqualSlices(
        u8,
        &checkpoint_sha256,
        &loaded.checkpoint_sha256.?,
    );

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var opened = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
    );
    defer opened.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.checkpoint, opened.source);
    try std.testing.expectEqual(
        loaded.position.through_event_log_bytes - checkpoint_bytes,
        opened.tail_bytes,
    );
    try std.testing.expect(opened.state.preferences.fast_mode);
}

test "final replacement policy tracks mutations after the last replacement" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-final-replacement-policy", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try std.testing.expect(!loaded.needsFinalStateReplacement(false));
    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    const generation_before_rebind = loaded.position.log_generation;
    _ = try loaded.appendEvent(
        alloc,
        .{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast("/tmp/session-final-replacement-policy-b"),
        } },
        20,
        .retry_expected_tail,
        .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &generation_before_rebind,
        &loaded.position.log_generation,
    ));
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    _ = try loaded.appendEvent(
        alloc,
        .{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast("/tmp/session-final-replacement-policy-c"),
        } },
        40,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    loaded.state_replacement_pending = true;
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = false } },
        45,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(loaded.needsFinalStateReplacement(false));

    var current = try loaded.state.dupe(alloc);
    defer current.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    var append_failure = BoundaryFailure{ .target = .after_event_append };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            .{ .workspace_rebound = .{
                .previous_workspace_root = loaded.state.workspace_root,
                .workspace_root = @constCast("/tmp/session-final-replacement-policy-failed"),
            } },
            50,
            .rollback_before_adapter_continue,
            .{ .test_controls = append_failure.test_controls() },
        ),
    );
    try std.testing.expect(loaded.needsFinalStateReplacement(false));

    _ = try loaded.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    var replacement_failure = BoundaryFailure{ .target = .after_event_append };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.commitStateReplacement(
            alloc,
            current,
            .compaction,
            .rollback_before_adapter_continue,
            .{ .test_controls = replacement_failure.test_controls() },
        ),
    );
    try std.testing.expect(loaded.needsFinalStateReplacement(false));
}

test "event append rejects a truncated committed prefix without extending it" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-truncated-commit-prefix", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const prior = loaded.position;
    const truncated_length = prior.through_event_log_bytes - 1;

    {
        var log = try openManagedFile(
            &loaded.log.dir,
            events_file,
            .read_write,
        );
        defer log.close(io_mod.getIo());
        try log.setLength(io_mod.getIo(), truncated_length);
        try log.sync(io_mod.getIo());
    }

    try std.testing.expectError(
        error.InvalidSessionFormat,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            20,
            .retry_expected_tail,
            .{},
        ),
    );
    try std.testing.expect(positionsEqual(prior, loaded.position));
    try std.testing.expect(!loaded.state.preferences.fast_mode);
    try std.testing.expect(loaded.needsFinalStateReplacement(false));
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    try std.testing.expectEqual(truncated_length, try log.length(io_mod.getIo()));
}

test "writable open state replays only the committed tail after a checkpoint" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint-tail-open", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const checkpoint_position = loaded.position;

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var exact = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
    );
    defer exact.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.checkpoint, exact.source);
    try std.testing.expectEqual(@as(u64, 0), exact.tail_bytes);

    const AllocationCheck = struct {
        fn run(
            failing_alloc: Allocator,
            dir: *io_mod.VerifiedDir,
            session_id: []const u8,
            authority_id: Identifier,
            event_log: std.Io.File,
            position: CommitPosition,
        ) !void {
            var opened = try loadOpenState(
                failing_alloc,
                dir,
                session_id,
                authority_id,
                event_log,
                position,
            );
            defer opened.state.deinit(failing_alloc);
            try std.testing.expectEqual(ReplaySource.checkpoint, opened.source);
        }
    };
    try std.testing.checkAllAllocationFailures(
        alloc,
        AllocationCheck.run,
        .{
            &loaded.log.dir,
            loaded.active_id,
            loaded.authority_id,
            log,
            loaded.position,
        },
    );

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    var tailed = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
    );
    defer tailed.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.checkpoint, tailed.source);
    try std.testing.expectEqual(
        loaded.position.through_event_log_bytes -
            checkpoint_position.through_event_log_bytes,
        tailed.tail_bytes,
    );
    try std.testing.expect(tailed.state.preferences.fast_mode);
    try std.testing.expectEqual(checkpoint_position.through_seq, tailed.checkpoint_seq.?);
}

test "writable open state falls back when the checkpoint is corrupt" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-corrupt-checkpoint-open", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try durableReplace(alloc, &loaded.log.dir, checkpoint_file, "{bad");

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var opened = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
    );
    defer opened.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.event_log, opened.source);
    try std.testing.expectEqual(ProjectionStatus.stale, opened.projection_status);
    try std.testing.expect(opened.checkpoint_seq == null);
    try std.testing.expectEqualStrings(initial.id, opened.state.id);
}

test "writable open state preserves compaction accounting after a stale event file fingerprint" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-stale-manifest-open", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const generation_base_seq = loaded.generation_base_seq;
    const generation_base_bytes = loaded.generation_base_bytes;

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    var first: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try log.readPositionalAll(io_mod.getIo(), &first, 0),
    );
    try log.writePositionalAll(io_mod.getIo(), &first, 0);
    try log.sync(io_mod.getIo());

    var opened = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
    );
    defer opened.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.event_log, opened.source);
    try std.testing.expectEqual(ProjectionStatus.stale, opened.projection_status);
    try std.testing.expectEqual(generation_base_seq, opened.generation_base_seq);
    try std.testing.expectEqual(generation_base_bytes, opened.generation_base_bytes);
    try std.testing.expect(opened.checkpoint_seq == null);
    try std.testing.expectEqualStrings(initial.id, opened.state.id);
}

test "manifest fingerprint captures the native event device" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-manifest-device", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var file = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const native_device = try eventDevice(file);

    const captured = try eventStat(file, loaded.position.through_event_log_bytes);
    try std.testing.expectEqual(native_device, captured.device);
}

test "log compaction replaces the generation without changing durable state" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-compaction", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const old_generation = loaded.position.log_generation;
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{},
    );

    try loaded.compactCanonicalLogIfDue(alloc, .{
        .compaction_frame_threshold = 1,
        .compaction_byte_threshold = 1,
    });
    try std.testing.expect(!std.mem.eql(
        u8,
        &old_generation,
        &loaded.position.log_generation,
    ));
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
    try std.testing.expectEqualStrings("world", replayed.history[0].assistant.assistant);
}

test "specialized history survives event replacement checkpoint and canonical compaction" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-specialized-history", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    var calls = [_]session.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("typed failure"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .assistant = @constCast("Inspecting."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const record_id = session.StableBackgroundRecordId{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    const background_template = session.HistoryTurn{ .background_command = .{
        .user = .{ .text = @constCast("run dev") },
        .assistant = @constCast("The server is starting."),
        .execution = .{ .tool_steps = steps[0..] },
        .log_path = @constCast("/tmp/server.log"),
        .expect_url = true,
        .background_record_id = record_id,
    } };
    const interrupted_template = session.HistoryTurn{ .interrupted = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("I inspected the entry point."),
        .execution = .{ .tool_steps = steps[0..] },
    } };

    var append_state = try loaded.state.dupe(alloc);
    defer append_state.deinit(alloc);
    const append_history = try alloc.alloc(session.HistoryTurn, 1);
    var owns_append_history = true;
    errdefer if (owns_append_history) alloc.free(append_history);
    append_history[0] = try session.dupeHistoryTurn(alloc, background_template);
    var append_history_initialized = true;
    errdefer if (owns_append_history and append_history_initialized) {
        session.freeHistoryTurn(alloc, append_history[0]);
    };
    session.freeHistoryTurnSlice(alloc, append_state.history);
    append_state.history = append_history;
    owns_append_history = false;
    append_history_initialized = false;
    append_state.updated_at_ms = 20;
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(append_state),
        20,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqualStrings(
        "The server is starting.",
        loaded.state.history[0].background_command.assistant.?,
    );

    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    const replacement_history = try alloc.alloc(session.HistoryTurn, 2);
    var owns_replacement_history = true;
    var copied_replacement_turns: usize = 0;
    errdefer if (owns_replacement_history) {
        for (replacement_history[0..copied_replacement_turns]) |turn| {
            session.freeHistoryTurn(alloc, turn);
        }
        alloc.free(replacement_history);
    };
    replacement_history[0] = try session.dupeHistoryTurn(alloc, background_template);
    copied_replacement_turns += 1;
    replacement_history[1] = try session.dupeHistoryTurn(alloc, interrupted_template);
    copied_replacement_turns += 1;
    session.freeHistoryTurnSlice(alloc, replacement.history);
    replacement.history = replacement_history;
    owns_replacement_history = false;
    replacement.updated_at_ms = 30;
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try loaded.compactCanonicalLogIfDue(alloc, .{
        .compaction_frame_threshold = 1,
        .compaction_byte_threshold = 1,
    });

    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), replayed.history.len);
    const background = replayed.history[0].background_command;
    try std.testing.expectEqualStrings("The server is starting.", background.assistant.?);
    try std.testing.expectEqual(@as(usize, 1), background.execution.tool_steps.len);
    try std.testing.expectEqual(.failure, background.execution.tool_steps[0].tool_results[0].status);
    try std.testing.expectEqualSlices(u8, &record_id, &background.background_record_id.?);
    const interrupted = replayed.history[1].interrupted;
    try std.testing.expectEqualStrings("I inspected the entry point.", interrupted.assistant.?);
    try std.testing.expectEqual(@as(usize, 1), interrupted.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "typed failure",
        interrupted.execution.tool_steps[0].tool_results[0].output,
    );
}

test "typed history above the context limit survives checkpoint and canonical compaction" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-typed-history-growth", 10);
    defer initial.deinit(alloc);

    {
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        defer loaded.deinit(alloc);

        var calls = [_]session.ToolCall{.{
            .id = "call_first",
            .name = "read_file",
            .arguments_json = "{\"path\":\"src/main.zig\"}",
        }};
        var results = [_]session.PersistedToolResult{.{
            .tool_call_id = @constCast("call_first"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("const main = true;"),
            .output_bytes = 18,
            .stored_output_bytes = 18,
        }};
        var steps = [_]session.ToolExecutionStep{.{
            .assistant = @constCast("Inspecting the entry point."),
            .tool_calls = calls[0..],
            .tool_results = results[0..],
        }};
        var files = [_]session.FileEvidence{.{
            .path = @constCast("src/main.zig"),
            .tool_call_id = @constCast("call_first"),
            .tool_name = @constCast("read_file"),
            .action = .read,
            .status = .success,
            .model_view_covers_full_file = true,
        }};
        const typed_turn = session.HistoryTurn{ .assistant = .{
            .user = .{ .text = @constCast("inspect the entry point") },
            .assistant = @constCast("The entry point is intact."),
            .execution = .{
                .tool_steps = steps[0..],
                .files = files[0..],
            },
        } };
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = loaded.state.conversation_language,
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = typed_turn,
            } },
            20,
            .retry_expected_tail,
            .{},
        );

        var index: usize = 1;
        while (index < 9) : (index += 1) {
            const turn = try session.makeAssistantTurn(alloc, "follow-up", "acknowledged");
            defer session.freeHistoryTurn(alloc, turn);
            _ = try loaded.appendEvent(
                alloc,
                .{ .history_turn_committed = .{
                    .conversation_language = loaded.state.conversation_language,
                    .total_input_tokens = index + 1,
                    .total_output_tokens = index + 1,
                    .turn = turn,
                } },
                @intCast(20 + index),
                .retry_expected_tail,
                .{},
            );
        }

        try std.testing.expectEqual(@as(usize, 9), loaded.state.history.len);
        const first = loaded.state.history[0].assistant;
        try std.testing.expectEqualStrings("call_first", first.execution.tool_steps[0].tool_calls[0].id);
        try std.testing.expectEqualStrings(
            "const main = true;",
            first.execution.tool_steps[0].tool_results[0].output,
        );
        try std.testing.expectEqualStrings("src/main.zig", first.execution.files[0].path);

        try loaded.writeCheckpointIfDue(alloc, true, .{});
        try loaded.compactCanonicalLogIfDue(alloc, .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        });
        try std.testing.expectEqual(@as(usize, 9), loaded.state.history.len);
    }

    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), replayed.history.len);
    const first = replayed.history[0].assistant;
    try std.testing.expectEqualStrings("call_first", first.execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqual(.success, first.execution.tool_steps[0].tool_results[0].status);
    try std.testing.expectEqualStrings(
        "const main = true;",
        first.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqualStrings("src/main.zig", first.execution.files[0].path);
    try std.testing.expect(first.execution.files[0].model_view_covers_full_file);
}

test "successful semantic commit automatically compacts when due" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-auto-compaction", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const old_generation = loaded.position.log_generation;
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);

    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );

    try std.testing.expect(!std.mem.eql(
        u8,
        &old_generation,
        &loaded.position.log_generation,
    ));
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
    try std.testing.expectEqualStrings("world", replayed.history[0].assistant.assistant);
}

test "automatic compaction honors an immediate commit lock deadline" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-compaction-lock-deadline", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const Contention = struct {
        dir: *io_mod.VerifiedDir,
        commit_attempts: usize = 0,
        commit_lock: ?io_mod.TimedAdvisoryLock = null,

        fn lock(raw: ?*anyopaque, kind: LockKind) void {
            if (kind != .commit) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.commit_attempts += 1;
            if (self.commit_attempts != 2) return;
            self.commit_lock = io_mod.acquireTimedAdvisoryLock(
                self.dir,
                commit_lock_file,
                2000,
            ) catch return;
        }
    };
    var contention = Contention{ .dir = &loaded.log.dir };
    defer if (contention.commit_lock) |*lock| lock.release();

    const started_at_ms = io_mod.milliTimestamp();
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{
            .test_controls = .{
                .context = &contention,
                .lock_fn = Contention.lock,
            },
            .commit_lock_deadline_ms = 0,
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );
    try std.testing.expectEqual(@as(usize, 2), contention.commit_attempts);
    try std.testing.expect(contention.commit_lock != null);
    try std.testing.expect(loaded.compaction_warning_active);
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "automatic compaction leaves post-rename uncertainty fenced" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-auto-compaction-fence", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_compaction_log_rename };
    loaded.resume_view_stale = false;

    try std.testing.expectError(
        error.SessionLogCompactionIndeterminate,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{
                .test_controls = failure.test_controls(),
                .compaction_frame_threshold = 1,
                .compaction_byte_threshold = 1,
            },
        ),
    );

    try std.testing.expect(loaded.namespace_confirmation_required);
    try std.testing.expect(loaded.resume_view_stale);
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.loadReadOnly(alloc, initial.id, .{}),
    );
    loaded.deinit(alloc);

    var resolved = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resolved.state.history.len);
    try std.testing.expectEqualStrings(
        "world",
        resolved.state.history[0].assistant.assistant,
    );
}

test "automatic compaction recovers every injected transaction boundary" {
    const boundaries = [_]Boundary{
        .after_compaction_temp_sync,
        .after_compaction_watermark_sync,
        .after_compaction_intent_sync,
        .after_compaction_log_rename,
        .after_compaction_namespace_sync,
        .after_compaction_live_confirmation,
        .after_compaction_intent_remove,
    };
    for (boundaries, 0..) |boundary, index| {
        const alloc = std.testing.allocator;
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        const session_id = try std.fmt.allocPrint(
            alloc,
            "session-log-compaction-boundary-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var initial = try testState(alloc, session_id, 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        var next = try stateWithTurn(alloc, loaded.state, 20);
        defer next.deinit(alloc);
        var failure = BoundaryFailure{ .target = boundary };

        const result = loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{
                .test_controls = failure.test_controls(),
                .compaction_frame_threshold = 1,
                .compaction_byte_threshold = 1,
            },
        );
        switch (boundary) {
            .after_compaction_temp_sync,
            .after_compaction_watermark_sync,
            .after_compaction_intent_remove,
            => _ = try result,
            .after_compaction_intent_sync,
            .after_compaction_log_rename,
            .after_compaction_namespace_sync,
            .after_compaction_live_confirmation,
            => try std.testing.expectError(
                error.SessionLogCompactionIndeterminate,
                result,
            ),
            else => unreachable,
        }
        loaded.deinit(alloc);

        var resumed = try temp.root.resumeForWrite(alloc, session_id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
        try std.testing.expectEqualStrings(
            "world",
            resumed.state.history[0].assistant.assistant,
        );
    }
}

test "log compaction rename remains fenced until writable resolution" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-compaction-fence", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{},
    );
    var failure = BoundaryFailure{ .target = .after_compaction_log_rename };
    loaded.resume_view_stale = false;

    try std.testing.expectError(
        error.SessionLogCompactionIndeterminate,
        loaded.compactCanonicalLogIfDue(alloc, .{
            .test_controls = failure.test_controls(),
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        }),
    );
    try std.testing.expect(loaded.resume_view_stale);
    loaded.deinit(alloc);
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.loadReadOnly(alloc, initial.id, .{}),
    );
    var resolved = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resolved.state.history.len);
    try std.testing.expectEqualStrings(
        "world",
        resolved.state.history[0].assistant.assistant,
    );
}

test "orphan cleanup removes only validated noncurrent generated files" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-orphan-cleanup", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const candidates = try loaded.createCleanupCandidatesForTest(alloc);
    defer {
        alloc.free(candidates.temp_name);
        alloc.free(candidates.watermark_name);
    }
    const report = try loaded.cleanupOrphans(alloc, .delete);
    try std.testing.expectEqual(@as(usize, 2), report.removed);
    try std.testing.expect(!(try loaded.log.entryExistsForTest(candidates.temp_name)));
    try std.testing.expect(!(try loaded.log.entryExistsForTest(candidates.watermark_name)));
    try std.testing.expect(try loaded.log.entryExistsForTest("authority.json"));
}

test "orphan cleanup preserves a generated temp with malformed trailing bytes" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-orphan-malformed", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const candidates = try loaded.createCleanupCandidatesForTest(alloc);
    defer {
        alloc.free(candidates.temp_name);
        alloc.free(candidates.watermark_name);
    }
    var malformed = try openManagedFile(
        &loaded.log.dir,
        candidates.temp_name,
        .read_write,
    );
    defer malformed.close(io_mod.getIo());
    const length = try malformed.length(io_mod.getIo());
    try malformed.writePositionalAll(io_mod.getIo(), "not-json\n", length);
    try malformed.sync(io_mod.getIo());

    const report = try loaded.cleanupOrphans(alloc, .delete);
    try std.testing.expectEqual(@as(usize, 1), report.removed);
    try std.testing.expectEqual(@as(usize, 2), report.ignored);
    try std.testing.expect(try loaded.log.entryExistsForTest(candidates.temp_name));
    try std.testing.expect(!(try loaded.log.entryExistsForTest(candidates.watermark_name)));
}

test "lock ordering is session before commit and read boundary uses commit only" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-lock-order", 10);
    defer initial.deinit(alloc);
    var create_trace: LockTrace = .{};
    var loaded = try temp.root.startWritableSession(
        alloc,
        initial,
        .{ .test_controls = create_trace.test_controls() },
    );
    loaded.deinit(alloc);
    try std.testing.expect(create_trace.len >= 2);
    try std.testing.expectEqual(LockKind.session, create_trace.items[0]);
    try std.testing.expectEqual(LockKind.commit, create_trace.items[1]);

    var read_trace: LockTrace = .{};
    var boundary = try temp.root.captureReadBoundary(
        alloc,
        initial.id,
        .{ .test_controls = read_trace.test_controls() },
    );
    boundary.deinit();
    try std.testing.expectEqual(@as(usize, 1), read_trace.len);
    try std.testing.expectEqual(LockKind.commit, read_trace.items[0]);
}

test "writable resume can fail immediately at a contended commit boundary" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-commit-lock-deadline", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    loaded.log.park();

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        commit_lock_file,
        2000,
    );
    defer contender.release();

    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.resumeForWrite(alloc, initial.id, .{
            .session_lock_deadline_ms = 0,
            .commit_lock_deadline_ms = 0,
        }),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "read boundary can fail immediately at a contended commit boundary" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "read-commit-lock-deadline", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    loaded.log.park();

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        commit_lock_file,
        2000,
    );
    defer contender.release();

    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.captureReadBoundary(alloc, initial.id, .{
            .commit_lock_deadline_ms = 0,
        }),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "namespace confirmation honors an immediate commit lock deadline" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "confirmation-commit-lock-deadline", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_commit_intent_remove };

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .rollback_before_adapter_continue,
        .{ .test_controls = failure.test_controls() },
    );
    try std.testing.expect(loaded.namespace_confirmation_required);

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        commit_lock_file,
        2000,
    );
    defer contender.release();

    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = false } },
            30,
            .rollback_before_adapter_continue,
            .{ .commit_lock_deadline_ms = 0 },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "park releases session.lock and unpark reacquires or fails busy" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-park-lock", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try std.testing.expect(!loaded.log.isParked());
    loaded.log.park();
    try std.testing.expect(loaded.log.isParked());

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        session_lock_file,
        2000,
    );
    try std.testing.expectError(error.SessionBusy, loaded.log.unpark());
    contender.release();

    try loaded.log.unpark();
    try std.testing.expect(!loaded.log.isParked());

    try std.testing.expectError(
        error.LockBusy,
        io_mod.acquireTimedAdvisoryLock(
            &loaded.log.dir,
            session_lock_file,
            50,
        ),
    );
}

test "watermark decoder rejects malformed object keys and required strings" {
    const unknown_key =
        "{\"schema_version\":1,\"session_id\":\"session\",\"log_generation\":\"00000000000000000000000000000000\",\"through_seq\":0,\"through_event_id\":\"00000000000000000000000000000000\",\"through_event_log_bytes\":0,\"unexpected\":true}";
    const non_string_session_id =
        "{\"schema_version\":1,\"session_id\":1,\"log_generation\":\"00000000000000000000000000000000\",\"through_seq\":0,\"through_event_id\":\"00000000000000000000000000000000\",\"through_event_log_bytes\":0}";

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        unknown_key,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidSessionFormat,
        session_codec.exactObject(parsed.value, &.{
            "schema_version",
            "session_id",
            "log_generation",
            "through_seq",
            "through_event_id",
            "through_event_log_bytes",
        }),
    );
    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseWatermark(std.testing.allocator, unknown_key),
    );
    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseWatermark(std.testing.allocator, non_string_session_id),
    );
}

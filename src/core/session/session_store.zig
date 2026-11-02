const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_child_store = @import("session_child_store.zig");
const session_json = @import("session_json.zig");
const session_layout = @import("session_layout.zig");
const session_log = @import("session_log.zig");
const session_replay = @import("session_replay.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const discovery = @import("session_discovery.zig");
const migration = @import("session_migration.zig");
const paths = @import("session_store_paths.zig");
const store_types = @import("session_store_types.zig");
const summary_codec = @import("session_summary_codec.zig");

const classifyAuthority = authority_module.classifyAuthority;
const openSessionFile = authority_module.openSessionFile;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
const DiscoveryMode = discovery.DiscoveryMode;
const ReadOnlyCandidate = discovery.ReadOnlyCandidate;
const classifyReadOnlyCandidate = discovery.classifyReadOnlyCandidate;
const storageFormatForLegacy = discovery.storageFormatForLegacy;
const summaryFromState = discovery.summaryFromState;
const retired_latest_sessions_dir = "latest";
const LegacyStoredSession = migration.LegacyStoredSession;
const legacyToDurableState = migration.legacyToDurableState;
const loadSchemaV3ReadOnly = migration.loadSchemaV3ReadOnly;
const normalizeWorkspaceRoot = paths.normalizeWorkspaceRoot;
const sessionJsonPath = paths.sessionJsonPath;
pub const validateSessionId = paths.validateSessionId;
pub const generateSessionId = paths.generateSessionId;

/// The process's temporary folder for captured prompt images, made on first
/// use. The turn keeps the bytes (D44), and a saved session saves them as
/// its blob (D89), which requests name instead of a copy here. The caller
/// frees the result; `temp_dir` keeps the folder's path.
pub fn imageSnapshotTempDir(alloc: Allocator, temp_dir: *?[]u8) ![]u8 {
    if (temp_dir.* == null) temp_dir.* = try image_attachments.createTempSnapshotDir(alloc);
    return alloc.dupe(u8, temp_dir.*.?);
}
pub const ReadOnlyDetail = store_types.ReadOnlyDetail;
pub const ResumeOptions = store_types.ResumeOptions;
pub const ResumeTarget = store_types.ResumeTarget;
pub const SessionRecoveryResult = store_types.SessionRecoveryResult;
pub const SessionSummary = store_types.SessionSummary;

fn latestCheckpointHistoryIndex(history: []const session.HistoryTurn) usize {
    var result: usize = 0;
    for (history, 0..) |turn, index| {
        if (turn == .compacted_summary) result = index;
    }
    return result;
}

pub const ResumableSessionContinuation = store_types.ResumableSessionContinuation;
pub const ResumableSessionPage = store_types.ResumableSessionPage;
pub const SessionListScope = store_types.SessionListScope;
pub const SessionListPage = store_types.SessionListPage;
pub const session_list_default_limit: usize = 100;
pub const session_list_max_limit: usize = 100;
const automatic_legacy_max_bytes = store_types.automatic_legacy_max_bytes;
const StoreContext = store_types.StoreContext;

/// Borrows its store's directory handles. The caller owns each returned candidate.
pub const CandidateIterator = struct {
    store: Store,
    entries: ?std.Io.Dir.Iterator,
    mode: DiscoveryMode = .read_only_list,
    skipped_invalid: usize = 0,

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

pub const default_resume_page_limit: usize = 10;

pub const Store = struct {
    sessions_dir: []u8,
    home_dir: []u8,
    workspace_root: []u8,
    canonical_root: session_log.Root,
    // How many sessions one resume page yields before flagging `has_more`.
    // Carried on the value so it propagates through the by-value page chain;
    // the UI sets it from the visible screen height.

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

    /// Read-only store with an injected home directory (tests / non-HOME callers).
    pub fn initReadOnlyFromHome(
        alloc: Allocator,
        home_dir: []const u8,
        workspace_root: []const u8,
    ) !Store {
        return initWithHome(alloc, home_dir, workspace_root, false);
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

    /// Returns an owned ID, or null when this workspace has no remembered selection.
    /// Reading never creates profile state or enumerates sessions.
    pub fn readRememberedSessionId(self: Store, alloc: Allocator) !?[]u8 {
        var directory = (try self.openRememberedDirectory(false)) orelse return null;
        defer directory.close();
        const name = self.rememberedSessionFilename();
        const path_stat = directory.dir.statFile(io_mod.getIo(), &name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (path_stat.kind != .file) return error.InvalidRememberedSession;
        var file = directory.dir.openFile(io_mod.getIo(), &name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        return try readRememberedSessionFile(alloc, &file);
    }

    fn readRememberedSessionFile(alloc: Allocator, file: *std.Io.File) ![]u8 {
        const stat = try file.stat(io_mod.getIo());
        // An atomic replacement can unlink the valid version already opened here.
        if (stat.kind != .file or stat.nlink > 1 or stat.permissions.toMode() & 0o777 != 0o600 or stat.size > 256) {
            return error.InvalidRememberedSession;
        }
        const bytes = try io_mod.readFileToEnd(alloc, file, 256);
        defer alloc.free(bytes);
        return try alloc.dupe(u8, try parseRememberedSessionId(bytes));
    }

    fn rememberedSessionFilename(self: Store) [64]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(normalizeWorkspaceRoot(self.workspace_root), &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }

    fn openRememberedDirectory(self: Store, create: bool) !?io_mod.VerifiedDir {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, profile_paths.rootParent(self.home_dir), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer home.close(zio);
        var profile = home.openDir(zio, profile_paths.rootName(), .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer profile.close(zio);
        if ((try profile.stat(zio)).permissions.toMode() & 0o777 != 0o700) return error.SessionPathUnsafe;
        if (create) return try io_mod.openOrCreateVerifiedPrivateDirFromDir(profile, "continue");
        var directory = profile.openDir(zio, "continue", .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer directory.close(zio);
        if ((try directory.stat(zio)).permissions.toMode() & 0o777 != 0o700) return error.SessionPathUnsafe;
        return .{ .dir = directory };
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

    /// Reads the child identity a legacy session records in its first event,
    /// for a session discovery classified as legacy. The event is read only
    /// within a small fixed bound, so listing never scans a log.
    pub fn loadListedLegacyChildIdentity(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        return self.canonical_root.loadListedLegacyChildIdentity(alloc, session_id);
    }

    /// Opens verified read-only storage restricted to subagent control files.
    /// The caller has already classified the session; no history is replayed.
    pub fn openListedSubagentControlReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !?session_child_store.SessionChildCapability {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display = try paths.sessionDirPath(alloc, self.sessions_dir, session_id);
        defer alloc.free(display);
        return session_child_store.SessionChildCapability.initLegacySubagentControl(alloc, session_dir.dir, display);
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
            var state = try root.loadReadOnly(alloc, session_id);
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
                if (state.recovery_checkpoint) |*checkpoint| checkpoint else null,
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
                    if (state.recovery_checkpoint) |*checkpoint| checkpoint else null,
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

    pub fn readOnlyCandidates(self: Store) CandidateIterator {
        return .{
            .store = self,
            .entries = if (self.canonical_root.sessions) |dir| dir.dir.iterate() else null,
        };
    }

    /// Listing's read of one session: a schema-v3 session whose projection is
    /// stale, missing, or unreadable is summarized from its committed log. The
    /// caller owns the candidate. No directory handle escapes this read.
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
        const classified = if (cancelled) |stop|
            discovery.classifyReadOnlyCandidateCancellable(alloc, &dir, session_id, stop)
        else
            classifyReadOnlyCandidate(alloc, &dir, session_id);
        var candidate = classified catch |err| switch (err) {
            // A missing or undecodable manifest; every other failure is
            // reported, not recovered.
            error.SessionNotFound, error.InvalidSessionFormat => (try discovery.recoverSchemaV3Candidate(alloc, &dir, session_id, cancelled)) orelse return err,
            else => return err,
        };
        errdefer candidate.deinit(alloc);
        try discovery.summarizeStaleProjection(alloc, &dir, &candidate, cancelled);
        return candidate;
    }

    /// Summarizes a legacy session behind an interrupted upgrade fence from
    /// its stable snapshot, for listing only. The caller owns the candidate.
    pub fn readOnlyFencedLegacyCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cancelled: ?*const std.atomic.Value(bool),
    ) !ReadOnlyCandidate {
        var dir = try self.openSessionDir(session_id);
        defer dir.close();
        return discovery.classifyFencedLegacyCandidate(alloc, &dir, session_id, cancelled);
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
        var state = try legacyToDurableState(self.ctx(), alloc, &legacy);
        errdefer state.deinit(alloc);
        // The oldest format saved some images without an id; number them as
        // v1's resume did (D69).
        _ = try session.repair_legacy_zero_image_ids(alloc, state.history);
        try resolveSessionSnapshotLocators(
            alloc,
            state.history,
            if (state.recovery_checkpoint) |*checkpoint| checkpoint else null,
            self.sessions_dir,
            session_id,
        );
        return .{
            .summary = try summaryFromState(alloc, state),
            .state = state,
            .storage_format = storageFormatForLegacy(schema),
        };
    }

    /// A damaged session's recoverable part (`recoverableState`).
    pub const Recoverable = struct {
        state: session_codec.DurableSessionState,
        /// The current format's last valid frame; null for schema 3.
        boundary: ?session_log.ConversationRecoveryBoundary,
        title: ?[]u8,
    };

    /// What `fx session recover` keeps of a damaged session, read from its
    /// folder `dir`, which the caller holds locked: its state up to the last
    /// frame v1 validates, or a schema-3 session's manifest boundary (D64).
    /// `error.SessionRecoveryNotNeeded` when nothing is damaged. Caller owns
    /// the result.
    pub fn recoverableState(
        self: Store,
        alloc: Allocator,
        dir: *io_mod.VerifiedDir,
        session_id: []const u8,
    ) !Recoverable {
        var metadata = session_log.readConversationMetadata(alloc, dir) catch |err| switch (err) {
            error.InvalidSessionMetadata, error.InvalidSessionFormat => return error.SessionRecoveryBoundaryInvalid,
            else => return err,
        };
        defer if (metadata) |*current| current.deinit();
        var current_boundary: ?session_log.ConversationRecoveryBoundary = null;
        var recovered = recovery_state: {
            if (metadata) |current| {
                if (!std.mem.eql(u8, current.value.id, session_id)) return error.SessionRecoveryBoundaryInvalid;
                if (current.value.subagent_child) return error.SessionNotFound;
                const recovery = session_log.classify_conversation_recovery(alloc, dir, session_id) catch |err| {
                    if (err == error.SessionRecoveryNotNeeded) {
                        var healthy = try self.loadReadOnly(alloc, session_id);
                        healthy.deinit(alloc);
                    }
                    return err;
                };
                current_boundary = recovery.boundary;
                break :recovery_state try session_log.load_conversation_recovery_state(alloc, dir, session_id, current_boundary.?);
            }
            const authority = try classifyAuthority(
                alloc,
                dir,
                session_id,
            );
            if (authority != .schema_v3) {
                return error.SessionRecoveryRequiresCurrentSchema;
            }
            var manifest_file = openSessionFile(
                dir,
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
            var events = openSessionFile(dir, "events.jsonl", .read_only) catch
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
        errdefer recovered.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            recovered.history,
            if (recovered.recovery_checkpoint) |*checkpoint| checkpoint else null,
            self.sessions_dir,
            session_id,
        );
        const source_dir_path = try paths.sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(source_dir_path);
        var source_children = try session_child_store.SessionChildCapability.init(
            alloc,
            dir.dir,
            source_dir_path,
            .read_only,
        );
        defer source_children.deinit();
        if (try subagent_child_state.capabilityHasManagedChildMarker(alloc, &source_children)) {
            return error.SessionNotFound;
        }
        const title = if (metadata) |current| if (current.value.title) |value| try alloc.dupe(u8, value) else null else null;
        return .{ .state = recovered, .boundary = current_boundary, .title = title };
    }
};

fn canonicalSnapshotLeaf(image: session.ImageAttachment, stored: []const u8) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(stored)) return error.InvalidSessionFormat;
    const prefix = "images/";
    if (!std.mem.startsWith(u8, stored, prefix)) return error.InvalidSessionFormat;
    const leaf = stored[prefix.len..];
    if (leaf.len == 0 or
        std.mem.findAny(u8, leaf, "/\\") != null or
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
    const expected = std.mem.print(
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
    checkpoint: ?*session_codec.RecoveryCheckpoint,
    sessions_dir: []const u8,
    session_id: []const u8,
) !void {
    const session_dir = try paths.sessionDirPath(alloc, sessions_dir, session_id);
    defer alloc.free(session_dir);
    const image_dir = try std.Io.Dir.path.join(alloc, &.{ session_dir, "images" });
    defer alloc.free(image_dir);

    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        try resolveImageSnapshotLocators(alloc, images, image_dir);
    }
    if (checkpoint) |value| try resolveImageSnapshotLocators(alloc, value.user.images, image_dir);
}

fn resolveImageSnapshotLocators(
    alloc: Allocator,
    images: []session.ImageAttachment,
    image_dir: []const u8,
) !void {
    for (images) |*image| {
        const stored = image.snapshot_path orelse continue;
        const leaf = try canonicalSnapshotLeaf(image.*, stored);
        const resolved = try std.Io.Dir.path.join(alloc, &.{ image_dir, leaf });
        alloc.free(stored);
        image.snapshot_path = resolved;
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
        null,
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
            null,
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
                null,
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
    const canonical_leaf = try std.mem.print(
        &canonical_leaf_buffer,
        "image-1-{s}.bin",
        .{digest[0..16]},
    );
    var locator_buffer: [80]u8 = undefined;
    const locator = try std.mem.print(
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
            null,
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
fn parseRememberedSessionId(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes.len > 256 or bytes[bytes.len - 1] != '\n') return error.InvalidRememberedSession;
    const id = bytes[0 .. bytes.len - 1];
    validateSessionId(id) catch return error.InvalidRememberedSession;
    return id;
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
    // The read-only store only sees a sessions folder that already exists.
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/sessions");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    errdefer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    errdefer alloc.free(workspace);
    var store = try Store.initReadOnlyFromHome(alloc, home, workspace);
    errdefer store.deinit(alloc);
    return .{ .home = home, .workspace = workspace, .store = store };
}

fn makeSessionDir(alloc: Allocator, store: Store, id: []const u8) !void {
    const dir = try paths.sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(dir);
    try config_runtime.makeAbsolutePath(dir);
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

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "reads of an empty or missing home find nothing and create nothing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const workspace = try std.Io.Dir.path.join(alloc, &.{ root, "workspace" });
    defer alloc.free(workspace);
    for ([_][]const u8{ "home", "missing-home" }) |name| {
        const home = try std.Io.Dir.path.join(alloc, &.{ root, name });
        defer alloc.free(home);
        var store = try Store.initReadOnlyFromHome(alloc, home, workspace);
        defer store.deinit(alloc);
        var candidates = store.readOnlyCandidates();
        try std.testing.expect((try candidates.nextId(alloc, null)) == null);
        try std.testing.expectError(error.SessionNotFound, store.loadReadOnly(alloc, "missing"));
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io_mod.getIo(), "home/.fx", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io_mod.getIo(), "missing-home", .{}));
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
    const session_dir = try paths.sessionDirPath(
        alloc,
        ctx.store.sessions_dir,
        "legacy-detail",
    );
    defer alloc.free(session_dir);
    const commit_lock = try std.Io.Dir.path.join(alloc, &.{ session_dir, "commit.lock" });
    defer alloc.free(commit_lock);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io_mod.getIo(), commit_lock, .{}),
    );
}

test "remembered session IDs are bounded and unambiguous" {
    try std.testing.expectEqualStrings("session-1", try parseRememberedSessionId("session-1\n"));
    for ([_][]const u8{ "", "\n", "../other\n", "session-1", "one\ntwo\n", "one\r\n", " one\n" }) |bytes| {
        try std.testing.expectError(error.InvalidRememberedSession, parseRememberedSessionId(bytes));
    }
    var bytes: [257]u8 = @splat('a');
    bytes[255] = '\n';
    try std.testing.expectEqual(@as(usize, 255), (try parseRememberedSessionId(bytes[0..256])).len);
    try std.testing.expectError(error.InvalidRememberedSession, parseRememberedSessionId(&bytes));
}

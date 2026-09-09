//! Native storage for the shared execution journal. Session admission owns the
//! existing session.lock; this module borrows it and never executes a turn.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const codec = @import("execution_journal_codec.zig");
const execution = @import("execution_journal.zig");
const journal = @import("journal.zig");
const session_log = @import("session_log.zig");
const session_codec = @import("session_codec.zig");
const session_json = @import("session_json.zig");
const session_store = @import("session_store.zig");
const store_types = @import("session_store_types.zig");
const migration = @import("session_migration.zig");
const authority = @import("session_authority.zig");
const child_store = @import("session_child_store.zig");
const child_state = @import("../subagent/child_state.zig");
const terminal_store = @import("../terminal/store.zig");
const result_store = @import("result_store.zig");
const command_replay_store = @import("command_replay_store.zig");
const image_attachments = @import("../images/image_attachments.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const metadata_name = "session.json";
const marker_name = "authority.json";
const journal_name = "execution.journal";
const stage_prefix = ".journal-stage-";
const header_bytes = 84;
const max_entry_bytes = codec.max_entry_bytes;
const max_source_bytes = 64 * 1024 * 1024;
const max_manifest_bytes = session_codec.max_session_metadata_bytes + 2048;
const max_source_files = 16_384;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

const SourceFile = struct {
    path: []const u8,
    bytes: u64,
    sha256: [64]u8,
};

const CapturedSnapshot = struct {
    source_path: []const u8,
    relative_path: []const u8,
    active_path: []const u8,
    bytes: []const u8,
    sha256: [64]u8,
    media_type: []const u8,
};

/// Owns its arena and all state/file identities. Call deinit; do not separately
/// free state fields. Artifact paths have been resolved through trusted roots.
pub const ValidatedSource = struct {
    arena: std.heap.ArenaAllocator,
    schema_version: u8,
    state: session_codec.DurableSessionState,
    model_history: []const types.HistoryTurn,
    metadata: session_codec.SessionMetadata,
    files: []const SourceFile,
    captured_snapshots: []const CapturedSnapshot = &.{},

    pub fn deinit(self: *ValidatedSource) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SourceOptions = struct {
    context: store_types.StoreContext,
    /// Legacy snapshots did not store these preferences. The native owner must
    /// resolve them explicitly; inspection does not consult global settings.
    legacy_preferences: ?session_codec.DurableSessionPreferences = null,
};

/// The shared execution owner supplies the real self-contained checkpoint.
/// Returned bytes belong to allocator; no storage-side fallback synthesizes old
/// turns or request IDs. This callback is never called during recovery.
pub const GenesisEncoder = struct {
    context: *anyopaque,
    encode_fn: *const fn (*anyopaque, Allocator, *const ValidatedSource) anyerror!codec.OwnedEntry,
};

/// Receives validated entries synchronously without starting execution. The
/// callback must copy anything it retains and discard partial state on error.
pub const Replay = struct {
    context: *anyopaque,
    entry_fn: *const fn (*anyopaque, codec.Entry) anyerror!void,
};

pub const Boundary = enum {
    staged,
    marker_published,
    events_archived,
    controls_archived,
    images_installed,
    journal_installed,
    manifest_published,
};

pub const Options = struct {
    durable_ops: io_mod.DurableOps = .{},
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (?*anyopaque, Boundary) anyerror!void = null,

    fn observe(self: Options, boundary: Boundary) !void {
        if (self.boundary_fn) |callback| try callback(self.context, boundary);
    }
};

const Marker = struct {
    schema_version: u8 = 2,
    storage_format: []const u8 = "execution_journal_v1",
    session_id: []const u8,
    source_schema: u8,
    archive: []const u8,
    source_index_sha256: []const u8,
    genesis_hash: []const u8,
};

const Manifest = struct {
    schema_version: u8 = 5,
    id: []const u8,
    journal: []const u8 = journal_name,
    archive: []const u8,
    genesis_hash: []const u8,
    metadata: session_codec.SessionMetadata,
};

fn require_lock(locked: *const session_log.WritableSessionDir) !void {
    if (locked.isParked()) return error.SessionWriterRequired;
}

fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn read_file(alloc: Allocator, dir: *io_mod.VerifiedDir, name: []const u8, limit: usize) ![]u8 {
    var file = try authority.openSessionFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    const size = try file.length(io_mod.getIo());
    if (size > limit) return error.JournalCapacityExceeded;
    return io_mod.readFileToEnd(alloc, &file, limit);
}

fn open_child(dir: *io_mod.VerifiedDir, path: []const u8) !io_mod.VerifiedDir {
    return .{ .dir = try dir.dir.openDir(io_mod.getIo(), path, .{ .iterate = true, .follow_symlinks = false }) };
}

fn is_stage(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, stage_prefix) or name.len != stage_prefix.len + 32) return false;
    for (name[stage_prefix.len..]) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

fn source_inventory(
    alloc: Allocator,
    root: *io_mod.VerifiedDir,
    prefix: []const u8,
    depth: usize,
    files: *std.ArrayList(SourceFile),
    total: *u64,
    entries: *usize,
) !void {
    if (depth > 16) return error.JournalCapacityExceeded;
    var iterator = root.dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (depth == 0 and (std.mem.eql(u8, entry.name, "session.lock") or is_stage(entry.name))) continue;
        if (entries.* >= max_source_files) return error.JournalCapacityExceeded;
        entries.* += 1;
        const path = if (prefix.len == 0) try alloc.dupe(u8, entry.name) else try std.fs.path.join(alloc, &.{ prefix, entry.name });
        if (entry.kind == .directory) {
            var child = try open_child(root, entry.name);
            defer child.close();
            try source_inventory(alloc, &child, path, depth + 1, files, total, entries);
        } else {
            if (entry.kind != .file or files.items.len >= max_source_files) return error.SessionPathUnsafe;
            const bytes = try read_file(alloc, root, entry.name, max_source_bytes);
            defer alloc.free(bytes);
            total.* = std.math.add(u64, total.*, bytes.len) catch return error.JournalCapacityExceeded;
            if (total.* > max_source_bytes) return error.JournalCapacityExceeded;
            try files.append(alloc, .{ .path = path, .bytes = bytes.len, .sha256 = digest(bytes) });
        }
    }
}

fn reject_control_conflicts(dir: *io_mod.VerifiedDir) !void {
    if (try authority.entryExistsRelative(dir, "recovery.json")) return error.PendingTurnError;
    for ([_][]const u8{ "authority.pending.json", "commit.pending.json", "events.v3.backup", "events.v4.tmp", journal_name }) |name| {
        if (try authority.entryExistsRelative(dir, name)) return error.JournalSourceConflict;
    }
}

fn reject_managed_work(alloc: Allocator, root: *io_mod.VerifiedDir, files: []const SourceFile, session_id: []const u8) !void {
    for (files) |file| {
        const child_registry = std.mem.eql(u8, file.path, "subagent/children.json");
        if (std.mem.startsWith(u8, file.path, "terminal/state/close-transaction-") and std.mem.endsWith(u8, file.path, ".json")) return error.PendingTurnError;
        const terminal_record = std.mem.startsWith(u8, file.path, "terminal/state/record-") and std.mem.endsWith(u8, file.path, ".json");
        if (!child_registry and !terminal_record) continue;
        const bytes = try read_relative(alloc, root, file.path, 1024 * 1024);
        defer alloc.free(bytes);
        if (child_registry) {
            var registry = try child_state.parseRegistry(alloc, bytes, session_id);
            defer registry.deinit(alloc);
            for (registry.children) |child| {
                if ((child.phase != .idle and child.phase != .finished) or child.active != null) return error.PendingTurnError;
            }
        } else {
            var record = try terminal_store.parse_record(alloc, bytes);
            defer record.deinit(alloc);
            if (!std.mem.eql(u8, record.owner_session_id, session_id)) return error.JournalSourceConflict;
            if (record.lifecycle != .closed and record.lifecycle != .exited) return error.PendingTurnError;
        }
    }
}

fn validate_artifacts(alloc: Allocator, locked: *session_log.WritableSessionDir, state: *session_codec.DurableSessionState, context: store_types.StoreContext, captured: []const CapturedSnapshot) !void {
    const path = try io_mod.dirRealpathAlloc(alloc, locked.dir.dir, ".");
    defer alloc.free(path);
    const expected = try std.fs.path.join(alloc, &.{ context.sessions_dir, locked.session_id });
    defer alloc.free(expected);
    if (!std.mem.eql(u8, path, expected)) return error.JournalSourceConflict;
    try session_store.resolveSessionSnapshotLocators(alloc, state.history, null, context.sessions_dir, locked.session_id);
    var captured_by_path: std.StringHashMapUnmanaged(*const CapturedSnapshot) = .empty;
    defer captured_by_path.deinit(alloc);
    for (captured) |*snapshot| try captured_by_path.put(alloc, snapshot.active_path, snapshot);
    var capability = try child_store.SessionChildCapability.init(alloc, locked.dir.dir, path, .read_only);
    defer capability.deinit();
    for (state.history) |turn| {
        const user = switch (turn) {
            .compacted_summary => continue,
            .assistant => |value| value.user,
            .interrupted => |value| blk: {
                if (value.tool_call != null) return error.PendingTurnError;
                break :blk value.user;
            },
        };
        for (user.images) |attachment| {
            if (captured_by_path.get(attachment.snapshot_path orelse return error.MissingImageSnapshot)) |snapshot| {
                if (!std.mem.eql(u8, &snapshot.sha256, attachment.snapshot_sha256 orelse return error.MissingImageSnapshot) or
                    !std.mem.eql(u8, snapshot.media_type, attachment.media_type)) return error.ImageSnapshotCorrupt;
            } else {
                var verified = try image_attachments.loadVerifiedSnapshot(alloc, attachment, .{});
                verified.deinit(alloc);
            }
        }
        const memory = switch (turn) {
            .assistant => |value| value.execution,
            .interrupted => |value| value.execution,
            .compacted_summary => unreachable,
        };
        for (memory.tool_steps) |step| {
            for (step.tool_calls) |call| {
                var complete = call.provider_result != null;
                for (step.tool_results) |result| if (std.mem.eql(u8, call.id, result.tool_call_id) and std.mem.eql(u8, call.name, result.tool_name)) {
                    complete = true;
                    break;
                };
                if (!complete) return error.PendingTurnError;
            }
            for (step.tool_results) |result| {
                const replay_alias = if (result.command_output_replay) |replay|
                    replay == .available and result.output_handle != null and
                        std.mem.eql(u8, result.output_handle.?, replay.available.handle)
                else
                    false;
                if (result.output_handle) |handle| {
                    // Older conversation records used the command replay itself
                    // as the result reference when no text sidecar existed.
                    if (!replay_alias) {
                        const bytes = try result_store.readForReplayManaged(alloc, &capability, handle, result.stored_output_bytes);
                        defer alloc.free(bytes);
                        var hash: [32]u8 = undefined;
                        Sha256.hash(bytes, &hash, .{});
                        if (@import("artifact_digest.zig").hasContentDigest(handle, ".txt") and
                            !result_store.handleMatchesContentDigest(handle, hash)) return error.JournalSourceConflict;
                    }
                }
                if (result.tool_image_handle) |handle| {
                    const images = try result_store.loadToolImages(alloc, &capability, handle);
                    types.freeToolImages(alloc, images);
                }
                if (result.command_output_replay) |replay| if (replay == .available) {
                    const descriptor = replay.available;
                    var file = try capability.openFileReadOnly(alloc, .command_artifacts, descriptor.handle);
                    defer file.deinit();
                    const bytes = try file.readToEnd(alloc, max_source_bytes);
                    defer alloc.free(bytes);
                    // Preserve exact presentation bytes. A malformed replay still
                    // uses the saved textual result through the existing UI fallback.
                    if (bytes.len != descriptor.framed_bytes) return error.JournalSourceConflict;
                    var hash: [32]u8 = undefined;
                    Sha256.hash(bytes, &hash, .{});
                    if (command_replay_store.hasContentDigest(descriptor.handle) and !command_replay_store.handleMatchesContentDigest(descriptor.handle, hash)) return error.JournalSourceConflict;
                };
            }
        }
    }
}

/// Reads only, under the caller's existing session lock. No legacy writer,
/// migration repair, model request, tool effect, or global settings read runs.
// Capture into temporary storage, then retain verified bytes in the source
// arena. No source file or active image directory changes during inspection.
fn captureLegacySnapshots(arena: Allocator, history: []types.HistoryTurn, session_dir: []const u8, source_bytes: *u64, source_files: usize) ![]const CapturedSnapshot {
    _ = try @import("session.zig").repair_legacy_zero_image_ids(arena, history);
    var directory: ?[]u8 = null;
    defer if (directory) |path| image_attachments.cleanupSnapshotDir(path);
    var captured: std.ArrayList(CapturedSnapshot) = .empty;
    var by_id: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*value| value.user.images,
            .interrupted => |*value| value.user.images,
        };
        for (images) |*image| {
            if (image.snapshot_path != null) continue;
            if (by_id.get(image.id)) |index| {
                const prior = captured.items[index];
                if (!std.mem.eql(u8, prior.source_path, image.path)) return error.DuplicateImageId;
                image.snapshot_path = try arena.dupe(u8, prior.relative_path);
                image.snapshot_sha256 = try arena.dupe(u8, &prior.sha256);
                arena.free(image.media_type);
                image.media_type = try arena.dupe(u8, prior.media_type);
                continue;
            }
            if (captured.items.len >= max_source_files - source_files) return error.JournalCapacityExceeded;
            if (directory == null) directory = try image_attachments.createTempSnapshotDir(arena);
            try image_attachments.captureImageSnapshot(arena, image, directory.?);
            const verified = try image_attachments.loadVerifiedSnapshot(arena, image.*, .{});
            source_bytes.* = std.math.add(u64, source_bytes.*, verified.bytes.len) catch return error.JournalCapacityExceeded;
            if (source_bytes.* > max_source_bytes) return error.JournalCapacityExceeded;
            const relative = try std.fmt.allocPrint(arena, "images/{s}", .{std.fs.path.basename(image.snapshot_path.?)});
            try captured.append(arena, .{
                .source_path = image.path,
                .relative_path = relative,
                .active_path = try std.fs.path.join(arena, &.{ session_dir, relative }),
                .bytes = verified.bytes,
                .sha256 = digest(verified.bytes),
                .media_type = verified.media_type,
            });
            try by_id.put(arena, image.id, captured.items.len - 1);
            arena.free(image.snapshot_path.?);
            image.snapshot_path = try arena.dupe(u8, relative);
        }
    }
    return captured.toOwnedSlice(arena);
}

pub fn inspectSource(alloc: Allocator, locked: *session_log.WritableSessionDir, options: SourceOptions) !ValidatedSource {
    try require_lock(locked);
    try reject_control_conflicts(&locked.dir);
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList(SourceFile) = .empty;
    var total: u64 = 0;
    var entries: usize = 0;
    try source_inventory(a, &locked.dir, "", 0, &files, &total, &entries);
    const manifest = try read_file(a, &locked.dir, metadata_name, max_source_bytes);
    const version = try authority.manifestSchemaVersion(a, manifest);
    if (try authority.readOptionalSessionFile(a, &locked.dir, "upgrade-handoff.json", 16 * 1024)) |handoff| {
        if (!std.mem.eql(u8, handoff, "{}\n")) return error.JournalSourceConflict;
    }
    if (version == 4) {
        if (try authority.entryExistsRelative(&locked.dir, marker_name)) return error.JournalSourceConflict;
    } else if (version >= 1 and version <= 3) {
        const selected = try authority.classifyAuthority(a, &locked.dir, locked.session_id);
        if ((version == 3) != (selected == .schema_v3)) return error.JournalSourceConflict;
    }
    var state = switch (version) {
        4 => try session_log.loadCompletedConversationForJournal(a, &locked.dir, locked.session_id),
        3 => blk: {
            var source = try migration.loadCompletedSchemaV3ForJournal(a, &locked.dir, locked.session_id);
            break :blk source.takeState();
        },
        1, 2 => blk: {
            const preferences = options.legacy_preferences orelse return error.LegacyPreferencesRequired;
            var legacy = try session_json.parseLegacyExact(migration.LegacyStoredSession, a, manifest);
            break :blk try migration.legacyToDurableState(options.context, a, &legacy, options.context.workspace_root, .preserved_workspace, preferences);
        },
        else => return error.UnsupportedSessionSchema,
    };
    if (!std.mem.eql(u8, state.id, locked.session_id) or state.recovery_checkpoint != null) return error.JournalSourceConflict;
    if (version < 4) {
        const discarded = try session_log.discardEmptyLegacyFileEvidence(a, state.history);
        if (discarded > 0) @import("../shared/debug_trace.zig").logf("session", "legacy file evidence omitted empty_paths={d} session={s}", .{ discarded, locked.session_id });
    }
    const captured = if (version < 4) try captureLegacySnapshots(a, state.history, try io_mod.dirRealpathAlloc(a, locked.dir.dir, "."), &total, files.items.len) else &.{};
    const permission_state = @import("../permissions/session_permission_state.zig");
    if (state.permission_state.version == 1) {
        const migrated = try permission_state.migrateV1ToV2(a, state.permission_state);
        state.permission_state.deinit(a);
        state.permission_state = migrated;
    }
    try session_codec.validateState(state);
    try reject_managed_work(a, &locked.dir, files.items, locked.session_id);
    try validate_artifacts(a, locked, &state, options.context, captured);
    const model_history = if (version == 4) model: {
        var current = (try session_log.loadConversationStateIfPresent(a, &locked.dir, locked.session_id)) orelse return error.InvalidSessionMetadata;
        try validate_artifacts(a, locked, &current, options.context, &.{});
        break :model current.history;
    } else try @import("execution_journal_genesis.zig").legacyContext(a, state.history, state.context_history_start);
    const metadata: session_codec.SessionMetadata = if (version == 4)
        try std.json.parseFromSliceLeaky(session_codec.SessionMetadata, a, manifest, .{ .allocate = .alloc_always })
    else metadata: {
        const display = @import("session_display_metadata.zig");
        const stored = try display.readSidecarOrFallback(a, &locked.dir);
        const selected = if (stored.present) stored else try display.deriveFromHistory(a, state.history);
        break :metadata .{
            .id = state.id,
            .origin_workspace_root = state.origin_workspace_root,
            .workspace_root = state.workspace_root,
            .created_at_ms = state.created_at_ms,
            .updated_at_ms = state.updated_at_ms,
            .conversation_language = try a.dupe(u8, state.conversation_language.view()),
            .provider = @tagName(state.preferences.provider),
            .model = state.preferences.model,
            .effort = try a.dupe(u8, state.preferences.effort.label()),
            .fast_mode = state.preferences.fast_mode,
            .title = if (selected.present) selected.title else null,
            .subagent_child = state.subagent_child,
        };
    };
    try session_codec.validateSessionMetadata(metadata);
    const source_files = try files.toOwnedSlice(a);
    return .{ .arena = arena, .schema_version = @intCast(version), .state = state, .model_history = model_history, .metadata = metadata, .files = source_files, .captured_snapshots = captured };
}

fn read_relative(alloc: Allocator, dir: *io_mod.VerifiedDir, path: []const u8, limit: usize) ![]u8 {
    try validate_source_path(path);
    if (std.fs.path.isAbsolute(path)) return error.SessionPathUnsafe;
    if (std.mem.indexOfScalar(u8, path, '/')) |separator| {
        const part = path[0..separator];
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.SessionPathUnsafe;
        var child = try open_child(dir, part);
        defer child.close();
        return read_relative(alloc, &child, path[separator + 1 ..], limit);
    }
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return error.SessionPathUnsafe;
    return read_file(alloc, dir, path, limit);
}

fn validate_source_path(path: []const u8) !void {
    if (path.len == 0 or path.len > std.Io.Dir.max_path_bytes or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return error.SessionPathUnsafe;
    var components = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (components.next()) |part| {
        count += 1;
        if (count > 17 or part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.SessionPathUnsafe;
    }
}

fn entry_kind(tag: u8) !codec.Kind {
    return switch (tag) {
        0 => .turn_start,
        1 => .model_step,
        2 => .tool_result,
        3 => .turn_end,
        4 => .checkpoint,
        else => error.InvalidJournalFrame,
    };
}

fn encode_frame(alloc: Allocator, entry: codec.Entry) ![]u8 {
    var checked = try codec.decode(alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
    defer checked.deinit(alloc);
    const bytes = try alloc.alloc(u8, header_bytes + entry.bytes.len);
    @memcpy(bytes[0..4], "FXEJ");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    bytes[6] = switch (entry.kind) {
        .turn_start => 0,
        .model_step => 1,
        .tool_result => 2,
        .turn_end => 3,
        .checkpoint => 4,
    };
    bytes[7] = 0;
    std.mem.writeInt(u64, bytes[8..16], entry.seq, .little);
    std.mem.writeInt(u32, bytes[16..20], @intCast(entry.bytes.len), .little);
    @memcpy(bytes[20..header_bytes], &entry.hash);
    @memcpy(bytes[header_bytes..], entry.bytes);
    return bytes;
}

/// Borrows locked until deinit; it must remain locked and must not be parked or
/// moved while this writer exists. Owns only its file, never the session lock.
pub const Store = struct {
    alloc: Allocator,
    locked: *session_log.WritableSessionDir,
    file: std.Io.File,
    append_journal: journal.Journal,
    last_hash: [64]u8,
    ops: io_mod.DurableOps,

    pub fn deinit(self: *Store) void {
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn sink(self: *Store) execution.Sink {
        return .{ .context = self, .append_fn = append_entry };
    }

    fn append_entry(raw: *anyopaque, entry: codec.Entry) !void {
        const self: *Store = @ptrCast(@alignCast(raw));
        try require_lock(self.locked);
        try self.append_journal.ensure_available();
        const alloc = self.alloc;
        const frame = try encode_frame(alloc, entry);
        defer alloc.free(frame);
        if (entry.seq == self.append_journal.cursor.seq and std.mem.eql(u8, &entry.hash, &self.last_hash)) {
            self.require_cursor() catch |err| {
                self.append_journal.blocked = true;
                return err;
            };
            return;
        }
        _ = self.append_journal.append(.{ .context = self, .append_fn = append_native }, entry.seq, entry.seq, frame) catch |err| {
            self.append_journal.blocked = true;
            return err;
        };
        self.last_hash = entry.hash;
    }

    fn require_cursor(self: *Store) !void {
        if (try self.file.length(io_mod.getIo()) != self.append_journal.cursor.committed_bytes) return error.JournalConflict;
        const current = try self.locked.dir.dir.statFile(io_mod.getIo(), journal_name, .{ .follow_symlinks = false });
        const held = try self.file.stat(io_mod.getIo());
        if (current.inode != held.inode or current.nlink != 1 or current.kind != .file) return error.JournalConflict;
    }

    fn append_native(raw: *anyopaque, request: journal.Append) journal.Outcome {
        const self: *Store = @ptrCast(@alignCast(raw));
        const zio = io_mod.getIo();
        const length = self.file.length(zio) catch |err| return .{ .not_written = err };
        if (length != request.expected.committed_bytes) return .conflict;
        const current = self.locked.dir.dir.statFile(zio, journal_name, .{ .follow_symlinks = false }) catch return .conflict;
        const held = self.file.stat(zio) catch return .conflict;
        if (current.inode != held.inode or current.nlink != 1 or current.kind != .file) return .conflict;
        self.file.writePositionalAll(zio, request.bytes, request.expected.committed_bytes) catch |err| return .{ .uncertain = err };
        self.ops.sync_file(self.ops.ctx, self.file) catch |err| return .{ .uncertain = err };
        return .{ .committed = request.next };
    }
};

/// Owns a stable session lock and its journal file. The caller owns the shared
/// execution State and must stop all users of sink() before closing this owner.
pub const Session = struct {
    alloc: Allocator,
    locked: session_log.WritableSessionDir,
    writer: Store,

    /// Validates or converts an exact session under its existing exclusive lock.
    /// Publishes the caller's fresh State only after replay and storage sync.
    /// Both this owner and state use alloc; neither source inspection nor replay
    /// starts a model, tool, native legacy repair, or a second execution writer.
    pub fn acquire(
        alloc: Allocator,
        root: *session_log.Root,
        session_id: []const u8,
        source_options: SourceOptions,
        state: *execution.State,
        lock_deadline_ms: u64,
        options: Options,
    ) !*Session {
        try state.ensureAvailable();
        if (state.last_seq != 0) return error.JournalConflict;
        const self = try alloc.create(Session);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.locked = try root.openWritableSessionDir(alloc, session_id, lock_deadline_ms);
        errdefer self.locked.deinit(alloc);
        const metadata = try read_file(alloc, &self.locked.dir, metadata_name, max_source_bytes);
        defer alloc.free(metadata);
        const version = try authority.manifestSchemaVersion(alloc, metadata);
        const marker = try authority.readOptionalSessionFile(alloc, &self.locked.dir, marker_name, 16 * 1024);
        defer if (marker) |bytes| alloc.free(bytes);
        const recovering = version == 5 or if (marker) |bytes| (try authority.manifestSchemaVersion(alloc, bytes)) == 2 else false;
        if (recovering) {
            try recoverCutover(alloc, &self.locked, options);
        } else {
            var source = try inspectSource(alloc, &self.locked, source_options);
            defer source.deinit();
            try cutover(alloc, &self.locked, &source, .{ .context = state, .encode_fn = encode_genesis }, options);
        }
        var candidate: execution.State = .{ .limits = state.limits };
        errdefer candidate.deinit(alloc);
        var replay = SessionReplay{ .alloc = alloc, .state = &candidate };
        self.writer = try open(alloc, &self.locked, .{ .context = &replay, .entry_fn = SessionReplay.append }, options.durable_ops);
        state.deinit(alloc);
        state.* = candidate;
        return self;
    }

    pub fn sink(self: *Session) execution.Sink {
        return self.writer.sink();
    }

    pub fn readMetadata(self: *Session) !session_codec.DecodedSessionMetadata {
        try self.writer.append_journal.ensure_available();
        var manifest = try read_manifest(self.alloc, &self.locked);
        defer manifest.deinit();
        const bytes = try session_codec.encodeSessionMetadata(self.alloc, manifest.value.metadata);
        defer self.alloc.free(bytes);
        return session_codec.decodeSessionMetadata(self.alloc, bytes);
    }

    /// Preferences and presentation metadata keep their native store ownership;
    /// updating them cannot replace execution records or the session identity.
    pub fn replaceMetadata(self: *Session, metadata: session_codec.SessionMetadata) !void {
        try self.writer.append_journal.ensure_available();
        try session_codec.validateSessionMetadata(metadata);
        var manifest = try read_manifest(self.alloc, &self.locked);
        defer manifest.deinit();
        const prior = manifest.value.metadata;
        if (!std.mem.eql(u8, metadata.id, prior.id) or
            !std.mem.eql(u8, metadata.origin_workspace_root, prior.origin_workspace_root) or
            metadata.created_at_ms != prior.created_at_ms or metadata.subagent_child != prior.subagent_child) return error.JournalConflict;
        manifest.value.metadata = metadata;
        manifest.value.metadata.updated_at_ms = @max(metadata.updated_at_ms, prior.updated_at_ms);
        const bytes = try std.json.Stringify.valueAlloc(self.alloc, manifest.value, .{});
        defer self.alloc.free(bytes);
        if (bytes.len > max_manifest_bytes) return error.JournalCapacityExceeded;
        self.writer.require_cursor() catch |err| {
            self.writer.append_journal.blocked = true;
            return err;
        };
        self.writer.append_journal.blocked = true;
        try io_mod.durableReplaceVerifiedWithOps(self.alloc, &self.locked.dir, metadata_name, bytes, self.writer.ops);
        self.writer.append_journal.blocked = false;
    }

    pub fn deinit(self: *Session) void {
        const alloc = self.alloc;
        self.writer.deinit();
        self.locked.deinit(alloc);
        alloc.destroy(self);
    }

    fn encode_genesis(raw: *anyopaque, alloc: Allocator, source: *const ValidatedSource) !codec.OwnedEntry {
        const state: *const execution.State = @ptrCast(@alignCast(raw));
        var entry = try @import("execution_journal_genesis.zig").encodeWithContext(alloc, source.state, source.model_history);
        errdefer entry.deinit(alloc);
        var checked: execution.State = .{ .limits = state.limits };
        defer checked.deinit(alloc);
        var replay = SessionReplay{ .alloc = alloc, .state = &checked };
        try SessionReplay.append(&replay, entry.entry);
        return entry;
    }
};

const SessionReplay = struct {
    alloc: Allocator,
    state: *execution.State,

    fn append(raw: *anyopaque, entry: codec.Entry) !void {
        const self: *SessionReplay = @ptrCast(@alignCast(raw));
        try self.state.restoreValidated(self.alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash, .{ .context = self, .validate_fn = validate });
    }

    fn validate(raw: *anyopaque, state: *const execution.State, body: std.json.Value) !void {
        const self: *SessionReplay = @ptrCast(@alignCast(raw));
        try @import("../agent/runtime/journal_runtime.zig").validateIncoming(self.alloc, state, body);
    }
};

fn source_file_less(_: void, a: SourceFile, b: SourceFile) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn verify_source(alloc: Allocator, locked: *session_log.WritableSessionDir, source: *const ValidatedSource) !void {
    if (!std.mem.eql(u8, source.state.id, locked.session_id)) return error.JournalSourceConflict;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var current: std.ArrayList(SourceFile) = .empty;
    var total: u64 = 0;
    var entries: usize = 0;
    try source_inventory(arena.allocator(), &locked.dir, "", 0, &current, &total, &entries);
    if (current.items.len != source.files.len) return error.JournalSourceConflict;
    std.mem.sort(SourceFile, current.items, {}, source_file_less);
    const original = try arena.allocator().dupe(SourceFile, source.files);
    std.mem.sort(SourceFile, original, {}, source_file_less);
    for (current.items, original) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or a.bytes != b.bytes or !std.mem.eql(u8, &a.sha256, &b.sha256)) return error.JournalSourceConflict;
    }
}

fn write_relative(alloc: Allocator, dir: *io_mod.VerifiedDir, path: []const u8, bytes: []const u8, ops: io_mod.DurableOps) !void {
    try validate_source_path(path);
    if (std.fs.path.isAbsolute(path)) return error.SessionPathUnsafe;
    if (std.mem.indexOfScalar(u8, path, '/')) |separator| {
        const part = path[0..separator];
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.SessionPathUnsafe;
        var child = try io_mod.openOrCreateVerifiedPrivateDir(dir, part);
        defer child.close();
        return write_relative(alloc, &child, path[separator + 1 ..], bytes, ops);
    }
    return io_mod.durableReplaceVerifiedWithOps(alloc, dir, path, bytes, ops);
}

fn checked_source_bytes(alloc: Allocator, root: *io_mod.VerifiedDir, file: SourceFile) ![]u8 {
    const bytes = try read_relative(alloc, root, file.path, max_source_bytes);
    errdefer alloc.free(bytes);
    if (bytes.len != file.bytes or !std.mem.eql(u8, &digest(bytes), &file.sha256)) return error.JournalSourceConflict;
    return bytes;
}

fn obsolete_control(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '/') != null) return false;
    if (std.mem.startsWith(u8, path, "commit.") and std.mem.endsWith(u8, path, ".json")) return true;
    for ([_][]const u8{ "events.jsonl", "session.legacy.json", "checkpoint.json", "recovery.json", "permissions.json", "usage-v2.json", "display.json", "resume-view.bin", "upgrade-handoff.json" }) |name| {
        if (std.mem.eql(u8, path, name)) return true;
    }
    return false;
}

fn archive_control(alloc: Allocator, locked: *session_log.WritableSessionDir, archive: *io_mod.VerifiedDir, file: SourceFile, ops: io_mod.DurableOps) !void {
    const original = checked_source_bytes(alloc, &locked.dir, file) catch |err| switch (err) {
        // A prior process may already have moved this control file. Its exact
        // archived copy was independently verified before reaching this loop.
        error.FileNotFound => return,
        else => return err,
    };
    defer alloc.free(original);
    try locked.dir.dir.rename(file.path, archive.dir, file.path, io_mod.getIo());
    try ops.sync_dir(ops.ctx, archive.dir);
    try ops.sync_dir(ops.ctx, locked.dir.dir);
}

fn valid_hash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

fn validate_marker(marker: Marker, session_id: []const u8) !void {
    if (marker.schema_version != 2 or !std.mem.eql(u8, marker.storage_format, "execution_journal_v1") or
        !std.mem.eql(u8, marker.session_id, session_id) or marker.source_schema < 1 or marker.source_schema > 4 or
        !is_stage(marker.archive) or !valid_hash(marker.source_index_sha256) or !valid_hash(marker.genesis_hash)) return error.JournalSourceConflict;
}

fn parse_marker(alloc: Allocator, dir: *io_mod.VerifiedDir, session_id: []const u8) !std.json.Parsed(Marker) {
    const bytes = try read_file(alloc, dir, marker_name, 16 * 1024);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(Marker, alloc, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate_marker(parsed.value, session_id);
    return parsed;
}

fn read_manifest(alloc: Allocator, locked: *session_log.WritableSessionDir) !std.json.Parsed(Manifest) {
    try require_lock(locked);
    var marker = try parse_marker(alloc, &locked.dir, locked.session_id);
    defer marker.deinit();
    const bytes = try read_file(alloc, &locked.dir, metadata_name, max_manifest_bytes);
    defer alloc.free(bytes);
    var manifest = try std.json.parseFromSlice(Manifest, alloc, bytes, .{ .allocate = .alloc_always });
    errdefer manifest.deinit();
    try validate_manifest(manifest.value, marker.value);
    return manifest;
}

fn validate_manifest(manifest: Manifest, marker: Marker) !void {
    try session_codec.validateSessionMetadata(manifest.metadata);
    if (manifest.schema_version != 5 or !std.mem.eql(u8, manifest.id, marker.session_id) or
        !std.mem.eql(u8, manifest.metadata.id, manifest.id) or
        !std.mem.eql(u8, manifest.journal, journal_name) or !std.mem.eql(u8, manifest.archive, marker.archive) or
        !std.mem.eql(u8, manifest.genesis_hash, marker.genesis_hash)) return error.JournalSourceConflict;
}

/// Stages only through the supplied genesis encoder, then commits the manifest
/// under the borrowed lock. Any error after staging requires recreation through
/// recoverCutover; callers must not continue with an old native writer.
pub fn cutover(
    alloc: Allocator,
    locked: *session_log.WritableSessionDir,
    source: *const ValidatedSource,
    encoder: GenesisEncoder,
    options: Options,
) !void {
    try require_lock(locked);
    try reject_control_conflicts(&locked.dir);
    try verify_source(alloc, locked, source);
    var genesis = try encoder.encode_fn(encoder.context, alloc, source);
    defer genesis.deinit(alloc);
    if (genesis.entry.seq != 1 or genesis.entry.kind != .checkpoint) return error.InvalidJournalGenesis;
    const genesis_frame = try encode_frame(alloc, genesis.entry);
    defer alloc.free(genesis_frame);
    var nonce: [16]u8 = undefined;
    try io_mod.getIo().randomSecure(&nonce);
    const stage_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stage_prefix, std.fmt.bytesToHex(nonce, .lower) });
    defer alloc.free(stage_name);
    // Unpublished staging directories are inert copies; no legacy reader uses
    // these names, and no source is removed before the marker is durable.
    try locked.dir.dir.createDir(io_mod.getIo(), stage_name, .fromMode(0o700));
    try options.durable_ops.sync_dir(options.durable_ops.ctx, locked.dir.dir);
    var stage = try open_child(&locked.dir, stage_name);
    defer stage.close();
    var archive = try io_mod.openOrCreateVerifiedPrivateDir(&stage, "source");
    defer archive.close();
    for (source.files) |file| {
        const bytes = try checked_source_bytes(alloc, &locked.dir, file);
        defer alloc.free(bytes);
        try write_relative(alloc, &archive, file.path, bytes, options.durable_ops);
    }
    for (source.captured_snapshots) |snapshot| try write_relative(alloc, &stage, snapshot.relative_path, snapshot.bytes, options.durable_ops);
    const index = try std.json.Stringify.valueAlloc(alloc, source.files, .{});
    defer alloc.free(index);
    if (index.len > max_entry_bytes) return error.JournalCapacityExceeded;
    const index_hash = digest(index);
    const marker = Marker{
        .session_id = locked.session_id,
        .source_schema = source.schema_version,
        .archive = stage_name,
        .source_index_sha256 = &index_hash,
        .genesis_hash = &genesis.entry.hash,
    };
    const manifest = try std.json.Stringify.valueAlloc(alloc, Manifest{ .id = locked.session_id, .archive = stage_name, .genesis_hash = &genesis.entry.hash, .metadata = source.metadata }, .{});
    defer alloc.free(manifest);
    if (manifest.len > max_manifest_bytes) return error.JournalCapacityExceeded;
    try io_mod.durableReplaceVerifiedWithOps(alloc, &stage, "source-index.json", index, options.durable_ops);
    try io_mod.durableReplaceVerifiedWithOps(alloc, &stage, "genesis", genesis_frame, options.durable_ops);
    try io_mod.durableReplaceVerifiedWithOps(alloc, &stage, metadata_name, manifest, options.durable_ops);
    try options.observe(.staged);
    try verify_source(alloc, locked, source);
    const marker_bytes = try std.json.Stringify.valueAlloc(alloc, marker, .{});
    defer alloc.free(marker_bytes);
    try io_mod.durableReplaceVerifiedWithOps(alloc, &locked.dir, marker_name, marker_bytes, options.durable_ops);
    try options.observe(.marker_published);
    try finish_cutover(alloc, locked, marker, &stage, &archive, source.files, options);
}

fn installGenesisSnapshots(alloc: Allocator, locked: *session_log.WritableSessionDir, stage: *io_mod.VerifiedDir, genesis_body: std.json.Value, ops: io_mod.DurableOps) !void {
    const base = genesis_body.object.get("nativeBase") orelse return error.InvalidJournalGenesis;
    var state = try @import("execution_journal_genesis.zig").decodeBase(alloc, base);
    defer state.deinit(alloc);
    const active_path = try io_mod.dirRealpathAlloc(alloc, locked.dir.dir, ".");
    defer alloc.free(active_path);
    if (!std.mem.eql(u8, std.fs.path.basename(active_path), locked.session_id)) return error.JournalSourceConflict;
    const parent = std.fs.path.dirname(active_path) orelse return error.JournalSourceConflict;
    try session_store.resolveSessionSnapshotLocators(alloc, state.history, null, parent, locked.session_id);
    const staged_path = try io_mod.dirRealpathAlloc(alloc, stage.dir, ".");
    defer alloc.free(staged_path);
    for (state.history) |turn| {
        const images = switch (turn) {
            .compacted_summary => continue,
            .assistant => |value| value.user.images,
            .interrupted => |value| value.user.images,
        };
        for (images) |image| {
            var existing = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    const leaf = std.fs.path.basename(image.snapshot_path orelse return error.MissingImageSnapshot);
                    const relative = try std.fmt.allocPrint(alloc, "images/{s}", .{leaf});
                    defer alloc.free(relative);
                    const staged_image_path = try std.fs.path.join(alloc, &.{ staged_path, relative });
                    defer alloc.free(staged_image_path);
                    var staged_image = image;
                    staged_image.snapshot_path = staged_image_path;
                    var verified = try image_attachments.loadVerifiedSnapshot(alloc, staged_image, .{});
                    defer verified.deinit(alloc);
                    try write_relative(alloc, &locked.dir, relative, verified.bytes, ops);
                    continue;
                },
                else => return err,
            };
            existing.deinit(alloc);
        }
    }
}

fn finish_cutover(alloc: Allocator, locked: *session_log.WritableSessionDir, marker: Marker, stage: *io_mod.VerifiedDir, archive: *io_mod.VerifiedDir, files: []const SourceFile, options: Options) !void {
    // Old v3 readers may have classified before waiting for session.lock. Their
    // under-lock replay begins with events.jsonl; remove that active pathname
    // before any other control sidecar so they cannot rewrite the new format.
    for (files) |file| if (std.mem.eql(u8, file.path, "events.jsonl")) {
        try archive_control(alloc, locked, archive, file, options.durable_ops);
    };
    try options.observe(.events_archived);
    for (files) |file| if (obsolete_control(file.path) and !std.mem.eql(u8, file.path, "events.jsonl")) {
        try archive_control(alloc, locked, archive, file, options.durable_ops);
    };
    try options.observe(.controls_archived);
    const genesis = try read_file(alloc, stage, "genesis", header_bytes + max_entry_bytes);
    defer alloc.free(genesis);
    var first = try decode_frame(alloc, genesis);
    defer first.deinit(alloc);
    if (first.entry.seq != 1 or first.entry.kind != .checkpoint or !std.mem.eql(u8, &first.entry.hash, marker.genesis_hash)) return error.InvalidJournalGenesis;
    try installGenesisSnapshots(alloc, locked, stage, first.payload.value, options.durable_ops);
    try options.observe(.images_installed);
    const existing = authority.readOptionalSessionFile(alloc, &locked.dir, journal_name, header_bytes + max_entry_bytes) catch return error.JournalSourceConflict;
    defer if (existing) |bytes| alloc.free(bytes);
    if (existing) |bytes| {
        if (!std.mem.eql(u8, bytes, genesis)) return error.JournalSourceConflict;
    } else try io_mod.durableReplaceVerifiedWithOps(alloc, &locked.dir, journal_name, genesis, options.durable_ops);
    try options.observe(.journal_installed);
    const manifest_bytes = try read_file(alloc, stage, metadata_name, max_manifest_bytes);
    defer alloc.free(manifest_bytes);
    const manifest = try std.json.parseFromSlice(Manifest, alloc, manifest_bytes, .{});
    defer manifest.deinit();
    try validate_manifest(manifest.value, marker);
    // This replacement alone selects journal execution. On post-rename failure,
    // preserve both representations and reopen; never assume rollback is safe.
    try io_mod.durableReplaceVerifiedWithOps(alloc, &locked.dir, metadata_name, manifest_bytes, options.durable_ops);
    try options.observe(.manifest_published);
}

/// Reconciles a interrupted cutover from its immutable stage under a newly held
/// session lock. It never calls the genesis encoder or starts execution. If old
/// authoritative bytes changed, it refuses rather than restoring a stale copy.
pub fn recoverCutover(alloc: Allocator, locked: *session_log.WritableSessionDir, options: Options) !void {
    try require_lock(locked);
    var marker = try parse_marker(alloc, &locked.dir, locked.session_id);
    defer marker.deinit();
    var stage = try open_child(&locked.dir, marker.value.archive);
    defer stage.close();
    var archive = try open_child(&stage, "source");
    defer archive.close();
    const index_bytes = try read_file(alloc, &stage, "source-index.json", max_entry_bytes);
    defer alloc.free(index_bytes);
    if (!std.mem.eql(u8, &digest(index_bytes), marker.value.source_index_sha256)) return error.JournalSourceConflict;
    const index = try std.json.parseFromSlice([]SourceFile, alloc, index_bytes, .{});
    defer index.deinit();
    if (index.value.len > max_source_files) return error.JournalSourceConflict;
    var total: u64 = 0;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(alloc);
    for (index.value) |file| {
        total = std.math.add(u64, total, file.bytes) catch return error.JournalSourceConflict;
        if (total > max_source_bytes or file.path.len == 0 or names.contains(file.path)) return error.JournalSourceConflict;
        try names.put(alloc, file.path, {});
        const archived = try checked_source_bytes(alloc, &archive, file);
        alloc.free(archived);
    }
    const metadata = try read_file(alloc, &locked.dir, metadata_name, max_source_bytes);
    defer alloc.free(metadata);
    const version = try authority.manifestSchemaVersion(alloc, metadata);
    if (version == 5) {
        const manifest = try std.json.parseFromSlice(Manifest, alloc, metadata, .{});
        defer manifest.deinit();
        try validate_manifest(manifest.value, marker.value);
        var current = try authority.openSessionFile(&locked.dir, journal_name, .read_only);
        defer current.close(io_mod.getIo());
        var header: [header_bytes]u8 = undefined;
        if (try current.readPositionalAll(io_mod.getIo(), &header, 0) != header_bytes) return error.InvalidJournalGenesis;
        const body_length: usize = std.mem.readInt(u32, header[16..20], .little);
        if (body_length > max_entry_bytes) return error.InvalidJournalGenesis;
        const buffer = try alloc.alloc(u8, header_bytes + body_length);
        defer alloc.free(buffer);
        if (try current.readPositionalAll(io_mod.getIo(), buffer, 0) != buffer.len) return error.InvalidJournalGenesis;
        var first = try decode_frame(alloc, buffer);
        defer first.deinit(alloc);
        if (first.entry.seq != 1 or first.entry.kind != .checkpoint or !std.mem.eql(u8, &first.entry.hash, marker.value.genesis_hash)) return error.InvalidJournalGenesis;
        // A previous manifest rename may have succeeded with an unconfirmed
        // directory sync. Establish that publication before returning authority.
        try options.durable_ops.sync_dir(options.durable_ops.ctx, locked.dir.dir);
        return;
    }
    if (version != marker.value.source_schema) return error.JournalSourceConflict;
    for (index.value) |file| {
        if (std.mem.eql(u8, file.path, marker_name)) continue;
        const current = checked_source_bytes(alloc, &locked.dir, file) catch |err| switch (err) {
            error.FileNotFound => if (obsolete_control(file.path)) continue else return error.JournalSourceConflict,
            else => return err,
        };
        alloc.free(current);
    }
    try finish_cutover(alloc, locked, marker.value, &stage, &archive, index.value, options);
}

fn decode_frame(alloc: Allocator, bytes: []const u8) !codec.OwnedEntry {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], "FXEJ") or
        std.mem.readInt(u16, bytes[4..6], .little) != 1 or bytes[7] != 0) return error.InvalidJournalFrame;
    const kind = try entry_kind(bytes[6]);
    const length: usize = std.mem.readInt(u32, bytes[16..20], .little);
    if (length > max_entry_bytes or bytes.len - header_bytes != length) return error.InvalidJournalFrame;
    return codec.decode(alloc, std.mem.readInt(u64, bytes[8..16], .little), @tagName(kind), bytes[header_bytes..], bytes[20..header_bytes]);
}

const ReadPosition = struct { seq: u64, bytes: u64, hash: [64]u8 };

pub const Snapshot = struct {
    state: execution.State,
    metadata: session_codec.DecodedSessionMetadata,
    incomplete_tail: bool,
    updated_at_ms: i64,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.metadata.deinit();
        self.* = undefined;
    }
};

/// Reads one bounded prefix without a writer lock, tail repair, or execution.
/// A non-journal manifest returns null so legacy readers keep their own policy.
pub fn inspect(alloc: Allocator, dir: *io_mod.VerifiedDir, session_id: []const u8) !?Snapshot {
    // Legacy recovery may own an incomplete manifest. Recognize our authority
    // marker before inspecting it, leaving older formats to their own reader.
    const marker_bytes = (try authority.readOptionalSessionFile(alloc, dir, marker_name, 16 * 1024)) orelse return null;
    defer alloc.free(marker_bytes);
    const marker_version = authority.manifestSchemaVersion(alloc, marker_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (marker_version != 2) return null;
    var metadata_file = authority.openSessionFile(dir, metadata_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer metadata_file.close(io_mod.getIo());
    if (try metadata_file.length(io_mod.getIo()) > max_manifest_bytes) return null;
    const bytes = try io_mod.readFileToEnd(alloc, &metadata_file, max_manifest_bytes);
    defer alloc.free(bytes);
    if (try authority.manifestSchemaVersion(alloc, bytes) != 5) return null;
    var manifest = try std.json.parseFromSlice(Manifest, alloc, bytes, .{});
    defer manifest.deinit();
    var marker = try parse_marker(alloc, dir, session_id);
    defer marker.deinit();
    try validate_manifest(manifest.value, marker.value);
    var file = try authority.openSessionFile(dir, journal_name, .read_only);
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    var state: execution.State = .{};
    errdefer state.deinit(alloc);
    var replay = SessionReplay{ .alloc = alloc, .state = &state };
    const position = try replay_file(alloc, file, length, marker.value.genesis_hash, .{ .context = &replay, .entry_fn = SessionReplay.append });
    const encoded_metadata = try session_codec.encodeSessionMetadata(alloc, manifest.value.metadata);
    defer alloc.free(encoded_metadata);
    return .{
        .state = state,
        .metadata = try session_codec.decodeSessionMetadata(alloc, encoded_metadata),
        .incomplete_tail = position.bytes != length,
        .updated_at_ms = @max(manifest.value.metadata.updated_at_ms, std.math.cast(i64, @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)) orelse manifest.value.metadata.updated_at_ms),
    };
}

fn replay_file(alloc: Allocator, file: std.Io.File, length: u64, genesis_hash: []const u8, replay: Replay) !ReadPosition {
    var offset: u64 = 0;
    var seq: u64 = 0;
    var last_hash: [64]u8 = @splat(0);
    while (offset < length) {
        var header: [header_bytes]u8 = undefined;
        const got = try file.readPositionalAll(io_mod.getIo(), &header, offset);
        if (!std.mem.eql(u8, header[0..@min(got, 4)], "FXEJ"[0..@min(got, 4)])) return error.InvalidJournalFrame;
        if (got >= 6 and std.mem.readInt(u16, header[4..6], .little) != 1) return error.InvalidJournalFrame;
        if (got >= 7) _ = try entry_kind(header[6]);
        if (got >= 8 and header[7] != 0) return error.InvalidJournalFrame;
        if (got >= 16 and std.mem.readInt(u64, header[8..16], .little) != seq + 1) return error.JournalConflict;
        if (got < header_bytes) break;
        if (!std.mem.eql(u8, header[0..4], "FXEJ") or std.mem.readInt(u16, header[4..6], .little) != 1 or header[7] != 0) return error.InvalidJournalFrame;
        _ = try entry_kind(header[6]);
        const body_length: u64 = std.mem.readInt(u32, header[16..20], .little);
        if (body_length > max_entry_bytes) return error.InvalidJournalFrame;
        const frame_length = header_bytes + body_length;
        if (frame_length > length - offset) break;
        const buffer = try alloc.alloc(u8, @intCast(frame_length));
        defer alloc.free(buffer);
        if (try file.readPositionalAll(io_mod.getIo(), buffer, offset) != buffer.len) return error.JournalSourceConflict;
        var entry = try decode_frame(alloc, buffer);
        defer entry.deinit(alloc);
        if (entry.entry.seq != seq + 1) return error.JournalConflict;
        if (seq == 0 and (entry.entry.kind != .checkpoint or !std.mem.eql(u8, &entry.entry.hash, genesis_hash))) return error.InvalidJournalGenesis;
        try replay.entry_fn(replay.context, entry.entry);
        seq = entry.entry.seq;
        last_hash = entry.entry.hash;
        offset += frame_length;
    }
    if (seq == 0) return error.InvalidJournalGenesis;
    return .{ .seq = seq, .bytes = offset, .hash = last_hash };
}

/// Opens only a committed native journal manifest. Validates/replays every full
/// record before repairing an incomplete final frame. Complete pending turns
/// remain intact. The caller discards Replay's partial state if this fails.
pub fn open(alloc: Allocator, locked: *session_log.WritableSessionDir, replay: Replay, ops: io_mod.DurableOps) !Store {
    try require_lock(locked);
    var marker = try parse_marker(alloc, &locked.dir, locked.session_id);
    defer marker.deinit();
    const metadata = try read_file(alloc, &locked.dir, metadata_name, max_manifest_bytes);
    defer alloc.free(metadata);
    const manifest = try std.json.parseFromSlice(Manifest, alloc, metadata, .{});
    defer manifest.deinit();
    try validate_manifest(manifest.value, marker.value);
    var file = try authority.openSessionFile(&locked.dir, journal_name, .writable);
    errdefer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    const position = try replay_file(alloc, file, length, marker.value.genesis_hash, replay);
    if (try file.length(io_mod.getIo()) != length) return error.JournalSourceConflict;
    const offset = position.bytes;
    if (offset != length) {
        @import("../shared/debug_trace.zig").logf("session", "execution journal incomplete tail dropped offset={d} bytes={d}", .{ offset, length - offset });
        try file.setLength(io_mod.getIo(), offset);
    }
    try ops.sync_file(ops.ctx, file);
    return .{ .alloc = alloc, .locked = locked, .file = file, .append_journal = try journal.Journal.init(.{ .seq = position.seq, .committed_bytes = offset }), .last_hash = position.hash, .ops = ops };
}

const TestSession = struct {
    alloc: Allocator,
    home: [:0]u8,
    root: session_log.Root,
    locked: session_log.WritableSessionDir,

    fn init(alloc: Allocator, tmp: *std.testing.TmpDir) !TestSession {
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
        errdefer alloc.free(home);
        var root = try session_log.Root.initFromHome(alloc, home, .writable);
        errdefer root.deinit(alloc);
        const history = [_]types.HistoryTurn{.{ .assistant = .{
            .user = .{ .text = @constCast("saved legacy question") },
            .assistant = @constCast("saved legacy answer"),
        } }};
        var loaded = try root.startConversationSession(alloc, .{
            .id = @constCast("native-journal-test"),
            .origin_workspace_root = home,
            .workspace_root = home,
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = .literal("en"),
            .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
            .history = @constCast(&history),
            .total_input_tokens = 3,
            .total_output_tokens = 2,
        }, .{});
        loaded.deinit(alloc);
        var dir = try open_child(&root.sessions.?, "native-journal-test");
        errdefer dir.close();
        var lock = try io_mod.acquireTimedAdvisoryLock(&dir, "session.lock", 0);
        errdefer lock.release();
        return .{ .alloc = alloc, .home = home, .root = root, .locked = .{
            .dir = dir,
            .writer_lock = lock,
            .session_id = try alloc.dupe(u8, "native-journal-test"),
        } };
    }

    fn deinit(self: *TestSession) void {
        self.locked.deinit(self.alloc);
        self.root.deinit(self.alloc);
        self.alloc.free(self.home);
    }

    fn options(self: *TestSession) SourceOptions {
        return .{ .context = .{
            .sessions_dir = self.root.display_root,
            .home_dir = self.home,
            .workspace_root = self.home,
            .canonical_root = self.root,
        } };
    }

    fn relock(self: *TestSession) !void {
        self.locked.park();
        const next = try self.root.openWritableSessionDir(self.alloc, self.locked.session_id, 0);
        self.locked.deinit(self.alloc);
        self.locked = next;
    }

    fn writeLegacy(self: *TestSession, version: u8) !void {
        if (version == 4) return;
        const alloc = self.alloc;
        if (version == 1 or version == 2) {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print("{{\"schema_version\":{d},\"id\":\"native-journal-test\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":", .{version});
            try std.json.Stringify.value(self.home, .{}, &out.writer);
            try out.writer.writeAll(",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[{\"kind\":\"assistant\",\"user\":{\"text\":\"saved legacy question\",\"images\":[]},\"assistant\":\"saved legacy answer\"}],\"total_input_tokens\":3,\"total_output_tokens\":2}");
            try io_mod.durableReplaceVerified(alloc, &self.locked.dir, metadata_name, out.written());
            return;
        }
        const event = @import("session_event.zig");
        const generation: event.Identifier = @splat(1);
        const started = try event.encodeLegacyFixtureFrame(alloc, .{
            .log_generation = generation,
            .seq = 1,
            .event_id = @splat(1),
            .timestamp_ms = 1,
            .event = .{ .session_started = .{
                .id = self.locked.session_id,
                .created_at_ms = 1,
                .origin_workspace_root = self.home,
                .workspace_root = self.home,
                .conversation_language = .literal("en"),
                .preferences = .{ .model = @constCast("test/model"), .effort = .literal("high"), .fast_mode = false },
            } },
        });
        defer alloc.free(started);
        const ended = try event.encodeLegacyFixtureFrame(alloc, .{
            .log_generation = generation,
            .seq = 2,
            .event_id = @splat(2),
            .timestamp_ms = 2,
            .event = .{ .history_turn_committed = .{
                .conversation_language = .literal("en"),
                .total_input_tokens = 3,
                .total_output_tokens = 2,
                .turn = .{ .assistant = .{ .user = .{ .text = @constCast("saved legacy question") }, .assistant = @constCast("saved legacy answer") } },
            } },
        });
        defer alloc.free(ended);
        const events = try std.mem.concat(alloc, u8, &.{ started, ended });
        defer alloc.free(events);
        try io_mod.durableReplaceVerified(alloc, &self.locked.dir, "events.jsonl", events);
        const watermark = try std.fmt.allocPrint(alloc, "{{\"schema_version\":1,\"session_id\":\"native-journal-test\",\"log_generation\":\"01010101010101010101010101010101\",\"through_seq\":2,\"through_event_id\":\"02020202020202020202020202020202\",\"through_event_log_bytes\":{d}}}", .{events.len});
        defer alloc.free(watermark);
        try io_mod.durableReplaceVerified(alloc, &self.locked.dir, "commit.01010101010101010101010101010101.json", watermark);
        try io_mod.durableReplaceVerified(alloc, &self.locked.dir, marker_name, "{\"schema_version\":1,\"storage_format\":\"event_log_v1\",\"session_id\":\"native-journal-test\",\"authority_id\":\"03030303030303030303030303030303\",\"source\":\"native_create\"}");
        const metadata = try @import("session_projection.zig").encodeManifest(alloc, .{
            .id = self.locked.session_id,
            .authority_id = @splat(3),
            .log_generation = generation,
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .origin_workspace_root = self.home,
            .workspace_root = self.home,
            .conversation_language = .literal("en"),
            .history_len = 1,
            .total_input_tokens = 3,
            .total_output_tokens = 2,
            .last_event_seq = 2,
            .event_log_bytes = events.len,
            .event_log_stat_fingerprint = @splat(0),
            .generation_base_seq = 1,
            .generation_base_bytes = started.len,
            .checkpoint_seq = null,
            .checkpoint_sha256 = null,
            .preferences = .{ .model = @constCast("test/model"), .effort = .literal("high"), .fast_mode = false },
        });
        defer alloc.free(metadata);
        try io_mod.durableReplaceVerified(alloc, &self.locked.dir, metadata_name, metadata);
    }
};

const TestGenesis = struct {
    calls: usize = 0,

    fn encoder(self: *TestGenesis) GenesisEncoder {
        return .{ .context = self, .encode_fn = encode };
    }

    fn encode(raw: *anyopaque, alloc: Allocator, source: *const ValidatedSource) !codec.OwnedEntry {
        const self: *TestGenesis = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return @import("execution_journal_genesis.zig").encodeWithContext(alloc, source.state, source.model_history);
    }
};

test "journal witness native owner validates before cutover and reopens the exact pending boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    fixture.locked.park();
    var state: execution.State = .{ .limits = .{ .bytes = 128 } };
    defer state.deinit(alloc);
    try std.testing.expectError(error.JournalCapacityExceeded, Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{}));
    try std.testing.expectEqual(@as(u64, 0), state.last_seq);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
    try std.testing.expect(try authority.entryExistsRelative(&fixture.locked.dir, "events.jsonl"));
    state.limits = .{};
    var owner: ?*Session = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{});
    defer if (owner) |value| value.deinit();
    const runtime = @import("../agent/runtime/journal_runtime.zig");
    var turn = runtime.Runtime{
        .alloc = alloc,
        .state = &state,
        .sink = owner.?.sink(),
        .namespace = "discarded-new-owner-name",
        .creation_id = "first-owner",
        .request_id = "native-request",
    };
    _ = try turn.begin(.{ .text = @constCast("pending input") }, "test/model", 42, false);
    var generation = try turn.generation();
    defer generation.deinit(alloc);
    _ = try turn.recordDecision(.{ .content = "selected effect" }, &.{.{
        .id = "original-provider-call",
        .name = "write_file",
        .arguments_json = "{\"path\":\"result.txt\"}",
    }}, &.{.blocked}, generation, false, null, null);
    const turn_id = try alloc.dupe(u8, try execution.string(state.start(0), "turnId"));
    defer alloc.free(turn_id);
    owner.?.deinit();
    owner = null;
    state.deinit(alloc);
    state = .{};
    owner = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{});
    try std.testing.expectEqual(@as(u64, 3), state.last_seq);
    try std.testing.expect(state.pending() == .tool);
    try std.testing.expectEqualStrings(turn_id, try execution.string(state.start(0), "turnId"));
    const restored_history = try runtime.restoreHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, restored_history);
    try std.testing.expectEqualStrings("saved legacy answer", restored_history[0].assistant.assistant);
    turn.state = &state;
    turn.sink = owner.?.sink();
    const context = try turn.context(0, 0, true);
    try std.testing.expectEqualStrings("native-journal-test:turn:1:message:1:call:1", context.callId);
    const abandoned = (try turn.abandon()).?;
    defer types.freeHistoryTurn(alloc, abandoned);
    try std.testing.expectEqualStrings("original-provider-call", abandoned.interrupted.tool_call.?.id);
    var checkpoint = try state.checkpoint(alloc, owner.?.sink());
    defer checkpoint.deinit(alloc);
    owner.?.deinit();
    owner = null;
    state.deinit(alloc);
    state = .{};
    owner = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{});
    try std.testing.expect(state.pending() == .idle);
    try std.testing.expectEqual(@as(u64, 5), state.last_seq);
    try std.testing.expect(state.request("native-request") != null);
    const terminal_history = try runtime.restoreHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, terminal_history);
    try std.testing.expectEqual(@as(usize, 2), terminal_history.len);
    try std.testing.expectEqualStrings("saved legacy answer", terminal_history[0].assistant.assistant);
    try std.testing.expectEqualStrings("original-provider-call", terminal_history[1].interrupted.tool_call.?.id);
}

const TestReplay = struct {
    alloc: Allocator,
    entries: std.ArrayList(codec.OwnedEntry) = .empty,

    fn replay(self: *TestReplay) Replay {
        return .{ .context = self, .entry_fn = add };
    }

    fn add(raw: *anyopaque, entry: codec.Entry) !void {
        const self: *TestReplay = @ptrCast(@alignCast(raw));
        var copied = try codec.decode(self.alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
        errdefer copied.deinit(self.alloc);
        try self.entries.append(self.alloc, copied);
    }

    fn deinit(self: *TestReplay) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
    }
};

test "journal witness native loaded session uses journal authority for history and retains preferences" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    fixture.locked.park();
    var facade = try session_store.Store.initFromHome(alloc, fixture.home, fixture.home);
    defer facade.deinit(alloc);
    var loaded = try facade.resumeJournalForWrite(alloc, fixture.locked.session_id, .{});
    var owned = true;
    defer if (owned) loaded.deinit(alloc);
    try std.testing.expect(!loaded.hasPendingTurn());
    try std.testing.expectEqualStrings("saved legacy answer", loaded.state.history[0].assistant.assistant);
    _ = try loaded.childCapability();
    _ = try loaded.renameConversation(alloc, "Journal session title");
    _ = try loaded.appendEvent(alloc, .{ .preferences_changed = .{ .model = @constCast("test/new-model") } }, 3);
    const runtime = @import("../agent/runtime/journal_runtime.zig");
    var turn = runtime.Runtime{
        .alloc = alloc,
        .state = loaded.journalState().?,
        .sink = loaded.journalSink().?,
        .namespace = "unused-new-owner",
        .creation_id = "native-loaded-owner",
        .request_id = "facade-request",
    };
    const user: types.UserTurn = .{ .text = @constCast("new native turn") };
    _ = try turn.begin(user, loaded.state.preferences.model, 42, false);
    var generation = try turn.generation();
    defer generation.deinit(alloc);
    _ = try turn.recordDecision(.{ .content = "new native answer" }, &.{}, &.{}, generation, true, null, null);
    const history: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("new native answer") } };
    const event: session_log.SessionUpdate = .{ .history_turn_committed = .{
        .turn = history,
        .conversation_language = .literal("en"),
        .total_input_tokens = 3,
        .total_output_tokens = 2,
    } };
    try std.testing.expectError(error.JournalControlRequired, loaded.appendEvent(alloc, event, 4));
    {
        var detail = try facade.loadReadOnlyDetail(alloc, fixture.locked.session_id, .{});
        defer detail.deinit(alloc);
        try std.testing.expectEqual(session_store.StorageFormat.execution_journal, detail.storage_format);
        try std.testing.expect(detail.summary.has_checkpoint);
        const pending = detail.journal.?.pending.?;
        try std.testing.expectEqualStrings("new native turn", pending.interrupted.user.text);
        const output = try (@import("../output/output_contracts.zig").SessionDetailSnapshot{ .detail = detail }).renderJson(alloc);
        defer alloc.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "new native answer") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"pending_turn\":") != null);
        try std.testing.expectError(error.JournalReaderRequired, facade.loadReadOnly(alloc, fixture.locked.session_id));
        var listed = try facade.list(alloc);
        defer {
            for (listed.items) |*item| item.deinit(alloc);
            listed.deinit(alloc);
        }
        try std.testing.expectEqual(@as(usize, 1), listed.items.len);
        try std.testing.expectEqualStrings(fixture.locked.session_id, listed.items[0].id);
        try std.testing.expect(listed.items[0].has_checkpoint);
        try std.testing.expectEqual(@as(u64, 3), loaded.journalState().?.last_seq);
        try std.testing.expectError(error.SessionBusy, facade.resumeTargetForWrite(alloc, .last, fixture.home, .{ .execution_journal = true, .log = .{ .session_lock_deadline_ms = 0 } }));
        var page = try facade.loadHistoryPage(alloc, fixture.locked.session_id, null, 1);
        defer page.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), page.history_len);
        try std.testing.expectEqualStrings("saved legacy answer", page.turns[0].assistant.assistant);
    }
    const result = try std.json.parseFromSlice(std.json.Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\"}", .{});
    defer result.deinit();
    try turn.finish(result.value, history);
    _ = try loaded.appendEvent(alloc, event, 4);
    try std.testing.expectEqual(@as(u64, 4), loaded.position.through_seq);
    try std.testing.expect(!try authority.entryExistsRelative(&loaded.log.dir, "events.jsonl"));
    try std.testing.expect(!try authority.entryExistsRelative(&loaded.log.dir, "recovery.json"));
    loaded.deinit(alloc);
    owned = false;
    var reopened = try facade.resumeTargetForWrite(alloc, .last, fixture.home, .{ .execution_journal = true });
    defer reopened.deinit(alloc);
    try std.testing.expectEqualStrings("test/new-model", reopened.state.preferences.model);
    const title = (try reopened.conversationTitle(alloc)).?;
    defer alloc.free(title);
    try std.testing.expectEqualStrings("Journal session title", title);
    try std.testing.expectEqual(@as(usize, 2), reopened.state.history.len);
    try std.testing.expectEqualStrings("new native answer", reopened.state.history[1].assistant.assistant);
    try std.testing.expect(!reopened.hasPendingTurn());
    try std.testing.expect(reopened.journalState().?.request("facade-request") != null);
    var detail = try facade.loadReadOnlyDetail(alloc, fixture.locked.session_id, .{});
    defer detail.deinit(alloc);
    try std.testing.expect(detail.journal.?.pending == null);
    try std.testing.expectEqual(@as(usize, 2), detail.state.history.len);
    var latest = try facade.loadHistoryPage(alloc, fixture.locked.session_id, null, 1);
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings("new native answer", latest.turns[0].assistant.assistant);
    var earlier = try facade.loadHistoryPage(alloc, fixture.locked.session_id, latest.next_cursor.?, 1);
    defer earlier.deinit(alloc);
    try std.testing.expectEqualStrings("saved legacy answer", earlier.turns[0].assistant.assistant);
}

test "journal witness native conversion migrates legacy permissions without changing source bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    const original = "{\"schema_version\":1,\"next_generation\":1,\"rules\":[]}";
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, "permissions.json", original);
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    try std.testing.expectEqual(@as(u8, 2), source.state.permission_state.version);
    const unchanged = try read_file(alloc, &fixture.locked.dir, "permissions.json", 1024);
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
    fixture.locked.park();
    var execution_state: execution.State = .{};
    defer execution_state.deinit(alloc);
    const owner = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &execution_state, 0, .{});
    defer owner.deinit();
    var restored = try @import("execution_journal_genesis.zig").decodeBase(alloc, execution_state.nativeBase().?);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 2), restored.permission_state.version);
    try expect_archive_unchanged(alloc, &fixture, &source);
}

test "journal witness native probe preserves legacy interrupted replacement discovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    try fixture.writeLegacy(2);
    const stable = try read_file(alloc, &fixture.locked.dir, metadata_name, max_source_bytes);
    defer alloc.free(stable);
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, "session.legacy.json", stable);
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, "authority.pending.json", "pending");
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, metadata_name, "interrupted replacement");
    try std.testing.expect(try inspect(alloc, &fixture.locked.dir, fixture.locked.session_id) == null);
    fixture.locked.park();
    var facade = try session_store.Store.initFromHome(alloc, fixture.home, fixture.home);
    defer facade.deinit(alloc);
    var resumed = try facade.resumeTargetForWrite(alloc, .last, fixture.home, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(fixture.locked.session_id, resumed.active_id);
    try std.testing.expectEqualStrings("saved legacy answer", resumed.state.history[0].assistant.assistant);
}

test "journal witness native inspection preserves pending entries and incomplete bytes without repair" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    try std.testing.expect(try inspect(alloc, &fixture.locked.dir, fixture.locked.session_id) == null);
    fixture.locked.park();
    var state: execution.State = .{};
    defer state.deinit(alloc);
    var owner: ?*Session = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{});
    defer if (owner) |value| value.deinit();
    var runtime = @import("../agent/runtime/journal_runtime.zig").Runtime{
        .alloc = alloc,
        .state = &state,
        .sink = owner.?.sink(),
        .namespace = "unused-owner-id",
        .creation_id = "native-inspection",
        .request_id = "pending-request",
    };
    _ = try runtime.begin(.{ .text = @constCast("preserve unfinished input") }, "test/model", 7, false);
    {
        var live = (try inspect(alloc, &fixture.locked.dir, fixture.locked.session_id)).?;
        defer live.deinit(alloc);
        try std.testing.expectEqual(@as(u64, 2), live.state.last_seq);
        try std.testing.expect(live.state.pending() == .model);
        try std.testing.expect(!live.incomplete_tail);
    }
    owner.?.deinit();
    owner = null;
    var file = try authority.openSessionFile(&fixture.locked.dir, journal_name, .writable);
    try file.writePositionalAll(io_mod.getIo(), "FXE", try file.length(io_mod.getIo()));
    file.close(io_mod.getIo());
    const before = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
    defer alloc.free(before);
    var snapshot = (try inspect(alloc, &fixture.locked.dir, fixture.locked.session_id)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.incomplete_tail);
    try std.testing.expect(snapshot.state.pending() == .model);
    try std.testing.expectEqualStrings("pending-request", try execution.string(snapshot.state.start(0), "requestId"));
    const after = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

const TestCut = struct {
    boundary: Boundary,
    observed: bool = false,

    fn stop(raw: ?*anyopaque, boundary: Boundary) !void {
        const self: *TestCut = @ptrCast(@alignCast(raw.?));
        if (boundary == self.boundary) {
            self.observed = true;
            return error.CutoverInterrupted;
        }
    }
};

fn expect_archive_unchanged(alloc: Allocator, test_session: *TestSession, source: *const ValidatedSource) !void {
    var marker = try parse_marker(alloc, &test_session.locked.dir, test_session.locked.session_id);
    defer marker.deinit();
    var stage = try open_child(&test_session.locked.dir, marker.value.archive);
    defer stage.close();
    var archive = try open_child(&stage, "source");
    defer archive.close();
    for (source.files) |file| {
        const bytes = try checked_source_bytes(alloc, &archive, file);
        alloc.free(bytes);
    }
}

test "journal witness native storage cutover preserves source and uses required genesis encoder" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    try std.testing.expectEqual(@as(u8, 4), source.schema_version);
    try std.testing.expectEqualStrings("saved legacy question", source.state.history[0].assistant.user.text);
    var encoder = TestGenesis{};
    try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
    try std.testing.expectEqual(@as(usize, 1), encoder.calls);
    try expect_archive_unchanged(alloc, &fixture, &source);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, "events.jsonl"));
    var replay = TestReplay{ .alloc = alloc };
    defer replay.deinit();
    var store = try open(alloc, &fixture.locked, replay.replay(), .{});
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.entries.items.len);
    try std.testing.expectEqual(@as(u64, 1), store.append_journal.cursor.seq);
    var state = try @import("execution_journal_genesis.zig").decodeBase(alloc, replay.entries.items[0].payload.value.object.get("nativeBase").?);
    defer state.deinit(alloc);
    try std.testing.expectEqualStrings("saved legacy answer", state.history[0].assistant.assistant);
    try std.testing.expectError(error.InvalidSessionFormat, authority.classifyAuthority(alloc, &fixture.locked.dir, fixture.locked.session_id));
    const metadata = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
    defer alloc.free(metadata);
    try std.testing.expectError(error.UnsupportedSessionSchema, session_json.parseLegacySchemaVersion(alloc, metadata));
    try std.testing.expectError(error.FileNotFound, migration.migrateSchemaV3Locked(fixture.options().context, alloc, &fixture.locked));
    try expect_archive_unchanged(alloc, &fixture, &source);
}

test "journal witness native storage recreates at every cutover boundary" {
    const alloc = std.testing.allocator;
    for (std.enums.values(Boundary)) |boundary| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        var source = try inspectSource(alloc, &fixture.locked, fixture.options());
        defer source.deinit();
        var encoder = TestGenesis{};
        var cut = TestCut{ .boundary = boundary };
        try std.testing.expectError(error.CutoverInterrupted, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{ .context = &cut, .boundary_fn = TestCut.stop }));
        try std.testing.expect(cut.observed);
        try fixture.relock();
        if (boundary == .staged) {
            // No marker was published, so an unreferenced stage cannot become
            // authority. A new attempt revalidates the unchanged original.
            try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
            try std.testing.expectEqual(@as(usize, 2), encoder.calls);
        } else {
            try recoverCutover(alloc, &fixture.locked, .{});
            try std.testing.expectEqual(@as(usize, 1), encoder.calls);
        }
        try expect_archive_unchanged(alloc, &fixture, &source);
        var replay = TestReplay{ .alloc = alloc };
        defer replay.deinit();
        var store = try open(alloc, &fixture.locked, replay.replay(), .{});
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 1), store.append_journal.cursor.seq);
    }
}

test "journal witness native storage appends exact entries and retains complete pending turns" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    var encoder = TestGenesis{};
    try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
    var replay = TestReplay{ .alloc = alloc };
    defer replay.deinit();
    var store = try open(alloc, &fixture.locked, replay.replay(), .{});
    var owned = true;
    defer if (owned) store.deinit();
    const prefix = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
    defer alloc.free(prefix);
    var pending = try codec.create(alloc, 2, .turn_start, "{\"v\":1,\"kind\":\"turn_start\",\"text\":\"雪\"}");
    defer pending.deinit(alloc);
    const sink = store.sink();
    try sink.append_fn(sink.context, pending.entry);
    try sink.append_fn(sink.context, pending.entry);
    const length = try store.file.length(io_mod.getIo());
    try std.testing.expectEqual(prefix.len + header_bytes + pending.entry.bytes.len, length);
    const after = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, prefix, after[0..prefix.len]);
    store.deinit();
    owned = false;
    try fixture.relock();
    var restored = TestReplay{ .alloc = alloc };
    defer restored.deinit();
    var next = try open(alloc, &fixture.locked, restored.replay(), .{});
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.entries.items.len);
    try std.testing.expectEqualSlices(u8, pending.entry.bytes, restored.entries.items[1].entry.bytes);
    try std.testing.expectEqual(length, try next.file.length(io_mod.getIo()));
}

test "journal witness native storage repairs only incomplete trailing frames" {
    const alloc = std.testing.allocator;
    for ([_]usize{ 3, header_bytes, header_bytes + 4 }) |partial_length| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        var source = try inspectSource(alloc, &fixture.locked, fixture.options());
        defer source.deinit();
        var encoder = TestGenesis{};
        try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
        const before = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
        defer alloc.free(before);
        var entry = try codec.create(alloc, 2, .turn_start, "{\"v\":1,\"kind\":\"turn_start\"}");
        defer entry.deinit(alloc);
        const frame = try encode_frame(alloc, entry.entry);
        defer alloc.free(frame);
        var file = try authority.openSessionFile(&fixture.locked.dir, journal_name, .writable);
        try file.writePositionalAll(io_mod.getIo(), frame[0..partial_length], before.len);
        file.close(io_mod.getIo());
        try fixture.relock();
        var replay = TestReplay{ .alloc = alloc };
        defer replay.deinit();
        var store = try open(alloc, &fixture.locked, replay.replay(), .{});
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 1), store.append_journal.cursor.seq);
        const after = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
        defer alloc.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }
}

test "journal witness native source eligibility leaves incomplete legacy bytes untouched" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    var file = try authority.openSessionFile(&fixture.locked.dir, "events.jsonl", .writable);
    try file.writePositionalAll(io_mod.getIo(), "{\"schema_version\":", try file.length(io_mod.getIo()));
    file.close(io_mod.getIo());
    const before = try read_file(alloc, &fixture.locked.dir, "events.jsonl", max_source_bytes);
    defer alloc.free(before);
    try std.testing.expectError(error.TruncatedEventFrame, inspectSource(alloc, &fixture.locked, fixture.options()));
    const after = try read_file(alloc, &fixture.locked.dir, "events.jsonl", max_source_bytes);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
}

const TestSyncFailure = struct {
    kind: enum { file, directory },
    armed: bool = false,
    failed: bool = false,

    fn ops(self: *TestSyncFailure) io_mod.DurableOps {
        return .{ .ctx = self, .sync_file = sync_file, .sync_dir = sync_dir };
    }

    fn sync_file(raw: ?*anyopaque, file: std.Io.File) !void {
        const self: *TestSyncFailure = @ptrCast(@alignCast(raw.?));
        if (self.armed and self.kind == .file) {
            self.armed = false;
            self.failed = true;
            return error.InjectedSyncFailure;
        }
        try file.sync(io_mod.getIo());
    }

    fn sync_dir(raw: ?*anyopaque, dir: std.Io.Dir) !void {
        const self: *TestSyncFailure = @ptrCast(@alignCast(raw.?));
        if (self.armed and self.kind == .directory) {
            self.armed = false;
            self.failed = true;
            return error.InjectedSyncFailure;
        }
        try io_mod.syncVerifiedDir(dir);
    }

    fn before_manifest(raw: ?*anyopaque, boundary: Boundary) !void {
        const self: *TestSyncFailure = @ptrCast(@alignCast(raw.?));
        if (boundary == .journal_installed) self.armed = true;
    }
};

test "journal witness native metadata retains identity and journal across uncertain writes" {
    const alloc = std.testing.allocator;
    for ([_]enum { success, before_rename, after_rename }{ .success, .before_rename, .after_rename }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        fixture.locked.park();
        var state: execution.State = .{};
        defer state.deinit(alloc);
        var owner: ?*Session = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{});
        defer if (owner) |value| value.deinit();
        var before = try owner.?.readMetadata();
        defer before.deinit();
        const journal_before = try read_file(alloc, &owner.?.locked.dir, journal_name, max_source_bytes);
        defer alloc.free(journal_before);
        var replacement = before.value;
        replacement.id = "different-session";
        try std.testing.expectError(error.JournalConflict, owner.?.replaceMetadata(replacement));
        try owner.?.writer.append_journal.ensure_available();
        replacement = before.value;
        replacement.title = "Retained native title";
        replacement.model = "test/replacement";
        replacement.updated_at_ms += 1;
        var failure = TestSyncFailure{ .kind = if (mode == .after_rename) .directory else .file, .armed = mode != .success };
        owner.?.writer.ops = failure.ops();
        if (mode == .success) {
            try owner.?.replaceMetadata(replacement);
        } else {
            try std.testing.expectError(
                if (mode == .after_rename) error.DurableReplacePostRenameFailed else error.DurableReplacePreRenameFailed,
                owner.?.replaceMetadata(replacement),
            );
            try std.testing.expectError(error.JournalUnavailable, owner.?.readMetadata());
        }
        owner.?.deinit();
        owner = null;
        state.deinit(alloc);
        state = .{};
        owner = try Session.acquire(alloc, &fixture.root, fixture.locked.session_id, fixture.options(), &state, 0, .{});
        var after = try owner.?.readMetadata();
        defer after.deinit();
        try std.testing.expectEqualStrings(before.value.id, after.value.id);
        try std.testing.expectEqualStrings(if (mode == .before_rename) before.value.model else replacement.model, after.value.model);
        if (mode != .before_rename) try std.testing.expectEqualStrings(replacement.title.?, after.value.title.?);
        try std.testing.expectEqual(@as(u64, 1), state.last_seq);
        const journal_after = try read_file(alloc, &owner.?.locked.dir, journal_name, max_source_bytes);
        defer alloc.free(journal_after);
        try std.testing.expectEqualSlices(u8, journal_before, journal_after);
    }
}

test "journal witness native storage recreates both sides of an uncertain manifest replacement" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |after_rename| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        var source = try inspectSource(alloc, &fixture.locked, fixture.options());
        defer source.deinit();
        var encoder = TestGenesis{};
        var failure = TestSyncFailure{ .kind = if (after_rename) .directory else .file };
        const expected = if (after_rename) error.DurableReplacePostRenameFailed else error.DurableReplacePreRenameFailed;
        try std.testing.expectError(expected, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{
            .durable_ops = failure.ops(),
            .context = &failure,
            .boundary_fn = TestSyncFailure.before_manifest,
        }));
        try std.testing.expect(failure.failed);
        const metadata = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
        defer alloc.free(metadata);
        try std.testing.expectEqual(@as(u64, if (after_rename) 5 else 4), try authority.manifestSchemaVersion(alloc, metadata));
        try expect_archive_unchanged(alloc, &fixture, &source);
        try fixture.relock();
        try recoverCutover(alloc, &fixture.locked, .{});
        var replay = TestReplay{ .alloc = alloc };
        defer replay.deinit();
        var store = try open(alloc, &fixture.locked, replay.replay(), .{});
        defer store.deinit();
        try std.testing.expectEqual(@as(usize, 1), encoder.calls);
        try std.testing.expectEqual(@as(u64, 1), store.append_journal.cursor.seq);
        try expect_archive_unchanged(alloc, &fixture, &source);
    }
}

test "journal witness native storage fences failed append sync and restores the actual file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    var encoder = TestGenesis{};
    try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
    var replay = TestReplay{ .alloc = alloc };
    defer replay.deinit();
    var failure = TestSyncFailure{ .kind = .file };
    var store = try open(alloc, &fixture.locked, replay.replay(), failure.ops());
    var owned = true;
    defer if (owned) store.deinit();
    var entry = try codec.create(alloc, 2, .turn_start, "{\"v\":1,\"kind\":\"turn_start\"}");
    defer entry.deinit(alloc);
    failure.armed = true;
    const sink = store.sink();
    try std.testing.expectError(error.InjectedSyncFailure, sink.append_fn(sink.context, entry.entry));
    try std.testing.expectError(error.JournalUnavailable, sink.append_fn(sink.context, entry.entry));
    try std.testing.expectEqual(@as(u64, 1), store.append_journal.cursor.seq);
    store.deinit();
    owned = false;
    try fixture.relock();
    var restored = TestReplay{ .alloc = alloc };
    defer restored.deinit();
    var next = try open(alloc, &fixture.locked, restored.replay(), .{});
    defer next.deinit();
    try std.testing.expectEqual(@as(u64, 2), next.append_journal.cursor.seq);
    try std.testing.expectEqual(@as(usize, 2), restored.entries.items.len);
}

test "journal witness native storage refuses complete invalid records without tail repair" {
    const alloc = std.testing.allocator;
    for ([_]enum { hash, version, sequence }{ .hash, .version, .sequence }) |damage| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        var source = try inspectSource(alloc, &fixture.locked, fixture.options());
        defer source.deinit();
        var encoder = TestGenesis{};
        try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
        var entry = try codec.create(alloc, if (damage == .sequence) 3 else 2, .turn_start, "{\"v\":1,\"kind\":\"turn_start\"}");
        defer entry.deinit(alloc);
        const frame = try encode_frame(alloc, entry.entry);
        defer alloc.free(frame);
        if (damage == .hash) frame[frame.len - 1] = ' ';
        if (damage == .version) frame[4] = 2;
        var file = try authority.openSessionFile(&fixture.locked.dir, journal_name, .writable);
        try file.writePositionalAll(io_mod.getIo(), frame, try file.length(io_mod.getIo()));
        file.close(io_mod.getIo());
        const before = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
        defer alloc.free(before);
        var replay = TestReplay{ .alloc = alloc };
        defer replay.deinit();
        const expected = switch (damage) {
            .hash => error.InvalidHash,
            .version => error.InvalidJournalFrame,
            .sequence => error.JournalConflict,
        };
        try std.testing.expectError(expected, open(alloc, &fixture.locked, replay.replay(), .{}));
        const after = try read_file(alloc, &fixture.locked.dir, journal_name, max_source_bytes);
        defer alloc.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }
}

test "journal witness native source rejects changed state child work and conflicting sidecars" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "authority.pending.json", "events.v3.backup", "upgrade-handoff.json" }) |conflict| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, conflict, "preserved conflict");
        try std.testing.expectError(error.JournalSourceConflict, inspectSource(alloc, &fixture.locked, fixture.options()));
        const bytes = try read_file(alloc, &fixture.locked.dir, conflict, 100);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings("preserved conflict", bytes);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    const children =
        \\{"schema_version":2,"parent_id":"native-journal-test","generation":1,"children":[{"id":"child-1","kind":"one_off","persistent":null,"phase":"running","work_generation":1,"active":{"id":"work-1","request_fingerprint":"0000000000000000000000000000000000000000000000000000000000000000","message":"review","root_user_intent_context":"","root_user_messages":[],"root_user_evidence_complete":true,"permission_mode":"auto","created_at_ms":1},"last_work_id":null,"last_request_fingerprint":null,"last_outcome":null,"last_failure":null}]}
    ;
    try write_relative(alloc, &fixture.locked.dir, "subagent/children.json", children, .{});
    try std.testing.expectError(error.PendingTurnError, inspectSource(alloc, &fixture.locked, fixture.options()));
    var encoder = TestGenesis{};
    try std.testing.expectError(error.JournalSourceConflict, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{}));
    try std.testing.expectEqual(@as(usize, 0), encoder.calls);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
}

test "journal witness native source inspection releases every allocation without writing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn run(a: Allocator, test_session: *TestSession) !void {
            var source = try inspectSource(a, &test_session.locked, test_session.options());
            source.deinit();
        }
    }.run, .{&fixture});
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
}

test "journal witness native storage converts all completed legacy source versions without invented requests" {
    const alloc = std.testing.allocator;
    for ([_]u8{ 1, 2, 3, 4 }) |version| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        try fixture.writeLegacy(version);
        var source_options = fixture.options();
        source_options.legacy_preferences = .{ .model = @constCast("test/model"), .effort = .literal("high"), .fast_mode = false };
        var source = try inspectSource(alloc, &fixture.locked, source_options);
        defer source.deinit();
        try std.testing.expectEqual(version, source.schema_version);
        try std.testing.expectEqualStrings(if (version == 4) "auto" else "high", source.metadata.effort);
        try std.testing.expectEqualStrings("saved legacy answer", source.state.history[0].assistant.assistant);
        var encoder = TestGenesis{};
        try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
        try expect_archive_unchanged(alloc, &fixture, &source);
        var replay = TestReplay{ .alloc = alloc };
        defer replay.deinit();
        var store = try open(alloc, &fixture.locked, replay.replay(), .{});
        defer store.deinit();
        try std.testing.expectEqual(@as(usize, 0), replay.entries.items[0].payload.value.object.get("records").?.array.items.len);
        try std.testing.expect(replay.entries.items[0].payload.value.object.get("requestId") == null);
        var restored: execution.State = .{};
        defer restored.deinit(alloc);
        const entry = replay.entries.items[0].entry;
        try restored.restoreValidated(alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash, .{
            .context = &fixture,
            .validate_fn = struct {
                fn validate(_: *anyopaque, state: *const execution.State, body: std.json.Value) !void {
                    try @import("../agent/runtime/journal_runtime.zig").validateIncoming(std.testing.allocator, state, body);
                }
            }.validate,
        });
        const runtime = @import("../agent/runtime/journal_runtime.zig");
        const history = try runtime.restoreHistory(alloc, &restored);
        defer types.freeHistoryTurnSlice(alloc, history);
        try std.testing.expectEqualStrings("saved legacy question", history[0].assistant.user.text);
        try std.testing.expectEqualStrings("saved legacy answer", history[0].assistant.assistant);
        try std.testing.expectEqual(@as(usize, 0), restored.turns.items.len);
        var next = runtime.Runtime{
            .alloc = alloc,
            .state = &restored,
            .sink = store.sink(),
            .namespace = "new-owner-id",
            .creation_id = "recreated",
            .request_id = "first-journal-request",
        };
        try std.testing.expectEqual(runtime.Selection.new_turn, try next.begin(.{ .text = @constCast("continue") }, "test/model", 10, false));
        try std.testing.expectEqualStrings("native-journal-test", try execution.string(restored.start(0), "namespace"));
        try std.testing.expectEqual(@as(u64, 2), store.append_journal.cursor.seq);
        try expect_archive_unchanged(alloc, &fixture, &source);
    }
}

fn older_environment(alloc: Allocator, home: []const u8) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(alloc);
    errdefer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    try environment.put("AI_GATEWAY_API_KEY", "native-compatibility-fixture");
    try environment.put("FX_MODEL", "test/model");
    try environment.put("FX_GATEWAY_CHAT_URL", "http://127.0.0.1:1/unreachable");
    try environment.put("FX_GATEWAY_BASE_URL", "http://127.0.0.1:1");
    try environment.put("FX_E2E_GATEWAY_CHAT_URL", "http://127.0.0.1:1/unreachable");
    try environment.put("FX_AUTO_UPGRADE", "0");
    try environment.put("FX_E2E_FAIL_ON_DURABLE_MUTATION", "1");
    return environment;
}

fn older_binary() ![]const u8 {
    const path = std.c.getenv("FX_JOURNAL_OLDER_EXE") orelse return error.SkipZigTest;
    const bytes = std.mem.span(path);
    if (!std.fs.path.isAbsolute(bytes)) return error.InvalidOlderExecutablePath;
    return bytes;
}

test "journal witness native older binary refuses converted v1 v2 v3 v4 sessions without writes" {
    const binary = try older_binary();
    const alloc = std.testing.allocator;
    for ([_]u8{ 1, 2, 3, 4 }) |version| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        try fixture.writeLegacy(version);
        var source_options = fixture.options();
        source_options.legacy_preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false };
        var source = try inspectSource(alloc, &fixture.locked, source_options);
        defer source.deinit();
        var environment = try older_environment(alloc, fixture.home);
        defer environment.deinit();
        const original = try std.process.run(alloc, io_mod.getIo(), .{
            .argv = &.{ binary, "session", "--id", "native-journal-test", "--json" },
            .cwd = .{ .path = fixture.home },
            .environ_map = &environment,
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
        defer alloc.free(original.stdout);
        defer alloc.free(original.stderr);
        if (!std.meta.eql(original.term, std.process.Child.Term{ .exited = 0 })) std.debug.print("older source control v{d}\nstdout={s}\nstderr={s}\n", .{ version, original.stdout, original.stderr });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, original.term);
        var encoder = TestGenesis{};
        try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
        const marker_before = try read_file(alloc, &fixture.locked.dir, marker_name, 16 * 1024);
        defer alloc.free(marker_before);
        const manifest_before = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
        defer alloc.free(manifest_before);
        fixture.locked.park();
        for ([_][]const []const u8{
            &.{ binary, "session", "--id", "native-journal-test", "--json" },
            &.{ binary, "session", "migrate", "--id", "native-journal-test", "--json" },
            &.{ binary, "ask", "--json", "--auto", "--resume-id", "native-journal-test", "compatibility probe" },
        }) |argv| {
            const result = try std.process.run(alloc, io_mod.getIo(), .{
                .argv = argv,
                .cwd = .{ .path = fixture.home },
                .environ_map = &environment,
                .stdout_limit = .limited(16 * 1024),
                .stderr_limit = .limited(16 * 1024),
                .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
            });
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
            var format_refused = false;
            for ([_][]const u8{ "InvalidSessionFormat", "UnsupportedSessionSchema", "SessionNotFound", "SessionMigrationRequired" }) |code| {
                if (std.mem.find(u8, result.stdout, code) != null or std.mem.find(u8, result.stderr, code) != null) format_refused = true;
            }
            if (!format_refused) std.debug.print("older v{d} command={s}\nstdout={s}\nstderr={s}\n", .{ version, argv[1], result.stdout, result.stderr });
            try std.testing.expect(format_refused);
        }
        try fixture.relock();
        const marker_after = try read_file(alloc, &fixture.locked.dir, marker_name, 16 * 1024);
        defer alloc.free(marker_after);
        const manifest_after = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
        defer alloc.free(manifest_after);
        try std.testing.expectEqualSlices(u8, marker_before, marker_after);
        try std.testing.expectEqualSlices(u8, manifest_before, manifest_after);
        try expect_archive_unchanged(alloc, &fixture, &source);
        try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, "events.jsonl"));
    }
}

fn observe_old_reader_lock(alloc: Allocator, child: *std.process.Child, session_id: []const u8) !void {
    const lsof = switch (@import("builtin").os.tag) {
        .macos => "/usr/sbin/lsof",
        .linux => "/usr/bin/lsof",
        else => return error.SkipZigTest,
    };
    const process_id = try std.fmt.allocPrint(alloc, "{d}", .{child.id.?});
    defer alloc.free(process_id);
    const suffix = try std.fmt.allocPrint(alloc, "/sessions/{s}/session.lock", .{session_id});
    defer alloc.free(suffix);
    const deadline = io_mod.milliTimestamp() + 1500;
    while (io_mod.milliTimestamp() < deadline) {
        const result = std.process.run(alloc, io_mod.getIo(), .{
            .argv = &.{ lsof, "-nP", "-a", "-p", process_id, "-Fn" },
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } },
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (std.mem.find(u8, result.stdout, suffix) != null) return;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.OlderReaderDidNotReachSessionLock;
}

test "journal witness native older waiting readers cannot restore legacy authority after cutover" {
    const binary = try older_binary();
    const alloc = std.testing.allocator;
    for ([_]u8{ 1, 2, 3, 4 }) |version| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        try fixture.writeLegacy(version);
        var source_options = fixture.options();
        source_options.legacy_preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false };
        var source = try inspectSource(alloc, &fixture.locked, source_options);
        defer source.deinit();
        var environment = try older_environment(alloc, fixture.home);
        defer environment.deinit();
        const argv: []const []const u8 = if (version == 4)
            &.{ binary, "ask", "--json", "--auto", "--resume-id", "native-journal-test", "compatibility probe" }
        else
            &.{ binary, "session", "migrate", "--id", "native-journal-test", "--json" };
        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = argv,
            .cwd = .{ .path = fixture.home },
            .environ_map = &environment,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer if (child.id != null) child.kill(io_mod.getIo());
        // Opening session.lock happens after old format classification. Holding
        // our lock while observing that descriptor proves this is a queued old
        // reader, rather than a fresh post-cutover invocation.
        try observe_old_reader_lock(alloc, &child, fixture.locked.session_id);
        var encoder = TestGenesis{};
        try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
        try observe_old_reader_lock(alloc, &child, fixture.locked.session_id);
        fixture.locked.park();
        const term = try child.wait(io_mod.getIo());
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, term);
        try fixture.relock();
        try expect_archive_unchanged(alloc, &fixture, &source);
        const metadata = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
        defer alloc.free(metadata);
        try std.testing.expectEqual(@as(u64, 5), try authority.manifestSchemaVersion(alloc, metadata));
        try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, "events.jsonl"));
    }
}

fn writeLegacyImageFixture(fixture: *TestSession, path: []const u8, references: usize) ![]u8 {
    const alloc = fixture.alloc;
    const Image = struct { id: usize, path: []const u8, media_type: []const u8 = "image/png" };
    const Turn = struct {
        kind: []const u8 = "assistant",
        user: struct { text: []const u8 = "Legacy [Image #1]", images: []const Image },
        assistant: []const u8 = "saved image",
    };
    const images = [_]Image{.{ .id = if (references == 1) 0 else 1, .path = path }};
    const history = try alloc.alloc(Turn, references);
    defer alloc.free(history);
    for (history) |*turn| turn.* = .{ .user = .{ .images = &images } };
    const bytes = try std.json.Stringify.valueAlloc(alloc, .{
        .schema_version = 2,
        .id = fixture.locked.session_id,
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .workspace_root = fixture.home,
        .conversation_language = "en",
        .history_len = references,
        .history = history,
    }, .{});
    errdefer alloc.free(bytes);
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, metadata_name, bytes);
    return bytes;
}

const legacy_image_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=";

fn writeLegacyImage(alloc: Allocator, tmp: *std.testing.TmpDir) ![:0]u8 {
    const bytes = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(legacy_image_png));
    defer alloc.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, legacy_image_png);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "legacy.png", .data = bytes });
    return tmp.dir.realPathFileAlloc(std.testing.io, "legacy.png", alloc);
}

test "journal witness legacy image capture preserves source and survives every cutover boundary" {
    const alloc = std.testing.allocator;
    for (std.enums.values(Boundary)) |boundary| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        const path = try writeLegacyImage(alloc, &tmp);
        defer alloc.free(path);
        const original = try writeLegacyImageFixture(&fixture, path, 1);
        defer alloc.free(original);
        var options = fixture.options();
        options.legacy_preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false };
        var source = try inspectSource(alloc, &fixture.locked, options);
        defer source.deinit();
        try std.testing.expectEqual(@as(usize, 1), source.captured_snapshots.len);
        try std.testing.expectEqual(@as(usize, 1), source.state.history[0].assistant.user.images[0].id);
        const unchanged = try read_file(alloc, &fixture.locked.dir, metadata_name, 1024 * 1024);
        defer alloc.free(unchanged);
        try std.testing.expectEqualSlices(u8, original, unchanged);
        try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, "images"));
        var encoder: TestGenesis = .{};
        var cut: TestCut = .{ .boundary = boundary };
        try std.testing.expectError(error.CutoverInterrupted, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{ .context = &cut, .boundary_fn = TestCut.stop }));
        try std.testing.expect(cut.observed);
        try fixture.relock();
        if (boundary == .staged) {
            try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, "images"));
            try cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{});
        } else {
            try tmp.dir.deleteFile(std.testing.io, "legacy.png");
            try recoverCutover(alloc, &fixture.locked, .{});
            try std.testing.expectEqual(@as(usize, 1), encoder.calls);
        }
        try expect_archive_unchanged(alloc, &fixture, &source);
        var image = try image_attachments.loadVerifiedSnapshot(alloc, source.state.history[0].assistant.user.images[0], .{});
        defer image.deinit(alloc);
        try std.testing.expectEqualSlices(u8, source.captured_snapshots[0].bytes, image.bytes);
        var manifest = try read_manifest(alloc, &fixture.locked);
        defer manifest.deinit();
        try std.testing.expectEqual(@as(u8, 5), manifest.value.schema_version);
    }
}

test "journal witness legacy image capture is deduplicated and missing staged bytes block publication" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |corrupt| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        const path = try writeLegacyImage(alloc, &tmp);
        defer alloc.free(path);
        const original = try writeLegacyImageFixture(&fixture, path, 2);
        defer alloc.free(original);
        var options = fixture.options();
        options.legacy_preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false };
        var source = try inspectSource(alloc, &fixture.locked, options);
        defer source.deinit();
        try std.testing.expectEqual(@as(usize, 1), source.captured_snapshots.len);
        var encoder: TestGenesis = .{};
        var cut: TestCut = .{ .boundary = .marker_published };
        try std.testing.expectError(error.CutoverInterrupted, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{ .context = &cut, .boundary_fn = TestCut.stop }));
        var marker = try parse_marker(alloc, &fixture.locked.dir, fixture.locked.session_id);
        defer marker.deinit();
        var stage = try open_child(&fixture.locked.dir, marker.value.archive);
        defer stage.close();
        const captured = source.captured_snapshots[0];
        if (corrupt) try write_relative(alloc, &stage, captured.relative_path, "corrupt snapshot", .{}) else try stage.dir.deleteFile(std.testing.io, captured.relative_path);
        try tmp.dir.deleteFile(std.testing.io, "legacy.png");
        try fixture.relock();
        try std.testing.expectError(if (corrupt) error.ImageSnapshotCorrupt else error.FileNotFound, recoverCutover(alloc, &fixture.locked, .{}));
        try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, journal_name));
        try expect_archive_unchanged(alloc, &fixture, &source);
        // Exact repair of the durable stage can finish without the old file.
        try write_relative(alloc, &stage, captured.relative_path, captured.bytes, .{});
        try recoverCutover(alloc, &fixture.locked, .{});
        try std.testing.expectEqual(@as(usize, 1), encoder.calls);
    }
}

test "journal witness missing legacy image leaves original storage untouched" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    const path = try writeLegacyImage(alloc, &tmp);
    defer alloc.free(path);
    const original = try writeLegacyImageFixture(&fixture, path, 1);
    defer alloc.free(original);
    try tmp.dir.deleteFile(std.testing.io, "legacy.png");
    var options = fixture.options();
    options.legacy_preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false };
    try std.testing.expectError(error.FileNotFound, inspectSource(alloc, &fixture.locked, options));
    const unchanged = try read_file(alloc, &fixture.locked.dir, metadata_name, 1024 * 1024);
    defer alloc.free(unchanged);
    try std.testing.expectEqualSlices(u8, original, unchanged);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, "images"));
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
}

test "journal witness native source verifies image references under the owning session root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=";
    const bytes = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer alloc.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    const hash = digest(bytes);
    const relative = try std.fmt.allocPrint(alloc, "images/image-1-{s}.bin", .{hash[0..16]});
    defer alloc.free(relative);
    try write_relative(alloc, &fixture.locked.dir, relative, bytes, .{});
    var file = try authority.openSessionFile(&fixture.locked.dir, "events.jsonl", .writable);
    var writer = session_log.ConversationWriter.init(alloc, file) catch |err| {
        file.close(io_mod.getIo());
        return err;
    };
    var writer_owned = true;
    defer if (writer_owned) writer.deinit();
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/this-path-must-not-be-opened.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = relative,
        .snapshot_sha256 = @constCast(&hash),
    }};
    try writer.appendHistoryTurn(alloc, 3, .{ .assistant = .{
        .user = .{ .text = @constCast("look at this image"), .images = &images },
        .assistant = @constCast("saved image answer"),
    } });
    writer.deinit();
    writer_owned = false;
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    const image = source.state.history[1].assistant.user.images[0];
    const trusted_root = try std.fs.path.join(alloc, &.{ fixture.root.display_root, fixture.locked.session_id, "images" });
    defer alloc.free(trusted_root);
    try std.testing.expect(std.mem.startsWith(u8, image.snapshot_path.?, trusted_root));
    try std.testing.expectEqualStrings("/this-path-must-not-be-opened.png", image.path);
    // A changed referenced artifact fails before genesis encoding/publication.
    try write_relative(alloc, &fixture.locked.dir, relative, "corrupt saved image", .{});
    try std.testing.expectError(error.ImageSnapshotCorrupt, inspectSource(alloc, &fixture.locked, fixture.options()));
    var encoder = TestGenesis{};
    try std.testing.expectError(error.JournalSourceConflict, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{}));
    try std.testing.expectEqual(@as(usize, 0), encoder.calls);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
}

test "journal witness native storage does not restore an obsolete source snapshot after a precommit change" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    var source = try inspectSource(alloc, &fixture.locked, fixture.options());
    defer source.deinit();
    var encoder = TestGenesis{};
    var cut = TestCut{ .boundary = .marker_published };
    try std.testing.expectError(error.CutoverInterrupted, cutover(alloc, &fixture.locked, &source, encoder.encoder(), .{ .context = &cut, .boundary_fn = TestCut.stop }));
    const old = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
    defer alloc.free(old);
    const changed = try std.mem.concat(alloc, u8, &.{ old, "\n" });
    defer alloc.free(changed);
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, metadata_name, changed);
    try fixture.relock();
    try std.testing.expectError(error.JournalSourceConflict, recoverCutover(alloc, &fixture.locked, .{}));
    const retained = try read_file(alloc, &fixture.locked.dir, metadata_name, 16 * 1024);
    defer alloc.free(retained);
    try std.testing.expectEqualSlices(u8, changed, retained);
    try expect_archive_unchanged(alloc, &fixture, &source);
    try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, journal_name));
}

test "journal witness native source rejects invalid terminal records and pending close transactions" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |pending_close| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestSession.init(alloc, &tmp);
        defer fixture.deinit();
        const path = if (pending_close) "terminal/state/close-transaction-test.json" else "terminal/state/record-test.json";
        const bytes = "{\"schema_version\":1,\"owner_session_id\":\"native-journal-test\",\"lifecycle\":\"exited\"}";
        try write_relative(alloc, &fixture.locked.dir, path, bytes, .{});
        const expected = if (pending_close) error.PendingTurnError else error.InvalidTerminalRecord;
        try std.testing.expectError(expected, inspectSource(alloc, &fixture.locked, fixture.options()));
        const retained = try read_relative(alloc, &fixture.locked.dir, path, 4096);
        defer alloc.free(retained);
        try std.testing.expectEqualStrings(bytes, retained);
        try std.testing.expect(!try authority.entryExistsRelative(&fixture.locked.dir, marker_name));
    }
}

test "journal witness native source rejects raw v3 pending recovery before compatibility archival" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestSession.init(alloc, &tmp);
    defer fixture.deinit();
    try fixture.writeLegacy(3);
    const recovery =
        \\{"schema_version":1,"log_generation":"01010101010101010101010101010101","seq":3,"event_id":"03030303030303030303030303030303","timestamp_ms":3,"kind":"recovery_checkpoint_set","payload":{"checkpoint":{"version":2,"route_identity":{"connection_id":"vercel","adapter_kind":"vercel_ai_gateway","permission_review_model_id":"review"},"delivery":"possibly_sent","turn_id":1,"user":{"text":"pending request","images":[]},"assistant_source":"saved partial","execution":{"schema_version":3,"tool_steps":[],"files":[]},"cause":"response_interrupted","action":"continuing_response","tool_state":"uncertain","route_model":"test/model","requested_fast_mode":false,"fast_mode":false,"max_provider_attempts":3,"consumed_provider_attempts":0,"outstanding_reservation":false}}}
    ++ "\n";
    var file = try authority.openSessionFile(&fixture.locked.dir, "events.jsonl", .writable);
    const length = try file.length(io_mod.getIo());
    try file.writePositionalAll(io_mod.getIo(), recovery, length);
    file.close(io_mod.getIo());
    const watermark = try std.fmt.allocPrint(alloc, "{{\"schema_version\":1,\"session_id\":\"native-journal-test\",\"log_generation\":\"01010101010101010101010101010101\",\"through_seq\":3,\"through_event_id\":\"03030303030303030303030303030303\",\"through_event_log_bytes\":{d}}}", .{length + recovery.len});
    defer alloc.free(watermark);
    try io_mod.durableReplaceVerified(alloc, &fixture.locked.dir, "commit.01010101010101010101010101010101.json", watermark);
    const before = try read_file(alloc, &fixture.locked.dir, "events.jsonl", max_source_bytes);
    defer alloc.free(before);
    try std.testing.expectError(error.PendingTurnError, inspectSource(alloc, &fixture.locked, fixture.options()));
    var legacy_view = try migration.loadSchemaV3ReadOnly(alloc, &fixture.locked.dir, fixture.locked.session_id);
    defer legacy_view.deinit(alloc);
    try std.testing.expect(legacy_view.state.recovery_checkpoint == null);
    try std.testing.expectEqual(@as(usize, 2), legacy_view.state.history.len);
    const after = try read_file(alloc, &fixture.locked.dir, "events.jsonl", max_source_bytes);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

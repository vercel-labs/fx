const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");
const Allocator = std.mem.Allocator;

const discovery = @import("session_discovery.zig");
const paths = @import("session_store_paths.zig");
const summary_codec = @import("session_summary_codec.zig");
const store_types = @import("session_store_types.zig");

const validateSessionId = paths.validateSessionId;
const SessionSummary = store_types.SessionSummary;
const summaryFromState = discovery.summaryFromState;
const freeSummaries = summary_codec.freeSummaries;
const readSessionIndexForRepair = summary_codec.readSessionIndexForRepair;
const removeSessionIndexMarker = summary_codec.removeSessionIndexMarker;
const replaceIndexedSummary = summary_codec.replaceIndexedSummary;
const writeSessionIndex = summary_codec.writeSessionIndex;
const writeSessionIndexMarker = summary_codec.writeSessionIndexMarker;

/// Two-phase state of a workspace latest pointer on disk: `pending` is written
/// under lock before commit, `ready` after the session is durable.
pub const PointerStatus = enum { pending, ready };

pub const LatestPointer = struct {
    session_id: []u8,
    updated_at_ms: i64,

    pub fn deinit(self: *LatestPointer, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const InitialIndexEffect = union(enum) {
    maintain,
    preserve,
    replace_latest_if_current: ConditionalLatestReplacement,
};

pub const LatestCandidate = struct {
    session_id: []const u8,
    updated_at_ms: i64,
};

pub const ConditionalLatestReplacement = struct {
    expected_current_id: []const u8,
    discovered_latest: ?LatestCandidate,
    observed_snapshot: LatestSnapshotToken,
};

pub const LatestSnapshotToken = union(enum) {
    missing,
    file: struct {
        inode: u128,
        size: u64,
        mtime_ns: i96,
        ctime_ns: i96,
    },
};

const LatestPointerJson = struct {
    schema_version: i64,
    status: []const u8,
    workspace_root: []const u8,
    session_id: ?[]const u8 = null,
    updated_at_ms: ?i64 = null,
};

pub const LatestCache = struct {
    sessions: io_mod.VerifiedDir,
    test_controls: session_log.TestControls,
    cache_lock: ?io_mod.TimedAdvisoryLock = null,
    pending_workspace_roots: std.ArrayList([]u8) = .empty,
    prior_ready: ?LatestPointer = null,
    prior_index: ?std.ArrayList(SessionSummary) = null,
    next_index_effect: InitialIndexEffect,

    pub fn init(
        alloc: Allocator,
        sessions: *const io_mod.VerifiedDir,
        test_controls: session_log.TestControls,
        initial_index_effect: InitialIndexEffect,
    ) !*LatestCache {
        const owned_sessions = try sessions.dir.openDir(io_mod.getIo(), ".", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer owned_sessions.close(io_mod.getIo());
        const result = try alloc.create(LatestCache);
        result.* = .{
            .sessions = .{ .dir = owned_sessions },
            .test_controls = test_controls,
            .next_index_effect = initial_index_effect,
        };
        return result;
    }

    pub fn deinit(self: *LatestCache, alloc: Allocator) void {
        self.abort();
        self.clearPreparedState(alloc);
        self.sessions.close();
        alloc.destroy(self);
    }

    fn clearPreparedState(self: *LatestCache, alloc: Allocator) void {
        for (self.pending_workspace_roots.items) |workspace_root| alloc.free(workspace_root);
        self.pending_workspace_roots.deinit(alloc);
        self.pending_workspace_roots = .empty;
        if (self.prior_ready) |*pointer| pointer.deinit(alloc);
        self.prior_ready = null;
        if (self.prior_index) |*index| freeSummaries(alloc, index);
        self.prior_index = null;
    }

    pub fn begin(
        self: *LatestCache,
        alloc: Allocator,
        session_id: []const u8,
        previous_workspace_root: []const u8,
        next_workspace_root: []const u8,
        commit_lock_deadline_ms: u64,
    ) !void {
        if (self.cache_lock == null) {
            self.cache_lock = io_mod.acquireTimedAdvisoryLock(
                &self.sessions,
                latest_sessions_lock_file,
                commit_lock_deadline_ms,
            ) catch |err| return switch (err) {
                error.LockBusy => error.LatestCacheLockBusy,
                error.LockUnsupported => error.SessionCommitBoundaryUnavailable,
                else => err,
            };
        }
        errdefer {
            self.abort();
            self.clearPreparedState(alloc);
        }
        switch (self.next_index_effect) {
            .replace_latest_if_current => |replacement| {
                const current_snapshot = try readLatestSnapshotToken(
                    &self.sessions,
                    next_workspace_root,
                );
                if (!std.meta.eql(
                    current_snapshot,
                    replacement.observed_snapshot,
                )) {
                    return error.SessionLatestBaselineChanged;
                }
            },
            .maintain, .preserve => {},
        }
        if (self.prior_ready == null) {
            self.prior_ready = readLatestPointerFromSessions(
                &self.sessions,
                alloc,
                next_workspace_root,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        switch (self.next_index_effect) {
            .preserve => {},
            .maintain, .replace_latest_if_current => {
                if (self.prior_index == null) {
                    self.prior_index = readSessionIndexForRepair(alloc, &self.sessions) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => null,
                    };
                }
                try writeSessionIndexMarker(alloc, &self.sessions);
            },
        }
        try self.rememberPendingWorkspace(alloc, previous_workspace_root);
        try self.rememberPendingWorkspace(alloc, next_workspace_root);
        for (self.pending_workspace_roots.items) |workspace_root| {
            try self.writePointer(alloc, workspace_root, .pending, session_id, null);
        }
        try self.test_controls.boundary(.after_latest_cache_pending);
    }

    pub fn writeDeferredToken(
        self: *LatestCache,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        position: session_log.CommitPosition,
    ) !void {
        try validateSessionId(session_id);
        const encoded = try summary_codec.encodeDeferredCacheToken(
            alloc,
            session_id,
            workspace_root,
            position,
        );
        defer alloc.free(encoded);

        var latest = try io_mod.openOrCreateVerifiedPrivateDir(
            &self.sessions,
            latest_sessions_dir,
        );
        defer latest.close();
        var deferred = try io_mod.openOrCreateVerifiedPrivateDir(
            &latest,
            deferred_cache_dir,
        );
        defer deferred.close();
        try io_mod.durableReplaceVerified(
            alloc,
            &deferred,
            session_id,
            encoded,
        );
    }

    pub fn publish(
        self: *LatestCache,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
    ) !void {
        defer self.releaseLock();
        defer self.clearPreparedState(alloc);
        const index_effect = self.next_index_effect;
        self.next_index_effect = .maintain;
        try self.test_controls.boundary(.before_latest_cache_ready);
        var prior_candidate: ?LatestCandidate = if (self.prior_ready) |prior|
            .{
                .session_id = prior.session_id,
                .updated_at_ms = prior.updated_at_ms,
            }
        else
            null;
        switch (index_effect) {
            .replace_latest_if_current => |replacement| {
                if (replacement.discovered_latest) |discovered| {
                    if (prior_candidate == null or latestCandidateNewer(
                        discovered,
                        prior_candidate.?,
                    )) {
                        prior_candidate = discovered;
                    }
                }
            },
            .maintain, .preserve => {},
        }
        if (prior_candidate) |prior| {
            const replace_current = switch (index_effect) {
                .replace_latest_if_current => |replacement| std.mem.eql(
                    u8,
                    prior.session_id,
                    replacement.expected_current_id,
                ) or
                    std.mem.eql(u8, prior.session_id, state.id),
                .maintain, .preserve => false,
            };
            if (!replace_current and latestCandidateNewerThanState(prior, state)) {
                try self.writePointer(
                    alloc,
                    state.workspace_root,
                    .ready,
                    prior.session_id,
                    prior.updated_at_ms,
                );
            } else {
                try self.writePointer(
                    alloc,
                    state.workspace_root,
                    .ready,
                    state.id,
                    state.updated_at_ms,
                );
            }
        } else {
            try self.writePointer(
                alloc,
                state.workspace_root,
                .ready,
                state.id,
                state.updated_at_ms,
            );
        }
        switch (index_effect) {
            .preserve => return,
            .maintain, .replace_latest_if_current => {},
        }
        if (self.prior_index) |*index| {
            var summary = try summaryFromState(alloc, state);
            summary.has_durable_activity = position.through_seq > 1;
            var summary_owned = true;
            errdefer if (summary_owned) summary.deinit(alloc);
            try summary_codec.preserveIndexedDisplayMetadata(alloc, index.items, &summary);
            try replaceIndexedSummary(alloc, index, &summary);
            summary_owned = false;
            try writeSessionIndex(alloc, &self.sessions, index.items);
            try removeSessionIndexMarker(&self.sessions);
        }
        try self.clearDeferredTokenIfCovered(
            alloc,
            state.id,
            position,
        );
    }

    fn clearDeferredTokenIfCovered(
        self: *LatestCache,
        alloc: Allocator,
        session_id: []const u8,
        position: session_log.CommitPosition,
    ) !void {
        var token = (try summary_codec.readDeferredCacheToken(
            alloc,
            &self.sessions,
            session_id,
        )) orelse return;
        defer token.deinit(alloc);
        if (!commitPositionCovers(position, token.position)) return;
        try removeDeferredToken(&self.sessions, session_id);
    }

    fn abort(self: *LatestCache) void {
        self.releaseLock();
    }

    fn releaseLock(self: *LatestCache) void {
        if (self.cache_lock) |*lock| lock.release();
        self.cache_lock = null;
    }

    fn rememberPendingWorkspace(
        self: *LatestCache,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !void {
        for (self.pending_workspace_roots.items) |existing| {
            if (std.mem.eql(u8, existing, workspace_root)) return;
        }
        const owned_workspace_root = try alloc.dupe(u8, workspace_root);
        errdefer alloc.free(owned_workspace_root);
        try self.pending_workspace_roots.append(alloc, owned_workspace_root);
    }

    fn writePointer(
        self: *LatestCache,
        alloc: Allocator,
        workspace_root: []const u8,
        status: PointerStatus,
        session_id: []const u8,
        updated_at_ms: ?i64,
    ) !void {
        var latest = try io_mod.openOrCreateVerifiedPrivateDir(
            &self.sessions,
            latest_sessions_dir,
        );
        defer latest.close();
        var name: [69]u8 = undefined;
        const filename = latestPointerFilename(workspace_root, &name);
        const text = try encodeLatestPointer(
            alloc,
            workspace_root,
            status,
            session_id,
            updated_at_ms,
        );
        defer alloc.free(text);
        try io_mod.durableReplaceVerified(alloc, &latest, filename, text);
    }
};

pub const latest_sessions_dir = "latest";

pub const deferred_cache_dir = summary_codec.deferred_cache_dir;

pub const latest_sessions_lock_file = "latest.lock";

const latest_pointer_schema_version: i64 = 2;

const max_latest_pointer_bytes: usize = 8 * 1024;

pub fn readLatestSnapshotToken(
    sessions: *const io_mod.VerifiedDir,
    workspace_root: []const u8,
) !LatestSnapshotToken {
    var latest = sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    defer latest.close(io_mod.getIo());

    var name: [69]u8 = undefined;
    var file = latest.openFile(
        io_mod.getIo(),
        latestPointerFilename(workspace_root, &name),
        .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir, error.SymLinkLoop, error.IsDir => {
            return error.InvalidSessionIndex;
        },
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) {
        return error.InvalidSessionIndex;
    }
    return .{ .file = .{
        .inode = @intCast(stat.inode),
        .size = stat.size,
        .mtime_ns = stat.mtime.toNanoseconds(),
        .ctime_ns = stat.ctime.toNanoseconds(),
    } };
}

fn latestCandidateNewerThanState(
    candidate: LatestCandidate,
    state: session_codec.DurableSessionState,
) bool {
    return latestCandidateNewer(candidate, .{
        .session_id = state.id,
        .updated_at_ms = state.updated_at_ms,
    });
}

fn latestCandidateNewer(
    left: LatestCandidate,
    right: LatestCandidate,
) bool {
    if (left.updated_at_ms != right.updated_at_ms) {
        return left.updated_at_ms > right.updated_at_ms;
    }
    return std.mem.order(u8, left.session_id, right.session_id) == .gt;
}

pub fn commitPositionCovers(
    current: session_log.CommitPosition,
    target: session_log.CommitPosition,
) bool {
    if (!std.mem.eql(u8, &current.log_generation, &target.log_generation)) {
        return true;
    }
    if (current.through_seq != target.through_seq) {
        return current.through_seq > target.through_seq;
    }
    return std.mem.eql(
        u8,
        &current.through_event_id,
        &target.through_event_id,
    ) and current.through_event_log_bytes >= target.through_event_log_bytes;
}

fn deferredTokensEqual(
    left: summary_codec.DeferredCacheToken,
    right: summary_codec.DeferredCacheToken,
) bool {
    return std.mem.eql(u8, left.session_id, right.session_id) and
        std.mem.eql(u8, left.workspace_root, right.workspace_root) and
        std.meta.eql(left.position, right.position);
}

pub fn removeDeferredToken(
    sessions: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !void {
    try validateSessionId(session_id);
    var latest = sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir, error.SymLinkLoop => return error.InvalidSessionIndex,
        else => return err,
    };
    defer latest.close(io_mod.getIo());
    var deferred = latest.openDir(io_mod.getIo(), deferred_cache_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir, error.SymLinkLoop => return error.InvalidSessionIndex,
        else => return err,
    };
    defer deferred.close(io_mod.getIo());
    deferred.deleteFile(io_mod.getIo(), session_id) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try io_mod.syncVerifiedDir(deferred);
}

pub fn clearObservedDeferredToken(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    expected: summary_codec.DeferredCacheToken,
) !void {
    var session_dir = sessions.dir.openDir(io_mod.getIo(), expected.session_id, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            var current = (try summary_codec.readDeferredCacheToken(
                alloc,
                sessions,
                expected.session_id,
            )) orelse return;
            defer current.deinit(alloc);
            if (deferredTokensEqual(expected, current)) {
                try removeDeferredToken(sessions, expected.session_id);
            }
            return;
        },
        error.NotDir, error.SymLinkLoop => return,
        else => return err,
    };
    defer session_dir.close(io_mod.getIo());
    var verified = io_mod.VerifiedDir{ .dir = session_dir };
    var session_lock = io_mod.acquireTimedAdvisoryLock(
        &verified,
        "session.lock",
        0,
    ) catch return;
    defer session_lock.release();

    var current = (try summary_codec.readDeferredCacheToken(
        alloc,
        sessions,
        expected.session_id,
    )) orelse return;
    defer current.deinit(alloc);
    if (!deferredTokensEqual(expected, current)) return;
    try removeDeferredToken(sessions, expected.session_id);
}

/// Commit-lifecycle `prepare` thunk: recovers the `LatestCache` from the opaque
/// context and begins the pending phase for the previous/next workspace roots.
pub fn latestCachePrepare(
    raw: ?*anyopaque,
    alloc: Allocator,
    session_id: []const u8,
    previous_workspace_root: []const u8,
    next_workspace_root: []const u8,
    commit_lock_deadline_ms: u64,
) !void {
    const cache: *LatestCache = @ptrCast(@alignCast(raw orelse return error.SessionStoreUnavailable));
    try cache.begin(
        alloc,
        session_id,
        previous_workspace_root,
        next_workspace_root,
        commit_lock_deadline_ms,
    );
}

/// Commit-lifecycle deferred-publication thunk: persists the proposed
/// canonical boundary before the watermark can advance.
pub fn latestCacheWriteDeferred(
    raw: ?*anyopaque,
    alloc: Allocator,
    session_id: []const u8,
    workspace_root: []const u8,
    position: session_log.CommitPosition,
) !void {
    const cache: *LatestCache = @ptrCast(@alignCast(raw orelse return error.SessionStoreUnavailable));
    try cache.writeDeferredToken(
        alloc,
        session_id,
        workspace_root,
        position,
    );
}

/// Commit-lifecycle `publish` thunk: writes the ready pointer for the committed state.
pub fn latestCachePublish(
    raw: ?*anyopaque,
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    position: session_log.CommitPosition,
) !void {
    const cache: *LatestCache = @ptrCast(@alignCast(raw orelse return error.SessionStoreUnavailable));
    try cache.publish(alloc, state, position);
}

/// Commit-lifecycle `abort` thunk: releases the cache lock without publishing.
pub fn latestCacheAbort(raw: ?*anyopaque) void {
    const cache: *LatestCache = @ptrCast(@alignCast(raw orelse return));
    cache.abort();
}

/// Commit-lifecycle `deinit` thunk: aborts if needed and frees the cache.
pub fn latestCacheDeinit(raw: ?*anyopaque, alloc: Allocator) void {
    const cache: *LatestCache = @ptrCast(@alignCast(raw orelse return));
    cache.deinit(alloc);
}

/// Writes the deterministic pointer filename (sha256(workspace_root) hex +
/// ".json") into `output` and returns the slice.
fn latestPointerFilename(workspace_root: []const u8, output: *[69]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(workspace_root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(output[0..64], &hex);
    @memcpy(output[64..], ".json");
    return output[0..];
}

fn encodeLatestPointer(
    alloc: Allocator,
    workspace_root: []const u8,
    status: PointerStatus,
    session_id: []const u8,
    updated_at_ms: ?i64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"schema_version\":{d},\"status\":", .{latest_pointer_schema_version});
    try std.json.Stringify.value(@tagName(status), .{}, &out.writer);
    try out.writer.writeAll(",\"workspace_root\":");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.writeAll(",\"updated_at_ms\":");
    if (updated_at_ms) |value| {
        try out.writer.print("{d}", .{value});
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

/// Reads the ready pointer for `workspace_root` from the `latest/` directory.
/// Returns null when no pointer exists; `error.InvalidSessionIndex` on a
/// malformed or non-ready file. Caller owns the returned pointer.
pub fn readLatestPointerFromSessions(
    sessions: *const io_mod.VerifiedDir,
    alloc: Allocator,
    workspace_root: []const u8,
) !?LatestPointer {
    var parsed = (try readLatestPointerJsonFromSessions(
        sessions,
        alloc,
        workspace_root,
    )) orelse return null;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.status, "ready")) {
        return error.InvalidSessionIndex;
    }
    const session_id = parsed.value.session_id orelse return error.InvalidSessionIndex;
    const updated_at_ms = parsed.value.updated_at_ms orelse return error.InvalidSessionIndex;
    try validateSessionId(session_id);
    return .{
        .session_id = try alloc.dupe(u8, session_id),
        .updated_at_ms = updated_at_ms,
    };
}

/// Reads an owned pending session ID for `workspace_root`. Returns null when
/// no pointer exists or the pointer is ready.
pub fn readPendingLatestSessionIdFromSessions(
    sessions: *const io_mod.VerifiedDir,
    alloc: Allocator,
    workspace_root: []const u8,
) !?[]u8 {
    var parsed = (try readLatestPointerJsonFromSessions(
        sessions,
        alloc,
        workspace_root,
    )) orelse return null;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.status, "ready")) return null;
    if (!std.mem.eql(u8, parsed.value.status, "pending") or
        parsed.value.updated_at_ms != null)
    {
        return error.InvalidSessionIndex;
    }
    const session_id = parsed.value.session_id orelse return error.InvalidSessionIndex;
    try validateSessionId(session_id);
    const owned_id = try alloc.dupe(u8, session_id);
    return owned_id;
}

fn readLatestPointerJsonFromSessions(
    sessions: *const io_mod.VerifiedDir,
    alloc: Allocator,
    workspace_root: []const u8,
) !?std.json.Parsed(LatestPointerJson) {
    var latest = sessions.dir.openDir(io_mod.getIo(), latest_sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    defer latest.close(io_mod.getIo());

    var name: [69]u8 = undefined;
    var file = latest.openFile(io_mod.getIo(), latestPointerFilename(workspace_root, &name), .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop, error.IsDir => return error.InvalidSessionIndex,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidSessionIndex;
    const bytes = io_mod.readFileToEnd(alloc, &file, max_latest_pointer_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    defer alloc.free(bytes);
    return try decodeLatestPointerJson(alloc, bytes, workspace_root);
}

fn decodeLatestPointerJson(
    alloc: Allocator,
    bytes: []const u8,
    workspace_root: []const u8,
) !std.json.Parsed(LatestPointerJson) {
    var parsed = std.json.parseFromSlice(
        LatestPointerJson,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    if (parsed.value.schema_version != latest_pointer_schema_version or
        !std.mem.eql(u8, parsed.value.workspace_root, workspace_root))
    {
        parsed.deinit();
        return error.InvalidSessionIndex;
    }
    return parsed;
}

test "latest pointer parser handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzLatestPointer, .{
        .corpus = &.{
            "",
            "{}",
            "{\"schema_version\":1,\"status\":\"pending\",\"workspace_root\":\"/tmp/workspace\",\"session_id\":\"session\",\"updated_at_ms\":null}",
            "{\"schema_version\":1,\"status\":\"ready\",\"workspace_root\":\"/tmp/workspace\",\"session_id\":\"session\",\"updated_at_ms\":1}",
        },
    });
}

fn fuzzLatestPointer(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var parsed = decodeLatestPointerJson(
        std.testing.allocator,
        buffer[0..len],
        "/tmp/workspace",
    ) catch return;
    parsed.deinit();
}

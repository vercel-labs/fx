const std = @import("std");
const child_state = @import("child_state.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_discovery = @import("../session/session_discovery.zig");
const catalog_cache = @import("../session/session_catalog_cache.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");

const Allocator = std.mem.Allocator;
const max_page_limit: usize = 100;

pub const ActionableContinuation = struct {
    updated_at_ms: i64,
    id: []u8,

    pub fn deinit(self: *ActionableContinuation, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn view(self: ActionableContinuation) session_store.ResumableSessionContinuation {
        return .{ .updated_at_ms = self.updated_at_ms, .id = self.id };
    }
};

pub const ActionableSessionPage = struct {
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    has_more: bool = false,
    continuation: ?ActionableContinuation = null,

    pub fn deinit(self: *ActionableSessionPage, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        self.* = undefined;
    }
};

pub const ActionableSessionCatalog = struct {
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,

    pub fn deinit(self: *ActionableSessionCatalog, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        self.* = undefined;
    }
};

const CatalogRead = struct {
    store: session_store.Store,
    candidates: session_store.CandidateIterator,
    iterator_mutex: std.Io.Mutex = .init,
    active_id: ?[]const u8,
    cancelled: *std.atomic.Value(bool),
    cache: *const catalog_cache.Loaded,
    changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reused: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn nextId(self: *CatalogRead, alloc: Allocator) !?[]u8 {
        self.iterator_mutex.lockUncancelable(io_mod.getIo());
        defer self.iterator_mutex.unlock(io_mod.getIo());
        return self.candidates.nextId(alloc, self.cancelled);
    }
};

const CatalogWorker = struct {
    read: *CatalogRead,
    alloc: Allocator,
    entries: std.ArrayList(catalog_cache.Entry) = .empty,
    failure: ?anyerror = null,

    fn run(self: *CatalogWorker) void {
        self.readAll() catch |err| {
            self.failure = err;
            self.read.cancelled.store(true, .release);
        };
    }

    fn readAll(self: *CatalogWorker) !void {
        const dir = self.read.store.canonical_root.sessions orelse return;
        while (try self.read.nextId(self.alloc)) |id| {
            defer self.alloc.free(id);
            const before = catalog_cache.fingerprint(dir.dir, id) catch null;
            if (before) |stamp| {
                if (try self.read.cache.reuse(self.alloc, id, stamp)) |value| {
                    var entry = value;
                    errdefer entry.deinit(self.alloc);
                    try self.entries.append(self.alloc, entry);
                    _ = self.read.reused.fetchAdd(1, .monotonic);
                    continue;
                }
            }
            var candidate = self.read.store.readOnlyCandidate(self.alloc, id, self.read.cancelled) catch |err| switch (err) {
                error.OutOfMemory, error.Cancelled => return err,
                else => {
                    session_discovery.logDiscoveryError(.read_only_list, id, null, null, err);
                    continue;
                },
            };
            var owned = true;
            defer if (owned) candidate.deinit(self.alloc);
            const is_active = if (self.read.active_id) |active| std.mem.eql(u8, id, active) else false;
            if (is_active and !candidate.summary.hasResumableContent()) continue;
            if (self.read.cancelled.load(.acquire)) return error.Cancelled;
            var cacheable = candidate.storage == .conversation;
            const managed = if (!candidate.summary.hasResumableContent()) true else child_state.isListedManagedChildSession(self.read.store, self.alloc, &candidate) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => blk: {
                    cacheable = false;
                    break :blk true;
                },
            };
            const after = if (cacheable) catalog_cache.fingerprint(dir.dir, id) catch null else null;
            const stable = if (before) |a| if (after) |z| std.mem.eql(u8, &a, &z) else false else false;
            var entry = catalog_cache.Entry{
                .fingerprint = if (stable) after else null,
                .value = if (managed) .{ .excluded = try self.alloc.dupe(u8, id) } else .{ .visible = candidate.summary },
            };
            if (!managed) owned = false;
            errdefer entry.deinit(self.alloc);
            try self.entries.append(self.alloc, entry);
            if (stable or self.read.cache.contains(id)) self.read.changed.store(true, .release);
        }
    }
};

pub fn listActionableCatalog(
    store: session_store.Store,
    alloc: Allocator,
    active_id: ?[]const u8,
    cancelled: ?*std.atomic.Value(bool),
    cache_writer: ?*catalog_cache.Writer,
) !ActionableSessionCatalog {
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    var local_stop = std.atomic.Value(bool).init(false);
    const stop_requested = cancelled orelse &local_stop;
    var cached = try catalog_cache.Loaded.load(std.heap.c_allocator, store.canonical_root.sessions, stop_requested);
    defer cached.deinit(std.heap.c_allocator);
    var read = CatalogRead{ .store = store, .candidates = store.readOnlyCandidates(), .active_id = active_id, .cancelled = stop_requested, .cache = &cached };
    read.changed.store(!cached.present(), .monotonic);
    // Worker storage is independent of the caller's allocator and ends after the merge.
    const worker_alloc = std.heap.c_allocator;
    var workers: [4]CatalogWorker = undefined;
    for (&workers) |*worker| worker.* = .{ .read = &read, .alloc = worker_alloc };
    defer for (&workers) |*worker| {
        for (worker.entries.items) |*entry| entry.deinit(worker_alloc);
        worker.entries.deinit(worker_alloc);
    };
    var threads: [workers.len - 1]?std.Thread = @splat(null);
    errdefer {
        stop_requested.store(true, .release);
        for (&threads) |*handle| {
            if (handle.*) |thread| thread.join();
            handle.* = null;
        }
    }
    for (&threads, workers[1..]) |*handle, *worker| {
        handle.* = try std.Thread.spawn(.{}, CatalogWorker.run, .{worker});
    }
    workers[0].run();
    for (&threads) |*handle| {
        handle.*.?.join();
        handle.* = null;
    }
    for (workers) |worker| {
        if (worker.failure) |err| {
            if (err != error.Cancelled) return err;
        }
    }
    if (stop_requested.load(.acquire)) return error.Cancelled;
    var entries: std.ArrayList(catalog_cache.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(worker_alloc);
        entries.deinit(worker_alloc);
    }
    for (&workers) |*worker| {
        try entries.appendSlice(worker_alloc, worker.entries.items);
        worker.entries.items.len = 0;
    }
    var catalog: ActionableSessionCatalog = .{};
    errdefer catalog.deinit(alloc);
    var cacheable: usize = 0;
    for (entries.items) |entry| {
        if (stop_requested.load(.acquire)) return error.Cancelled;
        if (entry.fingerprint != null) cacheable += 1;
        switch (entry.value) {
            .visible => |summary| {
                if (active_id) |active| if (std.mem.eql(u8, active, summary.id)) continue;
                var copy = try session_summary_codec.cloneSessionSummary(alloc, summary);
                errdefer copy.deinit(alloc);
                try catalog.summaries.append(alloc, copy);
            },
            .excluded, .legacy_ranking => {},
        }
    }
    if (cache_writer) |writer| {
        if (read.changed.load(.acquire) or cacheable != cached.count()) {
            writer.save(alloc, entries.items, stop_requested) catch |err| {
                if (stop_requested.load(.acquire)) return error.Cancelled;
                @import("../shared/debug_trace.zig").logf("core", "session catalog cache not saved err={s}", .{@errorName(err)});
            };
        }
    }
    @import("../shared/debug_trace.zig").logf("core", "session catalog cache reused={d} records={d}", .{ read.reused.load(.monotonic), cacheable });
    session_summary_codec.sortSummariesNewestFirst(catalog.summaries.items);
    return catalog;
}

pub fn listVisiblePage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.SessionListPage {
    if (limit == 0) return error.InvalidSessionListLimit;
    var result = session_store.SessionListPage{};
    errdefer result.deinit(alloc);
    var position: ?ActionableContinuation = if (continuation) |value| .{
        .updated_at_ms = value.updated_at_ms,
        .id = try alloc.dupe(u8, value.id),
    } else null;
    defer if (position) |*value| value.deinit(alloc);

    while (result.summaries.items.len < limit) {
        const next = if (position) |value| value.view() else null;
        var page = try store.listSessionPage(
            alloc,
            scope,
            next,
            limit - result.summaries.items.len,
        );
        defer page.deinit(alloc);
        result.skipped_invalid +|= page.skipped_invalid;
        if (page.summaries.items.len == 0) {
            result.has_more = false;
            break;
        }
        for (page.summaries.items) |summary| {
            if (position) |*value| value.deinit(alloc);
            position = .{
                .updated_at_ms = summary.updated_at_ms,
                .id = try alloc.dupe(u8, summary.id),
            };
            if (try isVisibleSession(store, alloc, summary.id)) {
                var cloned = try session_summary_codec.cloneSessionSummary(
                    alloc,
                    summary,
                );
                result.summaries.append(alloc, cloned) catch |err| {
                    cloned.deinit(alloc);
                    return err;
                };
            }
        }
        result.has_more = page.has_more;
        if (!page.has_more) break;
    }
    return result;
}

pub fn latestVisibleWorkspaceSummary(
    store: session_store.Store,
    alloc: Allocator,
) !session_store.SessionSummary {
    var page = try listVisiblePage(
        store,
        alloc,
        .current_workspace,
        null,
        1,
    );
    defer page.deinit(alloc);
    if (page.summaries.items.len == 0) {
        if (page.skipped_invalid > 0) return error.NoReadableSessions;
        return error.NoSavedSessions;
    }
    return session_summary_codec.cloneSessionSummary(
        alloc,
        page.summaries.items[0],
    );
}

pub fn loadVisibleReadOnlyDetail(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
    options: session_store.ResumeOptions,
) !session_store.ReadOnlyDetail {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidSessionId => return err,
        else => return error.SessionNotFound,
    };
    if (managed) return error.SessionNotFound;

    var detail = try store.loadReadOnlyDetail(alloc, session_id, options);
    errdefer detail.deinit(alloc);
    if (detail.state.subagent_child) return error.SessionNotFound;
    return detail;
}

pub fn listActionablePage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    active_id: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !ActionableSessionPage {
    if (limit == 0 or limit > max_page_limit) return error.InvalidSessionListLimit;

    var result: ActionableSessionPage = .{};
    errdefer result.deinit(alloc);
    var position: ?ActionableContinuation = if (continuation) |value| .{
        .updated_at_ms = value.updated_at_ms,
        .id = try alloc.dupe(u8, value.id),
    } else null;
    defer if (position) |*value| value.deinit(alloc);

    var scanned: usize = 0;
    while (result.summaries.items.len < limit and scanned < max_page_limit) {
        var scoped = store;
        scoped.resume_page_limit = @min(
            limit - result.summaries.items.len,
            max_page_limit - scanned,
        );
        const next = if (position) |value| value.view() else null;
        var page = switch (scope) {
            .current_workspace => try scoped.listResumableWorkspacePage(
                alloc,
                active_id,
                next,
            ),
            .all_workspaces => try scoped.listResumablePage(
                alloc,
                active_id,
                next,
            ),
        };
        defer page.deinit(alloc);
        result.has_more = page.has_more;
        if (page.summaries.items.len == 0) break;

        for (page.summaries.items) |summary| {
            scanned += 1;
            if (position) |*value| value.deinit(alloc);
            position = .{
                .updated_at_ms = summary.updated_at_ms,
                .id = try alloc.dupe(u8, summary.id),
            };
            const managed = child_state.isManagedChildSession(
                store,
                alloc,
                summary.id,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => true,
            };
            if (managed) continue;
            var cloned = try session_summary_codec.cloneSessionSummary(alloc, summary);
            result.summaries.append(alloc, cloned) catch |err| {
                cloned.deinit(alloc);
                return err;
            };
        }
        if (!page.has_more) break;
    }

    if (position) |value| {
        result.continuation = value;
        position = null;
    }
    return result;
}

pub fn resumeForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    switch (target) {
        .id => |session_id| try ensureExternalMarkerAllowed(store, alloc, session_id),
        .last => {},
    }
    var loaded = try store.resumeTargetForWrite(
        alloc,
        target,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureExternalMarkerAllowed(store, alloc, loaded.active_id);
    try ensureLoadedExternalPromptAllowed(&loaded);
    return loaded;
}

fn isVisibleSession(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !bool {
    return !(child_state.isManagedChildSession(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    });
}

fn ensureExternalMarkerAllowed(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !void {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionNotFound, error.SessionStoreUnavailable => return,
        else => return err,
    };
    if (managed) return error.OneOffSessionNotResumable;
}

fn ensureLoadedExternalPromptAllowed(
    loaded: *const session_store.LoadedWritableSession,
) !void {
    if (loaded.state.subagent_child) return error.OneOffSessionNotResumable;
}

test "actionable catalog preserves discovery and child visibility" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("saved request") },
        .assistant = @constCast("saved response"),
    } }};
    for ([_][]const u8{ "public", "private-bit", "private-marker", "empty" }, 0..) |id, index| {
        const durable = session_codec.DurableSessionState{
            .id = @constCast(id),
            .origin_workspace_root = workspace,
            .workspace_root = workspace,
            .created_at_ms = 1,
            .updated_at_ms = @intCast(index + 1),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .history = if (std.mem.eql(u8, id, "empty")) &.{} else @constCast(&history),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
            .subagent_child = std.mem.eql(u8, id, "private-bit"),
        };
        var writable = try store.startWritableSession(alloc, durable);
        writable.deinit(alloc);
    }
    const children = child_state.Store{ .sessions = &store, .parent_id = "public" };
    try children.markChildSession(alloc, "private-marker");
    var stopped = std.atomic.Value(bool).init(false);
    var catalog = try listActionableCatalog(store, alloc, null, &stopped, null);
    defer catalog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), catalog.summaries.items.len);
    try std.testing.expectEqualStrings("public", catalog.summaries.items[0].id);
    var reference = try store.list(alloc);
    defer session_summary_codec.freeSummaries(alloc, &reference);
    var visible: usize = 0;
    for (reference.items) |summary| {
        if (!summary.hasResumableContent() or !try isVisibleSession(store, alloc, summary.id)) continue;
        try std.testing.expectEqualStrings(summary.id, catalog.summaries.items[visible].id);
        try std.testing.expectEqual(summary.history_len, catalog.summaries.items[visible].history_len);
        try std.testing.expectEqual(summary.updated_at_ms, catalog.summaries.items[visible].updated_at_ms);
        visible += 1;
    }
    try std.testing.expectEqual(catalog.summaries.items.len, visible);
    stopped.store(true, .release);
    try std.testing.expectError(error.Cancelled, listActionableCatalog(store, alloc, null, &stopped, null));
    const AllocationCheck = struct {
        fn run(failing_alloc: Allocator, source: session_store.Store) !void {
            var result = try listActionableCatalog(source, failing_alloc, null, null, null);
            defer result.deinit(failing_alloc);
            try std.testing.expectEqual(@as(usize, 1), result.summaries.items.len);
        }

        fn candidate(failing_alloc: Allocator, source: session_store.Store) !void {
            var result = try source.readOnlyCandidate(failing_alloc, "public", null);
            defer result.deinit(failing_alloc);
            try std.testing.expectEqualStrings("public", result.summary.id);
            try std.testing.expectEqual(@as(?bool, false), result.subagent_child);
        }
    };
    try std.testing.checkAllAllocationFailures(alloc, AllocationCheck.run, .{store});
    try std.testing.checkAllAllocationFailures(alloc, AllocationCheck.candidate, .{store});

    stopped.store(false, .release);
    var empty_cache: catalog_cache.Loaded = .{};
    var failed_read = CatalogRead{ .store = store, .candidates = store.readOnlyCandidates(), .active_id = null, .cancelled = &stopped, .cache = &empty_cache };
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var failed_worker = CatalogWorker{ .read = &failed_read, .alloc = failing.allocator() };
    defer failed_worker.entries.deinit(failing.allocator());
    failed_worker.run();
    try std.testing.expectEqual(error.OutOfMemory, failed_worker.failure.?);
    try std.testing.expect(stopped.load(.acquire));
    try std.testing.expectError(error.Cancelled, store.readOnlyCandidate(alloc, "public", &stopped));

    stopped.store(false, .release);
    var writer = (try catalog_cache.Writer.init(store)).?;
    defer writer.deinit();
    var built = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer built.deinit(alloc);
    var reused = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer reused.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), reused.summaries.items.len);
    try std.testing.expectEqualStrings(built.summaries.items[0].id, reused.summaries.items[0].id);
    {
        var changed = try store.resumeForWrite(alloc, "public");
        defer changed.deinit(alloc);
        _ = try changed.renameConversation(alloc, "Changed title");
    }
    var renamed = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer renamed.deinit(alloc);
    try std.testing.expectEqualStrings("Changed title", renamed.summaries.items[0].title.?);
    try io_mod.durableReplaceVerified(alloc, &writer.dir, ".resume-catalog", "truncated cache");
    var repaired = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer repaired.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), repaired.summaries.items.len);
    try std.testing.expectEqualStrings("Changed title", repaired.summaries.items[0].title.?);
    const new_owner = child_state.Store{ .sessions = &store, .parent_id = "parent" };
    try new_owner.markChildSession(alloc, "public");
    var hidden = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer hidden.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), hidden.summaries.items.len);
    var removed = try store.resumeForWrite(alloc, "empty");
    try std.testing.expectEqual(.discarded, store.deleteCommittedSession(alloc, &removed));
    var reconciled = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer reconciled.deinit(alloc);
    var saved = try catalog_cache.Loaded.load(alloc, writer.dir, null);
    defer saved.deinit(alloc);
    try std.testing.expect(saved.present());
    try std.testing.expect(!saved.contains("empty"));
    var read_only = try session_store.Store.initReadOnlyFromHome(alloc, home, workspace);
    defer read_only.deinit(alloc);
    try std.testing.expect((try catalog_cache.Writer.init(read_only)) == null);
}

test "managed child marker is hidden from external access" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var durable = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "child"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
    };
    defer durable.deinit(alloc);
    var writable = try store.startWritableSession(alloc, durable);
    writable.deinit(alloc);

    var visible = try loadVisibleReadOnlyDetail(store, alloc, "child", .{});
    visible.deinit(alloc);

    const state_store = child_state.Store{ .sessions = &store, .parent_id = "parent" };
    try state_store.markChildSession(alloc, "child");
    try std.testing.expectError(
        error.SessionNotFound,
        loadVisibleReadOnlyDetail(store, alloc, "child", .{}),
    );
    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        resumeForExternalPrompt(store, alloc, .{ .id = "child" }, workspace, .{}),
    );
}

test "subagent work identity hides a partial child without owner sidecar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var durable = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "partial-child"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
        .last_subagent_work_id = try alloc.dupe(u8, "work-1"),
        .subagent_child = true,
    };
    defer durable.deinit(alloc);
    var writable = try store.startWritableSession(alloc, durable);
    writable.deinit(alloc);

    try std.testing.expectError(
        error.SessionNotFound,
        loadVisibleReadOnlyDetail(store, alloc, "partial-child", .{}),
    );
    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        resumeForExternalPrompt(
            store,
            alloc,
            .{ .id = "partial-child" },
            workspace,
            .{},
        ),
    );
}

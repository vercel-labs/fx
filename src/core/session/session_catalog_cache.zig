//! The index of v1's sessions folder that earlier releases wrote, read only,
//! to list the v1 sessions not converted yet without opening each one.
//!
//! Rows are bound to stat fingerprints of each session's classification
//! inputs. A matching fingerprint reuses the row without opening the session;
//! a mismatch reclassifies that one directory through canonical discovery.
//! A missing, corrupt, or older-version index is ignored, and every session
//! is classified from its directory, which remains the only authority.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const child_state = @import("../subagent/child_state.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_discovery = @import("session_discovery.zig");
const session_layout = @import("session_layout.zig");
const session_store = @import("session_store.zig");
const summary_codec = @import("session_summary_codec.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const magic = "fx-resume-catalog-v6\n";
const file_name = ".resume-catalog";
const max_bytes = 64 * 1024 * 1024;
const max_records = 100_000;
const Fingerprint = [Sha256.digest_length]u8;

const Entry = struct {
    value: union(enum) { visible: session_store.SessionSummary, excluded: []u8 },

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.value) {
            .visible => |*summary| summary.deinit(alloc),
            .excluded => |name| alloc.free(name),
        }
        self.* = undefined;
    }
};

const Summary = struct {
    workspace_root: ?[]const u8,
    origin_workspace_root: ?[]const u8,
    title: ?[]const u8,
    preview: ?[]const u8,
    display_metadata_present: bool,
    created_at_ms: i64,
    updated_at_ms: i64,
    history_len: u64,
    language: []const u8,
    has_checkpoint: bool,
    has_managed_children: bool,

    /// The row contract `decodeRows` enforces: one row outside it rejects
    /// the whole file.
    fn persistable(self: Summary) bool {
        if (self.created_at_ms < 0 or self.updated_at_ms < self.created_at_ms) return false;
        if (!std.unicode.utf8ValidateSlice(self.language)) return false;
        _ = session.ConversationLanguage.fromSlice(self.language) catch return false;
        if (std.math.cast(usize, self.history_len) == null) return false;
        for ([_]?[]const u8{ self.workspace_root, self.origin_workspace_root, self.title, self.preview }) |optional| {
            if (optional) |value| if (!std.unicode.utf8ValidateSlice(value)) return false;
        }
        if (self.title) |title| {
            if (title.len > session_codec.max_session_title_bytes) return false;
        }
        for ([_]?[]const u8{ self.workspace_root, self.origin_workspace_root }) |root| {
            const path = root orelse continue;
            if (!std.Io.Dir.path.isAbsolute(path) or path.len > std.Io.Dir.max_path_bytes) return false;
        }
        return true;
    }

    fn clone(self: Summary, alloc: Allocator, id: []const u8) !session_store.SessionSummary {
        return summary_codec.cloneSessionSummary(alloc, .{
            .id = @constCast(id),
            .workspace_root = if (self.workspace_root) |value| @constCast(value) else null,
            .origin_workspace_root = if (self.origin_workspace_root) |value| @constCast(value) else null,
            .title = if (self.title) |value| @constCast(value) else null,
            .preview = if (self.preview) |value| @constCast(value) else null,
            .display_metadata_present = self.display_metadata_present,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .history_len = std.math.cast(usize, self.history_len) orelse return error.InvalidCatalogCache,
            .conversation_language = try session.ConversationLanguage.fromSlice(self.language),
            .has_checkpoint = self.has_checkpoint,
            .has_managed_children = self.has_managed_children,
        });
    }
};

const Row = struct {
    id: []const u8,
    fingerprint: Fingerprint,
    value: union(enum) {
        visible: Summary,
        excluded: void,
    },
};

/// Owns parsed cache bytes. Reused entries are separately owned by the caller.
const Loaded = struct {
    bytes: ?[]u8 = null,
    parsed: ?[]Row = null,
    index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        self.index.deinit(alloc);
        if (self.parsed) |rows| alloc.free(rows);
        if (self.bytes) |bytes| alloc.free(bytes);
        self.* = .{};
    }

    pub fn load(alloc: Allocator, dir: ?io_mod.VerifiedDir) !Loaded {
        const root = dir orelse return .{};
        return loadChecked(alloc, root.dir) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => .{},
            else => blk: {
                debug_trace.logf("core", "session catalog cache ignored err={s}", .{@errorName(err)});
                break :blk .{};
            },
        };
    }

    fn loadChecked(alloc: Allocator, dir: std.Io.Dir) !Loaded {
        // Opening a FIFO or device for reading can block, so the helper checks
        // the entry and opens it without blocking before any read.
        var file = try io_mod.openExistingRegularFile(dir, file_name, .read_only);
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink > 1 or (stat.permissions.toMode() & 0o077) != 0 or stat.size > max_bytes) return error.InvalidCatalogCache;
        const bytes = try alloc.alloc(u8, @intCast(stat.size));
        errdefer alloc.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + 64 * 1024);
            const read = try file.readPositionalAll(io_mod.getIo(), bytes[offset..end], offset);
            if (read != end - offset) return error.InvalidCatalogCache;
            offset = end;
        }
        if (bytes.len < magic.len + Sha256.digest_length + @sizeOf(u32) or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidCatalogCache;
        const payload = bytes[magic.len + Sha256.digest_length ..];
        var digest: Fingerprint = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..Sha256.digest_length])) return error.InvalidCatalogCache;
        const rows = try decodeRows(alloc, payload);
        errdefer alloc.free(rows);
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer index.deinit(alloc);
        try index.ensureTotalCapacity(alloc, @intCast(rows.len));
        for (rows, 0..) |row, i| {
            const entry = index.getOrPutAssumeCapacity(row.id);
            if (entry.found_existing) return error.InvalidCatalogCache;
            entry.value_ptr.* = i;
        }
        return .{ .bytes = bytes, .parsed = rows, .index = index };
    }

    fn reuse(self: *const Loaded, alloc: Allocator, id: []const u8, fingerprint_value: Fingerprint) !?Entry {
        const position = self.index.get(id) orelse return null;
        const row = self.parsed.?[position];
        if (!matches(row, fingerprint_value)) return null;
        return try cloneRow(alloc, row);
    }

    fn matches(row: Row, value: Fingerprint) bool {
        return std.mem.eql(u8, &row.fingerprint, &value);
    }

    fn cloneRow(alloc: Allocator, row: Row) !Entry {
        return .{ .value = switch (row.value) {
            .visible => |summary| .{ .visible = try summary.clone(alloc, row.id) },
            .excluded => .{ .excluded = try alloc.dupe(u8, row.id) },
        } };
    }
};

fn decodeRows(alloc: Allocator, payload: []const u8) ![]Row {
    var cursor = ByteCursor{ .bytes = payload };
    const count = try cursor.readInt(u32);
    if (count > max_records) return error.InvalidCatalogCache;
    const rows = try alloc.alloc(Row, count);
    errdefer alloc.free(rows);
    for (rows) |*row| {
        const id = try cursor.readString();
        session_layout.validateSessionId(id) catch return error.InvalidCatalogCache;
        const raw_fingerprint = try cursor.take(@sizeOf(Fingerprint));
        const fingerprint_value: Fingerprint = raw_fingerprint[0..@sizeOf(Fingerprint)].*;
        const value: @FieldType(Row, "value") = switch (try cursor.readByte()) {
            0 => .excluded,
            1 => visible: {
                const flags = try cursor.readByte();
                if (flags & ~@as(u8, 0b111) != 0) return error.InvalidCatalogCache;
                const summary = Summary{
                    .display_metadata_present = flags & (1 << 0) != 0,
                    .has_checkpoint = flags & (1 << 1) != 0,
                    .has_managed_children = flags & (1 << 2) != 0,
                    .created_at_ms = try cursor.readInt(i64),
                    .updated_at_ms = try cursor.readInt(i64),
                    .history_len = try cursor.readInt(u64),
                    .workspace_root = try cursor.readOptionalString(),
                    .origin_workspace_root = try cursor.readOptionalString(),
                    .title = try cursor.readOptionalString(),
                    .preview = try cursor.readOptionalString(),
                    .language = try cursor.readString(),
                };
                if (!summary.persistable()) return error.InvalidCatalogCache;
                break :visible .{ .visible = summary };
            },
            else => return error.InvalidCatalogCache,
        };
        row.* = .{ .id = id, .fingerprint = fingerprint_value, .value = value };
    }
    if (!cursor.done()) return error.InvalidCatalogCache;
    return rows;
}

const ByteCursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *ByteCursor, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.offset, len) catch
            return error.InvalidCatalogCache;
        if (end > self.bytes.len) return error.InvalidCatalogCache;
        const result = self.bytes[self.offset..end];
        self.offset = end;
        return result;
    }

    fn readByte(self: *ByteCursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readInt(self: *ByteCursor, comptime T: type) !T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn readString(self: *ByteCursor) ![]const u8 {
        return self.take(try self.readInt(u32));
    }

    fn readOptionalString(self: *ByteCursor) !?[]const u8 {
        const len = try self.readInt(u32);
        if (len == std.math.maxInt(u32)) return null;
        return @as(?[]const u8, try self.take(len));
    }

    fn done(self: ByteCursor) bool {
        return self.offset == self.bytes.len;
    }
};

/// Stats are freshness evidence only. Cache misses still use canonical discovery and admission.
fn fingerprint(dir: std.Io.Dir, id: []const u8) !?Fingerprint {
    try session_layout.validateSessionId(id);
    const before = (try statOptional(dir, id)) orelse return null;
    if (before.kind != .directory) return null;
    var digest = Sha256.init(.{});
    addStat(&digest, before);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Classification observes each of these files, and its result depends on
    // whether each is present: a legacy session carries no event log, and a
    // schema_v3 session whose manifest is lost is listed from its log. Their
    // presence, absence, or replacement must invalidate a cached row, so bind
    // them into the digest.
    for ([_][]const u8{ "session.json", "events.jsonl", "authority.json", "authority.pending.json", "display.json" }) |name| {
        const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ id, name });
        if (try statOptional(dir, path)) |stat| {
            if (stat.kind != .file or stat.nlink != 1) return null;
            digest.update(&.{1});
            addStat(&digest, stat);
        } else digest.update(&.{0});
    }
    const child_path = try std.mem.print(&path_buffer, "{s}/subagent", .{id});
    const child = try statOptional(dir, child_path);
    if (child) |stat| {
        if (stat.kind != .directory) return null;
        digest.update(&.{1});
        addStat(&digest, stat);
        for ([_][]const u8{ "owner.json", "control.json" }) |name| {
            const path = try std.mem.print(&path_buffer, "{s}/subagent/{s}", .{ id, name });
            if (try statOptional(dir, path)) |marker| {
                if (marker.kind != .file or marker.nlink != 1) return null;
                digest.update(&.{1});
                addStat(&digest, marker);
            } else digest.update(&.{0});
        }
    } else digest.update(&.{0});
    const after = (try statOptional(dir, id)) orelse return null;
    if (!sameStat(before, after)) return null;
    var value: Fingerprint = undefined;
    digest.final(&value);
    return value;
}

fn statOptional(dir: std.Io.Dir, path: []const u8) !?std.Io.File.Stat {
    return dir.statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => err,
    };
}

fn sameStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.nlink == b.nlink and a.kind == b.kind and a.size == b.size and
        a.permissions.toMode() == b.permissions.toMode() and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn addStat(hash: *Sha256, stat: std.Io.File.Stat) void {
    const values = [_]u128{ stat.inode, stat.nlink, stat.size, @backingInt(stat.kind), stat.permissions.toMode(), @bitCast(@as(i128, stat.mtime.nanoseconds)), @bitCast(@as(i128, stat.ctime.nanoseconds)) };
    var bytes: [16]u8 = undefined;
    for (values) |value| {
        std.mem.writeInt(u128, &bytes, value, .little);
        hash.update(&bytes);
    }
}

/// Every listable session in newest-first order, plus the number of session
/// directories that could not be classified during this refresh.
pub const ActionableSessionCatalog = struct {
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    skipped_invalid: usize = 0,
    /// Owned ids of the sessions counted in `skipped_invalid`, which v2's
    /// listing still shows until they are converted or refused (D59).
    invalid_ids: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ActionableSessionCatalog, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        for (self.invalid_ids.items) |id| alloc.free(id);
        self.invalid_ids.deinit(alloc);
        self.* = undefined;
    }
};

const CatalogRead = struct {
    store: session_store.Store,
    candidates: session_store.CandidateIterator,
    iterator_mutex: std.Io.Mutex = .init,
    active_id: ?[]const u8,
    cancelled: *std.atomic.Value(bool),
    cache: *const Loaded,
    reused: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    skipped_invalid: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn nextId(self: *CatalogRead, alloc: Allocator) !?[]u8 {
        self.iterator_mutex.lockUncancelable(io_mod.getIo());
        defer self.iterator_mutex.unlock(io_mod.getIo());
        return self.candidates.nextId(alloc, self.cancelled);
    }
};

const CatalogWorker = struct {
    read: *CatalogRead,
    alloc: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Owned ids this worker counted in `skipped_invalid`.
    invalid: std.ArrayList([]u8) = .empty,
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
            const before = fingerprint(dir.dir, id) catch null;
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
                else => fallback: {
                    // A legacy upgrade interrupted mid-rename stays listed from
                    // its stable snapshot; opening it refuses it and keeps it
                    // for `fx session recover` (D70).
                    if (self.read.store.readOnlyFencedLegacyCandidate(self.alloc, id, self.read.cancelled)) |value|
                        break :fallback value
                    else |fallback_err| switch (fallback_err) {
                        error.OutOfMemory, error.Cancelled => return fallback_err,
                        else => {},
                    }
                    session_discovery.logDiscoveryError(.read_only_list, id, null, null, err);
                    _ = self.read.skipped_invalid.fetchAdd(1, .monotonic);
                    try self.invalid.ensureUnusedCapacity(self.alloc, 1);
                    self.invalid.appendAssumeCapacity(try self.alloc.dupe(u8, id));
                    continue;
                },
            };
            var owned = true;
            defer if (owned) candidate.deinit(self.alloc);
            const is_active = if (self.read.active_id) |active| std.mem.eql(u8, id, active) else false;
            if (is_active and !candidate.summary.hasResumableContent()) continue;
            if (self.read.cancelled.load(.acquire)) return error.Cancelled;
            // Empty sessions stay listed; the picker alone hides rows without
            // resumable content.
            const managed = child_state.isDiscoveredManagedChildSession(self.read.store, self.alloc, candidate.summary.id, candidate.subagent_child) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // An unverifiable marker or first event stays listed, as
                // `fx sessions` always did; exact resume still refuses a real
                // child.
                else => false,
            };
            var entry = Entry{ .value = if (managed) .{ .excluded = try self.alloc.dupe(u8, id) } else .{ .visible = candidate.summary } };
            if (!managed) owned = false;
            errdefer entry.deinit(self.alloc);
            try self.entries.append(self.alloc, entry);
        }
    }
};

/// Every listable v1 session, newest first, `active_id` left out. Rows whose
/// fingerprints still match the index are reused without opening their
/// sessions; the rest are classified by canonical discovery. The index is
/// never written. Caller owns the returned catalog.
pub fn listActionableCatalog(
    store: session_store.Store,
    alloc: Allocator,
    active_id: ?[]const u8,
) !ActionableSessionCatalog {
    // A worker that fails stops the others.
    var stop = std.atomic.Value(bool).init(false);
    const stop_requested = &stop;
    var cached = try Loaded.load(std.heap.c_allocator, store.canonical_root.sessions);
    defer cached.deinit(std.heap.c_allocator);
    var read = CatalogRead{ .store = store, .candidates = store.readOnlyCandidates(), .active_id = active_id, .cancelled = stop_requested, .cache = &cached };
    // Worker storage is independent of the caller's allocator and ends after the merge.
    const worker_alloc = std.heap.c_allocator;
    var workers: [4]CatalogWorker = undefined;
    for (&workers) |*worker| worker.* = .{ .read = &read, .alloc = worker_alloc };
    defer for (&workers) |*worker| {
        for (worker.entries.items) |*entry| entry.deinit(worker_alloc);
        worker.entries.deinit(worker_alloc);
        for (worker.invalid.items) |id| worker_alloc.free(id);
        worker.invalid.deinit(worker_alloc);
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
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(worker_alloc);
        entries.deinit(worker_alloc);
    }
    for (&workers) |*worker| {
        try entries.appendSlice(worker_alloc, worker.entries.items);
        worker.entries.items.len = 0;
    }
    var catalog: ActionableSessionCatalog = .{ .skipped_invalid = read.skipped_invalid.load(.monotonic) };
    errdefer catalog.deinit(alloc);
    for (workers) |worker| for (worker.invalid.items) |id| {
        if (active_id) |active| if (std.mem.eql(u8, active, id)) continue;
        try catalog.invalid_ids.ensureUnusedCapacity(alloc, 1);
        catalog.invalid_ids.appendAssumeCapacity(try alloc.dupe(u8, id));
    };
    for (entries.items) |entry| {
        switch (entry.value) {
            .visible => |summary| {
                if (active_id) |active| if (std.mem.eql(u8, active, summary.id)) continue;
                var copy = try summary_codec.cloneSessionSummary(alloc, summary);
                errdefer copy.deinit(alloc);
                try catalog.summaries.append(alloc, copy);
            },
            .excluded => {},
        }
    }
    debug_trace.logf("core", "session catalog cache reused={d} skipped_invalid={d}", .{ read.reused.load(.monotonic), catalog.skipped_invalid });
    summary_codec.sortSummariesNewestFirst(catalog.summaries.items);
    return catalog;
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "catalog cache ignores a FIFO without blocking" {
    if (comptime @import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "{s}/{s}", .{ root, file_name }, 0);
    if (mkfifo(path, 0o600) != 0) return error.SkipZigTest;
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    // Reading a FIFO waits for a writer that never comes; the index is ignored.
    var loaded = try Loaded.load(alloc, dir);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.parsed == null);
}

test "catalog rows reject a v5 JSON payload relabelled v6" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    const payload = "[{\"id\":\"legacy\",\"fingerprint\":\"" ++ text_utils.repeat("1", 64) ++ "\",\"value\":{\"legacy_ranking\":{\"workspace_root\":\"/workspace\",\"updated_at_ms\":20}}}]";
    var digest: Fingerprint = undefined;
    Sha256.hash(payload, &digest, .{});
    var bytes: std.Io.Writer.Allocating = .init(alloc);
    defer bytes.deinit();
    try bytes.writer.writeAll(magic);
    try bytes.writer.writeAll(&digest);
    try bytes.writer.writeAll(payload);
    try io_mod.durableReplaceVerified(alloc, &dir, file_name, bytes.written());
    var loaded = try Loaded.load(alloc, dir);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.parsed == null);
}

test "catalog fingerprint binds authority fence display sidecar and missing event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "session");
    {
        var file = try tmp.dir.createFile(std.testing.io, "session/session.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    // Legacy sessions carry no event log; the fingerprint must still exist.
    const legacy = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expectEqual(legacy, (try fingerprint(tmp.dir, "session")).?);
    // A later appearance of events.jsonl invalidates the legacy observation.
    {
        var file = try tmp.dir.createFile(std.testing.io, "session/events.jsonl", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    const with_events = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &legacy, &with_events));
    // Adding or removing the authority marker, fence, or display sidecar must
    // invalidate the observation even when session.json and events.jsonl are
    // untouched.
    for ([_][]const u8{ "authority.json", "authority.pending.json", "display.json" }) |name| {
        const path = try std.testing.allocator.print("session/{s}", .{name});
        defer std.testing.allocator.free(path);
        const absent = (try fingerprint(tmp.dir, "session")).?;
        var file = try tmp.dir.createFile(std.testing.io, path, .{});
        try file.writeStreamingAll(std.testing.io, "{}\n");
        file.close(std.testing.io);
        const present = (try fingerprint(tmp.dir, "session")).?;
        try std.testing.expect(!std.mem.eql(u8, &absent, &present));
        try tmp.dir.deleteFile(std.testing.io, path);
    }
}

test "catalog fingerprint detects event appends and child directory permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "session/subagent");
    for ([_][]const u8{ "session/session.json", "session/events.jsonl" }) |path| {
        var file = try tmp.dir.createFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    const first = (try fingerprint(tmp.dir, "session")).?;
    var events = try tmp.dir.openFile(std.testing.io, "session/events.jsonl", .{ .mode = .read_write });
    defer events.close(std.testing.io);
    try events.writePositionalAll(std.testing.io, "more\n", 3);
    const appended = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &first, &appended));
    var child = try tmp.dir.openDir(std.testing.io, "session/subagent", .{ .iterate = true });
    defer child.close(std.testing.io);
    try child.setPermissions(std.testing.io, .fromMode(0o700));
    const private = (try fingerprint(tmp.dir, "session")).?;
    try child.setPermissions(std.testing.io, .fromMode(0o755));
    const changed = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &private, &changed));
}

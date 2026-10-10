//! L3: the catalog, `index.jsonl`.
//!
//! The index is derived and rebuildable. It holds one checksummed line per
//! change: `put` (a session's summary), `opened` (a host opened it) and
//! `del` (a tombstone), appended under `index.lock` and never fsynced.
//! Folding it keeps the newest record per id; a tombstone is final, so a
//! deleted id never comes back (`tla/Catalog.tla` `NoResurrection`).
//! `list` reads only the index and self-heals entries whose folder is gone;
//! `rebuild` re-derives it from the folders and sweeps `.tmp` and `.trash`.
//!
//! Pure core: `encodeRecord`, `decodeRecord` and `Index.fold`.

const std = @import("std");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const log_mod = @import("log.zig");
const session_mod = @import("session.zig");
const diag = @import("diag.zig");

const index_name = "index.jsonl";
const index_tmp_name = "index.jsonl.tmp";
const lock_name = "index.lock";

/// A `.tmp` entry younger than this may be a publish in progress.
const sweep_after_ms: i64 = 60 * 60 * 1000;

pub const host_count = @typeInfo(schema.Host).@"enum".fields.len;

pub const Summary = struct {
    id: []const u8,
    role: schema.Role,
    /// The host that created the session.
    host: schema.Host,
    /// The workspace in effect.
    workspace: []const u8,
    /// Raw JSON string, as set.
    title: ?[]const u8 = null,
    /// Raw JSON string, as set (D18).
    language: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    created_ms: u64,
    updated_ms: u64,
    /// Turns that ended, committed or interrupted.
    turns: u64,
    /// When each host last opened the session; 0 means never.
    opened_ms: [host_count]u64 = @splat(0),
};

pub const Record = union(enum) {
    put: Summary,
    /// Read from indexes that older builds wrote; a resume now writes a
    /// whole `put` (D42).
    opened: struct { id: []const u8, host: schema.Host, ts_ms: u64 },
    del: struct { id: []const u8, ts_ms: u64 },
};

// ---------------------------------------------------------------------------
// Pure core

/// Appends one framed index line.
pub fn encodeRecord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), record: Record) log_mod.FrameError!void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    switch (record) {
        .put => |p| {
            try payload.appendSlice(gpa, "{\"op\":\"put\",\"id\":");
            try schema.appendJsonString(gpa, &payload, p.id);
            try payload.print(gpa, ",\"role\":\"{s}\",\"host\":\"{s}\",\"workspace\":", .{ @tagName(p.role), @tagName(p.host) });
            try schema.appendJsonString(gpa, &payload, p.workspace);
            if (p.title) |title| {
                try payload.appendSlice(gpa, ",\"title\":");
                try payload.appendSlice(gpa, title);
            }
            if (p.language) |language| {
                try payload.appendSlice(gpa, ",\"language\":");
                try payload.appendSlice(gpa, language);
            }
            if (p.parent) |parent| {
                try payload.appendSlice(gpa, ",\"parent\":");
                try schema.appendJsonString(gpa, &payload, parent);
            }
            try payload.print(gpa, ",\"created\":{d},\"updated\":{d},\"turns\":{d},\"opened\":[", .{ p.created_ms, p.updated_ms, p.turns });
            for (p.opened_ms, 0..) |ts, i| {
                if (i > 0) try payload.append(gpa, ',');
                try payload.print(gpa, "{d}", .{ts});
            }
            try payload.append(gpa, ']');
        },
        .opened => |o| {
            try payload.appendSlice(gpa, "{\"op\":\"opened\",\"id\":");
            try schema.appendJsonString(gpa, &payload, o.id);
            try payload.print(gpa, ",\"host\":\"{s}\",\"ts\":{d}", .{ @tagName(o.host), o.ts_ms });
        },
        .del => |d| {
            try payload.appendSlice(gpa, "{\"op\":\"del\",\"id\":");
            try schema.appendJsonString(gpa, &payload, d.id);
            try payload.print(gpa, ",\"ts\":{d}", .{d.ts_ms});
        },
    }
    try log_mod.appendFramed(gpa, out, payload.items);
}

/// Parses one index line, newline included. Null for a line that fails
/// its checksum or does not parse.
pub fn decodeRecord(arena: std.mem.Allocator, line: []const u8) error{OutOfMemory}!?Record {
    const payload = log_mod.checkFrame(line) catch return null;
    const object = try std.mem.concat(arena, u8, &.{ payload, "}" });
    const f = schema.Fields.parseObject(arena, object) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadBody => null,
    };
    const op = f.req([]const u8, "op") catch return null;
    const id = f.req([]const u8, "id") catch return null;
    if (std.mem.eql(u8, op, "put")) {
        var summary: Summary = .{
            .id = id,
            .role = f.req(schema.Role, "role") catch return null,
            .host = f.req(schema.Host, "host") catch return null,
            .workspace = f.req([]const u8, "workspace") catch return null,
            .title = f.raw("title"),
            .language = f.raw("language"),
            .parent = f.opt([]const u8, "parent") catch return null,
            .created_ms = f.req(u64, "created") catch return null,
            .updated_ms = f.req(u64, "updated") catch return null,
            .turns = f.req(u64, "turns") catch return null,
        };
        const opened = f.raw("opened") orelse return null;
        summary.opened_ms = plainTimes(opened) orelse blk: {
            const times = f.req([]const u64, "opened") catch return null;
            if (times.len != host_count) return null;
            break :blk times[0..host_count].*;
        };
        return .{ .put = summary };
    }
    if (std.mem.eql(u8, op, "opened")) {
        return .{ .opened = .{
            .id = id,
            .host = f.req(schema.Host, "host") catch return null,
            .ts_ms = f.req(u64, "ts") catch return null,
        } };
    }
    if (std.mem.eql(u8, op, "del")) {
        return .{ .del = .{ .id = id, .ts_ms = f.req(u64, "ts") catch return null } };
    }
    return null;
}

/// Pure: `opened` as `encodeRecord` writes it, `[t,t,...]` with one plain
/// unsigned number per host, read without a second JSON parse. Null for
/// anything else, which that parse then decides, so results never differ.
fn plainTimes(raw: []const u8) ?[host_count]u64 {
    if (raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') return null;
    var times: [host_count]u64 = undefined;
    var it = std.mem.splitScalar(u8, raw[1 .. raw.len - 1], ',');
    for (&times) |*time| {
        const digits = it.next() orelse return null;
        if (digits.len == 0 or digits.len > 19 or (digits.len > 1 and digits[0] == '0')) return null;
        for (digits) |c| if (c < '0' or c > '9') return null;
        time.* = std.fmt.parseInt(u64, digits, 10) catch return null;
    }
    return if (it.next() == null) times else null;
}

pub const Entry = struct {
    summary: Summary,
    deleted: bool,
};

/// The folded index: the newest summary per id, and every tombstone.
/// Owns everything through its arena.
pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Lines that failed their checksum or did not parse.
    damaged_lines: u64 = 0,
    /// Lines folded.
    lines: u64 = 0,

    pub fn deinit(index: *Index) void {
        index.arena.deinit();
    }

    /// Pure: about how large the index is with one line per id, from the
    /// `folded_bytes` it was folded from and the share of its lines that
    /// are still the newest of their id.
    pub fn liveBytes(index: *const Index, folded_bytes: usize) usize {
        if (index.lines == 0) return 0;
        // At most `folded_bytes`, so the cast holds.
        return @intCast(@as(u128, folded_bytes) * @min(index.entries.count(), index.lines) / index.lines);
    }

    /// Pure: folds index bytes. A bad line is counted and skipped; a torn
    /// final line is ignored.
    pub fn fold(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Index {
        var index: Index = .{ .arena = .init(gpa) };
        errdefer index.deinit();
        const arena = index.arena.allocator();
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, bytes, at, '\n')) |nl| : (at = nl + 1) {
            const record = (try decodeRecord(arena, bytes[at .. nl + 1])) orelse {
                index.damaged_lines += 1;
                continue;
            };
            index.lines += 1;
            try index.apply(record);
        }
        return index;
    }

    pub fn apply(index: *Index, record: Record) error{OutOfMemory}!void {
        const arena = index.arena.allocator();
        switch (record) {
            .put => |summary| {
                const slot = try index.entries.getOrPut(arena, summary.id);
                if (slot.found_existing) {
                    // A tombstone is final.
                    if (slot.value_ptr.deleted) return;
                    var merged = summary;
                    for (&merged.opened_ms, slot.value_ptr.summary.opened_ms) |*ts, old| ts.* = @max(ts.*, old);
                    slot.value_ptr.summary = merged;
                } else {
                    slot.value_ptr.* = .{ .summary = summary, .deleted = false };
                }
            },
            .opened => |o| if (index.entries.getPtr(o.id)) |entry| {
                const i = @intFromEnum(o.host);
                entry.summary.opened_ms[i] = @max(entry.summary.opened_ms[i], o.ts_ms);
            },
            .del => |d| {
                const slot = try index.entries.getOrPut(arena, d.id);
                if (!slot.found_existing) {
                    slot.value_ptr.summary = .{ .id = d.id, .role = .root, .host = .app, .workspace = "", .created_ms = d.ts_ms, .updated_ms = d.ts_ms, .turns = 0 };
                }
                slot.value_ptr.deleted = true;
            },
        }
    }

    pub fn isDeleted(index: *const Index, id: []const u8) bool {
        const entry = index.entries.get(id) orelse return false;
        return entry.deleted;
    }
};

// ---------------------------------------------------------------------------
// Effectful shell

pub const Error = error{ Busy, OutOfMemory } || storage.IoFault;

pub const Filter = union(enum) { all, workspace: []const u8 };

/// Where the next page of `list` starts.
pub const Cursor = struct {
    updated_ms: u64,
    id_buffer: [255]u8 = undefined,
    id_len: usize = 0,

    pub fn id(c: *const Cursor) []const u8 {
        return c.id_buffer[0..c.id_len];
    }
};

pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    /// Newest first.
    items: []Summary,
    next: ?Cursor,

    pub fn deinit(page: *Page) void {
        page.arena.deinit();
    }
};

pub const Target = union(enum) {
    /// The newest updated root session in the workspace, from any host.
    last,
    /// The root session this host opened last in the workspace (`-c`).
    last_opened: schema.Host,
};

pub const Rebuilt = struct { sessions: u64, swept: u64 };

/// `index.lock`, opened once and kept for the manager's life (it is never
/// renamed or removed). The flock excludes other processes; `mutex`
/// excludes this process's threads, which share one open file and so one
/// flock. A crash drops both, as before.
pub const IndexLock = struct {
    mutex: std.Io.Mutex = .init,
    file: ?storage.File = null,
    /// An append folds the index to see whether to rewrite it only once it
    /// is twice this: its size with one line per id as this manager last
    /// folded or rewrote it, or its whole size when that fold found it too
    /// live to rewrite; 0 until then. So each fold is paid for by as many
    /// appended bytes.
    baseline_bytes: std.atomic.Value(usize) = .init(0),

    pub fn close(lock: *IndexLock, s: storage.Storage) void {
        if (lock.file) |file| s.closeFile(file);
        lock.file = null;
    }
};

pub const Catalog = struct {
    env: *const session_mod.Env,
    lock: *IndexLock,

    pub fn put(cat: Catalog, summary: Summary) Error!void {
        try cat.append(.{ .put = summary });
        cat.env.observeCatalog(summary.id, .index_put);
    }

    pub fn del(cat: Catalog, id: []const u8, ts_ms: u64) Error!void {
        try cat.append(.{ .del = .{ .id = id, .ts_ms = ts_ms } });
        cat.env.observeCatalog(id, .index_del);
    }

    /// Reads and folds the index without its lock. The file only grows,
    /// or is replaced whole by a rename, so a reader always sees a prefix
    /// of whole lines plus at most one torn line, which the fold ignores.
    /// Damaged lines are dropped by rewriting the index, reported once.
    pub fn load(cat: Catalog, gpa: std.mem.Allocator) Error!Index {
        const bytes = try cat.readIndex(gpa);
        defer gpa.free(bytes);
        var index = try Index.fold(gpa, bytes);
        errdefer index.deinit();
        cat.lock.baseline_bytes.store(index.liveBytes(bytes.len), .monotonic);
        if (index.damaged_lines > 0) {
            const lock = try cat.acquireIndexLock();
            defer cat.releaseIndexLock(lock);
            try cat.writeFresh(&index);
            diag.report(cat.env.diagnostics, .{ .kind = .index_healed, .session_id = "", .count = index.damaged_lines });
            index.damaged_lines = 0;
        }
        return index;
    }

    /// Root sessions, newest updated first, `limit` per page. Entries whose
    /// folder is gone are tombstoned and skipped (self-heal).
    pub fn list(cat: Catalog, gpa: std.mem.Allocator, filter: Filter, cursor: ?Cursor, limit: usize) Error!Page {
        var index = try cat.load(gpa);
        defer index.deinit();
        var page: Page = .{ .arena = .init(gpa), .items = &.{}, .next = null };
        errdefer page.deinit();
        const arena = page.arena.allocator();
        const candidates = try sorted(arena, &index, filter, cursor);
        var items: std.ArrayList(Summary) = .empty;
        var i: usize = 0;
        while (i < candidates.len and items.items.len < limit) : (i += 1) {
            if (!try cat.healIfGone(candidates[i].id)) continue;
            try items.append(arena, try copySummary(arena, candidates[i].*));
        }
        if (i < candidates.len and items.items.len == limit) {
            const last = items.items[items.items.len - 1];
            var next: Cursor = .{ .updated_ms = last.updated_ms, .id_len = last.id.len };
            @memcpy(next.id_buffer[0..last.id.len], last.id);
            page.next = next;
        }
        page.items = items.items;
        return page;
    }

    /// Resolves `.last` or `.last_opened{host}` to an id the caller owns.
    pub fn resolve(cat: Catalog, gpa: std.mem.Allocator, workspace: []const u8, target: Target) Error!?[]u8 {
        var index = try cat.load(gpa);
        defer index.deinit();
        while (true) {
            var best: ?*const Summary = null;
            var best_key: u64 = 0;
            var it = index.entries.iterator();
            while (it.next()) |kv| {
                const entry = kv.value_ptr;
                if (entry.deleted or entry.summary.role != .root) continue;
                if (!std.mem.eql(u8, entry.summary.workspace, workspace)) continue;
                const key = switch (target) {
                    .last => entry.summary.updated_ms,
                    .last_opened => |host| entry.summary.opened_ms[@intFromEnum(host)],
                };
                if (key == 0 and target == .last_opened) continue;
                // A tie resolves as `list` sorts: the smaller id first (D11).
                const better = best == null or key > best_key or
                    (key == best_key and std.mem.lessThan(u8, entry.summary.id, best.?.id));
                if (better) {
                    best = &entry.summary;
                    best_key = key;
                }
            }
            const found = best orelse return null;
            if (try cat.healIfGone(found.id)) return try gpa.dupe(u8, found.id);
            // Gone: its tombstone is in the file now; forget it here too.
            index.entries.getPtr(found.id).?.deleted = true;
        }
    }

    pub fn isDeleted(cat: Catalog, gpa: std.mem.Allocator, id: []const u8) Error!bool {
        var index = try cat.load(gpa);
        defer index.deinit();
        return index.isDeleted(id);
    }

    /// Re-derives the index from the session folders under `index.lock`,
    /// keeping tombstones and each host's open times from the old index,
    /// then sweeps `.trash` and old `.tmp` entries.
    pub fn rebuild(cat: Catalog, gpa: std.mem.Allocator) Error!Rebuilt {
        const env = cat.env;
        const s = env.s;
        const lock = try cat.acquireIndexLock();
        defer cat.releaseIndexLock(lock);
        const old_bytes = try cat.readIndex(gpa);
        defer gpa.free(old_bytes);
        var old = try Index.fold(gpa, old_bytes);
        defer old.deinit();

        var fresh: Index = .{ .arena = .init(gpa) };
        defer fresh.deinit();
        const arena = fresh.arena.allocator();
        var sessions: u64 = 0;
        var listing = s.list(env.root);
        while (listing.next() catch |io_err| return storage.ioFault(io_err)) |entry| {
            if (entry.kind != .directory or !schema.validId(entry.name)) continue;
            const id = try arena.dupe(u8, entry.name);
            var summary = session_mod.readSummary(env, id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Damaged or unreadable: listed by id so it can be recovered.
                else => {
                    try fresh.apply(.{ .put = .{ .id = id, .role = .root, .host = .app, .workspace = "", .created_ms = 0, .updated_ms = 0, .turns = 0 } });
                    sessions += 1;
                    continue;
                },
            };
            defer summary.deinit(gpa);
            var derived = try summaryFrom(arena, &summary);
            if (old.entries.get(id)) |known| derived.opened_ms = known.summary.opened_ms;
            if (old.isDeleted(id)) continue;
            try fresh.apply(.{ .put = derived });
            sessions += 1;
        }
        if (env.isPlanted(.rebuild_resurrects)) try cat.plantedResurrect(&fresh);
        var it = old.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.deleted) try fresh.apply(.{ .del = .{ .id = try arena.dupe(u8, kv.key_ptr.*), .ts_ms = kv.value_ptr.summary.updated_ms } });
        }
        try cat.writeFresh(&fresh);
        const swept = try cat.sweep();
        if (swept > 0) diag.report(env.diagnostics, .{ .kind = .rebuild_swept, .session_id = "", .count = swept });
        env.observeCatalog("", .rebuilt);
        return .{ .sessions = sessions, .swept = swept };
    }

    /// Hooks only: the planted Catalog bug lists `.trash` entries as live.
    fn plantedResurrect(cat: Catalog, fresh: *Index) Error!void {
        const s = cat.env.s;
        const trash = s.openDir(cat.env.root, ".trash") catch return;
        defer s.closeDir(trash);
        var listing = s.list(trash);
        while (listing.next() catch |io_err| return storage.ioFault(io_err)) |entry| {
            if (!schema.validId(entry.name)) continue;
            const id = try fresh.arena.allocator().dupe(u8, entry.name);
            try fresh.apply(.{ .put = .{ .id = id, .role = .root, .host = .app, .workspace = "/w", .created_ms = 0, .updated_ms = 0, .turns = 0 } });
        }
    }

    // -- internals -----------------------------------------------------------

    fn append(cat: Catalog, record: Record) Error!void {
        const env = cat.env;
        const s = env.s;
        const gpa = env.gpa;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        encodeRecord(gpa, &line, record) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge => error.Io,
        };
        const lock = try cat.acquireIndexLock();
        defer cat.releaseIndexLock(lock);
        const file = s.openFile(env.root, index_name, .read_write) catch |err| switch (err) {
            error.NotFound => s.createFile(env.root, index_name) catch |io_err| return storage.ioFault(io_err),
            else => |io_err| return storage.ioFault(io_err),
        };
        defer s.closeDerived(file);
        const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
        // A crash may have left half a line; never glue a record onto it.
        const end = log_mod.lastLineEnd(s, file, len) catch |io_err| return storage.ioFault(io_err);
        if (end != len) s.setLength(file, end) catch |io_err| return storage.ioFault(io_err);
        s.writeAt(file, line.items, end) catch |io_err| return storage.ioFault(io_err);
        const size = end + line.items.len;
        if (size <= env.options.index_compact_bytes or size <= 2 * cat.lock.baseline_bytes.load(.monotonic)) return;
        const bytes = try cat.readIndex(gpa);
        defer gpa.free(bytes);
        var index = try Index.fold(gpa, bytes);
        defer index.deinit();
        // Rewritten once at least half its lines are stale; otherwise looked
        // at again only once it has doubled, so each fold is paid for by as
        // many appended bytes and a live index is not rewritten every time.
        if (bytes.len >= 2 * index.liveBytes(bytes.len)) try cat.writeFresh(&index) else cat.lock.baseline_bytes.store(bytes.len, .monotonic);
    }

    /// Replaces the index with one line per id, atomically: a temporary
    /// file, synced, renamed over the old one. Caller holds `index.lock`.
    fn writeFresh(cat: Catalog, index: *const Index) Error!void {
        const env = cat.env;
        const s = env.s;
        const gpa = env.gpa;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var it = index.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            const record: Record = if (entry.deleted)
                .{ .del = .{ .id = entry.summary.id, .ts_ms = entry.summary.updated_ms } }
            else
                .{ .put = entry.summary };
            encodeRecord(gpa, &bytes, record) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooLarge => error.Io,
            };
        }
        s.deleteFile(env.root, index_tmp_name) catch |err| switch (err) {
            error.NotFound => {},
            else => |io_err| return storage.ioFault(io_err),
        };
        const file = s.createFile(env.root, index_tmp_name) catch |io_err| return storage.ioFault(io_err);
        defer s.closeFile(file);
        if (bytes.items.len > 0) s.writeAt(file, bytes.items, 0) catch |io_err| return storage.ioFault(io_err);
        s.sync(file) catch |io_err| return storage.ioFault(io_err);
        s.rename(env.root, index_tmp_name, env.root, index_name) catch |io_err| return storage.ioFault(io_err);
        cat.lock.baseline_bytes.store(bytes.items.len, .monotonic);
        s.syncDir(env.root) catch |io_err| return storage.ioFault(io_err);
    }

    /// The whole index file; empty when there is none. Caller owns it.
    fn readIndex(cat: Catalog, gpa: std.mem.Allocator) Error![]u8 {
        const s = cat.env.s;
        const file = s.openFile(cat.env.root, index_name, .read_only) catch |err| return switch (err) {
            error.NotFound => try gpa.alloc(u8, 0),
            else => |io_err| storage.ioFault(io_err),
        };
        defer s.closeFile(file);
        const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try bytes.resize(gpa, @intCast(len));
        const n = s.readAt(file, bytes.items, 0) catch |io_err| return storage.ioFault(io_err);
        // Shorter only if a writer cut a torn tail meanwhile.
        bytes.shrinkRetainingCapacity(n);
        return bytes.toOwnedSlice(gpa);
    }

    fn acquireIndexLock(cat: Catalog) Error!storage.File {
        const env = cat.env;
        const s = env.s;
        cat.lock.mutex.lockUncancelable(s.io);
        errdefer cat.lock.mutex.unlock(s.io);
        const file = cat.lock.file orelse blk: {
            const opened_file = s.openFile(env.root, lock_name, .read_write) catch |err| switch (err) {
                error.NotFound => s.createFile(env.root, lock_name) catch |create_err| switch (create_err) {
                    // Another process created it first.
                    error.AlreadyExists => s.openFile(env.root, lock_name, .read_write) catch |io_err| return storage.ioFault(io_err),
                    else => |io_err| return storage.ioFault(io_err),
                },
                else => |io_err| return storage.ioFault(io_err),
            };
            cat.lock.file = opened_file;
            break :blk opened_file;
        };
        var waited: u64 = 0;
        while (!(s.tryLock(file) catch |io_err| return storage.ioFault(io_err))) {
            if (waited >= env.options.lock_wait_ms) return error.Busy;
            s.io.sleep(.fromMilliseconds(5), .awake) catch return error.Busy;
            waited += 5;
        }
        return file;
    }

    fn releaseIndexLock(cat: Catalog, file: storage.File) void {
        cat.env.s.unlock(file);
        cat.lock.mutex.unlock(cat.env.s.io);
    }

    /// Whether the session's folder still exists; if not, it is tombstoned
    /// (`tla/Catalog.tla` `Heal`) and reported once.
    /// One `stat` of the folder, no open: a published folder always holds
    /// its synced log (publish renames it in whole, delete renames it away),
    /// so the folder alone decides. `rebuild` checks the logs themselves.
    fn healIfGone(cat: Catalog, id: []const u8) Error!bool {
        const s = cat.env.s;
        const present = if (s.stat(cat.env.root, id)) |st| st.kind == .directory else |err| switch (err) {
            error.NotFound => false,
            else => |io_err| return storage.ioFault(io_err),
        };
        if (present) return true;
        try cat.del(id, nowMs(cat.env));
        diag.report(cat.env.diagnostics, .{ .kind = .index_healed, .session_id = id, .count = 1 });
        cat.env.observeCatalog(id, .healed);
        return false;
    }

    /// The live roots `filter` keeps that follow `cursor`, newest first,
    /// pointing into `index`.
    fn sorted(arena: std.mem.Allocator, index: *const Index, filter: Filter, cursor: ?Cursor) error{OutOfMemory}![]const *const Summary {
        var out: std.ArrayList(*const Summary) = .empty;
        for (index.entries.values()) |*entry| {
            if (entry.deleted or entry.summary.role != .root) continue;
            switch (filter) {
                .all => {},
                .workspace => |w| if (!std.mem.eql(u8, entry.summary.workspace, w)) continue,
            }
            if (cursor) |c| if (!isAfter(entry.summary, c)) continue;
            try out.append(arena, &entry.summary);
        }
        // Ids are unique, so the order is total: no stable sort, which
        // moves whole summaries, is needed.
        std.mem.sortUnstable(*const Summary, out.items, {}, newerFirst);
        return out.items;
    }

    /// Removes `.trash` entries, and `.tmp` entries old enough that no
    /// publish can still be writing them. Caller holds `index.lock`.
    fn sweep(cat: Catalog) Error!u64 {
        const env = cat.env;
        const s = env.s;
        var swept: u64 = 0;
        const now = std.math.cast(i64, nowMs(env)) orelse std.math.maxInt(i64);
        for ([_][]const u8{ ".trash", ".tmp" }) |folder| {
            const dir = s.openDir(env.root, folder) catch |err| switch (err) {
                error.NotFound => continue,
                else => |io_err| return storage.ioFault(io_err),
            };
            defer s.closeDir(dir);
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| env.gpa.free(n);
                names.deinit(env.gpa);
            }
            var listing = s.list(dir);
            while (listing.next() catch |io_err| return storage.ioFault(io_err)) |entry| {
                try names.append(env.gpa, try env.gpa.dupe(u8, entry.name));
            }
            for (names.items) |name| {
                if (!schema.validId(name)) continue;
                if (std.mem.eql(u8, folder, ".tmp")) {
                    const st = s.stat(dir, name) catch continue;
                    if (now - st.mtime_ms < sweep_after_ms) continue;
                }
                s.deleteTree(dir, name) catch |io_err| return storage.ioFault(io_err);
                swept += 1;
            }
        }
        return swept;
    }
};

fn nowMs(env: *const session_mod.Env) u64 {
    return std.math.cast(u64, std.Io.Timestamp.now(env.s.io, .real).toMilliseconds()) orelse 0;
}

fn newerFirst(_: void, a: *const Summary, b: *const Summary) bool {
    if (a.updated_ms != b.updated_ms) return a.updated_ms > b.updated_ms;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// Whether `s` sorts after the cursor's entry.
fn isAfter(s: Summary, c: Cursor) bool {
    if (s.updated_ms != c.updated_ms) return s.updated_ms < c.updated_ms;
    return std.mem.lessThan(u8, c.id(), s.id);
}

fn copySummary(arena: std.mem.Allocator, s: Summary) error{OutOfMemory}!Summary {
    var copy = s;
    copy.id = try arena.dupe(u8, s.id);
    copy.workspace = try arena.dupe(u8, s.workspace);
    if (s.title) |t| copy.title = try arena.dupe(u8, t);
    if (s.language) |l| copy.language = try arena.dupe(u8, l);
    if (s.parent) |p| copy.parent = try arena.dupe(u8, p);
    return copy;
}

/// The index record for a session read from its folder.
pub fn summaryFrom(arena: std.mem.Allocator, summary: *const session_mod.Summary) error{OutOfMemory}!Summary {
    const identity = &summary.identity;
    const state = &summary.state;
    const workspace = if (state.workspace) |raw|
        std.json.parseFromSliceLeaky([]const u8, arena, raw, .{}) catch identity.workspace
    else
        identity.workspace;
    return .{
        .id = try arena.dupe(u8, identity.id),
        .role = identity.role,
        .host = identity.host,
        .workspace = try arena.dupe(u8, workspace),
        .title = if (state.title) |t| try arena.dupe(u8, t) else null,
        .language = if (state.language) |l| try arena.dupe(u8, l) else null,
        .parent = if (identity.parent) |p| try arena.dupe(u8, p) else null,
        .created_ms = summary.created_ms,
        .updated_ms = summary.updated_ms,
        .turns = state.committed + state.interrupted,
    };
}

// ---------------------------------------------------------------------------
// Tests (pure)

const testing = std.testing;

fn sample(id: []const u8, updated: u64) Summary {
    return .{ .id = id, .role = .root, .host = .app, .workspace = "/w", .created_ms = 1, .updated_ms = updated, .turns = 2 };
}

test "records round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var summary = sample("abc", 7);
    summary.title = "\"a \\\"title\\\"\"";
    summary.parent = "p";
    summary.opened_ms[@intFromEnum(schema.Host.ask)] = 9;
    try encodeRecord(arena.allocator(), &out, .{ .put = summary });
    try encodeRecord(arena.allocator(), &out, .{ .opened = .{ .id = "abc", .host = .acp, .ts_ms = 10 } });
    try encodeRecord(arena.allocator(), &out, .{ .del = .{ .id = "abc", .ts_ms = 11 } });
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    const put = (try decodeRecord(arena.allocator(), try std.mem.concat(arena.allocator(), u8, &.{ lines.next().?, "\n" }))).?.put;
    try testing.expectEqualStrings("\"a \\\"title\\\"\"", put.title.?);
    try testing.expectEqual(@as(u64, 9), put.opened_ms[@intFromEnum(schema.Host.ask)]);
    const opened = (try decodeRecord(arena.allocator(), try std.mem.concat(arena.allocator(), u8, &.{ lines.next().?, "\n" }))).?.opened;
    try testing.expectEqual(schema.Host.acp, opened.host);
    const del = (try decodeRecord(arena.allocator(), try std.mem.concat(arena.allocator(), u8, &.{ lines.next().?, "\n" }))).?.del;
    try testing.expectEqual(@as(u64, 11), del.ts_ms);
}

test "the fold keeps the newest put, merges open times, and a tombstone is final" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    const a = arena.allocator();
    try encodeRecord(a, &out, .{ .put = sample("s1", 1) });
    try encodeRecord(a, &out, .{ .opened = .{ .id = "s1", .host = .app, .ts_ms = 5 } });
    var newer = sample("s1", 3);
    newer.turns = 4;
    try encodeRecord(a, &out, .{ .put = newer });
    try encodeRecord(a, &out, .{ .put = sample("s2", 2) });
    try encodeRecord(a, &out, .{ .del = .{ .id = "s2", .ts_ms = 4 } });
    try encodeRecord(a, &out, .{ .put = sample("s2", 9) }); // stale writer: ignored
    try out.appendSlice(a, "{\"op\":\"put\",\"id\":\"torn"); // torn tail
    var index = try Index.fold(testing.allocator, out.items);
    defer index.deinit();
    try testing.expectEqual(@as(u64, 0), index.damaged_lines);
    const s1 = index.entries.get("s1").?.summary;
    try testing.expectEqual(@as(u64, 4), s1.turns);
    try testing.expectEqual(@as(u64, 5), s1.opened_ms[@intFromEnum(schema.Host.app)]);
    try testing.expect(index.isDeleted("s2"));

    // A flipped byte in a middle line is counted, never folded.
    out.items[20] ^= 1;
    var damaged = try Index.fold(testing.allocator, out.items);
    defer damaged.deinit();
    try testing.expectEqual(@as(u64, 1), damaged.damaged_lines);
}

test "open times decode without a second parse as written, and any other spelling as JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual([host_count]u64{ 1791248460854, 0, 7, 0, 0 }, plainTimes("[1791248460854,0,7,0,0]").?);
    for ([_][]const u8{ "[1,0,0,0]", "[1,0,0,0,0,0]", "[01,0,0,0,0]", "[1, 0,0,0,0]", "[-1,0,0,0,0]", "[1,0,0,0,]", "[]", "1" }) |raw| {
        try testing.expect(plainTimes(raw) == null);
    }
    // A spelling this module never writes still decodes, through JSON.
    var out: std.ArrayList(u8) = .empty;
    try log_mod.appendFramed(a, &out, "{\"op\":\"put\",\"id\":\"s1\",\"role\":\"root\",\"host\":\"app\",\"workspace\":\"/w\",\"created\":1,\"updated\":2,\"turns\":1,\"opened\":[3, 0, 0, 0, 9]");
    const put = (try decodeRecord(a, out.items)).?.put;
    try testing.expectEqual([host_count]u64{ 3, 0, 0, 0, 9 }, put.opened_ms);
}

test "the live size is the share of folded lines still the newest of their id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (0..3) |_| try encodeRecord(a, &out, .{ .put = sample("s1", 1) });
    try encodeRecord(a, &out, .{ .put = sample("s2", 1) });
    var index = try Index.fold(testing.allocator, out.items);
    defer index.deinit();
    try testing.expectEqual(@as(u64, 4), index.lines);
    try testing.expectEqual(out.items.len / 2, index.liveBytes(out.items.len));
    var empty = try Index.fold(testing.allocator, "");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.liveBytes(0));
}

const catalog_model_tests = struct {
    //! L3 and L4 against `tla/Catalog.tla`: publish, delete, crashes between
    //! the folder change and the index write, self-heal and rebuild, driven
    //! through the public API. Every run writes a trace for TLC.

    const api = @import("api.zig");
    const catalog_mod = @import("catalog.zig");
    const trace = @import("trace.zig");
    const Fault = @import("storage_fault.zig").Fault;

    const gpa = testing.allocator;
    const io = testing.io;
    const Io = std.Io;

    const CatTracer = struct {
        trace: trace.Trace,
        root: Io.Dir,
        fault: *Fault,
        ids: [3]?[]u8 = .{ null, null, null },
        published: [3]bool = .{ false, false, false },
        pending: [3][]const u8 = .{ "none", "none", "none" },
        ever_deleted: [3]bool = .{ false, false, false },
        /// Kill the process right after this step for this session.
        kill_after: ?struct { what: enum { published, trashed }, id: []const u8 } = null,

        const labels = [3][]const u8{ "s1", "s2", "s3" };

        fn deinit(t: *CatTracer) void {
            for (t.ids) |maybe| if (maybe) |id| gpa.free(id);
        }

        fn slot(t: *CatTracer, id: []const u8) usize {
            for (t.ids, 0..) |maybe, i| {
                if (maybe) |known| if (std.mem.eql(u8, known, id)) return i;
            }
            for (&t.ids, 0..) |*maybe, i| if (maybe.* == null) {
                maybe.* = gpa.dupe(u8, id) catch @panic("oom");
                return i;
            };
            @panic("more than three traced sessions");
        }

        fn observer(t: *CatTracer) session_mod.Observer {
            return .{ .context = t, .notify = notify };
        }

        fn catalogObserver(t: *CatTracer) session_mod.CatalogObserver {
            return .{ .context = t, .notify = notifyCatalog };
        }

        fn notify(context: *anyopaque, session: *session_mod.Session, what: session_mod.Observed) void {
            const t: *CatTracer = @ptrCast(@alignCast(context));
            if (what != .published) return;
            const i = t.slot(session.id());
            t.published[i] = true;
            t.pending[i] = "put";
            t.emit("Publish", labels[i]);
            t.maybeKill(.published, session.id());
        }

        fn notifyCatalog(context: *anyopaque, id: []const u8, what: session_mod.CatalogStep) void {
            const t: *CatTracer = @ptrCast(@alignCast(context));
            if (what == .rebuilt) {
                t.pending = .{ "none", "none", "none" };
                t.emit("Rebuild", null);
                return;
            }
            const i = t.slot(id);
            switch (what) {
                // Updates of an indexed session are not spec actions.
                .index_put => if (std.mem.eql(u8, t.pending[i], "put")) {
                    t.pending[i] = "none";
                    t.emit("IndexPut", labels[i]);
                },
                // A heal's tombstone is reported by `.healed`.
                .index_del => if (std.mem.eql(u8, t.pending[i], "del")) {
                    t.pending[i] = "none";
                    t.emit("IndexDel", labels[i]);
                },
                .trashed => {
                    t.pending[i] = "del";
                    t.ever_deleted[i] = true;
                    t.emit("Trash", labels[i]);
                    t.maybeKill(.trashed, id);
                },
                .purged => t.emit("Purge", labels[i]),
                .healed => t.emit("Heal", labels[i]),
                .rebuilt => unreachable,
            }
        }

        fn maybeKill(t: *CatTracer, what: @TypeOf(t.kill_after.?.what), id: []const u8) void {
            const k = t.kill_after orelse return;
            if (k.what == what and std.mem.eql(u8, k.id, id)) t.fault.kill();
        }

        /// fx dies: owed index writes are forgotten.
        fn crash(t: *CatTracer) void {
            t.pending = .{ "none", "none", "none" };
            t.emit("Crash", null);
            t.kill_after = null;
            t.fault.restart();
        }

        fn dirOf(t: *CatTracer, i: usize) []const u8 {
            const id = t.ids[i] orelse return "none";
            var path: [300]u8 = undefined;
            if (exists(t.root, id)) return "live";
            if (exists(t.root, std.fmt.bufPrint(&path, ".trash/{s}", .{id}) catch return "none")) return "trash";
            return if (t.published[i]) "gone" else "none";
        }

        const IndexLine = struct { id: []const u8, op: []const u8 };

        fn indexOf(t: *CatTracer, arena: std.mem.Allocator) ![]IndexLine {
            var out: std.ArrayList(IndexLine) = .empty;
            const bytes = t.root.readFileAlloc(io, "index.jsonl", gpa, .limited(8 << 20)) catch return out.items;
            defer gpa.free(bytes);
            var last_op: [3][]const u8 = .{ "none", "none", "none" };
            var at: usize = 0;
            while (std.mem.findScalarPos(u8, bytes, at, '\n')) |nl| : (at = nl + 1) {
                const record = (try catalog_mod.decodeRecord(arena, bytes[at .. nl + 1])) orelse continue;
                const id, const op = switch (record) {
                    .put => |p| .{ p.id, "put" },
                    .del => |d| .{ d.id, "del" },
                    .opened => continue,
                };
                const i = t.slot(id);
                if (std.mem.eql(u8, op, "put") and std.mem.eql(u8, last_op[i], "put")) continue;
                last_op[i] = op;
                try out.append(arena, .{ .id = labels[i], .op = op });
            }
            return out.items;
        }

        fn emit(t: *CatTracer, event: []const u8, s: ?[]const u8) void {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const index = t.indexOf(arena) catch return;
            const Names = struct { s1: []const u8, s2: []const u8, s3: []const u8 };
            var deleted: std.ArrayList([]const u8) = .empty;
            for (t.ever_deleted, labels) |d, label| if (d) deleted.append(arena, label) catch return;
            const Set = struct { @"$set": []const []const u8 };
            const dir: Names = .{ .s1 = t.dirOf(0), .s2 = t.dirOf(1), .s3 = t.dirOf(2) };
            const pending: Names = .{ .s1 = t.pending[0], .s2 = t.pending[1], .s3 = t.pending[2] };
            const ever: Set = .{ .@"$set" = deleted.items };
            if (s) |label| {
                t.trace.write(.{ .event = event, .s = label, .dir = dir, .index = index, .pending = pending, .everDeleted = ever });
            } else {
                t.trace.write(.{ .event = event, .dir = dir, .index = index, .pending = pending, .everDeleted = ever });
            }
        }
    };

    fn exists(root: Io.Dir, path: []const u8) bool {
        _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    fn publish(m: *api.Manager) ![]u8 {
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ .turn_started, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        s.release();
        return id;
    }

    fn listCount(m: *api.Manager) !usize {
        var page = try m.list(gpa, .all, null, 10);
        defer page.deinit();
        return page.items.len;
    }

    fn runCatalogTrace(case: []const u8, planted: trace.Planted) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(base);
        const root_path = try std.fs.path.join(gpa, &.{ base, "sessions", "v2" });
        defer gpa.free(root_path);
        var fault = Fault.init(gpa, io, 1);
        defer fault.deinit();
        const m = try api.Manager.init(gpa, io, .{ .root = root_path, .lock_wait_ms = 50 });
        defer m.deinit();
        m.setFault(&fault);
        try tmp.dir.createDirPath(io, "sessions/v2");
        var root = try tmp.dir.openDir(io, "sessions/v2", .{});
        defer root.close(io);
        var tracer: CatTracer = .{ .trace = try trace.Trace.create(gpa, io, "Catalog", case), .root = root, .fault = &fault };
        defer tracer.deinit();
        m.env.observer = tracer.observer();
        m.env.catalog_observer = tracer.catalogObserver();
        m.env.planted = planted;

        const s1 = try publish(m);
        defer gpa.free(s1);
        const s2 = try publish(m);
        defer gpa.free(s2);

        // s3: the process dies between its publish and its index put.
        {
            const s = try m.openNew(.{ .workspace = "/w", .host = .app });
            tracer.kill_after = .{ .what = .published, .id = s.id() };
            _ = try s.append(&.{ .turn_started, .turn_committed });
            s.release();
            tracer.crash();
        }
        try testing.expectEqual(@as(usize, 2), try listCount(m));

        // A clean delete, then one that dies between trash and tombstone.
        try m.delete(s1);
        tracer.kill_after = .{ .what = .trashed, .id = s2 };
        try testing.expectError(error.Io, m.delete(s2));
        tracer.crash();
        // list heals the stale entry, then rebuild purges .trash and finds s3.
        // The planted run rebuilds straight away: a tombstone from the heal
        // would otherwise stop the planted bug (tombstones survive rebuild).
        if (planted == .none) try testing.expectEqual(@as(usize, 0), try listCount(m));
        _ = try m.rebuild();
        if (planted == .none) {
            try testing.expectEqual(@as(usize, 1), try listCount(m));
            try testing.expectError(error.NotFound, m.read(gpa, s2, .start, .forward, 1));
        }
        try tracer.trace.finish();
    }

    test "Catalog trace: publish, crash before the index, delete, crash after trash, heal, rebuild" {
        try runCatalogTrace("crashes-heal-rebuild", .none);
    }

    test "Catalog trace: planted bug, rebuild resurrects a trashed id" {
        try runCatalogTrace("planted-rebuild_resurrects", .rebuild_resurrects);
    }
};

test {
    if (@import("storage.zig").hooks) _ = catalog_model_tests;
}

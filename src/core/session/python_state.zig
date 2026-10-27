//! A node's Python state in its session log (D99): the `proto_fx` store and
//! a snapshot of every kernel at the end of each turn in which it ran a
//! cell. Both are lines of the node's own log over content-addressed blobs
//! of its own session, so a rewind and a fork need no code of their own:
//! the folds in `session_manager/python_fold.zig` skip the turns a rewind
//! dropped, and a fork copies the lines through its point with their blobs.
//!
//! - Turn end (`TurnKernels`): before a turn's end line, each of the node's
//!   kernels that ran a cell since its last line snapshots under its own
//!   gate, so no later cell can come first, and the turn's end batch carries
//!   one `kernel_snapshot` line per kernel. Kernel processes write their own
//!   records into the node's blob folder with the manager's blob protocol
//!   (a `.pending` name, fsync, rename to the hash); only the manager writes
//!   lines, and every read checks a blob against its name.
//! - Restore (`resolve`): a kernel starting without a save of this process
//!   reads the newest kept `kernel_snapshot` of its name, without the
//!   session's lock.
//! - Store (`storeSet` and the rest): through the node's open session,
//!   which the registry below finds by id, inside the node's running turn.
//!
//! `tests/tla/session_manager/PythonState.tla` checks that a fork or rewind
//! at any turn restores that turn's exact state.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const adapter = @import("session_adapter.zig");
const sm = adapter.python_api;
const kernel = @import("../kernel/kernel.zig");
const pool = @import("../kernel/pool.zig");
const slot = @import("../kernel/slot.zig");
const kernel_protocol = @import("../kernel/protocol.zig");
const Allocator = std.mem.Allocator;
const Session = adapter.Session;
const Manifest = kernel_protocol.Manifest;

const op_store = @import("../harness/op_store.zig");
/// Largest stored value after pickling, most keys, and most bytes in all.
pub const max_value_bytes = op_store.max_value_bytes;
pub const max_keys = op_store.max_keys;
pub const max_store_bytes = op_store.max_store_bytes;
/// Most failures one snapshot line names; the rest are counted.
const max_failed_listed = 256;

pub const blobDir = slot.nodeBlobDir;

// ---------------------------------------------------------------------------
// Restore

/// Reads one session's log by id without its lock.
const ById = struct {
    manager: *sm.Manager,
    id: []const u8,

    pub fn read(self: ById, gpa: Allocator, from: sm.From, direction: sm.Direction, limit: usize) !sm.Page {
        return self.manager.read(gpa, self.id, from, direction, limit);
    }
};

/// The newest kept snapshot of kernel `name` in the log of `node_id`, whose
/// blobs are `blob_dir`, as `kernel.Resolver` asks; null when the log holds
/// none or the session is not on disk. Caller owns it.
pub fn resolve(alloc: Allocator, blob_dir: []const u8, node_id: []const u8, name: []const u8) anyerror!?*Manifest {
    const session_dir = std.Io.Dir.path.dirname(blob_dir) orelse return null;
    const root = std.Io.Dir.path.dirname(session_dir) orelse return null;
    // No disk I/O until the first read; nothing here takes the session's lock.
    const manager = try sm.Manager.init(alloc, io_mod.getIo(), .{ .root = root });
    defer manager.deinit();
    var peeked = manager.peek(alloc, node_id) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer peeked.deinit(alloc);
    var found = (try sm.python_fold.latestKernel(alloc, ById{ .manager = manager, .id = node_id }, peeked.state.dropped.items, name)) orelse return null;
    defer found.deinit();
    debug_trace.logf("kernel", "restore source node={s} kernel={s} turn={d} records={d}", .{ node_id, name, found.turn, found.names.len });
    return try manifestOf(alloc, &found);
}

fn manifestOf(alloc: Allocator, found: *const sm.python_fold.Kernel) !*Manifest {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const records = try a.alloc(kernel_protocol.Record, found.names.len);
    for (found.names, found.blobs, records) |name, hash, *record| record.* = .{ .name = name, .hash = hash };
    const failed = std.json.parseFromSliceLeaky([]const kernel_protocol.Event.Failure, a, found.failed, .{ .ignore_unknown_fields = true }) catch &.{};
    return Manifest.create(alloc, records, failed);
}

// ---------------------------------------------------------------------------
// Turn end

/// The `kernel_snapshot` lines a turn's end writes, and the kernels they
/// record, which learn it once the batch is durable.
pub const TurnKernels = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    managers: []*kernel.Manager = &.{},
    recorded_ones: std.ArrayList(*kernel.Manager) = .empty,
    events: std.ArrayList(sm.Event) = .empty,

    /// Snapshots every kernel of `session`'s node that ran a cell since its
    /// last line. Opens the turn first, so the session folder that holds
    /// the records exists. A kernel that cannot snapshot is left out with a
    /// trace and stays due; the turn still ends.
    pub fn take(alloc: Allocator, session: *Session) TurnKernels {
        var self: TurnKernels = .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
        self.collect(session) catch |err| debug_trace.logf("kernel", "turn snapshot skipped session={s} err={s}", .{ session.id(), @errorName(err) });
        return self;
    }

    fn collect(self: *TurnKernels, session: *Session) !void {
        self.managers = try pool.nodeKernels(self.alloc, session.id());
        var due = false;
        for (self.managers) |manager| {
            if (manager.dueForLog()) due = true;
        }
        if (!due) return;
        try session.beginTurn();
        const a = self.arena.allocator();
        for (self.managers) |manager| {
            const began = io_mod.monotonicMilliTimestamp();
            const manifest = (manager.turnSnapshot(a) catch |err| {
                debug_trace.logf("kernel", "turn snapshot failed session={s} kernel={s} err={s}", .{ session.id(), manager.name, @errorName(err) });
                continue;
            }) orelse continue;
            try self.events.append(a, .{ .kernel_snapshot = try lineOf(a, manager.name, manifest) });
            try self.recorded_ones.append(a, manager);
            debug_trace.logf("kernel", "turn snapshot session={s} kernel={s} records={d} failed={d} written={d} bytes={d} ms={d}", .{
                session.id(),   manager.name,                             manifest.records.len, manifest.failed.len, manifest.written,
                manifest.bytes, io_mod.monotonicMilliTimestamp() - began,
            });
        }
    }

    /// The batch carrying these lines is durable.
    pub fn recorded(self: *TurnKernels) void {
        for (self.recorded_ones.items) |manager| manager.recorded();
    }

    pub fn deinit(self: *TurnKernels) void {
        if (self.managers.len > 0) pool.unpinAll(self.alloc, self.managers);
        self.arena.deinit();
        self.* = undefined;
    }
};

fn lineOf(a: Allocator, name: []const u8, manifest: *const Manifest) !sm.KernelSnapshot {
    const names = try a.alloc([]const u8, manifest.records.len);
    const blobs = try a.alloc([]const u8, manifest.records.len);
    for (manifest.records, names, blobs) |record, *n, *b| {
        n.* = record.name;
        b.* = record.hash;
    }
    var failed: std.Io.Writer.Allocating = .init(a);
    const listed = manifest.failed[0..@min(manifest.failed.len, max_failed_listed)];
    try failed.writer.writeByte('[');
    for (listed, 0..) |entry, i| {
        if (i > 0) try failed.writer.writeByte(',');
        try std.json.Stringify.value(entry, .{}, &failed.writer);
    }
    // One more entry counts the globals the list leaves out.
    if (manifest.failed.len > listed.len) try failed.writer.print(",{{\"name\":\"...\",\"reason\":\"{d} more globals not saved\"}}", .{manifest.failed.len - listed.len});
    try failed.writer.writeByte(']');
    return .{ .kernel = name, .names = names, .blobs = blobs, .failed = failed.written() };
}

// ---------------------------------------------------------------------------
// Rewind

/// A rewind dropped turns of node `node_id`: its kernels go back to the
/// newest snapshot it kept, restored in the background (D99).
pub fn afterRewind(node_id: []const u8) void {
    pool.resetNode(std.heap.c_allocator, node_id);
}

// ---------------------------------------------------------------------------
// The open sessions, by id, for the store

const Live = struct { session: *Session, users: usize = 0 };

var live_lock: std.Io.Mutex = .init;
var live_changed: std.Io.Condition = .init;
var live: std.ArrayList(Live) = .empty;

/// The session is open for writing: the store can reach it by id.
pub fn register(session: *Session) void {
    // Kernels find their snapshots through the log from now on.
    slot.state_resolver = resolve;
    slot.state_usage = usage;
    op_store.backend = .{ .set = storeSet, .get = storeGet, .del = storeDel, .keys = storeKeys };
    const io = io_mod.getIo();
    live_lock.lockUncancelable(io);
    defer live_lock.unlock(io);
    live.append(std.heap.c_allocator, .{ .session = session }) catch {};
}

/// The session is closing: waits for any store call on it, then forgets it.
pub fn unregister(session: *Session) void {
    const io = io_mod.getIo();
    live_lock.lockUncancelable(io);
    defer live_lock.unlock(io);
    while (true) {
        const index = for (live.items, 0..) |entry, i| {
            if (entry.session == session) break i;
        } else return;
        if (live.items[index].users == 0) {
            _ = live.swapRemove(index);
            return;
        }
        live_changed.waitUncancelable(io, &live_lock);
    }
}

fn acquire(id: []const u8) ?*Session {
    const io = io_mod.getIo();
    live_lock.lockUncancelable(io);
    defer live_lock.unlock(io);
    for (live.items) |*entry| if (std.mem.eql(u8, entry.session.id(), id)) {
        entry.users += 1;
        return entry.session;
    };
    return null;
}

fn releaseSession(session: *Session) void {
    const io = io_mod.getIo();
    live_lock.lockUncancelable(io);
    for (live.items) |*entry| if (entry.session == session) {
        entry.users -= 1;
        break;
    };
    live_lock.unlock(io);
    live_changed.broadcast(io);
}

// ---------------------------------------------------------------------------
// Store

pub const StoreError = error{
    /// The node's session is not open in this process.
    NoSession,
    InvalidKey,
    ValueTooLarge,
    TooManyKeys,
    StoreFull,
};

fn checkKey(key: []const u8) StoreError!void {
    if (key.len == 0 or key.len > sm.max_store_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
}

/// The node's store folded from its log. Caller deinits it.
fn fold(alloc: Allocator, session: *Session) !sm.python_fold.Store {
    var state = try session.handle.state(alloc);
    defer state.deinit(alloc);
    if (!session.handle.onDisk()) return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    return sm.python_fold.store(alloc, session.handle, state.dropped.items);
}

fn blobSize(session: *Session, alloc: Allocator, hash: []const u8) u64 {
    const path = session.store.manager.blobPath(alloc, session.id(), hash) catch return 0;
    defer alloc.free(path);
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return 0;
    return stat.size;
}

/// Keeps `value`, a pickled object, under `key` in node `node_id`'s store,
/// as a line of its running turn.
pub fn storeSet(alloc: Allocator, node_id: []const u8, key: []const u8, value: []const u8) !void {
    try checkKey(key);
    if (value.len > max_value_bytes) return error.ValueTooLarge;
    const session = acquire(node_id) orelse return error.NoSession;
    defer releaseSession(session);
    var current = try fold(alloc, session);
    defer current.deinit();
    var total: u64 = value.len;
    for (current.values.keys(), current.values.values()) |existing, hash| {
        if (std.mem.eql(u8, existing, key)) continue;
        total += blobSize(session, alloc, hash);
    }
    if (current.get(key) == null and current.values.count() >= max_keys) return error.TooManyKeys;
    if (total > max_store_bytes) return error.StoreFull;
    try session.beginTurn();
    const hash = try session.handle.putBlob(value);
    const blob: [1][]const u8 = .{&hash};
    try session.appendPythonState(&.{.{ .store_set = .{ .key = key, .blob = &blob } }});
}

/// The pickled value under `key`, or null. Caller owns it.
pub fn storeGet(alloc: Allocator, node_id: []const u8, key: []const u8) !?[]u8 {
    try checkKey(key);
    const session = acquire(node_id) orelse return error.NoSession;
    defer releaseSession(session);
    var current = try fold(alloc, session);
    defer current.deinit();
    const hash = current.get(key) orelse return null;
    return try session.store.manager.getBlob(alloc, session.id(), hash);
}

/// Removes `key`; false when the store did not hold it.
pub fn storeDel(alloc: Allocator, node_id: []const u8, key: []const u8) !bool {
    try checkKey(key);
    const session = acquire(node_id) orelse return error.NoSession;
    defer releaseSession(session);
    var current = try fold(alloc, session);
    defer current.deinit();
    if (current.get(key) == null) return false;
    try session.appendPythonState(&.{.{ .store_del = key }});
    return true;
}

/// Every key, in the order each was first set. Caller frees with `freeKeys`.
pub fn storeKeys(alloc: Allocator, node_id: []const u8) ![][]u8 {
    const session = acquire(node_id) orelse return error.NoSession;
    defer releaseSession(session);
    var current = try fold(alloc, session);
    defer current.deinit();
    const keys = try alloc.alloc([]u8, current.values.count());
    var made: usize = 0;
    errdefer {
        for (keys[0..made]) |item| alloc.free(item);
        alloc.free(keys);
    }
    for (current.values.keys()) |item| {
        keys[made] = try alloc.dupe(u8, item);
        made += 1;
    }
    return keys;
}

pub fn freeKeys(alloc: Allocator, keys: [][]u8) void {
    for (keys) |item| alloc.free(item);
    alloc.free(keys);
}

// ---------------------------------------------------------------------------
// Disk use, for `/kernel`

/// Snapshot lines of a kernel in kept turns, the distinct records they
/// name, and the bytes those records hold.
pub const Usage = slot.Usage;

/// What kernel `name` of node `node_id` keeps on disk: every snapshot of a
/// kept turn shares unchanged records, so `bytes` counts each record once.
pub fn usage(alloc: Allocator, blob_dir: []const u8, node_id: []const u8, name: []const u8) !Usage {
    const session_dir = std.Io.Dir.path.dirname(blob_dir) orelse return .{};
    const root = std.Io.Dir.path.dirname(session_dir) orelse return .{};
    const manager = try sm.Manager.init(alloc, io_mod.getIo(), .{ .root = root });
    defer manager.deinit();
    var peeked = manager.peek(alloc, node_id) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    defer peeked.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.array_hash_map.String(void) = .empty;
    var result: Usage = .{};
    var from: sm.From = .start;
    while (true) {
        var page = try manager.read(alloc, node_id, from, .forward, 256);
        defer page.deinit();
        for (page.entries) |entry| {
            const body = entry.body orelse continue;
            if (body != .kernel_snapshot) continue;
            const line = body.kernel_snapshot;
            if (!std.mem.eql(u8, line.kernel, name) or droppedTurn(peeked.state.dropped.items, line.turn)) continue;
            result.snapshots += 1;
            for (line.blobs) |hash| {
                const seen_slot = try seen.getOrPut(a, hash);
                if (seen_slot.found_existing) continue;
                seen_slot.key_ptr.* = try a.dupe(u8, hash);
                result.records += 1;
                const path = try std.Io.Dir.path.join(a, &.{ blob_dir, hash });
                const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch continue;
                result.bytes += stat.size;
            }
        }
        from = .{ .at = page.next orelse break };
    }
    return result;
}

fn droppedTurn(ranges: []const sm.Dropped, turn: u64) bool {
    for (ranges) |range| if (range.dropsTurn(turn)) return true;
    return false;
}

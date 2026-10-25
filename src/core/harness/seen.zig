//! What each agent has seen of each file, for the stale-write guard.
//!
//! A record is the file's modification time, size and, when the host read
//! it, content hash at the moment the agent saw it: through `read_file`,
//! `edit_file` or `write_file`, through `harness.fs`, or through a plain
//! Python read that the guard's audit hook reported. Before a fresh Python
//! process opens an existing file for writing, it asks `check`: a file whose
//! record no longer matches the disk changed after the agent last saw it,
//! and the write is refused with StaleWriteError. A file the agent never
//! saw has no record and is never stale.
//!
//! Records live in memory for the life of the process, per node, bounded in
//! both nodes and paths; losing one only means the guard lets a write pass,
//! which is the guard's documented failure mode (it fails open).
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const Allocator = std.mem.Allocator;

pub const Hash = [32]u8;

/// Files larger than this are tracked by time and size only.
pub const max_hashed_bytes: u64 = 16 << 20;
const max_nodes: usize = 256;
const max_paths_per_node: usize = 4096;

pub const Record = struct {
    mtime_ns: i128,
    size: u64,
    hash: ?Hash = null,
};

pub const Verdict = union(enum) {
    /// The agent never saw this file, or it no longer exists.
    unknown,
    fresh,
    stale: struct { seen: Record, now: Record },
};

const Node = struct {
    id: []u8,
    paths: std.array_hash_map.String(Record) = .empty,
    used: u64 = 0,
};

var mutex: std.Io.Mutex = .init;
var nodes: std.ArrayList(*Node) = .empty;
var clock: u64 = 0;

fn alloc() Allocator {
    return std.heap.c_allocator;
}

/// The node's records, creating them and evicting the least recently used
/// node if needed. Caller holds `mutex`.
fn nodeLocked(node_id: []const u8) !*Node {
    clock += 1;
    var oldest: usize = 0;
    for (nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, node_id)) {
            node.used = clock;
            return node;
        }
        if (node.used < nodes.items[oldest].used) oldest = index;
    }
    if (nodes.items.len >= max_nodes) destroyNode(nodes.swapRemove(oldest));
    const node = try alloc().create(Node);
    errdefer alloc().destroy(node);
    node.* = .{ .id = try alloc().dupe(u8, node_id), .used = clock };
    errdefer alloc().free(node.id);
    try nodes.append(alloc(), node);
    return node;
}

fn destroyNode(node: *Node) void {
    for (node.paths.keys()) |key| alloc().free(key);
    node.paths.deinit(alloc());
    alloc().free(node.id);
    alloc().destroy(node);
}

fn put(node_id: []const u8, path: []const u8, record: Record) !void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const node = try nodeLocked(node_id);
    if (node.paths.getPtr(path)) |existing| {
        existing.* = record;
        return;
    }
    // The oldest record goes first; insertion order is kept.
    if (node.paths.count() >= max_paths_per_node) {
        alloc().free(node.paths.keys()[0]);
        node.paths.orderedRemoveAt(0);
    }
    const key = try alloc().dupe(u8, path);
    errdefer alloc().free(key);
    try node.paths.put(alloc(), key, record);
}

fn get(node_id: []const u8, path: []const u8) ?Record {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    for (nodes.items) |node| if (std.mem.eql(u8, node.id, node_id)) return node.paths.get(path);
    return null;
}

/// Forgets what node `node_id` saw of `path`.
pub fn forget(node_id: []const u8, path: []const u8) void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    for (nodes.items) |node| if (std.mem.eql(u8, node.id, node_id)) {
        if (node.paths.fetchOrderedRemove(path)) |entry| alloc().free(entry.key);
        return;
    };
}

/// The file at `path` now: time, size and content hash. Null if it is not
/// a regular file that can be read.
pub fn observe(path: []const u8) ?Record {
    const io = io_mod.getIo();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const before = file.stat(io) catch return null;
    if (before.kind != .file) return null;
    var record: Record = .{ .mtime_ns = before.mtime.nanoseconds, .size = before.size };
    if (before.size > max_hashed_bytes) return record;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var read_buffer: [8 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    while (true) {
        const count = reader.interface.readSliceShort(&buffer) catch return null;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    const after = file.stat(io) catch return null;
    // A file that changed while it was read is recorded by time and size.
    if (after.mtime.nanoseconds != before.mtime.nanoseconds or after.size != before.size) return .{ .mtime_ns = after.mtime.nanoseconds, .size = after.size };
    record.hash = hasher.finalResult();
    return record;
}

/// Records that node `node_id` saw `path` as it is now.
pub fn noteFile(node_id: []const u8, path: []const u8) void {
    if (!std.Io.Dir.path.isAbsolute(path)) return;
    const record = observe(path) orelse return forget(node_id, path);
    put(node_id, path, record) catch {};
}

/// Records a read a Python process reported: the time and size it saw when
/// it opened the file. The content hash is taken only if the file still has
/// that time and size, so a change after the read is never recorded as seen.
pub fn noteReported(node_id: []const u8, path: []const u8, mtime_ns: i128, size: u64) void {
    if (!std.Io.Dir.path.isAbsolute(path)) return;
    const now = observe(path) orelse return;
    const record: Record = if (now.mtime_ns == mtime_ns and now.size == size) now else .{ .mtime_ns = mtime_ns, .size = size };
    put(node_id, path, record) catch {};
}

/// Whether writing `path` now would overwrite a change the agent never saw.
pub fn check(node_id: []const u8, path: []const u8) Verdict {
    const seen = get(node_id, path) orelse return .unknown;
    const now = observe(path) orelse return .unknown;
    if (seen.mtime_ns == now.mtime_ns and seen.size == now.size) {
        const a = seen.hash orelse return .fresh;
        const b = now.hash orelse return .fresh;
        if (std.mem.eql(u8, &a, &b)) return .fresh;
    } else if (seen.hash != null and now.hash != null and std.mem.eql(u8, &seen.hash.?, &now.hash.?)) {
        // Touched but unchanged.
        put(node_id, path, now) catch {};
        return .fresh;
    }
    return .{ .stale = .{ .seen = seen, .now = now } };
}

/// Lowercase hex of `hash`.
pub fn hex(hash: Hash) [64]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

/// Every record, for tests.
pub fn resetForTest() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    for (nodes.items) |node| destroyNode(node);
    nodes.clearAndFree(alloc());
}

test "a file changed after the agent saw it is stale, and an unseen file never is" {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    resetForTest();
    defer resetForTest();
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "a.txt" });
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });

    try std.testing.expect(check("n", path) == .unknown);
    noteFile("n", path);
    try std.testing.expect(check("n", path) == .fresh);
    // Another node saw nothing.
    try std.testing.expect(check("m", path) == .unknown);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "two, longer\n" });
    try std.testing.expect(check("n", path) == .stale);
    noteFile("n", path);
    try std.testing.expect(check("n", path) == .fresh);

    // A reported read with a time and size the file no longer has is stale.
    noteReported("n", path, 1, 3);
    try std.testing.expect(check("n", path) == .stale);
    forget("n", path);
    try std.testing.expect(check("n", path) == .unknown);
}

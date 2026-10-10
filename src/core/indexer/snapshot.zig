//! Saved trees for one scope (format v2), so `@` can paint at launch and a
//! refresh can confirm nothing changed without reading folders again. The
//! caller chooses the file path. A file is used only when it is a private
//! regular file with one link, at most `max_bytes`, matching digest, exactly
//! the requested roots and well-formed contents; anything else is ignored
//! with a trace and a new scan follows. Older formats fail the magic check
//! and are overwritten by the next save.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const tree_mod = @import("tree.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Tree = tree_mod.Tree;

const magic = "fx-file-index-v2\n";
const max_bytes: usize = 64 * 1024 * 1024;
const max_path_bytes: usize = 4096;

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    /// One per requested root, in the requested order.
    trees: []const Tree,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Loads the snapshot at the absolute `path` for exactly `roots`, or null when
/// it is missing or not admissible.
pub fn load(alloc: Allocator, path: []const u8, roots: []const []const u8) Allocator.Error!?Snapshot {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = readAdmitted(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            arena_state.deinit();
            return null;
        },
        else => {
            debug_trace.logf("indexer", "snapshot ignored reason={s}", .{@errorName(err)});
            arena_state.deinit();
            return null;
        },
    };
    const trees = decode(arena, bytes, roots) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSnapshot => {
            debug_trace.logf("indexer", "snapshot ignored reason=invalid_contents", .{});
            arena_state.deinit();
            return null;
        },
    };
    return .{ .arena = arena_state, .trees = trees };
}

fn readAdmitted(arena: Allocator, path: []const u8) ![]const u8 {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink != 1 or (stat.permissions.toMode() & 0o077) != 0 or stat.size > max_bytes) return error.InvalidSnapshot;
    const bytes = try arena.alloc(u8, @intCast(stat.size));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 64 * 1024);
        const read = try file.readPositionalAll(io, bytes[offset..end], offset);
        if (read != end - offset) return error.InvalidSnapshot;
        offset = end;
    }
    if (bytes.len < magic.len + Sha256.digest_length or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidSnapshot;
    const payload = bytes[magic.len + Sha256.digest_length ..];
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..Sha256.digest_length])) return error.InvalidSnapshot;
    return payload;
}

/// Saves `trees` to the absolute `path`, replacing it atomically. When every
/// tree is empty the file is deleted instead, so stale entries are never
/// painted.
pub fn save(alloc: Allocator, path: []const u8, trees: []const Tree) !void {
    const io = io_mod.getIo();
    var empty = true;
    for (trees) |tree| empty = empty and tree.entries.len == 0;
    if (empty) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try encode(&payload.writer, trees);
    if (payload.written().len > max_bytes - magic.len - Sha256.digest_length) return error.SnapshotTooLarge;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(magic);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload.written(), &digest, .{});
    try out.writer.writeAll(&digest);
    try out.writer.writeAll(payload.written());

    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidSnapshotPath;
    try io_mod.makeDirRecursive(dir_path);
    // `.iterate` matters on Linux: without it the descriptor is O_PATH and
    // the directory fsync inside durableReplaceVerified fails with EBADF.
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .follow_symlinks = false, .iterate = true });
    defer dir.close(io);
    var verified: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &verified, std.fs.path.basename(path), out.written());
    try dir.setPermissions(io, .fromMode(0o700));
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeInt(writer, u32, @intCast(value.len));
    try writer.writeAll(value);
}

fn encode(writer: *std.Io.Writer, trees: []const Tree) !void {
    try writeInt(writer, u32, @intCast(trees.len));
    for (trees) |tree| {
        try writeString(writer, tree.root);
        try writeInt(writer, u64, tree.root_inode);
        try writeInt(writer, i64, tree.scan_started_ns);
        const flags: u8 = @as(u8, @intFromBool(tree.repository)) | @as(u8, @intFromBool(tree.incomplete)) << 1 | @as(u8, @intFromBool(tree.cap_reached)) << 2;
        try writer.writeByte(flags);
        try writeInt(writer, u64, tree.skipped_overlong);
        try writeInt(writer, u32, @intCast(tree.skipped_names.len));
        for (tree.skipped_names) |name| try writeString(writer, name);
        try writeInt(writer, u32, @intCast(tree.entries.len));
        for (tree.entries) |entry| {
            try writer.writeByte(@intFromEnum(entry.kind));
            try writeString(writer, entry.path);
        }
        try writeInt(writer, u32, @intCast(tree.folders.len));
        for (tree.folders) |folder| {
            try writeString(writer, folder.rel);
            try writeInt(writer, u64, folder.inode);
            try writeInt(writer, i64, folder.mtime_ns);
            try writeInt(writer, i64, folder.ctime_ns);
            try writer.writeByte(@as(u8, @intFromBool(folder.reusable)) | @as(u8, @intFromBool(folder.boundary)) << 1 | @as(u8, @intFromBool(folder.excluded)) << 2);
        }
        try writeInt(writer, u32, @intCast(tree.sources.len));
        for (tree.sources) |source| {
            try writeString(writer, source.path);
            const source_flags: u8 = @as(u8, @intFromBool(source.exists)) | @as(u8, @intFromBool(source.identity_only)) << 1 | @as(u8, @intFromBool(source.reusable)) << 2;
            try writer.writeByte(source_flags);
            try writeInt(writer, u64, source.inode);
            try writeInt(writer, u64, source.size);
            try writeInt(writer, i64, source.mtime_ns);
            try writeInt(writer, i64, source.ctime_ns);
        }
    }
}

const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Decoder, len: usize) error{InvalidSnapshot}![]const u8 {
        if (len > self.bytes.len - self.pos) return error.InvalidSnapshot;
        defer self.pos += len;
        return self.bytes[self.pos .. self.pos + len];
    }

    fn int(self: *Decoder, comptime T: type) error{InvalidSnapshot}!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    /// A count of items each at least `min_item_bytes` long, bounded by what is left.
    fn count(self: *Decoder, min_item_bytes: usize) error{InvalidSnapshot}!usize {
        const value = try self.int(u32);
        if (value > (self.bytes.len - self.pos) / min_item_bytes) return error.InvalidSnapshot;
        return value;
    }

    fn string(self: *Decoder, arena: Allocator, max: usize, allow_empty: bool) (Allocator.Error || error{InvalidSnapshot})![]const u8 {
        const len = try self.int(u32);
        if (len > max or (len == 0 and !allow_empty)) return error.InvalidSnapshot;
        const value = try self.take(len);
        if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidSnapshot;
        return arena.dupe(u8, value);
    }
};

fn decode(arena: Allocator, bytes: []const u8, roots: []const []const u8) (Allocator.Error || error{InvalidSnapshot})![]const Tree {
    var decoder: Decoder = .{ .bytes = bytes };
    const tree_count = try decoder.count(1);
    if (tree_count != roots.len) return error.InvalidSnapshot;
    const trees = try arena.alloc(Tree, tree_count);
    for (trees, roots) |*tree, expected_root| {
        const root = try decoder.string(arena, max_path_bytes, false);
        if (!std.mem.eql(u8, root, expected_root)) return error.InvalidSnapshot;
        const root_inode = try decoder.int(u64);
        const scan_started_ns = try decoder.int(i64);
        const flags = (try decoder.take(1))[0];
        if (flags & ~@as(u8, 0b111) != 0) return error.InvalidSnapshot;
        const skipped_overlong = try decoder.int(u64);
        const names = try arena.alloc([]const u8, try decoder.count(4));
        for (names) |*name| name.* = try decoder.string(arena, 255, false);
        const entries = try arena.alloc(tree_mod.Entry, try decoder.count(5));
        for (entries) |*entry| {
            const kind = (try decoder.take(1))[0];
            if (kind > 1) return error.InvalidSnapshot;
            entry.* = .{ .kind = @enumFromInt(kind), .path = try decoder.string(arena, max_path_bytes, false) };
        }
        const folders = try arena.alloc(tree_mod.FolderStamp, try decoder.count(29));
        for (folders) |*folder| {
            const rel = try decoder.string(arena, max_path_bytes, true);
            const inode = try decoder.int(u64);
            const mtime_ns = try decoder.int(i64);
            const ctime_ns = try decoder.int(i64);
            const folder_flags = (try decoder.take(1))[0];
            if (folder_flags & ~@as(u8, 7) != 0) return error.InvalidSnapshot;
            folder.* = .{
                .rel = rel,
                .inode = inode,
                .mtime_ns = mtime_ns,
                .ctime_ns = ctime_ns,
                .reusable = folder_flags & 1 != 0,
                .boundary = folder_flags & 2 != 0,
                .excluded = folder_flags & 4 != 0,
            };
        }
        const stamps = try arena.alloc(tree_mod.SourceStamp, try decoder.count(37));
        for (stamps) |*source| {
            const path = try decoder.string(arena, max_path_bytes, false);
            const source_flags = (try decoder.take(1))[0];
            if (source_flags & ~@as(u8, 0b111) != 0) return error.InvalidSnapshot;
            source.* = .{
                .path = path,
                .exists = source_flags & 1 != 0,
                .identity_only = source_flags & 2 != 0,
                .reusable = source_flags & 4 != 0,
                .inode = try decoder.int(u64),
                .size = try decoder.int(u64),
                .mtime_ns = try decoder.int(i64),
                .ctime_ns = try decoder.int(i64),
            };
        }
        tree.* = .{
            .root = root,
            .root_inode = root_inode,
            .scan_started_ns = scan_started_ns,
            .repository = flags & 1 != 0,
            .incomplete = flags & 2 != 0,
            .cap_reached = flags & 4 != 0,
            .skipped_overlong = std.math.cast(usize, skipped_overlong) orelse return error.InvalidSnapshot,
            .skipped_names = names,
            .entries = entries,
            .folders = folders,
            .sources = stamps,
        };
    }
    if (decoder.pos != bytes.len) return error.InvalidSnapshot;
    return trees;
}

fn testTree(root: []const u8, entries: []const tree_mod.Entry) Tree {
    return .{
        .root = root,
        .root_inode = 7,
        .scan_started_ns = 1_000,
        .repository = true,
        .incomplete = false,
        .cap_reached = false,
        .skipped_overlong = 2,
        .skipped_names = &.{ "node_modules", "dist" },
        .entries = entries,
        .folders = &.{
            .{ .rel = "", .inode = 7, .mtime_ns = 5, .ctime_ns = 6, .reusable = true },
            .{ .rel = "src", .inode = 9, .mtime_ns = 5, .ctime_ns = 900, .reusable = false, .boundary = true, .excluded = true },
        },
        .sources = &.{
            .{ .path = "/w/.gitignore", .exists = true, .identity_only = false, .inode = 3, .size = 10, .mtime_ns = 4, .ctime_ns = 4, .reusable = true },
            .{ .path = "/w/.git", .exists = true, .identity_only = true, .inode = 11, .reusable = true },
            .{ .path = "/home/.gitconfig", .exists = false, .identity_only = false, .reusable = true },
        },
    };
}

test "snapshot round trips, rejects tampering, other scopes and v1 files, and an empty save deletes it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const path = try std.fs.path.join(alloc, &.{ home, "file-index", "scope.idx" });
    defer alloc.free(path);
    const roots = [_][]const u8{ "/w", "/extra" };
    const trees = [_]Tree{
        testTree("/w", &.{ .{ .path = "a.txt", .kind = .file }, .{ .path = "src", .kind = .directory } }),
        testTree("/extra", &.{.{ .path = "b.txt", .kind = .file }}),
    };

    try std.testing.expect((try load(alloc, path, &roots)) == null);
    try save(alloc, path, &trees);
    {
        var loaded = (try load(alloc, path, &roots)).?;
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 2), loaded.trees.len);
        const first = loaded.trees[0];
        try std.testing.expectEqualStrings("/w", first.root);
        try std.testing.expectEqual(@as(u64, 7), first.root_inode);
        try std.testing.expect(first.repository and !first.incomplete and !first.cap_reached);
        try std.testing.expectEqual(@as(usize, 2), first.skipped_overlong);
        try std.testing.expectEqualStrings("dist", first.skipped_names[1]);
        try std.testing.expectEqualStrings("src", first.entries[1].path);
        try std.testing.expectEqual(tree_mod.Kind.directory, first.entries[1].kind);
        try std.testing.expectEqualStrings("", first.folders[0].rel);
        try std.testing.expect(!first.folders[1].reusable and first.folders[1].boundary and first.folders[1].excluded);
        try std.testing.expect(!first.folders[0].boundary and !first.folders[0].excluded);
        try std.testing.expect(first.sources[1].identity_only and !first.sources[2].exists);
        try std.testing.expectEqualStrings("b.txt", loaded.trees[1].entries[0].path);
    }

    // A different scope, or the same roots in another order, never reuses it.
    try std.testing.expect((try load(alloc, path, &.{"/w"})) == null);
    try std.testing.expect((try load(alloc, path, &.{ "/extra", "/w" })) == null);

    // Every single-byte change breaks the digest.
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "X", magic.len + Sha256.digest_length + 4);
    file.close(std.testing.io);
    try std.testing.expect((try load(alloc, path, &roots)) == null);

    // A v1 file fails the magic check.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "fx-file-index-v1\n{}", .flags = .{ .permissions = .fromMode(0o600) } });
    try std.testing.expect((try load(alloc, path, &roots)) == null);

    // A file others can read is not trusted.
    try save(alloc, path, &trees);
    try std.Io.Dir.cwd().setFilePermissions(std.testing.io, path, .fromMode(0o644), .{});
    try std.testing.expect((try load(alloc, path, &roots)) == null);

    try save(alloc, path, &.{ testTree("/w", &.{}), testTree("/extra", &.{}) });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{}));
}

test "snapshot decoding rejects every truncation and malformed fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trees = [_]Tree{testTree("/w", &.{.{ .path = "a.txt", .kind = .file }})};
    var payload: std.Io.Writer.Allocating = .init(arena);
    try encode(&payload.writer, &trees);
    const bytes = payload.written();
    _ = try decode(arena, bytes, &.{"/w"});
    for (0..bytes.len) |len| try std.testing.expectError(error.InvalidSnapshot, decode(arena, bytes[0..len], &.{"/w"}));
    const extra = try std.mem.concat(arena, u8, &.{ bytes, "x" });
    try std.testing.expectError(error.InvalidSnapshot, decode(arena, extra, &.{"/w"}));
    const bad_kind = try arena.dupe(u8, bytes);
    const kind_at = std.mem.find(u8, bad_kind, "a.txt").? - 5;
    bad_kind[kind_at] = 9;
    try std.testing.expectError(error.InvalidSnapshot, decode(arena, bad_kind, &.{"/w"}));
}

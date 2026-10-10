//! git's index file (`.git/index`) read as data: which paths are tracked and
//! which are gitlinks (submodules). Versions 2 to 4 and SHA-1 or SHA-256
//! object ids are supported. Every read is bounds-checked, so a truncated or
//! hostile file is reported as unreadable instead of being trusted.

const std = @import("std");
const bounded_read = @import("bounded_read.zig");

const Allocator = std.mem.Allocator;

/// D7: the index is never read beyond this size.
const max_index_bytes: usize = 128 * 1024 * 1024;

const mode_type_mask: u32 = 0o170000;
const mode_gitlink: u32 = 0o160000;

pub const Entry = struct {
    /// Relative to the worktree root, as stored in the index.
    path: []const u8,
    gitlink: bool,
};

pub const Index = struct {
    /// In index order (sorted by path). Unmerged paths appear once.
    entries: []const Entry,
};

pub const Outcome = union(enum) {
    /// No index file: a repository with nothing staged yet.
    missing,
    index: Index,
    /// Static string naming why the index cannot be used.
    unavailable: []const u8,
};

pub const HashFormat = enum { sha1, sha256 };

/// Reads the index at the absolute `path`. Memory belongs to `arena`.
pub fn read(arena: Allocator, path: []const u8, hash: HashFormat) Allocator.Error!Outcome {
    const data = switch (try bounded_read.readAbsolute(arena, path, max_index_bytes)) {
        .content => |bytes| bytes,
        .missing => return .missing,
        .unavailable => |reason| return .{ .unavailable = reason },
    };
    return parse(arena, data, hash);
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, len: usize) ?[]const u8 {
        if (len > self.data.len - self.pos) return null;
        const bytes = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return bytes;
    }

    fn int(self: *Reader, comptime T: type) ?T {
        const bytes = self.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }

    /// git's decode_varint, used by v4 path compression.
    fn varint(self: *Reader) ?usize {
        var byte = (self.take(1) orelse return null)[0];
        var value: usize = byte & 0x7f;
        while (byte & 0x80 != 0) {
            value = std.math.add(usize, value, 1) catch return null;
            if (value > std.math.maxInt(usize) >> 7) return null;
            byte = (self.take(1) orelse return null)[0];
            value = (value << 7) | (byte & 0x7f);
        }
        return value;
    }
};

pub fn parse(arena: Allocator, data: []const u8, hash: HashFormat) Allocator.Error!Outcome {
    const hash_len: usize = switch (hash) {
        .sha1 => 20,
        .sha256 => 32,
    };
    if (data.len < 12 + hash_len) return .{ .unavailable = "index_truncated" };
    // The trailing checksum is not verified; every field below is bounds-checked.
    var reader: Reader = .{ .data = data[0 .. data.len - hash_len] };
    const signature = reader.take(4).?;
    if (!std.mem.eql(u8, signature, "DIRC")) return .{ .unavailable = "index_signature" };
    const version = reader.int(u32).?;
    if (version < 2 or version > 4) return .{ .unavailable = "index_version" };
    const count = reader.int(u32).?;
    // The smallest v4 entry is 40 + hash + 2 + 1 + 1 bytes.
    if (count > (reader.data.len - reader.pos) / (44 + hash_len)) return .{ .unavailable = "index_truncated" };

    const entries = try arena.alloc(Entry, count);
    var kept: usize = 0;
    var previous: []const u8 = "";
    var path_buffer: std.ArrayList(u8) = .empty;
    for (0..count) |_| {
        const start = reader.pos;
        _ = reader.take(24) orelse return .{ .unavailable = "index_truncated" };
        const mode = reader.int(u32) orelse return .{ .unavailable = "index_truncated" };
        _ = reader.take(12 + hash_len) orelse return .{ .unavailable = "index_truncated" };
        const flags = reader.int(u16) orelse return .{ .unavailable = "index_truncated" };
        if (flags & 0x4000 != 0) {
            if (version < 3) return .{ .unavailable = "index_extended_flags" };
            _ = reader.int(u16) orelse return .{ .unavailable = "index_truncated" };
        }
        const stage = (flags >> 12) & 0x3;

        const path: []const u8 = if (version == 4) blk: {
            const strip = reader.varint() orelse return .{ .unavailable = "index_prefix" };
            if (strip > previous.len) return .{ .unavailable = "index_prefix" };
            const rest = reader.data[reader.pos..];
            const end = std.mem.findScalar(u8, rest, 0) orelse return .{ .unavailable = "index_truncated" };
            path_buffer.clearRetainingCapacity();
            try path_buffer.appendSlice(arena, previous[0 .. previous.len - strip]);
            try path_buffer.appendSlice(arena, rest[0..end]);
            reader.pos += end + 1;
            break :blk try arena.dupe(u8, path_buffer.items);
        } else blk: {
            const rest = reader.data[reader.pos..];
            const end = std.mem.findScalar(u8, rest, 0) orelse return .{ .unavailable = "index_truncated" };
            const name = rest[0..end];
            // Entries are padded with 1 to 8 NUL bytes to a multiple of 8.
            const fixed = reader.pos - start;
            const size = (fixed + name.len + 8) & ~@as(usize, 7);
            if (size > reader.data.len - start) return .{ .unavailable = "index_truncated" };
            reader.pos = start + size;
            break :blk name;
        };
        previous = path;
        if (path.len == 0) return .{ .unavailable = "index_empty_path" };
        // Unmerged paths carry stages 1 to 3 in sequence; keep the first.
        if (stage != 0 and kept > 0 and std.mem.eql(u8, entries[kept - 1].path, path)) continue;
        entries[kept] = .{ .path = path, .gitlink = mode & mode_type_mask == mode_gitlink };
        kept += 1;
    }

    // Extensions follow the entries. One starting with an upper-case letter is
    // optional; any other is required and changes how entries must be read.
    while (reader.pos < reader.data.len) {
        const name = reader.take(4) orelse return .{ .unavailable = "index_truncated" };
        const size = reader.int(u32) orelse return .{ .unavailable = "index_truncated" };
        if (!std.ascii.isUpper(name[0])) {
            if (std.mem.eql(u8, name, "link")) return .{ .unavailable = "index_split" };
            if (std.mem.eql(u8, name, "sdir")) return .{ .unavailable = "index_sparse" };
            return .{ .unavailable = "index_required_extension" };
        }
        _ = reader.take(size) orelse return .{ .unavailable = "index_truncated" };
    }
    return .{ .index = .{ .entries = entries[0..kept] } };
}

pub const TestEntry = struct { path: []const u8, mode: u32 = 0o100644, stage: u2 = 0 };

/// Builds an index the way git lays it out. Test support only.
pub fn buildForTest(alloc: Allocator, version: u32, hash: HashFormat, entries: []const TestEntry, extensions: []const u8) ![]u8 {
    const hash_len: usize = if (hash == .sha1) 20 else 32;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "DIRC");
    try appendInt(alloc, &out, u32, version);
    try appendInt(alloc, &out, u32, @intCast(entries.len));
    var previous: []const u8 = "";
    for (entries) |entry| {
        const start = out.items.len;
        try out.appendNTimes(alloc, 0, 24);
        try appendInt(alloc, &out, u32, entry.mode);
        try out.appendNTimes(alloc, 0, 12 + hash_len);
        const name_len: u16 = @intCast(@min(entry.path.len, 0xfff));
        try appendInt(alloc, &out, u16, (@as(u16, entry.stage) << 12) | name_len);
        if (version == 4) {
            var common: usize = 0;
            while (common < previous.len and common < entry.path.len and previous[common] == entry.path[common]) common += 1;
            try appendVarint(alloc, &out, previous.len - common);
            try out.appendSlice(alloc, entry.path[common..]);
            try out.append(alloc, 0);
        } else {
            try out.appendSlice(alloc, entry.path);
            const fixed = out.items.len - start - entry.path.len;
            const size = (fixed + entry.path.len + 8) & ~@as(usize, 7);
            try out.appendNTimes(alloc, 0, size - (out.items.len - start));
        }
        previous = entry.path;
    }
    try out.appendSlice(alloc, extensions);
    try out.appendNTimes(alloc, 0xab, hash_len);
    return out.toOwnedSlice(alloc);
}

fn appendInt(alloc: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try out.appendSlice(alloc, &bytes);
}

/// git's encode_varint.
fn appendVarint(alloc: Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var buffer: [16]u8 = undefined;
    var pos: usize = buffer.len - 1;
    var remaining = value;
    buffer[pos] = @intCast(remaining & 0x7f);
    while (true) {
        remaining >>= 7;
        if (remaining == 0) break;
        remaining -= 1;
        pos -= 1;
        buffer[pos] = @intCast(0x80 | (remaining & 0x7f));
    }
    try out.appendSlice(alloc, buffer[pos..]);
}

fn expectPaths(outcome: Outcome, expected: []const []const u8, gitlinks: []const []const u8) !void {
    const index = switch (outcome) {
        .index => |value| value,
        else => return error.TestExpectedIndex,
    };
    try std.testing.expectEqual(expected.len, index.entries.len);
    for (expected, index.entries) |want, entry| {
        try std.testing.expectEqualStrings(want, entry.path);
        var is_link = false;
        for (gitlinks) |link| is_link = is_link or std.mem.eql(u8, link, want);
        try std.testing.expectEqual(is_link, entry.gitlink);
    }
}

test "index reader handles versions 2 to 4, both hash formats, gitlinks and unmerged paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]TestEntry{
        .{ .path = "a.txt" },
        .{ .path = "conflict", .stage = 1 },
        .{ .path = "conflict", .stage = 2 },
        .{ .path = "conflict", .stage = 3 },
        .{ .path = "dir/deep/file.zig", .mode = 0o100755 },
        .{ .path = "dir/deep/link", .mode = 0o120000 },
        .{ .path = "mod", .mode = 0o160000 },
    };
    const expected = [_][]const u8{ "a.txt", "conflict", "dir/deep/file.zig", "dir/deep/link", "mod" };
    for ([_]u32{ 2, 3, 4 }) |version| {
        for ([_]HashFormat{ .sha1, .sha256 }) |hash| {
            const data = try buildForTest(arena, version, hash, &entries, "TREE\x00\x00\x00\x02ab");
            try expectPaths(try parse(arena, data, hash), &expected, &.{"mod"});
        }
    }
}

test "index reader rejects truncated, hostile and unsupported indexes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]TestEntry{ .{ .path = "a.txt" }, .{ .path = "b/c.txt" } };
    const good = try buildForTest(arena, 2, .sha1, &entries, "");
    try expectPaths(try parse(arena, good, .sha1), &.{ "a.txt", "b/c.txt" }, &.{});

    // Every truncation point is reported, never read past.
    for (0..good.len - 1) |len| {
        try std.testing.expect(try parse(arena, good[0..len], .sha1) != .index);
    }
    var bad_signature = try arena.dupe(u8, good);
    bad_signature[0] = 'X';
    try std.testing.expectEqualStrings("index_signature", (try parse(arena, bad_signature, .sha1)).unavailable);
    var bad_version = try arena.dupe(u8, good);
    std.mem.writeInt(u32, bad_version[4..8], 9, .big);
    try std.testing.expectEqualStrings("index_version", (try parse(arena, bad_version, .sha1)).unavailable);
    var huge_count = try arena.dupe(u8, good);
    std.mem.writeInt(u32, huge_count[8..12], std.math.maxInt(u32), .big);
    try std.testing.expectEqualStrings("index_truncated", (try parse(arena, huge_count, .sha1)).unavailable);

    const split = try buildForTest(arena, 2, .sha1, &entries, "link\x00\x00\x00\x00");
    try std.testing.expectEqualStrings("index_split", (try parse(arena, split, .sha1)).unavailable);
    const sparse = try buildForTest(arena, 2, .sha1, &entries, "sdir\x00\x00\x00\x00");
    try std.testing.expectEqualStrings("index_sparse", (try parse(arena, sparse, .sha1)).unavailable);
    const oversized_extension = try buildForTest(arena, 2, .sha1, &entries, "TREE\x7f\xff\xff\xff");
    try std.testing.expectEqualStrings("index_truncated", (try parse(arena, oversized_extension, .sha1)).unavailable);

    const v4 = try buildForTest(arena, 4, .sha1, &entries, "");
    var bad_prefix = try arena.dupe(u8, v4);
    // The second entry's strip count, just before its stored suffix, would
    // remove more than the previous path holds.
    const suffix = std.mem.find(u8, bad_prefix, "b/c.txt").?;
    bad_prefix[suffix - 1] = 0x7f;
    try std.testing.expectEqualStrings("index_prefix", (try parse(arena, bad_prefix, .sha1)).unavailable);
}

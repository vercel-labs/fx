//! Persisted workspace file index for instant @-completion on launch.
//!
//! One file per workspace scope under `<home>/.fx/file-index/<sha>.idx`:
//! magic + SHA-256 of the payload + JSON payload listing the scope roots and
//! every indexed path with its kind. Freshness is advisory only: a background
//! rescan always follows a cache load and replaces it, and the index is a
//! completion aid, never a correctness boundary.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const file_index = @import("file_index.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic = "fx-file-index-v1\n";
pub const max_bytes = 64 * 1024 * 1024;

const Candidate = file_index.Candidate;

const Payload = struct {
    written_at_ms: i64,
    roots: []const []const u8,
    entries: []const Entry,

    const Entry = struct {
        path: []const u8,
        kind: u8,
    };
};

pub const Loaded = struct {
    written_at_ms: i64,
    /// Owned candidate slice; each path is owned by the same allocator.
    candidates: []Candidate,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        for (self.candidates) |candidate| alloc.free(candidate.path);
        alloc.free(self.candidates);
        self.* = undefined;
    }
};

fn cacheKeyHex(alloc: Allocator, roots: []const []const u8) ![]u8 {
    var digest = Sha256.init(.{});
    for (roots) |root| {
        digest.update(root);
        digest.update(&.{0});
    }
    var sum: [Sha256.digest_length]u8 = undefined;
    digest.final(&sum);
    const hex = std.fmt.bytesToHex(sum, .lower);
    return try alloc.dupe(u8, &hex);
}

fn cachePath(alloc: Allocator, home: []const u8, roots: []const []const u8) ![]u8 {
    const key = try cacheKeyHex(alloc, roots);
    defer alloc.free(key);
    return try alloc.print("{s}/.fx/file-index/{s}.idx", .{ home, key });
}

/// Loads the persisted index for `roots` under `$HOME`, or null when absent,
/// unreadable, or invalid. All validation failures degrade to a rescan.
pub fn load(alloc: Allocator, roots: []const []const u8) !?Loaded {
    const home = io_mod.getenv("HOME") orelse return null;
    return loadFrom(alloc, home, roots);
}

/// Loads from an explicit home directory (tests and non-HOME callers).
pub fn loadFrom(alloc: Allocator, home: []const u8, roots: []const []const u8) !?Loaded {
    const path = try cachePath(alloc, home, roots);
    defer alloc.free(path);
    return loadPath(alloc, path, roots) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => null,
        else => blk: {
            debug_trace.logf("core", "file index cache ignored err={s}", .{@errorName(err)});
            break :blk null;
        },
    };
}

fn loadPath(alloc: Allocator, path: []const u8, roots: []const []const u8) !?Loaded {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(zio);
    const stat = try file.stat(zio);
    if (stat.kind != .file or stat.nlink != 1 or (stat.permissions.toMode() & 0o077) != 0 or stat.size > max_bytes) return error.InvalidIndexCache;
    const bytes = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 64 * 1024);
        const read = try file.readPositionalAll(zio, bytes[offset..end], offset);
        if (read != end - offset) return error.InvalidIndexCache;
        offset = end;
    }
    if (bytes.len < magic.len + Sha256.digest_length or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidIndexCache;
    const payload = bytes[magic.len + Sha256.digest_length ..];
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..Sha256.digest_length])) return error.InvalidIndexCache;
    var parsed = try std.json.parseFromSlice(Payload, alloc, payload, .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = false, .max_value_len = max_bytes });
    defer parsed.deinit();
    const value = parsed.value;
    if (value.written_at_ms < 0 or value.roots.len == 0) return error.InvalidIndexCache;
    if (value.entries.len > file_index.max_indexed_files) return error.InvalidIndexCache;
    if (value.roots.len != roots.len) return error.InvalidIndexCache;
    for (value.roots, roots) |cached, expected| {
        if (!std.mem.eql(u8, cached, expected)) return error.InvalidIndexCache;
    }
    var candidates = try std.ArrayList(Candidate).initCapacity(alloc, value.entries.len);
    errdefer {
        for (candidates.items) |candidate| alloc.free(candidate.path);
        candidates.deinit(alloc);
    }
    for (value.entries) |entry| {
        if (entry.path.len == 0 or entry.path.len > file_index.max_path_len) return error.InvalidIndexCache;
        if (!text_utils.isTerminalSafe(entry.path)) return error.InvalidIndexCache;
        const kind: file_index.CandidateKind = switch (entry.kind) {
            0 => .file,
            1 => .directory,
            else => return error.InvalidIndexCache,
        };
        candidates.appendAssumeCapacity(.{
            .path = try alloc.dupe(u8, entry.path),
            .kind = kind,
        });
    }
    return .{
        .written_at_ms = value.written_at_ms,
        .candidates = try candidates.toOwnedSlice(alloc),
    };
}

/// Persists the index for `roots` under `$HOME`. Best-effort by contract:
/// callers log and continue on failure because the in-memory index is
/// already complete.
pub fn save(alloc: Allocator, roots: []const []const u8, candidates: []const Candidate) !void {
    const home = io_mod.getenv("HOME") orelse return;
    return saveTo(alloc, home, roots, candidates);
}

/// Saves under an explicit home directory (tests and non-HOME callers).
pub fn saveTo(alloc: Allocator, home: []const u8, roots: []const []const u8, candidates: []const Candidate) !void {
    if (roots.len == 0) return;
    const path = try cachePath(alloc, home, roots);
    defer alloc.free(path);
    if (candidates.len == 0) {
        // An empty index paints nothing, so never create one. If a prior scan
        // persisted entries and the workspace is now empty, drop the stale
        // file instead of serving ghosts.
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const zio = io_mod.getIo();
    const dir_path = std.Io.Dir.path.dirname(path) orelse return;
    try io_mod.makeDirRecursive(dir_path);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    const writer = &payload.writer;
    try writer.writeAll("{\"written_at_ms\":");
    try writer.print("{d}", .{io_mod.milliTimestamp()});
    try writer.writeAll(",\"roots\":");
    try std.json.Stringify.value(roots, .{}, writer);
    try writer.writeAll(",\"entries\":[");
    var written: usize = 0;
    for (candidates) |candidate| {
        if (candidate.path.len == 0 or candidate.path.len > file_index.max_path_len) continue;
        if (!text_utils.isTerminalSafe(candidate.path)) continue;
        if (written > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(candidate.path, .{}, writer);
        try writer.print(",\"kind\":{d}}}", .{@backingInt(candidate.kind)});
        written += 1;
        if (payload.written().len > max_bytes) return error.IndexCacheTooLarge;
    }
    try writer.writeAll("]}");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(magic);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload.written(), &digest, .{});
    try out.writer.writeAll(&digest);
    try out.writer.writeAll(payload.written());

    // `.iterate` matters on Linux: without it the descriptor is O_PATH and
    // the directory fsync inside durableReplaceVerified fails with EBADF.
    var dir = try std.Io.Dir.openDirAbsolute(zio, dir_path, .{ .follow_symlinks = false, .iterate = true });
    defer dir.close(zio);
    var verified: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &verified, std.Io.Dir.path.basename(path), out.written());
    try dir.setPermissions(zio, .fromMode(0o700));
}

test "file index cache round trips and rejects tampering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const roots = [_][]const u8{"/workspace"};
    const candidates = [_]Candidate{
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "docs", .kind = .directory },
    };

    try std.testing.expect((try loadFrom(alloc, home, &roots)) == null);
    try saveTo(alloc, home, &roots, &candidates);
    var loaded = (try loadFrom(alloc, home, &roots)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.candidates.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.candidates[0].path);
    try std.testing.expectEqual(.directory, loaded.candidates[1].kind);

    // A different scope must never reuse this file.
    const other_roots = [_][]const u8{"/elsewhere"};
    try std.testing.expect((try loadFrom(alloc, home, &other_roots)) == null);

    // Bit flips break the digest and degrade to a rescan.
    const path = try cachePath(alloc, home, &roots);
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "X", magic.len + Sha256.digest_length + 4);
    file.close(std.testing.io);
    try std.testing.expect((try loadFrom(alloc, home, &roots)) == null);

    // Unsafe entries never reach disk: a save of only-unsafe paths produces a
    // valid but empty index, and the next load filters nothing further.
    const evil = [_]Candidate{.{ .path = "bad\x1bpath", .kind = .file }};
    try saveTo(alloc, home, &roots, &evil);
    var empty = (try loadFrom(alloc, home, &roots)).?;
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.candidates.len);

    // An empty scan deletes the persisted index rather than serving ghosts.
    try saveTo(alloc, home, &roots, &.{});
    try std.testing.expect((try loadFrom(alloc, home, &roots)) == null);
}

//! Gzip tar archives that move files between this machine and a sandbox.
//! Building reads only the files it is given. Extracting writes only regular
//! files with safe paths, under one folder.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const sync_plan = @import("sync_plan.zig");

const Allocator = std.mem.Allocator;

pub const BuildError = error{ ArchiveTooLarge, ReadFailed, OutOfMemory };

pub const Extracted = struct {
    written: []const []const u8,
    /// Entries never written: links, devices, unsafe paths, paths not in `allowed`.
    refused: []const []const u8,
};

pub const ExtractError = error{ InvalidArchive, ArchiveTooLarge, WriteFailed, OutOfMemory };

const max_name_bytes = 4096;
const part_suffix = ".fx-part";
const executable_mode: u32 = 0o755;
const plain_mode: u32 = 0o644;
const folder_mode: u32 = 0o755;

/// Options for `build`.
pub const BuildOptions = struct {
    max_bytes: usize,
    /// Store symbolic links as links, with their target text. For uploads
    /// from this machine's own repository; the sandbox side writes them.
    links: bool = false,
};

/// Builds a gzip tar of `paths`, relative to `root`, keeping each file's
/// mode and modification time. A missing path or one that is not a regular
/// file is skipped, and so is a symbolic link unless `options.links` is set.
/// A link is stored with its own target text and is never followed. Fails
/// when the archive would pass `options.max_bytes`. A single file larger than
/// that fails too, before it is compressed.
pub fn build(arena: Allocator, root: []const u8, paths: []const []const u8, options: BuildOptions) BuildError![]u8 {
    const max_bytes = options.max_bytes;
    const zio = io_mod.getIo();
    var root_dir = std.Io.Dir.cwd().openDir(zio, root, .{}) catch return error.ReadFailed;
    defer root_dir.close(zio);

    var gzip = try std.Io.Writer.Allocating.initCapacity(arena, 64);
    var scratch: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&gzip.writer, &scratch, .gzip, .fastest) catch |err| return buildFailure(err);
    var tar: std.tar.Writer = .{ .underlying_writer = &compressor.writer };

    for (paths) |path| {
        if (!sync_plan.safeRelativePath(path) or !parentsExist(root_dir, path)) continue;
        const stat = root_dir.statFile(zio, path, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind == .sym_link) {
            if (!options.links) continue;
            var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const target_len = root_dir.readLink(zio, path, &target_buffer) catch return error.ReadFailed;
            // The link's own text, never the file it points at.
            tar.writeLink(path, target_buffer[0..target_len], .{
                .mtime = @intCast(@max(stat.mtime.toSeconds(), 0)),
            }) catch |err| return buildFailure(err);
            if (gzip.written().len > max_bytes) return error.ArchiveTooLarge;
            continue;
        }
        if (stat.kind != .file) continue;
        var file = root_dir.openFile(zio, path, .{ .follow_symlinks = false }) catch return error.ReadFailed;
        defer file.close(zio);
        const content = io_mod.readFileToEnd(arena, &file, max_bytes) catch |err| return buildFailure(err);
        const mtime: u64 = @intCast(@max(stat.mtime.toSeconds(), 0));
        tar.writeFileBytes(path, content, .{
            .mode = stat.permissions.toMode(),
            .mtime = mtime,
        }) catch |err| return buildFailure(err);
        if (gzip.written().len > max_bytes) return error.ArchiveTooLarge;
    }
    tar.finishPedantically() catch |err| return buildFailure(err);
    compressor.finish() catch |err| return buildFailure(err);
    if (gzip.written().len > max_bytes) return error.ArchiveTooLarge;
    return gzip.written();
}

/// Extracts the regular files of a gzip tar into `dest`. When `allowed` is
/// set, only those paths are written. Each file goes through a temporary
/// file and a rename. Fails when the files pass `max_total_bytes`. Files
/// already written stay.
pub fn extract(
    arena: Allocator,
    archive: []const u8,
    dest: []const u8,
    allowed: ?[]const []const u8,
    max_total_bytes: usize,
) ExtractError!Extracted {
    const zio = io_mod.getIo();
    var dest_dir = std.Io.Dir.cwd().openDir(zio, dest, .{}) catch return error.WriteFailed;
    defer dest_dir.close(zio);

    var input = std.Io.Reader.fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &window);
    var name_buffer: [max_name_bytes]u8 = undefined;
    var link_buffer: [max_name_bytes]u8 = undefined;
    var diagnostics: std.tar.Diagnostics = .{ .allocator = arena };
    var iterator = std.tar.Iterator.init(&decompressor.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
        .diagnostics = &diagnostics,
    });

    const limit: u64 = max_total_bytes;
    var total: u64 = 0;
    var skipped_seen: usize = 0;
    var written: std.ArrayList([]const u8) = .empty;
    var refused: std.ArrayList([]const u8) = .empty;
    while (true) {
        const next = iterator.next() catch |err| return extractFailure(err);
        try takeSkipped(arena, &diagnostics, &skipped_seen, &refused);
        const entry = next orelse break;
        if (entry.kind == .directory) continue;
        const name = try arena.dupe(u8, entry.name);
        if (entry.kind != .file or !sync_plan.safeRelativePath(name) or !isAllowed(allowed, name)) {
            try refused.append(arena, name);
            continue;
        }
        if (total + entry.size > limit) {
            debug_trace.logf("sandbox", "archive extract stopped at the size limit after {d} files", .{written.items.len});
            return error.ArchiveTooLarge;
        }
        if (!try ensureParents(dest_dir, name)) {
            try refused.append(arena, name);
            continue;
        }
        const content = try readContent(arena, &iterator, entry);
        try writeRegular(arena, dest_dir, name, content, fileMode(entry.mode));
        total += entry.size;
        try written.append(arena, name);
    }
    return .{
        .written = try written.toOwnedSlice(arena),
        .refused = try refused.toOwnedSlice(arena),
    };
}

/// The total size of the regular files in a gzip tar, counting only `allowed`
/// paths when set. These are the files `extract` would write, so a caller can
/// check a size limit from the headers before any write. No content is read.
pub fn regularFileBytes(arena: Allocator, archive: []const u8, allowed: ?[]const []const u8) ExtractError!u64 {
    var input = std.Io.Reader.fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &window);
    var name_buffer: [max_name_bytes]u8 = undefined;
    var link_buffer: [max_name_bytes]u8 = undefined;
    var diagnostics: std.tar.Diagnostics = .{ .allocator = arena };
    var iterator = std.tar.Iterator.init(&decompressor.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
        .diagnostics = &diagnostics,
    });
    var total: u64 = 0;
    while (true) {
        const next = iterator.next() catch |err| return extractFailure(err);
        const entry = next orelse break;
        if (entry.kind != .file or !sync_plan.safeRelativePath(entry.name) or !isAllowed(allowed, entry.name)) continue;
        total += entry.size;
    }
    return total;
}

fn isAllowed(allowed: ?[]const []const u8, name: []const u8) bool {
    const list = allowed orelse return true;
    for (list) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Refuses the entries the iterator skipped, such as hard links and devices.
fn takeSkipped(
    arena: Allocator,
    diagnostics: *const std.tar.Diagnostics,
    seen: *usize,
    refused: *std.ArrayList([]const u8),
) Allocator.Error!void {
    while (seen.* < diagnostics.errors.items.len) : (seen.* += 1) {
        switch (diagnostics.errors.items[seen.*]) {
            .unsupported_file_type => |skipped| try refused.append(arena, skipped.file_name),
            else => {},
        }
    }
}

/// True when every folder above `path` under `dir` is a real folder. Never
/// creates anything, so a missing folder makes the path missing.
fn parentsExist(dir: std.Io.Dir, path: []const u8) bool {
    const zio = io_mod.getIo();
    var index: usize = 0;
    while (std.mem.findScalarPos(u8, path, index, '/')) |slash| : (index = slash + 1) {
        const stat = dir.statFile(zio, path[0..slash], .{ .follow_symlinks = false }) catch return false;
        if (stat.kind != .directory) return false;
    }
    return true;
}

/// Makes each folder above `path` under `dir` as needed. False when one of
/// them is a symbolic link, or is not a folder: the entry is then refused.
fn ensureParents(dir: std.Io.Dir, path: []const u8) ExtractError!bool {
    const zio = io_mod.getIo();
    var index: usize = 0;
    while (std.mem.findScalarPos(u8, path, index, '/')) |slash| : (index = slash + 1) {
        const parent = path[0..slash];
        const stat = dir.statFile(zio, parent, .{ .follow_symlinks = false }) catch |err| {
            if (err != error.FileNotFound) return false;
            dir.createDir(zio, parent, std.Io.File.Permissions.fromMode(folder_mode)) catch return error.WriteFailed;
            continue;
        };
        if (stat.kind != .directory) return false;
    }
    return true;
}

fn readContent(arena: Allocator, iterator: *std.tar.Iterator, entry: std.tar.Iterator.File) ExtractError![]u8 {
    var content = try std.Io.Writer.Allocating.initCapacity(arena, 256);
    iterator.streamRemaining(entry, &content.writer) catch |err| return extractFailure(err);
    return content.written();
}

fn fileMode(tar_mode: u32) u32 {
    return if ((tar_mode & 0o111) != 0) executable_mode else plain_mode;
}

/// Writes `bytes` to `name` under `dir` through a `.fx-part` file, then renames
/// it over `name`. The part file is removed on any error. The part is deleted
/// before the create, and the create is exclusive, so a link is never followed.
fn writeRegular(arena: Allocator, dir: std.Io.Dir, name: []const u8, bytes: []const u8, mode: u32) ExtractError!void {
    const zio = io_mod.getIo();
    const part = try arena.print("{s}{s}", .{ name, part_suffix });
    dir.deleteFile(zio, part) catch {};
    var renamed = false;
    defer if (!renamed) dir.deleteFile(zio, part) catch {};
    {
        var file = dir.createFile(zio, part, .{
            .truncate = true,
            .exclusive = true,
            // `mode_t` is u16 on macOS and u32 on Linux; the mode is 0o644 or 0o755.
            .permissions = std.Io.File.Permissions.fromMode(@intCast(mode)),
        }) catch return error.WriteFailed;
        defer file.close(zio);
        file.writeStreamingAll(zio, bytes) catch return error.WriteFailed;
        file.sync(zio) catch return error.WriteFailed;
    }
    dir.rename(part, dir, name, zio) catch return error.WriteFailed;
    renamed = true;
}

fn extractFailure(err: anyerror) ExtractError {
    return switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        else => error.InvalidArchive,
    };
}

fn buildFailure(err: anyerror) BuildError {
    return switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        error.StreamTooLong => error.ArchiveTooLarge,
        else => error.ReadFailed,
    };
}

// ---- tests ----

const testing = std.testing;

/// Gzips `plain` the way the flate tests do.
fn gzipForTest(arena: Allocator, plain: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(arena, 64);
    var scratch: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out.writer, &scratch, .gzip, .fastest);
    try compressor.writer.writeAll(plain);
    try compressor.finish();
    return out.written();
}

/// A hard-link entry. `std.tar.Writer` cannot write one, so the type byte is set by hand.
fn writeHardLinkEntry(out: *std.Io.Writer, name: []const u8, target: []const u8) !void {
    var header = std.tar.Writer.Header.init(.regular);
    std.mem.asBytes(&header)[@offsetOf(std.tar.Writer.Header, "typeflag")] = '1';
    try header.setPath("", name);
    try header.setLinkname(target);
    // `write` computes the checksum itself. Calling `updateChecksum` first
    // would sum the digits it left behind, and the reader would reject it.
    try header.write(out);
}

fn writeExecutable(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try dir.createFile(zio, name, .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
    defer file.close(zio);
    try file.writeStreamingAll(zio, data);
}

fn readAt(arena: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try dir.openFile(zio, name, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 1 << 20);
}

fn modeAt(dir: std.Io.Dir, name: []const u8) !u32 {
    const stat = try dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false });
    return stat.permissions.toMode();
}

fn existsAt(dir: std.Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch return false;
    return true;
}

test "an archive round-trips files, modes, and folders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    try src.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "alpha\n" });
    try src.dir.createDir(zio, "bin", std.Io.File.Permissions.fromMode(0o755));
    try writeExecutable(src.dir, "bin/run.sh", "#!/bin/sh\necho hi\n");
    try src.dir.createDir(zio, "deep", std.Io.File.Permissions.fromMode(0o755));
    try src.dir.createDir(zio, "deep/x", std.Io.File.Permissions.fromMode(0o755));
    try src.dir.writeFile(zio, .{ .sub_path = "deep/x/y.txt", .data = "why\n" });
    const archive = try build(arena, src_root, &.{ "a.txt", "bin/run.sh", "deep/x/y.txt" }, .{ .max_bytes = 1 << 20 });

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    const result = try extract(arena, archive, dst_root, null, 1 << 20);
    try testing.expectEqual(@as(usize, 3), result.written.len);
    try testing.expectEqual(@as(usize, 0), result.refused.len);
    try testing.expectEqualStrings("alpha\n", try readAt(arena, dst.dir, "a.txt"));
    try testing.expectEqualStrings("#!/bin/sh\necho hi\n", try readAt(arena, dst.dir, "bin/run.sh"));
    try testing.expectEqualStrings("why\n", try readAt(arena, dst.dir, "deep/x/y.txt"));

    const run_mode = try modeAt(dst.dir, "bin/run.sh");
    try testing.expect((run_mode & 0o111) != 0);
    const plain_mode_bits = try modeAt(dst.dir, "a.txt");
    try testing.expectEqual(@as(u32, 0), plain_mode_bits & 0o111);
}

test "build skips missing paths and folders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    try src.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "alpha\n" });
    try src.dir.createDir(zio, "deep", std.Io.File.Permissions.fromMode(0o755));
    try src.dir.writeFile(zio, .{ .sub_path = "deep/x.txt", .data = "x\n" });
    const archive = try build(arena, src_root, &.{ "a.txt", "missing.txt", "deep" }, .{ .max_bytes = 1 << 20 });

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    const result = try extract(arena, archive, dst_root, null, 1 << 20);
    try testing.expectEqual(@as(usize, 1), result.written.len);
    try testing.expectEqualStrings("a.txt", result.written[0]);
    try testing.expectEqual(@as(usize, 0), result.refused.len);
}

test "build stops at the size limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    const big: [10 * 1024]u8 = @splat(0);
    try src.dir.writeFile(zio, .{ .sub_path = "big.bin", .data = &big });
    try testing.expectError(error.ArchiveTooLarge, build(arena, src_root, &.{"big.bin"}, .{ .max_bytes = 1024 }));
}

test "build stops when the compressed archive passes the limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    // Each file gets its own random bytes. Random bytes do not compress, so
    // the archive grows past the limit while each file alone still fits it.
    // Copies of one block would compress to about one file's size.
    var noise: [1000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const names = [_][]const u8{ "n1.bin", "n2.bin", "n3.bin", "n4.bin" };
    for (names) |name| {
        prng.random().bytes(&noise);
        try src.dir.writeFile(zio, .{ .sub_path = name, .data = &noise });
    }
    try testing.expectError(error.ArchiveTooLarge, build(arena, src_root, &names, .{ .max_bytes = 2048 }));
}

test "extract writes only allowed paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    try src.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "a\n" });
    try src.dir.writeFile(zio, .{ .sub_path = "b.txt", .data = "b\n" });
    const archive = try build(arena, src_root, &.{ "a.txt", "b.txt" }, .{ .max_bytes = 1 << 20 });

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    const only_a: []const []const u8 = &.{"a.txt"};
    const result = try extract(arena, archive, dst_root, only_a, 1 << 20);
    try testing.expectEqual(@as(usize, 1), result.written.len);
    try testing.expectEqualStrings("a.txt", result.written[0]);
    try testing.expectEqual(@as(usize, 1), result.refused.len);
    try testing.expectEqualStrings("b.txt", result.refused[0]);
    try testing.expect(existsAt(dst.dir, "a.txt"));
    try testing.expect(!existsAt(dst.dir, "b.txt"));
}

test "extract refuses unsafe paths and links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var tar_out = try std.Io.Writer.Allocating.initCapacity(arena, 64);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    try tar.writeFileBytes("../evil.txt", "x", .{});
    try tar.writeFileBytes("/abs.txt", "x", .{});
    try tar.writeFileBytes(".git/config", "x", .{});
    try tar.writeLink("link", "/etc/passwd", .{});
    try writeHardLinkEntry(&tar_out.writer, "hard", "ok.txt");
    try tar.writeFileBytes("ok.txt", "ok\n", .{});
    try tar.finishPedantically();
    const archive = try gzipForTest(arena, tar_out.written());

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    const result = try extract(arena, archive, dst_root, null, 1 << 20);
    try testing.expectEqual(@as(usize, 1), result.written.len);
    try testing.expectEqualStrings("ok.txt", result.written[0]);
    try testing.expectEqual(@as(usize, 5), result.refused.len);
    try testing.expectEqualStrings("../evil.txt", result.refused[0]);
    try testing.expectEqualStrings("/abs.txt", result.refused[1]);
    try testing.expectEqualStrings(".git/config", result.refused[2]);
    try testing.expectEqualStrings("link", result.refused[3]);
    try testing.expectEqualStrings("hard", result.refused[4]);

    // Nothing was written outside `dest`, through a link, or as a link.
    const outside_evil = try arena.print("{s}/../evil.txt", .{dst_root});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(zio, outside_evil, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(zio, "/abs.txt", .{}));
    try testing.expect(!existsAt(dst.dir, ".git/config"));
    try testing.expect(!existsAt(dst.dir, "link"));
    try testing.expect(!existsAt(dst.dir, "hard"));
}

test "extract never writes through a linked folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    const other_root = try io_mod.dirRealpathAlloc(arena, other.dir, ".");

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    try dst.dir.symLink(zio, other_root, "out", .{ .is_directory = true });

    var tar_out = try std.Io.Writer.Allocating.initCapacity(arena, 64);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    try tar.writeFileBytes("out/x.txt", "x\n", .{});
    try tar.finishPedantically();
    const archive = try gzipForTest(arena, tar_out.written());

    const result = try extract(arena, archive, dst_root, null, 1 << 20);
    try testing.expectEqual(@as(usize, 0), result.written.len);
    try testing.expectEqual(@as(usize, 1), result.refused.len);
    try testing.expectEqualStrings("out/x.txt", result.refused[0]);
    try testing.expect(!existsAt(other.dir, "x.txt"));

    var listing = try other.dir.openDir(zio, ".", .{ .iterate = true });
    defer listing.close(zio);
    var it = listing.iterate();
    try testing.expect((try it.next(zio)) == null);
}

test "extract replaces a file without leaving parts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    try dst.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "old" });

    var tar_out = try std.Io.Writer.Allocating.initCapacity(arena, 64);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    try tar.writeFileBytes("a.txt", "new\n", .{});
    try tar.finishPedantically();
    const archive = try gzipForTest(arena, tar_out.written());

    const result = try extract(arena, archive, dst_root, null, 1 << 20);
    try testing.expectEqual(@as(usize, 1), result.written.len);
    try testing.expectEqualStrings("new\n", try readAt(arena, dst.dir, "a.txt"));
    try testing.expect(!existsAt(dst.dir, "a.txt.fx-part"));
}

test "extract stops at the size limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const kib: [1024]u8 = @splat(0);
    var tar_out = try std.Io.Writer.Allocating.initCapacity(arena, 64);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    try tar.writeFileBytes("a.bin", &kib, .{});
    try tar.writeFileBytes("b.bin", &kib, .{});
    try tar.finishPedantically();
    const archive = try gzipForTest(arena, tar_out.written());

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    try testing.expectError(error.ArchiveTooLarge, extract(arena, archive, dst_root, null, 1500));
    // The first file was already written, and it stays.
    try testing.expect(existsAt(dst.dir, "a.bin"));
    try testing.expect(!existsAt(dst.dir, "b.bin"));
    try testing.expect(!existsAt(dst.dir, "b.bin.fx-part"));
}

/// One entry of an archive, copied out of the iterator's reused buffers.
const Listed = struct {
    name: []const u8,
    kind: std.tar.FileKind,
    link_name: []const u8,
};

/// Lists the entries of a gzip tar, for tests.
fn listArchive(arena: Allocator, archive: []const u8) ![]Listed {
    var input = std.Io.Reader.fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &window);
    var name_buffer: [max_name_bytes]u8 = undefined;
    var link_buffer: [max_name_bytes]u8 = undefined;
    var iterator = std.tar.Iterator.init(&decompressor.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var listed: std.ArrayList(Listed) = .empty;
    while (try iterator.next()) |entry| {
        try listed.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .kind = entry.kind,
            .link_name = try arena.dupe(u8, entry.link_name),
        });
    }
    return listed.toOwnedSlice(arena);
}

fn findListed(listed: []const Listed, name: []const u8) ?Listed {
    for (listed) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

test "regularFileBytes counts only allowed regular files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const src = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    try tmp.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "0123456789" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "b.txt", .data = "bbbbbbbbbbbbbbbbbbbb" });
    try tmp.dir.symLink(zio, "a.txt", "l", .{});
    const bytes = try build(arena, src, &.{ "a.txt", "b.txt", "l" }, .{ .max_bytes = 1 << 20, .links = true });

    try testing.expectEqual(@as(u64, 30), try regularFileBytes(arena, bytes, null));
    try testing.expectEqual(@as(u64, 10), try regularFileBytes(arena, bytes, &.{"a.txt"}));
    try testing.expectEqual(@as(u64, 0), try regularFileBytes(arena, bytes, &.{"l"}));
}

test "build keeps links when asked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    try src.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "one\n" });
    try src.dir.symLink(zio, "a.txt", "l", .{ .is_directory = false });

    const with_links = try build(arena, src_root, &.{ "a.txt", "l" }, .{ .max_bytes = 1 << 20, .links = true });
    const kept = try listArchive(arena, with_links);
    const link = findListed(kept, "l") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(std.tar.FileKind.sym_link, link.kind);
    try testing.expectEqualStrings("a.txt", link.link_name);
    const file = findListed(kept, "a.txt") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(std.tar.FileKind.file, file.kind);

    const without_links = try build(arena, src_root, &.{ "a.txt", "l" }, .{ .max_bytes = 1 << 20 });
    const skipped = try listArchive(arena, without_links);
    try testing.expectEqual(@as(usize, 1), skipped.len);
    try testing.expectEqualStrings("a.txt", skipped[0].name);
}

test "extract still refuses links from a built archive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    const src_root = try io_mod.dirRealpathAlloc(arena, src.dir, ".");
    try src.dir.writeFile(zio, .{ .sub_path = "a.txt", .data = "one\n" });
    try src.dir.symLink(zio, "a.txt", "l", .{ .is_directory = false });
    const archive = try build(arena, src_root, &.{ "a.txt", "l" }, .{ .max_bytes = 1 << 20, .links = true });

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_root = try io_mod.dirRealpathAlloc(arena, dst.dir, ".");
    const result = try extract(arena, archive, dst_root, null, 1 << 20);
    try testing.expectEqual(@as(usize, 1), result.written.len);
    try testing.expectEqualStrings("a.txt", result.written[0]);
    try testing.expectEqual(@as(usize, 1), result.refused.len);
    try testing.expectEqualStrings("l", result.refused[0]);
    try testing.expectEqualStrings("one\n", try readAt(arena, dst.dir, "a.txt"));
    try testing.expect(!existsAt(dst.dir, "l"));
}

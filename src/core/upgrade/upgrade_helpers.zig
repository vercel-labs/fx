const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const update_target = @import("update_target.zig");

const Allocator = std.mem.Allocator;

const recv_timeout_sec: i64 = 30;
const latest_version_max_bytes: usize = 128;
const checksum_max_bytes: usize = 4096;

const Channel = update_target.Channel;
const Target = update_target.Target;

fn setRecvTimeout(conn: *std.http.Client.Connection) void {
    const sock = conn.stream_writer.stream.socket.handle;
    const timeout = std.posix.timeval{ .sec = recv_timeout_sec, .usec = 0 };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
}

pub const cdn_base = "https://releases.fx.sh";

pub fn resolveCdnBase() []const u8 {
    if (io_mod.getenv("FX_E2E_UPGRADE_BASE_URL")) |url| {
        if (isLoopbackE2eUpgradeBase(url)) return url;
    }
    return cdn_base;
}

fn isLoopbackE2eUpgradeBase(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null or
        !uri.path.isEmpty() or
        uri.query != null or
        uri.fragment != null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1");
}

pub const platform = platformFromTarget() orelse blk: {
    if (builtin.os.tag == .windows) break :blk "windows-x86_64";
    @compileError("unsupported platform for auto-upgrade (requires macOS or Linux, x86_64 or aarch64)");
};

fn platformFromTarget() ?[]const u8 {
    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => null,
    };
    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => null,
    };
    if (os) |o| {
        if (arch) |a| {
            return o ++ "-" ++ a;
        }
    }
    return null;
}

pub fn fetchTarget(alloc: Allocator, channel: Channel, base_url: []const u8) !Target {
    return switch (channel) {
        .stable => blk: {
            const latest = try fetchLatestVersion(alloc, base_url);
            defer alloc.free(latest);
            break :blk Target.initStable(alloc, latest) catch return error.FetchFailed;
        },
        .dev => blk: {
            var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
            defer client.deinit();
            const url = try std.fmt.allocPrint(alloc, "{s}/dev.json", .{base_url});
            defer alloc.free(url);
            const manifest = try fetchTextBounded(
                &client,
                alloc,
                url,
                update_target.max_manifest_bytes,
            );
            defer alloc.free(manifest);
            break :blk Target.parseDevManifest(alloc, manifest) catch return error.FetchFailed;
        },
    };
}

fn fetchLatestVersion(alloc: Allocator, base_url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const url = try std.fmt.allocPrint(alloc, "{s}/latest.txt", .{base_url});
    defer alloc.free(url);

    const raw = try fetchTextBounded(
        &client,
        alloc,
        url,
        latest_version_max_bytes,
    );
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == raw.len) return raw;

    const duped = try alloc.dupe(u8, trimmed);
    alloc.free(raw);
    return duped;
}

fn fetchTextBounded(
    client: *std.http.Client,
    alloc: Allocator,
    url: []const u8,
    max_bytes: usize,
) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.FetchFailed;

    var req = client.request(.GET, uri, .{}) catch return error.FetchFailed;
    defer req.deinit();

    if (req.connection) |conn| setRecvTimeout(conn);
    req.sendBodiless() catch return error.FetchFailed;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.FetchFailed;
    if (response.head.status != .ok) return error.FetchFailed;
    if (response.head.content_length) |content_length| {
        if (content_length > max_bytes) return error.FetchFailed;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = body_reader.readSliceShort(&chunk) catch return error.FetchFailed;
        if (n == 0) break;
        if (n > max_bytes -| out.writer.buffered().len) return error.FetchFailed;
        out.writer.writeAll(chunk[0..n]) catch return error.FetchFailed;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub const DownloadProgress = struct {
    ctx: *anyopaque,
    start: *const fn (*anyopaque, ?u64) void,
    update: *const fn (*anyopaque, u64, ?u64) void,
};

pub fn downloadFileStreaming(client: *std.http.Client, url: []const u8, dest_path: []const u8) !void {
    return downloadFileStreamingWithProgress(client, url, dest_path, null);
}

pub fn downloadFileStreamingWithProgress(client: *std.http.Client, url: []const u8, dest_path: []const u8, progress: ?DownloadProgress) !void {
    var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), dest_path, .{}) catch return error.DownloadFailed;
    defer file.close(io_mod.getIo());

    var write_buf: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .initStreaming(file, io_mod.getIo(), &write_buf);

    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var req = client.request(.GET, uri, .{}) catch return error.DownloadFailed;
    defer req.deinit();

    if (req.connection) |conn| setRecvTimeout(conn);
    req.sendBodiless() catch return error.DownloadFailed;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.DownloadFailed;
    if (response.head.status != .ok) return error.DownloadFailed;

    const total = response.head.content_length;
    if (progress) |p| p.start(p.ctx, total);

    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var copy_buf: [64 * 1024]u8 = undefined;
    var downloaded: u64 = 0;
    while (true) {
        const n = body_reader.readSliceShort(&copy_buf) catch return error.DownloadFailed;
        if (n == 0) break;
        file_writer.interface.writeAll(copy_buf[0..n]) catch return error.DownloadFailed;
        downloaded += n;
        if (progress) |p| p.update(p.ctx, downloaded, total);
    }

    file_writer.interface.flush() catch return error.DownloadFailed;
}

pub fn verifyChecksum(client: *std.http.Client, file_path: []const u8, checksum_url: []const u8) !void {
    const raw = fetchTextBounded(
        client,
        client.allocator,
        checksum_url,
        checksum_max_bytes,
    ) catch return error.ChecksumFetchFailed;
    defer client.allocator.free(raw);

    const expected_hex = extractChecksumHex(raw) orelse return error.ChecksumMismatch;
    if (expected_hex.len != 64) return error.ChecksumMismatch;

    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), file_path, .{}) catch return error.ChecksumMismatch;
    defer file.close(io_mod.getIo());

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var rbuf: [8192]u8 = undefined;
    var r = file.readerStreaming(io_mod.getIo(), &rbuf);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return error.ChecksumMismatch;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    const digest = hasher.finalResult();
    const actual_hex = bytesToHex(&digest);

    if (!std.mem.eql(u8, &actual_hex, expected_hex)) return error.ChecksumMismatch;
}

fn bytesToHex(bytes: *const [32]u8) [64]u8 {
    const charset = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

fn extractChecksumHex(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.findScalar(u8, trimmed, ' ')) |space_idx| {
        return trimmed[0..space_idx];
    }
    return if (trimmed.len >= 64) trimmed[0..64] else null;
}

pub fn extractTarGz(alloc: Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    const tar_path = if (comptime builtin.os.tag == .windows)
        windowsTarPath(alloc) catch return error.TarNotAvailable
    else
        "tar";
    defer if (comptime builtin.os.tag == .windows) alloc.free(tar_path);
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ tar_path, "-xzf", archive_path, "-C", dest_dir },
    }) catch return error.ExtractionFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ExtractionFailed,
        else => return error.ExtractionFailed,
    }
}

fn windowsTarPath(alloc: Allocator) ![]u8 {
    const system_path = "C:\\Windows\\System32\\tar.exe";
    if (std.Io.Dir.accessAbsolute(io_mod.getIo(), system_path, .{})) {
        return try alloc.dupe(u8, system_path);
    } else |_| {}

    const path_env = io_mod.getenv("Path") orelse io_mod.getenv("PATH") orelse return error.NotFound;
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = std.fs.path.join(alloc, &.{ entry, "tar.exe" }) catch continue;
        if (std.Io.Dir.accessAbsolute(io_mod.getIo(), candidate, .{})) {
            return candidate;
        } else |_| {
            alloc.free(candidate);
        }
    }
    return error.NotFound;
}

pub fn replaceBinary(alloc: Allocator, new_path: []const u8, target_path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        // On Windows, the running fx.exe cannot be renamed or unlinked while
        // it is executing. Use the stdlib's atomic copy which uses Windows'
        // ReplaceFile / MoveFileEx under the hood, so the running process
        // keeps the old image in memory and the next launch reads the fresh
        // bytes from disk. The temp file is left next to the target for the
        // atomic-swap step to consume.
        const cwd = std.Io.Dir.cwd();
        std.Io.Dir.copyFile(cwd, new_path, cwd, target_path, io_mod.getIo(), .{
            .replace = true,
        }) catch return error.ReplaceFailed;
        return;
    }
    std.Io.Dir.renameAbsolute(new_path, target_path, io_mod.getIo()) catch {
        copyBinary(new_path, target_path) catch return error.ReplaceFailed;
        return;
    };
    _ = alloc;
}

/// Extract `entry_name` from a ZIP archive at `archive_path` into `dest_dir`.
///
/// This is a minimal in-process ZIP reader for the v1 self-upgrade path on
/// Windows (and any future platform that distributes `.zip` artifacts). It
/// supports only the cases fx actually ships:
///
///  * compression method 0 (stored) — no DEFLATE / bzip2 / LZMA
///  * single- or multi-entry archives with a deterministic entry order
///  * no zip64, no encryption, no data descriptors
///
/// The reader scans the archive linearly for `PK\x03\x04` Local File Headers,
/// reads the filename, and copies the entry body to `<dest_dir>/<name>` when
/// `name == entry_name`. The End of Central Directory record terminates the
/// scan.
pub fn extractZipEntry(
    alloc: Allocator,
    archive_path: []const u8,
    dest_dir: []const u8,
    entry_name: []const u8,
) !void {
    const zio = io_mod.getIo();
    const file = std.Io.Dir.openFileAbsolute(zio, archive_path, .{}) catch
        return error.ExtractionFailed;
    defer file.close(zio);
    var reader_buf: [16 * 1024]u8 = undefined;
    var reader_holder = file.readerStreaming(zio, &reader_buf);
    const reader = &reader_holder.interface;

    const local_file_header_sig: u32 = 0x04034b50;
    const central_dir_sig: u32 = 0x02014b50;
    const eocd_sig: u32 = 0x06054b50;
    var extracted = false;

    while (true) {
        const sig = try readU32Le(reader);
        if (sig == eocd_sig) break;
        if (sig == central_dir_sig) {
            // Central directory header: 24 fixed bytes after the version /
            // attribs / sizes (which are 42 bytes from the sig), then a
            // filename + extra + comment block.
            try reader.discardAll(24);
            const name_len = try readU16Le(reader);
            const extra_len = try readU16Le(reader);
            const comment_len = try readU16Le(reader);
            const total: u64 = @as(u64, name_len) + @as(u64, extra_len) + @as(u64, comment_len);
            try reader.discardAll64(total);
            continue;
        }
        if (sig != local_file_header_sig) return error.ExtractionFailed;

        // Local file header. Body is 26 fixed bytes after the 4-byte sig.
        try reader.discardAll(2 + 2); // version needed, flags
        const method = try readU16Le(reader);
        try reader.discardAll(2 + 2); // mtime, mdate
        try reader.discardAll(4); // crc32
        const compressed_size = try readU32Le(reader);
        try reader.discardAll(4); // uncompressed size
        const name_len = try readU16Le(reader);
        const extra_len = try readU16Le(reader);
        if (method != 0) return error.UnsupportedCompression;
        const name = try reader.readAlloc(alloc, name_len);
        defer alloc.free(name);
        try reader.discardAll(extra_len);

        if (std.mem.eql(u8, name, entry_name)) {
            const out_path = try std.fs.path.join(alloc, &.{ dest_dir, entry_name });
            defer alloc.free(out_path);
            const out = std.Io.Dir.createFileAbsolute(zio, out_path, .{}) catch
                return error.ExtractionFailed;
            defer out.close(zio);
            var out_buf: [16 * 1024]u8 = undefined;
            var out_holder = out.writerStreaming(zio, &out_buf);
            const out_writer = &out_holder.interface;
            _ = try reader.stream(out_writer, std.Io.Limit.limited(@as(u64, compressed_size)));
            try out_writer.flush();
            extracted = true;
        } else {
            try reader.discardAll(compressed_size);
        }
    }
    if (!extracted) return error.EntryNotFound;
}

fn readU16Le(reader: *std.Io.Reader) !u16 {
    var buf: [2]u8 = undefined;
    try reader.readSliceAll(&buf);
    return std.mem.readInt(u16, &buf, .little);
}

fn readU32Le(reader: *std.Io.Reader) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readSliceAll(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

pub const ExecutablePathError = error{
    SelfExeNotFound,
    PathTooLong,
};

pub fn currentExecutablePath(out: []u8) ExecutablePathError![]const u8 {
    const n = std.process.executablePath(io_mod.getIo(), out) catch |err| switch (err) {
        error.NameTooLong => return error.PathTooLong,
        else => return error.SelfExeNotFound,
    };
    const path = out[0..n];
    const linux_deleted_suffix = " (deleted)";
    if (builtin.os.tag == .linux and std.mem.endsWith(u8, path, linux_deleted_suffix)) {
        return path[0 .. path.len - linux_deleted_suffix.len];
    }
    return path;
}

fn copyBinary(src_path: []const u8, dest_path: []const u8) !void {
    const zio = io_mod.getIo();
    var src = std.Io.Dir.openFileAbsolute(zio, src_path, .{}) catch return error.ReplaceFailed;
    defer src.close(zio);

    const stat = src.stat(zio) catch return error.ReplaceFailed;

    std.Io.Dir.deleteFileAbsolute(zio, dest_path) catch {};

    var dest = std.Io.Dir.createFileAbsolute(zio, dest_path, .{}) catch return error.ReplaceFailed;
    defer dest.close(zio);

    var rbuf: [8192]u8 = undefined;
    var r = src.readerStreaming(zio, &rbuf);
    var transfer_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&transfer_buf) catch return error.ReplaceFailed;
        if (n == 0) break;
        dest.writeStreamingAll(zio, transfer_buf[0..n]) catch return error.ReplaceFailed;
    }

    dest.setPermissions(zio, stat.permissions) catch {};
}

fn writeTempFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), name, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

test "platform string is valid" {
    try std.testing.expect(platform.len > 0);
    try std.testing.expect(std.mem.find(u8, platform, "-") != null);
}

test "E2E upgrade base accepts only explicit IPv4 loopback origins" {
    try std.testing.expect(isLoopbackE2eUpgradeBase("http://127.0.0.1:1234"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("https://127.0.0.1:1234"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("http://127.0.0.1"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("http://127.0.0.1:80@example.com"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("http://localhost:1234"));
}

test "production upgrade base uses the fx release domain" {
    try std.testing.expectEqualStrings("https://releases.fx.sh", resolveCdnBase());
}

test "extractChecksumHex parses sha256sum format" {
    const with_filename = "abc123def456  fx-macos-aarch64.tar.gz\n";
    const hex = extractChecksumHex(with_filename).?;
    try std.testing.expectEqualStrings("abc123def456", hex);
}

test "extractChecksumHex parses raw hex" {
    const raw = "a" ** 64 ++ "\n";
    const hex = extractChecksumHex(raw).?;
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    try std.testing.expectEqualStrings("a" ** 64, hex);
}

test "extractChecksumHex rejects short raw checksum" {
    try std.testing.expect(extractChecksumHex("abcd\n") == null);
}

test "bytesToHex renders lowercase sha256 digest" {
    const bytes = [_]u8{0x0f} ** 32;
    const hex = bytesToHex(&bytes);
    try std.testing.expectEqualStrings("0f" ** 32, &hex);
}

test "replaceBinary moves replacement over target path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(tmp.dir, "fx-old", "old");
    try writeTempFile(tmp.dir, "fx-new", "new");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const new_path = try std.fs.path.join(alloc, &.{ root, "fx-new" });
    defer alloc.free(new_path);
    const target_path = try std.fs.path.join(alloc, &.{ root, "fx-old" });
    defer alloc.free(target_path);

    try replaceBinary(new_path, target_path);

    const replaced = try readAbsoluteFile(alloc, target_path);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("new", replaced);
}

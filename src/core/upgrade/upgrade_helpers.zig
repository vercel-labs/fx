const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const update_target = @import("update_target.zig");
const text_utils = @import("../shared/text_utils.zig");

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

pub const platform = platformFromTarget() orelse
    @compileError("unsupported platform for auto-upgrade (requires macOS or Linux, x86_64 or aarch64)");

fn platformFromTarget() ?[]const u8 {
    const os: ?[]const u8 = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => null,
    };
    const arch: ?[]const u8 = switch (builtin.target.cpu.arch) {
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

pub fn fetchTarget(alloc: Allocator, channel: Channel, base_url: []const u8, control: TransferControl) !Target {
    return switch (channel) {
        .stable => blk: {
            const latest = try fetchLatestVersion(alloc, base_url, control);
            defer alloc.free(latest);
            break :blk Target.initStable(alloc, latest) catch return error.FetchFailed;
        },
        .dev => blk: {
            var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
            defer client.deinit();
            const url = try alloc.print("{s}/dev.json", .{base_url});
            defer alloc.free(url);
            const manifest = try fetchTextBounded(
                &client,
                alloc,
                url,
                update_target.max_manifest_bytes,
                control,
            );
            defer alloc.free(manifest);
            break :blk Target.parseDevManifest(alloc, manifest) catch return error.FetchFailed;
        },
    };
}

fn fetchLatestVersion(alloc: Allocator, base_url: []const u8, control: TransferControl) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const url = try alloc.print("{s}/latest.txt", .{base_url});
    defer alloc.free(url);

    const raw = try fetchTextBounded(
        &client,
        alloc,
        url,
        latest_version_max_bytes,
        control,
    );
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == raw.len) return raw;

    const duped = try alloc.dupe(u8, trimmed);
    alloc.free(raw);
    return duped;
}

pub fn cancelRequested(cancel: ?*const std.atomic.Value(bool)) bool {
    return if (cancel) |flag| flag.load(.acquire) else false;
}

/// Lets one thread interrupt another thread's blocking transfer read. The
/// transfer publishes its socket before first use and clears it before the
/// socket can be closed, both under the mutex, so interrupt() always acts on
/// a live socket or none at all.
pub const TransferInterrupt = struct {
    mutex: std.Io.Mutex = .init,
    handle: ?std.Io.net.Socket.Handle = null,

    pub fn publish(self: *TransferInterrupt, handle: std.Io.net.Socket.Handle) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.handle = handle;
    }

    pub fn clear(self: *TransferInterrupt) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.handle = null;
    }

    pub fn interrupt(self: *TransferInterrupt) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const handle = self.handle orelse return;
        zio.vtable.netShutdown(zio.userdata, handle, .both) catch {};
    }
};

pub const TransferControl = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    interrupt: ?*TransferInterrupt = null,
};

fn controlCancelled(control: TransferControl) bool {
    return cancelRequested(control.cancel);
}

/// Registers the request socket with the interrupt slot; the matching clear
/// runs before the request (and its connection) can be torn down.
fn publishConnection(
    control: TransferControl,
    req: *std.http.Client.Request,
) void {
    const slot = control.interrupt orelse return;
    const conn = req.connection orelse return;
    slot.publish(conn.stream_writer.stream.socket.handle);
}

fn clearConnection(control: TransferControl) void {
    const slot = control.interrupt orelse return;
    slot.clear();
}

test "transfer interrupt wakes a blocked socket read" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    const zio = io_mod.getIo();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(zio, .{});
    defer server.deinit(zio);

    const Ctx = struct {
        server: *std.Io.net.Server,
        slot: *TransferInterrupt,
        woke_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    };
    var slot: TransferInterrupt = .{};
    var ctx: Ctx = .{ .server = &server, .slot = &slot };
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            const z = io_mod.getIo();
            const conn = c.server.accept(z) catch return;
            defer conn.close(z);
            c.slot.publish(conn.socket.handle);
            defer c.slot.clear();
            var buf: [16]u8 = undefined;
            var stream_reader = conn.reader(z, &buf);
            // Blocks until the interrupt shuts the socket down.
            _ = stream_reader.interface.takeByte() catch {};
            c.woke_ms.store(io_mod.milliTimestamp(), .release);
        }
    }.run, .{&ctx});

    const client = try server.socket.address.connect(zio, .{ .mode = .stream });
    defer client.close(zio);

    const started_ms = io_mod.milliTimestamp();
    io_mod.sleep(100 * std.time.ns_per_ms);
    slot.interrupt();
    reader.join();
    const woke_ms = ctx.woke_ms.load(.acquire);
    try std.testing.expect(woke_ms != 0);
    try std.testing.expect(woke_ms - started_ms < 2000);

    // Interrupting an idle slot is a no-op.
    slot.interrupt();
}

fn fetchTextBounded(
    client: *std.http.Client,
    alloc: Allocator,
    url: []const u8,
    max_bytes: usize,
    control: TransferControl,
) ![]u8 {
    if (controlCancelled(control)) return error.Cancelled;
    const uri = std.Uri.parse(url) catch return error.FetchFailed;

    var req = client.request(.GET, uri, .{}) catch return error.FetchFailed;
    defer req.deinit();

    if (req.connection) |conn| setRecvTimeout(conn);
    publishConnection(control, &req);
    defer clearConnection(control);
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
        if (controlCancelled(control)) return error.Cancelled;
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

pub fn downloadFileStreaming(client: *std.http.Client, url: []const u8, dest_path: []const u8, control: TransferControl) !void {
    return downloadFileStreamingWithProgress(client, url, dest_path, null, control);
}

pub fn downloadFileStreamingWithProgress(client: *std.http.Client, url: []const u8, dest_path: []const u8, progress: ?DownloadProgress, control: TransferControl) !void {
    if (controlCancelled(control)) return error.Cancelled;
    var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), dest_path, .{}) catch return error.DownloadFailed;
    defer file.close(io_mod.getIo());

    var write_buf: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .initStreaming(file, io_mod.getIo(), &write_buf);

    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var req = client.request(.GET, uri, .{}) catch return error.DownloadFailed;
    defer req.deinit();

    if (req.connection) |conn| setRecvTimeout(conn);
    publishConnection(control, &req);
    defer clearConnection(control);
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
        if (controlCancelled(control)) return error.Cancelled;
        const n = body_reader.readSliceShort(&copy_buf) catch return error.DownloadFailed;
        if (n == 0) break;
        file_writer.interface.writeAll(copy_buf[0..n]) catch return error.DownloadFailed;
        downloaded += n;
        if (progress) |p| p.update(p.ctx, downloaded, total);
    }

    file_writer.interface.flush() catch return error.DownloadFailed;
}

pub fn verifyChecksum(client: *std.http.Client, file_path: []const u8, checksum_url: []const u8, control: TransferControl) !void {
    const raw = fetchTextBounded(
        client,
        client.allocator,
        checksum_url,
        checksum_max_bytes,
        control,
    ) catch |err| return switch (err) {
        error.Cancelled => error.Cancelled,
        else => error.ChecksumFetchFailed,
    };
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
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "tar", "-xzf", archive_path, "-C", dest_dir },
    }) catch return error.ExtractionFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ExtractionFailed,
        else => return error.ExtractionFailed,
    }
}

pub fn replaceBinary(new_path: []const u8, target_path: []const u8) !void {
    std.Io.Dir.renameAbsolute(new_path, target_path, io_mod.getIo()) catch {
        copyBinary(new_path, target_path) catch return error.ReplaceFailed;
        return;
    };
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
    if (builtin.target.os.tag == .linux and std.mem.endsWith(u8, path, linux_deleted_suffix)) {
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
    const raw = text_utils.repeat("a", 64) ++ "\n";
    const hex = extractChecksumHex(raw).?;
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    try std.testing.expectEqualStrings(text_utils.repeat("a", 64), hex);
}

test "extractChecksumHex rejects short raw checksum" {
    try std.testing.expect(extractChecksumHex("abcd\n") == null);
}

test "bytesToHex renders lowercase sha256 digest" {
    const bytes: [32]u8 = @splat(0x0f);
    const hex = bytesToHex(&bytes);
    try std.testing.expectEqualStrings(text_utils.repeat("0f", 32), &hex);
}

test "replaceBinary moves replacement over target path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(tmp.dir, "fx-old", "old");
    try writeTempFile(tmp.dir, "fx-new", "new");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const new_path = try std.Io.Dir.path.join(alloc, &.{ root, "fx-new" });
    defer alloc.free(new_path);
    const target_path = try std.Io.Dir.path.join(alloc, &.{ root, "fx-old" });
    defer alloc.free(target_path);

    try replaceBinary(new_path, target_path);

    const replaced = try readAbsoluteFile(alloc, target_path);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("new", replaced);
}

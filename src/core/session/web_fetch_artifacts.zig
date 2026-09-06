const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const relative_dir = "artifacts/web-fetch";
pub const default_max_bytes: usize = 50 * 1024 * 1024;
pub const default_max_files: usize = 1024;

pub const Limits = struct {
    max_bytes: usize = default_max_bytes,
    max_files: usize = default_max_files,
};

pub const Artifact = struct {
    handle: []u8,
    mime_type: []u8,
    byte_count: usize,
    retention_scope: []const u8 = "session",
    display_path: []u8,

    pub fn deinit(self: *Artifact, alloc: Allocator) void {
        alloc.free(self.handle);
        alloc.free(self.mime_type);
        alloc.free(self.display_path);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: Allocator,
    dir: []u8,
    store_id: []u8,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    ready: bool = false,
    used_bytes: usize = 0,
    file_count: usize = 0,

    pub fn init(alloc: Allocator, session_dir: []const u8) !Store {
        return initWithLimits(alloc, session_dir, .{});
    }

    pub fn initWithLimits(alloc: Allocator, session_dir: []const u8, limits: Limits) !Store {
        const dir = try std.fs.path.join(alloc, &.{ session_dir, relative_dir });
        errdefer alloc.free(dir);
        const store_id = try alloc.dupe(u8, dir);
        errdefer alloc.free(store_id);

        return .{
            .allocator = alloc,
            .dir = dir,
            .store_id = store_id,
            .limits = limits,
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.dir);
        self.allocator.free(self.store_id);
        self.* = undefined;
    }

    pub fn id(self: *const Store) []const u8 {
        return self.store_id;
    }

    pub fn write(self: *Store, alloc: Allocator, mime_type: []const u8, bytes: []const u8) !Artifact {
        const ext = extensionForMime(mime_type);
        const handle = try makeHandle(alloc, ext);
        return try self.writeWithOwnedHandle(alloc, handle, mime_type, bytes);
    }

    pub fn read(self: *Store, alloc: Allocator, handle: []const u8, max_bytes: usize) ![]u8 {
        if (!(try self.contains(handle))) return error.ArtifactNotFound;
        const path = try self.pathForHandle(alloc, handle);
        defer alloc.free(path);
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ArtifactNotFound,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        return io_mod.readFileToEnd(alloc, &file, max_bytes);
    }

    pub fn contains(self: *Store, handle: []const u8) !bool {
        try validateHandle(handle);
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), self.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close(io_mod.getIo());
        var iter = dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (!std.mem.eql(u8, entry.name, handle)) continue;
            return switch (entry.kind) {
                .file => true,
                .sym_link => error.CorruptArtifactStore,
                else => error.CorruptArtifactStore,
            };
        }
        return false;
    }

    fn reconcile(self: *Store) !void {
        var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), self.dir, .{ .iterate = true });
        defer dir.close(io_mod.getIo());

        var used_bytes: usize = 0;
        var file_count: usize = 0;
        var iter = dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (isTempName(entry.name)) {
                try dir.deleteFile(io_mod.getIo(), entry.name);
                continue;
            }

            switch (entry.kind) {
                .file => {},
                .sym_link => return error.CorruptArtifactStore,
                else => return error.CorruptArtifactStore,
            }
            try validateHandle(entry.name);
            const stat = try dir.statFile(io_mod.getIo(), entry.name, .{});
            if (stat.kind != .file) return error.CorruptArtifactStore;
            used_bytes = checkedAdd(used_bytes, stat.size) catch return error.ArtifactQuotaExceeded;
            file_count += 1;
            if (used_bytes > self.limits.max_bytes or file_count > self.limits.max_files) {
                return error.ArtifactQuotaExceeded;
            }
        }

        self.used_bytes = used_bytes;
        self.file_count = file_count;
    }

    fn writeWithHandleForTest(self: *Store, alloc: Allocator, handle: []const u8, mime_type: []const u8, bytes: []const u8) !Artifact {
        return try self.writeWithOwnedHandle(alloc, try alloc.dupe(u8, handle), mime_type, bytes);
    }

    fn writeWithOwnedHandle(self: *Store, alloc: Allocator, handle: []u8, mime_type: []const u8, bytes: []const u8) !Artifact {
        errdefer alloc.free(handle);
        try validateHandle(handle);
        try self.ensureReady();

        const normalized_mime = try normalizedMime(alloc, mime_type);
        errdefer alloc.free(normalized_mime);
        const path = try self.pathForHandle(alloc, handle);
        defer alloc.free(path);
        const display_path = try alloc.dupe(u8, path);
        errdefer alloc.free(display_path);
        const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ path, io_mod.nanoTimestamp() });
        defer alloc.free(temp_path);

        try self.reserve(bytes.len);
        var committed = false;
        errdefer if (!committed) self.rollback(bytes.len);

        var cleanup_temp = true;
        defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), temp_path) catch {};

        {
            var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), temp_path, .{ .truncate = true });
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), bytes);
            try file.sync(io_mod.getIo());
        }

        try std.Io.Dir.renameAbsolute(temp_path, path, io_mod.getIo());
        cleanup_temp = false;
        committed = true;

        return .{
            .handle = handle,
            .mime_type = normalized_mime,
            .byte_count = bytes.len,
            .display_path = display_path,
        };
    }

    fn reserve(self: *Store, byte_count: usize) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (byte_count > self.limits.max_bytes) return error.ArtifactQuotaExceeded;
        if (self.used_bytes > self.limits.max_bytes - byte_count) return error.ArtifactQuotaExceeded;
        if (self.file_count >= self.limits.max_files) return error.ArtifactFileCapExceeded;
        self.used_bytes += byte_count;
        self.file_count += 1;
    }

    fn ensureReady(self: *Store) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.ready) return;
        const session_dir = std.fs.path.dirname(self.dir) orelse
            return error.CorruptArtifactStore;
        const root = std.fs.path.dirname(session_dir) orelse
            return error.CorruptArtifactStore;
        try ensureArtifactDir(self.allocator, root);
        try self.reconcile();
        self.ready = true;
    }

    fn rollback(self: *Store, byte_count: usize) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.used_bytes -= @min(self.used_bytes, byte_count);
        if (self.file_count > 0) self.file_count -= 1;
    }

    fn pathForHandle(self: *const Store, alloc: Allocator, handle: []const u8) ![]u8 {
        try validateHandle(handle);
        return std.fs.path.join(alloc, &.{ self.dir, handle });
    }

    fn usedBytesForTest(self: *Store) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.used_bytes;
    }

    fn fileCountForTest(self: *Store) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.file_count;
    }

    fn reserveForTest(self: *Store, byte_count: usize) !void {
        try self.reserve(byte_count);
    }

    fn rollbackForTest(self: *Store, byte_count: usize) void {
        self.rollback(byte_count);
    }
};

fn ensureArtifactDir(alloc: Allocator, session_dir: []const u8) !void {
    try ensureManagedDir(session_dir, "artifacts");
    const artifacts_dir = try std.fs.path.join(alloc, &.{ session_dir, "artifacts" });
    defer alloc.free(artifacts_dir);
    try ensureManagedDir(artifacts_dir, "web-fetch");
}

fn ensureManagedDir(parent_path: []const u8, child_name: []const u8) !void {
    const zio = io_mod.getIo();
    var parent = try std.Io.Dir.openDirAbsolute(zio, parent_path, .{ .iterate = true });
    defer parent.close(zio);

    for (0..2) |_| {
        var child = parent.openDir(zio, child_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                parent.createDir(zio, child_name, std.Io.File.Permissions.fromMode(0o700)) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    error.NotDir, error.SymLinkLoop => return error.CorruptArtifactStore,
                    else => return create_err,
                };
                io_mod.syncVerifiedDir(parent) catch return error.CorruptArtifactStore;
                continue;
            },
            error.NotDir, error.SymLinkLoop => return error.CorruptArtifactStore,
            else => return err,
        };
        defer child.close(zio);
        child.setPermissions(zio, std.Io.File.Permissions.fromMode(0o700)) catch
            return error.CorruptArtifactStore;
        const stat = try child.stat(zio);
        if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
            return error.CorruptArtifactStore;
        }
        return;
    }
    return error.CorruptArtifactStore;
}

fn checkedAdd(a: usize, b: u64) !usize {
    if (b > std.math.maxInt(usize)) return error.Overflow;
    const rhs: usize = @intCast(b);
    if (a > std.math.maxInt(usize) - rhs) return error.Overflow;
    return a + rhs;
}

fn normalizedMime(alloc: Allocator, mime_type: []const u8) ![]u8 {
    const parameter_start = std.mem.findScalar(u8, mime_type, ';') orelse mime_type.len;
    const trimmed = std.mem.trim(u8, mime_type[0..parameter_start], " \t\r\n");
    if (trimmed.len == 0) return alloc.dupe(u8, "application/octet-stream");
    const out = try alloc.alloc(u8, trimmed.len);
    for (trimmed, 0..) |byte, index| out[index] = std.ascii.toLower(byte);
    return out;
}

pub fn extensionForMime(mime_type: []const u8) []const u8 {
    const parameter_start = std.mem.findScalar(u8, mime_type, ';') orelse mime_type.len;
    const trimmed = std.mem.trim(u8, mime_type[0..parameter_start], " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "application/pdf")) return "pdf";
    if (std.ascii.eqlIgnoreCase(trimmed, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(trimmed, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(trimmed, "image/gif")) return "gif";
    if (std.ascii.eqlIgnoreCase(trimmed, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(trimmed, "image/svg+xml")) return "svg";
    if (std.ascii.eqlIgnoreCase(trimmed, "application/zip")) return "zip";
    return "bin";
}

fn makeHandle(alloc: Allocator, extension: []const u8) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(alloc, "artifact-{d}-{s}.{s}", .{ io_mod.nanoTimestamp(), &random_hex, extension });
}

fn isTempName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".artifact-") or std.mem.find(u8, name, ".tmp.") != null;
}

fn validateHandle(handle: []const u8) !void {
    if (handle.len == 0 or handle.len > 160) return error.InvalidArtifactHandle;
    if (!std.mem.startsWith(u8, handle, "artifact-")) return error.InvalidArtifactHandle;
    if (std.mem.find(u8, handle, "..") != null) return error.InvalidArtifactHandle;
    for (handle) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.';
        if (!ok) return error.InvalidArtifactHandle;
    }
    if (!hasAllowedExtension(handle)) return error.InvalidArtifactHandle;
}

fn hasAllowedExtension(handle: []const u8) bool {
    inline for (.{ ".pdf", ".png", ".jpg", ".gif", ".webp", ".svg", ".zip", ".bin" }) |ext| {
        if (std.mem.endsWith(u8, handle, ext)) return true;
    }
    return false;
}

fn createFileAbsolute(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

test "web_fetch binary artifact write is byte exact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);

    var store = try Store.init(alloc, session_dir);
    defer store.deinit();

    const bytes = "\x00pdf bytes\xff";
    var artifact = try store.write(alloc, "application/pdf", bytes);
    defer artifact.deinit(alloc);

    const read_back = try store.read(alloc, artifact.handle, 1024);
    defer alloc.free(read_back);
    try std.testing.expectEqualSlices(u8, bytes, read_back);
}

test "web_fetch artifact quota reconciles existing files on resume" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);
    const artifact_dir = try std.fs.path.join(alloc, &.{ session_dir, relative_dir });
    defer alloc.free(artifact_dir);
    try config_runtime.makeAbsolutePath(artifact_dir);
    const existing_path = try std.fs.path.join(alloc, &.{ artifact_dir, "artifact-existing.bin" });
    defer alloc.free(existing_path);
    try createFileAbsolute(existing_path, "abc");

    var store = try Store.initWithLimits(alloc, session_dir, .{ .max_bytes = 4, .max_files = 2 });
    defer store.deinit();
    try std.testing.expectError(error.ArtifactQuotaExceeded, store.writeWithHandleForTest(alloc, "artifact-new.bin", "application/octet-stream", "xy"));
    try std.testing.expectEqual(@as(usize, 3), store.usedBytesForTest());
    try std.testing.expectEqual(@as(usize, 1), store.fileCountForTest());
}

test "web_fetch concurrent artifact reservations cannot exceed byte or file caps" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);
    var store = try Store.initWithLimits(alloc, session_dir, .{ .max_bytes = 3, .max_files = 1 });
    defer store.deinit();

    try store.reserveForTest(2);
    defer store.rollbackForTest(2);

    try std.testing.expectError(error.ArtifactQuotaExceeded, store.reserveForTest(2));
    try std.testing.expectEqual(@as(usize, 2), store.usedBytesForTest());
    try std.testing.expectEqual(@as(usize, 1), store.fileCountForTest());
}

test "web_fetch failed artifact write rolls back quota reservation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);
    var store = try Store.initWithLimits(alloc, session_dir, .{ .max_bytes = 3, .max_files = 1 });
    defer store.deinit();
    try store.ensureReady();

    const final_dir = try std.fs.path.join(alloc, &.{ store.dir, "artifact-conflict.bin" });
    defer alloc.free(final_dir);
    try config_runtime.makeAbsolutePath(final_dir);

    try std.testing.expectError(error.IsDir, store.writeWithHandleForTest(alloc, "artifact-conflict.bin", "application/octet-stream", "ab"));
    try std.testing.expectEqual(@as(usize, 0), store.usedBytesForTest());
    try std.testing.expectEqual(@as(usize, 0), store.fileCountForTest());

    var artifact = try store.writeWithHandleForTest(alloc, "artifact-ok.bin", "application/octet-stream", "ab");
    defer artifact.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), store.usedBytesForTest());
    try std.testing.expectEqual(@as(usize, 1), store.fileCountForTest());
}

test "web_fetch artifact store refuses symlinks and partial temp files deterministically" {
    const alloc = std.testing.allocator;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(session_dir);
        const artifact_dir = try std.fs.path.join(alloc, &.{ session_dir, relative_dir });
        defer alloc.free(artifact_dir);
        try config_runtime.makeAbsolutePath(artifact_dir);
        const temp_path = try std.fs.path.join(alloc, &.{ artifact_dir, ".artifact-leftover.tmp" });
        defer alloc.free(temp_path);
        try createFileAbsolute(temp_path, "partial");

        var store = try Store.init(alloc, session_dir);
        defer store.deinit();
        try store.ensureReady();
        try std.testing.expect(!try store.contains("artifact-leftover.bin"));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), temp_path));
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "artifacts/web-fetch");
        tmp.dir.symLink(io_mod.getIo(), "target", "artifacts/web-fetch/artifact-link.bin", .{ .is_directory = false }) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(session_dir);
        var store = try Store.init(alloc, session_dir);
        defer store.deinit();
        try std.testing.expectError(error.CorruptArtifactStore, store.ensureReady());
    }
}

test "web_fetch artifact store rejects a symlinked store directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "artifacts");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside");
    tmp.dir.symLink(io_mod.getIo(), "../outside", "artifacts/web-fetch", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);

    var store = try Store.init(alloc, session_dir);
    defer store.deinit();
    try std.testing.expectError(error.CorruptArtifactStore, store.ensureReady());
}

test "web_fetch artifact store creates private managed directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);

    var store = try Store.init(alloc, session_dir);
    defer store.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "artifacts", .{ .follow_symlinks = false }),
    );
    var artifact = try store.write(alloc, "text/plain", "created lazily");
    defer artifact.deinit(alloc);

    const artifacts_stat = try tmp.dir.statFile(io_mod.getIo(), "artifacts", .{ .follow_symlinks = false });
    const web_fetch_stat = try tmp.dir.statFile(io_mod.getIo(), "artifacts/web-fetch", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), artifacts_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), web_fetch_stat.permissions.toMode() & 0o777);
}

test "web_fetch corrupt durable artifact store fails instead of degrading to storeless metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(session_dir);
    const artifact_dir = try std.fs.path.join(alloc, &.{ session_dir, relative_dir });
    defer alloc.free(artifact_dir);
    try config_runtime.makeAbsolutePath(artifact_dir);
    const corrupt_path = try std.fs.path.join(alloc, &.{ artifact_dir, "not-managed.bin" });
    defer alloc.free(corrupt_path);
    try createFileAbsolute(corrupt_path, "corrupt");

    var store = try Store.init(alloc, session_dir);
    defer store.deinit();
    try std.testing.expectError(error.InvalidArtifactHandle, store.ensureReady());
}

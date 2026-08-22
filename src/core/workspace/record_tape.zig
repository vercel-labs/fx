//! FX_RECORD tape writer and replay reader.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const profile_roots = @import("../shared/profile_roots.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const magic = "FXTP\x01";

pub const Kind = enum(u8) {
    stdout = 1,
    stdin = 2,
    resize = 3,
    sigint = 4,
    marker = 5,
    _,
};

const State = struct {
    enabled: bool = false,
    failed: bool = false,
    record_stdin: bool = false,
    file: ?std.Io.File = null,
    path: ?[]u8 = null,
    path_alloc: ?Allocator = null,
    start_ms: i64 = 0,
    last_ms: i64 = 0,
};

var state_mutex: std.Io.Mutex = .init;
var state: State = .{};

fn nowMs() i64 {
    return io_mod.milliTimestamp();
}

pub const CaptureStatus = union(enum) {
    inactive,
    active: []u8,
    failed,

    pub fn deinit(self: *CaptureStatus, alloc: Allocator) void {
        switch (self.*) {
            .active => |path| alloc.free(path),
            .inactive, .failed => {},
        }
        self.* = undefined;
    }
};

pub fn configureFromEnv(
    alloc: Allocator,
    workspace_root: []const u8,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
    record_requested: bool,
) !void {
    _ = workspace_root;

    const configured_path = if (io_mod.getenv("FX_RECORD")) |raw_path|
        std.mem.trim(u8, raw_path, " \t\r\n")
    else
        "";
    if (configured_path.len > 0) {
        configure(alloc, configured_path, initial_cols, initial_rows, fx_version) catch |err| {
            if (record_requested) return err;
            return;
        };
    } else if (record_requested) {
        try configureAutomatic(alloc, initial_cols, initial_rows, fx_version);
    } else {
        return;
    }

    if (io_mod.getenv("FX_RECORD_INPUT")) |raw_value| {
        const value = std.mem.trim(u8, raw_value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "on"))
        {
            const zio = io_mod.getIo();
            state_mutex.lockUncancelable(zio);
            defer state_mutex.unlock(zio);
            state.record_stdin = true;
        }
    }
}

pub fn configure(
    alloc: Allocator,
    path: []const u8,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
) !void {
    try configureWithOptions(alloc, path, initial_cols, initial_rows, fx_version, false, false);
}

fn configureAutomatic(
    alloc: Allocator,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
) !void {
    const home = if (io_mod.getenv("HOME")) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else null;
    const root = if (home) |value|
        try profile_paths.recordingsDir(alloc, (try profile_roots.processRoots(value)).state)
    else
        try std.fs.path.join(alloc, &.{ io_mod.getenv("TMPDIR") orelse "/tmp", "fx-recordings" });
    defer alloc.free(root);
    try io_mod.makeDirRecursive(root);

    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        var random_bytes: [6]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fmt.allocPrint(alloc, "{s}/fx-record-{d}-{s}.fxtape", .{ root, nowMs(), random_hex });
        defer alloc.free(path);

        configureWithOptions(alloc, path, initial_cols, initial_rows, fx_version, true, true) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return;
    }
    return error.PathAlreadyExists;
}

fn configureWithOptions(
    alloc: Allocator,
    path: []const u8,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
    exclusive: bool,
    private: bool,
) !void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (state.enabled) return;

    try ensureParentDir(path);

    const file = try openTape(path, exclusive, private);
    errdefer file.close(zio);

    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);

    const header = buildHeader(initial_cols, initial_rows, fx_version);
    try file.writeStreamingAll(zio, &header.fixed);
    if (header.version_tail.len > 0) {
        try file.writeStreamingAll(zio, header.version_tail);
    }

    const now = nowMs();
    state = .{
        .enabled = true,
        .file = file,
        .path = owned_path,
        .path_alloc = alloc,
        .start_ms = now,
        .last_ms = now,
    };
}

fn openTape(path: []const u8, exclusive: bool, private: bool) !std.Io.File {
    const zio = io_mod.getIo();
    if (std.fs.path.isAbsolute(path)) {
        if (private) {
            return std.Io.Dir.createFileAbsolute(zio, path, .{
                .truncate = !exclusive,
                .exclusive = exclusive,
                .permissions = .fromMode(0o600),
            });
        }
        return std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = !exclusive, .exclusive = exclusive });
    }
    if (private) {
        return std.Io.Dir.cwd().createFile(zio, path, .{
            .truncate = !exclusive,
            .exclusive = exclusive,
            .permissions = .fromMode(0o600),
        });
    }
    return std.Io.Dir.cwd().createFile(zio, path, .{ .truncate = !exclusive, .exclusive = exclusive });
}

const Header = struct {
    fixed: [header_len]u8,
    version_tail: []const u8,
};

fn buildHeader(initial_cols: u16, initial_rows: u16, fx_version: []const u8) Header {
    var header: Header = .{
        .fixed = undefined,
        .version_tail = fx_version,
    };
    @memcpy(header.fixed[0..magic.len], magic);
    var idx: usize = magic.len;
    std.mem.writeInt(u16, header.fixed[idx..][0..2], initial_cols, .little);
    idx += 2;
    std.mem.writeInt(u16, header.fixed[idx..][0..2], initial_rows, .little);
    idx += 2;
    std.mem.writeInt(i64, header.fixed[idx..][0..8], nowMs(), .little);
    idx += 8;
    header.fixed[idx] = @intCast(@min(fx_version.len, @as(usize, 255)));
    return header;
}

fn writeFrame(kind: Kind, payload: []const u8) void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    writeFrameLocked(zio, kind, payload);
}

fn writeFrameLocked(zio: std.Io, kind: Kind, payload: []const u8) void {
    if (!state.enabled) return;
    const file = state.file orelse {
        stopCaptureLocked(zio, true);
        return;
    };

    const now = nowMs();
    const delta: i32 = @intCast(std.math.clamp(now - state.last_ms, 0, std.math.maxInt(i32)));
    state.last_ms = now;

    var header: [9]u8 = undefined;
    std.mem.writeInt(i32, header[0..4], delta, .little);
    header[4] = @intFromEnum(kind);
    const len: u32 = @intCast(@min(payload.len, std.math.maxInt(u32)));
    std.mem.writeInt(u32, header[5..9], len, .little);

    file.writeStreamingAll(zio, &header) catch {
        stopCaptureLocked(zio, true);
        return;
    };
    if (len > 0) {
        file.writeStreamingAll(zio, payload[0..len]) catch {
            stopCaptureLocked(zio, true);
            return;
        };
    }
}

pub fn recordStdout(bytes: []const u8) void {
    if (bytes.len == 0) return;
    writeFrame(.stdout, bytes);
}

pub fn recordStdin(bytes: []const u8) void {
    if (bytes.len == 0) return;

    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (!state.record_stdin) return;
    writeFrameLocked(zio, .stdin, bytes);
}

pub fn recordResize(cols: u16, rows: u16) void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], cols, .little);
    std.mem.writeInt(u16, payload[2..4], rows, .little);
    writeFrame(.resize, &payload);
}

pub fn recordSigint() void {
    writeFrame(.sigint, "");
}

pub fn recordMarker(label: []const u8) void {
    writeFrame(.marker, label);
}

pub fn shutdown() void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    stopCaptureLocked(zio, false);
}

pub fn captureStatus(alloc: Allocator) !CaptureStatus {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (state.enabled and state.path != null) {
        return .{ .active = try alloc.dupe(u8, state.path.?) };
    }
    return if (state.failed) .failed else .inactive;
}

fn stopCaptureLocked(zio: std.Io, failed: bool) void {
    if (failed) debug_trace.logf("record", "capture stopped after a frame write failure", .{});
    if (state.file) |*file| file.close(zio);
    if (state.path) |path| state.path_alloc.?.free(path);
    state = .{ .failed = failed };
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try io_mod.makeDirRecursive(parent);
}

pub const ReplayHeader = struct {
    cols: u16,
    rows: u16,
    epoch_ms: i64,
    version: []const u8,
};

pub const ReplayFrame = struct {
    delta_ms: i32,
    kind: Kind,
    payload: []const u8,
};

pub const Parser = struct {
    bytes: []const u8,
    pos: usize = 0,
    header: ReplayHeader,

    pub fn init(bytes: []const u8) !Parser {
        if (bytes.len < header_len) return error.TapeTooShort;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadTapeMagic;

        var idx: usize = magic.len;
        const cols = std.mem.readInt(u16, bytes[idx..][0..2], .little);
        idx += 2;
        const rows = std.mem.readInt(u16, bytes[idx..][0..2], .little);
        idx += 2;
        const epoch_ms = std.mem.readInt(i64, bytes[idx..][0..8], .little);
        idx += 8;
        const version_len = bytes[idx];
        idx += 1;
        if (idx + version_len > bytes.len) return error.TruncatedVersion;
        const version = bytes[idx .. idx + version_len];
        idx += version_len;

        return .{
            .bytes = bytes,
            .pos = idx,
            .header = .{
                .cols = cols,
                .rows = rows,
                .epoch_ms = epoch_ms,
                .version = version,
            },
        };
    }

    pub fn next(self: *Parser) !?ReplayFrame {
        if (self.pos >= self.bytes.len) return null;
        if (self.pos + 9 > self.bytes.len) return error.TruncatedFrameHeader;

        const delta_ms = std.mem.readInt(i32, self.bytes[self.pos..][0..4], .little);
        const kind_raw = self.bytes[self.pos + 4];
        const payload_len = std.mem.readInt(u32, self.bytes[self.pos + 5 ..][0..4], .little);
        const start = self.pos + 9;
        const end = start + payload_len;
        if (end > self.bytes.len) return error.TruncatedFramePayload;

        self.pos = end;
        return .{
            .delta_ms = delta_ms,
            .kind = @enumFromInt(kind_raw),
            .payload = self.bytes[start..end],
        };
    }
};

const header_len = magic.len + 2 + 2 + 8 + 1;

var test_empty_env: std.process.Environ.Map = std.process.Environ.Map.init(std.heap.c_allocator);

fn resetEnvForTest() void {
    io_mod.setEnvironMap(&test_empty_env);
}

fn tapePath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn appendHeader(out: *std.ArrayList(u8), alloc: Allocator, cols: u16, rows: u16, epoch_ms: i64, version: []const u8) !void {
    try out.appendSlice(alloc, magic);
    var fixed: [2 + 2 + 8 + 1]u8 = undefined;
    std.mem.writeInt(u16, fixed[0..2], cols, .little);
    std.mem.writeInt(u16, fixed[2..4], rows, .little);
    std.mem.writeInt(i64, fixed[4..12], epoch_ms, .little);
    fixed[12] = @intCast(@min(version.len, @as(usize, 255)));
    try out.appendSlice(alloc, &fixed);
    try out.appendSlice(alloc, version);
}

fn appendFrame(out: *std.ArrayList(u8), alloc: Allocator, delta_ms: i32, kind: u8, payload: []const u8) !void {
    var fixed: [9]u8 = undefined;
    std.mem.writeInt(i32, fixed[0..4], delta_ms, .little);
    fixed[4] = kind;
    std.mem.writeInt(u32, fixed[5..9], @intCast(payload.len), .little);
    try out.appendSlice(alloc, &fixed);
    try out.appendSlice(alloc, payload);
}

fn expectNoFrame(bytes: []const u8) !void {
    var parser = try Parser.init(bytes);
    try testing.expect((try parser.next()) == null);
}

test "header construction round-trips" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tapePath(alloc, tmp.dir, "header.fxtape");
    defer alloc.free(path);

    shutdown();
    defer shutdown();
    try configure(alloc, path, 120, 40, "1.2.3");
    shutdown();

    const bytes = try readFile(alloc, path);
    defer alloc.free(bytes);

    var parser = try Parser.init(bytes);
    try testing.expectEqual(@as(u16, 120), parser.header.cols);
    try testing.expectEqual(@as(u16, 40), parser.header.rows);
    try testing.expect(parser.header.epoch_ms > 0);
    try testing.expectEqualStrings("1.2.3", parser.header.version);
    try testing.expect((try parser.next()) == null);
}

test "writer helper frames parse back through Parser" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tapePath(alloc, tmp.dir, "frames.fxtape");
    defer alloc.free(path);

    shutdown();
    defer shutdown();
    try configure(alloc, path, 80, 24, "vtest");
    recordStdout("hello\n");
    recordResize(60, 20);
    recordSigint();
    recordMarker("");
    recordMarker("after-resize");
    recordStdout("world");
    shutdown();

    const bytes = try readFile(alloc, path);
    defer alloc.free(bytes);

    var parser = try Parser.init(bytes);

    const f1 = (try parser.next()).?;
    try testing.expectEqual(Kind.stdout, f1.kind);
    try testing.expectEqualStrings("hello\n", f1.payload);

    const f2 = (try parser.next()).?;
    try testing.expectEqual(Kind.resize, f2.kind);
    try testing.expectEqual(@as(usize, 4), f2.payload.len);
    try testing.expectEqual(@as(u16, 60), std.mem.readInt(u16, f2.payload[0..2], .little));
    try testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, f2.payload[2..4], .little));

    const f3 = (try parser.next()).?;
    try testing.expectEqual(Kind.sigint, f3.kind);
    try testing.expectEqual(@as(usize, 0), f3.payload.len);

    const f4 = (try parser.next()).?;
    try testing.expectEqual(Kind.marker, f4.kind);
    try testing.expectEqual(@as(usize, 0), f4.payload.len);

    const f5 = (try parser.next()).?;
    try testing.expectEqual(Kind.marker, f5.kind);
    try testing.expectEqualStrings("after-resize", f5.payload);

    const f6 = (try parser.next()).?;
    try testing.expectEqual(Kind.stdout, f6.kind);
    try testing.expectEqualStrings("world", f6.payload);

    try testing.expect((try parser.next()) == null);
}

test "parser rejects bad magic" {
    const garbage = "NOTA\x01" ++ [_]u8{0} ** 32;
    try testing.expectError(error.BadTapeMagic, Parser.init(garbage));
}

test "disabled recorder calls do not crash" {
    shutdown();
    defer shutdown();

    recordStdout("ignored");
    recordStdin("ignored");
    recordResize(10, 10);
    recordSigint();
    recordMarker("ignored");
}

test "missing writer disables capture" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tapePath(alloc, tmp.dir, "write-failure.fxtape");
    defer alloc.free(path);

    shutdown();
    defer {
        if (state.enabled) {
            state = .{};
        } else {
            shutdown();
        }
    }
    try configure(alloc, path, 80, 24, "vtest");

    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    const file = state.file.?;
    state.file = null;
    state_mutex.unlock(zio);
    file.close(zio);

    recordStdout("after-close");
    try testing.expect(!state.enabled);
    try testing.expect(state.file == null);
    var status = try captureStatus(alloc);
    defer status.deinit(alloc);
    try testing.expect(status == .failed);
}

test "Parser.init returns TapeTooShort for too-short input" {
    try testing.expectError(error.TapeTooShort, Parser.init(magic[0 .. magic.len - 1]));
}

test "Parser.init returns TruncatedVersion when declared version exceeds remaining bytes" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendHeader(&bytes, testing.allocator, 80, 24, 123, "ab");
    bytes.items[header_len - 1] = 3;

    try testing.expectError(error.TruncatedVersion, Parser.init(bytes.items));
}

test "Parser.next returns TruncatedFrameHeader for short leftover bytes" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendHeader(&bytes, testing.allocator, 80, 24, 123, "");
    try bytes.appendSlice(testing.allocator, &.{ 1, 2, 3 });

    var parser = try Parser.init(bytes.items);
    try testing.expectError(error.TruncatedFrameHeader, parser.next());
}

test "Parser.next returns TruncatedFramePayload for non-overflowing truncated payload" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendHeader(&bytes, testing.allocator, 80, 24, 123, "");
    var frame_header: [9]u8 = undefined;
    std.mem.writeInt(i32, frame_header[0..4], 0, .little);
    frame_header[4] = @intFromEnum(Kind.stdout);
    std.mem.writeInt(u32, frame_header[5..9], 5, .little);
    try bytes.appendSlice(testing.allocator, &frame_header);
    try bytes.appendSlice(testing.allocator, "ab");

    var parser = try Parser.init(bytes.items);
    try testing.expectError(error.TruncatedFramePayload, parser.next());
}

test "Parser.next accepts unknown kind bytes" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendHeader(&bytes, testing.allocator, 80, 24, 123, "");
    try appendFrame(&bytes, testing.allocator, 7, 200, "x");

    var parser = try Parser.init(bytes.items);
    const frame = (try parser.next()).?;
    try testing.expectEqual(@as(u8, 200), @intFromEnum(frame.kind));
    try testing.expectEqual(@as(i32, 7), frame.delta_ms);
    try testing.expectEqualStrings("x", frame.payload);
}

test "Parser.next accepts malformed kind-specific payload lengths" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendHeader(&bytes, testing.allocator, 80, 24, 123, "");
    try appendFrame(&bytes, testing.allocator, 0, @intFromEnum(Kind.resize), "x");

    var parser = try Parser.init(bytes.items);
    const frame = (try parser.next()).?;
    try testing.expectEqual(Kind.resize, frame.kind);
    try testing.expectEqualStrings("x", frame.payload);
}

test "recordStdin suppresses input by default" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tapePath(alloc, tmp.dir, "stdin-default.fxtape");
    defer alloc.free(path);

    shutdown();
    defer shutdown();
    try configure(alloc, path, 80, 24, "v");
    recordStdin("typed");
    shutdown();

    const bytes = try readFile(alloc, path);
    defer alloc.free(bytes);
    try expectNoFrame(bytes);
}

test "requested recording creates a private tape under home" {
    const alloc = testing.allocator;
    resetEnvForTest();
    defer resetEnvForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", home);

    shutdown();
    defer shutdown();
    io_mod.setEnvironMap(&env);
    try configureFromEnv(alloc, "/ignored/workspace", 80, 24, "vtest", true);

    var status = try captureStatus(alloc);
    defer status.deinit(alloc);
    switch (status) {
        .active => |path| {
            const expected_roots = try profile_roots.processRoots(home);
            const expected_dir = try profile_paths.recordingsDir(alloc, expected_roots.state);
            defer alloc.free(expected_dir);
            try testing.expect(std.mem.startsWith(u8, path, expected_dir));
            const file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
            defer file.close(io_mod.getIo());
            if (@import("builtin").os.tag != .windows) {
                const stat = try file.stat(io_mod.getIo());
                try testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
            }
        },
        else => return error.TestExpectedActiveRecording,
    }
}

test "requested recording uses the temporary fallback when HOME is empty" {
    const alloc = testing.allocator;
    resetEnvForTest();
    defer resetEnvForTest();

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "");

    shutdown();
    defer shutdown();
    io_mod.setEnvironMap(&env);
    try configureFromEnv(alloc, "/ignored/workspace", 80, 24, "vtest", true);

    var status = try captureStatus(alloc);
    defer status.deinit(alloc);
    switch (status) {
        .active => |path| {
            try testing.expect(std.mem.startsWith(u8, path, "/tmp/fx-recordings/"));
            shutdown();
            if (std.fs.path.isAbsolute(path)) {
                std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
            } else {
                std.Io.Dir.cwd().deleteFile(io_mod.getIo(), path) catch {};
            }
        },
        else => return error.TestExpectedActiveRecording,
    }
}

test "configureFromEnv enables stdin for the accepted truthy values only" {
    const alloc = testing.allocator;
    resetEnvForTest();
    defer resetEnvForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const truthy_values = [_][]const u8{ "1", "TrUe", " ON " };
    for (truthy_values, 0..) |value, idx| {
        const name = try std.fmt.allocPrint(alloc, "stdin-{d}.fxtape", .{idx});
        defer alloc.free(name);
        const path = try tapePath(alloc, tmp.dir, name);
        defer alloc.free(path);

        var env = std.process.Environ.Map.init(alloc);
        defer env.deinit();
        try env.put("FX_RECORD", path);
        try env.put("FX_RECORD_INPUT", value);

        shutdown();
        io_mod.setEnvironMap(&env);
        defer resetEnvForTest();
        try configureFromEnv(alloc, "/ignored/workspace", 80, 24, "v", false);
        recordStdin("typed");
        shutdown();

        const bytes = try readFile(alloc, path);
        defer alloc.free(bytes);
        var parser = try Parser.init(bytes);
        const frame = (try parser.next()).?;
        try testing.expectEqual(Kind.stdin, frame.kind);
        try testing.expectEqualStrings("typed", frame.payload);
        try testing.expect((try parser.next()) == null);

        resetEnvForTest();
    }

    const path = try tapePath(alloc, tmp.dir, "stdin-yes.fxtape");
    defer alloc.free(path);
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("FX_RECORD", path);
    try env.put("FX_RECORD_INPUT", "yes");

    shutdown();
    io_mod.setEnvironMap(&env);
    try configureFromEnv(alloc, "/ignored/workspace", 80, 24, "v", false);
    recordStdin("typed");
    shutdown();

    const bytes = try readFile(alloc, path);
    defer alloc.free(bytes);
    try expectNoFrame(bytes);
}

test "configure is idempotent while enabled and shutdown is idempotent" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try tapePath(alloc, tmp.dir, "first.fxtape");
    defer alloc.free(first);
    const second = try tapePath(alloc, tmp.dir, "second.fxtape");
    defer alloc.free(second);

    shutdown();
    try configure(alloc, first, 80, 24, "v");
    try configure(alloc, second, 10, 5, "ignored");
    recordStdout("only-first");
    shutdown();
    shutdown();

    const first_bytes = try readFile(alloc, first);
    defer alloc.free(first_bytes);
    var parser = try Parser.init(first_bytes);
    const frame = (try parser.next()).?;
    try testing.expectEqual(Kind.stdout, frame.kind);
    try testing.expectEqualStrings("only-first", frame.payload);

    try testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io_mod.getIo(), second, .{}));
}

test "long versions keep the full written tail while declaring length 255" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tapePath(alloc, tmp.dir, "long-version.fxtape");
    defer alloc.free(path);

    var version: [300]u8 = undefined;
    @memset(&version, 'v');

    shutdown();
    defer shutdown();
    try configure(alloc, path, 80, 24, &version);
    shutdown();

    const bytes = try readFile(alloc, path);
    defer alloc.free(bytes);

    try testing.expectEqual(@as(u8, 255), bytes[header_len - 1]);
    try testing.expectEqual(@as(usize, header_len + version.len), bytes.len);
    try testing.expectEqualSlices(u8, &version, bytes[header_len..][0..version.len]);

    const parser = try Parser.init(bytes);
    try testing.expectEqual(@as(usize, 255), parser.header.version.len);
}

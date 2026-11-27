//! Takes over a dead leader's socket folder. `fx acp` calls `takeOverDeadLeader`
//! after it wins a session's lock, with the line the previous holder left, and
//! the folder goes only when every check holds. The live socket is in leader.zig.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const json_decode = @import("../core/shared/json_decode.zig");
const leader_mod = @import("leader.zig");

const testing = std.testing;

const max_socket_path_bytes = leader_mod.max_socket_path_bytes;
const folder_prefix = leader_mod.folder_prefix;
const random_len = leader_mod.random_len;
const hex_len = leader_mod.hex_len;
const socket_name = leader_mod.socket_name;

/// Stands in for the connection runner in tests that only need a socket to answer.
const NoopRunner = struct {
    fn run(context: ?*anyopaque, reader: jsonrpc.Reader, writer: jsonrpc.Writer) void {
        _ = context;
        _ = reader;
        _ = writer;
    }
};

/// How long a takeover waits for a leader's socket to accept a connection. A
/// socket that stays busy this long keeps its folder.
const probe_timeout_ms: i64 = 200;
/// The pause between two connection attempts to the same socket.
const probe_retry_ms: u64 = 10;
const nonblock_flag: c_int = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
/// The most bytes of a lock line a takeover takes as a record. The lock hook is
/// registered with this limit (server.zig), so the session passes a longer line on
/// one byte past it, and the takeover refuses it.
pub const max_record_bytes: usize = 1024;
/// What a record adds around its socket path: its JSON, the pid, and the newline.
const record_framing_bytes = 64;
/// A record writes each byte of its socket path as at most six bytes (`\u00XX`).
const longest_record_bytes = 6 * max_socket_path_bytes + record_framing_bytes;
comptime {
    if (max_record_bytes < longest_record_bytes) @compileError("the lock line limit cannot hold a leader record");
}

const Probe = enum { alive, dead, unknown };

/// Why a takeover keeps a dead leader's folder. Each name is the trace reason.
const KeepReason = enum {
    unreadable_record,
    not_leader_socket,
    live_pid,
    probe_alive,
    probe_unknown,
    folder_missing,
    folder_unsafe,
    folder_mode,
    folder_owner,
    entry_not_socket,
    line_too_long,
};

const Record = struct {
    socket: []const u8,
    pid: i64,
};

/// The base folder and the leader folder name of a socket path with the
/// leader's shape.
const LeaderPath = struct {
    base: []const u8,
    name: []const u8,
};

const LeaderFolder = struct {
    base: io_mod.VerifiedDir,
    folder: io_mod.VerifiedDir,

    fn close(self: *LeaderFolder) void {
        self.folder.close();
        self.base.close();
    }
};

const OpenResult = union(enum) {
    opened: LeaderFolder,
    kept: KeepReason,
};

/// Removes the socket and folder that a previous holder of a session lock left
/// behind. The session calls this only after this process won the lock, and
/// before it writes its own record. It removes nothing unless every check
/// holds: the record parses, the socket has the leader's shape, its pid is
/// gone, nothing answers the socket within `probe_timeout_ms`, and the folder
/// is a private folder of this user. It never fails the open: every keep and
/// every failure is traced.
pub fn takeOverDeadLeader(io: std.Io, old_line: []const u8) void {
    if (old_line.len == 0) return;
    if (old_line.len > max_record_bytes) return keepFolder(.line_too_long);
    var buffer: [max_record_bytes]u8 = undefined;
    const record = parseRecord(&buffer, old_line) catch return keepFolder(.unreadable_record);
    const path = leaderPathOf(record.socket) orelse return keepFolder(.not_leader_socket);
    if (!isDeadPid(record.pid)) return keepFolder(.live_pid);
    switch (openLeaderFolder(io, path)) {
        .kept => |reason| return keepFolder(reason),
        .opened => |opened| {
            var leader = opened;
            defer leader.close();
            if (socketEntryKeepReason(io, leader.folder.dir)) |reason| return keepFolder(reason);
            switch (probeSocket(io, record.socket)) {
                .dead => {},
                .alive => return keepFolder(.probe_alive),
                .unknown => return keepFolder(.probe_unknown),
            }
            removeLeaderFiles(io, &leader, path.name);
        },
    }
}

fn keepFolder(reason: KeepReason) void {
    debug_trace.logf("acp", "event=dead_leader_kept reason={s}", .{@tagName(reason)});
}

/// The strings of the record that need decoding are stored in `buffer`, which
/// the caller owns, so they outlive this call.
fn parseRecord(buffer: *[max_record_bytes]u8, old_line: []const u8) !Record {
    var fallback = std.heap.FixedBufferAllocator.init(buffer);
    return json_decode.parseFromSliceLeaky(Record, fallback.allocator(), old_line, .{ .ignore_unknown_fields = true });
}

/// The base and name of a socket path `{base}/fx-leader-{16 hex}/s`, with an
/// absolute base and at most `max_socket_path_bytes` bytes. Null otherwise.
fn leaderPathOf(socket_path: []const u8) ?LeaderPath {
    if (socket_path.len > max_socket_path_bytes) return null;
    const slash = std.mem.findScalarLast(u8, socket_path, '/') orelse return null;
    if (!std.mem.eql(u8, socket_path[slash + 1 ..], socket_name)) return null;
    const folder = socket_path[0..slash];
    const name_at = std.mem.findScalarLast(u8, folder, '/') orelse return null;
    const base = folder[0..name_at];
    const name = folder[name_at + 1 ..];
    if (base.len == 0 or base[0] != '/') return null;
    if (hasDotPart(base)) return null;
    if (name.len != folder_prefix.len + hex_len) return null;
    if (!std.mem.startsWith(u8, name, folder_prefix)) return null;
    for (name[folder_prefix.len..]) |c| {
        if (!isLowerHex(c)) return null;
    }
    return .{ .base = base, .name = name };
}

/// True when a path has a `.` or `..` part, so its folders are not spelled out.
fn hasDotPart(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn isLowerHex(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f' => true,
        else => false,
    };
}

/// True only when the kernel reports the pid as gone. A pid that is not
/// positive, or that the kernel will not name, counts as alive, so its folder
/// stays.
fn isDeadPid(pid: i64) bool {
    if (pid <= 0 or pid > std.math.maxInt(std.c.pid_t)) return false;
    const rc = std.c.kill(@intCast(pid), @fromBackingInt(@intCast(0)));
    if (rc == 0) return false;
    return std.c.errno(rc) == .SRCH;
}

/// Connects to a leader's socket, retrying while it is busy, until it answers,
/// refuses, or `probe_timeout_ms` passes.
fn probeSocket(io: std.Io, socket_path: []const u8) Probe {
    const started_ms = io_mod.awakeMilliTimestamp();
    while (true) {
        switch (connectOnce(socket_path)) {
            .alive => |fd| {
                _ = std.c.close(fd);
                return .alive;
            },
            .dead => return .dead,
            .busy => {},
            .unknown => return .unknown,
        }
        if (io_mod.awakeMilliTimestamp() - started_ms >= probe_timeout_ms) return .unknown;
        io.sleep(.fromMilliseconds(probe_retry_ms), .awake) catch return .unknown;
    }
}

const Attempt = union(enum) {
    alive: std.c.fd_t,
    dead,
    busy,
    unknown,
};

/// One non-blocking connect. A connected descriptor is returned to the caller,
/// who closes it.
fn connectOnce(socket_path: []const u8) Attempt {
    var address = std.mem.zeroes(posix.sockaddr.un);
    if (socket_path.len >= address.path.len) return .unknown;
    const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return .unknown;
    if (!setNonBlocking(fd)) {
        _ = std.c.close(fd);
        return .unknown;
    }
    address.family = posix.AF.UNIX;
    @memcpy(address.path[0..socket_path.len], socket_path);
    const rc = std.c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address)));
    if (rc == 0) return .{ .alive = fd };
    _ = std.c.close(fd);
    return switch (std.c.errno(rc)) {
        .NOENT, .CONNREFUSED => .dead,
        .AGAIN, .INPROGRESS, .ALREADY, .INTR => .busy,
        else => .unknown,
    };
}

fn setNonBlocking(fd: std.c.fd_t) bool {
    const flags = std.c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return false;
    return std.c.fcntl(fd, posix.F.SETFL, flags | nonblock_flag) >= 0;
}

/// Opens the leader's folder for removal, or says why it must stay. The folder
/// must be a real directory (not a link), private (mode 0700), and owned by
/// this user.
fn openLeaderFolder(io: std.Io, path: LeaderPath) OpenResult {
    const base_dir = std.Io.Dir.cwd().openDir(io, path.base, .{ .iterate = true }) catch return .{ .kept = .folder_missing };
    var base = io_mod.VerifiedDir{ .dir = base_dir };
    const opened = io_mod.openVerifiedPrivateDirIfPresent(&base, path.name) catch |err| {
        base.close();
        return .{ .kept = folderKeepReason(err) };
    };
    var folder = opened orelse {
        base.close();
        return .{ .kept = .folder_missing };
    };
    if (ownerKeepReason(folderOwner(folder.dir), std.c.geteuid())) |reason| {
        folder.close();
        base.close();
        return .{ .kept = reason };
    }
    return .{ .opened = .{ .base = base, .folder = folder } };
}

fn folderKeepReason(err: anyerror) KeepReason {
    return switch (err) {
        error.PrivateStatePermissionsUnsupported => .folder_mode,
        else => .folder_unsafe,
    };
}

/// The owner of an open folder. Linux reads it with `statx`, which the std Io
/// layer also uses; other systems read `fstat` from libc.
fn folderOwner(dir: std.Io.Dir) ?std.c.uid_t {
    if (comptime builtin.os.tag == .linux) {
        var statx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(dir.handle, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true }, &statx);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return statx.uid;
    }
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(dir.handle, &stat) != 0) return null;
    return stat.uid;
}

/// The reason to keep a folder owned by `owner`, or null when `expected` owns
/// it. A folder whose owner is unknown is kept.
fn ownerKeepReason(owner: ?std.c.uid_t, expected: std.c.uid_t) ?KeepReason {
    const actual = owner orelse return .folder_owner;
    return if (actual == expected) null else .folder_owner;
}

/// The reason to keep the folder when its entry `s` exists and is not a socket.
/// The entry is read without following links, so a link of that name keeps it too.
fn socketEntryKeepReason(io: std.Io, dir: std.Io.Dir) ?KeepReason {
    const stat = dir.statFile(io, socket_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return .entry_not_socket,
    };
    return if (stat.kind == .unix_domain_socket) null else .entry_not_socket;
}

/// Unlinks the leader's socket, then removes its folder. A failure is traced,
/// and the other step still runs.
fn removeLeaderFiles(io: std.Io, leader: *LeaderFolder, name: []const u8) void {
    leader.folder.dir.deleteFile(io, socket_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf("acp", "event=dead_leader_socket_not_removed err={s}", .{@errorName(err)}),
    };
    // deleteDir removes only an empty folder, so a file left inside keeps it.
    leader.base.dir.deleteDir(io, name) catch |err| {
        debug_trace.logf("acp", "event=dead_leader_folder_not_removed err={s}", .{@errorName(err)});
        return;
    };
    debug_trace.logf("acp", "event=dead_leader_removed", .{});
}

/// Its pid is the largest a kernel can name, so no process has it.
const no_process_pid: i64 = std.math.maxInt(std.c.pid_t);
const max_fill_attempts = 16;

/// A leader-shaped folder under /tmp, with its socket path. The socket is a
/// plain file until a test binds a listener there.
const TestLeader = struct {
    folder: []u8,
    socket: []u8,

    fn create(io: std.Io, mode: std.posix.mode_t) !TestLeader {
        var random: [random_len]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const folder = try testing.allocator.print("/tmp/" ++ folder_prefix ++ "{s}", .{&hex});
        errdefer testing.allocator.free(folder);
        try std.Io.Dir.cwd().createDir(io, folder, .fromMode(mode));
        const socket = try testing.allocator.print("{s}/" ++ socket_name, .{folder});
        return .{ .folder = folder, .socket = socket };
    }

    fn placeSocketFile(self: TestLeader, io: std.Io) !void {
        const file = try std.Io.Dir.cwd().createFile(io, self.socket, .{});
        file.close(io);
    }

    /// A socket file that no process listens on, as a dead leader leaves it.
    fn placeStaleSocket(self: TestLeader) !void {
        const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.TestSocketFailed;
        defer _ = std.c.close(fd);
        var address = std.mem.zeroes(posix.sockaddr.un);
        address.family = posix.AF.UNIX;
        @memcpy(address.path[0..self.socket.len], self.socket);
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.TestBindFailed;
    }

    fn destroy(self: TestLeader, io: std.Io) void {
        // A test may already have removed the folder; the cleanup must not fail.
        std.Io.Dir.cwd().deleteTree(io, self.folder) catch {};
        testing.allocator.free(self.folder);
        testing.allocator.free(self.socket);
    }
};

/// A listener at `socket` whose queue is full, so a connect to it is busy.
const BusyListener = struct {
    server: std.Io.net.Server,
    held: std.ArrayList(std.c.fd_t),

    fn start(io: std.Io, socket: []const u8) !BusyListener {
        const address = try std.Io.net.UnixAddress.init(socket);
        var busy = BusyListener{ .server = try address.listen(io, .{ .kernel_backlog = 1 }), .held = .empty };
        errdefer busy.stop(io);
        for (0..max_fill_attempts) |_| {
            switch (connectOnce(socket)) {
                .alive => |fd| try busy.held.append(testing.allocator, fd),
                .busy => return busy,
                // macOS refuses a connect to a full queue instead of reporting it busy.
                .dead => if (builtin.os.tag != .linux and busy.held.items.len > 0) return busy else return error.TestListenerNotBusy,
                .unknown => return error.TestListenerNotBusy,
            }
        }
        return error.TestListenerNotBusy;
    }

    fn stop(self: *BusyListener, io: std.Io) void {
        for (self.held.items) |fd| _ = std.c.close(fd);
        self.held.deinit(testing.allocator);
        self.server.deinit(io);
    }
};

test "a socket path counts as a leader's only in the leader's shape" {
    const shaped = leaderPathOf("/tmp/fx-leader-0123456789abcdef/s").?;
    try testing.expectEqualStrings("/tmp", shaped.base);
    try testing.expectEqualStrings("fx-leader-0123456789abcdef", shaped.name);
    try testing.expect(leaderPathOf("/tmp/fx-leader-0123456789abcdef/x") == null);
    try testing.expect(leaderPathOf("/tmp/fx-leader-0123456789abcdef/s/") == null);
    try testing.expect(leaderPathOf("/tmp/fx-leader-0123456789ABCDEF/s") == null);
    try testing.expect(leaderPathOf("/tmp/fx-leader-0123456789abcde/s") == null);
    try testing.expect(leaderPathOf("/tmp/fx-leader-0123456789abcdef0/s") == null);
    try testing.expect(leaderPathOf("/tmp/other-0123456789abcdef/s") == null);
    try testing.expect(leaderPathOf("tmp/fx-leader-0123456789abcdef/s") == null);
    try testing.expect(leaderPathOf("/fx-leader-0123456789abcdef/s") == null);
    const ninety: [90]u8 = @splat('a');
    const long = try testing.allocator.print("/{s}/fx-leader-0123456789abcdef/s", .{ninety[0..]});
    defer testing.allocator.free(long);
    try testing.expect(leaderPathOf(long) == null);
}

test "a socket path whose base has a . or .. part is not a leader's shape, and a name that starts with dots is" {
    try testing.expect(leaderPathOf("/tmp/../tmp/fx-leader-0123456789abcdef/s") == null);
    try testing.expect(leaderPathOf("/tmp/./fx-leader-0123456789abcdef/s") == null);
    try testing.expect(leaderPathOf("/tmp/..x/fx-leader-0123456789abcdef/s") != null);
}

test "a folder owned by another user is kept, and an unknown owner is kept" {
    const mine = std.c.geteuid();
    try testing.expect(ownerKeepReason(mine, mine) == null);
    try testing.expectEqual(KeepReason.folder_owner, ownerKeepReason(mine +% 1, mine).?);
    try testing.expectEqual(KeepReason.folder_owner, ownerKeepReason(null, mine).?);
}

test "a pid that no process has is dead, and this process is alive" {
    try testing.expect(isDeadPid(no_process_pid));
    try testing.expect(!isDeadPid(@intCast(std.c.getpid())));
    try testing.expect(!isDeadPid(0));
}

test "a socket with no file is dead" {
    try testing.expectEqual(Probe.dead, probeSocket(testing.io, "/tmp/fx-leader-0000000000000000/s"));
}

test "a socket that accepts a connection is alive" {
    const io = testing.io;
    const leader = try leader_mod.Leader.start(testing.allocator, io, null, .{ .context = null, .run = NoopRunner.run });
    defer leader.stop(io);
    try testing.expectEqual(Probe.alive, probeSocket(io, leader.socket_path));
}

test "a socket whose queue stays full is unknown after probe_timeout_ms on Linux and dead at once on macOS" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    var busy = try BusyListener.start(io, leader.socket);
    defer busy.stop(io);

    const started_ms = io_mod.awakeMilliTimestamp();
    const probe = probeSocket(io, leader.socket);
    const elapsed_ms = io_mod.awakeMilliTimestamp() - started_ms;
    if (builtin.os.tag == .linux) {
        try testing.expectEqual(Probe.unknown, probe);
        try testing.expect(elapsed_ms >= probe_timeout_ms);
    } else {
        // macOS refuses a connect to a full queue at once, so the probe reads
        // it as dead without waiting. Only a live pid keeps such a folder there.
        try testing.expectEqual(Probe.dead, probe);
        try testing.expect(elapsed_ms < probe_timeout_ms);
    }
}

test "a dead leader's socket and folder are removed" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(leader_mod.pathGone(io, leader.socket));
    try testing.expect(leader_mod.pathGone(io, leader.folder));
}

test "a live pid keeps the folder and its socket" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, @intCast(std.c.getpid()));
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!leader_mod.pathGone(io, leader.socket));
    try testing.expect(!leader_mod.pathGone(io, leader.folder));
}

test "a live pid keeps the folder when its socket file is missing" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, @intCast(std.c.getpid()));
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!leader_mod.pathGone(io, leader.folder));
}

test "a socket that answers keeps its folder, even when its pid is gone" {
    const io = testing.io;
    const leader = try leader_mod.Leader.start(testing.allocator, io, null, .{ .context = null, .run = NoopRunner.run });
    var stopped = false;
    defer if (!stopped) leader.stop(io);
    const socket_copy = try testing.allocator.dupe(u8, leader.socket_path);
    defer testing.allocator.free(socket_copy);
    const line = try leader_mod.recordBytes(testing.allocator, socket_copy, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!leader_mod.pathGone(io, socket_copy));
    stopped = true;
    leader.stop(io);
    try testing.expect(leader_mod.pathGone(io, socket_copy));
}

test "a socket whose queue stays full keeps its folder (dead pid on Linux, live pid on macOS)" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    var busy = try BusyListener.start(io, leader.socket);
    defer busy.stop(io);
    // On macOS a full queue reads as refused, which is dead, so only a live pid keeps this folder.
    const pid: i64 = if (builtin.os.tag == .linux) no_process_pid else @intCast(std.c.getpid());
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!leader_mod.pathGone(io, leader.folder));
}

test "a folder with mode 0755 is kept" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o755);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);
    const path = leaderPathOf(leader.socket).?;

    switch (openLeaderFolder(io, path)) {
        .kept => |reason| try testing.expectEqual(KeepReason.folder_mode, reason),
        .opened => |opened| {
            var folder = opened;
            folder.close();
            return error.TestFolderOpened;
        },
    }
    try testing.expect(!leader_mod.pathGone(io, leader.socket));
}

test "a folder reached through a symlink is kept, and the folder it points at stays" {
    const io = testing.io;
    var target = try TestLeader.create(io, 0o700);
    defer target.destroy(io);
    try target.placeSocketFile(io);
    var link = try TestLeader.create(io, 0o700);
    defer link.destroy(io);
    try std.Io.Dir.cwd().deleteDir(io, link.folder);
    try std.Io.Dir.cwd().symLink(io, target.folder, link.folder, .{});
    const line = try leader_mod.recordBytes(testing.allocator, link.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    const stat = try std.Io.Dir.cwd().statFile(io, link.folder, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, stat.kind);
    try testing.expect(!leader_mod.pathGone(io, target.socket));
}

test "a socket path outside the leader's shape keeps its folder" {
    const io = testing.io;
    var victim = try TestLeader.create(io, 0o700);
    defer victim.destroy(io);
    try victim.placeSocketFile(io);
    const escaping = try testing.allocator.print("{s}/../x", .{victim.socket});
    defer testing.allocator.free(escaping);
    const line = try leader_mod.recordBytes(testing.allocator, escaping, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!leader_mod.pathGone(io, victim.socket));
}

test "a lock line that does not parse keeps every folder" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);

    takeOverDeadLeader(io, "not a record\n");

    try testing.expect(!leader_mod.pathGone(io, leader.socket));
}

test "a plain file named s in a leader's folder is kept, even when its pid is gone" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!leader_mod.pathGone(io, leader.socket));
    try testing.expect(!leader_mod.pathGone(io, leader.folder));
}

/// Runs one takeover with debug tracing into a temporary file, and returns the
/// trace the caller frees.
fn takeOverTraced(io: std.Io, line: []const u8) ![]u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(dir_path);
    const trace_path = try testing.allocator.print("{s}/trace.log", .{dir_path});
    defer testing.allocator.free(trace_path);
    try debug_trace.configureForTest(testing.allocator, trace_path);
    defer debug_trace.resetForTest();
    takeOverDeadLeader(io, line);
    return tmp.dir.readFileAlloc(io, "trace.log", testing.allocator, .limited(1 << 16));
}

test "a symlinked leader folder is refused before its socket is probed" {
    const io = testing.io;
    const leader = try leader_mod.Leader.start(testing.allocator, io, null, .{ .context = null, .run = NoopRunner.run });
    defer leader.stop(io);
    var link = try TestLeader.create(io, 0o700);
    defer link.destroy(io);
    try std.Io.Dir.cwd().deleteDir(io, link.folder);
    try std.Io.Dir.cwd().symLink(io, leader.folder_path, link.folder, .{});
    const line = try leader_mod.recordBytes(testing.allocator, link.socket, no_process_pid);
    defer testing.allocator.free(line);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(std.mem.find(u8, trace, "reason=folder_unsafe") != null);
    try testing.expect(std.mem.find(u8, trace, "reason=probe_alive") == null);
    try testing.expect(!leader_mod.pathGone(io, leader.socket_path));
}

test "a lock line whose socket path has an escape is read as its bytes, and its folder is removed" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const line = try testing.allocator.print("{{\"socket\":\"{s}/\\u0073\",\"pid\":{d}}}", .{ leader.folder, no_process_pid });
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(leader_mod.pathGone(io, leader.socket));
    try testing.expect(leader_mod.pathGone(io, leader.folder));
}

test "a lock line over the limit is kept and traced, even when its record parses" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const record = try leader_mod.recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(record);
    const line = try testing.allocator.alloc(u8, max_record_bytes + 1);
    defer testing.allocator.free(line);
    @memset(line, ' ');
    @memcpy(line[0..record.len], record);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(std.mem.find(u8, trace, "reason=line_too_long") != null);
    try testing.expect(!leader_mod.pathGone(io, leader.socket));
    try testing.expect(!leader_mod.pathGone(io, leader.folder));
}

test "a removal that fails after the socket is unlinked keeps the folder, traces it, and the open goes on" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const left_behind = try testing.allocator.print("{s}/left-behind", .{leader.folder});
    defer testing.allocator.free(left_behind);
    const file = try std.Io.Dir.cwd().createFile(io, left_behind, .{});
    file.close(io);
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(leader_mod.pathGone(io, leader.socket));
    try testing.expect(!leader_mod.pathGone(io, leader.folder));
    try testing.expect(std.mem.find(u8, trace, "event=dead_leader_folder_not_removed") != null);
}

test "a second takeover of the same lock line finds nothing to remove and does not fail" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);
    takeOverDeadLeader(io, line);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(leader_mod.pathGone(io, leader.folder));
    try testing.expect(std.mem.find(u8, trace, "reason=folder_missing") != null);
}

test "a lock record parses or is refused on fuzzed bytes, and what parses writes back the same" {
    try testing.fuzz({}, fuzzLockRecord, .{ .corpus = &(@import("fuzz_seed").slices(.{
        "{\"socket\":\"/tmp/fx-leader-0123456789abcdef/s\",\"pid\":4242}\n",
        "{\"pid\":-1,\"socket\":\"/x/s\"}",
        "{\"socket\":\"/tmp/a\\\"b/s\",\"pid\":7}",
        "not a record",
        "[]",
    }) ++ @import("fuzz_corpus").lock_record.*) });
}

fn fuzzLockRecord(_: void, smith: *testing.Smith) anyerror!void {
    var input: [max_record_bytes]u8 = undefined;
    const len = smith.slice(&input);
    var buffer: [max_record_bytes]u8 = undefined;
    const record = parseRecord(&buffer, input[0..len]) catch return;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try leader_mod.writeRecord(&out.writer, record.socket, record.pid);
    var again_buffer: [max_record_bytes]u8 = undefined;
    const again = try parseRecord(&again_buffer, out.writer.buffered());
    try testing.expectEqualStrings(record.socket, again.socket);
    try testing.expectEqual(record.pid, again.pid);
}

test "a dead leader's folder with no socket left in it is removed" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    const line = try leader_mod.recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(leader_mod.pathGone(io, leader.folder));
}

//! The leader socket: one Unix socket per `fx acp` process, recorded in each
//! session lock the process holds, so another process can find the holder.
//! Each client that connects is served as a full ACP connection by the
//! `ConnectionRunner` the process gives, so it shares the process's sessions and
//! store. This file knows nothing of ACP: it accepts, bounds, and stops.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const json_decode = @import("../core/shared/json_decode.zig");
const session_manager = @import("session_manager");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A Unix socket path must fit `sun_path`, which holds 104 bytes on macOS with
/// the NUL. Std copies a longer path without checking, so `Leader.start` checks
/// it too.
const max_socket_path_bytes = 103;
/// Connections served at once. A connection past this is closed at once, so
/// one client cannot hold every thread.
const max_connections = 16;
/// How long one reply may take to reach a client, counted over the whole
/// reply. `stop` waits for every connection, so no write may take longer than
/// this: a client that stops reading, or reads too slowly, is dropped after it.
const max_write_wait_ms = 1000;
/// How often the accept loop and each connection check the stop flag. Stop
/// therefore waits at most this long.
const poll_ms = 100;
const folder_prefix = "fx-leader-";
const random_len = 8;
const hex_len = random_len * 2;
const socket_name = "s";
/// Used when TMPDIR is missing, or when its socket path would be too long.
const fallback_base = "/tmp";

/// The folder base for the leader's socket: `tmpdir` with its trailing slashes
/// trimmed, when it is absolute and `{base}/fx-leader-{16 hex}/s` stays within
/// the socket limit. Otherwise `/tmp`, which is short enough. A null, empty, or
/// relative `tmpdir` gives `/tmp`, so the socket path never depends on the
/// working directory.
pub fn socketBase(tmpdir: ?[]const u8) []const u8 {
    const raw = tmpdir orelse return fallback_base;
    if (!std.mem.startsWith(u8, raw, "/")) return fallback_base;
    const base = std.mem.trimEnd(u8, raw, "/");
    if (base.len == 0 or socketPathLen(base) > max_socket_path_bytes) return fallback_base;
    return base;
}

/// The length of `{base}/fx-leader-{16 hex}/s`.
fn socketPathLen(base: []const u8) usize {
    return base.len + "/".len + folder_prefix.len + hex_len + "/".len + socket_name.len;
}

/// Writes the record a session lock holds for this process: one JSON line with
/// the socket path and the pid. The session manager stores the bytes without
/// reading them; a reader connects to the socket to check the holder.
pub fn writeRecord(w: *std.Io.Writer, socket_path: []const u8, pid: i64) !void {
    try w.writeAll("{\"socket\":");
    try jsonrpc.writeJsonStr(socket_path, w);
    try w.print(",\"pid\":{d}}}\n", .{pid});
}

fn recordBytes(alloc: Allocator, socket_path: []const u8, pid: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeRecord(&out.writer, socket_path, pid);
    return out.toOwnedSlice();
}

/// How the leader reads the sessions its process leads. The owner keeps them
/// under its own lock; `copy_ids` copies them out, so the socket thread never
/// reads the owner's list. The caller frees each id and the slice.
pub const SessionList = struct {
    context: ?*anyopaque,
    copy_ids: *const fn (context: ?*anyopaque, alloc: Allocator) error{OutOfMemory}![][]u8,
};

/// Serves one accepted connection as a full ACP connection. `run` gets the
/// socket's reader and writer, and returns when the connection ends. server.zig
/// gives it, so this file stays free of server.zig.
pub const ConnectionRunner = struct {
    context: ?*anyopaque,
    run: *const fn (context: ?*anyopaque, reader: jsonrpc.Reader, writer: jsonrpc.Writer) void,
};

pub const Leader = struct {
    alloc: Allocator,
    io: std.Io,
    runner: ConnectionRunner,
    /// `{base}/fx-leader-{hex}`: the folder that holds the socket, removed at stop.
    folder_path: []u8,
    /// `{folder_path}/s`: the socket another process connects to.
    socket_path: []u8,
    /// The record `writeRecord` wrote for `socket_path` and this pid.
    record: []u8,
    listener: std.Io.net.Server,
    accept_task: ?std.Io.Future(void) = null,
    connections: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    open_connections: usize = 0,
    stop_flag: std.atomic.Value(bool) = .init(false),

    /// Starts the leader: makes the folder, binds the socket in it, and starts
    /// the accept loop. Each connection is served by `runner`. The caller ends it
    /// with `stop`.
    pub fn start(
        alloc: Allocator,
        io: std.Io,
        tmpdir: ?[]const u8,
        runner: ConnectionRunner,
    ) !*Leader {
        var random: [random_len]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const base = socketBase(tmpdir);
        const pid: i64 = @intCast(std.c.getpid());

        const self = try alloc.create(Leader);
        errdefer alloc.destroy(self);
        const folder_path = try alloc.print("{s}/" ++ folder_prefix ++ "{s}", .{ base, &hex });
        errdefer alloc.free(folder_path);
        const socket_path = try alloc.print("{s}/" ++ socket_name, .{folder_path});
        errdefer alloc.free(socket_path);
        if (socket_path.len > max_socket_path_bytes) return error.SocketPathTooLong;
        const record = try recordBytes(alloc, socket_path, pid);
        errdefer alloc.free(record);

        // The errdefers run in reverse: the listener closes, then the socket
        // file is unlinked, then the folder is removed. The folder must be
        // empty for that last step, so the socket goes first. A failure here is
        // not traced: the error returned to the caller is the one that counts.
        try std.Io.Dir.cwd().createDir(io, folder_path, .fromMode(0o700));
        errdefer std.Io.Dir.cwd().deleteDir(io, folder_path) catch {};
        const address = try std.Io.net.UnixAddress.init(socket_path);
        errdefer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .runner = runner,
            .folder_path = folder_path,
            .socket_path = socket_path,
            .record = record,
            .listener = listener,
        };
        self.accept_task = try std.Io.concurrent(io, acceptLoop, .{self});
        return self;
    }

    /// Stops the leader and frees it. It returns within `poll_ms` plus
    /// `max_write_wait_ms`: each loop sees the stop flag at its next poll, and a
    /// write that is blocked ends at its send time limit. Then the socket and
    /// its folder are removed.
    pub fn stop(self: *Leader, io: std.Io) void {
        self.stop_flag.store(true, .release);
        if (self.accept_task) |*task| task.await(io);
        self.connections.cancel(io);
        self.listener.deinit(io);
        removeSocketFiles(io, self.socket_path, self.folder_path);
        const alloc = self.alloc;
        alloc.free(self.record);
        alloc.free(self.socket_path);
        alloc.free(self.folder_path);
        alloc.destroy(self);
    }

    /// Polls the listener so that a stop is seen within `poll_ms`, and hands
    /// each accepted connection to the group while there is room for it.
    fn acceptLoop(self: *Leader) void {
        while (!self.stop_flag.load(.acquire)) {
            var fds = [_]posix.pollfd{.{ .fd = self.listener.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, poll_ms) catch |err| {
                debug_trace.logf("acp", "event=leader_accept_ended err={s}", .{@errorName(err)});
                return;
            };
            if (ready == 0) continue;
            const stream = self.listener.accept(self.io) catch |err| {
                debug_trace.logf("acp", "event=leader_accept_failed err={s}", .{@errorName(err)});
                continue;
            };
            configureConnection(stream.socket.handle) catch |err| {
                debug_trace.logf("acp", "event=leader_connection_dropped err={s}", .{@errorName(err)});
                stream.close(self.io);
                continue;
            };
            if (!self.reserveConnection()) {
                debug_trace.logf("acp", "event=leader_connection_dropped open={d}", .{max_connections});
                stream.close(self.io);
                continue;
            }
            self.connections.concurrent(self.io, serveConnection, .{ self, stream }) catch |err| {
                debug_trace.logf("acp", "event=leader_connection_dropped err={s}", .{@errorName(err)});
                self.finishConnection(stream);
                continue;
            };
        }
    }

    fn reserveConnection(self: *Leader) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.open_connections >= max_connections) return false;
        self.open_connections += 1;
        return true;
    }

    /// Closes the stream and frees its slot, so the next connection can come in.
    fn finishConnection(self: *Leader, stream: std.Io.net.Stream) void {
        stream.close(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.open_connections -= 1;
    }

    /// Serves one client as a full ACP connection: the runner reads its requests
    /// from the socket and writes its answers to it. Returns when the runner
    /// returns, which is when the client closed, the leader stopped, or a write
    /// failed.
    fn serveConnection(self: *Leader, stream: std.Io.net.Stream) void {
        defer self.finishConnection(stream);
        const fd = stream.socket.handle;
        var sink: Sink = .{ .fd = fd };
        const writer = jsonrpc.Writer.initCallback(&sink, Sink.write);
        var source: SocketSource = .{ .stop_flag = &self.stop_flag, .fd = fd };
        const reader = jsonrpc.Reader.initCallback(&source, SocketSource.read);
        self.runner.run(self.runner.context, reader, writer);
    }
};

/// Removes the socket file, then its folder. A failure is traced and left
/// behind: the folder name is random, so a leftover never blocks a later start.
fn removeSocketFiles(io: std.Io, socket_path: []const u8, folder_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| {
        debug_trace.logf("acp", "event=leader_socket_not_removed err={s}", .{@errorName(err)});
    };
    std.Io.Dir.cwd().deleteDir(io, folder_path) catch |err| {
        debug_trace.logf("acp", "event=leader_folder_not_removed err={s}", .{@errorName(err)});
    };
}

/// Gives an accepted connection its send time limit, `max_write_wait_ms`; each
/// reply then narrows it to the time it has left (`sendAll`). On macOS, where a
/// send to a closed peer raises SIGPIPE unless the socket says otherwise, it
/// also sets SO_NOSIGPIPE; `sendAll` passes MSG.NOSIGNAL on every platform.
fn configureConnection(fd: posix.socket_t) SocketOptionError!void {
    const limit = posix.timeval{ .sec = max_write_wait_ms / 1000, .usec = 0 };
    try setSocketOption(fd, posix.SO.SNDTIMEO, std.mem.asBytes(&limit));
    if (comptime builtin.os.tag == .macos) {
        const on: c_int = 1;
        try setSocketOption(fd, posix.SO.NOSIGPIPE, std.mem.asBytes(&on));
    }
}

const SocketOptionError = error{ ConnectionClosed, SetOptionFailed };

/// Sets one socket option at the socket level. Std's `posix.setsockopt` maps
/// EINVAL to unreachable, and macOS returns EINVAL for a socket whose peer has
/// shut it down (setsockopt(2): "The socket has been shut down"), so a client
/// that leaves early would crash fx. Here an errno that a shut-down or reset
/// peer can cause, or that means the descriptor is no longer a socket, becomes
/// `ConnectionClosed`. Any other errno becomes `SetOptionFailed`.
fn setSocketOption(fd: posix.socket_t, optname: u32, value: []const u8) SocketOptionError!void {
    const rc = std.c.setsockopt(fd, posix.SOL.SOCKET, optname, value.ptr, @intCast(value.len));
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        .INVAL, .BADF, .NOTSOCK, .CONNRESET => error.ConnectionClosed,
        else => error.SetOptionFailed,
    };
}

/// Sends all of `bytes` before `deadline_ms`, a `io_mod.milliTimestamp` value.
/// SO_SNDTIMEO applies to each send call, and a send that moves some bytes
/// returns early, so the limit is set to the time left before each call. A send
/// that cannot proceed fails with EAGAIN, which becomes `error.WriteTimedOut`.
/// Std's stream writer is not used here: it treats EAGAIN as a programmer bug,
/// which panics in Debug builds (`Threaded.errnoBug`).
fn sendAll(fd: posix.socket_t, bytes: []const u8, deadline_ms: i64) error{ WriteTimedOut, WriteFailed }!void {
    var rest = bytes;
    while (rest.len > 0) {
        const remaining = deadline_ms - io_mod.milliTimestamp();
        if (remaining <= 0) return error.WriteTimedOut;
        setSendLimit(fd, remaining) catch return error.WriteFailed;
        const rc = std.c.send(fd, rest.ptr, rest.len, posix.MSG.NOSIGNAL);
        if (rc < 0) switch (posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return error.WriteTimedOut,
            else => return error.WriteFailed,
        };
        rest = rest[@intCast(rc)..];
    }
}

/// Sets SO_SNDTIMEO to `ms` (at least 1, since a zero timeval means no limit).
fn setSendLimit(fd: posix.socket_t, ms: i64) SocketOptionError!void {
    const limit = posix.timeval{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .usec = @intCast(@mod(ms, 1000) * 1000),
    };
    try setSocketOption(fd, posix.SO.SNDTIMEO, std.mem.asBytes(&limit));
}

/// Writes the frames of one connection. Each frame gets `max_write_wait_ms`
/// from its start, so a client that stops reading, or reads too slowly, ends
/// the write at that deadline.
const Sink = struct {
    fd: posix.socket_t,

    fn write(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const sink: *Sink = @ptrCast(@alignCast(context.?));
        try sendAll(sink.fd, bytes, io_mod.milliTimestamp() + max_write_wait_ms);
    }
};

/// The read side of one connection. It waits in `poll_ms` steps, so it sees the
/// stop flag, and it reports end of input when the leader stops, when the client
/// closes, and when a read fails. A stop therefore ends a connection the way a
/// client that closed its input does. Lines the reader already holds are still
/// answered first, since the reader serves them before it asks for more input.
const SocketSource = struct {
    stop_flag: *const std.atomic.Value(bool),
    fd: posix.socket_t,

    fn read(context: ?*anyopaque, buffer: []u8) usize {
        const source: *SocketSource = @ptrCast(@alignCast(context.?));
        while (!source.stop_flag.load(.acquire)) {
            var fds = [_]posix.pollfd{.{ .fd = source.fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, poll_ms) catch |err| {
                debug_trace.logf("acp", "event=leader_poll_failed err={s}", .{@errorName(err)});
                return 0;
            };
            if (ready == 0) continue;
            const n = posix.read(source.fd, buffer) catch |err| {
                debug_trace.logf("acp", "event=leader_read_failed err={s}", .{@errorName(err)});
                return 0;
            };
            if (n == 0) debug_trace.logf("acp", "event=leader_client_closed", .{});
            return n;
        }
        debug_trace.logf("acp", "event=leader_connection_stopped", .{});
        return 0;
    }
};

/// How long a takeover waits for a leader's socket to accept a connection. A
/// socket that stays busy this long keeps its folder.
const probe_timeout_ms: i64 = 200;
/// The pause between two connection attempts to the same socket.
const probe_retry_ms: u64 = 10;
const nonblock_flag: c_int = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
/// The most bytes of a lock line a takeover takes as a record. The session owns
/// the limit: a longer line reaches the takeover one byte past it.
const max_record_bytes = session_manager.max_lock_line_bytes;
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
    if (name.len != folder_prefix.len + hex_len) return null;
    if (!std.mem.startsWith(u8, name, folder_prefix)) return null;
    for (name[folder_prefix.len..]) |c| {
        if (!isLowerHex(c)) return null;
    }
    return .{ .base = base, .name = name };
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

test "socketBase keeps TMPDIR and trims its trailing slashes when the socket path fits" {
    try testing.expectEqualStrings("/var/folders/ab/T", socketBase("/var/folders/ab/T/"));
    try testing.expectEqualStrings("/tmp/x", socketBase("/tmp/x///"));
}

test "socketBase falls back to /tmp for a null, empty, root, or relative TMPDIR, and for a long one" {
    try testing.expectEqualStrings("/tmp", socketBase(null));
    try testing.expectEqualStrings("/tmp", socketBase(""));
    try testing.expectEqualStrings("/tmp", socketBase("/"));
    try testing.expectEqualStrings("/tmp", socketBase("tmp"));
    try testing.expectEqualStrings("/tmp", socketBase("./t"));
    var long: [80]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '/';
    try testing.expectEqualStrings("/tmp", socketBase(&long));
}

test "socketBase keeps a base of 74 bytes, whose socket path is 103, and refuses 75" {
    var at_limit: [74]u8 = undefined;
    @memset(&at_limit, 'a');
    at_limit[0] = '/';
    try testing.expectEqualStrings(&at_limit, socketBase(&at_limit));
    var over: [75]u8 = undefined;
    @memset(&over, 'a');
    over[0] = '/';
    try testing.expectEqualStrings("/tmp", socketBase(&over));
}

test "writeRecord writes one JSON line with the socket path and the pid" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeRecord(&out.writer, "/tmp/fx-leader-0123456789abcdef/s", 42);
    try testing.expectEqualStrings("{\"socket\":\"/tmp/fx-leader-0123456789abcdef/s\",\"pid\":42}\n", out.writer.buffered());
}

test "writeRecord escapes a quote in the socket path, and the line is still valid JSON" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeRecord(&out.writer, "/tmp/a\"b/s", 7);
    try testing.expectEqualStrings("{\"socket\":\"/tmp/a\\\"b/s\",\"pid\":7}\n", out.writer.buffered());
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/a\"b/s", parsed.value.object.get("socket").?.string);
}

/// Stands in for the connection runner `server.zig` gives. It answers each request
/// line with a result, and it ends when a read or a write fails, as `runServer` does.
const FakeRunner = struct {
    /// Set when a request whose method is `ping` arrives.
    got_ping: std.atomic.Value(bool) = .init(false),
    /// Set when the runner returns, so a test can see that the connection ended.
    done: std.atomic.Value(bool) = .init(false),

    fn run(context: ?*anyopaque, reader: jsonrpc.Reader, writer: jsonrpc.Writer) void {
        const self: *FakeRunner = @ptrCast(@alignCast(context.?));
        defer self.done.store(true, .release);
        var input = reader;
        var output = writer;
        while (true) {
            const read = (input.readLine(testing.allocator) catch return) orelse return;
            switch (read) {
                .overflow => return,
                .line => |line| {
                    defer testing.allocator.free(line);
                    if (std.mem.find(u8, line, "\"method\":\"ping\"") != null) self.got_ping.store(true, .release);
                    output.writeResponse(testing.allocator, jsonrpc.RequestId{ .integer = 7 }, "{\"ok\":true}") catch return;
                },
            }
        }
    }
};

fn pathGone(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| return err == error.FileNotFound;
    return false;
}

fn sendLine(io: std.Io, stream: std.Io.net.Stream, line: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

/// Reads one reply line, without its newline, one byte at a time.
fn readReplyLine(fd: posix.socket_t, buffer: []u8) ![]const u8 {
    var length: usize = 0;
    while (length < buffer.len) {
        const n = try posix.read(fd, buffer[length .. length + 1]);
        if (n == 0) return error.EndOfStream;
        if (buffer[length] == '\n') return buffer[0..length];
        length += 1;
    }
    return error.LineTooLong;
}

test "a leader hands each connection a reader and a writer: a request reaches the runner, its reply reaches the client, and stop waits for the connection to end" {
    const io = testing.io;
    const alloc = testing.allocator;
    var fake: FakeRunner = .{};
    const leader = try Leader.start(alloc, io, null, .{ .context = &fake, .run = FakeRunner.run });
    var stopped = false;
    defer if (!stopped) leader.stop(io);
    const socket_copy = try alloc.dupe(u8, leader.socket_path);
    defer alloc.free(socket_copy);
    const folder_copy = try alloc.dupe(u8, leader.folder_path);
    defer alloc.free(folder_copy);

    const address = try std.Io.net.UnixAddress.init(socket_copy);
    const client = try address.connect(io);
    var client_closed = false;
    defer if (!client_closed) client.close(io);
    try sendLine(io, client, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\",\"params\":{}}\n");
    var buffer: [1024]u8 = undefined;
    const reply = try readReplyLine(client.socket.handle, &buffer);
    try testing.expect(std.mem.find(u8, reply, "\"id\":7") != null);
    try testing.expect(std.mem.find(u8, reply, "\"result\":{\"ok\":true}") != null);
    try testing.expect(fake.got_ping.load(.acquire));

    client.close(io);
    client_closed = true;
    leader.stop(io);
    stopped = true;
    try testing.expect(fake.done.load(.acquire));
    try testing.expect(pathGone(io, socket_copy));
    try testing.expect(pathGone(io, folder_copy));
}

const request_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{}}\n";
/// The most lines the stall test sends. The test fails if the client never
/// stops sending within this many lines; then this number must go up.
const never_read_lines = 5000;

/// Sends one whole line without waiting. Returns false when the client can send
/// no more: its buffer is full (AGAIN, or NOBUFS on macOS), or the leader has
/// dropped the connection at its write deadline (PIPE, CONNRESET). Any other
/// errno returns error.SendFailed, which fails the test that sends the line.
fn sendLineNoWait(fd: posix.socket_t, line: []const u8) !bool {
    const rc = std.c.send(fd, line.ptr, line.len, posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT);
    if (rc < 0) switch (posix.errno(rc)) {
        .AGAIN, .NOBUFS, .PIPE, .CONNRESET => return false,
        else => return error.SendFailed,
    };
    return @as(usize, @intCast(rc)) == line.len;
}

test "a client that never reads cannot hold up stop: it returns within 3 s and removes the socket and folder" {
    const io = testing.io;
    const alloc = testing.allocator;
    var fake: FakeRunner = .{};
    const leader = try Leader.start(alloc, io, null, .{ .context = &fake, .run = FakeRunner.run });
    var stopped = false;
    defer if (!stopped) leader.stop(io);
    const socket_copy = try alloc.dupe(u8, leader.socket_path);
    defer alloc.free(socket_copy);
    const folder_copy = try alloc.dupe(u8, leader.folder_path);
    defer alloc.free(folder_copy);

    const address = try std.Io.net.UnixAddress.init(socket_copy);
    const client = try address.connect(io);
    var client_closed = false;
    defer if (!client_closed) client.close(io);
    // The client sends and never reads. The leader's answers fill the
    // connection, so its writes block. The client stops when it can send no
    // more, because its buffer is full or the leader has dropped it.
    var send_refused = false;
    for (0..never_read_lines) |_| {
        if (!try sendLineNoWait(client.socket.handle, request_line)) {
            send_refused = true;
            break;
        }
    }
    try testing.expect(send_refused);

    const started = io_mod.milliTimestamp();
    leader.stop(io);
    stopped = true;
    const elapsed_ms = io_mod.milliTimestamp() - started;
    client.close(io);
    client_closed = true;
    try testing.expect(elapsed_ms < 3000);
    try testing.expect(pathGone(io, socket_copy));
    try testing.expect(pathGone(io, folder_copy));
}

test "setSocketOption answers a descriptor that is not open with ConnectionClosed" {
    const limit = posix.timeval{ .sec = 1, .usec = 0 };
    try testing.expectError(error.ConnectionClosed, setSocketOption(-1, posix.SO.SNDTIMEO, std.mem.asBytes(&limit)));
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
    var fake: FakeRunner = .{};
    const leader = try Leader.start(testing.allocator, io, null, .{ .context = &fake, .run = FakeRunner.run });
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
    const line = try recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(pathGone(io, leader.socket));
    try testing.expect(pathGone(io, leader.folder));
}

test "a live pid keeps the folder and its socket" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);
    const line = try recordBytes(testing.allocator, leader.socket, @intCast(std.c.getpid()));
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!pathGone(io, leader.socket));
    try testing.expect(!pathGone(io, leader.folder));
}

test "a live pid keeps the folder when its socket file is missing" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    const line = try recordBytes(testing.allocator, leader.socket, @intCast(std.c.getpid()));
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!pathGone(io, leader.folder));
}

test "a socket that answers keeps its folder, even when its pid is gone" {
    const io = testing.io;
    var fake: FakeRunner = .{};
    const leader = try Leader.start(testing.allocator, io, null, .{ .context = &fake, .run = FakeRunner.run });
    var stopped = false;
    defer if (!stopped) leader.stop(io);
    const socket_copy = try testing.allocator.dupe(u8, leader.socket_path);
    defer testing.allocator.free(socket_copy);
    const line = try recordBytes(testing.allocator, socket_copy, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!pathGone(io, socket_copy));
    stopped = true;
    leader.stop(io);
    try testing.expect(pathGone(io, socket_copy));
}

test "a socket whose queue stays full keeps its folder (dead pid on Linux, live pid on macOS)" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    var busy = try BusyListener.start(io, leader.socket);
    defer busy.stop(io);
    // On macOS a full queue reads as refused, which is dead, so only a live pid keeps this folder.
    const pid: i64 = if (builtin.os.tag == .linux) no_process_pid else @intCast(std.c.getpid());
    const line = try recordBytes(testing.allocator, leader.socket, pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!pathGone(io, leader.folder));
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
    try testing.expect(!pathGone(io, leader.socket));
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
    const line = try recordBytes(testing.allocator, link.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    const stat = try std.Io.Dir.cwd().statFile(io, link.folder, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, stat.kind);
    try testing.expect(!pathGone(io, target.socket));
}

test "a socket path outside the leader's shape keeps its folder" {
    const io = testing.io;
    var victim = try TestLeader.create(io, 0o700);
    defer victim.destroy(io);
    try victim.placeSocketFile(io);
    const escaping = try testing.allocator.print("{s}/../x", .{victim.socket});
    defer testing.allocator.free(escaping);
    const line = try recordBytes(testing.allocator, escaping, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!pathGone(io, victim.socket));
}

test "a lock line that does not parse keeps every folder" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);

    takeOverDeadLeader(io, "not a record\n");

    try testing.expect(!pathGone(io, leader.socket));
}

test "a plain file named s in a leader's folder is kept, even when its pid is gone" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeSocketFile(io);
    const line = try recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(!pathGone(io, leader.socket));
    try testing.expect(!pathGone(io, leader.folder));
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
    var fake: FakeRunner = .{};
    const leader = try Leader.start(testing.allocator, io, null, .{ .context = &fake, .run = FakeRunner.run });
    defer leader.stop(io);
    var link = try TestLeader.create(io, 0o700);
    defer link.destroy(io);
    try std.Io.Dir.cwd().deleteDir(io, link.folder);
    try std.Io.Dir.cwd().symLink(io, leader.folder_path, link.folder, .{});
    const line = try recordBytes(testing.allocator, link.socket, no_process_pid);
    defer testing.allocator.free(line);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(std.mem.find(u8, trace, "reason=folder_unsafe") != null);
    try testing.expect(std.mem.find(u8, trace, "reason=probe_alive") == null);
    try testing.expect(!pathGone(io, leader.socket_path));
}

test "a lock line whose socket path has an escape is read as its bytes, and its folder is removed" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const line = try testing.allocator.print("{{\"socket\":\"{s}/\\u0073\",\"pid\":{d}}}", .{ leader.folder, no_process_pid });
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(pathGone(io, leader.socket));
    try testing.expect(pathGone(io, leader.folder));
}

test "a lock line over the limit is kept and traced, even when its record parses" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const record = try recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(record);
    const line = try testing.allocator.alloc(u8, session_manager.max_lock_line_bytes + 1);
    defer testing.allocator.free(line);
    @memset(line, ' ');
    @memcpy(line[0..record.len], record);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(std.mem.find(u8, trace, "reason=line_too_long") != null);
    try testing.expect(!pathGone(io, leader.socket));
    try testing.expect(!pathGone(io, leader.folder));
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
    const line = try recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(pathGone(io, leader.socket));
    try testing.expect(!pathGone(io, leader.folder));
    try testing.expect(std.mem.find(u8, trace, "event=dead_leader_folder_not_removed") != null);
}

test "a second takeover of the same lock line finds nothing to remove and does not fail" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    try leader.placeStaleSocket();
    const line = try recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);
    takeOverDeadLeader(io, line);

    const trace = try takeOverTraced(io, line);
    defer testing.allocator.free(trace);

    try testing.expect(pathGone(io, leader.folder));
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
    try writeRecord(&out.writer, record.socket, record.pid);
    var again_buffer: [max_record_bytes]u8 = undefined;
    const again = try parseRecord(&again_buffer, out.writer.buffered());
    try testing.expectEqualStrings(record.socket, again.socket);
    try testing.expectEqual(record.pid, again.pid);
}

test "a dead leader's folder with no socket left in it is removed" {
    const io = testing.io;
    var leader = try TestLeader.create(io, 0o700);
    defer leader.destroy(io);
    const line = try recordBytes(testing.allocator, leader.socket, no_process_pid);
    defer testing.allocator.free(line);

    takeOverDeadLeader(io, line);

    try testing.expect(pathGone(io, leader.folder));
}

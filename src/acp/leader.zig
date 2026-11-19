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
/// errno is an error, and the test output names it.
fn sendLineNoWait(fd: posix.socket_t, line: []const u8) !bool {
    const rc = std.c.send(fd, line.ptr, line.len, posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT);
    if (rc < 0) switch (posix.errno(rc)) {
        .AGAIN, .NOBUFS, .PIPE, .CONNRESET => return false,
        else => |err| {
            std.debug.print("sendLineNoWait: send failed with errno {t}\n", .{err});
            return error.SendFailed;
        },
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

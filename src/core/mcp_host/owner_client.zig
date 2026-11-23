//! The session's side of the MCP owner (`tests/tla/mcp_host/SharedServers.tla`).
//!
//! One client connects lazily, at the first need or call for a shared server.
//! If no owner answers, it starts one, detached, as `fx --fx-internal-mcp-owner
//! <fx_home>`, and tries again: one attempt is "connect, else start an owner,
//! then connect", repeated every 200 ms until the server's startup timeout,
//! because an owner that is still exiting holds the lock and a new owner exits
//! at once. A reader thread hands whole frames to the runtime, which decodes
//! them on its owner thread and wakes the engine. When the owner cannot be
//! reached at all, `SharingUnavailable` lets the runtime run that server in its
//! own engine.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const self_exe = @import("../shared/self_exe.zig");
const owner = @import("owner.zig");
const wire = @import("owner_wire.zig");

const Allocator = std.mem.Allocator;

/// The longest socket path a Unix address takes on macOS.
pub const max_socket_path = 103;
/// One attempt is connect, else start an owner, then connect again.
pub const retry_ms = 200;
/// An owner is started at most this often while a session waits for one.
pub const spawn_retry_ms = 1000;

pub const Error = Allocator.Error || std.Io.net.UnixAddress.InitError || error{
    /// No owner answered within the server's startup timeout, the socket path
    /// is too long, or another owner holds the lock and does not serve.
    SharingUnavailable,
    /// The connection closed; the next need or call connects again.
    Closed,
};

/// How the client wakes the runtime's owner thread.
pub const Wake = struct {
    context: *anyopaque,
    wake: *const fn (context: *anyopaque) void,
};

pub const Client = struct {
    io: std.Io,
    gpa: Allocator,
    fx_home: []const u8,
    spawn_owner: bool,
    socket_path: []u8,
    wake: Wake,
    mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    /// Whole frames, owned here until the runtime takes them.
    queue: std.ArrayList([]u8) = .empty,
    /// The bytes those frames take, for the cap below.
    queued_bytes: usize = 0,
    stream: ?std.Io.net.Stream = null,
    /// The task that reads this connection. Closing cancels it and waits:
    /// a read blocked on the socket ends with `error.Canceled`, so the
    /// descriptor is never closed under it.
    reader: ?std.Io.Future(std.Io.Cancelable!void) = null,
    closed: bool = false,
    last_spawn_ms: i64 = 0,
    /// The owners this session started that it has not reaped yet. An owner
    /// that exits while the session lives stays a zombie until someone waits
    /// for it (`RULES.md` R3.9), so each start is kept here and reaped in
    /// `reapSpawned`.
    spawned: std.ArrayList(std.c.pid_t) = .empty,

    pub fn init(io: std.Io, gpa: Allocator, fx_home: []const u8, spawn_owner: bool, wake: Wake) Error!Client {
        const socket_path = try std.Io.Dir.path.join(gpa, &.{ fx_home, owner.run_dir_name, owner.socket_name });
        errdefer gpa.free(socket_path);
        // A Unix address holds this many bytes; a longer path means sharing
        // cannot work here, and the session runs every server itself.
        if (socket_path.len > max_socket_path) {
            debug_trace.logf("mcp-owner", "sharing unavailable reason=socket path over {d} bytes", .{max_socket_path});
            return error.SharingUnavailable;
        }
        return .{ .io = io, .gpa = gpa, .fx_home = fx_home, .spawn_owner = spawn_owner, .socket_path = socket_path, .wake = wake };
    }

    pub fn deinit(c: *Client) void {
        c.close();
        // An owner this session started may have exited since the last check.
        c.reapSpawned();
        c.spawned.deinit(c.gpa);
        c.gpa.free(c.socket_path);
        if (c.queue.items.len != 0) {
            // The session ended with frames it had not read: a call's end or a
            // tool page is gone with them, and the next call is the one that
            // asks again.
            debug_trace.logf("mcp-owner", "owner frames dropped reason=client ended frames={d} bytes={d}", .{ c.queue.items.len, c.queued_bytes });
        }
        for (c.queue.items) |frame| c.gpa.free(frame);
        c.queue.deinit(c.gpa);
        c.queued_bytes = 0;
    }

    fn now(c: *const Client) i64 {
        return std.Io.Clock.awake.now(c.io).toMilliseconds();
    }

    /// Connected, or `SharingUnavailable`: one attempt is connect, else start
    /// an owner, then connect again, every `retry_ms` until the timeout.
    pub fn ensureReady(c: *Client, startup_timeout_ms: u32) Error!void {
        // An owner started before this point may have exited: its process is
        // reaped here, so a session that outlives many owners leaves no
        // zombies behind it.
        c.reapSpawned();
        if (c.stream != null) {
            if (!c.isClosed()) return;
            // The owner went away: this connection closes, and one attempt
            // below finds or starts the next owner.
            c.close();
        }
        const deadline = c.now() + startup_timeout_ms;
        while (true) {
            // A refused or missing socket is expected here: the loop below
            // starts an owner when it may, and tries again until the deadline.
            c.connect(deadline) catch {};
            if (c.stream != null) return;
            if (c.spawn_owner and c.now() - c.last_spawn_ms >= spawn_retry_ms) {
                c.last_spawn_ms = c.now();
                c.spawn();
            }
            if (c.now() >= deadline) {
                debug_trace.logf("mcp-owner", "sharing unavailable reason=no owner within {d} ms", .{startup_timeout_ms});
                return error.SharingUnavailable;
            }
            // The owner is another process: its socket appears when that
            // process is ready, and no signal crosses the boundary, so the
            // client polls every `retry_ms` until the deadline above.
            io_mod.sleep(retry_ms * std.time.ns_per_ms);
        }
    }

    /// Starts an owner, detached, with nothing on this session's terminal.
    fn spawn(c: *Client) void {
        const exe = self_exe.pathForPeerReexec(c.gpa) catch |err| {
            debug_trace.logf("mcp-owner", "owner not started reason=self path err={s}", .{@errorName(err)});
            return;
        };
        defer c.gpa.free(exe);
        var argv = [_][]const u8{ exe, owner.mode, c.fx_home };
        const child = std.process.spawn(c.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            debug_trace.logf("mcp-owner", "owner not started err={s}", .{@errorName(err)});
            return;
        };
        const pid = child.id orelse {
            debug_trace.logf("mcp-owner", "owner started without a pid", .{});
            return;
        };
        // Kept until it exits, so a session that outlives its owner reaps it
        // rather than leaving a zombie in its process table.
        c.spawned.append(c.gpa, pid) catch |err| {
            debug_trace.logf("mcp-owner", "owner pid not kept reason={s} pid={d}", .{ @errorName(err), pid });
        };
        debug_trace.logf("mcp-owner", "owner started pid={d}", .{pid});
    }

    /// Reaps the owners this session started that have exited, so none stays a
    /// zombie (`RULES.md` R3.9). One still running is checked again next time,
    /// and one already reaped, or that no longer waits for its parent, is
    /// dropped: either way nothing waits for it any more.
    fn reapSpawned(c: *Client) void {
        var i: usize = 0;
        while (i < c.spawned.items.len) {
            const pid: std.c.pid_t = @intCast(c.spawned.items[i]);
            if (std.c.waitpid(pid, null, std.c.W.NOHANG) == 0) {
                i += 1;
                continue;
            }
            _ = c.spawned.swapRemove(i);
        }
    }

    /// Connects, sends hello, and checks the owner's welcome version. The
    /// welcome is read only once `poll` says the socket has bytes, each wait
    /// bounded by `deadline`: a peer that accepts the connection and never
    /// answers ends as `SharingUnavailable` instead of hanging the session.
    fn connect(c: *Client, deadline: i64) !void {
        const address = std.Io.net.UnixAddress.init(c.socket_path) catch return error.SharingUnavailable;
        const stream = address.connect(c.io) catch return error.SharingUnavailable;
        errdefer stream.close(c.io);
        var client = c;
        c.write_mutex.lockUncancelable(c.io);
        const sent = client.sendOn(stream, .{ .hello = .{ .pid = @intCast(std.c.getpid()) } });
        c.write_mutex.unlock(c.io);
        try sent;
        // The welcome names the owner, and its version must match ours.
        var header: [wire.header_bytes]u8 = undefined;
        try c.waitReadable(stream, deadline);
        readExact(c.io, stream, &header) catch return error.SharingUnavailable;
        const length = wire.readLength(&header) catch return error.SharingUnavailable;
        var buffer: [1024]u8 = undefined;
        if (length > buffer.len) return error.SharingUnavailable;
        try c.waitReadable(stream, deadline);
        readExact(c.io, stream, buffer[0..length]) catch return error.SharingUnavailable;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const message = wire.decode(arena.allocator(), buffer[0..length]) catch return error.SharingUnavailable;
        switch (message) {
            .owner => |welcome| switch (welcome) {
                .welcome => {},
                else => return error.SharingUnavailable,
            },
            .client => return error.SharingUnavailable,
        }
        c.stream = stream;
        c.closed = false;
        c.reader = c.io.concurrent(readerTask, .{ c, stream }) catch |err| {
            // A connection with no reader could only wait for frames that
            // never come: say so, and let the session run every server itself.
            debug_trace.logf("mcp-owner", "owner reader not started socket={s} err={s}", .{ c.socket_path, @errorName(err) });
            c.stream = null;
            c.closed = true;
            return error.SharingUnavailable;
        };
        debug_trace.logf("mcp-owner", "owner connected socket={s}", .{c.socket_path});
    }

    /// Waits until the socket has bytes to read or `deadline` passes.
    fn waitReadable(c: *Client, stream: std.Io.net.Stream, deadline: i64) !void {
        while (true) {
            const left = deadline - c.now();
            if (left <= 0) return error.SharingUnavailable;
            var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32)))) catch return error.SharingUnavailable;
            if (ready > 0) return;
        }
    }

    /// Writes one message. The caller has called `ensureReady`.
    pub fn send(c: *Client, message: wire.ClientMessage) Error!void {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        // A connection the reader saw end carries nothing more: saying so here
        // lets the session take the close in now, not after a write that never
        // lands.
        if (c.isClosed()) return error.Closed;
        const stream = c.stream orelse return error.Closed;
        return c.sendOn(stream, message);
    }

    fn sendOn(c: *Client, stream: std.Io.net.Stream, message: wire.ClientMessage) Error!void {
        const frame = wire.encode(c.gpa, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.SharingUnavailable,
        };
        defer c.gpa.free(frame);
        var buffer: [4096]u8 = undefined;
        var writer = stream.writer(c.io, &buffer);
        writer.interface.writeAll(frame) catch {
            c.markClosed();
            return error.Closed;
        };
        writer.interface.flush() catch {
            c.markClosed();
            return error.Closed;
        };
    }

    /// The frames that arrived since the last call, owned by `out`.
    pub fn takeFrames(c: *Client, out: *std.ArrayList([]u8)) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const taken = c.queue;
        c.queue = out.*;
        out.* = taken;
        c.queued_bytes = 0;
    }

    pub fn isClosed(c: *Client) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.closed;
    }

    fn markClosed(c: *Client) void {
        c.mutex.lockUncancelable(c.io);
        c.closed = true;
        c.mutex.unlock(c.io);
        // The runtime's owner thread may be waiting on its engine: a close ends
        // the calls the owner held, so it hears now rather than at its next
        // timer.
        c.wake.wake(c.wake.context);
    }

    /// Closes the connection; the next need or call connects again.
    pub fn close(c: *Client) void {
        c.mutex.lockUncancelable(c.io);
        const stream = c.stream;
        c.stream = null;
        c.closed = true;
        c.mutex.unlock(c.io);
        if (c.reader) |*reader| {
            // Cancel ends a read blocked on this socket and waits for the
            // task, so the descriptor is never closed under the read.
            reader.cancel(c.io) catch {};
            c.reader = null;
        }
        if (stream) |open| open.close(c.io);
    }
};

/// The connection's reader, as a task, with its own copy of the stream: a read
/// blocked on the socket ends with `error.Canceled` when the client closes,
/// with no need to shut it down, and the task never reads `Client.stream`,
/// which `close` clears under the client's lock.
fn readerTask(c: *Client, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    var header: [wire.header_bytes]u8 = undefined;
    while (true) {
        readExact(c.io, stream, &header) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return c.markClosed(),
        };
        const length = wire.readLength(&header) catch return c.markClosed();
        const payload = c.gpa.alloc(u8, length) catch return c.markClosed();
        readExact(c.io, stream, payload) catch |err| {
            c.gpa.free(payload);
            if (err == error.Canceled) return error.Canceled;
            return c.markClosed();
        };
        c.mutex.lockUncancelable(c.io);
        // Past the cap the session is not taking what the owner sends, so it
        // stops sharing: closing ends its calls the way an owner that went
        // away does, and the next need starts an owner or runs the server here.
        if (c.queued_bytes + payload.len > max_queue_bytes) {
            const queued = c.queued_bytes;
            c.mutex.unlock(c.io);
            c.gpa.free(payload);
            debug_trace.logf("mcp-owner", "owner frame dropped reason=queue over its cap bytes={d} queued={d}", .{ length, queued });
            return c.markClosed();
        }
        c.queue.append(c.gpa, payload) catch |err| {
            c.mutex.unlock(c.io);
            c.gpa.free(payload);
            // What this frame carried (a call's end, a tool page) is gone with
            // it, and the session hears nothing more for it.
            debug_trace.logf("mcp-owner", "owner frame dropped reason=queue append bytes={d} err={s}", .{ length, @errorName(err) });
            return c.markClosed();
        };
        c.queued_bytes += payload.len;
        c.mutex.unlock(c.io);
        c.wake.wake(c.wake.context);
    }
}

fn readExact(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) !void {
    var read: usize = 0;
    while (read < buffer.len) {
        var data = [_][]u8{buffer[read..]};
        const result = try stream.readWithControl(io, &data, &.{});
        if (result.data_len == 0) return error.Closed;
        read += result.data_len;
    }
}

const testing = std.testing;

/// The most a session queues from the owner: two frames of the largest size
/// the owner can send, as the owner's own per-connection queue holds. Past it
/// the session stops sharing and runs every server itself, so one that stops
/// taking frames (in a permission question, say) is not grown without end.
const max_queue_bytes = 2 * wire.max_frame_bytes;

/// Removes a test's folder. Cleanup only: a folder that won't go leaves
/// nothing the test asserts on, and the system clears /tmp.
fn removeTestDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testing.io, path) catch {}; // Cleanup only: nothing the test asserts on depends on the folder.
}

/// A short fx home under `/tmp`: a Unix socket path stops at 103 bytes and a
/// test's tmpDir real path is longer than that.
fn shortHome(alloc: Allocator, tag: []const u8) ![]u8 {
    const path = try alloc.print("/tmp/fx-owner-{s}-{d}", .{ tag, std.c.getpid() });
    removeTestDir(path);
    try std.Io.Dir.cwd().createDir(testing.io, path, .fromMode(0o700));
    return path;
}

fn serveOnThread(io: std.Io, gpa: Allocator, home: []const u8, stop: *std.atomic.Value(bool)) void {
    // An owner that ends with an error is what a test's stop asks for; the
    // test fails on the state it checks, not on this thread.
    owner.serve(io, gpa, home, stop, owner.test_client_version) catch {};
}

fn waitForSocket(path: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const address = std.Io.net.UnixAddress.init(path) catch return error.NameTooLong;
        if (address.connect(testing.io)) |stream| {
            stream.close(testing.io);
            return;
        } else |_| {
            // Polls for the socket the test's owner thread is opening.
            testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }
    return error.SocketNeverAppeared;
}

fn writeRaw(io: std.Io, fd: std.posix.socket_t, bytes: []const u8) void {
    _ = io;
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) return;
        if (rc == 0) return;
        written += @intCast(rc);
    }
}

/// Welcomes the client, then sends two frames of `size` bytes each.
fn floodFrames(io: std.Io, path: []const u8, size: usize) void {
    const address = std.Io.net.UnixAddress.init(path) catch return;
    var server = address.listen(io, .{}) catch return;
    defer server.deinit(io);
    const probe = server.accept(io) catch return;
    probe.close(io);
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    const welcome = "{\"t\":\"welcome\",\"v\":2,\"owner\":1}";
    var buf: [4 + 32]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @intCast(welcome.len), .big);
    @memcpy(buf[4 .. 4 + welcome.len], welcome);
    writeRaw(io, stream.socket.handle, buf[0 .. 4 + welcome.len]);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(size), .big);
    writeRaw(io, stream.socket.handle, &header);
    // A reader takes the bytes and queues them: it reads no JSON.
    var chunk: [4096]u8 = @splat(0);
    var left = size;
    while (left > 0) {
        const n = @min(left, chunk.len);
        writeRaw(io, stream.socket.handle, chunk[0..n]);
        left -= n;
    }
    std.mem.writeInt(u32, &header, @intCast(size), .big);
    writeRaw(io, stream.socket.handle, &header);
    left = size;
    while (left > 0) {
        const n = @min(left, chunk.len);
        writeRaw(io, stream.socket.handle, chunk[0..n]);
        left -= n;
    }
}

/// Answers one connection with a welcome from another wire version.
fn staleWelcome(io: std.Io, path: []const u8) void {
    const address = std.Io.net.UnixAddress.init(path) catch return;
    var server = address.listen(io, .{}) catch return;
    defer server.deinit(io);
    // The first connection is `waitForSocket`'s probe for the socket: it sends
    // nothing and is closed here, so the next one is the client's.
    const probe = server.accept(io) catch return;
    probe.close(io);
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    // Version 1 is another wire version, so a client of this build refuses the
    // owner that answers it.
    const json = "{\"t\":\"welcome\",\"v\":1,\"owner\":1}";
    var framed: [4 + 32]u8 = undefined;
    std.mem.writeInt(u32, framed[0..4], @intCast(json.len), .big);
    @memcpy(framed[4 .. 4 + json.len], json);
    writeRaw(io, stream.socket.handle, framed[0 .. 4 + json.len]);
    // Keeps this connection open while the client reads the welcome; closing
    // under it would make the read a close instead of a version answer.
    io.sleep(.fromMilliseconds(500), .awake) catch {};
}

/// A peer that accepts a client and never writes the welcome it waits for.
/// Holds the connection open past the client's deadline, then goes.
fn silentPeer(io: std.Io, path: []const u8) void {
    const address = std.Io.net.UnixAddress.init(path) catch return;
    var server = address.listen(io, .{}) catch return;
    defer server.deinit(io);
    // The first connection is `waitForSocket`'s probe for the socket: it sends
    // nothing and is closed here, so the next one is the client's.
    const probe = server.accept(io) catch return;
    probe.close(io);
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    io.sleep(.fromMilliseconds(2_000), .awake) catch {};
}

fn wakeNothing(_: *anyopaque) void {}

test "closing a client whose reader waits for a frame returns at once" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "close");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveOnThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name, owner.socket_name });
    defer alloc.free(path);
    try waitForSocket(path);

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, false, wake);
    try client.ensureReady(5_000);
    // The reader blocks in its read; close has to end it without that frame.
    // A fixed wait is what puts the reader in that read, and no signal says
    // it is there.
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    client.close();
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 1_000);
    client.deinit();

    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "a welcome from another wire version is sharing unavailable" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "version");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run);
    try std.Io.Dir.cwd().createDir(testing.io, run, .fromMode(0o700));
    const path = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name, owner.socket_name });
    defer alloc.free(path);
    const thread = try std.Thread.spawn(.{}, staleWelcome, .{ testing.io, path });
    defer thread.join();
    try waitForSocket(path);

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, false, wake);
    defer client.deinit();
    try testing.expectError(error.SharingUnavailable, client.ensureReady(1_000));
}

test "a session that stops taking frames caps its queue and stops sharing" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "cap");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run);
    try std.Io.Dir.cwd().createDir(testing.io, run, .fromMode(0o700));
    const path = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name, owner.socket_name });
    defer alloc.free(path);
    // Two frames, each over half the cap: the second one trips it.
    const thread = try std.Thread.spawn(.{}, floodFrames, .{ testing.io, path, max_queue_bytes / 2 + 1 });
    defer thread.join();
    try waitForSocket(path);

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, false, wake);
    defer client.deinit();
    try client.ensureReady(1_000);
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 10_000;
    while (!client.isClosed()) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > deadline) return error.ClientNeverClosed;
        // Polls for the reader to take the frame that trips the cap.
        testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    // What it did take is under the cap, and the rest was dropped: a session
    // that cannot keep up runs every server itself instead.
    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |frame| alloc.free(frame);
        frames.deinit(alloc);
    }
    client.takeFrames(&frames);
    var bytes: usize = 0;
    for (frames.items) |frame| bytes += frame.len;
    try testing.expect(bytes <= max_queue_bytes);
}

test "a peer that never welcomes the client makes it give up by its deadline" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "silent");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run);
    try std.Io.Dir.cwd().createDir(testing.io, run, .fromMode(0o700));
    const path = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name, owner.socket_name });
    defer alloc.free(path);
    const peer = try std.Thread.spawn(.{}, silentPeer, .{ testing.io, path });
    defer peer.join();
    try waitForSocket(path);

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, false, wake);
    defer client.deinit();

    // The deadline is the only thing that ends the wait for a welcome that
    // never comes: the attempt runs on its own thread so a client that ignores
    // the deadline fails this test instead of hanging it.
    const Attempt = struct {
        client: *Client,
        ready: *std.atomic.Value(bool),
        fn attempt(a: @This()) void {
            a.client.ensureReady(300) catch {};
            a.ready.store(true, .release);
        }
    };
    var ready = std.atomic.Value(bool).init(false);
    const attempt = try std.Thread.spawn(.{}, Attempt.attempt, .{Attempt{ .client = &client, .ready = &ready }});
    defer attempt.join();
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    while (!ready.load(.acquire)) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() - started > 1_000) return error.WelcomeWaitNeverEnded;
        // Polls for the attempt to hit its deadline, a bounded wait.
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    // It gave up rather than talking to a peer that said nothing.
    try testing.expect(client.stream == null);
}

test "an owner the session starts is reaped once it exits, so none stays a zombie" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "reap");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run);
    try std.Io.Dir.cwd().createDir(testing.io, run, .fromMode(0o700));

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, true, wake);
    defer client.deinit();
    client.spawn();
    // The owner starts on the same fx home and exits on its own: it has no
    // client, so it goes after its grace period.
    if (client.spawned.items.len != 1) return error.OwnerNotStarted;
    const pid = client.spawned.items[0];

    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 20_000;
    while (client.spawned.items.len != 0) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > deadline) return error.OwnerNeverReaped;
        // Polls for the owner to exit and be reaped, a bounded wait.
        testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
        client.reapSpawned();
    }
    // Nothing waits for that process any more: a second wait finds no child,
    // which a zombie would still be.
    const again = std.c.waitpid(@intCast(pid), null, std.c.W.NOHANG);
    try testing.expectEqual(@as(std.c.pid_t, -1), again);
    try testing.expectEqual(std.c.E.CHILD, std.c.errno(again));
}

test "an fx home whose socket path is too long cannot share" {
    const long = "/tmp/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/home";
    const alloc = testing.allocator;
    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    try testing.expectError(error.SharingUnavailable, Client.init(testing.io, alloc, long, false, wake));
}

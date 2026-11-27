//! The session's side of the MCP owner (`tests/tla/mcp_host/SharedServers.tla`).
//!
//! One client connects lazily, at the first need or call for a shared server.
//! If no owner answers, it starts one, detached, as `fx --fx-internal-mcp-owner
//! <fx_home>` with stdout piped (`CLOEXEC`). The owner writes one ready byte to
//! stdout once its socket is listening and 0600, or exits (giving EOF) if
//! another owner holds the lock. The client polls that pipe until the ready
//! byte, EOF, or the deadline, closes it, and connects at once; rounds without
//! a fresh spawn wait with short growing pauses (5 ms doubling up to 100 ms)
//! until the server's startup timeout. A reader thread hands whole frames to
//! the runtime, which decodes them on its owner thread and wakes the engine.
//! When the owner cannot be reached at all, `SharingUnavailable` lets the
//! runtime run that server in its own engine.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const net_connect = @import("../shared/net_connect.zig");
const self_exe = @import("../shared/self_exe.zig");
const owner = @import("owner.zig");
const owner_test_controls = @import("owner_test_controls.zig");
const wire = @import("owner_wire.zig");

const Allocator = std.mem.Allocator;

/// The longest socket path a Unix address takes on macOS.
pub const max_socket_path = 103;
/// Initial pause between reconnect probes without a fresh owner ready pipe.
pub const initial_retry_ms: u64 = 5;
/// Maximum pause between reconnect probes without a fresh owner ready pipe.
pub const max_retry_ms: u64 = 100;
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
        if (comptime builtin.is_test) {
            if (owner_test_controls.now_ms_hook) |hook| return hook();
        }
        return std.Io.Clock.awake.now(c.io).toMilliseconds();
    }

    fn sleepBackoff(pause_ms: u64) void {
        if (comptime builtin.is_test) {
            if (owner_test_controls.sleep_ms_hook) |hook| {
                hook(pause_ms);
                return;
            }
        }
        io_mod.sleep(pause_ms * std.time.ns_per_ms);
    }

    /// Connected, or `SharingUnavailable`: connects, else starts an owner and
    /// waits on its ready pipe (or backs off from 5 ms to 100 ms when no fresh
    /// spawn ran) until the startup timeout.
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
        var backoff_ms: u64 = initial_retry_ms;
        while (true) {
            // A refused or missing socket is expected here: the loop below
            // starts an owner when it may, and tries again until the deadline.
            c.connect(deadline) catch {};
            if (comptime builtin.is_test) {
                if (owner_test_controls.on_connect_attempt) |hook| hook(c.stream != null);
            }
            if (c.stream != null) return;
            var ready_pipe: ?std.Io.File = null;
            defer if (ready_pipe) |pipe| pipe.close(c.io);
            if (c.spawn_owner and c.now() - c.last_spawn_ms >= spawn_retry_ms) {
                c.last_spawn_ms = c.now();
                ready_pipe = c.spawn();
            }
            if (ready_pipe) |pipe| {
                ready_pipe = null;
                const outcome = c.waitReadyPipe(pipe, deadline);
                if (comptime builtin.is_test) {
                    if (owner_test_controls.on_ready_outcome) |hook| hook(outcome);
                }
                switch (outcome) {
                    .ready => {
                        backoff_ms = initial_retry_ms;
                        continue;
                    },
                    .eof, .timeout => {},
                }
            }
            const left = deadline - c.now();
            if (left <= 0) {
                debug_trace.logf("mcp-owner", "sharing unavailable reason=no owner within {d} ms", .{startup_timeout_ms});
                return error.SharingUnavailable;
            }
            const pause_ms: u64 = @min(backoff_ms, @as(u64, @intCast(left)));
            // Another owner may be starting or exiting under the lock without a
            // ready pipe to this session, so back off briefly before probing again.
            sleepBackoff(pause_ms);
            backoff_ms = nextRetryMs(backoff_ms);
        }
    }

    const ReadyOutcome = owner_test_controls.ReadyOutcome;

    fn nextRetryMs(current_ms: u64) u64 {
        if (current_ms == 0) return initial_retry_ms;
        return @min(current_ms *| 2, max_retry_ms);
    }

    fn waitReadyPipe(c: *Client, pipe: std.Io.File, deadline: i64) ReadyOutcome {
        var close_pipe = true;
        defer if (close_pipe) pipe.close(c.io);
        while (true) {
            const left = deadline - c.now();
            if (left <= 0) {
                debug_trace.logf("mcp-owner", "event=owner_ready_dropped reason=timeout", .{});
                return .timeout;
            }
            var fds = [_]std.posix.pollfd{.{
                .fd = pipe.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32)))) catch |err| {
                debug_trace.logf("mcp-owner", "event=owner_ready_dropped reason=poll err={s}", .{@errorName(err)});
                return .eof;
            };
            if (ready == 0) {
                debug_trace.logf("mcp-owner", "event=owner_ready_dropped reason=timeout", .{});
                return .timeout;
            }
            if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                if (fds[0].revents & std.posix.POLL.NVAL != 0) {
                    close_pipe = false;
                    debug_trace.logf("mcp-owner", "event=owner_ready_eof reason=nval", .{});
                    return .eof;
                }
                var byte: [1]u8 = undefined;
                const rc = std.c.read(pipe.handle, &byte, 1);
                if (rc == 1) {
                    debug_trace.logf("mcp-owner", "event=owner_ready byte={d}", .{byte[0]});
                    return .ready;
                }
                if (rc < 0 and std.c.errno(rc) == .INTR) continue;
                if (rc == 0) {
                    debug_trace.logf("mcp-owner", "event=owner_ready_eof", .{});
                    return .eof;
                }
                debug_trace.logf("mcp-owner", "event=owner_ready_dropped reason=read errno={d}", .{@backingInt(std.c.errno(rc))});
                return .eof;
            }
        }
    }

    /// Starts an owner, detached, with its stdout piped for the ready signal
    /// and nothing on this session's terminal. Returns the CLOEXEC read end.
    fn spawn(c: *Client) ?std.Io.File {
        if (comptime builtin.is_test) {
            if (owner_test_controls.spawn_hook) |hook| {
                var fds: [2]std.c.fd_t = undefined;
                if (std.c.pipe(&fds) != 0) return null;
                // Best effort: the ready pipe is closed right after `waitReadyPipe` returns.
                net_connect.setCloexec(fds[0]) catch {};
                // Best effort: the test owner closes its write end once done.
                net_connect.setCloexec(fds[1]) catch {};
                if (hook(c.io, c.fx_home, fds[1])) |pid| {
                    c.spawned.append(c.gpa, pid) catch |err| {
                        debug_trace.logf("mcp-owner", "owner pid not kept reason={s} pid={d}", .{ @errorName(err), pid });
                    };
                }
                return .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
            }
        }
        const exe = self_exe.pathForPeerReexec(c.gpa) catch |err| {
            debug_trace.logf("mcp-owner", "owner not started reason=self path err={s}", .{@errorName(err)});
            return null;
        };
        defer c.gpa.free(exe);
        var argv = [_][]const u8{ exe, owner.mode, c.fx_home };
        const child = std.process.spawn(c.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            debug_trace.logf("mcp-owner", "owner not started err={s}", .{@errorName(err)});
            return null;
        };
        const pid = child.id orelse {
            debug_trace.logf("mcp-owner", "owner started without a pid", .{});
            if (child.stdout) |out| out.close(c.io);
            return null;
        };
        // Kept until it exits, so a session that outlives its owner reaps it
        // rather than leaving a zombie in its process table.
        c.spawned.append(c.gpa, pid) catch |err| {
            debug_trace.logf("mcp-owner", "owner pid not kept reason={s} pid={d}", .{ @errorName(err), pid });
        };
        debug_trace.logf("mcp-owner", "owner started pid={d}", .{pid});
        if (child.stdout) |out| {
            // Best effort: the ready pipe is closed right after `waitReadyPipe` returns.
            net_connect.setCloexec(out.handle) catch {};
            return out;
        }
        return null;
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
    if (client.spawn()) |pipe| pipe.close(testing.io);
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

test "a spawned owner connects right after signaling ready with no retry sleep" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "ready");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run_dir = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run_dir);
    try std.Io.Dir.cwd().createDir(testing.io, run_dir, .fromMode(0o700));
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ home, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "mcp-owner");

    const Harness = struct {
        var mu: std.Io.Mutex = .init;
        var active_gpa: Allocator = undefined;
        var active_home: []const u8 = "";
        var stop_owner = std.atomic.Value(bool).init(false);
        var owner_thread: ?std.Thread = null;
        var ready_write_fd: ?std.posix.fd_t = null;
        var connect_attempts: usize = 0;
        var sleep_count: usize = 0;
        var ready_outcomes: usize = 0;
        var last_outcome: ?Client.ReadyOutcome = null;

        fn spawn(io: std.Io, _: []const u8, write_fd: std.posix.fd_t) ?std.c.pid_t {
            mu.lockUncancelable(io);
            ready_write_fd = write_fd;
            mu.unlock(io);
            stop_owner.store(false, .release);
            owner_thread = std.Thread.spawn(.{}, serveOnThread, .{ io, active_gpa, active_home, &stop_owner }) catch {
                closeReadyFd(io);
                return null;
            };
            return null;
        }

        fn onListening(io: std.Io) void {
            mu.lockUncancelable(io);
            const fd = ready_write_fd;
            ready_write_fd = null;
            mu.unlock(io);
            if (fd) |write_fd| {
                defer _ = std.c.close(write_fd);
                const byte = [_]u8{1};
                _ = std.c.write(write_fd, &byte, 1);
            }
        }

        fn closeReadyFd(io: std.Io) void {
            mu.lockUncancelable(io);
            const fd = ready_write_fd;
            ready_write_fd = null;
            mu.unlock(io);
            if (fd) |write_fd| _ = std.c.close(write_fd);
        }

        fn onConnectAttempt(_: bool) void {
            connect_attempts += 1;
        }

        fn onReadyOutcome(outcome: Client.ReadyOutcome) void {
            ready_outcomes += 1;
            last_outcome = outcome;
        }

        fn onSleep(_: u64) void {
            sleep_count += 1;
        }

        fn cleanup(io: std.Io) void {
            stop_owner.store(true, .release);
            if (owner_thread) |t| t.join();
            owner_thread = null;
            closeReadyFd(io);
        }
    };

    Harness.active_gpa = alloc;
    Harness.active_home = home;
    Harness.ready_write_fd = null;
    Harness.connect_attempts = 0;
    Harness.sleep_count = 0;
    Harness.ready_outcomes = 0;
    Harness.last_outcome = null;
    owner_test_controls.spawn_hook = Harness.spawn;
    owner_test_controls.on_listening_hook = Harness.onListening;
    owner_test_controls.on_connect_attempt = Harness.onConnectAttempt;
    owner_test_controls.on_ready_outcome = Harness.onReadyOutcome;
    owner_test_controls.sleep_ms_hook = Harness.onSleep;
    defer {
        owner_test_controls.spawn_hook = null;
        owner_test_controls.on_listening_hook = null;
        owner_test_controls.on_connect_attempt = null;
        owner_test_controls.on_ready_outcome = null;
        owner_test_controls.sleep_ms_hook = null;
        Harness.cleanup(testing.io);
    }

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, true, wake);
    defer client.deinit();

    try client.ensureReady(30_000);
    try testing.expect(client.stream != null);
    try testing.expectEqual(@as(usize, 2), Harness.connect_attempts);
    try testing.expectEqual(@as(usize, 0), Harness.sleep_count);
    try testing.expectEqual(@as(usize, 1), Harness.ready_outcomes);
    try testing.expectEqual(@as(?Client.ReadyOutcome, .ready), Harness.last_outcome);

    var trace_file = try std.Io.Dir.openFileAbsolute(testing.io, trace_path, .{});
    defer trace_file.close(testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace);
    const ready_idx = std.mem.find(u8, trace, "event=owner_ready ") orelse return error.MissingReadyTrace;
    const connected_idx = std.mem.find(u8, trace, "owner connected socket=") orelse return error.MissingConnectTrace;
    try testing.expect(connected_idx > ready_idx);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_eof") == null);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_dropped") == null);
}

test "an owner that exits with LockBusy gives EOF and does not wait for the deadline" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "lockeof");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run_dir = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run_dir);
    try std.Io.Dir.cwd().createDir(testing.io, run_dir, .fromMode(0o700));
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ home, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "mcp-owner");

    var dir: io_mod.VerifiedDir = .{ .dir = try std.Io.Dir.openDirAbsolute(testing.io, run_dir, .{ .iterate = true }) };
    var lock_released = false;
    var held = try io_mod.acquireTimedAdvisoryLock(&dir, owner.lock_name, 0);
    defer {
        if (!lock_released) held.release();
        dir.close();
    }

    const Harness = struct {
        var active_io: std.Io = undefined;
        var active_gpa: Allocator = undefined;
        var active_home: []const u8 = "";
        var eof_observed = std.atomic.Value(bool).init(false);
        var observed_outcome: ?Client.ReadyOutcome = null;
        var busy_err: ?anyerror = null;
        var busy_thread: ?std.Thread = null;
        var mutex: std.Io.Mutex = .init;
        var cond: std.Io.Condition = .init;

        fn spawn(io: std.Io, _: []const u8, ready_write_fd: std.posix.fd_t) ?std.c.pid_t {
            busy_thread = std.Thread.spawn(.{}, runBusyOwner, .{ io, ready_write_fd }) catch {
                _ = std.c.close(ready_write_fd);
                return null;
            };
            return null;
        }

        fn runBusyOwner(io: std.Io, write_fd: std.posix.fd_t) void {
            defer _ = std.c.close(write_fd);
            var stop = std.atomic.Value(bool).init(false);
            owner.serve(io, active_gpa, active_home, &stop, owner.test_client_version) catch |err| {
                busy_err = err;
                return;
            };
        }

        fn onReadyOutcome(outcome: Client.ReadyOutcome) void {
            mutex.lockUncancelable(active_io);
            observed_outcome = outcome;
            eof_observed.store(true, .release);
            cond.broadcast(active_io);
            mutex.unlock(active_io);
        }

        fn cleanup() void {
            if (busy_thread) |t| t.join();
            busy_thread = null;
        }
    };

    Harness.active_io = testing.io;
    Harness.active_gpa = alloc;
    Harness.active_home = home;
    Harness.eof_observed.store(false, .release);
    Harness.observed_outcome = null;
    Harness.busy_err = null;
    owner_test_controls.spawn_hook = Harness.spawn;
    owner_test_controls.on_ready_outcome = Harness.onReadyOutcome;
    defer {
        owner_test_controls.spawn_hook = null;
        owner_test_controls.on_ready_outcome = null;
        Harness.cleanup();
    }

    var stop_real = std.atomic.Value(bool).init(false);
    var real_thread: ?std.Thread = null;
    defer if (real_thread) |t| {
        stop_real.store(true, .release);
        t.join();
    };

    // Releases the lock only after `waitReadyPipe` returns `.eof` so a client
    // that waited for its 30 s deadline would time out instead of connecting.
    const Releaser = struct {
        fn run(
            io: std.Io,
            gpa: Allocator,
            fx_home: []const u8,
            lock_ptr: *io_mod.TimedAdvisoryLock,
            released_flag: *bool,
            stop_flag: *std.atomic.Value(bool),
            thread_slot: *?std.Thread,
        ) void {
            Harness.mutex.lockUncancelable(io);
            while (!Harness.eof_observed.load(.acquire)) {
                Harness.cond.waitTimeout(io, &Harness.mutex, .{ .duration = .{
                    .raw = .fromMilliseconds(10_000),
                    .clock = .awake,
                } }) catch break; // Hang guard so a broken client cannot stall the test thread.
            }
            Harness.mutex.unlock(io);
            if (!Harness.eof_observed.load(.acquire)) return;
            lock_ptr.release();
            released_flag.* = true;
            thread_slot.* = std.Thread.spawn(.{}, serveOnThread, .{ io, gpa, fx_home, stop_flag }) catch return;
        }
    };

    const releaser = try std.Thread.spawn(
        .{},
        Releaser.run,
        .{ testing.io, alloc, home, &held, &lock_released, &stop_real, &real_thread },
    );
    defer releaser.join();

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, true, wake);
    defer client.deinit();

    try client.ensureReady(30_000);
    try testing.expect(client.stream != null);
    try testing.expect(Harness.eof_observed.load(.acquire));
    try testing.expectEqual(@as(?Client.ReadyOutcome, .eof), Harness.observed_outcome);
    try testing.expectEqual(@as(?anyerror, error.LockBusy), Harness.busy_err);

    var trace_file = try std.Io.Dir.openFileAbsolute(testing.io, trace_path, .{});
    defer trace_file.close(testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace);
    const eof_idx = std.mem.find(u8, trace, "event=owner_ready_eof") orelse return error.MissingEofTrace;
    const connected_idx = std.mem.find(u8, trace, "owner connected socket=") orelse return error.MissingConnectTrace;
    try testing.expect(connected_idx > eof_idx);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_dropped") == null);
}

test "a round without a fresh spawn probes with growing backoff capped at the deadline" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "backoff");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run_dir = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run_dir);
    try std.Io.Dir.cwd().createDir(testing.io, run_dir, .fromMode(0o700));

    const Harness = struct {
        var fake_now_ms: i64 = 10_000;
        var connect_attempts: usize = 0;
        var sleeps: [8]u64 = undefined;
        var sleep_len: usize = 0;

        fn nowMs() i64 {
            return fake_now_ms;
        }

        fn sleepMs(pause_ms: u64) void {
            if (sleep_len < sleeps.len) {
                sleeps[sleep_len] = pause_ms;
                sleep_len += 1;
            }
            fake_now_ms += @intCast(pause_ms);
        }

        fn onConnectAttempt(_: bool) void {
            connect_attempts += 1;
        }
    };

    Harness.fake_now_ms = 10_000;
    Harness.connect_attempts = 0;
    Harness.sleep_len = 0;
    owner_test_controls.now_ms_hook = Harness.nowMs;
    owner_test_controls.sleep_ms_hook = Harness.sleepMs;
    owner_test_controls.on_connect_attempt = Harness.onConnectAttempt;
    defer {
        owner_test_controls.now_ms_hook = null;
        owner_test_controls.sleep_ms_hook = null;
        owner_test_controls.on_connect_attempt = null;
    }

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, false, wake);
    defer client.deinit();

    try testing.expectError(error.SharingUnavailable, client.ensureReady(60));
    try testing.expectEqual(@as(usize, 5), Harness.connect_attempts);
    try testing.expectEqualSlices(u64, &.{ 5, 10, 20, 25 }, Harness.sleeps[0..Harness.sleep_len]);
}

test "backoff pause doubles from 5 ms and caps at 100 ms" {
    var pause = Client.nextRetryMs(0);
    try testing.expectEqual(@as(u64, 5), pause);
    pause = Client.nextRetryMs(pause);
    try testing.expectEqual(@as(u64, 10), pause);
    pause = Client.nextRetryMs(pause);
    try testing.expectEqual(@as(u64, 20), pause);
    pause = Client.nextRetryMs(pause);
    try testing.expectEqual(@as(u64, 40), pause);
    pause = Client.nextRetryMs(pause);
    try testing.expectEqual(@as(u64, 80), pause);
    pause = Client.nextRetryMs(pause);
    try testing.expectEqual(@as(u64, 100), pause);
    pause = Client.nextRetryMs(pause);
    try testing.expectEqual(@as(u64, 100), pause);
}

test "waitReadyPipe returns eof immediately on POLLNVAL" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "pollnval");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ home, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "mcp-owner");

    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    _ = std.c.close(fds[1]);
    _ = std.c.close(fds[0]);

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, false, wake);
    defer client.deinit();

    const outcome = client.waitReadyPipe(
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        client.now() + 2_000,
    );
    try testing.expectEqual(Client.ReadyOutcome.eof, outcome);

    var trace_file = try std.Io.Dir.openFileAbsolute(testing.io, trace_path, .{});
    defer trace_file.close(testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_eof reason=nval") != null);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_dropped") == null);
}

test "ensureReady returns SharingUnavailable and traces owner_ready_dropped when the ready pipe hits its deadline" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "readydrop");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    const run_dir = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name });
    defer alloc.free(run_dir);
    try std.Io.Dir.cwd().createDir(testing.io, run_dir, .fromMode(0o700));
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ home, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "mcp-owner");

    const Harness = struct {
        var held_write_fd: ?std.posix.fd_t = null;

        fn spawn(_: std.Io, _: []const u8, ready_write_fd: std.posix.fd_t) ?std.c.pid_t {
            held_write_fd = ready_write_fd;
            return null;
        }

        fn cleanup() void {
            if (held_write_fd) |fd| {
                _ = std.c.close(fd);
                held_write_fd = null;
            }
        }
    };

    Harness.held_write_fd = null;
    owner_test_controls.spawn_hook = Harness.spawn;
    defer {
        owner_test_controls.spawn_hook = null;
        Harness.cleanup();
    }

    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    var client = try Client.init(testing.io, alloc, home, true, wake);
    defer client.deinit();

    try testing.expectError(error.SharingUnavailable, client.ensureReady(300));

    var trace_file = try std.Io.Dir.openFileAbsolute(testing.io, trace_path, .{});
    defer trace_file.close(testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_dropped reason=timeout") != null);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready ") == null);
    try testing.expect(std.mem.find(u8, trace, "event=owner_ready_eof") == null);
}

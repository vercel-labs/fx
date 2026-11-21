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
    stream: ?std.Io.net.Stream = null,
    reader: ?std.Thread = null,
    closed: bool = false,
    last_spawn_ms: i64 = 0,

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
        c.gpa.free(c.socket_path);
        for (c.queue.items) |frame| c.gpa.free(frame);
        c.queue.deinit(c.gpa);
    }

    fn now(c: *const Client) i64 {
        return std.Io.Clock.awake.now(c.io).toMilliseconds();
    }

    /// Connected, or `SharingUnavailable`: one attempt is connect, else start
    /// an owner, then connect again, every `retry_ms` until the timeout.
    pub fn ensureReady(c: *Client, startup_timeout_ms: u32) Error!void {
        if (c.stream != null) {
            if (!c.isClosed()) return;
            // The owner went away: this connection closes, and one attempt
            // below finds or starts the next owner.
            c.close();
        }
        const deadline = c.now() + startup_timeout_ms;
        while (true) {
            c.connect() catch {};
            if (c.stream != null) return;
            if (c.spawn_owner and c.now() - c.last_spawn_ms >= spawn_retry_ms) {
                c.last_spawn_ms = c.now();
                c.spawn();
            }
            if (c.now() >= deadline) {
                debug_trace.logf("mcp-owner", "sharing unavailable reason=no owner within {d} ms", .{startup_timeout_ms});
                return error.SharingUnavailable;
            }
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
        debug_trace.logf("mcp-owner", "owner started pid={d}", .{child.id orelse 0});
    }

    /// Connects, sends hello, and checks the owner's welcome version.
    fn connect(c: *Client) !void {
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
        readExact(c.io, stream.socket.handle, &header) catch return error.SharingUnavailable;
        const length = wire.readLength(&header) catch return error.SharingUnavailable;
        var buffer: [1024]u8 = undefined;
        if (length > buffer.len) return error.SharingUnavailable;
        readExact(c.io, stream.socket.handle, buffer[0..length]) catch return error.SharingUnavailable;
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
        c.reader = std.Thread.spawn(.{}, readerLoop, .{c}) catch null;
        debug_trace.logf("mcp-owner", "owner connected socket={s}", .{c.socket_path});
    }

    /// Writes one message. The caller has called `ensureReady`.
    pub fn send(c: *Client, message: wire.ClientMessage) Error!void {
        const stream = c.stream orelse return error.Closed;
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        return c.sendOn(stream, message);
    }

    fn sendOn(c: *Client, stream: std.Io.net.Stream, message: wire.ClientMessage) Error!void {
        const frame = wire.encode(c.gpa, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.SharingUnavailable,
        };
        defer c.gpa.free(frame);
        writeAll(c.io, stream.socket.handle, frame) catch {
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
    }

    /// Closes the connection; the next need or call connects again.
    pub fn close(c: *Client) void {
        c.mutex.lockUncancelable(c.io);
        const stream = c.stream;
        c.stream = null;
        c.closed = true;
        c.mutex.unlock(c.io);
        if (stream) |open| {
            // A read blocked in the reader thread is not woken by closing the
            // descriptor under it, so shut the socket down first: the read then
            // returns zero, the thread ends, and only then is the fd closed.
            open.shutdown(c.io, .both) catch {};
            if (c.reader) |thread| thread.join();
            c.reader = null;
            open.close(c.io);
        }
    }
};

fn readerLoop(c: *Client) void {
    const stream = c.stream orelse return;
    var header: [wire.header_bytes]u8 = undefined;
    while (true) {
        readExact(c.io, stream.socket.handle, &header) catch return c.markClosed();
        const length = wire.readLength(&header) catch return c.markClosed();
        const payload = c.gpa.alloc(u8, length) catch return c.markClosed();
        readExact(c.io, stream.socket.handle, payload) catch {
            c.gpa.free(payload);
            return c.markClosed();
        };
        c.mutex.lockUncancelable(c.io);
        c.queue.append(c.gpa, payload) catch {
            c.mutex.unlock(c.io);
            c.gpa.free(payload);
            return c.markClosed();
        };
        c.mutex.unlock(c.io);
        c.wake.wake(c.wake.context);
    }
}

fn readExact(io: std.Io, fd: std.posix.socket_t, buffer: []u8) !void {
    var read: usize = 0;
    while (read < buffer.len) {
        const n = std.posix.read(fd, buffer[read..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.Closed;
        read += n;
    }
    _ = io;
}

fn writeAll(io: std.Io, fd: std.posix.socket_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) {
            const errno = std.posix.errno(rc);
            if (errno == .INTR or errno == .AGAIN) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.Closed;
        written += @intCast(rc);
    }
    _ = io;
}

const testing = std.testing;

/// A short fx home under `/tmp`: a Unix socket path stops at 103 bytes and a
/// test's tmpDir real path is longer than that.
fn shortHome(alloc: Allocator, tag: []const u8) ![]u8 {
    const path = try alloc.print("/tmp/fx-owner-{s}-{d}", .{ tag, std.c.getpid() });
    std.Io.Dir.cwd().deleteTree(testing.io, path) catch {};
    try std.Io.Dir.cwd().createDir(testing.io, path, .fromMode(0o700));
    return path;
}

fn serveOnThread(io: std.Io, gpa: Allocator, home: []const u8, stop: *std.atomic.Value(bool)) void {
    owner.serve(io, gpa, home, stop) catch {};
}

fn waitForSocket(path: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const address = std.Io.net.UnixAddress.init(path) catch return error.NameTooLong;
        if (address.connect(testing.io)) |stream| {
            stream.close(testing.io);
            return;
        } else |_| {
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

/// Answers one connection with a welcome from another wire version.
fn staleWelcome(io: std.Io, path: []const u8) void {
    const address = std.Io.net.UnixAddress.init(path) catch return;
    var server = address.listen(io, .{}) catch return;
    defer server.deinit(io);
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    const json = "{\"t\":\"welcome\",\"v\":2,\"owner\":1}";
    var framed: [4 + 32]u8 = undefined;
    std.mem.writeInt(u32, framed[0..4], @intCast(json.len), .big);
    @memcpy(framed[4 .. 4 + json.len], json);
    writeRaw(io, stream.socket.handle, framed[0 .. 4 + json.len]);
    io.sleep(.fromMilliseconds(500), .awake) catch {};
}

fn wakeNothing(_: *anyopaque) void {}

test "closing a client whose reader waits for a frame returns at once" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "close");
    defer {
        std.Io.Dir.cwd().deleteTree(testing.io, home) catch {};
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
        std.Io.Dir.cwd().deleteTree(testing.io, home) catch {};
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

test "an fx home whose socket path is too long cannot share" {
    const long = "/tmp/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/home";
    const alloc = testing.allocator;
    var woken: u8 = 0;
    const wake: Wake = .{ .context = &woken, .wake = wakeNothing };
    try testing.expectError(error.SharingUnavailable, Client.init(testing.io, alloc, long, false, wake));
}

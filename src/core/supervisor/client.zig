//! Local daemon client: `Client` for one-shot requests and `Connection`, the
//! kept-open connection an attached terminal uses. The caller owns responses.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const protocol = @import("protocol.zig");
const Channel = @import("channel.zig").Channel;
const Allocator = std.mem.Allocator;

pub const Response = std.json.Parsed(std.json.Value);
const max_frame_bytes = @import("channel.zig").max_frame_bytes;
/// The hidden command that runs the supervisor (`cli_surface.zig`).
pub const daemon_argument = "--proto-daemon";

pub const Client = struct {
    alloc: Allocator,
    socket_path: []u8,

    pub fn init(alloc: Allocator) !Client {
        const path = try socketPath(alloc);
        return .{ .alloc = alloc, .socket_path = path };
    }

    pub fn deinit(self: *Client) void {
        self.alloc.free(self.socket_path);
        self.* = undefined;
    }

    /// Executes one bare, one-shot request (`protocol.Request`), which a
    /// supervisor of any version answers. It blocks, so never call it while
    /// painting. The response owns all strings until deinit().
    pub fn request(self: *const Client, alloc: Allocator, command: protocol.Request) !Response {
        const json = try protocol.encode(alloc, command);
        defer alloc.free(json);
        return self.requestJson(alloc, json);
    }

    fn requestJson(self: *const Client, alloc: Allocator, json: []const u8) !Response {
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        const stream = try address.connect(io_mod.getIo());
        defer stream.close(io_mod.getIo());
        try writeFrame(stream, json);
        const bytes = try readFrame(alloc, stream, 30_000);
        defer alloc.free(bytes);
        return std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
    }

    /// Launches this executable in detached daemon mode if no daemon answers.
    /// Startup races converge on the daemon's exclusive owner lock. The
    /// daemon's stderr, where a panic and its trace go, is appended to
    /// `log_name` in the state directory (D283). A daemon that exits before
    /// it answers fails at once with `error.DaemonExited`.
    pub fn ensureRunning(self: *const Client, executable: []const u8) !void {
        if (self.ping()) |_| return else |err| if (err == error.DaemonVersionMismatch) return err;
        const io = io_mod.getIo();
        const log = openLog(self.alloc) catch null;
        defer if (log) |file| file.close(io);
        var child = try std.process.spawn(io, .{
            .argv = &.{ executable, daemon_argument },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = if (log) |file| .{ .file = file } else .ignore,
        });
        // The daemon has a separate session and owns its lifetime, not this
        // terminal; this side only notices if it ends before answering.
        var exited_at: ?i64 = null;
        const deadline = io_mod.milliTimestamp() + 15_000;
        while (io_mod.milliTimestamp() < deadline) {
            if (self.ping()) |_| return else |err| if (err == error.DaemonVersionMismatch) return err;
            if (exited_at == null and reaped(&child)) exited_at = io_mod.milliTimestamp();
            // A daemon that lost the owner lock to another exits too; give
            // the winner a moment to answer.
            if (exited_at) |at| if (io_mod.milliTimestamp() - at > 1_000) return error.DaemonExited;
            io_mod.sleep(30 * std.time.ns_per_ms);
        }
        return error.DaemonStartupTimeout;
    }

    /// True once the spawned daemon has exited; reaps it.
    fn reaped(child: *std.process.Child) bool {
        const pid = child.id orelse return true;
        var status: c_int = undefined;
        const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (waited == 0) return false;
        child.id = null;
        return true;
    }

    /// A supervisor of another protocol version is still running: stop it
    /// with `proto-fx daemon stop`, which every version understands.
    fn ping(self: *const Client) !void {
        const response = try self.request(self.alloc, .ping);
        defer response.deinit();
        const pong = std.json.parseFromValueLeaky(protocol.Pong, self.alloc, response.value, .{ .ignore_unknown_fields = true }) catch return error.DaemonVersionMismatch;
        if (!pong.ok or pong.version != protocol.version) return error.DaemonVersionMismatch;
    }
};

/// What the connection's I/O thread hands the frontend, in arrival order.
pub const Incoming = union(enum) {
    /// A connection is open. After a `disconnected`, the frontend
    /// resubscribes: the supervisor forgot this connection's watches.
    connected,
    /// The connection could not open, or closed. Every request sent before
    /// it has no reply coming.
    disconnected: anyerror,
    /// The supervisor stopped on purpose. The connection does not reopen
    /// and nothing more arrives.
    stopped,
    /// A reply (`id` set) or a pushed update (`update` set).
    frame: std.json.Parsed(protocol.ServerFrame),

    pub fn deinit(self: *Incoming) void {
        switch (self.*) {
            .frame => |*parsed| parsed.deinit(),
            else => {},
        }
    }
};

/// One kept-open connection to the supervisor, run by one I/O thread. The
/// thread starts the supervisor if none answers, reconnects with backoff
/// when the connection drops, and queues what it reads for `take`. Only the
/// owning thread calls `send`, `take`, and `stop`.
pub const Connection = struct {
    alloc: Allocator,
    client: Client,
    executable: []u8,
    channel: Channel,
    thread: ?std.Thread = null,
    connected: std.atomic.Value(bool) = .init(false),
    /// Set by the pump thread when the supervisor announced its stop.
    stopped: bool = false,
    next_id: u64 = 1,
    inbox_mutex: std.Io.Mutex = .init,
    inbox: std.ArrayList(Incoming) = .empty,

    const max_backoff_ms = 2_000;

    pub fn start(alloc: Allocator, executable: []const u8) !*Connection {
        const self = try alloc.create(Connection);
        errdefer alloc.destroy(self);
        var client = try Client.init(alloc);
        errdefer client.deinit();
        const owned = try alloc.dupe(u8, executable);
        errdefer alloc.free(owned);
        var channel = try Channel.init(alloc);
        errdefer channel.deinit();
        self.* = .{ .alloc = alloc, .client = client, .executable = owned, .channel = channel };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Closes the connection, joins its thread, and frees everything.
    pub fn stop(self: *Connection) void {
        const alloc = self.alloc;
        self.channel.shutDown();
        if (self.thread) |thread| thread.join();
        for (self.inbox.items) |*item| item.deinit();
        self.inbox.deinit(alloc);
        self.channel.deinit();
        alloc.free(self.executable);
        self.client.deinit();
        alloc.destroy(self);
    }

    /// Queues an encoded `protocol.Request` and returns the id its reply
    /// will carry. Fails while no connection is open.
    pub fn send(self: *Connection, request_json: []const u8) !u64 {
        if (!self.connected.load(.acquire)) return error.SupervisorDisconnected;
        const id = self.next_id;
        const bytes = try protocol.encode(self.alloc, .{ .id = id, .request = protocol.RawJson{ .bytes = request_json } });
        defer self.alloc.free(bytes);
        self.channel.send(bytes) catch |err| return if (err == error.OutOfMemory) err else error.SupervisorDisconnected;
        self.next_id += 1;
        return id;
    }

    /// Everything received since the last call. Caller owns the list and
    /// deinits each item.
    pub fn take(self: *Connection) std.ArrayList(Incoming) {
        self.inbox_mutex.lockUncancelable(io_mod.getIo());
        defer self.inbox_mutex.unlock(io_mod.getIo());
        const items = self.inbox;
        self.inbox = .empty;
        return items;
    }

    fn deliver(self: *Connection, item: Incoming) void {
        var owned = item;
        self.inbox_mutex.lockUncancelable(io_mod.getIo());
        defer self.inbox_mutex.unlock(io_mod.getIo());
        self.inbox.append(self.alloc, owned) catch owned.deinit();
    }

    /// The pump's frame handler.
    pub fn frame(self: *Connection, bytes: []const u8) void {
        const parsed = std.json.parseFromSlice(protocol.ServerFrame, self.alloc, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        if (parsed.value.update == .stopped) {
            parsed.deinit();
            self.stopped = true;
            return;
        }
        self.deliver(.{ .frame = parsed });
    }

    fn run(self: *Connection) void {
        var backoff_ms: i32 = 0;
        // One notice per outage, not one per failed attempt.
        var reported = false;
        while (true) {
            if (backoff_ms > 0) self.channel.waitWake(backoff_ms);
            if (!self.channel.reset()) return;
            backoff_ms = if (backoff_ms == 0) 250 else @min(backoff_ms * 2, max_backoff_ms);
            const stream = self.open() catch |err| {
                if (!reported) self.deliver(.{ .disconnected = err });
                reported = true;
                continue;
            };
            defer stream.close(io_mod.getIo());
            self.connected.store(true, .release);
            self.deliver(.connected);
            reported = false;
            backoff_ms = 0;
            const ended: anyerror = if (self.channel.pump(stream, self)) |_| error.SupervisorDisconnected else |err| err;
            self.connected.store(false, .release);
            // An intentional stop stays stopped; only a drop or crash
            // starts the supervisor again.
            if (self.stopped) return self.deliver(.stopped);
            if (self.channel.isClosed() and !self.channel.reset()) return;
            self.deliver(.{ .disconnected = ended });
            reported = true;
            backoff_ms = 250;
        }
    }

    fn open(self: *Connection) !std.Io.net.Stream {
        try self.client.ensureRunning(self.executable);
        const address = try std.Io.net.UnixAddress.init(self.client.socket_path);
        return address.connect(io_mod.getIo());
    }
};

pub fn stateDir(alloc: Allocator) ![]u8 {
    if (io_mod.getenv("PROTO_FX_STATE_DIR")) |override| return alloc.dupe(u8, override);
    const home = io_mod.homeDir() orelse return error.HomeUnavailable;
    const root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(root);
    return std.Io.Dir.path.join(alloc, &.{ root, "daemon" });
}

/// The file in the state directory that holds the daemon's stderr.
pub const log_name = "daemon.log";
/// Past this size the log moves to `daemon.log.1`, replacing the one there,
/// so the two together stay under twice the limit (D283).
pub const max_log_bytes: u64 = 256 * 1024;

/// The daemon log's path. Caller owns it.
pub fn logPath(alloc: Allocator) ![]u8 {
    const root = try stateDir(alloc);
    defer alloc.free(root);
    return std.Io.Dir.path.join(alloc, &.{ root, log_name });
}

/// Opens the daemon log for a new daemon's stderr. Caller closes it.
fn openLog(alloc: Allocator) !std.Io.File {
    const io = io_mod.getIo();
    const root = try stateDir(alloc);
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    return openLogIn(dir, io_mod.milliTimestamp());
}

/// Rotates the log in `dir` when it is full, then opens it for appending
/// and marks where this start begins.
fn openLogIn(dir: std.Io.Dir, now_ms: i64) !std.Io.File {
    const io = io_mod.getIo();
    if (dir.statFile(io, log_name, .{})) |stat| {
        if (stat.size >= max_log_bytes) try dir.rename(log_name, dir, log_name ++ ".1", io);
    } else |err| if (err != error.FileNotFound) return err;
    const file = try dir.createFile(io, log_name, .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    // The daemon shares this offset: it writes after what is there.
    if (std.c.lseek(file.handle, 0, std.c.SEEK.END) < 0) return error.Unseekable;
    var line: [80]u8 = undefined;
    try file.writeStreamingAll(io, try std.mem.print(&line, "proto-fx supervisor starting at {d} ms\n", .{now_ms}));
    return file;
}

/// Keeps a running daemon's own log under the limit: when its stderr is a
/// file past `max_log_bytes`, it starts over (D283).
pub fn boundOwnLog() void {
    const io = io_mod.getIo();
    const stderr = std.Io.File.stderr();
    const stat = stderr.stat(io) catch return;
    if (stat.kind != .file or stat.size < max_log_bytes) return;
    stderr.setLength(io, 0) catch return;
    _ = std.c.lseek(stderr.handle, 0, std.c.SEEK.SET);
}

pub fn socketPath(alloc: Allocator) ![]u8 {
    const root = try stateDir(alloc);
    defer alloc.free(root);
    return std.Io.Dir.path.join(alloc, &.{ root, "control.sock" });
}

fn writeFrame(stream: std.Io.net.Stream, json: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.writeAll(json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn readFrame(alloc: Allocator, stream: std.Io.net.Stream, timeout_ms: i32) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    var buffer: [8192]u8 = undefined;
    while (bytes.items.len <= max_frame_bytes) {
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.DaemonRequestTimeout;
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) == 0) return error.DaemonRequestTimeout;
        var buffers = [_][]u8{&buffer};
        const read = try stream.readWithControl(io_mod.getIo(), &buffers, &.{});
        const count = read.data_len;
        if (count == 0) return error.EndOfStream;
        if (std.mem.findScalar(u8, buffer[0..count], '\n')) |end| {
            if (bytes.items.len + end > max_frame_bytes) return error.FrameTooLarge;
            try bytes.appendSlice(alloc, buffer[0..end]);
            return bytes.toOwnedSlice(alloc);
        }
        try bytes.appendSlice(alloc, buffer[0..count]);
    }
    return error.FrameTooLarge;
}

test "the daemon log appends each start and rotates once full" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    {
        const file = try openLogIn(tmp.dir, 1);
        defer file.close(io);
        try file.writeStreamingAll(io, "thread 1 panic: boom\n");
    }
    {
        const file = try openLogIn(tmp.dir, 2);
        file.close(io);
    }
    const bytes = try tmp.dir.readFileAlloc(io, log_name, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("proto-fx supervisor starting at 1 ms\nthread 1 panic: boom\nproto-fx supervisor starting at 2 ms\n", bytes);
    // A full log moves aside, so the pair stays bounded.
    {
        const file = try tmp.dir.createFile(io, log_name, .{});
        defer file.close(io);
        try file.setLength(io, max_log_bytes);
    }
    const file = try openLogIn(tmp.dir, 3);
    file.close(io);
    try std.testing.expectEqual(max_log_bytes, (try tmp.dir.statFile(io, log_name ++ ".1", .{})).size);
    try std.testing.expect((try tmp.dir.statFile(io, log_name, .{})).size < 64);
}

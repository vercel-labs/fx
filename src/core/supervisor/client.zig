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
    /// Startup races converge on the daemon's exclusive owner lock.
    pub fn ensureRunning(self: *const Client, executable: []const u8) !void {
        if (self.ping()) |_| return else |err| if (err == error.DaemonVersionMismatch) return err;
        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = &.{ executable, daemon_argument },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        // The daemon has a separate session and owns its lifetime, not this terminal.
        _ = &child;
        const deadline = io_mod.milliTimestamp() + 15_000;
        while (io_mod.milliTimestamp() < deadline) {
            if (self.ping()) |_| return else |err| if (err == error.DaemonVersionMismatch) return err;
            io_mod.sleep(30 * std.time.ns_per_ms);
        }
        return error.DaemonStartupTimeout;
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

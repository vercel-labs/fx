//! One Unix socket per node, open while any of the node's commands holds a
//! lease. The socket lives in a 0700 directory and is itself 0600. A
//! connection carries exactly one request. Its token must name a live lease
//! of this channel's node, so the node a request acts for comes from the
//! socket it reached, never from what the client says.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const lease_mod = @import("lease.zig");
const protocol = @import("protocol.zig");
const ops = @import("ops.zig");
const Allocator = std.mem.Allocator;
const Lease = lease_mod.Lease;

/// Connections served at once per node; more are closed at once with `busy`.
pub const max_connections: usize = 64;
/// How long a client has to send its request line.
const request_deadline_ms: i64 = 5_000;
const poll_slice_ms: i32 = 100;
/// The longest socket path every platform accepts (macOS: 104 with NUL).
const max_socket_path: usize = 100;

pub const Channel = struct {
    alloc: Allocator,
    node_id: []u8,
    socket_path: []u8,
    listener: std.Io.net.Server = undefined,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    leases: std.ArrayList(*Lease) = .empty,
    connections: usize = 0,
};

var registry_mutex: std.Io.Mutex = .init;
var channels: std.ArrayList(*Channel) = .empty;
var sequence: u64 = 0;

/// Gives `lease` to its node's channel, opening the channel's socket in
/// `socket_dir` first if the node has none.
pub fn attach(lease: *Lease, socket_dir: []const u8) !void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    const channel = for (channels.items) |candidate| {
        if (std.mem.eql(u8, candidate.node_id, lease.node_id)) break candidate;
    } else try open(lease.node_id, socket_dir);
    channel.mutex.lockUncancelable(io);
    defer channel.mutex.unlock(io);
    try channel.leases.append(channel.alloc, lease);
    lease.bindChannel(channel);
}

/// Ends `lease`: no new request authenticates with it, requests in flight
/// finish, and the node's socket closes once it has no lease left.
pub fn detach(lease: *Lease) void {
    const io = io_mod.getIo();
    const channel = lease.channel;
    // Requests in flight may open leases of their own, such as a harness
    // tool call that runs a command, so the wait holds no registry lock.
    channel.mutex.lockUncancelable(io);
    lease.closing = true;
    while (lease.in_flight > 0) channel.changed.waitUncancelable(io, &channel.mutex);
    channel.mutex.unlock(io);
    registry_mutex.lockUncancelable(io);
    channel.mutex.lockUncancelable(io);
    for (channel.leases.items, 0..) |candidate, index| if (candidate == lease) {
        _ = channel.leases.swapRemove(index);
        break;
    };
    const empty = channel.leases.items.len == 0;
    channel.mutex.unlock(io);
    if (empty) for (channels.items, 0..) |candidate, index| if (candidate == channel) {
        _ = channels.swapRemove(index);
        break;
    };
    registry_mutex.unlock(io);
    if (empty) close(channel);
}

fn open(node_id: []const u8, socket_dir: []const u8) !*Channel {
    const alloc = std.heap.c_allocator;
    const io = io_mod.getIo();
    try channels.ensureUnusedCapacity(alloc, 1);
    sequence += 1;
    const socket_path = try alloc.print("{s}/{d}-{d}.sock", .{ socket_dir, std.c.getpid(), sequence });
    errdefer alloc.free(socket_path);
    if (socket_path.len > max_socket_path) return error.HarnessSocketPathTooLong;
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| if (err != error.FileNotFound) return err;
    const channel = try alloc.create(Channel);
    errdefer alloc.destroy(channel);
    channel.* = .{ .alloc = alloc, .node_id = try alloc.dupe(u8, node_id), .socket_path = socket_path };
    errdefer alloc.free(channel.node_id);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    channel.listener = try address.listen(io, .{});
    errdefer channel.listener.deinit(io);
    errdefer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    const path_z = try alloc.dupeSentinel(u8, socket_path, 0);
    defer alloc.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o600) != 0) return error.HarnessSocketPermissions;
    ignoreBrokenPipes();
    channel.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, acceptLoop, .{channel});
    channels.appendAssumeCapacity(channel);
    debug_trace.logf("harness", "channel open node={s} socket={s}", .{ node_id, socket_path });
    return channel;
}

fn close(channel: *Channel) void {
    const io = io_mod.getIo();
    channel.stop.store(true, .release);
    if (channel.thread) |thread| thread.join();
    channel.mutex.lockUncancelable(io);
    while (channel.connections > 0) channel.changed.waitUncancelable(io, &channel.mutex);
    channel.mutex.unlock(io);
    channel.listener.deinit(io);
    std.Io.Dir.deleteFileAbsolute(io, channel.socket_path) catch {};
    debug_trace.logf("harness", "channel closed node={s}", .{channel.node_id});
    channel.leases.deinit(channel.alloc);
    channel.alloc.free(channel.socket_path);
    channel.alloc.free(channel.node_id);
    channel.alloc.destroy(channel);
}

/// A client that hangs up early must not kill the host with SIGPIPE.
fn ignoreBrokenPipes() void {
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &ignore, null);
}

fn acceptLoop(channel: *Channel) void {
    const io = io_mod.getIo();
    while (!channel.stop.load(.acquire)) {
        var fds = [_]std.posix.pollfd{.{ .fd = channel.listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, poll_slice_ms) catch break;
        if (ready == 0) continue;
        const stream = channel.listener.accept(io) catch continue;
        channel.mutex.lockUncancelable(io);
        const admitted = channel.connections < max_connections;
        if (admitted) channel.connections += 1;
        channel.mutex.unlock(io);
        if (!admitted) {
            writeAll(stream, "{\"id\":0,\"ok\":false,\"error\":{\"kind\":\"busy\",\"message\":\"too many harness requests are in flight for this agent\"}}\n");
            stream.close(io);
            continue;
        }
        const thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, serve, .{ channel, stream }) catch {
            stream.close(io);
            finishConnection(channel);
            continue;
        };
        thread.detach();
    }
}

fn finishConnection(channel: *Channel) void {
    const io = io_mod.getIo();
    channel.mutex.lockUncancelable(io);
    channel.connections -= 1;
    channel.mutex.unlock(io);
    channel.changed.broadcast(io);
}

const Connection = struct {
    stream: std.Io.net.Stream,
    lock: std.Io.Mutex = .init,
    broken: bool = false,

    fn write(context: *anyopaque, line: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(context));
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.broken) return;
        var buffer: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &buffer);
        writer.interface.writeAll(line) catch {
            self.broken = true;
            return;
        };
        writer.interface.flush() catch {
            self.broken = true;
        };
    }
};

fn writeAll(stream: std.Io.net.Stream, line: []const u8) void {
    var connection: Connection = .{ .stream = stream };
    Connection.write(&connection, line);
}

fn serve(channel: *Channel, stream: std.Io.net.Stream) void {
    const io = io_mod.getIo();
    defer finishConnection(channel);
    defer stream.close(io);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var connection: Connection = .{ .stream = stream };
    const sink: protocol.Sink = .{ .context = &connection, .write_fn = Connection.write };
    const line = readRequest(arena, channel, stream) catch |err| {
        if (err != error.EndOfStream and err != error.Stopped) respond(arena, sink, 0, .{ .failure = .{ .kind = .bad_request, .message = @errorName(err) } });
        return;
    };
    const envelope = protocol.parseEnvelope(arena, line) catch |err| {
        respond(arena, sink, 0, .{ .failure = .{ .kind = .bad_request, .message = if (err == error.UnsupportedVersion) "this proto_fx speaks another protocol version; use the package proto-fx staged for this command" else "the request is not a valid harness request" } });
        return;
    };
    const lease = authenticate(channel, envelope.token) orelse {
        debug_trace.logf("harness", "unauthorized request node={s} op={s}", .{ channel.node_id, envelope.op });
        respond(arena, sink, envelope.id, .{ .failure = .{ .kind = .unauthorized, .message = "this token names no running command of this agent; proto_fx works only while the command that started it runs" } });
        return;
    };
    defer release(channel, lease);
    var call: protocol.Call = .{ .arena = arena, .lease = lease, .id = envelope.id, .sink = sink };
    const reply = ops.dispatch(&call, envelope.op, envelope.args) catch |err| switch (err) {
        error.OutOfMemory => protocol.Reply{ .failure = .{ .kind = .internal, .message = "out of memory" } },
        error.Cancelled => protocol.Reply{ .failure = .{ .kind = .cancelled, .message = "the agent's turn was cancelled" } },
        else => protocol.Reply{ .failure = .{ .kind = .internal, .message = @errorName(err) } },
    };
    respond(arena, sink, envelope.id, reply);
}

fn respond(arena: Allocator, sink: protocol.Sink, id: i64, reply: protocol.Reply) void {
    const line = protocol.finalLine(arena, id, reply) catch return;
    if (line.len > 0) sink.write_fn(sink.context, line);
}

/// The live lease `token` names on this channel, held until `release`.
fn authenticate(channel: *Channel, token: []const u8) ?*Lease {
    const io = io_mod.getIo();
    channel.mutex.lockUncancelable(io);
    defer channel.mutex.unlock(io);
    for (channel.leases.items) |lease| {
        if (lease.closing or !lease.matches(token)) continue;
        lease.in_flight += 1;
        return lease;
    }
    return null;
}

fn release(channel: *Channel, lease: *Lease) void {
    const io = io_mod.getIo();
    channel.mutex.lockUncancelable(io);
    lease.in_flight -= 1;
    channel.mutex.unlock(io);
    channel.changed.broadcast(io);
}

fn readRequest(arena: Allocator, channel: *Channel, stream: std.Io.net.Stream) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    const deadline = io_mod.monotonicMilliTimestamp() + request_deadline_ms;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        if (channel.stop.load(.acquire)) return error.Stopped;
        if (io_mod.monotonicMilliTimestamp() >= deadline) return error.RequestTimedOut;
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, poll_slice_ms) == 0) continue;
        var buffers = [_][]u8{&buffer};
        const count = (try stream.readWithControl(io_mod.getIo(), &buffers, &.{})).data_len;
        if (count == 0) return if (bytes.items.len == 0) error.EndOfStream else error.RequestIncomplete;
        if (std.mem.findScalar(u8, buffer[0..count], '\n')) |end| {
            if (bytes.items.len + end > protocol.max_request_bytes) return error.RequestTooLarge;
            try bytes.appendSlice(arena, buffer[0..end]);
            return bytes.items;
        }
        if (bytes.items.len + count > protocol.max_request_bytes) return error.RequestTooLarge;
        try bytes.appendSlice(arena, buffer[0..count]);
    }
}

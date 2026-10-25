//! Local daemon client. The caller owns responses and must keep blocking requests off paint paths.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;

pub const Response = std.json.Parsed(std.json.Value);
pub const max_frame_bytes = 8 * 1024 * 1024;
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

    /// Executes one local request (`protocol.Request`). Run this on a
    /// frontend I/O worker, never while painting. The response owns all
    /// strings until deinit().
    pub fn request(self: *const Client, alloc: Allocator, command: protocol.Request) !Response {
        const json = try protocol.encode(alloc, command);
        defer alloc.free(json);
        return self.requestJson(alloc, json);
    }

    pub fn requestJson(self: *const Client, alloc: Allocator, json: []const u8) !Response {
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

pub fn writeFrame(stream: std.Io.net.Stream, json: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.writeAll(json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

pub fn readFrame(alloc: Allocator, stream: std.Io.net.Stream, timeout_ms: i32) ![]u8 {
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

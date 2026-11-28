//! Loopback fixtures for the model-list tests: a server that sends one raw
//! HTTP answer, and environment overrides that point a provider at it.
const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

/// Sends `answer` to the first connection, then closes it.
pub const AnswerServer = struct {
    alloc: std.mem.Allocator,
    state: *State,
    thread: std.Thread,

    const State = struct {
        server: std.Io.net.Server,
        answer: []const u8,
        failure: ?anyerror = null,

        fn run(self: *State) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *State) !void {
            const zio = io_mod.getIo();
            const stream = try self.server.accept(zio);
            defer stream.close(zio);
            try readRequestHead(zio, stream);
            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(zio, &write_buffer);
            // A client that stops reading early closes the connection. That
            // is expected for an answer over a size cap.
            writer.interface.writeAll(self.answer) catch {};
            writer.interface.flush() catch {};
        }
    };

    pub fn start(alloc: std.mem.Allocator, answer: []const u8) !AnswerServer {
        const zio = io_mod.getIo();
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        const state = try alloc.create(State);
        errdefer alloc.destroy(state);
        state.* = .{
            .server = try std.Io.net.IpAddress.listen(&address, zio, .{ .reuse_address = true }),
            .answer = answer,
        };
        errdefer state.server.deinit(zio);
        const thread = try std.Thread.spawn(.{}, State.run, .{state});
        return .{ .alloc = alloc, .state = state, .thread = thread };
    }

    /// The URL of `path` on this server. The caller frees it.
    pub fn url(self: AnswerServer, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        return alloc.print("http://127.0.0.1:{d}{s}", .{ self.state.server.socket.address.getPort(), path });
    }

    /// Waits for the answer to be sent and releases the server. Returns the
    /// server's own failure, if any.
    pub fn finish(self: AnswerServer) !void {
        self.thread.join();
        self.state.server.deinit(io_mod.getIo());
        const failure = self.state.failure;
        self.alloc.destroy(self.state);
        if (failure) |err| return err;
    }
};

fn readRequestHead(zio: std.Io, stream: std.Io.net.Stream) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &read_buffer);
    var head: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < head.len) {
        head[len] = try reader.interface.takeByte();
        len += 1;
        if (std.mem.endsWith(u8, head[0..len], "\r\n\r\n")) return;
    }
    return error.TestRequestTooLarge;
}

/// Environment overrides for one test. They replace the process environment
/// until `deinit`.
pub const Env = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    pub fn install(alloc: std.mem.Allocator, pairs: []const [2][]const u8) !*Env {
        const self = try alloc.create(Env);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .map = std.process.Environ.Map.init(alloc) };
        errdefer self.map.deinit();
        for (pairs) |pair| try self.map.put(pair[0], pair[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    pub fn deinit(self: *Env) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        self.alloc.destroy(self);
    }
};

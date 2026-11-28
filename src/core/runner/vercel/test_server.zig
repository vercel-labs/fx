//! A loopback HTTP server for the runner's Vercel tests. It answers one
//! scripted reply per connection, in order, and the last reply repeats. It
//! keeps the head of each request it reads. Only test blocks import this file.
//! `close` stops it whether or not a client connected, so no test can hang.

const std = @import("std");
const testing_listener = @import("../../shared/testing_listener.zig");
const io_mod = @import("../../shared/io.zig");

pub const max_recorded: usize = 8;
pub const max_head: usize = 2048;
pub const max_body: usize = 1024;
/// The most body bytes a kept request holds, for a test that reads what was sent.
pub const max_kept_body: usize = 1024 * 1024;

const socket_buffer_bytes: usize = 4096;
const chunk_bytes: usize = 4096;
const reply_head_bytes: usize = 256;

pub const Mode = enum {
    /// Answer with `status` and `body`.
    reply,
    /// Answer with `status` and `body` as a chunked body, in pieces that do not line up with the
    /// client's read buffer, as the real sandbox API sends its GET answers.
    chunked,
    /// Answer with `status` and the request's own body.
    echo,
    /// Answer 200 with `size` bytes of body. A client that stops reading early is fine.
    too_large,
    /// Never answer. The connection stays open until `close`.
    hold,
    /// Set `cancel` once the request is read, then hold as `hold` does.
    cancel_then_hold,
    /// Send `body` as newline-terminated lines, `gap_ms` apart, then close.
    lines_then_close,
    /// Send the lines as `lines_then_close` does, set `cancel` if given, then hold.
    lines_then_hold,
};

pub const Reply = struct {
    status: []const u8 = "200 OK",
    body: []const u8 = "",
    mode: Mode = .reply,
    size: usize = 0,
    cancel: ?*std.atomic.Value(bool) = null,
    /// The pause between two lines in the line modes, in milliseconds.
    gap_ms: u64 = 0,
};

const Request = struct {
    head_len: usize,
    body_len: usize,
};

pub const Server = struct {
    backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server = undefined,
    open: bool = false,
    replies: []const Reply,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    held: ?std.Io.net.Stream = null,
    served: usize = 0,
    /// Wakes `waitServed` each time a request is counted. `served` moves only under `served_lock`.
    served_lock: std.Io.Mutex = .init,
    served_changed: std.Io.Condition = .init,
    /// When set, a request's body is read and counted, not kept, of any size, and the reply follows it.
    sink_bodies: bool = false,
    /// When set, only the head is read, the body stays unread, and the reply holds, so an upload blocks.
    stall_upload: bool = false,
    /// When set, the body is copied into `kept` (up to its size) and the reply follows.
    keep_body: bool = false,
    kept: [max_kept_body]u8 = undefined,
    kept_len: usize = 0,
    /// The body byte count the last sunk request carried.
    body_bytes: usize = 0,
    /// Whether the last sunk request's body came chunked.
    body_chunked: bool = false,
    heads: [max_recorded][max_head]u8 = undefined,
    head_lens: [max_recorded]usize = @splat(0),

    fn io(self: *Server) std.Io {
        return self.backend.io();
    }

    pub fn listen(self: *Server) !void {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try address.listen(self.io(), .{ .reuse_address = true });
        self.open = true;
    }

    pub fn port(self: *Server) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stops the thread and closes what it held. Safe to call twice.
    pub fn close(self: *Server) void {
        if (!self.open) return;
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.held) |stream| stream.close(self.io());
        self.held = null;
        self.server.deinit(self.io());
        self.open = false;
    }

    /// The head of request `index`, as the client sent it.
    pub fn head(self: *const Server, index: usize) []const u8 {
        return self.heads[index][0..self.head_lens[index]];
    }

    /// The first line of request `index`.
    pub fn line(self: *const Server, index: usize) []const u8 {
        const whole = self.head(index);
        return whole[0..(std.mem.find(u8, whole, "\r\n") orelse whole.len)];
    }

    /// Waits until `count` requests are counted. Each count wakes the waiter. A request that does
    /// not come within `served_wait_seconds` fails the wait, so a broken run fails its test instead
    /// of hanging it (R2.3).
    pub fn waitServed(self: *Server, count: usize) !void {
        const zio = self.io();
        self.served_lock.lockUncancelable(zio);
        defer self.served_lock.unlock(zio);
        while (self.served < count) {
            self.served_changed.waitTimeout(zio, &self.served_lock, .{ .duration = .{
                .raw = .fromSeconds(served_wait_seconds),
                .clock = .awake,
            } }) catch return error.ServerDidNotAnswer;
        }
    }

    /// The requests counted so far. The serve thread writes the count under `served_lock`, so a test
    /// on another thread reads it through this accessor, not the field.
    pub fn servedCount(self: *Server) usize {
        const zio = self.io();
        self.served_lock.lockUncancelable(zio);
        defer self.served_lock.unlock(zio);
        return self.served;
    }

    fn countServed(self: *Server) void {
        const zio = self.io();
        self.served_lock.lockUncancelable(zio);
        self.served += 1;
        self.served_lock.unlock(zio);
        self.served_changed.broadcast(zio);
    }

    fn run(self: *Server) void {
        while (true) {
            const stream = (testing_listener.acceptUnlessStopping(&self.server, self.io(), &self.stopping) catch return) orelse return;
            self.serve(stream);
        }
    }

    fn serve(self: *Server, stream: std.Io.net.Stream) void {
        const zio = self.io();
        var socket_buffer: [socket_buffer_bytes]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        var head_buffer: [max_head]u8 = undefined;
        var body_buffer: [max_body]u8 = undefined;
        const request = (if (self.stall_upload)
            readHeadOnly(&reader.interface, &head_buffer)
        else if (self.keep_body)
            self.keepRequest(&reader.interface, &head_buffer)
        else if (self.sink_bodies)
            self.sinkRequest(&reader.interface, &head_buffer)
        else
            readRequest(&reader.interface, &head_buffer, &body_buffer)) catch {
            stream.close(zio);
            return;
        };
        const index = self.served;
        if (index < max_recorded) {
            @memcpy(self.heads[index][0..request.head_len], head_buffer[0..request.head_len]);
            self.head_lens[index] = request.head_len;
        }
        self.countServed();
        const reply = self.replies[@min(index, self.replies.len - 1)];
        switch (reply.mode) {
            .reply => sendReply(zio, stream, reply.status, reply.body),
            .echo => sendReply(zio, stream, reply.status, body_buffer[0..request.body_len]),
            .too_large => sendSized(zio, stream, reply.size),
            .chunked => sendChunked(zio, stream, reply.status, reply.body),
            .hold => self.hold(stream),
            .cancel_then_hold => {
                if (reply.cancel) |flag| flag.store(true, .seq_cst);
                self.hold(stream);
            },
            .lines_then_close => {
                sendLines(zio, stream, reply.body, reply.gap_ms);
                stream.close(zio);
            },
            .lines_then_hold => {
                sendLines(zio, stream, reply.body, reply.gap_ms);
                if (reply.cancel) |flag| flag.store(true, .seq_cst);
                self.hold(stream);
            },
        }
    }

    fn hold(self: *Server, stream: std.Io.net.Stream) void {
        if (self.held) |previous| previous.close(self.io());
        self.held = stream;
    }

    /// Reads the head and discards the body, counting its bytes. A chunked body is decoded to its end.
    fn sinkRequest(self: *Server, reader: *std.Io.Reader, head_bytes: []u8) !Request {
        const head_len = try readHead(reader, head_bytes);
        const text = head_bytes[0..head_len];
        self.body_chunked = isChunked(text);
        if (self.body_chunked) {
            self.body_bytes = 0;
            while (true) {
                const size_line = try reader.takeDelimiterInclusive('\n');
                const size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_line, " \r\n"), 16);
                if (size == 0) {
                    _ = try reader.takeDelimiterInclusive('\n');
                    break;
                }
                try reader.discardAll(size);
                _ = try reader.takeDelimiterInclusive('\n');
                self.body_bytes += size;
            }
        } else {
            self.body_bytes = contentLength(text);
            try reader.discardAll(self.body_bytes);
        }
        return .{ .head_len = head_len, .body_len = 0 };
    }

    /// Reads the head and copies the body into `kept`, up to its size. The rest is counted and discarded.
    fn keepRequest(self: *Server, reader: *std.Io.Reader, head_bytes: []u8) !Request {
        const head_len = try readHead(reader, head_bytes);
        const length = contentLength(head_bytes[0..head_len]);
        const keep = @min(length, self.kept.len);
        try reader.readSliceAll(self.kept[0..keep]);
        try reader.discardAll(length - keep);
        self.kept_len = keep;
        self.body_bytes = length;
        return .{ .head_len = head_len, .body_len = 0 };
    }
};

/// Reads the head, then the declared body, so the reply goes out only after
/// the whole request has arrived and the client never sees a reset.
fn readRequest(reader: *std.Io.Reader, head: []u8, body: []u8) !Request {
    const head_len = try readHead(reader, head);
    const body_len = contentLength(head[0..head_len]);
    if (body_len > body.len) return error.TestRequestTooLarge;
    try reader.readSliceAll(body[0..body_len]);
    return .{ .head_len = head_len, .body_len = body_len };
}

/// Reads the head and leaves the body unread, so a client's upload blocks once the socket buffers fill.
fn readHeadOnly(reader: *std.Io.Reader, head: []u8) !Request {
    const head_len = try readHead(reader, head);
    return .{ .head_len = head_len, .body_len = 0 };
}

fn readHead(reader: *std.Io.Reader, head: []u8) !usize {
    var head_len: usize = 0;
    while (true) {
        if (head_len == head.len) return error.TestRequestTooLarge;
        head[head_len] = try reader.takeByte();
        head_len += 1;
        if (std.mem.endsWith(u8, head[0..head_len], "\r\n\r\n")) return head_len;
    }
}

fn isChunked(head: []const u8) bool {
    var lower: [max_head]u8 = undefined;
    for (head, 0..) |byte, index| lower[index] = std.ascii.toLower(byte);
    return std.mem.find(u8, lower[0..head.len], "transfer-encoding: chunked") != null;
}

/// Sends the lines of `body` as a close-delimited NDJSON reply, one line at a time.
/// The caller closes or holds the stream.
fn sendLines(zio: std.Io, stream: std.Io.net.Stream, body: []const u8, gap_ms: u64) void {
    send(zio, stream, "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n") catch return;
    var rest = body;
    while (rest.len > 0) {
        const end = if (std.mem.findScalar(u8, rest, '\n')) |index| index + 1 else rest.len;
        send(zio, stream, rest[0..end]) catch return;
        rest = rest[end..];
        // Paces the reply the way a slow stream arrives, which the idle and cadence tests need.
        if (gap_ms > 0 and rest.len > 0) io_mod.sleep(gap_ms * std.time.ns_per_ms);
    }
}

fn contentLength(head: []const u8) usize {
    var lower: [max_head]u8 = undefined;
    for (head, 0..) |byte, index| lower[index] = std.ascii.toLower(byte);
    const label = "content-length:";
    const at = std.mem.find(u8, lower[0..head.len], label) orelse return 0;
    var index = at + label.len;
    while (index < head.len and head[index] == ' ') index += 1;
    var value: usize = 0;
    while (index < head.len and head[index] >= '0' and head[index] <= '9') : (index += 1) {
        value = value * 10 + (head[index] - '0');
    }
    return value;
}

fn sendHead(zio: std.Io, stream: std.Io.net.Stream, status: []const u8, length: usize) bool {
    var head_buffer: [reply_head_bytes]u8 = undefined;
    const head = std.mem.print(&head_buffer, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, length }) catch return false;
    send(zio, stream, head) catch return false;
    return true;
}

fn sendReply(zio: std.Io, stream: std.Io.net.Stream, status: []const u8, body: []const u8) void {
    defer stream.close(zio);
    if (!sendHead(zio, stream, status, body.len)) return;
    // The client may close early; the test asserts on what it received, not on the rest of the body.
    send(zio, stream, body) catch {};
}

const chunked_piece_bytes: usize = 300;
const served_wait_seconds: i64 = 10;

fn sendChunked(zio: std.Io, stream: std.Io.net.Stream, status: []const u8, body: []const u8) void {
    defer stream.close(zio);
    var head_buffer: [reply_head_bytes]u8 = undefined;
    const head = std.mem.print(&head_buffer, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", .{status}) catch return;
    send(zio, stream, head) catch return;
    var rest = body;
    while (rest.len > 0) {
        const n = @min(rest.len, chunked_piece_bytes);
        var size_buffer: [16]u8 = undefined;
        const size = std.mem.print(&size_buffer, "{x}\r\n", .{n}) catch return;
        send(zio, stream, size) catch return;
        send(zio, stream, rest[0..n]) catch return;
        send(zio, stream, "\r\n") catch return;
        rest = rest[n..];
    }
    // The same as sendReply: a client that closed early already has what it asked for.
    send(zio, stream, "0\r\n\r\n") catch {};
}

fn sendSized(zio: std.Io, stream: std.Io.net.Stream, size: usize) void {
    defer stream.close(zio);
    if (!sendHead(zio, stream, "200 OK", size)) return;
    var chunk: [chunk_bytes]u8 = @splat('a');
    var remaining: usize = size;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        send(zio, stream, chunk[0..n]) catch return;
        remaining -= n;
    }
}

fn send(zio: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [socket_buffer_bytes]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

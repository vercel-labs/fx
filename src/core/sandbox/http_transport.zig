//! Sends Sandbox API requests over HTTPS with fx's pooled HTTP client. It
//! implements `client.Transport`: it opens each request, streams answer lines,
//! publishes the socket for `Abort`, and resends only what is safe to resend.
const std = @import("std");
const api = @import("api.zig");
const client = @import("client.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const http_pool = @import("../shared/http_pool.zig");
const io_mod = @import("../shared/io.zig");

/// The longest answer line fx reads. A longer line fails the request.
const max_line_bytes = 16 * 1024 * 1024;
const transfer_buffer_bytes = 4096;

/// Errors this transport raises itself. Network errors keep their own names.
pub const SendError = error{ Aborted, AnswerLost, AnswerTooLarge, LineTooLong, InvalidUrl, OutOfMemory };

/// Identity only: answers are read as sent, so decompression is not needed.
const identity_only = blk: {
    var accept: @FieldType(std.http.Client.Request, "accept_encoding") = @splat(false);
    accept[@backingInt(std.http.ContentEncoding.identity)] = true;
    break :blk accept;
};

/// The Sandbox API over HTTPS. Keep it where it is: `transport` points into it.
pub const HttpTransport = struct {
    pool: http_pool.HttpPool,

    pub fn init(alloc: std.mem.Allocator) HttpTransport {
        return .{ .pool = http_pool.HttpPool.init(alloc) };
    }

    /// Releases the pool. A connection open that is still running keeps it alive.
    pub fn deinit(self: *HttpTransport) void {
        _ = self.pool.deinit();
    }

    pub fn transport(self: *HttpTransport) client.Transport {
        return .{ .context = self, .send = sendThunk };
    }

    fn sendThunk(context: *anyopaque, arena: std.mem.Allocator, call: client.Call) anyerror!client.Response {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        return self.run(arena, call);
    }

    fn run(self: *HttpTransport, arena: std.mem.Allocator, call: client.Call) anyerror!client.Response {
        if (requested(call)) return error.Aborted;
        const url = try arena.print("{s}{s}", .{ call.base_url, call.request.target });
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const started = io_mod.milliTimestamp();
        const response = self.exchange(arena, call, url, uri) catch |err| {
            logRequest(call, 0, started);
            return err;
        };
        logRequest(call, response.status, started);
        return response;
    }

    /// One request on the pool. A failure before the answer head is sent
    /// again only when the request is safe to resend and its connection was
    /// reused, and then on a new connection. Any other such failure is a lost answer.
    fn exchange(self: *HttpTransport, arena: std.mem.Allocator, call: client.Call, url: []const u8, uri: std.Uri) anyerror!client.Response {
        _ = self.pool.clientFor(url);
        const options = try requestOptions(arena, call);
        const method = httpMethod(call.request.method);
        var retried = false;
        while (true) {
            var pooled = try self.pool.openRequest(method, uri, options);
            const req = &pooled.request;
            if (!publishSocket(call, req)) {
                finish(call, req, false);
                return error.Aborted;
            }
            var response = sendAndReceiveHead(arena, call, req) catch |err| {
                finish(call, req, false);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (requested(call)) return error.Aborted;
                if (call.retry_safe and pooled.reused and !retried) {
                    retried = true;
                    _ = self.pool.closeIdleConnections(url);
                    continue;
                }
                return error.AnswerLost;
            };
            return self.readAnswer(arena, call, req, &response);
        }
    }

    /// Reads the answer on `req`, then ends the request. The connection is
    /// kept only when the whole answer was read.
    fn readAnswer(
        self: *HttpTransport,
        arena: std.mem.Allocator,
        call: client.Call,
        req: *std.http.Client.Request,
        response: *std.http.Client.Response,
    ) anyerror!client.Response {
        const status: u16 = @backingInt(response.head.status);
        var transfer: [transfer_buffer_bytes]u8 = undefined;
        const reader = response.reader(&transfer);
        if (call.lines) |sink| {
            if (isSuccess(status)) {
                streamLines(arena, call, sink, reader) catch |err| {
                    finish(call, req, false);
                    return err;
                };
                finish(call, req, true);
                self.pool.noteActivity();
                return .{ .status = status };
            }
        }
        const body = reader.allocRemaining(arena, .limited(call.max_body_bytes)) catch |err| {
            finish(call, req, false);
            return mapBodyError(call, err);
        };
        finish(call, req, true);
        self.pool.noteActivity();
        return .{ .status = status, .body = body };
    }
};

fn sendAndReceiveHead(arena: std.mem.Allocator, call: client.Call, req: *std.http.Client.Request) anyerror!std.http.Client.Response {
    req.accept_encoding = identity_only;
    if (call.request.body.len > 0) {
        // The writer takes a mutable slice, so the body is copied.
        const body = try arena.dupe(u8, call.request.body);
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);
    } else {
        try req.sendBodiless();
    }
    return req.receiveHead(&.{});
}

/// Sends each line of a 2xx answer to `sink`. A line ends at LF, and one
/// trailing CR is dropped. A last line without LF is sent too.
fn streamLines(arena: std.mem.Allocator, call: client.Call, sink: client.LineSink, reader: *std.Io.Reader) anyerror!void {
    var line: std.Io.Writer.Allocating = .init(arena);
    while (true) {
        line.clearRetainingCapacity();
        _ = reader.streamDelimiterLimit(&line.writer, '\n', .limited(max_line_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.LineTooLong,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return failedRead(call),
        };
        const at_end = if (reader.discardDelimiterInclusive('\n')) |_| false else |err| switch (err) {
            error.EndOfStream => true,
            error.ReadFailed => return failedRead(call),
        };
        var bytes = line.written();
        if (bytes.len > 0 and bytes[bytes.len - 1] == '\r') bytes.len -= 1;
        if (at_end and bytes.len == 0) return;
        try sink.on_line(sink.context, bytes);
        if (at_end) return;
    }
}

fn mapBodyError(call: client.Call, err: anyerror) anyerror {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.StreamTooLong) return error.AnswerTooLarge;
    return failedRead(call);
}

/// An answer that stopped part way: an abort when one was asked for, else a lost answer.
fn failedRead(call: client.Call) anyerror {
    return if (requested(call)) error.Aborted else error.AnswerLost;
}

fn requestOptions(arena: std.mem.Allocator, call: client.Call) std.mem.Allocator.Error!std.http.Client.RequestOptions {
    var extra: std.ArrayList(std.http.Header) = .empty;
    if (call.request.extract_cwd) |cwd| try extra.append(arena, .{ .name = "x-cwd", .value = cwd });
    return .{
        .headers = .{
            .authorization = .{ .override = try arena.print("Bearer {s}", .{call.token}) },
            .content_type = if (call.request.content_type) |media| .{ .override = media } else .default,
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra.items,
        .redirect_behavior = .unhandled,
    };
}

fn httpMethod(method: api.Method) std.http.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .DELETE => .DELETE,
    };
}

/// Attaches the request's socket so `Abort.abort` can shut it while the request
/// waits. False when an abort came first: the request must end.
fn publishSocket(call: client.Call, req: *std.http.Client.Request) bool {
    const abort = call.abort orelse return true;
    const connection = req.connection orelse return !abort.wasRequested();
    return abort.attach(connection.stream_reader.stream.socket.handle);
}

/// Detaches the socket before the request ends and its socket closes.
fn unpublishSocket(call: client.Call) void {
    const abort = call.abort orelse return;
    abort.detach();
}

fn requested(call: client.Call) bool {
    const abort = call.abort orelse return false;
    return abort.wasRequested();
}

/// Unpublishes the socket, then ends the request. `keep` reuses the
/// connection, and is set only when the whole answer was read.
fn finish(call: client.Call, req: *std.http.Client.Request, keep: bool) void {
    unpublishSocket(call);
    if (!keep) {
        if (req.connection) |connection| connection.closing = true;
    }
    req.deinit();
}

fn isSuccess(status: u16) bool {
    return status >= 200 and status < 300;
}

/// One line per request: the method and the path. Never the query, the
/// token, or a body.
fn logRequest(call: client.Call, status: u16, started: i64) void {
    const query = std.mem.findScalar(u8, call.request.target, '?') orelse call.request.target.len;
    debug_trace.logf("sandbox", "http {s} {s} status={d} ms={d}", .{
        @tagName(call.request.method),
        call.request.target[0..query],
        status,
        io_mod.milliTimestamp() - started,
    });
}

const testing = std.testing;

/// Case-insensitive substring search, for header names in a raw request.
fn containsFolded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn startsWithFolded(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

/// What the test server received: the raw request, and how many it read.
const Record = struct {
    request: [8192]u8 = undefined,
    len: usize = 0,
    count: std.atomic.Value(u32) = .init(0),

    fn append(self: *Record, data: []const u8) !void {
        if (data.len > self.request.len - self.len) return error.RecordFull;
        @memcpy(self.request[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn bytes(self: *const Record) []const u8 {
        return self.request[0..self.len];
    }
};

/// Collects each line into `text` with a `|` after it.
const LineCollector = struct {
    text: [64]u8 = undefined,
    len: usize = 0,

    fn onLine(context: *anyopaque, line: []const u8) anyerror!void {
        const self: *LineCollector = @ptrCast(@alignCast(context));
        @memcpy(self.text[self.len..][0..line.len], line);
        self.len += line.len;
        self.text[self.len] = '|';
        self.len += 1;
    }

    fn slice(self: *const LineCollector) []const u8 {
        return self.text[0..self.len];
    }
};

/// Serves `rounds` connections on `server`. Each request is read and
/// recorded. Then the server writes `answer`, or waits for the client to close.
fn serveRounds(server: *std.Io.net.Server, record: *Record, answer: []const u8, wait_for_close: bool, rounds: usize) !void {
    for (0..rounds) |_| {
        const stream = server.accept(testing.io) catch return;
        defer stream.close(testing.io);
        readRequest(stream, record) catch return;
        _ = record.count.fetchAdd(1, .seq_cst);
        if (wait_for_close) {
            waitForClose(stream);
        } else {
            writeAnswer(stream, answer) catch return;
        }
    }
}

fn readRequest(stream: std.Io.net.Stream, record: *Record) !void {
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(testing.io, &buffer);
    var length: usize = 0;
    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        try record.append(line);
        if (std.mem.eql(u8, line, "\r\n")) break;
        if (startsWithFolded(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t\r\n");
            length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    var body: [4096]u8 = undefined;
    var remaining = length;
    while (remaining > 0) {
        const want = @min(remaining, body.len);
        const n = try reader.interface.readSliceShort(body[0..want]);
        if (n == 0) return error.EndOfStream;
        try record.append(body[0..n]);
        remaining -= n;
    }
}

fn writeAnswer(stream: std.Io.net.Stream, answer: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(testing.io, &buffer);
    try writer.interface.writeAll(answer);
    try writer.interface.flush();
}

fn waitForClose(stream: std.Io.net.Stream) void {
    var buffer: [256]u8 = undefined;
    var reader = stream.reader(testing.io, &buffer);
    while (true) {
        const n = reader.interface.readSliceShort(&buffer) catch return;
        if (n == 0) return;
    }
}

fn abortAfter(abort: *client.Abort) !void {
    io_mod.sleep(200_000_000);
    abort.abort();
}

test "the transport sends the token, headers, and body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const base_url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var record: Record = .{};
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    var serving = try testing.io.concurrent(serveRounds, .{ &server, &record, answer, false, 1 });
    defer serving.cancel(testing.io) catch {};

    var state = HttpTransport.init(std.testing.allocator);
    defer state.deinit();
    const transport = state.transport();
    const response = try transport.send(transport.context, arena, .{
        .base_url = base_url,
        .token = "tok",
        .request = .{
            .method = .POST,
            .target = "/v2/sandboxes/sessions/sbx_1/fs/write?slug=team-a",
            .content_type = "application/gzip",
            .body = "abc",
            .extract_cwd = "/w",
        },
    });
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("ok", response.body);
    const sent = record.bytes();
    try testing.expect(containsFolded(sent, "authorization: Bearer tok"));
    try testing.expect(containsFolded(sent, "x-cwd: /w"));
    try testing.expect(containsFolded(sent, "content-type: application/gzip"));
    try testing.expect(std.mem.endsWith(u8, sent, "abc"));
    try testing.expectEqual(@as(u32, 1), record.count.load(.seq_cst));
}

test "the transport streams answer lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const base_url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var record: Record = .{};
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\na\nb\r\nc";
    var serving = try testing.io.concurrent(serveRounds, .{ &server, &record, answer, false, 1 });
    defer serving.cancel(testing.io) catch {};

    var state = HttpTransport.init(std.testing.allocator);
    defer state.deinit();
    const transport = state.transport();
    var collector: LineCollector = .{};
    const response = try transport.send(transport.context, arena, .{
        .base_url = base_url,
        .token = "tok",
        .request = .{ .method = .GET, .target = "/v2/sandboxes/sessions/sbx_1/cmd/cmd_1?wait=true&slug=team-a" },
        .lines = .{ .context = &collector, .on_line = LineCollector.onLine },
    });
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("", response.body);
    try testing.expectEqualStrings("a|b|c|", collector.slice());
}

test "a failed streamed answer returns its body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const base_url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var record: Record = .{};
    const answer = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\nConnection: close\r\n\r\nboom";
    var serving = try testing.io.concurrent(serveRounds, .{ &server, &record, answer, false, 1 });
    defer serving.cancel(testing.io) catch {};

    var state = HttpTransport.init(std.testing.allocator);
    defer state.deinit();
    const transport = state.transport();
    var collector: LineCollector = .{};
    const response = try transport.send(transport.context, arena, .{
        .base_url = base_url,
        .token = "tok",
        .request = .{ .method = .GET, .target = "/v2/sandboxes/sessions/sbx_1/cmd/cmd_1?wait=true&slug=team-a" },
        .lines = .{ .context = &collector, .on_line = LineCollector.onLine },
    });
    try testing.expectEqual(@as(u16, 500), response.status);
    try testing.expectEqualStrings("boom", response.body);
    try testing.expectEqual(@as(usize, 0), collector.len);
}

test "abort stops a request that waits for its answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const base_url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var record: Record = .{};
    var serving = try testing.io.concurrent(serveRounds, .{ &server, &record, "", true, 1 });
    defer serving.cancel(testing.io) catch {};
    var abort: client.Abort = .{};
    var aborting = try testing.io.concurrent(abortAfter, .{&abort});
    defer aborting.cancel(testing.io) catch {};

    var state = HttpTransport.init(std.testing.allocator);
    defer state.deinit();
    const transport = state.transport();
    const started = io_mod.milliTimestamp();
    try testing.expectError(error.Aborted, transport.send(transport.context, arena, .{
        .base_url = base_url,
        .token = "tok",
        .request = .{
            .method = .POST,
            .target = "/v2/sandboxes/sessions/sbx_1/cmd?slug=team-a",
            .content_type = "application/json",
            .body = "{}",
        },
        .abort = &abort,
    }));
    try testing.expect(io_mod.milliTimestamp() - started < 3000);
    try testing.expectEqual(@as(u32, 1), record.count.load(.seq_cst));
}

test "a lost answer is not sent again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const base_url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var record: Record = .{};
    // Two rounds: a resend would show up as a second request.
    var serving = try testing.io.concurrent(serveRounds, .{ &server, &record, "", false, 2 });
    defer serving.cancel(testing.io) catch {};

    var state = HttpTransport.init(std.testing.allocator);
    defer state.deinit();
    const transport = state.transport();
    try testing.expectError(error.AnswerLost, transport.send(transport.context, arena, .{
        .base_url = base_url,
        .token = "tok",
        .request = .{
            .method = .POST,
            .target = "/v2/sandboxes/sessions/sbx_1/cmd?slug=team-a",
            .content_type = "application/json",
            .body = "{}",
        },
        .retry_safe = false,
    }));
    io_mod.sleep(200_000_000);
    try testing.expectEqual(@as(u32, 1), record.count.load(.seq_cst));
}

test "an abort requested first sends nothing" {
    var abort: client.Abort = .{};
    abort.abort();

    var state = HttpTransport.init(std.testing.allocator);
    defer state.deinit();
    const transport = state.transport();
    try testing.expectError(error.Aborted, transport.send(transport.context, std.testing.allocator, .{
        .base_url = "http://127.0.0.1:1",
        .token = "tok",
        .request = .{ .method = .POST, .target = "/v2/sandboxes/sessions/sbx_1/cmd?slug=team-a" },
        .abort = &abort,
    }));
}

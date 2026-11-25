//! Streamed and bounded HTTP calls for the built-in remote runner (spec V5,
//! V6, V9, V11). A call connects under its connect limit, sends its body from a
//! reader, then reads the head and body under its total and idle limits. The
//! limits are enforced by the gateway's `ConnectionWatch`, which shuts a
//! connection that is late or silent. Outside code imports `vercel.zig`, not
//! this file.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../shared/io.zig");
const secret = @import("../../auth/secret.zig");
const gateway_client = @import("../../../gateway/client.zig");
const credentials = @import("credentials.zig");
const transport = @import("transport.zig");

/// The connect deadline of every call, from its start to a connected socket (V11).
pub const connect_limit_ms: i64 = 10_000;
/// The total deadline of a call other than exec, reattach and the bring-back (V11).
pub const call_limit_ms: i64 = 30_000;
/// The most silence the bring-back stream may have before it is cut (V11).
pub const bring_back_idle_limit_ms: i64 = 30_000;
/// No limit. The exec and reattach streams have no total or idle deadline (V11).
pub const no_limit_ms: i64 = std.math.maxInt(i64);
/// The most bytes one log line may hold. A longer line is an error, not a growing buffer (R3.7).
pub const max_log_line_bytes: usize = 256 * 1024;
/// The buffer one request-body write copies through.
const send_buffer_bytes: usize = 16 * 1024;
/// The buffer a buffered call reads its body through.
const read_chunk_bytes: usize = 4 * 1024;
/// The response reader's buffer for a body with a length or a chunked framing.
const transfer_buffer_bytes: usize = 16 * 1024;

/// The limits of one call. `no_limit_ms` means none.
pub const Limits = struct {
    /// From the call's start to a connected socket.
    connect_ms: i64 = connect_limit_ms,
    /// From the call's start to its last byte.
    total_ms: i64 = no_limit_ms,
    /// The silence allowed between response bytes, once the head has arrived.
    idle_ms: i64 = no_limit_ms,
};

/// A buffered call other than exec, reattach and the bring-back.
pub const buffered_limits: Limits = .{ .total_ms = call_limit_ms };
/// The exec and reattach streams: the connect limit only. Cancel ends them.
pub const exec_limits: Limits = .{};
/// The bring-back stream: no total limit, and at most `bring_back_idle_limit_ms` of silence.
pub const bring_back_limits: Limits = .{ .idle_ms = bring_back_idle_limit_ms };
/// The reattach stream: the exec rule. Cancel ends it.
pub const reattach_limits: Limits = exec_limits;
/// The base of an fs/write's total limit, in milliseconds (V11).
pub const upload_base_ms: i64 = 30_000;
/// One unit of chunk, in bytes. The total limit grows by one `upload_ms_per_unit` per unit.
pub const upload_unit_bytes: u64 = 128 * 1024;
/// The extra total limit per unit of chunk, in milliseconds: a floor of about 1 Mbit/s.
pub const upload_ms_per_unit: i64 = 1_000;

/// The whole fs/write of `chunk_bytes` is held to its total limit, upload included, so a
/// 32 MiB chunk gets 286 s and every upload stays bounded. A send timeout cannot end a
/// stalled upload: the stream writer turns EAGAIN into a bug (`Threaded.zig` `netWritePosix`,
/// `errnoBug`), so it panics in Debug.
pub fn fsWriteLimits(chunk_bytes: u64) Limits {
    return uploadLimits(chunk_bytes, upload_base_ms, upload_ms_per_unit);
}

/// `fsWriteLimits` with the base and the rate as parameters, so a test can inject small ones.
fn uploadLimits(chunk_bytes: u64, base_ms: i64, ms_per_unit: i64) Limits {
    const units: i64 = @intCast(chunk_bytes / upload_unit_bytes);
    return .{ .total_ms = base_ms + units * ms_per_unit };
}

pub const Sized = struct {
    len: u64,
    source: *std.Io.Reader,
};

/// A request body. A sized body goes with Content-Length. A chunked body goes
/// with Transfer-Encoding: chunked. Both are copied from their reader, so the
/// whole body is never held in memory.
pub const Body = union(enum) {
    none,
    sized: Sized,
    chunked: *std.Io.Reader,
};

pub const Call = struct {
    step: []const u8,
    method: std.http.Method,
    path: []const u8,
    /// Extra headers, such as `accept` or `x-cwd`.
    headers: []const std.http.Header = &.{},
    body: Body = .none,
    content_type: []const u8 = "application/json",
    limits: Limits = buffered_limits,
    /// Set once the whole request body is sent (V7). A caller reads it after a failed
    /// open to tell a request that never went out from one that did.
    sent: ?*std.atomic.Value(bool) = null,
    /// The send gate (V10). A stop closes it before the body starts. A body that began
    /// runs to its end, so the caller knows whether the server could have read the request.
    send_gate: ?*std.atomic.Value(u8) = null,
};

/// The send gate's states. It opens, then begins when the body starts. A stop closes it
/// while it is open, and a closed gate never sends.
pub const gate_open: u8 = 0;
pub const gate_began: u8 = 1;
pub const gate_closed: u8 = 2;

pub const StreamError = std.mem.Allocator.Error || error{
    Cancelled,
    ConnectTimeout,
    Timeout,
    StreamStalled,
    TransportFailed,
    BodyLengthMismatch,
    BodyTooLarge,
    InvalidPath,
    LogLineTooLong,
};

/// An open call: its head has arrived, and its body is read through `nextLine`
/// or `read`. It is heap-allocated, so its reader keeps a fixed address. Free it with `close`.
pub const Stream = struct {
    alloc: std.mem.Allocator,
    cancel: *std.atomic.Value(bool),
    total_deadline: ?std.Io.Clock.Timestamp,
    /// The connection, with the client it runs on. Its open job owns that client.
    opened: gateway_client.OpenedRequest,
    response: std.http.Client.Response = undefined,
    body: *std.Io.Reader = undefined,
    watch: *gateway_client.ConnectionWatch,
    /// The line being read. It holds at most `max_log_line_bytes`.
    line_buffer: []u8,
    /// The response reader's buffer. A close-delimited body reads through the connection's own buffer instead.
    transfer: []u8,
    status: u16,

    /// Reads the next newline-terminated line, without its newline. The line is
    /// valid until the next read. A line longer than `max_log_line_bytes` is
    /// `error.LogLineTooLong`. Null means the body ended.
    pub fn nextLine(self: *Stream) StreamError!?[]u8 {
        var length: usize = 0;
        while (true) {
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
            const buffered = self.body.buffered();
            if (std.mem.findScalar(u8, buffered, '\n')) |end| {
                try self.appendLine(&length, buffered[0..end]);
                self.body.toss(end + 1);
                return self.line_buffer[0..length];
            }
            try self.appendLine(&length, buffered);
            self.body.toss(buffered.len);
            self.body.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    try self.endOfBody();
                    return if (length == 0) null else self.line_buffer[0..length];
                },
                error.ReadFailed => return self.failure(error.ReadFailed),
            };
            self.markProgress();
        }
    }

    /// Copies `piece` onto the end of the line being read. A line longer than
    /// `max_log_line_bytes` is `error.LogLineTooLong`.
    fn appendLine(self: *Stream, length: *usize, piece: []const u8) StreamError!void {
        if (piece.len > max_log_line_bytes - length.*) return error.LogLineTooLong;
        @memcpy(self.line_buffer[length.*..][0..piece.len], piece);
        length.* += piece.len;
    }

    /// The body reached its end of stream. A connection the watch shut reads as
    /// end of stream too, so the watch's cause, when it set one, is the error.
    fn endOfBody(self: *Stream) StreamError!void {
        const cause = self.watch.failure(error.EndOfStream);
        if (cause != error.EndOfStream) return mapWatch(cause);
    }

    /// Copies up to `dest.len` body bytes. Zero means the body ended. A fill that adds no bytes and
    /// no end of stream is not the end: over TLS the server sends records with no application data,
    /// and the reader returns from them with nothing buffered. Such fills repeat until bytes or the end come.
    pub fn read(self: *Stream, dest: []u8) StreamError!usize {
        if (self.cancel.load(.seq_cst)) return error.Cancelled;
        while (self.body.bufferedLen() == 0) {
            self.body.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    try self.endOfBody();
                    return 0;
                },
                error.ReadFailed => return self.failure(error.ReadFailed),
            };
            self.markProgress();
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
        }
        const available = self.body.buffered();
        const count = @min(dest.len, available.len);
        @memcpy(dest[0..count], available[0..count]);
        self.body.toss(count);
        return count;
    }

    /// Ends a body that reached its end. If the watch closed the connection first, its cause is the error.
    pub fn finish(self: *Stream) StreamError!void {
        if (self.watch.finish()) |err| return mapWatch(err);
    }

    pub fn close(self: *Stream) void {
        const alloc = self.alloc;
        self.watch.stop();
        alloc.destroy(self.watch);
        self.opened.deinit();
        alloc.free(self.line_buffer);
        alloc.free(self.transfer);
        alloc.destroy(self);
    }

    fn start(self: *Stream, call: Call) StreamError!void {
        const connection = self.opened.request.connection orelse return error.TransportFailed;
        if (call.send_gate) |gate| {
            if (gate.cmpxchgStrong(gate_open, gate_began, .seq_cst, .seq_cst) != null) return error.Cancelled;
        }
        self.watch.start(self.cancel, self.total_deadline, connection.stream_writer.stream) catch return error.TransportFailed;
        try self.sendBody(call.body);
        if (call.sent) |flag| flag.store(true, .seq_cst);
        if (self.cancel.load(.seq_cst)) return error.Cancelled;
        if (self.watch.armHead()) |err| return mapWatch(err);
        self.response = self.opened.request.receiveHead(&.{}) catch |err| return self.failure(err);
        if (self.watch.commitHead()) |err| return mapWatch(err);
        self.body = self.response.reader(self.transfer);
        self.status = @backingInt(self.response.head.status);
    }

    fn sendBody(self: *Stream, body: Body) StreamError!void {
        switch (body) {
            .none => {
                // std asserts that a body-less send is for a method without a body, so a POST sends an empty one.
                if (self.opened.request.method.requestHasBody()) {
                    self.opened.request.transfer_encoding = .{ .content_length = 0 };
                    var empty = std.Io.Reader.fixed("");
                    try self.writeBody(&empty, 0);
                } else {
                    self.opened.request.sendBodiless() catch |err| return self.failure(err);
                }
            },
            .sized => |sized| {
                self.opened.request.transfer_encoding = .{ .content_length = sized.len };
                try self.writeBody(sized.source, sized.len);
            },
            .chunked => |source| {
                self.opened.request.transfer_encoding = .chunked;
                try self.writeBody(source, null);
            },
        }
    }

    fn writeBody(self: *Stream, source: *std.Io.Reader, expected: ?u64) StreamError!void {
        var buffer: [send_buffer_bytes]u8 = undefined;
        var body_writer = self.opened.request.sendBodyUnflushed(&buffer) catch |err| return self.failure(err);
        const copied = source.streamRemaining(&body_writer.writer) catch |err| return self.failure(err);
        if (expected) |len| {
            if (copied != len) return error.BodyLengthMismatch;
        }
        body_writer.end() catch |err| return self.failure(err);
        if (self.opened.request.connection) |connection| {
            connection.flush() catch |err| return self.failure(err);
        }
    }

    /// The error for a failed read or write. The watch's own cause wins. When the
    /// watch recorded none, the error is the one given, and a total deadline that
    /// has passed makes it a timeout: a shut socket can fail as any transport error.
    fn failure(self: *Stream, err: anyerror) StreamError {
        // A transfer that fails after the caller cancelled is a cancel, whatever the socket reported (R2.4).
        if (self.cancel.load(.seq_cst)) return error.Cancelled;
        const cause = self.watch.failure(err);
        if (cause == err and self.totalExpired()) return error.Timeout;
        return mapWatch(cause);
    }

    fn totalExpired(self: *const Stream) bool {
        const limit = self.total_deadline orelse return false;
        return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, limit);
    }

    fn markProgress(self: *Stream) void {
        const progress = self.watch.progress();
        progress.mark_fn(progress.context);
    }
};

/// Opens one call and waits for its head. The caller reads the body, calls
/// `finish` at its end, and frees the stream with `close`. A failure is traced
/// by step and status name only (U12, R4.8).
pub fn open(
    alloc: std.mem.Allocator,
    cancel: *std.atomic.Value(bool),
    base: transport.BaseUrl,
    real: credentials.Token,
    trace: credentials.Trace,
    call: Call,
) StreamError!*Stream {
    const stream = openCall(alloc, cancel, base, real, call) catch |err| {
        transport.traceFailure(trace, call.step, err);
        return err;
    };
    transport.traceStatus(trace, call.step, stream.status);
    return stream;
}

fn openCall(
    alloc: std.mem.Allocator,
    cancel: *std.atomic.Value(bool),
    base: transport.BaseUrl,
    real: credentials.Token,
    call: Call,
) StreamError!*Stream {
    if (cancel.load(.seq_cst)) return error.Cancelled;
    const url = transport.requestUrl(alloc, base, call.path) catch |err| return mapTransport(err);
    defer alloc.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidPath;
    const authorization = try alloc.print("Bearer {s}", .{transport.bearerToken(base, real)});
    defer secret.zeroAndFree(alloc, authorization);

    var connect: Connect = .{
        .alloc = alloc,
        .uri = uri,
        .method = call.method,
        .authorization = authorization,
        .call = call,
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(call.limits.connect_ms),
    });
    var connected = gateway_client.runBoundedHttpOperation(Connected, alloc, cancel, connect_deadline, &connect) catch |err| {
        return mapConnect(err);
    };

    const line_buffer = alloc.alloc(u8, max_log_line_bytes) catch |err| {
        connected.deinit(alloc);
        return err;
    };
    const transfer = alloc.alloc(u8, transfer_buffer_bytes) catch |err| {
        alloc.free(line_buffer);
        connected.deinit(alloc);
        return err;
    };
    const watch = alloc.create(gateway_client.ConnectionWatch) catch |err| {
        alloc.free(transfer);
        alloc.free(line_buffer);
        connected.deinit(alloc);
        return err;
    };
    // A patient head wait: the head never times out on silence, and only cancel,
    // a dead socket or the total deadline ends it. The gateway's agent streams work the same way.
    watch.* = .init(.{
        .timeout_ms = call_limit_ms,
        .patient = true,
        .stall_timeout_ms = call.limits.idle_ms,
    });
    const stream = alloc.create(Stream) catch |err| {
        alloc.destroy(watch);
        alloc.free(transfer);
        alloc.free(line_buffer);
        connected.deinit(alloc);
        return err;
    };
    stream.* = .{
        .alloc = alloc,
        .cancel = cancel,
        .total_deadline = totalDeadline(call.limits.total_ms),
        .opened = connected.opened,
        .watch = watch,
        .line_buffer = line_buffer,
        .transfer = transfer,
        .status = 0,
    };
    errdefer stream.close();
    try stream.start(call);
    return stream;
}

/// A buffered call under the limits in `call.limits`. The body is read whole,
/// and it may not exceed `transport.max_response_bytes`.
pub fn callBuffered(
    alloc: std.mem.Allocator,
    cancel: *std.atomic.Value(bool),
    base: transport.BaseUrl,
    real: credentials.Token,
    trace: credentials.Trace,
    call: Call,
) StreamError!transport.Response {
    const stream = try open(alloc, cancel, base, real, trace, call);
    defer stream.close();
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    var chunk: [read_chunk_bytes]u8 = undefined;
    while (true) {
        const count = try stream.read(&chunk);
        if (count == 0) break;
        if (body.items.len + count > transport.max_response_bytes) return error.BodyTooLarge;
        try body.appendSlice(alloc, chunk[0..count]);
    }
    try stream.finish();
    return .{ .status = stream.status, .body = try body.toOwnedSlice(alloc) };
}

fn totalDeadline(total_ms: i64) ?std.Io.Clock.Timestamp {
    if (total_ms == no_limit_ms) return null;
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(total_ms) });
}

const Connected = struct {
    opened: gateway_client.OpenedRequest,

    pub fn deinit(self: *Connected, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.opened.deinit();
    }
};

/// Tests only: the opener that `Connect.run` calls, so a test can hold or fail a connect on any machine
/// (V11). Product builds have no such field, so the product runs the real opener and nothing else.
const ConnectHook = if (builtin.is_test) struct {
    var opener: ?*const fn (*Connect) anyerror!Connected = null;
} else struct {};

/// Connects under the connect limit. The connection opens on an open job
/// (`openRequestOnJob`): the job owns its client, and when this operation is
/// cancelled at the limit, the job walks away on its own. Nothing of this
/// operation is left for the job to read.
const Connect = struct {
    alloc: std.mem.Allocator,
    uri: std.Uri,
    method: std.http.Method,
    authorization: []const u8,
    call: Call,

    pub fn run(self: *Connect) anyerror!Connected {
        if (comptime builtin.is_test) {
            if (ConnectHook.opener) |opener| return opener(self);
        }
        const opened = try gateway_client.openRequestOnJob(self.method, self.uri, .{
            .headers = .{
                .accept_encoding = .omit,
                .authorization = .{ .override = self.authorization },
                .content_type = if (hasBody(self.call.body)) .{ .override = self.call.content_type } else .default,
            },
            .extra_headers = self.call.headers,
            .redirect_behavior = .unhandled,
        });
        return .{ .opened = opened };
    }
};

fn hasBody(body: Body) bool {
    return switch (body) {
        .none => false,
        .sized, .chunked => true,
    };
}

fn mapTransport(err: transport.RequestError) StreamError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPath => error.InvalidPath,
        else => error.TransportFailed,
    };
}

fn mapConnect(err: anyerror) StreamError {
    return switch (err) {
        error.Timeout => error.ConnectTimeout,
        else => mapWatch(err),
    };
}

fn mapWatch(err: anyerror) StreamError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.Timeout => error.Timeout,
        error.StreamStalled => error.StreamStalled,
        else => error.TransportFailed,
    };
}

// --- Tests ---------------------------------------------------------------

const test_server = @import("test_server.zig");

test "a body read that adds no bytes and no end is not the end of the body (V3, TLS)" {
    const Silent = struct {
        reader: std.Io.Reader,
        calls: usize = 0,

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            _ = limit;
            const self: *@This() = @fieldParentPtr("reader", r);
            self.calls += 1;
            // The first fill carries no application data, as a TLS session ticket does.
            if (self.calls == 1) return 0;
            if (self.calls == 2) {
                w.writeAll("{\"a\":1}") catch return error.WriteFailed;
                return 7;
            }
            return error.EndOfStream;
        }
    };
    var buffer: [64]u8 = undefined;
    var silent: Silent = .{ .reader = .{ .vtable = &.{ .stream = Silent.stream }, .buffer = &buffer, .seek = 0, .end = 0 } };
    var watch: gateway_client.ConnectionWatch = .init(.{});
    var line_buffer: [64]u8 = undefined;
    var transfer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var stream: Stream = .{
        .alloc = std.testing.allocator,
        .cancel = &cancel,
        .total_deadline = null,
        .opened = undefined,
        .watch = &watch,
        .line_buffer = &line_buffer,
        .transfer = &transfer,
        .status = 200,
        .body = &silent.reader,
    };
    var dest: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), try stream.read(&dest));
    try std.testing.expectEqualStrings("{\"a\":1}", dest[0..7]);
    try std.testing.expectEqual(@as(usize, 0), try stream.read(&dest));
}

const token_text = "vca_stream_fake";

fn loopbackBase(buffer: []u8, port: u16) !transport.BaseUrl {
    return transport.resolveBaseUrl(try std.mem.print(buffer, "http://127.0.0.1:{d}", .{port}));
}

/// Counts the bytes an allocator holds at once, so a test can show a copy stays bounded.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const memory = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grow(len);
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const moved = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resized(memory.len, new_len);
        return moved;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    fn grow(self: *CountingAllocator, bytes: usize) void {
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
    }

    fn resized(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) self.grow(new_len - old_len) else self.live -= old_len - new_len;
    }
};

// Linux holds a connect to a full accept queue until the limit ends it. Other systems answer it
// differently, and the timing varies by machine, so the real-socket tests check only the bound there (V11).
const linux_holds = builtin.os.tag == .linux;
/// How long past its limit a real-socket connect may end, in milliseconds (V11).
const v11_slack_ms: i64 = 2_000;
/// Off Linux, one filler connect gets this long before it is cancelled (V11). Zig 0.17's POSIX connect
/// panics on a timeout, so the bound is a timer that races the connect.
const filler_bound_ns: u64 = 500 * std.time.ns_per_ms;
/// Off Linux, a real-socket test connects at most this many fillers before it stops filling (V11).
const max_fillers = 8;

/// Holds a connect until the connect limit cancels the wait, so only the limit can end it (V11).
fn holdUntilLimit(connect: *Connect) anyerror!Connected {
    _ = connect;
    var never: std.Io.Event = .unset;
    try never.wait(io_mod.getIo());
    return error.TransportFailed;
}

/// Fails a connect at once, as a refused connection does (V11).
fn refuseAtOnce(connect: *Connect) anyerror!Connected {
    _ = connect;
    return error.ConnectionRefused;
}

/// Runs one fallible setup step of a real-socket test (V11). A failure prints one line with the step, the error,
/// the elapsed time and the round, then returns the error. A passing step prints nothing.
fn setupStep(value: anytype, step: []const u8, started_ms: i64, round: ?usize) @TypeOf(value) {
    return value catch |err| {
        std.debug.print("V11 setup failed: step={s} error={s} elapsed_ms={d} round={?d}\n", .{ step, @errorName(err), io_mod.milliTimestamp() - started_ms, round });
        return err;
    };
}

const FillerEvent = union(enum) {
    connected: std.Io.net.IpAddress.ConnectError!std.Io.net.Stream,
    bound: void,
};

fn connectTask(io: std.Io, address: *const std.Io.net.IpAddress) std.Io.net.IpAddress.ConnectError!std.Io.net.Stream {
    return address.connect(io, .{ .mode = .stream });
}

fn boundTask(ns: u64) void {
    io_mod.sleep(ns);
}

/// Connects one filler off Linux, within `filler_bound_ns` (V11). The connect races a timer, and the loser is
/// cancelled. Null means the filler failed or hit its bound, so the queue is full and the caller stops.
fn boundedFiller(io: std.Io, address: *const std.Io.net.IpAddress) !?std.Io.net.Stream {
    var buffer: [2]FillerEvent = undefined;
    var select: std.Io.Select(FillerEvent) = .init(io, &buffer);
    try select.concurrent(.connected, connectTask, .{ io, address });
    try select.concurrent(.bound, boundTask, .{filler_bound_ns});
    const first = try select.await();
    var filler: ?std.Io.net.Stream = switch (first) {
        .connected => |result| result catch null,
        .bound => null,
    };
    while (select.cancel()) |item| switch (item) {
        .connected => |late| {
            if (filler == null) filler = late catch null;
        },
        .bound => {},
    };
    return filler;
}

/// Fills the accept queue of `address` for a V11 test. Linux connects two fillers strictly, so a failure fails
/// the test. Elsewhere it connects up to `max_fillers` bounded fillers and stops at the first one that fails or
/// hits its bound, because then the queue is full. The caller closes what is left in `fillers`.
fn fillAcceptQueue(io: std.Io, address: *const std.Io.net.IpAddress, fillers: *[max_fillers]?std.Io.net.Stream, t0: i64) !void {
    if (linux_holds) {
        fillers[0] = try setupStep(address.connect(io, .{ .mode = .stream }), "filler 1", t0, null);
        fillers[1] = try setupStep(address.connect(io, .{ .mode = .stream }), "filler 2", t0, null);
        return;
    }
    for (fillers) |*slot| {
        slot.* = (try setupStep(boundedFiller(io, address), "bounded filler", t0, null)) orelse return;
    }
}

fn closeFillers(io: std.Io, fillers: *[max_fillers]?std.Io.net.Stream) void {
    for (fillers) |*slot| {
        if (slot.*) |*stream| stream.close(io);
    }
}

/// The V11 bound for a connect that a real kernel answers: it ends as ConnectTimeout or TransportFailed,
/// and no later than the limit plus a fixed slack. It has no lower bound and no tight one (V11).
fn expectEndedByLimit(result: StreamError!*Stream, elapsed: i64, limit_ms: i64, captured: []const u8, round: ?usize) !void {
    const outcome = outcomeText(result);
    try checkConnect(endedWith(result, error.ConnectTimeout) or endedWith(result, error.TransportFailed), outcome, elapsed, limit_ms, round);
    try checkConnect(elapsed < limit_ms + v11_slack_ms, outcome, elapsed, limit_ms, round);
    try checkConnect(std.mem.find(u8, captured, "step connect, failed ") != null, outcome, elapsed, limit_ms, round);
}

fn outcomeText(result: StreamError!*Stream) []const u8 {
    return if (result) |_| "connected" else |err| @errorName(err);
}

fn endedWith(result: StreamError!*Stream, want: anyerror) bool {
    return if (result) |_| false else |err| err == want;
}

/// Fails after one line that names the outcome, the elapsed time, the limit and the round (V11). A passing
/// check prints nothing, so a CI log shows what the failing real-socket test saw.
fn checkConnect(ok: bool, outcome: []const u8, elapsed: i64, limit_ms: i64, round: ?usize) !void {
    if (ok) return;
    std.debug.print("V11 check failed: outcome={s} elapsed_ms={d} limit_ms={d} round={?d}\n", .{ outcome, elapsed, limit_ms, round });
    return error.TestUnexpectedResult;
}

/// Waits for the open job that a walked-away connect left behind (V11). When it is still running after 5 s,
/// prints the test Io's concurrency limit and busy count, and whether one more concurrent task can start now.
fn expectOpenJobsDone() !void {
    gateway_client.waitForOwnClientOpenJobs() catch |err| {
        const test_io = &std.testing.io_instance;
        std.debug.print("open job still running after 5 s: {s}; concurrent_limit={any} busy_count={d} cpus={d} one_more_concurrent_task={s}\n", .{
            @errorName(err),
            test_io.concurrent_limit,
            test_io.busy_count,
            std.Thread.getCpuCount() catch 0,
            if (concurrencyAvailable()) "available" else "unavailable",
        });
        return err;
    };
}

/// Whether the test Io can start one more concurrent task now (V11 diagnostics only).
fn concurrencyAvailable() bool {
    const io = std.testing.io;
    var probe = io.concurrent(probeTask, .{}) catch return false;
    probe.await(io);
    return true;
}

fn probeTask() void {}

test "the connect limit maps a timeout to ConnectTimeout on every platform (V11)" {
    try std.testing.expectEqual(@as(StreamError, error.ConnectTimeout), mapConnect(error.Timeout));
    try std.testing.expectEqual(@as(StreamError, error.TransportFailed), mapConnect(error.ConnectionResetByPeer));
}

test "a connect that never completes ends as ConnectTimeout at its limit (V11)" {
    ConnectHook.opener = &holdUntilLimit;
    defer ConnectHook.opener = null;
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, 9);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const started = io_mod.milliTimestamp();
    try std.testing.expectError(error.ConnectTimeout, open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "connect",
        .method = .GET,
        .path = "/v2/user",
        .limits = .{ .connect_ms = 150 },
    }));
    // Only the limit ends this wait: never before it, and within the slack after it.
    const elapsed = io_mod.milliTimestamp() - started;
    try std.testing.expect(elapsed >= 150 and elapsed < 150 + 2_000);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "step connect, failed ConnectTimeout") != null);
}

test "a connect that fails at once ends as TransportFailed, well before its limit (V11)" {
    ConnectHook.opener = &refuseAtOnce;
    defer ConnectHook.opener = null;
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, 9);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const started = io_mod.milliTimestamp();
    try std.testing.expectError(error.TransportFailed, open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "connect",
        .method = .GET,
        .path = "/v2/user",
        .limits = .{ .connect_ms = 2_000 },
    }));
    try std.testing.expect(io_mod.milliTimestamp() - started < 2_000);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "step connect, failed TransportFailed") != null);
}

test "a connect that never completes ends as ConnectTimeout at its limit, 50 times in a row, with a call between each (V11)" {
    const Counted = struct {
        var holds: std.atomic.Value(usize) = .init(0);
        fn hold(connect: *Connect) anyerror!Connected {
            _ = holds.fetchAdd(1, .seq_cst);
            return holdUntilLimit(connect);
        }
    };
    ConnectHook.opener = &Counted.hold;
    defer ConnectHook.opener = null;
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const round_started = io_mod.milliTimestamp();
        try std.testing.expectError(error.ConnectTimeout, open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
            .step = "connect",
            .method = .GET,
            .path = "/v2/user",
            .limits = .{ .connect_ms = 50 },
        }));
        const round_elapsed = io_mod.milliTimestamp() - round_started;
        try std.testing.expect(round_elapsed >= 50 and round_elapsed < 50 + 2_000);
        // The hook holds only the connect under test. The call between rounds connects for real.
        ConnectHook.opener = null;
        const response = try callBuffered(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
            .step = "user",
            .method = .GET,
            .path = "/v2/user",
        });
        ConnectHook.opener = &Counted.hold;
        response.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 50), Counted.holds.load(.seq_cst));
}

test "real sockets: a connect to a full accept queue ends by its limit (V11)" {
    // Linux holds the connect until its limit ends it, and the test checks that exactly. Elsewhere the
    // kernel may answer differently, so the test checks only the bound.
    const io = std.testing.io;
    const t0 = io_mod.milliTimestamp();
    const any = try setupStep(std.Io.net.IpAddress.parse("127.0.0.1", 0), "parse address", t0, null);
    var listener = try setupStep(any.listen(io, .{ .kernel_backlog = 1, .reuse_address = true }), "listen", t0, null);
    defer listener.deinit(io);
    const target = listener.socket.address;
    var fillers: [max_fillers]?std.Io.net.Stream = @splat(null);
    defer closeFillers(io, &fillers);
    try fillAcceptQueue(io, &target, &fillers, t0);

    var buffer: [64]u8 = undefined;
    const base = try setupStep(loopbackBase(&buffer, target.getPort()), "base url", t0, null);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const started = io_mod.milliTimestamp();
    const result = open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "connect",
        .method = .GET,
        .path = "/v2/user",
        .limits = .{ .connect_ms = 150 },
    });
    const elapsed = io_mod.milliTimestamp() - started;
    const outcome = outcomeText(result);
    if (linux_holds) {
        // The hold ends at the limit: never before it, and never after the bound.
        try checkConnect(endedWith(result, error.ConnectTimeout), outcome, elapsed, 150, null);
        try checkConnect(elapsed >= 150 and elapsed < 3_000, outcome, elapsed, 150, null);
        try checkConnect(std.mem.find(u8, capture.captured(), "step connect, failed ConnectTimeout") != null, outcome, elapsed, 150, null);
    } else {
        try expectEndedByLimit(result, elapsed, 150, capture.captured(), null);
    }
    // The connect walked away from its open job; the test ends only when that job has finished.
    try expectOpenJobsDone();
}

test "an exec stream has no idle limit, so a silence past the bring-back limit does not cut it" {
    const reply: test_server.Reply = .{ .body = "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n", .mode = .lines_then_close, .gap_ms = 300 };
    var server: test_server.Server = .{ .replies = &.{ reply, reply } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const exec = try open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = exec_limits,
    });
    var lines: usize = 0;
    while (try exec.nextLine()) |_| lines += 1;
    try std.testing.expectEqual(@as(usize, 3), lines);
    try exec.finish();
    exec.close();

    // The same silence, with a 100 ms idle limit, is cut.
    const cut = try open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "bring back",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = .{ .idle_ms = 100 },
    });
    defer cut.close();
    try std.testing.expectEqualStrings("{\"a\":1}", (try cut.nextLine()).?);
    try std.testing.expectError(error.StreamStalled, cut.nextLine());
    try std.testing.expectEqual(@as(i64, 30_000), bring_back_limits.idle_ms);
}

test "a bring-back stream that goes silent is cut at its idle limit, as StreamStalled (V11)" {
    const reply: test_server.Reply = .{ .body = "{\"a\":1}\n", .mode = .lines_then_hold };
    var server: test_server.Server = .{ .replies = &.{reply} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const stream = try open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "bring back",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = .{ .idle_ms = 150 },
    });
    defer stream.close();
    try std.testing.expectEqualStrings("{\"a\":1}", (try stream.nextLine()).?);
    const started = io_mod.milliTimestamp();
    try std.testing.expectError(error.StreamStalled, stream.nextLine());
    try std.testing.expect(io_mod.milliTimestamp() - started < 3_000);
}

test "a cancel during an exec stream ends the read at once, as Cancelled (R2.4)" {
    var cancel = std.atomic.Value(bool).init(false);
    const reply: test_server.Reply = .{ .body = "{\"a\":1}\n", .mode = .lines_then_hold };
    var server: test_server.Server = .{ .replies = &.{reply} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var capture: credentials.CaptureTrace = .{};

    const exec = try open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = exec_limits,
    });
    defer exec.close();
    try std.testing.expectEqualStrings("{\"a\":1}", (try exec.nextLine()).?);
    cancel.store(true, .seq_cst);
    const started = io_mod.milliTimestamp();
    try std.testing.expectError(error.Cancelled, exec.nextLine());
    try std.testing.expect(io_mod.milliTimestamp() - started < 1_000);
}

test "a log line at max_log_line_bytes is read, and one longer is LogLineTooLong" {
    // One stream: a line exactly at the limit, then a line one byte over it.
    const alloc = std.testing.allocator;
    const over_start = max_log_line_bytes + 1;
    const body = try alloc.alloc(u8, over_start + max_log_line_bytes + 2);
    defer alloc.free(body);
    @memset(body[0..max_log_line_bytes], 'x');
    body[max_log_line_bytes] = '\n';
    @memset(body[over_start .. over_start + max_log_line_bytes + 1], 'y');
    body[body.len - 1] = '\n';

    var server: test_server.Server = .{ .replies = &.{.{ .body = body, .mode = .lines_then_close }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const stream = try open(alloc, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = exec_limits,
    });
    defer stream.close();
    try std.testing.expectEqual(max_log_line_bytes, (try stream.nextLine()).?.len);
    try std.testing.expectError(error.LogLineTooLong, stream.nextLine());
}

test "a sized body goes with Content-Length and a chunked body goes chunked, and each arrives whole" {
    const payload: [1000]u8 = @splat('p');
    var buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    var sized_server: test_server.Server = .{ .replies = &.{.{ .body = "{}" }}, .sink_bodies = true };
    try sized_server.listen();
    try sized_server.start();
    defer sized_server.close();
    var sized_source = std.Io.Reader.fixed(&payload);
    const sized = try open(std.testing.allocator, &cancel, try loopbackBase(&buffer, sized_server.port()), .{ .value = token_text }, capture.trace(), .{
        .step = "upload",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/fs/write",
        .body = .{ .sized = .{ .len = payload.len, .source = &sized_source } },
    });
    sized.close();
    try std.testing.expectEqual(@as(usize, payload.len), sized_server.body_bytes);
    try std.testing.expect(!sized_server.body_chunked);

    var chunked_server: test_server.Server = .{ .replies = &.{.{ .body = "{}" }}, .sink_bodies = true };
    try chunked_server.listen();
    try chunked_server.start();
    defer chunked_server.close();
    var chunked_source = std.Io.Reader.fixed(&payload);
    const chunked = try open(std.testing.allocator, &cancel, try loopbackBase(&buffer, chunked_server.port()), .{ .value = token_text }, capture.trace(), .{
        .step = "upload",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/fs/write",
        .body = .{ .chunked = &chunked_source },
    });
    chunked.close();
    try std.testing.expectEqual(@as(usize, payload.len), chunked_server.body_bytes);
    try std.testing.expect(chunked_server.body_chunked);
}

test "a 600 MiB streamed upload is copied from its reader, and peak live memory stays under 4 MiB" {
    // The runner's own fs/write calls carry 32 MiB each (V5). This test uses one
    // 600 MiB body to show that the size does not set the memory.
    const io = std.testing.io;
    const upload_len: u64 = 600 * 1024 * 1024;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io, "upload.bin", .{});
        defer file.close(io);
        const pattern: [1024 * 1024]u8 = @splat('u');
        var written: u64 = 0;
        while (written < upload_len) : (written += pattern.len) try file.writeStreamingAll(io, &pattern);
    }
    var file = try tmp.dir.openFile(io, "upload.bin", .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);

    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }}, .sink_bodies = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var counting: CountingAllocator = .{ .inner = std.testing.allocator };
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const stream = try open(counting.allocator(), &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "fs write",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/fs/write",
        .headers = &.{.{ .name = "x-cwd", .value = "/Users/example/repo" }},
        .body = .{ .sized = .{ .len = upload_len, .source = &file_reader.interface } },
        .content_type = "application/octet-stream",
        .limits = .{ .total_ms = no_limit_ms },
    });
    defer stream.close();
    try std.testing.expectEqual(@as(u16, 200), stream.status);
    try std.testing.expectEqual(@as(usize, upload_len), server.body_bytes);
    try std.testing.expect(!server.body_chunked);
    try std.testing.expect(counting.peak < 4 * 1024 * 1024);
}

test "a second call connects and completes while an exec stream is still open (V11)" {
    const exec_reply: test_server.Reply = .{ .body = "{\"a\":1}\n", .mode = .lines_then_hold };
    const kill_reply: test_server.Reply = .{ .body = "{\"ok\":true}" };
    var server: test_server.Server = .{ .replies = &.{ exec_reply, kill_reply } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const exec = try open(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = exec_limits,
    });
    defer exec.close();
    try std.testing.expectEqualStrings("{\"a\":1}", (try exec.nextLine()).?);

    const kill = try callBuffered(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "kill",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd/c/kill",
    });
    defer kill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), kill.status);
}

test "real sockets: a connect to a full accept queue ends by its limit, 50 times in a row, with a call between each (V11)" {
    // Two connections fill the accept queue. Linux holds each later connect until its limit ends it, and the
    // test checks that exactly. Elsewhere each connect only has to end by its limit.
    const io = std.testing.io;
    const t0 = io_mod.milliTimestamp();
    const any = try setupStep(std.Io.net.IpAddress.parse("127.0.0.1", 0), "parse address", t0, null);
    var listener = try setupStep(any.listen(io, .{ .kernel_backlog = 1, .reuse_address = true }), "listen", t0, null);
    defer listener.deinit(io);
    const held = listener.socket.address;
    var fillers: [max_fillers]?std.Io.net.Stream = @splat(null);
    defer closeFillers(io, &fillers);
    try fillAcceptQueue(io, &held, &fillers, t0);
    var held_buffer: [64]u8 = undefined;
    const held_base = try setupStep(loopbackBase(&held_buffer, held.getPort()), "held base url", t0, null);

    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }} };
    try setupStep(server.listen(), "test server listen", t0, null);
    try setupStep(server.start(), "test server start", t0, null);
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try setupStep(loopbackBase(&buffer, server.port()), "server base url", t0, null);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const round_started = io_mod.milliTimestamp();
        const result = open(std.testing.allocator, &cancel, held_base, .{ .value = token_text }, capture.trace(), .{
            .step = "connect",
            .method = .GET,
            .path = "/v2/user",
            .limits = .{ .connect_ms = 50 },
        });
        const round_elapsed = io_mod.milliTimestamp() - round_started;
        const outcome = outcomeText(result);
        if (linux_holds) {
            try checkConnect(endedWith(result, error.ConnectTimeout), outcome, round_elapsed, 50, round);
            try checkConnect(round_elapsed >= 50, outcome, round_elapsed, 50, round);
        } else {
            try expectEndedByLimit(result, round_elapsed, 50, capture.captured(), round);
        }
        const response = try setupStep(callBuffered(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
            .step = "user",
            .method = .GET,
            .path = "/v2/user",
        }), "between-round call", t0, round);
        response.deinit(std.testing.allocator);
    }
    try expectOpenJobsDone();
}

test "a second stream opens and reads right after a stream that read a 256 KiB line is closed (V11)" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, max_log_line_bytes + 1);
    defer alloc.free(big);
    @memset(big[0..max_log_line_bytes], 'x');
    big[max_log_line_bytes] = '\n';

    var server: test_server.Server = .{ .replies = &.{
        .{ .body = big, .mode = .lines_then_close },
        .{ .body = "{\"a\":1}\n", .mode = .lines_then_close },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const first = try open(alloc, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = exec_limits,
    });
    try std.testing.expectEqual(max_log_line_bytes, (try first.nextLine()).?.len);
    first.close();

    const second = try open(alloc, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/cmd",
        .limits = exec_limits,
    });
    defer second.close();
    try std.testing.expectEqualStrings("{\"a\":1}", (try second.nextLine()).?);
}

test "the runner's limits are pinned: reattach has no limit, and an fs/write of 32 MiB gets 286 s (V11)" {
    try std.testing.expectEqual(no_limit_ms, reattach_limits.total_ms);
    try std.testing.expectEqual(no_limit_ms, reattach_limits.idle_ms);
    const limits = fsWriteLimits(32 * 1024 * 1024);
    try std.testing.expectEqual(@as(i64, 286_000), limits.total_ms);
    try std.testing.expectEqual(no_limit_ms, limits.idle_ms);
}

test "an upload the server stops reading ends at its total limit as Timeout, and does not hang (V11)" {
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, 32 * 1024 * 1024);
    defer alloc.free(payload);
    @memset(payload, 'u');

    var server: test_server.Server = .{ .replies = &.{.{ .mode = .hold }}, .stall_upload = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var source = std.Io.Reader.fixed(payload);

    try std.testing.expectError(error.Timeout, open(alloc, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "upload",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/fs/write?teamId=team_fake",
        .body = .{ .sized = .{ .len = payload.len, .source = &source } },
        .limits = uploadLimits(payload.len, 100, 1),
    }));
    try std.testing.expect(std.mem.find(u8, capture.captured(), "step upload, failed Timeout") != null);
}

test "a buffered call past its total limit ends as Timeout, and its trace names the failure" {
    var server: test_server.Server = .{ .replies = &.{.{ .mode = .hold }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    try std.testing.expectError(error.Timeout, callBuffered(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "get",
        .method = .GET,
        .path = "/v2/user",
        .limits = .{ .total_ms = 150 },
    }));
    try std.testing.expect(std.mem.find(u8, capture.captured(), "step get, failed Timeout") != null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), token_text) == null);
}

test "a buffered call returns its status and body, and the wire carries the test token, never the real one (AC-30)" {
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }} };
    try server.listen();
    try server.start();
    var buffer: [64]u8 = undefined;
    const base = try loopbackBase(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};

    const response = try callBuffered(std.testing.allocator, &cancel, base, .{ .value = token_text }, capture.trace(), .{
        .step = "user",
        .method = .GET,
        .path = "/v2/user",
    });
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);

    server.close();
    const wire = server.head(0);
    try std.testing.expect(std.mem.find(u8, wire, "Bearer fx-test-token") != null);
    try std.testing.expect(std.mem.find(u8, wire, token_text) == null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step user, status 200") != null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), token_text) == null);
}

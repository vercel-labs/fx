const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const builtin_gateway = @import("../builtins/gateway.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const cooperative_pulse_interval_ms = 50;

extern "fx" fn fx_http_stream_open(
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
) i32;
extern "fx" fn fx_http_stream_status(handle: i32, status_out: *u16) i32;
extern "fx" fn fx_http_stream_next(handle: i32, out_ptr: [*]u8, out_cap: usize) i32;
extern "fx" fn fx_http_stream_close(handle: i32) void;

pub const transport = builtin_gateway.VercelTransport{ .stream_fn = stream };

fn stream(
    _: ?*anyopaque,
    alloc: Allocator,
    request: builtin_gateway.VercelTransportRequest,
) anyerror!builtin_gateway.VercelTransportResponse {
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential});
    defer alloc.free(auth);

    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(alloc);
    try headers.appendSlice(alloc, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = auth },
        .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" },
        .{ .name = "X-Title", .value = "fx" },
        .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" },
        .{ .name = "ai-language-model-specification-version", .value = "4" },
        .{ .name = "ai-language-model-id", .value = request.model_id },
        .{ .name = "ai-language-model-streaming", .value = "true" },
    });
    if (request.tenant) |team| {
        if (team.len > 0) try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
    }
    if (request.session_id) |session_id| {
        if (session_id.len > 0) {
            try headers.appendSlice(alloc, &.{
                .{ .name = "x-session-id", .value = session_id },
                .{ .name = "x-session-affinity", .value = session_id },
            });
        }
    }

    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer headers_json.deinit();
    try std.json.Stringify.value(headers.items, .{}, &headers_json.writer);

    const method = "POST";
    request.delivery.markPossiblySent();
    const handle = fx_http_stream_open(
        method.ptr,
        method.len,
        request.endpoint.ptr,
        request.endpoint.len,
        headers_json.writer.buffered().ptr,
        headers_json.writer.buffered().len,
        request.payload.ptr,
        request.payload.len,
    );
    if (handle < 0) return error.JsHostStreamFailed;
    defer fx_http_stream_close(handle);

    var status_code: u16 = 0;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const status_result = fx_http_stream_status(handle, &status_code);
        if (status_result == 1) break;
        if (status_result == -2) return error.Cancelled;
        if (status_result < 0) return error.JsHostStreamFailed;
        try pulseCooperativeHost(request.cooperative_pulse);
    }

    const status: std.http.Status = @enumFromInt(status_code);
    if (status != .ok) {
        const body = try readBody(alloc, handle, request.cancel_flag, request.cooperative_pulse);
        return .{
            .status = status,
            .err_body = body,
            .owned = true,
        };
    }

    var host_reader: HostStreamReader = undefined;
    host_reader.init(handle, request.cancel_flag, request.cooperative_pulse);
    const completion = gateway_client.consumeGatewaySseStream(
        alloc,
        &host_reader.interface,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.cancel_flag,
        request.content_capture_limit,
    ) catch |err| switch (err) {
        error.ReadFailed => return if (request.cancel_flag.load(.seq_cst) or host_reader.aborted)
            error.Cancelled
        else
            error.JsHostStreamFailed,
        else => return err,
    };

    return .{
        .status = .ok,
        .completion = completion,
        .owned = true,
    };
}

fn pulseCooperativeHost(pulse: ?stream_provider.CooperativePulse) !void {
    if (pulse) |callback| try callback.pulse();
}

fn readBody(
    alloc: Allocator,
    handle: i32,
    cancel_flag: *std.atomic.Value(bool),
    cooperative_pulse: ?stream_provider.CooperativePulse,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const count = fx_http_stream_next(handle, &chunk, chunk.len);
        if (count == -3) {
            try pulseCooperativeHost(cooperative_pulse);
            continue;
        }
        if (count < 0) return error.JsHostStreamFailed;
        if (count == 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(count)]);
    }
    return out.toOwnedSlice(alloc);
}

const HostStreamReader = struct {
    handle: i32 = -1,
    cancel_flag: *std.atomic.Value(bool) = undefined,
    cooperative_pulse: ?stream_provider.CooperativePulse = null,
    last_cooperative_pulse: ?std.Io.Clock.Timestamp = null,
    aborted: bool = false,
    buffer: [16 * 1024]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(
        self: *@This(),
        handle: i32,
        cancel_flag: *std.atomic.Value(bool),
        cooperative_pulse: ?stream_provider.CooperativePulse,
    ) void {
        self.* = .{
            .handle = handle,
            .cancel_flag = cancel_flag,
            .cooperative_pulse = cooperative_pulse,
            .last_cooperative_pulse = if (cooperative_pulse != null)
                std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            else
                null,
        };
        self.interface = .{
            .vtable = &.{
                .stream = HostStreamReader.stream,
                .readVec = HostStreamReader.readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        if (self.cancel_flag.load(.seq_cst)) {
            self.aborted = true;
            return error.ReadFailed;
        }
        for (data) |dest| {
            if (dest.len == 0) continue;
            const count = try self.readHost(dest);
            return count;
        }
        const dest = reader.buffer[reader.end..];
        if (dest.len == 0) return 0;
        const count = try self.readHost(dest);
        reader.end += count;
        return 0;
    }

    fn pulseAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        self.last_cooperative_pulse = now;
        try pulseCooperativeHost(self.cooperative_pulse);
    }

    fn pulseIfDueAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        const last_pulse = self.last_cooperative_pulse orelse return;
        const elapsed_ms = last_pulse.durationTo(now).raw.toMilliseconds();
        if (elapsed_ms < cooperative_pulse_interval_ms) return;
        try self.pulseAt(now);
    }

    fn readHost(self: *@This(), dest: []u8) std.Io.Reader.Error!usize {
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) {
                self.aborted = true;
                return error.ReadFailed;
            }
            if (self.cooperative_pulse != null) {
                self.pulseIfDueAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch
                    return error.ReadFailed;
            }
            if (self.cancel_flag.load(.seq_cst)) {
                self.aborted = true;
                return error.ReadFailed;
            }
            const count = fx_http_stream_next(self.handle, dest.ptr, dest.len);
            if (count == -3) {
                if (self.cooperative_pulse != null) {
                    self.pulseAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch
                        return error.ReadFailed;
                }
                continue;
            }
            if (count == -2) {
                self.aborted = true;
                return error.ReadFailed;
            }
            if (count < 0) return error.ReadFailed;
            if (count == 0) return error.EndOfStream;
            return @intCast(count);
        }
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const count = readVec(reader, &data) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        writer.advance(count);
        return count;
    }
};

test "JS host stream reader throttles cooperative pulses" {
    const PulseTrace = struct {
        calls: usize = 0,

        fn run(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    const awakeTimestamp = struct {
        fn at(milliseconds: i64) std.Io.Clock.Timestamp {
            return .{
                .clock = .awake,
                .raw = .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms),
            };
        }
    }.at;

    var trace: PulseTrace = .{};
    var reader: HostStreamReader = .{
        .cooperative_pulse = .{ .ctx = &trace, .run = PulseTrace.run },
        .last_cooperative_pulse = awakeTimestamp(100),
    };

    try reader.pulseIfDueAt(awakeTimestamp(149));
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try reader.pulseIfDueAt(awakeTimestamp(150));
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try reader.pulseIfDueAt(awakeTimestamp(199));
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try reader.pulseIfDueAt(awakeTimestamp(200));
    try std.testing.expectEqual(@as(usize, 2), trace.calls);
}

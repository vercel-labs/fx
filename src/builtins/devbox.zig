const std = @import("std");

const debug_trace = @import("../core/shared/debug_trace.zig");
const devbox_executor = @import("../core/execution/devbox_executor.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const CommandResult = devbox_executor.CommandResult;
const Control = devbox_executor.Control;
const VercelOutcome = devbox_executor.VercelOutcome;

const vercel_http_timeout_sec: i64 = 30;

pub const provider = devbox_executor.Provider{ .execute_fn = executeProvider };

fn executeProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    control: Control,
) devbox_executor.ProviderError!VercelOutcome {
    return executeVercel(alloc, command, cwd, control) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.TimeoutExpired => error.TimeoutExpired,
    };
}

pub fn executeVercel(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    control: Control,
) !VercelOutcome {
    try control.check();

    const token = getVercelAuthToken() orelse return .unavailable;
    if (try executeVercelControlled(alloc, command, cwd, token, control)) |result| {
        return .{ .success = result };
    }
    return .request_failed;
}

fn setVercelHttpTimeout(conn: *std.http.Client.Connection) void {
    if (comptime @import("builtin").os.tag == .windows) {
        return;
    } else {
        const sock = conn.stream_writer.stream.socket.handle;
        const timeout = std.posix.timeval{ .sec = vercel_http_timeout_sec, .usec = 0 };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            debug_trace.logf("core", "vercel sandbox receive timeout setup failed err={s}", .{@errorName(err)});
        };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            debug_trace.logf("core", "vercel sandbox send timeout setup failed err={s}", .{@errorName(err)});
        };
    }
}

fn executeVercelHttp(alloc: Allocator, scratch: Allocator, token: []const u8, command: []const u8, cwd: []const u8) !CommandResult {
    const started_ms = io_mod.milliTimestamp();
    var body_writer: std.Io.Writer.Allocating = .init(scratch);
    defer body_writer.deinit();
    try body_writer.writer.writeAll("{\"command\":\"sh\",\"args\":[\"-lc\",");
    try std.json.Stringify.value(command, .{}, &body_writer.writer);
    try body_writer.writer.writeAll("],\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, &body_writer.writer);
    try body_writer.writer.writeAll(",\"wait\":true}");
    const request_body = try body_writer.toOwnedSlice();
    defer scratch.free(request_body);

    const auth_header = try std.fmt.allocPrint(scratch, "Bearer {s}", .{token});
    defer scratch.free(auth_header);
    var response_buf: std.Io.Writer.Allocating = .init(scratch);
    defer response_buf.deinit();

    var client: std.http.Client = .{ .allocator = scratch, .io = io_mod.getIo() };
    defer client.deinit();

    const uri = try std.Uri.parse("https://api.vercel.com/v1/sandboxes/cmd");
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .authorization = .{ .override = auth_header },
            .content_type = .{ .override = "application/json" },
        },
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    if (req.connection) |conn| setVercelHttpTimeout(conn);
    req.transfer_encoding = .{ .content_length = request_body.len };
    var send_buf: [8192]u8 = undefined;
    var request_writer = try req.sendBodyUnflushed(&send_buf);
    try request_writer.writer.writeAll(request_body);
    try request_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok) {
        if (req.connection) |conn| conn.closing = true;
        return error.VercelResponseFailure;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try scratch.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try scratch.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) scratch.free(decompress_buffer);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const response_reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);
    _ = response_reader.streamRemaining(&response_buf.writer) catch |err| switch (err) {
        error.ReadFailed => {
            if (response.bodyErr()) |body_err| return body_err;
            return err;
        },
        else => |e| return e,
    };

    const response_body = try response_buf.toOwnedSlice();
    defer scratch.free(response_body);
    return parseVercelResponse(alloc, scratch, response_body, elapsedMs(started_ms, io_mod.milliTimestamp()));
}

const VercelHttpResultTag = enum {
    success,
    fallback,
    oom,
};

const VercelHttpRequest = struct {
    command: []u8,
    cwd: []u8,
    token: []u8,

    fn create(command: []const u8, cwd: []const u8, token: []const u8) !*VercelHttpRequest {
        const alloc = std.heap.c_allocator;
        const self = try alloc.create(VercelHttpRequest);
        errdefer alloc.destroy(self);
        self.* = .{
            .command = try alloc.dupe(u8, command),
            .cwd = &.{},
            .token = &.{},
        };
        errdefer alloc.free(self.command);
        self.cwd = try alloc.dupe(u8, cwd);
        errdefer alloc.free(self.cwd);
        self.token = try alloc.dupe(u8, token);
        return self;
    }

    fn deinit(self: *VercelHttpRequest) void {
        const alloc = std.heap.c_allocator;
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.token);
        alloc.destroy(self);
    }
};

fn executeVercelControlled(alloc: Allocator, command: []const u8, cwd: []const u8, token: []const u8, control: Control) !?CommandResult {
    const request = try VercelHttpRequest.create(command, cwd, token);
    defer request.deinit();

    if (!control.canInterrupt()) {
        const result = runVercelRequest(request) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Cancelled,
            else => {
                debug_trace.logf("core", "vercel sandbox request failed err={s}", .{@errorName(err)});
                return null;
            },
        };
        return finishVercelResult(alloc, result);
    }

    const zio = io_mod.getIo();
    var queue_buf: [2]VercelRaceEvent = undefined;
    var queue = VercelRaceQueue.init(&queue_buf);
    var request_future = zio.concurrent(runVercelRequestQueued, .{ &queue, request }) catch |err| {
        debug_trace.logf("core", "vercel sandbox request concurrency unavailable err={s}", .{@errorName(err)});
        return null;
    };
    var control_future = zio.async(runVercelControlQueued, .{ &queue, control });

    const event = queue.getOne(zio) catch |err| {
        request_future.cancel(zio);
        _ = control_future.cancel(zio) catch {};
        debug_trace.logf("core", "vercel sandbox request race failed err={s}", .{@errorName(err)});
        return null;
    };

    switch (event) {
        .request => |result| {
            _ = control_future.cancel(zio) catch {};
            request_future.await(zio);
            return finishVercelResult(alloc, result);
        },
        .cancelled => {
            request_future.cancel(zio);
            _ = control_future.await(zio) catch {};
            discardQueuedVercelEvents(&queue);
            return error.Cancelled;
        },
        .timed_out => {
            request_future.cancel(zio);
            _ = control_future.await(zio) catch {};
            discardQueuedVercelEvents(&queue);
            return error.TimeoutExpired;
        },
    }
}

fn finishVercelResult(alloc: Allocator, result: VercelHttpResult) !?CommandResult {
    return switch (result) {
        .success => |output| blk: {
            var owned = output;
            defer owned.deinit(std.heap.c_allocator);
            break :blk try owned.clone(alloc);
        },
        .fallback => null,
        .oom => error.OutOfMemory,
    };
}

fn runVercelRequest(request: *VercelHttpRequest) anyerror!VercelHttpResult {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch_state.deinit();

    const result = try executeVercelHttp(std.heap.c_allocator, scratch_state.allocator(), request.token, request.command, request.cwd);
    return .{ .success = result };
}

const VercelHttpResult = union(VercelHttpResultTag) {
    success: CommandResult,
    fallback,
    oom,
};

const VercelRaceEvent = union(enum) {
    request: VercelHttpResult,
    cancelled,
    timed_out,
};

const VercelRaceQueue = std.Io.Queue(VercelRaceEvent);

fn runVercelRequestQueued(queue: *VercelRaceQueue, request: *VercelHttpRequest) void {
    const result = runVercelRequest(request) catch |err| switch (err) {
        error.Canceled => return,
        error.OutOfMemory => VercelHttpResult.oom,
        else => blk: {
            debug_trace.logf("core", "vercel sandbox request failed err={s}", .{@errorName(err)});
            break :blk VercelHttpResult.fallback;
        },
    };
    queue.putOneUncancelable(io_mod.getIo(), .{ .request = result }) catch {
        freeVercelResult(result);
    };
}

fn runVercelControlQueued(queue: *VercelRaceQueue, control: Control) std.Io.Cancelable!void {
    while (true) {
        control.check() catch |err| switch (err) {
            error.Cancelled => {
                queue.putOneUncancelable(io_mod.getIo(), .cancelled) catch {};
                return;
            },
            error.TimeoutExpired => {
                queue.putOneUncancelable(io_mod.getIo(), .timed_out) catch {};
                return;
            },
            else => return,
        };
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms }, .clock = .awake } }, io_mod.getIo());
    }
}

fn discardQueuedVercelEvents(queue: *VercelRaceQueue) void {
    var events: [2]VercelRaceEvent = undefined;
    const count = queue.get(io_mod.getIo(), &events, 0) catch 0;
    for (events[0..count]) |event| {
        switch (event) {
            .request => |result| freeVercelResult(result),
            .cancelled, .timed_out => {},
        }
    }
}

fn freeVercelResult(result: VercelHttpResult) void {
    switch (result) {
        .success => |output| {
            var owned = output;
            owned.deinit(std.heap.c_allocator);
        },
        .fallback, .oom => {},
    }
}

fn parseVercelResponse(alloc: Allocator, scratch: Allocator, body: []const u8, duration_ms: ?u64) !CommandResult {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, body, .{}) catch return error.VercelParseError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.VercelParseError;

    const exit_code_val = parsed.value.object.get("exitCode") orelse return error.VercelParseError;
    const stdout_val = parsed.value.object.get("stdout") orelse return error.VercelParseError;
    const stderr_val = parsed.value.object.get("stderr") orelse return error.VercelParseError;
    if (exit_code_val != .integer or stdout_val != .string or stderr_val != .string) return error.VercelParseError;

    const stdout = try alloc.dupe(u8, stdout_val.string);
    errdefer alloc.free(stdout);
    const stderr = try alloc.dupe(u8, stderr_val.string);
    errdefer alloc.free(stderr);
    return .{
        .exit_code = exit_code_val.integer,
        .stdout = stdout,
        .stderr = stderr,
        .duration_ms = duration_ms,
    };
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

fn getVercelAuthToken() ?[]const u8 {
    return getVercelAuthTokenForProbe(.{
        .oidc_token = io_mod.getenv("VERCEL_OIDC_TOKEN"),
        .token = io_mod.getenv("VERCEL_TOKEN"),
    });
}

const VercelCredentialProbe = struct {
    oidc_token: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

fn getVercelAuthTokenForProbe(probe: VercelCredentialProbe) ?[]const u8 {
    if (probe.oidc_token) |token| return token;
    return probe.token;
}

test "devbox vercel control checks cancellation and timeout before remote work" {
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, executeVercel(
        std.testing.allocator,
        "printf no",
        "/tmp",
        .{
            .cancel_flag = &cancel,
            .timeout_ms = 1000,
            .started_ms = io_mod.milliTimestamp(),
        },
    ));

    try std.testing.expectError(error.TimeoutExpired, executeVercel(
        std.testing.allocator,
        "printf no",
        "/tmp",
        .{
            .timeout_ms = 0,
            .started_ms = io_mod.milliTimestamp(),
        },
    ));
}

test "devbox vercel auth token prefers oidc and falls back to token" {
    try std.testing.expectEqualStrings("oidc", getVercelAuthTokenForProbe(.{
        .oidc_token = "oidc",
        .token = "token",
    }).?);
    try std.testing.expectEqualStrings("token", getVercelAuthTokenForProbe(.{ .token = "token" }).?);
    try std.testing.expect(getVercelAuthTokenForProbe(.{}) == null);
}

test "devbox vercel json parser handles success and parse failure" {
    var result = try parseVercelResponse(
        std.testing.allocator,
        std.testing.allocator,
        "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}",
        7,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), result.exit_code);
    try std.testing.expectEqualStrings("ok", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(?u64, 7), result.duration_ms);
    try std.testing.expectError(
        error.VercelParseError,
        parseVercelResponse(std.testing.allocator, std.testing.allocator, "{}", null),
    );
}

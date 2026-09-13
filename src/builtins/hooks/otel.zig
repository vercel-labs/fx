const std = @import("std");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const Header = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *Header, alloc: Allocator) void {
        alloc.free(self.name);
        secretZeroFree(alloc, self.value);
    }
};

const ConfigError = Allocator.Error || error{ InvalidEndpoint, InvalidHeaders, InvalidTimeout, UnsupportedProtocol, UnsupportedCompression };
const QueueCapacity = 4;
const MaxHeaders = 32;
const DefaultTimeoutMs: i64 = 10_000;
const RetryBaseDelayNs: u64 = 100 * std.time.ns_per_ms;
const RetryMaxDelayNs: u64 = 5 * std.time.ns_per_s;

const Job = struct {
    payload: []u8,
};

pub const State = struct {
    alloc: Allocator = std.heap.c_allocator,
    endpoint: ?[]u8 = null,
    service_name: []u8 = &.{},
    headers: std.ArrayList(Header) = .empty,
    timeout_ms: i64 = DefaultTimeoutMs,
    configured: bool = false,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: [QueueCapacity]Job = undefined,
    queue_len: usize = 0,
    stopping: bool = false,
    shutdown_deadline: ?std.Io.Clock.Timestamp = null,
    worker: ?std.Thread = null,

    pub fn configure(self: *State) !void {
        self.deinit();
        self.configured = true;
        if (std.ascii.eqlIgnoreCase(io_mod.getenv("OTEL_SDK_DISABLED") orelse "", "true")) return;
        const signal_endpoint = io_mod.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT");
        const generic_endpoint = io_mod.getenv("OTEL_EXPORTER_OTLP_ENDPOINT");
        const raw_endpoint = signal_endpoint orelse generic_endpoint orelse return;
        if (raw_endpoint.len == 0) return;
        const endpoint = if (signal_endpoint != null)
            try self.alloc.dupe(u8, raw_endpoint)
        else
            try traceEndpoint(self.alloc, raw_endpoint, false);
        const uri = std.Uri.parse(endpoint) catch {
            self.alloc.free(endpoint);
            return error.InvalidEndpoint;
        };
        if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null) {
            self.alloc.free(endpoint);
            return error.InvalidEndpoint;
        }
        self.endpoint = endpoint;
        const configured_service_name = io_mod.getenv("OTEL_SERVICE_NAME") orelse "fx";
        self.service_name = try self.alloc.dupe(u8, if (configured_service_name.len > 0) configured_service_name else "fx");

        const timeout_key = if (io_mod.getenv("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT") != null)
            "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT"
        else
            "OTEL_EXPORTER_OTLP_TIMEOUT";
        if (io_mod.getenv(timeout_key)) |raw| {
            self.timeout_ms = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidTimeout;
            if (self.timeout_ms <= 0) return error.InvalidTimeout;
        }
        const protocol = io_mod.getenv("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL") orelse
            io_mod.getenv("OTEL_EXPORTER_OTLP_PROTOCOL") orelse "http/json";
        if (!std.mem.eql(u8, protocol, "http/json")) return error.UnsupportedProtocol;
        const compression = io_mod.getenv("OTEL_EXPORTER_OTLP_TRACES_COMPRESSION") orelse
            io_mod.getenv("OTEL_EXPORTER_OTLP_COMPRESSION") orelse "none";
        if (!std.mem.eql(u8, compression, "none") and compression.len != 0) return error.UnsupportedCompression;
        const header_key = if (io_mod.getenv("OTEL_EXPORTER_OTLP_TRACES_HEADERS") != null)
            "OTEL_EXPORTER_OTLP_TRACES_HEADERS"
        else
            "OTEL_EXPORTER_OTLP_HEADERS";
        if (io_mod.getenv(header_key)) |raw| try parseHeaders(self, raw);
        self.stopping = false;
        self.shutdown_deadline = null;
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn shutdown(self: *State) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (!self.stopping) {
            self.stopping = true;
            self.shutdown_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromMilliseconds(self.timeout_ms),
            });
        }
        self.condition.broadcast(io_mod.getIo());
        self.mutex.unlock(io_mod.getIo());
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        while (self.queue_len > 0) {
            self.queue_len -= 1;
            secretZeroFree(self.alloc, self.queue[self.queue_len].payload);
        }
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn deinit(self: *State) void {
        self.shutdown();
        if (self.endpoint) |value| self.alloc.free(value);
        if (self.service_name.len > 0) self.alloc.free(self.service_name);
        for (self.headers.items) |*header| header.deinit(self.alloc);
        self.headers.deinit(self.alloc);
        self.endpoint = null;
        self.service_name = &.{};
        self.headers = .empty;
        self.timeout_ms = DefaultTimeoutMs;
        self.shutdown_deadline = null;
        self.configured = false;
    }

    pub fn enabled(self: *const State) bool {
        return self.endpoint != null and self.endpoint.?.len > 0 and self.configured;
    }
};

fn secretZeroFree(alloc: Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    alloc.free(value);
}

fn parseHeaders(state: *State, raw: []const u8) ConfigError!void {
    if (raw.len == 0) return;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) return error.InvalidHeaders;
        const equal = std.mem.findScalar(u8, trimmed, '=') orelse return error.InvalidHeaders;
        const name = std.mem.trim(u8, trimmed[0..equal], " \t");
        const encoded = std.mem.trim(u8, trimmed[equal + 1 ..], " \t");
        if (!validHeaderName(name) or transportHeader(name)) return error.InvalidHeaders;
        const value = percentDecode(state.alloc, encoded) catch return error.InvalidHeaders;
        errdefer secretZeroFree(state.alloc, value);
        if (!validHeaderValue(value)) return error.InvalidHeaders;
        if (state.headers.items.len >= MaxHeaders) return error.InvalidHeaders;
        for (state.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return error.InvalidHeaders;
        }
        const owned_name = try state.alloc.dupe(u8, name);
        errdefer state.alloc.free(owned_name);
        try state.headers.append(state.alloc, .{ .name = owned_name, .value = value });
    }
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null)) return false;
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn transportHeader(name: []const u8) bool {
    const reserved = [_][]const u8{
        "connection",
        "content-length",
        "content-type",
        "host",
        "transfer-encoding",
    };
    for (reserved) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn percentDecode(alloc: Allocator, input: []const u8) (Allocator.Error || error{InvalidPercent})![]u8 {
    var out = try alloc.alloc(u8, input.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%') {
            if (i + 2 >= input.len) {
                alloc.free(out);
                return error.InvalidPercent;
            }
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                alloc.free(out);
                return error.InvalidPercent;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                alloc.free(out);
                return error.InvalidPercent;
            };
            out[n] = (@as(u8, hi) << 4) | @as(u8, lo);
            n += 1;
            i += 2;
        } else {
            out[n] = input[i];
            n += 1;
        }
    }
    return alloc.realloc(out, n);
}

fn workerMain(state: *State) void {
    while (true) {
        state.mutex.lockUncancelable(io_mod.getIo());
        while (state.queue_len == 0 and !state.stopping) state.condition.waitUncancelable(io_mod.getIo(), &state.mutex);
        if (state.queue_len == 0 and state.stopping) {
            state.mutex.unlock(io_mod.getIo());
            return;
        }
        const job = state.queue[0];
        var index: usize = 1;
        while (index < state.queue_len) : (index += 1) state.queue[index - 1] = state.queue[index];
        state.queue_len -= 1;
        const deadline = state.shutdown_deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(state.timeout_ms),
        });
        state.mutex.unlock(io_mod.getIo());
        sendPayload(state, job.payload, deadline) catch |err| debug_trace.logf("otel", "trace export failed error={s}", .{@errorName(err)});
        secretZeroFree(state.alloc, job.payload);
    }
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(app: *App) !void {
            app.otel.configure() catch |err| {
                debug_trace.logf("otel", "exporter disabled during configuration error={s}", .{@errorName(err)});
                app.otel.deinit();
                return;
            };
            if (!app.otel.enabled()) return;
            errdefer app.otel.deinit();
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.otel.turn",
                .ctx = &app.otel,
                .run = postTurnEnd,
            });
        }

        fn postTurnEnd(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            const state: *State = @ptrCast(@alignCast(raw));
            const payload = buildPayload(state.alloc, state.service_name, input) catch |err| {
                debug_trace.logf("otel", "trace dropped error={s}", .{@errorName(err)});
                return;
            };
            _ = enqueuePayload(state, payload, input.invocation.scope.kind);
        }
    };
}

fn enqueuePayload(state: *State, payload: []u8, scope: hooks.ScopeKind) bool {
    state.mutex.lockUncancelable(io_mod.getIo());
    defer state.mutex.unlock(io_mod.getIo());
    if (state.stopping or state.queue_len >= QueueCapacity) {
        const reason = if (state.stopping) "shutdown" else "queue_full";
        secretZeroFree(state.alloc, payload);
        debug_trace.logf("otel", "trace dropped reason={s} scope={s}", .{ reason, @tagName(scope) });
        return false;
    }
    state.queue[state.queue_len] = .{ .payload = payload };
    state.queue_len += 1;
    state.condition.signal(io_mod.getIo());
    return true;
}

const ExportError = Allocator.Error || error{ InvalidEndpoint, HttpFailure, Timeout };

const AttemptResult = struct {
    status: std.http.Status,
    retry_after_seconds: ?u64,
};

const Attempt = struct {
    state: *const State,
    uri: std.Uri,
    payload: []const u8,

    fn run(self: *Attempt) !AttemptResult {
        var client: std.http.Client = .{ .allocator = self.state.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var extra_headers: [MaxHeaders]std.http.Header = undefined;
        for (self.state.headers.items, 0..) |header, index| {
            extra_headers[index] = .{ .name = header.name, .value = header.value };
        }
        var request = try client.request(.POST, self.uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
            },
            .extra_headers = extra_headers[0..self.state.headers.items.len],
        });
        defer request.deinit();
        try request.sendBodyComplete(@constCast(self.payload));
        const response = try request.receiveHead(&.{});
        return .{
            .status = response.head.status,
            .retry_after_seconds = retryAfterSeconds(response.head),
        };
    }
};

fn sendPayload(
    state: *const State,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
) ExportError!void {
    const endpoint = state.endpoint orelse return;
    const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
    var attempt_index: usize = 0;
    while (true) : (attempt_index += 1) {
        if (!beforeDeadline(deadline)) return error.Timeout;
        var attempt = Attempt{ .state = state, .uri = uri, .payload = payload };
        const result = runBoundedAttempt(&attempt, deadline) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Timeout) return error.Timeout;
            try waitBeforeRetry(deadline, retryBackoffDelayNs(attempt_index));
            continue;
        };
        if (result.status == .ok) return;
        if (!retryableStatus(result.status)) return error.HttpFailure;
        const delay_ns = if (result.retry_after_seconds) |seconds|
            std.math.mul(u64, seconds, std.time.ns_per_s) catch RetryMaxDelayNs
        else
            retryBackoffDelayNs(attempt_index);
        try waitBeforeRetry(deadline, @min(delay_ns, RetryMaxDelayNs));
    }
}

const AttemptEvent = union(enum) {
    request: anyerror!AttemptResult,
    deadline: anyerror!void,
};

fn runBoundedAttempt(attempt: *Attempt, deadline: std.Io.Clock.Timestamp) !AttemptResult {
    var events: [2]AttemptEvent = undefined;
    var select: std.Io.Select(AttemptEvent) = .init(io_mod.getIo(), &events);
    select.concurrent(.deadline, waitForDeadline, .{deadline}) catch |err| return err;
    select.concurrent(.request, Attempt.run, .{attempt}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    const event = select.await() catch |err| {
        drainAttemptSelect(&select);
        return err;
    };
    switch (event) {
        .request => |result| {
            drainAttemptSelect(&select);
            return result;
        },
        .deadline => |result| {
            result catch |err| {
                drainAttemptSelect(&select);
                return err;
            };
            drainAttemptSelect(&select);
            return error.Timeout;
        },
    }
}

fn drainAttemptSelect(select: *std.Io.Select(AttemptEvent)) void {
    while (select.cancel()) |_| {}
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

fn beforeDeadline(deadline: std.Io.Clock.Timestamp) bool {
    return std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        .lt,
        deadline,
    );
}

fn waitBeforeRetry(deadline: std.Io.Clock.Timestamp, delay_ns: u64) ExportError!void {
    if (!beforeDeadline(deadline)) return error.Timeout;
    var wake = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromNanoseconds(@intCast(delay_ns)),
    });
    if (std.Io.Clock.Timestamp.compare(deadline, .lt, wake)) wake = deadline;
    wake.wait(io_mod.getIo()) catch return error.HttpFailure;
    if (!beforeDeadline(deadline)) return error.Timeout;
}

fn retryBackoffDelayNs(attempt_index: usize) u64 {
    var ceiling = RetryBaseDelayNs;
    var index: usize = 0;
    while (index < @min(attempt_index, 6)) : (index += 1) {
        ceiling = @min(ceiling * 2, RetryMaxDelayNs);
    }
    var random: u64 = undefined;
    io_mod.getIo().random(std.mem.asBytes(&random));
    const half = ceiling / 2;
    return half + random % (half + 1);
}

fn retryableStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

fn retryAfterSeconds(head: std.http.Client.Response.Head) ?u64 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        return parseRetryAfter(std.mem.trim(u8, header.value, " \t\r\n"));
    }
    return null;
}

fn parseRetryAfter(value: []const u8) ?u64 {
    if (std.fmt.parseInt(u64, value, 10)) |seconds| return seconds else |_| {}
    const requested_at = parseImfFixdate(value) orelse return null;
    const now = @divFloor(io_mod.milliTimestamp(), std.time.ms_per_s);
    if (requested_at <= now) return 0;
    return @intCast(requested_at - now);
}

fn parseImfFixdate(value: []const u8) ?i64 {
    if (value.len != 29 or value[3] != ',' or value[4] != ' ' or value[7] != ' ' or
        value[11] != ' ' or value[16] != ' ' or value[19] != ':' or value[22] != ':' or
        value[25] != ' ' or !std.mem.eql(u8, value[26..29], "GMT")) return null;
    const weekday = value[0..3];
    if (!std.mem.eql(u8, weekday, "Mon") and !std.mem.eql(u8, weekday, "Tue") and
        !std.mem.eql(u8, weekday, "Wed") and !std.mem.eql(u8, weekday, "Thu") and
        !std.mem.eql(u8, weekday, "Fri") and !std.mem.eql(u8, weekday, "Sat") and
        !std.mem.eql(u8, weekday, "Sun")) return null;

    const day = std.fmt.parseInt(i64, value[5..7], 10) catch return null;
    const year = std.fmt.parseInt(i64, value[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(i64, value[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(i64, value[20..22], 10) catch return null;
    const second = std.fmt.parseInt(i64, value[23..25], 10) catch return null;
    const month: i64 = if (std.mem.eql(u8, value[8..11], "Jan")) 1 else if (std.mem.eql(u8, value[8..11], "Feb")) 2 else if (std.mem.eql(u8, value[8..11], "Mar")) 3 else if (std.mem.eql(u8, value[8..11], "Apr")) 4 else if (std.mem.eql(u8, value[8..11], "May")) 5 else if (std.mem.eql(u8, value[8..11], "Jun")) 6 else if (std.mem.eql(u8, value[8..11], "Jul")) 7 else if (std.mem.eql(u8, value[8..11], "Aug")) 8 else if (std.mem.eql(u8, value[8..11], "Sep")) 9 else if (std.mem.eql(u8, value[8..11], "Oct")) 10 else if (std.mem.eql(u8, value[8..11], "Nov")) 11 else if (std.mem.eql(u8, value[8..11], "Dec")) 12 else return null;
    if (year < 1970 or hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59) return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const days_in_month = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > days_in_month[@intCast(month - 1)]) return null;

    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    const epoch_day = era * 146097 + day_of_era - 719468;
    return epoch_day * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
}

fn traceEndpoint(alloc: Allocator, endpoint: []const u8, signal_specific: bool) Allocator.Error![]u8 {
    if (signal_specific) return alloc.dupe(u8, endpoint);
    var split = endpoint.len;
    if (std.mem.findScalar(u8, endpoint, '?')) |index| split = @min(split, index);
    if (std.mem.findScalar(u8, endpoint, '#')) |index| split = @min(split, index);
    const base = endpoint[0..split];
    const suffix = endpoint[split..];
    const separator = if (std.mem.endsWith(u8, base, "/")) "" else "/";
    return std.fmt.allocPrint(alloc, "{s}{s}v1/traces{s}", .{ base, separator, suffix });
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeStringAttr(writer: *std.Io.Writer, key: []const u8, value: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeAll("{\"key\":");
    try writeString(writer, key);
    try writer.writeAll(",\"value\":{\"stringValue\":");
    try writeString(writer, value);
    try writer.writeAll("}}");
}

fn writeUnixNanos(writer: *std.Io.Writer, value: i64) !void {
    const nanos: i128 = @as(i128, @max(value, 0)) * std.time.ns_per_ms;
    try writer.print("\"{d}\"", .{nanos});
}

fn fillNonzeroRandom(bytes: []u8) void {
    while (true) {
        io_mod.getIo().random(bytes);
        for (bytes) |byte| {
            if (byte != 0) return;
        }
    }
}

fn buildPayload(alloc: Allocator, service_name: []const u8, input: hooks.PostTurnEndInput) ![]u8 {
    var trace_id: [16]u8 = undefined;
    var span_id: [8]u8 = undefined;
    fillNonzeroRandom(&trace_id);
    fillNonzeroRandom(&span_id);
    const trace_hex = std.fmt.bytesToHex(trace_id, .lower);
    const span_hex = std.fmt.bytesToHex(span_id, .lower);

    const now_ms = io_mod.milliTimestamp();
    const reported_start_ms = if (input.turn_summary) |summary| summary.started_at_ms else now_ms;
    const reported_end_ms = if (input.turn_summary) |summary| summary.completed_at_ms else now_ms;
    const start_ms = if (reported_start_ms > 0) reported_start_ms else now_ms;
    const end_ms = if (reported_end_ms >= start_ms) reported_end_ms else start_ms;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":");
    try writeString(&out.writer, service_name);
    try out.writer.writeAll("}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"fx\"},\"spans\":[{\"traceId\":");
    try writeString(&out.writer, &trace_hex);
    try out.writer.writeAll(",\"spanId\":");
    try writeString(&out.writer, &span_hex);
    try out.writer.writeAll(",\"name\":\"fx.turn\",\"kind\":1,\"startTimeUnixNano\":");
    try writeUnixNanos(&out.writer, start_ms);
    try out.writer.writeAll(",\"endTimeUnixNano\":");
    try writeUnixNanos(&out.writer, end_ms);
    try out.writer.writeAll(",\"attributes\":[");
    var first = true;
    try writeStringAttr(&out.writer, "fx.turn.scope", @tagName(input.invocation.scope.kind), &first);
    try writeStringAttr(&out.writer, "fx.turn.outcome", @tagName(input.outcome), &first);
    if (input.provider_disposition) |disposition| {
        try writeStringAttr(&out.writer, "fx.turn.provider_disposition", @tagName(disposition), &first);
    }
    if (input.outcome == .failed) try writeStringAttr(&out.writer, "error.type", "fx.turn.failed", &first);
    const status_code: u8 = if (input.outcome == .failed) 2 else 0;
    try out.writer.print("],\"status\":{{\"code\":{d}}}}}]}}]}}]}}", .{status_code});
    return try out.toOwnedSlice();
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != '0') return false;
    return true;
}

test "OTLP payload has the expected schema, identifiers, status, and privacy boundary" {
    const payload = try buildPayload(std.testing.allocator, "test-service", .{
        .invocation = .{ .scope = .{ .kind = .ask, .workspace_root = "/private", .session_id = "secret" } },
        .outcome = .completed,
        .provider_disposition = .length_limited,
        .turn_summary = .{
            .started_at_ms = 1,
            .completed_at_ms = 13,
            .turn_duration_ms = 12,
            .token_progress = .{ .input_tokens = 3, .output_tokens = 4 },
        },
    });
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const resource_spans = parsed.value.object.get("resourceSpans").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), resource_spans.len);
    const scope_spans = resource_spans[0].object.get("scopeSpans").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), scope_spans.len);
    const spans = scope_spans[0].object.get("spans").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    const span = spans[0].object;
    const trace_id = span.get("traceId").?.string;
    const span_id = span.get("spanId").?.string;
    try std.testing.expectEqual(@as(usize, 32), trace_id.len);
    try std.testing.expectEqual(@as(usize, 16), span_id.len);
    try std.testing.expect(!allZero(trace_id));
    try std.testing.expect(!allZero(span_id));
    try std.testing.expectEqualStrings("fx.turn", span.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 1), span.get("kind").?.integer);
    try std.testing.expectEqualStrings("1000000", span.get("startTimeUnixNano").?.string);
    try std.testing.expectEqualStrings("13000000", span.get("endTimeUnixNano").?.string);
    try std.testing.expectEqual(@as(i64, 0), span.get("status").?.object.get("code").?.integer);
    try std.testing.expect(std.mem.find(u8, payload, "fx.turn.scope") != null);
    try std.testing.expect(std.mem.find(u8, payload, "fx.turn.outcome") != null);
    try std.testing.expect(std.mem.find(u8, payload, "fx.turn.provider_disposition") != null);
    try std.testing.expect(std.mem.find(u8, payload, "private") == null);
    try std.testing.expect(std.mem.find(u8, payload, "secret") == null);
    try std.testing.expect(std.mem.find(u8, payload, "assistant") == null);
    try std.testing.expect(std.mem.find(u8, payload, "input_tokens") == null);
    try std.testing.expect(std.mem.find(u8, payload, "output_tokens") == null);
}

test "OTLP payload marks only failed turns as errors" {
    const cases = [_]struct { outcome: types.TurnPresentationOutcome, code: i64, has_error_type: bool }{
        .{ .outcome = .completed, .code = 0, .has_error_type = false },
        .{ .outcome = .interrupted, .code = 0, .has_error_type = false },
        .{ .outcome = .paused, .code = 0, .has_error_type = false },
        .{ .outcome = .failed, .code = 2, .has_error_type = true },
    };
    for (cases) |case| {
        const payload = try buildPayload(std.testing.allocator, "fx", .{
            .invocation = .{ .scope = .{ .kind = .acp, .workspace_root = "" } },
            .outcome = case.outcome,
        });
        defer std.testing.allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
        defer parsed.deinit();
        const resource_span = parsed.value.object.get("resourceSpans").?.array.items[0];
        const scope_span = resource_span.object.get("scopeSpans").?.array.items[0];
        const span = scope_span.object.get("spans").?.array.items[0].object;
        try std.testing.expectEqual(case.code, span.get("status").?.object.get("code").?.integer);
        try std.testing.expectEqual(case.has_error_type, std.mem.find(u8, payload, "error.type") != null);
    }
}

test "generic OTLP endpoint gains the traces path before query and fragment" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "http://localhost:4318", .expected = "http://localhost:4318/v1/traces" },
        .{ .input = "http://localhost:4318/", .expected = "http://localhost:4318/v1/traces" },
        .{ .input = "http://localhost:4318/collector", .expected = "http://localhost:4318/collector/v1/traces" },
        .{ .input = "http://localhost:4318/collector/?tenant=a#part", .expected = "http://localhost:4318/collector/v1/traces?tenant=a#part" },
    };
    for (cases) |case| {
        const endpoint = try traceEndpoint(std.testing.allocator, case.input, false);
        defer std.testing.allocator.free(endpoint);
        try std.testing.expectEqualStrings(case.expected, endpoint);
    }
    const signal_specific = try traceEndpoint(std.testing.allocator, "http://localhost:4318/custom?tenant=a", true);
    defer std.testing.allocator.free(signal_specific);
    try std.testing.expectEqualStrings("http://localhost:4318/custom?tenant=a", signal_specific);
}

test "OTLP headers decode values and reject duplicates or transport headers" {
    var state = State{ .alloc = std.testing.allocator };
    defer state.deinit();
    try parseHeaders(&state, " authorization = Bearer%20token , x-tenant=a=b ");
    try std.testing.expectEqual(@as(usize, 2), state.headers.items.len);
    try std.testing.expectEqualStrings("authorization", state.headers.items[0].name);
    try std.testing.expectEqualStrings("Bearer token", state.headers.items[0].value);
    try std.testing.expectEqualStrings("a=b", state.headers.items[1].value);

    var duplicate = State{ .alloc = std.testing.allocator };
    defer duplicate.deinit();
    try std.testing.expectError(error.InvalidHeaders, parseHeaders(&duplicate, "x-a=1,X-A=2"));

    var transport = State{ .alloc = std.testing.allocator };
    defer transport.deinit();
    try std.testing.expectError(error.InvalidHeaders, parseHeaders(&transport, "content-type=text/plain"));

    var injection = State{ .alloc = std.testing.allocator };
    defer injection.deinit();
    try std.testing.expectError(error.InvalidHeaders, parseHeaders(&injection, "x-a=line%0Ainjected"));
}

test "Retry-After supports delta-seconds and IMF-fixdate" {
    try std.testing.expectEqual(@as(?u64, 12), parseRetryAfter("12"));
    try std.testing.expectEqual(@as(?i64, 1_445_412_480), parseImfFixdate("Wed, 21 Oct 2015 07:28:00 GMT"));
    try std.testing.expectEqual(@as(?u64, 0), parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 951_782_400), parseImfFixdate("Tue, 29 Feb 2000 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), parseImfFixdate("Mon, 29 Feb 2021 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("not-a-date"));
}

test "OTLP retry policy is limited to protocol-defined transient statuses" {
    try std.testing.expect(retryableStatus(.too_many_requests));
    try std.testing.expect(retryableStatus(.bad_gateway));
    try std.testing.expect(retryableStatus(.service_unavailable));
    try std.testing.expect(retryableStatus(.gateway_timeout));
    try std.testing.expect(!retryableStatus(.bad_request));
    try std.testing.expect(!retryableStatus(.internal_server_error));
    const first = retryBackoffDelayNs(0);
    try std.testing.expect(first >= RetryBaseDelayNs / 2 and first <= RetryBaseDelayNs);
    const later = retryBackoffDelayNs(4);
    try std.testing.expect(later >= (RetryBaseDelayNs * 16) / 2 and later <= RetryBaseDelayNs * 16);
}

test "OTLP queue is bounded and drops during shutdown" {
    var state = State{ .alloc = std.testing.allocator };
    defer state.deinit();
    for (0..QueueCapacity) |_| {
        const payload = try std.testing.allocator.dupe(u8, "payload");
        try std.testing.expect(enqueuePayload(&state, payload, .ask));
    }
    const overflow = try std.testing.allocator.dupe(u8, "overflow");
    try std.testing.expect(!enqueuePayload(&state, overflow, .ask));
    try std.testing.expectEqual(@as(usize, QueueCapacity), state.queue_len);

    state.stopping = true;
    const stopped = try std.testing.allocator.dupe(u8, "stopped");
    try std.testing.expect(!enqueuePayload(&state, stopped, .acp));
    try std.testing.expectEqual(@as(usize, QueueCapacity), state.queue_len);
}

test "OTLP exporter is disabled without a configured endpoint" {
    var state = State{ .alloc = std.testing.allocator };
    defer state.deinit();
    try std.testing.expect(!state.enabled());
    state.endpoint = try std.testing.allocator.dupe(u8, "");
    state.configured = true;
    try std.testing.expect(!state.enabled());
}

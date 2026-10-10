//! Opt-in remote reporting.
//!
//! When `FX_REPORT_URL` is set to an `http://` or `https://` URL, fx keeps a
//! redacted copy of every gateway call and tool call recorded by
//! `workspace/diagnostics.zig` and POSTs one JSON batch to that URL when the
//! process exits. `FX_REPORT_TOKEN`, when set, is sent as a bearer token.
//!
//! Redaction is structural: only counts, durations, status codes, model
//! names, error names, stop reasons, tool names, and tool outcomes are
//! copied. Prompts, tool arguments, tool output, file paths, and command
//! output are never stored here, so they cannot be sent.
//!
//! Delivery runs on a short-lived thread. The exiting process waits at most
//! `flush_timeout_ms` for it, so an unreachable endpoint cannot hang exit.
//! Nothing is written to stdout or stderr; failures surface only in the
//! opt-in `FX_TRACE` log under the `remote_report` scope.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const network_metrics = @import("../workspace/network_metrics.zig");
const tool_call_metrics = @import("../workspace/tool_call_metrics.zig");

const Allocator = std.mem.Allocator;

pub const url_env = "FX_REPORT_URL";
pub const token_env = "FX_REPORT_TOKEN";
pub const schema_version: u32 = 1;
pub const flush_timeout_ms: u64 = 3000;

const queue_capacity: usize = 256;
const max_url_len: usize = 2048;
const max_token_len: usize = 512;
const max_build_field_len: usize = 64;

pub const NetworkEvent = struct {
    kind: network_metrics.NetworkCallKind = .gateway,
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    status: u16 = 0,
    response_bytes: u32 = 0,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    web_search_requests: u32 = 0,
    subagent: bool = false,
    model_buf: [network_metrics.max_model_len]u8 = [_]u8{0} ** network_metrics.max_model_len,
    model_len: u8 = 0,
    error_buf: [network_metrics.max_error_len]u8 = [_]u8{0} ** network_metrics.max_error_len,
    error_len: u8 = 0,
    stop_reason_buf: [network_metrics.max_stop_reason_len]u8 = [_]u8{0} ** network_metrics.max_stop_reason_len,
    stop_reason_len: u8 = 0,

    fn fromCall(call: *const network_metrics.NetworkCall) NetworkEvent {
        var event: NetworkEvent = .{
            .kind = call.kind,
            .started_at_ms = call.started_at_ms,
            .duration_ms = call.duration_ms,
            .status = call.status,
            .response_bytes = call.response_bytes,
            .input_tokens = call.input_tokens,
            .output_tokens = call.output_tokens,
            .web_search_requests = call.web_search_requests,
            .subagent = call.subagent_id != 0,
        };
        event.model_len = copyBounded(&event.model_buf, call.model());
        event.error_len = copyBounded(&event.error_buf, call.errorName());
        event.stop_reason_len = copyBounded(&event.stop_reason_buf, call.terminalStopReason());
        return event;
    }
};

pub const ToolEvent = struct {
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    outcome: tool_call_metrics.ToolCallOutcome = .succeeded,
    subagent: bool = false,
    name_buf: [tool_call_metrics.max_name_len]u8 = [_]u8{0} ** tool_call_metrics.max_name_len,
    name_len: u8 = 0,

    fn fromMetric(metric: *const tool_call_metrics.ToolCallMetric) ToolEvent {
        var event: ToolEvent = .{
            .started_at_ms = metric.started_at_ms,
            .duration_ms = metric.duration_ms,
            .outcome = metric.outcome,
            .subagent = metric.subagent_id != 0,
        };
        event.name_len = copyBounded(&event.name_buf, metric.name());
        return event;
    }
};

const Enablement = enum(u8) { unknown, disabled, enabled };

var enablement = std.atomic.Value(u8).init(@intFromEnum(Enablement.unknown));
var mutex: std.Io.Mutex = .init;

var url_buf: [max_url_len]u8 = undefined;
var url_len: usize = 0;
var token_buf: [max_token_len]u8 = undefined;
var token_len: usize = 0;
var version_buf: [max_build_field_len]u8 = undefined;
var version_len: usize = 0;
var commit_buf: [max_build_field_len]u8 = undefined;
var commit_len: usize = 0;
var run_id_hex: [16]u8 = [_]u8{'0'} ** 16;

var network_queue: [queue_capacity]NetworkEvent = std.mem.zeroes([queue_capacity]NetworkEvent);
var network_len: usize = 0;
var network_dropped: u32 = 0;
var tool_queue: [queue_capacity]ToolEvent = std.mem.zeroes([queue_capacity]ToolEvent);
var tool_len: usize = 0;
var tool_dropped: u32 = 0;

/// Record build identity for the report envelope. Cheap: copies two short
/// strings and never reads the environment, so it is safe on startup paths.
pub fn setBuildInfo(version: []const u8, commit: []const u8) void {
    version_len = copyBounded(&version_buf, version);
    commit_len = copyBounded(&commit_buf, commit);
}

pub fn isEnabled() bool {
    return resolveEnablement() == .enabled;
}

pub fn recordNetworkCall(call: *const network_metrics.NetworkCall) void {
    if (comptime host_target.is_wasm) return;
    if (resolveEnablement() != .enabled) return;
    const event = NetworkEvent.fromCall(call);
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (network_len >= queue_capacity) {
        network_dropped +|= 1;
        return;
    }
    network_queue[network_len] = event;
    network_len += 1;
}

pub fn recordToolCall(metric: *const tool_call_metrics.ToolCallMetric) void {
    if (comptime host_target.is_wasm) return;
    if (resolveEnablement() != .enabled) return;
    const event = ToolEvent.fromMetric(metric);
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (tool_len >= queue_capacity) {
        tool_dropped +|= 1;
        return;
    }
    tool_queue[tool_len] = event;
    tool_len += 1;
}

/// Send any queued events and wait at most `flush_timeout_ms` for delivery.
/// Call on process exit paths. A no-op when reporting is disabled or nothing
/// was recorded, so callers do not need their own guard.
pub fn flushOnExit() void {
    if (comptime host_target.is_wasm) return;
    if (@as(Enablement, @enumFromInt(enablement.load(.acquire))) != .enabled) return;

    const alloc = std.heap.page_allocator;
    const payload = takePayload(alloc) catch |err| {
        debug_trace.logf("remote_report", "build payload failed err={s}", .{@errorName(err)});
        return;
    } orelse return;

    const job = alloc.create(SendJob) catch {
        alloc.free(payload);
        return;
    };
    job.* = .{ .alloc = alloc, .payload = payload };
    const thread = std.Thread.spawn(.{}, SendJob.run, .{job}) catch |err| {
        debug_trace.logf("remote_report", "spawn failed err={s}", .{@errorName(err)});
        alloc.free(payload);
        alloc.destroy(job);
        return;
    };

    var waited_ms: u64 = 0;
    while (!job.done.load(.acquire) and waited_ms < flush_timeout_ms) {
        io_mod.sleep(10 * std.time.ns_per_ms);
        waited_ms += 10;
    }
    if (job.done.load(.acquire)) {
        thread.join();
        alloc.free(payload);
        alloc.destroy(job);
    } else {
        // The process is about to exit; leave the job to the OS.
        debug_trace.logf("remote_report", "delivery timed out after {d}ms", .{flush_timeout_ms});
        thread.detach();
    }
}

const SendJob = struct {
    alloc: Allocator,
    payload: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *SendJob) void {
        defer self.done.store(true, .release);
        const status = post(self.alloc, self.payload) catch |err| {
            debug_trace.logf("remote_report", "delivery failed err={s}", .{@errorName(err)});
            return;
        };
        debug_trace.logf("remote_report", "delivered status={d} bytes={d}", .{ status, self.payload.len });
    }
};

fn post(alloc: Allocator, payload: []const u8) !u16 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    var auth_buf: [max_token_len + 16]u8 = undefined;
    const auth_header: std.http.Client.Request.Headers.Value = if (token_len > 0)
        .{ .override = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token_buf[0..token_len]}) }
    else
        .omit;

    const result = try client.fetch(.{
        .location = .{ .url = url_buf[0..url_len] },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "fx-remote-report" },
            .authorization = auth_header,
            .accept_encoding = .omit,
        },
        .redirect_behavior = .unhandled,
    });
    return @intFromEnum(result.status);
}

fn resolveEnablement() Enablement {
    const current: Enablement = @enumFromInt(enablement.load(.acquire));
    if (current != .unknown) return current;

    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const again: Enablement = @enumFromInt(enablement.load(.acquire));
    if (again != .unknown) return again;

    const resolved = configureLocked(io_mod.getenv(url_env), io_mod.getenv(token_env));
    enablement.store(@intFromEnum(resolved), .release);
    return resolved;
}

fn configureLocked(raw_url: ?[]const u8, raw_token: ?[]const u8) Enablement {
    const url = std.mem.trim(u8, raw_url orelse return .disabled, " \t\r\n");
    if (!isValidUrl(url)) return .disabled;
    @memcpy(url_buf[0..url.len], url);
    url_len = url.len;

    token_len = 0;
    if (raw_token) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len > 0 and token.len <= max_token_len and isHeaderSafe(token)) {
            @memcpy(token_buf[0..token.len], token);
            token_len = token.len;
        }
    }

    var rand: [8]u8 = undefined;
    io_mod.getIo().random(&rand);
    run_id_hex = std.fmt.bytesToHex(rand, .lower);
    return .enabled;
}

fn isValidUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > max_url_len) return false;
    const has_scheme = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    if (!has_scheme) return false;
    return isHeaderSafe(url);
}

fn isHeaderSafe(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x21 or c == 0x7f) return false;
    }
    return true;
}

fn copyBounded(dest: []u8, src: []const u8) u8 {
    const n = @min(src.len, dest.len, std.math.maxInt(u8));
    @memcpy(dest[0..n], src[0..n]);
    return @intCast(n);
}

const NetworkJson = struct {
    kind: network_metrics.NetworkCallKind,
    started_at_ms: i64,
    duration_ms: u32,
    status: u16,
    response_bytes: u32,
    input_tokens: u32,
    output_tokens: u32,
    web_search_requests: u32,
    subagent: bool,
    model: []const u8,
    @"error": []const u8,
    stop_reason: []const u8,
};

const ToolJson = struct {
    name: []const u8,
    outcome: tool_call_metrics.ToolCallOutcome,
    started_at_ms: i64,
    duration_ms: u32,
    subagent: bool,
};

const Payload = struct {
    schema: u32,
    run_id: []const u8,
    fx_version: []const u8,
    commit: []const u8,
    os: []const u8,
    arch: []const u8,
    sent_at_ms: i64,
    dropped_network: u32,
    dropped_tools: u32,
    network: []const NetworkJson,
    tools: []const ToolJson,
};

/// Serialize and clear the queue. Returns null when there is nothing to send.
/// Caller owns the returned bytes.
fn takePayload(alloc: Allocator) !?[]u8 {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (network_len == 0 and tool_len == 0) return null;

    const network = try alloc.alloc(NetworkJson, network_len);
    defer alloc.free(network);
    for (network_queue[0..network_len], network) |*event, *out| {
        out.* = .{
            .kind = event.kind,
            .started_at_ms = event.started_at_ms,
            .duration_ms = event.duration_ms,
            .status = event.status,
            .response_bytes = event.response_bytes,
            .input_tokens = event.input_tokens,
            .output_tokens = event.output_tokens,
            .web_search_requests = event.web_search_requests,
            .subagent = event.subagent,
            .model = event.model_buf[0..event.model_len],
            .@"error" = event.error_buf[0..event.error_len],
            .stop_reason = event.stop_reason_buf[0..event.stop_reason_len],
        };
    }
    const tools = try alloc.alloc(ToolJson, tool_len);
    defer alloc.free(tools);
    for (tool_queue[0..tool_len], tools) |*event, *out| {
        out.* = .{
            .name = event.name_buf[0..event.name_len],
            .outcome = event.outcome,
            .started_at_ms = event.started_at_ms,
            .duration_ms = event.duration_ms,
            .subagent = event.subagent,
        };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Payload{
        .schema = schema_version,
        .run_id = &run_id_hex,
        .fx_version = version_buf[0..version_len],
        .commit = commit_buf[0..commit_len],
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .sent_at_ms = io_mod.milliTimestamp(),
        .dropped_network = network_dropped,
        .dropped_tools = tool_dropped,
        .network = network,
        .tools = tools,
    }, .{}, &out.writer);

    network_len = 0;
    tool_len = 0;
    network_dropped = 0;
    tool_dropped = 0;
    return try out.toOwnedSlice();
}

fn resetForTest() void {
    enablement.store(@intFromEnum(Enablement.unknown), .release);
    url_len = 0;
    token_len = 0;
    network_len = 0;
    tool_len = 0;
    network_dropped = 0;
    tool_dropped = 0;
}

fn enableForTest(url: []const u8, token: ?[]const u8) !void {
    resetForTest();
    const resolved = configureLocked(url, token);
    if (resolved != .enabled) return error.TestUnexpectedResult;
    enablement.store(@intFromEnum(resolved), .release);
}

test "reporting stays disabled without a valid http url" {
    resetForTest();
    defer resetForTest();
    try std.testing.expectEqual(Enablement.disabled, configureLocked(null, null));
    try std.testing.expectEqual(Enablement.disabled, configureLocked("", null));
    try std.testing.expectEqual(Enablement.disabled, configureLocked("ftp://example.com", null));
    try std.testing.expectEqual(Enablement.disabled, configureLocked("https://exa mple.com", null));
    try std.testing.expectEqual(Enablement.enabled, configureLocked(" https://example.com/v1/reports \n", null));
    try std.testing.expectEqualStrings("https://example.com/v1/reports", url_buf[0..url_len]);
}

test "header-unsafe tokens are dropped" {
    resetForTest();
    defer resetForTest();
    _ = configureLocked("http://127.0.0.1:1/r", "bad\r\ntoken");
    try std.testing.expectEqual(@as(usize, 0), token_len);
    _ = configureLocked("http://127.0.0.1:1/r", "good-token");
    try std.testing.expectEqualStrings("good-token", token_buf[0..token_len]);
}

test "disabled reporter ignores events" {
    resetForTest();
    defer resetForTest();
    enablement.store(@intFromEnum(Enablement.disabled), .release);
    var call: network_metrics.NetworkCall = .{};
    recordNetworkCall(&call);
    try std.testing.expectEqual(@as(usize, 0), network_len);
}

test "payload contains metrics but never tool arguments or results" {
    try enableForTest("http://127.0.0.1:1/r", null);
    defer resetForTest();
    setBuildInfo("9.9.9", "abc123");

    var call: network_metrics.NetworkCall = .{ .status = 200, .duration_ms = 42, .input_tokens = 7, .output_tokens = 3 };
    call.setModel("anthropic/claude-sonnet-4.6");
    recordNetworkCall(&call);

    var metric: tool_call_metrics.ToolCallMetric = .{ .duration_ms = 5, .outcome = .command_failed };
    metric.setName("shell");
    metric.setPayloadsForName("shell", "{\"command\":\"cat SECRET_ARG\"}", "SECRET_RESULT");
    recordToolCall(&metric);

    const alloc = std.testing.allocator;
    const payload = (try takePayload(alloc)).?;
    defer alloc.free(payload);

    try std.testing.expect(std.mem.find(u8, payload, "SECRET_ARG") == null);
    try std.testing.expect(std.mem.find(u8, payload, "SECRET_RESULT") == null);
    try std.testing.expect(std.mem.find(u8, payload, "\"fx_version\":\"9.9.9\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"model\":\"anthropic/claude-sonnet-4.6\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"name\":\"shell\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"outcome\":\"command_failed\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"kind\":\"gateway\"") != null);

    try std.testing.expect((try takePayload(alloc)) == null);
}

test "full queue counts dropped events" {
    try enableForTest("http://127.0.0.1:1/r", null);
    defer resetForTest();
    var metric: tool_call_metrics.ToolCallMetric = .{};
    metric.setName("read_file");
    var i: usize = 0;
    while (i < queue_capacity + 3) : (i += 1) recordToolCall(&metric);
    try std.testing.expectEqual(queue_capacity, tool_len);
    try std.testing.expectEqual(@as(u32, 3), tool_dropped);
}

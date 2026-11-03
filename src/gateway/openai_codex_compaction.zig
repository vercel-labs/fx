const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const openai_codex = @import("openai_codex.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const configured_request = @import("configured_request.zig");
const responses_protocol = @import("responses_protocol.zig");
const session = @import("../core/session/session.zig");
const session_codec = @import("../core/session/session_codec.zig");
const sse_stream = @import("sse.zig");

const Allocator = std.mem.Allocator;

pub const retained_message_budget: u32 = 64_000;
pub const max_retries: usize = 2;
pub const timeout_ms: i64 = 300_000;
const max_event_bytes: usize = 32 * 1024 * 1024;
const max_state_bytes: usize = types.ProviderReplay.max_bytes;
const max_error_body_bytes: usize = 1024 * 1024;
const max_input_items: usize = 100_000;
const trigger_type = "compaction_trigger";

/// Codex V2 uses the normal Responses endpoint with a compaction trigger. The
/// callback is intentionally transport-only: history selection and checkpoint
/// publication stay in the core compactor.
pub const provider: stream_provider.CompactionProvider = .{
    .supports_v2_streaming = true,
    .compact_fn = compact,
};

fn compact(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.CompactionRequest,
) anyerror!stream_provider.CompactionResult {
    if (!acceptsCredential(request.credential)) return error.CodexSubscriptionCredentialRequired;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.kind == .remote) return compactV1(alloc, request);
    if (request.kind != .v2_streaming) return error.UnsupportedCodexCompactionKind;

    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = request.instructions }};
    const request_data: stream_provider.RequestData = .{
        .session_id = request.session_id,
        .model = compactionModel(request),
        .instructions = if (request.instructions.len > 0) &instructions else &.{},
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = if (request.tools.advertised_functions.len > 0 or request.tools.additional_functions.len > 0) .auto else .none,
        .provider_options = request.provider_options,
        .budget = request.budget,
    };
    const original_payload = try openai_codex.buildRequest(alloc, request_data);
    defer alloc.free(original_payload);
    const payload = try appendTrigger(alloc, original_payload);
    defer alloc.free(payload);
    try request.admission.admit();

    var last_error: ?anyerror = null;
    var attempt: usize = 0;
    while (attempt <= max_retries) : (attempt += 1) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const result = streamOnce(alloc, request, payload) catch |err| {
            last_error = err;
            if (!retryable(err) or attempt == max_retries) return err;
            continue;
        };
        return result;
    }
    return last_error orelse error.CodexCompactionFailed;
}

fn compactV1(alloc: Allocator, request: stream_provider.CompactionRequest) !stream_provider.CompactionResult {
    const metadata = request.provider_options.model_metadata orelse return error.CodexV1CompactionUnavailable;
    const remote = metadata.remote_compaction orelse return error.CodexV1CompactionUnavailable;
    if (!remote.enabled) return error.CodexV1CompactionUnavailable;
    const endpoint = remote.endpoint orelse return error.CodexV1CompactionUnavailable;
    if (std.mem.trim(u8, endpoint, " \t\r\n").len == 0) return error.CodexV1CompactionUnavailable;
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = request.instructions }};
    const request_data: stream_provider.RequestData = .{
        .session_id = request.session_id,
        .model = request.model,
        .instructions = if (request.instructions.len > 0) &instructions else &.{},
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = if (request.tools.advertised_functions.len > 0 or request.tools.additional_functions.len > 0) .auto else .none,
        .provider_options = request.provider_options,
        .budget = request.budget,
    };
    const payload = try buildV1Payload(alloc, request_data, remote.model orelse request.model);
    defer alloc.free(payload);
    const body = try postV1(alloc, request, endpoint, payload);
    defer alloc.free(body);
    return parseV1Result(alloc, body);
}

fn buildV1Payload(alloc: Allocator, request: stream_provider.RequestData, model: []const u8) ![]u8 {
    const payload = try openai_codex.buildRequest(alloc, request);
    defer alloc.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexCompactionRequest;
    const object = &parsed.value.object;
    try object.put(alloc, "model", .{ .string = model });
    for ([_][]const u8{
        "stream",
        "store",
        "max_output_tokens",
        "text",
        "tool_choice",
        "parallel_tool_calls",
        "include",
        "reasoning",
        "prompt_cache_retention",
        "cache_control",
        "provider",
        "providerOptions",
    }) |key| _ = object.*.swapRemove(key);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn postV1(
    alloc: Allocator,
    request: stream_provider.CompactionRequest,
    endpoint: []const u8,
    payload: []const u8,
) ![]u8 {
    const request_endpoint = endpoint;
    var auth = try openai_codex.requestAuthHeaders(alloc, request.credential);
    defer auth.deinit(alloc);
    const metadata = request.provider_options.model_metadata;
    var metadata_headers: configured_request.Headers = .{};
    if (metadata) |value| {
        if (value.headers.len > 0) {
            const selected = try alloc.alloc(configured_provider.Header, value.headers.len);
            defer alloc.free(selected);
            @memcpy(selected, value.headers);
            metadata_headers = try configured_request.resolveHeaderValues(alloc, selected);
        }
    }
    defer metadata_headers.deinit(alloc);
    var default_headers_buf: [openai_codex.max_extra_headers]std.http.Header = undefined;
    const default_headers = openai_codex.extraHeaders(&default_headers_buf, auth.account_id, request.session_id);
    for (default_headers) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) header.value = "application/json";
    }
    const extra_headers = try configured_request.mergeHeaders(alloc, default_headers, metadata_headers.items);
    defer alloc.free(extra_headers);
    const deadline = request.budget orelse stream_provider.BuildBudget{};
    const end = deadline.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const uri = try std.Uri.parse(request_endpoint);
    var operation = gateway_client.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = auth.authorization,
        .extra_headers = extra_headers,
    };
    try request.admission.admit();
    try requestBudgetCheck(request);
    var opened = try gateway_client.openBoundedPost(alloc, request.cancel_flag, end, &operation);
    var http_request = opened.take();
    defer http_request.deinit();
    var watch: gateway_client.ConnectionWatch = .init(.{ .patient = true, .stall_timeout_ms = gateway_client.ConnectionWatch.bodyStallTimeoutMs(end) });
    defer watch.stop();
    if (http_request.connection) |connection| try watch.start(request.cancel_flag, end, connection.stream_writer.stream);
    if (watch.armHead()) |err| return err;
    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    var response = http_request.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    var transfer: [256 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        const detail = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ProviderCompactionFailed,
            else => return err,
        };
        alloc.free(detail);
        return error.ProviderCompactionFailed;
    }
    const body = reader.allocRemaining(alloc, .limited(max_state_bytes)) catch |err| return err;
    if (watch.finish()) |err| {
        alloc.free(body);
        return err;
    }
    return body;
}

fn parseV1Result(alloc: Allocator, body: []const u8) !stream_provider.CompactionResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexCompactionResponse;
    const object = parsed.value.object;
    const output = object.get("output") orelse return error.CodexV1CompactionMissingItem;
    if (output != .array) return error.CodexV1CompactionMissingItem;
    var item: ?std.json.Value = null;
    for (output.array.items) |candidate| {
        if (candidate != .object) continue;
        const kind = candidate.object.get("type") orelse continue;
        if (kind != .string or (!std.mem.eql(u8, kind.string, "compaction") and !std.mem.eql(u8, kind.string, "compaction_summary"))) continue;
        item = candidate;
        break;
    }
    const selected = item orelse return error.CodexV1CompactionMissingItem;
    var state_writer: std.Io.Writer.Allocating = .init(alloc);
    defer state_writer.deinit();
    try std.json.Stringify.value(output, .{}, &state_writer.writer);
    const state = try state_writer.toOwnedSlice();
    errdefer alloc.free(state);
    var summary: ?[]u8 = null;
    if (object.get("summary")) |value| {
        if (value == .string and std.mem.trim(u8, value.string, " \t\r\n").len > 0) summary = try alloc.dupe(u8, value.string);
    }
    if (summary == null) for ([_][]const u8{ "summary", "text" }) |key| if (selected.object.get(key)) |value| if (value == .string and std.mem.trim(u8, value.string, " \t\r\n").len > 0) {
        summary = try alloc.dupe(u8, value.string);
        break;
    };
    if (summary == null) summary = try alloc.dupe(u8, "Remote compaction");
    errdefer if (summary) |value| alloc.free(value);
    const usage = parseUsage(object);
    return .{ .summary = summary, .provider_state_json = state, .used_tokens = usage.input_tokens, .usage = usage, .ownership = .owned };
}

fn acceptsCredential(lease: stream_provider.CredentialLease) bool {
    const source = lease.credentialSource() orelse return false;
    return source == .chatgpt_subscription or source == .host_managed;
}

fn appendTrigger(alloc: Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexCompactionRequest;
    const input = parsed.value.object.getPtr("input") orelse return error.InvalidCodexCompactionRequest;
    if (input.* != .array or input.array.items.len >= max_input_items) return error.InvalidCodexCompactionRequest;
    try input.array.append(.{ .object = blk: {
        var object: std.json.ObjectMap = .empty;
        try object.put(alloc, "type", .{ .string = trigger_type });
        break :blk object;
    } });
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn compactionModel(request: stream_provider.CompactionRequest) []const u8 {
    const metadata = request.provider_options.model_metadata orelse return request.model;
    const remote = metadata.remote_compaction orelse return request.model;
    const model = remote.model orelse return request.model;
    return if (std.mem.trim(u8, model, " \t\r\n").len == 0) request.model else model;
}

fn compactionEndpoint(alloc: Allocator, request: stream_provider.CompactionRequest) ![]u8 {
    if (request.provider_options.model_metadata) |metadata| if (metadata.remote_compaction) |remote| {
        for ([_]?[]const u8{ remote.v2_endpoint, remote.streaming_endpoint }) |configured| if (configured) |endpoint| {
            const trimmed = std.mem.trim(u8, endpoint, " \t\r\n");
            if (trimmed.len != 0) return alloc.dupe(u8, trimmed);
        };
        if (metadata.base_url) |base| {
            const trimmed = std.mem.trimEnd(u8, base, "/");
            if (trimmed.len != 0) {
                if (std.mem.endsWith(u8, trimmed, "/codex/responses") or std.mem.endsWith(u8, trimmed, "/responses")) return alloc.dupe(u8, trimmed);
                if (std.mem.endsWith(u8, trimmed, "/codex")) return alloc.print("{s}/responses", .{trimmed});
                return alloc.print("{s}/codex/responses", .{trimmed});
            }
        }
    };
    return alloc.dupe(u8, try openai_codex.responsesEndpoint());
}

fn streamOnce(
    alloc: Allocator,
    request: stream_provider.CompactionRequest,
    payload: []const u8,
) !stream_provider.CompactionResult {
    const request_endpoint = try compactionEndpoint(alloc, request);
    defer alloc.free(request_endpoint);
    var auth = try openai_codex.requestAuthHeaders(alloc, request.credential);
    defer auth.deinit(alloc);
    var metadata_headers: configured_request.Headers = .{};
    if (request.provider_options.model_metadata) |metadata| if (metadata.headers.len > 0) {
        const selected = try alloc.alloc(configured_provider.Header, metadata.headers.len);
        defer alloc.free(selected);
        @memcpy(selected, metadata.headers);
        metadata_headers = try configured_request.resolveHeaderValues(alloc, selected);
    };
    defer metadata_headers.deinit(alloc);
    var extra_headers_buf: [openai_codex.max_extra_headers + 1]std.http.Header = undefined;
    var default_headers = openai_codex.extraHeaders(extra_headers_buf[0..openai_codex.max_extra_headers], auth.account_id, request.session_id);
    extra_headers_buf[default_headers.len] = .{ .name = "x-codex-beta-features", .value = "remote_compaction_v2" };
    default_headers = extra_headers_buf[0 .. default_headers.len + 1];
    const extra_headers = try configured_request.mergeHeaders(alloc, default_headers, metadata_headers.items);
    defer alloc.free(extra_headers);

    const deadline = request.budget orelse stream_provider.BuildBudget{};
    const end = deadline.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const uri = try std.Uri.parse(request_endpoint);
    var operation = gateway_client.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = auth.authorization,
        .extra_headers = extra_headers,
    };
    try requestBudgetCheck(request);
    var opened = try gateway_client.openBoundedPost(alloc, request.cancel_flag, end, &operation);
    var http_request = opened.take();
    defer http_request.deinit();
    var watch: gateway_client.ConnectionWatch = .init(.{ .patient = true, .stall_timeout_ms = gateway_client.ConnectionWatch.bodyStallTimeoutMs(end) });
    defer watch.stop();
    if (http_request.connection) |connection| try watch.start(request.cancel_flag, end, connection.stream_writer.stream);
    if (watch.armHead()) |err| return err;
    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    var response = http_request.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const body = response.reader(&transfer).allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI Codex compaction error response exceeded the local limit"),
            else => return err,
        };
        alloc.free(body);
        return error.ProviderCompactionFailed;
    }
    const input_json = try extractInput(alloc, payload);
    defer alloc.free(input_json);
    var transfer: [256 * 1024]u8 = undefined;
    const result = parseStream(alloc, request, input_json, response.reader(&transfer), watch.progress());
    if (result) |_| {
        if (watch.finish()) |err| return err;
    } else |err| return watch.failure(err);
    return result;
}

fn requestBudgetCheck(request: stream_provider.CompactionRequest) !void {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.budget) |budget| if (budget.deadline) |deadline| {
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, deadline)) return error.Timeout;
    };
}

fn extractInput(alloc: Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexCompactionRequest;
    const input = parsed.value.object.get("input") orelse return error.InvalidCodexCompactionRequest;
    if (input != .array) return error.InvalidCodexCompactionRequest;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(input, .{}, &out.writer);
    return out.toOwnedSlice();
}

const Collection = struct {
    alloc: Allocator,
    compaction_item: ?[]u8 = null,
    saw_completed: bool = false,
    usage: types.Usage = .{},

    fn deinit(self: *Collection) void {
        if (self.compaction_item) |value| self.alloc.free(value);
        self.* = undefined;
    }
};

fn parseStream(
    alloc: Allocator,
    request: stream_provider.CompactionRequest,
    input_json: []const u8,
    reader: *std.Io.Reader,
    progress: ?sse_stream.Progress,
) !stream_provider.CompactionResult {
    var collection = Collection{ .alloc = alloc };
    defer collection.deinit();
    var sse: sse_stream.Reader = .{ .max_event_bytes = max_event_bytes, .progress = progress };
    defer sse.deinit(alloc);
    while (sse.next(alloc, reader, request.cancel_flag) catch |err| return err) |json_text| {
        if (std.mem.eql(u8, json_text, "[DONE]")) break;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidCodexCompactionEvent;
        defer parsed.deinit();
        try consumeEvent(alloc, request, &collection, parsed.value);
        if (collection.saw_completed) break;
    }
    if (!collection.saw_completed) return error.CodexCompactionStreamIncomplete;
    const item = collection.compaction_item orelse return error.CodexCompactionMissingItem;
    const summary = try compactionSummary(alloc, item);
    errdefer alloc.free(summary);
    const replacement = try buildReplacementHistory(alloc, input_json, item, request.retained_message_budget orelse retained_message_budget);
    errdefer alloc.free(replacement);
    return .{ .summary = summary, .provider_state_json = replacement, .used_tokens = collection.usage.input_tokens, .usage = collection.usage, .ownership = .owned };
}

fn consumeEvent(alloc: Allocator, request: stream_provider.CompactionRequest, collection: *Collection, value: std.json.Value) !void {
    if (value != .object) return;
    const event_type = stringField(value.object, "type") orelse return;
    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item = value.object.get("item") orelse return;
        if (item != .object or !std.mem.eql(u8, stringField(item.object, "type") orelse "", "compaction")) return;
        if (collection.compaction_item != null) return error.CodexCompactionMultipleItems;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(item, .{}, &out.writer);
        collection.compaction_item = try out.toOwnedSlice();
        return;
    }
    if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.done")) {
        const response = value.object.get("response") orelse return;
        if (response != .object) return;
        collection.saw_completed = true;
        collection.usage = parseUsage(response.object);
        return;
    }
    if (std.mem.eql(u8, event_type, "response.failed") or std.mem.eql(u8, event_type, "error")) return error.CodexCompactionProviderFailed;
    _ = request;
}

fn parseUsage(response: std.json.ObjectMap) types.Usage {
    const usage = response.get("usage") orelse return .{};
    if (usage != .object) return .{};
    const input_details = usage.object.get("input_tokens_details");
    const output_details = usage.object.get("output_tokens_details");
    return .{
        .input_tokens = unsignedField(usage.object, "input_tokens"),
        .output_tokens = unsignedField(usage.object, "output_tokens"),
        .cache_read_tokens = nestedUnsigned(input_details, "cached_tokens"),
        .reasoning_tokens = nestedUnsigned(output_details, "reasoning_tokens"),
    };
}

fn nestedUnsigned(value: ?std.json.Value, key: []const u8) ?u64 {
    const item = value orelse return null;
    if (item != .object) return null;
    return unsignedField(item.object, key);
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn compactionSummary(alloc: Allocator, item_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, item_json, .{});
    defer parsed.deinit();
    if (parsed.value == .object) if (stringField(parsed.value.object, "summary")) |summary| if (summary.len > 0) return alloc.dupe(u8, summary);
    return alloc.dupe(u8, "Remote compaction");
}

fn buildReplacementHistory(alloc: Allocator, input_json: []const u8, item_json: []const u8, budget: u32) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, input_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCodexCompactionHistory;
    var kept: std.ArrayList(std.json.Value) = .empty;
    var tokens: usize = 0;
    var index = parsed.value.array.items.len;
    while (index > 0) {
        index -= 1;
        const value = parsed.value.array.items[index];
        if (value != .object) continue;
        const role = stringField(value.object, "role") orelse continue;
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "system") and !std.mem.eql(u8, role, "developer")) continue;
        const estimate = @max(1, try jsonTokenEstimate(value));
        if (tokens +| estimate > budget) break;
        try kept.append(alloc, value);
        tokens += estimate;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    var wrote = false;
    var reverse = kept.items.len;
    while (reverse > 0) {
        reverse -= 1;
        if (wrote) try out.writer.writeByte(',');
        try std.json.Stringify.value(kept.items[reverse], .{}, &out.writer);
        wrote = true;
    }
    if (wrote) try out.writer.writeByte(',');
    try out.writer.writeAll(item_json);
    try out.writer.writeByte(']');
    if (out.written().len > max_state_bytes) return error.CodexCompactionStateTooLarge;
    return out.toOwnedSlice();
}

fn jsonTokenEstimate(value: std.json.Value) !usize {
    var scratch: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer scratch.deinit();
    try std.json.Stringify.value(value, .{}, &scratch.writer);
    return scratch.written().len / 4 + 1;
}

fn retryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout,
        error.StreamStalled,
        error.CodexCompactionStreamIncomplete,
        error.InvalidCodexCompactionEvent,
        error.CodexCompactionProviderFailed,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        => true,
        else => false,
    };
}

const V2CompactionHttpFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    request_headers: [16 * 1024]u8 = undefined,
    request_headers_len: std.atomic.Value(usize) = .init(0),
    request_body: [128 * 1024]u8 = undefined,
    request_body_len: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,

    fn init() !@This() {
        var fixture: @This() = .{ .server = undefined };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        self.stopping.store(true, .seq_cst);
        const zio = self.io();
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            var wake_io: std.Io.Threaded = .init_single_thread;
            const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
            if (address.connect(wake_io.io(), .{ .mode = .stream })) |wake| wake.close(wake_io.io()) else |_| {}
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
    }

    fn run(self: *@This()) void {
        const zio = self.io();
        var socket = self.server.accept(zio) catch |err| {
            if (!self.stopping.load(.seq_cst)) self.failure = err;
            return;
        };
        defer socket.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        var socket_buffer: [8192]u8 = undefined;
        var reader = socket.reader(zio, &socket_buffer);
        var header: [16 * 1024]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header.len) {
            header[header_len] = reader.interface.takeByte() catch |err| {
                self.failure = err;
                return;
            };
            header_len += 1;
            if (std.mem.endsWith(u8, header[0..header_len], "\r\n\r\n")) break;
        } else {
            self.failure = error.TestRequestTooLarge;
            return;
        }
        @memcpy(self.request_headers[0..header_len], header[0..header_len]);
        self.request_headers_len.store(header_len, .seq_cst);
        const content_length = contentLength(header[0 .. header_len - 4]) orelse {
            self.failure = error.MissingContentLength;
            return;
        };
        if (content_length > self.request_body.len) {
            self.failure = error.TestRequestTooLarge;
            return;
        }
        reader.interface.readSliceAll(self.request_body[0..content_length]) catch |err| {
            self.failure = err;
            return;
        };
        self.request_body_len.store(content_length, .seq_cst);
        const body =
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"compaction\",\"summary\":\"V2 retained summary\"}}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":654,\"output_tokens\":9}}}\n\n";
        var output: [2048]u8 = undefined;
        const response = std.mem.print(&output, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch |err| {
            self.failure = err;
            return;
        };
        var write_buffer: [4096]u8 = undefined;
        var writer = socket.writer(zio, &write_buffer);
        writer.interface.writeAll(response) catch |err| {
            self.failure = err;
            return;
        };
        writer.interface.flush() catch |err| {
            self.failure = err;
        };
    }

    fn contentLength(headers: []const u8) ?usize {
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len < prefix.len or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) continue;
            return std.fmt.parseUnsigned(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10) catch null;
        }
        return null;
    }
};

test "Codex V2 compaction sends metadata override and persists replay" {
    const alloc = std.testing.allocator;
    var fixture = try V2CompactionHttpFixture.init();
    defer fixture.deinit();
    try fixture.start();
    const endpoint = try alloc.print("http://127.0.0.1:{d}/v2/compact", .{fixture.port()});
    defer alloc.free(endpoint);
    const base_url = try alloc.print("http://127.0.0.1:{d}/v1", .{fixture.port()});
    defer alloc.free(base_url);
    const headers = [_]configured_provider.Header{.{ .name = "X-V2-Fixture", .value = "present" }};
    const remote = configured_provider.RemoteCompaction{
        .enabled = true,
        .model = "summary-model",
        .v2_streaming_enabled = true,
        .v2_endpoint = endpoint,
        .streaming_endpoint = "http://127.0.0.1:1/unused",
    };
    const metadata = configured_provider.ModelMetadata{
        .id = "source-model",
        .base_url = base_url,
        .headers = &headers,
        .remote_compaction = remote,
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "retain this user input" }};
    var result = try @import("../core/agent/runtime/gateway_step.zig").compactModelContext(provider, alloc, .{
        .credential = .host_managed,
        .model = "source-model",
        .messages = &messages,
        .provider_options = .{ .model_metadata = &metadata },
        .kind = .v2_streaming,
        .retained_message_budget = retained_message_budget,
        .cancel_flag = &cancelled,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("V2 retained summary", result.summary.?);
    try std.testing.expectEqual(@as(?u64, 654), result.used_tokens);
    const body = fixture.request_body[0..fixture.request_body_len.load(.seq_cst)];
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"summary-model\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "compaction_trigger") != null);
    const request_headers = fixture.request_headers[0..fixture.request_headers_len.load(.seq_cst)];
    try std.testing.expect(std.mem.find(u8, request_headers, "x-v2-fixture: present") != null or std.mem.find(u8, request_headers, "X-V2-Fixture: present") != null);
    try std.testing.expect(fixture.failure == null);

    const replay = result.provider_state_json orelse return error.TestExpectedReplay;
    const replay_message = [_]types.ChatMessage{.{ .role = .assistant, .provider_replay = .{
        .source = .{ .provider = .codex, .model = "summary-model" },
        .parts_json = replay,
    } }};
    var replay_wire: std.Io.Writer.Allocating = .init(alloc);
    defer replay_wire.deinit();
    try responses_protocol.writeInputWith(&replay_wire.writer, alloc, &replay_message, null, .{
        .tool_calls = 8,
        .tool_identity_bytes = 128,
        .tool_arguments_bytes = 4096,
        .provider_state_bytes = types.ProviderReplay.max_bytes,
    }, .{}, .{});
    try std.testing.expect(std.mem.find(u8, replay_wire.written(), "compaction") != null);
    try std.testing.expect(std.mem.find(u8, replay_wire.written(), "retain this user input") != null);

    const turn = types.HistoryTurn{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, result.summary.?),
        .removed_turn_count = 1,
        .compaction_count = 1,
        .provider_replay = .{ .source = .{ .provider = .codex, .model = "summary-model" }, .parts_json = replay },
    } };
    defer alloc.free(turn.compacted_summary.summary);
    var persisted: std.Io.Writer.Allocating = .init(alloc);
    defer persisted.deinit();
    try session_codec.writeHistoryTurn(&persisted.writer, turn);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, persisted.written(), .{});
    defer parsed.deinit();
    const decoded = try session_codec.parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, decoded);
    try std.testing.expectEqualStrings(replay, decoded.compacted_summary.provider_replay.?.parts_json);
}

test "Codex V2 compaction payload appends trigger item" {
    const body = "{\"model\":\"gpt-5.6\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[]}] ,\"stream\":true}";
    const result = try appendTrigger(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "compaction_trigger") != null);
}

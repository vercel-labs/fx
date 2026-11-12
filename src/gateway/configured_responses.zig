//! The OpenAI Responses protocol for a custom model connection whose
//! settings say `"protocol": "openai-responses"`
//! (`src/core/config/configured_provider.zig`): the request body and the
//! streamed reply. The wire format is `responses_protocol.zig`'s, which the
//! ChatGPT and Grok adapters share; `configured_transport.zig` sends it.
const std = @import("std");
const responses_protocol = @import("responses_protocol.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const request_fragment = @import("../core/config/request_fragment.zig");
const model_provider = @import("../core/config/model_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    tool_choice_mode: configured_provider.ToolChoiceMode = .omit,
    /// The connection's bound identity, borrowed during serialization. Replay
    /// recorded for another endpoint is left out.
    provider: *const model_provider.ProviderId,
    /// The model's own request fields, from the connection's settings.
    request_fields: request_fragment.Fragment = .{},
    /// The fields of the effort level the request carries; null when the
    /// model does not declare that level, and then a request that names one
    /// is refused (`tests/tla/configured_provider/ConfiguredRequest.tla`
    /// EffortOnlyWhenDeclared).
    effort_fields: ?request_fragment.Fragment = null,
    /// Ask for the reply's reasoning back encrypted. Only for a model whose
    /// settings declare effort levels: OpenAI refuses the request for a model
    /// that does not reason, and settings cannot take the field out.
    include_reasoning: bool = false,
};

const max_event_bytes: usize = 1024 * 1024;
const max_stream_bytes: usize = 64 * 1024 * 1024;
const max_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;

const stream_limits = responses_protocol.StreamLimits{
    .aggregate_bytes = max_stream_bytes,
    .count_json_bytes = false,
    .events = max_events,
    .tool_calls = max_tool_calls,
    .tool_identity_bytes = max_tool_identity_bytes,
    .tool_arguments_bytes = max_tool_arguments_bytes,
    .provider_state_bytes = max_provider_state_bytes,
};

/// The request body. Caller owns it. The settings' fields come last, so
/// every field above them is fx's own and a fragment cannot name one.
pub fn build_request(alloc: Allocator, request: stream_provider.RequestData, options: Options) ![]u8 {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const provider_options = request.provider_options;
    if (provider_options.reasoning != null and options.effort_fields == null) return error.UnsupportedProviderOption;
    if (provider_options.fast or provider_options.prompt_caching or provider_options.provider_order.len != 0) return error.UnsupportedProviderOption;
    if (request.max_output_tokens == 0) return error.InvalidOutputLimit;
    if (request.response_format) |format| if (format.schema != .object) return error.UnsupportedResponseFormat;
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = options.provider.*, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    if (projected != null) debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |instruction| {
        const text = instruction.content.?;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }

    var tools = try selectTools(alloc, request);
    defer tools.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    // fx keeps the conversation itself, so the server stores nothing.
    try writer.writeAll(",\"stream\":true,\"store\":false");
    if (instructions.written().len > 0) {
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(instructions.written(), .{}, writer);
    }
    try writer.writeAll(",\"input\":[");
    // Replay and image scratch must not grow the body's own buffer, as the
    // ChatGPT and Grok adapters keep it apart.
    try responses_protocol.writeInput(writer, std.heap.c_allocator, projected orelse request.messages, request.verified_images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }, budget);
    try writer.writeByte(']');
    const tool_count = if (request.tool_choice == .none) 0 else try responses_protocol.writeTools(writer, alloc, tools.selection);
    if (tool_count > 0) {
        if (options.tool_choice_mode == .send) {
            const choice: types.ToolChoice = if (request.vision_mode == .required) .required else request.tool_choice;
            try writer.writeAll(",\"tool_choice\":");
            try std.json.Stringify.value(@tagName(choice), .{}, writer);
        }
        if (provider_options.parallel_tool_calls) |parallel| {
            try writer.writeAll(",\"parallel_tool_calls\":");
            try std.json.Stringify.value(parallel, .{}, writer);
        }
    }
    // With nothing stored, a reasoning model's reasoning travels back
    // encrypted, so a later turn can send it again.
    if (options.include_reasoning) try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    if (request.response_format) |format| {
        try writer.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        if (format.description.len != 0) {
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(format.description, .{}, writer);
        }
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    const effort_fields = if (provider_options.reasoning != null) options.effort_fields orelse request_fragment.Fragment{} else request_fragment.Fragment{};
    try request_fragment.write(writer, options.request_fields, effort_fields);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

/// The request's tools, with the image fallback's `vision` tool added when
/// the request may use it, and alone when it must, as the gateway sends it.
const SelectedTools = struct {
    selection: stream_provider.ToolSelection,
    /// Owned when the vision tool was added to the request's own list.
    added: ?[]model_tool_schema.FunctionSchema = null,

    fn deinit(self: *SelectedTools, alloc: Allocator) void {
        if (self.added) |functions| alloc.free(functions);
        self.* = undefined;
    }
};

fn selectTools(alloc: Allocator, request: stream_provider.RequestData) !SelectedTools {
    const tools = request.tools;
    if (request.vision_mode == .unavailable) return .{ .selection = tools };
    const vision = tools.registry.lookup("vision") orelse return error.InvalidToolSelection;
    if (request.vision_mode == .required) {
        const only: []const model_tool_schema.FunctionSchema = (&vision.model_schema)[0..1];
        return .{ .selection = .{ .registry = tools.registry, .additional_functions = only } };
    }
    for (tools.advertised_names) |name| if (std.mem.eql(u8, name, "vision")) return .{ .selection = tools };
    for (tools.additional_functions) |function| if (std.mem.eql(u8, function.name, "vision")) return .{ .selection = tools };
    const functions = try std.mem.concat(alloc, model_tool_schema.FunctionSchema, &.{ tools.additional_functions, &.{vision.model_schema} });
    var selection = tools;
    selection.additional_functions = functions;
    return .{ .selection = selection, .added = functions };
}

/// Reads a successful streamed reply. The result owns the completion.
pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: stream_provider.ModelRequest, progress: ?sse.Progress) !stream_provider.Result {
    var events = request.events;
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var lines: sse.Reader = .{ .max_event_bytes = max_event_bytes, .max_total_bytes = max_stream_bytes, .progress = progress };
    defer lines.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = &events,
        .on_content = stream_provider.EventSink.onContentChunk,
        .on_tool_start = stream_provider.EventSink.onToolStart,
        .on_reasoning = stream_provider.EventSink.onReasoningChunk,
        .on_tool_input = stream_provider.EventSink.onToolInputChunk,
    };
    while (lines.next(alloc, reader, request.cancel_flag) catch |err| return named(err)) |json_text| {
        // Some servers end with the Chat Completions sentinel as well.
        if (std.mem.eql(u8, json_text, "[DONE]")) break;
        if (reducer.applyJson(alloc, json_text, callbacks, request.cancel_flag, request.content_capture_limit, stream_limits) catch |err| return named(err)) break;
    }
    const completion = reducer.finish(alloc, request.cancel_flag, stream_limits) catch |err| return named(err);
    return .{ .completed = .{ .completion = completion, .ownership = .owned } };
}

/// The shared reducer's errors under names that say which protocol failed;
/// request recovery resends an unreadable reply by these names
/// (`src/gateway/client.zig` isUnreadableReply).
fn named(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidResponsesEvent,
        error.MalformedEvent => error.MalformedResponsesEvent,
        error.EventTooLarge => error.ResponsesEventTooLarge,
        error.StreamIncomplete => error.ResponsesStreamIncomplete,
        else => err,
    };
}

fn test_provider() model_provider.ProviderId {
    var identity = model_provider.parse("local").?;
    identity.configured.binding = @splat(7);
    return identity;
}

fn test_request() stream_provider.RequestData {
    return .{
        .model = "qwen2.5:1.5b",
        .instructions = &.{ .{ .role = .system, .content = "first" }, .{ .role = .system, .content = "second" } },
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 512,
    };
}

test "configured responses body has fx's fields, then the model's, with a declared level's over them" {
    const alloc = std.testing.allocator;
    const provider = test_provider();
    var registry = try configured_provider.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-responses","base_url":"http://127.0.0.1:1/v1","auth":{"type":"none"},
        \\"model_metadata":{"qwen2.5:1.5b":{"request":{"temperature":0.2,"top_p":0.9},
        \\"reasoning_efforts":{"high":{"reasoning":{"effort":"high"},"temperature":0.7}}}}}}
    );
    defer registry.deinit(alloc);
    const metadata = registry.get("local").?.metadata_for("qwen2.5:1.5b").?;
    var request = test_request();
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    const body = try build_request(alloc, request, .{
        .provider = &provider,
        .request_fields = metadata.request.?,
        .effort_fields = metadata.effort("high").?.fields,
    });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const fields = parsed.value.object;
    try std.testing.expectEqualStrings("qwen2.5:1.5b", fields.get("model").?.string);
    try std.testing.expect(fields.get("stream").?.bool);
    try std.testing.expect(!fields.get("store").?.bool);
    try std.testing.expectEqualStrings("first\n\nsecond", fields.get("instructions").?.string);
    try std.testing.expectEqual(@as(i64, 512), fields.get("max_output_tokens").?.integer);
    try std.testing.expectEqualStrings("high", fields.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqual(@as(f64, 0.7), fields.get("temperature").?.float);
    try std.testing.expectEqual(@as(f64, 0.9), fields.get("top_p").?.float);
    try std.testing.expect(fields.get("tools") == null);
    const input = fields.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), input.len);

    // No level chosen: the level's fields stay out, the model's stay in.
    request.provider_options = .{};
    const plain = try build_request(alloc, request, .{ .provider = &provider, .request_fields = metadata.request.?, .effort_fields = metadata.effort("high").?.fields });
    defer alloc.free(plain);
    var plain_parsed = try std.json.parseFromSlice(std.json.Value, alloc, plain, .{});
    defer plain_parsed.deinit();
    try std.testing.expect(plain_parsed.value.object.get("reasoning") == null);
    try std.testing.expectEqual(@as(f64, 0.2), plain_parsed.value.object.get("temperature").?.float);
}

test "configured responses asks for encrypted reasoning only for a model that reasons" {
    const alloc = std.testing.allocator;
    const provider = test_provider();
    for ([_]bool{ false, true }) |reasons| {
        const body = try build_request(alloc, test_request(), .{ .provider = &provider, .include_reasoning = reasons });
        defer alloc.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();
        const include = parsed.value.object.get("include");
        try std.testing.expectEqual(reasons, include != null);
        if (include) |list| try std.testing.expectEqualStrings("reasoning.encrypted_content", list.array.items[0].string);
    }
}

test "configured responses refuses what the connection cannot send" {
    const alloc = std.testing.allocator;
    const provider = test_provider();
    var request = test_request();
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{ .provider = &provider }));
    request = test_request();
    request.provider_options = .{ .fast = true };
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{ .provider = &provider }));
    request = test_request();
    request.max_output_tokens = 0;
    try std.testing.expectError(error.InvalidOutputLimit, build_request(alloc, request, .{ .provider = &provider }));
    request = test_request();
    request.response_format = .{ .name = "answer", .description = "", .schema = .null };
    try std.testing.expectError(error.UnsupportedResponseFormat, build_request(alloc, request, .{ .provider = &provider }));
    request = test_request();
    request.vision_mode = .optional;
    try std.testing.expectError(error.InvalidToolSelection, build_request(alloc, request, .{ .provider = &provider }));
}

test "configured responses sends a structured reply's schema" {
    const alloc = std.testing.allocator;
    const provider = test_provider();
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\"}", .{});
    defer schema.deinit();
    var request = test_request();
    request.response_format = .{ .name = "vision_result", .description = "", .schema = schema.value };
    const body = try build_request(alloc, request, .{ .provider = &provider });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const format = parsed.value.object.get("text").?.object.get("format").?.object;
    try std.testing.expectEqualStrings("json_schema", format.get("type").?.string);
    try std.testing.expectEqualStrings("vision_result", format.get("name").?.string);
    try std.testing.expect(format.get("description") == null);
    try std.testing.expectEqualStrings("object", format.get("schema").?.object.get("type").?.string);
}

const RecordedEvents = struct {
    content: std.ArrayList(u8) = .empty,

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *RecordedEvents = @ptrCast(@alignCast(raw));
        switch (event) {
            .content_delta => |text| self.content.appendSlice(std.testing.allocator, text) catch {},
            else => {},
        }
    }
};

fn test_consume(alloc: Allocator, bytes: []const u8, recorded: *RecordedEvents) !stream_provider.Result {
    var reader = std.Io.Reader.fixed(bytes);
    var cancel = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    return consume(alloc, &reader, .{
        .credential = .{ .direct = .{ .source = .configured } },
        .model = "qwen2.5:0.5b",
        .retry_count = 0,
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = recorded, .emit_fn = RecordedEvents.emit },
        .cancel_flag = &cancel,
    }, null);
}

test "configured responses reads a real server's text reply with its cached and reasoning counts" {
    const alloc = std.testing.allocator;
    // Abridged from tests/e2e/fixtures/custom-endpoint-captures/responses-text.sse:
    // the events and the usage block as Ollama sent them.
    const captured =
        "event: response.created\ndata: {\"response\":{\"id\":\"resp_1\",\"model\":\"qwen2.5:0.5b\",\"object\":\"response\",\"output\":[],\"status\":\"in_progress\"},\"sequence_number\":0,\"type\":\"response.created\"}\n\n" ++
        "event: response.output_item.added\ndata: {\"item\":{\"content\":[],\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"type\":\"message\"},\"output_index\":0,\"sequence_number\":1,\"type\":\"response.output_item.added\"}\n\n" ++
        "event: response.output_text.delta\ndata: {\"content_index\":0,\"delta\":\"Hello\",\"item_id\":\"msg_1\",\"output_index\":0,\"sequence_number\":2,\"type\":\"response.output_text.delta\"}\n\n" ++
        "event: response.output_text.done\ndata: {\"content_index\":0,\"item_id\":\"msg_1\",\"output_index\":0,\"sequence_number\":3,\"text\":\"Hello\",\"type\":\"response.output_text.done\"}\n\n" ++
        "event: response.output_item.done\ndata: {\"item\":{\"content\":[{\"annotations\":[],\"text\":\"Hello\",\"type\":\"output_text\"}],\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"type\":\"message\"},\"output_index\":0,\"sequence_number\":4,\"type\":\"response.output_item.done\"}\n\n" ++
        "event: response.completed\ndata: {\"response\":{\"id\":\"resp_1\",\"model\":\"qwen2.5:0.5b\",\"object\":\"response\",\"output\":[{\"content\":[{\"annotations\":[],\"text\":\"Hello\",\"type\":\"output_text\"}],\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"type\":\"message\"}],\"status\":\"completed\",\"usage\":{\"input_tokens\":30,\"input_tokens_details\":{\"cached_tokens\":12},\"output_tokens\":2,\"output_tokens_details\":{\"reasoning_tokens\":1},\"total_tokens\":32}},\"sequence_number\":5,\"type\":\"response.completed\"}\n\n";
    var recorded: RecordedEvents = .{};
    defer recorded.content.deinit(alloc);
    var result = try test_consume(alloc, captured, &recorded);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Hello", completion.content.?);
    try std.testing.expectEqualStrings("Hello", recorded.content.items);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 30), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 1), completion.usage.reasoning_tokens);
}

test "configured responses fails a reply that never finishes" {
    const alloc = std.testing.allocator;
    const cut = "event: response.created\ndata: {\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"output\":[]},\"type\":\"response.created\"}\n\n";
    var recorded: RecordedEvents = .{};
    defer recorded.content.deinit(alloc);
    try std.testing.expectError(error.ResponsesStreamIncomplete, test_consume(alloc, cut, &recorded));
    try std.testing.expectError(error.MalformedResponsesEvent, test_consume(alloc, "data: {not json\n\n", &recorded));
}

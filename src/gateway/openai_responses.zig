//! OpenAI Responses transport for configured providers such as OpenCode Zen
//! (D147). The body and the stream reducer are the Codex ones; only the
//! endpoint, the bearer key, the replay authority and two request fields
//! differ, so the public API's `max_output_tokens` is sent and Codex's
//! `text.verbosity` is not.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const model_compatibility = @import("../core/config/model_compatibility.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const responses_protocol = @import("responses_protocol.zig");
const openai_codex = @import("openai_codex.zig");
const chat_completions = @import("chat_completions.zig");
const configured_request = @import("configured_request.zig");
const sse = @import("sse.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .compaction = .{ .context = context, .supports_v2_streaming = true, .compact_fn = compact },
            .build_request_fn = build,
            .project_replay_fn = project_replay,
        },
        .model_catalog = chat_completions.model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat_completions.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

pub fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) anyerror![]u8 {
    const definition = definition_at(raw);
    const metadata = request.provider_options.model_metadata orelse definition.model(request.model);
    const base_url = definition.baseUrlFor(request.model);
    const openrouter_host = std.mem.find(u8, base_url, "openrouter.ai") != null;
    const vercel_gateway_host = std.mem.find(u8, base_url, "ai-gateway.vercel.sh") != null or
        std.mem.find(u8, base_url, "gateway.ai.vercel.sh") != null;
    const body = try build_request(alloc, request, chat_completions.bound_identity(definition), if (metadata) |value| &value.compat else null, metadata, openrouter_host, vercel_gateway_host);
    return body;
}

fn build_request(
    alloc: Allocator,
    request: streams.RequestData,
    provider: @import("../core/config/model_provider.zig").ProviderId,
    compatibility: ?*const model_compatibility.Compatibility,
    metadata: ?*const definitions.ModelMetadata,
    openrouter_host: bool,
    vercel_gateway_host: bool,
) anyerror![]u8 {
    try request.validatePrompt();
    definitions.validate_model_id(request.model) catch return error.InvalidModel;
    const effective_compatibility = active_compatibility(compatibility, request.provider_options.reasoning != null);
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = provider, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |instruction| if (instruction.content) |text| if (text.len != 0) {
        if (instructions.written().len != 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    };
    if (instructions.written().len == 0) try instructions.writer.writeAll("You are a helpful assistant.");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    if (effective_compatibility) |value| {
        if (value.stateful_responses == true) {
            try writer.writeAll(",\"store\":true");
        } else if (value.supports_store == true) {
            try writer.writeAll(",\"store\":false");
        }
    }
    try writer.writeAll(",\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try responses_protocol.writeInputWith(writer, alloc, projected orelse request.messages, request.verified_images, .{
        .tool_calls = 128,
        .tool_identity_bytes = 256,
        .tool_arguments_bytes = 1024 * 1024,
        .provider_state_bytes = types.ProviderReplay.max_bytes,
    }, budget, .{ .compatibility = effective_compatibility });
    try writer.writeByte(']');
    const tool_count = try responses_protocol.writeToolsWith(writer, alloc, request.tools, .{ .compatibility = effective_compatibility });
    if (tool_count != 0 and (effective_compatibility == null or effective_compatibility.?.supports_tool_choice != false)) {
        try writer.writeAll(",\"tool_choice\":");
        const choice = if (request.tool_choice == .required and effective_compatibility != null and effective_compatibility.?.supports_forced_tool_choice == false) "auto" else request.tool_choice.label();
        try std.json.Stringify.value(choice, .{}, writer);
    }
    if (tool_count != 0) if (request.provider_options.parallel_tool_calls) |parallel| {
        try writer.writeAll(",\"parallel_tool_calls\":");
        try std.json.Stringify.value(parallel, .{}, writer);
    };
    if (effective_compatibility == null or effective_compatibility.?.supports_reasoning_summary != false) try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");
    try writer.writeAll(",\"text\":{");
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll("\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}");
    }
    try writer.writeByte('}');
    const disable_reasoning = if (effective_compatibility) |value|
        (tool_count != 0 and value.disable_reasoning_with_tools == true) or
            (request.tool_choice == .required and value.disable_reasoning_on_forced_tool_choice == true) or
            (request.tool_choice != .auto and value.disable_reasoning_on_tool_choice == true)
    else
        false;
    if (!disable_reasoning) if (request.provider_options.reasoning) |effort| if (effort.gatewayValue()) |raw_name| {
        if ((effective_compatibility == null or effective_compatibility.?.supports_reasoning_params != false) and
            (effective_compatibility == null or effective_compatibility.?.supports_reasoning_effort != false))
        {
            const name = response_effort(effective_compatibility, raw_name);
            try writer.writeAll(",\"reasoning\":{\"effort\":");
            try std.json.Stringify.value(if (std.mem.eql(u8, name, "minimal")) "low" else name, .{}, writer);
            if (effective_compatibility == null or effective_compatibility.?.supports_reasoning_summary != false) try writer.writeAll(",\"summary\":\"auto\"");
            try writer.writeByte('}');
        }
    };
    if (metadata == null or metadata.?.omit_max_output_tokens == false) {
        const output_limit = request.max_output_tokens orelse if (effective_compatibility != null and effective_compatibility.?.always_send_max_tokens == true)
            (if (metadata) |value| value.max_output_tokens else null)
        else
            null;
        if (output_limit) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    }
    if (request.provider_options.prompt_caching and request.provider_options.skip_cache_writes == false and effective_compatibility != null and effective_compatibility.?.supports_long_prompt_cache_retention == true) {
        try writer.writeAll(",\"prompt_cache_retention\":\"24h\"");
    }
    if (effective_compatibility) |value| {
        if (value.cache_control_format == .anthropic) try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
        if (openrouter_host and request.provider_options.provider_order.len == 0) if (value.openrouter_routing) |route| if (route.only.len != 0 or route.order.len != 0) {
            try writer.writeAll(",\"provider\":{");
            if (route.only.len != 0) {
                try writer.writeAll("\"only\":");
                try std.json.Stringify.value(route.only, .{}, writer);
            } else {
                try writer.writeAll("\"order\":");
                try std.json.Stringify.value(route.order, .{}, writer);
            }
            try writer.writeByte('}');
        };
        if (vercel_gateway_host) if (route_for_gateway(effective_compatibility.?)) |route| {
            try writer.writeAll(",\"providerOptions\":{\"gateway\":{");
            var wrote = false;
            if (route.only.len != 0) {
                try writer.writeAll("\"only\":");
                try std.json.Stringify.value(route.only, .{}, writer);
                wrote = true;
            }
            if (route.order.len != 0) {
                if (wrote) try writer.writeByte(',');
                try writer.writeAll("\"order\":");
                try std.json.Stringify.value(route.order, .{}, writer);
            }
            try writer.writeAll("}}");
        };
    }
    try writer.writeByte('}');
    const serialized = try out.toOwnedSlice();
    defer alloc.free(serialized);
    return merge_extra_body(alloc, serialized, effective_compatibility);
}

fn active_compatibility(base: ?*const model_compatibility.Compatibility, reasoning_requested: bool) ?*const model_compatibility.Compatibility {
    const compatibility = base orelse return null;
    if (reasoning_requested) return compatibility.when_thinking orelse compatibility;
    return compatibility;
}

fn route_for_gateway(compatibility: *const model_compatibility.Compatibility) ?model_compatibility.Routing {
    return compatibility.vercel_gateway_routing;
}
fn response_effort(compatibility: ?*const model_compatibility.Compatibility, raw_name: []const u8) []const u8 {
    if (compatibility) |value| if (value.reasoning_effort_map) |map| if (map.get(raw_name)) |mapped| return mapped;
    return raw_name;
}

fn merge_extra_body(alloc: Allocator, body: []const u8, compatibility: ?*const model_compatibility.Compatibility) ![]u8 {
    const extra = if (compatibility) |value| value.extra_body else null;
    if (extra == null or extra.? != .object or extra.?.object.count() == 0) return alloc.dupe(u8, body);
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, body, .{}) catch return error.InvalidProviderState;
    var iterator = extra.?.object.iterator();
    while (iterator.next()) |entry| parsed.object.put(scratch, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(parsed, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub const project_replay = responses_protocol.selectReplayParts;

fn compact(raw: ?*anyopaque, alloc: Allocator, request: streams.CompactionRequest) anyerror!streams.CompactionResult {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    try configured_request.checkToken(definition, token);
    const metadata = definition.model(request.model) orelse return error.ResponsesCompactionUnavailable;
    const remote = metadata.remote_compaction orelse return error.ResponsesCompactionUnavailable;
    if (!remote.enabled) return error.ResponsesCompactionUnavailable;
    if (request.kind == .v2_streaming) {
        if (!responsesV2Enabled(definition, metadata, remote)) return error.ResponsesCompactionUnavailable;
        return compactV2(alloc, definition, request, remote, token);
    }
    if (request.kind != .remote) return error.UnsupportedResponsesCompactionKind;
    const endpoint = try compactionEndpoint(alloc, definition, request.model, remote);
    defer alloc.free(endpoint);
    const model = remote.model orelse request.model;
    const payload = try buildCompactionPayload(alloc, definition, request, model);
    defer alloc.free(payload);

    var delivery: streams.DeliveryCertainty = .{};
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    const model_request: streams.ModelRequest = .{
        .admission = request.admission,
        .observer = request.observer,
        .purpose = .compaction,
        .credential = request.credential,
        .session_id = request.session_id,
        .model = model,
        .retry_count = 0,
        .instructions = &.{},
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = if (request.tools.advertised_functions.len != 0 or request.tools.additional_functions.len != 0) .auto else .none,
        .provider_options = request.provider_options,
        .budget = request.budget,
        .trace_ctx = request.trace_ctx,
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = discard_compaction_event },
        .cancel_flag = request.cancel_flag,
    };
    const body = try chat_completions.post_json_url(alloc, definition, endpoint, model_request, token, payload, consume_json);
    defer alloc.free(body);
    return parseCompactionResult(alloc, body);
}

fn responsesV2Enabled(
    definition: *const definitions.Definition,
    metadata: *const definitions.ModelMetadata,
    remote: definitions.RemoteCompaction,
) bool {
    if (!remote.v2_streaming_enabled) return false;
    return (remote.protocol orelse metadata.protocol orelse definition.protocol) == .@"openai-responses";
}

fn compactV2(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.CompactionRequest,
    remote: definitions.RemoteCompaction,
    token: ?[]const u8,
) !streams.CompactionResult {
    const endpoint = try compactionV2Endpoint(alloc, definition, request.model, remote);
    defer alloc.free(endpoint);
    const model = remote.model orelse request.model;
    const payload = try buildCompactionV2Payload(alloc, definition, request, model);
    defer alloc.free(payload);
    var delivery: streams.DeliveryCertainty = .{};
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    const model_request: streams.ModelRequest = .{
        .admission = request.admission,
        .observer = request.observer,
        .purpose = .compaction,
        .credential = request.credential,
        .session_id = request.session_id,
        .model = request.model,
        .retry_count = 0,
        .instructions = &.{},
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = if (request.tools.advertised_functions.len != 0 or request.tools.additional_functions.len != 0) .auto else .none,
        .provider_options = request.provider_options,
        .budget = request.budget,
        .trace_ctx = request.trace_ctx,
        .content_capture_limit = null,
        .deadline = if (request.budget) |budget| budget.deadline else null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = discard_compaction_event },
        .cancel_flag = request.cancel_flag,
    };
    var result = try chat_completions.post_url(alloc, definition, endpoint, model_request, token, payload, consumeV2);
    switch (result) {
        .completed => |*completed| {
            const completion = &completed.completion;
            const summary = completion.content orelse {
                result.deinit(alloc);
                return error.ResponsesCompactionMissingItem;
            };
            const state = completion.provider_state_json orelse {
                result.deinit(alloc);
                return error.ResponsesCompactionMissingItem;
            };
            completed.ownership = .borrowed;
            return .{
                .summary = summary,
                .provider_state_json = state,
                .used_tokens = completion.usage.input_tokens,
                .usage = completion.usage,
                .ownership = .owned,
            };
        },
        .failed => {
            result.deinit(alloc);
            return error.ResponsesCompactionProviderFailed;
        },
    }
}

fn compactionV2Endpoint(
    alloc: Allocator,
    definition: *const definitions.Definition,
    model: []const u8,
    remote: definitions.RemoteCompaction,
) ![]u8 {
    for ([_]?[]const u8{ remote.v2_endpoint, remote.streaming_endpoint }) |configured| if (configured) |endpoint| {
        const trimmed = std.mem.trim(u8, endpoint, " \t\r\n");
        if (trimmed.len != 0) return alloc.dupe(u8, trimmed);
    };
    const base = std.mem.trimEnd(u8, definition.baseUrlFor(model), "/");
    if (std.mem.endsWith(u8, base, "/responses")) return alloc.dupe(u8, base);
    if (std.mem.endsWith(u8, base, "/v1")) return std.mem.concat(alloc, u8, &.{ base, "/responses" });
    return std.mem.concat(alloc, u8, &.{ base, "/v1/responses" });
}

fn buildCompactionV2Payload(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.CompactionRequest,
    model: []const u8,
) ![]u8 {
    const system = [_]types.ChatMessage{.{ .role = .system, .content = request.instructions }};
    const data: streams.RequestData = .{
        .session_id = request.session_id,
        .model = request.model,
        .instructions = if (request.instructions.len == 0) &.{} else &system,
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = if (request.tools.advertised_functions.len != 0 or request.tools.additional_functions.len != 0) .auto else .none,
        .provider_options = request.provider_options,
        .budget = request.budget,
    };
    const original = try build(@ptrCast(@constCast(definition)), alloc, data);
    defer alloc.free(original);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, original, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesCompactionRequest;
    const object = &parsed.value.object;
    try object.put(alloc, "model", .{ .string = model });
    try object.put(alloc, "stream", .{ .bool = true });
    try object.put(alloc, "store", .{ .bool = false });
    const input = object.getPtr("input") orelse return error.InvalidResponsesCompactionRequest;
    if (input.* != .array or input.array.items.len >= 100_000) return error.InvalidResponsesCompactionRequest;
    var trigger: std.json.ObjectMap = .empty;
    try trigger.put(alloc, "type", .{ .string = "compaction_trigger" });
    try input.array.append(.{ .object = trigger });
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn compactionEndpoint(
    alloc: Allocator,
    definition: *const definitions.Definition,
    model: []const u8,
    remote: definitions.RemoteCompaction,
) ![]u8 {
    if (remote.endpoint) |endpoint| if (std.mem.trim(u8, endpoint, " \t\r\n").len != 0) return alloc.dupe(u8, endpoint);
    const base = definition.baseUrlFor(model);
    if (std.mem.endsWith(u8, base, "/v1")) return std.mem.concat(alloc, u8, &.{ base, "/responses/compact" });
    return std.mem.concat(alloc, u8, &.{ base, "/v1/responses/compact" });
}

fn buildCompactionPayload(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.CompactionRequest,
    model: []const u8,
) ![]u8 {
    const system = [_]types.ChatMessage{.{ .role = .system, .content = request.instructions }};
    const data: streams.RequestData = .{
        .session_id = request.session_id,
        .model = request.model,
        .instructions = if (request.instructions.len == 0) &.{} else &system,
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = if (request.tools.advertised_functions.len != 0 or request.tools.additional_functions.len != 0) .auto else .none,
        .provider_options = request.provider_options,
        .budget = request.budget,
    };
    const payload = try build(@ptrCast(@constCast(definition)), alloc, data);
    defer alloc.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesCompactionRequest;
    const object = &parsed.value.object;
    try object.put(alloc, "model", .{ .string = model });
    // /responses/compact accepts the Responses transcript, instructions, and
    // model; normal completion-only fields can change the endpoint semantics.
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

fn discard_compaction_event(_: *anyopaque, _: streams.Event) void {}

fn consume_json(
    alloc: Allocator,
    reader: *std.Io.Reader,
    _: streams.ModelRequest,
    _: ?sse.Progress,
) ![]u8 {
    return reader.allocRemaining(alloc, .limited(16 * 1024 * 1024));
}

const v2_max_event_bytes: usize = 32 * 1024 * 1024;
const v2_retained_message_budget: u32 = 64_000;

const V2Collection = struct {
    alloc: Allocator,
    compaction_item: ?[]u8 = null,
    saw_completed: bool = false,
    usage: types.Usage = .{},

    fn deinit(self: *V2Collection) void {
        if (self.compaction_item) |value| self.alloc.free(value);
        self.* = undefined;
    }
};

fn consumeV2(
    alloc: Allocator,
    reader: *std.Io.Reader,
    request: streams.ModelRequest,
    progress: ?sse.Progress,
) !streams.Result {
    var collection = V2Collection{ .alloc = alloc };
    defer collection.deinit();
    var events: sse.Reader = .{ .max_event_bytes = v2_max_event_bytes, .progress = progress };
    defer events.deinit(alloc);
    while (events.next(alloc, reader, request.cancel_flag) catch |err| return err) |json_text| {
        if (std.mem.eql(u8, json_text, "[DONE]")) break;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidResponsesCompactionEvent;
        defer parsed.deinit();
        try consumeV2Event(alloc, &collection, parsed.value);
        if (collection.saw_completed) break;
    }
    if (!collection.saw_completed) return error.ResponsesCompactionStreamIncomplete;
    const item = collection.compaction_item orelse return error.ResponsesCompactionMissingItem;
    const summary = try v2CompactionSummary(alloc, item);
    errdefer alloc.free(summary);
    const replacement = try buildV2ReplacementHistory(alloc, request.messages, item, v2_retained_message_budget);
    errdefer alloc.free(replacement);
    return .{ .completed = .{
        .completion = .{
            .content = summary,
            .provider_state_json = replacement,
            .finish_reason = .stop,
            .usage = collection.usage,
        },
        .ownership = .owned,
    } };
}

fn consumeV2Event(alloc: Allocator, collection: *V2Collection, value: std.json.Value) !void {
    if (value != .object) return;
    const event_type = value.object.get("type") orelse return;
    if (event_type != .string) return;
    if (std.mem.eql(u8, event_type.string, "response.output_item.done")) {
        const item = value.object.get("item") orelse return;
        if (item != .object) return;
        const item_type = item.object.get("type") orelse return;
        if (item_type != .string or !std.mem.eql(u8, item_type.string, "compaction")) return;
        if (collection.compaction_item != null) return error.ResponsesCompactionMultipleItems;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(item, .{}, &out.writer);
        collection.compaction_item = try out.toOwnedSlice();
        return;
    }
    if (std.mem.eql(u8, event_type.string, "response.completed") or std.mem.eql(u8, event_type.string, "response.done")) {
        const response = value.object.get("response") orelse return;
        if (response != .object) return;
        collection.saw_completed = true;
        collection.usage = parseUsage(response.object.get("usage"));
        return;
    }
    if (std.mem.eql(u8, event_type.string, "response.failed") or std.mem.eql(u8, event_type.string, "error")) return error.ResponsesCompactionProviderFailed;
}

fn v2CompactionSummary(alloc: Allocator, item_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, item_json, .{});
    defer parsed.deinit();
    if (parsed.value == .object) if (parsed.value.object.get("summary")) |summary| if (summary == .string and std.mem.trim(u8, summary.string, " \t\r\n").len > 0) return alloc.dupe(u8, summary.string);
    return alloc.dupe(u8, "Remote compaction");
}

fn buildV2ReplacementHistory(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    item_json: []const u8,
    budget: u32,
) ![]u8 {
    var input: std.Io.Writer.Allocating = .init(alloc);
    defer input.deinit();
    try input.writer.writeByte('[');
    try responses_protocol.writeInputWith(&input.writer, alloc, messages, null, .{
        .tool_calls = 128,
        .tool_identity_bytes = 256,
        .tool_arguments_bytes = 1024 * 1024,
        .provider_state_bytes = types.ProviderReplay.max_bytes,
    }, .{}, .{});
    try input.writer.writeByte(']');
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, input.written(), .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesCompactionHistory;
    var kept: std.ArrayList(std.json.Value) = .empty;
    defer kept.deinit(alloc);
    var tokens: usize = 0;
    var index = parsed.value.array.items.len;
    while (index > 0) {
        index -= 1;
        const value = &parsed.value.array.items[index];
        if (value.* != .object) continue;
        const role = value.object.get("role") orelse continue;
        if (role != .string or (!std.mem.eql(u8, role.string, "user") and !std.mem.eql(u8, role.string, "system") and !std.mem.eql(u8, role.string, "developer"))) continue;
        if (!value.object.contains("type")) try value.object.put(alloc, "type", .{ .string = "message" });
        const estimate = @max(1, try v2JsonTokenEstimate(value.*));
        if (tokens +| estimate > budget) break;
        try kept.append(alloc, value.*);
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
    if (out.written().len > types.ProviderReplay.max_bytes) return error.ResponsesCompactionStateTooLarge;
    return out.toOwnedSlice();
}

fn v2JsonTokenEstimate(value: std.json.Value) !usize {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written().len / 4 + 1;
}

fn parseCompactionResult(alloc: Allocator, body: []const u8) !streams.CompactionResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesCompactionResponse;
    const object = parsed.value.object;
    const output = object.get("output");
    var item: ?std.json.Value = null;
    var state_json: ?[]u8 = null;
    if (output) |value| if (value == .array) {
        for (value.array.items) |candidate| {
            if (candidate != .object) continue;
            const kind = candidate.object.get("type") orelse continue;
            if (kind != .string or (!std.mem.eql(u8, kind.string, "compaction") and !std.mem.eql(u8, kind.string, "compaction_summary"))) continue;
            item = candidate;
            break;
        }
        if (item == null) return error.ResponsesCompactionMissingItem;
        var state = std.Io.Writer.Allocating.init(alloc);
        defer state.deinit();
        try std.json.Stringify.value(value, .{}, &state.writer);
        state_json = try state.toOwnedSlice();
    };
    var summary: ?[]u8 = null;
    if (object.get("summary")) |value| if (value == .string and std.mem.trim(u8, value.string, " \t\r\n").len != 0) {
        summary = try alloc.dupe(u8, value.string);
    };
    if (summary == null) if (item) |value| {
        for ([_][]const u8{ "summary", "text" }) |key| if (value.object.get(key)) |field| if (field == .string and std.mem.trim(u8, field.string, " \t\r\n").len != 0) {
            summary = try alloc.dupe(u8, field.string);
            break;
        };
    };
    if (summary == null) summary = try alloc.dupe(u8, "Remote compaction");
    errdefer if (summary) |value| alloc.free(value);
    const usage = parseUsage(object.get("usage"));
    return .{
        .summary = summary,
        .provider_state_json = state_json,
        .used_tokens = usage.input_tokens,
        .usage = usage,
        .ownership = .owned,
    };
}

fn parseUsage(value: ?std.json.Value) types.Usage {
    const usage = value orelse return .{};
    if (usage != .object) return .{};
    return .{
        .input_tokens = unsignedField(usage.object, "input_tokens"),
        .output_tokens = unsignedField(usage.object, "output_tokens"),
        .cache_read_tokens = unsignedField(usage.object, "cache_read_tokens"),
    };
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) anyerror!streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    try configured_request.checkToken(definition, token);
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const url = try definition.responses_url(alloc, request.model);
    defer alloc.free(url);
    return chat_completions.post_url(alloc, definition, url, request, token, payload, consume);
}

fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) anyerror!streams.Result {
    return openai_codex.completeFromStream(alloc, request, reader, progress);
}

pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return chat_completions.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
}

const CompactionHttpFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    request_body: [128 * 1024]u8 = undefined,
    request_body_len: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    streaming: bool = false,

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
            var wake_io: std.Io.Threaded = .init_single_threaded;
            const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
            if (address.connect(wake_io.io(), .{ .mode = .stream })) |wake| {
                wake.close(wake_io.io());
            } else |_| {}
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
        const body: []const u8 = if (self.streaming)
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"compaction\",\"summary\":\"Keep the streamed context.\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":432,\"output_tokens\":8}}}\n\n"
        else
            "{\"output\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"retain this\"}]},{\"type\":\"compaction_summary\",\"summary\":\"Keep the retained context.\"}],\"usage\":{\"input_tokens\":321}}";
        const content_type = if (self.streaming) "text/event-stream" else "application/json";
        var output: [2048]u8 = undefined;
        const response = std.mem.print(&output, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ content_type, body.len, body }) catch |err| {
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

test "configured Responses V1 compaction sends request and replays output" {
    const alloc = std.testing.allocator;
    var fixture = try CompactionHttpFixture.init();
    defer fixture.deinit();
    try fixture.start();
    const endpoint = try alloc.print("http://127.0.0.1:{d}/v1/responses/compact", .{fixture.port()});
    defer alloc.free(endpoint);
    const config = try alloc.print("{{\"local\":{{\"protocol\":\"openai-responses\",\"base_url\":\"http://127.0.0.1:{d}/v1\",\"auth\":{{\"type\":\"none\"}},\"model_metadata\":{{\"source\":{{\"remote_compaction\":{{\"enabled\":true,\"endpoint\":\"{s}\",\"model\":\"summary\"}}}}}}}}}}", .{ fixture.port(), endpoint });
    defer alloc.free(config);
    var registry = try definitions.Registry.parse_json(alloc, config);
    defer registry.deinit(alloc);
    const definition = registry.get("local").?;
    var cancelled = std.atomic.Value(bool).init(false);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "retain this" }};
    const request: streams.CompactionRequest = .{
        .credential = .{ .direct = .{ .source = .configured } },
        .model = "source",
        .instructions = "",
        .messages = &messages,
        .cancel_flag = &cancelled,
    };
    var result = try @import("../core/agent/runtime/gateway_step.zig").compactModelContext(bundle(definition).agent_stream.?.compaction.?, alloc, request);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("Keep the retained context.", result.summary.?);
    try std.testing.expectEqual(@as(?u64, 321), result.used_tokens);
    const body_len = fixture.request_body_len.load(.seq_cst);
    try std.testing.expect(body_len > 0);
    const sent = fixture.request_body[0..body_len];
    try std.testing.expect(std.mem.find(u8, sent, "\"model\":\"summary\"") != null);
    try std.testing.expect(std.mem.find(u8, sent, "\"stream\"") == null);
    try std.testing.expect(std.mem.find(u8, sent, "\"input\"") != null);
    try std.testing.expect(fixture.failure == null);
    const replay = result.provider_state_json.?;
    const replay_message = [_]types.ChatMessage{.{ .role = .assistant, .provider_replay = .{
        .source = .{ .provider = model_provider.parse("local").?, .model = "summary" },
        .parts_json = replay,
    } }};
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try responses_protocol.writeInputWith(&out.writer, alloc, &replay_message, null, .{
        .tool_calls = 8,
        .tool_identity_bytes = 128,
        .tool_arguments_bytes = 4096,
        .provider_state_bytes = types.ProviderReplay.max_bytes,
    }, .{}, .{});
    try std.testing.expect(std.mem.find(u8, out.written(), "compaction_summary") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "role\":\"user") != null);
}

test "configured Responses V2 compaction streams configured endpoint and model" {
    const alloc = std.testing.allocator;
    var fixture = try CompactionHttpFixture.init();
    fixture.streaming = true;
    defer fixture.deinit();
    try fixture.start();
    const endpoint = try alloc.print("http://127.0.0.1:{d}/v2/compact", .{fixture.port()});
    defer alloc.free(endpoint);
    const config = try alloc.print("{{\"local\":{{\"protocol\":\"openai-responses\",\"base_url\":\"http://127.0.0.1:{d}/v1\",\"auth\":{{\"type\":\"none\"}},\"model_metadata\":{{\"source\":{{\"remote_compaction\":{{\"enabled\":true,\"v2_streaming_enabled\":true,\"v2_endpoint\":\"{s}\",\"model\":\"summary-v2\"}}}}}}}}}}", .{ fixture.port(), endpoint });
    defer alloc.free(config);
    var registry = try definitions.Registry.parse_json(alloc, config);
    defer registry.deinit(alloc);
    const definition = registry.get("local").?;
    var cancelled = std.atomic.Value(bool).init(false);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "retain streamed input" }};
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const work = scratch.allocator();
    var result = try @import("../core/agent/runtime/gateway_step.zig").compactModelContext(bundle(definition).agent_stream.?.compaction.?, work, .{
        .credential = .{ .direct = .{ .source = .configured } },
        .model = "source",
        .instructions = "",
        .messages = &messages,
        .kind = .v2_streaming,
        .cancel_flag = &cancelled,
    });
    defer result.deinit(work);
    try std.testing.expectEqualStrings("Keep the streamed context.", result.summary.?);
    try std.testing.expectEqual(@as(?u64, 432), result.used_tokens);
    const sent = fixture.request_body[0..fixture.request_body_len.load(.seq_cst)];
    try std.testing.expect(std.mem.find(u8, sent, "\"model\":\"summary-v2\"") != null);
    try std.testing.expect(std.mem.find(u8, sent, "compaction_trigger") != null);
    try std.testing.expect(std.mem.find(u8, sent, "\"stream\":true") != null);
    try std.testing.expect(fixture.failure == null);
    const replay = result.provider_state_json.?;
    const bound_local = try model_provider.parse("local").?.bind(registry);
    const next_messages = [_]types.ChatMessage{.{ .role = .assistant, .provider_replay = .{
        .source = .{ .provider = bound_local, .model = "source" },
        .parts_json = replay,
    } }};
    var direct_wire: std.Io.Writer.Allocating = .init(work);
    try responses_protocol.writeInputWith(&direct_wire.writer, work, &next_messages, null, .{
        .tool_calls = 128,
        .tool_identity_bytes = 256,
        .tool_arguments_bytes = 1024 * 1024,
        .provider_state_bytes = types.ProviderReplay.max_bytes,
    }, .{}, .{});
    const next_payload = try build(@ptrCast(@constCast(definition)), work, .{
        .model = "source",
        .messages = &next_messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    try std.testing.expect(std.mem.find(u8, next_payload, "compaction") != null);
}

test "configured Responses requests carry the endpoint authority and output limit" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"zen":{"protocol":"openai-responses","base_url":"https://opencode.ai/zen/v1","auth":{"type":"login"},"model_metadata":{"gpt-5.5":{"reasoning_efforts":["low","high"]}}}}
    );
    defer registry.deinit(alloc);
    const definition = registry.get("zen").?;
    const body = try build(@ptrCast(@constCast(definition)), alloc, .{
        .model = "gpt-5.5",
        .instructions = &.{.{ .role = .system, .content = "Be brief." }},
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = .literal("high") },
        .max_output_tokens = 4096,
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":4096") != null);
    try std.testing.expect(std.mem.find(u8, body, "verbosity") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be brief.\"") != null);
    const url = try definition.responses_url(alloc, "gpt-5.5");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/responses", url);
}

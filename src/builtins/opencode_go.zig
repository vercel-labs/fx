const std = @import("std");
const agent_stream = @import("../core/agent/stream_provider.zig");
const gateway_client = @import("../gateway/client.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const provider_id = @import("../core/providers/provider_id.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const responses_url = "https://opencode.ai/zen/go/v1/responses";
pub const models_url = "https://opencode.ai/zen/go/v1/models";

pub fn isModel(model: []const u8) bool {
    return provider_id.fromModel(model) == .opencode_go;
}

fn writeJsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeTool(writer: *std.Io.Writer, value: std.json.Value) !void {
    if (value != .object) return error.InvalidOpenCodeGoToolSchema;
    const tool_type = value.object.get("type") orelse return error.InvalidOpenCodeGoToolSchema;
    if (tool_type != .string or !std.mem.eql(u8, tool_type.string, "function")) {
        return error.InvalidOpenCodeGoToolSchema;
    }
    const name = value.object.get("name") orelse return error.InvalidOpenCodeGoToolSchema;
    const description = value.object.get("description") orelse return error.InvalidOpenCodeGoToolSchema;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse
        return error.InvalidOpenCodeGoToolSchema;
    if (name != .string or description != .string) return error.InvalidOpenCodeGoToolSchema;

    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try writeJsonValue(writer, name.string);
    try writer.writeAll(",\"description\":");
    try writeJsonValue(writer, description.string);
    try writer.writeAll(",\"parameters\":");
    try writeJsonValue(writer, parameters);
    try writer.writeAll("}");
}

fn writeTools(alloc: Allocator, writer: *std.Io.Writer, request: agent_stream.BuildRequest) !void {
    var first = true;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, request.serialized_tools, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidOpenCodeGoToolSchema;
    for (parsed.value.array.items) |tool| {
        if (tool == .object) {
            if (tool.object.get("type")) |tool_type| {
                if (tool_type == .string and std.mem.eql(u8, tool_type.string, "provider")) continue;
            }
        }
        if (!first) try writer.writeByte(',');
        first = false;
        try writeTool(writer, tool);
    }
    for (request.selected_dynamic_tool_schemas) |schema| {
        var dynamic = try std.json.parseFromSlice(std.json.Value, alloc, schema, .{});
        defer dynamic.deinit();
        if (!first) try writer.writeByte(',');
        first = false;
        try writeTool(writer, dynamic.value);
    }
}

fn writeMessage(writer: *std.Io.Writer, message: types.ChatMessage, first: *bool) !void {
    if (message.role != .tool) {
        if (message.content) |content| {
            if (!first.*) try writer.writeByte(',');
            first.* = false;
            try writer.writeAll("{\"type\":\"message\",\"role\":");
            try writeJsonValue(writer, switch (message.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => unreachable,
            });
            try writer.writeAll(",\"content\":");
            try writeJsonValue(writer, content);
            try writer.writeByte('}');
        }
    }

    for (message.tool_calls) |call| {
        if (!first.*) try writer.writeByte(',');
        first.* = false;
        try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
        try writeJsonValue(writer, call.id);
        try writer.writeAll(",\"name\":");
        try writeJsonValue(writer, call.name);
        try writer.writeAll(",\"arguments\":");
        try writeJsonValue(writer, call.arguments_json);
        try writer.writeByte('}');
    }

    if (message.role == .tool) {
        const call_id = message.tool_call_id orelse return error.InvalidOpenCodeGoToolHistory;
        if (!first.*) try writer.writeByte(',');
        first.* = false;
        try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
        try writeJsonValue(writer, call_id);
        try writer.writeAll(",\"output\":");
        try writeJsonValue(writer, message.content orelse "");
        try writer.writeByte('}');
    }
}

fn buildRequest(_: ?*anyopaque, alloc: Allocator, request: agent_stream.BuildRequest) anyerror![]u8 {
    if (!isModel(request.model)) return error.InvalidOpenCodeGoModel;
    // The vision tool being registered (.optional) is not an image request.
    // Only refuse when vision is actually demanded: a forced vision route or
    // verified images attached to the turn.
    if (request.vision_mode == .required or request.verified_images != null) {
        return error.OpenCodeGoVisionUnavailable;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"model\":");
    try writeJsonValue(&out.writer, provider_id.upstreamModel(request.model));
    try out.writer.writeAll(",\"stream\":true,\"store\":false,\"input\":[");
    var first = true;
    for (request.messages) |message| try writeMessage(&out.writer, message, &first);
    try out.writer.writeAll("],\"tools\":[");
    try writeTools(alloc, &out.writer, request);
    try out.writer.writeAll("],\"tool_choice\":");
    try writeJsonValue(&out.writer, request.tool_choice.label());
    if (request.max_output_tokens) |limit| try out.writer.print(",\"max_output_tokens\":{d}", .{limit});
    if (request.provider_options.parallel_tool_calls) |enabled| {
        try out.writer.print(",\"parallel_tool_calls\":{s}", .{if (enabled) "true" else "false"});
    }
    if (request.provider_options.reasoning) |effort| {
        if (effort != .auto) {
            try out.writer.writeAll(",\"reasoning\":{\"effort\":");
            try writeJsonValue(&out.writer, @tagName(effort));
            try out.writer.writeByte('}');
        }
    }
    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        try out.writer.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try writeJsonValue(&out.writer, format.name);
        try out.writer.writeAll(",\"description\":");
        try writeJsonValue(&out.writer, format.description);
        try out.writer.writeAll(",\"strict\":true,\"schema\":");
        try writeJsonValue(&out.writer, schema.value);
        try out.writer.writeAll("}}");
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn streamCompletion(_: ?*anyopaque, alloc: Allocator, request: agent_stream.Request) anyerror!agent_stream.Result {
    const result = gateway_client.streamGatewayCompletion(alloc, .{
        .api_key = request.api_key,
        .model = provider_id.upstreamModel(request.model),
        .retry_count = request.retry_count,
        .chat_url = responses_url,
        .payload = request.payload,
        .trace_ctx = request.trace_ctx,
        .content_capture_limit = request.content_capture_limit,
        .delivery = request.delivery,
        .on_reasoning_chunk = request.on_reasoning_chunk,
        .on_tool_input_chunk = request.on_tool_input_chunk,
        .provider_attempt_owner = switch (request.provider_attempt_owner) {
            .transport => .transport,
            .agent => .agent,
        },
        .wire_format = .openai_responses,
    }, request.callback_ctx, request.on_content_chunk, request.on_tool_start, request.cancel_flag) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

pub const agent_stream_provider = agent_stream.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

fn parseCatalog(alloc: Allocator, json_text: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenCodeGoCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenCodeGoCatalog;
    if (data != .array) return error.InvalidOpenCodeGoCatalog;

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (data.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;
        const id = try std.fmt.allocPrint(alloc, "{s}{s}", .{ provider_id.opencode_go_prefix, id_value.string });
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var released: i64 = 0;
        if (item.object.get("created")) |created| switch (created) {
            .integer => |value| released = value,
            else => {},
        };
        try entries.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = released,
            .has_tool_use = true,
        });
    }
    std.mem.sort(model_catalog.ModelCatalogEntry, entries.items, {}, model_catalog.compareModelCatalogEntries);
    return entries;
}

fn fetchCatalog(_: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const response = if (input.cancel_flag) |flag|
        gateway_client.fetchGatewayJsonCancellable(alloc, null, null, models_url, flag) catch |err| return .{
            .failure = .{ .category = if (err == error.OutOfMemory) .resource_exhausted else .transport },
        }
    else
        gateway_client.fetchGatewayJson(alloc, null, null, models_url) catch |err| return .{
            .failure = .{ .category = if (err == error.OutOfMemory) .resource_exhausted else .transport },
        };
    const body = switch (response) {
        .success => |value| value,
        .http_status => |status| return .{ .failure = model_catalog.failureForHttpStatus(status) },
    };
    defer alloc.free(body);
    return .{ .catalog = parseCatalog(alloc, body) catch |err| return .{
        .failure = .{ .category = if (err == error.OutOfMemory) .resource_exhausted else .malformed_response },
    } };
}

pub const model_catalog_provider = model_catalog.Provider{ .fetch_fn = fetchCatalog };

fn fetchCliCatalog(_: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .endpoint = models_url,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .failed => |failure| .{ .failure = failure },
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{ .ids = ids, .provenance = loaded.provenance } };
        },
    };
}

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{ .fetch_fn = fetchCliCatalog };

test "Responses request keeps OpenCode Go wire details provider-local" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "opencode-go/deepseek-v4-flash",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}},{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"description\":\"Search\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-v4-flash\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "inputSchema") == null);
    try std.testing.expect(std.mem.find(u8, body, "perplexity_search") == null);
}

test "Responses request accepts an optional vision tool without images" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "opencode-go/deepseek-v4-flash",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .vision_mode = .optional,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-v4-flash\"") != null);
}

test "Responses request refuses a required vision route" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    try std.testing.expectError(
        error.OpenCodeGoVisionUnavailable,
        agent_stream_provider.build(std.testing.allocator, .{
            .model = "opencode-go/deepseek-v4-flash",
            .serialized_tools = "[]",
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{},
            .vision_mode = .required,
        }),
    );
}

test "OpenCode Go catalog receives its own namespace" {
    var entries = try parseCatalog(std.testing.allocator, "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5.2\",\"created\":42}]}");
    defer model_catalog.freeModelCatalog(std.testing.allocator, &entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("opencode-go/glm-5.2", entries.items[0].id);
    try std.testing.expect(entries.items[0].has_tool_use);
}

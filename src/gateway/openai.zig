const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const responses_transport = @import("responses_transport.zig");

const Allocator = std.mem.Allocator;

pub const default_base_url = "https://api.openai.com/v1";
pub const base_url_env = "OPENAI_BASE_URL";
const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = stream_completion,
};

pub fn fallback_capabilities(_: []const u8) model_capabilities.Capabilities {
    return .{ .supports_tool_use = true };
}

/// The caller owns the returned Responses endpoint.
pub fn responses_url(alloc: Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url, " \t\r\n");
    const without_trailing_slash = std.mem.trimEnd(u8, trimmed, "/");
    if (without_trailing_slash.len == 0) return error.InvalidOpenAIBaseUrl;
    const uri = std.Uri.parse(without_trailing_slash) catch return error.InvalidOpenAIBaseUrl;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidOpenAIBaseUrl;
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !gateway_client.isLoopbackHttpUrl(without_trailing_slash)) {
        return error.InvalidOpenAIBaseUrl;
    }
    return std.fmt.allocPrint(alloc, "{s}/responses", .{without_trailing_slash});
}

fn configured_base_url() []const u8 {
    return io_mod.getenv(base_url_env) orelse default_base_url;
}

fn validate_model(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAIModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAIModel;
    }
}

pub fn build_request(alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    try validate_model(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }
    if (instructions.written().len == 0) try instructions.writer.writeAll("You are a helpful assistant.");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try responses_protocol.writeInput(writer, alloc, request.messages, request.verified_images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    });
    try writer.writeByte(']');
    _ = try responses_protocol.writeTools(writer, alloc, request.tools);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true,\"include\":[\"reasoning.encrypted_content\"]");
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn stream_completion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.credential.source != .openai_api_key) {
        return stream_provider.failResult(error.OpenAIApiKeyRequired);
    }
    const payload = try build_request(alloc, request.data());
    defer alloc.free(payload);
    const endpoint = try responses_url(alloc, configured_base_url());
    defer alloc.free(endpoint);
    return responses_transport.stream(alloc, request, payload, .{
        .endpoint = endpoint,
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
        .max_error_body_bytes = max_error_body_bytes,
        .error_limit_message = "OpenAI error response exceeded the local limit",
        .stream_limits = .{
            .line_bytes = max_sse_line_bytes,
            .aggregate_bytes = max_sse_aggregate_bytes,
            .events = max_sse_events,
            .tool_calls = max_tool_calls,
            .tool_identity_bytes = max_tool_identity_bytes,
            .tool_arguments_bytes = max_tool_arguments_bytes,
            .provider_state_bytes = max_provider_state_bytes,
        },
    });
}

test "OpenAI base URL appends Responses endpoint and rejects unsafe origins" {
    const url = try responses_url(std.testing.allocator, "https://proxy.example/v1/");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://proxy.example/v1/responses", url);
    const loopback = try responses_url(std.testing.allocator, "http://127.0.0.1:43123/v1");
    defer std.testing.allocator.free(loopback);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/responses", loopback);
    try std.testing.expectError(error.InvalidOpenAIBaseUrl, responses_url(std.testing.allocator, "http://proxy.example/v1"));
    try std.testing.expectError(error.InvalidOpenAIBaseUrl, responses_url(std.testing.allocator, "https://key@proxy.example/v1"));
    try std.testing.expectError(error.InvalidOpenAIBaseUrl, responses_url(std.testing.allocator, "https://proxy.example/v1?target=other"));
}

test "OpenAI request rejects unsafe model identifiers" {
    try std.testing.expectError(error.InvalidOpenAIModel, build_request(std.testing.allocator, .{
        .model = "gpt model",
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
    }));
}

test "OpenAI Responses request includes direct API limits and replay state" {
    const body = try build_request(std.testing.allocator, .{
        .model = "gpt-5.4",
        .messages = &.{.{ .role = .user, .content = "Hello" }},
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 400,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":400") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
}

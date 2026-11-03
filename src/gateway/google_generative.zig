//! Configured-provider transport for the native Google GenerateContent API.
//! OpenCode Zen supplies the x-api-key slot; the protocol itself is shared by
//! every configured definition that declares google-generative-ai.
const std = @import("std");
const protocol = @import("google_generative_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const chat = @import("chat_completions.zig");
const configured_request = @import("configured_request.zig");
const sse = @import("sse.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const Allocator = std.mem.Allocator;

pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = chat.model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

pub fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    return chat.bound_identity(definition);
}

pub fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return build_for(definition_at(raw), alloc, request);
}

pub fn build_for(definition: *const definitions.Definition, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const identity = bound_identity(definition);
    return protocol.build_request(alloc, request, .{ .provider = &identity });
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try protocol.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

fn endpoint_url(alloc: Allocator, definition: *const definitions.Definition, model: []const u8) Allocator.Error![]u8 {
    return alloc.print("{s}/models/{s}:streamGenerateContent?alt=sse", .{ definition.baseUrlFor(model), model });
}

fn auth_style(definition: *const definitions.Definition) chat.AuthStyle {
    return switch (definition.auth) {
        .none => .none,
        .bearer, .command, .login => if (definition.key_header == .x_api_key) .x_api_key else .bearer,
    };
}

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    try configured_request.checkToken(definition, token);
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const url = try endpoint_url(alloc, definition, request.model);
    defer alloc.free(url);
    return chat.post_url_auth(alloc, definition, url, request, token, payload, consume, auth_style(definition)) catch |err| {
        request.attempt_evidence.network_failure = @import("client.zig").networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
}

fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) anyerror!streams.Result {
    var limits: protocol.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return protocol.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return chat.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
}

test "native Google transport builds the Zen endpoint and wire body" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"zen":{"protocol":"google-generative-ai","base_url":"https://opencode.ai/zen/v1","auth":{"type":"login","header":"x-api-key"},"model_metadata":{"gemini-3-flash":{"reasoning_efforts":["minimal","low","medium","high"],"protocol":"google-generative-ai"}}}}
    );
    defer registry.deinit(alloc);
    const definition = registry.get("zen").?;
    const body = try build(@ptrCast(@constCast(definition)), alloc, .{
        .model = "gemini-3-flash",
        .instructions = &.{.{ .role = .system, .content = "Be concise." }},
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = .literal("high") },
        .max_output_tokens = 1024,
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "systemInstruction") != null);
    try std.testing.expect(std.mem.find(u8, body, "thinkingLevel") != null);
    const url = try endpoint_url(alloc, definition, "gemini-3-flash");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/models/gemini-3-flash:streamGenerateContent?alt=sse", url);
}

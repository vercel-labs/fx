//! A configured provider whose models speak different wire protocols, as
//! OpenCode Zen's do (D146): each request goes to the transport its model's
//! catalog entry names. Replay projection has no model, so it reads the
//! replay's shape, which each transport writes distinctly.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const types = @import("../core/shared/types.zig");
const chat_completions = @import("chat_completions.zig");
const anthropic_messages = @import("anthropic_messages.zig");
const anthropic_codec = @import("anthropic_messages_protocol.zig");
const openai_responses = @import("openai_responses.zig");
const Allocator = std.mem.Allocator;

pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = chat_completions.model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat_completions.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn protocol_at(raw: ?*anyopaque, model: []const u8) definitions.Protocol {
    const definition: *const definitions.Definition = @ptrCast(@alignCast(raw.?));
    return definition.protocolFor(model);
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) anyerror![]u8 {
    return switch (protocol_at(raw, request.model)) {
        .@"openai-chat-completions" => chat_completions.build(raw, alloc, request),
        .@"anthropic-messages" => anthropic_messages.build(raw, alloc, request),
        .@"openai-responses" => openai_responses.build(raw, alloc, request),
    };
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) anyerror!streams.Result {
    return switch (protocol_at(raw, request.model)) {
        .@"openai-chat-completions" => chat_completions.stream(raw, alloc, request),
        .@"anthropic-messages" => anthropic_messages.stream(raw, alloc, request),
        .@"openai-responses" => openai_responses.stream(raw, alloc, request),
    };
}

/// Responses replays are JSON arrays, Messages replays carry the thinking
/// field, and Chat Completions replays are the remaining objects.
pub fn replayProtocol(parts_json: []const u8) definitions.Protocol {
    const trimmed = std.mem.trimStart(u8, parts_json, " \t\r\n");
    if (trimmed.len != 0 and trimmed[0] == '[') return .@"openai-responses";
    if (std.mem.find(u8, parts_json, "\"" ++ anthropic_codec.thinking_field ++ "\"") != null) return .@"anthropic-messages";
    return .@"openai-chat-completions";
}

fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) anyerror!?types.ProviderReplay {
    const value = replay orelse return null;
    return switch (replayProtocol(value.parts_json)) {
        .@"openai-chat-completions" => chat_completions.project_replay(alloc, replay, calls, text, reasoning),
        .@"anthropic-messages" => anthropic_messages.project_replay(alloc, replay, calls, text, reasoning),
        .@"openai-responses" => openai_responses.project_replay(alloc, replay, calls, text, reasoning),
    };
}

fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) anyerror!classifier.ParseOutcome {
    const definition: *const definitions.Definition = @ptrCast(@alignCast(raw.?));
    const model = chat_completions.reviewerModel(definition, input, request);
    return switch (definition.protocolFor(model)) {
        .@"openai-chat-completions" => chat_completions.review(raw, alloc, input, request),
        .@"anthropic-messages" => anthropic_messages.review(raw, alloc, input, request),
        .@"openai-responses" => openai_responses.review(raw, alloc, input, request),
    };
}

test "routed provider sends each model through its catalog protocol" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"zen":{"protocol":"openai-chat-completions","base_url":"https://opencode.ai/zen/v1","auth":{"type":"login","header":"x-api-key"},"reasoning_format":"openai",
        \\"model_metadata":{"claude":{"protocol":"anthropic-messages","max_output_tokens":1000},"gpt":{"protocol":"openai-responses"},"glm":{"reasoning_efforts":["high"]}}}}
    );
    defer registry.deinit(alloc);
    const adapter = bundle(registry.get("zen").?).agent_stream.?;
    const Case = struct { model: []const u8, marker: []const u8 };
    for ([_]Case{
        .{ .model = "claude", .marker = "\"max_tokens\":1000" },
        .{ .model = "gpt", .marker = "\"input\":[" },
        .{ .model = "glm", .marker = "\"reasoning_effort\":\"high\"" },
    }) |case| {
        const body = try adapter.build_request_fn.?(adapter.context, alloc, .{
            .model = case.model,
            .instructions = &.{.{ .role = .system, .content = "sys" }},
            .messages = &.{.{ .role = .user, .content = "hi" }},
            .tool_choice = .auto,
            .provider_options = if (std.mem.eql(u8, case.model, "glm")) .{ .reasoning = .literal("high") } else .{},
        });
        defer alloc.free(body);
        if (std.mem.find(u8, body, case.marker) == null) {
            std.debug.print("model {s} body {s}\n", .{ case.model, body });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(definitions.Protocol.@"openai-responses", replayProtocol(" [{\"type\":\"reasoning\"}]"));
    try std.testing.expectEqual(definitions.Protocol.@"anthropic-messages", replayProtocol("{\"anthropic_thinking\":[],\"_tool_call_ids\":[]}"));
    try std.testing.expectEqual(definitions.Protocol.@"openai-chat-completions", replayProtocol("{\"reasoning_details\":[],\"_tool_call_ids\":[]}"));
}

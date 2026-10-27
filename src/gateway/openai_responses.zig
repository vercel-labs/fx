//! OpenAI Responses transport for configured providers such as OpenCode Zen
//! (D147). The body and the stream reducer are the Codex ones; only the
//! endpoint, the bearer key, the replay authority and two request fields
//! differ, so the public API's `max_output_tokens` is sent and Codex's
//! `text.verbosity` is not.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const responses_protocol = @import("responses_protocol.zig");
const openai_codex = @import("openai_codex.zig");
const chat_completions = @import("chat_completions.zig");
const configured_request = @import("configured_request.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
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
    return openai_codex.buildRequestWith(alloc, request, .{
        .provider = chat_completions.bound_identity(definition),
        .verbosity = false,
        .max_output_tokens = true,
    });
}

pub const project_replay = responses_protocol.selectReplayParts;

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) anyerror!streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    try configured_request.checkToken(definition, token);
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const url = try definition.responses_url(alloc);
    defer alloc.free(url);
    return chat_completions.post_url(alloc, definition, url, request, token, payload, consume);
}

fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) anyerror!streams.Result {
    return openai_codex.completeFromStream(alloc, request, reader, progress);
}

pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return chat_completions.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
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
    const url = try definition.responses_url(alloc);
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/responses", url);
}

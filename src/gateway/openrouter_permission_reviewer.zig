const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const openrouter = @import("openrouter.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

/// The reviewer adapter is protocol-agnostic: it only needs a request builder
/// and a sender, so the Chat Completions route reuses it unchanged.
pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewOpenRouter,
};

fn reviewOpenRouter(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .openrouter_api_key,
        // OpenRouter has no dedicated small reviewer model, so reviews run on
        // whatever model the turn already selected.
        .model = request.review_turn.model,
        .require_account = false,
        .validate_fn = validateCredential,
        .build_fn = openrouter.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    if (input.credential.len == 0) return error.InvalidCredential;
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return openrouter.streamPrepared(alloc, request, payload);
}

test "OpenRouter reviewer builds a chat-completions request with the admitted model" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User requested the change." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "call_review",
                .name = "write_file",
                .arguments_json = "{\"path\":\"a.txt\"}",
            }},
        },
        .{ .role = .system, .content = "Review the pending action." },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const body = try responses_reviewer.buildPayloadForTest(
        std.testing.allocator,
        "z-ai/glm-5.2:free",
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(@import("../core/shared/io.zig").getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        openrouter.buildRequest,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"z-ai/glm-5.2:free\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
    // Tool results travel as `role":"tool"` on this wire format, not as the
    // Responses API's function_call_output items.
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "function_call_output") == null);
    try std.testing.expect(std.mem.find(u8, body, "ai-gateway") == null);
}

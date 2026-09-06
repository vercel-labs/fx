const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const xai_grok = @import("xai_grok.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;
const reviewer_model = "grok-4.5";

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewGrok,
};

fn reviewGrok(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .grok_subscription,
        .model = reviewer_model,
        .require_account = true,
        .validate_fn = validateCredential,
        .build_fn = xai_grok.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    if (!grok_session.validAccountId(input.account_id orelse return error.InvalidAccount)) {
        return error.InvalidAccount;
    }
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return xai_grok.streamPrepared(alloc, request, payload);
}

test "Grok reviewer builds a direct Responses request with grok-4.5" {
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Review the pending action." }};
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
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const body = try responses_reviewer.buildPayloadForTest(
        std.testing.allocator,
        reviewer_model,
        &instructions,
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(@import("../core/shared/io.zig").getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        xai_grok.buildRequest,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"grok-4.5\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "ai-gateway") == null);
}

const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const session_usage = @import("../core/session/session_usage.zig");
const anthropic_claude = @import("anthropic_claude.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewClaude,
};

const ReviewConfig = struct {
    credential: []const u8,
    account_id: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
};

fn reviewClaude(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    if (input.credential.len == 0) return .invalid;
    const account_id = input.account_id orelse return .invalid;
    var config = ReviewConfig{
        .credential = input.credential,
        .account_id = account_id,
        .cancel_flag = input.cancel_flag,
        .usage = input.usage,
        .usage_allocator = input.usage_allocator,
    };
    return permission_auto_classifier.Reviewer.withTransportModel(
        .{
            .context = @ptrCast(&config),
            .build_fn = buildReviewPayload,
            .send_fn = sendReview,
        },
        config.cancel_flag,
        permission_auto_classifier.Reviewer.default_timeout_ms,
        request.review_turn.model,
    ).review(alloc, request);
}

fn buildReviewPayload(
    _: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    tools_json: []const u8,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const expanded = try gateway_json.expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);
    return anthropic_claude.agent_stream_provider.build(alloc, .{
        .model = model,
        .serialized_tools = tools_json,
        .messages = expanded,
        .tool_choice = .required,
        .provider_options = .{},
        .max_output_tokens = 2048,
        .budget = .{ .deadline = deadline, .cancel_flag = cancel_flag },
    });
}

const OwnedResult = struct {
    result: stream_provider.Result,
};

fn deinitOwnedResult(raw: *anyopaque, alloc: Allocator) void {
    const owned: *OwnedResult = @ptrCast(@alignCast(raw));
    owned.result.deinit(alloc);
    alloc.destroy(owned);
}

fn ignoreChunk(_: *anyopaque, _: []const u8) void {}

fn sendReview(
    raw: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !permission_auto_classifier.TransportOutcome {
    const config: *ReviewConfig = @ptrCast(@alignCast(raw));
    if (cancel_flag.load(.seq_cst)) return .cancelled;
    if (std.Io.Clock.Timestamp.now(@import("../core/shared/io.zig").getIo(), .awake).raw.nanoseconds >=
        deadline.raw.nanoseconds)
    {
        return .timed_out;
    }
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    const usage_observation = try session_usage.GatewayObservation.begin(config.usage);
    var result = anthropic_claude.streamHttpCompletion(alloc, .{
        .api_key = config.credential,
        .credential_source = .claude_subscription,
        .account_id = config.account_id,
        .team = null,
        .model = model,
        .retry_count = 1,
        .chat_url = "",
        .payload = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .callback_ctx = @ptrCast(&callback_context),
        .on_content_chunk = ignoreChunk,
        .on_tool_start = null,
        .on_reasoning_chunk = null,
        .cancel_flag = cancel_flag,
        .provider_attempt_owner = .transport,
    }) catch |err| {
        usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled) catch return .permanent_failure;
        return mapStreamError(err, cancel_flag);
    };
    var result_owned = true;
    defer if (result_owned) result.deinit(alloc);
    usage_observation.complete(
        config.usage_allocator,
        result.status,
        result.completion,
        "https://api.anthropic.com/v1",
        null,
    ) catch return .permanent_failure;
    if (cancel_flag.load(.seq_cst)) return .cancelled;
    if (result.status != .ok) {
        const code: u16 = @intFromEnum(result.status);
        return if (code == 408 or code == 425 or code == 429 or code >= 500)
            .transient_failure
        else
            .permanent_failure;
    }
    if (result.completion.finish_reason) |reason| switch (reason) {
        .provider_error => return .transient_failure,
        .content_filter => return .permanent_failure,
        .stop, .length, .tool_calls, .other => {},
    };
    const owned = try alloc.create(OwnedResult);
    owned.* = .{ .result = result };
    result_owned = false;
    return .{ .completion = .{
        .completion = owned.result.completion,
        .context = @ptrCast(owned),
        .deinit_fn = deinitOwnedResult,
    } };
}

fn mapStreamError(
    err: anyerror,
    cancel_flag: *std.atomic.Value(bool),
) error{OutOfMemory}!permission_auto_classifier.TransportOutcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.Cancelled or cancel_flag.load(.seq_cst)) return .cancelled;
    if (err == error.Timeout) return .timed_out;
    return .transient_failure;
}

test "Claude reviewer builds a direct Messages request with the admitted model" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User requested the change." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "toolu_review",
                .name = "write_file",
                .arguments_json = "{\"path\":\"a.txt\"}",
            }},
        },
        .{ .role = .system, .content = "Review the pending action." },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var context: u8 = 0;
    const body = try buildReviewPayload(
        @ptrCast(&context),
        std.testing.allocator,
        "claude-sonnet-4-5",
        "[{\"type\":\"function\",\"name\":\"permission_decision\"}]",
        &messages,
        "toolu_review",
        std.Io.Clock.Timestamp.fromNow(@import("../core/shared/io.zig").getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"messages\"") != null);
}

test "Claude reviewer maps an enforced stream deadline to fail-closed timeout" {
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(
        permission_auto_classifier.TransportOutcome.timed_out,
        try mapStreamError(error.Timeout, &cancelled),
    );
}

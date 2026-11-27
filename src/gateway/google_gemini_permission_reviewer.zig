const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const google_gemini = @import("google_gemini.zig");
const google_gemini_models = @import("google_gemini_models.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewGoogle,
};

fn reviewGoogle(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return reviewWithSend(alloc, input, request, sendPrepared);
}

fn reviewWithSend(
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
    send_fn: responses_reviewer.SendFn,
) !permission_auto_classifier.ParseOutcome {
    const source: types.CredentialSource = switch (input.credential_source orelse .gemini_api_key) {
        .google_subscription => .google_subscription,
        else => .gemini_api_key,
    };
    return responses_reviewer.review(alloc, input, request, .{
        .source = source,
        .model = reviewerModel(input),
        .validate_fn = validateCredential,
        .build_fn = google_gemini.buildRequest,
        .send_fn = send_fn,
    });
}

fn reviewerModel(input: permission_auto_classifier.ProviderInput) []const u8 {
    if (input.reviewer_model.len > 0) return input.reviewer_model;
    return google_gemini_models.title_model;
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    const source = input.credential_source orelse return error.InvalidGeminiCredentialSource;
    if (source != .gemini_api_key and source != .google_subscription) {
        return error.InvalidGeminiCredentialSource;
    }
    if (!google_gemini.validApiKey(input.credential)) return error.InvalidGeminiApiKey;
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return google_gemini.streamPrepared(alloc, request, payload);
}

fn decisionCompletion(comptime arguments_json: []const u8) stream_provider.Result {
    return .{ .completed = .{
        .completion = .{
            .generation_id = "google-review",
            .finish_reason = .tool_calls,
            .tool_calls = &.{.{
                .id = "call_decision",
                .name = permission_auto_classifier.tool_name,
                .arguments_json = arguments_json,
            }},
        },
    } };
}

fn testRequest() permission_auto_classifier.ReviewRequest {
    const pending = types.ChatMessage{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "call_review",
            .name = "write_file",
            .arguments_json = "{\"path\":\"a.txt\"}",
        }},
    };
    return .{
        .review_turn = .{
            .model = "gemini-4-hydrogen",
            .pending_assistant = pending,
            .target_call_id = "call_review",
            .origin = .root,
            .trusted_root_context = "User asked to change a.txt.",
        },
        .targets = &.{},
        .action = .{ .tool = .{
            .tool_name = "write_file",
            .arguments_json = "{\"path\":\"a.txt\"}",
        } },
    };
}

fn testInput(reviewer_model: []const u8) permission_auto_classifier.ProviderInput {
    return .{
        .credential = "test-key",
        .credential_source = .gemini_api_key,
        .reviewer_model = reviewer_model,
    };
}

test "Google reviewer request carries the forced decision tool and no response_format" {
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
        google_gemini_models.title_model,
        &instructions,
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        google_gemini.buildRequest,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gemini-3.5-flash-lite\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"permission_decision\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"any\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"response_format\"") == null);
}

test "Google reviewer sends each review to gemini-3.5-flash-lite with the forced decision tool" {
    const Fake = struct {
        var model: []const u8 = "";
        var has_decision_tool = false;
        var has_tool_choice_any = false;
        var has_response_format = true;

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            payload: []const u8,
        ) anyerror!stream_provider.Result {
            try request.admission.admit();
            model = request.model;
            has_decision_tool = std.mem.find(u8, payload, "\"name\":\"permission_decision\"") != null;
            has_tool_choice_any = std.mem.find(u8, payload, "\"tool_choice\":\"any\"") != null;
            has_response_format = std.mem.find(u8, payload, "\"response_format\"") != null;
            return decisionCompletion("{\"decision\":\"clear\",\"rationale\":\"Routine edit.\"}");
        }
    };
    var outcome = try reviewWithSend(std.testing.allocator, testInput(""), testRequest(), Fake.send);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gemini-3.5-flash-lite", Fake.model);
    try std.testing.expect(Fake.has_decision_tool);
    try std.testing.expect(Fake.has_tool_choice_any);
    try std.testing.expect(!Fake.has_response_format);
    try std.testing.expectEqual(permission_auto_classifier.HostDisposition.clear, permission_auto_classifier.hostDisposition(outcome));
}

test "Google reviewer uses the reviewer_model override when one is given" {
    const Fake = struct {
        var model: []const u8 = "";

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            _: []const u8,
        ) anyerror!stream_provider.Result {
            try request.admission.admit();
            model = request.model;
            return decisionCompletion("{\"decision\":\"clear\"}");
        }
    };
    var outcome = try reviewWithSend(std.testing.allocator, testInput("gemini-4-carbon"), testRequest(), Fake.send);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gemini-4-carbon", Fake.model);
    try std.testing.expectEqual(permission_auto_classifier.HostDisposition.clear, permission_auto_classifier.hostDisposition(outcome));
}

test "Google reviewer reports a failed transport call as unavailable" {
    const Fake = struct {
        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            _: []const u8,
        ) anyerror!stream_provider.Result {
            try request.admission.admit();
            return error.ConnectionRefused;
        }
    };
    var outcome = try reviewWithSend(std.testing.allocator, testInput(""), testRequest(), Fake.send);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(permission_auto_classifier.HostDisposition.unavailable, permission_auto_classifier.hostDisposition(outcome));
}

test "Google reviewer reports a rejected transport request as unavailable" {
    const Fake = struct {
        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            _: []const u8,
        ) anyerror!stream_provider.Result {
            try request.admission.admit();
            return .{ .failed = .{ .kind = .unauthorized } };
        }
    };
    var outcome = try reviewWithSend(std.testing.allocator, testInput(""), testRequest(), Fake.send);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(permission_auto_classifier.HostDisposition.unavailable, permission_auto_classifier.hostDisposition(outcome));
}

test "Google reviewer refuses a credential that is not a Gemini API key" {
    const Fake = struct {
        fn send(
            _: Allocator,
            _: stream_provider.ModelRequest,
            _: []const u8,
        ) anyerror!stream_provider.Result {
            return error.TestUnexpectedSend;
        }
    };
    var input = testInput("");
    input.credential_source = .grok_subscription;
    var outcome = try reviewWithSend(std.testing.allocator, input, testRequest(), Fake.send);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(permission_auto_classifier.HostDisposition.unavailable, permission_auto_classifier.hostDisposition(outcome));
}

test "Google reviewer accepts the Google plan source and routes it as google_subscription" {
    const Fake = struct {
        var seen_source: ?types.CredentialSource = null;
        var seen_secret: []const u8 = "";

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            _: []const u8,
        ) anyerror!stream_provider.Result {
            try request.admission.admit();
            seen_source = request.credential.credentialSource();
            seen_secret = request.credential.secret() orelse "";
            return decisionCompletion("{\"decision\":\"clear\",\"rationale\":\"Routine edit.\"}");
        }
    };
    var input = testInput("");
    input.credential = "ya29.plan-review-token";
    input.credential_source = .google_subscription;
    var outcome = try reviewWithSend(std.testing.allocator, input, testRequest(), Fake.send);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?types.CredentialSource, .google_subscription), Fake.seen_source);
    try std.testing.expectEqualStrings("ya29.plan-review-token", Fake.seen_secret);
    try std.testing.expectEqual(permission_auto_classifier.HostDisposition.clear, permission_auto_classifier.hostDisposition(outcome));
}

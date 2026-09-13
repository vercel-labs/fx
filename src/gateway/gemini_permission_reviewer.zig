const std = @import("std");
const classifier = @import("../core/permissions/auto_classifier.zig");
const stream = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const reviewer = @import("responses_permission_reviewer.zig");
const gemini = @import("gemini.zig");
const models = @import("gemini_models.zig");
pub const provider = classifier.Provider{ .review_fn = review };
fn review(_: ?*anyopaque, alloc: std.mem.Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return reviewer.review(alloc, input, request, .{
        .source = .gemini_api_key,
        .model = models.reviewer_model,
        .validate_fn = validate,
        .build_fn = build,
        .send_fn = gemini.streamPrepared,
    });
}
fn validate(_: std.mem.Allocator, input: classifier.ProviderInput) !void {
    if (input.credential_source != .gemini_api_key or input.credential.len == 0) return error.GeminiApiKeyRequired;
}
fn build(alloc: std.mem.Allocator, request: stream.RequestData) ![]u8 {
    // Review evidence contains synthetic calls. Send it as data, not Google history.
    const evidence = try std.json.Stringify.valueAlloc(alloc, request.messages, .{});
    defer alloc.free(evidence);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = evidence }};
    var adapted = request;
    adapted.messages = &messages;
    adapted.provider_options.reasoning = .literal("low");
    return gemini.buildRequest(alloc, adapted);
}

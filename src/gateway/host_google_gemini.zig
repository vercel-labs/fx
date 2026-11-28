//! Google Gemini model requests sent through a host transport, for runtimes
//! such as libfx whose network access belongs to the host. The request and its
//! parsing are the CLI's own; only the HTTP client differs. The host adds the
//! Gemini API key header; only the API key route is supported today.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const chat_completions_protocol = @import("chat_completions_protocol.zig");
const gemini_interactions_protocol = @import("gemini_interactions_protocol.zig");
const google_gemini = @import("google_gemini.zig");
const google_gemini_models = @import("google_gemini_models.zig");
const host_stream = @import("host_stream_provider.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    transport: host_stream.Transport,
};

/// The context must outlive every stream started through the provider.
pub fn provider(context: *Context) stream_provider.Provider {
    return .{
        .context = context,
        .stream_fn = stream,
        .build_request_fn = buildRequest,
        .project_replay_fn = gemini_interactions_protocol.project_replay,
    };
}

/// Fixed Google catalog; needs no host fetch.
pub const model_catalog_provider = google_gemini_models.model_catalog_provider;

fn buildRequest(_: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    return google_gemini.buildRequest(alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    const route = google_gemini.routeForCredential(request.credential.credentialSource()) orelse {
        return stream_provider.failResult(error.GeminiCredentialRequired);
    };
    return streamForRoute(raw, alloc, request, route);
}

fn streamForRoute(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    route: google_gemini.Route,
) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    // The host transport contract carries only the API key route today.
    if (route != .api_key) {
        return stream_provider.failResult(error.GooglePlanRouteUnsupported);
    }
    if (request.credential.credentialSource() != .host_managed) {
        return stream_provider.failResult(error.GeminiCredentialRequired);
    }
    _ = google_gemini.resolveThinkingLevel(request.model, request.provider_options.reasoning) catch |err| {
        return stream_provider.failResult(err);
    };

    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const payload = request.prepared_request_body orelse
        try google_gemini.buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);

    const endpoint = google_gemini.interactionsEndpoint(alloc) catch |err| return stream_provider.failResult(err);
    defer alloc.free(endpoint);

    var extra_buf: [google_gemini.max_extra_headers]std.http.Header = undefined;
    const extra = google_gemini.extraHeaders(&extra_buf, null);
    var headers_buf: [google_gemini.max_extra_headers + 1]std.http.Header = undefined;
    headers_buf[0] = .{ .name = "content-type", .value = "application/json" };
    @memcpy(headers_buf[1..][0..extra.len], extra);

    const opened = try host_stream.openPost(alloc, transport, request, endpoint, headers_buf[0 .. extra.len + 1], payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) {
        return mapHttpError(alloc, transport, opened, request, route);
    }

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = gemini_interactions_protocol.consume_stream(
        alloc,
        &reader.interface,
        request.data(),
        .{},
        request.events,
        request.cancel_flag,
        null,
    ) catch |err| switch (err) {
        error.ReadFailed => return host_stream.readFailure(&reader, request.cancel_flag),
        else => return err,
    };
    switch (result) {
        .completed => |completed| host_stream.signalConsumed(transport, opened.handle, request, completed.completion),
        else => {},
    }
    return result;
}

fn mapHttpError(
    alloc: Allocator,
    transport: host_stream.Transport,
    opened: host_stream.OpenedPost,
    request: stream_provider.ModelRequest,
    route: google_gemini.Route,
) !stream_provider.Result {
    const body = try host_stream.readErrorBody(alloc, transport, opened.handle, request);
    defer alloc.free(body);
    var retry_after_buf: [32]u8 = undefined;
    const retry_after_str: ?[]const u8 = if (opened.retry_after_seconds) |secs|
        std.mem.print(&retry_after_buf, "{d}", .{secs}) catch null
    else
        null;
    const plan = try google_gemini.classifyHttpFailure(
        alloc,
        route,
        opened.status,
        if (body.len > google_gemini.max_error_body_bytes) "" else body,
        retry_after_str,
        request.credential.secret(),
    );
    defer if (plan.interactive_message) |msg| alloc.free(msg);
    const detail = try chat_completions_protocol.redactOwnedErrorBody(
        alloc,
        plan.message,
        request.credential.secret(),
    );
    return .{ .failed = .{
        .kind = plan.kind,
        .http_status = opened.status,
        .detail = detail,
        .retry_after_seconds = plan.retry_after_seconds,
        .ownership = .owned,
    } };
}

const FakeTransport = @import("host_transport_testing.zig").FakeTransport;

const reply_sse =
    "event: interaction.created\n" ++
    "data: {\"event_type\":\"interaction.created\",\"interaction\":{\"id\":\"int_1\",\"status\":\"in_progress\",\"object\":\"interaction\",\"model\":\"gemini-4-hydrogen\"}}\n\n" ++
    "event: step.start\n" ++
    "data: {\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"model_output\"}}\n\n" ++
    "event: step.delta\n" ++
    "data: {\"event_type\":\"step.delta\",\"index\":0,\"delta\":{\"type\":\"text\",\"text\":\"libfx on google\"}}\n\n" ++
    "event: step.stop\n" ++
    "data: {\"event_type\":\"step.stop\",\"index\":0}\n\n" ++
    "event: interaction.completed\n" ++
    "data: {\"event_type\":\"interaction.completed\",\"interaction\":{\"id\":\"int_1\",\"status\":\"completed\",\"usage\":{\"total_input_tokens\":23,\"total_output_tokens\":7}}}\n\n" ++
    "event: done\n" ++
    "data: [DONE]\n\n";

test "host Google stream sends the CLI's request to /v1beta/interactions without credentials and parses the reply" {
    var fake = FakeTransport{
        .model = "gemini-4-hydrogen",
        .prepared_body = "{\"model\":\"gemini-4-hydrogen\",\"store\":false,\"stream\":true}",
        .responses = &.{.{ .status = 200, .body = reply_sse }},
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("POST", fake.methods[0]);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/interactions", fake.urls[0]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"}," ++
            "{\"name\":\"accept\",\"value\":\"text/event-stream\"}]",
        fake.headers[0],
    );
    try std.testing.expectEqualStrings(fake.prepared_body, fake.bodies[0]);
    try std.testing.expectEqualStrings("libfx on google", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
    try std.testing.expectEqual(@as(usize, 1), fake.closed);
}

test "host Google stream maps a 429 daily-limit body to the same failure as the CLI path" {
    const daily_body =
        \\{"error":{"code":"too_many_requests","message":"You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models."}}
    ;
    var fake = FakeTransport{
        .model = "gemini-4-hydrogen",
        .responses = &.{.{ .status = 429, .body = daily_body, .retry_after = 19104 }},
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(stream_provider.FailureKind.quota_exhausted, result.failed.kind);
    try std.testing.expectEqual(std.http.Status.too_many_requests, result.failed.http_status.?);
    try std.testing.expectEqual(@as(?u64, 19104), result.failed.retry_after_seconds);
    try std.testing.expectEqualStrings(
        "Daily limit reached for gemini-4-hydrogen; resets in 5 h 18 min. Switch models or try again after reset.",
        result.failed.detail.?,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(@as(usize, 1), fake.closed);
}

test "host Google stream maps a 429 rate-limit body like the CLI path" {
    const rate_body = "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"Requests per minute limit exceeded.\"}}";
    var fake = FakeTransport{
        .model = "gemini-4-hydrogen",
        .responses = &.{.{ .status = 429, .body = rate_body, .retry_after = 7 }},
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(stream_provider.FailureKind.rate_limited, result.failed.kind);
    try std.testing.expectEqual(std.http.Status.too_many_requests, result.failed.http_status.?);
    try std.testing.expectEqual(@as(?u64, 7), result.failed.retry_after_seconds);
    try std.testing.expectEqualStrings("Rate limited by Gemini; retry in 7 s.", result.failed.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(@as(usize, 1), fake.closed);
}

test "host Google stream refuses non-host credentials and unsupported effort without sending" {
    const types = @import("../core/shared/types.zig");
    var fake = FakeTransport{
        .model = "gemini-4-carbon",
        .responses = &.{.{ .status = 200, .body = reply_sse }},
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };

    const gateway_lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "gateway-key", .source = .ai_gateway_api_key } };
    try std.testing.expectError(
        error.GeminiCredentialRequired,
        provider(&context).stream(std.testing.allocator, fake.request(gateway_lease)),
    );
    const direct_gemini: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "gemini-key", .source = .gemini_api_key } };
    try std.testing.expectError(
        error.GeminiCredentialRequired,
        provider(&context).stream(std.testing.allocator, fake.request(direct_gemini)),
    );

    var bad_effort = fake.request(.host_managed);
    bad_effort.provider_options = .{ .reasoning = types.ReasoningEffort.literal("xhigh") };
    try std.testing.expectError(
        error.UnsupportedGoogleThinkingLevel,
        provider(&context).stream(std.testing.allocator, bad_effort),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host Google stream fails closed on the plan route without sending" {
    var fake = FakeTransport{
        .model = "gemini-4-hydrogen",
        .responses = &.{.{ .status = 200, .body = reply_sse }},
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    try std.testing.expectError(
        error.GooglePlanRouteUnsupported,
        streamForRoute(&context, std.testing.allocator, fake.request(.host_managed), .plan),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host Google catalog returns the fixed Google table without a host fetch" {
    const result = try model_catalog_provider.fetch(std.testing.allocator, .{
        .access = .host_managed,
        .endpoint = "",
        .view = .picker,
    });
    var catalog = result.catalog;
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 4), catalog.items.len);
    try std.testing.expectEqualStrings("gemini-4-hydrogen", catalog.items[0].id);
}

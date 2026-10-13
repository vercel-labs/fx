//! Codex (ChatGPT subscription) model requests sent through a host transport,
//! for runtimes such as libfx whose network access belongs to the host. The
//! request and its parsing are the CLI's own; only the HTTP client differs.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const versions = @import("../core/gateway/provider_versions.zig");
const responses_protocol = @import("responses_protocol.zig");
const host_stream = @import("host_stream_provider.zig");
const host_model_catalog = @import("host_model_catalog.zig");
const openai_codex = @import("openai_codex.zig");
const openai_codex_models = @import("openai_codex_models.zig");
const version_lookup = @import("provider_versions.zig");

const Allocator = std.mem.Allocator;
const max_version_bytes = 64 * 1024;

pub const Context = struct {
    transport: host_stream.Transport,
};

/// The context must outlive every stream started through the provider.
pub fn provider(context: *Context) stream_provider.Provider {
    return .{
        .context = context,
        .stream_fn = stream,
        .build_request_fn = buildRequest,
        .project_replay_fn = responses_protocol.selectReplayParts,
    };
}

/// Loads the account's Codex models. Only host-managed access is supported:
/// the host adds the account's credentials to the request.
pub fn modelCatalogProvider(context: *Context) model_catalog.Provider {
    return .{
        .context = context,
        .fetch_fn = fetchCatalog,
        .provider_id = .codex,
        .refresh_interval_ms = versions.refresh_interval_ms,
    };
}

fn fetchCatalog(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    if (input.access != .host_managed) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const headers = [_]std.http.Header{.{ .name = "originator", .value = "fx" }};

    const version_url = version_lookup.versionUrl(.codex) catch
        return .{ .failure = .{ .category = .runtime } };
    const version_body = switch (try host_model_catalog.get(alloc, context.transport, version_url, &.{}, input.cancel_flag, max_version_bytes)) {
        .body => |body| body,
        .failure => |failure| return .{ .failure = .{
            .category = if (failure.category == .cancellation) .cancellation else .transport,
            .retryable = failure.category != .cancellation,
        } },
    };
    defer alloc.free(version_body);
    const version = version_lookup.parseResponse(alloc, .codex, version_body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    };

    const url = openai_codex_models.modelsUrl(alloc, version) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(url);
    const body = switch (try host_model_catalog.get(alloc, context.transport, url, &headers, input.cancel_flag, openai_codex_models.max_catalog_bytes)) {
        .body => |body| body,
        .failure => |failure| return .{ .failure = failure },
    };
    defer alloc.free(body);
    return openai_codex_models.catalogFromBody(alloc, body);
}

fn buildRequest(_: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    return openai_codex.buildRequest(alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (!openai_codex.acceptsCredential(request.credential)) {
        return stream_provider.failResult(error.CodexSubscriptionCredentialRequired);
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const payload = request.prepared_request_body orelse
        try openai_codex.buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const endpoint = openai_codex.responsesEndpoint() catch |err| return stream_provider.failResult(err);

    var auth = try openai_codex.requestAuthHeaders(alloc, request.credential);
    defer auth.deinit(alloc);
    var extra_buf: [openai_codex.max_extra_headers]std.http.Header = undefined;
    const extra = openai_codex.extraHeaders(&extra_buf, auth.account_id, request.session_id);
    var headers_buf: [openai_codex.max_extra_headers + 2]std.http.Header = undefined;
    var count: usize = 0;
    headers_buf[count] = .{ .name = "content-type", .value = "application/json" };
    count += 1;
    if (auth.authorization) |value| {
        headers_buf[count] = .{ .name = "authorization", .value = value };
        count += 1;
    }
    @memcpy(headers_buf[count..][0..extra.len], extra);
    count += extra.len;

    const opened = try host_stream.openPost(alloc, transport, request, endpoint, headers_buf[0..count], payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) return .{ .failed = .{
        .kind = openai_codex.failureKind(opened.status),
        .detail = try host_stream.readErrorBody(alloc, transport, opened.handle, request),
        .ownership = .owned,
    } };

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = openai_codex.completeFromStream(alloc, request, &reader.interface) catch |err| switch (err) {
        error.ReadFailed => return host_stream.readFailure(&reader, request.cancel_flag),
        else => return err,
    };
    switch (result) {
        .completed => |completed| host_stream.signalConsumed(transport, opened.handle, request, completed.completion),
        else => {},
    }
    return result;
}

const FakeTransport = @import("host_transport_testing.zig").FakeTransport;

const reply_sse =
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\"}}\n\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"libfx ok\"}\n\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":23,\"output_tokens\":7}}}\n\n";

test "host Codex stream sends the CLI's request without credentials and parses the reply" {
    var fake = FakeTransport{ .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("POST", fake.methods[0]);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", fake.urls[0]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"}," ++
            "{\"name\":\"originator\",\"value\":\"fx\"}," ++
            "{\"name\":\"OpenAI-Beta\",\"value\":\"responses=experimental\"}," ++
            "{\"name\":\"accept\",\"value\":\"text/event-stream\"}," ++
            "{\"name\":\"session-id\",\"value\":\"session-1\"}," ++
            "{\"name\":\"x-client-request-id\",\"value\":\"session-1\"}]",
        fake.headers[0],
    );
    try std.testing.expectEqualStrings(fake.prepared_body, fake.bodies[0]);
    try std.testing.expectEqualStrings("libfx ok", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
    try std.testing.expectEqual(@as(usize, 1), fake.closed);
}

test "host Codex stream returns the error body of a rejected request" {
    var fake = FakeTransport{ .responses = &.{.{ .status = 401, .body = "{\"detail\":\"token expired\"}" }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, result.failed.kind);
    try std.testing.expectEqualStrings("{\"detail\":\"token expired\"}", result.failed.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(@as(usize, 1), fake.closed);
}

test "host Codex stream refuses a Gateway credential without sending" {
    var fake = FakeTransport{ .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "gateway-key", .source = .ai_gateway_api_key } };
    try std.testing.expectError(
        error.CodexSubscriptionCredentialRequired,
        provider(&context).stream(std.testing.allocator, fake.request(lease)),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host Codex catalog resolves the client version through the host" {
    const models =
        \\{"models":[
        \\  {"slug":"gpt-6.1-sol","visibility":"list","supported_in_api":true,"priority":1,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"additional_speed_tiers":[],"input_modalities":["text","image"],"context_window":272000},
        \\  {"slug":"gpt-5.6-luna","visibility":"list","supported_in_api":true,"priority":2,"supported_reasoning_levels":[{"effort":"low"}],"additional_speed_tiers":[],"input_modalities":["text"],"context_window":272000}
        \\]}
    ;
    var fake = FakeTransport{ .responses = &.{
        .{ .status = 200, .body = "{\"version\":\"0.162.1\",\"name\":\"@openai/codex\"}" },
        .{ .status = 200, .body = models },
    } };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    const result = try modelCatalogProvider(&context).fetch_fn(&context, std.testing.allocator, .{
        .access = .host_managed,
        .endpoint = "",
        .view = .picker,
    });
    var catalog = result.catalog;
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings("GET", fake.methods[0]);
    try std.testing.expectEqualStrings("https://registry.npmjs.org/@openai/codex/latest", fake.urls[0]);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/models?client_version=0.162.1", fake.urls[1]);
    try std.testing.expectEqualStrings("[{\"name\":\"originator\",\"value\":\"fx\"}]", fake.headers[1]);
    try std.testing.expectEqualStrings("gpt-6.1-sol", catalog.items[0].id);
}

test "host Codex catalog refuses access the host does not manage" {
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    const result = try modelCatalogProvider(&context).fetch_fn(&context, std.testing.allocator, .{ .endpoint = "" });
    try std.testing.expectEqual(model_catalog.FailureCategory.authentication, result.failure.category);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

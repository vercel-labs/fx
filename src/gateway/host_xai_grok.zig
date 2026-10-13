//! Grok (xAI subscription) model requests sent through a host transport, for
//! runtimes such as libfx whose network access belongs to the host. The
//! request and its parsing are the CLI's own; only the HTTP client differs.
//! The host adds the account's token and id; everything else is sent here.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const versions = @import("../core/gateway/provider_versions.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const responses_protocol = @import("responses_protocol.zig");
const host_stream = @import("host_stream_provider.zig");
const host_model_catalog = @import("host_model_catalog.zig");
const xai_grok = @import("xai_grok.zig");
const xai_grok_models = @import("xai_grok_models.zig");
const version_lookup = @import("provider_versions.zig");

const Allocator = std.mem.Allocator;
const max_version_bytes = 64 * 1024;

pub const Context = struct {
    transport: host_stream.Transport,
    /// The client version last fetched through the host, shared by streams and
    /// the model list, so each request does not fetch it again.
    version_mutex: std.Io.Mutex = .init,
    version: ?versions.Cached = null,
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

/// Loads the account's Grok models. Only host-managed access is supported:
/// the host adds the account's credentials to the request.
pub fn modelCatalogProvider(context: *Context) model_catalog.Provider {
    return .{
        .context = context,
        .fetch_fn = fetchCatalog,
        .provider_id = .grok,
        .refresh_interval_ms = versions.refresh_interval_ms,
    };
}

const VersionLookup = struct {
    transport: host_stream.Transport,
    cancel_flag: ?*std.atomic.Value(bool),

    fn fetch(raw: ?*anyopaque, alloc: Allocator, which: versions.Provider) versions.Error!versions.Version {
        const self: *VersionLookup = @ptrCast(@alignCast(raw.?));
        const url = version_lookup.versionUrl(which) catch return error.ProviderVersionUnavailable;
        const body = switch (try host_model_catalog.get(alloc, self.transport, url, &.{}, self.cancel_flag, max_version_bytes)) {
            .body => |body| body,
            .failure => |failure| return if (failure.category == .cancellation)
                error.Cancelled
            else
                error.ProviderVersionUnavailable,
        };
        defer alloc.free(body);
        return version_lookup.parseResponse(alloc, which, body) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.ProviderVersionUnavailable;
        };
    }
};

fn loadVersion(raw: ?*anyopaque, _: Allocator, _: versions.Provider) anyerror!?versions.Cached {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    return context.version;
}

fn saveVersion(raw: ?*anyopaque, _: Allocator, _: versions.Provider, cached: versions.Cached) anyerror!void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.version = cached;
}

/// The Grok client version, refetched through the host once the remembered
/// one is a minute old, and kept when a refetch fails.
fn clientVersion(context: *Context, alloc: Allocator, cancel_flag: ?*std.atomic.Value(bool)) versions.Error!versions.Version {
    const io = io_mod.getIo();
    context.version_mutex.lockUncancelable(io);
    defer context.version_mutex.unlock(io);
    var lookup = VersionLookup{ .transport = context.transport, .cancel_flag = cancel_flag };
    return versions.resolveWithCache(
        alloc,
        .grok,
        .{ .context = &lookup, .fetch = VersionLookup.fetch },
        .{ .context = context, .load = loadVersion, .save = saveVersion },
        io_mod.milliTimestamp(),
    );
}

fn fetchCatalog(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    if (input.access != .host_managed) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const version = clientVersion(context, alloc, input.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .{ .failure = .{ .category = .cancellation } },
        error.ProviderVersionUnavailable => return .{ .failure = .{ .category = .transport, .retryable = true } },
    };
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" },
        .{ .name = "x-grok-client-version", .value = version.slice() },
        .{ .name = "x-grok-client-identifier", .value = "fx" },
    };
    const models_url = xai_grok_models.modelsUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(models_url);
    const body = switch (try host_model_catalog.get(alloc, context.transport, models_url, &headers, input.cancel_flag, xai_grok_models.max_catalog_bytes)) {
        .body => |body| body,
        .failure => |failure| return .{ .failure = failure },
    };
    defer alloc.free(body);

    // Modalities only enrich the list; without them every model reads as text-only.
    const modalities_url = xai_grok_models.modalitiesUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(modalities_url);
    const modality_headers = [_]std.http.Header{.{ .name = "accept", .value = "application/json" }};
    const modalities: ?[]u8 = switch (try host_model_catalog.get(alloc, context.transport, modalities_url, &modality_headers, input.cancel_flag, xai_grok_models.max_catalog_bytes)) {
        .body => |modalities| modalities,
        .failure => |failure| blk: {
            if (failure.category == .cancellation) return .{ .failure = failure };
            debug_trace.logf("catalog", "Grok modality enrichment unavailable category={t}", .{failure.category});
            break :blk null;
        },
    };
    defer if (modalities) |value| alloc.free(value);
    return xai_grok_models.catalogFromBodies(alloc, body, modalities);
}

fn buildRequest(_: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    return xai_grok.buildRequest(alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (!xai_grok.acceptsCredential(request.credential)) {
        return stream_provider.failResult(error.GrokSubscriptionCredentialRequired);
    }
    // The model travels in a header too.
    try xai_grok.validateModel(request.model);
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const payload = request.prepared_request_body orelse
        try xai_grok.buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const endpoint = xai_grok.responsesEndpoint() catch |err| return stream_provider.failResult(err);
    const version = clientVersion(context, alloc, request.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled, error.ProviderVersionUnavailable => return stream_provider.failResult(err),
    };

    var extra_buf: [xai_grok.max_extra_headers]std.http.Header = undefined;
    const extra = xai_grok.extraHeaders(&extra_buf, .{
        .subscription = true,
        .client_version = version.slice(),
        .model = request.model,
        .session_id = request.session_id,
    });
    var headers_buf: [xai_grok.max_extra_headers + 1]std.http.Header = undefined;
    headers_buf[0] = .{ .name = "content-type", .value = "application/json" };
    @memcpy(headers_buf[1..][0..extra.len], extra);

    const opened = try host_stream.openPost(alloc, transport, request, endpoint, headers_buf[0 .. extra.len + 1], payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) return .{ .failed = .{
        .kind = xai_grok.failureKind(opened.status),
        .detail = try host_stream.readErrorBody(alloc, transport, opened.handle, request),
        .ownership = .owned,
    } };

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = xai_grok.completeFromStream(alloc, request, &reader.interface) catch |err| switch (err) {
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
    "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"libfx on grok\"}\n\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":23,\"output_tokens\":7}}}\n\n";

test "host Grok stream sends the CLI's request with subscription headers but no credentials" {
    var fake = FakeTransport{
        .model = "grok-4.5",
        .prepared_body = "{\"model\":\"grok-4.5\"}",
        .responses = &.{
            .{ .status = 200, .body = "1.0.50\n" },
            .{ .status = 200, .body = reply_sse },
        },
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings("GET", fake.methods[0]);
    try std.testing.expectEqualStrings("https://x.ai/cli/stable", fake.urls[0]);
    try std.testing.expectEqualStrings("POST", fake.methods[1]);
    try std.testing.expectEqualStrings("https://cli-chat-proxy.grok.com/v1/responses", fake.urls[1]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"}," ++
            "{\"name\":\"accept\",\"value\":\"text/event-stream\"}," ++
            "{\"name\":\"X-XAI-Token-Auth\",\"value\":\"xai-grok-cli\"}," ++
            "{\"name\":\"x-authenticateresponse\",\"value\":\"authenticate-response\"}," ++
            "{\"name\":\"x-grok-client-version\",\"value\":\"1.0.50\"}," ++
            "{\"name\":\"x-grok-client-identifier\",\"value\":\"fx\"}," ++
            "{\"name\":\"x-grok-model-override\",\"value\":\"grok-4.5\"}," ++
            "{\"name\":\"x-grok-conv-id\",\"value\":\"session-1\"}]",
        fake.headers[1],
    );
    try std.testing.expectEqualStrings(fake.prepared_body, fake.bodies[1]);
    try std.testing.expectEqualStrings("libfx on grok", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
}

test "host Grok streams reuse the client version for a minute" {
    var fake = FakeTransport{
        .model = "grok-4.5",
        .prepared_body = "{\"model\":\"grok-4.5\"}",
        .responses = &.{
            .{ .status = 200, .body = "1.0.50\n" },
            .{ .status = 200, .body = reply_sse },
            .{ .status = 200, .body = reply_sse },
        },
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    for (0..2) |_| {
        var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
        result.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualStrings("https://cli-chat-proxy.grok.com/v1/responses", fake.urls[2]);
}

test "host Grok stream returns the error body of a rejected request" {
    var fake = FakeTransport{
        .model = "grok-4.5",
        .responses = &.{
            .{ .status = 200, .body = "1.0.50\n" },
            .{ .status = 401, .body = "{\"error\":\"token expired\"}" },
        },
    };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try provider(&context).stream(std.testing.allocator, fake.request(.host_managed));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, result.failed.kind);
    try std.testing.expectEqualStrings("{\"error\":\"token expired\"}", result.failed.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host Grok stream fails without sending when the client version is unavailable" {
    var fake = FakeTransport{ .model = "grok-4.5", .responses = &.{.{ .status = 503, .body = "" }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    try std.testing.expectError(
        error.ProviderVersionUnavailable,
        provider(&context).stream(std.testing.allocator, fake.request(.host_managed)),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("https://x.ai/cli/stable", fake.urls[0]);
}

test "host Grok stream refuses a Gateway credential and a header-unsafe model without sending" {
    var fake = FakeTransport{ .model = "grok-4.5", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "gateway-key", .source = .ai_gateway_api_key } };
    try std.testing.expectError(
        error.GrokSubscriptionCredentialRequired,
        provider(&context).stream(std.testing.allocator, fake.request(lease)),
    );
    fake.model = "grok-4.5\r\nx-injected: 1";
    try std.testing.expectError(
        error.InvalidXaiGrokModel,
        provider(&context).stream(std.testing.allocator, fake.request(.host_managed)),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host Grok catalog joins the subscription list and modalities through the host" {
    const models =
        \\{"data":[
        \\  {"id":"grok-4.5","model":"grok-4.5","api_backend":"responses","context_window":500000,"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"low"},{"value":"high"}]},
        \\  {"id":"grok-4.7","model":"grok-4.7","api_backend":"responses","context_window":500000,"supports_reasoning_effort":false,"reasoning_efforts":[]}
        \\]}
    ;
    const modalities =
        \\{"models":[{"id":"grok-4.5","input_modalities":["text","image"],"output_modalities":["text"]}]}
    ;
    var fake = FakeTransport{ .responses = &.{
        .{ .status = 200, .body = "1.0.50\n" },
        .{ .status = 200, .body = models },
        .{ .status = 200, .body = modalities },
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

    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualStrings("https://cli-chat-proxy.grok.com/v1/models", fake.urls[1]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"accept\",\"value\":\"application/json\"}," ++
            "{\"name\":\"X-XAI-Token-Auth\",\"value\":\"xai-grok-cli\"}," ++
            "{\"name\":\"x-grok-client-version\",\"value\":\"1.0.50\"}," ++
            "{\"name\":\"x-grok-client-identifier\",\"value\":\"fx\"}]",
        fake.headers[1],
    );
    try std.testing.expectEqualStrings("https://api.x.ai/v1/language-models", fake.urls[2]);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("grok-4.5", catalog.items[0].id);
}

test "host Grok catalog loads without modalities and refuses unmanaged access" {
    const models =
        \\{"data":[{"id":"grok-4.5","model":"grok-4.5","api_backend":"responses","context_window":500000,"supports_reasoning_effort":false,"reasoning_efforts":[]}]}
    ;
    var fake = FakeTransport{ .responses = &.{
        .{ .status = 200, .body = "1.0.50\n" },
        .{ .status = 200, .body = models },
        .{ .status = 401, .body = "" },
    } };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    const result = try modelCatalogProvider(&context).fetch_fn(&context, std.testing.allocator, .{ .access = .host_managed, .endpoint = "" });
    var catalog = result.catalog;
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);

    const refused = try modelCatalogProvider(&context).fetch_fn(&context, std.testing.allocator, .{ .endpoint = "" });
    try std.testing.expectEqual(model_catalog.FailureCategory.authentication, refused.failure.category);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

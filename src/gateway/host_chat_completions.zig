//! A configured OpenAI-compatible provider's requests sent through a host
//! transport, for runtimes such as libfx whose network access belongs to the
//! host. The request, the declared models and the reply parsing are the CLI's
//! own; only the HTTP client differs. The host adds the API key, if any.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const definitions = @import("../core/config/configured_provider.zig");
const chat_completions = @import("chat_completions.zig");
const host_stream = @import("host_stream_provider.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    transport: host_stream.Transport,
    /// The one provider this runtime may use. Owned; free with `deinit`.
    registry: definitions.Registry,

    /// Parses `json`, a settings-style providers object that must define
    /// exactly one provider and give it no credentials of its own.
    pub fn init(alloc: Allocator, transport: host_stream.Transport, json: []const u8) !Context {
        var registry = try definitions.Registry.parse_json(alloc, json);
        errdefer registry.deinit(alloc);
        if (registry.definitions.len != 1 or registry.definitions[0].auth != .none) {
            return error.InvalidConfiguredProvider;
        }
        return .{ .transport = transport, .registry = registry };
    }

    pub fn deinit(self: *Context, alloc: Allocator) void {
        self.registry.deinit(alloc);
    }

    pub fn definition(self: *const Context) *const definitions.Definition {
        return &self.registry.definitions[0];
    }
};

/// A `provider_set.Set.configured_fn` for a `*Context`. `definition` is the
/// engine's copy of a configured provider; a provider other than the context's
/// own gets an empty bundle, so its requests fail instead of reaching this host.
pub fn bundle(raw: ?*anyopaque, definition: *const definitions.Definition) provider_set.Bundle {
    const context: *Context = @ptrCast(@alignCast(raw orelse return .{}));
    const own = context.definition();
    if (!std.mem.eql(u8, &own.binding_identity(), &definition.binding_identity())) return .{};
    return .{
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .build_request_fn = buildRequest,
            .project_replay_fn = chat_completions.project_replay,
        },
        .model_catalog = chat_completions.model_catalog_provider(own),
    };
}

fn buildRequest(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    return chat_completions.build_for(context.definition(), alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    // The engine never holds this provider's key; the host adds it.
    if (request.credential.credentialSource() != .host_managed) {
        return stream_provider.failResult(error.ConfiguredProviderCredentialRequired);
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const definition = context.definition();
    const payload = request.prepared_request_body orelse
        try chat_completions.build_for(definition, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const endpoint = try definition.chat_url(alloc);
    defer alloc.free(endpoint);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    const opened = try host_stream.openPost(alloc, transport, request, endpoint, &headers, payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) return .{ .failed = .{
        .kind = chat_completions.failure_kind(opened.status),
        .detail = try host_stream.readErrorBody(alloc, transport, opened.handle, request),
        .ownership = .owned,
    } };

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = chat_completions.consume(alloc, &reader.interface, request) catch |err| switch (err) {
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

const test_provider =
    \\{"local":{"protocol":"openai-chat-completions","base_url":"https://models.example/v1/","auth":{"type":"none"},
    \\"model_metadata":{"local-model":{"context_window":8192,"supports_tool_use":true}}}}
;

const reply_sse =
    "data: {\"id\":\"chat-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"libfx on a custom provider\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "host chat completions posts the CLI's request to the provider's base URL without credentials" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var result = try agent_stream.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("POST", fake.methods[0]);
    try std.testing.expectEqualStrings("https://models.example/v1/chat/completions", fake.urls[0]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"},{\"name\":\"accept\",\"value\":\"text/event-stream\"}]",
        fake.headers[0],
    );
    try std.testing.expectEqualStrings(fake.prepared_body, fake.bodies[0]);
    try std.testing.expectEqualStrings("libfx on a custom provider", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host chat completions returns the error status and body of a rejected request" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 401, .body = "{\"error\":\"invalid key\"}" }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    var result = try bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);

    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, result.failed.kind);
    try std.testing.expectEqualStrings("{\"error\":\"invalid key\"}", result.failed.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host chat completions refuses a credential held by the engine without sending" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "provider-key", .source = .configured } };
    try std.testing.expectError(
        error.ConfiguredProviderCredentialRequired,
        bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(lease)),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host chat completions serves only its own provider and lists the declared models" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);

    // The engine parses its own copy of the same settings.
    var same = try definitions.Registry.parse_json(alloc, test_provider);
    defer same.deinit(alloc);
    const served = bundle(&context, &same.definitions[0]);
    try std.testing.expect(served.agent_stream != null);
    var listed = try served.model_catalog.?.fetch(alloc, .{ .endpoint = "unused" });
    defer @import("../core/gateway/model_catalog.zig").freeModelCatalog(alloc, &listed.catalog);
    try std.testing.expectEqual(@as(usize, 1), listed.catalog.items.len);
    try std.testing.expectEqualStrings("local-model", listed.catalog.items[0].id);

    var moved = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"https://elsewhere.example/v1","auth":{"type":"none"}}}
    );
    defer moved.deinit(alloc);
    try std.testing.expect(bundle(&context, &moved.definitions[0]).agent_stream == null);
    try std.testing.expect(bundle(null, &same.definitions[0]).agent_stream == null);
}

test "host chat completions context refuses settings it cannot honor" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    for ([_][]const u8{
        \\{}
        ,
        \\{"one":{"protocol":"openai-chat-completions","base_url":"https://a.example/v1","auth":{"type":"none"}},
        \\"two":{"protocol":"openai-chat-completions","base_url":"https://b.example/v1","auth":{"type":"none"}}}
        ,
        \\{"keyed":{"protocol":"openai-chat-completions","base_url":"https://a.example/v1","auth":{"type":"bearer","env":"PROVIDER_KEY"}}}
    }) |json| {
        try std.testing.expectError(error.InvalidConfiguredProvider, Context.init(alloc, fake.transport(), json));
    }
    try std.testing.expectError(error.InsecureBaseUrl, Context.init(alloc, fake.transport(),
        \\{"plain":{"protocol":"openai-chat-completions","base_url":"http://models.example/v1","auth":{"type":"none"}}}
    ));
}

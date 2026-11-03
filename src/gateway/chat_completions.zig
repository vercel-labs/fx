const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const tokenizer = @import("../core/tokenizer/tokenizer.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const configured_request = @import("configured_request.zig");
const openrouter_catalog = @import("openrouter_catalog.zig");
const configured_discovery = @import("configured_discovery.zig");
const google_generative = @import("google_generative.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

/// The models the definition declares; there is no network request. Borrows
/// the definition, which must outlive the provider.
pub fn model_catalog_provider(definition: *const definitions.Definition) catalog.Provider {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{ .context = context, .fetch_fn = fetch_catalog, .lookup_capabilities_fn = lookup_capabilities, .provider_id = bound_identity(definition) };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

pub fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

pub fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return build_for(definition_at(raw), alloc, request);
}

/// The request body for `definition`, omitting replay parts recorded for
/// another endpoint. Caller owns the result.
pub fn build_for(definition: *const definitions.Definition, alloc: Allocator, request: streams.RequestData) ![]u8 {
    if (definition.protocolFor(request.model) == .@"google-generative-ai") return google_generative.build_for(definition, alloc, request);
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    const metadata = request.provider_options.model_metadata orelse definition.model(request.model);
    const base_url = definition.baseUrlFor(request.model);
    const openrouter_host = std.mem.find(u8, base_url, "openrouter.ai") != null;
    const vercel_gateway_host = std.mem.find(u8, base_url, "ai-gateway.vercel.sh") != null or
        std.mem.find(u8, base_url, "gateway.ai.vercel.sh") != null;
    return codec.build_request(alloc, request, .{
        .tool_choice_mode = definition.tool_choice_mode,
        .reasoning_format = definition.reasoning_format,
        .provider = &identity,
        .compatibility = if (metadata) |value| &value.compat else null,
        .default_max_output_tokens = if (metadata) |value| value.max_output_tokens else null,
        .openrouter_host = openrouter_host,
        .vercel_gateway_host = vercel_gateway_host,
    });
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

test "chat completions adapter binds replay to endpoint authority and wires projection" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:5678/v1","auth":{"type":"none"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("local").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "{\"reasoning_details\":[{\"signature\":\"signed\"}],\"_tool_call_ids\":[]}",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try adapter.projectReplay(alloc, replay, &.{}, true, false) == null);
    const request: streams.RequestData = .{
        .model = "model",
        .instructions = &.{.{ .role = .system, .content = "instructions" }},
        .messages = &.{.{ .role = .assistant, .content = "answer", .provider_replay = replay }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "reasoning_details") != null);
    const other = bundle(changed_registry.get("local").?).agent_stream.?;
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "reasoning_details") == null);
    try std.testing.expect(request.messages[0].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (definition.protocolFor(request.model) == .@"google-generative-ai") return google_generative.stream(raw, alloc, request);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    try configured_request.checkToken(definition, token);
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    return post(alloc, definition, request, token, payload) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
        return err;
    };
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

fn body_stall_timeout_ms(definition: *const definitions.Definition, request: streams.ModelRequest) i64 {
    if (request.deadline != null) return std.math.maxInt(i64);
    const metadata = request.provider_options.model_metadata orelse definition.model(request.model) orelse return client_mod.ConnectionWatch.bodyStallTimeoutMs(null);
    const configured = metadata.compat.stream_idle_timeout_ms orelse return client_mod.ConnectionWatch.bodyStallTimeoutMs(null);
    if (configured == 0) return std.math.maxInt(i64);
    return @intCast(@min(configured, @as(u64, @intCast(std.math.maxInt(i64)))));
}

fn post(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const url = try definition.chat_url(alloc, request.model);
    defer alloc.free(url);
    return post_url(alloc, definition, url, request, token, payload, consume);
}

pub const ConsumeFn = *const fn (Allocator, *std.Io.Reader, streams.ModelRequest, ?sse.Progress) anyerror!streams.Result;

/// The configured credential header used by a native protocol. Bearer remains
/// the default for OpenAI-compatible endpoints; Google-compatible Zen routes
/// use x-api-key without changing the shared HTTP lifecycle.
pub const AuthStyle = enum { bearer, x_api_key, none };

/// Posts `payload` with a bearer key and parses a streamed reply. Shared with
/// the Responses transport for configured providers.
pub fn post_url(alloc: Allocator, definition: *const definitions.Definition, url: []const u8, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8, consume_fn: ConsumeFn) !streams.Result {
    return post_url_auth(alloc, definition, url, request, token, payload, consume_fn, .bearer);
}

/// The same bounded POST as `post_url`, with an explicit credential style for
/// native protocols that do not use HTTP Authorization.
pub fn post_url_auth(alloc: Allocator, definition: *const definitions.Definition, url: []const u8, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8, consume_fn: ConsumeFn, auth_style: AuthStyle) !streams.Result {
    const authorization = if (auth_style == .bearer) if (token) |value| if (value.len != 0) try alloc.print("Bearer {s}", .{value}) else null else null else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var extra = try configured_request.resolveHeaders(alloc, definition, request.model);
    defer extra.deinit(alloc);
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try headers.append(alloc, .{ .name = "accept", .value = "text/event-stream" });
    if (auth_style == .x_api_key) if (token) |value| if (value.len != 0) {
        try headers.append(alloc, .{ .name = "x-api-key", .value = value });
    };
    try headers.appendSlice(alloc, extra.items);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = headers.items,
    };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.ConnectionWatch = .init(.{
        .timeout_ms = 120_000,
        .stall_timeout_ms = body_stall_timeout_ms(definition, request),
    });
    defer watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    // The 120 s head wait also bounds sending the request.
    if (watch.armHead()) |err| return err;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    if (response.head.status != .ok) {
        // An error body is read under its own 30 s bound.
        watch.stop();
        watch = .init(.{ .patient = true, .stall_timeout_ms = std.math.maxInt(i64) });
        if (http.connection) |connection| try watch.start(request.cancel_flag, phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    }
    var retry_after: ?u64 = null;
    var response_headers = response.head.iterateHeaders();
    while (response_headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }

        return .{ .failed = .{ .kind = client_mod.httpFailureKind(alloc, .fromHttpStatus(response.head.status), detail), .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var stream_request = request;
    stream_request.compatibility = if (request.provider_options.model_metadata orelse definition.model(request.model)) |metadata| &metadata.compat else null;
    var result = consume_fn(alloc, reader, stream_request, watch.progress()) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    return result;
}

/// Parses a successful non-streaming JSON reply after the same bounded POST
/// lifecycle used by the streaming transports. The callback owns the returned
/// bytes and may parse them before returning its provider result.
pub const JsonConsumeFn = *const fn (Allocator, *std.Io.Reader, streams.ModelRequest, ?sse.Progress) anyerror![]u8;

pub fn post_json_url(
    alloc: Allocator,
    definition: *const definitions.Definition,
    url: []const u8,
    request: streams.ModelRequest,
    token: ?[]const u8,
    payload: []const u8,
    consume_fn: JsonConsumeFn,
) ![]u8 {
    return post_json_url_auth(alloc, definition, url, request, token, payload, consume_fn, .bearer);
}

pub fn post_json_url_auth(
    alloc: Allocator,
    definition: *const definitions.Definition,
    url: []const u8,
    request: streams.ModelRequest,
    token: ?[]const u8,
    payload: []const u8,
    consume_fn: JsonConsumeFn,
    auth_style: AuthStyle,
) ![]u8 {
    const authorization = if (auth_style == .bearer)
        if (token) |value| if (value.len != 0) try alloc.print("Bearer {s}", .{value}) else null else null
    else
        null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var extra = try configured_request.resolveHeaders(alloc, definition, request.model);
    defer extra.deinit(alloc);
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try headers.append(alloc, .{ .name = "accept", .value = "application/json" });
    try headers.append(alloc, .{ .name = "content-type", .value = "application/json" });
    if (auth_style == .x_api_key) if (token) |value| if (value.len != 0) {
        try headers.append(alloc, .{ .name = "x-api-key", .value = value });
    };
    try headers.appendSlice(alloc, extra.items);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = headers.items,
    };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.ConnectionWatch = .init(.{
        .timeout_ms = 120_000,
        .stall_timeout_ms = body_stall_timeout_ms(definition, request),
    });
    defer watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    if (watch.armHead()) |err| return err;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    if (response.head.status != .ok) {
        watch.stop();
        watch = .init(.{ .patient = true, .stall_timeout_ms = std.math.maxInt(i64) });
        if (http.connection) |connection| try watch.start(request.cancel_flag, phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    }
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        const detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => return error.ProviderHttpFailure,
            else => return err,
        };
        defer alloc.free(detail);
        return error.ProviderHttpFailure;
    }
    const result = consume_fn(alloc, reader, request, watch.progress()) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        alloc.free(result);
        return err;
    }
    return result;
}

/// Parses a successful streamed reply from `reader`, telling `progress` about
/// each event when it is set.
pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) anyerror!streams.Result {
    var limits: codec.Limits = .{ .compatibility = request.compatibility };
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The returned entry borrows its strings; fetch_catalog replaces them with owned copies.
pub fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .name = if (metadata.name) |name| @constCast(name) else null,
        .description = if (metadata.description) |description| @constCast(description) else null,
        .cost = metadata.cost,
        .intelligence = metadata.intelligence,
        .recommended = metadata.recommended,
        .beta = metadata.beta,
        .released = metadata.released,
        .model_type = @constCast("language"),
        .tokenizer = if (metadata.tokenizer) |name| tokenizer.Encoding.parse(name) else tokenizer.resolveModel(metadata.id),
        .has_tool_use = metadata.supports_tool_use orelse false,
        // Chat completions sends images as inline base64 content parts, so
        // vision support implies file input through the same path.
        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
        .max_context_window = metadata.max_context_window,
        .omit_max_output_tokens = metadata.omit_max_output_tokens,
        .prefer_websockets = metadata.prefer_websockets,
        // Only Messages definitions declare efforts; the list stays borrowed.
        .has_reasoning = metadata.reasoning_efforts.len != 0,
        .reasoning_efforts = .fromOwnedSlice(@constCast(metadata.reasoning_efforts)),
    };
}

pub fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const definition = definition_at(raw);
    const metadata = definition.model(model) orelse return .{};
    return model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata.*)));
}

pub fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    // Declared models first; a preset's built-in ones fill in, then the live
    // OpenRouter catalog when the definition uses it.
    var live = if (definition.catalog == .openrouter) openrouter_catalog.fetch(alloc, definition.base_url, input.cancel_flag) else openrouter_catalog.Fetched{};
    defer live.deinit(alloc);
    var discovered = if (definition.discovery != null) try configured_discovery.fetch(alloc, definition, input) else configured_discovery.Fetched{};
    defer discovered.deinit(alloc);
    if (discovered.failure) |failure| return .{ .failure = failure };
    // Live metadata is the base; parsed overrides replace only supplied fields.
    for ([_][]const definitions.ModelMetadata{ live.models, discovered.models, definition.model_metadata, definition.builtin_models }) |list| for (list) |base| {
        if (listed(entries.items, base.id)) continue;
        var metadata = base;
        if (definition.model_defaults) |defaults| metadata = definitions.overlayMetadata(metadata, defaults.*);
        for (definition.model_metadata) |override| if (std.mem.eql(u8, override.id, base.id)) {
            metadata = definitions.overlayMetadata(metadata, override);
            break;
        };
        const entry = try catalog.cloneModelCatalogEntry(alloc, metadata_entry(metadata));
        errdefer catalog.freeModelCatalogEntry(alloc, entry);
        try entries.append(alloc, entry);
    };
    return .{ .catalog = entries };
}

fn listed(entries: []const catalog.ModelCatalogEntry, id: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false,"tokenizer":"qwen3"},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try std.testing.expectEqualDeep(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        const declared_vision = std.mem.eql(u8, entry.id, "small");
        try std.testing.expectEqual(declared_vision, actual.supports_vision);
        try std.testing.expectEqual(
            if (declared_vision) model_capabilities.ImageInputSupport.native else model_capabilities.ImageInputSupport.non_native,
            actual.image_input_support,
        );
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expectEqual(@as(?tokenizer.Encoding, .qwen3), provider.lookupCapabilities("large").?.tokenizer);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try std.testing.expectEqualDeep(model_capabilities.Capabilities{}, provider.lookupCapabilities("missing-fast").?);
}

pub fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const result = fetch_catalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch
        return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            var entries = value;
            defer catalog.freeModelCatalog(alloc, &entries);
            const ids = catalog.projectModelIds(alloc, entries.items) catch return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
            return .{ .loaded = .{ .ids = ids, .provenance = provenance } };
        },
    }
}

/// The build and stream callbacks a review sends through; both take the
/// definition as context.
pub const ReviewTransport = struct {
    build_fn: *const fn (?*anyopaque, Allocator, streams.RequestData) anyerror![]u8 = build,
    stream_fn: *const fn (?*anyopaque, Allocator, streams.ModelRequest) anyerror!streams.Result = stream,
};
const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput, transport: ReviewTransport };
pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return review_with(raw, alloc, input, request, .{});
}

/// A permission review sent through `transport` to the reviewer model.
pub fn review_with(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest, transport: ReviewTransport) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input, .transport = transport };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, reviewerModel(state.definition, input, request)).review(alloc, request);
}

/// The `review` model role first, then the definition's reviewer, then the
/// conversation's model (D172).
pub fn reviewerModel(definition: *const definitions.Definition, input: classifier.ProviderInput, request: classifier.ReviewRequest) []const u8 {
    if (input.reviewer_model.len > 0) return input.reviewer_model;
    return definition.reviewer_model orelse request.review_turn.model;
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return state.transport.build_fn(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    const provider: streams.Provider = .{ .context = @ptrCast(@constCast(state.definition)), .stream_fn = state.transport.stream_fn };
    var result = gateway_step.streamModelCompletion(provider, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
        else => {
            const outcome = reviewErrorOutcome(err);
            debug_trace.logf("permission", "event=auto_review_transport result={s} reason=transport_error error={s}", .{ @tagName(outcome), @errorName(err) });
            return outcome;
        },
    };
    errdefer result.deinit(alloc);
    // A review the output limit cut off holds no decision, and the same
    // review would be cut off again, so it stays unavailable.
    const cut_off = result == .completed and result.completed.completion.finish_reason == .length;
    if (result == .failed or cut_off) {
        const outcome = if (result == .failed)
            reviewFailureOutcome(result.failed.kind)
        else
            classifier.TransportOutcome.permanent_failure;
        debug_trace.logf("permission", "event=auto_review_transport result={s} reason={s} failure_kind={s}", .{
            @tagName(outcome),
            if (result == .failed) @as([]const u8, "provider_failure") else "review_cut_off",
            if (result == .failed) @tagName(result.failed.kind) else "none",
        });
        result.deinit(alloc);
        return outcome;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}

/// A review whose request failed on the way is worth one more try, as the
/// Responses reviewer does: the reviewer retries a transient failure once
/// with a fresh deadline (D292). A refused request will be refused again.
fn reviewErrorOutcome(err: anyerror) classifier.TransportOutcome {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.Timeout => .timed_out,
        error.Refused, error.ContentFiltered, error.IncompleteStream => .permanent_failure,
        else => .transient_failure,
    };
}

pub fn failure_kind(status: std.http.Status) streams.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

/// An upstream that is busy, down or overloaded may answer the next
/// attempt; one that rejects the request will not (D292).
fn reviewFailureOutcome(kind: streams.FailureKind) classifier.TransportOutcome {
    return switch (kind) {
        .rate_limited, .server_error, .bad_gateway, .unavailable, .gateway_timeout, .provider_error => .transient_failure,
        .invalid_request, .unauthorized, .forbidden, .request_too_large, .quota_exhausted => .permanent_failure,
    };
}

test "a review that an upstream fails for now is tried again, a refused one is not" {
    try std.testing.expectEqual(classifier.TransportOutcome.transient_failure, reviewFailureOutcome(.server_error));
    try std.testing.expectEqual(classifier.TransportOutcome.transient_failure, reviewFailureOutcome(.unavailable));
    try std.testing.expectEqual(classifier.TransportOutcome.transient_failure, reviewFailureOutcome(.rate_limited));
    try std.testing.expectEqual(classifier.TransportOutcome.permanent_failure, reviewFailureOutcome(.unauthorized));
    try std.testing.expectEqual(classifier.TransportOutcome.permanent_failure, reviewFailureOutcome(.invalid_request));
    try std.testing.expectEqual(classifier.TransportOutcome.transient_failure, reviewErrorOutcome(error.ConnectionRefused));
    try std.testing.expectEqual(classifier.TransportOutcome.timed_out, reviewErrorOutcome(error.Timeout));
}

const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    var identity = @import("../core/config/model_provider.zig").parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build },
        .model_catalog = .{ .context = context, .fetch_fn = fetch_catalog, .lookup_capabilities_fn = lookup_capabilities, .provider_id = identity },
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return codec.build_request(alloc, request, .{ .tool_choice_mode = definition_at(raw).tool_choice_mode });
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
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

fn post(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const url = try definition.chat_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.CancelWatch = .{};
    defer watch.stop();
    const head_deadline = phase_deadline(120_000, request.deadline);
    if (http.connection) |connection| try watch.start(request.cancel_flag, head_deadline, connection.stream_writer.stream);
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| {
        if (expired(head_deadline)) return error.Timeout;
        return err;
    };
    watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, if (response.head.status == .ok) request.deadline else phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    var retry_after: ?u64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
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

        return .{ .failed = .{ .kind = switch (response.head.status) {
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
        }, .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag);
}

/// The returned entry borrows its strings; fetch_catalog replaces them with owned copies.
fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_tool_use = metadata.supports_tool_use orelse false,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).model(model) orelse return .{};
    return model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata.*)));
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |metadata| {
        var entry = metadata_entry(metadata);
        entry.id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, entry.model_type);
        errdefer alloc.free(entry.model_type);
        try entries.append(alloc, entry);
    }
    return .{ .catalog = entries };
}

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try std.testing.expectEqualDeep(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        try std.testing.expectEqual(model_capabilities.ImageInputSupport.non_native, actual.image_input_support);
        try std.testing.expect(!actual.supports_vision);
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try std.testing.expectEqualDeep(model_capabilities.Capabilities{}, provider.lookupCapabilities("missing-fast").?);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
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

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
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
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
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
    }, state.input.usage, state.input.usage_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);
    if (result == .failed) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}

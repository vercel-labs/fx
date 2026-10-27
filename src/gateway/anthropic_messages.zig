//! Anthropic Messages transport. `Endpoint` names the URL, where the key goes
//! and any extra headers, so any provider that speaks Messages can register
//! through `stream_endpoint`. `bundle` registers a profile-defined
//! `anthropic-messages` provider.
const std = @import("std");
const codec = @import("anthropic_messages_protocol.zig");
const reducer = @import("anthropic_messages_stream.zig");
const chat_codec = @import("chat_completions_protocol.zig");
const chat_completions = @import("chat_completions.zig");
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const configured_request = @import("configured_request.zig");
const Allocator = std.mem.Allocator;

pub const api_version = "2023-06-01";
pub const interleaved_thinking_beta = "interleaved-thinking-2025-05-14";

pub const KeyStyle = enum { none, x_api_key, bearer };

/// Everything a Messages provider varies. Borrowed for the call.
pub const Endpoint = struct {
    /// Full URL of the messages resource, such as `https://api.anthropic.com/v1/messages`.
    messages_url: []const u8,
    key_style: KeyStyle,
    /// Sent after the fixed headers; must not carry the credential.
    extra_headers: []const std.http.Header = &.{},
    /// Beta flags joined into one `anthropic-beta` header.
    betas: []const []const u8 = &.{},
    options: codec.Options = .{},
};

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = chat_completions.model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat_completions.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

/// Options for a profile-defined endpoint. `provider` points at `identity`.
fn definition_options(definition: *const definitions.Definition, model: []const u8, identity: *const model_provider.ProviderId) codec.Options {
    const metadata = definition.model(model);
    const mode: codec.ThinkingMode = if (metadata) |value| switch (value.thinking orelse .budget) {
        .budget => .budget,
        .adaptive => .adaptive,
    } else .budget;
    var options: codec.Options = .{ .provider = identity, .thinking_mode = mode };
    if (metadata) |value| if (value.max_output_tokens) |limit| {
        options.default_max_tokens = limit;
    };
    return options;
}

pub fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const definition = definition_at(raw);
    const identity = bound_identity(definition);
    return codec.build_request(alloc, request, definition_options(definition, request.model, &identity));
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    try configured_request.checkToken(definition, token);
    const url = try definition.messages_url(alloc);
    defer alloc.free(url);
    const identity = bound_identity(definition);
    const style: KeyStyle = switch (definition.auth) {
        .none => .none,
        .bearer, .command, .login => if (definition.key_header == .x_api_key) .x_api_key else .bearer,
    };
    var headers = try configured_request.resolveHeaders(alloc, definition);
    defer headers.deinit(alloc);
    return stream_endpoint(alloc, .{
        .messages_url = url,
        .key_style = style,
        .extra_headers = headers.items,
        .options = definition_options(definition, request.model, &identity),
    }, if (style == .none) null else token, request);
}

/// Streams one request to `endpoint`. A rejected thinking signature is
/// retried once with every thinking block dropped, as proto does.
pub fn stream_endpoint(alloc: Allocator, endpoint: Endpoint, token: ?[]const u8, request: streams.ModelRequest) !streams.Result {
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    const built = if (request.prepared_request_body == null) try codec.build_request(alloc, request.data(), endpoint.options) else null;
    defer if (built) |body| alloc.free(body);
    var result = try post_guarded(alloc, endpoint, request, token, built orelse request.prepared_request_body.?);
    if (result == .failed and result.failed.kind == .invalid_request and !endpoint.options.drop_thinking) {
        const detail = result.failed.detail orelse "";
        if (invalid_signature(detail)) {
            debug_trace.logf("gateway", "anthropic_thinking_signature_rejected retry=drop_all", .{});
            result.deinit(alloc);
            var options = endpoint.options;
            options.drop_thinking = true;
            const retry_body = try codec.build_request(alloc, request.data(), options);
            defer alloc.free(retry_body);
            return post_guarded(alloc, endpoint, request, token, retry_body);
        }
    }
    return result;
}

/// Proto's INVALID_THINKING_SIGNATURE and MISSING_THINKING_SIGNATURE patterns.
pub fn invalid_signature(detail: []const u8) bool {
    var lower_buffer: [4096]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buffer, detail[0..@min(detail.len, lower_buffer.len)]);
    if (std.mem.find(u8, lower, "thinking.signature") != null and std.mem.find(u8, lower, "required") != null) return true;
    const at = std.mem.find(u8, lower, "invalid") orelse return false;
    const signature = std.mem.findPos(u8, lower, at, "signature") orelse return false;
    return std.mem.findPos(u8, lower, signature, "thinking") != null;
}

fn post_guarded(alloc: Allocator, endpoint: Endpoint, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    return post(alloc, endpoint, request, token, payload) catch |err| {
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

fn post(alloc: Allocator, endpoint: Endpoint, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const authorization = if (endpoint.key_style == .bearer) if (token) |value| try alloc.print("Bearer {s}", .{value}) else null else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var betas: std.ArrayList(u8) = .empty;
    defer betas.deinit(alloc);
    for (endpoint.betas) |beta| {
        if (betas.items.len != 0) try betas.append(alloc, ',');
        try betas.appendSlice(alloc, beta);
    }
    if (codec.uses_budget_thinking(payload)) {
        if (betas.items.len != 0) try betas.append(alloc, ',');
        try betas.appendSlice(alloc, interleaved_thinking_beta);
    }
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try headers.appendSlice(alloc, &.{ .{ .name = "accept", .value = "text/event-stream" }, .{ .name = "anthropic-version", .value = api_version } });
    if (endpoint.key_style == .x_api_key) if (token) |value| try headers.append(alloc, .{ .name = "x-api-key", .value = value });
    if (betas.items.len != 0) try headers.append(alloc, .{ .name = "anthropic-beta", .value = betas.items });
    try headers.appendSlice(alloc, endpoint.extra_headers);

    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(endpoint.messages_url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var operation = client_mod.PostOperation{ .client = &client, .uri = uri, .authorization = authorization, .extra_headers = headers.items };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.ConnectionWatch = .init(.{
        .timeout_ms = 120_000,
        .stall_timeout_ms = client_mod.ConnectionWatch.bodyStallTimeoutMs(request.deadline),
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
    var retry_after: ?u64 = null;
    var iterator = response.head.iterateHeaders();
    while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
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
            const redacted = try chat_codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }
        return .{ .failed = .{ .kind = failure_kind(response.head.status), .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var result = consume(alloc, reader, request, watch.progress()) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    return result;
}

/// HTTP 529 is Anthropic's overloaded status; it retries like 503.
pub fn failure_kind(status: std.http.Status) streams.FailureKind {
    if (@backingInt(status) == 529) return .unavailable;
    return chat_completions.failure_kind(status);
}

pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: reducer.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return reducer.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The chat review flow, sent through this transport.
pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return chat_completions.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
}

test "signature rejection patterns match proto" {
    try std.testing.expect(invalid_signature("{\"error\":{\"message\":\"messages.1.content.0: Invalid `signature` in `thinking` block\"}}"));
    try std.testing.expect(invalid_signature("messages.3.content.0.thinking.signature: Field required"));
    try std.testing.expect(!invalid_signature("invalid model"));
    try std.testing.expectEqual(streams.FailureKind.unavailable, failure_kind(@fromBackingInt(529)));
}

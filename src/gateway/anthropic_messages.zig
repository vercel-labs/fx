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
const fine_grained_tool_streaming_beta = "fine-grained-tool-streaming-2025-05-14";
const fast_mode_beta = "fast-mode-2026-02-01";
const task_budget_beta = "task-budgets-2026-03-13";
const structured_outputs_beta = "structured-outputs-2025-12-15";
const context_management_beta = "context-management-2025-06-27";
const compaction_beta = "compact-2026-01-12";
const server_side_fallback_beta = "server-side-fallback-2026-06-01";

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
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .compaction = .{ .context = context, .compact_fn = compact },
            .build_request_fn = build,
            .project_replay_fn = project_replay,
        },
        .model_catalog = chat_completions.model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat_completions.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

pub fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

/// Options for a profile-defined endpoint. `provider` points at `identity`.
pub fn definition_options(definition: *const definitions.Definition, model: []const u8, identity: *const model_provider.ProviderId) codec.Options {
    const metadata = definition.model(model);
    const mode: codec.ThinkingMode = if (metadata) |value| switch (value.thinking orelse .budget) {
        .budget => .budget,
        .adaptive => .adaptive,
    } else .budget;
    var options: codec.Options = .{ .provider = identity, .thinking_mode = mode };
    if (metadata) |value| {
        if (value.max_output_tokens) |limit| options.default_max_tokens = limit;
        options.supports_context_management = value.compat.supports_context_management orelse true;
        options.supports_eager_tool_input_streaming = value.compat.supports_eager_tool_input_streaming orelse true;
        options.requires_tool_result_id = value.compat.requires_tool_result_id orelse false;
        options.supports_forced_tool_choice = value.compat.supports_forced_tool_choice orelse true;
        options.requires_thinking_presence = value.compat.requires_thinking_presence orelse false;
        options.allow_anthropic_header_overrides = value.compat.allow_anthropic_header_overrides orelse false;
        options.replay_unsigned_thinking = value.compat.replay_unsigned_thinking orelse false;
    }
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
    const url = try definition.messages_url(alloc, request.model);
    defer alloc.free(url);
    const identity = bound_identity(definition);
    const style: KeyStyle = switch (definition.auth) {
        .none => .none,
        .bearer, .command, .login => if (definition.key_header == .x_api_key) .x_api_key else .bearer,
    };
    var headers = try configured_request.resolveHeaders(alloc, definition, request.model);
    defer headers.deinit(alloc);
    return stream_endpoint(alloc, .{
        .messages_url = url,
        .key_style = style,
        .extra_headers = headers.items,
        .options = definition_options(definition, request.model, &identity),
    }, if (style == .none) null else token, request);
}

fn discard_compaction_event(_: *anyopaque, _: streams.Event) void {}

fn usage_total(usage: types.Usage) ?u64 {
    var total: u64 = 0;
    var seen = false;
    if (usage.input_tokens) |value| {
        total +|= value;
        seen = true;
    }
    if (usage.output_tokens) |value| {
        total +|= value;
        seen = true;
    }
    return if (seen) total else null;
}

/// Runs Anthropic's server-side compaction edit and exposes its summary and
/// replay envelope to the core compactor. The normal Messages stream reducer
/// owns response validation, usage, encrypted content, and provider state.
fn compact(raw: ?*anyopaque, alloc: Allocator, request: streams.CompactionRequest) anyerror!streams.CompactionResult {
    if (request.kind != .anthropic_native) return error.UnsupportedCompactionKind;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    var options = request.provider_options;
    if (options.anthropic_compaction == null) {
        options.anthropic_compaction = .{
            .trigger_input_tokens = 50_000,
            .pause_after_compaction = true,
            .instructions = if (request.instructions.len == 0) null else request.instructions,
        };
    }
    var delivery: streams.DeliveryCertainty = .{};
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = try stream(raw, alloc, .{
        .observer = request.observer,
        .admission = request.admission,
        .purpose = .compaction,
        .credential = request.credential,
        .session_id = request.session_id,
        .model = request.model,
        .retry_count = 0,
        .instructions = &.{},
        .messages = request.messages,
        .tools = request.tools,
        .tool_choice = .none,
        .provider_options = options,
        .budget = request.budget,
        .trace_ctx = request.trace_ctx,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = discard_compaction_event },
        .content_capture_limit = 8 * 1024 * 1024,
        .cancel_flag = request.cancel_flag,
    });
    defer result.deinit(alloc);
    switch (result) {
        .failed => return error.NativeCompactionFailed,
        .completed => |completed| {
            const state = completed.completion.provider_state_json orelse return error.EmptyNativeCompaction;
            const summary = try codec.compaction_summary(alloc, state) orelse return error.EmptyNativeCompaction;
            errdefer alloc.free(summary);
            const state_copy = try alloc.dupe(u8, state);
            return .{
                .summary = summary,
                .provider_state_json = state_copy,
                .used_tokens = usage_total(completed.completion.usage),
                .usage = completed.completion.usage,
                .ownership = .owned,
            };
        },
    }
}

/// Streams one request to `endpoint`. When compatibility permits unsigned
/// replay, a signature rejection first demotes unsigned blocks and then falls
/// back to dropping all replayed thinking if signed history is also rejected.
pub fn stream_endpoint(alloc: Allocator, endpoint: Endpoint, token: ?[]const u8, request: streams.ModelRequest) !streams.Result {
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    const built = if (request.prepared_request_body == null) try codec.build_request(alloc, request.data(), endpoint.options) else null;
    defer if (built) |body| alloc.free(body);
    var result = try post_guarded(alloc, endpoint, request, token, built orelse request.prepared_request_body.?);
    if (invalid_thinking_signature(result) and !endpoint.options.drop_thinking) {
        var options = endpoint.options;
        result.deinit(alloc);
        if (options.replay_unsigned_thinking) {
            // A signing proxy can reject only unsigned historical thinking.
            // First demote those blocks while retaining signed replay; if the
            // provider still rejects the signed history, retry once without it.
            debug_trace.logf("gateway", "anthropic_thinking_signature_rejected retry=drop_unsigned", .{});
            options.replay_unsigned_thinking = false;
            const retry_body = try codec.build_request(alloc, request.data(), options);
            var retried = post_guarded(alloc, endpoint, request, token, retry_body) catch |err| {
                alloc.free(retry_body);
                return err;
            };
            alloc.free(retry_body);
            if (invalid_thinking_signature(retried)) {
                debug_trace.logf("gateway", "anthropic_thinking_signature_rejected retry=drop_all", .{});
                retried.deinit(alloc);
                options.drop_thinking = true;
                const final_body = try codec.build_request(alloc, request.data(), options);
                defer alloc.free(final_body);
                return post_guarded(alloc, endpoint, request, token, final_body);
            }
            return retried;
        }
        debug_trace.logf("gateway", "anthropic_thinking_signature_rejected retry=drop_all", .{});
        options.drop_thinking = true;
        const retry_body = try codec.build_request(alloc, request.data(), options);
        defer alloc.free(retry_body);
        return post_guarded(alloc, endpoint, request, token, retry_body);
    }
    return result;
}

fn invalid_thinking_signature(result: streams.Result) bool {
    return switch (result) {
        .failed => |failure| failure.kind == .invalid_request and invalid_signature(failure.detail orelse ""),
        .completed => false,
    };
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

fn isAnthropicOAuthToken(token: ?[]const u8) bool {
    return if (token) |value| std.mem.startsWith(u8, value, "sk-ant-oat") else false;
}

fn isOfficialAnthropicUrl(url: []const u8) bool {
    const prefix = "https://api.anthropic.com";
    return std.ascii.startsWithIgnoreCase(url, prefix) and (url.len == prefix.len or url[prefix.len] == '/');
}

fn isCoworkHeader(name: []const u8) bool {
    return for ([_][]const u8{
        "x-stainless-arch",        "x-stainless-lang",    "x-stainless-package-version",
        "x-stainless-retry-count", "x-stainless-runtime", "x-stainless-runtime-version",
        "x-stainless-timeout",
    }) |known| {
        if (std.ascii.eqlIgnoreCase(name, known)) break true;
    } else false;
}

fn isAnthropicEnforcedHeader(name: []const u8) bool {
    return isCoworkHeader(name) or for ([_][]const u8{
        "accept",                                    "accept-encoding",          "connection",          "content-type",         "anthropic-version",
        "anthropic-dangerous-direct-browser-access", "anthropic-beta",           "user-agent",          "x-app",                "authorization",
        "x-api-key",                                 "x-claude-code-session-id", "x-client-request-id", "cf-aig-authorization",
    }) |known| {
        if (std.ascii.eqlIgnoreCase(name, known)) break true;
    } else false;
}

fn isAnthropicOverridableHeader(name: []const u8) bool {
    return isCoworkHeader(name) or for ([_][]const u8{ "anthropic-beta", "user-agent", "x-app" }) |known| {
        if (std.ascii.eqlIgnoreCase(name, known)) break true;
    } else false;
}

pub fn customHeaderAllowed(name: []const u8, options: codec.Options, base_url: []const u8, oauth_token: bool) bool {
    if (!isAnthropicEnforcedHeader(name)) return true;
    return options.allow_anthropic_header_overrides and oauth_token and
        !isOfficialAnthropicUrl(base_url) and isAnthropicOverridableHeader(name);
}

fn appendExtraHeaders(alloc: Allocator, headers: *std.ArrayList(std.http.Header), endpoint: Endpoint, token: ?[]const u8) !void {
    for (endpoint.extra_headers) |header| {
        if (!customHeaderAllowed(header.name, endpoint.options, endpoint.messages_url, isAnthropicOAuthToken(token))) continue;
        var replaced = false;
        for (headers.items) |*existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, header.name)) {
                existing.value = header.value;
                replaced = true;
                break;
            }
        }
        if (!replaced) try headers.append(alloc, header);
    }
}

fn append_beta(alloc: Allocator, betas: *std.ArrayList(u8), beta: []const u8) !void {
    var it = std.mem.splitScalar(u8, betas.items, ',');
    while (it.next()) |existing| if (std.mem.eql(u8, existing, beta)) return;
    if (betas.items.len != 0) try betas.append(alloc, ',');
    try betas.appendSlice(alloc, beta);
}

fn post(alloc: Allocator, endpoint: Endpoint, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const authorization = if (endpoint.key_style == .bearer) if (token) |value| try alloc.print("Bearer {s}", .{value}) else null else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var betas: std.ArrayList(u8) = .empty;
    defer betas.deinit(alloc);
    for (endpoint.betas) |beta| try append_beta(alloc, &betas, beta);
    if (codec.uses_budget_thinking(payload)) try append_beta(alloc, &betas, interleaved_thinking_beta);
    // These controls are request-shaped in the native protocol. Deriving the
    // beta set from the exact body keeps custom endpoints working without
    // making every caller duplicate Anthropic's feature matrix.
    if (std.mem.find(u8, payload, "\"eager_input_streaming\":true") != null) try append_beta(alloc, &betas, fine_grained_tool_streaming_beta);
    if (std.mem.find(u8, payload, "\"speed\":\"fast\"") != null) try append_beta(alloc, &betas, fast_mode_beta);
    if (std.mem.find(u8, payload, "\"task_budget\"") != null) try append_beta(alloc, &betas, task_budget_beta);
    if (std.mem.find(u8, payload, "\"format\":{\"type\":\"json_schema\"") != null) try append_beta(alloc, &betas, structured_outputs_beta);
    if (std.mem.find(u8, payload, "\"context_management\"") != null) {
        try append_beta(alloc, &betas, context_management_beta);
        if (std.mem.find(u8, payload, "\"compact_20260112\"") != null) try append_beta(alloc, &betas, compaction_beta);
    }
    if (std.mem.find(u8, payload, "\"fallbacks\"") != null) try append_beta(alloc, &betas, server_side_fallback_beta);
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try headers.appendSlice(alloc, &.{ .{ .name = "accept", .value = "text/event-stream" }, .{ .name = "anthropic-version", .value = api_version } });
    if (endpoint.key_style == .x_api_key) if (token) |value| try headers.append(alloc, .{ .name = "x-api-key", .value = value });
    if (betas.items.len != 0) try headers.append(alloc, .{ .name = "anthropic-beta", .value = betas.items });
    try appendExtraHeaders(alloc, &headers, endpoint, token);

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
    var result = consume(alloc, reader, request, endpoint.options.replay_unsigned_thinking, watch.progress()) catch |err| return watch.failure(err);
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

pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, replay_unsigned_thinking: bool, progress: ?sse.Progress) !streams.Result {
    var limits: reducer.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return reducer.consume_stream_with_replay(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress, replay_unsigned_thinking);
}

/// The chat review flow, sent through this transport.
pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    return chat_completions.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
}

test "Anthropic header overrides require OAuth and a non-official endpoint" {
    const options: codec.Options = .{ .allow_anthropic_header_overrides = true };
    try std.testing.expect(customHeaderAllowed("anthropic-beta", options, "https://proxy.example/v1", true));
    try std.testing.expect(!customHeaderAllowed("anthropic-beta", options, "https://api.anthropic.com/v1", true));
    try std.testing.expect(!customHeaderAllowed("anthropic-version", options, "https://proxy.example/v1", true));
    try std.testing.expect(!customHeaderAllowed("anthropic-beta", options, "https://proxy.example/v1", false));
    try std.testing.expect(customHeaderAllowed("x-model-header", .{}, "https://api.anthropic.com/v1", false));
}

test "signature rejection patterns match proto" {
    try std.testing.expect(invalid_signature("{\"error\":{\"message\":\"messages.1.content.0: Invalid `signature` in `thinking` block\"}}"));
    try std.testing.expect(invalid_signature("messages.3.content.0.thinking.signature: Field required"));
    try std.testing.expect(!invalid_signature("invalid model"));
    try std.testing.expectEqual(streams.FailureKind.unavailable, failure_kind(@fromBackingInt(529)));
}

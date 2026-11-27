const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../core/shared/debug_trace.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const io_mod = @import("../core/shared/io.zig");
const testing_listener = @import("../core/shared/testing_listener.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const chat_completions_protocol = @import("chat_completions_protocol.zig");
const gemini_errors = @import("gemini_errors.zig");
const gemini_interactions_protocol = @import("gemini_interactions_protocol.zig");
const google_gemini_models = @import("google_gemini_models.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const default_base_url = "https://generativelanguage.googleapis.com";
pub const api_key_path = "/v1beta/interactions";
pub const plan_path = "/v1beta/interactions:createPerUserQuota";
pub const base_url_env = "FX_TEST_GEMINI_BASE_URL";

pub const max_error_body_bytes: usize = 256 * 1024;
pub const connect_timeout_ms: i64 = 30_000;
pub const stream_stall_timeout_seconds: i64 = 3_600;
pub const stream_stall_timeout_ms: i64 = stream_stall_timeout_seconds * std.time.ms_per_s;

const send_buffer_bytes: usize = 8 * 1024;
const error_transfer_buffer_bytes: usize = 16 * 1024;
const stream_transfer_buffer_bytes: usize = 256 * 1024;
const max_refusal_detail_bytes: usize = 256;
const max_refusal_parse_bytes: usize = 8 * 1024;
const refused_api_key_cli_message = "Google refused this Gemini API key. Paste a valid key: fx login google --api-key.";
const refused_api_key_tui_message = "Google refused this Gemini API key. Paste a valid key: /provider google api-key";

pub const bundle_capabilities: provider_set.Bundle.Capabilities = .{ .sends_output_limit = false, .declares_effort_levels = true };

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
    .build_request_fn = buildRequestForProvider,
    .project_replay_fn = gemini_interactions_protocol.project_replay,
};

pub fn acceptsCredential(lease: stream_provider.CredentialLease) bool {
    return routeForCredential(lease.credentialSource()) != null;
}

pub fn validApiKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

pub fn resolveThinkingLevel(
    model_id: []const u8,
    reasoning: ?types.ReasoningEffort,
) error{UnsupportedGoogleThinkingLevel}!?gemini_interactions_protocol.ThinkingLevel {
    const effort = reasoning orelse return null;
    return google_gemini_models.thinkingLevel(model_id, effort) orelse error.UnsupportedGoogleThinkingLevel;
}

/// Caller owns the returned slice.
pub fn unsupportedThinkingLevelMessage(
    alloc: Allocator,
    model_id: []const u8,
    effort: types.ReasoningEffort,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    writeUnsupportedThinkingLevelMessage(&out.writer, model_id, effort) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUnsupportedThinkingLevelMessage(
    writer: *std.Io.Writer,
    model_id: []const u8,
    effort: types.ReasoningEffort,
) std.Io.Writer.Error!void {
    try writer.print("{s} does not support reasoning effort \"{s}\"", .{ model_id, effort.label() });
    var count: usize = 0;
    for (std.meta.tags(gemini_interactions_protocol.ThinkingLevel)) |level| {
        const parsed = types.ReasoningEffort.parse(@tagName(level)) orelse continue;
        if (google_gemini_models.thinkingLevel(model_id, parsed) == null) continue;
        try writer.writeAll(if (count == 0) "; supported levels: " else ", ");
        try writer.writeAll(@tagName(level));
        count += 1;
    }
    if (count == 0) {
        try writer.writeAll("; model is not in the Gemini catalog");
    }
}

fn traceUnsupportedThinkingLevel(alloc: Allocator, model_id: []const u8, effort: types.ReasoningEffort) void {
    const detail = unsupportedThinkingLevelMessage(alloc, model_id, effort) catch return;
    defer alloc.free(detail);
    debug_trace.logf("gateway", "google_gemini_preflight_rejected detail={s}", .{detail});
}

fn resolveThinkingLevelOrTrace(
    alloc: Allocator,
    model_id: []const u8,
    reasoning: ?types.ReasoningEffort,
) error{UnsupportedGoogleThinkingLevel}!?gemini_interactions_protocol.ThinkingLevel {
    return resolveThinkingLevel(model_id, reasoning) catch |err| {
        if (reasoning) |effort| traceUnsupportedThinkingLevel(alloc, model_id, effort);
        return err;
    };
}

/// Caller owns the returned request body.
pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    const thinking_level = try resolveThinkingLevelOrTrace(alloc, request.model, request.provider_options.reasoning);
    var outbound = request;
    if (outbound.max_output_tokens) |limit| {
        if (limit != 0) outbound.max_output_tokens = null;
    }
    return gemini_interactions_protocol.build_request(alloc, outbound, .{
        .provider = .google,
        .thinking_level = thinking_level,
    });
}

fn buildRequestForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.RequestData,
) anyerror![]u8 {
    return buildRequest(alloc, request);
}

/// Caller owns the returned endpoint URL.
pub fn selectEndpointForRoute(alloc: Allocator, route: Route, override_url: ?[]const u8) ![]u8 {
    const base = if (override_url) |override| blk: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EGeminiBaseUrl;
        const uri = std.Uri.parse(override) catch return error.InvalidE2EGeminiBaseUrl;
        if (uri.query != null or uri.fragment != null) return error.InvalidE2EGeminiBaseUrl;
        break :blk override;
    } else default_base_url;
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const path = switch (route) {
        .api_key => api_key_path,
        .plan => plan_path,
    };
    return std.mem.concat(alloc, u8, &.{ trimmed, path });
}

/// Caller owns the returned endpoint URL.
pub fn selectInteractionsEndpoint(alloc: Allocator, override_url: ?[]const u8) ![]u8 {
    return selectEndpointForRoute(alloc, .api_key, override_url);
}

/// Caller owns the returned endpoint URL.
pub fn endpointForRoute(alloc: Allocator, route: Route) ![]u8 {
    return selectEndpointForRoute(alloc, route, io_mod.getenv(base_url_env));
}

/// Caller owns the returned endpoint URL.
pub fn interactionsEndpoint(alloc: Allocator) ![]u8 {
    return endpointForRoute(alloc, .api_key);
}

pub const max_extra_headers = 2;

/// Writes Google Gemini API key headers into `buf` and returns the used prefix.
/// Values borrow from `api_key`. Never writes Authorization, DPoP, or X-Goog-User-Project.
pub fn extraHeaders(buf: *[max_extra_headers]std.http.Header, api_key: ?[]const u8) []std.http.Header {
    var count: usize = 0;
    buf[count] = .{ .name = "accept", .value = "text/event-stream" };
    count += 1;
    if (api_key) |key| {
        buf[count] = .{ .name = "x-goog-api-key", .value = key };
        count += 1;
    }
    return buf[0..count];
}

pub fn bodyStallTimeoutMs(deadline: ?std.Io.Clock.Timestamp) i64 {
    if (deadline != null) return std.math.maxInt(i64);
    if (comptime builtin.is_test) {
        if (gateway_client.test_body_stall_timeout_ms) |ms| return ms;
    }
    return stream_stall_timeout_ms;
}

pub const Route = enum {
    api_key,
    plan,
};

pub fn routeForCredential(source: ?types.CredentialSource) ?Route {
    const kind = source orelse return null;
    return switch (kind) {
        .gemini_api_key, .host_managed => .api_key,
        .google_subscription => .plan,
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .fx_login,
        .stored_key,
        .chatgpt_subscription,
        .grok_subscription,
        .configured,
        => null,
    };
}

fn validatedRoute(lease: stream_provider.CredentialLease) !Route {
    const route = routeForCredential(lease.credentialSource()) orelse return error.GeminiCredentialRequired;
    switch (route) {
        .api_key => {
            if (lease.credentialSource() == .host_managed) return .api_key;
            const key = lease.secret() orelse return error.GeminiCredentialRequired;
            if (!validApiKey(key)) return error.InvalidGeminiApiKey;
        },
        .plan => {
            const key = switch (lease) {
                .direct => |direct| direct.secret_bytes,
                .host_managed => return error.GeminiCredentialRequired,
            };
            if (!validApiKey(key)) return error.GeminiCredentialRequired;
        },
    }
    return route;
}

/// Formats a reset duration in whole hours and minutes. Caller owns the slice.
pub fn formatResetDuration(alloc: Allocator, seconds: u64) Allocator.Error![]u8 {
    if (seconds < 60) return alloc.dupe(u8, "under a minute");
    const hours = seconds / 3_600;
    const minutes = (seconds % 3_600) / 60;
    if (hours > 0 and minutes > 0) {
        return alloc.print("{d} h {d} min", .{ hours, minutes });
    }
    if (hours > 0) {
        return alloc.print("{d} h", .{hours});
    }
    return alloc.print("{d} min", .{minutes});
}

pub const HttpFailurePlan = struct {
    kind: stream_provider.FailureKind,
    daily_limit: bool = false,
    message: []u8,
    interactive_message: ?[]u8 = null,
    retry_after_seconds: ?u64,
};

/// Maps an HTTP error response through `gemini_errors.classify` to fx's
/// `FailureKind`, a route-appropriate short user message, and preserved `Retry-After`.
/// Caller owns `message`.
pub fn classifyHttpFailure(
    alloc: Allocator,
    route: Route,
    status: std.http.Status,
    body: []const u8,
    retry_after_header: ?[]const u8,
    credential_secret: ?[]const u8,
) Allocator.Error!HttpFailurePlan {
    const status_code = @backingInt(status);
    const parsed_retry_after = if (retry_after_header) |raw|
        std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null
    else
        null;
    const classification = gemini_errors.classify(status_code, body, retry_after_header);
    return switch (classification) {
        .rate_limited => |limited| .{
            .kind = .rate_limited,
            .message = try alloc.print("Rate limited by Gemini; retry in {d} s.", .{limited.retry_after_s}),
            .retry_after_seconds = parsed_retry_after orelse @as(u64, limited.retry_after_s),
        },
        .daily_limit => |daily| blk: {
            const reset_s: ?u64 = if (daily.reset_after_s) |secs| @as(u64, secs) else parsed_retry_after;
            const message = try formatDailyLimitMessage(alloc, route, daily.model, reset_s, false);
            errdefer alloc.free(message);
            const interactive_message: ?[]u8 = if (route == .plan)
                try formatDailyLimitMessage(alloc, route, daily.model, reset_s, true)
            else
                null;
            break :blk .{
                .kind = .quota_exhausted,
                .daily_limit = true,
                .message = message,
                .interactive_message = interactive_message,
                .retry_after_seconds = parsed_retry_after orelse if (daily.reset_after_s) |secs| @as(u64, secs) else null,
            };
        },
        .model_unavailable => |unavail| .{
            .kind = .invalid_request,
            .message = if (unavail.model) |model|
                try alloc.print("Gemini model {s} is unavailable on this route. Switch to a supported Gemini model.", .{model})
            else
                try alloc.dupe(u8, "This Gemini model is unavailable on this route. Switch to a supported Gemini model."),
            .retry_after_seconds = parsed_retry_after,
        },
        .not_entitled => |plan| blk: {
            if (route == .api_key) {
                break :blk .{
                    .kind = .forbidden,
                    .message = try formatRefusedApiKeyMessage(alloc, status_code, body, credential_secret),
                    .retry_after_seconds = parsed_retry_after,
                };
            }
            break :blk try planRouteNotEntitledFailure(alloc, plan.upgrade_url, parsed_retry_after);
        },
        .api_key_invalid => blk: {
            if (route == .api_key) break :blk try refusedApiKeyFailure(alloc, parsed_retry_after);
            break :blk try planRouteNotEntitledFailure(alloc, gemini_errors.google_ai_plans_url, parsed_retry_after);
        },
        .server_error => .{
            .kind = stream_provider.FailureKind.fromHttpStatus(status),
            .message = try alloc.print("Gemini service error (HTTP {d}); please retry.", .{status_code}),
            .retry_after_seconds = parsed_retry_after,
        },
        .other => |other| blk: {
            const kind = stream_provider.FailureKind.fromHttpStatus(status);
            const message = if (kind == .invalid_request and
                stream_provider.isContextOverflow(.{ .kind = .invalid_request, .detail = @constCast(body) }))
                try alloc.dupe(u8, "Gemini request exceeds the context window.")
            else
                try alloc.print("Gemini request failed (HTTP {d}).", .{other.status});
            break :blk .{
                .kind = kind,
                .message = message,
                .retry_after_seconds = parsed_retry_after,
            };
        },
        .scope_missing,
        .unauthenticated,
        .client_not_authorized,
        .plan_setup_pending,
        .service_disabled,
        .project_not_allowlisted,
        .unsupported_location,
        .stateless_required,
        => try simpleFailurePlan(
            alloc,
            std.meta.activeTag(classification),
            route,
            status_code,
            body,
            parsed_retry_after,
            credential_secret,
        ),
    };
}

fn simpleFailurePlan(
    alloc: Allocator,
    tag: std.meta.Tag(gemini_errors.Classification),
    route: Route,
    status_code: u16,
    body: []const u8,
    retry_after_seconds: ?u64,
    credential_secret: ?[]const u8,
) Allocator.Error!HttpFailurePlan {
    const spec: struct {
        kind: stream_provider.FailureKind,
        message: []const u8,
        refused_on_api_key: bool = false,
    } = switch (tag) {
        .scope_missing => .{ .kind = .forbidden, .message = "Sign in with Google again.", .refused_on_api_key = true },
        .unauthenticated => .{ .kind = .unauthorized, .message = "Google authentication failed. Sign in with Google again.", .refused_on_api_key = true },
        .client_not_authorized => .{ .kind = .forbidden, .message = "Google has turned off sign-in for fx. Use a Gemini API key, or update fx." },
        .plan_setup_pending => .{ .kind = .forbidden, .message = "Google is still setting up your plan for fx. Try again in a few minutes.", .refused_on_api_key = true },
        .service_disabled => .{ .kind = .forbidden, .message = "Generative Language API is disabled for this Google project." },
        .project_not_allowlisted => .{ .kind = .provider_error, .message = "Gemini endpoint or project is not allowlisted (HTTP 404)." },
        .unsupported_location => .{ .kind = .invalid_request, .message = "Gemini API is not available in your current location." },
        .stateless_required => .{ .kind = .invalid_request, .message = "Gemini rejected stored interaction state; stateless mode is required." },
        else => unreachable,
    };
    return .{
        .kind = spec.kind,
        .message = if (spec.refused_on_api_key and route == .api_key)
            try formatRefusedApiKeyMessage(alloc, status_code, body, credential_secret)
        else
            try alloc.dupe(u8, spec.message),
        .retry_after_seconds = retry_after_seconds,
    };
}

fn planRouteNotEntitledFailure(
    alloc: Allocator,
    upgrade_url: []const u8,
    retry_after_seconds: ?u64,
) Allocator.Error!HttpFailurePlan {
    const message = try alloc.print(
        "Your Google account needs an active Google AI Pro or Google AI Ultra subscription to use your plan in fx. Upgrade: {s}. Or use a Gemini API key: fx login google --api-key.",
        .{upgrade_url},
    );
    errdefer alloc.free(message);
    const interactive_message = try alloc.print(
        "Your Google account needs an active Google AI Pro or Google AI Ultra subscription to use your plan in fx. Upgrade: {s} \u{00b7} Use a Gemini API key: /provider google api-key",
        .{upgrade_url},
    );
    return .{
        .kind = .forbidden,
        .message = message,
        .interactive_message = interactive_message,
        .retry_after_seconds = retry_after_seconds,
    };
}

fn refusedApiKeyFailure(alloc: Allocator, retry_after_seconds: ?u64) Allocator.Error!HttpFailurePlan {
    const message = try alloc.dupe(u8, refused_api_key_cli_message);
    errdefer alloc.free(message);
    const interactive_message = try alloc.dupe(u8, refused_api_key_tui_message);
    return .{
        .kind = .forbidden,
        .message = message,
        .interactive_message = interactive_message,
        .retry_after_seconds = retry_after_seconds,
    };
}

fn formatRefusedApiKeyMessage(
    alloc: Allocator,
    status_code: u16,
    body: []const u8,
    credential_secret: ?[]const u8,
) Allocator.Error![]u8 {
    const detail = try extractRedactedRefusalDetail(alloc, body, credential_secret);
    defer if (detail) |text| alloc.free(text);
    if (detail) |text| {
        return alloc.print("Google refused this Gemini API key (HTTP {d}). {s}", .{ status_code, text });
    }
    return alloc.print("Google refused this Gemini API key (HTTP {d}).", .{status_code});
}

fn extractRedactedRefusalDetail(
    alloc: Allocator,
    body: []const u8,
    credential_secret: ?[]const u8,
) Allocator.Error!?[]u8 {
    const bounded = body[0..@min(body.len, max_refusal_parse_bytes)];
    const extracted = try extractErrorMessage(alloc, bounded);
    defer if (extracted) |text| alloc.free(text);
    const candidate = extracted orelse std.mem.trim(u8, bounded, " \t\r\n");
    if (candidate.len == 0) return null;
    const prefix = text_utils.utf8PrefixByBytes(candidate, max_refusal_detail_bytes);
    if (prefix.len == 0) return null;
    const owned = try alloc.dupe(u8, prefix);
    const redacted = try chat_completions_protocol.redactOwnedErrorBody(alloc, owned, credential_secret);
    if (redacted.len == 0) {
        alloc.free(redacted);
        return null;
    }
    return redacted;
}

fn extractErrorMessage(alloc: Allocator, body: []const u8) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err_val = parsed.value.object.get("error") orelse return null;
    if (err_val != .object) return null;
    const msg_val = err_val.object.get("message") orelse return null;
    if (msg_val != .string) return null;
    const trimmed = std.mem.trim(u8, msg_val.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

fn formatDailyLimitMessage(
    alloc: Allocator,
    route: Route,
    model: ?[]const u8,
    reset_after_s: ?u64,
    interactive: bool,
) Allocator.Error![]u8 {
    const reset_duration: ?[]u8 = if (reset_after_s) |secs| try formatResetDuration(alloc, secs) else null;
    defer if (reset_duration) |text| alloc.free(text);
    const reset_prefix = if (reset_duration != null) "; resets in " else "";
    const reset_text = reset_duration orelse "";
    const suffix = if (route == .plan and interactive)
        ". Switch models: /model \u{00b7} Use a Gemini API key: /provider google api-key"
    else if (route == .plan)
        ". Switch models or try again after reset. Or use a Gemini API key: fx login google --api-key."
    else
        ". Switch models or try again after reset.";
    return alloc.print("Daily limit reached for {s}{s}{s}{s}", .{
        model orelse "Gemini",
        reset_prefix,
        reset_text,
        suffix,
    });
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    _ = validatedRoute(request.credential) catch |err| return stream_provider.failResult(err);
    _ = resolveThinkingLevelOrTrace(alloc, request.model, request.provider_options.reasoning) catch |err| {
        return stream_provider.failResult(err);
    };
    const payload = request.prepared_request_body orelse
        try buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);

    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        if (requestDeadlineExpired(request)) return stream_provider.failResult(error.Timeout);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return stream_provider.failResult(error.Timeout);
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    const route = validatedRoute(request.credential) catch |err| return stream_provider.failResult(err);
    const request_endpoint = endpointForRoute(alloc, route) catch |err| return stream_provider.failResult(err);
    defer alloc.free(request_endpoint);
    const uri = try std.Uri.parse(request_endpoint);

    const authorization: ?[]u8 = if (route == .plan)
        try alloc.print("Bearer {s}", .{request.credential.direct.secret_bytes})
    else
        null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);

    var extra_headers_buf: [max_extra_headers]std.http.Header = undefined;
    const api_key: ?[]const u8 = if (route == .api_key) request.credential.secret() else null;
    const extra_headers = extraHeaders(&extra_headers_buf, api_key);

    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }
    try request.admission.admit();
    var opened = try gateway_client.openBoundedPost(request.cancel_flag, connect_deadline, .{
        .uri = uri,
        .authorization = authorization,
        .extra_headers = extra_headers,
    });
    defer opened.deinit();
    const http_request = &opened.request;
    var watch: gateway_client.ConnectionWatch = .init(.{
        .patient = true,
        .stall_timeout_ms = bodyStallTimeoutMs(request.deadline),
    });
    defer watch.stop();
    if (http_request.connection) |connection| {
        try watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [send_buffer_bytes]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    if (watch.armHead()) |err| return err;
    var response = http_request.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;

    if (response.head.status != .ok) {
        // Read Retry-After before reading the body, which reuses the head's buffer.
        const retry_after = gateway_client.retryAfterSeconds(response.head);
        var retry_after_buf: [32]u8 = undefined;
        const retry_after_str: ?[]const u8 = if (retry_after) |secs|
            std.mem.print(&retry_after_buf, "{d}", .{secs}) catch null
        else
            null;
        var transfer: [error_transfer_buffer_bytes]u8 = undefined;
        const reader = response.reader(&transfer);
        const body: ?[]u8 = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => null,
            else => return watch.failure(err),
        };
        defer if (body) |bytes| alloc.free(bytes);
        const plan = try classifyHttpFailure(
            alloc,
            route,
            response.head.status,
            body orelse "",
            retry_after_str,
            request.credential.secret(),
        );
        var pending_interactive = plan.interactive_message;
        errdefer if (pending_interactive) |msg| alloc.free(msg);
        const detail = try chat_completions_protocol.redactOwnedErrorBody(
            alloc,
            plan.message,
            request.credential.secret(),
        );
        errdefer alloc.free(detail);
        const interactive_detail: ?[]u8 = if (pending_interactive) |msg| blk: {
            pending_interactive = null;
            break :blk try chat_completions_protocol.redactOwnedErrorBody(
                alloc,
                msg,
                request.credential.secret(),
            );
        } else null;
        return .{
            .failed = .{
                .kind = plan.kind,
                .daily_limit = plan.daily_limit,
                .http_status = response.head.status,
                .detail = detail,
                .interactive_detail = interactive_detail,
                .retry_after_seconds = plan.retry_after_seconds,
                .ownership = .owned,
            },
        };
    }

    var transfer_buffer: [stream_transfer_buffer_bytes]u8 = undefined;
    var result = gemini_interactions_protocol.consume_stream(
        alloc,
        response.reader(&transfer_buffer),
        request.data(),
        .{},
        request.events,
        request.cancel_flag,
        watch.progress(),
    ) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    if (result == .failed) {
        if (result.failed.detail) |detail| {
            result.failed.detail = null;
            result.failed.detail = chat_completions_protocol.redactOwnedErrorBody(
                alloc,
                detail,
                request.credential.secret(),
            ) catch |err| {
                result.deinit(alloc);
                return err;
            };
        }
    }
    return result;
}

// Tests.

fn ignoreTestEvent(_: *anyopaque, _: stream_provider.Event) void {}

const AdmissionTracker = struct {
    calls: usize = 0,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
    }
};

const TestRequestState = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    delivery: stream_provider.DeliveryCertainty = stream_provider.DeliveryCertainty.init(),
    evidence: stream_provider.AttemptEvidence = .{},
    callback_ctx: u8 = 0,
    admission: AdmissionTracker = .{},

    fn request(
        self: *@This(),
        secret_value: []const u8,
        source: types.CredentialSource,
    ) stream_provider.ModelRequest {
        return .{
            .credential = .{ .direct = .{
                .secret_bytes = secret_value,
                .source = source,
            } },
            .model = google_gemini_models.default_model,
            .retry_count = 1,
            .messages = &.{.{ .role = .user, .content = "hi" }},
            .tool_choice = .none,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &self.delivery,
            .attempt_evidence = &self.evidence,
            .events = .{ .context = &self.callback_ctx, .emit_fn = ignoreTestEvent },
            .admission = .{ .context = &self.admission, .admit_fn = AdmissionTracker.admit },
            .cancel_flag = &self.cancelled,
        };
    }
};

const TestResponseMode = union(enum) {
    ok_sse: []const u8,
    stalled_sse,
    http_error: struct {
        status_line: []const u8,
        retry_after: ?[]const u8 = null,
        body: []const u8,
    },
    error_body_splat: usize,
};

const CapturedRequest = struct {
    method: []u8 = &.{},
    target: []u8 = &.{},
    headers_raw: []u8 = &.{},
    body: []u8 = &.{},

    fn deinit(self: *CapturedRequest, alloc: Allocator) void {
        alloc.free(self.method);
        alloc.free(self.target);
        alloc.free(self.headers_raw);
        alloc.free(self.body);
        self.* = .{};
    }

    fn headerValue(self: *const CapturedRequest, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.headers_raw, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }
};

const TestResponseFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: TestResponseMode,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    reached_stage: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    captured: CapturedRequest = .{},

    fn init(mode: TestResponseMode) !@This() {
        var fixture: @This() = .{
            .server = undefined,
            .mode = mode,
        };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *@This()) void {
        if (!self.server_open) return;
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.server.deinit(self.io());
        self.server_open = false;
    }

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.stop();
        self.captured.deinit(alloc);
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and
                (err == error.BrokenPipe or err == error.ConnectionResetByPeer))
            {
                return;
            }
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var stream = (try testing_listener.acceptUnlessStopping(&self.server, zio, &self.stopping)) orelse return;
        defer stream.close(zio);
        self.captured = try readCapturedRequest(std.heap.c_allocator, zio, stream);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = stream.writer(zio, &buffer);
        switch (self.mode) {
            .ok_sse => |sse_payload| {
                try writer.interface.print(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{sse_payload.len},
                );
                try writer.interface.writeAll(sse_payload);
                try writer.interface.flush();
                self.reached_stage.store(true, .seq_cst);
                return;
            },
            .stalled_sse => {
                try writer.interface.writeAll(
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"event_type\":\"interaction.created\",\"interaction\":{\"id\":\"int_1\",\"status\":\"in_progress\"}}\n\n",
                );
                try writer.interface.flush();
            },
            .http_error => |resp| {
                try writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\n", .{resp.status_line});
                if (resp.retry_after) |ra| {
                    try writer.interface.print("Retry-After: {s}\r\n", .{ra});
                }
                try writer.interface.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{resp.body.len});
                try writer.interface.writeAll(resp.body);
                try writer.interface.flush();
                self.reached_stage.store(true, .seq_cst);
                return;
            },
            .error_body_splat => |body_bytes| {
                try writer.interface.print(
                    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{body_bytes},
                );
                try writer.interface.splatByteAll('e', body_bytes);
                try writer.interface.flush();
                self.reached_stage.store(true, .seq_cst);
                return;
            },
        }
        self.reached_stage.store(true, .seq_cst);
        while (!self.stopping.load(.seq_cst)) {
            var sleep_io: std.Io.Threaded = .init_single_threaded;
            sleep_io.io().sleep(.fromMilliseconds(5), .real) catch {};
        }
    }
};

fn readCapturedRequest(alloc: Allocator, zio: std.Io, stream: std.Io.net.Stream) !CapturedRequest {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &socket_buffer);
    var head_buf: [16 * 1024]u8 = undefined;
    var head_len: usize = 0;
    while (head_len < head_buf.len) {
        head_buf[head_len] = try reader.interface.takeByte();
        head_len += 1;
        if (!std.mem.endsWith(u8, head_buf[0..head_len], "\r\n\r\n")) continue;
        const raw_head = head_buf[0 .. head_len - 4];
        const line_end = std.mem.find(u8, raw_head, "\r\n") orelse raw_head.len;
        const request_line = raw_head[0..line_end];
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse "";
        const target = parts.next() orelse "";
        const headers_slice = if (line_end + 2 <= raw_head.len) raw_head[line_end + 2 ..] else "";

        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, headers_slice, "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len < prefix.len or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) continue;
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10);
            break;
        }
        const body = try alloc.alloc(u8, content_length);
        errdefer alloc.free(body);
        if (content_length > 0) try reader.interface.readSliceAll(body);

        const owned_method = try alloc.dupe(u8, method);
        errdefer alloc.free(owned_method);
        const owned_target = try alloc.dupe(u8, target);
        errdefer alloc.free(owned_target);
        const owned_headers = try alloc.dupe(u8, headers_slice);
        return .{
            .method = owned_method,
            .target = owned_target,
            .headers_raw = owned_headers,
            .body = body,
        };
    }
    return error.TestRequestTooLarge;
}

const TestServerRun = struct {
    alloc: Allocator,
    fixture: TestResponseFixture,
    base_url: []u8,
    env_map: std.process.Environ.Map,
    state: TestRequestState = .{},

    fn start(alloc: Allocator, mode: TestResponseMode) !*@This() {
        const self = try alloc.create(@This());
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .fixture = try TestResponseFixture.init(mode),
            .base_url = undefined,
            .env_map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.fixture.deinit(std.heap.c_allocator);
        errdefer self.env_map.deinit();
        try self.fixture.start();
        self.base_url = try alloc.print("http://127.0.0.1:{d}", .{self.fixture.port()});
        errdefer alloc.free(self.base_url);
        try self.env_map.put(base_url_env, self.base_url);
        io_mod.setEnvironMap(&self.env_map);
        return self;
    }

    fn stream(self: *@This(), secret_value: []const u8, source: types.CredentialSource) !stream_provider.Result {
        var result = try agent_stream_provider.stream(self.alloc, self.state.request(secret_value, source));
        errdefer result.deinit(self.alloc);
        self.fixture.stop();
        if (self.fixture.failure) |err| return err;
        return result;
    }

    fn deinit(self: *@This()) void {
        io_mod.resetEnvironForTest();
        self.env_map.deinit();
        self.alloc.free(self.base_url);
        self.fixture.deinit(std.heap.c_allocator);
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn testInteractionSse(
    comptime id: []const u8,
    comptime text: []const u8,
    comptime output_tokens: []const u8,
) []const u8 {
    return "event: interaction.created\n" ++
        "data: {\"event_type\":\"interaction.created\",\"interaction\":{\"id\":\"" ++ id ++ "\",\"status\":\"in_progress\",\"object\":\"interaction\",\"model\":\"gemini-4-hydrogen\"}}\n\n" ++
        "event: step.start\n" ++
        "data: {\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"model_output\"}}\n\n" ++
        "event: step.delta\n" ++
        "data: {\"event_type\":\"step.delta\",\"index\":0,\"delta\":{\"type\":\"text\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "event: step.stop\n" ++
        "data: {\"event_type\":\"step.stop\",\"index\":0}\n\n" ++
        "event: interaction.completed\n" ++
        "data: {\"event_type\":\"interaction.completed\",\"interaction\":{\"id\":\"" ++ id ++ "\",\"status\":\"completed\",\"usage\":{\"total_input_tokens\":5,\"total_output_tokens\":" ++ output_tokens ++ "}}}\n\n" ++
        "event: done\n" ++
        "data: [DONE]\n\n";
}

test "Google Gemini constants match Google docs and 3600s stall budget" {
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com", default_base_url);
    try std.testing.expectEqualStrings("/v1beta/interactions", api_key_path);
    try std.testing.expectEqualStrings("/v1beta/interactions:createPerUserQuota", plan_path);
    try std.testing.expectEqual(@as(i64, 3_600), stream_stall_timeout_seconds);
    try std.testing.expectEqual(@as(i64, 3_600_000), bodyStallTimeoutMs(null));
    try std.testing.expect(!bundle_capabilities.sends_output_limit);
    try std.testing.expect(!bundle_capabilities.fx_search);
    try std.testing.expect(!bundle_capabilities.gateway_prompt_caching);
    try std.testing.expect(!bundle_capabilities.vision_fallback);
    try std.testing.expect(agent_stream_provider.project_replay_fn == gemini_interactions_protocol.project_replay);
}

test "Google Gemini base URL override accepts loopback HTTP only" {
    const alloc = std.testing.allocator;
    const default_url = try selectInteractionsEndpoint(alloc, null);
    defer alloc.free(default_url);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/interactions", default_url);

    for ([_][]const u8{
        "http://127.0.0.1:8080",
        "http://127.0.0.1:8080/",
        "http://localhost:9000",
        "http://[::1]:9001",
    }) |override| {
        const url = try selectInteractionsEndpoint(alloc, override);
        defer alloc.free(url);
        try std.testing.expect(std.mem.endsWith(u8, url, "/v1beta/interactions"));
        try std.testing.expect(std.mem.find(u8, url, "?key=") == null);
    }

    for ([_][]const u8{
        "https://127.0.0.1:8080",
        "http://127.0.0.1",
        "http://evil.example.com:8080",
        "http://127.0.0.1:8080/?key=leak",
        "http://user@127.0.0.1:8080",
    }) |bad| {
        try std.testing.expectError(error.InvalidE2EGeminiBaseUrl, selectInteractionsEndpoint(alloc, bad));
    }
}

test "Google Gemini buildRequest uses .google provider and validates thinking level" {
    const alloc = std.testing.allocator;
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Be concise." }};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hi." }};
    const body = try buildRequest(alloc, .{
        .model = "gemini-4-hydrogen",
        .instructions = &instructions,
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = .auto },
        .max_output_tokens = 65_536,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gemini-4-hydrogen\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking_level\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\"") == null);

    try std.testing.expectError(
        error.UnsupportedGoogleThinkingLevel,
        buildRequest(alloc, .{
            .model = "gemini-4-hydrogen",
            .messages = &messages,
            .tool_choice = .none,
            .provider_options = .{ .reasoning = types.ReasoningEffort.literal("minimal") },
        }),
    );

    const msg = try unsupportedThinkingLevelMessage(alloc, "gemini-4-hydrogen", types.ReasoningEffort.literal("minimal"));
    defer alloc.free(msg);
    try std.testing.expect(std.mem.find(u8, msg, "gemini-4-hydrogen") != null);
    try std.testing.expect(std.mem.find(u8, msg, "low, medium, high, xhigh") != null);
}

test "Google Gemini unsupported effort fails before admission and before sending" {
    var state: TestRequestState = .{};
    var request = state.request("test-gemini-key", .gemini_api_key);
    request.model = "gemini-4-carbon";
    request.provider_options = .{ .reasoning = types.ReasoningEffort.literal("xhigh") };

    try std.testing.expectError(
        error.UnsupportedGoogleThinkingLevel,
        agent_stream_provider.stream(std.testing.allocator, request),
    );
    try std.testing.expectEqual(@as(usize, 0), state.admission.calls);
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, state.delivery.load());
}

test "Google Gemini rejects non-Gemini credentials and invalid API keys before admission" {
    var state: TestRequestState = .{};
    try std.testing.expectError(
        error.GeminiCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, state.request("gateway-key", .ai_gateway_api_key)),
    );
    try std.testing.expectError(
        error.InvalidGeminiApiKey,
        agent_stream_provider.stream(std.testing.allocator, state.request("bad\r\nkey", .gemini_api_key)),
    );
    try std.testing.expectEqual(@as(usize, 0), state.admission.calls);
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, state.delivery.load());
}

test "Google Gemini API key request goes to /v1beta/interactions with x-goog-api-key and no Authorization or DPoP" {
    const alloc = std.testing.allocator;
    const run = try TestServerRun.start(alloc, .{ .ok_sse = testInteractionSse("int_1", "hello from test", "3") });
    defer run.deinit();

    var result = try run.stream("test-gemini-secret-key", .gemini_api_key);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), run.state.admission.calls);
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.possibly_sent, run.state.delivery.load());
    try std.testing.expectEqualStrings("hello from test", result.completed.completion.content.?);
    try std.testing.expectEqualStrings("POST", run.fixture.captured.method);
    try std.testing.expectEqualStrings("/v1beta/interactions", run.fixture.captured.target);
    try std.testing.expect(std.mem.find(u8, run.fixture.captured.target, "key=") == null);
    try std.testing.expectEqualStrings("test-gemini-secret-key", run.fixture.captured.headerValue("x-goog-api-key").?);
    try std.testing.expectEqualStrings("text/event-stream", run.fixture.captured.headerValue("accept").?);
    try std.testing.expectEqualStrings("application/json", run.fixture.captured.headerValue("content-type").?);
    try std.testing.expectEqualStrings(gateway_client.user_agent, run.fixture.captured.headerValue("user-agent").?);
    try std.testing.expect(run.fixture.captured.headerValue("authorization") == null);
    try std.testing.expect(run.fixture.captured.headerValue("dpop") == null);
    try std.testing.expect(run.fixture.captured.headerValue("x-goog-user-project") == null);
    try std.testing.expect(std.mem.find(u8, run.fixture.captured.body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, run.fixture.captured.body, "\"stream\":true") != null);
}

test "Google Gemini 429 daily-limit and 403 plan errors map to quota_exhausted and forbidden" {
    const alloc = std.testing.allocator;
    const daily_body =
        \\{"error":{"code":"too_many_requests","message":"You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models."}}
    ;
    const plan_body =
        \\{"error":{"code":403,"message":"Your account is not eligible for this request. Secret test-gemini-secret-key echoed.","status":"PERMISSION_DENIED"}}
    ;

    {
        const run = try TestServerRun.start(alloc, .{ .http_error = .{
            .status_line = "429 Too Many Requests",
            .retry_after = "19104",
            .body = daily_body,
        } });
        defer run.deinit();

        var result = try run.stream("test-gemini-secret-key", .gemini_api_key);
        defer result.deinit(alloc);

        try std.testing.expectEqual(stream_provider.FailureKind.quota_exhausted, result.failed.kind);
        try std.testing.expectEqual(std.http.Status.too_many_requests, result.failed.http_status.?);
        try std.testing.expectEqual(@as(?u64, 19104), result.failed.retry_after_seconds);
        try std.testing.expectEqualStrings(
            "Daily limit reached for gemini-4-hydrogen; resets in 5 h 18 min. Switch models or try again after reset.",
            result.failed.detail.?,
        );
        try std.testing.expect(std.mem.find(u8, result.failed.detail.?, "Or use a Gemini API key") == null);
        try std.testing.expect(std.mem.find(u8, result.failed.detail.?, "one.google.com") == null);
    }

    {
        const run = try TestServerRun.start(alloc, .{ .http_error = .{
            .status_line = "403 Forbidden",
            .body = plan_body,
        } });
        defer run.deinit();

        var result = try run.stream("test-gemini-secret-key", .gemini_api_key);
        defer result.deinit(alloc);

        try std.testing.expectEqual(stream_provider.FailureKind.forbidden, result.failed.kind);
        try std.testing.expectEqual(std.http.Status.forbidden, result.failed.http_status.?);
        try std.testing.expect(std.mem.startsWith(u8, result.failed.detail.?, "Google refused this Gemini API key (HTTP 403)."));
        try std.testing.expect(std.mem.find(u8, result.failed.detail.?, "Google AI Pro or Ultra plan") == null);
        try std.testing.expect(std.mem.find(u8, result.failed.detail.?, "test-gemini-secret-key") == null);
        try std.testing.expect(std.mem.find(u8, result.failed.detail.?, "***") != null);
    }
}

test "Google Gemini formatResetDuration formats seconds into hours and minutes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        seconds: u64,
        expected: []const u8,
    }{
        .{ .seconds = 0, .expected = "under a minute" },
        .{ .seconds = 59, .expected = "under a minute" },
        .{ .seconds = 60, .expected = "1 min" },
        .{ .seconds = 3_599, .expected = "59 min" },
        .{ .seconds = 3_600, .expected = "1 h" },
        .{ .seconds = 19_104, .expected = "5 h 18 min" },
    };
    for (cases) |case| {
        const formatted = try formatResetDuration(alloc, case.seconds);
        defer alloc.free(formatted);
        try std.testing.expectEqualStrings(case.expected, formatted);
    }
}

test "Google Gemini classifyHttpFailure covers every gemini_errors Classification across routes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        route: Route = .api_key,
        status: std.http.Status,
        body: []const u8,
        retry_after: ?[]const u8 = null,
        secret_value: ?[]const u8 = null,
        kind: stream_provider.FailureKind,
        needle: []const u8,
        interactive_needle: ?[]const u8 = null,
        forbidden_needle: ?[]const u8 = null,
        interactive_forbidden_needle: ?[]const u8 = null,
        expected_retry_after: ?u64 = null,
    }{
        .{
            .status = .too_many_requests,
            .body = "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"Requests per minute limit exceeded.\"}}",
            .retry_after = "7",
            .kind = .rate_limited,
            .needle = "Rate limited",
            .expected_retry_after = 7,
        },
        .{
            .route = .api_key,
            .status = .too_many_requests,
            .body = "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps.\"}}",
            .retry_after = "19104",
            .kind = .quota_exhausted,
            .needle = "Daily limit reached for gemini-4-hydrogen; resets in 5 h 18 min. Switch models or try again after reset.",
            .forbidden_needle = "Or use a Gemini API key.",
            .expected_retry_after = 19104,
        },
        .{
            .route = .plan,
            .status = .too_many_requests,
            .body = "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps.\"}}",
            .retry_after = "45",
            .kind = .quota_exhausted,
            .needle = "Daily limit reached for gemini-4-hydrogen; resets in under a minute. Switch models or try again after reset. Or use a Gemini API key: fx login google --api-key.",
            .interactive_needle = "Daily limit reached for gemini-4-hydrogen; resets in under a minute. Switch models: /model \u{00b7} Use a Gemini API key: /provider google api-key",
            .forbidden_needle = "one.google.com",
            .interactive_forbidden_needle = "one.google.com",
            .expected_retry_after = 45,
        },
        .{
            .status = .bad_request,
            .body = "{\"error\":{\"message\":\"gemini-3.5-flash is not supported for per-user quota.\"}}",
            .kind = .invalid_request,
            .needle = "unavailable on this route",
        },
        .{
            .route = .plan,
            .status = .payment_required,
            .body = "{\"error\":{\"message\":\"Plan required.\"}}",
            .kind = .forbidden,
            .needle = "Your Google account needs an active Google AI Pro or Google AI Ultra subscription to use your plan in fx. Upgrade: https://one.google.com/",
            .interactive_needle = "Use a Gemini API key: /provider google api-key",
        },
        .{
            .route = .api_key,
            .status = .forbidden,
            .body = "{\"error\":{\"message\":\"API key expired for secret-k.\"}}",
            .secret_value = "secret-k",
            .kind = .forbidden,
            .needle = "Google refused this Gemini API key (HTTP 403).",
            .forbidden_needle = "secret-k",
        },
        .{
            .route = .plan,
            .status = .forbidden,
            .body = "{\"error\":{\"message\":\"insufficient authentication scopes\"}}",
            .kind = .forbidden,
            .needle = "Sign in with Google again.",
        },
        .{
            .route = .api_key,
            .status = .forbidden,
            .body = "{\"error\":{\"message\":\"insufficient authentication scopes\"}}",
            .kind = .forbidden,
            .needle = "Google refused this Gemini API key (HTTP 403).",
            .forbidden_needle = "Sign in with Google",
        },
        .{
            .status = .forbidden,
            .body = "{\"error\":{\"message\":\"OAuth client is not authorized.\"}}",
            .kind = .forbidden,
            .needle = "Google has turned off sign-in for fx. Use a Gemini API key, or update fx.",
            .forbidden_needle = "OAuth",
        },
        .{
            .status = .forbidden,
            .body = "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"SERVICE_DISABLED\"}]}}",
            .kind = .forbidden,
            .needle = "disabled for this Google project",
        },
        .{
            .status = .not_found,
            .body = "{\"error\":{\"message\":\"Not found.\"}}",
            .kind = .provider_error,
            .needle = "not allowlisted",
        },
        .{
            .status = .bad_request,
            .body = "{\"error\":{\"message\":\"User location is not supported.\"}}",
            .kind = .invalid_request,
            .needle = "current location",
        },
        .{
            .status = .bad_request,
            .body = "{\"error\":{\"message\":\"Stored interactions aren't supported.\"}}",
            .kind = .invalid_request,
            .needle = "stateless mode",
        },
        .{
            .route = .plan,
            .status = .unauthorized,
            .body = "{\"error\":{\"message\":\"Invalid token.\"}}",
            .kind = .unauthorized,
            .needle = "Sign in with Google again.",
        },
        .{
            .route = .api_key,
            .status = .unauthorized,
            .body = "{\"error\":{\"message\":\"API key not valid.\"}}",
            .kind = .unauthorized,
            .needle = "Google refused this Gemini API key (HTTP 401).",
            .forbidden_needle = "Sign in with Google",
        },
        .{
            .status = .service_unavailable,
            .body = "{\"error\":{\"message\":\"Unavailable.\"}}",
            .kind = .unavailable,
            .needle = "HTTP 503",
        },
        .{
            .status = .bad_request,
            .body = "{\"error\":{\"message\":\"Invalid argument.\"}}",
            .kind = .invalid_request,
            .needle = "HTTP 400",
        },
        .{
            .status = .bad_request,
            .body = "{\"error\":{\"message\":\"Input exceeds the context window.\"}}",
            .kind = .invalid_request,
            .needle = "exceeds the context window",
        },
        .{
            .route = .api_key,
            .status = .bad_request,
            .body = "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"API_KEY_INVALID\",\"domain\":\"googleapis.com\"}]}}",
            .kind = .forbidden,
            .needle = "Google refused this Gemini API key. Paste a valid key: fx login google --api-key.",
            .interactive_needle = "Google refused this Gemini API key. Paste a valid key: /provider google api-key",
            .forbidden_needle = "API key not valid",
        },
        .{
            .route = .plan,
            .status = .bad_request,
            .body = "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"API_KEY_INVALID\",\"domain\":\"googleapis.com\"}]}}",
            .kind = .forbidden,
            .needle = "Your Google account needs an active Google AI Pro or Google AI Ultra subscription to use your plan in fx. Upgrade: https://one.google.com/",
            .interactive_needle = "Use a Gemini API key: /provider google api-key",
        },
    };

    for (cases) |case| {
        const plan = try classifyHttpFailure(alloc, case.route, case.status, case.body, case.retry_after, case.secret_value);
        defer alloc.free(plan.message);
        defer if (plan.interactive_message) |msg| alloc.free(msg);
        try std.testing.expectEqual(case.kind, plan.kind);
        try std.testing.expectEqual(case.expected_retry_after, plan.retry_after_seconds);
        try std.testing.expect(std.mem.find(u8, plan.message, case.needle) != null);
        if (case.forbidden_needle) |forbidden| {
            try std.testing.expect(std.mem.find(u8, plan.message, forbidden) == null);
        }
        if (case.interactive_needle) |interactive| {
            try std.testing.expect(plan.interactive_message != null);
            try std.testing.expect(std.mem.find(u8, plan.interactive_message.?, interactive) != null);
            if (case.interactive_forbidden_needle) |forbidden| {
                try std.testing.expect(std.mem.find(u8, plan.interactive_message.?, forbidden) == null);
            }
        } else {
            try std.testing.expect(plan.interactive_message == null);
        }
    }
    const plan_not_entitled = try classifyHttpFailure(alloc, .plan, .forbidden, "{\"error\":{\"message\":\"Plan required.\"}}", null, null);
    defer alloc.free(plan_not_entitled.message);
    defer if (plan_not_entitled.interactive_message) |msg| alloc.free(msg);
    try std.testing.expect(std.mem.endsWith(u8, plan_not_entitled.message, "Or use a Gemini API key: fx login google --api-key."));
    try std.testing.expect(std.mem.find(u8, plan_not_entitled.interactive_message.?, "Upgrade: https://one.google.com/") != null);
    try std.testing.expect(std.mem.find(u8, plan_not_entitled.interactive_message.?, "Google AI Pro or Google AI Ultra") != null);
}

test "Google Gemini refused API key 400 tells the person which key to paste" {
    const alloc = std.testing.allocator;
    const invalid_key_body =
        \\{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com","metadata":{"service":"generativelanguage.googleapis.com"}}]}}
    ;
    const run = try TestServerRun.start(alloc, .{ .http_error = .{
        .status_line = "400 Bad Request",
        .body = invalid_key_body,
    } });
    defer run.deinit();

    var result = try run.stream("test-gemini-secret-key", .gemini_api_key);
    defer result.deinit(alloc);

    try std.testing.expectEqual(stream_provider.FailureKind.forbidden, result.failed.kind);
    try std.testing.expectEqual(std.http.Status.bad_request, result.failed.http_status.?);
    try std.testing.expectEqualStrings(
        "Google refused this Gemini API key. Paste a valid key: fx login google --api-key.",
        result.failed.detail.?,
    );
    try std.testing.expectEqualStrings(
        "Google refused this Gemini API key. Paste a valid key: /provider google api-key",
        result.failed.interactive_detail.?,
    );
}

test "Google Gemini error body reader bounds oversized payloads" {
    const alloc = std.testing.allocator;
    inline for (.{ max_error_body_bytes, max_error_body_bytes + 1 }) |body_len| {
        const run = try TestServerRun.start(alloc, .{ .error_body_splat = body_len });
        defer run.deinit();

        var result = try run.stream("test-gemini-key", .gemini_api_key);
        defer result.deinit(alloc);

        try std.testing.expectEqual(stream_provider.FailureKind.server_error, result.failed.kind);
        try std.testing.expectEqualStrings("Gemini service error (HTTP 500); please retry.", result.failed.detail.?);
    }
}

test "Google Gemini cancel stops an open stream fast" {
    const alloc = std.testing.allocator;
    const server = try TestServerRun.start(alloc, .stalled_sse);
    defer server.deinit();
    const request = server.state.request("test-gemini-key", .gemini_api_key);

    const Canceller = struct {
        flag: *std.atomic.Value(bool),
        reached: *std.atomic.Value(bool),
        fn run(self: *@This()) void {
            while (!self.reached.load(.seq_cst)) {
                var sleep_io: std.Io.Threaded = .init_single_threaded;
                sleep_io.io().sleep(.fromMilliseconds(2), .real) catch {};
            }
            self.flag.store(true, .seq_cst);
        }
    };
    var canceller: Canceller = .{ .flag = &server.state.cancelled, .reached = &server.fixture.reached_stage };
    const cancel_thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    defer cancel_thread.join();

    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = agent_stream_provider.stream(alloc, request);
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
    server.fixture.stop();

    try std.testing.expectError(error.Cancelled, result);
    if (server.fixture.failure) |err| return err;
    try std.testing.expect(elapsed_ms < 2_000);
}

test "Google Gemini stalled SSE triggers StreamStalled when test stall timeout expires" {
    gateway_client.test_body_stall_timeout_ms = 80;
    defer gateway_client.test_body_stall_timeout_ms = null;

    const alloc = std.testing.allocator;
    const run = try TestServerRun.start(alloc, .stalled_sse);
    defer run.deinit();

    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = agent_stream_provider.stream(alloc, run.state.request("test-gemini-key", .gemini_api_key));
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
    run.fixture.stop();

    try std.testing.expectError(error.StreamStalled, result);
    if (run.fixture.failure) |err| return err;
    try std.testing.expect(run.fixture.reached_stage.load(.seq_cst));
    try std.testing.expect(elapsed_ms >= 70 and elapsed_ms < 2_000);
    try std.testing.expectEqual(stream_provider.NetworkFailureCause.stream_stalled, run.state.evidence.network_failure.?.cause);
}

test "Google Gemini routeForCredential maps only valid Google sources and fails closed on others" {
    try std.testing.expectEqual(@as(?Route, .api_key), routeForCredential(.gemini_api_key));
    try std.testing.expectEqual(@as(?Route, .api_key), routeForCredential(.host_managed));
    try std.testing.expectEqual(@as(?Route, .plan), routeForCredential(.google_subscription));
    for ([_]?types.CredentialSource{
        null,
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .fx_login,
        .stored_key,
        .chatgpt_subscription,
        .grok_subscription,
        .configured,
    }) |source| {
        try std.testing.expectEqual(@as(?Route, null), routeForCredential(source));
    }
}

test "Google Gemini unknown credential source fails closed before admission in stream and streamPrepared" {
    var state: TestRequestState = .{};
    for ([_]types.CredentialSource{ .grok_subscription, .ai_gateway_api_key, .fx_login, .configured }) |source| {
        const request = state.request("secret-token", source);
        try std.testing.expectError(error.GeminiCredentialRequired, agent_stream_provider.stream(std.testing.allocator, request));
        try std.testing.expectError(error.GeminiCredentialRequired, streamPrepared(std.testing.allocator, request, "{}"));
    }
    try std.testing.expectEqual(@as(usize, 0), state.admission.calls);
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, state.delivery.load());
}

test "Google Gemini plan request goes to createPerUserQuota with Bearer and no API key or DPoP" {
    const alloc = std.testing.allocator;
    const run = try TestServerRun.start(alloc, .{ .ok_sse = testInteractionSse("int_plan_1", "hello from ultra plan", "4") });
    defer run.deinit();

    var result = try run.stream("ya29.plan-access-token", .google_subscription);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), run.state.admission.calls);
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.possibly_sent, run.state.delivery.load());
    try std.testing.expectEqualStrings("hello from ultra plan", result.completed.completion.content.?);
    try std.testing.expectEqualStrings("POST", run.fixture.captured.method);
    try std.testing.expectEqualStrings(plan_path, run.fixture.captured.target);
    try std.testing.expect(std.mem.find(u8, run.fixture.captured.target, "key=") == null);
    try std.testing.expectEqualStrings("Bearer ya29.plan-access-token", run.fixture.captured.headerValue("authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", run.fixture.captured.headerValue("accept").?);
    try std.testing.expectEqualStrings("application/json", run.fixture.captured.headerValue("content-type").?);
    try std.testing.expectEqualStrings(gateway_client.user_agent, run.fixture.captured.headerValue("user-agent").?);
    try std.testing.expect(run.fixture.captured.headerValue("x-goog-api-key") == null);
    try std.testing.expect(run.fixture.captured.headerValue("dpop") == null);
    try std.testing.expect(run.fixture.captured.headerValue("x-goog-user-project") == null);
}

test "a project permission 403 on the plan route says Google is still setting up the plan" {
    const alloc = std.testing.allocator;
    const body =
        \\{"error":{"message":"Caller does not have required permission to use project example-project-123. Grant the caller the roles/serviceusage.serviceUsageConsumer role, or a custom role with the serviceusage.services.use permission, by visiting https://console.developers.google.com/iam-admin/iam?project=example-project-123 and then retry. Propagation of the new permission may take a few minutes.","code":"permission_denied"}}
    ;
    const plan = try classifyHttpFailure(alloc, .plan, .forbidden, body, null, null);
    defer alloc.free(plan.message);
    defer if (plan.interactive_message) |msg| alloc.free(msg);
    try std.testing.expectEqualStrings("Google is still setting up your plan for fx. Try again in a few minutes.", plan.message);
    try std.testing.expect(std.mem.find(u8, plan.message, "Ultra") == null);
}

const std = @import("std");
const codec = @import("google_vertex_protocol.zig");
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
const model_provider = @import("../core/config/model_provider.zig");
const Allocator = std.mem.Allocator;

const TokenCache = struct {
    token_buf: [2048]u8 = undefined,
    token_len: usize = 0,
    expires_at_ms: i64 = 0,

    pub fn getValidToken(self: *TokenCache) ?[]const u8 {
        const now = io.milliTimestamp();
        // Require at least 5 minutes (300,000 ms) before expiry
        if (self.token_len > 0 and now + (300 * 1000) < self.expires_at_ms) {
            return self.token_buf[0..self.token_len];
        }
        return null;
    }

    pub fn setToken(self: *TokenCache, token: []const u8, expires_in_s: i64) void {
        if (token.len == 0 or token.len > self.token_buf.len) return;
        @memcpy(self.token_buf[0..token.len], token);
        self.token_len = token.len;
        self.expires_at_ms = io.milliTimestamp() + (expires_in_s * 1000);
    }

    pub fn invalidate(self: *TokenCache) void {
        self.token_len = 0;
        self.expires_at_ms = 0;
    }
};

var global_token_cache: TokenCache = .{};

pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .build_request_fn = build,
            .project_replay_fn = project_replay,
        },
        .model_catalog = .{
            .context = context,
            .fetch_fn = fetch_catalog,
            .lookup_capabilities_fn = lookup_capabilities,
            .provider_id = bound_identity(definition),
        },
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
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

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const definition = definition_at(raw);
    return codec.build_request(alloc, request, .{ .provider = definition });
}

fn project_replay(
    alloc: Allocator,
    replay: ?types.ProviderReplay,
    calls: []const types.ToolCall,
    text: bool,
    reasoning: bool,
) !?types.ProviderReplay {
    return codec.project_replay(alloc, replay, calls, text, reasoning);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

fn fetchGcloudAccessToken(alloc: Allocator) ?[]const u8 {
    const argv = [_][]const u8{ "gcloud", "auth", "print-access-token" };
    var child = std.process.spawn(io.getIo(), .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    errdefer child.kill(io.getIo());

    var stdout_file = child.stdout orelse return null;
    const stdout_bytes = io.readFileToEnd(alloc, &stdout_file, 2048) catch return null;
    defer alloc.free(stdout_bytes);

    const term = child.wait(io.getIo()) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const token = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    if (token.len == 0) return null;
    return alloc.dupe(u8, token) catch null;
}

fn refreshGoogleAdcAccessToken(alloc: Allocator) ![]const u8 {
    const zio = io.getIo();
    var adc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const adc_path: []const u8 = if (io.getenv("GOOGLE_APPLICATION_CREDENTIALS")) |path|
        path
    else blk: {
        const home = io.getenv("HOME") orelse return error.NoAdcFile;
        const joined = std.fmt.bufPrint(&adc_path_buf, "{s}/.config/gcloud/application_default_credentials.json", .{home}) catch return error.NoAdcFile;
        break :blk joined;
    };

    var file = std.Io.Dir.openFileAbsolute(zio, adc_path, .{}) catch return error.NoAdcFile;
    defer file.close(zio);

    const content = io.readFileToEnd(alloc, &file, 64 * 1024) catch return error.AdcReadFailed;
    defer alloc.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return error.AdcParseFailed;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidAdcFormat;
    const root = parsed.value.object;

    const client_id_val = root.get("client_id") orelse return error.MissingClientId;
    const client_secret_val = root.get("client_secret") orelse return error.MissingClientSecret;
    const refresh_token_val = root.get("refresh_token") orelse return error.MissingRefreshToken;

    if (client_id_val != .string or client_secret_val != .string or refresh_token_val != .string) return error.InvalidAdcFormat;

    const payload = try std.fmt.allocPrint(
        alloc,
        "grant_type=refresh_token&client_id={s}&client_secret={s}&refresh_token={s}",
        .{ client_id_val.string, client_secret_val.string, refresh_token_val.string },
    );
    defer alloc.free(payload);

    var client: std.http.Client = .{ .allocator = alloc, .io = zio };
    defer client.deinit();

    const uri = try std.Uri.parse("https://oauth2.googleapis.com/token");
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = null,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        },
    };

    var cancel_stub: std.atomic.Value(bool) = .init(false);
    var opened = try client_mod.openBoundedPost(alloc, &cancel_stub, phase_deadline(15_000, null), &operation);
    defer opened.deinit(alloc);

    const http = &opened.request.?;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [4096]u8 = undefined;

    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |conn| try conn.flush();

    var response = try http.receiveHead(&.{});
    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);

    if (response.head.status != .ok) return error.OauthRefreshFailed;

    const resp_body = try reader.allocRemaining(alloc, .limited(16 * 1024));
    defer alloc.free(resp_body);

    var resp_parsed = std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{}) catch return error.InvalidTokenResponse;
    defer resp_parsed.deinit();

    if (resp_parsed.value != .object) return error.InvalidTokenResponse;
    const token_val = resp_parsed.value.object.get("access_token") orelse return error.MissingAccessToken;
    const expires_in_val = resp_parsed.value.object.get("expires_in") orelse return error.MissingExpiresIn;

    if (token_val != .string or expires_in_val != .integer) return error.InvalidTokenResponse;

    global_token_cache.setToken(token_val.string, expires_in_val.integer);
    return try alloc.dupe(u8, token_val.string);
}

fn getEffectiveToken(alloc: Allocator, request: streams.ModelRequest) ![]const u8 {
    // 1. Cached in-memory token (valid with >= 5m headroom)
    if (global_token_cache.getValidToken()) |cached| {
        return try alloc.dupe(u8, cached);
    }

    // 2. Direct HTTP refresh via Application Default Credentials
    if (refreshGoogleAdcAccessToken(alloc)) |token| {
        return token;
    } else |_| {}

    // 3. Fallback to gcloud subprocess
    if (fetchGcloudAccessToken(alloc)) |token| {
        global_token_cache.setToken(token, 3500);
        return token;
    }

    // 4. Fallback to environment variable / credential secret
    if (request.credential.secret()) |sec| {
        if (sec.len > 0) return try alloc.dupe(u8, sec);
    }

    return error.MissingConfiguredProviderCredential;
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);

    const token = try getEffectiveToken(alloc, request);
    defer alloc.free(token);

    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);

    var result = post(alloc, definition, request, token, payload) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };

    // Auto-Recovery on HTTP 401 Unauthorized:
    // If token expired mid-session or was invalidated, force an eager refresh and replay once.
    if (result == .failed and result.failed.kind == .unauthorized) {
        global_token_cache.invalidate();
        var refreshed_token: ?[]const u8 = refreshGoogleAdcAccessToken(alloc) catch null;
        if (refreshed_token == null) {
            refreshed_token = fetchGcloudAccessToken(alloc);
        }
        if (refreshed_token) |fresh| {
            defer alloc.free(fresh);
            result.deinit(alloc);
            result = post(alloc, definition, request, fresh, payload) catch |err| {
                request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
                if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
                return err;
            };
        }
    }

    return result;
}

fn post(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.ModelRequest,
    token: []const u8,
    payload: []const u8,
) !streams.Result {
    const url = try definition.vertex_stream_url(alloc, request.model);
    defer alloc.free(url);

    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer secret.zeroAndFree(alloc, authorization);

    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();

    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;

    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        },
    };

    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);

    const http = &opened.request.?;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |conn| try conn.flush();

    var response = try http.receiveHead(&.{});
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);

    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Vertex AI error response exceeded local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        const redacted = try codec.redact_error_detail(alloc, detail, token);
        alloc.free(detail);
        detail = redacted;

        return .{
            .failed = .{
                .kind = switch (response.head.status) {
                    .bad_request => .invalid_request,
                    .unauthorized => .unauthorized,
                    .forbidden => .forbidden,
                    .too_many_requests => .rate_limited,
                    else => .provider_error,
                },
                .detail = detail,
                .ownership = .owned,
            },
        };
    }

    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag);
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).model(model) orelse return .{};
    var caps = model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(.{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_tool_use = metadata.supports_tool_use orelse true,
        .context_window = metadata.context_window orelse 1048576,
        .max_tokens = metadata.max_output_tokens orelse 8192,
    }));
    caps.supports_reasoning = true;
    return caps;
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, _: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |meta| {
        try entries.append(alloc, .{
            .id = try alloc.dupe(u8, meta.id),
            .model_type = try alloc.dupe(u8, "language"),
            .has_tool_use = meta.supports_tool_use orelse true,
            .context_window = meta.context_window orelse 1048576,
            .max_tokens = meta.max_output_tokens orelse 8192,
        });
    }
    return .{ .catalog = entries };
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
            const ids = catalog.projectModelIds(alloc, entries.items) catch
                return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
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
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
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

test "vertex permission review fails closed without credentials instead of rubber-stamping clear" {
    const definition = definitions.Definition{
        .id = "vertex",
        .protocol = .@"google-vertex",
        .base_url = "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models",
        .auth = .{ .bearer = "VERTEX_TOKEN" },
        .reviewer_model = "gemini-3.8-flash",
    };
    const pending = types.ChatMessage{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "call_1",
            .name = "glob_files",
            .arguments_json = "{\"pattern\":\"*\"}",
        }},
    };
    const request = classifier.ReviewRequest{
        .review_turn = .{
            .model = "gemini-3.8-flash",
            .pending_assistant = pending,
            .target_call_id = "call_1",
            .origin = .root,
            .trusted_root_context = "User asked to inspect the repository.",
        },
        .targets = &.{},
        .action = .{ .tool = .{
            .tool_name = "glob_files",
            .arguments_json = "{\"pattern\":\"*\"}",
        } },
    };
    var outcome = try review(@ptrCast(@constCast(&definition)), std.testing.allocator, .{
        .credential = "",
        .credential_source = .configured,
    }, request);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.meta.Tag(classifier.ParseOutcome).invalid, std.meta.activeTag(outcome));
    try std.testing.expectEqual(classifier.InvalidReason.transport_permanent, outcome.invalid);
}

//! Provider bundle for custom OpenAI-compatible endpoints.
//!
//! Setting FX_BASE_URL (for example `https://api.openai.com/v1` or
//! `http://localhost:11434/v1`) routes inference to that endpoint using the
//! OpenAI chat-completions protocol instead of Vercel AI Gateway. FX_API_KEY
//! is the only credential ever sent to the custom endpoint; Vercel
//! credentials resolved by the auth runtime never leave the process in this
//! mode. Gateway-only features (credits, generation usage reconciliation,
//! provider-executed web search) degrade to unavailable.

const std = @import("std");

const agent_stream_provider_contract = @import("../core/agent/stream_provider.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const collections = @import("../core/shared/collections.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_client = @import("../gateway/client.zig");
const gateway_failure_diagnostics = @import("../core/gateway/gateway_failure_diagnostics.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const generation_usage_provider = @import("../core/session/generation_usage_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const custom_endpoint = @import("../core/config/custom_endpoint.zig");
const credentials = @import("../core/auth/credentials.zig");
const openai_json = @import("../core/gateway/openai_json.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const tool_advertisement = @import("../core/tooling/tool_advertisement.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const builtin_gateway = @import("gateway.zig");

const Allocator = std.mem.Allocator;

pub const base_url_env = custom_endpoint.base_url_env;
pub const api_key_env = custom_endpoint.api_key_env;

const chat_completions_path = "/chat/completions";
const models_path = "/models";
const max_endpoint_url_bytes = 2048;
const models_response_max_bytes: usize = 4 * 1024 * 1024;

/// A custom endpoint is active for this process when FX_BASE_URL holds an
/// http(s) URL, or `fx setup --base-url` stored one in the user profile.
pub fn isConfigured() bool {
    return custom_endpoint.isConfigured();
}

fn baseUrl() ?[]const u8 {
    return custom_endpoint.baseUrl();
}

/// The credential to send to the custom endpoint. FX_API_KEY wins; otherwise
/// the resolved credential is used, which `credentials.loadSource` guarantees
/// is endpoint-scoped whenever an endpoint is configured. The keyless
/// placeholder maps back to sending no Authorization header at all.
fn endpointCredential(resolved: []const u8) []const u8 {
    const env_key = custom_endpoint.envApiKey();
    if (env_key.len > 0) return env_key;
    if (std.mem.eql(u8, resolved, credentials.custom_endpoint_keyless_placeholder)) return "";
    return resolved;
}

var chat_url_buf: [max_endpoint_url_bytes]u8 = undefined;
var models_url_buf: [max_endpoint_url_bytes]u8 = undefined;

fn endpointUrl(buf: []u8, path: []const u8) ?[]const u8 {
    const base = baseUrl() orelse return null;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..path.len], path);
    return buf[0 .. base.len + path.len];
}

pub fn chatUrl() ?[]const u8 {
    return endpointUrl(&chat_url_buf, chat_completions_path);
}

fn modelsUrl() ?[]const u8 {
    return endpointUrl(&models_url_buf, models_path);
}

fn resolveChatUrlForProvider(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return chatUrl() orelse fallback;
}

fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.BuildRequest,
) anyerror![]u8 {
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
    }
    if (request.verified_images != null or request.response_format != null) {
        return error.StructuredOutputUnsupportedForProvider;
    }
    if (request.vision_mode == .required) return error.VisionUnsupportedForProvider;

    const tools_json = if (request.selected_dynamic_tool_schemas.len > 0)
        try tool_advertisement.buildGatewayToolsJsonWithSelectedDynamicSchemas(
            alloc,
            request.serialized_tools,
            request.selected_dynamic_tool_schemas,
        )
    else
        request.serialized_tools;
    defer if (request.selected_dynamic_tool_schemas.len > 0) alloc.free(@constCast(tools_json));

    return openai_json.buildChatCompletionsBody(alloc, .{
        .model = request.model,
        .tools_json = tools_json,
        .messages = request.messages,
        .tool_choice = request.tool_choice,
        .max_output_tokens = request.max_output_tokens,
    });
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.Request,
) anyerror!agent_stream_provider_contract.Result {
    const chat_url = chatUrl() orelse return error.OpenAiEndpointUnconfigured;
    const result = gateway_client.streamGatewayCompletion(
        alloc,
        .{
            .api_key = endpointCredential(request.api_key),
            .team = null,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .chat_url = chat_url,
            .payload = request.payload,
            .protocol = .openai_compat,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .provider_attempt_owner = switch (request.provider_attempt_owner) {
                .transport => .transport,
                .agent => .agent,
            },
        },
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.cancel_flag,
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
    const diagnostics = if (result.status == .ok)
        gateway_failure_diagnostics.FailureDiagnostics{}
    else
        gateway_failure_diagnostics.collect(alloc, request.payload, result.err_body);
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .generation_origin = "",
        .reconcile_generation_usage = false,
        .failure_schema = diagnostics.schema,
        .failure_request_shape = diagnostics.request_shape,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

fn catalogFailureForStatus(status: std.http.Status) model_catalog.Failure {
    const code = @intFromEnum(status);
    if (status == .unauthorized or status == .forbidden) {
        return .{ .category = .authentication, .http_status = status };
    }
    if (status == .too_many_requests) {
        return .{ .category = .rate_limited, .http_status = status, .retryable = true };
    }
    if (code >= 500) {
        return .{ .category = .gateway_unavailable, .http_status = status, .retryable = true };
    }
    return .{ .category = .http_status, .http_status = status };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    }
    const url = modelsUrl() orelse return .{ .failure = .{ .category = .transport } };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| alloc.free(value);
    var headers: std.http.Client.Request.Headers = .{};
    headers.user_agent = .{ .override = gateway_client.user_agent };
    const key = endpointCredential(input.access.authorizationCredential() orelse "");
    if (key.len > 0) {
        auth_header = std.fmt.allocPrint(alloc, "Bearer {s}", .{key}) catch |err| return err;
        headers.authorization = .{ .override = auth_header.? };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("gateway", "openai models fetch failed err={s}", .{@errorName(err)});
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    };
    if (response.status != .ok) return .{ .failure = catalogFailureForStatus(response.status) };
    if (out.written().len > models_response_max_bytes) {
        return .{ .failure = .{ .category = .malformed_response } };
    }

    return parseOpenAiModelCatalog(alloc, out.written());
}

/// Parses the OpenAI `GET /models` shape: `{"data":[{"id":"...",...}]}`.
/// Every listed model is treated as a tool-capable language model; context
/// window and vision support stay unknown and resolve through the local
/// capability tables.
fn parseOpenAiModelCatalog(
    alloc: Allocator,
    body: []const u8,
) Allocator.Error!model_catalog.ProviderResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = .{ .category = .malformed_response } };
    const data = parsed.value.object.get("data") orelse
        return .{ .failure = .{ .category = .malformed_response } };
    if (data != .array) return .{ .failure = .{ .category = .malformed_response } };

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (data.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;

        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const released: i64 = if (item.object.get("created")) |created| switch (created) {
            .integer => |value| value,
            else => 0,
        } else 0;
        try entries.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = released,
            .has_tool_use = true,
        });
    }
    return .{ .catalog = entries };
}

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .loaded => |loaded| project: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :project .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failed| .{ .failure = failed },
    };
}

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{
        .err_message = alloc.dupe(u8, "credits are not available for a custom FX_BASE_URL endpoint") catch null,
    };
}

fn resolvePreferredWebSearchBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return &.{};
}

fn executeWebSearchProvider(
    _: ?*anyopaque,
    _: Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    return error.WebSearchUnsupportedForProvider;
}

const unavailable_web_search_provider = web_search_provider.Provider{
    .policy = .{
        .preferred_backends = &.{},
        .backend_policies = &.{},
    },
    .preferred_backends_fn = resolvePreferredWebSearchBackends,
    .execute_fn = executeWebSearchProvider,
};

pub const agent_stream_provider = agent_stream_provider_contract.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrlForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub const credits_provider = gateway_provider.CreditsProvider{
    .fetch_fn = fetchCredits,
};

pub const provider = gateway_provider.Provider{
    .agent_stream = agent_stream_provider,
    // fx login continues to manage Vercel sessions even while inference is
    // routed elsewhere; the OAuth transport never sees the custom endpoint.
    .oauth_transport = builtin_gateway.oauth_transport_provider,
    .chat_url = chat_url_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .credits = credits_provider,
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = unavailable_web_search_provider,
    .model_catalog = model_catalog_provider,
};

var stable_empty_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_empty_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_empty_test_environ = map;
    return map;
}

const EnvOverride = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const [2][]const u8) !*EnvOverride {
        _ = try stableEmptyTestEnviron();
        const self = try alloc.create(EnvOverride);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .map = std.process.Environ.Map.init(alloc) };
        errdefer self.map.deinit();
        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *EnvOverride) void {
        if (stable_empty_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "custom endpoint urls derive from FX_BASE_URL with trailing slash trimmed" {
    const env = try EnvOverride.install(std.testing.allocator, &.{
        .{ base_url_env, "http://localhost:11434/v1/" },
    });
    defer env.deinit();

    try std.testing.expect(isConfigured());
    try std.testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", chatUrl().?);
    try std.testing.expectEqualStrings("http://localhost:11434/v1/models", modelsUrl().?);
    try std.testing.expectEqualStrings(
        "http://localhost:11434/v1/chat/completions",
        chat_url_provider.resolve("https://fallback.test/chat"),
    );
}

test "non-http FX_BASE_URL values are rejected" {
    const env = try EnvOverride.install(std.testing.allocator, &.{
        .{ base_url_env, "file:///etc/passwd" },
    });
    defer env.deinit();

    try std.testing.expect(!isConfigured());
    try std.testing.expect(chatUrl() == null);
    try std.testing.expectEqualStrings(
        "https://fallback.test/chat",
        chat_url_provider.resolve("https://fallback.test/chat"),
    );
}

test "openai model catalog parses the OpenAI list shape" {
    const body =
        \\{"object":"list","data":[{"id":"gpt-5.2","object":"model","created":1700000000},{"id":"","object":"model"},{"id":"llama3.3","object":"model"}]}
    ;
    const result = try parseOpenAiModelCatalog(std.testing.allocator, body);
    var entries = switch (result) {
        .catalog => |catalog| catalog,
        .failure => return error.TestUnexpectedResult,
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &entries);

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("gpt-5.2", entries.items[0].id);
    try std.testing.expect(entries.items[0].has_tool_use);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), entries.items[0].released);
    try std.testing.expectEqualStrings("llama3.3", entries.items[1].id);
}

test "openai model catalog reports malformed and error responses as failures" {
    const malformed = try parseOpenAiModelCatalog(std.testing.allocator, "not json");
    try std.testing.expectEqual(
        model_catalog.FailureCategory.malformed_response,
        malformed.failure.category,
    );

    try std.testing.expectEqual(
        model_catalog.FailureCategory.authentication,
        catalogFailureForStatus(.unauthorized).category,
    );
    try std.testing.expect(catalogFailureForStatus(.internal_server_error).retryable);
}

test "agent request builder produces openai chat completion bodies" {
    const shared_types = @import("../core/shared/types.zig");
    const model_capabilities = @import("../core/config/model_capabilities.zig");
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "llama3.3",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = model_capabilities.resolveProviderOptions("llama3.3", .auto, false),
        .max_output_tokens = 2048,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"llama3.3\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":2048") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "inputSchema") == null);
}

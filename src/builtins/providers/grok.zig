const std = @import("std");
const agent_stream_provider = @import("../../core/agent/stream_provider.zig");
const grok_auth = @import("../../core/providers/grok_auth.zig");
const grok_catalog = @import("../../core/providers/grok_catalog.zig");
const secret = @import("../../core/auth/secret.zig");
const gateway_provider = @import("../../core/gateway/gateway_provider.zig");
const model_catalog = @import("../../core/gateway/model_catalog.zig");
const output_contracts = @import("../../core/output/output_contracts.zig");
const openai_compatible = @import("../../gateway/openai_compatible.zig");
const gateway_client = @import("../../gateway/client.zig");
const oauth_transport = @import("../../core/auth/oauth_transport.zig");
const generation_usage_provider = @import("../../core/session/generation_usage_provider.zig");
const web_search_contract = @import("../../core/tooling/web_search_contract.zig");
const web_search_provider = @import("../../core/tooling/web_search_provider.zig");
const collections = @import("../../core/shared/collections.zig");

const Allocator = std.mem.Allocator;

pub const no_gateway_balance_message = "this backend has no gateway balance";

pub const agent_stream_provider_value = agent_stream_provider.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrl,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub const credits_provider = gateway_provider.CreditsProvider{
    .fetch_fn = fetchCredits,
};

const unavailable_web_search_provider = web_search_provider.Provider{
    .policy = .{
        .preferred_backends = &.{},
        .backend_policies = &.{},
    },
    .preferred_backends_fn = preferredWebSearchBackends,
    .execute_fn = executeWebSearch,
};

pub const provider = gateway_provider.Provider{
    .agent_stream = agent_stream_provider_value,
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = chat_url_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .credits = credits_provider,
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = unavailable_web_search_provider,
    .model_catalog = .{ .fetch_fn = fetchModelCatalog },
};

fn preferredWebSearchBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
    return null;
}

fn executeWebSearch(
    _: ?*anyopaque,
    _: Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    return error.WebSearchUnavailable;
}

fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) anyerror![]u8 {
    var rewritten = request;
    rewritten.model = grok_catalog.resolveModel(request.model);
    return openai_compatible.buildChatCompletionsBody(alloc, rewritten);
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.Request,
) anyerror!agent_stream_provider.Result {
    var owned_token: ?[]u8 = null;
    defer if (owned_token) |value| secret.zeroAndFree(alloc, value);

    var session = grok_auth.loadValidSession(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MissingCredentials,
    };
    defer if (session) |*value| value.deinit(alloc);

    const access_token = blk: {
        if (session) |loaded| {
            owned_token = try alloc.dupe(u8, loaded.access_token);
            break :blk owned_token.?;
        }
        if (request.api_key.len > 0) break :blk request.api_key;
        return error.MissingCredentials;
    };

    const chat_url = blk: {
        if (std.mem.endsWith(u8, request.chat_url, "chat/completions")) break :blk request.chat_url;
        break :blk grok_auth.configuredChatUrl();
    };

    const result = openai_compatible.streamChatCompletions(
        alloc,
        .{
            .api_key = access_token,
            .model = grok_catalog.resolveModel(request.model),
            .retry_count = request.retry_count,
            .chat_url = chat_url,
            .payload = request.payload,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .provider_attempt_owner = request.provider_attempt_owner,
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
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .generation_origin = "",
        .reconcile_generation_usage = false,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

fn resolveChatUrl(_: ?*anyopaque, _: []const u8) []const u8 {
    return grok_auth.configuredChatUrl();
}

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{
        .notice = alloc.dupe(u8, no_gateway_balance_message) catch null,
    };
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    if (tryLiveCatalog(alloc, input)) |result| return result;
    const ids = grok_catalog.ownedIds(alloc) catch {
        return catalogFailure(input);
    };
    return .{
        .loaded = .{
            .ids = ids,
            .provenance = .{
                .access = model_catalog.AccessMetadata.init(input.access),
                .anonymous_fallback_used = false,
            },
        },
    };
}

fn tryLiveCatalog(
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) ?gateway_provider.CliModelCatalogResult {
    const token = grok_auth.loadAccessToken(alloc) catch return null;
    defer if (token) |value| secret.zeroAndFree(alloc, value);
    const api_key = token orelse return null;
    var ids = openai_compatible.fetchModelIds(alloc, api_key, grok_auth.configuredModelsUrl()) catch
        return null;
    if (ids.items.len == 0) {
        collections.freeStringList(alloc, &ids);
        return null;
    }
    return .{
        .loaded = .{
            .ids = ids,
            .provenance = .{
                .access = model_catalog.AccessMetadata.init(input.access),
                .anonymous_fallback_used = false,
            },
        },
    };
}

fn catalogFailure(input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    return .{
        .failure = .{
            .access = model_catalog.AccessMetadata.init(input.access),
            .anonymous_fallback_used = false,
            .failure = .{ .category = .runtime },
        },
    };
}

fn fetchModelCatalog(
    _: ?*anyopaque,
    _: Allocator,
    _: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    return .{ .failure = .{ .category = .runtime } };
}

test "grok credits never claim a gateway balance" {
    var snapshot = fetchCredits(null, std.testing.allocator, .{ .credential = null, .tenant = null });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(no_gateway_balance_message, snapshot.notice.?);
    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.err_message == null);
}

test "grok catalog falls back to documented Grok Build ids" {
    const result = fetchCliModelCatalog(null, std.testing.allocator, .{
        .access = .{ .public_only = .no_credential },
        .endpoint = grok_auth.default_chat_url,
    });
    switch (result) {
        .loaded => |loaded| {
            defer {
                for (loaded.ids.items) |id| std.testing.allocator.free(id);
                var ids = loaded.ids;
                ids.deinit(std.testing.allocator);
            }
            try std.testing.expectEqual(grok_catalog.catalog_ids.len, loaded.ids.items.len);
            try std.testing.expectEqualStrings("grok-4.6", loaded.ids.items[0]);
            try std.testing.expectEqualStrings("grok-build-0.1", loaded.ids.items[3]);
        },
        else => return error.TestUnexpectedCatalogFailure,
    }
}

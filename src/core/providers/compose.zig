const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const providers_config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    vercel: gateway_provider.Provider,
    openai_compatible: gateway_provider.Provider,
    chatgpt: gateway_provider.Provider,
};

pub fn provider(context: *const Context) gateway_provider.Provider {
    return .{
        .agent_stream = .{
            .context = @constCast(context),
            .build_fn = buildAgentRequest,
            .stream_fn = streamAgentCompletion,
        },
        .oauth_transport = context.vercel.oauth_transport,
        .chat_url = .{
            .context = @constCast(context),
            .resolve_fn = resolveChatUrl,
        },
        .cli_model_catalog = .{
            .context = @constCast(context),
            .fetch_fn = fetchCliModelCatalog,
        },
        .credits = .{
            .context = @constCast(context),
            .fetch_fn = fetchCredits,
        },
        .generation_usage = context.vercel.generation_usage,
        .web_search = context.vercel.web_search,
        .model_catalog = context.vercel.model_catalog,
    };
}

fn buildAgentRequest(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) anyerror![]u8 {
    const context: *const Context = @ptrCast(@alignCast(raw.?));
    return switch (providers_config.resolveActive().kind) {
        .openai_compatible => context.openai_compatible.agent_stream.build(alloc, request),
        .chatgpt => context.chatgpt.agent_stream.build(alloc, request),
        .vercel_gateway => context.vercel.agent_stream.build(alloc, request),
        .grok, .cursor => error.ModelBackendUnsupported,
    };
}

fn streamAgentCompletion(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.Request,
) anyerror!agent_stream_provider.Result {
    const context: *const Context = @ptrCast(@alignCast(raw.?));
    return switch (providers_config.resolveActive().kind) {
        .openai_compatible => context.openai_compatible.agent_stream.stream(alloc, request),
        .chatgpt => context.chatgpt.agent_stream.stream(alloc, request),
        .vercel_gateway => context.vercel.agent_stream.stream(alloc, request),
        .grok, .cursor => error.ModelBackendUnsupported,
    };
}

fn resolveChatUrl(raw: ?*anyopaque, fallback: []const u8) []const u8 {
    const context: *const Context = @ptrCast(@alignCast(raw.?));
    return switch (providers_config.resolveActive().kind) {
        .openai_compatible => context.openai_compatible.chat_url.resolve(fallback),
        .chatgpt => context.chatgpt.chat_url.resolve(fallback),
        else => context.vercel.chat_url.resolve(fallback),
    };
}

fn fetchCliModelCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const context: *const Context = @ptrCast(@alignCast(raw.?));
    return switch (providers_config.resolveActive().kind) {
        .openai_compatible => context.openai_compatible.cli_model_catalog.fetch(alloc, input),
        .chatgpt => context.chatgpt.cli_model_catalog.fetch(alloc, input),
        else => context.vercel.cli_model_catalog.fetch(alloc, input),
    };
}

fn fetchCredits(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    const context: *const Context = @ptrCast(@alignCast(raw.?));
    return switch (providers_config.resolveActive().kind) {
        .openai_compatible => context.openai_compatible.credits.fetch(alloc, input),
        .chatgpt => context.chatgpt.credits.fetch(alloc, input),
        .grok, .cursor => .{
            .notice = alloc.dupe(u8, "this backend has no gateway balance") catch null,
        },
        .vercel_gateway => context.vercel.credits.fetch(alloc, input),
    };
}

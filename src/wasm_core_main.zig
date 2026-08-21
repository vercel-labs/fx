const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const js_host_stream_provider = @import("gateway/js_host_stream_provider.zig");
const background_process_provider = @import("core/execution/background_process_provider.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const generation_usage_provider = @import("core/session/generation_usage_provider.zig");
const host = @import("core/hosts/host.zig");
const io_mod = @import("core/shared/io.zig");
const model_catalog = @import("core/gateway/model_catalog.zig");
const js_host_model_catalog = @import("gateway/js_host_model_catalog.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const output_contracts = @import("core/output/output_contracts.zig");
const web_search_contract = @import("core/tooling/web_search_contract.zig");
const web_search_policy = @import("core/tooling/web_search_policy.zig");
const web_search_provider = @import("core/tooling/web_search_provider.zig");
const builtin_context = @import("builtins/context.zig");
const builtin_gateway = @import("builtins/gateway.zig");
const builtin_modes = @import("builtins/modes.zig");

const Allocator = std.mem.Allocator;

comptime {
    if (build_options.wasm_surface != .core) {
        @compileError("fx-core requires -Dwasm-surface=core");
    }
}

pub const panic = @import("core/hosts/wasm_panic.zig").panic;

pub fn main(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    try acp_server.run(std.heap.c_allocator, .{
        .default_model = builtin_gateway.default_model,
        .default_agent_step_limit = 64,
        .gateway_retry_count = 0,
        .gateway_chat_url = builtin_gateway.default_chat_url,
        .gateway_models_path = builtin_gateway.models_path,
        .gateway_provider = js_host_gateway_provider,
        .background_process_provider = background_process_provider.unavailable_provider,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = builtin_context.prompt_policy,
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 64 * 1024,
        .max_history_turns = 100,
        .context_registry = .{ .default_provider = builtin_context.provider },
        .mode_registry = builtin_modes.registry,
    });
}

const js_host_gateway_provider = gateway_provider.Provider{
    .agent_stream = js_host_stream_provider.provider(),
    .provider_adapter = .{
        .legacy_provider = js_host_stream_provider.provider(),
        .stream_fn = builtin_gateway.provider_adapter.stream_fn,
    },
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveChatUrl },
    .cli_model_catalog = .{ .fetch_fn = fetchCliModelCatalog },
    .credits = .{ .fetch_fn = fetchCredits },
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = unavailable_web_search_provider,
    .model_catalog = js_host_model_catalog.provider,
};

fn resolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return fallback;
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(js_host_model_catalog.provider, alloc, .{
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
    _: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{};
}

const unavailable_web_search_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &.{},
    .backend_policies = &.{},
};

const unavailable_web_search_provider = web_search_provider.Provider{
    .policy = unavailable_web_search_policy,
    .preferred_backends_fn = preferredWebSearchBackends,
    .execute_fn = executeWebSearch,
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
) anyerror!web_search_contract.ProviderResponse {
    return error.WebSearchUnavailable;
}

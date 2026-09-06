const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const js_host_stream_provider = @import("gateway/js_host_stream_provider.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const provider_set = @import("core/gateway/provider_set.zig");
const host = @import("core/hosts/host.zig");
const io_mod = @import("core/shared/io.zig");
const model_catalog = @import("core/gateway/model_catalog.zig");
const js_host_model_catalog = @import("gateway/js_host_model_catalog.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const output_contracts = @import("core/output/output_contracts.zig");
const builtin_gateway = @import("builtins/gateway.zig");
const provider_catalog = @import("core/auth/provider_catalog.zig");
const vercel_model_policy = @import("gateway/vercel_model_policy.zig");
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
        .provider_set = js_host_provider_set,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 64 * 1024,
        .max_history_turns = 100,
        .context_registry = .{ .default_provider = context_contract.empty_provider },
        .mode_registry = builtin_modes.registry,
        .credential_override = io_mod.getenv("AI_GATEWAY_API_KEY"),
        .model_override = io_mod.getenv("FX_MODEL"),
        .workspace_root_override = "/",
        .allow_acp_mcp = false,
        .allow_native_tools = false,
        .minimal_kernel = true,
    });
}

const js_host_gateway_provider = gateway_provider.Provider{
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveChatUrl },
};

const js_host_provider_set = provider_set.gateway_only(.{
    .presentation = provider_catalog.find(.gateway),
    .auth_strategy = .vercel,
    .fallback_model_capabilities_fn = vercel_model_policy.capabilitiesForModel,
    .agent_stream = js_host_stream_provider.provider(),
    .cli_model_catalog = .{ .fetch_fn = fetchCliModelCatalog },
    .model_catalog = js_host_model_catalog.provider,
    .credits = .{ .fetch_fn = fetchCredits },
});

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

const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const agent_stream_provider = @import("core/agent/stream_provider.zig");
const js_host_stream_provider = @import("gateway/js_host_stream_provider.zig");
const js_host_auth = @import("core/auth/js_host_auth.zig");
const background_process_provider = @import("core/execution/background_process_provider.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const account_usage_provider = @import("core/gateway/account_usage_provider.zig");
const host = @import("core/hosts/host.zig");
const io_mod = @import("core/shared/io.zig");
const js_host_model_catalog = @import("gateway/js_host_model_catalog.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const output_contracts = @import("core/output/output_contracts.zig");
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
    .connection_seed = builtin_gateway.connection_seed,
    .agent_stream = js_host_stream_provider.provider(),
    .provider_adapter = js_host_provider_adapter,
    .adapter_registry = .{ .adapters = &js_host_adapters },
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveChatUrl },
};

const js_host_provider_adapter = agent_stream_provider.ProviderAdapter{
    .kind = builtin_gateway.connection_seed.adapter_id,
    .auth = builtin_gateway.auth_provider_for_transport(&js_host_auth.oauth_provider),
    .account_usage = .{ .fetch_fn = fetchCredits },
    .model_catalog = js_host_model_catalog.provider,
    .model_descriptors = builtin_gateway.model_descriptor_provider,
    .legacy_provider = js_host_stream_provider.provider(),
    .stream_fn = builtin_gateway.streamVercelAdapter,
};

const js_host_adapters = [_]agent_stream_provider.ProviderAdapter{js_host_provider_adapter};

fn resolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return fallback;
}

fn fetchCredits(
    _: ?*anyopaque,
    _: Allocator,
    _: account_usage_provider.Input,
) output_contracts.CreditsSnapshot {
    return .{};
}

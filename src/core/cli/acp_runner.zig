const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const devbox_executor = @import("../execution/devbox_executor.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const gateway_system = @import("../gateway/gateway_system.zig");
const host = @import("../hosts/host.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const context_contract = @import("../workspace/context_contract.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    default_model: []const u8,
    default_agent_step_limit: usize,
    gateway_retry_count: usize,
    gateway_system: gateway_system.System,
    background_process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    devbox_provider: ?devbox_executor.Provider = null,
    model_override: ?[]const u8 = null,
    home_override: ?[]const u8 = null,
    workspace_root_override: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    context_limit_overrides: []const config_runtime.context_limits.Override = &.{},
    additional_directories: []const []const u8 = &.{},
    saved_directories_suppressed: bool = false,
    allow_acp_mcp: bool = true,
    allow_native_tools: bool = true,
};

pub const RunFn = *const fn (?*anyopaque, Allocator, Config) anyerror!void;

pub const Runner = struct {
    context: ?*anyopaque = null,
    run_fn: RunFn,

    pub fn run(self: Runner, alloc: Allocator, cfg: Config) !void {
        return self.run_fn(self.context, alloc, cfg);
    }
};

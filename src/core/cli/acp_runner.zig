const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
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
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8,
    gateway_provider: gateway_provider.Provider,
    codex_agent_stream: ?agent_stream_provider.Provider = null,
    codex_model_catalog: ?model_catalog.Provider = null,
    grok_agent_stream: ?agent_stream_provider.Provider = null,
    grok_model_catalog: ?model_catalog.Provider = null,
    claude_agent_stream: ?agent_stream_provider.Provider = null,
    claude_model_catalog: ?model_catalog.Provider = null,
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
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    codex_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    grok_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    claude_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    model_override: ?[]const u8 = null,
    credential_override: ?[]const u8 = null,
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

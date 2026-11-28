const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config_runtime = @import("../config/config_runtime.zig");
const process_provider = @import("../execution/process_provider.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const host = @import("../hosts/host.zig");
const host_attachments = @import("../hosts/host_attachments.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const context_contract = @import("../workspace/context_contract.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    auth_mode: credentials.AuthMode = .local,
    default_model: []const u8,
    default_agent_step_limit: usize,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    process_provider: process_provider.Provider = process_provider.unavailable_provider,
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
    model_override: ?[]const u8 = null,
    /// Raw reasoning-effort override using the kernel's ReasoningEffort.parse
    /// vocabulary. Borrowed; must outlive the server run.
    effort_override: ?[]const u8 = null,
    /// Fast-lane override matching --fast/--no-fast. Null leaves the startup
    /// and session defaults untouched.
    fast_override: ?bool = null,
    /// Ultrafast-lane override. Null leaves the startup and session defaults
    /// untouched.
    ultrafast_override: ?bool = null,
    /// Provider for every session this server runs, like model_override. Null
    /// keeps the startup provider and each saved session's own provider.
    provider_override: ?model_provider.ProviderId = null,
    /// The permission mode every new session starts in, as `FX_PERMISSION_MODE`
    /// sets it, without saving it. A client can still switch modes. Null
    /// starts in the saved mode.
    permission_override: ?types.PermissionMode = null,
    /// `.host_managed` sends requests to every provider but Gateway (Codex,
    /// Grok and a configured provider) without a credential; the host adds one
    /// at its fetch edge. Gateway keeps `auth_mode`.
    provider_auth_mode: credentials.AuthMode = .local,
    /// For `minimal_kernel` runs: a settings-style providers object whose
    /// providers the run may use. Borrowed for the server's lifetime.
    configured_providers_json: ?[]const u8 = null,
    credential_override: ?[]const u8 = null,
    home_override: ?[]const u8 = null,
    workspace_root_override: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    context_limit_overrides: []const config_runtime.context_limits.Override = &.{},
    tool_placement_overrides: []const config_runtime.tool_placement.Override = &.{},
    additional_directories: []const []const u8 = &.{},
    saved_directories_suppressed: bool = false,
    /// The ACP kernel's switches. Unit tests run both kernels in one
    /// binary, so they set these per config; every other build takes them
    /// from `build_options.libfx_kernel`, so a kernel's unused branches are
    /// not compiled in. Read them through `minimalKernel`, `allowsAcpMcp`
    /// and `allowsNativeTools`.
    allow_acp_mcp: KernelSwitch = kernelSwitch(true),
    allow_native_tools: KernelSwitch = kernelSwitch(true),
    minimal_kernel: KernelSwitch = kernelSwitch(false),
    /// Raw prompt image and checkpoint bytes from a libfx host. Null for
    /// hosts that only speak standard ACP, such as `fx acp`.
    host_attachments: ?host_attachments.Store = null,

    /// libfx's kernel: fx-core.wasm and the Node addon. `fx acp` runs the full one.
    pub inline fn minimalKernel(self: *const Config) bool {
        if (comptime builtin.is_test) return self.minimal_kernel;
        return build_options.libfx_kernel;
    }

    pub inline fn allowsAcpMcp(self: *const Config) bool {
        if (comptime builtin.is_test) return self.allow_acp_mcp;
        return !build_options.libfx_kernel;
    }

    pub inline fn allowsNativeTools(self: *const Config) bool {
        if (comptime builtin.is_test) return self.allow_native_tools;
        return !build_options.libfx_kernel;
    }
};

/// A kernel switch holds a value only in unit tests, so no other build can
/// set one that disagrees with `build_options.libfx_kernel`.
const KernelSwitch = if (builtin.is_test) bool else void;

fn kernelSwitch(comptime value: bool) KernelSwitch {
    return if (builtin.is_test) value else {};
}

pub const RunFn = *const fn (?*anyopaque, Allocator, Config) anyerror!void;

pub const Runner = struct {
    context: ?*anyopaque = null,
    run_fn: RunFn,

    pub fn run(self: Runner, alloc: Allocator, cfg: Config) !void {
        return self.run_fn(self.context, alloc, cfg);
    }
};

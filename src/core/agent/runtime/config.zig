const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const types = @import("../../shared/types.zig");
const tool_descriptor = @import("../../tooling/tool_descriptor.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const context_limits = @import("../../config/context_limits.zig");
const workspace_access = @import("../../workspace/workspace_access.zig");
const model_response_recovery = @import("model_response_recovery.zig");

const ReasoningEffort = types.ReasoningEffort;

pub const default_history_context_budget_tokens: usize = 24_000;
pub const history_context_budget_window_divisor: usize = 4;

/// Who owns the prompt driving this run. A root turn's prompt is real user
/// input; a subagent turn's prompt is assistant-authored delegation and can
/// never establish user authorization for the automatic reviewer.
pub const TurnOrigin = enum { root, subagent };

pub const Config = struct {
    pub const default_step_limit_notice = "Agent step limit reached; continue with a follow-up prompt if needed.";

    system_prompt: []const u8,
    model_prompt_overlay: ?[]const u8 = null,
    skills_prompt_section: []const u8 = "",
    explicit_skills_prompt_section: []const u8 = "",
    gateway_retry_count: usize,
    max_provider_attempts: usize = model_response_recovery.default_max_provider_attempts,
    /// Interactive hosts may request a durable "try later" pause separately
    /// from cancellation. Headless hosts leave this null.
    recovery_pause_flag: ?*std.atomic.Value(bool) = null,
    /// Read-only compatibility input for tool and subagent contexts. Root
    /// model traffic uses `QueuedPrompt.route.endpoint`; G11 removes this field.
    model_tools: []const tool_descriptor.Descriptor,
    provider_tools: []const agent_stream_provider.ProviderToolAdvertisement = &.{},
    custom_tool_guidance: []const u8 = "",
    agent_step_limit: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    step_limit_notice: []const u8 = default_step_limit_notice,
    cancel_flag: *std.atomic.Value(bool),
    review_enabled: bool = false,
    fast_mode: bool = false,
    effort: ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    workspace_root: []const u8 = "",
    access_scope: ?workspace_access.AccessScope = null,
    origin: TurnOrigin = .root,
    /// Root-user evidence inherited by a subagent turn. Unused for root turns.
    root_user_intent_context: []const u8 = "",
    /// Exact ordered root-user authority inherited by a child. The child task
    /// prompt is intentionally excluded.
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    /// True only for a real external user prompt appended to a resumed
    /// persistent child. Internal assistant-authored delegations leave this
    /// false.
    current_prompt_is_root_authority: bool = false,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    subagent_id: u64 = 0,
    context_limits: context_limits.Values = .{},
};

const std = @import("std");
const skill_contract = @import("../../skills/skill_contract.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const types = @import("../../shared/types.zig");
const diff = @import("../../output/diff.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const session_permission_state = @import("../../permissions/session_permission_state.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const result_commit = @import("../../tooling/result_commit.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");

pub const vision = @import("vision_contracts.zig");

test {
    _ = vision;
}

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;

/// Borrowed child-only authority refreshed immediately before one tool action.
/// Main-agent requests leave this null and retain their existing behavior.
pub const LiveToolAuthority = struct {
    generation: u64,
    root_id: []const u8,
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const PermissionGrant,
    permission_state: ?*const session_permission_state.State = null,
    permission_mode: types.PermissionMode = .yolo,
};

pub const ToolExecutionStatus = enum {
    success,
    failure,
};

/// Exact action identity and approval provenance retained while a child action
/// is revalidated against a newer live-authority generation.
pub const LivePermissionRevalidation = union(enum) {
    action: struct {
        authority: command_admission.ToolExecutionAuthority,
        human_approval: command_admission.HumanApprovalProvenance,
    },
};

pub const DeferredToolCompletion = struct {
    transport_id: []const u8,
    content_text: []const u8,
    command_result_json: ?[]const u8 = null,
};

pub const TransportPublicationOutcome = enum {
    published,
    failed,
};

pub const SecondarySinkOutcome = enum {
    skipped,
    published,
    failed,
};

pub const SecondaryPublicationReport = struct {
    diff: SecondarySinkOutcome,
    tracker: SecondarySinkOutcome,

    pub fn degraded(self: SecondaryPublicationReport) bool {
        return self.diff == .failed or self.tracker == .failed;
    }
};

pub const ToolExecutionResult = struct {
    model_content_kind: tool_dispatch.ModelContentKind = .ordinary,
    model_output: []const u8,
    status: ToolExecutionStatus = .success,
    cancelled: bool = false,
    status_detail: ?[]const u8 = null,
    diff_entry: ?DiffEntryPayload = null,
    finish_turn: bool = false,
    system_notice: ?[]const u8 = null,
    interactive_notice: ?types.SemanticNotice = null,
    context_notices: []const []const u8 = &.{},
    command_result_json: ?[]const u8 = null,
    turn_control: ?tool_dispatch.TurnControl = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
    inner_usage: ?types.ToolUsage = null,
    selected_dynamic_tools: []const @import("../../tooling/tool_mcp_runtime.zig").SelectedTool = &.{},
    retired_dynamic_tool_names: []const []const u8 = &.{},
    tool_result_memory: ?types.ToolResultMemory = null,
    tool_result_memory_prepared: bool = false,
    committed_file_handoff: ?file_mutation.CommittedFileHandoff = null,
    deferred_tool_completion: ?DeferredToolCompletion = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    result_commit: ?result_commit.Token = null,
};

test "tool result retains one memory payload across preparation" {
    try std.testing.expect(@hasField(ToolExecutionResult, "tool_result_memory"));
    try std.testing.expect(@hasField(ToolExecutionResult, "tool_result_memory_prepared"));
    try std.testing.expect(!@hasField(ToolExecutionResult, "prepared_result_memory"));
}

pub inline fn failToolExecutionResult(err: anytype) @TypeOf(err)!ToolExecutionResult {
    return @errorCast(failToolExecutionResultDynamic(err));
}

noinline fn failToolExecutionResultDynamic(err: anyerror) anyerror!ToolExecutionResult {
    return err;
}

test "tool result failure writer preserves exact error type and identity" {
    const failure = failToolExecutionResult(error.LiveToolAuthorityUnavailable);
    try std.testing.expect(
        @TypeOf(failure) == error{LiveToolAuthorityUnavailable}!ToolExecutionResult,
    );
    try std.testing.expectError(error.LiveToolAuthorityUnavailable, failure);
}

pub fn unavailableHostToolResult(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    return .{
        .status = .failure,
        .model_output = try alloc.dupe(u8, "Tools are unavailable in the current JavaScript host."),
    };
}

pub const ToolExecutionRequest = struct {
    skill_locations: ?*const skill_contract.Locations = null,
    call_allocator: Allocator,
    result_allocator: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    credential: types.CredentialLease = .{ .direct = .{} },
    /// Action-scoped root mode sampled before permission admission. Direct
    /// callers without a sampled mode retain their execution context value.
    permission_mode: ?types.PermissionMode = null,
    /// Borrowed root-user evidence for subagent execution. This is never
    /// populated from an assistant-authored task prompt.
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    /// Borrowed caller-owned catalog of images authorized for this call. The
    /// executor must not retain this slice or any attachment pointer.
    authorized_image_catalog: []const types.ImageAttachment = &.{},
    /// Borrowed execution evidence retained by the owning agent loop until
    /// the current turn is committed.
    current_turn_messages: []const ChatMessage = &.{},
    session_grants: []const PermissionGrant,
    live_authority: ?LiveToolAuthority = null,
    expected_mcp_runtime_generation: ?u64 = null,
    expected_mcp_binding: ?types.McpToolBinding = null,
    advertised_dynamic_tool_names: []const []const u8,
    max_tool_result_bytes: usize,
    /// The owning agent loop already ran its policy-neutral idempotency and
    /// availability classifiers for this exact effective call.
    classification_complete: bool = false,
    /// Timeout origin retained across preparation and execution.
    command_timeout_started_ms: ?i64 = null,
    /// Continues accepted-byte capture across the prepared execution.
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    /// Present for interactive tool calls so streamed command output can stay
    /// attached to the status row that owns this exact call.
    lifecycle_id: ?types.ToolLifecycleId = null,
};

pub const DiffEntryPayload = diff.DiffEntryPayload;

pub const ToolCallValidationWitness = struct {
    mcp_runtime_generation: ?u64 = null,
};

pub const ToolCallValidationResult = union(enum) {
    not_registered,
    valid: ToolCallValidationWitness,
    failure: []const u8,
};

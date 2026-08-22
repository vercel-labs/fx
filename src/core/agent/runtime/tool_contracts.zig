const std = @import("std");
const command_admission = @import("../../permissions/command_admission.zig");
const command_contract = @import("../../execution/command_contract.zig");
const types = @import("../../shared/types.zig");
const diff = @import("../../output/diff.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const session_permission_state = @import("../../permissions/session_permission_state.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");

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
    model_output: []const u8,
    status: ToolExecutionStatus = .success,
    cancelled: bool = false,
    status_detail: ?[]const u8 = null,
    display_output: ?[]const u8 = null,
    diff_entry: ?DiffEntryPayload = null,
    finish_turn: bool = false,
    system_notice: ?[]const u8 = null,
    interactive_notice: ?types.SemanticNotice = null,
    context_notices: []const []const u8 = &.{},
    background_command: ?command_contract.BackgroundCommand = null,
    command_result_json: ?[]const u8 = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
    inner_usage: ?types.ToolUsage = null,
    selected_dynamic_tool_name: ?[]const u8 = null,
    selected_dynamic_tool_schema_json: ?[]const u8 = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    prepared_result_memory: ?types.ToolResultMemory = null,
    committed_file_handoff: ?file_mutation.CommittedFileHandoff = null,
    deferred_tool_completion: ?DeferredToolCompletion = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
};

pub fn unavailableHostToolResult(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    return .{
        .status = .failure,
        .model_output = try alloc.dupe(u8, "Tools are unavailable in the current JavaScript host."),
    };
}

pub const ToolExecutionRequest = struct {
    call_allocator: Allocator,
    result_allocator: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
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

pub const ToolCallValidationResult = union(enum) {
    not_registered,
    valid,
    failure: []const u8,
};

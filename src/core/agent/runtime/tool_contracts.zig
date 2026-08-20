const std = @import("std");
const command_admission = @import("../../permissions/command_admission.zig");
const command_contract = @import("../../execution/command_contract.zig");
const types = @import("../../shared/types.zig");
const diff = @import("../../output/diff.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_admission = @import("../../tooling/tool_admission.zig");
const session_permission_state = @import("../../permissions/session_permission_state.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const route_snapshot = @import("../../gateway/route_snapshot.zig");
const stream_provider = @import("../stream_provider.zig");
const tool_descriptor = @import("../../tooling/tool_descriptor.zig");

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
    sandbox_backend: types.BackendKind,
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

pub const SandboxWideningPhase = enum {
    preflight,
    reactive,
};

/// A command reached the existing OS sandbox boundary and needs a fresh,
/// broader authority decision before any permissive execution can occur.
/// Reactive dispositions retain the completed restricted attempt verbatim.
pub const SandboxScopeRequired = struct {
    phase: SandboxWideningPhase,
    /// Frozen admission identity used by the completed restricted attempt.
    restricted_fingerprint: command_admission.AdmissionFingerprint,
    /// Original foreground command timeout origin. A broader retry must share
    /// this budget instead of starting a second full timeout window.
    command_timeout_started_ms: ?i64 = null,
    restricted_model_output: ?[]const u8 = null,
    restricted_command_result_json: ?[]const u8 = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,

    pub fn wideningInput(self: SandboxScopeRequired) tool_admission.SandboxWideningInput {
        return .{
            .phase = switch (self.phase) {
                .preflight => .preflight,
                .reactive => .reactive,
            },
            .restricted_fingerprint = self.restricted_fingerprint,
            .restricted_result = self.restricted_model_output,
            .restricted_command_result = self.restricted_command_result_json,
        };
    }
};

/// Exact action identity and approval provenance retained while a child action
/// is revalidated against a newer live-authority generation.
pub const LivePermissionRevalidation = union(enum) {
    action: struct {
        authority: command_admission.ToolExecutionAuthority,
        human_approval: command_admission.HumanApprovalProvenance,
    },
    sandbox_widening: struct {
        authority: command_admission.ToolExecutionAuthority,
        required: SandboxScopeRequired,
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
    selected_dynamic_tool: ?tool_descriptor.Descriptor = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    prepared_result_memory: ?types.ToolResultMemory = null,
    committed_file_handoff: ?file_mutation.CommittedFileHandoff = null,
    deferred_tool_completion: ?DeferredToolCompletion = null,
    sandbox_scope_required: ?SandboxScopeRequired = null,
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
    /// Borrowed provider authority already admitted and resolved by the
    /// owning turn. Tool implementations may consume it but never retain it.
    route: ?*const route_snapshot.RouteSnapshot = null,
    route_adapter: ?stream_provider.ProviderAdapter = null,
    route_credential: []const u8 = "",
    route_tenant: ?[]const u8 = null,
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
    /// Reused only for a broader sandbox retry of the same command.
    command_timeout_started_ms: ?i64 = null,
    /// Continues the accepted-byte capture across a reactive sandbox retry.
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    /// Present for interactive tool calls so streamed command output can stay
    /// attached to the status row that owns this exact call.
    lifecycle_id: ?types.ToolLifecycleId = null,

    pub fn isSandboxWideningRetryCancellation(
        self: ToolExecutionRequest,
        result: ToolExecutionResult,
    ) bool {
        return result.cancelled and self.isSandboxWideningRetry();
    }

    /// True when the result is not final for the surface: it either requests
    /// a broader sandbox scope or is a cancelled broader retry, and the
    /// widening flow owns projecting and recording the combined evidence.
    pub fn resultAwaitsSandboxWidening(
        self: ToolExecutionRequest,
        result: ToolExecutionResult,
    ) bool {
        return result.sandbox_scope_required != null or
            self.isSandboxWideningRetryCancellation(result);
    }

    pub fn isSandboxWideningRetry(self: ToolExecutionRequest) bool {
        return switch (self.authority) {
            .run_command => |authority| switch (authority) {
                .direct_only => false,
                .shell_allowed => |allowed| allowed.fingerprint.scope == .broader,
            },
            else => false,
        };
    }

    pub fn isSandboxWideningRetryCancellationError(
        self: ToolExecutionRequest,
        err: anyerror,
    ) bool {
        return self.isSandboxWideningRetry() and
            (err == error.Cancelled or err == error.CancelledBeforeExecution);
    }
};

pub const DiffEntryPayload = diff.DiffEntryPayload;

pub const ToolCallValidationResult = union(enum) {
    not_registered,
    valid,
    failure: []const u8,
};

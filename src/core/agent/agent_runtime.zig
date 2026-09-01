const runtime_assistant_stream = @import("runtime/assistant_stream.zig");
const runtime_agent = @import("runtime/agent.zig");
const runtime_config = @import("runtime/config.zig");
const runtime_checkpoint = @import("runtime/checkpoint.zig");
const runtime_deps = @import("runtime/deps.zig");
const runtime_execution_memory = @import("runtime/execution_memory.zig");
const runtime_finalization = @import("runtime/finalization.zig");
const runtime_lifecycle = @import("runtime/lifecycle.zig");
const runtime_orchestrator = @import("runtime/orchestrator.zig");
const runtime_tool_contracts = @import("runtime/tool_contracts.zig");
const assistant_presentation = @import("assistant_presentation.zig");
const worker_runtime = @import("worker_runtime.zig");

pub const ToolExecutionStatus = runtime_tool_contracts.ToolExecutionStatus;
pub const Agent = runtime_agent.Agent;
pub const checkpoint = runtime_checkpoint;
pub const DeferredToolCompletion = runtime_tool_contracts.DeferredToolCompletion;
pub const TransportPublicationOutcome = runtime_tool_contracts.TransportPublicationOutcome;
pub const SecondarySinkOutcome = runtime_tool_contracts.SecondarySinkOutcome;
pub const SecondaryPublicationReport = runtime_tool_contracts.SecondaryPublicationReport;
pub const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;
pub const unavailableHostToolResult = runtime_tool_contracts.unavailableHostToolResult;
pub const LiveToolAuthority = runtime_tool_contracts.LiveToolAuthority;
pub const LivePermissionRevalidation = runtime_tool_contracts.LivePermissionRevalidation;
pub const ToolExecutionRequest = runtime_tool_contracts.ToolExecutionRequest;
pub const DiffEntryPayload = runtime_tool_contracts.DiffEntryPayload;
pub const ToolCallValidationResult = runtime_tool_contracts.ToolCallValidationResult;
pub const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
pub const PresentationStyles = runtime_deps.PresentationStyles;
pub const TextEmission = runtime_deps.TextEmission;
pub const ParentTurnDeliveryAck = runtime_deps.ParentTurnDeliveryAck;
pub const PreparedParentTurnContext = runtime_deps.PreparedParentTurnContext;
pub const RouteRecoveryDecision = runtime_deps.RouteRecoveryDecision;
pub const RouteRecoveryRequest = runtime_deps.RouteRecoveryRequest;
pub const CredentialRefreshMode = runtime_deps.CredentialRefreshMode;
pub const SemanticPresentationSink = runtime_assistant_stream.SemanticPresentationSink;
pub const LifecycleContext = runtime_lifecycle.LifecycleContext;
pub const PreparedToolBlockKind = runtime_lifecycle.PreparedToolBlockKind;
pub const PreparedToolCall = runtime_lifecycle.PreparedToolCall;
pub const prepareToolCallForLifecycle = runtime_lifecycle.prepareToolCallForLifecycle;
pub const dispatchAttentionRequiredCheckpoint = runtime_lifecycle.dispatchAttentionRequiredCheckpoint;
pub const TurnFinalizationGuard = runtime_finalization.TurnFinalizationGuard;
pub const Config = runtime_config.Config;
pub fn processAgentPrompt(
    agent: *Agent,
    deps: *const AgentRuntimeDeps,
    semantic_presentation: ?SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    const prior_inline_code = assistant_presentation.currentInlineCodeStyle();
    const prior_task_completed = assistant_presentation.currentTaskCompletedStyle();
    defer assistant_presentation.setPresentationStyles(
        prior_inline_code,
        prior_task_completed,
    );
    assistant_presentation.setPresentationStyles(
        deps.presentation_styles.inline_code,
        deps.presentation_styles.task_completed,
    );
    return runtime_orchestrator.processAgentPrompt(
        agent,
        deps,
        semantic_presentation,
        lifecycle,
        config,
        job,
    );
}
pub const compactContextTransaction = runtime_orchestrator.compactContextTransaction;
pub const persistedStatusForCurrentFxLocalResult = runtime_execution_memory.persistedStatusForCurrentFxLocalResult;
pub const classifyProviderExecutedResultStatus = runtime_execution_memory.classifyProviderExecutedResultStatus;
pub const normalizeAssistantTextForDisplay = runtime_assistant_stream.normalizeAssistantTextForDisplay;

test {
    _ = @import("stream_provider.zig");
    _ = @import("runtime/context_compaction.zig");
    _ = @import("runtime/tests/gateway_flow.zig");
    _ = @import("runtime/tests/tool_flow.zig");
    _ = @import("runtime/tests/interruption_flow.zig");
    _ = @import("runtime/tests/finalization_flow.zig");
    _ = @import("runtime/orchestrator.zig");
    _ = @import("runtime/vision_contracts.zig");
}

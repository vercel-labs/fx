//! Compacting a conversation on request, outside a turn: `/compact` in the
//! terminal app and `fx/command` `compact` in the ACP host. Both summarize with
//! the conversation's own model and settings, so the request to that model is
//! built here once.
const std = @import("std");
const agent_runtime = @import("agent_runtime.zig");
const compactor = @import("../compactor/compactor.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const session_runtime = @import("../session/session.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// The conversation's model, which writes the summary. Every slice is
/// borrowed for the call.
pub const Model = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    gateway_team: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    retry_count: usize,
    /// The `compact` model role's model; empty uses `model`. Borrowed.
    summary_model: []const u8 = "",
    effort: types.ReasoningEffort,
    fast_mode: bool,
    prompt_caching: bool,
    /// The gateway's provider routing; other providers have none.
    provider_order: []const []const u8 = &.{},
    provider_strict: bool = false,
};

pub const Request = struct {
    model: Model,
    /// The saved conversation, oldest first.
    history: []const types.HistoryTurn,
    /// The conversation's agent, for what it measured of its requests.
    agent: *const agent_runtime.Agent,
    auto_compact_percent: u8,
    records: ?compactor.Store,
    cancel_flag: *std.atomic.Value(bool),
    turn_id: u64,
    /// The activity the host already began for this compaction, if it shows one.
    operation_id: ?compaction_activity.OperationId = null,
};

/// Compacts `request.history` and publishes the summary through
/// `deps.commit_context_compaction`. Null when there was nothing to compact.
/// The result borrows `arena`.
pub fn run(arena: Allocator, deps: *const agent_runtime.AgentRuntimeDeps, request: Request) !?compactor.Result {
    const model = request.model;
    const capabilities = deps.available_model_capabilities(deps.ctx, model.model);
    var provider_options = model_capabilities.resolveProviderOptionsForCapabilities(capabilities, model.effort, model.fast_mode);
    provider_options.prompt_caching = model.prompt_caching;
    if (model.provider == .gateway) {
        provider_options.provider_order = model.provider_order;
        provider_options.provider_strict = model.provider_strict;
    }
    var summary_model: agent_runtime.CompactorCaller = .{
        .stream_provider = deps.agent_stream_provider,
        .cooperative_transport_pulse = deps.cooperative_transport_pulse,
        .provider = model.provider,
        .model = model.model,
        .summary_model = model.summary_model,
        .api_key = model.api_key,
        .credential_source = model.credential_source,
        .account_id = model.account_id,
        .gateway_team = model.gateway_team,
        .session_id = model.session_id,
        .retry_count = model.retry_count,
        .provider_options = provider_options,
        .max_output_tokens = model_capabilities.requestOutputTokens(capabilities),
        .capabilities_context = deps.ctx,
        .capabilities_fn = deps.available_model_capabilities,
    };
    return agent_runtime.compactContext(arena, deps, .{
        .operation_id = request.operation_id,
        .activity_origin = .manual,
        .compactor = .{
            .history = request.history,
            .append_messages = session_runtime.appendHistoryChatMessages,
            .size = agent_runtime.compactionSize(request.agent, capabilities, request.auto_compact_percent, model.model),
            .caller = summary_model.caller(),
            .records = request.records,
            .cancel_flag = request.cancel_flag,
            .trace_ctx = .{ .turn_id = request.turn_id },
        },
    });
}

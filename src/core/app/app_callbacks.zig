const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const route_snapshot = @import("../gateway/route_snapshot.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const core_input_runtime = @import("../input/runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const change_tracker_mod = @import("../workspace/change_tracker.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const io_mod = @import("../shared/io.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_usage = @import("../session/session_usage.zig");
const parent_delivery_projector = @import("../subagent/parent_delivery_projector.zig");
const task_helpers = @import("../tasks/task_helpers.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const ui_render = @import("../../ui/render.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const WorkerEvent = worker_runtime.WorkerEvent;

const reset_style = ui_render.reset_style;

fn preparedDiffPayload(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !diff_mod.DiffEntryPayload {
    return preparedDiffPayloadWithFullAllocator(alloc, alloc, handoff);
}

fn preparedDiffPayloadWithFullAllocator(
    alloc: Allocator,
    full_alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !diff_mod.DiffEntryPayload {
    return diff_mod.formatFileChangePayload(
        alloc,
        full_alloc,
        handoff.preview,
        handoff.tracker.previous_content,
        if (handoff.full_view) |snapshot| .{
            .after_content = snapshot.after_content,
            .lifecycle_id = snapshot.lifecycle_id,
        } else null,
        .{
            .added_fg = ui_render.diff_added_style,
            .removed_fg = ui_render.diff_removed_style,
            .context_fg = ui_render.dim_style,
            .added_marker_fg = ui_render.diff_added_marker_style,
            .removed_marker_fg = ui_render.diff_removed_marker_style,
            .reset = ui_render.reset_style,
        },
    );
}

test "prepared preview formatter preserves context and informative elision" {
    const preview: diff_mod.FileChangePreview = .{
        .path = "note.txt",
        .lines = &.{
            .{
                .op = .context,
                .old_line = 1,
                .new_line = 1,
                .text = "alpha",
            },
            .{
                .op = .deletion,
                .old_line = 2,
                .text = "before",
            },
            .{
                .op = .addition,
                .new_line = 2,
                .text = "after",
            },
            .{
                .op = .elision,
                .text = "⋯ +2 -1 omitted",
            },
        },
        .additions = 3,
        .deletions = 2,
        .truncated = true,
    };
    const formatted = try diff_mod.formatFileChangePreview(
        std.testing.allocator,
        preview,
        .{
            .added_fg = "",
            .removed_fg = "",
            .context_fg = "",
            .reset = "",
        },
    );
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.mem.find(u8, formatted, "alpha") != null);
    try std.testing.expect(
        std.mem.find(u8, formatted, "⋯ +2 -1 omitted") != null,
    );
}

test "prepared diff payload keeps compact elision and retains the complete approved review" {
    const alloc = std.testing.allocator;
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(alloc);
    for (1..121) |line_number| {
        var line: [32]u8 = undefined;
        try after.appendSlice(
            alloc,
            try std.fmt.bufPrint(&line, "full-review-{d:0>3}\n", .{line_number}),
        );
    }

    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = "full-review-001" },
        .{ .op = .elision, .text = "⋯ +118 omitted" },
        .{ .op = .addition, .new_line = 120, .text = "full-review-120" },
    };
    const handoff = file_mutation.CommittedFileHandoff.init(
        .{
            .path = "full-review.txt",
            .lines = &preview_lines,
            .additions = 120,
            .deletions = 0,
            .truncated = true,
        },
        .{
            .kind = .write,
            .raw_path = "/tmp/full-review.txt",
            .previous_content = null,
            .committed_at_ms = 0,
        },
    );
    var enriched_handoff = handoff;
    enriched_handoff.full_view = .{
        .after_content = after.items,
        .lifecycle_id = .{ .turn_id = 39, .call_id = "full-review" },
    };

    const payload = try preparedDiffPayload(alloc, enriched_handoff);
    defer diff_mod.freeDiffEntryPayload(alloc, payload);

    try std.testing.expect(std.mem.indexOf(u8, payload.preview, "⋯ +118 omitted") != null);
    const full = payload.full orelse return error.TestExpectedFullDiff;
    try std.testing.expect(std.mem.indexOf(u8, full.content, "full-review-001") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.content, "full-review-120") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.content, "⋯ +118 omitted") == null);
}

test "prepared diff payload keeps compact output when full formatting is unavailable" {
    const handoff = testCommittedFileHandoff();
    var enriched_handoff = handoff;
    enriched_handoff.full_view = .{
        .after_content = "after\n",
        .lifecycle_id = .{ .turn_id = 40, .call_id = "full-format-fallback" },
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    const payload = try preparedDiffPayloadWithFullAllocator(
        std.testing.allocator,
        failing.allocator(),
        enriched_handoff,
    );
    defer diff_mod.freeDiffEntryPayload(std.testing.allocator, payload);

    try std.testing.expect(payload.full == null);
    try std.testing.expect(std.mem.indexOf(u8, payload.preview, "after") != null);
}

test "full diff formatter renders unchanged review elisions" {
    const before =
        "same-01\n" ++
        "same-02\n" ++
        "same-03\n" ++
        "same-04\n" ++
        "same-05\n" ++
        "same-06\n" ++
        "same-07\n" ++
        "same-08\n" ++
        "same-09\n" ++
        "same-10\n" ++
        "old\n";
    const after =
        "same-01\n" ++
        "same-02\n" ++
        "same-03\n" ++
        "same-04\n" ++
        "same-05\n" ++
        "same-06\n" ++
        "same-07\n" ++
        "same-08\n" ++
        "same-09\n" ++
        "same-10\n" ++
        "new\n";
    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .deletion, .old_line = 11, .text = "old" },
        .{ .op = .addition, .new_line = 11, .text = "new" },
    };
    var handoff = file_mutation.CommittedFileHandoff.init(
        .{
            .path = "elision.txt",
            .lines = &preview_lines,
            .additions = 1,
            .deletions = 1,
            .truncated = false,
        },
        .{
            .kind = .edit,
            .raw_path = "/tmp/elision.txt",
            .previous_content = before,
            .committed_at_ms = 0,
        },
    );
    handoff.full_view = .{
        .after_content = after,
        .lifecycle_id = .{ .turn_id = 41, .call_id = "context-elision" },
    };

    const snapshot = handoff.full_view orelse return error.TestExpectedFullDiff;
    const full = (try diff_mod.formatFileChangeFullDiff(
        std.testing.allocator,
        handoff.tracker.previous_content,
        .{
            .after_content = snapshot.after_content,
            .lifecycle_id = snapshot.lifecycle_id,
        },
        .{},
    )) orelse
        return error.TestExpectedFullDiff;
    defer full.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, full.content, "5 unchanged lines ⋯") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.content, "old") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.content, "new") != null);
}

pub fn Bindings(comptime App: type) type {
    return struct {
        pub fn agentRuntimeDeps(app: *App) agent_runtime.AgentRuntimeDeps {
            var deps: agent_runtime.AgentRuntimeDeps = .{
                .ctx = @ptrCast(app),
                .provider_adapter = if (comptime @hasDecl(App, "providerAdapter"))
                    app.providerAdapter()
                else
                    agent_stream_provider.unavailable_adapter,
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .cooperative_transport_pulse = if (comptime @hasDecl(App, "cooperativeTransportPulse")) .{
                    .ctx = @ptrCast(app),
                    .run = cooperativeTransportPulse,
                } else null,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry() else .{},
                .context_registry = if (comptime @hasDecl(App, "contextRegistry")) app.contextRegistry() else null,
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else false,
                .finalize_turn = agentFinalizeTurn,
                .prepare_parent_turn_context = agentPrepareParentTurnContext,
                .acknowledge_parent_turn_context = agentAcknowledgeParentTurnContext,
                .append_runtime_context = agentAppendRuntimeContext,
                .append_static_context = agentAppendStaticContext,
                .validate_tool_call = agentValidateToolCall,
                .check_tool_availability = agentCheckToolAvailability,
                .request_tool_permission = agentRequestToolPermission,
                .request_prepared_file_mutation_permission = agentRequestPreparedFileMutationPermission,
                .describe_tool_action = agentDescribeToolAction,
                .describe_tool_action_completed = agentDescribeToolActionCompleted,
                .describe_tool_action_denied = agentDescribeToolActionDenied,
                .permission_target_for_call = agentPermissionTargetForCall,
                .execute_tool_call = agentExecuteToolCall,
                .publish_committed_file_handoff = agentPublishCommittedFileHandoff,
                .propagate_history_turn = agentPropagateHistoryTurn,
                .recovery_checkpoint = if (comptime @hasField(App, "session_persistence"))
                    if (app.session_persistence.writable != null)
                        .{
                            .set = agentSetRecoveryCheckpoint,
                        }
                    else
                        null
                else
                    null,
                .propagate_grant = agentPropagateGrant,
                .push_event = agentPushEvent,
                .push_text = agentPushText,
                .push_tool_lifecycle = agentPushToolLifecycle,
                .push_diff_block = agentPushDiffBlock,
                .push_system_notice = agentPushSystemNotice,
                .push_interactive_notice = agentPushInteractiveNotice,
                .push_context_notice = agentPushContextNotice,
                .push_route_recovery_status = agentPushRouteRecoveryStatus,
                .push_command_output_complete = agentPushCommandOutputComplete,
                .push_http_error = agentPushHttpError,
                .refresh_gateway_credential = if (comptime @hasField(App, "auth"))
                    refreshGatewayCredential
                else
                    null,
                .request_route_recovery = if (comptime @hasDecl(@TypeOf(app.worker), "requestRouteRecoveryAnswerBlocking"))
                    agentRequestRouteRecovery
                else
                    null,
                .available_model_descriptor = agentAvailableModelDescriptor,
                .resolve_model_descriptor = agentResolveModelDescriptor,
                .available_model_capabilities = agentAvailableModelCapabilities,
                .resolve_model_capabilities = agentResolveModelCapabilities,
                .format_tool_execution_error = agentFormatToolExecutionError,
                .record_tool_call_rejected = agentRecordToolCallRejected,
                .report_usage = agentReportUsage,
                .report_inner_tool_usage = agentReportInnerToolUsage,
                .usage_allocator = app.alloc,
                .diff_marker_styles = .{
                    .added = ui_render.diff_added_marker_style,
                    .removed = ui_render.diff_removed_marker_style,
                },
            };
            if (comptime @hasDecl(App, "resolveRouteCredential")) {
                deps.resolve_route_credential = resolveRouteCredential;
            }
            if (comptime @hasField(@TypeOf(app.session), "usage")) {
                deps.usage = &app.session.usage;
                if (comptime @hasField(App, "session_persistence") and
                    @hasField(@TypeOf(app.session_persistence), "writable"))
                {
                    app.session.usage.configureCheckpointSink(
                        if (app.session_persistence.writable != null)
                            .{
                                .context = @ptrCast(app),
                                .allocator = app.alloc,
                                .persist = agentPersistUsageCheckpoint,
                            }
                        else
                            null,
                    );
                }
            }
            if (comptime @hasDecl(App, "requestSandboxWideningSyncWithAdvertised")) {
                deps.request_sandbox_widening = agentRequestSandboxWidening;
            }
            return deps;
        }

        fn resolveRouteCredential(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
            route: *const route_snapshot.RouteSnapshot,
        ) !agent_runtime.RouteCredential {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.resolveRouteCredential(alloc, route);
        }

        fn refreshGatewayCredential(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
            source: credentials.Source,
            mode: auth_runtime.CredentialRefreshMode,
        ) !?[]u8 {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (source != .fx_login) return null;
            return app.auth.refreshSelectedCredential(alloc, switch (mode) {
                .if_needed => .if_needed,
                .force => .force,
            });
        }

        pub fn modelCapabilityResolver(app: *App) model_capabilities.Resolver {
            return .{
                .ctx = @ptrCast(app),
                .resolve_fn = agentResolveModelCapabilities,
            };
        }

        pub fn semanticPresentationSink(app: *App) agent_runtime.SemanticPresentationSink {
            return .{
                .ctx = @ptrCast(app),
                .table = agentPushTable,
                .code_block = agentPushCodeBlock,
                .thematic_rule = agentPushThematicRule,
            };
        }

        pub fn workerEventHandlers(app: *App) app_worker_runtime.WorkerEventHandlers {
            return .{
                .ctx = @ptrCast(app),
                .tool_lifecycle = worker_tool_lifecycle_presenter(app),
                .write_user_prompt = workerBridgeWriteUserPrompt,
                .write_user_prompt_with_skill_bindings = workerBridgeWriteUserPromptWithSkillBindings,
                .append_text = workerBridgeAppendText,
                .append_table = workerBridgeAppendTable,
                .append_code_block = workerBridgeAppendCodeBlock,
                .append_thematic_rule = workerBridgeAppendThematicRule,
                .drain_assistant_text = workerBridgeDrainAssistantText,
                .open_model_picker = workerBridgeOpenModelPicker,
                .semantic_notice = workerBridgeSemanticNotice,
                .command_output = workerBridgeCommandOutput,
                .command_output_complete = workerBridgeCommandOutputComplete,
                .diff_block = workerBridgeDiffBlock,
                .append_history_turn = workerBridgeAppendHistoryTurn,
                .session_grant = workerBridgeSessionGrant,
                .error_text = workerBridgeErrorText,
            };
        }

        pub fn worker_tool_lifecycle_presenter(
            app: *App,
        ) activity_runtime.LifecyclePresenter {
            return .{
                .ctx = @ptrCast(app),
                .snapshot_fn = worker_tool_lifecycle_snapshot,
                .record_fn = worker_tool_lifecycle_record,
                .apply_fn = worker_apply_tool_lifecycle,
                .finish_batch_fn = worker_finish_tool_lifecycle_batch,
            };
        }

        fn worker_tool_lifecycle_snapshot(
            raw_ctx: *anyopaque,
        ) activity_runtime.LifecycleSnapshot {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return .{
                .finalized_turn_watermark = app.shell.finalizedToolTurnWatermark(),
                .active_tool_count = app.shell.activeToolActivityCount(),
                .focused_entry_id = app.shell.focusedToolEntryId(),
                .focused_activity_kind = app.shell.focusedToolActivityKind(),
                .activity = app.shell.activityProjection(),
            };
        }

        fn worker_tool_lifecycle_record(
            raw_ctx: *anyopaque,
            id: types.ToolLifecycleId,
        ) ?activity_runtime.ToolPresentationRecord {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.shell.toolActivityRecord(id);
        }

        fn worker_apply_tool_lifecycle(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
            event: types.ToolLifecycleEvent,
        ) !activity_runtime.LifecycleTransition {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            const previous_focused_entry_id = app.shell.focusedToolEntryId();
            const preserve_normal_buffer_anchor = if (comptime @hasField(App, "terminal"))
                app.terminal.alternate_screen_owner != .none
            else
                false;
            const applied_activity_kind = if (preserve_normal_buffer_anchor)
                try app.shell.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event)
            else
                try app.shell.applyToolLifecycle(alloc, event);
            return .{
                .previous_focused_entry_id = previous_focused_entry_id,
                .snapshot = worker_tool_lifecycle_snapshot(raw_ctx),
                .applied_activity_kind = applied_activity_kind,
                .terminal_record = switch (event) {
                    .terminal => |terminal| app.shell.toolActivityRecord(terminal.id),
                    .provisional, .authoritative_started, .progress, .turn_finished => null,
                },
            };
        }

        fn worker_finish_tool_lifecycle_batch(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) !void {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            try app.shell.finishLifecycleBatch(alloc);
        }

        pub fn onCommandOutputChunk(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, chunk: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (app.worker.worker_cancel_requested.load(.seq_cst)) return;
            try app_worker_runtime.Runtime(App).pushCommandOutput(app, lifecycle_id, stream, chunk);
        }

        pub fn onMcpProgress(ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var label_buf: [512]u8 = undefined;
            const label = std.fmt.bufPrint(
                &label_buf,
                "{s}● {s}{s}",
                .{ ui_render.bold_style, text, reset_style },
            ) catch ui_render.bold_style ++ "● MCP progress" ++ reset_style;
            app_worker_runtime.Runtime(App).pushToolLifecycle(app, .{ .progress = .{
                .id = lifecycle_id,
                .text = label,
            } }) catch |err| {
                debug_trace.logf("mcp", "failed to publish MCP tool progress err={s}", .{@errorName(err)});
                return;
            };
            debug_trace.logf("mcp", "queued MCP tool progress turn_id={d}", .{lifecycle_id.turn_id});
        }

        pub fn onWebSearchProgress(ctx: *anyopaque, call_id: []const u8, progress: types.WebSearchProgress) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            app_worker_runtime.Runtime(App).pushWebSearchProgress(app, call_id, progress) catch {};
        }

        pub fn onWebFetchProgress(ctx: *anyopaque, call_id: []const u8, progress: types.WebFetchProgress) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            app_worker_runtime.Runtime(App).pushWebFetchProgress(app, call_id, progress) catch {};
        }

        pub fn onInnerToolUsage(ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
            agentReportInnerToolUsage(ctx, tool_name, usage);
        }

        pub fn onBackgroundUrlReady(ctx: *anyopaque, task_id: u64, url: []const u8) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const notice = task_helpers.backgroundServerReadyNotice(std.heap.c_allocator, task_id, url, app.session.languageSnapshot()) catch return;
            defer std.heap.c_allocator.free(notice.body);
            app_worker_runtime.Runtime(App).pushSemanticNotice(app, notice) catch {};
        }

        pub fn onTaskCompletion(ctx: *anyopaque, completion: task_helpers.TaskCompletion) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const notice = task_helpers.backgroundCompletionNotice(std.heap.c_allocator, completion, app.session.languageSnapshot()) catch return;
            defer std.heap.c_allocator.free(notice.body);
            app_worker_runtime.Runtime(App).pushSemanticNotice(app, notice) catch {};
        }

        fn agentAppendRuntimeContext(ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.appendRuntimeContextMessage(arena, messages);
        }

        fn cooperativeTransportPulse(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.cooperativeTransportPulse();
        }

        fn agentFinalizeTurn(ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, _: ?types.ProviderCompletionDisposition) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.worker.pushTurnFinished(std.heap.c_allocator, .{
                .turn_id = turn_id,
                .outcome = outcome,
            });
        }

        fn agentAppendStaticContext(ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "appendStaticContextMessage")) {
                try app.appendStaticContextMessage(arena, messages);
            }
        }

        fn agentPrepareParentTurnContext(
            ctx: *anyopaque,
            arena: Allocator,
        ) !?agent_runtime.PreparedParentTurnContext {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "session_persistence")) {
                const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return null;
                const session_id = app_session_runtime.Runtime(App).activeSessionId(app) orelse return null;
                return parent_delivery_projector.prepare(
                    arena,
                    host.sessions,
                    session_id,
                    host.manager.options.child_store,
                );
            }
            return null;
        }

        fn agentAcknowledgeParentTurnContext(
            ctx: *anyopaque,
            arena: Allocator,
            acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
        ) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "session_persistence")) {
                const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return;
                parent_delivery_projector.acknowledge(
                    arena,
                    host.sessions,
                    host.manager.options.child_store,
                    acknowledgements,
                );
            }
        }

        fn agentResolveModelDescriptor(ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.ModelDescriptor {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "resolveModelDescriptorForRequest")) {
                return app.resolveModelDescriptorForRequest(model);
            }
            if (comptime @hasDecl(App, "resolvedModelDescriptor")) {
                return app.resolvedModelDescriptor(model);
            }
            if (comptime @hasDecl(App, "resolveModelCapabilitiesForRequest")) {
                return model_capabilities.configuredDescriptor(
                    model,
                    try app.resolveModelCapabilitiesForRequest(model),
                );
            }
            return model_capabilities.configuredDescriptor(model, .{});
        }

        fn agentResolveModelCapabilities(ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
            const descriptor = try agentResolveModelDescriptor(ctx, std.heap.c_allocator, model);
            return descriptor.capabilities;
        }

        fn agentAvailableModelDescriptor(ctx: *anyopaque, model: []const u8) model_capabilities.ModelDescriptor {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "resolvedModelDescriptor")) {
                return app.resolvedModelDescriptor(model);
            }
            return model_capabilities.configuredDescriptor(model, .{});
        }

        fn agentAvailableModelCapabilities(ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
            return agentAvailableModelDescriptor(ctx, model).capabilities;
        }

        fn agentRequestToolPermission(ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.requestToolPermissionSyncWithAdvertised(arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names);
        }

        fn agentRequestPreparedFileMutationPermission(ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.requestPreparedFileMutationPermissionSyncWithAdvertised(arena, call, prepared, review_turn, permission_mode, local_grants, live_authority, advertised_dynamic_tool_names);
        }

        fn agentRequestSandboxWidening(
            ctx: *anyopaque,
            arena: Allocator,
            call: ToolCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            advertised_dynamic_tool_names: []const []const u8,
            required: agent_runtime.SandboxScopeRequired,
        ) !command_admission.PermissionOutcome {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.requestSandboxWideningSyncWithAdvertised(
                arena,
                call,
                review_turn,
                permission_mode,
                local_grants,
                live_authority,
                advertised_dynamic_tool_names,
                required,
            );
        }

        fn agentValidateToolCall(ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.validateToolCall(arena, call);
        }

        fn agentCheckToolAvailability(ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.checkToolAvailability(arena, call);
        }

        fn agentDescribeToolAction(ctx: *anyopaque, arena: Allocator, call: ToolCall, file_display_path: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.describeToolActionWithAdvertised(arena, call, file_display_path, advertised_dynamic_tool_names);
        }

        fn agentDescribeToolActionCompleted(ctx: *anyopaque, arena: Allocator, call: ToolCall, file_display_path: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.describeToolActionCompletedWithAdvertised(arena, call, file_display_path, advertised_dynamic_tool_names);
        }

        fn agentDescribeToolActionDenied(ctx: *anyopaque, arena: Allocator, call: ToolCall, file_display_path: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.describeToolActionDeniedWithAdvertised(arena, call, file_display_path, label, advertised_dynamic_tool_names);
        }

        fn agentPermissionTargetForCall(ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.permissionTargetForCallWithAdvertised(arena, call, advertised_dynamic_tool_names);
        }

        fn agentExecuteToolCall(
            ctx: *anyopaque,
            request: agent_runtime.ToolExecutionRequest,
        ) !ToolExecutionResult {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.executeToolCallWithAdvertised(request);
        }

        fn agentRecordToolCallRejected(
            ctx: *anyopaque,
            _: Allocator,
            call: ToolCall,
            model_output: []const u8,
            _: ?[]const u8,
        ) !void {
            _ = ctx;
            diagnostics.recordToolCallResult(.{
                .name = call.name,
                .arguments_json = call.arguments_json,
                .model_output = model_output,
                .ok = false,
                .started_at_ms = io_mod.milliTimestamp(),
            });
        }

        fn agentPublishCommittedFileHandoff(
            ctx: *anyopaque,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondaryPublicationReport {
            const app: *App = @ptrCast(@alignCast(ctx));
            return .{
                .diff = publishCommittedDiff(app, handoff),
                .tracker = publishCommittedTracker(app, handoff),
            };
        }

        fn publishCommittedDiff(
            app: *App,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondarySinkOutcome {
            const payload = preparedDiffPayload(
                std.heap.c_allocator,
                handoff,
            ) catch |err| {
                debug_trace.logf(
                    "tool",
                    "committed file diff projection failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            app_worker_runtime.Runtime(App).pushDiffBlock(app, payload) catch |err| {
                diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
                debug_trace.logf(
                    "tool",
                    "committed file diff publication failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            return .published;
        }

        fn publishCommittedTracker(
            app: *App,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondarySinkOutcome {
            if (comptime !@hasField(App, "change_tracker")) return .skipped;

            const path = app.alloc.dupe(u8, handoff.tracker.raw_path) catch |err| {
                debug_trace.logf(
                    "tool",
                    "committed file tracker path clone failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            const previous_content = if (handoff.tracker.previous_content) |content|
                app.alloc.dupe(u8, content) catch |err| {
                    app.alloc.free(path);
                    debug_trace.logf(
                        "tool",
                        "committed file tracker preimage clone failed err={s}",
                        .{@errorName(err)},
                    );
                    return .failed;
                }
            else
                null;
            app.change_tracker.pushOperation(app.alloc, .{
                .kind = switch (handoff.tracker.kind) {
                    .write => change_tracker_mod.OperationKind.write,
                    .edit => change_tracker_mod.OperationKind.edit,
                },
                .path = path,
                .previous_content = previous_content,
                .timestamp_ms = handoff.tracker.committed_at_ms,
            }) catch |err| {
                app.alloc.free(path);
                if (previous_content) |content| app.alloc.free(content);
                debug_trace.logf(
                    "tool",
                    "committed file tracker publication failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            return .published;
        }

        fn agentPropagateHistoryTurn(ctx: *anyopaque, turn: HistoryTurn) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).propagateHistoryTurn(app, turn, app.session.max_history_turns);
        }

        fn agentSetRecoveryCheckpoint(
            ctx: *anyopaque,
            checkpoint: session_codec.RecoveryCheckpoint,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).setRecoveryCheckpoint(app, checkpoint);
        }

        fn agentPersistUsageCheckpoint(
            ctx: *anyopaque,
            snapshot: session_usage.Snapshot,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).persistUsageCheckpoint(app, snapshot);
        }

        fn agentPropagateGrant(ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).propagateGrant(app, tool_name, target_path);
        }

        fn agentPushEvent(ctx: *anyopaque, event: WorkerEvent) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var owned_event = event;
            if (event == .finish_prompt and
                comptime @hasDecl(@TypeOf(app.worker), "handoffActivePromptSnapshots"))
            {
                var finished = event.finish_prompt;
                finished.snapshot_file_ownership =
                    try app.worker.handoffActivePromptSnapshots(std.heap.c_allocator);
                owned_event = .{ .finish_prompt = finished };
            }
            defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, owned_event);
            try app_worker_runtime.Runtime(App).pushEvent(app, owned_event);
        }

        fn agentPushText(ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            switch (emission) {
                .assistant_source => {},
                .assistant_rendered => |text| try app_worker_runtime.Runtime(App).pushText(app, text),
                .operational => |text| try app_worker_runtime.Runtime(App).pushText(app, text),
            }
        }

        fn agentPushTable(ctx: *anyopaque, table: assistant_presentation.TablePayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushTable(app, table);
            var owned = table;
            owned.deinit(std.heap.c_allocator);
        }

        fn agentPushCodeBlock(ctx: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushCodeBlock(app, block);
            var owned = block;
            owned.deinit(std.heap.c_allocator);
        }

        fn agentPushThematicRule(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushThematicRule(app);
        }

        fn agentPushToolLifecycle(
            ctx: *anyopaque,
            event: types.ToolLifecycleEvent,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushToolLifecycle(app, event);
        }

        fn agentPushDiffBlock(ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            errdefer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
            try app_worker_runtime.Runtime(App).pushDiffBlock(app, payload);
        }

        fn agentPushSystemNotice(ctx: *anyopaque, text: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                .topic = "system",
                .tone = .neutral,
                .body = text,
            });
        }

        fn agentPushInteractiveNotice(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, notice);
        }

        fn agentPushContextNotice(ctx: *anyopaque, text: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                if (!try app.session.claimContextNotice(std.heap.c_allocator, text)) return;
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, text);
            defer std.heap.c_allocator.free(body);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                .topic = "context",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            });
        }

        fn agentPushRouteRecoveryStatus(ctx: *anyopaque, status: types.RouteRecoveryStatus) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushEvent(app, .{ .route_recovery_status = status });
        }

        fn agentPushCommandOutputComplete(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushCommandOutputComplete(app, lifecycle_id);
        }

        fn agentPushHttpError(ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
            if (auth_failure != null) {
                try app_worker_runtime.Runtime(App).pushEvent(app, .authentication_failed);
            }
            const message = if (auth_failure) |failure|
                try failure.renderText(std.heap.c_allocator)
            else
                try gateway_error_format.formatHttpErrorMessage(std.heap.c_allocator, status, detail);
            defer std.heap.c_allocator.free(message);
            const label = if (auth_failure != null)
                try std.fmt.allocPrint(
                    std.heap.c_allocator,
                    "⚠ {s} · Run /setup to choose another source.",
                    .{message},
                )
            else
                try std.fmt.allocPrint(std.heap.c_allocator, "⚠ {s}", .{message});
            defer std.heap.c_allocator.free(label);
            try app_worker_runtime.Runtime(App).pushEvent(app, .{ .api_status_text = label });
        }

        fn agentRequestRouteRecovery(ctx: *anyopaque, arena: Allocator, request: agent_runtime.RouteRecoveryRequest) !agent_runtime.RouteRecoveryDecision {
            const app: *App = @ptrCast(@alignCast(ctx));
            const question = switch (request.finish_reason) {
                .content_filter => "Response blocked by content filter. What should fx do?",
                else => if (request.replay_safe)
                    try std.fmt.allocPrint(
                        arena,
                        "Route failed after {d} attempt{s} for {s}. What should fx do?",
                        .{
                            request.semantic_attempts,
                            if (request.semantic_attempts == 1) "" else "s",
                            request.route_model,
                        },
                    )
                else switch (request.unsafe_no_retry_reason orelse .assistant_output) {
                    .assistant_output => "Route failed after assistant output started. What should fx do?",
                    .tool_start => "Route failed after tool use started. What should fx do?",
                },
            };
            var options_buf: [3]types.QuestionOption = undefined;
            var option_count: usize = 0;
            if (request.finish_reason == .provider_error and request.replay_safe and request.fast_mode) {
                options_buf[option_count] = .{
                    .label = "Disable Fast",
                    .description = "Retry the selected model without Fast.",
                };
                option_count += 1;
            }
            options_buf[option_count] = .{
                .label = "Change model",
                .description = "Open the model picker and leave this prompt stopped.",
            };
            option_count += 1;
            options_buf[option_count] = .{
                .label = "Try again later",
                .description = "Stop this prompt and try again later.",
            };
            option_count += 1;

            const entry = types.QuestionBatchEntry{
                .question = question,
                .options = options_buf[0..option_count],
            };
            const answers = try app.worker.requestRouteRecoveryAnswerBlocking(std.heap.c_allocator, &.{entry});
            defer if (answers) |owned| {
                for (owned) |label| std.heap.c_allocator.free(label);
                std.heap.c_allocator.free(owned);
            };
            const label = if (answers) |owned|
                if (owned.len > 0) owned[0] else "Try again later"
            else
                "Try again later";
            if (std.mem.eql(u8, label, "Disable Fast")) return .disable_fast;
            if (std.mem.eql(u8, label, "Change model") or std.mem.eql(u8, label, "Switch model")) {
                try app_worker_runtime.Runtime(App).pushEvent(app, .open_model_picker);
                return .switch_model;
            }
            return .cancel;
        }

        fn agentFormatToolExecutionError(ctx: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.formatToolExecutionErrorForAgent(arena, tool_name, err);
        }

        fn agentReportUsage(ctx: *anyopaque, usage: types.Usage) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (usage.input_tokens) |input| app.total_input_tokens = input;
            if (usage.output_tokens) |output| app.total_output_tokens = output;
        }

        fn agentReportInnerToolUsage(ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
            if (!std.mem.eql(u8, tool_name, "web_search")) return;
            const app: *App = @ptrCast(@alignCast(ctx));
            app.total_web_search_requests +|= @as(u64, usage.web_search_requests);
        }

        fn workerBridgeWriteUserPrompt(ctx: *anyopaque, prompt: types.UserTurn) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeUserPromptCard(prompt);
        }

        fn workerBridgeWriteUserPromptWithSkillBindings(
            ctx: *anyopaque,
            prompt: types.UserTurn,
            skill_bindings: []const worker_runtime.SkillBinding,
            skill_display_spans: []const worker_runtime.SkillDisplaySpan,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "writeUserPromptCardWithSkillBindings")) {
                try app.writeUserPromptCardWithSkillBindings(prompt, skill_bindings, skill_display_spans);
            } else {
                try app.writeUserPromptCard(prompt);
            }
        }

        fn workerBridgeAppendText(ctx: *anyopaque, text: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.pacer.enqueue(app.alloc, text);
        }

        fn workerBridgeAppendTable(ctx: *anyopaque, table: assistant_presentation.TablePayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var owned = table;
            var handed_off = false;
            errdefer if (!handed_off) owned.deinit(app.alloc);
            if (comptime @hasDecl(App, "appendAssistantTable")) {
                try app.appendAssistantTable(owned);
                handed_off = true;
                return;
            }
            owned.deinit(app.alloc);
            handed_off = true;
        }

        fn workerBridgeAppendCodeBlock(ctx: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var owned = block;
            var handed_off = false;
            errdefer if (!handed_off) owned.deinit(app.alloc);
            if (comptime @hasDecl(App, "appendAssistantCodeBlock")) {
                try app.appendAssistantCodeBlock(owned);
                handed_off = true;
                return;
            }
            owned.deinit(app.alloc);
            handed_off = true;
        }

        fn workerBridgeAppendThematicRule(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "appendAssistantThematicRule")) {
                try app.appendAssistantThematicRule();
            }
        }

        fn workerBridgeDrainAssistantText(ctx: *anyopaque) !app_worker_runtime.AssistantTextDrainResult {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.pacer.flushPresentationAtBoundary(
                app.alloc,
                io_mod.nanoTimestamp(),
                app.pacerCallbacks(),
            );
            return .drained;
        }

        fn workerBridgeOpenModelPicker(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "input_runtime") and
                @hasField(App, "selected_model") and
                @hasDecl(App, "modelCompletions"))
            {
                try input_completion_runtime.CompletionRuntime(App).openCurrentModelPicker(app);
            }
        }

        fn workerBridgeSemanticNotice(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(notice, true);
        }

        fn workerBridgeCommandOutput(
            ctx: *anyopaque,
            lifecycle_id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            text: []const u8,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "writeCommandOutputChunkForLifecycle")) {
                try app.writeCommandOutputChunkForLifecycle(lifecycle_id, stream, text, true);
                return;
            }
            try app.writeCommandOutputChunk(stream, text, true);
        }

        fn workerBridgeCommandOutputComplete(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "flushCommandOutputSummaryForLifecycle")) {
                try app.flushCommandOutputSummaryForLifecycle(lifecycle_id, true);
                return;
            }
            try app.flushCommandOutputSummary(true);
        }

        fn workerBridgeDiffBlock(ctx: *anyopaque, payload: diff_mod.DiffEntryPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.registerAndEmitDiffBlock(payload);
        }

        fn workerBridgeAppendHistoryTurn(ctx: *anyopaque, finished: types.FinishedPrompt) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (try app.pacer.deferFinish(app.alloc, finished)) return;
            try appendHistoryTurn(app, finished);
        }

        fn workerBridgeSessionGrant(ctx: *anyopaque, grant: types.PermissionGrant) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.allowToolForSession(grant.tool_name, grant.target_path);
        }

        fn workerBridgeErrorText(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(notice, true);
        }

        fn appendHistoryTurn(app: *App, finished: types.FinishedPrompt) !void {
            if (comptime @hasDecl(App, "appendFinishedPrompt")) {
                try app.appendFinishedPrompt(finished);
                return;
            }
            if (comptime @hasDecl(App, "appendHistoryTurn")) {
                try app.appendHistoryTurn(finished.turn);
                if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
                return;
            }
            try app_session_runtime.Runtime(App).appendFinishedPrompt(app, finished);
        }
    };
}

const FakeWorker = struct {
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WorkerEvent) = .empty,
    propagated_history_turns: usize = 0,
    propagated_grants: usize = 0,
    active_snapshot_transfers: usize = 0,
    active_turn_id: u64 = 1,
    fail_diff_push: bool = false,
    fail_semantic_push: bool = false,
    fail_command_output_push: bool = false,

    fn deinit(self: *FakeWorker) void {
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        self.events.deinit(std.heap.c_allocator);
    }

    pub fn pushEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try worker_runtime.dupeWorkerEvent(alloc, event);
        errdefer worker_runtime.freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    pub fn pushOwnedEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        if (self.fail_diff_push) {
            switch (event) {
                .diff_block => return error.TestDiffPublicationFailure,
                else => {},
            }
        }
        if (self.fail_semantic_push) {
            switch (event) {
                .assistant_presentation => |presentation| switch (presentation) {
                    .table, .code_block => return error.TestSemanticPresentationPublicationFailure,
                    .text, .thematic_rule => {},
                },
                else => {},
            }
        }
        if (self.fail_command_output_push) {
            switch (event) {
                .command_output => return error.OutOfMemory,
                else => {},
            }
        }
        try self.events.append(alloc, event);
    }

    pub fn pushTurnFinished(self: *FakeWorker, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        try self.events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } });
    }

    pub fn propagateHistoryTurn(self: *FakeWorker, alloc: std.mem.Allocator, turn: HistoryTurn, max_history_turns: usize) !void {
        _ = alloc;
        _ = turn;
        _ = max_history_turns;
        self.propagated_history_turns += 1;
    }

    pub fn propagateGrant(self: *FakeWorker, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        _ = alloc;
        _ = tool_name;
        _ = target_path;
        self.propagated_grants += 1;
    }

    pub fn transferActivePromptSnapshots(self: *FakeWorker) void {
        self.active_snapshot_transfers += 1;
    }

    pub fn activeTurnId(self: *FakeWorker) u64 {
        return self.active_turn_id;
    }
};

const FakeSession = struct {
    max_history_turns: usize = 8,
    history_appends: usize = 0,

    fn languageSnapshot(self: *FakeSession) types.ConversationLanguage {
        _ = self;
        return types.ConversationLanguage.default();
    }

    pub fn appendHistoryEntry(self: *FakeSession, alloc: std.mem.Allocator, turn: types.HistoryTurn) !void {
        _ = alloc;
        _ = turn;
        self.history_appends += 1;
    }
};

const FakePacer = struct {
    text: std.ArrayList(u8) = .empty,
    defer_history: bool = false,
    enqueue_count: usize = 0,
    flush_count: usize = 0,
    flush_result: assistant_pacer.FlushResult = .drained,

    fn deinit(self: *FakePacer, alloc: std.mem.Allocator) void {
        self.text.deinit(alloc);
    }

    fn enqueue(self: *FakePacer, alloc: std.mem.Allocator, text: []const u8) !void {
        self.enqueue_count += 1;
        try self.text.appendSlice(alloc, text);
    }

    fn deferFinish(self: *FakePacer, alloc: std.mem.Allocator, finished: types.FinishedPrompt) !bool {
        _ = alloc;
        _ = finished;
        return self.defer_history;
    }

    pub fn flushPendingText(self: *FakePacer, callbacks: anytype) !assistant_pacer.FlushResult {
        _ = callbacks;
        self.flush_count += 1;
        if (self.flush_result == .drained) self.text.clearRetainingCapacity();
        return self.flush_result;
    }

    pub fn flushPendingTextAtBoundary(self: *FakePacer, callbacks: anytype) !void {
        _ = try self.flushPendingText(callbacks);
        self.text.clearRetainingCapacity();
    }

    pub fn flushPresentationAtBoundary(
        self: *FakePacer,
        alloc: std.mem.Allocator,
        now_ns: i128,
        callbacks: anytype,
    ) !void {
        _ = alloc;
        _ = now_ns;
        try self.flushPendingTextAtBoundary(callbacks);
    }
};

const FakeShell = struct {
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    render_requests: render_request.RenderRequestState = .{},
    lifecycle: transcript_runtime.TranscriptRuntime = .{},
    preserved_anchor_apply_count: usize = 0,

    pub fn replaceableEntryId(self: *FakeShell) ?u32 {
        _ = self;
        return null;
    }

    pub fn setRawEntryClass(self: *FakeShell, entry_id: u32, class: transcript_runtime.RawEntryClass) bool {
        _ = entry_id;
        self.last_class = class;
        return true;
    }

    pub fn applyToolLifecycle(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        return self.lifecycle.applyToolLifecycle(alloc, event);
    }

    pub fn applyToolLifecyclePreservingNormalBufferAnchor(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        self.preserved_anchor_apply_count += 1;
        return self.lifecycle.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event);
    }

    pub fn finishLifecycleBatch(
        self: *FakeShell,
        alloc: std.mem.Allocator,
    ) !void {
        return self.lifecycle.finishLifecycleBatch(alloc);
    }

    pub fn activityProjection(
        self: *const FakeShell,
    ) activity_runtime.ActivityProjection {
        return self.lifecycle.activityProjection();
    }

    pub fn focusedToolEntryId(self: *const FakeShell) ?u32 {
        return self.lifecycle.focusedToolEntryId();
    }

    pub fn focusedToolActivityKind(
        self: *const FakeShell,
    ) ?types.ToolActivityKind {
        return self.lifecycle.focusedToolActivityKind();
    }

    pub fn activeToolActivityCount(self: *const FakeShell) usize {
        return self.lifecycle.activeToolActivityCount();
    }

    pub fn toolActivityRecord(
        self: *const FakeShell,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle.toolActivityRecord(id);
    }

    pub fn finalizedToolTurnWatermark(self: *const FakeShell) u64 {
        return self.lifecycle.finalizedToolTurnWatermark();
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    worker: FakeWorker = .{},
    session: FakeSession = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    model_completion_values: []const []const u8 = &.{},
    change_tracker: change_tracker_mod.ChangeTracker = .{},
    shell: FakeShell = .{},
    terminal: struct {
        alternate_screen_owner: enum { none, active } = .none,
    } = .{},
    pacer: FakePacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    user_prompt_count: usize = 0,
    command_output_count: usize = 0,
    command_output_complete_count: usize = 0,
    last_command_output_lifecycle_turn_id: ?u64 = null,
    last_command_output_lifecycle_call_id: []const u8 = "",
    last_command_output_complete_lifecycle_turn_id: ?u64 = null,
    last_command_output_complete_lifecycle_call_id: []const u8 = "",
    history_append_count: usize = 0,
    summary_append_count: usize = 0,
    last_summary: ?types.TurnSummary = null,
    grant_count: usize = 0,
    diff_register_count: usize = 0,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    last_notice_topic: std.ArrayList(u8) = .empty,
    last_notice_tone: types.NoticeTone = .information,
    last_notice_visibility: types.NoticeVisibility = .compact_and_full,
    last_notice_record: bool = false,
    capability_request_count: usize = 0,

    fn init(alloc: std.mem.Allocator) FakeApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *FakeApp) void {
        self.worker.deinit();
        self.input_runtime.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.change_tracker.deinit(self.alloc);
        self.shell.lifecycle.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.last_notice_topic.deinit(self.alloc);
    }

    pub fn modelCompletions(self: *FakeApp, _: []const u8, out: *[32][]const u8) usize {
        const count = @min(self.model_completion_values.len, out.len);
        for (self.model_completion_values[0..count], 0..) |value, index| {
            out[index] = value;
        }
        return count;
    }

    pub fn resolveModelCapabilitiesForRequest(
        self: *FakeApp,
        model: []const u8,
    ) !model_capabilities.Capabilities {
        self.capability_request_count += 1;
        const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
        return model_capabilities.resolveCapabilities(
            model,
            .{ .reasoning_efforts = .fromSlice(&efforts) },
        );
    }

    fn storeLifecycleId(
        turn_id: *?u64,
        call_id: *[]const u8,
        lifecycle_id: ?types.ToolLifecycleId,
    ) void {
        if (lifecycle_id) |id| {
            turn_id.* = id.turn_id;
            call_id.* = id.call_id;
        } else {
            turn_id.* = null;
            call_id.* = "";
        }
    }

    fn appendRuntimeContextMessage(self: *FakeApp, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        _ = self;
        try messages.append(arena, .{ .role = .system, .content = "runtime" });
    }

    fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, _: ?agent_runtime.LiveToolAuthority, _: ?agent_runtime.LivePermissionRevalidation, _: []const []const u8) !command_admission.PermissionOutcome {
        _ = self;
        _ = arena;
        _ = call;
        _ = review_turn;
        _ = permission_mode;
        _ = local_grants;
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, _: ?agent_runtime.LiveToolAuthority, _: []const []const u8) !command_admission.PermissionOutcome {
        _ = self;
        _ = call;
        _ = review_turn;
        _ = permission_mode;
        _ = local_grants;
        prepared.deinit(arena);
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn validateToolCall(self: *FakeApp, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        _ = self;
        return .{ .failure = try std.fmt.allocPrint(arena, "invalid {s}", .{call.name}) };
    }

    fn checkToolAvailability(self: *FakeApp, _: Allocator, _: ToolCall) !?[]const u8 {
        _ = self;
        return null;
    }

    fn describeToolActionWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "run {s}", .{call.name});
    }

    fn describeToolActionCompletedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "done {s}", .{call.name});
    }

    fn describeToolActionDeniedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "denied {s} {s}", .{ call.name, label });
    }

    fn permissionTargetForCallWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "target:{s}", .{call.id});
    }

    fn executeToolCallWithAdvertised(
        self: *FakeApp,
        request: agent_runtime.ToolExecutionRequest,
    ) !ToolExecutionResult {
        _ = self;
        _ = request;
        return .{ .model_output = "tool output" };
    }

    fn registerAndEmitDiffBlock(self: *FakeApp, payload: agent_runtime.DiffEntryPayload) !void {
        defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        self.diff_register_count += 1;
        try self.transcript.appendSlice(self.alloc, payload.preview);
    }

    fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "{s}:{s}", .{ tool_name, @errorName(err) });
    }

    fn writeUserPromptCard(self: *FakeApp, prompt: types.UserTurn) !void {
        _ = prompt;
        self.user_prompt_count += 1;
    }

    pub fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, record: bool) !void {
        self.last_notice_topic.clearRetainingCapacity();
        try self.last_notice_topic.appendSlice(self.alloc, notice.topic);
        self.last_notice_tone = notice.tone;
        self.last_notice_visibility = notice.visibility;
        self.last_notice_record = record;
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn pacerCallbacks(self: *FakeApp) void {
        _ = self;
    }

    fn writeCommandOutputChunk(self: *FakeApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = stream;
        _ = text;
        _ = record;
        self.command_output_count += 1;
    }

    fn writeCommandOutputChunkForLifecycle(self: *FakeApp, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        storeLifecycleId(
            &self.last_command_output_lifecycle_turn_id,
            &self.last_command_output_lifecycle_call_id,
            lifecycle_id,
        );
        try self.writeCommandOutputChunk(stream, text, record);
    }

    fn flushCommandOutputSummary(self: *FakeApp, record: bool) !void {
        try self.flushCommandOutputSummaryForLifecycle(null, record);
    }

    fn flushCommandOutputSummaryForLifecycle(self: *FakeApp, lifecycle_id: ?types.ToolLifecycleId, record: bool) !void {
        _ = record;
        storeLifecycleId(
            &self.last_command_output_complete_lifecycle_turn_id,
            &self.last_command_output_complete_lifecycle_call_id,
            lifecycle_id,
        );
        self.command_output_complete_count += 1;
    }

    pub fn appendHistoryTurn(self: *FakeApp, turn: types.HistoryTurn) !void {
        _ = turn;
        self.history_append_count += 1;
    }

    pub fn appendFinishedPrompt(self: *FakeApp, finished: types.FinishedPrompt) !void {
        _ = finished.turn;
        self.history_append_count += 1;
        if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
        if (finished.summary) |summary| {
            self.summary_append_count += 1;
            self.last_summary = summary;
        }
    }

    fn allowToolForSession(self: *FakeApp, tool_name: []const u8, target_path: []const u8) !void {
        _ = tool_name;
        _ = target_path;
        self.grant_count += 1;
    }

    pub fn writeTranscript(self: *FakeApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    pub fn writeTranscriptClassified(self: *FakeApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(text, record);
    }

    pub fn appendReplaceableTranscriptLine(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLine(text);
    }

    pub fn appendReplaceableTranscriptLineSilent(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    pub fn appendReplaceableTranscriptLineSilentClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLineSilent(text);
    }

    pub fn replaceTrailingTranscriptLine(self: *FakeApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn replaceTrailingTranscriptLineSilent(self: *FakeApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }
};

const NoOverridePersistentApp = struct {
    alloc: Allocator,
    shell: FakeShell = .{},
    pacer: FakePacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
    fn deinit(self: *NoOverridePersistentApp) void {
        self.shell.lifecycle.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.session.deinit(self.alloc);
        self.* = undefined;
    }

    fn writeUserPromptCard(self: *NoOverridePersistentApp, prompt: types.UserTurn) !void {
        _ = self;
        _ = prompt;
    }

    fn writeDomainNotice(self: *NoOverridePersistentApp, notice: types.SemanticNotice, record: bool) !void {
        _ = self;
        _ = notice;
        _ = record;
    }

    fn pacerCallbacks(self: *NoOverridePersistentApp) void {
        _ = self;
    }

    fn writeCommandOutputChunk(self: *NoOverridePersistentApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = self;
        _ = stream;
        _ = text;
        _ = record;
    }

    fn flushCommandOutputSummary(self: *NoOverridePersistentApp, record: bool) !void {
        _ = self;
        _ = record;
    }

    fn allowToolForSession(self: *NoOverridePersistentApp, tool_name: []const u8, target_path: []const u8) !void {
        _ = self;
        _ = tool_name;
        _ = target_path;
    }

    fn writeTranscript(self: *NoOverridePersistentApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeTranscriptClassified(self: *NoOverridePersistentApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        _ = class;
        try self.writeTranscript(text, record);
    }

    fn registerAndEmitDiffBlock(self: *NoOverridePersistentApp, payload: agent_runtime.DiffEntryPayload) !void {
        _ = self;
        diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }

    fn appendReplaceableTranscriptLine(self: *NoOverridePersistentApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    fn appendReplaceableTranscriptLineSilent(self: *NoOverridePersistentApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    fn replaceTrailingTranscriptLine(self: *NoOverridePersistentApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn replaceTrailingTranscriptLineSilent(self: *NoOverridePersistentApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }
};

test "agent deps forward app callbacks through core types" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    try std.testing.expect(deps.prepare_parent_turn_context != null);
    try std.testing.expect(deps.acknowledge_parent_turn_context != null);
    try deps.push_text(deps.ctx, .{ .assistant_rendered = "hello" });
    try deps.finalize_turn(deps.ctx, 9, .completed, .length_limited);
    try deps.propagate_history_turn(deps.ctx, .{ .compacted_summary = .{
        .summary = @constCast("summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } });
    try deps.propagate_grant(deps.ctx, "read_file", "/tmp/a");
    const finished = try types.dupeFinishedPrompt(std.heap.c_allocator, .{ .turn = .{
        .compacted_summary = .{
            .summary = @constCast("finished"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        },
    } });
    try deps.push_event(deps.ctx, .{ .finish_prompt = finished });

    try std.testing.expectEqual(@as(usize, 3), app.worker.events.items.len);
    try std.testing.expectEqualStrings("hello", app.worker.events.items[0].assistant_presentation.text);
    try std.testing.expect(app.worker.events.items[1] == .tool_lifecycle);
    try std.testing.expectEqual(
        @as(u64, 9),
        app.worker.events.items[1].tool_lifecycle.turn_finished.turn_id,
    );
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.completed,
        app.worker.events.items[1].tool_lifecycle.turn_finished.outcome,
    );
    try std.testing.expectEqual(@as(usize, 1), app.worker.propagated_history_turns);
    try std.testing.expectEqual(@as(usize, 1), app.worker.propagated_grants);
    try std.testing.expectEqual(@as(usize, 0), app.worker.active_snapshot_transfers);

    const validation = try (deps.validate_tool_call orelse return error.TestExpectedEqual)(deps.ctx, std.testing.allocator, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":1}",
    });
    defer std.testing.allocator.free(validation.failure);
    try std.testing.expectEqualStrings("invalid web_fetch", validation.failure);

    const formatted = try deps.format_tool_execution_error(deps.ctx, std.testing.allocator, "tool", error.Boom);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("tool:Boom", formatted);
}

test "unauthorized HTTP errors publish authentication failure before status text" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    try deps.push_http_error(
        deps.ctx,
        .unauthorized,
        "invalid credential",
        .ai_gateway_api_key,
    );

    try std.testing.expectEqual(@as(usize, 2), app.worker.events.items.len);
    try std.testing.expect(app.worker.events.items[0] == .authentication_failed);
    try std.testing.expect(app.worker.events.items[1] == .api_status_text);
}

test "agent deps use request-time model capability resolution when available" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    const capabilities = try deps.resolve_model_capabilities(
        deps.ctx,
        std.testing.allocator,
        "provider/new-reasoning-model",
    );

    try std.testing.expectEqual(@as(usize, 1), app.capability_request_count);
    try std.testing.expect(model_capabilities.reasoningEffortSupported(capabilities, types.ReasoningEffort.literal("future-tier")));
}

test "agent deps record rejected tool calls in feedback diagnostics" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    const record = deps.record_tool_call_rejected orelse return error.TestExpectedEqual;
    try record(deps.ctx, std.testing.allocator, .{
        .id = "denied",
        .name = "run_command",
        .arguments_json = "{\"command\":\"touch /tmp/denied\"}",
    }, "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}", null);

    var buf: [1]diagnostics.ToolCallMetric = undefined;
    const n = diagnostics.snapshotToolCalls(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(!buf[0].ok);
    try std.testing.expectEqualStrings("run_command", buf[0].name());
    try std.testing.expect(std.mem.find(u8, buf[0].args(), "touch /tmp/denied") != null);
    try std.testing.expect(std.mem.find(u8, buf[0].result(), "tool_permission_denied") != null);
    try std.testing.expectEqual(@as(u64, 0), buf[0].subagent_id);
}

test "app semantic presentation sink retains payload ownership only after successful queueing" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const sink = Bindings(FakeApp).semanticPresentationSink(&app);

    const table = try assistant_presentation.parseTablePayload(
        std.heap.c_allocator,
        "| Name | Count |\n|------|------:|\n| api | 7 |\n",
    );
    const table_source_cell = table.rows[1].cells[0].ptr;
    try sink.table(sink.ctx, table);

    const code = try std.heap.c_allocator.dupe(u8, "const ready = true;\n");
    const code_source_ptr = code.ptr;
    try sink.code_block(sink.ctx, .{
        .language = try std.heap.c_allocator.dupe(u8, "zig"),
        .code = code,
    });

    try std.testing.expectEqual(@as(usize, 2), app.worker.events.items.len);
    try std.testing.expect(app.worker.events.items[0] == .assistant_presentation);
    try std.testing.expect(app.worker.events.items[0].assistant_presentation == .table);
    try std.testing.expectEqualStrings("api", app.worker.events.items[0].assistant_presentation.table.rows[1].cells[0]);
    try std.testing.expect(app.worker.events.items[0].assistant_presentation.table.rows[1].cells[0].ptr != table_source_cell);
    try std.testing.expect(app.worker.events.items[1] == .assistant_presentation);
    try std.testing.expect(app.worker.events.items[1].assistant_presentation == .code_block);
    try std.testing.expectEqualStrings("const ready = true;\n", app.worker.events.items[1].assistant_presentation.code_block.code);
    try std.testing.expect(app.worker.events.items[1].assistant_presentation.code_block.code.ptr != code_source_ptr);

    app.worker.fail_semantic_push = true;
    const failed_table = try assistant_presentation.parseTablePayload(
        std.heap.c_allocator,
        "| Name | Count |\n|------|------:|\n| api | 7 |\n",
    );
    try std.testing.expectError(
        error.TestSemanticPresentationPublicationFailure,
        sink.table(sink.ctx, failed_table),
    );
    var retained = failed_table;
    retained.deinit(std.heap.c_allocator);
}

test "interactive stream adapter queues byte-identical rendered spans" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.worker.worker_cancel_requested.store(true, .seq_cst);

    const spans = [_][]const u8{
        "\x1b[1mbold\x1b[22m and \x1b[3mitalic\x1b[23m\n",
        "\x1b]8;id=fx-1;https://example.com\x1b\\docs\x1b]8;;\x1b\\\n",
        "\x1b[2m\xe2\x94\x82 \x1b[22mconst x = **literal**;\n",
    };
    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    for (spans) |span| try deps.push_text(deps.ctx, .{ .assistant_rendered = span });

    try std.testing.expectEqual(spans.len, app.worker.events.items.len);
    for (spans, app.worker.events.items) |expected, event| {
        try std.testing.expect(event == .assistant_presentation);
        try std.testing.expect(event.assistant_presentation == .text);
        try std.testing.expectEqualStrings(expected, event.assistant_presentation.text);
    }
    try std.testing.expectEqual(@as(usize, 0), app.pacer.enqueue_count);
    try std.testing.expectEqual(@as(usize, 0), app.pacer.text.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.pacer.flush_count);
}

test "inner search tokens do not replace outer context counters" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    (deps.report_usage orelse return error.TestExpectedEqual)(deps.ctx, .{
        .input_tokens = 100,
        .output_tokens = 20,
    });
    (deps.report_inner_tool_usage orelse return error.TestExpectedEqual)(deps.ctx, "web_search", .{
        .input_tokens = 999,
        .output_tokens = 888,
        .web_search_requests = 3,
    });

    try std.testing.expectEqual(@as(u64, 100), app.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 20), app.total_output_tokens);
    try std.testing.expectEqual(@as(u64, 3), app.total_web_search_requests);
}

test "agent diff block callback enqueues worker event without direct transcript mutation" {
    const c_alloc = std.heap.c_allocator;
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    try deps.push_diff_block(deps.ctx, .{
        .preview = try c_alloc.dupe(u8, "diff preview"),
    });

    try std.testing.expectEqual(@as(usize, 0), app.diff_register_count);
    try std.testing.expectEqual(@as(usize, 1), app.worker.events.items.len);
    try std.testing.expect(app.worker.events.items[0] == .diff_block);
    try std.testing.expectEqualStrings("diff preview", app.worker.events.items[0].diff_block.preview);
}

const committed_preview_lines = [_]diff_mod.PreviewLine{
    .{
        .op = .deletion,
        .old_line = 1,
        .text = "before",
    },
    .{
        .op = .addition,
        .new_line = 1,
        .text = "after",
    },
};

fn testCommittedFileHandoff() file_mutation.CommittedFileHandoff {
    return file_mutation.CommittedFileHandoff.init(
        .{
            .path = "tracked.txt",
            .lines = &committed_preview_lines,
            .additions = 1,
            .deletions = 1,
            .truncated = false,
        },
        .{
            .kind = .edit,
            .raw_path = "/tmp/workspace/tracked.txt",
            .previous_content = "before\n",
            .committed_at_ms = 42,
        },
    );
}

test "committed file handoff publishes prepared diff and cloned tracker state" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    const handoff = testCommittedFileHandoff();
    const report = deps.publish_committed_file_handoff(deps.ctx, handoff);

    try std.testing.expectEqual(
        agent_runtime.SecondarySinkOutcome.published,
        report.diff,
    );
    try std.testing.expectEqual(
        agent_runtime.SecondarySinkOutcome.published,
        report.tracker,
    );
    try std.testing.expectEqual(@as(usize, 1), app.worker.events.items.len);
    try std.testing.expect(app.worker.events.items[0] == .diff_block);
    try std.testing.expect(std.mem.find(
        u8,
        app.worker.events.items[0].diff_block.preview,
        "after",
    ) != null);
    try std.testing.expectEqual(@as(u32, 1), app.worker.events.items[0].diff_block.additions);
    try std.testing.expectEqual(@as(u32, 1), app.worker.events.items[0].diff_block.deletions);
    try std.testing.expectEqual(@as(usize, 1), app.change_tracker.stack.items.len);
    const tracked = app.change_tracker.stack.items[0];
    try std.testing.expectEqualStrings(handoff.tracker.raw_path, tracked.path);
    try std.testing.expect(tracked.path.ptr != handoff.tracker.raw_path.ptr);
    try std.testing.expectEqualStrings(
        handoff.tracker.previous_content.?,
        tracked.previous_content.?,
    );
    try std.testing.expect(
        tracked.previous_content.?.ptr != handoff.tracker.previous_content.?.ptr,
    );
}

test "command output callback drops cancelled late chunks without mutating queued output" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 11, .call_id = "command-output-callback" };
    try Bindings(FakeApp).onCommandOutputChunk(&app, lifecycle_id, .stdout, "visible-one");
    try Bindings(FakeApp).onCommandOutputChunk(&app, lifecycle_id, .stderr, "visible-two");
    try std.testing.expectEqual(@as(usize, 2), app.worker.events.items.len);
    try std.testing.expectEqual(@as(u64, 11), app.worker.events.items[0].command_output.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings(
        "command-output-callback",
        app.worker.events.items[0].command_output.lifecycle_id.?.call_id,
    );
    try std.testing.expectEqual(command_output_content.Stream.stdout, app.worker.events.items[0].command_output.stream);
    try std.testing.expectEqualStrings("visible-one", app.worker.events.items[0].command_output.text);
    try std.testing.expectEqual(command_output_content.Stream.stderr, app.worker.events.items[1].command_output.stream);
    try std.testing.expectEqualStrings("visible-two", app.worker.events.items[1].command_output.text);

    app.worker.worker_cancel_requested.store(true, .seq_cst);
    try Bindings(FakeApp).onCommandOutputChunk(&app, lifecycle_id, .stdout, "late-one");
    try Bindings(FakeApp).onCommandOutputChunk(&app, lifecycle_id, .stderr, "late-two");

    try std.testing.expectEqual(@as(usize, 2), app.worker.events.items.len);
    try std.testing.expectEqualStrings("visible-one", app.worker.events.items[0].command_output.text);
    try std.testing.expectEqualStrings("visible-two", app.worker.events.items[1].command_output.text);
}

test "command output callback returns queue handoff failure" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.worker.fail_command_output_push = true;

    try std.testing.expectError(
        error.OutOfMemory,
        Bindings(FakeApp).onCommandOutputChunk(&app, null, .stdout, "not-queued"),
    );
    try std.testing.expectEqual(@as(usize, 0), app.worker.events.items.len);
}

test "web progress callback keeps typed lifecycle facts during cancellation" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.worker.active_turn_id = 41;
    app.worker.worker_cancel_requested.store(true, .seq_cst);

    Bindings(FakeApp).onWebSearchProgress(&app, "search_call", .{
        .results_received = .{
            .query = "current news",
            .result_count = 3,
        },
    });

    try std.testing.expectEqual(@as(usize, 1), app.worker.events.items.len);
    const lifecycle = app.worker.events.items[0].tool_lifecycle;
    try std.testing.expect(lifecycle == .progress);
    try std.testing.expectEqual(@as(u64, 41), lifecycle.progress.id.turn_id);
    try std.testing.expectEqualStrings("search_call", lifecycle.progress.id.call_id);
    try std.testing.expect(std.mem.find(
        u8,
        lifecycle.progress.text,
        "Found 3 results",
    ) != null);

    app.worker.active_turn_id = 0;
    Bindings(FakeApp).onWebSearchProgress(&app, "unowned", .{
        .query_started = "ignored",
    });
    try std.testing.expectEqual(@as(usize, 1), app.worker.events.items.len);
}

test "MCP progress callback publishes the owning tool lifecycle" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 42,
        .call_id = "mcp-progress",
    };

    Bindings(FakeApp).onMcpProgress(&app, lifecycle_id, "MCP fixture halfway");

    try std.testing.expectEqual(@as(usize, 1), app.worker.events.items.len);
    const lifecycle = app.worker.events.items[0].tool_lifecycle;
    try std.testing.expect(lifecycle == .progress);
    try std.testing.expectEqual(@as(u64, 42), lifecycle.progress.id.turn_id);
    try std.testing.expectEqualStrings("mcp-progress", lifecycle.progress.id.call_id);
    try std.testing.expect(std.mem.find(
        u8,
        lifecycle.progress.text,
        "● MCP fixture halfway",
    ) != null);
}

test "background callbacks publish ready success failure and cancellation semantics" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    Bindings(FakeApp).onBackgroundUrlReady(&app, 7, "http://localhost:3000");
    Bindings(FakeApp).onTaskCompletion(&app, .{ .id = 7, .state = .exited, .exit_code = 0 });
    Bindings(FakeApp).onTaskCompletion(&app, .{ .id = 8, .state = .failed, .exit_code = 2 });
    Bindings(FakeApp).onTaskCompletion(&app, .{ .id = 9, .state = .stopped, .exit_code = null });

    try std.testing.expectEqual(@as(usize, 4), app.worker.events.items.len);
    const ready = app.worker.events.items[0].semantic_notice;
    try std.testing.expectEqualStrings("background", ready.topic);
    try std.testing.expectEqual(types.NoticeTone.neutral, ready.tone);
    try std.testing.expectEqualStrings("Command #7 server ready at http://localhost:3000.", ready.body);
    const succeeded = app.worker.events.items[1].semantic_notice;
    try std.testing.expectEqualStrings("background", succeeded.topic);
    try std.testing.expectEqual(types.NoticeTone.neutral, succeeded.tone);
    try std.testing.expectEqualStrings("Command #7 completed successfully.", succeeded.body);
    const failed = app.worker.events.items[2].semantic_notice;
    try std.testing.expectEqualStrings("background", failed.topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", failed.tone);
    try std.testing.expectEqualStrings("Command #8 failed (exit 2).", failed.body);
    const cancelled = app.worker.events.items[3].semantic_notice;
    try std.testing.expectEqualStrings("background", cancelled.topic);
    try std.testing.expectEqual(types.NoticeTone.cancelled, cancelled.tone);
    try std.testing.expectEqualStrings("Command #9 stopped.", cancelled.body);

    for (app.worker.events.items) |event| {
        const notice = event.semantic_notice;
        try std.testing.expect(std.mem.find(u8, notice.body, "Background") == null);
    }
}

test "agent context and system notices share semantic transport with distinct fields" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).agentRuntimeDeps(&app);
    try deps.push_context_notice.?(
        deps.ctx,
        "[context] first warning\n[context] second warning",
    );
    try deps.push_system_notice(deps.ctx, "ordinary-system");
    try deps.push_interactive_notice.?(deps.ctx, .{
        .topic = "background",
        .tone = .information,
        .body = "Command #1 started. Log: /tmp/run.log",
    });

    try std.testing.expectEqual(@as(usize, 3), app.worker.events.items.len);
    try std.testing.expect(app.worker.events.items[0] == .semantic_notice);
    const context = app.worker.events.items[0].semantic_notice;
    try std.testing.expectEqualStrings("context", context.topic);
    try std.testing.expectEqual(types.NoticeTone.warning, context.tone);
    try std.testing.expectEqualStrings("first warning\nsecond warning", context.body);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, context.visibility);
    try std.testing.expect(app.worker.events.items[1] == .semantic_notice);
    const ordinary = app.worker.events.items[1].semantic_notice;
    try std.testing.expectEqualStrings("system", ordinary.topic);
    try std.testing.expectEqual(types.NoticeTone.neutral, ordinary.tone);
    try std.testing.expectEqualStrings("ordinary-system", ordinary.body);
    try std.testing.expectEqual(types.NoticeVisibility.compact_and_full, ordinary.visibility);
    const interactive = app.worker.events.items[2].semantic_notice;
    try std.testing.expectEqualStrings("background", interactive.topic);
    try std.testing.expectEqual(types.NoticeTone.information, interactive.tone);
    try std.testing.expectEqualStrings("Command #1 started. Log: /tmp/run.log", interactive.body);
}

test "worker bridge deps forward UI operations" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).workerEventHandlers(&app);
    const prompt = types.UserTurn{ .text = @constCast("prompt"), .images = &.{} };
    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 7, .call_id = "command-7" };
    app.terminal.alternate_screen_owner = .active;
    const lifecycle_transition = try deps.tool_lifecycle.apply(
        app.alloc,
        .{ .authoritative_started = .{
            .id = .{ .turn_id = 8, .call_id = "read-8" },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        } },
    );
    try std.testing.expectEqual(
        types.ToolActivityKind.read,
        lifecycle_transition.applied_activity_kind.?,
    );
    try std.testing.expect(lifecycle_transition.focus_changed());
    try std.testing.expectEqual(@as(usize, 1), app.shell.preserved_anchor_apply_count);
    try std.testing.expectEqual(@as(usize, 1), deps.tool_lifecycle.snapshot().active_tool_count);
    const terminal_transition = try deps.tool_lifecycle.apply(
        app.alloc,
        .{ .terminal = .{
            .id = .{ .turn_id = 8, .call_id = "read-8" },
            .outcome = .{ .kind = .completed, .summary = "Read file" },
        } },
    );
    try std.testing.expectEqualStrings(
        "read_file",
        terminal_transition.terminal_record.?.tool_name.?,
    );
    try std.testing.expectEqual(@as(usize, 0), terminal_transition.snapshot.active_tool_count);
    try deps.tool_lifecycle.finish_batch(app.alloc);
    try deps.write_user_prompt(deps.ctx, prompt);
    try deps.append_text(deps.ctx, "assistant");
    try deps.semantic_notice(deps.ctx, .{
        .topic = "context",
        .tone = .warning,
        .body = "context-warning",
        .visibility = .full_only,
    });
    try std.testing.expectEqualStrings("context", app.last_notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.warning, app.last_notice_tone);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, app.last_notice_visibility);
    try std.testing.expect(app.last_notice_record);
    try deps.command_output(deps.ctx, lifecycle_id, .stdout, "cmd");
    try deps.command_output_complete(deps.ctx, lifecycle_id);
    try deps.diff_block(deps.ctx, .{
        .preview = try std.heap.c_allocator.dupe(u8, "diff preview"),
    });
    try deps.append_history_turn(deps.ctx, .{ .turn = .{ .compacted_summary = .{
        .summary = @constCast("summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } }, .summary = .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    } });
    try deps.session_grant(deps.ctx, .{ .tool_name = @constCast("read_file"), .target_path = @constCast("/tmp/a") });
    try deps.error_text(deps.ctx, .{
        .topic = "system",
        .tone = .@"error",
        .body = "err",
    });
    try std.testing.expectEqualStrings("system", app.last_notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_notice_tone);

    try std.testing.expectEqual(@as(usize, 1), app.user_prompt_count);
    try std.testing.expectEqualStrings("assistant", app.pacer.text.items);
    try std.testing.expectEqual(@as(usize, 1), app.command_output_count);
    try std.testing.expectEqual(@as(usize, 1), app.command_output_complete_count);
    try std.testing.expectEqual(@as(u64, 7), app.last_command_output_lifecycle_turn_id.?);
    try std.testing.expectEqualStrings("command-7", app.last_command_output_lifecycle_call_id);
    try std.testing.expectEqual(@as(u64, 7), app.last_command_output_complete_lifecycle_turn_id.?);
    try std.testing.expectEqualStrings("command-7", app.last_command_output_complete_lifecycle_call_id);
    try std.testing.expectEqual(@as(usize, 1), app.diff_register_count);
    try std.testing.expectEqual(@as(usize, 1), app.history_append_count);
    try std.testing.expectEqual(@as(usize, 1), app.summary_append_count);
    try std.testing.expectEqual(@as(u64, 5_000), app.last_summary.?.token_progress.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), app.grant_count);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "err") != null);
    try std.testing.expectEqualStrings("system", app.last_notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_notice_tone);
    try std.testing.expectEqual(types.NoticeVisibility.compact_and_full, app.last_notice_visibility);
}

test "worker bridge binds model picker callback to current completion selection" {
    const current_model = "anthropic/claude-opus-4.8";
    const completions = [_][]const u8{
        "provider/model-0",
        current_model,
    };
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();
    app.model_completion_values = &completions;
    try app.selected_model.appendSlice(app.alloc, current_model);
    const deps = Bindings(FakeApp).workerEventHandlers(&app);

    try deps.open_model_picker(deps.ctx);

    try std.testing.expectEqualStrings("/model ", app.input_runtime.edit_state.input.items);
    var projected: [32][]const u8 = undefined;
    const projected_count = input_completion_runtime.CompletionRuntime(FakeApp).modelPickerCompletions(&app, "", &projected);
    try std.testing.expectEqual(
        @as(usize, 1),
        input_completion_runtime.CompletionRuntime(FakeApp).modelPickerIndex(&app, projected[0..projected_count]),
    );
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "workerBridgeAppendText enqueues text without producer-owned gap mutation" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).workerEventHandlers(&app);
    try deps.append_text(deps.ctx, "hello");

    try std.testing.expectEqualStrings("hello", app.pacer.text.items);
}

test "worker bridge exposes assistant text drain separately from semantic notice" {
    var app = FakeApp.init(std.testing.allocator);
    defer app.deinit();

    const deps = Bindings(FakeApp).workerEventHandlers(&app);
    try deps.append_text(deps.ctx, "partial output");
    try std.testing.expectEqual(
        app_worker_runtime.AssistantTextDrainResult.drained,
        try deps.drain_assistant_text(deps.ctx),
    );
    try deps.semantic_notice(deps.ctx, .{
        .topic = "system",
        .tone = .neutral,
        .body = "notice",
    });

    try std.testing.expectEqual(@as(usize, 1), app.pacer.flush_count);
    try std.testing.expectEqual(@as(usize, 0), app.pacer.text.items.len);
}

test "worker bridge history append fallback updates runtime history" {
    const alloc = std.testing.allocator;
    var app = NoOverridePersistentApp{ .alloc = alloc };
    defer app.deinit();

    const deps = Bindings(NoOverridePersistentApp).workerEventHandlers(&app);
    const turn = try session_runtime.makeAssistantTurn(alloc, "persist me", "saved");
    defer session_runtime.freeHistoryTurn(alloc, turn);

    try deps.append_history_turn(deps.ctx, .{ .turn = turn });

    try std.testing.expectEqual(@as(usize, 1), app.session.historyLen());
    try std.testing.expectEqualStrings(
        "persist me",
        app.session.history.items[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "saved",
        app.session.history.items[0].assistant.assistant,
    );
}

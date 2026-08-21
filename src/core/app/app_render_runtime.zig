const std = @import("std");
const builtin = @import("builtin");
const question_prompt = @import("../agent/question_prompt.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const input_queue_runtime = @import("input_queue_runtime.zig");
const app_commands = @import("app_commands.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const terminal_ui_projection = @import("../terminal/ui_projection.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const route_snapshot = @import("../gateway/route_snapshot.zig");
const test_model_descriptors = if (builtin.is_test)
    @import("../../builtins/gateway/model_descriptors.zig")
else
    struct {};
const picker_state = @import("../input/picker_state.zig");
const core_input_runtime = @import("../input/runtime.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const permission_request = @import("../permissions/permission_request.zig");
const sandbox = @import("../permissions/sandbox.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const types = @import("../shared/types.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_projection = @import("../subagent/ui_projection.zig");
const file_index = @import("../workspace/file_index.zig");
const statusline_identity = @import("../workspace/statusline_identity.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const event_loop = @import("../../ui/event_loop.zig");
const surface_frame = @import("../../ui/footer/surface_frame.zig");
const surface_invalidation = @import("../../ui/footer/surface_invalidation.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const input_presentation = @import("../../ui/footer/input_presentation.zig");
const footer_viewport = @import("../../ui/footer/viewport.zig");
const render_request = @import("../../ui/render_request.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const input_visual_layout = @import("../../ui/input/visual_layout.zig");
const registered_entities = @import("../input/registered_entities.zig");
const approval_screen = @import("../../ui/approval_screen.zig");
const models_screen = @import("../../ui/models_screen.zig");
const resume_screen = @import("../../ui/resume_screen.zig");
const skills_screen = @import("../../ui/skills_screen.zig");
const help_screen = @import("../../ui/help_screen.zig");
const settings_screen = @import("../../ui/settings_screen.zig");
const full_transcript_screen = @import("../../ui/full_transcript_screen.zig");
const render_engine = @import("../../ui/render_engine.zig");
const build_checkpoint = @import("../../ui/render_engine/build_checkpoint.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const shimmer_runtime = @import("../../ui/transcript/shimmer_runtime.zig");
const ui_subagents = @import("../../ui/subagent/controller.zig");
const ui_terminal = @import("../../ui/terminal/terminal.zig");
const vt_emulator = @import("../terminal/engine.zig");
const transcript_painter = @import("../../ui/transcript/painter.zig");
const command_output_runtime = @import("../../ui/transcript/command_output_runtime.zig");
const resume_projection = @import("../../ui/transcript/resume_projection.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const ui_render = @import("../../ui/render.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");

fn set_transcript_assistant_tail_writable(
    runtime: *transcript_runtime.TranscriptRuntime,
    writable: bool,
) void {
    if (runtime.transcript_release.assistant_tail_writable == writable) return;
    runtime.transcript_release = runtime.transcript_release.with_assistant_tail_writable(writable);
    debug_trace.logf(
        "scroll",
        "assistant tail writability changed writable={s}",
        .{if (writable) "true" else "false"},
    );
}

pub const VisualEpochResetTrigger = enum {
    native_clear_probe,
    ctrl_l,
};

const FrameAttemptResult = struct {
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
    animation_visible: bool,
    yolo_warning_visible: bool = false,

    fn is_committed(self: FrameAttemptResult) bool {
        return self.shadow_state.is_committed();
    }
};

const InlineRenderReconciliation = struct {
    alternate_screen_owns_rendering: bool = false,
    terminal_transition: render_engine.terminal_diff.FrameTerminalTransition = .none,
};

const PreparedChildConversation = struct {
    runtime: transcript_runtime.TranscriptRuntime,
    diff_entries: std.ArrayList(diff_mod.DiffEntry),
    next_diff_id: u32,
};

fn encodeSelectedChildDisplayName(
    alloc: std.mem.Allocator,
    raw_name: []const u8,
) error{OutOfMemory}!text_utils.EncodedText {
    return text_utils.encodeTerminalSafe(
        alloc,
        raw_name,
        std.math.maxInt(usize),
    );
}

/// Couples the physical terminal buffer with the logical presentation that
/// owns retry invalidations. Ctrl-X keeps one terminal shadow with native
/// primary/alternate buffers while main and child conversations retain
/// independent render queues.
const SurfaceFrameShell = struct {
    output: *transcript_runtime.TranscriptRuntime,
    invalidation_owner: *transcript_runtime.TranscriptRuntime,
    shadow_vt: ?*vt_emulator.Grid,
    committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    history_reset_uses_ris: bool,

    fn init(
        output: *transcript_runtime.TranscriptRuntime,
        invalidation_owner: *transcript_runtime.TranscriptRuntime,
        committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    ) SurfaceFrameShell {
        return .{
            .output = output,
            .invalidation_owner = invalidation_owner,
            .shadow_vt = output.shadow_vt,
            .committed_frame_layout = committed_frame_layout,
            .history_reset_uses_ris = output.history_reset_uses_ris,
        };
    }

    pub fn frameSink(
        self: *SurfaceFrameShell,
    ) render_engine.terminal_diff.FrameSink {
        return self.output.frameSink();
    }

    pub fn recordFrameInvalidation(
        self: *SurfaceFrameShell,
        range: render_engine.paint_plan.FrameInvalidationRange,
    ) !void {
        try self.invalidation_owner.recordFrameInvalidation(range);
    }
};

const RenderReconciliation = union(enum) {
    inline_render: InlineRenderReconciliation,
    file_approval_screen,
    skills_screen,
    models_screen,
    resume_screen,
    help_screen,
    settings_screen,
    frame_result: FrameAttemptResult,
};

const QueuedCardProjection = struct {
    cards: []render_input.QueuedPromptCard = &.{},
    row_count: u16 = 0,
    editor_active: bool = false,

    fn deinit(self: *QueuedCardProjection, alloc: std.mem.Allocator) void {
        for (self.cards) |card| alloc.free(card.bytes);
        if (self.cards.len > 0) alloc.free(self.cards);
        self.* = .{};
    }
};

fn composerInputAppearance(comptime App: type, app: *App) render_input.InputAppearance {
    return if (app.shell.maxxing_mode == .minimal) .lines else app.input_runtime.input_appearance;
}

fn composerPrefixStyle(comptime App: type, app: *App) input_presentation.ComposerPrefixStyle {
    return if (app.shell.maxxing_mode == .minimal) .rail else .arrow;
}

// Queued prompts stay collapsed behind their summary row until the review is
// opened; only then does the banner expand into one card per queued prompt.
fn buildQueuedCardProjection(comptime App: type, app: *App) !QueuedCardProjection {
    if (comptime !@hasField(App, "queued_prompt_review")) return .{};
    const review_entries = app.queued_prompt_review.entries;
    if (!app.queued_prompt_review.visible or
        !app.queued_prompt_review.active() or
        review_entries.len == 0) return .{};
    const draft_count = review_entries.len;

    const cards = try app.alloc.alloc(render_input.QueuedPromptCard, draft_count);
    var built: usize = 0;
    errdefer {
        for (cards[0..built]) |card| app.alloc.free(card.bytes);
        app.alloc.free(cards);
    }

    const selected_turn_id: ?u64 = blk: {
        const selected_index = app.queued_prompt_review.selected_index orelse break :blk null;
        if (selected_index >= review_entries.len) break :blk null;
        break :blk review_entries[selected_index].draft.turn_id;
    };

    var total_rows: u16 = 0;
    var editor_active = false;
    while (built < draft_count) : (built += 1) {
        const draft = review_entries[built].draft;
        const editing = selected_turn_id != null and draft.turn_id == selected_turn_id.?;
        if (editing) {
            const source = input_visual_layout.Source{
                .input = app.input_runtime.edit_state.input.items,
                .cursor = app.input_runtime.edit_state.cursor,
                .terminal_cols = app.shell.layout.cols,
                .images = app.pending_images.items,
                .pasted_blocks = app.input_runtime.entities.pasted_blocks.items,
                .image_tokens = app.input_runtime.entities.image_tokens.items,
                .skill_tokens = app.input_runtime.entities.skill_tokens.items,
            };
            const summary = input_visual_layout.summarize(source, null);
            const row_count: u16 = @intCast(@min(summary.total_rows, std.math.maxInt(u16)));
            cards[built] = .{
                .bytes = try app.alloc.dupe(u8, ""),
                .row_count = @max(row_count, 1),
                .editing = true,
            };
            total_rows +|= cards[built].row_count;
            editor_active = true;
            continue;
        }

        const review_input = draft.reviewInput();
        const review_skill_spans = draft.reviewSkillDisplaySpans();
        var skill_tokens: []registered_entities.SkillTokenSpan = if (review_skill_spans.len > 0)
            try app.alloc.alloc(registered_entities.SkillTokenSpan, review_skill_spans.len)
        else
            &.{};
        defer if (skill_tokens.len > 0) app.alloc.free(skill_tokens);
        for (review_skill_spans, 0..) |span, i| {
            skill_tokens[i] = .{
                .raw_start = span.raw_start,
                .raw_end = span.raw_end,
                .name = span.name,
                .path = span.path,
                .display_source = span.display_source,
                .owns_trailing_separator = span.owns_trailing_separator,
            };
        }

        const bytes = try input_presentation.composeQueuedPromptCard(
            app.alloc,
            .{
                .input = review_input,
                .cursor = 0,
                .terminal_cols = app.shell.layout.cols,
                .images = draft.images,
                .pasted_blocks = review_entries[built].pasted_blocks.items,
                .image_tokens = review_entries[built].image_tokens.items,
                .skill_tokens = skill_tokens,
            },
            composerInputAppearance(App, app),
            composerPrefixStyle(App, app),
        );
        const row_count: u16 = @intCast(@min(
            std.mem.count(u8, bytes, "\n"),
            std.math.maxInt(u16),
        ));
        cards[built] = .{ .bytes = bytes, .row_count = row_count };
        total_rows +|= row_count;
    }

    return .{ .cards = cards, .row_count = total_rows, .editor_active = editor_active };
}

noinline fn approvalScreenNeedsClear(
    screen_active: bool,
    request: permission_request.PermissionRequest,
    layout: types.Layout,
    commit: ?interaction_state.ApprovalScreenCommit,
) bool {
    if (!screen_active) return true;
    const prior = commit orelse return true;
    return prior.request_id != request.id or
        prior.rows != layout.rows or
        prior.cols != layout.cols;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        fn appendDeferredHistoryForVisualEpoch(
            ctx: *anyopaque,
            finished: *const types.FinishedPrompt,
        ) anyerror!assistant_pacer.DeferredFinishCommit {
            const app: *App = @ptrCast(@alignCast(ctx));
            return switch (try app_session_runtime.Runtime(App).appendFinishedPromptForVisualEpoch(
                app,
                finished.*,
            )) {
                .uncommitted => .uncommitted,
                .committed, .committed_degraded => .committed,
            };
        }

        pub fn resetVisualEpoch(
            app: *App,
            trigger: VisualEpochResetTrigger,
        ) !bool {
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);

            const committed = try app.pacer.discardDeferredPresentationForVisualEpoch(
                app.alloc,
                .{
                    .ctx = app,
                    .append_history = appendDeferredHistoryForVisualEpoch,
                },
            );
            if (!committed) {
                switch (trigger) {
                    .native_clear_probe => debug_trace.logf(
                        "native_clear",
                        "native_clear_recovery_skipped reason=history_uncommitted",
                        .{},
                    ),
                    .ctrl_l => debug_trace.logf(
                        "render",
                        "visual_epoch_reset_skipped trigger=ctrl_l reason=history_uncommitted",
                        .{},
                    ),
                }
                return false;
            }

            try app.shell.resetVisualEpoch(app.alloc, welcome);
            try app.shell.requestTerminalReset(&app.metrics);
            switch (trigger) {
                .native_clear_probe => debug_trace.logf(
                    "native_clear",
                    "native_clear_recovery_requested",
                    .{},
                ),
                .ctrl_l => debug_trace.logf(
                    "render",
                    "visual_epoch_reset_requested trigger=ctrl_l",
                    .{},
                ),
            }
            return true;
        }

        pub fn applyThemeUpdate(app: *App, light: bool, rgb: ?ui_render.TerminalRgb) !void {
            if (!ui_render.themeNeedsUpdate(light, rgb)) return;

            const prior_light = ui_render.is_light;
            app.shell.retintEntriesForTheme(app.alloc, prior_light, light) catch |err| {
                debug_trace.logf("theme", "theme_transcript_retint_failed err={s}", .{@errorName(err)});
                return;
            };
            app.pacer.rethemeInlineCode(light);
            ui_render.initTheme(light, rgb);
            app.shell.setCommandOutputRenderPolicy(shellStyles());
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.transcript);
        }

        pub fn shellStyles() transcript_runtime.Styles {
            return .{
                .system_notice_label_style = ui_render.system_notice_label_style,
                .system_notice_text_style = ui_render.system_notice_text_style,
                .reset_style = ui_render.reset_style,
                .dim_style = ui_render.dim_style,
                .red_style = ui_render.red_style,
                .cancelled_text_style = ui_render.hint_style,
                .notice_information_style = ui_render.system_notice_label_style,
                .notice_success_style = ui_render.green_style,
                .notice_warning_style = ui_render.warning_style,
                .notice_error_style = ui_render.red_style,
                .notice_cancelled_style = ui_render.dim_style,
                .code_highlight_theme = if (ui_render.is_light) .light else .dark,
            };
        }

        var model_completions_buf: [32][]const u8 = undefined;
        var effort_picker_values_buf: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined;
        var effort_picker_labels_buf: [types.ReasoningEffort.max_options + 1][]const u8 = undefined;
        var fast_picker_labels_buf: [2][]const u8 = undefined;
        var file_completions_buf: [input_completion_runtime.file_picker_completion_cap]file_index.SearchResult = undefined;
        var file_match_spans_buf: [input_completion_runtime.file_picker_completion_cap * file_index.max_path_len]file_index.MatchSpan = undefined;
        var file_path_storage_buf: [input_completion_runtime.file_picker_path_storage_cap]u8 = undefined;
        noinline fn footerContext(
            app: *App,
            upgrade_status_buf: *[64]u8,
            shimmer_pos: i16,
            queued_cards: *const QueuedCardProjection,
        ) render_input.RenderContext {
            const queue_preview = app.worker.queuePreview();

            const model_query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state);
            const pending_model = if (app.input_runtime.picker.hasPendingModelPickerSelection()) app.input_runtime.picker.model_picker_pending_model.items else null;
            var model_picker_stage: picker_state.ModelPickerStage = .model;
            var picker_items: []const []const u8 = &.{};
            var picker_index: usize = 0;
            var picker_window_start: usize = 0;
            var picker_anchor: usize = 0;

            if (model_query) |picker_query| {
                model_picker_stage = picker_query.stage;
                picker_anchor = picker_query.token_start;
                switch (picker_query.stage) {
                    .model => {
                        const count = input_completion_runtime.CompletionRuntime(App).modelPickerCompletions(app, picker_query.query, &model_completions_buf);
                        picker_items = model_completions_buf[0..count];
                        picker_index = input_completion_runtime.CompletionRuntime(App).modelPickerIndex(app, picker_items);
                        picker_window_start = input_completion_runtime.CompletionRuntime(App).modelPickerWindowStart(app, count, picker_index);
                    },
                    .effort => {
                        const target = if (app.input_runtime.picker.hasPendingModelPickerSelection()) app.input_runtime.picker.model_picker_pending_model.items else app.selected_model.items;
                        const capabilities = model_capabilities.resolveForApp(App, app, target);
                        const effort_count = model_capabilities.reasoningEffortOptionCount(capabilities);
                        for (0..effort_count) |i| {
                            effort_picker_values_buf[i] = model_capabilities.reasoningEffortAtIndex(capabilities, i);
                            effort_picker_labels_buf[i] = effort_picker_values_buf[i].displayLabel();
                        }
                        const count = picker_state.filterCompletionLabels(picker_query.query, effort_picker_labels_buf[0..effort_count], effort_picker_labels_buf[0..]);
                        picker_items = effort_picker_labels_buf[0..count];
                        picker_index = app.input_runtime.picker.model_picker_effort_index;
                        picker_window_start = app.input_runtime.picker.model_picker_effort_window_start;
                    },
                    .fast => {
                        for (picker_state.model_picker_fast_options, 0..) |option, i| fast_picker_labels_buf[i] = option;
                        const count = picker_state.filterCompletionLabels(picker_query.query, fast_picker_labels_buf[0..], fast_picker_labels_buf[0..]);
                        picker_items = fast_picker_labels_buf[0..count];
                        picker_index = app.input_runtime.picker.model_picker_fast_index;
                        picker_window_start = app.input_runtime.picker.model_picker_fast_window_start;
                    },
                }
            }

            const file_query = if (model_query == null) app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) else null;
            var file_items: []const file_index.SearchResult = &.{};
            var file_anchor: usize = 0;
            var file_selection_index: usize = 0;
            if (file_query) |fq| {
                file_anchor = fq.at_offset;
                const count = app.fileCompletions(fq.query, &file_completions_buf, &file_match_spans_buf, &file_path_storage_buf) catch |err| failed: {
                    debug_trace.logf("render", "file picker render search failed err={s}", .{@errorName(err)});
                    break :failed 0;
                };
                file_items = file_completions_buf[0..count];
                file_selection_index = app.input_runtime.picker.file_completion_index;
            }
            const inline_completion =
                input_completion_runtime.CompletionRuntime(App).visibleInlineCompletion(app);

            const visible_model = pending_model orelse app.selected_model.items;
            const visible_capabilities = model_capabilities.resolveForApp(App, app, visible_model);
            const model_supports_fast = visible_capabilities.supports_fast_mode;
            const model_supports_effort = visible_capabilities.reasoning_efforts.len > 0;
            const visible_effort = if (pending_model != null and model_supports_effort)
                pendingPickerEffort(app, visible_model, model_query, app.input_runtime.picker.model_picker_effort_index)
            else if (model_capabilities.reasoningEffortSupported(visible_capabilities, app.effort))
                app.effort
            else
                .auto;
            const visible_fast_mode = if (pending_model != null and model_supports_fast)
                pendingPickerFastMode(model_query, app.input_runtime.picker.model_picker_fast_index)
            else
                app.fast_mode;

            const upgrade_label = app.upgrader.statusLabel(upgrade_status_buf);
            const yolo_warning_active =
                if (comptime @hasField(App, "permission_state") and
                @hasField(App, "permission_engine"))
                    app_permission_runtime.Runtime(App).yoloWarningActive(app)
                else
                    false;
            const settings_snapshot = app_commands.settingsCatalogSnapshot(app);
            const now_ms = io_mod.milliTimestamp();
            var visible_stream = app.stream;
            if (!visible_stream.active) {
                if (app.pacer.completedAssistantPresentationTokenProgress()) |progress| {
                    visible_stream.token_progress = progress;
                }
            }

            return .{
                .slash_registry = app.slashRegistry(),
                .stream = visible_stream,
                .completed_assistant_presentation_tail = app.pacer.hasCompletedAssistantPresentationTail(),
                .writing_response = app.pacer.hasPending(),
                .has_api_key = app.auth.credentialSource() != null,
                .model = visible_model,
                .pending_images = app.pending_images.items,
                .input_appearance = app.input_runtime.input_appearance,
                .maxxing_mode = app.shell.maxxing_mode,
                .permission_mode = if (comptime @hasField(App, "permission_engine"))
                    app.permission_engine.mode
                else
                    .ask,
                .queued_count = if (queued_cards.cards.len > 0) queued_cards.cards.len else queue_preview.count,
                .queued_paused = if (comptime @hasField(@TypeOf(queue_preview), "paused"))
                    queue_preview.paused
                else
                    false,
                .queued_cancel_all_available = if (comptime @hasField(App, "queued_prompt_review"))
                    app.queued_prompt_review.active() and
                        app.queued_prompt_review.reason.? == .post_cancel and
                        !app.queued_prompt_review.visible and
                        app.input_runtime.edit_state.input.items.len == 0 and
                        app.pending_images.items.len == 0
                else
                    false,
                .queued_prompt_cards = queued_cards.cards,
                .queued_prompt_card_rows = queued_cards.row_count,
                .queued_editor_active = queued_cards.editor_active,
                .subagent_count = app.subagents.count(),
                .subagent_view_active = app.subagents.isViewActive(),
                .selected_subagent_id = null,
                .selected_subagent_label = null,
                .selected_subagent_status = null,
                .selected_subagent_tool_calls = 0,
                .selected_subagent_activity = null,
                .fast_mode = visible_fast_mode,
                .model_supports_fast = model_supports_fast,
                .effort = visible_effort,
                .model_supports_effort = model_supports_effort,
                .ctrl_c_pending = app.input_runtime.gestures.ctrlCExitArmed(),
                .shimmer_pos = shimmer_pos,
                .now_ms = now_ms,
                .model_query_active = model_query != null,
                .model_picker_stage = model_picker_stage,
                .model_completions_loading = if (model_query != null and model_picker_stage == .model) app.isModelCacheLoading() else false,
                .model_completions_failed = if (model_query != null and model_picker_stage == .model) app.isModelCacheFailed() else false,
                .model_completions = picker_items,
                .model_completion_index = picker_index,
                .model_completion_window_start = picker_window_start,
                .model_completion_anchor = picker_anchor,
                .file_query_active = file_query != null,
                .file_completions = file_items,
                .file_completion_index = file_selection_index,
                .file_completion_window_start = app.input_runtime.picker.file_completion_window_start,
                .file_completion_anchor = file_anchor,
                .file_completions_loading = if (file_query) |fq|
                    fileCompletionsDependOnIndex(app, fq.query) and app.isFileIndexLoading()
                else
                    false,
                .file_completions_failed = if (file_query) |fq|
                    fileCompletionsDependOnIndex(app, fq.query) and app.isFileIndexFailed()
                else
                    false,
                .inline_completion_suffix = if (inline_completion) |completion|
                    completion.suffix()
                else
                    "",
                .auth_picker = app.auth.pickerView(),
                .skills_menu = if (comptime @hasField(App, "skills"))
                    render_input.skillsMenuProjection(&app.skills)
                else
                    .{},
                .model_menu = if (comptime @hasField(App, "model_cache"))
                    render_input.modelMenuProjection(&app.model_cache)
                else
                    .{},
                .session_menu = if (comptime @hasField(App, "session_persistence")) .{
                    .active = app.session_persistence.session_picker.active,
                    .load_state = app.session_persistence.session_picker.load_state,
                    .summaries = app.session_persistence.session_picker.summaries.items,
                    .has_more = app.session_persistence.session_picker.has_more,
                    .loading_more = app.session_persistence.session_picker.loading_more,
                    .scope = app.session_persistence.session_picker.scope,
                    .selected_index = app.session_persistence.session_picker.selected,
                    .window_start = app.session_persistence.session_picker.window_start,
                    .query = app.session_persistence.session_picker.query(),
                    .now_ms = now_ms,
                    .selection_failure = app.session_persistence.session_picker.selection_failure,
                } else .{},
                .appearance_menu = render_input.appearanceMenuProjection(
                    &app.input_runtime.appearance_menu,
                    settings_snapshot,
                ),
                .statusline_menu = render_input.statuslineMenuProjection(
                    &app.input_runtime.statusline_menu,
                    settings_snapshot,
                ),
                .sandbox_menu = render_input.sandboxMenuProjection(
                    &app.input_runtime.sandbox_menu,
                    settings_snapshot,
                    sandbox.osSandboxAvailable(),
                ),
                .usage_menu = render_input.usageMenuProjection(
                    &app.input_runtime.usage_menu,
                ),
                .workspace_menu = if (comptime @hasDecl(App, "workspaceAccess"))
                    render_input.workspaceMenuProjection(
                        &app.input_runtime.workspace_menu,
                        app.workspace_root,
                        app.workspaceAccess(),
                    )
                else
                    .{},
                .upgrade_status = upgrade_label,
                .danger_status = if (yolo_warning_active)
                    app_permission_runtime.yolo_warning_text
                else
                    "",
                .danger_status_compact = if (yolo_warning_active)
                    app_permission_runtime.yolo_warning_compact_text
                else
                    "",
                .esc_clear_armed = app.input_runtime.gestures.escapeClearArmed(),
                .question = app.question_prompt.projection(),
                .statusline = buildStatuslineItems(
                    app,
                    visible_model,
                ),
                .activity = activityProjection(app),
                .input = &app.input_runtime,
            };
        }

        fn prepareChildConversationProjection(
            app: *App,
            view: ui_subagents.ChildPresentationView,
        ) !PreparedChildConversation {
            var projection = try resume_projection.ResumeProjection.initEmpty(
                app.alloc,
                &app.shell,
                io_mod.milliTimestamp(),
                1,
            );
            defer projection.deinit();

            const chat = view.chat;
            var display_name = try encodeSelectedChildDisplayName(
                app.alloc,
                chat.configuration.name,
            );
            defer display_name.deinit(app.alloc);
            var identity: std.Io.Writer.Allocating = .init(app.alloc);
            defer identity.deinit();
            try identity.writer.print(
                "{s} · {s}\nParent: {s}\nMode: {s} · status: {s} · busy: {s}\nModel: {s} · effort: {s}",
                .{
                    display_name.bytes,
                    chat.child_id,
                    chat.parent_id orelse "unavailable",
                    @tagName(chat.mode),
                    ui_subagents.statusLabelPublic(chat.state),
                    if (chat.external_busy or chat.state == .running or
                        chat.state == .awaiting_approval) "yes" else "no",
                    chat.configuration.model orelse "default",
                    if (chat.configuration.effort) |*effort| effort.label() else "default",
                },
            );
            _ = try projection.appendNotice(.{
                .topic = "subagent",
                .tone = .information,
                .body = identity.written(),
            });

            if (!view.pages.has_newest) {
                _ = try projection.appendNotice(.{
                    .topic = "history",
                    .tone = .warning,
                    .body = "Newer committed turns omitted; PgDn returns live.",
                });
            }
            var has_prior_turns = false;
            for (view.pages.pages.items) |page| {
                std.debug.assert(page.history.turns.len == page.sources.len);
                for (page.history.turns, page.sources, 0..) |_, source, index| {
                    try appendChildTurnSource(&projection, source);
                    try app_session_runtime.Runtime(App).appendHistoryToDetachedProjection(
                        app,
                        &projection,
                        page.history.turns[index .. index + 1],
                        &has_prior_turns,
                    );
                }
            }

            for (chat.messages) |message| {
                switch (message.status) {
                    .completed => continue,
                    .pending,
                    .running,
                    .awaiting_approval,
                    .failed,
                    .cancelled,
                    .interrupted,
                    => {},
                }
                try appendChildMessageSource(
                    &projection,
                    message.source_id,
                    message.identity_source,
                );
                _ = try projection.appendUserTurn(.{
                    .text = message.content,
                    .work_id = message.id,
                });
                const status = try std.fmt.allocPrint(
                    app.alloc,
                    "[{s}]",
                    .{@tagName(message.status)},
                );
                defer app.alloc.free(status);
                _ = try projection.appendNotice(.{
                    .topic = "Work",
                    .tone = .neutral,
                    .body = status,
                });
            }
            if (chat.failure_reason) |reason| {
                const body = try std.fmt.allocPrint(
                    app.alloc,
                    "Latest failure: {s}",
                    .{reason},
                );
                defer app.alloc.free(body);
                _ = try projection.appendNotice(.{
                    .topic = "subagent",
                    .tone = .@"error",
                    .body = body,
                });
            }
            var next_diff_id = projection.next_diff_id;
            if (chat.live) |live| {
                try applyLivePresentationEvents(
                    &projection.runtime,
                    app.alloc,
                    live.events,
                    &next_diff_id,
                    &projection.pending_diffs,
                );
                if (live.events.len == 0) {
                    try projection.appendAssistantText(live.text);
                    for (live.tools) |tool| {
                        const outcome: types.ToolOutcomeKind = switch (tool.phase) {
                            .started => continue,
                            .succeeded => .completed,
                            .failed => .failed,
                            .denied => .denied,
                        };
                        _ = try projection.appendToolStatus(outcome, tool.tool_name);
                    }
                }
                if (live.text_truncated or
                    live.tools_truncated or
                    live.events_truncated)
                {
                    _ = try projection.appendNotice(.{
                        .topic = "subagent",
                        .tone = .warning,
                        .body = "Live presentation truncated.",
                    });
                }
            }
            if (!chat.messageable()) {
                _ = try projection.appendNotice(.{
                    .topic = "subagent",
                    .tone = .neutral,
                    .body = "Read-only child (one-off or archived).",
                });
            }
            if (view.input_failure) |failure| {
                _ = try projection.appendNotice(.{
                    .topic = "message",
                    .tone = .@"error",
                    .body = ui_subagents.childInputFailureDisplay(failure),
                });
            } else if (view.submission_failure) |failure| {
                const body = try std.fmt.allocPrint(
                    app.alloc,
                    "Send failed [{s}{s}]",
                    .{
                        @tagName(failure.code),
                        if (failure.retryable) ", retryable" else "",
                    },
                );
                defer app.alloc.free(body);
                _ = try projection.appendNotice(.{
                    .topic = "message",
                    .tone = .@"error",
                    .body = body,
                });
            }

            if (chat.live != null) {
                try projection.finalizeLivePresentation();
            } else {
                try projection.finalize();
            }
            projection.runtime.requestTailViewport(.{
                .rows_from_bottom = view.rows_from_bottom,
                .prior_total_rows = view.prior_total_rows,
                .preserve_after_append = view.preserve_after_append,
            });
            const diff_entries = projection.takePendingDiffs();
            return .{
                .runtime = projection.intoRuntime(),
                .diff_entries = diff_entries,
                .next_diff_id = next_diff_id,
            };
        }

        fn appendChildTurnSource(
            projection: *resume_projection.ResumeProjection,
            source: subagent_projection.OwnedTurnSource,
        ) !void {
            switch (source) {
                .not_applicable => {},
                .ordinary_human => try appendChildMessageSource(
                    projection,
                    "",
                    .human,
                ),
                .manager_source => |manager_source| try appendChildMessageSource(
                    projection,
                    manager_source.source_id,
                    manager_source.identity_source,
                ),
                .unavailable => {
                    _ = try projection.appendNotice(.{
                        .topic = "Message source",
                        .tone = .warning,
                        .body = "Origin metadata is unavailable.",
                    });
                },
            }
        }

        fn applyLivePresentationEvents(
            runtime: *transcript_runtime.TranscriptRuntime,
            alloc: std.mem.Allocator,
            events: []const worker_runtime.WorkerEvent,
            next_diff_id: *u32,
            diff_entries: *std.ArrayList(diff_mod.DiffEntry),
        ) !void {
            var metrics: types.Metrics = .{};
            for (events) |event| {
                try applyLivePresentationEvent(
                    runtime,
                    alloc,
                    &metrics,
                    event,
                    next_diff_id,
                    diff_entries,
                );
            }
            try runtime.finishLifecycleBatch(alloc);
        }

        fn applyIncrementalLivePresentationEvents(
            runtime: *transcript_runtime.TranscriptRuntime,
            alloc: std.mem.Allocator,
            events: []const worker_runtime.WorkerEvent,
            applied_count: *usize,
            next_diff_id: *u32,
            diff_entries: *std.ArrayList(diff_mod.DiffEntry),
        ) !void {
            var metrics: types.Metrics = .{};
            try runtime.finishLifecycleBatch(alloc);
            while (applied_count.* < events.len) {
                try applyLivePresentationEvent(
                    runtime,
                    alloc,
                    &metrics,
                    events[applied_count.*],
                    next_diff_id,
                    diff_entries,
                );
                applied_count.* += 1;
                try runtime.finishLifecycleBatch(alloc);
            }
        }

        fn applyLivePresentationEvent(
            runtime: *transcript_runtime.TranscriptRuntime,
            alloc: std.mem.Allocator,
            metrics: *types.Metrics,
            event: worker_runtime.WorkerEvent,
            next_diff_id: *u32,
            diff_entries: *std.ArrayList(diff_mod.DiffEntry),
        ) !void {
            switch (event) {
                .assistant_presentation => |presentation| switch (presentation) {
                    .text => |text| {
                        _ = try runtime.streamAssistantChunk(
                            alloc,
                            metrics,
                            text,
                        );
                    },
                    .table => |table| {
                        var owned = try table.clone(alloc);
                        errdefer owned.deinit(alloc);
                        _ = try runtime.appendAssistantTableOwned(alloc, owned);
                    },
                    .code_block => |block| {
                        var owned = try block.clone(alloc);
                        errdefer owned.deinit(alloc);
                        _ = try runtime.appendAssistantCodeBlockOwned(alloc, owned);
                    },
                    .thematic_rule => {
                        _ = try runtime.appendAssistantThematicRule(alloc);
                    },
                },
                .semantic_notice, .error_text => |notice| {
                    _ = try runtime.appendSemanticNotice(alloc, notice);
                },
                .command_output => |chunk| {
                    _ = try command_output_runtime.writeCommandOutputChunkDetached(
                        runtime,
                        alloc,
                        metrics,
                        runtime.retainedTranscriptStyles(),
                        chunk.lifecycle_id,
                        chunk.stream,
                        chunk.text,
                        true,
                        io_mod.milliTimestamp(),
                    );
                },
                .command_output_complete => |lifecycle_id| {
                    try command_output_runtime.flushCommandOutputSummaryDetached(
                        runtime,
                        alloc,
                        runtime.retainedTranscriptStyles(),
                        lifecycle_id,
                        io_mod.milliTimestamp(),
                    );
                },
                .tool_lifecycle => |lifecycle| {
                    _ = try runtime.applyToolLifecycle(alloc, lifecycle);
                },
                .diff_block => |payload| {
                    const c_alloc = std.heap.c_allocator;
                    const wrapped = try diff_mod.wrapWithMarkers(
                        alloc,
                        next_diff_id.*,
                        payload.preview,
                    );
                    errdefer alloc.free(wrapped);
                    const full = try cloneFullDiff(c_alloc, payload.full);
                    var owns_full = true;
                    errdefer if (owns_full) {
                        if (full) |owned| owned.deinit(c_alloc);
                    };
                    try diff_entries.append(c_alloc, .{
                        .id = next_diff_id.*,
                        .full = full,
                    });
                    owns_full = false;
                    errdefer {
                        var removed = diff_entries.pop().?;
                        removed.deinit(c_alloc);
                    }
                    _ = try runtime.appendRawBytesEntryClassified(
                        alloc,
                        wrapped,
                        .diff_block,
                    );
                    next_diff_id.* +%= 1;
                },
                .route_recovery_status => |status| {
                    runtime.worker_status_state().set_route_recovery(status, io_mod.milliTimestamp());
                    runtime.render_requests.request(.footer);
                },
                .clear_route_recovery_status => {
                    if (runtime.worker_status_state().clear_route_recovery()) {
                        runtime.render_requests.request(.footer);
                    }
                },
                .api_status_text => |text| {
                    runtime.worker_status_state().set_api(text, .danger);
                    runtime.render_requests.request(.footer);
                },
                .authentication_failed => {},
                .begin_prompt,
                .begin_prompt_with_skill_bindings,
                .append_user_feedback,
                .notification,
                .question_requested,
                .open_model_picker,
                .turn_token_update,
                .tool_payload_started,
                .finish_prompt,
                .session_grant,
                => {},
            }
        }

        fn cloneFullDiff(
            alloc: std.mem.Allocator,
            source: ?diff_mod.FullDiff,
        ) !?diff_mod.FullDiff {
            const full = source orelse return null;
            const content = try alloc.dupe(u8, full.content);
            errdefer alloc.free(content);
            const call_id = try alloc.dupe(u8, full.lifecycle_id.call_id);
            return .{
                .content = content,
                .lifecycle_id = .{
                    .turn_id = full.lifecycle_id.turn_id,
                    .call_id = call_id,
                },
            };
        }

        fn appendChildMessageSource(
            projection: *resume_projection.ResumeProjection,
            source_id: []const u8,
            identity_source: ?subagent_domain.OperationIdentitySource,
        ) !void {
            switch (identity_source orelse {
                _ = try projection.appendNotice(.{
                    .topic = "Manager message",
                    .tone = .neutral,
                    .body = if (source_id.len > 0) source_id else "Unknown source",
                });
                return;
            }) {
                .human => {
                    _ = try projection.appendNotice(.{
                        .topic = "You",
                        .tone = .neutral,
                        .body = "Sent directly in this subagent chat.",
                    });
                },
                .model => {
                    _ = try projection.appendNotice(.{
                        .topic = "Parent agent",
                        .tone = .neutral,
                        .body = if (source_id.len > 0) source_id else "Parent source unavailable",
                    });
                },
            }
        }

        fn presentedApprovalBelongsToChild(
            app: *const App,
            child_id: []const u8,
        ) bool {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "mainApprovalBinding")) {
                return false;
            }
            const approval = app.approval_prompt.projection() orelse return false;
            const binding = app.subagents.mainApprovalBinding(approval.request.id) orelse return false;
            return std.mem.eql(u8, binding.child_id, child_id);
        }

        fn reconcileChildTranscriptForPresentedApproval(
            app: *App,
            child_id: []const u8,
        ) !bool {
            if (!presentedApprovalBelongsToChild(app, child_id)) return false;
            if (!app.subagents.childTranscriptPresentationDepth().active()) {
                return false;
            }
            const from = app.subagents.childTranscriptPresentationDepth();
            const closed = try app.subagents.closeChildTranscriptPresentation(app.alloc);
            if (closed) {
                debug_trace.logf(
                    "full_transcript",
                    "depth_transition from={s} to=inline route=child trigger=approval_handoff",
                    .{@tagName(from)},
                );
            }
            return closed;
        }

        fn childFooterContext(
            app: *App,
            base: render_input.RenderContext,
            view: ui_subagents.ChildPresentationView,
            display_name: []const u8,
            slash_registry: command_specs.SlashRegistry,
        ) render_input.RenderContext {
            const chat = view.chat;
            const visible_model = chat.configuration.model orelse app.selected_model.items;
            const capabilities = model_capabilities.resolveForApp(App, app, visible_model);
            var ctx = base;
            ctx.slash_registry = slash_registry;
            ctx.stream = .{};
            ctx.completed_assistant_presentation_tail = false;
            ctx.writing_response = chat.busy();
            ctx.model = visible_model;
            ctx.pending_images = &.{};
            ctx.composer_visible = chat.messageable();
            ctx.input_appearance = app.input_runtime.input_appearance;
            ctx.maxxing_mode = app.shell.maxxing_mode;
            ctx.permission_mode = .auto;
            ctx.queued_count = 0;
            ctx.queued_paused = false;
            ctx.queued_cancel_all_available = false;
            ctx.queued_prompt_cards = &.{};
            ctx.queued_prompt_card_rows = 0;
            ctx.queued_editor_active = false;
            ctx.subagent_count = 0;
            ctx.subagent_view_active = false;
            ctx.selected_subagent_label = display_name;
            ctx.selected_subagent_status = chat.state;
            ctx.fast_mode = false;
            ctx.model_supports_fast = capabilities.supports_fast_mode;
            ctx.effort = chat.configuration.effort orelse .auto;
            ctx.model_supports_effort = capabilities.reasoning_efforts.len > 0;
            ctx.ctrl_c_pending = view.editor.gestures.ctrlCExitArmed();
            ctx.model_query_active = false;
            ctx.model_completions = &.{};
            ctx.file_query_active = false;
            ctx.file_completions = &.{};
            ctx.inline_completion_suffix = "";
            ctx.auth_picker.active = false;
            ctx.skills_menu = .{};
            ctx.model_menu = if (comptime @hasField(App, "model_cache"))
                render_input.modelMenuProjection(&app.model_cache)
            else
                .{};
            ctx.session_menu = .{};
            ctx.appearance_menu = .{};
            ctx.statusline_menu = .{};
            ctx.sandbox_menu = .{};
            ctx.usage_menu = .{};
            ctx.workspace_menu = .{};
            ctx.upgrade_status = "";
            ctx.danger_status = "";
            ctx.danger_status_compact = "";
            ctx.esc_clear_armed = view.editor.gestures.escapeClearArmed();
            ctx.question = null;
            ctx.statusline = .{
                .workspace_label = base.statusline.workspace_label,
                .git_branch = base.statusline.git_branch,
                .sandbox_label = base.statusline.sandbox_label,
            };
            const worker_status_projection = if (app.subagents.childConversationRuntime()) |child_runtime|
                child_runtime.worker_status_state().projection()
            else
                null;
            ctx.activity = chat.activityProjection(worker_status_projection);
            ctx.input = view.editor;
            return ctx;
        }

        fn syncChildConversationProjection(
            app: *App,
            view: ui_subagents.ChildPresentationView,
        ) !void {
            if (app.subagents.childConversationRuntime() == null) {
                const prepared = try prepareChildConversationProjection(app, view);
                try app.subagents.installChildConversationRuntime(
                    app.alloc,
                    prepared.runtime,
                    prepared.diff_entries,
                    view.chat.live,
                    prepared.next_diff_id,
                );
                return;
            }

            const runtime = app.subagents.childConversationRuntime().?;
            // A live child can still stream into its trailing assistant
            // entry; a finished child's tail is final.
            set_transcript_assistant_tail_writable(runtime, view.chat.live != null);
            if (!std.meta.eql(runtime.layout, app.shell.layout)) {
                runtime.layout = app.shell.layout;
                runtime.markTranscriptDirty();
            }
            runtime.requestTailViewport(.{
                .rows_from_bottom = view.rows_from_bottom,
                .prior_total_rows = view.prior_total_rows,
                .preserve_after_append = view.preserve_after_append,
            });
            const live = view.chat.live orelse return;
            const applied = app.subagents.childConversationEventCount();
            if (applied >= live.events.len) return;

            var next_diff_id = app.subagents.childConversationNextDiffId();
            var applied_count = applied;
            applyIncrementalLivePresentationEvents(
                runtime,
                app.alloc,
                live.events,
                &applied_count,
                &next_diff_id,
                app.subagents.childConversationDiffEntries(),
            ) catch |err| {
                app.subagents.markChildConversationEventsAppliedThrough(
                    live,
                    applied_count,
                    next_diff_id,
                );
                return err;
            };
            app.subagents.markChildConversationEventsAppliedThrough(
                live,
                applied_count,
                next_diff_id,
            );
        }

        fn pendingPickerEffort(app: *App, model: []const u8, query: ?picker_state.ModelPickerQuery, effort_index: usize) types.ReasoningEffort {
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (query) |picker_query| {
                if (picker_query.stage == .effort) {
                    const typed = std.mem.trim(u8, picker_query.query, " \t");
                    if (types.ReasoningEffort.parseDisplayLabel(typed)) |effort| {
                        if (model_capabilities.reasoningEffortSupported(capabilities, effort)) return effort;
                    }
                }
            }
            return model_capabilities.reasoningEffortAtIndex(capabilities, effort_index);
        }

        fn buildStatuslineItems(
            app: *App,
            visible_model: []const u8,
        ) ui_render.StatuslineItems {
            var items: ui_render.StatuslineItems = .{};
            if (comptime @hasField(App, "workspace_identity") and
                @hasField(App, "workspace_root"))
            {
                const identity = app.workspace_identity.refresh(
                    app.alloc,
                    app.workspace_root,
                ) catch app.workspace_identity.snapshot();
                items.workspace_label = identity.workspace_label;
                items.git_branch = identity.git_branch;
            }
            if (app.statusline_sandbox) {
                const permission_mode: types.PermissionMode = if (comptime @hasField(App, "permission_engine"))
                    app.permission_engine.mode
                else
                    .auto;
                items.sandbox_label = sandbox.publicModeForBackend(sandbox.effectiveBackend(
                    permission_mode,
                    app.permission_state.sandbox_backend,
                )).label();
            }
            if (app.statusline_context) {
                items.context_used = app.total_input_tokens;
                items.context_total = model_capabilities.resolveForApp(App, app, visible_model).context_window;
            }
            if (comptime @hasField(App, "statusline_session")) {
                if (app.statusline_session) {
                    items.session_title = app_session_runtime.Runtime(App).cachedSessionTitle(app);
                }
            }
            return items;
        }

        fn pendingPickerFastMode(query: ?picker_state.ModelPickerQuery, fast_index: usize) bool {
            if (query) |picker_query| {
                if (picker_query.stage == .fast) {
                    const typed = std.mem.trim(u8, picker_query.query, " \t");
                    if (std.ascii.eqlIgnoreCase(typed, picker_state.model_picker_fast_options[0])) return false;
                    if (std.ascii.eqlIgnoreCase(typed, picker_state.model_picker_fast_options[1])) return true;
                }
            }
            return fast_index % picker_state.model_picker_fast_options.len == 1;
        }

        fn fileCompletionsDependOnIndex(app: *App, query: []const u8) bool {
            if (comptime @hasDecl(App, "fileCompletionsDependOnIndex")) {
                return app.fileCompletionsDependOnIndex(query);
            }
            return true;
        }

        pub fn flushRequestedFrame(app: *App) !void {
            if (app.shell.terminal_dimensions_invalid or app.shell.layout.rows == 0 or app.shell.layout.cols == 0) return;
            const has_resize_lifecycle =
                @hasField(@TypeOf(app.shell), "pending_resize_observation");
            if (comptime has_resize_lifecycle) {
                if (shell_runtime.resizeBlocksFrameCommit(&app.shell)) return;
            }
            if (comptime @hasField(App, "subagents")) {
                if (app.subagents.isViewActive() and
                    app.shell.render_requests.hasReason(.resize))
                {
                    requestSubagentSurfaceFrame(app, .resize);
                    app.shell.render_requests.clearReason(.resize);
                    debug_trace.logf(
                        "frame_schedule",
                        "resize_request_transferred surface=subagent",
                        .{},
                    );
                }
            }
            if (comptime @hasField(App, "subagents") and
                @hasDecl(App, "describeToolActionDeniedWithAdvertised") and
                @hasDecl(App, "describeToolActionCompletedWithAdvertised") and
                @hasDecl(@TypeOf(app.subagents), "childPresentationView") and
                @hasDecl(@TypeOf(app.subagents), "childConversationRuntime"))
            {
                if (app.subagents.isViewActive() and
                    app.subagents.childConversationRuntime() == null)
                {
                    if (app.subagents.childPresentationView()) |view| {
                        try syncChildConversationProjection(app, view);
                        requestSubagentSurfaceFrame(app, .subagent_panel);
                    }
                }
            }
            const render_requests = activeRenderRequests(app);
            var attempt = (try render_requests.beginAttempt()) orelse return;
            const snapshot = attempt.snapshot;
            var reason_buf: [128]u8 = undefined;
            const reason_names = renderReasonNames(snapshot.reasons, &reason_buf);
            debug_trace.logf(
                "frame_schedule",
                "attempt_begin reasons={s} reason_count={d} invalidations={d} resize_blocked={s} animation_phase={d} animation_generation={d} animation_deadline_ms={d}",
                .{
                    reason_names,
                    snapshot.reasons.count(),
                    snapshot.invalidations.len,
                    if (render_requests.blocksFrameCommit()) "true" else "false",
                    render_requests.visibleAnimationPhase(),
                    if (snapshot.animation_candidate) |candidate| candidate.generation else 0,
                    render_requests.animation_next_deadline_ms,
                },
            );
            errdefer |err| {
                if (comptime @hasField(App, "terminal")) {
                    _ = app_lifecycle.closeFullTranscriptIfActive(
                        app.alloc,
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    ) catch {};
                }
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome=error err={s} reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                    .{
                        @errorName(err),
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.pendingReasonCount(),
                        render_requests.visibleAnimationPhase(),
                        render_requests.animation_next_deadline_ms,
                    },
                );
            }
            defer attempt.deinit();

            const resize_commit = if (comptime has_resize_lifecycle)
                shell_runtime.pendingResizeFrameCommit(
                    &app.shell,
                    snapshot.reasons.contains(.resize),
                )
            else
                shell_runtime.ResizeFrameCommit.none;
            const result = (try attemptRequestedFrame(app, snapshot)) orelse {
                attempt.restore();
                render_requests.noteInputPendingAbort();
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome=input_pending reasons={s} reason_count={d} invalidations={d} consecutive_aborts={d}",
                    .{
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.consecutive_input_pending_aborts,
                    },
                );
                return;
            };

            if (!result.is_committed()) {
                render_requests.resetInputPendingAbortStreak();
                attempt.restore();
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome={s} reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                    .{
                        @tagName(result.shadow_state),
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.pendingReasonCount(),
                        render_requests.visibleAnimationPhase(),
                        render_requests.animation_next_deadline_ms,
                    },
                );
                return;
            }

            const committed_at_ms = io_mod.milliTimestamp();
            attempt.commit(
                committed_at_ms,
                render_request.animation_interval_ms,
                result.animation_visible,
            );
            if (comptime @hasField(App, "permission_state") and
                @hasField(App, "permission_engine"))
            {
                app_permission_runtime.Runtime(App).noteFrameCommitted(
                    app,
                    app_permission_runtime.monotonicMillis(),
                    result.yolo_warning_visible,
                );
            }
            if (comptime has_resize_lifecycle) {
                shell_runtime.acknowledgeResizeFrameCommit(&app.shell, resize_commit);
            }
            if (comptime @hasDecl(App, "flushNotifications")) {
                if (snapshot.reasons.contains(.notification)) {
                    app.flushNotifications();
                }
            }
            if (comptime @hasField(@TypeOf(app.shell), "resize_history_row_delta")) {
                if (snapshot.reasons.contains(.resize) and
                    !app.shell.render_requests.hasReason(.resize))
                {
                    app.shell.resize_history_row_delta = null;
                }
            }
            debug_trace.logf(
                "frame_schedule",
                "attempt_end outcome=committed reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                .{
                    reason_names,
                    snapshot.reasons.count(),
                    snapshot.invalidations.len,
                    render_requests.pendingReasonCount(),
                    render_requests.visibleAnimationPhase(),
                    render_requests.animation_next_deadline_ms,
                },
            );
            if (comptime @hasDecl(App, "persistResumeViewAfterFrame")) {
                app.persistResumeViewAfterFrame();
            }
        }

        fn attemptRequestedFrame(
            app: *App,
            snapshot: render_request.AttemptSnapshot,
        ) !?FrameAttemptResult {
            const result = (if (comptime @hasDecl(App, "renderFrameAttemptForTest"))
                App.renderFrameAttemptForTest(app, snapshot)
            else
                renderFrameAttempt(app, snapshot)) catch |err| {
                if (err == error.InputPending) return null;
                return err;
            };
            return result;
        }

        fn transcriptInputPending(context: *anyopaque) bool {
            const app: *App = @ptrCast(@alignCast(context));
            if (app.terminal_input_runtime.hasPendingTerminalInput()) return true;
            const state = app.terminal.pollInput(0) catch |err| {
                debug_trace.logf(
                    "frame_schedule",
                    "input_poll_failed err={s}",
                    .{@errorName(err)},
                );
                return true;
            };
            return state.readable or state.closed();
        }

        fn transcriptBuildCheckpoint(app: *App) ?build_checkpoint.BuildCheckpoint {
            if (comptime !@hasField(App, "terminal")) return null;
            if (comptime @hasField(App, "shell")) {
                const render_requests = activeRenderRequests(app);
                if (!render_requests.permitsInputPendingAbort()) {
                    debug_trace.logf(
                        "frame_schedule",
                        "input_cancellation_suppressed consecutive_aborts={d} bound={d}",
                        .{
                            render_requests.consecutive_input_pending_aborts,
                            render_request.max_consecutive_input_pending_aborts,
                        },
                    );
                    return null;
                }
            }
            return .init(app, transcriptInputPending);
        }

        fn reconcileBeforeFrameRender(app: *App, queued_rows: usize) !RenderReconciliation {
            if (comptime !@hasField(App, "terminal")) return .{ .inline_render = .{} };

            if (try app_lifecycle.recoverFullTranscriptDriftBeforeRender(
                app.alloc,
                &app.terminal,
                &app.shell,
                &app.metrics,
            )) {
                try requestNormalViewportRecovery(app);
            }

            const question_active = app.question_prompt.isActive();
            if (question_active) {
                if (try app_lifecycle.closeFullTranscriptIfActive(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                )) {
                    try requestNormalViewportRecovery(app);
                }
                if (app.terminal.catalogMenuScreenActive()) {
                    try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                    try requestNormalViewportRecovery(app);
                }
            }

            const approval = app.approval_prompt.projection();
            if (approval) |projection| {
                const approval_screen_active = try approval_screen.needsScreen(
                    app.alloc,
                    projection.request,
                    app.shell.layout,
                    queued_rows,
                );
                if (app.terminal.catalogMenuScreenActive()) {
                    try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                    if (!approval_screen_active) try requestNormalViewportRecovery(app);
                }
                switch (try app_lifecycle.transitionFullTranscriptForApproval(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                    approval_screen_active,
                )) {
                    .inactive, .handed_off => {},
                    .closed => {
                        try requestNormalViewportRecovery(app);
                    },
                }
                if (approval_screen_active) return .file_approval_screen;
            }

            const terminal_transition = app_lifecycle.approvalInlineRestoreTransition(
                &app.terminal,
            );
            switch (terminal_transition) {
                .none => {},
                .restore_normal_screen => {
                    if (!question_active and approval == null and
                        (settingsMenuActive(app) or helpMenuActive(app) or
                            skillsMenuActive(app) or modelMenuActive(app) or
                            sessionMenuActive(app)))
                    {
                        app.shell.render_requests.request(.footer);
                    }
                    return .{ .inline_render = .{
                        .terminal_transition = terminal_transition,
                    } };
                },
            }

            if (!question_active and approval == null and (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app))) {
                if (try app_lifecycle.closeFullTranscriptIfActive(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                )) {
                    try requestNormalViewportRecovery(app);
                }
                if (settingsMenuActive(app)) return .settings_screen;
                if (modelMenuActive(app)) return .models_screen;
                if (sessionMenuActive(app)) return .resume_screen;
                if (helpMenuActive(app)) return .help_screen;
                return .skills_screen;
            }

            if (app.terminal.catalogMenuScreenActive()) {
                try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                try requestNormalViewportRecovery(app);
            }

            return .{ .inline_render = .{
                .alternate_screen_owns_rendering = app.terminal.alternate_screen_owner != .none,
            } };
        }

        fn renderFrameAttempt(app: *App, snapshot: render_request.AttemptSnapshot) !FrameAttemptResult {
            var checkpoint_storage = transcriptBuildCheckpoint(app);
            const checkpoint = if (checkpoint_storage) |*value| value else null;
            const supports_child_conversation_projection =
                @hasDecl(App, "describeToolActionDeniedWithAdvertised") and
                @hasDecl(App, "describeToolActionCompletedWithAdvertised");
            const child_view: ?ui_subagents.ChildPresentationView =
                if (comptime supports_child_conversation_projection)
                    app.subagents.childPresentationView()
                else
                    null;
            if (app.subagents.isViewActive() and child_view == null) {
                return renderSubagentManagerScreen(app);
            }
            if (comptime supports_child_conversation_projection) {
                if (child_view) |view| {
                    try syncChildConversationProjection(app, view);
                }
            }
            // Frame-fresh producer fact for the finality floor: the trailing
            // assistant entry stays non-final while the stream is open or
            // the pacer still holds undelivered output.
            set_transcript_assistant_tail_writable(
                &app.shell,
                app.stream.active or app.pacer.hasPending(),
            );
            const presentation_shell: *transcript_runtime.TranscriptRuntime =
                if (child_view != null)
                    app.subagents.childConversationRuntime() orelse &app.shell
                else
                    &app.shell;
            if (child_view) |view| {
                _ = try reconcileChildTranscriptForPresentedApproval(
                    app,
                    view.chat.child_id,
                );
            }
            if (child_view != null) {
                const surface_changed = if (modelMenuActive(app) or
                    skillsMenuActive(app))
                    if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "activateChildCatalogSurface",
                    ))
                        app.subagents.activateChildCatalogSurface()
                    else
                        false
                else if (comptime @hasDecl(
                    @TypeOf(app.subagents),
                    "activateChildConversationSurface",
                ))
                    app.subagents.activateChildConversationSurface()
                else
                    false;
                if (surface_changed) {
                    if (!modelMenuActive(app)) {
                        presentation_shell.invalidateTranscriptAnchor(
                            "subagent child surface activated",
                        );
                        presentation_shell.markTranscriptDirty();
                    }
                }
            }
            const render_requests = activeRenderRequests(app);
            var upgrade_status_buf: [64]u8 = undefined;
            var queued_cards = try buildQueuedCardProjection(App, app);
            defer queued_cards.deinit(app.alloc);
            var child_display_name: ?text_utils.EncodedText = if (child_view) |view|
                try encodeSelectedChildDisplayName(
                    app.alloc,
                    view.chat.configuration.name,
                )
            else
                null;
            defer if (child_display_name) |*display_name| {
                display_name.deinit(app.alloc);
            };
            const shimmer_pos = if (snapshot.animation_candidate) |candidate|
                candidate.phase
            else
                render_requests.visibleAnimationPhase();
            const main_footer_ctx = footerContext(
                app,
                &upgrade_status_buf,
                shimmer_pos,
                &queued_cards,
            );
            var child_slash_specs: [command_specs.child_chat_slash_command_count]command_specs.SlashSpec =
                undefined;
            var footer_ctx = if (child_view) |view|
                childFooterContext(
                    app,
                    main_footer_ctx,
                    view,
                    child_display_name.?.bytes,
                    command_specs.childChatSlashRegistry(
                        app.slashRegistry(),
                        &child_slash_specs,
                    ),
                )
            else
                main_footer_ctx;
            if (child_view != null and modelMenuActive(app)) {
                return renderChildModelsScreen(app, footer_ctx);
            }
            if (child_view != null and skillsMenuActive(app)) {
                return renderChildSkillsScreen(app, footer_ctx);
            }
            const render_reconciliation = if (child_view != null)
                InlineRenderReconciliation{ .alternate_screen_owns_rendering = true }
            else switch (try reconcileBeforeFrameRender(app, render_input.queuedBannerRows(footer_ctx))) {
                .inline_render => |inline_render| inline_render,
                .file_approval_screen => return renderApprovalScreen(app),
                .skills_screen => return renderSkillsScreen(app, footer_ctx),
                .models_screen => return renderModelsScreen(app, footer_ctx),
                .resume_screen => return renderResumeScreen(app, footer_ctx),
                .help_screen => return renderHelpScreen(app, footer_ctx),
                .settings_screen => return renderSettingsScreen(app, footer_ctx),
                .frame_result => |result| return result,
            };
            const presentation_commits_transcript =
                child_view != null or
                !render_reconciliation.alternate_screen_owns_rendering;
            const active_committed_layout = if (render_reconciliation.alternate_screen_owns_rendering)
                app.terminal.alternate_frame_layout
            else
                app.shell.committed_frame_layout;

            var attempt_invalidations = snapshot.invalidations;
            presentation_shell.normalizeFrameInvalidations(&attempt_invalidations);
            var frame_redraw = snapshot.reasons.count() > 0 or !attempt_invalidations.isEmpty();

            const body_rows: usize = presentation_shell.layout.content_bottom;

            var prepared_transcript: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
            defer if (prepared_transcript) |*prepared| prepared.deinit(app.alloc);
            var owned_transcript_source: ?transcript_runtime.TranscriptPreparationSource = null;
            defer if (owned_transcript_source) |*source| source.deinit(app.alloc);
            var transcript_source: ?*transcript_runtime.TranscriptPreparationSource = null;
            var full_transcript_projection: ?*full_transcript_screen.Projection = null;
            var transcript_transition: ?transcript_runtime.TranscriptTransition = null;
            defer if (transcript_transition) |*transition| transition.deinit(app.alloc);
            var footer_measurement: ?surface_frame.SurfaceFooterMeasurement = null;
            defer if (footer_measurement) |*measurement| measurement.deinit(app.alloc);
            const extra_input_rows_before_footer_prepare = presentation_shell.extra_input_rows;
            const footer_reserved_base_rows_before_footer_prepare = presentation_shell.footer_reserved_base_rows;
            var restore_footer_prepare_state = true;
            defer {
                if (restore_footer_prepare_state) {
                    presentation_shell.extra_input_rows = extra_input_rows_before_footer_prepare;
                    presentation_shell.footer_reserved_base_rows = footer_reserved_base_rows_before_footer_prepare;
                }
            }
            const visible_approval = if (child_view) |view|
                if (presentedApprovalBelongsToChild(app, view.chat.child_id))
                    app.approval_prompt.projection()
                else
                    null
            else
                app.approval_prompt.projection();
            {
                footer_ctx.transcript_depth = presentation_shell.transcriptPresentationDepth();
                if (presentation_shell.fullTranscriptActive()) {
                    const full_diff_resolver: ?full_transcript_screen.FullDiffResolver =
                        if (child_view != null)
                            app.subagents.childFullTranscriptDiffResolver()
                        else if (comptime @hasDecl(App, "fullTranscriptDiffResolver"))
                            app.fullTranscriptDiffResolver()
                        else
                            null;
                    full_transcript_projection = try presentation_shell.cachedFullTranscriptProjectionInterruptible(
                        app.alloc,
                        full_diff_resolver,
                        checkpoint,
                    );
                }
                footer_measurement = try surface_frame.measureSurfaceFooter(
                    app.alloc,
                    presentation_shell,
                    visible_approval,
                    footer_ctx,
                );
                const omitted_entry_id: ?u32 = if (!presentation_shell.fullTranscriptActive() and footer_measurement != null) switch (footer_measurement.?.activity_projection) {
                    .tool_slot => |slot| if (slot.active) slot.entry_id else null,
                    .none, .turn_thinking => null,
                } else null;
                if (!presentation_shell.fullTranscriptActive()) {
                    if (try presentation_shell.pendingResumeSourceInterruptible(
                        app.alloc,
                        checkpoint,
                    )) |source| {
                        transcript_source = source;
                    } else if (omitted_entry_id) |entry_id| {
                        owned_transcript_source = if (presentation_shell.maxxing_mode == .minimal)
                            try presentation_shell.prepareTranscriptSourceForFrameInterruptible(
                                app.alloc,
                                entry_id,
                                null,
                                checkpoint,
                            )
                        else
                            try presentation_shell.prepareTranscriptSourceForFrameInterruptible(
                                app.alloc,
                                null,
                                entry_id,
                                checkpoint,
                            );
                    } else {
                        owned_transcript_source = try presentation_shell.cachedTranscriptSourceInterruptible(
                            app.alloc,
                            checkpoint,
                        );
                    }
                    if (transcript_source == null) {
                        transcript_source = &owned_transcript_source.?;
                    }
                }
            }
            const footer_reservation_changed = if (footer_measurement) |*measurement|
                measurement.changesFooterReservation(presentation_shell)
            else
                false;
            const replay_displaced_footer_history = if (footer_measurement) |*measurement|
                measurement.replaysDisplacedTranscriptHistory(presentation_shell)
            else
                false;

            var footer_frame: surface_frame.SurfaceFooterFrame = undefined;
            var footer_frame_initialized = false;
            defer if (footer_frame_initialized) footer_frame.deinit(app.alloc);
            var solved_layout: ?render_engine.frame_layout.FrameLayout = null;
            var resolved_transcript_target: ?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget = null;
            var scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
                presentation_shell.layout.rows,
                presentation_shell.owned_top_row,
            );
            var planned_scroll_next_start_line: usize = 0;
            {
                const transcript_preview = if (transcript_source) |source|
                    source.preview
                else
                    render_engine.frame_layout.TranscriptFlowPreview{
                        .natural_visual_rows = @intCast(@min(body_rows, @as(usize, std.math.maxInt(u16)))),
                        .cursor_row = presentation_shell.cursor_row,
                        .cursor_col = presentation_shell.cursor_col,
                        .replaceable_row = presentation_shell.replaceable_row,
                    };
                const neutral_footer = if (footer_measurement) |*measurement|
                    measurement.frameLayoutMeasurement()
                else
                    footerMeasurementFromRows(footer_frame.paint.footer);
                const frame_activity = if (footer_measurement) |*measurement|
                    frameActivityStateFromMeasurement(presentation_shell, measurement)
                else
                    activityStateFromPlacement(footer_frame.paint.activity);
                const target_activity_projection: activity_runtime.ActivityProjection = if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .{ .turn_thinking = .{ .label = footer_frame.label() } };
                var fixed_point_ctx = FixedPointTranscriptContext(App){
                    .app = app,
                    .presentation_shell = presentation_shell,
                    .prepare_transcript = !presentation_shell.fullTranscriptActive(),
                    .source = transcript_source,
                    .prepared_transcript = &prepared_transcript,
                    .resolved_target = &resolved_transcript_target,
                    .footer_reservation_changed = footer_reservation_changed,
                    .replay_displaced_footer_history = replay_displaced_footer_history,
                    .footer_measurement = if (footer_measurement) |*measurement| measurement else null,
                    .fallback_footer_rows = if (footer_measurement == null)
                        footer_frame.paint.footer
                    else
                        null,
                    .activity_projection = target_activity_projection,
                    .frame_activity = frame_activity,
                    .base_invalidation = if (footer_measurement != null)
                        render_engine.paint_plan.FrameInvalidationSet.empty()
                    else
                        footer_frame.paint.invalidation,
                    .attempt_invalidations = attempt_invalidations,
                };
                const fixed_point = try render_engine.frame_fixed_point.solve(
                    FixedPointTranscriptContext(App),
                    &fixed_point_ctx,
                    .{
                        .terminal = presentation_shell.layout,
                        .owned_top = presentation_shell.owned_top_row,
                        .footer = neutral_footer,
                        .transcript = transcript_preview,
                        .activity = frame_activity,
                        .body_mode = .transcript,
                        .prior = active_committed_layout,
                    },
                    FixedPointTranscriptContext(App).prepareCandidate,
                    FixedPointTranscriptContext(App).resolveCandidate,
                );
                const solved = fixed_point.layout;
                solved_layout = solved;
                scroll_plan = fixed_point.scroll_plan;
                debug_trace.logf(
                    "frame_layout",
                    "layout_id={x} solved_frame_height={d} footer_height={d} footer_top={d} owned_top={d} owned_bottom={d} scroll_rows={d}",
                    .{
                        solved.layout_id,
                        solved.solved_frame_height,
                        solved.footer_area.height(),
                        solved.footer_area.top,
                        solved.owned_top,
                        solved.owned_band.bottom,
                        scroll_plan.terminal_scroll_rows,
                    },
                );
                const solved_footer_rows = if (footer_measurement) |*measurement|
                    measurement.frameLayoutRows(presentation_shell.layout.rows, solved.footer_area.top)
                else
                    footer_frame.paint.footer;
                const solved_viewport = if (resolved_transcript_target) |target|
                    target.selection()
                else if (prepared_transcript) |*prepared|
                    prepared.selection
                else if (footer_measurement != null)
                    surface_frame.currentSurfaceFooterTranscriptState(presentation_shell).selection
                else
                    footer_frame.paint.viewport;
                const solved_projection = if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .none;
                const solved_activity = if (footer_measurement != null)
                    render_engine.activity_placement.resolve(
                        solved_projection,
                        frame_activity,
                        solved,
                    )
                else
                    render_engine.activity_placement.resolve(
                        .{ .turn_thinking = .{ .label = footer_frame.label() } },
                        frame_activity,
                        solved,
                    );
                const solved_cursor_visible = if (footer_measurement) |*measurement|
                    measurement.input_visible
                else switch (solved_activity) {
                    .transient_row => false,
                    .none, .overlay_entry => true,
                };
                const solved_cursor_target = if (resolved_transcript_target) |target|
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = target.cursorRow(),
                        .col = target.cursorCol(),
                        .visible = solved_cursor_visible,
                    }
                else if (prepared_transcript) |*prepared|
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = prepared.cursor.cursor_row,
                        .col = prepared.cursor.cursor_col,
                        .visible = solved_cursor_visible,
                    }
                else if (footer_measurement != null)
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = solved_footer_rows.input_base,
                        .col = 1,
                        .visible = solved_cursor_visible,
                    }
                else
                    footer_frame.paint.cursor_target;
                const solved_plan = solved.toPaintPlan(.{
                    .footer_rows = solved_footer_rows,
                    .viewport = solved_viewport,
                    .activity = solved_activity,
                    .invalidation = if (footer_measurement != null)
                        render_engine.paint_plan.FrameInvalidationSet.empty()
                    else
                        footer_frame.paint.invalidation,
                    .synchronized_update = app.shell.sync_updates_enabled,
                    .cursor_target = solved_cursor_target,
                    .preserve_scrollback = if (footer_measurement != null)
                        !presentation_shell.pending_scroll_compact
                    else
                        footer_frame.paint.preserve_scrollback,
                    .reset_terminal = shouldResetPhysicalTerminal(
                        child_view != null,
                        app.shell.terminal_reset_pending,
                    ),
                });
                if (footer_measurement) |*measurement| {
                    footer_frame = try surface_frame.prepareMeasuredSurfaceFooterFrameForPlan(
                        app.alloc,
                        presentation_shell,
                        &frame_redraw,
                        visible_approval,
                        footer_ctx,
                        measurement,
                        solved_plan,
                        attempt_invalidations,
                    );
                    footer_frame_initialized = true;
                } else {
                    surface_frame.retargetSurfaceFooterFrame(&footer_frame, solved_plan);
                }
                if (!framePlanBandsEqual(footer_frame.paint, solved_plan)) {
                    debug_trace.logf(
                        "frame_layout",
                        "migration_mismatch old_transcript={d}..{d} old_activity={d}..{d} old_footer={d}..{d} solved_transcript={d}..{d} solved_activity={d}..{d} solved_footer={d}..{d}",
                        .{
                            footer_frame.paint.transcript_band.top,
                            footer_frame.paint.transcript_band.bottom,
                            footer_frame.paint.activity_band.top,
                            footer_frame.paint.activity_band.bottom,
                            footer_frame.paint.footer_band.top,
                            footer_frame.paint.footer_band.bottom,
                            solved_plan.transcript_band.top,
                            solved_plan.transcript_band.bottom,
                            solved_plan.activity_band.top,
                            solved_plan.activity_band.bottom,
                            solved_plan.footer_band.top,
                            solved_plan.footer_band.bottom,
                        },
                    );
                }
                try footer_frame.paint.validate();
                if (prepared_transcript) |*prepared| {
                    try validatePreparedTranscriptFitsPlan(prepared, footer_frame.paint);
                    planned_scroll_next_start_line = if (resolved_transcript_target) |target|
                        target.selection().start_line
                    else
                        prepared.selection.start_line;
                }
                if (full_transcript_projection) |projection| {
                    const area = footer_frame.paint.transcript_band;
                    if (!area.isEmpty()) {
                        const capability = if (comptime @hasDecl(App, "fullTranscriptSidecarCapability"))
                            app.fullTranscriptSidecarCapability()
                        else
                            null;
                        const staged = try presentation_shell.prepareFullTranscriptSurfacePaintInterruptible(
                            app.alloc,
                            &app.metrics,
                            projection,
                            capability,
                            .{ .top = area.top, .bottom = area.bottom },
                            checkpoint,
                        );
                        owned_transcript_source = staged.source;
                        transcript_source = &owned_transcript_source.?;
                        prepared_transcript = staged.prepared;
                        footer_frame.paint.viewport = prepared_transcript.?.selection;
                        try validatePreparedTranscriptFitsPlan(&prepared_transcript.?, footer_frame.paint);
                    }
                }
            }
            if (presentation_commits_transcript) {
                if (transcript_source) |source| {
                    if (prepared_transcript) |*prepared| {
                        if (presentation_shell.fullTranscriptActive()) {
                            if (child_view == null) return error.InvalidFullTranscriptRoute;
                            const layout = solved_layout orelse return error.MissingSolvedFrameLayout;
                            transcript_transition = try presentation_shell.finalizeTranscriptTransitionForFrame(
                                app.alloc,
                                source,
                                prepared,
                                render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(layout),
                                &footer_frame.paint,
                                scroll_plan,
                                footer_reservation_changed,
                                replay_displaced_footer_history,
                            );
                        } else {
                            const target = resolved_transcript_target orelse
                                return error.MissingResolvedTranscriptTarget;
                            transcript_transition = try presentation_shell.sealTranscriptTransition(
                                app.alloc,
                                source,
                                prepared,
                                &footer_frame.paint,
                                target,
                            );
                        }
                    }
                }
            }
            const committed_layout = solved_layout orelse return error.MissingSolvedFrameLayout;
            const commit_diagnostic = presentation_shell.transcriptCommitDiagnostic();
            debug_trace.logf(
                "scroll",
                "frame_builder_scroll terminal_scroll_rows={d} source_state={s} previous_committed_start_line={d} next_start_line={d}",
                .{
                    scroll_plan.terminal_scroll_rows,
                    @tagName(commit_diagnostic.state),
                    commit_diagnostic.stable_start_line orelse 0,
                    planned_scroll_next_start_line,
                },
            );

            const observation_activity: activity_runtime.ActivityProjection =
                if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .{ .turn_thinking = .{ .label = footer_frame.label() } };
            var frame_ctx = FramePaintContext(App){
                .app = app,
                .presentation_shell = presentation_shell,
                .body = .transcript,
                .prepared_transcript = if (prepared_transcript) |*prepared| prepared else null,
                .footer_frame = &footer_frame,
                .activity_style = switch (observation_activity) {
                    .tool_slot => |slot| if (slot.thinking_label != null) .thinking else .tool_marker,
                    .turn_thinking => |thinking| switch (thinking.tone) {
                        .thinking => .thinking,
                        .neutral => .neutral,
                        .warning => .warning,
                        .success => .success,
                        .danger => .danger,
                    },
                    .none => .thinking,
                },
                .activity_result = .{ .painted = false, .row = 0, .overlay = false },
            };
            const document_append = if (transcript_transition) |*transition|
                transition.document_append
            else
                render_engine.frame_scroll_plan.FrameDocumentAppend{};
            const transcript_body: render_engine.frame_builder.TranscriptBodyDisposition =
                if (transcript_transition) |*transition| switch (transition.body_disposition) {
                    .paint => .paint,
                    .retain_committed => |retained| .{ .retain = retained },
                } else .paint;
            const observation_rows = if (transcript_transition) |*transition|
                switch (transition.body_disposition) {
                    .paint => transition.row_provenance,
                    .retain_committed => presentation_shell.committedRowProvenance(),
                }
            else
                presentation_shell.committedRowProvenance();
            var counters: render_engine.frame_builder.TraceCounters = .{};
            try build_checkpoint.poll(checkpoint);
            if (footer_frame.paint.reset_terminal) {
                if (comptime @hasField(App, "terminal")) {
                    app.terminal.clearTmuxScreenAndHistory(app.alloc);
                }
            }
            var frame_shell = SurfaceFrameShell.init(
                &app.shell,
                presentation_shell,
                active_committed_layout,
            );
            const result = try render_engine.frame_builder.buildAndFlushFrame(
                app.alloc,
                &frame_shell,
                &app.metrics,
                .{
                    .plan = footer_frame.paint,
                    .committed_layout = active_committed_layout,
                    .body = frame_ctx.body,
                    .transcript_body = transcript_body,
                    .scroll_plan = scroll_plan,
                    .document_append = document_append,
                    .terminal_transition = render_reconciliation.terminal_transition,
                    .body_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintBody },
                    .footer_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintFooter },
                    .activity_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintActivity },
                    .trace_counters = &counters,
                    .observation = .{
                        .observer = &presentation_shell.ui_observer,
                        .row_provenance = observation_rows,
                        .activity = observation_activity,
                        .stream_active = footer_ctx.stream.active,
                        .completed_assistant_presentation_tail = footer_ctx.completed_assistant_presentation_tail,
                    },
                },
            );
            const scroll_commit = result.scrollCommit(scroll_plan);
            debug_trace.logf(
                "frame_diff",
                "attempt_result transcript_body={s} body_paints={d} retained_changed_cells={d} document_append_bytes={d} planned_scroll_rows={d} committed_scroll_rows={d} accepted_scroll_rows={d} unplanned_scroll_rows={d} changed_cells={d} shadow_state={s}",
                .{
                    @tagName(transcript_body),
                    counters.body_paints,
                    counters.retained_transcript_changed_cells,
                    document_append.bytes.len,
                    scroll_commit.planned_terminal_scroll_rows,
                    scroll_commit.physical_terminal_scroll_rows,
                    scroll_commit.accepted_terminal_scroll_rows,
                    scroll_commit.unplanned_terminal_scroll_rows,
                    result.changed_cells,
                    @tagName(result.state()),
                },
            );

            if (presentation_commits_transcript) {
                const transition_ptr: ?*transcript_runtime.TranscriptTransition =
                    if (transcript_transition) |*transition| transition else null;
                presentation_shell.consumeFrameScrollCommit(
                    app.alloc,
                    scroll_plan,
                    result,
                    transition_ptr,
                );
            }
            if (result.is_committed() and render_reconciliation.alternate_screen_owns_rendering) {
                app.terminal.alternate_frame_layout =
                    render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(committed_layout);
            }
            if (result.is_committed()) {
                switch (render_reconciliation.terminal_transition) {
                    .none => {},
                    .restore_normal_screen => app_lifecycle.commitApprovalInlineRestore(
                        &app.terminal,
                    ),
                }
            }
            if (result.is_committed() and presentation_commits_transcript) {
                restore_footer_prepare_state = false;
                presentation_shell.has_committed_frame = true;
                presentation_shell.terminal_reset_pending = false;
                if (footer_frame.paint.reset_terminal) {
                    app.shell.terminal_reset_pending = false;
                }
                if (transcript_transition == null) {
                    presentation_shell.committed_frame_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(committed_layout);
                    presentation_shell.invalidateTranscriptAnchor("empty_transcript_commit");
                }
                surface_frame.commitSurfaceFooterFrame(
                    app.alloc,
                    presentation_shell,
                    &footer_frame,
                    if (footer_measurement) |*measurement| measurement else null,
                );
                presentation_shell.shimmer_active = frame_ctx.activity_result.painted;
                presentation_shell.shimmer_row = if (frame_ctx.activity_result.painted) frame_ctx.activity_result.row else 1;
                presentation_shell.shimmer_is_overlay = frame_ctx.activity_result.overlay;
                if (scroll_plan.remaining_inline_advance_rows > 0) {
                    presentation_shell.markTranscriptDirty();
                } else if (!render_requests.hasReason(.transcript)) {
                    presentation_shell.transcript_band_dirty = false;
                }
                if (!render_requests.hasReason(.external_damage)) {
                    presentation_shell.footer_viewport.clearExternalInvalidation();
                }
            }
            if (result.is_committed() and child_view != null) {
                if (presentation_shell.resolvedTailViewport()) |viewport| {
                    app.subagents.commitChildPresentationViewport(
                        viewport.total_rows,
                        viewport.max_rows_from_bottom,
                        viewport.rows_from_bottom,
                    );
                }
            }
            return .{
                .shadow_state = result.state(),
                .animation_visible = frame_ctx.activity_result.painted,
                .yolo_warning_visible = !render_reconciliation.alternate_screen_owns_rendering and
                    footer_frame.composed.danger_status_visible,
            };
        }

        fn renderApprovalScreen(app: *App) !FrameAttemptResult {
            const approval = app.approval_prompt.projection() orelse return error.MissingApprovalRequest;
            const request = approval.request;
            const clear_display = approvalScreenNeedsClear(
                app.terminal.fileApprovalScreenActive(),
                request,
                app.shell.layout,
                app.approval_screen.screen_commit,
            );
            app.approval_screen.invalidateScreenCommit();
            app_lifecycle.enterApprovalScreen(
                &app.terminal,
                &app.shell,
                &app.metrics,
            ) catch |err| return failApprovalScreen(app, request.id, err);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or
                    grid.rows != app.shell.layout.rows)
                {
                    grid.resize(
                        app.shell.layout.cols,
                        app.shell.layout.rows,
                    ) catch |err| return failApprovalScreen(app, request.id, err);
                }
            }

            var screen = approval_screen.paint(
                app.alloc,
                approval,
                &app.approval_screen,
                app.shell.entries.items,
                app.shell.retainedTranscriptStyles(),
                app.shell.layout,
                clear_display,
            ) catch |err| return failApprovalScreen(app, request.id, err);
            defer screen.deinit(app.alloc);

            app_lifecycle.setApprovalScreenMouseTracking(
                &app.terminal,
                &app.shell,
                &app.metrics,
                request.file != null or screen.document_scrollable,
            ) catch |err| return failApprovalScreen(app, request.id, err);

            app_lifecycle.writeLifecycleTerminalBytes(
                &app.shell,
                &app.metrics,
                screen.bytes,
            ) catch |err| return failApprovalScreen(app, request.id, err);

            app.approval_screen.recordScreenCommit(request.id, .{
                .request_id = request.id,
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .file_identity_visible = screen.file_identity_visible,
                .all_decision_controls_visible = screen.all_decision_controls_visible,
                .changed_or_notice_visible = screen.changed_or_notice_visible,
                .document_scrollable = screen.document_scrollable,
            });
            app.shell.ui_observer.observeAlternateScreen(app.alloc, .{
                .request_id = request.id,
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .file_identity_visible = screen.file_identity_visible,
                .all_decision_controls_visible = screen.all_decision_controls_visible,
                .changed_or_notice_visible = screen.changed_or_notice_visible,
                .document_scrollable = screen.document_scrollable,
            });
            if (screen.needs_full_file_projection) {
                app.shell.render_requests.request(.modal);
            }
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderSkillsScreen(app: *App, ctx: render_input.RenderContext) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "skills")) {
                return error.MissingSkillsScreenRuntime;
            }

            const clear_display = !app.terminal.catalogMenuScreenActive();
            try app_lifecycle.enterCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try skills_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .skills = render_input.skillsMenuProjection(&app.skills),
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = ctx.pending_images,
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = clear_display,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, screen.bytes);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderModelsScreen(app: *App, ctx: render_input.RenderContext) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "model_cache")) {
                return error.MissingModelsScreenRuntime;
            }

            const clear_display = !app.terminal.catalogMenuScreenActive();
            try app_lifecycle.enterCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try models_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .models = ctx.model_menu,
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = ctx.pending_images,
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = clear_display,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, screen.bytes);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderChildModelsScreen(
            app: *App,
            ctx: render_input.RenderContext,
        ) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "model_cache")) {
                return error.MissingModelsScreenRuntime;
            }
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try models_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .models = ctx.model_menu,
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = &.{},
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = true,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, screen.bytes);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderChildSkillsScreen(
            app: *App,
            ctx: render_input.RenderContext,
        ) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "skills")) {
                return error.MissingSkillsScreenRuntime;
            }
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try skills_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .skills = render_input.skillsMenuProjection(&app.skills),
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = &.{},
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = true,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(
                &app.shell,
                &app.metrics,
                screen.bytes,
            );
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderResumeScreen(app: *App, ctx: render_input.RenderContext) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "session_persistence")) {
                return error.MissingResumeScreenRuntime;
            }

            const clear_display = !app.terminal.catalogMenuScreenActive();
            try app_lifecycle.enterCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try resume_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .sessions = ctx.session_menu,
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = ctx.pending_images,
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = clear_display,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, screen.bytes);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderHelpScreen(app: *App, ctx: render_input.RenderContext) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "input_runtime")) {
                return error.MissingHelpScreenRuntime;
            }

            const clear_display = !app.terminal.catalogMenuScreenActive();
            try app_lifecycle.enterCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try help_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .help = render_input.helpMenuProjection(
                    &app.input_runtime.help_menu,
                    app.slashRegistry(),
                    ctx.input.edit_state.input.items,
                ),
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = ctx.pending_images,
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = clear_display,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, screen.bytes);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderSettingsScreen(app: *App, ctx: render_input.RenderContext) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal") or !@hasField(App, "input_runtime")) {
                return error.MissingSettingsScreenRuntime;
            }

            const clear_display = !app.terminal.catalogMenuScreenActive();
            try app_lifecycle.enterCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    try grid.resize(app.shell.layout.cols, app.shell.layout.rows);
                }
            }

            var screen = try settings_screen.paint(app.alloc, .{
                .rows = app.shell.layout.rows,
                .cols = app.shell.layout.cols,
                .settings = blk: {
                    var projection = render_input.settingsMenuProjection(
                        &app.input_runtime.settings_menu,
                        app_commands.settingsCatalogSnapshot(app),
                        ctx.input.edit_state.input.items,
                    );
                    if (comptime @hasField(App, "model_cache")) {
                        projection.models = render_input.modelMenuProjection(&app.model_cache);
                    }
                    break :blk projection;
                },
                .composer = .{
                    .input = ctx.input.edit_state.input.items,
                    .cursor = ctx.input.edit_state.cursor,
                    .images = ctx.pending_images,
                    .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                    .image_tokens = ctx.input.entities.image_tokens.items,
                    .skill_tokens = ctx.input.entities.skill_tokens.items,
                    .appearance = if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                    .prefix_style = if (ctx.maxxing_mode == .minimal) .rail else .arrow,
                },
                .ctrl_c_pending = ctx.ctrl_c_pending,
                .clear_display = clear_display,
            });
            defer screen.deinit(app.alloc);
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, screen.bytes);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        fn renderSubagentManagerScreen(app: *App) !FrameAttemptResult {
            if (comptime !@hasField(App, "terminal")) return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
            if (comptime @hasDecl(
                @TypeOf(app.subagents),
                "activateManagerSurface",
            )) {
                app.subagents.activateManagerSurface();
            }
            app_lifecycle.enterSubagentManagerScreen(
                &app.terminal,
                &app.shell,
                &app.metrics,
            ) catch |err| return failSubagentManagerScreen(app, err);
            if (app.shell.shadow_vt) |grid| {
                if (grid.cols != app.shell.layout.cols or grid.rows != app.shell.layout.rows) {
                    grid.resize(app.shell.layout.cols, app.shell.layout.rows) catch |err|
                        return failSubagentManagerScreen(app, err);
                }
            }
            const main_approval = if (app.approval_prompt.projection()) |projection|
                projection.request
            else
                null;
            const bytes = app.subagents.panelText(
                app.alloc,
                app.shell.layout,
                main_approval,
            ) catch |err| return failSubagentManagerScreen(app, err);
            defer app.alloc.free(bytes);
            app_lifecycle.writeLifecycleTerminalBytes(
                &app.shell,
                &app.metrics,
                bytes,
            ) catch |err| return failSubagentManagerScreen(app, err);
            return .{ .shadow_state = .committed, .animation_visible = false };
        }

        fn failSubagentManagerScreen(app: *App, err: anyerror) !FrameAttemptResult {
            debug_trace.logf("subagent", "manager_screen_failed err={s}", .{@errorName(err)});
            if (comptime @hasField(App, "terminal")) {
                _ = app_lifecycle.leaveSubagentManagerScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                ) catch {};
            }
            app.subagents.close(app.alloc);
            app.shell.worker_status_state().set_api("Subagent manager unavailable", .danger);
            app.shell.render_requests.request(.footer);
            return .{ .shadow_state = .committed, .animation_visible = false };
        }

        fn failApprovalScreen(
            app: *App,
            request_id: u64,
            err: anyerror,
        ) !FrameAttemptResult {
            debug_trace.logf(
                "permission",
                "approval_screen_failed request_id={d} err={s}",
                .{ request_id, @errorName(err) },
            );
            _ = app_lifecycle.leaveApprovalScreen(
                &app.terminal,
                &app.shell,
                &app.metrics,
            ) catch |leave_err| {
                debug_trace.logf(
                    "permission",
                    "approval_screen_leave_failed reason=screen_failure err={s}",
                    .{@errorName(leave_err)},
                );
            };
            switch (app.worker.submitPermissionResponse(
                request_id,
                permission_request.OwnedPermissionResponse.init(app.alloc, .deny, null),
            )) {
                .accepted => {
                    app.approval_prompt.clearWithReason(app.alloc, "screen_failure");
                    app.approval_screen.clear();
                },
                .stale, .no_pending => {},
            }
            app.shell.render_requests.request(.modal);
            return .{
                .shadow_state = .committed,
                .animation_visible = false,
            };
        }

        pub noinline fn requestNormalViewportRecovery(app: *App) !void {
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.alternate_screen_owner != .none) return;
                try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
            }
        }

        fn skillsMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "skills")) return app.skills.menu.active;
            return false;
        }

        fn modelMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "model_cache")) return app.model_cache.menu.active;
            return false;
        }

        fn sessionMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "session_persistence")) return app.session_persistence.session_picker.active;
            return false;
        }

        fn helpMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.help_menu.active;
            return false;
        }

        fn settingsMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.settings_menu.active;
            return false;
        }

        fn catalogMenuActive(app: *const App) bool {
            return settingsMenuActive(app) or
                helpMenuActive(app) or
                skillsMenuActive(app) or
                modelMenuActive(app) or
                sessionMenuActive(app);
        }

        fn activityProjection(app: *const App) activity_runtime.ActivityProjection {
            return shell_runtime.activityProjection(&app.shell);
        }

        fn activeRenderRequests(app: *App) *render_request.RenderRequestState {
            if (comptime @hasField(App, "subagents")) {
                if (comptime @hasDecl(@TypeOf(app.subagents), "activeRenderRequests")) {
                    if (app.subagents.isViewActive()) {
                        return app.subagents.activeRenderRequests();
                    }
                }
            }
            return &app.shell.render_requests;
        }

        pub fn requestActiveSurfaceFrame(
            app: *App,
            reason: render_request.Reason,
        ) void {
            activeRenderRequests(app).request(reason);
        }

        pub noinline fn requestSubagentSurfaceFrame(
            app: *App,
            reason: render_request.Reason,
        ) void {
            requestActiveSurfaceFrame(app, reason);
        }

        pub fn toggleSubagentView(app: *App) !void {
            if (app.subagents.isViewActive()) {
                if (comptime @hasField(App, "terminal")) {
                    try app_lifecycle.leaveSubagentManagerScreen(
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    );
                }
                app.subagents.close(app.alloc);
                if (comptime @hasField(App, "terminal")) {
                    try requestNormalViewportRecovery(app);
                } else {
                    app.shell.render_requests.request(.footer);
                }
                if (comptime @hasDecl(App, "loopCommitFrame")) {
                    try App.loopCommitFrame(app);
                }
                return;
            }
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fileApprovalScreenActive()) {
                    try app_lifecycle.handoffApprovalToSubagentManager(
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    );
                }
                if (app.terminal.catalogMenuScreenActive() and
                    !catalogMenuActive(app))
                {
                    try app_lifecycle.handoffCatalogMenuToSubagentManager(
                        &app.terminal,
                    );
                }
                app_lifecycle.enterSubagentManagerScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                ) catch |err| {
                    if (err == error.AlternateScreenAlreadyOwned) {
                        app.shell.worker_status_state().set_api("Close the current full-screen view before opening Subagent manager", .danger);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    return err;
                };
            }
            if (comptime @hasDecl(@TypeOf(app.subagents), "setDefaults") and
                @hasField(App, "selected_model") and @hasField(App, "effort"))
            {
                try app.subagents.setDefaults(
                    app.alloc,
                    app.selected_model.items,
                    app.effort,
                );
            }
            app.subagents.open(app.alloc);
            errdefer {
                var left_screen = true;
                if (comptime @hasField(App, "terminal")) {
                    app_lifecycle.leaveSubagentManagerScreen(
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    ) catch {
                        left_screen = false;
                    };
                }
                if (left_screen) app.subagents.close(app.alloc);
            }
            try refreshSubagentManager(app, true);
            requestSubagentSurfaceFrame(app, .subagent_panel);
        }

        pub fn refreshSubagentManager(app: *App, force: bool) !void {
            try refreshSubagentManagerProjection(app, force, false);
        }

        pub fn refreshSubagentManagerAfterSessionInstall(app: *App) !void {
            try refreshSubagentManagerProjection(app, true, true);
        }

        fn refreshSubagentManagerProjection(
            app: *App,
            force: bool,
            comptime count_only: bool,
        ) !void {
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                app.subagents.setDegraded(app.alloc, .store_failure);
                requestSubagentSurfaceFrame(app, .subagent_panel);
                return;
            };
            const now_ms = io_mod.milliTimestamp();
            const refresh_due = if (comptime @hasDecl(
                @TypeOf(app.subagents),
                "projectionRefreshDue",
            ))
                app.subagents.projectionRefreshDue(
                    now_ms,
                    force,
                    host.approvals.pendingRevision(),
                )
            else
                app.subagents.refreshDue(io_mod.milliTimestamp(), force);
            if (!refresh_due) return;
            const source = subagent_projection.Source{
                .root_id = host.root_id,
                .manager = &host.manager,
                .sessions = host.sessions,
                .owner = &host.owner,
                .approval_registry = if (count_only) null else &host.approvals,
                .pending_approval_offset = if (comptime @hasDecl(
                    @TypeOf(app.subagents),
                    "pendingApprovalOffset",
                ))
                    app.subagents.pendingApprovalOffset()
                else
                    0,
            };
            var loaded = if (comptime @hasDecl(@TypeOf(app.subagents), "pageCursor"))
                try subagent_projection.loadPage(
                    app.alloc,
                    source,
                    app.subagents.pageCursor(),
                    app.subagents.pageAnchorId(),
                )
            else
                try subagent_projection.load(app.alloc, source);
            switch (loaded) {
                .snapshot => |snapshot| {
                    loaded = undefined;
                    if (comptime count_only) {
                        var count: usize = 0;
                        for (snapshot.nodes) |node| {
                            if (node.state != .archived) count += 1;
                        }
                        var projection = snapshot;
                        defer projection.deinit(app.alloc);
                        app.subagents.setCountProjection(count);
                        return;
                    }
                    const changed = try app.subagents.replaceSnapshot(app.alloc, snapshot);
                    if (changed) {
                        requestSubagentSurfaceFrame(app, .subagent_panel);
                    }
                    if (app.subagents.childRouteId() != null) {
                        if (changed) {
                            try refreshChildChat(app, null, false, false);
                        } else {
                            try refreshChildLive(app);
                        }
                    }
                },
                .degraded => |failure| {
                    if (comptime count_only) {
                        app.subagents.setCountProjection(0);
                        return;
                    }
                    app.subagents.setDegraded(app.alloc, failure);
                    requestSubagentSurfaceFrame(app, .subagent_panel);
                },
            }
            if (comptime @hasField(App, "terminal_client") and
                @hasDecl(@TypeOf(app.terminal_client), "terminalProjection") and
                @hasDecl(@TypeOf(app.subagents), "replaceTerminalSnapshot"))
            {
                const terminal_snapshot = try app.terminal_client.terminalProjection(app.alloc);
                if (try app.subagents.replaceTerminalSnapshot(app.alloc, terminal_snapshot)) {
                    requestSubagentSurfaceFrame(app, .subagent_panel);
                }
            }
        }

        pub fn refreshChildChat(
            app: *App,
            cursor: ?[]const u8,
            older_page: bool,
            reset_pages: bool,
        ) !void {
            const child_id = app.subagents.childRouteId() orelse return;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                app.subagents.setChildUnavailable(app.alloc, .store_failure);
                return;
            };
            const source = subagent_projection.Source{
                .root_id = host.root_id,
                .manager = &host.manager,
                .sessions = host.sessions,
                .owner = &host.owner,
            };
            var loaded = try subagent_projection.loadChildChat(
                app.alloc,
                source,
                child_id,
                cursor,
            );
            switch (loaded) {
                .chat => |chat| {
                    loaded = undefined;
                    try app.subagents.installChildChat(
                        app.alloc,
                        chat,
                        older_page,
                        reset_pages,
                    );
                },
                .stale_cursor => {
                    loaded = undefined;
                    var refreshed = try subagent_projection.loadChildChat(
                        app.alloc,
                        source,
                        child_id,
                        null,
                    );
                    switch (refreshed) {
                        .chat => |chat| {
                            refreshed = undefined;
                            try app.subagents.installChildChat(
                                app.alloc,
                                chat,
                                false,
                                true,
                            );
                        },
                        .unavailable => |reason| {
                            refreshed = undefined;
                            app.subagents.setChildUnavailable(app.alloc, reason);
                        },
                        .stale_cursor => unreachable,
                    }
                },
                .unavailable => |reason| {
                    loaded = undefined;
                    app.subagents.setChildUnavailable(app.alloc, reason);
                },
            }
            requestSubagentSurfaceFrame(app, .subagent_panel);
        }

        fn refreshChildLive(app: *App) !void {
            const child_id = app.subagents.childRouteId() orelse return;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return;
            const live = try host.owner.snapshotLivePresentation(app.alloc, child_id);
            if (app.subagents.replaceChildLive(app.alloc, live)) {
                requestSubagentSurfaceFrame(app, .subagent_panel);
            }
        }

        pub fn submitChildMessage(app: *App) !void {
            const submission = try app.subagents.prepareSubmission(
                app.alloc,
                io_mod.milliTimestamp(),
            ) orelse return;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                app.subagents.submissionRejected(app.alloc, .{
                    .code = .store_failure,
                    .retryable = true,
                });
                return;
            };
            const identity_epoch = if (submission.identity_epoch != 0)
                submission.identity_epoch
            else
                host.issueOperationIdentity(
                    app.alloc,
                    submission.invocation_id,
                    .human,
                ) catch {
                    app.subagents.submissionRejected(app.alloc, .{
                        .code = .store_failure,
                        .retryable = true,
                    });
                    return;
                };
            if (!app.subagents.assignSubmissionIdentity(
                submission.invocation_id,
                identity_epoch,
            )) {
                host.abortOperationIdentity(
                    submission.invocation_id,
                    .human,
                    identity_epoch,
                ) catch {
                    app.subagents.submissionRejected(app.alloc, .{
                        .code = .control_commit_indeterminate,
                        .retryable = true,
                    });
                    return;
                };
                app.subagents.submissionRejected(app.alloc, .{
                    .code = .store_failure,
                });
                return;
            }
            var route: ?route_snapshot.RouteSnapshot = if (comptime @hasDecl(
                App,
                "admitSubagentWorkRoute",
            ))
                app.admitSubagentWorkRoute(app.alloc) catch {
                    app.subagents.submissionRejected(app.alloc, .{
                        .code = .store_failure,
                        .retryable = true,
                    });
                    return;
                }
            else
                null;
            defer if (route) |*owned| owned.deinit(app.alloc);
            var result = host.sendMessage(app.alloc, .{
                .caller_id = host.root_id,
                .invocation_id = submission.invocation_id,
                .child_id = submission.child_id,
                .content = submission.content,
                .route = if (route) |*owned| owned else null,
                .timestamp_ms = io_mod.milliTimestamp(),
                .identity_epoch = identity_epoch,
            }) catch {
                app.subagents.submissionRejected(app.alloc, .{
                    .code = .store_failure,
                    .retryable = true,
                });
                return;
            };
            defer result.deinit(app.alloc);
            switch (result) {
                .receipt => {
                    app.subagents.submissionAccepted(app.alloc);
                    try refreshSubagentManager(app, true);
                    try refreshChildChat(app, null, false, false);
                },
                .failure => |failure| app.subagents.submissionRejected(
                    app.alloc,
                    failure,
                ),
                .inspection => unreachable,
            }
        }

        pub fn loadSubagentAttachCandidates(app: *App, append: bool) !void {
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                app.subagents.setAttachLoadFailure();
                return;
            };
            const continuation = if (append) app.subagents.attachContinuation() else null;
            var page = subagent_projection.loadAttachPage(
                app.alloc,
                .{
                    .root_id = host.root_id,
                    .manager = &host.manager,
                    .sessions = host.sessions,
                    .owner = &host.owner,
                },
                continuation,
            ) catch {
                app.subagents.setAttachLoadFailure();
                return;
            };
            errdefer page.deinit(app.alloc);
            app.subagents.installAttachPage(app.alloc, page, append) catch {
                app.subagents.setAttachLoadFailure();
                return;
            };
            page = undefined;
        }

        pub fn submitSubagentManagerMutation(app: *App) !void {
            var mutation = app.subagents.prepareManagerMutation(
                app.alloc,
                io_mod.milliTimestamp(),
            ) catch {
                app.subagents.mutationRejected(app.alloc, .{
                    .code = .store_failure,
                    .retryable = true,
                });
                return;
            } orelse return;
            defer mutation.deinit(app.alloc);
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                app.subagents.mutationRejected(app.alloc, .{
                    .code = .store_failure,
                    .retryable = true,
                });
                return;
            };
            if (comptime !@hasField(App, "session") or
                !@hasField(App, "selected_model") or !@hasField(App, "effort"))
            {
                app.subagents.mutationRejected(app.alloc, .{
                    .code = .store_failure,
                    .retryable = true,
                });
                return;
            }
            const identity_epoch = if (mutation.identity_epoch != 0)
                mutation.identity_epoch
            else
                host.issueOperationIdentity(
                    app.alloc,
                    mutation.invocation_id,
                    .human,
                ) catch {
                    app.subagents.mutationRejected(app.alloc, .{
                        .code = .store_failure,
                        .retryable = true,
                    });
                    return;
                };
            if (!app.subagents.assignMutationIdentity(
                mutation.invocation_id,
                identity_epoch,
            )) {
                host.abortOperationIdentity(
                    mutation.invocation_id,
                    .human,
                    identity_epoch,
                ) catch {
                    app.subagents.mutationRejected(app.alloc, .{
                        .code = .control_commit_indeterminate,
                        .retryable = true,
                    });
                    return;
                };
                app.subagents.mutationRejected(app.alloc, .{
                    .code = .store_failure,
                });
                return;
            }
            const publishes_work = switch (mutation.command) {
                .create => |create| create.prompt != null,
                .message => |message| message == .send,
                .inspect, .relationship, .configure, .lifecycle => false,
            };
            var route: ?route_snapshot.RouteSnapshot = if (publishes_work and
                comptime @hasDecl(App, "admitSubagentWorkRoute"))
                app.admitSubagentWorkRoute(app.alloc) catch {
                    app.subagents.mutationRejected(app.alloc, .{
                        .code = .store_failure,
                        .retryable = true,
                    });
                    return;
                }
            else
                null;
            defer if (route) |*owned| owned.deinit(app.alloc);
            var result = host.executeHumanCommand(app.alloc, &mutation.command, .{
                .invocation_id = mutation.invocation_id,
                .defaults = .{
                    .model = app.selected_model.items,
                    .route = if (route) |*owned| owned else null,
                    .effort = app.effort,
                    .fast_mode = if (comptime @hasField(App, "fast_mode")) app.fast_mode else false,
                    .conversation_language = app.session.languageSnapshot(),
                },
                .expected_generation = mutation.expected_generation,
                .identity_epoch = identity_epoch,
                .timestamp_ms = io_mod.milliTimestamp(),
            }) catch {
                app.subagents.mutationRejected(app.alloc, .{
                    .code = .store_failure,
                    .retryable = true,
                });
                return;
            };
            defer result.deinit(app.alloc);
            switch (result) {
                .receipt => |receipt| {
                    _ = try app.subagents.mutationAccepted(app.alloc, receipt);
                    try refreshSubagentManager(app, true);
                    if (app.subagents.childRouteId() != null) {
                        try refreshChildChat(app, null, false, true);
                    }
                },
                .failure => |failure| {
                    app.subagents.mutationRejected(app.alloc, failure);
                    if (failure.code == .stale_generation or
                        failure.code == .operation_conflict or
                        failure.code == .graph_changed)
                    {
                        try refreshSubagentManager(app, true);
                        if (app.subagents.isAttachRouteActive()) {
                            try loadSubagentAttachCandidates(app, false);
                        }
                    }
                },
                .inspection => unreachable,
            }
        }

        pub fn resolveSubagentApproval(app: *App) !void {
            const submission = app.subagents.prepareApprovalResolution() orelse return;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                try app.subagents.approvalRejected(app.alloc, false);
                return;
            };
            const resolved = host.resolveApproval(.{
                .request_id = submission.request_id,
                .child_id = submission.child_id,
                .decision = submission.decision,
                .timestamp_ms = io_mod.milliTimestamp(),
            }) catch |err| {
                try app.subagents.approvalRejected(
                    app.alloc,
                    err == error.RequestNotFound or err == error.StaleRequest or err == error.WrongChild,
                );
                try refreshSubagentManager(app, true);
                return;
            };
            if (resolved == .accepted) {
                app.subagents.approvalAccepted(app.alloc);
            } else {
                try app.subagents.approvalRejected(app.alloc, true);
            }
            try refreshSubagentManager(app, true);
        }

        pub fn acknowledgeSubagentManagerSelection(app: *App) !void {
            const acknowledgement = app.subagents.acknowledgement() orelse return;
            persistSubagentAcknowledgement(
                app,
                acknowledgement.child_id,
                acknowledgement.through_sequence,
            );
            app.subagents.acknowledgementAttempted(
                app.alloc,
                acknowledgement,
            );
            try refreshSubagentManager(app, true);
        }

        pub fn acknowledgeVisibleSubagentChildBeforeClose(app: *App) void {
            const acknowledgement = app.subagents.visibleChildAcknowledgement() orelse return;
            persistSubagentAcknowledgement(
                app,
                acknowledgement.child_id,
                acknowledgement.through_sequence,
            );
        }

        fn persistSubagentAcknowledgement(
            app: *App,
            child_id: []const u8,
            through_sequence: u64,
        ) void {
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return;
            subagent_projection.acknowledge(
                app.alloc,
                .{
                    .root_id = host.root_id,
                    .manager = &host.manager,
                    .sessions = host.sessions,
                    .owner = &host.owner,
                },
                child_id,
                through_sequence,
            ) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "manager_acknowledge_failed child_id={s} sequence={d} err={s}",
                    .{ child_id, through_sequence, @errorName(err) },
                );
            };
        }

        pub fn eventLoopCallbacks(app: *App) event_loop.EventLoopCallbacks {
            return .{
                .ctx = @ptrCast(app),
                .collect_facts = App.loopCollectFacts,
                .next_collected_byte = App.loopNextCollectedByte,
                .handle_byte = App.loopHandleByte,
                .settle_delivery_epoch = App.loopSettleInputDeliveryEpoch,
                .commit_frame = App.loopCommitFrame,
                .poll_timeout_ms = if (comptime @hasDecl(App, "loopPollTimeoutMs")) App.loopPollTimeoutMs else null,
            };
        }
    };
}

fn renderReasonNames(
    reasons: render_request.ReasonSet,
    buf: *[128]u8,
) []const u8 {
    var len: usize = 0;
    for (std.meta.tags(render_request.Reason)) |reason| {
        if (!reasons.contains(reason)) continue;
        if (len > 0) {
            if (len == buf.len) break;
            buf[len] = ',';
            len += 1;
        }
        const name = @tagName(reason);
        const copy_len = @min(name.len, buf.len - len);
        @memcpy(buf[len..][0..copy_len], name[0..copy_len]);
        len += copy_len;
        if (copy_len < name.len) break;
    }
    if (len == 0) return "none";
    return buf[0..len];
}

fn FixedPointTranscriptContext(comptime App: type) type {
    return struct {
        app: *App,
        presentation_shell: *transcript_runtime.TranscriptRuntime,
        prepare_transcript: bool,
        source: ?*const transcript_runtime.TranscriptPreparationSource,
        prepared_transcript: *?transcript_painter.PreparedTranscriptSurfacePaint,
        resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
        footer_reservation_changed: bool,
        replay_displaced_footer_history: bool,
        footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
        fallback_footer_rows: ?render_engine.footer_layout.FooterRows,
        activity_projection: activity_runtime.ActivityProjection,
        frame_activity: render_engine.frame_layout.ActivityState,
        base_invalidation: render_engine.paint_plan.FrameInvalidationSet,
        attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
        scroll_facts: ?transcript_runtime.TranscriptScrollFacts = null,

        fn prepareCandidate(
            self: *@This(),
            candidate: render_engine.frame_layout.FrameLayout,
        ) !render_engine.frame_fixed_point.CandidatePreparation {
            if (self.prepared_transcript.*) |*prepared| {
                prepared.deinit(self.app.alloc);
                self.prepared_transcript.* = null;
            }
            self.resolved_target.* = null;
            self.scroll_facts = null;
            if (!self.prepare_transcript or candidate.transcript_area.isEmpty()) return .{
                .inline_advance_rows = 0,
                .occupied_transcript_rows = candidate.transcript_area.height(),
            };
            const source = self.source orelse return error.MissingTranscriptPreparationSource;

            self.prepared_transcript.* = try self.presentation_shell.prepareTranscriptSurfacePaintFromSourceForFrame(
                self.app.alloc,
                &self.app.metrics,
                source,
                candidate.transcript_area,
                self.footer_reservation_changed,
            );
            const prepared = &self.prepared_transcript.*.?;
            const scroll_facts = try self.presentation_shell.prepareTranscriptScrollFactsForFrame(
                self.app.alloc,
                source,
                prepared,
                self.footer_reservation_changed,
                self.replay_displaced_footer_history,
            );
            self.scroll_facts = scroll_facts;
            const occupied_transcript_rows = if (prepared.selection.last_visible_row >= candidate.transcript_area.top)
                prepared.selection.last_visible_row - candidate.transcript_area.top + 1
            else
                0;
            return .{
                .inline_advance_rows = scroll_facts.planned_rows,
                .occupied_transcript_rows = occupied_transcript_rows,
            };
        }

        fn resolveCandidate(
            self: *@This(),
            candidate: render_engine.frame_layout.FrameLayout,
            scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        ) !render_engine.frame_fixed_point.CandidateResolution {
            const candidate_rows = candidate.transcript_area.height();
            if (!self.prepare_transcript or candidate.transcript_area.isEmpty()) {
                return .{ .occupied_transcript_rows = candidate_rows };
            }
            const source = self.source orelse return error.MissingTranscriptPreparationSource;
            const prepared = if (self.prepared_transcript.*) |*value| value else return error.MissingTranscriptPaint;
            const scroll_facts = self.scroll_facts orelse return error.MissingTranscriptScrollFacts;
            const footer_rows = if (self.footer_measurement) |measurement|
                measurement.frameLayoutRows(
                    self.presentation_shell.layout.rows,
                    candidate.footer_area.top,
                )
            else
                self.fallback_footer_rows orelse return error.MissingFooterRows;
            const activity = render_engine.activity_placement.resolve(
                self.activity_projection,
                self.frame_activity,
                candidate,
            );
            var candidate_plan = candidate.toPaintPlan(.{
                .footer_rows = footer_rows,
                .viewport = prepared.selection,
                .activity = activity,
                .invalidation = self.base_invalidation,
                .cursor_target = .{
                    .row = prepared.cursor.cursor_row,
                    .col = prepared.cursor.cursor_col,
                    .visible = true,
                },
            });
            candidate_plan.invalidation = try surface_invalidation.resolveCandidateFrameInvalidations(
                self.presentation_shell,
                candidate_plan,
                if (self.footer_measurement) |measurement|
                    measurement.frameInvalidationUpdate()
                else
                    null,
                self.attempt_invalidations,
            );
            const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
                self.presentation_shell.committed_frame_layout.transcript_area,
                candidate_plan.invalidation,
            );
            const target = try self.presentation_shell.resolveTranscriptTransitionTargetForFrame(
                self.app.alloc,
                source,
                prepared,
                render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(candidate),
                scroll_plan,
                scroll_facts,
                destructive_invalidation,
                activity == .overlay_entry,
            );
            self.resolved_target.* = target;
            return .{ .occupied_transcript_rows = target.occupiedTranscriptRows() };
        }
    };
}

fn FramePaintContext(comptime App: type) type {
    return struct {
        app: *App,
        presentation_shell: *transcript_runtime.TranscriptRuntime,
        body: render_engine.frame_builder.FrameBody,
        prepared_transcript: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
        footer_frame: *const surface_frame.SurfaceFooterFrame,
        activity_style: shimmer_runtime.ActivityPaintStyle,
        activity_result: render_engine.paint_plan.ActivityPaintResult,

        fn paintBody(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (self.body) {
                .transcript => {
                    if (surface.plan.transcript_band.isEmpty()) return;
                    if (self.prepared_transcript) |prepared| {
                        _ = try self.presentation_shell.paintPreparedTranscriptIntoSurface(self.app.alloc, surface, prepared);
                    }
                },
                .subagent_panel => |text| {
                    if (surface.plan.transcript_band.isEmpty() or text.len == 0) return;
                    const rows = surface.plan.transcript_band.bottom - surface.plan.transcript_band.top + 1;
                    _ = try surface.writeAnsiBand(surface.plan.transcript_band.top, rows, text, .transcript, .same_owner);
                },
                .none => {},
            }
        }

        fn paintFooter(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = try footer_viewport.paintFooterIntoSurface(surface, &self.footer_frame.composed);
        }

        fn paintActivity(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.activity_result = try shimmer_runtime.paintActivityIntoSurface(surface, .{
                .label = self.footer_frame.label(),
                .tool_label = self.footer_frame.toolLabel(),
                .shimmer_pos = self.footer_frame.shimmer_pos,
                .style = self.activity_style,
                .thinking_blink = self.footer_frame.thinking_blink,
            });
        }
    };
}

fn validatePreparedTranscriptFitsPlan(
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    plan: render_engine.paint_plan.PaintPlan,
) !void {
    const selection = prepared.selection;
    const has_prepared_rows = prepared.total_lines > 0 or selection.last_visible_row > 0;
    if (!has_prepared_rows) return;

    if (plan.transcript_band.isEmpty() or
        selection.top_row < plan.transcript_band.top or
        selection.bottom_row > plan.transcript_band.bottom or
        selection.last_visible_row > plan.transcript_band.bottom)
    {
        debug_trace.logf(
            "frame_plan",
            "prepared_transcript_outside_band selection={d}..{d} last_visible={d} transcript_band={d}..{d} total_lines={d}",
            .{
                selection.top_row,
                selection.bottom_row,
                selection.last_visible_row,
                plan.transcript_band.top,
                plan.transcript_band.bottom,
                prepared.total_lines,
            },
        );
        return error.InvalidPaintPlan;
    }
}

fn footerMeasurementFromRows(rows: render_engine.footer_layout.FooterRows) render_engine.frame_layout.FooterMeasurement {
    return .{
        .natural_rows = rows.total_rows,
        .min_rows = 1,
        .max_rows = rows.total_rows,
        .input_rows = 1,
        .picker_rows = if (rows.picker_start <= rows.bottom_divider and rows.bottom_divider > rows.picker_divider)
            rows.bottom_divider - rows.picker_divider - 1
        else
            0,
        .banner_rows = rows.banner_rows,
    };
}

fn activityStateFromPlacement(activity: render_engine.activity_overlay.ActivityPlacement) render_engine.frame_layout.ActivityState {
    return switch (activity) {
        .transient_row => |transient| .{ .thinking = .{
            .gap_above_activity = transient.gap_above_rows,
            .activity_rows = transient.row_count,
            .footer_gap_after_activity = transient.footer_clearance_rows,
            .tool_before_activity = transient.tool_row != null,
        } },
        .overlay_entry => |row| .{ .overlay_entry = row },
        .none => .none,
    };
}

noinline fn frameActivityStateFromMeasurement(
    shell: *const transcript_runtime.TranscriptRuntime,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
) render_engine.frame_layout.ActivityState {
    return switch (measurement.activity_projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            transientActivityState(shell, measurement.activity_projection, slot.thinking_label != null)
        else
            .none,
        .turn_thinking => transientActivityState(shell, measurement.activity_projection, false),
    };
}

fn transientActivityState(
    shell: *const transcript_runtime.TranscriptRuntime,
    projection: activity_runtime.ActivityProjection,
    tool_before_activity: bool,
) render_engine.frame_layout.ActivityState {
    return .{ .thinking = .{
        .gap_above_activity = render_input.transientActivityGapRows(shell, tool_before_activity),
        .activity_rows = render_input.activityProjectionRows(projection, shell.layout.cols),
        .footer_gap_after_activity = render_engine.transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary),
        .tool_before_activity = tool_before_activity,
    } };
}

fn framePlanBandsEqual(
    old: render_engine.paint_plan.PaintPlan,
    solved: render_engine.paint_plan.PaintPlan,
) bool {
    return frameBandsEqual(old.transcript_band, solved.transcript_band) and
        frameBandsEqual(old.blank_band, solved.blank_band) and
        frameBandsEqual(old.activity_band, solved.activity_band) and
        frameBandsEqual(old.footer_gap_band, solved.footer_gap_band) and
        frameBandsEqual(old.footer_band, solved.footer_band);
}

noinline fn frameBandsEqual(
    a: render_engine.paint_plan.FrameBand,
    b: render_engine.paint_plan.FrameBand,
) bool {
    return a.top == b.top and a.bottom == b.bottom and a.owner == b.owner;
}

const FixedPointTestContext = struct {
    inline_advance_rows: u16 = 0,
    prepared_occupied_rows: ?u16 = null,

    fn prepareCandidate(
        self: *FixedPointTestContext,
        layout: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        return .{
            .inline_advance_rows = self.inline_advance_rows,
            .occupied_transcript_rows = layout.transcript_area.height(),
        };
    }

    fn resolveCandidate(
        self: *FixedPointTestContext,
        layout: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        _ = scroll_plan;
        return .{
            .occupied_transcript_rows = self.prepared_occupied_rows orelse layout.transcript_area.height(),
        };
    }
};

fn fixedPointTestInput(
    terminal_rows: u16,
    owned_top: u16,
    transcript_rows: u16,
    footer_rows: u16,
    body_mode: render_engine.frame_layout.BodyMode,
) render_engine.frame_layout.SolveInput {
    return .{
        .terminal = .{
            .rows = terminal_rows,
            .cols = 80,
            .content_bottom = terminal_rows -| 4,
            .divider_top_row = terminal_rows -| 3,
            .input_row = terminal_rows -| 2,
            .divider_bottom_row = terminal_rows -| 1,
            .hint_row = terminal_rows,
        },
        .owned_top = owned_top,
        .footer = .{
            .natural_rows = footer_rows,
            .min_rows = footer_rows,
            .max_rows = footer_rows,
        },
        .transcript = .{ .natural_visual_rows = transcript_rows },
        .body_mode = body_mode,
    };
}

fn solveFixedPointForTest(
    ctx: *FixedPointTestContext,
    input: render_engine.frame_layout.SolveInput,
) !render_engine.frame_fixed_point.FramePlan {
    return render_engine.frame_fixed_point.solve(
        FixedPointTestContext,
        ctx,
        input,
        FixedPointTestContext.prepareCandidate,
        FixedPointTestContext.resolveCandidate,
    );
}

test "assistant tail writability changes remain traceable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "assistant-tail.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "scroll");

    var runtime = transcript_runtime.TranscriptRuntime{};
    set_transcript_assistant_tail_writable(&runtime, false);
    set_transcript_assistant_tail_writable(&runtime, true);
    debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "assistant tail writability changed writable=false",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "assistant tail writability changed writable=true",
    ) != null);
}

test "core.app_render_runtime makes selected child display names terminal safe" {
    const cases = [_]struct {
        raw: []const u8,
        visible: []const u8,
    }{
        .{ .raw = "line\nbreak", .visible = "line\\x0abreak" },
        .{ .raw = "return\rrewrite", .visible = "return\\x0drewrite" },
        .{ .raw = "red\x1b[31mchild\x1b[0m", .visible = "red\\x1b[31mchild\\x1b[0m" },
        .{ .raw = "c1-\u{0080}", .visible = "c1-\\u{0080}" },
        .{ .raw = "δοκιμή-🦎-é", .visible = "δοκιμή-🦎-é" },
    };

    for (cases) |case| {
        var display_name = try encodeSelectedChildDisplayName(
            std.testing.allocator,
            case.raw,
        );
        defer display_name.deinit(std.testing.allocator);

        try std.testing.expectEqualStrings(case.visible, display_name.bytes);
        try std.testing.expect(!display_name.truncated);
        if (!std.mem.eql(u8, case.raw, case.visible)) {
            try std.testing.expect(std.mem.find(u8, display_name.bytes, case.raw) == null);
        }
    }
}

test "core.app_render_runtime fixed point retry resumes after acknowledged release" {
    var first_ctx = FixedPointTestContext{ .inline_advance_rows = 3 };
    const first = try solveFixedPointForTest(&first_ctx, fixedPointTestInput(12, 5, 1, 3, .transcript));
    var shell = transcript_runtime.TranscriptRuntime{
        .layout = fixedPointTestInput(12, 5, 1, 3, .transcript).terminal,
        .owned_top_row = 5,
        .viewport_top_row = 5,
    };
    defer shell.deinit(std.testing.allocator);
    try shell.ackPreservedRowRelease(first.scroll_plan, first.scroll_plan.terminal_scroll_rows);

    var retry_ctx = FixedPointTestContext{};
    const retry = try solveFixedPointForTest(&retry_ctx, fixedPointTestInput(12, shell.owned_top_row, 1, 3, .transcript));

    try std.testing.expectEqual(@as(u16, 1), shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 0), retry.scroll_plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 0), retry.scroll_plan.terminal_scroll_rows);
}

test "core.app_render_runtime fixed point shrink acknowledgment resumes from normalized ownership" {
    var first_ctx = FixedPointTestContext{};
    const first = try solveFixedPointForTest(&first_ctx, fixedPointTestInput(5, 9, 0, 5, .transcript));
    var shell = transcript_runtime.TranscriptRuntime{
        .layout = fixedPointTestInput(5, 9, 0, 5, .transcript).terminal,
        .owned_top_row = 9,
        .viewport_top_row = 9,
    };
    defer shell.deinit(std.testing.allocator);
    try shell.ackPreservedRowRelease(first.scroll_plan, 2);

    var retry_ctx = FixedPointTestContext{};
    const retry = try solveFixedPointForTest(&retry_ctx, fixedPointTestInput(5, shell.owned_top_row, 0, 5, .transcript));

    try std.testing.expectEqual(@as(u16, 3), shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 2), retry.scroll_plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 1), retry.scroll_plan.post_scroll_owned_top);
}

test "core.app_render_runtime gives all transient activity the turn-summary footer gap" {
    var shell = transcript_runtime.TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);

    const inactive = surface_frame.SurfaceFooterMeasurement{};
    try std.testing.expectEqual(render_engine.frame_layout.ActivityState.none, frameActivityStateFromMeasurement(&shell, &inactive));

    const active = surface_frame.SurfaceFooterMeasurement{
        .activity_projection = .{ .turn_thinking = .{
            .label = "thinking",
        } },
    };
    switch (frameActivityStateFromMeasurement(&shell, &active)) {
        .thinking => |thinking| try std.testing.expectEqual(@as(u16, 1), thinking.footer_gap_after_activity),
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }

    const active_tool = surface_frame.SurfaceFooterMeasurement{
        .activity_projection = .{ .tool_slot = .{
            .entry_id = 9,
            .fallback_label = "Running",
            .active = true,
            .kind = .read,
        } },
    };
    switch (frameActivityStateFromMeasurement(&shell, &active_tool)) {
        .thinking => |thinking| try std.testing.expectEqual(@as(u16, 1), thinking.footer_gap_after_activity),
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }
}

test "core.app_render_runtime connects minimal focused tools to the transcript block" {
    var shell = transcript_runtime.TranscriptRuntime{ .maxxing_mode = .minimal };
    defer shell.deinit(std.testing.allocator);

    const active_tool = surface_frame.SurfaceFooterMeasurement{
        .activity_projection = .{ .tool_slot = .{
            .entry_id = 9,
            .fallback_label = "Running zig build",
            .thinking_label = "Thinking",
            .active = true,
            .kind = .command,
        } },
    };

    switch (frameActivityStateFromMeasurement(&shell, &active_tool)) {
        .thinking => |thinking| {
            try std.testing.expectEqual(@as(u16, 0), thinking.gap_above_activity);
            try std.testing.expect(thinking.tool_before_activity);
        },
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }
}

test "core.app_render_runtime rejects prepared transcript outside final plan band" {
    const plan = render_engine.paint_plan.PaintPlan{
        .layout = .{
            .rows = 45,
            .cols = 168,
            .content_bottom = 41,
            .divider_top_row = 42,
            .input_row = 43,
            .divider_bottom_row = 44,
            .hint_row = 45,
        },
        .viewport = .{
            .top_row = 1,
            .bottom_row = 39,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 40,
            .last_visible_row = 39,
        },
        .footer = .{
            .top = 42,
            .top_divider = 42,
            .banner = 42,
            .banner_active = false,
            .input_base = 43,
            .picker_divider = 44,
            .picker_start = 45,
            .bottom_divider = 44,
            .hint = 45,
            .total_rows = 4,
        },
        .activity = .{ .transient_row = .{ .row = 41, .gap_above_rows = 1 } },
        .preserved_band = render_engine.paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 1, .bottom = 39, .owner = .transcript },
        .activity_band = .{ .top = 41, .bottom = 41, .owner = .activity },
        .footer_band = .{ .top = 42, .bottom = 45, .owner = .footer },
        .invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 43, .col = 3, .visible = true },
        .footer_reservation_source = .transient_activity,
        .bottom_reserved_rows = 2,
        .preserve_scrollback = true,
    };
    const prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .selection = .{
            .top_row = 1,
            .bottom_row = 41,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 40,
            .last_visible_row = 41,
        },
    };

    try std.testing.expectError(error.InvalidPaintPlan, validatePreparedTranscriptFitsPlan(&prepared, plan));
}

noinline fn shouldResetPhysicalTerminal(
    child_view_active: bool,
    main_reset_pending: bool,
) bool {
    return !child_view_active and main_reset_pending;
}

test "core.app_render_runtime child presentation cannot reset primary scrollback" {
    try std.testing.expect(!shouldResetPhysicalTerminal(true, true));
    try std.testing.expect(!shouldResetPhysicalTerminal(true, false));
    try std.testing.expect(!shouldResetPhysicalTerminal(false, false));
    try std.testing.expect(shouldResetPhysicalTerminal(false, true));
}

const CoordinatorFault = enum {
    committed,
    preparation_error,
    input_pending,
    terminal_partial_write,
    shadow_feed_failed,
};

const BufferedInputCheckpointTestApp = struct {
    const PollState = struct {
        readable: bool = false,

        fn closed(_: PollState) bool {
            return false;
        }
    };

    const Terminal = struct {
        fn pollInput(_: *Terminal, _: i32) !PollState {
            return .{};
        }
    };

    terminal: Terminal = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
};

test "transcript checkpoint sees input retained above an empty terminal" {
    var app = BufferedInputCheckpointTestApp{};
    app.terminal_input_runtime.terminal_theme_monitor.start();
    _ = app.terminal_input_runtime.terminal_theme_monitor.feed(0x1b, 0);
    var checkpoint = Runtime(BufferedInputCheckpointTestApp).transcriptBuildCheckpoint(&app).?;

    try std.testing.expectError(error.InputPending, build_checkpoint.poll(&checkpoint));
}

const CoordinatorFaultTestApp = struct {
    shell: struct {
        terminal_dimensions_invalid: bool = false,
        terminal_reset_pending: bool = false,
        resize_history_row_delta: ?i32 = null,
        pending_resize_observation: ?transcript_runtime.ResizeObservation = null,
        layout: struct {
            rows: u16 = 24,
            cols: u16 = 80,
        } = .{},
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    fault: CoordinatorFault = .committed,
    attempts: usize = 0,
    injected_reason: ?render_request.Reason = null,
    inject_animation_reset: bool = false,
    animation_visible: bool = false,
    notification_flushes: usize = 0,
    last_snapshot: ?render_request.AttemptSnapshot = null,

    fn flushNotifications(self: *CoordinatorFaultTestApp) void {
        self.notification_flushes += 1;
    }

    fn renderFrameAttemptForTest(
        self: *CoordinatorFaultTestApp,
        snapshot: render_request.AttemptSnapshot,
    ) !FrameAttemptResult {
        self.attempts += 1;
        self.last_snapshot = snapshot;
        if (self.injected_reason) |reason| {
            self.shell.render_requests.request(reason);
        }
        if (self.inject_animation_reset) {
            self.shell.render_requests.requestAnimationReset();
        }

        return switch (self.fault) {
            .committed => blk: {
                self.shell.terminal_reset_pending = false;
                break :blk .{
                    .shadow_state = .committed,
                    .animation_visible = self.animation_visible,
                };
            },
            .preparation_error => error.TestPreparationFailure,
            .input_pending => error.InputPending,
            .terminal_partial_write => .{
                .shadow_state = .terminal_partial_write,
                .animation_visible = self.animation_visible,
            },
            .shadow_feed_failed => .{
                .shadow_state = .shadow_feed_failed,
                .animation_visible = self.animation_visible,
            },
        };
    }
};

test "incremental child event replay retains the completed frontier after a later failure" {
    const alloc = std.testing.allocator;
    var runtime = transcript_runtime.TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer runtime.deinit(alloc);
    var diff_entries: std.ArrayList(diff_mod.DiffEntry) = .empty;
    defer {
        for (diff_entries.items) |*entry| entry.deinit(std.heap.c_allocator);
        diff_entries.deinit(std.heap.c_allocator);
    }
    const events = [_]worker_runtime.WorkerEvent{
        .{ .assistant_presentation = .{
            .text = @constCast("applied exactly once\n"),
        } },
        .{ .diff_block = .{
            .preview = @constCast("diff applied exactly once\n"),
            .full = .{
                .content = @constCast("full diff"),
                .lifecycle_id = .{ .turn_id = 98, .call_id = "diff-call" },
            },
        } },
        .{ .tool_lifecycle = .{ .progress = .{
            .id = .{ .turn_id = 99, .call_id = "missing" },
            .text = "must fail",
        } } },
    };
    var applied_count: usize = 0;
    var next_diff_id: u32 = 1;

    try std.testing.expectError(
        error.UnknownToolLifecycleIdentity,
        Runtime(CoordinatorFaultTestApp).applyIncrementalLivePresentationEvents(
            &runtime,
            alloc,
            &events,
            &applied_count,
            &next_diff_id,
            &diff_entries,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), applied_count);
    try std.testing.expectEqual(@as(usize, 1), diff_entries.items.len);
    try std.testing.expectEqual(@as(u32, 2), next_diff_id);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, runtime.transcript.items, "applied exactly once"),
    );
    var retained_diff_blocks: usize = 0;
    for (runtime.entries.items) |entry| switch (entry) {
        .raw_bytes => |raw| if (raw.class == .diff_block) {
            retained_diff_blocks += 1;
            try std.testing.expectEqual(
                @as(?u32, 1),
                diff_mod.markedDiffBlockId(raw.bytes),
            );
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), retained_diff_blocks);

    try std.testing.expectError(
        error.UnknownToolLifecycleIdentity,
        Runtime(CoordinatorFaultTestApp).applyIncrementalLivePresentationEvents(
            &runtime,
            alloc,
            &events,
            &applied_count,
            &next_diff_id,
            &diff_entries,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), applied_count);
    try std.testing.expectEqual(@as(usize, 1), diff_entries.items.len);
    try std.testing.expectEqual(@as(u32, 2), next_diff_id);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, runtime.transcript.items, "applied exactly once"),
    );
    retained_diff_blocks = 0;
    for (runtime.entries.items) |entry| switch (entry) {
        .raw_bytes => |raw| if (raw.class == .diff_block) {
            retained_diff_blocks += 1;
            try std.testing.expectEqual(
                @as(?u32, 1),
                diff_mod.markedDiffBlockId(raw.bytes),
            );
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), retained_diff_blocks);
}

test "core.app_render_runtime requested-frame flush skips absent and blocked work" {
    var app = CoordinatorFaultTestApp{};

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    try std.testing.expectEqual(@as(usize, 0), app.attempts);

    app.shell.render_requests.request(.footer);
    app.shell.terminal_dimensions_invalid = true;
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    try std.testing.expectEqual(@as(usize, 0), app.attempts);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.terminal_dimensions_invalid = false;
    app.shell.render_requests.observeResizeSignal(100, 80);
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    try std.testing.expectEqual(@as(usize, 0), app.attempts);
    try std.testing.expect(app.shell.render_requests.blocksFrameCommit());
}

test "core.app_render_runtime requested-frame flush commits one coalesced snapshot" {
    var app = CoordinatorFaultTestApp{};
    app.shell.render_requests.request(.first_frame);
    app.shell.render_requests.request(.footer);
    app.shell.render_requests.request(.modal);

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expectEqual(@as(usize, 3), app.last_snapshot.?.reasons.count());
    try std.testing.expect(!app.shell.render_requests.hasPending());
}

test "core.app_render_runtime flushes notifications only after a committed frame" {
    for ([_]CoordinatorFault{ .terminal_partial_write, .shadow_feed_failed }) |fault| {
        var app = CoordinatorFaultTestApp{ .fault = fault };
        app.shell.render_requests.request(.notification);

        try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
        try std.testing.expectEqual(@as(usize, 0), app.notification_flushes);
        try std.testing.expect(app.shell.render_requests.hasReason(.notification));

        app.fault = .committed;
        try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
        try std.testing.expectEqual(@as(usize, 1), app.notification_flushes);
        try std.testing.expect(!app.shell.render_requests.hasReason(.notification));
    }
}

test "core.app_render_runtime requested-frame flush preserves work injected during commit" {
    var app = CoordinatorFaultTestApp{
        .injected_reason = .modal,
    };
    app.shell.render_requests.request(.footer);

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "core.app_render_runtime requested-frame flush restores preparation errors" {
    var app = CoordinatorFaultTestApp{
        .fault = .preparation_error,
        .injected_reason = .modal,
    };
    app.shell.render_requests.request(.footer);
    app.shell.render_requests.requestInvalidation(.{
        .reason = .external_clear,
        .top = 3,
        .bottom = 4,
    });

    try std.testing.expectError(
        error.TestPreparationFailure,
        Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app),
    );

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
    try std.testing.expect(app.shell.render_requests.hasReason(.external_damage));
    try std.testing.expectEqual(
        @as(u8, 1),
        app.shell.render_requests.pendingInvalidations().len,
    );
}

test "core.app_render_runtime requested-frame flush restores input-interrupted work" {
    var app = CoordinatorFaultTestApp{ .fault = .input_pending };
    app.shell.render_requests.request(.modal);

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.fault = .committed;
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    try std.testing.expectEqual(@as(usize, 2), app.attempts);
    try std.testing.expect(!app.shell.render_requests.hasPending());
}

test "core.app_render_runtime requested-frame flush restores terminal recovery outcomes" {
    for ([_]CoordinatorFault{ .terminal_partial_write, .shadow_feed_failed }) |fault| {
        var app = CoordinatorFaultTestApp{
            .fault = fault,
            .injected_reason = .modal,
        };
        app.shell.render_requests.request(.transcript);
        app.shell.render_requests.requestInvalidation(.{
            .reason = .partial_write,
            .top = 2,
            .bottom = 5,
        });

        try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

        try std.testing.expectEqual(@as(usize, 1), app.attempts);
        try std.testing.expect(app.shell.render_requests.hasReason(.transcript));
        try std.testing.expect(app.shell.render_requests.hasReason(.modal));
        try std.testing.expect(app.shell.render_requests.hasReason(.external_damage));
        try std.testing.expectEqual(
            @as(u8, 1),
            app.shell.render_requests.pendingInvalidations().len,
        );
    }
}

test "core.app_render_runtime failed resize reset accepts only the superseding reset commit" {
    var app = CoordinatorFaultTestApp{ .fault = .terminal_partial_write };
    app.shell.render_requests.completeResizeGeometry(true);
    app.shell.pending_resize_observation = .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .{ .measured = 7 },
        .phase = .reset_queued,
    };
    app.shell.resize_history_row_delta = 7;
    app.shell.terminal_reset_pending = true;
    app.shell.render_requests.request(.resize);

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.shell.terminal_reset_pending);
    try std.testing.expectEqual(@as(?i32, 7), app.shell.resize_history_row_delta);
    try std.testing.expect(app.shell.pending_resize_observation != null);
    try std.testing.expect(app.shell.render_requests.resizeLifecyclePending());
    try std.testing.expect(app.shell.render_requests.hasReason(.resize));

    app.shell.render_requests.observeResizeSignal(200, 80);
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expect(app.shell.terminal_reset_pending);
    try std.testing.expectEqual(@as(?i32, 7), app.shell.resize_history_row_delta);

    app.shell.pending_resize_observation = .{
        .layout = .{
            .rows = 40,
            .cols = 120,
            .content_bottom = 36,
            .divider_top_row = 37,
            .input_row = 38,
            .divider_bottom_row = 39,
            .hint_row = 40,
        },
        .apply_after_ms = 280,
        .expected_row = 16,
        .result = .{ .measured = 3 },
        .phase = .reset_queued,
    };
    app.shell.resize_history_row_delta = 3;
    app.shell.render_requests.completeResizeGeometry(false);
    app.fault = .committed;
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 2), app.attempts);
    try std.testing.expect(!app.shell.terminal_reset_pending);
    try std.testing.expectEqual(
        @as(?transcript_runtime.ResizeObservation, null),
        app.shell.pending_resize_observation,
    );
    try std.testing.expectEqual(@as(?i32, null), app.shell.resize_history_row_delta);
    try std.testing.expect(!app.shell.render_requests.resizeLifecyclePending());
}

test "core.app_render_runtime awaiting resize observation blocks every flush caller" {
    var app = CoordinatorFaultTestApp{};
    app.shell.pending_resize_observation = .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .awaiting,
        .phase = .live,
    };
    app.shell.render_requests.request(.footer);

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 0), app.attempts);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.pending_resize_observation.?.result = .unavailable;
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
}

test "core.app_render_runtime committed resize light blocks intervening frames" {
    var app = CoordinatorFaultTestApp{};
    app.shell.render_requests.completeResizeGeometry(true);
    app.shell.pending_resize_observation = .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .{ .measured = 3 },
        .phase = .live,
    };
    app.shell.resize_history_row_delta = 3;
    app.shell.render_requests.request(.resize);

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expectEqual(
        transcript_runtime.ResizeObservationPhase.settle_pending,
        app.shell.pending_resize_observation.?.phase,
    );
    try std.testing.expectEqual(@as(?i32, null), app.shell.resize_history_row_delta);

    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 1), app.attempts);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "core.app_render_runtime animation retries the captured phase after every failure outcome" {
    for ([_]CoordinatorFault{
        .preparation_error,
        .terminal_partial_write,
        .shadow_feed_failed,
    }) |fault| {
        var app = CoordinatorFaultTestApp{
            .fault = fault,
            .animation_visible = true,
        };
        app.shell.render_requests.animation_visible = true;
        app.shell.render_requests.animation_next_deadline_ms = 100;
        try std.testing.expect(app.shell.render_requests.requestAnimationDue(100));

        if (fault == .preparation_error) {
            try std.testing.expectError(
                error.TestPreparationFailure,
                Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app),
            );
        } else {
            try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
        }
        const failed_candidate = app.last_snapshot.?.animation_candidate.?;

        try std.testing.expectEqual(
            @as(i16, -8),
            app.shell.render_requests.visibleAnimationPhase(),
        );
        try std.testing.expectEqual(
            @as(i64, 100),
            app.shell.render_requests.animation_next_deadline_ms,
        );

        app.fault = .committed;
        try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
        const retry_candidate = app.last_snapshot.?.animation_candidate.?;

        try std.testing.expectEqual(failed_candidate.generation, retry_candidate.generation);
        try std.testing.expectEqual(failed_candidate.phase, retry_candidate.phase);
        try std.testing.expectEqual(
            retry_candidate.phase,
            app.shell.render_requests.visibleAnimationPhase(),
        );
        try std.testing.expect(app.shell.render_requests.animation_next_deadline_ms > 100);
    }
}

test "core.app_render_runtime animation retry stays ahead of a newer fact" {
    var app = CoordinatorFaultTestApp{
        .fault = .terminal_partial_write,
        .inject_animation_reset = true,
        .animation_visible = true,
    };
    app.shell.render_requests.animation_visible = true;
    app.shell.render_requests.animation_next_deadline_ms = 100;
    try std.testing.expect(app.shell.render_requests.requestAnimationDue(100));

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    const failed_candidate = app.last_snapshot.?.animation_candidate.?;
    try std.testing.expectEqual(
        @as(i16, -8),
        app.shell.render_requests.visibleAnimationPhase(),
    );

    app.fault = .committed;
    app.inject_animation_reset = false;
    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    const retry_candidate = app.last_snapshot.?.animation_candidate.?;
    try std.testing.expectEqual(failed_candidate.generation, retry_candidate.generation);
    try std.testing.expect(app.shell.render_requests.hasReason(.animation));

    try Runtime(CoordinatorFaultTestApp).flushRequestedFrame(&app);
    const newer_candidate = app.last_snapshot.?.animation_candidate.?;
    try std.testing.expect(newer_candidate.generation > retry_candidate.generation);
    try std.testing.expectEqual(
        newer_candidate.phase,
        app.shell.render_requests.visibleAnimationPhase(),
    );
    try std.testing.expect(!app.shell.render_requests.hasPending());
}

const CoordinatorTestWorker = struct {
    submitted_permission: ?types.ToolPermissionDecision = null,

    fn queuePreview(_: *@This()) struct { count: usize = 0 } {
        return .{};
    }

    pub fn submitPermissionResponse(
        self: *@This(),
        _: u64,
        response: permission_request.OwnedPermissionResponse,
    ) @import("../agent/worker_runtime.zig").PermissionSubmissionResult {
        var owned = response;
        defer owned.deinit();
        self.submitted_permission = owned.decision;
        return .accepted;
    }
};

const CoordinatorTestUpgrader = struct {
    fn statusLabel(_: *@This(), _: []u8) []const u8 {
        return "";
    }
};

const CoordinatorTestPacer = struct {
    pending: bool = false,
    completed_token_progress: ?types.TurnTokenProgress = null,

    fn hasCompletedAssistantPresentationTail(self: *const CoordinatorTestPacer) bool {
        return self.completed_token_progress != null;
    }

    fn hasPending(self: *const CoordinatorTestPacer) bool {
        return self.pending;
    }

    fn completedAssistantPresentationTokenProgress(self: *const CoordinatorTestPacer) ?types.TurnTokenProgress {
        return self.completed_token_progress;
    }
};

const coordinator_test_slash_specs = [_]command_specs.SlashSpec{.{
    .kind = .help,
    .command = "/help",
    .help_entry = "/help",
}};
const coordinator_test_slash_registry = command_specs.SlashRegistry{
    .commands = coordinator_test_slash_specs[0..],
};

const CoordinatorTestTerminalClient = struct {
    snapshot_alloc: std.mem.Allocator = std.testing.allocator,
    snapshot_count: usize = 0,
    source_running: bool = false,

    fn terminalProjection(
        self: *CoordinatorTestTerminalClient,
        _: std.mem.Allocator,
    ) std.mem.Allocator.Error!terminal_ui_projection.Snapshot {
        self.snapshot_count += 1;
        const rows = try self.snapshot_alloc.alloc(
            terminal_ui_projection.Row,
            @intFromBool(self.source_running),
        );
        errdefer self.snapshot_alloc.free(rows);
        if (self.source_running) {
            const session_id = try self.snapshot_alloc.dupe(u8, "terminal-test");
            errdefer self.snapshot_alloc.free(session_id);
            rows[0] = .{
                .session_id = session_id,
                .label = try self.snapshot_alloc.dupe(u8, "test command"),
                .lifecycle = .running,
                .attention = .{},
                .backend = .native,
            };
        }
        self.source_running = false;
        return .{ .alloc = self.snapshot_alloc, .rows = rows };
    }
};

const CoordinatorTestApp = struct {
    alloc: std.mem.Allocator,
    terminal: shell_runtime.TerminalState = .{},
    shell: transcript_runtime.TranscriptRuntime,
    metrics: types.Metrics = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    question_prompt: question_prompt.QuestionPrompt = .{},
    session_persistence: app_session_runtime.Persistence = .{},
    worker: CoordinatorTestWorker = .{},
    subagents: ui_subagents.Controller = .{},
    selected_model: std.ArrayList(u8) = .empty,
    workspace_root: []const u8 = "",
    workspace_identity: statusline_identity.Runtime = .{},
    pacer: CoordinatorTestPacer = .{},
    auth: auth_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    skills: skill_runtime.Runtime = .{},
    model_cache: model_cache_runtime.Runtime = model_cache_runtime.Runtime.init(std.testing.allocator, "/v1/models"),
    stream: types.StreamState = .{},
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    statusline_sandbox: bool = false,
    statusline_context: bool = false,
    total_input_tokens: u64 = 0,
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    permission_state: app_permission_runtime.State = .{},
    upgrader: CoordinatorTestUpgrader = .{},
    terminal_client: CoordinatorTestTerminalClient = .{},

    pub fn slashRegistry(_: *const CoordinatorTestApp) command_specs.SlashRegistry {
        return coordinator_test_slash_registry;
    }

    fn deinit(self: *CoordinatorTestApp) void {
        self.shell.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.approval_prompt.deinit(self.alloc);
        self.question_prompt.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.workspace_identity.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
        self.model_cache.deinit();
    }

    pub fn modelCompletions(_: *CoordinatorTestApp, _: []const u8, _: [][]const u8) usize {
        return 0;
    }

    fn fileCompletions(
        _: *CoordinatorTestApp,
        _: []const u8,
        _: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        return 0;
    }

    fn isModelCacheLoading(_: *CoordinatorTestApp) bool {
        return false;
    }

    fn isModelCacheFailed(_: *CoordinatorTestApp) bool {
        return false;
    }

    pub fn resolvedModelCapabilities(self: *CoordinatorTestApp, model: []const u8) model_capabilities.Capabilities {
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.resolveCapabilities(model, self.gateway_metadata);
            }
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    fn isFileIndexLoading(_: *CoordinatorTestApp) bool {
        return false;
    }

    fn isFileIndexFailed(_: *CoordinatorTestApp) bool {
        return false;
    }
};

fn initCoordinatorProjectionTestApp(
    alloc: std.mem.Allocator,
    file: std.Io.File,
) !CoordinatorTestApp {
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 12,
                .cols = 80,
                .content_bottom = 8,
                .divider_top_row = 9,
                .input_row = 10,
                .divider_bottom_row = 11,
                .hint_row = 12,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
        .terminal_client = .{
            .source_running = true,
        },
    };
    errdefer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    return app;
}

test "core.app_render_runtime keeps final token progress during paced response tail" {
    const alloc = std.testing.allocator;
    const progress: types.TurnTokenProgress = .{
        .input_tokens = 50_000,
        .output_tokens = 20_000,
    };
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{},
        .pacer = .{
            .pending = true,
            .completed_token_progress = progress,
        },
    };
    defer app.deinit();

    var upgrade_status_buf: [64]u8 = undefined;
    const queued_cards: QueuedCardProjection = .{};
    const ctx = Runtime(CoordinatorTestApp).footerContext(
        &app,
        &upgrade_status_buf,
        0,
        &queued_cards,
    );

    try std.testing.expectEqual(progress, ctx.stream.token_progress);
    var activity_buf: [128]u8 = undefined;
    switch (render_input.frameOwnedActivityProjection(
        &activity_buf,
        &app.shell,
        ctx,
        null,
    )) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings(
            "  (↑50k ↓20k)",
            thinking.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "core.app_render_runtime projects only the visible inline completion suffix" {
    const alloc = std.testing.allocator;
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{},
    };
    defer app.deinit();
    app.shell.layout.cols = 80;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "explain $man");

    var upgrade_status_buf: [64]u8 = undefined;
    const queued_cards: QueuedCardProjection = .{};
    const ctx = Runtime(CoordinatorTestApp).footerContext(
        &app,
        &upgrade_status_buf,
        0,
        &queued_cards,
    );

    try std.testing.expectEqualStrings("aged-menu", ctx.inline_completion_suffix);
    try std.testing.expectEqualStrings("explain $man", ctx.input.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.input.entities.skill_tokens.items.len);
}

test "core.app_render_runtime projects an inline slash completion suffix after text" {
    const alloc = std.testing.allocator;
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{},
    };
    defer app.deinit();
    app.shell.layout.cols = 80;
    try app.input_runtime.textReplacementState().replace(alloc, "explain /he");

    var upgrade_status_buf: [64]u8 = undefined;
    const queued_cards: QueuedCardProjection = .{};
    const ctx = Runtime(CoordinatorTestApp).footerContext(
        &app,
        &upgrade_status_buf,
        0,
        &queued_cards,
    );

    try std.testing.expectEqualStrings("/help", ctx.slash_registry.commands[0].command);
    try std.testing.expectEqualStrings("lp", ctx.inline_completion_suffix);
    try std.testing.expectEqualStrings("explain /he", ctx.input.edit_state.input.items);
}

test "core.app_render_runtime projects Opus 4.8 one million token context to footer" {
    const alloc = std.testing.allocator;
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{},
        .statusline_context = true,
        .total_input_tokens = 43_000,
    };
    defer app.deinit();

    const statusline = Runtime(CoordinatorTestApp).buildStatuslineItems(
        &app,
        "anthropic/claude-opus-4.8",
    );
    try std.testing.expectEqual(@as(u64, 43_000), statusline.context_used);
    try std.testing.expectEqual(@as(?u32, 1_000_000), statusline.context_total);

    var buf: [128]u8 = undefined;
    const line = ui_render.buildHintLine(
        false,
        false,
        true,
        "anthropic/claude-opus-4.8",
        .ask,
        0,
        null,
        false,
        true,
        .auto,
        true,
        statusline,
        100,
        &buf,
    );
    try std.testing.expectEqualStrings("ask · opus 4.8 · Context: 43k/1000k 4%", line);
}

test "core.app_render_runtime uses Gateway context window from resolved capabilities" {
    const alloc = std.testing.allocator;
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{},
        .statusline_context = true,
        .total_input_tokens = 12_000,
        .gateway_metadata_model = "provider/new-long-context",
        .gateway_metadata = .{ .context_window = 750_000 },
    };
    defer app.deinit();

    const statusline = Runtime(CoordinatorTestApp).buildStatuslineItems(
        &app,
        "provider/new-long-context",
    );
    try std.testing.expectEqual(@as(u64, 12_000), statusline.context_used);
    try std.testing.expectEqual(@as(?u32, 750_000), statusline.context_total);
}

test "core.app_render_runtime request owner authorizes explicit frame causes" {
    const alloc = std.testing.allocator;
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{},
        .stream = .{ .active = true },
    };
    defer app.deinit();

    app.shell.shimmer_active = true;
    try std.testing.expect(!app.shell.render_requests.hasPending());

    app.shell.markTranscriptDirty();
    try std.testing.expect(app.shell.render_requests.hasReason(.transcript));

    app.shell.render_requests.request(.footer);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    try app.shell.recordFrameInvalidation(.{
        .reason = .external_clear,
        .top = 1,
        .bottom = 1,
    });
    try std.testing.expect(app.shell.render_requests.hasReason(.external_damage));
}

test "core.app_render_runtime exposes one requested-frame flush boundary" {
    try std.testing.expect(@hasDecl(Runtime(CoordinatorTestApp), "flushRequestedFrame"));
}

test "core.app_render_runtime requested-frame flush commits and acknowledges one snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "requested-frame.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 12,
                .cols = 64,
                .content_bottom = 8,
                .divider_top_row = 9,
                .input_row = 10,
                .divider_bottom_row = 11,
                .hint_row = 12,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "requested frame content\n", true);
    app.shell.terminal_reset_pending = true;

    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.shell.has_committed_frame);
    try std.testing.expect(!app.shell.terminal_reset_pending);
    try std.testing.expect(!app.shell.render_requests.hasPending());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "requested frame content"));
}

test "core.app_render_runtime inline frame omits background terminal chrome and animation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "terminal-projection.log", .{ .read = true });
    defer file.close(io_mod.getIo());
    var app = try initCoordinatorProjectionTestApp(alloc, file);
    defer app.deinit();

    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(@as(usize, 0), app.terminal_client.snapshot_count);
    try std.testing.expect(app.terminal_client.source_running);
    try std.testing.expect(!app.shell.render_requests.animation_visible);
    try std.testing.expect(!(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "background (",
    )));
    try std.testing.expect(!(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "ctrl+x manager",
    )));
}

noinline fn readCoordinatorFrameBytes(alloc: std.mem.Allocator, file: std.Io.File, read_offset: *u64) ![]u8 {
    const total = try file.length(io_mod.getIo());
    const want: usize = @intCast(total - read_offset.*);
    const bytes = try alloc.alloc(u8, want);
    errdefer alloc.free(bytes);
    const n = try file.readPositionalAll(io_mod.getIo(), bytes, read_offset.*);
    try std.testing.expectEqual(want, n);
    read_offset.* += n;
    return bytes;
}

noinline fn coordinatorGridContains(grid: vt_emulator.Grid, needle: []const u8) !bool {
    var row: u16 = 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);

    while (row <= grid.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return true;
    }
    return false;
}

noinline fn coordinatorGridOccurrenceCount(grid: vt_emulator.Grid, needle: []const u8) !usize {
    var row: u16 = 1;
    var count: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);

    while (row <= grid.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &buf);
        count += std.mem.count(u8, buf.items, needle);
    }
    return count;
}

test "core.app_render_runtime takeover manager return rebuilds the narrow inline viewport" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "takeover-manager-return.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 36,
                .cols = 120,
                .content_bottom = 32,
                .divider_top_row = 33,
                .input_row = 34,
                .divider_bottom_row = 35,
                .hint_row = 36,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    var physical = try vt_emulator.Grid.init(alloc, 120, 36);
    defer physical.deinit();
    var read_offset: u64 = 0;
    try app.input_runtime.textReplacementState().replace(alloc, "LANE1_COMPOSER_DRAFT_ABCDE");
    app.input_runtime.edit_state.cursor -= 5;

    const transcript =
        "INLINE_OLD_TOP_ORPHAN_01_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n" ++
        "INLINE_OLD_TOP_ORPHAN_02_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n" ++
        "INLINE_OLD_TOP_ORPHAN_03_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\n" ++
        "INLINE_OLD_TOP_ORPHAN_04_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD\n" ++
        "INLINE_ROW_05\n" ++
        "INLINE_ROW_06\n" ++
        "INLINE_ROW_07\n" ++
        "INLINE_ROW_08\n" ++
        "INLINE_ROW_09\n" ++
        "INLINE_ROW_10\n" ++
        "INLINE_ROW_11\n" ++
        "INLINE_ROW_12\n" ++
        "INLINE_ROW_13\n" ++
        "INLINE_ROW_14\n" ++
        "INLINE_ROW_15\n" ++
        "INLINE_TAIL_MARKER";
    try app.shell.writeTranscript(alloc, &app.metrics, transcript, true);
    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const initial_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(initial_bytes);
    try physical.feed(initial_bytes);
    try std.testing.expect(app.shell.cursor_row > 8);

    app.subagents.open(alloc);
    try app_lifecycle.enterSubagentManagerScreen(&app.terminal, &app.shell, &app.metrics);
    Runtime(CoordinatorTestApp).requestSubagentSurfaceFrame(&app, .subagent_panel);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const manager_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(manager_bytes);
    try physical.feed(manager_bytes);

    try app_lifecycle.leaveSubagentManagerScreen(&app.terminal, &app.shell, &app.metrics);
    try app_lifecycle.enterTerminalSessionScreen(&app.terminal, &app.shell, &app.metrics);
    try app_lifecycle.writeLifecycleTerminalBytes(
        &app.shell,
        &app.metrics,
        "TAKEOVER_120X36\n",
    );
    const takeover_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(takeover_bytes);
    try physical.feed(takeover_bytes);

    app.shell.layout = .{
        .rows = 24,
        .cols = 88,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    try app.shell.shadow_vt.?.resize(88, 24);
    try physical.resize(88, 24);
    try app_lifecycle.writeLifecycleTerminalBytes(
        &app.shell,
        &app.metrics,
        "TAKEOVER_88X24\n",
    );
    const resize_88_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(resize_88_bytes);
    try physical.feed(resize_88_bytes);

    app.shell.layout = .{
        .rows = 12,
        .cols = 60,
        .content_bottom = 8,
        .divider_top_row = 9,
        .input_row = 10,
        .divider_bottom_row = 11,
        .hint_row = 12,
    };
    try app.shell.shadow_vt.?.resize(60, 12);
    try physical.resize(60, 12);
    try app_lifecycle.writeLifecycleTerminalBytes(
        &app.shell,
        &app.metrics,
        "TAKEOVER_60X12\n",
    );
    const resize_60_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(resize_60_bytes);
    try physical.feed(resize_60_bytes);

    try app_lifecycle.handoffTerminalSessionToSubagentManager(
        &app.terminal,
        &app.shell,
        &app.metrics,
    );
    Runtime(CoordinatorTestApp).requestSubagentSurfaceFrame(&app, .subagent_panel);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const returned_manager_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(returned_manager_bytes);
    try physical.feed(returned_manager_bytes);
    try Runtime(CoordinatorTestApp).toggleSubagentView(&app);
    const manager_close_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(manager_close_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, manager_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, takeover_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, takeover_bytes, "\x1b[?1049l"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, returned_manager_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, returned_manager_bytes, "\x1b[?1049l"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, manager_close_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, manager_close_bytes, "\x1b[?1049l"),
    );
    try std.testing.expect(std.mem.find(
        u8,
        returned_manager_bytes,
        ui_terminal.interactiveModeEnableSequence(io_mod.getenv("TMUX")),
    ) != null);
    for ([_][]const u8{
        "\x1b[?2026l",
        "\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l",
        "\x1b[?1l\x1b>",
        "\x1b[?2004l\x1b[<u",
    }) |restored_mode| {
        try std.testing.expect(std.mem.find(
            u8,
            returned_manager_bytes,
            restored_mode,
        ) != null);
    }
    try physical.feed(manager_close_bytes);
    try physical.feed("\x1b[5;30HORPHANED_OLD_CELLS");
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const inline_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(inline_bytes);
    try physical.feed(inline_bytes);

    const grid = physical;
    try std.testing.expect(!(try coordinatorGridContains(grid, "ORPHANED_OLD_CELLS")));
    try std.testing.expect(!(try coordinatorGridContains(grid, "INLINE_OLD_TOP_ORPHAN")));
    try std.testing.expectEqual(
        @as(usize, 1),
        try coordinatorGridOccurrenceCount(grid, "INLINE_TAIL_MARKER"),
    );
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("INLINE_ROW_08", row.items);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(8, &row);
    try std.testing.expectEqualStrings("INLINE_ROW_15", row.items);
    try std.testing.expectEqualStrings(
        "LANE1_COMPOSER_DRAFT_ABCDE",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(
        "LANE1_COMPOSER_DRAFT_ABCDE".len - 5,
        app.input_runtime.edit_state.cursor,
    );
}

test "core.app_render_runtime first requested startup frame commits through the ordinary coordinator" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "first-startup-frame.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    const layout: types.Layout = .{
        .rows = 12,
        .cols = 64,
        .content_bottom = 8,
        .divider_top_row = 9,
        .input_row = 10,
        .divider_bottom_row = 11,
        .hint_row = 12,
    };
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = layout,
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "startup frame content\n", true);

    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.shell.has_committed_frame);
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "startup frame content"));
    const first_len = try file.length(io_mod.getIo());
    try std.testing.expect(first_len > 0);

    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(first_len, try file.length(io_mod.getIo()));
}

test "core.app_render_runtime active skills menu owns a transcript-free alternate screen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "skills-screen.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    const skills = [_]skill_runtime.Skill{.{
        .name = "pure-core",
        .description = "Keep data transformations pure.",
        .path = "/skills/pure-core/SKILL.md",
        .source = .global_fx,
    }};
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 14,
                .cols = 72,
                .content_bottom = 10,
                .divider_top_row = 11,
                .input_row = 12,
                .divider_bottom_row = 13,
                .hint_row = 14,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "$pure");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    app.skills.items = @constCast(&skills);
    app.skills.openMenuWithQuery(.dollar, .{ .start = 0, .end = app.input_runtime.edit_state.input.items.len }, "pure");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "transcript must stay behind the browser\n", true);

    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "$pure"));
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Skills 1"));
    try std.testing.expect(!(try coordinatorGridContains(app.shell.shadow_vt.?.*, "transcript must stay behind")));

    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .id = 42,
        .label = "web_search latest Zig release",
    }));
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(!app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "Would you like to allow this action?",
    ));

    app.approval_prompt.clear(alloc);
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Skills 1"));

    const options = [_]types.QuestionOption{
        .{ .label = "Inspect repo state", .description = null },
        .{ .label = "Keep going", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "What should fx do next?", .options = &options },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(!app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Inspect repo state"));

    app.question_prompt.discard(alloc, "test_cleanup");
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Skills 1"));

    try app.shell.writeTranscript(alloc, &app.metrics, "background transcript update\n", true);
    app.shell.render_requests.request(.transcript);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(!(try coordinatorGridContains(app.shell.shadow_vt.?.*, "background transcript update")));

    app.shell.layout = .{
        .rows = 10,
        .cols = 48,
        .content_bottom = 6,
        .divider_top_row = 7,
        .input_row = 8,
        .divider_bottom_row = 9,
        .hint_row = 10,
    };
    app.shell.render_requests.request(.resize);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expectEqual(@as(u16, 48), app.shell.shadow_vt.?.cols);
    try std.testing.expectEqual(@as(u16, 10), app.shell.shadow_vt.?.rows);
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Skills 1"));

    app.skills.closeMenu();
    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "transcript must stay behind"));
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "background transcript update"));

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, terminal_bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, terminal_bytes, "\x1b[?1049l"));
}

test "core.app_render_runtime model catalog survives modal preemption and restores the transcript on close" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "models-screen.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 14,
                .cols = 72,
                .content_bottom = 10,
                .divider_top_row = 11,
                .input_row = 12,
                .divider_bottom_row = 13,
                .hint_row = 14,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "current/model");
    app.model_cache.menu.active = true;
    app.model_cache.menu.load_state = .loading;
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "model catalog transcript stays behind\n", true);

    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Models 0"));
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Loading models"));
    try std.testing.expect(!(try coordinatorGridContains(app.shell.shadow_vt.?.*, "model catalog transcript stays behind")));

    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .id = 84,
        .label = "web_search latest model metadata",
    }));
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(!app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Would you like to allow this action?"));

    app.approval_prompt.clear(alloc);
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Loading models"));

    app.model_cache.closeMenu();
    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(!app.terminal.catalogMenuScreenActive());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "model catalog transcript stays behind"));
}

test "core.app_render_runtime file approval returns to the preserved skills catalog" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "skills-file-approval.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    const skills = [_]skill_runtime.Skill{.{
        .name = "pure-core",
        .description = "Keep data transformations pure.",
        .path = "/skills/pure-core/SKILL.md",
        .source = .global_fx,
    }};
    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = "after" },
    };
    const request: permission_request.PermissionRequest = .{
        .id = 44,
        .label = "write_file note.txt",
        .file = .{
            .kind = .write,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    var review = try diff_mod.FileReview.init(alloc, "", "after\n");
    defer review.deinit(alloc);
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 14,
                .cols = 72,
                .content_bottom = 10,
                .divider_top_row = 11,
                .input_row = 12,
                .divider_bottom_row = 13,
                .hint_row = 14,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "$pure");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    app.skills.items = @constCast(&skills);
    app.skills.openMenuWithQuery(.dollar, .{ .start = 0, .end = app.input_runtime.edit_state.input.items.len }, "pure");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "transcript behind catalog\n", true);

    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.catalogMenuScreenActive());

    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, request));
    try std.testing.expect(app.approval_prompt.syncReview(&review));
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(shell_runtime.AlternateScreenOwner.file_approval, app.terminal.alternate_screen_owner);
    try std.testing.expectEqualStrings("$pure", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("pure", app.skills.menu.query());

    app.approval_prompt.clear(alloc);
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expectEqualStrings("$pure", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("pure", app.skills.menu.query());
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "Skills 1"));

    app.skills.closeMenu();
    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expectEqual(shell_runtime.AlternateScreenOwner.none, app.terminal.alternate_screen_owner);
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "transcript behind catalog"));
}

test "core.app_render_runtime file approvals commit the alternate screen for each request" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "identity-only-modal.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    const preview_lines = [_]diff_mod.PreviewLine{
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
    };
    const request_a: permission_request.PermissionRequest = .{
        .id = 41,
        .label = "file_mutation",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 1,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    var review = try diff_mod.FileReview.init(alloc, "before\n", "after\n");
    defer review.deinit(alloc);
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        request_a,
    ));
    try std.testing.expect(app.approval_prompt.syncReview(&review));

    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const first_len = try file.length(io_mod.getIo());
    try std.testing.expect(first_len > 0);
    try std.testing.expect(app.terminal.fileApprovalScreenActive());
    try std.testing.expect(!app.approval_screen.screen_commit.?.document_scrollable);
    try std.testing.expect(app.terminal.alternate_mouse_tracking_active);
    try std.testing.expect(approval_screen.fileApprovalAffirmativeReady(
        &app.shell,
        app.approval_prompt.projection().?,
        &app.approval_screen,
    ));
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "after"));

    app.shell.layout.rows = 20;
    app.shell.layout.cols = 80;
    app.shell.render_requests.request(.resize);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const resized_len = try file.length(io_mod.getIo());
    try std.testing.expect(resized_len > first_len);
    try std.testing.expectEqual(@as(u16, 80), app.shell.shadow_vt.?.cols);
    try std.testing.expectEqual(@as(u16, 20), app.shell.shadow_vt.?.rows);
    try std.testing.expect(approval_screen.fileApprovalAffirmativeReady(
        &app.shell,
        app.approval_prompt.projection().?,
        &app.approval_screen,
    ));

    var request_b = request_a;
    request_b.id = 42;
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        request_b,
    ));
    try std.testing.expect(app.approval_prompt.syncReview(&review));
    app.shell.render_requests.request(.modal);
    try std.testing.expect(!approval_screen.fileApprovalAffirmativeReady(
        &app.shell,
        app.approval_prompt.projection().?,
        &app.approval_screen,
    ));

    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect((try file.length(io_mod.getIo())) > resized_len);
    try std.testing.expect(!app.shell.render_requests.hasPending());
    try std.testing.expect(approval_screen.fileApprovalAffirmativeReady(
        &app.shell,
        app.approval_prompt.projection().?,
        &app.approval_screen,
    ));
    try std.testing.expectEqual(@as(u64, 42), app.approval_screen.screen_commit.?.request_id);
    try std.testing.expect(app.terminal.fileApprovalScreenActive());
    try std.testing.expect(app.terminal.alternate_mouse_tracking_active);

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049l"),
    );
}

test "core.app_render_runtime restores file review before rendering a generic approval inline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "file-to-generic-approval.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = "after" },
    };
    const file_request: permission_request.PermissionRequest = .{
        .id = 41,
        .label = "file_mutation",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    const generic_request: permission_request.PermissionRequest = .{
        .id = 42,
        .label = "web_search latest Zig release",
    };
    var review = try diff_mod.FileReview.init(alloc, "", "after\n");
    defer review.deinit(alloc);
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, file_request));
    try std.testing.expect(app.approval_prompt.syncReview(&review));

    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.fileApprovalScreenActive());
    try std.testing.expect(app.terminal.alternate_mouse_tracking_active);

    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, generic_request));
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.fileApprovalScreenActive());
    try std.testing.expect(!app.terminal.alternate_mouse_tracking_active);
    try std.testing.expect(!app.shell.render_requests.hasReason(.external_damage));
    try std.testing.expect(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "Would you like to allow this action?",
    ));

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049l"),
    );
}

test "core.app_render_runtime generic approval exits the full transcript screen before rendering inline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "full-transcript-to-generic-approval.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "prior transcript\n", true);
    try app_lifecycle.openFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);

    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .id = 42,
        .label = "terminal.exec sh -c 'printf approval'",
    }));
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());
    try std.testing.expect(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "Would you like to run the following command?",
    ));

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049l"),
    );
}

test "core.app_render_runtime question prompt exits the full transcript screen before rendering inline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "full-transcript-to-question.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "prior transcript\n", true);
    try app_lifecycle.openFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);

    const options = [_]types.QuestionOption{
        .{ .label = "Inspect repo state", .description = null },
        .{ .label = "Keep going", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "What should fx do next?", .options = &options },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());
    try std.testing.expect(app.shell.has_committed_frame);
    try std.testing.expect(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "Inspect repo state",
    ));

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049l"),
    );
}

test "core.app_render_runtime file approval takes over the full transcript alternate screen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "full-transcript-to-file-approval.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = "after" },
    };
    const request: permission_request.PermissionRequest = .{
        .id = 43,
        .label = "write_file note.txt",
        .file = .{
            .kind = .write,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    var review = try diff_mod.FileReview.init(alloc, "", "after\n");
    defer review.deinit(alloc);
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "prior transcript\n", true);
    try app_lifecycle.openFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, request));
    try std.testing.expect(app.approval_prompt.syncReview(&review));

    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(app.terminal.fileApprovalScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());
    try std.testing.expect(approval_screen.fileApprovalAffirmativeReady(
        &app.shell,
        app.approval_prompt.projection().?,
        &app.approval_screen,
    ));
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "after"));

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049l"),
    );
}

test "core.app_render_runtime lifecycle rewrite recovers normal buffer after file rejection" {
    const approval_input_runtime = @import("input_approval_runtime.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "lifecycle-rewrite-file-rejection.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);

    try app.shell.writeTranscript(alloc, &app.metrics, "setup sentinel\n", true);
    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "streaming-command" };
    _ = try app.shell.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycle_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"stream\"}",
    } });
    try app.shell.writeTranscript(
        alloc,
        &app.metrics,
        "retained assistant history\n" ** 64,
        true,
    );
    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const committed_before = app.shell.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        committed_before.state,
    );
    try std.testing.expect((committed_before.stable_start_line orelse 0) > 0);

    try app_lifecycle.openFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try app.shell.writeTranscript(alloc, &app.metrics, "stream completed\n", true);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    _ = try shell_runtime.applyToolLifecyclePreservingNormalBufferAnchor(
        alloc,
        &app.shell,
        .{ .terminal = .{
            .id = lifecycle_id,
            .outcome = .{ .kind = .completed, .summary = "Streaming command completed" },
            .result = "stream completed",
        } },
    );
    const state_after_rewrite = app.shell.transcriptCommitDiagnostic().state;

    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = "pending" },
    };
    const request: permission_request.PermissionRequest = .{
        .id = 72,
        .label = "write_file pending.txt",
        .file = .{
            .kind = .write,
            .intent = .mutation,
            .preview = .{
                .path = "pending.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    var review = try diff_mod.FileReview.init(alloc, "", "pending\n");
    defer review.deinit(alloc);
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, request));
    try std.testing.expect(app.approval_prompt.syncReview(&review));
    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    try std.testing.expect(app.terminal.fileApprovalScreenActive());

    try std.testing.expect(try approval_input_runtime.ApprovalRuntime(CoordinatorTestApp).handlePermissionAction(
        &app,
        .{ .number = 2 },
    ));
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expectEqual(types.ToolPermissionDecision.deny, app.worker.submitted_permission.?);
    try std.testing.expect(!app.terminal.fileApprovalScreenActive());
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        state_after_rewrite,
    );
    try std.testing.expect(try coordinatorGridContains(app.shell.shadow_vt.?.*, "stream completed"));
}

test "core.app_render_runtime changed resized full transcript close preserves primary history without full replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "full-transcript-changed-resize-recovery.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);

    try app.shell.writeTranscript(
        alloc,
        &app.metrics,
        "old primary history\n" ** 256,
        true,
    );
    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try app_lifecycle.openFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    app.shell.layout = .{
        .rows = 18,
        .cols = 72,
        .content_bottom = 14,
        .divider_top_row = 15,
        .input_row = 16,
        .divider_bottom_row = 17,
        .hint_row = 18,
    };
    try app.shell.requestTerminalResetAfterResize(&app.metrics, null);
    try app.shell.writeTranscript(
        alloc,
        &app.metrics,
        "new output while review is open\n",
        true,
    );
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    var read_offset = try file.length(io_mod.getIo());
    try app_lifecycle.closeFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const close_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(close_bytes);

    try std.testing.expect(std.mem.find(u8, close_bytes, "\x1b[3J") == null);
    try std.testing.expect(close_bytes.len < 16 * 1024);
    try std.testing.expect(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "new output while review is open",
    ));
    try std.testing.expect(!app.shell.terminal_reset_pending);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        app.shell.transcriptCommitDiagnostic().state,
    );
}

test "core.app_render_runtime exits terminal-only full transcript state before normal render" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "terminal-only-full-transcript.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try app.shell.writeTranscript(alloc, &app.metrics, "prior transcript\n", true);
    try app_lifecycle.openFullTranscript(app.alloc, &app.terminal, &app.shell, &app.metrics);
    app.shell.closeFullTranscriptState();
    try std.testing.expect(app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());

    app.shell.render_requests.request(.transcript);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());
    try std.testing.expect(try coordinatorGridContains(
        app.shell.shadow_vt.?.*,
        "prior transcript",
    ));

    var read_offset: u64 = 0;
    const terminal_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(terminal_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, terminal_bytes, "\x1b[?1049l"),
    );
}

test "core.app_render_runtime approval screen failure denies after leaving alternate mode" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        std.testing.io,
        "approval-screen-failure.log",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());

    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = "after" },
    };
    const request: permission_request.PermissionRequest = .{
        .id = 73,
        .label = "file_mutation",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 24,
                .cols = 96,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, request));

    app.shell.render_requests.request(.modal);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);

    try std.testing.expect(!app.terminal.fileApprovalScreenActive());
    try std.testing.expect(!app.approval_prompt.isActive());
    try std.testing.expect(!app.shell.render_requests.hasReason(.external_damage));
    try std.testing.expectEqual(
        types.ToolPermissionDecision.deny,
        app.worker.submitted_permission.?,
    );
}

test "approval screen clear decision rebuilds first request replacements and resizes only" {
    const request_a: permission_request.PermissionRequest = .{
        .id = 10,
        .label = "web_search latest Zig release",
    };
    const request_b: permission_request.PermissionRequest = .{
        .id = 11,
        .label = "web_search latest Zig release",
    };
    const layout: types.Layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    const commit: interaction_state.ApprovalScreenCommit = .{
        .request_id = request_a.id,
        .rows = layout.rows,
        .cols = layout.cols,
        .file_identity_visible = false,
        .all_decision_controls_visible = false,
        .changed_or_notice_visible = false,
        .document_scrollable = false,
    };

    try std.testing.expect(approvalScreenNeedsClear(false, request_a, layout, commit));
    try std.testing.expect(!approvalScreenNeedsClear(true, request_a, layout, commit));
    try std.testing.expect(approvalScreenNeedsClear(true, request_b, layout, commit));

    var resized = layout;
    resized.cols = 48;
    try std.testing.expect(approvalScreenNeedsClear(true, request_a, resized, commit));
    try std.testing.expect(approvalScreenNeedsClear(true, request_a, layout, null));
}

fn coordinatorRowHasText(grid: vt_emulator.Grid, row: u16) !bool {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);
    try grid.rowTextTrimmed(row, &buf);
    return std.mem.trim(u8, buf.items, " \t\r\n").len > 0;
}

test "core.app_render_runtime coordinator physically scrolls preserved shell rows for wrapped transcript growth" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "coordinator-scroll.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    const layout: types.Layout = .{
        .rows = 12,
        .cols = 32,
        .content_bottom = 8,
        .divider_top_row = 9,
        .input_row = 10,
        .divider_bottom_row = 11,
        .hint_row = 12,
    };
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = layout,
            .owned_top_row = 8,
            .viewport_top_row = 8,
        },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);

    var terminal = try vt_emulator.Grid.init(alloc, layout.cols, layout.rows);
    defer terminal.deinit();
    const shell_markers = "\x1b[1;1HSHELL01\nSHELL02\nSHELL03\nSHELL04\nSHELL05\nSHELL06\nSHELL07\n$ fx";
    try terminal.feed(shell_markers);
    try app.shell.shadow_vt.?.feed(shell_markers);

    var read_offset: u64 = 0;
    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const initial_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(initial_bytes);
    try terminal.feed(initial_bytes);
    try std.testing.expectEqual(@as(u16, 8), app.shell.owned_top_row);

    try app.shell.writeTranscript(
        alloc,
        &app.metrics,
        "wrapped-00 wrapped-01 wrapped-02 wrapped-03 wrapped-04 wrapped-05 wrapped-06 wrapped-07 wrapped-08 wrapped-09 wrapped-10 wrapped-11 wrapped-12 WRAPPED_TAIL",
        true,
    );
    app.shell.render_requests.request(.footer);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app);
    const growth_bytes = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(growth_bytes);

    var stats: vt_emulator.FeedStats = .{};
    try terminal.feedWithStats(growth_bytes, &stats);

    try std.testing.expect(stats.scrolled);
    try std.testing.expect(std.mem.find(u8, growth_bytes, "\x1b[12;1H\n") != null);
    try std.testing.expect(std.mem.find(u8, growth_bytes, "\x1b[3J") == null);
    try std.testing.expect(app.shell.owned_top_row < 8);
    try std.testing.expectEqual(app.shell.owned_top_row, app.shell.viewport_top_row);
    try std.testing.expect(!(try coordinatorGridContains(terminal, "SHELL01")));
    try std.testing.expect(try coordinatorRowHasText(terminal, 1));
    try std.testing.expect(try coordinatorGridContains(terminal, "WRAPPED_TAIL"));
    try std.testing.expect(try coordinatorGridContains(terminal, "run /login"));
}

const ChildApprovalReconcileBinding = struct {
    child_id: []const u8,
};

const ChildApprovalReconcileSubagents = struct {
    depth: transcript_presentation.Depth,
    close_calls: usize = 0,

    pub fn mainApprovalBinding(
        _: *const ChildApprovalReconcileSubagents,
        prompt_id: u64,
    ) ?ChildApprovalReconcileBinding {
        if (prompt_id != 91) return null;
        return .{ .child_id = "selected-child" };
    }

    pub fn childTranscriptPresentationDepth(
        self: *const ChildApprovalReconcileSubagents,
    ) transcript_presentation.Depth {
        return self.depth;
    }

    pub fn closeChildTranscriptPresentation(
        self: *ChildApprovalReconcileSubagents,
        _: std.mem.Allocator,
    ) !bool {
        self.close_calls += 1;
        self.depth = .inline_mode;
        return true;
    }
};

const ChildApprovalReconcileApp = struct {
    alloc: std.mem.Allocator,
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    subagents: ChildApprovalReconcileSubagents,

    fn deinit(self: *ChildApprovalReconcileApp) void {
        self.approval_prompt.deinit(self.alloc);
    }
};

test "child approval arrival closes review and full transcript depths before rendering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "child-approval-handoff.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "full_transcript");

    inline for (.{
        transcript_presentation.Depth.review,
        transcript_presentation.Depth.full,
    }) |depth| {
        var app = ChildApprovalReconcileApp{
            .alloc = alloc,
            .subagents = .{ .depth = depth },
        };
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
            .id = 91,
            .label = "terminal.exec npm test",
        }));

        try std.testing.expect(try Runtime(ChildApprovalReconcileApp)
            .reconcileChildTranscriptForPresentedApproval(
            &app,
            "selected-child",
        ));

        try std.testing.expectEqual(
            transcript_presentation.Depth.inline_mode,
            app.subagents.depth,
        );
        try std.testing.expectEqual(@as(usize, 1), app.subagents.close_calls);
    }

    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "depth_transition from=review to=inline route=child trigger=approval_handoff",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "depth_transition from=full to=inline route=child trigger=approval_handoff",
    ) != null);
}

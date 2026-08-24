const std = @import("std");
const question_prompt = @import("../agent/question_prompt.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_workspace_runtime = @import("app_workspace_runtime.zig");
const app_commands = @import("app_commands.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const host = @import("../hosts/host.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const composer_insertion = @import("../input/composer_insertion.zig");
const gesture_state = @import("../input/gesture_state.zig");
const horizontal_navigation = @import("../input/horizontal_navigation.zig");
const input_action = @import("../input/input_action.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const core_input_runtime = @import("../input/runtime.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const input_reset = @import("../input/input_reset.zig");
const picker_state = @import("../input/picker_state.zig");
const paste_framing = @import("../input/paste_framing.zig");
const text_scalar = @import("../input/text_scalar.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_commands = @import("../images/image_commands.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const permission_request = @import("../permissions/permission_request.zig");
const approval_decision = @import("../permissions/approval_decision.zig");
const permissions = @import("../permissions/permissions.zig");
const session_commands = @import("../session/session_commands.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_runtime = @import("../session/session.zig");
const session_store = @import("../session/session_store.zig");
const usage_report = @import("../session/usage_report.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const file_index = @import("../workspace/file_index.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const types = @import("../shared/types.zig");
const subagent_input = @import("../subagent/input_action.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");
const test_ui_input = @import("../../ui/input/runtime.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const approval_ui = @import("../../ui/footer/approval_ui.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const registered_entities = @import("../input/registered_entities.zig");
const prompt_history_runtime = @import("prompt_history_runtime.zig");
const prompt_history_store = @import("../session/prompt_history_store.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const input_queue_runtime = @import("input_queue_runtime.zig");
const input_history_runtime = @import("input_history_runtime.zig");
const input_subagent_runtime = @import("input_subagent_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const input_paste_runtime = @import("input_paste_runtime.zig");
const input_submit_runtime = @import("input_submit_runtime.zig");
const input_approval_runtime = @import("input_approval_runtime.zig");
const input_question_runtime = @import("input_question_runtime.zig");
const input_full_transcript_runtime = @import("input_full_transcript_runtime.zig");
const input_selection_runtime = @import("input_selection_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");
const app_upgrade_runtime = @import("app_upgrade_runtime.zig");

const ModelPickerStage = picker_state.ModelPickerStage;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub const file_picker_completion_cap = input_completion_runtime.file_picker_completion_cap;
const ctrl_g_upgrade_byte: u8 = 7;
const ctrl_x_manager_byte: u8 = 24;

fn classifyResumeFailure(err: anyerror) session_catalog.ResumeFailure {
    return switch (err) {
        error.SessionBusy => .open_elsewhere,
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => .being_updated,
        else => .unavailable,
    };
}

const ExplicitModelSelection = struct {
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    has_fast_mode_token: bool = false,
};

const ExplicitModelSelectionParse = union(enum) {
    none,
    invalid,
    selection: ExplicitModelSelection,
};

fn shortcutMayMutateQueuedDraft(action: input_action.ShortcutAction) bool {
    return switch (action) {
        .move,
        .select_all,
        .copy_selection,
        .redraw,
        => false,
        .cut_selection,
        .undo,
        .redo,
        .history_previous,
        .history_next,
        .delete_backward,
        .delete_forward,
        .delete_word_left,
        .delete_whitespace_word_left,
        .delete_word_right,
        .delete_to_line_start,
        .delete_to_line_end,
        .yank,
        .insert_newline,
        => true,
    };
}

fn shortcutDeletesQueuedDraft(action: input_action.ShortcutAction) bool {
    return switch (action) {
        .delete_backward,
        .delete_forward,
        .delete_word_left,
        .delete_whitespace_word_left,
        .delete_word_right,
        .delete_to_line_start,
        .delete_to_line_end,
        => true,
        else => false,
    };
}

fn parseExplicitModelSelection(input: []const u8) ExplicitModelSelectionParse {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "/model")) return .none;
    if (trimmed.len == "/model".len) return .none;
    if (trimmed["/model".len] != ' ' and trimmed["/model".len] != '\t') return .none;

    var tokens: [4][]const u8 = undefined;
    var token_count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, trimmed["/model".len..], " \t\r\n");
    while (iterator.next()) |token| {
        if (token_count == tokens.len) return .invalid;
        tokens[token_count] = token;
        token_count += 1;
    }
    if (token_count < 2) return .none;

    const effort = types.ReasoningEffort.parse(tokens[1]) orelse return .none;

    if (token_count == 2) {
        return .{ .selection = .{
            .model = tokens[0],
            .effort = effort,
            .fast_mode = false,
            .has_fast_mode_token = false,
        } };
    }

    if (token_count != 3) return .invalid;
    const fast_mode = if (std.ascii.eqlIgnoreCase(tokens[2], "fast"))
        true
    else if (std.ascii.eqlIgnoreCase(tokens[2], "normal"))
        false
    else
        return .invalid;
    return .{ .selection = .{
        .model = tokens[0],
        .effort = effort,
        .fast_mode = fast_mode,
        .has_fast_mode_token = true,
    } };
}

fn validateExplicitModelSelection(selection: ExplicitModelSelection, capabilities: model_capabilities.Capabilities) ExplicitModelSelectionParse {
    if (!model_capabilities.reasoningEffortSupported(capabilities, selection.effort)) return .invalid;
    if (capabilities.supports_fast_mode != selection.has_fast_mode_token) return .invalid;
    return .{ .selection = selection };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const history_rt = input_history_runtime.HistoryRuntime(App);
        const subagent_rt = input_subagent_runtime.SubagentRuntime(App);
        const completion_rt = input_completion_runtime.CompletionRuntime(App);
        const paste_rt = input_paste_runtime.PasteEditRuntime(App);
        const submit_rt = input_submit_runtime.SubmitRuntime(App);
        const approval_rt = input_approval_runtime.ApprovalRuntime(App);
        const question_rt = input_question_runtime.QuestionRuntime(App);
        const interrupt_rt = input_interrupt_runtime.InterruptRuntime(App);
        const queue_rt = input_queue_runtime.Runtime(App);
        const full_transcript_rt = input_full_transcript_runtime.Runtime(App);

        const ctrl_c_exit_window_ms = gesture_state.ctrl_c_exit_window_ms;
        const ResolvedEscapeRoute = union(enum) {
            done,
            remapped_byte: u8,
        };

        const routeSlashCompletionMove = completion_rt.routeSlashCompletionMove;
        const advanceModelPickerOnSpace = completion_rt.advanceModelPickerOnSpace;
        const routeModifiedHistory = completion_rt.routeModifiedHistory;
        const routePlainVertical = completion_rt.routePlainVertical;
        const routeVisiblePickerMove = completion_rt.routeVisiblePickerMove;
        const navigateModelPicker = completion_rt.navigateModelPicker;
        const cancelApprovalOperation = approval_rt.cancelApprovalOperation;

        fn selectedChildRouteActive(app: *const App) bool {
            if (comptime @hasDecl(@TypeOf(app.subagents), "childRouteId")) {
                return app.subagents.childRouteId() != null;
            }
            return false;
        }
        const routeApprovalEscapeAction = approval_rt.routeApprovalEscapeAction;
        const routeQuestionEscapeAction = question_rt.routeQuestionEscapeAction;
        const submitQuestionBatch = question_rt.submitQuestionBatch;
        pub const rerenderQuestionBlock = question_rt.rerenderQuestionBlock;
        const finishPaste = paste_rt.finishPaste;
        const finalizePastedBlock = paste_rt.finalizePastedBlock;
        const handlePastedBytes = paste_rt.handlePastedBytes;
        const submit = submit_rt.submit;
        pub const installPromptHistory = history_rt.installPromptHistory;
        pub const loadAndInstallPromptHistory = history_rt.loadAndInstallPromptHistory;

        fn insertComposerSliceBounded(
            app: *App,
            bytes: []const u8,
            max_input_len: usize,
            preserve_model_picker: bool,
        ) !composer_insertion.InsertResult {
            const picker_policy: composer_insertion.PickerPolicy = if (preserve_model_picker)
                .preserve
            else
                .clear;
            return app.input_runtime.replacementState(&app.pending_images).replaceSelectionOrInsertSliceBounded(
                app.alloc,
                bytes,
                max_input_len,
                picker_policy,
            );
        }

        pub fn clearPendingImages(app: *App) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            image_attachments.discardImageSnapshots(app.alloc, app.pending_images.items);
            for (app.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            app.pending_images.clearRetainingCapacity();
        }

        pub fn releasePendingImages(app: *App) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            for (app.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            app.pending_images.clearRetainingCapacity();
        }

        fn routeComposerShortcutAction(app: *App, action: input_action.ShortcutAction, max_input_len: usize) !void {
            if (comptime @hasField(App, "queued_prompt_review")) {
                if (shortcutDeletesQueuedDraft(action) and try queue_rt.deleteEmptyVisibleDraft(app)) return;
                if (shortcutMayMutateQueuedDraft(action)) queue_rt.markVisibleSelectionDirty(app);
            }
            switch (action) {
                .move => |intent| {
                    switch (intent.kind) {
                        .character_left => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null and
                                !app.stream.active and
                                try completion_rt.stepBackModelPicker(app))
                            {
                                app.shell.render_requests.request(.footer);
                                return;
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .character_right => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null)
                            {
                                switch (try completion_rt.autocompleteInlineCompletion(app, max_input_len)) {
                                    .inserted => {
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                    .inactive => {},
                                    .limit_exceeded => {
                                        try input_limit_feedback.report(App, app, .composer, 1);
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                }
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .word_left,
                        .word_right,
                        .line_start,
                        .line_end,
                        .draft_start,
                        .draft_end,
                        .paragraph_up,
                        .paragraph_down,
                        => {
                            completion_rt.abandonModelPickerOptions(app);
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .visual_up,
                        .visual_down,
                        .page_up,
                        .page_down,
                        => {
                            const direction: visual_layout.Direction = switch (intent.kind) {
                                .visual_up, .page_up => .up,
                                .visual_down, .page_down => .down,
                                else => unreachable,
                            };
                            const delta: i32 = if (direction == .up) -1 else 1;
                            try completion_rt.routeComposerVertical(
                                app,
                                direction,
                                delta,
                                intent.extend_selection,
                                intent.kind == .page_up or intent.kind == .page_down,
                            );
                        },
                    }
                    app.shell.render_requests.request(.footer);
                },
                .select_all => {
                    dismissActiveMenusThenRedraw(app);
                    if (app.input_runtime.selectionState().selectAll()) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .copy_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        if (input_selection_runtime.copySelection(
                            &app.input_runtime.edit_state,
                            app.clipboard(),
                        ) == .copy_failed) {
                            debug_trace.logf(
                                "input",
                                "composer selection copy preserved reason=clipboard_copy_failed",
                                .{},
                            );
                        }
                    }
                },
                .cut_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        switch (input_selection_runtime.cutSelection(
                            app.alloc,
                            app.input_runtime.selectionState(),
                            &app.pending_images,
                            app.clipboard(),
                        )) {
                            .cut => {
                                dismissActiveMenusThenRedraw(app);
                                syncCatalogMenus(app);
                                app.shell.render_requests.request(.footer);
                            },
                            .copy_failed => debug_trace.logf(
                                "input",
                                "composer selection cut preserved reason=clipboard_copy_failed",
                                .{},
                            ),
                            .delete_failed => debug_trace.logf(
                                "input",
                                "composer selection cut delete skipped reason=delete_failed",
                                .{},
                            ),
                            .inactive, .copied => {},
                        }
                    }
                },
                .undo => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.undoState().undo(app.alloc)) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redo => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.undoState().redo(app.alloc)) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redraw => {
                    if (!composerPickerSurfaceVisible(app) or
                        activeCatalogMenuOwnsByte(app, 12)) return;
                    if (comptime @hasField(App, "pacer") and
                        @hasField(App, "metrics") and
                        @hasDecl(@TypeOf(app.pacer), "discardDeferredPresentationForVisualEpoch"))
                    {
                        _ = try app_render_runtime.Runtime(App).resetVisualEpoch(app, .ctrl_l);
                    }
                },
                .history_previous => {
                    try completion_rt.navigatePromptHistory(app, -1);
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
                .history_next => {
                    try completion_rt.navigatePromptHistory(app, 1);
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
                .delete_backward => {
                    if (app.input_runtime.edit_state.input.items.len > 0) {
                        const picker_policy: composer_insertion.PickerPolicy =
                            if (completion_rt.shouldPreserveModelPickerBackspace(app))
                                .preserve
                            else
                                .clear;
                        const changed = app.input_runtime.deletionState(
                            &app.pending_images,
                        ).delete(app.alloc, .character_left, picker_policy);
                        if (changed) {
                            app.input_runtime.picker.resetFilePickerIndex();
                            syncCatalogMenus(app);
                            app.shell.render_requests.request(.footer);
                        }
                    }
                },
                .delete_forward => {
                    dismissActiveMenusThenRedraw(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .character_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_left => {
                    dismissActiveMenusThenRedraw(app);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .word_left,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_whitespace_word_left => {
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .whitespace_word_left,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_right => {
                    dismissActiveMenusThenRedraw(app);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .word_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_start => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .line_start,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_end => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .line_end,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .yank => {
                    const first_image_id = app.peekNextImageId();
                    switch (try app.input_runtime.killRingState(&app.pending_images).yank(
                        app.alloc,
                        first_image_id,
                        max_input_len,
                    )) {
                        .inserted => |image_count| {
                            for (0..image_count) |offset| {
                                const committed_id = app.nextImageId();
                                std.debug.assert(committed_id == first_image_id + offset);
                            }
                            syncCatalogMenus(app);
                            app.shell.render_requests.request(.footer);
                        },
                        .inactive => {},
                        .limit_exceeded => |attempted_bytes| try input_limit_feedback.report(
                            App,
                            app,
                            .composer,
                            attempted_bytes,
                        ),
                    }
                },
                .insert_newline => {
                    if (commandSkillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app)) return;
                    dismissActiveMenusThenRedraw(app);
                    switch (try insertComposerSliceBounded(app, "\n", max_input_len, false)) {
                        .inserted => app.shell.render_requests.request(.footer),
                        .inactive => unreachable,
                        .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                    }
                },
            }
        }

        pub fn expireTerminalInputGestures(app: *App, now: i64) void {
            expireCtrlCExitArm(app, now);
            expireEscClearArm(app, now);
        }

        fn terminalDecodeContext(
            app: *const App,
            paste_active: bool,
        ) input_action.TerminalDecodeContext {
            if (paste_active) {
                return .{
                    .now_ms = 0,
                    .paste_active = true,
                    .cancel_pending = false,
                    .child_route_active = false,
                    .question_freeform_selected = false,
                };
            }
            return .{
                .now_ms = io_mod.milliTimestamp(),
                .paste_active = false,
                .cancel_pending = app.stream.active,
                .child_route_active = selectedChildRouteActive(app),
                .question_freeform_selected = app.question_prompt.isFreeformSelected(),
            };
        }

        pub fn prepareTerminalDecode(app: *App) !?input_action.TerminalDecodeContext {
            if (!try app_worker_runtime.Runtime(App).authorizeInteractiveAdmission(app)) return null;
            const paste_active = terminalPasteActive(app);
            return terminalDecodeContext(app, paste_active);
        }

        pub fn handleTerminalInputIngressWithLimits(
            app: *App,
            ingress: input_action.TerminalInputIngress,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !?u8 {
            if (!ingress.has_routing_work()) return null;

            const file_picker_was_active = app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null;
            defer if (comptime runtime_profile.allows(App, .file_index))
                updateFilePickerEpisode(app, file_picker_was_active);

            const paste_was_active = terminalPasteActive(app);
            defer {
                const paste_is_active = terminalPasteActive(app);
                if (!paste_was_active and paste_is_active) {
                    shell_runtime.suspendResizeCursorProbeForPaste(&app.terminal_input_runtime.terminal_cursor_probe);
                } else if (paste_was_active and !paste_is_active) {
                    shell_runtime.resumeResizeCursorProbeAfterPaste(
                        &app.terminal_input_runtime.terminal_cursor_probe,
                        io_mod.milliTimestamp(),
                    );
                }
            }

            if (ingress.interrupts_pending_text and
                text_scalar.hasPending(app.input_runtime.text_scalar))
            {
                input_reset.resetPendingTextScalarWithTrace(
                    &app.input_runtime.text_scalar,
                    "interrupted_by_non_text_input",
                );
            }

            var replay_byte = ingress.replay_byte_after_routing;
            if (ingress.event) |event| {
                switch (event) {
                    .paste_byte => |byte| {
                        const routed = try routeActivePasteByte(app, byte);
                        std.debug.assert(routed);
                    },
                    .raw => |raw| try handleRawTerminalInputWithLimits(
                        app,
                        raw,
                        input_limits,
                        max_prompt_history,
                    ),
                    .action => |decoded| {
                        switch (try routeResolvedEscapeAction(
                            app,
                            decoded.action,
                            decoded.composer_shortcut,
                            decoded.approval_focused_edit,
                            decoded.question_action,
                            decoded.subagent_action,
                            decoded.cancel_pending,
                            input_limits.composer_bytes,
                        )) {
                            .done => {},
                            .remapped_byte => |byte| {
                                std.debug.assert(replay_byte == null);
                                replay_byte = byte;
                            },
                        }
                    },
                }
            }
            return replay_byte;
        }

        pub fn flushPendingEscape(app: *App, input_escape_timeout_ms: i64) !void {
            const now = io_mod.milliTimestamp();
            expireTerminalInputGestures(app, now);
            const ingress = app.terminal_input_runtime.flushTerminalAction(
                now,
                input_escape_timeout_ms,
                terminalPasteActive(app),
            );
            if (ingress.event) |event| {
                switch (event) {
                    .action => |decoded| {
                        std.debug.assert(decoded.action == .escape);
                        disarmCtrlCExit(app, "semantic_action");
                        try resolveEscape(app, decoded.cancel_pending, now);
                    },
                    .paste_byte, .raw => unreachable,
                }
            }
        }

        pub fn handleTerminalByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        pub fn handleTerminalByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            var context = try prepareTerminalDecode(app) orelse return;
            var ingress = app.terminal_input_runtime.decodeTerminalByte(
                byte,
                context,
            );
            while (true) {
                const replay_byte = try handleTerminalInputIngressWithLimits(
                    app,
                    ingress,
                    input_limits,
                    max_prompt_history,
                );
                const replay = replay_byte orelse return;
                context = try prepareTerminalDecode(app) orelse return;
                ingress = app.terminal_input_runtime.decodeTerminalByte(replay, context);
            }
        }

        pub fn terminalPasteActive(app: *const App) bool {
            if (app.input_runtime.paste.active()) return true;
            if (comptime @hasDecl(@TypeOf(app.subagents), "managerPasteActive")) {
                return app.subagents.managerPasteActive();
            }
            return false;
        }

        pub fn routeActivePasteIngressByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !bool {
            if (!terminalPasteActive(app)) return false;
            const replay_byte = try handleTerminalInputIngressWithLimits(
                app,
                .{ .event = .{ .paste_byte = byte } },
                input_limits,
                max_prompt_history,
            );
            std.debug.assert(replay_byte == null);
            return true;
        }

        pub fn settleTerminalPasteDeliveryEpochWithLimits(
            app: *App,
            input_limits: paste_framing.InputLimits,
        ) !void {
            const paste_was_active = terminalPasteActive(app);
            if (!paste_was_active) return;
            defer if (!terminalPasteActive(app)) {
                shell_runtime.resumeResizeCursorProbeAfterPaste(
                    &app.terminal_input_runtime.terminal_cursor_probe,
                    io_mod.milliTimestamp(),
                );
            };

            if (comptime @hasDecl(@TypeOf(app.subagents), "settleManagerPasteDeliveryEpoch")) {
                if (app.subagents.managerPasteActive()) {
                    const failure_before = if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "childPresentationView",
                    ))
                        if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null
                    else
                        null;
                    const settled = app.subagents.settleManagerPasteDeliveryEpoch(app.alloc);
                    if (!settled) return;
                    if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "invalidateChildConversationProjection",
                    )) {
                        const failure_after = if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null;
                        if (!std.meta.eql(failure_before, failure_after)) {
                            app.subagents.invalidateChildConversationProjection(app.alloc);
                        }
                    }
                    app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                        app,
                        .subagent_panel,
                    );
                    return;
                }
            }

            if (app.input_runtime.paste.active()) {
                const settled = try paste_rt.settlePasteDeliveryEpoch(
                    app,
                    input_limits.forOwner(app.input_runtime.paste.owner),
                );
                if (settled and !app.input_runtime.paste.active()) syncCatalogMenus(app);
            }
        }

        fn updateFilePickerEpisode(app: *App, was_active: bool) void {
            const query = app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) orelse return;
            if (was_active) return;

            app.input_runtime.picker.resetFilePickerIndex();
            if (comptime @hasDecl(App, "fileCompletionsDependOnIndex")) {
                if (!app.fileCompletionsDependOnIndex(query.query)) return;
            }
            if (!app.input_runtime.picker.file_picker_episode_seen) {
                app.input_runtime.picker.file_picker_episode_seen = true;
                if (comptime @hasDecl(App, "isFileIndexLoading")) {
                    if (app.isFileIndexLoading()) return;
                }
            }
            if (comptime @hasDecl(App, "refreshFileIndex")) {
                app.refreshFileIndex();
            }
        }

        pub fn handleByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        fn routeActivePasteByte(
            app: *App,
            byte: u8,
        ) !bool {
            if (comptime @hasDecl(@TypeOf(app.subagents), "managerPasteActive")) {
                if (app.subagents.managerPasteActive()) {
                    const failure_before = if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "childPresentationView",
                    ))
                        if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null
                    else
                        null;
                    _ = try app.subagents.consumeManagerPasteByte(app.alloc, byte);
                    if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "invalidateChildConversationProjection",
                    )) {
                        const failure_after = if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null;
                        if (!std.meta.eql(failure_before, failure_after)) {
                            app.subagents.invalidateChildConversationProjection(app.alloc);
                        }
                    }
                    app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                        app,
                        .subagent_panel,
                    );
                    return true;
                }
            }
            if (app.input_runtime.paste.active()) {
                try paste_rt.handleActivePasteByte(app, byte);
                return true;
            }
            return false;
        }

        fn handleRawTerminalInputWithLimits(
            app: *App,
            raw: input_action.RawTerminalInput,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            const byte = raw.byte;
            const max_input_len = input_limits.composer_bytes;
            // Fire the max-level cue only when the slash menu becomes visible.
            const slash_menu_was_visible = slashMenuVisibleForCue(app);
            defer announceSlashMenuOpened(app, slash_menu_was_visible);
            if (try routeActivePasteByte(app, byte)) return;

            if (byte != 3 and byte != 0x1b) disarmCtrlCExit(app, "raw_input");

            // Non-escape input disarms the pending double-Escape clear.
            if (byte != 0x1b) {
                if (disarmEscapeClear(app)) {
                    app.shell.render_requests.request(.footer);
                }
            }

            // Ctrl-Z arrives as raw byte 26 (ISIG disabled); kitty remaps here too.
            if (byte == 26) {
                try app.suspendToJobControl();
                return;
            }

            if (comptime runtime_profile.allows(App, .native_auth)) {
                if (try app_auth_runtime.Runtime(App).routeAuthPickerByte(app, byte)) return;
            }
            if (try full_transcript_rt.routeByte(app, byte)) return;

            if (try routeActiveModalInput(app, raw, input_limits.decision_bytes)) return;
            if (byte >= 0x80) {
                try handleTextByte(app, .composer, byte, max_input_len);
                return;
            }
            if (try routeUpgradeShortcut(app, byte)) return;
            if (routePickerControlByte(app, byte)) return;

            if (isComposerEditingByte(byte, raw.composer_shortcut) and
                !activeCatalogMenuOwnsByte(app, byte) and
                dismissActiveMenusForComposerEdit(app))
            {
                app.shell.render_requests.request(.footer);
            }
            if (isComposerEditingByte(byte, raw.composer_shortcut) and
                !activeCatalogMenuOwnsByte(app, byte))
            {
                if (comptime @hasField(App, "queued_prompt_review")) {
                    queue_rt.markVisibleSelectionDirty(app);
                }
            }

            try handleComposerByte(
                app,
                byte,
                raw.composer_shortcut,
                max_input_len,
                max_prompt_history,
            );
        }

        fn routeResolvedEscapeAction(
            app: *App,
            resolved: input_action.Action,
            composer_shortcut: ?input_action.ShortcutAction,
            approval_focused_edit: ?approval_decision.DraftAction,
            question_action: ?question_prompt.Action,
            subagent_action: ?subagent_input.Action,
            was_cancel_pending: bool,
            max_input_len: usize,
        ) !ResolvedEscapeRoute {
            switch (resolved) {
                .remapped_byte, .paste_start, .paste_end, .ignore => {},
                else => disarmCtrlCExit(app, "semantic_action"),
            }

            if (resolved == .escape) {
                if (try full_transcript_rt.routeAction(app, resolved)) return .done;
                const now = io_mod.milliTimestamp();
                expireEscClearArm(app, now);
                try resolveEscape(app, was_cancel_pending, now);
                return .done;
            }

            if (app_auth_runtime.Runtime(App).routeAuthPickerEscapeAction(app, resolved)) {
                return .done;
            }

            if (try full_transcript_rt.routeAction(app, resolved)) return .done;

            if (resolved == .paste_start) {
                if (comptime @hasDecl(@TypeOf(app.subagents), "beginManagerPaste")) {
                    if (app.subagents.isViewActive()) {
                        app.subagents.beginManagerPaste();
                        app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                            app,
                            .subagent_panel,
                        );
                        return .done;
                    }
                } else if (comptime @hasDecl(@TypeOf(app.subagents), "beginChildPaste")) {
                    if (app.subagents.childRouteId() != null) {
                        app.subagents.beginChildPaste();
                        app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                            app,
                            .subagent_panel,
                        );
                        return .done;
                    }
                }
                dismissActiveMenusThenRedraw(app);
                if (comptime @hasField(App, "queued_prompt_review")) {
                    queue_rt.markVisibleSelectionDirty(app);
                }
                paste_rt.beginPaste(app, max_input_len);
                return .done;
            }

            if (resolved == .paste_end) {
                return .done;
            }

            switch (resolved) {
                .remapped_byte => |byte| return .{ .remapped_byte = byte },
                else => {},
            }

            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    if (approvalOwnsCurrentSurface(app)) {
                        try approval_rt.routeApprovalEscapeAction(
                            app,
                            resolved,
                            approval_focused_edit,
                        );
                    } else {
                        try subagent_rt.routeSubagentEscapeAction(
                            app,
                            resolved,
                            composer_shortcut,
                            subagent_action,
                        );
                    }
                    return .done;
                }
            }

            if (app.question_prompt.isActive()) {
                try question_rt.routeQuestionEscapeAction(
                    app,
                    resolved,
                    question_action,
                );
                return .done;
            }

            if (app.approval_prompt.isActive()) {
                try approval_rt.routeApprovalEscapeAction(
                    app,
                    resolved,
                    approval_focused_edit,
                );
                return .done;
            }

            if (activeCompactCommandMenu(app)) |menu| {
                try routeCompactCommandMenuEscapeAction(app, menu, resolved);
                return .done;
            }

            if (settingsMenuActive(app) and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                try changeSettingsMenuSelection(
                    app,
                    if (resolved == .cursor_left) -1 else 1,
                );
                return .done;
            }

            if (try full_transcript_rt.routeComposerAction(app, resolved)) return .done;

            if (composer_shortcut) |action| {
                try routeComposerShortcutAction(app, action, max_input_len);
                return .done;
            }

            switch (resolved) {
                .history_up => {
                    try completion_rt.routeModifiedHistory(app, .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .history_down => {
                    try completion_rt.routeModifiedHistory(app, .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_up => {
                    try completion_rt.routePlainVertical(app, .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_down => {
                    try completion_rt.routePlainVertical(app, .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_left,
                .cursor_right,
                .word_left,
                .word_right,
                .home,
                .end,
                .delete_next,
                .delete_word_left,
                .delete_word_right,
                .delete_to_line_start,
                .delete_to_line_end,
                .insert_newline,
                .composer_shortcut,
                .toggle_full_transcript,
                => unreachable,
                .page_up,
                .page_down,
                .mouse_wheel,
                .mouse_pointer,
                => {},
                .clear_line => {
                    dismissActiveMenusThenRedraw(app);
                    if (comptime @hasField(App, "queued_prompt_review")) {
                        if (try queue_rt.deleteEmptyVisibleDraft(app)) return .done;
                        queue_rt.markVisibleSelectionDirty(app);
                    }
                    if (draftHasState(app)) {
                        clearDraftState(app, "clear_line");
                        app.shell.render_requests.request(.footer);
                    }
                },
                .toggle_permission_mode => {
                    if (settingsMenuActive(app)) {
                        return .done;
                    } else if (helpMenuActive(app)) {
                        return .done;
                    } else if (try toggleSessionPickerScopeIfActive(app)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, -1) or cycleSkillsMenuSource(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    } else {
                        try app_permission_runtime.Runtime(App).toggleMode(app);
                    }
                },
                .open_all_sessions => {
                    if (comptime @hasField(App, "session_persistence") and
                        runtime_profile.allows(App, .durable_sessions))
                    {
                        if (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app)) return .done;
                        if (try refuseSessionActionWithDraft(app, "submit or clear the draft before switching sessions")) return .done;
                        dismissActiveMenusThenRedraw(app);
                        try app_session_runtime.Runtime(App).openAllSessionPicker(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .paste_start => dismissActiveMenusThenRedraw(app),
                .paste_end => {},
                .remapped_byte => unreachable,
                .escape => unreachable,
                .ignore => {},
            }
            return .done;
        }

        fn routePickerControlByte(app: *App, byte: u8) bool {
            if (!composerPickerSurfaceVisible(app)) return false;
            const delta = pickerControlDelta(byte) orelse return false;
            if (!routeVisiblePickerMove(app, delta)) return false;
            app.input_runtime.vertical_navigation.reset();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn pickerControlDelta(byte: u8) ?i32 {
            return switch (byte) {
                10 => 1,
                11 => -1,
                else => null,
            };
        }

        fn composerPickerSurfaceVisible(app: *App) bool {
            if (app.question_prompt.isActive() or approvalOwnsCurrentSurface(app)) return false;
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return false;
            }
            return true;
        }

        fn routeUpgradeShortcut(app: *App, byte: u8) !bool {
            if (byte != ctrl_g_upgrade_byte) return false;
            if (comptime @hasDecl(App, "applyReadyUpgradeShortcut")) {
                try app.applyReadyUpgradeShortcut();
            }
            return true;
        }

        fn routeActiveModalInput(
            app: *App,
            raw: input_action.RawTerminalInput,
            max_input_len: usize,
        ) !bool {
            const byte = raw.byte;
            if ((app.question_prompt.isActive() or approvalOwnsCurrentSurface(app)) and byte == ctrl_g_upgrade_byte) {
                _ = try routeUpgradeShortcut(app, byte);
                return true;
            }
            // A presented child approval is resolvable from the main chat or
            // the manager, so only that exact modal may delegate Ctrl-X.
            if ((comptime runtime_profile.allows(App, .subagents)) and
                app.approval_prompt.isActive() and
                byte == ctrl_x_manager_byte and
                presentedSubagentApproval(app))
            {
                try subagent_rt.toggleSubagentView(app);
                return true;
            }
            if (app.question_prompt.isActive()) {
                if (byte >= 0x80) {
                    if (app.question_prompt.isFreeformSelected()) {
                        try handleTextByte(app, .question_freeform, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "question_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.question_action) |action| {
                    switch (try question_rt.handleQuestionActionBounded(
                        app,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, 1),
                    }
                }
                return true;
            }
            if (approvalOwnsCurrentSurface(app)) {
                if (byte >= 0x80) {
                    if (app.approval_prompt.isAmending()) {
                        try handleTextByte(app, .approval_amendment, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "approval_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.approval_action) |action| {
                    switch (try approval_rt.handlePermissionActionBounded(
                        app,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .approval_amendment, 1),
                    }
                }
                return true;
            }
            if (activeCompactCommandMenu(app)) |menu| {
                if (byte >= 0x80) {
                    input_reset.resetPendingTextScalarWithTrace(
                        &app.input_runtime.text_scalar,
                        "compact_command_menu_active",
                    );
                    return true;
                }
                switch (byte) {
                    '\r' => try submitCompactCommandMenuSelection(app, menu, max_input_len),
                    'r', 'R' => if (menu == .usage) {
                        if (comptime runtime_profile.allows(App, .profile_usage)) {
                            try refreshUsageMenu(
                                app,
                                app.input_runtime.usage_menu.navigationScope(),
                            );
                        }
                    },
                    10 => {
                        _ = moveCompactCommandMenu(app, menu, 1);
                        app.shell.render_requests.request(.footer);
                    },
                    11 => {
                        _ = moveCompactCommandMenu(app, menu, -1);
                        app.shell.render_requests.request(.footer);
                    },
                    else => {},
                }
                return true;
            }
            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    try subagent_rt.handleSubagentRawInput(app, raw);
                    return true;
                }
            }
            return false;
        }

        fn presentedSubagentApproval(app: *const App) bool {
            if (comptime !@hasField(App, "subagents")) return false;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "mainApprovalPresented")) {
                return false;
            }
            return app.subagents.mainApprovalPresented();
        }

        fn approvalOwnsCurrentSurface(app: *const App) bool {
            if (!app.approval_prompt.isActive()) return false;
            if (!app.subagents.isViewActive()) return true;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "childRouteId") or
                !@hasDecl(@TypeOf(app.subagents), "mainApprovalBinding"))
            {
                return true;
            }
            const child_id = app.subagents.childRouteId() orelse return false;
            const request = app.approval_prompt.request orelse return false;
            const binding = app.subagents.mainApprovalBinding(request.id) orelse return false;
            return std.mem.eql(u8, binding.child_id, child_id);
        }

        fn handleTextByte(app: *App, owner: text_scalar.Owner, byte: u8, max_input_len: usize) !void {
            const transition = text_scalar.advance(app.input_runtime.text_scalar, owner, byte);
            app.input_runtime.text_scalar = transition.next;
            const step = transition.step;
            if (step.dropped) |drop| {
                debug_trace.logf(
                    "input",
                    "text scalar dropped owner={s} bytes={d} reason={s}",
                    .{ @tagName(drop.owner), drop.bytes, @tagName(drop.reason) },
                );
            }
            const scalar = step.scalar orelse return;
            const bytes = scalar.slice();
            switch (scalar.owner) {
                .question_freeform => switch (try app.question_prompt.insertFreeformSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, bytes.len),
                },
                .approval_amendment => switch (try app.approval_prompt.decision.insertAmendmentSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .approval_amendment, bytes.len),
                },
                .composer => {
                    if (!app.input_runtime.replacementState(&app.pending_images).canReplaceSelectionOrInsert(
                        bytes.len,
                        max_input_len,
                    )) {
                        try input_limit_feedback.report(App, app, .composer, bytes.len);
                        return;
                    }
                    if (dismissActiveMenusForComposerEdit(app)) {
                        app.shell.render_requests.request(.footer);
                    }
                    if (comptime @hasField(App, "queued_prompt_review")) {
                        queue_rt.markVisibleSelectionDirty(app);
                    }
                    switch (try insertComposerSliceBounded(
                        app,
                        bytes,
                        max_input_len,
                        completion_rt.shouldPreserveModelPickerInsert(app),
                    )) {
                        .inserted => {},
                        .inactive => unreachable,
                        .limit_exceeded => {
                            try input_limit_feedback.report(App, app, .composer, bytes.len);
                            return;
                        },
                    }
                    app.input_runtime.picker.resetFilePickerIndex();
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
            }
        }

        fn handleComposerByte(
            app: *App,
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
            max_input_len: usize,
            max_prompt_history: usize,
        ) !void {
            switch (byte) {
                3 => {
                    try handleSemanticCtrlC(app);
                },
                4 => {
                    try handleSemanticCtrlD(app, max_input_len);
                },
                '\t' => {
                    if (comptime @hasField(App, "queued_prompt_review")) {
                        queue_rt.markVisibleSelectionDirty(app);
                    }
                    if (helpMenuActive(app) or settingsMenuActive(app)) {
                        return;
                    } else if (moveAuthPickerIfActive(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, 1) or cycleSkillsMenuSource(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (completion_rt.hasFileQuery(app)) {
                        if ((try completion_rt.autocompleteFilePickerSelection(app, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!commandSkillsMenuActive(app) and completion_rt.hasModelQuery(app)) {
                        // Mid-turn: list is hidden — do not autocomplete a hidden index.
                        if (!app.stream.active) {
                            try completion_rt.autocompleteModelPickerSelection(app);
                        }
                    } else if (completion_rt.visibleInlineCompletion(app) != null) {
                        if ((try completion_rt.autocompleteInlineCompletion(app, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!(app.stream.active and app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state))) {
                        const count = completion_rt.visibleSlashCompletionCount(app);
                        if (count > 0) {
                            const items = app.input_runtime.edit_state.input.items;
                            const prefix = command_specs.slashCompletionPrefix(
                                app.slashRegistry(),
                                items,
                            ) orelse return;
                            const idx = app.input_runtime.picker.slash_completion_index % count;
                            if (try bindSelectedSlashSkill(app, idx)) {
                                app.shell.render_requests.request(.footer);
                            } else if (command_specs.nthSlashCompletion(app.slashRegistry(), prefix, idx)) |completion| {
                                if (command_specs.slashCompletionHasArgs(app.slashRegistry(), completion)) {
                                    var buf: [128]u8 = undefined;
                                    const with_space = std.fmt.bufPrint(&buf, "{s} ", .{completion}) catch completion;
                                    try app.input_runtime.textReplacementState().replace(app.alloc, with_space);
                                } else {
                                    try app.input_runtime.textReplacementState().replace(app.alloc, completion);
                                }
                                app.shell.render_requests.request(.footer);
                            }
                        }
                    }
                },
                ' ' => {
                    dismissMentionSkillsMenuForSpace(app);
                    if (app.input_runtime.edit_state.selectionRange() == null and
                        !commandSkillsMenuActive(app) and
                        completion_rt.hasModelQuery(app))
                    {
                        if (try completion_rt.advanceModelPickerOnSpace(app)) {
                            app.shell.render_requests.request(.footer);
                        }
                    } else {
                        switch (try insertComposerSliceBounded(app, " ", max_input_len, false)) {
                            .inserted => {
                                syncCatalogMenus(app);
                                app.shell.render_requests.request(.footer);
                            },
                            .inactive => unreachable,
                            .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                        }
                    }
                },
                22 => {
                    try image_commands.Commands(App).attachClipboard(app);
                },
                24 => {
                    if (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app)) return;
                    if (comptime runtime_profile.allows(App, .subagents)) {
                        try subagent_rt.toggleSubagentView(app);
                    }
                },
                '\r' => {
                    if (try submitSettingsMenuSelection(app)) return;
                    if (try submitHelpMenuSelection(app, max_input_len, max_prompt_history)) return;
                    if (try submitAuthPickerSelection(app)) return;
                    if (try submitModelMenuSelection(app)) return;
                    if (try submitSkillsMenuSelection(app, max_input_len)) return;
                    if (try submitSlashSkillSelection(app)) return;
                    if (comptime runtime_profile.allows(App, .durable_sessions)) {
                        if (try submitSessionPickerSelection(app)) return;
                    }
                    if (try completion_rt.submitFilePickerOnEnter(app, max_input_len)) |result| {
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    if (picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try completion_rt.openCurrentModelPicker(app);
                        return;
                    }
                    if (completion_rt.hasModelQuery(app)) {
                        if (app.stream.active) {
                            if (try submitExplicitModelSelection(
                                app,
                                resolveExplicitModelSelection(app, app.input_runtime.edit_state.input.items),
                            )) return;
                            try app.writeDomainNotice(.{
                                .topic = "model",
                                .tone = .neutral,
                                .body = "Complete the model selection for the next turn: /model <id> <effort> [normal|fast].",
                            }, true);
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                        if (try completion_rt.submitModelPicker(app)) return;
                    }
                    if (try submitExplicitModelSelection(
                        app,
                        resolveExplicitModelSelection(app, app.input_runtime.edit_state.input.items),
                    )) return;
                    if (app.input_runtime.lineContinuationState().replaceBackslashBeforeCursorWithNewline(app.alloc)) {
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    debug_trace.logf("input", "submit requested stream_active={s} queued={d} input_bytes={d}", .{ if (app.stream.active) "true" else "false", app.worker.queuedPromptCount(), app.input_runtime.edit_state.input.items.len });
                    try submit_rt.submitInput(app, max_prompt_history);
                },
                else => {
                    if (composer_shortcut) |action| {
                        try routeComposerShortcutAction(app, action, max_input_len);
                        return;
                    }
                    if (byte >= 32 and byte != 127) {
                        const insertion_start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                            selection.start
                        else
                            app.input_runtime.edit_state.cursor;
                        if (byte == '$' and insertion_start == 0 and !helpMenuActive(app) and !commandSkillsMenuActive(app) and !modelMenuActive(app)) {
                            if ((try insertComposerSliceBounded(app, &.{byte}, max_input_len, false)) == .limit_exceeded) {
                                try input_limit_feedback.report(App, app, .composer, 1);
                                return;
                            }
                            if (comptime @hasField(App, "skills")) {
                                app.skills.openMenuWithQuery(.dollar, .{ .start = insertion_start, .end = insertion_start + 1 }, "");
                            }
                            app.input_runtime.picker.resetFilePickerIndex();
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                        const result = try insertComposerSliceBounded(
                            app,
                            &.{byte},
                            max_input_len,
                            completion_rt.shouldPreserveModelPickerInsert(app),
                        );
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                            return;
                        }
                        app.input_runtime.picker.resetFilePickerIndex();
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
            }
        }

        fn handleSemanticCtrlC(app: *App) !void {
            const now = io_mod.milliTimestamp();
            const transition = gesture_state.pressCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                app_session_runtime.Runtime(App).requestResumeHandoff(app);
                app.should_exit = true;
                return;
            }

            debug_trace.logf("input", "ctrl_c_exit_hint_armed", .{});

            if (app.stream.active) {
                try interrupt_rt.cancelActiveOperation(app);
                app.shell.render_requests.request(.footer);
                return;
            }

            if (draftHasState(app)) clearDraftState(app, "ctrl_c");
            app.shell.render_requests.request(.footer);
        }

        fn draftHasState(app: *App) bool {
            return app.input_runtime.edit_state.input.items.len > 0 or
                app.input_runtime.entities.pasted_blocks.items.len > 0 or
                app.pending_images.items.len > 0;
        }

        fn refuseSessionActionWithDraft(app: *App, body: []const u8) !bool {
            if (!draftHasState(app)) return false;
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .neutral,
                .body = body,
            }, true);
            return true;
        }

        fn clearDraftState(app: *App, reason: []const u8) void {
            debug_trace.logf(
                "input",
                "draft cleared reason={s} input_bytes={d} pasted_blocks={d} images={d}",
                .{
                    reason,
                    app.input_runtime.edit_state.input.items.len,
                    app.input_runtime.entities.pasted_blocks.items.len,
                    app.pending_images.items.len,
                },
            );
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.clearPendingImages();
            syncCatalogMenus(app);
        }

        fn handleSemanticCtrlD(app: *App, max_input_len: usize) !void {
            if (app.input_runtime.edit_state.input.items.len > 0) {
                try routeComposerShortcutAction(app, .delete_forward, max_input_len);
                return;
            }
            if (app.stream.active) return;
            app_session_runtime.Runtime(App).requestResumeHandoff(app);
            app.should_exit = true;
        }

        fn isComposerEditingByte(
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
        ) bool {
            if (composer_shortcut) |shortcut| {
                return switch (shortcut) {
                    .redraw => false,
                    else => true,
                };
            }
            return switch (byte) {
                ' ', 22 => true,
                else => byte >= 32 and byte != 127,
            };
        }

        fn activeCatalogMenuOwnsByte(app: *App, byte: u8) bool {
            if (settingsMenuActive(app)) return true;
            if (helpMenuActive(app)) return true;
            if (modelMenuActive(app)) return true;
            if (sessionMenuActive(app)) return true;
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            return byte == ' ' or commandSkillsMenuActive(app);
        }

        fn moveAuthPickerIfActive(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            return app.auth.movePicker(delta);
        }

        fn submitSessionPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;

            if (app.loadMoreSessionPicker() catch |err| {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
                    "unable to load more saved sessions: {s}",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = notice }, true);
                app.shell.render_requests.request(.footer);
                return true;
            }) return true;

            if (app.session_persistence.session_picker.selectedId() == null) return true;

            _ = app.resumeSelectedSession() catch |err| {
                const picker = &app.session_persistence.session_picker;
                debug_trace.logf(
                    "session",
                    "picker resume failed err={s} picker_active={s}",
                    .{ @errorName(err), if (picker.active) "true" else "false" },
                );
                if (picker.active) {
                    picker.selection_failure = classifyResumeFailure(err);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "session",
                        .tone = .@"error",
                        .body = "Unable to resume selected session.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return true;
            };
            return true;
        }

        fn dismissAuthPickerForComposerEdit(app: *App) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (!app.auth.pickerView().active) return false;
            app.auth.closePicker(app.alloc);
            return true;
        }

        fn popOrCloseAuthPicker(app: *App) bool {
            if (comptime !@hasField(App, "auth")) return false;
            const picker = app.auth.pickerView();
            if (!picker.active) return false;
            if (picker.stage == .root and picker.include_skip) app.auth.skipOnboarding();
            return app.auth.popPickerStage(app.alloc);
        }

        fn dismissSkillsMenuForComposerEdit(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            if (isMentionSkillsMenuOrigin(app.skills.menu.origin) or commandSkillsMenuActive(app)) return false;
            app.skills.closeMenu();
            return true;
        }

        fn isMentionSkillsMenuOrigin(origin: skill_runtime.SkillMenuOrigin) bool {
            return origin == .dollar or origin == .paste;
        }

        fn isCommandSkillsMenuOrigin(origin: skill_runtime.SkillMenuOrigin) bool {
            return origin == .command or origin == .slash;
        }

        fn commandSkillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menu.active and isCommandSkillsMenuOrigin(app.skills.menu.origin);
        }

        fn skillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menu.active;
        }

        fn modelMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            return app.model_cache.menu.active;
        }

        fn sessionMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            return app.session_persistence.session_picker.active;
        }

        fn helpMenuActive(app: *App) bool {
            return app.input_runtime.help_menu.active;
        }

        fn settingsMenuActive(app: *App) bool {
            return app.input_runtime.settings_menu.active;
        }

        const CompactCommandMenuKind = enum {
            statusline,
            usage,
            workspace,
        };

        fn activeCompactCommandMenu(app: *App) ?CompactCommandMenuKind {
            if (app.input_runtime.statusline_menu.active) return .statusline;
            if (app.input_runtime.usage_menu.active) return .usage;
            if (app.input_runtime.workspace_menu.active) return .workspace;
            return null;
        }

        // A space never extends a mention token, so it ends the mention and
        // inserts through the normal composer path.
        fn dismissMentionSkillsMenuForSpace(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!isMentionSkillsMenuOrigin(app.skills.menu.origin)) return;
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn closeSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            app.skills.closeMenu();
            return true;
        }

        fn closeHelpMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.help_menu.active) return false;
            app.input_runtime.help_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeSettingsMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.settings_menu.active) return false;
            app.input_runtime.settings_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeModelMenu(app: *App, clear_query: bool) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            app.model_cache.closeMenu();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn toggleSessionPickerScopeIfActive(app: *App) !bool {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return false;
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;
            return try app_session_runtime.Runtime(App).toggleSessionPickerScope(app);
        }

        fn dismissActiveMenusForComposerEdit(app: *App) bool {
            var dismissed = dismissAuthPickerForComposerEdit(app);
            dismissed = dismissSkillsMenuForComposerEdit(app) or dismissed;
            return dismissed;
        }

        fn dismissActiveMenusThenRedraw(app: *App) void {
            if (dismissActiveMenusForComposerEdit(app)) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn submitSkillsMenuSelection(app: *App, max_input_len: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            // Captured before the sync: a stale $ anchor makes the sync close
            // the menu, and close() resets origin to .command.
            const origin = app.skills.menu.origin;
            syncSkillsMenu(app);
            const skill = app.skills.selectedMenuSkill() orelse {
                if (isMentionSkillsMenuOrigin(origin)) {
                    app.skills.closeMenu();
                    app.shell.render_requests.request(.footer);
                    return false;
                }
                return true;
            };
            const target = if (isCommandSkillsMenuOrigin(origin))
                skill_runtime.SkillMenuTarget{ .start = 0, .end = app.input_runtime.edit_state.input.items.len }
            else
                app.skills.menu.target orelse skill_runtime.SkillMenuTarget{
                    .start = app.input_runtime.edit_state.cursor,
                    .end = app.input_runtime.edit_state.cursor,
                };
            const raw_len = app.input_runtime.entities.skillTokenInsertedLen(
                app.input_runtime.edit_state.input.items,
                target.end,
                skill.name,
            );
            if (!app.input_runtime.insertionState().canReplaceRange(
                target.start,
                target.end,
                raw_len,
                max_input_len,
            )) {
                app.skills.closeMenu();
                app.shell.render_requests.request(.footer);
                try input_limit_feedback.report(App, app, .composer, raw_len);
                return true;
            }

            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                target.start,
                target.end,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn changeSettingsMenuSelection(app: *App, delta: i32) !void {
            const menu = &app.input_runtime.settings_menu;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    if (delta < 0) try applyInlineSettingsModelSelection(app);
                    return;
                }
            }

            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const query = app.input_runtime.edit_state.input.items;
            const item = menu.selectedItem(&snapshot, query) orelse return;
            if (item.id == .model) {
                if (delta > 0 and comptime @hasField(App, "model_cache")) {
                    if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
                    try app.model_cache.openMenu();
                    app.shell.render_requests.request(.footer);
                }
                return;
            }

            const change = menu.changeSelectedOption(&snapshot, query, delta) orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn applyInlineSettingsModelSelection(app: *App) !void {
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse return;
            defer app.alloc.free(selected);
            try session_commands.Commands(App).selectModelFromPicker(
                app,
                selected,
                app.effort,
                app.fast_mode,
            );
            app.model_cache.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn submitSettingsMenuSelection(app: *App) !bool {
            if (!settingsMenuActive(app)) return false;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    try applyInlineSettingsModelSelection(app);
                    return true;
                }

                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const selected = app.input_runtime.settings_menu.selectedItem(
                    &snapshot,
                    app.input_runtime.edit_state.input.items,
                ) orelse return true;
                if (selected.id == .model) {
                    if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
                    try app.model_cache.openMenu();
                    app.shell.render_requests.request(.footer);
                }
            }
            return true;
        }

        fn submitCompactCommandMenuSelection(
            app: *App,
            menu: CompactCommandMenuKind,
            max_input_len: usize,
        ) !void {
            if (menu == .workspace) {
                try prepareWorkspaceMenuCommand(app, max_input_len);
                return;
            }
            if (menu == .usage) {
                _ = app.input_runtime.usage_menu.toggleExpanded(
                    app.shell.layout.rows,
                );
                app.shell.render_requests.request(.footer);
                return;
            }
            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const change = switch (menu) {
                .statusline => app.input_runtime.statusline_menu.selectedChange(snapshot),
                .usage, .workspace => unreachable,
            } orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogMenuChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn prepareWorkspaceMenuCommand(app: *App, max_input_len: usize) !void {
            if (comptime !@hasDecl(App, "workspaceAccess")) return;
            const entries = app.workspaceAccess().entries;
            const action = app.input_runtime.workspace_menu.selectedAction(entries) orelse return;

            var command: std.Io.Writer.Allocating = .init(app.alloc);
            defer command.deinit();
            switch (action) {
                .add => try command.writer.writeAll("/workspace add "),
                .remove => |index| {
                    if (index >= entries.len) return;
                    try command.writer.print("/workspace remove {s}", .{entries[index].path});
                },
                .clear => try command.writer.writeAll("/workspace clear"),
            }
            const text = command.written();
            if (text.len > max_input_len) return;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                text,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.workspace_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            app.input_runtime.picker.dismissInlinePicker(.slash);
            app.shell.render_requests.request(.footer);
        }

        fn moveCompactCommandMenu(app: *App, menu: CompactCommandMenuKind, delta: i32) bool {
            return switch (menu) {
                .statusline => app.input_runtime.statusline_menu.move(delta),
                .usage => app.input_runtime.usage_menu.moveModel(
                    delta,
                    app.shell.layout.rows,
                ),
                .workspace => if (comptime @hasDecl(App, "workspaceAccess"))
                    app.input_runtime.workspace_menu.move(
                        delta,
                        app.workspaceAccess().entries,
                    )
                else
                    false,
            };
        }

        fn routeCompactCommandMenuEscapeAction(
            app: *App,
            menu: CompactCommandMenuKind,
            resolved: input_action.Action,
        ) !void {
            if (menu == .usage and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const current = app.input_runtime.usage_menu.navigationScope();
                const next = if (resolved == .cursor_left)
                    current.previous()
                else
                    current.next();
                if (next != current) {
                    try refreshUsageMenu(app, next);
                }
                return;
            }
            if (menu == .statusline and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const delta: i32 = if (resolved == .cursor_left) -1 else 1;
                const change = switch (menu) {
                    .statusline => app.input_runtime.statusline_menu.changeSelectedOption(&snapshot, delta),
                    .usage, .workspace => unreachable,
                } orelse return;
                if (comptime @hasDecl(App, "notificationPreferences")) {
                    try app_commands.applySettingsCatalogMenuChange(app, change);
                }
                return;
            }
            const delta: i32 = switch (resolved) {
                .cursor_up => -1,
                .cursor_down => 1,
                else => return,
            };
            _ = moveCompactCommandMenu(app, menu, delta);
            app.shell.render_requests.request(.footer);
        }

        fn refreshUsageMenu(app: *App, scope: usage_report.Scope) !void {
            if (comptime !runtime_profile.allows(App, .profile_usage)) return;
            if (comptime @hasDecl(App, "refreshUsageMenu")) {
                try app.refreshUsageMenu(scope);
            } else {
                try app_commands.Handlers(App).refreshUsageMenu(app, scope);
            }
        }

        fn submitHelpMenuSelection(app: *App, max_input_len: usize, max_prompt_history: usize) !bool {
            if (!app.input_runtime.help_menu.active) return false;
            if (app.slashRegistry().matchExact(app.input_runtime.edit_state.input.items) != null) {
                app.input_runtime.help_menu.close();
                return false;
            }
            const selected = app.input_runtime.help_menu.selectedSpec(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            ) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            const inserted_len = selected.command.len + @intFromBool(selected.has_args);
            if (inserted_len > max_input_len) return true;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                selected.command,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.help_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            if (selected.has_args) {
                try app.input_runtime.insertionState().insertByte(app.alloc, ' ', .clear);
                app.shell.render_requests.request(.footer);
                return true;
            }
            try submit_rt.submitInput(app, max_prompt_history);
            return true;
        }

        fn submitModelMenuSelection(app: *App) !bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            defer app.alloc.free(selected);

            app.model_cache.closeMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            try completion_rt.beginExactModelSelection(app, selected);
            return true;
        }

        fn submitAuthPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            if (!app.auth.pickerView().active) return false;
            const choice = app.auth.takePickerChoice(app.alloc) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.applyAuthPickerChoice(choice) catch |err| {
                debug_trace.logf("auth", "picker choice failed choice={s} err={s}", .{ @tagName(choice), @errorName(err) });
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not load that credential. The current source is unchanged.",
                }, true);
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn submitSlashSkillSelection(app: *App) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (nonSlashPickerOwnsEnter(app)) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            if (app.slashRegistry().matchExact(prefix) != null) return false;
            const count = completion_rt.visibleSlashCompletionCount(app);
            if (count == 0) return false;
            const idx = app.input_runtime.picker.slash_completion_index % count;
            return try bindSelectedSlashSkill(app, idx);
        }

        fn nonSlashPickerOwnsEnter(app: *App) bool {
            if (completion_rt.filePickerOwnsSurface(app)) return true;
            // Bare `/model` and `/model …` own Enter over slash/skill bind. Mid-turn
            // commit is gated separately when the model list stays hidden.
            if (app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state)) return true;
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) return false;
            }
            if (comptime @hasField(App, "session_persistence")) {
                if (app.session_persistence.session_picker.active) return true;
            }
            if (comptime @hasField(App, "auth")) {
                if (app.auth.pickerView().active) return true;
            }
            return false;
        }

        fn resolveExplicitModelSelection(app: *App, input: []const u8) ExplicitModelSelectionParse {
            return switch (parseExplicitModelSelection(input)) {
                .selection => |selection| validateExplicitModelSelection(selection, model_capabilities.resolveForApp(App, app, selection.model)),
                .none => .none,
                .invalid => .invalid,
            };
        }

        fn submitExplicitModelSelection(
            app: *App,
            parsed: ExplicitModelSelectionParse,
        ) !bool {
            switch (parsed) {
                .none => return false,
                .invalid => {
                    try app.writeDomainNotice(.{
                        .topic = "model",
                        .tone = .@"error",
                        .body = "Invalid /model selection. Use /model <id> <effort> [normal|fast].",
                    }, true);
                },
                .selection => |selection| {
                    try session_commands.Commands(App).selectModelFromPicker(
                        app,
                        selection.model,
                        selection.effort,
                        selection.fast_mode,
                    );
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                },
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn bindSelectedSlashSkill(app: *App, selected_index: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            const skill = picker_presentation.nthMixedSlashCompletionSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                selected_index,
            ) orelse return false;
            const leading_ws = items.len - prefix.len;
            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                leading_ws,
                leading_ws + prefix.len,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.input_runtime.picker.resetInlinePickerEpisode();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn syncCatalogMenus(app: *App) void {
            syncSettingsMenu(app);
            syncHelpMenu(app);
            syncSkillsMenu(app);
            syncModelMenu(app);
            syncSessionMenu(app);
        }

        fn syncSettingsMenu(app: *App) void {
            if (!app.input_runtime.settings_menu.active) return;
            app.input_runtime.settings_menu.resetForQuery();
        }

        fn syncHelpMenu(app: *App) void {
            if (!app.input_runtime.help_menu.active) return;
            app.input_runtime.help_menu.resetForQuery();
        }

        fn syncSkillsMenu(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (isCommandSkillsMenuOrigin(app.skills.menu.origin)) {
                app.skills.menu.setQuery(app.input_runtime.edit_state.input.items);
                app.skills.menu.clamp(app.skills.items);
                return;
            }
            const target = app.skills.menu.target orelse return;
            const items = app.input_runtime.edit_state.input.items;
            if (target.start >= items.len or items[target.start] != '$') {
                app.skills.closeMenu();
                return;
            }
            const end = skillTokenEnd(items, target.start + 1);
            app.skills.menu.target = .{ .start = target.start, .end = end };
            app.skills.menu.setQuery(items[target.start + 1 .. end]);
            app.skills.menu.clamp(app.skills.items);
        }

        fn syncModelMenu(app: *App) void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (!app.model_cache.menu.active) return;
            app.model_cache.setMenuQuery(app.input_runtime.edit_state.input.items);
        }

        fn syncSessionMenu(app: *App) void {
            if (comptime !@hasField(App, "session_persistence")) return;
            const picker = &app.session_persistence.session_picker;
            if (!picker.active) return;
            picker.setQuery(app.input_runtime.edit_state.input.items);
        }

        fn skillTokenEnd(items: []const u8, start: usize) usize {
            var end = start;
            while (end < items.len) : (end += 1) {
                const byte = items[end];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) break;
            }
            return end;
        }

        fn cycleSkillsMenuSource(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            return app.skills.moveMenuSourceFilter(delta);
        }

        fn slashMenuVisibleForCue(app: *App) bool {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return false;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return false;
            }
            return completion_rt.slashCompletionCount(app) > 0;
        }

        fn announceSlashMenuOpened(app: *App, was_visible: bool) void {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return;
            }
            if (was_visible) return;
            if (completion_rt.slashCompletionCount(app) == 0) return;
            app.playSlashMenuSound();
        }

        fn cycleModelMenuProvider(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            _ = app.model_cache.menu.moveProvider(delta);
            return true;
        }

        fn cycleSettingsMenuCategory(app: *App, delta: i32) bool {
            return app.input_runtime.settings_menu.cycleCategory(delta);
        }

        fn expireEscClearArm(app: *App, now: i64) void {
            const transition = gesture_state.expireEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn expireCtrlCExitArm(app: *App, now: i64) void {
            const transition = gesture_state.expireCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason=timeout",
                    .{},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmCtrlCExit(app: *App, reason: []const u8) void {
            const transition = gesture_state.disarmCtrlCExit(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason={s}",
                    .{reason},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmEscapeClear(app: *App) bool {
            const transition = gesture_state.disarmEscapeClear(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            return transition.cleared;
        }

        fn resolveEscape(app: *App, was_cancel_pending: bool, now: i64) !void {
            if (try full_transcript_rt.routeAction(app, .escape)) return;
            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    _ = disarmEscapeClear(app);
                    if (approvalOwnsCurrentSurface(app)) {
                        if (was_cancel_pending) {
                            try approval_rt.cancelApprovalOperation(app);
                        }
                        return;
                    }
                    try subagent_rt.routeSubagentEscapeAction(
                        app,
                        .escape,
                        null,
                        .escape,
                    );
                    return;
                }
            }
            if (was_cancel_pending) {
                if (app.question_prompt.isActive()) {
                    // Freeform answers mirror the composer's Esc contract:
                    // Esc on a non-empty draft arms, a second press within
                    // the window clears it, and only an empty field lets
                    // Esc cancel the batch.
                    if (app.question_prompt.freeformDraftLen() > 0) {
                        const transition = gesture_state.pressEscapeClear(
                            app.input_runtime.gestures,
                            now,
                        );
                        app.input_runtime.gestures = transition.next;
                        if (transition.result == .activated) {
                            app.question_prompt.clearFreeformDraft("escape_clear");
                        }
                        app.shell.render_requests.request(.modal);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    try question_rt.cancelQuestionPrompt(app);
                    return;
                }
                if (app.approval_prompt.isActive()) {
                    try approval_rt.cancelApprovalOperation(app);
                    _ = disarmEscapeClear(app);
                    return;
                }
                if (cancelCompactCommandMenu(app) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app)) {
                    _ = disarmEscapeClear(app);
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (completion_rt.dismissVisibleInlinePicker(app)) {
                    _ = disarmEscapeClear(app);
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (comptime @hasField(App, "queued_prompt_review")) {
                    if (try queue_rt.hideVisibleDraft(app)) {
                        _ = disarmEscapeClear(app);
                        return;
                    }
                }
                if (!interrupt_rt.pauseActiveRecovery(app)) {
                    try interrupt_rt.cancelActiveOperation(app);
                }
                _ = disarmEscapeClear(app);
                return;
            }

            if (app.approval_prompt.isActive()) {
                _ = disarmEscapeClear(app);
                return;
            }
            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    _ = disarmEscapeClear(app);
                    try subagent_rt.routeSubagentEscapeAction(
                        app,
                        .escape,
                        null,
                        .escape,
                    );
                    return;
                }
            }
            if (cancelCompactCommandMenu(app) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (popOrCloseAuthPicker(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (completion_rt.dismissVisibleInlinePicker(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (comptime @hasField(App, "queued_prompt_review")) {
                if (try queue_rt.hideVisibleDraft(app)) {
                    _ = disarmEscapeClear(app);
                    return;
                }
                if (queue_rt.cancelAllHiddenPostCancelQueued(app)) {
                    _ = disarmEscapeClear(app);
                    return;
                }
            }
            if (!draftHasState(app)) {
                _ = disarmEscapeClear(app);
                return;
            }
            const transition = gesture_state.pressEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                clearDraftState(app, "double_escape");
                app.shell.render_requests.request(.footer);
                if (comptime @hasDecl(App, "playInputClearedSound")) app.playInputClearedSound();
            } else {
                app.shell.render_requests.request(.footer);
            }
        }

        fn cancelSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            const clear_query = isCommandSkillsMenuOrigin(app.skills.menu.origin);
            app.skills.closeMenu();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn cancelCompactCommandMenu(app: *App) bool {
            if (app.input_runtime.statusline_menu.active) {
                app.input_runtime.statusline_menu.close();
                return true;
            }
            if (app.input_runtime.usage_menu.active) {
                app.input_runtime.usage_menu.close(app.alloc);
                return true;
            }
            if (app.input_runtime.workspace_menu.active) {
                app.input_runtime.workspace_menu.close();
                return true;
            }
            return false;
        }

        fn cancelHelpMenu(app: *App) bool {
            return closeHelpMenu(app, true);
        }

        fn cancelSettingsMenu(app: *App) bool {
            return closeSettingsMenu(app, true);
        }

        fn cancelModelMenu(app: *App) bool {
            return closeModelMenu(app, true);
        }

        fn cancelSessionMenu(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;
            app_session_runtime.Runtime(App).cancelSessionPickerToComposer(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            return true;
        }
    };
}
const ApprovalCancelEvent = enum {
    request_cancel,
};

const FakeApprovalCancelWorker = struct {
    cancel_requested: bool = false,
    order: [1]ApprovalCancelEvent = undefined,
    order_len: usize = 0,

    fn record(self: *FakeApprovalCancelWorker, event: ApprovalCancelEvent) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = event;
            self.order_len += 1;
        }
    }

    pub fn isCancelRequested(self: *const FakeApprovalCancelWorker) bool {
        return self.cancel_requested;
    }

    pub fn queuedPromptCount(_: *const FakeApprovalCancelWorker) usize {
        return 0;
    }

    pub fn requestCancel(self: *FakeApprovalCancelWorker) void {
        self.cancel_requested = true;
        self.record(.request_cancel);
    }

    pub fn cancelApprovalTurn(self: *FakeApprovalCancelWorker) void {
        self.requestCancel();
    }

    fn submitPermissionResponse(
        _: *FakeApprovalCancelWorker,
        _: u64,
        response: permission_request.OwnedPermissionResponse,
    ) worker_runtime.PermissionSubmissionResult {
        var owned = response;
        owned.deinit();
        return .accepted;
    }

    pub fn submitQuestionBatchAnswer(_: *FakeApprovalCancelWorker, _: std.mem.Allocator, _: ?[]const []const u8) !void {}
};

const FakeApprovalPacer = struct {
    cleared: bool = false,

    pub fn clear(self: *FakeApprovalPacer, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.cleared = true;
    }
};

const FakeInactiveSubagents = struct {
    fn isViewActive(_: *const FakeInactiveSubagents) bool {
        return false;
    }
};

const FakeApprovalShell = struct {
    render_requests: render_request.RenderRequestState = .{},
    layout: types.Layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    },
    transcript: std.ArrayList(u8) = .empty,

    fn deinit(self: *FakeApprovalShell, alloc: std.mem.Allocator) void {
        self.transcript.deinit(alloc);
    }

    fn updateRawBytesEntry(_: *FakeApprovalShell, _: std.mem.Allocator, _: u32, _: []const u8) !bool {
        return false;
    }

    fn appendRawTranscriptEntry(_: *FakeApprovalShell, _: std.mem.Allocator, _: []const u8) !u32 {
        return 1;
    }

    pub fn scrollFullTranscript(
        _: *FakeApprovalShell,
        _: input_action.MouseWheel,
        _: transcript_runtime.TranscriptRuntime.FullTranscriptScrollUnit,
    ) void {}
};

const routing_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "clear the terminal transcript", .presentation_category = .general },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose a model", .presentation_category = .model, .has_args = true, .accepts_payload = true, .requires_prompt_credential = true },
    .{ .kind = .models, .command = "/models", .help_entry = "/models", .completion_description = "browse available models", .presentation_category = .model },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .workspace, .command = "/workspace", .help_entry = "/workspace [list|add PATH|remove PATH|clear]", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .has_args = true, .accepts_payload = true },
};
const routing_test_slash_registry = command_specs.SlashRegistry{ .commands = routing_test_slash_specs[0..] };

const FakeApprovalCancelApp = struct {
    alloc: std.mem.Allocator,
    worker: FakeApprovalCancelWorker = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    question_prompt: question_prompt.QuestionPrompt = .{},
    subagents: FakeInactiveSubagents = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: test_ui_input.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    shell: FakeApprovalShell = .{},
    stream: types.StreamState = .{ .active = true },
    pacer: FakeApprovalPacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,

    pub fn slashRegistry(_: *const FakeApprovalCancelApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FakeApprovalCancelApp) void {
        self.approval_prompt.deinit(self.alloc);
        self.question_prompt.deinit(self.alloc);
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
    }

    fn clearPendingImages(self: *FakeApprovalCancelApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    fn ensureTrailingBlankRow(self: *FakeApprovalCancelApp) !void {
        try self.transcript.appendSlice(self.alloc, "\n\n");
    }

    fn writeTranscript(self: *FakeApprovalCancelApp, content: []const u8, redraw: bool) !void {
        _ = redraw;
        try self.transcript.appendSlice(self.alloc, content);
    }

    pub fn writeTranscriptClassified(self: *FakeApprovalCancelApp, content: []const u8, redraw: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(content, redraw);
    }

    pub fn writeDomainNotice(self: *FakeApprovalCancelApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
    }

    pub fn stopStream(self: *FakeApprovalCancelApp) void {
        self.stream = .{};
    }

    pub fn appendReplaceableTranscriptLine(self: *FakeApprovalCancelApp, content: []const u8) !u32 {
        try self.shell.transcript.appendSlice(self.alloc, content);
        return 1;
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *FakeApprovalCancelApp, content: []const u8, _: transcript_runtime.RawEntryClass) !u32 {
        return self.appendReplaceableTranscriptLine(content);
    }

    pub fn fileCompletions(
        _: *FakeApprovalCancelApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        if (out.len == 0) return 0;
        out[0] = .{ .path = "file.zig", .kind = .file, .matched_spans = &.{} };
        return 1;
    }

    pub fn modelCompletions(_: *FakeApprovalCancelApp, _: []const u8, out: [][]const u8) usize {
        if (out.len == 0) return 0;
        out[0] = "openai/gpt-5";
        return 1;
    }

    pub fn transitionFullTranscriptProjection(
        _: *FakeApprovalCancelApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        return transcript_presentation.Depth.inline_mode.transition(
            event,
        );
    }
};

const RoutingSelectedSubagent = struct {
    id: u64,
    label: []const u8,
    status: @import("../../ui/subagent/runtime.zig").Status,
    tool_calls: usize,
    current_activity: ?[]const u8,
};

const RoutingSubagents = struct {
    active: bool = false,
    main_approval_presented: bool = false,
    handled_keys: usize = 0,
    handled_raw_keys: usize = 0,
    handled_actions: usize = 0,
    last_handled_key: ?u8 = null,
    last_main_approval_id: ?u64 = null,
    toggle_view_calls: usize = 0,
    manager_paste: core_input_runtime.Runtime = .{},

    fn deinit(self: *RoutingSubagents, alloc: std.mem.Allocator) void {
        self.manager_paste.deinit(alloc);
    }

    pub fn isViewActive(self: *const RoutingSubagents) bool {
        return self.active;
    }

    pub fn mainApprovalPresented(self: *const RoutingSubagents) bool {
        return self.main_approval_presented;
    }

    pub fn selectedInfo(_: *const RoutingSubagents) ?RoutingSelectedSubagent {
        return null;
    }

    pub fn count(_: *const RoutingSubagents) usize {
        return 0;
    }

    pub fn panelText(_: *RoutingSubagents, alloc: std.mem.Allocator, _: u16, _: u16, _: transcript_runtime.Styles) ![]u8 {
        return alloc.dupe(u8, "");
    }

    pub fn handleKey(self: *RoutingSubagents, _: std.mem.Allocator, byte: u8) !subagent_input.Command {
        self.handled_keys += 1;
        self.handled_raw_keys += 1;
        self.last_handled_key = byte;
        return .none;
    }

    pub fn handleAction(self: *RoutingSubagents, _: std.mem.Allocator, action: subagent_input.Action) !subagent_input.Command {
        self.handled_keys += 1;
        self.handled_actions += 1;
        self.last_handled_key = switch (action) {
            .escape => 0x1b,
            .up, .left => 25,
            .down, .right => 9,
            else => null,
        };
        return .none;
    }

    pub fn handleKeyWithMainApproval(self: *RoutingSubagents, alloc: std.mem.Allocator, byte: u8, main_approval_id: ?u64) !subagent_input.Command {
        self.last_main_approval_id = main_approval_id;
        return self.handleKey(alloc, byte);
    }

    pub fn handleActionWithMainApproval(self: *RoutingSubagents, alloc: std.mem.Allocator, action: subagent_input.Action, main_approval_id: ?u64) !subagent_input.Command {
        self.last_main_approval_id = main_approval_id;
        return self.handleAction(alloc, action);
    }

    pub fn toggleView(self: *RoutingSubagents) @import("../../ui/subagent/controller.zig").ToggleResult {
        self.toggle_view_calls += 1;
        return .changed;
    }

    pub fn managerPasteActive(self: *const RoutingSubagents) bool {
        return self.active and self.manager_paste.paste.active();
    }

    pub fn beginManagerPaste(self: *RoutingSubagents) void {
        self.manager_paste.paste.begin(.decision_prompt, std.math.maxInt(usize));
    }

    pub fn consumeManagerPasteByte(
        self: *RoutingSubagents,
        alloc: std.mem.Allocator,
        byte: u8,
    ) !bool {
        if (!self.managerPasteActive()) return false;
        try self.manager_paste.paste.consumeByte(alloc, byte);
        return true;
    }

    pub fn settleManagerPasteDeliveryEpoch(
        self: *RoutingSubagents,
        _: std.mem.Allocator,
    ) bool {
        switch (self.manager_paste.paste.settleDeliveryEpoch()) {
            .none => return false,
            .finish => self.manager_paste.paste.resetWithTrace(.decision_prompt_active),
            .reject => self.manager_paste.paste.resetWithTrace(.unsafe_suffix),
        }
        return true;
    }
};

const RoutingUpgradeStatus = struct {
    state: auto_upgrade.State = .ready,
    stop_count: usize = 0,

    pub fn getState(self: *const RoutingUpgradeStatus) auto_upgrade.State {
        return self.state;
    }

    pub fn stop(self: *RoutingUpgradeStatus) void {
        self.stop_count += 1;
    }

    pub fn statusLabel(_: *const RoutingUpgradeStatus, _: []u8) []const u8 {
        return "";
    }
};

const RoutingWorker = struct {
    submitted_permission: ?ToolPermissionDecision = null,
    submitted_permission_feedback: [64]u8 = undefined,
    submitted_permission_feedback_len: usize = 0,
    active_permission_request_id: ?u64 = null,
    permission_response: ?ToolPermissionDecision = null,
    resize_signal_on_submit: ?*shell_runtime.ResizeApprovalInterlock = null,
    question_cancelled: bool = false,
    cancel_requested_when_question_cancelled: bool = false,
    submitted_question_answer: [64]u8 = undefined,
    submitted_question_answer_len: usize = 0,
    submitted_question_answers: [2][64]u8 = undefined,
    submitted_question_answer_lens: [2]usize = .{ 0, 0 },
    submitted_question_count: usize = 0,
    cancel_requested: bool = false,
    question_source: worker_runtime.QuestionPromptSource = .agent_question,
    admission_snapshot: worker_runtime.InteractiveAdmissionSnapshot = .open,
    queued_count: usize = 0,
    synced_permission_mode: ?types.PermissionMode = null,
    permission_mode_sync_count: usize = 0,

    pub fn queuePreview(_: *RoutingWorker, _: []u8) @import("../agent/worker_runtime.zig").QueuePreview {
        return .{};
    }

    pub fn queuedPromptCount(self: *const RoutingWorker) usize {
        return self.queued_count;
    }

    pub fn activeTurnId(_: *const RoutingWorker) u64 {
        return 1;
    }

    pub fn isCancelRequested(self: *const RoutingWorker) bool {
        return self.cancel_requested;
    }

    pub fn requestCancel(self: *RoutingWorker) void {
        self.cancel_requested = true;
    }

    pub fn interactiveAdmissionSnapshot(self: *RoutingWorker) worker_runtime.InteractiveAdmissionSnapshot {
        return self.admission_snapshot;
    }

    pub fn cancelApprovalTurn(self: *RoutingWorker) void {
        self.cancel_requested = true;
        if (self.active_permission_request_id != null and
            self.permission_response == null)
        {
            self.permission_response = .deny;
        }
    }

    pub fn submitPermissionResponse(
        self: *RoutingWorker,
        request_id: u64,
        response: permission_request.OwnedPermissionResponse,
    ) worker_runtime.PermissionSubmissionResult {
        var owned = response;
        defer owned.deinit();
        const decision = owned.decision;
        if (owned.feedback) |feedback| {
            self.submitted_permission_feedback_len = @min(
                feedback.len,
                self.submitted_permission_feedback.len,
            );
            @memcpy(
                self.submitted_permission_feedback[0..self.submitted_permission_feedback_len],
                feedback[0..self.submitted_permission_feedback_len],
            );
        }
        if (self.resize_signal_on_submit) |interlock| {
            interlock.noteResizeSignal();
        }
        if (self.active_permission_request_id) |active_id| {
            if (self.permission_response != null) return .no_pending;
            if (request_id != active_id) return .stale;
            self.permission_response = decision;
        }
        self.submitted_permission = decision;
        return .accepted;
    }

    pub fn submitQuestionBatchAnswer(self: *RoutingWorker, _: std.mem.Allocator, answers: ?[]const []const u8) !void {
        if (answers == null) {
            self.cancel_requested_when_question_cancelled = self.cancel_requested;
            self.question_cancelled = true;
            return;
        }
        const submitted = answers.?;
        self.submitted_question_count = submitted.len;
        for (submitted[0..@min(submitted.len, self.submitted_question_answers.len)], 0..) |answer, index| {
            const len = @min(answer.len, self.submitted_question_answers[index].len);
            @memcpy(self.submitted_question_answers[index][0..len], answer[0..len]);
            self.submitted_question_answer_lens[index] = len;
            if (index == 0) {
                self.submitted_question_answer_len = len;
                @memcpy(self.submitted_question_answer[0..len], answer[0..len]);
            }
        }
    }

    pub fn pendingQuestionBatchSource(self: *RoutingWorker) worker_runtime.QuestionPromptSource {
        return self.question_source;
    }

    pub fn syncQueuedPromptModel(_: *RoutingWorker, _: std.mem.Allocator, _: []const u8) !void {}

    pub fn syncQueuedPromptPermissionSnapshot(self: *RoutingWorker, snapshot: worker_runtime.PermissionSnapshot) void {
        self.synced_permission_mode = snapshot.mode;
        self.permission_mode_sync_count += 1;
    }

    pub fn syncQueuedPromptFastMode(_: *RoutingWorker, _: bool) void {}

    pub fn syncQueuedPromptEffort(_: *RoutingWorker, _: types.ReasoningEffort) void {}
};

const RoutingPacer = struct {
    pub fn clear(_: *RoutingPacer, _: std.mem.Allocator) void {}
};

fn routingFullTranscriptStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn armCtrlCExitForTest(input_runtime: *core_input_runtime.Runtime, armed_ms: i64) void {
    input_runtime.gestures = gesture_state.disarmCtrlCExit(
        input_runtime.gestures,
    ).next;
    input_runtime.gestures = gesture_state.pressCtrlCExit(
        input_runtime.gestures,
        armed_ms,
    ).next;
}

fn armEscapeClearForTest(input_runtime: *core_input_runtime.Runtime, armed_ms: i64) void {
    input_runtime.gestures = gesture_state.disarmEscapeClear(
        input_runtime.gestures,
    ).next;
    input_runtime.gestures = gesture_state.pressEscapeClear(
        input_runtime.gestures,
        armed_ms,
    ).next;
}

test "queued draft cursor movement does not lock vertical navigation" {
    const cursor_actions = [_]input_action.ShortcutAction{
        .{ .move = .{ .kind = .character_left } },
        .{ .move = .{ .kind = .character_right } },
        .{ .move = .{ .kind = .line_start } },
        .{ .move = .{ .kind = .line_end } },
        .{ .move = .{ .kind = .word_left } },
        .{ .move = .{ .kind = .word_right } },
    };
    for (cursor_actions) |action| {
        try std.testing.expect(!shortcutMayMutateQueuedDraft(action));
    }
    try std.testing.expect(shortcutMayMutateQueuedDraft(.delete_backward));
    try std.testing.expect(shortcutMayMutateQueuedDraft(.insert_newline));
}

test "all destructive composer shortcuts can delete an empty queued draft" {
    const deletion_actions = [_]input_action.ShortcutAction{
        .delete_backward,
        .delete_forward,
        .delete_word_left,
        .delete_whitespace_word_left,
        .delete_word_right,
        .delete_to_line_start,
        .delete_to_line_end,
    };
    for (deletion_actions) |action| {
        try std.testing.expect(shortcutDeletesQueuedDraft(action));
    }
    try std.testing.expect(!shortcutDeletesQueuedDraft(.cut_selection));
    try std.testing.expect(!shortcutDeletesQueuedDraft(.{ .move = .{ .kind = .character_left } }));
    try std.testing.expect(!shortcutDeletesQueuedDraft(.insert_newline));
}

const RoutingFakeApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    metrics: types.Metrics = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    question_prompt: question_prompt.QuestionPrompt = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: test_ui_input.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    terminal: shell_runtime.TerminalState = .{},
    worker: RoutingWorker = .{},
    subagents: RoutingSubagents = .{},
    permission_engine: permissions.PermissionEngine = .{},
    upgrader: RoutingUpgradeStatus = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id_counter: usize = 1,
    selected_model: std.ArrayList(u8) = .empty,
    workspace_root: []const u8 = "",
    stream: types.StreamState = .{},
    session_persistence: app_session_runtime.Persistence = .{},
    skills: skill_runtime.Runtime = .{},
    pacer: RoutingPacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,
    notice_visibility: types.NoticeVisibility = .compact_and_full,
    notice_write_count: usize = 0,
    last_replaceable_class: transcript_runtime.RawEntryClass = .unknown_raw,
    auth: auth_runtime.Runtime = .{},
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    should_exit: bool = false,
    statusline_context: bool = false,
    permission_state: app_permission_runtime.State = .{},
    total_input_tokens: u64 = 0,
    last_command: ?[]u8 = null,
    input_len_at_command: usize = 0,
    pasted_block_count_at_command: usize = 0,
    preference_commit_count: usize = 0,
    last_preference_model: std.ArrayList(u8) = .empty,
    last_preference_effort: ?types.ReasoningEffort = null,
    last_preference_fast_mode: ?bool = null,
    permission_mode_preference_commit_count: usize = 0,
    last_preference_permission_mode: ?types.PermissionMode = null,
    model_completion_values: []const []const u8 = &.{},
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    model_cache_loading: bool = false,
    model_cache: model_cache_runtime.Runtime,
    file_completion_values: []const file_index.Candidate = &.{},
    file_completion_current: bool = true,
    expected_file_completion_kind: ?file_index.CandidateKind = null,
    validated_file_completion_kind: ?file_index.CandidateKind = null,
    file_completion_error: ?file_index.SearchError = null,
    file_completions_depend_on_index: bool = true,
    file_index_refresh_count: usize = 0,
    file_index_loading: bool = false,
    file_index_failed: bool = false,
    submitted_prompt_count: usize = 0,
    submitted_prompt: [128]u8 = undefined,
    submitted_prompt_len: usize = 0,
    approval_resize_interlock: shell_runtime.ResizeApprovalInterlock = .{},
    inject_resize_before_affirmative_claim: bool = false,
    affirmative_claim_count: usize = 0,
    affirmative_release_count: usize = 0,
    resume_selected_count: usize = 0,
    resume_selected_error: anyerror = error.SessionStoreUnavailable,
    resume_selected_closes_picker: bool = false,
    load_more_session_count: usize = 0,
    selected_credential_source: ?types.CredentialSource = null,
    selected_auth_action: ?auth_runtime.AcquisitionAction = null,
    selected_auth_team: ?usize = null,
    upgrade_apply_count: usize = 0,
    upgrade_denied_count: usize = 0,
    suspend_count: usize = 0,
    workspace_access: app_workspace_runtime.Access = .{},

    pub fn slashRegistry(_: *const RoutingFakeApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    pub fn urlOpener(_: *const RoutingFakeApp) host.UrlOpener {
        return .{ .open_fn = routingOpenUrl };
    }

    fn init(alloc: std.mem.Allocator) !RoutingFakeApp {
        var app = RoutingFakeApp{
            .alloc = alloc,
            .model_cache = model_cache_runtime.Runtime.init(alloc, "/v1/models"),
        };
        try app.selected_model.appendSlice(alloc, "test/model");
        app.shell.layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        };
        app.shell.owned_top_row = 1;
        app.shell.viewport_top_row = 1;
        app.shell.cursor_row = 10;
        app.shell.cursor_col = 1;
        return app;
    }

    fn deinit(self: *RoutingFakeApp) void {
        self.auth.deinit(self.alloc);
        self.approval_prompt.deinit(self.alloc);
        self.question_prompt.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.session_persistence.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
        self.last_preference_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.model_cache.deinit();
        self.workspace_access.deinit(self.alloc);
        if (self.last_command) |command| self.alloc.free(command);
    }

    pub fn workspaceAccess(self: *RoutingFakeApp) *app_workspace_runtime.Access {
        return &self.workspace_access;
    }

    pub fn flushBeforeBlockingExternalWork(_: *RoutingFakeApp) !void {}

    pub fn suspendToJobControl(self: *RoutingFakeApp) !void {
        self.suspend_count += 1;
    }

    pub fn modelCompletions(self: *RoutingFakeApp, query: []const u8, out: *[32][]const u8) usize {
        if (self.model_cache_loading) return 0;
        var count: usize = 0;
        for (self.model_completion_values) |value| {
            if (count == out.len) break;
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(value, query) == null) continue;
            out[count] = value;
            count += 1;
        }
        return count;
    }

    pub fn catalogModelCompletion(self: *RoutingFakeApp, model: []const u8) ?[]const u8 {
        if (self.model_cache_loading) return null;
        for (self.model_completion_values) |value| {
            if (std.mem.eql(u8, value, model)) return value;
        }
        return null;
    }

    pub fn fileCompletions(
        self: *RoutingFakeApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        if (self.file_completion_error) |err| return err;
        const count = @min(self.file_completion_values.len, out.len);
        for (self.file_completion_values[0..count], 0..) |value, index| {
            out[index] = .{ .path = value.path, .kind = value.kind, .matched_spans = &.{} };
        }
        return count;
    }

    pub fn refreshFileIndex(self: *RoutingFakeApp) void {
        self.file_index_refresh_count += 1;
    }

    pub fn fileCompletionsDependOnIndex(self: *const RoutingFakeApp, _: []const u8) bool {
        return self.file_completions_depend_on_index;
    }

    pub fn refreshUsageMenu(
        self: *RoutingFakeApp,
        scope: usage_report.Scope,
    ) !void {
        self.input_runtime.usage_menu.requested_scope = scope;
    }

    pub fn isCurrentFileCompletion(self: *RoutingFakeApp, _: []const u8, _: []const u8, kind: file_index.CandidateKind) bool {
        self.validated_file_completion_kind = kind;
        return self.file_completion_current and
            (self.expected_file_completion_kind == null or self.expected_file_completion_kind.? == kind);
    }

    pub fn isModelCacheLoading(self: *const RoutingFakeApp) bool {
        return self.model_cache_loading;
    }

    pub fn isModelCacheFailed(_: *const RoutingFakeApp) bool {
        return false;
    }

    pub fn resolvedModelCapabilities(self: *RoutingFakeApp, model: []const u8) model_capabilities.Capabilities {
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.resolveCapabilities(model, self.gateway_metadata);
            }
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    fn setGatewayControls(
        self: *RoutingFakeApp,
        model: []const u8,
        efforts: []const types.ReasoningEffort,
        supports_fast_mode: bool,
    ) void {
        self.gateway_metadata_model = model;
        self.gateway_metadata = .{
            .reasoning_efforts = .fromSlice(efforts),
            .supports_fast_mode = supports_fast_mode,
        };
    }

    pub fn isFileIndexLoading(self: *const RoutingFakeApp) bool {
        return self.file_index_loading;
    }

    pub fn isFileIndexFailed(self: *const RoutingFakeApp) bool {
        return self.file_index_failed;
    }

    pub fn appendReplaceableTranscriptLine(self: *RoutingFakeApp, content: []const u8) !u32 {
        try self.transcript.appendSlice(self.alloc, content);
        return 1;
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *RoutingFakeApp, content: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_replaceable_class = class;
        return self.appendReplaceableTranscriptLine(content);
    }

    pub fn writeTranscriptClassified(self: *RoutingFakeApp, content: []const u8, _: bool, _: transcript_runtime.RawEntryClass) !void {
        try self.transcript.appendSlice(self.alloc, content);
    }

    pub fn writeDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_write_count += 1;
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
        self.notice_visibility = notice.visibility;
        const rendered = if (notice.topic.len > 0)
            try std.fmt.allocPrint(self.alloc, "● {c}{s}: {s}", .{
                std.ascii.toUpper(notice.topic[0]),
                notice.topic[1..],
                notice.body,
            })
        else
            try std.fmt.allocPrint(self.alloc, "● {s}", .{notice.body});
        defer self.alloc.free(rendered);
        try self.transcript.appendSlice(self.alloc, rendered);
    }

    pub fn appendDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice) !u32 {
        return self.shell.appendSemanticNotice(self.alloc, notice);
    }

    pub fn appendReplaceableDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice) !u32 {
        return self.shell.appendReplaceableSemanticNotice(self.alloc, notice);
    }

    pub fn replaceDomainNotice(self: *RoutingFakeApp, entry_id: u32, notice: types.SemanticNotice) !bool {
        return self.shell.replaceSemanticNotice(self.alloc, entry_id, notice);
    }

    pub fn writeUserPromptCard(self: *RoutingFakeApp, user: types.UserTurn) !void {
        try self.transcript.appendSlice(self.alloc, user.text);
    }

    pub fn stopStream(self: *RoutingFakeApp) void {
        self.stream = .{};
    }

    pub fn prepareLiveSessionResume(_: *RoutingFakeApp) !void {}

    pub fn finishLiveSessionResume(_: *RoutingFakeApp) !void {}

    pub fn resumeSelectedSession(self: *RoutingFakeApp) !bool {
        self.resume_selected_count += 1;
        if (self.resume_selected_closes_picker) {
            self.session_persistence.session_picker.active = false;
        }
        return self.resume_selected_error;
    }

    pub fn loadMoreSessionPicker(self: *RoutingFakeApp) !bool {
        const picker = &self.session_persistence.session_picker;
        if (!picker.active or picker.load_state != .ready or !picker.has_more or
            picker.selected != picker.filteredItemCount()) return false;
        self.load_more_session_count += 1;
        return true;
    }

    pub fn applyAuthPickerChoice(self: *RoutingFakeApp, choice: auth_runtime.Choice) !void {
        switch (choice) {
            .provider => {},
            .source => |source| _ = try self.selectCredentialSource(source),
            .action => |action| self.selected_auth_action = action,
            .team => |index| self.selected_auth_team = index,
        }
    }

    pub fn selectCredentialSource(self: *RoutingFakeApp, source: types.CredentialSource) !bool {
        self.selected_credential_source = source;
        return true;
    }

    pub fn prepareResumeHandoffForUpgrade(_: *RoutingFakeApp) !void {}

    pub fn requestUpgradeRelaunch(
        self: *RoutingFakeApp,
        _: []const u8,
    ) !void {
        self.upgrade_apply_count += 1;
    }

    pub fn requestResumeHandoffForUpgrade(_: *RoutingFakeApp) void {}

    pub fn applyReadyUpgradeShortcut(self: *RoutingFakeApp) !void {
        const outcome = try app_upgrade_runtime.Runtime(RoutingFakeApp).applyReadyUpgradeWithDeps(
            self,
            .{
                .ctx = self,
                .current_executable_path = currentExecutablePathForRouting,
            },
        );
        if (outcome != .relaunch_requested) {
            self.upgrade_denied_count += 1;
        }
    }

    pub fn nextImageId(self: *RoutingFakeApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn captureImageAttachment(_: *RoutingFakeApp, _: *types.ImageAttachment) !void {
        return error.MissingImageSnapshot;
    }

    pub fn peekNextImageId(self: *const RoutingFakeApp) usize {
        return self.next_image_id_counter;
    }

    pub fn transitionFullTranscriptProjection(
        self: *RoutingFakeApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        self.shell.setCommandOutputRenderPolicy(
            routingFullTranscriptStyles(),
        );
        const depth = self.shell.transcriptPresentationDepth().transition(event);
        _ = try self.shell.setTranscriptPresentationDepth(self.alloc, depth);
        return depth;
    }

    pub fn writeSubagentSnapshot(self: *RoutingFakeApp) !void {
        self.subagents.toggle_view_calls += 1;
    }

    pub fn admitPendingApprovalResize(self: *RoutingFakeApp) bool {
        if (!self.approval_resize_interlock.takeResizePending()) return false;
        self.shell.render_requests.observeResizeSignal(100, 80);
        return true;
    }

    pub fn beforeApprovalAffirmativeClaim(self: *RoutingFakeApp) void {
        if (!self.inject_resize_before_affirmative_claim) return;
        self.inject_resize_before_affirmative_claim = false;
        self.approval_resize_interlock.noteResizeSignal();
    }

    pub fn claimApprovalAffirmative(self: *RoutingFakeApp) bool {
        self.affirmative_claim_count += 1;
        return self.approval_resize_interlock.claimAffirmative();
    }

    pub fn releaseApprovalAffirmative(self: *RoutingFakeApp) void {
        self.affirmative_release_count += 1;
        self.approval_resize_interlock.releaseAffirmative();
    }

    pub fn enqueuePrompt(self: *RoutingFakeApp, text: []const u8) !bool {
        self.submitted_prompt_len = @min(text.len, self.submitted_prompt.len);
        @memcpy(self.submitted_prompt[0..self.submitted_prompt_len], text[0..self.submitted_prompt_len]);
        self.submitted_prompt_count += 1;
        return true;
    }

    pub fn handleCommand(self: *RoutingFakeApp, command: []const u8) !void {
        if (self.last_command) |previous| self.alloc.free(previous);
        self.last_command = try self.alloc.dupe(u8, command);
        self.input_len_at_command = self.input_runtime.edit_state.input.items.len;
        self.pasted_block_count_at_command = self.input_runtime.entities.pasted_blocks.items.len;
    }

    pub fn persistRuntimePreferences(
        self: *RoutingFakeApp,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        self.preference_commit_count += 1;
        self.last_preference_model.clearRetainingCapacity();
        if (patch.model) |model| {
            self.last_preference_model.appendSlice(self.alloc, model) catch
                return .{ .settings_error = error.OutOfMemory };
        }
        self.last_preference_effort = patch.effort;
        self.last_preference_fast_mode = patch.fast_mode;
        return .{};
    }

    pub fn persistPermissionModePreference(
        self: *RoutingFakeApp,
        mode: types.PermissionMode,
    ) !void {
        self.permission_mode_preference_commit_count += 1;
        self.last_preference_permission_mode = mode;
    }

    pub fn clearPendingImages(self: *RoutingFakeApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.pending_images.items);
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }
};

fn routingOpenUrl(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) host.UrlOpenError!bool {
    return false;
}

fn currentExecutablePathForRouting(
    _: ?*anyopaque,
    executable_buf: []u8,
) upgrade_helpers.ExecutablePathError![]const u8 {
    const executable_path = "/tmp/fx-routing-upgraded";
    if (executable_path.len > executable_buf.len) return error.PathTooLong;
    @memcpy(executable_buf[0..executable_path.len], executable_path);
    return executable_buf[0..executable_path.len];
}

fn readTraceFileForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

fn activateFullTranscriptForRoutingTest(app: *RoutingFakeApp) void {
    app.terminal.alternate_screen_owner = .full_transcript;
    app.terminal.alternate_mouse_tracking_active = true;
    app.shell.full_transcript = .{ .depth = .review, .follow_tail = true };
}

fn appendRoutingSessionPickerSummary(
    alloc: std.mem.Allocator,
    picker: *app_session_runtime.SessionPicker,
    index: usize,
) !void {
    const id = try std.fmt.allocPrint(alloc, "session-{d}", .{index});
    errdefer alloc.free(id);
    const workspace_root = try std.fmt.allocPrint(alloc, "/tmp/workspace-{d}", .{index});
    errdefer alloc.free(workspace_root);
    const title = try std.fmt.allocPrint(alloc, "session {d}", .{index});
    errdefer alloc.free(title);
    const preview = try std.fmt.allocPrint(alloc, "session {d} preview", .{index});
    errdefer alloc.free(preview);
    try picker.summaries.append(alloc, .{
        .id = id,
        .workspace_root = workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = true,
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .history_len = 1,
    });
}

test "app_input_runtime slash completion movement works while stream is active" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    const count = command_specs.slashCompletionCount(app.slashRegistry(), app.input_runtime.edit_state.input.items);
    try std.testing.expect(count > 1);
    try std.testing.expect(app.stream.active);

    try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, 1));

    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);

    try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, -1));

    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);

    app.input_runtime.picker.dismissInlinePicker(.slash);
    try std.testing.expect(!Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, 1));
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
}

test "app_input_runtime slash completion window moves up before reverse scrolling" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    var down: usize = 0;
    while (down < 6) : (down += 1) {
        try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, 1));
    }
    try std.testing.expectEqual(@as(usize, 6), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.slash_completion_window_start);

    try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, -1));
    try std.testing.expectEqual(@as(usize, 5), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.slash_completion_window_start);
}

test "app_input_runtime session picker window moves up before reverse scrolling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.shell.layout.rows = 10;
    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    for (0..8) |index| try appendRoutingSessionPickerSummary(alloc, picker, index);

    var down: usize = 0;
    while (down < 5) : (down += 1) {
        try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    }
    try std.testing.expectEqual(@as(usize, 5), picker.selected);
    try std.testing.expectEqual(@as(usize, 2), picker.window_start);

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .up, -1);
    try std.testing.expectEqual(@as(usize, 4), picker.selected);
    try std.testing.expectEqual(@as(usize, 2), picker.window_start);
}

test "app_input_runtime session picker waits for rendered bottom before scrolling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.shell.layout.rows = 32;
    app.shell.layout.content_bottom = 28;
    app.shell.layout.divider_top_row = 29;
    app.shell.layout.input_row = 30;
    app.shell.layout.divider_bottom_row = 31;
    app.shell.layout.hint_row = 32;

    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    for (0..10) |index| try appendRoutingSessionPickerSummary(alloc, picker, index);

    var down: usize = 0;
    while (down < 7) : (down += 1) {
        try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    }

    try std.testing.expectEqual(@as(usize, 7), picker.selected);
    try std.testing.expectEqual(@as(usize, 0), picker.window_start);
}

test "app_input_runtime help menu navigation skips headings and Enter executes selection" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.input_runtime.help_menu.open();

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.help_menu.selected_index);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', RoutingFakeApp.input_byte_limit, 100);

    try std.testing.expect(!app.input_runtime.help_menu.active);
    try std.testing.expectEqualStrings("/clear", app.last_command.?);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime help menu inserts argument commands with a trailing space" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "additional directories");
    app.input_runtime.help_menu.open();

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', RoutingFakeApp.input_byte_limit, 100);

    try std.testing.expect(!app.input_runtime.help_menu.active);
    try std.testing.expectEqualStrings("/workspace ", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.last_command == null);
}

test "app_input_runtime help menu submits an exact slash command on first Enter" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/clear");
    app.input_runtime.help_menu.open();

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        RoutingFakeApp.input_byte_limit,
        100,
    );

    try std.testing.expect(!app.input_runtime.help_menu.active);
    try std.testing.expectEqualStrings("/clear", app.last_command.?);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime Escape closes help and clears its composer search" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "model");
    app.input_runtime.help_menu.open();

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expect(!app.input_runtime.help_menu.active);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime session picker uses spare footer row before scrolling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.shell.layout.rows = 28;
    app.shell.layout.content_bottom = 24;
    app.shell.layout.divider_top_row = 25;
    app.shell.layout.input_row = 26;
    app.shell.layout.divider_bottom_row = 27;
    app.shell.layout.hint_row = 28;

    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    for (0..10) |index| try appendRoutingSessionPickerSummary(alloc, picker, index);

    var down: usize = 0;
    while (down < 6) : (down += 1) {
        try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    }

    try std.testing.expectEqual(@as(usize, 6), picker.selected);
    try std.testing.expectEqual(@as(usize, 0), picker.window_start);
}

test "app_input_runtime session picker navigation keeps fixed catalog rows" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.shell.layout.rows = 28;
    app.shell.layout.content_bottom = 24;
    app.shell.layout.divider_top_row = 25;
    app.shell.layout.input_row = 26;
    app.shell.layout.divider_bottom_row = 27;
    app.shell.layout.hint_row = 28;

    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    var index: usize = 0;
    while (index < 10) : (index += 1) {
        try appendRoutingSessionPickerSummary(alloc, picker, index);
    }

    var down: usize = 0;
    while (down < 4) : (down += 1) {
        try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    }

    try std.testing.expectEqual(@as(usize, 4), picker.selected);
    try std.testing.expectEqual(@as(usize, 0), picker.window_start);

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);

    try std.testing.expectEqual(@as(usize, 5), picker.selected);
    try std.testing.expectEqual(@as(usize, 0), picker.window_start);
}

test "app_input_runtime routes auth picker navigation before composer history" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    app.auth.openPicker(alloc);

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);

    try std.testing.expect((auth_runtime.Choice{ .action = .chatgpt_login }).eql(app.auth.pickerView().selected_choice.?));
    try std.testing.expectEqual(@as(?usize, null), app.input_runtime.composer_history.activeIndex());
}

test "app_input_runtime Tab cycles the active auth picker" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    app.auth.openPicker(alloc);

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expect((auth_runtime.Choice{ .action = .chatgpt_login }).eql(app.auth.pickerView().selected_choice.?));
}

test "app_input_runtime Tab leaves a dismissed slash query unchanged" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/he");
    app.input_runtime.picker.dismissInlinePicker(.slash);

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expectEqualStrings("/he", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
}

test "app_input_runtime workspace add handoff dismisses argument completion" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.input_runtime.workspace_menu.open();

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.input_runtime.workspace_menu.active);
    try std.testing.expectEqualStrings(
        "/workspace add ",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
}

test "help menu whole replacement preserves the prior draft when staging fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(
        alloc,
        "additional directories",
    );
    app.input_runtime.help_menu.open();
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(
        error.OutOfMemory,
        Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100),
    );

    try std.testing.expect(app.input_runtime.help_menu.active);
    try std.testing.expectEqualStrings(
        "additional directories",
        app.input_runtime.edit_state.input.items,
    );
}

test "workspace menu whole replacement preserves the prior draft when staging fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "existing draft");
    app.input_runtime.workspace_menu.open();
    // The command writer owns the first allocation; fail replacement staging.
    failing.fail_index = failing.alloc_index + 1;

    try std.testing.expectError(
        error.OutOfMemory,
        Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100),
    );

    try std.testing.expect(app.input_runtime.workspace_menu.active);
    try std.testing.expectEqualStrings(
        "existing draft",
        app.input_runtime.edit_state.input.items,
    );
}

test "app_input_runtime auth picker enter closes before selecting a switched source" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    app.auth.openPicker(alloc);
    app.auth.openSwitchCredentialPicker(alloc);
    _ = app.auth.movePicker(1);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.auth.pickerView().active);
    try std.testing.expectEqual(types.CredentialSource.fx_login, app.selected_credential_source.?);
}

test "app_input_runtime auth picker delegates typed acquisition actions" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login });
    app.auth.openPicker(alloc);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.auth.pickerView().active);
    try std.testing.expectEqual(auth_runtime.AcquisitionAction.login, app.selected_auth_action.?);
}

test "app_input_runtime Escape closes auth picker without arming composer clear" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initOne(.ai_gateway_api_key);
    app.auth.openPicker(alloc);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expect(!app.auth.pickerView().active);
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
}

test "app_input_runtime onboarding Escape skips setup for the session" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.openOnboardingPicker(alloc);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expect(!app.auth.pickerView().active);
    try std.testing.expect(app.auth.view().onboarding_skipped);
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
}

test "app_input_runtime auth stage Escape pops before closing the picker" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initOne(.stored_key);
    app.auth.openPicker(alloc);

    for (0..7) |_| _ = app.auth.movePicker(1);
    try std.testing.expect((auth_runtime.Choice{ .action = .switch_credential }).eql(
        app.auth.pickerView().selected_choice.?,
    ));

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(auth_runtime.PickerStage.switch_credential, app.auth.pickerView().stage);
    try std.testing.expect(app.auth.pickerView().active);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);
    try std.testing.expectEqual(auth_runtime.PickerStage.root, app.auth.pickerView().stage);
    try std.testing.expect(app.auth.pickerView().active);
    try std.testing.expect((auth_runtime.Choice{ .action = .switch_credential }).eql(
        app.auth.pickerView().selected_choice.?,
    ));

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 2);
    try std.testing.expect(!app.auth.pickerView().active);
    try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
}

test "app_input_runtime disabled change team action stays silent" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initOne(.stored_key);
    app.auth.openPicker(alloc);

    for (0..6) |_| _ = app.auth.movePicker(1);
    try std.testing.expect((auth_runtime.Choice{ .action = .change_team }).eql(
        app.auth.pickerView().selected_choice.?,
    ));

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(app.auth.pickerView().active);
    try std.testing.expectEqual(auth_runtime.PickerStage.root, app.auth.pickerView().stage);
    try std.testing.expect(app.selected_auth_action == null);
    try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
}

test "app_input_runtime Escape dismisses visible slash completions without arming composer clear" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/");
    const cursor_before = app.input_runtime.edit_state.cursor;

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expectEqualStrings("/", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(cursor_before, app.input_runtime.edit_state.cursor);
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 2);

    try std.testing.expectEqualStrings("/", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(cursor_before, app.input_runtime.edit_state.cursor);
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
    try std.testing.expectEqual(
        @as(?i64, 2),
        app.input_runtime.gestures.escapeClearArmedAt(),
    );
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime Escape dismisses slash matches with wrapped input" {
    const alloc = std.testing.allocator;

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.shell.layout.cols = 8;
    app.shell.layout.content_bottom = 10;
    try app.input_runtime.textReplacementState().replace(alloc, "       /mo");
    try std.testing.expect(command_specs.slashCompletionCount(app.slashRegistry(), "/mo") > 0);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 11);

    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
}

test "app_input_runtime Escape dismisses model and file pickers through one contract" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        input: []const u8,
        kind: picker_state.InlinePickerKind,
    }{
        .{ .input = "/model ", .kind = .model },
        .{ .input = "@not-present", .kind = .file },
    };

    for (cases) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.textReplacementState().replace(alloc, case.input);
        const cursor_before = app.input_runtime.edit_state.cursor;

        try Runtime(RoutingFakeApp).resolveEscape(&app, false, 12);

        try std.testing.expectEqualStrings(case.input, app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(cursor_before, app.input_runtime.edit_state.cursor);
        try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(case.kind));
        try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());

        try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);
        try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(case.kind));
    }
}

test "app_input_runtime Escape dismisses an idle inline skill completion" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "explain $man");
    try std.testing.expect(input_completion_runtime.CompletionRuntime(RoutingFakeApp).visibleInlineSkillCompletion(&app) != null);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expectEqualStrings("explain $man", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.skill));
    try std.testing.expect(input_completion_runtime.CompletionRuntime(RoutingFakeApp).visibleInlineSkillCompletion(&app) == null);
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
}

test "app_input_runtime Escape dismisses an idle inline slash completion" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "explain /he");
    const completion_rt = input_completion_runtime.CompletionRuntime(RoutingFakeApp);
    try std.testing.expect(completion_rt.visibleInlineSlashCompletion(&app) != null);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expectEqualStrings("explain /he", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
    try std.testing.expect(completion_rt.visibleInlineSlashCompletion(&app) == null);
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
}

test "app_input_runtime active operation Escape keeps precedence over inline skill dismissal" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.stream.active = true;
    try app.input_runtime.textReplacementState().replace(alloc, "explain $man");
    try std.testing.expect(input_completion_runtime.CompletionRuntime(RoutingFakeApp).visibleInlineSkillCompletion(&app) != null);

    try Runtime(RoutingFakeApp).resolveEscape(&app, true, 1);

    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expect(!app.stream.active);
    try std.testing.expect(!app.input_runtime.picker.isInlinePickerDismissed(.skill));
}

test "app_input_runtime composer editing dismisses auth picker before inserting" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.auth.source_inventory = auth_runtime.SourceSet.initOne(.ai_gateway_api_key);
    app.auth.openPicker(alloc);

    try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);

    try std.testing.expect(!app.auth.pickerView().active);
    try std.testing.expectEqualStrings("x", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime skills menu navigation clamps before prompt history" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "workspace", .description = "", .path = "/tmp/workspace/SKILL.md", .source = .workspace_shared },
    };
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), app.skills.menu.selected_index);

    // At the last skill, down clamps (stays on the last) and does not fall
    // through to prompt history.
    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), app.skills.menu.selected_index);
}

test "app_input_runtime skills menu navigation remains interactive while streaming" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "workspace", .description = "", .path = "/tmp/workspace/SKILL.md", .source = .workspace_shared },
    };
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();
    app.stream.active = true;

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);

    try std.testing.expectEqual(@as(usize, 1), app.skills.menu.selected_index);
}

test "app_input_runtime skills menu navigation uses the dedicated composer window" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = "", .path = "/tmp/one/SKILL.md", .source = .global_fx },
        .{ .name = "two", .description = "", .path = "/tmp/two/SKILL.md", .source = .global_fx },
        .{ .name = "three", .description = "", .path = "/tmp/three/SKILL.md", .source = .global_fx },
        .{ .name = "four", .description = "", .path = "/tmp/four/SKILL.md", .source = .global_fx },
    };
    app.shell.layout = .{
        .rows = 16,
        .cols = 80,
        .content_bottom = 12,
        .divider_top_row = 13,
        .input_row = 14,
        .divider_bottom_row = 15,
        .hint_row = 16,
    };
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "one\ntwo\nthree\nfour\nfive\nsix\nseven");
    app.skills.openMenuWithQuery(.command, null, "");

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);

    try std.testing.expectEqual(@as(usize, 1), app.skills.menu.selected_index);
    try std.testing.expectEqual(@as(usize, 0), app.skills.menu.window_start);
}

test "app_input_runtime Escape closes an idle skills menu before empty-composer handling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!app.worker.cancel_requested);
}

test "api key entry bypasses composer paste and zeroes on cancellation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const sentinel = "FX_API_KEY_HISTORY_SENTINEL";
    app.auth.openApiKeyPicker(alloc);

    try feedRoutingBytes(&app, "\x1b[200~");
    try feedRoutingBytes(&app, sentinel);
    try feedRoutingBytes(&app, "\x1b[201~");

    try std.testing.expect(app.auth.apiKeyEntryActive());
    try std.testing.expectEqual(sentinel.len, app.auth.pickerView().api_key_mask_count);
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.composer_history.count());

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);
    try std.testing.expect(!app.auth.apiKeyEntryActive());
    try std.testing.expectEqual(@as(usize, 0), app.auth.pickerView().api_key_mask_count);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime command skills menu reuses composer input as its query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("x", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("x", app.skills.menu.query());
}

test "app_input_runtime command skills search owns dollar and model-shaped text" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "model-helper",
        .description = "",
        .path = "/tmp/model-helper/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try feedRoutingBytes(&app, "/model $");

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuOrigin.command, app.skills.menu.origin);
    try std.testing.expect(app.skills.menu.target == null);
    try std.testing.expectEqualStrings("/model $", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("/model $", app.skills.menu.query());
}

test "app_input_runtime command skills query follows history and ctrl-c clear" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "older",
        .description = "",
        .path = "/tmp/older/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.composer_history.installTextEntries(alloc, &.{"older"});
    app.skills.openMenu();

    try feedRoutingBytes(&app, "\x10");
    try std.testing.expectEqualStrings("older", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("older", app.skills.menu.query());

    try feedRoutingBytes(&app, "\x03");
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("", app.skills.menu.query());
}

test "app_input_runtime Escape closes a command skills menu and clears its temporary query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "man");
    app.skills.openMenuWithQuery(.command, null, "man");

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
}

test "app_input_runtime Space edits and filters a command skills query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "managed description",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try Runtime(RoutingFakeApp).handleByte(&app, ' ', 4096, 100);

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings(" ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings(" ", app.skills.menu.query());
}

test "app_input_runtime command skills search owns Space in model-shaped queries" {
    const model = "anthropic/claude-sonnet-4.6";
    const completions = [_][]const u8{model};
    const cases = [_]struct {
        query: []const u8,
        exact: bool,
    }{
        .{ .query = "/model nonsense", .exact = false },
        .{ .query = "/model " ++ model, .exact = true },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.model_completion_values = &completions;
        app.skills.openMenu();
        try feedRoutingBytes(&app, case.query);

        const model_query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(case.exact, std.ascii.eqlIgnoreCase(model_query.query, model));

        try Runtime(RoutingFakeApp).handleByte(&app, ' ', 4096, 100);

        try std.testing.expect(app.skills.menu.active);
        try std.testing.expectEqual(case.query.len + 1, app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqualStrings(case.query, app.input_runtime.edit_state.input.items[0..case.query.len]);
        try std.testing.expectEqual(@as(u8, ' '), app.input_runtime.edit_state.input.items[case.query.len]);
        try std.testing.expectEqualStrings(app.input_runtime.edit_state.input.items, app.skills.menu.query());
        try std.testing.expect(!app.input_runtime.picker.hasPendingModelPickerSelection());
    }
}

test "app_input_runtime Tab cycles skills menu sources before autocomplete" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "codex", .description = "", .path = "/tmp/codex/SKILL.md", .source = .global_codex },
    };
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();
    try app.input_runtime.textReplacementState().replace(alloc, "/sk");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuSourceFilter.fx, app.skills.menu.source_filter);
    try std.testing.expectEqualStrings("/sk", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime Tab cycles skills menu sources while streaming" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "codex", .description = "", .path = "/tmp/codex/SKILL.md", .source = .global_codex },
    };
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expectEqual(skill_runtime.SkillMenuSourceFilter.fx, app.skills.menu.source_filter);
}

test "app_input_runtime Tab toggles session picker scope before autocomplete" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.workspace_root = workspace;
    app.session_persistence.store = try session_store.Store.initFromHome(alloc, home, workspace);
    app.session_persistence.session_picker.active = true;
    app.session_persistence.session_picker.scope = .current_workspace;
    try app.input_runtime.textReplacementState().replace(alloc, "/sk");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expect(app.session_persistence.session_picker.active);
    try std.testing.expectEqual(app_session_runtime.SessionPickerScope.all_workspaces, app.session_persistence.session_picker.scope);
    try std.testing.expectEqualStrings("/sk", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime Shift+Tab cycles permission mode and queued prompts" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, '[', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'Z', 4096, 100);

    try std.testing.expectEqual(types.PermissionMode.auto, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.worker.synced_permission_mode);
    try std.testing.expectEqual(@as(usize, 1), app.worker.permission_mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.last_preference_permission_mode);
    try std.testing.expectEqual(@as(usize, 1), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, '[', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'Z', 4096, 100);

    try std.testing.expectEqual(types.PermissionMode.yolo, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .yolo), app.worker.synced_permission_mode);
    try std.testing.expectEqual(@as(usize, 2), app.worker.permission_mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .yolo), app.last_preference_permission_mode);
    try std.testing.expectEqual(@as(usize, 2), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, '[', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'Z', 4096, 100);

    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.worker.synced_permission_mode);
    try std.testing.expectEqual(@as(usize, 3), app.worker.permission_mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.last_preference_permission_mode);
    try std.testing.expectEqual(@as(usize, 3), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime Shift+Tab reverses skills source without changing permission mode" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "claw", .description = "", .path = "/tmp/claw/SKILL.md", .source = .global_claw },
    };
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try feedRoutingBytes(&app, "\x1b[Z");

    try std.testing.expectEqual(skill_runtime.SkillMenuSourceFilter.claw, app.skills.menu.source_filter);
    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(usize, 0), app.worker.permission_mode_sync_count);
}

test "app_input_runtime routes horizontal arrows to inline settings" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "permission");
    app.input_runtime.settings_menu.open();
    app.input_runtime.settings_menu.category = .agent;
    const cursor_before = app.input_runtime.edit_state.cursor;

    try feedRoutingBytes(&app, "\x1b[D");

    try std.testing.expect(app.input_runtime.settings_menu.active);
    try std.testing.expectEqual(cursor_before, app.input_runtime.edit_state.cursor);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime Enter stays inside the inline settings list" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.input_runtime.settings_menu.open();

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(app.input_runtime.settings_menu.active);
    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(usize, 0), app.worker.permission_mode_sync_count);
}

test "app_input_runtime Space edits the session catalog query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.session_persistence.session_picker.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, ' ', 4096, 100);

    try std.testing.expect(app.session_persistence.session_picker.active);
    try std.testing.expectEqualStrings(" ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings(" ", app.session_persistence.session_picker.query());

    try Runtime(RoutingFakeApp).handleByte(&app, ' ', 4096, 100);

    try std.testing.expect(app.session_persistence.session_picker.active);
    try std.testing.expectEqualStrings("  ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("  ", app.session_persistence.session_picker.query());
}

test "app_input_runtime Enter binds a selected skill token" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "review",
        .description = "",
        .path = "/tmp/review/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("$review ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "$review ".len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("review", app.input_runtime.entities.skill_tokens.items[0].name);
    try std.testing.expectEqualStrings("/tmp/review/SKILL.md", app.input_runtime.entities.skill_tokens.items[0].path);
    try std.testing.expectEqual(@as(usize, "$review".len), app.input_runtime.entities.skill_tokens.items[0].raw_end);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expect(app.last_command == null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Unknown command") == null);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expect(app.last_command == null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Unknown command") == null);
}

test "app_input_runtime Enter reports a skill binding rejected by the input limit" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "review",
        .description = "",
        .path = "/tmp/review/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "$r suffix");
    app.input_runtime.edit_state.cursor = "$r".len;
    app.skills.openMenuWithQuery(.dollar, .{ .start = 0, .end = "$r".len }, "r");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', app.input_runtime.edit_state.input.items.len, 100);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("$r suffix", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "That edit exceeds the local prompt safety limit and was not applied.",
        app.notice_body.items,
    );
}

test "app_input_runtime redraws a closed skill picker when the input limit notice is coalesced" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "review",
        .description = "",
        .path = "/tmp/review/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "$r suffix");
    app.input_runtime.edit_state.cursor = "$r".len;
    app.skills.openMenuWithQuery(.dollar, .{ .start = 0, .end = "$r".len }, "r");
    const limit_transition = input_limit_rejection.begin(
        app.input_runtime.input_limit_rejection,
        .composer,
    );
    app.input_runtime.input_limit_rejection = limit_transition.next;
    try std.testing.expect(limit_transition.should_report);
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', app.input_runtime.edit_state.input.items.len, 100);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqualStrings("$r suffix", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
}

test "app_input_runtime keeps the skill picker open when binding allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "review",
        .description = "",
        .path = "/tmp/review/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(
        error.OutOfMemory,
        Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100),
    );

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuOrigin.command, app.skills.menu.origin);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
}

test "app_input_runtime Enter replaces the full command skills query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "man");
    app.skills.openMenuWithQuery(.command, null, "man");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("$managed ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("/tmp/managed/SKILL.md", app.input_runtime.entities.skill_tokens.items[0].path);
}

test "app_input_runtime command skills query tracks bracketed paste" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();

    try feedRoutingBytes(&app, "\x1b[200~man\x1b[201~");

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("man", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("man", app.skills.menu.query());
    try std.testing.expectEqualStrings("managed", app.skills.selectedMenuSkill().?.name);
}

test "app_input_runtime dollar opens skills menu and Escape preserves raw text" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "scale",
        .description = "",
        .path = "/tmp/scale/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);

    try Runtime(RoutingFakeApp).handleByte(&app, '$', 4096, 100);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuOrigin.dollar, app.skills.menu.origin);
    try std.testing.expectEqualStrings("", app.skills.menu.query());
    try std.testing.expectEqualStrings("$", app.input_runtime.edit_state.input.items);

    try Runtime(RoutingFakeApp).handleByte(&app, 's', 4096, 101);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("s", app.skills.menu.query());
    try std.testing.expectEqual(@as(usize, 0), app.skills.menu.target.?.start);
    try std.testing.expectEqual(@as(usize, 2), app.skills.menu.target.?.end);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 102);
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("$s", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime non-leading dollar stays in the composer" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "scale",
        .description = "",
        .path = "/tmp/scale/SKILL.md",
        .source = .global_fx,
    }};
    const inputs = [_][]const u8{ " $", "hello $" };

    for (inputs) |input| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.skills.items = @constCast(&skills);

        try feedRoutingBytes(&app, input);

        try std.testing.expectEqualStrings(input, app.input_runtime.edit_state.input.items);
        try std.testing.expect(!app.skills.menu.active);
    }
}

test "app_input_runtime Tab and Right Arrow accept visible inline skill completions" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};

    for ([_]enum { tab, right }{ .tab, .right }) |key| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.skills.items = @constCast(&skills);
        try feedRoutingBytes(&app, "explain $man");

        const completion = input_completion_runtime.CompletionRuntime(RoutingFakeApp).visibleInlineSkillCompletion(&app).?;
        try std.testing.expectEqualStrings("aged-menu", completion.suffix);
        try std.testing.expectEqualStrings("explain $man", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);

        switch (key) {
            .tab => try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100),
            .right => try Runtime(RoutingFakeApp).routeComposerShortcutAction(
                &app,
                .{ .move = .{ .kind = .character_right } },
                4096,
            ),
        }

        try std.testing.expectEqualStrings("explain $managed-menu ", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
        try std.testing.expectEqualStrings("managed-menu", app.input_runtime.entities.skill_tokens.items[0].name);
        try std.testing.expectEqualStrings("/tmp/managed-menu/SKILL.md", app.input_runtime.entities.skill_tokens.items[0].path);
        try std.testing.expectEqual("explain ".len, app.input_runtime.entities.skill_tokens.items[0].raw_start);
    }
}

test "app_input_runtime Tab and Right Arrow accept visible inline slash completions" {
    const alloc = std.testing.allocator;

    for ([_]enum { tab, right }{ .tab, .right }) |key| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try feedRoutingBytes(&app, "explain /he");

        const completion_rt = input_completion_runtime.CompletionRuntime(RoutingFakeApp);
        try std.testing.expectEqualStrings(
            "lp",
            completion_rt.visibleInlineSlashCompletion(&app).?.suffix,
        );
        try std.testing.expectEqualStrings("explain /he", app.input_runtime.edit_state.input.items);

        switch (key) {
            .tab => try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100),
            .right => try Runtime(RoutingFakeApp).routeComposerShortcutAction(
                &app,
                .{ .move = .{ .kind = .character_right } },
                4096,
            ),
        }

        try std.testing.expectEqualStrings("explain /help", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
    }
}

test "app_input_runtime Right Arrow collapses selection before inline completion" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.items = @constCast(&skills);
    try feedRoutingBytes(&app, "explain $man");
    const end = app.input_runtime.edit_state.input.items.len;
    _ = app.input_runtime.selectionState().begin(end - 1);
    _ = app.input_runtime.selectionState().extend(end);

    try Runtime(RoutingFakeApp).routeComposerShortcutAction(
        &app,
        .{ .move = .{ .kind = .character_right } },
        4096,
    );

    try std.testing.expectEqualStrings("explain $man", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.edit_state.selectionRange() == null);
    try std.testing.expectEqual(end, app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
}

test "app_input_runtime ctrl-l preserves an active inline picker" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.items = @constCast(&skills);
    try feedRoutingBytes(&app, "$man");
    try std.testing.expect(app.skills.menu.active);

    try Runtime(RoutingFakeApp).handleByte(&app, 12, 4096, 100);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("$man", app.input_runtime.edit_state.input.items);

    _ = try Runtime(RoutingFakeApp).routeResolvedEscapeAction(
        &app,
        .{ .composer_shortcut = .redraw },
        .redraw,
        null,
        null,
        null,
        false,
        4096,
    );
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("$man", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime Enter keeps backslash newline semantics when history allocation fails" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "draft\\");
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    app.alloc = failing.allocator();

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    app.alloc = alloc;

    try std.testing.expectEqualStrings("draft\n", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime Tab accepts a root slash completion after multiline whitespace" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "\n   /he");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expectEqualStrings("/help", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
}

test "app_input_runtime inline skill acceptance preserves input on limit rejection" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try feedRoutingBytes(&app, "explain $man");
    const original_len = app.input_runtime.edit_state.input.items.len;

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', original_len, 100);

    try std.testing.expectEqualStrings("explain $man", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "That edit exceeds the local prompt safety limit and was not applied.",
        app.notice_body.items,
    );
}

test "app_input_runtime no-match dollar text keeps spaces and submits raw" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);

    try feedRoutingBytes(&app, "Explain echo $HOME");
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("Explain echo $HOME", app.input_runtime.edit_state.input.items);

    try feedRoutingBytes(&app, " please");
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("Explain echo $HOME please", app.input_runtime.edit_state.input.items);

    try feedRoutingBytes(&app, "\r");
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings(
        "Explain echo $HOME please",
        app.submitted_prompt[0..app.submitted_prompt_len],
    );
}

test "app_input_runtime space after matched dollar token inserts and closes menu" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);

    try feedRoutingBytes(&app, "$man");
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expect(app.skills.selectedMenuSkill() != null);

    try feedRoutingBytes(&app, " x");
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("$man x", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);

    try feedRoutingBytes(&app, "\r");
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("$man x", app.submitted_prompt[0..app.submitted_prompt_len]);
}

test "app_input_runtime matched dollar token still binds on enter" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);

    try feedRoutingBytes(&app, "$man");
    try feedRoutingBytes(&app, "\r");

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("managed", app.input_runtime.entities.skill_tokens.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime enter on tab-filtered empty dollar menu submits raw" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_codex,
    }};
    app.skills.items = @constCast(&skills);

    try feedRoutingBytes(&app, "$man");
    try std.testing.expect(app.skills.selectedMenuSkill() != null);

    // .all -> .fx: the codex-sourced skill vanishes, nothing is selectable.
    try feedRoutingBytes(&app, "\t");
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expect(app.skills.selectedMenuSkill() == null);

    try feedRoutingBytes(&app, "\r");
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("$man", app.submitted_prompt[0..app.submitted_prompt_len]);
}

test "app_input_runtime enter submits after delete-forward removes the dollar anchor" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);

    try feedRoutingBytes(&app, "$x");
    try std.testing.expect(app.skills.menu.active);

    // Delete-forward removes the $ and synchronizes the tracked menu
    // immediately, so Enter proceeds through normal prompt submission.
    app.input_runtime.edit_state.cursor = 0;
    try feedRoutingBytes(&app, "\x04");
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("x", app.input_runtime.edit_state.input.items);

    try feedRoutingBytes(&app, "\r");
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("x", app.submitted_prompt[0..app.submitted_prompt_len]);
}

test "app_input_runtime zero-match dollar query recovers matches on backspace" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);

    try feedRoutingBytes(&app, "$mzz");
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expect(app.skills.selectedMenuSkill() == null);

    try feedRoutingBytes(&app, "\x7f\x7f");
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("m", app.skills.menu.query());
    try std.testing.expect(app.skills.selectedMenuSkill() != null);

    try feedRoutingBytes(&app, "\r");
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("managed", app.input_runtime.entities.skill_tokens.items[0].name);
}

test "app_input_runtime Escape cancels an idle session picker before empty-composer handling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.session_persistence.session_picker.active = true;

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);

    try std.testing.expect(!app.session_persistence.session_picker.active);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!app.worker.cancel_requested);
}

test "app_input_runtime stream Escape retains cancellation precedence over session picker state" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;

    try Runtime(RoutingFakeApp).resolveEscape(&app, true, 1);

    try std.testing.expect(!app.session_persistence.session_picker.active);
    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expect(!app.stream.active);
}

test "app_input_runtime stream Escape closes the skills menu without cancelling the active operation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.openMenu();
    app.stream.active = true;

    try Runtime(RoutingFakeApp).resolveEscape(&app, true, 1);

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expect(app.stream.active);
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime stream Escape dismisses the visible slash picker before cancelling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/he");
    app.stream.active = true;

    try Runtime(RoutingFakeApp).resolveEscape(&app, true, 1);

    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
    try std.testing.expect(app.stream.active);
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime model catalog owns search navigation and provider tabs" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try openRoutingModelMenu(&app, &.{ "anthropic/one", "openai/two", "private/three" });

    try Runtime(RoutingFakeApp).handleByte(&app, '$', 4096, 100);
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings("$", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("$", app.model_cache.menu.query());

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 101);
    try std.testing.expect(app.model_cache.menu.active);
    try std.testing.expectEqualStrings("", app.model_cache.menu.query());

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.menu.selected_index);

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 102);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.menu.provider_index);
    try std.testing.expectEqual(@as(usize, 0), app.model_cache.menu.selected_index);
    try std.testing.expectEqual(model_cache_runtime.ModelProviderFilter.anthropic, app.model_cache.menu.providerFilter());
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.menu.filteredItemCount());
}

test "app_input_runtime model catalog selection reuses immediate model persistence" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try openRoutingModelMenu(&app, &.{ "alpha/one", "beta/two" });

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.model_cache.menu.active);
    try std.testing.expectEqualStrings("alpha/one", app.selected_model.items);
    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings("alpha/one", app.last_preference_model.items);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime model catalog selection preserves effort and fast picker stages" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const model = "anthropic/claude-opus-4.8";
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
    app.setGatewayControls(model, &efforts, true);
    try openRoutingModelMenu(&app, &.{model});

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!app.model_cache.menu.active);
    try std.testing.expectEqualStrings("test/model", app.selected_model.items);
    try std.testing.expectEqualStrings("/model " ++ model ++ " ", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
}

test "app_input_runtime stream Escape closes the model catalog without cancelling the active operation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try openRoutingModelMenu(&app, &.{"alpha/one"});
    app.stream.active = true;

    try Runtime(RoutingFakeApp).resolveEscape(&app, true, 1);

    try std.testing.expect(!app.model_cache.menu.active);
    try std.testing.expect(app.stream.active);
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime unselectable model catalog states consume Enter without submitting" {
    const Case = enum { loading, failed, no_match };
    for ([_]Case{ .loading, .failed, .no_match }) |case| {
        const alloc = std.testing.allocator;
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        switch (case) {
            .loading, .failed => {
                app.model_cache.menu.active = true;
                app.model_cache.menu.load_state = if (case == .loading) .loading else .failed;
            },
            .no_match => {
                try openRoutingModelMenu(&app, &.{"alpha/one"});
                app.model_cache.menu.setQuery("missing");
            },
        }

        try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

        try std.testing.expect(app.model_cache.menu.active);
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
        try std.testing.expect(app.last_command == null);
    }
}

test "app_input_runtime typing filters the active session catalog" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.session_persistence.session_picker.active = true;

    try std.testing.expect(Runtime(RoutingFakeApp).isComposerEditingByte(22, null));

    try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);

    try std.testing.expect(app.session_persistence.session_picker.active);
    try std.testing.expectEqualStrings("x", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("x", app.session_persistence.session_picker.query());
}

test "app_input_runtime session catalog keeps Shift Enter out of the search query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.session_persistence.session_picker.active = true;
    try app.input_runtime.textReplacementState().replace(alloc, "session");
    app.session_persistence.session_picker.setQuery(app.input_runtime.edit_state.input.items);

    try Runtime(RoutingFakeApp).routeComposerShortcutAction(&app, .insert_newline, 4096);

    try std.testing.expectEqualStrings("session", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("session", app.session_persistence.session_picker.query());
}

test "app_input_runtime session picker navigation clamps before prompt history" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    for (0..2) |index| try appendRoutingSessionPickerSummary(alloc, picker, index);

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), picker.selected);

    // At the last session, down clamps (stays on the last) and does not fall
    // through to prompt history.
    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), picker.selected);
}

test "app_input_runtime Enter consumes an active session picker on target failure" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    try picker.summaries.append(alloc, .{
        .id = try alloc.dupe(u8, "missing-session"),
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .history_len = 0,
    });

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(picker.active);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expectEqual(session_catalog.ResumeFailure.unavailable, picker.selection_failure.?);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "unable to resume") == null);
}

test "app_input_runtime reports resume failure after picker transition" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    try picker.summaries.append(alloc, .{
        .id = try alloc.dupe(u8, "broken-session"),
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .history_len = 1,
    });
    app.resume_selected_closes_picker = true;
    app.resume_selected_error = error.SessionCommitBoundaryUnavailable;

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!picker.active);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqualStrings("Unable to resume selected session.", app.notice_body.items);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "SessionCommitBoundaryUnavailable") == null);
}

test "app_input_runtime Enter loads the next session page from the catalog action" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    picker.has_more = true;
    for (0..2) |index| try appendRoutingSessionPickerSummary(alloc, picker, index);
    picker.selected = picker.filteredItemCount();

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.load_more_session_count);
    try std.testing.expectEqual(@as(usize, 0), app.resume_selected_count);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expect(picker.active);
}

test "app_input_runtime Enter consumes an empty session catalog result" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const picker = &app.session_persistence.session_picker;
    picker.active = true;
    picker.load_state = .ready;
    try appendRoutingSessionPickerSummary(alloc, picker, 0);
    picker.setQuery("missing");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 0), app.resume_selected_count);
    try std.testing.expect(picker.active);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime approval escape arrows move choices directly" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    app.approval_prompt.decision.choice_index = 1;
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .history_up, null);
    try std.testing.expectEqual(@as(u8, 0), app.approval_prompt.decision.choice_index);
    try std.testing.expectEqual(@as(usize, 0), app.approval_screen.document_scroll_rows);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    app.approval_prompt.decision.choice_index = 1;
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .cursor_left, null);
    try std.testing.expectEqual(@as(u8, 0), app.approval_prompt.decision.choice_index);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    app.approval_prompt.decision.choice_index = 1;
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .history_down, null);
    try std.testing.expectEqual(@as(u8, 2), app.approval_prompt.decision.choice_index);
    try std.testing.expectEqual(@as(usize, 0), app.approval_screen.document_scroll_rows);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    app.approval_prompt.decision.choice_index = 1;
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .cursor_right, null);
    try std.testing.expectEqual(@as(u8, 2), app.approval_prompt.decision.choice_index);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime approval amendment arrows edit the selected draft" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .label = "terminal.exec npm test",
    }));
    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'a', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'b', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'c', 4096, 100);

    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .cursor_left, null);
    try std.testing.expectEqual(@as(usize, 3), app.approval_prompt.draftCursorForChoice(0));
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .cursor_left, .cursor_left);
    try std.testing.expectEqual(@as(u8, 0), app.approval_prompt.decision.choice_index);
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expectEqual(@as(usize, 2), app.approval_prompt.draftCursorForChoice(0));
}

test "app_input_runtime routes approval amendment home end delete and word movement" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .label = "terminal.exec npm test",
    }));
    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    for ("alpha beta") |byte| try Runtime(RoutingFakeApp).handleByte(&app, byte, 4096, 100);

    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .home, .cursor_home);
    try std.testing.expectEqual(@as(usize, 0), app.approval_prompt.draftCursorForChoice(0));
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .word_right, .cursor_word_right);
    try std.testing.expectEqual(@as(usize, "alpha".len), app.approval_prompt.draftCursorForChoice(0));
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .delete_next, .delete_next);
    try std.testing.expectEqualStrings("alphabeta", app.approval_prompt.decision.selectedDraft());
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(&app, .end, .cursor_end);
    try std.testing.expectEqual(app.approval_prompt.decision.selectedDraft().len, app.approval_prompt.draftCursorForChoice(0));
}

test "app_input_runtime routes focused editor aliases into approval amendment only" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "hidden composer");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .label = "terminal.exec npm test",
    }));

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try feedRoutingBytes(&app, "alpha beta gamma");

    try Runtime(RoutingFakeApp).handleByte(&app, 1, 4096, 100);
    try std.testing.expectEqual(@as(usize, 0), app.approval_prompt.draftCursorForChoice(0));
    try Runtime(RoutingFakeApp).handleByte(&app, 5, 4096, 100);
    try std.testing.expectEqual(app.approval_prompt.decision.selectedDraft().len, app.approval_prompt.draftCursorForChoice(0));
    try Runtime(RoutingFakeApp).handleByte(&app, 2, 4096, 100);
    try std.testing.expectEqual(app.approval_prompt.decision.selectedDraft().len - 1, app.approval_prompt.draftCursorForChoice(0));
    try Runtime(RoutingFakeApp).handleByte(&app, 6, 4096, 100);
    try std.testing.expectEqual(app.approval_prompt.decision.selectedDraft().len, app.approval_prompt.draftCursorForChoice(0));

    try Runtime(RoutingFakeApp).handleByte(&app, 23, 4096, 100);
    try std.testing.expectEqualStrings("alpha beta ", app.approval_prompt.decision.selectedDraft());
    try Runtime(RoutingFakeApp).handleByte(&app, 21, 4096, 100);
    try std.testing.expectEqualStrings("", app.approval_prompt.decision.selectedDraft());

    try feedRoutingBytes(&app, "alpha beta");
    try Runtime(RoutingFakeApp).handleByte(&app, 1, 4096, 100);
    try feedRoutingBytes(&app, "\x1bd");
    try std.testing.expectEqualStrings("beta", app.approval_prompt.decision.selectedDraft());
    try Runtime(RoutingFakeApp).handleByte(&app, 5, 4096, 100);
    try feedRoutingBytes(&app, "\x1b\x7f");
    try std.testing.expectEqualStrings("", app.approval_prompt.decision.selectedDraft());

    try feedRoutingBytes(&app, "left right");
    try Runtime(RoutingFakeApp).handleByte(&app, 1, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 6, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 11, 4096, 100);
    try std.testing.expectEqualStrings("l", app.approval_prompt.decision.selectedDraft());
    try std.testing.expectEqualStrings("hidden composer", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime approval wheel scrolls only a committed overflowing file document" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        routingFileApprovalRequest(41),
    ));

    app.approval_screen.recordScreenCommit(41, .{
        .request_id = 41,
        .rows = 24,
        .cols = 80,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });
    app.approval_screen.document_scroll_rows = 3;
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(
        &app,
        .{ .mouse_wheel = .up },
        null,
    );
    try std.testing.expectEqual(@as(usize, 6), app.approval_screen.document_scroll_rows);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    app.approval_screen.recordScreenCommit(41, .{
        .request_id = 41,
        .rows = 24,
        .cols = 80,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = false,
    });
    try Runtime(RoutingFakeApp).routeApprovalEscapeAction(
        &app,
        .{ .mouse_wheel = .down },
        null,
    );
    try std.testing.expectEqual(@as(usize, 6), app.approval_screen.document_scroll_rows);
    try std.testing.expect(!app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime submits raw model command when picker has no selection" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "/model custom/provider-model\r");

    try std.testing.expect(app.last_command != null);
    try std.testing.expectEqualStrings("/model custom/provider-model", app.last_command.?);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "explicit model selection parser accepts complete picker syntax" {
    const selection = switch (parseExplicitModelSelection(
        "/model anthropic/claude-opus-4.7 auto normal",
    )) {
        .selection => |selection| selection,
        else => return error.TestExpectedEqual,
    };

    try std.testing.expectEqualStrings(
        "anthropic/claude-opus-4.7",
        selection.model,
    );
    try std.testing.expectEqual(types.ReasoningEffort.auto, selection.effort);
    try std.testing.expect(!selection.fast_mode);
    try std.testing.expect(selection.has_fast_mode_token);
}

test "explicit model selection semantic validation uses resolved capabilities" {
    const high_efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    const xhigh_efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("xhigh")};
    const unsupported_fast = switch (parseExplicitModelSelection(
        "/model anthropic/claude-sonnet-4.6 auto normal",
    )) {
        .selection => |selection| selection,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(validateExplicitModelSelection(
        unsupported_fast,
        model_capabilities.capabilitiesForModel(unsupported_fast.model),
    ) == .invalid);

    const gateway_reasoning_only = switch (parseExplicitModelSelection(
        "/model provider/new-reasoning-model high",
    )) {
        .selection => |selection| selection,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(validateExplicitModelSelection(
        gateway_reasoning_only,
        model_capabilities.resolveCapabilities(gateway_reasoning_only.model, .{ .reasoning_efforts = .fromSlice(&high_efforts) }),
    ) != .invalid);

    const unsupported_portable = switch (parseExplicitModelSelection(
        "/model provider/new-reasoning-model max",
    )) {
        .selection => |selection| selection,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(validateExplicitModelSelection(
        unsupported_portable,
        model_capabilities.resolveCapabilities(unsupported_portable.model, .{ .reasoning_efforts = .fromSlice(&high_efforts) }),
    ) == .invalid);

    const verified = switch (parseExplicitModelSelection(
        "/model anthropic/claude-opus-4.8 xhigh fast",
    )) {
        .selection => |selection| selection,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(validateExplicitModelSelection(
        verified,
        model_capabilities.resolveCapabilities(verified.model, .{
            .reasoning_efforts = .fromSlice(&xhigh_efforts),
            .supports_fast_mode = true,
        }),
    ) != .invalid);
}

test "model picker spaces do not commit before enter" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(
        alloc,
        "/model anthropic/claude-sonnet-4.6 auto",
    );
    try app.input_runtime.picker.beginModelPickerFlow(
        alloc,
        "anthropic/claude-sonnet-4.6",
        0,
        false,
        .effort,
    );

    try std.testing.expect(
        !try Runtime(RoutingFakeApp).advanceModelPickerOnSpace(&app),
    );
    try std.testing.expectEqualStrings(
        "/model anthropic/claude-sonnet-4.6 auto",
        app.input_runtime.edit_state.input.items,
    );
}

test "model picker enter commits selected fast option from fast stage" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    app.setGatewayControls("anthropic/claude-opus-4.7", &efforts, true);

    try app.input_runtime.textReplacementState().replace(
        alloc,
        "/model anthropic/claude-opus-4.7 auto ",
    );
    try app.input_runtime.picker.beginModelPickerFlow(
        alloc,
        "anthropic/claude-opus-4.7",
        0,
        false,
        .fast,
    );

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings(
        "anthropic/claude-opus-4.7",
        app.selected_model.items,
    );
    try std.testing.expectEqualStrings(
        "anthropic/claude-opus-4.7",
        app.last_preference_model.items,
    );
    try std.testing.expectEqual(types.ReasoningEffort.auto, app.effort);
    try std.testing.expectEqual(types.ReasoningEffort.auto, app.last_preference_effort.?);
    try std.testing.expect(!app.fast_mode);
    try std.testing.expectEqual(false, app.last_preference_fast_mode.?);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings(
        "Switched to anthropic/claude-opus-4.7",
        app.notice_body.items,
    );
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Invalid /model selection") == null);
}

test "active stream Enter commits a complete model choice for the next turn" {
    const alloc = std.testing.allocator;
    const model = "openai/gpt-5";
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    app.setGatewayControls(model, &efforts, false);

    try app.input_runtime.textReplacementState().replace(alloc, "/model " ++ model ++ " auto");
    try app.input_runtime.picker.beginModelPickerFlow(
        alloc,
        model,
        0,
        false,
        .effort,
    );
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(app.stream.active);
    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings(model, app.selected_model.items);
    try std.testing.expectEqualStrings(model, app.last_preference_model.items);
    try std.testing.expectEqual(types.ReasoningEffort.auto, app.effort);
    try std.testing.expectEqual(types.ReasoningEffort.auto, app.last_preference_effort.?);
    try std.testing.expect(app.last_preference_fast_mode == null);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expectEqualStrings(
        "Next turn will use " ++ model,
        app.notice_body.items,
    );
}

test "active stream Enter explains an incomplete hidden model choice" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try app.input_runtime.textReplacementState().replace(alloc, "/model openai/gpt");
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(app.stream.active);
    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
    try std.testing.expectEqualStrings("/model openai/gpt", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings(
        "Complete the model selection for the next turn: /model <id> <effort> [normal|fast].",
        app.notice_body.items,
    );
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime model picker Enter ignores hidden slash skill matches" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "model-helper",
        .description = "model helper",
        .path = "/tmp/model-helper/SKILL.md",
        .source = .global_fx,
    }};
    const completions = [_][]const u8{"xai/grok-build-1"};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.items = @constCast(&skills);
    app.model_completion_values = &completions;
    try app.input_runtime.textReplacementState().replace(alloc, "/model");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqualStrings("/model ", app.input_runtime.edit_state.input.items);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings("xai/grok-build-1", app.selected_model.items);
    try std.testing.expectEqualStrings("xai/grok-build-1", app.last_preference_model.items);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Invalid /model selection") == null);
}

test "app_input_runtime bare model opens on current scrolled selection before staging effort" {
    const alloc = std.testing.allocator;
    const current_model = "anthropic/claude-opus-4.8";
    const completions = [_][]const u8{
        "provider/model-0",
        "provider/model-1",
        "provider/model-2",
        "provider/model-3",
        "provider/model-4",
        "provider/model-5",
        current_model,
    };

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    app.setGatewayControls(current_model, &efforts, true);
    app.model_completion_values = &completions;
    app.selected_model.clearRetainingCapacity();
    try app.selected_model.appendSlice(alloc, current_model);
    app.effort = types.ReasoningEffort.literal("high");
    app.fast_mode = false;
    try app.input_runtime.textReplacementState().replace(alloc, "/model");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("/model ", app.input_runtime.edit_state.input.items);
    var projected: [32][]const u8 = undefined;
    const projected_count = input_completion_runtime.CompletionRuntime(RoutingFakeApp).modelPickerCompletions(&app, "", &projected);
    const projected_index = input_completion_runtime.CompletionRuntime(RoutingFakeApp).modelPickerIndex(&app, projected[0..projected_count]);
    try std.testing.expectEqual(@as(usize, 6), projected_index);
    try std.testing.expectEqual(@as(usize, 1), input_completion_runtime.CompletionRuntime(RoutingFakeApp).modelPickerWindowStart(&app, projected_count, projected_index));
    try std.testing.expectEqualStrings(current_model, app.selected_model.items);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), app.effort);
    try std.testing.expect(!app.fast_mode);
    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
    try std.testing.expect(!app.input_runtime.picker.hasPendingModelPickerSelection());

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings(current_model, app.input_runtime.picker.model_picker_pending_model.items);
    // The effort stage lands on the product default rather
    // than the session's current effort.
    try std.testing.expectEqual(
        0,
        app.input_runtime.picker.model_picker_effort_index,
    );
    try std.testing.expect(app.input_runtime.picker.selectedModelPickerFast());
    try std.testing.expectEqualStrings(current_model, app.selected_model.items);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), app.effort);
    try std.testing.expect(!app.fast_mode);
    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
}

test "app_input_runtime bare model keeps current selection across catalog readiness" {
    const alloc = std.testing.allocator;
    const current_model = "anthropic/claude-opus-4.8";
    const completions = [_][]const u8{
        "provider/model-0",
        current_model,
    };

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    app.setGatewayControls(current_model, &efforts, false);
    app.model_completion_values = &completions;
    app.model_cache_loading = true;
    app.selected_model.clearRetainingCapacity();
    try app.selected_model.appendSlice(alloc, current_model);
    try app.input_runtime.textReplacementState().replace(alloc, "/model");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    app.model_cache_loading = false;
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings(current_model, app.input_runtime.picker.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
}

test "app_input_runtime bare model keeps current selection beyond completion window" {
    const alloc = std.testing.allocator;
    const current_model = "anthropic/claude-opus-4.8";
    var completions = [_][]const u8{"anthropic/claude-opus-4.8-preview"} ** 33;
    completions[completions.len - 1] = current_model;

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    app.setGatewayControls(current_model, &efforts, false);
    app.model_completion_values = &completions;
    app.selected_model.clearRetainingCapacity();
    try app.selected_model.appendSlice(alloc, current_model);
    try app.input_runtime.textReplacementState().replace(alloc, "/model");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings(current_model, app.input_runtime.picker.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
}

test "app_input_runtime stream model-shaped keys stay model-owned" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "model-helper",
        .description = "model helper",
        .path = "/tmp/model-helper/SKILL.md",
        .source = .global_fx,
    }};
    const completions = [_][]const u8{"xai/grok-build-1"};
    const cases = [_]struct {
        input: []const u8,
        byte: u8,
        expect_input: []const u8,
    }{
        .{ .input = "/model ", .byte = '\r', .expect_input = "/model " },
        .{ .input = "/model", .byte = '\r', .expect_input = "/model " },
        .{ .input = "/model", .byte = '\t', .expect_input = "/model" },
        .{ .input = "/model ", .byte = '\t', .expect_input = "/model " },
    };

    for (cases) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.skills.items = @constCast(&skills);
        app.model_completion_values = &completions;
        app.selected_model.clearRetainingCapacity();
        try app.selected_model.appendSlice(alloc, "anthropic/claude-opus-4.7");
        app.stream.active = true;
        try app.input_runtime.textReplacementState().replace(alloc, case.input);

        try Runtime(RoutingFakeApp).handleByte(&app, case.byte, 4096, 100);

        try std.testing.expectEqualStrings(case.expect_input, app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
        try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", app.selected_model.items);
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    }
}

test "app_input_runtime Enter submits a dismissed slash skill query as text" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "custom-skill",
        .description = "custom skill",
        .path = "/tmp/custom-skill/SKILL.md",
        .source = .global_fx,
    }};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "/custom");
    app.input_runtime.picker.dismissInlinePicker(.slash);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(app.last_command == null);
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings(
        "/custom",
        app.submitted_prompt[0..app.submitted_prompt_len],
    );
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
}

test "app_input_runtime Enter binds a slash skill after multiline whitespace" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "custom-skill",
        .description = "custom skill",
        .path = "/tmp/custom-skill/SKILL.md",
        .source = .global_fx,
    }};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "\n   /custom");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("\n   $custom-skill ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("custom-skill", app.input_runtime.entities.skill_tokens.items[0].name);
    try std.testing.expectEqual(@as(usize, 4), app.input_runtime.entities.skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime retired slash alias no longer shadows a matching skill" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "input-helper",
        .description = "input helper",
        .path = "/tmp/input-helper/SKILL.md",
        .source = .global_fx,
    }};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.items = @constCast(&skills);
    try app.input_runtime.textReplacementState().replace(alloc, "/input");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(app.last_command == null);
    try std.testing.expectEqualStrings("$input-helper ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
}

test "app_input_runtime file picker replaces only the active query for Tab and Enter" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "src/main.zig", .kind = .file }};
    const before_suffix = "prefix @mai";
    const input = before_suffix ++ "/suffix";
    const expected = "prefix @src/main.zig /suffix";
    const expected_cursor = "prefix @src/main.zig ".len;

    for ([_]u8{ '\t', '\r' }) |byte| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.file_completion_values = &completions;
        try app.input_runtime.textReplacementState().replace(alloc, input);
        app.input_runtime.edit_state.cursor = before_suffix.len;

        try Runtime(RoutingFakeApp).handleByte(&app, byte, 4096, 100);

        try std.testing.expectEqualStrings(expected, app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(expected_cursor, app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    }
}

test "app_input_runtime file completion preserves a selected skill binding" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const completions = [_]file_index.Candidate{.{ .path = "target.txt", .kind = .file }};
    app.file_completion_values = &completions;
    try app.input_runtime.textReplacementState().replace(alloc, "review @tar");
    try app.input_runtime.skillBindingState().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    );
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expectEqualStrings("$review @target.txt ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("review", app.input_runtime.entities.skill_tokens.items[0].name);
    try std.testing.expectEqualStrings(
        "/tmp/review/SKILL.md",
        app.input_runtime.entities.skill_tokens.items[0].path,
    );
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, "$review".len), app.input_runtime.entities.skill_tokens.items[0].raw_end);
}

test "app_input_runtime file picker reuses one existing terminator and preserves the tail" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "src/main.zig", .kind = .file }};
    const prefix = "prefix @mai";
    const cases = [_]struct {
        tail: []const u8,
        expected_tail: []const u8,
    }{
        .{ .tail = "", .expected_tail = " " },
        .{ .tail = "/suffix", .expected_tail = " /suffix" },
        .{ .tail = " suffix", .expected_tail = " suffix" },
        .{ .tail = "\tsuffix", .expected_tail = "\tsuffix" },
        .{ .tail = "\rsuffix", .expected_tail = "\rsuffix" },
        .{ .tail = "\nsuffix", .expected_tail = "\nsuffix" },
        .{ .tail = "  suffix", .expected_tail = "  suffix" },
    };

    for (cases) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.file_completion_values = &completions;
        const input = try std.mem.concat(alloc, u8, &.{ prefix, case.tail });
        defer alloc.free(input);
        try app.input_runtime.textReplacementState().replace(alloc, input);
        app.input_runtime.edit_state.cursor = prefix.len;

        try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

        const expected = try std.mem.concat(alloc, u8, &.{ "prefix @src/main.zig", case.expected_tail });
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual("prefix @src/main.zig".len + 1, app.input_runtime.edit_state.cursor);
        try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) == null);
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    }
}

test "app_input_runtime accepts typed directories with one synthetic slash" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "src/nested", .kind = .directory }};
    const cases = [_]struct {
        input: []const u8,
        cursor: usize,
        expected: []const u8,
        expected_cursor: usize,
    }{
        .{
            .input = "@srcn",
            .cursor = "@srcn".len,
            .expected = "@src/nested/",
            .expected_cursor = "@src/nested/".len,
        },
        .{
            .input = "before @srcn tail",
            .cursor = "before @srcn".len,
            .expected = "before @src/nested/ tail",
            .expected_cursor = "before @src/nested/".len,
        },
    };

    for ([_]u8{ '\t', '\r' }) |byte| {
        for (cases) |case| {
            var app = try RoutingFakeApp.init(alloc);
            defer app.deinit();
            app.file_completion_values = &completions;
            app.expected_file_completion_kind = .directory;
            try app.input_runtime.textReplacementState().replace(alloc, case.input);
            app.input_runtime.edit_state.cursor = case.cursor;

            try Runtime(RoutingFakeApp).handleByte(&app, byte, 4096, 100);

            try std.testing.expectEqualStrings(case.expected, app.input_runtime.edit_state.input.items);
            try std.testing.expectEqual(case.expected_cursor, app.input_runtime.edit_state.cursor);
            try std.testing.expectEqual(file_index.CandidateKind.directory, app.validated_file_completion_kind.?);
            try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null);
            try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
        }
    }
}

test "app_input_runtime counts the directory slash against the input limit" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "src", .kind = .directory }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &completions;
    try app.input_runtime.textReplacementState().replace(alloc, "@s");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', "@src/".len - 1, 100);

    try std.testing.expectEqualStrings("@s", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime quotes whitespace paths only while they are active" {
    const alloc = std.testing.allocator;
    const directory = [_]file_index.Candidate{.{ .path = "space dir", .kind = .directory }};
    const file = [_]file_index.Candidate{.{ .path = "space dir/item.txt", .kind = .file }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &directory;
    try app.input_runtime.textReplacementState().replace(alloc, "@space");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try std.testing.expectEqualStrings("@\"space dir/", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null);

    app.file_completion_values = &file;
    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try std.testing.expectEqualStrings("@\"space dir/item.txt\" ", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) == null);
}

test "app_input_runtime rejects whitespace paths that the quote grammar cannot represent" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "space\" dir", .kind = .directory }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &completions;
    try app.input_runtime.textReplacementState().replace(alloc, "@space");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try std.testing.expectEqualStrings("@space", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime rejects kind-changed selections and preserves the query" {
    const alloc = std.testing.allocator;
    const cases = [_]file_index.Candidate{
        .{ .path = "file-became-directory", .kind = .file },
        .{ .path = "directory-became-file", .kind = .directory },
    };
    for (cases) |candidate| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.file_completion_values = &.{candidate};
        app.expected_file_completion_kind = switch (candidate.kind) {
            .file => .directory,
            .directory => .file,
        };
        try app.input_runtime.textReplacementState().replace(alloc, "@changed");

        try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

        try std.testing.expectEqualStrings("@changed", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(candidate.kind, app.validated_file_completion_kind.?);
        try std.testing.expectEqual(@as(usize, 1), app.file_index_refresh_count);
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    }
}

test "app_input_runtime consumes file search errors without stale insertion" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &.{.{ .path = "stale.txt", .kind = .file }};
    app.file_completion_error = error.NoSpaceLeft;
    try app.input_runtime.textReplacementState().replace(alloc, "@stale");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("@stale", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime file query without a selection submits as ordinary prompt text" {
    const alloc = std.testing.allocator;
    const states = [_]struct { loading: bool, failed: bool }{
        .{ .loading = false, .failed = false },
        .{ .loading = true, .failed = false },
        .{ .loading = false, .failed = true },
    };

    for (states) |state| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.file_index_loading = state.loading;
        app.file_index_failed = state.failed;
        try app.input_runtime.textReplacementState().replace(alloc, "@not-present");

        try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
        try std.testing.expectEqualStrings(
            "@not-present",
            app.submitted_prompt[0..app.submitted_prompt_len],
        );
    }
}

test "app_input_runtime dismissed file query submits as ordinary prompt text" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "@not-present");

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("@not-present", app.submitted_prompt[0..app.submitted_prompt_len]);
}

test "app_input_runtime stale file selection is rejected and refreshed" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "deleted.txt", .kind = .file }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &completions;
    app.file_completion_current = false;
    try app.input_runtime.textReplacementState().replace(alloc, "@deleted");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("@deleted", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.file_index_refresh_count);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime stale explicit selection does not refresh the workspace index" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "../deleted.txt", .kind = .file }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &completions;
    app.file_completion_current = false;
    app.file_completions_depend_on_index = false;
    try app.input_runtime.textReplacementState().replace(alloc, "@../deleted");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("@../deleted", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.file_index_refresh_count);
}

test "app_input_runtime stale Tab selection requests a footer repaint" {
    const alloc = std.testing.allocator;
    const completions = [_]file_index.Candidate{.{ .path = "deleted.txt", .kind = .file }};
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_completion_values = &completions;
    app.file_completion_current = false;
    try app.input_runtime.textReplacementState().replace(alloc, "@deleted");

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

    try std.testing.expectEqualStrings("@deleted", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.file_index_refresh_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime terminated file tokens submit while streaming queries stay local" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.textReplacementState().replace(alloc, "@literal ");
        try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
        try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
        try std.testing.expectEqualStrings("@literal ", app.submitted_prompt[0..app.submitted_prompt_len]);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try app.input_runtime.textReplacementState().replace(alloc, "@queued");
        try std.testing.expect(!Runtime(RoutingFakeApp).nonSlashPickerOwnsEnter(&app));
        try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
        try std.testing.expectEqualStrings("@queued", app.submitted_prompt[0..app.submitted_prompt_len]);
    }
}

test "app_input_runtime refreshes each file picker episode after startup loading" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    for ("@first") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expect(app.input_runtime.picker.file_picker_episode_seen);
    try std.testing.expectEqual(@as(usize, 1), app.file_index_refresh_count);

    try Runtime(RoutingFakeApp).handleTerminalByte(&app, ' ', 4096, 100);
    try Runtime(RoutingFakeApp).handleTerminalByte(&app, '@', 4096, 100);
    try std.testing.expectEqual(@as(usize, 2), app.file_index_refresh_count);

    for ("second") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expectEqual(@as(usize, 2), app.file_index_refresh_count);

    try Runtime(RoutingFakeApp).handleTerminalByte(&app, ' ', 4096, 100);
    try Runtime(RoutingFakeApp).handleTerminalByte(&app, '@', 4096, 100);
    try std.testing.expectEqual(@as(usize, 3), app.file_index_refresh_count);
}

test "app_input_runtime preserves exact refresh accounting across one thousand file picker episodes" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    for (0..1_000) |episode| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, '@', 4_096, 100);
        try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null);
        try std.testing.expectEqual(episode + 1, app.file_index_refresh_count);

        try Runtime(RoutingFakeApp).handleTerminalByte(&app, 'x', 4_096, 100);
        try std.testing.expectEqual(episode + 1, app.file_index_refresh_count);
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, ' ', 4_096, 100);
        try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) == null);
    }

    try std.testing.expect(app.input_runtime.picker.file_picker_episode_seen);
    try std.testing.expectEqual(@as(usize, 1_000), app.file_index_refresh_count);
    try std.testing.expectEqual(@as(usize, 3_000), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime does not duplicate the startup file index load" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.file_index_loading = true;

    for ("@first") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expect(app.input_runtime.picker.file_picker_episode_seen);
    try std.testing.expectEqual(@as(usize, 0), app.file_index_refresh_count);

    app.file_index_loading = false;
    try Runtime(RoutingFakeApp).handleTerminalByte(&app, ' ', 4096, 100);
    try Runtime(RoutingFakeApp).handleTerminalByte(&app, '@', 4096, 100);
    try std.testing.expectEqual(@as(usize, 1), app.file_index_refresh_count);
}

test "app_input_runtime file picker navigation respects completion cap" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    var values: [file_picker_completion_cap + 1]file_index.Candidate = undefined;
    for (&values) |*value| value.* = .{ .path = "main.zig", .kind = .file };
    app.file_completion_values = values[0..];
    try app.input_runtime.textReplacementState().replace(alloc, "prefix @mai /suffix");
    app.input_runtime.edit_state.cursor = "prefix @mai".len;
    app.input_runtime.picker.file_completion_index = file_picker_completion_cap - 1;

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.file_completion_index);
}

test "app_input_runtime file picker window moves up before reverse scrolling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const completions: []const file_index.Candidate = &.{
        .{ .path = "main0.zig", .kind = .file },
        .{ .path = "main1.zig", .kind = .file },
        .{ .path = "main2.zig", .kind = .file },
        .{ .path = "main3.zig", .kind = .file },
        .{ .path = "main4.zig", .kind = .file },
        .{ .path = "main5.zig", .kind = .file },
        .{ .path = "main6.zig", .kind = .file },
        .{ .path = "main7.zig", .kind = .file },
    };
    app.file_completion_values = completions;
    try app.input_runtime.textReplacementState().replace(alloc, "prefix @mai /suffix");
    app.input_runtime.edit_state.cursor = "prefix @mai".len;

    var down: usize = 0;
    while (down < 6) : (down += 1) {
        try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .down, 1);
    }
    try std.testing.expectEqual(@as(usize, 6), app.input_runtime.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.file_completion_window_start);

    try Runtime(RoutingFakeApp).routeModifiedHistory(&app, .up, -1);
    try std.testing.expectEqual(@as(usize, 5), app.input_runtime.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.file_completion_window_start);
}

test "app_input_runtime model picker window moves up before reverse scrolling" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const completions: []const []const u8 = &.{
        "provider/model-0",
        "provider/model-1",
        "provider/model-2",
        "provider/model-3",
        "provider/model-4",
        "provider/model-5",
        "provider/model-6",
        "provider/model-7",
    };
    app.model_completion_values = completions;
    try app.input_runtime.textReplacementState().replace(alloc, "/model ");

    var down: usize = 0;
    while (down < 6) : (down += 1) {
        Runtime(RoutingFakeApp).navigateModelPicker(&app, 1);
    }
    try std.testing.expectEqual(@as(usize, 6), app.input_runtime.picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.model_completion_window_start);

    Runtime(RoutingFakeApp).navigateModelPicker(&app, -1);
    try std.testing.expectEqual(@as(usize, 5), app.input_runtime.picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.model_completion_window_start);
}

test "app_input_runtime model picker consumes Enter while cache is loading for an empty query" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.model_cache_loading = true;
    try app.input_runtime.textReplacementState().replace(alloc, "/model ");
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("/model ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime model picker preserves staged selections and backs out safely" {
    const alloc = std.testing.allocator;
    const completions = [_][]const u8{
        "openai/gpt-4o",
        "anthropic/claude-opus-4.7",
    };

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("medium"),
        types.ReasoningEffort.literal("high"),
    };
    app.setGatewayControls("anthropic/claude-opus-4.7", &efforts, true);
    app.model_completion_values = &completions;
    app.fast_mode = true;
    try app.input_runtime.textReplacementState().replace(alloc, "/model ");
    app.input_runtime.picker.model_completion_index = 1;

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings(
        "anthropic/claude-opus-4.7",
        app.input_runtime.picker.model_picker_pending_model.items,
    );

    const effort_input_end = app.input_runtime.edit_state.input.items.len;
    _ = app.input_runtime.selectionState().begin(effort_input_end - 1);
    _ = app.input_runtime.selectionState().extend(effort_input_end);
    try feedRoutingBytes(&app, "\x1b[D");
    try std.testing.expectEqual(ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);
    try std.testing.expect(app.input_runtime.edit_state.selectionRange() == null);
    try std.testing.expectEqual(effort_input_end - 1, app.input_runtime.edit_state.cursor);

    try feedRoutingBytes(&app, "\x1b[D");
    try std.testing.expectEqual(ModelPickerStage.model, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings("/model anthropic/claude-opus-4.7", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.model_completion_index);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    Runtime(RoutingFakeApp).navigateModelPicker(&app, 2);
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(ModelPickerStage.fast, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings(
        "/model anthropic/claude-opus-4.7 medium ",
        app.input_runtime.edit_state.input.items,
    );
    // The fast stage lands on the recommended fast default; navigation
    // still reaches normal and back.
    try std.testing.expect(app.input_runtime.picker.selectedModelPickerFast());
    Runtime(RoutingFakeApp).navigateModelPicker(&app, 1);
    try std.testing.expect(!app.input_runtime.picker.selectedModelPickerFast());
    Runtime(RoutingFakeApp).navigateModelPicker(&app, 1);
    try std.testing.expect(app.input_runtime.picker.selectedModelPickerFast());

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", app.selected_model.items);
    try std.testing.expectEqual(types.ReasoningEffort.literal("medium"), app.effort);
    try std.testing.expect(app.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("medium"), app.last_preference_effort.?);
    try std.testing.expectEqual(true, app.last_preference_fast_mode.?);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime model picker commits a model without options directly" {
    const alloc = std.testing.allocator;
    const completions = [_][]const u8{"openai/gpt-4o"};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.model_completion_values = &completions;
    try app.input_runtime.textReplacementState().replace(alloc, "/model ");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings("openai/gpt-4o", app.selected_model.items);
    try std.testing.expect(app.last_preference_effort == null);
    try std.testing.expect(app.last_preference_fast_mode == null);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime model picker skips effort stage for reasoning model without tiers" {
    const alloc = std.testing.allocator;
    const model = "deepseek/deepseek-v4-pro-0813";
    const completions = [_][]const u8{model};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.model_completion_values = &completions;
    app.gateway_metadata_model = model;
    app.gateway_metadata = .{ .supports_reasoning = true };
    try app.input_runtime.textReplacementState().replace(alloc, "/model ");

    const capabilities = app.resolvedModelCapabilities(model);
    try std.testing.expect(capabilities.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 0), capabilities.reasoning_efforts.len);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings(model, app.selected_model.items);
    try std.testing.expectEqual(ModelPickerStage.model, app.input_runtime.picker.model_picker_stage);
    try std.testing.expect(!app.input_runtime.picker.hasPendingModelPickerSelection());
    try std.testing.expect(app.last_preference_effort == null);
    try std.testing.expect(app.last_preference_fast_mode == null);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime model picker exposes opaque Gateway reasoning effort" {
    const alloc = std.testing.allocator;
    const completions = [_][]const u8{"provider/new-reasoning-model"};

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.model_completion_values = &completions;
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
    app.setGatewayControls("provider/new-reasoning-model", &efforts, false);
    try app.input_runtime.textReplacementState().replace(alloc, "/model ");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 0), app.preference_commit_count);
    try std.testing.expectEqual(ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings(
        "provider/new-reasoning-model",
        app.input_runtime.picker.model_picker_pending_model.items,
    );

    Runtime(RoutingFakeApp).navigateModelPicker(&app, 1);
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preference_commit_count);
    try std.testing.expectEqualStrings("provider/new-reasoning-model", app.selected_model.items);
    try std.testing.expectEqual(types.ReasoningEffort.literal("future-tier"), app.effort);
    try std.testing.expect(!app.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("future-tier"), app.last_preference_effort.?);
    try std.testing.expect(app.last_preference_fast_mode == null);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime fatal admission rejects byte before input mutation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "kept");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try app.transcript.appendSlice(alloc, "kept transcript");
    app.worker.queued_count = 2;
    app.shell.render_requests.request(.footer);
    app.shell.transcript_band_dirty = true;
    app.metrics = .{
        .ansi_bytes = 11,
        .full_redraws = 12,
        .debounced_resizes = 13,
        .footer_line_updates = 14,
        .stream_chunks = 15,
    };
    app.worker.admission_snapshot = .{ .finalization_failed = .{
        .turn_id = 44,
        .outcome = .failed,
    } };
    const metrics_before = app.metrics;

    try std.testing.expectError(
        error.TurnFinalizationDeliveryFailed,
        Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100),
    );

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqualStrings("kept", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.worker.queuedPromptCount());
    try std.testing.expectEqualStrings("kept transcript", app.transcript.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.transcript_band_dirty);
    try std.testing.expectEqualDeep(metrics_before, app.metrics);
}

test "app_input_runtime question escape arrows preserve modal contracts" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
        .{ .label = "Gamma", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "First?", .options = &opts },
        .{ .question = "Second?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    app.question_prompt.entries.items[0].choice_index = 1;
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .history_up, null);
    try std.testing.expectEqual(@as(u8, 0), currentQuestionChoiceForRoutingTest(&app.question_prompt));
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    app.question_prompt.entries.items[0].choice_index = 1;
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .history_down, null);
    try std.testing.expectEqual(@as(u8, 2), currentQuestionChoiceForRoutingTest(&app.question_prompt));
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    app.question_prompt.current_index = 1;
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .cursor_left, null);
    try std.testing.expectEqual(@as(u8, 0), app.question_prompt.current_index);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .cursor_right, null);
    try std.testing.expectEqual(@as(u8, 0), app.question_prompt.current_index);
    try std.testing.expect(!app.shell.render_requests.hasReason(.modal));

    app.question_prompt.entries.items[0].choice_index = 3;
    try app.question_prompt.entries.items[0].freeform_buffer.appendSlice(alloc, "hi");
    app.question_prompt.entries.items[0].freeform_cursor = 2;

    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(
        &app,
        .cursor_left,
        .{ .edit_freeform = .cursor_left },
    );
    try std.testing.expectEqual(@as(usize, 1), app.question_prompt.entries.items[0].freeform_cursor);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    app.shell.render_requests.clearReason(.modal);
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(
        &app,
        .cursor_right,
        .{ .edit_freeform = .cursor_right },
    );
    try std.testing.expectEqual(@as(usize, 2), app.question_prompt.entries.items[0].freeform_cursor);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime routes question freeform home end delete and word movement" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.question_prompt.moveChoice(-1);
    try feedRoutingBytes(&app, "alpha beta");

    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(
        &app,
        .home,
        .{ .edit_freeform = .cursor_home },
    );
    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.entries.items[0].freeform_cursor);
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(
        &app,
        .word_right,
        .{ .edit_freeform = .cursor_word_right },
    );
    try std.testing.expectEqual(@as(usize, "alpha".len), app.question_prompt.entries.items[0].freeform_cursor);
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(
        &app,
        .delete_next,
        .{ .edit_freeform = .delete_next },
    );
    try std.testing.expectEqualStrings("alphabeta", app.question_prompt.entries.items[0].freeform_buffer.items);
    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(
        &app,
        .end,
        .{ .edit_freeform = .cursor_end },
    );
    try std.testing.expectEqual(
        app.question_prompt.entries.items[0].freeform_buffer.items.len,
        app.question_prompt.entries.items[0].freeform_cursor,
    );
}

test "app_input_runtime routes focused editor aliases into question freeform only" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "hidden composer");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    try Runtime(RoutingFakeApp).handleByte(&app, '2', 4096, 100);
    try feedRoutingBytes(&app, "alpha beta gamma");

    try Runtime(RoutingFakeApp).handleByte(&app, 1, 4096, 100);
    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.entries.items[0].freeform_cursor);
    try Runtime(RoutingFakeApp).handleByte(&app, 5, 4096, 100);
    try std.testing.expectEqual(
        app.question_prompt.entries.items[0].freeform_buffer.items.len,
        app.question_prompt.entries.items[0].freeform_cursor,
    );
    try Runtime(RoutingFakeApp).handleByte(&app, 2, 4096, 100);
    try std.testing.expectEqual(
        app.question_prompt.entries.items[0].freeform_buffer.items.len - 1,
        app.question_prompt.entries.items[0].freeform_cursor,
    );
    try Runtime(RoutingFakeApp).handleByte(&app, 6, 4096, 100);
    try std.testing.expectEqual(
        app.question_prompt.entries.items[0].freeform_buffer.items.len,
        app.question_prompt.entries.items[0].freeform_cursor,
    );

    try Runtime(RoutingFakeApp).handleByte(&app, 23, 4096, 100);
    try std.testing.expectEqualStrings("alpha beta ", app.question_prompt.entries.items[0].freeform_buffer.items);
    try Runtime(RoutingFakeApp).handleByte(&app, 21, 4096, 100);
    try std.testing.expectEqualStrings("", app.question_prompt.entries.items[0].freeform_buffer.items);

    try feedRoutingBytes(&app, "alpha beta");
    try Runtime(RoutingFakeApp).handleByte(&app, 1, 4096, 100);
    try feedRoutingBytes(&app, "\x1bd");
    try std.testing.expectEqualStrings("beta", app.question_prompt.entries.items[0].freeform_buffer.items);
    try Runtime(RoutingFakeApp).handleByte(&app, 5, 4096, 100);
    try feedRoutingBytes(&app, "\x1b\x7f");
    try std.testing.expectEqualStrings("", app.question_prompt.entries.items[0].freeform_buffer.items);

    try feedRoutingBytes(&app, "left right");
    try Runtime(RoutingFakeApp).handleByte(&app, 1, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 6, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 11, 4096, 100);
    try std.testing.expectEqualStrings("l", app.question_prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqualStrings("hidden composer", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime plain question arrows stay within multiline freeform answers" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.question_prompt.moveChoice(-1);
    try std.testing.expectEqual(
        question_prompt.FreeformInsertResult.inserted,
        try app.question_prompt.insertFreeformSlice(alloc, "first\nxy\nthird", 4096),
    );

    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .cursor_up, null);
    try std.testing.expect(app.question_prompt.isFreeformSelected());
    try std.testing.expectEqual(@as(usize, 8), app.question_prompt.entries.items[0].freeform_cursor);

    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .cursor_up, null);
    try std.testing.expectEqual(@as(usize, 5), app.question_prompt.entries.items[0].freeform_cursor);

    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .cursor_down, null);
    try std.testing.expectEqual(@as(usize, 8), app.question_prompt.entries.items[0].freeform_cursor);

    try Runtime(RoutingFakeApp).routeQuestionEscapeAction(&app, .history_up, null);
    try std.testing.expect(!app.question_prompt.isFreeformSelected());
    try std.testing.expectEqual(@as(?usize, null), app.question_prompt.entries.items[0].freeform_preferred_column);
}

test "app_input_runtime question modal ignores non-modal text" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    try feedRoutingBytes(&app, "compose sentinel text");

    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.question_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 0), app.worker.submitted_question_count);
}

test "app_input_runtime approval modal ignores non-modal text" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    try feedRoutingBytes(&app, "queue approval sentinel text");

    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.worker.submitted_permission == null);
}

test "app_input_runtime modal controls win before ordinary modal input" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        const opts = [_]types.QuestionOption{
            .{ .label = "Alpha", .description = null },
            .{ .label = "Beta", .description = null },
        };
        const entries = [_]types.QuestionBatchEntry{
            .{ .question = "Continue?", .options = &opts },
        };
        try app.question_prompt.syncFrom(alloc, &entries);

        try Runtime(RoutingFakeApp).handleByte(&app, '2', 4096, 100);

        try std.testing.expectEqual(@as(usize, 1), app.worker.submitted_question_count);
        try std.testing.expectEqualStrings(
            "Beta",
            app.worker.submitted_question_answer[0..app.worker.submitted_question_answer_len],
        );
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
            .label = "terminal.exec npm test",
            .amendment_allowed = true,
        }));

        try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
        try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);

        try std.testing.expect(app.approval_prompt.isAmending());
        try std.testing.expectEqualStrings("x", app.approval_prompt.decision.selectedDraft());
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
        try std.testing.expect(app.worker.submitted_permission == null);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try Runtime(RoutingFakeApp).handleByte(&app, '3', 4096, 100);

        try std.testing.expectEqual(ToolPermissionDecision.deny, app.worker.submitted_permission.?);
        try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    }
}

test "app_input_runtime raw CSI-u digits stay isolated from approval selection" {
    const alloc = std.testing.allocator;
    const sequences = [_][]const u8{
        "\x1b[49;5u",
        "\x1b[\x1b[49;5u",
    };

    for (sequences) |sequence| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
        app.approval_prompt.decision.choice_index = 2;

        try feedRoutingBytes(&app, sequence);
        try std.testing.expectEqual(@as(u8, 2), app.approval_prompt.decision.choice_index);
        try std.testing.expect(app.worker.submitted_permission == null);

        try feedRoutingBytes(&app, "\t");
        try std.testing.expectEqual(@as(u8, 2), app.approval_prompt.decision.choice_index);
        try std.testing.expect(app.approval_prompt.isAmending());
        try std.testing.expect(app.worker.submitted_permission == null);
    }
}

test "app_input_runtime raw CSI-u digits stay isolated from question selection" {
    const alloc = std.testing.allocator;
    const sequences = [_][]const u8{
        "\x1b[49;5u",
        "\x1b[\x1b[49;5u",
    };
    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
        .{ .label = "Gamma", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };

    for (sequences) |sequence| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.question_prompt.syncFrom(alloc, &entries);
        app.question_prompt.entries.items[0].choice_index = 1;

        try feedRoutingBytes(&app, sequence);
        try std.testing.expectEqual(@as(u8, 1), currentQuestionChoiceForRoutingTest(&app.question_prompt));
        try std.testing.expectEqual(@as(usize, 0), app.worker.submitted_question_answer_len);

        try feedRoutingBytes(&app, "\t");
        try std.testing.expectEqual(@as(u8, 1), currentQuestionChoiceForRoutingTest(&app.question_prompt));
        try std.testing.expectEqual(@as(usize, 0), app.worker.submitted_question_answer_len);
    }
}

test "app_input_runtime raw CSI-u digits stay isolated from question freeform text" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.question_prompt.entries.items[0].choice_index = 2;

    try feedRoutingBytes(&app, "\x1b[49;5u");
    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.entries.items[0].freeform_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.worker.submitted_question_answer_len);

    try feedRoutingBytes(&app, "x\r");
    try std.testing.expectEqualStrings("x", app.worker.submitted_question_answer[0..app.worker.submitted_question_answer_len]);
}

test "app_input_runtime decoded kitty Escape follows the raw Escape policy" {
    const alloc = std.testing.allocator;
    const question_sequences = [_][]const u8{ "\x1b[27u", "\x1b[27;1u" };
    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };

    for (question_sequences) |sequence| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try app.question_prompt.syncFrom(alloc, &entries);

        try feedRoutingBytes(&app, sequence);

        try std.testing.expect(app.worker.question_cancelled);
        try std.testing.expect(!app.question_prompt.isActive());
        try std.testing.expect(!app.stream.active);
        try std.testing.expect(app.worker.cancel_requested);
        try std.testing.expect(app.worker.cancel_requested_when_question_cancelled);
        try std.testing.expectEqual(transcript_runtime.RawEntryClass.question_resolution, app.last_replaceable_class);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try app.question_prompt.syncFrom(alloc, &entries);
        app.terminal_input_runtime.terminal_action_decoder.stage = 1;
        app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
        app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;

        try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

        try std.testing.expect(app.worker.question_cancelled);
        try std.testing.expect(!app.question_prompt.isActive());
        try std.testing.expect(!app.stream.active);
        try std.testing.expect(app.worker.cancel_requested);
        try std.testing.expect(app.worker.cancel_requested_when_question_cancelled);
        try std.testing.expectEqual(transcript_runtime.RawEntryClass.question_resolution, app.last_replaceable_class);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try feedRoutingBytes(&app, "\x1b[27u");

        try std.testing.expect(app.worker.cancel_requested);
        try std.testing.expect(!app.approval_prompt.isActive());
        try std.testing.expect(!app.stream.active);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;

        try feedRoutingBytes(&app, "\x1b[27u");

        try std.testing.expect(app.worker.cancel_requested);
        try std.testing.expect(!app.stream.active);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");

        try feedRoutingBytes(&app, "\x1b[27u");
        try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
        try std.testing.expect(app.input_runtime.gestures.escapeClearArmed());

        try feedRoutingBytes(&app, "\x1b[27u");
        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
        try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    }
}

test "app_input_runtime Ghostty Escape press closes the usage dashboard" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.usage_menu.openError(
        alloc,
        .days_30,
        "usage is unavailable",
    );

    try feedRoutingBytes(&app, "\x1b[27;1:1u");

    try std.testing.expect(!app.input_runtime.usage_menu.active);
}

test "app_input_runtime Ghostty Escape release leaves the usage dashboard open" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.usage_menu.openError(
        alloc,
        .days_30,
        "usage is unavailable",
    );

    try feedRoutingBytes(&app, "\x1b[27;1:3u");

    try std.testing.expect(app.input_runtime.usage_menu.active);
}

test "app_input_runtime decoded kitty Backspace edits the draft without cancelling" {
    const alloc = std.testing.allocator;
    const sequences = [_][]const u8{ "\x1b[127u", "\x1b[127;1u" };

    for (sequences) |sequence| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try feedRoutingBytes(&app, "draft");

        try feedRoutingBytes(&app, sequence);

        try std.testing.expectEqualStrings("draf", app.input_runtime.edit_state.input.items);
        try std.testing.expect(!app.worker.cancel_requested);
        try std.testing.expect(app.stream.active);
        try std.testing.expect(!app.terminal_input_runtime.terminal_action_decoder.cancel_pending);
    }
}

test "app_input_runtime idle terminal ingress stays fast with a maximum composer draft" {
    const alloc = std.testing.allocator;
    const input_limits: paste_framing.InputLimits = .{};
    const idle_poll_count: usize = 4096;
    const max_elapsed_ms: i64 = 1000;

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendNTimes(
        alloc,
        'x',
        input_limits.composer_bytes,
    );
    try std.testing.expect(app.input_runtime.edit_state.moveEnd());

    try std.testing.expect(
        app.input_runtime.picker.activeFilePickerQuery(
            &app.input_runtime.edit_state,
        ) == null,
    );

    var ingress = input_action.TerminalInputIngress{};
    std.mem.doNotOptimizeAway(&ingress);
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    for (0..idle_poll_count) |_| {
        const replay = try Runtime(RoutingFakeApp).handleTerminalInputIngressWithLimits(
            &app,
            ingress,
            input_limits,
            100,
        );
        try std.testing.expect(replay == null);
    }
    const elapsed_ms = started.durationTo(
        std.Io.Clock.Timestamp.now(std.testing.io, .awake),
    ).raw.toMilliseconds();

    try std.testing.expect(elapsed_ms < max_elapsed_ms);
}

test "app_input_runtime remapped ctrl+c reaches prompt cancellation" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try feedRoutingBytes(&app, "\x1b[99;5u");

        try std.testing.expectEqual(ToolPermissionDecision.deny, app.worker.submitted_permission.?);
        try std.testing.expect(!app.approval_prompt.isActive());
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        const opts = [_]types.QuestionOption{
            .{ .label = "Alpha", .description = null },
        };
        const entries = [_]types.QuestionBatchEntry{
            .{ .question = "Continue?", .options = &opts },
        };
        try app.question_prompt.syncFrom(alloc, &entries);

        try feedRoutingBytes(&app, "\x1b[99;5u");

        try std.testing.expect(app.worker.question_cancelled);
        try std.testing.expect(!app.question_prompt.isActive());
        try std.testing.expect(!app.stream.active);
        try std.testing.expect(app.worker.cancel_requested);
        try std.testing.expect(app.worker.cancel_requested_when_question_cancelled);
        try std.testing.expectEqual(transcript_runtime.RawEntryClass.question_resolution, app.last_replaceable_class);
    }
}

test "app_input_runtime ctrl+g invokes upgrade shortcut without composer mutation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try Runtime(RoutingFakeApp).handleByte(&app, ctrl_g_upgrade_byte, 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.upgrade_apply_count);
    try std.testing.expectEqual(@as(usize, 0), app.upgrade_denied_count);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime immediate ctrl+g follows bare Escape" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x1b\x07");

    try std.testing.expectEqual(@as(usize, 1), app.upgrade_apply_count);
    try std.testing.expectEqual(@as(usize, 0), app.upgrade_denied_count);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
}

test "app_input_runtime ctrl+r no longer invokes the ready upgrade shortcut" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try Runtime(RoutingFakeApp).handleByte(&app, 18, 4096, 100);

    try std.testing.expectEqual(@as(usize, 0), app.upgrade_apply_count);
    try std.testing.expectEqual(@as(usize, 0), app.upgrade_denied_count);
}

test "app_input_runtime ctrl+z suspends to job control without composer mutation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(RoutingFakeApp).handleByte(&app, 26, 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.suspend_count);
    try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime ctrl+z is inert mid-escape sequence" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 26, 4096, 100);

    try std.testing.expectEqual(@as(usize, 0), app.suspend_count);
}

test "app_input_runtime immediate Ctrl-A follows bare Escape" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abc");

    try feedRoutingBytes(&app, "\x1b\x01X");

    try std.testing.expectEqualStrings("Xabc", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
}

test "app_input_runtime immediate Ctrl-U follows slash completion Escape" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/");

    try feedRoutingBytes(&app, "\x1b\x15after");

    try std.testing.expectEqualStrings("after", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 5), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
}

test "app_input_runtime immediate Ctrl-X follows bare Escape" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x1b\x18");

    try std.testing.expectEqual(@as(usize, 1), app.subagents.toggle_view_calls);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
}

test "app_input_runtime ctrl+d exits on an empty idle composer" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try std.testing.expect(!app.should_exit);

    try Runtime(RoutingFakeApp).handleByte(&app, 4, 4096, 100);

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(
        app_session_runtime.ResumeHandoffIntent.requested,
        app.session_persistence.resume_handoff_intent,
    );
}

test "app_input_runtime ctrl+d deletes forward when the composer holds a draft" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
    app.input_runtime.edit_state.cursor = 0;

    try Runtime(RoutingFakeApp).handleByte(&app, 4, 4096, 100);

    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqualStrings("raft", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime ctrl+d does not exit while a response is streaming" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, 4, 4096, 100);

    try std.testing.expect(!app.should_exit);
}

test "app_input_runtime ctrl+g is denied while stream or modal owns state" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;

        try Runtime(RoutingFakeApp).handleByte(&app, ctrl_g_upgrade_byte, 4096, 100);

        try std.testing.expectEqual(@as(usize, 0), app.upgrade_apply_count);
        try std.testing.expectEqual(@as(usize, 1), app.upgrade_denied_count);
        try std.testing.expect(std.mem.find(u8, app.transcript.items, "response finishes") != null);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        const opts = [_]types.QuestionOption{
            .{ .label = "Alpha", .description = null },
        };
        const entries = [_]types.QuestionBatchEntry{
            .{ .question = "Continue?", .options = &opts },
        };
        try app.question_prompt.syncFrom(alloc, &entries);

        try Runtime(RoutingFakeApp).handleByte(&app, ctrl_g_upgrade_byte, 4096, 100);

        try std.testing.expectEqual(@as(usize, 0), app.upgrade_apply_count);
        try std.testing.expectEqual(@as(usize, 1), app.upgrade_denied_count);
        try std.testing.expect(app.question_prompt.isActive());
    }
}

test "app_input_runtime ctrl+c drops an active approval amendment" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .label = "terminal.exec npm test",
    }));

    try feedRoutingBytes(&app, "\tsummarize the result");
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expectEqualStrings(
        "summarize the result",
        app.approval_prompt.decision.selectedDraft(),
    );

    try feedRoutingBytes(&app, "\x1b[99;5u");

    try std.testing.expectEqual(ToolPermissionDecision.deny, app.worker.submitted_permission.?);
    try std.testing.expectEqual(@as(usize, 0), app.worker.submitted_permission_feedback_len);
}

test "app_input_runtime ctrl+c clears an image-only draft" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.pending_images.append(alloc, .{
        .id = 1,
        .path = try alloc.dupe(u8, "/tmp/image.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    try app.input_runtime.textReplacementState().replace(alloc, "[Image #1]");

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);

    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime double escape clears an image-only draft" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.pending_images.append(alloc, .{
        .id = 1,
        .path = try alloc.dupe(u8, "/tmp/image.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    try app.input_runtime.textReplacementState().replace(alloc, "[Image #1]");

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);
    try std.testing.expectEqual(
        @as(?i64, 1),
        app.input_runtime.gestures.escapeClearArmedAt(),
    );
    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 2);

    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
}

test "app_input_runtime owns pending image discard and release" {
    const alloc = std.testing.allocator;
    const PendingImageLifecycleApp = struct {
        alloc: std.mem.Allocator,
        input_runtime: core_input_runtime.Runtime = .{},
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var source = try tmp.dir.createFile(std.testing.io, "pending.png", .{});
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\npending");
    }
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "pending.png");
    defer alloc.free(source_path);
    const snapshot_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(snapshot_root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ snapshot_root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = PendingImageLifecycleApp{ .alloc = alloc };
    defer app.pending_images.deinit(alloc);
    app.input_runtime.vertical_navigation.preferred_column = 6;
    try app.pending_images.append(alloc, .{
        .id = 1,
        .path = try alloc.dupe(u8, source_path),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    try image_attachments.captureImageSnapshot(
        alloc,
        &app.pending_images.items[0],
        snapshot_dir,
    );
    const discarded_path = try alloc.dupe(
        u8,
        app.pending_images.items[0].snapshot_path.?,
    );
    defer alloc.free(discarded_path);

    Runtime(PendingImageLifecycleApp).clearPendingImages(&app);

    try std.testing.expect(app.input_runtime.vertical_navigation.preferredColumn() == null);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(std.testing.io, discarded_path, .{}),
    );

    try app.pending_images.append(alloc, .{
        .id = 2,
        .path = try alloc.dupe(u8, source_path),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    try image_attachments.captureImageSnapshot(
        alloc,
        &app.pending_images.items[0],
        snapshot_dir,
    );
    const released_path = try alloc.dupe(
        u8,
        app.pending_images.items[0].snapshot_path.?,
    );
    defer alloc.free(released_path);

    Runtime(PendingImageLifecycleApp).releasePendingImages(&app);

    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    var released = try std.Io.Dir.openFileAbsolute(std.testing.io, released_path, .{});
    released.close(std.testing.io);
}

fn currentQuestionChoiceForRoutingTest(prompt: *const question_prompt.QuestionPrompt) u8 {
    return prompt.entries.items[prompt.current_index].choice_index;
}

fn feedRoutingBytes(app: *RoutingFakeApp, bytes: []const u8) !void {
    return feedRoutingBytesWithLimit(app, bytes, RoutingFakeApp.input_byte_limit);
}

fn feedRoutingBytesWithLimit(app: *RoutingFakeApp, bytes: []const u8, max_input_len: usize) !void {
    for (bytes) |byte| {
        try Runtime(RoutingFakeApp).handleByte(app, byte, max_input_len, 100);
    }
    try Runtime(RoutingFakeApp).settleTerminalPasteDeliveryEpochWithLimits(
        app,
        paste_framing.InputLimits.single(max_input_len),
    );
}

fn primeComposerHistoryForTest(comptime App: type, app: *App, draft: []const u8) !void {
    try app.input_runtime.composer_history.installTextEntries(
        app.alloc,
        &.{"history entry"},
    );
    try app.input_runtime.textReplacementState().replace(app.alloc, draft);
    try input_completion_runtime.CompletionRuntime(App).navigatePromptHistory(app, -1);
}

test "prompt history movement starts a new text undo episode" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try app.input_runtime.composer_history.installTextEntries(
        alloc,
        &.{"history entry"},
    );
    try app.input_runtime.insertionState().insertSlice(alloc, "draft", .preserve);
    try input_completion_runtime.CompletionRuntime(RoutingFakeApp).navigatePromptHistory(&app, -1);

    try std.testing.expectEqualStrings("history entry", app.input_runtime.edit_state.input.items);
    try std.testing.expect(!(try app.input_runtime.undoState().undo(alloc)));
}

fn openRoutingModelMenu(app: *RoutingFakeApp, model_ids: []const []const u8) !void {
    const menu = &app.model_cache.menu;
    menu.active = true;
    menu.load_state = .ready;
    for (model_ids) |model_id| {
        const owned_id = try app.alloc.dupe(u8, model_id);
        var item_owns_id = false;
        errdefer if (!item_owns_id) app.alloc.free(owned_id);
        const provider_end = std.mem.indexOfScalar(u8, owned_id, '/') orelse owned_id.len;
        const provider = owned_id[0..provider_end];
        try menu.items.append(app.alloc, .{
            .id = owned_id,
            .provider = provider,
            .capabilities = app.resolvedModelCapabilities(owned_id),
        });
        item_owns_id = true;
    }
}

fn openRoutingAuthPicker(app: *RoutingFakeApp) !void {
    app.auth.source_inventory.insert(.vercel_oidc_token);
    app.auth.source_inventory.insert(.ai_gateway_api_key);
    app.auth.openPicker(app.alloc);
    try std.testing.expect(app.auth.movePicker(1));
    try std.testing.expectEqual(@as(usize, 8), app.auth.pickerView().choiceCount());
    try std.testing.expectEqual(@as(usize, 1), app.auth.pickerView().selectedIndex());
}

const RoutingDecisionKind = enum { question, approval };

fn activateRoutingDecision(app: *RoutingFakeApp, kind: RoutingDecisionKind) !void {
    switch (kind) {
        .question => {
            const options = [_]types.QuestionOption{
                .{ .label = "Alpha", .description = null },
                .{ .label = "Beta", .description = null },
            };
            const entries = [_]types.QuestionBatchEntry{
                .{ .question = "Continue?", .options = &options },
            };
            try app.question_prompt.syncFrom(app.alloc, &entries);
        },
        .approval => try std.testing.expect(try app.approval_prompt.syncRequest(app.alloc, .{
            .label = "terminal.exec npm test",
        })),
    }
}

test "app_input_runtime ctrl+w kills whitespace-delimited text and redraws only when changed" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try primeComposerHistoryForTest(RoutingFakeApp, &app, "draft");
        try app.input_runtime.textReplacementState().replace(alloc, "foo-bar");
        app.input_runtime.vertical_navigation.preferred_column = 7;
        app.shell.render_requests.clearReason(.footer);

        try feedRoutingBytes(&app, "\x17");
        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqualStrings("foo-bar", app.input_runtime.kill_ring.text.items);
        try std.testing.expectEqual(@as(?usize, 0), app.input_runtime.composer_history.activeIndex());
        try std.testing.expectEqualStrings("draft", app.input_runtime.composer_history.draftText().?);
        try std.testing.expectEqual(@as(?usize, null), app.input_runtime.vertical_navigation.preferredColumn());
        try std.testing.expect(app.shell.render_requests.hasReason(.footer));

        app.shell.render_requests.clearReason(.footer);
        try feedRoutingBytes(&app, "\x19");
        try std.testing.expectEqualStrings("foo-bar", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(?usize, 0), app.input_runtime.composer_history.activeIndex());
        try std.testing.expectEqualStrings("draft", app.input_runtime.composer_history.draftText().?);
        try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendSlice(alloc, "unchanged");
        try app.input_runtime.kill_ring.text.appendSlice(alloc, "existing kill");
        app.input_runtime.vertical_navigation.preferred_column = 7;
        app.shell.render_requests.clearReason(.footer);

        try feedRoutingBytes(&app, "\x17");
        try std.testing.expectEqualStrings("unchanged", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqualStrings("existing kill", app.input_runtime.kill_ring.text.items);
        try std.testing.expectEqual(@as(?usize, null), app.input_runtime.vertical_navigation.preferredColumn());
        try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
    }
}

test "app_input_runtime composer control aliases move, delete, and preserve process state" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abcd");

    try feedRoutingBytes(&app, "\x02");
    try std.testing.expectEqual(@as(usize, 3), app.input_runtime.edit_state.cursor);

    try feedRoutingBytes(&app, "\x02");
    try feedRoutingBytes(&app, "\x06");
    try Runtime(RoutingFakeApp).handleByte(&app, 'X', 4096, 100);
    try std.testing.expectEqualStrings("abcXd", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 4), app.input_runtime.edit_state.cursor);

    try feedRoutingBytes(&app, "\x04");
    try std.testing.expectEqualStrings("abcX", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 4), app.input_runtime.edit_state.cursor);
    try std.testing.expect(!app.should_exit);

    app.input_runtime.inputResetState().clearCurrent(alloc);
    app.shell.render_requests.clearReason(.footer);
    try feedRoutingBytes(&app, "\x04");
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime ctrl+p and ctrl+n navigate prompt history directly" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.composer_history.installTextEntries(alloc, &.{ "older", "newer" });
    try app.input_runtime.textReplacementState().replace(alloc, "draft");
    armCtrlCExitForTest(&app.input_runtime, 123);

    try feedRoutingBytes(&app, "\x10");
    try std.testing.expectEqualStrings("newer", app.input_runtime.edit_state.input.items);
    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());

    try feedRoutingBytes(&app, "\x10");
    try std.testing.expectEqualStrings("older", app.input_runtime.edit_state.input.items);

    try feedRoutingBytes(&app, "\x0e");
    try std.testing.expectEqualStrings("newer", app.input_runtime.edit_state.input.items);

    try feedRoutingBytes(&app, "\x0e");
    try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime decoded history recall disarms pending Ctrl-C exit" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.composer_history.installTextEntries(alloc, &.{"history sentinel"});

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    armEscapeClearForTest(&app.input_runtime, io_mod.milliTimestamp());
    app.shell.render_requests.clearReason(.footer);

    try feedRoutingBytes(&app, "\x1b[A");

    try std.testing.expectEqualStrings("history sentinel", app.input_runtime.edit_state.input.items);
    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!app.should_exit);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.should_exit);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime bare Escape disarms pending Ctrl-C exit" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    app.terminal_input_runtime.terminal_action_decoder.started_ms = io_mod.milliTimestamp() - 31;
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 30);

    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.should_exit);
}

test "app_input_runtime ctrl+j and ctrl+k navigate visible composer pickers" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        bytes: []const u8,
        expected_index: usize,
    }{
        .{ .bytes = "\x0a", .expected_index = 2 },
        .{ .bytes = "\x0b", .expected_index = 0 },
        .{ .bytes = "\x1b[106;5u", .expected_index = 2 },
        .{ .bytes = "\x1b[107;5u", .expected_index = 0 },
    };

    for (cases) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try openRoutingAuthPicker(&app);
        try app.input_runtime.textReplacementState().replace(alloc, "/");
        app.shell.render_requests.clearReason(.footer);

        try feedRoutingBytes(&app, case.bytes);

        try std.testing.expect(app.auth.pickerView().active);
        try std.testing.expectEqual(case.expected_index, app.auth.pickerView().selectedIndex());
        try std.testing.expectEqualStrings("/", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), app.input_runtime.edit_state.cursor);
        try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    }
}

test "app_input_runtime ctrl+j and ctrl+k preserve editor fallback behind full transcript" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        bytes: []const u8,
        expected_input: []const u8,
    }{
        .{ .bytes = "\x0a", .expected_input = "a\nb" },
        .{ .bytes = "\x0b", .expected_input = "a" },
        .{ .bytes = "\x1b[106;5u", .expected_input = "a\nb" },
        .{ .bytes = "\x1b[107;5u", .expected_input = "a" },
    };

    for (cases) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        activateFullTranscriptForRoutingTest(&app);
        try openRoutingAuthPicker(&app);
        try app.input_runtime.textReplacementState().replace(alloc, "ab");
        app.input_runtime.edit_state.cursor = 1;

        try feedRoutingBytes(&app, case.bytes);

        try std.testing.expectEqualStrings(case.expected_input, app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), app.auth.pickerView().selectedIndex());
        try std.testing.expect(!app.auth.pickerView().active);
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
    }
}

test "app_input_runtime modal-only controls do not reach the composer" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        kind: RoutingDecisionKind,
        bytes: []const u8,
    }{
        .{ .kind = .question, .bytes = "\x0b" },
        .{ .kind = .question, .bytes = "\x1b[107;5u" },
        .{ .kind = .approval, .bytes = "\x0b" },
        .{ .kind = .approval, .bytes = "\x1b[107;5u" },
    };

    for ([_]bool{ false, true }) |stacked_subagent| {
        for (cases) |case| {
            var app = try RoutingFakeApp.init(alloc);
            defer app.deinit();
            try activateRoutingDecision(&app, case.kind);
            app.subagents.active = stacked_subagent;
            try openRoutingAuthPicker(&app);
            try app.input_runtime.textReplacementState().replace(alloc, "ab");
            app.input_runtime.edit_state.cursor = 1;

            try feedRoutingBytes(&app, case.bytes);

            try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);
            try std.testing.expectEqual(@as(usize, 1), app.auth.pickerView().selectedIndex());
            try std.testing.expect(app.auth.pickerView().active);
            try std.testing.expect(app.question_prompt.isActive() or app.approval_prompt.isActive());
            try std.testing.expectEqual(@as(usize, 0), app.worker.submitted_question_count);
            try std.testing.expect(app.worker.submitted_permission == null);
            try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);

            try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
        }
    }
}

const RoutingDraftKind = enum {
    text,
    paste,
    image,
};

fn seedRoutingDraftForGuard(app: *RoutingFakeApp, kind: RoutingDraftKind) !void {
    switch (kind) {
        .text => try app.input_runtime.textReplacementState().replace(app.alloc, "guarded draft"),
        .paste => try app.input_runtime.entities.pasted_blocks.append(app.alloc, .{
            .id = 1,
            .text = try app.alloc.dupe(u8, "guarded pasted text"),
            .line_count = 1,
        }),
        .image => try app.pending_images.append(app.alloc, .{
            .id = 1,
            .path = try app.alloc.dupe(u8, "/tmp/guarded-image.png"),
            .media_type = try app.alloc.dupe(u8, "image/png"),
        }),
    }
}

fn expectRoutingDraftForGuard(app: *const RoutingFakeApp, kind: RoutingDraftKind) !void {
    switch (kind) {
        .text => try std.testing.expectEqualStrings("guarded draft", app.input_runtime.edit_state.input.items),
        .paste => {
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
            try std.testing.expectEqualStrings("guarded pasted text", app.input_runtime.entities.pasted_blocks.items[0].text);
        },
        .image => {
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
            try std.testing.expectEqualStrings("/tmp/guarded-image.png", app.pending_images.items[0].path);
        },
    }
}

test "app_input_runtime ctrl+l preserves text paste and image drafts" {
    const alloc = std.testing.allocator;
    const control_sequences = [_][]const u8{
        "\x0c",
        "\x1b[108;5u",
    };
    const draft_kinds = [_]RoutingDraftKind{ .text, .paste, .image };

    for (control_sequences) |bytes| {
        for (draft_kinds) |kind| {
            var app = try RoutingFakeApp.init(alloc);
            defer app.deinit();
            defer app.clearPendingImages();
            try seedRoutingDraftForGuard(&app, kind);

            try feedRoutingBytes(&app, bytes);

            try std.testing.expect(app.last_command == null);
            try expectRoutingDraftForGuard(&app, kind);
        }
    }
}

test "app_input_runtime ctrl+l does not invoke the clear command" {
    const alloc = std.testing.allocator;
    const control_sequences = [_][]const u8{
        "\x0c",
        "\x1b[108;5u",
    };

    for (control_sequences) |bytes| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();

        try feedRoutingBytes(&app, bytes);

        try std.testing.expect(app.last_command == null);
    }
}

test "app_input_runtime cmd+r refuses to open sessions over text paste and image drafts" {
    const alloc = std.testing.allocator;
    const draft_kinds = [_]RoutingDraftKind{ .text, .paste, .image };

    for (draft_kinds) |kind| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        defer app.clearPendingImages();
        try seedRoutingDraftForGuard(&app, kind);

        try feedRoutingBytes(&app, "\x1b[114;9u");

        try std.testing.expect(!app.session_persistence.session_picker.active);
        try expectRoutingDraftForGuard(&app, kind);
        try std.testing.expectEqualStrings("session", app.notice_topic.items);
        try std.testing.expectEqual(types.NoticeTone.neutral, app.notice_tone);
        try std.testing.expectEqualStrings(
            "submit or clear the draft before switching sessions",
            app.notice_body.items,
        );
    }
}

test "app_input_runtime cmd+r keeps empty composer picker behavior" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x1b[114;9u");

    try std.testing.expect(app.session_persistence.session_picker.active);
}

test "app_input_runtime ctrl+l leaves the session catalog open" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "\x0c",
        "\x1b[108;5u",
    };

    for (cases) |bytes| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.textReplacementState().replace(alloc, "draft with paste");
        try app.input_runtime.entities.pasted_blocks.append(alloc, .{
            .id = 1,
            .text = try alloc.dupe(u8, "owned pasted text"),
            .line_count = 1,
        });
        app.session_persistence.session_picker.active = true;

        try feedRoutingBytes(&app, bytes);

        try std.testing.expect(app.last_command == null);
        try std.testing.expectEqualStrings("draft with paste", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
        try std.testing.expect(app.session_persistence.session_picker.active);
    }
}

test "app_input_runtime decision prompts consume raw and kitty ctrl+l" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        kind: RoutingDecisionKind,
        bytes: []const u8,
    }{
        .{ .kind = .question, .bytes = "\x0c" },
        .{ .kind = .question, .bytes = "\x1b[108;5u" },
        .{ .kind = .approval, .bytes = "\x0c" },
        .{ .kind = .approval, .bytes = "\x1b[108;5u" },
    };

    for ([_]bool{ false, true }) |stacked_subagent| {
        for (cases) |case| {
            var app = try RoutingFakeApp.init(alloc);
            defer app.deinit();
            try activateRoutingDecision(&app, case.kind);
            app.subagents.active = stacked_subagent;
            try app.input_runtime.textReplacementState().replace(alloc, "draft");

            try feedRoutingBytes(&app, case.bytes);

            try std.testing.expect(app.last_command == null);
            try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
            try std.testing.expect(app.question_prompt.isActive() or app.approval_prompt.isActive());
            try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);
        }
    }
}

test "app_input_runtime active multiline history moves vertically before advancing" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.composer_history.installTextEntries(alloc, &.{ "older", "newer top\nnewer bottom" });
    try app.input_runtime.textReplacementState().replace(alloc, "draft top\ndraft bottom");

    try input_completion_runtime.CompletionRuntime(RoutingFakeApp).navigatePromptHistory(&app, -1);
    try std.testing.expectEqualStrings("newer top\nnewer bottom", app.input_runtime.edit_state.input.items);
    _ = horizontal_navigation.move(
        .character_left,
        &app.input_runtime.edit_state,
        &app.input_runtime.entities,
        &app.input_runtime.vertical_navigation,
    );
    try feedRoutingBytes(&app, "\x1b[A");
    try std.testing.expectEqualStrings("newer top\nnewer bottom", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "newer top".len), app.input_runtime.edit_state.cursor);
    try feedRoutingBytes(&app, "\x1b[A");
    try std.testing.expectEqualStrings("newer top\nnewer bottom", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
    try feedRoutingBytes(&app, "\x1b[A");
    try std.testing.expectEqualStrings("older", app.input_runtime.edit_state.input.items);
    try feedRoutingBytes(&app, "\x1b[B");
    try std.testing.expectEqualStrings("newer top\nnewer bottom", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
    try feedRoutingBytes(&app, "\x1b[B");
    try std.testing.expectEqualStrings("draft top\ndraft bottom", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);

    try input_completion_runtime.CompletionRuntime(RoutingFakeApp).navigatePromptHistory(&app, -1);
    _ = try Runtime(RoutingFakeApp).routeResolvedEscapeAction(
        &app,
        .history_up,
        null,
        null,
        null,
        null,
        false,
        4096,
    );
    try std.testing.expectEqualStrings("older", app.input_runtime.edit_state.input.items);

    try openRoutingAuthPicker(&app);
    try feedRoutingBytes(&app, "\x1b[A");
    try std.testing.expectEqual(@as(usize, 0), app.auth.pickerView().selectedIndex());
    try std.testing.expectEqualStrings("older", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime editing recalled history keeps the original draft reachable" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.composer_history.installTextEntries(alloc, &.{"historical prompt"});
    try app.input_runtime.textReplacementState().replace(alloc, "unsent draft");

    try Runtime(RoutingFakeApp).routeComposerShortcutAction(
        &app,
        .history_previous,
        4096,
    );
    try Runtime(RoutingFakeApp).handleByte(&app, '!', 4096, 100);

    try std.testing.expectEqualStrings("historical prompt!", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, 0), app.input_runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("unsent draft", app.input_runtime.composer_history.draftText().?);

    try Runtime(RoutingFakeApp).routeComposerShortcutAction(
        &app,
        .history_next,
        4096,
    );
    try std.testing.expectEqualStrings("unsent draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, null), app.input_runtime.composer_history.activeIndex());
    try std.testing.expect(app.input_runtime.composer_history.draftView() == null);
}

test "app_input_runtime alt+d deletes the next composer word" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "alpha beta");
    app.input_runtime.edit_state.cursor = 0;

    try feedRoutingBytes(&app, "\x1bd");

    try std.testing.expectEqualStrings("beta", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
}

test "app_input_runtime backslash enter inserts newline after enter-owned handlers decline" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "one\\");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqualStrings("one\n", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
}

test "app_input_runtime backslash enter is consumed by an active command skills menu" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "review",
        .description = "",
        .path = "/tmp/review/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    app.skills.openMenu();
    try app.input_runtime.textReplacementState().replace(alloc, "\\");

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(!std.mem.eql(u8, app.input_runtime.edit_state.input.items, "\n"));
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expect(app.skills.menu.active);
}

test "app_input_runtime decision prompt owns and discards bracketed paste" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "decision-paste.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    const payload = "typing\t\r\n" ++ "\x03" ++ "\x1b[99;5u" ++ "\x1b[A" ++ "\x1b[200~";
    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, payload);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);

    try feedRoutingBytes(&app, "\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.approval_prompt.isActive());
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    const needle = try std.fmt.allocPrint(alloc, "decision prompt paste dropped bytes={d} reason=decision_prompt_active", .{payload.len});
    defer alloc.free(needle);
    try std.testing.expect(std.mem.find(u8, trace, needle) != null);
}

test "app_input_runtime rejects same-epoch paste suffix without submitting it" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "keep");

    try feedRoutingBytes(
        &app,
        "\x1b[200~\x1b[201~/version\r\x1b[201~",
    );

    try std.testing.expectEqualStrings("keep", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);

    try feedRoutingBytes(&app, "\r");
    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings("keep", app.submitted_prompt[0..app.submitted_prompt_len]);
}

test "app_input_runtime rejects a same-epoch enter after an otherwise valid paste" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "prior");

    try feedRoutingBytes(&app, "\x1b[200~new\x1b[201~\r");

    try std.testing.expectEqualStrings("prior", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.submitted_prompt_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
}

test "app_input_runtime approval amendment accepts bracketed paste" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    try feedRoutingBytes(&app, "\t");
    try std.testing.expect(app.approval_prompt.isAmending());

    const payload = "pasted amendment marker " ++
        "\\x1b[200~" ++
        "\x1b[200~" ++
        "\x1b[201;1~" ++
        "\t\r\x03";
    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.approval_amendment, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, payload);

    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqualStrings("", app.approval_prompt.decision.selectedDraft());

    try feedRoutingBytes(&app, "\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqualStrings(
        "pasted amendment marker \\x1b[200~[200~[201;1~  ",
        app.approval_prompt.decision.selectedDraft(),
    );
}

test "app_input_runtime approval amendment rejects oversized paste visibly" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .label = "terminal.exec npm test",
    }));
    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 2, 100);

    try feedRoutingBytesWithLimit(&app, "\x1b[200~abc\x1b[201~", 2);

    try std.testing.expectEqualStrings("", app.approval_prompt.decision.selectedDraft());
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime keeps composer and decision input limits independent" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const limits = paste_framing.InputLimits{
        .composer_bytes = 4,
        .decision_bytes = 2,
    };

    for ("abcd") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByteWithLimits(
            &app,
            byte,
            limits,
            100,
        );
    }
    try std.testing.expectEqualStrings("abcd", app.input_runtime.edit_state.input.items);

    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .label = "terminal.exec npm test" },
    ));
    try Runtime(RoutingFakeApp).handleTerminalByteWithLimits(&app, '\t', limits, 100);
    for ("xyz") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByteWithLimits(
            &app,
            byte,
            limits,
            100,
        );
    }

    try std.testing.expectEqualStrings("xy", app.approval_prompt.decision.selectedDraft());
    try std.testing.expectEqualStrings("abcd", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime approval amendment paste finalization resets state after allocation failure" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    try feedRoutingBytes(&app, "\t");
    try std.testing.expect(app.approval_prompt.isAmending());
    try app.input_runtime.paste.buffer.ensureTotalCapacity(alloc, 1);
    try feedRoutingBytes(&app, "\x1b[200~");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    app.alloc = failing.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        feedRoutingBytes(&app, "x\x1b[201~"),
    );

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.approval_prompt.isAmending());
}

test "app_input_runtime paste start drops pending gesture arms before capture" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x03");
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    armEscapeClearForTest(&app.input_runtime, 777);
    app.shell.render_requests.clearReason(.footer);

    try feedRoutingBytes(&app, "\x1b[200~");

    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expectEqual(@as(u16, 0), app.terminal_input_runtime.terminal_action_decoder.param);
    try std.testing.expectEqual(@as(u16, 0), app.terminal_input_runtime.terminal_action_decoder.param2);
    try std.testing.expectEqual(@as(i64, 0), app.terminal_input_runtime.terminal_action_decoder.started_ms);
    try std.testing.expect(!app.terminal_input_runtime.terminal_action_decoder.cancel_pending);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    try feedRoutingBytes(&app, "\x1b[201~");
}

test "app_input_runtime paste start without pending gestures skips footer redraw" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    app.shell.render_requests.clearReason(.footer);
    try feedRoutingBytes(&app, "\x1b[200~");

    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));

    try feedRoutingBytes(&app, "\x1b[201~");
}

test "app_input_runtime zero-content decision paste logs once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "zero-decision-paste.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    try feedRoutingBytes(&app, "\x1b[200~\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.approval_prompt.isActive());
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "decision prompt paste dropped bytes=0 reason=decision_prompt_active"));
}

test "app_input_runtime decision paste start clears pending ctrl-c and esc gestures" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    armCtrlCExitForTest(&app.input_runtime, io_mod.milliTimestamp());
    armEscapeClearForTest(&app.input_runtime, io_mod.milliTimestamp());
    app.shell.render_requests.clearReason(.footer);

    try feedRoutingBytes(&app, "\x1b[200~");

    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime question prompt owns and discards bracketed paste" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    const payload = "typing\t\r\n" ++ "\x03" ++ "\x1b[99;5u" ++ "\x1b[A" ++ "\x1b[200~";
    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, payload);
    try std.testing.expect(app.question_prompt.isActive());
    try std.testing.expectEqual(@as(u8, 0), currentQuestionChoiceForRoutingTest(&app.question_prompt));
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.entries.items[0].freeform_buffer.items.len);

    try feedRoutingBytes(&app, "\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.question_prompt.isActive());
}

test "app_input_runtime question freeform accepts bracketed paste atomically" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.question_prompt.moveChoice(-1);

    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.question_freeform, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, "first\rsecond\tvalue\x03");
    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.entries.items[0].freeform_buffer.items.len);
    try std.testing.expectEqualStrings("first\rsecond value", app.input_runtime.paste.buffer.items);

    try feedRoutingBytes(&app, "\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqualStrings("first\nsecond value", app.question_prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime rejects unsafe suffixes for every root modal paste owner" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
            .label = "terminal.exec npm test",
        }));

        try feedRoutingBytes(&app, "\x1b[200~\x1b[201~1\r");

        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(app.worker.submitted_permission == null);
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
            .label = "terminal.exec npm test",
        }));
        try feedRoutingBytes(&app, "\tkeep");

        try feedRoutingBytes(&app, "\x1b[200~new\x1b[201~\r");

        try std.testing.expectEqualStrings("keep", app.approval_prompt.decision.selectedDraft());
        try std.testing.expect(app.worker.submitted_permission == null);
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        const opts = [_]types.QuestionOption{
            .{ .label = "Alpha", .description = null },
            .{ .label = "Other", .description = null },
        };
        const entries = [_]types.QuestionBatchEntry{
            .{ .question = "Continue?", .options = &opts },
        };
        try app.question_prompt.syncFrom(alloc, &entries);
        app.question_prompt.moveChoice(-1);
        try feedRoutingBytes(&app, "keep");

        try feedRoutingBytes(&app, "\x1b[200~new\x1b[201~\r");

        try std.testing.expectEqualStrings(
            "keep",
            app.question_prompt.entries.items[0].freeform_buffer.items,
        );
        try std.testing.expect(app.question_prompt.isActive());
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    }
}

test "app_input_runtime question freeform rejects paste beyond input limit" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.question_prompt.moveChoice(-1);

    try feedRoutingBytes(&app, "\x1b[200~");
    try feedRoutingBytes(&app, "x" ** 4097);
    try feedRoutingBytes(&app, "\x1b[201~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.entries.items[0].freeform_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "app_input_runtime rejects invalid utf8 paste without changing the draft" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "safe draft");

    try feedRoutingBytes(&app, "\x1b[200~");
    try Runtime(RoutingFakeApp).handleByte(&app, 0xC3, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, '(', 4096, 100);
    try feedRoutingBytes(&app, "\x1b[201~");

    try std.testing.expectEqualStrings("safe draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);
}

test "app_input_runtime admits a typed utf8 scalar only when the whole scalar fits" {
    const alloc = std.testing.allocator;

    for ([_]struct {
        limit: usize,
        expected: []const u8,
    }{
        .{ .limit = 2, .expected = "x" },
        .{ .limit = 3, .expected = "xé" },
    }) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.textReplacementState().replace(alloc, "x");

        try Runtime(RoutingFakeApp).handleByte(&app, 0xC3, case.limit, 100);
        try std.testing.expectEqualStrings("x", app.input_runtime.edit_state.input.items);
        try Runtime(RoutingFakeApp).handleByte(&app, 0xA9, case.limit, 100);

        try std.testing.expectEqualStrings(case.expected, app.input_runtime.edit_state.input.items);
        try std.testing.expect(std.unicode.utf8ValidateSlice(app.input_runtime.edit_state.input.items));
    }
}

test "app_input_runtime reports one notice for a continuous composer limit rejection" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abcd");

    try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'y', 4, 100);

    try std.testing.expectEqualStrings("abcd", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);

    try Runtime(RoutingFakeApp).handleByte(&app, 0x7F, 4, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'z', 4, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'q', 4, 100);

    try std.testing.expectEqualStrings("abcz", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.notice_write_count);
}

test "app_input_runtime bounds typed question and approval drafts with visible feedback" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        const opts = [_]types.QuestionOption{
            .{ .label = "Alpha", .description = null },
        };
        const entries = [_]types.QuestionBatchEntry{
            .{ .question = "Continue?", .options = &opts },
        };
        try app.question_prompt.syncFrom(alloc, &entries);
        app.question_prompt.moveChoice(-1);

        try feedRoutingBytesWithLimit(&app, "abcc", 2);

        try std.testing.expectEqualStrings("ab", app.question_prompt.entries.items[0].freeform_buffer.items);
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
        try std.testing.expect(app.shell.render_requests.hasReason(.modal));
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
            .label = "terminal.exec npm test",
        }));
        try Runtime(RoutingFakeApp).handleByte(&app, '\t', 2, 100);

        try feedRoutingBytesWithLimit(&app, "abcc", 2);

        try std.testing.expectEqualStrings("ab", app.approval_prompt.decision.selectedDraft());
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
        try std.testing.expect(app.shell.render_requests.hasReason(.modal));
    }
}

test "app_input_runtime rejects yank and file completion before owner mutation" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.textReplacementState().replace(alloc, "abc");
        try app.input_runtime.kill_ring.text.appendSlice(alloc, "XY");

        try Runtime(RoutingFakeApp).routeComposerShortcutAction(&app, .yank, 4);

        try std.testing.expectEqualStrings("abc", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqualStrings("XY", app.input_runtime.kill_ring.text.items);
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        const completions = [_]file_index.Candidate{.{ .path = "long/path.zig", .kind = .file }};
        app.file_completion_values = &completions;
        try app.input_runtime.textReplacementState().replace(alloc, "@l");

        try Runtime(RoutingFakeApp).handleByte(&app, '\t', 2, 100);

        try std.testing.expectEqualStrings("@l", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
        try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null);
        try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    }
}

test "app_input_runtime routes typed utf8 scalars to modal editors" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        const opts = [_]types.QuestionOption{
            .{ .label = "Alpha", .description = null },
            .{ .label = "Other", .description = null },
        };
        const entries = [_]types.QuestionBatchEntry{
            .{ .question = "Continue?", .options = &opts },
        };
        try app.question_prompt.syncFrom(alloc, &entries);
        app.question_prompt.entries.items[0].choice_index =
            @intCast(app.question_prompt.entries.items[0].options.items.len - 1);

        try feedRoutingBytes(&app, "🙂");

        try std.testing.expectEqualStrings("🙂", app.question_prompt.entries.items[0].freeform_buffer.items);
        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
        try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);

        try feedRoutingBytes(&app, "🙂");

        try std.testing.expectEqualStrings("🙂", app.approval_prompt.decision.selectedDraft());
        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    }
}

test "app_input_runtime question prompt owns paste over an approval amendment" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    try feedRoutingBytes(&app, "\tkeep");
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expectEqualStrings("keep", app.approval_prompt.decision.selectedDraft());

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, "question paste\x1b[201~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.question_prompt.isActive());
    try std.testing.expectEqual(@as(u8, 0), currentQuestionChoiceForRoutingTest(&app.question_prompt));
    try std.testing.expectEqualStrings("keep", app.approval_prompt.decision.selectedDraft());
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime routes input to the innermost active modal" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    const opts = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.subagents.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try std.testing.expect(app.question_prompt.isActive());
    try std.testing.expect(!app.approval_prompt.isAmending());
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);

    app.question_prompt.discard(alloc, "test_cleanup");
    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);

    app.approval_prompt.clear(alloc);
    try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);
    try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_keys);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime delegates only presented child approval ctrl-x" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .label = "terminal.exec npm test" },
    ));

    try Runtime(RoutingFakeApp).handleByte(&app, ctrl_x_manager_byte, 4096, 100);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 0), app.subagents.toggle_view_calls);
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);

    app.subagents.main_approval_presented = true;
    try Runtime(RoutingFakeApp).handleByte(&app, '3', 4096, 100);
    try std.testing.expectEqual(ToolPermissionDecision.deny, app.worker.submitted_permission.?);
    try std.testing.expectEqual(@as(usize, 0), app.subagents.toggle_view_calls);
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);

    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .label = "terminal.exec cargo test" },
    ));
    try Runtime(RoutingFakeApp).handleByte(&app, ctrl_x_manager_byte, 4096, 100);
    try std.testing.expectEqual(@as(usize, 1), app.subagents.toggle_view_calls);
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);
}

test "app_input_runtime active paste shields prompts from escape timeout cancellation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.paste.end_match_len);

    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.paste.end_match_len);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expect(!app.terminal_input_runtime.terminal_action_decoder.cancel_pending);
}

test "app_input_runtime terminal paste pauses and resumes the resize cursor probe only at exact boundaries" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.terminal_input_runtime.terminal_cursor_probe.begin(.ansi_tagged, 0);

    for ("\x1b[200~") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    switch (app.terminal_input_runtime.terminal_cursor_probe.poll(std.math.maxInt(i64))) {
        .none => {},
        else => return error.TestExpectedEqual,
    }

    for ("\x1b[201;1~") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    switch (app.terminal_input_runtime.terminal_cursor_probe.poll(std.math.maxInt(i64))) {
        .none => {},
        else => return error.TestExpectedEqual,
    }

    for ("\x1b[201~") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try Runtime(RoutingFakeApp).settleTerminalPasteDeliveryEpochWithLimits(
        &app,
        paste_framing.InputLimits.single(4096),
    );
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    switch (app.terminal_input_runtime.terminal_cursor_probe.poll(std.math.maxInt(i64))) {
        .probe_timed_out => {},
        else => return error.TestExpectedEqual,
    }
}

test "app_input_runtime false paste starts leave decision prompt controls usable" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    try feedRoutingBytes(&app, "\x1b[0200~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.worker.submitted_permission == null);

    try feedRoutingBytes(&app, "\x1b[200;1~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.worker.submitted_permission == null);

    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, '[', 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 'C', 4096, 100);
    try std.testing.expectEqual(@as(u8, 1), app.approval_prompt.decision.choice_index);

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);
    try std.testing.expectEqual(ToolPermissionDecision.always, app.worker.submitted_permission.?);
}

test "app_input_runtime false paste starts preserve stale paste and gestures" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    app.input_runtime.paste.decision_bytes = 7;
    try app.input_runtime.paste.buffer.appendSlice(alloc, "old");
    armCtrlCExitForTest(&app.input_runtime, 123);
    armEscapeClearForTest(&app.input_runtime, 456);
    app.shell.render_requests.clearReason(.footer);

    try feedRoutingBytes(&app, "\x1b[0200~");
    try feedRoutingBytes(&app, "\x1b[200;1~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 7), app.input_runtime.paste.decision_bytes);
    try std.testing.expectEqualStrings("old", app.input_runtime.paste.buffer.items);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expectEqual(
        @as(?i64, 123),
        app.input_runtime.gestures.ctrlCExitArmedAt(),
    );
    try std.testing.expectEqual(
        @as(?i64, 456),
        app.input_runtime.gestures.escapeClearArmedAt(),
    );
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime manager root paste preserves all main composer and session state" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.subagents.active = true;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "MAIN");
    app.input_runtime.edit_state.cursor = 2;
    try app.input_runtime.composer_history.record(alloc, 100, "history entry", &.{}, &.{}, &.{}, &.{});
    const pasted_text = try alloc.dupe(u8, "preserved backing");
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = pasted_text,
        .line_count = 1,
    });
    app.input_runtime.entities.next_paste_id = 8;
    app.session_persistence.degraded_warning_emitted = true;

    try feedRoutingBytes(&app, "\x1b[0200~");
    try feedRoutingBytes(&app, "\x1b[200;1~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);
    try std.testing.expectEqualStrings("MAIN", app.input_runtime.edit_state.input.items);

    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.subagents.managerPasteActive());
    try feedRoutingBytes(&app, "ROOT_PASTE_LEAK" ++ "\x19" ++ "\x1b[A");
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_keys);
    try feedRoutingBytes(&app, "\x1b[201~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(!app.subagents.managerPasteActive());
    try std.testing.expectEqualStrings("MAIN", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings("preserved backing", app.input_runtime.entities.pasted_blocks.items[0].text);
    try std.testing.expectEqual(@as(usize, 8), app.input_runtime.entities.next_paste_id);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings("history entry", app.input_runtime.composer_history.entryText(0).?);
    try std.testing.expect(app.session_persistence.degraded_warning_emitted);
    try std.testing.expect(app.subagents.isViewActive());
}

test "app_input_runtime manager paste pauses and resumes cursor probe at exact boundaries" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.subagents.active = true;
    try app.terminal_input_runtime.terminal_cursor_probe.begin(.ansi_tagged, 0);

    for ("\x1b[200~") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expect(app.subagents.managerPasteActive());
    switch (app.terminal_input_runtime.terminal_cursor_probe.poll(std.math.maxInt(i64))) {
        .none => {},
        else => return error.TestExpectedEqual,
    }

    for ("\x1b[201;1~") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try std.testing.expect(app.subagents.managerPasteActive());
    switch (app.terminal_input_runtime.terminal_cursor_probe.poll(std.math.maxInt(i64))) {
        .none => {},
        else => return error.TestExpectedEqual,
    }

    for ("\x1b[201~") |byte| {
        try Runtime(RoutingFakeApp).handleTerminalByte(&app, byte, 4096, 100);
    }
    try Runtime(RoutingFakeApp).settleTerminalPasteDeliveryEpochWithLimits(
        &app,
        paste_framing.InputLimits.single(4096),
    );
    try std.testing.expect(!app.subagents.managerPasteActive());
    switch (app.terminal_input_runtime.terminal_cursor_probe.poll(std.math.maxInt(i64))) {
        .probe_timed_out => {},
        else => return error.TestExpectedEqual,
    }
}

test "app_input_runtime routes keys to subagent view when no modal is active" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.subagents.active = true;

    try feedRoutingBytes(&app, "\x1b[A");
    try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_keys);
    try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_actions);
    try std.testing.expectEqual(@as(usize, 0), app.subagents.handled_raw_keys);

    try Runtime(RoutingFakeApp).handleByte(&app, 'x', 4096, 100);
    try std.testing.expectEqual(@as(usize, 2), app.subagents.handled_keys);
    try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_actions);
    try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_raw_keys);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime routes bare and decoded Kitty Escape to the active subagent view" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        bytes: []const u8,
        flush_pending: bool = false,
    }{
        .{ .bytes = "\x1b", .flush_pending = true },
        .{ .bytes = "\x1b[27u" },
    };

    for (cases) |case| {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.subagents.active = true;

        try feedRoutingBytes(&app, case.bytes);
        if (case.flush_pending) {
            try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);
        }

        try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_keys);
        try std.testing.expectEqual(@as(?u8, 0x1b), app.subagents.last_handled_key);
        try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    }
}

test "app_input_runtime active subagent manager owns stream Escape" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;
    app.subagents.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.stream.active);
    try std.testing.expect(app.subagents.isViewActive());
    try std.testing.expectEqual(@as(usize, 1), app.subagents.handled_keys);
    try std.testing.expectEqual(@as(?u8, 0x1b), app.subagents.last_handled_key);
}

test "app_input_runtime inline scroll actions do not open the transcript viewer" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;

    const cases = [_][]const u8{
        "\x1b[<64;1;1M",
        "\x1b[<65;1;1M",
        "\x1b[5~",
        "\x1b[6~",
    };
    for (cases) |bytes| {
        try feedRoutingBytes(&app, bytes);
        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqual(
            transcript_presentation.Depth.inline_mode,
            app.shell.transcriptPresentationDepth(),
        );
        try std.testing.expect(app.stream.active);
        try std.testing.expect(!app.worker.cancel_requested);
    }
}

test "app_input_runtime ctrl-o toggles transcript viewer while arrows switch detail" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = "ctrl-o-routing-harness.out";
    var sink = try tmp.dir.createFile(std.testing.io, out_path, .{ .read = true });
    var sink_open = true;
    defer if (sink_open) sink.close(io_mod.getIo());

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.shell.stdout_file = sink;

        app.shell.render_requests.clearReason(.modal);
        try Runtime(RoutingFakeApp).handleByte(&app, 15, 4096, 100);
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(app.terminal.alternate_mouse_tracking_active);
        try std.testing.expect(app.shell.fullTranscriptActive());
        try std.testing.expect(app.shell.full_transcript.follow_tail);
        try std.testing.expect(app.shell.render_requests.hasReason(.modal));
        try std.testing.expectEqual(
            transcript_presentation.Depth.review,
            app.shell.transcriptPresentationDepth(),
        );

        try feedRoutingBytes(&app, "\x1b[C");
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqual(
            transcript_presentation.Depth.full,
            app.shell.transcriptPresentationDepth(),
        );

        try feedRoutingBytes(&app, "\x1b[D");
        try std.testing.expectEqual(
            transcript_presentation.Depth.review,
            app.shell.transcriptPresentationDepth(),
        );

        try Runtime(RoutingFakeApp).handleByte(&app, 15, 4096, 100);
        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(!app.terminal.alternate_mouse_tracking_active);
        try std.testing.expect(!app.shell.fullTranscriptActive());

        try feedRoutingBytes(&app, "\x1b[111;5u");
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(app.terminal.alternate_mouse_tracking_active);
        try std.testing.expect(app.shell.fullTranscriptActive());

        app.shell.render_requests.clearReason(.footer);
        try Runtime(RoutingFakeApp).handleByte(&app, 'a', 4096, 100);
        try Runtime(RoutingFakeApp).handleByte(&app, 'b', 4096, 100);
        try feedRoutingBytes(&app, "\x1b[D");
        try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(
            transcript_presentation.Depth.review,
            app.shell.transcriptPresentationDepth(),
        );
        try feedRoutingBytes(&app, "\x1b[C");
        try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(
            transcript_presentation.Depth.full,
            app.shell.transcriptPresentationDepth(),
        );
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());

        try Runtime(RoutingFakeApp).handleByte(&app, 24, 4096, 100);
        try feedRoutingBytes(&app, "\x1b[120;5u");
        try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 2), app.subagents.toggle_view_calls);
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());

        app.shell.render_requests.clearReason(.modal);
        app.shell.full_transcript.scroll_rows = 1;
        app.shell.full_transcript.follow_tail = true;
        try feedRoutingBytes(&app, "\x1b[5~");
        try std.testing.expectEqual(@as(u32, 0), app.shell.full_transcript.scroll_rows);
        try std.testing.expect(!app.shell.full_transcript.follow_tail);
        try std.testing.expect(app.shell.render_requests.hasReason(.modal));

        app.shell.full_transcript.scroll_rows = std.math.maxInt(u32) - 1;
        try feedRoutingBytes(&app, "\x1b[6~");
        try std.testing.expectEqual(std.math.maxInt(u32), app.shell.full_transcript.scroll_rows);
        try feedRoutingBytes(&app, "\x1b[<64;1;1M");
        try std.testing.expectEqual(std.math.maxInt(u32) - 3, app.shell.full_transcript.scroll_rows);
        try feedRoutingBytes(&app, "\x1b[<65;1;1M");
        try std.testing.expectEqual(std.math.maxInt(u32), app.shell.full_transcript.scroll_rows);
        try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);

        try feedRoutingBytes(&app, "\x1b[99;5u");
        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(!app.terminal.alternate_mouse_tracking_active);
        try std.testing.expect(!app.shell.fullTranscriptActive());
        try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
        try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
        try std.testing.expectEqual(@as(usize, 2), app.subagents.toggle_view_calls);
    }

    {
        var approval_app = try RoutingFakeApp.init(alloc);
        defer approval_app.deinit();
        approval_app.shell.stdout_file = sink;
        try std.testing.expect(try approval_app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try Runtime(RoutingFakeApp).handleByte(&approval_app, 15, 4096, 100);
        try std.testing.expect(!approval_app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(!approval_app.shell.fullTranscriptActive());

        activateFullTranscriptForRoutingTest(&approval_app);
        approval_app.shell.full_transcript.scroll_rows = 10;
        try feedRoutingBytes(&approval_app, "\x1b[5~");
        try feedRoutingBytes(&approval_app, "\x1b[<64;1;1M");
        try std.testing.expectEqual(@as(u32, 10), approval_app.shell.full_transcript.scroll_rows);
        try std.testing.expect(approval_app.terminal.fullTranscriptScreenActive());
    }

    sink.close(io_mod.getIo());
    sink_open = false;

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 1024);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b[?1000h"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b[?1006h"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b[?1000l"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b[?1006l"));
}

test "app_input_runtime skills catalog owns ctrl-o without opening another screen" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.openMenu();
    app.terminal.alternate_screen_owner = .catalog_menu;

    try Runtime(RoutingFakeApp).handleByte(&app, 15, 4096, 100);

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expect(app.terminal.catalogMenuScreenActive());
    try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());
}

test "app_input_runtime skills catalog owns ctrl-x without activating subagents" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.openMenu();

    try Runtime(RoutingFakeApp).handleByte(&app, 24, 4096, 100);

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expect(!app.subagents.isViewActive());
    try std.testing.expectEqual(@as(usize, 0), app.subagents.toggle_view_calls);
}

test "app_input_runtime skills catalog owns the all-sessions shortcut" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.skills.openMenu();

    try feedRoutingBytes(&app, "\x1b[114;9u");

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expect(!app.session_persistence.session_picker.active);
    try std.testing.expectEqual(@as(usize, 0), app.notice_body.items.len);
}

test "app_input_runtime full transcript rejects ctrl-x manager entry without losing ownership" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    activateFullTranscriptForRoutingTest(&app);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).handleByte(&app, 'a', 4096, 100);
    try std.testing.expectEqualStrings("a", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.terminal.fullTranscriptScreenActive());

    try Runtime(RoutingFakeApp).handleByte(&app, 'b', 4096, 100);
    try feedRoutingBytes(&app, "\x1b[D");
    try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(
        transcript_presentation.Depth.review,
        app.shell.transcriptPresentationDepth(),
    );

    try Runtime(RoutingFakeApp).handleByte(&app, 24, 4096, 100);
    try feedRoutingBytes(&app, "\x1b[120;5u");
    try std.testing.expectEqualStrings("ab", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 2), app.subagents.toggle_view_calls);
    try std.testing.expect(!app.subagents.isViewActive());
    try std.testing.expect(app.terminal.fullTranscriptScreenActive());
}

test "app_input_runtime full transcript page and wheel keys scroll the projection" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    activateFullTranscriptForRoutingTest(&app);
    app.shell.full_transcript.scroll_rows = 10;
    app.shell.full_transcript.follow_tail = true;

    app.shell.render_requests.clearReason(.modal);
    try feedRoutingBytes(&app, "\x1b[5~");
    try std.testing.expectEqual(@as(u32, 0), app.shell.full_transcript.scroll_rows);
    try std.testing.expect(!app.shell.full_transcript.follow_tail);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));

    try feedRoutingBytes(&app, "\x1b[6~");
    try std.testing.expectEqual(@as(u32, 20), app.shell.full_transcript.scroll_rows);

    try feedRoutingBytes(&app, "\x1b[<64;1;1M");
    try std.testing.expectEqual(@as(u32, 17), app.shell.full_transcript.scroll_rows);
    try feedRoutingBytes(&app, "\x1b[<65;1;1M");
    try std.testing.expectEqual(@as(u32, 20), app.shell.full_transcript.scroll_rows);

    try std.testing.expect(app.terminal.fullTranscriptScreenActive());
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime ctrl-o opens review and closes active transcript from each encoding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "full-transcript-toggle.log", .{ .read = true });
    defer sink.close(io_mod.getIo());

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.shell.stdout_file = sink;

        try feedRoutingBytes(&app, "\x1b[111;5u");

        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(app.terminal.alternate_mouse_tracking_active);
        try std.testing.expect(app.shell.fullTranscriptActive());
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.shell.stdout_file = sink;

        try Runtime(RoutingFakeApp).handleByte(&app, 15, 4096, 100);
        try feedRoutingBytes(&app, "\x1b[C");
        try std.testing.expectEqual(
            transcript_presentation.Depth.full,
            app.shell.transcriptPresentationDepth(),
        );
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());

        try Runtime(RoutingFakeApp).handleByte(&app, 15, 4096, 100);
        try std.testing.expectEqual(
            transcript_presentation.Depth.inline_mode,
            app.shell.transcriptPresentationDepth(),
        );
        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        activateFullTranscriptForRoutingTest(&app);
        app.shell.stdout_file = sink;
        try feedRoutingBytes(&app, "hi");

        try feedRoutingBytes(&app, "\x1b[C");
        try Runtime(RoutingFakeApp).handleByte(&app, 15, 4096, 100);

        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        activateFullTranscriptForRoutingTest(&app);
        app.shell.stdout_file = sink;
        try feedRoutingBytes(&app, "hi");

        try feedRoutingBytes(&app, "\x1b[C");
        try feedRoutingBytes(&app, "\x1b[111;5u");

        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        activateFullTranscriptForRoutingTest(&app);
        app.shell.stdout_file = sink;
        try feedRoutingBytes(&app, "hi");

        try feedRoutingBytes(&app, "\x1b[C");
        try feedRoutingBytes(&app, "\x1b[27;5;111~");

        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.shell.stdout_file = sink;
        try feedRoutingBytes(&app, "hi");

        try feedRoutingBytes(&app, "\x1b[27;5;111~");

        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
    }
}

test "app_input_runtime full transcript ctrl-c closes the screen and preserves the composer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "full-transcript-interrupt.log", .{ .read = true });
    defer sink.close(io_mod.getIo());

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        activateFullTranscriptForRoutingTest(&app);
        app.shell.stdout_file = sink;
        try feedRoutingBytes(&app, "hi");

        try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);

        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
        try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
        try std.testing.expect(!app.should_exit);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        activateFullTranscriptForRoutingTest(&app);
        app.shell.stdout_file = sink;
        try feedRoutingBytes(&app, "hi");

        try feedRoutingBytes(&app, "\x1b[99;5u");

        try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
        try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
        try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
        try std.testing.expect(!app.should_exit);
    }
}

test "app_input_runtime raw escape closes full transcript without cancelling active work" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "full-transcript-escape.log", .{ .read = true });
    defer sink.close(io_mod.getIo());

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    activateFullTranscriptForRoutingTest(&app);
    app.shell.stdout_file = sink;
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

    try std.testing.expect(!app.terminal.fullTranscriptScreenActive());
    try std.testing.expect(!app.shell.fullTranscriptActive());
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.stream.active);
}

test "app_input_runtime approval prompt blocks full transcript key interception" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    activateFullTranscriptForRoutingTest(&app);
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    app.shell.full_transcript.scroll_rows = 10;

    try feedRoutingBytes(&app, "\x1b[5~");

    try std.testing.expectEqual(@as(u32, 10), app.shell.full_transcript.scroll_rows);
    try std.testing.expect(app.terminal.fullTranscriptScreenActive());
}

test "app_input_runtime full transcript malformed private CSI does not leak digits into composer" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    activateFullTranscriptForRoutingTest(&app);

    try feedRoutingBytes(&app, "\x1b[?12");
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

    const draft = "CTRL_O_MALFORMED_ESCAPE_DRAFT";
    try feedRoutingBytes(&app, draft);
    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expectEqual(@as(usize, 1), app.submitted_prompt_count);
    try std.testing.expectEqualStrings(draft, app.submitted_prompt[0..app.submitted_prompt_len]);
}

test "app_input_runtime stray paste end cannot finalize stale composer state" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.paste.buffer.appendSlice(alloc, "stale");

    try feedRoutingBytes(&app, "\x1b[201~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqualStrings("stale", app.input_runtime.paste.buffer.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime false paste ends cannot finalize stale composer state" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.paste.buffer.appendSlice(alloc, "stale");

    try feedRoutingBytes(&app, "\x1b[0201~");
    try feedRoutingBytes(&app, "\x1b[201;1~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqualStrings("stale", app.input_runtime.paste.buffer.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime new paste traces and clears stale inactive state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "stale-paste.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    app.input_runtime.paste.decision_bytes = 7;
    try app.input_runtime.paste.buffer.appendSlice(alloc, "old");

    try feedRoutingBytes(&app, "\x1b[200~");

    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.decision_bytes);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "decision prompt paste dropped bytes=7 reason=new_paste_stale_state") != null);
    try std.testing.expect(std.mem.find(u8, trace, "composer paste dropped bytes=3 reason=new_paste_stale_state") != null);
}

test "app_input_runtime composer paste stays composer owned when prompt appears" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, "hi");
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    try feedRoutingBytes(&app, "\x1b[201~");

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqualStrings("hi", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.worker.submitted_permission == null);
}

test "app_input_runtime malformed escape bytes stay inert under composer-owned paste" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    try feedRoutingBytes(&app, "\x1b[9999999999999999999q\x03\x1b[A");

    try std.testing.expectEqual(paste_framing.Owner.composer, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.should_exit);

    try feedRoutingBytes(&app, "\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqualStrings("[9999999999999999999q[A", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime modal disappearance keeps decision-owned paste pinned" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "modal-disappear-paste.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

    try feedRoutingBytes(&app, "\x1b[200~");
    app.approval_prompt.clear(app.alloc);
    try feedRoutingBytes(&app, "remaining" ++ "\x1b[200~");
    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);

    try feedRoutingBytes(&app, "\x1b[201~");
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "decision prompt paste dropped bytes=15 reason=decision_prompt_active") != null);
}

test "app_input_runtime exact paste start clears pending ctrl-c and esc gestures" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    armCtrlCExitForTest(&app.input_runtime, io_mod.milliTimestamp());
    armEscapeClearForTest(&app.input_runtime, io_mod.milliTimestamp());
    app.shell.render_requests.clearReason(.footer);

    try feedRoutingBytes(&app, "\x1b[200~\x1b[201~");
    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.should_exit);
}

test "app_input_runtime idle Ctrl-C clears composer before second press exits" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "draft");
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(
        app_session_runtime.ResumeHandoffIntent.requested,
        app.session_persistence.resume_handoff_intent,
    );
}

test "app_input_runtime pending Ctrl-C expires from state and rendering" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    armCtrlCExitForTest(
        &app.input_runtime,
        io_mod.milliTimestamp() - Runtime(RoutingFakeApp).ctrl_c_exit_window_ms,
    );
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 30);

    try std.testing.expect(!app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    app.shell.render_requests.clearReason(.footer);
    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 30);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(!app.should_exit);
}

test "app_input_runtime raw and Kitty Ctrl-C preserve double-press exit" {
    const sequences = [_][]const u8{ "\x03", "\x1b[99;5u" };

    for (sequences) |sequence| {
        const alloc = std.testing.allocator;
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();

        try feedRoutingBytes(&app, sequence);
        try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
        try std.testing.expect(!app.should_exit);

        try feedRoutingBytes(&app, sequence);
        try std.testing.expect(app.should_exit);
    }
}

test "app_input_runtime active Ctrl-C cancels stream and arms exit window" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);

    try std.testing.expect(!app.stream.active);
    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expectEqualStrings("● System: cancelled", app.transcript.items);
    try std.testing.expectEqualStrings("system", app.notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.cancelled, app.notice_tone);
    try std.testing.expectEqualStrings("cancelled", app.notice_body.items);
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmed());
    try std.testing.expect(app.input_runtime.gestures.ctrlCExitArmedAt() != null);
    try std.testing.expect(!app.should_exit);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime active tool Escape waits for terminal feedback before repainting" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;
    _ = try app.shell.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = .{ .turn_id = 1, .call_id = "command" },
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    try std.testing.expectEqual(@as(usize, 1), app.shell.activeToolActivityCount());
    app.shell.render_requests.clearReason(.footer);

    try Runtime(RoutingFakeApp).resolveEscape(&app, true, 100);

    try std.testing.expect(app.stream.active);
    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expectEqualStrings("", app.transcript.items);
    try std.testing.expectEqualStrings("", app.notice_topic.items);
    try std.testing.expectEqualStrings("", app.notice_body.items);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime second Ctrl-C after active cancellation exits without duplicate notice" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);
    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqualStrings("● System: cancelled", app.transcript.items);
    try std.testing.expectEqual(types.NoticeTone.cancelled, app.notice_tone);
}

test "app_input_runtime pending Ctrl-C exits before repeating active cancellation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;
    app.worker.cancel_requested = true;
    armCtrlCExitForTest(&app.input_runtime, io_mod.milliTimestamp());

    try Runtime(RoutingFakeApp).handleByte(&app, 3, 4096, 100);

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqualStrings("", app.transcript.items);
}

test "app_input_runtime expired incomplete control sequence preserves approval" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    app.terminal_input_runtime.terminal_action_decoder.stage = 3;
    app.terminal_input_runtime.terminal_action_decoder.param = 20;
    app.terminal_input_runtime.terminal_action_decoder.param2 = 2;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;

    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.worker.submitted_permission == null);
}

test "app_input_runtime complete unknown control sequence preserves active operation" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.stream.active = true;

    try feedRoutingBytes(&app, "\x1b[>0q");

    try std.testing.expect(app.stream.active);
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime refreshes the pending escape deadline on decoder progress" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const old_started_ms = io_mod.milliTimestamp() - 1;
    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = old_started_ms;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;

    try Runtime(RoutingFakeApp).handleByte(&app, '[', 4096, 100);

    try std.testing.expectEqual(@as(u8, 2), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expect(app.terminal_input_runtime.terminal_action_decoder.started_ms > old_started_ms);
    try std.testing.expect(app.terminal_input_runtime.terminal_action_decoder.cancel_pending);
}

test "app_input_runtime expired mouse prefixes discard their tails without cancelling approval" {
    const Case = struct {
        prefix: []const u8,
        tail: []const u8,
    };
    const cases = [_]Case{
        .{ .prefix = "\x1b[<64;79", .tail = ";12M" },
        .{ .prefix = "\x1b[M", .tail = "\x60\x2a\x25" },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try feedRoutingBytes(&app, case.prefix);
        app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
        try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);

        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);
        try feedRoutingBytes(&app, case.tail);
        try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);
        try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
    }
}

test "app_input_runtime tail-less expired mouse recovery releases quietly" {
    const prefixes = [_][]const u8{ "\x1b[<64", "\x1b[M" };

    for (prefixes) |prefix| {
        const alloc = std.testing.allocator;
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try feedRoutingBytes(&app, prefix);
        app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
        try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);
        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);

        try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);
        try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);
    }
}

test "app_input_runtime fresh Escape restarts expired mouse recovery before cancelling" {
    const prefixes = [_][]const u8{ "\x1b[<64", "\x1b[M" };

    for (prefixes) |prefix| {
        const alloc = std.testing.allocator;
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        app.stream.active = true;
        try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));

        try feedRoutingBytes(&app, prefix);
        app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
        try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);
        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);

        try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
        try std.testing.expectEqual(@as(u8, 1), app.terminal_input_runtime.terminal_action_decoder.stage);
        try std.testing.expect(app.terminal_input_runtime.terminal_action_decoder.cancel_pending);
        app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
        try Runtime(RoutingFakeApp).flushPendingEscape(&app, 0);
        try std.testing.expect(!app.approval_prompt.isActive());
        try std.testing.expect(app.worker.cancel_requested);
    }
}

test "app_input_runtime fresh escape rearms generic decoder before paste start" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{ .label = "terminal.exec npm test" }));
    app.terminal_input_runtime.terminal_action_decoder.stage = 3;
    app.terminal_input_runtime.terminal_action_decoder.param = 20;
    app.terminal_input_runtime.terminal_action_decoder.param2 = 2;
    const old_started_ms = io_mod.milliTimestamp() - 1;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = old_started_ms;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = false;
    app.stream.active = true;

    try Runtime(RoutingFakeApp).handleByte(&app, 0x1b, 4096, 100);
    try std.testing.expectEqual(@as(u8, 1), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expect(app.terminal_input_runtime.terminal_action_decoder.started_ms > old_started_ms);
    try std.testing.expectEqual(app.stream.active, app.terminal_input_runtime.terminal_action_decoder.cancel_pending);

    try feedRoutingBytes(&app, "[200~");
    try std.testing.expectEqual(paste_framing.Owner.decision_prompt, app.input_runtime.paste.owner);
}

test "app_input_runtime plain vertical routes visible slash picker while stream is active" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    app.input_runtime.vertical_navigation.preferred_column = 9;
    try Runtime(FakeApprovalCancelApp).routePlainVertical(&app, .down, 1);

    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
    try std.testing.expect(app.input_runtime.vertical_navigation.preferredColumn() == null);
}

test "app_input_runtime plain vertical keeps composer precedence over wrapped slash picker" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();
    app.stream.active = false;
    app.shell.layout.cols = 8;
    app.shell.layout.content_bottom = 10;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "       /mo");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeApprovalCancelApp).routePlainVertical(&app, .up, -1);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
    try std.testing.expect(app.input_runtime.edit_state.cursor < app.input_runtime.edit_state.input.items.len);

    const cursor_after_plain = app.input_runtime.edit_state.cursor;
    app.input_runtime.picker.slash_completion_index = 7;
    try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, 1));
    try std.testing.expectEqual(cursor_after_plain, app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
}

test "app_input_runtime tiny footer keeps wrapped slash picker visible" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();
    app.stream.active = false;
    app.shell.layout.cols = 8;
    app.shell.layout.content_bottom = 4;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "       /mo");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    app.input_runtime.picker.slash_completion_index = 7;

    try Runtime(FakeApprovalCancelApp).routePlainVertical(&app, .down, 1);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
}

test "app_input_runtime plain vertical edge history resets preferred column exactly" {
    const alloc = std.testing.allocator;
    var top = FakeApprovalCancelApp{ .alloc = alloc };
    defer top.deinit();
    top.stream.active = false;
    try top.input_runtime.edit_state.input.appendSlice(alloc, "\nabcdef");
    top.input_runtime.edit_state.cursor = top.input_runtime.edit_state.input.items.len;
    try Runtime(FakeApprovalCancelApp).routePlainVertical(&top, .up, -1);
    try std.testing.expectEqual(@as(usize, 0), top.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(?usize, 6), top.input_runtime.vertical_navigation.preferredColumn());
    try Runtime(FakeApprovalCancelApp).routeModifiedHistory(&top, .up, -1);
    try std.testing.expectEqual(@as(usize, 0), top.input_runtime.edit_state.cursor);
    try std.testing.expect(top.input_runtime.vertical_navigation.preferredColumn() == null);
    try Runtime(FakeApprovalCancelApp).routePlainVertical(&top, .down, 1);
    try std.testing.expectEqual(@as(usize, 1), top.input_runtime.edit_state.cursor);

    var bottom = FakeApprovalCancelApp{ .alloc = alloc };
    defer bottom.deinit();
    bottom.stream.active = false;
    try bottom.input_runtime.edit_state.input.appendSlice(alloc, "abcdef\n");
    bottom.input_runtime.edit_state.cursor = 6;
    try Runtime(FakeApprovalCancelApp).routePlainVertical(&bottom, .down, 1);
    try std.testing.expectEqual(bottom.input_runtime.edit_state.input.items.len, bottom.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(?usize, 6), bottom.input_runtime.vertical_navigation.preferredColumn());
    try Runtime(FakeApprovalCancelApp).routeModifiedHistory(&bottom, .down, 1);
    try std.testing.expectEqual(bottom.input_runtime.edit_state.input.items.len, bottom.input_runtime.edit_state.cursor);
    try std.testing.expect(bottom.input_runtime.vertical_navigation.preferredColumn() == null);
    try Runtime(FakeApprovalCancelApp).routePlainVertical(&bottom, .up, -1);
    try std.testing.expectEqual(@as(usize, 0), bottom.input_runtime.edit_state.cursor);
}

test "approval cancellation uses one worker-owned terminal transition" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .label = "terminal.exec npm test" },
    ));

    try Runtime(FakeApprovalCancelApp).cancelApprovalOperation(&app);

    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expectEqual(@as(usize, 1), app.worker.order_len);
    try std.testing.expectEqual(ApprovalCancelEvent.request_cancel, app.worker.order[0]);
    try std.testing.expect(!app.approval_prompt.isActive());
    try std.testing.expect(!app.stream.active);
    try std.testing.expect(app.pacer.cleared);
    try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
    try std.testing.expectEqual(transcript_runtime.RawEntryClass.unknown_raw, app.last_class);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}

test "escape on a freeform draft arms then clears before cancelling the batch" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Inspect repo state", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "What next?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    app.question_prompt.moveChoice(-1);
    try std.testing.expect(app.question_prompt.isFreeformSelected());
    _ = try app.question_prompt.apply(alloc, .{ .insert_ascii = 'k' });

    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
    try Runtime(FakeApprovalCancelApp).flushPendingEscape(&app, 0);

    try std.testing.expect(app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expectEqual(@as(usize, 1), app.question_prompt.freeformDraftLen());
    try std.testing.expect(app.question_prompt.isActive());
    try std.testing.expect(!app.worker.cancel_requested);

    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
    try Runtime(FakeApprovalCancelApp).flushPendingEscape(&app, 0);

    try std.testing.expectEqual(@as(usize, 0), app.question_prompt.freeformDraftLen());
    try std.testing.expect(app.question_prompt.isFreeformSelected());
    try std.testing.expect(app.question_prompt.isActive());
    try std.testing.expect(!app.input_runtime.gestures.escapeClearArmed());
    try std.testing.expect(!app.worker.cancel_requested);

    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;
    try Runtime(FakeApprovalCancelApp).flushPendingEscape(&app, 0);

    try std.testing.expect(!app.question_prompt.isActive());
}

test "bare escape during approval uses worker-owned cancellation" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .label = "terminal.exec npm test" },
    ));
    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;

    try Runtime(FakeApprovalCancelApp).flushPendingEscape(&app, 0);

    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expectEqual(ApprovalCancelEvent.request_cancel, app.worker.order[0]);
    try std.testing.expect(!app.approval_prompt.isActive());
    try std.testing.expect(!app.stream.active);
}

test "stale approval escape cancels and wakes the worker current request" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .id = 41, .label = "stale A" },
    ));
    app.worker.active_permission_request_id = 42;
    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;

    try Runtime(RoutingFakeApp).flushPendingEscape(
        &app,
        0,
    );

    try std.testing.expect(app.worker.cancel_requested);
    try std.testing.expectEqual(
        ToolPermissionDecision.deny,
        app.worker.permission_response.?,
    );
    try std.testing.expect(!app.approval_prompt.isActive());
    try std.testing.expectEqual(
        worker_runtime.PermissionSubmissionResult.no_pending,
        app.worker.submitPermissionResponse(
            41,
            permission_request.OwnedPermissionResponse.init(alloc, .always, null),
        ),
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.deny,
        app.worker.permission_response.?,
    );
    try std.testing.expect(app.worker.submitted_permission == null);
}

const routing_file_approval_preview_lines =
    [_]@import("../output/diff.zig").PreviewLine{
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

fn routingFileApprovalRequest(
    id: u64,
) permission_request.PermissionRequest {
    return .{
        .id = id,
        .label = "file_mutation",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &routing_file_approval_preview_lines,
                .additions = 1,
                .deletions = 1,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
}

fn installReadyRoutingFileApproval(app: *RoutingFakeApp) !void {
    try std.testing.expect(try app.approval_prompt.syncRequest(
        app.alloc,
        routingFileApprovalRequest(41),
    ));
    app.worker.active_permission_request_id = 41;
    app.shell.layout.rows = 24;
    app.shell.layout.cols = 96;
    app.shell.footer_viewport.has_frame = true;
    app.shell.footer_viewport.geometry = .{
        .top = 1,
        .top_divider = 1,
        .input_base = 2,
        .bottom_divider = 13,
        .hint = 13,
    };
    app.approval_screen.recordScreenCommit(41, .{
        .request_id = 41,
        .rows = app.shell.layout.rows,
        .cols = app.shell.layout.cols,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });
}

test "app_input_runtime consumes legacy X10 reports during active file approval" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try installReadyRoutingFileApproval(&app);
        app.approval_screen.recordScreenCommit(41, .{
            .request_id = 41,
            .rows = 24,
            .cols = 96,
            .file_identity_visible = true,
            .all_decision_controls_visible = true,
            .changed_or_notice_visible = true,
            .document_scrollable = true,
        });
        app.approval_screen.document_scroll_rows = 3;
        app.stream.active = true;

        try feedRoutingBytes(&app, "\x1b[M\x60\x2a\x25");

        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);
        try std.testing.expect(app.stream.active);
        try std.testing.expectEqual(@as(usize, 6), app.approval_screen.document_scroll_rows);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try installReadyRoutingFileApproval(&app);
        app.stream.active = true;

        try feedRoutingBytes(&app, "\x1b[M\x1b\x2a\x25");

        try std.testing.expect(app.approval_prompt.isActive());
        try std.testing.expect(!app.worker.cancel_requested);
        try std.testing.expect(app.stream.active);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    }
}

test "app_input_runtime keeps in-progress SGR mouse reports past bare escape timeout" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);
    app.approval_screen.document_scroll_rows = 3;
    app.stream.active = true;

    try feedRoutingBytes(&app, "\x1b[<65;79;");
    app.terminal_input_runtime.terminal_action_decoder.started_ms = io_mod.milliTimestamp() - 31;

    try Runtime(RoutingFakeApp).flushPendingEscape(&app, 30);
    try feedRoutingBytes(&app, "12M");

    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(app.stream.active);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.stage);
    try std.testing.expectEqual(@as(u8, 0), app.terminal_input_runtime.terminal_action_decoder.mouse.sgr_bytes);
    try std.testing.expectEqual(@as(usize, 0), app.approval_screen.document_scroll_rows);
}

test "file approval enter waits for the matching committed modal frame" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);

    app.shell.render_requests.request(.modal);
    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expect(app.approval_prompt.isActive());

    app.shell.render_requests.clearReason(.modal);
    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.once,
        app.worker.submitted_permission.?,
    );
    try std.testing.expect(!app.approval_prompt.isActive());
}

test "file approval digit submits the mapped choice when the modal is ready" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '2',
        4096,
        100,
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.always,
        app.worker.submitted_permission.?,
    );
    try std.testing.expect(!app.approval_prompt.isActive());
}

test "file approval keeps the active review when feedback materialization fails" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);

    _ = try app.approval_prompt.decision.apply(alloc, .tab, true, null);
    _ = try app.approval_prompt.decision.apply(
        alloc,
        .{ .insert_ascii = 's' },
        true,
        null,
    );
    _ = try app.approval_prompt.decision.apply(
        alloc,
        .{ .insert_ascii = 'u' },
        true,
        null,
    );
    _ = try app.approval_prompt.decision.apply(
        alloc,
        .{ .insert_ascii = 'm' },
        true,
        null,
    );

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    app.alloc = failing.allocator();
    defer app.alloc = alloc;

    try std.testing.expectError(
        error.OutOfMemory,
        Runtime(RoutingFakeApp).handleByte(
            &app,
            '\r',
            4096,
            100,
        ),
    );
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expect(app.approval_prompt.isAmending());
    try std.testing.expectEqualStrings("sum", app.approval_prompt.decision.selectedDraft());
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expectEqual(@as(usize, 1), app.affirmative_claim_count);
    try std.testing.expectEqual(@as(usize, 1), app.affirmative_release_count);
}

test "approval submission transfers feedback to the worker without a local card" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .label = "terminal.exec printf done",
    }));
    try Runtime(RoutingFakeApp).handleByte(&app, '\t', 4096, 100);
    for ("summarize the output") |byte| {
        try Runtime(RoutingFakeApp).handleByte(&app, byte, 4096, 100);
    }

    try Runtime(RoutingFakeApp).handleByte(&app, '\r', 4096, 100);

    try std.testing.expect(std.mem.find(u8, app.transcript.items, "summarize the output") == null);
    try std.testing.expectEqualStrings(
        "summarize the output",
        app.worker.submitted_permission_feedback[0..app.worker.submitted_permission_feedback_len],
    );
}

test "byte-identical replacement waits for commit and rejects stale request input" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);

    app.worker.active_permission_request_id = 42;
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        routingFileApprovalRequest(42),
    ));
    app.shell.render_requests.request(.modal);

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expectEqual(
        worker_runtime.PermissionSubmissionResult.stale,
        app.worker.submitPermissionResponse(
            41,
            permission_request.OwnedPermissionResponse.init(alloc, .once, null),
        ),
    );
    try std.testing.expect(app.worker.permission_response == null);

    var attempt =
        (try app.shell.render_requests.beginAttempt()).?;
    try std.testing.expect(!approval_ui.fileApprovalAffirmativeReady(
        &app.shell,
        app.approval_prompt.projection().?,
    ));
    attempt.commit(
        1_000,
        render_request.animation_interval_ms,
        false,
    );
    app.approval_screen.recordScreenCommit(42, .{
        .request_id = 42,
        .rows = app.shell.layout.rows,
        .cols = app.shell.layout.cols,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.once,
        app.worker.submitted_permission.?,
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.once,
        app.worker.permission_response.?,
    );
    try std.testing.expect(!app.approval_prompt.isActive());
}

test "file approval affirmative enter admits a pending raw resize" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);
    app.approval_resize_interlock.noteResizeSignal();

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );
    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expect(app.shell.render_requests.resize_dirty);
    try std.testing.expect(app.shell.render_requests.hasReason(.resize));
}

test "resize signal after readiness blocks affirmative before worker submission" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);
    app.inject_resize_before_affirmative_claim = true;

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );

    try std.testing.expect(app.worker.submitted_permission == null);
    try std.testing.expect(app.approval_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 1), app.affirmative_claim_count);
    try std.testing.expectEqual(@as(usize, 0), app.affirmative_release_count);
    try std.testing.expect(app.approval_resize_interlock.resizePending());

    try std.testing.expect(app.admitPendingApprovalResize());
    app.shell.render_requests.completeResizeGeometry(false);
    var attempt = (try app.shell.render_requests.beginAttempt()).?;
    attempt.commit(
        1_000,
        render_request.animation_interval_ms,
        false,
    );
    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.once,
        app.worker.submitted_permission.?,
    );
    try std.testing.expectEqual(@as(usize, 2), app.affirmative_claim_count);
    try std.testing.expectEqual(@as(usize, 1), app.affirmative_release_count);
}

test "affirmative claim preserves resize raised during worker submission" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);
    app.worker.resize_signal_on_submit = &app.approval_resize_interlock;

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '\r',
        4096,
        100,
    );

    try std.testing.expectEqual(
        ToolPermissionDecision.once,
        app.worker.submitted_permission.?,
    );
    try std.testing.expectEqual(@as(usize, 1), app.affirmative_claim_count);
    try std.testing.expectEqual(@as(usize, 1), app.affirmative_release_count);
    try std.testing.expect(app.approval_resize_interlock.resizePending());
    try std.testing.expect(app.admitPendingApprovalResize());
    try std.testing.expect(app.shell.render_requests.hasReason(.resize));
}

test "file approval denial remains actionable while modal work is pending" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try installReadyRoutingFileApproval(&app);

    try Runtime(RoutingFakeApp).handleByte(
        &app,
        '3',
        4096,
        100,
    );
    try std.testing.expectEqual(
        ToolPermissionDecision.deny,
        app.worker.submitted_permission.?,
    );
    try std.testing.expect(!app.approval_prompt.isActive());
}

test "bare escape trace captures approval interrupt context" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "escape-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "interrupt");

    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(
        alloc,
        .{ .label = "terminal.exec npm test" },
    ));
    app.terminal_input_runtime.terminal_action_decoder.stage = 1;
    app.terminal_input_runtime.terminal_action_decoder.cancel_pending = true;
    app.terminal_input_runtime.terminal_action_decoder.started_ms = 0;

    try Runtime(FakeApprovalCancelApp).flushPendingEscape(&app, 0);
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=cancel_requested") != null);
    try std.testing.expect(std.mem.find(u8, trace, "source=input_approval") != null);
    try std.testing.expect(std.mem.find(u8, trace, "stream_active=true") != null);
    try std.testing.expect(std.mem.find(u8, trace, "active_streamed_text_response=false") != null);
    try std.testing.expect(std.mem.find(u8, trace, "pending_tool_call=true") != null);
    try std.testing.expect(std.mem.find(u8, trace, "approval_prompt=true") != null);
    try std.testing.expect(std.mem.find(u8, trace, "running_tool=false") != null);
}

test "question resolution append does not add a second gap after prompt card" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();

    const opts = [_]types.QuestionOption{
        .{ .label = "Inspect repo state", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "What would you like to do next?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    try std.testing.expectEqual(
        question_prompt.QuestionInputEvent.all_decided,
        try app.question_prompt.apply(alloc, .submit),
    );

    try Runtime(FakeApprovalCancelApp).submitQuestionBatch(&app);

    try std.testing.expect(!std.mem.startsWith(u8, app.shell.transcript.items, "\n"));
    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "  1) What would you like to do next?\n") != null);
    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "     Inspect repo state") != null);
}

test "route recovery question submit does not write agent question transcript" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.worker.question_source = .route_recovery;

    const opts = [_]types.QuestionOption{
        .{ .label = "Change model", .description = null },
        .{ .label = "Try again later", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Route failed after 3 attempts. What should fx do?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);
    try std.testing.expectEqual(
        question_prompt.QuestionInputEvent.all_decided,
        try app.question_prompt.apply(alloc, .submit),
    );

    try Runtime(RoutingFakeApp).submitQuestionBatch(&app);

    try std.testing.expectEqual(@as(usize, 1), app.worker.submitted_question_count);
    try std.testing.expectEqualStrings(
        "Change model",
        app.worker.submitted_question_answers[0][0..app.worker.submitted_question_answer_lens[0]],
    );
    try std.testing.expect(!app.question_prompt.isActive());
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(app.transcript.items, "Route failed after 3 attempts. What should fx do?"));
}

test "route recovery question cancel stays local" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    app.worker.question_source = .route_recovery;
    app.stream.active = true;

    const opts = [_]types.QuestionOption{
        .{ .label = "Try again later", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Route failed. What should fx do?", .options = &opts },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    try input_question_runtime.QuestionRuntime(RoutingFakeApp).cancelQuestionPrompt(&app);

    try std.testing.expect(app.worker.question_cancelled);
    try std.testing.expect(!app.worker.cancel_requested_when_question_cancelled);
    try std.testing.expect(!app.worker.cancel_requested);
    try std.testing.expect(!app.question_prompt.isActive());
    try std.testing.expect(!app.stream.active);
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(app.transcript.items, "Route failed. What should fx do?"));
}

test "app_input_runtime submits multi-question answers in entry order" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    const first_options = [_]types.QuestionOption{
        .{ .label = "First", .description = null },
        .{ .label = "Second", .description = null },
    };
    const second_options = [_]types.QuestionOption{
        .{ .label = "Third", .description = null },
        .{ .label = "Fourth", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Choose the first answer", .options = &first_options },
        .{ .question = "Choose the second answer", .options = &second_options },
    };
    try app.question_prompt.syncFrom(alloc, &entries);

    try feedRoutingBytes(&app, "\r2");

    try std.testing.expectEqual(@as(usize, 2), app.worker.submitted_question_count);
    try std.testing.expectEqualStrings(
        "First",
        app.worker.submitted_question_answers[0][0..app.worker.submitted_question_answer_lens[0]],
    );
    try std.testing.expectEqualStrings(
        "Fourth",
        app.worker.submitted_question_answers[1][0..app.worker.submitted_question_answer_lens[1]],
    );
    try std.testing.expect(!app.question_prompt.isActive());
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(app.transcript.items, "Choose the first answer"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(app.transcript.items, "     Fourth"),
    );
}

const FakeSubmitApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    input_runtime: core_input_runtime.Runtime = .{},
    prompt_history: prompt_history_runtime.PromptHistoryRuntime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    stream: types.StreamState = .{},
    pacer: struct {
        completed_assistant_presentation_tail: bool = false,

        pub fn hasCompletedAssistantPresentationTail(self: *const @This()) bool {
            return self.completed_assistant_presentation_tail;
        }
    } = .{},
    worker: struct {
        pub fn queuedPromptCount(_: *@This()) usize {
            return 0;
        }
    } = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
        layout: types.Layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    } = .{},
    next_image_id_counter: usize = 1,
    transcript: std.ArrayList(u8) = .empty,
    last_command: ?[]u8 = null,
    last_prompt: ?[]u8 = null,
    last_images: []types.ImageAttachment = &.{},
    last_skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,
    notice_visibility: types.NoticeVisibility = .compact_and_full,
    input_len_at_command: usize = 0,
    command_count: usize = 0,
    fail_notice: bool = false,
    prompt_admitted: bool = true,
    queue_admitted: bool = true,
    queue_accept_count: usize = 0,
    preflight_count: usize = 0,
    notice_count: usize = 0,
    capture_count: usize = 0,
    capture_error_id: ?usize = null,
    capture_error: ?anyerror = null,
    fail_enqueue_after_snapshot: bool = false,
    fail_command_after_pending_clear: bool = false,
    snapshot_dir: ?[]const u8 = null,

    pub fn slashRegistry(_: *const FakeSubmitApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FakeSubmitApp) void {
        self.prompt_history.deinit(self.alloc);
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
        if (self.last_command) |text| self.alloc.free(text);
        if (self.last_prompt) |text| self.alloc.free(text);
        types.freeImageAttachmentSlice(self.alloc, self.last_images);
        self.clearLastSkillTokens();
        self.last_skill_tokens.deinit(self.alloc);
    }

    pub fn writeDomainNotice(self: *FakeSubmitApp, notice: types.SemanticNotice, _: bool) !void {
        if (self.fail_notice) return error.InjectedTranscriptFailure;
        self.notice_count += 1;
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
        self.notice_visibility = notice.visibility;
    }

    pub fn clearPendingImages(self: *FakeSubmitApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.pending_images.items);
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn releasePendingImages(self: *FakeSubmitApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn captureImageAttachment(self: *FakeSubmitApp, attachment: *types.ImageAttachment) !void {
        self.capture_count += 1;
        if (self.capture_error_id == attachment.id) {
            return self.capture_error orelse error.ImageTooLarge;
        }
        const snapshot_dir = self.snapshot_dir orelse return;
        try image_attachments.captureImageSnapshot(self.alloc, attachment, snapshot_dir);
    }

    pub fn handleCommand(self: *FakeSubmitApp, text: []const u8) !void {
        if (self.last_command) |old| self.alloc.free(old);
        self.last_command = try self.alloc.dupe(u8, text);
        self.command_count += 1;
        self.input_len_at_command = self.input_runtime.edit_state.input.items.len;
        if (std.mem.eql(u8, text, "/images clear")) {
            self.clearPendingImages();
            if (self.fail_command_after_pending_clear) return error.InjectedCommandFailure;
        }
        // Attach through the production handler so routing tests observe real placeholder
        // insertion, id allocation, and snapshot capture rather than a stub.
        const attach_prefix: ?[]const u8 = if (std.mem.startsWith(u8, text, "/image "))
            "/image "
        else if (std.mem.startsWith(u8, text, "/img "))
            "/img "
        else
            null;
        if (attach_prefix) |prefix| {
            try image_commands.Commands(FakeSubmitApp).attachPath(self, text[prefix.len..]);
        }
    }

    pub fn ensurePromptCredential(self: *FakeSubmitApp) !bool {
        self.preflight_count += 1;
        return self.prompt_admitted;
    }

    pub fn enqueuePrompt(self: *FakeSubmitApp, text: []const u8) !bool {
        return self.enqueuePromptWithSkillBindings(text, &.{});
    }

    pub fn enqueuePromptWithSkillBindings(
        self: *FakeSubmitApp,
        text: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !bool {
        if (!self.queue_admitted) return false;
        const prompt_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(prompt_copy);
        const images_copy = try types.dupeImageAttachmentSlice(self.alloc, self.pending_images.items);
        errdefer types.freeImageAttachmentSlice(self.alloc, images_copy);
        if (self.fail_enqueue_after_snapshot) return error.InjectedEnqueueFailure;
        if (self.last_prompt) |old| self.alloc.free(old);
        self.last_prompt = prompt_copy;
        types.freeImageAttachmentSlice(self.alloc, self.last_images);
        self.last_images = images_copy;
        self.clearLastSkillTokens();
        errdefer self.clearLastSkillTokens();
        try self.last_skill_tokens.ensureTotalCapacity(self.alloc, skill_tokens.len);
        for (skill_tokens) |token| {
            const name = try self.alloc.dupe(u8, token.name);
            var appended = false;
            errdefer if (!appended) self.alloc.free(name);
            const path = try self.alloc.dupe(u8, token.path);
            errdefer if (!appended) self.alloc.free(path);
            self.last_skill_tokens.appendAssumeCapacity(.{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
                .name = name,
                .path = path,
            });
            appended = true;
        }
        self.queue_accept_count += 1;
        return true;
    }

    pub fn nextImageId(self: *FakeSubmitApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const FakeSubmitApp) usize {
        return self.next_image_id_counter;
    }

    fn clearLastSkillTokens(self: *FakeSubmitApp) void {
        for (self.last_skill_tokens.items) |token| {
            self.alloc.free(@constCast(token.name));
            self.alloc.free(@constCast(token.path));
        }
        self.last_skill_tokens.clearRetainingCapacity();
    }
};

const FrameSubmitApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    input_runtime: core_input_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id_counter: usize = 1,
    shell: transcript_runtime.TranscriptRuntime,
    metrics: types.Metrics = .{},
    command_seen: bool = false,

    pub fn slashRegistry(_: *const FrameSubmitApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FrameSubmitApp) void {
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
    }

    pub fn clearPendingImages(self: *FrameSubmitApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn handleCommand(self: *FrameSubmitApp, _: []const u8) !void {
        self.command_seen = true;
        try self.writeDomainNotice(.{
            .topic = "system",
            .tone = .information,
            .body = "command result",
        }, true);
    }

    pub fn writeDomainNotice(self: *FrameSubmitApp, notice: types.SemanticNotice, record: bool) !void {
        try self.shell.writeNotice(self.alloc, &self.metrics, notice, record);
    }

    pub fn enqueuePrompt(_: *FrameSubmitApp, _: []const u8) !bool {
        return true;
    }

    pub fn nextImageId(self: *FrameSubmitApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const FrameSubmitApp) usize {
        return self.next_image_id_counter;
    }

    pub fn captureImageAttachment(_: *FrameSubmitApp, _: *types.ImageAttachment) !void {
        return error.MissingImageSnapshot;
    }
};

fn writeTestImage(tmp: *std.testing.TmpDir, name: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
}

fn realTmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
}

fn countTestSnapshotFiles(path: []const u8) !usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file or entry.kind == .sym_link) count += 1;
    }
    return count;
}

fn appendOwnedPendingImage(app: *FakeSubmitApp, id: usize, path: []const u8) !void {
    const path_copy = try app.alloc.dupe(u8, path);
    errdefer app.alloc.free(path_copy);
    const media_type = try app.alloc.dupe(u8, "image/png");
    errdefer app.alloc.free(media_type);
    try app.pending_images.append(app.alloc, .{
        .id = id,
        .path = path_copy,
        .media_type = media_type,
    });
}

fn appendImageTokenForPlaceholderAt(
    app: *FakeSubmitApp,
    id: usize,
    raw_start: usize,
) !void {
    var placeholder_buf: [32]u8 = undefined;
    const placeholder = try image_attachments.formatImagePlaceholder(
        &placeholder_buf,
        id,
    );
    try app.input_runtime.entities.image_tokens.append(app.alloc, .{
        .id = id,
        .span = .{
            .raw_start = raw_start,
            .raw_end = raw_start + placeholder.len,
        },
    });
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.find(u8, haystack[start..], needle)) |relative| {
        count += 1;
        start += relative + needle.len;
    }
    return count;
}

test "composer shortcut line delete handles decoded and raw mutations" {
    const alloc = std.testing.allocator;

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try primeComposerHistoryForTest(RoutingFakeApp, &app, "draft");
        try app.input_runtime.textReplacementState().replace(alloc, "alpha\nleftMIDright\ngamma");
        app.input_runtime.edit_state.cursor = "alpha\nleftMID".len;
        try app.input_runtime.picker.beginModelPickerFlow(alloc, "openai/gpt-5", 3, true, .fast);
        app.input_runtime.picker.file_completion_index = 4;

        _ = try Runtime(RoutingFakeApp).routeResolvedEscapeAction(
            &app,
            .delete_to_line_start,
            .delete_to_line_start,
            null,
            null,
            null,
            false,
            4096,
        );
        try std.testing.expectEqualStrings("alpha\nright\ngamma", app.input_runtime.edit_state.input.items);
        try std.testing.expect(app.shell.render_requests.hasReason(.footer));
        try std.testing.expectEqual(picker_state.ModelPickerStage.model, app.input_runtime.picker.model_picker_stage);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.file_completion_index);
        try std.testing.expectEqual(@as(?usize, 0), app.input_runtime.composer_history.activeIndex());
        try std.testing.expectEqualStrings("draft", app.input_runtime.composer_history.draftText().?);
    }

    {
        var app = try RoutingFakeApp.init(alloc);
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendSlice(alloc, "alpha\nleftMIDright\ngamma");
        app.input_runtime.edit_state.cursor = "alpha\nleftMID".len;

        const action = test_ui_input.shortcutFromControlByte(11);
        try std.testing.expectEqual(@as(?input_action.ShortcutAction, .delete_to_line_end), action);
        try Runtime(RoutingFakeApp).handleByte(&app, 11, 4096, 100);
        try std.testing.expectEqualStrings("alpha\nleftMID\ngamma", app.input_runtime.edit_state.input.items);
        try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    }
}

test "typed composer byte replaces a semantic selection and remains undoable" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try app.input_runtime.textReplacementState().replace(alloc, "(alpha beta)");
    try Runtime(RoutingFakeApp).routeComposerShortcutAction(
        &app,
        .{ .move = .{ .kind = .word_left, .extend_selection = true } },
        4096,
    );
    try Runtime(RoutingFakeApp).handleByte(&app, 'X', 4096, 100);
    try std.testing.expectEqualStrings("(alpha X", app.input_runtime.edit_state.input.items);

    try Runtime(RoutingFakeApp).routeComposerShortcutAction(&app, .undo, 4096);
    try std.testing.expectEqualStrings("(alpha beta)", app.input_runtime.edit_state.input.items);
}

test "composer shortcut line delete preserves no-op picker redraw and metadata state" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    defer app.clearPendingImages();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "[Pasted text #7, 1 line]\n[Image #8]");
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "pasted"),
        .line_count = 1,
    });
    try app.pending_images.append(alloc, .{
        .id = 8,
        .path = try alloc.dupe(u8, "/tmp/8.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    try app.input_runtime.picker.beginModelPickerFlow(alloc, "openai/gpt-5", 3, true, .effort);
    app.input_runtime.edit_state.cursor = 0;

    const line_start_action = test_ui_input.shortcutFromControlByte(21);
    try std.testing.expectEqual(@as(?input_action.ShortcutAction, .delete_to_line_start), line_start_action);
    try Runtime(RoutingFakeApp).handleByte(&app, 21, 4096, 100);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings("openai/gpt-5", app.input_runtime.picker.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);

    app.shell.render_requests.request(.footer);
    _ = try Runtime(RoutingFakeApp).routeResolvedEscapeAction(
        &app,
        .delete_to_line_start,
        .delete_to_line_start,
        null,
        null,
        null,
        false,
        4096,
    );
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, app.input_runtime.picker.model_picker_stage);

    app.shell.render_requests.clearReason(.footer);
    try app.input_runtime.picker.beginModelPickerFlow(alloc, "openai/gpt-5", 4, true, .fast);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    _ = try Runtime(RoutingFakeApp).routeResolvedEscapeAction(
        &app,
        .delete_to_line_end,
        .delete_to_line_end,
        null,
        null,
        null,
        false,
        4096,
    );
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(picker_state.ModelPickerStage.fast, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings("openai/gpt-5", app.input_runtime.picker.model_picker_pending_model.items);
}

test "composer shortcut line delete joins at non-final line end and rejects unknown bytes" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "alpha\nbeta");
    try app.input_runtime.kill_ring.text.appendSlice(alloc, "existing kill");
    app.input_runtime.edit_state.cursor = "alpha".len;

    const action = test_ui_input.shortcutFromControlByte(11);
    try std.testing.expectEqual(@as(?input_action.ShortcutAction, .delete_to_line_end), action);
    try Runtime(RoutingFakeApp).handleByte(&app, 11, 4096, 100);
    try std.testing.expectEqualStrings("\n", app.input_runtime.kill_ring.text.items);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(?input_action.ShortcutAction, null), test_ui_input.shortcutFromControlByte('x'));
    try std.testing.expectEqualStrings("alphabeta", app.input_runtime.edit_state.input.items);
}

test "composer shortcut yank commits fresh image ids only after insertion" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "source.png");
    const source_path = try realTmpPath(alloc, &tmp, "source.png");
    defer alloc.free(source_path);
    const snapshot_dir = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(snapshot_dir);

    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    defer app.clearPendingImages();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "[Image #8]");
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 8,
        .span = .{ .raw_start = 0, .raw_end = "[Image #8]".len },
    });
    var attachment = try image_attachments.loadImageAttachment(alloc, source_path);
    var attachment_owned = true;
    errdefer if (attachment_owned) {
        image_attachments.discardImageAttachment(alloc, attachment);
    };
    attachment.id = 8;
    try image_attachments.captureImageSnapshot(alloc, &attachment, snapshot_dir);
    try app.pending_images.append(alloc, attachment);
    attachment_owned = false;
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    app.next_image_id_counter = 9;

    try Runtime(RoutingFakeApp).handleByte(&app, 21, 4096, 100);
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 9), app.next_image_id_counter);

    try Runtime(RoutingFakeApp).handleByte(&app, 25, 4096, 100);
    try std.testing.expectEqualStrings("[Image #9]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 9), app.pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 10), app.next_image_id_counter);

    try Runtime(RoutingFakeApp).handleByte(&app, 25, 4096, 100);
    try std.testing.expectEqualStrings(
        "[Image #9][Image #10]",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 9), app.pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 10), app.pending_images.items[1].id);
    try std.testing.expectEqual(@as(usize, 11), app.next_image_id_counter);
    try std.testing.expect(
        image_attachments.imageAttachmentsSortedById(app.pending_images.items),
    );

    try Runtime(RoutingFakeApp).handleByte(&app, 21, 4096, 100);
    try app.input_runtime.textReplacementState().replace(alloc, "full");
    try Runtime(RoutingFakeApp).routeComposerShortcutAction(&app, .yank, 4);
    try std.testing.expectEqualStrings("full", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 11), app.next_image_id_counter);
}

test "app_input_runtime submit resolves slash completion through core command specs" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/he");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/help", app.last_command.?);
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime recalls a submitted slash command with history previous" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/he");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings(
        "/help",
        app.input_runtime.composer_history.entryText(0).?,
    );

    try input_completion_runtime.CompletionRuntime(FakeSubmitApp).navigatePromptHistory(
        &app,
        -1,
    );

    try std.testing.expectEqualStrings("/help", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime submit preserves a dismissed slash query" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/he");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    app.input_runtime.picker.dismissInlinePicker(.slash);

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expect(app.last_command == null);
    try std.testing.expectEqualStrings("/he", app.last_prompt.?);
}

test "app_input_runtime routes an unmatched visible slash query as an unknown command" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/foo");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/foo", app.last_command.?);
    try std.testing.expect(app.last_prompt == null);
}

test "app_input_runtime preserves an unmatched slash prompt with arguments" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/output quiet");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/output quiet", app.last_prompt.?);
    try std.testing.expect(app.last_command == null);
}

test "app_input_runtime submits a slash selection with wrapped input" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    app.shell.layout.cols = 8;
    app.shell.layout.content_bottom = 10;

    try app.input_runtime.edit_state.input.appendSlice(alloc, "       /he");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/help", app.last_command.?);
    try std.testing.expect(app.last_prompt == null);
}

test "app_input_runtime clears slash input before command output" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/sk");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/skills", app.last_command.?);
    try std.testing.expectEqual(@as(usize, 0), app.input_len_at_command);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime local commands clear unrelated pending images" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "/help");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/help", app.last_command.?);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
}

test "app_input_runtime routes pending image list locally and preserves its placeholder" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "[Image #1]/images");
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 1,
        .span = .{ .raw_start = 0, .raw_end = "[Image #1]".len },
    });
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    const command = app.last_command orelse return error.TestExpectedImageCommand;
    try std.testing.expectEqualStrings("/images", command);
    try std.testing.expectEqual(@as(usize, "[Image #1]".len), app.input_len_at_command);
    try std.testing.expectEqualStrings("[Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "[Image #1]".len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings(
        "/images",
        app.input_runtime.composer_history.entryText(0).?,
    );
    try std.testing.expect(app.last_prompt == null);
}

test "app_input_runtime routes image-prefixed slash command with reversed pending image order" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try appendOwnedPendingImage(&app, 2, "/tmp/two.png");
    try appendOwnedPendingImage(&app, 1, "/tmp/one.png");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "[Image #2] [Image #1] /images");
    try appendImageTokenForPlaceholderAt(&app, 2, 0);
    try appendImageTokenForPlaceholderAt(&app, 1, "[Image #2] ".len);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/images", app.last_command.?);
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items[1].id);
}

test "app_input_runtime clears pending image placeholders after image command state clears" {
    const alloc = std.testing.allocator;

    for ([_]bool{ false, true }) |fail_after_clear| {
        var app = FakeSubmitApp{
            .alloc = alloc,
            .prompt_admitted = false,
            .fail_command_after_pending_clear = fail_after_clear,
        };
        defer app.deinit();
        try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
        try app.input_runtime.edit_state.input.appendSlice(alloc, "[Image #1]/images clear");
        try app.input_runtime.entities.image_tokens.append(alloc, .{
            .id = 1,
            .span = .{ .raw_start = 0, .raw_end = "[Image #1]".len },
        });
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        if (fail_after_clear) {
            try std.testing.expectError(
                error.InjectedCommandFailure,
                Runtime(FakeSubmitApp).submit(&app, 100),
            );
        } else {
            try Runtime(FakeSubmitApp).submit(&app, 100);
        }

        const command = app.last_command orelse return error.TestExpectedImageCommand;
        try std.testing.expectEqualStrings("/images clear", command);
        try std.testing.expectEqual(@as(usize, "[Image #1]".len), app.input_len_at_command);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
        try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
        try std.testing.expectEqual(
            @as(usize, 1),
            app.input_runtime.composer_history.count(),
        );
        try std.testing.expectEqualStrings(
            "/images clear",
            app.input_runtime.composer_history.entryText(0).?,
        );
        try std.testing.expect(app.last_prompt == null);
    }
}

test "app_input_runtime keeps mixed unknown and non-images attachment suffixes as prompts" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "describe [Image #1]/images",
        "[Image #2]/images",
    };

    for (cases) |input| {
        var app = FakeSubmitApp{ .alloc = alloc };
        defer app.deinit();
        try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
        try app.input_runtime.edit_state.input.appendSlice(alloc, input);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        try Runtime(FakeSubmitApp).submit(&app, 100);

        try std.testing.expect(app.last_command == null);
        try std.testing.expectEqualStrings(input, app.last_prompt.?);
        try std.testing.expectEqual(@as(usize, 1), app.preflight_count);
        try std.testing.expectEqual(@as(usize, 1), app.queue_accept_count);
    }
}

test "app_input_runtime routes registered commands behind pending images" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "[Image #1]/help");
    try appendImageTokenForPlaceholderAt(&app, 1, 0);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("/help", app.last_command.?);
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqualStrings("[Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
}

test "app_input_runtime preserves pending image draft when model selection preflight rejects" {
    const alloc = std.testing.allocator;
    const input = "[Image #1]/model claude";
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    app.next_image_id_counter = 2;
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try appendImageTokenForPlaceholderAt(&app, 1, 0);
    app.input_runtime.edit_state.cursor = input.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preflight_count);
    try std.testing.expect(app.last_command == null);
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqualStrings(input, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(input.len, app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings("/tmp/image.png", app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 2), app.next_image_id_counter);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
}

test "app_input_runtime routes image slash commands before inline attachment extraction" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "slash-image.png");
    const image_path = try realTmpPath(alloc, &tmp, "slash-image.png");
    defer alloc.free(image_path);

    for ([_][]const u8{ "/image", "/img" }) |command| {
        var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
        defer app.deinit();
        const input = try std.fmt.allocPrint(alloc, "{s} {s}", .{ command, image_path });
        defer alloc.free(input);
        try app.input_runtime.edit_state.input.appendSlice(alloc, input);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        try Runtime(FakeSubmitApp).submit(&app, 100);

        const last_command = app.last_command orelse return error.TestExpectedImageCommand;
        try std.testing.expectEqualStrings(input, last_command);
        try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
        try std.testing.expect(app.last_prompt == null);
        try std.testing.expectEqual(@as(usize, 0), app.last_images.len);
    }
}

test "app_input_runtime keeps image-command near misses on the prompt path" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "describe [Image #1]/image",
        "[Image #2]/image",
        "[Image #1]/imagex",
        "[Image #1]/imagine a logo",
        "[Image #1] tell me about /image",
    };

    for (cases) |input| {
        var app = FakeSubmitApp{ .alloc = alloc };
        defer app.deinit();
        try appendOwnedPendingImage(&app, 1, "/tmp/first.png");
        try app.input_runtime.edit_state.input.appendSlice(alloc, input);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        try Runtime(FakeSubmitApp).submit(&app, 100);

        try std.testing.expect(app.last_command == null);
        try std.testing.expectEqual(@as(usize, 0), app.command_count);
        try std.testing.expectEqualStrings(input, app.last_prompt.?);
        try std.testing.expectEqual(@as(usize, 1), app.preflight_count);
        try std.testing.expectEqual(@as(usize, 1), app.queue_accept_count);
    }
}

test "app_input_runtime keeps a repeated image command local while an image is pending" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "second.png");
    const second_path = try realTmpPath(alloc, &tmp, "second.png");
    defer alloc.free(second_path);

    for ([_][]const u8{ "/image", "/img" }) |command| {
        var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false, .queue_admitted = false };
        defer app.deinit();
        try appendOwnedPendingImage(&app, 1, "/tmp/first.png");
        app.next_image_id_counter = 2;
        const input = try std.fmt.allocPrint(alloc, "[Image #1]{s} {s}", .{ command, second_path });
        defer alloc.free(input);
        try app.input_runtime.edit_state.input.appendSlice(alloc, input);
        try appendImageTokenForPlaceholderAt(&app, 1, 0);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        try Runtime(FakeSubmitApp).submit(&app, 100);

        const last_command = app.last_command orelse return error.TestExpectedImageCommand;
        try std.testing.expectEqualStrings(input["[Image #1]".len..], last_command);
        try std.testing.expectEqual(@as(usize, 1), app.command_count);
        try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 1), app.pending_images.items[0].id);
        try std.testing.expectEqual(@as(usize, 2), app.pending_images.items[1].id);
        try std.testing.expectEqualStrings(second_path, app.pending_images.items[1].path);
        try std.testing.expectEqualStrings("[Image #1][Image #2]", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
        try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
        try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
        try std.testing.expectEqualStrings(
            last_command,
            app.input_runtime.composer_history.entryText(0).?,
        );
        try std.testing.expect(app.last_prompt == null);
        try std.testing.expectEqual(@as(usize, 0), app.last_images.len);
        try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
    }
}

test "app_input_runtime attaches three sequential image commands in appearance order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "one.png", "two.png", "three.png" };
    for (names) |name| try writeTestImage(&tmp, name);

    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false, .queue_admitted = false };
    defer app.deinit();

    for (names, 1..) |name, expected_id| {
        const path = try realTmpPath(alloc, &tmp, name);
        defer alloc.free(path);
        const suffix = try std.fmt.allocPrint(alloc, "/image {s}", .{path});
        defer alloc.free(suffix);
        try app.input_runtime.insertionState().insertSlice(alloc, suffix, .preserve);

        try Runtime(FakeSubmitApp).submit(&app, 100);

        try std.testing.expectEqual(expected_id, app.pending_images.items.len);
        try std.testing.expectEqual(expected_id, app.pending_images.items[expected_id - 1].id);
    }

    try std.testing.expectEqualStrings("[Image #1][Image #2][Image #3]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 3), app.command_count);
    try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
    try std.testing.expect(app.last_prompt == null);
}

test "app_input_runtime submits one prompt carrying every image attached by repeated commands" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "second.png");
    const second_path = try realTmpPath(alloc, &tmp, "second.png");
    defer alloc.free(second_path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/first.png");
    app.next_image_id_counter = 2;
    const attach = try std.fmt.allocPrint(alloc, "[Image #1]/image {s}", .{second_path});
    defer alloc.free(attach);
    try app.input_runtime.edit_state.input.appendSlice(alloc, attach);
    try appendImageTokenForPlaceholderAt(&app, 1, 0);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);

    try app.input_runtime.insertionState().insertSlice(alloc, " describe both", .preserve);
    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 1), app.queue_accept_count);
    try std.testing.expectEqual(@as(usize, 1), app.preflight_count);
    try std.testing.expectEqualStrings("[Image #1][Image #2] describe both", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 2), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 1), app.last_images[0].id);
    try std.testing.expectEqual(@as(usize, 2), app.last_images[1].id);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime rejected second image keeps the first pending image and its snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "first.png");
    const first_path = try realTmpPath(alloc, &tmp, "first.png");
    defer alloc.free(first_path);
    const snapshot_dir = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(snapshot_dir);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .prompt_admitted = false,
        .queue_admitted = false,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    const attach_first = try std.fmt.allocPrint(alloc, "/image {s}", .{first_path});
    defer alloc.free(attach_first);
    try app.input_runtime.insertionState().insertSlice(alloc, attach_first, .preserve);
    try Runtime(FakeSubmitApp).submit(&app, 100);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    const first_snapshot = try alloc.dupe(u8, app.pending_images.items[0].snapshot_path.?);
    defer alloc.free(first_snapshot);

    const missing = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(missing);
    const attach_missing = try std.fmt.allocPrint(alloc, "/image {s}/absent.png", .{missing});
    defer alloc.free(attach_missing);
    try app.input_runtime.insertionState().insertSlice(alloc, attach_missing, .preserve);

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("images", app.notice_topic.items);
    try std.testing.expectEqualStrings("image file not found", app.notice_body.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings(first_snapshot, app.pending_images.items[0].snapshot_path.?);
    try std.testing.expectEqualStrings("[Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
    try std.testing.expect(app.last_prompt == null);

    var probe = try std.Io.Dir.openDirAbsolute(std.testing.io, first_snapshot[0..std.mem.lastIndexOfScalar(u8, first_snapshot, '/').?], .{});
    defer probe.close(std.testing.io);
    var snapshot_file = try probe.openFile(std.testing.io, std.fs.path.basename(first_snapshot), .{});
    snapshot_file.close(std.testing.io);
}

test "app_input_runtime repeated image command releases every allocation on failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "second.png");
    const second_path = try realTmpPath(alloc, &tmp, "second.png");
    defer alloc.free(second_path);
    const input = try std.fmt.allocPrint(alloc, "[Image #1]/image {s}", .{second_path});
    defer alloc.free(input);

    var counting = std.testing.FailingAllocator.init(alloc, .{});
    try runRepeatedImageCommand(counting.allocator(), input);

    var fail_index: usize = 0;
    while (fail_index < counting.alloc_index) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        runRepeatedImageCommand(failing.allocator(), input) catch {};
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

fn runRepeatedImageCommand(alloc: std.mem.Allocator, input: []const u8) !void {
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false, .queue_admitted = false };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/first.png");
    app.next_image_id_counter = 2;
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try appendImageTokenForPlaceholderAt(&app, 1, 0);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try Runtime(FakeSubmitApp).submit(&app, 100);
}

test "app_input_runtime slash command records output without a pre-frame terminal write" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "slash-command-frame.log", .{ .read = true });
    defer sink.close(io_mod.getIo());

    var app = FrameSubmitApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/help");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FrameSubmitApp).submit(&app, 100);

    try std.testing.expect(app.command_seen);
    try std.testing.expectEqual(@as(usize, 1), app.shell.entries.items.len);
    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "command result") != null);
    try std.testing.expectEqual(@as(u64, 0), try sink.length(io_mod.getIo()));
}

test "app_input_runtime idle pasted prompt defers frames until worker presentation" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "before [Pasted text #7, 2 lines] after");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "alpha\nbeta"),
        .line_count = 2,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before [Pasted text #7, 2 lines]".len,
        },
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expect(app.last_command == null);
    try std.testing.expectEqualStrings("before alpha\nbeta after", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.submittedPromptTransitionPending());
    try std.testing.expect(app.shell.render_requests.blocksFrameCommit());
}

test "app_input_runtime submit rejects oversized registered paste backing" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, placeholder);
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.alloc(u8, FakeSubmitApp.input_byte_limit + 1),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    });
    @memset(app.input_runtime.entities.pasted_blocks.items[0].text, 'x');
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(?[]u8, null), app.last_prompt);
    try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
    try std.testing.expectEqualStrings(
        "That edit exceeds the local prompt safety limit and was not applied.",
        app.notice_body.items,
    );
    try std.testing.expectEqualStrings(placeholder, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
}

test "app_input_runtime accepted prompt repaints while a turn is active" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc, .stream = .{ .active = true } };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "queued follow-up");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("queued follow-up", app.last_prompt.?);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!app.shell.render_requests.submittedPromptTransitionPending());
    try std.testing.expect(!app.shell.render_requests.blocksFrameCommit());
}

test "app_input_runtime completed presentation tail defers prompt frames until canonical admission" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{
        .alloc = alloc,
        .stream = .{ .active = true },
        .pacer = .{ .completed_assistant_presentation_tail = true },
    };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "paced-tail follow-up");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("paced-tail follow-up", app.last_prompt.?);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.submittedPromptTransitionPending());
    try std.testing.expect(app.shell.render_requests.blocksFrameCommit());
}

test "app_input_runtime blank submit repaints without a worker event" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, " \t ");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!app.shell.render_requests.submittedPromptTransitionPending());
}

test "app_input_runtime idle image-only prompt waits for begin prompt repaint" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(app.shell.render_requests.submittedPromptTransitionPending());
    try std.testing.expect(app.shell.render_requests.blocksFrameCommit());
}

test "app_input_runtime submit preserves direct prompt boundary whitespace" {
    const alloc = std.testing.allocator;
    const input = "    if True:\n        print(\"x\")\n";
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = input.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings(input, app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings(
        input,
        app.input_runtime.composer_history.entryText(0).?,
    );
}

test "app_input_runtime disabled prompt history skips composer recall recording" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    app.prompt_history.disable();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "disabled prompt");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("disabled prompt", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.composer_history.count());

    app.prompt_history.enable();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "enabled prompt");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("enabled prompt", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings(
        "enabled prompt",
        app.input_runtime.composer_history.entryText(0).?,
    );
}

test "app_input_runtime accepted large paste recalls compact and editable" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #7, 1 line]";
    const backing = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(
        alloc,
        "  " ++ placeholder ++ "  ",
    );
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, backing),
        .line_count = 1,
        .span = .{ .raw_start = 2, .raw_end = 2 + placeholder.len },
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);
    try std.testing.expectEqualStrings("  " ++ backing ++ "  ", app.last_prompt.?);

    try input_completion_runtime.CompletionRuntime(FakeSubmitApp).navigatePromptHistory(
        &app,
        -1,
    );

    try std.testing.expectEqualStrings(
        "  " ++ placeholder ++ "  ",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(
        backing,
        app.input_runtime.entities.pasted_blocks.items[0].text,
    );
    try std.testing.expectEqual(
        composer_insertion.InsertResult.inserted,
        try app.input_runtime.insertionState().insertSliceBounded(
            alloc,
            " edit",
            4096,
            .preserve,
        ),
    );
}

test "app_input_runtime recalled image and skill resubmit with fresh provenance" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "history-image.png");
    const image_path = try realTmpPath(alloc, &tmp, "history-image.png");
    defer alloc.free(image_path);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    const input = try std.fmt.allocPrint(alloc, "{s} $review", .{image_path});
    defer alloc.free(input);
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = input.len;
    const skill_start = image_path.len + 1;
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = skill_start,
        .raw_end = skill_start + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/claude/review/SKILL.md"),
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);
    try std.testing.expectEqualStrings("[Image #1] $review", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 1), app.last_skill_tokens.items.len);

    try input_completion_runtime.CompletionRuntime(FakeSubmitApp).navigatePromptHistory(
        &app,
        -1,
    );
    try std.testing.expectEqualStrings("[Image #2] $review", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "/tmp/claude/review/SKILL.md",
        app.input_runtime.entities.skill_tokens.items[0].path,
    );
    try std.testing.expectEqual(@as(usize, 3), app.next_image_id_counter);

    try Runtime(FakeSubmitApp).submit(&app, 100);
    try std.testing.expectEqualStrings("[Image #2] $review", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 2), app.last_images[0].id);
    try std.testing.expectEqual(@as(usize, 1), app.last_skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "/tmp/claude/review/SKILL.md",
        app.last_skill_tokens.items[0].path,
    );

    app.next_image_id_counter = std.math.maxInt(usize);
    try std.testing.expectError(
        error.Overflow,
        input_completion_runtime.CompletionRuntime(FakeSubmitApp).navigatePromptHistory(
            &app,
            -1,
        ),
    );
    try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(?usize, null), app.input_runtime.composer_history.activeIndex());
    try std.testing.expect(app.input_runtime.composer_history.draftView() == null);
    try std.testing.expectEqual(
        std.math.maxInt(usize),
        app.next_image_id_counter,
    );
}

test "app_input_runtime missing auth preserves the complete composer before prompt admission" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(
        alloc,
        "before [Pasted text #7, 1 line] $review [Image #1]",
    );
    app.input_runtime.edit_state.cursor = "before ".len;
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "pasted"),
        .line_count = 1,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before [Pasted text #7, 1 line]".len,
        },
    });
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = "before [Pasted text #7, 1 line] ".len,
        .raw_end = "before [Pasted text #7, 1 line] $review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/review/SKILL.md"),
    });
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 1,
        .span = .{
            .raw_start = "before [Pasted text #7, 1 line] $review ".len,
            .raw_end = "before [Pasted text #7, 1 line] $review [Image #1]".len,
        },
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preflight_count);
    try std.testing.expectEqualStrings(
        "before [Pasted text #7, 1 line] $review [Image #1]",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, "before ".len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.composer_history.count());
    try std.testing.expect(app.last_prompt == null);
}

test "app_input_runtime preflight rejection removes captured inline snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "preflight.png");
    const image_path = try realTmpPath(alloc, &tmp, "preflight.png");
    defer alloc.free(image_path);
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .prompt_admitted = false,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, image_path);
    app.input_runtime.edit_state.cursor = image_path.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings(image_path, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), try countTestSnapshotFiles(snapshot_dir));
}

test "app_input_runtime gates model selection but not model discovery" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        input: []const u8,
        preflight_count: usize,
        command: ?[]const u8,
        remaining_input: []const u8,
    }{
        .{ .input = "/models", .preflight_count = 0, .command = "/models", .remaining_input = "" },
        .{ .input = "/model claude", .preflight_count = 1, .command = null, .remaining_input = "/model claude" },
    };

    for (cases) |case| {
        var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendSlice(alloc, case.input);
        app.input_runtime.edit_state.cursor = case.input.len;

        try Runtime(FakeSubmitApp).submit(&app, 100);

        try std.testing.expectEqual(case.preflight_count, app.preflight_count);
        try std.testing.expectEqualStrings(case.remaining_input, app.input_runtime.edit_state.input.items);
        if (case.command) |command| {
            try std.testing.expectEqualStrings(command, app.last_command.?);
        } else {
            try std.testing.expect(app.last_command == null);
        }
    }
}

test "app_input_runtime keeps bare model status local without auth" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "/model");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 0), app.preflight_count);
    try std.testing.expectEqualStrings("/model", app.last_command.?);
}

test "app_input_runtime queue rejection preserves complete composer state" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc, .queue_admitted = false };
    defer app.deinit();
    const input = "before [Pasted text #7, 1 line] $review [Image #1]";
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = "before ".len;
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "pasted"),
        .line_count = 1,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before [Pasted text #7, 1 line]".len,
        },
    });
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = "before [Pasted text #7, 1 line] ".len,
        .raw_end = "before [Pasted text #7, 1 line] $review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/review/SKILL.md"),
    });
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 1,
        .span = .{
            .raw_start = "before [Pasted text #7, 1 line] $review ".len,
            .raw_end = "before [Pasted text #7, 1 line] $review [Image #1]".len,
        },
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 1), app.preflight_count);
    try std.testing.expectEqualStrings(input, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "before ".len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings("pasted", app.input_runtime.entities.pasted_blocks.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("review", app.input_runtime.entities.skill_tokens.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqualStrings("/tmp/image.png", app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.composer_history.count());
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "app_input_runtime queue rejection removes captured inline snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "rejected.png");
    const image_path = try realTmpPath(alloc, &tmp, "rejected.png");
    defer alloc.free(image_path);
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .queue_admitted = false,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, image_path);
    app.input_runtime.edit_state.cursor = image_path.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings(image_path, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), try countTestSnapshotFiles(snapshot_dir));
}

fn checkAcceptedPromptCleanupAcrossAllocationFailures(failing: *std.testing.FailingAllocator) !void {
    const alloc = failing.allocator();
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "accepted prompt");
    app.input_runtime.edit_state.cursor = "accepted prompt".len;

    Runtime(FakeSubmitApp).submit(&app, 100) catch |err| {
        if (app.queue_accept_count > 0) return error.AcceptedPromptReturnedError;
        return err;
    };

    if (app.queue_accept_count > 0) {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    }
}

test "app_input_runtime accepted prompt cleanup survives allocation failures" {
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try checkAcceptedPromptCleanupAcrossAllocationFailures(&probe);
    const allocation_count = probe.alloc_index;
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        checkAcceptedPromptCleanupAcrossAllocationFailures(&failing) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "app_input_runtime submit projects selected skill spans onto transformed prompt text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "selected-skill.png");

    const image_path = try realTmpPath(alloc, &tmp, "selected-skill.png");
    defer alloc.free(image_path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "pasted"),
        .line_count = 1,
        .span = .{
            .raw_start = "  ".len,
            .raw_end = "  [Pasted text #7, 1 line]".len,
        },
    });

    const prefix = try std.fmt.allocPrint(
        alloc,
        "  [Pasted text #7, 1 line] {s}, ",
        .{image_path},
    );
    defer alloc.free(prefix);
    try app.input_runtime.edit_state.input.appendSlice(alloc, prefix);
    try app.input_runtime.edit_state.input.appendSlice(alloc, "$review");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = prefix.len,
        .raw_end = prefix.len + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/.codex/skills/review/SKILL.md"),
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("pasted [Image #1], $review", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqualStrings(image_path, app.last_images[0].path);
    try std.testing.expectEqual(@as(usize, 1), app.last_skill_tokens.items.len);
    try std.testing.expectEqualStrings("review", app.last_skill_tokens.items[0].name);
    try std.testing.expectEqualStrings("/tmp/.codex/skills/review/SKILL.md", app.last_skill_tokens.items[0].path);
    try std.testing.expectEqual(@as(usize, "pasted [Image #1], ".len), app.last_skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, "pasted [Image #1], $review".len), app.last_skill_tokens.items[0].raw_end);
}

test "app_input_runtime submit preserves side whitespace around semantic entities" {
    const alloc = std.testing.allocator;
    const input = "  [Image #1] $review\n";
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try appendImageTokenForPlaceholderAt(&app, 1, "  ".len);
    const skill_start = "  [Image #1] ".len;
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = skill_start,
        .raw_end = skill_start + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/review/SKILL.md"),
    });
    app.input_runtime.edit_state.cursor = input.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings(input, app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 1), app.last_skill_tokens.items.len);
    try std.testing.expectEqual(skill_start, app.last_skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(
        skill_start + "$review".len,
        app.last_skill_tokens.items[0].raw_end,
    );
}

test "app_input_runtime submit keeps pasted dollar text separate from selected skill span" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "raw $review inside"),
        .line_count = 1,
        .span = .{
            .raw_start = 0,
            .raw_end = "[Pasted text #7, 1 line]".len,
        },
    });

    const prefix = "[Pasted text #7, 1 line] ";
    try app.input_runtime.edit_state.input.appendSlice(alloc, prefix);
    try app.input_runtime.edit_state.input.appendSlice(alloc, "$review");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = prefix.len,
        .raw_end = prefix.len + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/.codex/skills/review/SKILL.md"),
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("raw $review inside $review", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_skill_tokens.items.len);
    try std.testing.expectEqual(@as(usize, "raw $review inside ".len), app.last_skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, "raw $review inside $review".len), app.last_skill_tokens.items[0].raw_end);
}

test "app_input_runtime submit keeps selected skill on its exact marker after image renumbering" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    const image_ids = [_]usize{ 10, 11, 12, 13 };
    const placeholders = [_][]const u8{
        "[Image #10]",
        "[Image #11]",
        "[Image #12]",
        "[Image #13]",
    };
    for (image_ids, placeholders, 0..) |id, placeholder, index| {
        if (index > 0) try app.input_runtime.edit_state.input.append(alloc, ' ');
        const raw_start = app.input_runtime.edit_state.input.items.len;
        try app.input_runtime.edit_state.input.appendSlice(alloc, placeholder);
        try app.input_runtime.entities.image_tokens.append(alloc, .{
            .id = id,
            .span = .{
                .raw_start = raw_start,
                .raw_end = raw_start + placeholder.len,
            },
        });
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/image-{d}.png", .{id});
        try appendOwnedPendingImage(&app, id, path);
    }

    try app.input_runtime.edit_state.input.appendSlice(alloc, " $review$review");
    const selected_start = app.input_runtime.edit_state.input.items.len - "$review$review".len;
    try app.input_runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = selected_start,
        .raw_end = selected_start + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/review/SKILL.md"),
    });
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    const expected_prefix = "[Image #10] [Image #11] [Image #12] [Image #13] ";
    try std.testing.expectEqualStrings(
        expected_prefix ++ "$review$review",
        app.last_prompt.?,
    );
    try std.testing.expectEqual(@as(usize, 1), app.last_skill_tokens.items.len);
    try std.testing.expectEqual(expected_prefix.len, app.last_skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(
        expected_prefix.len + "$review".len,
        app.last_skill_tokens.items[0].raw_end,
    );
}

test "app_input_runtime persists accepted model prompt bytes after enqueue" {
    const alloc = std.testing.allocator;
    const input = "  accepted prompt\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    _ = try app.prompt_history.initialize(alloc, home, true, true);
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    const entries = try app.prompt_history.loadRecent(
        alloc,
        app.workspace_root,
        100,
    );
    defer prompt_history_store.freeLoadedEntries(alloc, entries);
    try std.testing.expectEqualStrings(input, app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(input, entries[0].text);
}

test "app_input_runtime persists expanded pasted prompt bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    _ = try app.prompt_history.initialize(alloc, home, true, true);
    try app.input_runtime.edit_state.input.appendSlice(
        alloc,
        "before [Pasted text #7, 2 lines] after",
    );
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "alpha\nbeta"),
        .line_count = 2,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before [Pasted text #7, 2 lines]".len,
        },
    });

    try Runtime(FakeSubmitApp).submit(&app, 100);

    const entries = try app.prompt_history.loadRecent(
        alloc,
        app.workspace_root,
        100,
    );
    defer prompt_history_store.freeLoadedEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(
        "before alpha\nbeta after",
        entries[0].text,
    );
}

test "app_input_runtime persists slash commands in durable prompt history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    _ = try app.prompt_history.initialize(alloc, home, true, true);
    try app.input_runtime.edit_state.input.appendSlice(alloc, "/help");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    const entries = try app.prompt_history.loadRecent(
        alloc,
        app.workspace_root,
        100,
    );
    defer prompt_history_store.freeLoadedEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("/help", entries[0].text);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings(
        "/help",
        app.input_runtime.composer_history.entryText(0).?,
    );
}

test "app_input_runtime excludes image-bearing prompts from durable history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    _ = try app.prompt_history.initialize(alloc, home, true, true);
    try appendOwnedPendingImage(&app, 1, "/tmp/image.png");
    try app.input_runtime.edit_state.input.appendSlice(
        alloc,
        "describe [Image #1]",
    );
    try appendImageTokenForPlaceholderAt(&app, 1, "describe ".len);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    const entries = try app.prompt_history.loadRecent(
        alloc,
        app.workspace_root,
        100,
    );
    defer prompt_history_store.freeLoadedEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "app_input_runtime submits nonexistent relative and absolute image paths as ordinary text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const absolute_path = try std.fs.path.join(alloc, &.{ root, "missing.png" });
    defer alloc.free(absolute_path);

    for ([_][]const u8{ "fx-missing-image.png", absolute_path }) |missing_path| {
        var app = FakeSubmitApp{ .alloc = alloc };
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendSlice(alloc, missing_path);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        try Runtime(FakeSubmitApp).submit(&app, 100);

        try std.testing.expect(app.last_command == null);
        try std.testing.expectEqualStrings(missing_path, app.last_prompt.?);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    }
}

test "app_input_runtime submits an absolute non-image path as ordinary text" {
    const alloc = std.testing.allocator;
    const input = "/Users/example/project/notes.txt please inspect";
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = input.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expect(app.last_command == null);
    try std.testing.expectEqualStrings(input, app.last_prompt.?);
}

test "app_input_runtime submits an absolute image path instead of treating it as a command" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "absolute.png");

    const image_path = try realTmpPath(alloc, &tmp, "absolute.png");
    defer alloc.free(image_path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, image_path);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expect(app.last_command == null);
    try std.testing.expectEqualStrings("[Image #1]", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqualStrings(image_path, app.last_images[0].path);
}

test "app_input_runtime preserves punctuation after a submitted image path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "punctuated.png");
    const image_path = try realTmpPath(alloc, &tmp, "punctuated.png");
    defer alloc.free(image_path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    const input = try std.fmt.allocPrint(alloc, "inspect {s},", .{image_path});
    defer alloc.free(input);
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = input.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("inspect [Image #1],", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqualStrings(image_path, app.last_images[0].path);
}

test "app_input_runtime keeps a typed image lookalike literal beside a real image" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "real.png");
    const image_path = try realTmpPath(alloc, &tmp, "real.png");
    defer alloc.free(image_path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        image_path,
        FakeSubmitApp.input_byte_limit,
    );
    try app.input_runtime.insertionState().insertSlice(alloc, " [Image #1]", .preserve);

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("[Image #2] [Image #1]", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 2), app.last_images[0].id);
    try std.testing.expectEqualStrings(image_path, app.last_images[0].path);
    try std.testing.expectEqual(@as(usize, 3), app.next_image_id_counter);
}

test "app_input_runtime queues existing and typed images in placeholder order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "typed.png");

    const typed_path = try realTmpPath(alloc, &tmp, "typed.png");
    defer alloc.free(typed_path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 7, "/tmp/existing.png");
    app.next_image_id_counter = 8;
    const input = try std.fmt.allocPrint(alloc, "before [Image #7] then {s}", .{typed_path});
    defer alloc.free(input);
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 7,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before [Image #7]".len,
        },
    });
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("before [Image #7] then [Image #8]", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 2), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 7), app.last_images[0].id);
    try std.testing.expectEqualStrings("/tmp/existing.png", app.last_images[0].path);
    try std.testing.expectEqual(@as(usize, 8), app.last_images[1].id);
    try std.testing.expectEqualStrings(typed_path, app.last_images[1].path);
    try std.testing.expectEqual(@as(usize, 9), app.next_image_id_counter);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime restores composer and pending images after late enqueue failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "typed.png");

    const typed_path = try realTmpPath(alloc, &tmp, "typed.png");
    defer alloc.free(typed_path);

    var app = FakeSubmitApp{ .alloc = alloc, .fail_enqueue_after_snapshot = true };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 7, "/tmp/original-a.png");
    try appendOwnedPendingImage(&app, 11, "/tmp/original-b.png");
    app.next_image_id_counter = 12;
    const input = try std.fmt.allocPrint(alloc, "[Image #11] {s} [Image #7]", .{typed_path});
    defer alloc.free(input);
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 11,
        .span = .{ .raw_start = 0, .raw_end = "[Image #11]".len },
    });
    const last_image_start = input.len - "[Image #7]".len;
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 7,
        .span = .{ .raw_start = last_image_start, .raw_end = input.len },
    });
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try std.testing.expectError(error.InjectedEnqueueFailure, Runtime(FakeSubmitApp).submit(&app, 100));

    try std.testing.expectEqualStrings(input, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings("/tmp/original-a.png", app.pending_images.items[0].path);
    try std.testing.expectEqualStrings("image/png", app.pending_images.items[0].media_type);
    try std.testing.expectEqual(@as(usize, 11), app.pending_images.items[1].id);
    try std.testing.expectEqualStrings("/tmp/original-b.png", app.pending_images.items[1].path);
    try std.testing.expectEqualStrings("image/png", app.pending_images.items[1].media_type);
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqual(@as(usize, 0), app.last_images.len);
}

test "app_input_runtime inline image rejection preserves the draft and rolls back only attempted snapshots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "existing.png");
    try writeTestImage(&tmp, "first.png");
    try writeTestImage(&tmp, "second.png");

    const existing_path = try realTmpPath(alloc, &tmp, "existing.png");
    defer alloc.free(existing_path);
    const first_path = try realTmpPath(alloc, &tmp, "first.png");
    defer alloc.free(first_path);
    const second_path = try realTmpPath(alloc, &tmp, "second.png");
    defer alloc.free(second_path);
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    const input = try std.fmt.allocPrint(
        alloc,
        "draft [Image #7] {s} {s}",
        .{ first_path, second_path },
    );
    defer alloc.free(input);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .next_image_id_counter = 8,
        .capture_error_id = 9,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 7, existing_path);
    try image_attachments.captureImageSnapshot(
        alloc,
        &app.pending_images.items[0],
        snapshot_dir,
    );
    const existing_snapshot_path = try alloc.dupe(u8, app.pending_images.items[0].snapshot_path.?);
    defer alloc.free(existing_snapshot_path);
    const existing_snapshot_digest = try alloc.dupe(u8, app.pending_images.items[0].snapshot_sha256.?);
    defer alloc.free(existing_snapshot_digest);
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try appendImageTokenForPlaceholderAt(&app, 7, "draft ".len);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings(input, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, input.len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings(existing_path, app.pending_images.items[0].path);
    try std.testing.expectEqualStrings(existing_snapshot_path, app.pending_images.items[0].snapshot_path.?);
    try std.testing.expectEqualStrings(existing_snapshot_digest, app.pending_images.items[0].snapshot_sha256.?);
    try std.testing.expectEqual(@as(usize, 2), app.capture_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings("images", app.notice_topic.items);
    try std.testing.expectEqualStrings(
        "image exceeds the 20 MiB limit",
        app.notice_body.items,
    );
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
    try std.testing.expect(app.last_prompt == null);
    try std.testing.expectEqual(@as(usize, 1), try countTestSnapshotFiles(snapshot_dir));

    app.capture_error_id = null;
    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqual(@as(usize, 1), app.queue_accept_count);
    try std.testing.expectEqual(@as(usize, 3), app.last_images.len);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime pasted image rejection preserves the raw paste and existing images" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "rejected.png");

    const path = try realTmpPath(alloc, &tmp, "rejected.png");
    defer alloc.free(path);
    const expected = try std.fmt.allocPrint(alloc, "draft {s}", .{path});
    defer alloc.free(expected);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .next_image_id_counter = 8,
        .capture_error_id = 8,
    };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 7, "/tmp/existing.png");
    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft ");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        path,
        FakeSubmitApp.input_byte_limit,
    );

    try std.testing.expectEqualStrings(expected, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings("/tmp/existing.png", app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings("images", app.notice_topic.items);
    try std.testing.expectEqualStrings(
        "image exceeds the 20 MiB limit",
        app.notice_body.items,
    );

    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        " next",
        FakeSubmitApp.input_byte_limit,
    );
    const expected_after = try std.fmt.allocPrint(alloc, "{s} next", .{expected});
    defer alloc.free(expected_after);
    try std.testing.expectEqualStrings(
        expected_after,
        app.input_runtime.edit_state.input.items,
    );
}

test "app_input_runtime inline capture out of memory propagates without notice or mutation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "oom-inline.png");

    const path = try realTmpPath(alloc, &tmp, "oom-inline.png");
    defer alloc.free(path);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .capture_error_id = 1,
        .capture_error = error.OutOfMemory,
    };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, path);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try std.testing.expectError(
        error.OutOfMemory,
        Runtime(FakeSubmitApp).submit(&app, 100),
    );

    try std.testing.expectEqualStrings(path, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.notice_count);
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
}

const PromptHistoryBusyLockState = struct {
    now_ms: i64 = 0,

    fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
        return false;
    }

    fn now(ctx: ?*anyopaque) i64 {
        const self: *PromptHistoryBusyLockState =
            @ptrCast(@alignCast(ctx.?));
        return self.now_ms;
    }

    fn sleep(ctx: ?*anyopaque, millis: u64) void {
        const self: *PromptHistoryBusyLockState =
            @ptrCast(@alignCast(ctx.?));
        self.now_ms += @intCast(millis);
    }
};

test "app_input_runtime history warning failures never block accepted submission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    _ = try app.prompt_history.initialize(alloc, home, true, true);
    var lock_state = PromptHistoryBusyLockState{};
    app.prompt_history.setStoreLockOpsForTest(.{
        .ctx = &lock_state,
        .try_lock = PromptHistoryBusyLockState.tryLock,
        .now_ms = PromptHistoryBusyLockState.now,
        .sleep_ms = PromptHistoryBusyLockState.sleep,
    });
    app.fail_notice = true;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "still accepted");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Runtime(FakeSubmitApp).submit(&app, 100);

    try std.testing.expectEqualStrings("still accepted", app.last_prompt.?);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "app_input_runtime finalizePastedBlock keeps small text visible" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.paste.buffer.appendSlice(alloc, "one\ntwo\n");

    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, 4096);

    try std.testing.expectEqualStrings("one\ntwo\n", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.next_paste_id);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
}

test "app_input_runtime small paste replaces selection within the existing byte budget" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abcde");
    _ = app.input_runtime.selectionState().begin(1);
    _ = app.input_runtime.selectionState().extend(4);
    try app.input_runtime.paste.buffer.appendSlice(alloc, "XYZ");

    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, 5);

    try std.testing.expectEqualStrings("aXYZe", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.input_runtime.edit_state.selectionRange() == null);
    try std.testing.expect(try app.input_runtime.undoState().undo(alloc));
    try std.testing.expectEqualStrings("abcde", app.input_runtime.edit_state.input.items);
}

test "app_input_runtime bracketed composer paste normalizes CRLF once" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();

    try feedRoutingBytes(&app, "\x1b[200~a\r\nb\rc\n\x1b[201~");

    try std.testing.expectEqualStrings("a\nb\nc\n", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
}

test "app_input_runtime rejects a small paste atomically when it does not fit" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abc");
    try app.input_runtime.paste.buffer.appendSlice(alloc, "XY");

    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, 4);

    try std.testing.expectEqualStrings("abc", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 3), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);
}

test "app_input_runtime paste edit keeps the original history draft reachable" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    try primeComposerHistoryForTest(RoutingFakeApp, &app, "unsent draft");
    try app.input_runtime.textReplacementState().replace(alloc, "recalled prompt");

    input_paste_runtime.PasteEditRuntime(RoutingFakeApp).beginPaste(
        &app,
        RoutingFakeApp.input_byte_limit,
    );
    try app.input_runtime.paste.buffer.appendSlice(alloc, " pasted edit");
    try Runtime(RoutingFakeApp).finishPaste(&app, 4096);

    try std.testing.expectEqualStrings("recalled prompt pasted edit", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, 0), app.input_runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("unsent draft", app.input_runtime.composer_history.draftText().?);
}

test "app_input_runtime small paste opens skills menu for matching dollar token" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "scale",
        .description = "",
        .path = "/tmp/scale/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    try app.input_runtime.paste.buffer.appendSlice(alloc, "use $sca now");

    try Runtime(RoutingFakeApp).finalizePastedBlock(&app, 4096);

    try std.testing.expectEqualStrings("use $sca now", app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuOrigin.paste, app.skills.menu.origin);
    try std.testing.expectEqualStrings("sca", app.skills.menu.query());
    try std.testing.expectEqual(@as(usize, 4), app.skills.menu.target.?.start);
    try std.testing.expectEqual(@as(usize, 8), app.skills.menu.target.?.end);
}

test "app_input_runtime multi dollar paste preserves spaces and opens first matching skill" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "fx-test-strategy",
        .description = "",
        .path = "/tmp/fx-test-strategy/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    const pasted = "Need $fx-test and $notaskill in pasted text";
    try app.input_runtime.paste.buffer.appendSlice(alloc, pasted);

    try Runtime(RoutingFakeApp).finalizePastedBlock(&app, 4096);

    try std.testing.expectEqualStrings(pasted, app.input_runtime.edit_state.input.items);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuOrigin.paste, app.skills.menu.origin);
    try std.testing.expectEqualStrings("fx-test", app.skills.menu.query());
    try std.testing.expectEqual(@as(usize, "Need ".len), app.skills.menu.target.?.start);
    try std.testing.expectEqual(@as(usize, "Need $fx-test".len), app.skills.menu.target.?.end);

    try Runtime(RoutingFakeApp).resolveEscape(&app, false, 1);
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqualStrings(pasted, app.input_runtime.edit_state.input.items);
}

test "app_input_runtime no-match dollar paste remains raw without opening skills menu" {
    const alloc = std.testing.allocator;
    var app = try RoutingFakeApp.init(alloc);
    defer app.deinit();
    const skills = [_]skill_runtime.Skill{.{
        .name = "scale",
        .description = "",
        .path = "/tmp/scale/SKILL.md",
        .source = .global_fx,
    }};
    app.skills.items = @constCast(&skills);
    const pasted = "Need $notaskill in pasted text";
    try app.input_runtime.paste.buffer.appendSlice(alloc, pasted);

    try Runtime(RoutingFakeApp).finalizePastedBlock(&app, 4096);

    try std.testing.expectEqualStrings(pasted, app.input_runtime.edit_state.input.items);
    try std.testing.expect(!app.skills.menu.active);
}

test "app_input_runtime image path paste rejects the complete edit without changing draft state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "a.png");
    try writeTestImage(&tmp, "b.png");

    const path_a = try realTmpPath(alloc, &tmp, "a.png");
    defer alloc.free(path_a);
    const path_b = try realTmpPath(alloc, &tmp, "b.png");
    defer alloc.free(path_b);
    const paste = try std.fmt.allocPrint(alloc, "{s} {s}", .{ path_a, path_b });
    defer alloc.free(paste);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
    app.input_runtime.edit_state.cursor = 2;
    try app.input_runtime.picker.beginModelPickerFlow(alloc, "test/model", 2, true, .fast);
    app.input_runtime.picker.file_completion_index = 4;
    try appendOwnedPendingImage(&app, 3, "/tmp/original.png");
    app.next_image_id_counter = 7;

    var placeholder_buf: [32]u8 = undefined;
    const first_placeholder = try image_attachments.formatImagePlaceholder(&placeholder_buf, 7);
    const limit = app.input_runtime.edit_state.input.items.len + first_placeholder.len + 1;
    try Runtime(FakeSubmitApp).handlePastedBytes(&app, paste, limit);

    try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
    try std.testing.expect(app.input_runtime.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(picker_state.ModelPickerStage.fast, app.input_runtime.picker.model_picker_stage);
    try std.testing.expectEqual(@as(usize, 4), app.input_runtime.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings("/tmp/original.png", app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 7), app.next_image_id_counter);
    try std.testing.expectEqualStrings(
        "That edit exceeds the local prompt safety limit and was not applied.",
        app.notice_body.items,
    );
}

test "app_input_runtime image path paste commits complete text and attachments in order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "a.png");
    try writeTestImage(&tmp, "b.png");

    const path_a = try realTmpPath(alloc, &tmp, "a.png");
    defer alloc.free(path_a);
    const path_b = try realTmpPath(alloc, &tmp, "b.png");
    defer alloc.free(path_b);

    const paste = try std.fmt.allocPrint(
        alloc,
        "before {s} middle {s} after",
        .{ path_a, path_b },
    );
    defer alloc.free(paste);
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeSubmitApp{ .alloc = alloc, .snapshot_dir = snapshot_dir };
    defer app.deinit();

    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        paste,
        FakeSubmitApp.input_byte_limit,
    );

    try std.testing.expectEqualStrings(
        "before [Image #1] middle [Image #2] after",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings(path_a, app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items[1].id);
    try std.testing.expectEqualStrings(path_b, app.pending_images.items[1].path);
    try std.testing.expectEqual(@as(usize, 3), app.next_image_id_counter);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 2), try countTestSnapshotFiles(snapshot_dir));
}

test "app_input_runtime image path paste resolves paths from the workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "photo.png");

    const workspace_root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(workspace_root);
    const expected_path = try realTmpPath(alloc, &tmp, "photo.png");
    defer alloc.free(expected_path);

    var app = FakeSubmitApp{
        .alloc = alloc,
        .workspace_root = workspace_root,
    };
    defer app.deinit();

    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        "photo.png",
        FakeSubmitApp.input_byte_limit,
    );

    try std.testing.expectEqualStrings("[Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqualStrings(expected_path, app.pending_images.items[0].path);
}

test "app_input_runtime image path paste replaces selection as one structured edit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "selection.png");
    const path = try realTmpPath(alloc, &tmp, "selection.png");
    defer alloc.free(path);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abcde");
    _ = app.input_runtime.selectionState().begin(1);
    _ = app.input_runtime.selectionState().extend(4);
    var placeholder_buf: [32]u8 = undefined;
    const placeholder = try image_attachments.formatImagePlaceholder(&placeholder_buf, 1);

    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        path,
        2 + placeholder.len,
    );

    try std.testing.expectEqualStrings("a[Image #1]e", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expect(app.input_runtime.edit_state.selectionRange() == null);
    try std.testing.expect(!(try app.input_runtime.undoState().undo(alloc)));
}

test "app_input_runtime image path paste keeps trailing punctuation outside the badge" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "punctuated.png");
    const path = try realTmpPath(alloc, &tmp, "punctuated.png");
    defer alloc.free(path);
    const paste = try std.fmt.allocPrint(alloc, "{s},", .{path});
    defer alloc.free(paste);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        paste,
        FakeSubmitApp.input_byte_limit,
    );

    try std.testing.expectEqualStrings("[Image #1],", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(
        @as(usize, "[Image #1]".len),
        app.input_runtime.entities.image_tokens.items[0].span.raw_end,
    );
}

fn checkImagePathPasteAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    path: []const u8,
) !void {
    const alloc = failing.allocator();
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    app.next_image_id_counter = 7;

    Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        path,
        FakeSubmitApp.input_byte_limit,
    ) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 7), app.next_image_id_counter);
        return err;
    };

    try std.testing.expectEqualStrings("[Image #7]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 8), app.next_image_id_counter);
}

test "app_input_runtime image path paste stays atomic across allocation failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "oom.png");

    const path = try realTmpPath(std.testing.allocator, &tmp, "oom.png");
    defer std.testing.allocator.free(path);

    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try checkImagePathPasteAllocationFailureIsAtomic(&probe, path);
    const allocation_count = probe.alloc_index;
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        checkImagePathPasteAllocationFailureIsAtomic(&failing, path) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "app_input_runtime oversized image path paste reports rejection without a snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "oversized.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\n");
        try file.setLength(std.testing.io, image_attachments.max_image_bytes + 1);
    }

    const path = try realTmpPath(alloc, &tmp, "oversized.png");
    defer alloc.free(path);
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeSubmitApp{ .alloc = alloc, .snapshot_dir = snapshot_dir };
    defer app.deinit();

    try Runtime(FakeSubmitApp).handlePastedBytes(&app, path, FakeSubmitApp.input_byte_limit);

    try std.testing.expectEqualStrings(path, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("images", app.notice_topic.items);
    try std.testing.expectEqualStrings("image exceeds the 20 MiB limit", app.notice_body.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), try countTestSnapshotFiles(snapshot_dir));
}

test "app_input_runtime repeated image path paste appends keep pending images sorted" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "a.png");
    try writeTestImage(&tmp, "b.png");

    const path_a = try realTmpPath(alloc, &tmp, "a.png");
    defer alloc.free(path_a);
    const path_b = try realTmpPath(alloc, &tmp, "b.png");
    defer alloc.free(path_b);
    const paste = try std.fmt.allocPrint(alloc, "{s} {s}", .{ path_a, path_b });
    defer alloc.free(paste);

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.insertionState().insertByte(alloc, 'a', .clear);
    try Runtime(FakeSubmitApp).handlePastedBytes(&app, paste, FakeSubmitApp.input_byte_limit);

    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
    try std.testing.expect(image_attachments.imageAttachmentsSortedById(app.pending_images.items));
    try std.testing.expect(!(try app.input_runtime.undoState().undo(alloc)));
}

test "app_input_runtime finalizePastedBlock registers large text placeholder atomically" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    const large_paste = "x" ** (paste_blocks.large_paste_char_threshold + 1);

    try app.input_runtime.insertionState().insertByte(alloc, 'a', .clear);
    try app.input_runtime.paste.buffer.appendSlice(alloc, large_paste);

    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, large_paste.len + 1);

    try std.testing.expectEqualStrings("a[Pasted text #1, 1 line]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(large_paste, app.input_runtime.entities.pasted_blocks.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items[0].line_count);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.entities.next_paste_id);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expect(!(try app.input_runtime.undoState().undo(alloc)));
}

test "app_input_runtime large paste replaces selection within its expanded byte budget" {
    const alloc = std.testing.allocator;
    const large_paste = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "abcde");
    _ = app.input_runtime.selectionState().begin(1);
    _ = app.input_runtime.selectionState().extend(4);
    try app.input_runtime.paste.buffer.appendSlice(alloc, large_paste);

    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, 2 + large_paste.len);

    try std.testing.expectEqualStrings("a[Pasted text #1, 1 line]e", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(large_paste, app.input_runtime.entities.pasted_blocks.items[0].text);
    try std.testing.expect(app.input_runtime.edit_state.selectionRange() == null);
    try std.testing.expect(!(try app.input_runtime.undoState().undo(alloc)));
}

test "app_input_runtime rejects a large paste when its backing text does not fit" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    const large_paste = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    try app.input_runtime.textReplacementState().replace(alloc, "draft");
    try app.input_runtime.paste.buffer.appendSlice(alloc, large_paste);

    const limit = "draft".len + large_paste.len - 1;
    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, limit);

    try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.next_paste_id);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone);
}

test "app_input_runtime multiple large pastes share one expanded byte budget" {
    const alloc = std.testing.allocator;
    const large_paste = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.paste.buffer.appendSlice(alloc, large_paste);
    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, large_paste.len * 2 - 1);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);

    try app.input_runtime.paste.buffer.appendSlice(alloc, large_paste);
    try Runtime(FakeSubmitApp).finalizePastedBlock(&app, large_paste.len * 2 - 1);

    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.entities.next_paste_id);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try std.testing.expectEqualStrings("input", app.notice_topic.items);
}

test "app_input_runtime finalizePastedBlock leaves large paste unchanged on allocation failure" {
    const base = std.testing.allocator;
    const large_paste = "x" ** (paste_blocks.large_paste_char_threshold + 1);

    var saw_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var app = FakeSubmitApp{ .alloc = base };
        defer app.deinit();
        try app.input_runtime.paste.buffer.appendSlice(base, large_paste);

        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        app.alloc = failing.allocator();
        if (Runtime(FakeSubmitApp).finalizePastedBlock(&app, 4096)) |_| {
            app.alloc = base;
            if (saw_failure) break;
            continue;
        } else |err| {
            app.alloc = base;
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.pasted_blocks.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.next_paste_id);
            try std.testing.expectEqualStrings(large_paste, app.input_runtime.paste.buffer.items);
        }
    }
    try std.testing.expect(saw_failure);
}

test "app_input_runtime finishPaste leaves no orphan placeholder after late finalization failure" {
    const base = std.testing.allocator;
    const large_paste = "x" ** (paste_blocks.large_paste_char_threshold + 1);

    var saw_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(base, tmp.dir, ".");
        defer base.free(root);
        const trace_path = try std.fs.path.join(base, &.{ root, "late-finalize-failed.log" });
        defer base.free(trace_path);

        debug_trace.resetForTest();
        defer debug_trace.resetForTest();
        try debug_trace.configureForTestWithScopes(base, trace_path, "input");

        var app = FakeSubmitApp{ .alloc = base };
        defer app.deinit();
        app.input_runtime.paste.owner = .composer;
        try app.input_runtime.paste.buffer.appendSlice(base, large_paste);

        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        app.alloc = failing.allocator();
        if (Runtime(FakeSubmitApp).finishPaste(&app, 4096)) |_| {
            app.alloc = base;
            debug_trace.shutdown();
            if (saw_failure) break;
            continue;
        } else |err| {
            app.alloc = base;
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
            try std.testing.expectEqualStrings("", app.input_runtime.edit_state.input.items);
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.pasted_blocks.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.next_paste_id);
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
            debug_trace.shutdown();

            const trace = try readTraceFileForTest(base, trace_path);
            defer base.free(trace);
            const needle = try std.fmt.allocPrint(
                base,
                "composer paste dropped bytes={d} reason=finalize_failed error=OutOfMemory",
                .{large_paste.len},
            );
            defer base.free(needle);
            try std.testing.expect(std.mem.find(u8, trace, needle) != null);
        }
    }
    try std.testing.expect(saw_failure);
}

test "app_input_runtime composer paste finalization failure clears inactive state" {
    const base = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(base, tmp.dir, ".");
    defer base.free(root);
    const trace_path = try std.fs.path.join(base, &.{ root, "finalize-failed-paste.log" });
    defer base.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(base, trace_path, "input");

    var app = FakeSubmitApp{ .alloc = base };
    defer app.deinit();
    app.input_runtime.paste.owner = .composer;
    try app.input_runtime.paste.buffer.appendSlice(base, "pending");

    var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = 0 });
    app.alloc = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, Runtime(FakeSubmitApp).finishPaste(&app, 4096));
    app.alloc = base;

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.buffer.items.len);
    try Runtime(FakeSubmitApp).finishPaste(&app, 4096);
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(base, trace_path);
    defer base.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "composer paste dropped bytes=7 reason=finalize_failed error=OutOfMemory") != null);
}

test "app input bridge installs durable history into the unified input owner" {
    const alloc = std.testing.allocator;
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    const Entry = @import("../session/prompt_history_store.zig").LoadedPromptHistoryEntry;
    var entries = [_]Entry{
        .{ .text = try alloc.dupe(u8, "older") },
        .{ .text = try alloc.dupe(u8, "newer") },
    };
    defer {
        alloc.free(entries[0].text);
        alloc.free(entries[1].text);
    }

    try Runtime(FakeSubmitApp).installPromptHistory(&app, &entries);

    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings("older", app.input_runtime.composer_history.entryText(0).?);
    try std.testing.expectEqualStrings("newer", app.input_runtime.composer_history.entryText(1).?);
}

test "app input bridge loads the most recent durable history in chronological order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var seed = try prompt_history_store.Store.initFromHome(alloc, home);
    defer seed.deinit(alloc);
    for (0..101) |index| {
        var text_buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "prompt-{d}", .{index});
        _ = try seed.append(alloc, @intCast(index), "/tmp/workspace", text);
    }

    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    _ = try app.prompt_history.initialize(alloc, home, true, true);

    try Runtime(FakeSubmitApp).loadAndInstallPromptHistory(&app);

    try std.testing.expectEqual(@as(usize, 100), app.prompt_history.loaded_count);
    try std.testing.expectEqual(@as(usize, 100), app.input_runtime.composer_history.count());
    try std.testing.expectEqualStrings("prompt-1", app.input_runtime.composer_history.entryText(0).?);
    try std.testing.expectEqualStrings("prompt-100", app.input_runtime.composer_history.entryText(99).?);
}

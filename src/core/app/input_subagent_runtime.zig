const std = @import("std");
const input_action = @import("../input/input_action.zig");
const core_input_runtime = @import("../input/runtime.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const input_visual_layout = @import("../../ui/input/visual_layout.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const app_terminal_runtime = @import("app_terminal_runtime.zig");
const input_selection_runtime = @import("input_selection_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const types = @import("../shared/types.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_input = @import("../subagent/input_action.zig");
const input_presentation = @import("../../ui/footer/input_presentation.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const model_menu_presentation = @import("../../ui/footer/model_menu_presentation.zig");
const skills_menu_presentation = @import("../../ui/footer/skills_menu_presentation.zig");
const render_input = @import("../../ui/footer/render_input.zig");

pub fn SubagentRuntime(comptime App: type) type {
    return struct {
        pub fn routeSubagentEscapeAction(
            app: *App,
            action: input_action.Action,
            shortcut: ?input_action.ShortcutAction,
            typed_action: ?subagent_input.Action,
        ) !void {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "handleAction")) return;
            app.input_runtime.vertical_navigation.reset();
            if (comptime @hasField(App, "model_cache") and
                @hasDecl(@TypeOf(app.subagents), "childRouteId") and
                @hasDecl(@TypeOf(app.subagents), "childPresentationView"))
            {
                if (childSkillsMenuActive(app)) {
                    switch (action) {
                        .escape => {
                            closeChildSkillsMenu(app);
                            try childChangedAndRedraw(app);
                        },
                        .history_up, .cursor_up => moveChildSkillsMenu(app, -1),
                        .history_down, .cursor_down => moveChildSkillsMenu(app, 1),
                        .cursor_left,
                        .cursor_right,
                        .home,
                        .end,
                        .word_left,
                        .word_right,
                        .delete_next,
                        .delete_word_left,
                        .delete_word_right,
                        .delete_to_line_start,
                        .delete_to_line_end,
                        .clear_line,
                        => try editChildSkillsQuery(app, action),
                        else => {},
                    }
                    return;
                }
                if (childModelMenuActive(app)) {
                    switch (action) {
                        .escape => {
                            closeChildModelMenu(app);
                            try childChangedAndRedraw(app);
                        },
                        .history_up, .cursor_up => moveChildModelMenu(app, -1),
                        .history_down, .cursor_down => moveChildModelMenu(app, 1),
                        .cursor_left,
                        .cursor_right,
                        .home,
                        .end,
                        .word_left,
                        .word_right,
                        .delete_next,
                        .delete_word_left,
                        .delete_word_right,
                        .delete_to_line_start,
                        .delete_to_line_end,
                        .clear_line,
                        => try editChildModelQuery(app, action),
                        else => {},
                    }
                    return;
                }
            }
            if (shortcut) |composer_action| {
                if (try routeChildComposerShortcut(app, composer_action)) return;
            }
            if (typed_action) |resolved| {
                try handleSubagentAction(app, resolved);
                return;
            }
            if (action == .mouse_pointer) {
                _ = routeChildComposerPointerAction(app, action.mouse_pointer);
            }
        }

        fn routeChildComposerShortcut(
            app: *App,
            shortcut: input_action.ShortcutAction,
        ) !bool {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "childComposerFocused")) {
                return false;
            }
            if (!app.subagents.childComposerFocused()) return false;

            switch (shortcut) {
                .move => |intent| {
                    const child_shell = app.subagents.childConversationRuntime() orelse return false;
                    if (!app.subagents.moveChildInputCursor(
                        intent,
                        child_shell.layout.cols,
                        input_presentation.inputRowLimit(child_shell.layout.content_bottom),
                    )) return false;
                },
                .select_all => {
                    if (comptime !@hasDecl(
                        @TypeOf(app.subagents),
                        "childComposerEditor",
                    )) return false;
                    const editor = app.subagents.childComposerEditor() orelse return false;
                    _ = editor.selectionState().selectAll();
                },
                .copy_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        const view = app.subagents.childPresentationView() orelse return false;
                        if (input_selection_runtime.copySelection(
                            &view.editor.edit_state,
                            app.clipboard(),
                        ) == .copy_failed) {
                            debug_trace.logf(
                                "subagent",
                                "child selection copy preserved reason=clipboard_copy_failed",
                                .{},
                            );
                        }
                    }
                },
                .cut_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        const editor = app.subagents.childComposerEditor() orelse return false;
                        switch (input_selection_runtime.cutSelection(
                            app.alloc,
                            editor.selectionState(),
                            null,
                            app.clipboard(),
                        )) {
                            .cut => app.subagents.commitChildEditorEdit(app.alloc),
                            .copy_failed => debug_trace.logf(
                                "subagent",
                                "child selection cut preserved reason=clipboard_copy_failed",
                                .{},
                            ),
                            .delete_failed => debug_trace.logf(
                                "subagent",
                                "child selection cut delete skipped reason=delete_failed",
                                .{},
                            ),
                            .inactive, .copied => {},
                        }
                    }
                },
                .delete_forward => try handleSubagentAction(app, .delete_next),
                .delete_word_left => try handleSubagentAction(app, .delete_word_left),
                .delete_whitespace_word_left => {
                    const editor = app.subagents.childComposerEditor() orelse return false;
                    if (try editor.killRingState(null).delete(
                        app.alloc,
                        .whitespace_word_left,
                    )) {
                        app.subagents.commitChildEditorEdit(app.alloc);
                    }
                },
                .delete_word_right => try handleSubagentAction(app, .delete_word_right),
                .delete_to_line_start => try handleSubagentAction(app, .delete_to_line_start),
                .delete_to_line_end => try handleSubagentAction(app, .delete_to_line_end),
                .insert_newline => try handleSubagentAction(app, .insert_newline),
                .undo => {
                    const editor = app.subagents.childComposerEditor() orelse return false;
                    if (try editor.undoState().undo(app.alloc)) {
                        app.subagents.commitChildEditorEdit(app.alloc);
                    }
                },
                .redo => {
                    const editor = app.subagents.childComposerEditor() orelse return false;
                    if (try editor.undoState().redo(app.alloc)) {
                        app.subagents.commitChildEditorEdit(app.alloc);
                    }
                },
                .yank => {
                    const editor = app.subagents.childComposerEditor() orelse return false;
                    switch (try editor.killRingState(null).yank(
                        app.alloc,
                        1,
                        subagent_domain.max_message_bytes,
                    )) {
                        .inserted => app.subagents.commitChildEditorEdit(app.alloc),
                        .inactive, .limit_exceeded => {},
                    }
                },
                .delete_backward,
                .history_previous,
                .history_next,
                .redraw,
                => return false,
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
            return true;
        }

        fn routeChildComposerPointerAction(
            app: *App,
            pointer: input_action.MousePointer,
        ) bool {
            if (pointer.shift) return false;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "childComposerEditor",
            )) return false;
            const editor = app.subagents.childComposerEditor() orelse return false;
            const child_shell = app.subagents.childConversationRuntime() orelse return false;
            if (!child_shell.footer_viewport.has_frame) return false;

            const prefix_cells: u16 = @intCast(input_visual_layout.inputPrefix(0).cell_width);
            const position = child_shell.footer_viewport.geometry.inputPointerPosition(
                pointer.row,
                pointer.column,
                prefix_cells,
            ) orelse {
                if (pointer.kind == .release and
                    editor.edit_state.selection_anchor != null)
                {
                    editor.selectionState().finish();
                    requestChildFooterFrame(app);
                    return true;
                }
                return false;
            };
            const point = input_visual_layout.cursorPointAtPosition(.{
                .input = editor.edit_state.input.items,
                .cursor = editor.edit_state.cursor,
                .terminal_cols = child_shell.layout.cols,
                .pasted_blocks = editor.entities.pasted_blocks.items,
                .skill_tokens = editor.entities.skill_tokens.items,
            }, position.row_index, position.content_column) orelse return false;

            const changed = switch (pointer.kind) {
                .press => editor.selectionState().begin(point.raw_offset),
                .drag => editor.selectionState().extend(point.raw_offset),
                .release => blk: {
                    if (editor.edit_state.selection_anchor == null) break :blk false;
                    _ = editor.selectionState().extend(point.raw_offset);
                    editor.selectionState().finish();
                    break :blk true;
                },
            };
            if (changed) requestChildFooterFrame(app);
            return changed;
        }

        fn requestChildFooterFrame(app: *App) void {
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .footer,
            );
        }

        pub fn handleSubagentRawInput(
            app: *App,
            raw: input_action.RawTerminalInput,
        ) !void {
            const byte = raw.byte;
            if (comptime @hasField(App, "model_cache") and
                @hasDecl(@TypeOf(app.subagents), "childRouteId") and
                @hasDecl(@TypeOf(app.subagents), "childPresentationView"))
            {
                if (childSkillsMenuActive(app) and
                    try handleChildSkillsMenuByte(app, byte))
                {
                    return;
                }
                if (childModelMenuActive(app) and
                    try handleChildModelMenuByte(app, byte))
                {
                    return;
                }
            }
            if (raw.composer_shortcut) |shortcut| {
                if (try routeChildComposerShortcut(app, shortcut)) return;
            }
            if (raw.subagent_action) |action| {
                try handleSubagentAction(app, action);
                return;
            }
            if (raw.composer_shortcut != null) return;
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
            const result = if (comptime @hasDecl(@TypeOf(app.subagents), "handleKeyWithMainApproval"))
                try app.subagents.handleKeyWithMainApproval(app.alloc, byte, mainApprovalId(app))
            else
                try app.subagents.handleKey(app.alloc, byte);
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
            switch (result) {
                .acknowledge => try acknowledgeAndRedraw(app),
                .none => {},
                .exit_app => exitApp(app),
                .close_manager => try closeSubagentManager(app),
                .page_changed => try refreshPageAndRedraw(app),
                .child_changed => try childChangedAndRedraw(app),
                .load_older_history => try loadOlderHistoryAndRedraw(app),
                .refresh_newest_history => try refreshNewestHistoryAndRedraw(app),
                .submit_child_message => try submitChildMessageAndRedraw(app),
                .load_attach_candidates => try loadAttachCandidatesAndRedraw(app, false),
                .load_more_attach_candidates => try loadAttachCandidatesAndRedraw(app, true),
                .submit_manager_mutation => try submitManagerMutationAndRedraw(app),
                .resolve_child_approval => try resolveChildApprovalAndRedraw(app),
                .open_terminal => try openSelectedTerminal(app),
                .redraw => try redraw(app),
            }
        }

        fn handleSubagentAction(app: *App, action: subagent_input.Action) !void {
            const result = if (comptime @hasDecl(@TypeOf(app.subagents), "handleActionWithMainApproval"))
                try app.subagents.handleActionWithMainApproval(app.alloc, action, mainApprovalId(app))
            else
                try app.subagents.handleAction(app.alloc, action);
            switch (result) {
                .acknowledge => try acknowledgeAndRedraw(app),
                .none => {},
                .exit_app => exitApp(app),
                .close_manager => try closeSubagentManager(app),
                .page_changed => try refreshPageAndRedraw(app),
                .child_changed => try childChangedAndRedraw(app),
                .load_older_history => try loadOlderHistoryAndRedraw(app),
                .refresh_newest_history => try refreshNewestHistoryAndRedraw(app),
                .submit_child_message => try submitChildMessageAndRedraw(app),
                .load_attach_candidates => try loadAttachCandidatesAndRedraw(app, false),
                .load_more_attach_candidates => try loadAttachCandidatesAndRedraw(app, true),
                .submit_manager_mutation => try submitManagerMutationAndRedraw(app),
                .resolve_child_approval => try resolveChildApprovalAndRedraw(app),
                .open_terminal => try openSelectedTerminal(app),
                .redraw => try redraw(app),
            }
        }

        fn openSelectedTerminal(app: *App) !void {
            requestSelectedTerminalOpen(app);
            try redraw(app);
        }

        fn requestSelectedTerminalOpen(app: *App) void {
            if (comptime @hasDecl(@TypeOf(app.subagents), "selectedTerminalId") and
                @hasDecl(App, "requestTerminalOpen"))
            {
                const session_id = app.subagents.selectedTerminalId() orelse return;
                switch (app.requestTerminalOpen(session_id)) {
                    .accepted, .occupied, .rejected => {},
                }
            }
        }

        fn exitApp(app: *App) void {
            app_session_runtime.Runtime(App).requestResumeHandoff(app);
            app.should_exit = true;
        }

        fn redraw(app: *App) !void {
            if (app.subagents.isViewActive()) {
                app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                    app,
                    .subagent_panel,
                );
                app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                    app,
                    .footer,
                );
            } else {
                try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
            }
        }

        fn refreshPageAndRedraw(app: *App) !void {
            if (comptime @hasDecl(@TypeOf(app.subagents), "pageCursor")) {
                try app_render_runtime.Runtime(App).refreshSubagentManager(app, true);
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn acknowledgeAndRedraw(app: *App) !void {
            if (comptime @hasDecl(App, "acknowledgeSubagentManagerSelection")) {
                try app.acknowledgeSubagentManagerSelection();
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn childChangedAndRedraw(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "childRouteId")) {
                app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                    app,
                    .subagent_panel,
                );
                return;
            }
            if (app.subagents.childRouteId() != null) {
                try app_render_runtime.Runtime(App).refreshChildChat(
                    app,
                    null,
                    false,
                    true,
                );
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn loadOlderHistoryAndRedraw(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "olderHistoryCursor")) {
                app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                    app,
                    .subagent_panel,
                );
                return;
            }
            const cursor = app.subagents.olderHistoryCursor() orelse return;
            try app_render_runtime.Runtime(App).refreshChildChat(
                app,
                cursor,
                true,
                false,
            );
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn refreshNewestHistoryAndRedraw(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "childRouteId")) {
                app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                    app,
                    .subagent_panel,
                );
                return;
            }
            try app_render_runtime.Runtime(App).refreshChildChat(
                app,
                null,
                false,
                true,
            );
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn submitChildMessageAndRedraw(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.subagents), "prepareSubmission")) {
                app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                    app,
                    .subagent_panel,
                );
                return;
            }
            if (comptime @hasDecl(@TypeOf(app.subagents), "childPresentationView") and
                @hasDecl(App, "slashRegistry"))
            {
                if (app.subagents.childPresentationView()) |view| {
                    switch (classifyChildSubmission(
                        app.slashRegistry(),
                        view.editor.edit_state.input.items,
                    )) {
                        .exit_app => {
                            exitApp(app);
                            return;
                        },
                        .open_models => {
                            app.subagents.clearChildComposer(app.alloc);
                            if (comptime @hasField(App, "model_cache")) {
                                if (comptime @hasDecl(App, "ensureModelCache")) {
                                    app.ensureModelCache();
                                }
                                try app.model_cache.openMenu();
                            }
                            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                                app,
                                .subagent_panel,
                            );
                            return;
                        },
                        .open_skills => {
                            app.subagents.clearChildComposer(app.alloc);
                            if (comptime @hasField(App, "skills")) {
                                app.skills.openMenuWithQuery(
                                    .command,
                                    null,
                                    "",
                                );
                            }
                            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                                app,
                                .subagent_panel,
                            );
                            return;
                        },
                        .message => {},
                    }
                }
            }
            try app_render_runtime.Runtime(App).submitChildMessage(app);
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn loadAttachCandidatesAndRedraw(app: *App, append: bool) !void {
            if (comptime @hasDecl(@TypeOf(app.subagents), "installAttachPage")) {
                try app_render_runtime.Runtime(App).loadSubagentAttachCandidates(app, append);
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn submitManagerMutationAndRedraw(app: *App) !void {
            if (comptime @hasDecl(@TypeOf(app.subagents), "prepareManagerMutation")) {
                try app_render_runtime.Runtime(App).submitSubagentManagerMutation(app);
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn resolveChildApprovalAndRedraw(app: *App) !void {
            if (comptime @hasDecl(@TypeOf(app.subagents), "prepareApprovalResolution")) {
                try app_render_runtime.Runtime(App).resolveSubagentApproval(app);
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn mainApprovalId(app: *const App) ?u64 {
            if (comptime !@hasField(App, "approval_prompt")) return null;
            const request = app.approval_prompt.request orelse return null;
            return request.id;
        }

        pub fn toggleSubagentView(app: *App) !void {
            if (comptime @hasDecl(App, "writeSubagentSnapshot")) {
                try app.writeSubagentSnapshot();
            } else {
                try app_render_runtime.Runtime(App).toggleSubagentView(app);
            }
        }

        fn closeSubagentManager(app: *App) !void {
            if (comptime @hasDecl(App, "acknowledgeVisibleSubagentChildBeforeClose")) {
                app.acknowledgeVisibleSubagentChildBeforeClose();
            }
            if (comptime @hasField(App, "skills")) {
                if (childSkillsMenuActive(app)) app.skills.closeMenu();
            }
            if (comptime @hasField(App, "model_cache")) {
                if (childModelMenuActive(app)) app.model_cache.closeMenu();
            }
            try toggleSubagentView(app);
        }

        fn childModelMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache") or
                !@hasDecl(@TypeOf(app.subagents), "childRouteId"))
            {
                return false;
            }
            return app.subagents.childRouteId() != null and
                app.model_cache.menu.active;
        }

        fn closeChildModelMenu(app: *App) void {
            app.model_cache.closeMenu();
            app.subagents.clearChildComposer(app.alloc);
        }

        fn childSkillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills") or
                !@hasDecl(@TypeOf(app.subagents), "childRouteId"))
            {
                return false;
            }
            return app.subagents.childRouteId() != null and
                app.skills.menu.active;
        }

        fn closeChildSkillsMenu(app: *App) void {
            app.skills.closeMenu();
            app.subagents.clearChildComposer(app.alloc);
        }

        fn handleChildSkillsMenuByte(app: *App, byte: u8) !bool {
            switch (byte) {
                '\r' => {
                    const skill = app.skills.selectedMenuSkill() orelse {
                        app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                            app,
                            .subagent_panel,
                        );
                        return true;
                    };
                    _ = try app.subagents.bindSelectedChildSkill(
                        app.alloc,
                        skill.name,
                        skill.path,
                        skill_runtime.skillDisplaySource(app.skills.items, skill),
                    );
                    app.skills.closeMenu();
                },
                '\t' => _ = app.skills.moveMenuSourceFilter(1),
                10 => moveChildSkillsMenu(app, 1),
                11 => moveChildSkillsMenu(app, -1),
                0x7f, 8 => {
                    _ = try app.subagents.handleKey(app.alloc, byte);
                    syncChildSkillsQuery(app);
                },
                else => {
                    if (byte < 0x20) return false;
                    _ = try app.subagents.handleKey(app.alloc, byte);
                    syncChildSkillsQuery(app);
                },
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
            return true;
        }

        fn handleChildModelMenuByte(app: *App, byte: u8) !bool {
            switch (byte) {
                '\r' => {
                    const selected = (try app.model_cache.menu.selectedModelAlloc(
                        app.alloc,
                    )) orelse {
                        app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                            app,
                            .subagent_panel,
                        );
                        return true;
                    };
                    defer app.alloc.free(selected);
                    app.model_cache.closeMenu();
                    _ = try app.subagents.openSelectedChildModelConfiguration(
                        app.alloc,
                        selected,
                    );
                },
                '\t' => {
                    _ = app.model_cache.menu.moveProvider(1);
                },
                10 => moveChildModelMenu(app, 1),
                11 => moveChildModelMenu(app, -1),
                0x7f, 8 => {
                    _ = try app.subagents.handleKey(app.alloc, byte);
                    syncChildModelQuery(app);
                },
                else => {
                    if (byte < 0x20) return false;
                    _ = try app.subagents.handleKey(app.alloc, byte);
                    syncChildModelQuery(app);
                },
            }
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
            return true;
        }

        fn editChildModelQuery(
            app: *App,
            action: input_action.Action,
        ) !void {
            const mapped: subagent_input.Action =
                switch (action) {
                    .cursor_left => .left,
                    .cursor_right => .right,
                    .home => .home,
                    .end => .end,
                    .word_left => .word_left,
                    .word_right => .word_right,
                    .delete_next => .delete_next,
                    .delete_word_left => .delete_word_left,
                    .delete_word_right => .delete_word_right,
                    .delete_to_line_start => .delete_to_line_start,
                    .delete_to_line_end => .delete_to_line_end,
                    .clear_line => .clear_line,
                    else => return,
                };
            _ = try app.subagents.handleAction(app.alloc, mapped);
            syncChildModelQuery(app);
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn editChildSkillsQuery(
            app: *App,
            action: input_action.Action,
        ) !void {
            const mapped: subagent_input.Action =
                switch (action) {
                    .cursor_left => .left,
                    .cursor_right => .right,
                    .home => .home,
                    .end => .end,
                    .word_left => .word_left,
                    .word_right => .word_right,
                    .delete_next => .delete_next,
                    .delete_word_left => .delete_word_left,
                    .delete_word_right => .delete_word_right,
                    .delete_to_line_start => .delete_to_line_start,
                    .delete_to_line_end => .delete_to_line_end,
                    .clear_line => .clear_line,
                    else => return,
                };
            _ = try app.subagents.handleAction(app.alloc, mapped);
            syncChildSkillsQuery(app);
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn syncChildModelQuery(app: *App) void {
            const view = app.subagents.childPresentationView() orelse return;
            app.model_cache.setMenuQuery(view.editor.edit_state.input.items);
        }

        fn syncChildSkillsQuery(app: *App) void {
            const view = app.subagents.childPresentationView() orelse return;
            app.skills.menu.setQuery(view.editor.edit_state.input.items);
            app.skills.menu.clamp(app.skills.items);
        }

        fn moveChildModelMenu(app: *App, delta: i32) void {
            const view = app.subagents.childPresentationView() orelse return;
            const scan = ui_input.scanInputCursorVertical(
                view.editor,
                .down,
                app.shell.layout.cols,
                &.{},
            );
            const capped = input_presentation.cappedInputRows(
                scan.total_rows,
                app.shell.layout.content_bottom,
                true,
            );
            const row_budget = picker_presentation.inlinePickerRowBudgetCapped(
                app.shell.layout.rows,
                capped.input_extra,
                0,
                model_menu_presentation.max_inline_rows,
            );
            _ = app.model_cache.menu.moveVisibleItems(
                delta,
                model_menu_presentation.visibleNavigationItemsForBudget(
                    render_input.modelMenuProjection(&app.model_cache),
                    row_budget,
                ),
            );
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }

        fn moveChildSkillsMenu(app: *App, delta: i32) void {
            const view = app.subagents.childPresentationView() orelse return;
            const scan = ui_input.scanInputCursorVertical(
                view.editor,
                .down,
                app.shell.layout.cols,
                &.{},
            );
            const capped = input_presentation.cappedInputRows(
                scan.total_rows,
                app.shell.layout.content_bottom,
                true,
            );
            const row_budget = picker_presentation.inlinePickerRowBudget(
                app.shell.layout.rows,
                capped.input_extra,
                0,
            );
            _ = app.skills.moveMenuSelectionVisibleRows(
                delta,
                skills_menu_presentation.inlineVisibleNavigationRowsForBudget(
                    render_input.skillsMenuProjection(&app.skills),
                    row_budget,
                ),
            );
            app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                app,
                .subagent_panel,
            );
        }
    };
}

const ChildSubmission = enum {
    message,
    exit_app,
    open_models,
    open_skills,
};

fn classifyChildSubmission(
    registry: command_specs.SlashRegistry,
    submission: []const u8,
) ChildSubmission {
    const command = std.mem.trimStart(u8, submission, " \t\r\n");
    if (command_specs.matchesSlashExact(registry, command, .quit)) {
        return .exit_app;
    }
    if (command_specs.matchesSlashExact(registry, command, .model)) {
        return .open_models;
    }
    if (command_specs.matchesSlashExact(registry, command, .skills)) {
        return .open_skills;
    }
    return .message;
}

const TestSubagents = struct {
    pub fn handleKey(
        _: *TestSubagents,
        _: std.mem.Allocator,
        _: u8,
    ) !subagent_input.Command {
        return .none;
    }

    pub fn handleAction(
        _: *TestSubagents,
        _: std.mem.Allocator,
        action: subagent_input.Action,
    ) !subagent_input.Command {
        return if (action == .ctrl_c) .exit_app else .none;
    }

    pub fn isViewActive(_: *const TestSubagents) bool {
        return true;
    }
};

const TestApp = struct {
    alloc: std.mem.Allocator = std.testing.allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    subagents: TestSubagents = .{},
    session_persistence: app_session_runtime.Persistence = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    metrics: types.Metrics = .{},
    should_exit: bool = false,

    pub fn writeSubagentSnapshot(_: *TestApp) !void {}
};

const CatalogTestSubagents = struct {
    composer_clear_count: usize = 0,

    pub fn childRouteId(_: *const CatalogTestSubagents) ?[]const u8 {
        return "child";
    }

    pub fn childPresentationView(_: *const CatalogTestSubagents) ?u8 {
        return null;
    }

    pub fn clearChildComposer(self: *CatalogTestSubagents, _: std.mem.Allocator) void {
        self.composer_clear_count += 1;
    }
};

const CatalogTestState = struct {
    menu: struct { active: bool = true } = .{},

    pub fn closeMenu(self: *CatalogTestState) void {
        self.menu.active = false;
    }
};

const CatalogTestApp = struct {
    alloc: std.mem.Allocator = std.testing.allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    subagents: CatalogTestSubagents = .{},
    model_cache: CatalogTestState = .{},
    skills: CatalogTestState = .{},
    session_persistence: app_session_runtime.Persistence = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    metrics: types.Metrics = .{},
    snapshot_writes: usize = 0,

    pub fn writeSubagentSnapshot(self: *CatalogTestApp) !void {
        self.snapshot_writes += 1;
    }
};

test "subagent Ctrl-C requests resume handoff before exit" {
    var app = TestApp{};
    defer {
        app.session_persistence.deinit(std.testing.allocator);
        app.shell.deinit(std.testing.allocator);
    }

    try SubagentRuntime(TestApp).handleSubagentRawInput(&app, .{
        .byte = 3,
        .subagent_action = .ctrl_c,
    });

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(
        app_session_runtime.ResumeHandoffIntent.requested,
        app.session_persistence.resume_handoff_intent,
    );
}

test "manager close dismisses child catalog menus" {
    var app = CatalogTestApp{};
    defer {
        app.session_persistence.deinit(std.testing.allocator);
        app.shell.deinit(std.testing.allocator);
    }

    try SubagentRuntime(CatalogTestApp).closeSubagentManager(&app);

    try std.testing.expect(!app.model_cache.menu.active);
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expectEqual(@as(usize, 1), app.snapshot_writes);
}

test "child catalog escape closes the menu and clears its temporary query" {
    var skills_app = CatalogTestApp{};
    defer {
        skills_app.session_persistence.deinit(std.testing.allocator);
        skills_app.shell.deinit(std.testing.allocator);
    }
    SubagentRuntime(CatalogTestApp).closeChildSkillsMenu(&skills_app);
    try std.testing.expect(!skills_app.skills.menu.active);
    try std.testing.expectEqual(@as(usize, 1), skills_app.subagents.composer_clear_count);

    var models_app = CatalogTestApp{};
    defer {
        models_app.session_persistence.deinit(std.testing.allocator);
        models_app.shell.deinit(std.testing.allocator);
    }
    models_app.skills.menu.active = false;
    SubagentRuntime(CatalogTestApp).closeChildModelMenu(&models_app);
    try std.testing.expect(!models_app.model_cache.menu.active);
    try std.testing.expectEqual(@as(usize, 1), models_app.subagents.composer_clear_count);
}

test "child exit submission recognizes only canonical local exit commands" {
    const specs = [_]command_specs.SlashSpec{
        .{
            .kind = .quit,
            .command = "/quit",
            .aliases = &.{"/exit"},
        },
        .{
            .kind = .model,
            .command = "/model",
        },
        .{
            .kind = .skills,
            .command = "/skills",
        },
    };
    const registry = command_specs.SlashRegistry{ .commands = specs[0..] };

    try std.testing.expectEqual(.exit_app, classifyChildSubmission(registry, "/quit"));
    try std.testing.expectEqual(.exit_app, classifyChildSubmission(registry, "  /exit\t"));
    try std.testing.expectEqual(.message, classifyChildSubmission(registry, "/quit now"));
    try std.testing.expectEqual(.message, classifyChildSubmission(registry, "explain /quit"));
    try std.testing.expectEqual(.open_models, classifyChildSubmission(registry, "/model"));
    try std.testing.expectEqual(.message, classifyChildSubmission(registry, "/model explicit-id"));
    try std.testing.expectEqual(.message, classifyChildSubmission(registry, "/models"));
    try std.testing.expectEqual(.open_skills, classifyChildSubmission(registry, "/skills"));
    try std.testing.expectEqual(.message, classifyChildSubmission(registry, "/skills now"));
}

const TerminalOpenTestSubagents = struct {
    selected_id: []const u8 = "terminal-a",
    manager_active: bool = true,

    fn selectedTerminalId(self: *const TerminalOpenTestSubagents) ?[]const u8 {
        return self.selected_id;
    }
};

const TerminalOpenTestApp = struct {
    subagents: TerminalOpenTestSubagents = .{},
    open_result: app_terminal_runtime.OpenRequestResult = .occupied,
    requested_id: ?[]const u8 = null,
    inline_draft: []const u8 = "preserved inline draft",
    inline_cursor: usize = 9,

    fn requestTerminalOpen(
        self: *TerminalOpenTestApp,
        session_id: []const u8,
    ) app_terminal_runtime.OpenRequestResult {
        self.requested_id = session_id;
        return self.open_result;
    }
};

test "manager handles occupied terminal open without losing selection or inline draft" {
    var app = TerminalOpenTestApp{};

    SubagentRuntime(TerminalOpenTestApp).requestSelectedTerminalOpen(&app);

    try std.testing.expect(app.subagents.manager_active);
    try std.testing.expectEqualStrings("terminal-a", app.subagents.selected_id);
    try std.testing.expectEqualStrings("terminal-a", app.requested_id.?);
    try std.testing.expectEqualStrings("preserved inline draft", app.inline_draft);
    try std.testing.expectEqual(@as(usize, 9), app.inline_cursor);
}

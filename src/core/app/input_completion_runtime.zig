const std = @import("std");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const edit_contract = @import("../input/editor_state.zig");
const file_picker_path = @import("../input/file_picker_path.zig");
const horizontal_navigation = @import("../input/horizontal_navigation.zig");
const picker_state = @import("../input/picker_state.zig");
const core_input_runtime = @import("../input/runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const list_window = @import("../shared/list_window.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const session_commands = @import("../session/session_commands.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const file_index = @import("../workspace/file_index.zig");
const app_workspace_runtime = @import("app_workspace_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_commands = @import("app_commands.zig");
const provider_runtime = @import("provider_runtime.zig");
const provider_picker_runtime = @import("provider_picker_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");
const types = @import("../shared/types.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const input_presentation = @import("../../ui/footer/input_presentation.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const skills_menu_presentation = @import("../../ui/footer/skills_menu_presentation.zig");
const model_menu_presentation = @import("../../ui/footer/model_menu_presentation.zig");
const resume_menu_presentation = @import("../../ui/footer/resume_menu_presentation.zig");
const help_menu_presentation = @import("../../ui/footer/help_menu_presentation.zig");
const settings_menu_presentation = @import("../../ui/footer/settings_menu_presentation.zig");
const surface_frame = @import("../../ui/footer/surface_frame.zig");
const footer_paint_plan = @import("../../ui/footer/paint_plan.zig");
const render_request = @import("../../ui/render_request.zig");

const ModelPickerStage = picker_state.ModelPickerStage;

pub const file_picker_completion_cap: usize = 32;
const file_picker_match_span_cap = file_picker_completion_cap * file_index.max_path_len;
pub const file_picker_path_storage_cap = file_picker_completion_cap * file_index.max_path_len;

pub const InlineSkillCompletion = struct {
    skill: skill_runtime.Skill,
    suffix: []const u8,
    replace_start: usize,
    replace_end: usize,
};

pub const InlineSlashCompletion = struct {
    suffix: []const u8,
};

pub const InlineCompletion = union(enum) {
    skill: InlineSkillCompletion,
    slash: InlineSlashCompletion,

    pub fn suffix(self: InlineCompletion) []const u8 {
        return switch (self) {
            .skill => |completion| completion.suffix,
            .slash => |completion| completion.suffix,
        };
    }
};

pub fn CompletionRuntime(comptime App: type) type {
    return struct {
        const FilePickerSelection = struct {
            query: picker_state.FilePickerQuery,
            choice: file_index.SearchResult,
        };

        pub fn slashCompletionCandidateCount(app: *App) usize {
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            ) orelse return 0;
            if (comptime @hasField(App, "skills")) {
                return picker_presentation.mixedSlashCompletionCount(
                    app.slashRegistry(),
                    prefix,
                    app.skills.items,
                );
            }
            return command_specs.slashCompletionCount(app.slashRegistry(), prefix);
        }

        fn slashCompletionQueryActive(app: *App) bool {
            if (app.input_runtime.picker.isInlinePickerSuppressed(.slash)) return false;
            if (app.input_runtime.picker.inlinePickerTriggerKind(&app.input_runtime.edit_state) != .slash) return false;
            // Model query always owns this slot. Mid-turn bare `/model` does too;
            // idle bare `/model` still surfaces slash rows.
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active and picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) return false;
            }
            return command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            ) != null;
        }

        pub fn slashCompletionCount(app: *App) usize {
            if (!slashCompletionQueryActive(app)) return 0;
            return slashCompletionCandidateCount(app);
        }

        fn visibleSlashCompletionQueryActive(app: *App) bool {
            if (comptime @hasField(App, "question_prompt")) {
                if (app.question_prompt.isActive()) return false;
            }
            if (comptime @hasField(App, "approval_prompt")) {
                if (app.approval_prompt.isActive()) return false;
            }
            if (hasFileQuery(app)) return false;
            return slashCompletionQueryActive(app);
        }

        /// Returns selectable completions projected by the footer.
        pub fn visibleSlashCompletionCount(app: *App) usize {
            if (!visibleSlashCompletionQueryActive(app)) return 0;
            return slashCompletionCandidateCount(app);
        }

        pub fn dismissVisibleInlinePicker(app: *App) bool {
            const kind = visibleInlinePickerKind(app) orelse return false;
            // Escaping the picker abandons the columns it had opened, so the
            // next `/provider` starts from the provider column again.
            if (kind == .provider) provider_picker_runtime.Runtime(App).abandon(app);
            app.input_runtime.picker.dismissInlinePicker(kind);
            return true;
        }

        fn visibleInlinePickerKind(app: *App) ?picker_state.InlinePickerKind {
            if (comptime @hasField(App, "question_prompt")) {
                if (app.question_prompt.isActive()) return null;
            }
            if (comptime @hasField(App, "approval_prompt")) {
                if (app.approval_prompt.isActive()) return null;
            }
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) {
                    if (hasModelQuery(app)) return .model;
                    if (hasFileQuery(app)) return .file;
                    if (visibleInlineSlashCompletion(app) != null) return .slash;
                    if (visibleSlashCompletionCount(app) > 0) return .slash;
                    return null;
                }
            }
            if (hasModelQuery(app)) return .model;
            if (provider_picker_runtime.Runtime(App).hasQuery(app)) return .provider;
            if (hasFileQuery(app)) return .file;
            if (visibleInlineCompletion(app)) |completion| {
                return switch (completion) {
                    .skill => .skill,
                    .slash => .slash,
                };
            }
            if (visibleSlashCompletionCount(app) > 0) return .slash;
            return null;
        }

        fn navigateSlashCompletion(app: *App, delta: i32, count: usize) void {
            navigatePickerOptions(&app.input_runtime.picker.slash_completion_index, &app.input_runtime.picker.slash_completion_window_start, count, delta);
        }

        pub fn routeSlashCompletionMove(app: *App, delta: i32) bool {
            const count = visibleSlashCompletionCount(app);
            if (count == 0) return false;
            navigateSlashCompletion(app, delta, count);
            return true;
        }

        pub fn routeModifiedHistory(app: *App, direction: visual_layout.Direction, delta: i32) !void {
            app.input_runtime.vertical_navigation.reset();
            if (try routeNonSlashPickerMove(app, delta)) {
                return;
            } else if (!routeSlashCompletionMove(app, delta)) {
                if (app.input_runtime.composer_history.activeIndex() != null) {
                    try navigatePromptHistory(app, delta);
                } else if (direction == .up and app.input_runtime.edit_state.cursor > 0) {
                    _ = horizontal_navigation.move(
                        .draft_start,
                        &app.input_runtime.edit_state,
                        &app.input_runtime.entities,
                        &app.input_runtime.vertical_navigation,
                    );
                } else if (direction == .up) {
                    try navigatePromptHistory(app, -1);
                } else if (app.input_runtime.edit_state.cursor < app.input_runtime.edit_state.input.items.len) {
                    _ = horizontal_navigation.move(
                        .draft_end,
                        &app.input_runtime.edit_state,
                        &app.input_runtime.entities,
                        &app.input_runtime.vertical_navigation,
                    );
                } else {
                    try navigatePromptHistory(app, 1);
                }
            }
        }

        pub fn routePlainVertical(app: *App, direction: visual_layout.Direction, delta: i32) !void {
            try routeComposerVertical(app, direction, delta, false, false);
        }

        pub fn routeComposerVertical(
            app: *App,
            direction: visual_layout.Direction,
            delta: i32,
            extend_selection: bool,
            page: bool,
        ) !void {
            const row_count = if (page)
                input_presentation.inputRowLimit(app.shell.layout.content_bottom)
            else
                @as(usize, 1);
            const picker_delta = if (page)
                delta * @as(i32, @intCast(@min(row_count, std.math.maxInt(i32))))
            else
                delta;
            if (try routeNonSlashPickerMove(app, picker_delta)) {
                app.input_runtime.vertical_navigation.reset();
                return;
            }

            const scan = if (page)
                ui_input.scanInputCursorRows(
                    &app.input_runtime,
                    direction,
                    row_count,
                    app.shell.layout.cols,
                    app.pending_images.items,
                )
            else
                ui_input.scanInputCursorVertical(
                    &app.input_runtime,
                    direction,
                    app.shell.layout.cols,
                    app.pending_images.items,
                );
            const capped = input_presentation.cappedInputRows(
                scan.total_rows,
                app.shell.layout.content_bottom,
                true,
            );
            const visible_slash_count = if (capped.input_extra == 0) visibleSlashCompletionCount(app) else 0;
            if (visible_slash_count > 0) {
                app.input_runtime.vertical_navigation.reset();
                navigateSlashCompletion(app, picker_delta, visible_slash_count);
                return;
            }

            if (app.input_runtime.vertical_navigation.applyTargetWithSelection(
                &app.input_runtime.edit_state,
                &app.input_runtime.entities,
                if (scan.target) |target| target.raw_offset else null,
                scan.preferred_column,
                extend_selection,
            )) return;

            if (page or extend_selection) return;

            if (direction == .up and app.input_runtime.edit_state.cursor > 0) {
                _ = horizontal_navigation.move(
                    .draft_start,
                    &app.input_runtime.edit_state,
                    &app.input_runtime.entities,
                    &app.input_runtime.vertical_navigation,
                );
            } else if (direction == .up) {
                try navigatePromptHistory(app, -1);
            } else if (app.input_runtime.edit_state.cursor < app.input_runtime.edit_state.input.items.len) {
                _ = horizontal_navigation.move(
                    .draft_end,
                    &app.input_runtime.edit_state,
                    &app.input_runtime.entities,
                    &app.input_runtime.vertical_navigation,
                );
            } else {
                try navigatePromptHistory(app, 1);
            }
        }

        pub fn navigatePromptHistory(app: *App, delta: i32) !void {
            const has_image_id_owner =
                @hasDecl(App, "peekNextImageId") and @hasDecl(App, "nextImageId");
            const first_image_id = if (comptime has_image_id_owner)
                app.peekNextImageId()
            else
                1;
            const max_input_len = if (comptime @hasDecl(App, "input_limits"))
                App.input_limits.composer_bytes
            else if (comptime @hasDecl(App, "input_byte_limit"))
                App.input_byte_limit
            else
                std.math.maxInt(usize);
            const result = app.input_runtime.composer_history.navigate(
                app.alloc,
                delta,
                .{
                    .edit = &app.input_runtime.edit_state,
                    .entities = &app.input_runtime.entities,
                    .picker = &app.input_runtime.picker,
                    .vertical_navigation = &app.input_runtime.vertical_navigation,
                    .input_limit_rejection = &app.input_runtime.input_limit_rejection,
                    .images = &app.pending_images,
                },
                first_image_id,
                max_input_len,
            ) catch |err| {
                switch (err) {
                    error.FileNotFound,
                    error.AccessDenied,
                    error.MissingImageSnapshot,
                    error.InvalidImageSnapshotDigest,
                    error.ImageSnapshotPathUnsafe,
                    error.NotRegularFile,
                    error.ImageTooLarge,
                    error.ImageSnapshotCorrupt,
                    error.UnsupportedImageType,
                    error.ImageSnapshotMediaTypeMismatch,
                    => {
                        debug_trace.logf(
                            "prompt_history",
                            "event=recall_rejected err={s}",
                            .{@errorName(err)},
                        );
                        return;
                    },
                    else => return err,
                }
            };
            switch (result) {
                .unchanged => {},
                .limit_exceeded => |attempted_bytes| try input_limit_feedback.report(
                    App,
                    app,
                    .composer,
                    attempted_bytes,
                ),
                .moved => |image_count| {
                    app.input_runtime.historyBoundary(app.alloc);
                    if (comptime has_image_id_owner) {
                        for (0..image_count) |offset| {
                            const committed_id = app.nextImageId();
                            std.debug.assert(committed_id == first_image_id + offset);
                        }
                    } else {
                        std.debug.assert(image_count == 0);
                    }
                },
            }
        }

        pub fn routeVisiblePickerMove(app: *App, delta: i32) !bool {
            if (try routeNonSlashPickerMove(app, delta)) return true;
            return routeSlashCompletionMove(app, delta);
        }

        fn routeNonSlashPickerMove(app: *App, delta: i32) !bool {
            if (try routeSettingsMenuMove(app, delta)) return true;
            if (try routeHelpMenuMove(app, delta)) return true;
            if (try routeModelMenuMove(app, delta)) return true;
            if (routeAuthPickerMove(app, delta)) return true;
            if (try routeSkillsMenuMove(app, delta)) return true;
            if (comptime runtime_profile.allows(App, .durable_sessions)) {
                if (try routeSessionPickerMove(app, delta)) return true;
            }
            if (hasFileQuery(app)) {
                navigateFilePicker(app, delta);
                return true;
            }
            if (hasModelQuery(app)) {
                navigateModelPicker(app, delta);
                return true;
            }
            if (provider_picker_runtime.Runtime(App).hasQuery(app)) {
                if (!app.stream.active) provider_picker_runtime.Runtime(App).navigate(app, delta);
                return true;
            }
            // Mid-turn bare `/model`: consume arrows without slash/skill navigation.
            if (app.stream.active and picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) return true;
            return false;
        }

        fn routeSettingsMenuMove(app: *App, delta: i32) !bool {
            const menu = &app.input_runtime.settings_menu;
            if (!menu.active) return false;
            const snapshot = app_commands.settingsCatalogSnapshot(app);
            var projection = render_input.settingsMenuProjection(
                menu,
                snapshot,
                app.input_runtime.edit_state.input.items,
            );
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    projection.models = render_input.modelMenuProjection(&app.model_cache);
                    _ = app.model_cache.menu.moveVisibleItems(
                        delta,
                        @max(
                            settings_menu_presentation.visibleModelItemsForBudget(
                                projection,
                                app.shell.layout.cols,
                                try inlineMenuRowBudget(app, settings_menu_presentation.max_inline_rows),
                            ),
                            1,
                        ),
                    );
                    return true;
                }
            }
            const visible_items = settings_menu_presentation.visibleNavigationItemsForBudget(
                projection,
                app.shell.layout.cols,
                try inlineMenuRowBudget(app, settings_menu_presentation.max_inline_rows),
            );
            return menu.move(&snapshot, app.input_runtime.edit_state.input.items, delta, visible_items);
        }

        fn routeHelpMenuMove(app: *App, delta: i32) !bool {
            if (!app.input_runtime.help_menu.active) return false;
            const projection = render_input.helpMenuProjection(
                &app.input_runtime.help_menu,
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            );
            const visible_items = help_menu_presentation.visibleNavigationItemsForBudget(
                projection,
                app.shell.layout.cols,
                try inlineMenuRowBudget(app, help_menu_presentation.max_inline_rows),
            );
            return app.input_runtime.help_menu.move(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
                delta,
                visible_items,
            );
        }

        fn routeModelMenuMove(app: *App, delta: i32) !bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            _ = app.model_cache.menu.moveVisibleItems(
                delta,
                model_menu_presentation.visibleNavigationItemsForBudget(
                    render_input.modelMenuProjection(&app.model_cache),
                    try inlineMenuRowBudget(app, model_menu_presentation.max_inline_rows),
                ),
            );
            return true;
        }

        fn routeSessionPickerMove(app: *App, delta: i32) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (app.stream.active) return false;
            if (!app.session_persistence.session_picker.active) return false;
            _ = app_session_runtime.Runtime(App).moveSessionPicker(app, delta, try sessionPickerVisibleItems(app));
            return true;
        }

        fn routeAuthPickerMove(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            return app.auth.movePicker(delta);
        }

        fn routeSkillsMenuMove(app: *App, delta: i32) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.moveMenuSelectionVisibleRows(delta, try skillsMenuVisibleRows(app));
        }

        fn skillsMenuVisibleRows(app: *App) !u16 {
            const projection = render_input.skillsMenuProjection(&app.skills);
            return skills_menu_presentation.inlineVisibleNavigationRowsForBudget(
                projection,
                try inlineMenuRowBudget(app, input_presentation.max_model_picker_rows + 2),
            );
        }

        fn inlineMenuRowBudget(app: *App, max_picker_rows: u16) !u16 {
            const budget = try footerRowBudget(app);
            return picker_presentation.inlinePickerRowBudgetCapped(
                app.shell.layout.rows,
                budget.input_extra,
                budget.banner_rows,
                max_picker_rows,
            );
        }

        const FooterRowBudget = struct {
            input_extra: u16,
            banner_rows: u16,
        };

        fn footerRowBudget(app: *App) !FooterRowBudget {
            const scan = ui_input.scanInputCursorVertical(
                &app.input_runtime,
                .down,
                app.shell.layout.cols,
                app.pending_images.items,
            );
            const capped = input_presentation.cappedInputRows(
                scan.total_rows,
                app.shell.layout.content_bottom,
                true,
            );
            if (comptime !@hasDecl(@TypeOf(app.worker), "snapshotSteeringPresentation")) {
                return .{ .input_extra = capped.input_extra, .banner_rows = 0 };
            }
            var steering = try app.worker.snapshotSteeringPresentation(app.alloc);
            defer steering.deinit(app.alloc);
            const requested_banner_rows = render_input.steeringBannerRowsForMessages(
                steering.messages,
                steering.waits_for_tool,
                app.shell.layout.cols,
            );
            return .{
                .input_extra = capped.input_extra,
                .banner_rows = surface_frame.clampSteeringBannerRows(
                    requested_banner_rows,
                    app.shell.layout.rows,
                    true,
                    footer_paint_plan.composerTopChromeRows(),
                    capped.input_extra,
                ),
            };
        }

        pub fn syncSessionPickerWindowStart(app: *App) !void {
            if (comptime !@hasField(App, "session_persistence")) return;
            const picker = &app.session_persistence.session_picker;
            const item_count = picker.navigationItemCount();
            if (!picker.active or item_count == 0) {
                picker.window_start = 0;
                return;
            }
            picker.syncWindowStart(try sessionPickerVisibleItems(app));
        }

        fn sessionPickerVisibleItems(app: *App) !u16 {
            const picker = &app.session_persistence.session_picker;
            const projection: render_input.SessionMenuProjection = .{
                .active = picker.active,
                .load_state = picker.load_state,
                .summaries = picker.summaries.items,
                .has_more = picker.has_more,
                .loading_more = picker.loading_more,
                .scope = picker.scope,
                .selected_index = picker.selected,
                .window_start = picker.window_start,
                .query = picker.query(),
                .selection_failure = picker.selection_failure,
            };
            return resume_menu_presentation.visibleNavigationItemsForBudget(
                projection,
                try inlineMenuRowBudget(app, resume_menu_presentation.max_inline_rows),
            );
        }

        pub fn hasModelQuery(app: *App) bool {
            return app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) != null;
        }

        pub fn hasFileQuery(app: *App) bool {
            return app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null;
        }

        pub fn visibleInlineSkillCompletion(app: *App) ?InlineSkillCompletion {
            if (comptime !@hasField(App, "skills")) return null;
            if (!inlineCompletionSurfaceAvailable(app)) return null;
            if (app.input_runtime.picker.inlinePickerTriggerKind(&app.input_runtime.edit_state) != .skill) return null;
            const query = app.input_runtime.picker.activeInlineSkillQuery(&app.input_runtime.edit_state) orelse return null;
            const match = skill_runtime.firstSkillNameCompletion(app.skills.items, query.query) orelse return null;
            if (!inlineSuffixCanRender(app, match.suffix)) return null;
            return .{
                .skill = match.skill,
                .suffix = match.suffix,
                .replace_start = query.dollar_offset,
                .replace_end = query.token_start + query.query.len,
            };
        }

        pub fn visibleInlineSlashCompletion(app: *App) ?InlineSlashCompletion {
            if (!inlineCompletionSurfaceAvailable(app)) return null;
            if (app.input_runtime.picker.inlinePickerTriggerKind(&app.input_runtime.edit_state) != .slash) return null;
            const query = app.input_runtime.picker.activeInlineSlashQuery(&app.input_runtime.edit_state) orelse return null;
            const command = command_specs.firstSlashCompletion(app.slashRegistry(), query.prefix) orelse return null;
            const suffix = command[query.prefix.len..];
            if (!inlineSuffixCanRender(app, suffix)) return null;
            return .{ .suffix = suffix };
        }

        pub fn visibleInlineCompletion(app: *App) ?InlineCompletion {
            if (visibleInlineSkillCompletion(app)) |completion| return .{ .skill = completion };
            if (visibleInlineSlashCompletion(app)) |completion| return .{ .slash = completion };
            return null;
        }

        pub fn autocompleteInlineCompletion(app: *App, max_input_len: usize) !edit_contract.InsertResult {
            const completion = visibleInlineCompletion(app) orelse return .inactive;
            return switch (completion) {
                .skill => |skill| bindInlineSkillCompletion(app, skill, max_input_len),
                .slash => |slash| app.input_runtime.insertionState().insertSliceBounded(
                    app.alloc,
                    slash.suffix,
                    max_input_len,
                    .preserve,
                ),
            };
        }

        pub fn autocompleteInlineSkillCompletion(app: *App, max_input_len: usize) !edit_contract.InsertResult {
            const completion = visibleInlineSkillCompletion(app) orelse return .inactive;
            return bindInlineSkillCompletion(app, completion, max_input_len);
        }

        fn bindInlineSkillCompletion(
            app: *App,
            completion: InlineSkillCompletion,
            max_input_len: usize,
        ) !edit_contract.InsertResult {
            const inserted_len = app.input_runtime.entities.skillTokenInsertedLen(
                app.input_runtime.edit_state.input.items,
                completion.replace_end,
                completion.skill.name,
            );
            if (!app.input_runtime.insertionState().canReplaceRange(
                completion.replace_start,
                completion.replace_end,
                inserted_len,
                max_input_len,
            )) {
                return .limit_exceeded;
            }

            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                completion.replace_start,
                completion.replace_end,
                completion.skill.name,
                completion.skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, completion.skill),
            );
            app.input_runtime.picker.resetInlinePickerEpisode();
            return .inserted;
        }

        fn inlineSuffixCanRender(app: *App, suffix: []const u8) bool {
            if (comptime !@hasField(@TypeOf(app.shell), "layout")) return false;
            const terminal_cols = app.shell.layout.cols;
            if (terminal_cols == 0) return false;

            const cursor = visual_layout.cursorPointAt(.{
                .input = app.input_runtime.edit_state.input.items,
                .cursor = app.input_runtime.edit_state.cursor,
                .terminal_cols = terminal_cols,
                .images = if (comptime @hasField(App, "pending_images"))
                    app.pending_images.items
                else
                    &.{},
                .pasted_blocks = app.input_runtime.entities.pasted_blocks.items,
                .image_tokens = app.input_runtime.entities.image_tokens.items,
                .skill_tokens = app.input_runtime.entities.skill_tokens.items,
            }, app.input_runtime.edit_state.cursor);
            const used_cells = visual_layout.inputPrefix(cursor.row_index).cell_width +| cursor.content_column;
            const available_cells = @as(usize, terminal_cols) -| used_cells;
            const first_unit = display_width.displayUnitAt(suffix, 0);
            return first_unit.byte_len > 0 and
                first_unit.cell_width > 0 and
                first_unit.cell_width <= available_cells;
        }

        fn inlineCompletionSurfaceAvailable(app: *App) bool {
            if (comptime @hasField(App, "question_prompt")) {
                if (app.question_prompt.isActive()) return false;
            }
            if (comptime @hasField(App, "approval_prompt")) {
                if (app.approval_prompt.isActive()) return false;
            }
            if (catalogMenuOwnsSurface(app)) return false;
            return true;
        }

        fn catalogMenuOwnsSurface(app: *App) bool {
            if (app.input_runtime.help_menu.active or app.input_runtime.settings_menu.active) return true;
            if (comptime @hasField(App, "skills")) {
                if (comptime @hasField(@TypeOf(app.skills), "menu")) {
                    if (app.skills.menuVisible()) return true;
                }
            }
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) return true;
            }
            if (comptime @hasField(App, "session_persistence")) {
                if (app.session_persistence.session_picker.active) return true;
            }
            return false;
        }

        fn navigateFilePicker(app: *App, delta: i32) void {
            const query = app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) orelse return;
            var results: [file_picker_completion_cap]file_index.SearchResult = undefined;
            var spans: [file_picker_match_span_cap]file_index.MatchSpan = undefined;
            var paths: [file_picker_path_storage_cap]u8 = undefined;
            const count = app.fileCompletions(query.query, &results, &spans, &paths) catch |err| {
                debug_trace.logf("input", "file picker navigation search failed err={s}", .{@errorName(err)});
                app.input_runtime.picker.resetFilePickerIndex();
                return;
            };
            navigatePickerOptions(&app.input_runtime.picker.file_completion_index, &app.input_runtime.picker.file_completion_window_start, count, delta);
        }

        pub fn autocompleteFilePickerSelection(app: *App, max_input_len: usize) !edit_contract.InsertResult {
            var results: [file_picker_completion_cap]file_index.SearchResult = undefined;
            var spans: [file_picker_match_span_cap]file_index.MatchSpan = undefined;
            var paths: [file_picker_path_storage_cap]u8 = undefined;
            const selection = resolveFilePickerSelection(app, &results, &spans, &paths) catch |err| {
                rejectFilePickerSearch(app, err);
                return .inactive;
            } orelse return .inactive;
            return applyFilePickerSelection(app, selection, max_input_len);
        }

        fn resolveFilePickerSelection(
            app: *App,
            out: *[file_picker_completion_cap]file_index.SearchResult,
            match_spans: *[file_picker_match_span_cap]file_index.MatchSpan,
            path_storage: *[file_picker_path_storage_cap]u8,
        ) !?FilePickerSelection {
            const query = app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) orelse return null;
            const count = try app.fileCompletions(query.query, out, match_spans, path_storage);
            if (count == 0) return null;

            const idx = app.input_runtime.picker.file_completion_index % count;
            return .{
                .query = query,
                .choice = out[idx],
            };
        }

        fn rejectFilePickerSearch(app: *App, err: anyerror) void {
            debug_trace.logf("input", "file picker selection search failed err={s}", .{@errorName(err)});
            app.input_runtime.picker.resetFilePickerIndex();
        }

        fn applyFilePickerSelection(
            app: *App,
            selection: FilePickerSelection,
            max_input_len: usize,
        ) !edit_contract.InsertResult {
            if (!file_picker_path.isRepresentable(selection.choice.path)) {
                debug_trace.logf("input", "file picker rejected unrepresentable selection bytes={d}", .{selection.choice.path.len});
                app.input_runtime.picker.resetFilePickerIndex();
                return .inactive;
            }
            if (!isCurrentFileCompletion(app, selection.query.query, selection.choice.path, selection.choice.kind)) {
                debug_trace.logf("input", "file picker rejected stale selection bytes={d} kind={s}", .{ selection.choice.path.len, @tagName(selection.choice.kind) });
                app.input_runtime.picker.resetFilePickerIndex();
                if (fileCompletionsDependOnIndex(app, selection.query.query)) {
                    if (comptime @hasDecl(App, "refreshFileIndex")) app.refreshFileIndex();
                }
                return .inactive;
            }

            const items = app.input_runtime.edit_state.input.items;
            const replace_start = selection.query.at_offset;
            const replace_end = selection.query.token_start + selection.query.query.len;
            const tail = items[replace_end..];
            const reuses_terminator = tail.len > 0 and picker_state.isFilePickerTerminator(tail[0]);
            const is_directory = selection.choice.kind == .directory;
            const uses_quote = selection.query.quoted or file_picker_path.needsQuotes(selection.choice.path);
            const directory_slash_len: usize = @intFromBool(is_directory);
            const quote_len: usize = @intFromBool(uses_quote);
            const closing_quote_len: usize = @intFromBool(uses_quote and !is_directory);
            const inserted_path_len = selection.choice.path.len + directory_slash_len;
            const adds_terminator = !is_directory and !reuses_terminator;
            const inserted_len = 1 + quote_len + inserted_path_len + closing_quote_len + @intFromBool(adds_terminator);

            var replacement: std.ArrayList(u8) = .empty;
            defer replacement.deinit(app.alloc);
            try replacement.ensureTotalCapacity(app.alloc, inserted_len);
            replacement.appendAssumeCapacity('@');
            if (uses_quote) replacement.appendAssumeCapacity('"');
            replacement.appendSliceAssumeCapacity(selection.choice.path);
            if (is_directory) replacement.appendAssumeCapacity('/');
            if (uses_quote and !is_directory) replacement.appendAssumeCapacity('"');
            const separator_offset = replace_start + replacement.items.len;
            if (adds_terminator) replacement.appendAssumeCapacity(' ');
            const cursor_after_replacement = replace_start + replacement.items.len + @intFromBool(!is_directory and reuses_terminator);

            const result = try app.input_runtime.replacementState(&app.pending_images).replaceRangeBounded(
                app.alloc,
                .{ .start = replace_start, .end = replace_end },
                replacement.items,
                cursor_after_replacement,
                max_input_len,
            );
            if (result == .inserted) {
                if (adds_terminator) {
                    app.input_runtime.entities.markFileCompletionSeparator(
                        app.input_runtime.edit_state.input.items,
                        app.input_runtime.edit_state.cursor,
                        separator_offset,
                    );
                }
                if (is_directory) app.input_runtime.picker.resetFilePickerIndex();
            }
            return result;
        }

        pub fn submitFilePickerOnEnter(app: *App, max_input_len: usize) !?edit_contract.InsertResult {
            if (!filePickerOwnsSurface(app)) return null;
            var results: [file_picker_completion_cap]file_index.SearchResult = undefined;
            var spans: [file_picker_match_span_cap]file_index.MatchSpan = undefined;
            var paths: [file_picker_path_storage_cap]u8 = undefined;
            const selection = resolveFilePickerSelection(app, &results, &spans, &paths) catch |err| {
                rejectFilePickerSearch(app, err);
                return .inactive;
            } orelse return null;
            const result = try applyFilePickerSelection(app, selection, max_input_len);
            debug_trace.logf(
                "input",
                "file picker Enter consumed selected={s} limit_exceeded={s}",
                .{
                    if (result == .inserted) "true" else "false",
                    if (result == .limit_exceeded) "true" else "false",
                },
            );
            return result;
        }

        pub fn filePickerOwnsSurface(app: *App) bool {
            return visibleInlinePickerKind(app) == .file;
        }

        fn isCurrentFileCompletion(app: *App, query: []const u8, path: []const u8, kind: file_index.CandidateKind) bool {
            if (comptime @hasDecl(App, "isCurrentFileCompletion")) {
                return app.isCurrentFileCompletion(query, path, kind);
            }
            return true;
        }

        fn fileCompletionsDependOnIndex(app: *App, query: []const u8) bool {
            if (comptime @hasDecl(App, "fileCompletionsDependOnIndex")) {
                return app.fileCompletionsDependOnIndex(query);
            }
            return true;
        }

        pub fn navigateModelPicker(app: *App, delta: i32) void {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return;
            switch (query.stage) {
                .model => navigateModelCompletion(app, query.query, delta),
                .effort => {
                    var values: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined;
                    navigatePickerOptions(&app.input_runtime.picker.model_picker_effort_index, &app.input_runtime.picker.model_picker_effort_window_start, effortCompletionValues(app, query.query, &values), delta);
                },
                .fast => {
                    var labels: [2][]const u8 = undefined;
                    navigatePickerOptions(&app.input_runtime.picker.model_picker_fast_index, &app.input_runtime.picker.model_picker_fast_window_start, fastCompletionLabels(query.query, &labels), delta);
                },
            }
        }

        fn navigateModelCompletion(app: *App, query: []const u8, delta: i32) void {
            var buf: [32][]const u8 = undefined;
            const count = modelPickerCompletions(app, query, &buf);
            if (count == 0) return;
            app.input_runtime.picker.model_completion_index = modelPickerIndex(app, buf[0..count]);
            app.input_runtime.picker.model_completion_window_start = modelPickerWindowStart(app, count, app.input_runtime.picker.model_completion_index);
            app.input_runtime.picker.model_completion_anchor_current = false;
            navigatePickerOptions(&app.input_runtime.picker.model_completion_index, &app.input_runtime.picker.model_completion_window_start, count, delta);
        }

        pub fn modelPickerCompletions(app: *App, query: []const u8, out: *[32][]const u8) usize {
            const count = app.modelCompletions(query, out);
            if (comptime !provider_runtime.supported(App)) return count;
            if (!app.input_runtime.picker.model_completion_anchor_current or query.len != 0) return count;

            const selected_model = provider_runtime.model(app);
            if (modelCompletionIndex(out[0..count], selected_model) == null) {
                if (catalogModelCompletion(app, selected_model)) |current| {
                    if (count < out.len) {
                        out[count] = current;
                        return count + 1;
                    }
                    if (count > 0) out[count - 1] = current;
                }
            }
            return count;
        }

        fn catalogModelCompletion(app: *App, model: []const u8) ?[]const u8 {
            if (comptime @hasDecl(App, "catalogModelCompletion")) return app.catalogModelCompletion(model);

            var buf: [32][]const u8 = undefined;
            const count = app.modelCompletions(model, &buf);
            const index = modelCompletionIndex(buf[0..count], model) orelse return null;
            return buf[index];
        }

        pub fn modelPickerIndex(app: *App, completions: []const []const u8) usize {
            if (completions.len == 0) return 0;
            if (comptime !provider_runtime.supported(App)) return app.input_runtime.picker.model_completion_index % completions.len;
            if (app.input_runtime.picker.model_completion_anchor_current) {
                if (modelCompletionIndex(completions, provider_runtime.model(app))) |index| return index;
            }
            return app.input_runtime.picker.model_completion_index % completions.len;
        }

        pub fn modelPickerWindowStart(app: *App, count: usize, index: usize) usize {
            if (app.input_runtime.picker.model_completion_anchor_current) {
                return list_window.updateEdgeStart(0, count, index, list_window.default_max_picker_rows);
            }
            return app.input_runtime.picker.model_completion_window_start;
        }

        fn modelCompletionIndex(completions: []const []const u8, model: []const u8) ?usize {
            for (completions, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate, model)) return index;
            }
            return null;
        }

        const navigatePickerOptions = list_window.advanceSelection;

        fn setModelComposerText(app: *App, comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(app.alloc, fmt, args);
            defer app.alloc.free(text);
            try app.input_runtime.textReplacementState().replace(app.alloc, text);
        }

        pub fn autocompleteModelPickerSelection(app: *App) !void {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return;
            switch (query.stage) {
                .model => {
                    const model = selectedModelCompletion(app) orelse return;
                    try setModelComposerText(app, "/model {s}", .{model});
                },
                .effort => {
                    const model = try app.alloc.dupe(u8, app.input_runtime.picker.model_picker_pending_model.items);
                    defer app.alloc.free(model);
                    const effort = selectedEffortCompletion(app) orelse return;
                    const capabilities = model_capabilities.resolveForApp(App, app, model);
                    try setModelComposerText(app, "/model {s} {s}", .{ model, effort.label() });
                    try app.input_runtime.picker.beginModelPickerFlow(
                        app.alloc,
                        model,
                        model_capabilities.reasoningEffortIndex(capabilities, effort),
                        capabilities.supports_fast_mode,
                        .effort,
                    );
                },
                .fast => {
                    const model = try app.alloc.dupe(u8, app.input_runtime.picker.model_picker_pending_model.items);
                    defer app.alloc.free(model);
                    const capabilities = model_capabilities.resolveForApp(App, app, model);
                    const effort = model_capabilities.reasoningEffortAtIndex(capabilities, app.input_runtime.picker.model_picker_effort_index);
                    const effort_index = model_capabilities.reasoningEffortIndex(capabilities, effort);
                    const fast_mode = selectedFastCompletion(app) orelse return;
                    const fast_label = if (fast_mode) picker_state.model_picker_fast_options[1] else picker_state.model_picker_fast_options[0];
                    try setModelComposerText(app, "/model {s} {s} {s}", .{ model, effort.label(), fast_label });
                    try app.input_runtime.picker.beginModelPickerFlow(app.alloc, model, effort_index, fast_mode, .fast);
                },
            }
            app.shell.render_requests.request(.footer);
        }

        pub fn advanceModelPickerOnSpace(app: *App) !bool {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (app.input_runtime.edit_state.cursor != app.input_runtime.edit_state.input.items.len) return false;

            switch (query.stage) {
                .model => {
                    const model = exactModelCompletion(app, query.query) orelse return false;
                    try beginModelPickerOptions(app, model);
                    return true;
                },
                .effort => {
                    if (!app.input_runtime.picker.hasPendingModelPickerSelection()) return false;
                    const model = try app.alloc.dupe(u8, app.input_runtime.picker.model_picker_pending_model.items);
                    defer app.alloc.free(model);
                    const effort = exactEffortCompletion(app, query.query) orelse return false;
                    const capabilities = model_capabilities.resolveForApp(App, app, model);
                    if (!capabilities.supports_fast_mode) return false;

                    try setModelComposerText(app, "/model {s} {s} ", .{ model, effort.label() });
                    try app.input_runtime.picker.beginModelPickerFlow(app.alloc, model, model_capabilities.reasoningEffortIndex(capabilities, effort), true, .fast);
                    return true;
                },
                .fast => return false,
            }
        }

        fn exactModelCompletion(app: *App, raw_query: []const u8) ?[]const u8 {
            const query = std.mem.trim(u8, raw_query, " \t");
            if (query.len == 0) return null;

            var buf: [32][]const u8 = undefined;
            const count = modelPickerCompletions(app, query, &buf);
            for (buf[0..count]) |candidate| {
                if (std.ascii.eqlIgnoreCase(candidate, query)) return candidate;
            }
            return null;
        }

        pub fn submitModelPicker(app: *App) !bool {
            switch (app.input_runtime.picker.model_picker_stage) {
                .model => {
                    if (app.isModelCacheLoading()) {
                        const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return false;
                        if (std.mem.trim(u8, query.query, " \t").len > 0) return false;
                        app.shell.render_requests.request(.footer);
                        return true;
                    }
                    const model = selectedModelCompletion(app) orelse return false;
                    try beginModelPickerOptions(app, model);
                    return true;
                },
                .effort => {
                    if (!app.input_runtime.picker.hasPendingModelPickerSelection()) return false;
                    const model = try app.alloc.dupe(u8, app.input_runtime.picker.model_picker_pending_model.items);
                    defer app.alloc.free(model);
                    const effort = selectedEffortCompletion(app) orelse {
                        app.shell.render_requests.request(.footer);
                        return true;
                    };
                    const capabilities = model_capabilities.resolveForApp(App, app, model);
                    if (capabilities.supports_fast_mode) {
                        try setModelComposerText(app, "/model {s} {s} ", .{ model, effort.label() });
                        try app.input_runtime.picker.beginModelPickerFlow(app.alloc, model, model_capabilities.reasoningEffortIndex(capabilities, effort), true, .fast);
                    } else {
                        try session_commands.Commands(App).selectModelFromPicker(app, model, effort, app.fast_mode);
                        app.input_runtime.inputResetState().clearCurrent(app.alloc);
                    }
                    app.shell.render_requests.request(.footer);
                    return true;
                },
                .fast => {
                    if (!app.input_runtime.picker.hasPendingModelPickerSelection()) return false;
                    const model = try app.alloc.dupe(u8, app.input_runtime.picker.model_picker_pending_model.items);
                    defer app.alloc.free(model);
                    const fast_mode = selectedFastCompletion(app) orelse {
                        app.shell.render_requests.request(.footer);
                        return true;
                    };
                    const effort = model_capabilities.reasoningEffortAtIndex(model_capabilities.resolveForApp(App, app, model), app.input_runtime.picker.model_picker_effort_index);
                    try session_commands.Commands(App).selectModelFromPicker(app, model, effort, fast_mode);
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                    app.shell.render_requests.request(.footer);
                    return true;
                },
            }
        }

        fn selectedModelCompletion(app: *App) ?[]const u8 {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return null;
            if (query.stage != .model) return null;
            if (exactModelCompletion(app, query.query)) |model| return model;
            var buf: [32][]const u8 = undefined;
            const count = modelPickerCompletions(app, query.query, &buf);
            if (count == 0) return null;
            const idx = modelPickerIndex(app, buf[0..count]);
            return buf[idx];
        }

        pub fn openCurrentModelPicker(app: *App) !void {
            try app.input_runtime.textReplacementState().replace(app.alloc, "/model ");
            app.input_runtime.picker.model_completion_anchor_current = true;
            app.shell.render_requests.request(.footer);
        }

        fn beginModelPickerOptions(app: *App, model: []const u8) !void {
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            const supports_effort = capabilities.reasoning_efforts.len > 0;
            const supports_fast = capabilities.supports_fast_mode;

            if (!supports_effort and !supports_fast) {
                try session_commands.Commands(App).selectModelFromPicker(app, model, app.effort, app.fast_mode);
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                app.shell.render_requests.request(.footer);
                return;
            }

            const stage: ModelPickerStage = if (supports_effort) .effort else .fast;
            if (supports_effort) {
                try setModelComposerText(app, "/model {s} ", .{model});
            } else {
                try setModelComposerText(app, "/model {s} auto ", .{model});
            }
            // Preselect the product effort default and enable Fast mode when supported.
            try app.input_runtime.picker.beginModelPickerFlow(
                app.alloc,
                model,
                model_capabilities.reasoningEffortIndex(capabilities, .auto),
                supports_fast,
                stage,
            );
            app.shell.render_requests.request(.footer);
        }

        pub fn beginExactModelSelection(app: *App, model: []const u8) !void {
            try beginModelPickerOptions(app, model);
        }

        pub fn stepBackModelPicker(app: *App) !bool {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (query.stage == .model) return false;
            if (!app.input_runtime.picker.hasPendingModelPickerSelection()) return false;

            const model = try app.alloc.dupe(u8, app.input_runtime.picker.model_picker_pending_model.items);
            defer app.alloc.free(model);
            switch (query.stage) {
                .model => return false,
                .effort => {
                    try restoreModelPickerModelStage(app, model);
                    return true;
                },
                .fast => {
                    const capabilities = model_capabilities.resolveForApp(App, app, model);
                    if (capabilities.reasoning_efforts.len > 0) {
                        const effort_index = model_capabilities.reasoningEffortIndex(capabilities, model_capabilities.reasoningEffortAtIndex(capabilities, app.input_runtime.picker.model_picker_effort_index));
                        try setModelComposerText(app, "/model {s} ", .{model});
                        try app.input_runtime.picker.beginModelPickerFlow(app.alloc, model, effort_index, app.fast_mode, .effort);
                    } else {
                        try restoreModelPickerModelStage(app, model);
                    }
                    return true;
                },
            }
        }

        fn restoreModelPickerModelStage(app: *App, model: []const u8) !void {
            try setModelComposerText(app, "/model {s}", .{model});
            syncModelCompletionSelection(app, model, model);
        }

        fn syncModelCompletionSelection(app: *App, query: []const u8, model: []const u8) void {
            var buf: [32][]const u8 = undefined;
            const count = app.modelCompletions(query, &buf);
            var index: usize = 0;
            for (buf[0..count], 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, model)) {
                    index = i;
                    break;
                }
            }
            app.input_runtime.picker.model_completion_index = index;
            app.input_runtime.picker.model_completion_window_start = list_window.updateEdgeStart(
                0,
                count,
                index,
                list_window.default_max_picker_rows,
            );
        }

        pub fn abandonModelPickerOptions(app: *App) void {
            if (app.input_runtime.picker.model_picker_stage == .model) return;
            app.input_runtime.picker.clearModelPickerFlow();
        }

        pub fn shouldPreserveModelPickerInsert(app: *App) bool {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return false;
            return query.stage != .model and app.input_runtime.edit_state.cursor == app.input_runtime.edit_state.input.items.len;
        }

        pub fn shouldPreserveModelPickerBackspace(app: *App) bool {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return false;
            return query.stage != .model and query.query.len > 0 and app.input_runtime.edit_state.cursor == app.input_runtime.edit_state.input.items.len;
        }

        fn effortCompletionValues(
            app: *App,
            query: []const u8,
            out: *[types.ReasoningEffort.max_options + 1]types.ReasoningEffort,
        ) usize {
            if (!app.input_runtime.picker.hasPendingModelPickerSelection()) return 0;
            const capabilities = model_capabilities.resolveForApp(App, app, app.input_runtime.picker.model_picker_pending_model.items);
            const count = model_capabilities.reasoningEffortOptionCount(capabilities);
            if (count == 0) return 0;

            const normalized_query = std.mem.trim(u8, query, " \t");
            var result_count: usize = 0;
            for (0..count) |i| {
                const effort = model_capabilities.reasoningEffortAtIndex(capabilities, i);
                if (normalized_query.len > 0 and !text_utils.containsIgnoreCase(effort.displayLabel(), normalized_query)) continue;
                out[result_count] = effort;
                result_count += 1;
            }
            return result_count;
        }

        fn exactEffortCompletion(app: *App, raw_query: []const u8) ?types.ReasoningEffort {
            if (!app.input_runtime.picker.hasPendingModelPickerSelection()) return null;
            const query = std.mem.trim(u8, raw_query, " \t");
            const effort = types.ReasoningEffort.parseDisplayLabel(query) orelse return null;
            if (!model_capabilities.reasoningEffortSupported(model_capabilities.resolveForApp(App, app, app.input_runtime.picker.model_picker_pending_model.items), effort)) return null;
            return effort;
        }

        fn selectedEffortCompletion(app: *App) ?types.ReasoningEffort {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return null;
            if (query.stage != .effort) return null;

            const normalized_query = std.mem.trim(u8, query.query, " \t");
            if (exactEffortCompletion(app, normalized_query)) |effort| return effort;

            var values: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined;
            const count = effortCompletionValues(app, normalized_query, &values);
            if (count == 0) return null;
            return values[app.input_runtime.picker.model_picker_effort_index % count];
        }

        fn fastCompletionLabels(query: []const u8, out: *[2][]const u8) usize {
            return picker_state.filterCompletionLabels(query, picker_state.model_picker_fast_options[0..], out[0..]);
        }

        fn exactFastCompletion(raw_query: []const u8) ?bool {
            const query = std.mem.trim(u8, raw_query, " \t");
            if (std.ascii.eqlIgnoreCase(query, picker_state.model_picker_fast_options[0])) return false;
            if (std.ascii.eqlIgnoreCase(query, picker_state.model_picker_fast_options[1])) return true;
            return null;
        }

        fn selectedFastCompletion(app: *App) ?bool {
            const query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) orelse return null;
            if (query.stage != .fast) return null;

            const normalized_query = std.mem.trim(u8, query.query, " \t");
            if (exactFastCompletion(normalized_query)) |fast_mode| return fast_mode;

            var labels: [2][]const u8 = undefined;
            const count = fastCompletionLabels(normalized_query, &labels);
            if (count == 0) return null;
            const label = labels[app.input_runtime.picker.model_picker_fast_index % count];
            return std.mem.eql(u8, label, picker_state.model_picker_fast_options[1]);
        }
    };
}

const FilePickerTestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    stream: types.StreamState = .{},
    shell: struct {} = .{},
    file_completion_values: []const file_index.Candidate = &.{},

    pub fn slashRegistry(_: *const FilePickerTestApp) command_specs.SlashRegistry {
        return .{};
    }

    fn deinit(self: *FilePickerTestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
    }

    pub fn fileCompletions(
        self: *FilePickerTestApp,
        _: []const u8,
        out: *[file_picker_completion_cap]file_index.SearchResult,
        _: *[file_picker_match_span_cap]file_index.MatchSpan,
        _: *[file_picker_path_storage_cap]u8,
    ) file_index.SearchError!usize {
        const count = @min(self.file_completion_values.len, out.len);
        for (self.file_completion_values[0..count], 0..) |value, index| {
            out[index] = .{
                .path = value.path,
                .kind = value.kind,
                .matched_spans = &.{},
            };
        }
        return count;
    }

    pub fn isCurrentFileCompletion(_: *const FilePickerTestApp, _: []const u8, _: []const u8, _: file_index.CandidateKind) bool {
        return true;
    }
};

const FilesystemFilePickerTestApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    workspace: app_workspace_runtime.State = .{},
    file_index: file_index.FileIndex = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,

    fn deinit(self: *FilesystemFilePickerTestApp) void {
        app_workspace_runtime.Runtime(FilesystemFilePickerTestApp).deinit(self);
        self.file_index.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
    }

    pub fn fileCompletions(
        self: *FilesystemFilePickerTestApp,
        query: []const u8,
        out: []file_index.SearchResult,
        match_spans: []file_index.MatchSpan,
        path_storage: []u8,
    ) app_workspace_runtime.FileCompletionError!usize {
        return app_workspace_runtime.Runtime(FilesystemFilePickerTestApp).fileCompletions(
            self,
            query,
            out,
            match_spans,
            path_storage,
        );
    }

    pub fn fileCompletionsDependOnIndex(self: *const FilesystemFilePickerTestApp, query: []const u8) bool {
        return app_workspace_runtime.Runtime(FilesystemFilePickerTestApp).fileCompletionsDependOnIndex(self, query);
    }

    pub fn isCurrentFileCompletion(
        self: *const FilesystemFilePickerTestApp,
        query: []const u8,
        path: []const u8,
        kind: file_index.CandidateKind,
    ) bool {
        return app_workspace_runtime.Runtime(FilesystemFilePickerTestApp).isCurrentFileCompletion(
            self,
            query,
            path,
            kind,
        );
    }
};

const inline_completion_test_slash_specs = [_]command_specs.SlashSpec{
    .{
        .kind = .help,
        .command = "/help",
        .help_entry = "/help",
    },
    .{
        .kind = .resume_session,
        .command = "/resume",
        .help_entry = "/resume",
    },
};
const inline_completion_test_slash_registry = command_specs.SlashRegistry{
    .commands = inline_completion_test_slash_specs[0..],
};

const InlineCompletionTestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    skills: skill_runtime.Runtime = .{},
    model_cache: struct {
        menu: struct {
            active: bool = false,
        } = .{},
    } = .{},
    session_persistence: struct {
        session_picker: struct {
            active: bool = false,
        } = .{},
    } = .{},
    shell: struct {
        layout: struct {
            cols: u16 = 80,
        } = .{},
        render_requests: render_request.RenderRequestState = .{},
    } = .{},

    pub fn slashRegistry(_: *const InlineCompletionTestApp) command_specs.SlashRegistry {
        return inline_completion_test_slash_registry;
    }

    fn deinit(self: *InlineCompletionTestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
    }
};

const ModelPickerCompletionTestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},

    fn deinit(self: *ModelPickerCompletionTestApp) void {
        self.input_runtime.deinit(self.alloc);
    }

    pub fn resolvedModelCapabilities(_: *const ModelPickerCompletionTestApp, _: []const u8) model_capabilities.Capabilities {
        return .{
            .reasoning_efforts = .fromSlice(&.{
                types.ReasoningEffort.literal("future-tier"),
                types.ReasoningEffort.literal("high"),
            }),
        };
    }
};

noinline fn clobberCompletionStack() void {
    var bytes: [8192]u8 = undefined;
    @memset(&bytes, 0xa5);
    std.mem.doNotOptimizeAway(&bytes);
}

test "model picker effort completion labels survive capability resolution" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(ModelPickerCompletionTestApp);
    var app = ModelPickerCompletionTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.picker.beginModelPickerFlow(alloc, "test/model", 0, false, .effort);

    var values: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined;
    const count = rt.effortCompletionValues(&app, "", &values);
    clobberCompletionStack();

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("default", values[0].displayLabel());
    try std.testing.expectEqualStrings("future-tier", values[1].displayLabel());
    try std.testing.expectEqualStrings("high", values[2].displayLabel());
}

test "inline slash completion uses the shared visible suffix and acceptance path" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    var app = InlineCompletionTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "explain /he");

    const completion = rt.visibleInlineCompletion(&app).?;
    try std.testing.expectEqualStrings("lp", completion.suffix());
    try std.testing.expectEqualStrings(
        "lp",
        rt.visibleInlineSlashCompletion(&app).?.suffix,
    );
    try std.testing.expectEqual(
        edit_contract.InsertResult.limit_exceeded,
        try rt.autocompleteInlineCompletion(&app, app.input_runtime.edit_state.input.items.len),
    );
    try std.testing.expectEqualStrings("explain /he", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(
        edit_contract.InsertResult.inserted,
        try rt.autocompleteInlineCompletion(&app, 4096),
    );
    try std.testing.expectEqualStrings("explain /help", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
}

test "inline slash completion stays inactive when its suffix cannot render" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    var app = InlineCompletionTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "x /he");

    app.shell.layout.cols = 7;
    try std.testing.expectEqual(
        @as(?InlineSlashCompletion, null),
        rt.visibleInlineSlashCompletion(&app),
    );
    try std.testing.expectEqual(
        edit_contract.InsertResult.inactive,
        try rt.autocompleteInlineCompletion(&app, 4096),
    );
    try std.testing.expectEqualStrings("x /he", app.input_runtime.edit_state.input.items);

    app.shell.layout.cols = 8;
    try std.testing.expectEqualStrings(
        "lp",
        rt.visibleInlineSlashCompletion(&app).?.suffix,
    );
}

test "root slash query is dismissible only while candidates are visible" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    var app = InlineCompletionTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/hezzzzz");

    try std.testing.expectEqual(@as(usize, 0), rt.visibleSlashCompletionCount(&app));
    try std.testing.expect(!rt.dismissVisibleInlinePicker(&app));
    try std.testing.expect(!app.input_runtime.picker.isInlinePickerDismissed(.slash));

    try app.input_runtime.textReplacementState().replace(alloc, "/he");
    try std.testing.expect(rt.visibleSlashCompletionCount(&app) > 0);
    try std.testing.expect(rt.dismissVisibleInlinePicker(&app));
    try std.testing.expect(app.input_runtime.picker.isInlinePickerDismissed(.slash));
}

test "root slash completion follows multiline and command argument ownership" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    const skills = [_]skill_runtime.Skill{.{
        .name = "resume-helper",
        .description = "resume a workflow",
        .path = "/tmp/resume-helper/SKILL.md",
        .source = .global_fx,
    }};
    var app = InlineCompletionTestApp{
        .alloc = alloc,
        .skills = .{ .items = @constCast(&skills) },
    };
    defer app.deinit();

    try app.input_runtime.textReplacementState().replace(alloc, "\n   /");
    try std.testing.expect(rt.visibleSlashCompletionCount(&app) > 0);

    try app.input_runtime.textReplacementState().replace(alloc, "/resume ");
    try std.testing.expectEqual(@as(usize, 0), rt.visibleSlashCompletionCount(&app));
    try std.testing.expect(!rt.dismissVisibleInlinePicker(&app));
}

test "inline skill completion stays inactive when its suffix cannot render" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    var app = InlineCompletionTestApp{
        .alloc = alloc,
        .skills = .{ .items = @constCast(&skills) },
    };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "x $man");

    app.shell.layout.cols = 8;
    try std.testing.expectEqual(
        @as(?InlineSkillCompletion, null),
        rt.visibleInlineSkillCompletion(&app),
    );
    try std.testing.expectEqual(
        edit_contract.InsertResult.inactive,
        try rt.autocompleteInlineSkillCompletion(&app, 4096),
    );
    try std.testing.expectEqualStrings("x $man", app.input_runtime.edit_state.input.items);

    app.shell.layout.cols = 9;
    try std.testing.expectEqualStrings(
        "aged-menu",
        rt.visibleInlineSkillCompletion(&app).?.suffix,
    );
}

test "model picker ownership suppresses inline skill completion" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    var app = InlineCompletionTestApp{
        .alloc = alloc,
        .skills = .{ .items = @constCast(&skills) },
    };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/model anything $man");

    try std.testing.expect(app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) != null);
    try std.testing.expectEqual(
        @as(?InlineSkillCompletion, null),
        rt.visibleInlineSkillCompletion(&app),
    );
    try std.testing.expectEqual(
        edit_contract.InsertResult.inactive,
        try rt.autocompleteInlineSkillCompletion(&app, 4096),
    );
    try std.testing.expectEqualStrings("/model anything $man", app.input_runtime.edit_state.input.items);
}

test "dedicated catalog ownership suppresses inline skill completion" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(InlineCompletionTestApp);
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed-menu",
        .description = "",
        .path = "/tmp/managed-menu/SKILL.md",
        .source = .global_fx,
    }};
    var app = InlineCompletionTestApp{
        .alloc = alloc,
        .skills = .{ .items = @constCast(&skills) },
    };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "x $man");

    try std.testing.expect(rt.visibleInlineSkillCompletion(&app) != null);

    app.input_runtime.help_menu.active = true;
    try expectInlineSkillCompletionInactive(&app);
    app.input_runtime.help_menu.active = false;

    app.input_runtime.settings_menu.active = true;
    try expectInlineSkillCompletionInactive(&app);
    app.input_runtime.settings_menu.active = false;

    app.model_cache.menu.active = true;
    try expectInlineSkillCompletionInactive(&app);
    app.model_cache.menu.active = false;

    app.session_persistence.session_picker.active = true;
    try expectInlineSkillCompletionInactive(&app);
    app.session_persistence.session_picker.active = false;

    app.skills.menu.active = true;
    try expectInlineSkillCompletionInactive(&app);

    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("x $man", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.skill_tokens.items.len);
}

fn expectInlineSkillCompletionInactive(app: *InlineCompletionTestApp) !void {
    const rt = CompletionRuntime(InlineCompletionTestApp);
    try std.testing.expectEqual(
        @as(?InlineSkillCompletion, null),
        rt.visibleInlineSkillCompletion(app),
    );
    try std.testing.expectEqual(
        edit_contract.InsertResult.inactive,
        try rt.autocompleteInlineSkillCompletion(app, 4096),
    );
}

test "streaming file selection commits the selected path" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(FilePickerTestApp);
    var app = FilePickerTestApp{
        .alloc = alloc,
        .file_completion_values = &.{.{ .path = "src/main.zig", .kind = .file }},
    };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "review @src/mai");
    app.stream.active = true;

    try std.testing.expectEqual(
        edit_contract.InsertResult.inserted,
        (try rt.submitFilePickerOnEnter(&app, 4096)).?,
    );
    try std.testing.expectEqualStrings("review @src/main.zig ", app.input_runtime.edit_state.input.items);
}

test "file picker rejects paths that would reopen quote grammar" {
    const alloc = std.testing.allocator;
    const rt = CompletionRuntime(FilePickerTestApp);
    var app = FilePickerTestApp{
        .alloc = alloc,
        .file_completion_values = &.{.{ .path = "\"weird", .kind = .file }},
    };
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "@we");

    try std.testing.expectEqual(
        edit_contract.InsertResult.inactive,
        try rt.autocompleteFilePickerSelection(&app, 4096),
    );
    try std.testing.expectEqualStrings("@we", app.input_runtime.edit_state.input.items);
}

test "filesystem file picker pipeline drills into a directory and selects a file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/space dir");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "workspace/space dir/item.txt",
        .data = "inside",
    });

    const io_mod = @import("../shared/io.zig");
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);

    const rt = CompletionRuntime(FilesystemFilePickerTestApp);
    var app = FilesystemFilePickerTestApp{
        .alloc = alloc,
        .workspace_root = workspace_root,
    };
    defer app.deinit();

    try app.input_runtime.textReplacementState().replace(alloc, "@./space");
    try std.testing.expectEqual(
        edit_contract.InsertResult.inserted,
        try rt.autocompleteFilePickerSelection(&app, 4096),
    );
    try std.testing.expectEqualStrings(
        "@\"./space dir/",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqualStrings(
        "./space dir/",
        app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state).?.query,
    );

    try app.input_runtime.edit_state.insertSlice(alloc, "item");
    try std.testing.expectEqual(
        edit_contract.InsertResult.inserted,
        try rt.autocompleteFilePickerSelection(&app, 4096),
    );
    try std.testing.expectEqualStrings(
        "@\"./space dir/item.txt\" ",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expect(app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) == null);
}

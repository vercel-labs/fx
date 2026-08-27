const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const registered_entities = @import("../input/registered_entities.zig");
const core_input_runtime = @import("../input/runtime.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const sort_utils = @import("../shared/sort_utils.zig");

pub const ReviewEntry = struct {
    draft: worker_runtime.QueuedPromptDraft,
    pasted_blocks: std.ArrayList(paste_blocks.PastedBlock) = .empty,
    image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,
    dirty: bool = false,

    fn deinit(self: *ReviewEntry, alloc: std.mem.Allocator) void {
        worker_runtime.freeQueuedPromptDraft(alloc, self.draft);
        paste_blocks.deinitBlocks(alloc, &self.pasted_blocks);
        self.image_tokens.deinit(alloc);
    }
};

pub const State = struct {
    entries: []ReviewEntry = &.{},
    selected_index: ?usize = null,
    reason: ?worker_runtime.QueueReviewReason = null,
    visible: bool = false,
    selected_dirty: bool = false,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.clear(alloc);
    }

    pub fn clear(self: *State, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        if (self.entries.len > 0) alloc.free(self.entries);
        self.* = .{};
    }

    pub fn active(self: *const State) bool {
        return self.reason != null;
    }
};

pub const VisibleReviewMeasurement = struct {
    card_rows: u16 = 0,
    editor_active: bool = false,
};

pub fn measureVisibleReviewRows(
    alloc: std.mem.Allocator,
    state: *const State,
    editor_source: visual_layout.Source,
) !VisibleReviewMeasurement {
    if (!state.visible or !state.active() or state.entries.len == 0) return .{};

    var result: VisibleReviewMeasurement = .{};
    for (state.entries, 0..) |entry, entry_index| {
        const editing = state.selected_index != null and state.selected_index.? == entry_index;
        const row_count: u16 = if (editing) blk: {
            result.editor_active = true;
            const summary = visual_layout.summarize(editor_source, null);
            break :blk @intCast(@min(@max(summary.total_rows, 1), std.math.maxInt(u16)));
        } else blk: {
            const draft = entry.draft;
            const display_spans = draft.reviewSkillDisplaySpans();
            var skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty;
            defer skill_tokens.deinit(alloc);
            try skill_tokens.ensureTotalCapacity(alloc, display_spans.len);
            for (display_spans) |span| {
                skill_tokens.appendAssumeCapacity(.{
                    .raw_start = span.raw_start,
                    .raw_end = span.raw_end,
                    .name = span.name,
                    .path = span.path,
                    .display_source = span.display_source,
                    .owns_trailing_separator = span.owns_trailing_separator,
                });
            }
            const summary = visual_layout.summarize(.{
                .input = draft.reviewInput(),
                .cursor = 0,
                .terminal_cols = editor_source.terminal_cols,
                .images = draft.images,
                .pasted_blocks = entry.pasted_blocks.items,
                .image_tokens = entry.image_tokens.items,
                .skill_tokens = skill_tokens.items,
            }, null);
            break :blk @intCast(@min(@max(summary.total_rows, 1), std.math.maxInt(u16)));
        };
        result.card_rows +|= row_count;
    }
    return result;
}

pub const PromptAdmission = enum {
    enqueue,
    replaced,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn requestCancelAndOpen(app: *App) bool {
            return openAfterPause(app, app.worker.requestCancelWithQueueReview());
        }

        pub fn pauseAndOpenAfterModalCancel(app: *App) bool {
            return openAfterPause(app, app.worker.beginQueueReview(.post_cancel));
        }

        pub fn routeVertical(app: *App, direction: visual_layout.Direction) !bool {
            const state = &app.queued_prompt_review;
            if (state.active()) {
                if (state.visible) {
                    const index = state.selected_index orelse return false;
                    switch (direction) {
                        .up => {
                            if (index > 0) {
                                if (state.selected_dirty) try stashSelected(app);
                                state.selected_index = index - 1;
                                loadSelected(app) catch |err| {
                                    state.selected_index = index;
                                    loadSelected(app) catch {};
                                    return err;
                                };
                                traceNavigation(state, "older");
                            }
                        },
                        .down => {
                            if (index + 1 < state.entries.len) {
                                if (state.selected_dirty) try stashSelected(app);
                                state.selected_index = index + 1;
                                loadSelected(app) catch |err| {
                                    state.selected_index = index;
                                    loadSelected(app) catch {};
                                    return err;
                                };
                                traceNavigation(state, "newer");
                            } else {
                                try hideDraft(app);
                            }
                        },
                    }
                    app.shell.render_requests.request(.footer);
                    return true;
                }

                if (direction == .up and composerIsEmpty(app)) {
                    try loadSelected(app);
                    app.shell.render_requests.request(.footer);
                    return true;
                }
                return false;
            }

            if (direction != .up or !composerIsEmpty(app)) return false;
            if (!app.worker.beginQueueReview(.manual)) return false;
            _ = ensureOpen(app, .manual) catch |err| {
                debug_trace.logf("input", "queue review snapshot failed reason=manual err={s}", .{@errorName(err)});
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn markVisibleSelectionDirty(app: *App) void {
            if (!app.queued_prompt_review.visible) return;
            app.queued_prompt_review.selected_dirty = true;
        }

        pub fn hideVisibleDraft(app: *App) !bool {
            if (!app.queued_prompt_review.visible) return false;
            try hideDraft(app);
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn cancelAllHiddenPostCancelQueued(app: *App) bool {
            const state = &app.queued_prompt_review;
            if (!postCancelAllAvailable(app)) return false;
            const dropped = state.entries.len;
            app.worker.clearQueuedPrompts(
                app.alloc,
                app.input_runtime.kill_ring.images.items,
            );
            state.clear(app.alloc);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            releasePendingImages(app);
            debug_trace.eventf("input", "queue_review_cancelled_all", .{}, "dropped={d}", .{dropped});
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn postCancelAllAvailable(app: *const App) bool {
            const state = &app.queued_prompt_review;
            return state.active() and
                state.reason.? == .post_cancel and
                !state.visible and
                composerIsEmpty(app);
        }

        pub fn submitPausedQueueUnchanged(app: *App) !bool {
            if (!app.queued_prompt_review.active() and app.worker.queueReviewReason() == null) return false;
            if (!try commitDirtyEntries(app)) return error.QueuedPromptNoLongerAvailable;
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            releasePendingImages(app);
            finishReview(app, "unchanged_queue");
            return true;
        }

        pub fn deleteEmptyVisibleDraft(app: *App) !bool {
            const state = &app.queued_prompt_review;
            if (!state.visible or !composerIsEmpty(app)) return false;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            const turn_id = state.entries[index].draft.turn_id;
            if (!app.worker.deleteQueuedPromptDraft(
                app.alloc,
                turn_id,
                app.input_runtime.kill_ring.images.items,
            )) {
                return error.QueuedPromptNoLongerAvailable;
            }

            var removed = state.entries[index];
            const remaining_len = state.entries.len - 1;
            if (remaining_len == 0) {
                app.alloc.free(state.entries);
                state.entries = &.{};
                removed.deinit(app.alloc);
                debug_trace.eventf("input", "queue_review_draft_deleted", .{ .turn_id = turn_id }, "remaining=0", .{});
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
                releasePendingImages(app);
                finishReview(app, "deleted_last_prompt");
                return true;
            }

            const next = try app.alloc.alloc(ReviewEntry, remaining_len);
            var next_index: usize = 0;
            for (state.entries, 0..) |entry, entry_index| {
                if (entry_index == index) continue;
                next[next_index] = entry;
                next_index += 1;
            }
            app.alloc.free(state.entries);
            state.entries = next;
            removed.deinit(app.alloc);
            debug_trace.eventf("input", "queue_review_draft_deleted", .{ .turn_id = turn_id }, "remaining={d}", .{remaining_len});

            state.selected_index = @min(index, remaining_len - 1);
            state.visible = false;
            state.selected_dirty = false;
            try loadSelected(app);
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn promptAdmission(
            app: *App,
            review_input: []const u8,
            review_pasted_blocks: []const paste_blocks.PastedBlock,
            review_image_tokens: []const entity_spans.ImageTokenSpan,
            review_skill_tokens: []const registered_entities.SkillTokenSpan,
        ) !PromptAdmission {
            const state = &app.queued_prompt_review;
            if (!state.active() or !state.visible) return .enqueue;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            var pasted_blocks = try dupePastedBlocks(
                app.alloc,
                review_pasted_blocks,
            );
            var pasted_blocks_owned = true;
            defer if (pasted_blocks_owned)
                paste_blocks.deinitBlocks(app.alloc, &pasted_blocks);
            var image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty;
            defer image_tokens.deinit(app.alloc);
            try image_tokens.appendSlice(app.alloc, review_image_tokens);
            try writeSelectedDraft(
                app,
                review_input,
                app.pending_images.items,
                review_skill_tokens,
            );
            paste_blocks.deinitBlocks(
                app.alloc,
                &state.entries[index].pasted_blocks,
            );
            state.entries[index].pasted_blocks = pasted_blocks;
            pasted_blocks = .empty;
            pasted_blocks_owned = false;
            state.entries[index].image_tokens.deinit(app.alloc);
            state.entries[index].image_tokens = image_tokens;
            image_tokens = .empty;
            if (!try commitDirtyEntries(app)) return error.QueuedPromptNoLongerAvailable;

            finishReview(app, "edited_prompts");
            return .replaced;
        }

        pub fn resumeAfterNewPrompt(app: *App) void {
            if (!app.queued_prompt_review.active() and app.worker.queueReviewReason() == null) return;
            finishReview(app, "new_prompt");
        }

        pub fn reset(app: *App) void {
            app.queued_prompt_review.clear(app.alloc);
        }

        fn openAfterPause(app: *App, paused: bool) bool {
            if (!paused) return false;
            if (app.queued_prompt_review.active()) {
                app.queued_prompt_review.reason = .post_cancel;
                return true;
            }
            _ = ensureOpen(app, .post_cancel) catch |err| {
                debug_trace.logf("input", "queue review snapshot failed reason=post_cancel err={s}", .{@errorName(err)});
                app.shell.render_requests.request(.footer);
                return true;
            };
            return true;
        }

        fn ensureOpen(app: *App, reason: worker_runtime.QueueReviewReason) !bool {
            const drafts = try app.worker.snapshotQueuedPromptDrafts(app.alloc);
            if (drafts.len == 0) {
                worker_runtime.freeQueuedPromptDrafts(app.alloc, drafts);
                return false;
            }
            var drafts_owned = true;
            errdefer if (drafts_owned) worker_runtime.freeQueuedPromptDrafts(app.alloc, drafts);

            const entries = try app.alloc.alloc(ReviewEntry, drafts.len);
            var entries_owned = true;
            errdefer if (entries_owned) app.alloc.free(entries);
            for (entries, drafts) |*entry, draft| {
                entry.* = .{ .draft = draft };
            }
            var tokens_initialized: usize = 0;
            errdefer for (entries[0..tokens_initialized]) |*entry| {
                entry.image_tokens.deinit(app.alloc);
            };
            for (entries) |*entry| {
                const has_review_tokens = if (entry.draft.review_draft) |review|
                    review.image_tokens.len > 0
                else
                    false;
                if (!has_review_tokens) {
                    entry.image_tokens = try imageTokensForQueuedPrompt(
                        app.alloc,
                        entry.draft.reviewInput(),
                        entry.draft.images,
                    );
                }
                tokens_initialized += 1;
            }
            for (entries) |*entry| {
                if (entry.draft.review_draft) |*review| {
                    if (review.pasted_blocks.len > 0) {
                        entry.pasted_blocks = .{
                            .items = review.pasted_blocks,
                            .capacity = review.pasted_blocks.len,
                        };
                        review.pasted_blocks = &.{};
                    }
                    if (review.image_tokens.len > 0) {
                        entry.image_tokens = .{
                            .items = review.image_tokens,
                            .capacity = review.image_tokens.len,
                        };
                        review.image_tokens = &.{};
                    }
                }
            }
            app.alloc.free(drafts);
            drafts_owned = false;

            app.queued_prompt_review.clear(app.alloc);
            const show_draft = composerIsEmpty(app);
            app.queued_prompt_review = .{
                .entries = entries,
                .selected_index = entries.len - 1,
                .reason = reason,
                .visible = false,
            };
            entries_owned = false;
            tokens_initialized = 0;
            if (show_draft) try loadSelected(app);
            return true;
        }

        fn loadSelected(app: *App) !void {
            const state = &app.queued_prompt_review;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;
            const entry = &state.entries[index];
            const draft = entry.draft;
            const review_input = draft.reviewInput();
            const review_skill_spans = draft.reviewSkillDisplaySpans();

            const images = try types.dupeImageAttachmentSlice(app.alloc, draft.images);
            var images_transferred = false;
            errdefer if (!images_transferred) types.freeImageAttachmentSlice(app.alloc, images);
            var skill_tokens = try dupeVisualSkillTokens(
                app.alloc,
                review_skill_spans,
            );
            errdefer deinitVisualSkillTokens(app.alloc, &skill_tokens);
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                review_input,
            );
            defer prepared_input.deinit(app.alloc);
            try app.pending_images.ensureTotalCapacity(app.alloc, images.len);

            releasePendingImages(app);
            if (images.len > 0) {
                app.pending_images.appendSliceAssumeCapacity(images);
                app.alloc.free(images);
            }
            images_transferred = true;
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            app.input_runtime.entities.image_tokens.deinit(app.alloc);
            app.input_runtime.entities.image_tokens = entry.image_tokens;
            entry.image_tokens = .empty;
            app.input_runtime.entities.skill_tokens.deinit(app.alloc);
            app.input_runtime.entities.skill_tokens = skill_tokens;
            skill_tokens = .empty;
            paste_blocks.deinitBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.entities.pasted_blocks = entry.pasted_blocks;
            entry.pasted_blocks = .empty;
            state.visible = true;
            state.selected_dirty = false;
        }

        fn stashSelected(app: *App) !void {
            const state = &app.queued_prompt_review;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            try writeSelectedDraft(
                app,
                app.input_runtime.edit_state.input.items,
                app.pending_images.items,
                app.input_runtime.entities.skill_tokens.items,
            );
            paste_blocks.deinitBlocks(app.alloc, &state.entries[index].pasted_blocks);
            state.entries[index].pasted_blocks = app.input_runtime.entities.pasted_blocks;
            app.input_runtime.entities.pasted_blocks = .empty;
            state.entries[index].image_tokens.deinit(app.alloc);
            state.entries[index].image_tokens = app.input_runtime.entities.image_tokens;
            app.input_runtime.entities.image_tokens = .empty;
            debug_trace.eventf(
                "input",
                "queue_review_draft_stashed",
                .{ .turn_id = state.entries[index].draft.turn_id },
                "prompt_bytes={d}",
                .{state.entries[index].draft.prompt.len},
            );
        }

        fn writeSelectedDraft(
            app: *App,
            prompt: []const u8,
            images: []const types.ImageAttachment,
            skill_tokens: []const registered_entities.SkillTokenSpan,
        ) !void {
            const state = &app.queued_prompt_review;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            const prompt_copy = try app.alloc.dupe(u8, prompt);
            errdefer app.alloc.free(prompt_copy);
            const images_copy = try types.dupeImageAttachmentSlice(app.alloc, images);
            errdefer types.freeImageAttachmentSlice(app.alloc, images_copy);
            const skill_display_spans = try dupeSkillDisplaySpans(app.alloc, skill_tokens);
            errdefer worker_runtime.freeSkillDisplaySpans(app.alloc, skill_display_spans);

            const draft = &state.entries[index].draft;
            types.freeImageAttachmentSlice(app.alloc, draft.images);
            if (draft.review_draft) |review| {
                worker_runtime.freeQueueReviewDraft(app.alloc, review);
            }
            draft.images = images_copy;
            draft.review_draft = .{
                .input = prompt_copy,
                .skill_display_spans = skill_display_spans,
            };
            state.entries[index].dirty = true;
            state.selected_dirty = false;
        }

        fn commitDirtyEntries(app: *App) !bool {
            const drafts = try buildDirtyDraftsForCommit(app);
            defer worker_runtime.freeQueuedPromptDrafts(app.alloc, drafts);
            if (drafts.len == 0) return true;
            if (!try app.worker.replaceQueuedPromptDrafts(app.alloc, drafts)) return false;
            debug_trace.eventf("input", "queue_review_batch_committed", .{}, "updated={d}", .{drafts.len});
            return true;
        }

        fn buildDirtyDraftsForCommit(app: *App) ![]worker_runtime.QueuedPromptDraft {
            const state = &app.queued_prompt_review;
            var dirty_count: usize = 0;
            for (state.entries) |entry| dirty_count += @intFromBool(entry.dirty);
            if (dirty_count == 0) return &.{};

            const commits = try app.alloc.alloc(worker_runtime.QueuedPromptDraft, dirty_count);
            var filled: usize = 0;
            errdefer {
                for (commits[0..filled]) |draft| worker_runtime.freeQueuedPromptDraft(app.alloc, draft);
                app.alloc.free(commits);
            }
            for (state.entries) |entry| {
                if (!entry.dirty) continue;
                const review_input = entry.draft.reviewInput();
                const review_skill_spans = entry.draft.reviewSkillDisplaySpans();
                const expanded = try paste_blocks.expand(
                    app.alloc,
                    review_input,
                    entry.pasted_blocks.items,
                );
                defer if (expanded.owned) app.alloc.free(expanded.text);
                const trimmed = std.mem.trim(u8, expanded.text, " \t\r\n");
                const prompt_copy = try app.alloc.dupe(u8, trimmed);
                errdefer app.alloc.free(prompt_copy);
                const images_copy = try types.dupeImageAttachmentSlice(app.alloc, entry.draft.images);
                errdefer types.freeImageAttachmentSlice(app.alloc, images_copy);
                const spans_copy = try projectSkillDisplaySpansForCommit(
                    app.alloc,
                    review_input,
                    expanded.text,
                    entry.pasted_blocks.items,
                    review_skill_spans,
                );
                errdefer worker_runtime.freeSkillDisplaySpans(
                    app.alloc,
                    spans_copy,
                );
                const review_draft = try worker_runtime.dupeQueueReviewDraft(
                    app.alloc,
                    .{
                        .input = @constCast(review_input),
                        .pasted_blocks = entry.pasted_blocks.items,
                        .image_tokens = entry.image_tokens.items,
                        .skill_display_spans = @constCast(review_skill_spans),
                    },
                );
                commits[filled] = .{
                    .turn_id = entry.draft.turn_id,
                    .prompt = prompt_copy,
                    .images = images_copy,
                    .skill_display_spans = spans_copy,
                    .review_draft = review_draft,
                };
                filled += 1;
            }
            return commits;
        }

        fn hideDraft(app: *App) !void {
            if (app.queued_prompt_review.selected_dirty) try stashSelected(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            releasePendingImages(app);
            app.queued_prompt_review.visible = false;
            app.queued_prompt_review.selected_dirty = false;
            debug_trace.eventf("input", "queue_review_hidden", .{}, "queued={d}", .{app.queued_prompt_review.entries.len});
        }

        fn finishReview(app: *App, source: []const u8) void {
            const queued = app.queued_prompt_review.entries.len;
            app.queued_prompt_review.clear(app.alloc);
            _ = app.worker.resumeQueueReview();
            debug_trace.eventf("input", "queue_review_finished", .{}, "source={s} queued={d}", .{ source, queued });
            app.shell.render_requests.request(.footer);
        }

        fn releasePendingImages(app: *App) void {
            if (comptime @hasDecl(App, "releasePendingImages")) {
                App.releasePendingImages(app);
            } else {
                app.clearPendingImages();
            }
        }

        fn composerIsEmpty(app: *const App) bool {
            return app.input_runtime.edit_state.input.items.len == 0 and app.pending_images.items.len == 0;
        }

        fn traceNavigation(state: *const State, direction: []const u8) void {
            const index = state.selected_index orelse return;
            debug_trace.eventf("input", "queue_review_navigate", .{}, "direction={s} index={d} count={d}", .{ direction, index, state.entries.len });
        }
    };
}

fn dupePastedBlocks(
    alloc: std.mem.Allocator,
    blocks: []const paste_blocks.PastedBlock,
) !std.ArrayList(paste_blocks.PastedBlock) {
    var copy: std.ArrayList(paste_blocks.PastedBlock) = .empty;
    errdefer paste_blocks.deinitBlocks(alloc, &copy);
    try copy.ensureTotalCapacity(alloc, blocks.len);
    for (blocks) |block| {
        const text = try alloc.dupe(u8, block.text);
        errdefer alloc.free(text);
        copy.appendAssumeCapacity(.{
            .id = block.id,
            .text = text,
            .line_count = block.line_count,
            .span = block.span,
        });
    }
    return copy;
}

fn imageTokensForQueuedPrompt(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    images: []const types.ImageAttachment,
) !std.ArrayList(entity_spans.ImageTokenSpan) {
    var tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty;
    errdefer tokens.deinit(alloc);
    try tokens.ensureTotalCapacity(alloc, images.len);

    for (images) |image| {
        var match_start: ?usize = null;
        var match_end: usize = 0;
        var count: usize = 0;
        var raw_start: usize = 0;
        while (raw_start < prompt.len) {
            const match = image_attachments.matchImagePlaceholder(
                prompt,
                raw_start,
            ) orelse {
                raw_start += 1;
                continue;
            };
            if (match.id == image.id) {
                count += 1;
                match_start = raw_start;
                match_end = raw_start + match.length;
            }
            raw_start += match.length;
        }
        if (count != 1) {
            debug_trace.logf(
                "input",
                "queued image span reconstruction skipped id={d} matches={d}",
                .{ image.id, count },
            );
            continue;
        }
        tokens.appendAssumeCapacity(.{
            .id = image.id,
            .span = .{
                .raw_start = match_start.?,
                .raw_end = match_end,
            },
        });
    }
    sort_utils.sort(
        entity_spans.ImageTokenSpan,
        tokens.items,
        {},
        struct {
            fn lessThan(_: void, lhs: entity_spans.ImageTokenSpan, rhs: entity_spans.ImageTokenSpan) bool {
                return lhs.span.raw_start < rhs.span.raw_start;
            }
        }.lessThan,
    );
    return tokens;
}

fn dupeVisualSkillTokens(
    alloc: std.mem.Allocator,
    spans: []const worker_runtime.SkillDisplaySpan,
) !std.ArrayList(registered_entities.SkillTokenSpan) {
    var tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty;
    errdefer deinitVisualSkillTokens(alloc, &tokens);
    try tokens.ensureTotalCapacity(alloc, spans.len);
    for (spans) |span| {
        const name = try alloc.dupe(u8, span.name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, span.path);
        tokens.appendAssumeCapacity(.{
            .raw_start = span.raw_start,
            .raw_end = span.raw_end,
            .name = name,
            .path = path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        });
    }
    return tokens;
}

fn deinitVisualSkillTokens(alloc: std.mem.Allocator, tokens: *std.ArrayList(registered_entities.SkillTokenSpan)) void {
    for (tokens.items) |token| {
        alloc.free(token.name);
        alloc.free(token.path);
    }
    tokens.deinit(alloc);
    tokens.* = .empty;
}

fn dupeSkillDisplaySpans(
    alloc: std.mem.Allocator,
    tokens: []const registered_entities.SkillTokenSpan,
) ![]worker_runtime.SkillDisplaySpan {
    if (tokens.len == 0) return &.{};
    const spans = try alloc.alloc(worker_runtime.SkillDisplaySpan, tokens.len);
    var filled: usize = 0;
    errdefer {
        for (spans[0..filled]) |span| {
            alloc.free(span.name);
            alloc.free(span.path);
        }
        alloc.free(spans);
    }
    while (filled < tokens.len) : (filled += 1) {
        const name = try alloc.dupe(u8, tokens[filled].name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, tokens[filled].path);
        spans[filled] = .{
            .raw_start = tokens[filled].raw_start,
            .raw_end = tokens[filled].raw_end,
            .name = name,
            .path = path,
            .display_source = tokens[filled].display_source,
            .owns_trailing_separator = tokens[filled].owns_trailing_separator,
        };
    }
    return spans;
}

fn projectSkillDisplaySpansForCommit(
    alloc: std.mem.Allocator,
    raw_input: []const u8,
    expanded_text: []const u8,
    pasted_blocks: []const paste_blocks.PastedBlock,
    spans: []const worker_runtime.SkillDisplaySpan,
) ![]worker_runtime.SkillDisplaySpan {
    if (spans.len == 0) return &.{};

    const trimmed = std.mem.trim(u8, expanded_text, " \t\r\n");
    const trim_start = expanded_text.len - std.mem.trimStart(u8, expanded_text, " \t\r\n").len;
    var projected: std.ArrayList(worker_runtime.SkillDisplaySpan) = .empty;
    errdefer {
        for (projected.items) |span| {
            alloc.free(span.name);
            alloc.free(span.path);
        }
        projected.deinit(alloc);
    }

    for (spans) |span| {
        const start = paste_blocks.projectOffsetThroughExpansion(raw_input, pasted_blocks, span.raw_start) orelse continue;
        const end = paste_blocks.projectOffsetThroughExpansion(raw_input, pasted_blocks, span.raw_end) orelse continue;
        if (start < trim_start or end < start or end - trim_start > trimmed.len) continue;
        const name = try alloc.dupe(u8, span.name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, span.path);
        errdefer alloc.free(path);
        try projected.append(alloc, .{
            .raw_start = start - trim_start,
            .raw_end = end - trim_start,
            .name = name,
            .path = path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        });
    }

    if (projected.items.len == 0) {
        projected.deinit(alloc);
        return &.{};
    }
    return projected.toOwnedSlice(alloc);
}

const kill_ring = @import("../input/kill_ring.zig");
const render_request = @import("../../ui/render_request.zig");

const ReviewTestShell = struct {
    render_requests: render_request.RenderRequestState = .{},
};

const ReviewTestApp = struct {
    alloc: std.mem.Allocator,
    worker: worker_runtime.WorkerRuntime = .{},
    queued_prompt_review: State = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    shell: ReviewTestShell = .{},

    fn deinit(self: *ReviewTestApp) void {
        self.queued_prompt_review.deinit(self.alloc);
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.worker.deinit(self.alloc);
    }

    pub fn clearPendingImages(self: *ReviewTestApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }
};

fn makeReviewTestPrompt(alloc: std.mem.Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    const prompt = try alloc.dupe(u8, text);
    errdefer alloc.free(prompt);
    const model = try alloc.dupe(u8, "test/model");
    errdefer alloc.free(model);
    const api_key = try alloc.dupe(u8, "key");
    errdefer alloc.free(api_key);
    const history = try alloc.alloc(types.HistoryTurn, 0);
    errdefer alloc.free(history);
    const grants = try alloc.alloc(types.PermissionGrant, 0);
    return .{
        .prompt = prompt,
        .images = &.{},
        .model = model,
        .api_key = api_key,
        .permission_mode = .auto,
        .history = history,
        .grants = grants,
    };
}

fn openQueueReviewWithSemanticImageTokens(alloc: std.mem.Allocator) !void {
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();

    {
        var prompt = try makeReviewTestPrompt(alloc, "[Image #1]");
        errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);
        const images = [_]types.ImageAttachment{.{
            .id = 1,
            .path = @constCast("/tmp/one.png"),
            .media_type = @constCast("image/png"),
        }};
        prompt.images = try types.dupeImageAttachmentSlice(alloc, &images);
        const tokens = [_]entity_spans.ImageTokenSpan{.{
            .id = 1,
            .span = .{ .raw_start = 0, .raw_end = "[Image #1]".len },
        }};
        prompt.review_draft = try worker_runtime.dupeQueueReviewDraft(
            alloc,
            .{
                .input = prompt.prompt,
                .image_tokens = @constCast(&tokens),
            },
        );
        try app.worker.enqueuePrompt(alloc, prompt);
    }
    {
        var prompt = try makeReviewTestPrompt(alloc, "[Image #2]");
        errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);
        const images = [_]types.ImageAttachment{.{
            .id = 2,
            .path = @constCast("/tmp/two.png"),
            .media_type = @constCast("image/png"),
        }};
        prompt.images = try types.dupeImageAttachmentSlice(alloc, &images);
        prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(
            alloc,
            &images,
        );
        try app.worker.enqueuePrompt(alloc, prompt);
    }

    try std.testing.expect(app.worker.beginQueueReview(.manual));
    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.ensureOpen(&app, .manual));
}

test "queued prompt review releases semantic image tokens once on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        openQueueReviewWithSemanticImageTokens,
        .{},
    );
}

test "queued prompt review navigates newest to oldest and stays paused when hidden" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "second queued"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings("second queued", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(worker_runtime.QueueReviewReason.manual, app.worker.queueReviewReason().?);

    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings("first queued", app.input_runtime.edit_state.input.items);
    try std.testing.expect(try rt.routeVertical(&app, .down));
    try std.testing.expectEqualStrings("second queued", app.input_runtime.edit_state.input.items);

    try std.testing.expect(try rt.routeVertical(&app, .down));
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expect(app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() != null);

    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings("second queued", app.input_runtime.edit_state.input.items);
    try app.input_runtime.edit_state.input.appendSlice(alloc, " edited");
    var placeholder_buf: [64]u8 = undefined;
    const placeholder = try paste_blocks.formatPlaceholder(&placeholder_buf, 7, 2);
    try app.input_runtime.edit_state.input.append(alloc, ' ');
    try app.input_runtime.edit_state.input.appendSlice(alloc, placeholder);
    try app.input_runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "pasted\ncontent"),
        .line_count = 2,
    });
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    rt.markVisibleSelectionDirty(&app);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings("first queued", app.input_runtime.edit_state.input.items);
    try std.testing.expect(try rt.routeVertical(&app, .down));
    try std.testing.expectEqualStrings("second queued edited [Pasted text #7, 2 lines]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings("pasted\ncontent", app.input_runtime.entities.pasted_blocks.items[0].text);

    const worker_drafts = try app.worker.snapshotQueuedPromptDrafts(alloc);
    defer worker_runtime.freeQueuedPromptDrafts(alloc, worker_drafts);
    try std.testing.expectEqualStrings("second queued", worker_drafts[1].prompt);
}

test "visible queue review measurement aggregates stored cards and the live editor" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first\nsecond"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "selected"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try app.input_runtime.textReplacementState().replace(alloc, "selected\nthird\nfourth");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    const measured = try measureVisibleReviewRows(
        alloc,
        &app.queued_prompt_review,
        .{
            .input = app.input_runtime.edit_state.input.items,
            .cursor = app.input_runtime.edit_state.cursor,
            .terminal_cols = 80,
            .images = app.pending_images.items,
            .pasted_blocks = app.input_runtime.entities.pasted_blocks.items,
            .image_tokens = app.input_runtime.entities.image_tokens.items,
            .skill_tokens = app.input_runtime.entities.skill_tokens.items,
        },
    );

    try std.testing.expectEqual(@as(u16, 5), measured.card_rows);
    try std.testing.expect(measured.editor_active);
}

test "visible queue review aggregate matches composed entity-aware rows" {
    const alloc = std.testing.allocator;
    const queue_input_presentation = @import("../../ui/footer/input_presentation.zig");
    const stored = "$skill [Image #1] [Pasted text #2, 2 lines] 界界界";
    const image_label = "[Image #1]";
    const paste_label = "[Pasted text #2, 2 lines]";
    const image_start = std.mem.find(u8, stored, image_label).?;
    const paste_start = std.mem.find(u8, stored, paste_label).?;
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/one.png"),
        .media_type = @constCast("image/png"),
    }};
    var display_spans = [_]worker_runtime.SkillDisplaySpan{.{
        .raw_start = 0,
        .raw_end = "$skill".len,
        .name = @constCast("skill"),
        .path = @constCast("/tmp/skill/SKILL.md"),
        .display_source = .global_fx,
    }};
    var pasted = [_]paste_blocks.PastedBlock{.{
        .id = 2,
        .text = @constCast("pasted first\npasted second"),
        .line_count = 2,
        .span = .{ .raw_start = paste_start, .raw_end = paste_start + paste_label.len },
    }};
    var image_tokens = [_]entity_spans.ImageTokenSpan{.{
        .id = 1,
        .span = .{ .raw_start = image_start, .raw_end = image_start + image_label.len },
    }};
    var entries = [_]ReviewEntry{
        .{
            .draft = .{
                .turn_id = 1,
                .prompt = @constCast(stored),
                .images = &images,
                .skill_display_spans = &display_spans,
            },
            .pasted_blocks = .{ .items = &pasted, .capacity = pasted.len },
            .image_tokens = .{ .items = &image_tokens, .capacity = image_tokens.len },
        },
        .{ .draft = .{
            .turn_id = 2,
            .prompt = @constCast("selected"),
            .images = &.{},
            .skill_display_spans = &.{},
        } },
    };
    const state = State{
        .entries = &entries,
        .selected_index = 1,
        .reason = .manual,
        .visible = true,
    };
    const live_input = "live 界 editor wraps here";
    const live_source = visual_layout.Source{
        .input = live_input,
        .cursor = live_input.len,
        .terminal_cols = 18,
    };

    const measured = try measureVisibleReviewRows(alloc, &state, live_source);
    var stored_skill_tokens = [_]registered_entities.SkillTokenSpan{.{
        .raw_start = 0,
        .raw_end = "$skill".len,
        .name = "skill",
        .path = "/tmp/skill/SKILL.md",
        .display_source = .global_fx,
    }};
    const stored_card = try queue_input_presentation.composeQueuedPromptCard(alloc, .{
        .input = stored,
        .cursor = 0,
        .terminal_cols = 18,
        .images = &images,
        .pasted_blocks = &pasted,
        .image_tokens = &image_tokens,
        .skill_tokens = &stored_skill_tokens,
    });
    defer alloc.free(stored_card);
    const live_card = try queue_input_presentation.composeQueuedPromptCard(alloc, live_source);
    defer alloc.free(live_card);
    const expected_rows: u16 = @intCast(
        std.mem.count(u8, stored_card, "\n") + std.mem.count(u8, live_card, "\n"),
    );

    try std.testing.expectEqual(expected_rows, measured.card_rows);
    try std.testing.expect(measured.editor_active);
}

fn measureVisibleReviewRowsWithSkillScratch(alloc: std.mem.Allocator) !void {
    var display_spans = [_]worker_runtime.SkillDisplaySpan{.{
        .raw_start = 0,
        .raw_end = "$skill".len,
        .name = @constCast("skill"),
        .path = @constCast("/tmp/skill/SKILL.md"),
    }};
    var entries = [_]ReviewEntry{.{ .draft = .{
        .turn_id = 1,
        .prompt = @constCast("$skill"),
        .images = &.{},
        .skill_display_spans = &display_spans,
    } }};
    const state = State{
        .entries = &entries,
        .reason = .manual,
        .visible = true,
    };
    const measured = try measureVisibleReviewRows(alloc, &state, .{
        .input = "",
        .cursor = 0,
        .terminal_cols = 20,
    });
    try std.testing.expectEqual(@as(u16, 1), measured.card_rows);
}

test "visible queue review measurement cleans scratch on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        measureVisibleReviewRowsWithSkillScratch,
        .{},
    );
}

test "queued prompt review restores compact paste and commits expanded execution" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();

    const placeholder = "[Pasted text #4, 1 line]";
    const compact = "before " ++ placeholder ++ " after";
    const backing = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    const expanded = "before " ++ backing ++ " after";
    var prompt = try makeReviewTestPrompt(alloc, expanded);
    errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);
    var blocks = [_]paste_blocks.PastedBlock{.{
        .id = 4,
        .text = @constCast(backing),
        .line_count = 1,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before ".len + placeholder.len,
        },
    }};
    prompt.review_draft = try worker_runtime.dupeQueueReviewDraft(alloc, .{
        .input = @constCast(compact),
        .pasted_blocks = &blocks,
    });
    try app.worker.enqueuePrompt(alloc, prompt);

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings(compact, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(
        backing,
        app.input_runtime.entities.pasted_blocks.items[0].text,
    );
    try app.input_runtime.edit_state.input.appendSlice(alloc, " edited");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    rt.markVisibleSelectionDirty(&app);

    try std.testing.expectEqual(
        PromptAdmission.replaced,
        try rt.promptAdmission(
            &app,
            app.input_runtime.edit_state.input.items,
            app.input_runtime.entities.pasted_blocks.items,
            app.input_runtime.entities.image_tokens.items,
            app.input_runtime.entities.skill_tokens.items,
        ),
    );
    const drafts = try app.worker.snapshotQueuedPromptDrafts(alloc);
    defer worker_runtime.freeQueuedPromptDrafts(alloc, drafts);
    try std.testing.expectEqualStrings(expanded ++ " edited", drafts[0].prompt);
    try std.testing.expectEqualStrings(
        compact ++ " edited",
        drafts[0].review_draft.?.input,
    );
    try std.testing.expectEqualStrings(
        backing,
        drafts[0].review_draft.?.pasted_blocks[0].text,
    );
}

test "queued prompt review direct commit preserves image token provenance" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();

    {
        var prompt = try makeReviewTestPrompt(alloc, "inspect [Image #7]");
        errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);
        const images = [_]types.ImageAttachment{.{
            .id = 7,
            .path = @constCast("/tmp/seven.png"),
            .media_type = @constCast("image/png"),
        }};
        prompt.images = try types.dupeImageAttachmentSlice(alloc, &images);
        prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(
            alloc,
            &images,
        );
        try app.worker.enqueuePrompt(alloc, prompt);
    }

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(
        PromptAdmission.replaced,
        try rt.promptAdmission(
            &app,
            app.input_runtime.edit_state.input.items,
            app.input_runtime.entities.pasted_blocks.items,
            app.input_runtime.entities.image_tokens.items,
            app.input_runtime.entities.skill_tokens.items,
        ),
    );

    const drafts = try app.worker.snapshotQueuedPromptDrafts(alloc);
    defer worker_runtime.freeQueuedPromptDrafts(alloc, drafts);
    try std.testing.expectEqual(@as(usize, 1), drafts.len);
    try std.testing.expectEqual(@as(usize, 1), drafts[0].review_draft.?.image_tokens.len);
    try std.testing.expectEqual(@as(usize, 7), drafts[0].review_draft.?.image_tokens[0].id);
    try std.testing.expectEqual(
        @as(usize, "inspect ".len),
        drafts[0].review_draft.?.image_tokens[0].span.raw_start,
    );
    try std.testing.expectEqual(
        @as(usize, "inspect [Image #7]".len),
        drafts[0].review_draft.?.image_tokens[0].span.raw_end,
    );
}

test "one confirmation commits edits stashed across multiple queued prompts" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "second queued"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try app.input_runtime.edit_state.input.appendSlice(alloc, " edited");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    rt.markVisibleSelectionDirty(&app);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings("first queued", app.input_runtime.edit_state.input.items);

    try std.testing.expectEqual(
        PromptAdmission.replaced,
        try rt.promptAdmission(
            &app,
            "first queued edited",
            &.{},
            &.{},
            &.{},
        ),
    );
    try std.testing.expect(!app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() == null);

    const drafts = try app.worker.snapshotQueuedPromptDrafts(alloc);
    defer worker_runtime.freeQueuedPromptDrafts(alloc, drafts);
    try std.testing.expectEqualStrings("first queued edited", drafts[0].prompt);
    try std.testing.expectEqualStrings("second queued edited", drafts[1].prompt);
}

test "new prompt after a hidden review appends in FIFO order and resumes admission" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "second queued"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expect(try rt.hideVisibleDraft(&app));
    try std.testing.expect(app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() != null);

    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "new queued"));
    rt.resumeAfterNewPrompt(&app);
    try std.testing.expect(!app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() == null);

    const drafts = try app.worker.snapshotQueuedPromptDrafts(alloc);
    defer worker_runtime.freeQueuedPromptDrafts(alloc, drafts);
    try std.testing.expectEqual(@as(usize, 3), drafts.len);
    try std.testing.expectEqualStrings("first queued", drafts[0].prompt);
    try std.testing.expectEqualStrings("second queued", drafts[1].prompt);
    try std.testing.expectEqualStrings("new queued", drafts[2].prompt);
}

test "empty submit resumes a hidden review without changing queued prompts" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "second queued"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expect(try rt.hideVisibleDraft(&app));
    try std.testing.expect(try rt.submitPausedQueueUnchanged(&app));
    try std.testing.expect(!app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() == null);

    const drafts = try app.worker.snapshotQueuedPromptDrafts(alloc);
    defer worker_runtime.freeQueuedPromptDrafts(alloc, drafts);
    try std.testing.expectEqual(@as(usize, 2), drafts.len);
    try std.testing.expectEqualStrings("first queued", drafts[0].prompt);
    try std.testing.expectEqualStrings("second queued", drafts[1].prompt);
}

test "backspace deletion removes only the visible empty draft and keeps review paused" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "second queued"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    app.input_runtime.inputResetState().clearCurrent(alloc);
    try std.testing.expect(try rt.deleteEmptyVisibleDraft(&app));
    try std.testing.expectEqualStrings("first queued", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.worker.queuedPromptCount());
    try std.testing.expect(app.worker.queueReviewReason() != null);

    app.input_runtime.inputResetState().clearCurrent(alloc);
    try std.testing.expect(try rt.deleteEmptyVisibleDraft(&app));
    try std.testing.expectEqual(@as(usize, 0), app.worker.queuedPromptCount());
    try std.testing.expect(!app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() == null);
}

test "queued image line kill survives deleting its queue card and yanks verified bytes" {
    const alloc = std.testing.allocator;
    const original_bytes = "\x89PNG\r\n\x1a\nqueued image";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var source = try tmp.dir.createFile(std.testing.io, "source.png", .{});
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, original_bytes);
    }
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "source.png");
    defer alloc.free(source_path);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    {
        var prompt = try makeReviewTestPrompt(alloc, "describe [Image #1]");
        errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);
        const images = try alloc.alloc(types.ImageAttachment, 1);
        var images_owned = true;
        errdefer if (images_owned) alloc.free(images);
        images[0] = try image_attachments.loadImageAttachment(alloc, source_path);
        var image_owned = true;
        errdefer if (image_owned) {
            image_attachments.discardImageAttachment(alloc, images[0]);
        };
        images[0].id = 1;
        try image_attachments.captureImageSnapshot(alloc, &images[0], snapshot_dir);
        prompt.images = images;
        image_owned = false;
        images_owned = false;
        prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(
            alloc,
            prompt.images,
        );
        try app.worker.enqueuePrompt(alloc, prompt);
    }
    try tmp.dir.deleteFile(std.testing.io, "source.png");

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(try rt.routeVertical(&app, .up));
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try std.testing.expect(try app.input_runtime.killRingState(
        &app.pending_images,
    ).delete(
        alloc,
        .line_start,
    ));
    try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.kill_ring.images.items.len);
    const retained_snapshot = app.input_runtime.kill_ring.images.items[0].snapshot_path.?;

    try std.testing.expect(try rt.deleteEmptyVisibleDraft(&app));
    try std.testing.expectEqual(@as(usize, 0), app.worker.queuedPromptCount());
    try std.Io.Dir.accessAbsolute(std.testing.io, retained_snapshot, .{});

    try std.testing.expectEqual(
        kill_ring.YankResult{ .inserted = 1 },
        try app.input_runtime.killRingState(&app.pending_images).yank(
            alloc,
            2,
            4096,
        ),
    );
    try std.testing.expectEqualStrings("describe [Image #2]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items[0].id);
    var verified = try image_attachments.loadVerifiedSnapshot(
        alloc,
        app.pending_images.items[0],
        .{},
    );
    defer verified.deinit(alloc);
    try std.testing.expectEqualSlices(u8, original_bytes, verified.bytes);
}

test "hidden post-cancel review can discard every queued prompt with Escape action" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "second queued"));

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(rt.pauseAndOpenAfterModalCancel(&app));
    try std.testing.expectEqual(worker_runtime.QueueReviewReason.post_cancel, app.queued_prompt_review.reason.?);
    try std.testing.expect(app.queued_prompt_review.visible);
    try std.testing.expect(try rt.hideVisibleDraft(&app));
    try std.testing.expect(rt.postCancelAllAvailable(&app));
    try std.testing.expect(rt.cancelAllHiddenPostCancelQueued(&app));
    try std.testing.expectEqual(@as(usize, 0), app.worker.queuedPromptCount());
    try std.testing.expect(!app.queued_prompt_review.active());
    try std.testing.expect(app.worker.queueReviewReason() == null);
}

test "post-cancel review opens newest queued prompt with images and skills" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();
    try app.worker.enqueuePrompt(alloc, try makeReviewTestPrompt(alloc, "first queued"));
    {
        var second = try makeReviewTestPrompt(
            alloc,
            "second $review$review [Image #1]",
        );
        errdefer worker_runtime.freeQueuedPrompt(alloc, second);
        {
            const images = try alloc.alloc(types.ImageAttachment, 1);
            errdefer alloc.free(images);
            const image_path = try alloc.dupe(u8, "/tmp/review.png");
            errdefer alloc.free(image_path);
            const media_type = try alloc.dupe(u8, "image/png");
            errdefer alloc.free(media_type);

            const spans = try alloc.alloc(worker_runtime.SkillDisplaySpan, 1);
            errdefer alloc.free(spans);
            const skill_name = try alloc.dupe(u8, "review");
            errdefer alloc.free(skill_name);
            const skill_path = try alloc.dupe(u8, "/tmp/review-skill");

            images[0] = .{ .id = 1, .path = image_path, .media_type = media_type };
            spans[0] = .{
                .raw_start = "second ".len,
                .raw_end = "second $review".len,
                .name = skill_name,
                .path = skill_path,
            };
            second.images = images;
            second.skill_display_spans = spans;
        }
        try app.worker.enqueuePrompt(alloc, second);
    }

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(rt.requestCancelAndOpen(&app));
    try std.testing.expect(app.worker.isCancelRequested());
    try std.testing.expectEqual(worker_runtime.QueueReviewReason.post_cancel, app.worker.queueReviewReason().?);
    try std.testing.expectEqualStrings(
        "second $review$review [Image #1]",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqualStrings("/tmp/review.png", app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items[0].id);
    try std.testing.expectEqual(
        @as(usize, "second $review$review ".len),
        app.input_runtime.entities.image_tokens.items[0].span.raw_start,
    );
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("review", app.input_runtime.entities.skill_tokens.items[0].name);
    try std.testing.expectEqual(@as(usize, "second ".len), app.input_runtime.entities.skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, "second $review".len), app.input_runtime.entities.skill_tokens.items[0].raw_end);

    try app.input_runtime.insertionState().insertSlice(alloc, " [Image #1]", .preserve);
    rt.markVisibleSelectionDirty(&app);
    try std.testing.expect(try rt.hideVisibleDraft(&app));
    try std.testing.expect(try rt.routeVertical(&app, .up));
    try std.testing.expectEqualStrings(
        "second $review$review [Image #1] [Image #1]",
        app.input_runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(
        @as(usize, "second $review$review ".len),
        app.input_runtime.entities.image_tokens.items[0].span.raw_start,
    );
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqual(@as(usize, "second ".len), app.input_runtime.entities.skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, "second $review".len), app.input_runtime.entities.skill_tokens.items[0].raw_end);
}

test "post-cancel review restores reversed image appearance order with stable ids" {
    const alloc = std.testing.allocator;
    var app = ReviewTestApp{ .alloc = alloc };
    defer app.deinit();

    var prompt = try makeReviewTestPrompt(alloc, "[Image #2] [Image #1]");
    errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);
    const source_images = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/two.png"), .media_type = @constCast("image/png") },
        .{ .id = 1, .path = @constCast("/tmp/one.png"), .media_type = @constCast("image/png") },
    };
    prompt.images = try types.dupeImageAttachmentSlice(alloc, &source_images);
    try app.worker.enqueuePrompt(alloc, prompt);

    const rt = Runtime(ReviewTestApp);
    try std.testing.expect(rt.requestCancelAndOpen(&app));
    try std.testing.expectEqualStrings("[Image #2] [Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.pending_images.items[0].id);
    try std.testing.expectEqualStrings("/tmp/two.png", app.pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items[1].id);
    try std.testing.expectEqualStrings("/tmp/one.png", app.pending_images.items[1].path);
}

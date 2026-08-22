const std = @import("std");
const paste_blocks = @import("../input/pasted_blocks.zig");
const registered_entities = @import("../input/registered_entities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const io_mod = @import("../shared/io.zig");
const provider_runtime = @import("provider_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const types = @import("../shared/types.zig");
const input_queue_runtime = @import("input_queue_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");

pub fn SubmitRuntime(comptime App: type) type {
    return struct {
        const queue_rt = input_queue_runtime.Runtime(App);
        const completion_rt = input_completion_runtime.CompletionRuntime(App);

        const AcceptedDraftProjection = struct {
            input: []const u8,
            pasted_blocks: std.ArrayList(paste_blocks.PastedBlock) = .empty,
            image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,
            skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty,

            fn deinit(self: *AcceptedDraftProjection, alloc: std.mem.Allocator) void {
                self.pasted_blocks.deinit(alloc);
                self.image_tokens.deinit(alloc);
                self.skill_tokens.deinit(alloc);
                self.* = undefined;
            }
        };

        pub fn submitInput(app: *App, max_prompt_history: usize) !void {
            try submit(app, max_prompt_history);
        }

        pub fn submit(app: *App, max_prompt_history: usize) !void {
            const expanded_len = paste_blocks.expandedLen(
                app.input_runtime.edit_state.input.items,
                app.input_runtime.entities.pasted_blocks.items,
            ) orelse std.math.maxInt(usize);
            const max_input_len = if (comptime @hasDecl(App, "input_limits"))
                App.input_limits.composer_bytes
            else if (comptime @hasDecl(App, "input_byte_limit"))
                App.input_byte_limit
            else
                std.math.maxInt(usize);
            if (expanded_len > max_input_len) {
                try input_limit_feedback.report(
                    App,
                    app,
                    .composer,
                    expanded_len,
                );
                return;
            }

            const expanded = try paste_blocks.expand(app.alloc, app.input_runtime.edit_state.input.items, app.input_runtime.entities.pasted_blocks.items);
            defer if (expanded.owned) app.alloc.free(expanded.text);

            if (directCommand(expanded.text)) |command| {
                if (comptime @hasDecl(App, "submitDirectTerminal")) {
                    try App.submitDirectTerminal(app, command);
                    return;
                }
            }

            const left_trimmed = std.mem.trimStart(u8, expanded.text, " \t\r\n");
            const resolved_slash_submission = resolvedSlashSubmission(app, left_trimmed);
            if (knownSlashCommand(app, resolved_slash_submission)) |command| {
                if (requiresPromptCredential(command, resolved_slash_submission) and !try preflightPrompt(app)) return;
                try submitSlashCommand(app, left_trimmed, null, max_prompt_history);
                return;
            }
            if (shouldRouteUnknownSlashCommand(app, resolved_slash_submission)) {
                try submitSlashCommand(app, left_trimmed, null, max_prompt_history);
                return;
            }
            if (pendingImagesPrefixEnd(
                app.input_runtime.edit_state.input.items,
                expanded.text,
                app.input_runtime.entities.pasted_blocks.items,
                app.input_runtime.entities.image_tokens.items,
                app.pending_images.items,
            )) |command_start| {
                const command_text = expanded.text[command_start..];
                if (knownSlashCommand(app, command_text)) |command| {
                    if (requiresPromptCredential(command, command_text) and !try preflightPrompt(app)) return;
                    try submitSlashCommand(
                        app,
                        command_text,
                        expanded.text[0..command_start],
                        max_prompt_history,
                    );
                    return;
                }
            }

            const trimmed = std.mem.trim(u8, expanded.text, " \t\r\n");

            if (trimmed.len == 0) {
                if (app.pending_images.items.len > 0) {
                    if (!try preflightPrompt(app)) return;
                    if (!try enqueuePromptForSubmit(app, "", &.{}, null)) return;
                    releasePendingImages(app);
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                    if (acceptedPromptNeedsImmediateFooter(app)) {
                        app.shell.render_requests.request(.footer);
                    }
                    return;
                }
                if (comptime @hasField(App, "queued_prompt_review")) {
                    if (try queue_rt.submitPausedQueueUnchanged(app)) {
                        beginIdleSubmittedPromptTransition(app);
                        return;
                    }
                }
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                app.shell.render_requests.request(.footer);
                return;
            }

            // While an ACP agent is the selected backend (model "acp/<name>"),
            // plain prompts become /acp run turns instead of gateway requests.
            if (comptime provider_runtime.supported(App)) {
                const current_model = provider_runtime.model(app);
                if (std.mem.startsWith(u8, current_model, "acp/")) {
                    const agent = current_model["acp/".len..];
                    // Echo the prompt as a normal user turn; the rewrite to
                    // /acp run is an implementation detail the transcript
                    // should not surface.
                    if (comptime @hasDecl(App, "writeUserPromptCard")) {
                        const prompt_copy = try app.alloc.dupe(u8, trimmed);
                        defer app.alloc.free(prompt_copy);
                        try app.writeUserPromptCard(.{ .text = prompt_copy });
                    }
                    const command_text = try std.fmt.allocPrint(
                        app.alloc,
                        "/acp run {s} {s}",
                        .{ agent, trimmed },
                    );
                    defer app.alloc.free(command_text);
                    try submitSlashCommand(app, command_text, null, max_prompt_history);
                    return;
                }
            }

            const first_image_id = try firstAvailableImageId(app.pending_images.items);
            var extracted = image_attachments.extractInlineImageAttachments(
                app.alloc,
                app.workspace_root,
                trimmed,
                first_image_id,
            ) catch |err| {
                const message = switch (err) {
                    error.UnsupportedImageType => try app.alloc.dupe(u8, "unsupported image type"),
                    error.FileNotFound => try app.alloc.dupe(u8, "image file not found"),
                    error.ImageTooLarge => try app.alloc.dupe(u8, image_attachments.image_too_large_notice),
                    else => try std.fmt.allocPrint(app.alloc, "failed to attach image: {s}", .{@errorName(err)}),
                };
                defer app.alloc.free(message);
                try app.writeDomainNotice(.{
                    .topic = "images",
                    .tone = .@"error",
                    .body = message,
                }, true);
                app.shell.render_requests.request(.footer);
                return;
            };
            var discard_extracted = true;
            defer if (discard_extracted)
                extracted.discard(app.alloc)
            else
                extracted.deinit(app.alloc);
            try assignStableExtractedImageIds(app, &extracted);
            if (try captureExtractedImages(app, extracted.images) == .rejected) {
                app.shell.render_requests.request(.footer);
                return;
            }

            const has_inline_images = extracted.images.len > 0;
            const effective_text = if (has_inline_images) extracted.text else expanded.text;

            if (!try preflightPrompt(app)) return;

            var staged_images = if (app.pending_images.items.len > 0 or extracted.images.len > 0)
                try stagePendingImages(app.alloc, app.pending_images.items, extracted.images)
            else
                null;
            defer if (staged_images) |*images| deinitOwnedImageList(app.alloc, images);

            var image_occurrences = try projectImageOccurrencesForSubmit(
                app.alloc,
                app.input_runtime.edit_state.input.items,
                expanded.text,
                trimmed,
                effective_text,
                app.input_runtime.entities.pasted_blocks.items,
                app.input_runtime.entities.image_tokens.items,
                app.pending_images.items,
                extracted.image_spans,
                extracted.images,
                has_inline_images,
            );
            defer image_occurrences.deinit(app.alloc);

            // One mapping owns both placeholder IDs and attachment order.
            const visual_text = if (staged_images) |*images|
                try mapSubmittedImages(
                    app.alloc,
                    effective_text,
                    images,
                    image_occurrences.items,
                    firstRemappedImageId(app),
                )
            else
                VisualText{ .text = effective_text, .owned = false };
            defer if (visual_text.owned) app.alloc.free(visual_text.text);
            const display_skill_tokens = try projectSkillTokensForSubmit(
                app.alloc,
                app.input_runtime.edit_state.input.items,
                expanded.text,
                trimmed,
                effective_text,
                visual_text.text,
                app.input_runtime.entities.pasted_blocks.items,
                app.input_runtime.entities.skill_tokens.items,
                has_inline_images,
                image_occurrences.items,
            );
            defer if (display_skill_tokens.len > 0) app.alloc.free(display_skill_tokens);
            var accepted_draft = try prepareAcceptedDraftProjection(
                app,
                expanded.text,
                visual_text.text,
                display_skill_tokens,
                image_occurrences.items,
                has_inline_images,
            );
            defer accepted_draft.deinit(app.alloc);
            const has_images_for_submit = if (staged_images) |*images|
                images.items.len > 0
            else
                app.pending_images.items.len > 0;

            const queued = if (staged_images) |*images|
                try enqueuePromptWithStagedImages(
                    app,
                    visual_text.text,
                    display_skill_tokens,
                    &accepted_draft,
                    images,
                )
            else
                try enqueuePromptForSubmit(
                    app,
                    visual_text.text,
                    display_skill_tokens,
                    &accepted_draft,
                );
            if (!queued) return;
            commitStableExtractedImageIds(app, extracted.images);
            commitRemappedImageIds(app, visual_text.next_image_id);
            if (visual_text.text.len > 0) {
                recordAcceptedPromptComposerHistory(
                    app,
                    max_prompt_history,
                    &accepted_draft,
                );
            }
            if (!has_images_for_submit and visual_text.text.len > 0) {
                recordAcceptedInput(app, visual_text.text);
            }
            discard_extracted = false;
            releasePendingImages(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            if (acceptedPromptNeedsImmediateFooter(app)) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn acceptedPromptNeedsImmediateFooter(app: *const App) bool {
            if (comptime @hasField(App, "stream")) return app.stream.active;
            return true;
        }

        fn preflightPrompt(app: *App) !bool {
            if (comptime @hasDecl(App, "ensurePromptCredential")) {
                return App.ensurePromptCredential(app);
            }
            return true;
        }

        fn knownSlashCommand(app: *const App, text: []const u8) ?*const command_specs.SlashSpec {
            if (text.len == 0 or text[0] != '/') return null;
            var command_end: usize = 1;
            while (command_end < text.len and !std.ascii.isWhitespace(text[command_end])) : (command_end += 1) {}
            return app.slashRegistry().lookup(text[0..command_end]);
        }

        fn shouldRouteUnknownSlashCommand(app: *App, text: []const u8) bool {
            if (text.len == 0 or text[0] != '/') return false;
            const command_end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
            if (command_end != text.len) return false;
            if (std.mem.indexOfScalar(u8, text[1..command_end], '/') != null) return false;
            if (app.input_runtime.picker.isInlinePickerDismissed(.slash)) return false;
            if (app.input_runtime.picker.inlinePickerTriggerKind(&app.input_runtime.edit_state) != .slash) return false;
            return completion_rt.slashCompletionCandidateCount(app) == 0;
        }

        fn requiresPromptCredential(command: *const command_specs.SlashSpec, submission: []const u8) bool {
            if (!command.requires_prompt_credential) return false;
            if (command.kind != .model) return true;

            var command_end: usize = 1;
            while (command_end < submission.len and !std.ascii.isWhitespace(submission[command_end])) : (command_end += 1) {}
            return std.mem.trim(u8, submission[command_end..], " \t\r\n").len > 0;
        }

        fn pendingImagesPrefixEnd(
            raw_input: []const u8,
            expanded_text: []const u8,
            pasted_blocks: []const paste_blocks.PastedBlock,
            image_tokens: []const entity_spans.ImageTokenSpan,
            images: []const types.ImageAttachment,
        ) ?usize {
            var index: usize = 0;
            while (index < expanded_text.len and std.ascii.isWhitespace(expanded_text[index])) : (index += 1) {}

            var saw_placeholder = false;
            while (projectedImageTokenAt(
                raw_input,
                pasted_blocks,
                image_tokens,
                images,
                index,
            )) |projected| {
                saw_placeholder = true;
                index = projected.end;
                while (index < expanded_text.len and std.ascii.isWhitespace(expanded_text[index])) : (index += 1) {}
            }
            if (!saw_placeholder) return null;
            return index;
        }

        fn projectedImageTokenAt(
            raw_input: []const u8,
            pasted_blocks: []const paste_blocks.PastedBlock,
            image_tokens: []const entity_spans.ImageTokenSpan,
            images: []const types.ImageAttachment,
            expanded_start: usize,
        ) ?Span {
            for (image_tokens) |token| {
                if (!validRawImageToken(raw_input, token)) continue;
                if (image_attachments.findImageIndexById(images, token.id) == null) continue;
                const start = paste_blocks.projectOffsetThroughExpansion(
                    raw_input,
                    pasted_blocks,
                    token.span.raw_start,
                ) orelse continue;
                if (start < expanded_start) continue;
                if (start > expanded_start) return null;
                const end = paste_blocks.projectOffsetThroughExpansion(
                    raw_input,
                    pasted_blocks,
                    token.span.raw_end,
                ) orelse return null;
                return .{ .start = start, .end = end };
            }
            return null;
        }

        fn submitSlashCommand(
            app: *App,
            text: []const u8,
            retained_prefix: ?[]const u8,
            max_prompt_history: usize,
        ) !void {
            const command_text = resolvedSlashSubmission(app, text);
            const command_copy = try app.alloc.dupe(u8, command_text);
            defer app.alloc.free(command_copy);
            const prefix_copy: ?[]u8 = if (retained_prefix) |prefix|
                try app.alloc.dupe(u8, prefix)
            else
                null;
            defer if (prefix_copy) |prefix| app.alloc.free(prefix);
            var retained_image_tokens = if (prefix_copy) |prefix|
                try projectRetainedImageTokens(app, prefix.len)
            else
                std.ArrayList(entity_spans.ImageTokenSpan).empty;
            defer retained_image_tokens.deinit(app.alloc);
            if (prefix_copy) |prefix| {
                try app.input_runtime.edit_state.input.ensureTotalCapacity(app.alloc, prefix.len);
                try app.input_runtime.entities.image_tokens.ensureTotalCapacity(
                    app.alloc,
                    retained_image_tokens.items.len,
                );
            }

            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            if (prefix_copy) |prefix| {
                app.input_runtime.edit_state.insertSliceAssumeCapacity(prefix);
                app.input_runtime.entities.image_tokens.appendSliceAssumeCapacity(
                    retained_image_tokens.items,
                );
            }
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            if (retained_prefix == null and app.pending_images.items.len > 0) {
                debug_trace.logf(
                    "input",
                    "draft images dropped count={d} reason=local_command",
                    .{app.pending_images.items.len},
                );
                app.clearPendingImages();
            }
            app.shell.render_requests.request(.footer);
            defer if (retained_prefix != null) {
                if (app.pending_images.items.len == 0) {
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                }
                app.shell.render_requests.request(.footer);
            };
            recordAcceptedSlashCommandHistory(
                app,
                max_prompt_history,
                command_copy,
            );
            try App.handleCommand(app, command_copy);
        }

        fn projectRetainedImageTokens(
            app: *App,
            expanded_prefix_len: usize,
        ) !std.ArrayList(entity_spans.ImageTokenSpan) {
            var projected: std.ArrayList(entity_spans.ImageTokenSpan) = .empty;
            errdefer projected.deinit(app.alloc);
            for (app.input_runtime.entities.image_tokens.items) |token| {
                if (!validRawImageToken(app.input_runtime.edit_state.input.items, token)) continue;
                if (image_attachments.findImageIndexById(
                    app.pending_images.items,
                    token.id,
                ) == null) continue;
                const start = paste_blocks.projectOffsetThroughExpansion(
                    app.input_runtime.edit_state.input.items,
                    app.input_runtime.entities.pasted_blocks.items,
                    token.span.raw_start,
                ) orelse continue;
                const end = paste_blocks.projectOffsetThroughExpansion(
                    app.input_runtime.edit_state.input.items,
                    app.input_runtime.entities.pasted_blocks.items,
                    token.span.raw_end,
                ) orelse continue;
                if (end > expanded_prefix_len) continue;
                try projected.append(app.alloc, .{
                    .id = token.id,
                    .span = .{ .raw_start = start, .raw_end = end },
                });
            }
            return projected;
        }

        fn resolvedSlashSubmission(app: *App, text: []const u8) []const u8 {
            if (completion_rt.visibleSlashCompletionCount(app) == 0) return text;
            return resolveSlashSubmission(app.slashRegistry(), text, app.input_runtime.picker.slash_completion_index);
        }

        fn enqueuePromptForSubmit(
            app: *App,
            prompt: []const u8,
            skill_tokens: []const registered_entities.SkillTokenSpan,
            accepted_draft: ?*const AcceptedDraftProjection,
        ) !bool {
            const resume_review = if (comptime @hasField(App, "queued_prompt_review"))
                app.queued_prompt_review.active()
            else
                false;
            if (comptime @hasField(App, "queued_prompt_review")) {
                switch (try queue_rt.promptAdmission(
                    app,
                    if (accepted_draft) |draft| draft.input else prompt,
                    if (accepted_draft) |draft| draft.pasted_blocks.items else &.{},
                    if (accepted_draft) |draft| draft.image_tokens.items else &.{},
                    if (accepted_draft) |draft| draft.skill_tokens.items else skill_tokens,
                )) {
                    .replaced => {
                        beginIdleSubmittedPromptTransition(app);
                        return true;
                    },
                    .enqueue => {},
                }
            }

            const accepted = if (comptime @hasDecl(App, "enqueuePromptWithReviewDraft")) blk: {
                if (accepted_draft) |draft| {
                    break :blk try App.enqueuePromptWithReviewDraft(
                        app,
                        prompt,
                        skill_tokens,
                        draft.input,
                        draft.pasted_blocks.items,
                        draft.image_tokens.items,
                        draft.skill_tokens.items,
                    );
                }
                break :blk try App.enqueuePromptWithSkillBindings(
                    app,
                    prompt,
                    skill_tokens,
                );
            } else if (comptime @hasDecl(App, "enqueuePromptWithSkillBindings"))
                try App.enqueuePromptWithSkillBindings(app, prompt, skill_tokens)
            else
                try App.enqueuePrompt(app, prompt);
            if (!accepted) return false;
            if (resume_review) {
                if (comptime @hasField(App, "queued_prompt_review")) {
                    queue_rt.resumeAfterNewPrompt(app);
                }
            }
            beginIdleSubmittedPromptTransition(app);
            return true;
        }

        fn beginIdleSubmittedPromptTransition(app: *App) void {
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) {
                    if (comptime @hasField(App, "pacer") and
                        @hasDecl(@TypeOf(app.pacer), "hasCompletedAssistantPresentationTail"))
                    {
                        if (!app.pacer.hasCompletedAssistantPresentationTail()) return;
                    } else {
                        return;
                    }
                }
            } else {
                return;
            }
            app.shell.render_requests.beginSubmittedPromptTransition();
        }

        fn enqueuePromptWithStagedImages(
            app: *App,
            prompt: []const u8,
            skill_tokens: []const registered_entities.SkillTokenSpan,
            accepted_draft: *const AcceptedDraftProjection,
            staged_images: *std.ArrayList(types.ImageAttachment),
        ) !bool {
            const original_images = app.pending_images;
            app.pending_images = staged_images.*;
            staged_images.* = .empty;
            errdefer {
                deinitOwnedImageList(app.alloc, &app.pending_images);
                app.pending_images = original_images;
            }

            if (!try enqueuePromptForSubmit(
                app,
                prompt,
                skill_tokens,
                accepted_draft,
            )) {
                staged_images.* = app.pending_images;
                app.pending_images = original_images;
                return false;
            }

            var committed_images = original_images;
            deinitOwnedImageList(app.alloc, &committed_images);
            return true;
        }

        fn firstAvailableImageId(images: []const types.ImageAttachment) !usize {
            var highest_id: usize = 0;
            for (images) |image| highest_id = @max(highest_id, image.id);
            return std.math.add(usize, highest_id, 1);
        }

        fn assignStableExtractedImageIds(
            app: *App,
            extracted: *image_attachments.ExtractedInlineImages,
        ) !void {
            if (extracted.images.len == 0) return;
            if (comptime !@hasDecl(App, "peekNextImageId")) return;

            const stable_ids = try app.alloc.alloc(usize, extracted.images.len);
            defer app.alloc.free(stable_ids);
            const first_stable_id = app.peekNextImageId();
            _ = std.math.add(
                usize,
                first_stable_id,
                extracted.images.len,
            ) catch return error.ImageIdOverflow;
            var ids_changed = false;
            for (extracted.images, 0..) |image, index| {
                const stable_id = first_stable_id + index;
                if (stable_id == 0) return error.ImageIdOverflow;
                for (app.pending_images.items) |pending_image| {
                    if (pending_image.id == stable_id) return error.DuplicateImageId;
                }
                stable_ids[index] = stable_id;
                ids_changed = ids_changed or stable_id != image.id;
            }
            if (!ids_changed) return;
            if (extracted.image_spans.len != extracted.images.len) {
                return error.InvalidImageOccurrence;
            }

            const stable_spans = try app.alloc.alloc(
                image_attachments.ImagePlaceholderSpan,
                extracted.image_spans.len,
            );
            errdefer app.alloc.free(stable_spans);
            var remapped: std.Io.Writer.Allocating = .init(app.alloc);
            defer remapped.deinit();
            var cursor: usize = 0;
            var span_index: usize = 0;
            while (cursor < extracted.text.len) {
                if (span_index < extracted.image_spans.len and
                    extracted.image_spans[span_index].start == cursor)
                {
                    const source_span = extracted.image_spans[span_index];
                    if (source_span.end > extracted.text.len or
                        source_span.id != extracted.images[span_index].id)
                    {
                        return error.InvalidImageOccurrence;
                    }
                    const match = image_attachments.matchImagePlaceholder(
                        extracted.text,
                        source_span.start,
                    ) orelse return error.InvalidImageOccurrence;
                    if (match.id != source_span.id or
                        source_span.start + match.length != source_span.end)
                    {
                        return error.InvalidImageOccurrence;
                    }
                    const remapped_start = remapped.written().len;
                    var placeholder_buf: [32]u8 = undefined;
                    try remapped.writer.writeAll(
                        try image_attachments.formatImagePlaceholder(
                            &placeholder_buf,
                            stable_ids[span_index],
                        ),
                    );
                    stable_spans[span_index] = .{
                        .start = remapped_start,
                        .end = remapped.written().len,
                        .id = stable_ids[span_index],
                    };
                    cursor = source_span.end;
                    span_index += 1;
                    continue;
                }
                try remapped.writer.writeByte(extracted.text[cursor]);
                cursor += 1;
            }
            if (span_index != extracted.image_spans.len) {
                return error.InvalidImageOccurrence;
            }
            const text = try remapped.toOwnedSlice();
            app.alloc.free(extracted.text);
            app.alloc.free(extracted.image_spans);
            extracted.text = text;
            extracted.image_spans = stable_spans;
            for (extracted.images, stable_ids) |*image, stable_id| image.id = stable_id;
        }

        fn commitStableExtractedImageIds(
            app: *App,
            images: []const types.ImageAttachment,
        ) void {
            if (comptime !@hasDecl(App, "nextImageId")) return;
            for (images) |image| {
                const committed_id = app.nextImageId();
                std.debug.assert(committed_id == image.id);
            }
        }

        fn captureExtractedImages(
            app: *App,
            images: []types.ImageAttachment,
        ) !image_attachments.CaptureAdmissionResult {
            return image_attachments.captureImageAttachmentsForAdmission(App, app, images);
        }

        fn stagePendingImages(
            alloc: std.mem.Allocator,
            pending: []const types.ImageAttachment,
            extracted: []const types.ImageAttachment,
        ) !std.ArrayList(types.ImageAttachment) {
            const pending_copy = try types.dupeImageAttachmentSlice(alloc, pending);
            var staged = std.ArrayList(types.ImageAttachment).fromOwnedSlice(pending_copy);
            errdefer deinitOwnedImageList(alloc, &staged);

            const extracted_copy = try types.dupeImageAttachmentSlice(alloc, extracted);
            errdefer types.freeImageAttachmentSlice(alloc, extracted_copy);
            if (extracted_copy.len > 0) {
                try staged.ensureUnusedCapacity(alloc, extracted_copy.len);
                staged.appendSliceAssumeCapacity(extracted_copy);
                alloc.free(extracted_copy);
            }
            return staged;
        }

        fn deinitOwnedImageList(alloc: std.mem.Allocator, images: *std.ArrayList(types.ImageAttachment)) void {
            for (images.items) |image| types.freeImageAttachment(alloc, image);
            images.deinit(alloc);
            images.* = .empty;
        }

        fn releasePendingImages(app: *App) void {
            if (comptime @hasDecl(App, "releasePendingImages")) {
                App.releasePendingImages(app);
            } else {
                app.clearPendingImages();
            }
        }

        fn recordAcceptedInput(app: *App, text: []const u8) void {
            if (comptime !@hasField(App, "prompt_history")) return;
            const outcome = app.prompt_history.recordAccepted(
                app.alloc,
                io_mod.milliTimestamp(),
                app.workspace_root,
                text,
            );
            if (outcome != .warning) return;
            const err = app.prompt_history.lastAppendError() orelse
                error.PromptHistoryWriteFailed;
            const notice = std.fmt.allocPrint(
                app.alloc,
                "failed to save input history ({s}); submission continued",
                .{@errorName(err)},
            ) catch |notice_err| {
                debug_trace.logf(
                    "prompt_history",
                    "warning allocation failed err={s}",
                    .{@errorName(notice_err)},
                );
                return;
            };
            defer app.alloc.free(notice);
            app.writeDomainNotice(.{
                .topic = "history",
                .tone = .warning,
                .body = notice,
            }, true) catch |notice_err| {
                debug_trace.logf(
                    "prompt_history",
                    "warning output failed err={s}",
                    .{@errorName(notice_err)},
                );
            };
        }

        fn recordAcceptedPromptComposerHistory(
            app: *App,
            max_prompt_history: usize,
            accepted: *const AcceptedDraftProjection,
        ) void {
            recordComposerHistory(
                app,
                max_prompt_history,
                accepted.input,
                accepted.pasted_blocks.items,
                app.pending_images.items,
                accepted.image_tokens.items,
                accepted.skill_tokens.items,
            );
        }

        fn recordAcceptedSlashCommandHistory(
            app: *App,
            max_prompt_history: usize,
            command: []const u8,
        ) void {
            recordComposerHistory(
                app,
                max_prompt_history,
                command,
                &.{},
                &.{},
                &.{},
                &.{},
            );
            recordAcceptedInput(app, command);
        }

        fn recordComposerHistory(
            app: *App,
            max_prompt_history: usize,
            text: []const u8,
            pasted: []const paste_blocks.PastedBlock,
            images: []const types.ImageAttachment,
            image_tokens: []const entity_spans.ImageTokenSpan,
            skill_tokens: []const registered_entities.SkillTokenSpan,
        ) void {
            if (comptime @hasField(App, "prompt_history")) {
                if (!app.prompt_history.enabled) return;
            }
            app.input_runtime.composer_history.record(
                app.alloc,
                max_prompt_history,
                text,
                pasted,
                images,
                image_tokens,
                skill_tokens,
            ) catch |err| {
                debug_trace.logf(
                    "input",
                    "composer history record skipped err={s}",
                    .{@errorName(err)},
                );
            };
        }

        fn prepareAcceptedDraftProjection(
            app: *App,
            expanded_text: []const u8,
            visual_text: []const u8,
            display_skill_tokens: []const registered_entities.SkillTokenSpan,
            image_occurrences: []const ImageOccurrence,
            has_extracted_images: bool,
        ) !AcceptedDraftProjection {
            var submitted_image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty;
            defer submitted_image_tokens.deinit(app.alloc);
            try submitted_image_tokens.ensureTotalCapacity(
                app.alloc,
                image_occurrences.len,
            );
            for (image_occurrences) |occurrence| {
                if (occurrence.submitted_id == 0) continue;
                submitted_image_tokens.appendAssumeCapacity(.{
                    .id = occurrence.submitted_id,
                    .span = .{
                        .raw_start = occurrence.span.start,
                        .raw_end = occurrence.span.end,
                    },
                });
            }

            if (app.input_runtime.entities.pasted_blocks.items.len > 0 and
                !has_extracted_images)
            {
                if (try prepareCompactAcceptedDraftProjection(
                    app,
                    expanded_text,
                    visual_text,
                    display_skill_tokens,
                    submitted_image_tokens.items,
                )) |compact| return compact;
                debug_trace.logf(
                    "input",
                    "accepted draft paste provenance unavailable after projection blocks={d}",
                    .{app.input_runtime.entities.pasted_blocks.items.len},
                );
            }
            if (app.input_runtime.entities.pasted_blocks.items.len > 0 and
                has_extracted_images)
            {
                debug_trace.logf(
                    "input",
                    "accepted draft paste provenance unavailable after inline image extraction blocks={d}",
                    .{app.input_runtime.entities.pasted_blocks.items.len},
                );
            }

            var fallback = AcceptedDraftProjection{ .input = visual_text };
            errdefer fallback.deinit(app.alloc);
            try fallback.image_tokens.appendSlice(
                app.alloc,
                submitted_image_tokens.items,
            );
            try fallback.skill_tokens.appendSlice(
                app.alloc,
                display_skill_tokens,
            );
            return fallback;
        }

        fn prepareCompactAcceptedDraftProjection(
            app: *App,
            expanded_text: []const u8,
            visual_text: []const u8,
            display_skill_tokens: []const registered_entities.SkillTokenSpan,
            submitted_image_tokens: []const entity_spans.ImageTokenSpan,
        ) !?AcceptedDraftProjection {
            const raw_input = app.input_runtime.edit_state.input.items;
            if (!std.mem.eql(u8, expanded_text, visual_text)) return null;
            const raw_start: usize = 0;
            const raw_end = raw_input.len;

            var compact = AcceptedDraftProjection{
                .input = raw_input[raw_start..raw_end],
            };
            var transferred = false;
            defer if (!transferred) compact.deinit(app.alloc);
            for (app.input_runtime.entities.pasted_blocks.items) |block| {
                if (block.span.raw_end <= raw_start or block.span.raw_start >= raw_end) {
                    continue;
                }
                if (block.span.raw_start < raw_start or block.span.raw_end > raw_end) {
                    return null;
                }
                try compact.pasted_blocks.append(app.alloc, .{
                    .id = block.id,
                    .text = block.text,
                    .line_count = block.line_count,
                    .span = .{
                        .raw_start = block.span.raw_start - raw_start,
                        .raw_end = block.span.raw_end - raw_start,
                    },
                });
            }

            const expanded_compact = try paste_blocks.expand(
                app.alloc,
                compact.input,
                compact.pasted_blocks.items,
            );
            defer if (expanded_compact.owned) app.alloc.free(expanded_compact.text);
            if (!std.mem.eql(u8, expanded_compact.text, visual_text)) return null;

            for (app.input_runtime.entities.image_tokens.items) |token| {
                if (token.span.raw_end <= raw_start or token.span.raw_start >= raw_end) {
                    continue;
                }
                if (token.span.raw_start < raw_start or token.span.raw_end > raw_end) {
                    return null;
                }
                try compact.image_tokens.append(app.alloc, .{
                    .id = token.id,
                    .span = .{
                        .raw_start = token.span.raw_start - raw_start,
                        .raw_end = token.span.raw_end - raw_start,
                    },
                });
            }
            if (!sameImageTokenIds(
                compact.image_tokens.items,
                submitted_image_tokens,
            )) {
                return null;
            }

            for (app.input_runtime.entities.skill_tokens.items) |token| {
                if (token.raw_end <= raw_start or token.raw_start >= raw_end) continue;
                if (token.raw_start < raw_start or token.raw_end > raw_end) return null;
                try compact.skill_tokens.append(app.alloc, .{
                    .raw_start = token.raw_start - raw_start,
                    .raw_end = token.raw_end - raw_start,
                    .name = token.name,
                    .path = token.path,
                    .display_source = token.display_source,
                    .owns_trailing_separator = token.owns_trailing_separator,
                });
            }
            if (!sameSkillSources(
                compact.skill_tokens.items,
                display_skill_tokens,
            )) {
                return null;
            }

            transferred = true;
            return compact;
        }

        fn sameImageTokenIds(
            raw_tokens: []const entity_spans.ImageTokenSpan,
            submitted_tokens: []const entity_spans.ImageTokenSpan,
        ) bool {
            if (raw_tokens.len != submitted_tokens.len) return false;
            for (raw_tokens, submitted_tokens) |raw, submitted| {
                if (raw.id != submitted.id) return false;
            }
            return true;
        }

        fn sameSkillSources(
            raw_tokens: []const registered_entities.SkillTokenSpan,
            submitted_tokens: []const registered_entities.SkillTokenSpan,
        ) bool {
            if (raw_tokens.len != submitted_tokens.len) return false;
            for (raw_tokens, submitted_tokens) |raw, submitted| {
                if (!std.mem.eql(u8, raw.name, submitted.name) or
                    !std.mem.eql(u8, raw.path, submitted.path) or
                    raw.display_source != submitted.display_source or
                    raw.owns_trailing_separator != submitted.owns_trailing_separator)
                {
                    return false;
                }
            }
            return true;
        }

        const VisualText = struct {
            text: []const u8,
            owned: bool,
            next_image_id: ?usize = null,
        };

        const ImageOccurrence = struct {
            span: Span,
            attachment_index: usize,
            source_id: usize,
            submitted_id: usize = 0,
        };

        fn projectImageOccurrencesForSubmit(
            alloc: std.mem.Allocator,
            raw_input: []const u8,
            expanded_text: []const u8,
            trimmed_text: []const u8,
            effective_text: []const u8,
            pasted_blocks: []const paste_blocks.PastedBlock,
            image_tokens: []const entity_spans.ImageTokenSpan,
            pending_images: []const types.ImageAttachment,
            extracted_spans: []const image_attachments.ImagePlaceholderSpan,
            extracted_images: []const types.ImageAttachment,
            has_inline_images: bool,
        ) !std.ArrayList(ImageOccurrence) {
            var occurrences: std.ArrayList(ImageOccurrence) = .empty;
            errdefer occurrences.deinit(alloc);
            const trim_start = if (has_inline_images)
                leadingTrimLen(expanded_text)
            else
                0;
            const projection_source = if (has_inline_images)
                trimmed_text
            else
                expanded_text;

            for (image_tokens) |token| {
                if (!validRawImageToken(raw_input, token)) continue;
                const attachment_index = image_attachments.findImageIndexById(
                    pending_images,
                    token.id,
                ) orelse continue;
                var span = projectSpanThroughPasteExpansion(raw_input, pasted_blocks, .{
                    .start = token.span.raw_start,
                    .end = token.span.raw_end,
                }) orelse continue;
                if (span.start < trim_start or span.end < span.start) continue;
                span.start -= trim_start;
                span.end -= trim_start;
                if (span.end > projection_source.len) continue;
                if (has_inline_images) {
                    span = projectSpanThroughInlineImageExtraction(
                        projection_source,
                        effective_text,
                        span,
                    ) orelse continue;
                }
                try appendImageOccurrenceSorted(alloc, &occurrences, .{
                    .span = span,
                    .attachment_index = attachment_index,
                    .source_id = token.id,
                });
            }

            for (extracted_spans, 0..) |span, index| {
                if (index >= extracted_images.len or span.id != extracted_images[index].id) continue;
                const match = image_attachments.matchImagePlaceholder(
                    effective_text,
                    span.start,
                ) orelse continue;
                if (match.id != span.id or span.start + match.length != span.end) continue;
                try appendImageOccurrenceSorted(alloc, &occurrences, .{
                    .span = .{ .start = span.start, .end = span.end },
                    .attachment_index = pending_images.len + index,
                    .source_id = span.id,
                });
            }
            return occurrences;
        }

        fn appendImageOccurrenceSorted(
            alloc: std.mem.Allocator,
            occurrences: *std.ArrayList(ImageOccurrence),
            occurrence: ImageOccurrence,
        ) !void {
            try occurrences.append(alloc, occurrence);
            var index = occurrences.items.len - 1;
            while (index > 0 and
                occurrences.items[index].span.start < occurrences.items[index - 1].span.start)
            {
                std.mem.swap(
                    ImageOccurrence,
                    &occurrences.items[index],
                    &occurrences.items[index - 1],
                );
                index -= 1;
            }
        }

        fn validRawImageToken(
            raw_input: []const u8,
            token: entity_spans.ImageTokenSpan,
        ) bool {
            if (!token.span.isValid(raw_input.len)) return false;
            const match = image_attachments.matchImagePlaceholder(
                raw_input,
                token.span.raw_start,
            ) orelse return false;
            return match.id == token.id and
                token.span.raw_start + match.length == token.span.raw_end;
        }

        fn mapSubmittedImages(
            alloc: std.mem.Allocator,
            text: []const u8,
            images: *std.ArrayList(types.ImageAttachment),
            occurrences: []ImageOccurrence,
            first_remapped_id: usize,
        ) !VisualText {
            if (images.items.len == 0) return .{ .text = text, .owned = false };

            const used = try alloc.alloc(bool, images.items.len);
            defer alloc.free(used);
            @memset(used, false);

            var ordered: std.ArrayList(types.ImageAttachment) = .empty;
            defer ordered.deinit(alloc);
            try ordered.ensureTotalCapacity(alloc, images.items.len);

            var remapped_id = first_remapped_id;
            var ids_changed = false;
            for (occurrences) |*occurrence| {
                if (occurrence.attachment_index >= images.items.len or
                    used[occurrence.attachment_index])
                {
                    return error.InvalidImageOccurrence;
                }
                var image = images.items[occurrence.attachment_index];
                if (image.id != occurrence.source_id) return error.InvalidImageOccurrence;
                if (literalImageIdUsed(text, occurrences, image.id)) {
                    remapped_id = try nextRemappedImageId(
                        text,
                        occurrences,
                        remapped_id,
                    );
                    image.id = remapped_id;
                    remapped_id = try std.math.add(usize, remapped_id, 1);
                    ids_changed = true;
                }
                occurrence.submitted_id = image.id;
                ordered.appendAssumeCapacity(image);
                used[occurrence.attachment_index] = true;
            }

            for (images.items, used) |image, retained| {
                if (!retained) types.freeImageAttachment(alloc, image);
            }
            @memcpy(images.items[0..ordered.items.len], ordered.items);
            images.items.len = ordered.items.len;

            if (!ids_changed) {
                return .{ .text = text, .owned = false };
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            var cursor: usize = 0;
            for (occurrences) |occurrence| {
                if (occurrence.span.start < cursor or occurrence.span.end > text.len) {
                    return error.InvalidImageOccurrence;
                }
                try out.appendSlice(alloc, text[cursor..occurrence.span.start]);
                var placeholder_buf: [64]u8 = undefined;
                const placeholder = try image_attachments.formatImagePlaceholder(
                    &placeholder_buf,
                    occurrence.submitted_id,
                );
                try out.appendSlice(alloc, placeholder);
                cursor = occurrence.span.end;
            }
            try out.appendSlice(alloc, text[cursor..]);
            return .{
                .text = try out.toOwnedSlice(alloc),
                .owned = true,
                .next_image_id = if (ids_changed) remapped_id else null,
            };
        }

        fn firstRemappedImageId(app: *const App) usize {
            if (comptime @hasDecl(App, "peekNextImageId")) {
                return app.peekNextImageId();
            }
            return 1;
        }

        fn commitRemappedImageIds(app: *App, next_image_id: ?usize) void {
            const next = next_image_id orelse return;
            if (comptime @hasDecl(App, "peekNextImageId") and
                @hasDecl(App, "nextImageId"))
            {
                while (app.peekNextImageId() < next) {
                    const committed_id = app.nextImageId();
                    std.debug.assert(committed_id < next);
                }
            }
        }

        fn nextRemappedImageId(
            text: []const u8,
            occurrences: []const ImageOccurrence,
            first_candidate: usize,
        ) !usize {
            var candidate = first_candidate;
            while (literalImageIdUsed(text, occurrences, candidate)) {
                candidate = try std.math.add(usize, candidate, 1);
            }
            return candidate;
        }

        fn literalImageIdUsed(
            text: []const u8,
            occurrences: []const ImageOccurrence,
            id: usize,
        ) bool {
            var index: usize = 0;
            while (index < text.len) {
                const match = image_attachments.matchImagePlaceholder(text, index) orelse {
                    index += 1;
                    continue;
                };
                const end = index + match.length;
                var registered = false;
                for (occurrences) |occurrence| {
                    if (occurrence.span.start == index and
                        occurrence.span.end == end and
                        occurrence.source_id == match.id)
                    {
                        registered = true;
                        break;
                    }
                }
                if (!registered and match.id == id) return true;
                index = end;
            }
            return false;
        }

        fn projectSpanThroughSubmittedImages(
            text: []const u8,
            occurrences: []const ImageOccurrence,
            span: Span,
        ) ?Span {
            if (span.start > span.end or span.end > text.len) return null;
            const start = projectOffsetThroughSubmittedImages(
                text,
                occurrences,
                span.start,
            ) orelse return null;
            const end = projectOffsetThroughSubmittedImages(
                text,
                occurrences,
                span.end,
            ) orelse return null;
            if (end < start) return null;
            return .{ .start = start, .end = end };
        }

        fn projectOffsetThroughSubmittedImages(
            text: []const u8,
            occurrences: []const ImageOccurrence,
            source_offset: usize,
        ) ?usize {
            if (source_offset > text.len) return null;

            var source_cursor: usize = 0;
            var output_cursor: usize = 0;
            for (occurrences) |occurrence| {
                if (occurrence.span.start < source_cursor or
                    occurrence.span.end < occurrence.span.start or
                    occurrence.span.end > text.len or
                    occurrence.submitted_id == 0)
                {
                    return null;
                }
                if (source_offset < occurrence.span.start) {
                    return std.math.add(
                        usize,
                        output_cursor,
                        source_offset - source_cursor,
                    ) catch null;
                }
                output_cursor = std.math.add(
                    usize,
                    output_cursor,
                    occurrence.span.start - source_cursor,
                ) catch return null;
                if (source_offset < occurrence.span.end) {
                    return if (source_offset == occurrence.span.start)
                        output_cursor
                    else
                        null;
                }

                var placeholder_buf: [64]u8 = undefined;
                const placeholder = image_attachments.formatImagePlaceholder(
                    &placeholder_buf,
                    occurrence.submitted_id,
                ) catch return null;
                output_cursor = std.math.add(
                    usize,
                    output_cursor,
                    placeholder.len,
                ) catch return null;
                source_cursor = occurrence.span.end;
            }
            return std.math.add(
                usize,
                output_cursor,
                source_offset - source_cursor,
            ) catch null;
        }

        fn resolveSlashSubmission(registry: command_specs.SlashRegistry, text: []const u8, selected_index: usize) []const u8 {
            const count = command_specs.slashCompletionCount(registry, text);
            if (count == 0) return text;
            const idx = selected_index % count;
            return command_specs.nthSlashCompletion(registry, text, idx) orelse text;
        }

        const Span = struct {
            start: usize,
            end: usize,
        };

        fn projectSkillTokensForSubmit(
            alloc: std.mem.Allocator,
            raw_input: []const u8,
            expanded_text: []const u8,
            trimmed_text: []const u8,
            effective_text: []const u8,
            final_text: []const u8,
            pasted_blocks: []const paste_blocks.PastedBlock,
            skill_tokens: []const registered_entities.SkillTokenSpan,
            has_inline_images: bool,
            image_occurrences: []const ImageOccurrence,
        ) ![]registered_entities.SkillTokenSpan {
            if (skill_tokens.len == 0) return &.{};

            var projected: std.ArrayList(registered_entities.SkillTokenSpan) = .empty;
            errdefer projected.deinit(alloc);

            const trim_start = if (has_inline_images)
                leadingTrimLen(expanded_text)
            else
                0;
            const projection_source = if (has_inline_images)
                trimmed_text
            else
                expanded_text;
            for (skill_tokens) |token| {
                if (token.name.len == 0 or token.path.len == 0) continue;

                var span = projectSpanThroughPasteExpansion(raw_input, pasted_blocks, .{
                    .start = token.raw_start,
                    .end = token.raw_end,
                }) orelse continue;

                if (span.start < trim_start or span.end < span.start) continue;
                span.start -= trim_start;
                span.end -= trim_start;
                if (span.end > projection_source.len) continue;

                if (has_inline_images) {
                    span = projectSpanThroughInlineImageExtraction(projection_source, effective_text, span) orelse continue;
                }

                const final_span = projectSpanThroughSubmittedImages(
                    effective_text,
                    image_occurrences,
                    span,
                ) orelse continue;
                const marker = skillMarkerAt(
                    final_text,
                    final_span.start,
                    token.name,
                ) orelse continue;
                if (marker.end != final_span.end) continue;
                try projected.append(alloc, .{
                    .raw_start = final_span.start,
                    .raw_end = final_span.end,
                    .name = token.name,
                    .path = token.path,
                    .display_source = token.display_source,
                    .owns_trailing_separator = token.owns_trailing_separator,
                });
            }

            if (projected.items.len == 0) {
                projected.deinit(alloc);
                return &.{};
            }
            return try projected.toOwnedSlice(alloc);
        }

        fn projectSpanThroughPasteExpansion(
            raw_input: []const u8,
            pasted_blocks: []const paste_blocks.PastedBlock,
            span: Span,
        ) ?Span {
            if (span.start > span.end or span.end > raw_input.len) return null;
            const start = paste_blocks.projectOffsetThroughExpansion(raw_input, pasted_blocks, span.start) orelse return null;
            const end = paste_blocks.projectOffsetThroughExpansion(raw_input, pasted_blocks, span.end) orelse return null;
            if (end < start) return null;
            return .{ .start = start, .end = end };
        }

        fn leadingTrimLen(text: []const u8) usize {
            var i: usize = 0;
            while (i < text.len and image_attachments.isWhitespace(text[i])) : (i += 1) {}
            return i;
        }

        fn projectSpanThroughInlineImageExtraction(
            source: []const u8,
            extracted_text: []const u8,
            span: Span,
        ) ?Span {
            if (span.start > span.end or span.end > source.len) return null;
            const start = projectOffsetThroughInlineImageExtraction(
                source,
                extracted_text,
                span.start,
            ) orelse return null;
            const end = projectOffsetThroughInlineImageExtraction(
                source,
                extracted_text,
                span.end,
            ) orelse return null;
            if (end < start) return null;
            return .{ .start = start, .end = end };
        }

        fn projectOffsetThroughInlineImageExtraction(
            source: []const u8,
            extracted_text: []const u8,
            source_offset: usize,
        ) ?usize {
            if (source_offset > source.len) return null;

            var in_pos: usize = 0;
            var written: usize = 0;
            while (true) {
                while (in_pos < source.len and image_attachments.isWhitespace(source[in_pos])) : (in_pos += 1) {}
                if (in_pos >= source.len) break;

                const token_start = in_pos;
                const token_end = image_attachments.nextShellTokenEnd(source, token_start);
                const raw = source[token_start..token_end];
                in_pos = token_end;

                const output_start = preservedTokenStart(extracted_text, written, raw);
                if (token_start <= source_offset and source_offset <= token_end) {
                    const token_output_start = output_start orelse return null;
                    return token_output_start + (source_offset - token_start);
                }

                if (output_start) |start| {
                    written = start + raw.len;
                } else {
                    const image_token = image_attachments.splitImagePathToken(raw) orelse return null;
                    const replacement_start = written + @intFromBool(written > 0);
                    if (replacement_start >= extracted_text.len) return null;
                    const replacement = image_attachments.matchImagePlaceholder(
                        extracted_text,
                        replacement_start,
                    ) orelse return null;
                    const suffix_start = replacement_start + replacement.length;
                    const suffix_end = suffix_start + image_token.suffix.len;
                    if (suffix_end > extracted_text.len or
                        !std.mem.eql(
                            u8,
                            extracted_text[suffix_start..suffix_end],
                            image_token.suffix,
                        ))
                    {
                        return null;
                    }
                    written = suffix_end;
                }
            }
            return if (source_offset == source.len) extracted_text.len else null;
        }

        fn preservedTokenStart(output: []const u8, written: usize, raw: []const u8) ?usize {
            if (raw.len == 0 or written > output.len) return null;

            var start = written;
            if (written > 0) {
                if (start >= output.len or output[start] != ' ') return null;
                start += 1;
            }
            if (start > output.len or output.len - start < raw.len) return null;
            if (!std.mem.eql(u8, output[start .. start + raw.len], raw)) return null;
            const end = start + raw.len;
            if (end < output.len and output[end] != ' ') return null;
            return start;
        }

        fn skillMarkerAt(text: []const u8, start: usize, name: []const u8) ?Span {
            if (start >= text.len or text[start] != '$') return null;
            const end = start + 1 + name.len;
            if (end > text.len) return null;
            if (!std.mem.eql(u8, text[start + 1 .. end], name)) return null;
            if (end < text.len and isSkillNameByte(text[end])) return null;
            return .{ .start = start, .end = end };
        }

        fn isSkillNameByte(byte: u8) bool {
            return (byte >= 'A' and byte <= 'Z') or
                (byte >= 'a' and byte <= 'z') or
                (byte >= '0' and byte <= '9') or
                byte == '_' or
                byte == '-';
        }
    };
}

pub fn directCommand(expanded: []const u8) ?[]const u8 {
    if (expanded.len == 0 or expanded[0] != '!') return null;
    return expanded[1..];
}

test "direct terminal route requires the literal first character" {
    try std.testing.expectEqualStrings("printf ready", directCommand("!printf ready").?);
    try std.testing.expectEqualStrings("", directCommand("!").?);
    try std.testing.expect(directCommand(" !printf prompt") == null);
    try std.testing.expect(directCommand("ordinary prompt") == null);
}

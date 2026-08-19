const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const image_attachments = @import("../images/image_attachments.zig");
const paste_decoder = @import("../images/paste_decoder.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const gesture_state = @import("../input/gesture_state.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const input_reset = @import("../input/input_reset.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const paste_framing = @import("../input/paste_framing.zig");
const text_scalar = @import("../input/text_scalar.zig");
const render_request = @import("../../ui/render_request.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");

fn normalizeApprovalAmendmentPasteInPlace(bytes: []u8) []u8 {
    const normalized = text_utils.normalizeLineEndingsInPlace(bytes);
    for (normalized) |*byte| {
        if (byte.* == '\n' or byte.* == '\t') byte.* = ' ';
    }
    return normalized;
}

const ImagePasteStage = struct {
    replacement: std.ArrayList(u8) = .empty,
    images: std.ArrayList(types.ImageAttachment) = .empty,
    tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,

    fn deinit(self: *ImagePasteStage, alloc: std.mem.Allocator) void {
        self.replacement.deinit(alloc);
        for (self.images.items) |image| {
            image_attachments.discardImageAttachment(alloc, image);
        }
        self.images.deinit(alloc);
        self.tokens.deinit(alloc);
    }
};

pub fn PasteEditRuntime(comptime App: type) type {
    return struct {
        pub fn beginPaste(app: *App, max_input_len: usize) void {
            const owner: paste_framing.Owner = if (app.question_prompt.isActive())
                if (app.question_prompt.isFreeformSelected()) .question_freeform else .decision_prompt
            else if (app.approval_prompt.isAmending())
                .approval_amendment
            else if (app.approval_prompt.isActive())
                .decision_prompt
            else
                .composer;
            const buffer_limit = switch (owner) {
                .composer => app.input_runtime.replacementState(&app.pending_images).availableBytesForSelectionOrInsertion(max_input_len),
                .none, .decision_prompt, .question_freeform, .approval_amendment => max_input_len,
            };

            input_reset.resetPendingTextScalarWithTrace(
                &app.input_runtime.text_scalar,
                "paste_started",
            );
            app.input_runtime.paste.begin(owner, buffer_limit);
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();

            const gesture_reset = gesture_state.reset(app.input_runtime.gestures);
            app.input_runtime.gestures = gesture_reset.next;
            if (gesture_reset.cleared_ctrl_c_exit) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason=pending_gesture_reset",
                    .{},
                );
            }
            if (gesture_reset.cleared_escape_clear) {
                debug_trace.logf(
                    "input",
                    "event=esc_clear_disarmed reason=pending_gesture_reset",
                    .{},
                );
            }
            app.terminal_input_runtime.resetEscapeDecoder();
            if (gesture_reset.clearedAny()) {
                app.shell.render_requests.request(.footer);
            }

            debug_trace.logf(
                "input",
                "paste begin owner={s}",
                .{@tagName(app.input_runtime.paste.owner)},
            );
        }

        pub fn handleActivePasteByte(app: *App, byte: u8) !void {
            try app.input_runtime.paste.consumeByte(app.alloc, byte);
        }

        pub fn settlePasteDeliveryEpoch(app: *App, max_input_len: usize) !bool {
            switch (app.input_runtime.paste.settleDeliveryEpoch()) {
                .none => return false,
                .finish => {
                    debug_trace.logf(
                        "input",
                        "paste end owner={s} bytes={d}",
                        .{ @tagName(app.input_runtime.paste.owner), app.input_runtime.paste.byteCount() },
                    );
                    try finishPaste(app, max_input_len);
                },
                .reject => {
                    const owner = app.input_runtime.paste.owner;
                    const render_reason: render_request.Reason = switch (owner) {
                        .composer => .footer,
                        .decision_prompt, .question_freeform, .approval_amendment => .modal,
                        .none => return false,
                    };
                    app.input_runtime.paste.resetWithTrace(.unsafe_suffix);
                    app.shell.render_requests.request(render_reason);
                    try app.writeDomainNotice(.{
                        .topic = "input",
                        .tone = .@"error",
                        .body = "Paste was not applied because extra input followed its end marker.",
                    }, true);
                },
            }
            return true;
        }

        pub fn finishPaste(app: *App, max_input_len: usize) !void {
            if (app.input_runtime.paste.overflow_bytes > 0) {
                const attempted_bytes = app.input_runtime.paste.attemptedBytes();
                const owner: text_scalar.Owner = switch (app.input_runtime.paste.owner) {
                    .composer => .composer,
                    .question_freeform => .question_freeform,
                    .approval_amendment => .approval_amendment,
                    .none, .decision_prompt => unreachable,
                };
                app.input_runtime.paste.resetWithTrace(.{ .input_limit = switch (owner) {
                    .composer => .composer,
                    .question_freeform => .question_freeform,
                    .approval_amendment => .approval_amendment,
                } });
                try input_limit_feedback.report(App, app, owner, attempted_bytes);
                return;
            }

            switch (app.input_runtime.paste.owner) {
                .composer, .question_freeform => {
                    const normalized = text_utils.normalizeLineEndingsInPlace(app.input_runtime.paste.buffer.items);
                    app.input_runtime.paste.buffer.items.len = normalized.len;
                },
                .approval_amendment => {
                    const normalized = normalizeApprovalAmendmentPasteInPlace(app.input_runtime.paste.buffer.items);
                    app.input_runtime.paste.buffer.items.len = normalized.len;
                },
                else => {},
            }

            if (app.input_runtime.paste.owner != .none and
                app.input_runtime.paste.owner != .decision_prompt and
                !text_utils.isModelSafeText(app.input_runtime.paste.buffer.items))
            {
                const render_reason: render_request.Reason = switch (app.input_runtime.paste.owner) {
                    .question_freeform, .approval_amendment => .modal,
                    else => .footer,
                };
                app.input_runtime.paste.resetWithTrace(.invalid_utf8);
                app.shell.render_requests.request(render_reason);
                try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "Pasted text contains unsupported bytes and was not added to the draft.",
                }, true);
                return;
            }

            switch (app.input_runtime.paste.owner) {
                .none => {},
                .decision_prompt => app.input_runtime.paste.resetWithTrace(.decision_prompt_active),
                .question_freeform => {
                    if (comptime @hasField(App, "question_prompt")) {
                        errdefer |err| app.input_runtime.paste.resetWithTrace(.{ .finalize_failed = .{
                            .owner = .question_freeform,
                            .error_name = @errorName(err),
                        } });
                        switch (try app.question_prompt.insertFreeformSlice(
                            app.alloc,
                            app.input_runtime.paste.buffer.items,
                            max_input_len,
                        )) {
                            .inserted => {
                                app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                                app.input_runtime.paste.finishHandled();
                                app.shell.render_requests.request(.modal);
                            },
                            .inactive => app.input_runtime.paste.resetWithTrace(.session_reset),
                            .limit_exceeded => {
                                const attempted_bytes = app.input_runtime.paste.buffer.items.len;
                                app.input_runtime.paste.resetWithTrace(.{ .input_limit = .question_freeform });
                                try input_limit_feedback.report(App, app, .question_freeform, attempted_bytes);
                            },
                        }
                    } else {
                        app.input_runtime.paste.resetWithTrace(.session_reset);
                    }
                },
                .composer => {
                    app.input_runtime.paste.beginHandling();
                    finalizePastedBlock(app, max_input_len) catch |err| {
                        app.input_runtime.paste.resetWithTrace(.{ .finalize_failed = .{
                            .owner = .composer,
                            .error_name = @errorName(err),
                        } });
                        return err;
                    };
                    app.input_runtime.paste.finishHandled();
                    app.shell.render_requests.request(.footer);
                },
                .approval_amendment => {
                    if (comptime @hasField(App, "approval_prompt")) {
                        errdefer |err| app.input_runtime.paste.resetWithTrace(.{ .finalize_failed = .{
                            .owner = .approval_amendment,
                            .error_name = @errorName(err),
                        } });
                        switch (try app.approval_prompt.decision.insertAmendmentSlice(
                            app.alloc,
                            app.input_runtime.paste.buffer.items,
                            max_input_len,
                        )) {
                            .inserted => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                            .inactive => {
                                app.input_runtime.paste.resetWithTrace(.session_reset);
                                return;
                            },
                            .limit_exceeded => {
                                const attempted_bytes = app.input_runtime.paste.buffer.items.len;
                                app.input_runtime.paste.resetWithTrace(.{ .input_limit = .approval_amendment });
                                try input_limit_feedback.report(App, app, .approval_amendment, attempted_bytes);
                                return;
                            },
                        }
                        app.input_runtime.paste.finishHandled();
                        app.shell.render_requests.request(.modal);
                    } else {
                        app.input_runtime.paste.resetWithTrace(.session_reset);
                    }
                },
            }
        }

        pub fn finalizePastedBlock(app: *App, max_input_len: usize) !void {
            if (app.input_runtime.paste.buffer.items.len == 0) return;

            const unwrapped = try paste_decoder.unwrapPaste(app.alloc, app.input_runtime.paste.buffer.items);
            defer unwrapped.deinit(app.alloc);
            const payload = switch (unwrapped) {
                .raster => |image| {
                    try attachRasterBytes(app, image.bytes, max_input_len);
                    app.input_runtime.paste.buffer.clearRetainingCapacity();
                    return;
                },
                .text => |text| text,
                .unchanged => app.input_runtime.paste.buffer.items,
            };

            if (paste_decoder.isDropShapedPaste(payload) or
                image_attachments.hasImagePathToken(payload) or
                paste_decoder.hasFileUrlToken(payload))
            {
                try handlePastedBytes(app, payload, max_input_len);
                app.input_runtime.paste.buffer.clearRetainingCapacity();
                return;
            }

            const text = try app.alloc.dupe(u8, payload);
            var text_owned_by_block = false;
            errdefer if (!text_owned_by_block) app.alloc.free(text);

            if (!paste_blocks.shouldUsePlaceholder(text)) {
                const start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                    selection.start
                else
                    app.input_runtime.edit_state.cursor;
                switch (try app.input_runtime.replacementState(&app.pending_images).replaceSelectionOrInsertSliceBounded(
                    app.alloc,
                    text,
                    max_input_len,
                    .preserve,
                )) {
                    .inserted => maybeOpenPastedSkillMenu(app, start, start + text.len),
                    .inactive => unreachable,
                    .limit_exceeded => try input_limit_feedback.report(App, app, .composer, text.len),
                }
                app.input_runtime.paste.buffer.clearRetainingCapacity();
                app.alloc.free(text);
                return;
            }

            const line_count = paste_blocks.countLines(text);
            const id = app.input_runtime.entities.next_paste_id;

            var buf: [64]u8 = undefined;
            const placeholder = try paste_blocks.formatPlaceholder(&buf, id, line_count);
            const replacement = app.input_runtime.replacementState(&app.pending_images);
            if (!replacement.canReplaceSelectionOrInsert(text.len, max_input_len)) {
                try input_limit_feedback.report(App, app, .composer, text.len);
                app.input_runtime.paste.buffer.clearRetainingCapacity();
                app.alloc.free(text);
                return;
            }
            try app.input_runtime.entities.pasted_blocks.ensureUnusedCapacity(app.alloc, 1);
            try app.input_runtime.edit_state.input.ensureUnusedCapacity(app.alloc, placeholder.len);

            const raw_start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                selection.start
            else
                app.input_runtime.edit_state.cursor;
            std.debug.assert(try replacement.replaceSelectionOrInsertSliceBounded(
                app.alloc,
                placeholder,
                max_input_len,
                .preserve,
            ) == .inserted);
            app.input_runtime.entities.registerPastedBlockAssumeCapacity(.{
                .id = id,
                .text = text,
                .line_count = line_count,
                .span = .{
                    .raw_start = raw_start,
                    .raw_end = raw_start + placeholder.len,
                },
            });
            text_owned_by_block = true;
            app.input_runtime.entities.next_paste_id += 1;
            if (comptime @hasDecl(@TypeOf(app.input_runtime), "historyBoundary")) {
                app.input_runtime.historyBoundary(app.alloc);
            }
            app.input_runtime.paste.buffer.clearRetainingCapacity();
        }

        fn attachRasterBytes(app: *App, bytes: []const u8, max_input_len: usize) !void {
            var persisted = image_attachments.persistImageBytes(app.alloc, bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.ImageTooLarge => {
                    try reportImageTooLarge(app);
                    return;
                },
                else => {
                    try reportImageAttachFailure(app, err);
                    return;
                },
            };
            var cleanup_source = true;
            defer if (cleanup_source) persisted.deinit(app.alloc);

            var attached = persisted.takeAttachment();
            var owns_attached = true;
            defer if (owns_attached) image_attachments.discardImageAttachment(app.alloc, attached);

            var stage: ImagePasteStage = .{};
            defer stage.deinit(app.alloc);

            const id = app.peekNextImageId();
            attached.id = id;
            switch (try image_attachments.captureImageAttachmentForAdmission(App, app, &attached)) {
                .captured => {},
                .rejected => return,
            }
            if (attached.snapshot_path) |snapshot_path| {
                const display_path = try app.alloc.dupe(u8, snapshot_path);
                app.alloc.free(attached.path);
                attached.path = display_path;
            } else {
                cleanup_source = false;
            }

            var ph_buf: [32]u8 = undefined;
            const placeholder = try image_attachments.formatImagePlaceholder(&ph_buf, id);
            try stage.replacement.appendSlice(app.alloc, placeholder);
            try stage.tokens.append(app.alloc, .{
                .span = .{ .raw_start = 0, .raw_end = placeholder.len },
                .id = id,
            });
            try stage.images.append(app.alloc, attached);
            owns_attached = false;
            try commitImagePasteStage(app, &stage, id, bytes.len, max_input_len);
        }

        pub fn handlePastedBytes(app: *App, bytes: []const u8, max_input_len: usize) !void {
            var stage: ImagePasteStage = .{};
            defer stage.deinit(app.alloc);

            const drop_shaped = paste_decoder.isDropShapedPaste(bytes);
            const first_image_id = app.peekNextImageId();
            var prev: usize = 0;
            var i: usize = 0;
            while (i < bytes.len) {
                while (i < bytes.len and image_attachments.isWhitespace(bytes[i])) : (i += 1) {}
                if (i >= bytes.len) break;
                const start = i;
                i = image_attachments.nextShellTokenEnd(bytes, start);
                const raw = bytes[start..i];
                if (image_attachments.splitImagePathToken(raw)) |token| {
                    const decoded_image_url = try paste_decoder.decodeFileUrl(app.alloc, token.path);
                    defer if (decoded_image_url) |path| app.alloc.free(path);
                    const load_path = decoded_image_url orelse token.path;
                    const maybe_img = image_attachments.loadUserImageAttachment(
                        app.alloc,
                        app.workspace_root,
                        load_path,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        error.ImageTooLarge => blk: {
                            try reportImageTooLarge(app);
                            break :blk null;
                        },
                        else => null,
                    };
                    if (maybe_img) |img| {
                        var attached = img;
                        var owns_attached = true;
                        defer if (owns_attached) {
                            image_attachments.discardImageAttachment(app.alloc, attached);
                        };

                        const id = std.math.add(
                            usize,
                            first_image_id,
                            stage.images.items.len,
                        ) catch return error.ImageIdOverflow;
                        attached.id = id;
                        switch (try image_attachments.captureImageAttachmentForAdmission(App, app, &attached)) {
                            .captured => {},
                            .rejected => continue,
                        }

                        var ph_buf: [32]u8 = undefined;
                        const placeholder = try image_attachments.formatImagePlaceholder(&ph_buf, id);
                        try stage.replacement.appendSlice(app.alloc, bytes[prev..start]);
                        const relative_start = stage.replacement.items.len;
                        try stage.replacement.appendSlice(app.alloc, placeholder);
                        try stage.tokens.append(app.alloc, .{
                            .span = .{
                                .raw_start = relative_start,
                                .raw_end = relative_start + placeholder.len,
                            },
                            .id = id,
                        });
                        try stage.replacement.appendSlice(app.alloc, token.suffix);
                        try stage.images.append(app.alloc, attached);
                        owns_attached = false;
                        prev = i;
                        continue;
                    }
                } else if (drop_shaped) {
                    const decoded_file_url = try paste_decoder.decodeFileUrl(app.alloc, raw);
                    defer if (decoded_file_url) |path| app.alloc.free(path);
                    const path: ?[]const u8 = if (decoded_file_url) |owned|
                        owned
                    else
                        dropAbsolutePath(raw);
                    if (path) |dropped_path| {
                        try stage.replacement.appendSlice(app.alloc, bytes[prev..start]);
                        try stage.replacement.appendSlice(app.alloc, dropped_path);
                        try stage.replacement.append(app.alloc, ' ');
                        prev = i;
                    }
                }
            }
            try stage.replacement.appendSlice(app.alloc, bytes[prev..]);
            try commitImagePasteStage(app, &stage, first_image_id, bytes.len, max_input_len);
        }

        fn dropAbsolutePath(raw: []const u8) ?[]const u8 {
            const trimmed = image_attachments.stripBalancedOuterQuotes(std.mem.trim(u8, raw, " \t\r\n"));
            return if (trimmed.len > 0 and trimmed[0] == '/') trimmed else null;
        }

        fn commitImagePasteStage(
            app: *App,
            stage: *ImagePasteStage,
            first_image_id: usize,
            attempted_bytes: usize,
            max_input_len: usize,
        ) !void {
            const image_count = stage.images.items.len;
            const start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                selection.start
            else
                app.input_runtime.edit_state.cursor;
            if (image_count == 0) {
                switch (try app.input_runtime.replacementState(&app.pending_images).replaceSelectionOrInsertSliceBounded(
                    app.alloc,
                    stage.replacement.items,
                    max_input_len,
                    .preserve,
                )) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        maybeOpenPastedSkillMenu(
                            app,
                            start,
                            start + stage.replacement.items.len,
                        );
                    },
                    .inactive => unreachable,
                    .limit_exceeded => try input_limit_feedback.report(
                        App,
                        app,
                        .composer,
                        attempted_bytes,
                    ),
                }
                return;
            }

            const replacement = app.input_runtime.replacementState(&app.pending_images);
            if (!replacement.canReplaceSelectionOrInsert(
                stage.replacement.items.len,
                max_input_len,
            )) {
                try input_limit_feedback.report(App, app, .composer, attempted_bytes);
                return;
            }

            const next_image_id = std.math.add(
                usize,
                first_image_id,
                image_count,
            ) catch return error.ImageIdOverflow;

            try app.input_runtime.edit_state.input.ensureUnusedCapacity(app.alloc, stage.replacement.items.len);
            try app.pending_images.ensureUnusedCapacity(app.alloc, image_count);
            try app.input_runtime.entities.image_tokens.ensureUnusedCapacity(app.alloc, image_count);

            if (image_count > 0 and app.pending_images.items.len > 0) {
                std.debug.assert(
                    app.pending_images.items[app.pending_images.items.len - 1].id <
                        stage.images.items[0].id,
                );
            }

            const structured_start = start;
            std.debug.assert(try replacement.replaceSelectionOrInsertSliceBounded(
                app.alloc,
                stage.replacement.items,
                max_input_len,
                .preserve,
            ) == .inserted);
            for (stage.images.items) |image| {
                app.pending_images.appendAssumeCapacity(image);
            }
            stage.images.clearRetainingCapacity();
            for (stage.tokens.items) |token| {
                app.input_runtime.entities.registerImageTokenAssumeCapacity(.{
                    .span = .{
                        .raw_start = structured_start + token.span.raw_start,
                        .raw_end = structured_start + token.span.raw_end,
                    },
                    .id = token.id,
                });
            }

            for (0..image_count) |offset| {
                const committed_id = app.nextImageId();
                std.debug.assert(committed_id == first_image_id + offset);
            }
            std.debug.assert(app.peekNextImageId() == next_image_id);

            if (image_count > 0) {
                if (comptime @hasDecl(@TypeOf(app.input_runtime), "historyBoundary")) {
                    app.input_runtime.historyBoundary(app.alloc);
                }
            }
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            maybeOpenPastedSkillMenu(
                app,
                structured_start,
                structured_start + stage.replacement.items.len,
            );
            if (image_count > 0) {
                app.input_runtime.picker.clearModelPickerFlow();
                app.input_runtime.picker.resetFilePickerIndex();
            }
        }

        fn reportImageTooLarge(app: *App) !void {
            if (comptime !@hasDecl(App, "writeDomainNotice")) return error.ImageTooLarge;
            try app.writeDomainNotice(.{
                .topic = "images",
                .tone = .@"error",
                .body = image_attachments.image_too_large_notice,
            }, true);
        }

        fn reportImageAttachFailure(app: *App, err: anyerror) !void {
            if (comptime !@hasDecl(App, "writeDomainNotice")) return err;
            const line = try std.fmt.allocPrint(app.alloc, "failed to attach pasted image: {s}", .{@errorName(err)});
            defer app.alloc.free(line);
            try app.writeDomainNotice(.{
                .topic = "images",
                .tone = .@"error",
                .body = line,
            }, true);
        }

        fn maybeOpenPastedSkillMenu(app: *App, start: usize, end: usize) void {
            if (comptime !@hasField(App, "skills")) return;
            if (app.skills.menu.active) return;

            const input = app.input_runtime.edit_state.input.items;
            var index = @min(start, input.len);
            const limit = @min(end, input.len);
            while (index < limit) : (index += 1) {
                if (input[index] != '$') continue;
                const query_start = index + 1;
                const query_end = skillTokenEnd(input, query_start);
                if (query_end == query_start) continue;

                const query = input[query_start..query_end];
                if (skill_runtime.skillMenuFilterQueryCount(app.skills.items, .all, query) == 0) continue;
                app.skills.openMenuWithQuery(.paste, .{ .start = index, .end = query_end }, query);
                return;
            }
        }

        fn skillTokenEnd(input: []const u8, start: usize) usize {
            var end = start;
            while (end < input.len) : (end += 1) {
                const byte = input[end];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) break;
            }
            return end;
        }
    };
}

test "approval amendment paste normalizes line and tab separators to spaces" {
    var storage = [_]u8{ 'o', 'n', 'e', '\r', '\n', 't', 'w', 'o', '\r', 't', 'h', 'r', 'e', 'e', '\n', '\t', 'f', 'o', 'u', 'r' };
    const normalized = normalizeApprovalAmendmentPasteInPlace(&storage);

    try std.testing.expectEqualStrings("one two three  four", normalized);
}

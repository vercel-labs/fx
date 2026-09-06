const std = @import("std");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const types = @import("../shared/types.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const paste_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_boundaries = @import("text_boundaries.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

pub const ImageBlocks = std.ArrayList(types.ImageAttachment);

pub const YankResult = union(enum) {
    inactive,
    limit_exceeded: usize,
    inserted: usize,
};

pub const LineBounds = struct {
    start: usize,
    cursor: usize,
    end: usize,
};

pub const DeleteRange = struct {
    start: usize,
    end: usize,
};

pub const ActiveComposer = struct {
    edit: *editor_state.State,
    entities: *registered_entities.State,
    picker: *picker_state.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,
    images: ?*ImageBlocks,
};

pub const State = struct {
    text: std.ArrayList(u8) = .empty,
    images: ImageBlocks = .empty,
    image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,
    skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty,
    owns_snapshots: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.text.deinit(alloc);
        for (self.images.items) |image| {
            if (self.owns_snapshots) {
                image_attachments.discardImageAttachment(alloc, image);
            } else {
                types.freeImageAttachment(alloc, image);
            }
        }
        self.images.deinit(alloc);
        self.image_tokens.deinit(alloc);
        for (self.skill_tokens.items) |token| {
            alloc.free(token.name);
            alloc.free(token.path);
        }
        self.skill_tokens.deinit(alloc);
        self.* = .{};
    }

    pub fn resetForSession(self: *State, alloc: Allocator) void {
        if (self.text.items.len > 0) {
            debug_trace.logf(
                "input",
                "kill ring dropped bytes={d} images={d} skills={d} reason=session_reset",
                .{
                    self.text.items.len,
                    self.images.items.len,
                    self.skill_tokens.items.len,
                },
            );
        }
        self.deinit(alloc);
    }

    pub fn deleteRange(
        self: *State,
        alloc: Allocator,
        active: ActiveComposer,
        bounds: LineBounds,
        requested: DeleteRange,
    ) !bool {
        if (requested.start >= requested.end) return false;
        const actual = actualDeleteRange(
            active.entities.pasted_blocks.items,
            active.entities.image_tokens.items,
            bounds,
            requested,
        ) orelse return false;

        var next = try capturePayload(alloc, active, actual);
        errdefer next.deinit(alloc);

        active.picker.clearModelPickerFlow();
        active.picker.resetFilePickerIndex();
        removeBackingMetadata(alloc, active, actual);
        next.owns_snapshots = true;
        deleteInputRange(alloc, active, actual.start, actual.end);
        _ = active.edit.setCursor(actual.start);
        active.picker.reconcileInlinePickerAfterEdit(active.edit);
        active.picker.resetActiveCompletionIndex();

        var previous = self.*;
        self.* = next;
        previous.deinit(alloc);
        return true;
    }

    pub fn yank(
        self: *const State,
        alloc: Allocator,
        active: ActiveComposer,
        first_image_id: usize,
        max_len: usize,
    ) !YankResult {
        if (self.text.items.len == 0) return .inactive;

        const replacement_len = try self.replacementLen(first_image_id);
        const selection = active.edit.selectionRange();
        const admitted = if (selection) |range|
            canReplaceInputRange(active, range.start, range.end, replacement_len, max_len)
        else
            canInsertInput(active, replacement_len, max_len);
        if (!admitted) return .{ .limit_exceeded = replacement_len };

        var prepared = try self.prepareYank(alloc, first_image_id);
        defer prepared.deinit(alloc);
        std.debug.assert(prepared.text.items.len == replacement_len);

        const image_count = prepared.images.items.len;
        const blocks = if (image_count > 0)
            active.images orelse return error.MissingImageAttachmentOwner
        else
            null;
        try active.edit.input.ensureUnusedCapacity(alloc, prepared.text.items.len);
        try active.entities.image_tokens.ensureUnusedCapacity(alloc, prepared.image_tokens.items.len);
        try active.entities.skill_tokens.ensureUnusedCapacity(alloc, prepared.skill_tokens.items.len);
        if (blocks) |active_images| {
            try active_images.ensureUnusedCapacity(alloc, prepared.images.items.len);
            if (active_images.items.len > 0) {
                std.debug.assert(active_images.items[active_images.items.len - 1].id < first_image_id);
            }
        }

        const insertion_start = if (selection) |range| range.start else active.edit.cursor;
        active.vertical_navigation.reset();
        if (selection) |range| {
            removeRegisteredEntitiesOverlapping(alloc, active, range.start, range.end);
            deleteInputRange(alloc, active, range.start, range.end);
            _ = active.edit.setCursor(range.start);
            _ = active.edit.clearSelection();
        }
        insertInputSliceAssumeCapacity(alloc, active, prepared.text.items);
        if (blocks) |active_images| {
            active_images.appendSliceAssumeCapacity(prepared.images.items);
            prepared.images.clearRetainingCapacity();
        }
        for (prepared.image_tokens.items) |token| {
            active.entities.registerImageTokenAssumeCapacity(.{
                .id = token.id,
                .span = .{
                    .raw_start = insertion_start + token.span.raw_start,
                    .raw_end = insertion_start + token.span.raw_end,
                },
            });
        }
        for (prepared.skill_tokens.items) |token| {
            active.entities.registerSkillTokenAssumeCapacity(.{
                .raw_start = insertion_start + token.raw_start,
                .raw_end = insertion_start + token.raw_end,
                .name = token.name,
                .path = token.path,
                .display_source = token.display_source,
                .owns_trailing_separator = token.owns_trailing_separator,
            });
        }
        prepared.skill_tokens.clearRetainingCapacity();
        active.input_limit_rejection.* = input_limit_rejection.clear();
        return .{ .inserted = image_count };
    }

    fn replacementLen(self: *const State, first_image_id: usize) !usize {
        _ = try std.math.add(usize, first_image_id, self.image_tokens.items.len);
        var replacement_len = self.text.items.len;
        var previous_end: usize = 0;
        for (self.image_tokens.items, 0..) |token, index| {
            if (!token.span.isValid(self.text.items.len) or
                token.span.raw_start < previous_end)
            {
                return error.InvalidKillPayload;
            }
            const match = image_attachments.matchImagePlaceholder(
                self.text.items,
                token.span.raw_start,
            ) orelse return error.InvalidKillPayload;
            if (match.id != token.id or token.span.raw_start + match.length != token.span.raw_end) {
                return error.InvalidKillPayload;
            }
            const next_id = try std.math.add(usize, first_image_id, index);
            var placeholder_buf: [64]u8 = undefined;
            const placeholder = try image_attachments.formatImagePlaceholder(
                &placeholder_buf,
                next_id,
            );
            replacement_len = try std.math.sub(
                usize,
                replacement_len,
                token.span.raw_end - token.span.raw_start,
            );
            replacement_len = try std.math.add(usize, replacement_len, placeholder.len);
            previous_end = token.span.raw_end;
        }
        return replacement_len;
    }

    fn prepareYank(
        self: *const State,
        alloc: Allocator,
        first_image_id: usize,
    ) !State {
        var prepared = State{ .owns_snapshots = true };
        errdefer prepared.deinit(alloc);

        var source_offset: usize = 0;
        for (self.image_tokens.items, 0..) |token, index| {
            if (index >= self.images.items.len or self.images.items[index].id != token.id) {
                return error.InvalidKillPayload;
            }
            try prepared.text.appendSlice(
                alloc,
                self.text.items[source_offset..token.span.raw_start],
            );
            const relative_start = prepared.text.items.len;
            const next_id = try std.math.add(usize, first_image_id, index);
            var placeholder_buf: [64]u8 = undefined;
            const placeholder = try image_attachments.formatImagePlaceholder(
                &placeholder_buf,
                next_id,
            );
            try prepared.text.appendSlice(alloc, placeholder);
            try prepared.appendYankedImage(
                alloc,
                self.images.items[index],
                .{
                    .id = next_id,
                    .span = .{
                        .raw_start = relative_start,
                        .raw_end = relative_start + placeholder.len,
                    },
                },
            );
            source_offset = token.span.raw_end;
        }
        if (self.images.items.len != self.image_tokens.items.len) {
            return error.InvalidKillPayload;
        }
        try prepared.text.appendSlice(alloc, self.text.items[source_offset..]);

        for (self.skill_tokens.items) |token| {
            if (token.raw_start >= token.raw_end or token.raw_end > self.text.items.len) {
                return error.InvalidKillPayload;
            }
            const raw = self.text.items[token.raw_start..token.raw_end];
            if (raw.len != token.name.len + 1 or
                raw[0] != '$' or
                !std.mem.eql(u8, raw[1..], token.name))
            {
                return error.InvalidKillPayload;
            }
            const relative_start = image_attachments.projectOffsetThroughPlaceholderRewrite(
                self.image_tokens.items,
                prepared.image_tokens.items,
                self.text.items.len,
                token.raw_start,
            ) orelse return error.InvalidKillPayload;
            const relative_end = image_attachments.projectOffsetThroughPlaceholderRewrite(
                self.image_tokens.items,
                prepared.image_tokens.items,
                self.text.items.len,
                token.raw_end,
            ) orelse return error.InvalidKillPayload;
            try prepared.appendSkillCopy(
                alloc,
                relative_start,
                relative_end,
                token.name,
                token.path,
                token.display_source,
                token.owns_trailing_separator,
            );
        }
        return prepared;
    }

    fn appendImageCopy(
        self: *State,
        alloc: Allocator,
        attachment: types.ImageAttachment,
        token: entity_spans.ImageTokenSpan,
    ) !void {
        try self.image_tokens.append(alloc, token);
        errdefer self.image_tokens.items.len -= 1;

        const path = try alloc.dupe(u8, attachment.path);
        errdefer alloc.free(path);
        const media_type = try alloc.dupe(u8, attachment.media_type);
        errdefer alloc.free(media_type);
        const snapshot_path = if (attachment.snapshot_path) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (snapshot_path) |value| alloc.free(value);
        const snapshot_sha256 = if (attachment.snapshot_sha256) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (snapshot_sha256) |value| alloc.free(value);
        try self.images.append(alloc, .{
            .id = token.id,
            .path = path,
            .media_type = media_type,
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = snapshot_sha256,
        });
    }

    fn appendYankedImage(
        self: *State,
        alloc: Allocator,
        attachment: types.ImageAttachment,
        token: entity_spans.ImageTokenSpan,
    ) !void {
        try self.image_tokens.append(alloc, token);
        errdefer self.image_tokens.items.len -= 1;

        const cloned = try image_attachments.cloneVerifiedImageAttachment(
            alloc,
            attachment,
            token.id,
        );
        errdefer image_attachments.discardImageAttachment(alloc, cloned);
        try self.images.append(alloc, cloned);
    }

    fn appendSkillCopy(
        self: *State,
        alloc: Allocator,
        raw_start: usize,
        raw_end: usize,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
        owns_trailing_separator: bool,
    ) !void {
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);
        try self.skill_tokens.append(alloc, .{
            .raw_start = raw_start,
            .raw_end = raw_end,
            .name = owned_name,
            .path = owned_path,
            .display_source = display_source,
            .owns_trailing_separator = owns_trailing_separator,
        });
    }
};

pub fn lineBounds(input: []const u8, cursor: usize) LineBounds {
    const clamped = @min(cursor, input.len);
    return .{
        .start = text_boundaries.logicalLineStart(input, clamped),
        .cursor = clamped,
        .end = text_boundaries.logicalLineEnd(input, clamped),
    };
}

fn actualDeleteRange(
    pasted: []const paste_blocks.PastedBlock,
    image_tokens: []const entity_spans.ImageTokenSpan,
    bounds: LineBounds,
    requested: DeleteRange,
) ?DeleteRange {
    if (requested.start >= requested.end) return requested;

    var actual = requested;
    while (true) {
        var changed = false;
        for (pasted) |block| {
            const span_range = DeleteRange{
                .start = block.span.raw_start,
                .end = block.span.raw_end,
            };
            if (rangesOverlap(actual, span_range) and !rangeContains(actual, span_range)) {
                actual.start = @min(actual.start, span_range.start);
                actual.end = @max(actual.end, span_range.end);
                if (actual.start < bounds.start or actual.end > bounds.end) return null;
                changed = true;
            }
        }

        for (image_tokens) |token| {
            const span_range = DeleteRange{
                .start = token.span.raw_start,
                .end = token.span.raw_end,
            };
            if (rangesOverlap(actual, span_range) and !rangeContains(actual, span_range)) {
                actual.start = @min(actual.start, span_range.start);
                actual.end = @max(actual.end, span_range.end);
                if (actual.start < bounds.start or actual.end > bounds.end) return null;
                changed = true;
            }
        }
        if (!changed) break;
    }
    return actual;
}

fn capturePayload(
    alloc: Allocator,
    active: ActiveComposer,
    actual: DeleteRange,
) !State {
    var payload: State = .{};
    errdefer payload.deinit(alloc);

    const expanded = try paste_blocks.expandRange(
        alloc,
        active.edit.input.items,
        active.entities.pasted_blocks.items,
        actual.start,
        actual.end,
    );
    defer if (expanded.owned) alloc.free(expanded.text);
    try payload.text.appendSlice(alloc, expanded.text);

    const expanded_origin = paste_blocks.projectOffsetThroughExpansion(
        active.edit.input.items,
        active.entities.pasted_blocks.items,
        actual.start,
    ) orelse return error.InvalidKillRange;
    const actual_span = entity_spans.Span{
        .raw_start = actual.start,
        .raw_end = actual.end,
    };

    for (active.entities.image_tokens.items) |token| {
        if (!entity_spans.containsSpan(actual_span, token.span)) continue;
        if (!active.entities.isValidImageToken(active.edit.input.items, token)) continue;
        const blocks = active.images orelse return error.MissingImageAttachment;
        const attachment = image_attachments.findById(blocks.items, token.id) orelse
            return error.MissingImageAttachment;
        const relative_start = try projectKillOffset(
            active,
            actual,
            expanded_origin,
            token.span.raw_start,
        );
        const relative_end = try projectKillOffset(
            active,
            actual,
            expanded_origin,
            token.span.raw_end,
        );
        try payload.appendImageCopy(alloc, attachment, .{
            .id = token.id,
            .span = .{
                .raw_start = relative_start,
                .raw_end = relative_end,
            },
        });
    }

    for (active.entities.skill_tokens.items) |token| {
        const span = entity_spans.Span{
            .raw_start = token.raw_start,
            .raw_end = token.raw_end,
        };
        if (!entity_spans.containsSpan(actual_span, span)) continue;
        if (!active.entities.isValidSkillToken(active.edit.input.items, token)) continue;
        const relative_start = try projectKillOffset(
            active,
            actual,
            expanded_origin,
            token.raw_start,
        );
        const relative_end = try projectKillOffset(
            active,
            actual,
            expanded_origin,
            token.raw_end,
        );
        try payload.appendSkillCopy(
            alloc,
            relative_start,
            relative_end,
            token.name,
            token.path,
            token.display_source,
            token.owns_trailing_separator and
                token.raw_end < actual.end and
                token.raw_end < active.edit.input.items.len and
                active.edit.input.items[token.raw_end] == ' ',
        );
    }
    return payload;
}

fn projectKillOffset(
    active: ActiveComposer,
    actual: DeleteRange,
    expanded_origin: usize,
    raw_offset: usize,
) !usize {
    if (raw_offset < actual.start or raw_offset > actual.end) {
        return error.InvalidKillRange;
    }
    const projected = paste_blocks.projectOffsetThroughExpansion(
        active.edit.input.items,
        active.entities.pasted_blocks.items,
        raw_offset,
    ) orelse return error.InvalidKillRange;
    return std.math.sub(usize, projected, expanded_origin);
}

fn removeBackingMetadata(
    alloc: Allocator,
    active: ActiveComposer,
    actual: DeleteRange,
) void {
    var paste_index: usize = 0;
    while (paste_index < active.entities.pasted_blocks.items.len) {
        const block = active.entities.pasted_blocks.items[paste_index];
        const span_range = DeleteRange{
            .start = block.span.raw_start,
            .end = block.span.raw_end,
        };
        if (span_range.start >= span_range.end or !rangeContains(actual, span_range)) {
            paste_index += 1;
            continue;
        }
        debug_trace.logf(
            "input",
            "placeholder backing dropped kind=paste id={d} backing_bytes={d} reason=atomic_line_delete",
            .{ block.id, block.text.len },
        );
        const removed = active.entities.pasted_blocks.orderedRemove(paste_index);
        alloc.free(removed.text);
    }

    var image_index: usize = 0;
    while (image_index < active.entities.image_tokens.items.len) {
        const token = active.entities.image_tokens.items[image_index];
        const span_range = DeleteRange{
            .start = token.span.raw_start,
            .end = token.span.raw_end,
        };
        if (span_range.start >= span_range.end or !rangeContains(actual, span_range)) {
            image_index += 1;
            continue;
        }
        debug_trace.logf(
            "input",
            "placeholder backing dropped kind=image id={d} reason=atomic_line_delete",
            .{token.id},
        );
        _ = active.entities.image_tokens.orderedRemove(image_index);
        if (active.images) |blocks| {
            if (imageBlockIndexById(blocks.items, token.id)) |block_index| {
                const removed = blocks.orderedRemove(block_index);
                types.freeImageAttachment(alloc, removed);
            }
        }
    }
}

fn canInsertInput(active: ActiveComposer, inserted_len: usize, max_len: usize) bool {
    const current_len = paste_blocks.expandedLen(
        active.edit.input.items,
        active.entities.pasted_blocks.items,
    ) orelse return false;
    return editor_state.canInsert(current_len, inserted_len, max_len);
}

fn canReplaceInputRange(
    active: ActiveComposer,
    replace_start: usize,
    replace_end: usize,
    inserted_len: usize,
    max_len: usize,
) bool {
    const current_len = paste_blocks.expandedLen(
        active.edit.input.items,
        active.entities.pasted_blocks.items,
    ) orelse return false;
    const replaced_len = paste_blocks.expandedRangeLen(
        active.edit.input.items,
        active.entities.pasted_blocks.items,
        replace_start,
        replace_end,
    ) orelse return false;
    return editor_state.canReplace(current_len, replaced_len, inserted_len, max_len);
}

fn deleteInputRange(
    alloc: Allocator,
    active: ActiveComposer,
    start: usize,
    end: usize,
) void {
    if (start >= end or end > active.edit.input.items.len) return;
    active.entities.discardPendingAutoSeparator();
    active.entities.adjustForDelete(alloc, start, end);
    std.debug.assert(active.edit.deleteTextRange(start, end));
    active.input_limit_rejection.* = input_limit_rejection.clear();
}

fn insertInputSliceAssumeCapacity(
    alloc: Allocator,
    active: ActiveComposer,
    bytes: []const u8,
) void {
    if (bytes.len == 0) return;
    active.entities.discardPendingAutoSeparator();
    const insert_start = active.edit.cursor;
    active.entities.convertSkillTokenContaining(alloc, insert_start);
    active.edit.insertSliceAssumeCapacity(bytes);
    active.entities.shiftForInsert(alloc, insert_start, bytes.len);
    active.picker.reconcileInlinePickerAfterEdit(active.edit);
    active.picker.resetActiveCompletionIndex();
}

fn removeRegisteredEntitiesOverlapping(
    alloc: Allocator,
    active: ActiveComposer,
    raw_start: usize,
    raw_end: usize,
) void {
    while (active.entities.entityOverlapping(raw_start, raw_end)) |entity| {
        if (active.entities.remove(alloc, entity)) |image_id| {
            if (active.images) |blocks| removeImageBlockById(alloc, blocks, image_id);
        }
    }
}

fn removeImageBlockById(alloc: Allocator, blocks: *ImageBlocks, id: usize) void {
    var index: usize = 0;
    while (index < blocks.items.len) : (index += 1) {
        if (blocks.items[index].id == id) {
            const removed = blocks.orderedRemove(index);
            image_attachments.discardImageAttachment(alloc, removed);
            return;
        }
    }
}

fn rangesOverlap(a: DeleteRange, b: DeleteRange) bool {
    return a.start < b.end and b.start < a.end;
}

fn rangeContains(outer: DeleteRange, inner: DeleteRange) bool {
    return outer.start <= inner.start and inner.end <= outer.end;
}

fn imageBlockIndexById(blocks: []const types.ImageAttachment, id: usize) ?usize {
    for (blocks, 0..) |image, index| {
        if (image.id == id) return index;
    }
    return null;
}

test "state captures and yanks a logical line prefix through the active composer" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    try edit.setText(alloc, "alpha\nleftMIDright");
    edit.cursor = "alpha\nleftMID".len;
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var picker: picker_state.State = .{};
    defer picker.deinit(alloc);
    var vertical_intent: vertical_navigation.State = .{ .preferred_column = 4 };
    var limit_rejection: input_limit_rejection.State = .{ .owner = .composer };
    const active = ActiveComposer{
        .edit = &edit,
        .entities = &entities,
        .picker = &picker,
        .vertical_navigation = &vertical_intent,
        .input_limit_rejection = &limit_rejection,
        .images = null,
    };

    const bounds = lineBounds(edit.input.items, edit.cursor);
    try std.testing.expect(try state.deleteRange(
        alloc,
        active,
        bounds,
        .{ .start = bounds.start, .end = bounds.cursor },
    ));
    try std.testing.expectEqualStrings("alpha\nright", edit.input.items);
    try std.testing.expectEqualStrings("leftMID", state.text.items);
    try std.testing.expectEqual(input_limit_rejection.State{}, limit_rejection);

    try std.testing.expectEqual(
        YankResult{ .inserted = 0 },
        try state.yank(alloc, active, 1, 4096),
    );
    try std.testing.expectEqualStrings("alpha\nleftMIDright", edit.input.items);
}

test "limit rejection leaves active composer and kill state unchanged" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.text.appendSlice(alloc, "XY");
    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    try edit.setText(alloc, "abc");
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var picker: picker_state.State = .{};
    defer picker.deinit(alloc);
    var vertical_intent: vertical_navigation.State = .{ .preferred_column = 2 };
    var limit_rejection: input_limit_rejection.State = .{ .owner = .composer };
    const active = ActiveComposer{
        .edit = &edit,
        .entities = &entities,
        .picker = &picker,
        .vertical_navigation = &vertical_intent,
        .input_limit_rejection = &limit_rejection,
        .images = null,
    };

    try std.testing.expectEqual(
        YankResult{ .limit_exceeded = 2 },
        try state.yank(alloc, active, 1, 4),
    );
    try std.testing.expectEqualStrings("abc", edit.input.items);
    try std.testing.expectEqualStrings("XY", state.text.items);
    try std.testing.expectEqual(@as(?usize, 2), vertical_intent.preferredColumn());
    try std.testing.expectEqual(
        input_limit_rejection.State{ .owner = .composer },
        limit_rejection,
    );
}

test "line bounds assign the cursor to logical lines" {
    const cases = [_]struct {
        input: []const u8,
        cursor: usize,
        expected: LineBounds,
    }{
        .{ .input = "", .cursor = 0, .expected = .{ .start = 0, .cursor = 0, .end = 0 } },
        .{ .input = "alpha", .cursor = 99, .expected = .{ .start = 0, .cursor = 5, .end = 5 } },
        .{ .input = "alpha\nbeta\ngamma", .cursor = 5, .expected = .{ .start = 0, .cursor = 5, .end = 5 } },
        .{ .input = "alpha\nbeta\ngamma", .cursor = 6, .expected = .{ .start = 6, .cursor = 6, .end = 10 } },
        .{ .input = "alpha\n\nbeta", .cursor = 6, .expected = .{ .start = 6, .cursor = 6, .end = 6 } },
        .{ .input = "alpha\n", .cursor = 6, .expected = .{ .start = 6, .cursor = 6, .end = 6 } },
        .{ .input = "\nalpha", .cursor = 0, .expected = .{ .start = 0, .cursor = 0, .end = 0 } },
        .{ .input = "\nalpha", .cursor = 1, .expected = .{ .start = 1, .cursor = 1, .end = 6 } },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, lineBounds(case.input, case.cursor));
    }
}

test "delete ranges expand registered entities and reject cross-line spans" {
    const blocks = [_]paste_blocks.PastedBlock{.{
        .id = 7,
        .text = @constCast("outer"),
        .line_count = 1,
        .span = .{ .raw_start = 3, .raw_end = 12 },
    }};
    const images = [_]entity_spans.ImageTokenSpan{.{
        .id = 8,
        .span = .{ .raw_start = 12, .raw_end = 20 },
    }};
    const expanded = actualDeleteRange(
        &blocks,
        &images,
        .{ .start = 0, .cursor = 11, .end = 20 },
        .{ .start = 11, .end = 13 },
    ).?;
    try std.testing.expectEqual(DeleteRange{ .start = 3, .end = 20 }, expanded);

    try std.testing.expect(actualDeleteRange(
        &blocks,
        &.{},
        .{ .start = 10, .cursor = 11, .end = 20 },
        .{ .start = 11, .end = 12 },
    ) == null);
}

const std = @import("std");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const composer_insertion = @import("composer_insertion.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const pasted_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

pub const ImageBlocks = std.ArrayList(types.ImageAttachment);
pub const InsertResult = composer_insertion.InsertResult;

pub const Range = struct {
    start: usize,
    end: usize,
};

const Plan = struct {
    growth: usize,
    cursor_after: usize,
};

/// Describes a raw composer range replacement without changing editor state.
fn plan(
    input_len: usize,
    range: Range,
    replacement_len: usize,
    requested_cursor_after: usize,
) ?Plan {
    if (range.start > range.end or range.end > input_len) return null;
    const removed_len = range.end - range.start;
    const next_len = (input_len - removed_len) +| replacement_len;
    return .{
        .growth = replacement_len -| removed_len,
        .cursor_after = @min(requested_cursor_after, next_len),
    };
}

/// Borrows the state changed by one bounded composer range replacement.
/// The containing runtime retains ownership of every pointer and allocation.
pub const State = struct {
    insertion: composer_insertion.State,
    images: ?*ImageBlocks = null,

    pub fn availableBytesForSelectionOrInsertion(
        self: State,
        max_len: usize,
    ) usize {
        const current_len = self.insertion.expandedInputLen() orelse return 0;
        const selected_len = if (self.insertion.edit.selectionRange()) |selection|
            pasted_blocks.expandedRangeLen(
                self.insertion.edit.input.items,
                self.insertion.entities.pasted_blocks.items,
                selection.start,
                selection.end,
            ) orelse return 0
        else
            0;
        return max_len -| (current_len -| selected_len);
    }

    pub fn canReplaceSelectionOrInsert(
        self: State,
        inserted_len: usize,
        max_len: usize,
    ) bool {
        if (self.insertion.edit.selectionRange()) |selection| {
            return self.insertion.canReplaceRange(
                selection.start,
                selection.end,
                inserted_len,
                max_len,
            );
        }
        return self.insertion.canInsert(inserted_len, max_len);
    }

    pub fn replaceSelectionOrInsertSliceBounded(
        self: State,
        alloc: Allocator,
        bytes: []const u8,
        max_len: usize,
        picker_policy: composer_insertion.PickerPolicy,
    ) Allocator.Error!InsertResult {
        if (self.insertion.edit.selectionRange() == null) {
            return self.insertion.insertSliceBounded(
                alloc,
                bytes,
                max_len,
                picker_policy,
            );
        }

        const result = try self.replaceSelectionBounded(alloc, bytes, max_len);
        if (result == .inserted and picker_policy == .clear) {
            self.insertion.picker.clearModelPickerFlow();
        }
        return result;
    }

    pub fn replaceRangeBounded(
        self: State,
        alloc: Allocator,
        range: Range,
        replacement: []const u8,
        cursor_after: usize,
        max_len: usize,
    ) Allocator.Error!InsertResult {
        const replacement_plan = plan(
            self.insertion.edit.input.items.len,
            range,
            replacement.len,
            cursor_after,
        ) orelse return .inactive;
        if (!self.insertion.canReplaceRange(
            range.start,
            range.end,
            replacement.len,
            max_len,
        )) return .limit_exceeded;

        if (replacement_plan.growth > 0) {
            try self.insertion.edit.input.ensureUnusedCapacity(
                alloc,
                replacement_plan.growth,
            );
        }

        var prepared = self.prepareHistory(
            alloc,
            range,
            replacement,
            replacement_plan.cursor_after,
            "range_replace",
        );
        defer prepared.deinit(alloc);
        self.applyReplacement(
            alloc,
            range,
            replacement,
            replacement_plan.cursor_after,
        );
        self.insertion.history.commit(alloc, &prepared);
        return .inserted;
    }

    pub fn replaceSelectionBounded(
        self: State,
        alloc: Allocator,
        replacement: []const u8,
        max_len: usize,
    ) Allocator.Error!InsertResult {
        const selection = self.insertion.edit.selectionRange() orelse return .inactive;
        const result = try self.replaceRangeBounded(
            alloc,
            .{ .start = selection.start, .end = selection.end },
            replacement,
            selection.start +| replacement.len,
            max_len,
        );
        if (result == .inserted) _ = self.insertion.edit.clearSelection();
        return result;
    }

    pub fn deleteSelection(self: State, alloc: Allocator) bool {
        const selection = self.insertion.edit.selectionRange() orelse return false;
        const range: Range = .{ .start = selection.start, .end = selection.end };
        if (!self.insertion.canReplaceRange(
            range.start,
            range.end,
            0,
            self.insertion.edit.input.items.len,
        )) return false;
        if (!self.deleteRange(alloc, range, selection.start)) return false;
        _ = self.insertion.edit.clearSelection();
        return true;
    }

    pub fn deleteRange(
        self: State,
        alloc: Allocator,
        range: Range,
        cursor_after: usize,
    ) bool {
        const replacement_plan = plan(
            self.insertion.edit.input.items.len,
            range,
            0,
            cursor_after,
        ) orelse return false;

        var prepared = self.prepareHistory(
            alloc,
            range,
            "",
            replacement_plan.cursor_after,
            "range_delete",
        );
        defer prepared.deinit(alloc);
        self.applyReplacement(
            alloc,
            range,
            "",
            replacement_plan.cursor_after,
        );
        self.insertion.history.commit(alloc, &prepared);
        return true;
    }

    fn prepareHistory(
        self: State,
        alloc: Allocator,
        range: Range,
        replacement: []const u8,
        cursor_after: usize,
        operation: []const u8,
    ) edit_history.Prepared {
        const structured = self.insertion.entities.entityOverlapping(
            range.start,
            range.end,
        ) != null or (range.start == range.end and
            self.insertion.entities.entityContaining(
                self.insertion.edit.input.items,
                range.start,
            ) != null);
        if (structured) return .boundary;

        return self.insertion.history.prepare(
            alloc,
            range.start,
            self.insertion.edit.input.items[range.start..range.end],
            replacement,
            self.insertion.edit.cursor,
            cursor_after,
        ) catch |err| {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=allocation_failure operation={s} error={s}",
                .{ operation, @errorName(err) },
            );
            self.insertion.history.reset(alloc);
            return .boundary;
        };
    }

    fn applyReplacement(
        self: State,
        alloc: Allocator,
        range: Range,
        replacement: []const u8,
        cursor_after: usize,
    ) void {
        self.removeRegisteredEntitiesOverlapping(alloc, range);
        self.deleteInputRange(alloc, range);
        _ = self.insertion.edit.setCursor(range.start);
        self.insertion.insertSliceAssumeCapacity(alloc, replacement);
        _ = self.insertion.edit.setCursor(cursor_after);
        self.insertion.input_limit_rejection.* = input_limit_rejection.clear();
    }

    fn deleteInputRange(self: State, alloc: Allocator, range: Range) void {
        if (range.start >= range.end) return;
        self.insertion.entities.discardPendingAutoSeparator();
        self.insertion.entities.adjustForDelete(alloc, range.start, range.end);
        std.debug.assert(self.insertion.edit.deleteTextRange(range.start, range.end));
    }

    fn removeRegisteredEntitiesOverlapping(
        self: State,
        alloc: Allocator,
        range: Range,
    ) void {
        while (self.insertion.entities.entityOverlapping(range.start, range.end)) |entity| {
            if (self.insertion.entities.remove(alloc, entity)) |image_id| {
                if (self.images) |images| removeImageById(alloc, images, image_id);
            }
        }
    }
};

fn removeImageById(alloc: Allocator, images: *ImageBlocks, id: usize) void {
    for (images.items, 0..) |image, index| {
        if (image.id != id) continue;
        const removed = images.orderedRemove(index);
        image_attachments.discardImageAttachment(alloc, removed);
        return;
    }
}

const Fixture = struct {
    edit: editor_state.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    history: edit_history.State = .{},
    vertical: vertical_navigation.State = .{},
    rejection: input_limit_rejection.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
        self.history.deinit(alloc);
    }

    fn replacement(self: *Fixture, images: ?*ImageBlocks) State {
        return .{
            .insertion = .{
                .edit = &self.edit,
                .history = &self.history,
                .picker = &self.picker,
                .entities = &self.entities,
                .vertical_navigation = &self.vertical,
                .input_limit_rejection = &self.rejection,
            },
            .images = images,
        };
    }
};

test "replacement plan validates ranges and clamps the final cursor" {
    try std.testing.expect(plan(6, .{ .start = 5, .end = 2 }, 1, 0) == null);
    try std.testing.expect(plan(6, .{ .start = 2, .end = 7 }, 1, 0) == null);
    try std.testing.expectEqual(
        Plan{
            .growth = 1,
            .cursor_after = 7,
        },
        plan(6, .{ .start = 2, .end = 5 }, 4, 99).?,
    );
}

test "bounded selection replacement preserves state on rejection" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "abcdef");

    _ = fixture.edit.beginSelection(2);
    _ = fixture.edit.extendSelection(5);
    try std.testing.expectEqual(
        InsertResult.inserted,
        try fixture.replacement(null).replaceSelectionBounded(alloc, "WXYZ", 7),
    );
    try std.testing.expectEqualStrings("abWXYZf", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 6), fixture.edit.cursor);
    try std.testing.expect(fixture.edit.selectionRange() == null);

    _ = fixture.edit.beginSelection(2);
    _ = fixture.edit.extendSelection(6);
    try fixture.picker.beginModelPickerFlow(alloc, "provider/model", 2, false, false, .effort);
    fixture.picker.file_completion_index = 3;
    fixture.picker.file_completion_window_start = 1;
    fixture.vertical.preferred_column = 7;
    fixture.rejection = .{ .owner = .composer };
    try std.testing.expectEqual(
        InsertResult.limit_exceeded,
        try fixture.replacement(null).replaceSelectionBounded(alloc, "123456789", 7),
    );
    try std.testing.expectEqualStrings("abWXYZf", fixture.edit.input.items);
    try std.testing.expectEqual(
        editor_state.SelectionRange{ .start = 2, .end = 6 },
        fixture.edit.selectionRange().?,
    );
    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, fixture.picker.model_picker_stage);
    try std.testing.expectEqual(@as(usize, 3), fixture.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 1), fixture.picker.file_completion_window_start);
    try std.testing.expectEqual(@as(?usize, 7), fixture.vertical.preferredColumn());
    try std.testing.expectEqual(.composer, fixture.rejection.owner.?);
}

test "invalid range replacement is inactive without mutation" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "abc");
    fixture.rejection = .{ .owner = .composer };

    try std.testing.expectEqual(
        InsertResult.inactive,
        try fixture.replacement(null).replaceRangeBounded(
            alloc,
            .{ .start = 1, .end = 4 },
            "x",
            2,
            8,
        ),
    );
    try std.testing.expectEqualStrings("abc", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 3), fixture.edit.cursor);
    try std.testing.expectEqual(.composer, fixture.rejection.owner.?);
}

test "selection deletion removes registered skill backing" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "$review ");
    try fixture.entities.skill_tokens.append(alloc, .{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/skills/review.md"),
        .owns_trailing_separator = true,
    });
    _ = fixture.edit.beginSelection(0);
    _ = fixture.edit.extendSelection("$review".len);

    try std.testing.expect(fixture.replacement(null).deleteSelection(alloc));
    try std.testing.expectEqualStrings(" ", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.skill_tokens.items.len);
    try std.testing.expect(fixture.edit.selectionRange() == null);
    try std.testing.expect(!fixture.edit.clearSelection());
}

test "range replacement measures and releases expanded paste backing" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, placeholder);
    try fixture.entities.pasted_blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "expanded"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    });

    try std.testing.expectEqual(
        InsertResult.inserted,
        try fixture.replacement(null).replaceRangeBounded(
            alloc,
            .{ .start = 0, .end = placeholder.len },
            "ok",
            "ok".len,
            "ok".len,
        ),
    );
    try std.testing.expectEqualStrings("ok", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.pasted_blocks.items.len);
}

test "range replacement measures expanded paste outside the replaced range" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";
    const backing = "expanded backing that exceeds the placeholder width";
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, placeholder ++ "x");
    try fixture.entities.pasted_blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, backing),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    });
    fixture.rejection = .{ .owner = .composer };

    try std.testing.expectEqual(
        InsertResult.limit_exceeded,
        try fixture.replacement(null).replaceRangeBounded(
            alloc,
            .{ .start = placeholder.len, .end = placeholder.len + 1 },
            "ok",
            placeholder.len + "ok".len,
            placeholder.len + "ok".len,
        ),
    );
    try std.testing.expectEqualStrings(placeholder ++ "x", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, placeholder.len + 1), fixture.edit.cursor);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(backing, fixture.entities.pasted_blocks.items[0].text);
    try std.testing.expectEqual(.composer, fixture.rejection.owner.?);
}

test "range replacement removes matching image attachment" {
    const alloc = std.testing.allocator;
    const placeholder = "[Image #7]";
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, placeholder);
    try fixture.entities.image_tokens.append(alloc, .{
        .id = 7,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    });
    var images: ImageBlocks = .empty;
    defer {
        for (images.items) |image| types.freeImageAttachment(alloc, image);
        images.deinit(alloc);
    }
    try images.append(alloc, .{
        .id = 7,
        .path = try alloc.dupe(u8, "/tmp/7.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    });

    try std.testing.expectEqual(
        InsertResult.inserted,
        try fixture.replacement(&images).replaceRangeBounded(
            alloc,
            .{ .start = 0, .end = placeholder.len },
            "done",
            "done".len,
            "done".len,
        ),
    );
    try std.testing.expectEqualStrings("done", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), images.items.len);
}

test "allocation failure leaves selection replacement unchanged" {
    const backing = std.testing.allocator;
    const replacement = [_]u8{'x'} ** 1024;
    var failing = std.testing.FailingAllocator.init(backing, .{});
    const alloc = failing.allocator();
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "abc");
    _ = fixture.edit.beginSelection(1);
    _ = fixture.edit.extendSelection(2);
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(
        error.OutOfMemory,
        fixture.replacement(null).replaceSelectionBounded(
            alloc,
            &replacement,
            replacement.len + 2,
        ),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualStrings("abc", fixture.edit.input.items);
    try std.testing.expectEqual(
        editor_state.SelectionRange{ .start = 1, .end = 2 },
        fixture.edit.selectionRange().?,
    );
}

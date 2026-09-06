const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const types = @import("../shared/types.zig");
const composer_insertion = @import("composer_insertion.zig");
const composer_replacement = @import("composer_replacement.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_boundaries = @import("text_boundaries.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    character_left,
    character_right,
    word_left,
    word_right,
};

/// Borrows the state changed by one layout-independent composer deletion.
/// The containing runtime retains ownership of every pointer and allocation.
pub const State = struct {
    replacement: composer_replacement.State,

    pub fn delete(
        self: State,
        alloc: Allocator,
        kind: Kind,
        picker_policy: composer_insertion.PickerPolicy,
    ) bool {
        const insertion = self.replacement.insertion;
        insertion.vertical_navigation.reset();

        if (self.replacement.deleteSelection(alloc)) {
            applyPickerPolicy(insertion, picker_policy);
            reconcilePicker(insertion);
            return true;
        }

        const range = deletionRange(
            insertion.edit.input.items,
            insertion.edit.cursor,
            insertion.entities,
            kind,
        ) orelse return false;
        applyPickerPolicy(insertion, picker_policy);
        if (!self.replacement.deleteRange(alloc, range, range.start)) return false;
        reconcilePicker(insertion);
        return true;
    }
};

fn deletionRange(
    input: []const u8,
    cursor: usize,
    entities: *const registered_entities.State,
    kind: Kind,
) ?composer_replacement.Range {
    return switch (kind) {
        .character_left => characterLeftRange(input, cursor, entities),
        .character_right => characterRightRange(input, cursor, entities),
        .word_left => wordLeftRange(input, cursor, entities),
        .word_right => wordRightRange(input, cursor, entities),
    };
}

fn characterLeftRange(
    input: []const u8,
    cursor: usize,
    entities: *const registered_entities.State,
) ?composer_replacement.Range {
    if (cursor == 0) return null;
    if (entities.entityEndingAtOrContaining(input, cursor)) |entity| {
        return .{ .start = entity.span.raw_start, .end = entity.span.raw_end };
    }
    return .{
        .start = text_boundaries.previousCharacterStart(input, cursor),
        .end = cursor,
    };
}

fn characterRightRange(
    input: []const u8,
    cursor: usize,
    entities: *const registered_entities.State,
) ?composer_replacement.Range {
    if (cursor >= input.len) return null;
    if (entities.entityStartingAtOrContaining(input, cursor)) |entity| {
        return .{
            .start = entity.span.raw_start,
            .end = entities.atomicForwardDeleteEnd(input, cursor, entity),
        };
    }
    return .{
        .start = cursor,
        .end = text_boundaries.nextCharacterEnd(input, cursor),
    };
}

fn wordLeftRange(
    input: []const u8,
    cursor: usize,
    entities: *const registered_entities.State,
) ?composer_replacement.Range {
    if (cursor == 0) return null;
    if (entities.entityEndingAtOrContaining(input, cursor)) |entity| {
        return .{ .start = entity.span.raw_start, .end = entity.span.raw_end };
    }

    var start = cursor;
    while (start > 0) {
        if (entities.entityEndingAt(input, start)) |entity| {
            start = entity.span.raw_start;
            break;
        }
        const previous = text_boundaries.previousCharacterStart(input, start);
        const rune = display_width.decodeNextRune(input, previous);
        if (text_boundaries.isWordCharacter(rune.codepoint)) break;
        start = previous;
    }
    while (start > 0) {
        if (entities.entityEndingAt(input, start)) |entity| {
            start = entity.span.raw_start;
            break;
        }
        const previous = text_boundaries.previousCharacterStart(input, start);
        const rune = display_width.decodeNextRune(input, previous);
        if (!text_boundaries.isWordCharacter(rune.codepoint)) break;
        start = previous;
    }
    if (start == cursor) return null;
    return .{ .start = start, .end = cursor };
}

fn wordRightRange(
    input: []const u8,
    cursor: usize,
    entities: *const registered_entities.State,
) ?composer_replacement.Range {
    if (cursor >= input.len) return null;
    if (entities.entityStartingAtOrContaining(input, cursor)) |entity| {
        return .{
            .start = entity.span.raw_start,
            .end = entities.atomicForwardDeleteEnd(input, cursor, entity),
        };
    }

    var end = cursor;
    while (end < input.len) {
        const rune = display_width.decodeNextRune(input, end);
        if (!text_boundaries.isWordCharacter(rune.codepoint)) break;
        end += rune.len;
    }
    while (end < input.len) {
        if (entities.entityStartingAt(input, end) != null) break;
        const rune = display_width.decodeNextRune(input, end);
        if (text_boundaries.isWordCharacter(rune.codepoint)) break;
        end += rune.len;
    }
    if (end == cursor) return null;
    return .{ .start = cursor, .end = end };
}

fn applyPickerPolicy(
    insertion: composer_insertion.State,
    picker_policy: composer_insertion.PickerPolicy,
) void {
    switch (picker_policy) {
        .preserve => {},
        .clear => insertion.picker.clearModelPickerFlow(),
    }
}

fn reconcilePicker(insertion: composer_insertion.State) void {
    insertion.picker.reconcileInlinePickerAfterEdit(insertion.edit);
    insertion.picker.resetActiveCompletionIndex();
}

const Fixture = struct {
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical: vertical_navigation.State = .{},
    rejection: input_limit_rejection.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.history.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
    }

    fn deletion(
        self: *Fixture,
        images: ?*composer_replacement.ImageBlocks,
    ) State {
        return .{
            .replacement = .{
                .insertion = .{
                    .edit = &self.edit,
                    .history = &self.history,
                    .picker = &self.picker,
                    .entities = &self.entities,
                    .vertical_navigation = &self.vertical,
                    .input_limit_rejection = &self.rejection,
                },
                .images = images,
            },
        };
    }
};

test "character and word deletion use terminal-independent ranges" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "Ae\u{301}B");
    _ = fixture.edit.setCursor(1);
    try std.testing.expect(fixture.deletion(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("AB", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 1), fixture.edit.cursor);

    try fixture.edit.setText(alloc, "foo-bar  ");
    fixture.history.reset(alloc);
    try std.testing.expect(fixture.deletion(null).delete(
        alloc,
        .word_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("foo-", fixture.edit.input.items);
    try std.testing.expectEqualStrings("bar  ", fixture.history.peekUndo().?.removed.items);
}

test "selection deletion wins and picker policy respects empty boundaries" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "alpha beta");
    try fixture.picker.beginModelPickerFlow(
        alloc,
        "provider/model",
        0,
        false,
        .effort,
    );
    _ = fixture.edit.beginSelection(2);
    _ = fixture.edit.extendSelection(7);
    fixture.vertical.preferred_column = 4;
    fixture.rejection = .{ .owner = .composer };

    try std.testing.expect(fixture.deletion(null).delete(
        alloc,
        .word_right,
        .preserve,
    ));
    try std.testing.expectEqualStrings("aleta", fixture.edit.input.items);
    try std.testing.expect(fixture.edit.selectionRange() == null);
    try std.testing.expectEqual(@as(?usize, null), fixture.vertical.preferredColumn());
    try std.testing.expect(fixture.rejection.owner == null);
    try std.testing.expectEqual(
        picker_state.ModelPickerStage.effort,
        fixture.picker.model_picker_stage,
    );

    _ = fixture.edit.setCursor(0);
    try std.testing.expect(!fixture.deletion(null).delete(
        alloc,
        .character_left,
        .clear,
    ));
    try std.testing.expectEqual(
        picker_state.ModelPickerStage.effort,
        fixture.picker.model_picker_stage,
    );

    try std.testing.expect(fixture.deletion(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqual(
        picker_state.ModelPickerStage.model,
        fixture.picker.model_picker_stage,
    );
}

test "registered image deletion is atomic and releases its attachment" {
    const alloc = std.testing.allocator;
    const placeholder = "[Image #7]";
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, placeholder ++ " tail");
    _ = fixture.edit.setCursor(0);
    try fixture.entities.image_tokens.append(alloc, .{
        .id = 7,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    });
    var images: composer_replacement.ImageBlocks = .empty;
    defer {
        for (images.items) |image| types.freeImageAttachment(alloc, image);
        images.deinit(alloc);
    }
    try images.append(alloc, .{
        .id = 7,
        .path = try alloc.dupe(u8, "/tmp/7.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    });

    try std.testing.expect(fixture.deletion(&images).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings(" tail", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), images.items.len);
    try std.testing.expect(fixture.history.peekUndo() == null);
}

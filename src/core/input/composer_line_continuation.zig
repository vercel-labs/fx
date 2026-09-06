const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

fn backslashIndexBeforeCursor(input: []const u8, cursor: usize) ?usize {
    if (cursor == 0 or cursor > input.len) return null;
    const index = cursor - 1;
    if (input[index] != '\\') return null;
    return index;
}

/// Borrows the Core state changed by one composer line-continuation edit.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,

    pub fn replaceBackslashBeforeCursorWithNewline(
        self: State,
        alloc: Allocator,
    ) bool {
        self.vertical_navigation.reset();
        const index = backslashIndexBeforeCursor(
            self.edit.input.items,
            self.edit.cursor,
        ) orelse return false;

        var prepared = self.prepareHistory(alloc, index);
        defer prepared.deinit(alloc);

        const replaced = self.edit.replaceByteBeforeCursor('\\', '\n');
        std.debug.assert(replaced);
        if (!replaced) return false;

        self.picker.clearModelPickerFlow();
        self.entities.discardPendingAutoSeparator();
        self.picker.reconcileInlinePickerAfterEdit(self.edit);
        self.picker.resetActiveCompletionIndex();
        self.picker.resetFilePickerIndex();
        self.history.commit(alloc, &prepared);
        return true;
    }

    fn prepareHistory(
        self: State,
        alloc: Allocator,
        index: usize,
    ) edit_history.Prepared {
        return self.history.prepare(
            alloc,
            index,
            "\\",
            "\n",
            self.edit.cursor,
            self.edit.cursor,
        ) catch |err| {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=allocation_failure operation=backslash_newline error={s}",
                .{@errorName(err)},
            );
            self.history.reset(alloc);
            return .boundary;
        };
    }
};

const Fixture = struct {
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: vertical_navigation.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.history.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
    }

    fn state(self: *Fixture) State {
        return .{
            .edit = &self.edit,
            .history = &self.history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
        };
    }
};

test "line continuation requires a backslash immediately before the cursor" {
    try std.testing.expectEqual(@as(?usize, null), backslashIndexBeforeCursor("", 0));
    try std.testing.expectEqual(@as(?usize, null), backslashIndexBeforeCursor("x", 0));
    try std.testing.expectEqual(@as(?usize, null), backslashIndexBeforeCursor("x", 1));
    try std.testing.expectEqual(@as(?usize, 1), backslashIndexBeforeCursor("x\\y", 2));
    try std.testing.expectEqual(@as(?usize, null), backslashIndexBeforeCursor("x\\y", 4));
}

test "line continuation records one edit and reconciles transient state" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "x \\");
    _ = fixture.edit.beginSelection(0);
    _ = fixture.edit.extendSelection(fixture.edit.input.items.len);
    try fixture.picker.beginModelPickerFlow(
        alloc,
        "provider/model",
        2,
        true,
        .effort,
    );
    fixture.picker.slash_completion_index = 3;
    fixture.picker.file_completion_index = 4;
    fixture.picker.file_completion_window_start = 2;
    fixture.picker.dismissInlinePicker(.file);
    fixture.entities.markFileCompletionSeparator(
        fixture.edit.input.items,
        2,
        1,
    );
    fixture.vertical_navigation.preferred_column = 5;

    try std.testing.expect(
        fixture.state().replaceBackslashBeforeCursorWithNewline(alloc),
    );

    try std.testing.expectEqualStrings("x \n", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 3), fixture.edit.cursor);
    try std.testing.expect(fixture.edit.selectionRange() == null);
    try std.testing.expectEqual(
        @as(?usize, null),
        fixture.vertical_navigation.preferredColumn(),
    );
    try std.testing.expect(!fixture.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.file_completion_window_start);
    try std.testing.expect(!fixture.picker.isInlinePickerDismissed(.file));
    try std.testing.expect(fixture.entities.pending_auto_separator == null);

    const entry = fixture.history.peekUndo().?;
    try std.testing.expectEqual(@as(usize, 2), entry.start);
    try std.testing.expectEqualStrings("\\", entry.removed.items);
    try std.testing.expectEqualStrings("\n", entry.inserted.items);
    try std.testing.expectEqual(@as(usize, 3), entry.cursor_before);
    try std.testing.expectEqual(@as(usize, 3), entry.cursor_after);
}

test "line continuation no-op only resets vertical navigation" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "draft ");
    _ = fixture.edit.beginSelection(0);
    _ = fixture.edit.extendSelection(fixture.edit.input.items.len);
    try fixture.picker.beginModelPickerFlow(
        alloc,
        "provider/model",
        1,
        false,
        .effort,
    );
    fixture.picker.file_completion_index = 3;
    fixture.entities.markFileCompletionSeparator(
        fixture.edit.input.items,
        fixture.edit.cursor,
        fixture.edit.cursor - 1,
    );
    fixture.vertical_navigation.preferred_column = 4;
    var prepared = try fixture.history.prepare(alloc, 0, "", "draft ", 0, 6);
    defer prepared.deinit(alloc);
    fixture.history.commit(alloc, &prepared);

    try std.testing.expect(
        !fixture.state().replaceBackslashBeforeCursorWithNewline(alloc),
    );

    try std.testing.expectEqualStrings("draft ", fixture.edit.input.items);
    try std.testing.expectEqual(
        editor_state.SelectionRange{ .start = 0, .end = 6 },
        fixture.edit.selectionRange().?,
    );
    try std.testing.expect(fixture.history.peekUndo() != null);
    try std.testing.expect(fixture.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(@as(usize, 3), fixture.picker.file_completion_index);
    try std.testing.expect(fixture.entities.pending_auto_separator != null);
    try std.testing.expectEqual(
        @as(?usize, null),
        fixture.vertical_navigation.preferredColumn(),
    );
}

test "line continuation history allocation failure preserves the primary edit" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "draft\\");
    var first = try fixture.history.prepare(alloc, 0, "", "draft", 0, 5);
    defer first.deinit(alloc);
    fixture.history.commit(alloc, &first);
    try std.testing.expect(try fixture.history.prepareUndo(alloc));
    fixture.history.commitUndo();

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expect(
        fixture.state().replaceBackslashBeforeCursorWithNewline(
            failing.allocator(),
        ),
    );

    try std.testing.expectEqualStrings("draft\n", fixture.edit.input.items);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
}

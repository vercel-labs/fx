const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

const Transition = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
    cursor_after: usize,

    fn growth(self: Transition) usize {
        return self.replacement.len -| (self.end - self.start);
    }
};

/// Purely validates one recorded delta and describes the mutation to apply.
fn plan(
    input: []const u8,
    entities: *const registered_entities.State,
    entry: *const edit_history.Entry,
    expected: []const u8,
    replacement: []const u8,
    cursor_after: usize,
) ?Transition {
    const end = std.math.add(usize, entry.start, expected.len) catch return null;
    if (end > input.len or !std.mem.eql(u8, input[entry.start..end], expected)) {
        return null;
    }
    if ((entry.start < end and entities.entityOverlapping(entry.start, end) != null) or
        (entry.start == end and entities.entityContaining(input, entry.start) != null))
    {
        return null;
    }
    return .{
        .start = entry.start,
        .end = end,
        .replacement = replacement,
        .cursor_after = cursor_after,
    };
}

/// Borrows the Core state changed by one composer undo or redo transition.
/// The containing runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,

    pub fn undo(self: State, alloc: Allocator) Allocator.Error!bool {
        if (!try self.history.prepareUndo(alloc)) return false;
        const entry = self.history.peekUndo().?;
        if (!try self.apply(
            alloc,
            entry,
            entry.inserted.items,
            entry.removed.items,
            entry.cursor_before,
        )) {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=invalid_transition operation=undo",
                .{},
            );
            self.history.reset(alloc);
            return false;
        }
        self.history.commitUndo();
        return true;
    }

    pub fn redo(self: State, alloc: Allocator) Allocator.Error!bool {
        if (!try self.history.prepareRedo(alloc)) return false;
        const entry = self.history.peekRedo().?;
        if (!try self.apply(
            alloc,
            entry,
            entry.removed.items,
            entry.inserted.items,
            entry.cursor_after,
        )) {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=invalid_transition operation=redo",
                .{},
            );
            self.history.reset(alloc);
            return false;
        }
        self.history.commitRedo();
        return true;
    }

    fn apply(
        self: State,
        alloc: Allocator,
        entry: *const edit_history.Entry,
        expected: []const u8,
        replacement: []const u8,
        cursor_after: usize,
    ) Allocator.Error!bool {
        const transition = plan(
            self.edit.input.items,
            self.entities,
            entry,
            expected,
            replacement,
            cursor_after,
        ) orelse return false;
        const growth = transition.growth();
        if (growth > 0) {
            try self.edit.input.ensureUnusedCapacity(
                alloc,
                growth,
            );
        }

        self.entities.discardPendingAutoSeparator();
        if (transition.start < transition.end) {
            self.entities.adjustForDelete(alloc, transition.start, transition.end);
            std.debug.assert(self.edit.deleteTextRange(transition.start, transition.end));
        }
        _ = self.edit.setCursor(transition.start);
        if (transition.replacement.len > 0) {
            self.edit.insertSliceAssumeCapacity(transition.replacement);
            self.entities.shiftForInsert(alloc, transition.start, transition.replacement.len);
        }
        _ = self.edit.setCursor(transition.cursor_after);
        self.vertical_navigation.reset();
        self.picker.clearModelPickerFlow();
        self.picker.reconcileInlinePickerAfterEdit(self.edit);
        self.picker.resetActiveCompletionIndex();
        self.picker.resetFilePickerIndex();
        self.input_limit_rejection.* = input_limit_rejection.clear();
        return true;
    }
};

const Fixture = struct {
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: vertical_navigation.State = .{},
    input_limit_rejection: input_limit_rejection.State = .{},

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
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    fn record(
        self: *Fixture,
        alloc: Allocator,
        start: usize,
        removed: []const u8,
        inserted: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) !void {
        var prepared = try self.history.prepare(
            alloc,
            start,
            removed,
            inserted,
            cursor_before,
            cursor_after,
        );
        defer prepared.deinit(alloc);
        self.history.commit(alloc, &prepared);
    }
};

test "composer undo and redo apply the recorded transition and reset edit policy" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "ab ");
    try fixture.record(alloc, 1, "", "b", 1, 2);
    try fixture.picker.beginModelPickerFlow(alloc, "provider/model", 2, true, .effort);
    fixture.picker.file_completion_index = 3;
    fixture.picker.file_completion_window_start = 1;
    fixture.entities.markFileCompletionSeparator(
        fixture.edit.input.items,
        fixture.edit.cursor,
        2,
    );
    try std.testing.expect(fixture.vertical_navigation.applyTarget(
        &fixture.edit,
        &fixture.entities,
        fixture.edit.input.items.len,
        1,
    ));
    fixture.input_limit_rejection = .{ .owner = .composer };

    try std.testing.expect(try fixture.state().undo(alloc));
    try std.testing.expectEqualStrings("a ", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 1), fixture.edit.cursor);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() != null);
    try std.testing.expect(fixture.entities.pending_auto_separator == null);
    try std.testing.expect(fixture.vertical_navigation.preferredColumn() == null);
    try std.testing.expect(!fixture.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.file_completion_window_start);
    try std.testing.expect(fixture.input_limit_rejection.owner == null);

    try std.testing.expect(try fixture.state().redo(alloc));
    try std.testing.expectEqualStrings("ab ", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 2), fixture.edit.cursor);
    try std.testing.expect(fixture.history.peekUndo() != null);
    try std.testing.expect(fixture.history.peekRedo() == null);
}

test "composer undo rejects stale bytes and clears both history directions" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "changed");
    try fixture.record(alloc, 0, "", "recorded", 0, "recorded".len);

    try std.testing.expect(!(try fixture.state().undo(alloc)));
    try std.testing.expectEqualStrings("changed", fixture.edit.input.items);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
}

test "composer undo rejects registered entities without mutating text" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "tag");
    try fixture.record(alloc, 0, "", "tag", 0, 3);
    try fixture.entities.image_tokens.append(alloc, .{
        .id = 1,
        .span = .{ .raw_start = 0, .raw_end = 3 },
    });

    try std.testing.expect(!(try fixture.state().undo(alloc)));
    try std.testing.expectEqualStrings("tag", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.image_tokens.items.len);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
}

test "composer undo destination allocation failure preserves text and history" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "a");
    try fixture.record(alloc, 0, "", "a", 0, 1);
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        fixture.state().undo(failing.allocator()),
    );
    try std.testing.expectEqualStrings("a", fixture.edit.input.items);
    try std.testing.expect(fixture.history.peekUndo() != null);
    try std.testing.expect(fixture.history.peekRedo() == null);
}

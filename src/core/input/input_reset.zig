const std = @import("std");
const composer_history = @import("composer_history.zig");
const editor_state = @import("editor_state.zig");
const edit_history = @import("edit_history.zig");
const gesture_state = @import("gesture_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const kill_ring = @import("kill_ring.zig");
const paste_framing = @import("paste_framing.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_scalar = @import("text_scalar.zig");
const vertical_navigation = @import("vertical_navigation.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// Non-owning view of the Core state affected by current-input and session
/// resets. Callers retain ownership of every referenced state value.
pub const State = struct {
    edit: *editor_state.State,
    picker: *picker_state.State,
    composer_history: *composer_history.State,
    paste: *paste_framing.State,
    entities: *registered_entities.State,
    text_scalar: *text_scalar.State,
    gestures: *gesture_state.State,
    input_limit_rejection: *input_limit_rejection.State,
    kill_ring: *kill_ring.State,
    edit_history: *edit_history.State,
    vertical_navigation: *vertical_navigation.State,

    pub fn clearCurrent(self: State, alloc: Allocator) void {
        self.vertical_navigation.reset();
        resetPendingTextScalarWithTrace(self.text_scalar, "input_cleared");
        discardSelectionWithTrace(self.edit, "input_cleared");
        self.input_limit_rejection.* = input_limit_rejection.clear();
        self.edit.clearRetainingCapacity();
        self.entities.clearImageAndSkillTokens(alloc);
        self.picker.resetInlinePickerEpisode();
        self.picker.model_completion_index = 0;
        self.picker.model_completion_window_start = 0;
        self.picker.resetFilePickerIndex();
        self.picker.clearModelPickerFlow();
        self.picker.clearProviderPickerFlow();
        self.composer_history.resetNavigation(alloc);
        self.edit_history.reset(alloc);
    }

    pub fn resetForSession(self: State, alloc: Allocator) void {
        self.paste.resetWithTrace(.session_reset);
        self.clearCurrent(alloc);
        self.entities.resetForSession(alloc);
        self.kill_ring.resetForSession(alloc);

        const gesture_reset = gesture_state.reset(self.gestures.*);
        self.gestures.* = gesture_reset.next;
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
    }
};

pub fn resetPendingTextScalarWithTrace(
    state: *text_scalar.State,
    reason: []const u8,
) void {
    const transition = text_scalar.reset(state.*);
    state.* = transition.next;
    if (transition.dropped) |drop| {
        debug_trace.logf(
            "input",
            "text scalar dropped owner={s} bytes={d} reason={s}",
            .{ @tagName(drop.owner), drop.bytes, reason },
        );
    }
}

pub fn discardSelectionWithTrace(
    edit: *editor_state.State,
    reason: []const u8,
) void {
    if (edit.discardSelection()) |dropped_bytes| {
        debug_trace.logf(
            "input",
            "selection dropped bytes={d} reason={s}",
            .{ dropped_bytes, reason },
        );
    }
}

test "session input reset clears transient state and preserves prompt history" {
    const alloc = std.testing.allocator;

    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    var picker: picker_state.State = .{};
    defer picker.deinit(alloc);
    var history: composer_history.State = .{};
    defer history.deinit(alloc);
    var paste: paste_framing.State = .{};
    defer paste.deinit(alloc);
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var scalar: text_scalar.State = .{};
    var gestures: gesture_state.State = .{};
    var rejection: input_limit_rejection.State = .{};
    var killed: kill_ring.State = .{};
    defer killed.deinit(alloc);
    var edits: edit_history.State = .{};
    defer edits.deinit(alloc);
    var vertical: vertical_navigation.State = .{};

    try history.installTextEntries(alloc, &.{ "one", "two" });
    try edit.setText(alloc, "draft");
    try std.testing.expectEqual(
        composer_history.NavigationResult{ .moved = 0 },
        try history.navigate(
            alloc,
            -1,
            .{
                .edit = &edit,
                .entities = &entities,
                .picker = &picker,
                .vertical_navigation = &vertical,
                .input_limit_rejection = &rejection,
                .images = null,
            },
            1,
            4096,
        ),
    );
    picker.dismissInlinePicker(.slash);
    picker.model_completion_index = 3;
    picker.model_completion_window_start = 2;
    picker.file_completion_index = 4;
    picker.file_completion_window_start = 1;
    try picker.beginModelPickerFlow(alloc, "provider/model", 2, true, .effort);
    try std.testing.expect(vertical.applyTarget(&edit, &entities, edit.input.items.len, 4));
    _ = edit.beginSelection(0);
    _ = edit.extendSelection(edit.input.items.len);
    {
        const pasted_backing = try alloc.dupe(u8, "pasted backing");
        errdefer alloc.free(pasted_backing);
        try entities.pasted_blocks.append(alloc, .{
            .id = 7,
            .text = pasted_backing,
            .line_count = 1,
        });
    }
    try killed.text.appendSlice(alloc, "killed draft");
    var prepared_edit = try edits.prepare(alloc, 0, "", "draft", 0, "draft".len);
    defer prepared_edit.deinit(alloc);
    edits.commit(alloc, &prepared_edit);
    entities.next_paste_id = 8;
    paste.begin(.composer, std.math.maxInt(usize));
    try paste.buffer.appendSlice(alloc, "pending paste");
    scalar = text_scalar.advance(scalar, .composer, 0xE2).next;
    gestures = gesture_state.pressCtrlCExit(gestures, 123).next;
    gestures = gesture_state.pressEscapeClear(gestures, 456).next;
    rejection = input_limit_rejection.begin(rejection, .composer).next;
    try std.testing.expect(edit.selectionRange() != null);
    try std.testing.expectEqual(@as(?usize, 4), vertical.preferredColumn());

    (State{
        .edit = &edit,
        .picker = &picker,
        .composer_history = &history,
        .paste = &paste,
        .entities = &entities,
        .text_scalar = &scalar,
        .gestures = &gestures,
        .input_limit_rejection = &rejection,
        .kill_ring = &killed,
        .edit_history = &edits,
        .vertical_navigation = &vertical,
    }).resetForSession(alloc);

    try std.testing.expectEqualStrings("", edit.input.items);
    try std.testing.expect(edit.selectionRange() == null);
    try std.testing.expectEqual(@as(usize, 0), entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings("", killed.text.items);
    try std.testing.expect(edits.peekUndo() == null);
    try std.testing.expectEqual(@as(usize, 1), entities.next_paste_id);
    try std.testing.expectEqual(paste_framing.Owner.none, paste.owner);
    try std.testing.expect(!text_scalar.hasPending(scalar));
    try std.testing.expect(!gestures.ctrlCExitArmed());
    try std.testing.expect(!gestures.escapeClearArmed());
    try std.testing.expect(rejection.owner == null);
    try std.testing.expect(vertical.preferredColumn() == null);
    try std.testing.expectEqual(@as(usize, 2), history.count());
    try std.testing.expect(history.activeIndex() == null);
    try std.testing.expectEqualStrings("one", history.entryText(0).?);
    try std.testing.expectEqualStrings("two", history.entryText(1).?);
    try std.testing.expect(!picker.isInlinePickerDismissed(.slash));
    try std.testing.expectEqual(@as(usize, 0), picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 0), picker.model_completion_window_start);
    try std.testing.expectEqual(@as(usize, 0), picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 0), picker.file_completion_window_start);
    try std.testing.expect(!picker.hasPendingModelPickerSelection());
}

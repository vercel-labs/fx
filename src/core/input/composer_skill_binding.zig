const std = @import("std");
const composer_insertion = @import("composer_insertion.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Borrows the Core state changed by one composer skill-token binding.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    insertion: composer_insertion.State,

    pub fn bindSkillToken(
        self: State,
        alloc: Allocator,
        replace_start: usize,
        replace_end: usize,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
    ) registered_entities.BindError!void {
        try self.insertion.entities.bindSkillToken(
            alloc,
            self.insertion.edit,
            replace_start,
            replace_end,
            name,
            path,
            display_source,
        );
        self.insertion.history.reset(alloc);
        self.insertion.vertical_navigation.reset();
        self.insertion.picker.reconcileInlinePickerAfterEdit(self.insertion.edit);
        self.insertion.picker.resetActiveCompletionIndex();
        self.insertion.input_limit_rejection.* = input_limit_rejection.clear();
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
        return .{ .insertion = .{
            .edit = &self.edit,
            .history = &self.history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        } };
    }

    fn seedHistoryBothDirections(self: *Fixture, alloc: Allocator) !void {
        var first = try self.history.prepare(alloc, 0, "", "a", 0, 1);
        defer first.deinit(alloc);
        self.history.commit(alloc, &first);

        var second = try self.history.prepare(alloc, 1, "", "b", 1, 2);
        defer second.deinit(alloc);
        self.history.commit(alloc, &second);
        try std.testing.expect(try self.history.prepareUndo(alloc));
        self.history.commitUndo();
    }
};

test "composer skill binding owns canonical mutation and transient cleanup" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);

    try fixture.edit.setText(alloc, "revnext");
    _ = fixture.edit.setCursor("rev".len);
    _ = fixture.edit.beginSelection(0);
    _ = fixture.edit.extendSelection("rev".len);
    try fixture.seedHistoryBothDirections(alloc);
    fixture.picker.slash_completion_index = 4;
    fixture.picker.slash_completion_window_start = 2;
    fixture.picker.dismissInlinePicker(.file);
    fixture.picker.model_completion_index = 5;
    fixture.picker.model_completion_window_start = 3;
    fixture.picker.model_completion_anchor_current = true;
    fixture.picker.file_completion_index = 6;
    fixture.picker.file_completion_window_start = 4;
    fixture.vertical_navigation.preferred_column = 7;
    fixture.input_limit_rejection = input_limit_rejection.begin(
        .{},
        .composer,
    ).next;

    try fixture.state().bindSkillToken(
        alloc,
        0,
        "rev".len,
        "review",
        "/tmp/review/SKILL.md",
        .workspace_codex,
    );

    try std.testing.expectEqualStrings("$review next", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, "$review ".len), fixture.edit.cursor);
    try std.testing.expect(fixture.edit.selectionRange() == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.skill_tokens.items.len);
    const token = fixture.entities.skill_tokens.items[0];
    try std.testing.expectEqual(@as(usize, 0), token.raw_start);
    try std.testing.expectEqual(@as(usize, "$review".len), token.raw_end);
    try std.testing.expectEqualStrings("review", token.name);
    try std.testing.expectEqualStrings("/tmp/review/SKILL.md", token.path);
    try std.testing.expectEqual(skill_contract.SkillSource.workspace_codex, token.display_source.?);
    try std.testing.expect(token.owns_trailing_separator);
    try std.testing.expect(fixture.entities.pending_auto_separator != null);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
    try std.testing.expectEqual(@as(?usize, null), fixture.vertical_navigation.preferredColumn());
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_window_start);
    try std.testing.expect(!fixture.picker.isInlinePickerDismissed(.file));
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.model_completion_window_start);
    try std.testing.expect(!fixture.picker.model_completion_anchor_current);
    try std.testing.expectEqual(@as(usize, 6), fixture.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 4), fixture.picker.file_completion_window_start);
    try std.testing.expect(fixture.input_limit_rejection.owner == null);
}

fn checkAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    fail_offset: ?usize,
    allocation_count: *usize,
) !void {
    const alloc = failing.allocator();
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "review tail");
    _ = fixture.edit.setCursor("review".len);
    try fixture.seedHistoryBothDirections(alloc);
    fixture.picker.slash_completion_index = 4;
    fixture.picker.model_completion_index = 5;
    fixture.vertical_navigation.preferred_column = 6;
    fixture.input_limit_rejection = input_limit_rejection.begin(
        .{},
        .composer,
    ).next;

    const start_alloc_index = failing.alloc_index;
    if (fail_offset) |offset| {
        failing.fail_index = try std.math.add(usize, start_alloc_index, offset);
    }

    fixture.state().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    ) catch |err| {
        try std.testing.expectEqualStrings("review tail", fixture.edit.input.items);
        try std.testing.expectEqual(@as(usize, "review".len), fixture.edit.cursor);
        try std.testing.expectEqual(@as(usize, 0), fixture.entities.skill_tokens.items.len);
        try std.testing.expect(fixture.history.peekUndo() != null);
        try std.testing.expect(fixture.history.peekRedo() != null);
        try std.testing.expectEqual(@as(usize, 4), fixture.picker.slash_completion_index);
        try std.testing.expectEqual(@as(usize, 5), fixture.picker.model_completion_index);
        try std.testing.expectEqual(@as(?usize, 6), fixture.vertical_navigation.preferredColumn());
        try std.testing.expectEqual(.composer, fixture.input_limit_rejection.owner.?);
        return err;
    };

    allocation_count.* = failing.alloc_index - start_alloc_index;
    try std.testing.expectEqualStrings("$review tail", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, "$review".len), fixture.edit.cursor);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.skill_tokens.items.len);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.model_completion_index);
    try std.testing.expectEqual(@as(?usize, null), fixture.vertical_navigation.preferredColumn());
    try std.testing.expect(fixture.input_limit_rejection.owner == null);
}

test "composer skill binding is atomic across allocation failures" {
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var allocation_count: usize = 0;
    try checkAllocationFailureIsAtomic(&probe, null, &allocation_count);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..allocation_count) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{},
        );
        var ignored_count: usize = 0;
        checkAllocationFailureIsAtomic(
            &failing,
            fail_offset,
            &ignored_count,
        ) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

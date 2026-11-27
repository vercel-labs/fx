const std = @import("std");
const composer_history = @import("composer_history.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Composer state set aside while the model picker shortcut borrows the
/// composer as the catalog menu's query box. `capture` moves the state out of
/// the live composer, leaving it empty for the picker flow; `restore` moves it
/// back verbatim, tearing down whatever the flow left behind. Neither performs
/// I/O, so the round trip cannot lose the draft to a partial failure.
pub const State = struct {
    edit: editor_state.State = .{},
    entities: registered_entities.State = .{},
    edit_history: edit_history.State = .{},
    vertical_navigation: vertical_navigation.State = .{},
    history_nav: composer_history.State.NavigationSnapshot = .{},

    /// Non-owning view of the live composer state the stash moves in and out.
    /// Callers retain ownership of every referenced state value.
    pub const ComposerView = struct {
        edit: *editor_state.State,
        entities: *registered_entities.State,
        edit_history: *edit_history.State,
        vertical_navigation: *vertical_navigation.State,
        composer_history: *composer_history.State,
    };

    pub fn capture(view: ComposerView) State {
        const stash: State = .{
            .edit = view.edit.*,
            .entities = view.entities.*,
            .edit_history = view.edit_history.*,
            .vertical_navigation = view.vertical_navigation.*,
            .history_nav = view.composer_history.takeNavigation(),
        };
        view.edit.* = .{};
        view.entities.* = .{};
        view.edit_history.* = .{};
        view.vertical_navigation.* = .{};
        return stash;
    }

    /// Consumes the stash: the flow-era composer state is torn down and the
    /// stashed state moves back in, leaving the stash empty.
    pub fn restore(self: *State, alloc: Allocator, view: ComposerView) void {
        view.edit.deinit(alloc);
        view.entities.deinit(alloc);
        view.edit_history.deinit(alloc);
        view.edit.* = self.edit;
        view.entities.* = self.entities;
        view.edit_history.* = self.edit_history;
        view.vertical_navigation.* = self.vertical_navigation;
        view.composer_history.restoreNavigation(alloc, &self.history_nav);
        self.* = .{};
    }

    pub fn hasDraft(self: *const State) bool {
        return self.edit.input.items.len > 0;
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.entities.deinit(alloc);
        self.edit_history.deinit(alloc);
        self.history_nav.deinit(alloc);
        self.* = .{};
    }
};

test "composer stash round trip preserves draft text, cursor, and selection" {
    const alloc = std.testing.allocator;
    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var history: edit_history.State = .{};
    defer history.deinit(alloc);
    var vertical: vertical_navigation.State = .{};
    var prompts: composer_history.State = .{};
    defer prompts.deinit(alloc);

    const view = State.ComposerView{
        .edit = &edit,
        .entities = &entities,
        .edit_history = &history,
        .vertical_navigation = &vertical,
        .composer_history = &prompts,
    };

    try edit.input.appendSlice(alloc, "draft with cursor");
    edit.cursor = 5;
    edit.selection_anchor = 2;
    vertical.preferred_column = 3;

    var stash = State.capture(view);
    defer stash.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), edit.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), edit.cursor);
    try std.testing.expectEqual(@as(?usize, null), edit.selection_anchor);
    try std.testing.expectEqual(@as(?usize, null), vertical.preferred_column);

    // The borrowing flow runs on the fresh composer.
    try edit.input.appendSlice(alloc, "query");
    edit.cursor = 5;

    stash.restore(alloc, view);

    try std.testing.expectEqualStrings("draft with cursor", edit.input.items);
    try std.testing.expectEqual(@as(usize, 5), edit.cursor);
    try std.testing.expectEqual(@as(?usize, 2), edit.selection_anchor);
    try std.testing.expectEqual(@as(?usize, 3), vertical.preferred_column);
}

test "composer stash round trip preserves registered entities" {
    const alloc = std.testing.allocator;
    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var history: edit_history.State = .{};
    defer history.deinit(alloc);
    var vertical: vertical_navigation.State = .{};
    var prompts: composer_history.State = .{};
    defer prompts.deinit(alloc);

    const view = State.ComposerView{
        .edit = &edit,
        .entities = &entities,
        .edit_history = &history,
        .vertical_navigation = &vertical,
        .composer_history = &prompts,
    };

    try edit.input.appendSlice(alloc, "draft text");
    try entities.pasted_blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "block"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = 5 },
    });
    try entities.image_tokens.append(alloc, .{
        .span = .{ .raw_start = 0, .raw_end = 5 },
        .id = 7,
    });
    try entities.skill_tokens.append(alloc, .{
        .raw_start = 6,
        .raw_end = 11,
        .name = try alloc.dupe(u8, "skill"),
        .path = try alloc.dupe(u8, "/tmp/s.md"),
    });
    entities.next_paste_id = 9;

    var stash = State.capture(view);
    defer stash.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.skill_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), entities.next_paste_id);

    // Flow-era registrations (e.g. a paste into the menu query) are torn down.
    try entities.pasted_blocks.append(alloc, .{
        .id = 99,
        .text = try alloc.dupe(u8, "flow"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = 4 },
    });

    stash.restore(alloc, view);

    try std.testing.expectEqual(@as(usize, 1), entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings("block", entities.pasted_blocks.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), entities.pasted_blocks.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 7), entities.image_tokens.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings("skill", entities.skill_tokens.items[0].name);
    try std.testing.expectEqual(@as(usize, 9), entities.next_paste_id);
}

test "composer stash round trip preserves undo history and drops flow edits" {
    const alloc = std.testing.allocator;
    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var history: edit_history.State = .{};
    defer history.deinit(alloc);
    var vertical: vertical_navigation.State = .{};
    var prompts: composer_history.State = .{};
    defer prompts.deinit(alloc);

    const view = State.ComposerView{
        .edit = &edit,
        .entities = &entities,
        .edit_history = &history,
        .vertical_navigation = &vertical,
        .composer_history = &prompts,
    };

    try edit.input.appendSlice(alloc, "ab");
    edit.cursor = 2;
    var prepared = try history.prepare(alloc, 0, "", "ab", 0, 2);
    history.commit(alloc, &prepared);
    try std.testing.expect(history.undo_stack.items.len == 1);

    var stash = State.capture(view);
    defer stash.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), history.undo_stack.items.len);

    // Flow-era edits record their own undo entries, all discarded on restore.
    try edit.input.appendSlice(alloc, "x");
    var flow_edit = try history.prepare(alloc, 0, "", "x", 0, 1);
    history.commit(alloc, &flow_edit);

    stash.restore(alloc, view);

    try std.testing.expectEqualStrings("ab", edit.input.items);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
}

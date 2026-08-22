const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const settings_catalog = @import("../config/settings_catalog.zig");
const usage_menu = @import("../session/usage_menu.zig");
const workspace_menu = @import("../workspace/workspace_menu.zig");
const composer_deletion = @import("composer_deletion.zig");
const composer_insertion = @import("composer_insertion.zig");
const composer_kill_ring = @import("composer_kill_ring.zig");
const composer_line_continuation = @import("composer_line_continuation.zig");
const composer_replacement = @import("composer_replacement.zig");
const composer_selection = @import("composer_selection.zig");
const composer_skill_binding = @import("composer_skill_binding.zig");
const composer_text_replacement = @import("composer_text_replacement.zig");
const composer_undo = @import("composer_undo.zig");
const composer_history = @import("composer_history.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const gesture_state = @import("gesture_state.zig");
const horizontal_navigation = @import("horizontal_navigation.zig");
const input_action = @import("input_action.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const input_reset = @import("input_reset.zig");
const kill_ring = @import("kill_ring.zig");
const paste_framing = @import("paste_framing.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_scalar = @import("text_scalar.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;
const ImageBlocks = kill_ring.ImageBlocks;

pub const Runtime = struct {
    edit_state: editor_state.State = .{},
    slash_menu_categories: bool = true,
    picker: picker_state.State = .{},
    help_menu: command_specs.HelpMenu = .{},
    settings_menu: settings_catalog.Menu = .{},
    statusline_menu: settings_catalog.StatuslineMenu = .{},
    usage_menu: usage_menu.State = .{},
    workspace_menu: workspace_menu.State = .{},
    composer_history: composer_history.State = .{},
    paste: paste_framing.State = .{},
    entities: registered_entities.State = .{},
    text_scalar: text_scalar.State = .{},
    gestures: gesture_state.State = .{},
    input_limit_rejection: input_limit_rejection.State = .{},
    kill_ring: kill_ring.State = .{},
    edit_history: edit_history.State = .{},
    vertical_navigation: vertical_navigation.State = .{},

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        input_reset.resetPendingTextScalarWithTrace(&self.text_scalar, "shutdown");
        self.paste.deinit(alloc);
        self.usage_menu.close(alloc);
        self.edit_state.deinit(alloc);
        self.picker.deinit(alloc);
        self.composer_history.deinit(alloc);
        self.entities.deinit(alloc);
        self.kill_ring.deinit(alloc);
        self.edit_history.deinit(alloc);
    }

    pub fn inputResetState(self: *Runtime) input_reset.State {
        return .{
            .edit = &self.edit_state,
            .picker = &self.picker,
            .composer_history = &self.composer_history,
            .paste = &self.paste,
            .entities = &self.entities,
            .text_scalar = &self.text_scalar,
            .gestures = &self.gestures,
            .input_limit_rejection = &self.input_limit_rejection,
            .kill_ring = &self.kill_ring,
            .edit_history = &self.edit_history,
            .vertical_navigation = &self.vertical_navigation,
        };
    }

    pub fn insertionState(self: *Runtime) composer_insertion.State {
        return .{
            .edit = &self.edit_state,
            .history = &self.edit_history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    pub fn selectionState(self: *Runtime) composer_selection.State {
        return .{ .insertion = self.insertionState() };
    }

    pub fn replacementState(
        self: *Runtime,
        images: ?*ImageBlocks,
    ) composer_replacement.State {
        return .{
            .insertion = self.insertionState(),
            .images = images,
        };
    }

    pub fn deletionState(
        self: *Runtime,
        images: ?*ImageBlocks,
    ) composer_deletion.State {
        return .{ .replacement = self.replacementState(images) };
    }

    pub fn undoState(self: *Runtime) composer_undo.State {
        return .{
            .edit = &self.edit_state,
            .history = &self.edit_history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    pub fn killRingState(
        self: *Runtime,
        images: ?*ImageBlocks,
    ) composer_kill_ring.State {
        return .{
            .ring = &self.kill_ring,
            .history = &self.edit_history,
            .active = .{
                .edit = &self.edit_state,
                .entities = &self.entities,
                .picker = &self.picker,
                .vertical_navigation = &self.vertical_navigation,
                .input_limit_rejection = &self.input_limit_rejection,
                .images = images,
            },
        };
    }

    pub fn textReplacementState(self: *Runtime) composer_text_replacement.State {
        return .{
            .edit = &self.edit_state,
            .history = &self.edit_history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    pub fn moveInputCursor(self: *Runtime, intent: input_action.MoveIntent) bool {
        return horizontal_navigation.moveIntent(
            intent,
            &self.edit_state,
            &self.entities,
            &self.vertical_navigation,
        );
    }

    pub fn historyBoundary(self: *Runtime, alloc: Allocator) void {
        self.edit_history.reset(alloc);
    }

    pub fn lineContinuationState(self: *Runtime) composer_line_continuation.State {
        return .{
            .edit = &self.edit_state,
            .history = &self.edit_history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
        };
    }

    pub fn skillBindingState(self: *Runtime) composer_skill_binding.State {
        return .{ .insertion = self.insertionState() };
    }
};

test "runtime owns product input state without terminal mechanics" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    try runtime.insertionState().insertSlice(alloc, "draft", .clear);
    try std.testing.expectEqualStrings("draft", runtime.edit_state.input.items);
    try std.testing.expect(!@hasField(Runtime, "terminal_action_decoder"));
    try std.testing.expect(!@hasField(Runtime, "terminal_cursor_probe"));
}

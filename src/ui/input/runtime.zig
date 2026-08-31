const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const approval_decision = @import("../../core/permissions/approval_decision.zig");
const subagent_input = @import("../../core/subagent/input_action.zig");
const paste_blocks = @import("../../core/input/pasted_blocks.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const native_clear_probe_runtime = @import("native_clear_probe.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const cursor_probe = @import("../terminal/cursor_probe.zig");
const theme_monitor = @import("../terminal/theme_monitor.zig");
const gesture_state = @import("../../core/input/gesture_state.zig");
const horizontal_navigation = @import("../../core/input/horizontal_navigation.zig");
const picker_state = @import("../../core/input/picker_state.zig");
const composer_history = @import("../../core/input/composer_history.zig");
const composer_insertion = @import("../../core/input/composer_insertion.zig");
const kill_ring = @import("../../core/input/kill_ring.zig");
const entity_spans = @import("../../core/shared/entity_spans.zig");
const input_action = @import("../../core/input/input_action.zig");
const vertical_navigation = @import("../../core/input/vertical_navigation.zig");
const visual_layout = @import("visual_layout.zig");
const escape_parser = @import("escape_parser.zig");
const shortcuts = @import("shortcuts.zig");
const terminal_action_decoder = @import("terminal_action_decoder.zig");

const ImageBlocks = kill_ring.ImageBlocks;
const InputRuntime = core_input_runtime.Runtime;

const Allocator = std.mem.Allocator;
const InsertResult = composer_insertion.InsertResult;

pub const DeferredTerminalInputSource = enum {
    theme_monitor,
    cursor_probe,
};

pub const TerminalInputOwner = enum {
    theme_monitor,
    paste,
    takeover,
    fx_input,
};

pub fn terminalInputOwner(
    monitor: *const theme_monitor.Monitor,
    paste_active: bool,
    takeover_active: bool,
) TerminalInputOwner {
    if (monitor.ownsInput()) return .theme_monitor;
    if (paste_active) return .paste;
    if (takeover_active) return .takeover;
    if (monitor.enabled) return .theme_monitor;
    return .fx_input;
}

const InputEscapeAction = input_action.Action;
const MouseInput = escape_parser.MouseInput;

pub const shortcutFromControlByte = shortcuts.fromControlByte;
pub const shortcutFromFocusedEditorControlByte = shortcuts.fromFocusedEditorControlByte;
pub const shortcutFromEscapeAction = shortcuts.fromEscapeAction;

pub fn approvalActionFromByte(byte: u8) ?approval_decision.Action {
    return switch (byte) {
        3 => .deny,
        '\r', '\n' => .submit,
        '\t' => .tab,
        0x7F, 0x08 => .backspace,
        '1'...'3' => .{ .number = byte - '1' },
        else => if (byte >= 0x20 and byte <= 0x7E)
            .{ .insert_ascii = byte }
        else
            null,
    };
}

fn approvalDraftActionFromShortcut(
    action: input_action.ShortcutAction,
) ?approval_decision.DraftAction {
    return switch (action) {
        .move => |intent| switch (intent.kind) {
            .character_left => .cursor_left,
            .character_right => .cursor_right,
            .line_start, .draft_start => .cursor_home,
            .line_end, .draft_end => .cursor_end,
            .word_left => .cursor_word_left,
            .word_right => .cursor_word_right,
            else => null,
        },
        .delete_forward => .delete_next,
        .delete_word_left => .delete_word_left,
        .delete_whitespace_word_left => .delete_whitespace_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        else => null,
    };
}

fn approvalDraftActionFromControlByte(byte: u8) ?approval_decision.DraftAction {
    const action = shortcuts.fromFocusedEditorControlByte(byte) orelse return null;
    return approvalDraftActionFromShortcut(action);
}

fn approvalActionFromRawByte(byte: u8) ?approval_decision.Action {
    if (approvalDraftActionFromControlByte(byte)) |edit| {
        return .{ .edit_draft = edit };
    }
    return approvalActionFromByte(byte);
}

fn withApprovalInput(
    ingress: input_action.TerminalInputIngress,
) input_action.TerminalInputIngress {
    var typed = ingress;
    const event = typed.event orelse return typed;
    typed.event = switch (event) {
        .raw => |raw| input_action.TerminalInputEvent{ .raw = .{
            .byte = raw.byte,
            .composer_shortcut = raw.composer_shortcut,
            .approval_action = approvalActionFromRawByte(raw.byte),
        } },
        .action => |decoded| input_action.TerminalInputEvent{ .action = .{
            .action = decoded.action,
            .composer_shortcut = decoded.composer_shortcut,
            .approval_focused_edit = if (decoded.composer_shortcut) |shortcut|
                approvalDraftActionFromShortcut(shortcut)
            else
                null,
            .cancel_pending = decoded.cancel_pending,
        } },
        .paste_byte => event,
    };
    return typed;
}

fn questionActionFromByte(
    byte: u8,
    freeform_selected: bool,
) ?question_prompt.Action {
    return switch (byte) {
        3 => .cancel,
        '\r', '\n' => .submit,
        '\t' => .next_entry,
        0x7F, 0x08 => if (freeform_selected) .backspace else null,
        '1'...'9' => if (freeform_selected)
            .{ .insert_ascii = byte }
        else
            .{ .select_ordinal = byte - '1' },
        else => if (freeform_selected and byte >= 0x20 and byte <= 0x7E)
            .{ .insert_ascii = byte }
        else
            null,
    };
}

fn questionFreeformActionFromShortcut(
    action: input_action.ShortcutAction,
) ?question_prompt.FreeformAction {
    return switch (action) {
        .move => |intent| switch (intent.kind) {
            .character_left => .cursor_left,
            .character_right => .cursor_right,
            .line_start, .draft_start => .cursor_home,
            .line_end, .draft_end => .cursor_end,
            .word_left => .cursor_word_left,
            .word_right => .cursor_word_right,
            else => null,
        },
        .delete_forward => .delete_next,
        .delete_word_left => .delete_word_left,
        .delete_whitespace_word_left => .delete_whitespace_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        else => null,
    };
}

fn questionActionFromShortcut(
    action: input_action.ShortcutAction,
    freeform_selected: bool,
) ?question_prompt.Action {
    switch (action) {
        .move => |intent| {
            if (intent.extend_selection) {
                switch (intent.kind) {
                    .visual_up => return .{ .move_choice = .previous },
                    .visual_down => return .{ .move_choice = .next },
                    else => {},
                }
            }
        },
        else => {},
    }
    if (!freeform_selected) return null;
    const edit = questionFreeformActionFromShortcut(action) orelse return null;
    return .{ .edit_freeform = edit };
}

fn questionActionFromRawByte(
    byte: u8,
    freeform_selected: bool,
) ?question_prompt.Action {
    if (freeform_selected) {
        if (shortcuts.fromFocusedEditorControlByte(byte)) |shortcut| {
            return questionActionFromShortcut(shortcut, true);
        }
    }
    return questionActionFromByte(byte, freeform_selected);
}

fn questionActionFromDecoded(
    action: input_action.Action,
    shortcut: ?input_action.ShortcutAction,
    freeform_selected: bool,
) ?question_prompt.Action {
    switch (action) {
        .remapped_byte => |byte| return questionActionFromRawByte(
            byte,
            freeform_selected,
        ),
        else => {},
    }
    return questionActionFromShortcut(
        shortcut orelse return null,
        freeform_selected,
    );
}

fn withQuestionInput(
    ingress: input_action.TerminalInputIngress,
    freeform_selected: bool,
) input_action.TerminalInputIngress {
    var typed = ingress;
    const event = typed.event orelse return typed;
    typed.event = switch (event) {
        .raw => |raw| input_action.TerminalInputEvent{ .raw = .{
            .byte = raw.byte,
            .composer_shortcut = raw.composer_shortcut,
            .approval_action = raw.approval_action,
            .question_action = questionActionFromRawByte(
                raw.byte,
                freeform_selected,
            ),
        } },
        .action => |decoded| input_action.TerminalInputEvent{ .action = .{
            .action = decoded.action,
            .composer_shortcut = decoded.composer_shortcut,
            .approval_focused_edit = decoded.approval_focused_edit,
            .question_action = questionActionFromDecoded(
                decoded.action,
                decoded.composer_shortcut,
                freeform_selected,
            ),
            .cancel_pending = decoded.cancel_pending,
        } },
        .paste_byte => event,
    };
    return typed;
}

fn subagentActionFromShortcut(
    action: input_action.ShortcutAction,
) ?subagent_input.Action {
    return switch (action) {
        .move => |intent| if (intent.extend_selection)
            null
        else switch (intent.kind) {
            .character_left => .left,
            .character_right => .right,
            .word_left => .word_left,
            .word_right => .word_right,
            .line_start, .draft_start => .home,
            .line_end, .draft_end => .end,
            .visual_up => .up,
            .visual_down => .down,
            .page_up => .page_up,
            .page_down => .page_down,
            .paragraph_up, .paragraph_down => null,
        },
        .delete_backward => .delete_backward,
        .delete_forward => .delete_next,
        .delete_word_left => .delete_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        .insert_newline => .insert_newline,
        .select_all,
        .copy_selection,
        .cut_selection,
        .undo,
        .redo,
        .history_previous,
        .history_next,
        .delete_whitespace_word_left,
        .yank,
        .redraw,
        => null,
    };
}

fn subagentActionFromRawByte(byte: u8) ?subagent_input.Action {
    return switch (byte) {
        3 => .ctrl_c,
        24 => .toggle,
        '\r' => .enter,
        '\t' => .focus_next,
        1 => .home,
        5 => .end,
        0x7f, 8 => .delete_backward,
        11 => .delete_to_line_end,
        21 => .clear_line,
        23 => .delete_word_left,
        else => null,
    };
}

fn subagentActionFromDecoded(action: input_action.Action) ?subagent_input.Action {
    return switch (action) {
        .escape => .escape,
        .history_up, .cursor_up => .up,
        .history_down, .cursor_down => .down,
        .cursor_left => .left,
        .cursor_right => .right,
        .home => .home,
        .end => .end,
        .word_left => .word_left,
        .word_right => .word_right,
        .delete_next => .delete_next,
        .delete_word_left => .delete_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        .clear_line => .clear_line,
        .insert_newline => .insert_newline,
        .page_up => .page_up,
        .page_down => .page_down,
        .composer_shortcut => |typed| subagentActionFromShortcut(typed),
        .remapped_byte => |byte| subagentActionFromRawByte(byte),
        .mouse_wheel,
        .mouse_pointer,
        .toggle_full_transcript,
        .toggle_permission_mode,
        .open_all_sessions,
        .steer_submit,
        .paste_start,
        .paste_end,
        .ignore,
        => null,
    };
}

fn withSubagentInput(
    ingress: input_action.TerminalInputIngress,
) input_action.TerminalInputIngress {
    var typed = ingress;
    const event = typed.event orelse return typed;
    typed.event = switch (event) {
        .raw => |raw| input_action.TerminalInputEvent{ .raw = .{
            .byte = raw.byte,
            .composer_shortcut = raw.composer_shortcut,
            .approval_action = raw.approval_action,
            .question_action = raw.question_action,
            .subagent_action = subagentActionFromRawByte(raw.byte),
        } },
        .action => |decoded| input_action.TerminalInputEvent{ .action = .{
            .action = decoded.action,
            .composer_shortcut = decoded.composer_shortcut,
            .approval_focused_edit = decoded.approval_focused_edit,
            .question_action = decoded.question_action,
            .subagent_action = subagentActionFromDecoded(decoded.action),
            .cancel_pending = decoded.cancel_pending,
        } },
        .paste_byte => event,
    };
    return typed;
}

test "terminal input carries typed subagent controls and shortcuts" {
    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = true,
    };

    const toggle = runtime.decodeTerminalByte(24, context);
    try std.testing.expectEqual(
        subagent_input.Action.toggle,
        toggle.event.?.raw.subagent_action.?,
    );

    const line_start = runtime.decodeTerminalByte(1, context);
    try std.testing.expectEqual(
        subagent_input.Action.home,
        line_start.event.?.raw.subagent_action.?,
    );

    const clear_line = runtime.decodeTerminalByte(21, context);
    try std.testing.expectEqual(
        subagent_input.Action.clear_line,
        clear_line.event.?.raw.subagent_action.?,
    );

    const child_only_shortcut = runtime.decodeTerminalByte(2, context);
    try std.testing.expect(child_only_shortcut.event.?.raw.subagent_action == null);
    try std.testing.expectEqual(
        input_action.ShortcutAction{ .move = .{ .kind = .character_left } },
        child_only_shortcut.event.?.raw.composer_shortcut.?,
    );

    const text = runtime.decodeTerminalByte('j', context);
    try std.testing.expect(text.event.?.raw.subagent_action == null);

    var word_delete = input_action.TerminalInputIngress{};
    for ("\x1bd") |byte| {
        word_delete = runtime.decodeTerminalByte(byte, context);
    }
    try std.testing.expectEqual(
        subagent_input.Action.delete_word_right,
        word_delete.event.?.action.subagent_action.?,
    );

    var arrow = input_action.TerminalInputIngress{};
    for ("\x1b[A") |byte| {
        arrow = runtime.decodeTerminalByte(byte, context);
    }
    try std.testing.expectEqual(
        subagent_input.Action.up,
        arrow.event.?.action.subagent_action.?,
    );
}

test "question bytes translate to typed prompt actions" {
    try std.testing.expectEqual(
        question_prompt.Action.cancel,
        questionActionFromByte(3, false).?,
    );
    try std.testing.expectEqual(
        question_prompt.Action.submit,
        questionActionFromByte('\r', false).?,
    );
    try std.testing.expectEqual(
        question_prompt.Action.next_entry,
        questionActionFromByte('\t', false).?,
    );
    try std.testing.expectEqual(
        question_prompt.Action{ .select_ordinal = 2 },
        questionActionFromByte('3', false).?,
    );
    try std.testing.expectEqual(
        question_prompt.Action{ .insert_ascii = '3' },
        questionActionFromByte('3', true).?,
    );
    try std.testing.expectEqual(
        question_prompt.Action.backspace,
        questionActionFromByte(0x7F, true).?,
    );
    try std.testing.expect(questionActionFromByte('x', false) == null);
    try std.testing.expect(questionActionFromByte(0x7F, false) == null);
    try std.testing.expect(questionActionFromByte(0x80, true) == null);
}

test "terminal input carries typed question decisions and focused edits" {
    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);

    const choice_context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = false,
        .question_freeform_selected = false,
    };
    const choice = runtime.decodeTerminalByte('3', choice_context);
    try std.testing.expectEqual(
        question_prompt.Action{ .select_ordinal = 2 },
        choice.event.?.raw.question_action.?,
    );

    const freeform_context: input_action.TerminalDecodeContext = .{
        .now_ms = 2,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = false,
        .question_freeform_selected = true,
    };
    const digit = runtime.decodeTerminalByte('3', freeform_context);
    try std.testing.expectEqual(
        question_prompt.Action{ .insert_ascii = '3' },
        digit.event.?.raw.question_action.?,
    );
    const focused_control = runtime.decodeTerminalByte(1, freeform_context);
    try std.testing.expectEqual(
        question_prompt.Action{ .edit_freeform = .cursor_home },
        focused_control.event.?.raw.question_action.?,
    );

    var focused_escape = input_action.TerminalInputIngress{};
    for ("\x1bd") |byte| {
        focused_escape = runtime.decodeTerminalByte(byte, freeform_context);
    }
    try std.testing.expectEqual(
        question_prompt.Action{ .edit_freeform = .delete_word_right },
        focused_escape.event.?.action.question_action.?,
    );

    var shifted_option = input_action.TerminalInputIngress{};
    for ("\x1b[1;2A") |byte| {
        shifted_option = runtime.decodeTerminalByte(byte, freeform_context);
    }
    try std.testing.expectEqual(
        question_prompt.Action{ .move_choice = .previous },
        shifted_option.event.?.action.question_action.?,
    );

    var remapped_cancel = input_action.TerminalInputIngress{};
    for ("\x1b[99;5u") |byte| {
        remapped_cancel = runtime.decodeTerminalByte(byte, choice_context);
    }
    try std.testing.expectEqual(
        question_prompt.Action.cancel,
        remapped_cancel.event.?.action.question_action.?,
    );
}

test "fx terminal reply ownership survives takeover transition" {
    const alloc = std.testing.allocator;
    var monitor = theme_monitor.Monitor{};
    monitor.start();

    try std.testing.expect(monitor.takeQueryRequest(0) == null);
    for ("\x1b[?997;1n") |byte| _ = monitor.feed(byte, 1);
    try std.testing.expectEqual(
        theme_monitor.QueryRequest.response_fence,
        monitor.takeQueryRequest(1000).?,
    );

    var child: std.ArrayList(u8) = .empty;
    defer child.deinit(alloc);
    var composer: std.ArrayList(u8) = .empty;
    defer composer.deinit(alloc);

    const Driver = struct {
        fn forwarded(
            takeover_active: bool,
            bytes: []const u8,
            child_bytes: *std.ArrayList(u8),
            composer_bytes: *std.ArrayList(u8),
        ) !void {
            if (takeover_active) {
                try child_bytes.appendSlice(alloc, bytes);
            } else {
                try composer_bytes.appendSlice(alloc, bytes);
            }
        }

        fn byte(
            theme: *theme_monitor.Monitor,
            takeover_active: bool,
            input_byte: u8,
            now_ms: i64,
            child_bytes: *std.ArrayList(u8),
            composer_bytes: *std.ArrayList(u8),
        ) !void {
            switch (terminalInputOwner(theme, false, takeover_active)) {
                .paste => unreachable,
                .takeover => try child_bytes.append(alloc, input_byte),
                .fx_input => try composer_bytes.append(alloc, input_byte),
                .theme_monitor => switch (theme.feed(input_byte, now_ms)) {
                    .pending, .consumed => {},
                    .forward => |bytes| try forwarded(
                        takeover_active,
                        bytes.slice(),
                        child_bytes,
                        composer_bytes,
                    ),
                },
            }
        }
    };

    const response = "\x1b[?1;2;4c";
    for (response[0..3]) |byte| {
        try Driver.byte(&monitor, true, byte, 1001, &child, &composer);
    }
    for (response[3..]) |byte| {
        try Driver.byte(&monitor, true, byte, 1002, &child, &composer);
    }
    try std.testing.expectEqual(@as(usize, 0), child.items.len);
    try std.testing.expectEqual(@as(usize, 0), composer.items.len);

    for (response) |byte| {
        try Driver.byte(&monitor, true, byte, 1003, &child, &composer);
    }
    try std.testing.expectEqualStrings(response, child.items);

    const raw_input = "\x1b[Akey";
    for (raw_input) |byte| {
        try Driver.byte(&monitor, true, byte, 1004, &child, &composer);
    }
    try std.testing.expectEqualStrings(response ++ raw_input, child.items);
    try std.testing.expectEqual(@as(usize, 0), composer.items.len);

    try Driver.byte(&monitor, false, 0x1b, 1005, &child, &composer);
    try Driver.byte(&monitor, true, '[', 1005, &child, &composer);
    monitor.poll(1005 + theme_monitor.response_idle_timeout_ms);
    while (monitor.takeDeferredByte()) |byte| {
        try Driver.forwarded(true, &.{byte}, &child, &composer);
        try std.testing.expect(monitor.consumeDeferredInputDispatch());
    }
    try std.testing.expectEqualStrings(response ++ raw_input ++ "\x1b[", child.items);
    try std.testing.expectEqual(@as(usize, 0), composer.items.len);
}

test "terminal reply ownership precedes active paste transport" {
    var monitor = theme_monitor.Monitor{};
    monitor.start();

    try std.testing.expect(monitor.takeQueryRequest(0) == null);
    for ("\x1b[?997;1n") |byte| _ = monitor.feed(byte, 1);
    try std.testing.expectEqual(
        theme_monitor.QueryRequest.response_fence,
        monitor.takeQueryRequest(1000).?,
    );
    try std.testing.expectEqual(
        TerminalInputOwner.theme_monitor,
        terminalInputOwner(&monitor, true, false),
    );

    for ("\x1b[?1;2;4c") |byte| {
        try std.testing.expect(monitor.feed(byte, 1001) != .forward);
    }
    try std.testing.expectEqual(
        TerminalInputOwner.paste,
        terminalInputOwner(&monitor, true, false),
    );
}

test "approval bytes translate to typed decision actions" {
    try std.testing.expectEqual(approval_decision.Action.deny, approvalActionFromByte(3).?);
    try std.testing.expectEqual(approval_decision.Action.submit, approvalActionFromByte('\r').?);
    try std.testing.expectEqual(approval_decision.Action.tab, approvalActionFromByte('\t').?);
    try std.testing.expectEqual(approval_decision.Action.backspace, approvalActionFromByte(0x7F).?);
    try std.testing.expectEqual(
        approval_decision.Action{ .number = 2 },
        approvalActionFromByte('3').?,
    );
    try std.testing.expectEqual(
        approval_decision.Action{ .insert_ascii = 'x' },
        approvalActionFromByte('x').?,
    );
    try std.testing.expect(approvalActionFromByte(0x80) == null);
}

test "terminal input carries typed approval decisions and focused edits" {
    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = false,
    };

    const decision = runtime.decodeTerminalByte('3', context);
    try std.testing.expectEqual(
        approval_decision.Action{ .number = 2 },
        decision.event.?.raw.approval_action.?,
    );

    const focused_control = runtime.decodeTerminalByte(1, context);
    try std.testing.expectEqual(
        approval_decision.Action{ .edit_draft = .cursor_home },
        focused_control.event.?.raw.approval_action.?,
    );

    _ = runtime.decodeTerminalByte(0x1b, context);
    const focused_escape = runtime.decodeTerminalByte('d', context);
    try std.testing.expectEqual(
        approval_decision.DraftAction.delete_word_right,
        focused_escape.event.?.action.approval_focused_edit.?,
    );
}

test "backspace and forward delete remove input selection first" {
    const alloc = std.testing.allocator;

    var backward = InputRuntime{};
    defer backward.deinit(alloc);
    try backward.textReplacementState().replace(alloc, "abcdef");
    _ = backward.selectionState().begin(2);
    _ = backward.selectionState().extend(5);
    try std.testing.expect(backward.deletionState(null).delete(
        alloc,
        .character_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("abf", backward.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), backward.edit_state.cursor);

    var forward = InputRuntime{};
    defer forward.deinit(alloc);
    try forward.textReplacementState().replace(alloc, "abcdef");
    _ = forward.selectionState().begin(2);
    _ = forward.selectionState().extend(5);
    try std.testing.expect(forward.deletionState(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("abf", forward.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), forward.edit_state.cursor);
}

test "word and line deletion families remove forward and reverse selections first" {
    const DeleteKind = enum {
        word_left,
        whitespace_word_left,
        word_right,
        line_start,
        line_end,
    };
    const alloc = std.testing.allocator;

    for ([_]bool{ false, true }) |reverse| {
        for (std.enums.values(DeleteKind)) |kind| {
            var runtime: InputRuntime = .{};
            defer runtime.deinit(alloc);
            try runtime.textReplacementState().replace(alloc, "alpha beta");
            if (reverse) {
                _ = runtime.selectionState().begin(8);
                _ = runtime.selectionState().extend(2);
            } else {
                _ = runtime.selectionState().begin(2);
                _ = runtime.selectionState().extend(8);
            }

            const changed = switch (kind) {
                .word_left => runtime.deletionState(null).delete(
                    alloc,
                    .word_left,
                    .clear,
                ),
                .whitespace_word_left => try runtime.killRingState(null).delete(
                    alloc,
                    .whitespace_word_left,
                ),
                .word_right => runtime.deletionState(null).delete(
                    alloc,
                    .word_right,
                    .clear,
                ),
                .line_start => try runtime.killRingState(null).delete(alloc, .line_start),
                .line_end => try runtime.killRingState(null).delete(alloc, .line_end),
            };

            try std.testing.expect(changed);
            try std.testing.expectEqualStrings("alta", runtime.edit_state.input.items);
            try std.testing.expectEqual(@as(usize, 2), runtime.edit_state.cursor);
            try std.testing.expect(runtime.edit_state.selectionRange() == null);
            try std.testing.expect(try runtime.undoState().undo(alloc));
            try std.testing.expectEqualStrings("alpha beta", runtime.edit_state.input.items);
        }
    }
}

test "history allocation failure preserves deletion and replacement edits" {
    const alloc = std.testing.allocator;
    var runtime: InputRuntime = .{};
    defer runtime.deinit(alloc);

    try runtime.textReplacementState().replace(alloc, "ab");
    _ = runtime.edit_state.setCursor(0);
    var delete_failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expect(runtime.deletionState(null).delete(
        delete_failing.allocator(),
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("b", runtime.edit_state.input.items);

    try runtime.textReplacementState().replace(alloc, "replace");
    _ = runtime.selectionState().begin(0);
    _ = runtime.selectionState().extend(runtime.edit_state.input.items.len);
    var replace_failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectEqual(
        InsertResult.inserted,
        try runtime.replacementState(null).replaceSelectionBounded(
            replace_failing.allocator(),
            "new",
            7,
        ),
    );
    try std.testing.expectEqualStrings("new", runtime.edit_state.input.items);
    try std.testing.expect(!(try runtime.undoState().undo(alloc)));
}

test "selection bytes are available to bounded replacement input" {
    const alloc = std.testing.allocator;
    var runtime: InputRuntime = .{};
    defer runtime.deinit(alloc);
    try runtime.textReplacementState().replace(alloc, "abcde");

    try std.testing.expectEqual(
        @as(usize, 0),
        runtime.replacementState(null).availableBytesForSelectionOrInsertion(5),
    );
    _ = runtime.selectionState().begin(1);
    _ = runtime.selectionState().extend(4);
    try std.testing.expectEqual(
        @as(usize, 3),
        runtime.replacementState(null).availableBytesForSelectionOrInsertion(5),
    );
}

test "text edits undo and redo without snapshotting structured state" {
    const alloc = std.testing.allocator;
    var runtime: InputRuntime = .{};
    defer runtime.deinit(alloc);

    try runtime.insertionState().insertByte(alloc, 'a', .clear);
    try runtime.insertionState().insertByte(alloc, 'b', .clear);
    try std.testing.expect(try runtime.undoState().undo(alloc));
    try std.testing.expectEqualStrings("a", runtime.edit_state.input.items);
    try std.testing.expect(try runtime.undoState().redo(alloc));
    try std.testing.expectEqualStrings("ab", runtime.edit_state.input.items);

    _ = runtime.selectionState().begin(0);
    _ = runtime.selectionState().extend(2);
    try std.testing.expect(runtime.selectionState().delete(alloc, null));
    try std.testing.expect(try runtime.undoState().undo(alloc));
    try std.testing.expectEqualStrings("ab", runtime.edit_state.input.items);
}

pub const Runtime = struct {
    terminal_cursor_probe: cursor_probe.Parser = .{},
    terminal_theme_monitor: theme_monitor.Monitor = .{},
    deferred_terminal_input_source: ?DeferredTerminalInputSource = null,
    native_clear_probe: native_clear_probe_runtime.Runtime = .{},
    terminal_action_decoder: terminal_action_decoder.Decoder = .{},

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.native_clear_probe.deinit(alloc);
    }

    pub fn resetEscapeDecoder(self: *Runtime) void {
        self.terminal_action_decoder.reset();
    }

    pub fn hasPendingTerminalAction(self: *const Runtime) bool {
        return self.terminal_action_decoder.hasPending();
    }

    pub fn hasPendingTerminalInput(self: *const Runtime) bool {
        return self.hasPendingTerminalAction() or
            self.terminal_theme_monitor.hasPendingInput() or
            self.terminal_cursor_probe.hasPendingInput();
    }

    pub fn decodeTerminalByte(
        self: *Runtime,
        byte: u8,
        context: input_action.TerminalDecodeContext,
    ) input_action.TerminalInputIngress {
        if (context.paste_active) return terminal_action_decoder.pasteByteIngress(byte);
        return withSubagentInput(withQuestionInput(
            withApprovalInput(self.terminal_action_decoder.feed(byte, context)),
            context.question_freeform_selected,
        ));
    }

    pub fn flushTerminalAction(
        self: *Runtime,
        now_ms: i64,
        timeout_ms: i64,
        paste_active: bool,
    ) input_action.TerminalInputIngress {
        return self.terminal_action_decoder.flush(now_ms, timeout_ms, paste_active);
    }

    pub fn takeDeferredTerminalInputByte(self: *Runtime) ?u8 {
        if (self.takeDeferredThemeMonitorByte()) |byte| return byte;
        if (self.terminal_cursor_probe.takeDeferredByte()) |byte| {
            self.deferred_terminal_input_source = .cursor_probe;
            return byte;
        }
        return null;
    }

    pub fn takeDeferredThemeMonitorByte(self: *Runtime) ?u8 {
        std.debug.assert(self.deferred_terminal_input_source == null);
        if (self.terminal_theme_monitor.takeDeferredByte()) |byte| {
            self.deferred_terminal_input_source = .theme_monitor;
            return byte;
        }
        return null;
    }

    pub fn consumeDeferredTerminalInputDispatch(self: *Runtime) ?DeferredTerminalInputSource {
        const source = self.deferred_terminal_input_source;
        self.deferred_terminal_input_source = null;
        return switch (source orelse return null) {
            .theme_monitor => blk: {
                std.debug.assert(self.terminal_theme_monitor.consumeDeferredInputDispatch());
                break :blk .theme_monitor;
            },
            .cursor_probe => blk: {
                std.debug.assert(self.terminal_cursor_probe.consumeDeferredInputDispatch());
                break :blk .cursor_probe;
            },
        };
    }
};

pub fn scanInputCursorVertical(
    input: *const InputRuntime,
    direction: visual_layout.Direction,
    terminal_cols: u16,
    pending_images: []const types.ImageAttachment,
) visual_layout.VerticalScan {
    return visual_layout.scanAdjacentRow(.{
        .input = input.edit_state.input.items,
        .cursor = input.edit_state.cursor,
        .terminal_cols = terminal_cols,
        .images = pending_images,
        .pasted_blocks = input.entities.pasted_blocks.items,
        .image_tokens = input.entities.image_tokens.items,
        .skill_tokens = input.entities.skill_tokens.items,
    }, direction, input.vertical_navigation.preferredColumn());
}

pub fn scanInputCursorRows(
    input: *const InputRuntime,
    direction: visual_layout.Direction,
    row_count: usize,
    terminal_cols: u16,
    pending_images: []const types.ImageAttachment,
) visual_layout.VerticalScan {
    return visual_layout.scanRowDelta(.{
        .input = input.edit_state.input.items,
        .cursor = input.edit_state.cursor,
        .terminal_cols = terminal_cols,
        .images = pending_images,
        .pasted_blocks = input.entities.pasted_blocks.items,
        .image_tokens = input.entities.image_tokens.items,
        .skill_tokens = input.entities.skill_tokens.items,
    }, direction, row_count, input.vertical_navigation.preferredColumn());
}

fn applyVerticalTargetForTest(
    runtime: *InputRuntime,
    scan: visual_layout.VerticalScan,
) bool {
    return runtime.vertical_navigation.applyTarget(
        &runtime.edit_state,
        &runtime.entities,
        if (scan.target) |target| target.raw_offset else null,
        scan.preferred_column,
    );
}

fn moveVerticalForTest(
    runtime: *InputRuntime,
    direction: visual_layout.Direction,
    terminal_cols: u16,
    pending_images: []const types.ImageAttachment,
) bool {
    return applyVerticalTargetForTest(
        runtime,
        scanInputCursorVertical(
            runtime,
            direction,
            terminal_cols,
            pending_images,
        ),
    );
}

fn moveHorizontalForTest(
    runtime: *InputRuntime,
    motion: input_action.MoveKind,
) bool {
    return horizontal_navigation.move(
        motion,
        &runtime.edit_state,
        &runtime.entities,
        &runtime.vertical_navigation,
    );
}

fn navigateComposerHistoryWithEntitiesForTest(
    runtime: *InputRuntime,
    alloc: Allocator,
    delta: i32,
    active_images: ?*ImageBlocks,
    first_image_id: usize,
    max_len: usize,
) !composer_history.NavigationResult {
    return runtime.composer_history.navigate(
        alloc,
        delta,
        .{
            .edit = &runtime.edit_state,
            .entities = &runtime.entities,
            .picker = &runtime.picker,
            .vertical_navigation = &runtime.vertical_navigation,
            .input_limit_rejection = &runtime.input_limit_rejection,
            .images = active_images,
        },
        first_image_id,
        max_len,
    );
}

fn navigateComposerHistoryForTest(
    runtime: *InputRuntime,
    alloc: Allocator,
    delta: i32,
) !void {
    const result = try navigateComposerHistoryWithEntitiesForTest(
        runtime,
        alloc,
        delta,
        null,
        1,
        std.math.maxInt(usize),
    );
    switch (result) {
        .unchanged, .limit_exceeded => {},
        .moved => |image_count| std.debug.assert(image_count == 0),
    }
}

fn primeComposerHistoryDraftForTest(
    runtime: *InputRuntime,
    alloc: Allocator,
    draft_text: []const u8,
) !void {
    try runtime.composer_history.record(
        alloc,
        1,
        "history entry",
        &.{},
        &.{},
        &.{},
        &.{},
    );
    try runtime.edit_state.setText(alloc, draft_text);
    try navigateComposerHistoryForTest(runtime, alloc, -1);
}

pub const MouseReportDiscardResult = escape_parser.MouseReportDiscardResult;
pub const isLegacyX10PayloadStage = escape_parser.isLegacyX10PayloadStage;
pub const isMouseReportPayloadStage = escape_parser.isMouseReportPayloadStage;
pub const isMouseReportDiscardStage = escape_parser.isMouseReportDiscardStage;
pub const isControlSequenceDiscardStage = escape_parser.isControlSequenceDiscardStage;
pub const beginMouseReportDiscard = escape_parser.beginMouseReportDiscard;
pub const consumeMouseReportDiscardByte = escape_parser.consumeMouseReportDiscardByte;
pub const consumeInputEscapeByte = escape_parser.consumeInputEscapeByte;
pub const consumeInputEscapeByteWithMouse = escape_parser.consumeInputEscapeByteWithMouse;
pub const controlByteFeatureAction = escape_parser.controlByteFeatureAction;

test "model picker flow stores pending model and selections" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.picker.beginModelPickerFlow(std.testing.allocator, "openai/gpt-5", 4, true, .effort);

    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings("openai/gpt-5", runtime.picker.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 4), runtime.picker.selectedModelPickerEffortIndex());
    try std.testing.expect(runtime.picker.selectedModelPickerFast());
}

test "model picker flow accepts aliased pending model slice" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.picker.beginModelPickerFlow(std.testing.allocator, "anthropic/claude-opus-4.6", 2, false, .effort);
    const aliased_model = runtime.picker.model_picker_pending_model.items;

    try runtime.picker.beginModelPickerFlow(std.testing.allocator, aliased_model, 3, true, .fast);

    try std.testing.expectEqual(picker_state.ModelPickerStage.fast, runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", runtime.picker.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 3), runtime.picker.selectedModelPickerEffortIndex());
    try std.testing.expect(runtime.picker.selectedModelPickerFast());
}

test "editing input clears model picker flow" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.picker.beginModelPickerFlow(std.testing.allocator, "openai/gpt-5", 3, false, .fast);
    try runtime.edit_state.input.appendSlice(std.testing.allocator, "/model ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try runtime.insertionState().insertByte(std.testing.allocator, 'x', .clear);

    try std.testing.expectEqual(picker_state.ModelPickerStage.model, runtime.picker.model_picker_stage);
    try std.testing.expect(!runtime.picker.hasPendingModelPickerSelection());
}

test "preserving picker edit keeps effort flow" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "/model openai/gpt-5 ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    try runtime.picker.beginModelPickerFlow(std.testing.allocator, "openai/gpt-5", 2, false, .effort);

    try runtime.insertionState().insertByte(std.testing.allocator, 'h', .preserve);

    const query = runtime.picker.activeModelPickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, query.stage);
    try std.testing.expectEqualStrings("h", query.query);
    try std.testing.expectEqualStrings("openai/gpt-5", runtime.picker.model_picker_pending_model.items);
}

test "active model picker query tracks fast token start" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "/model anthropic/claude-opus-4.6 high f");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    try runtime.picker.beginModelPickerFlow(std.testing.allocator, "anthropic/claude-opus-4.6", 3, true, .fast);

    const query = runtime.picker.activeModelPickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqual(picker_state.ModelPickerStage.fast, query.stage);
    try std.testing.expectEqualStrings("f", query.query);
    try std.testing.expectEqual("/model anthropic/claude-opus-4.6 high ".len, query.token_start);
}

test "bare model command at cursor is detected before submission" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "  /model");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(picker_state.isBareModelCommandAtCursor(&runtime.edit_state));
}

test "bare model command predicate ignores query text and mid-line cursor" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "/model claude");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    try std.testing.expect(!picker_state.isBareModelCommandAtCursor(&runtime.edit_state));

    try runtime.textReplacementState().replace(std.testing.allocator, "/model");
    runtime.edit_state.cursor = 3;
    try std.testing.expect(!picker_state.isBareModelCommandAtCursor(&runtime.edit_state));
}

test "model command with trailing picker space is not bare" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "/model ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(!picker_state.isBareModelCommandAtCursor(&runtime.edit_state));
    try std.testing.expect(runtime.picker.activeModelPickerQuery(&runtime.edit_state) != null);
    try std.testing.expect(runtime.picker.isModelShapedInput(&runtime.edit_state));
}

test "model-shaped input covers bare command and active query" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.textReplacementState().replace(std.testing.allocator, "/model");
    try std.testing.expect(runtime.picker.isModelShapedInput(&runtime.edit_state));

    try runtime.textReplacementState().replace(std.testing.allocator, "/mo");
    try std.testing.expect(!runtime.picker.isModelShapedInput(&runtime.edit_state));
}

test "active file picker query opens at start of input" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "@sr");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("sr", query.query);
    try std.testing.expectEqual(@as(usize, 0), query.at_offset);
    try std.testing.expectEqual(@as(usize, 1), query.token_start);
}

test "active file picker query opens after whitespace" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "look at @src/main");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("src/main", query.query);
    try std.testing.expectEqual("look at ".len, query.at_offset);
    try std.testing.expectEqual("look at @".len, query.token_start);
}

test "active file picker query opens after delimiters and quotes" {
    const cases = [_][]const u8{
        "look at (@src/main",
        "look at [@src/main",
        "look at {@src/main",
        "look at <@src/main",
        "look at '@src/main",
        "look at \"@src/main",
        "look at `@src/main",
    };

    for (cases) |input| {
        var runtime = InputRuntime{};
        defer runtime.deinit(std.testing.allocator);
        try runtime.edit_state.input.appendSlice(std.testing.allocator, input);
        runtime.edit_state.cursor = runtime.edit_state.input.items.len;

        const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
        try std.testing.expectEqualStrings("src/main", query.query);
    }
}

test "active file picker query ignores @ after a non-boundary byte" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "user@host");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expectEqual(@as(?picker_state.FilePickerQuery, null), runtime.picker.activeFilePickerQuery(&runtime.edit_state));
}

test "active file picker query preserves @ inside a path component" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "@./node_modules/@types/pkg");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("./node_modules/@types/pkg", query.query);
}

test "active file picker query preserves punctuation inside the path query" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "look at (@dir/file(name");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("dir/file(name", query.query);
}

test "active file picker query closes once a space is typed" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "@src/main.zig ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expectEqual(@as(?picker_state.FilePickerQuery, null), runtime.picker.activeFilePickerQuery(&runtime.edit_state));
}

test "active file picker query keeps a quoted path open across spaces" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "review @\"space dir/fi");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("space dir/fi", query.query);
    try std.testing.expect(query.quoted);
    try std.testing.expectEqual("review ".len, query.at_offset);
    try std.testing.expectEqual("review @\"".len, query.token_start);

    try runtime.textReplacementState().replace(std.testing.allocator, "review @\"space dir/file.txt\"");
    try std.testing.expectEqual(@as(?picker_state.FilePickerQuery, null), runtime.picker.activeFilePickerQuery(&runtime.edit_state));
}

test "active file picker query allows empty query right after @" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "@");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    const query = runtime.picker.activeFilePickerQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("", query.query);
    try std.testing.expectEqual(@as(usize, 0), query.at_offset);
    try std.testing.expectEqual(@as(usize, 1), query.token_start);
}

test "active file picker query defers to model picker when active" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "/model @foo");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(runtime.picker.activeModelPickerQuery(&runtime.edit_state) != null);
    try std.testing.expectEqual(@as(?picker_state.FilePickerQuery, null), runtime.picker.activeFilePickerQuery(&runtime.edit_state));
}

test "active inline skill query recognizes a later whitespace-delimited prefix" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.textReplacementState().replace(std.testing.allocator, "explain $man");

    const query = runtime.picker.activeInlineSkillQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("man", query.query);
    try std.testing.expectEqual("explain ".len, query.dollar_offset);
    try std.testing.expectEqual("explain $".len, query.token_start);
    try std.testing.expectEqual(picker_state.InlinePickerKind.skill, runtime.picker.inlinePickerTriggerKind(&runtime.edit_state).?);
}

test "active inline skill query rejects leading empty embedded and mid-cursor tokens" {
    const cases = [_][]const u8{
        "$man",
        "explain $",
        "explain$man",
        "explain $man ",
    };
    for (cases) |input| {
        var runtime = InputRuntime{};
        defer runtime.deinit(std.testing.allocator);
        try runtime.textReplacementState().replace(std.testing.allocator, input);
        try std.testing.expectEqual(@as(?picker_state.InlineSkillQuery, null), runtime.picker.activeInlineSkillQuery(&runtime.edit_state));
    }

    var mid_cursor = InputRuntime{};
    defer mid_cursor.deinit(std.testing.allocator);
    try mid_cursor.textReplacementState().replace(std.testing.allocator, "explain $managed later");
    mid_cursor.edit_state.cursor = "explain $man".len;
    try std.testing.expectEqual(@as(?picker_state.InlineSkillQuery, null), mid_cursor.picker.activeInlineSkillQuery(&mid_cursor.edit_state));
}

test "active inline slash query recognizes a later whitespace-delimited prefix" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.textReplacementState().replace(std.testing.allocator, "explain /he");

    const query = runtime.picker.activeInlineSlashQuery(&runtime.edit_state).?;
    try std.testing.expectEqualStrings("/he", query.prefix);
    try std.testing.expectEqual(picker_state.InlinePickerKind.slash, runtime.picker.inlinePickerTriggerKind(&runtime.edit_state).?);
}

test "slash picker trigger recognizes a root query after multiline whitespace" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.textReplacementState().replace(std.testing.allocator, "\n   /");

    try std.testing.expectEqual(picker_state.InlinePickerKind.slash, runtime.picker.inlinePickerTriggerKind(&runtime.edit_state).?);
}

test "active inline slash query preserves leading menu and rejects incomplete tokens" {
    const cases = [_][]const u8{
        "/he",
        "  /he",
        "explain /",
        "explain/he",
        "explain /help ",
    };
    for (cases) |input| {
        var runtime = InputRuntime{};
        defer runtime.deinit(std.testing.allocator);
        try runtime.textReplacementState().replace(std.testing.allocator, input);
        try std.testing.expectEqual(@as(?picker_state.InlineSlashQuery, null), runtime.picker.activeInlineSlashQuery(&runtime.edit_state));
    }

    var mid_cursor = InputRuntime{};
    defer mid_cursor.deinit(std.testing.allocator);
    try mid_cursor.textReplacementState().replace(std.testing.allocator, "explain /help later");
    mid_cursor.edit_state.cursor = "explain /he".len;
    try std.testing.expectEqual(@as(?picker_state.InlineSlashQuery, null), mid_cursor.picker.activeInlineSlashQuery(&mid_cursor.edit_state));
}

test "inline skill dismissal persists for its token episode and resets after whitespace" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);
    try runtime.textReplacementState().replace(std.testing.allocator, "explain $man");

    runtime.picker.dismissInlinePicker(.skill);
    try runtime.insertionState().insertByte(std.testing.allocator, 'a', .clear);
    try std.testing.expect(runtime.picker.isInlinePickerDismissed(.skill));
    try std.testing.expectEqual(@as(?picker_state.InlineSkillQuery, null), runtime.picker.activeInlineSkillQuery(&runtime.edit_state));

    try runtime.insertionState().insertByte(std.testing.allocator, ' ', .clear);
    try std.testing.expect(!runtime.picker.isInlinePickerDismissed(.skill));
}

test "filter completion labels matches query case-insensitively" {
    const options = [_][]const u8{ "auto", "low", "medium", "high", "max" };
    var out: [5][]const u8 = undefined;

    const count = picker_state.filterCompletionLabels("H", &options, &out);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("high", out[0]);
}

test "filter completion labels ignores surrounding whitespace" {
    const options = [_][]const u8{ "auto", "low", "medium", "high", "max" };
    var out: [5][]const u8 = undefined;

    const count = picker_state.filterCompletionLabels(" max ", &options, &out);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("max", out[0]);
}

test "prompt history recalls previous inputs with up and down" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.composer_history.record(std.testing.allocator, 100, "first prompt", &.{}, &.{}, &.{}, &.{});
    try runtime.composer_history.record(std.testing.allocator, 100, "second prompt", &.{}, &.{}, &.{}, &.{});
    try runtime.edit_state.input.appendSlice(std.testing.allocator, "draft");

    try navigateComposerHistoryForTest(&runtime, std.testing.allocator, -1);
    try std.testing.expectEqualStrings("second prompt", runtime.edit_state.input.items);

    try navigateComposerHistoryForTest(&runtime, std.testing.allocator, -1);
    try std.testing.expectEqualStrings("first prompt", runtime.edit_state.input.items);

    try navigateComposerHistoryForTest(&runtime, std.testing.allocator, 1);
    try std.testing.expectEqualStrings("second prompt", runtime.edit_state.input.items);

    try navigateComposerHistoryForTest(&runtime, std.testing.allocator, 1);
    try std.testing.expectEqualStrings("draft", runtime.edit_state.input.items);
}

test "prompt history recall restores compact paste backing" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";
    const backing = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, placeholder);
    try appendPastedBlockForTest(&runtime, alloc, 1, backing);
    try runtime.composer_history.record(
        alloc,
        100,
        placeholder,
        runtime.entities.pasted_blocks.items,
        &.{},
        &.{},
        &.{},
    );
    runtime.inputResetState().clearCurrent(alloc);
    paste_blocks.clearBlocks(alloc, &runtime.entities.pasted_blocks);

    try navigateComposerHistoryForTest(&runtime, alloc, -1);

    try std.testing.expectEqualStrings(placeholder, runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(backing, runtime.entities.pasted_blocks.items[0].text);
}

test "prompt history recall restores image snapshots with fresh ids and exact skills" {
    const alloc = std.testing.allocator;
    const original_bytes = "\x89PNG\r\n\x1a\nhistory";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var source = try tmp.dir.createFile(std.testing.io, "history.png", .{});
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, original_bytes);
    }
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "history.png");
    defer alloc.free(source_path);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    const input = "see [Image #8] $review";
    try runtime.edit_state.input.appendSlice(alloc, input);
    try appendCapturedImageBlockForTest(
        &runtime,
        &images,
        alloc,
        source_path,
        snapshot_dir,
        8,
    );
    const skill_start = "see [Image #8] ".len;
    try runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = skill_start,
        .raw_end = skill_start + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/exact/review/SKILL.md"),
    });
    try runtime.composer_history.record(
        alloc,
        100,
        runtime.edit_state.input.items,
        runtime.entities.pasted_blocks.items,
        images.items,
        runtime.entities.image_tokens.items,
        runtime.entities.skill_tokens.items,
    );
    {
        var source = try tmp.dir.createFile(
            std.testing.io,
            "history.png",
            .{ .truncate = true },
        );
        defer source.close(std.testing.io);
        try source.writeStreamingAll(
            std.testing.io,
            "\x89PNG\r\n\x1a\nhistory-replaced",
        );
    }
    var replacement_images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&replacement_images, alloc);
    var replacement = try image_attachments.loadImageAttachment(
        alloc,
        source_path,
    );
    var replacement_owned = true;
    errdefer if (replacement_owned) {
        image_attachments.discardImageAttachment(alloc, replacement);
    };
    replacement.id = 8;
    try image_attachments.captureImageSnapshot(
        alloc,
        &replacement,
        snapshot_dir,
    );
    try replacement_images.append(alloc, replacement);
    replacement_owned = false;
    try runtime.composer_history.record(
        alloc,
        100,
        runtime.edit_state.input.items,
        runtime.entities.pasted_blocks.items,
        replacement_images.items,
        runtime.entities.image_tokens.items,
        runtime.entities.skill_tokens.items,
    );
    try std.testing.expectEqual(@as(usize, 2), runtime.composer_history.count());
    try std.testing.expect(!std.mem.eql(
        u8,
        runtime.composer_history.viewEntry(0).?.images[0].snapshot_sha256.?,
        runtime.composer_history.viewEntry(1).?.images[0].snapshot_sha256.?,
    ));

    for (images.items) |image| types.freeImageAttachment(alloc, image);
    images.clearRetainingCapacity();
    runtime.inputResetState().clearCurrent(alloc);

    try std.testing.expectEqual(
        composer_history.NavigationResult{ .moved = 1 },
        try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            -1,
            &images,
            100,
            4096,
        ),
    );
    try std.testing.expectEqualStrings("see [Image #100] $review", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqual(@as(usize, 100), images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 100), runtime.entities.image_tokens.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "/tmp/exact/review/SKILL.md",
        runtime.entities.skill_tokens.items[0].path,
    );
    try std.testing.expect(runtime.entities.isValidSkillToken(
        runtime.edit_state.input.items,
        runtime.entities.skill_tokens.items[0],
    ));
}

test "prompt history semantic dedupe distinguishes paste and skill provenance" {
    const alloc = std.testing.allocator;
    const text = "$review check";
    const codex = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = "review",
        .path = "/tmp/codex/review/SKILL.md",
    }};
    const claude = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = "review",
        .path = "/tmp/claude/review/SKILL.md",
    }};
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.composer_history.record(alloc, 100, text, &.{}, &.{}, &.{}, &codex);
    try runtime.composer_history.record(alloc, 100, text, &.{}, &.{}, &.{}, &codex);
    try runtime.composer_history.record(alloc, 100, text, &.{}, &.{}, &.{}, &claude);

    try std.testing.expectEqual(@as(usize, 2), runtime.composer_history.count());
    try std.testing.expectEqualStrings(
        "/tmp/codex/review/SKILL.md",
        runtime.composer_history.viewEntry(0).?.skill_tokens[0].path,
    );
    try std.testing.expectEqualStrings(
        "/tmp/claude/review/SKILL.md",
        runtime.composer_history.viewEntry(1).?.skill_tokens[0].path,
    );

    const placeholder = "[Pasted text #4, 1 line]";
    const first_paste = [_]paste_blocks.PastedBlock{.{
        .id = 4,
        .text = @constCast("first backing"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    }};
    const second_paste = [_]paste_blocks.PastedBlock{.{
        .id = 4,
        .text = @constCast("second backing"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    }};
    var paste_runtime_owner = InputRuntime{};
    defer paste_runtime_owner.deinit(alloc);
    try paste_runtime_owner.composer_history.record(
        alloc,
        100,
        placeholder,
        &first_paste,
        &.{},
        &.{},
        &.{},
    );
    try paste_runtime_owner.composer_history.record(
        alloc,
        100,
        placeholder,
        &second_paste,
        &.{},
        &.{},
        &.{},
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        paste_runtime_owner.composer_history.count(),
    );
}

test "prompt history capture releases partial semantic entries across allocation failures" {
    const backing = std.testing.allocator;
    const text = "[Pasted text #4, 1 line] $review";
    const blocks = [_]paste_blocks.PastedBlock{.{
        .id = 4,
        .text = @constCast("paste backing"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = "[Pasted text #4, 1 line]".len },
    }};
    const skills = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = "[Pasted text #4, 1 line] ".len,
        .raw_end = text.len,
        .name = "review",
        .path = "/tmp/exact/review/SKILL.md",
    }};

    var probe = std.testing.FailingAllocator.init(backing, .{});
    {
        var runtime = InputRuntime{};
        try runtime.composer_history.record(
            probe.allocator(),
            100,
            text,
            &blocks,
            &.{},
            &.{},
            &skills,
        );
        runtime.deinit(probe.allocator());
    }
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            backing,
            .{ .fail_index = fail_index },
        );
        var runtime = InputRuntime{};
        if (runtime.composer_history.record(
            failing.allocator(),
            100,
            text,
            &blocks,
            &.{},
            &.{},
            &skills,
        )) {
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(@as(usize, 0), runtime.composer_history.count());
        runtime.deinit(failing.allocator());
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "prompt history replacement preserves the draft across allocation failures" {
    const Fixture = struct {
        const history_text = "[Pasted text #4, 1 line] $review";
        const history_blocks = [_]paste_blocks.PastedBlock{.{
            .id = 4,
            .text = @constCast("paste backing"),
            .line_count = 1,
            .span = .{
                .raw_start = 0,
                .raw_end = "[Pasted text #4, 1 line]".len,
            },
        }};
        const history_skills = [_]visual_layout.SkillTokenSpan{.{
            .raw_start = "[Pasted text #4, 1 line] ".len,
            .raw_end = history_text.len,
            .name = "review",
            .path = "/tmp/exact/review/SKILL.md",
        }};

        fn init(runtime: *InputRuntime, alloc: Allocator) !void {
            try runtime.composer_history.record(
                alloc,
                100,
                history_text,
                &history_blocks,
                &.{},
                &.{},
                &history_skills,
            );
            try runtime.edit_state.input.appendSlice(alloc, "unsent draft");
            runtime.edit_state.cursor = runtime.edit_state.input.items.len;
        }
    };
    const backing = std.testing.allocator;

    var probe = std.testing.FailingAllocator.init(backing, .{});
    var replacement_allocations: usize = undefined;
    {
        var runtime = InputRuntime{};
        try Fixture.init(&runtime, probe.allocator());
        const first_replacement_allocation = probe.alloc_index;
        _ = try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            probe.allocator(),
            -1,
            null,
            1,
            4096,
        );
        replacement_allocations = probe.alloc_index - first_replacement_allocation;
        runtime.deinit(probe.allocator());
    }
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..replacement_allocations) |replacement_fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        var runtime = InputRuntime{};
        try Fixture.init(&runtime, failing.allocator());
        failing.fail_index = failing.alloc_index + replacement_fail_index;

        if (navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            failing.allocator(),
            -1,
            null,
            1,
            4096,
        )) |_| {
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqualStrings("unsent draft", runtime.edit_state.input.items);
        try std.testing.expectEqual(
            @as(usize, "unsent draft".len),
            runtime.edit_state.cursor,
        );
        try std.testing.expectEqual(@as(?usize, null), runtime.composer_history.activeIndex());
        try std.testing.expect(runtime.composer_history.draftView() == null);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.pasted_blocks.items.len);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.skill_tokens.items.len);

        runtime.deinit(failing.allocator());
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "prompt history restores the saved draft after editing a recalled entry" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.composer_history.record(alloc, 100, "historical prompt", &.{}, &.{}, &.{}, &.{});
    try runtime.edit_state.input.appendSlice(alloc, "unsent draft");

    try navigateComposerHistoryForTest(&runtime, alloc, -1);
    try runtime.insertionState().insertSlice(alloc, "_edited", .preserve);
    try std.testing.expectEqualStrings("historical prompt_edited", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, 0), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("unsent draft", runtime.composer_history.draftText().?);

    try navigateComposerHistoryForTest(&runtime, alloc, 1);
    try std.testing.expectEqualStrings("unsent draft", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, null), runtime.composer_history.activeIndex());
    try std.testing.expect(runtime.composer_history.draftView() == null);
}

test "prompt history restores the complete saved semantic draft" {
    const alloc = std.testing.allocator;
    const original_bytes = "\x89PNG\r\n\x1a\nsaved-draft";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var source = try tmp.dir.createFile(std.testing.io, "draft.png", .{});
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, original_bytes);
    }
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "draft.png");
    defer alloc.free(source_path);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    try runtime.composer_history.record(
        alloc,
        100,
        "historical prompt",
        &.{},
        &.{},
        &.{},
        &.{},
    );
    const draft = "[Pasted text #4, 1 line] [Image #8] $review";
    try runtime.edit_state.input.appendSlice(alloc, draft);
    try appendPastedBlockForTest(&runtime, alloc, 4, "saved paste backing");
    try appendCapturedImageBlockForTest(
        &runtime,
        &images,
        alloc,
        source_path,
        snapshot_dir,
        8,
    );
    const skill_start = draft.len - "$review".len;
    try runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = skill_start,
        .raw_end = draft.len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/exact/review/SKILL.md"),
    });
    runtime.edit_state.cursor = 5;

    try std.testing.expectEqual(
        composer_history.NavigationResult{ .moved = 0 },
        try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            -1,
            &images,
            100,
            4096,
        ),
    );
    try std.testing.expectEqualStrings("historical prompt", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), images.items.len);

    try std.testing.expectEqual(
        composer_history.NavigationResult{ .moved = 0 },
        try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            1,
            &images,
            100,
            4096,
        ),
    );
    try std.testing.expectEqualStrings(draft, runtime.edit_state.input.items);
    try std.testing.expectEqual(draft.len, runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqualStrings(
        "saved paste backing",
        runtime.entities.pasted_blocks.items[0].text,
    );
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqual(@as(usize, 8), images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 8), runtime.entities.image_tokens.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "/tmp/exact/review/SKILL.md",
        runtime.entities.skill_tokens.items[0].path,
    );
    try std.testing.expectEqual(@as(?usize, null), runtime.composer_history.activeIndex());
    try std.testing.expect(runtime.composer_history.draftView() == null);
}

test "prompt history limit rejection preserves active and saved drafts" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.composer_history.record(
        alloc,
        100,
        "oversized",
        &.{},
        &.{},
        &.{},
        &.{},
    );
    try runtime.composer_history.record(alloc, 100, "new", &.{}, &.{}, &.{}, &.{});
    try runtime.edit_state.input.appendSlice(alloc, "unsent draft");

    try std.testing.expectEqual(
        composer_history.NavigationResult{ .moved = 0 },
        try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            -1,
            null,
            1,
            4096,
        ),
    );
    try std.testing.expectEqualStrings("new", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, 1), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings(
        "unsent draft",
        runtime.composer_history.draftText().?,
    );

    runtime.vertical_navigation.preferred_column = 7;
    try std.testing.expectEqual(
        composer_history.NavigationResult{ .limit_exceeded = "oversized".len },
        try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            -1,
            null,
            1,
            4,
        ),
    );
    try std.testing.expectEqualStrings("new", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, 1), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings(
        "unsent draft",
        runtime.composer_history.draftText().?,
    );
    try std.testing.expectEqual(@as(?usize, 7), runtime.vertical_navigation.preferredColumn());
}

test "prompt history limit counts registered paste backing text" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";
    const backing = "x" ** (paste_blocks.large_paste_char_threshold + 1);
    const blocks = [_]paste_blocks.PastedBlock{.{
        .id = 1,
        .text = @constCast(backing),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    }};
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.composer_history.record(
        alloc,
        100,
        placeholder,
        &blocks,
        &.{},
        &.{},
        &.{},
    );
    try runtime.edit_state.input.appendSlice(alloc, "draft");

    try std.testing.expectEqual(
        composer_history.NavigationResult{ .limit_exceeded = backing.len },
        try navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            -1,
            null,
            1,
            backing.len - 1,
        ),
    );
    try std.testing.expectEqualStrings("draft", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, null), runtime.composer_history.activeIndex());
}

test "prompt history corrupt image rejection preserves the active draft" {
    const alloc = std.testing.allocator;
    const original_bytes = "\x89PNG\r\n\x1a\nhistory";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var source = try tmp.dir.createFile(std.testing.io, "history.png", .{});
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, original_bytes);
    }
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "history.png");
    defer alloc.free(source_path);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    try runtime.edit_state.input.appendSlice(alloc, "[Image #8]");
    try appendCapturedImageBlockForTest(
        &runtime,
        &images,
        alloc,
        source_path,
        snapshot_dir,
        8,
    );
    try runtime.composer_history.record(
        alloc,
        100,
        runtime.edit_state.input.items,
        &.{},
        images.items,
        runtime.entities.image_tokens.items,
        &.{},
    );
    const snapshot_path = runtime.composer_history.viewEntry(0).?.images[0].snapshot_path.?;
    {
        var snapshot = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer snapshot.close(std.testing.io);
        try snapshot.writeStreamingAll(std.testing.io, "corrupt");
    }
    for (images.items) |image| types.freeImageAttachment(alloc, image);
    images.clearRetainingCapacity();
    runtime.inputResetState().clearCurrent(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "unsent draft");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    runtime.vertical_navigation.preferred_column = 3;

    try std.testing.expectError(
        error.ImageSnapshotCorrupt,
        navigateComposerHistoryWithEntitiesForTest(
            &runtime,
            alloc,
            -1,
            &images,
            100,
            4096,
        ),
    );
    try std.testing.expectEqualStrings("unsent draft", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "unsent draft".len), runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(?usize, null), runtime.composer_history.activeIndex());
    try std.testing.expect(runtime.composer_history.draftView() == null);
    try std.testing.expectEqual(@as(usize, 0), images.items.len);
    try std.testing.expectEqual(@as(?usize, 3), runtime.vertical_navigation.preferredColumn());
}

test "backspace removes full utf8 rune from input" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "a😀");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(runtime.deletionState(null).delete(
        std.testing.allocator,
        .character_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("a", runtime.edit_state.input.items);
}

test "composer movement and deletion keep terminal characters atomic" {
    const alloc = std.testing.allocator;

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.insertionState().insertSlice(alloc, "Ae\u{301}B", .preserve);
        _ = moveHorizontalForTest(&runtime, .character_left);
        _ = moveHorizontalForTest(&runtime, .character_left);
        try std.testing.expectEqual(@as(usize, 1), runtime.edit_state.cursor);
        try runtime.insertionState().insertSlice(alloc, "X", .preserve);
        try std.testing.expectEqualStrings("AXe\u{301}B", runtime.edit_state.input.items);
    }

    for ([_][]const u8{ "🇺🇸", "👍🏽", "👨‍👩‍👧‍👦" }) |character| {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.insertionState().insertSlice(alloc, "A", .preserve);
        try runtime.insertionState().insertSlice(alloc, character, .preserve);
        try runtime.insertionState().insertSlice(alloc, "B", .preserve);
        _ = moveHorizontalForTest(&runtime, .character_left);
        try std.testing.expect(runtime.deletionState(null).delete(
            alloc,
            .character_left,
            .clear,
        ));
        try std.testing.expectEqualStrings("AB", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), runtime.edit_state.cursor);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.insertionState().insertSlice(alloc, "A👨‍👩‍👧‍👦B", .preserve);
        runtime.edit_state.cursor = 1;
        try std.testing.expect(runtime.deletionState(null).delete(
            alloc,
            .character_right,
            .clear,
        ));
        try std.testing.expectEqualStrings("AB", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), runtime.edit_state.cursor);
    }
}

test "backspace removes image placeholder atomically and frees its attachment" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var snapshot = try tmp.dir.createFile(std.testing.io, "snapshot.bin", .{});
        defer snapshot.close(std.testing.io);
        try snapshot.writeStreamingAll(std.testing.io, "snapshot");
    }
    const snapshot_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.bin");
    defer alloc.free(snapshot_path);
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    var blocks: ImageBlocks = .empty;
    defer {
        for (blocks.items) |img| {
            alloc.free(img.path);
            alloc.free(img.media_type);
        }
        blocks.deinit(alloc);
    }

    try runtime.edit_state.input.appendSlice(alloc, "ab[Image #7]cd");
    runtime.edit_state.cursor = "ab[Image #7]".len;
    try runtime.entities.image_tokens.append(alloc, .{
        .id = 7,
        .span = .{ .raw_start = "ab".len, .raw_end = "ab[Image #7]".len },
    });
    try blocks.append(alloc, .{
        .id = 7,
        .path = try alloc.dupe(u8, "/tmp/x.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
        .snapshot_path = try alloc.dupe(u8, snapshot_path),
        .snapshot_sha256 = try alloc.dupe(u8, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
    });

    try std.testing.expect(runtime.deletionState(&blocks).delete(
        alloc,
        .character_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("abcd", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(std.testing.io, snapshot_path, .{}),
    );
}

test "backspace image placeholder removal preserves sorted attachment ids" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    var blocks: ImageBlocks = .empty;
    defer {
        for (blocks.items) |img| {
            alloc.free(img.path);
            alloc.free(img.media_type);
        }
        blocks.deinit(alloc);
    }

    try runtime.edit_state.input.appendSlice(alloc, "[Image #1][Image #2][Image #3]");
    runtime.edit_state.cursor = "[Image #1][Image #2]".len;
    var token_start: usize = 0;
    inline for (.{ 1, 2, 3 }) |id| {
        var token_buf: [32]u8 = undefined;
        const token = try std.fmt.bufPrint(&token_buf, "[Image #{d}]", .{id});
        try runtime.entities.image_tokens.append(alloc, .{
            .id = id,
            .span = .{ .raw_start = token_start, .raw_end = token_start + token.len },
        });
        token_start += token.len;
        try blocks.append(alloc, .{
            .id = id,
            .path = try std.fmt.allocPrint(alloc, "/tmp/{d}.png", .{id}),
            .media_type = try alloc.dupe(u8, "image/png"),
        });
    }

    try std.testing.expect(runtime.deletionState(&blocks).delete(
        alloc,
        .character_left,
        .clear,
    ));
    try std.testing.expectEqual(@as(usize, 2), blocks.items.len);
    try std.testing.expect(image_attachments.imageAttachmentsSortedById(blocks.items));
    try std.testing.expectEqual(@as(usize, 1), blocks.items[0].id);
    try std.testing.expectEqual(@as(usize, 3), blocks.items[1].id);
}

test "clear prompt history removes previous prompts" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.composer_history.record(std.testing.allocator, 100, "one", &.{}, &.{}, &.{}, &.{});
    try runtime.composer_history.record(std.testing.allocator, 100, "two", &.{}, &.{}, &.{}, &.{});
    runtime.composer_history.clear(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), runtime.composer_history.count());
    try std.testing.expect(runtime.composer_history.activeIndex() == null);
}

test "prompt history bulk install preserves chronological bytes and replaces prior entries" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.composer_history.record(alloc, 100, "old", &.{}, &.{}, &.{}, &.{});
    const invalid = [_]u8{ 0xff, 0x00, 0xfe };

    try runtime.composer_history.installTextEntries(alloc, &.{ "first", &invalid, "third" });

    try std.testing.expectEqual(@as(usize, 3), runtime.composer_history.count());
    try std.testing.expectEqualStrings("first", runtime.composer_history.entryText(0).?);
    try std.testing.expectEqualSlices(u8, &invalid, runtime.composer_history.entryText(1).?);
    try std.testing.expectEqualStrings("third", runtime.composer_history.entryText(2).?);
    try std.testing.expectEqual(@as(?usize, null), runtime.composer_history.activeIndex());
}

test "input escape parser separates plain up down from history arrows" {
    try expectEscapeAction("[A", .cursor_up);
    try expectEscapeAction("[B", .cursor_down);
    try expectEscapeAction("OA", .cursor_up);
    try expectEscapeAction("OB", .cursor_down);
    try expectEscapeAction("[1;1A", .cursor_up);
    try expectEscapeAction("[1;1B", .cursor_down);
    try expectEscapeAction("[57352;1u", .cursor_up);
    try expectEscapeAction("[57353;1u", .cursor_down);
    try expectEscapeAction("[57352u", .cursor_up);
    try expectEscapeAction("[57353u", .cursor_down);
}

test "input escape parser recognizes unmodified kitty Escape" {
    try expectEscapeAction("[27u", .escape);
    try expectEscapeAction("[27;1u", .escape);
    try expectEscapeAction("[27;1:1u", .escape);
    try expectEscapeAction("[27;1:2u", .escape);
    try expectEscapeAction("[27;1:3u", .ignore);
    // Ghostty with Num Lock active sends modifier 128 (bit 7).
    try expectEscapeAction("[27;129u", .escape);
    try expectEscapeAction("[27;129:1u", .escape);
    // Caps Lock (bit 6) should also be ignored.
    try expectEscapeAction("[27;65u", .escape);
    try expectEscapeAction("[27;65:1u", .escape);
}

test "input escape parser resolves unmodified kitty Backspace to a delete byte" {
    // Plain Backspace under the Kitty protocol is single-parameter ESC[127u.
    try expectEscapeAction("[127u", .{ .remapped_byte = 127 });
    // Modifier param is bitmask+1: ;1 = none, ;3 = Alt, ;9 = Super.
    try expectEscapeAction("[127;1u", .{ .remapped_byte = 127 });
    try expectEscapeAction("[127;3u", .delete_word_left);
    try expectEscapeAction("[127;9u", .delete_to_line_start);
    try expectEscapeAction("[13u", .{ .remapped_byte = '\r' });
    try expectEscapeAction("[13;1u", .{ .remapped_byte = '\r' });
    try expectEscapeAction("[9u", .{ .remapped_byte = '\t' });
    try expectEscapeAction("[9;1u", .{ .remapped_byte = '\t' });
}

test "input escape parser resolves unmapped single-parameter CSI u to ignore" {
    // A null result would leave the leading ESC's pending-cancel armed.
    try expectEscapeAction("[49u", .ignore);
    try expectEscapeAction("[111u", .ignore);
}

test "input escape parser preserves modified arrow intent" {
    try expectEscapeAction("[57352;2u", moveEscape(.visual_up, true));
    try expectEscapeAction("[57352;3u", moveEscape(.paragraph_up, false));
    try expectEscapeAction("[57353;5u", moveEscape(.visual_down, false));
    try expectEscapeAction("[57353;9u", moveEscape(.draft_end, false));
    try expectEscapeAction("[1;4D", moveEscape(.word_left, true));
}

test "input escape parser preserves double escape meta behavior" {
    try expectEscapeAction("\x1b[A", moveEscape(.paragraph_up, false));
    try expectEscapeAction("\x1b[B", moveEscape(.paragraph_down, false));
    try expectEscapeAction("\x1bOA", moveEscape(.paragraph_up, false));
    try expectEscapeAction("\x1bOB", moveEscape(.paragraph_down, false));
    try expectEscapeAction("\x1b[D", moveEscape(.word_left, false));
    try expectEscapeAction("\x1b[C", moveEscape(.word_right, false));
    try expectEscapeAction("\x1bb", .word_left);
    try expectEscapeAction("\x1bd", .{ .composer_shortcut = .delete_word_right });

    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, 0x1b));
    stage = 0; // timeout/reset between escape sequences clears Meta intent
    stage = 1;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_up), consumeInputEscapeByte(&stage, &param, &param2, 'A'));
}

test "input escape parser handles alt+d as delete_word_right" {
    try expectEscapeAction("d", .{ .composer_shortcut = .delete_word_right });
    try expectEscapeAction("[100;3u", .delete_word_right);
    try expectEscapeAction("[27;3;100~", .delete_word_right);
}

test "input escape parser handles kitty alt+b and alt+f as word navigation" {
    try expectEscapeAction("[98;3u", .word_left);
    try expectEscapeAction("[102;3u", .word_right);
}

test "input escape parser preserves shift on enhanced control and alt movement aliases" {
    try expectEscapeAction("[97;6u", moveEscape(.line_start, true));
    try expectEscapeAction("[27;6;97~", moveEscape(.line_start, true));
    try expectEscapeAction("[98;6u", moveEscape(.character_left, true));
    try expectEscapeAction("[27;6;98~", moveEscape(.character_left, true));
    try expectEscapeAction("[101;6u", moveEscape(.line_end, true));
    try expectEscapeAction("[27;6;101~", moveEscape(.line_end, true));
    try expectEscapeAction("[102;6u", moveEscape(.character_right, true));
    try expectEscapeAction("[27;6;102~", moveEscape(.character_right, true));
    try expectEscapeAction("[98;4u", moveEscape(.word_left, true));
    try expectEscapeAction("[27;4;98~", moveEscape(.word_left, true));
    try expectEscapeAction("[102;4u", moveEscape(.word_right, true));
    try expectEscapeAction("[27;4;102~", moveEscape(.word_right, true));
}

test "vertical movement scans hard newline rows and preserves preferred column" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "abcdef\nxy\nabcdef");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try expectScanMatchesLayout(runtime, .up, 80, &.{});
    try std.testing.expect(moveVerticalForTest(&runtime, .up, 80, &.{}));
    try std.testing.expectEqual(@as(usize, "abcdef\nxy".len), runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(?usize, 6), runtime.vertical_navigation.preferredColumn());

    try std.testing.expect(moveVerticalForTest(&runtime, .up, 80, &.{}));
    try std.testing.expectEqual(@as(usize, "abcdef".len), runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(?usize, 6), runtime.vertical_navigation.preferredColumn());
}

test "vertical movement scans soft wraps and boundary-owned rows" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "abcdefgh");
    runtime.edit_state.cursor = 4;

    const scan = scanInputCursorVertical(&runtime, .up, 6, &.{});
    try std.testing.expect(scan.target != null);
    try std.testing.expectEqual(@as(usize, 2), scan.total_rows);
    try std.testing.expectEqual(@as(usize, 1), scan.cursor_row);
    try std.testing.expectEqual(visual_layout.scanAdjacentRow(.{ .input = runtime.edit_state.input.items, .cursor = runtime.edit_state.cursor, .terminal_cols = 6 }, .up, null).target.?.raw_offset, scan.target.?.raw_offset);
}

test "vertical movement targets visual units exactly" {
    const alloc = std.testing.allocator;
    const images = [_]types.ImageAttachment{
        .{ .id = 5, .path = @constCast("/tmp/five.png"), .media_type = @constCast("image/png") },
    };
    const cases = [_]struct {
        input: []const u8,
        cursor: usize,
        cols: u16,
        images: []const types.ImageAttachment = &.{},
    }{
        .{ .input = "界\nab", .cursor = "界\nab".len, .cols = 80 },
        .{ .input = "a\xcc\x81\nb", .cursor = "a\xcc\x81\nb".len, .cols = 80 },
        .{ .input = "\xffx\ny", .cursor = "\xffx\ny".len, .cols = 80 },
        .{ .input = "\tX\nz", .cursor = "\tX\nz".len, .cols = 10 },
        .{ .input = "[Image #5]\nz", .cursor = 3, .cols = 80, .images = &images },
        .{ .input = "[Image #6]\nz", .cursor = "[Image #6]\nz".len, .cols = 80 },
        .{ .input = "[Image #999999999999999999999999999999999999]\nz", .cursor = "[Image #999999999999999999999999999999999999]\nz".len, .cols = 80 },
        .{ .input = "😀\nz", .cursor = 1, .cols = 80 },
    };

    for (cases) |case| {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, case.input);
        runtime.edit_state.cursor = case.cursor;
        try expectScanMatchesLayout(runtime, .down, case.cols, case.images);
    }
}

test "vertical movement never targets inside a registered paste" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    const placeholder = "[Pasted text #7, 1 line]";
    const input = "x\n" ++ placeholder;
    try runtime.edit_state.input.appendSlice(alloc, input);
    try runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "P" ** 1001),
        .line_count = 1,
        .span = .{
            .raw_start = "x\n".len,
            .raw_end = input.len,
        },
    });
    runtime.edit_state.cursor = input.len;

    try std.testing.expect(moveVerticalForTest(&runtime, .up, 80, &.{}));
    _ = moveHorizontalForTest(&runtime, .character_left);
    _ = moveHorizontalForTest(&runtime, .character_right);
    const down = scanInputCursorVertical(&runtime, .down, 80, &.{});
    try std.testing.expect(down.target != null);
    try std.testing.expectEqual(@as(usize, "x\n".len), down.target.?.raw_offset);
    try std.testing.expect(!runtime.entities.pasted_blocks.items[0].span.contains(
        down.target.?.raw_offset,
    ));

    const cursor_before_defensive_rejection = runtime.edit_state.cursor;
    try std.testing.expect(!applyVerticalTargetForTest(&runtime, .{
        .target = .{
            .raw_offset = runtime.entities.pasted_blocks.items[0].span.raw_start + 1,
            .row_index = 1,
            .content_column = 1,
        },
        .preferred_column = 1,
        .total_rows = 2,
        .cursor_row = 0,
    }));
    try std.testing.expectEqual(
        cursor_before_defensive_rejection,
        runtime.edit_state.cursor,
    );
}

test "vertical scan reports null target facts at visual edges" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "abc");
    runtime.edit_state.cursor = 0;

    const scan = scanInputCursorVertical(&runtime, .up, 80, &.{});
    try std.testing.expect(scan.target == null);
    try std.testing.expectEqual(@as(usize, 1), scan.total_rows);
    try std.testing.expectEqual(@as(usize, 0), scan.cursor_row);
    try std.testing.expect(!applyVerticalTargetForTest(&runtime, scan));
    try std.testing.expect(runtime.vertical_navigation.preferredColumn() == null);
}

test "vertical intent resets before nonvertical no-op cursor movement" {
    const alloc = std.testing.allocator;
    var top = InputRuntime{};
    defer top.deinit(alloc);
    try top.edit_state.input.appendSlice(alloc, "abc\n");
    top.edit_state.cursor = top.edit_state.input.items.len;
    try std.testing.expect(moveVerticalForTest(&top, .up, 80, &.{}));
    try std.testing.expectEqual(@as(usize, 0), top.edit_state.cursor);
    try std.testing.expect(top.vertical_navigation.preferredColumn() != null);
    _ = moveHorizontalForTest(&top, .character_left);
    try std.testing.expect(top.vertical_navigation.preferredColumn() == null);
    _ = moveHorizontalForTest(&top, .draft_start);
    try std.testing.expect(top.vertical_navigation.preferredColumn() == null);
    const down = scanInputCursorVertical(&top, .down, 80, &.{});
    try std.testing.expectEqual(@as(usize, 0), down.preferred_column);

    var end = InputRuntime{};
    defer end.deinit(alloc);
    try end.edit_state.input.appendSlice(alloc, "abc\n");
    end.edit_state.cursor = 0;
    try std.testing.expect(moveVerticalForTest(&end, .down, 80, &.{}));
    try std.testing.expectEqual(end.edit_state.input.items.len, end.edit_state.cursor);
    try std.testing.expect(end.vertical_navigation.preferredColumn() != null);
    _ = moveHorizontalForTest(&end, .character_right);
    try std.testing.expect(end.vertical_navigation.preferredColumn() == null);
    _ = moveHorizontalForTest(&end, .draft_end);
    try std.testing.expect(end.vertical_navigation.preferredColumn() == null);
    const up = scanInputCursorVertical(&end, .up, 80, &.{});
    try std.testing.expectEqual(@as(usize, 0), up.preferred_column);
}

test "line boundary cursor movement stays on the current logical line" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "FIRST\nSECOND\n\nTHIRD");

    runtime.edit_state.cursor = "FIRST\nSEC".len;
    runtime.vertical_navigation.preferred_column = 3;
    _ = moveHorizontalForTest(&runtime, .line_start);
    try std.testing.expectEqual(@as(usize, "FIRST\n".len), runtime.edit_state.cursor);
    try std.testing.expect(runtime.vertical_navigation.preferredColumn() == null);

    runtime.edit_state.cursor = "FIRST\nSEC".len;
    _ = moveHorizontalForTest(&runtime, .line_end);
    try std.testing.expectEqual(@as(usize, "FIRST\nSECOND".len), runtime.edit_state.cursor);

    runtime.edit_state.cursor = "FIRST\nSECOND\n".len;
    _ = moveHorizontalForTest(&runtime, .line_start);
    try std.testing.expectEqual(@as(usize, "FIRST\nSECOND\n".len), runtime.edit_state.cursor);
    _ = moveHorizontalForTest(&runtime, .line_end);
    try std.testing.expectEqual(@as(usize, "FIRST\nSECOND\n".len), runtime.edit_state.cursor);
}

fn expectEscapeAction(bytes: []const u8, expected: InputEscapeAction) !void {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    var action: ?InputEscapeAction = null;
    for (bytes) |byte| {
        action = consumeInputEscapeByte(&stage, &param, &param2, byte);
    }
    try std.testing.expectEqual(@as(?InputEscapeAction, expected), action);
    try std.testing.expectEqual(@as(u8, 0), stage);
}

fn moveEscape(kind: input_action.MoveKind, extend_selection: bool) InputEscapeAction {
    return .{ .composer_shortcut = .{ .move = .{
        .kind = kind,
        .extend_selection = extend_selection,
    } } };
}

fn expectScanMatchesLayout(runtime: InputRuntime, direction: visual_layout.Direction, cols: u16, images: []const types.ImageAttachment) !void {
    const actual = scanInputCursorVertical(&runtime, direction, cols, images);
    const expected = visual_layout.scanAdjacentRow(.{
        .input = runtime.edit_state.input.items,
        .cursor = runtime.edit_state.cursor,
        .terminal_cols = cols,
        .images = images,
        .pasted_blocks = runtime.entities.pasted_blocks.items,
        .image_tokens = runtime.entities.image_tokens.items,
        .skill_tokens = runtime.entities.skill_tokens.items,
    }, direction, null);
    try std.testing.expectEqual(expected.total_rows, actual.total_rows);
    try std.testing.expectEqual(expected.cursor_row, actual.cursor_row);
    try std.testing.expectEqual(expected.preferred_column, actual.preferred_column);
    if (expected.target) |target| {
        try std.testing.expect(actual.target != null);
        try std.testing.expectEqual(target.raw_offset, actual.target.?.raw_offset);
        try std.testing.expectEqual(target.row_index, actual.target.?.row_index);
        try std.testing.expectEqual(target.content_column, actual.target.?.content_column);
    } else {
        try std.testing.expect(actual.target == null);
    }
}

test "input escape parser handles plain csi cursor arrows" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(u8, 2), stage);
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_up), consumeInputEscapeByte(&stage, &param, &param2, 'A'));

    stage = 1;
    param = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_down), consumeInputEscapeByte(&stage, &param, &param2, 'B'));
}

test "input escape parser handles plain ss3 cursor arrows" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, 'O'));
    try std.testing.expectEqual(@as(u8, 4), stage);
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_up), consumeInputEscapeByte(&stage, &param, &param2, 'A'));

    stage = 1;
    param = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, 'O'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_down), consumeInputEscapeByte(&stage, &param, &param2, 'B'));
}

test "input escape parser handles cursor movement and delete" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_left), consumeInputEscapeByte(&stage, &param, &param2, 'D'));

    stage = 1;
    param = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, .cursor_right), consumeInputEscapeByte(&stage, &param, &param2, 'C'));

    stage = 1;
    param = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, .home), consumeInputEscapeByte(&stage, &param, &param2, 'H'));

    stage = 1;
    param = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_next), consumeInputEscapeByte(&stage, &param, &param2, '~'));
}

test "input escape parser handles page navigation" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .page_up), consumeInputEscapeByte(&stage, &param, &param2, '~'));

    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '6'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .page_down), consumeInputEscapeByte(&stage, &param, &param2, '~'));
}

test "input escape parser handles SGR mouse wheel events" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    var mouse = MouseInput{};
    const up = "\x1b[<64;12;7M";
    for (up[1..up.len], 0..) |byte, index| {
        const action = consumeInputEscapeByteWithMouse(
            &stage,
            &param,
            &param2,
            &mouse,
            byte,
        );
        if (index + 1 == up.len - 1) {
            try std.testing.expectEqual(
                @as(?InputEscapeAction, .{ .mouse_wheel = .up }),
                action,
            );
        } else {
            try std.testing.expectEqual(@as(?InputEscapeAction, null), action);
        }
    }
    try std.testing.expectEqual(@as(u8, 0), stage);

    stage = 1;
    const down = "\x1b[<65;12;7M";
    for (down[1..down.len], 0..) |byte, index| {
        const action = consumeInputEscapeByteWithMouse(
            &stage,
            &param,
            &param2,
            &mouse,
            byte,
        );
        if (index + 1 == down.len - 1) {
            try std.testing.expectEqual(
                @as(?InputEscapeAction, .{ .mouse_wheel = .down }),
                action,
            );
        } else {
            try std.testing.expectEqual(@as(?InputEscapeAction, null), action);
        }
    }
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser preserves SGR left pointer actions" {
    const Case = struct {
        sequence: []const u8,
        expected: InputEscapeAction,
    };
    const cases = [_]Case{
        .{
            .sequence = "\x1b[<0;12;7M",
            .expected = .{ .mouse_pointer = .{
                .kind = .press,
                .column = 12,
                .row = 7,
            } },
        },
        .{
            .sequence = "\x1b[<32;15;8M",
            .expected = .{ .mouse_pointer = .{
                .kind = .drag,
                .column = 15,
                .row = 8,
            } },
        },
        .{
            .sequence = "\x1b[<0;15;8m",
            .expected = .{ .mouse_pointer = .{
                .kind = .release,
                .column = 15,
                .row = 8,
            } },
        },
    };

    for (cases) |case| {
        var stage: u8 = 1;
        var param: u16 = 0;
        var param2: u16 = 0;
        var mouse = MouseInput{};
        var action: ?InputEscapeAction = null;
        for (case.sequence[1..]) |byte| {
            action = consumeInputEscapeByteWithMouse(
                &stage,
                &param,
                &param2,
                &mouse,
                byte,
            );
        }
        try std.testing.expectEqual(@as(?InputEscapeAction, case.expected), action);
        try std.testing.expectEqual(@as(u8, 0), stage);
    }
}

test "input escape parser handles legacy X10 mouse reports" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: InputEscapeAction,
    }{
        .{ .bytes = "[M\x60\x2a\x25", .expected = .{ .mouse_wheel = .up } },
        .{ .bytes = "[M\x61\x2a\x25", .expected = .{ .mouse_wheel = .down } },
        .{ .bytes = "[M\x20\x2a\x25", .expected = .ignore },
        .{ .bytes = "[M\x1b\x2a\x25", .expected = .ignore },
    };

    for (cases) |case| {
        var stage: u8 = 1;
        var param: u16 = 0;
        var param2: u16 = 0;
        var mouse = MouseInput{};
        for (case.bytes, 0..) |byte, index| {
            const action = consumeInputEscapeByteWithMouse(
                &stage,
                &param,
                &param2,
                &mouse,
                byte,
            );
            if (index + 1 == case.bytes.len) {
                try std.testing.expectEqual(@as(?InputEscapeAction, case.expected), action);
            } else {
                try std.testing.expectEqual(@as(?InputEscapeAction, null), action);
            }
        }
        try std.testing.expectEqual(@as(u8, 0), stage);
    }
}

test "input escape parser bounds expired SGR and X10 mouse report tails" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    var mouse = MouseInput{};

    for ("[<64;79") |byte| {
        try std.testing.expectEqual(
            @as(?InputEscapeAction, null),
            consumeInputEscapeByteWithMouse(&stage, &param, &param2, &mouse, byte),
        );
    }
    try std.testing.expect(beginMouseReportDiscard(&stage, &param, &param2, &mouse));
    try std.testing.expect(isMouseReportDiscardStage(stage));
    for (";12", 0..) |byte, index| {
        _ = index;
        try std.testing.expectEqual(
            MouseReportDiscardResult.pending,
            consumeMouseReportDiscardByte(&stage, &param, &param2, &mouse, byte),
        );
    }
    try std.testing.expectEqual(
        MouseReportDiscardResult.report_end,
        consumeMouseReportDiscardByte(&stage, &param, &param2, &mouse, 'M'),
    );
    try std.testing.expectEqual(@as(u8, 0), stage);

    stage = 1;
    param = 0;
    param2 = 0;
    mouse.reset();
    for ("[<") |byte| {
        try std.testing.expectEqual(
            @as(?InputEscapeAction, null),
            consumeInputEscapeByteWithMouse(&stage, &param, &param2, &mouse, byte),
        );
    }
    try std.testing.expect(beginMouseReportDiscard(&stage, &param, &param2, &mouse));
    const max_sgr_mouse_report_tail_bytes: usize = 18;
    for (0..max_sgr_mouse_report_tail_bytes) |index| {
        const expected: MouseReportDiscardResult = if (index + 1 == max_sgr_mouse_report_tail_bytes)
            .bound
        else
            .pending;
        try std.testing.expectEqual(
            expected,
            consumeMouseReportDiscardByte(&stage, &param, &param2, &mouse, 'x'),
        );
    }
    try std.testing.expectEqual(@as(u8, 0), stage);

    stage = 1;
    param = 0;
    param2 = 0;
    mouse.reset();
    for ("[M") |byte| {
        try std.testing.expectEqual(
            @as(?InputEscapeAction, null),
            consumeInputEscapeByteWithMouse(&stage, &param, &param2, &mouse, byte),
        );
    }
    try std.testing.expect(beginMouseReportDiscard(&stage, &param, &param2, &mouse));
    for ("\x60\x2a", 0..) |byte, index| {
        _ = index;
        try std.testing.expectEqual(
            MouseReportDiscardResult.pending,
            consumeMouseReportDiscardByte(&stage, &param, &param2, &mouse, byte),
        );
    }
    try std.testing.expectEqual(
        MouseReportDiscardResult.bound,
        consumeMouseReportDiscardByte(&stage, &param, &param2, &mouse, '\x25'),
    );
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser keeps private CSI digits in the escape sequence" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    for ("[?12") |byte| {
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, byte));
    }
    try std.testing.expect(isControlSequenceDiscardStage(stage));
    try std.testing.expectEqual(@as(?InputEscapeAction, .ignore), consumeInputEscapeByte(&stage, &param, &param2, 'h'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser ignores complete unknown CSI and SS3 sequences" {
    try expectEscapeAction("[I", .ignore);
    try expectEscapeAction("[1;2R", .ignore);
    try expectEscapeAction("[>0q", .ignore);
    try expectEscapeAction("O1;2P", .ignore);
}

test "input escape parser keeps an unknown control sequence pending until its final byte" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    for ("[>0") |byte| {
        try std.testing.expectEqual(
            @as(?InputEscapeAction, null),
            consumeInputEscapeByte(&stage, &param, &param2, byte),
        );
    }
    try std.testing.expect(isControlSequenceDiscardStage(stage));
    try std.testing.expectEqual(
        @as(?InputEscapeAction, .ignore),
        consumeInputEscapeByte(&stage, &param, &param2, 'q'),
    );
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser restarts from an expired mouse report on Escape" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    var mouse = MouseInput{};

    for ("[<64") |byte| {
        try std.testing.expectEqual(
            @as(?InputEscapeAction, null),
            consumeInputEscapeByteWithMouse(&stage, &param, &param2, &mouse, byte),
        );
    }
    try std.testing.expect(beginMouseReportDiscard(&stage, &param, &param2, &mouse));
    try std.testing.expectEqual(
        MouseReportDiscardResult.restart,
        consumeMouseReportDiscardByte(&stage, &param, &param2, &mouse, 0x1b),
    );
    try std.testing.expectEqual(@as(u8, 1), stage);
    try std.testing.expectEqual(@as(u16, 0), param);
    try std.testing.expectEqual(@as(u16, 0), param2);
}

test "input escape parser handles alt+enter as insert_newline" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, .insert_newline), consumeInputEscapeByte(&stage, &param, &param2, '\r'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles enhanced alt+enter as insert_newline" {
    try expectEscapeAction("[13;3u", .insert_newline);
    try expectEscapeAction("[27;3;13~", .insert_newline);
}

test "input escape parser handles shift+enter csi u sequence" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .insert_newline), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser preserves encoded shift+space as text" {
    try expectEscapeAction("[32;2u", .{ .remapped_byte = ' ' });
    try expectEscapeAction("[27;2;32~", .{ .remapped_byte = ' ' });
}

test "input escape parser handles shift+tab sequences" {
    const Parser = struct {
        fn expectSequence(sequence: []const u8) !void {
            var stage: u8 = 1;
            var param: u16 = 0;
            var param2: u16 = 0;
            for (sequence[0 .. sequence.len - 1]) |byte| {
                try std.testing.expectEqual(
                    @as(?InputEscapeAction, null),
                    consumeInputEscapeByte(&stage, &param, &param2, byte),
                );
            }
            try std.testing.expectEqual(
                @as(?InputEscapeAction, .toggle_permission_mode),
                consumeInputEscapeByte(&stage, &param, &param2, sequence[sequence.len - 1]),
            );
            try std.testing.expectEqual(@as(u8, 0), stage);
        }
    };

    try Parser.expectSequence("[Z");
    try Parser.expectSequence("[1;2Z");
    try Parser.expectSequence("[9;2u");
    try Parser.expectSequence("[27;2;9~");
}

test "input escape parser handles modifyOtherKeys shift+enter sequence" {
    // ESC[27;2;13~ — modifyOtherKeys format for Shift+Enter
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '7'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .insert_newline), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles delivered command editing shortcuts" {
    try expectEscapeAction("[97;9u", .{ .composer_shortcut = .select_all });
    try expectEscapeAction("[99;9u", .{ .composer_shortcut = .copy_selection });
    try expectEscapeAction("[120;9u", .{ .composer_shortcut = .cut_selection });
    try expectEscapeAction("[122;9u", .{ .composer_shortcut = .undo });
    try expectEscapeAction("[122;10u", .{ .composer_shortcut = .redo });
    try expectEscapeAction("[95;5u", .{ .remapped_byte = 31 });

    try expectEscapeAction("[27;9;97~", .{ .composer_shortcut = .select_all });
    try expectEscapeAction("[27;9;99~", .{ .composer_shortcut = .copy_selection });
    try expectEscapeAction("[27;9;120~", .{ .composer_shortcut = .cut_selection });
    try expectEscapeAction("[27;9;122~", .{ .composer_shortcut = .undo });
    try expectEscapeAction("[27;10;122~", .{ .composer_shortcut = .redo });
    try expectEscapeAction("[27;5;95~", .{ .remapped_byte = 31 });
}

test "input escape parser decodes bracketed paste start ESC[200~" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .paste_start), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser decodes bracketed paste end ESC[201~" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .paste_end), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

const EscapeParseResult = struct {
    action: ?InputEscapeAction,
    stage: u8,
    param: u16,
    param2: u16,
};

fn parseEscapeForTest(bytes: []const u8) EscapeParseResult {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    var action: ?InputEscapeAction = null;
    for (bytes) |byte| {
        action = consumeInputEscapeByte(&stage, &param, &param2, byte);
    }
    return .{
        .action = action,
        .stage = stage,
        .param = param,
        .param2 = param2,
    };
}

test "input escape parser only accepts canonical paste markers" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: InputEscapeAction,
    }{
        .{ .bytes = "[200~", .expected = .paste_start },
        .{ .bytes = "[201~", .expected = .paste_end },
        .{ .bytes = "[0200~", .expected = .ignore },
        .{ .bytes = "[00200~", .expected = .ignore },
        .{ .bytes = "[0201~", .expected = .ignore },
        .{ .bytes = "[200;1~", .expected = .ignore },
        .{ .bytes = "[201;1~", .expected = .ignore },
    };

    for (cases) |case| {
        const result = parseEscapeForTest(case.bytes);
        try std.testing.expectEqual(@as(?InputEscapeAction, case.expected), result.action);
        try std.testing.expectEqual(@as(u8, 0), result.stage);
        try std.testing.expectEqual(@as(u16, 0), result.param);
        try std.testing.expectEqual(@as(u16, 0), result.param2);
    }
}

test "input escape parser ignores long leading-zero paste marker without overflowing digit count" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;

    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    var i: usize = 0;
    while (i < @as(usize, std.math.maxInt(u16)) + 4) : (i += 1) {
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    }
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .ignore), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
    try std.testing.expectEqual(@as(u16, 0), param);
    try std.testing.expectEqual(@as(u16, 0), param2);
}

test "input escape parser ignores long parameterized false paste start without overflowing" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;

    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    for ("200;999999") |byte| {
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, byte));
    }
    try std.testing.expectEqual(@as(?InputEscapeAction, .ignore), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
    try std.testing.expectEqual(@as(u16, 0), param);
    try std.testing.expectEqual(@as(u16, 0), param2);
}

test "input escape parser ignores long third csi parameter without overflowing" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;

    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    for ("27;2;999999") |byte| {
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, byte));
    }
    try std.testing.expectEqual(@as(?InputEscapeAction, .ignore), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
    try std.testing.expectEqual(@as(u16, 0), param);
    try std.testing.expectEqual(@as(u16, 0), param2);
}

test "input escape parser rearms on fresh escape after incomplete sequence" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;

    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, 0x1b));
    try std.testing.expectEqual(@as(u8, 1), stage);
    try std.testing.expectEqual(@as(u16, 0), param);
    try std.testing.expectEqual(@as(u16, 0), param2);

    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .paste_start), consumeInputEscapeByte(&stage, &param, &param2, '~'));
}

test "input escape parser handles ctrl+c csi u sequence" {
    // ESC[99;5u — Kitty protocol for Ctrl+C (keycode 99='c', modifier 5=ctrl+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    const result = consumeInputEscapeByte(&stage, &param, &param2, 'u');
    try std.testing.expect(result != null);
    switch (result.?) {
        .remapped_byte => |b| try std.testing.expectEqual(@as(u8, 3), b),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ctrl+v csi u sequence" {
    // ESC[118;5u — Kitty protocol for Ctrl+V (keycode 118='v', modifier 5=ctrl+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '8'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    const result = consumeInputEscapeByte(&stage, &param, &param2, 'u');
    try std.testing.expect(result != null);
    switch (result.?) {
        .remapped_byte => |b| try std.testing.expectEqual(@as(u8, 22), b),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser admits raw ctrl+o control byte" {
    try std.testing.expectEqual(
        @as(?InputEscapeAction, .toggle_full_transcript),
        controlByteFeatureAction(15),
    );
    try std.testing.expectEqual(@as(?InputEscapeAction, null), controlByteFeatureAction(3));
}

test "input escape parser handles ctrl+o csi u sequence" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .toggle_full_transcript), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser ignores meta o" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, .ignore), consumeInputEscapeByte(&stage, &param, &param2, 'o'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser rejects ctrl meta o csi u sequence" {
    // ESC[111;7u is Ctrl+Meta+O. It must not reach the Ctrl-O action.
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    for ("[111;7") |byte| {
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, byte));
    }
    try std.testing.expectEqual(@as(?InputEscapeAction, .ignore), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
}

test "input escape parser handles modifyOtherKeys ctrl o" {
    // ESC[27;5;111~ is modifyOtherKeys Ctrl+O.
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    for ("[27;5;111") |byte| {
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, byte));
    }
    try std.testing.expectEqual(@as(?InputEscapeAction, .toggle_full_transcript), consumeInputEscapeByte(&stage, &param, &param2, '~'));
}

test "input cursor movement edits inside line" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.edit_state.input.appendSlice(std.testing.allocator, "ab😀c");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    _ = moveHorizontalForTest(&runtime, .character_left);
    try std.testing.expectEqualStrings("ab😀c", runtime.edit_state.input.items);
    try std.testing.expect(runtime.edit_state.cursor < runtime.edit_state.input.items.len);

    try runtime.insertionState().insertByte(std.testing.allocator, 'X', .clear);
    try std.testing.expectEqualStrings("ab😀Xc", runtime.edit_state.input.items);

    try std.testing.expect(runtime.deletionState(null).delete(
        std.testing.allocator,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("ab😀X", runtime.edit_state.input.items);
}

test "slash completion dismissal survives edits until the slash trigger is removed" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "/mo");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    runtime.picker.slash_completion_index = 2;
    runtime.picker.slash_completion_window_start = 1;
    runtime.picker.dismissInlinePicker(.slash);

    _ = moveHorizontalForTest(&runtime, .character_left);
    try std.testing.expect(runtime.picker.isInlinePickerDismissed(.slash));

    try runtime.insertionState().insertByte(alloc, 'd', .clear);
    try std.testing.expect(runtime.picker.isInlinePickerDismissed(.slash));
    try std.testing.expectEqual(@as(usize, 0), runtime.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 0), runtime.picker.slash_completion_window_start);

    runtime.inputResetState().clearCurrent(alloc);
    try std.testing.expect(!runtime.picker.isInlinePickerDismissed(.slash));
}

test "inline picker dismissal follows the active trigger kind" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.textReplacementState().replace(alloc, "/model gpt");
    runtime.picker.dismissInlinePicker(.model);
    try std.testing.expect(runtime.picker.activeModelPickerQuery(&runtime.edit_state) == null);

    try runtime.insertionState().insertByte(alloc, '-', .clear);
    try std.testing.expect(runtime.picker.isInlinePickerDismissed(.model));
    try std.testing.expect(runtime.picker.activeModelPickerQuery(&runtime.edit_state) == null);

    try runtime.textReplacementState().replace(alloc, "@src");
    runtime.picker.dismissInlinePicker(.file);
    try std.testing.expect(runtime.picker.activeFilePickerQuery(&runtime.edit_state) == null);

    try runtime.insertionState().insertByte(alloc, '/', .clear);
    try std.testing.expect(runtime.picker.isInlinePickerDismissed(.file));
    try std.testing.expect(runtime.picker.activeFilePickerQuery(&runtime.edit_state) == null);

    runtime.inputResetState().clearCurrent(alloc);
    try runtime.insertionState().insertSlice(alloc, "/", .preserve);
    try std.testing.expect(runtime.picker.dismissed_inline_picker == null);
}

test "registered paste skill and image spans are atomic editor boundaries" {
    const alloc = std.testing.allocator;

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        const placeholder = "[Pasted text #7, 1 line]";
        try runtime.edit_state.input.appendSlice(alloc, "A" ++ placeholder ++ "B");
        try runtime.entities.pasted_blocks.append(alloc, .{
            .id = 7,
            .text = try alloc.dupe(u8, "pasted"),
            .line_count = 1,
            .span = .{ .raw_start = 1, .raw_end = 1 + placeholder.len },
        });

        runtime.edit_state.cursor = 1 + placeholder.len;
        _ = moveHorizontalForTest(&runtime, .character_left);
        try std.testing.expectEqual(@as(usize, 1), runtime.edit_state.cursor);
        _ = moveHorizontalForTest(&runtime, .character_right);
        try std.testing.expectEqual(@as(usize, 1 + placeholder.len), runtime.edit_state.cursor);

        runtime.edit_state.cursor = 1 + placeholder.len - 1;
        try std.testing.expect(runtime.deletionState(null).delete(
            alloc,
            .character_left,
            .clear,
        ));
        try std.testing.expectEqualStrings("AB", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.pasted_blocks.items.len);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "review hello");
        try runtime.skillBindingState().bindSkillToken(alloc, 0, "review".len, "review", "/tmp/review/SKILL.md", null);

        runtime.edit_state.cursor = 0;
        _ = moveHorizontalForTest(&runtime, .word_right);
        try std.testing.expectEqual(@as(usize, "$review".len), runtime.edit_state.cursor);
        _ = moveHorizontalForTest(&runtime, .word_left);
        try std.testing.expectEqual(@as(usize, 0), runtime.edit_state.cursor);
        try std.testing.expect(runtime.deletionState(null).delete(
            alloc,
            .character_right,
            .clear,
        ));
        try std.testing.expectEqualStrings(" hello", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.skill_tokens.items.len);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        var images: ImageBlocks = .empty;
        defer deinitImageBlocksForTest(&images, alloc);
        try runtime.edit_state.input.appendSlice(alloc, "HEAD [Image #1] TAIL");
        try appendImageBlockForTest(&runtime, &images, alloc, 1);

        runtime.edit_state.cursor = 0;
        try std.testing.expect(runtime.deletionState(&images).delete(
            alloc,
            .word_right,
            .clear,
        ));
        try std.testing.expectEqualStrings("[Image #1] TAIL", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), images.items.len);
        try std.testing.expect(runtime.deletionState(&images).delete(
            alloc,
            .word_right,
            .clear,
        ));
        try std.testing.expectEqualStrings(" TAIL", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), images.items.len);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        var images: ImageBlocks = .empty;
        defer deinitImageBlocksForTest(&images, alloc);
        try runtime.edit_state.input.appendSlice(alloc, "[Image #1] ");
        try appendImageBlockForTest(&runtime, &images, alloc, 1);
        runtime.edit_state.cursor = runtime.edit_state.input.items.len;

        try std.testing.expect(runtime.deletionState(&images).delete(
            alloc,
            .word_left,
            .clear,
        ));
        try std.testing.expectEqual(@as(usize, 0), runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), images.items.len);
    }
}

test "forward delete removes a skill token with its owned separator" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "review");
    try runtime.skillBindingState().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    );
    try runtime.insertionState().insertSlice(alloc, "hello", .preserve);

    try std.testing.expectEqualStrings("$review hello", runtime.edit_state.input.items);
    try std.testing.expect(runtime.entities.skill_tokens.items[0].owns_trailing_separator);
    runtime.edit_state.cursor = 0;
    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("hello", runtime.edit_state.input.items);
}

test "forward word delete removes a skill token with its owned separator" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "review");
    try runtime.skillBindingState().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    );
    try runtime.insertionState().insertSlice(alloc, "hello", .preserve);

    runtime.edit_state.cursor = 0;
    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("hello", runtime.edit_state.input.items);
}

test "typing a separator claims the skill token gap as user input" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "review");
    try runtime.skillBindingState().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    );

    try std.testing.expectEqual(
        InsertResult.inserted,
        try runtime.insertionState().insertByteBounded(alloc, ' ', 4096, .clear),
    );
    try std.testing.expectEqualStrings("$review ", runtime.edit_state.input.items);
    try std.testing.expect(!runtime.entities.skill_tokens.items[0].owns_trailing_separator);
    runtime.edit_state.cursor = 0;
    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings(" ", runtime.edit_state.input.items);
}

test "typing a text scalar claims the skill token gap as user input" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "review");
    try runtime.skillBindingState().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    );

    try std.testing.expectEqual(
        InsertResult.inserted,
        try runtime.insertionState().insertSliceBounded(alloc, " ", 4096, .preserve),
    );
    try std.testing.expectEqualStrings("$review ", runtime.edit_state.input.items);
    try std.testing.expect(!runtime.entities.skill_tokens.items[0].owns_trailing_separator);
    runtime.edit_state.cursor = 0;
    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings(" ", runtime.edit_state.input.items);
}

test "replacing a removed skill gap makes the new separator user owned" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "review");
    try runtime.skillBindingState().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    );

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .character_left,
        .clear,
    ));
    try runtime.insertionState().insertByte(alloc, ' ', .clear);
    try std.testing.expect(!runtime.entities.skill_tokens.items[0].owns_trailing_separator);
    runtime.edit_state.cursor = 0;
    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .character_right,
        .clear,
    ));
    try std.testing.expectEqualStrings(" ", runtime.edit_state.input.items);
}

test "typing a separator claims the file completion gap without duplication" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "@AGENTS.md ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    runtime.entities.markFileCompletionSeparator(
        runtime.edit_state.input.items,
        runtime.edit_state.cursor,
        runtime.edit_state.input.items.len - 1,
    );

    try std.testing.expectEqual(
        InsertResult.inserted,
        try runtime.insertionState().insertByteBounded(
            alloc,
            ' ',
            runtime.edit_state.input.items.len,
            .clear,
        ),
    );
    try std.testing.expectEqualStrings("@AGENTS.md ", runtime.edit_state.input.items);
    try runtime.insertionState().insertByte(alloc, '@', .clear);
    try std.testing.expectEqualStrings("@AGENTS.md @", runtime.edit_state.input.items);
}

test "unrelated file input clears the pending separator claim" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "@AGENTS.md ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    runtime.entities.markFileCompletionSeparator(
        runtime.edit_state.input.items,
        runtime.edit_state.cursor,
        runtime.edit_state.input.items.len - 1,
    );

    try runtime.insertionState().insertByte(alloc, 'x', .clear);
    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .character_left,
        .clear,
    ));
    try runtime.insertionState().insertByte(alloc, ' ', .clear);
    try std.testing.expectEqualStrings("@AGENTS.md  ", runtime.edit_state.input.items);
}

test "input escape parser handles ESC b as word_left" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, .word_left), consumeInputEscapeByte(&stage, &param, &param2, 'b'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ESC f as word_right" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, .word_right), consumeInputEscapeByte(&stage, &param, &param2, 'f'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles alt+arrow as word jump" {
    // ESC[1;3D — Alt+Left
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.word_left, false)), consumeInputEscapeByte(&stage, &param, &param2, 'D'));
    try std.testing.expectEqual(@as(u8, 0), stage);

    // ESC[1;3C — Alt+Right
    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.word_right, false)), consumeInputEscapeByte(&stage, &param, &param2, 'C'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles double-ESC as meta prefix for arrows" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    // ESC ESC [ A — Option+Up on terminals that send Meta as ESC prefix
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, 0x1b));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.paragraph_up, false)), consumeInputEscapeByte(&stage, &param, &param2, 'A'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles double-ESC meta prefix for down arrow" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, 0x1b));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.paragraph_down, false)), consumeInputEscapeByte(&stage, &param, &param2, 'B'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ESC 0x7f as delete_word_left" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_word_left), consumeInputEscapeByte(&stage, &param, &param2, 0x7f));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ESC 0x08 as delete_word_left" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_word_left), consumeInputEscapeByte(&stage, &param, &param2, 0x08));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles alt+delete as delete_word_right" {
    // ESC[3;3~ — Alt+Forward-Delete
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_word_right), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser still returns delete_next for plain CSI 3~" {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_next), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "deleteWordLeft removes preceding word from input" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "hello world foo");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("hello world ", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "hello world ".len), runtime.edit_state.cursor);

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("hello ", runtime.edit_state.input.items);

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);

    try std.testing.expect(!runtime.deletionState(null).delete(
        alloc,
        .word_left,
        .clear,
    ));
}

test "deleteWhitespaceDelimitedWordLeft kills a token and preserves history draft" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try primeComposerHistoryDraftForTest(&runtime, alloc, "draft");
    try runtime.textReplacementState().replace(alloc, "foo-bar  ");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    runtime.vertical_navigation.preferred_column = 7;

    try std.testing.expect(try runtime.killRingState(null).delete(
        alloc,
        .whitespace_word_left,
    ));
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("foo-bar  ", runtime.kill_ring.text.items);
    try std.testing.expectEqual(@as(?usize, 0), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("draft", runtime.composer_history.draftText().?);
    try std.testing.expectEqual(@as(?usize, null), runtime.vertical_navigation.preferredColumn());
    try std.testing.expectEqual(
        kill_ring.YankResult{ .inserted = 0 },
        try runtime.killRingState(null).yank(alloc, 1, 4096),
    );
    try std.testing.expectEqualStrings("foo-bar  ", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(?usize, 0), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("draft", runtime.composer_history.draftText().?);
}

test "bounded composer inserts and yank reject without changing owner state" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.textReplacementState().replace(alloc, "abcd");
    runtime.edit_state.cursor = 2;
    runtime.picker.file_completion_index = 3;
    runtime.picker.file_completion_window_start = 1;
    try runtime.kill_ring.text.appendSlice(alloc, "XY");

    try std.testing.expectEqual(
        InsertResult.limit_exceeded,
        try runtime.insertionState().insertByteBounded(alloc, '!', 4, .clear),
    );
    try std.testing.expectEqual(
        InsertResult.limit_exceeded,
        try runtime.insertionState().insertSliceBounded(alloc, "XY", 5, .preserve),
    );
    try std.testing.expectEqual(
        kill_ring.YankResult{ .limit_exceeded = 2 },
        try runtime.killRingState(null).yank(alloc, 1, 5),
    );
    try std.testing.expectEqualStrings("abcd", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 3), runtime.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 1), runtime.picker.file_completion_window_start);
    try std.testing.expectEqualStrings("XY", runtime.kill_ring.text.items);
}

test "bounded composer edits count registered paste backing text" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";

    var insertion = InputRuntime{};
    defer insertion.deinit(alloc);
    try insertion.edit_state.input.appendSlice(alloc, placeholder);
    try appendPastedBlockForTest(&insertion, alloc, 1, "expanded");
    insertion.edit_state.cursor = insertion.edit_state.input.items.len;

    try std.testing.expectEqual(
        @as(?usize, "expanded".len),
        insertion.insertionState().expandedInputLen(),
    );
    try std.testing.expectEqual(
        InsertResult.limit_exceeded,
        try insertion.insertionState().insertByteBounded(
            alloc,
            '!',
            "expanded".len,
            .clear,
        ),
    );
    try std.testing.expectEqualStrings(placeholder, insertion.edit_state.input.items);

    var replacement = InputRuntime{};
    defer replacement.deinit(alloc);
    try replacement.edit_state.input.appendSlice(alloc, placeholder);
    try appendPastedBlockForTest(&replacement, alloc, 1, "expanded");
    replacement.edit_state.cursor = replacement.edit_state.input.items.len;

    try std.testing.expectEqual(
        InsertResult.inserted,
        try replacement.replacementState(null).replaceRangeBounded(
            alloc,
            .{ .start = 0, .end = placeholder.len },
            "ok",
            "ok".len,
            "ok".len,
        ),
    );
    try std.testing.expectEqualStrings("ok", replacement.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), replacement.entities.pasted_blocks.items.len);
}

test "deleteWhitespaceDelimitedWordLeft clears vertical intent on a no-op" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.kill_ring.text.appendSlice(alloc, "existing kill");
    runtime.vertical_navigation.preferred_column = 7;

    try std.testing.expect(!try runtime.killRingState(null).delete(
        alloc,
        .whitespace_word_left,
    ));
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("existing kill", runtime.kill_ring.text.items);
    try std.testing.expectEqual(@as(?usize, null), runtime.vertical_navigation.preferredColumn());
}

test "deleteWordLeft preserves punctuation boundaries" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "foo-bar");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_left,
        .clear,
    ));
    try std.testing.expectEqualStrings("foo-", runtime.edit_state.input.items);
}

test "deleteWordRight removes the next word from input" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "hello world foo");
    runtime.edit_state.cursor = 0;

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("world foo", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), runtime.edit_state.cursor);

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("foo", runtime.edit_state.input.items);

    try std.testing.expect(runtime.deletionState(null).delete(
        alloc,
        .word_right,
        .clear,
    ));
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);

    try std.testing.expect(!runtime.deletionState(null).delete(
        alloc,
        .word_right,
        .clear,
    ));
}

test "input escape parser handles alt+backspace (kitty) as delete_word_left" {
    // ESC[127;3u — Kitty protocol for Alt+Backspace (keycode 127, modifier 3=alt+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '7'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_word_left), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles cmd+backspace as delete_to_line_start" {
    // ESC[127;9u — Kitty protocol for Cmd+Backspace (keycode 127, modifier 9=super+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '2'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '7'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_to_line_start), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles cmd+fn+delete as delete_to_line_end" {
    // ESC[3;9~ — CSI for Cmd+Forward-Delete (keycode 3, modifier 9=super+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .delete_to_line_end), consumeInputEscapeByte(&stage, &param, &param2, '~'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser remaps kitty ctrl+u and ctrl+k" {
    const cases = [_]struct {
        keycode: []const u8,
        expected: u8,
    }{
        .{ .keycode = "117", .expected = 21 },
        .{ .keycode = "107", .expected = 11 },
        .{ .keycode = "119", .expected = 23 },
    };

    for (cases) |case| {
        var stage: u8 = 1;
        var param: u16 = 0;
        var param2: u16 = 0;
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
        for (case.keycode) |byte| {
            try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, byte));
        }
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
        try std.testing.expectEqual(
            @as(?InputEscapeAction, .{ .remapped_byte = case.expected }),
            consumeInputEscapeByte(&stage, &param, &param2, 'u'),
        );
    }
}

fn appendPastedBlockForTest(runtime: *InputRuntime, alloc: Allocator, id: usize, text: []const u8) !void {
    const line_count = paste_blocks.countLines(text);
    var placeholder_buf: [128]u8 = undefined;
    const placeholder = try paste_blocks.formatPlaceholder(&placeholder_buf, id, line_count);
    const raw_start = std.mem.find(u8, runtime.edit_state.input.items, placeholder);
    const span = if (raw_start) |start|
        entity_spans.Span{ .raw_start = start, .raw_end = start + placeholder.len }
    else
        entity_spans.Span{ .raw_start = 0, .raw_end = 0 };
    try runtime.entities.pasted_blocks.ensureUnusedCapacity(alloc, 1);
    runtime.entities.registerPastedBlockAssumeCapacity(.{
        .id = id,
        .text = try alloc.dupe(u8, text),
        .line_count = line_count,
        .span = span,
    });
}

fn appendImageBlockForTest(runtime: *InputRuntime, blocks: *ImageBlocks, alloc: Allocator, id: usize) !void {
    try blocks.append(alloc, .{
        .id = id,
        .path = try std.fmt.allocPrint(alloc, "/tmp/{d}.png", .{id}),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    var placeholder_buf: [64]u8 = undefined;
    const placeholder = try std.fmt.bufPrint(&placeholder_buf, "[Image #{d}]", .{id});
    if (std.mem.find(u8, runtime.edit_state.input.items, placeholder)) |raw_start| {
        try runtime.entities.image_tokens.ensureUnusedCapacity(alloc, 1);
        runtime.entities.registerImageTokenAssumeCapacity(.{
            .id = id,
            .span = .{ .raw_start = raw_start, .raw_end = raw_start + placeholder.len },
        });
    }
}

fn appendCapturedImageBlockForTest(
    runtime: *InputRuntime,
    blocks: *ImageBlocks,
    alloc: Allocator,
    source_path: []const u8,
    snapshot_dir: []const u8,
    id: usize,
) !void {
    var attachment = try image_attachments.loadImageAttachment(alloc, source_path);
    var attachment_owned = true;
    errdefer if (attachment_owned) {
        image_attachments.discardImageAttachment(alloc, attachment);
    };
    attachment.id = id;
    try image_attachments.captureImageSnapshot(alloc, &attachment, snapshot_dir);
    try blocks.append(alloc, attachment);
    attachment_owned = false;

    var placeholder_buf: [64]u8 = undefined;
    const placeholder = try std.fmt.bufPrint(&placeholder_buf, "[Image #{d}]", .{id});
    if (std.mem.find(u8, runtime.edit_state.input.items, placeholder)) |raw_start| {
        try runtime.entities.image_tokens.ensureUnusedCapacity(alloc, 1);
        runtime.entities.registerImageTokenAssumeCapacity(.{
            .id = id,
            .span = .{ .raw_start = raw_start, .raw_end = raw_start + placeholder.len },
        });
    }
}

fn deinitImageBlocksForTest(blocks: *ImageBlocks, alloc: Allocator) void {
    for (blocks.items) |image| {
        image_attachments.discardImageAttachment(alloc, image);
    }
    blocks.deinit(alloc);
}

fn readTraceFileForTest(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

test "line kill and repeated yank preserve images and exact skill provenance" {
    const alloc = std.testing.allocator;
    const original_bytes = "\x89PNG\r\n\x1a\noriginal";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var source = try tmp.dir.createFile(std.testing.io, "source.png", .{});
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, original_bytes);
    }
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "source.png");
    defer alloc.free(source_path);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    const input = "pre[Image #8] $review post";
    try runtime.edit_state.input.appendSlice(alloc, input);
    try appendCapturedImageBlockForTest(
        &runtime,
        &images,
        alloc,
        source_path,
        snapshot_dir,
        8,
    );
    const ring_snapshot_path = try alloc.dupe(u8, images.items[0].snapshot_path.?);
    defer alloc.free(ring_snapshot_path);
    try tmp.dir.deleteFile(std.testing.io, "source.png");
    const skill_start = "pre[Image #8] ".len;
    try runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = skill_start,
        .raw_end = skill_start + "$review".len,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/tmp/workspace/review/SKILL.md"),
    });
    runtime.edit_state.cursor = input.len;

    try std.testing.expect(try runtime.killRingState(&images).delete(
        alloc,
        .line_start,
    ));
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
    try std.testing.expectEqualStrings(input, runtime.kill_ring.text.items);
    try std.testing.expectEqual(@as(usize, 1), runtime.kill_ring.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.kill_ring.skill_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), images.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.entities.skill_tokens.items.len);

    try std.testing.expectEqual(
        kill_ring.YankResult{ .inserted = 1 },
        try runtime.killRingState(&images).yank(alloc, 100, 4096),
    );
    try std.testing.expectEqualStrings(
        "pre[Image #100] $review post",
        runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqual(@as(usize, 100), images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqualStrings(
        "/tmp/workspace/review/SKILL.md",
        runtime.entities.skill_tokens.items[0].path,
    );
    try std.testing.expect(runtime.entities.isValidSkillToken(
        runtime.edit_state.input.items,
        runtime.entities.skill_tokens.items[0],
    ));

    try std.testing.expectEqual(
        kill_ring.YankResult{ .inserted = 1 },
        try runtime.killRingState(&images).yank(alloc, 101, 4096),
    );
    try std.testing.expectEqualStrings(
        "pre[Image #100] $review postpre[Image #101] $review post",
        runtime.edit_state.input.items,
    );
    try std.testing.expectEqual(@as(usize, 2), images.items.len);
    try std.testing.expectEqual(@as(usize, 100), images.items[0].id);
    try std.testing.expectEqual(@as(usize, 101), images.items[1].id);
    try std.testing.expectEqual(@as(usize, 2), runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 2), runtime.entities.skill_tokens.items.len);
    try std.testing.expect(!std.mem.eql(
        u8,
        images.items[0].snapshot_path.?,
        images.items[1].snapshot_path.?,
    ));
    for (images.items) |image| {
        var verified = try image_attachments.loadVerifiedSnapshot(alloc, image, .{});
        defer verified.deinit(alloc);
        try std.testing.expectEqualSlices(u8, original_bytes, verified.bytes);
    }
    for (runtime.entities.skill_tokens.items) |token| {
        try std.testing.expect(runtime.entities.isValidSkillToken(
            runtime.edit_state.input.items,
            token,
        ));
        try std.testing.expectEqualStrings(
            "/tmp/workspace/review/SKILL.md",
            token.path,
        );
    }

    runtime.kill_ring.deinit(alloc);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, ring_snapshot_path, .{}),
    );
    for (images.items) |image| {
        var verified = try image_attachments.loadVerifiedSnapshot(alloc, image, .{});
        defer verified.deinit(alloc);
        try std.testing.expectEqualSlices(u8, original_bytes, verified.bytes);
    }
}

fn checkStructuredKillYankAllocationFailure(
    failing: *std.testing.FailingAllocator,
) !void {
    const alloc = failing.allocator();
    const image_bytes = "\x89PNG\r\n\x1a\noriginal";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "snapshots", .default_dir);
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_bytes, &digest_bytes, .{});
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    var snapshot_name_buf: [96]u8 = undefined;
    const snapshot_name = try std.fmt.bufPrint(
        &snapshot_name_buf,
        "image-8-{s}.bin",
        .{digest_hex[0..16]},
    );
    var snapshot_relative_buf: [128]u8 = undefined;
    const snapshot_relative = try std.fmt.bufPrint(
        &snapshot_relative_buf,
        "snapshots/{s}",
        .{snapshot_name},
    );
    {
        var snapshot_file = try tmp.dir.createFile(
            std.testing.io,
            snapshot_relative,
            .{},
        );
        defer snapshot_file.close(std.testing.io);
        try snapshot_file.writeStreamingAll(std.testing.io, image_bytes);
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    const input = "[Image #8] $review";
    try runtime.edit_state.input.appendSlice(alloc, input);

    const image_path = try alloc.dupe(u8, "/tmp/8.png");
    var image_path_owned = true;
    errdefer if (image_path_owned) alloc.free(image_path);
    const media_type = try alloc.dupe(u8, "image/png");
    var media_type_owned = true;
    errdefer if (media_type_owned) alloc.free(media_type);
    const snapshot_path = try std.fs.path.join(
        alloc,
        &.{ root, "snapshots", snapshot_name },
    );
    var snapshot_path_owned = true;
    errdefer if (snapshot_path_owned) alloc.free(snapshot_path);
    const snapshot_sha256 = try alloc.dupe(u8, &digest_hex);
    var snapshot_sha256_owned = true;
    errdefer if (snapshot_sha256_owned) alloc.free(snapshot_sha256);
    const attachment = types.ImageAttachment{
        .id = 8,
        .path = image_path,
        .media_type = media_type,
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = snapshot_sha256,
    };
    var attachment_owned = true;
    errdefer if (attachment_owned) {
        image_attachments.discardImageAttachment(alloc, attachment);
    };
    image_path_owned = false;
    media_type_owned = false;
    snapshot_path_owned = false;
    snapshot_sha256_owned = false;
    try images.append(alloc, attachment);
    attachment_owned = false;
    try runtime.entities.image_tokens.append(alloc, .{
        .id = 8,
        .span = .{ .raw_start = 0, .raw_end = "[Image #8]".len },
    });

    const skill_name = try alloc.dupe(u8, "review");
    var skill_name_owned = true;
    errdefer if (skill_name_owned) alloc.free(skill_name);
    const skill_path = try alloc.dupe(u8, "/tmp/review/SKILL.md");
    var skill_path_owned = true;
    errdefer if (skill_path_owned) alloc.free(skill_path);
    try runtime.entities.skill_tokens.append(alloc, .{
        .raw_start = "[Image #8] ".len,
        .raw_end = input.len,
        .name = skill_name,
        .path = skill_path,
    });
    skill_name_owned = false;
    skill_path_owned = false;
    try runtime.kill_ring.text.appendSlice(alloc, "previous kill");
    runtime.edit_state.cursor = input.len;

    const killed = runtime.killRingState(&images).delete(alloc, .line_start) catch |err| {
        try std.testing.expectEqualStrings(input, runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), images.items.len);
        try std.Io.Dir.accessAbsolute(
            std.testing.io,
            images.items[0].snapshot_path.?,
            .{},
        );
        try std.testing.expectEqual(@as(usize, 1), runtime.entities.skill_tokens.items.len);
        try std.testing.expectEqualStrings(
            "previous kill",
            runtime.kill_ring.text.items,
        );
        return err;
    };
    try std.testing.expect(killed);
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), images.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.entities.skill_tokens.items.len);

    _ = runtime.killRingState(&images).yank(alloc, 100, 4096) catch |err| {
        try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), images.items.len);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.image_tokens.items.len);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.skill_tokens.items.len);
        try std.testing.expectEqualStrings(input, runtime.kill_ring.text.items);
        try std.testing.expectEqual(@as(usize, 1), runtime.kill_ring.images.items.len);
        try std.Io.Dir.accessAbsolute(
            std.testing.io,
            runtime.kill_ring.images.items[0].snapshot_path.?,
            .{},
        );
        try std.testing.expectEqual(@as(usize, 1), runtime.kill_ring.skill_tokens.items.len);
        return err;
    };
    try std.testing.expectEqualStrings("[Image #100] $review", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.skill_tokens.items.len);
}

test "structured kill and yank stay atomic across allocation failures" {
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try checkStructuredKillYankAllocationFailure(&probe);
    const allocation_count = probe.alloc_index;
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        checkStructuredKillYankAllocationFailure(&failing) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "deleteToLineStart removes only the current logical line prefix" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.insertionState().insertSlice(
        std.testing.allocator,
        "alpha\nleftMIDright\ngamma",
        .preserve,
    );
    runtime.edit_state.cursor = "alpha\nleftMID".len;

    try std.testing.expect(try runtime.killRingState(null).delete(
        std.testing.allocator,
        .line_start,
    ));
    try std.testing.expectEqualStrings("alpha\nright\ngamma", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "alpha\n".len), runtime.edit_state.cursor);
    try std.testing.expectEqualStrings("leftMID", runtime.kill_ring.text.items);
}

test "deleteToLineEnd removes only the current logical line suffix" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.insertionState().insertSlice(
        std.testing.allocator,
        "alpha\nleftMIDright\ngamma",
        .preserve,
    );
    runtime.edit_state.cursor = "alpha\nleftMID".len;

    try std.testing.expect(try runtime.killRingState(null).delete(
        std.testing.allocator,
        .line_end,
    ));
    try std.testing.expectEqualStrings("alpha\nleftMID\ngamma", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "alpha\nleftMID".len), runtime.edit_state.cursor);
    try std.testing.expectEqualStrings("right", runtime.kill_ring.text.items);
}

test "line deletion boundary no-ops preserve the kill ring" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.insertionState().insertSlice(std.testing.allocator, "alpha\nbeta", .preserve);
    try runtime.kill_ring.text.appendSlice(std.testing.allocator, "existing kill");

    runtime.edit_state.cursor = "alpha\n".len;
    try std.testing.expect(!try runtime.killRingState(null).delete(
        std.testing.allocator,
        .line_start,
    ));
    try std.testing.expectEqualStrings("existing kill", runtime.kill_ring.text.items);

    runtime.edit_state.cursor = runtime.edit_state.input.items.len;
    try std.testing.expect(!try runtime.killRingState(null).delete(
        std.testing.allocator,
        .line_end,
    ));
    try std.testing.expectEqualStrings("existing kill", runtime.kill_ring.text.items);
}

test "deleteToLineEnd at non-final eol joins the next logical line" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.insertionState().insertSlice(
        std.testing.allocator,
        "alpha\nbeta\ngamma",
        .preserve,
    );
    runtime.edit_state.cursor = "alpha\nbeta".len;

    try std.testing.expect(try runtime.killRingState(null).delete(
        std.testing.allocator,
        .line_end,
    ));
    try std.testing.expectEqualStrings("alpha\nbetagamma", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "alpha\nbeta".len), runtime.edit_state.cursor);
    try std.testing.expectEqualStrings("\n", runtime.kill_ring.text.items);
}

test "line deletion preserves newline ownership and utf8 outside the range" {
    const alloc = std.testing.allocator;

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "alpha\nbeta\ngamma");
        runtime.edit_state.cursor = "alpha\nbeta".len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expectEqualStrings("alpha\n\ngamma", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, "alpha\n".len), runtime.edit_state.cursor);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "alpha\nbeta\ngamma");
        runtime.edit_state.cursor = "alpha\n".len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_end));
        try std.testing.expectEqualStrings("alpha\n\ngamma", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, "alpha\n".len), runtime.edit_state.cursor);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "écho\nnaïve😀\n尾");
        runtime.edit_state.cursor = "écho\nnaïve".len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expectEqualStrings("écho\n😀\n尾", runtime.edit_state.input.items);
    }
}

test "line deletion no-op preserves input state and metadata" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    try primeComposerHistoryDraftForTest(&runtime, alloc, "draft");
    try runtime.textReplacementState().replace(alloc, "alpha\n[Pasted text #7, 1 line]\n[Image #8]");
    runtime.edit_state.cursor = "alpha\n".len;
    try runtime.kill_ring.text.appendSlice(alloc, "existing kill");
    try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
    try appendImageBlockForTest(&runtime, &images, alloc, 8);
    try runtime.picker.beginModelPickerFlow(alloc, "openai/gpt-5", 3, true, .effort);
    runtime.picker.slash_completion_index = 4;
    runtime.picker.model_completion_index = 5;
    runtime.picker.file_completion_index = 6;
    try std.testing.expect(!try runtime.killRingState(&images).delete(alloc, .line_start));
    try std.testing.expectEqualStrings("alpha\n[Pasted text #7, 1 line]\n[Image #8]", runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("existing kill", runtime.kill_ring.text.items);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqual(picker_state.ModelPickerStage.effort, runtime.picker.model_picker_stage);
    try std.testing.expectEqualStrings("openai/gpt-5", runtime.picker.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 4), runtime.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 5), runtime.picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 6), runtime.picker.file_completion_index);
    try std.testing.expectEqual(@as(?usize, 0), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("draft", runtime.composer_history.draftText().?);
}

test "line deletion no-ops on empty logical lines and clamps an oversized cursor" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        input: []const u8,
        cursor: usize,
    }{
        .{ .input = "", .cursor = 0 },
        .{ .input = "alpha\n", .cursor = "alpha\n".len },
    };

    for (cases) |case| {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, case.input);
        try runtime.kill_ring.text.appendSlice(alloc, "existing kill");
        runtime.edit_state.cursor = case.cursor;
        try std.testing.expect(!try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expect(!try runtime.killRingState(null).delete(alloc, .line_end));
        try std.testing.expectEqualStrings(case.input, runtime.edit_state.input.items);
        try std.testing.expectEqualStrings("existing kill", runtime.kill_ring.text.items);
    }

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    try runtime.edit_state.input.appendSlice(alloc, "alpha");
    runtime.edit_state.cursor = 99;
    try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), runtime.edit_state.cursor);
}

test "successful line deletion resets picker state and preserves history draft" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try primeComposerHistoryDraftForTest(&runtime, alloc, "draft");
    try runtime.textReplacementState().replace(alloc, "alpha\nleftMIDright\ngamma");
    runtime.edit_state.cursor = "alpha\nleftMID".len;
    try runtime.picker.beginModelPickerFlow(alloc, "openai/gpt-5", 3, true, .fast);
    runtime.picker.file_completion_index = 6;
    try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    try std.testing.expectEqual(picker_state.ModelPickerStage.model, runtime.picker.model_picker_stage);
    try std.testing.expect(!runtime.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(@as(usize, 0), runtime.picker.file_completion_index);
    try std.testing.expectEqual(@as(?usize, 0), runtime.composer_history.activeIndex());
    try std.testing.expectEqualStrings("draft", runtime.composer_history.draftText().?);
}

test "registered placeholders expand line deletion atomically and drop matching metadata" {
    const alloc = std.testing.allocator;

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "alpha\npre[Pasted text #7, 1 line]post\ngamma");
        try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
        runtime.edit_state.cursor = "alpha\npre[Pasted text #7".len;

        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expectEqualStrings("alpha\npost\ngamma", runtime.edit_state.input.items);
        try std.testing.expectEqualStrings("prepasted", runtime.kill_ring.text.items);
        try std.testing.expectEqual(@as(usize, 0), runtime.entities.pasted_blocks.items.len);
        try std.testing.expectEqual(
            kill_ring.YankResult{ .inserted = 0 },
            try runtime.killRingState(null).yank(alloc, 1, 4096),
        );
        try std.testing.expectEqualStrings("alpha\nprepastedpost\ngamma", runtime.edit_state.input.items);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        var images: ImageBlocks = .empty;
        defer deinitImageBlocksForTest(&images, alloc);
        try runtime.edit_state.input.appendSlice(alloc, "alpha\npre[Image #8]post\ngamma");
        try appendImageBlockForTest(&runtime, &images, alloc, 8);
        runtime.edit_state.cursor = "alpha\npre[Image".len;

        try std.testing.expect(try runtime.killRingState(&images).delete(alloc, .line_end));
        try std.testing.expectEqualStrings("alpha\npre\ngamma", runtime.edit_state.input.items);
        try std.testing.expectEqualStrings("[Image #8]post", runtime.kill_ring.text.items);
        try std.testing.expectEqual(@as(usize, 0), images.items.len);
    }
}

test "same-id surviving placeholder preserves backing metadata" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "[Pasted text #7, 1 line]\n[Pasted text #7, 1 line]");
    try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
    runtime.entities.pasted_blocks.items[0].span = .{
        .raw_start = "[Pasted text #7, 1 line]\n".len,
        .raw_end = "[Pasted text #7, 1 line]\n[Pasted text #7, 1 line]".len,
    };
    runtime.edit_state.cursor = "[Pasted text #7, 1 line]".len;

    try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    try std.testing.expectEqualStrings("\n[Pasted text #7, 1 line]", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
}

test "unregistered and truncated placeholder lookalikes remain ordinary text" {
    const alloc = std.testing.allocator;

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "pre[Pasted text #99, 1 line]post");
        runtime.edit_state.cursor = "pre[Pasted text #99".len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expectEqualStrings(", 1 line]post", runtime.edit_state.input.items);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "pre[Pasted text #7, 2 lin");
        try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
        runtime.edit_state.cursor = runtime.edit_state.input.items.len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expectEqualStrings("", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
    }
}

test "image lookalikes and truncated tokens remain ordinary text" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    try runtime.edit_state.input.appendSlice(alloc, "pre[Image #99]post\npre[Image #7\npre[Image #999999999999999999999999999999999999999999]post");
    try appendImageBlockForTest(&runtime, &images, alloc, 7);
    runtime.edit_state.cursor = "pre[Image #99".len;
    try std.testing.expect(try runtime.killRingState(&images).delete(alloc, .line_start));
    try std.testing.expectEqualStrings("]post\npre[Image #7\npre[Image #999999999999999999999999999999999999999999]post", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), images.items.len);

    runtime.edit_state.cursor = "]post\npre[Image #7".len;
    try std.testing.expect(try runtime.killRingState(&images).delete(alloc, .line_start));
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
}

test "placeholder boundary touching does not expand the deletion range" {
    const alloc = std.testing.allocator;

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        const token = "[Pasted text #7, 1 line]";
        try runtime.edit_state.input.appendSlice(alloc, "pre" ++ token ++ "post");
        try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
        runtime.edit_state.cursor = "pre".len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
        try std.testing.expectEqualStrings(token ++ "post", runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        const token = "[Pasted text #7, 1 line]";
        try runtime.edit_state.input.appendSlice(alloc, "pre" ++ token ++ "post");
        try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
        runtime.edit_state.cursor = ("pre" ++ token).len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_end));
        try std.testing.expectEqualStrings("pre" ++ token, runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
    }
}

test "same-id surviving image placeholder preserves backing metadata" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    try runtime.edit_state.input.appendSlice(alloc, "[Image #7]\n[Image #7]");
    try appendImageBlockForTest(&runtime, &images, alloc, 7);
    runtime.entities.image_tokens.items[0].span = .{
        .raw_start = "[Image #7]\n".len,
        .raw_end = "[Image #7]\n[Image #7]".len,
    };
    runtime.edit_state.cursor = "[Image #7]".len;

    try std.testing.expect(try runtime.killRingState(&images).delete(alloc, .line_start));
    try std.testing.expectEqualStrings("\n[Image #7]", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
}

test "registered pasted placeholder crossing a newline makes line deletion a no-op" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "pre[Pasted text #7,\n1 line]post");
    try runtime.entities.pasted_blocks.append(alloc, .{
        .id = 7,
        .text = try alloc.dupe(u8, "pasted"),
        .line_count = 1,
        .span = .{
            .raw_start = "pre".len,
            .raw_end = "pre[Pasted text #7,\n1 line]".len,
        },
    });
    try runtime.kill_ring.text.appendSlice(alloc, "existing kill");
    runtime.edit_state.cursor = "pre".len;

    try std.testing.expect(!try runtime.killRingState(null).delete(alloc, .line_end));
    try std.testing.expectEqualStrings("pre[Pasted text #7,\n1 line]post", runtime.edit_state.input.items);
    try std.testing.expectEqualStrings("existing kill", runtime.kill_ring.text.items);
    try std.testing.expectEqual(@as(usize, 1), runtime.entities.pasted_blocks.items.len);
}

test "ordinary line deletion does not scan or remove orphan backing records" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "alpha\nleftMIDright\ngamma");
    runtime.edit_state.cursor = "alpha\nleftMID".len;
    for (0..1024) |id| try appendPastedBlockForTest(&runtime, alloc, id + 1, "x");

    try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    try std.testing.expectEqual(@as(usize, 1024), runtime.entities.pasted_blocks.items.len);
}

test "line deletion removes one same-id backing and preserves unrelated image records" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);

    try runtime.edit_state.input.appendSlice(alloc, "[Pasted text #7, 1 line][Pasted text #7, 1 line][Image #9]");
    try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
    for (0..1024) |id| try appendImageBlockForTest(&runtime, &images, alloc, id + 100);
    try appendImageBlockForTest(&runtime, &images, alloc, 9);
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(try runtime.killRingState(&images).delete(alloc, .line_start));
    try std.testing.expectEqual(@as(usize, 0), runtime.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1024), images.items.len);
    for (images.items) |image| {
        try std.testing.expect(image.id != 9);
    }
}

test "known-id pasted scans reject dense different-id prefixes" {
    const alloc = std.testing.allocator;
    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);

    try runtime.edit_state.input.appendSlice(alloc, "[Pasted text #7, 1 line]");
    for (0..128) |suffix| {
        var buf: [96]u8 = undefined;
        const lookalike = try std.fmt.bufPrint(&buf, "[Pasted text #7{d}, nested ", .{suffix});
        try runtime.edit_state.input.appendSlice(alloc, lookalike);
    }
    try runtime.edit_state.input.append(alloc, ']');
    try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    try std.testing.expectEqual(@as(usize, 0), runtime.entities.pasted_blocks.items.len);
}

test "atomic line deletion trace logs dropped backing without sensitive contents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "line-delete-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var runtime = InputRuntime{};
    defer runtime.deinit(alloc);
    var images: ImageBlocks = .empty;
    defer deinitImageBlocksForTest(&images, alloc);
    try runtime.edit_state.input.appendSlice(alloc, "[Pasted text #7, 1 line][Image #8]");
    try appendPastedBlockForTest(&runtime, alloc, 7, "secret pasted content");
    try appendImageBlockForTest(&runtime, &images, alloc, 8);
    runtime.edit_state.cursor = runtime.edit_state.input.items.len;

    try std.testing.expect(try runtime.killRingState(&images).delete(alloc, .line_start));
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "placeholder backing dropped kind=paste id=7 backing_bytes=21 reason=atomic_line_delete") != null);
    try std.testing.expect(std.mem.find(u8, trace, "placeholder backing dropped kind=image id=8 reason=atomic_line_delete") != null);
    try std.testing.expect(std.mem.find(u8, trace, "secret pasted content") == null);
    try std.testing.expect(std.mem.find(u8, trace, "/tmp/8.png") == null);
    try std.testing.expect(std.mem.find(u8, trace, "image/png") == null);
}

test "atomic line deletion trace logs a same-id backing once and skips survivors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "line-delete-dedup-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "[Pasted text #7, 1 line][Pasted text #7, 1 line]");
        try appendPastedBlockForTest(&runtime, alloc, 7, "pasted");
        runtime.edit_state.cursor = runtime.edit_state.input.items.len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    }

    {
        var runtime = InputRuntime{};
        defer runtime.deinit(alloc);
        try runtime.edit_state.input.appendSlice(alloc, "[Pasted text #8, 1 line]\n[Pasted text #8, 1 line]");
        try appendPastedBlockForTest(&runtime, alloc, 8, "pasted");
        runtime.entities.pasted_blocks.items[0].span = .{
            .raw_start = "[Pasted text #8, 1 line]\n".len,
            .raw_end = "[Pasted text #8, 1 line]\n[Pasted text #8, 1 line]".len,
        };
        runtime.edit_state.cursor = "[Pasted text #8, 1 line]".len;
        try std.testing.expect(try runtime.killRingState(null).delete(alloc, .line_start));
    }

    debug_trace.shutdown();
    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "placeholder backing dropped kind=paste id=7"));
    try std.testing.expect(std.mem.find(u8, trace, "placeholder backing dropped kind=paste id=8") == null);
}

test "input escape parser preserves existing tilde-terminated function keys" {
    const cases = [_]struct { code: []const u8, action: InputEscapeAction }{
        .{ .code = "1", .action = .home },
        .{ .code = "3", .action = .delete_next },
        .{ .code = "4", .action = .end },
        .{ .code = "7", .action = .home },
        .{ .code = "8", .action = .end },
    };

    for (cases) |case| {
        var stage: u8 = 1;
        var param: u16 = 0;
        var param2: u16 = 0;
        try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
        for (case.code) |b| {
            try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, b));
        }
        try std.testing.expectEqual(@as(?InputEscapeAction, case.action), consumeInputEscapeByte(&stage, &param, &param2, '~'));
        try std.testing.expectEqual(@as(u8, 0), stage);
    }
}

test "composer insertion inserts at cursor and advances" {
    var runtime = InputRuntime{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.insertionState().insertSlice(std.testing.allocator, "abc", .preserve);
    try std.testing.expectEqualStrings("abc", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 3), runtime.edit_state.cursor);

    runtime.edit_state.cursor = 2;
    try runtime.insertionState().insertSlice(std.testing.allocator, "xy", .preserve);
    try std.testing.expectEqualStrings("abxyc", runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 4), runtime.edit_state.cursor);
}

test "input escape parser handles cmd+arrow as home/end" {
    // ESC[1;9D — Cmd+Left (modifier 9=super+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.line_start, false)), consumeInputEscapeByte(&stage, &param, &param2, 'D'));
    try std.testing.expectEqual(@as(u8, 0), stage);

    // ESC[1;9C — Cmd+Right
    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.line_end, false)), consumeInputEscapeByte(&stage, &param, &param2, 'C'));
    try std.testing.expectEqual(@as(u8, 0), stage);

    // ESC[1;9A — Cmd+Up
    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.draft_start, false)), consumeInputEscapeByte(&stage, &param, &param2, 'A'));
    try std.testing.expectEqual(@as(u8, 0), stage);

    // ESC[1;9B — Cmd+Down
    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.draft_end, false)), consumeInputEscapeByte(&stage, &param, &param2, 'B'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ctrl+enter as steering submit" {
    // ESC[13;5u is Kitty's Ctrl+Enter encoding.
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '3'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .steer_submit), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles cmd+r as all-session resume picker" {
    // ESC[114;9u - Kitty protocol for Cmd+R (keycode 'r'=114, modifier 9=super+1)
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '4'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, .open_all_sessions), consumeInputEscapeByte(&stage, &param, &param2, 'u'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ctrl+a/ctrl+e via kitty protocol" {
    // ESC[97;5u is Kitty's Ctrl+A encoding.
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '7'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    const ctrl_a = consumeInputEscapeByte(&stage, &param, &param2, 'u');
    try std.testing.expectEqual(@as(?InputEscapeAction, .{ .remapped_byte = 1 }), ctrl_a);
    try std.testing.expectEqual(@as(u8, 0), stage);

    // ESC[101;5u is Kitty's Ctrl+E encoding.
    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '0'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    const ctrl_e = consumeInputEscapeByte(&stage, &param, &param2, 'u');
    try std.testing.expectEqual(@as(?InputEscapeAction, .{ .remapped_byte = 5 }), ctrl_e);
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "input escape parser handles ctrl+arrow as word jump" {
    // ESC[1;5D — Ctrl+Left
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.word_left, false)), consumeInputEscapeByte(&stage, &param, &param2, 'D'));
    try std.testing.expectEqual(@as(u8, 0), stage);

    // ESC[1;5C — Ctrl+Right
    stage = 1;
    param = 0;
    param2 = 0;
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '1'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?InputEscapeAction, null), consumeInputEscapeByte(&stage, &param, &param2, '5'));
    try std.testing.expectEqual(@as(?InputEscapeAction, moveEscape(.word_right, false)), consumeInputEscapeByte(&stage, &param, &param2, 'C'));
    try std.testing.expectEqual(@as(u8, 0), stage);
}

test "resetEscapeDecoder zeroes only terminal decoder state" {
    var input: InputRuntime = .{};
    input.gestures = gesture_state.pressCtrlCExit(input.gestures, 123).next;
    input.gestures = gesture_state.pressEscapeClear(input.gestures, 456).next;

    var terminal: Runtime = .{};
    terminal.terminal_action_decoder.stage = 2;
    terminal.terminal_action_decoder.param = 200;
    terminal.terminal_action_decoder.param2 = 1;
    terminal.terminal_action_decoder.started_ms = 99;
    terminal.terminal_action_decoder.cancel_pending = true;
    try std.testing.expect(terminal.hasPendingTerminalInput());
    terminal.resetEscapeDecoder();
    try std.testing.expectEqual(@as(u8, 0), terminal.terminal_action_decoder.stage);
    try std.testing.expectEqual(@as(u16, 0), terminal.terminal_action_decoder.param);
    try std.testing.expectEqual(@as(u16, 0), terminal.terminal_action_decoder.param2);
    try std.testing.expectEqual(@as(i64, 0), terminal.terminal_action_decoder.started_ms);
    try std.testing.expect(!terminal.terminal_action_decoder.cancel_pending);
    try std.testing.expect(!terminal.hasPendingTerminalInput());
    try std.testing.expect(input.gestures.ctrlCExitArmed());
    try std.testing.expect(input.gestures.escapeClearArmed());
}

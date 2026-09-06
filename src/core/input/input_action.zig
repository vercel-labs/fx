const std = @import("std");
const question_prompt = @import("../agent/question_prompt.zig");
const approval_decision = @import("../permissions/approval_decision.zig");

/// Describes a mouse-wheel direction after terminal input has been decoded by UI.
pub const MouseWheel = enum {
    up,
    down,
};

pub const MousePointerKind = enum {
    press,
    drag,
    release,
};

pub const MousePointer = struct {
    kind: MousePointerKind,
    column: u16,
    row: u16,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const MoveKind = enum {
    character_left,
    character_right,
    word_left,
    word_right,
    line_start,
    line_end,
    draft_start,
    draft_end,
    paragraph_up,
    paragraph_down,
    visual_up,
    visual_down,
    page_up,
    page_down,
};

pub const MoveIntent = struct {
    kind: MoveKind,
    extend_selection: bool = false,
};

/// Layout-independent edit intent after UI translates a control sequence.
pub const ShortcutAction = union(enum) {
    move: MoveIntent,
    select_all,
    copy_selection,
    cut_selection,
    undo,
    redo,
    history_previous,
    history_next,
    delete_backward,
    delete_forward,
    delete_word_left,
    delete_whitespace_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
    yank,
    redraw,
    insert_newline,
};

/// Typed result of UI-owned terminal escape decoding.
pub const Action = union(enum) {
    history_up,
    history_down,
    cursor_up,
    cursor_down,
    cursor_left,
    cursor_right,
    word_left,
    word_right,
    home,
    end,
    page_up,
    page_down,
    mouse_wheel: MouseWheel,
    mouse_pointer: MousePointer,
    delete_next,
    delete_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
    clear_line,
    toggle_full_transcript,
    toggle_permission_mode,
    open_all_sessions,
    insert_newline,
    paste_start,
    paste_end,
    composer_shortcut: ShortcutAction,
    remapped_byte: u8,
    escape,
    ignore,
};

/// Raw terminal input after UI has attached its layout-independent composer
/// fallback. Core still routes the byte through higher-priority product
/// surfaces before using the fallback.
pub const RawTerminalInput = struct {
    byte: u8,
    composer_shortcut: ?ShortcutAction = null,
    approval_action: ?approval_decision.Action = null,
    question_action: ?question_prompt.Action = null,
};

/// A decoded terminal action plus the state captured when its leading Escape
/// byte arrived. Core uses that state to preserve cancellation semantics.
pub const DecodedTerminalAction = struct {
    action: Action,
    composer_shortcut: ?ShortcutAction = null,
    approval_focused_edit: ?approval_decision.DraftAction = null,
    question_action: ?question_prompt.Action = null,
    cancel_pending: bool = false,
};

/// The typed UI-to-Core terminal input boundary.
pub const TerminalInputEvent = union(enum) {
    paste_byte: u8,
    raw: RawTerminalInput,
    action: DecodedTerminalAction,
};

/// Core-owned facts sampled before UI advances its terminal decoder.
pub const TerminalDecodeContext = struct {
    now_ms: i64,
    paste_active: bool,
    cancel_pending: bool,
    question_freeform_selected: bool = false,
};

/// One terminal byte produces at most one event. When a decoded action must be
/// followed by the current byte, replay waits until Core routes that action so
/// admission and cancellation context are captured at the original boundary.
pub const TerminalInputIngress = struct {
    event: ?TerminalInputEvent = null,
    interrupts_pending_text: bool = false,
    replay_byte_after_routing: ?u8 = null,

    pub fn setEvent(self: *TerminalInputIngress, event: TerminalInputEvent) void {
        std.debug.assert(self.event == null);
        self.event = event;
    }

    pub fn has_routing_work(self: TerminalInputIngress) bool {
        return self.event != null or
            self.interrupts_pending_text or
            self.replay_byte_after_routing != null;
    }
};

test "TerminalInputIngress reports only effectful routing work" {
    try std.testing.expect(!(TerminalInputIngress{}).has_routing_work());
    try std.testing.expect((TerminalInputIngress{
        .event = .{ .paste_byte = 'x' },
    }).has_routing_work());
    try std.testing.expect((TerminalInputIngress{
        .interrupts_pending_text = true,
    }).has_routing_work());
    try std.testing.expect((TerminalInputIngress{
        .replay_byte_after_routing = 0x1b,
    }).has_routing_work());
}

const std = @import("std");

pub const ctrl_c_exit_window_ms: i64 = 3000;
pub const escape_clear_window_ms: i64 = 500;

pub const EscapeIntent = enum { clear_draft, open_rewind };

pub const State = struct {
    ctrl_c_exit_armed_ms: ?i64 = null,
    escape_clear_armed_ms: ?i64 = null,
    escape_intent: ?EscapeIntent = null,

    pub fn ctrlCExitArmed(self: State) bool {
        return self.ctrl_c_exit_armed_ms != null;
    }

    pub fn ctrlCExitArmedAt(self: State) ?i64 {
        return self.ctrl_c_exit_armed_ms;
    }

    pub fn escapeClearArmed(self: State) bool {
        return self.escape_clear_armed_ms != null and self.escape_intent == .clear_draft;
    }

    pub fn escapeRewindArmed(self: State) bool {
        return self.escape_clear_armed_ms != null and self.escape_intent == .open_rewind;
    }

    pub fn escapeClearArmedAt(self: State) ?i64 {
        return self.escape_clear_armed_ms;
    }
};

pub const PressResult = enum {
    armed,
    activated,
};

pub const PressTransition = struct {
    next: State,
    result: PressResult,
};

pub const ClearTransition = struct {
    next: State,
    cleared: bool,
};

pub const ResetTransition = struct {
    next: State,
    cleared_ctrl_c_exit: bool,
    cleared_escape_clear: bool,

    pub fn clearedAny(self: ResetTransition) bool {
        return self.cleared_ctrl_c_exit or self.cleared_escape_clear;
    }
};

pub fn pressCtrlCExit(current: State, now_ms: i64) PressTransition {
    if (current.ctrl_c_exit_armed_ms) |armed_ms| {
        if (now_ms - armed_ms < ctrl_c_exit_window_ms) {
            return .{ .next = current, .result = .activated };
        }
    }

    var next = current;
    next.ctrl_c_exit_armed_ms = now_ms;
    return .{ .next = next, .result = .armed };
}

fn pressEscape(current: State, now_ms: i64, intent: EscapeIntent) PressTransition {
    if (current.escape_clear_armed_ms) |armed_ms| {
        if (current.escape_intent == intent and now_ms - armed_ms <= escape_clear_window_ms) {
            var next = current;
            next.escape_clear_armed_ms = null;
            next.escape_intent = null;
            return .{ .next = next, .result = .activated };
        }
    }

    var next = current;
    next.escape_clear_armed_ms = now_ms;
    next.escape_intent = intent;
    return .{ .next = next, .result = .armed };
}

pub fn pressEscapeClear(current: State, now_ms: i64) PressTransition {
    return pressEscape(current, now_ms, .clear_draft);
}

pub fn pressEscapeRewind(current: State, now_ms: i64) PressTransition {
    return pressEscape(current, now_ms, .open_rewind);
}

pub fn disarmCtrlCExit(current: State) ClearTransition {
    var next = current;
    next.ctrl_c_exit_armed_ms = null;
    return .{ .next = next, .cleared = current.ctrl_c_exit_armed_ms != null };
}

pub fn disarmEscapeClear(current: State) ClearTransition {
    var next = current;
    next.escape_clear_armed_ms = null;
    next.escape_intent = null;
    return .{ .next = next, .cleared = current.escape_clear_armed_ms != null };
}

pub fn expireCtrlCExit(current: State, now_ms: i64) ClearTransition {
    const armed_ms = current.ctrl_c_exit_armed_ms orelse return .{
        .next = current,
        .cleared = false,
    };
    if (now_ms - armed_ms < ctrl_c_exit_window_ms) {
        return .{ .next = current, .cleared = false };
    }
    return disarmCtrlCExit(current);
}

pub fn expireEscapeClear(current: State, now_ms: i64) ClearTransition {
    const armed_ms = current.escape_clear_armed_ms orelse return .{
        .next = current,
        .cleared = false,
    };
    if (now_ms - armed_ms <= escape_clear_window_ms) {
        return .{ .next = current, .cleared = false };
    }
    return disarmEscapeClear(current);
}

pub fn reset(current: State) ResetTransition {
    return .{
        .next = .{},
        .cleared_ctrl_c_exit = current.ctrl_c_exit_armed_ms != null,
        .cleared_escape_clear = current.escape_clear_armed_ms != null,
    };
}

test "Ctrl-C exit activates only strictly inside its window" {
    const armed = pressCtrlCExit(.{}, 100);
    try std.testing.expectEqual(PressResult.armed, armed.result);
    try std.testing.expectEqual(@as(?i64, 100), armed.next.ctrlCExitArmedAt());

    const activated = pressCtrlCExit(armed.next, 100 + ctrl_c_exit_window_ms - 1);
    try std.testing.expectEqual(PressResult.activated, activated.result);
    try std.testing.expectEqual(armed.next, activated.next);

    const rearmed = pressCtrlCExit(armed.next, 100 + ctrl_c_exit_window_ms);
    try std.testing.expectEqual(PressResult.armed, rearmed.result);
    try std.testing.expectEqual(
        @as(?i64, 100 + ctrl_c_exit_window_ms),
        rearmed.next.ctrlCExitArmedAt(),
    );
}

test "Escape clear activates through its inclusive window" {
    const armed = pressEscapeClear(.{}, 200);
    try std.testing.expectEqual(PressResult.armed, armed.result);
    try std.testing.expectEqual(@as(?i64, 200), armed.next.escapeClearArmedAt());

    const activated = pressEscapeClear(armed.next, 200 + escape_clear_window_ms);
    try std.testing.expectEqual(PressResult.activated, activated.result);
    try std.testing.expect(!activated.next.escapeClearArmed());

    const rearmed = pressEscapeClear(armed.next, 201 + escape_clear_window_ms);
    try std.testing.expectEqual(PressResult.armed, rearmed.result);
    try std.testing.expectEqual(
        @as(?i64, 201 + escape_clear_window_ms),
        rearmed.next.escapeClearArmedAt(),
    );
}

test "Escape intent changes rearm instead of activating" {
    const clear = pressEscapeClear(.{}, 100);
    try std.testing.expectEqual(PressResult.armed, clear.result);
    try std.testing.expect(clear.next.escapeClearArmed());

    const rewind = pressEscapeRewind(clear.next, 101);
    try std.testing.expectEqual(PressResult.armed, rewind.result);
    try std.testing.expect(!rewind.next.escapeClearArmed());
    try std.testing.expect(rewind.next.escapeRewindArmed());

    const activated = pressEscapeRewind(rewind.next, 101 + escape_clear_window_ms);
    try std.testing.expectEqual(PressResult.activated, activated.result);
    try std.testing.expect(!activated.next.escapeRewindArmed());
}

test "gesture expiry preserves boundary behavior" {
    const ctrl_c = pressCtrlCExit(.{}, 300).next;
    try std.testing.expect(!expireCtrlCExit(
        ctrl_c,
        300 + ctrl_c_exit_window_ms - 1,
    ).cleared);
    try std.testing.expect(expireCtrlCExit(
        ctrl_c,
        300 + ctrl_c_exit_window_ms,
    ).cleared);

    const escape = pressEscapeClear(.{}, 400).next;
    try std.testing.expect(!expireEscapeClear(
        escape,
        400 + escape_clear_window_ms,
    ).cleared);
    try std.testing.expect(expireEscapeClear(
        escape,
        401 + escape_clear_window_ms,
    ).cleared);
}

test "gesture disarm and reset report exactly what they clear" {
    const ctrl_c = pressCtrlCExit(.{}, 10).next;
    const both = pressEscapeClear(ctrl_c, 20).next;

    const escape_cleared = disarmEscapeClear(both);
    try std.testing.expect(escape_cleared.cleared);
    try std.testing.expect(escape_cleared.next.ctrlCExitArmed());
    try std.testing.expect(!escape_cleared.next.escapeClearArmed());

    const reset_transition = reset(both);
    try std.testing.expect(reset_transition.clearedAny());
    try std.testing.expect(reset_transition.cleared_ctrl_c_exit);
    try std.testing.expect(reset_transition.cleared_escape_clear);
    try std.testing.expectEqual(State{}, reset_transition.next);

    try std.testing.expect(!reset(.{}).clearedAny());
}

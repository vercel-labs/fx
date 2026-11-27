const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const input_action = @import("../../core/input/input_action.zig");
const shortcut_rules = @import("../../core/shortcuts/shortcuts.zig");
const escape_parser = @import("escape_parser.zig");
const shortcuts = @import("shortcuts.zig");

const mouse_report_escape_timeout_ms: i64 = 250;

pub fn pasteByteIngress(byte: u8) input_action.TerminalInputIngress {
    return .{ .event = .{ .paste_byte = byte } };
}

pub const Decoder = struct {
    mouse: escape_parser.MouseInput = .{},
    stage: u8 = 0,
    param: u16 = 0,
    param2: u16 = 0,
    started_ms: i64 = 0,
    cancel_pending: bool = false,

    pub fn reset(self: *Decoder) void {
        self.* = .{};
    }

    pub fn hasPending(self: *const Decoder) bool {
        return self.stage != 0;
    }

    /// Decodes one byte the terminal sent. The result carries the chord the
    /// byte names, next to its unchanged event.
    pub fn feed(
        self: *Decoder,
        byte: u8,
        context: input_action.TerminalDecodeContext,
    ) input_action.TerminalInputIngress {
        return self.feedWith(byte, context, true);
    }

    /// Decodes a byte that core replays after routing a `remapped_byte`. The
    /// original report already named its chord, so the replay names none, and
    /// a personal shortcut cannot fire twice for one key press.
    pub fn feedReplay(
        self: *Decoder,
        byte: u8,
        context: input_action.TerminalDecodeContext,
    ) input_action.TerminalInputIngress {
        return self.feedWith(byte, context, false);
    }

    fn feedWith(
        self: *Decoder,
        byte: u8,
        context: input_action.TerminalDecodeContext,
        names_chord: bool,
    ) input_action.TerminalInputIngress {
        var ingress = input_action.TerminalInputIngress{
            .interrupts_pending_text = byte < 0x80 and !context.paste_active,
        };

        if (context.paste_active) {
            return pasteByteIngress(byte);
        }

        if (byte == 0x1b and self.stage == 0) {
            self.beginEscape(context.now_ms, context.cancel_pending);
            return ingress;
        }

        if (escape_parser.isMouseReportDiscardStage(self.stage)) {
            const discard = escape_parser.consumeMouseReportDiscardByte(
                &self.stage,
                &self.param,
                &self.param2,
                &self.mouse,
                byte,
            );
            switch (discard) {
                .pending => self.started_ms = context.now_ms,
                .report_end => {
                    debug_trace.logf("input", "discard pending mouse report reason=report_end", .{});
                    self.finishEscape();
                },
                .bound => {
                    debug_trace.logf("input", "discard pending mouse report reason=bound", .{});
                    self.finishEscape();
                },
                .restart => {
                    debug_trace.logf("input", "discard pending mouse report reason=restart", .{});
                    self.started_ms = context.now_ms;
                    self.cancel_pending = context.cancel_pending;
                },
            }
            return ingress;
        }

        if (self.stage != 0) {
            const prior_stage = self.stage;
            var report_chord: ?shortcut_rules.Chord = null;
            const action = escape_parser.consumeKeyReport(
                &self.stage,
                &self.param,
                &self.param2,
                &self.mouse,
                byte,
                &report_chord,
            );
            const chord = if (names_chord) report_chord else null;

            if (byte == 0x1b and !escape_parser.isLegacyX10PayloadStage(prior_stage)) {
                self.started_ms = context.now_ms;
                self.cancel_pending = context.cancel_pending;
                return ingress;
            }

            if (self.stage != 0) self.started_ms = context.now_ms;

            if (prior_stage == 1 and
                self.stage == 0 and
                (action == null or action.? == .ignore) and
                shouldReplayControlAfterBareEscape(byte))
            {
                const was_cancel_pending = self.takeCancelPending();
                appendAction(&ingress, .escape, was_cancel_pending, null);
                ingress.replay_byte_after_routing = byte;
                return ingress;
            }

            if (action) |resolved| {
                const was_cancel_pending = self.takeCancelPending();
                appendAction(&ingress, resolved, was_cancel_pending, chord);
                return ingress;
            }

            if (self.stage != 0 or prior_stage != 0) {
                if (self.stage == 0) {
                    _ = self.takeCancelPending();
                    appendAction(&ingress, .ignore, false, null);
                }
                return ingress;
            }
        }

        const control_chord = if (names_chord) shortcut_rules.fromControlByte(byte) else null;
        if (escape_parser.controlByteFeatureAction(byte)) |resolved| {
            appendAction(&ingress, resolved, false, control_chord);
        } else {
            appendRaw(&ingress, byte, control_chord);
        }
        return ingress;
    }

    pub fn flush(
        self: *Decoder,
        now_ms: i64,
        timeout_ms: i64,
        paste_active: bool,
    ) input_action.TerminalInputIngress {
        var ingress = input_action.TerminalInputIngress{};
        if (self.stage == 0) return ingress;

        const effective_timeout_ms = if (escape_parser.isMouseReportPayloadStage(self.stage))
            @max(timeout_ms, mouse_report_escape_timeout_ms)
        else
            timeout_ms;
        if (now_ms - self.started_ms < effective_timeout_ms) return ingress;

        if (paste_active) {
            self.reset();
            return ingress;
        }

        if (escape_parser.isControlSequenceDiscardStage(self.stage)) {
            debug_trace.logf("input", "discard pending control sequence reason=quiet_expiry", .{});
            self.reset();
            return ingress;
        }

        if (escape_parser.isMouseReportDiscardStage(self.stage)) {
            debug_trace.logf("input", "discard pending mouse report reason=quiet_expiry", .{});
            self.reset();
            return ingress;
        }

        if (escape_parser.beginMouseReportDiscard(
            &self.stage,
            &self.param,
            &self.param2,
            &self.mouse,
        )) {
            self.cancel_pending = false;
            if (self.stage == 0) {
                debug_trace.logf("input", "discard pending mouse report reason=bound", .{});
                self.started_ms = 0;
            } else {
                self.started_ms = now_ms;
            }
            return ingress;
        }

        if (!escape_parser.isBareEscapeStage(self.stage)) {
            debug_trace.logf("input", "discard pending control sequence reason=quiet_expiry", .{});
            self.reset();
            return ingress;
        }

        const was_cancel_pending = self.cancel_pending;
        self.reset();
        appendAction(&ingress, .escape, was_cancel_pending, null);
        return ingress;
    }

    fn beginEscape(self: *Decoder, now_ms: i64, cancel_pending: bool) void {
        self.stage = 1;
        self.param = 0;
        self.param2 = 0;
        self.mouse.reset();
        self.started_ms = now_ms;
        self.cancel_pending = cancel_pending;
    }

    fn finishEscape(self: *Decoder) void {
        self.started_ms = 0;
        self.cancel_pending = false;
    }

    fn takeCancelPending(self: *Decoder) bool {
        const pending = self.cancel_pending;
        self.cancel_pending = false;
        return pending;
    }
};

fn appendRaw(
    ingress: *input_action.TerminalInputIngress,
    byte: u8,
    chord: ?shortcut_rules.Chord,
) void {
    ingress.setEvent(.{ .raw = .{
        .byte = byte,
        .composer_shortcut = shortcuts.fromControlByte(byte),
    } });
    ingress.chord = chord;
}

fn appendAction(
    ingress: *input_action.TerminalInputIngress,
    action: input_action.Action,
    cancel_pending: bool,
    chord: ?shortcut_rules.Chord,
) void {
    ingress.setEvent(.{ .action = .{
        .action = action,
        .composer_shortcut = shortcuts.fromEscapeAction(action),
        .cancel_pending = cancel_pending,
    } });
    ingress.chord = chord;
}

fn shouldReplayControlAfterBareEscape(byte: u8) bool {
    if (shortcuts.fromControlByte(byte) != null) return true;
    return switch (byte) {
        3, 7, 12, 15, 16, 20, 22, 24 => true,
        else => false,
    };
}

fn feedSequence(
    decoder: *Decoder,
    bytes: []const u8,
    context: input_action.TerminalDecodeContext,
) input_action.TerminalInputIngress {
    var ingress = input_action.TerminalInputIngress{};
    for (bytes) |byte| ingress = decoder.feed(byte, context);
    return ingress;
}

fn expectChord(text: []const u8, actual: ?shortcut_rules.Chord) !void {
    const expected = shortcut_rules.Chord.parse(text) orelse return error.TestBadChordText;
    try std.testing.expect(actual != null);
    try std.testing.expect(actual.?.eql(expected));
}

test "plain byte carries composer fallback without consuming product routing" {
    var decoder = Decoder{};
    const ingress = decoder.feed(11, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    });

    try std.testing.expectEqual(@as(u8, 11), ingress.event.?.raw.byte);
    try std.testing.expectEqual(
        input_action.ShortcutAction.delete_to_line_end,
        ingress.event.?.raw.composer_shortcut.?,
    );
}

test "bare Escape control replay preserves event order" {
    var decoder = Decoder{};
    _ = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
    });
    const ingress = decoder.feed(3, .{
        .now_ms = 2,
        .paste_active = false,
        .cancel_pending = true,
    });

    try std.testing.expectEqual(input_action.Action.escape, ingress.event.?.action.action);
    try std.testing.expect(ingress.event.?.action.cancel_pending);
    try std.testing.expectEqual(@as(?u8, 3), ingress.replay_byte_after_routing);
}

test "escape timeout emits one semantic action" {
    var decoder = Decoder{};
    _ = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
    });
    const ingress = decoder.flush(31, 30, false);

    try std.testing.expectEqual(input_action.Action.escape, ingress.event.?.action.action);
    try std.testing.expect(ingress.event.?.action.cancel_pending);
    try std.testing.expect(!decoder.hasPending());
}

test "active paste bypasses decoding and preserves pending text ownership" {
    var decoder = Decoder{};
    const ingress = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = true,
        .cancel_pending = true,
    });

    try std.testing.expectEqual(@as(u8, 0x1b), ingress.event.?.paste_byte);
    try std.testing.expect(!ingress.interrupts_pending_text);
    try std.testing.expect(!decoder.hasPending());
    try std.testing.expect(ingress.chord == null);
}

test "unknown escape resolves to ignore instead of Escape" {
    var decoder = Decoder{};
    _ = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
    });
    const ingress = decoder.feed('x', .{
        .now_ms = 2,
        .paste_active = false,
        .cancel_pending = false,
    });

    try std.testing.expectEqual(input_action.Action.ignore, ingress.event.?.action.action);
    try std.testing.expect(ingress.event.?.action.cancel_pending);
    try std.testing.expect(!decoder.hasPending());
}

test "unknown complete CSI stays pending until its final byte and resolves to ignore" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
    };

    _ = decoder.feed(0x1b, context);
    for ("[>0") |byte| {
        const ingress = decoder.feed(byte, context);
        try std.testing.expect(ingress.event == null);
        try std.testing.expect(decoder.hasPending());
    }
    const ingress = decoder.feed('q', context);
    try std.testing.expectEqual(input_action.Action.ignore, ingress.event.?.action.action);
    try std.testing.expect(ingress.event.?.action.cancel_pending);
    try std.testing.expect(!decoder.hasPending());
}

test "incomplete CSI expires without producing Escape" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
    };

    _ = decoder.feed(0x1b, context);
    _ = decoder.feed('[', context);
    const ingress = decoder.flush(31, 30, false);
    try std.testing.expect(ingress.event == null);
    try std.testing.expect(!decoder.hasPending());
}

test "legacy Alt+m is the Alt chord with its unchanged ignored event, and a doubled Escape names none" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    };

    _ = decoder.feed(0x1b, context);
    const ingress = decoder.feed('m', context);
    try std.testing.expectEqual(input_action.Action.ignore, ingress.event.?.action.action);
    try std.testing.expectEqual(@as(?input_action.ShortcutAction, null), ingress.event.?.action.composer_shortcut);
    try expectChord("alt+m", ingress.chord);
    try std.testing.expect(!decoder.hasPending());

    _ = decoder.feed(0x1b, context);
    _ = decoder.feed(0x1b, context);
    const doubled = decoder.feed('m', context);
    try std.testing.expectEqual(input_action.Action.ignore, doubled.event.?.action.action);
    try std.testing.expect(doubled.chord == null);
}

test "raw Ctrl+F names Ctrl+F and its event stays the cursor motion" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    };
    const ingress = decoder.feed(6, context);
    try std.testing.expectEqual(@as(u8, 6), ingress.event.?.raw.byte);
    try std.testing.expectEqual(input_action.ShortcutAction{ .move = .{ .kind = .character_right } }, ingress.event.?.raw.composer_shortcut.?);
    try expectChord("ctrl+f", ingress.chord);

    const replayed = decoder.feedReplay(6, context);
    try std.testing.expectEqual(@as(u8, 6), replayed.event.?.raw.byte);
    try std.testing.expect(replayed.chord == null);
}

test "exact CSI u and modifyOtherKeys Ctrl+F name Ctrl+F and keep remapped_byte 6" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    };
    const csi_u = feedSequence(&decoder, "\x1b[102;5u", context);
    try std.testing.expectEqual(input_action.Action{ .remapped_byte = 6 }, csi_u.event.?.action.action);
    try expectChord("ctrl+f", csi_u.chord);

    const modify_other = feedSequence(&decoder, "\x1b[27;5;102~", context);
    try std.testing.expectEqual(input_action.Action{ .remapped_byte = 6 }, modify_other.event.?.action.action);
    try expectChord("ctrl+f", modify_other.chord);
}

test "near misses of Ctrl+F keep their event and name their own chord" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    };
    const super_ctrl = feedSequence(&decoder, "\x1b[102;13u", context);
    try std.testing.expectEqual(input_action.Action{ .remapped_byte = 6 }, super_ctrl.event.?.action.action);
    try expectChord("ctrl+super+f", super_ctrl.chord);

    const shifted = feedSequence(&decoder, "\x1b[102;6u", context);
    try expectChord("ctrl+shift+f", shifted.chord);

    const meta = feedSequence(&decoder, "\x1b\x1b[102;5u", context);
    try std.testing.expect(meta.chord == null);

    const release = feedSequence(&decoder, "\x1b[102;5:3u", context);
    try std.testing.expectEqual(input_action.Action.ignore, release.event.?.action.action);
    try std.testing.expect(release.chord == null);
}

test "Ctrl+digit and key reports with arrows, Shift, and function keys name their chords" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    };
    const ctrl_one = feedSequence(&decoder, "\x1b[49;5u", context);
    try std.testing.expectEqual(input_action.Action.ignore, ctrl_one.event.?.action.action);
    try expectChord("ctrl+1", ctrl_one.chord);

    const shift_left = feedSequence(&decoder, "\x1b[1;2D", context);
    try expectChord("shift+left", shift_left.chord);

    const ctrl_right = feedSequence(&decoder, "\x1b[1;5C", context);
    try expectChord("ctrl+right", ctrl_right.chord);

    const ctrl_delete = feedSequence(&decoder, "\x1b[3;5~", context);
    try expectChord("ctrl+delete", ctrl_delete.chord);

    const ss3_f1 = feedSequence(&decoder, "\x1bOP", context);
    try expectChord("f1", ss3_f1.chord);
    try std.testing.expectEqual(input_action.Action.ignore, ss3_f1.event.?.action.action);

    const csi_f5 = feedSequence(&decoder, "\x1b[15~", context);
    try expectChord("f5", csi_f5.chord);
}

test "plain typing and Enter name no chord" {
    var decoder = Decoder{};
    const context: input_action.TerminalDecodeContext = .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
    };
    try std.testing.expect(decoder.feed('f', context).chord == null);
    try std.testing.expect(decoder.feed(13, context).chord == null);
    try std.testing.expect(decoder.feed(9, context).chord == null);
}

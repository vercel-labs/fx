const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const input_action = @import("../../core/input/input_action.zig");
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

    pub fn feed(
        self: *Decoder,
        byte: u8,
        context: input_action.TerminalDecodeContext,
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
            if (context.child_route_active and self.stage == 1 and byte == 0x1b) {
                const was_cancel_pending = self.cancel_pending;
                self.reset();
                debug_trace.logf(
                    "input",
                    "event=child_escape_replay boundary=selected_child",
                    .{},
                );
                appendAction(&ingress, .escape, was_cancel_pending);
                ingress.replay_byte_after_routing = 0x1b;
                return ingress;
            }

            const prior_stage = self.stage;
            const action = escape_parser.consumeInputEscapeByteWithMouse(
                &self.stage,
                &self.param,
                &self.param2,
                &self.mouse,
                byte,
            );

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
                appendAction(&ingress, .escape, was_cancel_pending);
                ingress.replay_byte_after_routing = byte;
                return ingress;
            }

            if (action) |resolved| {
                const was_cancel_pending = self.takeCancelPending();
                appendAction(&ingress, resolved, was_cancel_pending);
                return ingress;
            }

            if (self.stage != 0 or prior_stage != 0) {
                if (self.stage == 0) {
                    _ = self.takeCancelPending();
                    appendAction(&ingress, .ignore, false);
                }
                return ingress;
            }
        }

        if (escape_parser.controlByteFeatureAction(byte)) |resolved| {
            appendAction(&ingress, resolved, false);
        } else {
            appendRaw(&ingress, byte);
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
        appendAction(&ingress, .escape, was_cancel_pending);
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

fn appendRaw(ingress: *input_action.TerminalInputIngress, byte: u8) void {
    ingress.setEvent(.{ .raw = .{
        .byte = byte,
        .composer_shortcut = shortcuts.fromControlByte(byte),
    } });
}

fn appendAction(
    ingress: *input_action.TerminalInputIngress,
    action: input_action.Action,
    cancel_pending: bool,
) void {
    ingress.setEvent(.{ .action = .{
        .action = action,
        .composer_shortcut = shortcuts.fromEscapeAction(action),
        .cancel_pending = cancel_pending,
    } });
}

fn shouldReplayControlAfterBareEscape(byte: u8) bool {
    if (shortcuts.fromControlByte(byte) != null) return true;
    return switch (byte) {
        3, 7, 12, 15, 22, 24 => true,
        else => false,
    };
}

test "plain byte carries composer fallback without consuming product routing" {
    var decoder = Decoder{};
    const ingress = decoder.feed(11, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = false,
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
        .child_route_active = false,
    });
    const ingress = decoder.feed(3, .{
        .now_ms = 2,
        .paste_active = false,
        .cancel_pending = true,
        .child_route_active = false,
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
        .child_route_active = false,
    });
    const ingress = decoder.flush(31, 30, false);

    try std.testing.expectEqual(input_action.Action.escape, ingress.event.?.action.action);
    try std.testing.expect(ingress.event.?.action.cancel_pending);
    try std.testing.expect(!decoder.hasPending());
}

test "selected child defers the next Escape until after action routing" {
    var decoder = Decoder{};
    _ = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
        .child_route_active = true,
    });
    const ingress = decoder.feed(0x1b, .{
        .now_ms = 2,
        .paste_active = false,
        .cancel_pending = true,
        .child_route_active = true,
    });

    try std.testing.expectEqual(input_action.Action.escape, ingress.event.?.action.action);
    try std.testing.expectEqual(@as(?u8, 0x1b), ingress.replay_byte_after_routing);
    try std.testing.expect(!decoder.hasPending());

    const replay = decoder.feed(0x1b, .{
        .now_ms = 3,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = false,
    });
    try std.testing.expect(replay.event == null);
    try std.testing.expect(decoder.hasPending());
    try std.testing.expect(!decoder.cancel_pending);
}

test "active paste bypasses decoding and preserves pending text ownership" {
    var decoder = Decoder{};
    const ingress = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = true,
        .cancel_pending = true,
        .child_route_active = false,
    });

    try std.testing.expectEqual(@as(u8, 0x1b), ingress.event.?.paste_byte);
    try std.testing.expect(!ingress.interrupts_pending_text);
    try std.testing.expect(!decoder.hasPending());
}

test "unknown escape resolves to ignore instead of Escape" {
    var decoder = Decoder{};
    _ = decoder.feed(0x1b, .{
        .now_ms = 1,
        .paste_active = false,
        .cancel_pending = true,
        .child_route_active = false,
    });
    const ingress = decoder.feed('x', .{
        .now_ms = 2,
        .paste_active = false,
        .cancel_pending = false,
        .child_route_active = false,
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
        .child_route_active = false,
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
        .child_route_active = false,
    };

    _ = decoder.feed(0x1b, context);
    _ = decoder.feed('[', context);
    const ingress = decoder.flush(31, 30, false);
    try std.testing.expect(ingress.event == null);
    try std.testing.expect(!decoder.hasPending());
}

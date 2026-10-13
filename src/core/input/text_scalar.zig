const std = @import("std");
const display_width = @import("../shared/display_width.zig");

pub const Owner = enum {
    composer,
    question_freeform,
    approval_amendment,
};

pub const Scalar = struct {
    owner: Owner,
    bytes: [4]u8,
    len: usize,

    pub fn slice(self: *const Scalar) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const DropReason = enum {
    invalid_utf8,
    owner_changed,
};

pub const Drop = struct {
    reason: DropReason,
    owner: Owner,
    bytes: usize,
};

pub const Step = struct {
    scalar: ?Scalar = null,
    dropped: ?Drop = null,
};

pub const State = struct {
    owner: ?Owner = null,
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: usize = 0,
    expected_len: usize = 0,
};

pub const Transition = struct {
    next: State,
    step: Step,
};

pub const Pending = struct {
    owner: Owner,
    bytes: usize,
};

pub const ResetTransition = struct {
    next: State = .{},
    dropped: ?Pending = null,
};

pub fn hasPending(state: State) bool {
    return state.len > 0;
}

pub fn reset(state: State) ResetTransition {
    return .{
        .dropped = if (state.owner) |owner| .{
            .owner = owner,
            .bytes = state.len,
        } else null,
    };
}

pub fn advance(state: State, owner: Owner, byte: u8) Transition {
    if (state.owner != null and state.owner.? != owner) {
        const restarted = advance(.{}, owner, byte);
        var step = restarted.step;
        const restarted_drop_bytes = if (step.dropped) |drop| drop.bytes else 0;
        step.dropped = .{
            .reason = .owner_changed,
            .owner = state.owner.?,
            .bytes = state.len + restarted_drop_bytes,
        };
        return .{ .next = restarted.next, .step = step };
    }

    if (state.len == 0) {
        const expected_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            return .{
                .next = .{},
                .step = .{ .dropped = .{
                    .reason = .invalid_utf8,
                    .owner = owner,
                    .bytes = 1,
                } },
            };
        };
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        bytes[0] = byte;
        if (expected_len == 1) {
            return .{
                .next = .{},
                .step = .{ .scalar = .{ .owner = owner, .bytes = bytes, .len = 1 } },
            };
        }
        return .{
            .next = .{
                .owner = owner,
                .bytes = bytes,
                .len = 1,
                .expected_len = expected_len,
            },
            .step = .{},
        };
    }

    if (byte & 0xC0 != 0x80) {
        const restarted = advance(.{}, owner, byte);
        var step = restarted.step;
        const restarted_drop_bytes = if (step.dropped) |drop| drop.bytes else 0;
        step.dropped = .{
            .reason = .invalid_utf8,
            .owner = owner,
            .bytes = state.len + restarted_drop_bytes,
        };
        return .{ .next = restarted.next, .step = step };
    }

    var next = state;
    next.bytes[next.len] = byte;
    next.len += 1;
    if (next.len < next.expected_len) return .{ .next = next, .step = .{} };

    _ = display_width.decodeUtf8Sequence(next.bytes[0..next.len]) catch {
        return .{
            .next = .{},
            .step = .{ .dropped = .{
                .reason = .invalid_utf8,
                .owner = owner,
                .bytes = next.len,
            } },
        };
    };
    return .{
        .next = .{},
        .step = .{ .scalar = .{ .owner = owner, .bytes = next.bytes, .len = next.len } },
    };
}

test "text scalar admission completes utf8 atomically" {
    var state = State{};
    var transition = advance(state, .composer, 0xE2);
    try std.testing.expect(transition.step.scalar == null);
    try std.testing.expect(transition.step.dropped == null);
    state = transition.next;

    transition = advance(state, .composer, 0x82);
    try std.testing.expect(transition.step.scalar == null);
    state = transition.next;

    transition = advance(state, .composer, 0xAC);
    try std.testing.expectEqualStrings("€", transition.step.scalar.?.slice());
    try std.testing.expectEqual(Owner.composer, transition.step.scalar.?.owner);
    try std.testing.expect(!hasPending(transition.next));
}

test "text scalar admission rejects invalid utf8 without retaining bytes" {
    var transition = advance(.{}, .composer, 0xE2);
    transition = advance(transition.next, .composer, 0x28);
    try std.testing.expectEqualStrings("(", transition.step.scalar.?.slice());
    try std.testing.expectEqual(DropReason.invalid_utf8, transition.step.dropped.?.reason);
    try std.testing.expectEqual(@as(usize, 1), transition.step.dropped.?.bytes);
    try std.testing.expect(!hasPending(transition.next));
}

test "text scalar admission drops an incomplete scalar when its owner changes" {
    var transition = advance(.{}, .composer, 0xE2);
    transition = advance(transition.next, .question_freeform, 0xC3);
    try std.testing.expectEqual(DropReason.owner_changed, transition.step.dropped.?.reason);
    try std.testing.expectEqual(Owner.composer, transition.step.dropped.?.owner);
    try std.testing.expectEqual(@as(usize, 1), transition.step.dropped.?.bytes);
    try std.testing.expectEqual(Owner.question_freeform, transition.next.owner.?);
    try std.testing.expectEqual(@as(usize, 1), transition.next.len);
}

test "text scalar reset reports pending ownership without mutating input" {
    const pending = advance(.{}, .approval_amendment, 0xE2).next;
    const transition = reset(pending);
    try std.testing.expectEqual(Owner.approval_amendment, transition.dropped.?.owner);
    try std.testing.expectEqual(@as(usize, 1), transition.dropped.?.bytes);
    try std.testing.expect(!hasPending(transition.next));
}

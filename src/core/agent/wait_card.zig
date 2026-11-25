//! The card a view shows for a subagent's wait that only the person can
//! continue: a request out of credits, a provider's refusal or an expired
//! sign-in (kind E). The card owns a copy of what it draws, so the subagent's
//! status row stays the only source of truth and the view never borrows it
//! (`tests/tla/subagent/ViewWaits.tla` ShownWhenFree, NoStaleShown).

const std = @import("std");
const recovery = @import("../recovery/recovery.zig");
const types = @import("../shared/types.zig");

pub const Kind = enum {
    sign_in,
    quota,
    rejected,
    too_long,
    content_filter,
    crash_loop,
    stale,

    pub fn of(need: ?recovery.Status.Need) Kind {
        return switch (need orelse return .rejected) {
            .sign_in => .sign_in,
            .quota => .quota,
            .rejected => .rejected,
            .too_long => .too_long,
            .content_filter => .content_filter,
            .crash_loop => .crash_loop,
            .stale => .stale,
        };
    }
};

/// What the person can press on the card. `cancel` is Esc: it ends the
/// subagent's turn, and it is not one of the numbered choices.
pub const Choice = enum { retry, sign_in, change_model, open_screen, stop, cancel };

const retry_and_sign_in = [_]Choice{ .retry, .sign_in, .change_model, .open_screen, .stop };
const retry_and_model = [_]Choice{ .retry, .change_model, .open_screen, .stop };
const retry_only = [_]Choice{ .retry, .open_screen, .stop };

const name_max_bytes = 64;
const reason_max_bytes = recovery.Text.capacity;
const detail_max_bytes = recovery.Text.capacity;

/// The status text is `reason · what follows`. The keys live after that
/// separator on most waits, so the card cuts there and draws them as choices.
const reason_separator = " \u{b7} ";

/// One subagent's wait, copied into the view that holds it. `asked` is the
/// wait's place in its tree's order (`ChildAgent.wait_asked`): the view
/// returns the copy when the subagent raises a newer wait, and keeps it while
/// the stamp holds (`tests/tla/subagent/ViewWaits.tla` OldestFirst).
pub const WaitCardPrompt = struct {
    active: bool = false,
    asked: u64 = 0,
    kind: Kind = .rejected,
    name: [name_max_bytes]u8 = undefined,
    name_len: usize = 0,
    /// The reason alone: the status row before its separator.
    reason: [reason_max_bytes]u8 = undefined,
    reason_len: usize = 0,
    /// What the wait says besides its reason, such as the sign-in countdown,
    /// which moves every second and must not freeze in the copy.
    detail: [detail_max_bytes]u8 = undefined,
    detail_len: usize = 0,
    selected: usize = 0,

    pub fn isActive(self: *const WaitCardPrompt) bool {
        return self.active;
    }

    pub fn nameText(self: *const WaitCardPrompt) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn reasonText(self: *const WaitCardPrompt) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn detailText(self: *const WaitCardPrompt) []const u8 {
        return self.detail[0..self.detail_len];
    }

    pub fn clear(self: *WaitCardPrompt) void {
        self.* = .{};
    }

    pub fn choices(self: *const WaitCardPrompt) []const Choice {
        return switch (self.kind) {
            .sign_in, .rejected => &retry_and_sign_in,
            .quota, .too_long => &retry_and_model,
            .content_filter, .crash_loop, .stale => &retry_only,
        };
    }

    pub fn choiceAt(self: *const WaitCardPrompt, index: usize) ?Choice {
        const list = self.choices();
        return if (index < list.len) list[index] else null;
    }

    pub fn highlighted(self: *const WaitCardPrompt) ?Choice {
        return self.choiceAt(self.selected);
    }

    pub fn moveChoice(self: *WaitCardPrompt, delta: i32) void {
        const count = self.choices().len;
        if (count == 0) return;
        const current: i32 = @intCast(@min(self.selected, count - 1));
        self.selected = @intCast(@mod(current + delta, @as(i32, @intCast(count))));
    }

    /// Copies the wait `status` describes, stamped `asked`, under `name`.
    /// Returns whether what the person reads changed, so a caller repaints
    /// the countdown as it ticks and nothing else.
    pub fn sync(self: *WaitCardPrompt, asked: u64, status: types.RouteRecoveryStatus, name: []const u8) bool {
        const text = status.text.slice();
        const cut = std.mem.find(u8, text, reason_separator) orelse text.len;
        const kind = Kind.of(status.need);
        const after_separator = @min(text.len, cut + reason_separator.len);
        const detail = if (kind == .sign_in and cut < text.len) text[after_separator..] else "";
        const changed = !self.active or self.asked != asked or
            !std.mem.eql(u8, self.reasonText(), text[0..cut]) or
            !std.mem.eql(u8, self.detailText(), detail) or
            !std.mem.eql(u8, self.nameText(), name);
        self.active = true;
        self.asked = asked;
        self.kind = kind;
        self.name_len = copyInto(&self.name, name);
        self.reason_len = copyInto(&self.reason, text[0..cut]);
        self.detail_len = copyInto(&self.detail, detail);
        if (self.selected >= self.choices().len) self.selected = 0;
        return changed;
    }

    /// One choice's label, with `buf` backing the name it carries.
    pub fn labelFor(self: *const WaitCardPrompt, choice: Choice, buf: []u8) []const u8 {
        return switch (choice) {
            .retry => if (self.kind == .stale) "Resume" else "Retry",
            .sign_in => "Sign in",
            .change_model => "Change model",
            .open_screen => std.mem.print(buf, "Open {s}'s screen", .{self.nameText()}) catch "Open its screen",
            .stop => std.mem.print(buf, "Stop {s}", .{self.nameText()}) catch "Stop the subagent",
            .cancel => "Cancel this turn",
        };
    }
};

/// The Enter that follows a card's answer: the card hid the view's draft,
/// and that Enter must not submit it. One keystroke is dropped; any other
/// key disarms the guard, so a later Enter is the person's own.
pub const EnterGuard = struct {
    armed: bool = false,

    pub fn arm(self: *EnterGuard) void {
        self.armed = true;
    }

    /// True when `byte` is the Enter to drop.
    pub fn dropEnter(self: *EnterGuard, byte: u8) bool {
        const drop = self.armed and byte == '\r';
        self.armed = false;
        return drop;
    }
};

fn copyInto(buf: []u8, text: []const u8) usize {
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);
    return len;
}

fn statusText(comptime value: []const u8) recovery.Text {
    var text: recovery.Text = .{};
    @memcpy(text.bytes[0..value.len], value);
    text.len = value.len;
    return text;
}

fn waitStatus(need: recovery.Status.Need, comptime text: []const u8) types.RouteRecoveryStatus {
    return .{ .kind = .need_user, .need = need, .text = statusText(text) };
}

test "wait card: the reason stops at the separator, so the keys stay out of it" {
    var card: WaitCardPrompt = .{};
    const status = waitStatus(.rejected, "The provider rejected this request \u{b7} press Esc");
    try std.testing.expect(card.sync(7, status, "worker"));
    try std.testing.expectEqualStrings("The provider rejected this request", card.reasonText());
    try std.testing.expectEqualStrings("", card.detailText());
    try std.testing.expectEqual(@as(u64, 7), card.asked);
    try std.testing.expectEqual(Kind.rejected, card.kind);
    try std.testing.expectEqualStrings("worker", card.nameText());

    // A wait with no separator is its own reason.
    const no_keys = waitStatus(.too_long, "Still too long after compacting");
    try std.testing.expect(card.sync(8, no_keys, "worker"));
    try std.testing.expectEqualStrings("Still too long after compacting", card.reasonText());
    try std.testing.expectEqualStrings("", card.detailText());
    try std.testing.expectEqual(Kind.too_long, card.kind);
}

test "wait card: the sign-in countdown is kept beside the reason" {
    var card: WaitCardPrompt = .{};
    const status = waitStatus(.sign_in, "Sign-in expired \u{b7} waiting 12s \u{b7} next try in 8s");
    try std.testing.expect(card.sync(3, status, "signer"));
    try std.testing.expectEqualStrings("Sign-in expired", card.reasonText());
    try std.testing.expectEqualStrings("waiting 12s \u{b7} next try in 8s", card.detailText());
    try std.testing.expectEqual(Kind.sign_in, card.kind);

    // The same wait one second later is the same item, and the countdown moved.
    const later = waitStatus(.sign_in, "Sign-in expired \u{b7} waiting 13s \u{b7} next try in 7s");
    try std.testing.expect(card.sync(3, later, "signer"));
    try std.testing.expectEqualStrings("waiting 13s \u{b7} next try in 7s", card.detailText());
    try std.testing.expectEqual(@as(u64, 3), card.asked);
}

test "wait card: the choices follow the kind, and the number a digit picks is the one drawn" {
    var card: WaitCardPrompt = .{};
    const Cases = struct {
        kind: Kind,
        choices: []const Choice,
    };
    const cases = [_]Cases{
        .{ .kind = .sign_in, .choices = &.{ .retry, .sign_in, .change_model, .open_screen, .stop } },
        .{ .kind = .rejected, .choices = &.{ .retry, .sign_in, .change_model, .open_screen, .stop } },
        .{ .kind = .quota, .choices = &.{ .retry, .change_model, .open_screen, .stop } },
        .{ .kind = .too_long, .choices = &.{ .retry, .change_model, .open_screen, .stop } },
        .{ .kind = .content_filter, .choices = &.{ .retry, .open_screen, .stop } },
        .{ .kind = .crash_loop, .choices = &.{ .retry, .open_screen, .stop } },
        .{ .kind = .stale, .choices = &.{ .retry, .open_screen, .stop } },
    };
    var label_buf: [96]u8 = undefined;
    for (cases) |case| {
        card.kind = case.kind;
        const drawn = card.choices();
        try std.testing.expectEqual(case.choices.len, drawn.len);
        for (case.choices, drawn, 0..) |expected, actual, index| {
            try std.testing.expectEqual(expected, actual);
            // The digit the person reads beside a choice is the one that
            // picks it.
            try std.testing.expectEqual(expected, card.choiceAt(index).?);
            try std.testing.expect(card.labelFor(actual, &label_buf).len > 0);
        }
        try std.testing.expect(card.choiceAt(case.choices.len) == null);
    }

    // The labels say what the subagent's own screen offers.
    card.kind = .rejected;
    card.name_len = copyInto(&card.name, "worker");
    try std.testing.expectEqualStrings("Retry", card.labelFor(.retry, &label_buf));
    try std.testing.expectEqualStrings("Sign in", card.labelFor(.sign_in, &label_buf));
    try std.testing.expectEqualStrings("Change model", card.labelFor(.change_model, &label_buf));
    try std.testing.expectEqualStrings("Open worker's screen", card.labelFor(.open_screen, &label_buf));
    try std.testing.expectEqualStrings("Stop worker", card.labelFor(.stop, &label_buf));
    try std.testing.expectEqualStrings("Cancel this turn", card.labelFor(.cancel, &label_buf));
    card.kind = .stale;
    try std.testing.expectEqualStrings("Resume", card.labelFor(.retry, &label_buf));

    // Arrows wrap, and the highlight is always one of the drawn choices.
    card.kind = .content_filter;
    card.selected = 0;
    card.moveChoice(-1);
    try std.testing.expectEqual(@as(usize, 2), card.selected);
    try std.testing.expectEqual(Choice.stop, card.highlighted().?);
    card.moveChoice(1);
    try std.testing.expectEqual(@as(usize, 0), card.selected);
}

test "wait card: the Enter after an answer is dropped once, and any other key disarms it" {
    var guard: EnterGuard = .{};
    try std.testing.expect(!guard.dropEnter('\r'));

    guard.arm();
    try std.testing.expect(guard.dropEnter('\r'));
    // Only that one Enter: the next one is the person's own.
    try std.testing.expect(!guard.dropEnter('\r'));

    // Any other key is that keystroke's own, and disarms the guard.
    guard.arm();
    try std.testing.expect(!guard.dropEnter('a'));
    try std.testing.expect(!guard.dropEnter('\r'));

    // A line feed is not the Enter the terminal sends for the Enter key.
    guard.arm();
    try std.testing.expect(!guard.dropEnter('\n'));
}

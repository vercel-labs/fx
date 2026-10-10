//! Elicitation (2025 sessions): the server's `elicitation/create`
//! requests and the URL elicitations a -32042 error lists, as one state
//! machine. The
//! caller reads each request with `protocol/elicitation.zig`, keeps its id
//! and elicitationId by slot, and maps the server's cancels and completion
//! notifications to slots. 2026 rounds are `core/mrtr.zig`'s chains; the host's answers
//! there go through the same reader. Pure.

const std = @import("std");
const trace = @import("../io/trace.zig");

/// Elicitations the host holds or that wait for their completion.
pub const max_pending = 16;

pub const Mode = enum { form, url };
/// A request is answered with a JSON-RPC response; one a -32042 error lists
/// is not answered at all.
pub const Origin = enum { request, required };
pub const Action = enum { accept, decline, cancel };
pub const Phase = enum { shown, waiting };

/// The modes the client declared.
pub const Config = struct { form: bool = false, url: bool = false };

pub const Event = union(enum) {
    /// The server started an elicitation. `eid`: a url one carries an
    /// elicitationId. One a -32042 error lists is url mode with an id.
    asked: struct { origin: Origin, mode: Mode, eid: bool, readable: bool },
    /// The host's answer; `valid` is false when form content fails the schema.
    answered: struct { slot: u8, action: Action, valid: bool },
    /// notifications/cancelled for the request in `slot`; null when no
    /// request the client holds has that id.
    server_cancelled: ?u8,
    /// A new initialize, a DELETE, or detection again.
    session_ended,
    /// notifications/elicitation/complete for the elicitationId in `slot`;
    /// null when none the client holds has it.
    completed: ?u8,
};

pub const Reject = enum { invalid_params, too_many };

pub const Effect = union(enum) {
    /// Hand the elicitation to the host.
    show: u8,
    /// Answer the request just asked with an error: -32602 for one the
    /// client can't read or didn't declare, -32603 when the
    /// host already holds `max_pending`.
    reject: Reject,
    /// Answer the request in `slot`; `content` with a form accept only.
    send: struct { slot: u8, action: Action, content: bool },
    /// Tell the host it no longer holds `slot`.
    withdraw: u8,
    /// Tell the host the out-of-band interaction of `slot` completed.
    complete: u8,
    /// `slot` is free; forget what was kept for it.
    release: u8,
};

/// What a step answered, for the trace.
pub const Sent = enum { none, @"error", content, accept, decline, cancel };

pub const Output = struct {
    effect_buffer: [2 * max_pending + 2]Effect = undefined,
    effect_count: usize = 0,
    /// The model action, "" for a step that is none (a session end with
    /// nothing pending).
    action: []const u8 = "",
    ignored: bool = false,
    /// The elicitation the step was about, numbered from 1; 0 for none.
    n: u32 = 0,
    slot: ?u8 = null,
    /// Form content failed the schema: nothing changed, the host hears why.
    refused: bool = false,
    sent: Sent = .none,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn emit(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Slot = struct {
    used: bool = false,
    n: u32 = 0,
    origin: Origin = .request,
    mode: Mode = .form,
    eid: bool = false,
    phase: Phase = .shown,
    /// Its completion came while the host held it.
    early: bool = false,
};

pub const Table = struct {
    config: Config,
    slots: [max_pending]Slot = @splat(.{}),
    /// The number of the last elicitation asked.
    last: u32 = 0,

    pub fn init(config: Config) Table {
        return .{ .config = config };
    }

    pub fn step(t: *Table, event: Event, out: *Output) void {
        switch (event) {
            .asked => |a| {
                // The model's Ask: only url ones carry an id, and a -32042
                // error lists only those.
                std.debug.assert(a.mode == .url or !a.eid);
                std.debug.assert(a.origin == .request or (a.mode == .url and a.eid));
                t.last += 1;
                out.action = "ask";
                out.n = t.last;
                const declared = switch (a.mode) {
                    .form => t.config.form,
                    .url => t.config.url,
                };
                const open = for (&t.slots, 0..) |*s, i| {
                    if (!s.used) break i;
                } else null;
                if (a.readable and declared and open != null) {
                    const slot: u8 = @intCast(open.?);
                    t.slots[slot] = .{ .used = true, .n = t.last, .origin = a.origin, .mode = a.mode, .eid = a.eid };
                    out.slot = slot;
                    out.emit(.{ .show = slot });
                } else if (a.origin == .request) {
                    out.sent = .@"error";
                    out.emit(.{ .reject = if (a.readable and declared) .too_many else .invalid_params });
                }
            },
            .answered => |a| {
                out.action = "answer";
                const s = t.held(a.slot) orelse return ignore(out);
                out.n = s.n;
                out.slot = a.slot;
                if (s.phase != .shown) return ignore(out);
                const content = a.action == .accept and s.mode == .form;
                if (content and !a.valid) {
                    out.refused = true;
                    return;
                }
                if (s.origin == .request) {
                    out.sent = if (content) .content else switch (a.action) {
                        .accept => .accept,
                        .decline => .decline,
                        .cancel => .cancel,
                    };
                    out.emit(.{ .send = .{ .slot = a.slot, .action = a.action, .content = content } });
                }
                if (a.action == .accept and s.mode == .url and s.eid) {
                    if (!s.early) {
                        s.phase = .waiting;
                        return;
                    }
                    // Its completion came first, so the host hears it now.
                    out.emit(.{ .complete = a.slot });
                }
                t.free(a.slot, out);
            },
            .server_cancelled => |maybe| {
                out.action = "cancel";
                const slot = maybe orelse return ignore(out);
                const s = t.held(slot) orelse return ignore(out);
                out.n = s.n;
                out.slot = slot;
                if (s.phase != .shown or s.origin != .request) return ignore(out);
                out.emit(.{ .withdraw = slot });
                t.free(slot, out);
            },
            .session_ended => {
                var any = false;
                for (&t.slots, 0..) |*s, i| if (s.used) {
                    any = true;
                    if (s.phase == .shown) out.emit(.{ .withdraw = @intCast(i) });
                    t.free(@intCast(i), out);
                };
                if (any) out.action = "end";
            },
            .completed => |maybe| {
                out.action = "complete";
                const slot = maybe orelse return ignore(out);
                const s = t.held(slot) orelse return ignore(out);
                out.n = s.n;
                out.slot = slot;
                if (s.phase == .shown and s.mode == .url and s.eid) {
                    // Kept for the host's acceptance.
                    s.early = true;
                    return;
                }
                if (s.phase != .waiting) return ignore(out);
                out.emit(.{ .complete = slot });
                t.free(slot, out);
            },
        }
    }

    pub fn held(t: *Table, slot: u8) ?*Slot {
        if (slot >= max_pending or !t.slots[slot].used) return null;
        return &t.slots[slot];
    }

    fn free(t: *Table, slot: u8, out: *Output) void {
        t.slots[slot] = .{};
        out.emit(.{ .release = slot });
    }

    fn ignore(out: *Output) void {
        out.ignored = true;
    }
};

/// One trace record per model action. `phase` is the elicitation's after
/// the step: 0 idle, 1 shown, 2 waiting, 3 done.
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, t: *const Table, event: Event, out: *const Output) std.Io.Writer.Error!void {
    if (out.action.len == 0) return;
    const phase: i64 = if (out.n == 0) 0 else for (t.slots) |s| {
        if (s.used and s.n == out.n) break @as(i64, @intFromEnum(s.phase)) + 1;
    } else 3;
    const asked = if (event == .asked) event.asked else null;
    const answered = if (event == .answered) event.answered else null;
    try writer.write(.{
        .machine = "elicitation",
        .instance = instance,
        .event = out.action,
        .from = "",
        .to = "",
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },
            // TLC's integers are 32-bit; elicitations stay far below.
            .{ .name = "n", .value = .{ .int = @min(out.n, 1 << 30) } },
            .{ .name = "required", .value = .{ .boolean = if (asked) |a| a.origin == .required else false } },
            .{ .name = "url", .value = .{ .boolean = if (asked) |a| a.mode == .url else false } },
            .{ .name = "eid", .value = .{ .boolean = if (asked) |a| a.eid else false } },
            .{ .name = "readable", .value = .{ .boolean = if (asked) |a| a.readable else false } },
            .{ .name = "act", .value = .{ .int = if (answered) |a| @intFromEnum(a.action) else 0 } },
            .{ .name = "valid", .value = .{ .boolean = if (answered) |a| a.valid else false } },
            .{ .name = "phase", .value = .{ .int = phase } },
            .{ .name = "sent", .value = .{ .int = @intFromEnum(out.sent) } },
            .{ .name = "declared", .value = .{ .int = @as(i64, @intFromBool(t.config.form)) | @as(i64, @intFromBool(t.config.url)) << 1 } },
        },
    });
}

// ---- tests ----

const testing = std.testing;

/// The model's ghosts, for one walk: what was answered and told, by number.
const World = struct {
    const max_n = 64;
    sends: [max_n]u8 = @splat(0),
    withdrawn: [max_n]bool = @splat(false),
    told: [max_n]u8 = @splat(0),
    accepted_url: [max_n]bool = @splat(false),
    required: [max_n]bool = @splat(false),
    early: [max_n]bool = @splat(false),

    fn check(w: *World, t: *const Table, before: *const Table, event: Event, out: *const Output) !void {
        if (out.n >= max_n) return;
        // The host accepted a url one with an id, answered or not.
        if (event == .answered and !out.ignored and !out.refused and event.answered.action == .accept) {
            const slot = before.slots[event.answered.slot];
            if (slot.mode == .url and slot.eid) w.accepted_url[slot.n] = true;
        }
        for (out.effects()) |effect| switch (effect) {
            .show => |slot| {
                const s = t.slots[slot];
                // ModeGate: only a declared mode reaches the host.
                try testing.expect(if (s.mode == .form) t.config.form else t.config.url);
                if (s.origin == .required) w.required[s.n] = true;
            },
            .reject => {
                const a = event.asked;
                try testing.expectEqual(Origin.request, a.origin);
                w.sends[out.n] += 1;
            },
            .send => |s| {
                const a = event.answered;
                const slot = before.slots[s.slot];
                try testing.expectEqual(a.action, s.action); // HostDecides
                try testing.expectEqual(a.action == .accept and slot.mode == .form, s.content); // ContentGate
                try testing.expect(!s.content or a.valid); // ValidOnly
                try testing.expect(!w.withdrawn[slot.n]); // NothingAfterWithdraw
                try testing.expect(!w.required[slot.n]); // RequiredUnanswered
                w.sends[slot.n] += 1;
            },
            .withdraw => |slot| {
                // NothingAfterWithdraw: only one the host still holds.
                const n = before.slots[slot].n;
                try testing.expectEqual(@as(u8, 0), w.sends[n]);
                try testing.expect(!w.accepted_url[n]);
                w.withdrawn[n] = true;
            },
            .complete => |slot| {
                const n = before.slots[slot].n;
                w.told[n] += 1;
                try testing.expect(w.told[n] <= 1); // CompleteOnce
                try testing.expect(w.accepted_url[n]); // CompleteOnlyAccepted
            },
            .release => {},
        };
        if (event == .completed and !out.ignored and before.slots[out.slot.?].phase == .shown) w.early[out.n] = true;
        // EarlyCompletionTold.
        if (w.early[out.n] and w.accepted_url[out.n]) try testing.expectEqual(@as(u8, 1), w.told[out.n]);
        for (w.sends) |count| try testing.expect(count <= 1); // AnsweredOnce
        var used: usize = 0;
        for (t.slots) |s| used += @intFromBool(s.used);
        try testing.expect(used <= max_pending); // Bounded
        // Where the model has no choice, the core must act.
        switch (event) {
            .asked => |a| {
                var open = false;
                for (before.slots) |s| open = open or !s.used;
                const declared = if (a.mode == .form) t.config.form else t.config.url;
                try testing.expectEqual(a.readable and declared and open, out.slot != null);
                if (a.origin == .request) try testing.expect(out.slot != null or out.sent == .@"error");
            },
            .answered => |a| if (a.slot < max_pending and before.slots[a.slot].used and before.slots[a.slot].phase == .shown) {
                const s = before.slots[a.slot];
                if (a.action == .accept and s.mode == .form and !a.valid) {
                    try testing.expect(out.refused and out.effect_count == 0);
                } else try testing.expect(!t.slots[a.slot].used or t.slots[a.slot].phase == .waiting);
            },
            .session_ended => for (t.slots) |s| try testing.expect(!s.used),
            else => {},
        }
    }
};

const alphabet = [_]Event{
    .{ .asked = .{ .origin = .request, .mode = .form, .eid = false, .readable = true } },
    .{ .asked = .{ .origin = .request, .mode = .url, .eid = true, .readable = true } },
    .{ .asked = .{ .origin = .request, .mode = .url, .eid = false, .readable = true } },
    .{ .asked = .{ .origin = .request, .mode = .form, .eid = false, .readable = false } },
    .{ .asked = .{ .origin = .required, .mode = .url, .eid = true, .readable = true } },
    .{ .answered = .{ .slot = 0, .action = .accept, .valid = true } },
    .{ .answered = .{ .slot = 0, .action = .accept, .valid = false } },
    .{ .answered = .{ .slot = 0, .action = .decline, .valid = true } },
    .{ .answered = .{ .slot = 1, .action = .accept, .valid = true } },
    .{ .answered = .{ .slot = 1, .action = .cancel, .valid = true } },
    .{ .server_cancelled = 0 },
    .{ .server_cancelled = 1 },
    .{ .server_cancelled = null },
    .session_ended,
    .{ .completed = 0 },
    .{ .completed = 1 },
    .{ .completed = null },
};

fn explore(t: Table, w: World, depth: usize) !void {
    if (depth == 0) return;
    for (alphabet) |event| {
        var next = t;
        var world = w;
        var out: Output = .{};
        next.step(event, &out);
        try world.check(&next, &t, event, &out);
        try explore(next, world, depth - 1);
    }
}

test "every event sequence to depth 4 keeps the model's invariants, for every declared set" {
    for ([_]Config{ .{ .form = true }, .{ .url = true }, .{ .form = true, .url = true } }) |config| {
        try explore(.init(config), .{}, 4);
    }
}

test "random long sequences keep the model's invariants, past max_pending" {
    var prng: std.Random.DefaultPrng = .init(0x11);
    const random = prng.random();
    for (0..40) |_| {
        var t: Table = .init(.{ .form = true, .url = true });
        var w: World = .{};
        for (0..60) |_| {
            const event: Event = switch (random.uintLessThan(u8, 6)) {
                0, 1 => .{ .asked = if (random.boolean())
                    .{ .origin = .request, .mode = .form, .eid = false, .readable = random.uintLessThan(u8, 8) != 0 }
                else
                    .{ .origin = if (random.boolean()) .request else .required, .mode = .url, .eid = true, .readable = true } },
                2 => .{ .answered = .{ .slot = random.uintLessThan(u8, max_pending + 1), .action = random.enumValue(Action), .valid = random.boolean() } },
                3 => .{ .server_cancelled = random.uintLessThan(u8, max_pending) },
                4 => .{ .completed = random.uintLessThan(u8, max_pending) },
                else => if (random.uintLessThan(u8, 10) == 0) .session_ended else .{ .server_cancelled = null },
            };
            const before = t;
            var out: Output = .{};
            t.step(event, &out);
            try w.check(&t, &before, event, &out);
        }
    }
}

test "a form request is shown, answered once with its content, and freed" {
    var t: Table = .init(.{ .form = true });
    var out: Output = .{};
    t.step(.{ .asked = .{ .origin = .request, .mode = .form, .eid = false, .readable = true } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .show = 0 }}, out.effects());
    out = .{};
    t.step(.{ .answered = .{ .slot = 0, .action = .accept, .valid = false } }, &out);
    try testing.expect(out.refused and out.effect_count == 0 and t.slots[0].used);
    out = .{};
    t.step(.{ .answered = .{ .slot = 0, .action = .accept, .valid = true } }, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .send = .{ .slot = 0, .action = .accept, .content = true } }, .{ .release = 0 } }, out.effects());
    out = .{};
    t.step(.{ .answered = .{ .slot = 0, .action = .decline, .valid = true } }, &out);
    try testing.expect(out.ignored and out.effect_count == 0);
}

test "an undeclared mode or an unreadable request is refused, and a full table too" {
    var t: Table = .init(.{ .form = true });
    var out: Output = .{};
    t.step(.{ .asked = .{ .origin = .request, .mode = .url, .eid = true, .readable = true } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .reject = .invalid_params }}, out.effects());
    out = .{};
    t.step(.{ .asked = .{ .origin = .request, .mode = .form, .eid = false, .readable = false } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .reject = .invalid_params }}, out.effects());
    for (0..max_pending) |_| {
        out = .{};
        t.step(.{ .asked = .{ .origin = .request, .mode = .form, .eid = false, .readable = true } }, &out);
    }
    out = .{};
    t.step(.{ .asked = .{ .origin = .request, .mode = .form, .eid = false, .readable = true } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .reject = .too_many }}, out.effects());
    try testing.expectEqual(@as(u32, max_pending + 3), out.n);
}

test "a completion before the host accepts is kept and told the moment it does, once" {
    var t: Table = .init(.{ .url = true });
    var out: Output = .{};
    t.step(.{ .asked = .{ .origin = .request, .mode = .url, .eid = true, .readable = true } }, &out);
    out = .{};
    t.step(.{ .completed = 0 }, &out);
    try testing.expect(!out.ignored and out.effect_count == 0);
    out = .{};
    t.step(.{ .answered = .{ .slot = 0, .action = .accept, .valid = false } }, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .send = .{ .slot = 0, .action = .accept, .content = false } }, .{ .complete = 0 }, .{ .release = 0 } }, out.effects());
    out = .{};
    t.step(.{ .completed = 0 }, &out);
    try testing.expect(out.ignored and out.effect_count == 0);
}

test "an accepted url elicitation waits for its completion, told once" {
    var t: Table = .init(.{ .url = true });
    var out: Output = .{};
    t.step(.{ .asked = .{ .origin = .request, .mode = .url, .eid = true, .readable = true } }, &out);
    out = .{};
    t.step(.{ .answered = .{ .slot = 0, .action = .accept, .valid = false } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .send = .{ .slot = 0, .action = .accept, .content = false } }}, out.effects());
    try testing.expectEqual(Phase.waiting, t.slots[0].phase);
    out = .{};
    t.step(.{ .completed = 0 }, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .complete = 0 }, .{ .release = 0 } }, out.effects());
    out = .{};
    t.step(.{ .completed = 0 }, &out);
    try testing.expect(out.ignored and out.effect_count == 0);
}

test "a server's cancel and the session's end withdraw what the host holds" {
    var t: Table = .init(.{ .form = true, .url = true });
    var out: Output = .{};
    for (0..3) |i| {
        out = .{};
        t.step(.{ .asked = if (i == 1)
            .{ .origin = .required, .mode = .url, .eid = true, .readable = true }
        else
            .{ .origin = .request, .mode = .form, .eid = false, .readable = true } }, &out);
    }
    out = .{};
    t.step(.{ .server_cancelled = 1 }, &out);
    try testing.expect(out.ignored); // a -32042 one has no request to cancel
    out = .{};
    t.step(.{ .server_cancelled = 0 }, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .withdraw = 0 }, .{ .release = 0 } }, out.effects());
    out = .{};
    t.step(.{ .answered = .{ .slot = 1, .action = .accept, .valid = true } }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count); // required: nothing to send, waits
    out = .{};
    t.step(.session_ended, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .release = 1 }, .{ .withdraw = 2 }, .{ .release = 2 } }, out.effects());
    out = .{};
    t.step(.session_ended, &out);
    try testing.expectEqualStrings("", out.action);
}

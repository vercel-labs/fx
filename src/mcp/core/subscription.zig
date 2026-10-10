//! Subscriptions (2026): one server's subscriptions, as one state machine.
//! The caller owns the listen requests, whose ids come from the request table
//! as kind `listen` (no timeouts), and the transport: it opens with
//! `opened` after `canOpen`, and answers `relisten` with `resent`.

const std = @import("std");
const trace = @import("../io/trace.zig");
const request = @import("request.zig");

pub const Id = request.Id;

pub const max_subs = 4;

/// The notification types a filter can ask for, as bits (`bit`): the
/// list-changed fields of `subscriptions/listen`.
pub const Kind = enum(u2) { tools, prompts, resources };
pub const Filter = u8;

pub fn bit(kind: Kind) Filter {
    return @as(Filter, 1) << @intFromEnum(kind);
}

pub const Phase = enum { off, pending, active, waiting, ended };

/// Why a subscription ended for good. The host hears it once.
pub const End = enum { result, refused, server_cancelled, nothing_acknowledged, gave_up };

pub const Config = struct {
    /// Listens in a row that end abruptly before giving up.
    max_tries: u8 = 8,
    /// stdio: listens go out again when the process is back, not after a
    /// timer.
    stdio: bool = false,
};

pub const Event = union(enum) {
    /// The host opened `sub`: a listen asking for `filter` went out with `id`.
    opened: struct { sub: u8, id: Id, filter: Filter },
    /// A `relisten` went out with `id`.
    resent: struct { sub: u8, id: Id },
    cancel: u8,
    acknowledged: struct { id: Id, filter: Filter },
    notified: struct { id: Id, kind: Kind },
    /// A result, a JSON-RPC error, or the server's `notifications/cancelled`
    /// for the listen `id`.
    final: struct { id: Id, end: End },
    /// HTTP: the listen's stream closed without a result.
    lost: Id,
    /// HTTP: the backoff timer armed by `arm_retry`.
    retry_due: struct { sub: u8, generation: u32 },
    /// stdio: the process exited, or came back.
    transport_down,
    transport_up,
};

pub const Effect = union(enum) {
    deliver: struct { sub: u8, kind: Kind },
    /// `filter` is what the server agreed to send.
    acknowledged: struct { sub: u8, filter: Filter },
    ended: struct { sub: u8, end: End },
    /// Close the listen's stream (HTTP), or send `notifications/cancelled`
    /// for it (stdio).
    cancel_listen: Id,
    arm_retry: struct { sub: u8, generation: u32, after_ms: u32 },
    /// Send a new listen for `sub`, then step `resent`.
    relisten: u8,
};

pub const Output = struct {
    effect_buffer: [2 * max_subs]Effect = undefined,
    effect_count: usize = 0,
    /// The model action, "" for a step that is none (a backoff timer).
    action: []const u8 = "",
    ignored: bool = false,
    sub: ?u8 = null,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn push(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Sub = struct {
    phase: Phase = .off,
    id: Id = 0,
    asked: Filter = 0,
    acked: Filter = 0,
    tries: u8 = 0,
    /// Names the backoff timer; a newer abrupt end makes it stale.
    generation: u32 = 0,
};

pub const Table = struct {
    config: Config,
    subs: [max_subs]Sub = @splat(.{}),
    /// stdio: the process is running.
    up: bool = true,

    pub fn init(config: Config) Table {
        return .{ .config = config };
    }

    /// Whether `sub` may be opened now: never while it listens, nor while
    /// the stdio process is down.
    pub fn canOpen(t: *const Table, sub: u8) bool {
        if (sub >= max_subs) return false;
        const phase = t.subs[sub].phase;
        return (phase == .off or phase == .ended) and (!t.config.stdio or t.up);
    }

    /// stdio: a subscription waits for the process to come back. Restarts
    /// are on demand, so the host starts it.
    pub fn waiting(t: *const Table) bool {
        for (t.subs) |s| if (s.phase == .waiting) return true;
        return false;
    }

    pub fn step(t: *Table, event: Event, out: *Output) void {
        out.* = .{};
        switch (event) {
            .opened => |o| {
                out.action = "open";
                out.sub = o.sub;
                if (!t.canOpen(o.sub) or o.filter == 0) return ignore(out);
                t.subs[o.sub].tries = 0;
                t.listen(o.sub, o.id, o.filter);
            },
            .resent => |r| {
                out.action = "resend";
                out.sub = r.sub;
                if (r.sub >= max_subs or t.subs[r.sub].phase != .waiting or (t.config.stdio and !t.up)) return ignore(out);
                t.listen(r.sub, r.id, t.subs[r.sub].asked);
            },
            .cancel => |sub| {
                out.action = "cancel";
                out.sub = sub;
                if (sub >= max_subs) return ignore(out);
                const s = &t.subs[sub];
                switch (s.phase) {
                    .pending, .active => out.push(.{ .cancel_listen = s.id }),
                    // A backoff timer still armed finds it no longer waiting.
                    .waiting => {},
                    .off, .ended => return ignore(out),
                }
                s.phase = .off;
            },
            .acknowledged => |a| {
                out.action = "ack";
                const sub = t.current(a.id, .pending) orelse return ignore(out);
                out.sub = sub;
                const s = &t.subs[sub];
                // What was asked and acknowledged; more is
                // never delivered. Nothing of it ends the listen.
                const agreed = a.filter & s.asked;
                if (agreed == 0) {
                    out.push(.{ .cancel_listen = s.id });
                    return t.end(sub, .nothing_acknowledged, out);
                }
                s.phase = .active;
                s.acked = agreed;
                s.tries = 0;
                out.push(.{ .acknowledged = .{ .sub = sub, .filter = agreed } });
            },
            .notified => |n| {
                out.action = "note";
                // Only to the subscription whose listen it
                // names, after the acknowledgment, inside what was agreed.
                const sub = t.current(n.id, .active) orelse return ignore(out);
                if (t.subs[sub].acked & bit(n.kind) == 0) return ignore(out);
                out.sub = sub;
                out.push(.{ .deliver = .{ .sub = sub, .kind = n.kind } });
            },
            .final => |f| {
                out.action = "final";
                const sub = t.current(f.id, .pending) orelse t.current(f.id, .active) orelse return ignore(out);
                out.sub = sub;
                t.end(sub, f.end, out);
            },
            .lost => |id| {
                out.action = "lost";
                if (t.config.stdio) return ignore(out);
                const sub = t.current(id, .pending) orelse t.current(id, .active) orelse return ignore(out);
                out.sub = sub;
                t.abrupt(sub, out);
            },
            .retry_due => |r| {
                // Not a model action: the timer only asks for the resend.
                if (r.sub >= max_subs or t.config.stdio) return;
                const s = t.subs[r.sub];
                if (s.phase == .waiting and s.generation == r.generation) out.push(.{ .relisten = r.sub });
            },
            .transport_down => {
                out.action = "crash";
                if (!t.config.stdio or !t.up) return ignore(out);
                t.up = false;
                for (&t.subs, 0..) |*s, i| if (s.phase == .pending or s.phase == .active) t.abrupt(@intCast(i), out);
            },
            .transport_up => {
                out.action = "restart";
                if (!t.config.stdio or t.up) return ignore(out);
                t.up = true;
                // Every listen the exit ended goes out again.
                for (t.subs, 0..) |s, i| if (s.phase == .waiting) out.push(.{ .relisten = @intCast(i) });
            },
        }
    }

    fn current(t: *const Table, id: Id, phase: Phase) ?u8 {
        for (t.subs, 0..) |s, i| if (s.phase == phase and s.id == id) return @intCast(i);
        return null;
    }

    fn listen(t: *Table, sub: u8, id: Id, filter: Filter) void {
        const s = &t.subs[sub];
        s.phase = .pending;
        s.id = id;
        s.asked = filter;
        s.acked = 0;
    }

    fn end(t: *Table, sub: u8, why: End, out: *Output) void {
        t.subs[sub].phase = .ended;
        out.push(.{ .ended = .{ .sub = sub, .end = why } });
    }

    /// Wait to listen again (after the reconnect delay on HTTP), or give up.
    fn abrupt(t: *Table, sub: u8, out: *Output) void {
        const s = &t.subs[sub];
        if (s.tries >= t.config.max_tries) return t.end(sub, .gave_up, out);
        s.phase = .waiting;
        s.generation +%= 1;
        if (!t.config.stdio) out.push(.{ .arm_retry = .{ .sub = sub, .generation = s.generation, .after_ms = request.reconnectDelay(s.tries) } });
        s.tries += 1;
    }

    fn ignore(out: *Output) void {
        out.ignored = true;
    }
};

/// Writes the step as one trace line for machine "subscription". The whole
/// table goes in packed ints, 4 bits a subscription: phases, tries, and
/// acknowledged filters; subscriptions are numbered from 1.
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, t: *const Table, event: Event, out: *const Output) std.Io.Writer.Error!void {
    if (out.action.len == 0) return;
    var phases: i64 = 0;
    var tries: i64 = 0;
    var acked: i64 = 0;
    for (t.subs, 0..) |s, i| {
        const shift: u6 = @intCast(4 * i);
        phases |= @as(i64, @intFromEnum(s.phase)) << shift;
        tries |= @as(i64, @min(s.tries, 15)) << shift;
        acked |= @as(i64, s.acked) << shift;
    }
    const sub = if (out.sub) |s| @as(i64, s) + 1 else 0;
    const id: Id = switch (event) {
        .opened => |o| o.id,
        .resent => |r| r.id,
        .acknowledged => |a| a.id,
        .notified => |n| n.id,
        .final => |f| f.id,
        .lost => |l| l,
        else => 0,
    };
    try writer.write(.{
        .machine = "subscription",
        .instance = instance,
        .event = out.action,
        .from = "",
        .to = "",
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },
            .{ .name = "sub", .value = .{ .int = sub } },
            // TLC's integers are 32-bit; listen ids stay far below.
            .{ .name = "id", .value = .{ .int = @intCast(@min(id, 1 << 30)) } },
            .{ .name = "filter", .value = .{ .int = switch (event) {
                .opened => |o| o.filter,
                .acknowledged => |a| a.filter,
                .notified => |n| bit(n.kind),
                else => 0,
            } } },
            .{ .name = "phases", .value = .{ .int = phases } },
            .{ .name = "tries", .value = .{ .int = tries } },
            .{ .name = "acked", .value = .{ .int = acked } },
            .{ .name = "up", .value = .{ .boolean = t.up } },
        },
    });
}

// ---------------------------------------------------------------------------
// Tests. The model's ghosts are kept beside the table, and its invariants are
// checked after every step of every event sequence to a small depth, over
// both transports. Subscription 0 asks for tools, 1 for tools and prompts.

const testing = std.testing;

const asks = [_]Filter{ bit(.tools), bit(.tools) | bit(.prompts) };
const max_ids = 8;

const World = struct {
    next: Id = 1,
    owner: [max_ids]u8 = @splat(255),
    ack_seen: [max_ids]bool = @splat(false),
    allowed: [max_ids]Filter = @splat(0),
    over: [max_ids]bool = @splat(false),
    final: [max_ids]bool = @splat(false),
    told: [max_ids]u8 = @splat(0),

    fn check(w: *World, t: *const Table, before: Table, event: Event, out: *const Output) !void {
        // The ghosts follow what was sent and what the server sent.
        switch (event) {
            .opened => |o| if (!out.ignored) {
                try testing.expect(!t.config.stdio or before.up); // NoSendWhileDown
                w.owner[o.id] = o.sub;
            },
            .resent => |r| if (!out.ignored) {
                try testing.expect(!t.config.stdio or before.up); // NoSendWhileDown
                try testing.expect(!w.final[before.subs[r.sub].id]); // NoRelistenAfterFinal
                w.owner[r.id] = r.sub;
            },
            .acknowledged => |a| if (!out.ignored) {
                w.ack_seen[a.id] = true;
                w.allowed[a.id] = asks[w.owner[a.id]] & a.filter;
            },
            // The world ends these listens whatever the client does.
            .lost => |id| if (!before.config.stdio and w.owner[id] != 255) {
                w.over[id] = true;
            },
            .transport_down => if (before.config.stdio and before.up) for (before.subs) |b| {
                if (b.phase == .pending or b.phase == .active) w.over[b.id] = true;
            },
            else => {},
        }
        for (out.effects()) |effect| switch (effect) {
            .deliver => |d| {
                const id = event.notified.id;
                try testing.expectEqual(w.owner[id], d.sub); // SubDemux
                try testing.expect(w.ack_seen[id]); // AckFirst
                try testing.expect(w.allowed[id] & bit(d.kind) != 0); // FilterRespected
                try testing.expect(!w.over[id]); // NothingAfterEnd
            },
            .ended => |e| {
                const id = t.subs[e.sub].id;
                w.told[id] += 1;
                try testing.expect(w.told[id] <= 1); // OneEnd
                w.over[id] = true;
                if (e.end != .gave_up) w.final[id] = true;
            },
            .cancel_listen => |id| w.over[id] = true,
            // Only a subscription waiting to listen again does.
            .relisten => |sub| try testing.expectEqual(Phase.waiting, t.subs[sub].phase),
            .arm_retry, .acknowledged => {},
        };
        for (before.subs, t.subs) |b, s| {
            // A listen that stopped listening is over.
            if ((b.phase == .pending or b.phase == .active) and s.phase != b.phase and s.phase != .active) w.over[b.id] = true;
            // ActiveListensForSomething, EndTold, and the bound on tries.
            if (s.phase == .active) try testing.expect(s.acked != 0);
            if (s.phase == .ended) try testing.expectEqual(@as(u8, 1), w.told[s.id]);
            try testing.expect(s.tries <= t.config.max_tries);
        }
        // Where the model has no choice, the core must act.
        switch (event) {
            .final => |f| if (before.current(f.id, .pending) orelse before.current(f.id, .active)) |sub| {
                try testing.expectEqual(Phase.ended, t.subs[sub].phase);
            },
            .acknowledged => |a| if (before.current(a.id, .pending)) |sub| {
                try testing.expect(t.subs[sub].phase == .active or t.subs[sub].phase == .ended);
            },
            .transport_up => if (before.config.stdio and !before.up) {
                var waiting: usize = 0;
                for (t.subs) |s| waiting += @intFromBool(s.phase == .waiting);
                try testing.expectEqual(waiting, out.effect_count);
            },
            else => {},
        }
    }
};

fn alphabet(w: *const World) [24]Event {
    const id = w.next;
    return .{
        .{ .opened = .{ .sub = 0, .id = id, .filter = asks[0] } },
        .{ .opened = .{ .sub = 1, .id = id, .filter = asks[1] } },
        .{ .resent = .{ .sub = 0, .id = id } },
        .{ .resent = .{ .sub = 1, .id = id } },
        .{ .cancel = 0 },
        .{ .cancel = 1 },
        .{ .acknowledged = .{ .id = 1, .filter = bit(.tools) } },
        .{ .acknowledged = .{ .id = 1, .filter = bit(.prompts) } },
        .{ .acknowledged = .{ .id = 2, .filter = bit(.tools) | bit(.prompts) } },
        .{ .acknowledged = .{ .id = 2, .filter = 0 } },
        .{ .acknowledged = .{ .id = 3, .filter = bit(.tools) } },
        .{ .notified = .{ .id = 1, .kind = .tools } },
        .{ .notified = .{ .id = 2, .kind = .prompts } },
        .{ .notified = .{ .id = 2, .kind = .tools } },
        .{ .notified = .{ .id = 3, .kind = .tools } },
        .{ .final = .{ .id = 1, .end = .result } },
        .{ .final = .{ .id = 2, .end = .server_cancelled } },
        .{ .lost = 1 },
        .{ .lost = 2 },
        .{ .lost = 3 },
        .{ .retry_due = .{ .sub = 0, .generation = 1 } },
        .{ .retry_due = .{ .sub = 1, .generation = 2 } },
        .transport_down,
        .transport_up,
    };
}

fn explore(t: Table, w: World, depth: u8, steps: *usize) !void {
    if (depth == 0) return;
    for (alphabet(&w)) |event| {
        var child = t;
        var cw = w;
        var out: Output = .{};
        child.step(event, &out);
        steps.* += 1;
        try cw.check(&child, t, event, &out);
        if ((event == .opened or event == .resent) and !out.ignored) {
            if (cw.next + 1 >= max_ids) continue;
            cw.next += 1;
        }
        try explore(child, cw, depth - 1, steps);
    }
}

test "every event sequence to depth 5 keeps the model's invariants, on HTTP and stdio" {
    for ([_]bool{ false, true }) |stdio| {
        var steps: usize = 0;
        try explore(.init(.{ .max_tries = 1, .stdio = stdio }), .{}, 5, &steps);
        try testing.expect(steps > 1_000_000);
    }
}

test "random long sequences keep the model's invariants" {
    var prng: std.Random.DefaultPrng = .init(0x5eb5);
    const random = prng.random();
    for (0..400) |round| {
        var t: Table = .init(.{ .max_tries = 2, .stdio = round % 2 == 1 });
        var w: World = .{};
        for (0..40) |_| {
            const events = alphabet(&w);
            const event = events[random.uintLessThan(usize, events.len)];
            const before = t;
            var out: Output = .{};
            t.step(event, &out);
            try w.check(&t, before, event, &out);
            if ((event == .opened or event == .resent) and !out.ignored) {
                if (w.next + 1 >= max_ids) break;
                w.next += 1;
            }
        }
    }
}

test "a listen is acknowledged, delivers what was agreed, and ends once" {
    var t: Table = .init(.{});
    var out: Output = .{};
    t.step(.{ .opened = .{ .sub = 0, .id = 7, .filter = bit(.tools) } }, &out);
    // Before the acknowledgment nothing is delivered.
    t.step(.{ .notified = .{ .id = 7, .kind = .tools } }, &out);
    try testing.expect(out.ignored);
    // An acknowledgment naming more than was asked agrees to the overlap.
    t.step(.{ .acknowledged = .{ .id = 7, .filter = bit(.tools) | bit(.prompts) } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .acknowledged = .{ .sub = 0, .filter = bit(.tools) } }}, out.effects());
    t.step(.{ .notified = .{ .id = 7, .kind = .prompts } }, &out);
    try testing.expect(out.ignored);
    t.step(.{ .notified = .{ .id = 8, .kind = .tools } }, &out);
    try testing.expect(out.ignored);
    t.step(.{ .notified = .{ .id = 7, .kind = .tools } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .sub = 0, .kind = .tools } }}, out.effects());
    t.step(.{ .final = .{ .id = 7, .end = .result } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .ended = .{ .sub = 0, .end = .result } }}, out.effects());
    t.step(.{ .final = .{ .id = 7, .end = .result } }, &out);
    try testing.expect(out.ignored);
}

test "an acknowledgment of nothing asked cancels the listen" {
    var t: Table = .init(.{});
    var out: Output = .{};
    t.step(.{ .opened = .{ .sub = 1, .id = 3, .filter = bit(.tools) } }, &out);
    t.step(.{ .acknowledged = .{ .id = 3, .filter = bit(.prompts) } }, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .cancel_listen = 3 }, .{ .ended = .{ .sub = 1, .end = .nothing_acknowledged } } }, out.effects());
}

test "an abrupt end listens again after the reconnect delay, and gives up after max_tries" {
    var t: Table = .init(.{ .max_tries = 2 });
    var out: Output = .{};
    t.step(.{ .opened = .{ .sub = 0, .id = 1, .filter = bit(.tools) } }, &out);
    t.step(.{ .lost = 1 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .arm_retry = .{ .sub = 0, .generation = 1, .after_ms = 1000 } }}, out.effects());
    // A stale timer asks for nothing.
    t.step(.{ .retry_due = .{ .sub = 0, .generation = 0 } }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    t.step(.{ .retry_due = .{ .sub = 0, .generation = 1 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .relisten = 0 }}, out.effects());
    t.step(.{ .resent = .{ .sub = 0, .id = 2 } }, &out);
    t.step(.{ .lost = 2 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .arm_retry = .{ .sub = 0, .generation = 2, .after_ms = 2000 } }}, out.effects());
    t.step(.{ .resent = .{ .sub = 0, .id = 3 } }, &out);
    t.step(.{ .lost = 3 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .ended = .{ .sub = 0, .end = .gave_up } }}, out.effects());
    // An acknowledgment in between starts the count over.
    t.step(.{ .opened = .{ .sub = 0, .id = 4, .filter = bit(.tools) } }, &out);
    t.step(.{ .lost = 4 }, &out);
    t.step(.{ .resent = .{ .sub = 0, .id = 5 } }, &out);
    t.step(.{ .acknowledged = .{ .id = 5, .filter = bit(.tools) } }, &out);
    try testing.expectEqual(@as(u8, 0), t.subs[0].tries);
}

test "on stdio, a process exit ends every listen, and they go out again when it is back" {
    var t: Table = .init(.{ .stdio = true });
    var out: Output = .{};
    t.step(.{ .opened = .{ .sub = 0, .id = 1, .filter = bit(.tools) } }, &out);
    t.step(.{ .opened = .{ .sub = 1, .id = 2, .filter = bit(.tools) } }, &out);
    t.step(.{ .acknowledged = .{ .id = 2, .filter = bit(.tools) } }, &out);
    t.step(.transport_down, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expect(!t.canOpen(2));
    t.step(.{ .resent = .{ .sub = 0, .id = 3 } }, &out);
    try testing.expect(out.ignored);
    t.step(.transport_up, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .relisten = 0 }, .{ .relisten = 1 } }, out.effects());
    // A cancel sends the transport's cancel for a listen in flight.
    t.step(.{ .resent = .{ .sub = 0, .id = 3 } }, &out);
    t.step(.{ .cancel = 0 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .cancel_listen = 3 }}, out.effects());
}

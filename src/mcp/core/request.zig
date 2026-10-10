//! Request lifecycle core. Each step reports one transition for the trace.
//!
//! Pure: no I/O, no clock, no allocation, no globals. The caller owns the slot
//! storage, runs the returned effects, and turns armed timers into
//! `timer_fired` events.
//!
//! A finished request leaves the table. Because ids are never reused,
//! any issued id that is no longer in the table is done, so late and
//! duplicate messages for it are recognized and ignored. Responses without an
//! id can't be correlated; the I/O layer logs them and the request still
//! ends through its timeout.

const std = @import("std");
const trace = @import("../io/trace.zig");
const wire = @import("../protocol/wire.zig");

/// Request ids are allocated from 1 and never reused on a connection.
/// A request's progress token equals its id, which keeps tokens unique among
/// active requests.
pub const Id = wire.RequestId;

/// A listen (`subscriptions/listen`) has no timeouts, and a
/// server's `notifications/cancelled` ends it.
pub const Kind = enum { normal, initialize, listen };

/// The model's status of an id.
pub const Status = enum { unused, inflight, done };

pub const Outcome = enum {
    none,
    result,
    peer_error,
    cancelled,
    timed_out,
    lost,
    /// A listen the server ended with `notifications/cancelled`.
    ended,

    /// The outcome's name in the trace.
    pub fn modelName(outcome: Outcome) []const u8 {
        return switch (outcome) {
            .peer_error => "error",
            else => @tagName(outcome),
        };
    }
};

pub const PeerResponse = enum {
    result,
    peer_error,

    pub fn modelName(response: PeerResponse) []const u8 {
        return switch (response) {
            .result => "result",
            .peer_error => "error",
        };
    }
};

/// The default timeouts. The idle timer is re-armed by the request's own progress;
/// the hard timer never is.
pub const Timeouts = struct {
    idle_ms: u32 = 60_000,
    hard_ms: u32 = 600_000,
    reset_idle_on_progress: bool = true,
};

/// Reconnect delays double from 1 s up to 30 s.
pub fn reconnectDelay(attempt: u32) u32 {
    return @min(@as(u32, 30_000), @as(u32, 1000) << @intCast(@min(attempt, 5)));
}

pub const TimerKind = enum { idle, hard };

pub const Timer = struct {
    id: Id,
    kind: TimerKind,
    /// Idle timers are re-armed on progress, and only the newest generation
    /// counts. Hard timers always have generation 0.
    generation: u32,
};

pub const Event = union(enum) {
    send: Kind,
    response_received: struct { id: Id, response: PeerResponse },
    cancel_requested: Id,
    timer_fired: Timer,
    transport_lost: Id,
    progress_received: struct { token: Id, value: f64 },
    server_cancel_received: Id,
    /// The host holds a question from this server, which a 2025 server
    /// asks outside the request, so the request's idle timer waits for it.
    idle_paused: Id,
    /// The questions are answered; a full idle period starts.
    idle_resumed: Id,
};

pub const Effect = union(enum) {
    /// Write the request message with this id and progress token.
    write_request: struct { id: Id, kind: Kind },
    /// Signal cancellation the transport's way: `notifications/cancelled` on
    /// stdio and 2025 HTTP, closing the stream on 2026 HTTP.
    send_cancel: Id,
    /// Hand the outcome to the caller. Happens exactly once per request.
    deliver: struct { id: Id, outcome: Outcome },
    arm_timer: struct { timer: Timer, after_ms: u32 },
    disarm_timers: Id,
};

/// The id's model state after a step: outcome, delivered, cancelSent, and
/// progress (the number of accepted progress notifications).
pub const Projection = struct {
    outcome: Outcome,
    delivered: u8,
    cancel_sent: bool,
    progress: u32,
};

/// One model step, written to the trace by `writeTrace`.
pub const Transition = struct {
    /// The model action, in snake_case.
    event: []const u8,
    id: Id,
    from: Status,
    to: Status,
    kind: ?Kind = null,
    response: ?PeerResponse = null,
    /// Present while the id's state is known: in flight, or finishing now.
    state: ?Projection = null,
};

pub const max_effects = 4;

pub const Output = struct {
    effect_buffer: [max_effects]Effect = undefined,
    effect_count: usize = 0,
    transition: ?Transition = null,

    pub fn effects(output: *const Output) []const Effect {
        return output.effect_buffer[0..output.effect_count];
    }

    fn push(output: *Output, effect: Effect) void {
        std.debug.assert(output.effect_count < max_effects);
        output.effect_buffer[output.effect_count] = effect;
        output.effect_count += 1;
    }
};

pub const Slot = struct {
    used: bool = false,
    id: Id = 0,
    kind: Kind = .normal,
    progress_count: u32 = 0,
    last_progress: f64 = 0,
    idle_generation: u32 = 0,
    /// No idle timer runs, only the hard one.
    idle_paused: bool = false,
};

pub const StepError = error{
    /// Every slot holds a request in flight.
    TooManyInFlight,
    /// The client never cancels initialize.
    InitializeNotCancellable,
    IdsExhausted,
};

pub const Table = struct {
    slots: []Slot,
    timeouts: Timeouts,
    next_id: Id = 1,

    /// `slots` is caller-owned storage; its length is the in-flight limit.
    pub fn init(slots: []Slot, timeouts: Timeouts) Table {
        @memset(slots, .{});
        return .{ .slots = slots, .timeouts = timeouts };
    }

    pub fn status(table: *const Table, id: Id) Status {
        if (id == 0 or id >= table.next_id) return .unused;
        return if (table.indexOf(id) != null) .inflight else .done;
    }

    pub fn inFlightCount(table: *const Table) usize {
        var count: usize = 0;
        for (table.slots) |slot| count += @intFromBool(slot.used);
        return count;
    }

    /// Applies one event. Resets `out` first. Errors leave the table unchanged.
    pub fn step(table: *Table, event: Event, out: *Output) StepError!void {
        out.* = .{};
        switch (event) {
            .send => |kind| try table.send(kind, out),
            .response_received => |r| table.respond(r.id, r.response, out),
            .cancel_requested => |id| try table.cancel(id, out),
            .timer_fired => |timer| table.timerFired(timer, out),
            .transport_lost => |id| table.lose(id, out),
            .progress_received => |p| table.progressReceived(p.token, p.value, out),
            .server_cancel_received => |id| table.serverCancel(id, out),
            .idle_paused => |id| table.pauseIdle(id, true, out),
            .idle_resumed => |id| table.pauseIdle(id, false, out),
        }
    }

    fn indexOf(table: *const Table, id: Id) ?usize {
        for (table.slots, 0..) |slot, index| {
            if (slot.used and slot.id == id) return index;
        }
        return null;
    }

    fn send(table: *Table, kind: Kind, out: *Output) StepError!void {
        const index = for (table.slots, 0..) |slot, i| {
            if (!slot.used) break i;
        } else return error.TooManyInFlight;
        const id = table.next_id;
        if (id > wire.max_request_id) return error.IdsExhausted;
        table.next_id = id + 1;
        table.slots[index] = .{ .used = true, .id = id, .kind = kind, .idle_generation = 1 };
        out.push(.{ .write_request = .{ .id = id, .kind = kind } });
        if (kind != .listen) {
            out.push(.{ .arm_timer = .{ .timer = .{ .id = id, .kind = .idle, .generation = 1 }, .after_ms = table.timeouts.idle_ms } });
            out.push(.{ .arm_timer = .{ .timer = .{ .id = id, .kind = .hard, .generation = 0 }, .after_ms = table.timeouts.hard_ms } });
        }
        out.transition = .{
            .event = "send",
            .id = id,
            .from = .unused,
            .to = .inflight,
            .kind = kind,
            .state = projection(table.slots[index]),
        };
    }

    /// Ends the request in `index` and frees its slot.
    fn finish(table: *Table, index: usize, event: []const u8, outcome: Outcome, signal_cancel: bool, out: *Output) void {
        const slot = table.slots[index];
        if (signal_cancel) out.push(.{ .send_cancel = slot.id });
        out.push(.{ .disarm_timers = slot.id });
        out.push(.{ .deliver = .{ .id = slot.id, .outcome = outcome } });
        out.transition = .{
            .event = event,
            .id = slot.id,
            .from = .inflight,
            .to = .done,
            .kind = slot.kind,
            .state = .{ .outcome = outcome, .delivered = 1, .cancel_sent = signal_cancel, .progress = slot.progress_count },
        };
        table.slots[index] = .{};
    }

    /// A step that changes nothing: the model's ignore branches.
    fn ignore(table: *const Table, event: []const u8, id: Id, out: *Output) void {
        const current = table.status(id);
        out.transition = .{
            .event = event,
            .id = id,
            .from = current,
            .to = current,
            .state = if (table.indexOf(id)) |index| projection(table.slots[index]) else null,
        };
    }

    /// Only a request in flight takes a response; late, duplicate,
    /// and unknown-id responses are ignored.
    fn respond(table: *Table, id: Id, response: PeerResponse, out: *Output) void {
        if (table.indexOf(id)) |index| {
            table.finish(index, "response_received", switch (response) {
                .result => .result,
                .peer_error => .peer_error,
            }, false, out);
        } else {
            table.ignore("response_received", id, out);
        }
        out.transition.?.response = response;
    }

    /// A cancel signal goes only to a request believed in flight.
    fn cancel(table: *Table, id: Id, out: *Output) StepError!void {
        const index = table.indexOf(id) orelse return table.ignore("cancel_requested", id, out);
        if (table.slots[index].kind == .initialize) return error.InitializeNotCancellable;
        table.finish(index, "cancel_requested", .cancelled, true, out);
    }

    /// A server's cancel ends only a listen in flight.
    fn serverCancel(table: *Table, id: Id, out: *Output) void {
        const index = table.indexOf(id) orelse return table.ignore("server_cancel_received", id, out);
        if (table.slots[index].kind != .listen) return table.ignore("server_cancel_received", id, out);
        table.finish(index, "server_cancel_received", .ended, false, out);
    }

    /// A current timer ends the request as a local timeout.
    /// Initialize times out without a cancel signal. A
    /// listen arms none, so any timer for it is stale.
    fn timerFired(table: *Table, timer: Timer, out: *Output) void {
        const index = table.indexOf(timer.id) orelse return table.ignore("timer_fired", timer.id, out);
        const slot = table.slots[index];
        if (slot.kind == .listen or (timer.kind == .idle and timer.generation != slot.idle_generation)) {
            return table.ignore("timer_fired", timer.id, out);
        }
        table.finish(index, "timer_fired", .timed_out, slot.kind != .initialize, out);
    }

    /// Pausing makes the armed idle timer stale, and resuming arms a
    /// new one; the hard timer is untouched. Time is abstract in the model, so
    /// neither is a transition.
    fn pauseIdle(table: *Table, id: Id, pause: bool, out: *Output) void {
        const index = table.indexOf(id) orelse return;
        const slot = &table.slots[index];
        if (slot.kind == .listen or slot.idle_paused == pause) return;
        slot.idle_paused = pause;
        slot.idle_generation +%= 1;
        if (!pause) out.push(.{ .arm_timer = .{
            .timer = .{ .id = slot.id, .kind = .idle, .generation = slot.idle_generation },
            .after_ms = table.timeouts.idle_ms,
        } });
    }

    fn lose(table: *Table, id: Id, out: *Output) void {
        const index = table.indexOf(id) orelse return table.ignore("transport_lost", id, out);
        table.finish(index, "transport_lost", .lost, false, out);
    }

    /// Progress counts only for a request in flight and only
    /// when the value increases. Accepted progress re-arms the idle timer.
    fn progressReceived(table: *Table, token: Id, value: f64, out: *Output) void {
        const index = table.indexOf(token) orelse return table.ignore("progress_received", token, out);
        const slot = &table.slots[index];
        if (slot.progress_count > 0 and !(value > slot.last_progress)) {
            return table.ignore("progress_received", token, out);
        }
        slot.progress_count +|= 1;
        slot.last_progress = value;
        if (table.timeouts.reset_idle_on_progress and slot.kind != .listen and !slot.idle_paused) {
            slot.idle_generation +%= 1;
            out.push(.{ .arm_timer = .{
                .timer = .{ .id = slot.id, .kind = .idle, .generation = slot.idle_generation },
                .after_ms = table.timeouts.idle_ms,
            } });
        }
        out.transition = .{
            .event = "progress_received",
            .id = slot.id,
            .from = .inflight,
            .to = .inflight,
            .state = projection(slot.*),
        };
    }
};

fn projection(slot: Slot) Projection {
    return .{ .outcome = .none, .delivered = 0, .cancel_sent = false, .progress = slot.progress_count };
}

/// Writes the step in `out` as one trace line for machine "request".
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    const t = out.transition orelse return;
    var fields: [7]trace.Field = undefined;
    var count: usize = 0;
    fields[count] = .{ .name = "id", .value = .{ .int = @intCast(t.id) } };
    count += 1;
    if (t.kind) |kind| {
        fields[count] = .{ .name = "kind", .value = .{ .string = @tagName(kind) } };
        count += 1;
    }
    if (t.response) |response| {
        fields[count] = .{ .name = "response", .value = .{ .string = response.modelName() } };
        count += 1;
    }
    if (t.state) |state| {
        fields[count] = .{ .name = "outcome", .value = .{ .string = state.outcome.modelName() } };
        fields[count + 1] = .{ .name = "delivered", .value = .{ .int = state.delivered } };
        fields[count + 2] = .{ .name = "cancel_sent", .value = .{ .boolean = state.cancel_sent } };
        fields[count + 3] = .{ .name = "progress", .value = .{ .int = state.progress } };
        count += 4;
    }
    var effect_names: [max_effects][]const u8 = undefined;
    for (out.effects(), 0..) |effect, index| effect_names[index] = @tagName(effect);
    try writer.write(.{
        .machine = "request",
        .instance = instance,
        .event = t.event,
        .from = @tagName(t.from),
        .to = @tagName(t.to),
        .effects = effect_names[0..out.effect_count],
        .data = fields[0..count],
    });
}

const testing = std.testing;

fn countEffects(out: *const Output, tag: std.meta.Tag(Effect)) usize {
    var count: usize = 0;
    for (out.effects()) |effect| count += @intFromBool(effect == tag);
    return count;
}

fn deliveredOutcome(out: *const Output) ?Outcome {
    for (out.effects()) |effect| switch (effect) {
        .deliver => |d| return d.outcome,
        else => {},
    };
    return null;
}

test "ids stop at the JSON-safe limit" {
    var slots: [2]Slot = undefined;
    var table: Table = .init(&slots, .{});
    table.next_id = wire.max_request_id;
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try testing.expectEqual(wire.max_request_id, out.effects()[0].write_request.id);
    try testing.expectError(error.IdsExhausted, table.step(.{ .send = .normal }, &out));
}

test "ids are allocated from 1 and never reused" {
    var slots: [2]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try testing.expectEqual(@as(Id, 1), out.transition.?.id);
    try table.step(.{ .response_received = .{ .id = 1, .response = .result } }, &out);
    try table.step(.{ .send = .normal }, &out);
    try testing.expectEqual(@as(Id, 2), out.transition.?.id);
    try testing.expectEqual(Status.done, table.status(1));
    try testing.expectEqual(Status.inflight, table.status(2));
    try testing.expectEqual(Status.unused, table.status(3));

    try table.step(.{ .response_received = .{ .id = 1, .response = .result } }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Status.done, table.status(1));
}

test "late and duplicate responses deliver nothing" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .response_received = .{ .id = 1, .response = .peer_error } }, &out);
    try testing.expectEqual(Outcome.peer_error, deliveredOutcome(&out).?);

    for ([_]Event{
        .{ .response_received = .{ .id = 1, .response = .result } },
        .{ .cancel_requested = 1 },
        .{ .timer_fired = .{ .id = 1, .kind = .hard, .generation = 0 } },
        .{ .transport_lost = 1 },
        .{ .progress_received = .{ .token = 1, .value = 5 } },
    }) |late| {
        try table.step(late, &out);
        try testing.expectEqual(@as(usize, 0), out.effect_count);
        try testing.expectEqual(Status.done, out.transition.?.to);
    }
}

test "a timeout is a local outcome, never a peer error" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .hard, .generation = 0 } }, &out);
    try testing.expectEqual(Outcome.timed_out, deliveredOutcome(&out).?);
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .send_cancel));
}

test "a server cancellation never ends a client request" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .server_cancel_received = 1 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Status.inflight, table.status(1));
}

test "a listen arms no timers, outlives any timer, and a server's cancel ends it" {
    var slots: [2]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};
    try table.step(.{ .send = .listen }, &out);
    try testing.expectEqual(@as(usize, 1), out.effects().len);
    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .hard, .generation = 0 } }, &out);
    try testing.expectEqual(Status.inflight, table.status(1));
    try table.step(.{ .progress_received = .{ .token = 1, .value = 1 } }, &out);
    try testing.expectEqual(@as(usize, 0), countEffects(&out, .arm_timer));
    try table.step(.{ .server_cancel_received = 1 }, &out);
    try testing.expectEqual(Outcome.ended, deliveredOutcome(&out).?);
    try testing.expectEqual(@as(usize, 0), countEffects(&out, .send_cancel));
    try testing.expectEqual(@as(u32, 1000), reconnectDelay(0));
    try testing.expectEqual(@as(u32, 16_000), reconnectDelay(4));
    try testing.expectEqual(@as(u32, 30_000), reconnectDelay(9));
}

test "cancel signals go only to requests ended in flight" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .cancel_requested = 7 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .cancel_requested = 1 }, &out);
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .send_cancel));
    try testing.expectEqual(Outcome.cancelled, deliveredOutcome(&out).?);

    try table.step(.{ .cancel_requested = 1 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
}

test "initialize is never cancelled" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .initialize }, &out);
    try testing.expectError(error.InitializeNotCancellable, table.step(.{ .cancel_requested = 1 }, &out));
    try testing.expectEqual(Status.inflight, table.status(1));

    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .hard, .generation = 0 } }, &out);
    try testing.expectEqual(Outcome.timed_out, deliveredOutcome(&out).?);
    try testing.expectEqual(@as(usize, 0), countEffects(&out, .send_cancel));
}

test "a paused idle timer never fires, and resuming arms a full one; the hard timer still runs" {
    var slots: [2]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .idle_paused = 1 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    try testing.expect(out.transition == null);
    // The idle timer armed at send is stale, and progress arms none.
    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .idle, .generation = 1 } }, &out);
    try testing.expectEqual(Status.inflight, table.status(1));
    try table.step(.{ .progress_received = .{ .token = 1, .value = 1 } }, &out);
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    try table.step(.{ .idle_resumed = 1 }, &out);
    try testing.expect(out.transition == null);
    try testing.expectEqual(@as(usize, 1), out.effects().len);
    const armed = out.effects()[0].arm_timer;
    try testing.expectEqual(TimerKind.idle, armed.timer.kind);
    try testing.expectEqual(@as(u32, 60_000), armed.after_ms);
    try table.step(.{ .timer_fired = armed.timer }, &out);
    try testing.expectEqual(Status.done, table.status(1));
    // While paused, the hard timer still ends a request.
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .idle_paused = 2 }, &out);
    try table.step(.{ .timer_fired = .{ .id = 2, .kind = .hard, .generation = 0 } }, &out);
    try testing.expectEqual(Status.done, table.status(2));
}

test "progress counts only in flight and only when it increases; it re-arms only the idle timer" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .progress_received = .{ .token = 1, .value = 0.5 } }, &out);
    try testing.expectEqual(@as(u32, 1), out.transition.?.state.?.progress);
    try testing.expectEqual(@as(u32, 2), out.effects()[0].arm_timer.timer.generation);

    for ([_]f64{ 0.5, 0.2 }) |stale| {
        try table.step(.{ .progress_received = .{ .token = 1, .value = stale } }, &out);
        try testing.expectEqual(@as(usize, 0), out.effect_count);
        try testing.expectEqual(@as(u32, 1), out.transition.?.state.?.progress);
    }

    // The idle timer from before the progress is stale; the current one counts.
    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .idle, .generation = 1 } }, &out);
    try testing.expectEqual(Status.inflight, table.status(1));
    try table.step(.{ .progress_received = .{ .token = 1, .value = 0.7 } }, &out);
    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .hard, .generation = 0 } }, &out);
    try testing.expectEqual(Outcome.timed_out, deliveredOutcome(&out).?);
    try testing.expectEqual(@as(u32, 2), out.transition.?.state.?.progress);

    try table.step(.{ .progress_received = .{ .token = 1, .value = 9 } }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
}

test "the table refuses requests beyond its slots and frees a slot when a request ends" {
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try testing.expectError(error.TooManyInFlight, table.step(.{ .send = .normal }, &out));
    try testing.expectEqual(@as(Id, 2), table.next_id);
    try table.step(.{ .transport_lost = 1 }, &out);
    try testing.expectEqual(Outcome.lost, deliveredOutcome(&out).?);
    try table.step(.{ .send = .normal }, &out);
    try testing.expectEqual(@as(Id, 2), out.transition.?.id);
}

/// What the tests observe from effects alone, to check the model's invariants
/// against the Zig core without looking inside the table.
const Observed = struct {
    const max_ids = 8;
    delivered: [max_ids]u8 = @splat(0),
    cancelled_signal: [max_ids]bool = @splat(false),
    initialize: [max_ids]bool = @splat(false),
    listen: [max_ids]bool = @splat(false),
    highest_sent: Id = 0,

    fn at(id: Id) usize {
        return @intCast(id);
    }

    fn check(observed: *Observed, table: *const Table, event: Event, before: Status, out: *const Output) !void {
        for (out.effects()) |effect| switch (effect) {
            .write_request => |w| {
                // IdsNeverReused: every new id is above all earlier ones.
                try testing.expect(w.id > observed.highest_sent);
                observed.highest_sent = w.id;
                observed.initialize[at(w.id)] = w.kind == .initialize;
                observed.listen[at(w.id)] = w.kind == .listen;
            },
            .deliver => |d| {
                observed.delivered[at(d.id)] += 1;
                // AtMostOneOutcome.
                try testing.expect(observed.delivered[at(d.id)] <= 1);
                // Each outcome comes only from its own event. This covers
                // PeerOutcomesFromPeer (results and peer errors only from a
                // response) and CancelledByClientOnly (cancelled only from the
                // client's cancel), and sends, progress, and server cancels
                // never end a request.
                const allowed: Outcome = switch (event) {
                    .response_received => |r| switch (r.response) {
                        .result => .result,
                        .peer_error => .peer_error,
                    },
                    .cancel_requested => .cancelled,
                    .timer_fired => .timed_out,
                    .transport_lost => .lost,
                    // EndedOnlyListen: a server ends only a listen.
                    .server_cancel_received => |id| if (observed.listen[at(id)]) .ended else .none,
                    // Pausing and resuming the idle timer end nothing.
                    .send, .progress_received, .idle_paused, .idle_resumed => .none,
                };
                try testing.expectEqual(allowed, d.outcome);
                // ListenNeverTimesOut.
                if (observed.listen[at(d.id)]) try testing.expect(d.outcome != .timed_out);
            },
            .send_cancel => |id| {
                // CancelValid and NeverCancelInitialize.
                try testing.expect(before == .inflight);
                try testing.expect(!observed.initialize[at(id)]);
                const outcome = deliveredOutcome(out).?;
                try testing.expect(outcome == .cancelled or outcome == .timed_out);
                observed.cancelled_signal[at(id)] = true;
            },
            // A listen arms no timer.
            .arm_timer => |a| try testing.expect(!observed.listen[at(a.timer.id)]),
            .disarm_timers => {},
        };
        // Where the model has no choice, the core must act: a request in
        // flight ends on its response, a transport loss, a cancel (unless it
        // is initialize), or its hard timeout.
        if (before == .inflight) {
            const expected: ?Outcome = switch (event) {
                .response_received => |r| switch (r.response) {
                    .result => .result,
                    .peer_error => .peer_error,
                },
                .transport_lost => .lost,
                .cancel_requested => |id| if (observed.initialize[at(id)]) null else .cancelled,
                .timer_fired => |timer| if (timer.kind == .hard and !observed.listen[at(timer.id)]) .timed_out else null,
                .server_cancel_received => |id| if (observed.listen[at(id)]) .ended else null,
                else => null,
            };
            if (expected) |outcome| try testing.expectEqual(outcome, deliveredOutcome(out).?);
        }
        // The reported transition agrees with the table.
        if (out.transition) |t| {
            try testing.expectEqual(before, t.from);
            try testing.expectEqual(table.status(t.id), t.to);
            // OutcomeIffDone: a request is done exactly when it was delivered once.
            if (t.id < max_ids) try testing.expectEqual(t.to == .done, observed.delivered[at(t.id)] == 1);
        }
    }
};

fn eventId(event: Event) ?Id {
    return switch (event) {
        .send => null,
        .response_received => |r| r.id,
        .cancel_requested, .transport_lost, .server_cancel_received, .idle_paused, .idle_resumed => |id| id,
        .timer_fired => |t| t.id,
        .progress_received => |p| p.token,
    };
}

const alphabet = [_]Event{
    .{ .idle_paused = 1 },
    .{ .idle_resumed = 1 },
    .{ .send = .normal },
    .{ .send = .initialize },
    .{ .send = .listen },
    .{ .response_received = .{ .id = 1, .response = .result } },
    .{ .response_received = .{ .id = 2, .response = .peer_error } },
    .{ .cancel_requested = 1 },
    .{ .cancel_requested = 2 },
    .{ .timer_fired = .{ .id = 1, .kind = .hard, .generation = 0 } },
    .{ .timer_fired = .{ .id = 2, .kind = .idle, .generation = 1 } },
    .{ .timer_fired = .{ .id = 2, .kind = .idle, .generation = 2 } },
    .{ .transport_lost = 1 },
    .{ .progress_received = .{ .token = 1, .value = 1 } },
    .{ .progress_received = .{ .token = 2, .value = 2 } },
    .{ .server_cancel_received = 1 },
    .{ .server_cancel_received = 2 },
};

fn explore(slots: [2]Slot, next_id: Id, observed: Observed, depth: usize, steps: *usize) !void {
    if (depth == 0) return;
    for (alphabet) |event| {
        var child_slots = slots;
        var table: Table = .{ .slots = &child_slots, .timeouts = .{}, .next_id = next_id };
        var child = observed;
        const before = if (eventId(event)) |id| table.status(id) else Status.unused;
        var out: Output = .{};
        table.step(event, &out) catch |err| switch (err) {
            error.TooManyInFlight, error.InitializeNotCancellable => {
                // A refused step must change nothing.
                for (slots, child_slots) |a, b| try testing.expect(std.meta.eql(a, b));
                continue;
            },
            error.IdsExhausted => return err,
        };
        steps.* += 1;
        try child.check(&table, event, before, &out);
        try explore(child_slots, table.next_id, child, depth - 1, steps);
    }
}

test "every event sequence up to depth 5 keeps the model's invariants" {
    var slots: [2]Slot = undefined;
    @memset(&slots, .{});
    var steps: usize = 0;
    try explore(slots, 1, .{}, 5, &steps);
    try testing.expect(steps > 100_000);
}

test "random long sequences keep the model's invariants" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..300) |_| {
        var slots: [3]Slot = undefined;
        var table: Table = .init(&slots, .{});
        var observed: Observed = .{};
        for (0..60) |_| {
            const id = random.intRangeAtMost(Id, 1, @min(table.next_id, Observed.max_ids - 1));
            const event: Event = switch (random.uintLessThan(u8, 8)) {
                0 => .{ .send = switch (random.uintLessThan(u8, 6)) {
                    0 => .initialize,
                    1 => .listen,
                    else => .normal,
                } },
                1 => .{ .response_received = .{ .id = id, .response = if (random.boolean()) .result else .peer_error } },
                2 => .{ .cancel_requested = id },
                3 => .{ .timer_fired = .{ .id = id, .kind = .hard, .generation = 0 } },
                4 => .{ .timer_fired = .{ .id = id, .kind = .idle, .generation = random.intRangeAtMost(u32, 1, 3) } },
                5 => .{ .transport_lost = id },
                6 => .{ .progress_received = .{ .token = id, .value = @floatFromInt(random.uintLessThan(u8, 4)) } },
                else => .{ .server_cancel_received = id },
            };
            if (event == .send and table.next_id >= Observed.max_ids) continue;
            const before = if (eventId(event)) |event_id| table.status(event_id) else Status.unused;
            var out: Output = .{};
            table.step(event, &out) catch continue;
            try observed.check(&table, event, before, &out);
        }
    }
}

test "writes a model transition as one trace line" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var slots: [1]Slot = undefined;
    var table: Table = .init(&slots, .{});
    var out: Output = .{};

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .response_received = .{ .id = 1, .response = .peer_error } }, &out);
    try writeTrace(&writer, "lab", &out);
    try table.step(.{ .response_received = .{ .id = 1, .response = .result } }, &out);
    try writeTrace(&writer, "lab", &out);

    try testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"machine\":\"request\",\"inst\":\"lab\",\"event\":\"response_received\",\"from\":\"inflight\",\"to\":\"done\"," ++
            "\"effects\":[\"disarm_timers\",\"deliver\"],\"data\":{\"id\":1,\"kind\":\"normal\",\"response\":\"error\",\"outcome\":\"error\",\"delivered\":1,\"cancel_sent\":false,\"progress\":0}}\n" ++
            "{\"v\":1,\"seq\":2,\"machine\":\"request\",\"inst\":\"lab\",\"event\":\"response_received\",\"from\":\"done\",\"to\":\"done\"," ++
            "\"effects\":[],\"data\":{\"id\":1,\"response\":\"result\"}}\n",
        buffer.written(),
    );
}

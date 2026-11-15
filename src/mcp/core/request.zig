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
//!
//! A line the client refused that names no request has no request to end, so the requests in
//! flight when it came wait for their own timers, which can be minutes. `refused_line` gives each
//! normal one a short deadline instead, its grace (`Timeouts.refused_ms`). A line on a connection
//! that carries every request (stdio) is about all of them. A line on one request's stream (an HTTP
//! SSE event) is about that request alone, and another request keeps its own timers. One timer
//! covers the requests a line finds without a grace: it ends them one at a time as `malformed`, with a cancel
//! signal, unless an answer or progress for the request's own token came first. When the last
//! request that holds a line lets go of it, by ending or by progress, the table says
//! `disarm_refused` for that line, so the timers armed for refused lines never outnumber the
//! requests that hold one, however many lines and progress notifications come.
//!
//! TLA+ model: `tests/tla/mcp/Request.tla` (RefusedLine, GraceExpired, ProgressClears, and
//! `TimersBounded`).

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
    /// The grace of a refused line that named no request ran out with the request still silent.
    malformed,
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
    /// A start, from detection to ready, gets this long: the server cuts
    /// the probe and initialize's hard timeout to what is left.
    start_ms: u32 = 30_000,
    /// A token refresh gets this long; one with no answer by then fails
    /// and keeps the tokens.
    refresh_ms: u32 = 30_000,
    /// After a refused line that names no request, a normal request still in flight gets this
    /// long to be answered, or to show progress, before it ends as malformed. An engine option
    /// only: the host's configuration does not set it, so tests and labs can shorten it.
    refused_ms: u32 = 30_000,
};

/// Reconnect delays double from 1 s up to 30 s.
pub fn reconnectDelay(attempt: u32) u32 {
    return @min(@as(u32, 30_000), @as(u32, 1000) << @intCast(@min(attempt, 5)));
}

/// A `refused` timer is not a request's: its id is 0 and its generation is the refused line's number.
pub const TimerKind = enum { idle, hard, refused };

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
    /// The client refused a line that names no request: bytes that are not UTF-8, JSON nested too
    /// deep, a line whose id comes after what could not be read, or no JSON at all. The payload is
    /// the request whose stream carried the line, when it came on one request's stream, as an HTTP
    /// SSE event does: the line is about that request alone. It is null for a connection that
    /// carries every request, as stdio does: the line is about all of them.
    refused_line: ?Id,
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
    /// No request in flight holds the grace of refused line `epoch` any more, so its timer is
    /// stale: drop it. Only a refused timer has this generation (`Timer.generation`).
    disarm_refused: u32,
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
    /// The number of the refused line that gave this request its grace; 0 when it has none.
    refused_epoch: u32 = 0,
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
    /// Refused lines that gave a request a grace.
    refused_epoch: u32 = 0,

    /// `slots` is caller-owned storage; its length is the in-flight limit.
    pub fn init(slots: []Slot, timeouts: Timeouts) Table {
        @memset(slots, .{});
        return .{ .slots = slots, .timeouts = timeouts };
    }

    pub fn status(table: *const Table, id: Id) Status {
        if (id == 0 or id >= table.next_id) return .unused;
        return if (table.indexOf(id) != null) .inflight else .done;
    }

    /// The progress notifications accepted for `id` while it is in flight.
    pub fn progressCount(table: *const Table, id: Id) u32 {
        const index = table.indexOf(id) orelse return 0;
        return table.slots[index].progress_count;
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
            .refused_line => |scope| table.refusedLine(scope, out),
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
        table.slots[index] = .{};
        if (signal_cancel) out.push(.{ .send_cancel = slot.id });
        out.push(.{ .disarm_timers = slot.id });
        table.releaseRefusal(slot.refused_epoch, out);
        out.push(.{ .deliver = .{ .id = slot.id, .outcome = outcome } });
        out.transition = .{
            .event = event,
            .id = slot.id,
            .from = .inflight,
            .to = .done,
            .kind = slot.kind,
            .state = .{ .outcome = outcome, .delivered = 1, .cancel_sent = signal_cancel, .progress = slot.progress_count },
        };
    }

    /// Whether a request in flight still holds the grace of refused line `epoch`.
    fn holdsRefusal(table: *const Table, epoch: u32) bool {
        for (table.slots) |slot| if (slot.used and slot.refused_epoch == epoch) return true;
        return false;
    }

    /// A request let go of refused line `epoch`'s grace, by ending or by showing progress. When it
    /// was the last holder the line's timer has nothing left to end, so it is dropped now: the
    /// timers armed for refused lines never outnumber the requests that hold one.
    fn releaseRefusal(table: *const Table, epoch: u32, out: *Output) void {
        if (epoch != 0 and !table.holdsRefusal(epoch)) out.push(.{ .disarm_refused = epoch });
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
        if (timer.kind == .refused) return table.graceFired(timer.generation, out);
        const index = table.indexOf(timer.id) orelse return table.ignore("timer_fired", timer.id, out);
        const slot = table.slots[index];
        if (slot.kind == .listen or (timer.kind == .idle and timer.generation != slot.idle_generation)) {
            return table.ignore("timer_fired", timer.id, out);
        }
        table.finish(index, "timer_fired", .timed_out, slot.kind != .initialize, out);
    }

    /// A line that names no request gives every normal request it is about that is in flight and
    /// has no grace one: the same deadline for all of them, behind one timer. It is about every
    /// request when `scope` is null, and about `scope` alone when it came on that request's stream:
    /// another request keeps its own timers. A request that has a grace keeps it: a later line
    /// neither extends it nor arms another timer. initialize and a listen get none, and a request
    /// sent later is not in flight yet.
    fn refusedLine(table: *Table, scope: ?Id, out: *Output) void {
        const shown = if (scope) |id| table.status(id) else Status.unused;
        out.transition = .{ .event = "refused_line", .id = scope orelse 0, .from = shown, .to = shown };
        const epoch = table.refused_epoch +| 1;
        var fresh = false;
        for (table.slots) |*slot| {
            if (!slot.used or slot.kind != .normal or slot.refused_epoch != 0) continue;
            if (scope) |id| if (slot.id != id) continue;
            slot.refused_epoch = epoch;
            fresh = true;
        }
        if (!fresh) return;
        table.refused_epoch = epoch;
        out.push(.{ .arm_timer = .{
            .timer = .{ .id = 0, .kind = .refused, .generation = epoch },
            .after_ms = table.timeouts.refused_ms,
        } });
    }

    /// The grace of refused line `epoch` ran out: the first request that still holds it ends as
    /// malformed, with a cancel signal. While others hold it the timer is armed again at once,
    /// so a step ends one request. A request that was answered, or showed progress, no longer
    /// holds it, and a timer with nothing left to end is stale.
    fn graceFired(table: *Table, epoch: u32, out: *Output) void {
        const index = for (table.slots, 0..) |slot, i| {
            if (slot.used and slot.refused_epoch == epoch) break i;
        } else return;
        table.finish(index, "grace_expired", .malformed, true, out);
        for (table.slots) |slot| {
            if (!slot.used or slot.refused_epoch != epoch) continue;
            out.push(.{ .arm_timer = .{ .timer = .{ .id = 0, .kind = .refused, .generation = epoch }, .after_ms = 0 } });
            break;
        }
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
        // A request that shows progress for its own token is working, so the line that gave it a
        // grace says nothing about it. Its own timers go on.
        const held = slot.refused_epoch;
        slot.refused_epoch = 0;
        table.releaseRefusal(held, out);
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
        // A refused line's timer has no request of its own: it ends one the event does not name,
        // so `before` (the event's id, 0) says nothing about it.
        const grace = event == .timer_fired and event.timer_fired.kind == .refused;
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
                    // A refused line's grace ends a request as malformed, and nothing else does.
                    .timer_fired => |t| if (t.kind == .refused) .malformed else .timed_out,
                    .transport_lost => .lost,
                    // EndedOnlyListen: a server ends only a listen.
                    .server_cancel_received => |id| if (observed.listen[at(id)]) .ended else .none,
                    // Pausing and resuming the idle timer end nothing.
                    .send, .progress_received, .idle_paused, .idle_resumed, .refused_line => .none,
                };
                try testing.expectEqual(allowed, d.outcome);
                // ListenNeverTimesOut.
                if (observed.listen[at(d.id)]) try testing.expect(d.outcome != .timed_out);
            },
            .send_cancel => |id| {
                // CancelValid and NeverCancelInitialize.
                try testing.expect(before == .inflight or grace);
                try testing.expect(!observed.initialize[at(id)]);
                const outcome = deliveredOutcome(out).?;
                try testing.expect(outcome == .cancelled or outcome == .timed_out or outcome == .malformed);
                observed.cancelled_signal[at(id)] = true;
            },
            // A listen arms no timer.
            .arm_timer => |a| try testing.expect(!observed.listen[at(a.timer.id)]),
            .disarm_timers => {},
            // TimersAreGraces: a timer is dropped only for a line that no request holds.
            .disarm_refused => |epoch| try testing.expect(!table.holdsRefusal(epoch)),
        };
        // ScopedGrantsOnlyItsCall: a line on one request's stream gives a grace to that request alone.
        if (event == .refused_line) if (event.refused_line) |scope| for (out.effects()) |effect| switch (effect) {
            .arm_timer => |a| if (a.timer.kind == .refused) for (table.slots) |slot| {
                if (slot.used and slot.refused_epoch == a.timer.generation) try testing.expectEqual(scope, slot.id);
            },
            else => {},
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
            if (!grace) try testing.expectEqual(before, t.from);
            try testing.expectEqual(table.status(t.id), t.to);
            // OutcomeIffDone: a request is done exactly when it was delivered once.
            if (t.id < max_ids) try testing.expectEqual(t.to == .done, observed.delivered[at(t.id)] == 1);
        }
    }
};

fn eventId(event: Event) ?Id {
    return switch (event) {
        .send => null,
        .refused_line => |scope| scope,
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
    .{ .refused_line = null },
    .{ .refused_line = 1 },
    .{ .refused_line = 2 },
    .{ .timer_fired = .{ .id = 0, .kind = .refused, .generation = 1 } },
};

fn explore(slots: [2]Slot, next_id: Id, refused_epoch: u32, observed: Observed, depth: usize, steps: *usize) !void {
    if (depth == 0) return;
    for (alphabet) |event| {
        var child_slots = slots;
        var table: Table = .{ .slots = &child_slots, .timeouts = .{}, .next_id = next_id, .refused_epoch = refused_epoch };
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
        try explore(child_slots, table.next_id, table.refused_epoch, child, depth - 1, steps);
    }
}

test "every event sequence up to depth 5 keeps the model's invariants" {
    var slots: [2]Slot = undefined;
    @memset(&slots, .{});
    var steps: usize = 0;
    try explore(slots, 1, 0, .{}, 5, &steps);
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
            const event: Event = switch (random.uintLessThan(u8, 10)) {
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
                7 => .{ .server_cancel_received = id },
                8 => .{ .refused_line = if (random.boolean()) null else id },
                else => .{ .timer_fired = .{ .id = 0, .kind = .refused, .generation = random.intRangeAtMost(u32, 1, 3) } },
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

// ---- a line the client refused that names no request: the grace ----
//
// A refused line gives every normal request it is about that is in flight and has no grace one, with
// one timer for them all (`refused_line` step, id 0, or the stream's request for an SSE event); the timer's firing ends the first request that holds its
// number as `malformed` with a cancel signal (`grace_expired` step) and, while others hold it,
// arms the same timer again at once. tests/tla/mcp/Request.tla states the rules: RefusedLine,
// GraceExpired, ProgressClears and the invariants that go with them.

fn refusedArm(out: *const Output) ?@FieldType(Effect, "arm_timer") {
    for (out.effects()) |effect| switch (effect) {
        .arm_timer => |arm| if (arm.timer.kind == .refused) return arm,
        else => {},
    };
    return null;
}

fn refusedOrFail(out: *const Output) !@FieldType(Effect, "arm_timer") {
    return refusedArm(out) orelse error.TestUnexpectedResult;
}

fn deliveredOrFail(out: *const Output) !Outcome {
    return deliveredOutcome(out) orelse error.TestUnexpectedResult;
}

fn refusedArms(out: *const Output) usize {
    var count: usize = 0;
    for (out.effects()) |effect| switch (effect) {
        .arm_timer => |arm| count += @intFromBool(arm.timer.kind == .refused),
        else => {},
    };
    return count;
}

/// The refused timers a server holds, as the table's effects say: `arm_timer` adds one,
/// `disarm_refused` drops those of its line, and a timer that fires is taken out before the
/// table steps. The table's bound is on this count, which no arm count shows.
const RefusedTimers = struct {
    items: [128]Timer = undefined,
    count: usize = 0,

    fn apply(timers: *RefusedTimers, out: *const Output) !void {
        for (out.effects()) |effect| switch (effect) {
            .arm_timer => |arm| if (arm.timer.kind == .refused) {
                // The room is far above what the table keeps; running out of it is the failure.
                try testing.expect(timers.count < timers.items.len);
                timers.items[timers.count] = arm.timer;
                timers.count += 1;
            },
            .disarm_refused => |epoch| {
                var i: usize = 0;
                while (i < timers.count) {
                    if (timers.items[i].generation == epoch) {
                        timers.count -= 1;
                        timers.items[i] = timers.items[timers.count];
                    } else i += 1;
                }
            },
            else => {},
        };
    }

    fn fired(timers: *RefusedTimers, timer: Timer) void {
        for (timers.items[0..timers.count], 0..) |held, i| if (held.generation == timer.generation) {
            timers.count -= 1;
            timers.items[i] = timers.items[timers.count];
            return;
        };
    }

    /// Every timer is for a line that a request in flight still holds, so there are never more
    /// timers than requests.
    fn expectHeld(timers: *const RefusedTimers, table: *const Table) !void {
        for (timers.items[0..timers.count]) |timer| try testing.expect(table.holdsRefusal(timer.generation));
        try testing.expect(timers.count <= table.inFlightCount());
    }
};

test "grace: the grace is 30 s by default and a malformed request has its own model name" {
    try testing.expectEqual(@as(u32, 30_000), (Timeouts{}).refused_ms);
    try testing.expectEqualStrings("malformed", Outcome.malformed.modelName());
}

// `server/discover`, the probe, is a normal request, so a refused line gives it a grace. That
// changes nothing while the grace is no shorter than the start budget: the budget cuts the probe
// to what is left of it from detection on, so it ends before a grace that began later. A shorter
// grace would end a slow start early, and the probe would then need to stay out of the grace as
// initialize does.
test "grace: the grace is no shorter than the start budget, so the budget ends a probe first" {
    const defaults: Timeouts = .{};
    try testing.expect(defaults.refused_ms >= defaults.start_ms);
}

test "grace: a line that names no request arms one timer for the request in flight, and a second line arms none" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 1), out.effect_count);
    const arm = try refusedOrFail(&out);
    try testing.expectEqual(@as(u32, 30_000), arm.after_ms);
    try testing.expectEqual(@as(Id, 0), arm.timer.id);
    try testing.expectEqualStrings("refused_line", out.transition.?.event);
    try testing.expectEqual(@as(Id, 0), out.transition.?.id);
    try testing.expectEqual(Status.unused, out.transition.?.from);
    try testing.expectEqual(Status.unused, out.transition.?.to);

    // The second line finds a request that has its grace already: no timer, no extension.
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Status.inflight, table.status(1));
}

test "grace: a request that stays silent ends malformed, and the server is told it was cancelled" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    const arm = try refusedOrFail(&out);

    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(Outcome.malformed, try deliveredOrFail(&out));
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .send_cancel));
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .disarm_timers));
    try testing.expectEqualStrings("grace_expired", out.transition.?.event);
    try testing.expectEqual(Outcome.malformed, out.transition.?.state.?.outcome);
    try testing.expect(out.transition.?.state.?.cancel_sent);
    try testing.expectEqual(Status.done, table.status(1));

    // The timer fires again, as a stale one would: nothing more.
    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
}

test "grace: a line on one request's stream gives a grace to that request alone, and a line on the connection gives one to all" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    for (0..3) |_| try table.step(.{ .send = .normal }, &out);

    // An SSE event on request 2's stream: request 2 has a grace and the others have none.
    try table.step(.{ .refused_line = 2 }, &out);
    try testing.expectEqual(@as(usize, 1), refusedArms(&out));
    try testing.expectEqual(@as(u32, 30_000), (try refusedOrFail(&out)).after_ms);
    try testing.expectEqual(@as(u32, 0), table.slots[0].refused_epoch);
    try testing.expect(table.slots[1].refused_epoch != 0);
    try testing.expectEqual(@as(u32, 0), table.slots[2].refused_epoch);
    try testing.expectEqual(@as(Id, 2), out.transition.?.id);
    const first = (try refusedOrFail(&out)).timer;

    // Its grace ends request 2 as malformed, with a cancel, and the others go on.
    try table.step(.{ .timer_fired = first }, &out);
    try testing.expectEqual(Outcome.malformed, try deliveredOrFail(&out));
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .send_cancel));
    try testing.expectEqual(@as(usize, 0), refusedArms(&out));
    try testing.expectEqual(Status.done, table.status(2));
    try testing.expectEqual(Status.inflight, table.status(1));
    try testing.expectEqual(Status.inflight, table.status(3));

    // A line on the connection, as stdio has one, is about every request still in flight.
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 1), refusedArms(&out));
    try testing.expect(table.slots[0].refused_epoch != 0);
    try testing.expect(table.slots[2].refused_epoch != 0);
    try testing.expectEqual(@as(Id, 0), out.transition.?.id);
}

test "grace: a line on a stream that carries no normal request in flight arms no timer, and a second one adds nothing" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .initialize }, &out);
    try table.step(.{ .send = .listen }, &out);
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .send = .normal }, &out);
    // initialize, a listen, an id never sent, and a request that ended: nothing to grace.
    for ([_]Id{ 1, 2, 9 }) |scope| {
        try table.step(.{ .refused_line = scope }, &out);
        try testing.expectEqual(@as(usize, 0), out.effect_count);
    }
    try table.step(.{ .response_received = .{ .id = 3, .response = .result } }, &out);
    try table.step(.{ .refused_line = 3 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    // Request 4 gets its grace from the first line on its stream, and a second line adds none.
    try table.step(.{ .refused_line = 4 }, &out);
    try testing.expectEqual(@as(usize, 1), refusedArms(&out));
    try table.step(.{ .refused_line = 4 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    // A line that grants nothing takes no number.
    try testing.expectEqual(@as(u32, 1), table.refused_epoch);
}

test "grace: a response inside the grace still matches its request, and the timer then does nothing" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    const arm = try refusedOrFail(&out);

    try table.step(.{ .response_received = .{ .id = 1, .response = .result } }, &out);
    try testing.expectEqual(Outcome.result, try deliveredOrFail(&out));
    try testing.expectEqual(@as(usize, 0), countEffects(&out, .send_cancel));
    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);

    // The answered request's slot is free: the next request takes it, and the line's grace, which
    // that request was never in flight for, does not follow it there.
    var later: [1]Slot = undefined;
    var one: Table = .init(&later, .{ .refused_ms = 30_000 });
    try one.step(.{ .send = .normal }, &out);
    try one.step(.{ .refused_line = null }, &out);
    const held = try refusedOrFail(&out);
    try one.step(.{ .response_received = .{ .id = 1, .response = .result } }, &out);
    try one.step(.{ .send = .normal }, &out);
    try one.step(.{ .timer_fired = held.timer }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Status.inflight, one.status(2));
}

test "grace: progress for the request's own token clears its grace, and its other timers go on" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    const arm = try refusedOrFail(&out);
    try table.step(.{ .progress_received = .{ .token = 1, .value = 1 } }, &out);
    try testing.expectEqual(@as(u32, 1), table.progressCount(1));

    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Status.inflight, table.status(1));

    // Its idle timer, re-armed by the progress, still ends it as a timeout.
    const idle: Timer = .{ .id = 1, .kind = .idle, .generation = table.slots[0].idle_generation };
    try table.step(.{ .timer_fired = idle }, &out);
    try testing.expectEqual(Outcome.timed_out, try deliveredOrFail(&out));
}

test "grace: progress for another request's token does not clear it" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 1), refusedArms(&out));
    const arm = try refusedOrFail(&out);
    // Request 1 shows its server is alive; request 2 stays silent.
    try table.step(.{ .progress_received = .{ .token = 1, .value = 1 } }, &out);

    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(Outcome.malformed, try deliveredOrFail(&out));
    try testing.expectEqual(Status.done, table.status(2));
    try testing.expectEqual(Status.inflight, table.status(1));
    try testing.expectEqual(@as(usize, 0), refusedArms(&out));
}

test "grace: progress that does not increase is not progress, so it does not clear the grace" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .progress_received = .{ .token = 1, .value = 5 } }, &out);
    try table.step(.{ .refused_line = null }, &out);
    const arm = try refusedOrFail(&out);
    try table.step(.{ .progress_received = .{ .token = 1, .value = 5 } }, &out);
    try testing.expectEqual(@as(u32, 1), table.progressCount(1));

    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(Outcome.malformed, try deliveredOrFail(&out));
}

test "grace: progress before the line does not protect, and a request sent after the line gets no grace" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .progress_received = .{ .token = 1, .value = 1 } }, &out);
    try table.step(.{ .refused_line = null }, &out);
    const arm = try refusedOrFail(&out);
    try table.step(.{ .send = .normal }, &out);

    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(Outcome.malformed, try deliveredOrFail(&out));
    try testing.expectEqual(Status.done, table.status(1));
    try testing.expectEqual(Status.inflight, table.status(2));
    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Status.inflight, table.status(2));
}

test "grace: initialize and listen get none, and a line with nothing else in flight arms no timer" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    try table.step(.{ .send = .initialize }, &out);
    try table.step(.{ .send = .listen }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);

    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 1), refusedArms(&out));
    const arm = try refusedOrFail(&out);
    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(Status.done, table.status(3));
    try testing.expectEqual(Status.inflight, table.status(1));
    try testing.expectEqual(Status.inflight, table.status(2));
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .send_cancel));
}

test "grace: a request whose own deadline comes first ends at it, and the grace then does nothing" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000, .idle_ms = 10_000 });
    var out: Output = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    const arm = try refusedOrFail(&out);
    try table.step(.{ .timer_fired = .{ .id = 1, .kind = .idle, .generation = 1 } }, &out);
    try testing.expectEqual(Outcome.timed_out, try deliveredOrFail(&out));
    try table.step(.{ .timer_fired = arm.timer }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
}

test "grace: one line over three requests arms one timer, and it ends them one at a time" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    for (0..3) |_| try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try testing.expectEqual(@as(usize, 1), refusedArms(&out));
    const arm = try refusedOrFail(&out);

    var ended: usize = 0;
    while (table.inFlightCount() > 0) {
        try table.step(.{ .timer_fired = arm.timer }, &out);
        try testing.expectEqual(Outcome.malformed, try deliveredOrFail(&out));
        try testing.expectEqual(@as(usize, 1), countEffects(&out, .send_cancel));
        ended += 1;
        // While others hold the number the timer is armed again at once, with no wait.
        const again = refusedArm(&out);
        try testing.expectEqual(table.inFlightCount() > 0, again != null);
        if (again) |next| {
            try testing.expectEqual(@as(u32, 0), next.after_ms);
            try testing.expectEqual(arm.timer.generation, next.timer.generation);
        }
    }
    try testing.expectEqual(@as(usize, 3), ended);
}

test "grace: a flood of lines holds one timer for the requests, and a call that starts between floods adds one" {
    var slots: [8]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    var timers: RefusedTimers = .{};
    for (0..3) |_| try table.step(.{ .send = .normal }, &out);
    for (0..10_000) |_| {
        try table.step(.{ .refused_line = null }, &out);
        try timers.apply(&out);
        try timers.expectHeld(&table);
    }
    try testing.expectEqual(@as(usize, 1), timers.count);

    // A call that starts between lines is covered by the next line, once.
    try table.step(.{ .send = .normal }, &out);
    for (0..10_000) |_| {
        try table.step(.{ .refused_line = null }, &out);
        try timers.apply(&out);
        try timers.expectHeld(&table);
    }
    try testing.expectEqual(@as(usize, 2), timers.count);
}

test "grace: progress and a bad line in turns, a thousand times, leave one refused timer for the one request" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    var timers: RefusedTimers = .{};
    try table.step(.{ .send = .normal }, &out);
    for (1..1001) |round| {
        // The line gives the request a grace, with the full deadline each time.
        try table.step(.{ .refused_line = null }, &out);
        try testing.expectEqual(@as(u32, 30_000), (try refusedOrFail(&out)).after_ms);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 1), timers.count);
        try timers.expectHeld(&table);
        // Progress for its own token clears the grace, so its timer goes with it.
        try table.step(.{ .progress_received = .{ .token = 1, .value = @floatFromInt(round) } }, &out);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 0), timers.count);
        try testing.expectEqual(@as(usize, 1), countEffects(&out, .disarm_refused));
    }
    try testing.expectEqual(Status.inflight, table.status(1));
}

test "grace: progress and a bad line in turns, a thousand times, keep the timers within the requests, on a stream and on a connection" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    var timers: RefusedTimers = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .send = .normal }, &out);
    for (1..1001) |round| {
        const value: f64 = @floatFromInt(round);
        // An SSE event on request 1's stream: one timer, held by request 1 alone.
        try table.step(.{ .refused_line = 1 }, &out);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 1), timers.count);
        try testing.expectEqual(@as(u32, 0), table.slots[1].refused_epoch);
        try timers.expectHeld(&table);
        try table.step(.{ .progress_received = .{ .token = 1, .value = value } }, &out);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 0), timers.count);
        // A line on the connection: one timer, held by both requests, which each lets go in turn.
        try table.step(.{ .refused_line = null }, &out);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 1), timers.count);
        try timers.expectHeld(&table);
        try table.step(.{ .progress_received = .{ .token = 1, .value = value + 0.5 } }, &out);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 1), timers.count);
        try table.step(.{ .progress_received = .{ .token = 2, .value = value } }, &out);
        try timers.apply(&out);
        try testing.expectEqual(@as(usize, 0), timers.count);
        try timers.expectHeld(&table);
    }
    try testing.expectEqual(Status.inflight, table.status(1));
    try testing.expectEqual(Status.inflight, table.status(2));
}

test "grace: a request that ends or shows progress takes its line's timer away only when it was the last to hold it" {
    var slots: [4]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    var timers: RefusedTimers = .{};
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try timers.apply(&out);
    try table.step(.{ .send = .normal }, &out);
    try table.step(.{ .refused_line = null }, &out);
    try timers.apply(&out);
    // Request 1 and 2 hold the first line, request 3 the second.
    try testing.expectEqual(@as(usize, 2), timers.count);

    // Progress for 1 leaves the first line with request 2: no timer goes.
    try table.step(.{ .progress_received = .{ .token = 1, .value = 1 } }, &out);
    try testing.expectEqual(@as(usize, 0), countEffects(&out, .disarm_refused));
    try timers.apply(&out);
    try testing.expectEqual(@as(usize, 2), timers.count);

    // Request 2 ends: the first line has no holder, so its timer goes, and only that one.
    try table.step(.{ .response_received = .{ .id = 2, .response = .result } }, &out);
    try testing.expectEqual(@as(usize, 1), countEffects(&out, .disarm_refused));
    try timers.apply(&out);
    try testing.expectEqual(@as(usize, 1), timers.count);
    try timers.expectHeld(&table);

    // Request 3 ends by its cancel: the second line's timer goes, and none is left.
    try table.step(.{ .cancel_requested = 3 }, &out);
    try timers.apply(&out);
    try testing.expectEqual(@as(usize, 0), timers.count);
    // Request 1 holds nothing; ending it takes nothing away.
    try table.step(.{ .response_received = .{ .id = 1, .response = .result } }, &out);
    try testing.expectEqual(@as(usize, 0), countEffects(&out, .disarm_refused));
}

test "grace stress: a flood of lines with requests coming and going keeps the timers within the requests and ends each request once" {
    const iterations = 1_000_000;
    var slots: [64]Slot = undefined;
    var table: Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: Output = .{};
    var prng: std.Random.DefaultPrng = .init(0x6e6);
    const random = prng.random();
    var delivered = try testing.allocator.alloc(u8, iterations + 2);
    defer testing.allocator.free(delivered);
    @memset(delivered, 0);
    var timers: RefusedTimers = .{};
    var sends: usize = 0;
    var arms: usize = 0;
    var progress_steps: usize = 0;

    for (0..iterations) |_| {
        const pick = random.uintLessThan(u8, 100);
        if (pick < 20) {
            if (table.step(.{ .send = .normal }, &out)) |_| sends += 1 else |err| switch (err) {
                error.TooManyInFlight => continue,
                else => return err,
            }
        } else if (pick < 55) {
            const scope: ?Id = if (random.boolean()) null else random.intRangeAtMost(Id, 1, @max(1, table.next_id -| 1));
            try table.step(.{ .refused_line = scope }, &out);
            arms += refusedArms(&out);
        } else if (pick < 72) {
            if (timers.count == 0) continue;
            const timer = timers.items[random.uintLessThan(usize, timers.count)];
            timers.fired(timer);
            try table.step(.{ .timer_fired = timer }, &out);
        } else if (pick < 87) {
            const id = random.intRangeAtMost(Id, 1, @max(1, table.next_id -| 1));
            try table.step(.{ .response_received = .{ .id = id, .response = .result } }, &out);
        } else {
            const id = random.intRangeAtMost(Id, 1, @max(1, table.next_id -| 1));
            const was = table.progressCount(id);
            try table.step(.{ .progress_received = .{ .token = id, .value = @floatFromInt(random.uintLessThan(u8, 6)) } }, &out);
            progress_steps += @intFromBool(table.progressCount(id) != was);
        }
        for (out.effects()) |effect| switch (effect) {
            .deliver => |d| {
                delivered[@intCast(d.id)] += 1;
                try testing.expect(delivered[@intCast(d.id)] <= 1);
            },
            else => {},
        };
        try timers.apply(&out);
        // After every step each refused timer is for a line a request in flight still holds, so
        // the timers never outnumber the requests.
        try timers.expectHeld(&table);
        // A request is graced again only after progress cleared its grace, so the timers armed
        // never exceed the requests sent and the progress that cleared a grace.
        try testing.expect(arms <= sends + progress_steps);
    }
    // Every timer left fires: each request that held a number ends, once.
    while (timers.count > 0) {
        const timer = timers.items[timers.count - 1];
        timers.fired(timer);
        try table.step(.{ .timer_fired = timer }, &out);
        try timers.apply(&out);
        try timers.expectHeld(&table);
        for (out.effects()) |effect| switch (effect) {
            .deliver => |d| {
                delivered[@intCast(d.id)] += 1;
                try testing.expect(delivered[@intCast(d.id)] <= 1);
            },
            else => {},
        };
    }
}

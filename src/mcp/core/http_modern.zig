//! Streamable HTTP (2026) exchange core: one logical request and its
//! attempts. Events are its actions, and effects say what to do next. Pure: no I/O, clock,
//! allocation, or globals.
//!
//! Each `post` effect is a new attempt: a new request, so a new id.
//! The request table never reuses ids, so this core holds none.

const std = @import("std");
const trace = @import("../io/trace.zig");

/// A `tools/call` may change things on the server, so it is never re-sent
/// after a broken stream. Everything else is re-issued.
pub const Kind = enum { call, idempotent };
pub const Phase = enum { idle, posted, relisting, done, lost, failed, cancelled };
/// An attempt's JSON-RPC answer; `mismatch` is -32020 (HeaderMismatch).
pub const Answer = enum { result, failure, mismatch };
pub const Outcome = enum { result, failure, lost, http_failure, cancelled };

pub const Config = struct {
    /// POSTs per request after broken streams, counting the first.
    max_attempts: u8 = 2,
};

pub const Event = union(enum) {
    send,
    answer: Answer,
    /// An HTTP status without a JSON-RPC body.
    http_failure,
    /// The connection or stream broke before the answer.
    stream_broken,
    /// The re-list after -32020 ended, well or not.
    relisted: bool,
    /// The host cancelled, or the request's timeout fired.
    cancel,
};

pub const Effect = union(enum) {
    /// POST a new attempt.
    post,
    /// Re-list the tools before retrying the call.
    relist,
    /// Close the attempt's stream: that is the cancellation.
    close,
    /// What the caller gets. `maybe_ran`: a lost `tools/call` may have run.
    deliver: struct { outcome: Outcome, maybe_ran: bool },
};

pub const max_effects = 2;

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

pub const Transition = struct {
    event: []const u8,
    from: Phase,
    to: Phase,
    answer: ?Answer = null,
    ok: ?bool = null,
    ignored: bool = false,
    kind: Kind,
    attempts: u8,
    header_retries: u1,
    maybe_ran: bool,
};

pub const Exchange = struct {
    config: Config = .{},
    kind: Kind,
    phase: Phase = .idle,
    attempts: u8 = 0,
    header_retries: u1 = 0,
    maybe_ran: bool = false,

    pub fn init(config: Config, kind: Kind) Exchange {
        std.debug.assert(config.max_attempts > 0);
        return .{ .config = config, .kind = kind };
    }

    pub fn done(x: *const Exchange) bool {
        return switch (x.phase) {
            .done, .lost, .failed, .cancelled => true,
            else => false,
        };
    }

    /// Applies one event. Resets `out` first. An event the model can't take
    /// in this phase (such as an answer after a cancel) changes nothing.
    pub fn step(x: *Exchange, event: Event, out: *Output) void {
        out.* = .{};
        const from = x.phase;
        var ignored = false;
        switch (event) {
            .send => if (x.phase == .idle) {
                x.attempts = 1;
                x.post(out);
            } else {
                ignored = true;
            },
            .answer => |answer| if (x.phase != .posted) {
                ignored = true;
            } else if (answer == .mismatch and x.kind == .call and x.header_retries == 0) {
                x.phase = .relisting;
                x.header_retries = 1;
                out.push(.relist);
            } else {
                x.finish(.done, if (answer == .result) .result else .failure, out);
            },
            .http_failure => if (x.phase == .posted) x.finish(.failed, .http_failure, out) else {
                ignored = true;
            },
            .stream_broken => if (x.phase != .posted) {
                ignored = true;
            } else if (x.kind == .idempotent and x.attempts < x.config.max_attempts) {
                x.attempts += 1;
                x.post(out);
            } else {
                x.maybe_ran = x.kind == .call;
                x.finish(.lost, .lost, out);
            },
            .relisted => |ok| if (x.phase != .relisting) {
                ignored = true;
            } else if (ok) {
                x.post(out);
            } else {
                x.finish(.done, .failure, out);
            },
            .cancel => if (x.phase == .posted or x.phase == .relisting) {
                out.push(.close);
                x.finish(.cancelled, .cancelled, out);
            } else {
                ignored = true;
            },
        }
        out.transition = .{
            .event = @tagName(event),
            .from = from,
            .to = x.phase,
            .answer = if (event == .answer) event.answer else null,
            .ok = if (event == .relisted) event.relisted else null,
            .ignored = ignored,
            .kind = x.kind,
            .attempts = x.attempts,
            .header_retries = x.header_retries,
            .maybe_ran = x.maybe_ran,
        };
    }

    fn post(x: *Exchange, out: *Output) void {
        x.phase = .posted;
        out.push(.post);
    }

    fn finish(x: *Exchange, phase: Phase, outcome: Outcome, out: *Output) void {
        x.phase = phase;
        out.push(.{ .deliver = .{ .outcome = outcome, .maybe_ran = x.maybe_ran } });
    }
};

/// Writes the step in `out` as one trace line for machine "http".
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    const t = out.transition orelse return;
    var fields: [7]trace.Field = undefined;
    var count: usize = 0;
    if (t.answer) |a| {
        fields[count] = .{ .name = "answer", .value = .{ .string = switch (a) {
            .result => "result",
            .failure => "error",
            .mismatch => "mismatch",
        } } };
        count += 1;
    }
    if (t.ok) |ok| {
        fields[count] = .{ .name = "ok", .value = .{ .boolean = ok } };
        count += 1;
    }
    const projected = [_]trace.Field{
        .{ .name = "ignored", .value = .{ .boolean = t.ignored } },
        .{ .name = "kind", .value = .{ .string = @tagName(t.kind) } },
        .{ .name = "attempts", .value = .{ .int = t.attempts } },
        .{ .name = "header_retries", .value = .{ .int = t.header_retries } },
        .{ .name = "maybe_ran", .value = .{ .boolean = t.maybe_ran } },
    };
    @memcpy(fields[count..][0..projected.len], &projected);
    count += projected.len;
    var effect_names: [max_effects][]const u8 = undefined;
    for (out.effects(), 0..) |effect, index| effect_names[index] = @tagName(effect);
    try writer.write(.{
        .machine = "http",
        .instance = instance,
        .event = t.event,
        .from = @tagName(t.from),
        .to = @tagName(t.to),
        .effects = effect_names[0..out.effect_count],
        .data = fields[0..count],
    });
}

const testing = std.testing;

/// What the caller and the server saw, rebuilt from the effects alone.
const World = struct {
    posts: u8 = 0,
    delivered: u8 = 0,
    relists: u8 = 0,
    closed: bool = false,
    cancelled: bool = false,
    /// An attempt is in flight.
    posted: bool = false,
    relisting: bool = false,
};

const moves = [_]Event{
    .send,         .{ .answer = .result }, .{ .answer = .failure }, .{ .answer = .mismatch },
    .http_failure, .stream_broken,         .{ .relisted = true },   .{ .relisted = false },
    .cancel,
};

fn apply(x: *Exchange, w: *World, event: Event) !void {
    const before = x.*;
    var out: Output = .{};
    x.step(event, &out);
    const t = out.transition.?;
    if (t.ignored) {
        try testing.expectEqual(before, x.*);
        try testing.expectEqual(@as(usize, 0), out.effect_count);
        return;
    }
    if (event == .stream_broken or event == .answer or event == .http_failure) w.posted = false;
    if (event == .relisted) w.relisting = false;
    for (out.effects()) |effect| switch (effect) {
        .post => {
            // ReissueNewId holds by construction: each post is a new request.
            w.posts += 1;
            w.posted = true;
            // NoCallResent: a call is posted once, plus one retry after -32020.
            if (x.kind == .call) try testing.expect(w.posts <= 1 + w.relists);
            try testing.expect(w.posts <= x.config.max_attempts + w.relists);
        },
        .relist => {
            try testing.expect(x.kind == .call and event == .answer and event.answer == .mismatch);
            w.relists += 1;
            try testing.expect(w.relists <= 1);
            w.relisting = true;
        },
        .close => {
            try testing.expect(event == .cancel);
            w.closed = true;
        },
        .deliver => |d| {
            // AtMostOneOutcome.
            w.delivered += 1;
            try testing.expect(w.delivered <= 1);
            // MaybeRanOnlyForLostCalls.
            if (d.maybe_ran) try testing.expect(d.outcome == .lost and x.kind == .call);
            // CancelByClose: a cancel closes the stream first.
            if (d.outcome == .cancelled) try testing.expect(w.closed);
            if (event == .cancel) w.cancelled = true;
        },
    };
    // Where the model has no choice, the core must act.
    if (event == .stream_broken and before.phase == .posted and x.kind == .call) try testing.expectEqual(Phase.lost, x.phase);
    if (event == .cancel) try testing.expect(x.phase == .cancelled);
    if (event == .relisted and !event.relisted) try testing.expectEqual(Phase.done, x.phase);
}

fn explore(x: Exchange, w: World, depth: usize, steps: *usize) !void {
    if (depth == 0) return;
    for (moves) |move| {
        var xc = x;
        var wc = w;
        try apply(&xc, &wc, move);
        steps.* += 1;
        try explore(xc, wc, depth - 1, steps);
    }
}

test "every event sequence up to depth 7 keeps the model's invariants, for both kinds" {
    for ([_]Kind{ .call, .idempotent }) |kind| {
        for ([_]u8{ 1, 2, 3 }) |max| {
            var steps: usize = 0;
            try explore(.init(.{ .max_attempts = max }, kind), .{}, 7, &steps);
            try testing.expect(steps > 4_000);
        }
    }
}

test "every request ends once the server answers or breaks (EveryRequestEnds)" {
    var prng: std.Random.DefaultPrng = .init(0x477);
    const random = prng.random();
    for (0..2_000) |_| {
        var x: Exchange = .init(.{ .max_attempts = 3 }, if (random.boolean()) .call else .idempotent);
        var w: World = .{};
        for (0..random.uintLessThan(usize, 12)) |_| try apply(&x, &w, moves[random.uintLessThan(usize, moves.len)]);
        // The environment keeps answering what is pending: an attempt breaks,
        // gets -32020, or gets its result; a re-list ends.
        for (0..16) |_| {
            if (x.done()) break;
            const posted = [_]Event{ .stream_broken, .{ .answer = .mismatch }, .{ .answer = .result } };
            const event: Event = switch (x.phase) {
                .idle => .send,
                .relisting => .{ .relisted = random.boolean() },
                else => posted[random.uintLessThan(usize, posted.len)],
            };
            try apply(&x, &w, event);
        }
        try testing.expect(x.done());
    }
}

test "a listing is re-issued once after a broken stream; a call is lost, maybe run" {
    var list: Exchange = .init(.{}, .idempotent);
    var out: Output = .{};
    list.step(.send, &out);
    list.step(.stream_broken, &out);
    try testing.expectEqualSlices(Effect, &.{.post}, out.effects());
    list.step(.stream_broken, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .outcome = .lost, .maybe_ran = false } }}, out.effects());

    var call: Exchange = .init(.{}, .call);
    call.step(.send, &out);
    call.step(.stream_broken, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .outcome = .lost, .maybe_ran = true } }}, out.effects());
}

test "-32020 to a call re-lists, then retries once" {
    var call: Exchange = .init(.{}, .call);
    var out: Output = .{};
    call.step(.send, &out);
    call.step(.{ .answer = .mismatch }, &out);
    try testing.expectEqualSlices(Effect, &.{.relist}, out.effects());
    call.step(.{ .relisted = true }, &out);
    try testing.expectEqualSlices(Effect, &.{.post}, out.effects());
    call.step(.{ .answer = .mismatch }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .outcome = .failure, .maybe_ran = false } }}, out.effects());
}

test "cancelling closes the stream; a late answer changes nothing" {
    var x: Exchange = .init(.{}, .call);
    var out: Output = .{};
    x.step(.send, &out);
    x.step(.cancel, &out);
    try testing.expectEqualSlices(Effect, &.{ .close, .{ .deliver = .{ .outcome = .cancelled, .maybe_ran = false } } }, out.effects());
    x.step(.{ .answer = .result }, &out);
    try testing.expect(out.transition.?.ignored);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
}

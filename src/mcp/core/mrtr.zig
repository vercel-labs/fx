//! Multi round-trip requests (2026): one chain of rounds for one
//! tools/call. The host keeps the strings, the requestState and the input
//! requests; this core only decides.
//! A requestState is named by the round whose answer brought it.

const std = @import("std");
const trace = @import("../io/trace.zig");

pub const Config = struct {
    /// Requests per chain.
    max_requests: u8 = 10,
};

pub const Phase = enum { idle, sent, asking, backoff, done };

pub const Outcome = enum {
    none,
    result,
    /// A JSON-RPC error.
    failure,
    /// No answer: the stream broke after the request went out.
    lost,
    /// A status without a JSON-RPC answer.
    http_failure,
    cancelled,
    rounds_exceeded,
    /// Input requests for a capability the client didn't declare.
    unsupported_input,
    /// An input_required the client can't act on.
    malformed,
};

pub const Answer = union(enum) {
    /// The request ended: a final result, an error, or none.
    ended: Outcome,
    malformed,
    /// `requests` input requests (0 for none), whether a requestState came,
    /// and whether every request is for a declared capability.
    input_required: struct { requests: u8, state: bool, supported: bool },
};

pub const Event = union(enum) {
    start,
    answered: Answer,
    /// The host answered every input request.
    provided,
    backoff_elapsed,
    cancel,
};

pub const Effect = union(enum) {
    /// Send round `round`: echo the requestState of round `state` (0 for
    /// none) and answer `responses` input requests.
    send: struct { round: u8, state: u8, responses: u8 },
    /// Show the round's input requests to the host.
    ask_host,
    arm_backoff: u32,
    deliver: Outcome,
};

pub const Output = struct {
    effect_buffer: [2]Effect = undefined,
    effect_count: usize = 0,
    action: []const u8 = "",
    from: Phase = .idle,
    ignored: bool = false,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn push(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Chain = struct {
    config: Config,
    phase: Phase = .idle,
    round: u8 = 0,
    /// The round whose answer brought the requestState in hand, 0 for none.
    last_state: u8 = 0,
    requested: u8 = 0,
    supported: bool = true,
    sent_state: u8 = 0,
    responded: u8 = 0,
    outcome: Outcome = .none,
    /// Rounds in a row that carried only a requestState, for the backoff.
    state_only: u8 = 0,

    pub fn init(config: Config) Chain {
        return .{ .config = config };
    }

    pub fn step(c: *Chain, event: Event, out: *Output) void {
        out.* = .{ .from = c.phase };
        switch (event) {
            .start => {
                out.action = "start";
                if (c.phase != .idle) return c.ignore(out);
                c.send(0, out);
            },
            .answered => |answer| {
                out.action = switch (answer) {
                    .ended => "ended",
                    .malformed => "malformed",
                    .input_required => "input_required",
                };
                if (c.phase != .sent) return c.ignore(out);
                switch (answer) {
                    .ended => |o| c.end(o, out),
                    .malformed => c.end(.malformed, out),
                    .input_required => |r| c.inputRequired(r.requests, r.state, r.supported, out),
                }
            },
            .provided => {
                out.action = "provide";
                if (c.phase != .asking) return c.ignore(out);
                c.state_only = 0;
                c.send(c.requested, out);
            },
            .backoff_elapsed => {
                out.action = "backoff_done";
                if (c.phase != .backoff) return c.ignore(out);
                c.send(0, out);
            },
            .cancel => {
                out.action = "cancel";
                if (c.phase != .sent and c.phase != .asking and c.phase != .backoff) return c.ignore(out);
                c.end(.cancelled, out);
            },
        }
    }

    fn inputRequired(c: *Chain, requests: u8, state: bool, supported: bool, out: *Output) void {
        // At least one of the two fields; the parser reports malformed
        // otherwise, but the core doesn't rely on it.
        if (requests == 0 and !state) {
            out.action = "malformed";
            return c.end(.malformed, out);
        }
        c.requested = requests;
        c.supported = supported;
        c.last_state = if (state) c.round else 0;
        if (c.round >= c.config.max_requests) return c.end(.rounds_exceeded, out);
        if (requests > 0 and !supported) return c.end(.unsupported_input, out);
        if (requests > 0) {
            c.phase = .asking;
            return out.push(.ask_host);
        }
        // 50 ms doubling to 250 ms over rounds in a row that carry only
        // a requestState, as rmcp does.
        c.phase = .backoff;
        out.push(.{ .arm_backoff = @min(@as(u32, 250), @as(u32, 50) << @intCast(@min(c.state_only, 3))) });
        c.state_only += 1;
    }

    fn send(c: *Chain, responses: u8, out: *Output) void {
        c.phase = .sent;
        c.round += 1;
        c.sent_state = c.last_state;
        c.responded = responses;
        out.push(.{ .send = .{ .round = c.round, .state = c.sent_state, .responses = responses } });
    }

    fn end(c: *Chain, outcome: Outcome, out: *Output) void {
        c.phase = .done;
        c.outcome = outcome;
        out.push(.{ .deliver = outcome });
    }

    fn ignore(_: *Chain, out: *Output) void {
        out.ignored = true;
    }
};

/// Writes the step as one trace line for machine "mrtr".
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, c: *const Chain, out: *const Output) std.Io.Writer.Error!void {
    try writer.write(.{
        .machine = "mrtr",
        .instance = instance,
        .event = out.action,
        .from = @tagName(out.from),
        .to = @tagName(c.phase),
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },
            .{ .name = "round", .value = .{ .int = c.round } },
            .{ .name = "last_state", .value = .{ .int = c.last_state } },
            .{ .name = "requested", .value = .{ .int = c.requested } },
            .{ .name = "supported", .value = .{ .boolean = c.supported } },
            .{ .name = "sent_state", .value = .{ .int = c.sent_state } },
            .{ .name = "responded", .value = .{ .int = c.responded } },
            .{ .name = "outcome", .value = .{ .string = @tagName(c.outcome) } },
        },
    });
}

// ---------------------------------------------------------------------------
// Tests. The model's invariants are checked after every step of every event
// sequence to a small depth; the ghost `brought` is kept beside the chain.

const testing = std.testing;

const World = struct {
    brought: u8 = 0,
    sent_done: bool = false,

    fn check(w: *World, c: *const Chain, before: Phase, event: Event, out: *const Output) !void {
        if (event == .answered and event.answered == .input_required and before == .sent and !out.ignored) {
            const r = event.answered.input_required;
            if (r.requests > 0 or r.state) w.brought = if (r.state) c.round else 0;
        }
        for (out.effects()) |e| if (e == .send and before == .done) {
            w.sent_done = true;
        };
        try testing.expect(c.round <= c.config.max_requests); // RoundCap
        if (c.phase == .sent) {
            try testing.expectEqual(w.brought, c.sent_state); // StateEchoExact
            try testing.expectEqual(c.requested, c.responded); // ResponsesExact
        }
        if (c.phase == .asking) try testing.expect(c.supported); // NoAskUnsupported
        if (c.phase == .backoff) try testing.expect(w.brought != 0); // BackoffNeedsState
        try testing.expect(!w.sent_done); // NothingAfterEnd
        // Cancel ends the chain wherever the model lets it.
        if (event == .cancel and (before == .sent or before == .asking or before == .backoff)) try testing.expectEqual(Phase.done, c.phase);
        // Every send names the state of the round before, and the effect
        // carries what the chain recorded.
        for (out.effects()) |e| if (e == .send) {
            try testing.expectEqual(c.sent_state, e.send.state);
            try testing.expectEqual(c.responded, e.send.responses);
        };
    }
};

fn explore(c: Chain, w: World, depth: u8) !void {
    if (depth == 0) return;
    const answers = [_]Answer{
        .{ .ended = .result },                                                        .{ .ended = .lost },
        .malformed,                                                                   .{ .input_required = .{ .requests = 0, .state = true, .supported = true } },
        .{ .input_required = .{ .requests = 2, .state = true, .supported = true } },  .{ .input_required = .{ .requests = 1, .state = false, .supported = true } },
        .{ .input_required = .{ .requests = 1, .state = true, .supported = false } }, .{ .input_required = .{ .requests = 0, .state = false, .supported = true } },
    };
    var events: [12]Event = undefined;
    var n: usize = 0;
    for ([_]Event{ .start, .provided, .backoff_elapsed, .cancel }) |e| {
        events[n] = e;
        n += 1;
    }
    for (answers) |a| {
        events[n] = .{ .answered = a };
        n += 1;
    }
    for (events[0..n]) |event| {
        var next = c;
        var nw = w;
        const before = next.phase;
        var out: Output = .{};
        next.step(event, &out);
        try nw.check(&next, before, event, &out);
        try explore(next, nw, depth - 1);
    }
}

test "every event sequence to depth 7 keeps the model's invariants" {
    try explore(.init(.{ .max_requests = 4 }), .{}, 7);
}

fn steps(c: *Chain, events: []const Event) Output {
    var out: Output = .{};
    for (events) |e| c.step(e, &out);
    return out;
}

test "a retry echoes the last requestState and answers every input request" {
    var c: Chain = .init(.{});
    var out = steps(&c, &.{ .start, .{ .answered = .{ .input_required = .{ .requests = 2, .state = true, .supported = true } } } });
    try testing.expectEqualSlices(Effect, &.{.ask_host}, out.effects());
    out = steps(&c, &.{.provided});
    try testing.expectEqualSlices(Effect, &.{.{ .send = .{ .round = 2, .state = 1, .responses = 2 } }}, out.effects());
    // A round without a requestState: the next retry carries none.
    out = steps(&c, &.{ .{ .answered = .{ .input_required = .{ .requests = 1, .state = false, .supported = true } } }, .provided });
    try testing.expectEqualSlices(Effect, &.{.{ .send = .{ .round = 3, .state = 0, .responses = 1 } }}, out.effects());
}

test "rounds with only a requestState back off 50, 100, 200, then 250 ms" {
    var c: Chain = .init(.{});
    _ = steps(&c, &.{.start});
    const state_only: Event = .{ .answered = .{ .input_required = .{ .requests = 0, .state = true, .supported = true } } };
    for ([_]u32{ 50, 100, 200, 250, 250 }) |ms| {
        const out = steps(&c, &.{state_only});
        try testing.expectEqualSlices(Effect, &.{.{ .arm_backoff = ms }}, out.effects());
        _ = steps(&c, &.{.backoff_elapsed});
    }
    // A round with input requests starts the backoff over.
    _ = steps(&c, &.{ .{ .answered = .{ .input_required = .{ .requests = 1, .state = true, .supported = true } } }, .provided });
    const out = steps(&c, &.{state_only});
    try testing.expectEqualSlices(Effect, &.{.{ .arm_backoff = 50 }}, out.effects());
}

test "the tenth input_required ends the chain" {
    var c: Chain = .init(.{});
    _ = steps(&c, &.{.start});
    const state_only: Event = .{ .answered = .{ .input_required = .{ .requests = 0, .state = true, .supported = true } } };
    for (0..9) |_| _ = steps(&c, &.{ state_only, .backoff_elapsed });
    try testing.expectEqual(@as(u8, 10), c.round);
    const out = steps(&c, &.{state_only});
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .rounds_exceeded }}, out.effects());
}

test "undeclared input requests end the chain without asking the host" {
    var c: Chain = .init(.{});
    const out = steps(&c, &.{ .start, .{ .answered = .{ .input_required = .{ .requests = 1, .state = true, .supported = false } } } });
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .unsupported_input }}, out.effects());
}

test "an input_required with neither field, and steps after the end, change nothing more" {
    var c: Chain = .init(.{});
    var out = steps(&c, &.{ .start, .{ .answered = .{ .input_required = .{ .requests = 0, .state = false, .supported = true } } } });
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .malformed }}, out.effects());
    out = steps(&c, &.{.provided});
    try testing.expect(out.ignored);
    try testing.expectEqual(@as(usize, 0), out.effects().len);
}

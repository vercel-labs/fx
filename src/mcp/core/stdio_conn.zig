//! The stdio connection core. Events are the client side's actions, `State`
//! is the connection, and
//! effects are what the I/O layer does: spawn, close stdin, signal, arm
//! timers, deliver lines, write. Pure: no I/O, clock, allocation, or globals.
//!
//! Every process gets a new generation. Lines, timers, and exits carry the
//! generation they belong to, so anything from an earlier process is dropped
//! (NoStaleDelivery, SignalsOnTime, NoEarlyRestart).

const std = @import("std");
const trace = @import("../io/trace.zig");

pub const Generation = u32;

pub const State = enum { idle, starting, running, closing, terminating, killing, backoff, failed, stopped };

pub const Era = enum { unknown, modern, legacy };

pub const MessageKind = enum { request, notification, response };

pub const TimerKind = enum { grace, term, backoff };

pub const Signal = enum { term, kill };

pub const Timer = struct {
    kind: TimerKind,
    generation: Generation,
};

pub const Config = struct {
    /// Consecutive failures before the connection is failed.
    max_attempts: u8 = 8,
    /// Wait after closing stdin before SIGTERM, then before SIGKILL.
    grace_ms: u32 = 1_500,
    term_ms: u32 = 1_500,
    /// The backoff doubles from this, up to `backoff_cap_ms`. The I/O
    /// layer adds jitter.
    backoff_ms: u32 = 1_000,
    backoff_cap_ms: u32 = 30_000,
};

pub const Event = union(enum) {
    start_requested,
    spawned,
    spawn_failed,
    /// A valid message line from a process. Invalid lines never get here.
    line_received: Generation,
    /// A line over the limit from a process.
    oversized_line: Generation,
    /// Writing to the current process's stdin failed.
    write_failed,
    process_exited: Generation,
    stop_requested,
    timer_fired: Timer,
    reconnect_requested,
    era_detected: enum { modern, legacy },
    send: MessageKind,
};

pub const Effect = union(enum) {
    spawn: Generation,
    close_stdin: Generation,
    signal: struct { generation: Generation, signal: Signal },
    arm_timer: struct { timer: Timer, after_ms: u32 },
    /// Hand the line to the dispatcher.
    deliver: Generation,
    /// Write the message to the process's stdin.
    write: Generation,
    /// The process is ready for requests.
    ready: Generation,
    /// The process is gone: requests in flight on it end as lost (`transport_lost` in `core/request.zig`).
    lost: Generation,
};

/// The model's variables after a step, for the trace.
pub const Projection = struct {
    generation: Generation,
    attempts: u8,
    era: Era,
    stdin_open: bool,
    stopping: bool,
    errored: bool,
    term_sent: bool,
    kill_sent: bool,
};

/// One model step, written to the trace by `writeTrace`.
pub const Transition = struct {
    event: []const u8,
    from: State,
    to: State,
    /// The model action's parameter: the generation of the line, exit, or timer.
    arg: ?Generation = null,
    timer: ?TimerKind = null,
    kind: ?MessageKind = null,
    /// The event isn't enabled in the model here, so nothing changed.
    ignored: bool = false,
    state: Projection,
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

pub const StepError = error{
    /// Messages can be written only while the connection is running.
    NotRunning,
    /// Responses go only to a 2025 server.
    ResponseNotAllowed,
    GenerationsExhausted,
};

pub const Conn = struct {
    config: Config,
    state: State = .idle,
    generation: Generation = 0,
    attempts: u8 = 0,
    era: Era = .unknown,
    stdin_open: bool = false,
    stopping: bool = false,
    errored: bool = false,
    term_sent: bool = false,
    kill_sent: bool = false,

    pub fn init(config: Config) Conn {
        std.debug.assert(config.max_attempts > 0);
        return .{ .config = config };
    }

    /// Applies one event. Resets `out` first. Errors leave the connection unchanged.
    pub fn step(conn: *Conn, event: Event, out: *Output) StepError!void {
        out.* = .{};
        const from = conn.state;
        var arg: ?Generation = null;
        var ignored = false;
        switch (event) {
            .start_requested => ignored = !(try conn.start(out)),
            .spawned => ignored = !conn.spawned(out),
            .spawn_failed => ignored = !conn.spawnFailed(out),
            .line_received => |g| {
                arg = g;
                if (g == conn.generation and conn.live()) {
                    conn.attempts = 0;
                    out.push(.{ .deliver = g });
                }
            },
            .oversized_line => |g| {
                arg = g;
                if (g == conn.generation and conn.state == .running) conn.connectionError(out);
            },
            .write_failed => {
                if (conn.state == .running) conn.connectionError(out) else ignored = true;
            },
            .process_exited => |g| {
                arg = g;
                ignored = !conn.exited(g, out);
            },
            .stop_requested => ignored = !conn.stop(out),
            .timer_fired => |timer| {
                arg = timer.generation;
                conn.timerFired(timer, out);
            },
            .reconnect_requested => {
                if (conn.state == .failed) {
                    conn.state = .idle;
                    conn.attempts = 0;
                } else ignored = true;
            },
            .era_detected => |era| {
                if (conn.state == .running and conn.era == .unknown) {
                    conn.era = switch (era) {
                        .modern => .modern,
                        .legacy => .legacy,
                    };
                } else ignored = true;
            },
            .send => |kind| {
                if (conn.state != .running) return error.NotRunning;
                if (kind == .response and conn.era != .legacy) return error.ResponseNotAllowed;
                out.push(.{ .write = conn.generation });
            },
        }
        out.transition = .{
            .event = @tagName(event),
            .from = from,
            .to = conn.state,
            .arg = arg,
            .timer = if (event == .timer_fired) event.timer_fired.kind else null,
            .kind = if (event == .send) event.send else null,
            .ignored = ignored,
            .state = conn.projection(),
        };
    }

    fn live(conn: *const Conn) bool {
        return switch (conn.state) {
            .running, .closing, .terminating, .killing => true,
            else => false,
        };
    }

    fn down(conn: *const Conn) bool {
        return switch (conn.state) {
            .idle, .backoff, .failed, .stopped => true,
            else => false,
        };
    }

    fn projection(conn: *const Conn) Projection {
        return .{
            .generation = conn.generation,
            .attempts = conn.attempts,
            .era = conn.era,
            .stdin_open = conn.stdin_open,
            .stopping = conn.stopping,
            .errored = conn.errored,
            .term_sent = conn.term_sent,
            .kill_sent = conn.kill_sent,
        };
    }

    /// Starts on demand, never from backoff. A start after a host stop
    /// is a fresh start, so the failure count resets.
    fn start(conn: *Conn, out: *Output) StepError!bool {
        if (conn.state != .idle and conn.state != .stopped) return false;
        const generation = std.math.add(Generation, conn.generation, 1) catch return error.GenerationsExhausted;
        if (conn.state == .stopped) conn.attempts = 0;
        conn.* = .{ .config = conn.config, .state = .starting, .generation = generation, .attempts = conn.attempts };
        out.push(.{ .spawn = generation });
        return true;
    }

    fn spawned(conn: *Conn, out: *Output) bool {
        if (conn.state != .starting) return false;
        if (conn.stopping) {
            conn.beginClose(out);
        } else {
            conn.state = .running;
            conn.stdin_open = true;
            out.push(.{ .ready = conn.generation });
        }
        return true;
    }

    fn spawnFailed(conn: *Conn, out: *Output) bool {
        if (conn.state != .starting) return false;
        if (conn.stopping) conn.state = .stopped else conn.failure(out);
        return true;
    }

    /// A failed start or an exit the client didn't ask for.
    fn failure(conn: *Conn, out: *Output) void {
        conn.attempts += 1;
        if (conn.attempts >= conn.config.max_attempts) {
            conn.state = .failed;
            return;
        }
        conn.state = .backoff;
        const doubled = @as(u64, conn.config.backoff_ms) << @min(conn.attempts - 1, 32);
        const after_ms: u32 = @intCast(@min(doubled, conn.config.backoff_cap_ms));
        out.push(.{ .arm_timer = .{ .timer = .{ .kind = .backoff, .generation = conn.generation }, .after_ms = after_ms } });
    }

    /// Close stdin first, then wait out the grace period.
    fn beginClose(conn: *Conn, out: *Output) void {
        conn.state = .closing;
        conn.stdin_open = false;
        out.push(.{ .close_stdin = conn.generation });
        out.push(.{ .arm_timer = .{ .timer = .{ .kind = .grace, .generation = conn.generation }, .after_ms = conn.config.grace_ms } });
    }

    /// Kill the process at once, without the polite steps.
    fn connectionError(conn: *Conn, out: *Output) void {
        conn.state = .killing;
        conn.stdin_open = false;
        conn.errored = true;
        conn.kill_sent = true;
        out.push(.{ .close_stdin = conn.generation });
        out.push(.{ .signal = .{ .generation = conn.generation, .signal = .kill } });
    }

    /// The process is reaped. In-flight requests are lost either way.
    fn exited(conn: *Conn, generation: Generation, out: *Output) bool {
        if (generation != conn.generation or !conn.live()) return false;
        conn.stdin_open = false;
        out.push(.{ .lost = generation });
        if (conn.stopping) conn.state = .stopped else conn.failure(out);
        return true;
    }

    fn stop(conn: *Conn, out: *Output) bool {
        if (conn.stopping or conn.state == .stopped) return false;
        conn.stopping = true;
        if (conn.state == .running) {
            conn.beginClose(out);
        } else if (conn.down()) {
            conn.state = .stopped;
        }
        return true;
    }

    /// A timer from an earlier process, or one that fires in
    /// another state, changes nothing.
    fn timerFired(conn: *Conn, timer: Timer, out: *Output) void {
        if (timer.generation != conn.generation) return;
        switch (timer.kind) {
            .grace => if (conn.state == .closing) {
                conn.state = .terminating;
                conn.term_sent = true;
                out.push(.{ .signal = .{ .generation = conn.generation, .signal = .term } });
                out.push(.{ .arm_timer = .{ .timer = .{ .kind = .term, .generation = conn.generation }, .after_ms = conn.config.term_ms } });
            },
            .term => if (conn.state == .terminating) {
                conn.state = .killing;
                conn.kill_sent = true;
                out.push(.{ .signal = .{ .generation = conn.generation, .signal = .kill } });
            },
            .backoff => if (conn.state == .backoff) {
                conn.state = .idle;
            },
        }
    }
};

/// Writes the step in `out` as one trace line for machine "stdio".
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    const t = out.transition orelse return;
    const s = t.state;
    var fields: [13]trace.Field = undefined;
    var count: usize = 0;
    if (t.arg) |g| {
        fields[count] = .{ .name = "arg", .value = .{ .int = g } };
        count += 1;
    }
    if (t.timer) |kind| {
        fields[count] = .{ .name = "timer", .value = .{ .string = @tagName(kind) } };
        count += 1;
    }
    if (t.kind) |kind| {
        fields[count] = .{ .name = "kind", .value = .{ .string = @tagName(kind) } };
        count += 1;
    }
    const projected = [_]trace.Field{
        .{ .name = "ignored", .value = .{ .boolean = t.ignored } },
        .{ .name = "gen", .value = .{ .int = s.generation } },
        .{ .name = "attempts", .value = .{ .int = s.attempts } },
        .{ .name = "era", .value = .{ .string = @tagName(s.era) } },
        .{ .name = "stdin_open", .value = .{ .boolean = s.stdin_open } },
        .{ .name = "stopping", .value = .{ .boolean = s.stopping } },
        .{ .name = "errored", .value = .{ .boolean = s.errored } },
        .{ .name = "term_sent", .value = .{ .boolean = s.term_sent } },
        .{ .name = "kill_sent", .value = .{ .boolean = s.kill_sent } },
    };
    @memcpy(fields[count..][0..projected.len], &projected);
    count += projected.len;
    var effect_names: [max_effects][]const u8 = undefined;
    for (out.effects(), 0..) |effect, index| effect_names[index] = @tagName(effect);
    try writer.write(.{
        .machine = "stdio",
        .instance = instance,
        .event = t.event,
        .from = @tagName(t.from),
        .to = @tagName(t.to),
        .effects = effect_names[0..out.effect_count],
        .data = fields[0..count],
    });
}

const testing = std.testing;

/// The process and pipe the model's environment allows, rebuilt from the
/// core's effects. Tests offer the core only events this world could produce,
/// and check the model's invariants from the effects alone.
const World = struct {
    const max_timers = 32;
    const Proc = enum { none, alive, exited, reaped };

    proc: Proc = .none,
    /// Generation of the current process, from the last spawn effect.
    gen: Generation = 0,
    spawn_pending: bool = false,
    stdin_open: bool = false,
    stdin_closed: bool = false,
    term_sent: bool = false,
    kill_sent: bool = false,
    /// Generations with unread lines.
    pipe: u64 = 0,
    timers: [max_timers]Timer = undefined,
    timer_count: usize = 0,

    fn hasLines(world: *const World, g: Generation) bool {
        return g < 64 and world.pipe & (@as(u64, 1) << @intCast(g)) != 0;
    }

    fn armedIndex(world: *const World, timer: Timer) ?usize {
        for (world.timers[0..world.timer_count], 0..) |t, i| {
            if (t.kind == timer.kind and t.generation == timer.generation) return i;
        }
        return null;
    }

    fn removeTimer(world: *World, index: usize) void {
        world.timer_count -= 1;
        world.timers[index] = world.timers[world.timer_count];
    }
};

const Check = enum { pass, fail };

/// Applies one event to the core and the world, checking every invariant.
/// Environment-only moves (a line, a crash, death after SIGKILL) change the
/// world without a core step. Returns false when the event isn't possible.
fn apply(conn: *Conn, world: *World, move: Move) !bool {
    switch (move) {
        .emit_line => {
            if (world.proc != .alive) return false;
            world.pipe |= @as(u64, 1) << @intCast(world.gen);
            return true;
        },
        .crash => {
            if (world.proc != .alive) return false;
            world.proc = .exited;
            return true;
        },
        .killed => {
            if (world.proc != .alive or !world.kill_sent) return false;
            world.proc = .exited;
            return true;
        },
        .event => |event| {
            switch (event) {
                .spawned, .spawn_failed => if (!world.spawn_pending) return false,
                .line_received, .oversized_line => |g| if (!world.hasLines(g)) return false,
                .process_exited => |g| if (world.proc != .exited or g != world.gen) return false,
                .timer_fired => |t| if (world.armedIndex(t) == null) return false,
                else => {},
            }
            return step(conn, world, event);
        },
    }
}

const Move = union(enum) {
    emit_line,
    crash,
    killed,
    event: Event,
};

fn step(conn: *Conn, world: *World, event: Event) !bool {
    const before = conn.*;
    var out: Output = .{};
    conn.step(event, &out) catch |err| {
        // Refusals change nothing and are only allowed where the model has no Send.
        try testing.expectEqual(before, conn.*);
        switch (err) {
            error.NotRunning => try testing.expect(before.state != .running),
            error.ResponseNotAllowed => try testing.expect(event.send == .response and before.era != .legacy),
            error.GenerationsExhausted => return error.TestUnexpectedResult,
        }
        return true;
    };

    // The world reacts to the event itself.
    switch (event) {
        .spawned => {
            world.spawn_pending = false;
            world.proc = .alive;
            world.stdin_open = true;
        },
        .spawn_failed => world.spawn_pending = false,
        .line_received, .oversized_line => |g| {
            if (event == .oversized_line) world.pipe &= ~(@as(u64, 1) << @intCast(g));
        },
        .process_exited => world.proc = .reaped,
        .timer_fired => |t| world.removeTimer(world.armedIndex(t).?),
        else => {},
    }

    var delivered = false;
    for (out.effects()) |effect| switch (effect) {
        .spawn => |g| {
            // OneProcess.
            try testing.expect(world.proc == .none or world.proc == .reaped);
            try testing.expect(g == world.gen + 1);
            world.* = .{ .gen = g, .spawn_pending = true, .pipe = world.pipe, .timers = world.timers, .timer_count = world.timer_count };
        },
        .close_stdin => |g| {
            try testing.expectEqual(world.gen, g);
            world.stdin_open = false;
            world.stdin_closed = true;
        },
        .signal => |s| {
            try testing.expectEqual(world.gen, s.generation);
            try testing.expect(world.proc != .reaped and world.proc != .none);
            switch (s.signal) {
                .term => {
                    // SignalOrder: after stdin closed, on a host stop, not for an error.
                    try testing.expect(world.stdin_closed and conn.stopping and !conn.errored);
                    // SignalsOnTime: this process's own grace timer just fired.
                    try testing.expect(event == .timer_fired and event.timer_fired.kind == .grace);
                    try testing.expect(world.armedIndex(.{ .kind = .grace, .generation = world.gen }) == null);
                    world.term_sent = true;
                },
                .kill => {
                    try testing.expect(world.term_sent or conn.errored);
                    world.kill_sent = true;
                },
            }
        },
        .arm_timer => |a| {
            try testing.expectEqual(world.gen, a.timer.generation);
            try testing.expect(world.timer_count < World.max_timers);
            world.timers[world.timer_count] = a.timer;
            world.timer_count += 1;
        },
        .deliver => |g| {
            // NoStaleDelivery.
            try testing.expectEqual(world.gen, g);
            try testing.expectEqual(world.gen, event.line_received);
            delivered = true;
        },
        .write => |g| {
            // WritesOnlyWhenOpen and NoClientResponsesModern.
            try testing.expectEqual(world.gen, g);
            try testing.expect(world.stdin_open);
            if (event.send == .response) try testing.expectEqual(Era.legacy, conn.era);
        },
        .ready => |g| try testing.expectEqual(world.gen, g),
        .lost => |g| try testing.expectEqual(world.gen, g),
    };

    // NoOrphan and RestartBounded.
    if (conn.down()) try testing.expect(world.proc == .none or world.proc == .reaped);
    try testing.expect(conn.attempts <= conn.config.max_attempts);
    if (conn.state == .failed) try testing.expectEqual(conn.config.max_attempts, conn.attempts);
    if (conn.state == .backoff) try testing.expect(conn.attempts < conn.config.max_attempts);
    // NoEarlyRestart: a backoff ends only by its own timer.
    if (before.state == .backoff and conn.state == .idle) {
        try testing.expect(event == .timer_fired and event.timer_fired.kind == .backoff and event.timer_fired.generation == conn.generation);
    }

    // Where the model has no choice, the core must act.
    const t = out.transition.?;
    switch (event) {
        .spawned => try testing.expect(conn.state == .running or conn.state == .closing),
        .process_exited => try testing.expect(!conn.live()),
        .line_received => |g| try testing.expectEqual(g == conn.generation and before.live(), delivered),
        .oversized_line => |g| if (g == before.generation and before.state == .running) try testing.expectEqual(State.killing, conn.state),
        .stop_requested => if (before.state == .running) try testing.expectEqual(State.closing, conn.state),
        .timer_fired => |tm| if (tm.generation == before.generation) switch (tm.kind) {
            .grace => if (before.state == .closing) try testing.expectEqual(State.terminating, conn.state),
            .term => if (before.state == .terminating) try testing.expectEqual(State.killing, conn.state),
            .backoff => if (before.state == .backoff) try testing.expectEqual(State.idle, conn.state),
        },
        else => {},
    }
    // An ignored event changed nothing.
    if (t.ignored) {
        try testing.expectEqual(before, conn.*);
        try testing.expectEqual(@as(usize, 0), out.effect_count);
    }
    try testing.expectEqual(conn.state, t.to);
    return true;
}

/// Every move the model's Next could take, for generations up to `max_gen`.
fn candidateMoves(buffer: []Move, max_gen: Generation) []Move {
    var n: usize = 0;
    const fixed = [_]Move{
        .emit_line,                                 .crash,                                     .killed,
        .{ .event = .start_requested },             .{ .event = .spawned },                     .{ .event = .spawn_failed },
        .{ .event = .write_failed },                .{ .event = .stop_requested },              .{ .event = .reconnect_requested },
        .{ .event = .{ .era_detected = .modern } }, .{ .event = .{ .era_detected = .legacy } }, .{ .event = .{ .send = .request } },
        .{ .event = .{ .send = .response } },
    };
    for (fixed) |m| {
        buffer[n] = m;
        n += 1;
    }
    var g: Generation = 1;
    while (g <= max_gen) : (g += 1) {
        for ([_]Move{
            .{ .event = .{ .line_received = g } },
            .{ .event = .{ .oversized_line = g } },
            .{ .event = .{ .process_exited = g } },
            .{ .event = .{ .timer_fired = .{ .kind = .grace, .generation = g } } },
            .{ .event = .{ .timer_fired = .{ .kind = .term, .generation = g } } },
            .{ .event = .{ .timer_fired = .{ .kind = .backoff, .generation = g } } },
        }) |m| {
            buffer[n] = m;
            n += 1;
        }
    }
    return buffer[0..n];
}

const test_config: Config = .{ .max_attempts = 3, .grace_ms = 10, .term_ms = 20, .backoff_ms = 100, .backoff_cap_ms = 300 };

fn explore(conn: Conn, world: World, depth: usize, moves: []const Move, steps: *usize) !void {
    if (depth == 0) return;
    for (moves) |move| {
        var c = conn;
        var w = world;
        if (!try apply(&c, &w, move)) continue;
        steps.* += 1;
        try explore(c, w, depth - 1, moves, steps);
    }
}

test "every move sequence up to depth 6 keeps the model's invariants" {
    var buffer: [40]Move = undefined;
    const moves = candidateMoves(&buffer, 3);
    var steps: usize = 0;
    try explore(.init(test_config), .{}, 6, moves, &steps);
    try testing.expect(steps > 100_000);
}

test "random long runs keep the model's invariants" {
    var buffer: [80]Move = undefined;
    const moves = candidateMoves(&buffer, 10);
    var prng: std.Random.DefaultPrng = .init(0x57d10);
    const random = prng.random();
    var taken: usize = 0;
    for (0..300) |_| {
        var conn: Conn = .init(test_config);
        var world: World = .{};
        var tries: usize = 0;
        while (tries < 400 and conn.generation < 10) : (tries += 1) {
            if (try apply(&conn, &world, moves[random.uintLessThan(usize, moves.len)])) taken += 1;
        }
    }
    try testing.expect(taken > 10_000);
}

/// Drives only the moves the model makes fair: spawning finishes, timers
/// fire, the process dies after SIGKILL, and exits are reaped.
fn settle(conn: *Conn, world: *World) !void {
    for (0..64) |_| {
        if (world.spawn_pending) {
            _ = try apply(conn, world, .{ .event = .spawned });
        } else if (world.proc == .exited) {
            _ = try apply(conn, world, .{ .event = .{ .process_exited = world.gen } });
        } else if (world.proc == .alive and world.kill_sent) {
            _ = try apply(conn, world, .killed);
        } else if (world.timer_count > 0) {
            _ = try apply(conn, world, .{ .event = .{ .timer_fired = world.timers[0] } });
        } else return;
    }
    return error.TestUnexpectedResult;
}

test "a stop always ends stopped, even when the server ignores stdin and SIGTERM (Progress)" {
    var prng: std.Random.DefaultPrng = .init(0x5709);
    const random = prng.random();
    var buffer: [80]Move = undefined;
    const moves = candidateMoves(&buffer, 10);
    for (0..500) |_| {
        var conn: Conn = .init(test_config);
        var world: World = .{};
        for (0..random.uintLessThan(usize, 40)) |_| _ = try apply(&conn, &world, moves[random.uintLessThan(usize, moves.len)]);
        if (conn.state == .stopped) continue;
        try testing.expect(try apply(&conn, &world, .{ .event = .stop_requested }) or conn.stopping);
        try settle(&conn, &world);
        try testing.expectEqual(State.stopped, conn.state);
        try testing.expect(world.proc == .none or world.proc == .reaped);
    }
}

test "shutdown closes stdin, then sends SIGTERM, then SIGKILL" {
    var conn: Conn = .init(test_config);
    var out: Output = .{};
    try conn.step(.start_requested, &out);
    try testing.expectEqual(Effect{ .spawn = 1 }, out.effects()[0]);
    try conn.step(.spawned, &out);
    try testing.expectEqual(Effect{ .ready = 1 }, out.effects()[0]);
    try conn.step(.stop_requested, &out);
    try testing.expectEqualSlices(Effect, &.{
        .{ .close_stdin = 1 },
        .{ .arm_timer = .{ .timer = .{ .kind = .grace, .generation = 1 }, .after_ms = 10 } },
    }, out.effects());
    try conn.step(.{ .timer_fired = .{ .kind = .grace, .generation = 1 } }, &out);
    try testing.expectEqualSlices(Effect, &.{
        .{ .signal = .{ .generation = 1, .signal = .term } },
        .{ .arm_timer = .{ .timer = .{ .kind = .term, .generation = 1 }, .after_ms = 20 } },
    }, out.effects());
    try conn.step(.{ .timer_fired = .{ .kind = .term, .generation = 1 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .signal = .{ .generation = 1, .signal = .kill } }}, out.effects());
    try conn.step(.{ .process_exited = 1 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .lost = 1 }}, out.effects());
    try testing.expectEqual(State.stopped, conn.state);
}

test "failures back off exponentially, then the connection fails until a reconnect" {
    var conn: Conn = .init(.{ .max_attempts = 4, .backoff_ms = 1_000, .backoff_cap_ms = 3_000 });
    var out: Output = .{};
    for ([_]u32{ 1_000, 2_000, 3_000 }) |expected| {
        try conn.step(.start_requested, &out);
        try conn.step(.spawned, &out);
        try conn.step(.{ .process_exited = conn.generation }, &out);
        try testing.expectEqual(State.backoff, conn.state);
        try testing.expectEqual(expected, out.effects()[1].arm_timer.after_ms);
        // A demand during backoff doesn't start a process.
        try conn.step(.start_requested, &out);
        try testing.expect(out.transition.?.ignored);
        try conn.step(.{ .timer_fired = .{ .kind = .backoff, .generation = conn.generation } }, &out);
        try testing.expectEqual(State.idle, conn.state);
    }
    try conn.step(.start_requested, &out);
    try conn.step(.spawn_failed, &out);
    try testing.expectEqual(State.failed, conn.state);
    try conn.step(.start_requested, &out);
    try testing.expect(out.transition.?.ignored);
    try conn.step(.reconnect_requested, &out);
    try testing.expectEqual(State.idle, conn.state);
    try testing.expectEqual(@as(u8, 0), conn.attempts);
}

test "a delivered message resets the failure count; a stale one doesn't" {
    var conn: Conn = .init(test_config);
    var out: Output = .{};
    try conn.step(.start_requested, &out);
    try conn.step(.spawned, &out);
    try conn.step(.{ .process_exited = 1 }, &out);
    try testing.expectEqual(@as(u8, 1), conn.attempts);
    try conn.step(.{ .timer_fired = .{ .kind = .backoff, .generation = 1 } }, &out);
    try conn.step(.start_requested, &out);
    try conn.step(.spawned, &out);
    try conn.step(.{ .line_received = 1 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(@as(u8, 1), conn.attempts);
    try conn.step(.{ .line_received = 2 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = 2 }}, out.effects());
    try testing.expectEqual(@as(u8, 0), conn.attempts);
}

test "responses go only to a 2025 server; nothing is written outside running" {
    var conn: Conn = .init(test_config);
    var out: Output = .{};
    try testing.expectError(error.NotRunning, conn.step(.{ .send = .request }, &out));
    try conn.step(.start_requested, &out);
    try conn.step(.spawned, &out);
    try testing.expectError(error.ResponseNotAllowed, conn.step(.{ .send = .response }, &out));
    try conn.step(.{ .era_detected = .modern }, &out);
    try testing.expectError(error.ResponseNotAllowed, conn.step(.{ .send = .response }, &out));
    try conn.step(.{ .send = .notification }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .write = 1 }}, out.effects());

    var legacy: Conn = .init(test_config);
    try legacy.step(.start_requested, &out);
    try legacy.step(.spawned, &out);
    try legacy.step(.{ .era_detected = .legacy }, &out);
    try legacy.step(.{ .send = .response }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .write = 1 }}, out.effects());
    try legacy.step(.stop_requested, &out);
    try testing.expectError(error.NotRunning, legacy.step(.{ .send = .request }, &out));
}

test "an oversized line kills the process without SIGTERM" {
    var conn: Conn = .init(test_config);
    var out: Output = .{};
    try conn.step(.start_requested, &out);
    try conn.step(.spawned, &out);
    try conn.step(.{ .oversized_line = 1 }, &out);
    try testing.expectEqualSlices(Effect, &.{
        .{ .close_stdin = 1 },
        .{ .signal = .{ .generation = 1, .signal = .kill } },
    }, out.effects());
    try conn.step(.{ .process_exited = 1 }, &out);
    try testing.expectEqual(State.backoff, conn.state);
}

test "writes a model transition as one trace line" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var conn: Conn = .init(test_config);
    var out: Output = .{};
    try conn.step(.start_requested, &out);
    try conn.step(.spawned, &out);
    try conn.step(.{ .timer_fired = .{ .kind = .grace, .generation = 1 } }, &out);
    try writeTrace(&writer, "probe", &out);
    try testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"machine\":\"stdio\",\"inst\":\"probe\",\"event\":\"timer_fired\",\"from\":\"running\",\"to\":\"running\"," ++
            "\"effects\":[],\"data\":{\"arg\":1,\"timer\":\"grace\",\"ignored\":false,\"gen\":1,\"attempts\":0,\"era\":\"unknown\"," ++
            "\"stdin_open\":true,\"stopping\":false,\"errored\":false,\"term_sent\":false,\"kill_sent\":false}}\n",
        buffer.written(),
    );
}

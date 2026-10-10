//! The engine's core for one server: its phase and tries in a row, the host's tool list need, and the
//! tool calls the host made to it. A call goes nowhere without the host's
//! permission. A call to a ready server goes out at once; one to any
//! other server waits, goes out the moment the server is ready, and ends when
//! it gives up. A server starts only when the host needs its tool list or a
//! call waits for it (LazyConnect), at most `max_attempts` times in a row,
//! and after a failure only once its backoff is over. A step that
//! also starts the server is traced as a second record. Pure.

const std = @import("std");
const request = @import("request.zig");
const trace = @import("../io/trace.zig");

pub const Phase = enum { idle, connecting, ready, backoff, failed };
pub const Handle = u32;
/// Calls one server holds, waiting or in flight: below the server's 32
/// logical requests, so its listing, listen, and detection always find room.
pub const max_calls = 24;

pub const Config = struct {
    /// Tries in a row before the server gives up.
    max_attempts: u8 = 8,
};

pub const Event = union(enum) {
    /// The host called; `allowed` is its permission's answer.
    asked: struct { call: Handle, allowed: bool },
    /// The host needs the tool list.
    need,
    /// The host cancelled a call. One in flight is the server's to end.
    cancel: Handle,
    /// The host reconnects (`keep`: what waits stays) or disconnects.
    drop: struct { keep: bool },
    /// The server is ready.
    up,
    /// The start or the link failed.
    down,
    backoff_over,
    /// The server ended a call in flight, however it ended.
    answered: Handle,
};

/// How a call ends without its server's answer.
pub const End = enum { denied, failed, cancelled, lost };

pub const Effect = union(enum) {
    /// Start the server: spawn its process, or detect.
    connect,
    /// Hand the call to the server.
    send: Handle,
    /// The call ends here; the host hears how.
    end: struct { call: Handle, end: End },
    /// Hand the tool list need to the server.
    list,
    /// The server gave up: the host hears its tool list failed.
    refuse_need,
    /// The server may start again after this long.
    arm_backoff: u32,
    /// Stop the server's link. What was in flight on it ended with `end`.
    teardown,
};

/// The model's state of one server after a step, for the trace.
pub const Projection = struct {
    phase: Phase,
    attempts: u8,
    need: bool,
    waiting: u32,
    sent: u32,
    /// The state of the step's call: 0 none, 1 waiting, 2 sent, 3 done.
    state: u8,
};

pub const Output = struct {
    effect_buffer: [max_calls + 4]Effect = undefined,
    effect_count: usize = 0,
    /// The model action; "" for no step at all.
    action: []const u8 = "",
    ignored: bool = false,
    /// The call the step was about, numbered from 1 in the order asked; 0 for none.
    n: u32 = 0,
    /// Set when the step also started the server: the state before that.
    mid: ?Projection = null,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn emit(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Call = struct {
    used: bool = false,
    handle: Handle = 0,
    n: u32 = 0,
    sent: bool = false,
};

pub const Gate = struct {
    config: Config,
    phase: Phase = .idle,
    attempts: u8 = 0,
    need: bool = false,
    calls: [max_calls]Call = @splat(.{}),
    /// The number of the last call asked.
    last: u32 = 0,

    pub fn init(config: Config) Gate {
        return .{ .config = config };
    }

    /// error.TooManyCalls: `max_calls` already wait or are in flight, and
    /// nothing changed.
    pub fn step(s: *Gate, event: Event, out: *Output) error{TooManyCalls}!void {
        switch (event) {
            .asked => |a| {
                const open = for (&s.calls) |*c| {
                    if (!c.used) break c;
                } else if (a.allowed and s.phase != .failed) return error.TooManyCalls else null;
                s.last += 1;
                out.action = "ask";
                out.n = s.last;
                if (!a.allowed) return out.emit(.{ .end = .{ .call = a.call, .end = .denied } });
                if (s.phase == .failed) return out.emit(.{ .end = .{ .call = a.call, .end = .failed } });
                open.?.* = .{ .used = true, .handle = a.call, .n = s.last, .sent = s.phase == .ready };
                if (s.phase == .ready) out.emit(.{ .send = a.call }) else s.connect(out);
            },
            .need => {
                out.action = "need";
                switch (s.phase) {
                    // The model's Need isn't enabled here: nothing changes.
                    .ready => return ignoreWith(out, .list),
                    .failed => return ignoreWith(out, .refuse_need),
                    else => if (s.need) return ignore(out),
                }
                s.need = true;
                s.connect(out);
            },
            .cancel => |handle| {
                out.action = "cancel";
                const c = s.find(handle) orelse return ignore(out);
                out.n = c.n;
                if (c.sent) return ignore(out);
                out.emit(.{ .end = .{ .call = handle, .end = .cancelled } });
                c.* = .{};
            },
            .drop => |d| {
                out.action = "drop";
                out.emit(.teardown);
                for (&s.calls) |*c| if (c.used and (c.sent or !d.keep)) {
                    out.emit(.{ .end = .{ .call = c.handle, .end = .cancelled } });
                    c.* = .{};
                };
                s.phase = .idle;
                s.attempts = 0;
                s.need = s.need and d.keep;
                s.connect(out);
            },
            .up => {
                out.action = "up";
                if (s.phase != .connecting) return ignore(out);
                s.phase = .ready;
                s.attempts = 0;
                if (s.need) out.emit(.list);
                s.need = false;
                for (&s.calls) |*c| if (c.used and !c.sent) {
                    c.sent = true;
                    out.emit(.{ .send = c.handle });
                };
            },
            .down => {
                out.action = "down";
                if (s.phase != .connecting and s.phase != .ready) return ignore(out);
                const gave_up = s.attempts >= s.config.max_attempts;
                for (&s.calls) |*c| if (c.used and (c.sent or gave_up)) {
                    out.emit(.{ .end = .{ .call = c.handle, .end = if (c.sent) .lost else .failed } });
                    c.* = .{};
                };
                if (gave_up) {
                    s.phase = .failed;
                    if (s.need) out.emit(.refuse_need);
                    s.need = false;
                } else {
                    s.phase = .backoff;
                    out.emit(.{ .arm_backoff = request.reconnectDelay(s.attempts -| 1) });
                }
            },
            .backoff_over => {
                out.action = "backoff_over";
                if (s.phase != .backoff) return ignore(out);
                s.phase = .idle;
                s.connect(out);
            },
            .answered => |handle| {
                out.action = "answer";
                const c = s.find(handle) orelse return ignore(out);
                out.n = c.n;
                if (!c.sent) return ignore(out);
                c.* = .{};
            },
        }
    }

    /// The model's Connect, when it is enabled: an idle server that something
    /// needs, with tries left.
    fn connect(s: *Gate, out: *Output) void {
        if (s.phase != .idle or !s.demand() or s.attempts >= s.config.max_attempts) return;
        out.mid = s.project(out.n);
        s.phase = .connecting;
        s.attempts += 1;
        out.emit(.connect);
    }

    pub fn demand(s: *const Gate) bool {
        if (s.need) return true;
        for (s.calls) |c| if (c.used and !c.sent) return true;
        return false;
    }

    fn find(s: *Gate, handle: Handle) ?*Call {
        for (&s.calls) |*c| if (c.used and c.handle == handle) return c;
        return null;
    }

    pub fn project(s: *const Gate, n: u32) Projection {
        var p: Projection = .{ .phase = s.phase, .attempts = s.attempts, .need = s.need, .waiting = 0, .sent = 0, .state = if (n == 0) 0 else 3 };
        for (s.calls) |c| if (c.used) {
            if (c.sent) p.sent += 1 else p.waiting += 1;
            if (c.n == n) p.state = if (c.sent) 2 else 1;
        };
        return p;
    }

    fn ignore(out: *Output) void {
        out.ignored = true;
    }

    fn ignoreWith(out: *Output, effect: Effect) void {
        out.ignored = true;
        out.emit(effect);
    }
};

/// One record per model action: the event's, then "connect" when the step
/// also started the server. Each carries the server's state after it.
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, s: *const Gate, event: Event, out: *const Output) std.Io.Writer.Error!void {
    if (out.action.len == 0) return;
    if (out.mid) |mid| {
        try record(writer, instance, s, event, out, out.action, mid);
        return record(writer, instance, s, event, out, "connect", s.project(out.n));
    }
    try record(writer, instance, s, event, out, out.action, s.project(out.n));
}

fn record(writer: *trace.Writer, instance: []const u8, s: *const Gate, event: Event, out: *const Output, action: []const u8, p: Projection) std.Io.Writer.Error!void {
    try writer.write(.{
        .machine = "engine",
        .instance = instance,
        .event = action,
        .from = "",
        .to = "",
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },
            // TLC's integers are 32-bit; calls stay far below.
            .{ .name = "n", .value = .{ .int = @min(out.n, 1 << 30) } },
            .{ .name = "allowed", .value = .{ .boolean = event == .asked and event.asked.allowed } },
            .{ .name = "keep", .value = .{ .boolean = event == .drop and event.drop.keep } },
            .{ .name = "phase", .value = .{ .int = @intFromEnum(p.phase) } },
            .{ .name = "attempts", .value = .{ .int = p.attempts } },
            .{ .name = "need", .value = .{ .boolean = p.need } },
            .{ .name = "waiting", .value = .{ .int = p.waiting } },
            .{ .name = "sent", .value = .{ .int = p.sent } },
            .{ .name = "state", .value = .{ .int = p.state } },
            .{ .name = "max", .value = .{ .int = s.config.max_attempts } },
        },
    });
}

// ---- tests ----

const testing = std.testing;

/// The model's ghosts for one walk, by call number: whether the host allowed
/// the call, and whether it ever went out.
const World = struct {
    const max_n = 512;
    allowed: [max_n]bool = @splat(false),
    went_out: [max_n]bool = @splat(false),

    fn check(w: *World, s: *const Gate, before: *const Gate, event: Event, out: *const Output) !void {
        if (event == .asked and out.n > 0 and out.n < max_n) w.allowed[out.n] = event.asked.allowed;
        for (out.effects()) |effect| switch (effect) {
            .send => |h| {
                const n = for (s.calls) |c| {
                    if (c.used and c.handle == h) break c.n;
                } else unreachable;
                try testing.expect(w.allowed[n]); // PermissionBeforeCall
                try testing.expectEqual(Phase.ready, s.phase);
                w.went_out[n] = true;
            },
            // LazyConnect: something needed it when it started.
            .connect => {
                const mid = out.mid.?;
                try testing.expect(mid.phase == .idle and (mid.need or mid.waiting > 0));
                try testing.expect(mid.attempts < s.config.max_attempts);
            },
            .end => |e| if (e.end == .denied) try testing.expect(event == .asked and !event.asked.allowed),
            .list => try testing.expect(s.phase == .ready),
            .refuse_need => try testing.expect(s.phase == .failed),
            else => {},
        };
        try testing.expect(s.attempts <= s.config.max_attempts);
        // BoundedReconnect
        if (s.phase == .failed) try testing.expectEqual(s.config.max_attempts, s.attempts);
        // StatusConsistent
        const p = s.project(0);
        if (p.sent > 0) try testing.expectEqual(Phase.ready, s.phase);
        if (s.phase == .failed or s.phase == .ready) try testing.expect(!s.need and p.waiting == 0);
        // Where the model has no choice, the core must act: Connect is enabled.
        try testing.expect(!(s.phase == .idle and s.demand() and s.attempts < s.config.max_attempts));
        // Ignored steps change nothing.
        if (out.ignored and out.mid == null) try testing.expectEqualDeep(before.project(0), s.project(0));
        switch (event) {
            // Ready: a pending tool list need goes to the server.
            .up => if (before.phase == .connecting and before.need) {
                var listed = false;
                for (out.effects()) |effect| listed = listed or effect == .list;
                try testing.expect(listed);
            },
            // Answer needs a call in flight; Cancel one that waits.
            .answered, .cancel => |h| for (before.calls) |c| if (c.used and c.handle == h and c.sent == (event == .cancel)) {
                try testing.expect(out.ignored);
            },
            // A host drop starts the tries over.
            .drop => try testing.expect(s.attempts <= 1),
            else => {},
        }
    }
};

const alphabet = [_]Event{
    .{ .asked = .{ .call = 1, .allowed = true } },
    .{ .asked = .{ .call = 2, .allowed = true } },
    .{ .asked = .{ .call = 3, .allowed = false } },
    .need,
    .{ .cancel = 1 },
    .{ .drop = .{ .keep = true } },
    .{ .drop = .{ .keep = false } },
    .up,
    .down,
    .backoff_over,
    .{ .answered = 1 },
    .{ .answered = 2 },
};

fn walk(s: Gate, w: World, depth: usize) !void {
    if (depth == 0) return;
    for (alphabet) |event| {
        // A handle is asked at most once while it is held, as the engine does.
        if (event == .asked and find2(&s, event.asked.call)) continue;
        var next = s;
        var nw = w;
        var out: Output = .{};
        try next.step(event, &out);
        try nw.check(&next, &s, event, &out);
        try walk(next, nw, depth - 1);
    }
}

fn find2(s: *const Gate, handle: Handle) bool {
    for (s.calls) |c| if (c.used and c.handle == handle) return true;
    return false;
}

test "every event sequence to depth 6 keeps the model's invariants" {
    try walk(.init(.{ .max_attempts = 2 }), .{}, 6);
}

test "random long sequences keep the model's invariants, past max_calls" {
    var prng: std.Random.DefaultPrng = .init(0x12);
    const random = prng.random();
    for (0..200) |_| {
        var s: Gate = .init(.{ .max_attempts = 3 });
        var w: World = .{};
        var handle: Handle = 1;
        for (0..300) |_| {
            const event: Event = switch (random.uintLessThan(u8, 9)) {
                0 => blk: {
                    handle += 1;
                    break :blk .{ .asked = .{ .call = handle, .allowed = random.boolean() } };
                },
                1 => .need,
                2 => .{ .cancel = random.uintAtMost(Handle, handle) },
                3 => .{ .drop = .{ .keep = random.boolean() } },
                4 => .up,
                5 => .down,
                6 => .backoff_over,
                else => .{ .answered = random.uintAtMost(Handle, handle) },
            };
            const before = s;
            var out: Output = .{};
            s.step(event, &out) catch |err| {
                try testing.expectEqual(error.TooManyCalls, err);
                try testing.expectEqualDeep(before, s);
                continue;
            };
            try w.check(&s, &before, event, &out);
        }
    }
}

fn run(s: *Gate, event: Event) !Output {
    var out: Output = .{};
    try s.step(event, &out);
    return out;
}

test "a refused call never reaches the server or starts it (LazyConnect)" {
    var s: Gate = .init(.{});
    const out = try run(&s, .{ .asked = .{ .call = 7, .allowed = false } });
    try testing.expectEqualSlices(Effect, &.{.{ .end = .{ .call = 7, .end = .denied } }}, out.effects());
    try testing.expectEqual(Phase.idle, s.phase);
}

test "a call waits for its server, which starts for it, and goes out when it is ready" {
    var s: Gate = .init(.{});
    var out = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());
    try testing.expectEqual(Phase.idle, out.mid.?.phase);
    out = try run(&s, .need);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    out = try run(&s, .up);
    try testing.expectEqualSlices(Effect, &.{ .list, .{ .send = 1 } }, out.effects());
    out = try run(&s, .{ .asked = .{ .call = 2, .allowed = true } });
    try testing.expectEqualSlices(Effect, &.{.{ .send = 2 }}, out.effects());
    out = try run(&s, .need);
    try testing.expect(out.ignored);
    try testing.expectEqualSlices(Effect, &.{.list}, out.effects());
}

test "failures back off, then the server gives up and ends what waits" {
    var s: Gate = .init(.{ .max_attempts = 2 });
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    var out = try run(&s, .down);
    try testing.expectEqualSlices(Effect, &.{.{ .arm_backoff = 1000 }}, out.effects());
    out = try run(&s, .backoff_over);
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());
    _ = try run(&s, .need);
    out = try run(&s, .down);
    try testing.expectEqualSlices(Effect, &.{ .{ .end = .{ .call = 1, .end = .failed } }, .refuse_need }, out.effects());
    try testing.expectEqual(Phase.failed, s.phase);
    out = try run(&s, .{ .asked = .{ .call = 2, .allowed = true } });
    try testing.expectEqualSlices(Effect, &.{.{ .end = .{ .call = 2, .end = .failed } }}, out.effects());
    // Reconnect starts over.
    _ = try run(&s, .{ .asked = .{ .call = 3, .allowed = false } });
    out = try run(&s, .{ .drop = .{ .keep = true } });
    try testing.expectEqualSlices(Effect, &.{.teardown}, out.effects());
    try testing.expectEqual(Phase.idle, s.phase);
}

test "each time a server is ready its tries start over, so links that keep dying never give up" {
    var s: Gate = .init(.{ .max_attempts = 2 });
    _ = try run(&s, .need);
    for (0..5) |_| {
        _ = try run(&s, .up);
        _ = try run(&s, .down);
        try testing.expectEqual(Phase.backoff, s.phase);
        _ = try run(&s, .backoff_over);
        _ = try run(&s, .need);
        try testing.expectEqual(Phase.connecting, s.phase);
    }
}

test "a ready server's link dies: calls in flight are lost, and it starts again on demand" {
    var s: Gate = .init(.{});
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    _ = try run(&s, .up);
    var out = try run(&s, .down);
    try testing.expectEqualSlices(Effect, &.{ .{ .end = .{ .call = 1, .end = .lost } }, .{ .arm_backoff = 1000 } }, out.effects());
    out = try run(&s, .backoff_over);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Phase.idle, s.phase);
}

test "disconnect ends everything; reconnect keeps what waits and starts again" {
    var s: Gate = .init(.{});
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    _ = try run(&s, .up);
    _ = try run(&s, .down);
    _ = try run(&s, .{ .asked = .{ .call = 2, .allowed = true } });
    var out = try run(&s, .{ .drop = .{ .keep = true } });
    try testing.expectEqualSlices(Effect, &.{ .teardown, .connect }, out.effects());
    out = try run(&s, .{ .drop = .{ .keep = false } });
    try testing.expectEqualSlices(Effect, &.{ .teardown, .{ .end = .{ .call = 2, .end = .cancelled } } }, out.effects());
    try testing.expectEqual(Phase.idle, s.phase);
}

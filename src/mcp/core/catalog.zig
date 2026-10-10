//! Tool catalog core, one server. Events are its actions, and effects say
//! what to do with the
//! tool data, which lives in `protocol/tools.zig` (`Store`). Pure: no I/O,
//! clock, allocation, or globals.
//!
//! The list is cached as one unit. It is fresh only if nothing was
//! invalidated since its listing started and, on a modern server, if
//! every page had a positive TTL; the shortest one sets its expiry. A legacy
//! list stays fresh until an invalidation or a new process.

const std = @import("std");
const trace = @import("../io/trace.zig");

pub const Era = enum { modern, legacy };
pub const Cache = enum { none, fresh, stale };
pub const Pending = enum { none, first, next };
pub const Generation = u64;

pub const Config = struct {
    max_pages: u32 = 100,
};

pub const Event = union(enum) {
    /// A new server process is ready, in this era (after version detection).
    process_started: Era,
    /// The host needs the tool list.
    need,
    /// A complete page arrived and its tools were added to the store.
    /// `more`: it has a cursor. `ttl_ms`: from `tools.parsePage`.
    page_received: struct { more: bool, ttl_ms: u32 },
    /// -32602 for a continuation page.
    invalid_cursor,
    /// Any other end of the page request (an error, `input_required`, a
    /// malformed page, a timeout, or a lost connection).
    page_failed,
    /// `notifications/tools/list_changed`, a call answer that suggests
    /// the list changed, or the host.
    invalidated,
    /// An expiry timer, armed for this generation.
    expired: Generation,
};

pub const Effect = union(enum) {
    /// Request a page: the first without a cursor, the next with the store's cursor.
    send_page: Pending,
    /// Drop the pages gathered so far (`Store.discard`).
    discard_pages,
    /// The listing ended: the gathered list becomes current (`Store.publish`)
    /// and goes to everyone waiting. `fresh`: it may be served from the cache.
    publish: bool,
    /// The listing failed: everyone waiting gets the failure. The current
    /// list stays as it was, and isn't served.
    fail,
    /// Serve the current list from the cache to this need.
    serve,
    /// Expire the current list after this long.
    arm_expiry: struct { generation: Generation, after_ms: u32 },
};

pub const max_effects = 2;

pub const Projection = struct {
    era: ?Era,
    process: u32,
    generation: Generation,
    cache: Cache,
    cache_generation: Generation,
    cached_zero: bool,
    listing: bool,
    start_generation: Generation,
    page: u32,
    restarts: u1,
    zero_ttl: bool,
    pending: Pending,
    waiting: bool,
};

pub const Transition = struct {
    event: []const u8,
    more: ?bool = null,
    ttl_zero: ?bool = null,
    era: ?Era = null,
    state: Projection,
};

pub const Output = struct {
    effect_buffer: [max_effects]Effect = undefined,
    effect_count: usize = 0,
    /// Null for an expiry timer that no longer applies, which is no model step.
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
    /// No server process is ready yet.
    NotReady,
    /// A new process while a listing runs: its page request must end first (the stdio connection ends it as lost).
    Listing,
};

pub const Catalog = struct {
    config: Config = .{},
    era: ?Era = null,
    process: u32 = 0,
    generation: Generation = 0,
    cache: Cache = .none,
    cache_generation: Generation = 0,
    cached_zero: bool = false,
    listing: bool = false,
    start_generation: Generation = 0,
    page: u32 = 0,
    restarts: u1 = 0,
    /// The shortest TTL of the running listing's pages so far.
    ttl_min: u32 = std.math.maxInt(u32),
    pending: Pending = .none,
    waiting: bool = false,

    pub fn init(config: Config) Catalog {
        std.debug.assert(config.max_pages > 0);
        return .{ .config = config };
    }

    /// Applies one event. Resets `out` first. Errors leave the catalog unchanged.
    pub fn step(c: *Catalog, event: Event, out: *Output) StepError!void {
        out.* = .{};
        switch (event) {
            .process_started => |era| {
                if (c.listing) return error.Listing;
                c.process += 1;
                c.era = era;
                c.invalidate();
            },
            .need => {
                if (c.era == null) return error.NotReady;
                if (c.listing) {
                    c.waiting = true;
                } else if (c.cache == .fresh) {
                    out.push(.serve);
                } else {
                    c.listing = true;
                    c.waiting = true;
                    c.startListing(out);
                }
            },
            .page_received => |page| {
                if (c.pending == .none) return error.NotReady;
                c.page += 1;
                c.ttl_min = @min(c.ttl_min, page.ttl_ms);
                if (page.more and c.page < c.config.max_pages) {
                    c.pending = .next;
                    out.push(.{ .send_page = .next });
                } else c.finish(out);
            },
            .invalid_cursor => {
                if (c.pending != .next) return error.NotReady;
                if (c.restarts == 0) {
                    c.restarts = 1;
                    out.push(.discard_pages);
                    c.startListing(out);
                } else c.failListing(out);
            },
            .page_failed => {
                if (c.pending == .none) return error.NotReady;
                c.failListing(out);
            },
            .invalidated => c.invalidate(),
            .expired => |generation| {
                // A timer for an earlier list or generation is no step.
                if (generation != c.generation or c.cache != .fresh or c.era != .modern) return;
                c.cache = .stale;
            },
        }
        out.transition = .{
            .event = @tagName(event),
            .more = if (event == .page_received) event.page_received.more else null,
            .ttl_zero = if (event == .page_received) event.page_received.ttl_ms == 0 else null,
            .era = if (event == .process_started) event.process_started else null,
            .state = c.projection(),
        };
    }

    pub fn projection(c: *const Catalog) Projection {
        return .{
            .era = c.era,
            .process = c.process,
            .generation = c.generation,
            .cache = c.cache,
            .cache_generation = c.cache_generation,
            .cached_zero = c.cached_zero,
            .listing = c.listing,
            .start_generation = c.start_generation,
            .page = c.page,
            .restarts = c.restarts,
            .zero_ttl = c.ttl_min == 0,
            .pending = c.pending,
            .waiting = c.waiting,
        };
    }

    fn invalidate(c: *Catalog) void {
        c.generation += 1;
        if (c.cache == .fresh) c.cache = .stale;
    }

    /// Starts, or restarts, the listing from the first page.
    fn startListing(c: *Catalog, out: *Output) void {
        c.start_generation = c.generation;
        c.page = 0;
        c.ttl_min = std.math.maxInt(u32);
        c.pending = .first;
        out.push(.{ .send_page = .first });
    }

    fn finish(c: *Catalog, out: *Output) void {
        const zero = c.ttl_min == 0;
        const fresh = c.start_generation == c.generation and (c.era == .legacy or !zero);
        c.cache = if (fresh) .fresh else .stale;
        c.cache_generation = c.start_generation;
        c.cached_zero = zero;
        c.endListing();
        out.push(.{ .publish = fresh });
        if (fresh and c.era == .modern) out.push(.{ .arm_expiry = .{ .generation = c.generation, .after_ms = c.ttl_min } });
    }

    fn failListing(c: *Catalog, out: *Output) void {
        c.endListing();
        out.push(.fail);
    }

    fn endListing(c: *Catalog) void {
        c.listing = false;
        c.pending = .none;
        c.waiting = false;
    }
};

/// Writes the step in `out` as one trace line for machine "catalog".
/// Generations are written as integers below 2^53.
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    const t = out.transition orelse return;
    const s = t.state;
    var fields: [16]trace.Field = undefined;
    var count: usize = 0;
    if (t.more) |more| {
        fields[0] = .{ .name = "more", .value = .{ .boolean = more } };
        fields[1] = .{ .name = "ttl_zero", .value = .{ .boolean = t.ttl_zero.? } };
        count = 2;
    }
    if (t.era) |era| {
        fields[count] = .{ .name = "arg_era", .value = .{ .string = @tagName(era) } };
        count += 1;
    }
    const projected = [_]trace.Field{
        .{ .name = "era", .value = .{ .string = if (s.era) |e| @tagName(e) else "none" } },
        .{ .name = "process", .value = .{ .int = s.process } },
        .{ .name = "gen", .value = .{ .int = @intCast(s.generation) } },
        .{ .name = "cache", .value = .{ .string = @tagName(s.cache) } },
        .{ .name = "cache_gen", .value = .{ .int = @intCast(s.cache_generation) } },
        .{ .name = "cached_zero", .value = .{ .boolean = s.cached_zero } },
        .{ .name = "listing", .value = .{ .boolean = s.listing } },
        .{ .name = "start_gen", .value = .{ .int = @intCast(s.start_generation) } },
        .{ .name = "page", .value = .{ .int = s.page } },
        .{ .name = "restarts", .value = .{ .int = s.restarts } },
        .{ .name = "zero_ttl", .value = .{ .boolean = s.zero_ttl } },
        .{ .name = "pending", .value = .{ .string = @tagName(s.pending) } },
        .{ .name = "waiting", .value = .{ .boolean = s.waiting } },
    };
    @memcpy(fields[count..][0..projected.len], &projected);
    count += projected.len;
    var effect_names: [max_effects][]const u8 = undefined;
    for (out.effects(), 0..) |effect, index| effect_names[index] = @tagName(effect);
    try writer.write(.{
        .machine = "catalog",
        .instance = instance,
        .event = t.event,
        .from = "-",
        .to = "-",
        .effects = effect_names[0..out.effect_count],
        .data = fields[0..count],
    });
}

const testing = std.testing;

/// What the host has seen, rebuilt from the core's effects alone. Each check
/// is a model property.
const World = struct {
    era: ?Era = null,
    processes: u32 = 0,
    invalidations: u32 = 0,
    /// Invalidations seen when the running listing (re)started.
    start_invalidations: u32 = 0,
    listing: bool = false,
    pages: u32 = 0,
    restarts: u32 = 0,
    zero_seen: bool = false,
    min_ttl: u32 = std.math.maxInt(u32),
    waiters: u32 = 0,
    /// The current list may be served: published fresh, with no invalidation
    /// or expiry since.
    fresh: bool = false,
    /// Armed expiry timers that haven't fired.
    timers: [4]?Generation = @splat(null),
};

const Move = Event;
const ttls = [_]u32{ 0, 50, 7 };

fn apply(c: *Catalog, w: *World, event: Event) !bool {
    switch (event) {
        .process_started => if (w.processes >= 2 or w.listing) return false,
        .page_received, .page_failed => if (!w.listing) return false,
        .invalid_cursor => if (!w.listing or w.pages == 0) return false,
        .invalidated => if (w.invalidations >= 3) return false,
        .expired => |g| {
            var armed = false;
            for (w.timers) |t| armed = armed or t == g;
            if (!armed) return false;
        },
        .need => if (w.waiters >= 3) return false,
    }
    const before = c.*;
    var out: Output = .{};
    c.step(event, &out) catch |err| {
        try testing.expect(err == error.NotReady and event == .need and w.era == null);
        try testing.expectEqual(before, c.*);
        return true;
    };
    switch (event) {
        .process_started => |era| {
            w.processes += 1;
            w.era = era;
            w.invalidations += 1;
            w.fresh = false;
        },
        .need => w.waiters += 1,
        .page_received => |page| {
            w.pages += 1;
            w.min_ttl = @min(w.min_ttl, page.ttl_ms);
            if (page.ttl_ms == 0) w.zero_seen = true;
        },
        .invalidated => {
            w.invalidations += 1;
            w.fresh = false;
        },
        .expired => |g| {
            for (&w.timers) |*t| if (t.* == g) {
                t.* = null;
                break;
            };
            if (out.transition != null) w.fresh = false;
        },
        else => {},
    }
    for (out.effects()) |effect| switch (effect) {
        .send_page => |which| {
            if (which == .first) {
                if (event == .need) {
                    // OneListing: a listing starts only when none runs.
                    try testing.expect(!w.listing);
                    w.restarts = 0;
                } else {
                    // A restart after an invalid cursor, once.
                    try testing.expect(event == .invalid_cursor);
                    w.restarts += 1;
                    try testing.expect(w.restarts <= 1);
                }
                w.listing = true;
                w.pages = 0;
                w.zero_seen = false;
                w.min_ttl = std.math.maxInt(u32);
                w.start_invalidations = w.invalidations;
            }
            // PagesBounded.
            try testing.expect(w.pages < c.config.max_pages);
        },
        .discard_pages => try testing.expect(event == .invalid_cursor),
        .publish => |fresh| {
            try testing.expect(w.listing);
            // CacheCurrent and ZeroTtlNotCached.
            if (fresh) {
                try testing.expectEqual(w.start_invalidations, w.invalidations);
                if (w.era == .modern) try testing.expect(!w.zero_seen);
            }
            w.listing = false;
            w.waiters = 0;
            w.fresh = fresh;
        },
        .fail => {
            try testing.expect(w.listing);
            w.listing = false;
            w.waiters = 0;
        },
        .serve => {
            // NoStaleServe.
            try testing.expect(w.fresh and !w.listing and event == .need);
            w.waiters -= 1;
        },
        .arm_expiry => |a| {
            try testing.expect(w.era == .modern and w.fresh and a.after_ms == w.min_ttl and a.after_ms > 0);
            for (&w.timers) |*t| if (t.* == null) {
                t.* = a.generation;
                break;
            };
        },
    };
    // A restart drops the pages gathered so far before asking again.
    if (event == .invalid_cursor and w.listing) try testing.expectEqual(Effect.discard_pages, out.effects()[0]);
    // WaitingMeansListing.
    try testing.expectEqual(w.listing, c.waiting);
    try testing.expectEqual(c.waiting, c.listing);
    try testing.expect(!w.listing or w.waiters > 0);
    // Where the model has no choice, the core must act.
    if (event == .need and !before.listing and before.cache != .fresh and w.era != null) try testing.expect(w.listing);
    if (event == .page_received and !event.page_received.more) try testing.expect(!w.listing);
    return true;
}

fn candidateMoves(buffer: []Event) []Event {
    var n: usize = 0;
    for ([_]Event{ .{ .process_started = .modern }, .{ .process_started = .legacy }, .need, .invalid_cursor, .page_failed, .invalidated, .{ .expired = 1 }, .{ .expired = 2 }, .{ .expired = 3 }, .{ .expired = 4 } }) |m| {
        buffer[n] = m;
        n += 1;
    }
    for ([_]bool{ false, true }) |more| for (ttls) |ttl| {
        buffer[n] = .{ .page_received = .{ .more = more, .ttl_ms = ttl } };
        n += 1;
    };
    return buffer[0..n];
}

fn explore(c: Catalog, w: World, depth: usize, moves: []const Event, steps: *usize) !void {
    if (depth == 0) return;
    for (moves) |move| {
        var cc = c;
        var wc = w;
        if (!try apply(&cc, &wc, move)) continue;
        steps.* += 1;
        try explore(cc, wc, depth - 1, moves, steps);
    }
}

test "every event sequence up to depth 8 keeps the model's invariants" {
    var buffer: [24]Event = undefined;
    const moves = candidateMoves(&buffer);
    var steps: usize = 0;
    try explore(.init(.{ .max_pages = 3 }), .{}, 8, moves, &steps);
    try testing.expect(steps > 100_000);
}

test "random long runs keep the invariants, and every need is answered (EveryNeedAnswered)" {
    var buffer: [24]Event = undefined;
    const moves = candidateMoves(&buffer);
    var prng: std.Random.DefaultPrng = .init(0xca7);
    const random = prng.random();
    for (0..2_000) |_| {
        var c: Catalog = .init(.{ .max_pages = 4 });
        var w: World = .{};
        for (0..random.uintLessThan(usize, 80)) |_| _ = try apply(&c, &w, moves[random.uintLessThan(usize, moves.len)]);
        // The server answers every page, here with "more" each time.
        for (0..12) |_| {
            if (!c.waiting) break;
            _ = try apply(&c, &w, .{ .page_received = .{ .more = true, .ttl_ms = 50 } });
        }
        try testing.expect(!c.waiting);
    }
}

test "a fresh modern list is served from the cache until its TTL runs out" {
    var c: Catalog = .init(.{});
    var out: Output = .{};
    try c.step(.{ .process_started = .modern }, &out);
    try c.step(.need, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .send_page = .first }}, out.effects());
    try c.step(.{ .page_received = .{ .more = true, .ttl_ms = 900 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .send_page = .next }}, out.effects());
    try c.step(.{ .page_received = .{ .more = false, .ttl_ms = 300 } }, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .publish = true }, .{ .arm_expiry = .{ .generation = 1, .after_ms = 300 } } }, out.effects());
    try c.step(.need, &out);
    try testing.expectEqualSlices(Effect, &.{.serve}, out.effects());
    try c.step(.{ .expired = 1 }, &out);
    try c.step(.need, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .send_page = .first }}, out.effects());
}

test "an invalidation during a listing keeps its answer out of the cache" {
    var c: Catalog = .init(.{});
    var out: Output = .{};
    try c.step(.{ .process_started = .legacy }, &out);
    try c.step(.need, &out);
    try c.step(.invalidated, &out);
    try c.step(.{ .page_received = .{ .more = false, .ttl_ms = 0 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .publish = false }}, out.effects());
    try c.step(.need, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .send_page = .first }}, out.effects());
    try c.step(.{ .page_received = .{ .more = false, .ttl_ms = 0 } }, &out);
    // A legacy list stays fresh until an invalidation.
    try testing.expectEqualSlices(Effect, &.{.{ .publish = true }}, out.effects());
    try c.step(.{ .expired = 2 }, &out);
    try testing.expect(out.transition == null);
    try testing.expectEqual(Cache.fresh, c.cache);
}

test "a zero TTL on a modern server, or a new process, means listing again" {
    var c: Catalog = .init(.{});
    var out: Output = .{};
    try c.step(.{ .process_started = .modern }, &out);
    try c.step(.need, &out);
    try c.step(.{ .page_received = .{ .more = false, .ttl_ms = 0 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .publish = false }}, out.effects());
    var legacy: Catalog = .init(.{});
    try legacy.step(.{ .process_started = .legacy }, &out);
    try legacy.step(.need, &out);
    try legacy.step(.{ .page_received = .{ .more = false, .ttl_ms = 0 } }, &out);
    try legacy.step(.{ .process_started = .legacy }, &out);
    try legacy.step(.need, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .send_page = .first }}, out.effects());
}

test "pages stop at the limit; an invalid cursor restarts once" {
    var c: Catalog = .init(.{ .max_pages = 2 });
    var out: Output = .{};
    try c.step(.{ .process_started = .modern }, &out);
    try c.step(.need, &out);
    try c.step(.{ .page_received = .{ .more = true, .ttl_ms = 9 } }, &out);
    try c.step(.invalid_cursor, &out);
    try testing.expectEqualSlices(Effect, &.{ .discard_pages, .{ .send_page = .first } }, out.effects());
    try c.step(.{ .page_received = .{ .more = true, .ttl_ms = 9 } }, &out);
    try c.step(.invalid_cursor, &out);
    try testing.expectEqualSlices(Effect, &.{.fail}, out.effects());
    try c.step(.need, &out);
    try c.step(.{ .page_received = .{ .more = true, .ttl_ms = 9 } }, &out);
    try c.step(.{ .page_received = .{ .more = true, .ttl_ms = 9 } }, &out);
    try testing.expectEqual(Effect{ .publish = true }, out.effects()[0]);
    try testing.expectError(error.NotReady, c.step(.invalid_cursor, &out));
}

test "later needs join a running listing; nothing lists before a server is ready" {
    var c: Catalog = .init(.{});
    var out: Output = .{};
    try testing.expectError(error.NotReady, c.step(.need, &out));
    try c.step(.{ .process_started = .modern }, &out);
    try c.step(.need, &out);
    try c.step(.need, &out);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectError(error.Listing, c.step(.{ .process_started = .modern }, &out));
    try c.step(.page_failed, &out);
    try testing.expectEqualSlices(Effect, &.{.fail}, out.effects());
}

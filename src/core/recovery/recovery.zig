//! Recovery for one model request.
//!
//! fx reports what happened to a request through `step`, and `step` answers
//! with a `Plan`: save a record, send the request, replace the status line, or
//! finish. The module decides and fx acts. It performs no I/O, reads no clock,
//! starts no thread, keeps no global state, and never allocates, so the same
//! events at the same times always produce the same plans.
//!
//! Only `succeeded` finishes a request successfully, and only `user_cancel`
//! finishes it any other way. Every failure waits instead: for time, or for
//! the user when only they can fix it (`tests/tla/recovery/Recovery.tla`
//! NeverGivesUp, Heals). Comments below name the model property that pins
//! each rule.
//!
//! Outside code imports only this file, and this file imports only `std`.
//! `scripts/check-recovery-boundary.sh` enforces both in CI.

const std = @import("std");

/// The one entry point. `now_ms` is `std.Io.Clock.boot` in milliseconds,
/// which keeps counting while the machine sleeps. fx carries out the plan's
/// fields in declaration order and reports what happens as later events.
pub fn step(state: *State, event: Event, now_ms: u64) Plan {
    return switch (event) {
        .start => |start| onStart(state, start, now_ms),
        .responding => onResponding(state),
        .succeeded => onSucceeded(state),
        .failed => |failure| onFailed(state, failure, now_ms),
        .tick => onTick(state, now_ms),
        .user_continue => onUserContinue(state, now_ms),
        .user_cancel => onUserCancel(state),
        .closing => onClosing(state, now_ms),
    };
}

/// What fx reports.
pub const Event = union(enum) {
    /// A new request, or one a previous fx process was running.
    start: Start,
    /// The first byte of the current send's response arrived.
    responding,
    /// The response arrived complete.
    succeeded,
    failed: Failure,
    /// Once a second from `start` until `finish`.
    tick,
    /// Enter, a successful sign-in, or a picker choice that retries.
    user_continue,
    /// Esc, or quitting fx.
    user_cancel,
    /// SIGHUP or SIGTERM: fx is exiting, and the request resumes next launch.
    closing,
};

pub const Start = struct {
    /// A record saved by a previous fx process; null starts a new request.
    resume_from: ?Record = null,
    /// The request uses the Fast route, so dropping Fast is a real option.
    fast: bool = false,
};

pub const Failure = struct {
    kind: Kind,
    /// The server's Retry-After, for `rate_limited` and `server`. Zero counts
    /// as absent.
    retry_after_ms: ?u32 = null,

    pub const Kind = enum(u8) {
        /// No path to the gateway; nothing was sent.
        offline = 1,
        /// Connection lost, stream cut short or stalled, or garbled.
        dropped,
        /// 5xx, overloaded, or a provider error.
        server,
        rate_limited,
        /// The context window was exceeded.
        too_long,
        /// 400, 404, 422, or an unavailable model: resending unchanged can't help.
        rejected,
        /// Auth refresh failed, or there are no credentials.
        sign_in,
        quota,
        content_filter,
    };
};

/// What the module asks fx to do, in field order.
pub const Plan = struct {
    /// Persist, replacing any saved record.
    save: ?Record = null,
    /// Start the request.
    send: ?Send = null,
    /// Replace the status line.
    status: ?Status = null,
    /// Delete the saved record; no more events until the next `start`.
    finish: ?Finish = null,
};

/// How to send. `.{}` is a normal request.
pub const Send = packed struct {
    compact_first: bool = false,
    no_fast: bool = false,
};

pub const Finish = enum { succeeded, cancelled };

/// Opaque saved state. fx stores the bytes and hands them back unchanged.
pub const Record = [32]u8;

/// What the status line shows.
pub const Status = struct {
    kind: Kind,
    /// Set when `kind` is `need_user`; tells fx which prompt to show.
    need: ?Need = null,
    /// Canonical wording, shared by every host.
    text: Text = .{},
    /// A form that fits 46 columns; empty when `text` already does.
    short: Text = .{},

    pub const Kind = enum { clear, waiting, retrying, need_user };

    pub const Need = enum(u8) {
        sign_in = 1,
        quota,
        content_filter,
        rejected,
        too_long,
        crash_loop,
    };
};

pub const Text = struct {
    len: u8 = 0,
    bytes: [capacity]u8 = @splat(0),

    pub const capacity = 95;

    pub fn slice(text: *const Text) []const u8 {
        return text.bytes[0..text.len];
    }
};

/// One request's recovery state. fx holds it and passes it to `step`, but
/// never reads or writes its fields. `State{}` comes before the first `start`.
pub const State = struct {
    phase: Phase = .idle,
    flags: Flags = .{},
    need: ?Status.Need = null,
    /// Sends for this request, including the first.
    attempt: u16 = 0,
    /// The most recent failure, which the status line names.
    cause: ?Failure.Kind = null,
    /// Consecutive failures of `streak_kind`; offline never counts.
    streak: u8 = 0,
    streak_kind: ?Failure.Kind = null,
    backoff_step: u8 = 0,
    offline_step: u8 = 0,
    /// Abrupt deaths found with a send in flight, for the crash-loop guard.
    abrupt_deaths: u8 = 0,
    /// Jitter state, seeded from `now_ms` at `start` so replays stay exact.
    seed: u32 = 1,
    /// Request time carried over from earlier fx processes.
    carried_ms: u32 = 0,
    /// When this process started or resumed the request.
    started_ms: u64 = 0,
    wait_until_ms: u64 = 0,
    // The rest is never saved.
    fast: bool = false,
    flowing: bool = false,
    retry_label: RetryLabel = .after_failure,
    /// Key of the status line fx is showing; 0 means clear.
    shown: u32 = 0,
};

const Phase = enum(u8) { idle = 0, sending = 1, waiting = 2, need_user = 3 };

/// Saved in the record, so every bit is part of the format.
const Flags = packed struct(u8) {
    clean_exit: bool = false,
    no_fast: bool = false,
    compacted: bool = false,
    unused: u5 = 0,
};

const RetryLabel = enum { after_failure, compacting, resuming, after_sign_in, after_user };

// Policy.

/// Waits after dropped, server, and rate-limit failures without a
/// Retry-After hint. The last value repeats for every later wait.
const backoff_ms = [_]u32{ 1_000, 2_000, 4_000, 8_000, 16_000, 30_000 };
/// Waits while offline. Retrying costs nothing then: a failed connect sends
/// nothing billable.
const offline_ms = [_]u32{ 1_000, 2_000, 5_000 };
/// Waits keep 80 to 100 percent of their table value, so retries from many
/// processes spread out without ever passing the 30-second cap.
const jitter_floor_percent: u32 = 80;
/// Consecutive same-kind failures before trying another way. Public so a
/// host that asks a copy of `State` how it would send next can look this far
/// ahead.
pub const escalate_after: u8 = 3;
/// Abrupt in-flight deaths before asking the user once.
const crash_loop_after: u8 = 2;
const record_version: u8 = 1;
/// Short forms must fit a 48-column row after the two-column status sign.
const short_columns = 46;

// Events.

/// A new request shows nothing until something goes wrong
/// (`tests/tla/recovery/Recovery.tla` NoFalseAlarm).
fn onStart(state: *State, start: Start, now_ms: u64) Plan {
    if (start.resume_from) |bytes| {
        if (decode(bytes)) |saved| return resumeFrom(state, saved, start.fast, now_ms);
    }
    state.* = .{
        .phase = .sending,
        .attempt = 1,
        .seed = seedFrom(now_ms),
        .started_ms = now_ms,
        .fast = start.fast,
    };
    return .{ .save = encode(state, now_ms), .send = .{} };
}

/// A record left by SIGHUP or SIGTERM resumes without a question, and so does
/// one left while waiting, since the downtime already served as the wait
/// (`tests/tla/recovery/Recovery.tla` ResumesAfterClose). Only abrupt deaths
/// with a send in flight count toward asking once (CrashLoopAsks).
fn resumeFrom(state: *State, saved: State, fast: bool, now_ms: u64) Plan {
    state.* = saved;
    state.fast = fast;
    state.started_ms = now_ms;
    const abrupt = saved.phase == .sending and !saved.flags.clean_exit;
    state.flags.clean_exit = false;
    if (abrupt) state.abrupt_deaths +|= 1;
    if (state.abrupt_deaths >= crash_loop_after) return askUser(state, .crash_loop, now_ms);
    if (saved.phase == .need_user) {
        // decode guarantees a need for need_user; resending is the safe fallback.
        if (saved.need) |need| return askUser(state, need, now_ms);
    }
    state.retry_label = .resuming;
    return sendNow(state, now_ms, .{});
}

/// The first byte clears any recovery status, so a retry warning never sits
/// over a streaming answer (`tests/tla/recovery/Recovery.tla` StatusHonest).
fn onResponding(state: *State) Plan {
    if (state.phase != .sending or state.flowing) return .{};
    state.flowing = true;
    if (state.shown == 0) return .{};
    return .{ .status = show(state, .{ .kind = .clear }) };
}

fn onSucceeded(state: *State) Plan {
    if (state.phase != .sending) return .{};
    const plan: Plan = .{
        .status = if (state.shown != 0) Status{ .kind = .clear } else null,
        .finish = .succeeded,
    };
    state.* = .{};
    return plan;
}

fn onFailed(state: *State, failure: Failure, now_ms: u64) Plan {
    if (state.phase != .sending) return .{};
    state.flowing = false;
    return switch (failure.kind) {
        .offline, .dropped, .server, .rate_limited => waitAfter(state, failure, now_ms),
        .too_long => if (state.flags.compacted) askUser(state, .too_long, now_ms) else compactAndSend(state, now_ms),
        .rejected => askUser(state, .rejected, now_ms),
        .sign_in => askUser(state, .sign_in, now_ms),
        .quota => askUser(state, .quota, now_ms),
        .content_filter => askUser(state, .content_filter, now_ms),
    };
}

/// While recovering, the status changes every second: the countdown while
/// waiting, the elapsed time while a retry is on the wire.
fn onTick(state: *State, now_ms: u64) Plan {
    return switch (state.phase) {
        .waiting => if (now_ms >= state.wait_until_ms)
            sendNow(state, now_ms, .{})
        else
            refresh(state, waitingStatus(state, now_ms)),
        .sending => if (state.shown != 0 and !state.flowing)
            refresh(state, retryingStatus(state, now_ms))
        else
            .{},
        .idle, .need_user => .{},
    };
}

fn onUserContinue(state: *State, now_ms: u64) Plan {
    if (state.phase != .need_user) return .{};
    const label: RetryLabel = if (state.need) |need| switch (need) {
        .crash_loop => .resuming,
        .sign_in => .after_sign_in,
        .quota, .content_filter, .rejected, .too_long => .after_user,
    } else .after_user;
    if (state.need == .crash_loop) state.abrupt_deaths = 0;
    state.need = null;
    state.retry_label = label;
    return sendNow(state, now_ms, .{});
}

fn onUserCancel(state: *State) Plan {
    if (state.phase == .idle) return .{};
    const plan: Plan = .{
        .status = if (state.shown != 0) Status{ .kind = .clear } else null,
        .finish = .cancelled,
    };
    state.* = .{};
    return plan;
}

fn onClosing(state: *State, now_ms: u64) Plan {
    if (state.phase == .idle) return .{};
    state.flags.clean_exit = true;
    return .{ .save = encode(state, now_ms) };
}

// Transitions.

/// Every send goes out with a save, so the record always knows whether a
/// send is in flight. The crash-loop guard depends on that
/// (`tests/tla/recovery/Recovery.tla` SaveBeforeSend).
fn sendNow(state: *State, now_ms: u64, extra: Send) Plan {
    state.phase = .sending;
    state.flowing = false;
    state.attempt +|= 1;
    const send: Send = .{
        .compact_first = extra.compact_first,
        .no_fast = state.flags.no_fast,
    };
    return .{
        .save = encode(state, now_ms),
        .send = send,
        .status = show(state, retryingStatus(state, now_ms)),
    };
}

/// A transient failure always waits before the next send
/// (`tests/tla/recovery/Recovery.tla` NoHotRetry).
fn waitAfter(state: *State, failure: Failure, now_ms: u64) Plan {
    state.phase = .waiting;
    state.cause = failure.kind;
    state.retry_label = .after_failure;
    const delay_ms = switch (failure.kind) {
        .offline => offlineDelay(state),
        .dropped, .server, .rate_limited => transientDelay(state, failure),
        .too_long, .rejected, .sign_in, .quota, .content_filter => unreachable, // routed by onFailed
    };
    state.wait_until_ms = now_ms +| delay_ms;
    return .{
        .save = encode(state, now_ms),
        .status = show(state, waitingStatus(state, now_ms)),
    };
}

fn offlineDelay(state: *State) u32 {
    const delay = offline_ms[@min(state.offline_step, offline_ms.len - 1)];
    state.offline_step +|= 1;
    return delay;
}

fn transientDelay(state: *State, failure: Failure) u32 {
    state.offline_step = 0;
    noteStreak(state, failure.kind);
    escalate(state, failure.kind);
    // The server's hint replaces this wait's backoff step without advancing
    // it, and no hint waits past the ceiling, a rate limit's included.
    if (failure.retry_after_ms) |hint| {
        if (hint > 0) return @min(hint, backoff_ms[backoff_ms.len - 1]);
    }
    const base = backoff_ms[@min(state.backoff_step, backoff_ms.len - 1)];
    state.backoff_step +|= 1;
    return jittered(state, base);
}

/// Compacting changes the request, so it goes out at once: it is a new
/// request, not a resend of the one that failed.
fn compactAndSend(state: *State, now_ms: u64) Plan {
    state.flags.compacted = true;
    state.cause = .too_long;
    state.retry_label = .compacting;
    return sendNow(state, now_ms, .{ .compact_first = true });
}

fn askUser(state: *State, need: Status.Need, now_ms: u64) Plan {
    state.phase = .need_user;
    state.need = need;
    state.flowing = false;
    return .{
        .save = encode(state, now_ms),
        .status = show(state, needStatus(need)),
    };
}

fn noteStreak(state: *State, kind: Failure.Kind) void {
    if (state.streak_kind) |previous| {
        if (previous == kind) {
            state.streak +|= 1;
            return;
        }
    }
    state.streak_kind = kind;
    state.streak = 1;
}

fn escalate(state: *State, kind: Failure.Kind) void {
    if (state.streak < escalate_after) return;
    switch (kind) {
        .server => if (state.fast) {
            state.flags.no_fast = true;
        },
        .offline, .dropped, .rate_limited, .too_long, .rejected, .sign_in, .quota, .content_filter => {},
    }
}

fn seedFrom(now_ms: u64) u32 {
    const mixed: u32 = @truncate(now_ms ^ (now_ms >> 32));
    return (mixed *% 0x9e3779b9) | 1;
}

fn jittered(state: *State, base_ms: u32) u32 {
    var x = state.seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.seed = x;
    const percent = jitter_floor_percent + x % (101 - jitter_floor_percent);
    // percent <= 100, so the result never exceeds base_ms.
    return @intCast(@as(u64, base_ms) * percent / 100);
}

/// Time since the request's first send, across relaunches. Time while no fx
/// process was running is not counted, since the record holds no clock values.
fn elapsedMs(state: *const State, now_ms: u64) u64 {
    return @as(u64, state.carried_ms) +| (now_ms -| state.started_ms);
}

// Wording.

fn reasonText(state: *const State) []const u8 {
    const cause = state.cause orelse return "Retrying";
    return switch (cause) {
        .offline => "Offline",
        .dropped => "Connection lost",
        .server => "Gateway error",
        .rate_limited => "Rate limited",
        .too_long => "Conversation too long",
        .rejected, .sign_in, .quota, .content_filter => "Retrying",
    };
}

fn waitingStatus(state: *const State, now_ms: u64) Status {
    const remaining_ms = state.wait_until_ms -| now_ms;
    const next = Clock.of(@max(1, (remaining_ms +| 999) / 1000));
    const elapsed = Clock.of(elapsedMs(state, now_ms) / 1000);
    const text = if (state.cause == .offline)
        textOf("Offline · next try in {s} · {s}", .{ next.slice(), elapsed.slice() })
    else
        textOf("{s} · next try in {s} · attempt {d} · {s}", .{
            reasonText(state), next.slice(), state.attempt, elapsed.slice(),
        });
    return .{ .kind = .waiting, .text = text };
}

fn retryingStatus(state: *const State, now_ms: u64) Status {
    const elapsed = Clock.of(elapsedMs(state, now_ms) / 1000);
    const text = switch (state.retry_label) {
        .compacting => textOf("Conversation too long · compacting, then retrying", .{}),
        .resuming => textOf("Resuming the interrupted request · attempt {d}", .{state.attempt}),
        .after_sign_in => textOf("Signed in · retrying · attempt {d} · {s}", .{ state.attempt, elapsed.slice() }),
        .after_user => textOf("Retrying · attempt {d} · {s}", .{ state.attempt, elapsed.slice() }),
        .after_failure => if (state.cause == .server and state.flags.no_fast)
            textOf("Gateway error · retrying without Fast · attempt {d} · {s}", .{ state.attempt, elapsed.slice() })
        else
            textOf("{s} · retrying · attempt {d} · {s}", .{ reasonText(state), state.attempt, elapsed.slice() }),
    };
    return .{ .kind = .retrying, .text = text };
}

fn needStatus(need: Status.Need) Status {
    return switch (need) {
        .sign_in => needOf(need, "Sign-in expired · opening /login", ""),
        .quota => needOf(need, "Out of credits", ""),
        .content_filter => needOf(
            need,
            "Blocked by the content filter · press Esc and rephrase",
            "Blocked by content filter · Esc, then rephrase",
        ),
        .rejected => needOf(need, "The provider rejected this request · press Esc", ""),
        .too_long => needOf(
            need,
            "Still too long after compacting · press Esc and shorten your message",
            "Still too long · Esc, then shorten it",
        ),
        .crash_loop => needOf(
            need,
            "This request crashed fx twice · Enter to retry, Esc to cancel",
            "Crashed fx twice · Enter retries, Esc cancels",
        ),
    };
}

fn needOf(need: Status.Need, comptime text: []const u8, comptime short: []const u8) Status {
    return .{ .kind = .need_user, .need = need, .text = constText(text), .short = constText(short) };
}

fn constText(comptime value: []const u8) Text {
    comptime std.debug.assert(value.len <= Text.capacity);
    var text: Text = .{};
    @memcpy(text.bytes[0..value.len], value);
    text.len = value.len;
    return text;
}

/// Formats into a `Text`. Every format here fits the capacity for any
/// attempt or duration, so the fallback exists only to keep `step` total.
fn textOf(comptime format: []const u8, args: anytype) Text {
    var text: Text = .{};
    const written = std.mem.print(&text.bytes, format, args) catch return constText("Recovering");
    text.len = @intCast(written.len);
    return text;
}

/// `12s`, `1m 12s`, or `1h 02m`.
const Clock = struct {
    bytes: [24]u8 = @splat(0),
    len: u8 = 0,

    fn of(seconds: u64) Clock {
        var clock: Clock = .{};
        // 24 bytes hold the longest form: 16 digits of hours plus "h 59m".
        const written = (if (seconds < 60)
            std.mem.print(&clock.bytes, "{d}s", .{seconds})
        else if (seconds < 3600)
            std.mem.print(&clock.bytes, "{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 })
        else
            std.mem.print(&clock.bytes, "{d}h {d:0>2}m", .{ seconds / 3600, seconds % 3600 / 60 })) catch unreachable;
        clock.len = @intCast(written.len);
        return clock;
    }

    fn slice(clock: *const Clock) []const u8 {
        return clock.bytes[0..clock.len];
    }
};

fn statusKey(status: *const Status) u32 {
    if (status.kind == .clear) return 0;
    const key = std.hash.Crc32.hash(status.text.slice());
    return if (key == 0) 1 else key;
}

fn show(state: *State, status: Status) Status {
    state.shown = statusKey(&status);
    return status;
}

/// Emits the status only when its text changed since fx last showed one.
fn refresh(state: *State, status: Status) Plan {
    const key = statusKey(&status);
    if (key == state.shown) return .{};
    state.shown = key;
    return .{ .status = status };
}

// The record.
//
//  0      version
//  1      phase (1 sending, 2 waiting, 3 need_user)
//  2      flags: clean exit, Fast dropped, compacted
//  3      need (0 none)
//  4..5   attempt, little endian
//  6      streak
//  7      abrupt in-flight deaths
//  8      backoff step
//  9      cause (0 none)
//  10     streak kind (0 none)
//  11     offline step
//  12..15 request time so far, ms, little endian
//  16..19 reserved, zero: no wait is saved, because a relaunch resends at once
//  20..23 jitter seed, little endian
//  24..27 reserved, zero
//  28..31 CRC-32 of bytes 0 to 27, little endian

fn encode(state: *const State, now_ms: u64) Record {
    var record: Record = @splat(0);
    record[0] = record_version;
    record[1] = @backingInt(state.phase);
    record[2] = @bitCast(state.flags);
    record[3] = if (state.need) |need| @backingInt(need) else 0;
    std.mem.writeInt(u16, record[4..6], state.attempt, .little);
    record[6] = state.streak;
    record[7] = state.abrupt_deaths;
    record[8] = state.backoff_step;
    record[9] = if (state.cause) |cause| @backingInt(cause) else 0;
    record[10] = if (state.streak_kind) |kind| @backingInt(kind) else 0;
    record[11] = state.offline_step;
    const elapsed = std.math.cast(u32, elapsedMs(state, now_ms)) orelse std.math.maxInt(u32);
    std.mem.writeInt(u32, record[12..16], elapsed, .little);
    std.mem.writeInt(u32, record[20..24], state.seed, .little);
    std.mem.writeInt(u32, record[28..32], std.hash.Crc32.hash(record[0..28]), .little);
    return record;
}

/// Returns null for a record this version can't trust: a bad checksum, an
/// unknown version, or a value outside the format.
fn decode(record: Record) ?State {
    if (std.mem.readInt(u32, record[28..32], .little) != std.hash.Crc32.hash(record[0..28])) return null;
    if (record[0] != record_version) return null;
    for (record[16..20]) |byte| {
        if (byte != 0) return null;
    }
    for (record[24..28]) |byte| {
        if (byte != 0) return null;
    }
    const phase = std.enums.fromInt(Phase, record[1]) orelse return null;
    if (phase == .idle) return null;
    const flags: Flags = @bitCast(record[2]);
    if (flags.unused != 0) return null;
    const need = optionalFromByte(Status.Need, record[3]) catch return null;
    if ((phase == .need_user) != (need != null)) return null;
    const cause = optionalFromByte(Failure.Kind, record[9]) catch return null;
    const streak_kind = optionalFromByte(Failure.Kind, record[10]) catch return null;
    const seed = std.mem.readInt(u32, record[20..24], .little);
    return .{
        .phase = phase,
        .flags = flags,
        .need = need,
        .attempt = std.mem.readInt(u16, record[4..6], .little),
        .cause = cause,
        .streak = record[6],
        .streak_kind = streak_kind,
        .backoff_step = record[8],
        .offline_step = record[11],
        .abrupt_deaths = record[7],
        .seed = if (seed == 0) 1 else seed,
        .carried_ms = std.mem.readInt(u32, record[12..16], .little),
    };
}

fn optionalFromByte(comptime E: type, byte: u8) error{Invalid}!?E {
    if (byte == 0) return null;
    return std.enums.fromInt(E, byte) orelse error.Invalid;
}

// Tests. Production code stays above the first test; the boundary script
// checks that it never acts.

const testing = std.testing;

fn startNew(state: *State, now_ms: u64, fast: bool) Plan {
    return step(state, .{ .start = .{ .fast = fast } }, now_ms);
}

fn fail(state: *State, kind: Failure.Kind, now_ms: u64) Plan {
    return step(state, .{ .failed = .{ .kind = kind } }, now_ms);
}

/// Ticks once a second until a send goes out; returns the plan and its time.
fn tickUntilSend(state: *State, from_ms: u64) struct { plan: Plan, at_ms: u64 } {
    var now_ms = from_ms;
    var ticks: usize = 0;
    while (ticks < 400) : (ticks += 1) {
        now_ms += 1_000;
        const plan = step(state, .tick, now_ms);
        if (plan.send != null) return .{ .plan = plan, .at_ms = now_ms };
    }
    return .{ .plan = .{}, .at_ms = now_ms };
}

fn columns(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    return count;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

test "a dropped connection waits, retries, and clears at the first byte" {
    var state: State = .{};
    const started = startNew(&state, 10_000, false);
    try testing.expect(started.save != null);
    try testing.expectEqual(Send{}, started.send.?);
    try testing.expect(started.status == null);

    const failed = fail(&state, .dropped, 19_000);
    try testing.expect(failed.save != null);
    try testing.expect(failed.send == null);
    try testing.expectEqual(Status.Kind.waiting, failed.status.?.kind);
    try testing.expectEqualStrings("Connection lost · next try in 1s · attempt 1 · 9s", failed.status.?.text.slice());

    const retry = tickUntilSend(&state, 19_000);
    try testing.expect(retry.plan.save != null);
    try testing.expectEqual(Send{}, retry.plan.send.?);
    try testing.expectEqualStrings("Connection lost · retrying · attempt 2 · 10s", retry.plan.status.?.text.slice());

    const flowing = step(&state, .responding, retry.at_ms + 300);
    try testing.expectEqual(Status.Kind.clear, flowing.status.?.kind);
    try testing.expectEqual(Plan{}, step(&state, .tick, retry.at_ms + 1_000));

    const done = step(&state, .succeeded, retry.at_ms + 2_000);
    try testing.expectEqual(Finish.succeeded, done.finish.?);
    try testing.expect(done.status == null);
    try testing.expectEqual(Phase.idle, state.phase);
}

test "the countdown updates once a second while waiting" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    const failed = step(&state, .{ .failed = .{ .kind = .rate_limited, .retry_after_ms = 5_000 } }, 1_000);
    try testing.expectEqualStrings("Rate limited · next try in 5s · attempt 1 · 1s", failed.status.?.text.slice());
    // The same second shows the same text, so there is nothing to redraw.
    try testing.expectEqual(Plan{}, step(&state, .tick, 1_000));
    const later = step(&state, .tick, 2_000);
    try testing.expectEqualStrings("Rate limited · next try in 4s · attempt 1 · 2s", later.status.?.text.slice());
}

test "a retry on the wire keeps counting until the first byte" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    _ = fail(&state, .server, 1_000);
    const retry = tickUntilSend(&state, 1_000);
    const later = step(&state, .tick, retry.at_ms + 1_000);
    try testing.expectEqual(Status.Kind.retrying, later.status.?.kind);
    try testing.expect(!std.mem.eql(u8, retry.plan.status.?.text.slice(), later.status.?.text.slice()));
}

test "a healthy request shows nothing" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    try testing.expectEqual(Plan{}, step(&state, .tick, 1_000));
    try testing.expectEqual(Plan{}, step(&state, .responding, 1_200));
    const done = step(&state, .succeeded, 2_000);
    try testing.expectEqual(Plan{ .finish = .succeeded }, done);
}

test "backoff grows to the 30 second cap and never past it" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    var now_ms: u64 = 0;
    for (0..12) |round| {
        // Alternate kinds so neither escalates; both share the backoff.
        _ = fail(&state, if (round % 2 == 0) .server else .rate_limited, now_ms);
        const wait_ms = state.wait_until_ms - now_ms;
        const base = backoff_ms[@min(round, backoff_ms.len - 1)];
        try testing.expect(wait_ms <= base);
        try testing.expect(wait_ms >= @as(u64, base) * jitter_floor_percent / 100);
        try testing.expect(wait_ms <= 30_000);
        if (round >= backoff_ms.len) try testing.expect(wait_ms >= 24_000);
        const retry = tickUntilSend(&state, now_ms);
        try testing.expect(retry.plan.send != null);
        try testing.expect(retry.at_ms >= state.wait_until_ms or state.phase == .sending);
        now_ms = retry.at_ms;
    }
}

test "rate limits wait as long as the server asks, capped at the ceiling" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    _ = step(&state, .{ .failed = .{ .kind = .rate_limited, .retry_after_ms = 20_000 } }, 5_000);
    try testing.expectEqual(@as(u64, 25_000), state.wait_until_ms);
    try testing.expect(step(&state, .tick, 24_999).send == null);
    try testing.expect(step(&state, .tick, 25_000).send != null);

    // A longer hint waits the 30 second ceiling.
    _ = step(&state, .{ .failed = .{ .kind = .rate_limited, .retry_after_ms = 600_000 } }, 30_000);
    try testing.expectEqual(@as(u64, 60_000), state.wait_until_ms);
    try testing.expect(step(&state, .tick, 60_000).send != null);

    // Hints never advanced the backoff, so the first unhinted wait is the
    // first step. A zero hint carries no information and falls back to it.
    _ = step(&state, .{ .failed = .{ .kind = .rate_limited, .retry_after_ms = 0 } }, 70_000);
    try testing.expect(state.wait_until_ms > 70_000);
    try testing.expect(state.wait_until_ms <= 70_000 + backoff_ms[0]);
}

test "offline retries every few seconds and never escalates" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    var now_ms: u64 = 0;
    const expected = [_]u64{ 1_000, 2_000, 5_000, 5_000, 5_000 };
    for (expected) |wait_ms| {
        const plan = fail(&state, .offline, now_ms);
        try testing.expectEqual(now_ms + wait_ms, state.wait_until_ms);
        try testing.expect(startsWith(plan.status.?.text.slice(), "Offline · next try in "));
        now_ms = tickUntilSend(&state, now_ms).at_ms;
    }
    try testing.expectEqual(Flags{}, state.flags);
    try testing.expectEqual(@as(u8, 0), state.streak);
}

test "repeated drops keep retrying the same way" {
    var state: State = .{};
    _ = startNew(&state, 0, true);
    var now_ms: u64 = 0;
    var last: Plan = .{};
    for (0..5) |_| {
        _ = fail(&state, .dropped, now_ms);
        const retry = tickUntilSend(&state, now_ms);
        last = retry.plan;
        now_ms = retry.at_ms;
    }
    try testing.expectEqual(Send{}, last.send.?);
    try testing.expect(startsWith(last.status.?.text.slice(), "Connection lost · retrying · attempt 6"));
}

test "a server's Retry-After sets the wait, capped at the ceiling" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    _ = step(&state, .{ .failed = .{ .kind = .server, .retry_after_ms = 3_000 } }, 1_000);
    try testing.expectEqual(@as(u64, 4_000), state.wait_until_ms);
    _ = tickUntilSend(&state, 1_000);
    _ = step(&state, .{ .failed = .{ .kind = .server, .retry_after_ms = 600_000 } }, 10_000);
    try testing.expectEqual(@as(u64, 40_000), state.wait_until_ms);
}

test "three gateway errors drop Fast only when Fast is on" {
    for ([_]bool{ true, false }) |fast| {
        var state: State = .{};
        _ = startNew(&state, 0, fast);
        var now_ms: u64 = 0;
        var last: Plan = .{};
        for (0..3) |_| {
            _ = fail(&state, .server, now_ms);
            const retry = tickUntilSend(&state, now_ms);
            last = retry.plan;
            now_ms = retry.at_ms;
        }
        try testing.expectEqual(fast, last.send.?.no_fast);
        const text = last.status.?.text.slice();
        if (fast) {
            try testing.expect(startsWith(text, "Gateway error · retrying without Fast · attempt 4"));
        } else {
            try testing.expect(startsWith(text, "Gateway error · retrying · attempt 4"));
        }
    }
}

test "too long compacts once at once, then waits for the user" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    const compact = fail(&state, .too_long, 1_000);
    try testing.expect(compact.save != null);
    try testing.expectEqual(Send{ .compact_first = true }, compact.send.?);
    try testing.expectEqualStrings("Conversation too long · compacting, then retrying", compact.status.?.text.slice());

    const ask = fail(&state, .too_long, 2_000);
    try testing.expect(ask.send == null);
    try testing.expectEqual(Status.Need.too_long, ask.status.?.need.?);
    try testing.expectEqualStrings("Still too long · Esc, then shorten it", ask.status.?.short.slice());
}

test "out of credits waits for the user and continues after Enter" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    const ask = fail(&state, .quota, 3_000);
    try testing.expectEqual(Status.Need.quota, ask.status.?.need.?);
    try testing.expectEqualStrings("Out of credits", ask.status.?.text.slice());
    try testing.expectEqual(Plan{}, step(&state, .tick, 60_000));

    const resumed = step(&state, .user_continue, 64_000);
    try testing.expect(resumed.save != null);
    try testing.expectEqual(Send{}, resumed.send.?);
    try testing.expectEqualStrings("Retrying · attempt 2 · 1m 04s", resumed.status.?.text.slice());
}

test "sign-in waits, then names the retry" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    const ask = fail(&state, .sign_in, 1_000);
    try testing.expectEqualStrings("Sign-in expired · opening /login", ask.status.?.text.slice());
    try testing.expectEqual(@as(u8, 0), ask.status.?.short.len);
    const resumed = step(&state, .user_continue, 64_000);
    try testing.expectEqualStrings("Signed in · retrying · attempt 2 · 1m 04s", resumed.status.?.text.slice());
}

test "Esc ends the request from every active phase" {
    const setups = [_]Failure.Kind{ .dropped, .quota, .offline };
    for (setups) |kind| {
        var state: State = .{};
        _ = startNew(&state, 0, false);
        _ = fail(&state, kind, 1_000);
        const cancelled = step(&state, .user_cancel, 2_000);
        try testing.expectEqual(Finish.cancelled, cancelled.finish.?);
        try testing.expectEqual(Status.Kind.clear, cancelled.status.?.kind);
        try testing.expectEqual(Phase.idle, state.phase);
    }
    var sending: State = .{};
    _ = startNew(&sending, 0, false);
    try testing.expectEqual(Plan{ .finish = .cancelled }, step(&sending, .user_cancel, 1_000));
}

test "events that don't apply are ignored" {
    var idle: State = .{};
    for ([_]Event{ .responding, .succeeded, .tick, .user_continue, .user_cancel, .closing }) |event| {
        try testing.expectEqual(Plan{}, step(&idle, event, 1_000));
    }
    try testing.expectEqual(Plan{}, fail(&idle, .dropped, 1_000));

    var waiting: State = .{};
    _ = startNew(&waiting, 0, false);
    _ = fail(&waiting, .dropped, 1_000);
    try testing.expectEqual(Plan{}, step(&waiting, .responding, 1_100));
    try testing.expectEqual(Plan{}, step(&waiting, .succeeded, 1_200));
    try testing.expectEqual(Plan{}, fail(&waiting, .server, 1_300));
    try testing.expectEqual(Plan{}, step(&waiting, .user_continue, 1_400));
}

test "a closed window resumes without a question" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    _ = fail(&state, .dropped, 1_000);
    _ = tickUntilSend(&state, 1_000);
    for (0..3) |_| {
        const closing = step(&state, .closing, 5_000);
        const record = closing.save.?;
        state = .{};
        const resumed = step(&state, .{ .start = .{ .resume_from = record } }, 100);
        try testing.expect(resumed.send != null);
        try testing.expect(startsWith(resumed.status.?.text.slice(), "Resuming the interrupted request · attempt "));
        try testing.expectEqual(@as(u8, 0), state.abrupt_deaths);
    }
}

test "a relaunch during a wait resends at once" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    // The longest wait there is, so the relaunch lands inside it.
    const record = step(&state, .{ .failed = .{ .kind = .rate_limited, .retry_after_ms = 30_000 } }, 1_000).save.?;
    state = .{};
    const resumed = step(&state, .{ .start = .{ .resume_from = record } }, 10);
    try testing.expect(resumed.save != null);
    try testing.expectEqual(Send{}, resumed.send.?);
}

test "two abrupt deaths with a send in flight ask once" {
    var state: State = .{};
    var record = startNew(&state, 0, false).save.?;

    state = .{};
    const first = step(&state, .{ .start = .{ .resume_from = record } }, 50);
    try testing.expect(first.send != null);
    record = first.save.?;

    state = .{};
    const second = step(&state, .{ .start = .{ .resume_from = record } }, 50);
    try testing.expect(second.send == null);
    try testing.expectEqual(Status.Need.crash_loop, second.status.?.need.?);
    try testing.expectEqualStrings("Crashed fx twice · Enter retries, Esc cancels", second.status.?.short.slice());

    const resumed = step(&state, .user_continue, 900);
    try testing.expect(resumed.send != null);
    try testing.expectEqual(@as(u8, 0), state.abrupt_deaths);
}

test "a death while waiting is not a crash loop" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    var record = fail(&state, .dropped, 1_000).save.?;
    for (0..3) |_| {
        state = .{};
        const resumed = step(&state, .{ .start = .{ .resume_from = record } }, 10);
        try testing.expect(resumed.send != null);
        record = fail(&state, .dropped, 20).save.?;
    }
}

test "a request waiting for the user resumes waiting" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    const record = fail(&state, .content_filter, 1_000).save.?;
    state = .{};
    const resumed = step(&state, .{ .start = .{ .resume_from = record } }, 10);
    try testing.expect(resumed.send == null);
    try testing.expectEqual(Status.Need.content_filter, resumed.status.?.need.?);
}

test "request time survives a relaunch" {
    var state: State = .{};
    _ = startNew(&state, 0, false);
    const record = fail(&state, .server, 70_000).save.?;
    state = .{};
    // A reboot starts the clock over; the record carries durations only.
    _ = step(&state, .{ .start = .{ .resume_from = record } }, 5);
    _ = fail(&state, .server, 5_005);
    try testing.expectEqual(@as(u64, 75_000), elapsedMs(&state, 5_005));
}

test "records round-trip and damaged records start fresh" {
    var state: State = .{};
    _ = startNew(&state, 123_456, true);
    _ = fail(&state, .server, 130_000);
    const record = encode(&state, 130_000);
    const restored = decode(record).?;
    try testing.expectEqual(state.phase, restored.phase);
    try testing.expectEqual(state.attempt, restored.attempt);
    try testing.expectEqual(state.cause, restored.cause);
    try testing.expectEqual(state.seed, restored.seed);
    try testing.expectEqual(@as(u32, 6_544), restored.carried_ms);

    for (0..record.len) |index| {
        var damaged = record;
        damaged[index] ^= 0x01;
        try testing.expect(decode(damaged) == null);
    }

    var fresh: State = .{};
    var damaged = record;
    damaged[5] ^= 0xff;
    const plan = step(&fresh, .{ .start = .{ .resume_from = damaged } }, 0);
    try testing.expectEqual(@as(u16, 1), fresh.attempt);
    try testing.expectEqual(Send{}, plan.send.?);
    try testing.expect(plan.status == null);
}

test "a record from an unknown version starts fresh" {
    var state: State = .{};
    var record = startNew(&state, 0, false).save.?;
    record[0] = record_version + 1;
    std.mem.writeInt(u32, record[28..32], std.hash.Crc32.hash(record[0..28]), .little);
    try testing.expect(decode(record) == null);
}

test "every status fits, and every short form fits 46 columns" {
    for (std.enums.values(Status.Need)) |need| {
        const status = needStatus(need);
        try testing.expect(status.text.len > 0);
        if (status.short.len == 0) {
            try testing.expect(columns(status.text.slice()) <= short_columns);
        } else {
            try testing.expect(columns(status.short.slice()) <= short_columns);
        }
    }
    var state: State = .{
        .phase = .waiting,
        .attempt = std.math.maxInt(u16),
        .cause = .server,
        .flags = .{ .no_fast = true },
        .carried_ms = std.math.maxInt(u32),
        .wait_until_ms = std.math.maxInt(u64),
    };
    try testing.expect(!std.mem.eql(u8, "Recovering", waitingStatus(&state, 0).text.slice()));
    try testing.expect(!std.mem.eql(u8, "Recovering", retryingStatus(&state, 0).text.slice()));
    state.retry_label = .after_sign_in;
    try testing.expect(!std.mem.eql(u8, "Recovering", retryingStatus(&state, 0).text.slice()));
}

test "durations read 12s, 1m 12s, and 1h 02m" {
    try testing.expectEqualStrings("0s", Clock.of(0).slice());
    try testing.expectEqualStrings("12s", Clock.of(12).slice());
    try testing.expectEqualStrings("1m 12s", Clock.of(72).slice());
    try testing.expectEqualStrings("3m 05s", Clock.of(185).slice());
    try testing.expectEqualStrings("1h 02m", Clock.of(3_720).slice());
}

test "the same events at the same times produce the same plans" {
    const events = [_]struct { event: Event, at_ms: u64 }{
        .{ .event = .{ .start = .{ .fast = true } }, .at_ms = 77_123 },
        .{ .event = .{ .failed = .{ .kind = .server } }, .at_ms = 78_000 },
        .{ .event = .tick, .at_ms = 79_000 },
        .{ .event = .tick, .at_ms = 80_000 },
        .{ .event = .{ .failed = .{ .kind = .server } }, .at_ms = 80_500 },
        .{ .event = .tick, .at_ms = 84_000 },
        .{ .event = .responding, .at_ms = 84_200 },
        .{ .event = .succeeded, .at_ms = 85_000 },
    };
    var first: State = .{};
    var second: State = .{};
    for (events) |entry| {
        const a = step(&first, entry.event, entry.at_ms);
        const b = step(&second, entry.event, entry.at_ms);
        try testing.expectEqualDeep(a, b);
    }
}

// Simulation: random hosts that follow fx's side of the contract, with
// junk events mixed in, checked against the rules after every step.

const SimHost = struct {
    state: State = .{},
    now_ms: u64,
    fast: bool,
    saved: ?Record = null,
    outstanding: bool = false,
    flowing: bool = false,
    status: Status.Kind = .clear,
    need: ?Status.Need = null,
    finished: bool = false,
    /// Abrupt deaths with a send in flight since the last crash-loop continue.
    inflight_deaths: u8 = 0,
    /// When the latest transient failure happened; a retry must wait after it.
    transient_failure_ms: ?u64 = null,

    fn deliver(host: *SimHost, event: Event) !void {
        const was_outstanding = host.outstanding;
        const was_flowing = host.flowing;
        const plan = step(&host.state, event, host.now_ms);
        const consumes_send = switch (event) {
            .succeeded, .failed => true,
            else => false,
        };
        const open = was_outstanding and !consumes_send;

        if (plan.save) |record| try testing.expect(decode(record) != null);
        if (plan.send != null) {
            // Every send goes out with a save, and never on top of another.
            try testing.expect(plan.save != null);
            try testing.expect(!open);
        }
        if (plan.finish) |finish| switch (finish) {
            .succeeded => try testing.expect(event == .succeeded and was_outstanding),
            .cancelled => try testing.expect(event == .user_cancel),
        };
        if (!was_outstanding) switch (event) {
            .responding, .succeeded, .failed => try testing.expectEqual(Plan{}, plan),
            else => {},
        };
        if (event == .failed and was_outstanding) {
            switch (event.failed.kind) {
                .offline, .dropped, .server, .rate_limited => {
                    try testing.expect(plan.send == null);
                    try testing.expectEqual(Status.Kind.waiting, plan.status.?.kind);
                    host.transient_failure_ms = host.now_ms;
                },
                .too_long, .rejected, .sign_in, .quota, .content_filter => {},
            }
        }
        if (plan.send != null and event == .tick) {
            const failed_at = host.transient_failure_ms orelse return error.TestUnexpectedResult;
            try testing.expect(host.now_ms - failed_at >= 800);
        }
        if (plan.status) |status| {
            switch (status.kind) {
                .clear => {},
                .waiting, .retrying, .need_user => try testing.expect(status.text.len > 0),
            }
            try testing.expectEqual(status.kind == .need_user, status.need != null);
            try testing.expect(columns(status.short.slice()) <= short_columns);
            try testing.expect(std.mem.find(u8, status.text.slice(), "Failed") == null);
            try testing.expect(std.mem.findScalar(u8, status.text.slice(), '_') == null);
        }

        if (consumes_send) host.outstanding = false;
        if (event == .responding and was_outstanding) host.flowing = true;
        if (plan.save) |record| host.saved = record;
        if (plan.send != null) {
            host.outstanding = true;
            host.flowing = false;
            host.transient_failure_ms = null;
        }
        if (plan.status) |status| {
            host.status = status.kind;
            host.need = status.need;
        }
        if (plan.finish != null) {
            host.finished = true;
            host.saved = null;
            host.outstanding = false;
        }
        if (event == .responding and was_outstanding and !was_flowing) {
            try testing.expectEqual(Status.Kind.clear, host.status);
        }
    }

    fn userContinue(host: *SimHost) !void {
        if (host.status == .need_user and host.need == .crash_loop) host.inflight_deaths = 0;
        try host.deliver(.user_continue);
    }

    /// The process dies, gracefully or not, and fx starts again.
    fn relaunch(host: *SimHost, graceful: bool) !void {
        if (graceful) {
            try host.deliver(.closing);
        } else if (host.outstanding) {
            host.inflight_deaths +|= 1;
        }
        host.state = .{};
        host.outstanding = false;
        host.flowing = false;
        host.status = .clear;
        host.need = null;
        host.transient_failure_ms = null;
        host.now_ms += 5_000;
        const record = host.saved orelse return;
        try host.deliver(.{ .start = .{ .resume_from = record, .fast = host.fast } });
        const asked_crash_loop = host.status == .need_user and host.need == .crash_loop;
        try testing.expectEqual(host.inflight_deaths >= crash_loop_after, asked_crash_loop);
    }
};

fn randomFailure(random: std.Random) Failure {
    const kinds = [_]Failure.Kind{
        .dropped,      .dropped,  .server,   .server,  .offline, .offline,
        .rate_limited, .too_long, .rejected, .sign_in, .quota,   .content_filter,
    };
    const kind = kinds[random.uintLessThan(usize, kinds.len)];
    const hint: ?u32 = if (kind == .rate_limited and random.boolean())
        random.intRangeAtMost(u32, 0, 20_000)
    else
        null;
    return .{ .kind = kind, .retry_after_ms = hint };
}

fn simulate(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var host: SimHost = .{
        .now_ms = random.intRangeAtMost(u64, 0, 1 << 40),
        .fast = random.boolean(),
    };
    try host.deliver(.{ .start = .{ .fast = host.fast } });

    // Chaos: faults, deaths, junk, sleeps, and the user.
    var events: usize = 0;
    while (events < 48 and !host.finished) : (events += 1) {
        const roll = random.uintLessThan(u8, 100);
        switch (roll) {
            0...14 => try host.deliver(.responding),
            15...34 => try host.deliver(.{ .failed = randomFailure(random) }),
            35...38 => try host.deliver(.succeeded),
            39...68 => {
                host.now_ms += 1_000;
                try host.deliver(.tick);
            },
            69...73 => try host.userContinue(),
            74...75 => try host.deliver(.user_cancel),
            76...83 => try host.relaunch(false),
            84...90 => try host.relaunch(true),
            else => {
                // The machine slept.
                host.now_ms += random.intRangeAtMost(u64, 1_000, 30 * 60 * 1_000);
                try host.deliver(.tick);
            },
        }
    }

    // Heal: the world works and the user does what is asked. Every request
    // must finish, and no wait may outlast its cap.
    var steps: usize = 0;
    var ticks_waiting: usize = 0;
    while (!host.finished) : (steps += 1) {
        try testing.expect(steps < 400);
        if (host.status == .need_user) {
            try host.userContinue();
        } else if (host.outstanding) {
            if (!host.flowing) try host.deliver(.responding);
            try host.deliver(.succeeded);
        } else {
            host.now_ms += 1_000;
            ticks_waiting += 1;
            try host.deliver(.tick);
            if (host.outstanding) ticks_waiting = 0;
            try testing.expect(ticks_waiting <= 31);
        }
    }
}

test "simulation: the rules hold across random hosts and faults" {
    var seed: u64 = 0;
    while (seed < 10_000) : (seed += 1) {
        simulate(seed) catch |err| {
            std.debug.print("recovery simulation failed with seed {d}\n", .{seed});
            return err;
        };
    }
}

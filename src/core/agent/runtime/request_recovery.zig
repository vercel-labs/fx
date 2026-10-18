//! Carries out `src/core/recovery/` plans for one model request.
//!
//! The recovery module decides and this file acts. The turn loop reports what
//! happened to the request (`start`, `failed`, `responding`, `succeeded`,
//! `cancel`), and each report becomes one `recovery.step` call on the boot
//! clock. Its plan's status goes to the host, and its send tells the loop to
//! resend. Between sends `waitForSend` delivers `tick` once a second and polls
//! the cancel flag every 25 ms. While a send is on the wire, a ticker keeps the
//! retrying status counting: a thread in threaded builds, or the transport's
//! cooperative pulse in single-threaded ones.
//!
//! The module's state is not thread-safe, so every `step` call holds `mutex`.
//! Statuses are pushed under the same lock, so the host sees them in the order
//! the module produced them.
//!
//! This change does not persist `Plan.save`: fx's recovery checkpoint still
//! owns resume. `Plan.finish` has no record to delete for the same reason.
//!
//! The module retries every transient failure for as long as it lasts. Some
//! failures may never heal, so fx bounds them here, outside the module: see
//! `Repeating` for the four classes.

const std = @import("std");
const builtin = @import("builtin");
const recovery = @import("../../recovery/recovery.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const runtime_deps = @import("deps.zig");

pub const Failure = recovery.Failure;
pub const Send = recovery.Send;

/// The module expects `tick` once a second from `start` until `finish`.
const tick_ms: u64 = 1_000;
/// How often a wait checks for Esc.
const cancel_poll_ms: u64 = 25;
/// Tests run the ticker thread fast; the module still sees the virtual clock.
const ticker_interval_ns: i96 = if (builtin.is_test) 5 * std.time.ns_per_ms else tick_ms * std.time.ns_per_ms;
/// The virtual boot clock tests start at.
const test_epoch_ms: u64 = 1_000_000;

/// The module's failure kind for each of fx's transient causes, and null for
/// a cause that never reaches it. Every failure site in the turn loop reports
/// through this.
pub fn failureKind(cause: types.ModelRecoveryCause) ?Failure.Kind {
    return switch (cause) {
        // A path that is down sent nothing.
        .connectivity_lost, .system_resumed => .offline,
        // A connection that broke after connecting may have sent the request.
        .network_interrupted, .response_interrupted, .provider_stream_timeout => .dropped,
        .provider_unavailable => .server,
        .rate_limited => .rate_limited,
        .authentication, .request_limit_reached, .compaction_prepared => null,
    };
}

/// Failures fx cannot tell apart from a fault that never heals: fx classifies
/// what has a code and bounds what is unclear. std reports a certificate fx
/// will never accept as the same `TlsInitializationFailed` as a passing setup
/// failure, a stream that ends without a finish event may end that way every
/// time, and a provider error with neither a code nor a usable HTTP status
/// (`uncoded_error`) or with no error event at all
/// (`unexplained_error_finish`) says nothing about a resend. The module keeps
/// retrying them, so fx stops the request itself when unclear endings, of one
/// class or several, end `repeat_stop_sends` sends in a row.
pub const Repeating = enum { tls_setup, missing_finish, uncoded_error, unexplained_error_finish };

/// Sends in a row, all sent the same way, that `Repeating` failures may end
/// with no response progress between them before fx stops the request.
const repeat_stop_sends: u8 = 3;

/// Past any wait the module schedules; its longest is 30 seconds.
const probe_horizon_ms: u64 = 60 * std.time.ms_per_min;

pub const RequestRecovery = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    /// Off in tests unless a test exercises the thread itself.
    ticker_enabled: bool = !builtin.is_test,

    // Only the turn loop's thread touches these.
    /// How many sends in a row `Repeating` failures ended, 0 when the latest
    /// send ended some other way.
    repeat_sends: u8 = 0,
    /// Response bytes the latest of them streamed.
    repeat_progress_bytes: usize = 0,
    /// How those sends went out.
    repeat_send: Send = .{},
    /// The latest send's ending went to `repeatedFailure`.
    repeat_noted: bool = false,
    /// `repeatedFailure` stopped the request.
    repeat_stopped: bool = false,

    mutex: std.Io.Mutex = .init,
    // Everything below is guarded by `mutex`.
    state: recovery.State = .{},
    /// Sends the module asked for, including the first: its attempt count.
    attempts: u16 = 0,
    /// How the latest send goes out.
    send: Send = .{},
    /// The host showed a status for this request, so a success reports
    /// `recovered`.
    recovery_shown: bool = false,
    /// `responding` was delivered for the current send.
    responded: bool = false,
    /// The host's status line holds a module status right now.
    host_showing: bool = false,
    ticker: ?std.Thread = null,
    ticker_stop: bool = false,
    ticker_wake: std.Io.Condition = .init,
    /// Single-threaded builds tick from the transport's cooperative pulse.
    inner_pulse: ?agent_stream_provider.CooperativePulse = null,
    next_beat_ms: u64 = 0,
    /// Tests run on this virtual boot clock, so a 30-second wait takes no
    /// real time.
    virtual_now_ms: std.atomic.Value(u64) = .init(test_epoch_ms),

    pub fn init(
        deps: *const runtime_deps.AgentRuntimeDeps,
        cancel_flag: *std.atomic.Value(bool),
        trace_ctx: debug_trace.TraceContext,
    ) RequestRecovery {
        return .{ .deps = deps, .cancel_flag = cancel_flag, .trace_ctx = trace_ctx };
    }

    /// Every exit of the request ends here, so a module status the host still
    /// shows is cleared and a retry warning never outlives its request
    /// (`tests/tla/recovery/Recovery.tla` StatusHonest).
    pub fn deinit(self: *RequestRecovery) void {
        self.endSend();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearShownLocked();
    }

    /// A new request. `fast` is the request's Fast selection, which makes
    /// "retrying without Fast" a real option.
    pub fn start(self: *RequestRecovery, fast: bool) !void {
        if (self.deps.begin_route_recovery_request) |begin| begin(self.deps.ctx);
        _ = try self.event(.{ .start = .{ .fast = fast } });
    }

    /// Reports a failed send. A transient kind makes the module wait; the
    /// caller then calls `waitForSend`.
    pub fn failed(self: *RequestRecovery, failure: Failure) !void {
        _ = try self.event(.{ .failed = failure });
    }

    /// Waits for the module's next send, delivering `tick` once a second.
    /// Returns null when the cancel flag is set; the caller then runs its
    /// cancel path, which calls `cancel`.
    pub fn waitForSend(self: *RequestRecovery) !?Send {
        var next_tick_ms = self.nowMs() +| tick_ms;
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return null;
            const now_ms = self.nowMs();
            if (now_ms < next_tick_ms) {
                self.sleepMs(@min(cancel_poll_ms, next_tick_ms - now_ms));
                continue;
            }
            next_tick_ms = now_ms +| tick_ms;
            if (try self.event(.tick)) |send| return send;
        }
    }

    /// The first output of the current send arrived. Called from the
    /// transport's event callback, which cannot fail, so publication errors
    /// are traced. The check and the step share one hold of `mutex`, because
    /// `stepLocked` resets `responded` for each new send.
    pub fn responding(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.responded) return;
        self.responded = true;
        _ = self.stepLocked(.responding) catch |err| {
            debug_trace.logf("recovery", "responding status publication failed err={s}", .{@errorName(err)});
        };
    }

    /// The response arrived complete. After a request that showed a status,
    /// hosts that report a result get a `recovered` status, which carries
    /// only the attempt that succeeded.
    pub fn succeeded(self: *RequestRecovery) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = try self.stepLocked(.succeeded);
        if (!self.recovery_shown) return;
        self.recovery_shown = false;
        self.host_showing = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .recovered,
            .attempt = self.attempts,
        });
    }

    /// Esc or quitting: ends the request and clears its status.
    pub fn cancel(self: *RequestRecovery) !void {
        _ = try self.event(.user_cancel);
    }

    /// fx's own terminal status replaces the module's on the host. Terminal
    /// failures keep fx's handling and wording in this change. The terminal
    /// status is the request's result, so nothing reports over it.
    pub fn replaceStatus(self: *RequestRecovery, status: types.RouteRecoveryStatus) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.host_showing = false;
        self.recovery_shown = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, status);
    }

    /// The request ended on an error with no success, cancel, or terminal
    /// status of fx's own, for example an HTTP error after a retry or a
    /// resend that never reached the transport. After the host showed a
    /// status, hosts that report a result get `failed`, which also clears the
    /// TUI's status line; otherwise a module status still shown is cleared.
    pub fn endWithError(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.recovery_shown) return self.clearShownLocked();
        self.recovery_shown = false;
        self.host_showing = false;
        self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .failed,
            .attempt = self.attempts,
        }) catch |err| {
            debug_trace.logf("recovery", "failed status publication failed err={s}", .{@errorName(err)});
        };
    }

    /// Reports how a failed send ended, before the module hears of it:
    /// `failure` as the module will hear it, `class` when it is a `Repeating`
    /// failure and null for any other, and the response bytes the send
    /// streamed. Returns true when unclear failures, of any `Repeating` class,
    /// have now ended `repeat_stop_sends` sends in a row, all sent the same
    /// way, with no new response progress, and the module would keep sending
    /// the same way if `failure` kept ending them, so fx stops the request.
    /// When the module would change the send, as it drops Fast after a run of
    /// gateway errors, the request gets those sends first: the count starts
    /// over with the first send that goes out differently. A send whose ending
    /// never reaches this, such as an HTTP error or a success, breaks the run
    /// at the next `beginSend`.
    pub fn repeatedFailure(self: *RequestRecovery, failure: Failure, class: ?Repeating, progress_bytes: usize) bool {
        const repeating = class orelse {
            self.repeat_sends = 0;
            return false;
        };
        self.repeat_noted = true;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const same = self.repeat_sends > 0 and
            self.repeat_progress_bytes == progress_bytes and
            self.repeat_send == self.send;
        if (same) {
            self.repeat_sends +|= 1;
        } else {
            self.repeat_sends = 1;
            self.repeat_progress_bytes = progress_bytes;
            self.repeat_send = self.send;
        }
        if (self.repeat_sends < repeat_stop_sends) return false;
        if (self.nextSendLocked(failure)) |next| {
            if (next != self.send) return false;
        }
        self.repeat_stopped = true;
        // The trace names the class that ended the last send.
        debug_trace.eventf("recovery", "repeated_failure_stop", self.trace_ctx, "failure={s} sends={d} progress_bytes={d} no_fast={}", .{
            @tagName(repeating),
            self.repeat_sends,
            progress_bytes,
            self.send.no_fast,
        });
        return true;
    }

    /// `repeatedFailure` stopped the request.
    pub fn stoppedRepeating(self: *const RequestRecovery) bool {
        return self.repeat_stopped;
    }

    /// How the module would send if `failure` kept ending its sends, asked of
    /// a copy of its state: `step` is pure, so stepping a copy changes
    /// nothing. The copy hears `failure` up to `recovery.escalate_after`
    /// times, each followed by a tick past any wait it schedules, which is as
    /// many as the module needs to try another way, such as dropping Fast,
    /// even when unclear failures of other kinds started fx's count. Returns
    /// the first send that differs from the current one, the current one when
    /// none does, and null when the module would not send again on its own.
    fn nextSendLocked(self: *RequestRecovery, failure: Failure) ?Send {
        var probe = self.state;
        var now_ms = self.nowMs();
        for (0..recovery.escalate_after) |_| {
            _ = recovery.step(&probe, .{ .failed = failure }, now_ms);
            now_ms +|= probe_horizon_ms;
            const next = recovery.step(&probe, .tick, now_ms).send orelse return null;
            if (next != self.send) return next;
        }
        return self.send;
    }

    fn clearShownLocked(self: *RequestRecovery) void {
        if (!self.host_showing) return;
        self.host_showing = false;
        self.deps.push_event(self.deps.ctx, .clear_route_recovery_status) catch |err| {
            debug_trace.logf("recovery", "stale status clear failed err={s}", .{@errorName(err)});
        };
    }

    /// Sends so far, including the first.
    pub fn attempt(self: *RequestRecovery) u16 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.attempts;
    }

    /// Starts the ticker that keeps the retrying status counting while a
    /// send is on the wire.
    ///
    /// Why calling the host from this second thread is safe. The ticker only
    /// steps `tick` under `mutex`, and while a send is out `tick` can only
    /// refresh the `retrying` status the turn loop already published for it
    /// (`recovery.zig` `onTick`, phase `sending`): no clear, no send. Until
    /// `endSend`, every other route status for the request also comes from
    /// this file under `mutex` (`responding`'s clear), and fx's terminal
    /// statuses go through `replaceStatus` only after the stream returns.
    /// The turn loop keeps calling the host's other callbacks meanwhile, and
    /// each host takes a status from another thread safely:
    ///
    /// - TUI (`app_callbacks.agentPushRouteRecoveryStatus`): copies the event
    ///   with `std.heap.c_allocator` and queues it under `worker_mutex`.
    /// - ACP (`AcpContext.sendModelRecoveryStatus`): formats into a local
    ///   writer and writes one frame under `jsonrpc.Writer.mutex`; libfx's
    ///   writer callback queues under its own mutex. The allocator is the
    ///   server loop's (`processAllocator()` for `fx acp`, `c_allocator` for
    ///   libfx, and `state.alloc` for subagent children), never an arena, and
    ///   the loop thread already shares it with the prompt thread.
    /// - `fx ask` (`pushRouteRecoveryStatus`): writes only its two recovery
    ///   fields. During a send their only other writer is the clear from
    ///   `responding`, under `mutex`, and the result reads them after the
    ///   ticker is joined. It prints only when the kind changes, which a
    ///   `retrying` refresh never does.
    /// - Subagent children and the default deps drop the status.
    ///
    /// Single-threaded builds, such as wasm, tick from the transport's
    /// cooperative pulse on the turn loop's own thread instead.
    pub fn beginSend(self: *RequestRecovery) void {
        // The previous send ended some other way than a `Repeating` failure.
        if (!self.repeat_noted) self.repeat_sends = 0;
        self.repeat_noted = false;
        if (comptime builtin.single_threaded) {
            self.next_beat_ms = self.nowMs() +| tick_ms;
            return;
        }
        if (!self.ticker_enabled or self.ticker != null) return;
        self.ticker_stop = false;
        self.ticker = std.Thread.spawn(.{}, tickerMain, .{self}) catch |err| {
            // The status then refreshes at the next event instead.
            debug_trace.logf("recovery", "status ticker unavailable err={s}", .{@errorName(err)});
            return;
        };
    }

    pub fn endSend(self: *RequestRecovery) void {
        const thread = self.ticker orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.ticker_stop = true;
        self.ticker_wake.signal(io);
        self.mutex.unlock(io);
        thread.join();
        self.ticker = null;
    }

    /// Single-threaded builds have no ticker thread, so the transport's
    /// cooperative pulse delivers the in-flight `tick` instead. Threaded
    /// builds get `inner` back unchanged.
    pub fn cooperativePulse(
        self: *RequestRecovery,
        inner: ?agent_stream_provider.CooperativePulse,
    ) ?agent_stream_provider.CooperativePulse {
        if (comptime !builtin.single_threaded) return inner;
        self.inner_pulse = inner;
        return .{ .ctx = self, .run = pulseBeat };
    }

    fn pulseBeat(raw: *anyopaque) anyerror!void {
        const self: *RequestRecovery = @ptrCast(@alignCast(raw));
        const now_ms = self.nowMs();
        if (now_ms >= self.next_beat_ms) {
            self.next_beat_ms = now_ms +| tick_ms;
            _ = self.event(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
        if (self.inner_pulse) |inner| try inner.pulse();
    }

    fn tickerMain(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.ticker_stop) {
            self.ticker_wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(ticker_interval_ns),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (self.ticker_stop) return;
            _ = self.stepLocked(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
    }

    fn event(self: *RequestRecovery, value: recovery.Event) !?Send {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.stepLocked(value);
    }

    /// Steps the module and carries out its plan in field order. Returns
    /// the plan's send, which the caller carries out.
    fn stepLocked(self: *RequestRecovery, value: recovery.Event) !?Send {
        const now_ms = self.nowMs();
        const plan = recovery.step(&self.state, value, now_ms);
        if (plan.send) |send| {
            self.attempts +|= 1;
            self.send = send;
            self.responded = false;
        }
        if (plan.send != null or plan.status != null or plan.finish != null) {
            debug_trace.eventf("recovery", "step", self.trace_ctx, "event={s} now_ms={d} attempt={d} send={s} no_fast={} status={s} finish={s}", .{
                @tagName(value),
                now_ms,
                self.attempts,
                if (plan.send != null) "true" else "false",
                self.send.no_fast,
                if (plan.status) |status| @tagName(status.kind) else "none",
                if (plan.finish) |finish| @tagName(finish) else "none",
            });
        }
        if (plan.status) |status| try self.showLocked(status);
        // A cancelled request recovered nothing.
        if (plan.finish) |finish| if (finish == .cancelled) {
            self.recovery_shown = false;
        };
        return plan.send;
    }

    fn showLocked(self: *RequestRecovery, status: recovery.Status) !void {
        if (types.RouteRecoveryStatus.fromRecovery(status, self.attempts)) |shown| {
            self.recovery_shown = true;
            self.host_showing = true;
            try self.deps.push_route_recovery_status(self.deps.ctx, shown);
        } else {
            self.host_showing = false;
            try self.deps.push_event(self.deps.ctx, .clear_route_recovery_status);
        }
    }

    fn nowMs(self: *RequestRecovery) u64 {
        if (comptime builtin.is_test) return self.virtual_now_ms.load(.seq_cst);
        const ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .boot).raw.toNanoseconds();
        return if (ns <= 0) 0 else @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn sleepMs(self: *RequestRecovery, ms: u64) void {
        if (comptime builtin.is_test) {
            _ = self.virtual_now_ms.fetchAdd(ms, .seq_cst);
            return;
        }
        io_mod.getIo().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
    }
};

// Tests.

const support = @import("tests/support.zig");

fn statusTexts(fake: *const support.FakeAgentRuntimeDeps, buf: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (fake.route_recovery_statuses.items) |*status| {
        if (count == buf.len) break;
        buf[count] = status.text.slice();
        count += 1;
    }
    return buf[0..count];
}

test "a transient failure waits with the module's status, then resends" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);

    try request.failed(.{ .kind = .dropped });
    const waiting = fake.route_recovery_statuses.items[0];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.waiting, waiting.kind);
    try std.testing.expectEqualStrings("Connection lost · next try in 1s · attempt 1 · 0s", waiting.text.slice());
    try std.testing.expectEqual(@as(usize, 1), waiting.attempt);

    const send = (try request.waitForSend()).?;
    try std.testing.expectEqual(Send{}, send);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, retrying.kind);
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Connection lost · retrying · attempt 2 · "));
}

test "the first output clears the status and success reports the recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try request.failed(.{ .kind = .server });
    _ = (try request.waitForSend()).?;
    const shown = fake.route_recovery_statuses.items.len;

    request.responding();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
    // One `responding` per send.
    request.responding();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);

    try request.succeeded();
    try std.testing.expectEqual(shown + 1, fake.route_recovery_statuses.items.len);
    const recovered = fake.route_recovery_statuses.items[shown];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.recovered, recovered.kind);
    try std.testing.expectEqual(@as(usize, 2), recovered.attempt);
    // `recovered` reports the attempt only.
    try std.testing.expectEqual(@as(usize, 0), recovered.text.len);
}

test "responding from two threads at once delivers one responding" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    for (0..50) |_| {
        try request.failed(.{ .kind = .dropped });
        _ = (try request.waitForSend()).?;
        const clears = fake.route_recovery_clear_count;
        const racer = try std.Thread.spawn(.{}, RequestRecovery.responding, .{&request});
        request.responding();
        racer.join();
        // The retrying status clears exactly once per send.
        try std.testing.expectEqual(clears + 1, fake.route_recovery_clear_count);
    }
}

test "a healthy request shows nothing and reports no recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(true);
    request.responding();
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);
}

test "Esc during a wait stops waiting and cancel clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    fake.cancel_on_auto_retry_status = &cancel_flag;
    const deps = fake.deps();
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 20_000 });
    try std.testing.expect(cancel_flag.load(.seq_cst));
    try std.testing.expect(try request.waitForSend() == null);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());

    try request.cancel();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
    // A cancelled request ignores later events.
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_statuses.items.len);
}

test "three server errors in a row with Fast on resend without Fast" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(true);
    for (0..2) |_| {
        try request.failed(.{ .kind = .server });
        try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    }
    try request.failed(.{ .kind = .server });
    const send = (try request.waitForSend()).?;
    try std.testing.expect(send.no_fast);
    try std.testing.expect(request.send.no_fast);
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Gateway error · retrying without Fast · attempt 4 · "));

    // The rest of the request stays off Fast.
    try request.failed(.{ .kind = .dropped });
    try std.testing.expect((try request.waitForSend()).?.no_fast);
}

test "a server's Retry-After is honored up to the 30 second ceiling" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try request.failed(.{ .kind = .server, .retry_after_ms = 3_000 });
    try std.testing.expectEqualStrings("Gateway error · next try in 3s · attempt 1 · 0s", fake.route_recovery_statuses.items[0].text.slice());
    var started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 3_000), request.nowMs() - started_ms);

    try request.failed(.{ .kind = .server, .retry_after_ms = 120_000 });
    try std.testing.expect(std.mem.startsWith(u8, fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1].text.slice(), "Gateway error · next try in 30s · attempt 2"));
    started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 30_000), request.nowMs() - started_ms);
}

test "the countdown refreshes once a second while waiting" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 3_000 });
    _ = (try request.waitForSend()).?;
    var buf: [8][]const u8 = undefined;
    const texts = statusTexts(&fake, &buf);
    try std.testing.expectEqual(@as(usize, 4), texts.len);
    try std.testing.expectEqualStrings("Rate limited · next try in 3s · attempt 1 · 0s", texts[0]);
    try std.testing.expectEqualStrings("Rate limited · next try in 2s · attempt 1 · 1s", texts[1]);
    try std.testing.expectEqualStrings("Rate limited · next try in 1s · attempt 1 · 2s", texts[2]);
    try std.testing.expectEqualStrings("Rate limited · retrying · attempt 2 · 3s", texts[3]);
}

test "the in-flight ticker keeps the retrying status counting" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.ticker_enabled = true;
    defer request.deinit();

    try request.start(false);
    try request.failed(.{ .kind = .dropped });
    _ = (try request.waitForSend()).?;
    const io = io_mod.getIo();
    request.mutex.lockUncancelable(io);
    const before = fake.route_recovery_statuses.items.len;
    request.mutex.unlock(io);

    request.beginSend();
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    _ = request.virtual_now_ms.fetchAdd(1_000, .seq_cst);
    var waited_ms: usize = 0;
    while (waited_ms < 2_000) : (waited_ms += 5) {
        request.mutex.lockUncancelable(io);
        const count = fake.route_recovery_statuses.items.len;
        request.mutex.unlock(io);
        if (count > before) break;
        io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    request.endSend();

    try std.testing.expectEqual(before + 1, fake.route_recovery_statuses.items.len);
    const refreshed = fake.route_recovery_statuses.items[before];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, refreshed.kind);
    try std.testing.expectEqualStrings("Connection lost · retrying · attempt 2 · 2s", refreshed.text.slice());
}

test "the same repeating failure on three sends in a row stops the request" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    for (0..repeat_stop_sends - 1) |_| {
        request.beginSend();
        request.endSend();
        try std.testing.expect(!request.repeatedFailure(.{ .kind = .dropped }, .tls_setup, 0));
        try std.testing.expect(!request.stoppedRepeating());
        try request.failed(.{ .kind = .dropped });
        _ = (try request.waitForSend()).?;
    }
    request.beginSend();
    request.endSend();
    try std.testing.expect(request.repeatedFailure(.{ .kind = .dropped }, .tls_setup, 0));
    try std.testing.expect(request.stoppedRepeating());
}

test "unclear failures of different classes in a row still stop the request" {
    const Ending = struct { Failure.Kind, Repeating };
    // Between them the two runs end sends with every `Repeating` class.
    const runs = [_][repeat_stop_sends]Ending{
        .{ .{ .dropped, .tls_setup }, .{ .server, .uncoded_error }, .{ .dropped, .missing_finish } },
        .{ .{ .server, .unexplained_error_finish }, .{ .dropped, .missing_finish }, .{ .server, .uncoded_error } },
    };
    for (runs) |endings| {
        var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
        defer fake.deinit();
        const deps = fake.deps();
        var cancel_flag = std.atomic.Value(bool).init(false);
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();

        try request.start(false);
        for (endings, 0..) |ending, index| {
            request.beginSend();
            request.endSend();
            const stops = request.repeatedFailure(.{ .kind = ending[0] }, ending[1], 0);
            // The third unclear ending in a row stops it, whatever its class.
            try std.testing.expectEqual(index == endings.len - 1, stops);
            if (stops) break;
            try request.failed(.{ .kind = ending[0] });
            _ = (try request.waitForSend()).?;
        }
        try std.testing.expect(request.stoppedRepeating());
    }
}

test "a request gets its sends without Fast before a repeating failure stops it" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    // Three gateway errors with Fast: the module would drop Fast next, so
    // the third does not stop the request.
    try request.start(true);
    const server: Failure = .{ .kind = .server };
    for (0..repeat_stop_sends) |_| {
        request.beginSend();
        request.endSend();
        try std.testing.expect(!request.send.no_fast);
        try std.testing.expect(!request.repeatedFailure(server, .unexplained_error_finish, 0));
        try request.failed(server);
        _ = (try request.waitForSend()).?;
    }
    // The first send without Fast starts the count over, and the third such
    // failure stops it.
    for (0..repeat_stop_sends - 1) |_| {
        request.beginSend();
        request.endSend();
        try std.testing.expect(request.send.no_fast);
        try std.testing.expect(!request.repeatedFailure(server, .unexplained_error_finish, 0));
        try request.failed(server);
        _ = (try request.waitForSend()).?;
    }
    request.beginSend();
    request.endSend();
    try std.testing.expect(request.repeatedFailure(server, .unexplained_error_finish, 0));
    try std.testing.expect(request.stoppedRepeating());
}

test "the stop looks ahead through the module's whole run toward dropping Fast" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(true);
    const dropped: Failure = .{ .kind = .dropped };
    const server: Failure = .{ .kind = .server };
    for (0..repeat_stop_sends - 1) |_| {
        request.beginSend();
        request.endSend();
        try std.testing.expect(!request.repeatedFailure(dropped, .missing_finish, 0));
        try request.failed(dropped);
        _ = (try request.waitForSend()).?;
    }
    // fx's count passes its bound on the first gateway error, while the
    // module's run of them starts at zero: the request keeps Fast for all
    // `recovery.escalate_after` of them only if the lookahead reaches that
    // far.
    for (0..recovery.escalate_after) |_| {
        request.beginSend();
        request.endSend();
        try std.testing.expect(!request.send.no_fast);
        try std.testing.expect(!request.repeatedFailure(server, .uncoded_error, 0));
        try request.failed(server);
        _ = (try request.waitForSend()).?;
    }
    for (0..repeat_stop_sends - 1) |_| {
        request.beginSend();
        request.endSend();
        try std.testing.expect(request.send.no_fast);
        try std.testing.expect(!request.repeatedFailure(server, .uncoded_error, 0));
        try request.failed(server);
        _ = (try request.waitForSend()).?;
    }
    request.beginSend();
    request.endSend();
    try std.testing.expect(request.repeatedFailure(server, .uncoded_error, 0));
    try std.testing.expect(request.stoppedRepeating());
}

test "start tells the host a new request begins" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var deps = fake.deps();
    const Host = struct {
        var begun: usize = 0;
        fn begin(_: *anyopaque) void {
            begun += 1;
        }
    };
    Host.begun = 0;
    deps.begin_route_recovery_request = Host.begin;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try std.testing.expectEqual(@as(usize, 1), Host.begun);
}

test "another ending or new response progress starts the repeat count over" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    const Ending = union(enum) { repeating: struct { Repeating, usize }, other_failure, unreported };
    // Each run of unclear failures at the same point stays under the stop.
    const endings = [_]Ending{
        .{ .repeating = .{ .missing_finish, 0 } },
        .{ .repeating = .{ .missing_finish, 0 } },
        // A send that ends some other way, such as an HTTP error.
        .unreported,
        .{ .repeating = .{ .missing_finish, 0 } },
        .{ .repeating = .{ .tls_setup, 0 } },
        .other_failure,
        .{ .repeating = .{ .uncoded_error, 0 } },
        .{ .repeating = .{ .missing_finish, 0 } },
        // The response got further this time.
        .{ .repeating = .{ .missing_finish, 12 } },
        .{ .repeating = .{ .tls_setup, 12 } },
    };
    try request.start(false);
    const dropped: Failure = .{ .kind = .dropped };
    for (endings) |ending| {
        request.beginSend();
        request.endSend();
        switch (ending) {
            .repeating => |failure| try std.testing.expect(!request.repeatedFailure(dropped, failure[0], failure[1])),
            .other_failure => try std.testing.expect(!request.repeatedFailure(dropped, null, 0)),
            .unreported => {},
        }
    }
    try std.testing.expect(!request.stoppedRepeating());
}

test "an error after a status reports failed and every exit clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try request.start(false);
        try request.failed(.{ .kind = .server });
        _ = (try request.waitForSend()).?;
        request.endWithError();
        const last = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.failed, last.kind);
        try std.testing.expectEqual(@as(usize, 2), last.attempt);
    }
    // `failed` already ended the status, so the exit adds no clear.
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);

    const shown = fake.route_recovery_statuses.items.len;
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try request.start(false);
        try request.failed(.{ .kind = .dropped });
        // fx's terminal status reports the result itself.
        try request.replaceStatus(.{ .kind = .terminal_provider_error, .attempt = 1 });
        request.endWithError();
    }
    try std.testing.expectEqual(shown + 2, fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);

    {
        // A request that leaves without an error, such as a compaction handoff,
        // clears the status it still shows.
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try request.start(false);
        try request.failed(.{ .kind = .dropped });
    }
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
}

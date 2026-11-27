//! Carries out `src/core/recovery/` plans for one model request.
//!
//! The recovery module decides and this file acts. The turn loop reports what
//! happened to the request (`start`, `failed`, `responding`, `succeeded`,
//! `cancel`), and each report becomes one `recovery.step` call on the boot
//! clock. Its plan's status goes to the host, and its send tells the loop to
//! resend. Between sends `waitForSend` delivers `tick` every 100 ms, so a
//! jittered wait ends within a tick of its time, and polls the cancel flag
//! every 25 ms; in single-threaded builds each poll also gives the host its
//! cooperative pulse, which is where the host's Esc arrives. While a send is
//! on the wire, a ticker keeps the
//! retrying status counting: a thread in threaded builds, or the transport's
//! cooperative pulse in single-threaded ones.
//!
//! The module's state is not thread-safe, so every `step` call holds `mutex`.
//! Statuses are pushed under the same lock, so the host sees them in the order
//! the module produced them.
//!
//! On hosts that keep the module's record (`save_recovery_record`), every
//! `Plan.save` reaches the turn. A save that goes with a send travels in the
//! write before that send (`sendRecord`), so a turn's first write carries it;
//! a completed response clears it in the write that saves the response
//! (`responseRecord`); any other save is written at once. A launch reads the
//! newest one to resume the request (`tests/tla/recovery/Resume.tla`). Every
//! request that keeps a record registers for `closeActive`, which SIGHUP and
//! SIGTERM call from the closer thread, and a terminal that hangs up calls
//! from the main thread. One fx process runs main, its subagents and other
//! instances, and each can have a request in flight.
//!
//! The module retries every transient failure for as long as it lasts, and fx
//! adds no limit of its own: only Esc ends a request whose failures keep
//! coming.

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

/// The module expects `tick` at least once a second from `start` until
/// `finish`; a send on the wire ticks this often.
const tick_ms: u64 = 1_000;
/// How often a wait ticks. The module ends a wait at the first tick past its
/// jittered time, so a whole-second tick would round every wait up to a
/// whole second and every client would resend together.
const wait_tick_ms: u64 = 100;
/// How often a wait checks for Esc.
const cancel_poll_ms: u64 = 25;
/// How often a wait for a sign-in asks whether the store holds a new login.
const sign_in_check_ms: u64 = 1_000;
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
        .connectivity_lost => .offline,
        // A connection that broke after connecting may have sent the request.
        .network_interrupted, .response_interrupted, .provider_stream_timeout => .dropped,
        .provider_unavailable => .server,
        .rate_limited => .rate_limited,
        .authentication, .request_limit_reached, .compaction_prepared => null,
    };
}

/// The unreadable replies one request takes before its turn ends: a server
/// that sends one every time is broken, not having a bad moment.
const max_unreadable_replies = 3;

/// Whether the store now holds a login the waiting request can send, other
/// than the one the provider refused, as another fx process that signs in
/// saves.
const SignInRenewed = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque) bool,
};

pub const RequestRecovery = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    /// Set by the host when the user answers a request that waits for them,
    /// for example with Enter. Null on hosts that cannot ask the user, which
    /// end the turn instead (`canAskUser`).
    continue_flag: ?*std.atomic.Value(bool) = null,
    /// Set by the same host when the sign-in it opened for this request
    /// closes without a new login (`recovery.Event.sign_in_closed`).
    sign_in_closed_flag: ?*std.atomic.Value(bool) = null,
    /// Set by fx while the request waits for a sign-in. Asked about once a
    /// second; a new login answers the wait as the user's continue does.
    sign_in_renewed: ?SignInRenewed = null,
    /// Off in tests unless a test exercises the thread itself.
    ticker_enabled: bool = !builtin.is_test,
    /// Replies this request could not read. Touched only by the request's
    /// own thread.
    unreadable_replies: u8 = 0,
    /// Links the request into `registry` while it is registered. Guarded by
    /// `registry_mutex`, not `mutex`.
    registry_node: std.DoublyLinkedList.Node = .{},
    registered: bool = false,
    /// Set by `start` when the request ends at the crash-loop guard.
    stopped_by_crash_loop: bool = false,

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
    /// The kind of this request's last failed send (`failed`), reported with every status after it.
    last_failure: ?Failure.Kind = null,
    /// The kind and attempt of the last status saved in the session log.
    saved: ?struct { kind: types.RouteRecoveryStatus.Kind, attempt: usize } = null,
    ticker: ?std.Thread = null,
    ticker_stop: bool = false,
    ticker_wake: std.Io.Condition = .init,
    /// Single-threaded builds tick from the transport's cooperative pulse.
    inner_pulse: ?agent_stream_provider.CooperativePulse = null,
    /// The module's newest save, and whether it reached the turn.
    record: ?recovery.Record = null,
    record_written: bool = false,
    /// A record on disk says a send is or was in flight; a completed
    /// response or the request's end clears it.
    record_live: bool = false,
    /// `closeActive` saved the record marked clean: fx is exiting, and
    /// nothing after that may replace it.
    closed: bool = false,
    /// What `closeForYield` replaced, so a cancelled restart can put the
    /// request back (`reopenAfterYield`).
    before_yield: ?BeforeYield = null,
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
        unregister(self);
        self.endSend();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearShownLocked();
    }

    pub const Resume = types.RecoveryResume;

    const BeforeYield = struct { state: recovery.State, record: ?recovery.Record };

    /// A new request, or one resumed. `fast` is the request's Fast
    /// selection, which makes "retrying without Fast" a real option.
    /// Returns the first send, or null when the module asks the user first;
    /// the caller then writes the turn and calls `waitForSend`.
    pub fn start(self: *RequestRecovery, fast: bool, resumed: ?Resume) !?Send {
        if (self.deps.begin_route_recovery_request) |begin| begin(self.deps.ctx);
        if (self.deps.save_recovery_record != null) register(self);
        // A continue or a closed sign-in from before this request answers none
        // of its questions. Both are cleared before the step, which may ask,
        // to keep a quick answer.
        if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
            debug_trace.eventf("recovery", "answer_dropped", self.trace_ctx, "event=user_continue origin=start reason=nothing_waits_for_it", .{});
        };
        if (self.sign_in_closed_flag) |flag| if (flag.swap(false, .seq_cst)) {
            debug_trace.eventf("recovery", "answer_dropped", self.trace_ctx, "event=sign_in_closed origin=start reason=nothing_waits_for_it", .{});
        };
        const from = resumed orelse Resume{};
        return self.event(.{ .start = .{ .fast = fast, .resume_from = from.record, .crashes = from.crashes, .continues = from.continues } });
    }

    /// Whether `start` ended the request at the crash-loop guard. Only `start`
    /// finishes a request that way, on the turn's own thread, so that thread
    /// reads it after `start` returns.
    pub fn stoppedByCrashLoop(self: *const RequestRecovery) bool {
        return self.stopped_by_crash_loop;
    }

    /// The record for the write just before a send: the module's save for
    /// that send, until it is written. `.keep` on hosts that keep no record.
    pub fn sendRecord(self: *RequestRecovery) types.RecoveryRecordWrite {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed or self.deps.save_recovery_record == null or self.record_written) return .keep;
        const record = self.record orelse return .keep;
        self.record_written = true;
        self.record_live = true;
        return .{ .save = record };
    }

    /// The record for the write that saves a response: a complete response
    /// clears it there, before its pieces reach the turn, so a death after
    /// that is not a death with a send in flight
    /// (`tests/tla/recovery/Resume.tla` NoFalseCrash).
    pub fn responseRecord(self: *RequestRecovery, complete: bool) types.RecoveryRecordWrite {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!complete or self.closed or !self.record_live) return .keep;
        self.record_live = false;
        return .clear;
    }

    /// Writes a save the module made with a send now, for providers whose
    /// sends have no write before them.
    pub fn flushRecord(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.writeRecordLocked();
    }

    /// SIGHUP, SIGTERM, or a terminal that hangs up: delivers `closing` to
    /// every registered request and writes the clean record each returns, so
    /// the next launch resumes them without counting a death
    /// (`tests/tla/recovery/Resume.tla` NoFalseCrash). Main, its
    /// subagents and other instances can each have a request in flight.
    /// Waits at most `close_wait_ms` for each lock. Returns how many records
    /// were written.
    pub fn closeActive() usize {
        const io = io_mod.getIo();
        if (!lockWithin(&registry_mutex, close_wait_ms)) {
            debug_trace.logf("recovery", "closing skipped every request reason=registry_busy", .{});
            return 0;
        }
        defer registry_mutex.unlock(io);
        var written: usize = 0;
        var node = registry.first;
        while (node) |current| : (node = current.next) {
            const request: *RequestRecovery = @fieldParentPtr("registry_node", current);
            if (request.close()) written += 1;
        }
        return written;
    }

    /// Closes this request for `closeActive`. Returns whether its clean
    /// record was written.
    fn close(self: *RequestRecovery) bool {
        const io = io_mod.getIo();
        if (!lockWithin(&self.mutex, close_wait_ms)) {
            // Its record stays as it was, so the next launch counts a death.
            debug_trace.eventf("recovery", "closing_skipped", self.trace_ctx, "reason=request_busy", .{});
            return false;
        }
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        _ = self.stepLocked(.closing) catch |err| {
            debug_trace.logf("recovery", "closing status publication failed err={s}", .{@errorName(err)});
        };
        const written = self.record_written;
        self.closed = true;
        debug_trace.eventf("recovery", "closed", self.trace_ctx, "record_written={}", .{written});
        return written;
    }

    /// The turn stops before this request's send, between steps, for an
    /// upgrade's restart: saves the clean record `closing` returns, as
    /// SIGTERM does, so the next launch continues the request without
    /// counting a death (`tests/tla/recovery/Resume.tla` Hold,
    /// NoFalseCrash). Only a cancelled restart replaces that record
    /// afterwards (`reopenAfterYield`).
    /// When the clean record does not land, the request stays as it was,
    /// open and with its send's record, so the turn goes on and its next
    /// boundary asks again (`Resume.tla` YieldSaveFails). Returns whether
    /// this call saved the clean record: a request that SIGTERM already
    /// closed returns false and keeps the record that close wrote, and its
    /// turn ends with the process. Called on the request's own thread.
    pub fn closeForYield(self: *RequestRecovery) bool {
        const io = io_mod.getIo();
        if (!lockWithin(&self.mutex, close_wait_ms)) {
            debug_trace.eventf("recovery", "closing_skipped", self.trace_ctx, "reason=request_busy", .{});
            return false;
        }
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        const state_before = self.state;
        const record_before = self.record;
        const written_before = self.record_written;
        _ = self.stepLocked(.closing) catch |err| {
            debug_trace.logf("recovery", "closing status publication failed err={s}", .{@errorName(err)});
        };
        if (!self.record_written) {
            self.state = state_before;
            self.record = record_before;
            self.record_written = written_before;
            debug_trace.eventf("recovery", "yield_close_failed", self.trace_ctx, "reason=clean_record_not_saved", .{});
            return false;
        }
        self.before_yield = .{ .state = state_before, .record = record_before };
        self.closed = true;
        debug_trace.eventf("recovery", "closed", self.trace_ctx, "record_written=true", .{});
        return true;
    }

    pub const ReopenError = error{ NotYielded, RecordNotSaved };

    /// The restart this request's turn stopped for was cancelled: the request
    /// goes back to how it was before `closeForYield`, and its send's record
    /// is saved again before the send, so a death during that send counts
    /// (`tests/tla/recovery/Resume.tla` CancelRestart, CrashLoopStops). When
    /// the record does not land, the request stays closed with its clean
    /// record and this fails, so no send goes out without its record.
    /// Called on the request's own thread.
    pub fn reopenAfterYield(self: *RequestRecovery) ReopenError!void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const before = self.before_yield orelse return error.NotYielded;
        self.before_yield = null;
        self.state = before.state;
        self.record = before.record;
        self.record_written = false;
        self.closed = false;
        self.writeRecordLocked();
        if (!self.record_written) {
            self.closed = true;
            debug_trace.eventf("recovery", "yield_reopen_failed", self.trace_ctx, "reason=send_record_not_saved", .{});
            return error.RecordNotSaved;
        }
        debug_trace.eventf("recovery", "reopened", self.trace_ctx, "reason=restart_cancelled", .{});
    }

    /// Whether this request's record is in the session log, so a turn
    /// stopped before its send can be resumed from it after a restart.
    /// False on hosts that keep no record. Called on the request's own
    /// thread.
    pub fn recordSaved(self: *RequestRecovery) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return !self.closed and self.record_live;
    }

    /// Reports a failed send. Returns the send the module asks for at once,
    /// which only compaction and a sign-in failure the user already answered
    /// do. Any other kind makes the module wait or ask the user; the caller
    /// then calls `waitForSend`.
    pub fn failed(self: *RequestRecovery, failure: Failure) !?Send {
        // An answer given before this failure answers nothing, except a
        // sign-in that finished while a resend for one was on the wire: the
        // module keeps that one and resends at once with the new login. It
        // ignores the continue in every other phase.
        if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
            _ = try self.deliverAnswer(.user_continue, "failed_send");
        };
        // The send that failed was the saved login's try, so a sign-in that
        // closed while it was on the wire leaves nothing more to try.
        if (self.sign_in_closed_flag) |flag| if (flag.swap(false, .seq_cst)) {
            debug_trace.eventf("recovery", "answer_dropped", self.trace_ctx, "event=sign_in_closed origin=failed_send reason=the_failed_send_tried_the_saved_login", .{});
        };
        return self.event(.{ .failed = failure });
    }

    /// Whether the host can answer a request that needs the user. Hosts that
    /// cannot keep fx's own handling and end the turn.
    pub fn canAskUser(self: *const RequestRecovery) bool {
        return self.continue_flag != null;
    }

    /// The user answered a request that waits for them, other than through
    /// the continue flag, for example with a picker choice. Returns the
    /// module's send.
    pub fn userContinue(self: *RequestRecovery) !?Send {
        return self.deliverAnswer(.user_continue, "host");
    }

    /// Waits for the module's next send, delivering `tick` every
    /// `wait_tick_ms`, `user_continue` when the continue flag is set or
    /// `sign_in_renewed` finds a new login, and `sign_in_closed` when the
    /// sign-in closed flag is set. Returns null when the cancel flag is set;
    /// the caller then runs its cancel path, which calls `cancel`.
    pub fn waitForSend(self: *RequestRecovery) !?Send {
        var next_tick_ms = self.nowMs() +| wait_tick_ms;
        var next_sign_in_check_ms = self.nowMs() +| sign_in_check_ms;
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return null;
            if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
                if (try self.deliverAnswer(.user_continue, "wait")) |send| return send;
            };
            if (self.sign_in_closed_flag) |flag| if (flag.swap(false, .seq_cst)) {
                if (try self.deliverAnswer(.sign_in_closed, "wait")) |send| return send;
            };
            const now_ms = self.nowMs();
            if (self.sign_in_renewed) |renewed| if (now_ms >= next_sign_in_check_ms) {
                next_sign_in_check_ms = now_ms +| sign_in_check_ms;
                if (renewed.check(renewed.ctx)) {
                    if (try self.deliverAnswer(.user_continue, "stored_sign_in")) |send| {
                        if (self.deps.stored_sign_in_resumed) |resumed| resumed(self.deps.ctx);
                        return send;
                    }
                }
            };
            if (now_ms < next_tick_ms) {
                self.sleepMs(@min(cancel_poll_ms, next_tick_ms - now_ms));
                continue;
            }
            next_tick_ms = now_ms +| wait_tick_ms;
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
    /// the attempt that succeeded and the last failure.
    pub fn succeeded(self: *RequestRecovery) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = try self.stepLocked(.succeeded);
        if (!self.recovery_shown) return;
        self.recovery_shown = false;
        self.host_showing = false;
        const recovered: types.RouteRecoveryStatus = .{
            .kind = .recovered,
            .attempt = self.attempts,
            .failure = self.last_failure,
        };
        defer self.saveStatusLocked(recovered);
        try self.deps.push_route_recovery_status(self.deps.ctx, recovered);
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
        var shown = status;
        if (shown.failure == null) shown.failure = self.last_failure;
        defer self.saveStatusLocked(shown);
        try self.deps.push_route_recovery_status(self.deps.ctx, shown);
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
        const failed_status: types.RouteRecoveryStatus = .{
            .kind = .failed,
            .attempt = self.attempts,
            .failure = self.last_failure,
        };
        self.deps.push_route_recovery_status(self.deps.ctx, failed_status) catch |err| {
            debug_trace.logf("recovery", "failed status publication failed err={s}", .{@errorName(err)});
        };
        self.saveStatusLocked(failed_status);
    }

    /// Saves `status` in the session log when its kind or attempt differs
    /// from the last one saved, so a countdown's updates add nothing. A
    /// failed save is traced and never fails the request.
    fn saveStatusLocked(self: *RequestRecovery, status: types.RouteRecoveryStatus) void {
        const save = self.deps.save_route_recovery_status orelse return;
        if (self.saved) |last| if (last.kind == status.kind and last.attempt == status.attempt) return;
        self.saved = .{ .kind = status.kind, .attempt = status.attempt };
        save(self.deps.ctx, status) catch |err| {
            debug_trace.logf("recovery", "status save failed err={s} kind={s}", .{ @errorName(err), @tagName(status.kind) });
        };
    }

    fn clearShownLocked(self: *RequestRecovery) void {
        if (!self.host_showing) return;
        self.host_showing = false;
        self.deps.push_event(self.deps.ctx, .clear_route_recovery_status) catch |err| {
            debug_trace.logf("recovery", "stale status clear failed err={s}", .{@errorName(err)});
        };
    }

    /// Sends so far, including the first.
    /// Counts a reply this request could not read, and says whether it is
    /// the last one: past `max_unreadable_replies` the turn ends with the
    /// error instead of another resend.
    pub fn unreadableReplyEndsRequest(self: *RequestRecovery) bool {
        self.unreadable_replies +|= 1;
        return self.unreadable_replies >= max_unreadable_replies;
    }

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
    /// - `fx ask` (`pushRouteRecoveryStatus`): writes only its three recovery
    ///   fields. During a send their only other writer is the clear from
    ///   `responding`, under `mutex`, and the result reads them after the
    ///   ticker is joined. It prints only when the kind or the attempt
    ///   changes, which a `retrying` refresh never does.
    /// - Subagent children and the default deps drop the status.
    ///
    /// Single-threaded builds, such as wasm, tick from the transport's
    /// cooperative pulse on the turn loop's own thread instead.
    pub fn beginSend(self: *RequestRecovery) void {
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

    /// Steps the module with a user's answer, and traces the answer when
    /// the module has no use for it, since that drops what the user did: an
    /// Enter while nothing waits for them, or a closed sign-in while no wait
    /// is for one. `origin` names where the answer was read.
    fn deliverAnswer(self: *RequestRecovery, value: recovery.Event, origin: []const u8) !?Send {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!recovery.usesAnswer(&self.state, value)) {
            debug_trace.eventf("recovery", "answer_dropped", self.trace_ctx, "event={s} origin={s} reason=nothing_waits_for_it", .{ @tagName(value), origin });
        }
        return self.stepLocked(value);
    }

    /// Steps the module and carries out its plan in field order. Returns
    /// the plan's send, which the caller carries out.
    fn stepLocked(self: *RequestRecovery, value: recovery.Event) !?Send {
        switch (value) {
            .failed => |failure| self.last_failure = failure.kind,
            else => {},
        }
        // fx is exiting with the clean record saved; nothing replaces it.
        if (self.closed) return null;
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
        if (plan.save) |record| {
            self.record = record;
            self.record_written = false;
            // A save with a send travels in the write before that send.
            if (plan.send == null) self.writeRecordLocked();
        }
        if (plan.status) |status| try self.showLocked(status);
        if (plan.finish) |finish| switch (finish) {
            // A response that never reached `responseRecord` clears here.
            .succeeded => if (self.record_live) {
                _ = self.saveLocked(.clear);
            },
            // The turn ends cancelled, which ends its record too.
            .cancelled => self.recovery_shown = false,
            .crash_loop => {
                self.recovery_shown = false;
                self.stopped_by_crash_loop = true;
            },
        };
        return plan.send;
    }

    /// Writes the newest save if the turn is on disk; otherwise it waits for
    /// the turn's first write.
    fn writeRecordLocked(self: *RequestRecovery) void {
        if (self.record_written) return;
        const record = self.record orelse return;
        if (self.saveLocked(.{ .save = record })) {
            self.record_written = true;
            self.record_live = true;
        }
    }

    fn saveLocked(self: *RequestRecovery, write: types.RecoveryRecordWrite) bool {
        const save = self.deps.save_recovery_record orelse return false;
        const written = save(self.deps.ctx, write) catch |err| {
            debug_trace.logf("recovery", "record {s} failed err={s}", .{ @tagName(write), @errorName(err) });
            return false;
        };
        if (written and write == .clear) self.record_live = false;
        return written;
    }

    fn showLocked(self: *RequestRecovery, status: recovery.Status) !void {
        // After a content filter's last resend, a host that cannot ask has
        // nobody to answer the question, and the turn loop ends the request
        // on fx's own content-filter status next, so the question never
        // reaches it.
        if (status.need == .content_filter and !self.canAskUser()) {
            debug_trace.eventf("recovery", "status_not_shown", self.trace_ctx, "need=content_filter reason=host_cannot_ask", .{});
            return;
        }
        if (types.RouteRecoveryStatus.fromRecovery(status, self.attempts)) |converted| {
            var shown = converted;
            shown.failure = self.last_failure;
            self.recovery_shown = true;
            self.host_showing = true;
            defer self.saveStatusLocked(shown);
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
        // A single-threaded host, such as the browser SDK, delivers Esc only
        // through the cooperative pulse, so a wait that never pulsed ended
        // before the cancel could arrive.
        if (comptime builtin.single_threaded) {
            if (self.inner_pulse) |inner| inner.pulse() catch |err| {
                debug_trace.logf("recovery", "wait pulse failed err={s}", .{@errorName(err)});
            };
        }
        io_mod.getIo().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
    }
};

const close_wait_ms: u64 = 1_000;

fn lockWithin(mutex: *std.Io.Mutex, ms: u64) bool {
    var waited_ms: u64 = 0;
    while (!mutex.tryLock()) {
        if (waited_ms >= ms) return false;
        io_mod.getIo().sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 5;
    }
    return true;
}

/// The requests `closeActive` closes: every running request that keeps a
/// record, in every agent of the process. Each links itself through its own
/// `registry_node`, so registering never allocates.
var registry_mutex: std.Io.Mutex = .init;
var registry: std.DoublyLinkedList = .{};

fn register(request: *RequestRecovery) void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (request.registered) return;
    registry.append(&request.registry_node);
    request.registered = true;
}

/// Removes only `request`, so a request that ends never takes another
/// agent's out of `closeActive`'s reach.
fn unregister(request: *RequestRecovery) void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (!request.registered) return;
    registry.remove(&request.registry_node);
    request.registry_node = .{};
    request.registered = false;
}

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

    _ = try request.start(false, null);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);

    _ = try request.failed(.{ .kind = .dropped });
    const waiting = fake.route_recovery_statuses.items[0];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.waiting, waiting.kind);
    try std.testing.expectEqualStrings("Connection lost · next try in 1s · attempt 1", waiting.text.slice());
    try std.testing.expectEqual(@as(usize, 1), waiting.attempt);

    const send = (try request.waitForSend()).?;
    try std.testing.expectEqual(Send{}, send);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, retrying.kind);
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Connection lost · retrying · attempt 2"));
}

test "the first output clears the status and success reports the recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .server });
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

test "the recovered status names the failure its last send had, and a healthy request names none" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .rate_limited });
    const waiting = fake.route_recovery_statuses.items[0];
    try std.testing.expectEqual(@as(?Failure.Kind, .rate_limited), waiting.failure);
    _ = (try request.waitForSend()).?;
    request.responding();
    try request.succeeded();
    const recovered = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.recovered, recovered.kind);
    try std.testing.expectEqual(@as(?Failure.Kind, .rate_limited), recovered.failure);

    // A request that never failed pushes no status, so none names a failure.
    const pushed = fake.route_recovery_statuses.items.len;
    var healthy_cancel = std.atomic.Value(bool).init(false);
    var healthy = RequestRecovery.init(&deps, &healthy_cancel, .{});
    defer healthy.deinit();
    _ = try healthy.start(true, null);
    healthy.responding();
    try healthy.succeeded();
    try std.testing.expectEqual(pushed, fake.route_recovery_statuses.items.len);
    for (fake.route_recovery_statuses.items[pushed..]) |status| {
        try std.testing.expectEqual(@as(?Failure.Kind, null), status.failure);
    }
}

test "the session log gets each status once per kind and attempt, and the outcome" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    // The countdown: three `waiting` updates in one wait, then a retry, then success.
    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 3_000 });
    _ = (try request.waitForSend()).?;
    request.responding();
    try request.succeeded();

    const pushed = fake.route_recovery_statuses.items;
    const saved = fake.saved_route_recovery_statuses.items;
    try std.testing.expect(pushed.len > saved.len);
    try std.testing.expectEqual(@as(usize, 3), saved.len);
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.waiting, saved[0].kind);
    try std.testing.expectEqual(@as(usize, 1), saved[0].attempt);
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, saved[1].kind);
    try std.testing.expectEqual(@as(usize, 2), saved[1].attempt);
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.recovered, saved[2].kind);
    try std.testing.expectEqual(@as(usize, 2), saved[2].attempt);
    for (saved, 0..) |status, i| {
        try std.testing.expectEqual(@as(?Failure.Kind, .rate_limited), status.failure);
        if (i == 0) continue;
        const before = saved[i - 1];
        try std.testing.expect(before.kind != status.kind or before.attempt != status.attempt);
    }
}

test "responding from two threads at once delivers one responding" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    for (0..50) |_| {
        _ = try request.failed(.{ .kind = .dropped });
        _ = (try request.waitForSend()).?;
        const clears = fake.route_recovery_clear_count;
        const racer = try std.Thread.spawn(.{}, RequestRecovery.responding, .{&request});
        request.responding();
        racer.join();
        // The retrying status clears exactly once per send.
        try std.testing.expectEqual(clears + 1, fake.route_recovery_clear_count);
    }
}

test "a host that cannot ask resends a blocked reply at once and never shows the question" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    for (0..3) |_| {
        try std.testing.expectEqual(Send{}, (try request.failed(.{ .kind = .content_filter })).?);
    }
    try std.testing.expectEqual(@as(u16, 4), request.attempt());
    // The fourth block needs the user, whom this host cannot ask.
    try std.testing.expectEqual(@as(?Send, null), try request.failed(.{ .kind = .content_filter }));
    const statuses = fake.route_recovery_statuses.items;
    try std.testing.expectEqual(@as(usize, 3), statuses.len);
    for (statuses) |status| try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, status.kind);
    try std.testing.expectEqualStrings("Blocked by the content filter · retrying (3/3)", statuses[2].text.slice());
}

test "a host that can ask resends a blocked reply at once, then shows the question" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var continue_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    defer request.deinit();

    _ = try request.start(false, null);
    for (0..3) |_| {
        try std.testing.expectEqual(Send{}, (try request.failed(.{ .kind = .content_filter })).?);
    }
    try std.testing.expectEqual(@as(?Send, null), try request.failed(.{ .kind = .content_filter }));
    const statuses = fake.route_recovery_statuses.items;
    try std.testing.expectEqual(@as(usize, 4), statuses.len);
    try std.testing.expectEqualStrings("Blocked by the content filter · retrying (3/3)", statuses[2].text.slice());
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.need_user, statuses[3].kind);
    // Enter sends it again.
    continue_flag.store(true, .seq_cst);
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 5), request.attempt());
}

test "a healthy request shows nothing and reports no recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(true, null);
    request.responding();
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);
}

const StoredSignInProbe = struct {
    found_after: usize,
    checks: usize = 0,

    fn check(raw: *anyopaque) bool {
        const self: *StoredSignInProbe = @ptrCast(@alignCast(raw));
        self.checks += 1;
        return self.checks > self.found_after;
    }
};

test "a request waiting for a sign-in resends once another fx process saves a login" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var deps = fake.deps();
    // The host hears of the resend, which no answer of its own started.
    const Host = struct {
        var resumed: usize = 0;
        fn storedSignInResumed(_: *anyopaque) void {
            resumed += 1;
        }
    };
    Host.resumed = 0;
    deps.stored_sign_in_resumed = Host.storedSignInResumed;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var continue_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    defer request.deinit();
    var probe = StoredSignInProbe{ .found_after = 2 };
    request.sign_in_renewed = .{ .ctx = &probe, .check = StoredSignInProbe.check };

    _ = try request.start(false, null);
    try std.testing.expect(try request.failed(.{ .kind = .sign_in }) == null);
    const waited_from_ms = request.nowMs();
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(usize, 3), probe.checks);
    try std.testing.expectEqual(@as(usize, 1), Host.resumed);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    // About a second apart, and long before the wait's own next try.
    const waited_ms = request.nowMs() - waited_from_ms;
    try std.testing.expect(waited_ms >= 3 * sign_in_check_ms);
    try std.testing.expect(waited_ms < 60 * 1000);
}

test "a sign-in that finishes while a sign-in resend is on the wire sends again when that resend fails" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var continue_flag = std.atomic.Value(bool).init(false);
    var closed_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    request.sign_in_closed_flag = &closed_flag;
    defer request.deinit();

    _ = try request.start(false, null);
    try std.testing.expect(try request.failed(.{ .kind = .sign_in }) == null);
    // The sign-in fx opened closes, so the request tries its saved login.
    closed_flag.store(true, .seq_cst);
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    try std.testing.expect(!closed_flag.load(.seq_cst));
    // The user signs in while that resend is on the wire, and it fails.
    continue_flag.store(true, .seq_cst);
    try std.testing.expectEqual(Send{}, (try request.failed(.{ .kind = .sign_in })).?);
    try std.testing.expectEqual(@as(u16, 3), request.attempt());
    try std.testing.expect(!continue_flag.load(.seq_cst));
}

test "a sign-in during a sign-in resend that then fails on the way waits briefly, then resends" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var continue_flag = std.atomic.Value(bool).init(false);
    var closed_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    request.sign_in_closed_flag = &closed_flag;
    defer request.deinit();

    _ = try request.start(false, null);
    try std.testing.expect(try request.failed(.{ .kind = .sign_in }) == null);
    closed_flag.store(true, .seq_cst);
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    // The user signs in while that resend is on the wire, and the connection
    // drops. The turn loop's transient sites take their send from
    // `waitForSend`, so `failed` must not hand one back here.
    continue_flag.store(true, .seq_cst);
    try std.testing.expect(try request.failed(.{ .kind = .dropped }) == null);
    try std.testing.expect(!continue_flag.load(.seq_cst));
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 3), request.attempt());
}

test "a continue or a closed sign-in before an ordinary failure answers nothing" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var continue_flag = std.atomic.Value(bool).init(false);
    var closed_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    request.sign_in_closed_flag = &closed_flag;
    defer request.deinit();

    _ = try request.start(false, null);
    continue_flag.store(true, .seq_cst);
    closed_flag.store(true, .seq_cst);
    try std.testing.expect(try request.failed(.{ .kind = .dropped }) == null);
    try std.testing.expect(!continue_flag.load(.seq_cst));
    try std.testing.expect(!closed_flag.load(.seq_cst));
    // The request still waits, then resends.
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
}

test "Esc during a wait stops waiting and cancel clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    fake.cancel_on_auto_retry_status = &cancel_flag;
    const deps = fake.deps();
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 20_000 });
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

    _ = try request.start(true, null);
    for (0..2) |_| {
        _ = try request.failed(.{ .kind = .server });
        try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    }
    _ = try request.failed(.{ .kind = .server });
    const send = (try request.waitForSend()).?;
    try std.testing.expect(send.no_fast);
    try std.testing.expect(request.send.no_fast);
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Gateway error · retrying without Fast · attempt 4"));

    // The rest of the request stays off Fast.
    _ = try request.failed(.{ .kind = .dropped });
    try std.testing.expect((try request.waitForSend()).?.no_fast);
}

test "a server's Retry-After is honored up to the 30 second ceiling" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .server, .retry_after_ms = 3_000 });
    try std.testing.expectEqualStrings("Gateway error · next try in 3s · attempt 1", fake.route_recovery_statuses.items[0].text.slice());
    var started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 3_000), request.nowMs() - started_ms);

    _ = try request.failed(.{ .kind = .server, .retry_after_ms = 120_000 });
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

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 3_000 });
    _ = (try request.waitForSend()).?;
    var buf: [8][]const u8 = undefined;
    const texts = statusTexts(&fake, &buf);
    try std.testing.expectEqual(@as(usize, 4), texts.len);
    try std.testing.expectEqualStrings("Rate limited · next try in 3s · attempt 1", texts[0]);
    try std.testing.expectEqualStrings("Rate limited · next try in 2s · attempt 1", texts[1]);
    try std.testing.expectEqualStrings("Rate limited · next try in 1s · attempt 1", texts[2]);
    try std.testing.expectEqualStrings("Rate limited · retrying · attempt 2", texts[3]);
}

test "the in-flight ticker hands the line back to the thinking row" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.ticker_enabled = true;
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .dropped });
    _ = (try request.waitForSend()).?;
    const io = io_mod.getIo();
    request.mutex.lockUncancelable(io);
    const statuses_before = fake.route_recovery_statuses.items.len;
    const clears_before = fake.route_recovery_clear_count;
    request.mutex.unlock(io);

    request.beginSend();
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    // A model thinking in silence sends nothing, so only the ticker can end
    // the retry status.
    _ = request.virtual_now_ms.fetchAdd(2_000, .seq_cst);
    var waited_ms: usize = 0;
    while (waited_ms < 2_000) : (waited_ms += 5) {
        request.mutex.lockUncancelable(io);
        const clears = fake.route_recovery_clear_count;
        request.mutex.unlock(io);
        if (clears > clears_before) break;
        io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    request.endSend();

    try std.testing.expectEqual(clears_before + 1, fake.route_recovery_clear_count);
    try std.testing.expectEqual(statuses_before, fake.route_recovery_statuses.items.len);
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

    _ = try request.start(false, null);
    try std.testing.expectEqual(@as(usize, 1), Host.begun);
}

test "an error after a status reports failed and every exit clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .server });
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
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .dropped });
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
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .dropped });
    }
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
}

fn recordingFake() support.FakeAgentRuntimeDeps {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    fake.enable_recovery_record = true;
    return fake;
}

test "a send's save travels with its write, and a wait's is written at once" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    try std.testing.expectEqual(@as(usize, 0), fake.recovery_record_writes);
    const first = request.sendRecord();
    try std.testing.expect(first == .save);
    // Written once: the next write before a send carries nothing.
    try std.testing.expect(request.sendRecord() == .keep);

    // A wait has no send, so its save goes at once.
    try std.testing.expectEqual(@as(?Send, null), try request.failed(.{ .kind = .dropped }));
    try std.testing.expectEqual(@as(usize, 1), fake.recovery_record_writes);
    try std.testing.expect(!std.mem.eql(u8, &first.save, &fake.recovery_record.?));

    _ = (try request.waitForSend()).?;
    try std.testing.expect(request.sendRecord() == .save);
    // The response's write clears it; the success adds nothing.
    try std.testing.expect(request.responseRecord(true) == .clear);
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 0), fake.recovery_record_clears);
}

test "a success whose response write never ran clears through the host" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    _ = request.sendRecord();
    // An incomplete response keeps the record.
    try std.testing.expect(request.responseRecord(false) == .keep);
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 1), fake.recovery_record_clears);
}

test "closing saves a clean record that resumes without a death, and nothing replaces it" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = (try request.start(false, null)).?;
        _ = request.sendRecord();
        try std.testing.expectEqual(@as(usize, 1), RequestRecovery.closeActive());
        const saved = fake.recovery_record.?;
        // The dying send's failure saves nothing over it.
        try std.testing.expectEqual(@as(?Send, null), try request.failed(.{ .kind = .dropped }));
        try std.testing.expectEqual(saved, fake.recovery_record.?);
        try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());
    }
    // Ended requests are not closed.
    try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());

    var probe: recovery.State = .{};
    const plan = recovery.step(&probe, .{ .start = .{ .resume_from = fake.recovery_record.? } }, 0);
    try std.testing.expect(plan.send != null);
}

test "a yield saves a clean record that resumes without a death" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = (try request.start(false, null)).?;
        // The write before the send carries the send's record.
        try std.testing.expect(request.sendRecord() == .save);
        try std.testing.expect(request.closeForYield());
        const saved = fake.recovery_record.?;
        // Once closed, nothing writes over the clean record.
        try std.testing.expect(!request.closeForYield());
        try std.testing.expect(request.sendRecord() == .keep);
        try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());
        try std.testing.expectEqual(saved, fake.recovery_record.?);
    }
    var probe: recovery.State = .{};
    const plan = recovery.step(&probe, .{ .start = .{ .resume_from = fake.recovery_record.? } }, 0);
    try std.testing.expect(plan.send != null);
}

test "a request reports its record saved from its send until it is closed" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = (try request.start(false, null)).?;
        try std.testing.expect(!request.recordSaved());
        try std.testing.expect(request.sendRecord() == .save);
        try std.testing.expect(request.recordSaved());
        try std.testing.expect(request.closeForYield());
        try std.testing.expect(!request.recordSaved());
    }

    // A host that keeps no record saves nothing with the send.
    var no_record = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer no_record.deinit();
    const no_record_deps = no_record.deps();
    var no_record_request = RequestRecovery.init(&no_record_deps, &cancel_flag, .{});
    defer no_record_request.deinit();
    _ = (try no_record_request.start(false, null)).?;
    try std.testing.expect(no_record_request.sendRecord() == .keep);
    try std.testing.expect(!no_record_request.recordSaved());
}

test "a yield whose clean record does not land leaves the request open with its send's record" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    const send_write = request.sendRecord();
    try std.testing.expect(send_write == .save);
    // The write before the send stores the send's record.
    const sent = send_write.save;
    fake.recovery_record = sent;
    fake.recovery_record_save_failures = 1;

    // The clean record does not land: the request stays open with the send's record.
    try std.testing.expect(!request.closeForYield());
    try std.testing.expect(request.recordSaved());
    try std.testing.expectEqual(sent, fake.recovery_record.?);

    // The next boundary asks again, and the clean record lands.
    try std.testing.expect(request.closeForYield());
    try std.testing.expect(!request.recordSaved());

    var probe: recovery.State = .{};
    const plan = recovery.step(&probe, .{ .start = .{ .resume_from = fake.recovery_record.? } }, 0);
    try std.testing.expect(plan.send != null);
}

test "a cancelled restart reopens the request and saves its send's record again" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    const send_write = request.sendRecord();
    try std.testing.expect(send_write == .save);
    const sent = send_write.save;
    fake.recovery_record = sent;
    try std.testing.expect(request.closeForYield());
    const clean = fake.recovery_record.?;

    try request.reopenAfterYield();
    try std.testing.expect(!std.mem.eql(u8, &clean, &fake.recovery_record.?));
    try std.testing.expectEqual(sent, fake.recovery_record.?);
    try std.testing.expect(request.recordSaved());
}

test "a reopen whose send record does not land fails and keeps the request closed" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    const send_write = request.sendRecord();
    try std.testing.expect(send_write == .save);
    fake.recovery_record = send_write.save;
    try std.testing.expect(request.closeForYield());
    const clean = fake.recovery_record.?;

    fake.recovery_record_save_failures = 1;
    try std.testing.expectError(error.RecordNotSaved, request.reopenAfterYield());
    try std.testing.expect(!request.recordSaved());
    try std.testing.expectEqual(clean, fake.recovery_record.?);
}

test "a request that never yielded cannot be reopened" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    try std.testing.expectError(error.NotYielded, request.reopenAfterYield());
}

test "closing saves a clean record for every request in flight" {
    var main_fake = recordingFake();
    defer main_fake.deinit();
    var subagent_fake = recordingFake();
    defer subagent_fake.deinit();
    var ended_fake = recordingFake();
    defer ended_fake.deinit();
    const main_deps = main_fake.deps();
    const subagent_deps = subagent_fake.deps();
    const ended_deps = ended_fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    var main_request = RequestRecovery.init(&main_deps, &cancel_flag, .{});
    defer main_request.deinit();
    _ = (try main_request.start(false, null)).?;
    _ = main_request.sendRecord();
    // A request that starts later and ends first leaves main's registered.
    {
        var ended = RequestRecovery.init(&ended_deps, &cancel_flag, .{});
        defer ended.deinit();
        _ = (try ended.start(false, null)).?;
        _ = ended.sendRecord();
    }
    // Another agent's request starts after main's.
    var subagent_request = RequestRecovery.init(&subagent_deps, &cancel_flag, .{});
    defer subagent_request.deinit();
    _ = (try subagent_request.start(false, null)).?;
    _ = subagent_request.sendRecord();

    try std.testing.expectEqual(@as(usize, 2), RequestRecovery.closeActive());
    for ([_]*const support.FakeAgentRuntimeDeps{ &main_fake, &subagent_fake }) |fake| {
        var probe: recovery.State = .{};
        const plan = recovery.step(&probe, .{ .start = .{ .resume_from = fake.recovery_record.? } }, 0);
        try std.testing.expect(plan.send != null);
    }
    try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());
}

test "a resumed start at the crash-loop guard sends nothing and ends the request" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    var probe: recovery.State = .{};
    const record = recovery.step(&probe, .{ .start = .{} }, 0).save.?;
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();
    try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .record = record, .crashes = 3 }));
    try std.testing.expect(request.stoppedByCrashLoop());
}

test "a request that resumes below the crash-loop guard is not ended as one" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    var probe: recovery.State = .{};
    const record = recovery.step(&probe, .{ .start = .{} }, 0).save.?;
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();
    try std.testing.expectEqual(Send{}, (try request.start(false, .{ .record = record, .crashes = 2 })).?);
    try std.testing.expect(!request.stoppedByCrashLoop());
}

/// A record waiting for the user on a quota question.
fn quotaRecord() recovery.Record {
    var probe: recovery.State = .{};
    _ = recovery.step(&probe, .{ .start = .{} }, 0);
    return recovery.step(&probe, .{ .failed = .{ .kind = .quota } }, 0).save.?;
}

test "a continue from before a request does not answer the question it starts with" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var continue_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    defer request.deinit();

    // An Enter that reached no waiting request, such as one typed just
    // after the out-of-credits picker's retry.
    continue_flag.store(true, .seq_cst);
    try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .record = quotaRecord() }));
    try std.testing.expect(!continue_flag.load(.seq_cst));
    try std.testing.expect(recovery.usesAnswer(&request.state, .user_continue));
    try std.testing.expectEqual(@as(u16, 0), request.attempt());
    // The user's own Enter answers it.
    continue_flag.store(true, .seq_cst);
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
}

test "an Enter as soon as a request's first question shows answers it" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var continue_flag = std.atomic.Value(bool).init(false);
    fake.continue_on_need_user = &continue_flag;
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.continue_flag = &continue_flag;
    defer request.deinit();

    try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .record = quotaRecord() }));
    try std.testing.expect(continue_flag.load(.seq_cst));
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
}

/// The record a request saves while it waits for a sign-in.
fn signInWaitRecord() recovery.Record {
    var probe: recovery.State = .{};
    _ = recovery.step(&probe, .{ .start = .{} }, 0);
    return recovery.step(&probe, .{ .failed = .{ .kind = .sign_in } }, 0).save.?;
}

test "a sign-in closed before a request does not end the sign-in wait it resumes" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var closed_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.sign_in_closed_flag = &closed_flag;
    defer request.deinit();

    // The sign-in of an earlier request closed while that request's resend
    // was on the wire, and the resend went through.
    closed_flag.store(true, .seq_cst);
    try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .record = signInWaitRecord() }));
    try std.testing.expect(!closed_flag.load(.seq_cst));
    try std.testing.expect(recovery.usesAnswer(&request.state, .sign_in_closed));
    try std.testing.expectEqual(@as(u16, 0), request.attempt());
    // The sign-in fx opens for this wait closes, and the request tries its
    // saved login.
    closed_flag.store(true, .seq_cst);
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
}

test "a sign-in that closes as soon as a resumed sign-in wait shows ends that wait" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var closed_flag = std.atomic.Value(bool).init(false);
    fake.sign_in_closed_on_sign_in_wait = &closed_flag;
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.sign_in_closed_flag = &closed_flag;
    defer request.deinit();

    try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .record = signInWaitRecord() }));
    try std.testing.expect(closed_flag.load(.seq_cst));
    try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
}

test "a resend leaves within one wait tick of its jittered deadline" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var below: usize = 0;
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var cancel_flag = std.atomic.Value(bool).init(false);
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        request.virtual_now_ms.store(test_epoch_ms + seed * 7_919, .seq_cst);
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .server });
        const failed_at = request.virtual_now_ms.load(.seq_cst);
        _ = (try request.waitForSend()).?;
        const waited = request.virtual_now_ms.load(.seq_cst) - failed_at;
        // The first step is 1 s jittered to 80-100 %: 800 to 1000 ms, plus
        // at most one wait tick.
        try std.testing.expect(waited >= 800 and waited <= 1_000 + wait_tick_ms);
        if (waited <= 950) below += 1;
        _ = try request.cancel();
    }
    // A whole-second tick would put every resend at 1000 ms.
    try std.testing.expect(below >= 10);
}

test "ten thousand failures in a row keep every wait within its cap and never stop retrying" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();
    request.virtual_now_ms.store(test_epoch_ms, .seq_cst);
    _ = try request.start(false, null);
    var longest: u64 = 0;
    for (0..10_000) |_| {
        _ = try request.failed(.{ .kind = .server });
        const failed_at = request.virtual_now_ms.load(.seq_cst);
        _ = (try request.waitForSend()) orelse return error.TestExpectedSend;
        const waited = request.virtual_now_ms.load(.seq_cst) - failed_at;
        longest = @max(longest, waited);
        // The backoff tops out at 30 s; a wait ends within one tick of its time.
        try std.testing.expect(waited <= 30_000 + wait_tick_ms);
    }
    try std.testing.expect(longest >= 24_000);
    _ = try request.cancel();
}

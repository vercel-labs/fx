//! The exec of one remote command (V6, V7), the reattach after a quiet close (V8), the stop
//! on SIGTERM (V10), and the session extension while a command streams (V12). The run thread
//! reads the stream. A watch thread keeps the timers, the stop's kill steps, and the extension,
//! and it never allocates from the run's arena.

const std = @import("std");
const io_mod = @import("../../shared/io.zig");
const api = @import("api.zig");
const credentials = @import("credentials.zig");
const reply = @import("reply.zig");
const sandbox = @import("sandbox.zig");
const attempt = @import("attempt.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const stream = @import("stream.zig");
const test_server = @import("test_server.zig");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;

/// The wrapper of V6, run by bash as `bash -c W fx STAMP C cmd`. It applies the local
/// deletions, stamps the start, makes the folder, and runs the command.
/// The wrapper's own refusal (V6, L6). A 125 that comes with this line means the command never ran.
pub const cwd_refused_line = "fx: did not run: the sandbox could not prepare the cwd";

pub const wrapper = "for f in .git/fx-delete-*; do [ -f \"$f\" ] || continue; { xargs -0 rm -f -- < \"$f\" && rm -f \"$f\"; } || echo \"fx: could not apply $f\" >&2; done; mkdir -p \"$2\" && touch \"$1\" && sleep 0.05 && cd \"$2\" || { echo '" ++ cwd_refused_line ++ "' >&2; exit 125; }; exec bash -c \"$3\"";

/// V6: the exec's timeout when the call set none (5 hours).
pub const default_timeout_ms: i64 = 18_000_000;
/// V7: the longest wait from the request being sent to its first command line.
pub const first_line_ms: i64 = 30_000;
/// V8: failed reattach attempts in a row before contact is lost (N4).
pub const reattach_failures_max: u8 = 3;
/// The pause before a reattach attempt that follows a failed one. V8 does not set it; it
/// paces the retries so a dead connection does not spin.
pub const reattach_pause_ms: i64 = 1_000;
/// V10: the stop budget is `grace_ms` less this margin.
pub const stop_margin_ms: i64 = 200;
/// V12: the extension cadence while a command streams (20 minutes).
pub const extend_every_ms: i64 = 20 * 60 * 1000;
const poll_ns: u64 = 10 * std.time.ns_per_ms;
/// The longest detail N23 carries: an HTTP status or an error name.
const max_extend_detail_bytes: usize = 64;
/// The longest command id the runner accepts. A longer one is outside bytes (R3.2).
const max_id_bytes: usize = 256;
/// The longest answer to `GET …/cmd/{id}?wait=true` the runner reads.
const max_wait_bytes: usize = 16 * 1024;

pub const Limits = struct {
    first_line_ms: i64 = first_line_ms,
    extend_every_ms: i64 = extend_every_ms,
    reattach_pause_ms: i64 = reattach_pause_ms,
};

pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    /// R: the repository root, which the body sends as `cwd` (V6).
    root: []const u8,
    /// C: the folder the command runs in. The wrapper's second argument.
    cwd: []const u8,
    /// `R/.git/fx-stamp-{run_id}`. The wrapper's first argument.
    stamp: []const u8,
    command: []const u8,
    /// The `--env` names that are set in fx's environment, with their values (V6).
    env: []const Pair,
    /// `--timeout-ms`, when the call set one. The exec's timeout is this plus the grace.
    timeout_ms: ?i64,
    /// `--grace-ms`. The stop budget is this less `stop_margin_ms` (V10).
    grace_ms: i64,
};

pub const Sinks = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub const Outcome = union(enum) {
    /// The command ran and exited with this code. The runner exits with it.
    exited: u8,
    /// The request was not sent in full, so the command did not run (V7, N21). Exit 125.
    not_sent: []const u8,
    /// A stop before the request was sent. Exit 143, and the request is never sent (V10).
    stopped_unsent,
    /// A stop after the command id. `confirmed` says the command's exit was seen after the
    /// stop, so the kill took effect (N5). Exit 143.
    stopped: bool,
    /// The command may have run and its result is unknown (V7, V8). Exit 255. The id is
    /// null when no command line came (N3), and set once one did (N4).
    unknown: ?[]const u8,
    /// The sandbox is gone while the command streams (V12, N13). Exit 255.
    gone,
    /// The sandbox answered the command request with 404 or 410 before any command line, and the run cannot
    /// resume it (V3, V6). The command did not run. Exit 125, with the failure's N1 detail.
    sandbox_refused: sandbox.Failure,
    /// The wrapper refused before the command ran: its own `fx:` line came with the 125 (L6).
    refused_by_wrapper,
};

const Chunk = struct {
    stream: []const u8,
    data: []const u8,
};

const Exit = struct {
    id: []const u8,
    code: i64,
};

const Line = union(enum) {
    output: Chunk,
    started: []const u8,
    exited: Exit,
};

/// One line of a command's stream: an output chunk, the command line that gives the id, or
/// the command line that gives the exit code. The line is outside bytes, so each field is
/// checked. An empty output chunk is allowed.
pub fn parseLine(arena: Allocator, bytes: []const u8) reply.ParseError!Line {
    const object = try reply.objectOf(try reply.parseRoot(arena, bytes));
    if (object.get("command")) |command_value| {
        const command = try reply.objectOf(command_value);
        const id = try reply.requiredText(arena, command.get("id"), max_id_bytes);
        return switch (command.get("exitCode") orelse .null) {
            .integer => |code| .{ .exited = .{ .id = id, .code = code } },
            .null => .{ .started = id },
            else => error.BadReply,
        };
    }
    const name = switch (object.get("stream") orelse return error.BadReply) {
        .string => |text| text,
        else => return error.BadReply,
    };
    if (!std.mem.eql(u8, name, "stdout") and !std.mem.eql(u8, name, "stderr")) return error.BadReply;
    const data = switch (object.get("data") orelse return error.BadReply) {
        .string => |text| text,
        else => return error.BadReply,
    };
    if (data.len > stream.max_log_line_bytes) return error.BadReply;
    return .{ .output = .{ .stream = name, .data = try arena.dupe(u8, data) } };
}

/// The bytes of each stream that this run has written (V8 skips them on reattach).
const Written = struct {
    stdout: usize = 0,
    stderr: usize = 0,
};

const Seen = struct {
    written: Written = .{},
    code: ?i64 = null,
    /// The wrapper's refusal line came on stderr, so the command never ran (L6).
    wrapper_refused: bool = false,
};

/// The state the run thread and the watch thread share. The run thread writes the id, and
/// the watch thread reads it after the acquire load of `id_len`.
const Shared = struct {
    /// The stop flag: the runner's cancel, set by SIGTERM (V10).
    stop: *std.atomic.Value(bool),
    /// Cancels the exec, reattach and send reads. The watch sets it; the run thread reads.
    stream_cancel: std.atomic.Value(bool) = .init(false),
    sent: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    id_len: std.atomic.Value(usize) = .init(0),
    id_buf: [max_id_bytes]u8 = undefined,
    /// Set once the command's exit code has been read, by either connection.
    exit_seen: std.atomic.Value(bool) = .init(false),
    /// Set once the exec connection has ended, with or without an exit code.
    exec_ended: std.atomic.Value(bool) = .init(false),
    /// The extend calls that failed (V12). The run reports them once, after the watch ends.
    extend_failures: std.atomic.Value(usize) = .init(0),
    /// The detail of the first failed extend (N23). Only the watch thread writes it, before the join.
    extend_detail: [max_extend_detail_bytes]u8 = undefined,
    extend_detail_len: usize = 0,
    /// The record the watch marks as soon as a background extend answers 404 or 410 (V3, V12). Null for an isolated run.
    mark_dir: ?*io_mod.VerifiedDir = null,
    /// The send gate (V10). A stop closes it while the body has not begun.
    send_gate: std.atomic.Value(u8) = .init(stream.gate_open),
    base: transport.BaseUrl,
    token: credentials.Token,
    trace: credentials.Trace,
    team_id: []const u8,
    session_id: []const u8,
    stop_budget_ms: i64,
    limits: Limits,

    fn setId(self: *Shared, id: []const u8) void {
        if (id.len > max_id_bytes or self.id_len.load(.acquire) != 0) return;
        @memcpy(self.id_buf[0..id.len], id);
        self.id_len.store(id.len, .release);
    }

    fn knownId(self: *const Shared) ?[]const u8 {
        const len = self.id_len.load(.acquire);
        if (len == 0) return null;
        return self.id_buf[0..len];
    }
};

/// The stop budget for `grace_ms` (V10): the grace less the margin, and never negative.
pub fn stopBudget(grace_ms: i64) i64 {
    return @max(grace_ms - stop_margin_ms, 0);
}

const StopStage = enum { none, wait_id, end_after_15, end_after_9, cancelled };

fn watchLoop(shared: *Shared) void {
    const quarter = @divFloor(shared.stop_budget_ms, 4);
    var sent_at: ?i64 = null;
    var stop_at: ?i64 = null;
    var stage: StopStage = .none;
    var stage_at: i64 = 0;
    var next_extend: i64 = io_mod.milliTimestamp() + shared.limits.extend_every_ms;
    while (!shared.done.load(.acquire)) {
        const now = io_mod.milliTimestamp();
        if (shared.sent.load(.acquire)) {
            if (sent_at == null) sent_at = now;
            if (shared.knownId() == null and now - sent_at.? >= shared.limits.first_line_ms) {
                shared.stream_cancel.store(true, .seq_cst);
            }
        }
        if (stop_at == null and shared.stop.load(.seq_cst)) {
            stop_at = now;
            stage = .wait_id;
            stage_at = now;
        }
        if (stop_at) |started| {
            if (!shared.sent.load(.acquire)) {
                closeSendGate(shared);
            } else switch (stage) {
                .wait_id => if (shared.knownId()) |id| {
                    sendKill(shared, id, 15, quarter);
                    stage = .end_after_15;
                    stage_at = io_mod.milliTimestamp();
                } else if (now - started >= quarter) {
                    shared.stream_cancel.store(true, .seq_cst);
                    stage = .cancelled;
                },
                .end_after_15 => if (streamOver(shared)) {
                    stage = .cancelled;
                } else if (now - stage_at >= quarter) {
                    if (shared.knownId()) |id| sendKill(shared, id, 9, quarter);
                    stage = .end_after_9;
                    stage_at = io_mod.milliTimestamp();
                },
                .end_after_9 => if (streamOver(shared)) {
                    stage = .cancelled;
                } else if (now - stage_at >= quarter) {
                    shared.stream_cancel.store(true, .seq_cst);
                    stage = .cancelled;
                },
                .none, .cancelled => {},
            }
        } else if (shared.knownId() != null and now >= next_extend) {
            extendOnWatch(shared);
            next_extend = io_mod.milliTimestamp() + shared.limits.extend_every_ms;
        }
        // No event covers the cadence clock (V12) or the stop flag (V10), so the watch checks both every poll_ns.
        io_mod.sleep(poll_ns);
    }
}

/// The stop waits for the command to end (V10): the exit code was read, or the exec stream closed.
fn streamOver(shared: *const Shared) bool {
    return shared.exit_seen.load(.seq_cst) or shared.exec_ended.load(.seq_cst);
}

/// A stop before the body begins closes the send gate, so the request never goes out. A body
/// that already began runs to its end, because a cut-off body may still reach the server.
fn closeSendGate(shared: *Shared) void {
    if (shared.send_gate.cmpxchgStrong(stream.gate_open, stream.gate_closed, .seq_cst, .seq_cst) == null) {
        shared.stream_cancel.store(true, .seq_cst);
    }
}

/// Waits `ms` milliseconds, or returns at once when the stop flag is set (V8, R2.3).
fn pauseUnlessStopped(stop: *const std.atomic.Value(bool), ms: i64) void {
    const deadline = io_mod.milliTimestamp() + ms;
    while (!stop.load(.seq_cst) and io_mod.milliTimestamp() < deadline) io_mod.sleep(poll_ns);
}

/// One kill call (V10) on the watch thread. Its own arena and the page allocator, because the
/// run's arena is not thread-safe. A failed kill is not retried here: the later stop steps
/// and the stream's end report the outcome.
fn sendKill(shared: *Shared, id: []const u8, signal: u8, total_ms: i64) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var never = std.atomic.Value(bool).init(false);
    // A kill that fails is not retried here. The stop stays unconfirmed until the command's exit is
    // seen, and the run reports that (V10).
    const status = sandbox.killCommand(
        arena.allocator(),
        &never,
        shared.base,
        shared.token,
        shared.trace,
        shared.team_id,
        shared.session_id,
        id,
        signal,
        .{ .total_ms = total_ms },
    ) catch |err| {
        debug_trace.logf("remote run", "event=kill_failed signal={d} reason={s}", .{ signal, @errorName(err) });
        return;
    };
    if (status < 200 or status > 299) {
        debug_trace.logf("remote run", "event=kill_refused signal={d} status={d}", .{ signal, status });
    }
}

/// One extend call (V12) on the watch thread. A failure is counted, and the run reports the count.
fn extendOnWatch(shared: *Shared) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var never = std.atomic.Value(bool).init(false);
    const status = sandbox.extendTime(arena.allocator(), &never, shared.base, shared.token, shared.trace, shared.team_id, shared.session_id) catch |err| {
        noteExtendFailure(shared, @errorName(err));
        return;
    };
    // The run thread is blocked in the stream, so it does not touch the record while this writes it (V3).
    if (status == 404 or status == 410) {
        if (shared.mark_dir) |dir| sandbox.markExpiredIn(dir, arena.allocator());
    }
    if (status < 200 or status > 299) {
        var detail: [max_extend_detail_bytes]u8 = undefined;
        const text = std.mem.print(&detail, "HTTP {d}", .{status}) catch return noteExtendFailure(shared, "HTTP status");
        noteExtendFailure(shared, text);
    }
}

/// Counts a failed extend and keeps the first one's detail for N23. Only the watch thread
/// calls it, and the run reads the detail only after the watch has joined.
fn noteExtendFailure(shared: *Shared, detail: []const u8) void {
    if (shared.extend_failures.load(.seq_cst) == 0) {
        const n = @min(detail.len, shared.extend_detail.len);
        @memcpy(shared.extend_detail[0..n], detail[0..n]);
        shared.extend_detail_len = n;
    }
    _ = shared.extend_failures.fetchAdd(1, .seq_cst);
}

/// N23: the sandbox time limit could not be extended. Written once per run, after the watch
/// ends, and the run continues.
pub fn writeExtendNote(stderr: *std.Io.Writer, detail: []const u8) void {
    stderr.print("fx: could not extend the sandbox time limit: {s}; the run continued\n", .{detail}) catch return;
    // No reader is left to tell when stderr fails; the run's exit code still reports the result.
    stderr.flush() catch {};
}

/// The exec with V3's recovery. A 404 or 410 before the command line did not run, so when the run's one
/// recovery is unused the session resumes and the request goes out once more. Otherwise the run is refused.
pub fn runRecovering(ctx: *sandbox.Context, session: *sandbox.Session, request: Request, sinks: Sinks, limits: Limits) Outcome {
    var outcome = run(ctx, session.state.session_id, request, sinks, limits);
    while (true) {
        const refused = switch (outcome) {
            .sandbox_refused => |failure| failure,
            else => return outcome,
        };
        switch (attempt.plan(.exec, ctx.mode, attempt.statusOutcome(refused.status), ctx.used)) {
            .resume_session => {
                ctx.used.recovered = true;
                sandbox.recover(ctx, session) catch |err| return refusedBy(ctx, err);
                outcome = run(ctx, session.state.session_id, request, sinks, limits);
            },
            else => return outcome,
        }
    }
}

fn refusedBy(ctx: *const sandbox.Context, err: anyerror) Outcome {
    if (err == error.Refused) return .{ .sandbox_refused = ctx.failure };
    return .{ .not_sent = @errorName(err) };
}

/// Runs the exec once (V6). `ctx.cancel` is the stop flag (V10). A failed start is an unknown start,
/// and a lost stream is reattached by reading (R3.3). `runRecovering` adds the one resend V3 allows.
pub fn run(ctx: *sandbox.Context, session_id: []const u8, request: Request, sinks: Sinks, limits: Limits) Outcome {
    if (ctx.cancel.load(.seq_cst)) return .stopped_unsent;
    const body = encodeBody(ctx.alloc, request) catch return .{ .not_sent = "out of memory" };
    const path = sandbox.commandPath(ctx, session_id) catch return .{ .not_sent = "out of memory" };
    var shared: Shared = .{
        .stop = ctx.cancel,
        .base = ctx.base,
        .token = ctx.token,
        .trace = ctx.trace,
        .team_id = ctx.team_id,
        .session_id = session_id,
        .stop_budget_ms = stopBudget(request.grace_ms),
        .limits = limits,
        .mark_dir = if (ctx.mode == .remote) ctx.state_dir else null,
    };
    const thread = std.Thread.spawn(.{}, watchLoop, .{&shared}) catch return .{ .not_sent = "a thread could not start" };
    var seen: Seen = .{};
    const outcome = execOnce(ctx, path, body, &shared, sinks, &seen);
    shared.done.store(true, .release);
    thread.join();
    if (shared.extend_failures.load(.seq_cst) > 0) {
        writeExtendNote(sinks.stderr, shared.extend_detail[0..shared.extend_detail_len]);
    }
    return classifyRefusal(settle(ctx, &shared, outcome, seen), seen);
}

/// L6: a 125 with the wrapper's own line did not run the command. A command's own 125 stays `exited`.
fn classifyRefusal(outcome: Outcome, seen: Seen) Outcome {
    switch (outcome) {
        .exited => |code| return if (code == 125 and seen.wrapper_refused) .refused_by_wrapper else outcome,
        else => return outcome,
    }
}

/// The stop decides the result (V10): before the request, the stop is exit 143; with no id,
/// exit 255 (N3); with an id, exit 143 with N5, confirmed when the command's exit was seen.
fn settle(ctx: *sandbox.Context, shared: *Shared, outcome: Outcome, seen: Seen) Outcome {
    if (!ctx.cancel.load(.seq_cst)) return outcome;
    if (!shared.sent.load(.acquire)) {
        // A body that began and then failed did not run (V7, N21). Only a gate that never
        // began is the stop that N24 names, because then the request could not have reached it.
        if (shared.send_gate.load(.seq_cst) == stream.gate_began) return outcome;
        return .stopped_unsent;
    }
    if (shared.knownId() == null) return .{ .unknown = null };
    return .{ .stopped = seen.code != null };
}

/// The first pass: send the command and read its stream (V6).
fn execOnce(ctx: *sandbox.Context, path: []const u8, body: []const u8, shared: *Shared, sinks: Sinks, seen: *Seen) Outcome {
    var source: std.Io.Reader = .fixed(body);
    const line_stream = stream.open(ctx.alloc, &shared.stream_cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = "exec",
        .method = .POST,
        .path = path,
        .body = .{ .sized = .{ .len = body.len, .source = &source } },
        .limits = stream.exec_limits,
        .sent = &shared.sent,
        .send_gate = &shared.send_gate,
    }) catch |err| {
        if (!shared.sent.load(.acquire)) return .{ .not_sent = @errorName(err) };
        return .{ .unknown = idText(ctx.alloc, shared) };
    };
    defer line_stream.close();
    if (line_stream.status == 404 or line_stream.status == 410) {
        sandbox.markGone(ctx);
        return .{ .sandbox_refused = .{ .step = "exec", .status = line_stream.status, .detail = sandbox.session_ended_detail } };
    }
    // V13 (D269): a 401 or 403 answer means the command line was not accepted, so the refusal is certain.
    if (attempt.loginRejected(line_stream.status)) {
        return .{ .sandbox_refused = .{ .step = "exec", .status = line_stream.status, .detail = sandbox.login_rejected_detail } };
    }
    if (line_stream.status != 200) return .{ .unknown = idText(ctx.alloc, shared) };
    _ = readLines(ctx.alloc, line_stream, shared, sinks, seen, .{});
    shared.exec_ended.store(true, .seq_cst);
    if (seen.code) |code| return exitOutcome(ctx.alloc, shared, code);
    if (shared.knownId() == null) return .{ .unknown = null };
    if (ctx.cancel.load(.seq_cst)) return .{ .unknown = idText(ctx.alloc, shared) };
    return reattach(ctx, shared, sinks, seen);
}

/// The id as the outcome keeps it, copied out of the shared buffer. Out of memory leaves the
/// id out, so the run reports N3, which is the safe result.
fn idText(alloc: Allocator, shared: *const Shared) ?[]const u8 {
    const id = shared.knownId() orelse return null;
    return alloc.dupe(u8, id) catch null;
}

fn exitOutcome(alloc: Allocator, shared: *const Shared, code: i64) Outcome {
    if (code < 0 or code > 255) return .{ .unknown = idText(alloc, shared) };
    return .{ .exited = @intCast(code) };
}

/// Reads the lines of one answer (V6, V8). Output is written as it arrives, skipping the
/// bytes `skip` says were written already. Returns true when the body finished cleanly.
fn readLines(alloc: Allocator, line_stream: *stream.Stream, shared: *Shared, sinks: Sinks, seen: *Seen, skip: Written) bool {
    var remaining = skip;
    while (true) {
        const bytes = line_stream.nextLine() catch return false;
        const line = bytes orelse return true;
        switch (parseLine(alloc, line) catch return false) {
            .output => |chunk| emit(sinks, seen, &remaining, chunk),
            .started => |id| shared.setId(id),
            .exited => |exit| {
                shared.setId(exit.id);
                seen.code = exit.code;
                shared.exit_seen.store(true, .seq_cst);
            },
        }
    }
}

/// Writes one chunk and flushes it. Bytes within `remaining` were written already, so they are
/// skipped and not written again. A write that fails has no reader left, and the exit code
/// still reports the result.
fn emit(sinks: Sinks, seen: *Seen, remaining: *Written, chunk: Chunk) void {
    const is_stdout = std.mem.eql(u8, chunk.stream, "stdout");
    if (!is_stdout and std.mem.find(u8, chunk.data, cwd_refused_line) != null) seen.wrapper_refused = true;
    const skip_left: *usize = if (is_stdout) &remaining.stdout else &remaining.stderr;
    const skipped = @min(skip_left.*, chunk.data.len);
    skip_left.* -= skipped;
    const data = chunk.data[skipped..];
    if (data.len == 0) return;
    const writer = if (is_stdout) sinks.stdout else sinks.stderr;
    writer.writeAll(data) catch |err| debug_trace.logf("remote run", "event=output_dropped bytes={d} reason={s}", .{ data.len, @errorName(err) });
    writer.flush() catch |err| debug_trace.logf("remote run", "event=output_flush_failed reason={s}", .{@errorName(err)});
    if (is_stdout) seen.written.stdout += data.len else seen.written.stderr += data.len;
}

const Attempt = enum { done, gone, failed, pending };

/// Reattach (V8): read the logs, skipping what this run wrote, then wait for the exit code.
/// Attempts repeat while they connect. Three failed attempts in a row end the run as lost
/// contact (N4). A sandbox that answers 404 or 410 is gone (N13).
fn reattach(ctx: *sandbox.Context, shared: *Shared, sinks: Sinks, seen: *Seen) Outcome {
    const id = shared.knownId() orelse return .{ .unknown = null };
    var failures: u8 = 0;
    while (!ctx.cancel.load(.seq_cst)) {
        switch (reattachOnce(ctx, shared, sinks, seen, id)) {
            .done => return exitOutcome(ctx.alloc, shared, seen.code.?),
            .gone => return .gone,
            .pending => failures = 0,
            .failed => {
                failures += 1;
                if (failures >= reattach_failures_max) return .{ .unknown = idText(ctx.alloc, shared) };
                pauseUnlessStopped(ctx.cancel, shared.limits.reattach_pause_ms);
            },
        }
    }
    return .{ .unknown = idText(ctx.alloc, shared) };
}

fn reattachOnce(ctx: *sandbox.Context, shared: *Shared, sinks: Sinks, seen: *Seen, id: []const u8) Attempt {
    const escaped = api.escapeComponent(ctx.alloc, id) catch return .failed;
    const logs_rest = ctx.alloc.print("cmd/{s}/logs", .{escaped}) catch return .failed;
    const logs_path = sandbox.sessionPath(ctx.alloc, ctx.team_id, shared.session_id, logs_rest, "") catch return .failed;
    const logs = stream.open(ctx.alloc, &shared.stream_cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = "reattach",
        .method = .GET,
        .path = logs_path,
        .limits = stream.reattach_limits,
    }) catch return .failed;
    defer logs.close();
    if (logs.status == 404 or logs.status == 410) return .gone;
    if (logs.status != 200) return .failed;
    const logs_ended = readLines(ctx.alloc, logs, shared, sinks, seen, seen.written);
    if (!logs_ended) return .failed;
    if (seen.code != null) return .done;
    return waitForExit(ctx, shared, seen, id);
}

/// `GET …/cmd/{id}?wait=true` for the exit code (V8). It reads the answer whole, within a bound.
fn waitForExit(ctx: *sandbox.Context, shared: *Shared, seen: *Seen, id: []const u8) Attempt {
    const escaped = api.escapeComponent(ctx.alloc, id) catch return .failed;
    const rest = ctx.alloc.print("cmd/{s}", .{escaped}) catch return .failed;
    const path = sandbox.sessionPath(ctx.alloc, ctx.team_id, shared.session_id, rest, "wait=true&") catch return .failed;
    const wait = stream.open(ctx.alloc, &shared.stream_cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = "wait",
        .method = .GET,
        .path = path,
        .limits = stream.reattach_limits,
    }) catch return .failed;
    defer wait.close();
    if (wait.status == 404 or wait.status == 410) return .failed;
    if (wait.status != 200) return .failed;
    var answer: std.Io.Writer.Allocating = .init(ctx.alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const count = wait.read(&chunk) catch return .failed;
        if (count == 0) break;
        if (answer.written().len + count > max_wait_bytes) return .failed;
        answer.writer.writeAll(chunk[0..count]) catch return .failed;
    }
    const code = exitCodeOf(ctx.alloc, answer.written()) catch return .failed;
    if (code) |value| {
        seen.code = value;
        shared.exit_seen.store(true, .seq_cst);
        return .done;
    }
    return .pending;
}

/// The `command.exitCode` of a wait answer, or null while the command runs.
fn exitCodeOf(arena: Allocator, bytes: []const u8) reply.ParseError!?i64 {
    const object = try reply.objectOf(try reply.parseRoot(arena, bytes));
    const command = try reply.objectOf(object.get("command") orelse return error.BadReply);
    return switch (command.get("exitCode") orelse .null) {
        .integer => |code| code,
        .null => null,
        else => error.BadReply,
    };
}

const Body = struct {
    command: []const u8 = "bash",
    args: []const []const u8,
    cwd: []const u8,
    env: std.json.Value,
    wait: bool = true,
    logs: bool = true,
    timeout: i64,
};

/// The exec body (V6): the wrapper with its four arguments, R as `cwd`, the set env names, and
/// `timeout` as `timeout_ms` plus the grace, or 5 hours when the call set none.
fn encodeBody(alloc: Allocator, request: Request) Allocator.Error![]u8 {
    var env: std.json.ObjectMap = .empty;
    for (request.env) |pair| {
        env.put(alloc, pair.name, .{ .string = pair.value }) catch return error.OutOfMemory;
    }
    const args = [_][]const u8{ "-c", wrapper, "fx", request.stamp, request.cwd, request.command };
    const timeout: i64 = if (request.timeout_ms) |ms| ms + request.grace_ms else default_timeout_ms;
    var out: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(Body{
        .args = &args,
        .cwd = request.root,
        .env = .{ .object = env },
        .timeout = timeout,
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// One line of a command's NDJSON stream (V8), read as the bytes of the whole input.
fn fuzzStreamLine(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, transport.max_response_bytes);
    const len = smith.slice(raw);
    const parsed = parseLine(arena, raw[0..len]) catch |err| return switch (err) {
        error.BadReply => {},
        error.OutOfMemory => error.OutOfMemory,
    };
    switch (parsed) {
        .output => |chunk| try testing.expect(std.mem.eql(u8, chunk.stream, "stdout") or std.mem.eql(u8, chunk.stream, "stderr")),
        .started => |id| try testing.expect(id.len > 0),
        .exited => |exit| try testing.expect(exit.id.len > 0),
    }
}

test "a command stream line parses or is refused, and a parsed line has a known stream or a non-empty id, on fuzzed bytes" {
    try testing.fuzz({}, fuzzStreamLine, .{
        .corpus = &@import("fuzz_corpus").vercel_exec_line.*,
    });
}

/// The wait answer (V7 to V8) read as the bytes of the whole answer: its exit code, or none while it runs.
fn fuzzWaitAnswer(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, transport.max_response_bytes);
    const len = smith.slice(raw);
    const code = exitCodeOf(arena, raw[0..len]) catch |err| return switch (err) {
        error.BadReply => {},
        error.OutOfMemory => error.OutOfMemory,
    };
    const value = code orelse return;
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{{\"command\":{{\"id\":\"cmd_1\",\"exitCode\":{d}}}}}", .{value});
    const again = (try exitCodeOf(arena, out.written())) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(value, again);
}

test "a wait answer parses or is refused, and a parsed exit code holds when it is written back, on fuzzed bytes" {
    try testing.fuzz({}, fuzzWaitAnswer, .{
        .corpus = &@import("fuzz_corpus").vercel_wait_answer.*,
    });
}

test "the wrapper's refusal line on stderr makes a 125 a refusal, and a command's own 125 stays its exit (L6)" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const sinks: Sinks = .{ .stdout = &out.writer, .stderr = &err.writer };
    var seen: Seen = .{};
    var remaining: Written = .{};
    emit(sinks, &seen, &remaining, .{ .stream = "stdout", .data = cwd_refused_line });
    try testing.expect(!seen.wrapper_refused);
    emit(sinks, &seen, &remaining, .{ .stream = "stderr", .data = cwd_refused_line ++ "\n" });
    try testing.expect(seen.wrapper_refused);
    try testing.expect(std.meta.activeTag(classifyRefusal(.{ .exited = 125 }, seen)) == .refused_by_wrapper);
    try testing.expect(std.meta.activeTag(classifyRefusal(.{ .exited = 1 }, seen)) == .exited);
    try testing.expect(std.meta.activeTag(classifyRefusal(.{ .exited = 125 }, .{})) == .exited);
}

test "the wrapper is pinned byte for byte (V6)" {
    try std.testing.expectEqualStrings(
        "for f in .git/fx-delete-*; do [ -f \"$f\" ] || continue; { xargs -0 rm -f -- < \"$f\" && rm -f \"$f\"; } || echo \"fx: could not apply $f\" >&2; done; mkdir -p \"$2\" && touch \"$1\" && sleep 0.05 && cd \"$2\" || { echo 'fx: did not run: the sandbox could not prepare the cwd' >&2; exit 125; }; exec bash -c \"$3\"",
        wrapper,
    );
}

const testing = std.testing;
const test_token = "vca_exec_fake";
const test_name = "fx-test";

fn baseFor(buffer: []u8, port: u16) !transport.BaseUrl {
    const origin = try std.mem.print(buffer, "http://127.0.0.1:{d}", .{port});
    return transport.resolveBaseUrl(origin);
}

fn execContext(arena: Allocator, cancel: *std.atomic.Value(bool), base: transport.BaseUrl, capture: *credentials.CaptureTrace, state_dir: *io_mod.VerifiedDir) sandbox.Context {
    return .{
        .alloc = arena,
        .cancel = cancel,
        .base = base,
        .token = .{ .value = test_token },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = test_name,
        .repo_root = "/w/repo",
        .state_dir = state_dir,
    };
}

fn testRequest(env: []const Pair) Request {
    return .{
        .root = "/w/repo",
        .cwd = "/w/repo/app",
        .stamp = "/w/repo/.git/fx-stamp-run1",
        .command = "echo hi",
        .env = env,
        .timeout_ms = null,
        .grace_ms = 30_000,
    };
}

const test_limits: Limits = .{ .first_line_ms = 200, .extend_every_ms = 60 * 60 * 1000, .reattach_pause_ms = 1 };

test "the exec request carries the wrapper, the stamp, the folder, R, only the set env names, and the timeout (V6)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":0}}\n" }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const env = [_]Pair{.{ .name = "FX_SET", .value = "yes" }};
    var request = testRequest(&env);
    request.timeout_ms = 5_000;
    request.grace_ms = 1_000;
    const outcome = run(&ctx, "sess_1", request, sinks, test_limits);
    try testing.expectEqual(@as(u8, 0), outcome.exited);
    server.close();
    try testing.expect(std.mem.find(u8, server.head(0), "POST /v2/sandboxes/sessions/sess_1/cmd?teamId=team_1 HTTP/1.1") != null);
    const body = server.kept[0..server.kept_len];
    try testing.expect(std.mem.find(u8, body, "\"command\":\"bash\"") != null);
    try testing.expect(std.mem.find(u8, body, "\"cwd\":\"/w/repo\"") != null);
    try testing.expect(std.mem.find(u8, body, "\"/w/repo/.git/fx-stamp-run1\",\"/w/repo/app\",\"echo hi\"") != null);
    try testing.expect(std.mem.find(u8, body, "\"env\":{\"FX_SET\":\"yes\"}") != null);
    try testing.expect(std.mem.find(u8, body, "\"wait\":true,\"logs\":true,\"timeout\":6000") != null);
    try testing.expectEqual(@as(usize, 1), server.servedCount());
}

test "the exec timeout is 5 hours when the call sets none (V6)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const body = try encodeBody(arena_state.allocator(), testRequest(&.{}));
    try testing.expect(std.mem.find(u8, body, "\"timeout\":18000000") != null);
}

test "command output reaches its own sink as it arrives, and the exit code is the result (V6)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    const lines =
        "{\"command\":{\"id\":\"cmd_2\",\"exitCode\":null}}\n" ++
        "{\"stream\":\"stdout\",\"data\":\"hi\\n\"}\n" ++
        "{\"stream\":\"stderr\",\"data\":\"err\\n\"}\n" ++
        "{\"stream\":\"stdout\",\"data\":\"\"}\n" ++
        "{\"command\":{\"id\":\"cmd_2\",\"exitCode\":7}}\n";
    var server: test_server.Server = .{ .replies = &.{.{ .mode = .lines_then_close, .body = lines }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits);
    try testing.expectEqual(@as(u8, 7), outcome.exited);
    try testing.expectEqualStrings("hi\n", out_stdout.written());
    try testing.expectEqualStrings("err\n", out_stderr.written());
}

test "a request that never gets a command line within the limit is cut, and sent once, as result unknown (V7)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{.{ .mode = .hold }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits);
    try testing.expectEqual(@as(?[]const u8, null), outcome.unknown);
    try testing.expectEqual(@as(usize, 1), server.servedCount());
}

test "a stream that ends before any command line is result unknown with no id (V7, N3)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{.{ .mode = .lines_then_close, .body = "" }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits);
    try testing.expectEqual(@as(?[]const u8, null), outcome.unknown);
}

test "a quiet close after the command id reattaches: logs skip the bytes already written, then the exit code is read (V8, AC-11)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    const started = "{\"command\":{\"id\":\"cmd_11\",\"exitCode\":null}}\n{\"stream\":\"stdout\",\"data\":\"a\"}\n";
    const logs = "{\"stream\":\"stdout\",\"data\":\"a\"}\n{\"stream\":\"stdout\",\"data\":\"b\"}\n";
    var server: test_server.Server = .{ .replies = &.{
        .{ .mode = .lines_then_close, .body = started },
        .{ .mode = .lines_then_close, .body = logs },
        .{ .body = "{\"command\":{\"id\":\"cmd_11\",\"exitCode\":0}}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits);
    try testing.expectEqual(@as(u8, 0), outcome.exited);
    try testing.expectEqualStrings("ab", out_stdout.written());
    server.close();
    try testing.expectEqual(@as(usize, 3), server.servedCount());
    try testing.expect(std.mem.find(u8, server.head(1), "GET /v2/sandboxes/sessions/sess_1/cmd/cmd_11/logs?teamId=team_1 HTTP/1.1") != null);
    try testing.expect(std.mem.find(u8, server.head(2), "GET /v2/sandboxes/sessions/sess_1/cmd/cmd_11?wait=true&teamId=team_1 HTTP/1.1") != null);
}

test "three failed reattach attempts in a row are lost contact, with the id (N4)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    const started = "{\"command\":{\"id\":\"cmd_9\",\"exitCode\":null}}\n";
    const broken: test_server.Reply = .{ .status = "500 Internal Server Error", .body = "{}" };
    var server: test_server.Server = .{ .replies = &.{
        .{ .mode = .lines_then_close, .body = started },
        broken,
        broken,
        broken,
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits);
    try testing.expectEqualStrings("cmd_9", outcome.unknown.?);
    server.close();
    try testing.expectEqual(@as(usize, 4), server.servedCount());
}

test "V13: an exec answered 401 or 403 before its command line is refused with N11, sent once, and not recovered (V13, V7)" {
    try execLoginRejected("401 Unauthorized", 401);
    try execLoginRejected("403 Forbidden", 403);
}

fn execLoginRejected(status_line: []const u8, status: u16) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var session: sandbox.Session = .{
        .state = .{ .name = "fx-test", .session_id = "sess_1", .expires_at_ms = 9_000_000_000_000, .vcpus = 4, .vcpus_requested = null },
        .generation = .kept,
        .size_note = .none,
    };

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = status_line, .body = "{\"error\":{\"code\":\"forbidden\",\"message\":\"Not authorized\"}}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = runRecovering(&ctx, &session, testRequest(&.{}), sinks, test_limits);
    switch (outcome) {
        .sandbox_refused => |failure| try testing.expectEqual(status, failure.status),
        else => return error.TestExpectedSandboxRefused,
    }
    server.close();
    try testing.expectEqual(@as(usize, 1), server.servedCount());
}

test "a request that is not sent in full did not run: not_sent, never a second request (V7)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, 1);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    const outcome = run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits);
    try testing.expect(std.meta.activeTag(outcome) == .not_sent);
}

test "a stop before the request is sent exits 143 and sends nothing (V10)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{.{ .mode = .hold }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(true);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    try testing.expect(std.meta.activeTag(run(&ctx, "sess_1", testRequest(&.{}), sinks, test_limits)) == .stopped_unsent);
    server.close();
    try testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "a stop after the command id sends one kill at 15, then one at 9, and ends 143 unconfirmed (V10)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var cancel = std.atomic.Value(bool).init(false);
    const started = "{\"command\":{\"id\":\"cmd_7\",\"exitCode\":null}}\n";
    var server: test_server.Server = .{ .replies = &.{
        .{ .mode = .lines_then_hold, .body = started, .cancel = &cancel },
        .{ .body = "{}" },
        .{ .body = "{}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };

    var request = testRequest(&.{});
    request.grace_ms = 1_000;
    try testing.expect(std.meta.activeTag(run(&ctx, "sess_1", request, sinks, test_limits)) == .stopped);
    server.close();
    try testing.expectEqual(@as(usize, 3), server.servedCount());
    try testing.expect(std.mem.find(u8, server.head(1), "POST /v2/sandboxes/sessions/sess_1/cmd/cmd_7/kill?teamId=team_1 HTTP/1.1") != null);
    try testing.expect(std.mem.find(u8, server.head(2), "POST /v2/sandboxes/sessions/sess_1/cmd/cmd_7/kill?teamId=team_1 HTTP/1.1") != null);
}

/// One run on its own thread, so a test can wait for the server while the run streams (V12).
const RunJob = struct {
    ctx: *sandbox.Context,
    sinks: Sinks,
    limits: Limits,
    grace_ms: i64 = 30_000,
    outcome: ?Outcome = null,

    fn go(job: *RunJob) void {
        var request = testRequest(&.{});
        request.grace_ms = job.grace_ms;
        job.outcome = run(job.ctx, "sess_1", request, job.sinks, job.limits);
    }
};

/// A grace of 200 ms leaves a stop budget of zero (V10), so a stop in these tests takes no time.
const instant_stop_grace_ms: i64 = 200;

test "a command that streams gets its session extended on the cadence, and the default cadence is 20 minutes (V12)" {
    try testing.expectEqual(@as(i64, 20 * 60 * 1000), extend_every_ms);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    const started = "{\"command\":{\"id\":\"cmd_12\",\"exitCode\":null}}\n";
    var server: test_server.Server = .{ .replies = &.{
        .{ .mode = .lines_then_hold, .body = started },
        .{ .body = "{}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };
    var limits = test_limits;
    limits.extend_every_ms = 1;

    var job: RunJob = .{ .ctx = &ctx, .sinks = sinks, .limits = limits, .grace_ms = instant_stop_grace_ms };
    const thread = try std.Thread.spawn(.{}, RunJob.go, .{&job});
    server.waitServed(3) catch |err| {
        cancel.store(true, .seq_cst);
        thread.join();
        return err;
    };
    cancel.store(true, .seq_cst);
    thread.join();
    try testing.expect(std.meta.activeTag(job.outcome.?) == .stopped);
    server.close();
    try testing.expect(std.mem.find(u8, server.head(1), "POST /v2/sandboxes/sessions/sess_1/extend-timeout?teamId=team_1 HTTP/1.1") != null);
    try testing.expectEqualStrings("", out_stderr.written());
}

test "a failed extend is one N23 line with its detail, and the run continues (V12, N23)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    const started = "{\"command\":{\"id\":\"cmd_13\",\"exitCode\":null}}\n";
    var server: test_server.Server = .{ .replies = &.{
        .{ .mode = .lines_then_hold, .body = started },
        .{ .status = "500 Internal Server Error", .body = "{}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };
    var limits = test_limits;
    limits.extend_every_ms = 1;

    var job: RunJob = .{ .ctx = &ctx, .sinks = sinks, .limits = limits, .grace_ms = instant_stop_grace_ms };
    const thread = try std.Thread.spawn(.{}, RunJob.go, .{&job});
    server.waitServed(3) catch |err| {
        cancel.store(true, .seq_cst);
        thread.join();
        return err;
    };
    cancel.store(true, .seq_cst);
    thread.join();
    try testing.expectEqualStrings(
        "fx: could not extend the sandbox time limit: HTTP 500; the run continued\n",
        out_stderr.written(),
    );
}

test "a 410 on the cadence extend marks the record at once, while the stream is still open (V12, V3)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try io_mod.durableReplaceVerified(arena, &state_dir, "sandbox.json", "{\"name\":\"fx-test\",\"session_id\":\"sess_1\",\"expires_at_ms\":9000000000000,\"vcpus\":4,\"vcpus_requested\":null}");

    const started = "{\"command\":{\"id\":\"cmd_14\",\"exitCode\":null}}\n";
    var server: test_server.Server = .{ .replies = &.{
        .{ .mode = .lines_then_hold, .body = started },
        .{ .status = "410 Gone", .body = "{}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = execContext(arena, &cancel, base, &capture, &state_dir);
    var out_stdout: std.Io.Writer.Allocating = .init(arena);
    var out_stderr: std.Io.Writer.Allocating = .init(arena);
    const sinks: Sinks = .{ .stdout = &out_stdout.writer, .stderr = &out_stderr.writer };
    var limits = test_limits;
    limits.extend_every_ms = 1;

    var job: RunJob = .{ .ctx = &ctx, .sinks = sinks, .limits = limits, .grace_ms = instant_stop_grace_ms };
    const thread = try std.Thread.spawn(.{}, RunJob.go, .{&job});
    server.waitServed(2) catch |err| {
        cancel.store(true, .seq_cst);
        thread.join();
        return err;
    };
    cancel.store(true, .seq_cst);
    thread.join();
    var file = try io_mod.openExistingReadOnlyRegularFile(state_dir.dir, "sandbox.json", .no_follow);
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(arena, &file, 64 * 1024);
    try testing.expect(std.mem.find(u8, text, "\"expires_at_ms\":0") != null);
}

fn setFlagNow(flag: *std.atomic.Value(bool)) void {
    flag.store(true, .seq_cst);
}

test "the reattach wait ends at once when the stop flag is set, and waits its full time otherwise (V8, R2.3)" {
    var stop = std.atomic.Value(bool).init(false);
    const setter = try std.Thread.spawn(.{}, setFlagNow, .{&stop});
    const started_at = io_mod.milliTimestamp();
    pauseUnlessStopped(&stop, 60_000);
    setter.join();
    try testing.expect(io_mod.milliTimestamp() - started_at < 10_000);

    var never = std.atomic.Value(bool).init(false);
    const waited_at = io_mod.milliTimestamp();
    pauseUnlessStopped(&never, 30);
    try testing.expect(io_mod.milliTimestamp() - waited_at >= 30);
}

test "a closed send gate stops the request before any byte is sent (V10)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{}" }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var gate = std.atomic.Value(u8).init(stream.gate_closed);
    var capture: credentials.CaptureTrace = .{};
    try testing.expectError(error.Cancelled, stream.open(arena, &cancel, base, .{ .value = test_token }, capture.trace(), .{
        .step = "exec",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/sess_1/cmd",
        .send_gate = &gate,
    }));
    server.close();
    try testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "the stop budget is the grace less 200 ms, and never negative (V10)" {
    try testing.expectEqual(@as(i64, 29_800), stopBudget(30_000));
    try testing.expectEqual(@as(i64, 0), stopBudget(100));
}

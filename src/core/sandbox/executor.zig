//! Runs one command in a sandbox session, as fx runs a local command: live
//! output, the exit code, stop, and timeout. A lost connection is reported
//! as unknown, and fx never sends the command again by itself.
const std = @import("std");
const api = @import("api.zig");
const client_mod = @import("client.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

/// Added to the time left, so the server's own stop comes after fx's.
const timeout_backstop_ms = 10_000;
const min_timeout_ms = 1_000;
/// A partial line longer than this is relayed as it is.
const max_pending_line_bytes = 64 * 1024;
const max_command_id_bytes = 128;

/// One command to run in a session.
pub const Run = struct {
    session: []const u8,
    /// Shell text, run as `bash -lc <command>`, or as `bash -c <command>` when `login` is false.
    command: []const u8,
    remote_cwd: []const u8,
    env: []const api.Pair = &.{},
    /// Run with `bash -lc` (a login shell, as users expect) or plain `bash -c`.
    login: bool = true,
};

/// How the command is watched and bounded.
pub const Controls = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    /// Aborts the stream at once, without waiting for a stop.
    force_cancel_flag: ?*std.atomic.Value(bool) = null,
    /// Wall-clock milliseconds at which the command must stop.
    deadline_ms: ?i64 = null,
    max_output_bytes: usize,
    /// How long a stop may take before fx shuts the connection.
    stop_grace_ms: u64 = 5_000,
    poll_ms: u64 = 50,
};

/// Receives whole lines of live output, each with its `\n` when it has one.
pub const Output = struct {
    context: *anyopaque,
    on_line: *const fn (context: *anyopaque, stream: api.Stream, line: []const u8) anyerror!void,
};

/// Why fx stopped the command, if it did.
pub const Stop = enum { none, cancelled, timed_out };

/// What happened to the command. Its text lives in the caller's arena.
pub const Outcome = struct {
    started: bool = false,
    command_id: ?[]const u8 = null,
    exit_code: ?i64 = null,
    stop: Stop = .none,
    /// The answer ended before the exit code arrived. The command may still run.
    connection_lost: bool = false,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    truncated: bool = false,
    duration_ms: u64 = 0,
    /// Why the command could not start, or why its stream failed.
    failure: ?[]const u8 = null,
    /// The HTTP status when the API refused the start. The command did not run.
    start_status: ?u16 = null,
};

/// State the watcher and the calling thread share. Every field is read and
/// written under `mutex`.
const Shared = struct {
    mutex: std.Io.Mutex = .init,
    stop: Stop = .none,
    stop_at_ms: i64 = 0,
    command_known: bool = false,
    command_len: usize = 0,
    command_buf: [max_command_id_bytes]u8 = undefined,
    kill_sent_at_ms: i64 = 0,
    finished: bool = false,

    /// What the watcher does on one poll.
    const Decision = struct {
        done: bool = false,
        send_kill: bool = false,
        kill_len: usize = 0,
        kill_id: [max_command_id_bytes]u8 = undefined,
        abort: bool = false,
    };

    /// Sets a stop when one is asked for, and decides the kill and the abort.
    fn observe(self: *Shared, controls: Controls, now: i64) Decision {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var decision: Decision = .{};
        if (self.finished) {
            decision.done = true;
            return decision;
        }
        if (self.stop == .none) {
            if (controls.cancel_flag) |flag| {
                if (flag.load(.acquire)) {
                    self.stop = .cancelled;
                    self.stop_at_ms = now;
                }
            }
        }
        if (self.stop == .none) {
            if (controls.deadline_ms) |deadline| {
                if (now >= deadline) {
                    self.stop = .timed_out;
                    self.stop_at_ms = now;
                }
            }
        }
        if (self.stop != .none and self.command_known and self.kill_sent_at_ms == 0) {
            self.kill_sent_at_ms = now;
            decision.send_kill = true;
            decision.kill_len = self.command_len;
            @memcpy(decision.kill_id[0..self.command_len], self.command_buf[0..self.command_len]);
        }
        const grace: i64 = @intCast(controls.stop_grace_ms);
        if (controls.force_cancel_flag) |flag| {
            if (flag.load(.acquire)) decision.abort = true;
        }
        if (self.kill_sent_at_ms != 0 and now - self.kill_sent_at_ms > grace) decision.abort = true;
        if (self.stop != .none and !self.command_known and now - self.stop_at_ms > grace) decision.abort = true;
        return decision;
    }

    /// Keeps the first command id. An id too long for a path is not kept, so
    /// no kill is sent for it, and a stop then ends by the abort.
    fn noteCommand(self: *Shared, id: []const u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.command_known or id.len > max_command_id_bytes) return;
        @memcpy(self.command_buf[0..id.len], id);
        self.command_len = id.len;
        self.command_known = true;
    }

    /// Records a stop, unless one is already set.
    fn requestStop(self: *Shared, reason: Stop, now: i64) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stop != .none) return;
        self.stop = reason;
        self.stop_at_ms = now;
    }

    fn markFinished(self: *Shared) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.finished = true;
    }

    fn stopReason(self: *Shared) Stop {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.stop;
    }

    /// Copies the command id into `arena`. Called only after the watcher has ended.
    fn copyCommandId(self: *Shared, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.command_known) return null;
        return try arena.dupe(u8, self.command_buf[0..self.command_len]);
    }
};

/// What the watcher thread needs. It owns no memory: the state it reads is
/// on the calling thread's stack, and the thread is joined before that ends.
const Watch = struct {
    client: client_mod.Client,
    session: []const u8,
    controls: Controls,
    abort: *client_mod.Abort,
    shared: *Shared,
};

/// Polls until the command ends. It sends the kill once, and aborts the
/// stream when a stop is ignored past its grace time. It never uses an arena
/// that another thread uses.
fn watchRun(watch: *Watch) void {
    while (true) {
        io_mod.sleep(watch.controls.poll_ms * 1_000_000);
        var decision = watch.shared.observe(watch.controls, io_mod.milliTimestamp());
        if (decision.done) return;
        if (decision.send_kill) {
            if (!sendKill(watch.client, watch.session, decision.kill_id[0..decision.kill_len])) {
                decision.abort = true;
            }
        }
        if (decision.abort) watch.abort.abort();
    }
}

/// Sends the kill with an arena of its own. False when the kill was not accepted.
fn sendKill(client: client_mod.Client, session: []const u8, command_id: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var failure: client_mod.Failure = .{};
    client.kill(arena_state.allocator(), session, command_id, &failure) catch return false;
    return true;
}

/// Receives the client's log lines on the calling thread. It keeps the
/// output and relays whole lines. Only that thread uses its arena.
const Collector = struct {
    arena: std.mem.Allocator,
    output: ?Output,
    max_output_bytes: usize,
    shared: *Shared,
    started: bool = false,
    exit_code: ?i64 = null,
    failure: ?[]const u8 = null,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    truncated: bool = false,
    pending_stdout: std.ArrayList(u8) = .empty,
    pending_stderr: std.ArrayList(u8) = .empty,
    relay_failed: bool = false,

    fn sink(self: *Collector) client_mod.LogSink {
        return .{ .context = self, .on_log = onLog };
    }

    fn onLog(context: *anyopaque, line: api.LogLine) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        switch (line) {
            .command => |command| {
                self.started = true;
                self.shared.noteCommand(command.id);
                if (command.exit_code) |code| self.exit_code = code;
            },
            .output => |output| try self.onOutput(output.stream, output.data),
            .failure => |failure| self.failure = try self.arena.print("the sandbox closed the command stream: {s}", .{failure.message}),
            .other => {},
        }
    }

    /// Keeps up to `max_output_bytes` in total for both streams. Every byte
    /// is counted, and every byte is relayed.
    fn onOutput(self: *Collector, stream: api.Stream, data: []const u8) !void {
        switch (stream) {
            .stdout => self.stdout_bytes += data.len,
            .stderr => self.stderr_bytes += data.len,
        }
        const room = self.max_output_bytes -| (self.stdout.items.len + self.stderr.items.len);
        const keep = @min(room, data.len);
        if (keep > 0) try self.textOf(stream).appendSlice(self.arena, data[0..keep]);
        if (keep < data.len) self.truncated = true;
        self.relay(stream, data);
    }

    fn textOf(self: *Collector, stream: api.Stream) *std.ArrayList(u8) {
        return switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
    }

    fn pendingOf(self: *Collector, stream: api.Stream) *std.ArrayList(u8) {
        return switch (stream) {
            .stdout => &self.pending_stdout,
            .stderr => &self.pending_stderr,
        };
    }

    /// Relays each complete line, and a partial line too long to wait for.
    /// The rest stays pending for the next chunk.
    fn relay(self: *Collector, stream: api.Stream, data: []const u8) void {
        const output = self.output orelse return;
        if (self.relay_failed) return;
        const pending = self.pendingOf(stream);
        pending.appendSlice(self.arena, data) catch {
            self.relay_failed = true;
            self.shared.requestStop(.cancelled, io_mod.milliTimestamp());
            debug_trace.logf("sandbox", "live output relay failed (OutOfMemory): dropped {d} bytes of {s}, stopping the command", .{ data.len, @tagName(stream) });
            return;
        };
        const items = pending.items;
        var start: usize = 0;
        while (std.mem.findScalarPos(u8, items, start, '\n')) |index| {
            if (!self.emit(output, stream, items[start .. index + 1])) return;
            start = index + 1;
        }
        if (items.len - start > max_pending_line_bytes) {
            if (!self.emit(output, stream, items[start..])) return;
            start = items.len;
        }
        const rest = items[start..];
        @memmove(items[0..rest.len], rest);
        pending.items.len = rest.len;
    }

    /// Hands one line to the caller. A failure stops relaying, stops the
    /// command, and is logged with the bytes it dropped.
    fn emit(self: *Collector, output: Output, stream: api.Stream, bytes: []const u8) bool {
        output.on_line(output.context, stream, bytes) catch |err| {
            self.relay_failed = true;
            self.shared.requestStop(.cancelled, io_mod.milliTimestamp());
            debug_trace.logf("sandbox", "live output relay failed ({s}): dropped {d} bytes of {s}, stopping the command", .{ @errorName(err), bytes.len, @tagName(stream) });
            return false;
        };
        return true;
    }

    /// Relays what is left of each partial line, without its `\n`, once the command ends.
    fn flush(self: *Collector) void {
        const output = self.output orelse return;
        for ([_]api.Stream{ .stdout, .stderr }) |stream| {
            const pending = self.pendingOf(stream);
            if (pending.items.len == 0 or self.relay_failed) continue;
            _ = self.emit(output, stream, pending.items);
            pending.items.len = 0;
        }
    }
};

/// The server-side backstop: the time left plus a margin, so fx's own stop comes first.
fn commandTimeout(controls: Controls, now: i64) ?u64 {
    const deadline = controls.deadline_ms orelse return null;
    const left = deadline - now;
    const left_ms: u64 = if (left > 0) @intCast(left) else 0;
    return @max(left_ms + timeout_backstop_ms, min_timeout_ms);
}

fn elapsedMs(started_ms: i64) u64 {
    const elapsed = io_mod.milliTimestamp() - started_ms;
    return if (elapsed > 0) @intCast(elapsed) else 0;
}

/// Runs `run` in its session and returns what happened. Output lines go to
/// `output` as they arrive. The start is never sent twice.
pub fn execute(
    client: client_mod.Client,
    arena: std.mem.Allocator,
    run: Run,
    controls: Controls,
    output: ?Output,
) error{OutOfMemory}!Outcome {
    const started_ms = io_mod.milliTimestamp();
    var abort: client_mod.Abort = .{};
    var shared: Shared = .{};
    var collector: Collector = .{
        .arena = arena,
        .output = output,
        .max_output_bytes = controls.max_output_bytes,
        .shared = &shared,
    };
    var watch: Watch = .{
        .client = client,
        .session = run.session,
        .controls = controls,
        .abort = &abort,
        .shared = &shared,
    };
    var watcher = std.Thread.spawn(.{}, watchRun, .{&watch}) catch {
        return .{ .failure = "could not start the stop watcher", .duration_ms = elapsedMs(started_ms) };
    };

    const flag: []const u8 = if (run.login) "-lc" else "-c";
    const args = [_][]const u8{ flag, run.command };
    var failure: client_mod.Failure = .{};
    const result = client.runCommand(arena, run.session, .{
        .command = "bash",
        .args = &args,
        .cwd = run.remote_cwd,
        .env = run.env,
        .timeout_ms = commandTimeout(controls, started_ms),
    }, collector.sink(), &abort, &failure);

    shared.markFinished();
    watcher.join();
    collector.flush();

    var outcome: Outcome = .{
        .started = collector.started,
        .exit_code = collector.exit_code,
        .stop = shared.stopReason(),
        .stdout = collector.stdout.items,
        .stderr = collector.stderr.items,
        .stdout_bytes = collector.stdout_bytes,
        .stderr_bytes = collector.stderr_bytes,
        .truncated = collector.truncated,
        .failure = collector.failure,
        .duration_ms = elapsedMs(started_ms),
    };
    outcome.command_id = try shared.copyCommandId(arena);
    if (result) |_| {
        outcome.connection_lost = outcome.exit_code == null;
    } else |err| switch (err) {
        error.Aborted => outcome.connection_lost = outcome.exit_code == null,
        error.SandboxApiFailed, error.SandboxExists => {
            outcome.failure = failure.message;
            outcome.connection_lost = collector.started and outcome.exit_code == null;
            if (!collector.started) outcome.start_status = failure.status;
        },
        error.AnswerLost => {
            outcome.failure = failure.message;
            outcome.connection_lost = true;
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
    return outcome;
}

const testing = std.testing;

const run_fixture: Run = .{ .session = "sbx_1", .command = "make test", .remote_cwd = "/w" };
const start_line = "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":null}}";
const exit_143 = "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":143}}";
const exit_0 = "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":0}}";
const thirty_x = "xxxxxxxxxx" ++ "xxxxxxxxxx" ++ "xxxxxxxxxx";
const thirty_x_line = "{\"data\":\"" ++ thirty_x ++ "\",\"stream\":\"stdout\"}";
/// How long a held stream waits for a kill before the test gives up.
const hold_timeout_ms = 5_000;

/// A fake command API. A start streams `lines`. With `hold`, the stream then
/// stays open until a kill arrives (and then ends with exit 143) or the abort
/// fires. A kill is counted, and can fail or be ignored.
const FakeCommand = struct {
    mutex: std.Io.Mutex = .init,
    starts: usize = 0,
    kills: usize = 0,
    start_body: []const u8 = "",
    start_status: u16 = 200,
    start_error: []const u8 = "",
    lines: []const []const u8 = &.{},
    hold: bool = false,
    kill_fails: bool = false,
    kill_ignored: bool = false,
    start_lost: bool = false,

    fn send(context: *anyopaque, arena: std.mem.Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        _ = arena;
        const self: *FakeCommand = @ptrCast(@alignCast(context));
        if (std.mem.find(u8, call.request.target, "/kill?") != null) return self.kill();
        return self.start(call);
    }

    fn start(self: *FakeCommand, call: client_mod.Call) anyerror!client_mod.Response {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.starts += 1;
        self.start_body = call.request.body;
        self.mutex.unlock(io);
        if (self.start_lost) return error.AnswerLost;
        if (self.start_status != 200) return .{ .status = self.start_status, .body = self.start_error };
        const sink = call.lines orelse return error.TestUnexpectedResult;
        for (self.lines) |line| try sink.on_line(sink.context, line);
        if (self.hold) try self.holdUntilStopped(sink, call.abort);
        return .{ .status = 200 };
    }

    fn holdUntilStopped(self: *FakeCommand, sink: client_mod.LineSink, abort: ?*client_mod.Abort) anyerror!void {
        const io = io_mod.getIo();
        var waited_ms: u64 = 0;
        while (waited_ms < hold_timeout_ms) : (waited_ms += 10) {
            self.mutex.lockUncancelable(io);
            const killed = self.kills > 0;
            const ignored = self.kill_ignored;
            self.mutex.unlock(io);
            if (killed and !ignored) return sink.on_line(sink.context, exit_143);
            if (abort) |handle| {
                if (handle.wasRequested()) return error.Aborted;
            }
            io_mod.sleep(10_000_000);
        }
        return error.TestHoldExpired;
    }

    fn kill(self: *FakeCommand) anyerror!client_mod.Response {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.kills += 1;
        const fails = self.kill_fails;
        self.mutex.unlock(io);
        if (fails) return .{ .status = 500, .body = "{\"error\":{\"message\":\"kill failed\"}}" };
        return .{ .status = 200 };
    }
};

fn testClient(fake: *FakeCommand) client_mod.Client {
    return .{
        .transport = .{ .context = fake, .send = FakeCommand.send },
        .base_url = "https://api.test",
        .team = "team-a",
        .project = "proj",
        .token = "tok",
    };
}

/// Records each relayed line as `stdout:<line>|` or `stderr:<line>|`.
const Recorder = struct {
    text: [512]u8 = undefined,
    len: usize = 0,

    fn onLine(context: *anyopaque, stream: api.Stream, line: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.put(switch (stream) {
            .stdout => "stdout:",
            .stderr => "stderr:",
        });
        self.put(line);
        self.put("|");
    }

    fn put(self: *Recorder, bytes: []const u8) void {
        @memcpy(self.text[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn slice(self: *const Recorder) []const u8 {
        return self.text[0..self.len];
    }
};

/// Refuses every line, as a caller whose output pipe is closed would.
fn refuseLine(context: *anyopaque, stream: api.Stream, line: []const u8) anyerror!void {
    _ = context;
    _ = stream;
    _ = line;
    return error.BrokenPipe;
}

fn setFlagAfter(flag: *std.atomic.Value(bool), ms: u64) void {
    io_mod.sleep(ms * 1_000_000);
    flag.store(true, .release);
}

test "output and the exit code come back as lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .lines = &[_][]const u8{
        start_line,
        "{\"data\":\"a\\nb\",\"stream\":\"stdout\"}",
        "{\"data\":\"c\\n\",\"stream\":\"stdout\"}",
        "{\"data\":\"e\\n\",\"stream\":\"stderr\"}",
        "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":3}}",
    } };
    var recorder: Recorder = .{};

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 1024 }, .{
        .context = &recorder,
        .on_line = Recorder.onLine,
    });
    try testing.expect(outcome.started);
    try testing.expectEqual(@as(?i64, 3), outcome.exit_code);
    try testing.expectEqualStrings("cmd_1", outcome.command_id.?);
    try testing.expectEqualStrings("a\nbc\n", outcome.stdout);
    try testing.expectEqualStrings("e\n", outcome.stderr);
    try testing.expectEqualStrings("stdout:a\n|stdout:bc\n|stderr:e\n|", recorder.slice());
    try testing.expectEqual(Stop.none, outcome.stop);
    try testing.expect(!outcome.connection_lost);
}

test "a cancel kills the command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .hold = true, .lines = &[_][]const u8{start_line} };
    var cancel = std.atomic.Value(bool).init(false);
    const setter = try std.Thread.spawn(.{}, setFlagAfter, .{ &cancel, 100 });
    defer setter.join();

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{
        .cancel_flag = &cancel,
        .max_output_bytes = 64,
    }, null);
    try testing.expectEqual(Stop.cancelled, outcome.stop);
    try testing.expectEqual(@as(?i64, 143), outcome.exit_code);
    try testing.expectEqual(@as(usize, 1), fake.kills);
    try testing.expect(!outcome.connection_lost);
}

test "a timeout kills the command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .hold = true, .lines = &[_][]const u8{start_line} };

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{
        .deadline_ms = io_mod.milliTimestamp() + 100,
        .max_output_bytes = 64,
    }, null);
    try testing.expectEqual(Stop.timed_out, outcome.stop);
    try testing.expectEqual(@as(?i64, 143), outcome.exit_code);
    try testing.expectEqual(@as(usize, 1), fake.kills);
}

test "a stop the sandbox ignores shuts the connection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .hold = true, .kill_ignored = true, .lines = &[_][]const u8{start_line} };
    var cancel = std.atomic.Value(bool).init(true);

    const started = io_mod.milliTimestamp();
    const outcome = try execute(testClient(&fake), arena, run_fixture, .{
        .cancel_flag = &cancel,
        .stop_grace_ms = 200,
        .max_output_bytes = 64,
    }, null);
    try testing.expect(io_mod.milliTimestamp() - started < 2000);
    try testing.expect(outcome.connection_lost);
    try testing.expectEqual(@as(?i64, null), outcome.exit_code);
    try testing.expectEqual(Stop.cancelled, outcome.stop);
    try testing.expectEqual(@as(usize, 1), fake.kills);
}

test "a relay error stops the command and says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .hold = true, .lines = &[_][]const u8{
        start_line,
        "{\"data\":\"x\\n\",\"stream\":\"stdout\"}",
    } };
    var unused: u8 = 0;

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 64 }, .{
        .context = &unused,
        .on_line = refuseLine,
    });
    try testing.expectEqual(Stop.cancelled, outcome.stop);
    try testing.expectEqual(@as(?i64, 143), outcome.exit_code);
    try testing.expectEqual(@as(usize, 1), fake.kills);
    try testing.expectEqualStrings("x\n", outcome.stdout);
}

test "a lost connection is reported and never sent again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .lines = &[_][]const u8{
        start_line,
        "{\"data\":\"partial\\n\",\"stream\":\"stdout\"}",
    } };

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 64 }, null);
    try testing.expect(outcome.started);
    try testing.expectEqual(@as(?i64, null), outcome.exit_code);
    try testing.expect(outcome.connection_lost);
    try testing.expectEqualStrings("partial\n", outcome.stdout);
    try testing.expectEqual(@as(usize, 1), fake.starts);
    try testing.expectEqual(@as(usize, 0), fake.kills);
}

test "output beyond the limit is dropped and counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .lines = &[_][]const u8{ start_line, thirty_x_line, exit_0 } };

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 10 }, null);
    try testing.expectEqual(@as(usize, 10), outcome.stdout.len);
    try testing.expectEqual(@as(usize, 30), outcome.stdout_bytes);
    try testing.expect(outcome.truncated);
    try testing.expectEqual(@as(?i64, 0), outcome.exit_code);
}

test "a start failure says why" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{
        .start_status = 500,
        .start_error = "{\"error\":{\"message\":\"no capacity\"}}",
    };

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 64 }, null);
    try testing.expect(!outcome.started);
    try testing.expect(outcome.failure != null);
    try testing.expect(std.mem.find(u8, outcome.failure.?, "HTTP 500: no capacity") != null);
    try testing.expect(!outcome.connection_lost);
    try testing.expectEqual(@as(usize, 1), fake.starts);
}

test "a refused start reports its HTTP status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{
        .start_status = 404,
        .start_error = "{\"error\":{\"message\":\"no such session\"}}",
    };

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 64 }, null);
    try testing.expect(!outcome.started);
    try testing.expectEqual(@as(?u16, 404), outcome.start_status);
    try testing.expect(!outcome.connection_lost);
    try testing.expectEqual(@as(usize, 1), fake.starts);
}

test "the request carries the command, folder, env, and backstop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .lines = &[_][]const u8{ start_line, exit_0 } };
    const env = [_]api.Pair{.{ .name = "A", .value = "1" }};
    const run: Run = .{ .session = "sbx_1", .command = "make test", .remote_cwd = "/w", .env = &env };

    _ = try execute(testClient(&fake), arena, run, .{
        .deadline_ms = io_mod.milliTimestamp() + 5000,
        .max_output_bytes = 64,
    }, null);
    const root = switch (try std.json.parseFromSliceLeaky(std.json.Value, arena, fake.start_body, .{})) {
        .object => |map| map,
        else => return error.TestUnexpectedResult,
    };
    const args = root.get("args").?.array.items;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("-lc", args[0].string);
    try testing.expectEqualStrings("make test", args[1].string);
    try testing.expectEqualStrings("/w", root.get("cwd").?.string);
    try testing.expectEqualStrings("1", root.get("env").?.object.get("A").?.string);
    try testing.expect(root.get("timeout").?.integer >= 10000);
}

/// The args a recorded start request carried.
fn startArgs(arena: std.mem.Allocator, body: []const u8) ![]const std.json.Value {
    const root = switch (try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{})) {
        .object => |map| map,
        else => return error.TestUnexpectedResult,
    };
    return root.get("args").?.array.items;
}

test "the login flag picks bash -lc or bash -c" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var login_fake: FakeCommand = .{ .lines = &[_][]const u8{ start_line, exit_0 } };
    const login_run: Run = .{ .session = "sbx_1", .command = "make test", .remote_cwd = "/w" };
    _ = try execute(testClient(&login_fake), arena, login_run, .{ .max_output_bytes = 64 }, null);
    const login_args = try startArgs(arena, login_fake.start_body);
    try testing.expectEqual(@as(usize, 2), login_args.len);
    try testing.expectEqualStrings("-lc", login_args[0].string);
    try testing.expectEqualStrings("make test", login_args[1].string);

    var plain_fake: FakeCommand = .{ .lines = &[_][]const u8{ start_line, exit_0 } };
    const plain_run: Run = .{ .session = "sbx_1", .command = "make test", .remote_cwd = "/w", .login = false };
    _ = try execute(testClient(&plain_fake), arena, plain_run, .{ .max_output_bytes = 64 }, null);
    const plain_args = try startArgs(arena, plain_fake.start_body);
    try testing.expectEqual(@as(usize, 2), plain_args.len);
    try testing.expectEqualStrings("-c", plain_args[0].string);
    try testing.expectEqualStrings("make test", plain_args[1].string);
}

test "a lost start answer may have started the command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeCommand = .{ .start_lost = true };

    const outcome = try execute(testClient(&fake), arena, run_fixture, .{ .max_output_bytes = 64 }, null);
    try testing.expect(!outcome.started);
    try testing.expectEqual(@as(?i64, null), outcome.exit_code);
    try testing.expect(outcome.connection_lost);
    try testing.expect(outcome.failure != null);
    try testing.expect(std.mem.find(u8, outcome.failure.?, "may have taken effect") != null);
    try testing.expectEqual(@as(usize, 1), fake.starts);
}

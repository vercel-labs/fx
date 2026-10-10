//! Stdio I/O layer: runs one stdio server process for the `stdio_conn` core.
//!
//! Tasks for stdout, stderr, the exit watcher, and timers post to one queue.
//! Only the host's thread steps the core: `start`, `stop`, `reconnect`,
//! `setEra`, `send`, and `next` all run there, so the core needs no lock.
//! `next` waits for a posted event, steps the core, carries out its effects,
//! and returns what the host should see.
//!
//! The exit watcher reaps with `waitpid(WNOHANG)` under the same lock that
//! signals take, so a signal never reaches a reaped pid that the system may
//! have reused for another process.
//!
//! Each server runs in its own process group, and signals go to the
//! whole group, so a wrapper (npx, uvx, a shell) and the server it starts
//! stop together. A descendant that leaves the group with setsid escapes.
//!
//! Every process is listed, so a program about to exit can send each
//! server's group SIGTERM from any thread and wait for none of them.

const std = @import("std");
const core = @import("../core/stdio_conn.zig");
const wire = @import("../protocol/wire.zig");
const lines = @import("lines.zig");
const trace = @import("trace.zig");
const Bell = @import("bell.zig").Bell;

/// Every `Process` between `init` and `deinit`, and whether the program
/// is exiting.
const everyone = struct {
    var mutex: std.Io.Mutex = .init;
    var list: std.DoublyLinkedList = .{};
    var exiting: std.atomic.Value(bool) = .init(false);
};

/// For a program about to exit. Sends SIGTERM to every server's process
/// group and returns at once; a server that starts afterwards gets it as it
/// starts. Their stdin closes when the program exits. Safe from any thread.
pub fn signalAllForExit(io: std.Io) void {
    everyone.exiting.store(true, .seq_cst);
    everyone.mutex.lockUncancelable(io);
    defer everyone.mutex.unlock(io);
    var it = everyone.list.first;
    while (it) |node| : (it = node.next) {
        const p: *Process = @fieldParentPtr("node", node);
        p.signal(.term);
    }
}

pub const Options = struct {
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map = null,
    config: core.Config = .{},
    /// The longest stdout line; a longer one is a connection error.
    max_line: usize = 16 * 1024 * 1024,
    /// The longest stderr line kept for logs; the rest of that line is dropped.
    max_stderr_line: usize = 8 * 1024,
    /// How often the exit watcher checks on the process.
    poll_ms: u32 = 20,
    trace: ?*trace.Writer = null,
    trace_instance: []const u8 = "stdio",
    /// Rung after each post, for a host that reads many processes.
    bell: ?*Bell = null,
    /// Where stderr lines go, called from the reader task, so it must
    /// be safe to call from another thread. Without one they are queued for
    /// `next`, and dropped when the queue is full.
    stderr: ?Sink = null,
};

pub const Sink = struct {
    context: *anyopaque,
    line: *const fn (context: *anyopaque, line: []const u8) void,
};

/// What the host sees from `next`. Slices stay valid until the next call.
pub const Incoming = union(enum) {
    /// A message from the current server process.
    message: struct { bytes: []const u8, message: wire.Message },
    /// A line the server wrote to stderr, for logs only.
    stderr: []const u8,
    /// A stdout line that isn't a valid MCP message was dropped.
    dropped: wire.DecodeError,
    /// The connection changed state. `lost` means the process is gone and
    /// requests in flight on it are lost (`transport_lost` in `core/request.zig`).
    changed: struct { state: core.State, lost: bool },
    /// `next` was given a timeout and it passed first.
    timeout,
};

pub const SpawnError = std.process.SpawnError || std.Io.ConcurrentError;

pub const Error = core.StepError || std.Io.Cancelable || std.Io.ConcurrentError || std.mem.Allocator.Error || error{TraceFailed};

const Posted = union(enum) {
    line: struct { generation: core.Generation, bytes: []u8 },
    oversized: core.Generation,
    stderr: []u8,
    exited: core.Generation,
    timer: core.Timer,
    wake: u32,

    fn free(posted: Posted, gpa: std.mem.Allocator) void {
        switch (posted) {
            .line => |l| gpa.free(l.bytes),
            .stderr => |s| gpa.free(s),
            else => {},
        }
    }
};

pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    conn: core.Conn,
    queue: std.Io.Queue(Posted),
    queue_buffer: [64]Posted = undefined,
    tasks: std.Io.Group = .init,
    /// Guards `pid` against the exit watcher reaping it.
    pid_lock: std.Io.Mutex = .init,
    /// Set while the current process is unreaped.
    pid: ?std.posix.pid_t = null,
    stdin: ?std.Io.File = null,
    /// The bytes behind the last `message` or `stderr` returned by `next`.
    held: ?[]u8 = null,
    /// The message `send` is writing, while its step runs.
    outgoing: []const u8 = "",
    /// Counts `next` timeouts, so a stale wake-up is ignored.
    wake_id: u32 = 0,
    /// stderr lines dropped because the queue was full.
    stderr_dropped: std.atomic.Value(u32) = .init(0),
    /// Why the last start failed, for logs.
    spawn_error: ?SpawnError = null,
    /// This process in `everyone.list`.
    node: std.DoublyLinkedList.Node = .{},

    /// `options` (and the slices it holds) must outlive the process.
    pub fn init(p: *Process, io: std.Io, gpa: std.mem.Allocator, options: Options) void {
        p.* = .{ .io = io, .gpa = gpa, .options = options, .conn = .init(options.config), .queue = undefined };
        p.queue = .init(&p.queue_buffer);
        everyone.mutex.lockUncancelable(io);
        everyone.list.append(&p.node);
        everyone.mutex.unlock(io);
    }

    /// Kills a process that is still running (no polite shutdown; call
    /// `stop` and wait for `stopped` first for that), stops every task, and
    /// frees everything queued.
    pub fn deinit(p: *Process) void {
        everyone.mutex.lockUncancelable(p.io);
        everyone.list.remove(&p.node);
        everyone.mutex.unlock(p.io);
        p.pid_lock.lockUncancelable(p.io);
        if (p.pid) |pid| {
            std.posix.kill(pid, .KILL) catch {};
            _ = std.c.waitpid(pid, null, 0);
            p.pid = null;
        }
        p.pid_lock.unlock(p.io);
        if (p.stdin) |file| file.close(p.io);
        p.stdin = null;
        p.tasks.cancel(p.io);
        p.queue.close(p.io);
        var rest: [16]Posted = undefined;
        while (true) {
            const n = p.queue.getUncancelable(p.io, &rest, 0) catch break;
            if (n == 0) break;
            for (rest[0..n]) |posted| posted.free(p.gpa);
        }
        p.release();
    }

    pub fn start(p: *Process) Error!void {
        _ = try p.apply(.start_requested);
    }

    pub fn stop(p: *Process) Error!void {
        _ = try p.apply(.stop_requested);
    }

    pub fn reconnect(p: *Process) Error!void {
        _ = try p.apply(.reconnect_requested);
    }

    /// Version detection finished for the current process.
    pub fn setEra(p: *Process, era: @FieldType(core.Event, "era_detected")) Error!void {
        _ = try p.apply(.{ .era_detected = era });
    }

    /// Writes one encoded message, which must not contain a line break.
    pub fn send(p: *Process, kind: core.MessageKind, message: []const u8) Error!void {
        std.debug.assert(std.mem.findAny(u8, message, "\r\n") == null);
        p.outgoing = message;
        defer p.outgoing = "";
        _ = try p.apply(.{ .send = kind });
    }

    /// Waits for the next thing the host should see. With `timeout_ms`,
    /// returns `timeout` if nothing arrives first.
    pub fn next(p: *Process, timeout_ms: ?u32) Error!Incoming {
        p.release();
        if (timeout_ms) |ms| {
            p.wake_id +%= 1;
            try p.tasks.concurrent(p.io, postAfter, .{ p, .{ .wake = p.wake_id }, ms });
        }
        while (true) {
            const posted = p.queue.getOne(p.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => unreachable, // only deinit closes the queue
            };
            if (posted == .wake) {
                if (posted.wake == p.wake_id and timeout_ms != null) return .timeout;
            } else if (try p.take(posted)) |incoming| return incoming;
        }
    }

    /// What is already queued, without waiting; null when nothing is.
    pub fn poll(p: *Process) Error!?Incoming {
        p.release();
        var one: [1]Posted = undefined;
        while ((p.queue.get(p.io, &one, 0) catch 0) == 1) {
            if (one[0] != .wake) if (try p.take(one[0])) |incoming| return incoming;
        }
        return null;
    }

    /// What a posted item means to the host; null for one to skip.
    fn take(p: *Process, posted: Posted) Error!?Incoming {
        const before = p.conn.state;
        const lost = switch (posted) {
            .wake => unreachable,
            .line => |line| {
                const message = wire.decode(line.bytes) catch |err| {
                    p.gpa.free(line.bytes);
                    return .{ .dropped = err };
                };
                const result = p.apply(.{ .line_received = line.generation }) catch |err| {
                    p.gpa.free(line.bytes);
                    return err;
                };
                if (result.delivered) {
                    p.held = line.bytes;
                    return .{ .message = .{ .bytes = line.bytes, .message = message } };
                }
                p.gpa.free(line.bytes);
                return null;
            },
            .stderr => |bytes| {
                p.held = bytes;
                return .{ .stderr = bytes };
            },
            .oversized => |g| (try p.apply(.{ .oversized_line = g })).lost,
            .exited => |g| (try p.apply(.{ .process_exited = g })).lost,
            .timer => |t| (try p.apply(.{ .timer_fired = t })).lost,
        };
        if (lost or p.conn.state != before) return .{ .changed = .{ .state = p.conn.state, .lost = lost } };
        return null;
    }

    fn release(p: *Process) void {
        if (p.held) |bytes| p.gpa.free(bytes);
        p.held = null;
    }

    const Applied = struct { delivered: bool = false, lost: bool = false };

    /// Steps the core, then carries out its effects. A spawn's result and a
    /// failed write become further events, stepped here before returning.
    fn apply(p: *Process, first: core.Event) Error!Applied {
        var result: Applied = .{};
        var event: ?core.Event = first;
        while (event) |current| {
            event = null;
            var out: core.Output = .{};
            try p.conn.step(current, &out);
            if (trace.on(p.options.trace)) |writer| {
                core.writeTrace(writer, p.options.trace_instance, &out) catch return error.TraceFailed;
            }
            for (out.effects()) |effect| switch (effect) {
                .spawn => |g| {
                    p.spawn_error = null;
                    event = if (p.spawn(g)) |_| .spawned else |err| blk: {
                        p.spawn_error = err;
                        break :blk .spawn_failed;
                    };
                },
                .close_stdin => if (p.stdin) |file| {
                    file.close(p.io);
                    p.stdin = null;
                },
                .signal => |s| p.signal(s.signal),
                .arm_timer => |a| try p.tasks.concurrent(p.io, postAfter, .{ p, .{ .timer = a.timer }, p.delay(a.timer.kind, a.after_ms) }),
                .deliver => result.delivered = true,
                .write => p.write() catch {
                    event = .write_failed;
                },
                .ready => {},
                .lost => {
                    result.lost = true;
                    // The process is gone, so its stdin is too.
                    if (p.stdin) |file| file.close(p.io);
                    p.stdin = null;
                },
            };
        }
        return result;
    }

    fn spawn(p: *Process, generation: core.Generation) SpawnError!void {
        std.debug.assert(p.stdin == null);
        const child = try std.process.spawn(p.io, .{
            .argv = p.options.argv,
            .environ_map = p.options.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            // A new process group, led by the server.
            .pgid = 0,
        });
        const pid = child.id.?;
        p.pid_lock.lockUncancelable(p.io);
        p.pid = pid;
        p.pid_lock.unlock(p.io);
        // Started after `signalAllForExit` went through the list.
        if (everyone.exiting.load(.seq_cst)) p.signal(.term);
        p.stdin = child.stdin;
        errdefer p.stopSpawned(child.stdout.?, child.stderr.?);
        try p.tasks.concurrent(p.io, readLines, .{ p, child.stdout.?, .{ .stdout = generation } });
        try p.tasks.concurrent(p.io, readLines, .{ p, child.stderr.?, .stderr });
        try p.tasks.concurrent(p.io, watch, .{ p, generation, pid });
    }

    /// Undoes a spawn whose tasks couldn't all start.
    fn stopSpawned(p: *Process, stdout: std.Io.File, stderr: std.Io.File) void {
        p.signal(.kill);
        p.pid_lock.lockUncancelable(p.io);
        if (p.pid) |pid| _ = std.c.waitpid(pid, null, 0);
        p.pid = null;
        p.pid_lock.unlock(p.io);
        if (p.stdin) |file| file.close(p.io);
        p.stdin = null;
        stdout.close(p.io);
        stderr.close(p.io);
    }

    fn signal(p: *Process, which: core.Signal) void {
        p.pid_lock.lockUncancelable(p.io);
        defer p.pid_lock.unlock(p.io);
        const pid = p.pid orelse return;
        const sig: std.posix.SIG = switch (which) {
            .term => .TERM,
            .kill => .KILL,
        };
        // The whole group while its leader is unreaped, so the group id
        // can't have been reused. If that fails, at least the server itself.
        std.posix.kill(-pid, sig) catch std.posix.kill(pid, sig) catch {};
    }

    fn write(p: *Process) !void {
        const file = p.stdin orelse return error.NotOpen;
        try file.writeStreamingAll(p.io, p.outgoing);
        try file.writeStreamingAll(p.io, "\n");
    }

    /// Backoff delays get jitter, uniform in [half, full].
    fn delay(p: *Process, kind: core.TimerKind, after_ms: u32) u32 {
        if (kind != .backoff or after_ms < 2) return after_ms;
        var bytes: [4]u8 = undefined;
        p.io.random(&bytes);
        const half = after_ms / 2;
        return half + std.mem.readInt(u32, &bytes, .little) % (after_ms - half + 1);
    }

    /// Posts to the queue, or frees what can't be posted.
    fn post(p: *Process, posted: Posted) std.Io.Cancelable!void {
        p.queue.putOne(p.io, posted) catch |err| {
            posted.free(p.gpa);
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        if (posted != .wake) if (p.options.bell) |b| b.ring();
    }

    const Stream = union(enum) {
        stdout: core.Generation,
        stderr,
    };

    /// Reads lines from the server's stdout or stderr until the stream ends.
    fn readLines(p: *Process, file: std.Io.File, stream: Stream) std.Io.Cancelable!void {
        defer file.close(p.io);
        var buffer: [16 * 1024]u8 = undefined;
        var file_reader = file.reader(p.io, &buffer);
        const reader = &file_reader.interface;
        const limit = if (stream == .stdout) p.options.max_line else p.options.max_stderr_line;
        var line: std.Io.Writer.Allocating = .init(p.gpa);
        defer line.deinit();
        while (true) {
            const got = lines.read(reader, &line, limit) catch return;
            // An over-long stdout line is a connection error, and the
            // server is about to be killed. Logs keep the start of the line.
            var at_end = got.at_end;
            if (got.too_long) switch (stream) {
                .stdout => |g| return p.post(.{ .oversized = g }),
                .stderr => at_end = lines.skipRest(reader) catch return,
            };
            // At the end, a last stdout line without a newline is dropped.
            if (at_end and stream == .stdout) return;
            // Empty lines are skipped.
            const bytes = got.bytes;
            if (bytes.len > 0 and stream == .stderr and p.options.stderr != null) {
                const sink = p.options.stderr.?;
                sink.line(sink.context, bytes);
            } else if (bytes.len > 0) {
                const owned = p.gpa.dupe(u8, bytes) catch return;
                switch (stream) {
                    .stdout => |g| try p.post(.{ .line = .{ .generation = g, .bytes = owned } }),
                    // Stderr is only logged and never blocks on the
                    // queue, so a flood can't stall the server on a full pipe.
                    // Lines that don't fit are counted in `stderr_dropped`.
                    .stderr => if ((p.queue.put(p.io, &.{.{ .stderr = owned }}, 0) catch 0) == 0) {
                        p.gpa.free(owned);
                        _ = p.stderr_dropped.fetchAdd(1, .monotonic);
                    } else if (p.options.bell) |b| b.ring(),
                }
            }
            if (at_end) return;
        }
    }

    fn watch(p: *Process, generation: core.Generation, pid: std.posix.pid_t) std.Io.Cancelable!void {
        while (true) {
            p.pid_lock.lockUncancelable(p.io);
            const result = std.c.waitpid(pid, null, std.c.W.NOHANG);
            // -1 means the pid is no longer ours to wait for; treat it as gone.
            const gone = result == pid or result == -1;
            if (gone) p.pid = null;
            p.pid_lock.unlock(p.io);
            if (gone) return p.post(.{ .exited = generation });
            try p.io.sleep(.fromMilliseconds(p.options.poll_ms), .awake);
        }
    }

    /// Posts `posted` after `after_ms`: a timer for the core, or a wake-up for `next`.
    fn postAfter(p: *Process, posted: Posted, after_ms: u32) std.Io.Cancelable!void {
        try p.io.sleep(.fromMilliseconds(after_ms), .awake);
        try p.post(posted);
    }
};

const testing = std.testing;

const test_config: core.Config = .{ .max_attempts = 2, .grace_ms = 100, .term_ms = 100, .backoff_ms = 20, .backoff_cap_ms = 40 };

fn shell(script: []const u8) [3][]const u8 {
    return .{ "/bin/sh", "-c", script };
}

fn initTest(p: *Process, argv: []const []const u8) void {
    p.init(testing.io, testing.allocator, .{ .argv = argv, .config = test_config, .poll_ms = 5, .max_line = 64 });
}

/// Waits until the connection reaches `state`, skipping other output.
fn expectState(p: *Process, state: core.State) !void {
    for (0..200) |_| switch (try p.next(5_000)) {
        .changed => |c| if (c.state == state) return,
        .timeout => return error.TestTimeout,
        else => {},
    };
    return error.TestUnexpectedResult;
}

test "messages arrive, and a stop that closes stdin ends the server" {
    const argv = shell("printf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\\n'; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqual(core.State.running, p.conn.state);
    const first = try p.next(5_000);
    try testing.expectEqualStrings("notifications/message", first.message.message.notification.method);
    try p.send(.request, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    try p.stop();
    try expectState(&p, .stopped);
    try testing.expect(!p.conn.term_sent and !p.conn.kill_sent);
}

test "a server that ignores closed stdin gets SIGTERM, then SIGKILL if it ignores that too" {
    inline for (.{ .{ "trap 'exit 0' TERM; while :; do sleep 0.02; done", false }, .{ "trap '' TERM; while :; do sleep 0.02; done", true } }) |case| {
        const argv = shell(case[0]);
        var p: Process = undefined;
        initTest(&p, &argv);
        defer p.deinit();
        try p.start();
        try p.stop();
        try expectState(&p, .stopped);
        try testing.expect(p.conn.term_sent);
        try testing.expectEqual(case[1], p.conn.kill_sent);
    }
}

test "signalAllForExit sends SIGTERM to every server at once, even one that starts after it" {
    defer everyone.exiting.store(false, .seq_cst);
    // Only SIGTERM ends it: it never reads stdin.
    const argv = shell("trap 'exit 0' TERM; while :; do sleep 0.02; done");
    var running: Process = undefined;
    initTest(&running, &argv);
    defer running.deinit();
    try running.start();
    const before = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    signalAllForExit(testing.io);
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - before < 500);
    var late: Process = undefined;
    initTest(&late, &argv);
    defer late.deinit();
    try late.start();
    inline for (.{ &running, &late }) |p| {
        try expectState(p, .backoff);
        // The signal came from the exit, not from a stop.
        try testing.expect(!p.conn.term_sent);
    }
}

test "a crashing server backs off, restarts on demand, then fails at the limit" {
    const argv = shell("exit 3");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try expectState(&p, .backoff);
    // The dead process's stdin was closed, so restarts don't leak descriptors.
    try testing.expect(p.stdin == null);
    try expectState(&p, .idle);
    try p.start();
    try expectState(&p, .failed);
    try testing.expectEqual(@as(u8, 2), p.conn.attempts);
}

test "a command that can't start counts as a failure" {
    const argv = [_][]const u8{"/nonexistent/mcpv2-test-server"};
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqual(core.State.backoff, p.conn.state);
    try testing.expect(p.spawn_error != null);
}

test "a spawn that works clears the last spawn error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/server", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const argv = [_][]const u8{path};
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expect(p.spawn_error != null);
    // The command appears, as one npx is still installing would.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = "#!/bin/sh\nexec cat >/dev/null\n", .flags = .{ .permissions = .executable_file } });
    try expectState(&p, .idle);
    try p.start();
    try testing.expectEqual(core.State.running, p.conn.state);
    try testing.expect(p.spawn_error == null);
}

test "lines that aren't MCP messages are dropped, and CRLF and empty lines are handled" {
    const argv = shell("printf 'server starting\\r\\n\\r\\n{\"jsonrpc\":\"2.0\",\"method\":\"m\"}\\r\\n'; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqual(wire.DecodeError.InvalidJson, (try p.next(5_000)).dropped);
    const message = (try p.next(5_000)).message;
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"m\"}", message.bytes);
}

test "an oversized line kills the server" {
    const argv = shell("printf '%0100d\\n' 0; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try expectState(&p, .killing);
    try expectState(&p, .backoff);
    try testing.expect(p.conn.errored and !p.conn.term_sent);
}

test "stderr lines reach the host and never change the state" {
    const argv = shell("echo warming up >&2; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqualStrings("warming up", (try p.next(5_000)).stderr);
    try testing.expectEqual(core.State.running, p.conn.state);
}

test "a stop signals the server's whole process group, so its children stop too" {
    // The shell ignores closed stdin, so the stop escalates to SIGTERM. Its
    // child sleep must die with it.
    const argv = shell("sleep 30 & echo $! >&2; wait");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    const child = try std.fmt.parseInt(std.posix.pid_t, (try p.next(5_000)).stderr, 10);
    defer std.posix.kill(child, .KILL) catch {};
    try p.stop();
    try expectState(&p, .stopped);
    try testing.expect(p.conn.term_sent);
    for (0..100) |_| {
        std.posix.kill(child, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ChildStillRunning;
}

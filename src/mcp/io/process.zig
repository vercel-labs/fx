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
//! server's group SIGTERM from any thread and wait for none of them. A
//! helper process stops what is left once the program is gone (`helper`).

const std = @import("std");
const core = @import("../core/stdio_conn.zig");
const wire = @import("../protocol/wire.zig");
const lines = @import("lines.zig");
const Budget = @import("budget.zig").Budget;
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

/// The helper that stops what is left of the servers once the program is
/// gone, by exit or by crash. It hears
/// each group that starts ("+") and each one that is reaped ("-"). When its
/// stdin closes it sends the groups still listed SIGTERM, then SIGKILL 2 s
/// later, so the program's exit waits for nothing. A group that ends in those
/// 2 s frees its id, and the SIGKILL would reach a group given that id since;
/// on Linux and macOS a freed process id comes back only after the others
/// have been handed out, so that would take the system starting a process
/// for every other id within those 2 s.
const helper = struct {
    /// A leaf lock: taken under `pid_lock`, and nothing is taken under it.
    var mutex: std.Io.Mutex = .init;
    var started = false;
    /// Its stdin; null when it never started or can't be told.
    var stdin: ?std.posix.fd_t = null;
    var pid: std.posix.pid_t = 0;

    const script =
        \\trap '' INT HUP
        \\g=
        \\while read -r m; do
        \\  case $m in
        \\    +*) g="$g ${m#+}" ;;
        \\    -*) k=; for x in $g; do [ "$x" = "${m#-}" ] || k="$k $x"; done; g=$k ;;
        \\  esac
        \\done
        \\[ -n "$g" ] || exit 0
        \\for x in $g; do kill -s TERM -- "-$x"; done
        \\sleep 2
        \\for x in $g; do kill -s KILL -- "-$x"; done
    ;

    /// Starts it, once, before the first server.
    fn start(io: std.Io) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (started) return;
        started = true;
        const child = std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", script },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
            // Its own group, so the terminal's Ctrl-C doesn't reach it.
            .pgid = 0,
        }) catch return;
        const fd = child.stdin.?.handle;
        // A write never waits on it.
        _ = std.posix.system.fcntl(fd, std.posix.F.SETFL, @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        stdin = fd;
        pid = child.id.?;
    }

    /// Tells it a group started (`sign` '+') or was reaped ('-'). One that
    /// can't be told is stopped, so it never acts on a list out of date.
    fn tell(io: std.Io, sign: u8, group: std.posix.pid_t) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const fd = stdin orelse return;
        var buffer: [16]u8 = undefined;
        const line = std.mem.print(&buffer, "{c}{d}\n", .{ sign, group }) catch return;
        if (std.c.write(fd, line.ptr, line.len) == line.len) return;
        std.posix.kill(pid, .KILL) catch {};
        stdin = null;
    }
};

pub const Options = struct {
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map = null,
    /// The directory the server starts in, borrowed; the host's own when null.
    cwd: ?[]const u8 = null,
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
    /// A stdout line that isn't a valid MCP message was dropped. `line` is
    /// empty for one from an earlier process.
    dropped: struct { err: wire.DecodeError, line: []const u8 },
    /// The connection changed state. `lost` means the process is gone and
    /// requests in flight on it are lost (`transport_lost` in `core/request.zig`).
    /// `oversized` says fx killed it for a stdout line over `max_line`.
    changed: struct { state: core.State, lost: bool, oversized: bool = false },
    /// `next` was given a timeout and it passed first.
    timeout,
};

pub const SpawnError = std.process.SpawnError || std.Io.ConcurrentError;

/// How a process ended: its exit code, or the signal that ended it.
pub const Exit = union(enum) { code: u8, signal: u8 };

/// The start of `text` in `out`: as much as fits without cutting a UTF-8
/// sequence, with each control byte as '?', so a server's text is safe to
/// show. Shorter than `text` when it was cut.
pub fn maskedPrefix(out: []u8, text: []const u8) []const u8 {
    var n: usize = @min(text.len, out.len);
    if (n < text.len) {
        while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    }
    for (text[0..n], out[0..n]) |c, *e| e.* = if (c < 0x20 or c == 0x7f) '?' else c;
    return out[0..n];
}

test "a masked prefix keeps whole UTF-8 sequences and shows control bytes as '?'" {
    var out: [6]u8 = undefined;
    try std.testing.expectEqualStrings("a?b?", maskedPrefix(&out, "a\x1bb\x7f"));
    // "\xc3\xa9" is one character: cut at 6 it would split, so it stops before it.
    try std.testing.expectEqualStrings("abcde", maskedPrefix(&out, "abcde\xc3\xa9"));
    try std.testing.expectEqualStrings("abcd\xc3\xa9", maskedPrefix(&out, "abcd\xc3\xa9z"));
    try std.testing.expectEqualStrings("", maskedPrefix(&out, ""));
}

/// Bytes of the stderr tail a failure quotes: its last `tail_lines` lines.
pub const tail_max = 240;
const tail_lines = 3;

/// How long the exit watcher waits, once a process is gone, for its stderr
/// reader to reach the end of the pipe. A child that keeps the pipe open
/// delays the exit by this much and no more.
const stderr_drain_ms = 250;

fn exitOf(status: u32) ?Exit {
    if (std.c.W.IFEXITED(status)) return .{ .code = std.c.W.EXITSTATUS(status) };
    if (std.c.W.IFSIGNALED(status)) return .{ .signal = @truncate(@backingInt(std.c.W.TERMSIG(status))) };
    return null;
}

pub const Error = core.StepError || std.Io.Cancelable || std.Io.ConcurrentError || std.mem.Allocator.Error || error{TraceFailed};

const Posted = union(enum) {
    line: struct { generation: core.Generation, bytes: []u8 },
    oversized: core.Generation,
    stderr: []u8,
    exited: core.Generation,
    timer: core.Timer,
    /// A write to that process's stdin failed.
    write_failed: core.Generation,

    fn free(posted: Posted, gpa: std.mem.Allocator) void {
        switch (posted) {
            .line => |l| gpa.free(l.bytes),
            .stderr => |s| gpa.free(s),
            else => {},
        }
    }
};

/// One process's stdin, written in order by its own task, so a server that
/// stops reading blocks only that task, never the host. The process
/// and the task each hold a reference; the last to let go closes the file
/// and frees this.
const Stdin = struct {
    file: std.Io.File,
    generation: core.Generation,
    queue: std.Io.Queue([]u8),
    /// Above the request table's 64 slots and their cancels, so only the
    /// byte cap can refuse a send.
    buffer: [256][]u8 = undefined,
    /// Bytes queued and not yet written.
    queued: std.atomic.Value(usize) = .init(0),
    refs: std.atomic.Value(u8) = .init(2),

    fn unref(s: *Stdin, p: *Process) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        var rest: [16][]u8 = undefined;
        while (true) {
            const n = s.queue.getUncancelable(p.io, &rest, 0) catch break;
            if (n == 0) break;
            for (rest[0..n]) |line| p.gpa.free(line);
        }
        s.file.close(p.io);
        p.gpa.destroy(s);
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
    /// Guards `pid` and `exit`, which the exit watcher writes when it reaps
    /// the process.
    pid_lock: std.Io.Mutex = .init,
    /// Set while the current process is unreaped.
    pid: ?std.posix.pid_t = null,
    stdin: ?*Stdin = null,
    /// The bytes behind the last `message` or `stderr` returned by `next`.
    held: ?[]u8 = null,
    /// The message `send` is writing, while its step runs.
    outgoing: []const u8 = "",
    /// Rung after each post, as is the shared `bell` if any. `next` waits on
    /// this one, so a timed wait starts no task and never takes a ring meant
    /// for another server.
    own: Bell = undefined,
    /// stderr lines dropped because the queue was full.
    stderr_dropped: std.atomic.Value(u32) = .init(0),
    /// Bytes of stdout lines posted and not yet taken: at most one longest
    /// line, so a fast server waits instead of growing fx.
    budget: Budget,
    /// Why the last start failed, for logs.
    spawn_error: ?SpawnError = null,
    /// The current process is being killed because it wrote a stdout line
    /// over `max_line`: the loss its exit reports is said to be that.
    killed_oversized: bool = false,
    /// How the last process ended, once it has: set under `pid_lock` before
    /// `.exited` is posted. A status can be read before the owner takes that
    /// event, so read it with `exitStatus`.
    exit: ?Exit = null,
    /// The current process's last stderr lines, terminal-safe, each cut to
    /// `tail_max`: written by its stderr reader under `tail_lock`, cleared at
    /// each spawn.
    tail_lock: std.Io.Mutex = .init,
    tail: [tail_lines][tail_max]u8 = undefined,
    tail_len: [tail_lines]u8 = @splat(0),
    tail_next: u8 = 0,
    tail_count: u8 = 0,
    /// The latest generation whose stderr reader has handled every line and
    /// reached the end of its pipe.
    stderr_done: std.atomic.Value(core.Generation) = .init(0),
    /// This process in `everyone.list`.
    node: std.DoublyLinkedList.Node = .{},

    /// `options` (and the slices it holds) must outlive the process.
    pub fn init(p: *Process, io: std.Io, gpa: std.mem.Allocator, options: Options) void {
        p.* = .{ .io = io, .gpa = gpa, .options = options, .conn = .init(options.config), .queue = undefined, .budget = .{ .max = options.max_line } };
        p.own.init(io);
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
            // The whole group, as `signal` does.
            std.posix.kill(-pid, .KILL) catch std.posix.kill(pid, .KILL) catch {};
            _ = std.c.waitpid(pid, null, 0);
            helper.tell(p.io, '-', pid);
            p.pid = null;
        }
        p.pid_lock.unlock(p.io);
        p.closeStdin();
        p.tasks.cancel(p.io);
        p.queue.close(p.io);
        var rest: [16]Posted = undefined;
        while (true) {
            const n = p.queue.getUncancelable(p.io, &rest, 0) catch break;
            if (n == 0) break;
            for (rest[0..n]) |posted| posted.free(p.gpa);
        }
        p.release();
        p.budget.deinit(p.gpa);
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
        const deadline = if (timeout_ms) |ms| std.Io.Clock.awake.now(p.io).toMilliseconds() + ms else null;
        while (true) {
            if (try p.poll()) |incoming| return incoming;
            const left: ?u32 = if (deadline) |d| @intCast(@max(0, d - std.Io.Clock.awake.now(p.io).toMilliseconds())) else null;
            if (left == 0) return .timeout;
            try p.own.wait(left);
        }
    }

    /// What is already queued, without waiting; null when nothing is.
    pub fn poll(p: *Process) Error!?Incoming {
        p.release();
        var one: [1]Posted = undefined;
        while ((p.queue.get(p.io, &one, 0) catch 0) == 1) {
            switch (one[0]) {
                .line => |l| p.budget.give(p.io, l.bytes.len),
                else => {},
            }
            if (try p.take(one[0])) |incoming| return incoming;
        }
        return null;
    }

    /// What a posted item means to the host; null for one to skip.
    fn take(p: *Process, posted: Posted) Error!?Incoming {
        const before = p.conn.state;
        const lost = switch (posted) {
            .line => |line| {
                const message = wire.decode(line.bytes) catch |err| {
                    if (line.generation != p.conn.generation) {
                        p.gpa.free(line.bytes);
                        return .{ .dropped = .{ .err = err, .line = "" } };
                    }
                    p.held = line.bytes;
                    return .{ .dropped = .{ .err = err, .line = line.bytes } };
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
            .oversized => |g| blk: {
                const applied = try p.apply(.{ .oversized_line = g });
                if (before == .running and p.conn.state == .killing) p.killed_oversized = true;
                break :blk applied.lost;
            },
            .exited => |g| (try p.apply(.{ .process_exited = g })).lost,
            .timer => |t| (try p.apply(.{ .timer_fired = t })).lost,
            // One from an earlier process is stale.
            .write_failed => |g| if (g == p.conn.generation) (try p.apply(.write_failed)).lost else false,
        };
        const oversized = lost and p.killed_oversized;
        if (lost) p.killed_oversized = false;
        if (lost or p.conn.state != before) return .{ .changed = .{ .state = p.conn.state, .lost = lost, .oversized = oversized } };
        return null;
    }

    fn release(p: *Process) void {
        if (p.held) |bytes| p.budget.recycle(p.io, p.gpa, bytes);
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
                    p.killed_oversized = false;
                    p.pid_lock.lockUncancelable(p.io);
                    p.exit = null;
                    p.pid_lock.unlock(p.io);
                    p.tail_lock.lockUncancelable(p.io);
                    p.tail_count = 0;
                    p.tail_lock.unlock(p.io);
                    event = if (p.spawn(g)) |_| .spawned else |err| blk: {
                        p.spawn_error = err;
                        break :blk .spawn_failed;
                    };
                },
                .close_stdin => p.closeStdin(),
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
                    p.closeStdin();
                },
            };
        }
        return result;
    }

    fn spawn(p: *Process, generation: core.Generation) SpawnError!void {
        std.debug.assert(p.stdin == null);
        helper.start(p.io);
        const stdin = try p.gpa.create(Stdin);
        const child = std.process.spawn(p.io, .{
            .argv = p.options.argv,
            .environ_map = p.options.environ_map,
            .cwd = if (p.options.cwd) |dir| .{ .path = dir } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            // A new process group, led by the server.
            .pgid = 0,
        }) catch |err| {
            p.gpa.destroy(stdin);
            return err;
        };
        const pid = child.id.?;
        p.pid_lock.lockUncancelable(p.io);
        p.pid = pid;
        p.pid_lock.unlock(p.io);
        // Before the exit watcher, which reaps it, starts.
        helper.tell(p.io, '+', pid);
        // Started after `signalAllForExit` went through the list.
        if (everyone.exiting.load(.seq_cst)) p.signal(.term);
        stdin.* = .{ .file = child.stdin.?, .generation = generation, .queue = undefined };
        stdin.queue = .init(&stdin.buffer);
        p.tasks.concurrent(p.io, writeLines, .{ p, stdin }) catch |err| {
            stdin.file.close(p.io);
            p.gpa.destroy(stdin);
            p.stopSpawned(child.stdout.?, child.stderr.?);
            return err;
        };
        p.stdin = stdin;
        // A reader that started closes its pipe; only the others are closed
        // here.
        var unread: [2]?std.Io.File = .{ child.stdout.?, child.stderr.? };
        errdefer p.stopSpawned(unread[0], unread[1]);
        try p.tasks.concurrent(p.io, readLines, .{ p, child.stdout.?, .{ .stdout = generation } });
        unread[0] = null;
        try p.tasks.concurrent(p.io, readLines, .{ p, child.stderr.?, .{ .stderr = generation } });
        unread[1] = null;
        try p.tasks.concurrent(p.io, watch, .{ p, generation, pid });
    }

    /// Undoes a spawn whose tasks couldn't all start, closing the pipes no
    /// reader took.
    fn stopSpawned(p: *Process, stdout: ?std.Io.File, stderr: ?std.Io.File) void {
        p.signal(.kill);
        p.pid_lock.lockUncancelable(p.io);
        if (p.pid) |pid| {
            _ = std.c.waitpid(pid, null, 0);
            helper.tell(p.io, '-', pid);
        }
        p.pid = null;
        p.pid_lock.unlock(p.io);
        p.closeStdin();
        if (stdout) |f| f.close(p.io);
        if (stderr) |f| f.close(p.io);
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

    /// Queues the outgoing message for stdin's writer. A server that stops
    /// reading fills the queue: once what waits passes the line limit, it is
    /// broken. A lone message of any size still goes out.
    fn write(p: *Process) !void {
        const s = p.stdin orelse return error.NotOpen;
        const size = p.outgoing.len + 1;
        const waiting = s.queued.fetchAdd(size, .monotonic);
        if (waiting != 0 and waiting + size > p.options.max_line) {
            _ = s.queued.fetchSub(size, .monotonic);
            return error.Full;
        }
        errdefer _ = s.queued.fetchSub(size, .monotonic);
        const line = try p.gpa.alloc(u8, size);
        errdefer p.gpa.free(line);
        @memcpy(line[0..p.outgoing.len], p.outgoing);
        line[p.outgoing.len] = '\n';
        if (try s.queue.put(p.io, &.{line}, 0) == 0) return error.Full;
    }

    /// Writes `s`'s lines in order until its queue is closed and empty. A
    /// failed write is posted for its process, and the rest is dropped.
    fn writeLines(p: *Process, s: *Stdin) std.Io.Cancelable!void {
        defer s.unref(p);
        while (true) {
            const line = s.queue.getOne(p.io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };
            defer p.gpa.free(line);
            _ = s.queued.fetchSub(line.len, .monotonic);
            s.file.writeStreamingAll(p.io, line) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return p.post(.{ .write_failed = s.generation }),
            };
        }
    }

    /// Closes stdin after what is already queued; the writer then closes
    /// the file.
    fn closeStdin(p: *Process) void {
        const s = p.stdin orelse return;
        p.stdin = null;
        s.queue.close(p.io);
        s.unref(p);
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
            switch (posted) {
                .line => |l| p.budget.give(p.io, l.bytes.len),
                else => {},
            }
            posted.free(p.gpa);
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        p.ring();
    }

    const Stream = union(enum) {
        stdout: core.Generation,
        stderr: core.Generation,
    };

    /// Reads lines from the server's stdout or stderr until the stream ends.
    fn readLines(p: *Process, file: std.Io.File, stream: Stream) std.Io.Cancelable!void {
        defer file.close(p.io);
        // The exit watcher waits for this before it posts the exit.
        defer if (stream == .stderr) {
            _ = p.stderr_done.fetchMax(stream.stderr, .release);
        };
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
            if (bytes.len > 0 and stream == .stderr) p.keepTail(bytes);
            if (bytes.len > 0 and stream == .stderr and p.options.stderr != null) {
                const sink = p.options.stderr.?;
                sink.line(sink.context, bytes);
            } else if (bytes.len > 0) {
                // A stdout line waits for room before it is copied.
                const owned = switch (stream) {
                    .stdout => try p.budget.copy(p.io, p.gpa, bytes),
                    .stderr => p.gpa.dupe(u8, bytes) catch null,
                } orelse return;
                switch (stream) {
                    .stdout => |g| try p.post(.{ .line = .{ .generation = g, .bytes = owned } }),
                    // Stderr is only logged and never blocks on the
                    // queue, so a flood can't stall the server on a full pipe.
                    // Lines that don't fit are counted in `stderr_dropped`.
                    .stderr => if ((p.queue.put(p.io, &.{.{ .stderr = owned }}, 0) catch 0) == 0) {
                        p.gpa.free(owned);
                        _ = p.stderr_dropped.fetchAdd(1, .monotonic);
                    } else p.ring(),
                }
            }
            if (at_end) return;
        }
    }

    fn watch(p: *Process, generation: core.Generation, pid: std.posix.pid_t) std.Io.Cancelable!void {
        while (true) {
            p.pid_lock.lockUncancelable(p.io);
            var status: c_int = 0;
            const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            // -1 means the pid is no longer ours to wait for; treat it as gone.
            const gone = result == pid or result == -1;
            if (result == pid) p.exit = exitOf(@bitCast(status));
            if (gone) {
                // Told while its id can't yet come round.
                helper.tell(p.io, '-', pid);
                p.pid = null;
            }
            p.pid_lock.unlock(p.io);
            if (gone) {
                try p.awaitStderr(generation);
                return p.post(.{ .exited = generation });
            }
            try p.io.sleep(.fromMilliseconds(p.options.poll_ms), .awake);
        }
    }

    /// Waits up to `stderr_drain_ms` for `generation`'s stderr reader to
    /// finish. A server that exits at once can be reaped before that reader
    /// runs, and its last lines, which explain the exit, would miss the log
    /// sink, the tail a failure quotes, and the queue ahead of the exit.
    fn awaitStderr(p: *Process, generation: core.Generation) std.Io.Cancelable!void {
        const deadline = std.Io.Clock.awake.now(p.io).toMilliseconds() + stderr_drain_ms;
        while (p.stderr_done.load(.acquire) < generation and
            std.Io.Clock.awake.now(p.io).toMilliseconds() < deadline)
        {
            try p.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn keepTail(p: *Process, line: []const u8) void {
        p.tail_lock.lockUncancelable(p.io);
        defer p.tail_lock.unlock(p.io);
        const slot = p.tail_next;
        p.tail_len[slot] = @intCast(maskedPrefix(&p.tail[slot], std.mem.trimEnd(u8, line, " \t\r")).len);
        p.tail_next = (slot + 1) % tail_lines;
        p.tail_count = @min(p.tail_count + 1, tail_lines);
    }

    /// How the last process ended, once it has.
    pub fn exitStatus(p: *Process) ?Exit {
        p.pid_lock.lockUncancelable(p.io);
        defer p.pid_lock.unlock(p.io);
        return p.exit;
    }

    /// The current process's last stderr lines, oldest first, joined with
    /// " / ", and cut from the front to `tail_max`; in `out`.
    pub fn stderrTail(p: *Process, out: *[tail_max]u8) []const u8 {
        var all: [tail_lines * (tail_max + 3)]u8 = undefined;
        var w: std.Io.Writer = .fixed(&all);
        p.tail_lock.lockUncancelable(p.io);
        var k: u8 = 0;
        while (k < p.tail_count) : (k += 1) {
            const slot = (p.tail_next + tail_lines - p.tail_count + k) % tail_lines;
            if (k > 0) w.writeAll(" / ") catch unreachable;
            w.writeAll(p.tail[slot][0..p.tail_len[slot]]) catch unreachable;
        }
        p.tail_lock.unlock(p.io);
        var text = w.buffered();
        if (text.len > tail_max) {
            text = text[text.len - tail_max ..];
            while (text.len > 0 and (text[0] & 0xC0) == 0x80) text = text[1..];
        }
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }

    fn ring(p: *Process) void {
        p.own.ring();
        if (p.options.bell) |b| b.ring();
    }

    /// Posts `posted` after `after_ms`: a timer for the core.
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

test "lines past the budget all arrive, each once the one before it is taken" {
    // Six lines of 46 bytes against a 64-byte budget: each waits for room.
    const argv = shell("for i in 1 2 3 4 5 6; do printf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/n%s\"}\\n' $i; done; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    var got: usize = 0;
    while (got < 6) switch (try p.next(5_000)) {
        .message => got += 1,
        .timeout => return error.TestTimeout,
        else => {},
    };
    try testing.expect(p.budget.used <= 64);
    try p.stop();
    try expectState(&p, .stopped);
}

test "a server starts in the directory it's given" {
    // The server names its directory as a notification's method.
    const argv = shell("printf '{\"jsonrpc\":\"2.0\",\"method\":\"%s\"}\\n' \"$(pwd -P)\"; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    p.options.cwd = "/";
    try p.start();
    const first = try p.next(5_000);
    try testing.expectEqualStrings("/", first.message.message.notification.method);
    try p.stop();
    try expectState(&p, .stopped);
}

test "a server that ignores closed stdin gets SIGTERM, then SIGKILL if it ignores that too" {
    // The shell runs its TERM trap only once its `sleep` returns, so the one
    // that exits on SIGTERM gets a long window: a slow machine still sees it
    // exit before SIGKILL. The one that ignores SIGTERM keeps the short one.
    inline for (.{ .{ "trap 'exit 0' TERM; while :; do sleep 0.02; done", false, 5_000 }, .{ "trap '' TERM; while :; do sleep 0.02; done", true, test_config.term_ms } }) |case| {
        const argv = shell(case[0]);
        var config = test_config;
        config.term_ms = case[2];
        var p: Process = undefined;
        p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = config, .poll_ms = 5, .max_line = 64 });
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

test "how a server's process ended is kept until it starts again" {
    const argv = shell("exit 3");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try expectState(&p, .backoff);
    try testing.expectEqual(Exit{ .code = 3 }, p.exitStatus().?);
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
    const path = try testing.allocator.print(".zig-cache/tmp/{s}/server", .{tmp.sub_path});
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
    try testing.expectEqual(wire.DecodeError.InvalidJson, (try p.next(5_000)).dropped.err);
    const message = (try p.next(5_000)).message;
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"m\"}", message.bytes);
}

test "a send to a server that stops reading returns at once; only stdin's writer waits" {
    // It never reads stdin, so the pipe fills long before 1 MiB.
    const argv = shell("exec sleep 30");
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = test_config, .poll_ms = 5 });
    defer p.deinit();
    try p.start();
    try testing.expectEqual(core.State.running, p.conn.state);
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try p.send(.notification, big);
    try p.send(.notification, "{}");
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 2_000);
    try testing.expectEqual(core.State.running, p.conn.state);
}

test "a server that stops reading is a broken connection once what waits passes the line limit" {
    const argv = shell("exec sleep 30");
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = test_config, .poll_ms = 5, .max_line = 4096 });
    defer p.deinit();
    try p.start();
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    // A lone message of any size goes out; it fills the pipe.
    try p.send(.notification, big);
    try testing.expectEqual(core.State.running, p.conn.state);
    for (0..4) |_| if (p.conn.state == .running) try p.send(.notification, big[0..3000]);
    try testing.expectEqual(core.State.killing, p.conn.state);
    try expectState(&p, .backoff);
}

test "a server that closes its stdin is a broken connection once a write fails" {
    const argv = shell("exec 0<&-; sleep 30");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    // Writes before the shell closes stdin still land in the pipe.
    for (0..250) |_| {
        try p.send(.notification, "{}");
        switch (try p.next(20)) {
            .changed => |c| if (c.state == .killing) return,
            else => {},
        }
    }
    return error.TestTimeout;
}

test "a write failure from an earlier process is ignored" {
    const argv = shell("exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try p.post(.{ .write_failed = p.conn.generation -% 1 });
    try testing.expect(try p.next(50) == .timeout);
    try testing.expectEqual(core.State.running, p.conn.state);
    try p.post(.{ .write_failed = p.conn.generation });
    try expectState(&p, .killing);
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

test "the loss from killing a server for an oversized line says so, and an ordinary exit's doesn't" {
    const big = shell("printf '%0100d\\n' 0; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &big);
    defer p.deinit();
    try p.start();
    const lost = for (0..200) |_| switch (try p.next(5_000)) {
        .changed => |c| if (c.lost) break c,
        .timeout => return error.TestTimeout,
        else => {},
    } else return error.TestUnexpectedResult;
    try testing.expect(lost.oversized);
    try testing.expect(!p.killed_oversized);

    const quits = shell("exit 3");
    var q: Process = undefined;
    initTest(&q, &quits);
    defer q.deinit();
    try q.start();
    const gone = for (0..200) |_| switch (try q.next(5_000)) {
        .changed => |c| if (c.lost) break c,
        .timeout => return error.TestTimeout,
        else => {},
    } else return error.TestUnexpectedResult;
    try testing.expect(!gone.oversized);
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

/// A log sink that takes its time, as a reader whose thread runs only after
/// a server that exits at once is already gone.
const SlowSink = struct {
    mutex: std.Io.Mutex = .init,
    seen: [64]u8 = undefined,
    len: usize = 0,

    fn line(context: *anyopaque, bytes: []const u8) void {
        const s: *SlowSink = @ptrCast(@alignCast(context));
        testing.io.sleep(.fromMilliseconds(40), .awake) catch {};
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        s.len = @min(bytes.len, s.seen.len);
        @memcpy(s.seen[0..s.len], bytes[0..s.len]);
    }

    fn text(s: *SlowSink) []const u8 {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        return s.seen[0..s.len];
    }
};

test "a server's last stderr lines reach the sink and the tail before its exit does" {
    const argv = shell("echo trace-me >&2; exit 3");
    var sink: SlowSink = .{};
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{
        .argv = &argv,
        .config = test_config,
        .poll_ms = 5,
        .max_line = 64,
        .stderr = .{ .context = &sink, .line = SlowSink.line },
    });
    defer p.deinit();
    try p.start();
    try expectState(&p, .backoff);
    try testing.expectEqualStrings("trace-me", sink.text());
    var tail: [tail_max]u8 = undefined;
    try testing.expectEqualStrings("trace-me", p.stderrTail(&tail));
}

test "a child that keeps stderr open delays a server's exit by at most stderr_drain_ms" {
    // The background sleep inherits stderr, so the pipe outlives the server.
    const argv = shell("sleep 30 & echo $! >&2; exit 3");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    const child = try std.fmt.parseInt(std.posix.pid_t, (try p.next(5_000)).stderr, 10);
    defer std.posix.kill(child, .KILL) catch {};
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try expectState(&p, .backoff);
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 2_000);
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
        std.posix.kill(child, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ChildStillRunning;
}

test "the helper hears each server group that starts and each one that is reaped, in order" {
    // The test reads in place of the helper.
    helper.start(testing.io);
    const ends = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (ends) |fd| {
        _ = std.c.close(fd);
    };
    helper.mutex.lockUncancelable(testing.io);
    const real = helper.stdin;
    helper.stdin = ends[1];
    helper.mutex.unlock(testing.io);
    defer {
        helper.mutex.lockUncancelable(testing.io);
        helper.stdin = real;
        helper.mutex.unlock(testing.io);
    }
    const argv = shell("exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    p.pid_lock.lockUncancelable(testing.io);
    const pid = p.pid.?;
    p.pid_lock.unlock(testing.io);
    try p.stop();
    try expectState(&p, .stopped);
    var heard: [64]u8 = undefined;
    const n = std.c.read(ends[0], &heard, heard.len);
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&want, "+{d}\n-{d}\n", .{ pid, pid }), heard[0..@intCast(n)]);
}

test "once the program is gone, the helper kills a server that ignores SIGTERM and closed stdin, after 2 s" {
    // It ignores both, and so does its sleep.
    const argv = shell("trap '' TERM; echo ready >&2; exec 0</dev/null; while :; do sleep 1; done");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    // Once its trap is set.
    try testing.expectEqualStrings("ready", (try p.next(5_000)).stderr);
    // What the system does as the program exits: the helper's stdin closes.
    helper.mutex.lockUncancelable(testing.io);
    const fd = helper.stdin;
    if (fd) |f| _ = std.c.close(f);
    helper.stdin = null;
    helper.mutex.unlock(testing.io);
    if (fd == null) return error.NoHelper;
    const closed = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    while (true) switch (try p.next(10_000)) {
        .changed => |c| if (c.state != .running) break,
        .timeout => return error.TestTimeout,
        else => {},
    };
    const waited = std.Io.Clock.awake.now(testing.io).toMilliseconds() - closed;
    try testing.expect(waited >= 1_900 and waited < 6_000);
}

test "deinit kills the server's whole process group, so its children stop too" {
    const argv = shell("sleep 30 & echo $! >&2; wait");
    var p: Process = undefined;
    initTest(&p, &argv);
    try p.start();
    const child = try std.fmt.parseInt(std.posix.pid_t, (try p.next(5_000)).stderr, 10);
    defer std.posix.kill(child, .KILL) catch {};
    p.deinit();
    for (0..100) |_| {
        std.posix.kill(child, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ChildStillRunning;
}

/// A process group of a shell that ignores SIGTERM, ready once returned.
fn stubbornGroup() !std.process.Child {
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; echo ready >&2; while :; do sleep 1; done" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
        .pgid = 0,
    });
    var buffer: [16]u8 = undefined;
    var reader = child.stderr.?.reader(testing.io, &buffer);
    _ = try reader.interface.takeDelimiterInclusive('\n');
    return child;
}

/// Whether child `pid` has ended within `ms`, reaping it if so.
fn endsWithin(pid: std.posix.pid_t, ms: u32) bool {
    for (0..ms / 10) |_| {
        if (std.c.waitpid(pid, null, std.c.W.NOHANG) == pid) return true;
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "the helper kills the groups it still lists 2 s after its stdin closes, and none it was told are gone" {
    var listed = try stubbornGroup();
    defer listed.stderr.?.close(testing.io);
    var gone = try stubbornGroup();
    defer gone.stderr.?.close(testing.io);
    defer if (!endsWithin(gone.id.?, 10)) {
        std.posix.kill(-gone.id.?, .KILL) catch {};
        _ = std.c.waitpid(gone.id.?, null, 0);
    };
    defer if (!endsWithin(listed.id.?, 10)) {
        std.posix.kill(-listed.id.?, .KILL) catch {};
        _ = std.c.waitpid(listed.id.?, null, 0);
    };
    var reaper = try std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sh", "-c", helper.script }, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    var said: [64]u8 = undefined;
    const told = try std.mem.print(&said, "+{d}\n+{d}\n-{d}\n", .{ listed.id.?, gone.id.?, gone.id.? });
    try testing.expectEqual(@as(isize, @intCast(told.len)), std.c.write(reaper.stdin.?.handle, told.ptr, told.len));
    reaper.stdin.?.close(testing.io);
    const closed = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try testing.expect(endsWithin(reaper.id.?, 6_000));
    const waited = std.Io.Clock.awake.now(testing.io).toMilliseconds() - closed;
    try testing.expect(waited >= 1_900);
    try testing.expect(endsWithin(listed.id.?, 1_000));
    try testing.expect(!endsWithin(gone.id.?, 100));
}

/// How many descriptors are open in this process.
fn openDescriptors() usize {
    var n: usize = 0;
    for (0..1024) |fd| {
        if (std.posix.system.fcntl(@intCast(fd), std.posix.F.GETFD, @as(usize, 0)) != -1) n += 1;
    }
    return n;
}

test "a start whose tasks can't all run closes each of the server's pipes once" {
    helper.start(testing.io);
    // One, two, then three tasks run: the stdout reader, then the stderr
    // reader, then the exit watcher can't start.
    for ([_]usize{ 1, 2, 3 }) |limit| {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(limit) });
        defer threaded.deinit();
        const before = openDescriptors();
        const argv = shell("exec cat >/dev/null");
        var p: Process = undefined;
        p.init(threaded.io(), testing.allocator, .{ .argv = &argv, .config = test_config, .poll_ms = 5, .max_line = 64 });
        // The backoff timer after the failed spawn can't run either.
        p.start() catch |err| try testing.expectEqual(error.ConcurrencyUnavailable, err);
        try testing.expectEqual(@as(?SpawnError, error.ConcurrencyUnavailable), p.spawn_error);
        p.deinit();
        // A pipe closed twice would have hit unreachable; one never closed leaks.
        try testing.expectEqual(before, openDescriptors());
    }
}

test "what a process says wakes a timed wait at once" {
    // One server writes only a message, the other only a stderr line, so
    // neither can wake the other's wait. Each ends a long wait well before
    // its timeout.
    const scripts = [_][]const u8{
        "printf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\\n'; exec cat >/dev/null",
        "echo warming up >&2; exec cat >/dev/null",
    };
    for (scripts, 0..) |script, i| {
        const argv = shell(script);
        var p: Process = undefined;
        initTest(&p, &argv);
        defer p.deinit();
        try p.start();
        const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
        const incoming = try p.next(10_000);
        if (i == 0)
            try testing.expectEqualStrings("notifications/message", incoming.message.message.notification.method)
        else
            try testing.expectEqualStrings("warming up", incoming.stderr);
        try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 3_000);
    }
}

test "a timed wait starts no task, so it works where none can run" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var p: Process = undefined;
    p.init(threaded.io(), testing.allocator, .{ .argv = &.{"/bin/true"}, .config = test_config });
    defer p.deinit();
    try testing.expect((try p.next(20)) == .timeout);
}

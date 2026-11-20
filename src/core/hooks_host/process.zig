//! Runs one hook process for the hooks engine: a real process with a bounded
//! read loop, a deadline, and a kill that reaches everything it started.

const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("../../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const live_groups = @import("live_groups.zig");

/// Why the read loop stopped before both streams ended.
const Stop = enum { none, cancelled, timed_out, too_much_output };

/// How much input fx writes in the calling task when it cannot start one.
const inline_stdin_bytes = 16 * 1024;

/// How long the read loop waits for data before it looks at the deadline and the cancel flag.
const poll_ms = 50;
/// Room the reader keeps free for each read of hook output, in bytes.
const read_room_bytes = 256;

/// Runs one hook process to its end: writes `request.stdin`, reads stdout and
/// stderr up to their limits, and stops the whole process group on timeout,
/// cancel, or too much output. Buffers in the result are allocated with `alloc`.
/// `base_env` is the environment the hook starts from; null means fx's own.
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_env: ?*const std.process.Environ.Map,
    request: hooks.host.ProcessRequest,
) std.mem.Allocator.Error!hooks.host.ProcessResult {
    if (builtin.target.os.tag == .wasi or builtin.single_threaded) {
        return .{ .spawn_failed = try alloc.dupe(u8, "this fx build cannot run hook processes") };
    }
    if (request.cancel) |flag| {
        if (flag.load(.acquire)) return .cancelled;
    }

    // A hook that would be past the registry's size does not start. The check is only a hint: `add` decides below.
    if (!live_groups.hasRoom()) return refuseFull(alloc, request.argv);

    var env = if (base_env) |map|
        try map.clone(alloc)
    else
        io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .spawn_failed = try alloc.dupe(u8, "fx could not read its environment") },
        };
    defer env.deinit();
    try env.put("AI_AGENT", "fx");
    for (request.env) |entry| try env.put(entry.name, entry.value);

    var child = std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = .{ .path = request.cwd },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        return .{ .spawn_failed = try alloc.print("{s}: {s}", .{ request.argv[0], @errorName(err) }) };
    };
    const pid = child.id.?;
    // The group is registered at once, so a signal handler can stop it. A group that cannot be
    // registered is stopped here, because fx does not run a hook it cannot stop.
    const slot = live_groups.add(pid) catch {
        stopGroup(pid, request.argv[0], "refused: too many live groups");
        closeChildPipes(io, &child);
        var refused_tasks: std.Io.Group = .init;
        _ = reap(io, &child, &refused_tasks);
        return refuseFull(alloc, request.argv);
    };

    const stdin_file = child.stdin.?;
    child.stdin = null;
    var tasks: std.Io.Group = .init;
    tasks.concurrent(io, writeInput, .{ io, stdin_file, request.stdin }) catch |err| {
        if (request.stdin.len <= inline_stdin_bytes) {
            writeInput(io, stdin_file, request.stdin);
        } else {
            stdin_file.close(io);
            stopGroup(pid, request.argv[0], "no task to write its input");
            live_groups.remove(slot);
            _ = reap(io, &child, &tasks);
            debug_trace.logf("hooks", "could not start a task to write hook input err={s}", .{@errorName(err)});
            return .{ .spawn_failed = try alloc.dupe(u8, "fx could not start a task to write the hook's input") };
        }
    };

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + @as(i64, request.timeout_ms);
    var stop: Stop = .none;
    while (true) {
        if (request.cancel) |flag| {
            if (flag.load(.acquire)) {
                stop = .cancelled;
                break;
            }
        }
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now >= deadline) {
            stop = .timed_out;
            break;
        }
        const wait_ms = @min(poll_ms, deadline - now);
        multi_reader.fill(read_room_bytes, .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(wait_ms),
        } }) catch |err| switch (err) {
            error.Timeout => continue,
            error.EndOfStream => break,
            error.Canceled => {
                stop = .cancelled;
                break;
            },
            else => break,
        };
        if (stdout_reader.buffered().len > request.stdout_limit or
            stderr_reader.buffered().len > request.stderr_limit)
        {
            stop = .too_much_output;
            break;
        }
    }

    // Both streams ended, or a read failed, but the hook may still run. Watch its
    // exit under the same limits. The watch reaps the pid itself, so `reap` must
    // not wait for it again.
    var exit_term: ?std.process.Child.Term = null;
    var reaped = false;
    if (stop == .none) {
        stop = watchExit(io, pid, request.cancel, deadline, &exit_term);
        reaped = stop == .none;
    }
    if (stop != .none) {
        stopGroup(pid, request.argv[0], @tagName(stop));
    }
    // The group has ended or is about to be stopped, so the registry lets go before the reap.
    live_groups.remove(slot);
    // Pending reads point into the reader buffers, so they must stop before the
    // buffers move and before the pipes close.
    multi_reader.batch.cancel(io);
    const term = if (reaped) finishPolled(io, &child, &tasks, exit_term) else reap(io, &child, &tasks);

    switch (stop) {
        .timed_out => return .timed_out,
        .cancelled => return .cancelled,
        .too_much_output => {
            const out = try takeOutputs(alloc, &multi_reader, request.stdout_limit, request.stderr_limit);
            return .{ .exited = .{
                .code = exitCodeOf(term),
                .stdout = out.stdout,
                .stderr = out.stderr,
                .stdout_overflow = true,
            } };
        },
        .none => {},
    }

    if (term == null) {
        return .{ .spawn_failed = try alloc.dupe(u8, "fx could not wait for the hook process") };
    }

    const out = try takeOutputs(alloc, &multi_reader, request.stdout_limit, request.stderr_limit);
    return switch (term.?) {
        .exited => |code| .{ .exited = .{ .code = code, .stdout = out.stdout, .stderr = out.stderr } },
        .signal => |sig| signaled: {
            alloc.free(out.stdout);
            break :signaled .{ .signaled = .{ .signal = @backingInt(sig), .stderr = out.stderr } };
        },
        .stopped, .unknown => signaled: {
            alloc.free(out.stdout);
            break :signaled .{ .signaled = .{ .signal = 0, .stderr = out.stderr } };
        },
    };
}

/// Writes every byte a hook asked for, then closes its stdin. A hook that exits
/// without reading makes the write fail, which is not an error here.
fn writeInput(io: std.Io, file: std.Io.File, stdin: []const u8) void {
    file.writeStreamingAll(io, stdin) catch {};
    file.close(io);
}

/// Kills the hook's whole process group, or the process alone when the group is gone.
fn stopGroup(pid: std.posix.pid_t, argv0: []const u8, reason: []const u8) void {
    // Both kills fail only with ESRCH: the hook and its group have already exited, so there is nothing to stop.
    std.posix.kill(-pid, .KILL) catch std.posix.kill(pid, .KILL) catch {};
    debug_trace.logf("hooks", "stopped hook process {s} pid={d}: {s}", .{ argv0, pid, reason });
}

/// The result for a hook that does not start because the registry is full. The trace gives the size of
/// the command, never its text (R3.8).
fn refuseFull(alloc: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!hooks.host.ProcessResult {
    debug_trace.logf("hooks", "refused kind=hook process bytes={d} reason=too many live groups", .{argvBytes(argv)});
    return .{ .spawn_failed = try alloc.dupe(u8, "fx could not start the hook: too many hook processes are running") };
}

/// The bytes in a command's arguments. A trace reports this size, never the text.
pub fn argvBytes(argv: []const []const u8) usize {
    var total: usize = 0;
    for (argv) |arg| total += arg.len;
    return total;
}

/// Closes the pipes a child still holds, for a child that never reaches the readers. Each field is set
/// to null, so the reap that follows does not close it again.
fn closeChildPipes(io: std.Io, child: *std.process.Child) void {
    if (child.stdin) |file| file.close(io);
    child.stdin = null;
    if (child.stdout) |file| file.close(io);
    child.stdout = null;
    if (child.stderr) |file| file.close(io);
    child.stderr = null;
}

/// One non-blocking look at whether the hook has exited.
const Poll = union(enum) {
    running,
    exited: std.process.Child.Term,
    failed: std.posix.E,
};

/// Asks the kernel, without blocking, whether `pid` has exited. An exit reaps the
/// pid, so the caller must not wait for it again.
fn pollExit(pid: std.posix.pid_t) Poll {
    var status: if (builtin.link_libc) c_int else i32 = undefined;
    while (true) {
        const rc = std.posix.system.wait4(pid, &status, std.posix.W.NOHANG, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return .running;
                return .{ .exited = statusToTerm(@bitCast(status)) };
            },
            .INTR => continue,
            else => |err| return .{ .failed = err },
        }
    }
}

/// Reads a wait status the way the standard library's `Child.wait` does.
fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

/// Watches the hook's exit after its output has ended. It checks the cancel flag
/// and the deadline every `poll_ms`. Returns `.none` once the hook has exited: the
/// poll reaped the pid, and `exit_term` holds its exit (null when the poll
/// failed). Returns `.cancelled` or `.timed_out` while the hook still runs, and
/// the caller then stops its group.
fn watchExit(
    io: std.Io,
    pid: std.posix.pid_t,
    cancel: ?*const std.atomic.Value(bool),
    deadline: i64,
    exit_term: *?std.process.Child.Term,
) Stop {
    while (true) {
        if (cancel) |flag| {
            if (flag.load(.acquire)) return .cancelled;
        }
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now >= deadline) return .timed_out;
        switch (pollExit(pid)) {
            .running => {},
            .exited => |term| {
                exit_term.* = term;
                return .none;
            },
            .failed => |err| {
                // The state of the pid is unknown, so no group signal is sent: after a
                // reap, the pid could belong to another process.
                debug_trace.logf("hooks", "could not poll hook process pid={d} err={s}", .{ pid, @tagName(err) });
                return .none;
            },
        }
        const wait_ms = @min(poll_ms, deadline - now);
        io_mod.sleep(@as(u64, @intCast(wait_ms)) * std.time.ns_per_ms);
    }
}

/// Ends a child that `watchExit` reaped. It closes the pipes that `Child.wait`
/// would close, clears the child's id, and stops the input task. Stdin is already
/// with the input task, which closes it.
fn finishPolled(
    io: std.Io,
    child: *std.process.Child,
    tasks: *std.Io.Group,
    exit_term: ?std.process.Child.Term,
) ?std.process.Child.Term {
    if (child.stdout) |file| {
        file.close(io);
        child.stdout = null;
    }
    if (child.stderr) |file| {
        file.close(io);
        child.stderr = null;
    }
    child.id = null;
    tasks.cancel(io);
    return exit_term;
}

/// Waits for the hook without being cancelled, then stops its input task. The
/// task may be blocked writing to a pipe a background job still holds open, so
/// it is cancelled rather than awaited. `writeInput` closes the pipe either way.
fn reap(io: std.Io, child: *std.process.Child, tasks: *std.Io.Group) ?std.process.Child.Term {
    const protection = io.swapCancelProtection(.blocked);
    const term = child.wait(io) catch |err| blk: {
        debug_trace.logf("hooks", "could not wait for hook process err={s}", .{@errorName(err)});
        break :blk null;
    };
    _ = io.swapCancelProtection(protection);
    tasks.cancel(io);
    return term;
}

/// The output a finished hook left, each cut to its limit. The caller owns both slices.
const Outputs = struct { stdout: []u8, stderr: []u8 };

/// Takes the bytes the reader buffered for stdout and stderr, each cut to its limit. A failed
/// cut frees the bytes it was given, so an error leaves nothing behind.
fn takeOutputs(
    alloc: std.mem.Allocator,
    multi_reader: *std.Io.File.MultiReader,
    stdout_limit: usize,
    stderr_limit: usize,
) std.mem.Allocator.Error!Outputs {
    const raw_stdout = try multi_reader.toOwnedSlice(0);
    const stdout = cutOwned(alloc, raw_stdout, stdout_limit) catch |err| {
        alloc.free(raw_stdout);
        return err;
    };
    errdefer alloc.free(stdout);
    const raw_stderr = try multi_reader.toOwnedSlice(1);
    const stderr = cutOwned(alloc, raw_stderr, stderr_limit) catch |err| {
        alloc.free(raw_stderr);
        return err;
    };
    return .{ .stdout = stdout, .stderr = stderr };
}

/// Returns the first `limit` bytes of `bytes`, freeing `bytes` when it must copy.
fn cutOwned(alloc: std.mem.Allocator, bytes: []u8, limit: usize) std.mem.Allocator.Error![]u8 {
    if (bytes.len <= limit) return bytes;
    const short = alloc.dupe(u8, bytes[0..limit]) catch |err| {
        alloc.free(bytes);
        return err;
    };
    alloc.free(bytes);
    return short;
}

/// The exit code of a finished hook, or 0 when it did not exit.
fn exitCodeOf(term: ?std.process.Child.Term) u8 {
    const ended = term orelse return 0;
    return switch (ended) {
        .exited => |code| code,
        else => 0,
    };
}

/// An environment with only PATH, so tests do not depend on the runner's.
fn testEnv(alloc: std.mem.Allocator) std.mem.Allocator.Error!std.process.Environ.Map {
    var env = std.process.Environ.Map.init(alloc);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    return env;
}

fn freeResult(alloc: std.mem.Allocator, result: hooks.host.ProcessResult) void {
    switch (result) {
        .exited => |exited| {
            alloc.free(exited.stdout);
            alloc.free(exited.stderr);
        },
        .signaled => |signaled| alloc.free(signaled.stderr),
        .spawn_failed => |text| alloc.free(text),
        .timed_out, .cancelled => {},
    }
}

/// How often `cancelWhenStarted` checks for the hook's pid file, and how long it waits for it.
const started_check_ms = 5;
const started_deadline_ms = 5000;

/// Sets `flag` once the hook has written `pid_path`, which its script does before anything
/// else. It checks for the file every `started_check_ms`, and stops waiting after
/// `started_deadline_ms`, so a hook that never starts cannot hang the test.
fn cancelWhenStarted(flag: *std.atomic.Value(bool), pid_path: []const u8) void {
    const io = io_mod.getIo();
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + started_deadline_ms;
    while (std.Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        if (std.Io.Dir.openFileAbsolute(io, pid_path, .{})) |file| {
            file.close(io);
            break;
        } else |_| {}
        io_mod.sleep(started_check_ms * std.time.ns_per_ms);
    }
    flag.store(true, .release);
}

test "a hook reads its input and both streams come back" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "cat; printf err >&2; exit 3" },
        .stdin = "hello",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    const exited = result.exited;
    try std.testing.expectEqual(@as(u8, 3), exited.code);
    try std.testing.expectEqualStrings("hello", exited.stdout);
    try std.testing.expectEqualStrings("err", exited.stderr);
}

test "hook environment adds AI_AGENT and the request entries win" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "printf %s \"$FX_HOOK_EVENT:$AI_AGENT\"" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{.{ .name = "FX_HOOK_EVENT", .value = "PreToolUse" }},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    try std.testing.expectEqualStrings("PreToolUse:fx", result.exited.stdout);
}

test "a hook starts in the directory it is given" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(path);

    const result = try run(alloc, io, &env, .{
        .argv = &.{"/bin/pwd"},
        .stdin = "",
        .cwd = path,
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    const expected = try alloc.print("{s}\n", .{path});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, result.exited.stdout);
}

test "a hook that runs too long is stopped" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const started = io_mod.milliTimestamp();
    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 5" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 200,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    const elapsed = io_mod.milliTimestamp() - started;
    defer freeResult(alloc, result);

    try std.testing.expect(result == .timed_out);
    try std.testing.expect(elapsed < 3000);
}

test "an already cancelled hook never starts" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    var flag = std.atomic.Value(bool).init(true);

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = &flag,
    });
    defer freeResult(alloc, result);

    try std.testing.expect(result == .cancelled);
}

test "a hook is stopped when it is cancelled while running" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const pid_path = try alloc.print("{s}/pid", .{dir});
    defer alloc.free(pid_path);
    const script = try alloc.print("echo $$ > '{s}'; exec sleep 5", .{pid_path});
    defer alloc.free(script);
    var flag = std.atomic.Value(bool).init(false);
    const canceller = try std.Thread.spawn(.{}, cancelWhenStarted, .{ &flag, pid_path });
    defer canceller.join();

    const started = io_mod.milliTimestamp();
    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 10000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = &flag,
    });
    const elapsed = io_mod.milliTimestamp() - started;
    defer freeResult(alloc, result);

    try std.testing.expect(result == .cancelled);
    try std.testing.expect(elapsed < 3000);
}

/// Runs a hook that writes its pid to `pid` in `dir`, closes its output, and then sleeps 5 s.
/// A pid no process has, for the test that fills the registry. No test signals it.
const registry_fill_pid: std.posix.pid_t = 0x7ffffff0;

test "a hook that finds the registry full does not start" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const marker = try alloc.print("{s}/started", .{dir});
    defer alloc.free(marker);
    const script = try alloc.print("touch '{s}'", .{marker});
    defer alloc.free(script);

    var taken: [live_groups.max_live_groups]live_groups.Slot = undefined;
    var count: usize = 0;
    defer for (taken[0..count]) |slot| live_groups.remove(slot);
    while (live_groups.hasRoom()) : (count += 1) {
        taken[count] = try live_groups.add(registry_fill_pid);
    }

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    try std.testing.expect(result == .spawn_failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, marker, .{}));
}

test "a hook run frees its group slot on success, on timeout, and on cancel" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    const before = live_groups.liveCount();

    const exited = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .cancel = null,
    });
    defer freeResult(alloc, exited);
    try std.testing.expect(exited == .exited);
    try std.testing.expectEqual(before, live_groups.liveCount());

    const timed_out = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 30" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 300,
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .cancel = null,
    });
    try std.testing.expect(timed_out == .timed_out);
    try std.testing.expectEqual(before, live_groups.liveCount());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const pid_path = try alloc.print("{s}/pid", .{dir});
    defer alloc.free(pid_path);
    const script = try alloc.print("echo $$ > '{s}'; exec sleep 30", .{pid_path});
    defer alloc.free(script);
    var flag = std.atomic.Value(bool).init(false);
    const canceller = try std.Thread.spawn(.{}, cancelWhenStarted, .{ &flag, pid_path });
    defer canceller.join();
    const cancelled = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 10000,
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .cancel = &flag,
    });
    try std.testing.expect(cancelled == .cancelled);
    try std.testing.expectEqual(before, live_groups.liveCount());
}

fn runOutputClosingHook(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    dir: []const u8,
    timeout_ms: u32,
    cancel: ?*std.atomic.Value(bool),
) std.mem.Allocator.Error!hooks.host.ProcessResult {
    const script = try alloc.print("echo $$ > '{s}/pid'; exec >/dev/null 2>&1; exec sleep 5", .{dir});
    defer alloc.free(script);
    return run(alloc, io, env, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = timeout_ms,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = cancel,
    });
}

/// The pid the hook wrote, which is also its process group id.
fn hookGroup(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !std.posix.pid_t {
    var file = try dir.openFile(io, "pid", .{});
    defer file.close(io);
    const bytes = try io_mod.readFileToEnd(alloc, &file, 64);
    defer alloc.free(bytes);
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \n"), 10);
}

/// True when no process is left in process group `group`. The hook is one process
/// (`exec sleep`), and `reap` has waited for it, so the group is empty as soon as
/// `run` returns.
fn groupGone(group: std.posix.pid_t) bool {
    std.posix.kill(-group, @fromBackingInt(@intCast(0))) catch |err| return err == error.ProcessNotFound;
    return false;
}

test "a hook that closes its output is still stopped at its timeout" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const started = io_mod.milliTimestamp();
    const result = try runOutputClosingHook(alloc, io, &env, dir, 300, null);
    const elapsed = io_mod.milliTimestamp() - started;
    defer freeResult(alloc, result);

    try std.testing.expect(result == .timed_out);
    try std.testing.expect(elapsed < 2000);
    try std.testing.expect(groupGone(try hookGroup(alloc, io, tmp.dir)));
}

test "a hook that closes its output is stopped by a cancel" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var flag = std.atomic.Value(bool).init(false);
    const pid_path = try alloc.print("{s}/pid", .{dir});
    defer alloc.free(pid_path);
    const canceller = try std.Thread.spawn(.{}, cancelWhenStarted, .{ &flag, pid_path });
    defer canceller.join();

    const started = io_mod.milliTimestamp();
    const result = try runOutputClosingHook(alloc, io, &env, dir, 10000, &flag);
    const elapsed = io_mod.milliTimestamp() - started;
    defer freeResult(alloc, result);

    try std.testing.expect(result == .cancelled);
    try std.testing.expect(elapsed < 2000);
    try std.testing.expect(groupGone(try hookGroup(alloc, io, tmp.dir)));
}

test "a hook that closes its output and exits at once keeps its exit code" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const started = io_mod.milliTimestamp();
    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "exec >/dev/null 2>&1; exit 0" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    const elapsed = io_mod.milliTimestamp() - started;
    defer freeResult(alloc, result);

    try std.testing.expect(result == .exited);
    try std.testing.expectEqual(@as(u8, 0), result.exited.code);
    try std.testing.expect(elapsed < 2000);
}

test "too much stdout stops the hook and keeps the first bytes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "head -c 300000 /dev/zero" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 10000,
        .stdout_limit = 100000,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    const exited = result.exited;
    try std.testing.expect(exited.stdout_overflow);
    try std.testing.expectEqual(@as(usize, 100000), exited.stdout.len);
}

test "a hook that cannot start says why" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const result = try run(alloc, io, &env, .{
        .argv = &.{"/nonexistent/fx-hook"},
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    try std.testing.expect(std.mem.find(u8, result.spawn_failed, "/nonexistent/fx-hook") != null);
}

test "a hook that ignores a large input does not deadlock" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    const big = try alloc.alloc(u8, 200_000);
    defer alloc.free(big);
    @memset(big, 'a');

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = big,
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(u8, 0), result.exited.code);
}

test "a hook stopped by a signal says so" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "kill -9 $$" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(u32, 9), result.signaled.signal);
}

test "a background job that holds the output open runs into the deadline" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const holding = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 3 & exit 0" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 300,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    defer freeResult(alloc, holding);
    try std.testing.expect(holding == .timed_out);

    const started = io_mod.milliTimestamp();
    const closed = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 3 >/dev/null 2>&1 & exit 0" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 2000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    const elapsed = io_mod.milliTimestamp() - started;
    defer freeResult(alloc, closed);
    try std.testing.expectEqual(@as(u8, 0), closed.exited.code);
    try std.testing.expect(elapsed < 1500);
}

test "too much stderr stops the hook and keeps the first bytes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();

    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "head -c 100000 /dev/zero >&2" },
        .stdin = "",
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 10000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 20000,
        .cancel = null,
    });
    defer freeResult(alloc, result);

    const exited = result.exited;
    try std.testing.expect(exited.stdout_overflow);
    try std.testing.expectEqual(@as(usize, 20000), exited.stderr.len);
}

test "a background job that keeps stdin open does not hang the run" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(alloc);
    defer env.deinit();
    const big = try alloc.alloc(u8, 300_000);
    defer alloc.free(big);
    @memset(big, 'a');

    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = try run(alloc, io, &env, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 3 >/dev/null 2>&1 & exit 0" },
        .stdin = big,
        .cwd = "/tmp",
        .env = &.{},
        .timeout_ms = 5000,
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .cancel = null,
    });
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(u8, 0), result.exited.code);
    try std.testing.expect(elapsed < 1500);
}

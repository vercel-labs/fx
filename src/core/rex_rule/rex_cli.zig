//! The real Rex for the resume rule: runs the `rex` command. Every call has a
//! deadline and a cancel flag. Each child leads its own process group, and every
//! exit path kills that group and reaps the child before the call returns.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const apply = @import("apply.zig");
const records = @import("records.zig");

pub const default_deadline_ms: u64 = 5000;

const trace_scope = "rex_rule";
const poll_step_ms: u64 = 20;
const read_buf_bytes = 4096;
const max_stdout_bytes = records.max_answer_bytes;

pub const Cli = struct {
    rex_path: []const u8,
    block: []const u8,
    deadline_ms: u64 = default_deadline_ms,
    cancel: *std.atomic.Value(bool),

    pub fn rex(self: *Cli) apply.Rex {
        return .{
            .ctx = self,
            .records = recordsFn,
            .check = checkFn,
            .reload = reloadFn,
            .pause = pauseFn,
        };
    }

    fn from(ctx: *anyopaque) *Cli {
        return @ptrCast(@alignCast(ctx));
    }

    fn recordsFn(ctx: *anyopaque, out: []u8) ?[]const u8 {
        const self = from(ctx);
        const argv = [_][]const u8{ self.rex_path, "block", "call", "-b", self.block, "program_resume_records" };
        const cap = @min(out.len, max_stdout_bytes);
        return self.capture(&argv, out[0..cap]);
    }

    fn checkFn(ctx: *anyopaque, init_path: []const u8) bool {
        const self = from(ctx);
        const argv = [_][]const u8{ self.rex_path, "config", "check", init_path };
        return self.exitsOk(&argv);
    }

    fn reloadFn(ctx: *anyopaque) bool {
        const self = from(ctx);
        const argv = [_][]const u8{ self.rex_path, "config", "reload" };
        return self.exitsOk(&argv);
    }

    fn pauseFn(ctx: *anyopaque, ms: u64) bool {
        const self = from(ctx);
        var remaining = ms;
        while (true) {
            if (self.cancel.load(.acquire)) return false;
            if (remaining == 0) return true;
            const step: u64 = @min(remaining, poll_step_ms);
            // Rex reads fx's report on its own schedule and sends no event, so fx waits
            // between asks, in short steps so a cancel at exit stops it at once.
            io_mod.sleep(step * std.time.ns_per_ms);
            remaining -= step;
        }
    }

    fn exitsOk(self: *Cli, argv: []const []const u8) bool {
        var buf: [max_stdout_bytes]u8 = undefined;
        return self.capture(argv, &buf) != null;
    }

    /// Runs `argv` with stdout piped, and returns stdout when the exit code is 0
    /// and stdout fits in `out`. Otherwise returns null. Every path kills the
    /// child's process group and reaps the child.
    fn capture(self: *Cli, argv: []const []const u8, out: []u8) ?[]const u8 {
        const io = io_mod.getIo();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            traceFailure("spawn", err);
            return null;
        };
        defer reap(io, &child);

        const pid = child.id orelse return null;
        const stdout = child.stdout orelse return null;
        const budget_ms: i64 = std.math.cast(i64, self.deadline_ms) orelse std.math.maxInt(i64);
        var watch: Watch = .{
            .pid = pid,
            .deadline_at_ms = io_mod.awakeMilliTimestamp() +| budget_ms,
            .cancel = self.cancel,
        };
        var watcher = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch |err| {
            traceFailure("watch thread", err);
            return null;
        };
        const bytes = readBounded(io, stdout, out);
        watch.done.store(true, .release);
        watcher.join();

        killGroup(pid);
        const captured = bytes orelse return null;
        const term = child.wait(io) catch |err| {
            traceFailure("wait", err);
            return null;
        };
        return switch (term) {
            .exited => |code| if (code == 0) captured else null,
            .signal, .stopped, .unknown => null,
        };
    }
};

/// Kills the child's process group when the deadline passes or the cancel flag
/// turns true. It runs on its own thread, and the caller joins it before the
/// group is killed again, so no pid is signalled after it was reaped.
const Watch = struct {
    pid: std.process.Child.Id,
    deadline_at_ms: i64,
    cancel: *const std.atomic.Value(bool),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        while (!self.done.load(.acquire)) {
            if (self.cancel.load(.acquire) or io_mod.awakeMilliTimestamp() >= self.deadline_at_ms) {
                killGroup(self.pid);
                return;
            }
            // A blocked read has no deadline of its own, so this watcher checks the clock and
            // the cancel flag every step, like the DeadlineWatch in app_agent_runtime.zig.
            io_mod.sleep(poll_step_ms * std.time.ns_per_ms);
        }
    }
};

/// Kills every process in the group that the child leads. The child was spawned
/// with `pgid = 0`, so the group id is the child's pid. ESRCH means the group is gone.
fn killGroup(pid: std.process.Child.Id) void {
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| switch (err) {
        // macOS returns EPERM for a group whose only member has exited but is not reaped yet.
        error.ProcessNotFound, error.PermissionDenied => {},
        else => traceFailure("kill group", err),
    };
}

/// Ends the call's process group, then reaps the child. A child that was already
/// waited for has no id, so the group is not signalled after its pid is free.
fn reap(io: std.Io, child: *std.process.Child) void {
    if (child.id) |pid| killGroup(pid);
    child.kill(io);
}

/// Reads at most `out.len` bytes. Null when the answer is longer, or on a read error.
fn readBounded(io: std.Io, file: std.Io.File, out: []u8) ?[]const u8 {
    var read_buf: [read_buf_bytes]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const got = reader.interface.readSliceShort(out) catch |err| {
        traceFailure("read", err);
        return null;
    };
    if (got < out.len) return out[0..got];
    _ = reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => return out[0..got],
        else => {
            traceFailure("read", err);
            return null;
        },
    };
    debug_trace.logf(trace_scope, "rex output over the cap bytes={d}", .{out.len});
    return null;
}

fn traceFailure(step: []const u8, err: anyerror) void {
    debug_trace.logf(trace_scope, "rex call failed step={s} error={s}", .{ step, @errorName(err) });
}

const testing = std.testing;
const block_answer = "{\"records\":[{\"owner\":{\"pid\":7}}]}";
const gone_deadline_ms: i64 = 1000;

/// A fake `rex` script in its own tmp folder, with its absolute paths.
const Fake = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn create(script: []const u8) !Fake {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const root = try io_mod.dirRealpathAlloc(arena.allocator(), tmp.dir, ".");
        var fake: Fake = .{ .tmp = tmp, .arena = arena, .root = root };
        try fake.writeRex(script);
        return fake;
    }

    fn deinit(self: *Fake) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn join(self: *Fake, name: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena.allocator(), &.{ self.root, name });
    }

    fn writeRex(self: *Fake, script: []const u8) !void {
        const io = io_mod.getIo();
        try self.tmp.dir.writeFile(io, .{ .sub_path = "rex", .data = script });
        try self.tmp.dir.setFilePermissions(io, "rex", std.Io.File.Permissions.fromMode(0o755), .{});
    }

    fn cli(self: *Fake, cancel: *std.atomic.Value(bool)) !Cli {
        return .{ .rex_path = try self.join("rex"), .block = "fx.block", .cancel = cancel };
    }

    /// Reads a pid that the fake script wrote into `name`.
    fn readPid(self: *Fake, name: []const u8) !std.posix.pid_t {
        const text = try self.tmp.dir.readFileAlloc(io_mod.getIo(), name, self.arena.allocator(), .limited(64));
        return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
    }
};

/// A killed process can stay a zombie until its parent reaps it, so poll for
/// ESRCH up to a deadline.
fn expectGone(pid: std.posix.pid_t) !void {
    const started = io_mod.awakeMilliTimestamp();
    while (true) {
        if (std.c.errno(std.c.kill(pid, @fromBackingInt(@intCast(0)))) == .SRCH) return;
        if (io_mod.awakeMilliTimestamp() - started > gone_deadline_ms) return error.ProcessStillRunning;
        // The process is not fx's child, so no wait call reports its exit; the test polls kill(pid, 0).
        io_mod.sleep(poll_step_ms * std.time.ns_per_ms);
    }
}

const answer_script =
    \\#!/bin/sh
    \\if [ "$1" = block ]; then printf '%s' '{"records":[{"owner":{"pid":7}}]}'; fi
    \\exit 0
    \\
;

const check_script =
    \\#!/bin/sh
    \\if [ "$1" = config ] && [ "$2" = check ] && grep -q BROKEN "$3"; then exit 1; fi
    \\exit 0
    \\
;

test "rex resume cli records returns the block answer" {
    var fake = try Fake.create(answer_script);
    defer fake.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    var r = cli.rex();
    var buf: [records.max_answer_bytes]u8 = undefined;
    const got = r.records(r.ctx, &buf) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings(block_answer, got);
}

test "rex resume cli check is true for a good file and false for a broken one" {
    var fake = try Fake.create(check_script);
    defer fake.deinit();
    const io = io_mod.getIo();
    try fake.tmp.dir.writeFile(io, .{ .sub_path = "good.lua", .data = "return {}\n" });
    try fake.tmp.dir.writeFile(io, .{ .sub_path = "broken.lua", .data = "BROKEN\n" });
    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    var r = cli.rex();
    try testing.expect(r.check(r.ctx, try fake.join("good.lua")));
    try testing.expect(!r.check(r.ctx, try fake.join("broken.lua")));
}

test "rex resume cli reload is true when rex exits 0" {
    var fake = try Fake.create(check_script);
    defer fake.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    var r = cli.rex();
    try testing.expect(r.reload(r.ctx));
}

test "rex resume cli refuses an answer over the 64 KiB cap" {
    var fake = try Fake.create(
        \\#!/bin/sh
        \\head -c 70000 /dev/zero
        \\exit 0
        \\
    );
    defer fake.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    var r = cli.rex();
    var buf: [records.max_answer_bytes]u8 = undefined;
    try testing.expect(r.records(r.ctx, &buf) == null);
}

test "rex resume cli gives up at its deadline and leaves no child behind" {
    var fake = try Fake.create("");
    defer fake.deinit();
    const pid_path = try fake.join("pid");
    const script = try fake.arena.allocator().print("#!/bin/sh\necho $$ > \"{s}\"\nexec sleep 10\n", .{pid_path});
    try fake.writeRex(script);

    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    cli.deadline_ms = 300;
    var r = cli.rex();
    var buf: [records.max_answer_bytes]u8 = undefined;
    const started = io_mod.awakeMilliTimestamp();
    try testing.expect(r.records(r.ctx, &buf) == null);
    try testing.expect(io_mod.awakeMilliTimestamp() - started < 2000);

    try expectGone(try fake.readPid("pid"));
}

test "rex resume cli kills background children of the call at its deadline" {
    var fake = try Fake.create("");
    defer fake.deinit();
    const script = try fake.arena.allocator().print(
        "#!/bin/sh\necho $$ > \"{s}\"\nsleep 10 & echo $! > \"{s}\"\nexec sleep 10\n",
        .{ try fake.join("child.pid"), try fake.join("bg.pid") },
    );
    try fake.writeRex(script);

    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    cli.deadline_ms = 300;
    var r = cli.rex();
    var buf: [records.max_answer_bytes]u8 = undefined;
    const started = io_mod.awakeMilliTimestamp();
    try testing.expect(r.records(r.ctx, &buf) == null);
    try testing.expect(io_mod.awakeMilliTimestamp() - started < 2000);

    try expectGone(try fake.readPid("child.pid"));
    try expectGone(try fake.readPid("bg.pid"));
}

const CancelLater = struct {
    cancel: *std.atomic.Value(bool),

    fn run(self: *CancelLater) void {
        // Paces the cancel so it lands while the call waits; the test asserts the return time, not this delay.
        io_mod.sleep(100 * std.time.ns_per_ms);
        self.cancel.store(true, .release);
    }
};

test "rex resume cli returns quickly when cancel is set during a call" {
    var fake = try Fake.create(
        \\#!/bin/sh
        \\exec sleep 10
        \\
    );
    defer fake.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var cli = try fake.cli(&cancel);
    var r = cli.rex();
    var canceller: CancelLater = .{ .cancel = &cancel };
    const canceller_thread = try std.Thread.spawn(.{}, CancelLater.run, .{&canceller});
    var buf: [records.max_answer_bytes]u8 = undefined;
    const started = io_mod.awakeMilliTimestamp();
    const got = r.records(r.ctx, &buf);
    canceller_thread.join();
    try testing.expect(got == null);
    try testing.expect(io_mod.awakeMilliTimestamp() - started < 2000);
}

test "rex resume cli pause returns false at once when cancel is already set" {
    var fake = try Fake.create(answer_script);
    defer fake.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    var cli = try fake.cli(&cancel);
    var r = cli.rex();
    try testing.expect(!r.pause(r.ctx, 60_000));
}

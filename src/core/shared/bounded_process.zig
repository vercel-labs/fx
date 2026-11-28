//! Runs one child process with a deadline, an optional cancel flag, and capped
//! output. The caller reads the finished output and maps errors to its own
//! messages. A cancelled or timed-out run whose output arrives late frees it
//! here, so no output outlives the run.

const std = @import("std");
const select_watch = @import("select_watch.zig");

pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Replaces the whole child environment when set.
    environ_map: ?*const std.process.Environ.Map = null,
    stdout_limit: usize,
    stderr_limit: usize,
    timeout_ms: u64,
    /// When set and true, the run is stopped. A null flag means the run cannot be cancelled.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Overwrite the stdout of an abandoned run before it is freed, for a
    /// process whose output is a secret.
    scrub_abandoned_stdout: bool = false,
    /// Runs the child. Callers leave the default; the tests replace it to
    /// choose when a run's output arrives.
    run_child: *const fn (alloc: std.mem.Allocator, io: std.Io, options: *const Options) std.process.RunError!std.process.RunResult = runChild,
};

pub const Outcome = union(enum) {
    /// The caller owns the output and frees it.
    finished: std.process.RunError!std.process.RunResult,
    cancelled,
    unavailable: std.Io.ConcurrentError,
};

/// Runs the command and waits for it. Returns `.cancelled` after the flag is
/// set, which stops the child too.
pub fn run(alloc: std.mem.Allocator, io: std.Io, options: Options) Outcome {
    const flag = options.cancel orelse return .{ .finished = dispatchChild(alloc, io, &options) };
    return runCancellable(alloc, io, &options, flag);
}

const CancelCondition = struct {
    flag: *const std.atomic.Value(bool),

    pub fn cancelled(condition: CancelCondition) bool {
        return condition.flag.load(.acquire);
    }

    pub fn expired(_: CancelCondition, _: std.Io) bool {
        return false;
    }
};

const CancelWatch = select_watch.Watch(CancelCondition);

const RunEvent = union(enum) {
    process: std.process.RunError!std.process.RunResult,
    watch: std.Io.Cancelable!select_watch.Outcome,
};

fn runCancellable(
    alloc: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    flag: *const std.atomic.Value(bool),
) Outcome {
    var watch: CancelWatch = .{};
    var select_buffer: [2]RunEvent = undefined;
    var select: std.Io.Select(RunEvent) = .init(io, &select_buffer);
    select.concurrent(.watch, CancelWatch.run, .{
        &watch,
        select.io,
        CancelCondition{ .flag = flag },
    }) catch |err| return .{ .unavailable = err };
    select.concurrent(.process, dispatchChild, .{ alloc, io, options }) catch |err| {
        watch.finish(&select);
        return .{ .unavailable = err };
    };
    const event = select.await() catch {
        abandonRun(alloc, options.scrub_abandoned_stdout, &select, &watch);
        return .cancelled;
    };
    switch (event) {
        .process => |result| {
            watch.finish(&select);
            return .{ .finished = result };
        },
        .watch => {
            abandonRun(alloc, options.scrub_abandoned_stdout, &select, &watch);
            return .cancelled;
        },
    }
}

fn abandonRun(
    alloc: std.mem.Allocator,
    scrub: bool,
    select: *std.Io.Select(RunEvent),
    watch: *CancelWatch,
) void {
    watch.stop(select.io);
    while (select.cancel()) |item| switch (item) {
        .process => |result| if (result) |late| {
            if (scrub) {
                zeroAndFree(alloc, late.stdout);
            } else {
                alloc.free(late.stdout);
            }
            alloc.free(late.stderr);
        } else |_| {},
        .watch => {},
    };
}

/// The same rule as `auth/secret.zig` `zeroAndFree`: an empty buffer is left
/// alone, and any other buffer is overwritten before it is released. It is
/// released with `rawFree`, not `free`: in safe builds `free` first overwrites
/// the bytes with `undefined`, which would hide the zeroing from the allocator.
fn zeroAndFree(alloc: std.mem.Allocator, buffer: []u8) void {
    if (buffer.len == 0) return;
    std.crypto.secureZero(u8, @volatileCast(buffer));
    alloc.rawFree(buffer, .@"1", @returnAddress());
}

fn dispatchChild(
    alloc: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) std.process.RunError!std.process.RunResult {
    return options.run_child(alloc, io, options);
}

fn runChild(
    alloc: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) std.process.RunError!std.process.RunResult {
    return std.process.run(alloc, io, .{
        .argv = options.argv,
        .cwd = childCwd(options.cwd),
        .environ_map = options.environ_map,
        .stdout_limit = .limited(options.stdout_limit),
        .stderr_limit = .limited(options.stderr_limit),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(options.timeout_ms)),
            .clock = .awake,
        } },
    });
}

fn childCwd(cwd: ?[]const u8) std.process.Child.Cwd {
    const path = cwd orelse return .inherit;
    return .{ .path = path };
}

/// Exists only to see the zeroing. It forwards every call to
/// `std.testing.allocator`, and on each free it counts the buffers that still
/// hold a nonzero byte, which a scrubbed buffer never does.
const ZeroCheck = struct {
    frees: usize = 0,
    nonzero_frees: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *ZeroCheck) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return std.testing.allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remapFn(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ZeroCheck = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        if (holdsNonzero(buf)) self.nonzero_frees += 1;
        std.testing.allocator.rawFree(buf, alignment, ret_addr);
    }
};

fn holdsNonzero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

/// Stands in for a child that prints a secret only after its run was
/// cancelled: it waits for the cancel flag, then waits longer, so the cancel
/// always lands first and the output arrives after it.
const LateOutput = struct {
    const secret = "token-secret-value";
    const delay_after_cancel_ms: i64 = 300;

    fn run(alloc: std.mem.Allocator, io: std.Io, options: *const Options) std.process.RunError!std.process.RunResult {
        const flag = options.cancel.?;
        while (!flag.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
        // A cancel ends this wait early; the output still arrives, which is the case under test.
        io.sleep(.fromMilliseconds(delay_after_cancel_ms), .awake) catch {};
        return .{
            .term = .{ .exited = 0 },
            .stdout = alloc.dupe(u8, secret) catch @panic("the test allocator failed"),
            .stderr = alloc.dupe(u8, "") catch @panic("the test allocator failed"),
        };
    }
};

fn setFlagAfter(flag: *std.atomic.Value(bool), delay_ms: i64) void {
    std.testing.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
    flag.store(true, .release);
}

fn runLateOutputAfterCancel(scrub: bool) !ZeroCheck {
    var check: ZeroCheck = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, setFlagAfter, .{ &cancel, 50 });
    const outcome = run(check.allocator(), std.testing.io, .{
        .argv = &.{"unused"},
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .timeout_ms = 60_000,
        .cancel = &cancel,
        .scrub_abandoned_stdout = scrub,
        .run_child = LateOutput.run,
    });
    thread.join();
    try std.testing.expect(std.meta.activeTag(outcome) == .cancelled);
    return check;
}

test "a command that ends in time returns its output" {
    const alloc = std.testing.allocator;
    const outcome = run(alloc, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout_ms = 10_000,
    });
    const output = switch (outcome) {
        .finished => |result| try result,
        else => return error.TestUnexpectedResult,
    };
    defer alloc.free(output.stdout);
    defer alloc.free(output.stderr);
    try std.testing.expect(std.meta.activeTag(output.term) == .exited);
    try std.testing.expectEqual(@as(u8, 0), output.term.exited);
    try std.testing.expectEqualStrings("hello", output.stdout);
}

test "output over the cap is refused" {
    const outcome = run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "head -c 200 /dev/zero" },
        .stdout_limit = 100,
        .stderr_limit = 64,
        .timeout_ms = 10_000,
    });
    switch (outcome) {
        .finished => |result| try std.testing.expectError(error.StreamTooLong, result),
        else => return error.TestUnexpectedResult,
    }
}

test "the deadline stops a command that sleeps" {
    const started_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const outcome = run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "sleep", "5" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout_ms = 200,
    });
    switch (outcome) {
        .finished => |result| try std.testing.expectError(error.Timeout, result),
        else => return error.TestUnexpectedResult,
    }
    const elapsed_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - started_ns;
    try std.testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
}

test "a cancel stops a command that sleeps" {
    var cancel = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, setFlagAfter, .{ &cancel, 100 });
    const started_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const outcome = run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 5" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout_ms = 60_000,
        .cancel = &cancel,
    });
    thread.join();
    try std.testing.expect(std.meta.activeTag(outcome) == .cancelled);
    const elapsed_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - started_ns;
    try std.testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
}

test "with scrub_abandoned_stdout, output that arrives after a cancel is zeroed before it is freed" {
    const check = try runLateOutputAfterCancel(true);
    try std.testing.expect(check.frees >= 1);
    try std.testing.expectEqual(@as(usize, 0), check.nonzero_frees);
}

test "without scrub_abandoned_stdout, the same output is freed without zeroing" {
    const check = try runLateOutputAfterCancel(false);
    try std.testing.expect(check.frees >= 1);
    try std.testing.expect(check.nonzero_frees >= 1);
}

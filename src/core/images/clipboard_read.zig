//! Reads a clipboard image off the input loop, for `/paste` and Ctrl+V.
//!
//! osascript can take seconds to export a large image, so `start` returns at
//! once and a worker thread runs the export. The export stops at `timeout`,
//! or when shutdown sets the cancel flag, which kills osascript within one
//! poll (`image_attachments.loadClipboardImageAttachment`). The loop takes
//! the finished read in its fact collection with `take` and attaches the
//! image to the agent that asked (`image_commands.zig`). One read runs at a
//! time: `start` refuses a second until the first is taken.
//!
//! `tests/tla/clipboard_read/ClipboardRead.tla` models the read, and
//! `tests/tla/drivers/clipboard_read/driver.ts` checks the built fx against it.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("image_attachments.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const CaptureBudget = image_attachments.CaptureBudget;
const ClipboardImageAttachment = image_attachments.ClipboardImageAttachment;

/// How long osascript may run before the read stops it.
pub const default_timeout: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromSeconds(10) };

/// How a read ended.
pub const Outcome = union(enum) {
    image: ClipboardImageAttachment,
    no_image,
    timed_out,
    /// Any other failure, `error.Cancelled` at shutdown included.
    failed: anyerror,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        switch (self.*) {
            .image => |*loaded| loaded.deinit(alloc),
            .no_image, .timed_out, .failed => {},
        }
        self.* = undefined;
    }

    fn of(result: anyerror!ClipboardImageAttachment) Outcome {
        const loaded = result catch |err| return switch (err) {
            error.NoClipboardImage => .no_image,
            error.TimedOut => .timed_out,
            else => .{ .failed = err },
        };
        return .{ .image = loaded };
    }
};

/// A read the loop took. `requester` is the agent that asked, compared by
/// address only and never read, or null once that agent has closed
/// (`Runtime.forget`). The caller owns `outcome`.
pub const Finished = struct {
    requester: ?*const anyopaque,
    outcome: Outcome,
};

/// Exports the clipboard image within a budget. `supported` is false where
/// fx cannot read clipboard images, which makes `start` a silent no-op.
pub const Loader = struct {
    ctx: ?*anyopaque = null,
    load: *const fn (?*anyopaque, Allocator, CaptureBudget) anyerror!ClipboardImageAttachment,
    supported: bool = true,
};

/// osascript on macOS.
pub const system_loader: Loader = .{
    .load = loadSystemClipboard,
    .supported = image_attachments.clipboard_image_supported,
};

fn loadSystemClipboard(_: ?*anyopaque, alloc: Allocator, budget: CaptureBudget) anyerror!ClipboardImageAttachment {
    return image_attachments.loadClipboardImageAttachment(alloc, budget);
}

pub const Start = enum { started, busy, unsupported };

const Phase = enum { idle, reading, done };

/// One per app, on the loop thread. The worker writes only `phase` and
/// `outcome`, under `mutex`, and reads `cancel`.
pub const Runtime = struct {
    loader: Loader = system_loader,
    timeout: std.Io.Clock.Duration = default_timeout,
    mutex: std.Io.Mutex = .init,
    phase: Phase = .idle,
    outcome: ?Outcome = null,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Loop thread only.
    thread: ?std.Thread = null,
    requester: ?*const anyopaque = null,
    /// Tests only: the next worker spawn fails with this error.
    test_spawn_error: if (builtin.is_test) ?anyerror else void = if (builtin.is_test) null else {},

    /// Starts a read for `requester` and returns at once. `.busy` while a
    /// read is running or waiting to be taken.
    pub fn start(self: *Runtime, alloc: Allocator, requester: *const anyopaque) !Start {
        if (comptime builtin.single_threaded) return .unsupported;
        if (!self.loader.supported) return .unsupported;
        return self.startWithin(alloc, requester, .{
            .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), self.timeout),
        });
    }

    /// `start` with the budget's deadline and test hook given; the runtime
    /// adds its cancel flag.
    fn startWithin(self: *Runtime, alloc: Allocator, requester: *const anyopaque, budget: CaptureBudget) !Start {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.phase != .idle) {
            self.mutex.unlock(io);
            debug_trace.logf("images", "event=clipboard_read_busy", .{});
            return .busy;
        }
        self.phase = .reading;
        self.mutex.unlock(io);

        var within = budget;
        within.cancel_flag = &self.cancel;
        self.thread = self.spawnWorker(alloc, within) catch |err| {
            self.mutex.lockUncancelable(io);
            self.phase = .idle;
            self.mutex.unlock(io);
            debug_trace.logf("images", "event=clipboard_read_spawn_failed err={s}", .{@errorName(err)});
            return err;
        };
        self.requester = requester;
        debug_trace.logf("images", "event=clipboard_read_started", .{});
        return .started;
    }

    fn spawnWorker(self: *Runtime, alloc: Allocator, budget: CaptureBudget) !std.Thread {
        if (comptime builtin.is_test) {
            if (self.test_spawn_error) |err| return err;
        }
        return std.Thread.spawn(.{}, run, .{ self, alloc, budget });
    }

    fn run(self: *Runtime, alloc: Allocator, budget: CaptureBudget) void {
        const outcome = Outcome.of(self.loader.load(self.loader.ctx, alloc, budget));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.outcome = outcome;
        self.phase = .done;
    }

    /// The finished read, once; null while one runs or none was started.
    pub fn take(self: *Runtime) ?Finished {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.phase != .done) {
            self.mutex.unlock(io);
            return null;
        }
        const outcome = self.outcome.?;
        self.outcome = null;
        self.phase = .idle;
        self.mutex.unlock(io);
        // The worker stored its outcome last, so it is returning.
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const requester = self.requester;
        self.requester = null;
        debug_trace.logf("images", "event=clipboard_read_taken outcome={s} requester={s}", .{
            @tagName(outcome),
            if (requester == null) "closed" else "open",
        });
        return .{ .requester = requester, .outcome = outcome };
    }

    /// `agent` is closing: a read it started finishes without it, so a new
    /// agent at the same address never takes its image.
    pub fn forget(self: *Runtime, agent: *const anyopaque) void {
        if (self.requester != agent) return;
        self.requester = null;
        debug_trace.logf("images", "event=clipboard_read_requester_closed", .{});
    }

    /// Stops a read in flight and waits for its worker, which kills
    /// osascript at its next poll. A finished read nobody took is freed and
    /// logged as dropped.
    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.cancel.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        if (self.outcome) |*outcome| {
            debug_trace.logf("images", "event=clipboard_read_dropped reason=shutdown outcome={s}", .{switch (outcome.*) {
                .failed => |err| @errorName(err),
                else => @tagName(outcome.*),
            }});
            outcome.deinit(alloc);
        }
        const loader = self.loader;
        const timeout = self.timeout;
        self.* = .{ .loader = loader, .timeout = timeout };
    }
};

// Tests. The loaders below stand in for osascript: no test reads the real
// clipboard.

/// Blocks until released or cancelled, then ends as `verdict` says.
const ScriptedLoader = struct {
    entered: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(u32) = .init(0),
    verdict: std.atomic.Value(u8) = .init(@backingInt(Verdict.no_image)),
    /// Bounds a test that forgets to release the loader.
    max_wait_ms: u32 = 10_000,

    const Verdict = enum(u8) { no_image, timed_out, failed };

    fn loader(self: *ScriptedLoader) Loader {
        return .{ .ctx = self, .load = load };
    }

    fn finish(self: *ScriptedLoader, verdict: Verdict) void {
        self.verdict.store(@backingInt(verdict), .seq_cst);
        self.release.store(true, .seq_cst);
    }

    fn load(ctx: ?*anyopaque, _: Allocator, budget: CaptureBudget) anyerror!ClipboardImageAttachment {
        const self: *ScriptedLoader = @ptrCast(@alignCast(ctx.?));
        _ = self.entered.fetchAdd(1, .seq_cst);
        var waited_ms: u32 = 0;
        while (!self.release.load(.seq_cst)) : (waited_ms += 1) {
            budget.check() catch |err| {
                if (err == error.Cancelled) _ = self.cancelled.fetchAdd(1, .seq_cst);
                return err;
            };
            if (waited_ms >= self.max_wait_ms) return error.TestLoaderNotReleased;
            io_mod.sleep(std.time.ns_per_ms);
        }
        self.release.store(false, .seq_cst);
        return switch (@as(Verdict, @fromBackingInt(self.verdict.load(.seq_cst)))) {
            .no_image => error.NoClipboardImage,
            .timed_out => error.TimedOut,
            .failed => error.TestLoaderFailed,
        };
    }
};

fn waitEntered(loader: *ScriptedLoader) !void {
    var waited_ms: usize = 0;
    while (loader.entered.load(.seq_cst) == 0) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestTimedOut;
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn waitTake(runtime: *Runtime) !Finished {
    var waited_ms: usize = 0;
    while (true) : (waited_ms += 1) {
        if (runtime.take()) |finished| return finished;
        if (waited_ms > 10_000) return error.TestTimedOut;
        io_mod.sleep(std.time.ns_per_ms);
    }
}

const agent_a: u8 = 'a';
const agent_b: u8 = 'b';

test "a clipboard read returns at once while the export blocks, refuses a second start, and is taken once" {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader() };
    defer runtime.deinit(std.testing.allocator);

    try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
    try waitEntered(&scripted);
    // The export is still blocked: nothing to take, and a second paste is refused.
    try std.testing.expect(runtime.take() == null);
    try std.testing.expectEqual(Start.busy, try runtime.start(std.testing.allocator, &agent_b));
    try std.testing.expectEqual(@as(u32, 1), scripted.entered.load(.seq_cst));

    scripted.finish(.no_image);
    var finished = try waitTake(&runtime);
    defer finished.outcome.deinit(std.testing.allocator);
    try std.testing.expect(finished.outcome == .no_image);
    try std.testing.expectEqual(@as(?*const anyopaque, &agent_a), finished.requester);
    try std.testing.expect(runtime.take() == null);
    try std.testing.expect(runtime.thread == null);

    // Taken, so the next paste reads again.
    try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_b));
    scripted.finish(.timed_out);
    var second = try waitTake(&runtime);
    defer second.outcome.deinit(std.testing.allocator);
    try std.testing.expect(second.outcome == .timed_out);
    try std.testing.expectEqual(@as(?*const anyopaque, &agent_b), second.requester);
}

test "shutdown cancels a blocked clipboard read and joins its worker" {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader() };
    try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
    try waitEntered(&scripted);

    runtime.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), scripted.cancelled.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.outcome == null);
    try std.testing.expect(!runtime.cancel.load(.seq_cst));
}

test "a finished clipboard image nobody took is freed at shutdown" {
    const ImageLoader = struct {
        fn load(_: ?*anyopaque, alloc: Allocator, _: CaptureBudget) anyerror!ClipboardImageAttachment {
            const dir = try image_attachments.createTempSnapshotDir(alloc);
            errdefer alloc.free(dir);
            const path = try std.Io.Dir.path.join(alloc, &.{ dir, "clipboard.png" });
            errdefer alloc.free(path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "\x89PNG\r\n\x1a\nimage" });
            return .{
                .attachment = .{ .path = path, .media_type = try alloc.dupe(u8, "image/png") },
                .source_dir = dir,
            };
        }
    };
    var runtime: Runtime = .{ .loader = .{ .load = ImageLoader.load } };
    try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
    var waited_ms: usize = 0;
    while (true) : (waited_ms += 1) {
        runtime.mutex.lockUncancelable(std.testing.io);
        const done = runtime.phase == .done;
        runtime.mutex.unlock(std.testing.io);
        if (done) break;
        try std.testing.expect(waited_ms < 10_000);
        io_mod.sleep(std.time.ns_per_ms);
    }
    const dir = try std.testing.allocator.dupe(u8, runtime.outcome.?.image.source_dir);
    defer std.testing.allocator.free(dir);

    // The testing allocator reports a leak if deinit drops the image.
    runtime.deinit(std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, dir, .{}));
}

test "a clipboard read started by an agent that closed is taken without it" {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader() };
    defer runtime.deinit(std.testing.allocator);

    try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
    runtime.forget(&agent_b);
    try std.testing.expectEqual(@as(?*const anyopaque, &agent_a), runtime.requester);
    runtime.forget(&agent_a);
    scripted.finish(.no_image);
    var finished = try waitTake(&runtime);
    defer finished.outcome.deinit(std.testing.allocator);
    try std.testing.expect(finished.requester == null);
}

test "a failed worker spawn leaves no read running and the next paste starts one" {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader(), .test_spawn_error = error.SystemResources };
    defer runtime.deinit(std.testing.allocator);

    try std.testing.expectError(error.SystemResources, runtime.start(std.testing.allocator, &agent_a));
    try std.testing.expect(runtime.phase == .idle);
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.requester == null);
    try std.testing.expect(runtime.take() == null);

    runtime.test_spawn_error = null;
    try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
    scripted.finish(.no_image);
    var finished = try waitTake(&runtime);
    defer finished.outcome.deinit(std.testing.allocator);
    try std.testing.expect(finished.outcome == .no_image);
}

test "a clipboard read is silent where clipboard images are unsupported" {
    var runtime: Runtime = .{ .loader = .{ .load = ScriptedLoader.load, .supported = false } };
    defer runtime.deinit(std.testing.allocator);
    try std.testing.expectEqual(Start.unsupported, try runtime.start(std.testing.allocator, &agent_a));
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.take() == null);
}

/// A clock the test moves: each budget check is one tick, and the deadline
/// passes at `deadline_tick`.
const TickClock = struct {
    ticks: std.atomic.Value(u32) = .init(0),
    deadline_tick: u32,

    fn check(ctx: *anyopaque) anyerror!void {
        const self: *TickClock = @ptrCast(@alignCast(ctx));
        const tick = self.ticks.fetchAdd(1, .seq_cst) + 1;
        if (tick >= self.deadline_tick) return error.TimedOut;
    }
};

test "a clipboard read times out at its deadline and not before" {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader() };
    defer runtime.deinit(std.testing.allocator);

    // A deadline the real clock has reached times out at the first check.
    const passed = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectEqual(Start.started, try runtime.startWithin(std.testing.allocator, &agent_a, .{ .deadline = passed }));
    var first = try waitTake(&runtime);
    defer first.outcome.deinit(std.testing.allocator);
    try std.testing.expect(first.outcome == .timed_out);

    // On the test's clock every check before the deadline tick keeps the
    // read waiting, and the check at the deadline tick stops it.
    var clock: TickClock = .{ .deadline_tick = 50 };
    try std.testing.expectEqual(Start.started, try runtime.startWithin(std.testing.allocator, &agent_a, .{
        .test_hook = .{ .ctx = &clock, .check = TickClock.check },
    }));
    var second = try waitTake(&runtime);
    defer second.outcome.deinit(std.testing.allocator);
    try std.testing.expect(second.outcome == .timed_out);
    try std.testing.expectEqual(clock.deadline_tick, clock.ticks.load(.seq_cst));
}

test "1000 clipboard reads in a row are each started, finished, and taken once" {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader() };
    defer runtime.deinit(std.testing.allocator);
    for (0..1000) |index| {
        try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
        try std.testing.expectEqual(Start.busy, try runtime.start(std.testing.allocator, &agent_b));
        scripted.finish(if (index % 2 == 0) .no_image else .failed);
        var finished = try waitTake(&runtime);
        defer finished.outcome.deinit(std.testing.allocator);
        try std.testing.expect(runtime.take() == null);
    }
    try std.testing.expectEqual(@as(u32, 1000), scripted.entered.load(.seq_cst));
}

/// Plays one sequence of loop steps against a runtime and checks its rules
/// after each: one read at a time, each read taken once with its own
/// outcome and requester, and nothing left once shut down.
fn playSequence(next: anytype) !void {
    var scripted: ScriptedLoader = .{};
    var runtime: Runtime = .{ .loader = scripted.loader() };
    defer runtime.deinit(std.testing.allocator);
    const Expect = enum { idle, reading, done };
    var expect: Expect = .idle;
    var requester: ?*const anyopaque = null;
    var verdict: ScriptedLoader.Verdict = .no_image;
    var steps: usize = 0;
    while (next.step()) |op| : (steps += 1) {
        if (steps >= 64) break;
        switch (op % 5) {
            0 => {
                const who: *const anyopaque = if (next.flag()) &agent_a else &agent_b;
                const started = try runtime.start(std.testing.allocator, who);
                if (expect == .idle) {
                    try std.testing.expectEqual(Start.started, started);
                    expect = .reading;
                    requester = who;
                } else try std.testing.expectEqual(Start.busy, started);
            },
            1 => if (expect == .reading) {
                verdict = @fromBackingInt(next.pick(3));
                scripted.finish(verdict);
                expect = .done;
            },
            2 => if (expect == .done) {
                var finished = try waitTake(&runtime);
                defer finished.outcome.deinit(std.testing.allocator);
                try std.testing.expectEqual(requester, finished.requester);
                try std.testing.expectEqualStrings(@tagName(verdict), switch (finished.outcome) {
                    .failed => "failed",
                    else => @tagName(finished.outcome),
                });
                try std.testing.expect(runtime.take() == null);
                expect = .idle;
                requester = null;
            } else try std.testing.expect(runtime.take() == null),
            3 => {
                const who: *const anyopaque = if (next.flag()) &agent_a else &agent_b;
                runtime.forget(who);
                if (requester == who) requester = null;
            },
            else => {
                runtime.deinit(std.testing.allocator);
                try std.testing.expect(runtime.thread == null);
                try std.testing.expect(runtime.outcome == null);
                expect = .idle;
                requester = null;
                scripted.release.store(false, .seq_cst);
            },
        }
    }
}

const SmithSteps = struct {
    smith: *std.testing.Smith,

    fn step(self: SmithSteps) ?u8 {
        if (self.smith.eos()) return null;
        return self.smith.value(u8);
    }
    fn flag(self: SmithSteps) bool {
        return self.smith.boolWeighted(1, 1);
    }
    fn pick(self: SmithSteps, n: u8) u8 {
        return self.smith.valueRangeAtMost(u8, 0, n - 1);
    }
};

const RandomSteps = struct {
    random: std.Random,
    left: usize,

    fn step(self: *RandomSteps) ?u8 {
        if (self.left == 0) return null;
        self.left -= 1;
        return self.random.int(u8);
    }
    fn flag(self: *RandomSteps) bool {
        return self.random.boolean();
    }
    fn pick(self: *RandomSteps, n: u8) u8 {
        return self.random.uintLessThan(u8, n);
    }
};

test "clipboard reads keep one read at a time on fuzzed step sequences" {
    try std.testing.fuzz({}, fuzzClipboardRead, .{
        // Each byte is one step, read with the flag or verdict it needs.
        .corpus = &(.{ "", "\x00\x01\x01\x00\x02", "\x00\x00\x03\x00\x01\x02\x02", "\x00\x01\x05\x04\x00\x02" } ++
            @import("fuzz_corpus").clipboard_read.*),
    });
}

fn fuzzClipboardRead(_: void, smith: *std.testing.Smith) !void {
    try playSequence(SmithSteps{ .smith = smith });
}

test "clipboard reads keep one read at a time on seeded random step sequences" {
    var prng = std.Random.DefaultPrng.init(0xc11b_0a2d);
    for (0..300) |_| {
        var steps: RandomSteps = .{ .random = prng.random(), .left = 1 + prng.random().uintLessThan(usize, 24) };
        try playSequence(&steps);
    }
}

/// Finishes after a random short delay, so the worker stores its outcome at
/// different moments relative to the loop's take and shutdown.
const JitterLoader = struct {
    prng: std.Random.DefaultPrng,
    mutex: std.Io.Mutex = .init,

    fn load(ctx: ?*anyopaque, _: Allocator, budget: CaptureBudget) anyerror!ClipboardImageAttachment {
        const self: *JitterLoader = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(std.testing.io);
        const delay_us = self.prng.random().uintLessThan(u64, 300);
        self.mutex.unlock(std.testing.io);
        io_mod.sleep(delay_us * std.time.ns_per_us);
        try budget.check();
        return error.NoClipboardImage;
    }
};

test "clipboard reads survive the worker finishing at any moment around take and shutdown" {
    var jitter: JitterLoader = .{ .prng = std.Random.DefaultPrng.init(0x7a5e_5eed) };
    var prng = std.Random.DefaultPrng.init(0x0dd5_eed5);
    var taken: usize = 0;
    for (0..500) |_| {
        var runtime: Runtime = .{ .loader = .{ .ctx = &jitter, .load = JitterLoader.load } };
        try std.testing.expectEqual(Start.started, try runtime.start(std.testing.allocator, &agent_a));
        io_mod.sleep(prng.random().uintLessThan(u64, 300) * std.time.ns_per_us);
        if (prng.random().boolean()) {
            if (runtime.take()) |finished| {
                var owned = finished;
                owned.outcome.deinit(std.testing.allocator);
                taken += 1;
                try std.testing.expect(runtime.take() == null);
            }
        }
        // Whatever the worker has done by now, shutdown joins it and frees
        // anything left exactly once.
        runtime.deinit(std.testing.allocator);
        try std.testing.expect(runtime.thread == null);
        try std.testing.expect(runtime.outcome == null);
    }
    try std.testing.expect(taken <= 500);
}

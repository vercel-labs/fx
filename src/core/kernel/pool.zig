//! The one owner of every kernel in this process. It keys saved kernels by
//! their snapshot directory, so each session node has one kernel however many
//! session runtimes or nested hosts reach it, and it bounds the Python
//! processes by their private memory: the sweeper samples every live kernel
//! and zygote (`memory.zig`), and while the total, or the total plus an
//! estimate for a kernel about to start, exceeds `Limits.budget_bytes`, the
//! least recently used idle kernel is parked (snapshot, then stop). At most
//! `Limits.max_live` processes run at once whatever the budget. One left idle
//! past its TTL is parked too. A parked kernel restores lazily on its next
//! cell. A kernel running a cell is never parked. The decision is D95 in
//! `tests/tla/session_manager/system-design.md`.
//!
//! Lock order: the pool mutex may be taken before a manager's mutex, never
//! after. Parking happens with the pool unlocked, under a pin that keeps the
//! manager alive.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const kernel = @import("kernel.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const memory = @import("memory.zig");
const zygote = @import("zygote.zig");
const Allocator = std.mem.Allocator;
const Manager = kernel.Manager;
const Cancel = ?*const std.atomic.Value(bool);
const now = io_mod.monotonicMilliTimestamp;

pub const max_live_env = "PROTO_FX_MAX_LIVE_KERNELS";
pub const idle_env = "PROTO_FX_KERNEL_IDLE_MS";
pub const held_idle_env = "PROTO_FX_KERNEL_HELD_IDLE_MS";

/// Opaque identity of whatever keeps a kernel past its slot, such as the
/// tree a subagent belongs to. Only `releaseRetained` compares it.
pub const Retainer = *const anyopaque;

/// What a kernel that has not been sampled yet is assumed to cost, until any
/// live kernel has been: then the smallest sampled one stands in for it.
const default_estimate: u64 = 24 << 20;

pub const Limits = struct {
    /// Hard ceiling on Python kernel processes alive at once, matching the
    /// process-wide slot pool. `PROTO_FX_MAX_LIVE_KERNELS` overrides it.
    max_live: usize = 32,
    /// Private memory every live kernel and zygote may hold together; the
    /// environment default is `memory.configuredBudget`.
    budget_bytes: u64 = std.math.maxInt(u64),
    /// How often the sweeper samples memory while any kernel is live.
    sample_ms: i64 = 2000,
    /// How long zygotes outlive the last live kernel.
    zygote_linger_ms: i64 = 60_000,
    /// Idle TTL for a kernel no session runtime holds: a subagent's between
    /// its turns. Zero never parks.
    idle_ms: i64 = 5 * 60 * 1000,
    /// Idle TTL for a kernel a session runtime holds, such as an open root
    /// session. Longer, because a person returns to it and restoring costs
    /// a process start plus any live resources.
    held_idle_ms: i64 = 30 * 60 * 1000,
    /// How long a start waits for a running cell to finish when every live
    /// kernel is busy, before refusing.
    admit_wait_ms: i64 = 60_000,

    fn fromEnv() Limits {
        var value: Limits = .{};
        const max_live = parse(io_mod.getenv(max_live_env), @intCast(value.max_live));
        if (max_live > 0) value.max_live = @intCast(@min(max_live, 256));
        value.budget_bytes = memory.configuredBudget();
        value.idle_ms = parse(io_mod.getenv(idle_env), value.idle_ms);
        value.held_idle_ms = parse(io_mod.getenv(held_idle_env), value.held_idle_ms);
        return value;
    }
};

fn parse(raw: ?[]const u8, default: i64) i64 {
    const text = raw orelse return default;
    const value = std.fmt.parseInt(i64, text, 10) catch return default;
    return if (value < 0) default else value;
}

/// Per-manager pool state, guarded by the pool mutex.
pub const Membership = struct {
    /// Session runtimes holding the kernel through a slot.
    refs: usize = 0,
    /// Short holds by the pool while it parks this kernel.
    pins: usize = 0,
    /// Whether `keyed` lists it, which makes the pool its owner.
    keyed: bool = false,
    /// Keeps it alive with no refs while its process lives.
    retainer: ?Retainer = null,
    /// Counted against `max_live` from admission until its process stops.
    live: bool = false,
    last_used: i64 = 0,
    /// The live process, once spawned; zero before.
    pid: std.posix.pid_t = 0,
    /// Its last sampled private memory; zero until the first sample.
    private_bytes: u64 = 0,
};

var mutex: std.Io.Mutex = .init;
var changed: std.Io.Condition = .init;
var limits_loaded = false;
var limits: Limits = .{};
var keyed: std.ArrayList(*Manager) = .empty;
var live: std.ArrayList(*Manager) = .empty;
var sweeper_running = false;
/// The zygotes' private memory at the last sample.
var zygote_bytes: u64 = 0;
/// Counters for tests and diagnostics.
var parked_total: u64 = 0;

fn limitsLocked() Limits {
    if (!limits_loaded) {
        limits = Limits.fromEnv();
        limits_loaded = true;
    }
    return limits;
}

/// Replaces the limits, for tests and embedders. Call before kernels exist.
pub fn setLimits(value: Limits) void {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    limits = value;
    limits_loaded = true;
}

pub fn parkedTotal() u64 {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return parked_total;
}

/// The sampled private memory of live kernels and zygotes, counting each
/// kernel not sampled yet at the estimate.
pub fn memoryTotal() u64 {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return totalLocked();
}

fn totalLocked() u64 {
    const estimate = estimateLocked();
    var total = zygote_bytes;
    for (live.items) |manager| total +|= if (manager.pool.private_bytes > 0) manager.pool.private_bytes else estimate;
    return total;
}

fn estimateLocked() u64 {
    var smallest: u64 = 0;
    for (live.items) |manager| {
        const bytes = manager.pool.private_bytes;
        if (bytes > 0 and (smallest == 0 or bytes < smallest)) smallest = bytes;
    }
    return if (smallest > 0) smallest else default_estimate;
}

fn fitsLocked(config: Limits) Fit {
    return fits(config, live.items.len, totalLocked(), estimateLocked());
}

/// Whether admitting one more kernel keeps the pool within its limits.
fn fits(config: Limits, live_count: usize, total: u64, estimate: u64) Fit {
    if (live_count >= config.max_live) return .over_ceiling;
    // The first kernel always fits: a budget below one kernel would refuse all work.
    if (live_count > 0 and total +| estimate > config.budget_bytes) return .over_budget;
    return .fits;
}

const Fit = enum { fits, over_budget, over_ceiling };

pub fn liveCount() usize {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return live.items.len;
}

/// Whether any kernel in the process is running a cell, at any depth of any
/// tree: what keeps an idle supervisor from exiting under a cell.
pub fn anyExecuting() bool {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    for (live.items) |manager| if (manager.executing()) return true;
    return false;
}

/// The kernel for `options`, held once more by the caller until `release`.
/// A saved kernel is shared by snapshot directory; an unsaved one is the
/// caller's alone. `alloc` must be thread-safe and outlive the kernel.
pub fn acquire(alloc: Allocator, options: kernel.Options, retainer: ?Retainer) !*Manager {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (options.persist) for (keyed.items) |manager| {
        if (!std.mem.eql(u8, manager.artifact_dir, options.artifact_dir)) continue;
        manager.pool.refs += 1;
        if (retainer) |value| manager.pool.retainer = value;
        return manager;
    };
    try keyed.ensureUnusedCapacity(std.heap.c_allocator, 1);
    const manager = try Manager.create(alloc, options);
    manager.pool = .{ .refs = 1, .keyed = true, .retainer = retainer, .last_used = now() };
    keyed.appendAssumeCapacity(manager);
    return manager;
}

/// Drops one hold. The kernel is destroyed, with a final snapshot, unless a
/// retainer keeps its live process for a later turn.
pub fn release(manager: *Manager) void {
    mutex.lockUncancelable(io_mod.getIo());
    std.debug.assert(manager.pool.refs > 0);
    manager.pool.refs -= 1;
    const doomed = takeIfUnownedLocked(manager);
    mutex.unlock(io_mod.getIo());
    if (doomed) manager.destroy();
}

/// Destroys every kernel `retainer` kept that no runtime holds, and lets the
/// held ones go when their last slot does. Their owner calls this as it
/// closes, after every node that could use them has stopped.
pub fn releaseRetained(retainer: Retainer) void {
    var doomed: std.ArrayList(*Manager) = .empty;
    defer doomed.deinit(std.heap.c_allocator);
    mutex.lockUncancelable(io_mod.getIo());
    var index: usize = 0;
    while (index < keyed.items.len) {
        const manager = keyed.items[index];
        if (manager.pool.retainer != retainer) {
            index += 1;
            continue;
        }
        manager.pool.retainer = null;
        if (manager.pool.refs == 0 and manager.pool.pins == 0) {
            _ = keyed.swapRemove(index);
            manager.pool.keyed = false;
            doomed.append(std.heap.c_allocator, manager) catch {
                mutex.unlock(io_mod.getIo());
                manager.destroy();
                mutex.lockUncancelable(io_mod.getIo());
            };
            continue;
        }
        index += 1;
    }
    mutex.unlock(io_mod.getIo());
    for (doomed.items) |manager| manager.destroy();
}

/// Caller holds the mutex. Removes and reports a pool-owned kernel nobody
/// needs: no refs, no pins, and no retainer keeping a live process.
fn takeIfUnownedLocked(manager: *Manager) bool {
    const state = &manager.pool;
    if (!state.keyed or state.refs > 0 or state.pins > 0) return false;
    if (state.retainer != null and state.live) return false;
    for (keyed.items, 0..) |candidate, index| if (candidate == manager) {
        _ = keyed.swapRemove(index);
        break;
    };
    state.keyed = false;
    return true;
}

/// Called by `Manager.destroy` before it tears down: no pool list names it
/// afterwards, and no park is still using it.
pub fn forget(manager: *Manager) void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    removeLive(manager);
    for (keyed.items, 0..) |candidate, index| if (candidate == manager) {
        _ = keyed.swapRemove(index);
        break;
    };
    manager.pool.keyed = false;
    while (manager.pool.pins > 0) changed.waitUncancelable(io, &mutex);
}

/// Marks a cell's start or end as this kernel's latest use and wakes any
/// start waiting for an idle kernel to park.
pub fn touch(manager: *Manager) void {
    mutex.lockUncancelable(io_mod.getIo());
    manager.pool.last_used = now();
    mutex.unlock(io_mod.getIo());
    changed.broadcast(io_mod.getIo());
}

/// Counts `manager` as live before its process starts, parking least recently
/// used idle kernels while the memory budget or the ceiling would be exceeded.
/// Over budget with nothing parkable, it admits anyway: the budget is a soft
/// target on a lagging sample, every kernel in the way is running a cell, and
/// the sweeper parks idle kernels as soon as cells end. At the ceiling with
/// every live kernel running a cell it waits for one to finish, up to
/// `admit_wait_ms`, then refuses with `error.KernelCapacityExhausted`. Waiting
/// rather than refusing at once lets a fan-out of children share the ceiling;
/// the deadline keeps a stuck cell from hanging every other start.
pub fn admit(manager: *Manager, cancel: Cancel, owner: *const std.atomic.Value(bool)) !void {
    const io = io_mod.getIo();
    const deadline = now() + limitsSnapshot().admit_wait_ms;
    var skipped: std.ArrayList(*Manager) = .empty;
    defer skipped.deinit(std.heap.c_allocator);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (manager.pool.live) return;
    while (true) {
        const fit = fitsLocked(limitsLocked());
        if (fit == .fits) break;
        if (isSet(cancel) or owner.load(.acquire)) return error.Cancelled;
        const victim = pickVictimLocked(skipped.items) orelse {
            if (fit == .over_budget) {
                debug_trace.logf("kernel", "admit over budget total={d} budget={d} live={d}: every live kernel is busy", .{ totalLocked(), limitsLocked().budget_bytes, live.items.len });
                break;
            }
            const left = deadline - now();
            if (left <= 0) return error.KernelCapacityExhausted;
            // A cell finishing, a park, or a stop broadcasts; the slice rechecks cancel.
            skipped.clearRetainingCapacity();
            changed.waitTimeout(io, &mutex, .{ .duration = .{ .raw = .fromMilliseconds(std.math.clamp(left, 1, 50)), .clock = .awake } }) catch {};
            continue;
        };
        if (!parkPinnedLocked(victim)) skipped.append(std.heap.c_allocator, victim) catch {};
    }
    try live.ensureUnusedCapacity(std.heap.c_allocator, 1);
    live.appendAssumeCapacity(manager);
    manager.pool.live = true;
    manager.pool.last_used = now();
    manager.pool.pid = 0;
    manager.pool.private_bytes = 0;
    debug_trace.logf("kernel", "admit dir={s} live={d} total={d}", .{ manager.artifact_dir, live.items.len, totalLocked() });
    startSweeperLocked();
}

/// Its process started as `pid`, which the sweeper samples from now on.
pub fn started(manager: *Manager, pid: std.posix.pid_t) void {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    manager.pool.pid = pid;
    manager.pool.private_bytes = 0;
}

/// Its process stopped: it no longer counts against the cap.
pub fn retire(manager: *Manager) void {
    mutex.lockUncancelable(io_mod.getIo());
    removeLive(manager);
    mutex.unlock(io_mod.getIo());
    changed.broadcast(io_mod.getIo());
}

fn removeLive(manager: *Manager) void {
    if (!manager.pool.live) return;
    manager.pool.live = false;
    manager.pool.pid = 0;
    manager.pool.private_bytes = 0;
    for (live.items, 0..) |candidate, index| if (candidate == manager) {
        _ = live.swapRemove(index);
        return;
    };
}

fn limitsSnapshot() Limits {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return limitsLocked();
}

/// What the victim choice reads about one live kernel.
const Candidate = struct { last_used: i64, parkable: bool };

/// The least recently used parkable kernel, or null.
fn pickOldest(candidates: []const Candidate) ?usize {
    var best: ?usize = null;
    for (candidates, 0..) |candidate, index| {
        if (!candidate.parkable) continue;
        if (best == null or candidate.last_used < candidates[best.?].last_used) best = index;
    }
    return best;
}

fn pickVictimLocked(skipped: []const *Manager) ?*Manager {
    var candidates: [256]Candidate = undefined;
    const count = @min(live.items.len, candidates.len);
    for (live.items[0..count], candidates[0..count]) |manager, *candidate| {
        const excluded = std.mem.findScalar(*Manager, skipped, manager) != null;
        candidate.* = .{ .last_used = manager.pool.last_used, .parkable = !excluded and manager.parkable() };
    }
    const index = pickOldest(candidates[0..count]) orelse return null;
    return live.items[index];
}

/// Caller holds the mutex; it is released while the victim parks and held
/// again on return. Reports whether the victim parked.
fn parkPinnedLocked(victim: *Manager) bool {
    const io = io_mod.getIo();
    victim.pool.pins += 1;
    mutex.unlock(io);
    const parked = victim.park();
    mutex.lockUncancelable(io);
    victim.pool.pins -= 1;
    if (parked) parked_total += 1;
    debug_trace.logf("kernel", "park dir={s} parked={} live={d}", .{ victim.artifact_dir, parked, live.items.len });
    const doomed = takeIfUnownedLocked(victim);
    changed.broadcast(io);
    if (doomed) {
        mutex.unlock(io);
        victim.destroy();
        mutex.lockUncancelable(io);
    }
    return parked;
}

fn startSweeperLocked() void {
    if (sweeper_running) return;
    const thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, sweep, .{}) catch return;
    thread.detach();
    sweeper_running = true;
}

/// Samples memory, parks kernels while the pool is over budget or idle past
/// their TTL, and stops the zygotes once no kernel has been live for
/// `zygote_linger_ms`. A later admission starts it again.
fn sweep() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    var empty_since: ?i64 = null;
    var next_sample: i64 = 0;
    while (true) {
        const config = limitsLocked();
        const at = now();
        if (live.items.len == 0) {
            const since = empty_since orelse at;
            empty_since = since;
            const left = since + config.zygote_linger_ms - at;
            if (left <= 0) break;
            changed.waitTimeout(io, &mutex, .{ .duration = .{ .raw = .fromMilliseconds(std.math.clamp(left, 10, 60_000)), .clock = .awake } }) catch {};
            continue;
        }
        empty_since = null;
        if (at >= next_sample) {
            mutex.unlock(io);
            sample();
            mutex.lockUncancelable(io);
            next_sample = now() + config.sample_ms;
            if (overBudgetParkLocked(config)) continue;
        }
        var next_due: i64 = @min(at + 60_000, next_sample);
        var due: ?*Manager = null;
        for (live.items) |manager| {
            const ttl = if (manager.pool.refs > 0 or !manager.pool.keyed) config.held_idle_ms else config.idle_ms;
            if (ttl == 0) continue;
            // A busy kernel's cell may end without a wake that finds it parkable.
            if (!manager.parkable()) {
                next_due = @min(next_due, at + 1000);
                continue;
            }
            const when = manager.pool.last_used + ttl;
            if (when <= at) {
                due = manager;
                break;
            }
            next_due = @min(next_due, when);
        }
        if (due) |manager| {
            // A park that fails counts as a use, so it is not retried in a loop.
            if (!parkPinnedLocked(manager)) manager.pool.last_used = now();
            continue;
        }
        changed.waitTimeout(io, &mutex, .{ .duration = .{ .raw = .fromMilliseconds(std.math.clamp(next_due - at, 10, 60_000)), .clock = .awake } }) catch {};
    }
    sweeper_running = false;
    zygote_bytes = 0;
    mutex.unlock(io);
    zygote.stopAll();
}

/// Caller holds the mutex. Parks least recently used idle kernels until the
/// sampled total fits the budget, and reports whether it parked any. Kernels
/// that will not park are skipped until the next sample. As in admission, one
/// kernel always stays, however small the budget.
fn overBudgetParkLocked(config: Limits) bool {
    var skipped: std.ArrayList(*Manager) = .empty;
    defer skipped.deinit(std.heap.c_allocator);
    var parked_any = false;
    while (live.items.len > 1 and totalLocked() > config.budget_bytes) {
        const victim = pickVictimLocked(skipped.items) orelse break;
        debug_trace.logf("kernel", "over budget total={d} budget={d}: parking dir={s}", .{ totalLocked(), config.budget_bytes, victim.artifact_dir });
        if (parkPinnedLocked(victim)) {
            parked_any = true;
        } else skipped.append(std.heap.c_allocator, victim) catch break;
    }
    return parked_any;
}

/// Reads every live kernel's and zygote's private memory, with the pool
/// unlocked for the syscalls. A kernel that stopped meanwhile keeps no sample.
fn sample() void {
    const io = io_mod.getIo();
    const Reading = struct { manager: *Manager, pid: std.posix.pid_t, bytes: u64 = 0 };
    var readings: [256]Reading = undefined;
    var count: usize = 0;
    mutex.lockUncancelable(io);
    for (live.items) |manager| {
        if (manager.pool.pid <= 0 or count == readings.len) continue;
        readings[count] = .{ .manager = manager, .pid = manager.pool.pid };
        count += 1;
    }
    mutex.unlock(io);
    for (readings[0..count]) |*reading| reading.bytes = memory.privateBytes(reading.pid) orelse 0;
    var zygote_pids: [8]std.posix.pid_t = undefined;
    var zygote_total: u64 = 0;
    for (zygote_pids[0..zygote.pids(&zygote_pids)]) |pid| zygote_total +|= memory.privateBytes(pid) orelse 0;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    zygote_bytes = zygote_total;
    for (readings[0..count]) |reading| {
        // Only a manager still live under the same pid takes the reading.
        if (std.mem.findScalar(*Manager, live.items, reading.manager) == null) continue;
        if (reading.manager.pool.pid == reading.pid) reading.manager.pool.private_bytes = reading.bytes;
    }
}

fn isSet(flag: Cancel) bool {
    return if (flag) |value| value.load(.acquire) else false;
}

test "the pool parks the least recently used parkable kernel" {
    const candidates = [_]Candidate{
        .{ .last_used = 30, .parkable = true },
        .{ .last_used = 10, .parkable = false },
        .{ .last_used = 20, .parkable = true },
    };
    // The oldest is running a cell, so the next oldest goes.
    try std.testing.expectEqual(@as(?usize, 2), pickOldest(&candidates));
    const busy = [_]Candidate{ .{ .last_used = 1, .parkable = false }, .{ .last_used = 2, .parkable = false } };
    try std.testing.expectEqual(@as(?usize, null), pickOldest(&busy));
    try std.testing.expectEqual(@as(?usize, null), pickOldest(&.{}));
}

test "admission checks the ceiling first, then the memory budget, and always admits the first kernel" {
    const config: Limits = .{ .max_live = 3, .budget_bytes = 100 };
    try std.testing.expectEqual(Fit.fits, fits(config, 0, 500, 500));
    try std.testing.expectEqual(Fit.fits, fits(config, 1, 40, 60));
    try std.testing.expectEqual(Fit.over_budget, fits(config, 1, 41, 60));
    try std.testing.expectEqual(Fit.over_ceiling, fits(config, 3, 0, 0));
    try std.testing.expectEqual(Fit.over_budget, fits(.{ .budget_bytes = 10 }, 1, std.math.maxInt(u64), 1));
    // The default limits have no budget until the environment sets one.
    try std.testing.expectEqual(Fit.fits, fits(.{}, 31, 1 << 40, 1 << 40));
    try std.testing.expectEqual(Fit.over_ceiling, fits(.{}, 32, 0, 0));
}

test "pool limits read overrides and ignore bad values" {
    try std.testing.expectEqual(@as(i64, 300_000), parse(null, 300_000));
    try std.testing.expectEqual(@as(i64, 300_000), parse("soon", 300_000));
    try std.testing.expectEqual(@as(i64, 300_000), parse("-5", 300_000));
    try std.testing.expectEqual(@as(i64, 0), parse("0", 300_000));
    try std.testing.expectEqual(@as(i64, 1500), parse("1500", 300_000));
}

test "saved kernels are shared by snapshot directory and released by their retainer" {
    const alloc = std.heap.c_allocator;
    const tree: u8 = 0;
    const options: kernel.Options = .{ .cwd = "/Users/example", .artifact_dir = "/Users/example/.proto-fx/kernels/pool-test" };
    const first = try acquire(alloc, options, null);
    const second = try acquire(alloc, options, &tree);
    try std.testing.expect(first == second);
    release(first);
    release(second);
    // No process was live, so the retainer kept nothing: the last release
    // destroyed it.
    try std.testing.expectEqual(@as(usize, 0), keyedCount(options.artifact_dir));
    // A live process outlives its last slot until its retainer lets go.
    const third = try acquire(alloc, options, &tree);
    mutex.lockUncancelable(io_mod.getIo());
    try live.append(std.heap.c_allocator, third);
    third.pool.live = true;
    mutex.unlock(io_mod.getIo());
    release(third);
    try std.testing.expectEqual(@as(usize, 1), keyedCount(options.artifact_dir));
    try std.testing.expect(try acquire(alloc, options, null) == third);
    release(third);
    releaseRetained(&tree);
    try std.testing.expectEqual(@as(usize, 0), keyedCount(options.artifact_dir));
    try std.testing.expectEqual(@as(usize, 0), liveCount());
}

fn keyedCount(dir: []const u8) usize {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    var count: usize = 0;
    for (keyed.items) |manager| {
        if (std.mem.eql(u8, manager.artifact_dir, dir)) count += 1;
    }
    return count;
}

/// A temporary kernel home for the live tests, which run only when
/// PROTO_FX_KERNEL_TEST_PYTHON names a Python 3.11+ with dill.
const LiveFixture = struct {
    alloc: Allocator,
    python: []const u8,
    tmp: std.testing.TmpDir,
    root: []u8,
    runner_env: std.process.Environ.Map,
    env: std.process.Environ.Map,

    fn init(self: *LiveFixture, value: Limits) !void {
        const alloc = std.testing.allocator;
        self.alloc = alloc;
        self.runner_env = try std.process.Environ.createMap(std.testing.environ, alloc);
        errdefer self.runner_env.deinit();
        self.python = self.runner_env.get("PROTO_FX_KERNEL_TEST_PYTHON") orelse return error.SkipZigTest;
        self.tmp = std.testing.tmpDir(.{});
        self.root = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        const kernel_home = try std.Io.Dir.path.join(alloc, &.{ self.root, "kernel-home" });
        defer alloc.free(kernel_home);
        self.env = std.process.Environ.Map.init(alloc);
        try self.env.put("HOME", self.root);
        try self.env.put("PROTO_FX_KERNEL_HOME", kernel_home);
        io_mod.setEnvironMap(&self.env);
        setLimits(value);
    }

    fn deinit(self: *LiveFixture) void {
        setLimits(.{});
        io_mod.resetEnvironForTest();
        self.env.deinit();
        self.alloc.free(self.root);
        self.tmp.cleanup();
        self.runner_env.deinit();
    }

    fn manager(self: *LiveFixture, name: []const u8) !*Manager {
        const dir = try std.Io.Dir.path.join(self.alloc, &.{ self.root, name });
        defer self.alloc.free(dir);
        return Manager.create(self.alloc, .{ .cwd = self.root, .artifact_dir = dir, .python = self.python });
    }

    fn expectResult(self: *LiveFixture, target: *Manager, code: []const u8, expected: []const u8) !void {
        const result = try target.execute(self.alloc, code, .{});
        defer result.deinit(self.alloc);
        try std.testing.expectEqualStrings(expected, result.result);
    }
};

test "a full pool parks the least recently used idle kernel and restores it on its next cell" {
    var fixture: LiveFixture = undefined;
    try fixture.init(.{ .max_live = 2, .idle_ms = 0, .held_idle_ms = 0 });
    defer fixture.deinit();
    const a = try fixture.manager("a");
    defer a.destroy();
    const b = try fixture.manager("b");
    defer b.destroy();
    const c = try fixture.manager("c");
    defer c.destroy();
    try fixture.expectResult(a, "x = 'a'\nx", "'a'");
    try fixture.expectResult(b, "x = 'b'\nx", "'b'");
    const parked = parkedTotal();
    try fixture.expectResult(c, "x = 'c'\nx", "'c'");
    // `a` was used least recently, so it parked to admit `c`.
    try std.testing.expectEqual(kernel.State.idle, a.status());
    try std.testing.expectEqual(kernel.State.running, b.status());
    try std.testing.expectEqual(parked + 1, parkedTotal());
    try std.testing.expectEqual(@as(usize, 2), liveCount());
    // Its globals come back from the snapshot; now `b` is the oldest.
    try fixture.expectResult(a, "x", "'a'");
    try std.testing.expectEqual(kernel.State.idle, b.status());
    try fixture.expectResult(b, "x", "'b'");
}

test "a kernel running a cell is never parked, and a start waits for it or refuses" {
    var fixture: LiveFixture = undefined;
    try fixture.init(.{ .max_live = 1, .idle_ms = 0, .held_idle_ms = 0, .admit_wait_ms = 400 });
    defer fixture.deinit();
    const a = try fixture.manager("a");
    defer a.destroy();
    const b = try fixture.manager("b");
    defer b.destroy();
    try fixture.expectResult(a, "y = 7\ny", "7");

    const Long = struct {
        fn run(target: *Manager, outcome: *kernel.Status) void {
            const result = target.execute(std.testing.allocator, "import time\ntime.sleep(2)\ny", .{}) catch return;
            defer result.deinit(std.testing.allocator);
            outcome.* = result.status;
        }
    };
    var outcome: kernel.Status = .aborted;
    var cell = try std.Thread.spawn(.{}, Long.run, .{ a, &outcome });
    while (!a.executing()) io_mod.sleep(10 * std.time.ns_per_ms);
    // The only live kernel is busy past the admission wait: refused, not parked.
    try std.testing.expectError(error.KernelCapacityExhausted, b.execute(fixture.alloc, "1", .{}));
    try std.testing.expectEqual(kernel.State.running, a.status());
    try std.testing.expect(anyExecuting());
    cell.join();
    try std.testing.expect(!anyExecuting());
    try std.testing.expectEqual(kernel.Status.ok, outcome);

    // With a longer wait, the start waits for the cell and then parks `a`.
    setLimits(.{ .max_live = 1, .idle_ms = 0, .held_idle_ms = 0, .admit_wait_ms = 20_000 });
    outcome = .aborted;
    cell = try std.Thread.spawn(.{}, Long.run, .{ a, &outcome });
    while (!a.executing()) io_mod.sleep(10 * std.time.ns_per_ms);
    try fixture.expectResult(b, "2", "2");
    cell.join();
    try std.testing.expectEqual(kernel.Status.ok, outcome);
    try std.testing.expectEqual(kernel.State.idle, a.status());
    try fixture.expectResult(a, "y", "7");
}

test "an idle kernel parks after its TTL and restores lazily" {
    var fixture: LiveFixture = undefined;
    try fixture.init(.{ .max_live = 4, .idle_ms = 300, .held_idle_ms = 300 });
    defer fixture.deinit();
    const a = try fixture.manager("a");
    defer a.destroy();
    try fixture.expectResult(a, "z = [1, 2, 3]\nlen(z)", "3");
    var waited: usize = 0;
    while (a.status() != .idle and waited < 100) : (waited += 1) io_mod.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(kernel.State.idle, a.status());
    try std.testing.expectEqual(@as(usize, 0), liveCount());
    try fixture.expectResult(a, "sum(z)", "6");
}

test "a start over the memory budget parks an idle kernel, and so does the sweeper" {
    var fixture: LiveFixture = undefined;
    // One byte: any second kernel is over budget.
    try fixture.init(.{ .max_live = 8, .budget_bytes = 1, .idle_ms = 0, .held_idle_ms = 0, .sample_ms = 100 });
    defer fixture.deinit();
    const a = try fixture.manager("a");
    defer a.destroy();
    const b = try fixture.manager("b");
    defer b.destroy();
    try fixture.expectResult(a, "v = 'a'\nv", "'a'");
    const parked = parkedTotal();
    try fixture.expectResult(b, "v = 'b'\nv", "'b'");
    try std.testing.expectEqual(kernel.State.idle, a.status());
    try std.testing.expectEqual(parked + 1, parkedTotal());
    try std.testing.expectEqual(@as(usize, 1), liveCount());

    // Admitted under a loose budget, both run until the budget tightens; then
    // the sweeper parks the least recently used one from its samples.
    setLimits(.{ .max_live = 8, .idle_ms = 0, .held_idle_ms = 0, .sample_ms = 100 });
    try fixture.expectResult(a, "v", "'a'");
    try std.testing.expectEqual(@as(usize, 2), liveCount());
    mutex.lockUncancelable(io_mod.getIo());
    limits.budget_bytes = 1;
    mutex.unlock(io_mod.getIo());
    changed.broadcast(io_mod.getIo());
    var waited: usize = 0;
    while (liveCount() > 1 and waited < 100) : (waited += 1) io_mod.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), liveCount());
    try std.testing.expectEqual(kernel.State.idle, b.status());
    try std.testing.expect(memoryTotal() > 0);
    try fixture.expectResult(b, "v", "'b'");
}

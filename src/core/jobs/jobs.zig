//! Background jobs: one registry over every source of work that outlives
//! the tool call that started it. Shell commands the model was handed while
//! they ran are `bg_N`; fleet turns are `<node>-t<n>`. Monitors join as a
//! third source.
//!
//! Each settled job's result reaches the model exactly once (D110): either a
//! `jobs wait` that holds a lease on it, or the automatic async-result
//! delivery, never both. The registry keeps only the leases. Each source
//! keeps its job's delivery state, so a result is reserved by one consumer
//! at a time and committed once the model has it. The protocol is modeled
//! in `tests/tla/jobs/Jobs.tla` `ExactlyOnceDelivery`.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const result_commit = @import("../tooling/result_commit.zig");
const Allocator = std.mem.Allocator;

pub const shell_source = @import("shell_source.zig");
pub const turn_source = @import("turn_source.zig");
pub const watch_source = @import("watch_source.zig");
pub const notice = @import("notice.zig");
pub const card = @import("card.zig");
pub const host = @import("host.zig");

pub const Kind = enum {
    shell,
    turn,
    /// A watch over a job's output or a polled command (D190).
    watch,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .shell => "shell",
            .turn => "worker",
            .watch => "watch",
        };
    }
};

pub const State = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,

    pub fn settled(self: State) bool {
        return switch (self) {
            .queued, .running => false,
            .completed, .failed, .cancelled => true,
        };
    }

    /// Lists show running work first, then what needs attention.
    fn rank(self: State) u8 {
        return switch (self) {
            .queued, .running => 0,
            .failed => 1,
            .cancelled => 2,
            .completed => 3,
        };
    }
};

/// One job as its source sees it now. Strings borrow the caller's arena.
pub const Job = struct {
    id: []const u8,
    kind: Kind,
    label: []const u8,
    state: State,
    started_ms: i64,
    ended_ms: ?i64 = null,
    /// A cancel was requested and the work has not settled yet.
    tearing_down: bool = false,
    /// Its final result reached the model.
    delivered: bool = false,

    pub fn durationMs(self: Job, now_ms: i64) u64 {
        const end = self.ended_ms orelse now_ms;
        return if (end > self.started_ms) @intCast(end - self.started_ms) else 0;
    }
};

/// A settled job's result, reserved for one consumer. The consumer commits
/// `token` once the model has the text, or cancels it so the result stays
/// deliverable.
pub const Settled = struct {
    job: Job,
    text: []const u8,
    token: result_commit.Token,
};

pub const Logs = struct {
    text: []const u8,
    retained_bytes: usize,
    total_bytes: usize,
    handle: ?[]const u8 = null,
};

pub const CancelStatus = enum { settled, requested, already_settled };

pub const Cancelled = struct {
    status: CancelStatus,
    /// The cancelled job's final result when cancelling consumed it.
    settled: ?Settled = null,
};

/// How a source answers for its jobs. Every function is safe from any
/// thread; the registry calls `reserve` while it holds its lock.
pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        kind: Kind,
        owns: *const fn (id: []const u8) bool,
        list: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]Job,
        /// The job's settled result, or null while it runs, after it was
        /// delivered, or while another consumer holds it.
        reserve: *const fn (ctx: *anyopaque, arena: Allocator, id: []const u8) anyerror!?Settled,
        logs: *const fn (ctx: *anyopaque, arena: Allocator, id: []const u8, max_bytes: usize) anyerror!Logs,
        cancel: *const fn (ctx: *anyopaque, arena: Allocator, id: []const u8, force: bool) anyerror!Cancelled,
    };
};

pub const max_sources = 4;
pub const max_wait_targets = 32;
const wait_poll_ms = 50;

pub const Registry = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    sources: [max_sources]Source = undefined,
    source_count: usize = 0,
    /// Job ids an explicit wait holds, counted so overlapping waits keep
    /// automatic delivery off until the last one ends.
    leases: std.array_hash_map.String(u32) = .empty,
    /// Takes back a queued notice that holds a job's result, so a wait gets
    /// it instead (`host.zig`).
    reclaimer: ?Reclaimer = null,
    /// Starts watches (D190); null where the host keeps none.
    watches: ?*watch_source.Source = null,
    /// Waits on the session's mailbox for `jobs wait` (D189); null where
    /// the session has no agents to message it.
    mailbox: ?MailboxPort = null,

    pub const Reclaimer = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, job_id: []const u8) bool,
    };

    /// One message a mailbox wait took. Strings borrow the caller's arena.
    pub const MailMessage = struct {
        id: []const u8,
        from: []const u8,
        label: []const u8,
        body: []const u8,
        reply_to: ?[]const u8 = null,
        broadcast: bool = false,
    };

    pub const MailboxPort = struct {
        ctx: *anyopaque,
        /// Waits up to `timeout_ms` for messages, from `from` when given,
        /// and takes them as read; empty when the window passed.
        wait: *const fn (ctx: *anyopaque, arena: Allocator, from: ?[]const u8, timeout_ms: u64, cancel: ?*const std.atomic.Value(bool)) anyerror![]MailMessage,
    };

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        for (self.leases.keys()) |key| self.alloc.free(key);
        self.leases.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn addSource(self: *Registry, source: Source) void {
        std.debug.assert(self.source_count < max_sources);
        self.sources[self.source_count] = source;
        self.source_count += 1;
    }

    fn sourceFor(self: *Registry, id: []const u8) ?Source {
        for (self.sources[0..self.source_count]) |source| if (source.vtable.owns(id)) return source;
        return null;
    }

    /// Every job, running first, then failed, cancelled and completed.
    pub fn list(self: *Registry, arena: Allocator) ![]Job {
        var all: std.ArrayList(Job) = .empty;
        for (self.sources[0..self.source_count]) |source| {
            try all.appendSlice(arena, try source.vtable.list(source.ctx, arena));
        }
        std.mem.sort(Job, all.items, {}, lessThan);
        return all.items;
    }

    fn lessThan(_: void, a: Job, b: Job) bool {
        if (a.state.rank() != b.state.rank()) return a.state.rank() < b.state.rank();
        return a.started_ms < b.started_ms;
    }

    pub fn find(self: *Registry, arena: Allocator, id: []const u8) !?Job {
        const source = self.sourceFor(id) orelse return null;
        for (try source.vtable.list(source.ctx, arena)) |job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    pub fn runningCount(self: *Registry, arena: Allocator) usize {
        var count: usize = 0;
        for (self.list(arena) catch return 0) |job| {
            if (!job.state.settled()) count += 1;
        }
        return count;
    }

    pub fn logs(self: *Registry, arena: Allocator, id: []const u8, max_bytes: usize) !Logs {
        const source = self.sourceFor(id) orelse return error.UnknownJob;
        return source.vtable.logs(source.ctx, arena, id, max_bytes);
    }

    pub fn cancel(self: *Registry, arena: Allocator, id: []const u8, force: bool) !Cancelled {
        const source = self.sourceFor(id) orelse return error.UnknownJob;
        return source.vtable.cancel(source.ctx, arena, id, force);
    }

    /// Reserves every settled, undelivered job no wait holds, for one
    /// automatic delivery. The caller commits or cancels each token.
    pub fn takeDeliveries(self: *Registry, arena: Allocator) ![]Settled {
        const zio = io_mod.getIo();
        var taken: std.ArrayList(Settled) = .empty;
        errdefer for (taken.items) |item| item.token.cancel();
        const jobs = try self.list(arena);
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (jobs) |job| {
            if (!job.state.settled() or job.delivered) continue;
            if (self.leases.get(job.id) != null) continue;
            const source = self.sourceFor(job.id) orelse continue;
            const settled = (try source.vtable.reserve(source.ctx, arena, job.id)) orelse continue;
            try taken.append(arena, settled);
        }
        return taken.items;
    }

    pub const WaitOutcome = struct {
        settled: []Settled,
        /// Targets still running when the wait returned.
        pending: []Job,
        timed_out: bool,
    };

    /// Waits until a target settles, `timeout_ms` passes (0 waits until
    /// woken), or `cancel_flag` is set. Null `targets` waits on every job
    /// running now. While it waits it holds a lease on its targets, so
    /// automatic delivery leaves them to it; whatever it does not consume
    /// is delivered automatically after it returns.
    pub fn wait(
        self: *Registry,
        arena: Allocator,
        targets: ?[]const []const u8,
        timeout_ms: u64,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !WaitOutcome {
        const ids = try self.resolveTargets(arena, targets);
        if (ids.len == 0) return .{ .settled = &.{}, .pending = &.{}, .timed_out = false };
        try self.acquireLeases(ids);
        defer self.releaseLeases(ids);
        const started = io_mod.milliTimestamp();
        while (true) {
            // A result a notice queued but the model has not read yet goes
            // to this wait instead.
            if (self.reclaimer) |reclaimer| for (ids) |id| {
                _ = reclaimer.func(reclaimer.ctx, id);
            };
            const settled = try self.reserveTargets(arena, ids);
            if (settled.len > 0) return .{ .settled = settled, .pending = try self.pendingTargets(arena, ids), .timed_out = false };
            const pending = try self.pendingTargets(arena, ids);
            // Every target was already delivered elsewhere.
            if (pending.len == 0) return .{ .settled = &.{}, .pending = &.{}, .timed_out = false };
            if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
            if (timeout_ms > 0 and io_mod.milliTimestamp() - started >= @as(i64, @intCast(timeout_ms))) {
                return .{ .settled = &.{}, .pending = pending, .timed_out = true };
            }
            io_mod.sleep(wait_poll_ms * std.time.ns_per_ms);
        }
    }

    fn resolveTargets(self: *Registry, arena: Allocator, targets: ?[]const []const u8) ![]const []const u8 {
        if (targets) |ids| {
            if (ids.len > max_wait_targets) return error.TooManyTargets;
            for (ids) |id| if ((try self.find(arena, id)) == null) return error.UnknownJob;
            return ids;
        }
        var running: std.ArrayList([]const u8) = .empty;
        for (try self.list(arena)) |job| {
            if (!job.state.settled() and running.items.len < max_wait_targets) try running.append(arena, job.id);
        }
        return running.items;
    }

    fn reserveTargets(self: *Registry, arena: Allocator, ids: []const []const u8) ![]Settled {
        const zio = io_mod.getIo();
        var taken: std.ArrayList(Settled) = .empty;
        errdefer for (taken.items) |item| item.token.cancel();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (ids) |id| {
            const source = self.sourceFor(id) orelse continue;
            const settled = (try source.vtable.reserve(source.ctx, arena, id)) orelse continue;
            try taken.append(arena, settled);
        }
        return taken.items;
    }

    fn pendingTargets(self: *Registry, arena: Allocator, ids: []const []const u8) ![]Job {
        var pending: std.ArrayList(Job) = .empty;
        for (ids) |id| {
            const job = (try self.find(arena, id)) orelse continue;
            if (!job.state.settled()) try pending.append(arena, job);
        }
        return pending.items;
    }

    fn acquireLeases(self: *Registry, ids: []const []const u8) !void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (ids, 0..) |id, index| {
            errdefer self.releaseLeasesLocked(ids[0..index]);
            const entry = try self.leases.getOrPut(self.alloc, id);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
                continue;
            }
            entry.key_ptr.* = self.alloc.dupe(u8, id) catch |err| {
                _ = self.leases.swapRemove(id);
                return err;
            };
            entry.value_ptr.* = 1;
        }
    }

    fn releaseLeases(self: *Registry, ids: []const []const u8) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.releaseLeasesLocked(ids);
    }

    fn releaseLeasesLocked(self: *Registry, ids: []const []const u8) void {
        for (ids) |id| {
            const index = self.leases.getIndex(id) orelse continue;
            const count = &self.leases.values()[index];
            if (count.* > 1) {
                count.* -= 1;
                continue;
            }
            const key = self.leases.keys()[index];
            self.leases.swapRemoveAt(index);
            self.alloc.free(key);
        }
    }

    pub fn leased(self: *Registry, id: []const u8) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.leases.get(id) != null;
    }
};

/// Commits several reservations as one result: the tool result that carries
/// a wait's settled jobs. Owns itself; commit or cancel frees it.
pub const Batch = struct {
    alloc: Allocator,
    tokens: []result_commit.Token,

    /// The single token that settles every one of `settled`. Null when there
    /// is nothing to settle.
    pub fn token(alloc: Allocator, settled: []const Settled) !?result_commit.Token {
        if (settled.len == 0) return null;
        if (settled.len == 1) return settled[0].token;
        const self = try alloc.create(Batch);
        errdefer alloc.destroy(self);
        const tokens = try alloc.alloc(result_commit.Token, settled.len);
        for (settled, tokens) |item, *slot| slot.* = item.token;
        self.* = .{ .alloc = alloc, .tokens = tokens };
        return .{ .context = self, .identity = 0, .commit_fn = commitAll, .cancel_fn = cancelAll };
    }

    fn commitAll(raw: *anyopaque, _: u64) anyerror!void {
        const self: *Batch = @ptrCast(@alignCast(raw));
        defer self.destroy();
        var first_error: ?anyerror = null;
        for (self.tokens) |item| item.commit() catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
    }

    fn cancelAll(raw: *anyopaque, _: u64) void {
        const self: *Batch = @ptrCast(@alignCast(raw));
        defer self.destroy();
        for (self.tokens) |item| item.cancel();
    }

    fn destroy(self: *Batch) void {
        const alloc = self.alloc;
        alloc.free(self.tokens);
        alloc.destroy(self);
    }
};

/// Formats a duration the way job rows show it: 850ms, 4.1s, 1m2s, 2m,
/// 1h5m, 2d3h.
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    if (ms < 1000) return std.mem.print(buf, "{d}ms", .{ms}) catch buf[0..0];
    if (s < 60) return std.mem.print(buf, "{d}.{d}s", .{ s, (ms % 1000) / 100 }) catch buf[0..0];
    const m = s / 60;
    if (m < 60) {
        if (s % 60 == 0) return std.mem.print(buf, "{d}m", .{m}) catch buf[0..0];
        return std.mem.print(buf, "{d}m{d}s", .{ m, s % 60 }) catch buf[0..0];
    }
    const h = m / 60;
    if (h < 24) {
        if (m % 60 == 0) return std.mem.print(buf, "{d}h", .{h}) catch buf[0..0];
        return std.mem.print(buf, "{d}h{d}m", .{ h, m % 60 }) catch buf[0..0];
    }
    const d = h / 24;
    if (h % 24 == 0) return std.mem.print(buf, "{d}d", .{d}) catch buf[0..0];
    return std.mem.print(buf, "{d}d{d}h", .{ d, h % 24 }) catch buf[0..0];
}

test {
    _ = shell_source;
    _ = turn_source;
    _ = notice;
    _ = card;
    _ = host;
}

test "durations read like proto's job rows" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("850ms", formatDuration(&buf, 850));
    try std.testing.expectEqualStrings("4.1s", formatDuration(&buf, 4_100));
    try std.testing.expectEqualStrings("1m2s", formatDuration(&buf, 62_000));
    try std.testing.expectEqualStrings("2m", formatDuration(&buf, 120_000));
    try std.testing.expectEqualStrings("1h5m", formatDuration(&buf, 3_900_000));
    try std.testing.expectEqualStrings("2d3h", formatDuration(&buf, (2 * 24 + 3) * 3_600_000));
}

const FakeSource = struct {
    state: State = .running,
    delivered: bool = false,
    reserved: bool = false,
    commits: usize = 0,

    const vtable = Source.VTable{ .kind = .shell, .owns = owns, .list = listFn, .reserve = reserveFn, .logs = logsFn, .cancel = cancelFn };

    fn source(self: *FakeSource) Source {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn owns(id: []const u8) bool {
        return std.mem.startsWith(u8, id, "bg_");
    }
    fn listFn(raw: *anyopaque, arena: Allocator) anyerror![]Job {
        const self: *FakeSource = @ptrCast(@alignCast(raw));
        const jobs = try arena.alloc(Job, 1);
        jobs[0] = .{ .id = "bg_1", .kind = .shell, .label = "sleep 1", .state = self.state, .started_ms = 0, .delivered = self.delivered };
        return jobs;
    }
    fn reserveFn(raw: *anyopaque, arena: Allocator, id: []const u8) anyerror!?Settled {
        const self: *FakeSource = @ptrCast(@alignCast(raw));
        if (!self.state.settled() or self.delivered or self.reserved) return null;
        self.reserved = true;
        const jobs = try listFn(raw, arena);
        _ = id;
        return .{ .job = jobs[0], .text = "done", .token = .{ .context = self, .identity = 1, .commit_fn = commitFn, .cancel_fn = cancelTokenFn } };
    }
    fn commitFn(raw: *anyopaque, _: u64) anyerror!void {
        const self: *FakeSource = @ptrCast(@alignCast(raw));
        self.reserved = false;
        self.delivered = true;
        self.commits += 1;
    }
    fn cancelTokenFn(raw: *anyopaque, _: u64) void {
        const self: *FakeSource = @ptrCast(@alignCast(raw));
        self.reserved = false;
    }
    fn logsFn(_: *anyopaque, _: Allocator, _: []const u8, _: usize) anyerror!Logs {
        return .{ .text = "", .retained_bytes = 0, .total_bytes = 0 };
    }
    fn cancelFn(_: *anyopaque, _: Allocator, _: []const u8, _: bool) anyerror!Cancelled {
        return .{ .status = .requested };
    }
};

test "a leased job is left to its wait and delivered once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeSource = .{ .state = .completed };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.addSource(fake.source());

    const ids = [_][]const u8{"bg_1"};
    try registry.acquireLeases(&ids);
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
    const won = try registry.reserveTargets(arena, &ids);
    try std.testing.expectEqual(@as(usize, 1), won.len);
    registry.releaseLeases(&ids);
    // Reserved by the wait: automatic delivery still cannot take it.
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
    try won[0].token.commit();
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
    try std.testing.expectEqual(@as(usize, 1), fake.commits);
}

test "a wait that ends without its result leaves it for automatic delivery" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeSource = .{ .state = .completed };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.addSource(fake.source());

    const ids = [_][]const u8{"bg_1"};
    try registry.acquireLeases(&ids);
    try registry.acquireLeases(&ids);
    const won = try registry.reserveTargets(arena, &ids);
    won[0].token.cancel();
    registry.releaseLeases(&ids);
    try std.testing.expect(registry.leased("bg_1"));
    registry.releaseLeases(&ids);
    try std.testing.expect(!registry.leased("bg_1"));
    const delivered = try registry.takeDeliveries(arena);
    try std.testing.expectEqual(@as(usize, 1), delivered.len);
    try delivered[0].token.commit();
    try std.testing.expectEqual(@as(usize, 1), fake.commits);
}

test "a wait returns a settled target and times out on a running one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeSource = .{};
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.addSource(fake.source());

    const timed = try registry.wait(arena, null, 60, null);
    try std.testing.expect(timed.timed_out);
    try std.testing.expectEqual(@as(usize, 1), timed.pending.len);
    fake.state = .failed;
    const ids = [_][]const u8{"bg_1"};
    const done = try registry.wait(arena, &ids, 0, null);
    try std.testing.expectEqual(@as(usize, 1), done.settled.len);
    try std.testing.expectError(error.UnknownJob, registry.wait(arena, &.{"bg_9x"}, 0, null));
}

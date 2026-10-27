//! A session host's jobs: the registry with its shell and fleet sources,
//! and the async-result notice the host hands to the agent loop when jobs
//! settle with nobody waiting.
//!
//! Delivery follows proto: a notice steers a running turn at its next safe
//! boundary without cutting a streaming reply short, and wakes an idle
//! session with a turn of its own (D111). Until the turn hands a queued
//! notice to the model, a wait on one of its jobs takes it back and gets the
//! result itself, as proto's wait makes a queued delivery stale.
const std = @import("std");
const jobs = @import("jobs.zig");
const io_mod = @import("../shared/io.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const result_commit = @import("../tooling/result_commit.zig");
const turn_jobs = @import("../subagent/turn_jobs.zig");
const Allocator = std.mem.Allocator;

const undelivered_retry_ms = 30_000;

pub const Host = struct {
    registry: jobs.Registry,
    shell: jobs.shell_source.Source,
    turns: jobs.turn_source.Source,
    watches: jobs.watch_source.Source,
    mutex: std.Io.Mutex = .init,
    /// Notices the agent loop admitted and has not yet answered. Their
    /// results stay reserved until the answer says whether the model got
    /// them, so a wait can still take one back (D111).
    queued: std.ArrayList(Queued) = .empty,
    /// Takes a queued steer back before the turn hands it to the model.
    withdraw: ?Withdraw = null,
    /// After the loop answered a notice without delivering it, such as a
    /// turn that failed, the next notice waits until then.
    retry_after_ms: i64 = 0,

    pub const Withdraw = struct {
        ctx: *anyopaque,
        /// True when the steer was still queued and is now gone.
        func: *const fn (ctx: *anyopaque, request_id: i64) bool,
    };

    const Queued = struct {
        request_id: i64,
        tokens: []result_commit.Token,
        job_ids: [][]u8,

        fn free(self: Queued, alloc: Allocator) void {
            alloc.free(self.tokens);
            for (self.job_ids) |id| alloc.free(id);
            alloc.free(self.job_ids);
        }
    };

    /// `self` must not move afterwards: the registry points at its sources.
    pub fn init(
        self: *Host,
        alloc: Allocator,
        executions: *managed_execution.Runtime,
        turn_runtime: ?*const ?*turn_jobs.Runtime,
    ) void {
        self.* = .{
            .registry = jobs.Registry.init(alloc),
            .shell = .{ .runtime = executions },
            .turns = jobs.turn_source.Source.init(alloc, turn_runtime),
            .watches = undefined,
        };
        self.watches = jobs.watch_source.Source.init(alloc, &self.registry);
        self.registry.addSource(self.shell.source());
        self.registry.addSource(self.turns.source());
        self.registry.addSource(self.watches.source());
        self.registry.watches = &self.watches;
        self.registry.reclaimer = .{ .ctx = self, .func = reclaim };
    }

    /// Frees the bookkeeping only: the sources' runtimes may already be gone.
    pub fn deinit(self: *Host) void {
        const alloc = self.registry.alloc;
        // Watch threads read the registry: stop them first.
        self.watches.deinit();
        for (self.queued.items) |queued| queued.free(alloc);
        self.queued.deinit(alloc);
        self.registry.deinit();
        self.turns.deinit();
        self.* = undefined;
    }

    pub fn runningCount(self: *Host) usize {
        var arena_state = std.heap.ArenaAllocator.init(self.registry.alloc);
        defer arena_state.deinit();
        return self.registry.runningCount(arena_state.allocator());
    }

    /// The notice for jobs that settled with nobody waiting, or null. The
    /// caller hands `text` to the agent loop and then calls `admitted` with
    /// its request id, or releases the notice when the loop refused it.
    pub fn takeNotice(self: *Host, arena: Allocator) !?Notice {
        if (io_mod.milliTimestamp() < self.retry_after_ms) return null;
        const settled = try self.registry.takeDeliveries(arena);
        if (settled.len == 0) return null;
        errdefer for (settled) |item| item.token.cancel();
        const built = (try jobs.notice.build(arena, settled, io_mod.milliTimestamp())).?;
        const tokens = try arena.alloc(result_commit.Token, built.used);
        const ids = try arena.alloc([]const u8, built.used);
        for (settled[0..built.used], tokens, ids) |item, *token, *id| {
            token.* = item.token;
            id.* = item.job.id;
        }
        for (settled[built.used..]) |item| item.token.cancel();
        return .{ .text = built.text, .tokens = tokens, .job_ids = ids };
    }

    /// The loop admitted `notice` as request `request_id`: its results stay
    /// reserved until `answered`. Without memory to track it, the notice
    /// counts as delivered, which keeps it from reaching the model twice.
    pub fn admitted(self: *Host, notice: Notice, request_id: i64) void {
        self.track(notice, request_id) catch notice.commit();
    }

    fn track(self: *Host, notice: Notice, request_id: i64) !void {
        const alloc = self.registry.alloc;
        const tokens = try alloc.dupe(result_commit.Token, notice.tokens);
        errdefer alloc.free(tokens);
        const ids = try alloc.alloc([]u8, notice.job_ids.len);
        var filled: usize = 0;
        errdefer {
            for (ids[0..filled]) |id| alloc.free(id);
            alloc.free(ids);
        }
        for (notice.job_ids, ids) |id, *slot| {
            slot.* = try alloc.dupe(u8, id);
            filled += 1;
        }
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try self.queued.append(alloc, .{ .request_id = request_id, .tokens = tokens, .job_ids = ids });
    }

    /// The loop answered notice `request_id`: `delivered` when the model got
    /// it, as a steer the turn took or the prompt of a turn it ran.
    pub fn answered(self: *Host, request_id: i64, delivered: bool) void {
        const queued = self.takeQueued(request_id, null) orelse return;
        defer queued.free(self.registry.alloc);
        if (delivered) {
            for (queued.tokens) |token| token.commit() catch {};
        } else {
            for (queued.tokens) |token| token.cancel();
            self.retry_after_ms = io_mod.milliTimestamp() + undelivered_retry_ms;
        }
    }

    fn takeQueued(self: *Host, request_id: ?i64, job_id: ?[]const u8) ?Queued {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.queued.items, 0..) |queued, index| {
            const matches = if (request_id) |id| queued.request_id == id else for (queued.job_ids) |id| {
                if (std.mem.eql(u8, id, job_id.?)) break true;
            } else false;
            if (matches) return self.queued.orderedRemove(index);
        }
        return null;
    }

    /// A wait started on `job_id`: take its queued notice back, if the turn
    /// has not handed it to the model, so the result goes to the wait. The
    /// notice's other jobs are delivered again later. True when it did.
    fn reclaim(raw: *anyopaque, job_id: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        const withdraw = self.withdraw orelse return false;
        const queued = self.takeQueued(null, job_id) orelse return false;
        if (!withdraw.func(withdraw.ctx, queued.request_id)) {
            // Already with the model: it stays queued until its answer.
            const zio = io_mod.getIo();
            self.mutex.lockUncancelable(zio);
            defer self.mutex.unlock(zio);
            self.queued.append(self.registry.alloc, queued) catch {
                for (queued.tokens) |token| token.commit() catch {};
                queued.free(self.registry.alloc);
            };
            return false;
        }
        defer queued.free(self.registry.alloc);
        for (queued.tokens) |token| token.cancel();
        return true;
    }
};

/// How long a shell command runs before it becomes a background job:
/// `FX_AUTO_BACKGROUND_MS`, or proto's minute. 0 backgrounds at once.
pub fn autoBackgroundMs() u32 {
    const contract = @import("../execution/managed_execution_contract.zig");
    const raw = io_mod.getenv("FX_AUTO_BACKGROUND_MS") orelse return contract.default_auto_background_ms;
    const value = std.fmt.parseUnsigned(u32, raw, 10) catch return contract.default_auto_background_ms;
    return @min(value, contract.max_auto_background_ms);
}

pub const Notice = struct {
    text: []const u8,
    tokens: []const result_commit.Token,
    job_ids: []const []const u8 = &.{},

    pub fn commit(self: Notice) void {
        for (self.tokens) |token| token.commit() catch {};
    }

    pub fn release(self: Notice) void {
        for (self.tokens) |token| token.cancel();
    }
};

const TestSource = struct {
    delivered: bool = false,
    reserved: bool = false,
    commits: usize = 0,

    const vtable = jobs.Source.VTable{ .kind = .shell, .owns = owns, .list = list, .reserve = reserve, .logs = logs, .cancel = cancel };
    fn owns(id: []const u8) bool {
        return std.mem.eql(u8, id, "bg_1");
    }
    fn list(raw: *anyopaque, arena: Allocator) anyerror![]jobs.Job {
        const self: *TestSource = @ptrCast(@alignCast(raw));
        const out = try arena.alloc(jobs.Job, 1);
        out[0] = .{ .id = "bg_1", .kind = .shell, .label = "make", .state = .completed, .started_ms = 0, .ended_ms = 10, .delivered = self.delivered };
        return out;
    }
    fn reserve(raw: *anyopaque, arena: Allocator, _: []const u8) anyerror!?jobs.Settled {
        const self: *TestSource = @ptrCast(@alignCast(raw));
        if (self.delivered or self.reserved) return null;
        self.reserved = true;
        return .{ .job = (try list(raw, arena))[0], .text = "exit 0", .token = .{ .context = self, .identity = 0, .commit_fn = commit, .cancel_fn = release } };
    }
    fn commit(raw: *anyopaque, _: u64) anyerror!void {
        const self: *TestSource = @ptrCast(@alignCast(raw));
        self.reserved = false;
        self.delivered = true;
        self.commits += 1;
    }
    fn release(raw: *anyopaque, _: u64) void {
        const self: *TestSource = @ptrCast(@alignCast(raw));
        self.reserved = false;
    }
    fn logs(_: *anyopaque, _: Allocator, _: []const u8, _: usize) anyerror!jobs.Logs {
        return error.Unsupported;
    }
    fn cancel(_: *anyopaque, _: Allocator, _: []const u8, _: bool) anyerror!jobs.Cancelled {
        return error.Unsupported;
    }
};

const TestSteer = struct {
    queued: bool = true,
    fn withdraw(raw: *anyopaque, _: i64) bool {
        const self: *TestSteer = @ptrCast(@alignCast(raw));
        defer self.queued = false;
        return self.queued;
    }
};

fn testHost(host: *Host, source: *TestSource, steer: *TestSteer) void {
    host.* = .{
        .registry = jobs.Registry.init(std.testing.allocator),
        .shell = undefined,
        .turns = jobs.turn_source.Source.init(std.testing.allocator, null),
        .watches = undefined,
        .withdraw = .{ .ctx = steer, .func = TestSteer.withdraw },
    };
    host.watches = jobs.watch_source.Source.init(std.testing.allocator, &host.registry);
    host.registry.addSource(.{ .ctx = source, .vtable = &TestSource.vtable });
    host.registry.reclaimer = .{ .ctx = host, .func = Host.reclaim };
}

test "a wait takes back a notice the turn has not handed to the model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source: TestSource = .{};
    var steer: TestSteer = .{};
    var host: Host = undefined;
    testHost(&host, &source, &steer);
    defer host.deinit();

    const notice = (try host.takeNotice(arena)).?;
    host.admitted(notice, 7);
    const outcome = try host.registry.wait(arena, &.{"bg_1"}, 1_000, null);
    try std.testing.expectEqual(@as(usize, 1), outcome.settled.len);
    try outcome.settled[0].token.commit();
    // The withdrawn steer is never answered; a late answer changes nothing.
    host.answered(7, true);
    try std.testing.expectEqual(@as(usize, 1), source.commits);
}

test "a notice already with the model stays its delivery" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source: TestSource = .{};
    var steer: TestSteer = .{ .queued = false };
    var host: Host = undefined;
    testHost(&host, &source, &steer);
    defer host.deinit();

    host.admitted((try host.takeNotice(arena)).?, 7);
    const outcome = try host.registry.wait(arena, &.{"bg_1"}, 100, null);
    try std.testing.expectEqual(@as(usize, 0), outcome.settled.len);
    host.answered(7, true);
    try std.testing.expectEqual(@as(usize, 1), source.commits);

    // A dropped notice is released and delivered again after the backoff.
    var other: TestSource = .{};
    var host2: Host = undefined;
    testHost(&host2, &other, &steer);
    defer host2.deinit();
    host2.admitted((try host2.takeNotice(arena)).?, 8);
    host2.answered(8, false);
    try std.testing.expect((try host2.takeNotice(arena)) == null);
    host2.retry_after_ms = 0;
    const again = (try host2.takeNotice(arena)).?;
    again.commit();
    try std.testing.expectEqual(@as(usize, 1), other.commits);
}

//! Fleet turn jobs (D112): one job per accepted worker turn, with the id
//! `<node_id>-t<turn>`, where `node_id` is the worker's session id and
//! `turn` its 1-based turn number, reserved when the turn is accepted (a
//! queued turn that is cancelled keeps its number).
//!
//! The fleet owns turn state; this file is what the jobs registry reads:
//! the turns (`turnJobs`, `turnJob`), a hook called when one settles
//! (`setSettleHook`), and the controls `cancelTurn` and `turnLog`. The fleet
//! never hands a turn's result to the model itself: the jobs registry
//! delivers each settled turn once, by its summary handle, a
//! `read_tool_result` handle of the result the fleet stores as it settles.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const tool_host = @import("tool_host.zig");
const fleet_host = @import("fleet_host.zig");

const Allocator = std.mem.Allocator;

pub const State = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,

    pub fn settled(state: State) bool {
        return switch (state) {
            .queued, .running => false,
            .completed, .failed, .cancelled => true,
        };
    }
};

/// One turn job. Slices are owned by the allocator the query was given.
pub const TurnJob = struct {
    id: []const u8,
    /// The worker's session id.
    node_id: []const u8,
    /// The worker's label, its display name.
    label: []const u8,
    /// The kind of agent that runs the turn: `worker` for a spawned one.
    agent: []const u8,
    state: State,
    /// Milliseconds since the epoch; 0 while queued.
    started_ms: i64 = 0,
    /// Null until the job settles.
    ended_ms: ?i64 = null,
    /// The `read_tool_result` handle of the whole result when it was too
    /// long to deliver inline; null otherwise.
    summary_handle: ?[]const u8 = null,
    turn: u32,
    /// The settled result the parent reads, in the fleet tool's result
    /// form; null until the job settles.
    result: ?[]const u8 = null,
    /// The first line of the turn's message, for cards.
    message_preview: []const u8 = "",
};

/// The subagent host whose workers' turns these are.
pub const Runtime = tool_host.Runtime;

/// Called on the worker's own thread once the job's state and summary
/// handle are visible through `turnJob`. It must not block.
pub const SettleHook = struct {
    ctx: *anyopaque,
    settled: *const fn (ctx: *anyopaque, job_id: []const u8) void,
};

/// Every turn job of `runtime`'s workers, oldest first. Owned by `arena`.
pub fn turnJobs(arena: Allocator, runtime: *Runtime) ![]TurnJob {
    return runtime.fleet.snapshot(arena);
}

/// The job `id` of `runtime`'s workers, or null. Owned by `arena`.
pub fn turnJob(arena: Allocator, runtime: *Runtime, id: []const u8) !?TurnJob {
    return runtime.fleet.get(arena, id);
}

/// Installs the hook called when a turn settles; null removes it.
pub fn setSettleHook(runtime: *Runtime, hook: ?SettleHook) void {
    runtime.fleet.setHook(hook);
}

/// Whether `id` names a turn job: `<node_id>-t<digits>`.
pub fn isTurnJobId(id: []const u8) bool {
    return parseId(id) != null;
}

/// Moves whenever any job is accepted, starts or settles.
pub fn generation(runtime: *Runtime) u64 {
    return runtime.fleet.currentGeneration();
}

/// Waits until the generation differs from `seen`, or `timeout_ms` passes,
/// or `cancel` is set; returns the generation it saw last.
pub fn waitChange(runtime: *Runtime, seen: u64, timeout_ms: u64, cancel: ?*const std.atomic.Value(bool)) u64 {
    return runtime.fleet.waitChange(seen, timeout_ms, cancel);
}

pub const CancelOutcome = enum { cancelled, already_settled, unknown };

/// Cancels one turn: a queued one leaves the worker's queue, a running one
/// stops at its next safe point. The worker stays addressable.
pub fn cancelTurn(runtime: *Runtime, id: []const u8) !CancelOutcome {
    return fleet_host.cancelTurn(runtime, id);
}

/// A bounded log of turn `id`: its message, state and, once settled, the
/// start of its result. Null when unknown. Owned by `arena`.
pub fn turnLog(arena: Allocator, runtime: *Runtime, id: []const u8, max_bytes: usize) !?[]const u8 {
    const job = (try runtime.fleet.get(arena, id)) orelse return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s} · {s} · turn {d} of worker {s}\n> {s}\n", .{ job.id, @tagName(job.state), job.turn, job.label, job.message_preview });
    if (job.result) |result| try out.writer.writeAll(result);
    const text = out.written();
    if (text.len <= max_bytes) return text;
    var cut_at = max_bytes;
    while (cut_at > 0 and (text[cut_at] & 0xC0) == 0x80) cut_at -= 1;
    return text[0..cut_at];
}

/// Writes `<node_id>-t<turn>` into `buf`.
pub fn formatId(buf: []u8, node_id: []const u8, turn: u32) ![]const u8 {
    return std.mem.print(buf, "{s}-t{d}", .{ node_id, turn });
}

pub const ParsedId = struct { node_id: []const u8, turn: u32 };

/// Splits a job id into its worker and turn; null when it is not one.
pub fn parseId(id: []const u8) ?ParsedId {
    const dash = std.mem.findLast(u8, id, "-t") orelse return null;
    if (dash == 0) return null;
    const turn = std.fmt.parseInt(u32, id[dash + 2 ..], 10) catch return null;
    if (turn == 0) return null;
    return .{ .node_id = id[0..dash], .turn = turn };
}

/// The most jobs one host remembers; the oldest delivered ones go first.
pub const max_jobs: usize = 256;

/// The jobs of one node's workers, kept by its host (`tool_host.Runtime`).
/// Thread safe: workers settle jobs from their own threads.
pub const Ledger = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    generation: std.atomic.Value(u64) = .init(0),
    hook: ?SettleHook = null,

    const Entry = struct {
        id: []u8,
        node_id: []u8,
        label: []u8,
        work_id: []u8,
        preview: []u8,
        turn: u32,
        state: State,
        started_ms: i64 = 0,
        ended_ms: i64 = 0,
        result: ?[]u8 = null,
        handle: ?[]u8 = null,

        fn deinit(self: Entry, alloc: Allocator) void {
            alloc.free(self.id);
            alloc.free(self.node_id);
            alloc.free(self.label);
            alloc.free(self.work_id);
            alloc.free(self.preview);
            if (self.result) |value| alloc.free(value);
            if (self.handle) |value| alloc.free(value);
        }

        fn view(self: Entry, alloc: Allocator) !TurnJob {
            const id = try alloc.dupe(u8, self.id);
            errdefer alloc.free(id);
            const node_id = try alloc.dupe(u8, self.node_id);
            errdefer alloc.free(node_id);
            const label = try alloc.dupe(u8, self.label);
            errdefer alloc.free(label);
            const preview = try alloc.dupe(u8, self.preview);
            errdefer alloc.free(preview);
            const result = if (self.result) |value| try alloc.dupe(u8, value) else null;
            errdefer if (result) |value| alloc.free(value);
            return .{
                .id = id,
                .node_id = node_id,
                .label = label,
                .agent = "worker",
                .state = self.state,
                .started_ms = self.started_ms,
                .ended_ms = if (self.state.settled()) self.ended_ms else null,
                .summary_handle = if (self.handle) |value| try alloc.dupe(u8, value) else null,
                .turn = self.turn,
                .result = result,
                .message_preview = preview,
            };
        }
    };

    pub const Accept = struct {
        node_id: []const u8,
        label: []const u8,
        work_id: []const u8,
        turn: u32,
        message: []const u8,
        state: State,
        now_ms: i64,
    };

    pub fn init(alloc: Allocator) Ledger {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.entries.items) |entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    fn bump(self: *Ledger) void {
        _ = self.generation.fetchAdd(1, .seq_cst);
    }

    /// Records an accepted turn. A job already known by its work keeps its
    /// state, so a replayed call changes nothing.
    pub fn accept(self: *Ledger, input: Accept) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.work_id, input.work_id)) return;
        self.pruneLocked();
        var buf: [96]u8 = undefined;
        const id = try self.alloc.dupe(u8, try formatId(&buf, input.node_id, input.turn));
        errdefer self.alloc.free(id);
        const node_id = try self.alloc.dupe(u8, input.node_id);
        errdefer self.alloc.free(node_id);
        const label = try self.alloc.dupe(u8, input.label);
        errdefer self.alloc.free(label);
        const work_id = try self.alloc.dupe(u8, input.work_id);
        errdefer self.alloc.free(work_id);
        const preview = try self.alloc.dupe(u8, firstLine(input.message, 160));
        errdefer self.alloc.free(preview);
        try self.entries.append(self.alloc, .{
            .id = id,
            .node_id = node_id,
            .label = label,
            .work_id = work_id,
            .preview = preview,
            .turn = input.turn,
            .state = input.state,
            .started_ms = if (input.state == .running) input.now_ms else 0,
        });
        self.bump();
    }

    /// A queued turn began to run.
    pub fn start(self: *Ledger, work_id: []const u8, now_ms: i64) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.findWorkLocked(work_id) orelse return;
        if (entry.state != .queued) return;
        entry.state = .running;
        entry.started_ms = now_ms;
        self.bump();
    }

    /// Settles the job of `work_id` once; `result` and `handle` are copied.
    pub fn settle(self: *Ledger, work_id: []const u8, state: State, result: []const u8, handle: ?[]const u8, now_ms: i64) !void {
        std.debug.assert(state.settled());
        const hook, const job_id = blk: {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            const entry = self.findWorkLocked(work_id) orelse return;
            if (entry.state.settled()) return;
            const owned = try self.alloc.dupe(u8, result);
            errdefer self.alloc.free(owned);
            entry.handle = if (handle) |value| try self.alloc.dupe(u8, value) else null;
            entry.result = owned;
            entry.state = state;
            if (entry.started_ms == 0) entry.started_ms = now_ms;
            entry.ended_ms = now_ms;
            self.bump();
            break :blk .{ self.hook, entry.id };
        };
        // Only settled entries are pruned, by `accept`, so this one stays.
        if (hook) |value| value.settled(value.ctx, job_id);
    }

    pub fn snapshot(self: *Ledger, alloc: Allocator) ![]TurnJob {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var out: std.ArrayList(TurnJob) = .empty;
        errdefer {
            for (out.items) |job| freeJob(alloc, job);
            out.deinit(alloc);
        }
        for (self.entries.items) |entry| {
            const job = try entry.view(alloc);
            out.append(alloc, job) catch |err| {
                freeJob(alloc, job);
                return err;
            };
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn get(self: *Ledger, alloc: Allocator, id: []const u8) !?TurnJob {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.id, id)) return try entry.view(alloc);
        return null;
    }

    /// Whether a job tracks the work `work_id`.
    pub fn has(self: *Ledger, work_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.findWorkLocked(work_id) != null;
    }

    /// Whether any job is queued or running.
    pub fn active(self: *Ledger) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (!entry.state.settled()) return true;
        return false;
    }

    /// The work and worker of job `id`, copied into `arena`.
    pub fn workOf(self: *Ledger, arena: Allocator, id: []const u8) !?struct { work_id: []const u8, node_id: []const u8, state: State } {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.id, id)) return .{
            .work_id = try arena.dupe(u8, entry.work_id),
            .node_id = try arena.dupe(u8, entry.node_id),
            .state = entry.state,
        };
        return null;
    }

    /// A terminated worker's queued jobs settle as cancelled with `result`
    /// (D113).
    pub fn discardWorker(self: *Ledger, node_id: []const u8, result: []const u8, now_ms: i64) !void {
        var work_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (work_ids.items) |id| self.alloc.free(id);
            work_ids.deinit(self.alloc);
        }
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.entries.items) |entry| {
                if (entry.state != .queued or !std.mem.eql(u8, entry.node_id, node_id)) continue;
                try work_ids.append(self.alloc, try self.alloc.dupe(u8, entry.work_id));
            }
        }
        for (work_ids.items) |work_id| try self.settle(work_id, .cancelled, result, null, now_ms);
    }

    pub fn currentGeneration(self: *Ledger) u64 {
        return self.generation.load(.seq_cst);
    }

    pub fn waitChange(self: *Ledger, seen: u64, timeout_ms: u64, cancel: ?*const std.atomic.Value(bool)) u64 {
        const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
        while (true) {
            const now = self.generation.load(.seq_cst);
            if (now != seen) return now;
            if (cancel) |flag| if (flag.load(.seq_cst)) return now;
            if (io_mod.milliTimestamp() >= deadline) return now;
            io_mod.sleep(20 * std.time.ns_per_ms);
        }
    }

    pub fn setHook(self: *Ledger, hook: ?SettleHook) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.hook = hook;
    }

    fn findWorkLocked(self: *Ledger, work_id: []const u8) ?*Entry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.work_id, work_id)) return entry;
        return null;
    }

    /// Drops the oldest settled jobs once the ledger is full.
    fn pruneLocked(self: *Ledger) void {
        var index: usize = 0;
        while (self.entries.items.len >= max_jobs and index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (entry.state.settled()) {
                entry.deinit(self.alloc);
                _ = self.entries.orderedRemove(index);
            } else index += 1;
        }
    }
};

pub fn freeJob(alloc: Allocator, job: TurnJob) void {
    alloc.free(job.id);
    alloc.free(job.node_id);
    alloc.free(job.label);
    alloc.free(job.message_preview);
    if (job.summary_handle) |value| alloc.free(value);
    if (job.result) |value| alloc.free(value);
}

pub fn freeJobs(alloc: Allocator, jobs: []TurnJob) void {
    for (jobs) |job| freeJob(alloc, job);
    alloc.free(jobs);
}

/// The first line of `text`, at most `max` bytes on a UTF-8 boundary.
fn firstLine(text: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len;
    var line = trimmed[0..end];
    if (line.len <= max) return line;
    var cut = max;
    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
    line = line[0..cut];
    return line;
}

test "job ids name the worker and its turn" {
    var buf: [64]u8 = undefined;
    const id = try formatId(&buf, "01JABCDEFGHJKMNPQRSTVWXYZ0", 3);
    try std.testing.expectEqualStrings("01JABCDEFGHJKMNPQRSTVWXYZ0-t3", id);
    const parsed = parseId(id).?;
    try std.testing.expectEqualStrings("01JABCDEFGHJKMNPQRSTVWXYZ0", parsed.node_id);
    try std.testing.expectEqual(@as(u32, 3), parsed.turn);
    try std.testing.expect(parseId("bg_3") == null);
    try std.testing.expect(parseId("x-t0") == null);
}

test "a turn settles once and calls its hook" {
    const alloc = std.testing.allocator;
    var ledger = Ledger.init(alloc);
    defer ledger.deinit();
    const Counter = struct {
        calls: usize = 0,
        fn settled(ctx: *anyopaque, job_id: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            std.debug.assert(std.mem.eql(u8, job_id, "w-t1"));
        }
    };
    var counter: Counter = .{};
    ledger.setHook(.{ .ctx = &counter, .settled = Counter.settled });
    try ledger.accept(.{ .node_id = "w", .label = "parser", .work_id = "op1", .turn = 1, .message = "fix it\nmore", .state = .running, .now_ms = 10 });
    try ledger.accept(.{ .node_id = "w", .label = "parser", .work_id = "op2", .turn = 2, .message = "then this", .state = .queued, .now_ms = 11 });
    try ledger.accept(.{ .node_id = "w", .label = "parser", .work_id = "op1", .turn = 9, .message = "replay", .state = .queued, .now_ms = 12 });
    try std.testing.expect(ledger.active());
    const before = ledger.currentGeneration();
    try ledger.settle("op1", .completed, "{\"ok\":true}", "h1", 20);
    try std.testing.expect(ledger.currentGeneration() != before);
    try ledger.settle("op1", .failed, "{\"ok\":false}", null, 21);
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    {
        const job = (try ledger.get(alloc, "w-t1")).?;
        defer freeJob(alloc, job);
        try std.testing.expectEqual(State.completed, job.state);
        try std.testing.expectEqualStrings("fix it", job.message_preview);
        try std.testing.expectEqualStrings("h1", job.summary_handle.?);
        try std.testing.expectEqual(@as(?i64, 20), job.ended_ms);
    }
    ledger.setHook(null);
    try ledger.discardWorker("w", "{\"ok\":false}", 31);
    try std.testing.expect(!ledger.active());
    const jobs = try ledger.snapshot(alloc);
    defer freeJobs(alloc, jobs);
    try std.testing.expectEqual(State.cancelled, jobs[1].state);
    try std.testing.expect(isTurnJobId("worker-1a2b-t3"));
    try std.testing.expect(!isTurnJobId("worker-tx"));
}

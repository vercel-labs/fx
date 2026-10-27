//! Fleet turn jobs (D101): one job per accepted worker turn, with the id
//! `<node_id>-t<turn>`, where `node_id` is the worker's session id and
//! `turn` its 1-based turn number, reserved when the turn is accepted (a
//! queued turn that is cancelled keeps its number).
//!
//! The fleet owns turn state; this file is the read-only view the jobs
//! registry reads (`turnJobs`, `turnJob`), the exactly-once hand-off of a
//! settled result (`claim`), and the wait hooks: a generation that moves
//! whenever a job changes (`generation`, `waitChange`) and one listener
//! called when a job settles. A settled result is delivered once: to the
//! caller that claims it, or else to the parent's next step, never both.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const tool_host = @import("tool_host.zig");

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
    /// 0 until the job settles.
    ended_ms: i64 = 0,
    /// The `read_tool_result` handle of the whole result when it was too
    /// long to deliver inline; null otherwise.
    summary_handle: ?[]const u8 = null,
    turn: u32,
    /// The settled result the parent reads, in the fleet tool's result
    /// form; null until the job settles.
    result: ?[]const u8 = null,
    /// The first line of the turn's message, for cards.
    message_preview: []const u8 = "",
    /// The result reached the parent, by a claim or the parent's step.
    delivered: bool = false,
};

/// Called on the worker's own thread, after the job's state is visible
/// through `turnJob`. It must not block.
pub const Listener = struct {
    context: *anyopaque,
    settled_fn: *const fn (context: *anyopaque, node_id: []const u8, job_id: []const u8) void,
};

/// Every turn job of `runtime`'s workers, oldest first. Owned by `alloc`.
pub fn turnJobs(runtime: *tool_host.Runtime, alloc: Allocator) ![]TurnJob {
    return runtime.fleet.snapshot(alloc);
}

/// The job `id` of `runtime`'s workers, or null. Owned by `alloc`.
pub fn turnJob(runtime: *tool_host.Runtime, alloc: Allocator, id: []const u8) !?TurnJob {
    return runtime.fleet.get(alloc, id);
}

/// Takes the settled result of job `id` exactly once: null when the job is
/// unknown, still queued or running, or already delivered.
pub fn claim(runtime: *tool_host.Runtime, alloc: Allocator, id: []const u8) !?TurnJob {
    return runtime.fleet.claim(alloc, id);
}

/// Moves whenever any job is accepted, starts, settles or is delivered.
pub fn generation(runtime: *tool_host.Runtime) u64 {
    return runtime.fleet.currentGeneration();
}

/// Waits until the generation differs from `seen`, or `timeout_ms` passes,
/// or `cancel` is set; returns the generation it saw last.
pub fn waitChange(runtime: *tool_host.Runtime, seen: u64, timeout_ms: u64, cancel: ?*const std.atomic.Value(bool)) u64 {
    return runtime.fleet.waitChange(seen, timeout_ms, cancel);
}

/// Replaces the one settle listener; null removes it.
pub fn setListener(runtime: *tool_host.Runtime, listener: ?Listener) void {
    runtime.fleet.setListener(listener);
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
    listener: ?Listener = null,

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
        delivered: bool = false,

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
                .ended_ms = self.ended_ms,
                .summary_handle = if (self.handle) |value| try alloc.dupe(u8, value) else null,
                .turn = self.turn,
                .result = result,
                .message_preview = preview,
                .delivered = self.delivered,
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
        /// The caller takes the result itself, as a blocking run does.
        delivered: bool = false,
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
            .delivered = input.delivered,
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
        const listener, const node_id, const job_id = blk: {
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
            break :blk .{ self.listener, entry.node_id, entry.id };
        };
        // Entries are pruned only by `accept` on the parent's thread, which
        // cannot run while this worker's turn is still being settled.
        if (listener) |value| value.settled_fn(value.context, node_id, job_id);
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

    pub fn claim(self: *Ledger, alloc: Allocator, id: []const u8) !?TurnJob {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.id, id)) continue;
            if (!entry.state.settled() or entry.delivered) return null;
            const job = try entry.view(alloc);
            entry.delivered = true;
            self.bump();
            return job;
        }
        return null;
    }

    /// Claims every settled, undelivered job, oldest first, for the
    /// parent's next step. Owned by `alloc`.
    pub fn claimSettled(self: *Ledger, alloc: Allocator) ![]TurnJob {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var out: std.ArrayList(TurnJob) = .empty;
        errdefer {
            for (out.items) |job| freeJob(alloc, job);
            out.deinit(alloc);
        }
        for (self.entries.items) |entry| {
            if (!entry.state.settled() or entry.delivered) continue;
            const job = try entry.view(alloc);
            out.append(alloc, job) catch |err| {
                freeJob(alloc, job);
                return err;
            };
        }
        for (self.entries.items) |*entry| {
            if (entry.state.settled()) entry.delivered = true;
        }
        if (out.items.len > 0) self.bump();
        return out.toOwnedSlice(alloc);
    }

    /// Whether any job's result has yet to reach the parent.
    pub fn pendingDelivery(self: *Ledger) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (!entry.delivered) return true;
        return false;
    }

    /// Whether a settled result waits for the parent.
    pub fn settledUndelivered(self: *Ledger) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (entry.state.settled() and !entry.delivered) return true;
        return false;
    }

    /// Whether a job tracks the work `work_id`.
    pub fn has(self: *Ledger, work_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.findWorkLocked(work_id) != null;
    }

    /// A terminated worker's jobs (D102): its queued ones settle as
    /// cancelled with `result`, and none is delivered later, since the
    /// terminate's own result reports them.
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
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.node_id, node_id) and entry.state.settled()) entry.delivered = true;
        }
        self.bump();
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

    pub fn setListener(self: *Ledger, listener: ?Listener) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.listener = listener;
    }

    fn findWorkLocked(self: *Ledger, work_id: []const u8) ?*Entry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.work_id, work_id)) return entry;
        return null;
    }

    /// Drops the oldest delivered jobs once the ledger is full; jobs whose
    /// result has not reached the parent are never dropped.
    fn pruneLocked(self: *Ledger) void {
        var index: usize = 0;
        while (self.entries.items.len >= max_jobs and index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (entry.state.settled() and entry.delivered) {
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

test "a settled job is delivered exactly once" {
    const alloc = std.testing.allocator;
    var ledger = Ledger.init(alloc);
    defer ledger.deinit();
    try ledger.accept(.{ .node_id = "w", .label = "parser", .work_id = "op1", .turn = 1, .message = "fix it\nmore", .state = .running, .now_ms = 10 });
    try ledger.accept(.{ .node_id = "w", .label = "parser", .work_id = "op2", .turn = 2, .message = "then this", .state = .queued, .now_ms = 11 });
    try ledger.accept(.{ .node_id = "w", .label = "parser", .work_id = "op1", .turn = 9, .message = "replay", .state = .queued, .now_ms = 12 });
    try std.testing.expect(ledger.pendingDelivery());
    try std.testing.expect(try ledger.claim(alloc, "w-t1") == null);
    const before = ledger.currentGeneration();
    try ledger.settle("op1", .completed, "{\"ok\":true}", null, 20);
    try std.testing.expect(ledger.currentGeneration() != before);
    try ledger.settle("op1", .failed, "{\"ok\":false}", null, 21);
    const job = (try ledger.claim(alloc, "w-t1")).?;
    defer freeJob(alloc, job);
    try std.testing.expectEqual(State.completed, job.state);
    try std.testing.expectEqualStrings("fix it", job.message_preview);
    try std.testing.expect(try ledger.claim(alloc, "w-t1") == null);
    const rest = try ledger.claimSettled(alloc);
    defer freeJobs(alloc, rest);
    try std.testing.expectEqual(@as(usize, 0), rest.len);
    ledger.start("op2", 30);
    try ledger.discardWorker("x", "{\"ok\":false}", 31);
    {
        const view = (try ledger.get(alloc, "w-t2")).?;
        defer freeJob(alloc, view);
        try std.testing.expectEqual(State.running, view.state);
    }
    try ledger.settle("op2", .cancelled, "{\"ok\":false}", null, 40);
    const settled = try ledger.claimSettled(alloc);
    defer freeJobs(alloc, settled);
    try std.testing.expectEqual(@as(usize, 1), settled.len);
    try std.testing.expect(!ledger.pendingDelivery());
}

//! Fleet turns as jobs, read through `turn_jobs.zig`. Fleet owns a turn's
//! state; this source owns only whether its settled result reached the
//! model, as one reservation at a time per turn.
const std = @import("std");
const jobs = @import("jobs.zig");
const io_mod = @import("../shared/io.zig");
const turn_jobs = @import("../subagent/turn_jobs.zig");
const Allocator = std.mem.Allocator;

/// `open` after a released reservation; entries are never removed, so the
/// index a reservation token holds stays valid.
const Delivery = enum { open, reserved, delivered };

pub const Source = struct {
    alloc: Allocator,
    /// Where the host keeps its subagent runtime, which a session sets when
    /// it opens; read on each use.
    runtime_slot: ?*const ?*turn_jobs.Runtime = null,
    mutex: std.Io.Mutex = .init,
    /// Turn job ids whose result is reserved or delivered, keyed by owned id.
    deliveries: std.array_hash_map.String(Delivery) = .empty,

    const vtable = jobs.Source.VTable{
        .kind = .turn,
        .owns = owns,
        .list = list,
        .reserve = reserve,
        .logs = logs,
        .cancel = cancel,
    };

    pub fn init(alloc: Allocator, runtime_slot: ?*const ?*turn_jobs.Runtime) Source {
        return .{ .alloc = alloc, .runtime_slot = runtime_slot };
    }

    fn runtime(self: *const Source) ?*turn_jobs.Runtime {
        const slot = self.runtime_slot orelse return null;
        return slot.*;
    }

    pub fn deinit(self: *Source) void {
        for (self.deliveries.keys()) |key| self.alloc.free(key);
        self.deliveries.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn source(self: *Source) jobs.Source {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn from(raw: *anyopaque) *Source {
        return @ptrCast(@alignCast(raw));
    }

    fn owns(id: []const u8) bool {
        return turn_jobs.isTurnJobId(id);
    }

    fn list(raw: *anyopaque, arena: Allocator) anyerror![]jobs.Job {
        const self = from(raw);
        const host = self.runtime() orelse return &.{};
        const turns = try turn_jobs.turnJobs(arena, host);
        const result = try arena.alloc(jobs.Job, turns.len);
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (turns, result) |turn, *job| job.* = .{
            .id = turn.id,
            .kind = .turn,
            .label = if (turn.label.len > 0) turn.label else turn.agent,
            .state = jobState(turn.state),
            .started_ms = turn.started_ms,
            .ended_ms = turn.ended_ms,
            .delivered = self.deliveries.get(turn.id) == .delivered,
        };
        return result;
    }

    fn reserve(raw: *anyopaque, arena: Allocator, id: []const u8) anyerror!?jobs.Settled {
        const self = from(raw);
        const host = self.runtime() orelse return null;
        const turn = (try turn_jobs.turnJob(arena, host, id)) orelse return null;
        const state = jobState(turn.state);
        if (!state.settled()) return null;
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const entry = try self.deliveries.getOrPut(self.alloc, id);
        if (entry.found_existing) {
            if (entry.value_ptr.* != .open) return null;
        } else {
            entry.key_ptr.* = self.alloc.dupe(u8, id) catch |err| {
                _ = self.deliveries.swapRemove(id);
                return err;
            };
        }
        entry.value_ptr.* = .reserved;
        const index = entry.index;
        const text = if (turn.summary_handle) |handle|
            try arena.print("Worker {s} turn {s} {s}. Read its summary with read_tool_result handle {s}.", .{ turn.label, id, stateWord(state), handle })
        else
            try arena.print("Worker {s} turn {s} {s}.", .{ turn.label, id, stateWord(state) });
        return .{
            .job = .{ .id = id, .kind = .turn, .label = turn.label, .state = state, .started_ms = turn.started_ms, .ended_ms = turn.ended_ms },
            .text = text,
            .token = .{ .context = self, .identity = index, .commit_fn = commit, .cancel_fn = release },
        };
    }

    fn commit(raw: *anyopaque, index: u64) anyerror!void {
        const self = from(raw);
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const values = self.deliveries.values();
        if (index >= values.len or values[index] != .reserved) return error.UnknownReservation;
        values[index] = .delivered;
    }

    fn release(raw: *anyopaque, index: u64) void {
        const self = from(raw);
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const values = self.deliveries.values();
        if (index >= values.len or values[index] != .reserved) return;
        values[index] = .open;
    }

    fn logs(_: *anyopaque, _: Allocator, _: []const u8, _: usize) anyerror!jobs.Logs {
        return error.TurnLogsUnavailable;
    }

    fn cancel(_: *anyopaque, _: Allocator, _: []const u8, _: bool) anyerror!jobs.Cancelled {
        return error.TurnCancelUnavailable;
    }
};

fn jobState(state: turn_jobs.State) jobs.State {
    return switch (state) {
        .queued => .queued,
        .running => .running,
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
    };
}

fn stateWord(state: jobs.State) []const u8 {
    return switch (state) {
        .completed => "completed",
        .failed => "failed",
        .cancelled => "was cancelled",
        .queued, .running => "is running",
    };
}

test "a turn source without fleet lists nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var turns = Source.init(std.testing.allocator, null);
    defer turns.deinit();
    const listed = try Source.list(&turns, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 0), listed.len);
    try std.testing.expect(Source.owns("worker-1-t2"));
}

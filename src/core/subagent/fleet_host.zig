//! The fleet's worker operations on a node's host (D112, D113): `spawn`
//! and `send` answer with a turn receipt at once, and the turn's result
//! reaches the parent when it settles (`turn_jobs.zig`); `list`, `inspect`
//! and `terminate` read or end workers. `run` and `message` stay in
//! `tool_host.zig`, since they wait for their turn.
const std = @import("std");
const child_state = @import("child_state.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const fleet_state = @import("fleet_state.zig");
const io_mod = @import("../shared/io.zig");
const model_contract = @import("model_contract.zig");
const session_store = @import("../session/session_store.zig");
const tool_host = @import("tool_host.zig");
const turn_jobs = @import("turn_jobs.zig");

const Allocator = std.mem.Allocator;
const Runtime = tool_host.Runtime;
const Result = tool_host.ManagedExecutionResult;
const Child = child_state.Child;

pub const Context = struct {
    operation_id: []const u8,
    options: tool_host.ExecuteOptions,
    child_mode: @import("../shared/types.zig").PermissionMode,
    resolved_model: ?[]const u8,
};

pub fn execute(self: *Runtime, alloc: Allocator, request: *model_contract.Request, ctx: Context) !Result {
    pumpQueues(self);
    return switch (request.*) {
        .spawn => spawn(self, alloc, request.*, ctx),
        .send => |value| send(self, alloc, request.*, value.id, value.message, ctx),
        .list => list(self, alloc, null),
        .inspect => |id| list(self, alloc, id),
        .terminate => |id| terminate(self, alloc, id),
        .run, .message => unreachable,
    };
}

fn encode(alloc: Allocator, result: model_contract.Result) !Result {
    return .{ .success = result.ok, .body = try model_contract.encodeResultAlloc(alloc, result) };
}

fn jobId(arena: Allocator, worker: []const u8, turn: u32) ![]const u8 {
    return arena.print("{s}-t{d}", .{ worker, turn });
}

fn spawn(self: *Runtime, alloc: Allocator, request: model_contract.Request, ctx: Context) !Result {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = request.spawn;
    const fingerprint = model_contract.requestFingerprint(request);
    const defaults = tool_host.effectiveDefaults(ctx.options.defaults, request.override(), ctx.resolved_model);
    self.admission_mutex.lockUncancelable(io_mod.getIo());
    defer self.admission_mutex.unlock(io_mod.getIo());
    const admitted = blk: {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(arena);
        if (registry.findByOperation(ctx.operation_id)) |existing| {
            // The same call again: the same receipt.
            const label = existing.agentName() orelse "worker";
            break :blk .{ try arena.dupe(u8, existing.id), try arena.dupe(u8, label), false };
        }
        if (value.agent) |label| if (registry.findPersistent(label)) |taken| {
            const text = try arena.print("Worker label `{s}` is already used by worker `{s}`. Choose another label, or continue that worker with fleet op \"send\" id `{s}`.", .{ label, taken.id, taken.id });
            return encode(alloc, .{ .ok = false, .error_code = "label_taken", .result = text, .receipt = .rejected });
        };
        if (try self.refuseNewChild(arena, registry)) |refused| {
            return encode(alloc, .{ .ok = false, .error_code = refused.rejected.code, .receipt = .rejected, .result = try arena.print("No worker was spawned: {s}.", .{refused.rejected.code}) });
        }
        const child_id = try session_store.generateSessionId(arena);
        const label = value.agent orelse try generatedLabel(arena, child_id);
        var work = try tool_host.makeManagedWork(arena, ctx.operation_id, fingerprint, request, ctx.options, ctx.child_mode);
        work.turn = 1;
        try registry.appendPersistent(arena, child_id, label, value.instructions orelse "", work);
        registry.children[registry.children.len - 1].turns = 1;
        try self.managed.state_store.save(arena, registry);
        break :blk .{ child_id, label, true };
    };
    const child_id, const label, const fresh = admitted;
    const job = try jobId(arena, child_id, 1);
    if (fresh) {
        try self.ensureManagedChildSession(child_id, ctx.operation_id, defaults);
        try self.fleet.accept(.{ .node_id = child_id, .label = label, .work_id = ctx.operation_id, .turn = 1, .message = value.message, .state = .running, .now_ms = io_mod.milliTimestamp() });
        _ = self.managed.start(child_id) catch |err| {
            try self.fleet.settle(ctx.operation_id, .failed, "{\"ok\":false,\"error_code\":\"start_failed\"}", null, io_mod.milliTimestamp());
            debug_trace.logf("subagent", "fleet spawn start failed child_id={s} err={s}", .{ child_id, @errorName(err) });
            return encode(alloc, .{ .ok = false, .error_code = "start_failed", .receipt = .rejected, .worker = child_id, .label = label });
        };
        if (ctx.options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = ctx.options.invocation_id, .child_id = child_id, .work_id = ctx.operation_id, .phase = .dispatched } });
    }
    const model_note = if (value.model) |model| try arena.print("model `{s}`, ", .{model}) else "";
    const text = try arena.print(
        "Spawned worker `{s}` (label `{s}`, {s}turn 1 job `{s}`); receipt: accepted. The immutable worker id is the only routing address; labels never route. Its result is delivered automatically when the turn settles; to block on it, wait on that job with the jobs tool. Do not poll with list or inspect. Continue it with fleet op \"send\" id `{s}`.",
        .{ child_id, label, model_note, job, child_id },
    );
    return encode(alloc, .{ .ok = true, .result = text, .receipt = .accepted, .worker = child_id, .label = label, .turn = 1, .job = job });
}

/// `worker-` and the last six characters of the worker's id, lowercased.
fn generatedLabel(arena: Allocator, child_id: []const u8) ![]const u8 {
    const tail = child_id[child_id.len -| 6..];
    const label = try arena.alloc(u8, "worker-".len + tail.len);
    @memcpy(label[0.."worker-".len], "worker-");
    for (tail, label["worker-".len..]) |byte, *out| out.* = if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else '-';
    return label;
}

const Target = struct {
    id: []const u8,
    label: []const u8,
    phase: child_state.Phase,
    active_work: ?[]const u8,
    active_turn: u32,
    queued: usize,
};

/// The worker `id` names, or the result to answer with instead.
fn findWorker(arena: Allocator, registry: *child_state.Registry, id: []const u8) !union(enum) { found: *Child, refused: model_contract.Result } {
    if (registry.findById(id)) |child| {
        const label = child.agentName() orelse return .{ .refused = .{
            .ok = false,
            .error_code = "not_a_worker",
            .receipt = .rejected,
            .result = try arena.print("`{s}` is a one-off run, not a worker. Spawn a worker with fleet op \"spawn\".", .{id}),
        } };
        if (child.terminated) return .{ .refused = .{
            .ok = false,
            .error_code = "worker_terminal",
            .receipt = .terminal,
            .worker = child.id,
            .label = label,
            .result = try arena.print("Worker `{s}` (label `{s}`) is terminal; receipt: terminal, reason=explicit-kill. It takes no more input. Recover at history://{s} or agent://{s}, or spawn a new worker.", .{ child.id, label, child.id, child.id }),
        } };
        return .{ .found = child };
    }
    if (registry.findPersistent(id)) |child| return .{ .refused = .{
        .ok = false,
        .error_code = "unknown_worker",
        .receipt = .rejected,
        .result = try arena.print("`{s}` is a label, and labels never route. Address worker `{s}` by its id.", .{ id, child.id }),
    } };
    return .{ .refused = .{
        .ok = false,
        .error_code = "unknown_worker",
        .receipt = .rejected,
        .result = try arena.print("Unknown worker `{s}`. Address a worker this session owns by its id; fleet op \"list\" names them.", .{id}),
    } };
}

fn send(self: *Runtime, alloc: Allocator, request: model_contract.Request, id: []const u8, message: []const u8, ctx: Context) !Result {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fingerprint = model_contract.requestFingerprint(request);
    self.admission_mutex.lockUncancelable(io_mod.getIo());
    defer self.admission_mutex.unlock(io_mod.getIo());
    // Snapshot the worker without holding its registry across a steer: the
    // owner's lock comes before the registry's.
    const target: Target = blk: {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(arena);
        const child = switch (try findWorker(arena, &registry, id)) {
            .found => |child| child,
            .refused => |refused| return encode(alloc, refused),
        };
        // The same call again: the same receipt.
        if (replayedTurn(child.*, ctx.operation_id)) |replayed| {
            const job = try jobId(arena, child.id, replayed.turn);
            return encode(alloc, .{ .ok = true, .receipt = replayed.receipt, .worker = child.id, .label = child.agentName().?, .turn = replayed.turn, .job = job, .result = try arena.print("This send was already accepted as job `{s}`.", .{job}) });
        }
        break :blk .{
            .id = child.id,
            .label = child.agentName().?,
            .phase = child.phase,
            .active_work = if (child.active) |active| active.id else null,
            .active_turn = if (child.active) |active| active.turn else 0,
            .queued = child.queue.len,
        };
    };
    // A streaming worker takes the message inside its running turn.
    if (target.phase == .running and target.queued == 0) if (target.active_work) |work_id| {
        const steered = try self.managed.steer(target.id, work_id, ctx.operation_id, fingerprint, message);
        switch (steered) {
            .receipt => {
                const job = try jobId(arena, target.id, target.active_turn);
                const text = try arena.print("Steered worker `{s}` (label `{s}`) inside its running turn {d} (job `{s}`); receipt: steered. No new turn was created; the turn's result is delivered when it settles.", .{ target.id, target.label, target.active_turn, job });
                return encode(alloc, .{ .ok = true, .result = text, .receipt = .steered, .worker = target.id, .label = target.label, .turn = target.active_turn, .job = job });
            },
            .capacity => {
                const text = try arena.print("Worker `{s}` already has the most steering messages its running turn can take. Wait for its turn to settle, then retry this message.", .{target.id});
                return encode(alloc, .{ .ok = false, .error_code = "steering_full", .result = text, .receipt = .rejected, .worker = target.id, .label = target.label });
            },
            // Not streaming yet, or ending: the message becomes its own turn.
            .waiting, .cancelled, .unavailable, .conflict => {},
        }
    };
    return admitTurn(self, alloc, arena, request, fingerprint, target, ctx);
}

fn replayedTurn(child: Child, operation_id: []const u8) ?struct { receipt: model_contract.Receipt, turn: u32 } {
    if (child.active) |active| if (std.mem.eql(u8, active.id, operation_id)) return .{ .receipt = .accepted, .turn = active.turn };
    for (child.queue) |work| if (std.mem.eql(u8, work.id, operation_id)) return .{ .receipt = .queued, .turn = work.turn };
    if (child.last_work_id) |last| if (std.mem.eql(u8, last, operation_id)) return .{ .receipt = .accepted, .turn = child.turns };
    return null;
}

/// The hook a node's managed owner calls as its workers' turns start and
/// settle, which keeps the turn jobs current (D112).
pub fn turnHook(self: *Runtime) @import("managed_owner.zig").TurnHook {
    return .{ .context = self, .started_fn = turnStarted, .settled_fn = turnSettled };
}

fn turnStarted(context: *anyopaque, _: []const u8, work_id: []const u8) void {
    const self: *Runtime = @ptrCast(@alignCast(context));
    self.fleet.start(work_id, io_mod.milliTimestamp());
}

fn turnSettled(context: *anyopaque, child_id: []const u8, work_id: []const u8, observation: @import("managed_owner.zig").Observation) void {
    const self: *Runtime = @ptrCast(@alignCast(context));
    const tracked = self.fleet.has(work_id);
    debug_trace.logf("subagent", "fleet turn settled child_id={s} work_id={s} tracked={}", .{ child_id, work_id, tracked });
    if (!tracked) return;
    const now = io_mod.milliTimestamp();
    const state: turn_jobs.State = switch (observation.outcome orelse .failed) {
        .completed => .completed,
        .failed => .failed,
        .cancelled, .interrupted, .lost => .cancelled,
    };
    const result = self.completeManagedResult(self.alloc, child_id, work_id, observation) catch |err| {
        debug_trace.logf("subagent", "fleet result unavailable child_id={s} work_id={s} err={s}", .{ child_id, work_id, @errorName(err) });
        self.fleet.settle(work_id, state, "{\"ok\":false,\"result\":null,\"error_code\":\"child_result_unavailable\"}", null, now) catch {};
        return;
    };
    defer self.alloc.free(result.body);
    if (result.final_status) |status| self.alloc.free(status.model);
    // The jobs registry hands the model this handle, never the fleet (D112).
    const handle = self.storeFullResult(self.alloc, work_id, result.body) catch |err| blk: {
        debug_trace.logf("subagent", "fleet summary not stored child_id={s} err={s}", .{ child_id, @errorName(err) });
        break :blk null;
    };
    defer if (handle) |value| self.alloc.free(value);
    debug_trace.logf("subagent", "fleet job settled child_id={s} state={s} result_bytes={d}", .{ child_id, @tagName(state), result.body.len });
    self.fleet.settle(work_id, state, result.body, handle, now) catch |err|
        debug_trace.logf("subagent", "fleet settle failed child_id={s} work_id={s} err={s}", .{ child_id, work_id, @errorName(err) });
}

/// `turn_jobs.cancelTurn`: a queued turn leaves its worker's queue and
/// settles cancelled; a running one is asked to stop.
pub fn cancelTurn(self: *Runtime, id: []const u8) !turn_jobs.CancelOutcome {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const work = (try self.fleet.workOf(arena, id)) orelse return .unknown;
    switch (work.state) {
        .completed, .failed, .cancelled => return .already_settled,
        .running => {
            self.managed.cancel(work.node_id) catch return .already_settled;
            return .cancelled;
        },
        .queued => {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            {
                var lock = self.managed.state_store.acquireLock();
                defer lock.release();
                var registry = try self.managed.state_store.load(arena);
                if (!try fleet_state.cancelQueued(&registry, arena, work.node_id, work.work_id)) return .already_settled;
                try self.managed.state_store.save(arena, registry);
            }
            try self.fleet.settle(work.work_id, .cancelled, "{\"ok\":false,\"result\":\"This queued turn was cancelled before it ran.\",\"error_code\":\"turn_cancelled\"}", null, io_mod.milliTimestamp());
            return .cancelled;
        },
    }
}

/// Starts a new turn on an idle worker, or queues it behind a busy one.
fn admitTurn(self: *Runtime, alloc: Allocator, arena: Allocator, request: model_contract.Request, fingerprint: [32]u8, target: Target, ctx: Context) !Result {
    const message = request.turnMessage().?;
    const outcome: struct { receipt: model_contract.Receipt, turn: u32 } = blk: {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(arena);
        const child = registry.findById(target.id) orelse return encode(alloc, .{ .ok = false, .error_code = "unknown_worker", .receipt = .rejected });
        if (child.terminated) return encode(alloc, .{ .ok = false, .error_code = "worker_terminal", .receipt = .terminal, .worker = target.id, .label = target.label });
        var work = try tool_host.makeManagedWork(arena, ctx.operation_id, fingerprint, request, ctx.options, ctx.child_mode);
        work.turn = fleet_state.nextTurn(child.*);
        const idle = child.active == null and child.queue.len == 0;
        if (idle) {
            const started = try registry.startPersistentWork(arena, target.label, null, work);
            started.turns = work.turn;
        } else {
            _ = fleet_state.enqueue(&registry, arena, target.id, work) catch |err| switch (err) {
                error.QueueFull => {
                    const text = try arena.print("Worker `{s}` follow-up queue is full ({d}/{d} turns). Wait for a turn to settle, then retry this message.", .{ target.id, child.queue.len, fleet_state.max_queued_turns });
                    return encode(alloc, .{ .ok = false, .error_code = "queue_full", .result = text, .receipt = .rejected, .worker = target.id, .label = target.label });
                },
                else => |e| return e,
            };
        }
        try self.managed.state_store.save(arena, registry);
        break :blk .{ .receipt = if (idle) .accepted else .queued, .turn = work.turn };
    };
    const job = try jobId(arena, target.id, outcome.turn);
    const now = io_mod.milliTimestamp();
    try self.fleet.accept(.{ .node_id = target.id, .label = target.label, .work_id = ctx.operation_id, .turn = outcome.turn, .message = message, .state = if (outcome.receipt == .accepted) .running else .queued, .now_ms = now });
    if (outcome.receipt == .accepted) {
        _ = self.managed.start(target.id) catch |err| {
            debug_trace.logf("subagent", "fleet send start failed child_id={s} err={s}", .{ target.id, @errorName(err) });
            try self.fleet.settle(ctx.operation_id, .failed, "{\"ok\":false,\"error_code\":\"start_failed\"}", null, now);
            return encode(alloc, .{ .ok = false, .error_code = "start_failed", .receipt = .rejected, .worker = target.id, .label = target.label });
        };
    } else pumpQueues(self);
    const text = if (outcome.receipt == .accepted)
        try arena.print("Accepted turn {d} for worker `{s}` (label `{s}`, job `{s}`); receipt: accepted. Its result is delivered automatically when the turn settles.", .{ outcome.turn, target.id, target.label, job })
    else
        try arena.print("Queued turn {d} for busy worker `{s}` (label `{s}`, job `{s}`); receipt: queued. It starts after the current turn settles, and its result is delivered automatically.", .{ outcome.turn, target.id, target.label, job });
    return encode(alloc, .{ .ok = true, .result = text, .receipt = outcome.receipt, .worker = target.id, .label = target.label, .turn = outcome.turn, .job = job });
}

/// Starts the front of every idle worker's queue: after a restart, after a
/// cancelled turn, or when a send queued behind a turn that just ended.
pub fn pumpQueues(self: *Runtime) void {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var started: std.ArrayList([]const u8) = .empty;
    {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = self.managed.state_store.load(arena) catch return;
        for (registry.children) |child| {
            if (child.terminated or child.active != null or child.queue.len == 0) continue;
            const next = (fleet_state.startQueued(&registry, arena, child.id) catch continue) orelse continue;
            started.append(arena, next.id) catch continue;
        }
        if (started.items.len == 0) return;
        self.managed.state_store.save(arena, registry) catch |err| {
            debug_trace.logf("subagent", "fleet queue start not saved node_id={s} err={s}", .{ self.node_id, @errorName(err) });
            return;
        };
        for (started.items) |child_id| {
            const child = registry.findById(child_id).?;
            const work = child.active.?;
            self.fleet.accept(.{ .node_id = child_id, .label = child.agentName() orelse "worker", .work_id = work.id, .turn = work.turn, .message = work.message, .state = .queued, .now_ms = io_mod.milliTimestamp() }) catch {};
            self.fleet.start(work.id, io_mod.milliTimestamp());
        }
    }
    for (started.items) |child_id| {
        _ = self.managed.start(child_id) catch |err|
            debug_trace.logf("subagent", "fleet queue start failed child_id={s} err={s}", .{ child_id, @errorName(err) });
    }
}

fn terminate(self: *Runtime, alloc: Allocator, id: []const u8) !Result {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    self.admission_mutex.lockUncancelable(io_mod.getIo());
    defer self.admission_mutex.unlock(io_mod.getIo());
    const target = blk: {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(arena);
        break :blk switch (try findWorker(arena, &registry, id)) {
            .found => |child| .{ try arena.dupe(u8, child.id), try arena.dupe(u8, child.agentName().?), child.active != null },
            .refused => |refused| return encode(alloc, refused),
        };
    };
    const child_id, const label, const running = target;
    // The in-flight turn is cancelled and its subtree joined before the
    // tombstone (`tests/tla/session_manager/Fleet.tla` NoWorkAfterTerminate).
    if (running) self.managed.cancelAndJoin(child_id);
    {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(arena);
        fleet_state.terminate(&registry, arena, child_id) catch |err| switch (err) {
            error.Terminated => {},
            error.InvalidState => return encode(alloc, .{ .ok = false, .error_code = "worker_busy", .receipt = .rejected, .worker = child_id, .label = label, .result = "The worker's turn did not stop in time; terminate it again." }),
            else => |e| return e,
        };
        try self.managed.state_store.save(arena, registry);
    }
    try self.fleet.discardWorker(child_id, "{\"ok\":false,\"result\":\"The worker was terminated before this turn ran.\",\"error_code\":\"worker_terminated\"}", io_mod.milliTimestamp());
    const cancel_note = if (running) " Its in-flight turn was cancelled." else "";
    const text = try arena.print("Worker `{s}` (label `{s}`) is terminal; receipt: terminal, reason=explicit-kill.{s} Pending inputs were discarded. Recover at history://{s} or agent://{s}.", .{ child_id, label, cancel_note, child_id, child_id });
    return encode(alloc, .{ .ok = true, .result = text, .receipt = .terminal, .worker = child_id, .label = label, .error_code = if (running) "turn_cancelled" else null });
}

const Row = struct {
    id: []const u8,
    label: []const u8,
    lifecycle: []const u8,
    state: []const u8,
    turns: u32,
    queued: usize,
    job: ?[]const u8 = null,
    queued_jobs: []const []const u8 = &.{},
    started_ms: ?i64 = null,
    model: ?[]const u8 = null,
    activity: ?[]const u8 = null,
};

fn list(self: *Runtime, alloc: Allocator, only: ?[]const u8) !Result {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = blk: {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        break :blk try self.managed.state_store.load(arena);
    };
    if (only) |id| switch (try findWorker(arena, &registry, id)) {
        .found => {},
        .refused => |refused| if (refused.receipt != .terminal) return encode(alloc, refused),
    };
    const jobs = try self.fleet.snapshot(arena);
    var rows: std.ArrayList(Row) = .empty;
    for (registry.children) |child| {
        const label = child.agentName() orelse continue;
        if (only) |id| if (!std.mem.eql(u8, id, child.id)) continue;
        try rows.append(arena, try rowFor(self, arena, child, label, jobs));
    }
    var text: std.Io.Writer.Allocating = .init(arena);
    if (rows.items.len == 0) {
        try text.writer.writeAll("No owned workers. Spawn one with fleet op \"spawn\".");
    } else if (only != null) {
        try writeInspect(&text.writer, rows.items[0]);
    } else for (rows.items, 0..) |row, index| {
        if (index > 0) try text.writer.writeByte('\n');
        try writeRow(&text.writer, row);
    }
    var workers: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(rows.items, .{ .emit_null_optional_fields = false }, &workers.writer);
    return encode(alloc, .{ .ok = true, .result = text.written(), .workers = workers.written() });
}

/// The inspect text of `id` when it is one of this node's workers, for
/// `agent://`; null otherwise. Owned by `arena`.
pub fn inspectText(self: *Runtime, arena: Allocator, id: []const u8) !?[]const u8 {
    var registry = blk: {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        break :blk try self.managed.state_store.load(arena);
    };
    const child = registry.findById(id) orelse return null;
    const label = child.agentName() orelse return null;
    var text: std.Io.Writer.Allocating = .init(arena);
    try writeInspect(&text.writer, try rowFor(self, arena, child.*, label, try self.fleet.snapshot(arena)));
    return text.written();
}

fn rowFor(self: *Runtime, arena: Allocator, child: Child, label: []const u8, jobs: []const turn_jobs.TurnJob) !Row {
    var row: Row = .{
        .id = child.id,
        .label = label,
        .lifecycle = if (child.terminated) "terminal" else "live",
        .state = if (child.terminated) "terminated" else switch (child.phase) {
            .running => "running",
            .awaiting_approval => "awaiting approval",
            .interrupted => "interrupted",
            .idle, .finished => "idle",
        },
        .turns = child.turns,
        .queued = child.queue.len,
    };
    if (child.active) |active| {
        row.job = try jobId(arena, child.id, active.turn);
        row.activity = firstLine(active.message);
    } else if (child.turns > 0) row.job = try jobId(arena, child.id, child.turns - @as(u32, @intCast(child.queue.len)));
    for (jobs) |job| {
        if (row.job) |current| if (std.mem.eql(u8, job.id, current) and job.state == .running) {
            row.started_ms = job.started_ms;
        };
    }
    if (child.queue.len > 0) {
        const ids = try arena.alloc([]const u8, child.queue.len);
        for (child.queue, ids) |work, *out| out.* = try jobId(arena, child.id, work.turn);
        row.queued_jobs = ids;
    }
    if (self.children.parent.store.childPreferences(arena, child.id)) |preferences| {
        row.model = preferences.model;
    } else |_| {}
    return row;
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = trimmed[0..end];
    if (line.len <= 100) return line;
    var cut: usize = 100;
    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
    return line[0..cut];
}

fn writeRow(writer: *std.Io.Writer, row: Row) !void {
    try writer.print("- `{s}` (label `{s}`) lifecycle={s} · turn={s} · {d} turn{s}", .{ row.id, row.label, row.lifecycle, row.state, row.turns, if (row.turns == 1) "" else "s" });
    if (row.job) |job| try writer.print(" · job {s}", .{job});
    if (row.queued > 0) try writer.print(" · {d} queued", .{row.queued});
    if (row.model) |model| try writer.print(" · {s}", .{model});
    if (row.activity) |activity| try writer.print(" · last: {s}", .{activity});
}

fn writeInspect(writer: *std.Io.Writer, row: Row) !void {
    try writer.print("Worker `{s}` (label `{s}`)\nlifecycle: {s}\nturn state: {s}\nturns: {d}\n", .{ row.id, row.label, row.lifecycle, row.state, row.turns });
    if (row.model) |model| try writer.print("model: {s}\n", .{model});
    if (row.job) |job| try writer.print("{s} turn job: {s}\n", .{ if (std.mem.eql(u8, row.state, "running")) "current" else "last", job });
    if (row.queued_jobs.len > 0) {
        try writer.writeAll("queued turn jobs:");
        for (row.queued_jobs, 0..) |job, index| try writer.print("{s} {s}", .{ if (index == 0) "" else ",", job });
        try writer.writeByte('\n');
    }
    if (row.activity) |activity| try writer.print("last activity: {s}\n", .{activity});
    if (std.mem.eql(u8, row.lifecycle, "terminal")) try writer.writeAll("terminal: explicit-kill. ");
    try writer.print("Transcript: history://{s}", .{row.id});
}

test "generated labels are valid and readable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const label = try generatedLabel(arena_state.allocator(), "01JABCDEFGHJKMNPQRSTVWXYZ0");
    try std.testing.expectEqualStrings("worker-vwxyz0", label);
    try std.testing.expect(@import("domain.zig").validLabel(label));
}

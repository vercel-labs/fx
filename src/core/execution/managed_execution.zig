const std = @import("std");
const builtin = @import("builtin");
const command_admission = @import("../permissions/command_admission.zig");
const command_contract = @import("command_contract.zig");
const command_environment = @import("command_environment.zig");
const command_runner = @import("command_runner.zig");
const contract = @import("managed_execution_contract.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const execution_router = @import("router.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;
const max_entries = contract.max_live_entries + contract.max_tombstones;
const captured_stop_settle_timeout_ms: i64 = if (builtin.is_test)
    100
else
    command_runner.termination_settle_timeout_ms + 1_000;

pub const StartCapturedInput = struct {
    execution_id: []const u8,
    command: []const u8,
    cwd: []const u8,
    environment: command_environment.Environment,
    authority: command_admission.CommandExecutionAuthority,
    max_output_bytes: usize,
    timeout_ms: ?usize,
    command_artifact_dir: ?[]const u8,
    replay_capability: ?*const session_child_store.SessionChildCapability = null,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?command_runner.CommandOutputCallback = null,
    yield_time_ms: u32 = contract.default_yield_time_ms,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const TtyCursor = struct {
    segment: u64 = 1,
    offset: u64 = 0,

    fn validate(self: TtyCursor) !void {
        if (self.segment == 0) return error.InvalidTtyCursor;
    }
};

pub const TtyUpdate = struct {
    execution_id: []const u8,
    command: []const u8,
    cwd: ?[]const u8 = null,
    state: SnapshotState,
    output: []const u8 = "",
    replay_output: ?[]const u8 = null,
    next_cursor: ?TtyCursor = null,
    output_incomplete: bool = false,
    error_name: ?[]const u8 = null,
    max_output_bytes: usize,
    published_running: bool,
    capacity_reserved: bool = false,
    replay_capability: ?*const session_child_store.SessionChildCapability = null,
};

pub const SnapshotState = union(enum) {
    running,
    completed: command_contract.CommandStatus,
    stopped: ?command_contract.CommandStatus,
    lost,
};

pub const Snapshot = struct {
    execution_id: []u8,
    command: []u8,
    cwd: []u8,
    retained: bool,
    state: SnapshotState,
    backend: contract.Backend = .captured,
    persistence: contract.Persistence = .process,
    output_delta: []u8,
    output_truncated: bool,
    output_incomplete: bool = false,
    duration_ms: ?u64 = null,
    output_file: ?[]u8 = null,
    output_framed_bytes: usize = 0,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    error_name: ?[]u8 = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.execution_id);
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.output_delta);
        if (self.output_file) |value| alloc.free(value);
        if (self.error_name) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const PreparedSnapshot = struct {
    snapshot: Snapshot,
    reservation_id: u64,

    pub fn deinit(self: *PreparedSnapshot, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

pub fn modelOutputDelta(
    alloc: Allocator,
    encoded: []const u8,
) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const output_delta = switch (object.get("output_delta") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    return try alloc.dupe(u8, output_delta);
}

pub const ListItem = struct {
    execution_id: []u8,
    command: []u8,
    state: SnapshotState,
    backend: contract.Backend,
    persistence: contract.Persistence,

    pub fn deinit(self: *ListItem, alloc: Allocator) void {
        alloc.free(self.execution_id);
        alloc.free(self.command);
        self.* = undefined;
    }
};

const CapturedAuthority = struct {
    route: execution_router.PreparedCommandRoute,
};

const TtyAuthority = struct {
    session_id: []const u8,
    cursor: TtyCursor,
};

const BackendState = union(enum) {
    captured: CapturedAuthority,
    tty: TtyAuthority,
    tombstone,
};

const Entry = struct {
    runtime: *Runtime,
    arena: *std.heap.ArenaAllocator,
    execution_id: []const u8,
    command: []const u8,
    cwd: []const u8,
    environment: command_environment.Environment,
    max_output_bytes: usize,
    timeout_ms: ?usize,
    command_artifact_dir: ?[]const u8,
    backend_kind: contract.Backend,
    persistence_kind: contract.Persistence,
    mutex: std.Io.Mutex = .init,
    state: contract.State = .starting,
    barrier: contract.CompletionBarrier = .{},
    backend_state: BackendState,
    output: std.ArrayList(u8) = .empty,
    replay_capture: ?*command_replay_store.Capture = null,
    replay_capability: ?*session_child_store.SessionChildCapability = null,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?command_runner.CommandOutputCallback = null,
    output_handle: ?[]const u8 = null,
    output_framed_bytes: usize = 0,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    output_truncated: bool = false,
    output_incomplete: bool = false,
    delivery: contract.DeliveryState = .{},
    active_waiter: ?u64 = null,
    preempted_waiter: ?u64 = null,
    result: ?command_contract.RunCommandResult = null,
    error_name: ?[]const u8 = null,
    cancel: std.atomic.Value(bool) = .init(false),
    force_cancel: std.atomic.Value(bool) = .init(false),
    start_gate: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    published_running: bool = false,
    tombstone_sequence: std.atomic.Value(u32) = .init(0),
    active_operations: usize = 0,
    pending_delete: bool = false,

    fn init(runtime: *Runtime, input: StartCapturedInput) !*Entry {
        const entry = try runtime.alloc.create(Entry);
        errdefer runtime.alloc.destroy(entry);
        const arena = try runtime.alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(runtime.alloc);
        errdefer {
            arena.deinit();
            runtime.alloc.destroy(arena);
        }
        const owned = arena.allocator();
        const command = try owned.dupe(u8, input.command);
        const cwd = try owned.dupe(u8, input.cwd);
        const execution_id = try owned.dupe(u8, input.execution_id);
        const environment = try dupeEnvironment(owned, input.environment);
        const command_artifact_dir = if (input.command_artifact_dir) |path|
            try owned.dupe(u8, path)
        else
            null;
        const command_ctx = command_admission.CommandContext{
            .command = command,
            .resolved_cwd = cwd,
            .target_os = builtin.os.tag,
            .environment = environment,
        };
        const authority = rebindAuthority(input.authority, command_ctx);
        var route = try execution_router.prepareAuthorizedRoute(
            owned,
            command_ctx,
            authority,
        );
        errdefer route.deinit(owned);
        const replay_capability = try duplicateReplayCapability(
            runtime,
            input.replay_capability,
        );
        errdefer deinitReplayCapability(runtime, replay_capability);
        const replay_capture = if (replay_capability) |capability|
            try command_replay_store.Capture.create(owned, 0, capability)
        else
            try command_replay_store.Capture.createEphemeral(
                owned,
                0,
                &runtime.replay_store,
            );
        const output_chunk_lifecycle_id = if (input.output_chunk_lifecycle_id) |id|
            types.ToolLifecycleId{
                .turn_id = id.turn_id,
                .call_id = try owned.dupe(u8, id.call_id),
            }
        else
            null;
        entry.* = .{
            .runtime = runtime,
            .arena = arena,
            .execution_id = execution_id,
            .command = command,
            .cwd = cwd,
            .environment = environment,
            .max_output_bytes = input.max_output_bytes,
            .timeout_ms = input.timeout_ms,
            .command_artifact_dir = command_artifact_dir,
            .backend_kind = .captured,
            .persistence_kind = .process,
            .backend_state = .{ .captured = .{ .route = route } },
            .replay_capture = replay_capture,
            .replay_capability = replay_capability,
            .output_chunk_lifecycle_id = output_chunk_lifecycle_id,
            .output_chunk_ctx = input.output_chunk_ctx,
            .on_output_chunk = input.on_output_chunk,
        };
        return entry;
    }

    fn initTty(runtime: *Runtime, input: TtyUpdate) !*Entry {
        if (input.next_cursor) |cursor| try cursor.validate();
        const entry = try runtime.alloc.create(Entry);
        errdefer runtime.alloc.destroy(entry);
        const arena = try runtime.alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(runtime.alloc);
        errdefer {
            arena.deinit();
            runtime.alloc.destroy(arena);
        }
        const owned = arena.allocator();
        const execution_id = try owned.dupe(u8, input.execution_id);
        const command = try owned.dupe(u8, input.command);
        const cwd = try owned.dupe(u8, input.cwd orelse "");
        const replay_capability = try duplicateReplayCapability(
            runtime,
            input.replay_capability,
        );
        errdefer deinitReplayCapability(runtime, replay_capability);
        const replay_capture = if (replay_capability) |capability|
            try command_replay_store.Capture.create(owned, 0, capability)
        else
            try command_replay_store.Capture.createEphemeral(
                owned,
                0,
                &runtime.replay_store,
            );
        const raw_output = input.replay_output orelse input.output;
        if (raw_output.len != 0) {
            replay_capture.appendAccepted(owned, .stdout, raw_output);
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(runtime.alloc);
        try output.appendSlice(runtime.alloc, input.output[0..@min(
            input.output.len,
            input.max_output_bytes,
        )]);
        const error_name = if (input.error_name) |value|
            try owned.dupe(u8, value)
        else
            null;
        entry.* = .{
            .runtime = runtime,
            .arena = arena,
            .execution_id = execution_id,
            .command = command,
            .cwd = cwd,
            .environment = .legacy,
            .max_output_bytes = input.max_output_bytes,
            .timeout_ms = null,
            .command_artifact_dir = null,
            .backend_kind = .tty,
            .persistence_kind = .session,
            .state = contractStateFromSnapshot(input.state),
            .backend_state = .{ .tty = .{
                .session_id = execution_id,
                .cursor = input.next_cursor orelse .{},
            } },
            .output = output,
            .replay_capture = replay_capture,
            .replay_capability = replay_capability,
            .published_running = input.published_running,
            .output_truncated = input.output.len > input.max_output_bytes,
            .output_incomplete = input.output_incomplete,
            .stdout_bytes = raw_output.len,
            .error_name = error_name,
        };
        if (entry.isTerminal()) entry.finalizeReplayLocked();
        return entry;
    }

    fn deinit(self: *Entry) void {
        std.debug.assert(self.active_operations == 0);
        std.debug.assert(self.thread == null);
        switch (self.backend_state) {
            .captured => |*captured| captured.route.deinit(self.arena.allocator()),
            .tty, .tombstone => {},
        }
        if (self.replay_capture) |capture| {
            capture.releaseRetained(self.arena.allocator());
        }
        deinitReplayCapability(self.runtime, self.replay_capability);
        self.output.deinit(self.runtime.alloc);
        self.arena.deinit();
        self.runtime.alloc.destroy(self.arena);
        self.runtime.alloc.destroy(self);
    }

    fn matchesCapturedInput(self: *const Entry, input: StartCapturedInput) bool {
        return self.backend_kind == .captured and
            std.mem.eql(u8, self.command, input.command) and
            std.mem.eql(u8, self.cwd, input.cwd) and
            self.environment.eql(input.environment) and
            self.max_output_bytes == input.max_output_bytes and
            self.timeout_ms == input.timeout_ms and
            optionalStringEql(self.command_artifact_dir, input.command_artifact_dir);
    }

    fn statusSnapshot(self: *Entry) SnapshotState {
        return switch (self.state) {
            .starting, .running, .stopping => .running,
            .completed => |status| .{ .completed = status },
            .stopped => |status| .{ .stopped = status },
            .lost => .lost,
        };
    }

    fn isTerminal(self: *Entry) bool {
        return self.state.isTerminal();
    }

    fn backend(self: *const Entry) contract.Backend {
        return self.backend_kind;
    }

    fn persistence(self: *const Entry) contract.Persistence {
        return self.persistence_kind;
    }

    fn appendBoundedOutput(self: *Entry, chunk: []const u8) !void {
        const available = self.max_output_bytes -| self.output.items.len;
        const retained = @min(available, chunk.len);
        if (retained != 0) {
            try self.output.appendSlice(self.runtime.alloc, chunk[0..retained]);
        }
        if (retained != chunk.len) self.output_truncated = true;
    }

    fn appendOutput(raw: *anyopaque, _: ?@import("../shared/types.zig").ToolLifecycleId, stream: command_contract.CommandOutputStream, chunk: []const u8) !void {
        const self: *Entry = @ptrCast(@alignCast(raw));
        if (chunk.len == 0) return;
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.replay_capture) |capture| {
            capture.appendAccepted(self.arena.allocator(), stream, chunk);
        }
        switch (stream) {
            .stdout => self.stdout_bytes +|= chunk.len,
            .stderr => self.stderr_bytes +|= chunk.len,
        }
        try self.appendBoundedOutput(chunk);
    }

    fn workerMain(self: *Entry) void {
        self.start_gate.waitUncancelable(io_mod.getIo());
        const captured = switch (self.backend_state) {
            .captured => |*value| value,
            .tty, .tombstone => return,
        };
        const started_ms = io_mod.milliTimestamp();
        const routed = execution_router.executePreparedRoute(.{
            .max_command_output_bytes = self.max_output_bytes,
            .cancel_flag = &self.cancel,
            .force_cancel_flag = &self.force_cancel,
            .output_chunk_lifecycle_id = self.output_chunk_lifecycle_id,
            .output_chunk_ctx = self.output_chunk_ctx,
            .on_output_chunk = self.on_output_chunk,
            .accepted_output_chunk_ctx = self,
            .on_accepted_output_chunk = appendOutput,
            .callback_projection = .raw,
            .timeout_ms = self.timeout_ms,
            .timeout_started_ms = started_ms,
            .command_artifact_dir = self.command_artifact_dir,
        }, self.arena.allocator(), captured.route) catch |err| {
            const zio = io_mod.getIo();
            self.mutex.lockUncancelable(zio);
            self.finalizeReplayLocked();
            self.error_name = @errorName(err);
            debug_trace.logf(
                "core",
                "managed execution became lost boundary=worker_route execution_id={s} err={s}",
                .{ self.execution_id, @errorName(err) },
            );
            self.state = state_for_worker_error(err);
            self.barrier.output_drained = true;
            self.mutex.unlock(zio);
            return;
        };

        const status = statusFromResult(self.execution_id, routed.result);
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        self.finalizeReplayLocked();
        self.result = routed.result;
        var next = contract.transition(
            self.state,
            self.barrier,
            .{ .process_terminated = status },
        );
        next = contract.transition(next.state, next.barrier, .output_drained);
        self.state = next.state;
        self.barrier = next.barrier;
        self.mutex.unlock(zio);
    }

    fn finalizeReplayLocked(self: *Entry) void {
        if (self.output_handle != null) return;
        const capture = self.replay_capture orelse return;
        const replay = capture.retain(self.arena.allocator()) orelse return;
        switch (replay) {
            .available => |descriptor| {
                self.output_handle = self.arena.allocator().dupe(
                    u8,
                    descriptor.handle,
                ) catch null;
                self.output_framed_bytes = descriptor.framed_bytes;
            },
            .unavailable => {},
        }
        capture.releaseRetained(self.arena.allocator());
    }
};

pub const Runtime = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    entries: [max_entries]?*Entry = @splat(null),
    next_reservation_id: u64 = 1,
    next_generated_id: u64 = 1,
    next_tombstone_sequence: std.atomic.Value(u32) = .init(1),
    shutting_down: bool = false,
    replay_store: command_replay_store.EphemeralStore,
    pending_admissions: usize = 0,

    pub fn init(alloc: Allocator) Runtime {
        return .{
            .alloc = alloc,
            .replay_store = command_replay_store.EphemeralStore.init(alloc),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.shutdown();
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        for (&self.entries) |*slot| {
            const entry = slot.* orelse continue;
            std.debug.assert(entry.active_operations == 0);
            slot.* = null;
            self.joinEntry(entry);
            entry.deinit();
        }
        self.replay_store.deinit();
        self.mutex.unlock(zio);
        self.* = undefined;
    }

    pub fn generatedId(self: *Runtime, buffer: []u8) ![]const u8 {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const value = self.next_generated_id;
        self.next_generated_id +%= 1;
        if (self.next_generated_id == 0) self.next_generated_id = 1;
        return std.fmt.bufPrint(buffer, "shell-{d}", .{value});
    }

    pub fn replayStore(
        self: *Runtime,
    ) *command_replay_store.EphemeralStore {
        return &self.replay_store;
    }

    pub fn startCaptured(
        self: *Runtime,
        alloc: Allocator,
        input: StartCapturedInput,
    ) !PreparedSnapshot {
        if (input.yield_time_ms > contract.max_yield_time_ms) {
            return error.InvalidYieldTime;
        }
        const admission = try self.admitCaptured(input);
        const entry = admission.entry;
        var published = false;
        errdefer if (admission.created and !published) {
            self.cancelUnpublished(entry.execution_id);
        };

        if (!admission.created) {
            published = true;
            return self.prepareSnapshot(alloc, entry.execution_id);
        }

        if (input.yield_time_ms == 0) {
            const prepared = try self.prepareSnapshot(alloc, entry.execution_id);
            const zio = io_mod.getIo();
            entry.mutex.lockUncancelable(zio);
            entry.published_running = true;
            entry.mutex.unlock(zio);
            published = true;
            entry.start_gate.set(zio);
            return prepared;
        }

        entry.start_gate.set(io_mod.getIo());

        const started_ms = io_mod.milliTimestamp();
        const zio = io_mod.getIo();
        while (true) {
            entry.mutex.lockUncancelable(zio);
            const terminal = entry.isTerminal();
            entry.mutex.unlock(zio);
            if (terminal) break;
            if (input.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    entry.cancel.store(true, .seq_cst);
                    self.joinEntry(entry);
                    const prepared = try self.prepareSnapshot(
                        alloc,
                        entry.execution_id,
                    );
                    published = true;
                    return prepared;
                }
            }
            const elapsed = io_mod.milliTimestamp() - started_ms;
            if (elapsed >= input.yield_time_ms) break;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }

        const prepared = try self.prepareSnapshot(alloc, entry.execution_id);
        entry.mutex.lockUncancelable(zio);
        if (!entry.isTerminal()) entry.published_running = true;
        entry.mutex.unlock(zio);
        published = true;
        return prepared;
    }

    pub fn registerTty(
        self: *Runtime,
        alloc: Allocator,
        input: TtyUpdate,
    ) !PreparedSnapshot {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.shutting_down) {
            self.mutex.unlock(zio);
            return error.RuntimeStopping;
        }
        if (self.findEntryLocked(input.execution_id)) |existing| {
            if (input.capacity_reserved and self.pending_admissions != 0) {
                self.pending_admissions -= 1;
            }
            existing.active_operations += 1;
            self.mutex.unlock(zio);
            defer self.releaseEntry(existing);
            return self.updateTtyEntry(alloc, existing, input);
        }
        if (input.capacity_reserved) {
            if (self.pending_admissions == 0) {
                self.mutex.unlock(zio);
                return error.InvalidCapacityReservation;
            }
        } else if (contract.decideAdmission(
            self.liveCountLocked() + self.pending_admissions,
        ) == .capacity_exhausted) {
            self.mutex.unlock(zio);
            return error.ExecutionCapacityExceeded;
        }
        self.evictOldestTombstoneLocked();
        const slot = self.emptySlotLocked() orelse {
            self.mutex.unlock(zio);
            return error.ExecutionCapacityExceeded;
        };
        const entry = Entry.initTty(self, input) catch |err| {
            self.mutex.unlock(zio);
            return err;
        };
        entry.active_operations = 1;
        self.entries[slot] = entry;
        if (input.capacity_reserved) self.pending_admissions -= 1;
        self.mutex.unlock(zio);
        defer self.releaseEntry(entry);
        return self.prepareSnapshotForEntry(alloc, entry);
    }

    pub fn reserveTtyCapacity(self: *Runtime) !void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.shutting_down) return error.RuntimeStopping;
        if (contract.decideAdmission(
            self.liveCountLocked() + self.pending_admissions,
        ) == .capacity_exhausted) {
            return error.ExecutionCapacityExceeded;
        }
        self.pending_admissions += 1;
    }

    pub fn releaseTtyCapacity(self: *Runtime) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.pending_admissions != 0) self.pending_admissions -= 1;
    }

    pub fn updateTty(
        self: *Runtime,
        alloc: Allocator,
        input: TtyUpdate,
    ) !PreparedSnapshot {
        const entry = self.acquireEntry(input.execution_id) orelse
            return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        return self.updateTtyEntry(alloc, entry, input);
    }

    pub fn observeTtyState(
        self: *Runtime,
        execution_id: []const u8,
        state: SnapshotState,
    ) void {
        const entry = self.acquireEntry(execution_id) orelse return;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        if (entry.backend() != .tty or entry.backend_state == .tombstone) {
            entry.mutex.unlock(zio);
            return;
        }
        entry.state = contractStateFromSnapshot(state);
        entry.mutex.unlock(zio);
    }

    pub fn backendFor(
        self: *Runtime,
        execution_id: []const u8,
    ) ?contract.Backend {
        const entry = self.acquireEntry(execution_id) orelse return null;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        return entry.backend();
    }

    /// Copies retained captured-command metadata without reserving output or changing authority.
    /// The caller owns the returned bytes. Missing and TTY executions return null.
    pub fn captured_command_alloc(
        self: *Runtime,
        alloc: Allocator,
        execution_id: []const u8,
    ) Allocator.Error!?[]u8 {
        const entry = self.acquireEntry(execution_id) orelse return null;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        if (entry.backend() != .captured) return null;
        return try alloc.dupe(u8, entry.command);
    }

    pub fn stateFor(
        self: *Runtime,
        execution_id: []const u8,
    ) ?SnapshotState {
        const entry = self.acquireEntry(execution_id) orelse return null;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        return entry.statusSnapshot();
    }

    pub fn ttyCursorFor(
        self: *Runtime,
        execution_id: []const u8,
    ) ?TtyCursor {
        const entry = self.acquireEntry(execution_id) orelse return null;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        return switch (entry.backend_state) {
            .tty => |tty| tty.cursor,
            .captured, .tombstone => null,
        };
    }

    pub fn refreshTty(
        self: *Runtime,
        input: TtyUpdate,
    ) !void {
        const entry = self.acquireEntry(input.execution_id) orelse
            return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        try applyTtyUpdateLocked(entry, input);
    }

    pub fn retainedTerminalSnapshot(
        self: *Runtime,
        alloc: Allocator,
        execution_id: []const u8,
    ) !?PreparedSnapshot {
        const entry = self.acquireEntry(execution_id) orelse
            return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        const tombstone = entry.backend_state == .tombstone;
        entry.mutex.unlock(zio);
        if (!tombstone) return null;
        return try self.prepareSnapshotForEntry(alloc, entry);
    }

    pub fn isTombstone(
        self: *Runtime,
        execution_id: []const u8,
    ) bool {
        const entry = self.acquireEntry(execution_id) orelse return false;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        return entry.backend_state == .tombstone;
    }

    pub fn reserveExternalWait(
        self: *Runtime,
        execution_id: []const u8,
    ) !u64 {
        const entry = self.acquireEntry(execution_id) orelse
            return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        const waiter_id = self.nextReservationId();
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        if (entry.active_waiter != null or entry.delivery.reservation != null) {
            return error.ExecutionBusy;
        }
        entry.active_waiter = waiter_id;
        return waiter_id;
    }

    pub fn externalWaitPreempted(
        self: *Runtime,
        execution_id: []const u8,
        waiter_id: u64,
    ) bool {
        const entry = self.acquireEntry(execution_id) orelse return true;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        return entry.preempted_waiter == waiter_id;
    }

    pub fn releaseExternalWait(
        self: *Runtime,
        execution_id: []const u8,
        waiter_id: u64,
    ) void {
        const entry = self.acquireEntry(execution_id) orelse return;
        defer self.releaseEntry(entry);
        self.clearActiveWaiter(entry, waiter_id);
    }

    pub fn preemptWait(
        self: *Runtime,
        execution_id: []const u8,
    ) void {
        const entry = self.acquireEntry(execution_id) orelse return;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        if (entry.active_waiter) |waiter_id| {
            entry.preempted_waiter = waiter_id;
        }
        entry.mutex.unlock(zio);
    }

    pub fn wait(
        self: *Runtime,
        alloc: Allocator,
        execution_id: []const u8,
        wait_ceiling_ms: u32,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !PreparedSnapshot {
        if (wait_ceiling_ms > contract.max_wait_ceiling_ms) {
            return error.InvalidWaitCeiling;
        }
        const entry = self.acquireEntry(execution_id) orelse return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        const waiter_id = self.nextReservationId();
        entry.mutex.lockUncancelable(zio);
        const captured = entry.backend() == .captured;
        if (!captured) {
            entry.mutex.unlock(zio);
            return error.TtyEffectRequired;
        }
        if (entry.active_waiter != null or entry.delivery.reservation != null) {
            entry.mutex.unlock(zio);
            return error.ExecutionBusy;
        }
        entry.active_waiter = waiter_id;
        entry.mutex.unlock(zio);
        defer self.clearActiveWaiter(entry, waiter_id);
        const started_ms = io_mod.milliTimestamp();
        while (true) {
            entry.mutex.lockUncancelable(zio);
            const terminal = entry.isTerminal();
            const preempted = entry.preempted_waiter == waiter_id;
            entry.mutex.unlock(zio);
            if (preempted) return error.WaitPreempted;
            if (terminal) break;
            if (cancel_flag) |flag| {
                if (flag.load(.seq_cst)) return error.Cancelled;
            }
            if (io_mod.milliTimestamp() - started_ms >= wait_ceiling_ms) break;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
        return self.prepareSnapshotForEntry(alloc, entry);
    }

    pub fn stop(
        self: *Runtime,
        alloc: Allocator,
        execution_id: []const u8,
        force: bool,
    ) !PreparedSnapshot {
        return self.stop_with_ceiling(
            alloc,
            execution_id,
            force,
            captured_stop_settle_timeout_ms,
        );
    }

    fn stop_with_ceiling(
        self: *Runtime,
        alloc: Allocator,
        execution_id: []const u8,
        force: bool,
        settle_timeout_ms: i64,
    ) !PreparedSnapshot {
        const entry = self.acquireEntry(execution_id) orelse return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        if (entry.backend() != .captured) {
            entry.mutex.unlock(zio);
            return error.TtyEffectRequired;
        }
        if (!entry.isTerminal()) {
            const next = contract.transition(entry.state, entry.barrier, .stop_requested);
            entry.state = next.state;
            entry.barrier = next.barrier;
            entry.force_cancel.store(force, .seq_cst);
            entry.cancel.store(true, .seq_cst);
            if (entry.active_waiter) |waiter_id| {
                entry.preempted_waiter = waiter_id;
            }
        }
        entry.mutex.unlock(zio);
        const started_ms = io_mod.milliTimestamp();
        while (true) {
            entry.mutex.lockUncancelable(zio);
            const terminal = entry.isTerminal();
            entry.mutex.unlock(zio);
            if (terminal) break;
            const now_ms = io_mod.milliTimestamp();
            if (stop_wait_expired(started_ms, now_ms, settle_timeout_ms)) {
                debug_trace.logf(
                    "core",
                    "managed execution stop became lost boundary=settle_deadline execution_id={s} force={s}",
                    .{ execution_id, if (force) "true" else "false" },
                );
                var prepared = try self.prepareSnapshotForEntry(alloc, entry);
                if (prepared.snapshot.state == .running) {
                    prepared.snapshot.state = .lost;
                    prepared.snapshot.output_incomplete = true;
                    if (prepared.snapshot.error_name) |name| alloc.free(name);
                    prepared.snapshot.error_name = try alloc.dupe(
                        u8,
                        "StopSettlementTimedOut",
                    );
                }
                return prepared;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
        return self.prepareSnapshotForEntry(alloc, entry);
    }

    pub fn list(self: *Runtime, alloc: Allocator) ![]ListItem {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        var result: std.ArrayList(ListItem) = .empty;
        errdefer {
            for (result.items) |*item| item.deinit(alloc);
            result.deinit(alloc);
        }
        for (self.entries) |candidate| {
            const entry = candidate orelse continue;
            entry.mutex.lockUncancelable(zio);
            defer entry.mutex.unlock(zio);
            if (entry.isTerminal() and
                (entry.backend() != .tty or entry.backend_state == .tombstone))
            {
                continue;
            }
            try result.append(alloc, .{
                .execution_id = try alloc.dupe(u8, entry.execution_id),
                .command = try alloc.dupe(u8, entry.command),
                .state = entry.statusSnapshot(),
                .backend = entry.backend(),
                .persistence = entry.persistence(),
            });
        }
        return result.toOwnedSlice(alloc);
    }

    pub fn commitDelivery(
        self: *Runtime,
        execution_id: []const u8,
        reservation_id: u64,
    ) !void {
        const entry = self.acquireEntry(execution_id) orelse return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        return self.commitEntryDelivery(entry, reservation_id);
    }

    fn commitEntryDelivery(
        self: *Runtime,
        entry: *Entry,
        reservation_id: u64,
    ) !void {
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        const reservation = entry.delivery.reservation orelse {
            entry.mutex.unlock(zio);
            return error.UnknownReservation;
        };
        const next = try entry.delivery.commit(reservation_id);
        const delivered: usize = @intCast(reservation.range.end - reservation.range.start);
        if (delivered > entry.output.items.len) {
            entry.mutex.unlock(zio);
            return error.InvalidOutputRange;
        }
        if (delivered != 0) {
            std.mem.copyForwards(
                u8,
                entry.output.items[0 .. entry.output.items.len - delivered],
                entry.output.items[delivered..],
            );
            entry.output.items.len -= delivered;
        }
        entry.delivery = next;
        entry.output_truncated = false;
        const terminal = entry.isTerminal();
        const should_remove = terminal and !entry.published_running;
        if (terminal and entry.published_running) self.clearAuthorityLocked(entry);
        entry.mutex.unlock(zio);
        if (should_remove) self.markDelete(entry);
    }

    pub fn cancelDelivery(
        self: *Runtime,
        execution_id: []const u8,
        reservation_id: u64,
    ) !void {
        const entry = self.acquireEntry(execution_id) orelse return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        return self.cancelEntryDelivery(entry, reservation_id);
    }

    fn cancelEntryDelivery(
        _: *Runtime,
        entry: *Entry,
        reservation_id: u64,
    ) !void {
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        entry.delivery = try entry.delivery.cancel(reservation_id);
        entry.mutex.unlock(zio);
    }

    pub fn commitReservation(
        self: *Runtime,
        reservation_id: u64,
    ) !void {
        const entry = self.acquireEntryForReservation(reservation_id) orelse
            return error.UnknownReservation;
        defer self.releaseEntry(entry);
        return self.commitEntryDelivery(entry, reservation_id);
    }

    pub fn cancelReservation(
        self: *Runtime,
        reservation_id: u64,
    ) !void {
        const entry = self.acquireEntryForReservation(reservation_id) orelse
            return error.UnknownReservation;
        defer self.releaseEntry(entry);
        return self.cancelEntryDelivery(entry, reservation_id);
    }

    pub fn shutdown(self: *Runtime) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.shutting_down) {
            self.mutex.unlock(zio);
            return;
        }
        self.shutting_down = true;
        var live: [contract.max_live_entries]*Entry = undefined;
        var live_len: usize = 0;
        for (self.entries) |candidate| {
            const entry = candidate orelse continue;
            entry.mutex.lockUncancelable(zio);
            if (!entry.isTerminal()) {
                entry.cancel.store(true, .seq_cst);
                entry.start_gate.set(zio);
                live[live_len] = entry;
                live_len += 1;
            }
            entry.mutex.unlock(zio);
        }
        self.mutex.unlock(zio);
        for (live[0..live_len]) |entry| self.joinEntry(entry);
    }

    const AdmissionResult = struct {
        entry: *Entry,
        created: bool,
    };

    fn admitCaptured(self: *Runtime, input: StartCapturedInput) !AdmissionResult {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.shutting_down) return error.RuntimeStopping;
        if (self.findEntryLocked(input.execution_id)) |existing| {
            if (!existing.matchesCapturedInput(input)) {
                return error.ExecutionIdentityConflict;
            }
            return .{ .entry = existing, .created = false };
        }
        const live_count = self.liveCountLocked() + self.pending_admissions;
        if (contract.decideAdmission(live_count) == .capacity_exhausted) {
            return error.ExecutionCapacityExceeded;
        }
        self.evictOldestTombstoneLocked();
        const slot = self.emptySlotLocked() orelse return error.ExecutionCapacityExceeded;
        const entry = try Entry.init(self, input);
        self.entries[slot] = entry;
        if (comptime builtin.single_threaded) {
            self.entries[slot] = null;
            entry.deinit();
            return error.ManagedExecutionUnavailable;
        } else {
            entry.thread = std.Thread.spawn(.{}, Entry.workerMain, .{entry}) catch |err| {
                self.entries[slot] = null;
                entry.deinit();
                return err;
            };
        }
        const next = contract.transition(entry.state, entry.barrier, .child_started);
        entry.state = next.state;
        entry.barrier = next.barrier;
        return .{ .entry = entry, .created = true };
    }

    fn prepareSnapshot(
        self: *Runtime,
        alloc: Allocator,
        execution_id: []const u8,
    ) !PreparedSnapshot {
        const entry = self.acquireEntry(execution_id) orelse return error.ExecutionNotFound;
        defer self.releaseEntry(entry);
        return self.prepareSnapshotForEntry(alloc, entry);
    }

    fn prepareSnapshotForEntry(
        self: *Runtime,
        alloc: Allocator,
        entry: *Entry,
    ) !PreparedSnapshot {
        const reservation_id = self.nextReservationId();
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        defer entry.mutex.unlock(zio);
        entry.delivery = try entry.delivery.prepare(
            reservation_id,
            entry.delivery.committed + entry.output.items.len,
        );
        errdefer entry.delivery = entry.delivery.cancel(reservation_id) catch entry.delivery;
        const metadata = if (entry.result) |result|
            result.command_result orelse return error.InvalidCommandResult
        else
            null;
        const execution_id = try alloc.dupe(u8, entry.execution_id);
        errdefer alloc.free(execution_id);
        const command = try alloc.dupe(u8, entry.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, entry.cwd);
        errdefer alloc.free(cwd);
        const output_delta = try alloc.dupe(u8, entry.output.items);
        errdefer alloc.free(output_delta);
        const output_file = if (entry.output_handle) |handle|
            try alloc.dupe(u8, handle)
        else
            null;
        errdefer if (output_file) |value| alloc.free(value);
        const error_name = if (entry.error_name) |name|
            try alloc.dupe(u8, name)
        else
            null;
        return .{
            .reservation_id = reservation_id,
            .snapshot = .{
                .execution_id = execution_id,
                .command = command,
                .cwd = cwd,
                .retained = entry.published_running or !entry.isTerminal(),
                .state = entry.statusSnapshot(),
                .backend = entry.backend(),
                .persistence = entry.persistence(),
                .output_delta = output_delta,
                .output_truncated = entry.output_truncated or
                    if (metadata) |value| value.truncated else false,
                .output_incomplete = entry.output_incomplete or
                    if (metadata) |value| value.output_incomplete else false,
                .duration_ms = if (metadata) |value| value.duration_ms else null,
                .output_file = output_file,
                .output_framed_bytes = entry.output_framed_bytes,
                .stdout_bytes = if (metadata) |value|
                    value.stdout_bytes
                else
                    entry.stdout_bytes,
                .stderr_bytes = if (metadata) |value|
                    value.stderr_bytes
                else
                    entry.stderr_bytes,
                .error_name = error_name,
            },
        };
    }

    fn updateTtyEntry(
        self: *Runtime,
        alloc: Allocator,
        entry: *Entry,
        input: TtyUpdate,
    ) !PreparedSnapshot {
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        if (entry.backend() != .tty or entry.backend_state == .tombstone) {
            entry.mutex.unlock(zio);
            return error.InvalidBackend;
        }
        applyTtyUpdateLocked(entry, input) catch |err| {
            entry.mutex.unlock(zio);
            return err;
        };
        entry.mutex.unlock(zio);
        return self.prepareSnapshotForEntry(alloc, entry);
    }

    fn nextReservationId(self: *Runtime) u64 {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const result = self.next_reservation_id;
        self.next_reservation_id +%= 1;
        if (self.next_reservation_id == 0) self.next_reservation_id = 1;
        return result;
    }

    fn clearActiveWaiter(
        _: *Runtime,
        entry: *Entry,
        waiter_id: u64,
    ) void {
        const zio = io_mod.getIo();
        entry.mutex.lockUncancelable(zio);
        if (entry.active_waiter == waiter_id) entry.active_waiter = null;
        if (entry.preempted_waiter == waiter_id) entry.preempted_waiter = null;
        entry.mutex.unlock(zio);
    }

    fn cancelUnpublished(self: *Runtime, execution_id: []const u8) void {
        const entry = self.acquireEntry(execution_id) orelse return;
        entry.cancel.store(true, .seq_cst);
        entry.start_gate.set(io_mod.getIo());
        self.joinEntry(entry);
        self.markDelete(entry);
        self.releaseEntry(entry);
    }

    fn acquireEntry(self: *Runtime, execution_id: []const u8) ?*Entry {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const entry = self.findEntryLocked(execution_id) orelse return null;
        entry.active_operations += 1;
        return entry;
    }

    fn acquireEntryForReservation(
        self: *Runtime,
        reservation_id: u64,
    ) ?*Entry {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.entries) |candidate| {
            const entry = candidate orelse continue;
            entry.mutex.lockUncancelable(zio);
            const matches = if (entry.delivery.reservation) |reservation|
                reservation.waiter_id == reservation_id
            else
                false;
            entry.mutex.unlock(zio);
            if (matches) {
                entry.active_operations += 1;
                return entry;
            }
        }
        return null;
    }

    fn releaseEntry(self: *Runtime, entry: *Entry) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        std.debug.assert(entry.active_operations > 0);
        entry.active_operations -= 1;
        const destroy = entry.active_operations == 0 and entry.pending_delete;
        if (destroy) self.removeEntryLocked(entry);
        self.mutex.unlock(zio);
        if (destroy) {
            self.joinEntry(entry);
            entry.deinit();
        }
    }

    fn markDelete(self: *Runtime, entry: *Entry) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        entry.pending_delete = true;
        self.mutex.unlock(zio);
    }

    fn clearAuthorityLocked(self: *Runtime, entry: *Entry) void {
        if (entry.backend_state == .tombstone) return;
        self.joinEntry(entry);
        switch (entry.backend_state) {
            .captured => |*captured| captured.route.deinit(entry.arena.allocator()),
            .tty => {},
            .tombstone => unreachable,
        }
        if (entry.replay_capture) |capture| {
            capture.releaseRetained(entry.arena.allocator());
            entry.replay_capture = null;
        }
        deinitReplayCapability(self, entry.replay_capability);
        entry.replay_capability = null;
        entry.backend_state = .tombstone;
        entry.tombstone_sequence.store(
            self.next_tombstone_sequence.fetchAdd(1, .seq_cst),
            .seq_cst,
        );
    }

    fn joinEntry(_: *Runtime, entry: *Entry) void {
        if (entry.thread) |thread| {
            thread.join();
            entry.thread = null;
        }
    }

    fn findEntryLocked(self: *Runtime, execution_id: []const u8) ?*Entry {
        for (self.entries) |candidate| {
            const entry = candidate orelse continue;
            if (std.mem.eql(u8, entry.execution_id, execution_id)) return entry;
        }
        return null;
    }

    fn liveCountLocked(self: *Runtime) usize {
        var count: usize = 0;
        const zio = io_mod.getIo();
        for (self.entries) |candidate| {
            const entry = candidate orelse continue;
            entry.mutex.lockUncancelable(zio);
            if (entry.backend_state != .tombstone) count += 1;
            entry.mutex.unlock(zio);
        }
        return count;
    }

    fn emptySlotLocked(self: *Runtime) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry == null) return index;
        }
        return null;
    }

    fn evictOldestTombstoneLocked(self: *Runtime) void {
        var tombstone_count: usize = 0;
        var oldest: ?*Entry = null;
        for (self.entries) |candidate| {
            const entry = candidate orelse continue;
            if (entry.backend_state != .tombstone) continue;
            tombstone_count += 1;
            if (entry.active_operations != 0) continue;
            if (oldest == null or
                entry.tombstone_sequence.load(.seq_cst) <
                    oldest.?.tombstone_sequence.load(.seq_cst))
            {
                oldest = entry;
            }
        }
        if (tombstone_count < contract.max_tombstones) return;
        const entry = oldest orelse return;
        self.removeEntryLocked(entry);
        entry.deinit();
    }

    fn removeEntryLocked(self: *Runtime, entry: *Entry) void {
        for (&self.entries) |*slot| {
            if (slot.* != entry) continue;
            slot.* = null;
            return;
        }
        unreachable;
    }
};

fn applyTtyUpdateLocked(entry: *Entry, input: TtyUpdate) !void {
    const tty = switch (entry.backend_state) {
        .tty => |*value| value,
        .captured, .tombstone => return error.InvalidBackend,
    };
    if (input.next_cursor) |cursor| {
        try cursor.validate();
        if (cursor.segment < tty.cursor.segment or
            (cursor.segment == tty.cursor.segment and
                cursor.offset < tty.cursor.offset))
        {
            return error.InvalidTtyCursor;
        }
        tty.cursor = cursor;
    }
    if (!entry.state.isTerminal()) {
        entry.state = contractStateFromSnapshot(input.state);
    }
    entry.published_running = entry.published_running or input.published_running;
    const replay_output = input.replay_output orelse input.output;
    if (replay_output.len != 0) {
        entry.stdout_bytes +|= replay_output.len;
        if (entry.replay_capture) |capture| {
            capture.appendAccepted(
                entry.arena.allocator(),
                .stdout,
                replay_output,
            );
        }
    }
    try entry.appendBoundedOutput(input.output);
    entry.output_truncated = entry.output_truncated or input.output_incomplete;
    entry.output_incomplete = entry.output_incomplete or input.output_incomplete;
    if (input.error_name) |error_name| {
        entry.error_name = try entry.arena.allocator().dupe(u8, error_name);
    }
    if (entry.isTerminal()) entry.finalizeReplayLocked();
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    if (left) |value| return std.mem.eql(u8, value, right.?);
    return true;
}

fn duplicateReplayCapability(
    runtime: *Runtime,
    source: ?*const session_child_store.SessionChildCapability,
) !?*session_child_store.SessionChildCapability {
    const value = source orelse return null;
    const owned = try runtime.alloc.create(
        session_child_store.SessionChildCapability,
    );
    errdefer runtime.alloc.destroy(owned);
    owned.* = try value.duplicate(runtime.alloc);
    return owned;
}

fn deinitReplayCapability(
    runtime: *Runtime,
    capability: ?*session_child_store.SessionChildCapability,
) void {
    const value = capability orelse return;
    value.deinit();
    runtime.alloc.destroy(value);
}

fn dupeEnvironment(
    alloc: Allocator,
    environment: command_environment.Environment,
) !command_environment.Environment {
    return switch (environment) {
        .legacy => .legacy,
        .workspace_clean => .workspace_clean,
        .clean => |path| .{ .clean = try alloc.dupe(u8, path) },
        .user => |path| .{ .user = try alloc.dupe(u8, path) },
    };
}

fn rebindAuthority(
    authority: command_admission.CommandExecutionAuthority,
    command_ctx: command_admission.CommandContext,
) command_admission.CommandExecutionAuthority {
    return switch (authority) {
        .direct_only => .{ .direct_only = .init(command_ctx) },
        .shell_allowed => |shell| .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = shell.source,
        } },
    };
}

fn statusFromResult(
    execution_id: []const u8,
    result: command_contract.RunCommandResult,
) command_contract.CommandStatus {
    const command = result.command_result orelse {
        debug_trace.logf(
            "core",
            "managed execution termination indeterminate boundary=missing_command_result execution_id={s}",
            .{execution_id},
        );
        return .indeterminate;
    };
    if (command.termination_indeterminate) {
        debug_trace.logf(
            "core",
            "managed execution termination indeterminate boundary=command_result execution_id={s}",
            .{execution_id},
        );
        return .indeterminate;
    }
    if (command.exit_code) |code| return .{ .exit_code = code };
    if (command.signal) |signal| return .{ .signal = signal };
    return .finished;
}

fn state_for_worker_error(err: anyerror) contract.State {
    return if (err == error.TimeoutExpired)
        .{ .stopped = null }
    else
        .lost;
}

test "worker errors do not turn ambiguous cancellation into success" {
    try std.testing.expectEqual(
        contract.State.lost,
        state_for_worker_error(error.Cancelled),
    );
    try std.testing.expectEqual(
        contract.State{ .stopped = null },
        state_for_worker_error(error.TimeoutExpired),
    );
    try std.testing.expectEqual(
        contract.State.lost,
        state_for_worker_error(error.Unexpected),
    );
}

fn stop_wait_expired(started_ms: i64, now_ms: i64, settle_timeout_ms: i64) bool {
    return now_ms >= started_ms and
        now_ms - started_ms >= settle_timeout_ms;
}

test "stop wait expires only at its deterministic bound" {
    try std.testing.expect(!stop_wait_expired(1_000, 999, 100));
    try std.testing.expect(!stop_wait_expired(1_000, 1_099, 100));
    try std.testing.expect(stop_wait_expired(1_000, 1_100, 100));
}

fn contractStateFromSnapshot(state: SnapshotState) contract.State {
    return switch (state) {
        .running => .running,
        .completed => |status| .{ .completed = status },
        .stopped => |status| .{ .stopped = status },
        .lost => .lost,
    };
}

fn testAuthority(input: StartCapturedInput) command_admission.CommandExecutionAuthority {
    const ctx = command_admission.CommandContext{
        .command = input.command,
        .resolved_cwd = input.cwd,
        .target_os = builtin.os.tag,
        .environment = input.environment,
    };
    return .{ .shell_allowed = .{
        .fingerprint = .init(ctx),
        .source = .yolo,
    } };
}

test "captured managed execution yields one handle and delivers ordered output once" {
    if (comptime builtin.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var input = StartCapturedInput{
        .execution_id = "managed-yield",
        .command = "printf first; printf second",
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 4096,
        .timeout_ms = 2_000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    };
    input.authority = testAuthority(input);
    var started = try runtime.startCaptured(alloc, input);
    defer started.deinit(alloc);
    try std.testing.expectEqual(SnapshotState.running, started.snapshot.state);
    try std.testing.expectEqual(@as(?[]u8, null), try runtime.captured_command_alloc(alloc, "missing"));
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, runtime.captured_command_alloc(failing.allocator(), input.execution_id));
    const command = (try runtime.captured_command_alloc(alloc, input.execution_id)).?;
    defer alloc.free(command);
    try std.testing.expectEqualStrings(input.command, command);
    command[0] = 'P';
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);

    var completed = try runtime.wait(alloc, input.execution_id, 2_000, null);
    defer completed.deinit(alloc);
    try std.testing.expect(completed.snapshot.state != .running);
    const first_in_started = std.mem.find(u8, started.snapshot.output_delta, "first") != null;
    const first_in_completed = std.mem.find(u8, completed.snapshot.output_delta, "first") != null;
    const second_in_started = std.mem.find(u8, started.snapshot.output_delta, "second") != null;
    const second_in_completed = std.mem.find(u8, completed.snapshot.output_delta, "second") != null;
    try std.testing.expect(first_in_started != first_in_completed);
    try std.testing.expect(second_in_started != second_in_completed);
    try runtime.commitDelivery(completed.snapshot.execution_id, completed.reservation_id);

    var repeated = try runtime.wait(alloc, input.execution_id, 0, null);
    defer repeated.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), repeated.snapshot.output_delta.len);
    try runtime.commitDelivery(repeated.snapshot.execution_id, repeated.reservation_id);
    const retained_command = (try runtime.captured_command_alloc(alloc, input.execution_id)).?;
    defer alloc.free(retained_command);
    try std.testing.expectEqualStrings(input.command, retained_command);
    try std.testing.expect(runtime.isTombstone(input.execution_id));
}

test "captured stop returns lost when its worker cannot settle" {
    if (comptime builtin.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    const BlockingOutput = struct {
        fn append(
            raw: *anyopaque,
            _: ?types.ToolLifecycleId,
            _: command_contract.CommandOutputStream,
            _: []const u8,
        ) !void {
            const flags: *[2]std.atomic.Value(bool) = @ptrCast(@alignCast(raw));
            flags[0].store(true, .seq_cst);
            while (!flags[1].load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        }
    };
    var callback_flags = [_]std.atomic.Value(bool){
        .init(false),
        .init(false),
    };
    var input = StartCapturedInput{
        .execution_id = "managed-stop-stalled",
        .command = "printf 'ready\\n'; sleep 30",
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 4096,
        .timeout_ms = null,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
        .output_chunk_ctx = &callback_flags,
        .on_output_chunk = BlockingOutput.append,
    };
    input.authority = testAuthority(input);
    var started = try runtime.startCaptured(alloc, input);
    defer started.deinit(alloc);
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);

    const callback_deadline_ms = io_mod.milliTimestamp() + 2_000;
    while (!callback_flags[0].load(.seq_cst) and
        io_mod.milliTimestamp() < callback_deadline_ms)
    {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(callback_flags[0].load(.seq_cst));

    var stop_finished = std.atomic.Value(bool).init(false);
    var stop_lost = std.atomic.Value(bool).init(false);
    var stop_failed = std.atomic.Value(bool).init(false);
    const StopTask = struct {
        fn run(
            rt: *Runtime,
            finished: *std.atomic.Value(bool),
            lost: *std.atomic.Value(bool),
            failed: *std.atomic.Value(bool),
        ) void {
            var stopped = rt.stop(std.testing.allocator, "managed-stop-stalled", true) catch {
                failed.store(true, .seq_cst);
                finished.store(true, .seq_cst);
                return;
            };
            lost.store(
                stopped.snapshot.state == .lost and
                    stopped.snapshot.output_incomplete and
                    if (stopped.snapshot.error_name) |name|
                        std.mem.eql(u8, name, "StopSettlementTimedOut")
                    else
                        false,
                .seq_cst,
            );
            rt.commitDelivery(stopped.snapshot.execution_id, stopped.reservation_id) catch {
                failed.store(true, .seq_cst);
            };
            stopped.deinit(std.testing.allocator);
            finished.store(true, .seq_cst);
        }
    };
    const stop_thread = try std.Thread.spawn(
        .{},
        StopTask.run,
        .{ &runtime, &stop_finished, &stop_lost, &stop_failed },
    );
    io_mod.sleep(250 * std.time.ns_per_ms);
    const settled_before_release = stop_finished.load(.seq_cst);
    callback_flags[1].store(true, .seq_cst);
    stop_thread.join();

    try std.testing.expect(settled_before_release);
    try std.testing.expect(stop_lost.load(.seq_cst));
    try std.testing.expect(!stop_failed.load(.seq_cst));
}

test "generated captured execution identities do not depend on provider call ids" {
    if (comptime builtin.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var first_id_buffer: [64]u8 = undefined;
    const first_id = try runtime.generatedId(&first_id_buffer);
    var first = StartCapturedInput{
        .execution_id = first_id,
        .command = "sleep 1",
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 1024,
        .timeout_ms = 2_000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    };
    first.authority = testAuthority(first);
    var started = try runtime.startCaptured(alloc, first);
    defer started.deinit(alloc);
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);

    var second_id_buffer: [64]u8 = undefined;
    const second_id = try runtime.generatedId(&second_id_buffer);
    try std.testing.expect(!std.mem.eql(u8, first_id, second_id));

    var second = first;
    second.execution_id = second_id;
    second.command = "printf should-run";
    second.authority = testAuthority(second);
    var next = try runtime.startCaptured(alloc, second);
    defer next.deinit(alloc);
    try runtime.commitDelivery(next.snapshot.execution_id, next.reservation_id);
}

test "captured managed execution capacity rejects before spawn" {
    if (comptime builtin.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var reservations: usize = 0;
    defer while (reservations != 0) {
        runtime.releaseTtyCapacity();
        reservations -= 1;
    };
    for (0..contract.max_live_entries) |_| {
        try runtime.reserveTtyCapacity();
        reservations += 1;
    }
    var overflow = StartCapturedInput{
        .execution_id = "managed-capacity-overflow",
        .command = "printf should-not-run",
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 1024,
        .timeout_ms = 1_000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    };
    overflow.authority = testAuthority(overflow);
    try std.testing.expectError(
        error.ExecutionCapacityExceeded,
        runtime.startCaptured(alloc, overflow),
    );
}

test "captured managed execution exposes full output only by opaque replay handle" {
    if (comptime builtin.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var input = StartCapturedInput{
        .execution_id = "managed-large-output",
        .command = "i=0; while [ $i -lt 100 ]; do printf 'chunk-%03d\\n' \"$i\"; i=$((i+1)); done",
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 64,
        .timeout_ms = 2_000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    };
    input.authority = testAuthority(input);
    var started = try runtime.startCaptured(alloc, input);
    defer started.deinit(alloc);
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);
    var completed = try runtime.wait(alloc, input.execution_id, 2_000, null);
    defer completed.deinit(alloc);
    try std.testing.expect(completed.snapshot.output_truncated);
    const handle = completed.snapshot.output_file orelse return error.TestExpectedEqual;
    try std.testing.expect(std.fs.path.dirname(handle) == null);
    try runtime.commitDelivery(completed.snapshot.execution_id, completed.reservation_id);

    var reader = try command_replay_store.Reader.openEphemeralHandle(
        alloc,
        runtime.replayStore(),
        handle,
    );
    defer reader.deinit();
    var replay: std.ArrayList(u8) = .empty;
    defer replay.deinit(alloc);
    while (try reader.next(alloc)) |frame| {
        defer alloc.free(frame.payload);
        try replay.appendSlice(alloc, frame.payload);
    }
    try std.testing.expect(std.mem.find(u8, replay.items, "chunk-099") != null);
}

test "managed execution retains thirty two authority free terminal snapshots" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var ids: [contract.max_tombstones + 1][32]u8 = undefined;
    var id_lengths: [ids.len]usize = undefined;
    for (0..ids.len) |index| {
        const id = try std.fmt.bufPrint(&ids[index], "tty-tombstone-{d}", .{index});
        id_lengths[index] = id.len;
        var prepared = try runtime.registerTty(alloc, .{
            .execution_id = id,
            .command = "true",
            .state = .{ .completed = .{ .exit_code = 0 } },
            .max_output_bytes = 64,
            .published_running = true,
        });
        defer prepared.deinit(alloc);
        try runtime.commitDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        );
    }
    try std.testing.expectError(
        error.ExecutionNotFound,
        runtime.retainedTerminalSnapshot(alloc, ids[0][0..id_lengths[0]]),
    );
    var retained = (try runtime.retainedTerminalSnapshot(
        alloc,
        ids[ids.len - 1][0..id_lengths[id_lengths.len - 1]],
    )).?;
    defer retained.deinit(alloc);
    try std.testing.expect(retained.snapshot.state != .running);
    try runtime.commitDelivery(
        retained.snapshot.execution_id,
        retained.reservation_id,
    );
}

test "delivery reservation pins a tombstone across capacity eviction" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var ids: [contract.max_tombstones + 1][32]u8 = undefined;
    var lengths: [ids.len]usize = undefined;
    for (0..contract.max_tombstones) |index| {
        const id = try std.fmt.bufPrint(&ids[index], "tty-pinned-{d}", .{index});
        lengths[index] = id.len;
        var prepared = try runtime.registerTty(alloc, .{
            .execution_id = id,
            .command = "true",
            .state = .{ .completed = .{ .exit_code = 0 } },
            .max_output_bytes = 64,
            .published_running = true,
        });
        defer prepared.deinit(alloc);
        try runtime.commitDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        );
    }

    var reserved = (try runtime.retainedTerminalSnapshot(
        alloc,
        ids[0][0..lengths[0]],
    )).?;
    defer reserved.deinit(alloc);
    const pinned = runtime.acquireEntryForReservation(
        reserved.reservation_id,
    ) orelse return error.TestExpectedEqual;
    defer runtime.releaseEntry(pinned);

    const replacement_id = try std.fmt.bufPrint(
        &ids[contract.max_tombstones],
        "tty-pinned-{d}",
        .{contract.max_tombstones},
    );
    lengths[contract.max_tombstones] = replacement_id.len;
    var replacement = try runtime.registerTty(alloc, .{
        .execution_id = replacement_id,
        .command = "true",
        .state = .{ .completed = .{ .exit_code = 0 } },
        .max_output_bytes = 64,
        .published_running = true,
    });
    defer replacement.deinit(alloc);
    try runtime.commitDelivery(
        replacement.snapshot.execution_id,
        replacement.reservation_id,
    );

    try runtime.commitEntryDelivery(pinned, reserved.reservation_id);
    var retained = (try runtime.retainedTerminalSnapshot(
        alloc,
        ids[0][0..lengths[0]],
    )).?;
    defer retained.deinit(alloc);
    try runtime.commitDelivery(
        retained.snapshot.execution_id,
        retained.reservation_id,
    );
    try std.testing.expectError(
        error.ExecutionNotFound,
        runtime.retainedTerminalSnapshot(
            alloc,
            ids[1][0..lengths[1]],
        ),
    );
}

test "terminal tombstone retains raw output behind an opaque replay handle" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var prepared = try runtime.registerTty(alloc, .{
        .execution_id = "tty-replay",
        .command = "full-screen-command",
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output = "current screen",
        .replay_output = "raw-frame-one\nraw-frame-two\n",
        .max_output_bytes = 8,
        .published_running = true,
    });
    defer prepared.deinit(alloc);
    const handle = prepared.snapshot.output_file orelse
        return error.TestExpectedEqual;
    try std.testing.expect(prepared.snapshot.output_truncated);
    try runtime.commitDelivery(
        prepared.snapshot.execution_id,
        prepared.reservation_id,
    );
    var reader = try command_replay_store.Reader.openEphemeralHandle(
        alloc,
        runtime.replayStore(),
        handle,
    );
    defer reader.deinit();
    const frame = (try reader.next(alloc)) orelse return error.TestExpectedEqual;
    defer alloc.free(frame.payload);
    try std.testing.expectEqualStrings(
        "raw-frame-one\nraw-frame-two\n",
        frame.payload,
    );
}

test "terminal tombstone releases consumed replay authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var prepared = try runtime.registerTty(alloc, .{
        .execution_id = "tty-saved-replay",
        .command = "saved-replay-command",
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output = "current screen",
        .replay_output = "durable raw output\n",
        .max_output_bytes = 64,
        .published_running = true,
        .replay_capability = &capability,
    });
    defer prepared.deinit(alloc);
    const handle = prepared.snapshot.output_file orelse
        return error.TestExpectedEqual;
    try runtime.commitDelivery(
        prepared.snapshot.execution_id,
        prepared.reservation_id,
    );

    const entry = runtime.acquireEntry(prepared.snapshot.execution_id) orelse
        return error.TestExpectedEqual;
    defer runtime.releaseEntry(entry);
    try std.testing.expect(entry.backend_state == .tombstone);
    try std.testing.expect(entry.replay_capture == null);
    try std.testing.expect(entry.replay_capability == null);

    var reader = try command_replay_store.Reader.openHandle(
        alloc,
        &capability,
        handle,
    );
    defer reader.deinit();
    const frame = (try reader.next(alloc)) orelse return error.TestExpectedEqual;
    defer alloc.free(frame.payload);
    try std.testing.expectEqualStrings("durable raw output\n", frame.payload);
}

test "TTY cursor advances monotonically and delivers each delta once" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    var started = try runtime.registerTty(alloc, .{
        .execution_id = "tty-cursor",
        .command = "interactive",
        .state = .running,
        .next_cursor = .{ .segment = 1, .offset = 5 },
        .max_output_bytes = 64,
        .published_running = true,
    });
    defer started.deinit(alloc);
    try runtime.commitDelivery(
        started.snapshot.execution_id,
        started.reservation_id,
    );
    try std.testing.expectEqual(@as(?[]u8, null), try runtime.captured_command_alloc(alloc, "tty-cursor"));

    try runtime.refreshTty(.{
        .execution_id = "tty-cursor",
        .command = "interactive",
        .state = .running,
        .output = "ab",
        .replay_output = "ab",
        .next_cursor = .{ .segment = 1, .offset = 7 },
        .max_output_bytes = 64,
        .published_running = true,
    });
    var delivered = try runtime.updateTty(alloc, .{
        .execution_id = "tty-cursor",
        .command = "interactive",
        .state = .running,
        .next_cursor = .{ .segment = 1, .offset = 7 },
        .max_output_bytes = 64,
        .published_running = true,
    });
    defer delivered.deinit(alloc);
    try std.testing.expectEqualStrings("ab", delivered.snapshot.output_delta);
    try runtime.commitDelivery(
        delivered.snapshot.execution_id,
        delivered.reservation_id,
    );
    try std.testing.expectEqual(
        TtyCursor{ .segment = 1, .offset = 7 },
        runtime.ttyCursorFor("tty-cursor").?,
    );
    try std.testing.expectError(error.InvalidTtyCursor, runtime.refreshTty(.{
        .execution_id = "tty-cursor",
        .command = "interactive",
        .state = .running,
        .next_cursor = .{ .segment = 1, .offset = 6 },
        .max_output_bytes = 64,
        .published_running = true,
    }));
}

const std = @import("std");
const builtin = @import("builtin");
const command_effect = @import("../shell_command/command_effect.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_runner = @import("../execution/command_runner.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const direct_output_limit_bytes: usize = 65_536;
const direct_output_read_chunk_bytes: usize = 4096;

const DirectOutputProjector = struct {
    utf8_pending: [3]u8 = undefined,
    utf8_pending_len: u2 = 0,
    escaped_controls: usize = 0,
    escaped_invalid: usize = 0,

    fn push(
        self: *DirectOutputProjector,
        alloc: std.mem.Allocator,
        raw: []const u8,
        projected: *std.ArrayList(u8),
    ) !void {
        var combined: [direct_output_read_chunk_bytes + 3]u8 = undefined;
        const pending_len: usize = self.utf8_pending_len;
        @memcpy(combined[0..pending_len], self.utf8_pending[0..pending_len]);
        @memcpy(combined[pending_len .. pending_len + raw.len], raw);
        const bytes = combined[0 .. pending_len + raw.len];
        self.utf8_pending_len = 0;

        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            if (byte < 0x80) {
                if (byte == '\n') {
                    try projected.append(alloc, byte);
                } else if (byte < 0x20 or byte == 0x7f) {
                    self.escaped_controls += 1;
                    try appendByteEscape(alloc, projected, byte);
                } else {
                    try projected.append(alloc, byte);
                }
                index += 1;
                continue;
            }

            const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch {
                self.escaped_invalid += 1;
                try appendByteEscape(alloc, projected, byte);
                index += 1;
                continue;
            };
            if (bytes.len - index < sequence_len) {
                const remainder = bytes[index..];
                @memcpy(self.utf8_pending[0..remainder.len], remainder);
                self.utf8_pending_len = @intCast(remainder.len);
                break;
            }

            const sequence = bytes[index .. index + sequence_len];
            const scalar = std.unicode.utf8Decode(sequence) catch {
                self.escaped_invalid += 1;
                try appendByteEscape(alloc, projected, byte);
                index += 1;
                continue;
            };
            if (scalar >= 0x80 and scalar <= 0x9f) {
                self.escaped_controls += 1;
                try appendC1Escape(alloc, projected, @intCast(scalar));
            } else {
                try projected.appendSlice(alloc, sequence);
            }
            index += sequence_len;
        }
    }

    fn finish(
        self: *DirectOutputProjector,
        alloc: std.mem.Allocator,
        projected: *std.ArrayList(u8),
    ) !void {
        for (self.utf8_pending[0..self.utf8_pending_len]) |byte| {
            self.escaped_invalid += 1;
            try appendByteEscape(alloc, projected, byte);
        }
        self.utf8_pending_len = 0;
    }
};

fn appendByteEscape(
    alloc: std.mem.Allocator,
    projected: *std.ArrayList(u8),
    byte: u8,
) !void {
    const digits = "0123456789abcdef";
    try projected.appendSlice(alloc, &.{
        '\\',
        'x',
        digits[byte >> 4],
        digits[byte & 0x0f],
    });
}

fn appendC1Escape(
    alloc: std.mem.Allocator,
    projected: *std.ArrayList(u8),
    byte: u8,
) !void {
    const digits = "0123456789abcdef";
    try projected.appendSlice(alloc, &.{
        '\\',
        'u',
        '{',
        '0',
        '0',
        digits[byte >> 4],
        digits[byte & 0x0f],
        '}',
    });
}

const DirectOutputBudget = struct {
    limit: usize,
    admitted: usize = 0,
    tripped: bool = false,
    lock: std.Io.Mutex = .init,

    const Charge = struct {
        admit_chunk: bool,
        trip_owner: bool,
    };

    fn charge(self: *DirectOutputBudget, observed_len: usize) Charge {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if (self.tripped) {
            return .{ .admit_chunk = false, .trip_owner = false };
        }
        if (observed_len <= self.limit - self.admitted) {
            self.admitted += observed_len;
            return .{ .admit_chunk = true, .trip_owner = false };
        }
        self.tripped = true;
        return .{ .admit_chunk = false, .trip_owner = true };
    }

    fn remaining(self: *DirectOutputBudget) usize {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.limit - self.admitted;
    }
};

pub fn executeDirectReadOnly(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
) !command_contract.RunCommandResult {
    return executeDirectReadOnlyWithLimit(cfg, alloc, plan, direct_output_limit_bytes);
}

fn executeDirectReadOnlyWithLimit(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
    output_limit: usize,
) !command_contract.RunCommandResult {
    return executeDirectReadOnlyWithLimitAndTestControls(cfg, alloc, plan, output_limit, .{});
}

const DirectExecutionTestControls = struct {
    context: ?*anyopaque = null,
    after_spawn: ?*const fn (*anyopaque, usize, *const std.process.Child) void = null,
};

fn executeDirectReadOnlyWithLimitAndTestControls(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
    output_limit: usize,
    test_controls: DirectExecutionTestControls,
) !command_contract.RunCommandResult {
    if (plan.stages.len == 0) return error.InvalidDirectPlan;
    if (plan.stages.len > command_effect.max_direct_pipeline_stages) {
        return error.InvalidDirectPlan;
    }
    var execution_cfg = cfg;
    if (execution_cfg.timeout_ms != null and execution_cfg.timeout_started_ms == null) {
        execution_cfg.timeout_started_ms = io_mod.milliTimestamp();
    }
    try checkControl(execution_cfg);

    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        return error.UnsupportedDirectPlatform;
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var children = try scratch.alloc(std.process.Child, plan.stages.len);
    var child_count: usize = 0;
    var group_id: ?std.posix.pid_t = null;
    var pre_worker_cleanup_pending = true;
    errdefer if (pre_worker_cleanup_pending) {
        cleanupChildren(children[0..child_count], group_id);
    };
    const started_ms = io_mod.milliTimestamp();

    while (child_count < plan.stages.len) : (child_count += 1) {
        try checkControl(execution_cfg);
        const stage = plan.stages[child_count];
        var environment = try environmentForProfile(scratch, stage.environment_profile);
        defer environment.deinit();

        const child = std.process.spawn(io_mod.getIo(), .{
            .argv = stage.argv,
            .cwd = .{ .path = plan.cwd },
            .environ_map = &environment,
            .stdin = if (child_count == 0) .ignore else .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi)
                (if (child_count == 0) 0 else group_id)
            else
                null,
        }) catch |err| {
            return switch (err) {
                error.FileNotFound => error.DirectExecutableUnavailable,
                else => err,
            };
        };
        children[child_count] = child;
        if (child_count == 0 and builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            group_id = child.id;
        }
        if (test_controls.after_spawn) |after_spawn| {
            after_spawn(test_controls.context.?, child_count, &children[child_count]);
        }
    }

    var output = DirectOutput.init(alloc, execution_cfg);
    defer output.deinit();
    var shared: SharedExecution = .{
        .cfg = execution_cfg,
        .budget = .{ .limit = output_limit },
        .output = &output,
    };

    const worker_count = plan.stages.len * 2;
    const workers = try scratch.alloc(OutputWorker, worker_count);
    var initialized_workers: usize = 0;

    for (0..plan.stages.len - 1) |index| {
        workers[initialized_workers] = .{
            .shared = &shared,
            .source = children[index].stdout.?,
            .destination = children[index + 1].stdin.?,
            .kind = .relay,
        };
        children[index].stdout = null;
        children[index + 1].stdin = null;
        initialized_workers += 1;
    }

    workers[initialized_workers] = .{
        .shared = &shared,
        .source = children[plan.stages.len - 1].stdout.?,
        .kind = .{ .projected = .stdout },
    };
    children[plan.stages.len - 1].stdout = null;
    initialized_workers += 1;

    for (children[0..child_count]) |*child| {
        workers[initialized_workers] = .{
            .shared = &shared,
            .source = child.stderr.?,
            .kind = .{ .projected = .stderr },
        };
        child.stderr = null;
        initialized_workers += 1;
    }
    std.debug.assert(initialized_workers == worker_count);
    pre_worker_cleanup_pending = false;

    var started_workers: usize = 0;
    while (started_workers < workers.len) : (started_workers += 1) {
        workers[started_workers].thread = std.Thread.spawn(
            .{},
            OutputWorker.run,
            .{&workers[started_workers]},
        ) catch |err| {
            shared.commit(.output_failure, err);
            signalGroup(group_id, true);
            for (workers[started_workers..]) |*worker| worker.closeUnstarted();
            for (workers[0..started_workers]) |*worker| worker.thread.?.join();
            waitChildren(children[0..child_count]);
            const failure = shared.failure() orelse err;
            debug_trace.logf(
                "core",
                "direct command worker start failed route=direct_read_only cause={s} limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} children_reaped={d} workers_joined={d} artifact=false",
                .{
                    @tagName(shared.cause.?),
                    shared.budget.limit,
                    shared.budget.admitted,
                    shared.budget.remaining(),
                    child_count,
                    started_workers,
                },
            );
            return failure;
        };
    }

    var termination_started_ms: ?i64 = null;
    var force_kill_sent = false;
    while (!allWorkersDone(workers)) {
        if (!shared.isStopping()) {
            if (execution_cfg.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) shared.commit(.cancelled, error.Cancelled);
            }
            if (!shared.isStopping() and deadlineExpired(execution_cfg)) {
                shared.commit(.timed_out, error.TimeoutExpired);
            }
        }
        if (shared.isStopping()) {
            const now = io_mod.milliTimestamp();
            if (termination_started_ms == null) {
                signalGroup(group_id, false);
                termination_started_ms = now;
            } else if (!force_kill_sent and now - termination_started_ms.? >= 800) {
                signalGroup(group_id, true);
                force_kill_sent = true;
            }
        }
        io_mod.sleep(5 * std.time.ns_per_ms);
    }

    for (workers) |*worker| worker.thread.?.join();

    var final_term: std.process.Child.Term = .{ .unknown = 0 };
    for (children[0..child_count], 0..) |*child, index| {
        const term = child.wait(io_mod.getIo()) catch |err| {
            shared.commit(.output_failure, err);
            continue;
        };
        if (index + 1 == child_count) final_term = term;
    }

    if (shared.failure()) |failure| {
        if (shared.cause == .timed_out) {
            output.flushCallbacks() catch |err| debug_trace.logf(
                "core",
                "direct command timeout callback flush failed err={s}",
                .{@errorName(err)},
            );
        }
        debug_trace.logf(
            "core",
            "direct command terminated route=direct_read_only cause={s} limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} projected_bytes={d} escaped_controls={d} escaped_invalid={d} children_reaped={d} workers_joined={d} artifact=false",
            .{
                @tagName(shared.cause.?),
                shared.budget.limit,
                shared.budget.admitted,
                shared.budget.remaining(),
                output.stdout.items.len + output.stderr.items.len,
                output.escaped_controls,
                output.escaped_invalid,
                child_count,
                workers.len,
            },
        );
        return failure;
    }
    try output.flushCallbacks();

    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
    debug_trace.logf(
        "core",
        "direct command completed route=direct_read_only limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} projected_bytes={d} escaped_controls={d} escaped_invalid={d} children_reaped={d} workers_joined={d} artifact=false",
        .{
            shared.budget.limit,
            shared.budget.admitted,
            shared.budget.remaining(),
            output.stdout.items.len + output.stderr.items.len,
            output.escaped_controls,
            output.escaped_invalid,
            child_count,
            workers.len,
        },
    );
    return formatDirectResult(
        alloc,
        plan,
        final_term,
        output.stdout.items,
        output.stderr.items,
        output.stdout_bytes,
        output.stderr_bytes,
        duration_ms,
    );
}

fn environmentForProfile(
    alloc: std.mem.Allocator,
    profile: command_effect.EnvironmentProfile,
) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(alloc);
    errdefer environment.deinit();
    switch (profile) {
        .basic_read_only, .git_read_only => {
            try environment.put("PATH", "/usr/bin:/bin");
            try environment.put("LC_ALL", "C");
            try environment.put("LANG", "C");
        },
    }
    if (profile == .git_read_only) {
        try environment.put("GIT_CONFIG_NOSYSTEM", "1");
        try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try environment.put("GIT_OPTIONAL_LOCKS", "0");
        try environment.put("GIT_TERMINAL_PROMPT", "0");
        try environment.put("GIT_PAGER", "cat");
        try environment.put("PAGER", "cat");
    }
    return environment;
}

const DirectTerminationCause = enum {
    cancelled,
    timed_out,
    output_limit,
    output_failure,
};

const SharedExecution = struct {
    cfg: command_runner.Config,
    budget: DirectOutputBudget,
    output: *DirectOutput,
    lock: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    cause: ?DirectTerminationCause = null,
    failure_value: ?anyerror = null,

    fn commit(
        self: *SharedExecution,
        reported: DirectTerminationCause,
        failure_value: anyerror,
    ) void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.cause != null) return;

        if (self.cfg.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) {
                self.cause = .cancelled;
                self.failure_value = error.Cancelled;
                self.stopping.store(true, .release);
                return;
            }
        }
        if (deadlineExpired(self.cfg)) {
            self.cause = .timed_out;
            self.failure_value = error.TimeoutExpired;
            self.stopping.store(true, .release);
            return;
        }

        self.cause = reported;
        self.failure_value = failure_value;
        self.stopping.store(true, .release);
    }

    fn isStopping(self: *SharedExecution) bool {
        return self.stopping.load(.acquire);
    }

    fn failure(self: *SharedExecution) ?anyerror {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.failure_value;
    }
};

const WorkerKind = union(enum) {
    relay,
    projected: command_contract.CommandOutputStream,
};

const RelayWriteResult = enum {
    forwarded,
    downstream_closed,
};

fn writeRelayChunk(destination: std.Io.File, raw: []const u8) !RelayWriteResult {
    destination.writeStreamingAll(io_mod.getIo(), raw) catch |err| switch (err) {
        error.BrokenPipe => return .downstream_closed,
        else => return err,
    };
    return .forwarded;
}

const OutputWorker = struct {
    shared: *SharedExecution,
    source: std.Io.File,
    destination: ?std.Io.File = null,
    kind: WorkerKind,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn run(self: *OutputWorker) void {
        defer self.done.store(true, .release);
        defer self.source.close(io_mod.getIo());
        defer if (self.destination) |destination| destination.close(io_mod.getIo());

        self.runFallible() catch |err| self.shared.commit(.output_failure, err);
    }

    fn runFallible(self: *OutputWorker) !void {
        var projector: DirectOutputProjector = .{};
        defer self.shared.output.addProjectionStats(projector.escaped_controls, projector.escaped_invalid);
        var projected: std.ArrayList(u8) = .empty;
        defer projected.deinit(self.shared.output.alloc);
        var buffer: [direct_output_read_chunk_bytes]u8 = undefined;

        while (!self.shared.isStopping()) {
            const count = self.source.readStreaming(io_mod.getIo(), &.{buffer[0..]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (count == 0) break;
            const raw = buffer[0..count];
            const charge = self.shared.budget.charge(raw.len);
            if (!charge.admit_chunk) {
                if (charge.trip_owner) {
                    debug_trace.logf(
                        "core",
                        "direct_output_limit_exceeded route=direct_read_only limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} stream={s}",
                        .{
                            self.shared.budget.limit,
                            self.shared.budget.admitted,
                            self.shared.budget.remaining(),
                            @tagName(self.kind),
                        },
                    );
                    self.shared.commit(.output_limit, error.DirectOutputLimitExceeded);
                }
                break;
            }

            switch (self.kind) {
                .relay => switch (try writeRelayChunk(self.destination.?, raw)) {
                    .forwarded => {},
                    .downstream_closed => {
                        const remaining = self.shared.budget.remaining();
                        debug_trace.logf(
                            "core",
                            "direct relay route=direct_read_only downstream_closed=true admitted_raw_bytes={d} remaining_raw_bytes={d}",
                            .{ self.shared.budget.limit - remaining, remaining },
                        );
                        break;
                    },
                },
                .projected => |stream| {
                    try projector.push(self.shared.output.alloc, raw, &projected);
                    try self.shared.output.append(stream, raw, projected.items);
                    projected.clearRetainingCapacity();
                },
            }
        }

        if (!self.shared.isStopping()) {
            switch (self.kind) {
                .relay => {},
                .projected => |stream| {
                    try projector.finish(self.shared.output.alloc, &projected);
                    try self.shared.output.append(stream, "", projected.items);
                },
            }
        }
    }

    fn closeUnstarted(self: *OutputWorker) void {
        self.source.close(io_mod.getIo());
        if (self.destination) |destination| destination.close(io_mod.getIo());
        self.done.store(true, .release);
    }
};

const DirectOutput = struct {
    alloc: std.mem.Allocator,
    cfg: command_runner.Config,
    lock: std.Io.Mutex = .init,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_pending: std.ArrayList(u8) = .empty,
    stderr_pending: std.ArrayList(u8) = .empty,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    escaped_controls: usize = 0,
    escaped_invalid: usize = 0,

    fn init(alloc: std.mem.Allocator, cfg: command_runner.Config) DirectOutput {
        return .{ .alloc = alloc, .cfg = cfg };
    }

    fn deinit(self: *DirectOutput) void {
        self.stdout.deinit(self.alloc);
        self.stderr.deinit(self.alloc);
        self.stdout_pending.deinit(self.alloc);
        self.stderr_pending.deinit(self.alloc);
    }

    fn append(
        self: *DirectOutput,
        stream: command_contract.CommandOutputStream,
        raw: []const u8,
        projected: []const u8,
    ) !void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        try self.emitAcceptedCallback(stream, raw);
        switch (stream) {
            .stdout => {
                self.stdout_bytes += raw.len;
                try self.stdout.appendSlice(self.alloc, projected);
                try self.emitCallback(&self.stdout_pending, stream, raw, projected, false);
            },
            .stderr => {
                self.stderr_bytes += raw.len;
                try self.stderr.appendSlice(self.alloc, projected);
                try self.emitCallback(&self.stderr_pending, stream, raw, projected, false);
            },
        }
    }

    fn flushCallbacks(self: *DirectOutput) !void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.emitCallback(&self.stdout_pending, .stdout, "", "", true);
        try self.emitCallback(&self.stderr_pending, .stderr, "", "", true);
    }

    fn addProjectionStats(
        self: *DirectOutput,
        escaped_controls: usize,
        escaped_invalid: usize,
    ) void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.escaped_controls += escaped_controls;
        self.escaped_invalid += escaped_invalid;
    }

    fn emitCallback(
        self: *DirectOutput,
        pending: *std.ArrayList(u8),
        stream: command_contract.CommandOutputStream,
        raw: []const u8,
        projected: []const u8,
        flush: bool,
    ) !void {
        const bytes = switch (self.cfg.callback_projection) {
            .model_safe => projected,
            .raw => raw,
        };
        if (bytes.len > 0) try pending.appendSlice(self.alloc, bytes);
        const ctx = self.cfg.output_chunk_ctx orelse return;
        const callback = self.cfg.on_output_chunk orelse return;

        while (std.mem.findScalar(u8, pending.items, '\n')) |newline| {
            try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, pending.items[0 .. newline + 1]);
            const remaining = pending.items.len - newline - 1;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[newline + 1 ..]);
            pending.items.len = remaining;
        }
        if (!flush and pending.items.len >= direct_output_read_chunk_bytes) {
            try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, pending.items);
            pending.clearRetainingCapacity();
        }
        if (flush and pending.items.len > 0) {
            try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, pending.items);
            pending.clearRetainingCapacity();
        }
    }

    fn emitAcceptedCallback(
        self: *DirectOutput,
        stream: command_contract.CommandOutputStream,
        raw: []const u8,
    ) !void {
        if (raw.len == 0) return;
        const ctx = self.cfg.accepted_output_chunk_ctx orelse return;
        const callback = self.cfg.on_accepted_output_chunk orelse return;
        try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, raw);
    }
};

fn allWorkersDone(workers: []const OutputWorker) bool {
    for (workers) |*worker| {
        if (!worker.done.load(.acquire)) return false;
    }
    return true;
}

fn checkControl(cfg: command_runner.Config) !void {
    if (cfg.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }
    if (deadlineExpired(cfg)) return error.TimeoutExpired;
}

fn deadlineExpired(cfg: command_runner.Config) bool {
    const timeout_ms = cfg.timeout_ms orelse return false;
    const started_ms = cfg.timeout_started_ms orelse return false;
    return io_mod.milliTimestamp() - started_ms >= @as(i64, @intCast(timeout_ms));
}

fn signalGroup(group_id: ?std.posix.pid_t, force: bool) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const pid = group_id orelse return;
    std.posix.kill(-pid, if (force) std.posix.SIG.KILL else std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf("core", "direct command signal failed err={s}", .{@errorName(err)}),
    };
}

fn closeChildPipes(child: *std.process.Child) void {
    if (child.stdin) |file| file.close(io_mod.getIo());
    if (child.stdout) |file| file.close(io_mod.getIo());
    if (child.stderr) |file| file.close(io_mod.getIo());
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

fn cleanupChildren(children: []std.process.Child, group_id: ?std.posix.pid_t) void {
    signalGroup(group_id, true);
    for (children) |*child| closeChildPipes(child);
    waitChildren(children);
}

fn waitChildren(children: []std.process.Child) void {
    for (children) |*child| {
        _ = child.wait(io_mod.getIo()) catch |err| {
            debug_trace.logf("core", "direct command cleanup wait failed err={s}", .{@errorName(err)});
        };
    }
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    if (finished_ms <= started_ms) return 0;
    return @intCast(finished_ms - started_ms);
}

fn formatDirectResult(
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
    term: std.process.Child.Term,
    stdout_projected: []const u8,
    stderr_projected: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    duration_ms: u64,
) !command_contract.RunCommandResult {
    return command_contract.formatForegroundCommandResult(alloc, .{
        .command = plan.command,
        .cwd = plan.cwd,
        .status = foregroundCommandStatusFromTerm(term),
        .stdout_display = stdout_projected,
        .stderr_display = stderr_projected,
        .stdout_bytes = stdout_bytes,
        .stderr_bytes = stderr_bytes,
        .duration_ms = duration_ms,
    });
}

fn foregroundCommandStatusFromTerm(term: std.process.Child.Term) command_contract.ForegroundCommandStatus {
    return switch (term) {
        .exited => |code| .{ .exit_code = @intCast(code) },
        .signal => |sig| .{ .signal = @intFromEnum(sig) },
        else => .finished,
    };
}

fn projectForTest(alloc: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    var projector: DirectOutputProjector = .{};
    var projected: std.ArrayList(u8) = .empty;
    errdefer projected.deinit(alloc);
    for (chunks) |chunk| try projector.push(alloc, chunk, &projected);
    try projector.finish(alloc, &projected);
    return projected.toOwnedSlice(alloc);
}

test "direct projector renders terminal controls invalid bytes and split utf8 visibly" {
    const chunks = [_][]const u8{
        "ok\n\x00\x07\x08\x09\x0d\x1b\x7f",
        "\xc2",
        "\x85",
        "\xe2\x82",
        "\xac",
        "\xff\xf0\x9f",
    };
    const projected = try projectForTest(std.testing.allocator, &chunks);
    defer std.testing.allocator.free(projected);

    try std.testing.expectEqualStrings(
        "ok\n\\x00\\x07\\x08\\x09\\x0d\\x1b\\x7f\\u{0085}\u{20ac}\\xff\\xf0\\x9f",
        projected,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(projected));
}

test "direct projector covers every c0 byte del and preserves non-control utf8" {
    var raw: [128]u8 = undefined;
    var len: usize = 0;
    for (0..32) |byte| {
        raw[len] = @intCast(byte);
        len += 1;
    }
    raw[len] = 0x7f;
    len += 1;
    const suffix = "ASCII \u{00e9} \u{1f642}\n";
    @memcpy(raw[len .. len + suffix.len], suffix);
    len += suffix.len;

    const projected = try projectForTest(std.testing.allocator, &.{raw[0..len]});
    defer std.testing.allocator.free(projected);
    try std.testing.expect(std.mem.find(u8, projected, "\\x00") != null);
    try std.testing.expect(std.mem.find(u8, projected, "\\x1f") != null);
    try std.testing.expect(std.mem.find(u8, projected, "\\x7f") != null);
    try std.testing.expect(std.mem.find(u8, projected, "ASCII \u{00e9} \u{1f642}\n") != null);
    try std.testing.expect(projected.len <= raw[0..len].len * 4);
}

test "direct output budget admits whole chunks and trips exactly once" {
    var budget: DirectOutputBudget = .{ .limit = 8 };
    try std.testing.expectEqual(
        DirectOutputBudget.Charge{ .admit_chunk = true, .trip_owner = false },
        budget.charge(4),
    );
    try std.testing.expectEqual(@as(usize, 4), budget.remaining());
    try std.testing.expectEqual(
        DirectOutputBudget.Charge{ .admit_chunk = true, .trip_owner = false },
        budget.charge(4),
    );
    try std.testing.expectEqual(@as(usize, 0), budget.remaining());
    try std.testing.expectEqual(
        DirectOutputBudget.Charge{ .admit_chunk = false, .trip_owner = true },
        budget.charge(1),
    );
    try std.testing.expectEqual(
        DirectOutputBudget.Charge{ .admit_chunk = false, .trip_owner = false },
        budget.charge(1),
    );
    try std.testing.expectEqual(@as(usize, 8), budget.admitted);
}

test "direct output budget synchronizes concurrent producers and has one trip owner" {
    var budget: DirectOutputBudget = .{ .limit = 16 };
    var trip_owners = std.atomic.Value(usize).init(0);
    const Producer = struct {
        fn run(shared_budget: *DirectOutputBudget, owners: *std.atomic.Value(usize)) void {
            const charge = shared_budget.charge(1);
            if (charge.trip_owner) _ = owners.fetchAdd(1, .seq_cst);
        }
    };
    var threads: [32]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{ &budget, &trip_owners });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 16), budget.admitted);
    try std.testing.expect(budget.tripped);
    try std.testing.expectEqual(@as(usize, 1), trip_owners.load(.seq_cst));
}

test "direct termination arbiter gives cancellation and timeout precedence" {
    var output = DirectOutput.init(std.testing.allocator, .{
        .max_command_output_bytes = 1,
    });
    defer output.deinit();

    var cancel = std.atomic.Value(bool).init(true);
    var cancelled: SharedExecution = .{
        .cfg = .{
            .max_command_output_bytes = 1,
            .cancel_flag = &cancel,
        },
        .budget = .{ .limit = 1 },
        .output = &output,
    };
    cancelled.commit(.output_limit, error.DirectOutputLimitExceeded);
    try std.testing.expectEqual(error.Cancelled, cancelled.failure().?);

    var timed_out: SharedExecution = .{
        .cfg = .{
            .max_command_output_bytes = 1,
            .timeout_ms = 1,
            .timeout_started_ms = io_mod.milliTimestamp() - 10,
        },
        .budget = .{ .limit = 1 },
        .output = &output,
    };
    timed_out.commit(.output_failure, error.BrokenPipe);
    try std.testing.expectEqual(error.TimeoutExpired, timed_out.failure().?);

    var first_failure: SharedExecution = .{
        .cfg = .{
            .max_command_output_bytes = 1,
        },
        .budget = .{ .limit = 1 },
        .output = &output,
    };
    first_failure.commit(.output_limit, error.DirectOutputLimitExceeded);
    first_failure.commit(.output_failure, error.BrokenPipe);
    try std.testing.expectEqual(error.DirectOutputLimitExceeded, first_failure.failure().?);
}

test "direct executor runs fixed argv with sanitized environment and no artifact" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const argv = [_][]const u8{"/usr/bin/env"};
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/env",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};
    const result = executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, .{
        .command = "/usr/bin/env",
        .cwd = "/tmp",
        .stages = &stages,
    }) catch |err| {
        std.debug.print("sanitized environment execution failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "PATH=/usr/bin:/bin") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "LC_ALL=C") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "LANG=C") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "HOME=") == null);
    try std.testing.expectEqual(@as(?[]const u8, null), result.command_result.?.foreground.output_file);
}

test "git direct profile removes ambient authority and disables optional mutation" {
    var environment = try environmentForProfile(std.testing.allocator, .git_read_only);
    defer environment.deinit();

    try std.testing.expectEqualStrings("/usr/bin:/bin", environment.get("PATH").?);
    try std.testing.expectEqualStrings("1", environment.get("GIT_CONFIG_NOSYSTEM").?);
    try std.testing.expectEqualStrings("/dev/null", environment.get("GIT_CONFIG_GLOBAL").?);
    try std.testing.expectEqualStrings("0", environment.get("GIT_OPTIONAL_LOCKS").?);
    try std.testing.expectEqualStrings("0", environment.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("cat", environment.get("GIT_PAGER").?);
    try std.testing.expect(environment.get("HOME") == null);
}

test "direct executor runs a supported pipeline and reports final output" {
    var admission = try command_effect.plan(
        std.testing.allocator,
        "printf x | wc -c",
        "/tmp",
        false,
        @import("builtin").os.tag,
    );
    defer admission.deinit(std.testing.allocator);
    const plan = admission.direct_read_only;

    const result = executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, plan) catch |err| {
        std.debug.print("pipeline execution failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "<stdout>\n1\n</stdout>") != null);
    const foreground = result.command_result.?.foreground;
    try std.testing.expectEqualStrings("printf x | wc -c", foreground.command);
    try std.testing.expectEqual(@as(?i64, 0), foreground.exit_code);
    const expected_stdout_bytes: usize = if (builtin.os.tag == .linux) 2 else 9;
    try std.testing.expectEqual(expected_stdout_bytes, foreground.stdout_bytes);
    try std.testing.expectEqual(@as(?[]const u8, null), foreground.output_file);
    try std.testing.expectEqual(@as(?[]const u8, null), foreground.stdout_file);
    try std.testing.expectEqual(@as(?[]const u8, null), foreground.stderr_file);
}

test "direct executor rejects plans above the pipeline stage limit" {
    const argv = [_][]const u8{ "/usr/bin/wc", "-c" };
    var stages: [command_effect.max_direct_pipeline_stages + 1]command_effect.DirectStage = undefined;
    for (&stages) |*stage| {
        stage.* = .{
            .executable = "/usr/bin/wc",
            .argv = &argv,
            .environment_profile = .basic_read_only,
        };
    }
    try std.testing.expectError(
        error.InvalidDirectPlan,
        executeDirectReadOnly(.{
            .max_command_output_bytes = 1,
        }, std.testing.allocator, injectedPlan("/tmp", &stages)),
    );
}

test "direct executor uses the canonical production output limit" {
    try std.testing.expectEqual(@as(usize, 65_536), direct_output_limit_bytes);
    try std.testing.expectEqual(@as(usize, 4096), direct_output_read_chunk_bytes);
}

fn createListingFiles(
    dir: std.Io.Dir,
    full_length_count: usize,
    include_254_byte_name: bool,
    include_one_byte_name: bool,
) !void {
    for (0..full_length_count) |index| {
        var name: [255]u8 = undefined;
        @memset(&name, 'x');
        _ = try std.fmt.bufPrint(name[0..4], "{d:0>4}", .{index});
        var file = try dir.createFile(io_mod.getIo(), &name, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    if (include_254_byte_name) {
        var name: [254]u8 = undefined;
        @memset(&name, 'y');
        var file = try dir.createFile(io_mod.getIo(), &name, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    if (include_one_byte_name) {
        var file = try dir.createFile(io_mod.getIo(), "z", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
}

test "direct executor enforces canonical capacity with native large ls output" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io_mod.getIo(), "above-32k", .default_dir);
    try tmp.dir.createDir(io_mod.getIo(), "exact-64k", .default_dir);
    try tmp.dir.createDir(io_mod.getIo(), "above-64k", .default_dir);
    var above_32k = try tmp.dir.openDir(io_mod.getIo(), "above-32k", .{});
    defer above_32k.close(io_mod.getIo());
    var exact_64k = try tmp.dir.openDir(io_mod.getIo(), "exact-64k", .{});
    defer exact_64k.close(io_mod.getIo());
    var above_64k = try tmp.dir.openDir(io_mod.getIo(), "above-64k", .{});
    defer above_64k.close(io_mod.getIo());
    try createListingFiles(above_32k, 127, true, true);
    try createListingFiles(exact_64k, 256, false, false);
    try createListingFiles(above_64k, 255, true, true);
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cwd);

    const SuccessCase = struct {
        command: []const u8,
        expected_bytes: usize,
    };
    for ([_]SuccessCase{
        .{ .command = "ls above-32k", .expected_bytes = 32_769 },
        .{ .command = "ls exact-64k", .expected_bytes = direct_output_limit_bytes },
    }) |case| {
        var admission = try command_effect.plan(
            alloc,
            case.command,
            cwd,
            false,
            builtin.os.tag,
        );
        defer admission.deinit(alloc);
        const result = try executeDirectReadOnly(.{
            .max_command_output_bytes = 1,
        }, alloc, admission.direct_read_only);
        defer alloc.free(result.output);
        try std.testing.expectEqual(
            case.expected_bytes,
            result.command_result.?.foreground.stdout_bytes,
        );
        try std.testing.expectEqualStrings(
            case.command,
            result.command_result.?.foreground.command,
        );
        try std.testing.expectEqual(
            @as(?[]const u8, null),
            result.command_result.?.foreground.output_file,
        );
    }

    var over_admission = try command_effect.plan(
        alloc,
        "ls above-64k",
        cwd,
        false,
        builtin.os.tag,
    );
    defer over_admission.deinit(alloc);
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnly(.{
            .max_command_output_bytes = std.math.maxInt(usize),
        }, alloc, over_admission.direct_read_only),
    );
}

fn injectedPlan(
    cwd: []const u8,
    stages: []const command_effect.DirectStage,
) command_effect.DirectReadOnlyPlan {
    return .{
        .command = stages[0].executable,
        .cwd = cwd,
        .stages = stages,
    };
}

test "direct executor admits exact output limit and rejects limit plus one without artifacts" {
    const exact_argv = [_][]const u8{ "/usr/bin/printf", "12345678" };
    const exact_stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/printf",
        .argv = &exact_argv,
        .environment_profile = .basic_read_only,
    }};
    const exact = try executeDirectReadOnlyWithLimit(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &exact_stages), 8);
    defer std.testing.allocator.free(exact.output);
    try std.testing.expectEqual(@as(usize, 8), exact.command_result.?.foreground.stdout_bytes);
    try std.testing.expectEqual(@as(?[]const u8, null), exact.command_result.?.foreground.output_file);

    const over_argv = [_][]const u8{ "/usr/bin/printf", "123456789" };
    const over_stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/printf",
        .argv = &over_argv,
        .environment_profile = .basic_read_only,
    }};
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnlyWithLimit(.{
            .max_command_output_bytes = 1_000_000,
        }, std.testing.allocator, injectedPlan("/tmp", &over_stages), 8),
    );
}

test "direct executor canonical limit covers stderr and counted pipeline relays" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const exact_stderr_argv = [_][]const u8{
        "/usr/bin/awk",
        "BEGIN { for (i = 0; i < 65536; i++) printf \"x\" > \"/dev/stderr\" }",
    };
    const exact_stderr_stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/awk",
        .argv = &exact_stderr_argv,
        .environment_profile = .basic_read_only,
    }};
    const exact_stderr = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &exact_stderr_stages));
    defer std.testing.allocator.free(exact_stderr.output);
    try std.testing.expectEqual(
        direct_output_limit_bytes,
        exact_stderr.command_result.?.foreground.stderr_bytes,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        exact_stderr.command_result.?.foreground.stderr_file,
    );

    const over_stderr_argv = [_][]const u8{
        "/usr/bin/awk",
        "BEGIN { for (i = 0; i < 65537; i++) printf \"x\" > \"/dev/stderr\" }",
    };
    const over_stderr_stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/awk",
        .argv = &over_stderr_argv,
        .environment_profile = .basic_read_only,
    }};
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnly(.{
            .max_command_output_bytes = std.math.maxInt(usize),
        }, std.testing.allocator, injectedPlan("/tmp", &over_stderr_stages)),
    );

    const exact_relay_bytes = direct_output_limit_bytes / 2;
    const exact_data = try std.testing.allocator.alloc(u8, exact_relay_bytes);
    defer std.testing.allocator.free(exact_data);
    @memset(exact_data, 'r');
    const exact_producer_argv = [_][]const u8{ "/usr/bin/printf", "%s", exact_data };
    const cat_argv = [_][]const u8{"/bin/cat"};
    const exact_pipeline = [_]command_effect.DirectStage{
        .{
            .executable = "/usr/bin/printf",
            .argv = &exact_producer_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/bin/cat",
            .argv = &cat_argv,
            .environment_profile = .basic_read_only,
        },
    };
    const exact_relay = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &exact_pipeline));
    defer std.testing.allocator.free(exact_relay.output);
    try std.testing.expectEqual(
        exact_relay_bytes,
        exact_relay.command_result.?.foreground.stdout_bytes,
    );

    const over_data = try std.testing.allocator.alloc(u8, exact_relay_bytes + 1);
    defer std.testing.allocator.free(over_data);
    @memset(over_data, 'r');
    const over_producer_argv = [_][]const u8{ "/usr/bin/printf", "%s", over_data };
    const over_pipeline = [_]command_effect.DirectStage{
        .{
            .executable = "/usr/bin/printf",
            .argv = &over_producer_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/bin/cat",
            .argv = &cat_argv,
            .environment_profile = .basic_read_only,
        },
    };
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnly(.{
            .max_command_output_bytes = std.math.maxInt(usize),
        }, std.testing.allocator, injectedPlan("/tmp", &over_pipeline)),
    );
}

test "direct executor charges non-final pipeline bytes before relay" {
    const producer_argv = [_][]const u8{ "/usr/bin/printf", "123456789" };
    const consumer_argv = [_][]const u8{ "/usr/bin/wc", "-c" };
    const stages = [_]command_effect.DirectStage{
        .{
            .executable = "/usr/bin/printf",
            .argv = &producer_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/usr/bin/wc",
            .argv = &consumer_argv,
            .environment_profile = .basic_read_only,
        },
    };
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnlyWithLimit(.{
            .max_command_output_bytes = 1_000_000,
        }, std.testing.allocator, injectedPlan("/tmp", &stages), 8),
    );
}

test "direct executor enforces one budget across concurrent stdout and stderr" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const exact_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "(printf 12345678) & (printf abcdefgh >&2) & wait",
    };
    const exact_stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &exact_argv,
        .environment_profile = .basic_read_only,
    }};
    const exact = try executeDirectReadOnlyWithLimit(.{
        .max_command_output_bytes = 1_000_000,
    }, std.testing.allocator, injectedPlan("/tmp", &exact_stages), 16);
    defer std.testing.allocator.free(exact.output);
    try std.testing.expectEqual(@as(usize, 8), exact.command_result.?.foreground.stdout_bytes);
    try std.testing.expectEqual(@as(usize, 8), exact.command_result.?.foreground.stderr_bytes);

    const over_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "(printf 123456789) & (printf abcdefgh >&2) & wait",
    };
    const over_stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &over_argv,
        .environment_profile = .basic_read_only,
    }};
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnlyWithLimit(.{
            .max_command_output_bytes = 1_000_000,
        }, std.testing.allocator, injectedPlan("/tmp", &over_stages), 16),
    );
}

test "direct executor reaps partial spawn and output-limit process groups" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const PidCapture = struct {
        pid: ?std.posix.pid_t = null,

        fn afterSpawn(raw: *anyopaque, stage_index: usize, child: *const std.process.Child) void {
            if (stage_index != 0) return;
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.pid = child.id;
        }

        fn expectReaped(self: *const @This()) !void {
            const pid = self.pid.?;
            defer {
                std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
                _ = std.c.waitpid(pid, null, 0);
            }
            try std.testing.expectError(
                error.ProcessNotFound,
                std.posix.kill(pid, @enumFromInt(0)),
            );
        }
    };

    const sleep_argv = [_][]const u8{ "/bin/sleep", "10" };
    const missing_argv = [_][]const u8{"/definitely/missing/fx-direct-second-stage"};
    const partial_stages = [_]command_effect.DirectStage{
        .{
            .executable = "/bin/sleep",
            .argv = &sleep_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/definitely/missing/fx-direct-second-stage",
            .argv = &missing_argv,
            .environment_profile = .basic_read_only,
        },
    };
    var partial_capture = PidCapture{};
    try std.testing.expectError(
        error.DirectExecutableUnavailable,
        executeDirectReadOnlyWithLimitAndTestControls(
            .{
                .max_command_output_bytes = 1,
            },
            std.testing.allocator,
            injectedPlan("/tmp", &partial_stages),
            direct_output_limit_bytes,
            .{ .context = &partial_capture, .after_spawn = PidCapture.afterSpawn },
        ),
    );
    try partial_capture.expectReaped();

    const limit_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf 123456789; sleep 10",
    };
    const limit_stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &limit_argv,
        .environment_profile = .basic_read_only,
    }};
    var limit_capture = PidCapture{};
    try std.testing.expectError(
        error.DirectOutputLimitExceeded,
        executeDirectReadOnlyWithLimitAndTestControls(
            .{
                .max_command_output_bytes = 1_000_000,
            },
            std.testing.allocator,
            injectedPlan("/tmp", &limit_stages),
            8,
            .{ .context = &limit_capture, .after_spawn = PidCapture.afterSpawn },
        ),
    );
    try limit_capture.expectReaped();
}

test "direct executor cleans up cancellation after the first pipeline spawn" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    var cancel = std.atomic.Value(bool).init(false);
    const CancelAfterSpawn = struct {
        cancel: *std.atomic.Value(bool),
        pid: ?std.posix.pid_t = null,

        fn run(raw: *anyopaque, stage_index: usize, child: *const std.process.Child) void {
            if (stage_index != 0) return;
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.pid = child.id;
            self.cancel.store(true, .seq_cst);
        }
    };
    var test_control = CancelAfterSpawn{ .cancel = &cancel };

    const sleep_argv = [_][]const u8{ "/bin/sleep", "10" };
    const wc_argv = [_][]const u8{ "/usr/bin/wc", "-c" };
    const stages = [_]command_effect.DirectStage{
        .{
            .executable = "/bin/sleep",
            .argv = &sleep_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/usr/bin/wc",
            .argv = &wc_argv,
            .environment_profile = .basic_read_only,
        },
    };
    try std.testing.expectError(
        error.Cancelled,
        executeDirectReadOnlyWithLimitAndTestControls(
            .{
                .max_command_output_bytes = 1,
                .cancel_flag = &cancel,
            },
            std.testing.allocator,
            injectedPlan("/tmp", &stages),
            direct_output_limit_bytes,
            .{ .context = &test_control, .after_spawn = CancelAfterSpawn.run },
        ),
    );

    const pid = test_control.pid.?;
    defer {
        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        _ = std.c.waitpid(pid, null, 0);
    }
    try std.testing.expectError(
        error.ProcessNotFound,
        std.posix.kill(pid, @enumFromInt(0)),
    );
}

test "direct executor projects hostile final stdout and stderr" {
    const hostile_stdout = "\x1b]52;c;secret\x07\xff";
    const stdout_argv = [_][]const u8{ "/usr/bin/printf", "%s", hostile_stdout };
    const stdout_stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/printf",
        .argv = &stdout_argv,
        .environment_profile = .basic_read_only,
    }};
    const stdout_result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &stdout_stages));
    defer std.testing.allocator.free(stdout_result.output);
    try std.testing.expect(std.mem.find(u8, stdout_result.output, "\\x1b]52;c;secret\\x07\\xff") != null);
    try std.testing.expect(std.mem.findScalar(u8, stdout_result.output, 0x1b) == null);

    const stderr_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf '\\033[31m-missing' >&2; exit 2",
    };
    const stderr_stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &stderr_argv,
        .environment_profile = .basic_read_only,
    }};
    const stderr_result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &stderr_stages));
    defer std.testing.allocator.free(stderr_result.output);
    try std.testing.expect(std.mem.findScalar(u8, stderr_result.output, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, stderr_result.output, "\\x1b[31m-missing") != null);
    try std.testing.expect(stderr_result.command_result.?.foreground.stderr_bytes > 0);
}

const CallbackCapture = struct {
    stdout: [512]u8 = undefined,
    stdout_len: usize = 0,
    stderr: [512]u8 = undefined,
    stderr_len: usize = 0,
    streams: [16]command_contract.CommandOutputStream = undefined,
    stream_len: usize = 0,

    fn onChunk(
        raw_ctx: *anyopaque,
        _: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *CallbackCapture = @ptrCast(@alignCast(raw_ctx));
        std.debug.assert(self.stream_len < self.streams.len);
        self.streams[self.stream_len] = stream;
        self.stream_len += 1;
        switch (stream) {
            .stdout => {
                std.debug.assert(self.stdout_len + chunk.len <= self.stdout.len);
                @memcpy(self.stdout[self.stdout_len .. self.stdout_len + chunk.len], chunk);
                self.stdout_len += chunk.len;
            },
            .stderr => {
                std.debug.assert(self.stderr_len + chunk.len <= self.stderr.len);
                @memcpy(self.stderr[self.stderr_len .. self.stderr_len + chunk.len], chunk);
                self.stderr_len += chunk.len;
            },
        }
    }
};

test "direct executor callbacks receive only bounded projected output" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf '\\033]52;c;stdout\\007'; printf '\\033[31mstderr\\377' >&2",
    };
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};
    var capture = CallbackCapture{};
    const result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
        .output_chunk_ctx = &capture,
        .on_output_chunk = CallbackCapture.onChunk,
    }, std.testing.allocator, injectedPlan("/tmp", &stages));
    defer std.testing.allocator.free(result.output);

    const stdout = capture.stdout[0..capture.stdout_len];
    const stderr = capture.stderr[0..capture.stderr_len];
    try std.testing.expect(std.mem.findScalar(u8, stdout, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, stderr, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, stdout, "\\x1b]52;c;stdout\\x07") != null);
    try std.testing.expect(std.mem.find(u8, stderr, "\\x1b[31mstderr\\xff") != null);
    const foreground = result.command_result.?.foreground;
    try std.testing.expect(
        stdout.len + stderr.len <=
            4 * (foreground.stdout_bytes + foreground.stderr_bytes),
    );
}

test "direct executor raw callback projection keeps projected result isolated" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf '\\033[31mraw\\000\\377'",
    };
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};
    var capture = CallbackCapture{};
    const result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
        .output_chunk_ctx = &capture,
        .on_output_chunk = CallbackCapture.onChunk,
        .callback_projection = .raw,
    }, std.testing.allocator, injectedPlan("/tmp", &stages));
    defer std.testing.allocator.free(result.output);

    const stdout = capture.stdout[0..capture.stdout_len];
    try std.testing.expect(std.mem.findScalar(u8, stdout, 0x1b) != null);
    try std.testing.expect(std.mem.findScalar(u8, stdout, 0x00) != null);
    try std.testing.expect(std.mem.findScalar(u8, stdout, 0xff) != null);
    try std.testing.expect(std.mem.findScalar(u8, result.output, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, result.output, "\\x1b[31mraw\\x00\\xff") != null);
}

test "direct executor accepted callbacks preserve repeated newline-free stream order" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf E1 >&2; sleep 0.15; printf O1; sleep 0.15; printf E2 >&2; sleep 0.15; printf O2",
    };
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};
    var capture = CallbackCapture{};
    const result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 4096,
        .accepted_output_chunk_ctx = &capture,
        .on_accepted_output_chunk = CallbackCapture.onChunk,
    }, std.testing.allocator, injectedPlan("/tmp", &stages));
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqual(@as(usize, 4), capture.stream_len);
    try std.testing.expectEqual(.stderr, capture.streams[0]);
    try std.testing.expectEqual(.stdout, capture.streams[1]);
    try std.testing.expectEqual(.stderr, capture.streams[2]);
    try std.testing.expectEqual(.stdout, capture.streams[3]);
    try std.testing.expectEqualStrings("E1E2", capture.stderr[0..capture.stderr_len]);
    try std.testing.expectEqualStrings("O1O2", capture.stdout[0..capture.stdout_len]);
}

test "direct executor keeps stderr projector state independent per child" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const producer_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf '\\302' >&2; printf x",
    };
    const consumer_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "cat >/dev/null; printf '\\205' >&2",
    };
    const stages = [_]command_effect.DirectStage{
        .{
            .executable = "/bin/sh",
            .argv = &producer_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/bin/sh",
            .argv = &consumer_argv,
            .environment_profile = .basic_read_only,
        },
    };
    const result = executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &stages)) catch |err| {
        std.debug.print("downstream pipe closure failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "\\xc2") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "\\x85") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "\\u{0085}") == null);
}

test "direct executor reports final stage status without pipefail" {
    const argv = [_][]const u8{"/usr/bin/false"};
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/usr/bin/false",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};
    const result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &stages));
    defer std.testing.allocator.free(result.output);
    try std.testing.expectEqual(@as(?i64, 1), result.command_result.?.foreground.exit_code);
}

test "direct relay treats a closed downstream pipe as normal completion" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const argv = [_][]const u8{"/usr/bin/false"};
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const destination = child.stdin.?;
    child.stdin = null;
    defer destination.close(io_mod.getIo());
    _ = try child.wait(io_mod.getIo());

    try std.testing.expectEqual(
        RelayWriteResult.downstream_closed,
        try writeRelayChunk(destination, "not consumed"),
    );
}

test "direct executor treats downstream pipe closure as normal pipeline completion" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const producer_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "sleep 0.1; printf upstream",
    };
    const consumer_argv = [_][]const u8{ "/bin/pwd", "-P" };
    const stages = [_]command_effect.DirectStage{
        .{
            .executable = "/bin/sh",
            .argv = &producer_argv,
            .environment_profile = .basic_read_only,
        },
        .{
            .executable = "/bin/pwd",
            .argv = &consumer_argv,
            .environment_profile = .basic_read_only,
        },
    };
    const result = try executeDirectReadOnly(.{
        .max_command_output_bytes = 1,
    }, std.testing.allocator, injectedPlan("/tmp", &stages));
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqual(@as(?i64, 0), result.command_result.?.foreground.exit_code);
    const physical_tmp = try io_mod.realpathAlloc(std.testing.allocator, "/tmp");
    defer std.testing.allocator.free(physical_tmp);
    const expected_output = try std.fmt.allocPrint(
        std.testing.allocator,
        "<stdout>\n{s}\n</stdout>",
        .{physical_tmp},
    );
    defer std.testing.allocator.free(expected_output);
    try std.testing.expect(std.mem.find(u8, result.output, expected_output) != null);
}

test "direct executor fails closed for missing executable" {
    const missing_argv = [_][]const u8{"/definitely/missing/fx-direct-command"};
    const missing_stages = [_]command_effect.DirectStage{.{
        .executable = "/definitely/missing/fx-direct-command",
        .argv = &missing_argv,
        .environment_profile = .basic_read_only,
    }};
    try std.testing.expectError(
        error.DirectExecutableUnavailable,
        executeDirectReadOnly(.{
            .max_command_output_bytes = 1,
        }, std.testing.allocator, injectedPlan("/tmp", &missing_stages)),
    );
}

test "direct executor cancellation and timeout terminate and reap the process group" {
    const argv = [_][]const u8{ "/bin/sleep", "10" };
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sleep",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};

    var cancel = std.atomic.Value(bool).init(false);
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const thread = try std.Thread.spawn(.{}, Flip.run, .{&cancel});
    defer thread.join();
    try std.testing.expectError(
        error.Cancelled,
        executeDirectReadOnly(.{
            .max_command_output_bytes = 1,
            .cancel_flag = &cancel,
        }, std.testing.allocator, injectedPlan("/tmp", &stages)),
    );

    try std.testing.expectError(
        error.TimeoutExpired,
        executeDirectReadOnly(.{
            .max_command_output_bytes = 1,
            .timeout_ms = 1,
            .timeout_started_ms = io_mod.milliTimestamp() - 10,
        }, std.testing.allocator, injectedPlan("/tmp", &stages)),
    );
}

test "direct executor flushes partial callback output before timeout" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap 'exit 0' TERM; printf PARTIAL; sleep 10",
    };
    const stages = [_]command_effect.DirectStage{.{
        .executable = "/bin/sh",
        .argv = &argv,
        .environment_profile = .basic_read_only,
    }};
    var capture = CallbackCapture{};

    try std.testing.expectError(
        error.TimeoutExpired,
        executeDirectReadOnly(.{
            .max_command_output_bytes = 1,
            .timeout_ms = 500,
            .timeout_started_ms = io_mod.milliTimestamp(),
            .output_chunk_ctx = &capture,
            .on_output_chunk = CallbackCapture.onChunk,
        }, std.testing.allocator, injectedPlan("/tmp", &stages)),
    );
    try std.testing.expectEqualStrings("PARTIAL", capture.stdout[0..capture.stdout_len]);
}

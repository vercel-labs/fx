const std = @import("std");
const host_target = @import("../hosts/target.zig");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const docker_run = @import("docker_run.zig");
const operation_control = @import("operation_control.zig");

const Allocator = std.mem.Allocator;
const request_poll_ns: u64 = 5 * std.time.ns_per_ms;
const shutdown_grace_ms: i64 = 1_000;
const termination_grace_ms: i64 = 1_000;
const cancellation_write_timeout_ms: u32 = 100;
const server_request_write_timeout_ms: u32 = 1_000;

pub const Progress = mcp_contract.Progress;
pub const ProgressSink = mcp_contract.ProgressSink;
pub const NotificationSink = mcp_contract.NotificationSink;
pub const ResponseObserver = mcp_contract.ResponseObserver;
pub const ServerRequestSink = mcp_contract.ServerRequestSink;

pub const ServerRequestWait = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque) void,
};

pub const RequestOptions = struct {
    timeout_ms: u32,
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,
    commit_deadline: ?std.Io.Clock.Timestamp = null,
    commit_cancel_flag: ?*std.atomic.Value(bool) = null,
    progress: ?ProgressSink = null,
    response_observer: ?ResponseObserver = null,
    server_requests: ?ServerRequestSink = null,
    server_request_wait: ?ServerRequestWait = null,
    deadline_gate: ?*operation_control.DeadlineGate = null,
    send_cancellation: bool = true,
    request_started: ?*bool = null,
    purpose: RequestPurpose = .ordinary,
    precommit: ?*mcp_contract.TransportPrecommit = null,
    readiness: ?*RequestReadiness = null,
};

pub const RequestPurpose = enum {
    ordinary,
    subscription,
};

pub const RequestReadiness = struct {
    pub const State = enum(u8) {
        spawned,
        registered,
        committed,
        failed,
        stopped,
    };

    state: std.atomic.Value(State) = .init(.spawned),
    state_mutex: std.Io.Mutex = .init,
    failure: ?anyerror = null,
    registered_event: std.Io.Event = .unset,
    terminal_event: std.Io.Event = .unset,

    pub fn current(self: *const RequestReadiness) State {
        return self.state.load(.acquire);
    }

    pub fn markRegistered(self: *RequestReadiness) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        if (self.state.load(.monotonic) == .spawned) {
            self.state.store(.registered, .release);
        }
        self.state_mutex.unlock(io_mod.getIo());
        self.registered_event.set(io_mod.getIo());
    }

    pub fn markCommitted(self: *RequestReadiness) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const state = self.state.load(.monotonic);
        if (state == .spawned or state == .registered) {
            self.state.store(.committed, .release);
        }
        self.state_mutex.unlock(io_mod.getIo());
        self.registered_event.set(io_mod.getIo());
        self.terminal_event.set(io_mod.getIo());
    }

    pub fn markFailed(self: *RequestReadiness, err: anyerror) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const state = self.state.load(.monotonic);
        if (state == .spawned or state == .registered) {
            self.failure = err;
            self.state.store(.failed, .release);
        }
        self.state_mutex.unlock(io_mod.getIo());
        self.registered_event.set(io_mod.getIo());
        self.terminal_event.set(io_mod.getIo());
    }

    pub fn markStopped(self: *RequestReadiness) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const state = self.state.load(.monotonic);
        if (state == .spawned or state == .registered) {
            self.state.store(.stopped, .release);
        }
        self.state_mutex.unlock(io_mod.getIo());
        self.registered_event.set(io_mod.getIo());
        self.terminal_event.set(io_mod.getIo());
    }

    pub fn waitRegistered(
        self: *RequestReadiness,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        try waitForReadinessEvent(&self.registered_event, deadline, cancel_flag);
        return self.result(true);
    }

    pub fn waitCommitted(
        self: *RequestReadiness,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        try waitForReadinessEvent(&self.terminal_event, deadline, cancel_flag);
        return self.result(false);
    }

    fn result(self: *RequestReadiness, registered_is_ready: bool) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return switch (self.state.load(.acquire)) {
            .registered => if (registered_is_ready) {} else error.McpSubscriptionNotCommitted,
            .committed => {},
            .failed => self.failure orelse error.McpConnectionClosed,
            .stopped => error.McpConnectionClosed,
            .spawned => error.McpSubscriptionNotRegistered,
        };
    }
};

const ConnectionState = enum {
    running,
    stopping,
    failed,
    stopped,
};

const Pending = struct {
    max_frame_bytes: usize,
    progress: ?ProgressSink,
    purpose: RequestPurpose,
    active_progress_callbacks: usize = 0,
    active_response_callbacks: usize = 0,
    active_server_request_callbacks: usize = 0,
    response_observer: ?ResponseObserver = null,
    server_requests: ?ServerRequestSink = null,
    server_request_wait_required: bool = false,
    server_request_wait_released: bool = false,
    server_request_owner_retired: bool = false,
    write_committed: bool = false,
    response: ?[]u8 = null,
    failure: ?anyerror = null,
    changed: ChangeSignal = .{},
};

const ChangeSignal = struct {
    event: std.Io.Event = .unset,

    /// The request owner calls this while holding `state_mutex`, before it
    /// inspects pending state. Producers notify under the same mutex, so a
    /// change cannot be lost between inspection and waiting.
    fn prepareLocked(self: *ChangeSignal) void {
        self.event.reset();
    }

    fn notifyLocked(self: *ChangeSignal) void {
        self.event.set(io_mod.getIo());
    }

    fn wait(self: *ChangeSignal, deadline: std.Io.Clock.Timestamp) !void {
        self.event.waitTimeout(
            io_mod.getIo(),
            .{ .deadline = deadline },
        ) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Cancelled,
        };
    }
};

const WritePhase = enum(u8) {
    waiting,
    writing,
    committed,
};

const WriteOutcome = struct {
    phase: WritePhase,
    result: anyerror!void,
};

const WriteControl = enum {
    none,
    cancelled,
    timed_out,
};

const ProgressEvent = struct {
    token: ProgressToken,
    value: Progress,
};

const Inbound = union(enum) {
    response: ResponseId,
    notification: []const u8,
    cancelled: u64,
    progress: ProgressEvent,
    request: struct {
        id: std.json.Value,
        method: []const u8,
    },
};

const ResponseId = union(enum) {
    integer: u64,
    string: []const u8,
};

const ProgressToken = union(enum) {
    integer: u64,
    string: []const u8,
};

pub const StdioDispatcher = struct {
    owner_allocator: Allocator,
    shared_allocator: Allocator,
    child: std.process.Child,
    child_id: std.process.Child.Id,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    reader_thread: ?std.Thread = null,
    state_mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    state: ConnectionState = .running,
    reader_done: bool = false,
    pending: std.AutoHashMap(u64, *Pending),
    next_request_id: u64 = 0,
    generation: u64,
    max_frame_bytes: std.atomic.Value(usize),
    docker_cleanup: ?docker_run.Cleanup = null,
    notification_sink: ?NotificationSink = null,
    notification_callback_active: bool = false,
    active_server_request_workers: usize = 0,
    active_users: usize = 0,

    pub fn create(
        owner_allocator: Allocator,
        shared_allocator: Allocator,
        child_value: std.process.Child,
        generation: u64,
        initial_max_frame_bytes: usize,
    ) !*StdioDispatcher {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        var child = child_value;
        const child_id = child.id orelse return error.McpProcessNotStarted;
        const stdin = child.stdin orelse {
            terminateChild(child_id);
            _ = child.wait(io_mod.getIo()) catch {};
            return error.McpStdinClosed;
        };
        const stdout = child.stdout orelse {
            stdin.close(io_mod.getIo());
            child.stdin = null;
            terminateChild(child_id);
            _ = child.wait(io_mod.getIo()) catch {};
            return error.McpStdoutClosed;
        };
        child.stdin = null;
        child.stdout = null;

        const self = owner_allocator.create(StdioDispatcher) catch |err| {
            stdin.close(io_mod.getIo());
            stdout.close(io_mod.getIo());
            terminateChild(child_id);
            _ = child.wait(io_mod.getIo()) catch {};
            return err;
        };
        self.* = .{
            .owner_allocator = owner_allocator,
            .shared_allocator = shared_allocator,
            .child = child,
            .child_id = child_id,
            .stdin = stdin,
            .stdout = stdout,
            .pending = std.AutoHashMap(u64, *Pending).init(shared_allocator),
            .generation = generation,
            .max_frame_bytes = .init(initial_max_frame_bytes),
        };
        errdefer {
            self.closePipes();
            terminateChild(self.child_id);
            _ = self.child.wait(io_mod.getIo()) catch {};
            self.pending.deinit();
            owner_allocator.destroy(self);
        }

        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        debug_trace.logf(
            "mcp",
            "stdio dispatcher started generation={d} child={any}",
            .{ generation, child_id },
        );
        return self;
    }

    pub fn deinit(self: *StdioDispatcher) void {
        self.shutdown();
        self.destroy();
    }

    pub fn deinitForced(self: *StdioDispatcher) void {
        self.shutdownForced();
        self.destroy();
    }

    pub fn installDockerCleanup(
        self: *StdioDispatcher,
        cleanup: docker_run.Cleanup,
    ) void {
        std.debug.assert(self.docker_cleanup == null);
        self.docker_cleanup = cleanup;
    }

    fn destroy(self: *StdioDispatcher) void {
        std.debug.assert(self.docker_cleanup == null);
        self.pending.deinit();
        const owner_allocator = self.owner_allocator;
        owner_allocator.destroy(self);
    }

    pub fn connectionGeneration(self: *const StdioDispatcher) u64 {
        return self.generation;
    }

    pub fn isRunning(self: *StdioDispatcher) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.state == .running;
    }

    /// The caller must retain while the dispatcher is still protected by its
    /// server publication lock. Shutdown drains this lease before destruction.
    pub fn retainPublished(self: *StdioDispatcher) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        self.active_users += 1;
    }

    pub fn releaseUse(self: *StdioDispatcher) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_users > 0);
        self.active_users -= 1;
    }

    pub fn pendingRequestCount(self: *StdioDispatcher) usize {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.pending.count();
    }

    pub fn hasNotificationSink(self: *StdioDispatcher) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.notification_sink != null;
    }

    pub fn reserveRequestId(self: *StdioDispatcher) !u64 {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.state != .running) return error.McpConnectionClosed;
        const request_id = self.next_request_id;
        self.next_request_id = std.math.add(u64, request_id, 1) catch
            return error.McpRequestIdExhausted;
        return request_id;
    }

    pub fn setNotificationSink(
        self: *StdioDispatcher,
        sink: NotificationSink,
    ) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.state != .running) return error.McpConnectionClosed;
        if (self.notification_sink != null) return error.McpNotificationSinkExists;
        self.notification_sink = sink;
    }

    pub fn clearNotificationSink(self: *StdioDispatcher) void {
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            self.notification_sink = null;
            const drained = !self.notification_callback_active;
            self.state_mutex.unlock(io_mod.getIo());
            if (drained) return;
            io_mod.sleep(request_poll_ns);
        }
    }

    pub fn request(
        self: *StdioDispatcher,
        alloc: Allocator,
        request_id: u64,
        body: []const u8,
        max_frame_bytes: usize,
        options: RequestOptions,
    ) ![]u8 {
        return self.requestInner(
            alloc,
            request_id,
            body,
            max_frame_bytes,
            options,
        ) catch |err| {
            if (options.readiness) |readiness| readiness.markFailed(err);
            return err;
        };
    }

    fn requestInner(
        self: *StdioDispatcher,
        alloc: Allocator,
        request_id: u64,
        body: []const u8,
        max_frame_bytes: usize,
        options: RequestOptions,
    ) ![]u8 {
        if (options.request_started) |started| started.* = false;
        if (cancelRequested(options.cancel_flag) or
            cancelRequested(options.lifecycle_cancel_flag) or
            cancelRequested(options.commit_cancel_flag)) return error.Cancelled;
        const io = io_mod.getIo();
        const deadline = requestDeadline(io, options.timeout_ms, options.deadline);
        const commit_deadline = earlierDeadline(options.commit_deadline, deadline);

        var pending = Pending{
            .max_frame_bytes = max_frame_bytes,
            .progress = options.progress,
            .response_observer = options.response_observer,
            .server_requests = options.server_requests,
            .server_request_wait_required = options.server_request_wait != null,
            .purpose = options.purpose,
        };
        try self.registerPending(request_id, &pending, max_frame_bytes);
        if (options.readiness) |readiness| readiness.markRegistered();
        var registered = true;
        defer if (registered) self.retirePending(request_id, &pending);

        if (options.request_started) |started| started.* = true;
        const write_outcome = try self.writeBodyBounded(
            body,
            commit_deadline,
            options.cancel_flag,
            options.lifecycle_cancel_flag,
            options.commit_cancel_flag,
            options.precommit,
        );
        if (options.request_started) |started| {
            started.* = write_outcome.phase != .waiting;
        }
        var write_control: WriteControl = .none;
        if (write_outcome.phase == .committed) {
            if (options.readiness) |readiness| readiness.markCommitted();
        }
        write_outcome.result catch |err| switch (err) {
            error.Cancelled => write_control = .cancelled,
            error.McpRequestTimedOut => write_control = .timed_out,
            else => {
                if (write_outcome.phase == .waiting) return err;
                self.failConnection(err);
                terminateChild(self.child_id);
            },
        };
        if (write_outcome.phase == .committed) {
            self.state_mutex.lockUncancelable(io);
            if (self.pending.get(request_id) == &pending) {
                pending.write_committed = true;
            }
            self.state_mutex.unlock(io);
        }
        var connection_tainted = false;
        var server_request_wait_started = false;

        while (true) {
            var response: ?[]u8 = null;
            var failure: ?anyerror = null;
            var send_cancel = false;
            var taint_connection = false;
            var begin_server_request_wait = false;

            self.state_mutex.lockUncancelable(io);
            pending.changed.prepareLocked();
            begin_server_request_wait = !server_request_wait_started and
                pending.active_server_request_callbacks > 0 and
                options.server_request_wait != null;
            if (pending.response) |frame| {
                if (pending.active_response_callbacks == 0 and
                    pending.active_server_request_callbacks == 0)
                {
                    response = frame;
                    pending.response = null;
                    registered = false;
                }
            } else if (pending.failure) |err| {
                if (pending.active_progress_callbacks == 0 and
                    pending.active_response_callbacks == 0 and
                    pending.active_server_request_callbacks == 0)
                {
                    failure = err;
                    registered = false;
                }
            } else {
                const requested_cancel = write_control == .cancelled or
                    cancelRequested(options.cancel_flag) or
                    cancelRequested(options.lifecycle_cancel_flag);
                const timed_out = write_control == .timed_out or
                    requestDeadlineExpired(io, deadline, options.deadline_gate);
                if (requested_cancel or timed_out) {
                    if (self.pending.get(request_id) == &pending) {
                        _ = self.pending.remove(request_id);
                        registered = false;
                        send_cancel = pending.write_committed and options.send_cancellation;
                        if (requested_cancel) {
                            debug_trace.logf(
                                "mcp",
                                "cancelling stdio request generation={d} request_id={d} committed={any} caller={any} lifecycle={any}",
                                .{
                                    self.generation,
                                    request_id,
                                    pending.write_committed,
                                    cancelRequested(options.cancel_flag),
                                    cancelRequested(options.lifecycle_cancel_flag),
                                },
                            );
                        }
                        pending.failure = if (requested_cancel)
                            error.Cancelled
                        else
                            error.McpRequestTimedOut;
                        if (pending.active_progress_callbacks == 0 and
                            pending.active_response_callbacks == 0 and
                            pending.active_server_request_callbacks == 0)
                        {
                            failure = pending.failure;
                        }
                        taint_connection = write_outcome.phase == .writing;
                    }
                }
            }
            self.state_mutex.unlock(io);

            if (begin_server_request_wait) {
                server_request_wait_started = true;
                const wait = options.server_request_wait.?;
                wait.callback(wait.context);
                self.state_mutex.lockUncancelable(io);
                pending.server_request_wait_released = true;
                self.state_mutex.unlock(io);
            }

            if (response) |frame| {
                defer self.shared_allocator.free(frame);
                return try alloc.dupe(u8, frame);
            }
            if (taint_connection and !connection_tainted) {
                connection_tainted = true;
                self.failConnection(error.McpWriteInterrupted);
                terminateChild(self.child_id);
            }
            if (send_cancel) {
                self.sendCancellation(request_id, @errorName(pending.failure.?));
            }
            if (failure) |err| return err;
            const change_deadline = pendingChangeDeadline(io, deadline, options);
            try pending.changed.wait(change_deadline);
        }
    }

    pub fn sendNotification(
        self: *StdioDispatcher,
        body: []const u8,
        timeout_ms: u32,
    ) !void {
        return self.sendNotificationWithControl(body, timeout_ms, null, null);
    }

    pub fn sendNotificationWithControl(
        self: *StdioDispatcher,
        body: []const u8,
        timeout_ms: u32,
        operation_deadline: ?std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        return self.sendNotificationWithLifecycleControl(
            body,
            timeout_ms,
            operation_deadline,
            cancel_flag,
            null,
        );
    }

    pub fn sendNotificationWithLifecycleControl(
        self: *StdioDispatcher,
        body: []const u8,
        timeout_ms: u32,
        operation_deadline: ?std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
    ) !void {
        const io = io_mod.getIo();
        const deadline = requestDeadline(io, timeout_ms, operation_deadline);
        const outcome = try self.writeBodyBounded(
            body,
            deadline,
            cancel_flag,
            lifecycle_cancel_flag,
            null,
            null,
        );
        return outcome.result catch |err| {
            if (outcome.phase == .writing or
                (err != error.McpRequestTimedOut and err != error.Cancelled))
            {
                self.failConnection(err);
                terminateChild(self.child_id);
            }
            return err;
        };
    }

    fn writeBodyBounded(
        self: *StdioDispatcher,
        body: []const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
        commit_cancel_flag: ?*std.atomic.Value(bool),
        precommit: ?*mcp_contract.TransportPrecommit,
    ) !WriteOutcome {
        const Event = union(enum) {
            write: anyerror!void,
            deadline: anyerror!void,
            cancelled: anyerror!void,
            lifecycle_cancelled: anyerror!void,
            commit_cancelled: anyerror!void,
        };
        var operation = WriteOperation{
            .dispatcher = self,
            .body = body,
            .precommit = precommit,
        };
        var select_buffer: [5]Event = undefined;
        var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
        select.concurrent(.deadline, waitForWriteDeadline, .{deadline}) catch |err| {
            return err;
        };
        if (cancel_flag) |flag| {
            select.concurrent(.cancelled, waitForWriteCancellation, .{flag}) catch |err| {
                select.cancelDiscard();
                return err;
            };
        }
        if (lifecycle_cancel_flag) |flag| {
            if (cancel_flag == null or cancel_flag.? != flag) {
                select.concurrent(.lifecycle_cancelled, waitForWriteCancellation, .{flag}) catch |err| {
                    select.cancelDiscard();
                    return err;
                };
            }
        }
        if (commit_cancel_flag) |flag| {
            if ((cancel_flag == null or cancel_flag.? != flag) and
                (lifecycle_cancel_flag == null or lifecycle_cancel_flag.? != flag))
            {
                select.concurrent(.commit_cancelled, waitForWriteCancellation, .{flag}) catch |err| {
                    select.cancelDiscard();
                    return err;
                };
            }
        }
        select.concurrent(.write, WriteOperation.run, .{&operation}) catch |err| {
            select.cancelDiscard();
            return err;
        };

        const event = select.await() catch |err| {
            select.cancelDiscard();
            return err;
        };
        switch (event) {
            .write => |write_result| {
                select.cancelDiscard();
                const phase = operation.phase.load(.acquire);
                if (cancelRequested(cancel_flag) or
                    cancelRequested(lifecycle_cancel_flag) or
                    cancelRequested(commit_cancel_flag))
                {
                    return .{ .phase = phase, .result = error.Cancelled };
                }
                if (deadlineExpired(io_mod.getIo(), deadline)) {
                    return .{ .phase = phase, .result = error.McpRequestTimedOut };
                }
                return .{ .phase = phase, .result = write_result };
            },
            .deadline => |deadline_result| {
                deadline_result catch |err| {
                    select.cancelDiscard();
                    return err;
                };
                select.cancelDiscard();
                const phase = operation.phase.load(.acquire);
                return .{
                    .phase = phase,
                    .result = if (cancelRequested(cancel_flag) or
                        cancelRequested(lifecycle_cancel_flag) or
                        cancelRequested(commit_cancel_flag))
                        error.Cancelled
                    else
                        error.McpRequestTimedOut,
                };
            },
            .cancelled => |cancel_result| {
                cancel_result catch |err| {
                    select.cancelDiscard();
                    return err;
                };
                select.cancelDiscard();
                return .{
                    .phase = operation.phase.load(.acquire),
                    .result = error.Cancelled,
                };
            },
            .lifecycle_cancelled => |cancel_result| {
                cancel_result catch |err| {
                    select.cancelDiscard();
                    return err;
                };
                select.cancelDiscard();
                return .{
                    .phase = operation.phase.load(.acquire),
                    .result = error.Cancelled,
                };
            },
            .commit_cancelled => |cancel_result| {
                cancel_result catch |err| {
                    select.cancelDiscard();
                    return err;
                };
                select.cancelDiscard();
                return .{
                    .phase = operation.phase.load(.acquire),
                    .result = error.Cancelled,
                };
            },
        }
    }

    fn writeBodyLocked(
        self: *StdioDispatcher,
        body: []const u8,
        phase: *std.atomic.Value(WritePhase),
    ) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const running = self.state == .running;
        const stdin = self.stdin;
        self.state_mutex.unlock(io_mod.getIo());
        if (!running) return error.McpConnectionClosed;
        const writable = stdin orelse return error.McpStdinClosed;
        phase.store(.writing, .release);
        try writable.writeStreamingAll(io_mod.getIo(), body);
        try writable.writeStreamingAll(io_mod.getIo(), "\n");
        phase.store(.committed, .release);
    }

    pub fn shutdown(self: *StdioDispatcher) void {
        self.shutdownWithGrace(true);
    }

    fn shutdownForced(self: *StdioDispatcher) void {
        self.shutdownWithGrace(false);
    }

    fn shutdownWithGrace(self: *StdioDispatcher, allow_grace: bool) void {
        var should_join = false;
        self.state_mutex.lockUncancelable(io_mod.getIo());
        switch (self.state) {
            .stopped => {},
            .stopping => should_join = self.reader_thread != null,
            .running, .failed => {
                self.state = .stopping;
                self.failAllLocked(error.McpConnectionClosed);
                should_join = self.reader_thread != null;
            },
        }
        self.state_mutex.unlock(io_mod.getIo());

        self.closeStdin();
        if (!should_join) {
            self.markStopped();
            self.runDockerCleanupOnce();
            return;
        }

        if (allow_grace) {
            const deadline_ms = std.math.add(
                i64,
                io_mod.milliTimestamp(),
                shutdown_grace_ms,
            ) catch std.math.maxInt(i64);
            while (!self.readerIsDone() and io_mod.milliTimestamp() < deadline_ms) {
                io_mod.sleep(request_poll_ns);
            }
        }
        if (!self.readerIsDone()) {
            debug_trace.logf(
                "mcp",
                "stdio dispatcher requesting child termination generation={d}",
                .{self.generation},
            );
            terminateChildGracefully(self.child_id);
            const deadline_ms = std.math.add(
                i64,
                io_mod.milliTimestamp(),
                termination_grace_ms,
            ) catch std.math.maxInt(i64);
            while (!self.readerIsDone() and io_mod.milliTimestamp() < deadline_ms) {
                io_mod.sleep(request_poll_ns);
            }
        }
        if (!self.readerIsDone()) {
            debug_trace.logf(
                "mcp",
                "stdio dispatcher forcing child termination generation={d}",
                .{self.generation},
            );
            terminateChild(self.child_id);
        }

        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        while (!self.serverRequestWorkersDone()) io_mod.sleep(request_poll_ns);
        while (!self.usersDone()) io_mod.sleep(request_poll_ns);
        self.stdout = null;
        self.markStopped();
        self.runDockerCleanupOnce();
        debug_trace.logf(
            "mcp",
            "stdio dispatcher stopped generation={d} reader_joined=true",
            .{self.generation},
        );
    }

    fn runDockerCleanupOnce(self: *StdioDispatcher) void {
        var cleanup = self.docker_cleanup orelse return;
        self.docker_cleanup = null;
        defer cleanup.deinit(self.owner_allocator);
        cleanup.run(self.owner_allocator);
    }

    fn registerPending(
        self: *StdioDispatcher,
        request_id: u64,
        pending: *Pending,
        max_frame_bytes: usize,
    ) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.state != .running) return error.McpConnectionClosed;
        if (self.pending.contains(request_id)) return error.McpDuplicateRequestId;
        try self.pending.put(request_id, pending);
        _ = self.max_frame_bytes.fetchMax(max_frame_bytes, .monotonic);
    }

    fn retirePending(
        self: *StdioDispatcher,
        request_id: u64,
        pending: *Pending,
    ) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        if (self.pending.get(request_id) == pending) {
            _ = self.pending.remove(request_id);
        }
        pending.server_request_owner_retired = true;
        pending.server_request_wait_released = true;
        self.state_mutex.unlock(io_mod.getIo());

        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            const drained = pending.active_progress_callbacks == 0 and
                pending.active_response_callbacks == 0 and
                pending.active_server_request_callbacks == 0;
            self.state_mutex.unlock(io_mod.getIo());
            if (drained) break;
            io_mod.sleep(request_poll_ns);
        }
        if (pending.response) |frame| {
            self.shared_allocator.free(frame);
            pending.response = null;
        }
    }

    fn sendCancellation(self: *StdioDispatcher, request_id: u64, reason: []const u8) void {
        const body = buildCancellation(self.shared_allocator, request_id, reason) catch |err| {
            debug_trace.logf(
                "mcp",
                "failed to build cancellation generation={d} request_id={d} err={s}",
                .{ self.generation, request_id, @errorName(err) },
            );
            return;
        };
        defer self.shared_allocator.free(body);
        self.sendNotification(body, cancellation_write_timeout_ms) catch |err| {
            debug_trace.logf(
                "mcp",
                "failed to send cancellation generation={d} request_id={d} err={s}",
                .{ self.generation, request_id, @errorName(err) },
            );
        };
    }

    fn readerMain(self: *StdioDispatcher) void {
        defer {
            const stdout = self.stdout;
            if (stdout) |file| file.close(io_mod.getIo());
            self.finishReader();
        }

        const stdout = self.stdout orelse {
            self.failConnection(error.McpStdoutClosed);
            return;
        };
        var read_buf: [4096]u8 = undefined;
        var file_reader = stdout.reader(io_mod.getIo(), &read_buf);

        var terminal_error: ?anyerror = null;
        while (true) {
            const frame = readFrame(
                self.shared_allocator,
                &file_reader.interface,
                &self.max_frame_bytes,
            ) catch |err| {
                terminal_error = err;
                break;
            };
            self.dispatchFrame(frame) catch |err| {
                self.shared_allocator.free(frame);
                terminal_error = err;
                break;
            };
        }

        const stopping = self.isStopping();
        if (!stopping) {
            const err = terminal_error orelse error.McpConnectionClosed;
            self.failConnection(err);
            terminateChild(self.child_id);
        }
        _ = self.child.wait(io_mod.getIo()) catch |err| {
            debug_trace.logf(
                "mcp",
                "stdio dispatcher child wait failed generation={d} err={s}",
                .{ self.generation, @errorName(err) },
            );
        };
    }

    fn dispatchFrame(self: *StdioDispatcher, frame: []u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.shared_allocator, frame, .{}) catch
            return error.McpInvalidJson;
        defer parsed.deinit();

        const inbound = try classifyInbound(parsed.value);
        switch (inbound) {
            .response => |response_id| {
                const request_id = switch (response_id) {
                    .integer => |value| value,
                    .string => |value| {
                        debug_trace.logf(
                            "mcp",
                            "ignored unknown string response generation={d} request_id={s}",
                            .{ self.generation, value },
                        );
                        self.shared_allocator.free(frame);
                        return;
                    },
                };
                const observer_lease = self.acquireResponseObserver(request_id);
                var observer_error: ?anyerror = null;
                if (observer_lease) |lease| {
                    lease.observer.callback(
                        lease.observer.context,
                        self.shared_allocator,
                        parsed.value,
                    ) catch |err| {
                        observer_error = err;
                    };
                }
                self.state_mutex.lockUncancelable(io_mod.getIo());
                if (observer_lease) |lease| {
                    std.debug.assert(lease.pending.active_response_callbacks > 0);
                    lease.pending.active_response_callbacks -= 1;
                    lease.pending.changed.notifyLocked();
                }
                if (observer_error) |err| {
                    if (self.pending.fetchRemove(request_id)) |entry| {
                        entry.value.failure = err;
                        entry.value.changed.notifyLocked();
                        self.shared_allocator.free(frame);
                        self.state_mutex.unlock(io_mod.getIo());
                        return;
                    }
                }
                if (self.pending.fetchRemove(request_id)) |entry| {
                    const pending = entry.value;
                    if (frame.len > pending.max_frame_bytes) {
                        pending.failure = error.McpResponseFrameTooLarge;
                        pending.changed.notifyLocked();
                        self.shared_allocator.free(frame);
                        self.state_mutex.unlock(io_mod.getIo());
                        self.failConnection(error.McpResponseFrameTooLarge);
                        terminateChild(self.child_id);
                        return;
                    } else {
                        pending.response = frame;
                        pending.changed.notifyLocked();
                    }
                    self.state_mutex.unlock(io_mod.getIo());
                    return;
                }
                self.state_mutex.unlock(io_mod.getIo());
                debug_trace.logf(
                    "mcp",
                    "ignored late or unknown response generation={d} request_id={d}",
                    .{ self.generation, request_id },
                );
            },
            .progress => |progress| {
                const lease = self.acquireProgressSink(progress.token);
                if (lease) |active| {
                    active.sink.callback(active.sink.context, progress.value);
                    self.releaseProgressSink(active.pending);
                    debug_trace.logf(
                        "mcp",
                        "routed server progress generation={d}",
                        .{self.generation},
                    );
                } else {
                    debug_trace.logf(
                        "mcp",
                        "ignored late or unknown progress generation={d}",
                        .{self.generation},
                    );
                }
            },
            .notification => |method| {
                if (self.acquireNotificationSink()) |sink| {
                    sink.callback(sink.context, parsed.value);
                    self.releaseNotificationSink();
                } else {
                    debug_trace.logf(
                        "mcp",
                        "ignored server notification generation={d} method={s}",
                        .{ self.generation, method },
                    );
                }
            },
            .cancelled => |request_id| {
                self.state_mutex.lockUncancelable(io_mod.getIo());
                const pending = self.pending.get(request_id);
                if (pending != null and pending.?.purpose == .subscription) {
                    _ = self.pending.remove(request_id);
                    pending.?.failure = error.McpRequestCancelled;
                    self.state_mutex.unlock(io_mod.getIo());
                    debug_trace.logf(
                        "mcp",
                        "server cancelled subscription generation={d} request_id={d}",
                        .{ self.generation, request_id },
                    );
                } else {
                    self.state_mutex.unlock(io_mod.getIo());
                    debug_trace.logf(
                        "mcp",
                        "ignored unknown or non-subscription server cancellation generation={d} request_id={d}",
                        .{ self.generation, request_id },
                    );
                }
            },
            .request => |server_request| {
                debug_trace.logf(
                    "mcp",
                    "routing server request generation={d} method={s}",
                    .{ self.generation, server_request.method },
                );
                try self.dispatchServerRequest(frame);
                return;
            },
        }
        self.shared_allocator.free(frame);
    }

    const ProgressLease = struct {
        pending: *Pending,
        sink: ProgressSink,
    };

    const ResponseObserverLease = struct {
        pending: *Pending,
        observer: ResponseObserver,
    };

    fn acquireResponseObserver(
        self: *StdioDispatcher,
        request_id: u64,
    ) ?ResponseObserverLease {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        const pending = self.pending.get(request_id) orelse return null;
        const observer = pending.response_observer orelse return null;
        pending.active_response_callbacks += 1;
        return .{ .pending = pending, .observer = observer };
    }

    fn acquireNotificationSink(self: *StdioDispatcher) ?NotificationSink {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        const sink = self.notification_sink orelse return null;
        if (self.notification_callback_active) return null;
        self.notification_callback_active = true;
        return sink;
    }

    fn releaseNotificationSink(self: *StdioDispatcher) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        self.notification_callback_active = false;
    }

    fn acquireProgressSink(
        self: *StdioDispatcher,
        token: ProgressToken,
    ) ?ProgressLease {
        const request_id = switch (token) {
            .integer => |value| value,
            .string => return null,
        };
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        const pending = self.pending.get(request_id) orelse return null;
        const sink = pending.progress orelse return null;
        pending.active_progress_callbacks += 1;
        return .{ .pending = pending, .sink = sink };
    }

    fn releaseProgressSink(self: *StdioDispatcher, pending: *Pending) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        std.debug.assert(pending.active_progress_callbacks > 0);
        pending.active_progress_callbacks -= 1;
        pending.changed.notifyLocked();
    }

    const ServerRequestLease = struct {
        pending: *Pending,
        sink: ServerRequestSink,
    };

    const ServerRequestWork = struct {
        dispatcher: *StdioDispatcher,
        frame: []u8,
        lease: ?ServerRequestLease,

        fn run(self: *@This()) void {
            defer {
                self.dispatcher.shared_allocator.free(self.frame);
                self.dispatcher.releaseServerRequestWorker(self.lease);
                self.dispatcher.shared_allocator.destroy(self);
            }
            if (self.lease) |lease| {
                if (!self.dispatcher.waitForServerRequestOwner(lease.pending)) {
                    debug_trace.logf(
                        "mcp",
                        "discarded server request after owner retired generation={d}",
                        .{self.dispatcher.generation},
                    );
                    return;
                }
                lease.sink.callback(
                    lease.sink.context,
                    self.dispatcher.shared_allocator,
                    self.frame,
                ) catch |err| {
                    debug_trace.logf(
                        "mcp",
                        "server request callback failed generation={d} err={s}",
                        .{ self.dispatcher.generation, @errorName(err) },
                    );
                    self.dispatcher.sendServerRequestError(
                        self.frame,
                        -32603,
                        "Server request failed",
                    ) catch {};
                };
                return;
            }
            self.dispatcher.sendServerRequestError(
                self.frame,
                -32601,
                "Method not found",
            ) catch |err| {
                debug_trace.logf(
                    "mcp",
                    "server request rejection failed generation={d} err={s}",
                    .{ self.dispatcher.generation, @errorName(err) },
                );
            };
        }
    };

    fn waitForServerRequestOwner(self: *StdioDispatcher, pending: *Pending) bool {
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            const ready = !pending.server_request_wait_required or
                pending.server_request_wait_released;
            const retired = pending.server_request_owner_retired;
            self.state_mutex.unlock(io_mod.getIo());
            if (retired) return false;
            if (ready) return true;
            io_mod.sleep(request_poll_ns);
        }
    }

    fn dispatchServerRequest(self: *StdioDispatcher, frame: []u8) !void {
        const lease = self.acquireServerRequestLease();
        if (lease) |active| {
            if (active.sink.prepare_callback) |prepare| {
                prepare(active.sink.context, self.shared_allocator, frame) catch |err| {
                    defer {
                        self.shared_allocator.free(frame);
                        self.releaseServerRequestWorker(lease);
                    }
                    debug_trace.logf(
                        "mcp",
                        "server request preparation failed generation={d} err={s}",
                        .{ self.generation, @errorName(err) },
                    );
                    self.sendServerRequestError(
                        frame,
                        -32603,
                        "Server request failed",
                    ) catch {};
                    return;
                };
            }
        }
        const work = self.shared_allocator.create(ServerRequestWork) catch |err| {
            self.releaseServerRequestWorker(lease);
            return err;
        };
        work.* = .{ .dispatcher = self, .frame = frame, .lease = lease };
        const thread = std.Thread.spawn(.{}, ServerRequestWork.run, .{work}) catch |err| {
            self.shared_allocator.destroy(work);
            self.releaseServerRequestWorker(lease);
            return err;
        };
        thread.detach();
    }

    /// A legacy direct request has no parent request id. It is safe to route
    /// only when exactly one outstanding operation has declared an owner.
    fn acquireServerRequestLease(self: *StdioDispatcher) ?ServerRequestLease {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        var selected: ?ServerRequestLease = null;
        var iterator = self.pending.valueIterator();
        while (iterator.next()) |pending_ptr| {
            const pending = pending_ptr.*;
            const sink = pending.server_requests orelse continue;
            if (selected != null) {
                self.active_server_request_workers += 1;
                return null;
            }
            selected = .{ .pending = pending, .sink = sink };
        }
        if (selected) |lease| {
            lease.pending.active_server_request_callbacks += 1;
            lease.pending.changed.notifyLocked();
        }
        self.active_server_request_workers += 1;
        return selected;
    }

    fn releaseServerRequestWorker(
        self: *StdioDispatcher,
        lease: ?ServerRequestLease,
    ) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (lease) |active| {
            std.debug.assert(active.pending.active_server_request_callbacks > 0);
            active.pending.active_server_request_callbacks -= 1;
            active.pending.changed.notifyLocked();
        }
        std.debug.assert(self.active_server_request_workers > 0);
        self.active_server_request_workers -= 1;
    }

    fn serverRequestWorkersDone(self: *StdioDispatcher) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.active_server_request_workers == 0;
    }

    fn usersDone(self: *StdioDispatcher) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.active_users == 0;
    }

    fn sendServerRequestError(
        self: *StdioDispatcher,
        request_frame: []const u8,
        code: i64,
        message: []const u8,
    ) !void {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.shared_allocator,
            request_frame,
            .{ .parse_numbers = false },
        ) catch return error.McpInvalidJson;
        defer parsed.deinit();
        const id = if (parsed.value == .object)
            parsed.value.object.get("id") orelse std.json.Value.null
        else
            std.json.Value.null;
        var response: std.Io.Writer.Allocating = .init(self.shared_allocator);
        defer response.deinit();
        try response.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id, .{}, &response.writer);
        try response.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
        try std.json.Stringify.value(message, .{}, &response.writer);
        try response.writer.writeAll("}}");
        try self.sendNotification(response.writer.buffered(), server_request_write_timeout_ms);
    }

    fn failConnection(self: *StdioDispatcher, err: anyerror) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.state == .stopping or self.state == .stopped) return;
        self.state = .failed;
        self.failAllLocked(err);
        debug_trace.logf(
            "mcp",
            "stdio dispatcher failed generation={d} err={s}",
            .{ self.generation, @errorName(err) },
        );
    }

    fn failAllLocked(self: *StdioDispatcher, err: anyerror) void {
        var iterator = self.pending.valueIterator();
        while (iterator.next()) |pending| {
            pending.*.failure = err;
            pending.*.changed.notifyLocked();
        }
        self.pending.clearRetainingCapacity();
    }

    fn isStopping(self: *StdioDispatcher) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.state == .stopping or self.state == .stopped;
    }

    fn readerIsDone(self: *StdioDispatcher) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.reader_done;
    }

    fn finishReader(self: *StdioDispatcher) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        self.reader_done = true;
        if (self.state != .stopping) self.state = .failed;
        self.state_mutex.unlock(io_mod.getIo());
    }

    fn markStopped(self: *StdioDispatcher) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        self.state = .stopped;
        self.reader_done = true;
        self.state_mutex.unlock(io_mod.getIo());
    }

    fn closeStdin(self: *StdioDispatcher) void {
        if (!self.write_mutex.tryLock()) {
            debug_trace.logf(
                "mcp",
                "stdio dispatcher interrupting active writer generation={d}",
                .{self.generation},
            );
            terminateChild(self.child_id);
            self.write_mutex.lockUncancelable(io_mod.getIo());
        }
        defer self.write_mutex.unlock(io_mod.getIo());
        if (self.stdin) |stdin| {
            stdin.close(io_mod.getIo());
            self.stdin = null;
        }
    }

    fn closePipes(self: *StdioDispatcher) void {
        if (self.stdin) |stdin| stdin.close(io_mod.getIo());
        self.stdin = null;
        if (self.stdout) |stdout| stdout.close(io_mod.getIo());
        self.stdout = null;
    }
};

const WriteOperation = struct {
    dispatcher: *StdioDispatcher,
    body: []const u8,
    precommit: ?*mcp_contract.TransportPrecommit = null,
    phase: std.atomic.Value(WritePhase) = .init(.waiting),

    fn run(self: *WriteOperation) anyerror!void {
        const io = io_mod.getIo();
        try self.dispatcher.write_mutex.lock(io);
        defer self.dispatcher.write_mutex.unlock(io);
        if (self.precommit) |precommit| {
            try precommit.acquire();
            defer precommit.release();
        }
        return self.dispatcher.writeBodyLocked(self.body, &self.phase);
    }
};

fn waitForWriteDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

fn waitForWriteCancellation(cancel_flag: *const std.atomic.Value(bool)) anyerror!void {
    while (!cancel_flag.load(.seq_cst)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn requestDeadline(
    io: std.Io,
    timeout_ms: u32,
    outer_deadline: ?std.Io.Clock.Timestamp,
) std.Io.Clock.Timestamp {
    const local_deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
    const outer = outer_deadline orelse return local_deadline;
    return if (std.Io.Clock.Timestamp.compare(outer, .lt, local_deadline))
        outer
    else
        local_deadline;
}

fn pendingChangeDeadline(
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
    options: RequestOptions,
) std.Io.Clock.Timestamp {
    if (!pendingNeedsControlPolling(options)) return deadline;
    const control_poll_deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromNanoseconds(request_poll_ns),
    });
    return earlierDeadline(control_poll_deadline, deadline);
}

fn pendingNeedsControlPolling(options: RequestOptions) bool {
    return options.cancel_flag != null or
        options.lifecycle_cancel_flag != null or
        options.deadline_gate != null;
}

fn earlierDeadline(
    requested: ?std.Io.Clock.Timestamp,
    fallback: std.Io.Clock.Timestamp,
) std.Io.Clock.Timestamp {
    const candidate = requested orelse return fallback;
    return if (std.Io.Clock.Timestamp.compare(candidate, .lt, fallback))
        candidate
    else
        fallback;
}

test "pending change signal preserves notifications before wait and after reset" {
    var signal = ChangeSignal{};
    signal.prepareLocked();
    signal.notifyLocked();
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });
    try signal.wait(deadline);
    signal.prepareLocked();
    signal.notifyLocked();
    try signal.wait(deadline);
}

test "pending response waits poll only for externally owned control changes" {
    try std.testing.expect(!pendingNeedsControlPolling(.{ .timeout_ms = 100 }));

    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expect(pendingNeedsControlPolling(.{
        .timeout_ms = 100,
        .cancel_flag = &cancelled,
    }));
    try std.testing.expect(pendingNeedsControlPolling(.{
        .timeout_ms = 100,
        .lifecycle_cancel_flag = &cancelled,
    }));
}

fn waitForReadinessEvent(
    event: *std.Io.Event,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    event.waitTimeout(io_mod.getIo(), .{ .deadline = deadline }) catch |err| switch (err) {
        error.Timeout => return if (cancelRequested(cancel_flag))
            error.Cancelled
        else
            error.McpRequestTimedOut,
        else => return err,
    };
    if (cancelRequested(cancel_flag)) return error.Cancelled;
}

fn deadlineExpired(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

fn requestDeadlineExpired(
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
    gate: ?*const operation_control.DeadlineGate,
) bool {
    const active = gate orelse return deadlineExpired(io, deadline);
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const now_ms = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return active.expired(std.math.cast(i64, now_ms) orelse std.math.maxInt(i64));
}

fn buildCancellation(
    alloc: Allocator,
    request_id: u64,
    reason: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":",
    );
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn cancelRequested(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |value| value.load(.seq_cst) else false;
}

fn readFrame(
    alloc: Allocator,
    reader: *std.Io.Reader,
    max_frame_bytes: *const std.atomic.Value(usize),
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    while (true) {
        var byte_buf: [1]u8 = undefined;
        const count = try reader.readSliceShort(&byte_buf);
        if (count == 0) {
            if (line.items.len == 0) return error.McpConnectionClosed;
            return error.McpIncompleteBody;
        }
        if (byte_buf[0] != '\n') {
            if (line.items.len >= max_frame_bytes.load(.monotonic)) {
                return error.McpResponseFrameTooLarge;
            }
            try line.append(alloc, byte_buf[0]);
            continue;
        }
        line.shrinkRetainingCapacity(std.mem.trimEnd(u8, line.items, "\r").len);
        if (line.items.len == 0) continue;
        return try line.toOwnedSlice(alloc);
    }
}

fn classifyInbound(value: std.json.Value) !Inbound {
    if (value != .object) return error.McpInvalidJson;
    const object = value.object;
    const method_value = object.get("method");
    const id_value = object.get("id");

    if (method_value) |method| {
        if (method != .string) return error.McpInvalidJson;
        if (id_value) |id| return .{ .request = .{ .id = id, .method = method.string } };
        if (std.mem.eql(u8, method.string, "notifications/progress")) {
            const params = object.get("params") orelse return error.McpInvalidProgress;
            return .{ .progress = try parseProgress(params) };
        }
        if (std.mem.eql(u8, method.string, "notifications/cancelled")) {
            if (parseCancelledRequestId(object.get("params"))) |request_id| {
                return .{ .cancelled = request_id };
            }
        }
        return .{ .notification = method.string };
    }

    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    const id = id_value orelse return error.McpInvalidJson;
    return switch (id) {
        .integer => |number| .{ .response = .{
            .integer = std.math.cast(u64, number) orelse
                return error.McpUnsupportedResponseId,
        } },
        .string => |text| .{ .response = .{ .string = text } },
        else => error.McpUnsupportedResponseId,
    };
}

fn parseCancelledRequestId(params_value: ?std.json.Value) ?u64 {
    const params = params_value orelse return null;
    if (params != .object) return null;
    const request_id = params.object.get("requestId") orelse return null;
    if (request_id != .integer) return null;
    return std.math.cast(u64, request_id.integer);
}

fn parseProgress(value: std.json.Value) !ProgressEvent {
    if (value != .object) return error.McpInvalidProgress;
    const token_value = value.object.get("progressToken") orelse
        return error.McpInvalidProgress;
    const token: ProgressToken = switch (token_value) {
        .integer => |number| .{ .integer = std.math.cast(u64, number) orelse
            return error.McpInvalidProgress },
        .string => |text| .{ .string = text },
        else => return error.McpInvalidProgress,
    };
    const progress_value = value.object.get("progress") orelse
        return error.McpInvalidProgress;
    const progress = try jsonNumber(progress_value);
    const total = if (value.object.get("total")) |total_value|
        try jsonNumber(total_value)
    else
        null;
    const message = if (value.object.get("message")) |message_value| switch (message_value) {
        .string => |text| text,
        else => return error.McpInvalidProgress,
    } else null;
    return .{ .token = token, .value = .{
        .progress = progress,
        .total = total,
        .message = message,
    } };
}

fn jsonNumber(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => error.McpInvalidProgress,
    };
}

fn terminateChild(child_id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            switch (windows.ntdll.NtTerminateProcess(child_id, @enumFromInt(1))) {
                .SUCCESS, .PROCESS_IS_TERMINATING, .ACCESS_DENIED => {},
                else => |status| debug_trace.logf(
                    "mcp",
                    "failed to terminate stdio child status={any}",
                    .{status},
                ),
            }
        },
        .wasi => {},
        else => std.posix.kill(-child_id, .KILL) catch |group_err| {
            std.posix.kill(child_id, .KILL) catch |child_err| switch (child_err) {
                error.ProcessNotFound => {},
                else => debug_trace.logf(
                    "mcp",
                    "failed to terminate stdio child pid={d} group_err={s} child_err={s}",
                    .{ child_id, @errorName(group_err), @errorName(child_err) },
                ),
            };
        },
    }
}

fn terminateChildGracefully(child_id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows => terminateChild(child_id),
        .wasi => {},
        else => std.posix.kill(child_id, .TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => debug_trace.logf(
                "mcp",
                "failed to request stdio child termination pid={d} err={s}",
                .{ child_id, @errorName(err) },
            ),
        },
    }
}

test "classifyInbound separates responses notifications progress and requests" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        expected: std.meta.Tag(Inbound),
    }{
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}", .expected = .response },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}", .expected = .notification },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":8,\"progress\":2,\"total\":4,\"message\":\"half\"}}", .expected = .progress },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"sampling/createMessage\",\"params\":{}}", .expected = .request },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, std.meta.activeTag(try classifyInbound(parsed.value)));
    }
}

test "classifyInbound preserves request-specific progress values" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":42,\"progress\":1.5,\"total\":3,\"message\":\"working\"}}",
        .{},
    );
    defer parsed.deinit();

    const inbound = try classifyInbound(parsed.value);
    const progress = inbound.progress;
    try std.testing.expectEqual(@as(u64, 42), progress.token.integer);
    try std.testing.expectEqual(@as(f64, 1.5), progress.value.progress);
    try std.testing.expectEqual(@as(f64, 3), progress.value.total.?);
    try std.testing.expectEqualStrings("working", progress.value.message.?);
}

test "classifyInbound accepts string response ids and rejects malformed progress" {
    const alloc = std.testing.allocator;
    var string_response = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":\"response\",\"result\":{}}",
        .{},
    );
    defer string_response.deinit();
    try std.testing.expectEqualStrings(
        "response",
        (try classifyInbound(string_response.value)).response.string,
    );

    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":1,\"progress\":\"one\"}}",
    }) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.McpInvalidProgress,
            classifyInbound(parsed.value),
        );
    }
}

test "classifyInbound rejects malformed response envelopes" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":-1,\"message\":\"ambiguous\"}}",
    }) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.McpInvalidJson,
            classifyInbound(parsed.value),
        );
    }
}

test "cancellation notification preserves the original request id" {
    const body = try buildCancellation(
        std.testing.allocator,
        17,
        "user \"cancel\"",
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":17,\"reason\":\"user \\\"cancel\\\"\"}}",
        body,
    );
}

const ConcurrentRequest = struct {
    dispatcher: *StdioDispatcher,
    request_id: ?u64 = null,
    response: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *ConcurrentRequest) void {
        const request_id = self.dispatcher.reserveRequestId() catch |err| {
            self.err = err;
            return;
        };
        self.request_id = request_id;
        const body = std.fmt.allocPrint(
            std.heap.c_allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"fixture/call\"}}",
            .{request_id},
        ) catch |err| {
            self.err = err;
            return;
        };
        defer std.heap.c_allocator.free(body);
        self.response = self.dispatcher.request(
            std.heap.c_allocator,
            request_id,
            body,
            4096,
            .{ .timeout_ms = 2_000 },
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

const ReadinessRequest = struct {
    dispatcher: *StdioDispatcher,
    readiness: *RequestReadiness,
    commit_cancel_flag: ?*std.atomic.Value(bool) = null,
    response: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *ReadinessRequest) void {
        const request_id = self.dispatcher.reserveRequestId() catch |err| {
            self.err = err;
            return;
        };
        self.response = self.dispatcher.request(
            std.testing.allocator,
            request_id,
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"subscriptions/listen\"}",
            4096,
            .{
                .timeout_ms = 2_000,
                .commit_cancel_flag = self.commit_cancel_flag,
                .purpose = .subscription,
                .readiness = self.readiness,
            },
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn createShellDispatcher(script: []const u8) !struct {
    dispatcher: *StdioDispatcher,
    pid: std.posix.pid_t,
} {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ "sh", "-c", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    const pid = child.id.?;
    return .{
        .dispatcher = try StdioDispatcher.create(
            std.testing.allocator,
            std.heap.c_allocator,
            child,
            1,
            4096,
        ),
        .pid = pid,
    };
}

fn expectProcessReaped(pid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => {},
        };
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    return error.TestProcessStillRunning;
}

test "one dispatcher keeps reversed concurrent responses with their requests" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r first
        \\IFS= read -r second
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"owner":1}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"owner":0}}'
        \\while IFS= read -r ignored; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    var first = ConcurrentRequest{ .dispatcher = dispatcher };
    var second = ConcurrentRequest{ .dispatcher = dispatcher };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentRequest.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentRequest.run, .{&second});
    first_thread.join();
    second_thread.join();

    try std.testing.expect(first.err == null);
    try std.testing.expect(second.err == null);
    defer std.heap.c_allocator.free(first.response.?);
    defer std.heap.c_allocator.free(second.response.?);
    const first_owner = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"owner\":{d}",
        .{first.request_id.?},
    );
    defer std.testing.allocator.free(first_owner);
    const second_owner = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"owner\":{d}",
        .{second.request_id.?},
    );
    defer std.testing.allocator.free(second_owner);
    try std.testing.expect(std.mem.find(u8, first.response.?, first_owner) != null);
    try std.testing.expect(std.mem.find(u8, second.response.?, second_owner) != null);

    dispatcher.shutdown();
    try expectProcessReaped(fixture.pid);
}

test "request readiness distinguishes registration from committed transport" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete"}}'
        \\while IFS= read -r ignored; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    var readiness = RequestReadiness{};
    var request = ReadinessRequest{
        .dispatcher = dispatcher,
        .readiness = &readiness,
    };
    dispatcher.write_mutex.lockUncancelable(io_mod.getIo());
    var write_locked = true;
    defer if (write_locked) dispatcher.write_mutex.unlock(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, ReadinessRequest.run, .{&request});
    var joined = false;
    defer if (!joined) thread.join();

    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try readiness.waitRegistered(deadline, null);
    try std.testing.expectEqual(RequestReadiness.State.registered, readiness.current());
    try std.testing.expectEqual(@as(usize, 1), dispatcher.pendingRequestCount());

    dispatcher.write_mutex.unlock(io_mod.getIo());
    write_locked = false;
    try readiness.waitCommitted(deadline, null);
    try std.testing.expectEqual(RequestReadiness.State.committed, readiness.current());
    thread.join();
    joined = true;
    try std.testing.expect(request.err == null);
    defer std.testing.allocator.free(request.response.?);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pendingRequestCount());
}

test "request readiness propagates registration and write failures" {
    const registration_fixture = try createShellDispatcher(
        \\while IFS= read -r request; do :; done
    );
    const registration_dispatcher = registration_fixture.dispatcher;
    defer registration_dispatcher.deinit();
    const request_id = try registration_dispatcher.reserveRequestId();
    registration_dispatcher.shutdownForced();
    var registration = RequestReadiness{};
    try std.testing.expectError(
        error.McpConnectionClosed,
        registration_dispatcher.request(
            std.testing.allocator,
            request_id,
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"subscriptions/listen\"}",
            4096,
            .{
                .timeout_ms = 100,
                .purpose = .subscription,
                .readiness = &registration,
            },
        ),
    );
    try std.testing.expectError(
        error.McpConnectionClosed,
        registration.waitCommitted(
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromSeconds(1),
            }),
            null,
        ),
    );

    const write_fixture = try createShellDispatcher(
        \\exec tail -f /dev/null
    );
    const write_dispatcher = write_fixture.dispatcher;
    defer write_dispatcher.deinit();
    write_dispatcher.closeStdin();
    var write = RequestReadiness{};
    try std.testing.expectError(
        error.McpStdinClosed,
        write_dispatcher.request(
            std.testing.allocator,
            try write_dispatcher.reserveRequestId(),
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"subscriptions/listen\"}",
            4096,
            .{
                .timeout_ms = 100,
                .purpose = .subscription,
                .readiness = &write,
            },
        ),
    );
    try std.testing.expectEqual(RequestReadiness.State.failed, write.current());
    try std.testing.expectEqual(@as(usize, 0), write_dispatcher.pendingRequestCount());
}

test "request readiness cancellation removes the registered request" {
    const fixture = try createShellDispatcher(
        \\while IFS= read -r request; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var readiness = RequestReadiness{};
    var request = ReadinessRequest{
        .dispatcher = dispatcher,
        .readiness = &readiness,
        .commit_cancel_flag = &cancel,
    };
    dispatcher.write_mutex.lockUncancelable(io_mod.getIo());
    defer dispatcher.write_mutex.unlock(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, ReadinessRequest.run, .{&request});
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try readiness.waitRegistered(deadline, null);
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, readiness.waitCommitted(deadline, &cancel));
    thread.join();
    try std.testing.expectEqual(error.Cancelled, request.err.?);
    try std.testing.expectEqual(RequestReadiness.State.failed, readiness.current());
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pendingRequestCount());
}

test "server cancellation cannot remove an ordinary pending request" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":0,"reason":"malicious"}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"winner":"response"}}'
        \\while IFS= read -r ignored; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const request_id = try dispatcher.reserveRequestId();
    const response = try dispatcher.request(
        std.testing.allocator,
        request_id,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"tools/list\",\"params\":{}}",
        4096,
        .{ .timeout_ms = 2_000 },
    );
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.find(u8, response, "\"winner\":\"response\"") != null);

    dispatcher.shutdown();
    try expectProcessReaped(fixture.pid);
}

test "direct server requests run off-reader and preserve both JSON-RPC ids" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r origin
        \\printf '%s\n' '{"jsonrpc":"2.0","id":"legacy-request","method":"elicitation/create","params":{"message":"Choose","requestedSchema":{"type":"object","properties":{}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"legacy-request"}}'
        \\IFS= read -r elicitation_response
        \\case "$elicitation_response" in
        \\  *'"id":"legacy-request"'*'"result":{"action":"accept"}'*) ;;
        \\  *) exit 7 ;;
        \\esac
        \\printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"origin":"complete"}}'
        \\while IFS= read -r ignored; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const Capture = struct {
        dispatcher: *StdioDispatcher,
        calls: std.atomic.Value(usize) = .init(0),
        saw_exact_request_id: std.atomic.Value(bool) = .init(false),
        owner_released: std.atomic.Value(bool) = .init(false),
        callback_saw_owner_released: std.atomic.Value(bool) = .init(false),
        request_prepared: std.atomic.Value(bool) = .init(false),
        notification_saw_prepared: std.atomic.Value(bool) = .init(false),

        fn releaseOwner(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.owner_released.store(true, .release);
        }

        fn accept(raw: *anyopaque, _: Allocator, request_frame: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.calls.fetchAdd(1, .acq_rel);
            self.callback_saw_owner_released.store(
                self.owner_released.load(.acquire),
                .release,
            );
            self.saw_exact_request_id.store(
                std.mem.find(u8, request_frame, "\"id\":\"legacy-request\"") != null,
                .release,
            );
            io_mod.sleep(10 * std.time.ns_per_ms);
            try self.dispatcher.sendNotification(
                "{\"jsonrpc\":\"2.0\",\"id\":\"legacy-request\",\"result\":{\"action\":\"accept\"}}",
                1_000,
            );
        }

        fn prepare(raw: *anyopaque, _: Allocator, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.request_prepared.store(true, .release);
        }

        fn notify(raw: *anyopaque, _: std.json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.notification_saw_prepared.store(
                self.request_prepared.load(.acquire),
                .release,
            );
        }
    };

    var capture = Capture{ .dispatcher = dispatcher };
    try dispatcher.setNotificationSink(.{
        .context = @ptrCast(&capture),
        .callback = Capture.notify,
    });
    defer dispatcher.clearNotificationSink();
    const request_id = try dispatcher.reserveRequestId();
    const response = try dispatcher.request(
        std.testing.allocator,
        request_id,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"tools/call\",\"params\":{}}",
        4096,
        .{
            .timeout_ms = 2_000,
            .server_requests = .{
                .context = @ptrCast(&capture),
                .prepare_callback = Capture.prepare,
                .callback = Capture.accept,
            },
            .server_request_wait = .{
                .context = @ptrCast(&capture),
                .callback = Capture.releaseOwner,
            },
        },
    );
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.find(u8, response, "\"origin\":\"complete\"") != null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls.load(.acquire));
    try std.testing.expect(capture.saw_exact_request_id.load(.acquire));
    try std.testing.expect(capture.callback_saw_owner_released.load(.acquire));
    try std.testing.expect(capture.notification_saw_prepared.load(.acquire));

    dispatcher.shutdown();
    try expectProcessReaped(fixture.pid);
}

test "response observers establish candidates before following notifications" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32042,"message":"URL required"}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"candidate"}}'
        \\while IFS= read -r ignored; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const Capture = struct {
        observed: std.atomic.Value(bool) = .init(false),
        notification_saw_observer: std.atomic.Value(bool) = .init(false),

        fn observe(raw: *anyopaque, _: Allocator, _: std.json.Value) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.observed.store(true, .release);
        }

        fn notify(raw: *anyopaque, _: std.json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.notification_saw_observer.store(
                self.observed.load(.acquire),
                .release,
            );
        }
    };
    var capture = Capture{};
    try dispatcher.setNotificationSink(.{
        .context = @ptrCast(&capture),
        .callback = Capture.notify,
    });
    defer dispatcher.clearNotificationSink();

    const response = try dispatcher.request(
        std.testing.allocator,
        try dispatcher.reserveRequestId(),
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"tools/call\",\"params\":{}}",
        4096,
        .{
            .timeout_ms = 2_000,
            .response_observer = .{
                .context = @ptrCast(&capture),
                .callback = Capture.observe,
            },
        },
    );
    defer std.testing.allocator.free(response);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    while (!capture.notification_saw_observer.load(.acquire) and
        std.Io.Clock.Timestamp.compare(
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            .lt,
            deadline,
        ))
    {
        io_mod.sleep(request_poll_ns);
    }
    try std.testing.expect(capture.observed.load(.acquire));
    try std.testing.expect(capture.notification_saw_observer.load(.acquire));

    dispatcher.shutdown();
    try expectProcessReaped(fixture.pid);
}

test "progress callback can cancel its request without a late response win" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":0,"progress":1,"total":2,"message":"half"}}'
        \\IFS= read -r cancellation
        \\printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"late":true}}'
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const Capture = struct {
        cancel: *std.atomic.Value(bool),
        calls: usize = 0,
        message_seen: bool = false,

        fn accept(raw: *anyopaque, progress: Progress) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.message_seen = std.mem.eql(u8, progress.message orelse "", "half");
            self.cancel.store(true, .seq_cst);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var capture = Capture{ .cancel = &cancel };
    const request_id = try dispatcher.reserveRequestId();
    try std.testing.expectError(
        error.Cancelled,
        dispatcher.request(
            std.testing.allocator,
            request_id,
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/slow\",\"params\":{\"_meta\":{\"progressToken\":0}}}",
            4096,
            .{
                .timeout_ms = 2_000,
                .cancel_flag = &cancel,
                .progress = .{
                    .context = @ptrCast(&capture),
                    .callback = Capture.accept,
                },
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.message_seen);

    dispatcher.shutdown();
    try expectProcessReaped(fixture.pid);
}

test "operation timeout returns and shutdown joins an uncooperative child" {
    const fixture = try createShellDispatcher(
        \\trap '' TERM
        \\IFS= read -r request
        \\while :; do sleep 1; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const request_id = try dispatcher.reserveRequestId();
    try std.testing.expectError(
        error.McpRequestTimedOut,
        dispatcher.request(
            std.testing.allocator,
            request_id,
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/stall\"}",
            4096,
            .{ .timeout_ms = 25 },
        ),
    );

    dispatcher.shutdown();
    try expectProcessReaped(fixture.pid);
}

test "MCP normal shutdown gives a cooperative child TERM before forced cleanup" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const sentinel = try std.fmt.allocPrint(alloc, "{s}/term-sentinel", .{root});
    defer alloc.free(sentinel);
    const ready = try std.fmt.allocPrint(alloc, "{s}/ready", .{root});
    defer alloc.free(ready);
    const script = try std.fmt.allocPrint(
        alloc,
        "trap 'printf term > \"{s}\"; exit 0' TERM\nprintf ready > \"{s}\"\nwhile :; do :; done",
        .{ sentinel, ready },
    );
    defer alloc.free(script);

    const fixture = try createShellDispatcher(script);
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    dispatcher.shutdown();
    try std.Io.Dir.accessAbsolute(std.testing.io, sentinel, .{});
    try expectProcessReaped(fixture.pid);
}

test "MCP forced shutdown gives launchers bounded TERM before KILL" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const sentinel = try std.fmt.allocPrint(alloc, "{s}/term-sentinel", .{root});
    defer alloc.free(sentinel);
    const ready = try std.fmt.allocPrint(alloc, "{s}/ready", .{root});
    defer alloc.free(ready);
    const script = try std.fmt.allocPrint(
        alloc,
        "trap 'printf term > \"{s}\"; exit 0' TERM\nprintf ready > \"{s}\"\nwhile :; do :; done",
        .{ sentinel, ready },
    );
    defer alloc.free(script);

    const fixture = try createShellDispatcher(script);
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    for (0..100) |_| {
        std.Io.Dir.accessAbsolute(std.testing.io, ready, .{}) catch {
            io_mod.sleep(5 * std.time.ns_per_ms);
            continue;
        };
        break;
    } else return error.TestExpectedReady;
    dispatcher.shutdownForced();
    try std.Io.Dir.accessAbsolute(std.testing.io, sentinel, .{});
    try expectProcessReaped(fixture.pid);
}

test "the shorter request timeout wins over an outer operation deadline" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\while :; do sleep 1; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinitForced();

    const request_id = try dispatcher.reserveRequestId();
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.McpRequestTimedOut,
        dispatcher.request(
            std.testing.allocator,
            request_id,
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/stall\"}",
            4096,
            .{
                .timeout_ms = 25,
                .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                    .clock = .awake,
                    .raw = .fromSeconds(2),
                }),
                .send_cancellation = false,
            },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 150);

    dispatcher.shutdownForced();
    try expectProcessReaped(fixture.pid);
}

test "local cancellation does not require a protocol cancellation notification" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\while :; do sleep 1; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinitForced();

    const CancelledRequest = struct {
        dispatcher: *StdioDispatcher,
        cancel: *std.atomic.Value(bool),
        readiness: *RequestReadiness,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            const request_id = self.dispatcher.reserveRequestId() catch |err| {
                self.err = err;
                return;
            };
            const response = self.dispatcher.request(
                std.testing.allocator,
                request_id,
                "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/stall\"}",
                4096,
                .{
                    .timeout_ms = 2_000,
                    .cancel_flag = self.cancel,
                    .send_cancellation = false,
                    .readiness = self.readiness,
                },
            ) catch |err| {
                self.err = err;
                return;
            };
            std.testing.allocator.free(response);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var readiness = RequestReadiness{};
    var request = CancelledRequest{
        .dispatcher = dispatcher,
        .cancel = &cancel,
        .readiness = &readiness,
    };
    const request_thread = try std.Thread.spawn(.{}, CancelledRequest.run, .{&request});
    var joined = false;
    defer if (!joined) {
        cancel.store(true, .release);
        request_thread.join();
    };
    const commit_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try readiness.waitCommitted(commit_deadline, null);
    cancel.store(true, .release);
    request_thread.join();
    joined = true;

    try std.testing.expectEqual(error.Cancelled, request.err.?);

    dispatcher.shutdownForced();
    try expectProcessReaped(fixture.pid);
}

test "runtime retirement cancels a committed request without replacing caller cancellation" {
    const fixture = try createShellDispatcher(
        \\IFS= read -r request
        \\while :; do sleep 1; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinitForced();

    const PendingRequest = struct {
        dispatcher: *StdioDispatcher,
        caller_cancel: *std.atomic.Value(bool),
        lifecycle_cancel: *const std.atomic.Value(bool),
        readiness: *RequestReadiness,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            const request_id = self.dispatcher.reserveRequestId() catch |err| {
                self.err = err;
                return;
            };
            const response = self.dispatcher.request(
                std.testing.allocator,
                request_id,
                "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/stall\"}",
                4096,
                .{
                    .timeout_ms = 2_000,
                    .cancel_flag = self.caller_cancel,
                    .lifecycle_cancel_flag = self.lifecycle_cancel,
                    .readiness = self.readiness,
                },
            ) catch |err| {
                self.err = err;
                return;
            };
            std.testing.allocator.free(response);
        }
    };
    const Signal = struct {
        start: *const std.atomic.Value(bool),
        flag: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            while (!self.start.load(.acquire)) {
                std.atomic.spinLoopHint();
            }
            self.flag.store(true, .release);
        }
    };

    var caller_cancel = std.atomic.Value(bool).init(false);
    var lifecycle_cancel = std.atomic.Value(bool).init(false);
    var readiness = RequestReadiness{};
    var request = PendingRequest{
        .dispatcher = dispatcher,
        .caller_cancel = &caller_cancel,
        .lifecycle_cancel = &lifecycle_cancel,
        .readiness = &readiness,
    };
    const request_thread = try std.Thread.spawn(.{}, PendingRequest.run, .{&request});
    var request_joined = false;
    defer if (!request_joined) {
        lifecycle_cancel.store(true, .release);
        request_thread.join();
    };
    try readiness.waitCommitted(
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(1),
        }),
        null,
    );

    var start = std.atomic.Value(bool).init(false);
    const caller_thread = try std.Thread.spawn(.{}, Signal.run, .{Signal{
        .start = &start,
        .flag = &caller_cancel,
    }});
    const retirement_thread = try std.Thread.spawn(.{}, Signal.run, .{Signal{
        .start = &start,
        .flag = &lifecycle_cancel,
    }});
    start.store(true, .release);
    caller_thread.join();
    retirement_thread.join();
    request_thread.join();
    request_joined = true;

    try std.testing.expectEqual(error.Cancelled, request.err.?);
    try std.testing.expect(caller_cancel.load(.acquire));
    try std.testing.expect(lifecycle_cancel.load(.acquire));

    dispatcher.shutdownForced();
    try expectProcessReaped(fixture.pid);
}

test "request reports a registration failure as definitely unsent" {
    const fixture = try createShellDispatcher(
        \\while IFS= read -r request; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const request_id = try dispatcher.reserveRequestId();
    dispatcher.shutdownForced();
    var request_started = true;
    try std.testing.expectError(
        error.McpConnectionClosed,
        dispatcher.request(
            std.testing.allocator,
            request_id,
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/closed\"}",
            4096,
            .{
                .timeout_ms = 25,
                .request_started = &request_started,
            },
        ),
    );
    try std.testing.expect(!request_started);
    try expectProcessReaped(fixture.pid);
}

test "precommit rejection is unsent and preserves the connection" {
    const fixture = try createShellDispatcher(
        \\while IFS= read -r request; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const Reject = struct {
        fn acquire(_: *anyopaque) !void {
            return error.McpToolCatalogChanged;
        }

        fn release(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    var precommit = mcp_contract.TransportPrecommit{
        .context = &context,
        .acquire_callback = Reject.acquire,
        .release_callback = Reject.release,
    };
    var request_started = true;
    try std.testing.expectError(
        error.McpToolCatalogChanged,
        dispatcher.request(
            std.testing.allocator,
            try dispatcher.reserveRequestId(),
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/rejected\"}",
            4096,
            .{
                .timeout_ms = 25,
                .request_started = &request_started,
                .precommit = &precommit,
            },
        ),
    );
    try std.testing.expect(!request_started);
    try std.testing.expect(dispatcher.isRunning());
}

test "precommit rejection drains a leased direct server request" {
    const fixture = try createShellDispatcher(
        \\while IFS= read -r request; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const Capture = struct {
        callback_started: std.atomic.Value(bool) = .init(false),
        callback_finished: std.atomic.Value(bool) = .init(false),

        fn reject(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const deadline = io_mod.milliTimestamp() + 1_000;
            while (!self.callback_started.load(.acquire) and
                io_mod.milliTimestamp() < deadline)
            {
                io_mod.sleep(request_poll_ns);
            }
            if (!self.callback_started.load(.acquire)) return error.TestExpectedEqual;
            return error.McpToolCatalogChanged;
        }

        fn release(_: *anyopaque) void {}

        fn accept(raw: *anyopaque, _: Allocator, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callback_started.store(true, .release);
            io_mod.sleep(50 * std.time.ns_per_ms);
            self.callback_finished.store(true, .release);
        }
    };

    const RejectedRequest = struct {
        dispatcher: *StdioDispatcher,
        readiness: *RequestReadiness,
        capture: *Capture,
        request_id: u64,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            var precommit = mcp_contract.TransportPrecommit{
                .context = self.capture,
                .acquire_callback = Capture.reject,
                .release_callback = Capture.release,
            };
            const response = self.dispatcher.request(
                std.testing.allocator,
                self.request_id,
                "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/rejected\"}",
                4096,
                .{
                    .timeout_ms = 2_000,
                    .readiness = self.readiness,
                    .server_requests = .{
                        .context = @ptrCast(self.capture),
                        .callback = Capture.accept,
                    },
                    .precommit = &precommit,
                },
            ) catch |err| {
                self.err = err;
                return;
            };
            std.testing.allocator.free(response);
        }
    };

    var capture = Capture{};
    var readiness = RequestReadiness{};
    var request = RejectedRequest{
        .dispatcher = dispatcher,
        .readiness = &readiness,
        .capture = &capture,
        .request_id = try dispatcher.reserveRequestId(),
    };
    const request_thread = try std.Thread.spawn(.{}, RejectedRequest.run, .{&request});
    var joined = false;
    defer if (!joined) request_thread.join();
    const registration_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try readiness.waitRegistered(registration_deadline, null);
    const frame = try dispatcher.shared_allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"id\":\"unsolicited\",\"method\":\"elicitation/create\",\"params\":{}}",
    );
    dispatcher.dispatchServerRequest(frame) catch |err| {
        dispatcher.shared_allocator.free(frame);
        return err;
    };
    request_thread.join();
    joined = true;

    try std.testing.expectEqual(error.McpToolCatalogChanged, request.err.?);
    const returned_before_callback_finished = !capture.callback_finished.load(.acquire);
    const deadline = io_mod.milliTimestamp() + 1_000;
    while (!capture.callback_finished.load(.acquire) and
        io_mod.milliTimestamp() < deadline)
    {
        io_mod.sleep(request_poll_ns);
    }
    try std.testing.expect(!returned_before_callback_finished);
    try std.testing.expect(capture.callback_finished.load(.acquire));
}

test "operation deadline includes waiting for the serialized writer" {
    const fixture = try createShellDispatcher(
        \\while IFS= read -r request; do :; done
    );
    const dispatcher = fixture.dispatcher;
    defer dispatcher.deinit();

    const LockWaitRequest = struct {
        dispatcher: *StdioDispatcher,
        readiness: *RequestReadiness,
        finished: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.finished.store(true, .release);
            const request_id = self.dispatcher.reserveRequestId() catch |err| {
                self.err = err;
                return;
            };
            const response = self.dispatcher.request(
                std.testing.allocator,
                request_id,
                "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"fixture/lock-wait\"}",
                4096,
                .{ .timeout_ms = 25, .readiness = self.readiness },
            ) catch |err| {
                self.err = err;
                return;
            };
            std.testing.allocator.free(response);
        }
    };

    dispatcher.write_mutex.lockUncancelable(io_mod.getIo());
    var write_locked = true;
    defer if (write_locked) dispatcher.write_mutex.unlock(io_mod.getIo());
    var readiness = RequestReadiness{};
    var request = LockWaitRequest{
        .dispatcher = dispatcher,
        .readiness = &readiness,
    };
    const request_thread = try std.Thread.spawn(.{}, LockWaitRequest.run, .{&request});
    var joined = false;
    defer if (!joined) {
        if (write_locked) {
            dispatcher.write_mutex.unlock(io_mod.getIo());
            write_locked = false;
        }
        request_thread.join();
    };
    const registration_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try waitForReadinessEvent(&readiness.registered_event, registration_deadline, null);
    const finish_deadline = io_mod.milliTimestamp() + 5_000;
    while (!request.finished.load(.acquire) and
        io_mod.milliTimestamp() < finish_deadline)
    {
        io_mod.sleep(request_poll_ns);
    }
    const finished_while_locked = request.finished.load(.acquire);
    dispatcher.write_mutex.unlock(io_mod.getIo());
    write_locked = false;
    request_thread.join();
    joined = true;

    try std.testing.expect(finished_while_locked);
    try std.testing.expectEqual(error.McpRequestTimedOut, request.err.?);
}

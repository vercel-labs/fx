//! In-process owner of the `tty=true` terminals one fx process starts.
//!
//! Requests are admitted without I/O, then run on worker threads against a
//! native session registry and durable profile store that are created on the
//! first request. Terminals belong to this process instance: exit paths call
//! `closeOwnedTerminals` (or `deinit`), which ends every one of them with no
//! prompt, and a crash leaves them to the kernel PTY hangup and the launcher's
//! stdin watchdog. Nothing here outlives the process.

const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const host_target = @import("../hosts/target.zig");
const contracts = @import("contracts.zig");
const operation = @import("operation.zig");
const native_session = @import("native_session.zig");
const terminal_store = @import("store.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const json_decode = @import("../shared/json_decode.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
const process_identity = @import("../execution/process_identity.zig");
const process_tree = @import("../execution/process_tree.zig");
const ui_projection = @import("ui_projection.zig");

const Allocator = std.mem.Allocator;
const max_active_requests: usize = 32;
const queue_capacity: usize = 16;
const outcome_capacity: usize = 32;
// macOS GUI apps commonly inherit 256 descriptors, below what the 64-session
// terminal budget needs.
const desired_file_descriptor_limit: u64 = 1024;

pub const AdmissionError =
    contracts.RequestValidationError ||
    Allocator.Error ||
    error{
        DuplicateCorrelation,
        QueueFull,
        RuntimeStopping,
        TerminalUnavailable,
        WorkerStartFailed,
        InvalidCorrelationId,
    };

pub const CompletionKind = enum {
    response,
    cancelled,
    /// The operation failed before it produced a result.
    disconnected,
    /// This process cannot run terminals, for example without `HOME`.
    unavailable,
};

const OwnedResponse = struct {
    alloc: Allocator,
    value: contracts.OwnedResult,
};

pub const Completion = struct {
    kind: CompletionKind,
    correlation_id: ?contracts.CorrelationId = null,
    /// Present only for `.response`, and owned by the completion.
    response: ?OwnedResponse = null,

    pub fn deinit(self: *Completion) void {
        if (self.response) |*response| response.value.deinit(response.alloc);
        self.* = undefined;
    }
};

const Intent = struct {
    correlation_id: contracts.CorrelationId,
    request: contracts.OwnedActionRequest,

    fn deinit(self: *Intent, alloc: Allocator) void {
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

const Queue = struct {
    values: [queue_capacity]?Intent = @splat(null),
    len: usize = 0,

    fn admit(self: *Queue, intent: Intent, stopping: bool) AdmissionError!void {
        if (stopping) return error.RuntimeStopping;
        if (self.len >= self.values.len) return error.QueueFull;
        self.values[self.len] = intent;
        self.len += 1;
    }

    fn take(self: *Queue) ?Intent {
        return self.removeAt(0);
    }

    fn cancel(
        self: *Queue,
        correlation_id: contracts.CorrelationId,
    ) ?Intent {
        for (self.values[0..self.len], 0..) |entry, index| {
            const intent = entry.?;
            if (intent.correlation_id.value != correlation_id.value) continue;
            return self.removeAt(index);
        }
        return null;
    }

    fn removeAt(self: *Queue, index: usize) ?Intent {
        if (index >= self.len) return null;
        const intent = self.values[index].?;
        var shift_index = index;
        while (shift_index + 1 < self.len) : (shift_index += 1) {
            self.values[shift_index] = self.values[shift_index + 1];
        }
        self.len -= 1;
        self.values[self.len] = null;
        return intent;
    }
};

const CompletionSink = struct {
    values: [outcome_capacity]?Completion = @splat(null),
    len: usize = 0,
    correlated_len: usize = 0,

    fn push(self: *CompletionSink, completion: Completion) void {
        std.debug.assert(completion.correlation_id != null);
        std.debug.assert(self.correlated_len < outcome_capacity);
        self.correlated_len += 1;
        std.debug.assert(self.len < self.values.len);
        self.values[self.len] = completion;
        self.len += 1;
    }

    fn take(self: *CompletionSink) ?Completion {
        return self.removeAt(0);
    }

    fn takeForCorrelation(
        self: *CompletionSink,
        correlation_id: contracts.CorrelationId,
    ) ?Completion {
        for (self.values[0..self.len], 0..) |entry, index| {
            const completion = entry.?;
            const candidate = completion.correlation_id orelse continue;
            if (candidate.value == correlation_id.value) {
                return self.removeAt(index);
            }
        }
        return null;
    }

    fn removeAt(self: *CompletionSink, index: usize) ?Completion {
        if (index >= self.len) return null;
        const completion = self.values[index].?;
        var shift_index = index;
        while (shift_index + 1 < self.len) : (shift_index += 1) {
            self.values[shift_index] = self.values[shift_index + 1];
        }
        self.len -= 1;
        self.values[self.len] = null;
        self.correlated_len -= 1;
        return completion;
    }
};

/// Correlations that are queued, running, or holding an untaken completion.
/// Bounded by `outcome_capacity` so every one of them has a completion slot.
const PendingRequests = struct {
    values: [outcome_capacity]?contracts.CorrelationId = @splat(null),

    fn add(
        self: *PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) error{ DuplicateCorrelation, CapacityExceeded }!void {
        correlation_id.validate() catch return error.DuplicateCorrelation;
        var free_index: ?usize = null;
        for (self.values, 0..) |entry, index| {
            if (entry) |existing| {
                if (existing.value == correlation_id.value) {
                    return error.DuplicateCorrelation;
                }
            } else if (free_index == null) {
                free_index = index;
            }
        }
        self.values[free_index orelse return error.CapacityExceeded] = correlation_id;
    }

    fn contains(
        self: *const PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) bool {
        for (self.values) |entry| {
            if (entry) |existing| {
                if (existing.value == correlation_id.value) return true;
            }
        }
        return false;
    }

    fn remove(
        self: *PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) bool {
        for (&self.values) |*entry| {
            const existing = entry.* orelse continue;
            if (existing.value != correlation_id.value) continue;
            entry.* = null;
            return true;
        }
        return false;
    }
};

/// Mutations that share one session's write ownership run in admission order.
/// Every issued ticket must be completed exactly once.
const OrderedMutations = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    next_ticket: u64 = 0,
    serving_ticket: u64 = 0,

    fn issue(self: *OrderedMutations) u64 {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const ticket = self.next_ticket;
        self.next_ticket += 1;
        return ticket;
    }

    fn wait(self: *OrderedMutations, ticket: u64) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        while (self.serving_ticket != ticket) {
            self.changed.waitUncancelable(zio, &self.mutex);
        }
    }

    fn complete(self: *OrderedMutations, ticket: u64) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        std.debug.assert(self.serving_ticket == ticket);
        self.serving_ticket += 1;
        self.changed.broadcast(zio);
    }
};

/// The durable store and session registry this process runs terminals with.
/// Heap-pinned: the registry borrows `store` and `owner_identity`.
const Backend = struct {
    store: terminal_store.ProfileStore,
    registry: native_session.Registry,
    owner_identity_bytes: [terminal_store.max_owner_identity_bytes]u8,
    process_owner: contracts.ProcessOwner,
};

pub const Runtime = struct {
    process_provider: process_provider_mod.Provider =
        process_provider_mod.unavailable_provider,
    /// Profile home for the durable store. Null reads `HOME` when the first
    /// request runs; tests point it at a temporary directory.
    profile_home: ?[]const u8 = null,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    queue: Queue = .{},
    completions: CompletionSink = .{},
    live_correlations: PendingRequests = .{},
    thread: ?std.Thread = null,
    alloc: ?Allocator = null,
    stopping: bool = false,
    stop_requested: std.atomic.Value(bool) = .init(false),
    active: [max_active_requests]?*RequestWorker = @splat(null),
    active_count: usize = 0,
    next_correlation_value: u64 = 1,
    projection: ui_projection.Store = .{},
    ordered: OrderedMutations = .{},
    /// Guards `backend` and `backend_closed`. Never held with `mutex`.
    backend_mutex: std.Io.Mutex = .init,
    backend: ?*Backend = null,
    /// Set once the owned terminals have been ended for exit; no backend is
    /// opened after that.
    backend_closed: bool = false,
    /// Whether every backend thread finished during the exit close, which
    /// freeing the backend requires.
    backend_drained: bool = true,

    pub fn nextCorrelationId(self: *Runtime) contracts.CorrelationId {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const result = contracts.CorrelationId{
            .value = self.next_correlation_value,
        };
        self.next_correlation_value +%= 1;
        if (self.next_correlation_value == 0) self.next_correlation_value = 1;
        return result;
    }

    pub fn init(
        process_provider: process_provider_mod.Provider,
    ) Runtime {
        return .{ .process_provider = process_provider };
    }

    /// Takes ownership of a copy of `request`. `alloc` must be thread-safe
    /// and outlive the runtime; the first admission fixes it.
    pub fn admit(
        self: *Runtime,
        alloc: Allocator,
        correlation_id: contracts.CorrelationId,
        request: contracts.ActionRequest,
    ) AdmissionError!void {
        if (comptime host_target.is_wasm) return error.TerminalUnavailable;
        try correlation_id.validate();
        var intent = Intent{
            .correlation_id = correlation_id,
            .request = try contracts.OwnedActionRequest.init(alloc, request),
        };

        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.alloc) |existing| {
            if (existing.ptr != alloc.ptr or existing.vtable != alloc.vtable) {
                intent.deinit(alloc);
                return error.RuntimeStopping;
            }
        } else {
            self.alloc = alloc;
        }
        self.admitIntentLocked(intent) catch |err| {
            intent.deinit(alloc);
            return err;
        };
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch {
                var rollback = self.rollbackAdmissionLocked(correlation_id);
                rollback.deinit(alloc);
                return error.WorkerStartFailed;
            };
        }
        self.wake.signal(zio);
    }

    pub fn cancel(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) bool {
        correlation_id.validate() catch return false;
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.queue.cancel(correlation_id)) |intent_value| {
            var intent = intent_value;
            intent.deinit(self.alloc.?);
            self.completions.push(.{
                .kind = .cancelled,
                .correlation_id = correlation_id,
            });
            return true;
        }
        for (self.active) |entry| {
            const worker = entry orelse continue;
            if (worker.intent.correlation_id.value != correlation_id.value) {
                continue;
            }
            worker.cancelled.store(true, .release);
            return true;
        }
        return false;
    }

    pub fn takeCompletion(self: *Runtime) ?Completion {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const completion = self.completions.take() orelse return null;
        self.consumeCompletionLocked(completion);
        return completion;
    }

    pub fn takeCompletionFor(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) ?Completion {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const completion = self.completions.takeForCorrelation(correlation_id) orelse
            return null;
        self.consumeCompletionLocked(completion);
        return completion;
    }

    pub fn terminalProjection(
        self: *Runtime,
        alloc: Allocator,
    ) Allocator.Error!ui_projection.Snapshot {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.projection.snapshot(alloc);
    }

    pub fn clearTerminalProjection(self: *Runtime) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const alloc = self.alloc orelse return false;
        return self.projection.clear(alloc);
    }

    /// Ends the in-flight mark that a start with `retain_in_flight` left on
    /// `session_id`, once its caller has indexed the terminal or given up.
    /// The backend mutex is held only to read the backend, which `deinit`
    /// alone frees, so no lock is held while the store takes its own.
    pub fn endStart(self: *Runtime, session_id: []const u8) void {
        const zio = io_mod.getIo();
        self.backend_mutex.lockUncancelable(zio);
        const backend = self.backend;
        self.backend_mutex.unlock(zio);
        if (backend) |value| value.store.end_start(session_id);
    }

    /// Ends every terminal this runtime started, with no prompt, and refuses
    /// later requests. Running requests are cancelled. For process-exit paths
    /// that skip `deinit`; idempotent, and bounded by the registry's exit
    /// grace and join limits.
    pub fn closeOwnedTerminals(self: *Runtime) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        self.stopping = true;
        self.stop_requested.store(true, .release);
        for (self.active) |entry| {
            const worker = entry orelse continue;
            worker.cancelled.store(true, .release);
        }
        self.wake.broadcast(zio);
        self.mutex.unlock(zio);

        self.backend_mutex.lockUncancelable(zio);
        defer self.backend_mutex.unlock(zio);
        if (self.backend_closed) return;
        self.backend_closed = true;
        const backend = self.backend orelse return;
        self.backend_drained = backend.registry.closeAllForExit();
    }

    /// Waits until `timeout_ms` for backend threads that the exit close left
    /// draining, so a test can free the backend. fx's own exit never waits
    /// past its budget, and keeps such a backend allocated instead.
    pub fn joinExitDrainForTest(self: *Runtime, timeout_ms: i64) void {
        const zio = io_mod.getIo();
        self.backend_mutex.lockUncancelable(zio);
        defer self.backend_mutex.unlock(zio);
        if (self.backend_drained) return;
        const backend = self.backend orelse return;
        self.backend_drained = backend.registry.joinDrainingBackendsBefore(
            io_mod.milliTimestamp() + timeout_ms,
        );
    }

    pub fn deinit(self: *Runtime) void {
        self.closeOwnedTerminals();
        if (self.thread) |thread| thread.join();
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        while (self.active_count != 0) {
            self.wake.waitUncancelable(zio, &self.mutex);
        }
        self.mutex.unlock(zio);
        const alloc = self.alloc orelse {
            self.resetDrainedState();
            return;
        };
        while (self.queue.take()) |intent_value| {
            var intent = intent_value;
            self.releaseCorrelationLocked(intent.correlation_id);
            intent.deinit(alloc);
        }
        while (self.completions.take()) |completion_value| {
            var completion = completion_value;
            self.consumeCompletionLocked(completion);
            completion.deinit();
        }
        self.projection.deinit(alloc);
        if (self.backend) |backend| {
            if (self.backend_drained) {
                backend.registry.deinit();
                backend.store.deinit();
                alloc.destroy(backend);
            } else {
                // Backend threads still read the registry, so it stays
                // allocated until the process exits.
                debug_trace.logf(
                    "terminal_client",
                    "terminal backend left allocated: threads still draining",
                    .{},
                );
            }
        }
        self.resetDrainedState();
    }

    noinline fn resetDrainedState(self: *Runtime) void {
        // The drain above already nulls every owned slot. Reset only the
        // observable metadata so teardown does not copy the full runtime.
        self.process_provider = process_provider_mod.unavailable_provider;
        self.profile_home = null;
        self.mutex = .init;
        self.wake = .init;
        self.queue.len = 0;
        self.completions.len = 0;
        self.completions.correlated_len = 0;
        self.thread = null;
        self.alloc = null;
        self.stopping = false;
        self.stop_requested = .init(false);
        self.active_count = 0;
        self.next_correlation_value = 1;
        self.projection = .{};
        self.ordered = .{};
        self.backend_mutex = .init;
        self.backend = null;
        self.backend_closed = false;
        self.backend_drained = true;
    }

    fn consumeCompletionLocked(self: *Runtime, completion: Completion) void {
        const correlation_id = completion.correlation_id orelse return;
        self.releaseCorrelationLocked(correlation_id);
    }

    fn admitIntentLocked(
        self: *Runtime,
        intent: Intent,
    ) AdmissionError!void {
        if (self.live_correlations.contains(intent.correlation_id)) {
            return error.DuplicateCorrelation;
        }
        self.live_correlations.add(intent.correlation_id) catch |err| switch (err) {
            error.DuplicateCorrelation => return error.DuplicateCorrelation,
            error.CapacityExceeded => return error.QueueFull,
        };
        self.queue.admit(intent, self.stopping) catch |err| {
            self.releaseCorrelationLocked(intent.correlation_id);
            return err;
        };
    }

    fn rollbackAdmissionLocked(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) Intent {
        const intent = self.queue.cancel(correlation_id) orelse unreachable;
        self.releaseCorrelationLocked(correlation_id);
        return intent;
    }

    fn releaseCorrelationLocked(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) void {
        std.debug.assert(self.live_correlations.remove(correlation_id));
    }

    /// Publishes a worker's completion and frees the worker and its intent.
    /// It frees them before the broadcast that lets `deinit` finish, so a
    /// detached worker never touches the allocator after its runtime stopped.
    fn finishActive(
        self: *Runtime,
        worker: *RequestWorker,
        completion: Completion,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        std.debug.assert(self.active[worker.slot] == worker);
        self.active[worker.slot] = null;
        self.active_count -= 1;
        self.observeProjectionLocked(worker.intent.request.value, completion);
        self.completions.push(completion);
        const alloc = self.alloc.?;
        worker.intent.deinit(alloc);
        alloc.destroy(worker);
        self.wake.broadcast(zio);
    }

    fn observeProjectionLocked(
        self: *Runtime,
        request: contracts.ActionRequest,
        completion: Completion,
    ) void {
        const response = completion.response orelse return;
        self.projection.observe(self.alloc.?, request, response.value.view()) catch |err| {
            debug_trace.logf(
                "terminal_client",
                "ui projection update failed err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn registerWorkerLocked(self: *Runtime, worker: *RequestWorker) ?usize {
        for (&self.active, 0..) |*entry, index| {
            if (entry.* != null) continue;
            entry.* = worker;
            self.active_count += 1;
            return index;
        }
        return null;
    }

    /// Opens the store and registry on the first request. Fails after the
    /// owned terminals were ended for exit, so none can start later.
    fn openBackend(self: *Runtime) !*Backend {
        const zio = io_mod.getIo();
        self.backend_mutex.lockUncancelable(zio);
        defer self.backend_mutex.unlock(zio);
        if (self.backend) |backend| return backend;
        if (self.backend_closed) return error.RuntimeStopping;
        const alloc = self.alloc.?;
        const home = self.profile_home orelse io_mod.homeDir() orelse
            return error.HomeNotSet;

        const pid = std.c.getpid();
        var pid_buffer: [32]u8 = undefined;
        const pid_text = try std.mem.print(&pid_buffer, "{d}", .{pid});
        const token = try self.process_provider.captureToken(alloc, pid_text);
        var instance_bytes: [16]u8 = undefined;
        zio.random(&instance_bytes);
        const instance = std.fmt.bytesToHex(instance_bytes, .lower);

        const backend = try alloc.create(Backend);
        errdefer alloc.destroy(backend);
        backend.process_owner = try contracts.ProcessOwner.init(pid, token.view());
        const owner_identity = try terminal_store.formatOwnerIdentity(
            &backend.owner_identity_bytes,
            &instance,
            pid,
            token,
        );
        backend.store = try terminal_store.ProfileStore.init(
            alloc,
            home,
            self.process_provider,
        );
        backend.registry = native_session.Registry.init(
            alloc,
            .{ .context = null, .update_fn = ignoreLiveWork },
            &backend.store,
            owner_identity,
        );
        self.backend = backend;
        debug_trace.logf(
            "terminal_client",
            "terminal backend opened pid={d}",
            .{pid},
        );
        return backend;
    }
};

fn ignoreLiveWork(_: ?*anyopaque, _: bool) void {}

fn workerMain(runtime: *Runtime) void {
    const alloc = runtime.alloc.?;
    while (true) {
        const intent = takeIntent(runtime) orelse return;
        const worker = alloc.create(RequestWorker) catch {
            finishUnstarted(runtime, alloc, intent);
            continue;
        };
        worker.* = .{ .runtime = runtime, .intent = intent };

        const zio = io_mod.getIo();
        runtime.mutex.lockUncancelable(zio);
        const slot = runtime.registerWorkerLocked(worker);
        if (slot) |index| worker.slot = index;
        runtime.mutex.unlock(zio);
        if (slot == null) {
            const unstarted = worker.intent;
            alloc.destroy(worker);
            finishUnstarted(runtime, alloc, unstarted);
            continue;
        }
        // Tickets are issued here, in admission order, before any worker of
        // a later request can run.
        if (operation.requiresOrderedMutation(worker.intent.request.value)) {
            worker.ordered_ticket = runtime.ordered.issue();
        }
        var thread = std.Thread.spawn(.{}, RequestWorker.run, .{worker}) catch {
            if (worker.ordered_ticket) |ticket| {
                runtime.ordered.wait(ticket);
                runtime.ordered.complete(ticket);
            }
            runtime.finishActive(worker, .{
                .kind = .disconnected,
                .correlation_id = worker.intent.correlation_id,
            });
            continue;
        };
        thread.detach();
    }
}

const RequestWorker = struct {
    runtime: *Runtime,
    intent: Intent,
    slot: usize = 0,
    ordered_ticket: ?u64 = null,
    cancelled: std.atomic.Value(bool) = .init(false),

    fn run(self: *RequestWorker) void {
        const completion = self.complete(self.runtime.alloc.?);
        // This frees the worker, so nothing here may use it afterwards.
        self.runtime.finishActive(self, completion);
    }

    fn complete(self: *RequestWorker, alloc: Allocator) Completion {
        const correlation_id = self.intent.correlation_id;
        if (self.ordered_ticket) |ticket| self.runtime.ordered.wait(ticket);
        defer if (self.ordered_ticket) |ticket| self.runtime.ordered.complete(ticket);
        if (self.runtime.stop_requested.load(.acquire) or
            self.cancelled.load(.acquire))
        {
            return .{ .kind = .cancelled, .correlation_id = correlation_id };
        }
        const backend = self.runtime.openBackend() catch |err| {
            debug_trace.logf(
                "terminal_client",
                "terminal backend unavailable err={s}",
                .{@errorName(err)},
            );
            return .{ .kind = .unavailable, .correlation_id = correlation_id };
        };
        var request = self.intent.request.value;
        operation.attachProcessOwner(&request, backend.process_owner);
        if (request == .start) ensureFileDescriptorBudget();
        var result = execute(alloc, backend, request, &self.cancelled) catch |err| {
            debug_trace.logf(
                "terminal_client",
                "request failed correlation={d} action={s} err={s}",
                .{ correlation_id.value, @tagName(request.action()), @errorName(err) },
            );
            return .{ .kind = .disconnected, .correlation_id = correlation_id };
        };
        if (self.cancelled.load(.acquire)) {
            closeCancelledStart(alloc, backend, request, result.view());
            result.deinit(alloc);
            persistCancellation(backend, request);
            return .{ .kind = .cancelled, .correlation_id = correlation_id };
        }
        return .{
            .kind = .response,
            .correlation_id = correlation_id,
            .response = .{ .alloc = alloc, .value = result },
        };
    }
};

fn execute(
    alloc: Allocator,
    backend: *Backend,
    request: contracts.ActionRequest,
    cancelled: *const std.atomic.Value(bool),
) !contracts.OwnedResult {
    return operation.execute(&backend.registry, request, cancelled) catch |err| switch (err) {
        error.MissingTerminalAuthority,
        error.InvalidAuthorityClaim,
        error.InvalidAuthorityGeneration,
        error.InvalidPrincipal,
        => contracts.OwnedResult.init(alloc, .{ .failure = .{
            .action = request.action(),
            .code = .authority_denied,
        } }),
        else => err,
    };
}

/// Force-closes the terminal a cancelled start created. The caller only
/// learns `.cancelled`, never the session id, so without this the command
/// would run unseen until fx exits. Only `start` creates a session; every
/// other action works on one its caller already holds.
fn closeCancelledStart(
    alloc: Allocator,
    backend: *Backend,
    request: contracts.ActionRequest,
    result: contracts.Result,
) void {
    const start = switch (request) {
        .start => |value| value,
        else => return,
    };
    const persistence = start.persistence orelse return;
    const session_id = switch (result) {
        .success => |success| switch (success) {
            .start => |value| value.session.session_id,
            else => return,
        },
        .failure => return,
    };
    // The caller only learns `.cancelled`, so nobody else ends the mark.
    defer if (start.retain_in_flight) backend.store.end_start(session_id);
    var close_request: contracts.ActionRequest = .{ .close = .{
        .session_id = session_id,
        .policy = .force,
        .authority = .{
            .principal = persistence.grant.principal,
            .actor = persistence.grant.actor,
            .generation = persistence.grant.generation,
            .proof = persistence.proof,
        },
    } };
    operation.attachProcessOwner(&close_request, backend.process_owner);
    // The start's own flag is set, so the close gets a fresh one.
    const not_cancelled: std.atomic.Value(bool) = .init(false);
    var closed = execute(alloc, backend, close_request, &not_cancelled) catch |err| {
        debug_trace.logf(
            "terminal_client",
            "cancelled start close failed session={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return;
    };
    defer closed.deinit(alloc);
    switch (closed.view()) {
        .success => debug_trace.logf(
            "terminal_client",
            "cancelled start closed session={s}",
            .{session_id},
        ),
        .failure => |refused| debug_trace.logf(
            "terminal_client",
            "cancelled start close refused session={s} code={s}",
            .{ session_id, @tagName(refused.code) },
        ),
    }
}

/// Clears the cancelled actor's attention and lease on the session, so a
/// cancelled request leaves no durable claim behind.
fn persistCancellation(backend: *Backend, request: contracts.ActionRequest) void {
    const claim = operation.claim(request) orelse return;
    const session_id = operation.authoritySessionId(request) orelse return;
    backend.registry.cancelAuthorized(session_id, claim) catch |err| {
        debug_trace.logf(
            "terminal_client",
            "cancellation persistence failed session={s} err={s}",
            .{ session_id, @errorName(err) },
        );
    };
}

fn finishUnstarted(
    runtime: *Runtime,
    alloc: Allocator,
    intent_value: Intent,
) void {
    var intent = intent_value;
    const correlation_id = intent.correlation_id;
    intent.deinit(alloc);
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    defer runtime.mutex.unlock(zio);
    runtime.completions.push(.{
        .kind = .disconnected,
        .correlation_id = correlation_id,
    });
}

fn takeIntent(runtime: *Runtime) ?Intent {
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    defer runtime.mutex.unlock(zio);
    while (runtime.queue.len == 0 and !runtime.stopping) {
        runtime.wake.waitUncancelable(zio, &runtime.mutex);
    }
    if (runtime.stopping) return null;
    return runtime.queue.take();
}

var file_descriptor_budget_checked: std.atomic.Value(bool) = .init(false);

/// Raises the soft descriptor limit once per process, before the first
/// terminal start, so the PTY and pipe descriptors of a full session budget
/// fit under limits as low as 256.
fn ensureFileDescriptorBudget() void {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return;
    if (file_descriptor_budget_checked.swap(true, .acq_rel)) return;
    var limits = std.posix.getrlimit(.NOFILE) catch |err| {
        debug_trace.logf(
            "terminal_client",
            "file descriptor limit unavailable err={s}",
            .{@errorName(err)},
        );
        return;
    };
    const target = fileDescriptorLimitTarget(
        @intCast(limits.cur),
        @intCast(limits.max),
    ) orelse return;
    limits.cur = @intCast(target);
    std.posix.setrlimit(.NOFILE, limits) catch |err| {
        debug_trace.logf(
            "terminal_client",
            "file descriptor limit unchanged target={d} err={s}",
            .{ target, @errorName(err) },
        );
        return;
    };
    debug_trace.logf(
        "terminal_client",
        "file descriptor limit raised soft={d}",
        .{target},
    );
}

fn fileDescriptorLimitTarget(current: u64, maximum: u64) ?u64 {
    const target = @min(maximum, desired_file_descriptor_limit);
    return if (current < target) target else null;
}

fn testIntent(alloc: Allocator, correlation_id: u64) !Intent {
    return .{
        .correlation_id = .{ .value = correlation_id },
        .request = try contracts.OwnedActionRequest.init(
            alloc,
            .{ .screen = .{ .session_id = "terminal-1" } },
        ),
    };
}

fn admitTestIntent(runtime: *Runtime, correlation_id: u64) !void {
    var intent = try testIntent(std.testing.allocator, correlation_id);
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    defer runtime.mutex.unlock(zio);
    runtime.admitIntentLocked(intent) catch |err| {
        intent.deinit(std.testing.allocator);
        return err;
    };
}

fn checkIntentAllocationFailures(alloc: Allocator) !void {
    var runtime: Runtime = .{};
    var intent = try testIntent(alloc, 1);
    runtime.admitIntentLocked(intent) catch |err| {
        intent.deinit(alloc);
        return err;
    };
    var rollback = runtime.rollbackAdmissionLocked(intent.correlation_id);
    rollback.deinit(alloc);
}

test "owned admission survives allocation failure and rollback has one owner" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkIntentAllocationFailures,
        .{},
    );

    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();
    var intent = try testIntent(std.testing.allocator, 41);
    runtime.admitIntentLocked(intent) catch |err| {
        intent.deinit(std.testing.allocator);
        return err;
    };
    var rollback = runtime.rollbackAdmissionLocked(intent.correlation_id);
    rollback.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), runtime.queue.len);
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 41 }));
}

test "client queue owns admitted requests and reports full without I/O" {
    var queue: Queue = .{};
    defer {
        while (queue.take()) |intent_value| {
            var intent = intent_value;
            intent.deinit(std.testing.allocator);
        }
    }
    var next_id: u64 = 1;
    while (next_id <= queue_capacity) : (next_id += 1) {
        try queue.admit(try testIntent(std.testing.allocator, next_id), false);
    }
    var overflow = try testIntent(std.testing.allocator, next_id);
    defer overflow.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.QueueFull,
        queue.admit(overflow, false),
    );
    try std.testing.expectError(
        error.RuntimeStopping,
        queue.admit(overflow, true),
    );
}

test "intent queue stays FIFO after dequeue and refill" {
    var queue: Queue = .{};
    defer {
        while (queue.take()) |intent_value| {
            var intent = intent_value;
            intent.deinit(std.testing.allocator);
        }
    }
    for (1..4) |id| {
        try queue.admit(try testIntent(std.testing.allocator, id), false);
    }
    var first = queue.take().?;
    try std.testing.expectEqual(@as(u64, 1), first.correlation_id.value);
    first.deinit(std.testing.allocator);
    try queue.admit(try testIntent(std.testing.allocator, 4), false);
    for ([_]u64{ 2, 3, 4 }) |expected| {
        var intent = queue.take().?;
        defer intent.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected, intent.correlation_id.value);
    }
}

test "targeted cancellation releases only its pending request" {
    var pending: PendingRequests = .{};
    const first = contracts.CorrelationId{ .value = 1 };
    const second = contracts.CorrelationId{ .value = 2 };
    try pending.add(first);
    try pending.add(second);
    try std.testing.expectError(error.DuplicateCorrelation, pending.add(first));
    try std.testing.expect(pending.remove(first));
    try std.testing.expect(!pending.contains(first));
    try std.testing.expect(pending.contains(second));
    try std.testing.expect(!pending.remove(.{ .value = 99 }));
    try std.testing.expect(pending.remove(second));
}

test "runtime correlation stays reserved until its completion is taken" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();
    try admitTestIntent(&runtime, 23);
    try std.testing.expectError(
        error.DuplicateCorrelation,
        admitTestIntent(&runtime, 23),
    );

    // Finishing frees the worker and its intent; the testing allocator
    // reports a leak or a double free if it doesn't free them exactly once.
    const worker = try std.testing.allocator.create(RequestWorker);
    worker.* = .{
        .runtime = &runtime,
        .intent = takeIntent(&runtime).?,
    };
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    worker.slot = runtime.registerWorkerLocked(worker).?;
    runtime.mutex.unlock(zio);
    try std.testing.expectError(
        error.DuplicateCorrelation,
        admitTestIntent(&runtime, 23),
    );

    const correlation_id = worker.intent.correlation_id;
    runtime.finishActive(worker, .{
        .kind = .cancelled,
        .correlation_id = correlation_id,
    });
    try std.testing.expect(runtime.live_correlations.contains(correlation_id));
    var completion = runtime.takeCompletion().?;
    completion.deinit();
    try std.testing.expect(!runtime.live_correlations.contains(correlation_id));
    try admitTestIntent(&runtime, 23);
}

test "runtime queued cancellation releases only the target correlation" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();
    try admitTestIntent(&runtime, 1);
    try admitTestIntent(&runtime, 2);
    try admitTestIntent(&runtime, 3);

    try std.testing.expect(runtime.cancel(.{ .value = 2 }));
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 1 }));
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 2 }));
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 3 }));
    var completion = runtime.takeCompletion().?;
    try std.testing.expectEqual(CompletionKind.cancelled, completion.kind);
    try std.testing.expectEqual(
        @as(u64, 2),
        completion.correlation_id.?.value,
    );
    completion.deinit();
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 2 }));
    try admitTestIntent(&runtime, 2);
}

test "runtime deinit owns queued and retained correlations" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    try admitTestIntent(&runtime, 1);
    try admitTestIntent(&runtime, 2);
    var completed = runtime.queue.take().?;
    completed.deinit(std.testing.allocator);
    runtime.completions.push(.{
        .kind = .disconnected,
        .correlation_id = .{ .value = 1 },
    });

    runtime.deinit();
    try std.testing.expect(runtime.alloc == null);
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.backend == null);
    try std.testing.expect(!runtime.stopping);
    try std.testing.expect(!runtime.stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.queue.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.correlated_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.active_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.projection.rows.items.len);
    for (runtime.queue.values) |entry| try std.testing.expect(entry == null);
    for (runtime.completions.values) |entry| try std.testing.expect(entry == null);
    for (runtime.live_correlations.values) |entry| try std.testing.expect(entry == null);
    for (runtime.active) |entry| try std.testing.expect(entry == null);

    try std.testing.expectEqual(@as(u64, 1), runtime.nextCorrelationId().value);
    runtime.deinit();
    try std.testing.expectEqual(@as(u64, 1), runtime.nextCorrelationId().value);
}

test "lazy runtime opens no store registry or worker before first admission" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try std.testing.expect(runtime.alloc == null);
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.backend == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.queue.len);
    // Ending terminals before any request opened a backend does no I/O, and
    // the runtime then refuses to open one.
    runtime.closeOwnedTerminals();
    try std.testing.expect(runtime.backend_closed);
    try std.testing.expect(runtime.backend == null);
}

test "terminal file descriptor target is bounded by the hard limit" {
    try std.testing.expectEqual(
        @as(?u64, desired_file_descriptor_limit),
        fileDescriptorLimitTarget(256, std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(
        @as(?u64, 512),
        fileDescriptorLimitTarget(256, 512),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        fileDescriptorLimitTarget(desired_file_descriptor_limit, 4096),
    );
}

test "ordered mutations run in ticket order" {
    var ordered: OrderedMutations = .{};
    const first = ordered.issue();
    const second = ordered.issue();
    try std.testing.expectEqual(@as(u64, 0), first);
    try std.testing.expectEqual(@as(u64, 1), second);
    ordered.wait(first);
    ordered.complete(first);
    ordered.wait(second);
    ordered.complete(second);
    try std.testing.expectEqual(@as(u64, 2), ordered.serving_ticket);
}

/// Drives one real terminal through the in-process runtime. The launcher is
/// the installed fx binary that `zig build test` provides.
const LiveTerminalFixture = struct {
    const owner_session_id = "terminal-client-owner";
    const action_executor = @import("action_executor.zig");

    tmp: std.testing.TmpDir,
    home: []u8,
    runtime: Runtime,
    persistence: ?operation.PreparedAuthority = null,

    fn init(fixture: *LiveTerminalFixture) !void {
        const host_capabilities = @import("../hosts/host.zig");
        if (comptime !host_capabilities.terminalSupportForOs(builtin.target.os.tag).isSupported()) {
            return error.SkipZigTest;
        }
        const alloc = std.testing.allocator;
        fixture.tmp = std.testing.tmpDir(.{});
        errdefer fixture.tmp.cleanup();
        fixture.home = try io_mod.dirRealpathAlloc(alloc, fixture.tmp.dir, ".");
        errdefer alloc.free(fixture.home);
        var root = io_mod.VerifiedDir{ .dir = try fixture.tmp.dir.openDir(
            std.testing.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) };
        defer root.close();
        var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&root, ".fx");
        defer fx_dir.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, "sessions");
        defer sessions.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&sessions, owner_session_id);
        owner.close();
        fixture.runtime = Runtime.init(
            @import("../../tools/shell/process_provider.zig").provider,
        );
        fixture.runtime.profile_home = fixture.home;
        fixture.persistence = null;
    }

    fn deinit(fixture: *LiveTerminalFixture) void {
        // Under load a backend can drain after the exit budget, and the
        // runtime then keeps it allocated on purpose. The test process lives
        // on, so wait for it here and free it.
        fixture.runtime.closeOwnedTerminals();
        fixture.runtime.joinExitDrainForTest(10_000);
        fixture.runtime.deinit();
        if (fixture.persistence) |*persistence| persistence.deinit();
        std.testing.allocator.free(fixture.home);
        fixture.tmp.cleanup();
    }

    fn run(
        fixture: *LiveTerminalFixture,
        request: contracts.ActionRequest,
    ) !contracts.OwnedResult {
        return action_executor.execute(.{
            .alloc = std.testing.allocator,
            .lifecycle_allocator = std.testing.allocator,
            .runtime = &fixture.runtime,
        }, request);
    }

    /// Starts `command` in a clean bash and returns its owned session id.
    fn start(fixture: *LiveTerminalFixture, command: []const u8) ![]u8 {
        return fixture.startInShell("/bin/bash", command);
    }

    /// Starts `command` in a clean `shell_path` and returns its owned session id.
    fn startInShell(
        fixture: *LiveTerminalFixture,
        shell_path: []const u8,
        command: []const u8,
    ) ![]u8 {
        const alloc = std.testing.allocator;
        try fixture.preparePersistence();
        var started = try fixture.run(.{ .start = .{
            .cwd = fixture.home,
            .command = command,
            .shell = .{ .executable = .{ .path = shell_path, .clean_start = true } },
            .backend = .native,
            .return_when = .started,
            .wait_ceiling_ms = 15_000,
            .persistence = fixture.persistence.?.view(),
        } });
        defer started.deinit(alloc);
        const value = switch (started.view()) {
            .success => |success| switch (success) {
                .start => |start_value| start_value,
                else => return error.TestUnexpectedResult,
            },
            .failure => return error.TestTerminalStartFailed,
        };
        try std.testing.expectEqual(contracts.Lifecycle.running, value.session.lifecycle);
        return alloc.dupe(u8, value.session.session_id);
    }

    fn preparePersistence(fixture: *LiveTerminalFixture) !void {
        if (fixture.persistence) |*previous| previous.deinit();
        fixture.persistence = null;
        fixture.persistence = try operation.prepareStartPersistence(std.testing.allocator, .{
            .profile_user = "terminal-client-user",
            .durable_session_id = owner_session_id,
            .workspace_root = fixture.home,
            .cwd = fixture.home,
            .transport_role = .interactive,
            .backend = .native,
            .actor = .agent,
            .controls = .full(),
            .lifetime = .session,
        });
    }

    /// Waits for the single terminal record a start writes and returns its
    /// owned session id, for starts whose result the test never sees.
    fn waitForOnlyRecordedSession(
        fixture: *LiveTerminalFixture,
        timeout_ms: i64,
    ) ![]u8 {
        const state_path = ".fx/sessions/" ++ owner_session_id ++ "/terminal/state";
        const deadline = io_mod.milliTimestamp() + timeout_ms;
        while (io_mod.milliTimestamp() < deadline) : (io_mod.sleep(10 * std.time.ns_per_ms)) {
            var dir = fixture.tmp.dir.openDir(
                std.testing.io,
                state_path,
                .{ .iterate = true },
            ) catch continue;
            defer dir.close(std.testing.io);
            var it = dir.iterate();
            while (try it.next(std.testing.io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.startsWith(u8, entry.name, "record-")) continue;
                if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
                const session_id = entry.name["record-".len .. entry.name.len - ".json".len];
                return std.testing.allocator.dupe(u8, session_id);
            }
        }
        return error.TestMissingTerminalRecord;
    }

    fn awaitCompletion(
        fixture: *LiveTerminalFixture,
        correlation_id: contracts.CorrelationId,
        timeout_ms: i64,
    ) !Completion {
        const deadline = io_mod.milliTimestamp() + timeout_ms;
        while (io_mod.milliTimestamp() < deadline) {
            if (fixture.runtime.takeCompletionFor(correlation_id)) |completion| {
                return completion;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
        return error.TestCompletionTimedOut;
    }

    fn claim(fixture: *const LiveTerminalFixture) contracts.AuthorityClaim {
        const persistence = fixture.persistence.?.view();
        return .{
            .principal = persistence.grant.principal,
            .actor = persistence.grant.actor,
            .generation = persistence.grant.generation,
            .proof = persistence.proof,
        };
    }

    fn waitForExit(
        fixture: *LiveTerminalFixture,
        session_id: []const u8,
    ) !contracts.ReturnOutcome {
        var waited = try fixture.run(.{ .wait = .{
            .session_id = session_id,
            .return_when = .exit,
            .safety_ceiling_ms = 15_000,
            .authority = fixture.claim(),
        } });
        defer waited.deinit(std.testing.allocator);
        return switch (waited.view()) {
            .success => |success| switch (success) {
                .wait => |value| value.outcome,
                else => error.TestUnexpectedResult,
            },
            .failure => error.TestUnexpectedResult,
        };
    }

    /// Waits until the terminal output contains `pattern`.
    fn waitForMatch(
        fixture: *LiveTerminalFixture,
        session_id: []const u8,
        pattern: []const u8,
    ) !void {
        var waited = try fixture.run(.{ .wait = .{
            .session_id = session_id,
            .return_when = .{ .match = pattern },
            .safety_ceiling_ms = 15_000,
            .authority = fixture.claim(),
        } });
        defer waited.deinit(std.testing.allocator);
        const outcome = switch (waited.view()) {
            .success => |success| switch (success) {
                .wait => |value| value.outcome,
                else => return error.TestUnexpectedResult,
            },
            .failure => return error.TestUnexpectedResult,
        };
        if (outcome != .condition_met) return error.TestUnexpectedResult;
    }

    fn write(
        fixture: *LiveTerminalFixture,
        session_id: []const u8,
        lease: contracts.WriteLeaseIntent,
        payload: ?contracts.WritePayload,
    ) !void {
        var written = try fixture.run(.{ .write = .{
            .session_id = session_id,
            .payload = payload,
            .lease = lease,
            .authority = fixture.claim(),
        } });
        defer written.deinit(std.testing.allocator);
        if (written.view() != .success) return error.TestTerminalWriteFailed;
    }

    /// The pid recorded for a terminal's shell, read from its durable record.
    fn shellPid(fixture: *LiveTerminalFixture, session_id: []const u8) !std.posix.pid_t {
        const alloc = std.testing.allocator;
        const name = try alloc.print("record-{s}.json", .{session_id});
        defer alloc.free(name);
        const path = try std.Io.Dir.path.join(alloc, &.{
            ".fx", "sessions", owner_session_id, "terminal", "state", name,
        });
        defer alloc.free(path);
        const bytes = try fixture.tmp.dir.readFileAlloc(
            std.testing.io,
            path,
            alloc,
            .limited(1024 * 1024),
        );
        defer alloc.free(bytes);
        const Record = struct { pid: ?[]const u8 = null, lifecycle: contracts.Lifecycle };
        const parsed = try json_decode.parseFromSlice(Record, alloc, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return std.fmt.parseInt(std.posix.pid_t, parsed.value.pid orelse
            return error.TestMissingPid, 10);
    }

    fn recordedLifecycle(
        fixture: *LiveTerminalFixture,
        session_id: []const u8,
    ) !contracts.Lifecycle {
        const alloc = std.testing.allocator;
        const name = try alloc.print("record-{s}.json", .{session_id});
        defer alloc.free(name);
        const path = try std.Io.Dir.path.join(alloc, &.{
            ".fx", "sessions", owner_session_id, "terminal", "state", name,
        });
        defer alloc.free(path);
        const bytes = try fixture.tmp.dir.readFileAlloc(
            std.testing.io,
            path,
            alloc,
            .limited(1024 * 1024),
        );
        defer alloc.free(bytes);
        const Record = struct { lifecycle: contracts.Lifecycle };
        const parsed = try json_decode.parseFromSlice(Record, alloc, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return parsed.value.lifecycle;
    }
};

fn processGone(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| return err == error.ProcessNotFound;
    return false;
}

fn processGoneWithin(pid: std.posix.pid_t, timeout_ms: i64) bool {
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    while (io_mod.milliTimestamp() < deadline) {
        if (processGone(pid)) return true;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return processGone(pid);
}

/// A named pipe that a terminal's command writes one byte to when it starts,
/// so a test can wait on the command itself. The test holds both ends open:
/// the command's open never blocks, and a hang-up cannot pass for the byte on
/// either OS.
const LaunchSignal = struct {
    const fifo_c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };

    /// The pipe's name in its folder. The command runs in that folder, so it
    /// names the pipe relative to its working directory, and no path, which
    /// may hold any character, goes into a shell command.
    const name = "launched";

    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,

    fn init(signal: *LaunchSignal, dir: []const u8) !void {
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        const fifo = try std.mem.printSentinel(&path_buf, "{s}/" ++ name, .{dir}, 0);
        if (fifo_c.mkfifo(fifo, 0o600) != 0) return error.TestLaunchSignalFailed;
        signal.read_fd = std.c.open(fifo, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (signal.read_fd < 0) return error.TestLaunchSignalFailed;
        errdefer _ = std.c.close(signal.read_fd);
        signal.write_fd = std.c.open(fifo, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
        if (signal.write_fd < 0) return error.TestLaunchSignalFailed;
    }

    fn deinit(signal: *LaunchSignal) void {
        _ = std.c.close(signal.write_fd);
        _ = std.c.close(signal.read_fd);
    }

    /// Blocks until the command's byte arrives, for at most `timeout_ms`.
    fn wait(signal: *LaunchSignal, timeout_ms: i32) !void {
        var fds = [_]std.posix.pollfd{.{ .fd = signal.read_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((try std.posix.poll(&fds, timeout_ms)) == 0) return error.TestLaunchSignalTimedOut;
        var byte: [1]u8 = undefined;
        if ((try std.posix.read(signal.read_fd, &byte)) != 1) return error.TestLaunchSignalFailed;
    }
};

test "in-process registry starts writes to and stops a real terminal" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    const session_id = try fixture.start(
        "printf 'READY\\n'; IFS= read -r line; printf 'GOT:%s\\n' \"$line\"",
    );
    defer alloc.free(session_id);
    try std.testing.expect(fixture.runtime.backend != null);

    try fixture.write(session_id, .acquire, null);
    try fixture.write(session_id, .use, .{ .text = "hello\n" });
    try fixture.write(session_id, .release, null);
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .exited = 0 },
        try fixture.waitForExit(session_id),
    );

    var read = try fixture.run(.{ .read = .{
        .session_id = session_id,
        .cursor = .{ .segment = 1, .offset = 0 },
        .authority = fixture.claim(),
    } });
    defer read.deinit(alloc);
    const output = switch (read.view()) {
        .success => |success| switch (success) {
            .read => |value| value.output,
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.find(u8, output, "GOT:hello") != null);

    // A second terminal is stopped by signal and close, as shell.stop does.
    // The marker proves the command is running, so the signal cannot land
    // inside the launcher's startup handshake.
    const sleeper = try fixture.start("printf 'SLEEP%s\\n' ING; sleep 30");
    defer alloc.free(sleeper);
    try fixture.waitForMatch(sleeper, "SLEEPING");
    const pid = try fixture.shellPid(sleeper);
    var signaled = try fixture.run(.{ .signal = .{
        .session_id = sleeper,
        .signal = .kill,
        .authority = fixture.claim(),
    } });
    defer signaled.deinit(alloc);
    try std.testing.expect(signaled.view() == .success);
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .signal = @intCast(@backingInt(std.c.SIG.KILL)) },
        try fixture.waitForExit(sleeper),
    );
    var closed = try fixture.run(.{ .close = .{
        .session_id = sleeper,
        .policy = .force,
        .authority = fixture.claim(),
    } });
    defer closed.deinit(alloc);
    try std.testing.expect(closed.view() == .success);
    try std.testing.expect(processGoneWithin(pid, 2_000));
    try std.testing.expectEqual(
        contracts.Lifecycle.closed,
        try fixture.recordedLifecycle(sleeper),
    );
}

test "cancelling a start after its terminal launched closes that terminal" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    // The record file appears before the session can be found, so waiting on
    // the session as soon as the record exists can miss it. The command's own
    // byte comes after the session is registered, launched and its pid is
    // recorded.
    var launched: LaunchSignal = undefined;
    try launched.init(fixture.home);
    defer launched.deinit();
    const command = "printf 'HELD%s\\n' START; printf x > ./" ++ LaunchSignal.name ++ "; sleep 30";

    try fixture.preparePersistence();
    const correlation_id = fixture.runtime.nextCorrelationId();
    // The start waits for an exit that never comes on its own, so the
    // cancel lands after the terminal launched and before the result.
    try fixture.runtime.admit(alloc, correlation_id, .{ .start = .{
        .cwd = fixture.home,
        .command = command,
        .shell = .{ .executable = .{ .path = "/bin/bash", .clean_start = true } },
        .backend = .native,
        .return_when = .exit,
        .wait_ceiling_ms = 15_000,
        .persistence = fixture.persistence.?.view(),
    } });
    try launched.wait(15_000);
    const session_id = try fixture.waitForOnlyRecordedSession(15_000);
    defer alloc.free(session_id);
    try fixture.waitForMatch(session_id, "HELDSTART");
    const pid = try fixture.shellPid(session_id);

    try std.testing.expect(fixture.runtime.cancel(correlation_id));
    var completion = try fixture.awaitCompletion(correlation_id, 15_000);
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.cancelled, completion.kind);

    // The caller never learned the session id, so nothing else can end it.
    try std.testing.expect(processGoneWithin(pid, 2_000));
    try std.testing.expectEqual(
        contracts.Lifecycle.closed,
        try fixture.recordedLifecycle(session_id),
    );
}

/// The command of a terminal that stays idle until the fixture ends it. It
/// writes its byte to the launch signal once it runs, and `exec` leaves no
/// child behind.
const idle_signalling_command = "printf x > ./" ++ LaunchSignal.name ++ "; exec sleep 30";

/// A start request for a terminal that stays idle until the fixture ends it.
/// A test that ends with the fixture waits for the launch signal first, so
/// the exit close never comes while the shell is still starting, where it
/// waits out its whole grace.
fn idleStart(fixture: *LiveTerminalFixture, retain_in_flight: bool) contracts.ActionRequest {
    return .{ .start = .{
        .cwd = fixture.home,
        .command = idle_signalling_command,
        .shell = .{ .executable = .{ .path = "/bin/bash", .clean_start = true } },
        .backend = .native,
        .return_when = .started,
        .wait_ceiling_ms = 15_000,
        .persistence = fixture.persistence.?.view(),
        .retain_in_flight = retain_in_flight,
    } };
}

test "start in flight: a start keeps its mark for a caller that asks, until the caller ends it" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    var launched: LaunchSignal = undefined;
    try launched.init(fixture.home);
    defer launched.deinit();
    for ([_]bool{ false, true }) |retain| {
        try fixture.preparePersistence();
        var started = try fixture.run(idleStart(&fixture, retain));
        defer started.deinit(alloc);
        try launched.wait(15_000);
        const session_id = switch (started.view()) {
            .success => |success| switch (success) {
                .start => |value| value.session.session_id,
                else => return error.TestUnexpectedResult,
            },
            .failure => return error.TestTerminalStartFailed,
        };
        const store = &fixture.runtime.backend.?.store;
        // A caller that did not ask finds the id already visible.
        try std.testing.expectEqual(retain, store.is_starting(session_id));
        fixture.runtime.endStart(session_id);
        try std.testing.expect(!store.is_starting(session_id));
    }
}

test "start in flight: a cancelled start ends the mark it kept" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    var launched: LaunchSignal = undefined;
    try launched.init(fixture.home);
    defer launched.deinit();

    try fixture.preparePersistence();
    const correlation_id = fixture.runtime.nextCorrelationId();
    try fixture.runtime.admit(alloc, correlation_id, .{ .start = .{
        .cwd = fixture.home,
        .command = idle_signalling_command,
        .shell = .{ .executable = .{ .path = "/bin/bash", .clean_start = true } },
        .backend = .native,
        .return_when = .exit,
        .wait_ceiling_ms = 15_000,
        .persistence = fixture.persistence.?.view(),
        .retain_in_flight = true,
    } });
    try launched.wait(15_000);
    const session_id = try fixture.waitForOnlyRecordedSession(15_000);
    defer alloc.free(session_id);
    const store = &fixture.runtime.backend.?.store;
    try std.testing.expect(store.is_starting(session_id));

    try std.testing.expect(fixture.runtime.cancel(correlation_id));
    var completion = try fixture.awaitCompletion(correlation_id, 15_000);
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.cancelled, completion.kind);
    // The caller only learned `.cancelled`, so nobody else can end the mark.
    try std.testing.expect(!store.is_starting(session_id));
}

test "start in flight: a start result the executor cannot copy ends the mark it kept" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    var launched: LaunchSignal = undefined;
    try launched.init(fixture.home);
    defer launched.deinit();
    try fixture.preparePersistence();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, LiveTerminalFixture.action_executor.execute(.{
        .alloc = failing.allocator(),
        .lifecycle_allocator = alloc,
        .runtime = &fixture.runtime,
    }, idleStart(&fixture, true)));
    try launched.wait(15_000);
    const session_id = try fixture.waitForOnlyRecordedSession(15_000);
    defer alloc.free(session_id);
    try std.testing.expect(!fixture.runtime.backend.?.store.is_starting(session_id));
}

test "zsh terminal commands keep words that start with = literal" {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), "/bin/zsh", .{}) catch
        return error.SkipZigTest;
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    const session_id = try fixture.startInShell(
        "/bin/zsh",
        "echo before; echo ======; [ x == x ] && echo same; echo after",
    );
    defer alloc.free(session_id);
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .exited = 0 },
        try fixture.waitForExit(session_id),
    );

    var read = try fixture.run(.{ .read = .{
        .session_id = session_id,
        .cursor = .{ .segment = 1, .offset = 0 },
        .authority = fixture.claim(),
    } });
    defer read.deinit(alloc);
    const output = switch (read.view()) {
        .success => |success| switch (success) {
            .read => |value| value.output,
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.find(u8, output, "======") != null);
    try std.testing.expect(std.mem.find(u8, output, "same") != null);
    try std.testing.expect(std.mem.find(u8, output, "after") != null);
}

test "closing owned terminals for exit leaves no orphan and records them ended" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    const session_id = try fixture.start("sleep 30");
    defer alloc.free(session_id);
    const pid = try fixture.shellPid(session_id);
    try std.testing.expect(!processGone(pid));

    const started = io_mod.milliTimestamp();
    fixture.runtime.closeOwnedTerminals();
    // Hangup, grace and kill stay inside the exit budget.
    try std.testing.expect(io_mod.milliTimestamp() - started < 1_500);
    try std.testing.expect(processGoneWithin(pid, 1_000));
    try std.testing.expectEqual(
        contracts.Lifecycle.lost,
        try fixture.recordedLifecycle(session_id),
    );

    // Nothing starts after exit began.
    var refused = try fixture.run(.{ .screen = .{
        .session_id = session_id,
        .authority = fixture.claim(),
    } });
    defer refused.deinit(alloc);
    try std.testing.expect(refused.view() == .failure);
}

/// A named pipe the exit close writes one byte to, so a terminal's command can
/// wait for it with `read -r _ < ./go`. The test holds both ends open, as
/// `LaunchSignal` does, so the command's open never blocks.
const GoSignal = struct {
    const name = "go";

    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,

    fn init(signal: *GoSignal, dir: []const u8) !void {
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        const fifo = try std.mem.printSentinel(&path_buf, "{s}/" ++ name, .{dir}, 0);
        if (LaunchSignal.fifo_c.mkfifo(fifo, 0o600) != 0) return error.TestGoSignalFailed;
        signal.read_fd = std.c.open(fifo, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (signal.read_fd < 0) return error.TestGoSignalFailed;
        errdefer _ = std.c.close(signal.read_fd);
        signal.write_fd = std.c.open(fifo, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
        if (signal.write_fd < 0) return error.TestGoSignalFailed;
    }

    fn deinit(signal: *GoSignal) void {
        _ = std.c.close(signal.write_fd);
        _ = std.c.close(signal.read_fd);
    }

    fn send(signal: *GoSignal) !void {
        if (std.c.write(signal.write_fd, "x\n", 2) != 2) return error.TestGoSignalFailed;
    }
};

const real_process_provider = @import("../../tools/shell/process_provider.zig").provider;

/// A named pipe that a process holds open for writing. The test reads the end
/// of the pipe to learn that the process is gone: its files close when it
/// dies, so no wait on a clock or a process state is needed. A terminal's late
/// child holds it as its standard output and writes one byte when it starts.
const LifeSignal = struct {
    const late_child = "alive";
    const daemon = "daemon-alive";

    read_fd: std.posix.fd_t,

    fn init(signal: *LifeSignal, dir: []const u8, name: []const u8) !void {
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        const fifo = try std.mem.printSentinel(&path_buf, "{s}/{s}", .{ dir, name }, 0);
        if (LaunchSignal.fifo_c.mkfifo(fifo, 0o600) != 0) return error.TestLifeSignalFailed;
        signal.read_fd = std.c.open(fifo, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (signal.read_fd < 0) return error.TestLifeSignalFailed;
    }

    fn deinit(signal: *LifeSignal) void {
        _ = std.c.close(signal.read_fd);
    }

    /// Blocks until the child's byte arrives, for at most `timeout_ms`.
    fn waitStarted(signal: *LifeSignal, timeout_ms: i32) !void {
        var fds = [_]std.posix.pollfd{.{ .fd = signal.read_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((try std.posix.poll(&fds, timeout_ms)) == 0) return error.TestLifeSignalTimedOut;
        var byte: [1]u8 = undefined;
        if ((try std.posix.read(signal.read_fd, &byte)) != 1) return error.TestLifeSignalFailed;
    }

    /// Blocks until the process is gone, for at most `timeout_ms`.
    fn waitGone(signal: *LifeSignal, timeout_ms: i32) !void {
        if (!try readableOrAtEnd(signal.read_fd, timeout_ms)) return error.TestProcessStillRuns;
        var byte: [1]u8 = undefined;
        if ((try std.posix.read(signal.read_fd, &byte)) != 0) return error.TestLifeSignalFailed;
    }
};

/// Whether `fd`, the read end of a named pipe, holds data or has reached its
/// end within `timeout_ms`. On macOS only `select` says that the last writer
/// of a named pipe has gone; `poll` and `kqueue` stay silent.
fn readableOrAtEnd(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    if (comptime builtin.target.os.tag != .macos) {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        return (try std.posix.poll(&fds, timeout_ms)) != 0;
    }
    const system = struct {
        const FdSet = extern struct { bits: [32]u32 };
        extern "c" fn select(
            count: c_int,
            read_set: *FdSet,
            write_set: ?*FdSet,
            error_set: ?*FdSet,
            timeout: *std.c.timeval,
        ) c_int;
    };
    var read_set: system.FdSet = .{ .bits = @splat(0) };
    const index: usize = @intCast(@divFloor(fd, 32));
    read_set.bits[index] |= @as(u32, 1) << @intCast(@mod(fd, 32));
    var timeout: std.c.timeval = .{
        .sec = @divFloor(timeout_ms, 1000),
        .usec = @mod(timeout_ms, 1000) * 1000,
    };
    const ready = system.select(fd + 1, &read_set, null, null, &timeout);
    if (ready < 0) return error.TestSelectFailed;
    return ready > 0;
}

/// A process a test started, with the identity it had, so the test ends it by
/// pid only while it is still that process.
const TestProcess = struct {
    pid: std.posix.pid_t,
    token: ?process_identity.ProcessInstanceToken,

    fn init(pid: std.posix.pid_t) TestProcess {
        var buffer: [32]u8 = undefined;
        const text = std.mem.print(&buffer, "{d}", .{pid}) catch return .{ .pid = pid, .token = null };
        return .{
            .pid = pid,
            .token = real_process_provider.captureToken(
                std.testing.allocator,
                text,
            ) catch null,
        };
    }

    fn isSame(process: TestProcess) bool {
        var buffer: [32]u8 = undefined;
        const text = std.mem.print(&buffer, "{d}", .{process.pid}) catch return false;
        const token = process.token orelse return false;
        return real_process_provider.matchToken(
            std.testing.allocator,
            text,
            token,
        ) == .matched;
    }

    /// Whether it still runs. A zombie, which only waits to be reaped, does not.
    fn isRunning(process: TestProcess) bool {
        if (!process.isSame()) return false;
        return process_tree.processIsAlive(std.testing.allocator, process.pid) catch true;
    }

    fn end(process: TestProcess) void {
        if (!process.isRunning()) return;
        // Cleanup: it may have ended between the check and the signal.
        std.posix.kill(process.pid, std.posix.SIG.KILL) catch {};
    }
};

/// What the host does with a terminal's launcher, as `native_session.zig`
/// reports it. A test arms it before it starts the one terminal it watches.
const LauncherWatch = struct {
    var pid: std.atomic.Value(std.posix.pid_t) = .init(0);
    var kept: std.atomic.Value(usize) = .init(0);
    var collected: std.atomic.Value(usize) = .init(0);
    var kept_seen: std.Io.Event = .unset;
    var collected_seen: std.Io.Event = .unset;
    var decided: std.Io.Event = .unset;

    fn arm() void {
        pid.store(0, .release);
        kept.store(0, .release);
        collected.store(0, .release);
        kept_seen = .unset;
        collected_seen = .unset;
        decided = .unset;
        native_session.test_launcher_event = &observe;
    }

    fn disarm() void {
        native_session.test_launcher_event = null;
    }

    fn observe(
        event: native_session.LauncherEvent,
        _: []const u8,
        launcher_pid: std.posix.pid_t,
    ) void {
        const zio = io_mod.getIo();
        switch (event) {
            .started => pid.store(launcher_pid, .release),
            .kept => {
                _ = kept.fetchAdd(1, .acq_rel);
                kept_seen.set(zio);
                decided.set(zio);
            },
            .collected => {
                _ = collected.fetchAdd(1, .acq_rel);
                collected_seen.set(zio);
                decided.set(zio);
            },
        }
    }

    /// Blocks until `event` is set, for at most `timeout_ms`. A wait that ends
    /// early without the event is not a timeout: `Event.waitTimeout` reports a
    /// spurious wake-up as one.
    fn waitFor(event: *std.Io.Event, timeout_ms: i64) !void {
        const deadline = io_mod.milliTimestamp() + timeout_ms;
        while (!event.isSet()) {
            const left_ms = deadline - io_mod.milliTimestamp();
            if (left_ms <= 0) return error.TestLauncherEventTimedOut;
            event.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(left_ms),
            } }) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => return err,
            };
        }
    }
};

/// What a late-fork test holds while the exit close runs: the pipe that lets
/// the terminal's command go on once the close has recorded its process tree,
/// the pipes that command answers on once it has started its late child, and
/// the launcher that the close reported.
const ExitGate = struct {
    var go: ?*GoSignal = null;
    var forked: ?*LaunchSignal = null;
    var alive: ?*LifeSignal = null;
    var session_id: [128]u8 = undefined;
    var session_id_len: usize = 0;
    var failed = false;
    var launcher: ?TestProcess = null;
    /// Holds the close's last step until the host has decided what to do with
    /// the ended launcher, so that step cannot run first and hide whether the
    /// launcher was kept for it.
    var wait_for_launcher_decision = false;

    fn arm(
        go_signal: ?*GoSignal,
        forked_signal: ?*LaunchSignal,
        alive_signal: ?*LifeSignal,
        id: []const u8,
    ) void {
        go = go_signal;
        forked = forked_signal;
        alive = alive_signal;
        session_id_len = @min(id.len, session_id.len);
        @memcpy(session_id[0..session_id_len], id[0..session_id_len]);
        failed = false;
        launcher = null;
        wait_for_launcher_decision = false;
        native_session.test_after_exit_record = &afterRecord;
        native_session.test_before_exit_kill = &beforeKill;
    }

    fn disarm() void {
        native_session.test_after_exit_record = null;
        native_session.test_before_exit_kill = null;
        go = null;
        forked = null;
        alive = null;
    }

    fn afterRecord(id: []const u8, launcher_pid: ?std.posix.pid_t) void {
        if (!std.mem.eql(u8, id, session_id[0..session_id_len])) return;
        if (launcher_pid) |pid| launcher = TestProcess.init(pid);
        const go_signal = go orelse return;
        go_signal.send() catch {
            failed = true;
            return;
        };
        const forked_signal = forked orelse return;
        forked_signal.wait(15_000) catch {
            failed = true;
            return;
        };
        const alive_signal = alive orelse return;
        alive_signal.waitStarted(15_000) catch {
            failed = true;
        };
    }

    fn beforeKill(id: []const u8) void {
        if (!wait_for_launcher_decision) return;
        if (!std.mem.eql(u8, id, session_id[0..session_id_len])) return;
        LauncherWatch.waitFor(&LauncherWatch.decided, 15_000) catch {
            failed = true;
        };
    }

    fn endLauncher() void {
        if (launcher) |process| process.end();
    }
};

/// The late child starts after the exit close recorded the process tree, so
/// the record misses it: the command waits for `go`, starts the child in its
/// own process group with the `alive` pipe as its output, detaches it from the
/// shell's job table, and tells the close that it did. The child still holds
/// the terminal as its input and error output.
const late_fork_command = "read -r _ < ./" ++ GoSignal.name ++
    "; ( printf x; exec sleep 30 ) > ./" ++ LifeSignal.late_child ++
    " & echo $! > ./late.pid; disown; printf x > ./" ++ LaunchSignal.name ++
    "; exec sleep 60";
const launched_byte = "printf x > ./" ++ LaunchSignal.name ++ "; ";

fn readPid(fixture: *LiveTerminalFixture, name: []const u8) !std.posix.pid_t {
    const bytes = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        name,
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \n"), 10);
}

test "closing owned terminals for exit ends a child the shell started after the process tree was recorded" {
    try expectExitEndsLateChild(.drains_first);
}

test "closing owned terminals for exit ends a late child when the terminal's output ended first" {
    try expectExitEndsLateChild(.ends_first);
}

/// Where the terminal's output ends relative to the late child. macOS ends it
/// when the shell exits, while the late child still holds the PTY, and Linux
/// only when the PTY has no holder left. `ends_first` has Linux do what macOS
/// does.
const OutputEnds = enum { drains_first, ends_first };

fn expectExitEndsLateChild(output: OutputEnds) !void {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    native_session.test_end_before_drain = output == .ends_first;
    defer native_session.test_end_before_drain = false;
    LauncherWatch.arm();
    defer LauncherWatch.disarm();

    var go: GoSignal = undefined;
    try go.init(fixture.home);
    defer go.deinit();
    var forked: LaunchSignal = undefined;
    try forked.init(fixture.home);
    defer forked.deinit();
    var alive: LifeSignal = undefined;
    try alive.init(fixture.home, LifeSignal.late_child);
    defer alive.deinit();

    const session_id = try fixture.start(late_fork_command);
    defer alloc.free(session_id);
    ExitGate.arm(&go, &forked, &alive, session_id);
    defer ExitGate.disarm();
    ExitGate.wait_for_launcher_decision = output == .ends_first;

    fixture.runtime.closeOwnedTerminals();
    // The hook ran after the shell's tree was recorded and waited for the child.
    if (ExitGate.failed) return error.TestExitGateFailed;
    const late = TestProcess.init(try readPid(&fixture, "late.pid"));
    // Past the failed assertions, so the test never leaves its child behind.
    defer late.end();
    if (!fixture.runtime.backend_drained) return error.TestBackendNotDrained;
    try alive.waitGone(2_000);
    // The host collected the launcher once, after the close ended its session.
    try std.testing.expectEqual(@as(usize, 1), LauncherWatch.collected.load(.acquire));
    if (process_tree.exitedChildIsUncollected(LauncherWatch.pid.load(.acquire))) {
        return error.TestLauncherNotCollected;
    }
}

test "a launcher is collected as soon as its terminal ends with nothing left in its session" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    LauncherWatch.arm();
    defer LauncherWatch.disarm();
    var go: GoSignal = undefined;
    try go.init(fixture.home);
    defer go.deinit();
    const session_id = try fixture.start("read -r _ < ./" ++ GoSignal.name ++ "; exit 3");
    defer alloc.free(session_id);

    try go.send();
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .exited = 3 },
        try fixture.waitForExit(session_id),
    );
    try LauncherWatch.waitFor(&LauncherWatch.collected_seen, 15_000);
    try std.testing.expect(!process_tree.exitedChildIsUncollected(LauncherWatch.pid.load(.acquire)));
    try std.testing.expectEqual(@as(usize, 0), LauncherWatch.kept.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), LauncherWatch.collected.load(.acquire));
}

test "closing a terminal collects the launcher that was kept for its session" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    // The terminal's output ends before its last process does, as on macOS.
    native_session.test_end_before_drain = true;
    defer native_session.test_end_before_drain = false;
    LauncherWatch.arm();
    defer LauncherWatch.disarm();
    var go: GoSignal = undefined;
    try go.init(fixture.home);
    defer go.deinit();
    var launched: LaunchSignal = undefined;
    try launched.init(fixture.home);
    defer launched.deinit();
    // A process the shell started stays in its session after the shell ends.
    const session_id = try fixture.start("sleep 30 & echo $! > ./late.pid; disown; printf x > ./" ++
        LaunchSignal.name ++ "; read -r _ < ./" ++ GoSignal.name ++ "; exit 0");
    defer alloc.free(session_id);
    try launched.wait(15_000);
    const late = TestProcess.init(try readPid(&fixture, "late.pid"));
    defer late.end();

    try go.send();
    try LauncherWatch.waitFor(&LauncherWatch.kept_seen, 15_000);
    const launcher_pid = LauncherWatch.pid.load(.acquire);
    try std.testing.expect(process_tree.exitedChildIsUncollected(launcher_pid));
    try std.testing.expectEqual(@as(usize, 0), LauncherWatch.collected.load(.acquire));

    // The last process of the session ends, and closing the terminal collects the launcher.
    late.end();
    var closed = try fixture.run(.{ .close = .{
        .session_id = session_id,
        .policy = .force,
        .authority = fixture.claim(),
    } });
    defer closed.deinit(alloc);
    try std.testing.expect(closed.view() == .success);
    try std.testing.expectEqual(@as(usize, 1), LauncherWatch.collected.load(.acquire));
    try std.testing.expect(!process_tree.exitedChildIsUncollected(launcher_pid));
}

test "closing owned terminals for exit ends a launcher that still waits to release its command" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    // The shell has told the launcher that its command starts, and the host
    // never releases it. The hangup ends the shell, and the launcher waits
    // for a release that cannot come until it closes the PTY, which the
    // backend waits for.
    native_session.test_hold_release = true;
    defer native_session.test_hold_release = false;
    const session_id = try fixture.start("sleep 30");
    defer alloc.free(session_id);
    ExitGate.arm(null, null, null, session_id);
    defer ExitGate.disarm();
    defer ExitGate.endLauncher();

    fixture.runtime.closeOwnedTerminals();
    try std.testing.expect(ExitGate.launcher != null);
    try std.testing.expect(fixture.runtime.backend_drained);
}

test "a terminal whose shell ends while its release is held reports how it ended" {
    try expectEndsWhileReleaseIsHeld(.shell_only);
}

test "a terminal whose shell and helper both end while its release is held reports how it ended" {
    try expectEndsWhileReleaseIsHeld(.whole_group);
}

const EndedProcesses = enum { shell_only, whole_group };

/// The shell has told the launcher that its command starts, and the host
/// never releases it. The shell ends (the whole group, as a hangup of the
/// terminal ends it, takes the helper that told the launcher with it), and
/// the launcher must report that end, not a failed start.
fn expectEndsWhileReleaseIsHeld(ended: EndedProcesses) !void {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    native_session.test_hold_release = true;
    defer native_session.test_hold_release = false;
    const session_id = try fixture.start("sleep 30");
    defer alloc.free(session_id);
    const shell = TestProcess.init(try fixture.shellPid(session_id));
    defer shell.end();

    // The shell leads its own process group, so its pid names the group.
    const target = switch (ended) {
        .shell_only => shell.pid,
        .whole_group => -shell.pid,
    };
    try std.posix.kill(target, std.posix.SIG.KILL);
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .signal = @intCast(@backingInt(std.posix.SIG.KILL)) },
        try fixture.waitForExit(session_id),
    );
}

test "closing owned terminals for exit leaves a setsid program and another runtime's terminal running" {
    var fixture: LiveTerminalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;

    // A terminal of another runtime, as a second fx process owns its own.
    var sibling: LiveTerminalFixture = undefined;
    try sibling.init();
    defer sibling.deinit();
    const sibling_id = try sibling.start("printf 'UP%s\\n' NOW; exec sleep 30");
    defer alloc.free(sibling_id);
    try sibling.waitForMatch(sibling_id, "UPNOW");
    const sibling_shell = TestProcess.init(try sibling.shellPid(sibling_id));
    defer sibling_shell.end();

    // The daemon leaves the terminal's session before the late child starts,
    // and closes its terminal files, so only the late child holds the PTY.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "daemon.py", .data =
        \\import os, signal, sys
        \\ready_r, ready_w = os.pipe()
        \\if os.fork() == 0:
        \\    os.setsid()
        \\    null = os.open(os.devnull, os.O_RDWR)
        \\    for fd in (0, 1, 2):
        \\        os.dup2(null, fd)
        \\    life = os.open(sys.argv[1], os.O_WRONLY)
        \\    open("daemon.pid", "w").write(str(os.getpid()))
        \\    os.write(ready_w, b"x")
        \\    signal.alarm(30); signal.pause()
        \\    os._exit(0)
        \\os.read(ready_r, 1)
    });
    var go: GoSignal = undefined;
    try go.init(fixture.home);
    defer go.deinit();
    var forked: LaunchSignal = undefined;
    try forked.init(fixture.home);
    defer forked.deinit();
    var alive: LifeSignal = undefined;
    try alive.init(fixture.home, LifeSignal.late_child);
    defer alive.deinit();
    var daemon_life: LifeSignal = undefined;
    try daemon_life.init(fixture.home, LifeSignal.daemon);
    defer daemon_life.deinit();
    const session_id = try fixture.start("python3 ./daemon.py " ++ LifeSignal.daemon ++ "; " ++ launched_byte ++ late_fork_command);
    defer alloc.free(session_id);
    // The first byte says the daemon has left, and the second the late child has started.
    try forked.wait(15_000);
    const daemon = TestProcess.init(try readPid(&fixture, "daemon.pid"));
    defer daemon.end();
    ExitGate.arm(&go, &forked, &alive, session_id);
    defer ExitGate.disarm();

    fixture.runtime.closeOwnedTerminals();
    try std.testing.expect(!ExitGate.failed);
    const late = TestProcess.init(try readPid(&fixture, "late.pid"));
    defer late.end();
    try std.testing.expect(fixture.runtime.backend_drained);
    try alive.waitGone(2_000);
    try std.testing.expect(daemon.isRunning());
    try std.testing.expect(sibling_shell.isRunning());
    // The test leaves nothing running: the daemon is gone when it returns.
    daemon.end();
    try daemon_life.waitGone(5_000);
}

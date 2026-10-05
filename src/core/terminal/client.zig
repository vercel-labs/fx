//! In-process owner of the `tty=true` terminals one fx process starts.
//!
//! Requests are admitted without I/O, then run on worker threads against a
//! native session registry and durable profile store that are created on the
//! first request. Terminals belong to this process instance: exit paths call
//! `closeOwnedTerminals` (or `deinit`), which ends every one of them with no
//! prompt, and a crash leaves them to the kernel PTY hangup and the launcher's
//! stdin watchdog. Nothing here outlives the process.

const std = @import("std");
const builtin = @import("builtin");
const host_target = @import("../hosts/target.zig");
const contracts = @import("contracts.zig");
const operation = @import("operation.zig");
const native_session = @import("native_session.zig");
const terminal_store = @import("store.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
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
        const home = self.profile_home orelse io_mod.getenv("HOME") orelse
            return error.HomeNotSet;

        const pid = std.c.getpid();
        var pid_buffer: [32]u8 = undefined;
        const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
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
            worker.intent.deinit(alloc);
            alloc.destroy(worker);
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
        const alloc = self.runtime.alloc.?;
        const completion = self.complete(alloc);
        self.runtime.finishActive(self, completion);
        self.intent.deinit(alloc);
        alloc.destroy(self);
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
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return;
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
        std.testing.allocator,
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

    var worker = RequestWorker{
        .runtime = &runtime,
        .intent = takeIntent(&runtime).?,
    };
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    worker.slot = runtime.registerWorkerLocked(&worker).?;
    runtime.mutex.unlock(zio);
    try std.testing.expectError(
        error.DuplicateCorrelation,
        admitTestIntent(&runtime, 23),
    );

    const correlation_id = worker.intent.correlation_id;
    runtime.finishActive(&worker, .{
        .kind = .cancelled,
        .correlation_id = correlation_id,
    });
    worker.intent.deinit(std.testing.allocator);
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
/// the installed fx binary that `zig build test` names in FX_TEST_PRODUCT_EXE.
const LiveTerminalFixture = struct {
    const owner_session_id = "terminal-client-owner";
    const action_executor = @import("action_executor.zig");

    tmp: std.testing.TmpDir,
    home: []u8,
    runtime: Runtime,
    persistence: ?operation.PreparedAuthority = null,

    fn init(fixture: *LiveTerminalFixture) !void {
        const host_capabilities = @import("../hosts/host.zig");
        if (comptime !host_capabilities.terminalSupportForOs(builtin.os.tag).isSupported()) {
            return error.SkipZigTest;
        }
        if (std.c.getenv("FX_TEST_PRODUCT_EXE") == null) return error.SkipZigTest;
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
        const alloc = std.testing.allocator;
        if (fixture.persistence) |*previous| previous.deinit();
        fixture.persistence = try operation.prepareStartPersistence(alloc, .{
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
        var started = try fixture.run(.{ .start = .{
            .cwd = fixture.home,
            .command = command,
            .shell = .{ .executable = .{ .path = "/bin/bash", .clean_start = true } },
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
        const name = try std.fmt.allocPrint(alloc, "record-{s}.json", .{session_id});
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{
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
        const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{
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
        const name = try std.fmt.allocPrint(alloc, "record-{s}.json", .{session_id});
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{
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
        const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return parsed.value.lifecycle;
    }
};

fn processGone(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err == error.ProcessNotFound;
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
        contracts.ReturnOutcome{ .signal = @intCast(@intFromEnum(std.c.SIG.KILL)) },
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

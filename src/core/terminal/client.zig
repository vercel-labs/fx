const std = @import("std");
const builtin = @import("builtin");
const host_target = @import("../hosts/target.zig");
const contracts = @import("contracts.zig");
const protocol = @import("protocol.zig");
const host = @import("host.zig");
const policy = @import("host_policy.zig");
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
const ui_projection = @import("ui_projection.zig");

const Allocator = std.mem.Allocator;
const connect_deadline_ms: i64 = 2_000;
const handshake_deadline_ms: i64 = 5_000;
const max_active_requests: usize = 32;
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
    disconnected,
    unavailable,
};

pub const Completion = struct {
    kind: CompletionKind,
    correlation_id: ?contracts.CorrelationId = null,
    incompatibility: ?contracts.ProtocolIncompatibility = null,
    missing_capabilities: u64 = 0,
    frame: ?protocol.DecodedFrame = null,

    pub fn is_missing_capability(
        self: Completion,
        capability: u64,
    ) bool {
        return self.kind == .unavailable and
            self.missing_capabilities & capability != 0;
    }

    pub fn deinit(self: *Completion) void {
        if (self.frame) |*frame| frame.deinit();
        self.* = undefined;
    }
};

inline fn failCompletion(err: anytype) @TypeOf(err)!Completion {
    return @errorCast(failCompletionDynamic(err));
}

noinline fn failCompletionDynamic(err: anyerror) anyerror!Completion {
    return err;
}

test "completion failure writer preserves exact error type and identity" {
    const failure = failCompletion(error.InvalidHostMessage);
    try std.testing.expect(@TypeOf(failure) == error{InvalidHostMessage}!Completion);
    try std.testing.expectError(error.InvalidHostMessage, failure);
}

const Intent = struct {
    correlation_id: contracts.CorrelationId,
    request: contracts.OwnedActionRequest,

    fn deinit(self: *Intent, alloc: Allocator) void {
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

const Queue = struct {
    values: [policy.queue_capacity]?Intent = @splat(null),
    len: usize = 0,

    fn admit(self: *Queue, intent: Intent, stopping: bool) AdmissionError!void {
        switch (policy.classifyQueueAdmission(
            self.len,
            self.values.len,
            stopping,
        )) {
            .full => return error.QueueFull,
            .stopping => return error.RuntimeStopping,
            .admit => {},
        }
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
    values: [policy.outcome_capacity]?Completion = @splat(null),
    len: usize = 0,
    correlated_len: usize = 0,

    fn push(self: *CompletionSink, completion: Completion) void {
        std.debug.assert(completion.correlation_id != null);
        std.debug.assert(self.correlated_len < policy.outcome_capacity);
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

pub const Runtime = struct {
    process_provider: process_provider_mod.Provider =
        process_provider_mod.unavailable_provider,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    queue: Queue = .{},
    completions: CompletionSink = .{},
    live_correlations: policy.PendingRequests = .{},
    thread: ?std.Thread = null,
    alloc: ?Allocator = null,
    stopping: bool = false,
    stop_requested: std.atomic.Value(bool) = .init(false),
    active: [max_active_requests]?*RequestWorker = @splat(null),
    active_count: usize = 0,
    next_correlation_value: u64 = 1,
    projection: ui_projection.Store = .{},

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
            self.pushCompletionLocked(.{
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

    pub fn deinit(self: *Runtime) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        self.stopping = true;
        self.stop_requested.store(true, .release);
        self.wake.broadcast(zio);
        self.mutex.unlock(zio);
        if (self.thread) |thread| thread.join();
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
        self.resetDrainedState();
    }

    noinline fn resetDrainedState(self: *Runtime) void {
        // The drain above already nulls every owned slot. Reset only the
        // observable metadata so teardown does not copy the full runtime.
        self.process_provider = process_provider_mod.unavailable_provider;
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
    }

    fn pushCompletionLocked(self: *Runtime, completion: Completion) void {
        self.completions.push(completion);
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
        std.debug.assert(self.live_correlations.complete(correlation_id));
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
        self.pushCompletionLocked(completion);
        self.wake.broadcast(zio);
    }

    fn observeProjectionLocked(
        self: *Runtime,
        request: contracts.ActionRequest,
        completion: Completion,
    ) void {
        const frame = completion.frame orelse return;
        const response = switch (frame.message().payload) {
            .response => |value| value,
            else => return,
        };
        self.projection.observe(self.alloc.?, request, response) catch |err| {
            debug_trace.logf(
                "terminal_client",
                "ui projection update failed err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn takeIntentLocked(self: *Runtime) ?Intent {
        return self.queue.take();
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
};

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
        if (takeoverWorkerStartFailureRequested(worker)) {
            runtime.finishActive(worker, .{
                .kind = .disconnected,
                .correlation_id = worker.intent.correlation_id,
            });
            worker.intent.deinit(alloc);
            alloc.destroy(worker);
            continue;
        }
        var thread = std.Thread.spawn(.{}, RequestWorker.run, .{worker}) catch {
            const completion = Completion{
                .kind = .disconnected,
                .correlation_id = worker.intent.correlation_id,
            };
            runtime.finishActive(worker, completion);
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
    cancelled: std.atomic.Value(bool) = .init(false),

    fn run(self: *RequestWorker) void {
        const alloc = self.runtime.alloc.?;
        maybeDelayRequestForTest(self);
        if (self.runtime.stop_requested.load(.acquire) or
            self.cancelled.load(.acquire))
        {
            self.runtime.finishActive(self, .{
                .kind = .cancelled,
                .correlation_id = self.intent.correlation_id,
            });
            self.intent.deinit(alloc);
            alloc.destroy(self);
            return;
        }
        const completion = exchange(self, alloc, &self.intent) catch |err| blk: {
            debug_trace.logf(
                "terminal_client",
                "request failed correlation={d} err={s}",
                .{ self.intent.correlation_id.value, @errorName(err) },
            );
            break :blk Completion{
                .kind = switch (err) {
                    error.ProtocolIncompatible => .unavailable,
                    else => .disconnected,
                },
                .correlation_id = self.intent.correlation_id,
            };
        };
        self.runtime.finishActive(self, completion);
        self.intent.deinit(alloc);
        alloc.destroy(self);
    }
};

fn maybeDelayRequestForTest(worker: *RequestWorker) void {
    const variable = switch (worker.intent.request.value) {
        .start => "FX_TERMINAL_TEST_CLIENT_REQUEST_DELAY_MS",
        .write => |request| if (request.lease == .acquire)
            "FX_TERMINAL_TEST_TAKEOVER_ACQUIRE_DELAY_MS"
        else
            return,
        else => return,
    };
    const value = io_mod.getenv(variable) orelse return;
    var remaining_ms: u64 = @min(
        std.fmt.parseInt(u64, value, 10) catch return,
        30_000,
    );
    while (remaining_ms > 0 and
        !worker.runtime.stop_requested.load(.acquire) and
        !worker.cancelled.load(.acquire))
    {
        const step_ms: u64 = @min(remaining_ms, 10);
        io_mod.sleep(step_ms * std.time.ns_per_ms);
        remaining_ms -= step_ms;
    }
}

fn takeoverWorkerStartFailureRequested(worker: *const RequestWorker) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_TAKEOVER_FAILURE") orelse
        return false;
    if (!std.mem.eql(u8, requested, "worker_start")) return false;
    return switch (worker.intent.request.value) {
        .write => |request| request.lease == .acquire,
        else => false,
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
    runtime.pushCompletionLocked(.{
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
    return runtime.takeIntentLocked();
}

const Connected = struct {
    stream: std.Io.net.Stream,
    negotiated: contracts.NegotiatedProtocol,
    incompatibility: ?contracts.ProtocolIncompatibility = null,
};

fn exchange(
    worker: *RequestWorker,
    alloc: Allocator,
    intent: *const Intent,
) !Completion {
    var connected = try connectAndHandshake(
        alloc,
        worker.runtime.process_provider,
    );
    defer connected.stream.close(io_mod.getIo());
    if (connected.incompatibility) |incompatibility| {
        return .{
            .kind = .unavailable,
            .correlation_id = intent.correlation_id,
            .incompatibility = incompatibility,
        };
    }
    return exchangeConnected(worker, alloc, intent, connected);
}

fn exchangeConnected(
    worker: *RequestWorker,
    alloc: Allocator,
    intent: *const Intent,
    connected: Connected,
) !Completion {
    const required_capabilities = contracts.required_capabilities(
        intent.request.value,
    );
    const missing_capabilities = required_capabilities &
        ~connected.negotiated.capabilities;
    if (missing_capabilities != 0) {
        return .{
            .kind = .unavailable,
            .correlation_id = intent.correlation_id,
            .missing_capabilities = missing_capabilities,
        };
    }

    var write_buffer: [4096]u8 = undefined;
    var writer = connected.stream.writer(io_mod.getIo(), &write_buffer);
    var request_frame = try protocol.encodeFrame(
        alloc,
        connected.negotiated.revision,
        required_capabilities,
        intent.correlation_id,
        .{ .request = intent.request.value },
    );
    defer request_frame.deinit(alloc);
    try protocol.writeFrame(&writer.interface, request_frame);

    while (true) {
        var frame = readCancellableFrame(
            worker,
            alloc,
            connected.stream.socket,
        ) catch |err| switch (err) {
            error.Cancelled => {
                var cancel_frame = try protocol.encodeFrame(
                    alloc,
                    connected.negotiated.revision,
                    0,
                    intent.correlation_id,
                    .cancel,
                );
                defer cancel_frame.deinit(alloc);
                protocol.writeFrame(&writer.interface, cancel_frame) catch {};
                return .{
                    .kind = .cancelled,
                    .correlation_id = intent.correlation_id,
                };
            },
            else => return err,
        };
        const message = frame.message();
        switch (message.payload) {
            .response => {
                const correlation_id = message.envelope.correlation_id.?;
                if (correlation_id.value != intent.correlation_id.value) {
                    frame.deinit();
                    return failCompletion(error.InvalidResponseCorrelation);
                }
                return .{
                    .kind = .response,
                    .correlation_id = correlation_id,
                    .frame = frame,
                };
            },
            .hello, .request, .cancel => {
                frame.deinit();
                return failCompletion(error.InvalidHostMessage);
            },
        }
    }
}

fn readCancellableFrame(
    worker: *RequestWorker,
    alloc: Allocator,
    socket: std.Io.net.Socket,
) !protocol.DecodedFrame {
    var header_bytes: [protocol.header_len]u8 = undefined;
    try receiveCancellable(
        worker,
        socket,
        &header_bytes,
    );
    const header = try protocol.Header.decode(&header_bytes);
    const payload_len: usize = header.envelope.payload_len;
    const total_len = std.math.add(
        usize,
        protocol.header_len,
        payload_len,
    ) catch return error.HostFrameTooLarge;
    var bytes = try alloc.alloc(u8, total_len);
    defer alloc.free(bytes);
    @memcpy(bytes[0..protocol.header_len], &header_bytes);
    try receiveCancellable(
        worker,
        socket,
        bytes[protocol.header_len..],
    );
    return protocol.decodeFrame(alloc, bytes);
}

fn receiveCancellable(
    worker: *RequestWorker,
    socket: std.Io.net.Socket,
    destination: []u8,
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        if (worker.runtime.stop_requested.load(.acquire)) {
            return error.RuntimeStopping;
        }
        if (worker.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
        const incoming = socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(50),
            } },
        ) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn connectAndHandshake(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
) !Connected {
    return connectAndHandshakeOnce(alloc, process_provider) catch |err| switch (err) {
        error.HostClosedBeforeHandshake => connectAndHandshakeOnce(
            alloc,
            process_provider,
        ),
        else => err,
    };
}

fn connectAndHandshakeOnce(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
) !Connected {
    if (!host.isSupported()) return error.TerminalHostUnsupported;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var paths = try host.Paths.open(alloc, home);
    defer paths.deinit(alloc);

    var stream = connectOrStart(alloc, process_provider, &paths) catch |err| {
        debug_trace.logf(
            "terminal_client",
            "host unavailable err={s}",
            .{@errorName(err)},
        );
        return err;
    };
    errdefer stream.close(io_mod.getIo());

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &write_buffer);
    var hello_frame = try protocol.encodeFrame(
        alloc,
        contracts.compatibility_hello_revision,
        0,
        null,
        .{ .hello = .{
            .range = contracts.local_protocol_range,
            .capabilities = contracts.known_protocol_capabilities,
        } },
    );
    defer hello_frame.deinit(alloc);
    try protocol.writeFrame(&writer.interface, hello_frame);

    var reply = try readHandshakeFrame(alloc, stream.socket);
    defer reply.deinit();
    const host_hello = switch (reply.message().payload) {
        .hello => |hello| hello,
        else => return error.HandshakeRequired,
    };
    const negotiation = try contracts.negotiate_protocol(
        .{
            .range = contracts.local_protocol_range,
            .capabilities = contracts.known_protocol_capabilities,
        },
        host_hello,
    );
    return switch (negotiation) {
        .compatible => |negotiated| .{
            .stream = stream,
            .negotiated = negotiated,
        },
        .incompatible => |incompatibility| .{
            .stream = stream,
            .negotiated = undefined,
            .incompatibility = incompatibility,
        },
    };
}

fn connectOrStart(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    paths: *host.Paths,
) !std.Io.net.Stream {
    const started = io_mod.milliTimestamp();
    var authority_lock = while (true) {
        break io_mod.acquireTimedAdvisoryLock(
            &paths.host_dir,
            host.lock_name,
            0,
        ) catch |err| switch (err) {
            error.LockBusy => {
                if (tryConnect(paths.endpoint_path)) |stream| return stream;
                if (io_mod.milliTimestamp() - started >= connect_deadline_ms) {
                    return error.HostConnectTimeout;
                }
                io_mod.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    };
    const connection: policy.ConnectionEvidence =
        if (endpointExists(paths.endpointDir())) .refused else .endpoint_missing;
    const identity = host.identityEvidence(
        alloc,
        process_provider,
        &paths.host_dir,
    );
    const decision = policy.classifyReconciliation(
        connection,
        .acquired,
        identity,
    );
    switch (decision) {
        .start_host => authority_lock.release(),
        .remove_stale_then_start => {
            host.removeStaleArtifacts(&paths.host_dir, paths.endpointDir());
            authority_lock.release();
        },
        .preserve_identity_conflict => {
            authority_lock.release();
            return error.HostIdentityConflict;
        },
        .reuse_connected, .wait_for_authority, .unavailable => {
            authority_lock.release();
            return error.HostUnavailable;
        },
    }
    try launchHost(alloc);
    return waitForHost(paths.endpoint_path);
}

fn tryConnect(endpoint_path: []const u8) ?std.Io.net.Stream {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) {
        const address = std.Io.net.UnixAddress.init(endpoint_path) catch return null;
        return address.connect(io_mod.getIo()) catch null;
    }
    if (endpoint_path.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) {
        return null;
    }
    const fd = std.c.socket(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
    );
    if (fd < 0) return null;
    var connected = false;
    defer if (!connected) {
        _ = std.c.close(fd);
    };
    if (std.c.fcntl(
        fd,
        std.c.F.SETFD,
        @as(usize, std.c.FD_CLOEXEC),
    ) != 0) return null;

    var socket_address: std.c.sockaddr.un = .{
        .family = std.c.AF.UNIX,
        .path = @splat(0),
    };
    @memcpy(socket_address.path[0..endpoint_path.len], endpoint_path);
    const address_len: std.c.socklen_t = @intCast(
        @offsetOf(std.c.sockaddr.un, "path") + endpoint_path.len + 1,
    );
    if (@hasField(std.c.sockaddr.un, "len")) {
        socket_address.len = @intCast(address_len);
    }
    if (std.c.connect(
        fd,
        @ptrCast(&socket_address),
        address_len,
    ) != 0) return null;
    connected = true;
    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .loopback(0) },
    } };
}

fn waitForHost(endpoint_path: []const u8) !std.Io.net.Stream {
    const started = io_mod.milliTimestamp();
    while (io_mod.milliTimestamp() - started < connect_deadline_ms) {
        if (tryConnect(endpoint_path)) |stream| return stream;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.HostConnectTimeout;
}

fn launchHost(alloc: Allocator) !void {
    const executable = try self_exe.pathForReexec(alloc);
    defer alloc.free(executable);
    const argv = [_][]const u8{ executable, host.internal_mode };
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .macos or builtin.os.tag == .linux)
            0
        else
            null,
    });
    var reaper = try std.Thread.spawn(.{}, reapChild, .{child});
    reaper.detach();
}

fn reapChild(child_value: std.process.Child) void {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const pid = child_value.id orelse return;
        while (true) {
            const waited = std.c.waitpid(pid, null, 0);
            if (waited == pid) return;
            if (std.c.errno(waited) != .INTR) return;
        }
    }
    var child = child_value;
    _ = child.wait(io_mod.getIo()) catch {};
}

fn endpointExists(host_dir: *io_mod.VerifiedDir) bool {
    const stat = host_dir.dir.statFile(
        io_mod.getIo(),
        host.endpoint_name,
        .{ .follow_symlinks = false },
    ) catch return false;
    return stat.kind == .unix_domain_socket;
}

fn readHandshakeFrame(
    alloc: Allocator,
    socket: std.Io.net.Socket,
) !protocol.DecodedFrame {
    const deadline_ms = io_mod.milliTimestamp() + handshake_deadline_ms;
    var header_bytes: [protocol.header_len]u8 = undefined;
    try receiveBeforeDeadline(socket, &header_bytes, deadline_ms, .header);
    const header = try protocol.Header.decode(&header_bytes);
    const payload_len: usize = header.envelope.payload_len;
    const total_len = std.math.add(
        usize,
        protocol.header_len,
        payload_len,
    ) catch return error.HostFrameTooLarge;
    const bytes = try alloc.alloc(u8, total_len);
    defer alloc.free(bytes);
    @memcpy(bytes[0..protocol.header_len], &header_bytes);
    try receiveBeforeDeadline(
        socket,
        bytes[protocol.header_len..],
        deadline_ms,
        .payload,
    );
    return protocol.decodeFrame(alloc, bytes);
}

const HandshakeReadPart = enum {
    header,
    payload,
};

fn receiveBeforeDeadline(
    socket: std.Io.net.Socket,
    destination: []u8,
    deadline_ms: i64,
    part: HandshakeReadPart,
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const remaining_ms = deadline_ms - io_mod.milliTimestamp();
        if (remaining_ms <= 0) return error.HostHandshakeTimeout;
        const poll_ms = @min(remaining_ms, 50);
        const incoming = socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(poll_ms),
            } },
        ) catch |err| switch (err) {
            error.Timeout => continue,
            error.ConnectionResetByPeer => {
                if (part == .header and offset == 0) {
                    return error.HostClosedBeforeHandshake;
                }
                return error.TruncatedFrame;
            },
            else => return err,
        };
        if (incoming.data.len == 0) {
            if (part == .header and offset == 0) {
                return error.HostClosedBeforeHandshake;
            }
            return error.TruncatedFrame;
        }
        offset += incoming.data.len;
    }
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
    while (next_id <= policy.queue_capacity) : (next_id += 1) {
        try queue.admit(try testIntent(std.testing.allocator, next_id), false);
    }
    var overflow = try testIntent(std.testing.allocator, next_id);
    defer overflow.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.QueueFull,
        queue.admit(overflow, false),
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
        try std.testing.expectEqual(expected, intent.correlation_id.value);
        intent.deinit(std.testing.allocator);
    }
    try std.testing.expect(queue.take() == null);
}

test "targeted queue cancellation preserves FIFO order" {
    var queue: Queue = .{};
    defer {
        while (queue.take()) |intent_value| {
            var intent = intent_value;
            intent.deinit(std.testing.allocator);
        }
    }
    for (1..5) |id| {
        try queue.admit(try testIntent(std.testing.allocator, id), false);
    }
    var cancelled = queue.cancel(.{ .value = 2 }).?;
    cancelled.deinit(std.testing.allocator);

    for ([_]u64{ 1, 3, 4 }) |expected| {
        var intent = queue.take().?;
        try std.testing.expectEqual(expected, intent.correlation_id.value);
        intent.deinit(std.testing.allocator);
    }
}

test "completion sink stays FIFO after dequeue and refill" {
    var sink: CompletionSink = .{};
    defer {
        while (sink.take()) |completion_value| {
            var completion = completion_value;
            completion.deinit();
        }
    }
    sink.push(.{ .kind = .response, .correlation_id = .{ .value = 1 } });
    sink.push(.{ .kind = .cancelled, .correlation_id = .{ .value = 2 } });

    var first = sink.take().?;
    try std.testing.expectEqual(CompletionKind.response, first.kind);
    first.deinit();
    sink.push(.{ .kind = .disconnected, .correlation_id = .{ .value = 3 } });

    for ([_]CompletionKind{ .cancelled, .disconnected }) |expected| {
        var completion = sink.take().?;
        try std.testing.expectEqual(expected, completion.kind);
        completion.deinit();
    }
}

test "runtime reserves bounded outcomes until every correlation is consumed" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();

    for (1..policy.outcome_capacity + 1) |id| {
        try admitTestIntent(&runtime, id);
        var intent = runtime.queue.take().?;
        intent.deinit(std.testing.allocator);
        runtime.pushCompletionLocked(.{
            .kind = .response,
            .correlation_id = .{ .value = id },
        });
    }
    try std.testing.expectEqual(
        @as(usize, policy.outcome_capacity),
        runtime.completions.correlated_len,
    );
    try std.testing.expectError(
        error.QueueFull,
        admitTestIntent(&runtime, policy.outcome_capacity + 1),
    );
    try std.testing.expectEqual(
        @as(usize, policy.outcome_capacity),
        runtime.completions.correlated_len,
    );

    for (1..policy.outcome_capacity + 1) |id| {
        var completion = runtime.takeCompletionFor(.{ .value = id }).?;
        try std.testing.expectEqual(@as(u64, id), completion.correlation_id.?.value);
        completion.deinit();
        try std.testing.expect(runtime.takeCompletionFor(.{ .value = id }) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.correlated_len);
}

test "runtime rejects duplicate queued and active correlations" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();
    try admitTestIntent(&runtime, 23);
    try std.testing.expectError(
        error.DuplicateCorrelation,
        admitTestIntent(&runtime, 23),
    );

    const active_intent = takeIntent(&runtime).?;
    var worker = RequestWorker{
        .runtime = &runtime,
        .intent = active_intent,
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
    runtime.pushCompletionLocked(.{
        .kind = .disconnected,
        .correlation_id = .{ .value = 1 },
    });

    runtime.deinit();
    try std.testing.expect(runtime.alloc == null);
    try std.testing.expect(runtime.thread == null);
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

test "lazy runtime has no allocation or worker before first admission" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try std.testing.expect(runtime.alloc == null);
    try std.testing.expect(runtime.thread == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.queue.len);
}

test "stalled request cancellation emits only the targeted cancel" {
    if (!host.isSupported()) return error.SkipZigTest;
    var handles: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &handles,
    ) != 0) return error.SocketPairFailed;
    var client_stream = std.Io.net.Stream{ .socket = .{
        .handle = handles[0],
        .address = undefined,
    } };
    defer client_stream.close(io_mod.getIo());
    var host_stream = std.Io.net.Stream{ .socket = .{
        .handle = handles[1],
        .address = undefined,
    } };
    defer host_stream.close(io_mod.getIo());

    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();
    var worker = RequestWorker{
        .runtime = &runtime,
        .intent = .{
            .correlation_id = .{ .value = 17 },
            .request = try contracts.OwnedActionRequest.init(
                std.testing.allocator,
                .{ .screen = .{ .session_id = "terminal-1" } },
            ),
        },
    };
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    try runtime.live_correlations.add(.{ .value = 17 });
    worker.slot = runtime.registerWorkerLocked(&worker).?;
    runtime.mutex.unlock(zio);

    const Exchange = struct {
        worker: *RequestWorker,
        stream: std.Io.net.Stream,
        completion: ?Completion = null,
        failed: bool = false,

        fn run(self: *@This()) void {
            self.completion = exchangeConnected(
                self.worker,
                std.testing.allocator,
                &self.worker.intent,
                .{
                    .stream = self.stream,
                    .negotiated = .{
                        .revision = contracts.current_protocol_revision,
                        .capabilities = contracts.known_protocol_capabilities,
                    },
                },
            ) catch {
                self.failed = true;
                return;
            };
        }
    };
    var exchange_state = Exchange{
        .worker = &worker,
        .stream = client_stream,
    };
    const thread = try std.Thread.spawn(.{}, Exchange.run, .{&exchange_state});

    var host_read_buffer: [4096]u8 = undefined;
    var host_reader = host_stream.reader(io_mod.getIo(), &host_read_buffer);
    var request = try protocol.readFrame(
        std.testing.allocator,
        &host_reader.interface,
    );
    defer request.deinit();
    try std.testing.expectEqual(
        @as(u64, 17),
        request.message().envelope.correlation_id.?.value,
    );
    try std.testing.expect(runtime.cancel(.{ .value = 17 }));
    var cancel = try protocol.readFrame(
        std.testing.allocator,
        &host_reader.interface,
    );
    defer cancel.deinit();
    try std.testing.expectEqual(
        @as(u64, 17),
        cancel.message().envelope.correlation_id.?.value,
    );
    switch (cancel.message().payload) {
        .cancel => {},
        else => return error.TestExpectedCancel,
    }

    thread.join();
    try std.testing.expect(!exchange_state.failed);
    var completion = exchange_state.completion.?;
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.cancelled, completion.kind);
    runtime.finishActive(&worker, .{
        .kind = .cancelled,
        .correlation_id = .{ .value = 17 },
    });
    worker.intent.deinit(std.testing.allocator);
}

test "unsupported client platforms remain structural" {
    const host_capabilities = @import("../hosts/host.zig");
    try std.testing.expectEqual(
        host_capabilities.terminalSupportForOs(builtin.os.tag).isSupported(),
        host.isSupported(),
    );
}

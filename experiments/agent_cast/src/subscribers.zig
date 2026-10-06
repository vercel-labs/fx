const std = @import("std");

// Experimental, single-owner state machine. The trusted parent certifies sharing
// eligibility and supplies physical keys, epochs, job IDs, and monotonic time.
// This module performs no I/O, permission review, persistence, or retries.
// The parent owns payloads, pinned copies, and global pending-output accounting.
// A reservation is accounting metadata only; it does not allocate payload space.
pub const Options = struct {
    max_jobs: usize = 64,
    max_consumers: usize = 256,
};

pub const ConsumerIdentity = struct { client_id: u64, call_id: u64 };
pub const ConsumerRef = struct { token: u64 };
pub const JobRef = struct { token: u64, backing_id: u64, epoch: u64 };
pub const JobState = enum { queued, running, aborting, settled };
pub const Phase = enum { not_started, settled, uncertain };
pub const Outcome = enum { success, failed, stopped, cancelled, deadline_exceeded, worker_lost };
pub const Settlement = enum { success, failed, stopped };
pub const Action = enum { none, not_started, stop_requested };
pub const Receipt = struct { outcome: Outcome, phase: Phase, delivered_bytes: u64 };
pub const LeaveEvent = struct { consumer: ConsumerRef, job: JobRef, receipt: Receipt, action: Action };
pub const Subscription = struct { consumer: ConsumerRef, job: JobRef, shared: bool };
pub const Subscribe = struct {
    physical_key: [32]u8,
    epoch: u64,
    backing_id: u64,
    identity: ConsumerIdentity,
    deadline: u64,
    output_budget: u64,
    initial_credit: u64 = 0,
};
pub const Reservation = struct { consumer: ConsumerRef, job: JobRef, sequence: u64, bytes: u64 };
pub const ConsumerSnapshot = struct {
    identity: ConsumerIdentity,
    job: JobRef,
    deadline: u64,
    credit: u64,
    remaining_output_budget: u64,
    delivered_bytes: u64,
    next_output_sequence: u64,
    next_grant_sequence: u64,
    pending: ?Reservation,
    receipt: ?Receipt,
};
pub const JobSnapshot = struct { state: JobState, active_consumers: usize, expected_result_bytes: ?u64, receipt: ?Receipt };

pub const Error = error{
    InvalidOptions,
    JobCapacity,
    ConsumerCapacity,
    DuplicateConsumer,
    DuplicateJob,
    UnknownJob,
    UnknownConsumer,
    StaleEpoch,
    JobNotQueued,
    JobNotRunning,
    ConsumerTerminal,
    DeadlineExpired,
    NotExpired,
    ClockRegression,
    InvalidCredit,
    InvalidGrantSequence,
    InsufficientCredit,
    OutputBudgetExceeded,
    ResultSizeUndeclared,
    ResultSizeAlreadyDeclared,
    ResultSizeExceeded,
    ResultNotDrained,
    OutputPending,
    InvalidReservation,
    EmptyOutput,
    SequenceOverflow,
    TokenOverflow,
    BufferTooSmall,
    ConsumersRetained,
    NotTerminal,
};

const Job = struct {
    ref: JobRef,
    physical_key: [32]u8,
    state: JobState = .queued,
    active_consumers: usize = 0,
    retained_consumers: usize = 0,
    expected_result_bytes: ?u64 = null,
    receipt: ?Receipt = null,
};
const Consumer = struct {
    ref: ConsumerRef,
    data: ConsumerSnapshot,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    jobs: []?Job,
    consumers: []?Consumer,
    next_job_token: u64 = 1,
    next_consumer_token: u64 = 1,
    last_time: u64 = 0,

    // Registry owns both fixed tables. No operation allocates after init.
    // The caller must serialize access and call deinit exactly once.
    pub fn init(allocator: std.mem.Allocator, options: Options) (Error || std.mem.Allocator.Error)!Registry {
        if (options.max_jobs == 0 or options.max_jobs > 1024 or
            options.max_consumers == 0 or options.max_consumers > 8192) return error.InvalidOptions;
        const jobs = try allocator.alloc(?Job, options.max_jobs);
        errdefer allocator.free(jobs);
        const consumers = try allocator.alloc(?Consumer, options.max_consumers);
        @memset(jobs, null);
        @memset(consumers, null);
        return .{ .allocator = allocator, .jobs = jobs, .consumers = consumers };
    }

    pub fn deinit(self: *Registry) void {
        self.allocator.free(self.jobs);
        self.allocator.free(self.consumers);
        self.* = undefined;
    }

    pub fn subscribe(self: *Registry, args: Subscribe, now: u64) Error!Subscription {
        try self.observe_time(now);
        if (args.deadline <= now) return error.DeadlineExpired;
        if (args.initial_credit > args.output_budget) return error.InvalidCredit;
        var free_consumer: ?usize = null;
        for (self.consumers, 0..) |entry, index| {
            if (entry) |consumer| {
                if (std.meta.eql(consumer.data.identity, args.identity)) return error.DuplicateConsumer;
            } else if (free_consumer == null) free_consumer = index;
        }
        const consumer_index = free_consumer orelse return error.ConsumerCapacity;
        if (self.next_consumer_token == std.math.maxInt(u64)) return error.TokenOverflow;
        var matching_job: ?usize = null;
        var free_job: ?usize = null;
        for (self.jobs, 0..) |entry, index| {
            if (entry) |job| {
                if (job.ref.epoch == args.epoch and std.mem.eql(u8, &job.physical_key, &args.physical_key) and
                    (job.state == .queued or job.state == .running) and job.active_consumers != 0)
                {
                    // An expired final consumer must be swept before a new
                    // arrival can share, so it cannot revive abandoned work.
                    var live = false;
                    for (self.consumers) |consumer_entry| {
                        if (consumer_entry) |consumer| {
                            if (std.meta.eql(consumer.data.job, job.ref) and consumer.data.receipt == null and
                                consumer.data.deadline > now) live = true;
                        }
                    }
                    if (!live) return error.DeadlineExpired;
                    matching_job = index;
                }
            } else if (free_job == null) free_job = index;
        }
        const shared = matching_job != null;
        const job_index = matching_job orelse free_job orelse return error.JobCapacity;
        if (!shared) {
            if (self.next_job_token == std.math.maxInt(u64)) return error.TokenOverflow;
            for (self.jobs) |entry| {
                if (entry) |job| {
                    if (job.ref.backing_id == args.backing_id and job.ref.epoch == args.epoch) return error.DuplicateJob;
                }
            }
            self.jobs[job_index] = .{
                .ref = .{ .token = self.next_job_token, .backing_id = args.backing_id, .epoch = args.epoch },
                .physical_key = args.physical_key,
            };
            self.next_job_token += 1;
        }
        const job = &self.jobs[job_index].?;
        const consumer_ref: ConsumerRef = .{ .token = self.next_consumer_token };
        self.next_consumer_token += 1;
        self.consumers[consumer_index] = .{ .ref = consumer_ref, .data = .{
            .identity = args.identity,
            .job = job.ref,
            .deadline = args.deadline,
            .credit = args.initial_credit,
            .remaining_output_budget = args.output_budget,
            .delivered_bytes = 0,
            .next_output_sequence = 0,
            .next_grant_sequence = 0,
            .pending = null,
            .receipt = null,
        } };
        job.active_consumers += 1;
        job.retained_consumers += 1;
        return .{ .consumer = consumer_ref, .job = job.ref, .shared = shared };
    }

    // Queue time counts. Run expire first when any queued consumer is overdue.
    pub fn start(self: *Registry, ref: JobRef, now: u64) Error!void {
        try self.observe_time(now);
        const job = try self.find_job(ref);
        if (job.state != .queued) return error.JobNotQueued;
        for (self.consumers) |entry| {
            if (entry) |consumer| {
                if (std.meta.eql(consumer.data.job, ref) and consumer.data.receipt == null and
                    consumer.data.deadline <= now) return error.DeadlineExpired;
            }
        }
        job.state = .running;
    }

    // Grant sequences start at zero and must be contiguous, rejecting replay.
    // Remaining budget excludes the one pending reservation, if any.
    pub fn grant_credit(self: *Registry, ref: ConsumerRef, grant_sequence: u64, bytes: u64, now: u64) Error!void {
        try self.observe_time(now);
        const consumer = try self.live_consumer(ref, now);
        if (grant_sequence != consumer.data.next_grant_sequence) return error.InvalidGrantSequence;
        if (grant_sequence == std.math.maxInt(u64)) return error.SequenceOverflow;
        if (bytes == 0 or bytes > consumer.data.remaining_output_budget - consumer.data.credit) return error.InvalidCredit;
        consumer.data.credit += bytes;
        consumer.data.next_grant_sequence += 1;
    }

    // The trusted parent validates payload length and declares it exactly once.
    // Zero is an explicit empty result. New consumers of a running shared job
    // must still receive this full size; replay and payload storage are parent-owned.
    pub fn declare_result_size(self: *Registry, ref: JobRef, expected_bytes: u64, now: u64) Error!void {
        try self.observe_time(now);
        const job = try self.find_job(ref);
        if (job.state != .running) return error.JobNotRunning;
        if (job.expected_result_bytes != null) return error.ResultSizeAlreadyDeclared;
        job.expected_result_bytes = expected_bytes;
    }

    // Reserve before queuing parent-owned bytes. At most one reservation exists
    // per consumer; bytes immediately consume that consumer's output budget.
    pub fn reserve_output(self: *Registry, ref: JobRef, consumer_ref: ConsumerRef, bytes: u64, now: u64) Error!Reservation {
        try self.observe_time(now);
        const job = try self.find_job(ref);
        if (job.state != .running) return error.JobNotRunning;
        const expected_bytes = job.expected_result_bytes orelse return error.ResultSizeUndeclared;
        const consumer = try self.live_consumer(consumer_ref, now);
        if (!std.meta.eql(consumer.data.job, ref)) return error.InvalidReservation;
        if (consumer.data.pending != null) return error.OutputPending;
        if (bytes == 0) return error.EmptyOutput;
        if (consumer.data.next_output_sequence == std.math.maxInt(u64)) return error.SequenceOverflow;
        if (bytes > consumer.data.remaining_output_budget) return error.OutputBudgetExceeded;
        if (bytes > expected_bytes - consumer.data.delivered_bytes) return error.ResultSizeExceeded;
        if (bytes > consumer.data.credit) return error.InsufficientCredit;
        const reservation: Reservation = .{
            .consumer = consumer_ref,
            .job = ref,
            .sequence = consumer.data.next_output_sequence,
            .bytes = bytes,
        };
        consumer.data.next_output_sequence += 1;
        consumer.data.remaining_output_budget -= bytes;
        consumer.data.credit -= bytes;
        consumer.data.pending = reservation;
        return reservation;
    }

    // Call only when the parent has delivered the reserved bytes. Repeating a
    // delivery or using an old epoch cannot advance accounting twice.
    pub fn deliver_output(self: *Registry, reservation: Reservation, now: u64) Error!void {
        try self.observe_time(now);
        const job = try self.find_job(reservation.job);
        if (job.state != .running) return error.JobNotRunning;
        const consumer = try self.live_consumer(reservation.consumer, now);
        const pending = consumer.data.pending orelse return error.InvalidReservation;
        if (!std.meta.eql(pending, reservation)) return error.InvalidReservation;
        const sum = @addWithOverflow(consumer.data.delivered_bytes, reservation.bytes);
        if (sum[1] != 0) return error.SequenceOverflow;
        consumer.data.delivered_bytes = sum[0];
        consumer.data.pending = null;
    }

    pub fn cancel(self: *Registry, ref: ConsumerRef, now: u64) Error!LeaveEvent {
        try self.observe_time(now);
        const consumer = try self.find_consumer(ref);
        // Deadlines win over cancellation at or after the absolute deadline.
        const outcome: Outcome = if (consumer.data.deadline <= now) .deadline_exceeded else .cancelled;
        return self.leave(consumer, outcome);
    }

    pub fn expire_consumer(self: *Registry, ref: ConsumerRef, now: u64) Error!LeaveEvent {
        try self.observe_time(now);
        const consumer = try self.find_consumer(ref);
        if (consumer.data.receipt == null and consumer.data.deadline > now) return error.NotExpired;
        return self.leave(consumer, .deadline_exceeded);
    }

    // Returns events in caller-owned storage. A short buffer makes no lifecycle
    // changes, allowing the parent to handle every final-consumer stop request.
    pub fn expire(self: *Registry, now: u64, events: []LeaveEvent) Error![]LeaveEvent {
        try self.observe_time(now);
        var count: usize = 0;
        for (self.consumers) |entry| {
            if (entry) |consumer| {
                if (consumer.data.receipt == null and consumer.data.deadline <= now) count += 1;
            }
        }
        if (events.len < count) return error.BufferTooSmall;
        var index: usize = 0;
        for (self.consumers) |*entry| {
            if (entry.*) |*consumer| {
                if (consumer.data.receipt == null and consumer.data.deadline <= now) {
                    events[index] = try self.leave(consumer, .deadline_exceeded);
                    index += 1;
                }
            }
        }
        return events[0..index];
    }

    // Parent supplies a worker's terminal acknowledgement. Success requires an
    // explicit size and full delivery to every active, unexpired consumer.
    // A rejected success changes no state, including clock observation. Failed
    // or stopped work may discard reservations. Stopped is an acknowledged stop.
    pub fn settle(self: *Registry, ref: JobRef, result: Settlement, now: u64) Error!void {
        if (now < self.last_time) return error.ClockRegression;
        const job = try self.find_job(ref);
        if (job.state != .running and job.state != .aborting) return error.JobNotRunning;
        if (result == .success) {
            const expected_bytes = job.expected_result_bytes orelse return error.ResultSizeUndeclared;
            for (self.consumers) |entry| {
                if (entry) |consumer| {
                    if (std.meta.eql(consumer.data.job, ref) and consumer.data.receipt == null and consumer.data.deadline > now) {
                        if (consumer.data.pending != null) return error.OutputPending;
                        if (consumer.data.delivered_bytes != expected_bytes) return error.ResultNotDrained;
                    }
                }
            }
        }
        try self.observe_time(now);
        const outcome: Outcome = switch (result) {
            .success => .success,
            .failed => .failed,
            .stopped => .stopped,
        };
        self.finish_job(job, outcome, .settled, now);
    }

    // Losing a started worker leaves effects uncertain. There is no retry API.
    pub fn worker_loss(self: *Registry, ref: JobRef, now: u64) Error!void {
        try self.observe_time(now);
        const job = try self.find_job(ref);
        if (job.state == .settled) return error.JobNotRunning;
        const phase: Phase = if (job.state == .queued) .not_started else .uncertain;
        self.finish_job(job, .worker_lost, phase, now);
    }

    pub fn query_consumer(self: *Registry, ref: ConsumerRef) Error!ConsumerSnapshot {
        return (try self.find_consumer(ref)).data;
    }

    pub fn query_job(self: *Registry, ref: JobRef) Error!JobSnapshot {
        const job = try self.find_job(ref);
        return .{ .state = job.state, .active_consumers = job.active_consumers, .expected_result_bytes = job.expected_result_bytes, .receipt = job.receipt };
    }

    // Terminal records are retained until the parent consumes their receipts.
    pub fn reclaim_consumer(self: *Registry, ref: ConsumerRef) Error!void {
        for (self.consumers) |*entry| {
            if (entry.*) |consumer| {
                if (consumer.ref.token == ref.token) {
                    if (consumer.data.receipt == null) return error.NotTerminal;
                    const job = try self.find_job(consumer.data.job);
                    job.retained_consumers -= 1;
                    entry.* = null;
                    return;
                }
            }
        }
        return error.UnknownConsumer;
    }

    // Even terminal jobs cannot be reclaimed while any receipt references them.
    pub fn reclaim_job(self: *Registry, ref: JobRef) Error!void {
        const job = try self.find_job(ref);
        if (job.state != .settled) return error.NotTerminal;
        if (job.retained_consumers != 0) return error.ConsumersRetained;
        for (self.jobs) |*entry| {
            if (entry.*) |value| {
                if (std.meta.eql(value.ref, ref)) {
                    entry.* = null;
                    return;
                }
            }
        }
        unreachable;
    }

    fn observe_time(self: *Registry, now: u64) Error!void {
        if (now < self.last_time) return error.ClockRegression;
        self.last_time = now;
    }

    fn find_job(self: *Registry, ref: JobRef) Error!*Job {
        for (self.jobs) |*entry| {
            if (entry.*) |*job| {
                if (job.ref.token == ref.token) {
                    if (job.ref.epoch != ref.epoch) return error.StaleEpoch;
                    if (job.ref.backing_id != ref.backing_id) return error.UnknownJob;
                    return job;
                }
            }
        }
        return error.UnknownJob;
    }

    fn find_consumer(self: *Registry, ref: ConsumerRef) Error!*Consumer {
        for (self.consumers) |*entry| {
            if (entry.*) |*consumer| {
                if (consumer.ref.token == ref.token) return consumer;
            }
        }
        return error.UnknownConsumer;
    }

    fn live_consumer(self: *Registry, ref: ConsumerRef, now: u64) Error!*Consumer {
        const consumer = try self.find_consumer(ref);
        if (consumer.data.receipt != null) return error.ConsumerTerminal;
        if (consumer.data.deadline <= now) return error.DeadlineExpired;
        return consumer;
    }

    fn leave(self: *Registry, consumer: *Consumer, outcome: Outcome) Error!LeaveEvent {
        const job = try self.find_job(consumer.data.job);
        var action: Action = .none;
        if (consumer.data.receipt == null) {
            const phase: Phase = if (job.state == .queued) .not_started else .uncertain;
            consumer.data.receipt = .{ .outcome = outcome, .phase = phase, .delivered_bytes = consumer.data.delivered_bytes };
            consumer.data.pending = null;
            consumer.data.credit = 0;
            job.active_consumers -= 1;
            if (job.active_consumers == 0) {
                if (job.state == .queued) {
                    job.state = .settled;
                    job.receipt = .{ .outcome = outcome, .phase = .not_started, .delivered_bytes = 0 };
                    action = .not_started;
                } else if (job.state == .running) {
                    job.state = .aborting;
                    action = .stop_requested;
                }
            }
        }
        return .{ .consumer = consumer.ref, .job = job.ref, .receipt = consumer.data.receipt.?, .action = action };
    }

    fn finish_job(self: *Registry, job: *Job, outcome: Outcome, phase: Phase, now: u64) void {
        for (self.consumers) |*entry| {
            if (entry.*) |*consumer| {
                if (std.meta.eql(consumer.data.job, job.ref) and consumer.data.receipt == null) {
                    const expired = consumer.data.deadline <= now;
                    consumer.data.receipt = .{
                        .outcome = if (expired) .deadline_exceeded else outcome,
                        .phase = if (expired and phase != .not_started) .uncertain else phase,
                        .delivered_bytes = consumer.data.delivered_bytes,
                    };
                    consumer.data.pending = null;
                    consumer.data.credit = 0;
                }
            }
        }
        job.active_consumers = 0;
        job.state = .settled;
        job.receipt = .{ .outcome = outcome, .phase = phase, .delivered_bytes = 0 };
    }
};

fn request(client_id: u64, deadline: u64) Subscribe {
    return .{ .physical_key = [_]u8{7} ** 32, .epoch = 3, .backing_id = client_id, .identity = .{ .client_id = client_id, .call_id = 1 }, .deadline = deadline, .output_budget = 20, .initial_credit = 10 };
}

test "two consumers share and cancellation preserves the other" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const first = try registry.subscribe(request(1, 10), 0);
    const second = try registry.subscribe(request(2, 30), 0);
    try std.testing.expect(second.shared);
    try std.testing.expectEqual(first.job, second.job);
    try registry.start(first.job, 1);
    const cancelled = try registry.cancel(first.consumer, 2);
    try std.testing.expectEqual(Action.none, cancelled.action);
    try std.testing.expectEqual(Phase.uncertain, cancelled.receipt.phase);
    try registry.declare_result_size(second.job, 5, 3);
    const reserved = try registry.reserve_output(second.job, second.consumer, 5, 3);
    try registry.deliver_output(reserved, 3);
    try registry.settle(second.job, .success, 4);
    try std.testing.expectEqual(Outcome.cancelled, (try registry.query_consumer(first.consumer)).receipt.?.outcome);
    try std.testing.expectEqual(@as(u64, 5), (try registry.query_consumer(second.consumer)).receipt.?.delivered_bytes);
}

test "queue deadlines expire independently and start uses surviving deadline" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const first = try registry.subscribe(request(1, 10), 0);
    const second = try registry.subscribe(request(2, 30), 0);
    try std.testing.expectError(error.DeadlineExpired, registry.start(first.job, 10));
    var empty: [0]LeaveEvent = .{};
    try std.testing.expectError(error.BufferTooSmall, registry.expire(10, &empty));
    try std.testing.expectEqual(@as(usize, 2), (try registry.query_job(first.job)).active_consumers);
    var events: [2]LeaveEvent = undefined;
    const expired = try registry.expire(10, &events);
    try std.testing.expectEqual(@as(usize, 1), expired.len);
    try std.testing.expectEqual(Phase.not_started, expired[0].receipt.phase);
    try registry.start(second.job, 10);
    try registry.declare_result_size(second.job, 1, 10);
    try std.testing.expectEqual(@as(u64, 30), (try registry.query_consumer(second.consumer)).deadline);
    try std.testing.expectError(error.DeadlineExpired, registry.reserve_output(second.job, second.consumer, 1, 30));
    const last = try registry.expire_consumer(second.consumer, 30);
    try std.testing.expectEqual(Action.stop_requested, last.action);
}

test "last queued cancellation never starts and draining job refuses new attachment" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const queued = try registry.subscribe(request(1, 100), 0);
    const event = try registry.cancel(queued.consumer, 1);
    try std.testing.expectEqual(Action.not_started, event.action);
    try std.testing.expectEqual(Phase.not_started, event.receipt.phase);
    try std.testing.expectError(error.JobNotQueued, registry.start(queued.job, 1));
    const first = try registry.subscribe(request(2, 100), 1);
    const second = try registry.subscribe(request(3, 100), 1);
    try registry.start(first.job, 2);
    _ = try registry.cancel(first.consumer, 3);
    const last = try registry.cancel(second.consumer, 3);
    try std.testing.expectEqual(Action.stop_requested, last.action);
    try std.testing.expectEqual(JobState.aborting, (try registry.query_job(first.job)).state);
    const third = try registry.subscribe(request(4, 100), 4);
    try std.testing.expect(!third.shared);
    try std.testing.expect(third.job.token != first.job.token);
    try std.testing.expectError(error.JobNotRunning, registry.reserve_output(first.job, first.consumer, 1, 4));
    try registry.settle(first.job, .stopped, 5);
    try std.testing.expectEqual(Phase.uncertain, (try registry.query_consumer(second.consumer)).receipt.?.phase);
    try std.testing.expectEqual(Outcome.stopped, (try registry.query_job(first.job)).receipt.?.outcome);
}

test "credits sequences and output budget reject duplicate or overflowing accounting" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const sub = try registry.subscribe(request(1, 100), 0);
    try registry.start(sub.job, 0);
    try registry.declare_result_size(sub.job, 20, 0);
    try registry.grant_credit(sub.consumer, 0, 10, 0);
    try std.testing.expectError(error.InvalidGrantSequence, registry.grant_credit(sub.consumer, 0, 1, 0));
    try std.testing.expectError(error.InvalidCredit, registry.grant_credit(sub.consumer, 1, 1, 0));
    const output = try registry.reserve_output(sub.job, sub.consumer, 20, 0);
    try std.testing.expectError(error.OutputPending, registry.reserve_output(sub.job, sub.consumer, 1, 0));
    try std.testing.expectError(error.InvalidCredit, registry.grant_credit(sub.consumer, 1, 1, 0));
    try registry.deliver_output(output, 0);
    try std.testing.expectError(error.InvalidReservation, registry.deliver_output(output, 0));
    try std.testing.expectError(error.OutputBudgetExceeded, registry.reserve_output(sub.job, sub.consumer, 1, 0));
    const consumer = try registry.find_consumer(sub.consumer);
    consumer.data.next_output_sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceOverflow, registry.reserve_output(sub.job, sub.consumer, 1, 0));
    consumer.data.next_grant_sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceOverflow, registry.grant_credit(sub.consumer, std.math.maxInt(u64), 1, 0));
}

test "maximum byte credit and stale epochs cannot overflow or deliver late output" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    var args = request(1, 100);
    args.output_budget = std.math.maxInt(u64);
    args.initial_credit = std.math.maxInt(u64);
    const sub = try registry.subscribe(args, 0);
    try registry.start(sub.job, 0);
    try registry.declare_result_size(sub.job, std.math.maxInt(u64), 0);
    try std.testing.expectError(error.InvalidCredit, registry.grant_credit(sub.consumer, 0, 1, 0));
    var stale = sub.job;
    stale.epoch += 1;
    try std.testing.expectError(error.StaleEpoch, registry.reserve_output(stale, sub.consumer, 1, 0));
    try std.testing.expectError(error.StaleEpoch, registry.settle(stale, .success, 0));
    const output = try registry.reserve_output(sub.job, sub.consumer, std.math.maxInt(u64), 0);
    var stale_output = output;
    stale_output.job = stale;
    try std.testing.expectError(error.StaleEpoch, registry.deliver_output(stale_output, 0));
    try registry.deliver_output(output, 0);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try registry.query_consumer(sub.consumer)).delivered_bytes);
    try registry.worker_loss(sub.job, 1);
    try std.testing.expectEqual(Phase.uncertain, (try registry.query_consumer(sub.consumer)).receipt.?.phase);
    try std.testing.expectError(error.JobNotRunning, registry.deliver_output(output, 1));
    try std.testing.expectError(error.JobNotQueued, registry.start(sub.job, 1));
}

test "duplicates capacities receipts and reclamation protect stale handles" {
    var registry = try Registry.init(std.testing.allocator, .{ .max_jobs = 1, .max_consumers = 2 });
    defer registry.deinit();
    const sub = try registry.subscribe(request(1, 100), 0);
    try std.testing.expectError(error.DuplicateConsumer, registry.subscribe(request(1, 100), 0));
    var unique = request(3, 100);
    unique.physical_key[0] = 1;
    try std.testing.expectError(error.JobCapacity, registry.subscribe(unique, 0));
    const second = try registry.subscribe(request(2, 100), 0);
    try std.testing.expectError(error.ConsumerCapacity, registry.subscribe(request(3, 100), 0));
    try std.testing.expectError(error.NotTerminal, registry.reclaim_consumer(sub.consumer));
    _ = try registry.cancel(sub.consumer, 1);
    _ = try registry.cancel(second.consumer, 1);
    try std.testing.expectError(error.DuplicateConsumer, registry.subscribe(request(1, 100), 1));
    try std.testing.expectError(error.ConsumersRetained, registry.reclaim_job(sub.job));
    try std.testing.expectEqual(Outcome.cancelled, (try registry.query_consumer(sub.consumer)).receipt.?.outcome);
    try registry.reclaim_consumer(sub.consumer);
    try registry.reclaim_consumer(second.consumer);
    try registry.reclaim_job(sub.job);
    const replacement = try registry.subscribe(request(1, 100), 2);
    try std.testing.expect(replacement.consumer.token != sub.consumer.token);
    try std.testing.expect(replacement.job.token != sub.job.token);
    try std.testing.expectError(error.UnknownConsumer, registry.cancel(sub.consumer, 2));
    try std.testing.expectError(error.UnknownJob, registry.start(sub.job, 2));
    try std.testing.expectError(error.ClockRegression, registry.cancel(replacement.consumer, 1));
}

test "settlement enforces absolute deadline and discards pending delivery" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const sub = try registry.subscribe(request(1, 10), 0);
    try registry.start(sub.job, 1);
    try registry.declare_result_size(sub.job, 5, 1);
    const pending = try registry.reserve_output(sub.job, sub.consumer, 5, 2);
    try registry.settle(sub.job, .success, 10);
    const receipt = (try registry.query_consumer(sub.consumer)).receipt.?;
    try std.testing.expectEqual(Outcome.deadline_exceeded, receipt.outcome);
    try std.testing.expectEqual(@as(u64, 0), receipt.delivered_bytes);
    try std.testing.expectError(error.JobNotRunning, registry.deliver_output(pending, 10));
    const queued = try registry.subscribe(request(2, 100), 10);
    try registry.worker_loss(queued.job, 11);
    try std.testing.expectEqual(Phase.not_started, (try registry.query_consumer(queued.consumer)).receipt.?.phase);
}

test "an expired final subscriber cannot revive running work before a sweep" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const original = try registry.subscribe(request(1, 5), 0);
    try registry.start(original.job, 0);
    try std.testing.expectError(error.DeadlineExpired, registry.subscribe(request(2, 50), 5));
    var events: [1]LeaveEvent = undefined;
    _ = try registry.expire(5, &events);
    try std.testing.expectEqual(Action.stop_requested, events[0].action);
    const replacement = try registry.subscribe(request(2, 50), 5);
    try std.testing.expect(!replacement.shared);
    try std.testing.expect(original.job.token != replacement.job.token);
}

test "pending output rejects success without changing state and drained output settles" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const sub = try registry.subscribe(request(1, 100), 0);
    try registry.start(sub.job, 1);
    try std.testing.expectError(error.ResultSizeUndeclared, registry.reserve_output(sub.job, sub.consumer, 5, 1));
    try registry.declare_result_size(sub.job, 5, 1);
    try std.testing.expectError(error.ResultSizeExceeded, registry.reserve_output(sub.job, sub.consumer, 6, 1));
    const pending = try registry.reserve_output(sub.job, sub.consumer, 5, 2);
    const before_consumer = try registry.query_consumer(sub.consumer);
    const before_job = try registry.query_job(sub.job);
    try std.testing.expectError(error.OutputPending, registry.settle(sub.job, .success, 3));
    try std.testing.expect(std.meta.eql(before_consumer, try registry.query_consumer(sub.consumer)));
    try std.testing.expect(std.meta.eql(before_job, try registry.query_job(sub.job)));
    try std.testing.expectEqual(@as(u64, 2), registry.last_time);
    try registry.deliver_output(pending, 2);
    try registry.settle(sub.job, .success, 3);
    const receipt = (try registry.query_consumer(sub.consumer)).receipt.?;
    try std.testing.expectEqual(Outcome.success, receipt.outcome);
    try std.testing.expectEqual(@as(u64, 5), receipt.delivered_bytes);
}

test "credit blocked subscriber must drain before shared job succeeds" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const first = try registry.subscribe(request(1, 100), 0);
    var blocked_args = request(2, 100);
    blocked_args.initial_credit = 0;
    const blocked = try registry.subscribe(blocked_args, 0);
    try registry.start(first.job, 1);
    try registry.declare_result_size(first.job, 5, 1);
    try registry.deliver_output(try registry.reserve_output(first.job, first.consumer, 5, 1), 1);
    try std.testing.expectError(error.InsufficientCredit, registry.reserve_output(blocked.job, blocked.consumer, 5, 1));
    try std.testing.expectError(error.ResultNotDrained, registry.settle(first.job, .success, 2));
    try std.testing.expectEqual(JobState.running, (try registry.query_job(first.job)).state);
    try std.testing.expect((try registry.query_consumer(first.consumer)).receipt == null);
    try std.testing.expect((try registry.query_consumer(blocked.consumer)).receipt == null);
    try registry.grant_credit(blocked.consumer, 0, 5, 1);
    const pending = try registry.reserve_output(blocked.job, blocked.consumer, 5, 1);
    try std.testing.expectError(error.OutputPending, registry.settle(first.job, .success, 2));
    try registry.deliver_output(pending, 1);
    try registry.settle(first.job, .success, 2);
    try std.testing.expectEqual(Outcome.success, (try registry.query_consumer(blocked.consumer)).receipt.?.outcome);
}

test "zero byte success needs an explicit immutable declaration" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const sub = try registry.subscribe(request(1, 100), 0);
    try std.testing.expectError(error.JobNotRunning, registry.declare_result_size(sub.job, 0, 0));
    try registry.start(sub.job, 1);
    try std.testing.expectError(error.ResultSizeUndeclared, registry.settle(sub.job, .success, 2));
    try registry.declare_result_size(sub.job, 0, 1);
    try std.testing.expectError(error.ResultSizeAlreadyDeclared, registry.declare_result_size(sub.job, 0, 1));
    try std.testing.expectError(error.ResultSizeAlreadyDeclared, registry.declare_result_size(sub.job, 1, 1));
    try std.testing.expectEqual(@as(?u64, 0), (try registry.query_job(sub.job)).expected_result_bytes);
    try std.testing.expectError(error.ResultSizeExceeded, registry.reserve_output(sub.job, sub.consumer, 1, 1));
    var stale = sub.job;
    stale.epoch += 1;
    try std.testing.expectError(error.StaleEpoch, registry.declare_result_size(stale, 0, 1));
    try registry.settle(sub.job, .success, 2);
    try std.testing.expectEqual(@as(u64, 0), (try registry.query_consumer(sub.consumer)).receipt.?.delivered_bytes);
}

test "cancelled and expired pending output cannot block another consumer drain" {
    var registry = try Registry.init(std.testing.allocator, .{});
    defer registry.deinit();
    const cancelled = try registry.subscribe(request(1, 100), 0);
    const expired = try registry.subscribe(request(2, 5), 0);
    const survivor = try registry.subscribe(request(3, 100), 0);
    try registry.start(survivor.job, 1);
    try registry.declare_result_size(survivor.job, 5, 1);
    _ = try registry.reserve_output(cancelled.job, cancelled.consumer, 5, 1);
    const expired_pending = try registry.reserve_output(expired.job, expired.consumer, 5, 1);
    try registry.deliver_output(try registry.reserve_output(survivor.job, survivor.consumer, 5, 1), 1);
    _ = try registry.cancel(cancelled.consumer, 2);
    try registry.settle(survivor.job, .success, 5);
    try std.testing.expectEqual(Outcome.cancelled, (try registry.query_consumer(cancelled.consumer)).receipt.?.outcome);
    try std.testing.expectEqual(Outcome.deadline_exceeded, (try registry.query_consumer(expired.consumer)).receipt.?.outcome);
    try std.testing.expectEqual(@as(u64, 0), (try registry.query_consumer(expired.consumer)).receipt.?.delivered_bytes);
    try std.testing.expectEqual(Outcome.success, (try registry.query_consumer(survivor.consumer)).receipt.?.outcome);
    try std.testing.expectError(error.JobNotRunning, registry.deliver_output(expired_pending, 5));
}

fn allocation_check(allocator: std.mem.Allocator) !void {
    var registry = try Registry.init(allocator, .{ .max_jobs = 2, .max_consumers = 3 });
    defer registry.deinit();
}

test "invalid capacities reject before allocation and partial allocations clean up" {
    try std.testing.expectError(error.InvalidOptions, Registry.init(std.testing.allocator, .{ .max_jobs = std.math.maxInt(usize) }));
    try std.testing.expectError(error.InvalidOptions, Registry.init(std.testing.allocator, .{ .max_consumers = 0 }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocation_check, .{});
}

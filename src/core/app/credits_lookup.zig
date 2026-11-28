//! Runs the `/credits` lookup off the input loop as a `std.Io` task. One
//! lookup runs at a time. The event loop takes its result when it finishes,
//! and shutdown cancels it and awaits its bounded requests.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("../auth/secret.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");

pub const Start = enum { started, busy };

const renewal_failed_message = "Could not renew the sign-in to check credits. Try again.";
const renewal_sign_in_message = "Your sign-in has expired. Run /login, then check credits again.";

/// Renews a refreshable credential that is past its refresh deadline before
/// the lookup asks for credits.
pub const Renewal = struct {
    transport: oauth_transport.Provider,
    source: credentials.Source,
    account_id: ?[]const u8,
};

pub const Result = struct {
    snapshot: output_contracts.CreditsSnapshot,
    /// The credential the lookup renewed, for the caller to adopt.
    renewed: ?credentials.Credential = null,
    /// The caller's epoch when this lookup's request started.
    epoch: u32 = 0,

    /// Releases everything with `std.heap.c_allocator`, which allocated it.
    pub fn deinit(self: *Result) void {
        self.snapshot.deinit(std.heap.c_allocator);
        if (self.renewed) |*credential| credential.deinit(std.heap.c_allocator);
        self.* = undefined;
    }
};

pub const Lookup = struct {
    task: ?*Task = null,
    /// The epoch the caller passed when the running lookup's task started.
    epoch: u32 = 0,

    /// Copies `input` and `renewal`, then fetches in a `std.Io` task. Returns
    /// `.busy` while an earlier lookup runs. The result carries `epoch`, so
    /// the caller can tell a reply for an earlier credential.
    /// `provider.context` and the renewal transport's context must outlive
    /// the lookup.
    pub fn start(
        self: *Lookup,
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
        renewal: ?Renewal,
        epoch: u32,
    ) !Start {
        if (self.task != null) return .busy;
        self.task = try Task.start(provider, input, renewal);
        self.epoch = epoch;
        return .started;
    }

    /// Returns the finished result once, and null while the lookup runs or
    /// when none started. The caller owns the result.
    pub fn take(self: *Lookup) ?Result {
        const task = self.task orelse return null;
        if (!task.done.isSet()) return null;
        self.task = null;
        var result = task.finish();
        result.epoch = self.epoch;
        return result;
    }

    /// The running lookup's wake count, or 0 when none runs. A waiter reads
    /// it before it looks at what it waits for and passes it to
    /// `awaitFinish`, so a finish or a `wake` after that look still ends
    /// the wait.
    pub fn wakeCount(self: *const Lookup) u32 {
        const task = self.task orelse return 0;
        return task.wake_count.load(.acquire);
    }

    /// Waits at most `wait_ms` for the running lookup to finish or for a
    /// `wake`, and returns at once when either came since `seen` was read
    /// or when none runs. A wait can end early, so the caller checks the
    /// lookup and the time again.
    pub fn awaitFinish(self: *Lookup, seen: u32, wait_ms: i64) std.Io.Cancelable!void {
        const task = self.task orelse return;
        _ = task.sleepers.fetchAdd(1, .monotonic);
        defer _ = task.sleepers.fetchSub(1, .monotonic);
        try io_mod.getIo().futexWaitTimeout(u32, &task.wake_count.raw, seen, .{ .duration = .{
            .raw = .fromMilliseconds(wait_ms),
            .clock = .awake,
        } });
    }

    /// Ends every `awaitFinish` on the running lookup at once, so its caller
    /// looks again, such as at a cancel flag it set before this call.
    pub fn wake(self: *Lookup) void {
        const task = self.task orelse return;
        task.wakeWaiters();
    }

    /// `deinit` for process exit, which never waits. A lookup still running,
    /// such as one renewing the sign-in, which is never cut off
    /// (`oauth_transport.Request` `outlives_cancel`), is cancelled and left to
    /// end with the process. It holds only its own copies and static providers.
    pub fn leaveForExit(self: *Lookup) void {
        const task = self.task orelse return;
        if (task.done.isSet()) return self.deinit();
        self.task = null;
        task.cancel.store(true, .seq_cst);
        debug_trace.logf("credits", "lookup left running reason=process_exit", .{});
    }

    /// Cancels a running lookup and waits for its bounded requests to stop.
    pub fn deinit(self: *Lookup) void {
        const task = self.task orelse return;
        self.task = null;
        if (!task.done.isSet()) {
            debug_trace.logf("credits", "lookup dropped reason=shutdown", .{});
        }
        task.cancel.store(true, .seq_cst);
        var result = task.finish();
        result.deinit();
    }
};

const Task = struct {
    provider: gateway_provider.CreditsProvider,
    credential: ?[]u8,
    credential_source: ?credentials.Source,
    tenant: ?[]u8,
    renewal: ?Renewal,
    renewal_account_id: ?[]u8,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Set once `result` is final.
    done: std.Io.Event = .unset,
    /// Changes when the task finishes and on each `Lookup.wake`; a waiter
    /// sleeps on it (`Lookup.awaitFinish`).
    wake_count: std.atomic.Value(u32) = .init(0),
    /// How many threads sleep in `Lookup.awaitFinish`; a test acts once one
    /// does.
    sleepers: std.atomic.Value(u32) = .init(0),
    result: Result = .{ .snapshot = .{} },
    future: std.Io.Future(void) = undefined,

    fn start(
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
        renewal: ?Renewal,
    ) !*Task {
        const alloc = std.heap.c_allocator;
        const task = try alloc.create(Task);
        errdefer alloc.destroy(task);
        const credential = if (input.credential) |value| try alloc.dupe(u8, value) else null;
        errdefer if (credential) |value| secret.zeroAndFree(alloc, value);
        const tenant = if (input.tenant) |value| try alloc.dupe(u8, value) else null;
        errdefer if (tenant) |value| alloc.free(value);
        const account_id = if (renewal) |value| if (value.account_id) |id| try alloc.dupe(u8, id) else null else null;
        errdefer if (account_id) |id| alloc.free(id);
        task.* = .{
            .provider = provider,
            .credential = credential,
            .credential_source = input.credential_source,
            .tenant = tenant,
            .renewal = renewal,
            .renewal_account_id = account_id,
        };
        task.future = try io_mod.getIo().concurrent(run, .{task});
        return task;
    }

    fn run(self: *Task) void {
        const alloc = std.heap.c_allocator;
        var credential: ?[]const u8 = self.credential;
        var tenant: ?[]const u8 = self.tenant;
        if (self.renewal) |renewal| {
            var transport: oauth_transport.Cancellable = .{ .inner = renewal.transport, .cancel_flag = &self.cancel };
            const renewed = auth_runtime.refreshCredentialForAccount(
                transport.provider(),
                alloc,
                renewal.source,
                .if_needed,
                self.renewal_account_id,
                null,
            ) catch |err| {
                debug_trace.logf("credits", "lookup could not renew source={t} err={s}", .{ renewal.source, @errorName(err) });
                const message = if (auth_runtime.classifyCredentialFailure(renewal.source, err).requiresSignIn())
                    renewal_sign_in_message
                else
                    renewal_failed_message;
                self.result.snapshot = .{ .err_message = alloc.dupe(u8, message) catch null };
                self.finished();
                return;
            };
            if (renewed) |value| {
                self.result.renewed = value;
                credential = value.token;
                tenant = value.gatewayTeam();
            }
        }
        self.result.snapshot = self.provider.fetch(alloc, .{
            .credential = credential,
            .credential_source = self.credential_source,
            .tenant = tenant,
            .cancel_flag = &self.cancel,
        });
        self.finished();
    }

    fn finished(self: *Task) void {
        self.done.set(io_mod.getIo());
        self.wakeWaiters();
    }

    fn wakeWaiters(self: *Task) void {
        _ = self.wake_count.fetchAdd(1, .release);
        io_mod.getIo().futexWake(u32, &self.wake_count.raw, std.math.maxInt(u32));
    }

    /// Awaits the task, frees it, and returns its result.
    fn finish(self: *Task) Result {
        self.future.await(io_mod.getIo());
        const result = self.result;
        const alloc = std.heap.c_allocator;
        if (self.credential) |value| secret.zeroAndFree(alloc, value);
        if (self.tenant) |value| alloc.free(value);
        if (self.renewal_account_id) |id| alloc.free(id);
        alloc.destroy(self);
        return result;
    }
};

const HeldCredits = @import("credits_lookup_testing.zig").HeldCredits;

fn takeWhenDone(lookup: *Lookup) Result {
    while (true) {
        if (lookup.take()) |result| return result;
        std.Thread.yield() catch {};
    }
}

test "credits lookup hands over its finished snapshot once" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: HeldCredits = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    var credential = "credential".*;
    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{
        .credential = &credential,
        .tenant = "tenant",
    }, null, 0));
    // The lookup owns copies, so the caller's buffers may change at once.
    @memset(&credential, 'x');
    try std.testing.expect(lookup.take() == null);

    fake.release();
    var result = takeWhenDone(&lookup);
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.snapshot.balance.?);
    try std.testing.expect(result.renewed == null);
    try std.testing.expect(fake.saw_input.load(.seq_cst));
    try std.testing.expect(lookup.take() == null);
}

test "credits lookup reports busy while one runs" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: HeldCredits = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null, 0));
    try std.testing.expectEqual(Start.busy, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null, 0));

    fake.release();
    var result = takeWhenDone(&lookup);
    result.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.seq_cst));
    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null, 0));
}

test "credits lookup wakes a waiter when it finishes, and a wait with none running returns at once" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const wait_ms: i64 = 5_000;
    var fake: HeldCredits = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    var started_ms = io_mod.awakeMilliTimestamp();
    try lookup.awaitFinish(lookup.wakeCount(), wait_ms);
    try std.testing.expect(io_mod.awakeMilliTimestamp() - started_ms < @divTrunc(wait_ms, 2));

    _ = try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null, 0);
    const seen = lookup.wakeCount();
    const releaser = try std.Thread.spawn(.{}, HeldCredits.releaseOnceWaiting, .{ &fake, &lookup.task.?.sleepers, 2 * wait_ms });
    started_ms = io_mod.awakeMilliTimestamp();
    try lookup.awaitFinish(seen, wait_ms);
    const waited_ms = io_mod.awakeMilliTimestamp() - started_ms;
    releaser.join();

    var result = lookup.take() orelse return error.TestExpectedFinished;
    result.deinit();
    try std.testing.expect(waited_ms < @divTrunc(wait_ms, 2));
}

test "credits lookup at exit is cancelled and left running instead of waited for" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: HeldCredits = .{ .ignores_cancel = true };
    var lookup: Lookup = .{};

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null, 0));
    while (fake.calls.load(.seq_cst) == 0) std.Thread.yield() catch {};
    const task = lookup.task.?;
    lookup.leaveForExit();
    try std.testing.expect(lookup.task == null);
    try std.testing.expect(task.cancel.load(.seq_cst));
    try std.testing.expect(!task.done.isSet());

    // The process would end here; the test lets the task finish and frees it.
    fake.release();
    var result = task.finish();
    result.deinit();
}

test "credits lookup shutdown cancels a stalled fetch and waits for it" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: HeldCredits = .{};
    var lookup: Lookup = .{};

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null, 0));
    while (fake.calls.load(.seq_cst) == 0) std.Thread.yield() catch {};
    lookup.deinit();

    try std.testing.expect(lookup.task == null);
    try std.testing.expect(!fake.released.load(.seq_cst));
}

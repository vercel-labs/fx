//! Runs the `/credits` lookup off the input loop. One lookup runs at a time.
//! The event loop takes its snapshot when it finishes, and shutdown cancels it
//! and waits for its bounded fetch to stop.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const secret = @import("../auth/secret.zig");
const credentials = @import("../auth/credentials.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");

pub const Start = enum { started, busy };

pub const Lookup = struct {
    task: ?*Task = null,

    /// Copies `input` and fetches on a worker thread. Returns `.busy` while an
    /// earlier lookup runs. `provider.context` must outlive the lookup.
    pub fn start(
        self: *Lookup,
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
    ) !Start {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        if (self.task != null) return .busy;
        self.task = try Task.start(provider, input);
        return .started;
    }

    /// Returns the finished snapshot once, and null while the lookup runs or
    /// when none started. The caller owns the snapshot, which is allocated
    /// with `std.heap.c_allocator`.
    pub fn take(self: *Lookup) ?output_contracts.CreditsSnapshot {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task.finish();
    }

    /// Cancels a running lookup and waits for its bounded fetch to stop.
    pub fn deinit(self: *Lookup) void {
        const task = self.task orelse return;
        self.task = null;
        if (!task.done.load(.acquire)) {
            debug_trace.logf("credits", "lookup dropped reason=shutdown", .{});
        }
        task.cancel.store(true, .seq_cst);
        var snapshot = task.finish();
        snapshot.deinit(std.heap.c_allocator);
    }
};

const Task = struct {
    provider: gateway_provider.CreditsProvider,
    credential: ?[]u8,
    credential_source: ?credentials.Source,
    tenant: ?[]u8,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    snapshot: output_contracts.CreditsSnapshot = .{},
    thread: std.Thread = undefined,

    fn start(
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
    ) !*Task {
        const alloc = std.heap.c_allocator;
        const task = try alloc.create(Task);
        errdefer alloc.destroy(task);
        const credential = if (input.credential) |value| try alloc.dupe(u8, value) else null;
        errdefer if (credential) |value| secret.zeroAndFree(alloc, value);
        const tenant = if (input.tenant) |value| try alloc.dupe(u8, value) else null;
        errdefer if (tenant) |value| alloc.free(value);
        task.* = .{
            .provider = provider,
            .credential = credential,
            .credential_source = input.credential_source,
            .tenant = tenant,
        };
        task.thread = try std.Thread.spawn(.{}, run, .{task});
        return task;
    }

    fn run(self: *Task) void {
        self.snapshot = self.provider.fetch(std.heap.c_allocator, .{
            .credential = self.credential,
            .credential_source = self.credential_source,
            .tenant = self.tenant,
            .cancel_flag = &self.cancel,
        });
        self.done.store(true, .release);
    }

    /// Waits for the thread, frees the task, and returns its snapshot.
    fn finish(self: *Task) output_contracts.CreditsSnapshot {
        self.thread.join();
        const snapshot = self.snapshot;
        const alloc = std.heap.c_allocator;
        if (self.credential) |value| secret.zeroAndFree(alloc, value);
        if (self.tenant) |value| alloc.free(value);
        alloc.destroy(self);
        return snapshot;
    }
};

const TestProvider = struct {
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    saw_input: std.atomic.Value(bool) = .init(false),

    fn provider(self: *TestProvider) gateway_provider.CreditsProvider {
        return .{ .context = self, .fetch_fn = fetch };
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: std.mem.Allocator,
        input: gateway_provider.CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        const self: *TestProvider = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.saw_input.store(
            std.mem.eql(u8, input.credential orelse "", "credential") and
                std.mem.eql(u8, input.tenant orelse "", "tenant") and
                input.cancel_flag != null,
            .seq_cst,
        );
        // Stands in for a slow endpoint until the test releases it or the
        // lookup is cancelled.
        while (!self.release.load(.seq_cst) and !input.cancel_flag.?.load(.seq_cst)) {
            std.Thread.yield() catch {};
        }
        if (input.cancel_flag.?.load(.seq_cst)) {
            return .{ .err_message = alloc.dupe(u8, "cancelled") catch null };
        }
        return .{ .balance = alloc.dupe(u8, "42") catch null };
    }
};

fn takeWhenDone(lookup: *Lookup) output_contracts.CreditsSnapshot {
    while (true) {
        if (lookup.take()) |snapshot| return snapshot;
        std.Thread.yield() catch {};
    }
}

test "credits lookup hands over its finished snapshot once" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: TestProvider = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    var credential = "credential".*;
    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{
        .credential = &credential,
        .tenant = "tenant",
    }));
    // The lookup owns copies, so the caller's buffers may change at once.
    @memset(&credential, 'x');
    try std.testing.expect(lookup.take() == null);

    fake.release.store(true, .seq_cst);
    var snapshot = takeWhenDone(&lookup);
    defer snapshot.deinit(std.heap.c_allocator);
    try std.testing.expectEqualStrings("42", snapshot.balance.?);
    try std.testing.expect(fake.saw_input.load(.seq_cst));
    try std.testing.expect(lookup.take() == null);
}

test "credits lookup reports busy while one runs" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: TestProvider = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }));
    try std.testing.expectEqual(Start.busy, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }));

    fake.release.store(true, .seq_cst);
    var snapshot = takeWhenDone(&lookup);
    snapshot.deinit(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.seq_cst));
    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }));
}

test "credits lookup shutdown cancels a stalled fetch and waits for it" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: TestProvider = .{};
    var lookup: Lookup = .{};

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }));
    while (fake.calls.load(.seq_cst) == 0) std.Thread.yield() catch {};
    lookup.deinit();

    try std.testing.expect(lookup.task == null);
    try std.testing.expect(!fake.release.load(.seq_cst));
}

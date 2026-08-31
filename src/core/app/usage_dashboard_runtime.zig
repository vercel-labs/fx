const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_usage_runtime = @import("../session/profile_usage_runtime.zig");
const usage_recovery = @import("../session/usage_recovery.zig");
const usage_report = @import("../session/usage_report.zig");

const Allocator = std.mem.Allocator;

const rolling_scopes = [_]usage_report.Scope{
    .days_30,
    .days_7,
    .hours_24,
};

pub const SnapshotSet = struct {
    snapshots: [rolling_scopes.len]usage_report.Snapshot,

    pub fn deinit(self: *SnapshotSet, alloc: Allocator) void {
        for (&self.snapshots) |*snapshot| snapshot.deinit(alloc);
        self.* = undefined;
    }

    fn get(self: *const SnapshotSet, scope: usage_report.Scope) ?*const usage_report.Snapshot {
        for (rolling_scopes, 0..) |candidate, index| {
            if (candidate == scope) return &self.snapshots[index];
        }
        return null;
    }
};

pub const Provider = struct {
    context: *anyopaque,
    load: *const fn (
        context: *anyopaque,
        alloc: Allocator,
        home_path: []const u8,
        snapshot_time_ms: i64,
        cancel_requested: *const std.atomic.Value(bool),
    ) anyerror!SnapshotSet,
};

pub fn profileProvider(runtime: *profile_usage_runtime.Runtime) Provider {
    return .{
        .context = runtime,
        .load = loadProfileSnapshots,
    };
}

const LoadState = enum {
    idle,
    loading,
    ready,
    failed,
};

pub const Transition = enum {
    none,
    ready,
    failed,
};

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: LoadState = .idle,
    completion_pending: bool = false,
    cache: ?SnapshotSet = null,
    last_error: ?anyerror = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    /// Fieldwise initialization avoids retaining undefined cache payloads in
    /// a static release-binary template.
    pub fn initInto(storage: *Self, alloc: Allocator) void {
        comptime {
            if (std.meta.fields(Self).len != 8) {
                @compileError("update Runtime.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.alloc = alloc;
        storage.mutex = .init;
        storage.thread = null;
        storage.state = .idle;
        storage.completion_pending = false;
        storage.cache = null;
        storage.last_error = null;
        storage.cancel_requested = .init(false);
    }

    pub fn deinit(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
        if (self.cache) |*cache| cache.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn requestRefresh(
        self: *Self,
        provider: Provider,
        home_path: []const u8,
        snapshot_time_ms: i64,
    ) !bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.state == .loading) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.state = .loading;
        self.completion_pending = false;
        self.last_error = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);

        const owned_home = self.alloc.dupe(u8, home_path) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = err;
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        errdefer self.alloc.free(owned_home);
        self.thread = std.Thread.spawn(
            .{},
            loadThreadMain,
            .{ self, provider, owned_home, snapshot_time_ms },
        ) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = err;
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        return true;
    }

    pub fn snapshot(
        self: *Self,
        alloc: Allocator,
        scope: usage_report.Scope,
    ) Allocator.Error!?usage_report.Snapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const cached = if (self.cache) |*cache| cache.get(scope) else null;
        return if (cached) |value| try value.dupe(alloc) else null;
    }

    pub fn pollTransition(self: *Self) Transition {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.completion_pending) return .none;
        self.completion_pending = false;
        return if (self.last_error == null) .ready else .failed;
    }

    fn isLoading(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .loading;
    }

    pub fn lastError(self: *Self) ?anyerror {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.last_error;
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = self.state != .loading and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| {
            handle.join();
            self.mutex.lockUncancelable(io_mod.getIo());
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn loadThreadMain(
        self: *Self,
        provider: Provider,
        owned_home: []u8,
        snapshot_time_ms: i64,
    ) void {
        defer self.alloc.free(owned_home);
        const loaded = provider.load(
            provider.context,
            self.alloc,
            owned_home,
            snapshot_time_ms,
            &self.cancel_requested,
        ) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = err;
            self.mutex.unlock(io_mod.getIo());
            return;
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.cache) |*cache| cache.deinit(self.alloc);
        self.cache = loaded;
        self.state = .ready;
        self.last_error = null;
        self.mutex.unlock(io_mod.getIo());
    }
};

test "usage dashboard in-place initialization preserves idle state" {
    var runtime: Runtime = undefined;
    Runtime.initInto(&runtime, std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.state == .idle);
    try std.testing.expect(!runtime.completion_pending);
    try std.testing.expect(runtime.cache == null);
    try std.testing.expect(runtime.last_error == null);
    try std.testing.expect(!runtime.cancel_requested.load(.seq_cst));
}

fn loadProfileSnapshots(
    context: *anyopaque,
    alloc: Allocator,
    home_path: []const u8,
    snapshot_time_ms: i64,
    cancel_requested: *const std.atomic.Value(bool),
) !SnapshotSet {
    const runtime: *profile_usage_runtime.Runtime = @ptrCast(@alignCast(context));
    var recovery = try usage_recovery.collectFromHomeConservativeCancelable(
        alloc,
        home_path,
        cancel_requested,
    );
    defer recovery.deinit(alloc);

    if (cancel_requested.load(.seq_cst)) return error.Cancelled;
    return .{ .snapshots = try runtime.rollingSnapshots(
        alloc,
        snapshot_time_ms,
        .{
            .facts = recovery.facts,
            .incidents = recovery.incidents,
            .pending = recovery.pending,
            .unknown_pending = recovery.unknown_pending,
        },
    ) };
}

test "usage dashboard loads once off thread and serves every rolling scope" {
    const Gate = struct {
        allow_finish: std.atomic.Value(bool) = .init(false),
        loads: std.atomic.Value(usize) = .init(0),

        fn load(
            context: *anyopaque,
            alloc: Allocator,
            _: []const u8,
            snapshot_time_ms: i64,
            cancel_requested: *const std.atomic.Value(bool),
        ) !SnapshotSet {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.loads.fetchAdd(1, .seq_cst);
            while (!self.allow_finish.load(.seq_cst)) {
                if (cancel_requested.load(.seq_cst)) return error.Cancelled;
                io_mod.sleep(std.time.ns_per_ms);
            }
            var snapshots: [rolling_scopes.len]usage_report.Snapshot = undefined;
            var initialized: usize = 0;
            errdefer for (snapshots[0..initialized]) |*snapshot| snapshot.deinit(alloc);
            for (rolling_scopes, 0..) |scope, index| {
                snapshots[index] = .{
                    .scope = scope,
                    .snapshot_time_ms = snapshot_time_ms,
                    .window_start_ms = 0,
                    .coverage_started_at_ms = 0,
                    .coverage = .full,
                    .completeness = .complete,
                    .totals = null,
                    .models = try alloc.alloc(usage_report.ModelUsage, 0),
                };
                initialized += 1;
            }
            return .{ .snapshots = snapshots };
        }
    };

    var gate = Gate{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expect(try runtime.requestRefresh(.{
        .context = &gate,
        .load = Gate.load,
    }, "/tmp", 100));
    try std.testing.expect(runtime.isLoading());
    try std.testing.expect(!(try runtime.requestRefresh(.{
        .context = &gate,
        .load = Gate.load,
    }, "/tmp", 100)));

    gate.allow_finish.store(true, .seq_cst);
    var remaining_ms: usize = 5000;
    while (runtime.pollTransition() == .none and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(remaining_ms > 0);
    try std.testing.expectEqual(@as(usize, 1), gate.loads.load(.seq_cst));

    for (rolling_scopes) |scope| {
        var snapshot = (try runtime.snapshot(std.testing.allocator, scope)).?;
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqual(scope, snapshot.scope);
        try std.testing.expectEqual(@as(i64, 100), snapshot.snapshot_time_ms);
    }
}

test "usage dashboard cancellation joins a loading worker" {
    const Gate = struct {
        observed_cancel: std.atomic.Value(bool) = .init(false),

        fn load(
            context: *anyopaque,
            _: Allocator,
            _: []const u8,
            _: i64,
            cancel_requested: *const std.atomic.Value(bool),
        ) !SnapshotSet {
            const self: *@This() = @ptrCast(@alignCast(context));
            while (!cancel_requested.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
            self.observed_cancel.store(true, .seq_cst);
            return error.Cancelled;
        }
    };

    var gate = Gate{};
    var runtime = Runtime.init(std.testing.allocator);
    try std.testing.expect(try runtime.requestRefresh(.{
        .context = &gate,
        .load = Gate.load,
    }, "/tmp", 100));
    runtime.deinit();
    try std.testing.expect(gate.observed_cancel.load(.seq_cst));
}

test "usage dashboard reports home-copy allocation failure without starting work" {
    const Unused = struct {
        fn load(
            _: *anyopaque,
            _: Allocator,
            _: []const u8,
            _: i64,
            _: *const std.atomic.Value(bool),
        ) !SnapshotSet {
            return error.TestUnexpectedResult;
        }
    };

    var context: u8 = 0;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var runtime = Runtime.init(failing.allocator());
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.requestRefresh(.{
            .context = &context,
            .load = Unused.load,
        }, "/tmp", 100),
    );
    try std.testing.expectEqual(Transition.failed, runtime.pollTransition());
    runtime.deinit();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

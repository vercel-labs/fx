const std = @import("std");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;
const max_pending: usize = 64;

pub const Error = error{
    OutOfMemory,
    CapacityExceeded,
    CommitFailed,
    RegistryClosed,
    RequestConflict,
    RequestNotFound,
    StaleRequest,
    WrongChild,
};

pub const ResolveResult = enum { accepted, rejected };

pub const WorkerRoute = struct {
    context: *anyopaque,
    submit_fn: *const fn (
        *anyopaque,
        u64,
        permission_request.OwnedPermissionResponse,
        ?worker_runtime.WorkerRuntime.PermissionCommit,
    ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult,
    cancel_fn: *const fn (*anyopaque) void,
    pin_fn: *const fn (*anyopaque) bool,
    release_fn: *const fn (*anyopaque) void,

    fn eql(self: WorkerRoute, other: WorkerRoute) bool {
        return self.context == other.context and
            self.submit_fn == other.submit_fn and
            self.cancel_fn == other.cancel_fn and
            self.pin_fn == other.pin_fn and
            self.release_fn == other.release_fn;
    }

    fn submit(
        self: WorkerRoute,
        request_id: u64,
        response: permission_request.OwnedPermissionResponse,
        commit: ?worker_runtime.WorkerRuntime.PermissionCommit,
    ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
        return self.submit_fn(self.context, request_id, response, commit);
    }

    fn cancel(self: WorkerRoute) void {
        self.cancel_fn(self.context);
    }

    fn pin(self: WorkerRoute) bool {
        return self.pin_fn(self.context);
    }

    fn release(self: WorkerRoute) void {
        self.release_fn(self.context);
    }
};

const Binding = struct {
    request_id: []u8,
    child_id: []u8,
    root_id: []u8,
    work_id: []u8,
    request: permission_request.OwnedPermissionRequest,
    worker: WorkerRoute,
    worker_request_id: u64,

    fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        alloc.free(self.work_id);
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

pub const PendingRequest = struct {
    request_id: []u8,
    child_id: []u8,
    request: permission_request.OwnedPermissionRequest,

    pub fn deinit(self: *PendingRequest, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

pub const Registry = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    bindings: std.ArrayList(Binding) = .empty,
    pending_revision: u64 = 0,
    closed: bool = false,

    pub fn pendingRevision(self: *Registry) u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.pending_revision;
    }

    pub fn firstPendingRequest(
        self: *Registry,
        alloc: Allocator,
        root_id: []const u8,
    ) Error!?PendingRequest {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        for (self.bindings.items) |*binding| {
            if (!std.mem.eql(u8, binding.root_id, root_id)) continue;
            const request_id = try alloc.dupe(u8, binding.request_id);
            errdefer alloc.free(request_id);
            const child_id = try alloc.dupe(u8, binding.child_id);
            errdefer alloc.free(child_id);
            const request = permission_request.OwnedPermissionRequest.dupe(
                alloc,
                binding.request.view(),
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CommitFailed,
            };
            return .{
                .request_id = request_id,
                .child_id = child_id,
                .request = request,
            };
        }
        return null;
    }

    pub fn registerTool(
        self: *Registry,
        stable_request_id: []const u8,
        child_id: []const u8,
        root_id: []const u8,
        work_id: []const u8,
        request: permission_request.PermissionRequest,
        _: []const types.PermissionGrant,
        worker: WorkerRoute,
        _: i64,
    ) Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        if (self.find(stable_request_id)) |index| {
            const existing = self.bindings.items[index];
            if (!std.mem.eql(u8, existing.child_id, child_id) or
                !std.mem.eql(u8, existing.work_id, work_id) or
                !existing.worker.eql(worker) or
                existing.worker_request_id != request.id)
            {
                return error.RequestConflict;
            }
            return;
        }
        if (self.bindings.items.len >= max_pending) return error.CapacityExceeded;
        var projected = request;
        projected.origin = .{ .subagent = child_id };
        const owned_request = permission_request.OwnedPermissionRequest.dupe(
            self.alloc,
            projected,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
        errdefer {
            var value = owned_request;
            value.deinit(self.alloc);
        }
        const owned_request_id = try self.alloc.dupe(u8, stable_request_id);
        errdefer self.alloc.free(owned_request_id);
        const owned_child_id = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child_id);
        const owned_root_id = try self.alloc.dupe(u8, root_id);
        errdefer self.alloc.free(owned_root_id);
        const owned_work_id = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned_work_id);
        try self.bindings.append(self.alloc, .{
            .request_id = owned_request_id,
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .work_id = owned_work_id,
            .request = owned_request,
            .worker = worker,
            .worker_request_id = request.id,
        });
        self.pending_revision +|= 1;
    }

    pub fn resolve(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        decision: types.ToolPermissionDecision,
        feedback: ?[]const u8,
        _: i64,
    ) Error!ResolveResult {
        const owned_feedback = if (feedback) |value|
            try self.alloc.dupe(u8, value)
        else
            null;
        var feedback_owned = owned_feedback != null;
        errdefer if (feedback_owned) self.alloc.free(owned_feedback.?);

        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.closed) {
            self.mutex.unlock(io_mod.getIo());
            return error.RegistryClosed;
        }
        const index = self.find(request_id) orelse {
            self.mutex.unlock(io_mod.getIo());
            return error.RequestNotFound;
        };
        const binding = &self.bindings.items[index];
        if (!std.mem.eql(u8, binding.child_id, child_id)) {
            self.mutex.unlock(io_mod.getIo());
            return error.WrongChild;
        }
        if (!binding.worker.pin()) {
            var removed = self.bindings.orderedRemove(index);
            self.pending_revision +|= 1;
            self.mutex.unlock(io_mod.getIo());
            defer removed.deinit(self.alloc);
            if (feedback_owned) {
                self.alloc.free(owned_feedback.?);
                feedback_owned = false;
            }
            return .rejected;
        }
        var removed = self.bindings.orderedRemove(index);
        self.pending_revision +|= 1;
        self.mutex.unlock(io_mod.getIo());
        defer removed.deinit(self.alloc);
        defer removed.worker.release();

        const submission = removed.worker.submit(
            removed.worker_request_id,
            permission_request.OwnedPermissionResponse.init(
                self.alloc,
                decision,
                owned_feedback,
            ),
            .{ .context = self, .commit_fn = commitNoop },
        ) catch |err| {
            feedback_owned = false;
            removed.worker.cancel();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PermissionCapacityExceeded => error.CapacityExceeded,
                error.PermissionCommitFailed => error.CommitFailed,
            };
        };
        feedback_owned = false;
        if (submission != .accepted) return .rejected;
        return .accepted;
    }

    pub fn invalidateChild(
        self: *Registry,
        child_id: []const u8,
    ) Error!usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var changed: usize = 0;
        var index = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            if (!std.mem.eql(u8, self.bindings.items[index].child_id, child_id)) continue;
            var removed = self.bindings.orderedRemove(index);
            removed.worker.cancel();
            removed.deinit(self.alloc);
            changed += 1;
        }
        if (changed > 0) self.pending_revision +|= 1;
        return changed;
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        for (self.bindings.items) |*binding| {
            binding.worker.cancel();
            binding.deinit(self.alloc);
        }
        self.bindings.deinit(self.alloc);
        self.mutex.unlock(io_mod.getIo());
        self.* = undefined;
    }

    fn find(self: *Registry, request_id: []const u8) ?usize {
        for (self.bindings.items, 0..) |binding, index| {
            if (std.mem.eql(u8, binding.request_id, request_id)) return index;
        }
        return null;
    }

    fn commitNoop(_: *anyopaque) error{
        OutOfMemory,
        PermissionCapacityExceeded,
        PermissionCommitFailed,
    }!void {}
};

pub fn preparedRequestFingerprint(
    request: permission_request.PermissionRequest,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.approval.v1\x00");
    hashString(&hash, request.label);
    hashOptional(&hash, request.explanation);
    hashOptional(&hash, request.tool_arguments_preview);
    hashOptional(&hash, request.command);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub fn stableApprovalId(
    child_id: []const u8,
    work_id: []const u8,
    prepared: [32]u8,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.approval-id.v1\x00");
    hashString(&hash, child_id);
    hashString(&hash, work_id);
    hash.update(&prepared);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hash.update(&length);
    hash.update(value);
}

fn hashOptional(hash: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    if (value) |text| hashString(hash, text) else hash.update("none\x00");
}

test "approval identity is deterministic" {
    const request = permission_request.PermissionRequest{ .label = "shell.run" };
    const prepared = preparedRequestFingerprint(request);
    try std.testing.expectEqual(
        stableApprovalId("child", "work", prepared),
        stableApprovalId("child", "work", prepared),
    );
}

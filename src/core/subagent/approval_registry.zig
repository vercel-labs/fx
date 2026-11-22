const std = @import("std");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;
pub const max_pending: usize = 64;

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
    /// The exact call the subagent's approval is for, owned like the request.
    call: types.ToolCall,
    /// Whether the request's note to its parent was posted (`markNoted`).
    noted: bool = false,
    worker: WorkerRoute,
    worker_request_id: u64,

    fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        alloc.free(self.work_id);
        self.request.deinit(alloc);
        freeCall(alloc, &self.call);
        self.* = undefined;
    }
};

pub const PendingRequest = struct {
    request_id: []u8,
    child_id: []u8,
    request: permission_request.OwnedPermissionRequest,
    /// The exact call the request waits on, owned by the caller with it.
    call: types.ToolCall,

    pub fn deinit(self: *PendingRequest, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        self.request.deinit(alloc);
        freeCall(alloc, &self.call);
        self.* = undefined;
    }
};

/// The exact call, with its three strings owned by `alloc` and the fields
/// that borrow from the turn cleared: only the call itself outlives it.
fn dupeCall(alloc: Allocator, call: types.ToolCall) Allocator.Error!types.ToolCall {
    const id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, call.arguments_json);
    errdefer alloc.free(arguments_json);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = call.argument_integrity,
        .argument_diagnostic = call.argument_diagnostic,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

fn freeCall(alloc: Allocator, call: *types.ToolCall) void {
    alloc.free(call.id);
    alloc.free(call.name);
    alloc.free(call.arguments_json);
    call.* = undefined;
}

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
            errdefer {
                var owned = request;
                owned.deinit(alloc);
            }
            var call = try dupeCall(alloc, binding.call);
            errdefer freeCall(alloc, &call);
            return .{
                .request_id = request_id,
                .child_id = child_id,
                .request = request,
                .call = call,
            };
        }
        return null;
    }

    /// The first request waiting on `child_id`, as `firstPendingRequest`
    /// takes a caller's first by `root_id`. The caller frees it.
    pub fn firstPendingForChild(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!?PendingRequest {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        for (self.bindings.items) |*binding| {
            if (!std.mem.eql(u8, binding.child_id, child_id)) continue;
            const request_id = try alloc.dupe(u8, binding.request_id);
            errdefer alloc.free(request_id);
            const owned_child_id = try alloc.dupe(u8, binding.child_id);
            errdefer alloc.free(owned_child_id);
            const request = permission_request.OwnedPermissionRequest.dupe(
                alloc,
                binding.request.view(),
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CommitFailed,
            };
            errdefer {
                var owned = request;
                owned.deinit(alloc);
            }
            var call = try dupeCall(alloc, binding.call);
            errdefer freeCall(alloc, &call);
            return .{
                .request_id = request_id,
                .child_id = owned_child_id,
                .request = request,
                .call = call,
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
        call: types.ToolCall,
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
        const owned_call = try dupeCall(self.alloc, call);
        errdefer {
            var value = owned_call;
            freeCall(self.alloc, &value);
        }
        try self.bindings.append(self.alloc, .{
            .request_id = owned_request_id,
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .work_id = owned_work_id,
            .request = owned_request,
            .call = owned_call,
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
        return self.resolveIndexLocked(index, decision, owned_feedback, &feedback_owned);
    }

    /// Removes binding `index` and submits `decision` to its worker. The
    /// registry mutex is held on entry and released here, before the worker is
    /// called, so an answer never waits on a worker holding this lock.
    fn resolveIndexLocked(
        self: *Registry,
        index: usize,
        decision: types.ToolPermissionDecision,
        owned_feedback: ?[]u8,
        feedback_owned: *bool,
    ) Error!ResolveResult {
        const binding = &self.bindings.items[index];
        if (!binding.worker.pin()) {
            var removed = self.bindings.orderedRemove(index);
            self.pending_revision +|= 1;
            self.mutex.unlock(io_mod.getIo());
            defer removed.deinit(self.alloc);
            if (feedback_owned.*) {
                self.alloc.free(owned_feedback.?);
                feedback_owned.* = false;
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
            feedback_owned.* = false;
            removed.worker.cancel();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PermissionCapacityExceeded => error.CapacityExceeded,
                error.PermissionCommitFailed => error.CommitFailed,
            };
        };
        feedback_owned.* = false;
        if (submission != .accepted) return .rejected;
        return .accepted;
    }

    /// Marks the request's note as posted: only a noted request may be
    /// refused by fx ask's fallback (`tests/tla/subagent/ParentApproval.tla`
    /// `Note`). A missing id does nothing, since a note can outlive its
    /// request.
    pub fn markNoted(self: *Registry, request_id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const index = self.find(request_id) orelse return;
        self.bindings.items[index].noted = true;
    }

    /// Drops the request without answering its worker. The caller is the
    /// request's own observer, whose error path clears the worker's pending
    /// request before it waits, so nothing there is left waiting.
    pub fn withdraw(self: *Registry, request_id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const index = self.find(request_id) orelse {
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        var removed = self.bindings.orderedRemove(index);
        self.pending_revision +|= 1;
        self.mutex.unlock(io_mod.getIo());
        removed.deinit(self.alloc);
    }

    /// Whether this root has at least one request waiting and every one of
    /// its requests has had its note posted. False for a request still being
    /// noted, so the fallback never counts one main was not told of.
    pub fn allPendingNoted(self: *Registry, root_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var found = false;
        for (self.bindings.items) |binding| {
            if (!std.mem.eql(u8, binding.root_id, root_id)) continue;
            if (!binding.noted) return false;
            found = true;
        }
        return found;
    }

    /// What `refuseNoted` dropped: the requests whose worker took the refusal,
    /// and those whose worker was already gone (RULES.md R3.8: the trace must
    /// not undercount what was dropped).
    pub const RefusedCounts = struct { accepted: usize = 0, gone: usize = 0 };

    /// Refuses every noted request of `root_id`, as `resolve` refuses one.
    /// Only noted requests are touched: one whose note never went out is not
    /// main's to refuse.
    pub fn refuseNoted(self: *Registry, root_id: []const u8, feedback: []const u8) RefusedCounts {
        var counts: RefusedCounts = .{};
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            if (self.closed) {
                self.mutex.unlock(io_mod.getIo());
                break;
            }
            const index = self.firstNotedIndexLocked(root_id) orelse {
                self.mutex.unlock(io_mod.getIo());
                break;
            };
            const owned_feedback = self.alloc.dupe(u8, feedback) catch {
                self.mutex.unlock(io_mod.getIo());
                break;
            };
            var feedback_owned = true;
            const outcome = self.resolveIndexLocked(index, .deny, owned_feedback, &feedback_owned) catch break;
            switch (outcome) {
                .accepted => counts.accepted += 1,
                .rejected => counts.gone += 1,
            }
        }
        return counts;
    }

    fn firstNotedIndexLocked(self: *Registry, root_id: []const u8) ?usize {
        for (self.bindings.items, 0..) |binding, index| {
            if (!binding.noted) continue;
            if (!std.mem.eql(u8, binding.root_id, root_id)) continue;
            return index;
        }
        return null;
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

test "firstPendingForChild finds only that child's waiting request" {
    const alloc = std.testing.allocator;
    var registry = Registry{ .alloc = alloc };
    defer registry.deinit();
    const Worker = struct {
        fn submit(
            _: *anyopaque,
            _: u64,
            _: permission_request.OwnedPermissionResponse,
            _: ?worker_runtime.WorkerRuntime.PermissionCommit,
        ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
            return .accepted;
        }

        fn cancel(_: *anyopaque) void {}

        fn pin(_: *anyopaque) bool {
            return true;
        }

        fn release(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    const route = WorkerRoute{
        .context = &context,
        .submit_fn = Worker.submit,
        .cancel_fn = Worker.cancel,
        .pin_fn = Worker.pin,
        .release_fn = Worker.release,
    };
    try registry.registerTool("request-a", "child-a", "root", "work", .{ .id = 1, .label = "run a" }, .{ .id = "call-a", .name = "shell", .arguments_json = "{\"command\":\"ls a\"}" }, &.{}, route, 1);
    try registry.registerTool("request-b", "child-b", "root", "work", .{ .id = 2, .label = "run b" }, .{ .id = "call-b", .name = "shell", .arguments_json = "{\"command\":\"ls b\"}" }, &.{}, route, 2);

    var pending = (try registry.firstPendingForChild(alloc, "child-b")) orelse return error.TestUnexpectedResult;
    defer pending.deinit(alloc);
    try std.testing.expectEqualStrings("request-b", pending.request_id);
    try std.testing.expectEqualStrings("child-b", pending.child_id);
    try std.testing.expectEqualStrings("run b", pending.request.view().label);
    // The parent's answer checks the exact call that was registered.
    try std.testing.expectEqualStrings("call-b", pending.call.id);
    try std.testing.expectEqualStrings("shell", pending.call.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls b\"}", pending.call.arguments_json);
    try std.testing.expect((try registry.firstPendingForChild(alloc, "child-c")) == null);
}

test "a request counts as noted only after its note, and the fallback refuses only noted ones" {
    const alloc = std.testing.allocator;
    var registry = Registry{ .alloc = alloc };
    defer registry.deinit();
    const Recorder = struct {
        decision: ?types.ToolPermissionDecision = null,
        feedback_buf: [256]u8 = undefined,
        feedback_len: usize = 0,

        fn submit(
            raw: *anyopaque,
            _: u64,
            response: permission_request.OwnedPermissionResponse,
            _: ?worker_runtime.WorkerRuntime.PermissionCommit,
        ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var owned = response;
            defer owned.deinit();
            self.decision = owned.decision;
            self.feedback_len = 0;
            if (owned.feedback) |feedback| {
                const length = @min(feedback.len, self.feedback_buf.len);
                @memcpy(self.feedback_buf[0..length], feedback[0..length]);
                self.feedback_len = length;
            }
            return .accepted;
        }

        fn cancel(_: *anyopaque) void {}

        fn pin(_: *anyopaque) bool {
            return true;
        }

        fn release(_: *anyopaque) void {}

        fn route(self: *@This()) WorkerRoute {
            return .{
                .context = self,
                .submit_fn = submit,
                .cancel_fn = cancel,
                .pin_fn = pin,
                .release_fn = release,
            };
        }

        fn feedbackText(self: *const @This()) []const u8 {
            return self.feedback_buf[0..self.feedback_len];
        }
    };
    var first: Recorder = .{};
    var second: Recorder = .{};
    try registry.registerTool("request-a", "child-a", "root", "work", .{ .id = 1, .label = "run a" }, .{ .id = "call-a", .name = "shell", .arguments_json = "{}" }, &.{}, first.route(), 1);
    try registry.registerTool("request-b", "child-b", "root", "work", .{ .id = 2, .label = "run b" }, .{ .id = "call-b", .name = "shell", .arguments_json = "{}" }, &.{}, second.route(), 2);

    // A registered request whose note has not gone out is not the fallback's
    // (the model's `early_stall`): main was never told of it.
    try std.testing.expect(!registry.allPendingNoted("root"));
    registry.markNoted("request-a");
    try std.testing.expect(!registry.allPendingNoted("root"));
    // Another root's requests never count.
    try std.testing.expect(!registry.allPendingNoted("other"));
    // A missing id does nothing.
    registry.markNoted("request-missing");

    // Only noted requests are refused.
    const first_refused = registry.refuseNoted("root", "main did not answer");
    try std.testing.expectEqual(@as(usize, 1), first_refused.accepted);
    try std.testing.expectEqual(@as(usize, 0), first_refused.gone);
    try std.testing.expectEqual(@as(?types.ToolPermissionDecision, .deny), first.decision);
    try std.testing.expectEqualStrings("main did not answer", first.feedbackText());
    try std.testing.expect(second.decision == null);
    var pending = (try registry.firstPendingForChild(alloc, "child-b")) orelse return error.TestUnexpectedResult;
    pending.deinit(alloc);

    // Once its note goes out, the second request is the fallback's too.
    registry.markNoted("request-b");
    try std.testing.expect(registry.allPendingNoted("root"));
    const second_refused = registry.refuseNoted("root", "again");
    try std.testing.expectEqual(@as(usize, 1), second_refused.accepted);
    try std.testing.expectEqual(@as(?types.ToolPermissionDecision, .deny), second.decision);
    try std.testing.expectEqualStrings("again", second.feedbackText());
    try std.testing.expect(!registry.allPendingNoted("root"));
}

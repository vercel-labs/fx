const std = @import("std");
const observation = @import("../agent/runtime/observation.zig");
const diff_mod = @import("../output/diff.zig");
const permission_request = @import("permission_request.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Transport-neutral permission prompt capability. Policy evaluation and
/// grant construction stay in tool admission; transports present the request,
/// return the selected response, and may retain grants in session-owned state.
pub const Prompter = struct {
    observer: ?*observation.Observer = null,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    context: *anyopaque,
    request_fn: *const fn (
        *anyopaque,
        Allocator,
        permission_request.PermissionRequest,
        types.ToolCall,
        ?*const diff_mod.FileReview,
        ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse,
    retain_grant_fn: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,

    pub fn request(
        self: Prompter,
        alloc: Allocator,
        request_value: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const diff_mod.FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        const wait = if (self.observer) |observer| observer.beginWait(.{ .kind = .approval, .call_id = call.id, .external_id = if (request_value.id == 0) null else request_value.id, .prompt = request_value.label }) else null;
        const response = self.request_fn(
            self.context,
            alloc,
            request_value,
            call,
            review,
            grant_offer,
        ) catch |err| {
            if (wait) |value| value.end(if (endsCancelled(err)) .cancelled else .failed, &.{}, @errorName(err));
            return err;
        };
        if (wait) |value| value.end(if (self.cancel_flag != null and self.cancel_flag.?.load(.seq_cst)) .cancelled else if (response.decision.isDenied()) .denied else .accepted, if (response.feedback) |feedback| &.{feedback} else &.{}, null);
        return response;
    }

    pub fn retainGrant(self: Prompter, tool_name: []const u8, target_path: []const u8) anyerror!bool {
        const retain = self.retain_grant_fn orelse return false;
        try retain(self.context, tool_name, target_path);
        return true;
    }
};

/// Whether a failed request ended because it was cancelled, which a wait
/// reports as cancelled and not failed: the prompter was cancelled, or the
/// prompt it belongs to closed or the subagent that asked was stopped, as a
/// cancel does to a parent's own request.
fn endsCancelled(err: anyerror) bool {
    return err == error.Cancelled or err == error.PermissionPromptClosed or err == error.PermissionPromptStopped;
}

/// The cause a prompter's failure carries, or null for one that names none. A
/// prompter that cannot ask fails with `error.PermissionPromptUnavailable`, or
/// with the error here that names why; admission turns either into an outcome
/// that says approval was needed and could not be asked, never into a refusal
/// by the person.
pub fn unavailableCause(err: anyerror) ?types.ApprovalUnavailableCause {
    return switch (err) {
        error.PermissionPromptClosed => .prompt_closed,
        error.PermissionPromptStopped => .stopped,
        error.PermissionPromptFull => .requests_full,
        error.PermissionPromptClientUnavailable => .client_unavailable,
        else => null,
    };
}

/// Whether a prompter's failure means approval could not be asked.
pub fn isUnavailable(err: anyerror) bool {
    return err == error.PermissionPromptUnavailable or unavailableCause(err) != null;
}

test "approval observer pairs actual prompt attempts without changing their decisions" {
    const Fixture = struct {
        decision: types.ToolPermissionDecision = .once,
        failure: bool = false,
        fn request(raw: *anyopaque, alloc: Allocator, _: permission_request.PermissionRequest, _: types.ToolCall, _: ?*const diff_mod.FileReview, _: ?[]const types.PermissionGrant) !permission_request.OwnedPermissionResponse {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.failure) return error.Cancelled;
            return permission_request.OwnedPermissionResponse.init(alloc, self.decision, null);
        }
    };
    var capture: @import("../agent/runtime/observation_testing.zig").Capture = .{ .expected_call = "approval-call" };
    var observer = capture.observer();
    var fixture: Fixture = .{};
    const prompter = Prompter{ .context = &fixture, .request_fn = Fixture.request, .observer = &observer };
    const call = types.ToolCall{ .id = "approval-call", .name = "shell", .arguments_json = "{}" };
    for ([_]types.ToolPermissionDecision{ .once, .deny }) |decision| {
        fixture.decision = decision;
        var response = try prompter.request(std.testing.allocator, .{ .id = 42, .label = "Allow?" }, call, null, null);
        defer response.deinit();
        try std.testing.expectEqual(decision, response.decision);
    }
    fixture.failure = true;
    try std.testing.expectError(error.Cancelled, prompter.request(std.testing.allocator, .{ .label = "Allow?" }, call, null, null));
    try std.testing.expectEqual(@as(usize, 3), capture.count(.wait_start));
    try std.testing.expectEqual(capture.count(.wait_start), capture.count(.wait_end));
    try std.testing.expect(!capture.invalid);
}

test "a wait the prompt's close or a stop ended is cancelled, and any other failure is failed" {
    const Fixture = struct {
        err: anyerror = error.Cancelled,
        fn request(raw: *anyopaque, _: Allocator, _: permission_request.PermissionRequest, _: types.ToolCall, _: ?*const diff_mod.FileReview, _: ?[]const types.PermissionGrant) !permission_request.OwnedPermissionResponse {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.err;
        }
    };
    var capture: @import("../agent/runtime/observation_testing.zig").Capture = .{ .expected_call = "approval-call" };
    var observer = capture.observer();
    var fixture: Fixture = .{};
    const prompter = Prompter{ .context = &fixture, .request_fn = Fixture.request, .observer = &observer };
    const call = types.ToolCall{ .id = "approval-call", .name = "shell", .arguments_json = "{}" };
    const cancelled = [_]anyerror{ error.Cancelled, error.PermissionPromptClosed, error.PermissionPromptStopped };
    const failed = [_]anyerror{ error.PermissionPromptFull, error.PermissionPromptClientUnavailable, error.PermissionPromptUnavailable, error.OutOfMemory };
    for (cancelled ++ failed) |err| {
        fixture.err = err;
        try std.testing.expectError(err, prompter.request(std.testing.allocator, .{ .id = 42, .label = "Allow?" }, call, null, null));
    }
    try std.testing.expectEqual(cancelled.len + failed.len, capture.count(.wait_end));
    try std.testing.expectEqual(cancelled.len, capture.outcomes[@backingInt(observation.WaitOutcome.cancelled)]);
    try std.testing.expectEqual(failed.len, capture.outcomes[@backingInt(observation.WaitOutcome.failed)]);
    try std.testing.expect(!capture.invalid);
}

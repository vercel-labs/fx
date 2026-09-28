const std = @import("std");
const diff_mod = @import("../output/diff.zig");
const permission_request = @import("permission_request.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Submits a response to one open prompt. Returns false when that prompt was
/// already answered or replaced; the response is consumed either way.
pub const Answer = struct {
    context: *anyopaque,
    request_id: u64,
    submit_fn: *const fn (*anyopaque, u64, permission_request.OwnedPermissionResponse) bool,

    pub fn submit(self: Answer, response: permission_request.OwnedPermissionResponse) bool {
        return self.submit_fn(self.context, self.request_id, response);
    }
};

/// A second responder told when a prompt opens. `open_fn` runs while the
/// transport registers the prompt, so it must return without blocking; any
/// answer it later submits races the transport's own prompt.
pub const Responder = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, permission_request.PermissionRequest, Answer) void,
};

/// Transport-neutral permission prompt capability. Policy evaluation and
/// grant construction stay in tool admission; transports present the request,
/// return the selected response, and may retain grants in session-owned state.
pub const Prompter = struct {
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
    /// Set only by transports whose open prompt also accepts an answer from a
    /// `Responder`. The transport's prompt stays open; the first answer wins.
    answerable_request_fn: ?*const fn (
        *anyopaque,
        Allocator,
        permission_request.PermissionRequest,
        ?*const diff_mod.FileReview,
        Responder,
    ) anyerror!permission_request.OwnedPermissionResponse = null,

    pub fn request(
        self: Prompter,
        alloc: Allocator,
        request_value: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const diff_mod.FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        return self.request_fn(
            self.context,
            alloc,
            request_value,
            call,
            review,
            grant_offer,
        );
    }

    pub fn retainGrant(self: Prompter, tool_name: []const u8, target_path: []const u8) anyerror!bool {
        const retain = self.retain_grant_fn orelse return false;
        try retain(self.context, tool_name, target_path);
        return true;
    }
};

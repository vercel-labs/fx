//! Provider execution borrows the same proven root and live permission mode as native actions.
const std = @import("std");
const deps_mod = @import("deps.zig");
const action_mod = @import("../../permissions/executable_action.zig");
const classifier = @import("../../permissions/auto_classifier.zig");
const types = @import("../../shared/types.zig");

/// Stack-owned context remains valid until the serialized provider request returns.
pub const Context = struct {
    deps: *const deps_mod.AgentRuntimeDeps,
    review_turn: classifier.ReviewTurnContext,
    fallback_mode: types.PermissionMode,

    pub fn authorizer(self: *Context) ?action_mod.Authorizer {
        if (self.deps.request_executable_permission == null) return null;
        return .{ .context = self, .authorize_fn = authorize, .current_mode_fn = current_mode };
    }

    fn current_mode(raw: *anyopaque) types.PermissionMode {
        const self: *Context = @ptrCast(@alignCast(raw));
        return if (self.deps.snapshot_root_permission_mode) |sample| sample(self.deps.ctx) else self.fallback_mode;
    }

    fn authorize(raw: *anyopaque, alloc: std.mem.Allocator, action: action_mod.Action, previous: ?types.PermissionMode) !types.PermissionMode {
        const self: *Context = @ptrCast(@alignCast(raw));
        const callback = self.deps.request_executable_permission orelse return error.ExtensionExecutionPermissionRequired;
        const mode = current_mode(raw);
        const granted = try callback(self.deps.ctx, alloc, action, self.review_turn, mode, previous);
        if (granted != current_mode(raw)) return error.ExtensionExecutionPermissionRequired;
        return granted;
    }
};

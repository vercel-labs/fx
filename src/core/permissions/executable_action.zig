//! Native-only execution authority cannot be reconstructed from model tool JSON.
const std = @import("std");
const types = @import("../shared/types.zig");

pub const permission_name = "extension_execute";
pub const label_prefix = "Execute trusted extension with OS privileges";
const host_privilege_scope = "unsandboxed_host";

/// Identity comes from the registered provider and freshly hashed canonical executable.
pub const Action = struct {
    extension_id: []const u8,
    provider_id: []const u8,
    executable_identity: []const u8,
    privilege_scope: []const u8 = host_privilege_scope,
};

/// Borrowed callbacks remain inside the current proven root request; models never receive them.
pub const Authorizer = struct {
    context: *anyopaque,
    authorize_fn: *const fn (*anyopaque, std.mem.Allocator, Action, ?types.PermissionMode) anyerror!types.PermissionMode,
    current_mode_fn: *const fn (*anyopaque) types.PermissionMode,

    pub fn authorize(self: Authorizer, alloc: std.mem.Allocator, action: Action, previous: ?types.PermissionMode) !types.PermissionMode {
        return self.authorize_fn(self.context, alloc, action, previous);
    }

    pub fn unchanged(self: Authorizer, approved_mode: types.PermissionMode) bool {
        return self.current_mode_fn(self.context) == approved_mode;
    }
};

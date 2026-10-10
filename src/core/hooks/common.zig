const std = @import("std");
const definitions = @import("definitions.zig");

pub const ScopeKind = definitions.ScopeKind;
pub const Scope = definitions.Scope;
pub const Invocation = definitions.Invocation;
pub const Limits = definitions.Limits;
pub const RegistrationError = definitions.RegistrationError;
pub const ViewError = definitions.ViewError;
pub const HandlerError = definitions.HandlerError;
pub const MutationDispatchError = definitions.MutationDispatchError;

test "Hooks v1.0 scope kinds remain limited to the current surfaces" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(ScopeKind).@"enum".field_names.len);
}

const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");
const gateway_schema = @import("gateway_schema.zig");

// Generic aliases and helpers shared by registered tool specifications.

pub const ExecutorKind = tool_dispatch.ExecutorKind;
pub const LabelArgKind = tool_dispatch.LabelArgKind;
pub const PermissionTargetKind = tool_dispatch.PermissionTargetKind;
pub const ToolSpec = tool_dispatch.Tool;

pub fn toolInputSchemaJson(alloc: std.mem.Allocator, spec: ToolSpec) ![]u8 {
    return gateway_schema.inputSchemaJsonAlloc(alloc, spec.gateway_schema);
}

pub fn toolLabelValue(spec: ToolSpec, args: std.json.ObjectMap) ?[]const u8 {
    return tool_dispatch.toolLabelValue(spec, args);
}

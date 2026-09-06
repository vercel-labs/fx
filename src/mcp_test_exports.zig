const std = @import("std");

const io_mod = @import("core/shared/io.zig");
const access_policy = @import("core/mcp/access_policy.zig");
const mcp_contract = @import("core/mcp/mcp_contract.zig");
const mcp_runtime = @import("core/mcp/mcp_runtime.zig");
const stdio_dispatcher = @import("core/mcp/stdio_dispatcher.zig");
const tool_mcp_runtime = @import("core/tooling/tool_mcp_runtime.zig");

pub const McpEnvVar = mcp_contract.McpEnvVar;
pub const McpRuntime = mcp_runtime.McpRuntime;
pub const StdioDispatcher = stdio_dispatcher.StdioDispatcher;
pub const Progress = stdio_dispatcher.Progress;
pub const InputRequired = tool_mcp_runtime.InputRequired;
pub const InputOrigin = tool_mcp_runtime.InputOrigin;
pub const Access = tool_mcp_runtime.Access;
pub const ResolvedLiveView = tool_mcp_runtime.ResolvedLiveView;
pub const AccessView = access_policy.View;

pub fn authorityGeneration(view: access_policy.View) u64 {
    return access_policy.authorityGeneration(view);
}

pub fn setIo(io: std.Io) void {
    io_mod.setIo(io);
}

pub fn setEnvironMap(environ: *const std.process.Environ.Map) void {
    io_mod.setEnvironMap(environ);
}

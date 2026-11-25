//! Front door for the session's tool bridge: how commands run by fx's shell
//! tools call back into the running session's handlers (currently `fx mcp call`)
//! over a per-session Unix socket under the calling tool's permissions.
//!
//! Outside code imports only this file; `scripts/check-tool-bridge-boundary.sh`
//! enforces that in CI.
//!
//! `edit_blocks` reads the SEARCH/REPLACE blocks that a program sends to
//! `edit PATH` on stdin.

pub const core = @import("core.zig");
pub const wire = @import("wire.zig");
pub const capability = @import("capability.zig");
pub const edit_blocks = @import("edit_blocks.zig");
pub const client = @import("client.zig");
pub const tool_command = @import("tool_command.zig");
const bridge = @import("bridge.zig");

pub const supported = bridge.supported;
pub const Registration = bridge.Registration;
pub const variable_names = bridge.variable_names;
pub const register = bridge.register;
pub const unregister = bridge.unregister;
pub const Capability = capability.Capability;

test {
    _ = core;
    _ = wire;
    _ = bridge;
    _ = capability;
    _ = edit_blocks;
    _ = client;
    _ = tool_command;
}

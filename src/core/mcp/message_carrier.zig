//! Host-owned channel for MCP servers that are served over the host's own
//! connection instead of a process or network endpoint, such as ACP
//! `type: "acp"` servers. Each exchange sends one modern MCP request frame and
//! returns its JSON-RPC response frame, so Streamable HTTP parsing is reused
//! unchanged.

const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");
const streamable_http = @import("streamable_http.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    /// Host-issued identifier of the server registration.
    server_id: []const u8,
    /// Complete JSON-RPC request frame with MCP metadata in `params._meta`.
    frame: []const u8,
    control: streamable_http.Control,
    precommit: ?*mcp_contract.TransportPrecommit = null,
    /// Largest response frame the caller accepts.
    max_response_bytes: usize,
};

pub const Carrier = struct {
    context: *anyopaque,
    /// Returns an `alloc`-owned JSON-RPC response frame for `request.frame`.
    /// Fails with `error.Cancelled` or `error.McpRequestTimedOut` when the
    /// request's control ends first.
    exchange_fn: *const fn (context: *anyopaque, alloc: Allocator, request: Request) anyerror![]u8,

    pub fn exchange(self: Carrier, alloc: Allocator, request: Request) ![]u8 {
        return self.exchange_fn(self.context, alloc, request);
    }
};

/// Placeholder endpoint for host-channel servers. It is never dialed; its
/// scheme fails endpoint validation if any HTTP path ever receives it.
pub fn placeholderUrl(alloc: Allocator, server_id: []const u8) ![]u8 {
    return alloc.print("acp:{s}", .{server_id});
}

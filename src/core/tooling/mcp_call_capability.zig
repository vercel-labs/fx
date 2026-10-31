//! What a running tool call lends the `fx mcp call` bridge
//! (`src/core/mcp_host/mcp_call_bridge.zig`): the permission check and the
//! MCP call of that tool call's own context. A shell command's `fx mcp call`
//! therefore meets the same rules, prompt, automatic review, and MCP access
//! as a direct call by the agent that ran the command, a subagent included.
//!
//! `tool_runtime` builds one for each tool call it dispatches. It is valid
//! only while that tool call runs.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Where the bridge exists. Elsewhere a command's `fx mcp call` finds no
/// shell call, and the model is not told about it.
pub const supported = switch (builtin.target.os.tag) {
    .linux, .macos => true,
    else => false,
};

/// The largest MCP result a bridge call returns: the MCP client's own limit
/// on one HTTP message (`src/mcp/io/http.zig` `max_message`).
pub const max_result_bytes: usize = 16 * 1024 * 1024;

pub const Authorization = union(enum) {
    /// The check allowed the call, for the tool definition it checked.
    allow: struct { binding: ?types.McpToolBinding = null },
    /// Why not, for the client: a denial, a held review, or an unknown tool.
    deny: []const u8,
};

pub const CallStatus = enum { ok, tool_error, failed };

pub const CallOutcome = struct {
    status: CallStatus,
    /// The tool's data for `ok` and `tool_error`, or what failed.
    bytes: []const u8,
};

/// A question about the MCP tools themselves: `fx mcp call list`, `search`,
/// and `help`. It reads tool metadata only, as the agent's own
/// `capability_search` does, so it needs no permission check; it sees only
/// the tools the agent may use.
pub const Lookup = union(enum) {
    /// Every tool of the named server.
    list: []const u8,
    /// The tools that best match a query.
    search: []const u8,
    /// One tool's arguments and description.
    help: []const u8,
};

pub const Capability = struct {
    context: *anyopaque,
    /// Decides `tool` with `arguments_json` as call `request_id`. May prompt
    /// the user and block until they answer. Allocates in `arena`.
    authorize_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        request_id: []const u8,
        tool: []const u8,
        arguments_json: []const u8,
    ) anyerror!Authorization,
    /// Runs an allowed call. Setting `cancel` cancels it, and the call still
    /// returns. Allocates in `arena`.
    call_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        request_id: []const u8,
        tool: []const u8,
        arguments_json: []const u8,
        allowed: @FieldType(Authorization, "allow"),
        cancel: *std.atomic.Value(bool),
    ) anyerror!CallOutcome,
    /// Answers a lookup with text for the command: `ok`, or `failed` with
    /// why. Setting `cancel` ends it early. Allocates in `arena`.
    lookup_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        lookup: Lookup,
        cancel: *std.atomic.Value(bool),
    ) anyerror!CallOutcome,

    pub fn authorize(self: Capability, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8) anyerror!Authorization {
        return self.authorize_fn(self.context, arena, request_id, tool, arguments_json);
    }

    pub fn call(self: Capability, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8, allowed: @FieldType(Authorization, "allow"), cancel: *std.atomic.Value(bool)) anyerror!CallOutcome {
        return self.call_fn(self.context, arena, request_id, tool, arguments_json, allowed, cancel);
    }

    pub fn lookup(self: Capability, arena: Allocator, question: Lookup, cancel: *std.atomic.Value(bool)) anyerror!CallOutcome {
        return self.lookup_fn(self.context, arena, question, cancel);
    }
};

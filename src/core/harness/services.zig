//! What the running turn of a node offers the harness. The agent loop
//! implements it (`src/core/agent/runtime/harness_services.zig`) for one tool
//! call that runs a shell command, so every harness request reuses that
//! turn's admission, permission mode, grants and model connection instead of
//! a second path.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ToolStatus = enum {
    success,
    /// The tool ran and reported a failure.
    failure,
    /// The person, a rule, or automatic review denied it.
    denied,
    /// The node may not call it: no such tool, not admitted, invalid input.
    refused,
    cancelled,
};

/// `output` is allocated with the arena passed to the call.
pub const ToolOutcome = struct {
    status: ToolStatus,
    output: []const u8,
};

pub const ToolRequest = struct {
    /// Unique per lease; names the call in approvals and traces.
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const CompletionRequest = struct {
    prompt: []const u8,
    system: []const u8,
    /// Null uses the turn's model.
    model: ?[]const u8 = null,
    max_bytes: usize,
};

/// Slices are allocated with the arena passed to the call.
pub const CompletionOutcome = union(enum) {
    text: []const u8,
    failed: []const u8,
};

pub const Services = struct {
    context: *anyopaque,
    call_tool_fn: *const fn (context: *anyopaque, arena: Allocator, request: ToolRequest) anyerror!ToolOutcome,
    /// The tools this node may call, as the model sees them.
    tool_names_fn: *const fn (context: *anyopaque, arena: Allocator) anyerror![]const []const u8,
    complete_fn: *const fn (context: *anyopaque, arena: Allocator, request: CompletionRequest) anyerror!CompletionOutcome,

    pub fn callTool(self: Services, arena: Allocator, request: ToolRequest) !ToolOutcome {
        return self.call_tool_fn(self.context, arena, request);
    }

    pub fn toolNames(self: Services, arena: Allocator) ![]const []const u8 {
        return self.tool_names_fn(self.context, arena);
    }

    pub fn complete(self: Services, arena: Allocator, request: CompletionRequest) !CompletionOutcome {
        return self.complete_fn(self.context, arena, request);
    }
};

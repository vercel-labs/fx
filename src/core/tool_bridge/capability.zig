//! What a running tool call lends the `fx mcp call` bridge
//! (`bridge.zig`): the permission check and the
//! MCP call of that tool call's own context. A shell command's `fx mcp call`
//! therefore meets the same rules, prompt, automatic review, and MCP access
//! as a direct call by the agent that ran the command, a subagent included.
//!
//! `tool_runtime` builds one for each tool call it dispatches. It is valid
//! only while that tool call runs.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../shared/types.zig");
const edit_blocks = @import("edit_blocks.zig");

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

/// fx tool's text when fx cannot take a tool call from this command: outside a
/// bash program, experimental.bash_tool off, or after the bash call returns.
pub const file_tool_unavailable_text = "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, before that bash call returns.";

/// fx tool's text when fx cannot review a change: the bash call that ran this
/// program has returned, or fx's bash tool did not start it. Nothing changed.
pub const file_change_unreviewable_text = "fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.";

pub const Authorization = union(enum) {
    /// The check allowed the call, for the tool definition it checked. `prepared`
    /// is what the handler keeps for the call step: a file change's authority,
    /// owned by the handler; null for an MCP call.
    allow: struct { binding: ?types.McpToolBinding = null, prepared: ?*anyopaque = null },
    /// Why not, for the client: a denial, a held review, or an unknown tool.
    deny: []const u8,
};

/// `fx tool edit PATH`: one or more SEARCH/REPLACE blocks for one file.
pub const EditRequest = struct {
    path: []const u8,
    blocks: []const edit_blocks.Edit,
};

/// `fx tool write PATH`: the whole content of one file.
pub const WriteRequest = struct {
    path: []const u8,
    content: []const u8,
};

/// A file change a bridge command asks for. It runs as the agent's own
/// `edit_file` or `write_file` call would.
pub const FileRequest = union(enum) {
    edit: EditRequest,
    write: WriteRequest,
};

/// Mirrors `reports.Rule` in `src/core/subagent/reports.zig`. The bridge module
/// may not import subagent code, so `src/core/tooling/bash_tool_requests.zig` checks
/// at compile time that both enums have the same fields in the same order.
pub const AgentReport = enum {
    final,
    every_turn,
    never,

    pub fn name(self: AgentReport) []const u8 {
        return @tagName(self);
    }

    pub fn parse(raw: []const u8) ?AgentReport {
        if (std.mem.eql(u8, raw, "final")) return .final;
        if (std.mem.eql(u8, raw, "every_turn")) return .every_turn;
        if (std.mem.eql(u8, raw, "never")) return .never;
        return null;
    }
};

pub const SkillOpenRequest = struct {
    name: []const u8,
    resource: ?[]const u8 = null,
};

pub const AgentMessageRequest = struct {
    agent: []const u8,
    message: []const u8,
    instructions: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    report: ?AgentReport = null,
};

pub const BashToolRequest = union(enum) {
    skill_list,
    skill_open: SkillOpenRequest,
    agent_message: AgentMessageRequest,
    agent_wait,
    agent_status: ?[]const u8,
    agent_stop: []const u8,
    agent_close: []const u8,
};

pub const CallStatus = enum { ok, tool_error, failed };

pub const CallOutcome = struct {
    status: CallStatus,
    /// The tool's data for `ok` and `tool_error`, or what failed.
    bytes: []const u8,
    /// A one-line diagnostic for stderr, set only by a handler that has one.
    notice: ?[]const u8 = null,
};

/// A question about the MCP tools themselves: `fx mcp call list`, `search`,
/// and `help`. It reads tool metadata only, as the agent's own toolbox
/// search does, so it needs no permission check; it sees only
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
    /// Decides a file change as `file` with call `request_id`. Like
    /// `authorize_fn`, it may prompt. Allocates in `arena`.
    authorize_file_fn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        request_id: []const u8,
        file: FileRequest,
    ) anyerror!Authorization = null,
    /// Decides a bash-tool operation (`fx tool skill`, `fx tool agent`). Null
    /// on registrations that do not run under `experimental.bash_tool`.
    authorize_bash_tool_fn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        request_id: []const u8,
        operation: BashToolRequest,
    ) anyerror!Authorization = null,
    /// Runs an allowed call. Setting `cancel` cancels it, and the call still
    /// returns. For a file change, `allowed.prepared` names the change and the
    /// tool and arguments are empty. Allocates in `arena`.
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

    pub fn authorizeFile(self: Capability, arena: Allocator, request_id: []const u8, file: FileRequest) anyerror!Authorization {
        const handler = self.authorize_file_fn orelse return .{ .deny = file_tool_unavailable_text };
        return handler(self.context, arena, request_id, file);
    }

    pub fn authorizeBashTool(self: Capability, arena: Allocator, request_id: []const u8, operation: BashToolRequest) anyerror!Authorization {
        const handler = self.authorize_bash_tool_fn orelse return .{ .deny = file_tool_unavailable_text };
        return handler(self.context, arena, request_id, operation);
    }

    pub fn call(self: Capability, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8, allowed: @FieldType(Authorization, "allow"), cancel: *std.atomic.Value(bool)) anyerror!CallOutcome {
        return self.call_fn(self.context, arena, request_id, tool, arguments_json, allowed, cancel);
    }

    pub fn lookup(self: Capability, arena: Allocator, question: Lookup, cancel: *std.atomic.Value(bool)) anyerror!CallOutcome {
        return self.lookup_fn(self.context, arena, question, cancel);
    }
};

const std = @import("std");
const acp_types = @import("types.zig");
const server = @import("server.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_presentation = @import("../core/tooling/tool_presentation.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const builtin_tools = @import("../builtins/tools.zig");
const host_target = @import("../core/hosts/target.zig");
const types = @import("../core/shared/types.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

/// Maps an internal tool name to the public ACP-facing name.
pub fn acpToolName(tool_name: []const u8) []const u8 {
    return if (tool_presentation.isProviderSearchAlias(tool_name)) "web_search" else tool_name;
}

pub fn mapToolKind(tool_name: []const u8) acp_types.ToolCallKind {
    if (tool_presentation.isProviderSearchAlias(tool_name)) return .search;
    if (std.mem.eql(u8, tool_name, "glob_files")) return .read;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "web_fetch")) return .fetch;
    if (std.mem.eql(u8, tool_name, "web_search")) return .search;
    if (std.mem.eql(u8, tool_name, "write_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "shell")) return .execute;
    if (std.mem.eql(u8, tool_name, "terminal")) return .execute;
    if (std.mem.eql(u8, tool_name, "run_command")) return .execute;
    if (std.mem.eql(u8, tool_name, "skill")) return .other;
    if (std.mem.eql(u8, tool_name, "install_skill")) return .other;
    return .other;
}

pub fn describeToolTitle(registry: tool_dispatch.Registry, arena: Allocator, call: ToolCall) ![]const u8 {
    if (registry.lookup(call.name) != null) {
        if (try tool_presentation.formatSubagentPlainAction(arena, call, .identity)) |title| return title;
    }
    if (tool_presentation.isProviderSearchAlias(call.name)) {
        return tool_presentation.formatPlainAction(arena, .{
            .tool_registry = registry,
            .call = call,
        });
    }
    if (tool_dispatch.toolCallPresentation(arena, registry, call)) |presentation| {
        return arena.print("{s}", .{presentation.action_label});
    }
    return arena.print("{s}", .{call.name});
}

pub const ToolCallPresentation = struct {
    title: []const u8,
    meta: acp_types.ToolCallMeta,
};

/// Title and host metadata for one tool call. `mcp_identity`, resolved from
/// the session's MCP catalog for names outside the tool registry, gives MCP
/// calls the server's display title or the tool's own name.
pub fn describeToolCall(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
    mcp_identity: ?mcp_runtime.McpRuntime.ToolIdentity,
) ToolCallPresentation {
    if (registry.lookup(call.name)) |tool| {
        return .{
            .title = describeToolTitle(registry, arena, call) catch "Tool call",
            .meta = .{ .internal = tool.internal },
        };
    }
    if (mcp_identity) |identity| {
        return .{
            .title = identity.title orelse identity.tool,
            .meta = .{ .mcp = .{ .server = identity.server, .tool = identity.tool } },
        };
    }
    return .{ .title = describeToolTitle(registry, arena, call) catch "Tool call", .meta = .{} };
}

pub fn activeToolSet(state: *const server.ServerState) tool_set_contract.ToolSet {
    if (state.host_tools.tools.len > 0) return state.host_tools.toolSet();
    if (comptime host_target.is_wasm) return tool_set_contract.empty;
    return if (state.cfg.allow_native_tools) builtin_tools.advertisement_set else tool_set_contract.empty;
}

pub fn activeToolRegistry(state: *const server.ServerState) tool_dispatch.Registry {
    return activeToolSet(state).registry;
}

/// Returns the shell snapshot fallback notice that a shell result carries as
/// its last field, unescaped into `buffer`. Command output is a JSON string,
/// so an unescaped `,"notice":` key can only be the result's own field.
pub fn shellResultNotice(output: []const u8, buffer: []u8) ?[]const u8 {
    const key = ",\"notice\":";
    if (output.len == 0 or output[output.len - 1] != '}') return null;
    const start = std.mem.findLast(u8, output, key) orelse return null;
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    return std.json.parseFromSliceLeaky(
        []const u8,
        fixed.allocator(),
        output[start + key.len .. output.len - 1],
        .{},
    ) catch null;
}

/// Applies the live path's tool_call_update content contract: unsafe bytes are
/// replaced with a notice, permission-denied and review-held failures keep
/// their full text, and everything else is clipped to the 200-byte preview.
pub fn toolUpdateContentText(is_failure: bool, output: []const u8) []const u8 {
    if (!text_utils.isModelSafeText(output)) {
        debug_trace.logf(
            "acp",
            "tool update omitted binary or non-utf8 output bytes={d}",
            .{output.len},
        );
        return "binary or non-utf8 tool output omitted";
    }
    if (is_failure and
        (tool_result_errors.isToolPermissionDeniedOutput(output) or
            tool_result_errors.isToolReviewHeldOutput(output)))
    {
        return output;
    }
    return text_utils.utf8PrefixByBytes(output, 200);
}

test "describeToolCall flags internal discovery and names MCP identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = builtin_tools.registry;

    const search = describeToolCall(registry, arena, .{ .id = "a", .name = "capability_search", .arguments_json = "{}" }, null);
    try std.testing.expect(search.meta.internal);
    const select = describeToolCall(registry, arena, .{ .id = "b", .name = "mcp_select_tool", .arguments_json = "{}" }, null);
    try std.testing.expect(select.meta.internal);
    const read = describeToolCall(registry, arena, .{ .id = "c", .name = "read_file", .arguments_json = "{}" }, null);
    try std.testing.expect(!read.meta.internal);
    try std.testing.expect(read.meta.mcp == null);

    var server_name = "mini".*;
    var tool_name = "browser_eval".*;
    const untitled = describeToolCall(registry, arena, .{ .id = "d", .name = "mcp_mini_browser_eval", .arguments_json = "{}" }, .{
        .server = &server_name,
        .tool = &tool_name,
    });
    try std.testing.expectEqualStrings("browser_eval", untitled.title);
    try std.testing.expectEqualStrings("mini", untitled.meta.mcp.?.server);
    var title = "Evaluate JavaScript".*;
    const titled = describeToolCall(registry, arena, .{ .id = "e", .name = "mcp_mini_browser_eval", .arguments_json = "{}" }, .{
        .server = &server_name,
        .tool = &tool_name,
        .title = &title,
    });
    try std.testing.expectEqualStrings("Evaluate JavaScript", titled.title);
    try std.testing.expect(!titled.meta.internal);
}

test "toolUpdateContentText clips long output and guards unsafe bytes" {
    const long = text_utils.repeat("x", 500);
    const clipped = toolUpdateContentText(false, long);
    try std.testing.expectEqual(@as(usize, 200), clipped.len);

    const unsafe = toolUpdateContentText(false, "ok\xFF\xFEbinary");
    try std.testing.expectEqualStrings("binary or non-utf8 tool output omitted", unsafe);

    const denied_json = "{\"error\":{\"type\":\"tool_permission_denied\",\"tool_name\":\"run_command\",\"message\":\"Permission denied by user\",\"reason\":\"user_denied\"}}";
    const denied = toolUpdateContentText(true, denied_json);
    try std.testing.expectEqualStrings(denied_json, denied);
}

test "shell result notice is read only from the result's own field" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "shell snapshot unavailable (x); startup files run for every command",
        shellResultNotice(
            "{\"state\":\"completed\",\"notice\":\"shell snapshot unavailable (x); startup files run for every command\"}",
            &buffer,
        ).?,
    );
    // Output that merely prints the key stays escaped inside its string.
    try std.testing.expect(shellResultNotice(
        "{\"output_delta\":\",\\\"notice\\\":\\\"x\\\"\"}",
        &buffer,
    ) == null);
    try std.testing.expect(shellResultNotice("shell result is unavailable", &buffer) == null);
}

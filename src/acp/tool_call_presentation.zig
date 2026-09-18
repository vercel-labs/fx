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
    if (std.mem.eql(u8, tool_name, "apply_patch")) return .edit;
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
        return std.fmt.allocPrint(arena, "{s}", .{presentation.action_label});
    }
    return std.fmt.allocPrint(arena, "{s}", .{call.name});
}

pub fn activeToolSet(state: *const server.ServerState) tool_set_contract.ToolSet {
    if (state.host_tools.tools.len > 0) return state.host_tools.toolSet();
    if (comptime host_target.is_wasm) return tool_set_contract.empty;
    return if (state.cfg.allow_native_tools) builtin_tools.advertisement_set else tool_set_contract.empty;
}

pub fn activeToolRegistry(state: *const server.ServerState) tool_dispatch.Registry {
    return activeToolSet(state).registry;
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

test "toolUpdateContentText clips long output and guards unsafe bytes" {
    const long = "x" ** 500;
    const clipped = toolUpdateContentText(false, long);
    try std.testing.expectEqual(@as(usize, 200), clipped.len);

    const unsafe = toolUpdateContentText(false, "ok\xFF\xFEbinary");
    try std.testing.expectEqualStrings("binary or non-utf8 tool output omitted", unsafe);

    const denied_json = "{\"error\":{\"type\":\"tool_permission_denied\",\"tool_name\":\"run_command\",\"message\":\"Permission denied by user\",\"reason\":\"user_denied\"}}";
    const denied = toolUpdateContentText(true, denied_json);
    try std.testing.expectEqualStrings(denied_json, denied);
}

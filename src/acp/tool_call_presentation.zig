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
const catalog_state = @import("../core/mcp/catalog_state.zig");

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
    if (registry.lookup(call.name)) |tool| {
        if (try tool_presentation.formatSubagentPlainAction(arena, call, .identity)) |title| return title;
        // A read's input is an opaque handle, so its verb alone says nothing
        // about what it reads.
        if (tool.executor_kind == .read_tool_result) {
            return tool_presentation.formatPlainAction(arena, .{ .tool_registry = registry, .call = call });
        }
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
    mcp_identity: ?catalog_state.ToolIdentity,
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

/// The fields of a shell result (`formatSnapshotRaw` in
/// src/tools/shell/shell.zig) that a finished call's update shows.
const ShellResultView = struct {
    state: []const u8,
    output_delta: []const u8,
    output_truncated: bool = false,
    notice: ?[]const u8 = null,
};

const shell_output_cut_marker = "... output truncated ...";

/// Content for a finished `shell` call's tool_call_update, live or replayed.
/// The model receives a JSON result, but the client is shown what the command
/// printed: the snapshot fallback notice on its own line when the result
/// carries one, then the output under the same preview contract as other
/// tools, marked when the preview or the shell cut it. Returns null unless
/// `tool_name` is `shell` and `output` is a shell result, so the caller keeps
/// the generic preview. Caller owns the returned text.
pub fn shellUpdateContentText(
    alloc: Allocator,
    tool_name: []const u8,
    output: []const u8,
) Allocator.Error!?[]u8 {
    if (!std.mem.eql(u8, tool_name, "shell")) return null;
    const parsed = std.json.parseFromSlice(
        ShellResultView,
        alloc,
        output,
        .{ .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const view = parsed.value;
    const preview = toolUpdateContentText(false, view.output_delta);
    // The preview is a prefix of the output unless the output was replaced by
    // the unsafe-bytes notice, which is never marked as cut.
    const cut = preview.ptr == view.output_delta.ptr and
        (view.output_truncated or preview.len < view.output_delta.len);
    const marker_break: []const u8 = if (cut and preview.len > 0 and preview[preview.len - 1] != '\n') "\n" else "";
    return try std.mem.concat(alloc, u8, &.{
        view.notice orelse "",
        if (view.notice != null) "\n" else "",
        preview,
        marker_break,
        if (cut) shell_output_cut_marker else "",
    });
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
    return text_utils.utf8PrefixByBytes(output, content_preview_bytes);
}

/// The most text a tool_call_update's content carries for tool output.
const content_preview_bytes = 200;

/// The end of a running command's output, for its live tool_call_update.
/// ACP replaces a card's content with each update, so every progress update
/// carries this tail of the output so far rather than only the newest chunk.
/// Keeps the last `content_preview_bytes`; once older bytes are dropped,
/// `text` starts at a whole line, or at a whole UTF-8 sequence when the kept
/// bytes hold no line start.
pub const OutputTail = struct {
    bytes: [content_preview_bytes]u8 = undefined,
    len: usize = 0,
    cut: bool = false,

    pub fn append(self: *OutputTail, chunk: []const u8) void {
        if (chunk.len >= self.bytes.len) {
            self.cut = self.cut or self.len > 0 or chunk.len > self.bytes.len;
            @memcpy(&self.bytes, chunk[chunk.len - self.bytes.len ..]);
            self.len = self.bytes.len;
            return;
        }
        const keep = @min(self.len, self.bytes.len - chunk.len);
        if (keep < self.len) self.cut = true;
        @memmove(self.bytes[0..keep], self.bytes[self.len - keep .. self.len]);
        @memcpy(self.bytes[keep..][0..chunk.len], chunk);
        self.len = keep + chunk.len;
    }

    pub fn text(self: *const OutputTail) []const u8 {
        const kept = self.bytes[0..self.len];
        if (!self.cut) return kept;
        if (std.mem.findScalar(u8, kept, '\n')) |index| {
            if (index + 1 < kept.len) return kept[index + 1 ..];
        }
        var start: usize = 0;
        while (start < kept.len and kept[start] & 0xC0 == 0x80) start += 1;
        return kept[start..];
    }
};

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

test "read titles say what they read while other tools keep their verb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = builtin_tools.registry;
    const read: ToolCall = .{
        .id = "read",
        .name = "read_tool_result",
        .arguments_json = "{\"request\":{\"handle\":\"fx-command-replay-0123.bin\",\"query\":\"error:\"}}",
        .resolved_display_target = "zig build test output for \"error:\"",
    };
    try std.testing.expectEqualStrings("Searching zig build test output for \"error:\"", describeToolCall(registry, arena, read, null).title);
    var unresolved = read;
    unresolved.resolved_display_target = null;
    try std.testing.expectEqualStrings("Searching command output", describeToolCall(registry, arena, unresolved, null).title);
    const file: ToolCall = .{ .id = "file", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" };
    try std.testing.expectEqualStrings("Reading", describeToolCall(registry, arena, file, null).title);
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

test "output tail accumulates until the preview bound" {
    var tail: OutputTail = .{};
    tail.append("step-1\n");
    tail.append("step-2\n");
    try std.testing.expectEqualStrings("step-1\nstep-2\n", tail.text());
}

test "output tail slides to the newest whole lines" {
    var tail: OutputTail = .{};
    var line_buf: [16]u8 = undefined;
    for (0..100) |index| tail.append(try std.mem.print(&line_buf, "line-{d:0>3}\n", .{index}));
    const shown = tail.text();
    try std.testing.expect(shown.len <= content_preview_bytes);
    try std.testing.expect(std.mem.startsWith(u8, shown, "line-"));
    try std.testing.expect(std.mem.endsWith(u8, shown, "line-099\n"));
}

test "output tail keeps whole UTF-8 sequences without a line start" {
    var tail: OutputTail = .{};
    // 302 bytes, so the kept 200 begin inside a two-byte sequence.
    tail.append("x" ++ text_utils.repeat("\u{e9}", 150) ++ "z");
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail.text()));
    try std.testing.expectEqual(content_preview_bytes - 1, tail.text().len);
    try std.testing.expect(std.mem.endsWith(u8, tail.text(), "z"));

    var single: OutputTail = .{};
    single.append(text_utils.repeat("y", 500) ++ "\n");
    try std.testing.expectEqualStrings(text_utils.repeat("y", content_preview_bytes - 1) ++ "\n", single.text());
}

fn expectShellUpdateContent(expected: ?[]const u8, tool_name: []const u8, output: []const u8) !void {
    const actual = try shellUpdateContentText(std.testing.allocator, tool_name, output);
    defer if (actual) |text| std.testing.allocator.free(text);
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, actual orelse return error.TestExpectedShellContent);
    } else {
        try std.testing.expect(actual == null);
    }
}

test "shell update content shows the command output instead of the result JSON" {
    try expectShellUpdateContent(
        "hello-42\n",
        "shell",
        "{\"session_id\":null,\"state\":\"completed\",\"output_truncated\":false,\"full_output_handle\":\"fx-command-replay-1.bin\",\"exit_code\":0,\"error\":null,\"output_delta\":\"hello-42\\n\"}",
    );
    try expectShellUpdateContent(
        "",
        "shell",
        "{\"state\":\"completed\",\"output_truncated\":false,\"exit_code\":4,\"output_delta\":\"\"}",
    );
    try expectShellUpdateContent(
        "shell snapshot unavailable (x); startup files run for every command\nhello\n",
        "shell",
        "{\"state\":\"completed\",\"output_delta\":\"hello\\n\",\"notice\":\"shell snapshot unavailable (x); startup files run for every command\"}",
    );
    // Output that merely prints the notice key is output, not a notice.
    try expectShellUpdateContent(
        ",\"notice\":\"x\"",
        "shell",
        "{\"state\":\"completed\",\"output_delta\":\",\\\"notice\\\":\\\"x\\\"\"}",
    );
}

test "shell update content keeps the preview bound and marks cut output" {
    const long = text_utils.repeat("x", 500);
    try expectShellUpdateContent(
        text_utils.repeat("x", 200) ++ "\n" ++ shell_output_cut_marker,
        "shell",
        "{\"state\":\"completed\",\"output_truncated\":false,\"output_delta\":\"" ++ long ++ "\"}",
    );
    // The shell already cut the output before the model saw it.
    try expectShellUpdateContent(
        "tail\n" ++ shell_output_cut_marker,
        "shell",
        "{\"state\":\"completed\",\"output_truncated\":true,\"output_delta\":\"tail\\n\"}",
    );
    try expectShellUpdateContent(
        "binary or non-utf8 tool output omitted",
        "shell",
        "{\"state\":\"completed\",\"output_truncated\":true,\"output_delta\":\"ok\\u0000binary\"}",
    );
}

test "shell update content leaves other results to the generic preview" {
    const result = "{\"state\":\"completed\",\"output_delta\":\"hello\\n\"}";
    try expectShellUpdateContent(null, "read_file", result);
    try expectShellUpdateContent(null, "shell", "{\"exit_code\":0}");
    try expectShellUpdateContent(
        null,
        "shell",
        "{\"error\":{\"type\":\"tool_permission_denied\",\"tool_name\":\"shell\",\"message\":\"Permission denied by user\"}}",
    );
    try expectShellUpdateContent(null, "shell", "{\"state\":\"completed\",\"output_delta\":\"cut mid-str");
    try expectShellUpdateContent(null, "shell", "shell result is unavailable");
}

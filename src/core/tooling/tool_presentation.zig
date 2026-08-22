const std = @import("std");
const builtin = @import("builtin");
const command_policy = @import("command_policy.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_ui_projection = @import("../terminal/ui_projection.zig");
const types = @import("../shared/types.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const max_run_command_activity_bytes = 120;
const max_run_command_activity_source_bytes = max_run_command_activity_bytes * max_run_command_activity_bytes;
pub const max_auto_permission_reason_presentation_bytes: usize = 160;

pub const ToolActionInput = struct {
    tool_registry: tool_dispatch.Registry,
    call: ToolCall,
    workspace_root: []const u8 = "",
    display_target: ?[]const u8 = null,
    is_available_dynamic_mcp_tool: bool = false,
};

pub const RunCommandActivity = struct {
    detail: []const u8,
    compatibility_tool: ?*const tool_dispatch.Tool,
};

pub fn isProviderSearchAlias(name: []const u8) bool {
    return std.mem.eql(u8, name, "perplexity_search") or
        std.mem.eql(u8, name, "parallel_search");
}

fn projectRunCommandActivitySource(
    command: []const u8,
    workspace_root_input: []const u8,
    storage: *[max_run_command_activity_bytes + 1]u8,
) []const u8 {
    const display_command = stripNoopCurrentDirectoryPrefix(command);
    var workspace_root_end = workspace_root_input.len;
    while (workspace_root_end > 1 and workspace_root_input[workspace_root_end - 1] == '/') {
        workspace_root_end -= 1;
    }
    const workspace_root = workspace_root_input[0..workspace_root_end];
    const can_abbreviate_workspace = workspace_root.len > 1 and workspace_root[0] == '/';
    const source_limit = @min(display_command.len, max_run_command_activity_source_bytes);
    var source_index: usize = 0;
    var projected_len: usize = 0;
    var line_boundary_pending = false;

    while (source_index < source_limit) {
        const byte = display_command[source_index];
        if (byte == '\r' or byte == '\n') {
            line_boundary_pending = true;
            source_index += 1;
            continue;
        }
        if (line_boundary_pending and (byte == ' ' or byte == '\t')) {
            source_index += 1;
            continue;
        }
        if (line_boundary_pending) {
            line_boundary_pending = false;
            if (projected_len > 0) {
                storage[projected_len] = ' ';
                projected_len += 1;
                if (projected_len == storage.len) break;
            }
        }

        if (can_abbreviate_workspace and
            workspace_root.len <= source_limit - source_index and
            workspaceRootMatchesAt(display_command, workspace_root, source_index))
        {
            storage[projected_len] = '.';
            projected_len += 1;
            if (projected_len == storage.len) break;
            source_index += workspace_root.len;
            continue;
        }

        storage[projected_len] = byte;
        projected_len += 1;
        if (projected_len == storage.len) break;
        source_index += 1;
    }

    return storage[0..projected_len];
}

fn stripNoopCurrentDirectoryPrefix(command: []const u8) []const u8 {
    const prefix = "cd . &&";
    if (!std.mem.startsWith(u8, command, prefix)) return command;
    if (command.len == prefix.len or !std.ascii.isWhitespace(command[prefix.len])) return command;

    const remainder = std.mem.trimStart(u8, command[prefix.len..], " \t\r\n");
    return if (remainder.len > 0) remainder else command;
}

fn workspaceRootMatchesAt(command: []const u8, workspace_root: []const u8, index: usize) bool {
    if (!std.mem.startsWith(u8, command[index..], workspace_root)) return false;
    if (index > 0 and isPathTokenByte(command[index - 1])) return false;

    const next_index = index + workspace_root.len;
    if (next_index == command.len) return true;
    return command[next_index] == '/' or !isPathTokenByte(command[next_index]);
}

fn isPathTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatRunCommandPermissionLabel(
    alloc: Allocator,
    command: []const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const encoded = try text_utils.encodeTerminalSafe(
        scratch,
        command,
        max_run_command_activity_bytes,
    );
    const suffix = try commandApprovalLabelSuffix(scratch, "terminal", command);
    return std.fmt.allocPrint(alloc, "terminal.exec {s}{s}", .{ encoded.bytes, suffix });
}

pub fn isAdvertisedDynamicMcpName(registry: tool_dispatch.Registry, name: []const u8, advertised: []const []const u8) bool {
    if (registry.lookup(name) != null) return false;
    for (advertised) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) return true;
    }
    return false;
}

/// The caller owns `detail` and must free it with `alloc`.
pub fn formatRunCommandActivity(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
) !?RunCommandActivity {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    var projected_storage: [max_run_command_activity_bytes + 1]u8 = undefined;
    const projected = projectRunCommandActivitySource(command, workspace_root, &projected_storage);
    const encoded = try text_utils.encodeTerminalSafe(scratch, projected, max_run_command_activity_bytes);
    return .{
        .detail = try alloc.dupe(u8, encoded.bytes),
        .compatibility_tool = if (try tool_dispatch.matchRunCommandCompatibility(registry, command)) |matched| matched.tool else null,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalDisplayTargetFromRows(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
    rows: []const terminal_ui_projection.Row,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        rows,
    ));
}

fn terminalDisplayTargetSessionId(
    scratch: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) ?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .terminal) return null;
    const args = tool_args.parseToolArgsObject(
        scratch,
        call.arguments_json,
    ) catch return null;
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (presentation.label_arg_kind != .session_id) return null;
    return tool_args.optionalStringArg(args, "session_id");
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalSessionTargetFromRows(
    alloc: Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    rows: []const terminal_ui_projection.Row,
) ![]const u8 {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.session_id, session_id)) continue;
        if (row.label.len == 0 or std.mem.eql(u8, row.label, session_id)) break;
        return try formatTerminalDisplayTarget(
            alloc,
            workspace_root,
            row.label,
        );
    }

    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        session_id,
        max_run_command_activity_bytes - "session ".len,
    );
    defer encoded.deinit(alloc);
    return try std.fmt.allocPrint(alloc, "session {s}", .{encoded.bytes});
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn resolveTerminalDisplayTarget(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    terminal_client: ?*terminal_client_runtime.Runtime,
    call: ToolCall,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch_state.deinit();
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    const runtime = terminal_client orelse return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        &.{},
    ));
    var snapshot = try runtime.terminalProjection(std.heap.c_allocator);
    defer snapshot.deinit();
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        snapshot.rows,
    ));
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn formatTerminalDisplayTarget(
    alloc: Allocator,
    workspace_root: []const u8,
    raw: []const u8,
) ![]u8 {
    var projected_storage: [max_run_command_activity_bytes + 1]u8 = undefined;
    const projected = projectRunCommandActivitySource(
        raw,
        workspace_root,
        &projected_storage,
    );
    const encoded = try text_utils.encodeTerminalSafe(
        alloc,
        projected,
        max_run_command_activity_bytes,
    );
    return encoded.bytes;
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPlainAction(alloc: Allocator, input: ToolActionInput) ![]const u8 {
    const call = input.call;
    if (file_mutation_contract.isToolName(call.name)) {
        const spec = input.tool_registry.lookup(call.name) orelse
            return std.fmt.allocPrint(alloc, "Working: {s}", .{call.name});
        return std.fmt.allocPrint(
            alloc,
            "{s} {s}",
            .{ spec.action_label, input.display_target orelse spec.label_arg_default },
        );
    }

    if (try formatRunCommandActivity(alloc, input.tool_registry, input.workspace_root, call)) |activity| {
        defer alloc.free(activity.detail);
        const action_label = if (activity.compatibility_tool) |tool| tool.action_label else "Running";
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ action_label, activity.detail });
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const spec = input.tool_registry.lookup(call.name) orelse {
        if (isProviderSearchAlias(call.name)) {
            const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
                return std.fmt.allocPrint(alloc, "Searching web", .{});
            };
            return std.fmt.allocPrint(alloc, "Searching {s}", .{try formatWebSearchActionDetail(scratch, args)});
        }
        if (input.is_available_dynamic_mcp_tool) return std.fmt.allocPrint(alloc, "MCP: {s}", .{call.name});
        return std.fmt.allocPrint(alloc, "Working: {s}", .{call.name});
    };
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return std.fmt.allocPrint(alloc, "Working: {s}", .{call.name});
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (spec.executor_kind == .web_search) {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ presentation.action_label, try formatWebSearchActionDetail(scratch, args) });
    }
    if (try copyRenameLabel(scratch, call.name, args)) |value| {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ presentation.action_label, value });
    }
    const value = input.display_target orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ presentation.action_label, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPermissionLabel(alloc: Allocator, registry: tool_dispatch.Registry, call: ToolCall) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (try runCommandCompatibilitySource(scratch, registry, call)) |source| {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ source.tool.name, source.command });
    }
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return try alloc.dupe(u8, call.name);
    };
    if (isCapturedCommandCall(registry, call, args)) {
        const command = tool_args.optionalStringArg(args, "command") orelse
            return try alloc.dupe(u8, call.name);
        return formatRunCommandPermissionLabel(alloc, command);
    }
    const spec = registry.lookup(call.name) orelse return try alloc.dupe(u8, call.name);
    if (file_mutation_contract.isToolName(call.name)) {
        return std.fmt.allocPrint(
            alloc,
            "{s} {s}",
            .{ call.name, spec.label_arg_default },
        );
    }
    if (try copyRenameLabel(scratch, call.name, args)) |value| {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ call.name, value });
    }
    const value = tool_dispatch.toolLabelValue(spec.*, args) orelse return try alloc.dupe(u8, call.name);

    if (spec.label_arg_kind == .command) {
        const suffix = try commandApprovalLabelSuffix(scratch, call.name, value);
        if (tool_args.optionalStringArg(args, "cwd")) |cwd| {
            return std.fmt.allocPrint(alloc, "{s} {s} @ {s}{s}", .{ call.name, value, cwd, suffix });
        }
        return std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ call.name, value, suffix });
    }

    return std.fmt.allocPrint(alloc, "{s} {s}", .{ call.name, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchActionDetail(alloc: Allocator, args: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var label_buf: [160]u8 = undefined;
    const query = tool_args.optionalStringArg(args, "query") orelse "web";
    try out.writer.writeAll(text_utils.clippedLabel(&label_buf, query, 120));
    try appendWebSearchDomains(&out.writer, "allowed", args.get("allowed_domains"));
    try appendWebSearchDomains(&out.writer, "blocked", args.get("blocked_domains"));
    return try out.toOwnedSlice();
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchProgressPlain(alloc: Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| std.fmt.allocPrint(
            alloc,
            "Searching {s}",
            .{text_utils.clippedLabel(&query_buf, query, 120)},
        ),
        .results_received => |entry| std.fmt.allocPrint(
            alloc,
            "Found {d} result{s} for {s}",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebFetchProgressPlain(alloc: Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| std.fmt.allocPrint(alloc, "Fetching {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
        .converting => |url| std.fmt.allocPrint(alloc, "Converting {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
    };
}

fn appendWebSearchDomains(writer: *std.Io.Writer, label: []const u8, value: ?std.json.Value) !void {
    const array = value orelse return;
    if (array != .array or array.array.items.len == 0) return;
    try writer.print(" | {s}: ", .{label});
    var domain_buf: [64]u8 = undefined;
    const shown = @min(array.array.items.len, 3);
    for (array.array.items[0..shown], 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        if (item != .string) {
            try writer.writeAll("?");
            continue;
        }
        try writer.writeAll(text_utils.clippedLabel(&domain_buf, item.string, 48));
    }
    if (array.array.items.len > shown) try writer.print(" +{d}", .{array.array.items.len - shown});
}

fn commandApprovalLabelSuffix(alloc: Allocator, tool_name: []const u8, command: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, tool_name, "run_command") and
        !std.mem.eql(u8, tool_name, "terminal")) return "";
    const risk = command_policy.command_risk_note_for(command);
    const safer = command_policy.command_safer_alternative_for(command);
    if (risk == null and safer == null) return "";
    const risk_text = if (risk) |note| stripNotePrefix(note) else null;
    if (risk_text) |note| {
        if (safer) |alternative| {
            return std.fmt.allocPrint(alloc, " (risk: {s}; {s})", .{ note, alternative });
        }
        return std.fmt.allocPrint(alloc, " (risk: {s})", .{note});
    }
    if (safer) |alternative| {
        return std.fmt.allocPrint(alloc, " ({s})", .{alternative});
    }
    return "";
}

fn stripNotePrefix(note: []const u8) []const u8 {
    const prefix = "note: ";
    if (std.mem.startsWith(u8, note, prefix)) return note[prefix.len..];
    return note;
}

const RunCommandCompatibilitySource = struct {
    tool: *const tool_dispatch.Tool,
    command: []const u8,
};

fn runCommandCompatibilitySource(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?RunCommandCompatibilitySource {
    const args = tool_args.parseToolArgsObject(alloc, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    const matched = (try tool_dispatch.matchRunCommandCompatibility(registry, command)) orelse return null;
    return .{ .tool = matched.tool, .command = command };
}

fn isCapturedCommandCall(
    registry: tool_dispatch.Registry,
    call: ToolCall,
    args: std.json.ObjectMap,
) bool {
    // Historical sessions retain their original tool name. Presentation may
    // interpret those records, but execution remains unavailable because the
    // registry no longer contains a `run_command` tool.
    if (std.mem.eql(u8, call.name, "run_command")) return true;
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected = tool.captured_command_action orelse return false;
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected);
}

fn copyRenameLabel(alloc: Allocator, tool_name: []const u8, args: std.json.ObjectMap) !?[]const u8 {
    if (std.mem.eql(u8, tool_name, "copy_file")) {
        const source = tool_args.optionalStringArg(args, "source") orelse return null;
        const destination = tool_args.optionalStringArg(args, "destination") orelse return null;
        return try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ source, destination });
    }
    if (std.mem.eql(u8, tool_name, "rename_file")) {
        const old_path = tool_args.optionalStringArg(args, "old_path") orelse return null;
        const new_path = tool_args.optionalStringArg(args, "new_path") orelse return null;
        return try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ old_path, new_path });
    }
    return null;
}

fn matchesTestSkillInstall(command: []const u8) bool {
    return std.mem.startsWith(u8, command, "npx skills add ");
}

fn executeTestSkillInstall(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "installed") };
}

const test_install_skill = blk: {
    var tool = test_builtin_tools.skill;
    tool.name = "install_skill";
    tool.gateway_schema.name = "install_skill";
    tool.executor_kind = .install_skill;
    tool.activity_kind = .write;
    tool.requires_approval = true;
    tool.action_label = "Installing skill";
    tool.completed_action_label = "Installed skill";
    tool.label_arg_kind = .source;
    tool.label_arg_default = "skill";
    tool.run_command_compatibility = .{
        .matches = matchesTestSkillInstall,
        .execute = executeTestSkillInstall,
    };
    break :blk tool;
};

const test_web_search = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "web_search";
    tool.gateway_schema.name = "web_search";
    tool.executor_kind = .web_search;
    tool.action_label = "Searching";
    tool.completed_action_label = "Searched";
    tool.label_arg_kind = .query;
    tool.label_arg_default = "web";
    break :blk tool;
};

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.rename_file,
    test_builtin_tools.copy_file,
    test_web_search,
    test_builtin_tools.terminal,
    test_builtin_tools.memory,
    test_builtin_tools.skill,
    test_install_skill,
    test_builtin_tools.ask_user_question,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_presentation_tool = blk: {
    var tool = test_builtin_tools.memory;
    tool.name = "custom_presentation";
    tool.action_label = "Inspecting";
    tool.label_arg_kind = .name;
    tool.label_arg_default = "custom fallback";
    break :blk tool;
};
const custom_presentation_registry = tool_dispatch.Registry{ .tools = &.{custom_presentation_tool} };

test "tool presentation formats dynamic MCP availability distinctly" {
    const alloc = std.testing.allocator;
    const call: ToolCall = .{
        .id = "dynamic",
        .name = "mcp_lookup",
        .arguments_json = "{}",
    };

    const available = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = call,
        .is_available_dynamic_mcp_tool = true,
    });
    defer alloc.free(available);
    try std.testing.expectEqualStrings("MCP: mcp_lookup", available);

    const unavailable = try formatPlainAction(alloc, .{ .tool_registry = test_tool_registry, .call = call });
    defer alloc.free(unavailable);
    try std.testing.expectEqualStrings("Working: mcp_lookup", unavailable);
}

test "tool presentation reads labels from the supplied registry" {
    const alloc = std.testing.allocator;
    const label = try formatPlainAction(alloc, .{
        .tool_registry = custom_presentation_registry,
        .call = .{
            .id = "custom",
            .name = "custom_presentation",
            .arguments_json = "{\"name\":\"registry metadata\"}",
        },
    });
    defer alloc.free(label);

    try std.testing.expectEqualStrings("Inspecting registry metadata", label);
}

test "tool presentation formats plain web progress variants" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        progress: union(enum) {
            search: types.WebSearchProgress,
            fetch: types.WebFetchProgress,
        },
    }{
        .{ .text = "Searching current Zig release", .progress = .{ .search = .{ .query_started = "current Zig release" } } },
        .{ .text = "Found 1 result for current Zig release", .progress = .{ .search = .{ .results_received = .{ .query = "current Zig release", .result_count = 1 } } } },
        .{ .text = "Fetching https://ziglang.org", .progress = .{ .fetch = .{ .fetching = "https://ziglang.org" } } },
        .{ .text = "Converting https://ziglang.org", .progress = .{ .fetch = .{ .converting = "https://ziglang.org" } } },
    };

    for (cases) |case| {
        const text = switch (case.progress) {
            .search => |progress| try formatWebSearchProgressPlain(alloc, progress),
            .fetch => |progress| try formatWebFetchProgressPlain(alloc, progress),
        };
        defer alloc.free(text);
        try std.testing.expectEqualStrings(case.text, text);
    }
}

test "run command presentation resolves registered compatibility" {
    const alloc = std.testing.allocator;
    const call = ToolCall{
        .id = "install",
        .name = "run_command",
        .arguments_json = "{\"command\":\"npx skills add vercel-labs/agent-skills -g -y\"}",
    };
    const activity = (try formatRunCommandActivity(alloc, test_tool_registry, "", call)) orelse
        return error.TestExpectedEqual;
    defer alloc.free(activity.detail);

    const compatibility_tool = activity.compatibility_tool orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("install_skill", compatibility_tool.name);

    const action = try formatPlainAction(alloc, .{ .tool_registry = test_tool_registry, .call = call });
    defer alloc.free(action);
    try std.testing.expectEqualStrings("Installing skill npx skills add vercel-labs/agent-skills -g -y", action);

    const permission = try formatPermissionLabel(alloc, test_tool_registry, call);
    defer alloc.free(permission);
    try std.testing.expectEqualStrings("install_skill npx skills add vercel-labs/agent-skills -g -y", permission);
}

test "run command activity projects line boundaries without changing other bytes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        arguments_json: []const u8,
        expected: []const u8,
    }{
        .{
            .arguments_json = "{\"command\":\"cat <<'EOF'\\nline one\\nEOF\"}",
            .expected = "cat <<'EOF' line one EOF",
        },
        .{
            .arguments_json = "{\"command\":\"\\r\\n\\tprintf first\\r\\n    printf  second\\r\\t\\n\"}",
            .expected = "printf first printf  second",
        },
        .{
            .arguments_json = "{\"command\":\"printf  'literal \\\\x0a'\"}",
            .expected = "printf  'literal \\x0a'",
        },
        .{
            .arguments_json = "{\"command\":\"printf \\u0007\"}",
            .expected = "printf \\x07",
        },
    };

    for (cases) |case| {
        const activity = (try formatRunCommandActivity(alloc, test_tool_registry, "", .{
            .id = "projected_command",
            .name = "run_command",
            .arguments_json = case.arguments_json,
        })) orelse return error.TestExpectedEqual;
        defer alloc.free(activity.detail);

        try std.testing.expectEqualStrings(case.expected, activity.detail);
    }
}

test "run command activity abbreviates only active workspace paths" {
    const alloc = std.testing.allocator;
    const workspace_root = "/Users/example/workspace";
    const cases = [_]struct {
        arguments_json: []const u8,
        expected: []const u8,
    }{
        .{
            .arguments_json = "{\"command\":\"cd /Users/example/workspace/packages/cli && pwd\"}",
            .expected = "cd ./packages/cli && pwd",
        },
        .{
            .arguments_json = "{\"command\":\"printf '/Users/example/workspace'\"}",
            .expected = "printf '.'",
        },
        .{
            .arguments_json = "{\"command\":\"printf \\\"/Users/example/workspace/src/main.zig\\\"\"}",
            .expected = "printf \"./src/main.zig\"",
        },
        .{
            .arguments_json = "{\"command\":\"printf /Users/example/workspace /Users/example/workspace/src\"}",
            .expected = "printf . ./src",
        },
        .{
            .arguments_json = "{\"command\":\"cd /Users/example/workspace-other && pwd\"}",
            .expected = "cd /Users/example/workspace-other && pwd",
        },
        .{
            .arguments_json = "{\"command\":\"cd /Users/example/other && pwd\"}",
            .expected = "cd /Users/example/other && pwd",
        },
        .{
            .arguments_json = "{\"command\":\"cd /prefix/Users/example/workspace && pwd\"}",
            .expected = "cd /prefix/Users/example/workspace && pwd",
        },
    };

    for (cases) |case| {
        const call: ToolCall = .{
            .id = "workspace_command",
            .name = "run_command",
            .arguments_json = case.arguments_json,
        };
        const activity = (try formatRunCommandActivity(
            alloc,
            test_tool_registry,
            workspace_root ++ "/",
            call,
        )) orelse return error.TestExpectedEqual;
        defer alloc.free(activity.detail);
        try std.testing.expectEqualStrings(case.expected, activity.detail);
    }

    const permission = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "raw_workspace_command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"cd /Users/example/workspace/packages/cli && pwd\"}",
    });
    defer alloc.free(permission);
    try std.testing.expectEqualStrings(
        "terminal.exec cd /Users/example/workspace/packages/cli && pwd",
        permission,
    );
}

test "run command activity hides only a leading no-op current directory prefix" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        command: []const u8,
        expected: []const u8,
    }{
        .{ .command = "cd . && zig build", .expected = "zig build" },
        .{ .command = "cd . &&\n  zig build test", .expected = "zig build test" },
        .{ .command = "cd ./packages && pwd", .expected = "cd ./packages && pwd" },
        .{ .command = "cd .. && pwd", .expected = "cd .. && pwd" },
        .{ .command = "cd . || pwd", .expected = "cd . || pwd" },
        .{ .command = "printf 'cd . && pwd'", .expected = "printf 'cd . && pwd'" },
        .{ .command = "cd . &&", .expected = "cd . &&" },
    };

    for (cases) |case| {
        const arguments_json = try std.fmt.allocPrint(alloc, "{{\"command\":{f}}}", .{std.json.fmt(case.command, .{})});
        defer alloc.free(arguments_json);
        const activity = (try formatRunCommandActivity(alloc, test_tool_registry, "", .{
            .id = "current_directory_command",
            .name = "run_command",
            .arguments_json = arguments_json,
        })) orelse return error.TestExpectedEqual;
        defer alloc.free(activity.detail);

        try std.testing.expectEqualStrings(case.expected, activity.detail);
    }

    const permission = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "raw_current_directory_command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"cd . && zig build\"}",
    });
    defer alloc.free(permission);
    try std.testing.expectEqualStrings("terminal.exec cd . && zig build", permission);
}

test "tool presentation formats bounded web search action detail" {
    const alloc = std.testing.allocator;
    const label = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "call_search",
            .name = "web_search",
            .arguments_json = "{\"query\":\"current Zig release\",\"blocked_domains\":[\"spam.example\",\"ads.example\"]}",
        },
    });
    defer alloc.free(label);
    try std.testing.expectEqualStrings("Searching current Zig release | blocked: spam.example, ads.example", label);
}

test "tool presentation bounds a large multiline run command activity" {
    const alloc = std.testing.allocator;
    const arguments_json = "{\"command\":\"" ++ ("é\\r\\n" ** 20_000) ++ "\"}";
    const label = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "large_command",
            .name = "run_command",
            .arguments_json = arguments_json,
        },
    });
    defer alloc.free(label);

    try std.testing.expect(label.len <= 128);
    try std.testing.expect(std.mem.findScalar(u8, label, '\r') == null);
    try std.testing.expect(std.mem.findScalar(u8, label, '\n') == null);
    try std.testing.expect(std.mem.find(u8, label, "\\x0a") == null);
    try std.testing.expect(std.mem.find(u8, label, "\\x0d") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expect(std.mem.endsWith(u8, label, "..."));
}

test "tool presentation formats permission labels" {
    const alloc = std.testing.allocator;
    const cwd = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"npm test\",\"cwd\":\"/tmp/fx\"}",
    });
    defer alloc.free(cwd);
    try std.testing.expectEqualStrings("terminal.exec npm test", cwd);

    const risk = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "risk",
        .name = "run_command",
        .arguments_json = "{\"command\":\"git reset --hard\"}",
    });
    defer alloc.free(risk);
    try expectContains(risk, "risk: command may discard version-control state");
    try expectContains(risk, "safer: inspect git status first");
}

test "tool presentation preserves plain action fallbacks" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        call: ToolCall,
        expected: []const u8,
    }{
        .{ .call = .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"src/main.zig\"}" }, .expected = "Reading src/main.zig" },
        .{ .call = .{ .id = "command", .name = "run_command", .arguments_json = "{\"command\":\"zig build\"}" }, .expected = "Running zig build" },
        .{ .call = .{ .id = "ask", .name = "ask_user_question", .arguments_json = "{}" }, .expected = "Asking " },
        .{ .call = .{ .id = "memory", .name = "memory", .arguments_json = "{\"action\":\"save\"}" }, .expected = "Remembering save" },
        .{ .call = .{ .id = "skill", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" }, .expected = "Loading skill workflow" },
        .{ .call = .{ .id = "install", .name = "install_skill", .arguments_json = "{\"source\":\"vercel-labs/agent-skills\",\"skill\":\"workflow\"}" }, .expected = "Installing skill vercel-labs/agent-skills" },
        .{ .call = .{ .id = "copy", .name = "copy_file", .arguments_json = "{\"source\":\"src/a.zig\",\"destination\":\"src/b.zig\"}" }, .expected = "Copying src/a.zig -> src/b.zig" },
        .{ .call = .{ .id = "rename", .name = "rename_file", .arguments_json = "{\"old_path\":\"src/a.zig\",\"new_path\":\"src/b.zig\"}" }, .expected = "Renaming src/a.zig -> src/b.zig" },
        .{ .call = .{ .id = "unknown", .name = "unknown_tool", .arguments_json = "{}" }, .expected = "Working: unknown_tool" },
    };

    for (cases) |case| {
        const label = try formatPlainAction(alloc, .{ .tool_registry = test_tool_registry, .call = case.call });
        defer alloc.free(label);
        try std.testing.expectEqualStrings(case.expected, label);
    }
}

test "terminal display target is call-local across a cold inspect projection update" {
    const alloc = std.testing.allocator;
    const session_id = "terminal-cold-session";
    const facts = terminal_contracts.SessionFacts{
        .session_id = session_id,
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
        .output_cursor = .{ .segment = 1, .offset = 0 },
        .screen_recovery = .{ .unavailable = .missing },
    };
    var projection: terminal_ui_projection.Store = .{};
    defer projection.deinit(alloc);
    try projection.observe(
        alloc,
        .{ .list = .{} },
        .{ .success = .{ .list = .{ .sessions = &.{facts} } } },
    );

    const inspect_call = ToolCall{
        .id = "inspect",
        .name = "terminal",
        .arguments_json = "{\"action\":\"inspect\",\"session_id\":\"terminal-cold-session\"}",
    };
    var cold_snapshot = try projection.snapshot(alloc);
    const current_target = try resolveTerminalDisplayTargetFromRows(
        alloc,
        test_tool_registry,
        "/tmp/workspace",
        inspect_call,
        cold_snapshot.rows,
    ) orelse return error.TestExpectedEqual;
    cold_snapshot.deinit();
    defer alloc.free(current_target);
    try std.testing.expectEqualStrings("session terminal-cold-session", current_target);

    try projection.observe(
        alloc,
        .{ .inspect = .{ .session_id = session_id } },
        .{ .success = .{ .inspect = .{
            .session = facts,
            .shell = "/bin/zsh",
            .cwd = "/tmp/workspace",
            .command = "npm run dev",
        } } },
    );
    try std.testing.expectEqualStrings("session terminal-cold-session", current_target);

    var learned_snapshot = try projection.snapshot(alloc);
    defer learned_snapshot.deinit();
    const next_target = try resolveTerminalDisplayTargetFromRows(
        alloc,
        test_tool_registry,
        "/tmp/workspace",
        .{
            .id = "read",
            .name = "terminal",
            .arguments_json = "{\"action\":\"read\",\"session_id\":\"terminal-cold-session\"}",
        },
        learned_snapshot.rows,
    ) orelse return error.TestExpectedEqual;
    defer alloc.free(next_target);
    try std.testing.expectEqualStrings("npm run dev", next_target);
}

test "tool presentation frees all formatted output with a normal allocator" {
    const alloc = std.testing.allocator;

    const search = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "search",
            .name = "web_search",
            .arguments_json = "{\"query\":\"current Zig release\",\"allowed_domains\":[\"ziglang.org\"]}",
        },
    });
    defer alloc.free(search);
    try std.testing.expectEqualStrings("Searching current Zig release | allowed: ziglang.org", search);

    const provider_search = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "provider_search",
            .name = "perplexity_search",
            .arguments_json = "{}",
            .provenance = .provider_executed,
        },
    });
    defer alloc.free(provider_search);
    try std.testing.expectEqualStrings("Searching web", provider_search);

    const copy = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "copy",
            .name = "copy_file",
            .arguments_json = "{\"source\":\"src/a.zig\",\"destination\":\"src/b.zig\"}",
        },
    });
    defer alloc.free(copy);
    try std.testing.expectEqualStrings("Copying src/a.zig -> src/b.zig", copy);

    const command = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"git reset --hard\"}",
    });
    defer alloc.free(command);
    try expectContains(command, "risk: command may discard version-control state");

    const fallback = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "malformed",
        .name = "memory",
        .arguments_json = "{",
    });
    defer alloc.free(fallback);
    try std.testing.expectEqualStrings("memory", fallback);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"query\":\"current Zig release\",\"blocked_domains\":[\"spam.example\"]}", .{});
    defer parsed.deinit();
    const detail = try formatWebSearchActionDetail(alloc, parsed.value.object);
    defer alloc.free(detail);
    try std.testing.expectEqualStrings("current Zig release | blocked: spam.example", detail);
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, text, needle) != null);
}

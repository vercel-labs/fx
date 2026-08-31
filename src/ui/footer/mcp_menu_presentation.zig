const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const mcp_health = @import("../../core/mcp/health.zig");
const mcp_menu_state = @import("../../core/mcp/menu_state.zig");
const app_mcp_runtime = @import("../../core/app/app_mcp_runtime.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const McpMenuProjection = render_input.McpMenuProjection;

const roomy_header_rows: u16 = 2;
pub const max_inline_rows: u16 = 12;

pub fn menuRowCount(projection: McpMenuProjection, width: u16, max_rows: u16) u16 {
    if (!projection.state.active or max_rows == 0) return 0;
    const header_rows: u16 = if (max_rows > 2) roomy_header_rows else 0;
    const body_budget = max_rows - header_rows;
    if (body_budget == 0) return header_rows;
    const body_rows: u16 = switch (projection.state.screen) {
        .browse => @intCast(@min(
            @max(projection.itemCount(), @as(usize, 1)),
            body_budget,
        )),
        .details => @min(@as(u16, 7), body_budget),
        .preview => @min(previewVisualRowCount(projection.preview, width), body_budget),
        .add => @min(
            if (projection.state.add_transport == .local) @as(u16, 5) else @as(u16, 4),
            body_budget,
        ),
        .arguments => @intCast(@min(
            @max(projection.arguments.len, @as(usize, 1)),
            body_budget,
        )),
        .info => @min(@as(u16, 2), body_budget),
        .confirm => 1,
    };
    return header_rows + body_rows;
}

pub fn visibleItemsForBudget(row_budget: u16) u16 {
    const header_rows: u16 = if (row_budget > 2) roomy_header_rows else 0;
    return @max(row_budget -| header_rows, 1);
}

pub noinline fn composeMcpMenuRow(
    alloc: Allocator,
    projection: McpMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count or !projection.state.active) return empty;
    const show_header = row_count > 2;
    const body_start: u16 = if (show_header) roomy_header_rows else 0;
    if (show_header and row_index == 0) return composeHeader(alloc, projection, width);
    if (show_header and row_index == 1 and projection.feedback != null) {
        return composeTextRow(
            alloc,
            projection.feedback.?,
            width,
            if (projection.state.load_state == .failed) ui_render.warning_style else ui_render.dim_style,
            2,
        );
    }
    if (show_header and row_index == 1 and
        projection.state.screen == .arguments and projection.state.load_state == .loading)
    {
        return composeTextRow(
            alloc,
            "Completing MCP argument…",
            width,
            ui_render.dim_style,
            2,
        );
    }
    if (show_header and row_index == 1 and projection.state.query_len > 0) {
        var filter_buf: [160]u8 = undefined;
        const filter = std.fmt.bufPrint(
            &filter_buf,
            "Filter: {s}",
            .{projection.state.queryText()},
        ) catch "Filter";
        return composeTextRow(alloc, filter, width, ui_render.dim_style, 2);
    }
    if (row_index < body_start) return empty;
    const body_index = row_index - body_start;
    return switch (projection.state.screen) {
        .browse => composeBrowseRow(alloc, projection, body_index, width, row_count - body_start),
        .details => composeDetailsRow(alloc, projection, body_index, width),
        .preview => composePreviewRow(
            alloc,
            projection,
            body_index,
            width,
            row_count - body_start,
        ),
        .add => composeAddRow(alloc, projection, body_index, width),
        .arguments => composeArgumentRow(alloc, projection, body_index, width),
        .info => composeInfoRow(alloc, body_index, width),
        .confirm => composeTextRow(
            alloc,
            confirmationText(projection.state.confirmation_action),
            width,
            ui_render.warning_style,
            0,
        ),
    };
}

fn composeArgumentRow(
    alloc: Allocator,
    projection: McpMenuProjection,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (row_index >= projection.arguments.len) return .empty;
    const field = projection.arguments[row_index];
    const selected = row_index == projection.state.argument_index;
    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(
        &label_buf,
        "{s}{s}{s}",
        .{ if (selected) "> " else "", field.name, if (field.required) " *" else "" },
    ) catch field.name;
    const value = if (selected and projection.argument_draft.len > 0)
        projection.argument_draft
    else
        field.value.items;
    return composeFactRow(alloc, label, value, width);
}

fn confirmationText(action: ?mcp_menu_state.Action) []const u8 {
    return switch (action orelse return "Confirm this MCP action before continuing.") {
        .remove => "Remove this profile MCP server? Press Enter to confirm.",
        .logout => "Log out of this MCP server? Press Enter to confirm.",
        .trust_reject => "Reject this project MCP server? Press Enter to confirm.",
        .trust_approve_all => "Approve all pending project MCP servers? Press Enter to confirm.",
        .trust_reset => "Reset all project MCP choices? Press Enter to confirm.",
        else => "Confirm this MCP action before continuing.",
    };
}

fn composeHeader(alloc: Allocator, projection: McpMenuProjection, width: u16) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try wide.appendSlice(alloc, ui_render.selected_completion_style);
    var title_buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "MCP {d}", .{projection.servers.len}) catch "MCP";
    try wide.appendSlice(alloc, title);
    try wide.appendSlice(alloc, ui_render.reset_style);
    inline for (std.meta.fields(mcp_menu_state.Section)) |field| {
        const section: mcp_menu_state.Section = @enumFromInt(field.value);
        try wide.appendSlice(alloc, "  ");
        try appendSectionTab(alloc, &wide, section, section == projection.state.section);
    }
    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) return cloneClipped(alloc, wide.items, width);

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try compact.appendSlice(alloc, ui_render.selected_completion_style);
    try compact.appendSlice(alloc, title);
    try compact.appendSlice(alloc, ui_render.reset_style);
    try compact.appendSlice(alloc, "  ");
    try appendSectionTab(alloc, &compact, projection.state.section, true);
    return cloneClipped(alloc, compact.items, width);
}

fn appendSectionTab(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    section: mcp_menu_state.Section,
    active: bool,
) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, switch (section) {
        .servers => "Servers",
        .tools => "Tools",
        .resources => "Resources",
        .prompts => "Prompts",
    });
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn composeBrowseRow(
    alloc: Allocator,
    projection: McpMenuProjection,
    body_index: u16,
    width: u16,
    visible_rows: u16,
) !std.ArrayList(u8) {
    if (projection.state.load_state == .loading) {
        if (body_index > 0) return .empty;
        return composeTextRow(alloc, "Loading MCP catalog…", width, ui_render.dim_style, 2);
    }
    if (projection.state.load_state == .failed and projection.feedback != null) {
        if (body_index > 0) return .empty;
        return composeTextRow(alloc, projection.feedback.?, width, ui_render.warning_style, 2);
    }
    const count = projection.itemCount();
    if (count == 0) {
        if (body_index > 0) return .empty;
        const text = if (projection.state.query_len > 0)
            "No matching MCP items."
        else switch (projection.state.section) {
            .servers => if (projection.configuration_issue_count == 0)
                "No MCP servers configured."
            else
                "No MCP servers available; configuration errors need attention.",
            .tools => "No MCP tools available.",
            .resources => "No MCP resources available.",
            .prompts => "No MCP prompts available.",
        };
        return composeTextRow(alloc, text, width, ui_render.dim_style, 2);
    }

    const visible = @max(@min(@as(usize, visible_rows), count), 1);
    const window_start = visibleWindowStart(
        projection.state.window_start,
        projection.state.selected_index,
        count,
        visible,
    );
    const display_index = window_start + body_index;
    if (display_index >= count) return .empty;
    return switch (projection.state.section) {
        .servers => composeServerRow(
            alloc,
            projection.servers[display_index],
            display_index == projection.state.selected_index,
            width,
        ),
        .tools => if (projection.toolAt(display_index)) |tool|
            composeCatalogRow(
                alloc,
                tool,
                "Tool",
                display_index == projection.state.selected_index,
                width,
            )
        else
            .empty,
        .resources => if (projection.resourceAt(display_index)) |resource|
            composeCatalogRow(
                alloc,
                resource.uri,
                resource.title orelse resource.description orelse if (resource.is_template) "Template" else resource.name,
                display_index == projection.state.selected_index,
                width,
            )
        else
            .empty,
        .prompts => if (projection.promptAt(display_index)) |prompt|
            composeCatalogRow(
                alloc,
                prompt.title orelse prompt.name,
                prompt.description orelse "Prompt",
                display_index == projection.state.selected_index,
                width,
            )
        else
            .empty,
    };
}

fn composeInfoRow(alloc: Allocator, row_index: u16, width: u16) !std.ArrayList(u8) {
    return switch (row_index) {
        0 => composeFactRow(alloc, "Profile config", "~/.fx/mcp.json", width),
        1 => composeFactRow(alloc, "Project config", "<workspace>/.mcp.json", width),
        else => .empty,
    };
}

fn visibleWindowStart(
    requested_start: usize,
    selected_index: usize,
    item_count: usize,
    visible_count: usize,
) usize {
    if (item_count == 0) return 0;
    const visible = @max(@min(visible_count, item_count), 1);
    const selected = @min(selected_index, item_count - 1);
    var start = @min(requested_start, item_count - visible);
    if (selected < start) start = selected;
    if (selected >= start + visible) start = selected - visible + 1;
    return @min(start, item_count - visible);
}

fn composeCatalogRow(
    alloc: Allocator,
    identity: []const u8,
    description: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width > 4) try row.appendSlice(alloc, "  ");
    try row.appendSlice(
        alloc,
        if (selected) ui_render.selected_completion_style else ui_render.dim_style,
    );
    if (width >= 76) {
        const identity_width: usize = @min(34, @as(usize, width) -| 4);
        try appendTerminalSafeSingleLine(alloc, &row, identity, identity_width);
        try row_text.appendSpacesToColumn(alloc, &row, identity_width + 4);
        try appendTerminalSafeSingleLine(
            alloc,
            &row,
            description,
            @as(usize, width) -| identity_width -| 4,
        );
    } else {
        try appendTerminalSafeSingleLine(alloc, &row, identity, @as(usize, width) -| 2);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeServerRow(
    alloc: Allocator,
    server: mcp_health.ServerSnapshot,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width > 4) try row.appendSlice(alloc, "  ");
    const style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);

    const name_width: usize = if (width >= 80) 20 else if (width >= 56) 16 else @as(usize, width) -| 2;
    try appendTerminalSafeSingleLine(alloc, &row, server.configured_name, name_width);
    if (width > name_width + 4) {
        try row_text.appendSpacesToColumn(alloc, &row, name_width + 4);
        const state = serverStateLabel(server);
        const state_width: usize = if (width >= 80) 20 else @as(usize, width) -| name_width -| 4;
        try appendTerminalSafeSingleLine(alloc, &row, state, state_width);
    }
    if (width >= 80) {
        try row_text.appendSpacesToColumn(alloc, &row, 44);
        var meta_buf: [160]u8 = undefined;
        const meta = serverMetadata(&meta_buf, server);
        try appendTerminalSafeSingleLine(alloc, &row, meta, @as(usize, width) -| 44);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn serverStateLabel(server: mcp_health.ServerSnapshot) []const u8 {
    if (server.workspace_admission == .pending) return "Pending trust";
    if (server.authentication == .required) return "Needs authentication";
    return switch (server.connection) {
        .disconnected => "Disconnected",
        .disabled => "Disabled",
        .connecting => "Connecting",
        .ready => "Ready",
        .failed => "Failed",
    };
}

fn serverMetadata(buf: []u8, server: mcp_health.ServerSnapshot) []const u8 {
    const source = switch (server.source) {
        .profile => "Profile",
        .workspace => "Project",
        .acp => "ACP",
    };
    const transport = switch (server.transport) {
        .stdio => "stdio",
        .http => "HTTP",
        .sse => "SSE",
    };
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ transport, source }) catch source;
}

fn composeDetailsRow(
    alloc: Allocator,
    projection: McpMenuProjection,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const server = projection.selectedServer() orelse return composeTextRow(
        alloc,
        "MCP server is no longer available.",
        width,
        ui_render.warning_style,
        2,
    );
    var value_buf: [192]u8 = undefined;
    const pair: struct { label: []const u8, value: []const u8 } = switch (row_index) {
        0 => .{ .label = "Server", .value = server.configured_name },
        1 => .{ .label = "State", .value = serverStateLabel(server.*) },
        2 => .{ .label = "Source", .value = switch (server.source) {
            .profile => "Profile · ~/.fx/mcp.json",
            .workspace => "Project · .mcp.json",
            .acp => "ACP session",
        } },
        3 => .{ .label = "Transport", .value = @tagName(server.transport) },
        4 => .{ .label = "Policy", .value = if (server.required) "required" else "optional" },
        5 => .{ .label = "Protocol", .value = server.protocol_version orelse "unavailable" },
        6 => .{ .label = "Capabilities", .value = capabilitySummary(&value_buf, server.counts) },
        else => return .empty,
    };
    return composeFactRow(alloc, pair.label, pair.value, width);
}

fn capabilitySummary(buf: []u8, counts: mcp_health.CapabilityCounts) []const u8 {
    var tools_buf: [24]u8 = undefined;
    var resources_buf: [24]u8 = undefined;
    var templates_buf: [24]u8 = undefined;
    var prompts_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "tools={s} resources={s} templates={s} prompts={s}", .{
        formatOptionalCount(&tools_buf, counts.tools),
        formatOptionalCount(&resources_buf, counts.resources),
        formatOptionalCount(&templates_buf, counts.resource_templates),
        formatOptionalCount(&prompts_buf, counts.prompts),
    }) catch "unavailable";
}

fn formatOptionalCount(buf: []u8, value: ?usize) []const u8 {
    return if (value) |count|
        std.fmt.bufPrint(buf, "{d}", .{count}) catch "?"
    else
        "?";
}

fn composePreviewRow(
    alloc: Allocator,
    projection: McpMenuProjection,
    row_index: u16,
    width: u16,
    visible_rows: u16,
) !std.ArrayList(u8) {
    const text = projection.preview orelse "Loading MCP content…";
    const total_rows = previewVisualRowCount(projection.preview, width);
    const max_start = total_rows -| @min(visible_rows, total_rows);
    const window_start: u16 = @intCast(@min(projection.state.window_start, max_start));
    const line = previewVisualRow(text, window_start +| row_index, width) orelse return .empty;
    return composeTextRow(alloc, line, width, ui_render.dim_style, 2);
}

pub fn previewVisualRowCount(preview: ?[]const u8, width: u16) u16 {
    const text = preview orelse return 1;
    const content_width: usize = width -| 2;
    if (content_width == 0) return 1;
    var count: u16 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            count +|= 1;
            continue;
        }
        var remaining = line;
        while (remaining.len > 0) {
            const chunk = previewChunk(remaining, content_width);
            count +|= 1;
            remaining = display_width.trimBreakWhitespace(remaining[chunk.len..]);
        }
    }
    return count;
}

fn previewVisualRow(text: []const u8, target_row: u16, width: u16) ?[]const u8 {
    const content_width: usize = width -| 2;
    if (content_width == 0) return "";
    var visual_row: u16 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (visual_row == target_row) return "";
            visual_row +|= 1;
            continue;
        }
        var remaining = line;
        while (remaining.len > 0) {
            const chunk = previewChunk(remaining, content_width);
            if (visual_row == target_row) return chunk;
            visual_row +|= 1;
            remaining = display_width.trimBreakWhitespace(remaining[chunk.len..]);
        }
    }
    return null;
}

fn previewChunk(remaining: []const u8, content_width: usize) []const u8 {
    const chunk = display_width.prefixByWidth(remaining, content_width);
    if (chunk.len == remaining.len) return chunk;

    var last_break: ?usize = null;
    var saw_content = false;
    var index: usize = 0;
    while (index < chunk.len) {
        const unit = display_width.displayUnitAt(chunk, index);
        if (chunk[index] == ' ' or chunk[index] == '\t') {
            if (saw_content) last_break = index;
        } else {
            saw_content = true;
        }
        index += unit.byte_len;
    }
    if (last_break) |break_index| return remaining[0..break_index];
    if (chunk.len > 0) return chunk;

    const sequence_len = std.unicode.utf8ByteSequenceLength(remaining[0]) catch 1;
    return remaining[0..@min(sequence_len, remaining.len)];
}

fn composeAddRow(
    alloc: Allocator,
    projection: McpMenuProjection,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const field_index = projection.state.add_field_index;
    const local = projection.state.add_transport == .local;
    const row: struct { label: []const u8, value: []const u8 } = switch (row_index) {
        0 => .{ .label = "Transport", .value = if (local) "Local" else "HTTP" },
        1 => .{
            .label = if (field_index == 0) "> Name" else "Name",
            .value = if (field_index == 0) projection.add_draft else projection.add_name,
        },
        2 => .{
            .label = if (field_index == 1)
                if (local) "> Command" else "> URL"
            else if (local)
                "Command"
            else
                "URL",
            .value = if (field_index == 1) projection.add_draft else projection.add_target,
        },
        3 => if (local) .{
            .label = if (field_index == 2) "> Arguments" else "Arguments",
            .value = if (field_index == 2) projection.add_draft else projection.add_arguments,
        } else .{ .label = "Scope", .value = "Profile" },
        4 => if (local)
            .{ .label = "Scope", .value = "Profile" }
        else
            return .empty,
        else => return .empty,
    };
    return composeFactRow(alloc, row.label, row.value, width);
}

fn composeFactRow(alloc: Allocator, label: []const u8, value: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    if (width > 4) try row.appendSlice(alloc, "  ");
    const value_col: usize = @min(22, width);
    try appendTerminalSafeSingleLine(alloc, &row, label, value_col -| 2);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try appendTerminalSafeSingleLine(alloc, &row, value, @as(usize, width) -| value_col);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeTextRow(
    alloc: Allocator,
    text: []const u8,
    width: u16,
    style: []const u8,
    indent: usize,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, style);
    if (indent > 0) try row.appendNTimes(alloc, ' ', @min(indent, width));
    try appendTerminalSafeSingleLine(alloc, &row, text, @as(usize, width) -| indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClipped(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    return row;
}

fn appendTerminalSafeSingleLine(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    var encoded = try text_utils.encodeTerminalSafe(alloc, text, 4096);
    defer encoded.deinit(alloc);
    try row_text.appendSingleLineEllipsized(alloc, row, encoded.bytes, width);
}

test "MCP menu empty server state is compact and actionable" {
    const projection: McpMenuProjection = .{
        .state = .{ .active = true, .load_state = .ready },
    };
    const rows = menuRowCount(projection, 100, 20);
    try std.testing.expectEqual(@as(u16, 3), rows);

    var header = try composeMcpMenuRow(std.testing.allocator, projection, 0, 100, rows);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "MCP 0") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[Servers]") != null);

    var empty = try composeMcpMenuRow(std.testing.allocator, projection, 2, 100, rows);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, empty.items, "No MCP servers configured.") != null);
}

test "MCP menu rows stay within narrow terminal width" {
    const projection: McpMenuProjection = .{
        .state = .{ .active = true, .load_state = .ready },
    };
    const rows = menuRowCount(projection, 24, 4);
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeMcpMenuRow(std.testing.allocator, projection, row_index, 24, rows);
        defer row.deinit(std.testing.allocator);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 24);
    }
}

test "MCP menu catalog text cannot inject terminal control sequences" {
    const tools = [_][]const u8{"mcp_bad\x1b]0;owned\x07"};
    const projection: McpMenuProjection = .{
        .state = .{
            .active = true,
            .section = .tools,
            .load_state = .ready,
        },
        .tools = &tools,
    };
    const rows = menuRowCount(projection, 100, 10);
    var row = try composeMcpMenuRow(std.testing.allocator, projection, 2, 100, rows);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b]0;owned") == null);
    try std.testing.expect(std.mem.find(u8, row.items, "\\x1b") != null);
}

test "MCP menu keeps selection visible when the terminal has one body row" {
    const tools = [_][]const u8{
        "tool-0",
        "tool-1",
        "tool-2",
        "tool-3",
        "tool-4",
        "tool-5",
    };
    const projection: McpMenuProjection = .{
        .state = .{
            .active = true,
            .section = .tools,
            .selected_index = 5,
            .window_start = 0,
            .load_state = .ready,
        },
        .tools = &tools,
    };
    const rows = menuRowCount(projection, 40, 3);
    try std.testing.expectEqual(@as(u16, 3), rows);
    var row = try composeMcpMenuRow(std.testing.allocator, projection, 2, 40, rows);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "tool-5") != null);
}

test "MCP preview wraps one long logical line across terminal rows" {
    const projection: McpMenuProjection = .{
        .state = .{
            .active = true,
            .section = .tools,
            .screen = .preview,
            .load_state = .ready,
        },
        .preview = "0123456789abcdefghijkl",
    };
    const rows = menuRowCount(projection, 12, 10);
    try std.testing.expectEqual(@as(u16, 5), rows);

    var first = try composeMcpMenuRow(std.testing.allocator, projection, 2, 12, rows);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, first.items, "0123456789") != null);
    try std.testing.expect(std.mem.find(u8, first.items, "…") == null);

    var second = try composeMcpMenuRow(std.testing.allocator, projection, 3, 12, rows);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, second.items, "abcdefghij") != null);

    var third = try composeMcpMenuRow(std.testing.allocator, projection, 4, 12, rows);
    defer third.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, third.items, "kl") != null);
}

test "MCP preview keeps fitting words intact across visual rows" {
    const text = "alpha documentation beta";
    try std.testing.expectEqualStrings(
        "alpha",
        previewVisualRow(text, 0, 16).?,
    );
    try std.testing.expectEqualStrings(
        "documentation",
        previewVisualRow(text, 1, 16).?,
    );
    try std.testing.expectEqualStrings(
        "beta",
        previewVisualRow(text, 2, 16).?,
    );
}

test "MCP preview renders from its vertical window offset" {
    const projection: McpMenuProjection = .{
        .state = .{
            .active = true,
            .section = .tools,
            .screen = .preview,
            .window_start = 2,
            .load_state = .ready,
        },
        .preview = "0000000000111111111122222222223333333333",
    };
    const rows = menuRowCount(projection, 12, 4);
    try std.testing.expectEqual(@as(u16, 4), rows);
    var first = try composeMcpMenuRow(std.testing.allocator, projection, 2, 12, rows);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, first.items, "2222222222") != null);
}

test "MCP preview row count matches wide-character wrapping" {
    const projection: McpMenuProjection = .{
        .state = .{
            .active = true,
            .section = .tools,
            .screen = .preview,
            .load_state = .ready,
        },
        .preview = "界界界界",
    };
    try std.testing.expectEqual(
        @as(u16, 6),
        menuRowCount(projection, 5, 10),
    );
}

fn expectMcpMenuVtContains(
    alloc: Allocator,
    projection: McpMenuProjection,
    width: u16,
    row_budget: u16,
    needles: []const []const u8,
) !void {
    const rows = menuRowCount(projection, width, row_budget);
    try std.testing.expect(rows > 0);
    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();

    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeMcpMenuRow(
            alloc,
            projection,
            row_index,
            width,
            rows,
        );
        defer row.deinit(alloc);
        var cursor_buf: [32]u8 = undefined;
        const cursor = try std.fmt.bufPrint(
            &cursor_buf,
            "\x1b[{d};1H",
            .{row_index + 1},
        );
        try grid.feed(cursor);
        try grid.feed(row.items);
    }

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);
    var row_number: u16 = 1;
    while (row_number <= rows) : (row_number += 1) {
        if (row_number > 1) try frame.append(alloc, '\n');
        try grid.rowTextTrimmed(row_number, &frame);
    }
    for (needles) |needle| {
        try std.testing.expect(std.mem.find(u8, frame.items, needle) != null);
    }
}

test "MCP menu every screen and section renders through the VT" {
    const alloc = std.testing.allocator;
    const width: u16 = 100;
    const server = mcp_health.ServerSnapshot{
        .configured_name = @constCast("fixture"),
        .negotiated_name = @constCast("Fixture MCP"),
        .negotiated_version = @constCast("1.0"),
        .source = .profile,
        .scope = .profile,
        .required = false,
        .transport = .stdio,
        .protocol_version = @constCast("2025-06-18"),
        .connection = .ready,
        .authentication = .authenticated,
        .counts = .{
            .tools = 2,
            .resources = 3,
            .resource_templates = 1,
            .prompts = 4,
        },
        .cache_freshness = .fresh,
        .subscription = .active,
        .runtime_generation = 3,
        .catalog_generation = 4,
        .retry_attempt = 0,
        .retry_in_ms = null,
        .last_successful_discovery_ms = 10,
        .failure = null,
    };
    const servers = [_]mcp_health.ServerSnapshot{server};
    const tools = [_][]const u8{"mcp_fixture_echo"};
    const arguments = [_]app_mcp_runtime.MenuArgumentField{.{
        .name = @constCast("topic"),
        .required = true,
    }};

    var projection: McpMenuProjection = .{
        .state = .{ .active = true, .load_state = .ready },
        .servers = &servers,
        .tools = &tools,
    };
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "MCP 1", "[Servers]", "fixture", "Ready", "stdio · Profile" },
    );

    projection.state.screen = .details;
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "Server", "fixture", "Protocol", "2025-06-18", "Capabilities", "tools=2" },
    );

    projection.state = .{
        .active = true,
        .section = .tools,
        .load_state = .ready,
    };
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "[Tools]", "mcp_fixture_echo", "Tool" },
    );

    projection.state.section = .resources;
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "[Resources]", "No MCP resources available." },
    );

    projection.state.section = .prompts;
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "[Prompts]", "No MCP prompts available." },
    );

    projection.state = .{
        .active = true,
        .section = .resources,
        .screen = .preview,
        .load_state = .ready,
    };
    projection.preview = "MCP resource · untrusted content\n\nRESOURCE_TEXT: preserve this preview";
    try expectMcpMenuVtContains(
        alloc,
        projection,
        32,
        6,
        &.{ "[Resources]", "MCP resource", "untrusted", "content", "RESOURCE_TEXT: preserve this" },
    );

    projection.state = .{
        .active = true,
        .screen = .add,
        .load_state = .ready,
    };
    projection.preview = null;
    projection.add_draft = "fixture";
    projection.add_target = "/usr/bin/env";
    projection.add_arguments = "node fixture.mjs";
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "Transport", "Local", "> Name", "fixture", "Command", "Arguments", "Scope", "Profile" },
    );

    projection.state = .{
        .active = true,
        .section = .prompts,
        .screen = .arguments,
        .load_state = .ready,
    };
    projection.arguments = &arguments;
    projection.argument_draft = "alpha";
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "[Prompts]", "> topic *", "alpha" },
    );

    projection.state = .{
        .active = true,
        .screen = .info,
        .load_state = .ready,
    };
    projection.arguments = &.{};
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{ "Profile config", "~/.fx/mcp.json", "Project config", "<workspace>/.mcp.json" },
    );

    projection.state = .{
        .active = true,
        .screen = .confirm,
        .load_state = .ready,
        .confirmation_action = .remove,
    };
    try expectMcpMenuVtContains(
        alloc,
        projection,
        width,
        max_inline_rows,
        &.{"Remove this profile MCP server? Press Enter to confirm."},
    );
}

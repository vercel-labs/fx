const std = @import("std");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const usage_mod = @import("usage");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");
const workspace_menu = @import("../../core/workspace/workspace_menu.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const CompactCommandMenuProjection = render_input.CompactCommandMenuProjection;

const column_gap: usize = 4;
const workspace_pinned_rows = 5;
/// Title row plus the blank row above the first toggle choice.
const settings_row_offset: usize = 2;

const ChoiceView = struct {
    label: []const u8,
    setting: settings_catalog.SettingId,
    snapshot: settings_catalog.Snapshot,
    selected: bool,
};

pub fn desiredRowCount(projection: CompactCommandMenuProjection, width: u16) u16 {
    const count: usize = switch (projection) {
        .statusline => settings_row_offset + settings_catalog.statuslineChoiceCount(),
        .usage => |usage| usageDesiredRowCount(usage, width),
        .workspace => |workspace| workspace_pinned_rows +
            workspace_menu.State.rowCount(workspace.entries),
    };
    return std.math.cast(u16, count) orelse std.math.maxInt(u16);
}

pub noinline fn composeCompactCommandMenuRow(
    alloc: Allocator,
    projection: CompactCommandMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= visible_rows) return empty;
    return switch (projection) {
        .statusline => composeSettingsRow(alloc, projection, row_index, visible_rows, width),
        .usage => |usage| composeUsageRow(alloc, usage, row_index, visible_rows, width),
        .workspace => |workspace| composeWorkspaceRow(alloc, workspace, row_index, visible_rows, width),
    };
}

fn composeSettingsRow(
    alloc: Allocator,
    projection: CompactCommandMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    const statusline = switch (projection) {
        .statusline => |value| value,
        .usage, .workspace => return empty,
    };
    const choice_count = settings_catalog.statuslineChoiceCount();
    if (choice_count == 0) return empty;
    const selected = statusline.selected_index % choice_count;
    if (visible_rows == 1) {
        return composeChoiceRow(
            alloc,
            choiceView(projection, selected) orelse return empty,
            statuslineValueColumn(width),
            width,
        );
    }
    if (row_index == 0) {
        return composeStyledRow(alloc, "Status line", width, ui_render.selected_completion_style);
    }
    const first_choice_row: u16 = if (visible_rows == 2) 1 else settings_row_offset;
    if (row_index < first_choice_row) return empty;
    const visible_choices = @min(@as(usize, visible_rows - first_choice_row), choice_count);
    const window_start = @min(selected -| (visible_choices - 1), choice_count - visible_choices);
    const choice_index = window_start + @as(usize, row_index - first_choice_row);
    return composeChoiceRow(
        alloc,
        choiceView(projection, choice_index) orelse return empty,
        statuslineValueColumn(width),
        width,
    );
}

fn choiceView(projection: CompactCommandMenuProjection, choice_index: usize) ?ChoiceView {
    return switch (projection) {
        .statusline => |statusline| {
            const choice = settings_catalog.statuslineChoiceAt(choice_index) orelse return null;
            return .{
                .label = choice.label,
                .setting = choice.setting,
                .snapshot = statusline.snapshot,
                .selected = choice_index == statusline.selected_index % settings_catalog.statuslineChoiceCount(),
            };
        },
        .usage, .workspace => null,
    };
}

fn usageDesiredRowCount(projection: render_input.UsageMenuProjection, width: u16) usize {
    return usage_mod.render.dashboardDesiredRows(projection.dashboard, width);
}

fn composeUsageRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: usage_mod.render.Row = .{};
    usage_mod.render.dashboardRow(&row, projection.dashboard, row_index, visible_rows, width);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    row.paint(&out.writer, .{
        .title = ui_render.selected_completion_style,
        .dim = ui_render.dim_style,
        .label = ui_render.system_notice_label_style,
        .warning = ui_render.warning_style,
        .strong = ui_render.bold_style,
        .reset = ui_render.reset_style,
    }) catch return error.OutOfMemory;
    return out.toArrayList();
}

/// How many model rows the dashboard shows at this size.
pub fn usageVisibleModelItems(projection: render_input.UsageMenuProjection, visible_rows: u16, width: u16) u16 {
    return usage_mod.render.dashboardVisibleModelItems(projection.dashboard, visible_rows, width);
}

fn composeWorkspaceRow(
    alloc: Allocator,
    projection: render_input.WorkspaceMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (visible_rows < workspace_pinned_rows + 1) {
        const header_rows: u16 = @intFromBool(visible_rows > 1);
        if (header_rows == 1 and row_index == 0) {
            return composeStyledRow(alloc, "Workspace", width, ui_render.selected_completion_style);
        }
        if (row_index < header_rows) return empty;
        return composeWorkspaceChoiceRow(
            alloc,
            projection,
            row_index - header_rows,
            visible_rows - header_rows,
            width,
        );
    }
    return switch (row_index) {
        0 => composeStyledRow(alloc, "Workspace", width, ui_render.selected_completion_style),
        1 => empty,
        2 => blk: {
            var safe_path = try text_utils.encodeTerminalSafe(
                alloc,
                projection.primary_directory,
                std.math.maxInt(usize),
            );
            defer safe_path.deinit(alloc);
            break :blk try composeLabelValueRow(
                alloc,
                "Primary",
                safe_path.bytes,
                workspaceSummaryValueColumn(width),
                width,
            );
        },
        3 => blk: {
            var count_buf: [96]u8 = undefined;
            const count = if (projection.saved_suppressed)
                std.fmt.bufPrint(
                    &count_buf,
                    "{d} / {d} · Saved roots suppressed",
                    .{ projection.entries.len, workspace_access.max_additional_directories },
                ) catch "Unavailable"
            else
                std.fmt.bufPrint(
                    &count_buf,
                    "{d} / {d}",
                    .{ projection.entries.len, workspace_access.max_additional_directories },
                ) catch "Unavailable";
            break :blk try composeLabelValueRow(
                alloc,
                "Additional directories",
                count,
                workspaceSummaryValueColumn(width),
                width,
            );
        },
        4 => empty,
        else => composeWorkspaceChoiceRow(
            alloc,
            projection,
            row_index - workspace_pinned_rows,
            visible_rows - workspace_pinned_rows,
            width,
        ),
    };
}

fn composeWorkspaceChoiceRow(
    alloc: Allocator,
    projection: render_input.WorkspaceMenuProjection,
    display_row: u16,
    choice_rows_value: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    const row_count = workspace_menu.State.rowCount(projection.entries);
    const choice_rows: usize = choice_rows_value;
    if (choice_rows == 0) return empty;
    const selected = projection.selected_row;
    const max_start = row_count -| choice_rows;
    const window_start = @min(selected -| (choice_rows - 1), max_start);
    const choice_index = window_start + @as(usize, display_row);
    if (choice_index >= row_count) return empty;

    const info_column = workspaceActionInfoColumn(projection, width);

    if (choice_index == 0) {
        return composeWorkspaceActionRow(
            alloc,
            "Add directory…",
            "Grant access to another directory",
            choice_index == selected,
            info_column,
            width,
        );
    }
    if (choice_index <= projection.entries.len) {
        const entry = projection.entries[choice_index - 1];
        var safe_path = try text_utils.encodeTerminalSafe(
            alloc,
            entry.path,
            std.math.maxInt(usize),
        );
        defer safe_path.deinit(alloc);
        var status_buf: [64]u8 = undefined;
        const status = formatWorkspaceEntryStatus(&status_buf, entry);
        return composeWorkspaceActionRow(
            alloc,
            safe_path.bytes,
            status,
            entry.saved and choice_index == selected,
            info_column,
            width,
        );
    }
    return composeWorkspaceActionRow(
        alloc,
        "Clear saved directories",
        "Remove every saved additional directory",
        choice_index == selected,
        info_column,
        width,
    );
}

fn formatWorkspaceEntryStatus(
    buf: *[64]u8,
    entry: workspace_access.Entry,
) []const u8 {
    const availability = if (!entry.available)
        "Unavailable"
    else if (entry.active)
        "Active"
    else
        "Inactive";
    const source = if (entry.saved and entry.command_line)
        "Saved + launch"
    else if (entry.saved)
        "Saved"
    else if (entry.command_line)
        "Launch only"
    else
        "Session";
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ availability, source }) catch availability;
}

fn composeWorkspaceActionRow(
    alloc: Allocator,
    label: []const u8,
    info: []const u8,
    selected: bool,
    info_column: ?usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);

    try row.appendSlice(alloc, if (selected) ui_render.system_notice_label_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, if (selected) "❯ " else "  ", width);
    const used_prefix = display_width.visibleWidthIgnoringAnsi(row.items);
    const total_width: usize = width;
    if (used_prefix >= total_width) {
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    const info_start = info_column orelse {
        try row_text.appendSingleLineEllipsized(alloc, &row, label, total_width - used_prefix);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    };
    if (info_start <= used_prefix + 2) {
        try row_text.appendSingleLineEllipsized(alloc, &row, label, total_width - used_prefix);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        label,
        info_start - used_prefix - 1,
    );
    try row.appendSlice(alloc, ui_render.reset_style);

    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used >= info_start) return row;
    try row.appendNTimes(alloc, ' ', info_start - used);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, info, total_width - info_start);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn workspaceActionInfoColumn(
    projection: render_input.WorkspaceMenuProjection,
    width: u16,
) ?usize {
    const indent: usize = if (width <= 2) 0 else 2;
    const content_width: usize = width;
    var longest_label = @max(
        display_width.visibleWidth("Add directory…"),
        display_width.visibleWidth("Clear saved directories"),
    );
    var widest_info = @max(
        display_width.visibleWidth("Grant access to another directory"),
        display_width.visibleWidth("Remove every saved additional directory"),
    );
    for (projection.entries) |entry| {
        longest_label = @max(longest_label, text_utils.terminalSafeVisibleWidth(entry.path));
        var status_buf: [64]u8 = undefined;
        widest_info = @max(
            widest_info,
            display_width.visibleWidth(formatWorkspaceEntryStatus(&status_buf, entry)),
        );
    }
    if (content_width < indent + 8 + column_gap + widest_info) return null;
    return @min(indent + longest_label + column_gap, content_width - widest_info);
}

fn workspaceSummaryValueColumn(width: u16) usize {
    const indent: usize = if (width <= 2) 0 else 2;
    const longest_label = display_width.visibleWidth("Additional directories");
    return @min(indent + longest_label + column_gap, width);
}

fn composeStyledRow(
    alloc: Allocator,
    text: []const u8,
    width: u16,
    style: []const u8,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeLabelValueRow(
    alloc: Allocator,
    label: []const u8,
    value: []const u8,
    value_column: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const total_width: usize = width;
    if (total_width == 0) return row;

    try row.appendSlice(alloc, ui_render.system_notice_label_style);
    try row_text.appendClipped(alloc, &row, "  ", width);
    const prefix_used = display_width.visibleWidthIgnoringAnsi(row.items);
    const target = @min(@max(value_column, prefix_used + 2), total_width);
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        label,
        target -| prefix_used -| 1,
    );
    try row.appendSlice(alloc, ui_render.reset_style);

    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used >= total_width) return row;
    const actual_target = @max(target, used + 1);
    if (actual_target >= total_width) return row;
    try row.appendNTimes(alloc, ' ', actual_target - used);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, value, total_width - actual_target);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeChoiceRow(
    alloc: Allocator,
    choice: ChoiceView,
    value_col: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent: usize = if (width <= 2) 0 else 2;
    if (indent > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (choice.selected) ui_render.selected_completion_style else ui_render.dim_style);
    const description_col = value_col;
    try row_text.appendSingleLineEllipsized(alloc, &row, choice.label, description_col -| indent -| 2);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);

    const option_count = settings_catalog.optionCount(&choice.snapshot, choice.setting);
    var option_index: usize = 0;
    while (option_index < option_count) : (option_index += 1) {
        const before_option = display_width.visibleWidthIgnoringAnsi(row.items);
        if (before_option >= width) break;
        if (option_index > 0) try row.appendNTimes(alloc, ' ', @min(@as(usize, 2), @as(usize, width) - before_option));
        const option = settings_catalog.optionAt(&choice.snapshot, choice.setting, option_index) orelse continue;
        const current = std.ascii.eqlIgnoreCase(option, choice.snapshot.value(choice.setting));
        try row.appendSlice(alloc, if (current) ui_render.selected_completion_style else ui_render.dim_style);
        const used = display_width.visibleWidthIgnoringAnsi(row.items);
        try row_text.appendSingleLineEllipsized(alloc, &row, option, @as(usize, width) -| used);
        try row.appendSlice(alloc, ui_render.reset_style);
        if (display_width.visibleWidthIgnoringAnsi(row.items) >= width) break;
    }
    return row;
}

fn statuslineValueColumn(width: u16) usize {
    const indent: usize = if (width <= 2) 0 else 2;
    var widest_label: usize = 0;
    for (0..settings_catalog.statuslineChoiceCount()) |index| {
        const choice = settings_catalog.statuslineChoiceAt(index) orelse continue;
        widest_label = @max(widest_label, display_width.visibleWidth(choice.label));
    }
    return @min(indent + widest_label + column_gap, width);
}

test "compact status line menu renders toggled items without choose copy" {
    const projection: CompactCommandMenuProjection = .{ .statusline = .{
        .active = true,
        .selected_index = 0,
        .snapshot = .{
            .statusline_context = false,
            .statusline_session = true,
            .statusline_workspace = false,
        },
    } };

    // Every catalog choice must be reachable as a rendered row.
    const rows = desiredRowCount(projection, 80);
    try std.testing.expectEqual(
        @as(u16, @intCast(settings_row_offset + settings_catalog.statuslineChoiceCount())),
        rows,
    );

    var header = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, rows, 80);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "Status line") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Choose") == null);

    var workspace = try composeCompactCommandMenuRow(std.testing.allocator, projection, 4, rows, 80);
    defer workspace.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, workspace.items, "Workspace") != null);
    try std.testing.expect(std.mem.find(u8, workspace.items, "off") != null);

    var context = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, rows, 80);
    defer context.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, context.items, "Context") != null);
    try std.testing.expect(std.mem.find(u8, context.items, "off") != null);

    var session = try composeCompactCommandMenuRow(std.testing.allocator, projection, 3, rows, 80);
    defer session.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, session.items, "Session") != null);
    try std.testing.expect(std.mem.find(u8, session.items, "on") != null);
}

test "compact status line menu anchors options and prioritizes the selected tiny row" {
    const projection: CompactCommandMenuProjection = .{ .statusline = .{
        .active = true,
        .selected_index = 2,
        .snapshot = .{
            .statusline_context = false,
            .statusline_session = true,
            .statusline_workspace = false,
        },
    } };

    var tiny = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, 1, 80);
    defer tiny.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, tiny.items, "Workspace") != null);
    try std.testing.expect(std.mem.find(u8, tiny.items, "Status line") == null);

    var medium = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, 5, 80);
    defer medium.deinit(std.testing.allocator);
    var wide = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, 5, 180);
    defer wide.deinit(std.testing.allocator);
    const medium_option = std.mem.find(u8, medium.items, "off") orelse return error.TestExpectedOption;
    const wide_option = std.mem.find(u8, wide.items, "off") orelse return error.TestExpectedOption;
    const expected_column = 2 + display_width.visibleWidth("Workspace") + 4;
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(medium.items[0..medium_option]));
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(wide.items[0..wide_option]));
}

test "workspace menu keeps paths and status on the same width-safe row" {
    var entries = [_]workspace_access.Entry{.{
        .path = @constCast("/Users/example/Developer/Fx/docs"),
        .saved = true,
        .command_line = false,
        .available = true,
        .active = true,
    }};
    const projection: CompactCommandMenuProjection = .{ .workspace = .{
        .active = true,
        .selected_row = 1,
        .primary_directory = "/Users/example/Developer/Fx",
        .entries = &entries,
    } };

    try std.testing.expectEqual(@as(u16, 8), desiredRowCount(projection, 80));
    var primary = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, 8, 120);
    defer primary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, primary.items, "Primary") != null);
    try std.testing.expect(std.mem.find(u8, primary.items, "/Users/example/Developer/Fx") != null);

    var entry = try composeCompactCommandMenuRow(std.testing.allocator, projection, 6, 8, 120);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.findScalar(u8, entry.items, '\n') == null);
    try std.testing.expect(std.mem.find(u8, entry.items, "/Users/example/Developer/Fx/docs") != null);
    try std.testing.expect(std.mem.find(u8, entry.items, "Active · Saved") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(entry.items) <= 120);
}

test "workspace menu anchors metadata and prioritizes the selected tiny action" {
    var entries = [_]workspace_access.Entry{
        .{
            .path = @constCast("/short"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        },
        .{
            .path = @constCast("/this/is/a/much-longer-path"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        },
    };
    const projection: CompactCommandMenuProjection = .{ .workspace = .{
        .active = true,
        .selected_row = 2,
        .primary_directory = "/workspace",
        .entries = &entries,
    } };

    var header = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, 9, 80);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "Workspace") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Workspace:") == null);

    var tiny = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, 1, 100);
    defer tiny.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, tiny.items, "much-longer-path") != null);

    var medium = try composeCompactCommandMenuRow(std.testing.allocator, projection, 6, 9, 80);
    defer medium.deinit(std.testing.allocator);
    var wide = try composeCompactCommandMenuRow(std.testing.allocator, projection, 6, 9, 180);
    defer wide.deinit(std.testing.allocator);
    const medium_status = std.mem.find(u8, medium.items, "Active · Saved") orelse return error.TestExpectedStatus;
    const wide_status = std.mem.find(u8, wide.items, "Active · Saved") orelse return error.TestExpectedStatus;
    const expected_column = 2 + display_width.visibleWidth("/this/is/a/much-longer-path") + 4;
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(medium.items[0..medium_status]));
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(wide.items[0..wide_status]));
}

test "workspace menu keeps launch-only roots visible but not selectable" {
    var entries = [_]workspace_access.Entry{
        .{
            .path = @constCast("/tmp/launch-only"),
            .saved = false,
            .command_line = true,
            .available = true,
            .active = true,
        },
        .{
            .path = @constCast("/tmp/saved"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        },
    };
    const projection: CompactCommandMenuProjection = .{ .workspace = .{
        .active = true,
        .selected_row = 2,
        .primary_directory = "/tmp/workspace",
        .entries = &entries,
    } };

    try std.testing.expectEqual(@as(u16, 9), desiredRowCount(projection, 80));
    var launch_only = try composeCompactCommandMenuRow(std.testing.allocator, projection, 6, 9, 80);
    defer launch_only.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, launch_only.items, "Launch only") != null);
    try std.testing.expect(std.mem.find(u8, launch_only.items, "❯") == null);

    var saved = try composeCompactCommandMenuRow(std.testing.allocator, projection, 7, 9, 80);
    defer saved.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, saved.items, "❯ /tmp/saved") != null);
}

test "compact command menu rows stay single-line and width safe" {
    const projection: CompactCommandMenuProjection = .{ .statusline = .{
        .active = true,
    } };
    for ([_]u16{ 1, 4, 18 }) |width| {
        var row = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, 4, width);
        defer row.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
    }
}

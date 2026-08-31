const std = @import("std");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const usage_report = @import("../../core/session/usage_report.zig");
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
const max_usage_model_rows: usize = 20;
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

const UsageOverviewMode = enum {
    wide,
    medium,
    narrow,
};

const UsageModelMode = enum {
    columns,
    facts,
    compact,
    name_only,
};

const UsageLayout = struct {
    overview_mode: UsageOverviewMode,
    overview_start: usize,
    overview_rows: usize,
    activity_start: ?usize,
    models_header: usize,
    model_columns: ?usize,
    model_start: usize,
};

const UsageModelColumns = struct {
    token: usize,
    share: usize,
    spend: usize,
};

const UsageOverviewColumns = struct {
    second: usize,
    third: usize,
};

fn usageDesiredRowCount(
    projection: render_input.UsageMenuProjection,
    width: u16,
) usize {
    const snapshot = projection.snapshot orelse return 2;
    if (snapshot.totals == null) {
        const activity_rows: usize = if (snapshot.session_activity != null) 3 else 0;
        return 2 + activity_rows;
    }
    const model_rows = @min(snapshot.models.len, max_usage_model_rows) +
        @intFromBool(projection.expanded_model != null);
    return usageLayout(snapshot.*, width).model_start + @max(model_rows, 1);
}

fn composeUsageRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (visible_rows == 1) {
        return composeUsagePriorityRow(alloc, projection, width);
    }
    if (row_index == 0) {
        return composeUsageHeaderRow(alloc, projection.scope, width);
    }
    const snapshot = projection.snapshot orelse {
        if (row_index != 1) return empty;
        return composeStyledRow(
            alloc,
            if (projection.refresh_error != null)
                "Usage unavailable · press R to retry"
            else
                "Loading usage",
            width,
            ui_render.dim_style,
        );
    };
    const totals = snapshot.totals orelse {
        if (row_index == 1) {
            return composeUsageStatusRow(alloc, projection, snapshot.*, width);
        }
        const activity = snapshot.session_activity orelse return empty;
        return (try composeCompactSessionActivityRow(
            alloc,
            activity,
            row_index,
            2,
            width,
        )) orelse empty;
    };
    _ = totals;
    const layout = usageLayout(snapshot.*, width);
    if (visible_rows < layout.model_start + 1) {
        return composeConstrainedUsageRow(
            alloc,
            projection,
            snapshot.*,
            row_index,
            visible_rows,
            width,
        );
    }
    if (row_index == 1) return composeUsageStatusRow(alloc, projection, snapshot.*, width);
    if (row_index >= layout.overview_start and
        row_index < layout.overview_start + layout.overview_rows)
    {
        return composeUsageOverviewRow(
            alloc,
            snapshot.*,
            layout.overview_mode,
            row_index - layout.overview_start,
            width,
        );
    }
    if (layout.activity_start) |activity_start| {
        if (try composeCompactSessionActivityRow(
            alloc,
            snapshot.session_activity.?,
            row_index,
            activity_start,
            width,
        )) |row| return row;
    }

    if (row_index == layout.models_header) {
        return composeUsageModelsHeader(alloc, snapshot.models.len, width);
    }
    if (layout.model_columns) |column_row| {
        if (row_index == column_row) {
            return composeUsageModelColumnHeader(alloc, snapshot.*, width);
        }
    }
    if (row_index < layout.model_start) return empty;
    if (snapshot.models.len == 0) {
        if (row_index != layout.model_start) return empty;
        return composeStyledRow(
            alloc,
            "  No model usage in this scope.",
            width,
            ui_render.dim_style,
        );
    }
    return composeUsageModelRow(
        alloc,
        projection,
        snapshot.*,
        @as(usize, row_index) - layout.model_start,
        @as(usize, visible_rows) -| layout.model_start,
        width,
    );
}

fn composeUsagePriorityRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    width: u16,
) !std.ArrayList(u8) {
    const snapshot = projection.snapshot orelse return composeStyledRow(
        alloc,
        if (projection.refresh_error != null)
            "Usage unavailable · press R to retry"
        else
            "Loading usage",
        width,
        ui_render.dim_style,
    );
    if (snapshot.models.len > 0) {
        return composeUsageModelRow(
            alloc,
            projection,
            snapshot.*,
            0,
            1,
            width,
        );
    }
    return composeUsageStatusRow(alloc, projection, snapshot.*, width);
}

fn composeUsageHeaderRow(
    alloc: Allocator,
    active_scope: usage_report.Scope,
    width: u16,
) !std.ArrayList(u8) {
    const scopes = [_]usage_report.Scope{
        .days_30,
        .days_7,
        .hours_24,
        .session,
    };
    var wide: std.ArrayList(u8) = .empty;
    errdefer wide.deinit(alloc);
    try wide.appendSlice(alloc, ui_render.selected_completion_style);
    try wide.appendSlice(alloc, "Usage");
    try wide.appendSlice(alloc, ui_render.reset_style);
    for (scopes) |scope| {
        try wide.appendSlice(alloc, "  ");
        try appendUsageScopeTab(alloc, &wide, scope, scope == active_scope);
    }
    if (width >= 64 and display_width.visibleWidthIgnoringAnsi(wide.items) <= width) return wide;
    wide.deinit(alloc);
    wide = .empty;

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try compact.appendSlice(alloc, ui_render.selected_completion_style);
    try compact.appendSlice(alloc, "Usage");
    try compact.appendSlice(alloc, ui_render.reset_style);
    try compact.appendSlice(alloc, "  ");
    try appendUsageScopeTab(alloc, &compact, active_scope, true);
    var clipped: std.ArrayList(u8) = .empty;
    errdefer clipped.deinit(alloc);
    try row_text.appendClipped(alloc, &clipped, compact.items, width);
    try clipped.appendSlice(alloc, ui_render.reset_style);
    return clipped;
}

fn appendUsageScopeTab(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    scope: usage_report.Scope,
    active: bool,
) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, scope.label());
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn composeConstrainedUsageRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    snapshot: usage_report.Snapshot,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    const model_start = constrainedUsageModelStart(visible_rows);
    if (row_index == 1 and row_index < model_start) {
        return composeUsageStatusRow(alloc, projection, snapshot, width);
    }
    if (row_index == 2 and row_index < model_start) {
        return composeUsageCompactSummaryRow(alloc, snapshot, width);
    }
    if (row_index == 3 and row_index < model_start) {
        return composeUsageModelsHeader(alloc, snapshot.models.len, width);
    }
    if (row_index < model_start) return empty;
    if (snapshot.models.len == 0) return composeUsageStatusRow(alloc, projection, snapshot, width);
    return composeUsageModelRow(
        alloc,
        projection,
        snapshot,
        row_index - model_start,
        visible_rows - model_start,
        width,
    );
}

fn composeUsageCompactSummaryRow(
    alloc: Allocator,
    snapshot: usage_report.Snapshot,
    width: u16,
) !std.ArrayList(u8) {
    const totals = snapshot.totals orelse
        return composeStyledRow(alloc, "Usage unavailable", width, ui_render.dim_style);
    var token_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    var buf: [96]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &buf,
        "{s} tokens · {s}",
        .{
            formatCompactUnsigned(&token_buf, totals.total_tokens),
            formatMoney(&spend_buf, totals.total_cost),
        },
    ) catch "Usage summary unavailable";
    return composeStyledRow(alloc, summary, width, ui_render.dim_style);
}

fn composeCompactSessionActivityRow(
    alloc: Allocator,
    activity: usage_report.SessionActivity,
    row_index: u16,
    activity_start: usize,
    width: u16,
) !?std.ArrayList(u8) {
    if (row_index == activity_start) {
        return try composeStyledRow(
            alloc,
            "Session activity",
            width,
            ui_render.system_notice_label_style,
        );
    }
    var api_buf: [32]u8 = undefined;
    var wall_buf: [32]u8 = undefined;
    var row_buf: [128]u8 = undefined;
    if (row_index == activity_start + 1) {
        const text = std.fmt.bufPrint(
            &row_buf,
            "API {s} · Wall {s}",
            .{
                if (activity.api_duration_complete)
                    formatDuration(&api_buf, activity.api_duration_ms)
                else
                    "Unavailable",
                if (activity.wall_duration_complete)
                    formatDuration(&wall_buf, activity.wall_duration_ms)
                else
                    "Unavailable",
            },
        ) catch "Session timing unavailable";
        return try composeStyledRow(alloc, text, width, ui_render.dim_style);
    }
    if (row_index == activity_start + 2) {
        const text = if (activity.code_complete)
            std.fmt.bufPrint(
                &row_buf,
                "Code +{d} · -{d}",
                .{ activity.lines_added, activity.lines_removed },
            ) catch "Code activity unavailable"
        else
            "Code activity unavailable";
        return try composeStyledRow(alloc, text, width, ui_render.dim_style);
    }
    return null;
}

fn composeUsageStatusRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    snapshot: usage_report.Snapshot,
    width: u16,
) !std.ArrayList(u8) {
    const status = if (projection.refresh_error != null)
        "Refresh failed · showing previous data"
    else if (snapshot.coverage == .not_started)
        "Tracking has not started"
    else if (snapshot.coverage == .partial or snapshot.completeness != .complete)
        if (width < 48) "Partial data" else "Partial data · some usage may be missing"
    else
        "Local fx activity";
    return composeStyledRow(alloc, status, width, ui_render.dim_style);
}

fn composeUsageModelRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    snapshot: usage_report.Snapshot,
    display_row: usize,
    visible_rows: usize,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    const selected = @min(projection.selected_model, snapshot.models.len - 1);
    const visible_models = @min(
        snapshot.models.len,
        max_usage_model_rows,
        @max(
            visible_rows -| @intFromBool(projection.expanded_model != null),
            1,
        ),
    );
    const max_start = snapshot.models.len -| visible_models;
    const selection_start = selected -| (visible_models - 1);
    const start = @min(
        @max(
            @min(projection.model_window_start, selected),
            selection_start,
        ),
        max_start,
    );
    var logical_row: usize = 0;
    var model_index = start;
    while (model_index < snapshot.models.len) : (model_index += 1) {
        if (logical_row == display_row) {
            const model = snapshot.models[model_index];
            var safe_model = try text_utils.encodeTerminalSafe(
                alloc,
                model.model,
                std.math.maxInt(usize),
            );
            defer safe_model.deinit(alloc);
            return composeUsageModelSummaryRow(
                alloc,
                snapshot,
                safe_model.bytes,
                model,
                model_index == selected,
                width,
            );
        }
        logical_row += 1;
        if (projection.expanded_model == model_index) {
            if (logical_row == display_row) {
                const totals = snapshot.models[model_index].totals;
                var detail_buf: [256]u8 = undefined;
                const detail = formatUsageModelDetail(&detail_buf, totals);
                return composeStyledRow(
                    alloc,
                    detail,
                    width,
                    ui_render.dim_style,
                );
            }
            logical_row += 1;
        }
        if (logical_row > display_row) return empty;
    }
    return empty;
}

pub fn usageVisibleModelItems(
    projection: render_input.UsageMenuProjection,
    visible_rows: u16,
    width: u16,
) u16 {
    const snapshot = projection.snapshot orelse return 0;
    if (snapshot.models.len == 0) return 0;
    const model_start = usageModelAreaStart(snapshot.*, visible_rows, width) orelse return 0;
    const model_area_rows = @as(usize, visible_rows) -| model_start;
    if (model_area_rows == 0) return 0;
    return @intCast(@min(
        snapshot.models.len,
        max_usage_model_rows,
        @max(
            model_area_rows -| @intFromBool(projection.expanded_model != null),
            1,
        ),
    ));
}

fn usageModelAreaStart(
    snapshot: usage_report.Snapshot,
    visible_rows: u16,
    width: u16,
) ?usize {
    if (snapshot.totals == null) return null;
    if (visible_rows == 1) return 0;
    const natural = usageLayout(snapshot, width).model_start;
    if (visible_rows < natural + 1) return constrainedUsageModelStart(visible_rows);
    return natural;
}

fn constrainedUsageModelStart(visible_rows: u16) usize {
    if (visible_rows <= 4) return visible_rows -| 1;
    return 4;
}

fn usageLayout(snapshot: usage_report.Snapshot, width: u16) UsageLayout {
    const totals = snapshot.totals.?;
    const overview_mode: UsageOverviewMode = if (width >= 110 and usageOverviewColumns(totals, width) != null)
        .wide
    else if (width >= 48)
        .medium
    else
        .narrow;
    const overview_start: usize = if (overview_mode == .narrow) 2 else 3;
    const overview_rows: usize = if (overview_mode == .narrow) 2 else 3;
    var cursor = overview_start + overview_rows;
    var activity_start: ?usize = null;
    if (snapshot.session_activity != null) {
        if (overview_mode != .narrow) cursor += 1;
        activity_start = cursor;
        cursor += 3;
    }
    if (overview_mode != .narrow) cursor += 1;
    const models_header = cursor;
    cursor += 1;
    const model_columns = if (usageModelModeFor(snapshot, width) == .columns) blk: {
        const row = cursor;
        cursor += 1;
        break :blk row;
    } else null;
    return .{
        .overview_mode = overview_mode,
        .overview_start = overview_start,
        .overview_rows = overview_rows,
        .activity_start = activity_start,
        .models_header = models_header,
        .model_columns = model_columns,
        .model_start = cursor,
    };
}

fn composeUsageOverviewRow(
    alloc: Allocator,
    snapshot: usage_report.Snapshot,
    mode: UsageOverviewMode,
    display_row: usize,
    width: u16,
) !std.ArrayList(u8) {
    const totals = snapshot.totals.?;
    var first_buf: [64]u8 = undefined;
    var second_buf: [64]u8 = undefined;
    var third_buf: [64]u8 = undefined;
    const cells = usageOverviewCells(
        totals,
        mode,
        display_row,
        &first_buf,
        &second_buf,
        &third_buf,
    );
    if (mode == .wide) {
        return composeUsageMetricColumns(
            alloc,
            cells,
            usageOverviewColumns(totals, width).?,
            width,
        );
    }
    var row_buf: [192]u8 = undefined;
    const text = if (cells[2].len > 0)
        std.fmt.bufPrint(&row_buf, "{s} · {s} · {s}", .{ cells[0], cells[1], cells[2] }) catch "Usage unavailable"
    else if (cells[1].len > 0)
        std.fmt.bufPrint(&row_buf, "{s} · {s}", .{ cells[0], cells[1] }) catch "Usage unavailable"
    else
        cells[0];
    return composeStyledRow(alloc, text, width, ui_render.dim_style);
}

fn usageOverviewCells(
    totals: usage_report.Totals,
    mode: UsageOverviewMode,
    row: usize,
    first: *[64]u8,
    second: *[64]u8,
    third: *[64]u8,
) [3][]const u8 {
    if (mode == .narrow) {
        return switch (row) {
            0 => .{
                formatTokenLabel(first, totals.total_tokens, "tokens"),
                formatMoney(second, totals.total_cost),
                "",
            },
            else => .{
                formatRequestLabel(third, totals.request_count),
                "",
                "",
            },
        };
    }
    return switch (row) {
        0 => .{
            formatTokenLabel(first, totals.total_tokens, "tokens"),
            formatMoneyLabel(second, totals.total_cost, "spent"),
            formatRequestLabel(third, totals.request_count),
        },
        1 => .{
            formatTokenLabel(first, totals.input_tokens, "input"),
            formatTokenLabel(second, totals.output_tokens, "output"),
            if (totals.reasoning_tokens) |value|
                formatTokenLabel(third, value, "reasoning")
            else
                "Reasoning unavailable",
        },
        else => .{
            formatTokenLabel(first, totals.cache_read_tokens, "cache read"),
            formatTokenLabel(second, totals.cache_write_tokens, "cache write"),
            "",
        },
    };
}

fn usageOverviewColumns(
    totals: usage_report.Totals,
    width: u16,
) ?UsageOverviewColumns {
    var first_width: usize = 0;
    var second_width: usize = 0;
    var third_width: usize = 0;
    for (0..3) |row| {
        var first: [64]u8 = undefined;
        var second: [64]u8 = undefined;
        var third: [64]u8 = undefined;
        const cells = usageOverviewCells(totals, .wide, row, &first, &second, &third);
        first_width = @max(first_width, display_width.visibleWidth(cells[0]));
        second_width = @max(second_width, display_width.visibleWidth(cells[1]));
        third_width = @max(third_width, display_width.visibleWidth(cells[2]));
    }
    const indent: usize = if (width <= 2) 0 else 2;
    const second = indent + first_width + column_gap;
    const third = second + second_width + column_gap;
    if (third + third_width > width) return null;
    return .{ .second = second, .third = third };
}

fn composeUsageMetricColumns(
    alloc: Allocator,
    cells: [3][]const u8,
    columns: UsageOverviewColumns,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    if (width > 2) try row.appendSlice(alloc, "  ");
    try row_text.appendSingleLineEllipsized(alloc, &row, cells[0], columns.second -| 3);
    try row_text.appendSpacesToColumn(alloc, &row, columns.second);
    try row_text.appendSingleLineEllipsized(alloc, &row, cells[1], columns.third -| columns.second -| 1);
    if (cells[2].len > 0) {
        try row_text.appendSpacesToColumn(alloc, &row, columns.third);
        try row_text.appendSingleLineEllipsized(alloc, &row, cells[2], @as(usize, width) -| columns.third);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeUsageModelsHeader(
    alloc: Allocator,
    model_count: usize,
    width: u16,
) !std.ArrayList(u8) {
    var buf: [64]u8 = undefined;
    const text = if (width < 48)
        "Models"
    else
        std.fmt.bufPrint(&buf, "Models {d}", .{model_count}) catch "Models";
    return composeStyledRow(alloc, text, width, ui_render.system_notice_label_style);
}

fn composeUsageModelColumnHeader(
    alloc: Allocator,
    snapshot: usage_report.Snapshot,
    width: u16,
) !std.ArrayList(u8) {
    const columns = usageModelColumns(snapshot, width) orelse
        return std.ArrayList(u8).empty;
    return composeUsageModelColumnsRow(
        alloc,
        "Model",
        "Tokens",
        "Share",
        "Spend",
        false,
        columns,
        width,
    );
}

fn composeUsageModelSummaryRow(
    alloc: Allocator,
    snapshot: usage_report.Snapshot,
    model_name: []const u8,
    model: usage_report.ModelUsage,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var token_buf: [32]u8 = undefined;
    var share_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    const mode = usageModelModeFor(snapshot, width);
    if (mode == .columns) {
        return composeUsageModelColumnsRow(
            alloc,
            model_name,
            formatCompactUnsigned(&token_buf, model.totals.total_tokens),
            formatUsageShare(&share_buf, model.totals.total_tokens, snapshot.totals.?.total_tokens),
            formatMoney(&spend_buf, model.totals.total_cost),
            selected,
            usageModelColumns(snapshot, width).?,
            width,
        );
    }
    const include_share = mode == .facts;
    var info_buf: [128]u8 = undefined;
    const info = formatUsageModelFacts(
        &info_buf,
        model,
        snapshot.totals.?.total_tokens,
        include_share,
    );
    return composeWorkspaceActionRow(
        alloc,
        model_name,
        if (mode == .name_only) "" else info,
        selected,
        usageModelInfoColumn(snapshot, width, include_share),
        width,
    );
}

fn composeUsageModelColumnsRow(
    alloc: Allocator,
    name: []const u8,
    tokens: []const u8,
    share: []const u8,
    spend: []const u8,
    selected: bool,
    columns: UsageModelColumns,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.system_notice_label_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, if (selected) "❯ " else "  ", width);
    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    try row_text.appendSingleLineEllipsized(alloc, &row, name, columns.token -| used -| 1);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, columns.token);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, tokens, columns.share -| columns.token -| 1);
    try row_text.appendSpacesToColumn(alloc, &row, columns.share);
    try row_text.appendSingleLineEllipsized(alloc, &row, share, columns.spend -| columns.share -| 1);
    try row_text.appendSpacesToColumn(alloc, &row, columns.spend);
    try row_text.appendSingleLineEllipsized(alloc, &row, spend, @as(usize, width) -| columns.spend);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn usageModelModeFor(snapshot: usage_report.Snapshot, width: u16) UsageModelMode {
    if (width >= 110 and usageModelColumns(snapshot, width) != null) return .columns;
    if (width >= 48 and usageModelInfoColumn(snapshot, width, true) != null) return .facts;
    if (usageModelInfoColumn(snapshot, width, false) != null) return .compact;
    return .name_only;
}

fn usageModelColumns(
    snapshot: usage_report.Snapshot,
    width: u16,
) ?UsageModelColumns {
    const indent: usize = if (width <= 2) 0 else 2;
    var longest_model = display_width.visibleWidth("Model");
    var token_width = display_width.visibleWidth("Tokens");
    var share_width = display_width.visibleWidth("Share");
    var spend_width = display_width.visibleWidth("Spend");
    for (snapshot.models) |model| {
        longest_model = @max(longest_model, text_utils.terminalSafeVisibleWidth(model.model));
        var token_buf: [32]u8 = undefined;
        var share_buf: [32]u8 = undefined;
        var spend_buf: [32]u8 = undefined;
        token_width = @max(token_width, display_width.visibleWidth(formatCompactUnsigned(&token_buf, model.totals.total_tokens)));
        share_width = @max(share_width, display_width.visibleWidth(formatUsageShare(&share_buf, model.totals.total_tokens, snapshot.totals.?.total_tokens)));
        spend_width = @max(spend_width, display_width.visibleWidth(formatMoney(&spend_buf, model.totals.total_cost)));
    }
    const fixed = column_gap * 3 + token_width + share_width + spend_width;
    const minimum_name: usize = 10;
    if (@as(usize, width) < indent + minimum_name + fixed) return null;
    const name_width = @min(longest_model, @as(usize, width) - indent - fixed);
    const token = indent + name_width + column_gap;
    const share = token + token_width + column_gap;
    const spend = share + share_width + column_gap;
    return .{ .token = token, .share = share, .spend = spend };
}

fn usageModelInfoColumn(
    snapshot: usage_report.Snapshot,
    width: u16,
    include_share: bool,
) ?usize {
    const indent: usize = if (width <= 2) 0 else 2;
    var longest_model: usize = 0;
    var widest_info: usize = 0;
    for (snapshot.models) |model| {
        longest_model = @max(longest_model, text_utils.terminalSafeVisibleWidth(model.model));
        var info_buf: [128]u8 = undefined;
        widest_info = @max(
            widest_info,
            display_width.visibleWidth(formatUsageModelFacts(
                &info_buf,
                model,
                snapshot.totals.?.total_tokens,
                include_share,
            )),
        );
    }
    if (widest_info == 0 or @as(usize, width) < indent + 8 + column_gap + widest_info) return null;
    return @min(indent + longest_model + column_gap, @as(usize, width) - widest_info);
}

fn formatUsageModelFacts(
    buf: *[128]u8,
    model: usage_report.ModelUsage,
    total_tokens: u64,
    include_share: bool,
) []const u8 {
    var token_buf: [32]u8 = undefined;
    var share_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    return if (include_share)
        std.fmt.bufPrint(
            buf,
            "{s} · {s} · {s}",
            .{
                formatCompactUnsigned(&token_buf, model.totals.total_tokens),
                formatUsageShare(&share_buf, model.totals.total_tokens, total_tokens),
                formatMoney(&spend_buf, model.totals.total_cost),
            },
        ) catch "Unavailable"
    else
        std.fmt.bufPrint(
            buf,
            "{s} · {s}",
            .{
                formatCompactUnsigned(&token_buf, model.totals.total_tokens),
                formatMoney(&spend_buf, model.totals.total_cost),
            },
        ) catch "Unavailable";
}

fn formatUsageModelDetail(
    buf: *[256]u8,
    totals: usage_report.Totals,
) []const u8 {
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var read_buf: [32]u8 = undefined;
    var write_buf: [32]u8 = undefined;
    var reasoning_buf: [32]u8 = undefined;
    var request_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "Input {s} · Output {s} · Cache {s}/{s} · Reasoning {s} · Requests {s} · {s}",
        .{
            formatCompactUnsigned(&input_buf, totals.input_tokens),
            formatCompactUnsigned(&output_buf, totals.output_tokens),
            formatCompactUnsigned(&read_buf, totals.cache_read_tokens),
            formatCompactUnsigned(&write_buf, totals.cache_write_tokens),
            if (totals.reasoning_tokens) |value| formatCompactUnsigned(&reasoning_buf, value) else "n/a",
            if (totals.request_count) |value| formatGroupedUnsigned(&request_buf, value) else "n/a",
            formatMoney(&spend_buf, totals.total_cost),
        },
    ) catch "Usage details unavailable";
}

fn formatTokenLabel(buf: *[64]u8, value: u64, label: []const u8) []const u8 {
    var value_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatCompactUnsigned(&value_buf, value), label }) catch "Unavailable";
}

fn formatMoneyLabel(buf: *[64]u8, value: f64, label: []const u8) []const u8 {
    var value_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatMoney(&value_buf, value), label }) catch "Unavailable";
}

fn formatRequestLabel(buf: *[64]u8, value: ?u64) []const u8 {
    const requests = value orelse return "Requests unavailable";
    var value_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "{s} {s}",
        .{
            formatGroupedUnsigned(&value_buf, requests),
            if (requests == 1) "request" else "requests",
        },
    ) catch "Requests unavailable";
}

fn formatCompactUnsigned(buf: *[32]u8, value: u64) []const u8 {
    const units = [_]struct { value: u64, suffix: []const u8 }{
        .{ .value = 1_000_000_000, .suffix = "B" },
        .{ .value = 1_000_000, .suffix = "M" },
        .{ .value = 1_000, .suffix = "K" },
    };
    for (units) |unit| {
        if (value < unit.value) continue;
        if (value % unit.value == 0) {
            return std.fmt.bufPrint(buf, "{d}{s}", .{ value / unit.value, unit.suffix }) catch "?";
        }
        return std.fmt.bufPrint(
            buf,
            "{d:.1}{s}",
            .{ @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(unit.value)), unit.suffix },
        ) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

fn formatGroupedUnsigned(buf: *[32]u8, value: u64) []const u8 {
    var cursor = buf.len;
    var remaining = value;
    var digits: usize = 0;
    while (true) {
        if (digits > 0 and digits % 3 == 0) {
            cursor -= 1;
            buf[cursor] = ',';
        }
        cursor -= 1;
        buf[cursor] = @intCast('0' + remaining % 10);
        remaining /= 10;
        digits += 1;
        if (remaining == 0) break;
    }
    return buf[cursor..];
}

fn formatMoney(buf: anytype, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "$?";
}

fn formatUsageShare(buf: *[32]u8, tokens: u64, total_tokens: u64) []const u8 {
    const share = if (total_tokens == 0)
        0.0
    else
        @as(f64, @floatFromInt(tokens)) * 100.0 / @as(f64, @floatFromInt(total_tokens));
    return std.fmt.bufPrint(buf, "{d:.1}%", .{share}) catch "?%";
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

fn formatDuration(buf: anytype, duration_ms: u64) []const u8 {
    const total_seconds = duration_ms / 1000;
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, minutes, seconds }) catch "Unavailable";
    }
    if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds }) catch "Unavailable";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "Unavailable";
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

test "usage menu renders token-first totals and selectable model rows" {
    var models = [_]usage_report.ModelUsage{
        .{
            .model = @constCast("z.ai/glm-5.2"),
            .totals = testUsageTotals(104, 0.0104),
        },
        .{
            .model = @constCast("openai/gpt-5.6"),
            .totals = testUsageTotals(19, 0.0019),
        },
    };
    const snapshot = usage_report.Snapshot{
        .scope = .days_30,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = .{
            .total_tokens = 120,
            .input_tokens = 100,
            .output_tokens = 20,
            .cache_read_tokens = 20,
            .cache_write_tokens = 10,
            .reasoning_tokens = 5,
            .request_count = 2,
            .total_cost = 0.0123,
        },
        .models = &models,
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .snapshot = &snapshot,
    } };

    var total = try composeCompactCommandMenuRow(std.testing.allocator, projection, 3, 14, 120);
    defer total.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, total.items, "120 tokens") != null);
    try std.testing.expect(std.mem.find(u8, total.items, "$0.01 spent") != null);
    try std.testing.expect(std.mem.find(u8, total.items, "2 requests") != null);

    try std.testing.expectEqual(@as(u16, 11), desiredRowCount(projection, 120));
    var model = try composeCompactCommandMenuRow(std.testing.allocator, projection, 9, 11, 120);
    defer model.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, model.items, "z.ai/glm-5.2") != null);
    try std.testing.expect(std.mem.find(u8, model.items, "104") != null);
    try std.testing.expect(std.mem.find(u8, model.items, "86.7%") != null);

    var compact_summary = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, 8, 40);
    defer compact_summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, compact_summary.items, "120 tokens") != null);
    try std.testing.expect(std.mem.find(u8, compact_summary.items, "$0.01") != null);
}

test "usage menu adapts dashboard density without losing model columns" {
    var models = [_]usage_report.ModelUsage{
        .{
            .model = @constCast("openai/gpt-5.6-sol"),
            .totals = .{
                .total_tokens = 43_626_823,
                .input_tokens = 43_000_000,
                .output_tokens = 626_823,
                .cache_read_tokens = 30_000_000,
                .cache_write_tokens = 5_000_000,
                .reasoning_tokens = 200_000,
                .request_count = 1_000,
                .total_cost = 100.7886,
            },
        },
        .{
            .model = @constCast("provider/a-much-longer-model-name"),
            .totals = testUsageTotals(17_487_444, 16.4968),
        },
    };
    const snapshot = usage_report.Snapshot{
        .scope = .days_7,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .partial,
        .completeness = .incomplete,
        .totals = .{
            .total_tokens = 61_114_267,
            .input_tokens = 60_415_084,
            .output_tokens = 699_183,
            .cache_read_tokens = 42_920_431,
            .cache_write_tokens = 14_728_752,
            .reasoning_tokens = 253_917,
            .request_count = 1_464,
            .total_cost = 117.2854,
        },
        .models = &models,
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .scope = .days_7,
        .snapshot = &snapshot,
    } };

    var small_header = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, 7, 44);
    defer small_header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, small_header.items, "Usage") != null);
    try std.testing.expect(std.mem.find(u8, small_header.items, "[7 days]") != null);
    try std.testing.expect(std.mem.find(u8, small_header.items, "30 days") == null);

    var small_model = try composeCompactCommandMenuRow(std.testing.allocator, projection, 5, 7, 44);
    defer small_model.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, small_model.items, "43.6M") != null);
    try std.testing.expect(std.mem.find(u8, small_model.items, "$100.79") != null);
    try std.testing.expect(std.mem.find(u8, small_model.items, "%") == null);

    var medium_model = try composeCompactCommandMenuRow(std.testing.allocator, projection, 8, 10, 90);
    defer medium_model.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, medium_model.items, "43.6M · 71.4% · $100.79") != null);

    var wide_header = try composeCompactCommandMenuRow(std.testing.allocator, projection, 8, 11, 160);
    defer wide_header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, wide_header.items, "Model") != null);
    try std.testing.expect(std.mem.find(u8, wide_header.items, "Tokens") != null);
    try std.testing.expect(std.mem.find(u8, wide_header.items, "Share") != null);
    try std.testing.expect(std.mem.find(u8, wide_header.items, "Spend") != null);

    for ([_]u16{ 32, 44, 90, 160 }) |width| {
        const rows = desiredRowCount(projection, width);
        for (0..rows) |row_index| {
            var row = try composeCompactCommandMenuRow(
                std.testing.allocator,
                projection,
                @intCast(row_index),
                rows,
                width,
            );
            defer row.deinit(std.testing.allocator);
            try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        }
    }
}

test "usage menu renders scope tabs stable model facts and at most twenty models" {
    var models: [25]usage_report.ModelUsage = undefined;
    for (&models, 0..) |*model, index| {
        model.* = .{
            .model = @constCast(if (index == models.len - 1)
                "provider/a-much-longer-selected-model"
            else
                "provider/model"),
            .totals = testUsageTotals(10, 0.001),
        };
    }
    const snapshot = usage_report.Snapshot{
        .scope = .days_30,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testUsageTotals(250, 0.025),
        .models = &models,
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .selected_model = models.len - 1,
        .model_window_start = models.len - 1,
        .snapshot = &snapshot,
    } };

    try std.testing.expectEqual(@as(u16, 28), desiredRowCount(projection, 80));
    var header = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, 28, 80);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "Usage") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[30 days]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Session") != null);

    var tiny = try composeCompactCommandMenuRow(std.testing.allocator, projection, 0, 1, 100);
    defer tiny.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, tiny.items, "selected-model") != null);

    var pair = [_]usage_report.ModelUsage{
        .{ .model = @constCast("provider/short"), .totals = testUsageTotals(20, 0.002) },
        .{ .model = @constCast("provider/a-much-longer-model"), .totals = testUsageTotals(30, 0.003) },
    };
    const pair_snapshot = usage_report.Snapshot{
        .scope = .days_30,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testUsageTotals(50, 0.005),
        .models = &pair,
    };
    const pair_projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .snapshot = &pair_snapshot,
    } };
    var medium = try composeCompactCommandMenuRow(std.testing.allocator, pair_projection, 8, 10, 80);
    defer medium.deinit(std.testing.allocator);
    var wide = try composeCompactCommandMenuRow(std.testing.allocator, pair_projection, 9, 11, 180);
    defer wide.deinit(std.testing.allocator);
    const medium_facts = std.mem.find(u8, medium.items, "20") orelse return error.TestExpectedFacts;
    const wide_facts = std.mem.find(u8, wide.items, "20") orelse return error.TestExpectedFacts;
    const expected_column = 2 + display_width.visibleWidth("provider/a-much-longer-model") + 4;
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(medium.items[0..medium_facts]));
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(wide.items[0..wide_facts]));
}

test "usage menu renders expanded details for the last visible session model" {
    var models: [13]usage_report.ModelUsage = undefined;
    for (&models) |*model| {
        model.* = .{
            .model = @constCast("provider/model"),
            .totals = testUsageTotals(10, 0.001),
        };
    }
    const snapshot = usage_report.Snapshot{
        .scope = .session,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testUsageTotals(130, 0.013),
        .models = &models,
        .session_activity = .{
            .api_duration_complete = true,
            .wall_duration_complete = true,
            .code_complete = true,
            .api_duration_ms = 1,
            .wall_duration_ms = 2,
            .lines_added = 3,
            .lines_removed = 4,
        },
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .selected_model = 12,
        .expanded_model = 12,
        .model_window_start = 1,
        .snapshot = &snapshot,
    } };

    var selected = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        24,
        26,
        100,
    );
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, selected.items, "❯ provider/model") != null);

    var details = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        25,
        26,
        100,
    );
    defer details.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, details.items, "Input 10 · Output 0") != null);
}

test "usage menu keeps expanded model details visible at constrained height" {
    var models: [13]usage_report.ModelUsage = undefined;
    for (&models) |*model| {
        model.* = .{
            .model = @constCast("provider/model"),
            .totals = testUsageTotals(10, 0.001),
        };
    }
    const snapshot = usage_report.Snapshot{
        .scope = .days_30,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testUsageTotals(130, 0.013),
        .models = &models,
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .selected_model = 12,
        .expanded_model = 12,
        .model_window_start = 12,
        .snapshot = &snapshot,
    } };

    var details = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        11,
        12,
        72,
    );
    defer details.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, details.items, "Input 10 · Output 0") != null);
}

test "usage menu renders a full pending status once" {
    var models: [0]usage_report.ModelUsage = .{};
    const snapshot = usage_report.Snapshot{
        .scope = .session,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .pending,
        .totals = null,
        .models = &models,
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .snapshot = &snapshot,
    } };

    try std.testing.expectEqual(@as(u16, 2), desiredRowCount(projection, 80));
    var status = try composeCompactCommandMenuRow(std.testing.allocator, projection, 1, 2, 80);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, status.items, "Partial data") != null);

    var omitted = try composeCompactCommandMenuRow(std.testing.allocator, projection, 3, 2, 80);
    defer omitted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), omitted.items.len);
}

test "usage menu keeps session activity visible while billing is pending" {
    var models: [0]usage_report.ModelUsage = .{};
    const snapshot = usage_report.Snapshot{
        .scope = .session,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .pending,
        .totals = null,
        .models = &models,
        .session_activity = .{
            .api_duration_complete = true,
            .wall_duration_complete = false,
            .code_complete = true,
            .api_duration_ms = 1200,
            .wall_duration_ms = 3400,
            .lines_added = 5,
            .lines_removed = 2,
        },
    };
    const projection: CompactCommandMenuProjection = .{ .usage = .{
        .active = true,
        .scope = .session,
        .snapshot = &snapshot,
    } };

    try std.testing.expectEqual(@as(u16, 5), desiredRowCount(projection, 80));
    var api = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        3,
        5,
        80,
    );
    defer api.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, api.items, "API 1s") != null);
    try std.testing.expect(std.mem.find(u8, api.items, "1s") != null);

    var wall = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        3,
        5,
        80,
    );
    defer wall.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, wall.items, "Unavailable") != null);

    var code = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        4,
        5,
        80,
    );
    defer code.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, code.items, "+5 · -2") != null);
}

fn testUsageTotals(tokens: u64, cost: f64) usage_report.Totals {
    return .{
        .total_tokens = tokens,
        .input_tokens = tokens,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .request_count = 1,
        .total_cost = cost,
    };
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

const std = @import("std");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const usage_report = @import("../../core/session/usage_report.zig");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");
const workspace_menu = @import("../../core/workspace/workspace_menu.zig");
const usage_menu = @import("../../core/session/usage_menu.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const CompactCommandMenuProjection = render_input.CompactCommandMenuProjection;

const usage_value_column: usize = 20;
const workspace_summary_value_column: usize = 30;
const workspace_pinned_rows: usize = 5;
/// Title row plus the blank row above the first toggle choice.
const settings_row_offset: usize = 2;

const ChoiceView = struct {
    label: []const u8,
    setting: settings_catalog.SettingId,
    snapshot: settings_catalog.Snapshot,
    selected: bool,
};

pub fn desiredRowCount(projection: CompactCommandMenuProjection) u16 {
    const count: usize = switch (projection) {
        .statusline => settings_row_offset + settings_catalog.statuslineChoiceCount(),
        .usage => |usage| usageDesiredRowCount(usage),
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
        .statusline => composeSettingsRow(alloc, projection, row_index, width),
        .usage => |usage| composeUsageRow(alloc, usage, row_index, visible_rows, width),
        .workspace => |workspace| composeWorkspaceRow(alloc, workspace, row_index, visible_rows, width),
    };
}

fn composeSettingsRow(
    alloc: Allocator,
    projection: CompactCommandMenuProjection,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (row_index == 0) {
        return composeStyledRow(alloc, title(projection), width, ui_render.selected_completion_style);
    }
    if (row_index < settings_row_offset) return empty;
    const choice_index = row_index - settings_row_offset;
    return composeChoiceRow(alloc, choiceView(projection, choice_index) orelse return empty, width);
}

fn title(projection: CompactCommandMenuProjection) []const u8 {
    return switch (projection) {
        .statusline => "Status line",
        .usage => "Usage:",
        .workspace => "Workspace:",
    };
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

fn usageDesiredRowCount(projection: render_input.UsageMenuProjection) usize {
    const snapshot = projection.snapshot orelse return 2;
    if (snapshot.totals == null) {
        const detail_rows: usize = @intFromBool(usageNeedsStatusDetail(
            projection,
            snapshot.*,
        ));
        if (snapshot.session_activity != null) {
            return usage_menu.usage_summary_start +
                detail_rows +
                usage_menu.usage_activity_rows;
        }
        return if (detail_rows == 0)
            2
        else
            usage_menu.usage_summary_start + detail_rows;
    }
    const model_rows = snapshot.models.len +
        @intFromBool(projection.expanded_model != null);
    return usage_menu.usagePinnedRowCount(snapshot.*) +
        @max(model_rows, 1);
}

fn composeUsageRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (row_index == 0) {
        var header_buf: [96]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "Usage · {s}",
            .{projection.scope.label()},
        ) catch "Usage";
        return composeStyledRow(
            alloc,
            header,
            width,
            ui_render.selected_completion_style,
        );
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
    if (row_index == 1) {
        return composeUsageStatusRow(alloc, projection, snapshot.*, width);
    }
    const totals = snapshot.totals orelse {
        const detail_rows: usize = @intFromBool(usageNeedsStatusDetail(
            projection,
            snapshot.*,
        ));
        if (detail_rows == 1 and
            row_index == usage_menu.usage_summary_start)
        {
            return composeStyledRow(
                alloc,
                completenessMessage(snapshot.*),
                width,
                ui_render.dim_style,
            );
        }
        const activity = snapshot.session_activity orelse return empty;
        const activity_start = usage_menu.usage_summary_start +
            detail_rows;
        return (try composeSessionActivityRow(
            alloc,
            activity,
            row_index,
            activity_start,
            width,
        )) orelse empty;
    };

    var value_buf: [160]u8 = undefined;
    switch (@as(usize, row_index) - usage_menu.usage_summary_start) {
        0 => return composeLabelValueRow(
            alloc,
            "Total tokens",
            std.fmt.bufPrint(&value_buf, "{d}", .{totals.total_tokens}) catch "Unavailable",
            usage_value_column,
            width,
        ),
        1 => return composeLabelValueRow(
            alloc,
            "Input",
            std.fmt.bufPrint(&value_buf, "{d}", .{totals.input_tokens}) catch "Unavailable",
            usage_value_column,
            width,
        ),
        2 => return composeLabelValueRow(
            alloc,
            "Output",
            std.fmt.bufPrint(&value_buf, "{d}", .{totals.output_tokens}) catch "Unavailable",
            usage_value_column,
            width,
        ),
        3 => return composeLabelValueRow(
            alloc,
            "Cache",
            std.fmt.bufPrint(
                &value_buf,
                "{d} read · {d} write",
                .{ totals.cache_read_tokens, totals.cache_write_tokens },
            ) catch "Unavailable",
            usage_value_column,
            width,
        ),
        4 => return composeLabelValueRow(
            alloc,
            "Reasoning",
            if (totals.reasoning_tokens) |reasoning|
                std.fmt.bufPrint(&value_buf, "{d}", .{reasoning}) catch "Unavailable"
            else
                "Not reported",
            usage_value_column,
            width,
        ),
        5 => return composeLabelValueRow(
            alloc,
            "Requests",
            if (totals.request_count) |requests|
                std.fmt.bufPrint(&value_buf, "{d}", .{requests}) catch "Unavailable"
            else
                "Unavailable",
            usage_value_column,
            width,
        ),
        6 => return composeLabelValueRow(
            alloc,
            "Spend",
            std.fmt.bufPrint(&value_buf, "${d:.4}", .{totals.total_cost}) catch "Unavailable",
            usage_value_column,
            width,
        ),
        else => {},
    }

    const activity_start = usage_menu.usage_summary_start +
        usage_menu.usage_summary_rows;
    const models_start = if (snapshot.session_activity) |activity| blk: {
        if (try composeSessionActivityRow(
            alloc,
            activity,
            row_index,
            activity_start,
            width,
        )) |row| return row;
        break :blk activity_start + usage_menu.usage_activity_rows;
    } else activity_start;

    if (row_index == models_start) {
        return composeStyledRow(
            alloc,
            "  By model",
            width,
            ui_render.system_notice_label_style,
        );
    }
    if (snapshot.models.len == 0) {
        if (row_index != models_start + 1) return empty;
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
        @as(usize, row_index) - (models_start + 1),
        @as(usize, visible_rows) -| (models_start + 1),
        width,
    );
}

fn usageNeedsStatusDetail(
    projection: render_input.UsageMenuProjection,
    snapshot: usage_report.Snapshot,
) bool {
    return projection.refresh_error != null or
        (snapshot.coverage != .full and
            (snapshot.coverage != .not_started or
                snapshot.completeness != .complete));
}

fn composeSessionActivityRow(
    alloc: Allocator,
    activity: usage_report.SessionActivity,
    row_index: u16,
    activity_start: usize,
    width: u16,
) !?std.ArrayList(u8) {
    if (row_index == activity_start) return std.ArrayList(u8).empty;
    if (row_index == activity_start + 1) {
        return try composeStyledRow(
            alloc,
            "  Session activity",
            width,
            ui_render.system_notice_label_style,
        );
    }
    var value_buf: [160]u8 = undefined;
    if (row_index == activity_start + 2) {
        return try composeLabelValueRow(
            alloc,
            "API time",
            if (activity.api_duration_complete)
                formatDuration(&value_buf, activity.api_duration_ms)
            else
                "Unavailable",
            usage_value_column,
            width,
        );
    }
    if (row_index == activity_start + 3) {
        return try composeLabelValueRow(
            alloc,
            "Wall time",
            if (activity.wall_duration_complete)
                formatDuration(&value_buf, activity.wall_duration_ms)
            else
                "Unavailable",
            usage_value_column,
            width,
        );
    }
    if (row_index == activity_start + 4) {
        return try composeLabelValueRow(
            alloc,
            "Code changes",
            if (activity.code_complete)
                std.fmt.bufPrint(
                    &value_buf,
                    "+{d} · -{d}",
                    .{ activity.lines_added, activity.lines_removed },
                ) catch "Unavailable"
            else
                "Unavailable",
            usage_value_column,
            width,
        );
    }
    return null;
}

fn composeUsageStatusRow(
    alloc: Allocator,
    projection: render_input.UsageMenuProjection,
    snapshot: usage_report.Snapshot,
    width: u16,
) !std.ArrayList(u8) {
    var status_buf: [160]u8 = undefined;
    var date_buf: [24]u8 = undefined;
    const status = if (projection.refresh_error != null)
        "Refresh failed · showing the previous snapshot"
    else if (snapshot.coverage == .not_started)
        "Tracking has not started"
    else if (snapshot.coverage == .partial and
        snapshot.completeness != .complete)
        std.fmt.bufPrint(
            &status_buf,
            "{s} · partial since {s}",
            .{
                completenessMessage(snapshot),
                usage_report.formatUtcDate(
                    &date_buf,
                    snapshot.coverage_started_at_ms.?,
                ),
            },
        ) catch completenessMessage(snapshot)
    else if (snapshot.coverage == .partial)
        std.fmt.bufPrint(
            &status_buf,
            "Tracking since {s} · partial window",
            .{usage_report.formatUtcDate(
                &date_buf,
                snapshot.coverage_started_at_ms.?,
            )},
        ) catch "Partial tracking window"
    else if (snapshot.completeness != .complete)
        completenessMessage(snapshot)
    else
        "Local Fx activity";
    return composeStyledRow(alloc, status, width, ui_render.dim_style);
}

fn completenessMessage(snapshot: usage_report.Snapshot) []const u8 {
    return switch (snapshot.completeness) {
        .complete => if (snapshot.coverage == .not_started)
            "Tracking has not started."
        else
            "No model usage in this scope.",
        .pending => "Known totals exclude pending reconciliation.",
        .incomplete => "Known totals may be incomplete.",
        .legacy => "This session predates complete usage tracking.",
    };
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
    const visible_models = @max(
        visible_rows -| @intFromBool(projection.expanded_model != null),
        1,
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
            var info_buf: [128]u8 = undefined;
            const info = std.fmt.bufPrint(
                &info_buf,
                "{d} tokens · ${d:.4}",
                .{ model.totals.total_tokens, model.totals.total_cost },
            ) catch "Unavailable";
            return composeWorkspaceActionRow(
                alloc,
                safe_model.bytes,
                info,
                model_index == selected,
                width,
            );
        }
        logical_row += 1;
        if (projection.expanded_model == model_index) {
            if (logical_row == display_row) {
                const totals = snapshot.models[model_index].totals;
                var detail_buf: [256]u8 = undefined;
                var reasoning_buf: [32]u8 = undefined;
                var requests_buf: [32]u8 = undefined;
                const reasoning = if (totals.reasoning_tokens) |value|
                    std.fmt.bufPrint(&reasoning_buf, "{d}", .{value}) catch "?"
                else
                    "n/a";
                const requests = if (totals.request_count) |value|
                    std.fmt.bufPrint(&requests_buf, "{d}", .{value}) catch "?"
                else
                    "n/a";
                const detail = std.fmt.bufPrint(
                    &detail_buf,
                    "  In {d} · Out {d} · Cache {d}/{d} · Reasoning {s} · Requests {s} · ${d:.4}",
                    .{
                        totals.input_tokens,
                        totals.output_tokens,
                        totals.cache_read_tokens,
                        totals.cache_write_tokens,
                        reasoning,
                        requests,
                        totals.total_cost,
                    },
                ) catch "Usage details unavailable";
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

fn composeWorkspaceRow(
    alloc: Allocator,
    projection: render_input.WorkspaceMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    return switch (row_index) {
        0 => composeStyledRow(alloc, "Workspace:", width, ui_render.selected_completion_style),
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
                workspace_summary_value_column,
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
                workspace_summary_value_column,
                width,
            );
        },
        4 => empty,
        else => composeWorkspaceChoiceRow(
            alloc,
            projection,
            row_index,
            visible_rows,
            width,
        ),
    };
}

fn composeWorkspaceChoiceRow(
    alloc: Allocator,
    projection: render_input.WorkspaceMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    const row_count = workspace_menu.State.rowCount(projection.entries);
    const choice_rows = @as(usize, visible_rows) -| workspace_pinned_rows;
    if (choice_rows == 0) return empty;
    const selected = projection.selected_row;
    const max_start = row_count -| choice_rows;
    const window_start = @min(selected -| (choice_rows - 1), max_start);
    const choice_index = window_start + (@as(usize, row_index) - workspace_pinned_rows);
    if (choice_index >= row_count) return empty;

    if (choice_index == 0) {
        return composeWorkspaceActionRow(
            alloc,
            "Add directory…",
            "Grant access to another directory",
            choice_index == selected,
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
            width,
        );
    }
    return composeWorkspaceActionRow(
        alloc,
        "Clear saved directories",
        "Remove every saved additional directory",
        choice_index == selected,
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

    const info_column = workspaceInfoColumn(total_width);
    if (info_column <= used_prefix + 2 or total_width < 32) {
        try row_text.appendSingleLineEllipsized(alloc, &row, label, total_width - used_prefix);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        label,
        info_column - used_prefix - 1,
    );
    try row.appendSlice(alloc, ui_render.reset_style);

    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used >= info_column) return row;
    try row.appendNTimes(alloc, ' ', info_column - used);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, info, total_width - info_column);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn workspaceInfoColumn(width: usize) usize {
    if (width < 32) return width;
    return @min(@max(width * 3 / 5, 28), width - 12);
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
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent: usize = if (width <= 2) 0 else 2;
    if (indent > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (choice.selected) ui_render.selected_completion_style else ui_render.dim_style);
    const value_col = settingsValueColumn(choice.snapshot, choice.setting, width);
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

fn settingsValueColumn(snapshot: settings_catalog.Snapshot, setting: settings_catalog.SettingId, width: u16) usize {
    const total_width: usize = width;
    const right_column_start = total_width * 2 / 3;
    const right_column_width = total_width - right_column_start;
    var options_width: usize = 0;
    const option_count = settings_catalog.optionCount(&snapshot, setting);
    for (0..option_count) |index| {
        if (index > 0) options_width += 2;
        const option = settings_catalog.optionAt(&snapshot, setting, index) orelse continue;
        options_width += display_width.visibleWidth(option);
    }
    const block_width = @min(options_width, right_column_width);
    return right_column_start + (right_column_width - block_width) / 2;
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
    const rows = desiredRowCount(projection);
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

    try std.testing.expectEqual(@as(u16, 12), desiredRowCount(projection));
    var total = try composeCompactCommandMenuRow(std.testing.allocator, projection, 2, 12, 80);
    defer total.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, total.items, "Total tokens") != null);
    try std.testing.expect(std.mem.find(u8, total.items, "120") != null);

    var model = try composeCompactCommandMenuRow(std.testing.allocator, projection, 10, 12, 80);
    defer model.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, model.items, "z.ai/glm-5.2") != null);
    try std.testing.expect(std.mem.find(u8, model.items, "104 tokens") != null);

    var spend = try composeCompactCommandMenuRow(std.testing.allocator, projection, 8, 9, 60);
    defer spend.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, spend.items, "Spend") != null);
    try std.testing.expect(std.mem.find(u8, spend.items, "$0.0123") != null);
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
        25,
        27,
        100,
    );
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, selected.items, "❯ provider/model") != null);

    var details = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        26,
        27,
        100,
    );
    defer details.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, details.items, "In 10 · Out 0") != null);
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
    try std.testing.expect(std.mem.find(u8, details.items, "In 10 · Out 0") != null);
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

    try std.testing.expectEqual(@as(u16, 2), desiredRowCount(projection));
    var status = try composeCompactCommandMenuRow(std.testing.allocator, projection, 1, 2, 80);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, status.items, "Known totals exclude pending") != null);

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

    try std.testing.expectEqual(@as(u16, 7), desiredRowCount(projection));
    var api = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        4,
        7,
        80,
    );
    defer api.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, api.items, "API time") != null);
    try std.testing.expect(std.mem.find(u8, api.items, "1s") != null);

    var wall = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        5,
        7,
        80,
    );
    defer wall.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, wall.items, "Unavailable") != null);

    var code = try composeCompactCommandMenuRow(
        std.testing.allocator,
        projection,
        6,
        7,
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

    try std.testing.expectEqual(@as(u16, 8), desiredRowCount(projection));
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

    try std.testing.expectEqual(@as(u16, 9), desiredRowCount(projection));
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

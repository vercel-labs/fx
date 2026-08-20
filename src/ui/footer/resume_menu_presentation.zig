const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const session_catalog = @import("../../core/session/session_catalog.zig");
const session_store = @import("../../core/session/session_store.zig");
const ui_render = @import("../render.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const SessionMenuProjection = render_input.SessionMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const title_rows: u16 = 1;
// Each session is a single line now: the workspace, age, and turn count live
// in the title row's right cluster, so there is no separate path row or gap.
const path_rows: u16 = 0;
const item_gap_rows: u16 = 0;

const SessionMenuLayout = struct {
    session_count: usize = 0,
    navigation_count: usize = 0,
    selected: usize = 0,
    visible_items: u16 = 0,
    visible_session_items: u16 = 0,
    first_item_row: u16 = header_rows,
    item_stride: u16 = title_rows,
    load_more_row: ?u16 = null,
    feedback_row: ?u16 = null,
    feedback_inline: bool = false,
    row_count: u16 = 0,

    fn build(projection: SessionMenuProjection, row_budget: u16) SessionMenuLayout {
        if (row_budget == 0) return .{};

        const session_count = projection.filteredItemCount();
        const navigation_count = projection.navigationItemCount();
        const selected = if (navigation_count > 0) projection.selected_index % navigation_count else 0;
        if (projection.load_state != .ready or navigation_count == 0) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .row_count = @min(row_budget, header_rows + roomy_top_gap_rows + 1),
            };
        }
        if (row_budget == 1) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .row_count = 1,
            };
        }
        if (projection.selection_failure != null and row_budget == 2) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .visible_items = 1,
                .visible_session_items = 1,
                .first_item_row = 1,
                .feedback_inline = true,
                .row_count = 2,
            };
        }
        if (projection.selection_failure != null and row_budget == 3) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .visible_items = 1,
                .visible_session_items = 1,
                .first_item_row = 1,
                .feedback_row = 2,
                .row_count = 3,
            };
        }
        if (projection.selection_failure != null and projection.has_more and row_budget <= 5) {
            const compact_item_stride: u16 = if (row_budget == 4)
                title_rows
            else
                title_rows + path_rows;
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .visible_items = 2,
                .visible_session_items = 1,
                .first_item_row = 2,
                .item_stride = compact_item_stride,
                .load_more_row = row_budget - 1,
                .feedback_row = 1,
                .row_count = row_budget,
            };
        }
        if (projection.has_more) {
            var layout = buildPaged(session_count, navigation_count, selected, row_budget);
            if (projection.selection_failure != null) layout.feedback_row = 1;
            return layout;
        }
        if (row_budget == 2) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .visible_items = 1,
                .visible_session_items = 1,
                .first_item_row = 1,
                .row_count = 2,
            };
        }
        if (row_budget < header_rows + roomy_top_gap_rows + title_rows + path_rows) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .visible_items = 1,
                .visible_session_items = 1,
                .first_item_row = 1,
                .item_stride = title_rows + path_rows,
                .row_count = 3,
            };
        }

        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_stride = title_rows + path_rows + item_gap_rows;
        const item_budget = (row_budget - first_item_row +| item_gap_rows) / item_stride;
        const visible_items: u16 = @intCast(@min(session_count, @max(item_budget, 1)));
        return .{
            .session_count = session_count,
            .navigation_count = navigation_count,
            .selected = selected,
            .visible_items = visible_items,
            .visible_session_items = visible_items,
            .first_item_row = first_item_row,
            .item_stride = item_stride,
            .feedback_row = if (projection.selection_failure != null) 1 else null,
            .row_count = first_item_row + visible_items * item_stride - item_gap_rows,
        };
    }

    fn buildPaged(
        session_count: usize,
        navigation_count: usize,
        selected: usize,
        row_budget: u16,
    ) SessionMenuLayout {
        if (row_budget == 2) {
            return .{
                .session_count = session_count,
                .navigation_count = navigation_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 1,
                .load_more_row = 1,
                .row_count = 2,
            };
        }

        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_stride = title_rows + path_rows + item_gap_rows;
        const available_session_rows = row_budget -| first_item_row -| 1;
        const session_budget = available_session_rows / item_stride;
        const visible_sessions: u16 = @intCast(@min(session_count, session_budget));
        const load_more_row = first_item_row + visible_sessions * item_stride;
        return .{
            .session_count = session_count,
            .navigation_count = navigation_count,
            .selected = selected,
            .visible_items = visible_sessions + 1,
            .visible_session_items = visible_sessions,
            .first_item_row = first_item_row,
            .item_stride = item_stride,
            .load_more_row = load_more_row,
            .row_count = @min(row_budget, load_more_row + 1),
        };
    }
};

pub fn menuRowCount(projection: SessionMenuProjection, _: u16, max_rows: u16) u16 {
    return SessionMenuLayout.build(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(projection: SessionMenuProjection, row_budget: u16) u16 {
    return SessionMenuLayout.build(projection, row_budget).visible_items;
}

pub fn composeSessionMenuRow(
    alloc: Allocator,
    projection: SessionMenuProjection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_budget) return row;
    if (row_index == 0) return composeHeaderRow(alloc, projection, width);

    const layout = SessionMenuLayout.build(projection, row_budget);
    if (row_index >= layout.row_count) return row;
    if (layout.feedback_row == row_index) {
        return composeSelectionFailureRow(alloc, projection.selection_failure.?, width);
    }
    if (projection.load_state != .ready or layout.navigation_count == 0) {
        if (row_index < layout.row_count -| 1) return row;
        return composeStateRow(alloc, projection, width);
    }
    if (layout.load_more_row == row_index) {
        return composeLoadMoreRow(
            alloc,
            projection.isLoadMoreIndex(layout.selected),
            projection.loading_more,
            width,
        );
    }
    if (row_index < layout.first_item_row) return row;
    if (layout.visible_session_items == 0) return row;

    const body_offset = row_index - layout.first_item_row;
    const visible_offset = body_offset / layout.item_stride;
    if (visible_offset >= layout.visible_session_items) return row;
    const window_start = sessionWindowStart(projection, layout);
    const display_index = window_start + visible_offset;
    const summary = projection.itemAt(display_index) orelse return row;

    // item_stride is 1: every session is a single row.
    const columns = metadataColumns(projection, layout);
    if (layout.feedback_inline) {
        return composeCompactFailureTitleRow(
            alloc,
            summary.*,
            display_index == layout.selected,
            projection.now_ms,
            columns,
            width,
        );
    }
    return composeTitleRow(alloc, summary.*, display_index == layout.selected, projection.now_ms, columns, width);
}

fn sessionWindowStart(projection: SessionMenuProjection, layout: SessionMenuLayout) usize {
    if (layout.session_count == 0 or layout.visible_session_items == 0) return 0;
    if (layout.selected >= layout.session_count) {
        return layout.session_count -| layout.visible_session_items;
    }
    return list_window.updateEdgeStart(
        projection.window_start,
        layout.session_count,
        layout.selected,
        layout.visible_session_items,
    );
}

fn composeHeaderRow(alloc: Allocator, projection: SessionMenuProjection, width: u16) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendHeaderTitle(alloc, &wide, projection.filteredItemCount());
    inline for (std.meta.fields(session_catalog.Scope)) |field| {
        const scope: session_catalog.Scope = @enumFromInt(field.value);
        try wide.appendSlice(alloc, "  ");
        try appendScopeTab(alloc, &wide, scope, scope == projection.scope);
    }
    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) {
        return cloneClippedRow(alloc, wide.items, width);
    }

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try appendHeaderTitle(alloc, &compact, projection.filteredItemCount());
    try compact.appendSlice(alloc, "  ");
    try appendScopeTab(alloc, &compact, projection.scope, true);
    return cloneClippedRow(alloc, compact.items, width);
}

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Sessions {d}", .{count}) catch "Sessions";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendScopeTab(alloc: Allocator, row: *std.ArrayList(u8), scope: session_catalog.Scope, active: bool) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, switch (scope) {
        .current_workspace => "Current workspace",
        .all_workspaces => "All workspaces",
    });
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

// Widths of the right-cluster sub-columns, taken as the max across the
// visible sessions so "<workspace>", "<age>", and "N turns" line up in
// vertical columns instead of drifting with each row's content.
const MetadataColumns = struct {
    workspace: usize = 0,
    age: usize = 0,
    turns: usize = 0,

    fn totalWidth(self: MetadataColumns) usize {
        return self.workspace + separator_width + self.age + separator_width + self.turns;
    }

    const separator_width: usize = 3; // " · "
};

fn sessionWorkspaceLabel(summary: session_store.SessionSummary) []const u8 {
    return std.fs.path.basename(session_catalog.workspacePath(summary));
}

fn sessionTurnsText(buf: []u8, history_len: usize) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d} {s}",
        .{ history_len, if (history_len == 1) "turn" else "turns" },
    ) catch "";
}

fn metadataColumns(projection: SessionMenuProjection, layout: SessionMenuLayout) MetadataColumns {
    var cols: MetadataColumns = .{};
    if (layout.visible_session_items == 0) return cols;
    const start = sessionWindowStart(projection, layout);
    var i: usize = 0;
    while (i < layout.visible_session_items) : (i += 1) {
        const summary = (projection.itemAt(start + i) orelse continue).*;
        var age_buf: [32]u8 = undefined;
        const age = session_catalog.relativeActivityAgeCompact(&age_buf, summary.updated_at_ms, projection.now_ms);
        var turns_buf: [32]u8 = undefined;
        const turns = sessionTurnsText(&turns_buf, summary.history_len);
        cols.workspace = @max(cols.workspace, display_width.visibleWidth(sessionWorkspaceLabel(summary)));
        cols.age = @max(cols.age, display_width.visibleWidth(age));
        cols.turns = @max(cols.turns, display_width.visibleWidth(turns));
    }
    return cols;
}

fn composeTitleRow(
    alloc: Allocator,
    summary: session_store.SessionSummary,
    selected: bool,
    now_ms: i64,
    columns: MetadataColumns,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);

    const indent_width: usize = if (width <= 4) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");

    // Right cluster: "<workspace> · <age> · N turns", all dim, laid out in
    // fixed columns. @max with the row's own widths keeps it self-sizing when
    // no shared columns are supplied.
    var age_buf: [32]u8 = undefined;
    const age = session_catalog.relativeActivityAgeCompact(&age_buf, summary.updated_at_ms, now_ms);
    const workspace = sessionWorkspaceLabel(summary);
    var turns_buf: [32]u8 = undefined;
    const turns = sessionTurnsText(&turns_buf, summary.history_len);
    const workspace_col = @max(columns.workspace, display_width.visibleWidth(workspace));
    const age_col = @max(columns.age, display_width.visibleWidth(age));
    const turns_col = @max(columns.turns, display_width.visibleWidth(turns));
    const metadata_width = workspace_col + MetadataColumns.separator_width + age_col + MetadataColumns.separator_width + turns_col;

    const prefix_width = display_width.visibleWidthIgnoringAnsi(row.items);
    const content_width: usize = @as(usize, width) -| 1;
    const show_metadata = content_width >= prefix_width + 8 + 2 + metadata_width;
    const title_budget = if (show_metadata)
        content_width - prefix_width - metadata_width - 2
    else
        @as(usize, width) -| prefix_width;

    // Selection is signaled by brightness: bold bright white when selected,
    // dim gray otherwise, so the two are clearly distinct. No marker glyph.
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, session_catalog.displayTitle(summary), title_budget);
    try row.appendSlice(alloc, ui_render.reset_style);

    if (show_metadata) {
        try row_text.appendSpacesToColumn(alloc, &row, content_width - metadata_width);
        // The metadata cluster tracks the row's selection: bold bright with the
        // selected title, dim gray otherwise, so the whole selected row stands out.
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
        // Workspace and turn count left-aligned, age right-aligned: each column
        // keeps its own digits in line. The turn count closes the row, so it
        // needs no trailing padding.
        try row.appendSlice(alloc, workspace);
        try row.appendNTimes(alloc, ' ', workspace_col - display_width.visibleWidth(workspace));
        try row.appendSlice(alloc, " · ");
        try row.appendNTimes(alloc, ' ', age_col - display_width.visibleWidth(age));
        try row.appendSlice(alloc, age);
        try row.appendSlice(alloc, " · ");
        try row.appendSlice(alloc, turns);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeLoadMoreRow(
    alloc: Allocator,
    selected: bool,
    loading: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent_width: usize = if (width <= 4) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        if (loading) "↓ Loading more…" else "↓ Load more",
        @as(usize, width) -| indent_width,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeStateRow(alloc: Allocator, projection: SessionMenuProjection, width: u16) !std.ArrayList(u8) {
    const message = switch (projection.load_state) {
        .loading => "Loading sessions…",
        .failed => "Unable to load sessions.",
        .ready => "No sessions found.",
    };
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width > 4) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, message, width -| 2);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSelectionFailureRow(
    alloc: Allocator,
    failure: session_catalog.ResumeFailure,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent_width: usize = if (width > 4) 2 else 0;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.red_style);
    const message = switch (failure) {
        .open_elsewhere => "This session is open in another Fx. Close it there, then press Enter to retry.",
        .being_updated => "This session is being updated. Wait a moment, then press Enter to retry.",
        .select_connection => "Restore or select this session's saved connection, then press Enter to retry.",
        .unavailable => "Unable to resume this session.",
    };
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        message,
        @as(usize, width) -| indent_width,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeCompactFailureTitleRow(
    alloc: Allocator,
    summary: session_store.SessionSummary,
    selected: bool,
    now_ms: i64,
    columns: MetadataColumns,
    width: u16,
) !std.ArrayList(u8) {
    const retry_text = " · retry";
    const retry_width: u16 = @intCast(display_width.visibleWidth(retry_text));
    const suffix_width = @min(width, retry_width);
    var row = try composeTitleRow(
        alloc,
        summary,
        selected,
        now_ms,
        columns,
        width -| suffix_width,
    );
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.red_style);
    try row_text.appendClipped(alloc, &row, retry_text, suffix_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, bytes: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, bytes, width);
    return row;
}

test "resume menu starts every turn count in the same column" {
    const alloc = std.testing.allocator;
    const summaries = [_]session_store.SessionSummary{
        .{
            .id = @constCast("one"),
            .workspace_root = @constCast("/tmp/resume-catalog"),
            .title = @constCast("single turn"),
            .created_at_ms = 1,
            .updated_at_ms = 1_000,
            .conversation_language = .literal("en"),
            .history_len = 1,
        },
        .{
            .id = @constCast("two"),
            .workspace_root = @constCast("/tmp/resume-catalog"),
            .title = @constCast("many turns"),
            .created_at_ms = 1,
            .updated_at_ms = 1_000,
            .conversation_language = .literal("en"),
            .history_len = 12,
        },
    };
    const projection: SessionMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .summaries = &summaries,
        .scope = .current_workspace,
        .now_ms = 1_000 + 8 * std.time.ms_per_min,
    };

    var first = try composeSessionMenuRow(alloc, projection, 2, 120, 5);
    defer first.deinit(alloc);
    var second = try composeSessionMenuRow(alloc, projection, 3, 120, 5);
    defer second.deinit(alloc);

    const first_turns = std.mem.find(u8, first.items, "1 turn") orelse return error.TestMissingTurnCount;
    const second_turns = std.mem.find(u8, second.items, "12 turns") orelse return error.TestMissingTurnCount;
    try std.testing.expectEqual(
        display_width.visibleWidthIgnoringAnsi(first.items[0..first_turns]),
        display_width.visibleWidthIgnoringAnsi(second.items[0..second_turns]),
    );
}

test "resume menu renders each session on one line with a right metadata cluster" {
    const alloc = std.testing.allocator;
    const summaries = [_]session_store.SessionSummary{.{
        .id = @constCast("one"),
        .workspace_root = @constCast("/Users/example/Developer/Fx/worktrees/resume-catalog"),
        .title = @constCast("Redesign resume menu"),
        .created_at_ms = 1,
        .updated_at_ms = 1_000,
        .conversation_language = .literal("en"),
        .history_len = 24,
    }};
    const projection: SessionMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .summaries = &summaries,
        .scope = .current_workspace,
        .now_ms = 1_000 + 8 * std.time.ms_per_min,
    };

    var header = try composeSessionMenuRow(alloc, projection, 0, 120, 4);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Sessions 1") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[Current workspace]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "All workspaces") != null);

    var title = try composeSessionMenuRow(alloc, projection, 2, 120, 4);
    defer title.deinit(alloc);
    // Single line, no selection marker: title plus the dim right cluster
    // "<workspace> · <age> · N turns" using the workspace basename.
    try std.testing.expect(std.mem.find(u8, title.items, "Redesign resume menu") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "resume-catalog · 8m · 24 turns") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "●") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "○") == null);
}

test "resume menu renders loading empty and failure states" {
    const alloc = std.testing.allocator;
    const states = [_]struct { state: session_catalog.LoadState, text: []const u8 }{
        .{ .state = .loading, .text = "Loading sessions…" },
        .{ .state = .ready, .text = "No sessions found." },
        .{ .state = .failed, .text = "Unable to load sessions." },
    };
    for (states) |state| {
        const projection: SessionMenuProjection = .{ .active = true, .load_state = state.state };
        var row = try composeSessionMenuRow(alloc, projection, 2, 80, 3);
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, state.text) != null);
    }
}

test "resume menu explains retryable selected session contention" {
    const alloc = std.testing.allocator;
    const summaries = [_]session_store.SessionSummary{.{
        .id = @constCast("one"),
        .title = @constCast("Selected session"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    const cases = [_]struct {
        failure: session_catalog.ResumeFailure,
        message: []const u8,
    }{
        .{
            .failure = .open_elsewhere,
            .message = "This session is open in another Fx. Close it there, then press Enter to retry.",
        },
        .{
            .failure = .being_updated,
            .message = "This session is being updated. Wait a moment, then press Enter to retry.",
        },
        .{
            .failure = .unavailable,
            .message = "Unable to resume this session.",
        },
    };

    for (cases) |case| {
        const projection: SessionMenuProjection = .{
            .active = true,
            .load_state = .ready,
            .summaries = &summaries,
            .selection_failure = case.failure,
        };
        var row = try composeSessionMenuRow(alloc, projection, 1, 100, 4);
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, case.message) != null);
        try std.testing.expect(std.mem.find(u8, row.items, "SessionCommitBoundaryUnavailable") == null);
    }
}

test "resume menu keeps selected title and retry feedback in compact layouts" {
    const alloc = std.testing.allocator;
    const summaries = [_]session_store.SessionSummary{.{
        .id = @constCast("one"),
        .workspace_root = @constCast("/workspace"),
        .title = @constCast("Selected session"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    const projection: SessionMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .summaries = &summaries,
        .selection_failure = .being_updated,
    };

    try std.testing.expectEqual(@as(u16, 1), visibleNavigationItemsForBudget(projection, 2));
    var two_row = try composeSessionMenuRow(alloc, projection, 1, 100, 2);
    defer two_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, two_row.items, "Selected session") != null);
    try std.testing.expect(std.mem.find(u8, two_row.items, "retry") != null);

    try std.testing.expectEqual(@as(u16, 1), visibleNavigationItemsForBudget(projection, 3));
    var three_row_title = try composeSessionMenuRow(alloc, projection, 1, 100, 3);
    defer three_row_title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, three_row_title.items, "Selected session") != null);
    var three_row_feedback = try composeSessionMenuRow(alloc, projection, 2, 100, 3);
    defer three_row_feedback.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, three_row_feedback.items, "press Enter to retry") != null);

    var paged_projection = projection;
    paged_projection.has_more = true;
    for ([_]u16{ 4, 5 }) |row_budget| {
        try std.testing.expectEqual(
            @as(u16, 2),
            visibleNavigationItemsForBudget(paged_projection, row_budget),
        );
        var paged_feedback = try composeSessionMenuRow(
            alloc,
            paged_projection,
            1,
            100,
            row_budget,
        );
        defer paged_feedback.deinit(alloc);
        try std.testing.expect(
            std.mem.find(u8, paged_feedback.items, "press Enter to retry") != null,
        );
        var paged_title = try composeSessionMenuRow(
            alloc,
            paged_projection,
            2,
            100,
            row_budget,
        );
        defer paged_title.deinit(alloc);
        try std.testing.expect(
            std.mem.find(u8, paged_title.items, "Selected session") != null,
        );
        var load_more = try composeSessionMenuRow(
            alloc,
            paged_projection,
            row_budget - 1,
            100,
            row_budget,
        );
        defer load_more.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, load_more.items, "Load more") != null);
    }
}

test "resume menu keeps long titles on one narrow row without a workspace spill row" {
    const alloc = std.testing.allocator;
    const summaries = [_]session_store.SessionSummary{.{
        .id = @constCast("one"),
        .workspace_root = @constCast("/Users/example/Developer/Fx/worktrees/a-very-long-session-catalog-worktree"),
        .title = @constCast("Investigate a very long session catalog rendering issue"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    const projection: SessionMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .summaries = &summaries,
    };

    var title = try composeSessionMenuRow(alloc, projection, 2, 32, 4);
    defer title.deinit(alloc);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(title.items) <= 32);
    try std.testing.expect(std.mem.find(u8, title.items, "…") != null);
    try std.testing.expect(std.mem.findScalar(u8, title.items, '\n') == null);

    var next_row = try composeSessionMenuRow(alloc, projection, 3, 32, 4);
    defer next_row.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), next_row.items.len);
}

test "resume menu keeps shared-prefix session titles distinguishable when narrow" {
    const alloc = std.testing.allocator;
    const alpha = session_store.SessionSummary{
        .id = @constCast("alpha"),
        .workspace_root = @constCast("/workspace"),
        .title = @constCast("Shared production composer regression investigation session alpha"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    };
    const beta = session_store.SessionSummary{
        .id = @constCast("beta"),
        .workspace_root = @constCast("/workspace"),
        .title = @constCast("Shared production composer regression investigation session beta"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    };

    var alpha_row = try composeTitleRow(alloc, alpha, true, 1, .{}, 64);
    defer alpha_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, alpha_row.items, "Shared p") != null);
    try std.testing.expect(std.mem.find(u8, alpha_row.items, "n alpha") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(alpha_row.items) <= 64);

    var beta_row = try composeTitleRow(alloc, beta, false, 1, .{}, 64);
    defer beta_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, beta_row.items, "Shared p") != null);
    try std.testing.expect(std.mem.find(u8, beta_row.items, "on beta") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(beta_row.items) <= 64);
}

test "resume menu keeps a complete compact item within a three row budget" {
    const summaries = [_]session_store.SessionSummary{.{
        .id = @constCast("one"),
        .workspace_root = @constCast("/workspace"),
        .title = @constCast("Compact session"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    const projection: SessionMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .summaries = &summaries,
    };

    try std.testing.expectEqual(@as(u16, 3), menuRowCount(projection, 80, 3));
    try std.testing.expectEqual(@as(u16, 1), visibleNavigationItemsForBudget(projection, 3));
}

test "resume menu renders a navigable load more action" {
    const alloc = std.testing.allocator;
    const summaries = [_]session_store.SessionSummary{.{
        .id = @constCast("one"),
        .workspace_root = @constCast("/workspace"),
        .title = @constCast("First page"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    const projection: SessionMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .summaries = &summaries,
        .has_more = true,
        .selected_index = 1,
    };

    try std.testing.expectEqual(@as(usize, 2), projection.navigationItemCount());
    const row_budget: u16 = 7;
    const row_count = menuRowCount(projection, 80, row_budget);
    var header = try composeSessionMenuRow(alloc, projection, 0, 80, row_budget);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Sessions 1") != null);

    var action = try composeSessionMenuRow(alloc, projection, row_count - 1, 80, row_budget);
    defer action.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, action.items, "↓ Load more") != null);

    var loading_projection = projection;
    loading_projection.loading_more = true;
    var loading = try composeSessionMenuRow(
        alloc,
        loading_projection,
        row_count - 1,
        80,
        row_budget,
    );
    defer loading.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, loading.items, "↓ Loading more…") != null);
}

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
const model_capabilities = @import("../../core/config/model_capabilities.zig");
const token_pass = @import("../../core/gateway/token_pass.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const ui_render = @import("../render.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const ModelMenuProjection = render_input.ModelMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const item_rows: u16 = 1;
const status_gap_rows: u16 = 1;
pub const max_visible_items: u16 = 20;
pub const max_inline_rows: u16 = header_rows + roomy_top_gap_rows + max_visible_items + status_gap_rows + 1;

/// A grouped list adds three rows: the Token Pass heading, the gap before
/// the second group, and that group's heading.
const group_heading_rows: u16 = 3;

const ModelMenuLayout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    /// The models the window keeps in view, which navigation pages by.
    visible_items: u16 = 0,
    /// The rows the list takes below the gap: one per model, plus the
    /// headings when the list is grouped.
    body_rows: u16 = 0,
    /// The Token Pass models that lead a grouped list, under their own
    /// heading; null when the list is not grouped.
    token_pass_rows: ?usize = null,
    first_item_row: u16 = header_rows,
    item_stride: u16 = item_rows,
    show_header: bool = true,
    state_row: ?u16 = null,
    status_row: ?u16 = null,
    row_count: u16 = 0,

    fn build(projection: ModelMenuProjection, row_budget: u16) ModelMenuLayout {
        if (row_budget == 0) return .{};

        const match_count = projection.filteredItemCount();
        const selected = if (match_count > 0) projection.selected_index % match_count else 0;
        if (projection.load_state != .ready or match_count == 0) {
            const state_row: u16 = if (row_budget == 1)
                0
            else if (row_budget == 2)
                1
            else
                header_rows + roomy_top_gap_rows;
            var row_count = state_row + 1;
            const show_status = projection.load_state == .ready and
                loadedCatalogStatusText(projection.catalog_state) != null and
                row_budget >= row_count + status_gap_rows + 1;
            const status_row = if (show_status) row_count + status_gap_rows else null;
            if (status_row) |row| row_count = row + 1;
            return .{
                .match_count = match_count,
                .selected = selected,
                .show_header = row_budget > 1,
                .state_row = state_row,
                .status_row = status_row,
                .row_count = row_count,
            };
        }
        if (row_budget == 1) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .body_rows = 1,
                .first_item_row = 0,
                .show_header = false,
                .row_count = 1,
            };
        }
        if (row_budget == 2) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .body_rows = 1,
                .first_item_row = 1,
                .row_count = 2,
            };
        }
        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_budget = @max(row_budget - first_item_row, 1);
        var token_pass_rows = tokenPassLeadCount(projection, match_count);
        var body_rows: u16 = @intCast(@min(match_count, item_budget, max_visible_items));
        var visible_items = body_rows;
        if (token_pass_rows != null) {
            const grouped_rows: u16 = @intCast(@min(match_count + group_heading_rows, item_budget, max_visible_items));
            // The headings need room for at least two models beside them.
            if (grouped_rows >= group_heading_rows + 2) {
                body_rows = grouped_rows;
                visible_items = grouped_rows - group_heading_rows;
            } else {
                token_pass_rows = null;
            }
        }
        const show_status = loadedCatalogStatusText(projection.catalog_state) != null and item_budget - body_rows >= status_gap_rows + 1;
        const status_row = if (show_status) first_item_row + body_rows + status_gap_rows else null;
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .body_rows = body_rows,
            .token_pass_rows = token_pass_rows,
            .first_item_row = first_item_row,
            .item_stride = item_rows,
            .status_row = status_row,
            .row_count = first_item_row + body_rows + @intFromBool(show_status) * (status_gap_rows + 1),
        };
    }
};

/// How many Token Pass models lead the list when it shows them under their
/// own heading: only for a team that has Token Pass, only while nothing is
/// typed, since a search ranks models by match, and only when other models
/// follow them.
fn tokenPassLeadCount(projection: ModelMenuProjection, match_count: usize) ?usize {
    if (!projection.token_pass or projection.query.len > 0) return null;
    var count: usize = 0;
    while (count < match_count) : (count += 1) {
        const item = projection.itemAt(count) orelse break;
        if (!token_pass.isFeaturedModel(item.id)) break;
    }
    if (count == 0 or count == match_count) return null;
    return count;
}

/// One line of a grouped list: the Token Pass heading, its models, a gap,
/// then the heading and models of every other model.
const GroupedLine = union(enum) {
    token_pass_heading,
    gap,
    others_heading,
    item: usize,
};

fn groupedLine(line: usize, token_pass_rows: usize) GroupedLine {
    if (line == 0) return .token_pass_heading;
    if (line <= token_pass_rows) return .{ .item = line - 1 };
    if (line == token_pass_rows + 1) return .gap;
    if (line == token_pass_rows + 2) return .others_heading;
    return .{ .item = line - group_heading_rows };
}

/// The first line a grouped list shows when the window starts at model
/// `window_start`. A window that starts at a group's first model also shows
/// that group's heading, and the window never runs past the last line.
fn groupedFirstLine(window_start: usize, token_pass_rows: usize, match_count: usize, body_rows: u16) usize {
    const line = if (window_start == 0)
        0
    else if (window_start < token_pass_rows)
        window_start + 1
    else if (window_start == token_pass_rows)
        token_pass_rows + 2
    else
        window_start + group_heading_rows;
    return @min(line, (match_count + group_heading_rows) -| body_rows);
}

pub fn menuRowCount(projection: ModelMenuProjection, _: u16, max_rows: u16) u16 {
    return ModelMenuLayout.build(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(projection: ModelMenuProjection, row_budget: u16) u16 {
    return ModelMenuLayout.build(projection, row_budget).visible_items;
}

pub inline fn composeModelMenuRow(
    alloc: Allocator,
    projection: ModelMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return row;

    const layout = ModelMenuLayout.build(projection, row_count);
    if (layout.show_header and row_index == 0) return composeHeaderRow(alloc, projection, width);
    if (projection.load_state != .ready or layout.match_count == 0) {
        if (layout.state_row == row_index) return composeStateRow(alloc, projection, width);
        if (layout.status_row == row_index) {
            const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
            return composeDimmedRow(alloc, text, width);
        }
        return row;
    }
    if (layout.status_row) |status_row| {
        if (row_index == status_row) {
            const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
            return composeDimmedRow(alloc, text, width);
        }
    }
    if (row_index < layout.first_item_row) return row;

    const body_offset = row_index - layout.first_item_row;
    if (body_offset >= layout.body_rows) return row;
    const window_start = list_window.updateEdgeStart(
        projection.window_start,
        layout.match_count,
        layout.selected,
        layout.visible_items,
    );
    const item_row: u16, const display_index: usize = if (layout.token_pass_rows) |token_pass_rows| blk: {
        const line = groupedFirstLine(window_start, token_pass_rows, layout.match_count, layout.body_rows) + body_offset;
        switch (groupedLine(line, token_pass_rows)) {
            .token_pass_heading => return composeGroupHeading(alloc, "Token Pass", token_pass_rows, width),
            .gap => return row,
            .others_heading => return composeGroupHeading(alloc, "All Models", layout.match_count - token_pass_rows, width),
            .item => |index| break :blk .{ 0, index },
        }
    } else .{ body_offset % layout.item_stride, window_start + body_offset / layout.item_stride };
    const item = projection.itemAt(display_index) orelse return row;

    if (item_row == 0) {
        return composeTitleRow(
            alloc,
            item.*,
            display_index == layout.selected,
            FactColumns.build(projection, width, if (layout.token_pass_rows != null) .shown else .hidden),
            width,
        );
    }
    return row;
}

fn composeHeaderRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try appendHeaderTitle(alloc, &row, projection.filteredItemCount());

    const tabs = ProviderTabs.build(projection.items);
    const active_position = tabs.activePosition(projection.provider_index);
    const active_index = tabs.indices[active_position];
    const title_width = display_width.visibleWidthIgnoringAnsi(row.items);
    if (title_width + 2 + providerTabWidth(active_index, active_index) > width) {
        try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, active_index, active_index);
        return cloneClippedRow(alloc, row.items, width);
    }

    var start = active_position;
    var end = active_position + 1;
    while (true) {
        var expanded = false;
        if (end < tabs.len and title_width + 2 + providerRangeWidth(tabs, start, end + 1, active_index) <= width) {
            end += 1;
            expanded = true;
        }
        if (start > 0 and title_width + 2 + providerRangeWidth(tabs, start - 1, end, active_index) <= width) {
            start -= 1;
            expanded = true;
        }
        if (!expanded) break;
    }

    try row.appendSlice(alloc, "  ");
    if (start > 0) {
        try appendProviderOverflowMarker(alloc, &row);
        try row.appendSlice(alloc, "  ");
    }
    for (start..end) |position| {
        if (position > start) try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, tabs.indices[position], active_index);
    }
    if (end < tabs.len) {
        try row.appendSlice(alloc, "  ");
        try appendProviderOverflowMarker(alloc, &row);
    }
    return cloneClippedRow(alloc, row.items, width);
}

const ProviderTabs = struct {
    indices: [model_cache_runtime.model_provider_filter_count]usize = undefined,
    len: usize = 0,

    fn build(items: []const model_cache_runtime.ModelMenuItem) ProviderTabs {
        var tabs: ProviderTabs = .{};
        for (0..model_cache_runtime.model_provider_filter_count) |index| {
            const filter: model_cache_runtime.ModelProviderFilter = @fromBackingInt(@intCast(index));
            if (!model_cache_runtime.modelProviderFilterAvailable(items, filter)) continue;
            tabs.indices[tabs.len] = index;
            tabs.len += 1;
        }
        return tabs;
    }

    fn activePosition(self: ProviderTabs, active_index: usize) usize {
        for (self.indices[0..self.len], 0..) |index, position| {
            if (index == active_index) return position;
        }
        return 0;
    }
};

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.mem.print(&buf, "Models {d}", .{count}) catch "Models";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendProviderTab(alloc: Allocator, row: *std.ArrayList(u8), label: []const u8, active: bool) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, label);
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendProviderTabAt(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    index: usize,
    active_index: usize,
) !void {
    try appendProviderTab(alloc, row, providerTabLabel(index), index == active_index);
}

fn appendProviderOverflowMarker(alloc: Allocator, row: *std.ArrayList(u8)) !void {
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, "…");
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn providerTabLabel(index: usize) []const u8 {
    const filter: model_cache_runtime.ModelProviderFilter = @fromBackingInt(@intCast(index));
    return switch (filter) {
        .all => "All",
        .anthropic => "Anthropic",
        .openai => "OpenAI",
        .xai => "xAI",
        .zai => "Z.AI",
        .others => "Others",
    };
}

fn providerTabWidth(index: usize, active_index: usize) usize {
    const active_padding: usize = if (index == active_index) 2 else 0;
    return display_width.visibleWidth(providerTabLabel(index)) + active_padding;
}

fn providerRangeWidth(
    tabs: ProviderTabs,
    start: usize,
    end: usize,
    active_index: usize,
) usize {
    var width: usize = if (start > 0) 3 else 0;
    for (start..end) |position| {
        if (position > start) width += 2;
        width += providerTabWidth(tabs.indices[position], active_index);
    }
    if (end < tabs.len) width += 3;
    return width;
}

/// The spaces between a model's id and its first fact, and between facts.
const fact_gap: usize = 3;
/// A model id keeps at least this many cells before facts take the rest.
const min_id_width: usize = 20;

/// The facts beside each model, in columns that line up down the list: the
/// Token Pass tag, the context window, the output limit, and the speed
/// options. The widths come from every model in the open tab, so the columns
/// stay put while the user scrolls or types a search. A row that is too
/// narrow drops whole columns from the right, the Token Pass tag last.
const FactColumns = struct {
    /// The cell where the first column starts.
    start: usize = 0,
    token_pass: bool = false,
    /// Whether the team has Token Pass, which drops Fast mode from its models.
    token_pass_team: bool = false,
    context_digits: usize = 0,
    output_digits: usize = 0,
    speed: usize = 0,

    const context_label = " context";
    const output_label = " output";

    /// Whether the list shows the Token Pass heading above its models.
    const Headings = enum { shown, hidden };

    fn build(projection: ModelMenuProjection, row_width: u16, headings: Headings) ?FactColumns {
        const indent: usize = if (row_width <= 2) 0 else 2;
        const filter = projection.providerFilter();
        var columns: FactColumns = .{ .token_pass_team = projection.token_pass };
        var longest_id: usize = 8;
        var tab_has_token_pass = false;
        for (projection.items) |item| {
            if (!model_cache_runtime.modelProviderFilterKeeps(item, filter)) continue;
            longest_id = @max(longest_id, display_width.visibleWidth(item.id));
            if (projection.token_pass and token_pass.isFeaturedModel(item.id)) tab_has_token_pass = true;
            var buf: [32]u8 = undefined;
            if (item.capabilities.context_window) |tokens| {
                const text: []const u8 = formatTokenCount(&buf, tokens) catch "";
                columns.context_digits = @max(columns.context_digits, text.len);
            }
            if (item.capabilities.max_output_tokens) |tokens| {
                const text: []const u8 = formatTokenCount(&buf, tokens) catch "";
                columns.output_digits = @max(columns.output_digits, text.len);
            }
            columns.speed = @max(columns.speed, speedFacts(&buf, itemSpeed(item, projection.token_pass)).len);
        }
        // Under the Token Pass heading the tag says nothing new.
        columns.token_pass = tab_has_token_pass and headings == .hidden;

        const id_floor = @min(longest_id, min_id_width);
        while (columns.width() > 0 and indent + id_floor + fact_gap + columns.width() > row_width) columns.dropLast();
        if (columns.width() == 0) return null;
        columns.start = @min(indent + longest_id + fact_gap, @as(usize, row_width) - columns.width());
        return columns;
    }

    fn width(self: FactColumns) usize {
        var total: usize = 0;
        var count: usize = 0;
        if (self.token_pass) {
            total += token_pass_fact.len;
            count += 1;
        }
        if (self.context_digits > 0) {
            total += self.context_digits + context_label.len;
            count += 1;
        }
        if (self.output_digits > 0) {
            total += self.output_digits + output_label.len;
            count += 1;
        }
        if (self.speed > 0) {
            total += self.speed;
            count += 1;
        }
        return total + fact_gap * (count -| 1);
    }

    fn dropLast(self: *FactColumns) void {
        if (self.speed > 0) {
            self.speed = 0;
        } else if (self.output_digits > 0) {
            self.output_digits = 0;
        } else if (self.context_digits > 0) {
            self.context_digits = 0;
        } else {
            self.token_pass = false;
        }
    }

    /// Writes `item`'s cells, each padded to its column. Spaces are written
    /// only before a fact, so a row never ends in padding.
    fn appendCells(self: FactColumns, alloc: Allocator, out: *std.ArrayList(u8), item: model_cache_runtime.ModelMenuItem) !void {
        var cells: CellWriter = .{ .alloc = alloc, .out = out };
        if (self.token_pass) {
            try cells.cell(if (token_pass.isFeaturedModel(item.id)) token_pass_fact else "", token_pass_fact.len);
        }
        var buf: [32]u8 = undefined;
        if (self.context_digits > 0) {
            try cells.cell(try tokenCell(&buf, item.capabilities.context_window, self.context_digits, context_label), self.context_digits + context_label.len);
        }
        if (self.output_digits > 0) {
            try cells.cell(try tokenCell(&buf, item.capabilities.max_output_tokens, self.output_digits, output_label), self.output_digits + output_label.len);
        }
        if (self.speed > 0) try cells.cell(speedFacts(&buf, itemSpeed(item, self.token_pass_team)), self.speed);
    }
};

const CellWriter = struct {
    alloc: Allocator,
    out: *std.ArrayList(u8),
    /// Spaces owed before the next fact: gaps and the padding of cells so far.
    pending: usize = 0,
    started: bool = false,

    fn cell(self: *CellWriter, text: []const u8, cell_width: usize) !void {
        if (self.started) self.pending += fact_gap;
        self.started = true;
        if (text.len > 0) {
            try self.out.appendNTimes(self.alloc, ' ', self.pending);
            try self.out.appendSlice(self.alloc, text);
            self.pending = 0;
        }
        self.pending += cell_width -| text.len;
    }
};

/// A token count right-aligned in `digits` cells and followed by `label`,
/// or nothing when the catalog does not say.
fn tokenCell(buf: *[32]u8, tokens: ?u32, digits: usize, label: []const u8) ![]const u8 {
    const count = tokens orelse return "";
    var count_buf: [16]u8 = undefined;
    const text = try formatTokenCount(&count_buf, count);
    const pad = digits -| text.len;
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..text.len], text);
    @memcpy(buf[pad + text.len ..][0..label.len], label);
    return buf[0 .. pad + text.len + label.len];
}

/// The capabilities whose speed facts `item` shows. Token Pass credit does
/// not pay for Fast mode, so for a team with Token Pass its models leave
/// Fast mode out.
fn itemSpeed(item: model_cache_runtime.ModelMenuItem, token_pass_team: bool) model_capabilities.Capabilities {
    var capabilities = item.capabilities;
    capabilities.supports_fast_mode = token_pass.offersFastMode(token_pass_team, item.id, capabilities.supports_fast_mode);
    return capabilities;
}

/// The speed options a model has, as one cell: `Fast` for a model that
/// always runs fast, and `Fast mode` or `Ultrafast mode` for options it offers.
fn speedFacts(buf: *[32]u8, capabilities: model_capabilities.Capabilities) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    const facts = [_]struct { on: bool, text: []const u8 }{
        .{ .on = capabilities.intrinsic_fast, .text = fast_fact },
        .{ .on = capabilities.supports_fast_mode, .text = fast_mode_fact },
        .{ .on = capabilities.supports_ultrafast_mode, .text = ultrafast_mode_fact },
    };
    var any = false;
    for (facts) |fact| {
        if (!fact.on) continue;
        if (any) writer.writeAll(", ") catch break;
        writer.writeAll(fact.text) catch break;
        any = true;
    }
    return writer.buffered();
}

/// Writes a token count the way model providers write it. A size that is a
/// multiple of 1,024 counts 1,024 per K, so 131072 reads 128K and 1048576
/// reads 1M; other sizes count 1,000 per K, so 128000 reads 128K and 1050000
/// reads 1.05M. Thousands round to a whole number, millions to two places.
fn formatTokenCount(buf: []u8, tokens: u32) ![]const u8 {
    if (tokens < 1000) return std.mem.print(buf, "{d}", .{tokens});
    const unit: u64 = if (tokens % 1024 == 0 and tokens % 1000 != 0) 1024 else 1000;
    const thousands = (@as(u64, tokens) + unit / 2) / unit;
    if (thousands < 1000) return std.mem.print(buf, "{d}K", .{thousands});
    const hundredths = (@as(u64, tokens) * 100 + unit * unit / 2) / (unit * unit);
    const whole = hundredths / 100;
    const fraction = hundredths % 100;
    if (fraction == 0) return std.mem.print(buf, "{d}M", .{whole});
    if (fraction % 10 == 0) return std.mem.print(buf, "{d}.{d}M", .{ whole, fraction / 10 });
    return std.mem.print(buf, "{d}.{d:0>2}M", .{ whole, fraction });
}

fn composeTitleRow(
    alloc: Allocator,
    item: model_cache_runtime.ModelMenuItem,
    selected: bool,
    columns: ?FactColumns,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent_width: usize = if (width <= 2) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);

    var cells: std.ArrayList(u8) = .empty;
    defer cells.deinit(alloc);
    if (columns) |c| try c.appendCells(alloc, &cells, item);

    const id_budget = if (columns) |c| c.start - indent_width - fact_gap else @as(usize, width) -| indent_width;
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, item.id, id_budget);
    if (selected) try row.appendSlice(alloc, ui_render.reset_style);

    if (cells.items.len > 0) {
        try row_text.appendSpacesToColumn(alloc, &row, columns.?.start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, cells.items);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

// A `-fast` model always runs fast, so it reads "Fast". "Fast mode" and "Ultrafast mode"
// name speed options the model offers, so they are not mistaken for a fast model.
const fast_fact = "Fast";
const fast_mode_fact = "Fast mode";
const ultrafast_mode_fact = "Ultrafast mode";
// Listed first, so a narrow row cuts the other facts and keeps this one.
const token_pass_fact = "Token Pass";

fn composeStateRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    const text = switch (projection.load_state) {
        .loading => "Loading models…",
        .failed => retryableFailureText(projection.catalog_state.failure) orelse "Unable to load models.",
        .ready => if (projection.items.len == 0) "No models available." else "No models found.",
    };
    return composeDimmedRow(alloc, text, width);
}

fn loadedCatalogStatusText(state: model_cache_runtime.ModelMenuCatalogState) ?[]const u8 {
    if (retryableFailureText(state.failure)) |text| return text;
    if (state.from_profile_settings) return "Models from settings and, with fetch_models, the server; explicit model IDs need no catalog.";
    if (state.private_models_hidden) {
        const reason = state.public_only_reason orelse return "Using the public model catalog.";
        return switch (reason) {
            .no_credential => "Using the public model catalog; sign in or use an API key for team-private models.",
            .fx_login_team_required => "Choose a Vercel team to load its private models.",
            .fx_login_refresh_required => "Vercel sign-in must refresh before team-private models can load.",
            .credential_refresh_required => "The selected sign-in must refresh before authenticated models can load.",
            .credential_refresh_failed => "Vercel sign-in refresh failed; using the public model catalog.",
            .authenticated_credential_rejected => "Your Gateway credential was rejected; using the public model catalog.",
            .chatgpt_subscription => "Codex models require an authenticated Codex catalog.",
            .grok_subscription => "Grok models require an authenticated Grok catalog.",
        };
    }
    if (state.access_level == .authenticated) {
        const source = state.source orelse return "Using an authenticated AI Gateway catalog.";
        return switch (source) {
            .fx_login => "Gateway catalog: authenticated with fx login.",
            .ai_gateway_api_key => "Note: Gateway catalog is authenticated with an API key",
            .vercel_oidc_token => "Gateway catalog: authenticated with the Vercel session.",
            .stored_key => "Gateway catalog: authenticated with the stored API key.",
            .chatgpt_subscription => "Codex catalog: authenticated with a subscription.",
            .grok_subscription => "Grok catalog: authenticated with a subscription.",
            .host_managed => "Provider catalog: authentication is managed by the host.",
            .configured => "Provider catalog: models from profile settings.",
        };
    }
    return null;
}

fn retryableFailureText(failure: ?model_cache_runtime.ModelMenuCatalogState.Failure) ?[]const u8 {
    const value = failure orelse return null;
    if (!value.retryable) return null;
    return switch (value.category) {
        .rate_limited => "AI Gateway rate limited model discovery; fx retries automatically.",
        .transport, .gateway_unavailable => "Could not reach AI Gateway; fx retries automatically.",
        else => "Could not refresh model catalog; fx retries automatically.",
    };
}

/// A group's heading in the list, styled like the headings in `/mcp` and
/// always bold, whatever the theme's subtitle style is.
fn composeGroupHeading(alloc: Allocator, name: []const u8, count: usize, width: u16) !std.ArrayList(u8) {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var count_buf: [24]u8 = undefined;
    if (width > 2) try text.appendSlice(alloc, "  ");
    try text.appendSlice(alloc, ui_render.subtitle_style);
    try text.appendSlice(alloc, ui_render.bold_style);
    try text.appendSlice(alloc, name);
    try text.appendSlice(alloc, ui_render.reset_style);
    try text.appendSlice(alloc, "  ");
    try text.appendSlice(alloc, ui_render.dim_style);
    try text.appendSlice(alloc, std.mem.print(&count_buf, "{d}", .{count}) catch "");
    try text.appendSlice(alloc, ui_render.reset_style);
    return cloneClippedRow(alloc, text.items, width);
}

fn composeDimmedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "model menu renders provider tabs and compact model facts" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{
            .id = @constCast("anthropic/claude-opus-4.8"),
            .provider = "anthropic",
            .capabilities = .{
                .supports_reasoning = true,
                .supports_tool_use = true,
                .supports_vision = true,
                .supports_file_input = true,
                .supports_web_search = true,
                .supports_fast_mode = true,
                .supports_ultrafast_mode = true,
                .context_window = 1_000_000,
                .max_output_tokens = 128_000,
            },
        },
        .{
            .id = @constCast("openai/gpt-5"),
            .provider = "openai",
            .capabilities = .{},
        },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };
    const rows = menuRowCount(projection, 120, 20);
    try std.testing.expectEqual(@as(u16, 4), rows);

    var header = try composeModelMenuRow(alloc, projection, 0, 120, rows);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Models 2") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Anthropic") != null);

    var title = try composeModelMenuRow(alloc, projection, 2, 120, rows);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "anthropic/claude-opus-4.8") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "●") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "○") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "1M context   128K output   Fast mode, Ultrafast mode") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "Anthropic") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Current") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Reasoning") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Vision") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Tools") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Files") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Web") == null);
}

test "model menu keeps active provider visible and omits unknown metadata" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{
            .id = @constCast("private-team-provider/model-with-a-very-long-name"),
            .provider = "private-team-provider",
            .capabilities = .{},
        },
        .{ .id = @constCast("openai/gpt"), .provider = "openai", .capabilities = .{} },
        .{ .id = @constCast("xai/grok"), .provider = "xai", .capabilities = .{} },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
        .provider_index = 5,
    };

    const rows = menuRowCount(projection, 42, 5);
    var header = try composeModelMenuRow(alloc, projection, 0, 42, rows);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "[Others]") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(header.items) <= 42);

    var title = try composeModelMenuRow(alloc, projection, 2, 24, rows);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "unknown") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(title.items) <= 24);
}

test "model menu keeps shared-prefix model ids distinguishable when narrow" {
    const alloc = std.testing.allocator;
    const alpha: model_cache_runtime.ModelMenuItem = .{
        .id = @constCast("provider/very-long-shared-family-production-reasoning-alpha"),
        .provider = "provider",
        .capabilities = .{},
    };
    const beta: model_cache_runtime.ModelMenuItem = .{
        .id = @constCast("provider/very-long-shared-family-production-reasoning-beta"),
        .provider = "provider",
        .capabilities = .{},
    };

    var alpha_row = try composeTitleRow(alloc, alpha, true, null, 40);
    defer alpha_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, alpha_row.items, "provider/very-lo") != null);
    try std.testing.expect(std.mem.find(u8, alpha_row.items, "reasoning-alpha") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(alpha_row.items) <= 40);

    var beta_row = try composeTitleRow(alloc, beta, false, null, 40);
    defer beta_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, beta_row.items, "provider/very-lo") != null);
    try std.testing.expect(std.mem.find(u8, beta_row.items, "reasoning-beta") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(beta_row.items) <= 40);
}

test "model menu states and navigation budget stay bounded" {
    const alloc = std.testing.allocator;
    const loading: ModelMenuProjection = .{ .active = true, .load_state = .loading };
    const rows = menuRowCount(loading, 80, 10);
    try std.testing.expectEqual(@as(u16, 3), rows);
    var state = try composeModelMenuRow(alloc, loading, 2, 80, rows);
    defer state.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, state.items, "Loading models…") != null);

    const empty: ModelMenuProjection = .{ .active = true, .load_state = .ready };
    var empty_state = try composeModelMenuRow(alloc, empty, 2, 80, menuRowCount(empty, 80, 10));
    defer empty_state.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, empty_state.items, "No models available.") != null);

    const failed: ModelMenuProjection = .{ .active = true, .load_state = .failed, .catalog_state = .{ .failure = .{ .category = .transport, .retryable = true } } };
    var failed_state = try composeModelMenuRow(alloc, failed, 2, 80, menuRowCount(failed, 80, 10));
    defer failed_state.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, failed_state.items, "Could not reach AI Gateway; fx retries automatically.") != null);

    const items = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("a/one"), .provider = "a", .capabilities = .{} },
        .{ .id = @constCast("a/two"), .provider = "a", .capabilities = .{} },
        .{ .id = @constCast("a/three"), .provider = "a", .capabilities = .{} },
    };
    const ready: ModelMenuProjection = .{ .active = true, .load_state = .ready, .items = &items };
    try std.testing.expectEqual(@as(u16, 3), visibleNavigationItemsForBudget(ready, 7));
}

test "empty model menu keeps catalog provenance below the empty state" {
    const alloc = std.testing.allocator;
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .catalog_state = .{
            .access_level = .public_only,
            .public_only_reason = .no_credential,
            .private_models_hidden = true,
        },
    };
    const rows = menuRowCount(projection, 80, 10);
    try std.testing.expectEqual(@as(u16, 5), rows);

    var state = try composeModelMenuRow(alloc, projection, 2, 80, rows);
    defer state.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, state.items, "No models available.") != null);

    var gap = try composeModelMenuRow(alloc, projection, 3, 80, rows);
    defer gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), gap.items.len);

    var status = try composeModelMenuRow(alloc, projection, 4, 80, rows);
    defer status.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, status.items, "Using the public model catalog") != null);
}

test "model menu caps inline browse at twenty and prioritizes tiny selection" {
    const alloc = std.testing.allocator;
    var items: [25]model_cache_runtime.ModelMenuItem = undefined;
    for (&items) |*item| {
        item.* = .{
            .id = @constCast("provider/model"),
            .provider = "provider",
            .capabilities = .{},
        };
    }
    items[items.len - 1].id = @constCast("provider/selected-model");
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
        .selected_index = items.len - 1,
    };

    try std.testing.expectEqual(@as(u16, 20), visibleNavigationItemsForBudget(projection, 40));
    try std.testing.expectEqual(@as(u16, 22), menuRowCount(projection, 120, 40));

    var tiny = try composeModelMenuRow(alloc, projection, 0, 40, 1);
    defer tiny.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, tiny.items, "selected-model") != null);
    try std.testing.expect(std.mem.find(u8, tiny.items, "Models") == null);
}

test "model menu places catalog note after an item gap and preserves the heading gap" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("provider/one"), .provider = "provider", .capabilities = .{} },
        .{ .id = @constCast("provider/two"), .provider = "provider", .capabilities = .{} },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
        .catalog_state = .{
            .access_level = .authenticated,
            .source = .ai_gateway_api_key,
        },
    };
    const rows = menuRowCount(projection, 120, 10);
    try std.testing.expectEqual(@as(u16, 6), rows);

    var gap = try composeModelMenuRow(alloc, projection, 1, 120, rows);
    defer gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), gap.items.len);

    var first = try composeModelMenuRow(alloc, projection, 2, 120, rows);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first.items, "provider/one") != null);

    var status_gap = try composeModelMenuRow(alloc, projection, 4, 120, rows);
    defer status_gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), status_gap.items.len);

    var status = try composeModelMenuRow(alloc, projection, 5, 120, rows);
    defer status.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, status.items, "Note: Gateway catalog is authenticated with an API key") != null);
}

test "configured model menu identifies profile settings without Gateway sign-in" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("qwen2.5:0.5b"), .provider = "", .capabilities = .{} },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
        .catalog_state = .{
            .access_level = .public_only,
            .public_only_reason = .no_credential,
            .private_models_hidden = true,
            .from_profile_settings = true,
        },
    };
    const rows = menuRowCount(projection, 120, 10);
    try std.testing.expectEqual(@as(u16, 5), rows);

    var status = try composeModelMenuRow(alloc, projection, rows - 1, 120, rows);
    defer status.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, status.items, "Models from settings and, with fetch_models, the server; explicit model IDs need no catalog.") != null);
    try std.testing.expect(std.mem.find(u8, status.items, "public model catalog") == null);
    try std.testing.expect(std.mem.find(u8, status.items, "sign in") == null);
}

test "model menu status follows provenance and retryable failure precedence" {
    try std.testing.expectEqualStrings(
        "Gateway catalog: authenticated with fx login.",
        loadedCatalogStatusText(.{ .access_level = .authenticated, .source = .fx_login }).?,
    );

    const cases = [_]struct {
        state: model_cache_runtime.ModelMenuCatalogState,
        expected: []const u8,
    }{
        .{ .state = .{ .public_only_reason = .no_credential, .private_models_hidden = true }, .expected = "Using the public model catalog; sign in or use an API key for team-private models." },
        .{ .state = .{ .public_only_reason = .fx_login_team_required, .private_models_hidden = true }, .expected = "Choose a Vercel team to load its private models." },
        .{ .state = .{ .public_only_reason = .fx_login_refresh_required, .private_models_hidden = true }, .expected = "Vercel sign-in must refresh before team-private models can load." },
        .{ .state = .{ .public_only_reason = .credential_refresh_failed, .private_models_hidden = true }, .expected = "Vercel sign-in refresh failed; using the public model catalog." },
        .{ .state = .{ .public_only_reason = .authenticated_credential_rejected, .private_models_hidden = true }, .expected = "Your Gateway credential was rejected; using the public model catalog." },
        .{ .state = .{ .public_only_reason = .chatgpt_subscription, .private_models_hidden = true }, .expected = "Codex models require an authenticated Codex catalog." },
        .{ .state = .{ .public_only_reason = .grok_subscription, .private_models_hidden = true }, .expected = "Grok models require an authenticated Grok catalog." },
        .{ .state = .{ .failure = .{ .category = .transport, .retryable = true } }, .expected = "Could not reach AI Gateway; fx retries automatically." },
        .{ .state = .{ .access_level = .public_only, .public_only_reason = .no_credential, .private_models_hidden = true, .failure = .{ .category = .rate_limited, .retryable = true } }, .expected = "AI Gateway rate limited model discovery; fx retries automatically." },
        .{ .state = .{ .access_level = .authenticated, .failure = .{ .category = .rate_limited, .retryable = true } }, .expected = "AI Gateway rate limited model discovery; fx retries automatically." },
        .{ .state = .{ .access_level = .authenticated, .failure = .{ .category = .runtime, .retryable = true } }, .expected = "Could not refresh model catalog; fx retries automatically." },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, loadedCatalogStatusText(case.state).?);
    }
}

test "model menu header shows only vendor filters represented by the catalog" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("anthropic/claude"), .provider = "anthropic", .capabilities = .{} },
        .{ .id = @constCast("openai/gpt"), .provider = "openai", .capabilities = .{} },
        .{ .id = @constCast("deepseek/v3"), .provider = "deepseek", .capabilities = .{} },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };

    var header = try composeModelMenuRow(alloc, projection, 0, 60, 3);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Anthropic") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "OpenAI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Others") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "xAI") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "Z.AI") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "…") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "Provider ") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(header.items) <= 60);
}

test "model menu header hides redundant vendor filters for a single-vendor catalog" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("gpt-5.6-sol"), .provider = "", .capabilities = .{} },
        .{ .id = @constCast("gpt-5.4-mini"), .provider = "", .capabilities = .{} },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };

    var header = try composeModelMenuRow(alloc, projection, 0, 120, 3);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Anthropic") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "OpenAI") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "xAI") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "Z.AI") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "Others") == null);
}

test "model menu facts share a left-aligned column" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{
            .id = @constCast("tiny-provider/model"),
            .provider = "tiny-provider",
            .capabilities = .{ .context_window = 1_000_000 },
        },
        .{
            .id = @constCast("much-longer-provider/model"),
            .provider = "much-longer-provider",
            .capabilities = .{ .context_window = 256_000, .max_output_tokens = 128_000 },
        },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };
    const rows = menuRowCount(projection, 80, 20);

    var first = try composeModelMenuRow(alloc, projection, 2, 80, rows);
    defer first.deinit(alloc);
    var second = try composeModelMenuRow(alloc, projection, 3, 80, rows);
    defer second.deinit(alloc);

    // The column starts three cells after the longest id, and numbers align
    // on the right, so `1M` sits under the `6K` of `256K`.
    const expected_column = 2 + display_width.visibleWidth("much-longer-provider/model") + fact_gap;
    const first_label = std.mem.find(u8, first.items, "1M context").?;
    const second_label = std.mem.find(u8, second.items, "256K context").?;
    try std.testing.expectEqual(expected_column + 2, display_width.visibleWidthIgnoringAnsi(first.items[0..first_label]));
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(second.items[0..second_label]));
    // A model without an output limit ends at its context cell, with no padding.
    try std.testing.expect(std.mem.endsWith(u8, first.items, "1M context" ++ "\x1b[0m"));

    const wide_rows = menuRowCount(projection, 160, 20);
    var wide = try composeModelMenuRow(alloc, projection, 3, 160, wide_rows);
    defer wide.deinit(alloc);
    const wide_label = std.mem.find(u8, wide.items, "256K context").?;
    try std.testing.expectEqual(expected_column, display_width.visibleWidthIgnoringAnsi(wide.items[0..wide_label]));
}

test "model menu writes token counts the way providers do" {
    const cases = [_]struct { tokens: u32, text: []const u8 }{
        .{ .tokens = 999, .text = "999" },
        .{ .tokens = 1024, .text = "1K" },
        .{ .tokens = 8192, .text = "8K" },
        .{ .tokens = 32_768, .text = "32K" },
        .{ .tokens = 131_072, .text = "128K" },
        .{ .tokens = 262_144, .text = "256K" },
        .{ .tokens = 1_048_576, .text = "1M" },
        .{ .tokens = 1_572_864, .text = "1.5M" },
        .{ .tokens = 128_000, .text = "128K" },
        .{ .tokens = 131_000, .text = "131K" },
        .{ .tokens = 202_800, .text = "203K" },
        .{ .tokens = 999_999, .text = "1M" },
        .{ .tokens = 1_000_000, .text = "1M" },
        .{ .tokens = 1_050_000, .text = "1.05M" },
        .{ .tokens = 2_000_000, .text = "2M" },
    };
    for (cases) |case| {
        var buf: [16]u8 = undefined;
        try std.testing.expectEqualStrings(case.text, try formatTokenCount(&buf, case.tokens));
    }
}

test "model menu keeps only compact facts beside the model" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{.{
        .id = @constCast("anthropic/claude-opus-4.8"),
        .provider = "anthropic",
        .capabilities = .{
            .context_window = 1_000_000,
            .max_output_tokens = 128_000,
            .supports_reasoning = true,
            .supports_fast_mode = true,
            .supports_vision = true,
            .supports_tool_use = true,
        },
    }};
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };
    const rows = menuRowCount(projection, 100, 20);
    try std.testing.expectEqual(@as(u16, 3), rows);

    var title = try composeModelMenuRow(alloc, projection, 2, 100, rows);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "anthropic/claude-opus-4.8") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "1M context   128K output   Fast mode") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "Anthropic") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Current") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Reasoning") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Vision") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Tools") == null);
}

test "model menu labels -fast models Fast and models that offer Fast mode as Fast mode" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{
            .id = @constCast("anthropic/claude-opus-4.8"),
            .provider = "anthropic",
            .capabilities = model_capabilities.resolveCapabilities(
                "anthropic/claude-opus-4.8",
                .{ .supports_fast_mode = true, .context_window = 1_000_000 },
            ),
        },
        .{
            .id = @constCast("anthropic/claude-opus-4.8-fast"),
            .provider = "anthropic",
            .capabilities = model_capabilities.resolveCapabilities(
                "anthropic/claude-opus-4.8-fast",
                .{ .context_window = 1_000_000 },
            ),
        },
        .{
            .id = @constCast("xai/grok-4.7-fast"),
            .provider = "xai",
            .capabilities = model_capabilities.resolveCapabilities(
                "xai/grok-4.7-fast",
                .{ .supports_fast_mode = true, .context_window = 1_000_000 },
            ),
        },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };
    const rows = menuRowCount(projection, 100, 20);

    var regular = try composeModelMenuRow(alloc, projection, 2, 100, rows);
    defer regular.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, regular.items, "1M context   Fast mode") != null);

    var always_fast = try composeModelMenuRow(alloc, projection, 3, 100, rows);
    defer always_fast.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, always_fast.items, "anthropic/claude-opus-4.8-fast") != null);
    try std.testing.expect(std.mem.find(u8, always_fast.items, "1M context   Fast") != null);
    try std.testing.expect(std.mem.find(u8, always_fast.items, "Fast mode") == null);

    var fast_with_option = try composeModelMenuRow(alloc, projection, 4, 100, rows);
    defer fast_with_option.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, fast_with_option.items, "xai/grok-4.7-fast") != null);
    try std.testing.expect(std.mem.find(u8, fast_with_option.items, "1M context   Fast, Fast mode") != null);
}

test "model menu tags Token Pass models for a team with Token Pass and leaves their Fast mode out" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{
            .id = @constCast("zai/glm-5.3"),
            .provider = "zai",
            .capabilities = .{ .context_window = 200_000, .supports_fast_mode = true },
        },
        .{
            .id = @constCast("zai/glm-5.3-fast"),
            .provider = "zai",
            .capabilities = .{ .context_window = 200_000 },
        },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
        .token_pass = true,
    };
    const rows = menuRowCount(projection, 100, 20);
    try std.testing.expectEqual(@as(u16, 7), rows);

    // Under the Token Pass heading the rows leave the tag out, and Fast mode
    // too, since Token Pass credit does not pay for it.
    var featured = try composeModelMenuRow(alloc, projection, 3, 100, rows);
    defer featured.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, featured.items, "zai/glm-5.3") != null);
    try std.testing.expect(std.mem.find(u8, featured.items, "200K context") != null);
    try std.testing.expect(std.mem.find(u8, featured.items, "Fast mode") == null);
    try std.testing.expect(std.mem.find(u8, featured.items, "Token Pass") == null);

    var other = try composeModelMenuRow(alloc, projection, 6, 100, rows);
    defer other.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, other.items, "zai/glm-5.3-fast") != null);
    try std.testing.expect(std.mem.find(u8, other.items, "Token Pass") == null);

    // A search has no headings, so the tag gets its own column, and the
    // other model's facts still line up after the empty tag cell.
    var searched = projection;
    searched.query = "glm";
    const searched_rows = menuRowCount(searched, 100, 20);
    var tagged = try composeModelMenuRow(alloc, searched, 2, 100, searched_rows);
    defer tagged.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, tagged.items, "Token Pass   200K context") != null);
    try std.testing.expect(std.mem.find(u8, tagged.items, "Fast mode") == null);
    var untagged = try composeModelMenuRow(alloc, searched, 3, 100, searched_rows);
    defer untagged.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, untagged.items, "zai/glm-5.3-fast") != null);
    try std.testing.expect(std.mem.find(u8, untagged.items, "Token Pass") == null);
    try std.testing.expectEqual(
        display_width.visibleWidthIgnoringAnsi(tagged.items[0..std.mem.find(u8, tagged.items, "200K context").?]),
        display_width.visibleWidthIgnoringAnsi(untagged.items[0..std.mem.find(u8, untagged.items, "200K context").?]),
    );
}

/// Draws every row of the menu into a VT grid of `width` columns, as the
/// terminal would show it.
fn renderMenuGrid(alloc: Allocator, projection: ModelMenuProjection, width: u16, max_rows: u16) !vt_emulator.Grid {
    const rows = menuRowCount(projection, width, max_rows);
    var grid = try vt_emulator.Grid.init(alloc, width, @max(rows, 1));
    errdefer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeModelMenuRow(alloc, projection, row_index, width, rows);
        defer row.deinit(alloc);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{row_index + 1}));
        try grid.feed(row.items);
    }
    return grid;
}

/// The cell where `needle` starts on grid row `row`, or null.
fn gridColumnOf(alloc: Allocator, grid: *vt_emulator.Grid, row: u16, needle: []const u8) !?usize {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try grid.rowTextTrimmed(row, &text);
    const at = std.mem.find(u8, text.items, needle) orelse return null;
    return display_width.visibleWidth(text.items[0..at]);
}

const column_test_items = [_]model_cache_runtime.ModelMenuItem{
    .{ .id = @constCast("moonshotai/kimi-k3"), .provider = "moonshotai", .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 131_072, .supports_fast_mode = true } },
    .{ .id = @constCast("zai/glm-5.3-flash"), .provider = "zai", .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 131_000 } },
    .{ .id = @constCast("openai/gpt-6.1-terra"), .provider = "openai", .capabilities = .{ .context_window = 1_050_000, .max_output_tokens = 128_000, .supports_fast_mode = true } },
    .{ .id = @constCast("amazon/nova-pro"), .provider = "amazon", .capabilities = .{ .context_window = 300_000, .max_output_tokens = 8_192 } },
    .{ .id = @constCast("anthropic/claude-opus-5.5-fast"), .provider = "anthropic", .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 128_000, .intrinsic_fast = true } },
};

test "model menu facts line up in columns through the VT and drop whole columns as the terminal narrows" {
    const alloc = std.testing.allocator;
    const projection: ModelMenuProjection = .{ .active = true, .load_state = .ready, .items = &column_test_items, .token_pass = true };
    // Grid rows: 1 header, 2 gap, 3 Token Pass heading, 4-5 its models, 6 gap,
    // 7 All Models heading, 8-10 the rest.
    const model_rows = [_]u16{ 4, 5, 8, 9, 10 };
    const cases = [_]struct { width: u16, context: bool, output: bool, speed: bool }{
        .{ .width = 120, .context = true, .output = true, .speed = true },
        .{ .width = 80, .context = true, .output = true, .speed = true },
        .{ .width = 64, .context = true, .output = true, .speed = true },
        .{ .width = 56, .context = true, .output = true, .speed = false },
        .{ .width = 44, .context = true, .output = false, .speed = false },
        .{ .width = 30, .context = false, .output = false, .speed = false },
    };
    for (cases) |case| {
        var grid = try renderMenuGrid(alloc, projection, case.width, 20);
        defer grid.deinit();
        try std.testing.expectEqual(@as(?usize, 2), try gridColumnOf(alloc, &grid, 3, "Token Pass"));
        try std.testing.expectEqual(@as(?usize, 2), try gridColumnOf(alloc, &grid, 7, "All Models"));

        // Every label sits in one column down the list, whatever the number
        // before it, and a dropped column leaves no trace.
        var context_column: ?usize = null;
        var output_column: ?usize = null;
        for (model_rows) |row| {
            const context = try gridColumnOf(alloc, &grid, row, " context");
            try std.testing.expectEqual(case.context, context != null);
            if (context) |column| {
                if (context_column) |expected| try std.testing.expectEqual(expected, column);
                context_column = column;
            }
            const output = try gridColumnOf(alloc, &grid, row, " output");
            if (!case.output) try std.testing.expect(output == null);
            if (output) |column| {
                if (output_column) |expected| try std.testing.expectEqual(expected, column);
                output_column = column;
            }
        }
        try std.testing.expectEqual(case.output, output_column != null);
        try std.testing.expectEqual(case.speed, (try gridColumnOf(alloc, &grid, 8, "Fast mode")) != null);
        if (case.speed) {
            try std.testing.expectEqual(try gridColumnOf(alloc, &grid, 8, "Fast mode"), try gridColumnOf(alloc, &grid, 10, "Fast"));
        }
        // The Token Pass model that offers Fast mode leaves it out.
        try std.testing.expect((try gridColumnOf(alloc, &grid, 4, "Fast")) == null);
    }

    // At 120 columns the cells read as the design shows them.
    var wide = try renderMenuGrid(alloc, projection, 120, 20);
    defer wide.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    const expected = [_]struct { row: u16, text: []const u8 }{
        .{ .row = 4, .text = "moonshotai/kimi-k3                  1M context   128K output" },
        .{ .row = 5, .text = "zai/glm-5.3-flash                   1M context   131K output" },
        .{ .row = 8, .text = "openai/gpt-6.1-terra             1.05M context   128K output   Fast mode" },
        .{ .row = 9, .text = "amazon/nova-pro                   300K context     8K output" },
        .{ .row = 10, .text = "anthropic/claude-opus-5.5-fast      1M context   128K output   Fast" },
    };
    for (expected) |line| {
        text.clearRetainingCapacity();
        try wide.rowTextTrimmed(line.row, &text);
        try std.testing.expectEqualStrings(line.text, std.mem.trimStart(u8, text.items, " "));
    }
}

test "model menu fits a short terminal and keeps the Token Pass tag when a search narrows the row" {
    const alloc = std.testing.allocator;
    var projection: ModelMenuProjection = .{ .active = true, .load_state = .ready, .items = &column_test_items, .token_pass = true };

    // Too few rows for headings and two models: a plain list that still
    // shows the selection.
    for ([_]u16{ 1, 2, 3, 6 }) |max_rows| {
        projection.selected_index = column_test_items.len - 1;
        const rows = menuRowCount(projection, 60, max_rows);
        try std.testing.expect(rows <= max_rows);
        var grid = try renderMenuGrid(alloc, projection, 60, max_rows);
        defer grid.deinit();
        var found = false;
        var row: u16 = 1;
        while (row <= rows) : (row += 1) {
            // The tag column can leave the id too little room, so match the
            // end of the id, which its middle ellipsis keeps.
            if ((try gridColumnOf(alloc, &grid, row, "5.5-fast")) != null) found = true;
            try std.testing.expect((try gridColumnOf(alloc, &grid, row, "All Models")) == null);
        }
        try std.testing.expect(found);
    }

    // A search drops the headings; on a narrow terminal the tag outlasts the
    // other facts, so a Token Pass model stays marked.
    projection.selected_index = 0;
    projection.query = "a";
    var narrow = try renderMenuGrid(alloc, projection, 40, 20);
    defer narrow.deinit();
    const kimi_row: u16 = for (3..8) |row| {
        if ((try gridColumnOf(alloc, &narrow, @intCast(row), "kimi-k3")) != null) break @intCast(row);
    } else return error.TestUnexpectedResult;
    try std.testing.expect((try gridColumnOf(alloc, &narrow, kimi_row, "Token Pass")) != null);
    try std.testing.expect((try gridColumnOf(alloc, &narrow, kimi_row, " context")) == null);
}

test "model menu groups Token Pass models under their own heading until a search ranks the list" {
    const alloc = std.testing.allocator;
    var items: [13]model_cache_runtime.ModelMenuItem = undefined;
    var ids: [10][16]u8 = undefined;
    for (&items, 0..) |*item, index| {
        const id: []u8 = switch (index) {
            0 => @constCast("moonshotai/kimi-k3"),
            1 => @constCast("zai/glm-5.3"),
            2 => @constCast("zai/glm-5.3-flash"),
            else => try std.mem.print(&ids[index - 3], "acme/model-{d:0>2}", .{index - 3}),
        };
        item.* = .{ .id = id, .provider = "other", .capabilities = .{} };
    }
    var projection: ModelMenuProjection = .{ .active = true, .load_state = .ready, .items = &items, .token_pass = true };

    // Header, gap, then the Token Pass group, a gap, and every other model.
    const all_rows = menuRowCount(projection, 100, 40);
    try std.testing.expectEqual(@as(u16, 2 + 13 + group_heading_rows), all_rows);
    const expected = [_]?[]const u8{ null, null, "Token Pass", "moonshotai/kimi-k3", "zai/glm-5.3", "zai/glm-5.3-flash", null, "All Models", "acme/model-00" };
    for (expected, 0..) |text, index| {
        var row = try composeModelMenuRow(alloc, projection, @intCast(index), 100, all_rows);
        defer row.deinit(alloc);
        if (index == 0) continue;
        if (text) |needle| {
            try std.testing.expect(std.mem.find(u8, row.items, needle) != null);
        } else {
            try std.testing.expectEqual(@as(usize, 0), row.items.len);
        }
    }
    for ([_]struct { row: u16, name: []const u8, count: []const u8 }{
        .{ .row = 2, .name = ui_render.bold_style ++ "Token Pass", .count = "3" },
        .{ .row = 7, .name = ui_render.bold_style ++ "All Models", .count = "10" },
    }) |heading| {
        var row = try composeModelMenuRow(alloc, projection, heading.row, 100, all_rows);
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, heading.name) != null);
        const count = try std.mem.concat(alloc, u8, &.{ ui_render.dim_style, heading.count, ui_render.reset_style });
        defer alloc.free(count);
        try std.testing.expect(std.mem.find(u8, row.items, count) != null);
    }

    // A short menu keeps the same height and pages by the models it shows,
    // and the last model stays in view below the headings.
    const short_rows = menuRowCount(projection, 100, 9);
    try std.testing.expectEqual(@as(u16, 9), short_rows);
    try std.testing.expectEqual(@as(u16, 4), visibleNavigationItemsForBudget(projection, 9));
    projection.selected_index = 12;
    try std.testing.expectEqual(short_rows, menuRowCount(projection, 100, 9));
    var last = try composeModelMenuRow(alloc, projection, short_rows - 1, 100, short_rows);
    defer last.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, last.items, "acme/model-09") != null);
    try std.testing.expect(std.mem.find(u8, last.items, ui_render.selected_completion_style) != null);

    // A search ranks models by match, so the list has no headings.
    projection.selected_index = 0;
    projection.query = "a";
    const searched_rows = menuRowCount(projection, 100, 40);
    try std.testing.expectEqual(@as(u16, 2 + 13), searched_rows);
    var first = try composeModelMenuRow(alloc, projection, 2, 100, searched_rows);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first.items, "/") != null);
}

test "model menu for a team without Token Pass shows no Token Pass heading or tag and keeps Fast mode" {
    const alloc = std.testing.allocator;
    var projection: ModelMenuProjection = .{ .active = true, .load_state = .ready, .items = &column_test_items };

    // Header, gap, then the models as the catalog lists them.
    const rows = menuRowCount(projection, 120, 20);
    try std.testing.expectEqual(@as(u16, 2 + column_test_items.len), rows);
    var grid = try renderMenuGrid(alloc, projection, 120, 20);
    defer grid.deinit();
    var row: u16 = 1;
    while (row <= rows) : (row += 1) {
        try std.testing.expect((try gridColumnOf(alloc, &grid, row, "Token Pass")) == null);
        try std.testing.expect((try gridColumnOf(alloc, &grid, row, "All Models")) == null);
    }
    // Grid rows: 1 header, 2 gap, 3 the first model.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try grid.rowTextTrimmed(3, &text);
    try std.testing.expectEqualStrings(
        "moonshotai/kimi-k3                  1M context   128K output   Fast mode",
        std.mem.trimStart(u8, text.items, " "),
    );

    // A search has no tag column either.
    projection.query = "kimi";
    var searched = try renderMenuGrid(alloc, projection, 120, 20);
    defer searched.deinit();
    text.clearRetainingCapacity();
    try searched.rowTextTrimmed(3, &text);
    try std.testing.expect(std.mem.find(u8, text.items, "kimi-k3") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "Token Pass") == null);
    try std.testing.expect(std.mem.find(u8, text.items, "1M context   128K output   Fast mode") != null);
}

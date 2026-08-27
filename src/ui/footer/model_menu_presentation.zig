const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
const model_capabilities = @import("../../core/config/model_capabilities.zig");
const ui_render = @import("../render.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const ModelMenuProjection = render_input.ModelMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const item_rows: u16 = 1;

const ModelMenuLayout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    visible_items: u16 = 0,
    first_item_row: u16 = header_rows,
    item_stride: u16 = item_rows,
    row_count: u16 = 0,

    fn build(projection: ModelMenuProjection, row_budget: u16) ModelMenuLayout {
        if (row_budget == 0) return .{};

        const match_count = projection.filteredItemCount();
        const selected = if (match_count > 0) projection.selected_index % match_count else 0;
        if (projection.load_state != .ready or match_count == 0) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .row_count = @min(row_budget, header_rows + roomy_top_gap_rows + 1),
            };
        }
        if (row_budget == 1) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .row_count = 1,
            };
        }
        if (row_budget == 2) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 1,
                .row_count = 2,
            };
        }
        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_budget = row_budget - first_item_row;
        const visible_items: u16 = @intCast(@min(match_count, @max(item_budget, 1)));
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .first_item_row = first_item_row,
            .item_stride = item_rows,
            .row_count = first_item_row + visible_items,
        };
    }
};

pub fn menuRowCount(projection: ModelMenuProjection, _: u16, max_rows: u16) u16 {
    return ModelMenuLayout.build(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(projection: ModelMenuProjection, row_budget: u16) u16 {
    return ModelMenuLayout.build(projection, row_budget).visible_items;
}

pub fn composeModelMenuRow(
    alloc: Allocator,
    projection: ModelMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return row;
    if (row_index == 0) return composeHeaderRow(alloc, projection, width);

    const layout = ModelMenuLayout.build(projection, row_count);
    if (projection.load_state == .ready and row_index == header_rows and row_index < layout.row_count - 1) {
        const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
        return composeDimmedRow(alloc, text, width);
    }
    if (projection.load_state != .ready or layout.match_count == 0) {
        if (row_index < layout.row_count -| 1) return row;
        return composeStateRow(alloc, projection, width);
    }
    if (row_index < layout.first_item_row) return row;

    const body_offset = row_index - layout.first_item_row;
    const visible_offset = body_offset / layout.item_stride;
    if (visible_offset >= layout.visible_items) return row;
    const item_row = body_offset % layout.item_stride;
    const window_start = list_window.updateEdgeStart(
        projection.window_start,
        layout.match_count,
        layout.selected,
        layout.visible_items,
    );
    const display_index = window_start + visible_offset;
    const item = projection.itemAt(display_index) orelse return row;

    if (item_row == 0) {
        return composeTitleRow(
            alloc,
            item.*,
            display_index == layout.selected,
            modelFactsColumn(projection, width),
            width,
        );
    }
    return row;
}

fn composeHeaderRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try appendHeaderTitle(alloc, &row, projection.filteredItemCount());

    const tab_count = model_cache_runtime.model_provider_filter_count;
    const active_index = @min(projection.provider_index, tab_count - 1);
    const title_width = display_width.visibleWidthIgnoringAnsi(row.items);
    if (title_width + 2 + providerTabWidth(active_index, active_index) > width) {
        try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, active_index, active_index);
        return cloneClippedRow(alloc, row.items, width);
    }

    var start = active_index;
    var end = active_index + 1;
    while (true) {
        var expanded = false;
        if (end < tab_count and title_width + 2 + providerRangeWidth(start, end + 1, active_index) <= width) {
            end += 1;
            expanded = true;
        }
        if (start > 0 and title_width + 2 + providerRangeWidth(start - 1, end, active_index) <= width) {
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
    for (start..end) |index| {
        if (index > start) try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, index, active_index);
    }
    if (end < tab_count) {
        try row.appendSlice(alloc, "  ");
        try appendProviderOverflowMarker(alloc, &row);
    }
    return cloneClippedRow(alloc, row.items, width);
}

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Models {d}", .{count}) catch "Models";
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
    const filter: model_cache_runtime.ModelProviderFilter = @enumFromInt(index);
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
    start: usize,
    end: usize,
    active_index: usize,
) usize {
    var width: usize = if (start > 0) 3 else 0;
    for (start..end) |index| {
        if (index > start) width += 2;
        width += providerTabWidth(index, active_index);
    }
    if (end < model_cache_runtime.model_provider_filter_count) width += 3;
    return width;
}

fn modelFactsColumn(projection: ModelMenuProjection, width: u16) ?usize {
    const indent_width: usize = if (width <= 2) 0 else 2;
    const content_width: usize = width;
    var facts_width: usize = 0;
    for (projection.items) |item| {
        facts_width = @max(facts_width, compactFactsWidth(item.capabilities));
    }
    if (facts_width == 0 or content_width < indent_width + 8 + 2 + facts_width) return null;
    return content_width - facts_width;
}

fn composeTitleRow(
    alloc: Allocator,
    item: model_cache_runtime.ModelMenuItem,
    selected: bool,
    facts_column: ?usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent_width: u16 = if (width <= 2) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(alloc);
    try appendCompactFacts(alloc, &facts, item.capabilities);

    const prefix_width = display_width.visibleWidthIgnoringAnsi(row.items);
    const content_width = @as(usize, width);
    const facts_start = facts_column orelse content_width;
    const show_facts = facts.items.len > 0 and facts_start >= prefix_width + 8 + 2;
    const id_budget = if (show_facts) facts_start - prefix_width - 2 else content_width -| prefix_width;
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, item.id, id_budget);
    if (selected) try row.appendSlice(alloc, ui_render.reset_style);

    if (show_facts) {
        try row_text.appendSpacesToColumn(alloc, &row, facts_start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, facts.items, content_width - facts_start);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn appendCompactFacts(
    alloc: Allocator,
    facts: *std.ArrayList(u8),
    capabilities: model_capabilities.Capabilities,
) !void {
    if (capabilities.context_window) |tokens| try appendTokenFact(alloc, facts, tokens, "context");
    if (capabilities.max_output_tokens) |tokens| try appendTokenFact(alloc, facts, tokens, "output");
    if (capabilities.supports_fast_mode) try appendMetadataFact(alloc, facts, "Fast");
}

fn compactFactsWidth(capabilities: model_capabilities.Capabilities) usize {
    var width: usize = 0;
    if (capabilities.context_window) |tokens| {
        if (width > 0) width += display_width.visibleWidth(" · ");
        width += tokenFactWidth(tokens, "context");
    }
    if (capabilities.max_output_tokens) |tokens| {
        if (width > 0) width += display_width.visibleWidth(" · ");
        width += tokenFactWidth(tokens, "output");
    }
    if (capabilities.supports_fast_mode) {
        if (width > 0) width += display_width.visibleWidth(" · ");
        width += display_width.visibleWidth("Fast");
    }
    return width;
}

fn appendTokenFact(alloc: Allocator, text: *std.ArrayList(u8), tokens: u32, suffix: []const u8) !void {
    var buf: [48]u8 = undefined;
    const label = try formatTokenFact(&buf, tokens, suffix);
    try appendMetadataFact(alloc, text, label);
}

fn tokenFactWidth(tokens: u32, suffix: []const u8) usize {
    var buf: [48]u8 = undefined;
    const label = formatTokenFact(&buf, tokens, suffix) catch return 0;
    return display_width.visibleWidth(label);
}

fn formatTokenFact(buf: *[48]u8, tokens: u32, suffix: []const u8) ![]const u8 {
    if (tokens >= 1_000_000 and tokens % 1_000_000 == 0) {
        return try std.fmt.bufPrint(buf, "{d}M {s}", .{ tokens / 1_000_000, suffix });
    }
    if (tokens >= 1_000 and tokens % 1_000 == 0) {
        return try std.fmt.bufPrint(buf, "{d}K {s}", .{ tokens / 1_000, suffix });
    }
    return try std.fmt.bufPrint(buf, "{d} {s}", .{ tokens, suffix });
}

fn appendMetadataFact(alloc: Allocator, text: *std.ArrayList(u8), fact: []const u8) !void {
    if (text.items.len > 0) try text.appendSlice(alloc, " · ");
    try text.appendSlice(alloc, fact);
}

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
    if (state.private_models_hidden) {
        const reason = state.public_only_reason orelse return "Using the public model catalog.";
        return switch (reason) {
            .no_credential => "Using the public model catalog; sign in or use an API key for team-private models.",
            .fx_login_team_required => "Choose a Vercel team to load its private models.",
            .fx_login_refresh_required => "Vercel sign-in must refresh before team-private models can load.",
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
            .ai_gateway_api_key => "Gateway catalog: authenticated with an API key.",
            .vercel_oidc_token => "Gateway catalog: authenticated with the Vercel session.",
            .stored_key => "Gateway catalog: authenticated with the stored API key.",
            .chatgpt_subscription => "Codex catalog: authenticated with a subscription.",
            .grok_subscription => "Grok catalog: authenticated with a subscription.",
        };
    }
    return null;
}

fn retryableFailureText(failure: ?model_cache_runtime.ModelMenuCatalogState.Failure) ?[]const u8 {
    const value = failure orelse return null;
    if (!value.retryable) return null;
    return switch (value.category) {
        .rate_limited => "AI Gateway rate limited model discovery; retry /models.",
        .transport, .gateway_unavailable => "Could not reach AI Gateway; retry /models.",
        else => "Could not refresh model catalog; retry /models.",
    };
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
    try std.testing.expect(std.mem.find(u8, title.items, "1M context · 128K output · Fast") != null);
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
    const items = [_]model_cache_runtime.ModelMenuItem{.{
        .id = @constCast("private-team-provider/model-with-a-very-long-name"),
        .provider = "private-team-provider",
        .capabilities = .{},
    }};
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
    try std.testing.expect(std.mem.find(u8, failed_state.items, "Could not reach AI Gateway; retry /models.") != null);

    const items = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("a/one"), .provider = "a", .capabilities = .{} },
        .{ .id = @constCast("a/two"), .provider = "a", .capabilities = .{} },
        .{ .id = @constCast("a/three"), .provider = "a", .capabilities = .{} },
    };
    const ready: ModelMenuProjection = .{ .active = true, .load_state = .ready, .items = &items };
    try std.testing.expectEqual(@as(u16, 3), visibleNavigationItemsForBudget(ready, 7));
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
        .{ .state = .{ .failure = .{ .category = .transport, .retryable = true } }, .expected = "Could not reach AI Gateway; retry /models." },
        .{ .state = .{ .access_level = .public_only, .public_only_reason = .no_credential, .private_models_hidden = true, .failure = .{ .category = .rate_limited, .retryable = true } }, .expected = "AI Gateway rate limited model discovery; retry /models." },
        .{ .state = .{ .access_level = .authenticated, .failure = .{ .category = .rate_limited, .retryable = true } }, .expected = "AI Gateway rate limited model discovery; retry /models." },
        .{ .state = .{ .access_level = .authenticated, .failure = .{ .category = .runtime, .retryable = true } }, .expected = "Could not refresh model catalog; retry /models." },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, loadedCatalogStatusText(case.state).?);
    }
}

test "model menu fixed provider tabs fit a typical terminal width" {
    const alloc = std.testing.allocator;
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
    };

    var header = try composeModelMenuRow(alloc, projection, 0, 60, 1);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Anthropic") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "OpenAI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "xAI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Z.AI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Others") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "…") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "Provider ") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(header.items) <= 60);
}

test "model menu header groups secondary providers under Others" {
    const alloc = std.testing.allocator;
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
    };

    var header = try composeModelMenuRow(alloc, projection, 0, 120, 1);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Anthropic") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "OpenAI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "xAI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Z.AI") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Others") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "deepseek") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "minimax") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "alibaba") == null);
    try std.testing.expect(std.mem.find(u8, header.items, "amazon") == null);
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

    const first_label = std.mem.find(u8, first.items, "1M context").?;
    const second_label = std.mem.find(u8, second.items, "256K context").?;
    try std.testing.expectEqual(
        display_width.visibleWidthIgnoringAnsi(first.items[0..first_label]),
        display_width.visibleWidthIgnoringAnsi(second.items[0..second_label]),
    );
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
    try std.testing.expect(std.mem.find(u8, title.items, "1M context · 128K output · Fast") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "Anthropic") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Current") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Reasoning") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Vision") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Tools") == null);
}

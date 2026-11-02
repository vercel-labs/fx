const std = @import("std");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

pub fn gridCellsEqual(
    left_grid: vt_emulator.Grid,
    left: vt_emulator.Cell,
    right_grid: vt_emulator.Grid,
    right: vt_emulator.Cell,
) bool {
    if (!baseCellsEqual(left.codepoint, left.width, left.style, right.codepoint, right.width, right.style)) {
        return false;
    }
    if (!resourceIdsMatchByBytes(
        left.combining_suffix_id,
        right.combining_suffix_id,
        if (left.combining_suffix_id == 0) null else left_grid.combiningSuffix(left.combining_suffix_id),
        if (right.combining_suffix_id == 0) null else right_grid.combiningSuffix(right.combining_suffix_id),
    )) {
        return false;
    }
    return resourceIdsMatchByBytes(
        left.style.hyperlink_id,
        right.style.hyperlink_id,
        if (left.style.hyperlink_id == 0) null else left_grid.hyperlinkUrl(left.style.hyperlink_id),
        if (right.style.hyperlink_id == 0) null else right_grid.hyperlinkUrl(right.style.hyperlink_id),
    ) and resourceIdsMatchByBytes(
        left.style.hyperlink_id,
        right.style.hyperlink_id,
        if (left.style.hyperlink_id == 0) null else left_grid.hyperlinkParams(left.style.hyperlink_id),
        if (right.style.hyperlink_id == 0) null else right_grid.hyperlinkParams(right.style.hyperlink_id),
    );
}

pub fn gridSurfaceCellsEqual(
    grid: vt_emulator.Grid,
    grid_cell: vt_emulator.Cell,
    surface: frame_surface.FrameSurface,
    surface_cell: frame_surface.FrameCell,
) bool {
    if (!baseCellsEqual(
        grid_cell.codepoint,
        grid_cell.width,
        grid_cell.style,
        surface_cell.codepoint,
        surface_cell.width,
        surface_cell.style,
    )) {
        return false;
    }
    if (!resourceIdsMatchByBytes(
        grid_cell.combining_suffix_id,
        surface_cell.combining_suffix_id,
        if (grid_cell.combining_suffix_id == 0) null else grid.combiningSuffix(grid_cell.combining_suffix_id),
        if (surface_cell.combining_suffix_id == 0) null else surface.combiningSuffix(surface_cell.combining_suffix_id),
    )) {
        return false;
    }
    return resourceIdsMatchByBytes(
        grid_cell.style.hyperlink_id,
        surface_cell.style.hyperlink_id,
        if (grid_cell.style.hyperlink_id == 0) null else grid.hyperlinkUrl(grid_cell.style.hyperlink_id),
        if (surface_cell.style.hyperlink_id == 0) null else surface.hyperlinkUrl(surface_cell.style.hyperlink_id),
    ) and resourceIdsMatchByBytes(
        grid_cell.style.hyperlink_id,
        surface_cell.style.hyperlink_id,
        if (grid_cell.style.hyperlink_id == 0) null else grid.hyperlinkParams(grid_cell.style.hyperlink_id),
        if (surface_cell.style.hyperlink_id == 0) null else surface.hyperlinkParams(surface_cell.style.hyperlink_id),
    );
}

fn baseCellsEqual(
    left_codepoint: u21,
    left_width: u8,
    left_style: vt_emulator.Style,
    right_codepoint: u21,
    right_width: u8,
    right_style: vt_emulator.Style,
) bool {
    return left_codepoint == right_codepoint and
        left_width == right_width and
        left_style.fg.eql(right_style.fg) and
        left_style.bg.eql(right_style.bg) and
        left_style.flags.eql(right_style.flags);
}

fn resourceIdsMatchByBytes(
    left_id: u32,
    right_id: u32,
    left_bytes: ?[]const u8,
    right_bytes: ?[]const u8,
) bool {
    if (left_id == 0 or right_id == 0) return left_id == right_id;
    const left = left_bytes orelse return false;
    const right = right_bytes orelse return false;
    return std.mem.eql(u8, left, right);
}

test "grid cell comparison resolves hyperlink URI instead of numeric id" {
    var left = try vt_emulator.Grid.init(std.testing.allocator, 8, 2);
    defer left.deinit();
    try left.feed("\x1b]8;;https://unused.example\x1b\\\x1b]8;;\x1b\\");
    try left.feed("\x1b[1;1H\x1b]8;;https://same.example\x1b\\X\x1b]8;;\x1b\\");

    var right = try vt_emulator.Grid.init(std.testing.allocator, 8, 2);
    defer right.deinit();
    try right.feed("\x1b]8;;https://same.example\x1b\\X\x1b]8;;\x1b\\");
    try right.feed("\x1b]8;;https://unused.example\x1b\\\x1b]8;;\x1b\\");

    const left_cell = left.cellAt(1, 1).?;
    const right_cell = right.cellAt(1, 1).?;
    try std.testing.expectEqual(@as(u32, 2), left_cell.style.hyperlink_id);
    try std.testing.expectEqual(@as(u32, 1), right_cell.style.hyperlink_id);
    try std.testing.expect(gridCellsEqual(left, left_cell, right, right_cell));

    var different = right_cell;
    different.style.hyperlink_id = 2;
    try std.testing.expect(!gridCellsEqual(left, left_cell, right, different));

    var missing = right_cell;
    missing.style.hyperlink_id = 99;
    try std.testing.expect(!gridCellsEqual(left, left_cell, right, missing));

    var unlinked = right_cell;
    unlinked.style.hyperlink_id = 0;
    try std.testing.expect(!gridCellsEqual(left, left_cell, right, unlinked));

    var different_codepoint = right_cell;
    different_codepoint.codepoint = 'Y';
    try std.testing.expect(!gridCellsEqual(left, left_cell, right, different_codepoint));

    var different_color = right_cell;
    different_color.style.fg = .{ .indexed = 1 };
    try std.testing.expect(!gridCellsEqual(left, left_cell, right, different_color));

    var different_flags = right_cell;
    different_flags.style.flags.bold = true;
    try std.testing.expect(!gridCellsEqual(left, left_cell, right, different_flags));
}

test "grid cell comparison distinguishes OSC 8 identities on the same URI" {
    var first = try vt_emulator.Grid.init(std.testing.allocator, 8, 1);
    defer first.deinit();
    try first.feed("\x1b]8;id=fx-1;https://example.com\x1b\\X\x1b]8;;\x1b\\");

    var second = try vt_emulator.Grid.init(std.testing.allocator, 8, 1);
    defer second.deinit();
    try second.feed("\x1b]8;id=fx-2;https://example.com\x1b\\X\x1b]8;;\x1b\\");

    try std.testing.expect(!gridCellsEqual(first, first.cellAt(1, 1).?, second, second.cellAt(1, 1).?));
}

test "grid cell comparison resolves combining suffix bytes instead of base glyph" {
    var acute = try vt_emulator.Grid.init(std.testing.allocator, 8, 1);
    defer acute.deinit();
    try acute.feed("e\u{0301}");

    var cedilla = try vt_emulator.Grid.init(std.testing.allocator, 8, 1);
    defer cedilla.deinit();
    try cedilla.feed("e\u{0327}");

    try std.testing.expect(!gridCellsEqual(
        acute,
        acute.cellAt(1, 1).?,
        cedilla,
        cedilla.cellAt(1, 1).?,
    ));
}

test "grid surface comparison resolves remapped hyperlink and combining resources" {
    var grid = try vt_emulator.Grid.init(std.testing.allocator, 16, 3);
    defer grid.deinit();
    try grid.feed("\x1b]8;;https://unused.example\x1b\\\x1b]8;;\x1b\\");
    try grid.feed("\x1b[2;1H\x1b]8;;https://same.example\x1b\\e\u{0301}\x1b]8;;\x1b\\");

    const plan = cellMatchTestPlan();
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, grid);
    defer surface.deinit();
    _ = try surface.writeAnsiBand(
        2,
        1,
        "\x1b]8;;https://same.example\x1b\\e\u{0301}\x1b]8;;\x1b\\",
        .transcript,
        .same_owner,
    );

    const grid_cell = grid.cellAt(2, 1).?;
    const surface_cell = surface.cellAt(2, 1).?;
    try std.testing.expectEqual(@as(u32, 2), grid_cell.style.hyperlink_id);
    try std.testing.expectEqual(@as(u32, 2), surface_cell.style.hyperlink_id);
    try std.testing.expect(gridSurfaceCellsEqual(grid, grid_cell, surface, surface_cell));

    _ = try surface.writeAnsiBand(
        2,
        1,
        "\x1b]8;;https://same.example\x1b\\e\u{0327}\x1b]8;;\x1b\\",
        .transcript,
        .same_owner,
    );
    try std.testing.expect(!gridSurfaceCellsEqual(grid, grid_cell, surface, surface.cellAt(2, 1).?));
}

fn cellMatchTestPlan() paint_plan.PaintPlan {
    return .{
        .layout = .{
            .rows = 3,
            .cols = 16,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 3,
            .divider_bottom_row = 3,
            .hint_row = 3,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 2,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
        .footer = .{
            .top = 3,
            .top_divider = 3,
            .banner = 3,
            .banner_active = false,
            .input_base = 3,
            .picker_divider = 3,
            .picker_start = 3,
            .bottom_divider = 3,
            .hint = 3,
            .total_rows = 1,
        },
        .activity = .none,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 2, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 3, .bottom = 3, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 3, .col = 1, .visible = true },
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

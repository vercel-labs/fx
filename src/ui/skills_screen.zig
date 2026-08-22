const std = @import("std");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const types = @import("../core/shared/types.zig");
const catalog_screen_layout = @import("catalog_screen_layout.zig");
const paste_blocks = @import("../core/input/pasted_blocks.zig");
const visual_layout = @import("input/visual_layout.zig");
const input_presentation = @import("footer/input_presentation.zig");
const render_input = @import("footer/render_input.zig");
const row_text = @import("footer/row_text.zig");
const skills_menu_presentation = @import("footer/skills_menu_presentation.zig");
const ui_render = @import("render.zig");
const vt_emulator = @import("../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;

pub const Composer = struct {
    input: []const u8,
    cursor: usize,
    images: []const types.ImageAttachment = &.{},
    pasted_blocks: []const paste_blocks.PastedBlock = &.{},
    image_tokens: []const visual_layout.ImageTokenSpan = &.{},
    skill_tokens: []const visual_layout.SkillTokenSpan = &.{},
};

pub const PaintInput = struct {
    rows: u16,
    cols: u16,
    skills: render_input.SkillsMenuProjection,
    composer: Composer,
    ctrl_c_pending: bool = false,
    clear_display: bool,
};

pub const Paint = struct {
    bytes: []u8,

    pub fn deinit(self: Paint, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

pub fn paint(alloc: Allocator, input: PaintInput) !Paint {
    if (input.rows == 0 or input.cols == 0) return error.InvalidSkillsScreenLayout;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("\x1b[?25l\x1b[H");
    if (input.clear_display) try out.writer.writeAll("\x1b[2J");

    const source = visual_layout.Source{
        .input = input.composer.input,
        .cursor = @min(input.composer.cursor, input.composer.input.len),
        .terminal_cols = input.cols,
        .images = input.composer.images,
        .pasted_blocks = input.composer.pasted_blocks,
        .image_tokens = input.composer.image_tokens,
        .skill_tokens = input.composer.skill_tokens,
    };
    const summary = visual_layout.summarize(source, null);
    const layout = catalog_screen_layout.screenLayout(input.rows, summary.total_rows, summary.cursor.row_index);
    var composer_rows = try input_presentation.composeVisibleInputRows(
        alloc,
        source,
        layout.composer_window,
    );
    defer composer_rows.deinit(alloc);

    const composer_row_count = layout.composer_row_count;
    const regions = catalog_screen_layout.regions(input.rows, composer_row_count);
    var prepared_menu = try skills_menu_presentation.prepareSkillsMenu(
        alloc,
        input.skills,
        layout.menu_row_budget,
    );
    defer prepared_menu.deinit(alloc);
    const menu_row_count = prepared_menu.rowCount();

    var screen_row: u16 = 1;
    while (screen_row <= input.rows) : (screen_row += 1) {
        if (screen_row <= composer_row_count) {
            try writeScreenRow(&out.writer, screen_row, composer_rows.rows.items[screen_row - 1].items);
            continue;
        }
        if (screen_row == regions.top_divider_row or screen_row == regions.bottom_divider_row) {
            var divider = try row_text.composeDividerRow(alloc, input.cols);
            defer divider.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, divider.items);
            continue;
        }
        if (regions.menu_start_row > 0 and screen_row >= regions.menu_start_row and screen_row < regions.menu_start_row +| menu_row_count) {
            var menu_row = try skills_menu_presentation.composeSkillsMenuRow(
                alloc,
                prepared_menu,
                screen_row - regions.menu_start_row,
                input.cols,
            );
            defer menu_row.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, menu_row.items);
            continue;
        }
        if (screen_row == regions.hint_row) {
            var hint = try input_presentation.composeSkillsMenuHintRow(alloc, input.cols, input.ctrl_c_pending);
            defer hint.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, hint.items);
            continue;
        }
        try writeScreenRow(&out.writer, screen_row, "");
    }

    const cursor_row_offset: usize = summary.cursor.row_index -| layout.composer_window.first_row;
    const cursor_row: u16 = @intCast(@min(cursor_row_offset + 1, @as(usize, composer_row_count)));
    const cursor_col = visual_layout.terminalColumn(summary.cursor, input.cols);
    try writeCursor(&out.writer, cursor_row, cursor_col);
    try out.writer.writeAll(ui_render.reset_style);
    try out.writer.writeAll("\x1b[?25h");

    return .{ .bytes = try out.toOwnedSlice() };
}

fn writeScreenRow(writer: *std.Io.Writer, row: u16, bytes: []const u8) !void {
    try writeCursor(writer, row, 1);
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll("\x1b[K");
    try writer.writeAll(bytes);
    try writer.writeAll(ui_render.reset_style);
}

fn writeCursor(writer: *std.Io.Writer, row: u16, col: u16) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

test "skills screen preserves the final cell of an exact-width row" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("\x1b[?7l");
    try writeScreenRow(&out.writer, 1, "12345678");

    var grid = try vt_emulator.Grid.init(alloc, 8, 2);
    defer grid.deinit();
    try grid.feed(out.written());

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("12345678", row.items);
}

test "skills screen places the unchanged composer above the catalog without transcript chrome" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "pure-core", .description = "Keep data transformations pure.", .path = "/skills/pure-core/SKILL.md", .source = .global_fx },
        .{ .name = "fx-guide", .description = "Route Fx work to the right skill.", .path = "/skills/fx-guide/SKILL.md", .source = .global_codex },
    };
    const projection: render_input.SkillsMenuProjection = .{
        .active = true,
        .items = @constCast(&skills),
        .query = "pure",
    };

    var screen = try paint(alloc, .{
        .rows = 14,
        .cols = 72,
        .skills = projection,
        .composer = .{
            .input = "$pure",
            .cursor = "$pure".len,
        },
        .clear_display = true,
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 72, 14);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "$pure") != null);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(3, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "Skills 1") != null);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(5, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "pure-core") != null);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(14, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "Navigate") != null);
    try std.testing.expect(std.mem.find(u8, screen.bytes, "Run /help for commands") == null);
}

test "skills screen keeps the armed Ctrl-C exit warning visible" {
    const alloc = std.testing.allocator;
    const projection: render_input.SkillsMenuProjection = .{ .active = true };
    var screen = try paint(alloc, .{
        .rows = 8,
        .cols = 48,
        .skills = projection,
        .composer = .{
            .input = "",
            .cursor = 0,
        },
        .ctrl_c_pending = true,
        .clear_display = true,
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 48, 8);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(8, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "press ctrl+c again to exit") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Navigate") == null);
}

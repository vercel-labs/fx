const std = @import("std");
const model_cache_runtime = @import("../core/app/model_cache_runtime.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const types = @import("../core/shared/types.zig");
const catalog_screen_layout = @import("catalog_screen_layout.zig");
const paste_blocks = @import("../core/input/pasted_blocks.zig");
const visual_layout = @import("input/visual_layout.zig");
const input_presentation = @import("footer/input_presentation.zig");
const model_menu_presentation = @import("footer/model_menu_presentation.zig");
const render_input = @import("footer/render_input.zig");
const row_text = @import("footer/row_text.zig");
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
    appearance: render_input.InputAppearance,
    prefix_style: input_presentation.ComposerPrefixStyle,
};

pub const PaintInput = struct {
    rows: u16,
    cols: u16,
    models: render_input.ModelMenuProjection,
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
    if (input.rows == 0 or input.cols == 0) return error.InvalidModelsScreenLayout;

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
        input.composer.appearance,
        input.composer.prefix_style,
    );
    defer composer_rows.deinit(alloc);

    const regions = catalog_screen_layout.regions(input.rows, layout.composer_row_count);
    const menu_row_count = model_menu_presentation.menuRowCount(input.models, input.cols, layout.menu_row_budget);

    var screen_row: u16 = 1;
    while (screen_row <= input.rows) : (screen_row += 1) {
        if (screen_row <= layout.composer_row_count) {
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
            var menu_row = try model_menu_presentation.composeModelMenuRow(
                alloc,
                input.models,
                screen_row - regions.menu_start_row,
                input.cols,
                menu_row_count,
            );
            defer menu_row.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, menu_row.items);
            continue;
        }
        if (screen_row == regions.hint_row) {
            var hint = try input_presentation.composeModelsMenuHintRow(alloc, input.cols, input.ctrl_c_pending);
            defer hint.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, hint.items);
            continue;
        }
        try writeScreenRow(&out.writer, screen_row, "");
    }

    const cursor_row_offset = summary.cursor.row_index -| layout.composer_window.first_row;
    const cursor_row: u16 = @intCast(@min(cursor_row_offset + 1, @as(usize, layout.composer_row_count)));
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

test "models screen places composer catalog and controls without transcript chrome" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{.{
        .id = @constCast("anthropic/claude-opus-4.8"),
        .provider = "anthropic",
        .descriptor = model_capabilities.configuredDescriptor(
            "anthropic/claude-opus-4.8",
            .{ .supports_reasoning = true, .context_window = 1_000_000 },
        ),
    }};
    const projection: render_input.ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
        .query = "opus",
    };
    var screen = try paint(alloc, .{
        .rows = 14,
        .cols = 80,
        .models = projection,
        .composer = .{
            .input = "opus",
            .cursor = "opus".len,
            .appearance = .lines,
            .prefix_style = .rail,
        },
        .clear_display = true,
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 80, 14);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "opus") != null);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(3, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "Models 1") != null);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(5, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "anthropic/claude-opus-4.8") != null);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(14, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "Tab Provider") != null);
    try std.testing.expect(std.mem.find(u8, screen.bytes, "Run /help for commands") == null);
}

test "models screen stays within tiny terminal dimensions" {
    const alloc = std.testing.allocator;
    const projection: render_input.ModelMenuProjection = .{ .active = true, .load_state = .loading };
    var screen = try paint(alloc, .{
        .rows = 3,
        .cols = 8,
        .models = projection,
        .composer = .{ .input = "", .cursor = 0, .appearance = .lines, .prefix_style = .rail },
        .clear_display = true,
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 8, 3);
    defer grid.deinit();
    try grid.feed(screen.bytes);
    try std.testing.expectEqual(@as(u16, 8), grid.cols);
    try std.testing.expectEqual(@as(u16, 3), grid.rows);
}

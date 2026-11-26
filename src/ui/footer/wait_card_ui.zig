//! The rows of the wait card: the subagent and the reason, the countdown the
//! wait may carry, a numbered choice for each action the card offers, and the
//! keys. The footer draws the card in the block a question panel takes
//! (`src/ui/footer/paint_plan.zig`), so this module only turns the card into
//! clipped, terminal-safe rows.

const std = @import("std");
const wait_card = @import("../../core/agent/wait_card.zig");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const ui_render = @import("../render.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;

/// The rows above the first choice: the name and reason, the detail line and
/// a gap. The choices follow, then the key row.
const lead_rows: u16 = 3;
const warning_sign = "\u{26a0} ";
const chosen_mark = "\u{25b8} ";
const spare_mark = "  ";
const hint_text = "  \u{2191}\u{2193} choose   enter run   esc cancel this turn   type after you choose";

/// The rows the card needs, never more than the block the footer has for it.
pub fn rowCount(card: *const wait_card.WaitCardPrompt, max_rows: u16) u16 {
    const wanted = lead_rows + @as(u16, @intCast(card.choices().len)) + 1;
    return @min(wanted, @max(max_rows, 1));
}

/// One row of the card, styled and clipped to `width`. Every row ends in a
/// reset, so the footer can paint it alone.
pub fn composeRow(
    alloc: Allocator,
    card: *const wait_card.WaitCardPrompt,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const choice_count: u16 = @intCast(card.choices().len);
    if (row_index == 0) {
        const line = try alloc.print("  {s}{s}: {s}", .{ warning_sign, card.nameText(), card.reasonText() });
        defer alloc.free(line);
        try row.appendSlice(alloc, ui_render.bold_style);
        try appendTerminalSafe(alloc, &row, line, width);
    } else if (row_index == 1) {
        if (card.detailText().len > 0) {
            const line = try alloc.print("  {s}", .{card.detailText()});
            defer alloc.free(line);
            try row.appendSlice(alloc, ui_render.dim_style);
            try appendTerminalSafe(alloc, &row, line, width);
        }
    } else if (row_index < lead_rows) {
        // The gap between the reason and the choices.
    } else if (row_index < lead_rows + choice_count) {
        const index = row_index - lead_rows;
        const choice = card.choiceAt(index) orelse return row;
        var label_buf: [96]u8 = undefined;
        const chosen = index == card.selected;
        const line = try alloc.print("  {s}{d} {s}", .{
            if (chosen) chosen_mark else spare_mark,
            index + 1,
            card.labelFor(choice, &label_buf),
        });
        defer alloc.free(line);
        try row.appendSlice(alloc, if (chosen) ui_render.selected_completion_style else ui_render.dim_style);
        try appendTerminalSafe(alloc, &row, line, width);
    } else {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendClipped(alloc, &row, hint_text, width);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

/// The subagent's name comes from its parent, and a reason may quote a
/// provider: draw both as text, never as escapes the terminal would act on.
fn appendTerminalSafe(alloc: Allocator, row: *std.ArrayList(u8), raw: []const u8, width: u16) !void {
    const safe = try alloc.print("{f}", .{text_utils.terminalSafe(raw)});
    defer alloc.free(safe);
    try row_text.appendClipped(alloc, row, safe, width);
}

test "wait card: the rows name the subagent and the reason, number every choice, and keep an escape out of the screen" {
    const alloc = std.testing.allocator;
    var card: wait_card.WaitCardPrompt = .{};
    card.kind = .sign_in;
    card.name_len = 6;
    @memcpy(card.name[0..6], "signer");
    card.reason_len = 15;
    @memcpy(card.reason[0..15], "Sign-in expired");
    card.detail_len = 10;
    @memcpy(card.detail[0..10], "waiting 1s");

    var grid = try vt_emulator.Grid.init(alloc, 80, rowCount(&card, 40));
    defer grid.deinit();
    const rows = rowCount(&card, 40);
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeRow(alloc, &card, row_index, 80);
        defer row.deinit(alloc);
        try grid.feed(row.items);
        // A line break after the last row would scroll the grid once and
        // push the header out of it.
        if (row_index + 1 < rows) try grid.feed("\r\n");
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try grid.rowTextTrimmed(1, &text);
    try std.testing.expectEqualStrings("  \u{26a0} signer: Sign-in expired", text.items);
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(2, &text);
    try std.testing.expectEqualStrings("  waiting 1s", text.items);
    // The first choice carries the mark, and each choice carries its digit in
    // the order that picks it.
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(4, &text);
    try std.testing.expectEqualStrings("  \u{25b8} 1 Retry", text.items);
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(5, &text);
    try std.testing.expectEqualStrings("    2 Sign in", text.items);
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(8, &text);
    try std.testing.expectEqualStrings("    5 Stop signer", text.items);
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(9, &text);
    try std.testing.expectEqualStrings("  \u{2191}\u{2193} choose   enter run   esc cancel this turn   type after you choose", text.items);

    // A name that holds a control byte reaches the screen as visible text.
    var hostile: wait_card.WaitCardPrompt = .{};
    hostile.kind = .rejected;
    const name = "evil\x1b[2Jname";
    hostile.name_len = name.len;
    @memcpy(hostile.name[0..name.len], name);
    const reason = "refused";
    hostile.reason_len = reason.len;
    @memcpy(hostile.reason[0..reason.len], reason);
    var row = try composeRow(alloc, &hostile, 0, 80);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.findScalar(u8, row.items, 0x1b) != null);
    var safe_grid = try vt_emulator.Grid.init(alloc, 80, 1);
    defer safe_grid.deinit();
    try safe_grid.feed(row.items);
    text.clearRetainingCapacity();
    try safe_grid.rowTextTrimmed(1, &text);
    try std.testing.expect(text_utils.isTerminalSafe(text.items));
    try std.testing.expect(display_width.visibleWidth(text.items) > 0);
    try std.testing.expect(std.mem.find(u8, text.items, "evil") != null);
}

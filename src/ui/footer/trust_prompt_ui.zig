const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const workspace_trust = @import("../../core/workspace_trust/workspace_trust.zig");

const Allocator = std.mem.Allocator;
const Prompt = workspace_trust.prompt.Prompt;
const Row = workspace_trust.prompt.Row;
const Choice = workspace_trust.prompt.Choice;
const Cover = workspace_trust.Cover;

const title_text = "Folder access";
const question_text = "Allow fx to read, edit, delete and run files in this folder, within your permission mode?";
const notice_text = "Give access only if you trust contents of this folder and who has access to it, as files in this folder can affect how fx operates.";
const rows_heading = "This folder has:";
const whole_repository_note = "This applies to the whole repo: ";
const main_repository_note = "This applies to the main repo and all its worktrees: ";
const home_folder_note = "fx asks again each time you start in your home folder.";
const special_folder_note = "fx asks again each time you start in this folder.";
const allow_label = "Yes, allow";
const exit_label = "No, exit";
const selected_marker = "❯ ";
const wide_hint = "↑↓ choose    enter confirm    esc exit";
const narrow_hint = "enter confirm    esc exit";
const hint_variants = [_][]const u8{ wide_hint, narrow_hint };

const indent_cols: u16 = 2;
const right_margin_cols: u16 = 2;
/// The indent plus the selection marker in front of each choice label.
const choice_prefix_cols: u16 = 4;
const list_name_gap_cols: usize = 2;
const list_name_max_share: usize = 3;
const max_encoded_bytes: usize = 4096;

const Section = enum { title, question, folder, notice, list, note, choices };
const section_count = std.enums.values(Section).len;
const Sections = [section_count]std.ArrayList(u8);

/// The sections dropped first when the rows do not fit, in that order.
const drop_order = [_]Section{ .list, .note, .title };

const Plan = struct {
    keep: [section_count]bool,
    blank_rows: bool,
};

pub fn hintText(cols: u16) []const u8 {
    return display_width.widestFitting(&hint_variants, cols);
}

pub fn composeHintRow(alloc: Allocator, cols: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hintText(cols), cols);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

/// The panel as rows joined by '\n'. The caller owns the result.
pub fn composeTrustPromptText(alloc: Allocator, prompt: *const Prompt, cols: u16, max_rows: u16) ![]u8 {
    var sections: Sections = @splat(std.ArrayList(u8).empty);
    defer deinitSections(alloc, &sections);
    try buildSections(alloc, &sections, prompt, cols);

    var row_counts: [section_count]usize = undefined;
    for (&row_counts, sections) |*count, section| count.* = rowCount(section.items);
    const plan = planSections(row_counts, max_rows);

    var joined = try joinSections(alloc, &sections, plan);
    defer joined.deinit(alloc);
    return alloc.dupe(u8, joined.items[tailStart(joined.items, max_rows)..]);
}

pub fn panelRowCount(alloc: Allocator, prompt: *const Prompt, cols: u16, max_rows: u16) !u16 {
    const budget = @max(max_rows, 1);
    const text = try composeTrustPromptText(alloc, prompt, cols, budget);
    defer alloc.free(text);
    return @intCast(@min(rowCount(text), budget));
}

fn deinitSections(alloc: Allocator, sections: *Sections) void {
    for (sections) |*section| section.deinit(alloc);
}

fn slot(sections: *Sections, section: Section) *std.ArrayList(u8) {
    return &sections[@backingInt(section)];
}

fn buildSections(alloc: Allocator, sections: *Sections, prompt: *const Prompt, cols: u16) !void {
    const width = contentWidth(cols);
    try appendTitle(alloc, slot(sections, .title), cols);
    try appendParagraph(alloc, slot(sections, .question), question_text, width);
    try appendFolder(alloc, slot(sections, .folder), prompt.folder, width);
    try appendParagraph(alloc, slot(sections, .notice), notice_text, width);
    if (showsList(prompt)) try appendList(alloc, slot(sections, .list), prompt.rows, width);
    try appendNote(alloc, slot(sections, .note), prompt.cover, width);
    try appendChoices(alloc, slot(sections, .choices), prompt.selected, cols);
}

fn contentWidth(cols: u16) usize {
    return @as(usize, cols) -| @as(usize, indent_cols + right_margin_cols);
}

fn showsList(prompt: *const Prompt) bool {
    if (prompt.rows.len == 0) return false;
    return switch (prompt.cover) {
        .home_folder, .special_folder => false,
        else => true,
    };
}

/// Starts a new row in `section`, unless the section has no rows yet.
fn beginRow(alloc: Allocator, section: *std.ArrayList(u8)) !void {
    if (section.items.len > 0) try section.append(alloc, '\n');
}

fn appendTitle(alloc: Allocator, section: *std.ArrayList(u8), cols: u16) !void {
    try beginRow(alloc, section);
    try section.appendNTimes(alloc, ' ', indent_cols);
    try section.appendSlice(alloc, ui_render.bold_style);
    try row_text.appendClipped(alloc, section, title_text, cols -| indent_cols);
    try section.appendSlice(alloc, ui_render.reset_style);
}

fn appendFolder(alloc: Allocator, section: *std.ArrayList(u8), folder: []const u8, width: usize) !void {
    var path = try text_utils.encodeTerminalSafeInline(alloc, folder, max_encoded_bytes);
    defer path.deinit(alloc);
    try beginRow(alloc, section);
    try section.appendNTimes(alloc, ' ', indent_cols);
    try row_text.appendSingleLineMiddleEllipsized(alloc, section, path.bytes, width);
}

fn appendParagraph(alloc: Allocator, section: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    try beginRow(alloc, section);
    try section.appendNTimes(alloc, ' ', indent_cols);
    try appendWrapped(alloc, section, text, width, indent_cols);
}

/// Writes `text` as rows of at most `width` columns. The first row continues
/// the current row; each later row starts `continuation_indent` spaces in.
fn appendWrapped(
    alloc: Allocator,
    section: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
    continuation_indent: usize,
) !void {
    var rest = text;
    var first = true;
    while (rest.len > 0) {
        if (!first) {
            try section.append(alloc, '\n');
            try section.appendNTimes(alloc, ' ', continuation_indent);
        }
        first = false;
        var piece = display_width.wrapCutIgnoringAnsi(rest, width);
        if (piece.len == 0) piece = rest[0..display_width.displayUnitAt(rest, 0).byte_len];
        try section.appendSlice(alloc, piece);
        rest = display_width.trimBreakWhitespace(rest[piece.len..]);
    }
}

fn appendNote(alloc: Allocator, section: *std.ArrayList(u8), cover: Cover, width: usize) !void {
    switch (cover) {
        .this_folder => {},
        .home_folder => try appendParagraph(alloc, section, home_folder_note, width),
        .special_folder => try appendParagraph(alloc, section, special_folder_note, width),
        .whole_repository => |path| try appendPathNote(alloc, section, whole_repository_note, path, width),
        .main_repository => |path| try appendPathNote(alloc, section, main_repository_note, path, width),
    }
}

fn appendPathNote(alloc: Allocator, section: *std.ArrayList(u8), prefix: []const u8, path: []const u8, width: usize) !void {
    var safe_path = try text_utils.encodeTerminalSafeInline(alloc, path, max_encoded_bytes);
    defer safe_path.deinit(alloc);
    var note: std.ArrayList(u8) = .empty;
    defer note.deinit(alloc);
    try note.appendSlice(alloc, prefix);
    try note.appendSlice(alloc, safe_path.bytes);
    try appendParagraph(alloc, section, note.items, width);
}

fn appendList(alloc: Allocator, section: *std.ArrayList(u8), rows: []const Row, width: usize) !void {
    const name_col = try listNameColumn(alloc, rows, width);
    try beginRow(alloc, section);
    try section.appendNTimes(alloc, ' ', indent_cols);
    try section.appendSlice(alloc, rows_heading);
    for (rows) |row| try appendListRow(alloc, section, row, name_col, width);
}

/// The name column fits the widest name plus a gap, and never takes more than
/// a third of the width.
fn listNameColumn(alloc: Allocator, rows: []const Row, width: usize) !usize {
    var widest: usize = 0;
    for (rows) |row| {
        const name_width = try encodedWidth(alloc, row.name);
        widest = @max(widest, name_width);
    }
    return @min(widest + list_name_gap_cols, width / list_name_max_share);
}

fn encodedWidth(alloc: Allocator, raw: []const u8) !usize {
    var encoded = try text_utils.encodeTerminalSafeInline(alloc, raw, max_encoded_bytes);
    defer encoded.deinit(alloc);
    return display_width.visibleWidth(encoded.bytes);
}

fn appendListRow(alloc: Allocator, section: *std.ArrayList(u8), row: Row, name_col: usize, width: usize) !void {
    const detail_indent = @as(usize, indent_cols) + name_col;
    try beginRow(alloc, section);
    const row_start = section.items.len;
    try section.appendNTimes(alloc, ' ', indent_cols);
    var name = try text_utils.encodeTerminalSafeInline(alloc, row.name, max_encoded_bytes);
    defer name.deinit(alloc);
    try row_text.appendSingleLineEllipsized(alloc, section, name.bytes, name_col -| list_name_gap_cols);
    const used = display_width.visibleWidth(section.items[row_start..]);
    try section.appendNTimes(alloc, ' ', detail_indent -| used);
    var detail = try text_utils.encodeTerminalSafeInline(alloc, row.detail, max_encoded_bytes);
    defer detail.deinit(alloc);
    try appendWrapped(alloc, section, detail.bytes, width -| name_col, detail_indent);
}

fn appendChoices(alloc: Allocator, section: *std.ArrayList(u8), selected: Choice, cols: u16) !void {
    try appendChoice(alloc, section, selected == .allow, allow_label, cols);
    try appendChoice(alloc, section, selected == .exit, exit_label, cols);
}

fn appendChoice(alloc: Allocator, section: *std.ArrayList(u8), selected: bool, label: []const u8, cols: u16) !void {
    try beginRow(alloc, section);
    const label_cols = cols -| choice_prefix_cols;
    if (selected) {
        try section.appendNTimes(alloc, ' ', indent_cols);
        try section.appendSlice(alloc, selected_marker);
        try section.appendSlice(alloc, ui_render.tag_style);
        try row_text.appendClipped(alloc, section, label, label_cols);
        try section.appendSlice(alloc, ui_render.reset_style);
    } else {
        try section.appendNTimes(alloc, ' ', choice_prefix_cols);
        try row_text.appendClipped(alloc, section, label, label_cols);
    }
}

/// Number of rows in a section's text: its rows are joined by '\n'.
fn rowCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    return std.mem.countScalar(u8, text, '\n') + 1;
}

/// Picks the sections to keep for a row budget. Blank rows go first, then the
/// list, the note and the title, in that order.
fn planSections(row_counts: [section_count]usize, max_rows: usize) Plan {
    var plan: Plan = .{ .keep = undefined, .blank_rows = true };
    for (&plan.keep, row_counts) |*keep, count| keep.* = count > 0;
    if (plannedRows(row_counts, plan) <= max_rows) return plan;
    plan.blank_rows = false;
    for (drop_order) |section| {
        if (plannedRows(row_counts, plan) <= max_rows) break;
        plan.keep[@backingInt(section)] = false;
    }
    return plan;
}

fn plannedRows(row_counts: [section_count]usize, plan: Plan) usize {
    var rows: usize = 0;
    var kept: usize = 0;
    for (row_counts, plan.keep) |count, keep| {
        if (!keep) continue;
        rows += count;
        kept += 1;
    }
    if (plan.blank_rows and kept > 0) rows += kept - 1;
    return rows;
}

fn joinSections(alloc: Allocator, sections: *const Sections, plan: Plan) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var joined_any = false;
    for (sections, plan.keep) |section, keep| {
        if (!keep) continue;
        if (joined_any) {
            try out.append(alloc, '\n');
            if (plan.blank_rows) try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, section.items);
        joined_any = true;
    }
    return out;
}

/// Where the last `max_rows` rows of `text` begin: the top rows go first.
fn tailStart(text: []const u8, max_rows: usize) usize {
    const rows = rowCount(text);
    if (rows <= max_rows) return 0;
    var to_skip = rows - max_rows;
    for (text, 0..) |byte, index| {
        if (byte != '\n') continue;
        to_skip -= 1;
        if (to_skip == 0) return index + 1;
    }
    return text.len;
}

fn feedRows(grid: *vt_emulator.Grid, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try grid.feed("\r\n");
        first = false;
        try grid.feed(line);
    }
}

fn gridRowText(alloc: Allocator, grid: vt_emulator.Grid, row: u16) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    try grid.rowTextTrimmed(row, &line);
    return line.toOwnedSlice(alloc);
}

/// Every grid row joined with single spaces, so a wrapped sentence reads as one line.
fn joinedWords(alloc: Allocator, grid: vt_emulator.Grid, row_count: u16) ![]u8 {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(alloc);
    var row: u16 = 1;
    while (row <= row_count) : (row += 1) {
        try grid.rowTextTrimmed(row, &all);
        try all.append(alloc, ' ');
    }
    var words: std.ArrayList(u8) = .empty;
    errdefer words.deinit(alloc);
    var tokens = std.mem.tokenizeScalar(u8, all.items, ' ');
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try words.append(alloc, ' ');
        first = false;
        try words.appendSlice(alloc, token);
    }
    return words.toOwnedSlice(alloc);
}

fn composeForTest(alloc: Allocator, prompt: Prompt, cols: u16, max_rows: u16) ![]u8 {
    return composeTrustPromptText(alloc, &prompt, cols, max_rows);
}

fn withoutStyles(alloc: Allocator, text: []const u8) ![]u8 {
    const styles = [_][]const u8{ ui_render.bold_style, ui_render.reset_style, ui_render.tag_style, ui_render.dim_style };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    outer: while (index < text.len) {
        for (styles) |style| {
            if (style.len > 0 and std.mem.startsWith(u8, text[index..], style)) {
                index += style.len;
                continue :outer;
            }
        }
        try out.append(alloc, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(alloc);
}

test "the folder access screen shows the approved text at every width" {
    const alloc = std.testing.allocator;
    const rows = [_]Row{
        .{ .name = "AGENTS.md", .detail = "instructions for the agent" },
        .{ .name = ".fx/skills", .detail = "3 skills" },
        .{ .name = ".mcp.json", .detail = "2 MCP servers, each needs your approval" },
    };
    for ([_]u16{ 48, 80, 120 }) |cols| {
        const prompt: Prompt = .{ .folder = "/Users/example/code/some-repo", .cover = .this_folder, .rows = &rows };
        const text = try composeForTest(alloc, prompt, cols, 40);
        defer alloc.free(text);
        const row_count: u16 = @intCast(rowCount(text));
        var grid = try vt_emulator.Grid.init(alloc, cols, row_count);
        defer grid.deinit();
        try feedRows(&grid, text);

        const words = try joinedWords(alloc, grid, row_count);
        defer alloc.free(words);
        try std.testing.expect(std.mem.find(u8, words, question_text) != null);
        try std.testing.expect(std.mem.find(u8, words, notice_text) != null);

        const first = try gridRowText(alloc, grid, 1);
        defer alloc.free(first);
        try std.testing.expectEqualStrings(title_text, std.mem.trim(u8, first, " "));

        const last = try gridRowText(alloc, grid, row_count);
        defer alloc.free(last);
        try std.testing.expectEqualStrings(exit_label, std.mem.trim(u8, last, " "));
        const before_last = try gridRowText(alloc, grid, row_count - 1);
        defer alloc.free(before_last);
        try std.testing.expectEqualStrings("❯ " ++ allow_label, std.mem.trim(u8, before_last, " "));

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
    }
}

test "the selected choice moves with the prompt" {
    const alloc = std.testing.allocator;
    const prompt: Prompt = .{ .folder = "/r", .cover = .this_folder, .selected = .exit };
    const text = try composeForTest(alloc, prompt, 80, 40);
    defer alloc.free(text);
    const row_count: u16 = @intCast(rowCount(text));
    var grid = try vt_emulator.Grid.init(alloc, 80, row_count);
    defer grid.deinit();
    try feedRows(&grid, text);

    var marked: usize = 0;
    var row: u16 = 1;
    while (row <= row_count) : (row += 1) {
        const line = try gridRowText(alloc, grid, row);
        defer alloc.free(line);
        if (std.mem.find(u8, line, "❯") == null) continue;
        marked += 1;
        try std.testing.expect(std.mem.find(u8, line, exit_label) != null);
    }
    try std.testing.expectEqual(@as(usize, 1), marked);
}

test "a long folder path keeps both ends" {
    const alloc = std.testing.allocator;
    var long_path: std.ArrayList(u8) = .empty;
    defer long_path.deinit(alloc);
    try long_path.appendSlice(alloc, "/Users/example/");
    for (0..13) |_| try long_path.appendSlice(alloc, "deep-folder/");
    try long_path.appendSlice(alloc, "last-repo");
    try std.testing.expectEqual(@as(usize, 180), long_path.items.len);

    const prompt: Prompt = .{ .folder = long_path.items, .cover = .this_folder };
    const text = try composeForTest(alloc, prompt, 48, 40);
    defer alloc.free(text);
    const row_count: u16 = @intCast(rowCount(text));
    var grid = try vt_emulator.Grid.init(alloc, 48, row_count);
    defer grid.deinit();
    try feedRows(&grid, text);

    var found = false;
    var row: u16 = 1;
    while (row <= row_count) : (row += 1) {
        const line = try gridRowText(alloc, grid, row);
        defer alloc.free(line);
        if (std.mem.find(u8, line, "/Users/") == null) continue;
        found = true;
        const shown = std.mem.trim(u8, line, " ");
        try std.testing.expect(std.mem.find(u8, shown, "…") != null);
        try std.testing.expect(std.mem.startsWith(u8, shown, "/Users/"));
        try std.testing.expect(std.mem.endsWith(u8, shown, "last-repo"));
    }
    try std.testing.expect(found);
}

test "escape sequences in a folder name never reach the screen" {
    const alloc = std.testing.allocator;
    const rows = [_]Row{.{ .name = "\x1b]0;title\x07", .detail = "a detail" }};
    const prompt: Prompt = .{ .folder = "/tmp/\x1b[31mred\x1b[0m", .cover = .this_folder, .rows = &rows };
    const text = try composeForTest(alloc, prompt, 80, 40);
    defer alloc.free(text);

    const bare = try withoutStyles(alloc, text);
    defer alloc.free(bare);
    try std.testing.expect(std.mem.findScalar(u8, bare, 0x1b) == null);

    const row_count: u16 = @intCast(rowCount(text));
    var grid = try vt_emulator.Grid.init(alloc, 80, row_count);
    defer grid.deinit();
    try feedRows(&grid, text);
    const words = try joinedWords(alloc, grid, row_count);
    defer alloc.free(words);
    try std.testing.expect(std.mem.find(u8, words, "/tmp/\\x1b[31mred") != null);
}

test "a short terminal keeps the question, the notice, and the choices" {
    const alloc = std.testing.allocator;
    const rows = [_]Row{
        .{ .name = "AGENTS.md", .detail = "instructions for the agent" },
        .{ .name = ".fx/skills", .detail = "3 skills" },
        .{ .name = ".mcp.json", .detail = "2 MCP servers, each needs your approval" },
    };
    const prompt: Prompt = .{ .folder = "/Users/example/code/some-repo", .cover = .this_folder, .rows = &rows };
    const text = try composeForTest(alloc, prompt, 80, 11);
    defer alloc.free(text);
    const row_count: u16 = @intCast(rowCount(text));
    try std.testing.expect(row_count <= 11);
    try std.testing.expect(std.mem.find(u8, text, rows_heading) == null);

    var grid = try vt_emulator.Grid.init(alloc, 80, row_count);
    defer grid.deinit();
    try feedRows(&grid, text);
    const words = try joinedWords(alloc, grid, row_count);
    defer alloc.free(words);
    try std.testing.expect(std.mem.find(u8, words, question_text) != null);
    try std.testing.expect(std.mem.find(u8, words, notice_text) != null);

    const last = try gridRowText(alloc, grid, row_count);
    defer alloc.free(last);
    try std.testing.expectEqualStrings(exit_label, std.mem.trim(u8, last, " "));
    const before_last = try gridRowText(alloc, grid, row_count - 1);
    defer alloc.free(before_last);
    try std.testing.expectEqualStrings("❯ " ++ allow_label, std.mem.trim(u8, before_last, " "));
}

test "the note says what the answer covers" {
    const alloc = std.testing.allocator;
    const rows = [_]Row{.{ .name = "AGENTS.md", .detail = "instructions for the agent" }};

    const whole = try composeForTest(alloc, .{ .folder = "/r/src", .cover = .{ .whole_repository = "/r" } }, 80, 40);
    defer alloc.free(whole);
    try std.testing.expect(std.mem.find(u8, whole, "This applies to the whole repo: /r") != null);

    const home = try composeForTest(alloc, .{ .folder = "/Users/example", .cover = .home_folder, .rows = &rows }, 80, 40);
    defer alloc.free(home);
    try std.testing.expect(std.mem.find(u8, home, "fx asks again each time you start in your home folder.") != null);
    try std.testing.expect(std.mem.find(u8, home, rows_heading) == null);

    const this = try composeForTest(alloc, .{ .folder = "/r", .cover = .this_folder, .rows = &rows }, 80, 40);
    defer alloc.free(this);
    try std.testing.expect(std.mem.find(u8, this, "This applies to") == null);
    try std.testing.expect(std.mem.find(u8, this, "fx asks again") == null);
}

test "the hint keeps enter and esc at any width" {
    const alloc = std.testing.allocator;
    for ([_]u16{ 20, 200 }) |cols| {
        const hint = hintText(cols);
        try std.testing.expect(std.mem.find(u8, hint, "enter confirm") != null);
        try std.testing.expect(std.mem.find(u8, hint, "esc exit") != null);
        var row = try composeHintRow(alloc, cols);
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, "enter confirm") != null);
    }
}

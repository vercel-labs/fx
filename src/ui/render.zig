const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const host = @import("../core/hosts/host.zig");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const types = @import("../core/shared/types.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const main = @import("../main.zig");
const theme_detection = @import("terminal/theme_detection.zig");
const theme_protocol = @import("terminal/theme_protocol.zig");
const visual_layout = @import("input/visual_layout.zig");

pub const input_prefix = "❯ ";
pub const TerminalRgb = user_message_card.Rgb;
pub const reset_style = "\x1b[0m";
pub const bold_style = "\x1b[1m";
pub const app_name = "fx";
pub const right_tag = "/fx";
pub const ask_activity_label = "⏺ Asking";

const user_message_card = @import("assistant/user_message_card.zig");

pub const welcome_message_reserved_rows: u16 = 11;

pub var is_light: bool = false;
pub var input_bar_style: []const u8 = "";
pub var divider_style: []const u8 = "\x1b[38;5;240m";
pub var hint_style: []const u8 = "\x1b[38;5;255m";
pub var statusline_style: []const u8 = "\x1b[38;5;245m";
pub var tag_style: []const u8 = "\x1b[1;38;5;255m";
pub var subtitle_style: []const u8 = "\x1b[1;38;5;255m";
pub var system_notice_label_style: []const u8 = "\x1b[1;38;5;252m";
pub var system_notice_text_style: []const u8 = "\x1b[38;5;250m";
pub var dim_style: []const u8 = "\x1b[38;5;245m";
pub var warning_style: []const u8 = "\x1b[38;5;252m";
pub var green_style: []const u8 = "\x1b[38;5;252m";
pub var red_style: []const u8 = "\x1b[38;5;252m";
pub var diff_added_style: []const u8 = "\x1b[38;5;252m";
pub var diff_removed_style: []const u8 = "\x1b[38;5;252m";
// The line number and +/- sign carry the only color in an otherwise
// monochrome diff: green for additions (#30A46C), red for deletions
// (#E5484D). The line text stays neutral. Truecolor when the terminal
// supports it, 256-color fallback otherwise.
const diff_added_marker_truecolor = "\x1b[38;2;48;164;108m";
const diff_removed_marker_truecolor = "\x1b[38;2;229;72;77m";
const diff_added_marker_fallback = "\x1b[38;5;71m";
const diff_removed_marker_fallback = "\x1b[38;5;167m";
pub var diff_added_marker_style: []const u8 = diff_added_marker_fallback;
pub var diff_removed_marker_style: []const u8 = diff_removed_marker_fallback;
pub var approval_button_active_style: []const u8 = "\x1b[48;5;255m\x1b[38;5;235m\x1b[1m";
pub var approval_button_inactive_style: []const u8 = "\x1b[48;5;239m\x1b[38;5;255m";
pub var selected_completion_style: []const u8 = "\x1b[1;38;5;255m";
// Statusbar permissions "auto": a step brighter than the statusline gray.
pub var permission_auto_style: []const u8 = "\x1b[38;5;252m";
var active_terminal_background: ?TerminalRgb = null;

var truecolor_enabled: bool = true;

pub fn setTruecolorSupport(enabled: bool) void {
    truecolor_enabled = enabled;
}

pub fn initTheme(light: bool, terminal_bg: ?TerminalRgb) void {
    is_light = light;
    active_terminal_background = terminal_bg;
    assistant_presentation.setInlineCodeTheme(light);
    if (light) {
        input_bar_style = "";
        divider_style = "\x1b[38;5;250m";
        hint_style = "\x1b[38;5;235m";
        statusline_style = "\x1b[38;5;241m";
        tag_style = "\x1b[1;38;5;235m";
        subtitle_style = "\x1b[1;38;5;235m";
        system_notice_label_style = "\x1b[1;38;5;238m";
        system_notice_text_style = "\x1b[38;5;241m";
        dim_style = "\x1b[38;5;247m";
        warning_style = "\x1b[38;5;238m";
        green_style = "\x1b[38;5;238m";
        red_style = "\x1b[38;5;238m";
        diff_added_style = "\x1b[38;5;238m";
        diff_removed_style = "\x1b[38;5;238m";
        approval_button_active_style = "\x1b[48;5;236m\x1b[38;5;255m\x1b[1m";
        approval_button_inactive_style = "\x1b[48;5;251m\x1b[38;5;237m";
        selected_completion_style = "\x1b[1;38;5;235m";
        permission_auto_style = "\x1b[38;5;238m";
    } else {
        input_bar_style = "";
        divider_style = "\x1b[38;5;240m";
        hint_style = "\x1b[38;5;255m";
        statusline_style = "\x1b[38;5;245m";
        tag_style = "\x1b[1;38;5;255m";
        subtitle_style = "\x1b[1;38;5;255m";
        system_notice_label_style = "\x1b[1;38;5;252m";
        system_notice_text_style = "\x1b[38;5;250m";
        dim_style = "\x1b[38;5;245m";
        warning_style = "\x1b[38;5;252m";
        green_style = "\x1b[38;5;252m";
        red_style = "\x1b[38;5;252m";
        diff_added_style = "\x1b[38;5;252m";
        diff_removed_style = "\x1b[38;5;252m";
        approval_button_active_style = "\x1b[48;5;255m\x1b[38;5;235m\x1b[1m";
        approval_button_inactive_style = "\x1b[48;5;239m\x1b[38;5;255m";
        selected_completion_style = "\x1b[1;38;5;255m";
        permission_auto_style = "\x1b[38;5;252m";
    }

    // The diff marker green/red reads the same on light and dark, so it is set
    // once here rather than per-theme.
    if (truecolor_enabled) {
        diff_added_marker_style = diff_added_marker_truecolor;
        diff_removed_marker_style = diff_removed_marker_truecolor;
    } else {
        diff_added_marker_style = diff_added_marker_fallback;
        diff_removed_marker_style = diff_removed_marker_fallback;
    }

    // Delegate bar shade computation to the card module — it owns the logic
    // that derives a subtle but visible shade from the terminal's actual bg.
    user_message_card.setTruecolor(truecolor_enabled);
    user_message_card.setStyle(light, terminal_bg);
    input_bar_style = user_message_card.user_message_style;
}

pub fn themeNeedsUpdate(light: bool, terminal_bg: ?TerminalRgb) bool {
    if (light != is_light) return true;
    const background = terminal_bg orelse return false;
    const current = active_terminal_background orelse return true;
    return current.r != background.r or current.g != background.g or current.b != background.b;
}

// Explicit theme overrides skip OSC 11, leaving `rgb` null for fallback shading.
pub const ThemeDetection = theme_detection.Detection;
pub const TerminalBackground = theme_protocol.Background;
pub const explicitThemeOverride = theme_detection.explicitThemeOverride;
pub const detectTheme = theme_detection.detectTheme;
pub const parseOsc11Response = theme_protocol.parseOsc11Response;
pub const truecolorSupportedForValues = theme_protocol.truecolorSupportedForValues;

pub const InputLineView = struct {
    line: []const u8,
    cursor_col: u16,
};

pub const MultilineInfo = struct {
    total_lines: u16,
    cursor_line: u16,
};

pub fn countMultilineInfo(input: []const u8, cursor: usize, width: u16) MultilineInfo {
    const summary = visual_layout.summarize(.{ .input = input, .cursor = cursor, .terminal_cols = width }, null);
    return .{
        .total_lines = @intCast(@min(summary.total_rows, std.math.maxInt(u16))),
        .cursor_line = @intCast(@min(summary.cursor.row_index, std.math.maxInt(u16))),
    };
}

pub fn buildInputLineForRow(input: []const u8, cursor: usize, line_index: usize, total_lines: usize, width: u16, out: []u8) InputLineView {
    if (width == 0 or out.len == 0) return .{ .line = "", .cursor_col = 1 };

    const source = visual_layout.Source{ .input = input, .cursor = cursor, .terminal_cols = width };
    const summary = visual_layout.summarize(source, null);
    const visible_rows = @max(total_lines, 1);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, visible_rows);
    const actual_row = window.first_row + line_index;
    const line = copyVisualRowToBuffer(source, actual_row, out);
    return .{
        .line = line,
        .cursor_col = if (summary.cursor.row_index == actual_row) visual_layout.terminalColumn(summary.cursor, width) else 0,
    };
}

pub fn welcomeMessage(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}𝒇x{s}{s} v{s} · Run /help for commands" ++ reset_style ++ "\n\n",
        .{ subtitle_style, reset_style, dim_style, main.version },
    );
}

pub const StatuslineItems = struct {
    workspace_label: []const u8 = "",
    git_branch: ?[]const u8 = null,
    sandbox_label: ?[]const u8 = null,
    context_used: u64 = 0,
    context_total: ?u32 = null,
    session_title: ?[]const u8 = null,
};

/// Cell budget for the session title segment. The title is capped at 8 words
/// upstream, so this only bounds pathological single-word titles.
const max_session_title_cells: usize = 32;

fn compactModelLabel(model: []const u8, out: []u8) []const u8 {
    var start: usize = 0;
    for (model, 0..) |byte, i| {
        if (byte == '/') start = i + 1;
    }
    const bare = model[start..];

    const claude_prefix = "claude-";
    if (!std.mem.startsWith(u8, bare, claude_prefix)) return bare;
    const claude_name = bare[claude_prefix.len..];

    inline for (&.{
        .{ "opus-", "opus " },
        .{ "sonnet-", "sonnet " },
        .{ "haiku-", "haiku " },
    }) |mapping| {
        const prefix = mapping[0];
        const label = mapping[1];
        if (std.mem.startsWith(u8, claude_name, prefix)) {
            return std.fmt.bufPrint(out, "{s}{s}", .{ label, claude_name[prefix.len..] }) catch bare;
        }
    }

    return claude_name;
}

fn permissionModeStatusLabel(mode: types.PermissionMode, out: []u8) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => std.fmt.bufPrint(out, "{s}auto{s}", .{ permission_auto_style, statusline_style }) catch "auto",
        .yolo => std.fmt.bufPrint(out, "{s}YOLO{s}", .{ permission_auto_style, statusline_style }) catch "YOLO",
    };
}

fn appendStatusSegment(out: []u8, end: *usize, segment: []const u8) void {
    if (segment.len == 0) return;
    const sep = " · ";
    const sep_len = if (end.* > 0) sep.len else 0;
    if (end.* + sep_len + segment.len > out.len) return;

    if (sep_len > 0) {
        @memcpy(out[end.* .. end.* + sep.len], sep);
        end.* += sep.len;
    }
    @memcpy(out[end.* .. end.* + segment.len], segment);
    end.* += segment.len;
}

const statusline_separator = " · ";

fn leadingPermissionModeFits(
    limit: usize,
    permission_label: []const u8,
    model_label: []const u8,
) bool {
    if (limit == 0) return false;
    return display_width.visibleWidthIgnoringAnsi(permission_label) +
        display_width.visibleWidth(statusline_separator) +
        display_width.visibleWidth(model_label) <= limit;
}

const ClippedSegment = struct {
    bytes: []const u8,
    marker_before: bool = false,
    marker_after: bool = false,
};

fn clippedWorkspaceSuffix(encoded: []const u8, max_width: usize) ClippedSegment {
    if (display_width.visibleWidth(encoded) <= max_width) return .{ .bytes = encoded };
    if (max_width <= 1) return .{ .bytes = "", .marker_before = max_width == 1 };
    return .{
        .bytes = text_utils.suffixTerminalSafeByWidth(encoded, max_width - 1),
        .marker_before = true,
    };
}

fn clippedBranchPrefix(encoded: []const u8, max_width: usize) ClippedSegment {
    if (display_width.visibleWidth(encoded) <= max_width) return .{ .bytes = encoded };
    if (max_width <= 1) return .{ .bytes = "", .marker_after = max_width == 1 };
    return .{
        .bytes = text_utils.prefixTerminalSafeByWidth(encoded, max_width - 1),
        .marker_after = true,
    };
}

fn appendIdentityBytes(out: []u8, end: *usize, bytes: []const u8) bool {
    if (end.* + bytes.len > out.len) return false;
    @memcpy(out[end.* .. end.* + bytes.len], bytes);
    end.* += bytes.len;
    return true;
}

fn appendClippedIdentityPart(
    out: []u8,
    end: *usize,
    clipped: ClippedSegment,
) bool {
    if (clipped.marker_before and !appendIdentityBytes(out, end, "…")) return false;
    if (!appendIdentityBytes(out, end, clipped.bytes)) return false;
    if (clipped.marker_after and !appendIdentityBytes(out, end, "…")) return false;
    return true;
}

fn composeWorkspaceIdentity(
    statusline: StatuslineItems,
    max_width: usize,
    out: []u8,
) ?[]const u8 {
    if (statusline.workspace_label.len == 0 or max_width == 0) return null;

    var width_budget = @min(max_width, out.len);
    while (width_budget > 0) : (width_budget -= 1) {
        var end: usize = 0;
        if (statusline.git_branch) |branch| {
            if (branch.len > 0) {
                // Below seven cells, showing fragments of both values is less
                // useful than retaining the working-directory tail alone.
                if (width_budget >= 7) {
                    const branch_width = display_width.visibleWidth(branch);
                    const max_branch_width = width_budget - 4;
                    const branch_budget = @min(
                        branch_width,
                        @min(max_branch_width, @max(@as(usize, 4), width_budget / 2)),
                    );
                    const path_budget = width_budget - 3 - branch_budget;
                    const path = clippedWorkspaceSuffix(statusline.workspace_label, path_budget);
                    const branch_label = clippedBranchPrefix(branch, branch_budget);
                    if (appendClippedIdentityPart(out, &end, path) and
                        appendIdentityBytes(out, &end, " (") and
                        appendClippedIdentityPart(out, &end, branch_label) and
                        appendIdentityBytes(out, &end, ")"))
                    {
                        return out[0..end];
                    }
                    continue;
                }
            }
        }

        const path = clippedWorkspaceSuffix(statusline.workspace_label, width_budget);
        if (appendClippedIdentityPart(out, &end, path)) return out[0..end];
    }
    return null;
}

fn appendWorkspaceIdentity(
    out: []u8,
    end: *usize,
    status_limit: usize,
    statusline: StatuslineItems,
) void {
    if (statusline.workspace_label.len == 0) return;
    const used_width = display_width.visibleWidthIgnoringAnsi(out[0..end.*]);
    const separator_width = if (end.* > 0)
        display_width.visibleWidth(statusline_separator)
    else
        0;
    if (used_width + separator_width >= status_limit) return;

    const separator_bytes = if (end.* > 0) statusline_separator.len else 0;
    if (end.* + separator_bytes >= out.len) return;
    const available_width = status_limit - used_width - separator_width;
    const available_bytes = out.len - end.* - separator_bytes;
    var identity_buf: [512]u8 = undefined;
    const identity = composeWorkspaceIdentity(
        statusline,
        available_width,
        identity_buf[0..@min(identity_buf.len, available_bytes)],
    ) orelse return;
    appendStatusSegment(out, end, identity);
}

pub fn buildHintLine(
    stream_active: bool,
    awaiting_permission: bool,
    has_api_key: bool,
    model: []const u8,
    permission_mode: types.PermissionMode,
    queued_count: usize,
    active_label: ?[]const u8,
    fast_mode: bool,
    model_supports_fast: bool,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    statusline: StatuslineItems,
    width: u16,
    out: []u8,
) []const u8 {
    _ = active_label;
    _ = stream_active;

    var model_buf: [96]u8 = undefined;
    const model_label = compactModelLabel(model, &model_buf);
    var permission_buf: [64]u8 = undefined;
    const permission_label = permissionModeStatusLabel(permission_mode, &permission_buf);

    var end: usize = 0;
    if (!awaiting_permission and !has_api_key) {
        appendStatusSegment(out, &end, "run /login");
    }
    if (!awaiting_permission and queued_count > 0) {
        var queued_buf: [32]u8 = undefined;
        appendStatusSegment(out, &end, std.fmt.bufPrint(&queued_buf, "queued {d}", .{queued_count}) catch "");
    }
    const status_limit = @min(@as(usize, width), out.len);
    const show_effort = model_supports_effort and !effort.isDefault();
    const show_fast = model_supports_fast and fast_mode;
    if (leadingPermissionModeFits(status_limit, permission_label, model_label)) {
        appendStatusSegment(out, &end, permission_label);
    }
    appendStatusSegment(out, &end, model_label);
    if (show_effort) {
        appendStatusSegment(out, &end, effort.displayLabel());
    }
    if (show_fast) {
        appendStatusSegment(out, &end, "⚡︎");
    }

    if (statusline.session_title) |title| {
        appendStatusSegment(out, &end, display_width.prefixByWidth(title, max_session_title_cells));
    }

    if (statusline.sandbox_label) |sb_label| {
        var sandbox_buf: [64]u8 = undefined;
        appendStatusSegment(out, &end, std.fmt.bufPrint(&sandbox_buf, "sandbox:{s}", .{sb_label}) catch "");
    }

    if (statusline.context_used > 0) {
        if (statusline.context_total) |total| {
            const used_k = statusline.context_used / 1000;
            const total_k: u64 = @as(u64, total) / 1000;
            const pct = if (total > 0) (statusline.context_used * 100) / @as(u64, total) else 0;
            var ctx_buf: [48]u8 = undefined;
            appendStatusSegment(out, &end, std.fmt.bufPrint(&ctx_buf, "Context: {d}k/{d}k {d}%", .{ used_k, total_k, pct }) catch "");
        } else {
            const used_k = statusline.context_used / 1000;
            var ctx_buf: [32]u8 = undefined;
            appendStatusSegment(out, &end, std.fmt.bufPrint(&ctx_buf, "Context: {d}k", .{used_k}) catch "");
        }
    }
    appendWorkspaceIdentity(out, &end, status_limit, statusline);

    const width_usize: usize = width;
    if (width_usize == 0) return "";
    return display_width.prefixByWidthIgnoringAnsi(out[0..end], width_usize);
}

pub fn buildInputLine(input: []const u8, cursor: usize, width: u16, out: []u8) InputLineView {
    const ml = countMultilineInfo(input, cursor, width);
    return buildInputLineForRow(input, cursor, ml.cursor_line, ml.total_lines, width, out);
}

pub fn inputColumnForIndex(input: []const u8, cursor: usize, target: usize, width: u16) u16 {
    const summary = visual_layout.summarize(.{ .input = input, .cursor = cursor, .terminal_cols = width }, target);
    return visual_layout.projectedAnchorColumn(summary, width);
}

fn copyVisualRowToBuffer(source: visual_layout.Source, target_row: usize, out: []u8) []const u8 {
    if (source.terminal_cols == 0 or out.len == 0) return "";

    var len: usize = 0;
    var row_started = false;
    var remaining_cells: usize = 0;
    var omitted_positive_unit = false;
    var it = visual_layout.iterator(source);
    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index < target_row) continue;
            if (unit.row_index > target_row) break;
            startVisualRow(source.terminal_cols, target_row, out, &len, &row_started, &remaining_cells);
            if (remaining_cells == 0) continue;
            switch (unit.kind) {
                .text => {
                    if (unit.cell_width == 0) {
                        if (!omitted_positive_unit) appendBytesToBuffer(out, &len, source.input[unit.raw_start..unit.raw_end]);
                    } else if (unit.cell_width <= remaining_cells) {
                        appendBytesToBuffer(out, &len, source.input[unit.raw_start..unit.raw_end]);
                        remaining_cells -= unit.cell_width;
                        omitted_positive_unit = false;
                    } else {
                        omitted_positive_unit = true;
                    }
                },
                .paste_placeholder => {
                    const visible = display_width.prefixByWidth(
                        source.input[unit.raw_start..unit.raw_end],
                        remaining_cells,
                    );
                    appendBytesToBuffer(out, &len, visible);
                    const emitted_width = display_width.visibleWidth(visible);
                    remaining_cells -= emitted_width;
                    omitted_positive_unit = emitted_width < unit.cell_width;
                },
                .tab => {
                    if (unit.cell_width > 0 and unit.cell_width <= remaining_cells) {
                        appendSpacesToBuffer(out, &len, unit.cell_width);
                        remaining_cells -= unit.cell_width;
                        omitted_positive_unit = false;
                    } else if (unit.cell_width > 0) {
                        omitted_positive_unit = true;
                    }
                },
                .skill_token => |token_index| {
                    const token = source.skill_tokens[token_index];
                    if (unit.cell_width <= remaining_cells) {
                        appendBytesToBuffer(out, &len, token.name);
                        if (visual_layout.skillTokenSourceLabel(token)) |source_label| {
                            appendBytesToBuffer(out, &len, visual_layout.skill_source_separator);
                            appendBytesToBuffer(out, &len, source_label);
                        }
                        remaining_cells -= unit.cell_width;
                        omitted_positive_unit = false;
                    } else {
                        omitted_positive_unit = true;
                    }
                },
                .image_badge => {},
            }
        },
        .row_end => |row| {
            if (row.index < target_row) continue;
            if (row.index == target_row) startVisualRow(source.terminal_cols, target_row, out, &len, &row_started, &remaining_cells);
            break;
        },
    };
    return out[0..len];
}

fn startVisualRow(width: u16, row_index: usize, out: []u8, len: *usize, started: *bool, remaining_cells: *usize) void {
    if (started.*) return;
    started.* = true;
    const prefix = visual_layout.inputPrefix(row_index);
    const clipped = display_width.prefixByWidth(prefix.bytes, width);
    appendBytesToBuffer(out, len, clipped);
    const width_usize: usize = width;
    remaining_cells.* = if (width_usize > prefix.cell_width) width_usize - prefix.cell_width else 0;
}

fn appendBytesToBuffer(out: []u8, len: *usize, bytes: []const u8) void {
    if (bytes.len > out.len - len.*) return;
    @memcpy(out[len.* .. len.* + bytes.len], bytes);
    len.* += bytes.len;
}

fn appendSpacesToBuffer(out: []u8, len: *usize, count: usize) void {
    var i: usize = 0;
    while (i < count and len.* < out.len) : (i += 1) {
        out[len.*] = ' ';
        len.* += 1;
    }
}

pub fn isPrintableAscii(byte: u8) bool {
    return byte >= 32 and byte <= 126;
}

test "input line wraps to the cursor row" {
    var buf: [64]u8 = undefined;
    const view = buildInputLine("abcdefghijklmnopqrstuvwxyz", 26, 16, &buf);
    try std.testing.expectEqualStrings("  opqrstuvwxyz", view.line);
    try std.testing.expectEqual(@as(u16, 15), view.cursor_col);
}

test "input line wraps without cutting emoji bytes" {
    var buf: [64]u8 = undefined;
    const view = buildInputLine("a😀b", "a😀b".len, 5, &buf);
    try std.testing.expectEqualStrings("  b", view.line);
    try std.testing.expectEqual(@as(u16, 4), view.cursor_col);
}

test "wrapped input row builder exposes all visual rows" {
    var buf: [64]u8 = undefined;
    const input = "abcdefgh";
    const ml = countMultilineInfo(input, input.len, 6);
    try std.testing.expectEqual(@as(u16, 2), ml.total_lines);
    try std.testing.expectEqual(@as(u16, 1), ml.cursor_line);

    const first = buildInputLineForRow(input, input.len, 0, ml.total_lines, 6, &buf);
    try std.testing.expectEqualStrings("❯ abcd", first.line);
    try std.testing.expectEqual(@as(u16, 0), first.cursor_col);

    const second = buildInputLineForRow(input, input.len, 1, ml.total_lines, 6, &buf);
    try std.testing.expectEqualStrings("  efgh", second.line);
    try std.testing.expectEqual(@as(u16, 6), second.cursor_col);
}

test "hard newline keeps cursor at end of previous row" {
    var buf: [64]u8 = undefined;
    const input = "abc\ndef";
    const view = buildInputLine(input, 3, 20, &buf);
    try std.testing.expectEqualStrings("❯ abc", view.line);
    try std.testing.expectEqual(@as(u16, 6), view.cursor_col);
}

test "inputColumnForIndex aligns active token under input" {
    const input = "/model openai/gpt-5 high";
    const col = inputColumnForIndex(input, input.len, "/model openai/gpt-5 ".len, 80);
    try std.testing.expectEqual(@as(u16, 23), col);
}

test "render geometry wrappers match visual layout projections" {
    const input = "abc\ndefgh";
    const source = visual_layout.Source{ .input = input, .cursor = input.len, .terminal_cols = 6 };
    const summary = visual_layout.summarize(source, "abc\n".len + 1);
    const ml = countMultilineInfo(input, input.len, 6);
    try std.testing.expectEqual(@as(u16, @intCast(summary.total_rows)), ml.total_lines);
    try std.testing.expectEqual(@as(u16, @intCast(summary.cursor.row_index)), ml.cursor_line);
    try std.testing.expectEqual(visual_layout.projectedAnchorColumn(summary, 6), inputColumnForIndex(input, input.len, "abc\n".len + 1, 6));

    try std.testing.expectEqual(@as(u16, 3), visual_layout.terminalColumn(.{ .raw_offset = 0, .row_index = 0, .content_column = 0 }, 80));
    try std.testing.expectEqual(@as(u16, 3), visual_layout.terminalColumn(.{ .raw_offset = 0, .row_index = 1, .content_column = 0 }, 80));
    try std.testing.expectEqual(@as(u16, 6), visual_layout.terminalColumn(.{ .raw_offset = 3, .row_index = 0, .content_column = 3 }, 80));
}

test "render row window stays cursor-containing for direct and restored input" {
    var buf: [128]u8 = undefined;
    inline for (.{ "x" ** 4096, "y" ** 5000 }) |input| {
        const summary = visual_layout.summarize(.{ .input = input, .cursor = input.len, .terminal_cols = 80 }, null);
        const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 4);
        try std.testing.expect(window.first_row <= summary.cursor.row_index);
        try std.testing.expect(summary.cursor.row_index < window.first_row + window.row_count);

        const view = buildInputLineForRow(input, input.len, 3, 4, 80, &buf);
        try std.testing.expect(std.mem.startsWith(u8, view.line, "  "));
        try std.testing.expect(view.cursor_col > 0);
    }
}

test "render soft-wrap boundary and earlier anchors use cursor row columns" {
    var buf: [64]u8 = undefined;
    const input = "abcd";
    const view = buildInputLine(input, 3, 5, &buf);
    try std.testing.expectEqualStrings("  d", view.line);
    try std.testing.expectEqual(@as(u16, 3), view.cursor_col);

    const earlier_anchor_col = inputColumnForIndex("abcdef", 5, 1, 5);
    try std.testing.expectEqual(@as(u16, 3), earlier_anchor_col);
}

test "render tabs use visual layout absolute tab stops" {
    const input = "\tX";
    const summary = visual_layout.summarize(.{ .input = input, .cursor = 1, .terminal_cols = 10 }, 1);
    try std.testing.expectEqual(@as(u16, 9), visual_layout.projectedAnchorColumn(summary, 10));
    try std.testing.expectEqual(@as(u16, 9), inputColumnForIndex(input, 1, 1, 10));

    const wrapped = "aaaaaa\tXY";
    const wrapped_summary = visual_layout.summarize(.{ .input = wrapped, .cursor = wrapped.len, .terminal_cols = 10 }, wrapped.len - 1);
    try std.testing.expectEqual(visual_layout.projectedAnchorColumn(wrapped_summary, 10), inputColumnForIndex(wrapped, wrapped.len, wrapped.len - 1, 10));
}

test "render width zero emits no row bytes and first cursor column" {
    var buf: [8]u8 = undefined;
    const view = buildInputLine("abc", 3, 0, &buf);
    try std.testing.expectEqualStrings("", view.line);
    try std.testing.expectEqual(@as(u16, 1), view.cursor_col);
}

/// Writes the title to the same file the transcript renders to, so a host
/// that redirects its output keeps the escape sequence out of the real
/// stdout. `out` must outlive every call.
pub fn terminalTitleFor(out: *const std.Io.File) host.TerminalTitle {
    return .{
        .context = @constCast(out),
        .set_fn = setTerminalTitleLabel,
        .clear_fn = clearTerminalTitleProvider,
    };
}

fn titleOutput(raw: ?*anyopaque) std.Io.File {
    const out: *const std.Io.File = @ptrCast(@alignCast(raw.?));
    return out.*;
}

const terminal_title_osc_prefix = "\x1b]2;";
const terminal_title_display_prefix = "fx · ";
const terminal_title_max_content_bytes: usize = 128;
const terminal_title_max_label_bytes = terminal_title_max_content_bytes - terminal_title_display_prefix.len;

fn sanitizedTerminalTitleLabel(raw: []const u8, buffer: *[terminal_title_max_label_bytes]u8) []const u8 {
    const marker = "...";
    var source_index: usize = 0;
    var written: usize = 0;
    while (source_index < raw.len) {
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(raw[source_index]) catch {
            source_index += 1;
            continue;
        };
        if (raw.len - source_index < sequence_len) break;
        const sequence = raw[source_index .. source_index + sequence_len];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            source_index += 1;
            continue;
        };
        source_index += sequence_len;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) continue;
        if (written + sequence_len > buffer.len) {
            written = text_utils.utf8BackwardBoundary(buffer[0..written], buffer.len - marker.len);
            @memcpy(buffer[written .. written + marker.len], marker);
            written += marker.len;
            break;
        }
        @memcpy(buffer[written .. written + sequence_len], sequence);
        written += sequence_len;
    }
    return buffer[0..written];
}

fn setTerminalTitleLabel(raw: ?*anyopaque, label: []const u8) void {
    const out = titleOutput(raw);
    var label_buffer: [terminal_title_max_label_bytes]u8 = undefined;
    const sanitized = sanitizedTerminalTitleLabel(label, &label_buffer);
    var sequence_buffer: [terminal_title_osc_prefix.len + terminal_title_max_content_bytes + 1]u8 = undefined;
    var sequence: std.Io.Writer = .fixed(&sequence_buffer);
    sequence.writeAll(terminal_title_osc_prefix) catch return;
    sequence.writeAll(terminal_title_display_prefix) catch return;
    sequence.writeAll(sanitized) catch return;
    sequence.writeByte('\x07') catch return;
    out.writeStreamingAll(io_mod.getIo(), sequence.buffered()) catch return;
}

fn clearTerminalTitleProvider(raw: ?*anyopaque) void {
    const out = titleOutput(raw);
    out.writeStreamingAll(io_mod.getIo(), "\x1b]2;\x07") catch return;
}

test "terminal title writes the label to the caller's output file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "terminal-title.log", .{});
    defer sink.close(io_mod.getIo());

    // A host that redirects its output keeps the escape sequence off the
    // real stdout, which the Zig test runner owns as its protocol channel.
    terminalTitleFor(&sink).set("release notes");

    var written_file = try tmp.dir.openFile(io_mod.getIo(), "terminal-title.log", .{});
    defer written_file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &written_file, 128);
    defer alloc.free(written);
    try std.testing.expectEqualStrings("\x1b]2;fx · release notes\x07", written);
}

test "terminal title sanitizes and bounds untrusted labels" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "terminal-title-hostile.log", .{});
    defer sink.close(io_mod.getIo());

    terminalTitleFor(&sink).set("safe\x07\x1b]2;owned\xc2\x9b" ++ ("é" ** 80));

    var written_file = try tmp.dir.openFile(io_mod.getIo(), "terminal-title-hostile.log", .{});
    defer written_file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &written_file, 512);
    defer alloc.free(written);
    try std.testing.expect(written.len <= terminal_title_osc_prefix.len + terminal_title_max_content_bytes + 1);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]2;fx · safe]2;owned"));
    try std.testing.expect(std.mem.endsWith(u8, written, "...\x07"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\x07"));
    try std.testing.expect(std.mem.find(u8, written[terminal_title_osc_prefix.len..], "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, written, "\xc2\x9b") == null);
}

test "terminal title clear restores a predictable empty state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "terminal-title-clear.log", .{});
    defer sink.close(io_mod.getIo());

    terminalTitleFor(&sink).clear();

    var written_file = try tmp.dir.openFile(io_mod.getIo(), "terminal-title-clear.log", .{});
    defer written_file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &written_file, 32);
    defer alloc.free(written);
    try std.testing.expectEqualStrings("\x1b]2;\x07", written);
}

pub fn formatResumeHandoff(
    buffer: []u8,
    session_id: []const u8,
    terminal_cols: u16,
) ![]const u8 {
    const label = "Continue session with:";
    const command = "fx --resume ";
    const single_row_width = label.len + 1 + command.len + session_id.len;
    const separator = if (single_row_width <= terminal_cols) " " else "\n  ";
    return std.fmt.bufPrint(
        buffer,
        "{s}{s}{s}{s}{s}{s}\n",
        .{ dim_style, label, separator, command, session_id, reset_style },
    );
}

test "initTheme sets light mode styles" {
    initTheme(true, null);
    try std.testing.expect(is_light);
    try std.testing.expect(!std.mem.eql(u8, subtitle_style, "\x1b[1;38;5;255m"));
    try std.testing.expectEqualStrings("\x1b[48;5;255m\x1b[38;5;16m", input_bar_style);

    initTheme(false, null);
    try std.testing.expect(!is_light);
    try std.testing.expectEqualStrings("\x1b[1;38;5;255m", subtitle_style);
    try std.testing.expectEqualStrings("\x1b[48;5;238m\x1b[38;5;250m", input_bar_style);
}

test "resume handoff uses one row only when the full instruction fits" {
    initTheme(false, null);
    defer initTheme(false, null);

    const single_row = "Continue session with: fx --resume session-123";
    var exact_buffer: [128]u8 = undefined;
    const exact = try formatResumeHandoff(&exact_buffer, "session-123", single_row.len);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;245mContinue session with: fx --resume session-123\x1b[0m\n",
        exact,
    );

    var narrow_buffer: [128]u8 = undefined;
    const narrow = try formatResumeHandoff(&narrow_buffer, "session-123", single_row.len - 1);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;245mContinue session with:\n  fx --resume session-123\x1b[0m\n",
        narrow,
    );
}

test "resume handoff follows the active muted theme shade" {
    initTheme(true, null);
    defer initTheme(false, null);

    var buffer: [128]u8 = undefined;
    const message = try formatResumeHandoff(&buffer, "session-123", 80);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;247mContinue session with: fx --resume session-123\x1b[0m\n",
        message,
    );
}

test "themeNeedsUpdate compares the active terminal background" {
    initTheme(false, .{ .r = 20, .g = 21, .b = 22 });
    defer initTheme(false, null);

    try std.testing.expect(!themeNeedsUpdate(false, null));
    try std.testing.expect(!themeNeedsUpdate(false, .{ .r = 20, .g = 21, .b = 22 }));
    try std.testing.expect(themeNeedsUpdate(false, .{ .r = 21, .g = 21, .b = 22 }));
    try std.testing.expect(themeNeedsUpdate(true, null));
}

test "initTheme selects the light inline code foreground" {
    const alloc = std.testing.allocator;
    assistant_presentation.setInlineCodeTheme(false);
    defer initTheme(false, null);

    initTheme(true, null);

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "run `zig build` now\n", &out);
    try std.testing.expectEqualStrings("run \x1b[38;5;247mzig build\x1b[39m now\n", out.items);
}

test "welcomeMessage shows version and help hint" {
    const message = try welcomeMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.find(u8, message, "𝒇x") != null);
    try std.testing.expect(std.mem.find(u8, message, main.version) != null);
    try std.testing.expect(std.mem.find(u8, message, "/help") != null);
}

test "welcomeMessage keeps only the app name bright" {
    initTheme(false, null);
    const message = try welcomeMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}𝒇x{s}{s} v{s} · Run /help for commands" ++ reset_style ++ "\n\n",
        .{ subtitle_style, reset_style, dim_style, main.version },
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, message);
}

test "buildHintLine hides effort when it is auto" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "anthropic/claude-opus-4.7", .ask, 0, null, false, true, .auto, true, .{}, 80, &buf);
    try std.testing.expectEqualStrings("ask · opus 4.7", line);
}

test "buildHintLine hides effort for models without effort support" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-4o", .ask, 0, null, false, false, .auto, false, .{}, 80, &buf);
    try std.testing.expectEqualStrings("ask · gpt-4o", line);
}

test "buildHintLine uses a monochrome lightning marker for fast mode" {
    initTheme(false, null);
    defer initTheme(false, null);

    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "anthropic/claude-opus-4.8", .ask, 0, null, true, true, types.ReasoningEffort.literal("low"), true, .{}, 80, &buf);
    try std.testing.expectEqualStrings("ask · opus 4.8 · low · ⚡︎", line);
    try std.testing.expectEqual(@as(usize, 25), display_width.visibleWidthIgnoringAnsi(line));
}

test "buildHintLine shows effort when active" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, types.ReasoningEffort.literal("high"), true, .{}, 80, &buf);
    try std.testing.expectEqualStrings("ask · gpt-5 · high", line);
}

test "buildHintLine shows full context usage" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "anthropic/claude-opus-4.8", .ask, 0, null, false, true, .auto, true, .{
        .context_used = 43_000,
        .context_total = 1_000_000,
    }, 80, &buf);
    try std.testing.expectEqualStrings("ask · opus 4.8 · Context: 43k/1000k 4%", line);
}

test "buildHintLine shows the session title before sandbox and context" {
    var buf: [256]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .session_title = "add a session name display",
        .sandbox_label = "none",
    }, 200, &buf);
    try std.testing.expectEqualStrings(
        "ask · gpt-5 · add a session name display · sandbox:none",
        line,
    );
}

test "buildHintLine clips an overlong session title on a character boundary" {
    var buf: [256]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .session_title = "ααααααααααααααααααααααααααααααααααααααααα",
    }, 200, &buf);
    try std.testing.expect(std.mem.startsWith(u8, line, "ask · gpt-5 · "));
    const title = line["ask · gpt-5 · ".len..];
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));
    try std.testing.expectEqual(@as(usize, 32), display_width.visibleWidth(title));
}

test "buildHintLine omits the session segment when no title is cached" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .session_title = null,
    }, 80, &buf);
    try std.testing.expectEqualStrings("ask · gpt-5", line);
}

test "buildHintLine shows the workspace and Git branch" {
    var buf: [256]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .workspace_label = "/workspace/code/fx",
        .git_branch = "feature/statusline",
    }, 100, &buf);
    try std.testing.expectEqualStrings(
        "ask · gpt-5 · /workspace/code/fx (feature/statusline)",
        line,
    );
}

test "buildHintLine keeps workspace and branch readable at narrow widths" {
    var buf: [256]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .workspace_label = "/a/very/long/path/to/fx-repo",
        .git_branch = "feature/statusline",
    }, 36, &buf);
    try std.testing.expectEqual(@as(usize, 36), display_width.visibleWidthIgnoringAnsi(line));
    try std.testing.expect(std.mem.startsWith(u8, line, "ask · gpt-5 · "));
    try std.testing.expect(std.mem.find(u8, line, "fx-repo") != null);
    try std.testing.expect(std.mem.find(u8, line, "feature/") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "…)"));
}

test "buildHintLine workspace identity does not displace existing status segments" {
    var buf: [256]u8 = undefined;
    const line = buildHintLine(false, false, true, "anthropic/claude-opus-4.8", .auto, 0, null, true, true, types.ReasoningEffort.literal("xhigh"), true, .{
        .workspace_label = "/a/very/long/path/to/the/active/workspace",
        .git_branch = "feature/statusline",
        .context_used = 1_000,
        .context_total = 100_000,
    }, 60, &buf);
    try std.testing.expect(std.mem.find(u8, line, "xhigh") != null);
    try std.testing.expect(std.mem.find(u8, line, "⚡︎") != null);
    try std.testing.expect(std.mem.find(u8, line, "Context: 1k/100k 1%") != null);
}

test "buildHintLine shows a non-Git workspace without branch punctuation" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .workspace_label = "/tmp/plain-workspace",
    }, 80, &buf);
    try std.testing.expectEqualStrings(
        "ask · gpt-5 · /tmp/plain-workspace",
        line,
    );
}

test "buildHintLine labels detached HEAD" {
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-5", .ask, 0, null, false, false, .auto, false, .{
        .workspace_label = "/tmp/fx",
        .git_branch = "detached:0123456789ab",
    }, 80, &buf);
    try std.testing.expectEqualStrings(
        "ask · gpt-5 · /tmp/fx (detached:0123456789ab)",
        line,
    );
}

test "buildHintLine keeps system labels and dot separators" {
    var buf: [256]u8 = undefined;
    const line = buildHintLine(false, false, false, "anthropic/claude-opus-4.8", .auto, 2, null, true, true, types.ReasoningEffort.literal("low"), true, .{
        .sandbox_label = "none",
        .context_used = 43_000,
        .context_total = 1_000_000,
    }, 256, &buf);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "run /login · queued 2 · {s}auto{s} · opus 4.8 · low · ⚡︎ · sandbox:none · Context: 43k/1000k 4%",
        .{ permission_auto_style, statusline_style },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(
        expected,
        line,
    );
}

test "buildHintLine skips an over-capacity segment without a dangling dot" {
    var buf: [16]u8 = undefined;
    const line = buildHintLine(false, false, true, "anthropic/claude-opus-4.7", .ask, 0, null, true, true, .auto, true, .{}, 80, &buf);
    try std.testing.expectEqualStrings("ask · opus 4.7", line);
}

test "buildHintLine colors auto mode with theme accent" {
    initTheme(false, null);
    const dark_accent = permission_auto_style;
    const dark_status = statusline_style;
    var dark_buf: [128]u8 = undefined;
    const dark_line = buildHintLine(false, false, true, "openai/gpt-4o", .auto, 0, null, false, false, .auto, false, .{}, 80, &dark_buf);
    const dark_expected = try std.fmt.allocPrint(std.testing.allocator, "{s}auto{s} · gpt-4o", .{ dark_accent, dark_status });
    defer std.testing.allocator.free(dark_expected);
    try std.testing.expectEqualStrings(dark_expected, dark_line);

    initTheme(true, null);
    defer initTheme(false, null);
    try std.testing.expect(!std.mem.eql(u8, permission_auto_style, dark_accent));
    var light_buf: [128]u8 = undefined;
    const light_line = buildHintLine(false, false, true, "openai/gpt-4o", .auto, 0, null, false, false, .auto, false, .{}, 80, &light_buf);
    const light_expected = try std.fmt.allocPrint(std.testing.allocator, "{s}auto{s} · gpt-4o", .{ permission_auto_style, statusline_style });
    defer std.testing.allocator.free(light_expected);
    try std.testing.expectEqualStrings(light_expected, light_line);
}

test "buildHintLine renders yolo uppercase with subdued permission styling" {
    initTheme(false, null);
    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-4o", .yolo, 0, null, false, false, .auto, false, .{}, 80, &buf);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}YOLO{s} · gpt-4o",
        .{ permission_auto_style, statusline_style },
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, line);
}

test "buildHintLine clips styled auto mode by visible width" {
    initTheme(false, null);
    defer initTheme(false, null);

    var buf: [128]u8 = undefined;
    const line = buildHintLine(false, false, true, "openai/gpt-4o", .auto, 0, null, false, false, .auto, false, .{}, 13, &buf);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}auto{s} · gpt-4o", .{ permission_auto_style, statusline_style });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, line);
    try std.testing.expectEqual(@as(usize, 13), display_width.visibleWidthIgnoringAnsi(line));
    try std.testing.expect(std.mem.endsWith(u8, line, "gpt-4o"));
}

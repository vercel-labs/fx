const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const credentials = @import("../../core/auth/credentials.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const mcp_menu_state = @import("../../core/mcp/menu_state.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const types = @import("../../core/shared/types.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const paste_blocks = @import("../../core/input/pasted_blocks.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const visual_layout = @import("../input/visual_layout.zig");
const ui_render = @import("../render.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const InputRuntime = core_input_runtime.Runtime;
const RenderContext = render_input.RenderContext;

const max_status_line_len: usize = 512;
pub const max_top_row_len = row_text.max_top_row_len;
pub const max_model_picker_rows: u16 = list_window.default_max_picker_rows;
pub const composeDividerRow = row_text.composeDividerRow;
pub const appendClipped = row_text.appendClipped;
pub const appendAbsoluteColumn = row_text.appendAbsoluteColumn;

pub const PickerKind = enum { model_stage, provider_stage, models, file, slash, skills, help, settings, sessions, mcp, auth };
pub const CappedInputRows = struct {
    row_limit: usize,
    total_lines: u16,
    input_extra: u16,
};

pub const RawInputGeometry = struct {
    summary: visual_layout.Summary,
    window: visual_layout.VisibleWindow,
    total_lines: u16,
    input_extra: u16,
    slash_completion_count: usize,
    show_slash_query: bool,
    picker_start_col: u16,
};

pub const ComposedInputRows = struct {
    rows: std.ArrayList(std.ArrayList(u8)) = .empty,

    pub fn deinit(self: *ComposedInputRows, alloc: Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
    }
};

pub fn composeSteeringMessageRows(
    alloc: Allocator,
    message: []const u8,
    width: u16,
    row_limit: u16,
    waits_for_tool: bool,
) !ComposedInputRows {
    var composed: ComposedInputRows = .{};
    errdefer composed.deinit(alloc);
    const layout = render_input.steering_message_layout(message, width, waits_for_tool, row_limit);
    for (layout.rows[0..layout.row_count], 0..) |content, index| {
        const normalized = try alloc.dupe(u8, content);
        defer alloc.free(normalized);
        for (normalized) |*byte| {
            if (byte.* == '\t') byte.* = ' ';
        }
        var safe = try text_utils.encodeTerminalSafe(alloc, normalized, std.math.maxInt(usize));
        defer safe.deinit(alloc);

        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, if (waits_for_tool) ui_render.dim_style else ui_render.hint_style);
        if (waits_for_tool) try row_text.appendClipped(alloc, &row, "┋ ", width);
        const ellipsis = layout.truncated and index + 1 == layout.row_count and layout.content_width > 0;
        try row_text.appendClipped(alloc, &row, safe.bytes, layout.content_width - @as(u16, @intFromBool(ellipsis)));
        if (ellipsis) {
            try row.appendSlice(alloc, "…");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        try composed.rows.append(alloc, row);
    }
    return composed;
}

test "steering rows use the dotted rail without an escape hint" {
    var first = try composeSteeringMessageRows(std.testing.allocator, "First steer", 80, 2, true);
    defer first.deinit(std.testing.allocator);
    var second = try composeSteeringMessageRows(std.testing.allocator, "Second steer", 80, 2, true);
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), first.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), second.rows.items.len);
    try std.testing.expect(std.mem.find(u8, first.rows.items[0].items, "┋ First steer") != null);
    try std.testing.expect(std.mem.find(u8, second.rows.items[0].items, "┋ Second steer") != null);
    try std.testing.expect(std.mem.find(u8, first.rows.items[0].items, "Esc to steer now") == null);
    try std.testing.expect(std.mem.find(u8, second.rows.items[0].items, "Esc to steer now") == null);
}

test "steering preview preserves the first two lines and hides the rest" {
    const alloc = std.testing.allocator;
    var rows = try composeSteeringMessageRows(alloc, "what is this\r\nLockfile\tfailed\nHIDDEN_TAIL", 40, 2, true);
    defer rows.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), rows.rows.items.len);
    const first = rows.rows.items[0].items;
    const second = rows.rows.items[1].items;
    try std.testing.expectEqualStrings("┋ what is this", first[ui_render.dim_style.len .. first.len - ui_render.reset_style.len]);
    try std.testing.expectEqualStrings("┋ Lockfile failed…", second[ui_render.dim_style.len .. second.len - ui_render.reset_style.len]);
}

test "steering preview keeps the beginning of long paragraphs" {
    const message = "one two three four five six seven eight nine ten HIDDEN_END";
    var rows = try composeSteeringMessageRows(std.testing.allocator, message, 18, 2, true);
    defer rows.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), rows.rows.items.len);
    try std.testing.expect(std.mem.find(u8, rows.rows.items[0].items, "┋ one two three") != null);
    try std.testing.expect(std.mem.find(u8, rows.rows.items[1].items, "┋ ") != null);
    try std.testing.expect(std.mem.find(u8, rows.rows.items[1].items, "┋ four five six…") != null);
    for (rows.rows.items) |row| {
        try std.testing.expect(std.mem.find(u8, row.items, "HIDDEN_END") == null);
        try std.testing.expect(std.mem.find(u8, row.items, "Esc to steer now") == null);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 18);
    }
}

test "steering preview layout and painted rows agree at narrow widths" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", "first\nsecond\nthird", "alpha\tbeta", "界海語", "é\xff\x1b[2Jtail", "abc\n\ndef", "12\r\n34\r56", "\u{1f469}\u{200d}\u{2764}\u{fe0f}\u{200d}\u{1f48b}\u{200d}\u{1f469}" }) |message| {
        for ([_]u16{ 0, 1, 2, 3, 5, 12, 31, 33, 80 }) |width| {
            for ([_]bool{ false, true }) |waiting| {
                for ([_]u16{ 0, 1, 2 }) |limit| {
                    const layout = render_input.steering_message_layout(message, width, waiting, limit);
                    var rows = try composeSteeringMessageRows(alloc, message, width, limit, waiting);
                    defer rows.deinit(alloc);
                    try std.testing.expectEqual(@as(usize, layout.row_count), rows.rows.items.len);
                    try std.testing.expect(rows.rows.items.len <= limit);
                    for (rows.rows.items) |row| {
                        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
                        try std.testing.expect(std.unicode.utf8ValidateSlice(row.items));
                        try std.testing.expect(std.mem.find(u8, row.items, "\\x0a") == null);
                        try std.testing.expect(std.mem.find(u8, row.items, "\\x0d") == null);
                        try std.testing.expect(std.mem.find(u8, row.items, "\\x09") == null);
                        try std.testing.expect(std.mem.find(u8, row.items, "\x1b[2J") == null);
                    }
                }
            }
        }
    }
}

test "steering preview truncates after the second wide glyph" {
    var rows = try composeSteeringMessageRows(std.testing.allocator, "界海語", 5, 2, true);
    defer rows.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), rows.rows.items.len);
    try std.testing.expect(std.mem.find(u8, rows.rows.items[0].items, "┋ 界") != null);
    try std.testing.expect(std.mem.find(u8, rows.rows.items[1].items, "┋ 海…") != null);
}

test "steering rows visibly escape terminal control bytes" {
    var unsafe = try composeSteeringMessageRows(std.testing.allocator, "before\x1b[2Jafter", 80, 2, true);
    defer unsafe.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), unsafe.rows.items.len);
    try std.testing.expect(std.mem.find(u8, unsafe.rows.items[0].items, "┋ before\\x1b[2Jafter") != null);
    try std.testing.expect(std.mem.find(u8, unsafe.rows.items[0].items, "Esc to steer now") == null);
    try std.testing.expect(std.mem.find(u8, unsafe.rows.items[0].items, "\x1b[2J") == null);
}

// Ordered widest-first; every fallback keeps the enter/esc controls so narrow
// terminals never lose the submit and cancel instructions.
const freeform_question_hints = [_][]const u8{
    "↑↓ Cursor · Shift+↑↓ Options · Tab Questions · Enter Answer · Esc Cancel",
    "Shift+↑↓ Options · Tab Questions · Enter Answer · Esc Cancel",
    "Tab Questions · Enter Answer · Esc Cancel",
    "Enter Answer · Esc Cancel",
};

const predefined_question_hints = [_][]const u8{
    "↑↓ Options · Tab Questions · Enter Answer · Esc Cancel",
    "Tab Questions · Enter Answer · Esc Cancel",
    "Enter Answer · Esc Cancel",
};

fn questionInteractionHint(
    projection: question_prompt.Projection,
    width: u16,
    out_buf: []u8,
) []const u8 {
    const option_count = if (projection.current_entry) |entry| entry.options.len else 0;
    const variants: []const []const u8 = if (projection.isFreeformSelected())
        &freeform_question_hints
    else
        &predefined_question_hints;

    var out: std.Io.Writer = .fixed(out_buf);
    if (projection.isFreeformSelected()) {
        out.writeAll(
            "Type answer    ↑↓←→ Cursor    Shift+↑↓ Options    Tab Questions    Enter Answer    Esc Cancel",
        ) catch return display_width.widestFitting(variants, width);
    } else {
        out.print(
            "1–{d} Choose now    ↑↓ Options    Tab Questions    Enter Answer    Esc Cancel",
            .{option_count},
        ) catch return display_width.widestFitting(variants, width);
    }
    var base = out.buffered();
    if (display_width.visibleWidth(base) > width) {
        const variant = display_width.widestFitting(variants, width);
        out = .fixed(out_buf);
        out.writeAll(variant) catch return variant;
        base = out.buffered();
    }

    // Batch progress rides the hint row, right-aligned like the rest of the
    // footer chrome; a lone question needs no counter.
    if (projection.entry_count > 1) {
        var counter_buf: [32]u8 = undefined;
        const counter = std.fmt.bufPrint(
            &counter_buf,
            "Question {d} of {d}",
            .{ projection.current_index + 1, projection.entry_count },
        ) catch "";
        const base_width = display_width.visibleWidth(base);
        const counter_width = display_width.visibleWidth(counter);
        if (counter.len > 0 and base_width + counter_width + 2 <= width) {
            out.splatByteAll(' ', width - base_width - counter_width) catch return base;
            out.writeAll(counter) catch return base;
            return out.buffered();
        }
    }
    return base;
}

pub fn slashInputPrefix(registry: command_specs.SlashRegistry, items: []const u8) []const u8 {
    return command_specs.slashCompletionPrefix(registry, items) orelse "";
}

pub fn inputRowLimit(content_bottom: u16) usize {
    const max_extra: usize = if (content_bottom > 4) content_bottom / 2 else 0;
    return max_extra + 1;
}

pub fn cappedInputRows(total_rows: usize, content_bottom: u16, input_visible: bool) CappedInputRows {
    const row_limit = inputRowLimit(content_bottom);
    const visible_rows = @min(total_rows, row_limit);
    const total_lines: u16 = @intCast(@min(visible_rows, std.math.maxInt(u16)));
    const input_extra: u16 = if (input_visible and total_lines > 1) total_lines - 1 else 0;
    return .{
        .row_limit = row_limit,
        .total_lines = total_lines,
        .input_extra = input_extra,
    };
}

pub fn slashCompletionPickerPrefix(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) ?[]const u8 {
    if (ctx.input.picker.isInlinePickerSuppressed(.slash) or modal_active or show_model_query or show_file_query) return null;
    if (ctx.input.picker.inlinePickerTriggerKind(&ctx.input.edit_state) != .slash) return null;
    // Mid-turn bare `/model` owns the footer slot before the staged picker opens.
    if (ctx.stream.active and ctx.input.picker.isModelShapedInput(&ctx.input.edit_state)) return null;
    const prefix = slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
    return if (prefix.len > 0) prefix else null;
}

fn slashCompletionPickerActive(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) bool {
    return slashCompletionPickerPrefix(ctx, modal_active, show_model_query, show_file_query) != null;
}

pub fn slashCompletionPickerCount(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) usize {
    const prefix = slashCompletionPickerPrefix(ctx, modal_active, show_model_query, show_file_query) orelse return 0;
    return picker_presentation.mixedSlashCompletionCount(ctx.slash_registry, prefix, ctx.skills_menu.items);
}

fn slashRawAnchor(input_items: []const u8, prefix: []const u8) ?usize {
    const slash_anchor = command_specs.argCompletionAnchor(prefix);
    if (slash_anchor == 0 or prefix.len > input_items.len or slash_anchor > prefix.len) return null;
    const leading_ws = input_items.len - prefix.len;
    return leading_ws + slash_anchor;
}

pub fn measureRawInputGeometry(
    ctx: RenderContext,
    terminal_cols: u16,
    content_bottom: u16,
    input_visible: bool,
    modal_active: bool,
    show_model_query: bool,
    show_file_query: bool,
) RawInputGeometry {
    return measureRawInputGeometryPrepared(
        ctx,
        terminal_cols,
        content_bottom,
        input_visible,
        modal_active,
        show_model_query,
        show_file_query,
        null,
    );
}

pub fn measureRawInputGeometryPrepared(
    ctx: RenderContext,
    terminal_cols: u16,
    content_bottom: u16,
    input_visible: bool,
    modal_active: bool,
    show_model_query: bool,
    show_file_query: bool,
    prepared_slash_completion_count: ?usize,
) RawInputGeometry {
    return measureRawInputGeometryPreparedWithProvider(
        ctx,
        terminal_cols,
        content_bottom,
        input_visible,
        modal_active,
        show_model_query,
        false,
        show_file_query,
        prepared_slash_completion_count,
    );
}

pub fn measureRawInputGeometryPreparedWithProvider(
    ctx: RenderContext,
    terminal_cols: u16,
    content_bottom: u16,
    input_visible: bool,
    modal_active: bool,
    show_model_query: bool,
    show_provider_query: bool,
    show_file_query: bool,
    prepared_slash_completion_count: ?usize,
) RawInputGeometry {
    const display_input = ctx.input.edit_state.input.items;
    const display_cursor = ctx.input.edit_state.cursor;
    const display_images = ctx.pending_images;
    const display_pasted_blocks = ctx.input.entities.pasted_blocks.items;
    const display_image_tokens = ctx.input.entities.image_tokens.items;
    const display_skill_tokens = ctx.input.entities.skill_tokens.items;
    const slash_prefix = slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
    const raw_anchor: ?usize = if (show_model_query)
        ctx.model_completion_anchor
    else if (show_provider_query)
        ctx.provider_picker_completion_anchor
    else if (show_file_query)
        ctx.file_completion_anchor
    else
        slashRawAnchor(ctx.input.edit_state.input.items, slash_prefix);

    const summary = visual_layout.summarize(.{
        .input = display_input,
        .cursor = display_cursor,
        .terminal_cols = terminal_cols,
        .images = display_images,
        .pasted_blocks = display_pasted_blocks,
        .image_tokens = display_image_tokens,
        .skill_tokens = display_skill_tokens,
    }, raw_anchor);
    const capped = cappedInputRows(summary.total_rows, content_bottom, input_visible);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, capped.row_limit);
    const slash_query_active = slashCompletionPickerActive(ctx, modal_active, show_model_query, show_provider_query or show_file_query);
    const slash_completion_count = if (slash_query_active)
        prepared_slash_completion_count orelse
            slashCompletionPickerCount(ctx, modal_active, show_model_query, show_provider_query or show_file_query)
    else
        0;
    const show_slash_query = slash_query_active and slash_completion_count > 0;
    const picker_start_col = if (show_model_query or show_provider_query or show_file_query or show_slash_query)
        visual_layout.projectedAnchorColumn(summary, terminal_cols)
    else
        @as(u16, 1);

    return .{
        .summary = summary,
        .window = window,
        .total_lines = capped.total_lines,
        .input_extra = capped.input_extra,
        .slash_completion_count = slash_completion_count,
        .show_slash_query = show_slash_query,
        .picker_start_col = picker_start_col,
    };
}

fn authPickerInteractionHint(view: auth_runtime.PickerView, width: u16) ?[]const u8 {
    if (!view.active or view.include_skip) return null;

    if (view.stage == .api_key and view.api_key_inline) {
        const key_variants = [_][]const u8{
            "Enter saves     Esc cancels     " ++ credentials.stored_key_backend_label,
            "Enter saves  Esc cancels",
            "Enter  Esc",
        };
        for (key_variants) |candidate| {
            if (display_width.visibleWidth(candidate) <= width) return candidate;
        }
        return key_variants[key_variants.len - 1];
    }

    const root_variants = [_][]const u8{
        "↑↓ Navigate     Enter Open     Esc Close",
        "↑↓ Move  Enter Open  Esc",
        "Enter Open  Esc Close",
        "Enter Esc",
    };
    const connections_variants = [_][]const u8{
        "↑↓ Navigate     Enter Open     Esc Back",
        "↑↓ Move  Enter Open  Esc",
        "Enter Open  Esc Back",
        "Enter Esc",
    };
    const selection_variants = [_][]const u8{
        "↑↓ Navigate     Enter Use     Esc Back",
        "↑↓ Move  Enter Use  Esc",
        "Enter Use  Esc Back",
        "Enter Esc",
    };
    const team_variants = [_][]const u8{
        "Type to search     ↑↓ Navigate     Enter Use     Esc Back",
        "Type  ↑↓ Move  Enter  Esc",
        "↑↓ Move  Enter  Esc",
        "Enter Esc",
    };
    const codex_sign_in_variants = [_][]const u8{
        "Enter reopens browser · Esc cancels",
        "Enter reopens  Esc cancels",
        "Enter  Esc",
        "Enter Esc",
    };
    const grok_browser_variants = [_][]const u8{
        "Enter reopens browser · Tab enters code · Esc cancels",
        "Enter reopens  Tab code  Esc cancels",
        "Enter  Tab  Esc",
        "Enter Tab Esc",
    };
    const grok_manual_variants = [_][]const u8{
        "Enter submits code · Tab returns to browser · Esc cancels",
        "Enter submits  Tab browser  Esc cancels",
        "Enter  Tab  Esc",
        "Enter Tab Esc",
    };
    const variants = switch (view.stage) {
        .root => root_variants,
        .connections => connections_variants,
        .provider, .switch_credential => selection_variants,
        .change_team => team_variants,
        .sign_in => switch (view.sign_in_source) {
            .chatgpt_subscription => codex_sign_in_variants,
            .grok_subscription => if (view.sign_in_code_visible)
                grok_manual_variants
            else
                grok_browser_variants,
            else => return null,
        },
        .api_key => return null,
    };
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) return candidate;
    }
    return variants[variants.len - 1];
}

pub fn composeHintRow(
    alloc: Allocator,
    approval_active: bool,
    ctx: RenderContext,
    width: u16,
) !std.ArrayList(u8) {
    var question_hint_buf: [512]u8 = undefined;
    const question_hint = if (ctx.question) |projection|
        questionInteractionHint(projection, width, &question_hint_buf)
    else
        null;
    const auth_hint = if (!approval_active and question_hint == null and !ctx.ctrl_c_pending)
        authPickerInteractionHint(ctx.auth_picker, width)
    else
        null;
    var hint_buf: [max_status_line_len]u8 = undefined;
    const base_hint_line = ui_render.buildHintLine(
        approval_active,
        ctx.has_api_key or (ctx.auth_picker.active and ctx.auth_picker.include_skip),
        ctx.model,
        ctx.permission_mode,
        ctx.fast_indicator_active,
        ctx.effort,
        ctx.model_supports_effort,
        ctx.statusline,
        width,
        &hint_buf,
    );
    const hint_line = if (question_hint) |hint|
        hint
    else if (ctx.ctrl_c_pending)
        "press ctrl+c again to exit"
    else if (auth_hint) |hint|
        hint
    else
        base_hint_line;

    const width_usize: usize = width;
    const danger_text = dangerStatusText(approval_active, ctx, width);
    // The armed clear indicator outranks the question suppression: a
    // freeform draft mid-question uses the same double-Esc contract as the
    // composer and needs the same cue.
    const right_text: []const u8 = if (ctx.esc_clear_armed)
        "esc again to clear"
    else if (question_hint != null)
        ""
    else if (danger_text.len > 0)
        danger_text
    else
        ctx.upgrade_status;
    const right_width = display_width.visibleWidth(right_text);
    const danger_visible = danger_text.len > 0 and right_text.ptr == danger_text.ptr;
    const left_width: u16 = if (!danger_visible and right_width > 0 and width_usize > right_width)
        @intCast(width_usize - right_width - 1)
    else
        width;

    var row: std.ArrayList(u8) = .empty;
    try row.appendSlice(alloc, if (question_hint != null) ui_render.dim_style else ui_render.statusline_style);
    try row_text.appendClipped(alloc, &row, hint_line, left_width);
    try row.appendSlice(alloc, ui_render.reset_style);

    const hint_width = @min(
        display_width.visibleWidthIgnoringAnsi(hint_line),
        @as(usize, left_width),
    );
    if (right_text.len > 0 and right_width > 0 and
        ((danger_visible and width_usize >= right_width) or
            (!danger_visible and width_usize > hint_width + right_width)))
    {
        const tag_col: u16 = @intCast(width_usize - right_width + 1);
        try row_text.appendAbsoluteColumn(alloc, &row, tag_col);
        try row.appendSlice(alloc, if (danger_visible) ui_render.red_style else ui_render.dim_style);
        try row.appendSlice(alloc, right_text);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

pub fn dangerStatusText(
    approval_active: bool,
    ctx: RenderContext,
    width: u16,
) []const u8 {
    // Transient interaction hints own the whole row: the warning is placed at
    // an absolute column and would overwrite them on narrow terminals.
    if (approval_active or ctx.question != null or ctx.esc_clear_armed or ctx.ctrl_c_pending) return "";
    if (ctx.danger_status.len > 0 and
        display_width.visibleWidth(ctx.danger_status) <= width)
    {
        return ctx.danger_status;
    }
    if (ctx.danger_status_compact.len > 0 and
        display_width.visibleWidth(ctx.danger_status_compact) <= width)
    {
        return ctx.danger_status_compact;
    }
    return "";
}

pub fn composeSkillsMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    return composeCatalogMenuHintRow(alloc, width, ctrl_c_pending, .source);
}

pub fn composeModelsMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    return composeCatalogMenuHintRow(alloc, width, ctrl_c_pending, .provider);
}

pub fn composeResumeMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    return composeCatalogMenuHintRow(alloc, width, ctrl_c_pending, .scope);
}

pub fn composeMcpMenuHintRow(
    alloc: Allocator,
    width: u16,
    ctrl_c_pending: bool,
    projection: render_input.McpMenuProjection,
) !std.ArrayList(u8) {
    const state = projection.state;
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const root_variants = [_][]const u8{
        "↑↓ Move  Tab Section  Enter Inspect  A Add  R Reload  C Help  Esc Close",
        "↑↓ Move  Tab Section  Enter  A Add  R Reload  C Help  Esc",
        "Tab Enter A R C Esc",
    };
    const catalog_variants = [_][]const u8{
        "↑↓ Navigate     Tab Section     Enter Open     / Filter     Esc Back",
        "↑↓ Move  Tab Section  Enter  / Filter  Esc",
        "Tab Enter / Esc",
    };
    const preview_variants = [_][]const u8{
        "↑↓ Scroll     I Insert     Esc Back",
        "↑↓ Scroll  I Insert  Esc",
        "↑↓ I Esc",
    };
    const add_variants = [_][]const u8{
        "Type field     Enter Next/Save     Tab Transport     Esc Cancel",
        "Type  Enter Next/Save  Tab Transport  Esc",
        "Enter Tab Esc",
    };
    const argument_variants = [_][]const u8{
        "Type value  Enter Next/Preview  Tab Complete  Esc Cancel",
        "Type  Enter Next  Tab Complete  Esc",
        "Enter Tab Esc",
    };
    var details: std.ArrayList(u8) = .empty;
    defer details.deinit(alloc);
    if (projection.selectedServer()) |server| {
        const labels = [_]struct { action: mcp_menu_state.Action, label: []const u8 }{
            .{ .action = .authenticate, .label = "Enter Sign in  " },
            .{ .action = .trust_approve, .label = "A Approve  " },
            .{ .action = .trust_reject, .label = "X Reject  " },
            .{ .action = .remove, .label = "D Remove  " },
            .{ .action = .logout, .label = "L Logout  " },
        };
        for (labels) |item| if (mcp_menu_state.serverActionAvailable(item.action, server)) try details.appendSlice(alloc, item.label);
    }
    try details.appendSlice(alloc, "C Help  Esc Back");
    const details_variants = [_][]const u8{ details.items, "C Help  Esc Back", "C Esc" };
    const confirm_variants = [_][]const u8{
        "Enter Confirm     Esc Cancel",
        "Enter Confirm  Esc",
        "Enter Esc",
    };
    const info_variants = [_][]const u8{
        "Esc Back",
        "Esc",
        "Esc",
    };
    const variants = switch (state.screen) {
        .browse => if (state.section == .servers) root_variants else catalog_variants,
        .preview => preview_variants,
        .add => add_variants,
        .arguments => argument_variants,
        .info => info_variants,
        .details => details_variants,
        .confirm => confirm_variants,
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeHelpMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool) !std.ArrayList(u8) {
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const variants = [_][]const u8{
        "↑↓ Navigate     Tab Category     Enter Open     Esc Close",
        "↑↓ Navigate  Tab Category  Enter Open  Esc Close",
        "↑↓ Move  Tab Category  Enter  Esc",
        "Tab Category  Enter Open  Esc",
        "Tab Enter Esc",
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeSettingsMenuHintRow(
    alloc: Allocator,
    width: u16,
    ctrl_c_pending: bool,
) !std.ArrayList(u8) {
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const variants = [_][]const u8{
        "↑↓ Navigate     Tab Category     ←→ Change     Esc Close",
        "↑↓ Navigate  Tab Category  ←→ Change  Esc Close",
        "↑↓ Move  Tab Category  ←→ Change  Esc",
        "Tab Category  ←→ Change  Esc",
        "Tab ←→ Esc",
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeCompactCommandMenuHintRow(
    alloc: Allocator,
    width: u16,
    menu: render_input.CompactCommandMenuProjection,
) !std.ArrayList(u8) {
    const variants = switch (menu) {
        .statusline => [_][]const u8{
            "↑↓ Navigate     ←→ Change     Esc Close",
            "↑↓ Move  ←→ Change  Esc",
            "←→ Esc",
        },
        .usage => [_][]const u8{
            "Tab Scope     ↑↓ Model     Enter Expand     R Refresh     Esc Close",
            "Tab Scope  ↑↓ Model  Enter Expand  R Refresh  Esc",
            "Tab ↑↓  Enter  R  Esc",
        },
        .workspace => [_][]const u8{
            "↑↓ Navigate     Enter Use     Esc Close",
            "↑↓ Move  Enter Use  Esc",
            "Enter Esc",
        },
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const CatalogTabKind = enum {
    source,
    provider,
    scope,
};

fn composeCatalogMenuHintRow(alloc: Allocator, width: u16, ctrl_c_pending: bool, tab_kind: CatalogTabKind) !std.ArrayList(u8) {
    if (ctrl_c_pending) {
        var warning: std.ArrayList(u8) = .empty;
        errdefer warning.deinit(alloc);
        try warning.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendClipped(alloc, &warning, "press ctrl+c again to exit", width);
        try warning.appendSlice(alloc, ui_render.reset_style);
        return warning;
    }

    const source_variants = [_][]const u8{
        "↑↓ Navigate     Tab Source     Enter Use     Esc Close",
        "↑↓ Navigate  Tab Source  Enter Use  Esc Close",
        "↑↓ Move  Tab Source  Enter  Esc",
        "Enter Use  Esc Close",
        "Enter Esc",
    };
    const provider_variants = [_][]const u8{
        "↑↓ Navigate     Tab Provider     Enter Use     Esc Close",
        "↑↓ Navigate  Tab Provider  Enter Use  Esc Close",
        "↑↓ Move  Tab Provider  Enter  Esc",
        "Enter Use  Esc Close",
        "Enter Esc",
    };
    const scope_variants = [_][]const u8{
        "↑↓ Navigate     Tab Scope     Enter Resume     Esc Close",
        "↑↓ Navigate  Tab Scope  Enter Resume  Esc Close",
        "↑↓ Move  Tab Scope  Enter  Esc",
        "Enter Resume  Esc Close",
        "Enter Esc",
    };
    const variants = switch (tab_kind) {
        .source => source_variants,
        .provider => provider_variants,
        .scope => scope_variants,
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeSlashMenuHintRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    const variants = [_][]const u8{
        "↑↓ Navigate     Enter Use     Esc Close",
        "↑↓ Navigate  Enter Use  Esc Close",
        "↑↓ Move  Enter  Esc",
        "Enter Use  Esc Close",
        "Enter Esc",
    };
    var hint = variants[variants.len - 1];
    for (variants) |candidate| {
        if (display_width.visibleWidth(candidate) <= width) {
            hint = candidate;
            break;
        }
    }

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "slash menu hint keeps navigation and selection controls width safe" {
    var wide = try composeSlashMenuHintRow(std.testing.allocator, 80);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, wide.items, "↑↓ Navigate     Enter Use     Esc Close") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(wide.items) <= 80);

    var narrow = try composeSlashMenuHintRow(std.testing.allocator, 12);
    defer narrow.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, narrow.items, "Enter Esc") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow.items) <= 12);
}

pub fn composeVisibleInputRows(
    alloc: Allocator,
    source: visual_layout.Source,
    window: visual_layout.VisibleWindow,
) !ComposedInputRows {
    var result = ComposedInputRows{};
    errdefer result.deinit(alloc);
    if (window.row_count == 0) return result;

    const end_row = window.first_row + window.row_count;
    var current: std.ArrayList(u8) = .empty;
    errdefer current.deinit(alloc);
    var row_started = false;
    var remaining_cells: usize = 0;
    var omitted_positive_unit = false;

    var it = visual_layout.iterator(source);
    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index < window.first_row) continue;
            if (unit.row_index >= end_row) break;
            try startComposedInputRow(
                alloc,
                &current,
                source.terminal_cols,
                unit.row_index,
                unit.row_index == window.first_row and window.first_row > 0,
                &row_started,
                &remaining_cells,
            );
            try appendLayoutUnit(alloc, &current, source, unit, &remaining_cells, &omitted_positive_unit);
        },
        .row_end => |row| {
            if (row.index < window.first_row) continue;
            if (row.index >= end_row) break;
            try startComposedInputRow(
                alloc,
                &current,
                source.terminal_cols,
                row.index,
                row.index == window.first_row and window.first_row > 0,
                &row_started,
                &remaining_cells,
            );
            try finishComposedInputRow(alloc, &current, source.terminal_cols);
            try result.rows.append(alloc, current);
            current = .empty;
            row_started = false;
            remaining_cells = 0;
            omitted_positive_unit = false;
            if (row.index + 1 >= end_row) break;
        },
    };

    return result;
}

pub fn appendInlineCompletionSuffix(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    width: u16,
    suffix: []const u8,
) !void {
    if (suffix.len == 0) return;
    const used_cells = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used_cells >= @as(usize, width)) return;

    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(
        alloc,
        row,
        suffix,
        @intCast(@as(usize, width) - used_cells),
    );
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn startComposedInputRow(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    width: u16,
    row_index: usize,
    hidden_above: bool,
    started: *bool,
    remaining_cells: *usize,
) !void {
    if (started.*) return;
    started.* = true;
    const prefix = visual_layout.inputPrefix(row_index);
    try row.appendSlice(alloc, ui_render.hint_style);
    try row_text.appendClipped(alloc, row, if (hidden_above) "┃↑" else "┃", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (!hidden_above and width > 1) try row_text.appendClipped(alloc, row, " ", width - 1);
    const width_usize: usize = width;
    remaining_cells.* = if (width_usize > prefix.cell_width) width_usize - prefix.cell_width else 0;
}

fn appendLayoutUnit(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    source: visual_layout.Source,
    unit: visual_layout.Unit,
    remaining_cells: *usize,
    omitted_positive_unit: *bool,
) !void {
    if (remaining_cells.* == 0) return;

    const selected = if (source.selection) |selection|
        unit.raw_start < selection.end and unit.raw_end > selection.start
    else
        false;
    if (selected) try row.appendSlice(alloc, "\x1b[7m");
    try appendLayoutUnitContent(
        alloc,
        row,
        source,
        unit,
        remaining_cells,
        omitted_positive_unit,
    );
    if (selected) {
        try row.appendSlice(alloc, ui_render.reset_style);
    }
}

fn appendLayoutUnitContent(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    source: visual_layout.Source,
    unit: visual_layout.Unit,
    remaining_cells: *usize,
    omitted_positive_unit: *bool,
) !void {
    switch (unit.kind) {
        .text => {
            if (unit.cell_width == 0) {
                if (!omitted_positive_unit.*) try row.appendSlice(alloc, source.input[unit.raw_start..unit.raw_end]);
                return;
            }
            if (unit.cell_width <= remaining_cells.*) {
                try row.appendSlice(alloc, source.input[unit.raw_start..unit.raw_end]);
                remaining_cells.* -= unit.cell_width;
                omitted_positive_unit.* = false;
            } else {
                omitted_positive_unit.* = true;
            }
        },
        .paste_placeholder => {
            const emit_cells = @min(unit.cell_width, remaining_cells.*);
            try row_text.appendClipped(
                alloc,
                row,
                source.input[unit.raw_start..unit.raw_end],
                @intCast(@min(emit_cells, std.math.maxInt(u16))),
            );
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = emit_cells < unit.cell_width;
        },
        .tab => {
            if (unit.cell_width == 0) return;
            if (unit.cell_width <= remaining_cells.*) {
                try row.appendNTimes(alloc, ' ', unit.cell_width);
                remaining_cells.* -= unit.cell_width;
                omitted_positive_unit.* = false;
            } else {
                omitted_positive_unit.* = true;
            }
        },
        .skill_token => |token_index| {
            const token = source.skill_tokens[token_index];
            const emit_cells = @min(unit.cell_width, remaining_cells.*);
            if (emit_cells == 0) {
                omitted_positive_unit.* = unit.cell_width > 0;
                return;
            }
            try row.appendSlice(alloc, ui_render.tag_style);
            try row_text.appendClipped(alloc, row, token.name, @intCast(@min(emit_cells, std.math.maxInt(u16))));
            try row.appendSlice(alloc, ui_render.reset_style);
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = unit.cell_width > emit_cells;
        },
        .image_badge => |badge| {
            const emit_cells = @min(unit.cell_width, remaining_cells.*);
            if (emit_cells == 0) {
                omitted_positive_unit.* = unit.cell_width > 0;
                return;
            }
            var writer = std.Io.Writer.Allocating.fromArrayList(alloc, row);
            const attachment = source.images[badge.attachment_index];
            try image_attachments.writeImageBadgeClipped(&writer.writer, attachment.id, attachment.path, emit_cells);
            row.* = writer.toArrayList();
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = unit.cell_width > emit_cells;
        },
    }
}

fn finishComposedInputRow(alloc: Allocator, row: *std.ArrayList(u8), width: u16) !void {
    if (display_width.visibleWidthIgnoringAnsi(row.items) < @as(usize, width)) try row.appendSlice(alloc, "\x1b[K");
}

const input_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true },
    .{ .kind = .resume_session, .command = "/resume", .help_entry = "/resume", .completion_description = "resume a session", .presentation_category = .session },
};
const input_test_slash_registry = command_specs.SlashRegistry{ .commands = input_test_slash_specs[0..] };

fn testRenderContext(input: *const InputRuntime) RenderContext {
    return .{
        .slash_registry = input_test_slash_registry,
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .input = input,
    };
}

test "composer badge labels a later-turn image with its own id" {
    const alloc = std.testing.allocator;
    const images = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/two.png"), .media_type = @constCast("image/png") },
    };
    const image_tokens = [_]visual_layout.ImageTokenSpan{.{
        .id = 2,
        .span = .{ .raw_start = 0, .raw_end = "[Image #2]".len },
    }};
    const source = visual_layout.Source{
        .input = "[Image #2]",
        .cursor = "[Image #2]".len,
        .terminal_cols = 40,
        .images = &images,
        .image_tokens = &image_tokens,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 4);
    var composed = try composeVisibleInputRows(alloc, source, window);
    defer composed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), composed.rows.items.len);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "[Image 2]") != null);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "[Image 1]") == null);
}

test "composer skill token shows only its name" {
    const alloc = std.testing.allocator;
    const skill_tokens = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = "review",
        .path = "/tmp/review",
        .display_source = .workspace_codex,
    }};
    const source = visual_layout.Source{
        .input = "$review",
        .cursor = "$review".len,
        .terminal_cols = 40,
        .skill_tokens = &skill_tokens,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);
    var composed = try composeVisibleInputRows(alloc, source, window);
    defer composed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), composed.rows.items.len);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "review") != null);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "workspace .codex") == null);
}

test "composeVisibleInputRows avoids clear-to-eol after full-width input" {
    const alloc = std.testing.allocator;

    const full_source = visual_layout.Source{
        .input = "12345",
        .cursor = 5,
        .terminal_cols = 7,
    };
    const full_summary = visual_layout.summarize(full_source, null);
    const full_window = visual_layout.visibleWindow(full_summary.cursor.row_index, full_summary.total_rows, 1);
    var full = try composeVisibleInputRows(alloc, full_source, full_window);
    defer full.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), full.rows.items.len);
    try std.testing.expect(std.mem.indexOf(u8, full.rows.items[0].items, "\x1b[K") == null);

    const short_source = visual_layout.Source{
        .input = "1234",
        .cursor = 4,
        .terminal_cols = 7,
    };
    const short_summary = visual_layout.summarize(short_source, null);
    const short_window = visual_layout.visibleWindow(short_summary.cursor.row_index, short_summary.total_rows, 1);
    var short = try composeVisibleInputRows(alloc, short_source, short_window);
    defer short.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), short.rows.items.len);
    try std.testing.expect(std.mem.indexOf(u8, short.rows.items[0].items, "\x1b[K") != null);
}

test "composeVisibleInputRows paints selected input without changing visible width" {
    const alloc = std.testing.allocator;
    const source = visual_layout.Source{
        .input = "alpha beta",
        .cursor = "alpha".len,
        .terminal_cols = 20,
        .selection = .{ .start = 0, .end = "alpha".len },
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);

    var plain_rows = try composeVisibleInputRows(alloc, .{ .input = source.input, .cursor = source.cursor, .terminal_cols = source.terminal_cols }, window);
    defer plain_rows.deinit(alloc);

    var rows = try composeVisibleInputRows(alloc, source, window);
    defer rows.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, rows.rows.items[0].items, "\x1b[7ma") != null);
    try std.testing.expect(std.mem.find(u8, rows.rows.items[0].items, "\x1b[0m ") != null);
    try std.testing.expectEqual(
        display_width.visibleWidthIgnoringAnsi(plain_rows.rows.items[0].items),
        display_width.visibleWidthIgnoringAnsi(rows.rows.items[0].items),
    );
}

test "inline completion suffix uses dim style and clips to the current row" {
    const alloc = std.testing.allocator;
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try row.appendSlice(alloc, "❯ explain $man\x1b[K");
    const used = display_width.visibleWidthIgnoringAnsi(row.items);

    try appendInlineCompletionSuffix(
        alloc,
        &row,
        @intCast(used + 4),
        "aged-menu",
    );

    try std.testing.expect(std.mem.find(u8, row.items, ui_render.dim_style) != null);
    try std.testing.expect(std.mem.find(u8, row.items, "aged") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "aged-") == null);
    try std.testing.expectEqual(used + 4, display_width.visibleWidthIgnoringAnsi(row.items));

    var full_row: std.ArrayList(u8) = .empty;
    defer full_row.deinit(alloc);
    try full_row.appendSlice(alloc, "❯ x $man");
    const full_width: u16 = @intCast(display_width.visibleWidthIgnoringAnsi(full_row.items));
    try appendInlineCompletionSuffix(
        alloc,
        &full_row,
        full_width,
        "aged-menu",
    );
    try std.testing.expect(std.mem.find(u8, full_row.items, ui_render.dim_style) == null);
    try std.testing.expect(std.mem.find(u8, full_row.items, "aged") == null);
}

test "clipped composer row marks hidden input above" {
    const alloc = std.testing.allocator;
    const input = "first line\nsecond line";
    const source = visual_layout.Source{
        .input = input,
        .cursor = input.len,
        .terminal_cols = 40,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);
    var composed = try composeVisibleInputRows(alloc, source, window);
    defer composed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), window.first_row);
    try std.testing.expectEqual(@as(usize, 1), composed.rows.items.len);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "┃↑") != null);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "second line") != null);
    try std.testing.expectEqual(@as(u16, 14), visual_layout.terminalColumn(summary.cursor, source.terminal_cols));
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(composed.rows.items[0].items) <= source.terminal_cols);
}

test "trailing empty clipped composer row remains visibly nonempty" {
    const alloc = std.testing.allocator;
    const input = "first line\nsecond line\n";
    const source = visual_layout.Source{
        .input = input,
        .cursor = input.len,
        .terminal_cols = 40,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);
    var rows = try composeVisibleInputRows(alloc, source, window);
    defer rows.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), window.first_row);
    try std.testing.expectEqual(@as(u16, 3), visual_layout.terminalColumn(summary.cursor, source.terminal_cols));
    try std.testing.expect(std.mem.find(u8, rows.rows.items[0].items, "┃↑") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(rows.rows.items[0].items) <= source.terminal_cols);
}

test "footer raw input row composition matches hard newlines and soft wraps" {
    const alloc = std.testing.allocator;
    var hard_input = InputRuntime{};
    defer hard_input.deinit(alloc);
    try hard_input.edit_state.input.appendSlice(alloc, "abcd\nefgh");
    hard_input.edit_state.cursor = hard_input.edit_state.input.items.len;

    var soft_input = InputRuntime{};
    defer soft_input.deinit(alloc);
    try soft_input.edit_state.input.appendSlice(alloc, "abcdefgh");
    soft_input.edit_state.cursor = soft_input.edit_state.input.items.len;

    const hard = measureRawInputGeometry(testRenderContext(&hard_input), 6, 20, true, false, false, false);
    const soft = measureRawInputGeometry(testRenderContext(&soft_input), 6, 20, true, false, false, false);
    try std.testing.expectEqual(@as(u16, 2), hard.total_lines);
    try std.testing.expectEqual(hard.total_lines, soft.total_lines);
}

test "footer tabs are modeled spaces and anchors use modeled columns" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "\t/model");
    input.edit_state.cursor = 1;
    var ctx = testRenderContext(&input);
    ctx.model_query_active = true;
    ctx.model_completion_anchor = 1;
    // The tab consumes 6 cells, leaving 4 on row 0; "/model" (6 cells) word
    // wraps whole onto row 1, so the anchor projects to column 3.
    const geometry = measureRawInputGeometry(ctx, 10, 20, true, false, true, false);
    try std.testing.expectEqual(@as(u16, 3), geometry.picker_start_col);
}

test "footer raw geometry windows capped input around the cursor" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "x" ** 5000);
    input.edit_state.cursor = input.edit_state.input.items.len;
    const geometry = measureRawInputGeometry(testRenderContext(&input), 80, 8, true, false, false, false);
    try std.testing.expect(geometry.summary.total_rows > geometry.window.row_count);
    try std.testing.expect(geometry.window.first_row <= geometry.summary.cursor.row_index);
    try std.testing.expect(geometry.summary.cursor.row_index < geometry.window.first_row + geometry.window.row_count);
    try std.testing.expectEqual(geometry.window.row_count, geometry.total_lines);
}

test "footer image badges wrap atomically and close clipped OSC output" {
    const alloc = std.testing.allocator;
    const images = [_]types.ImageAttachment{
        .{ .id = 5, .path = @constCast("/tmp/five.png"), .media_type = @constCast("image/png") },
    };
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "a[Image #5]");
    try input.entities.image_tokens.append(alloc, .{
        .id = 5,
        .span = .{ .raw_start = "a".len, .raw_end = "a[Image #5]".len },
    });
    input.edit_state.cursor = input.edit_state.input.items.len;
    var ctx = testRenderContext(&input);
    ctx.pending_images = &images;
    ctx.file_query_active = true;
    ctx.file_completion_anchor = "a[Image #5]".len;

    const geometry = measureRawInputGeometry(ctx, 10, 20, true, false, false, true);
    try std.testing.expect(geometry.summary.total_rows > 1);
    try std.testing.expect(geometry.picker_start_col > 1);
}

test "footer unknown and overflowing placeholders stay literal" {
    const alloc = std.testing.allocator;
    const text = "[Image #6] [Image #999999999999999999999999999999999999]";
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, text);
    input.edit_state.cursor = input.edit_state.input.items.len;

    const geometry = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expectEqual(text.len, geometry.summary.cursor.raw_offset);
    try std.testing.expectEqual(@as(u16, 1), geometry.picker_start_col);
}

test "footer picker anchors project raw offsets before inside and after badges" {
    const alloc = std.testing.allocator;
    const images = [_]types.ImageAttachment{
        .{ .id = 5, .path = @constCast("/tmp/five.png"), .media_type = @constCast("image/png") },
    };
    const input_text = "[Image #5] suffix";

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, input_text);
    try input.entities.image_tokens.append(alloc, .{
        .id = 5,
        .span = .{ .raw_start = 0, .raw_end = "[Image #5]".len },
    });
    input.edit_state.cursor = "[Image #5]".len;
    var ctx = testRenderContext(&input);
    ctx.pending_images = &images;
    ctx.file_query_active = true;

    ctx.file_completion_anchor = 0;
    try std.testing.expectEqual(@as(u16, 3), measureRawInputGeometry(ctx, 80, 20, true, false, false, true).picker_start_col);
    ctx.file_completion_anchor = 3;
    try std.testing.expectEqual(@as(u16, 3), measureRawInputGeometry(ctx, 80, 20, true, false, false, true).picker_start_col);
    ctx.file_completion_anchor = "[Image #5]".len;
    try std.testing.expectEqual(@as(u16, 12), measureRawInputGeometry(ctx, 80, 20, true, false, false, true).picker_start_col);
}

test "footer model and file anchors on earlier soft rows project to cursor row start" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "abcdef");
    input.edit_state.cursor = 5;
    var ctx = testRenderContext(&input);
    ctx.model_query_active = true;
    ctx.model_completion_anchor = 1;
    try std.testing.expectEqual(@as(u16, 3), measureRawInputGeometry(ctx, 5, 20, true, false, true, false).picker_start_col);

    ctx.model_query_active = false;
    ctx.file_query_active = true;
    ctx.file_completion_anchor = 1;
    try std.testing.expectEqual(@as(u16, 3), measureRawInputGeometry(ctx, 5, 20, true, false, false, true).picker_start_col);
}

test "footer slash anchor contract handles top level and argument completions" {
    const alloc = std.testing.allocator;
    inline for (.{ "/", "/mo", "  /mo" }) |text| {
        var input = InputRuntime{};
        defer input.deinit(alloc);
        try input.edit_state.input.appendSlice(alloc, text);
        input.edit_state.cursor = input.edit_state.input.items.len;
        const geometry = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
        try std.testing.expect(geometry.summary.anchor == null);
        try std.testing.expectEqual(@as(u16, 1), geometry.picker_start_col);
    }

    var arg = InputRuntime{};
    defer arg.deinit(alloc);
    try arg.edit_state.input.appendSlice(alloc, "  /permissions ");
    arg.edit_state.cursor = arg.edit_state.input.items.len;
    const arg_geometry = measureRawInputGeometry(testRenderContext(&arg), 80, 20, true, false, false, false);
    try std.testing.expectEqual(@as(usize, 2 + "/permissions ".len), arg_geometry.summary.anchor.?.raw_offset);
    try std.testing.expectEqual(@as(usize, 2 + "/permissions ".len), arg_geometry.summary.anchor.?.content_column);
    try std.testing.expectEqual(@as(u16, 3 + 2 + "/permissions ".len), arg_geometry.picker_start_col);
}

test "footer slash completion remains active across capped input rows" {
    const alloc = std.testing.allocator;
    try std.testing.expect(command_specs.slashCompletionCount(input_test_slash_registry, "/mo") > 0);
    var suppressed = InputRuntime{};
    defer suppressed.deinit(alloc);
    try suppressed.edit_state.input.appendSlice(alloc, "/mo");
    suppressed.edit_state.cursor = suppressed.edit_state.input.items.len;
    try std.testing.expect(slashCompletionPickerCount(testRenderContext(&suppressed), false, false, false) > 0);

    var roomy = InputRuntime{};
    defer roomy.deinit(alloc);
    try roomy.edit_state.input.appendSlice(alloc, "       /mo");
    roomy.edit_state.cursor = roomy.edit_state.input.items.len;
    const roomy_geometry = measureRawInputGeometry(testRenderContext(&roomy), 8, 10, true, false, false, false);
    try std.testing.expect(roomy_geometry.input_extra > 0);
    try std.testing.expect(roomy_geometry.show_slash_query);
    try std.testing.expect(roomy_geometry.slash_completion_count > 0);

    const capped = cappedInputRows(3, 4, true);
    try std.testing.expectEqual(@as(usize, 1), capped.row_limit);
    try std.testing.expectEqual(@as(u16, 1), capped.total_lines);
    try std.testing.expectEqual(@as(u16, 0), capped.input_extra);

    const tiny_geometry = measureRawInputGeometry(testRenderContext(&roomy), 8, 4, true, false, false, false);
    try std.testing.expect(tiny_geometry.show_slash_query);
    try std.testing.expect(tiny_geometry.slash_completion_count > 0);
}

test "footer slash completion follows candidate visibility transitions" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    try input.textReplacementState().replace(alloc, "/mo");
    const matching = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(matching.show_slash_query);
    try std.testing.expect(matching.slash_completion_count > 0);

    try input.textReplacementState().replace(alloc, "/mozzzzz");
    const no_match = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(!no_match.show_slash_query);
    try std.testing.expectEqual(@as(usize, 0), no_match.slash_completion_count);

    try input.textReplacementState().replace(alloc, "/mo");
    const restored = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(restored.show_slash_query);
    try std.testing.expect(restored.slash_completion_count > 0);
}

test "footer slash completion preserves command argument ownership" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    try input.textReplacementState().replace(alloc, "/resume ");
    const no_args = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(!no_args.show_slash_query);
    try std.testing.expectEqual(@as(usize, 0), no_args.slash_completion_count);

    try input.textReplacementState().replace(alloc, "/permissions ");
    const arguments = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(arguments.show_slash_query);
    try std.testing.expectEqual(@as(usize, 6), arguments.slash_completion_count);
}

test "footer slash completion opens after multiline whitespace" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(alloc, "\n   /");

    const geometry = measureRawInputGeometry(testRenderContext(&input), 72, 12, true, false, false, false);
    try std.testing.expectEqual(@as(u16, 1), geometry.input_extra);
    try std.testing.expect(geometry.show_slash_query);
    try std.testing.expect(geometry.slash_completion_count > 0);
}

test "footer slash completion projection honors dismissed input state" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/mo");
    input.edit_state.cursor = input.edit_state.input.items.len;

    try std.testing.expect(slashCompletionPickerCount(testRenderContext(&input), false, false, false) > 0);
    input.picker.dismissInlinePicker(.slash);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionPickerCount(testRenderContext(&input), false, false, false));

    const geometry = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expectEqual(@as(usize, 0), geometry.slash_completion_count);
    try std.testing.expect(!geometry.show_slash_query);
    try std.testing.expectEqualStrings("/mo", input.edit_state.input.items);
}

test "footer does not reinterpret dismissed model or file input as slash completion" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    try input.textReplacementState().replace(alloc, "/model ");
    input.picker.dismissInlinePicker(.model);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionPickerCount(testRenderContext(&input), false, false, false));

    try input.textReplacementState().replace(alloc, "/help @src");
    input.picker.dismissInlinePicker(.file);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionPickerCount(testRenderContext(&input), false, false, false));
}

test "footer suppresses slash rows for streaming model-shaped input" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "model-helper",
        .description = "model helper",
        .path = "/tmp/model-helper/SKILL.md",
        .source = .global_fx,
    }};

    for ([_][]const u8{ "/model", "/model " }) |text| {
        var input = InputRuntime{};
        defer input.deinit(alloc);
        try input.edit_state.input.appendSlice(alloc, text);
        input.edit_state.cursor = input.edit_state.input.items.len;

        var ctx = testRenderContext(&input);
        ctx.skills_menu = .{ .items = &skills };
        ctx.stream = .{ .active = true };

        try std.testing.expectEqual(@as(usize, 0), slashCompletionPickerCount(ctx, false, false, false));
        const geometry = measureRawInputGeometry(ctx, 80, 20, true, false, false, false);
        try std.testing.expectEqual(@as(usize, 0), geometry.slash_completion_count);
        try std.testing.expect(!geometry.show_slash_query);
    }

    var generic = InputRuntime{};
    defer generic.deinit(alloc);
    try generic.edit_state.input.appendSlice(alloc, "/mo");
    generic.edit_state.cursor = generic.edit_state.input.items.len;
    var generic_ctx = testRenderContext(&generic);
    generic_ctx.skills_menu = .{ .items = &skills };
    generic_ctx.stream = .{ .active = true };
    try std.testing.expect(slashCompletionPickerCount(generic_ctx, false, false, false) > 0);
}

test "compose hint row keeps model in left hint text" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .fast_indicator_active = true,
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, ctx, 32);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, row.items, ui_render.statusline_style));
    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1 · ⚡︎") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[14G") == null);
}

test "compose hint row replaces model status with setup navigation" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.auth_picker = .{
        .active = true,
        .available_sources = .empty,
        .selected_choice = .{ .action = .connections },
        .active_source = null,
        .include_skip = false,
    };

    var root = try composeHintRow(std.testing.allocator, false, ctx, 96);
    defer root.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, root.items, "↑↓ Navigate") != null);
    try std.testing.expect(std.mem.find(u8, root.items, "Enter Open") != null);
    try std.testing.expect(std.mem.find(u8, root.items, "Esc Close") != null);
    try std.testing.expect(std.mem.find(u8, root.items, "gpt-5.1") == null);

    ctx.auth_picker.stage = .connections;
    ctx.auth_picker.selected_choice = .{ .action = .login };
    var child = try composeHintRow(std.testing.allocator, false, ctx, 96);
    defer child.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, child.items, "Esc Back") != null);
}

test "compose hint row replaces model status with subscription sign-in controls" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        source: credentials.Source,
        manual_code_visible: bool,
        expected: []const u8,
    }{
        .{
            .source = .chatgpt_subscription,
            .manual_code_visible = false,
            .expected = "Enter reopens browser · Esc cancels",
        },
        .{
            .source = .grok_subscription,
            .manual_code_visible = false,
            .expected = "Enter reopens browser · Tab enters code · Esc cancels",
        },
        .{
            .source = .grok_subscription,
            .manual_code_visible = true,
            .expected = "Enter submits code · Tab returns to browser · Esc cancels",
        },
    };

    for (cases) |case| {
        var input = InputRuntime{};
        defer input.deinit(alloc);
        var ctx = testRenderContext(&input);
        ctx.model = "model-status-sentinel";
        ctx.auth_picker = .{
            .active = true,
            .available_sources = .empty,
            .selected_choice = null,
            .active_source = null,
            .include_skip = false,
            .stage = .sign_in,
            .sign_in_source = case.source,
            .sign_in_code_visible = case.manual_code_visible,
        };

        var row = try composeHintRow(alloc, false, ctx, 80);
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, case.expected) != null);
        try std.testing.expect(std.mem.find(u8, row.items, "model-status-sentinel") == null);
    }
}

test "compose hint row keeps configured fast mode visible" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .fast_indicator_active = true,
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, ctx, 96);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1 · ⚡︎") != null);
}

test "compose hint row does not advertise background terminals" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.shimmer_pos = 1;

    var row = try composeHintRow(std.testing.allocator, false, ctx, 96);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "background (") == null);
}

test "compose hint row right-aligns upgrade status" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .upgrade_status = "update ready: ctrl+g to reload",
        .statusline = .{
            .workspace_label = "/a/long/workspace/path/that/uses/the/statusline-tail",
        },
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, ctx, 48);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "update ready: ctrl+g to reload") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[19G") != null);
}

test "compose hint row right-aligns upgrade status after styled auto mode" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "openai/gpt-4o",
        .permission_mode = .auto,
        .upgrade_status = "update ready: ctrl+g to reload",
        .input = &input,
    };

    ui_render.initTheme(false, null);
    var row = try composeHintRow(std.testing.allocator, false, ctx, 56);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "auto") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "gpt-4o") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "update ready: ctrl+g to reload") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[27G") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 56);
}

test "compose hint row prioritizes red yolo warning with compact fallback" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.danger_status = "Full access enabled: fx permission checks disabled";
    ctx.danger_status_compact = "Full access";

    var full = try composeHintRow(std.testing.allocator, false, ctx, 80);
    defer full.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, full.items, ctx.danger_status) != null);
    try std.testing.expect(std.mem.find(u8, full.items, ui_render.red_style) != null);

    var compact = try composeHintRow(std.testing.allocator, false, ctx, 24);
    defer compact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, compact.items, ctx.danger_status_compact) != null);
    try std.testing.expect(std.mem.find(u8, compact.items, ctx.danger_status) == null);

    ctx.esc_clear_armed = true;
    var suppressed = try composeHintRow(std.testing.allocator, false, ctx, 80);
    defer suppressed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, suppressed.items, "esc again to clear") != null);
    try std.testing.expect(std.mem.find(u8, suppressed.items, "Full access") == null);
}

test "compose hint row yields the yolo warning to a pending ctrl+c quit hint" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.danger_status = "Full access enabled: fx permission checks disabled";
    ctx.danger_status_compact = "Full access";
    ctx.ctrl_c_pending = true;

    // Reported as unpainted so the warning's visible budget pauses.
    try std.testing.expectEqualStrings("", dangerStatusText(false, ctx, 60));

    var pending = try composeHintRow(std.testing.allocator, false, ctx, 60);
    defer pending.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, pending.items, "press ctrl+c again to exit") != null);
    try std.testing.expect(std.mem.find(u8, pending.items, "Full access") == null);

    ctx.ctrl_c_pending = false;
    try std.testing.expectEqualStrings(ctx.danger_status, dangerStatusText(false, ctx, 60));

    var resumed = try composeHintRow(std.testing.allocator, false, ctx, 60);
    defer resumed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, resumed.items, ctx.danger_status) != null);
    try std.testing.expect(std.mem.find(u8, resumed.items, "press ctrl+c again to exit") == null);
}

fn syncHintTestQuestion(prompt: *question_prompt.QuestionPrompt) !void {
    const opts = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
        .{ .label = "Maybe", .description = "decide later" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
}

test "question hint row excludes model and upgrade status at supported widths" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncHintTestQuestion(&prompt);

    const cases = [_]struct {
        width: u16,
        freeform: bool,
        hint: []const u8,
    }{
        .{ .width = 120, .freeform = false, .hint = "1–4 Choose now    ↑↓ Options    Tab Questions    Enter Answer    Esc Cancel" },
        .{ .width = 88, .freeform = false, .hint = "1–4 Choose now    ↑↓ Options    Tab Questions    Enter Answer    Esc Cancel" },
        .{ .width = 40, .freeform = false, .hint = predefined_question_hints[2] },
        .{ .width = 120, .freeform = true, .hint = "Type answer    ↑↓←→ Cursor    Shift+↑↓ Options    Tab Questions    Enter Answer    Esc Cancel" },
        .{ .width = 72, .freeform = true, .hint = freeform_question_hints[0] },
        .{ .width = 32, .freeform = true, .hint = freeform_question_hints[3] },
    };

    for (cases) |case| {
        if (case.freeform) prompt.moveChoice(-1);
        defer if (case.freeform) prompt.moveChoice(1);

        var input = InputRuntime{};
        defer input.deinit(std.testing.allocator);
        var ctx = testRenderContext(&input);
        ctx.question = prompt.projection();
        ctx.model = "model-x";
        ctx.upgrade_status = "update ready: ctrl+g to reload";
        var row = try composeHintRow(std.testing.allocator, false, ctx, case.width);
        defer row.deinit(std.testing.allocator);

        try std.testing.expect(std.mem.find(u8, row.items, case.hint) != null);
        try std.testing.expect(std.mem.find(u8, row.items, "model-x") == null);
        try std.testing.expect(std.mem.find(u8, row.items, "update ready: ctrl+g to reload") == null);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= case.width);
    }
}

test "question hint row right-aligns batch progress and drops it when narrow" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    const opts = [_]types.QuestionOption{
        .{ .label = "Yes", .description = null },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "First?", .options = &opts },
        .{ .question = "Second?", .options = &opts },
        .{ .question = "Third?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.question = prompt.projection();

    var row = try composeHintRow(std.testing.allocator, false, ctx, 120);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "  Question 1 of 3") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 120);

    var narrow = try composeHintRow(std.testing.allocator, false, ctx, 40);
    defer narrow.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, narrow.items, "Question 1 of 3") == null);
}

test "question hint assigns tab to question pagination" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncHintTestQuestion(&prompt);

    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.question = prompt.projection();

    var row = try composeHintRow(std.testing.allocator, false, ctx, 120);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "Tab Questions") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "tab to choose") == null);
}

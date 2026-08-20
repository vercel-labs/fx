const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const types = @import("../../core/shared/types.zig");
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

pub const PickerKind = enum { model_stage, file, slash, auth };
pub const ComposerPrefixStyle = enum { arrow, rail };

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

// Collapsed queue banner: the prompts stay hidden until the review is opened,
// so this row only reports how many are waiting and how to reach them.
pub fn composeQueuedSummaryRow(
    alloc: Allocator,
    queued_count: usize,
    queued_paused: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    try row.appendSlice(alloc, ui_render.hint_style);

    // The paused hint row already owns the controls, so it drops the affordance.
    const affordance = if (queued_paused) "" else " · ↑ to edit";
    var row_buf: [max_top_row_len]u8 = undefined;
    const label = if (queued_count == 0)
        "queued"
    else if (queued_count == 1)
        std.fmt.bufPrint(&row_buf, "1 queued message{s}", .{affordance}) catch "1 queued message"
    else
        std.fmt.bufPrint(&row_buf, "{d} queued messages{s}", .{ queued_count, affordance }) catch "queued messages";

    try row_text.appendClipped(alloc, &row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeQueueReviewHintRow(
    alloc: Allocator,
    width: u16,
    empty_draft: bool,
    cancel_all_available: bool,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    try row.appendSlice(alloc, ui_render.dim_style);
    const hint = if (cancel_all_available)
        "paused · enter to send · press esc to cancel all queued"
    else if (empty_draft)
        "paused · delete again to remove queued prompt · enter to send unchanged"
    else
        "paused · enter to send";
    try row_text.appendClipped(alloc, &row, hint, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "collapsed queue banner counts the waiting prompts and offers the review" {
    var single = try composeQueuedSummaryRow(std.testing.allocator, 1, false, 80);
    defer single.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, single.items, "1 queued message · ↑ to edit") != null);

    var many = try composeQueuedSummaryRow(std.testing.allocator, 3, false, 80);
    defer many.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, many.items, "3 queued messages · ↑ to edit") != null);
}

test "collapsed queue banner drops the affordance while the review is paused" {
    var row = try composeQueuedSummaryRow(std.testing.allocator, 2, true, 80);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "2 queued messages") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "↑ to edit") == null);
}

test "queue review hint explains empty draft deletion" {
    var row = try composeQueueReviewHintRow(std.testing.allocator, 100, true, false);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "delete again to remove queued prompt") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "enter to send unchanged") != null);
}

test "post-cancel queue review hint offers cancelling every queued prompt" {
    var row = try composeQueueReviewHintRow(std.testing.allocator, 100, false, true);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "press esc to cancel all queued") != null);
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

fn slashCompletionPickerActive(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) bool {
    if (ctx.input.picker.isInlinePickerDismissed(.slash) or modal_active or show_model_query or show_file_query) return false;
    if (ctx.input.picker.inlinePickerTriggerKind(&ctx.input.edit_state) != .slash) return false;
    // Mid-turn model-shaped input owns the footer slot even while the model list is hidden.
    if (ctx.stream.active and ctx.input.picker.isModelShapedInput(&ctx.input.edit_state)) return false;
    return slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items).len > 0;
}

pub fn slashCompletionPickerCount(ctx: RenderContext, modal_active: bool, show_model_query: bool, show_file_query: bool) usize {
    if (!slashCompletionPickerActive(ctx, modal_active, show_model_query, show_file_query)) return 0;
    const prefix = slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
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
    const display_input: []const u8 = if (ctx.queued_editor_active) "" else ctx.input.edit_state.input.items;
    const display_cursor: usize = if (ctx.queued_editor_active) 0 else ctx.input.edit_state.cursor;
    const display_images: []const types.ImageAttachment = if (ctx.queued_editor_active) &.{} else ctx.pending_images;
    const display_pasted_blocks: []const paste_blocks.PastedBlock = if (ctx.queued_editor_active) &.{} else ctx.input.entities.pasted_blocks.items;
    const display_image_tokens: []const visual_layout.ImageTokenSpan = if (ctx.queued_editor_active) &.{} else ctx.input.entities.image_tokens.items;
    const display_skill_tokens: []const visual_layout.SkillTokenSpan = if (ctx.queued_editor_active) &.{} else ctx.input.entities.skill_tokens.items;
    const slash_prefix = slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
    const raw_anchor: ?usize = if (ctx.queued_editor_active)
        null
    else if (show_model_query)
        ctx.model_completion_anchor
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
    const show_slash_query = slashCompletionPickerActive(ctx, modal_active, show_model_query, show_file_query);
    const slash_completion_count = if (show_slash_query)
        slashCompletionPickerCount(ctx, modal_active, show_model_query, show_file_query)
    else
        0;
    const picker_start_col = if (show_model_query or show_file_query or show_slash_query)
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

pub fn composeHintRow(
    alloc: Allocator,
    approval_active: bool,
    active_label: ?[]const u8,
    ctx: RenderContext,
    width: u16,
) !std.ArrayList(u8) {
    var question_hint_buf: [512]u8 = undefined;
    const question_hint = if (ctx.question) |projection|
        questionInteractionHint(projection, width, &question_hint_buf)
    else
        null;
    var hint_buf: [max_status_line_len]u8 = undefined;
    var hint_with_subagents_buf: [max_status_line_len + 128]u8 = undefined;
    const base_hint_line = ui_render.buildHintLine(
        ctx.stream.active,
        approval_active,
        ctx.has_api_key or (ctx.auth_picker.active and ctx.auth_picker.include_skip),
        ctx.model,
        ctx.permission_mode,
        ctx.queued_count,
        active_label,
        ctx.fast_mode,
        ctx.model_supports_fast,
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
    else if (ctx.selected_subagent_label) |label|
        if (ctx.selected_subagent_status) |status|
            std.fmt.bufPrint(
                &hint_with_subagents_buf,
                "{s} · {s} · {s}",
                .{
                    label,
                    switch (status) {
                        .awaiting_approval => "approval",
                        else => @tagName(status),
                    },
                    base_hint_line,
                },
            ) catch base_hint_line
        else
            base_hint_line
    else if (ctx.subagent_view_active)
        std.fmt.bufPrint(&hint_with_subagents_buf, "Subagent manager · tracked {d} · ctrl+x exit", .{ctx.subagent_count}) catch base_hint_line
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
        "↑↓ Navigate     Enter Open     Esc Close",
        "↑↓ Navigate  Enter Open  Esc Close",
        "↑↓ Move  Enter Open  Esc",
        "Enter Open  Esc Close",
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
        "↑↓ Navigate     ←→ Change     Esc Close",
        "↑↓ Navigate  ←→ Change  Esc Close",
        "↑↓ Move  ←→ Change  Esc",
        "←→ Change  Esc Close",
        "←→ Esc",
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

pub fn composeAppearanceMenuHintRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    const variants = [_][]const u8{
        "↑↓ Navigate     ←→ Change     Tab Section     Esc Close",
        "↑↓ Navigate  ←→ Change  Tab Section  Esc Close",
        "↑↓ Move  ←→ Change  Tab  Esc",
        "←→ Change  Esc Close",
        "←→ Esc",
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
            "",
            "",
            "",
        },
        .sandbox => [_][]const u8{
            "↑↓ Navigate     ←→ Change     Esc Close",
            "↑↓ Move  ←→ Change  Esc",
            "←→ Esc",
        },
        .usage => [_][]const u8{
            "←→ Scope     ↑↓ Model     Enter Expand     R Refresh     Esc Close",
            "←→ Scope  ↑↓ Model  Enter Expand  R Refresh  Esc",
            "←→ ↑↓  Enter  R  Esc",
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
    appearance: render_input.InputAppearance,
    prefix_style: ComposerPrefixStyle,
) !ComposedInputRows {
    var result = ComposedInputRows{};
    errdefer result.deinit(alloc);
    if (window.row_count == 0) return result;

    const tint = inputRowTint(appearance);
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
                tint,
                prefix_style,
            );
            try appendLayoutUnit(alloc, &current, source, unit, &remaining_cells, &omitted_positive_unit, tint);
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
                tint,
                prefix_style,
            );
            try finishComposedInputRow(alloc, &current, source.terminal_cols, tint);
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

// A queued prompt is an unsent draft, so it wears the composer's chrome instead
// of a submitted-turn card. Rows stay newline-terminated for the banner painter.
pub fn composeQueuedPromptCard(
    alloc: Allocator,
    source: visual_layout.Source,
    appearance: render_input.InputAppearance,
    prefix_style: ComposerPrefixStyle,
) ![]u8 {
    const summary = visual_layout.summarize(source, null);
    var rows = try composeVisibleInputRows(
        alloc,
        source,
        .{ .first_row = 0, .row_count = summary.total_rows },
        appearance,
        prefix_style,
    );
    defer rows.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (rows.rows.items) |row| {
        try out.writer.writeAll(row.items);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

pub fn appendInlineCompletionSuffix(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    width: u16,
    suffix: []const u8,
    appearance: render_input.InputAppearance,
) !void {
    if (suffix.len == 0) return;
    const used_cells = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used_cells >= @as(usize, width)) return;

    const tint = inputRowTint(appearance);
    if (tint.len != 0) try row.appendSlice(alloc, tint);
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
    tint: []const u8,
    prefix_style: ComposerPrefixStyle,
) !void {
    if (started.*) return;
    started.* = true;
    try row.appendSlice(alloc, tint);
    const prefix = visual_layout.inputPrefix(row_index);
    switch (prefix_style) {
        .arrow => if (hidden_above) {
            try row.appendSlice(alloc, ui_render.hint_style);
            try row_text.appendClipped(alloc, row, "↑ ", width);
            try row.appendSlice(alloc, if (tint.len > 0) tint else ui_render.reset_style);
        } else {
            try row_text.appendClipped(alloc, row, prefix.bytes, width);
        },
        .rail => {
            try row.appendSlice(alloc, ui_render.hint_style);
            try row_text.appendClipped(alloc, row, if (hidden_above) "┃↑" else "┃", width);
            try row.appendSlice(alloc, if (tint.len > 0) tint else ui_render.reset_style);
            if (!hidden_above and width > 1) try row_text.appendClipped(alloc, row, " ", width - 1);
        },
    }
    const width_usize: usize = width;
    remaining_cells.* = if (width_usize > prefix.cell_width) width_usize - prefix.cell_width else 0;
}

// Style prepended to each composed input row and re-applied after mid-row
// resets; empty when the row is untinted.
fn inputRowTint(appearance: render_input.InputAppearance) []const u8 {
    return switch (appearance) {
        .lines => "",
        .tint => ui_render.input_bar_style,
    };
}

fn appendLayoutUnit(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    source: visual_layout.Source,
    unit: visual_layout.Unit,
    remaining_cells: *usize,
    omitted_positive_unit: *bool,
    tint: []const u8,
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
        tint,
    );
    if (selected) {
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, tint);
    }
}

fn appendLayoutUnitContent(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    source: visual_layout.Source,
    unit: visual_layout.Unit,
    remaining_cells: *usize,
    omitted_positive_unit: *bool,
    tint: []const u8,
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
            if (visual_layout.skillTokenSourceLabel(token)) |source_label| {
                const emitted_name_cells = @min(display_width.visibleWidth(token.name), emit_cells);
                const label_cells = emit_cells - emitted_name_cells;
                if (label_cells > 0) {
                    try row_text.appendClipped(
                        alloc,
                        row,
                        visual_layout.skill_source_separator,
                        @intCast(@min(label_cells, std.math.maxInt(u16))),
                    );
                    const emitted_separator_cells = @min(
                        display_width.visibleWidth(visual_layout.skill_source_separator),
                        label_cells,
                    );
                    const source_cells = label_cells - emitted_separator_cells;
                    if (source_cells > 0) {
                        try row_text.appendClipped(
                            alloc,
                            row,
                            source_label,
                            @intCast(@min(source_cells, std.math.maxInt(u16))),
                        );
                    }
                }
            }
            try row.appendSlice(alloc, ui_render.reset_style);
            try row.appendSlice(alloc, tint);
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
            try row.appendSlice(alloc, tint);
            remaining_cells.* -= emit_cells;
            omitted_positive_unit.* = unit.cell_width > emit_cells;
        },
    }
}

fn finishComposedInputRow(alloc: Allocator, row: *std.ArrayList(u8), width: u16, tint: []const u8) !void {
    if (display_width.visibleWidthIgnoringAnsi(row.items) < @as(usize, width)) try row.appendSlice(alloc, "\x1b[K");
    if (tint.len != 0) try row.appendSlice(alloc, ui_render.reset_style);
}

const input_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true },
    .{ .kind = .models, .command = "/models", .help_entry = "/models", .completion_description = "browse available models", .presentation_category = .model },
    .{ .kind = .resume_session, .command = "/resume", .help_entry = "/resume", .completion_description = "resume a session", .presentation_category = .session },
    .{ .kind = .sandbox, .command = "/sandbox", .help_entry = "/sandbox [os|none]", .completion_description = "choose command sandbox behavior", .presentation_category = .security, .has_args = true },
};
const input_test_slash_registry = command_specs.SlashRegistry{ .commands = input_test_slash_specs[0..] };

fn testRenderContext(input: *const InputRuntime) RenderContext {
    return .{
        .slash_registry = input_test_slash_registry,
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
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
    var composed = try composeVisibleInputRows(alloc, source, window, .lines, .arrow);
    defer composed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), composed.rows.items.len);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "[Image 2]") != null);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "[Image 1]") == null);
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
    var full = try composeVisibleInputRows(alloc, full_source, full_window, .lines, .arrow);
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
    var short = try composeVisibleInputRows(alloc, short_source, short_window, .lines, .arrow);
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

    var plain_rows = try composeVisibleInputRows(
        alloc,
        .{ .input = source.input, .cursor = source.cursor, .terminal_cols = source.terminal_cols },
        window,
        .lines,
        .arrow,
    );
    defer plain_rows.deinit(alloc);

    var rows = try composeVisibleInputRows(alloc, source, window, .lines, .arrow);
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
        .lines,
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
        .lines,
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
    var composed = try composeVisibleInputRows(alloc, source, window, .lines, .arrow);
    defer composed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), window.first_row);
    try std.testing.expectEqual(@as(usize, 1), composed.rows.items.len);
    try std.testing.expect(std.mem.find(u8, composed.rows.items[0].items, "↑ ") != null);
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
    var arrow = try composeVisibleInputRows(alloc, source, window, .lines, .arrow);
    defer arrow.deinit(alloc);
    var rail = try composeVisibleInputRows(alloc, source, window, .lines, .rail);
    defer rail.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), window.first_row);
    try std.testing.expectEqual(@as(u16, 3), visual_layout.terminalColumn(summary.cursor, source.terminal_cols));
    try std.testing.expect(std.mem.find(u8, arrow.rows.items[0].items, "↑ ") != null);
    try std.testing.expect(std.mem.find(u8, rail.rows.items[0].items, "┃↑") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(arrow.rows.items[0].items) <= source.terminal_cols);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(rail.rows.items[0].items) <= source.terminal_cols);
}

test "queued prompt card wears composer chrome without a card background" {
    const alloc = std.testing.allocator;
    const source = visual_layout.Source{
        .input = "queued one\nqueued two",
        .cursor = 0,
        .terminal_cols = 40,
    };

    const rail = try composeQueuedPromptCard(alloc, source, .lines, .rail);
    defer alloc.free(rail);
    try std.testing.expect(std.mem.find(u8, rail, "\x1b[48;") == null);
    try std.testing.expect(std.mem.find(u8, rail, "❯") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rail, "┃"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rail, "\n"));

    const arrow = try composeQueuedPromptCard(alloc, source, .lines, .arrow);
    defer alloc.free(arrow);
    try std.testing.expect(std.mem.find(u8, arrow, "\x1b[48;") == null);
    try std.testing.expect(std.mem.find(u8, arrow, "❯ queued one") != null);
    try std.testing.expect(std.mem.find(u8, arrow, "  queued two") != null);
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

test "footer raw geometry ignores input appearance" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "first line\n/input tint wraps here");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var lines_ctx = testRenderContext(&input);
    lines_ctx.input_appearance = .lines;
    var tint_ctx = testRenderContext(&input);
    tint_ctx.input_appearance = .tint;

    const lines = measureRawInputGeometry(lines_ctx, 16, 20, true, false, false, false);
    const tinted = measureRawInputGeometry(tint_ctx, 16, 20, true, false, false, false);

    try std.testing.expectEqual(lines.summary.total_rows, tinted.summary.total_rows);
    try std.testing.expectEqual(lines.summary.cursor, tinted.summary.cursor);
    try std.testing.expectEqual(lines.summary.anchor, tinted.summary.anchor);
    try std.testing.expectEqual(lines.window, tinted.window);
    try std.testing.expectEqual(lines.total_lines, tinted.total_lines);
    try std.testing.expectEqual(lines.input_extra, tinted.input_extra);
    try std.testing.expectEqual(lines.slash_completion_count, tinted.slash_completion_count);
    try std.testing.expectEqual(lines.show_slash_query, tinted.show_slash_query);
    try std.testing.expectEqual(lines.picker_start_col, tinted.picker_start_col);
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

test "queued editor keeps standalone composer geometry empty" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "first queued line\nsecond queued line");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var ctx = testRenderContext(&input);
    ctx.queued_editor_active = true;
    const geometry = measureRawInputGeometry(ctx, 12, 20, true, false, false, false);

    try std.testing.expectEqual(@as(usize, 1), geometry.summary.total_rows);
    try std.testing.expectEqual(@as(u16, 1), geometry.total_lines);
    try std.testing.expectEqual(@as(u16, 0), geometry.input_extra);
    try std.testing.expectEqual(@as(usize, 0), geometry.summary.cursor.raw_offset);
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
    try arg.edit_state.input.appendSlice(alloc, "  /sandbox ");
    arg.edit_state.cursor = arg.edit_state.input.items.len;
    const arg_geometry = measureRawInputGeometry(testRenderContext(&arg), 80, 20, true, false, false, false);
    try std.testing.expectEqual(@as(usize, 2 + "/sandbox ".len), arg_geometry.summary.anchor.?.raw_offset);
    try std.testing.expectEqual(@as(usize, 11), arg_geometry.summary.anchor.?.content_column);
    try std.testing.expectEqual(@as(u16, 14), arg_geometry.picker_start_col);

    var wrapped = InputRuntime{};
    defer wrapped.deinit(alloc);
    try wrapped.edit_state.input.appendSlice(alloc, "       /sandbox ");
    wrapped.edit_state.cursor = wrapped.edit_state.input.items.len;
    // Margin spaces hang on their row instead of wrapping, so row 0 holds
    // all 7 leading spaces, row 1 is "/sandb", and row 2 is "ox " with the
    // trailing space hanging at column 2.
    const wrapped_geometry = measureRawInputGeometry(testRenderContext(&wrapped), 8, 4, true, false, false, false);
    try std.testing.expectEqual(@as(usize, 3), wrapped_geometry.summary.total_rows);
    try std.testing.expectEqual(@as(usize, 2), wrapped_geometry.summary.cursor.row_index);
    try std.testing.expectEqual(@as(usize, 3), wrapped_geometry.summary.cursor.content_column);
    try std.testing.expectEqual(@as(usize, 2), wrapped_geometry.summary.anchor.?.row_index);
    try std.testing.expectEqual(@as(usize, 3), wrapped_geometry.summary.anchor.?.content_column);
    try std.testing.expectEqual(@as(u16, 6), wrapped_geometry.picker_start_col);
    try std.testing.expectEqual(@as(u16, 0), cappedInputRows(3, 4, true).input_extra);
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

test "footer slash completion separates query activity from candidate count" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    try input.textReplacementState().replace(alloc, "/hezzzzz");
    const no_match = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(no_match.show_slash_query);
    try std.testing.expectEqual(@as(usize, 0), no_match.slash_completion_count);

    try input.textReplacementState().replace(alloc, "/resume ");
    const no_args = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(!no_args.show_slash_query);
    try std.testing.expectEqual(@as(usize, 0), no_args.slash_completion_count);

    try input.textReplacementState().replace(alloc, "/sandbox ");
    const arguments = measureRawInputGeometry(testRenderContext(&input), 80, 20, true, false, false, false);
    try std.testing.expect(arguments.show_slash_query);
    try std.testing.expectEqual(@as(usize, 2), arguments.slash_completion_count);
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
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .fast_mode = true,
        .model_supports_fast = true,
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 32);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, row.items, ui_render.statusline_style));
    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1 · ⚡︎") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[14G") == null);
}

test "compose hint row uses dots in subagent view" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 2,
        .subagent_view_active = true,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 96);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "Subagent manager · tracked 2 · ctrl+x exit") != null);
    try std.testing.expect(std.mem.find(u8, row.items, " | ") == null);
}

test "compose hint row keeps active child identity ahead of model status" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.selected_subagent_label = "header-child";
    ctx.selected_subagent_status = .awaiting_approval;

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 64);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "header-child · approval") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1") != null);
}

test "compose hint row omits the inactive subagent manager marker" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 2,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .fast_mode = true,
        .model_supports_fast = true,
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 96);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1 · ⚡︎") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "subagents 2") == null);
    try std.testing.expect(std.mem.find(u8, row.items, "ctrl+x manager") == null);
}

test "compose hint row does not advertise background terminals or the manager shortcut" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.shimmer_pos = 1;

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 96);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "background (") == null);
    try std.testing.expect(std.mem.find(u8, row.items, "ctrl+x manager") == null);
}

test "compose hint row right-aligns upgrade status" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .upgrade_status = "Update installed: ctrl+g to reload",
        .statusline = .{
            .workspace_label = "/a/long/workspace/path/that/uses/the/statusline-tail",
        },
        .input = &input,
    };

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 48);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "gpt-5.1") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Update installed: ctrl+g to reload") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[15G") != null);
}

test "compose hint row right-aligns upgrade status after styled auto mode" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    const ctx: RenderContext = .{
        .stream = .{},
        .has_api_key = true,
        .model = "openai/gpt-4o",
        .permission_mode = .auto,
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .upgrade_status = "Update installed: ctrl+g to reload",
        .input = &input,
    };

    ui_render.initTheme(false, null);
    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 56);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "auto") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "gpt-4o") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Update installed: ctrl+g to reload") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[23G") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 56);
}

test "compose hint row prioritizes red yolo warning with compact fallback" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.danger_status = "YOLO enabled: permissions and sandboxing disabled";
    ctx.danger_status_compact = "YOLO: unrestricted";

    var full = try composeHintRow(std.testing.allocator, false, null, ctx, 80);
    defer full.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, full.items, ctx.danger_status) != null);
    try std.testing.expect(std.mem.find(u8, full.items, ui_render.red_style) != null);

    var compact = try composeHintRow(std.testing.allocator, false, null, ctx, 24);
    defer compact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, compact.items, ctx.danger_status_compact) != null);
    try std.testing.expect(std.mem.find(u8, compact.items, ctx.danger_status) == null);

    ctx.esc_clear_armed = true;
    var suppressed = try composeHintRow(std.testing.allocator, false, null, ctx, 80);
    defer suppressed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, suppressed.items, "esc again to clear") != null);
    try std.testing.expect(std.mem.find(u8, suppressed.items, "YOLO") == null);
}

test "compose hint row yields the yolo warning to a pending ctrl+c quit hint" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var ctx = testRenderContext(&input);
    ctx.danger_status = "YOLO enabled: permissions and sandboxing disabled";
    ctx.danger_status_compact = "YOLO: unrestricted";
    ctx.ctrl_c_pending = true;

    // Reported as unpainted so the warning's visible budget pauses.
    try std.testing.expectEqualStrings("", dangerStatusText(false, ctx, 60));

    var pending = try composeHintRow(std.testing.allocator, false, null, ctx, 60);
    defer pending.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, pending.items, "press ctrl+c again to exit") != null);
    try std.testing.expect(std.mem.find(u8, pending.items, "YOLO") == null);

    ctx.ctrl_c_pending = false;
    try std.testing.expectEqualStrings(ctx.danger_status, dangerStatusText(false, ctx, 60));

    var resumed = try composeHintRow(std.testing.allocator, false, null, ctx, 60);
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
        ctx.upgrade_status = "Update installed: ctrl+g to reload";
        var row = try composeHintRow(std.testing.allocator, false, null, ctx, case.width);
        defer row.deinit(std.testing.allocator);

        try std.testing.expect(std.mem.find(u8, row.items, case.hint) != null);
        try std.testing.expect(std.mem.find(u8, row.items, "model-x") == null);
        try std.testing.expect(std.mem.find(u8, row.items, "Update installed: ctrl+g to reload") == null);
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

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 120);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "  Question 1 of 3") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 120);

    var narrow = try composeHintRow(std.testing.allocator, false, null, ctx, 40);
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

    var row = try composeHintRow(std.testing.allocator, false, null, ctx, 120);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "Tab Questions") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "tab to choose") == null);
}

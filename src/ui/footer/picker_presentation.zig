const std = @import("std");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const credentials = @import("../../core/auth/credentials.zig");
const login_flow = @import("../../core/auth/login_flow.zig");
const picker_state = @import("../../core/input/picker_state.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const ui_render = @import("../render.zig");
const input_presentation = @import("input_presentation.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const team_query_prefix = "   Choose a Vercel team · Search: ";
const compact_team_query_prefix = "Search: ";

const TeamQueryProjection = struct {
    prefix: []const u8,
    query: []const u8,

    fn cursorColumn(self: TeamQueryProjection, width: u16) u16 {
        const content_end = display_width.visibleWidth(self.prefix) +
            display_width.visibleWidth(self.query) + 1;
        return @intCast(@min(content_end, width));
    }
};

pub fn authPickerQueryCursorColumn(view: auth_runtime.PickerView, width: u16) ?u16 {
    if (view.stage != .change_team or width == 0) return null;
    return teamQueryProjection(view.team_query, width).cursorColumn(width);
}

fn teamQueryProjection(query: []const u8, width: u16) TeamQueryProjection {
    const available: usize = width;
    if (query.len == 0) return .{
        .prefix = display_width.prefixByWidth(team_query_prefix, available),
        .query = "",
    };

    const prefix = if (display_width.visibleWidth(team_query_prefix) < available)
        team_query_prefix
    else if (display_width.visibleWidth(compact_team_query_prefix) < available)
        compact_team_query_prefix
    else
        "";
    const query_width = available - display_width.visibleWidth(prefix);
    return .{
        .prefix = prefix,
        .query = display_width.suffixByWidth(query, query_width),
    };
}

pub fn authPickerRowCount(view: auth_runtime.PickerView) u16 {
    if (view.stage == .sign_in) return 7;
    if (view.stage == .api_key) return 4;
    if (view.stage == .root and view.include_skip) return 19;
    return @intCast(1 + @max(view.choiceCount(), 1));
}

pub noinline fn composeAuthPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (view.stage == .sign_in) {
        return composeSignInPickerRow(alloc, view.sign_in, view.sign_in_source, row_index, width);
    }
    if (view.stage == .api_key) {
        return composeApiKeyPickerRow(alloc, view.api_key_mask_count, row_index, width);
    }
    if (view.stage == .root and view.include_skip) {
        return composeOnboardingPickerRow(alloc, view, row_index, row_count, width);
    }

    var row: std.ArrayList(u8) = .empty;
    if (width == 0) return row;

    const show_header = row_index == 0 and (row_count > 1 or view.stage == .change_team);
    if (show_header) {
        try row.appendSlice(alloc, ui_render.dim_style);
        if (view.stage == .change_team) {
            const projection = teamQueryProjection(view.team_query, width);
            try row_text.appendClipped(alloc, &row, projection.prefix, width);
            const remaining: u16 = width -| @as(u16, @intCast(display_width.visibleWidth(projection.prefix)));
            try row_text.appendClipped(alloc, &row, projection.query, remaining);
            try row.appendSlice(alloc, ui_render.reset_style);
            return row;
        }
        const header = switch (view.stage) {
            .root => "   Setup",
            .provider => "   Switch provider",
            .sign_in => unreachable,
            .api_key => unreachable,
            .change_team => unreachable,
            .switch_credential => "   Use this credential",
        };
        try row_text.appendClipped(alloc, &row, header, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    const maybe_choice = if (row_count == 1)
        view.selected_choice
    else if (row_index > 0) blk: {
        const window = pickerWindow(view.choiceCount(), view.selectedIndex(), row_count - 1);
        const choice_index = window.start + row_index - 1;
        if (choice_index >= window.end) break :blk null;
        break :blk view.choiceAt(choice_index);
    } else null;
    const choice = maybe_choice orelse {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendClipped(alloc, &row, switch (view.stage) {
            .root => "",
            .provider => "     No providers available",
            .sign_in => unreachable,
            .api_key => unreachable,
            .change_team => if (view.team_query.len == 0)
                "     No Vercel teams available"
            else
                "     No matching Vercel teams",
            .switch_credential => "     No credentials available",
        }, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    };

    const selected = view.choiceIsSelected(choice);
    const enabled = view.choiceEnabled(choice);
    try row.appendSlice(
        alloc,
        if (selected and enabled) ui_render.selected_completion_style else ui_render.dim_style,
    );

    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(
        &label_buf,
        "{s}{s}",
        .{ if (selected) "   › " else "     ", view.choiceLabel(choice) },
    ) catch view.choiceLabel(choice);
    try row_text.appendClipped(alloc, &row, label, width);

    const description_col = authPickerDescriptionColumn(view);
    if (width >= description_col) {
        try row_text.appendAbsoluteColumn(alloc, &row, description_col);
        const description = view.choiceDescription(choice);
        try row_text.appendClipped(alloc, &row, description, width - description_col + 1);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const onboarding_note = "   ⚠︎ Note: fx is experimental and defaults to auto mode.";
const onboarding_note_link = onboarding_note ++ " \x1b]8;id=fx-onboarding;https://fx.sh/docs/stability\x1b\\\x1b[4mLearn more\x1b[24m\x1b]8;;\x1b\\";

fn onboardingProjectedRowIndex(view: auth_runtime.PickerView, row_index: u16, row_count: u16) u16 {
    if (row_count >= 19) return row_index;

    const selected_row: u16 = 8 + @as(u16, @intCast(view.selectedIndex()));
    const priority = [_]u16{ selected_row, 12, 9, 10, 8, 11, 16, 7, 13, 5, 0, 2, 3, 6, 14, 15, 1, 4, 17, 18 };

    var projected_index: u16 = 0;
    for (0..19) |source_row| {
        for (priority[0..@min(row_count, priority.len)]) |included_row| {
            if (source_row != included_row) continue;
            if (projected_index == row_index) return @intCast(source_row);
            projected_index += 1;
            break;
        }
    }
    return 18;
}

fn composeOnboardingPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const source_row_index = onboardingProjectedRowIndex(view, row_index, row_count);
    const maybe_choice_index: ?usize = switch (source_row_index) {
        8 => 0,
        9 => 1,
        10 => 2,
        11 => 3,
        12 => 4,
        else => null,
    };
    if (maybe_choice_index) |choice_index| {
        const choice = view.choiceAt(choice_index) orelse return row;
        const selected = view.choiceIsSelected(choice);
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
        var label_buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buf,
            "{s}{s}",
            .{ if (selected) "   › " else "     ", view.choiceLabel(choice) },
        ) catch view.choiceLabel(choice);
        try row_text.appendClipped(alloc, &row, label, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    try row.appendSlice(alloc, ui_render.hint_style);
    const label = switch (source_row_index) {
        0 => "   Welcome to fx",
        1 => "",
        2 => "   fx can access AI models with an account, subscription, or API key.",
        3 => "   Choose a sign-in option below, or add your own API key.",
        4 => "",
        5 => "   You can change this anytime with /setup.",
        6 => "",
        7 => "   Get started",
        13 => if (display_width.visibleWidthIgnoringAnsi(onboarding_note_link) <= width) onboarding_note_link else onboarding_note,
        14, 15 => "",
        16 => "   Esc to set up later · Explore all commands with /help",
        17, 18 => "",
        else => "",
    };
    try row_text.appendClipped(alloc, &row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSignInPickerRow(
    alloc: Allocator,
    snapshot: login_flow.SignInSnapshot,
    source: credentials.Source,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    try row.appendSlice(
        alloc,
        if (row_index == 2 or row_index == 3)
            ui_render.selected_completion_style
        else
            ui_render.dim_style,
    );
    if (row_index == 2 and source == .chatgpt_subscription) {
        const prefix = "   Open   ";
        try row_text.appendClipped(alloc, &row, prefix, width);
        const used: u16 = @intCast(@min(display_width.visibleWidth(prefix), width));
        const remaining = width -| used;
        if (remaining > 0) {
            try row.appendSlice(alloc, "\x1b]8;id=fx-codex-auth;");
            try row.appendSlice(alloc, snapshot.verification_uri);
            try row.appendSlice(alloc, "\x1b\\\x1b[4m");
            try row_text.appendClipped(alloc, &row, "Authorize with Codex", remaining);
            try row.appendSlice(alloc, "\x1b[24m\x1b]8;;\x1b\\");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    var label_buf: [512]u8 = undefined;
    const label = switch (row_index) {
        0 => if (source == .chatgpt_subscription)
            "   Sign in with Codex"
        else if (source == .grok_subscription)
            "   Sign in with Grok"
        else if (source == .claude_subscription)
            "   Sign in with Claude"
        else
            "   Sign in with Vercel",
        1, 4 => "",
        2 => std.fmt.bufPrint(
            &label_buf,
            "   Open   {s}",
            .{snapshot.verification_uri},
        ) catch if (source == .chatgpt_subscription)
            "   Open the Codex authorization page"
        else if (source == .grok_subscription)
            "   Open the Grok authorization page"
        else if (source == .claude_subscription)
            "   Open the Claude authorization page"
        else
            "   Open the Vercel device authorization page",
        3 => if (source == .claude_subscription)
            "   Paste the authorization code from the browser"
        else if (snapshot.user_code.len == 0)
            ""
        else
            std.fmt.bufPrint(
                &label_buf,
                "   Code   {s}",
                .{snapshot.user_code},
            ) catch "   Code unavailable",
        5 => switch (snapshot.state) {
            .idle => "   Preparing sign-in…",
            .polling => "   Waiting for authorization…",
            .succeeded => "   Authorization complete",
            .failed => "   Sign-in failed",
            .cancelled => "   Sign-in cancelled",
        },
        6 => if (source == .claude_subscription)
            "   Enter reopens browser · paste the code in the terminal · Esc cancels"
        else
            "   Enter reopens browser · Esc cancels",
        else => "",
    };
    try row_text.appendClipped(alloc, &row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeApiKeyPickerRow(
    alloc: Allocator,
    mask_count: usize,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    try row.appendSlice(alloc, if (row_index == 1)
        ui_render.selected_completion_style
    else
        ui_render.dim_style);
    switch (row_index) {
        0 => try row_text.appendClipped(alloc, &row, "   Paste your AI Gateway API key", width),
        1 => {
            try row_text.appendClipped(alloc, &row, "   ┃ ", width);
            if (mask_count == 0) {
                try row.appendSlice(alloc, ui_render.dim_style);
                try row_text.appendClipped(alloc, &row, "Paste or type a key", width -| 5);
            } else {
                for (0..@min(mask_count, width -| 5)) |_| try row.appendSlice(alloc, "•");
            }
        },
        2 => try row_text.appendClipped(alloc, &row, "   Enter saves · Esc cancels", width),
        3 => {
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(
                &label_buf,
                "   Saves to {s}",
                .{credentials.stored_key_backend_label},
            ) catch "   Saves to configured credential store";
            try row_text.appendClipped(alloc, &row, label, width);
        },
        else => {},
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn authPickerDescriptionColumn(view: auth_runtime.PickerView) u16 {
    var column: usize = 31;
    var index: usize = 0;
    while (view.choiceAt(index)) |choice| : (index += 1) {
        const label_end = 5 + display_width.visibleWidth(view.choiceLabel(choice));
        column = @max(column, label_end + 2);
    }
    return @intCast(@min(column, std.math.maxInt(u16)));
}

pub fn pickerRowCount(completion_count: usize) u16 {
    if (completion_count == 0) return 1;
    return @intCast(@min(completion_count, input_presentation.max_model_picker_rows));
}

pub fn activeListPickerReservedRows(terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const available_rows = terminal_rows -| fixed_rows;
    if (available_rows == 0) return 1;
    return @min(input_presentation.max_model_picker_rows, available_rows);
}

pub fn authPickerReservedRows(view: auth_runtime.PickerView, terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    if (view.stage == .sign_in or (view.stage == .root and view.include_skip)) {
        const available_rows = terminal_rows -| (5 +| input_extra +| banner_rows);
        return @min(authPickerRowCount(view), @max(available_rows, 1));
    }
    return @min(authPickerRowCount(view), activeListPickerReservedRows(terminal_rows, input_extra, banner_rows));
}

pub const PickerWindow = list_window.Window;

pub fn pickerWindow(count: usize, selected: usize, max_rows: u16) PickerWindow {
    return list_window.centered(count, selected, max_rows);
}

pub fn edgeScrollPickerWindow(count: usize, selected: usize, max_rows: u16) PickerWindow {
    return list_window.edgeFromSelection(count, selected, max_rows);
}

pub fn edgeScrollPickerWindowFromStart(count: usize, start: usize, max_rows: u16) PickerWindow {
    return list_window.edgeFromStart(count, start, max_rows);
}

pub fn updateEdgeScrollPickerWindowStart(current_start: usize, count: usize, selected: usize, max_rows: u16) usize {
    return list_window.updateEdgeStart(current_start, count, selected, max_rows);
}

pub const SlashMenuLayout = struct {
    row_count: u16,
    selectable_rows: u16,
    show_header: bool,
    selected: usize,
    command_count: usize,
    result_count: usize,
    window: PickerWindow,
};

pub fn slashMenuLayout(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (command_specs.argCompletionAnchor(prefix) != 0) return null;
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    const result_count = mixedSlashCompletionCount(registry, prefix, skills);
    if (result_count == 0) return null;

    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const minimum_transcript_rows: u16 = 5;
    const available_picker_rows = (terminal_rows -| fixed_rows) -| minimum_transcript_rows;
    const row_budget = @min(input_presentation.max_model_picker_rows + 2, @max(available_picker_rows, 1));
    const show_header = row_budget > 2;
    const header_rows: u16 = if (show_header) 2 else 0;
    const selectable_rows = row_budget - header_rows;
    const selected = selection_index % result_count;
    const window_start = updateEdgeScrollPickerWindowStart(current_window_start, result_count, selected, selectable_rows);
    const window = edgeScrollPickerWindowFromStart(result_count, window_start, selectable_rows);

    return .{
        .row_count = selectable_rows + header_rows,
        .selectable_rows = selectable_rows,
        .show_header = show_header,
        .selected = selected,
        .command_count = command_count,
        .result_count = result_count,
        .window = window,
    };
}

pub noinline fn composePickerOptionRow(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    // The model picker (including its effort and fast stages) signals
    // selection by brightness alone, like the question panel; the other
    // pickers keep the filled row.
    const selected_style = switch (kind) {
        .model_stage => ui_render.selected_completion_style,
        .file, .slash, .auth => ui_render.approval_button_inactive_style,
    };
    try row.appendSlice(alloc, if (selected) selected_style else ui_render.dim_style);

    const label_width: u16 = @intCast(width_usize - @as(usize, start_col - 1));
    try row_text.appendClipped(alloc, &row, item, label_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeFilePickerOptionRow(
    alloc: Allocator,
    start_col: u16,
    item: file_index.SearchResult,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    const base_style = if (selected) ui_render.approval_button_inactive_style else ui_render.dim_style;
    try row.appendSlice(alloc, base_style);
    try appendFilePickerLabel(
        alloc,
        &row,
        item,
        @intCast(width_usize - @as(usize, start_col - 1)),
        base_style,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composePickerStatusRow(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    model_stage: picker_state.ModelPickerStage,
    loading: bool,
    failed: bool,
    start_col: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    try row.appendSlice(alloc, ui_render.dim_style);

    const label = switch (kind) {
        .model_stage => switch (model_stage) {
            .model => if (loading)
                "loading models..."
            else if (failed)
                "unable to load models"
            else
                "no matching models",
            .effort => "no matching effort",
            .fast => "no matching mode",
        },
        .file => if (loading)
            "indexing files..."
        else if (failed)
            "unable to index files"
        else
            "no matching files",
        .slash => "no matching slash commands",
        .auth => "authentication actions unavailable",
    };

    try row_text.appendClipped(alloc, &row, label, @intCast(width_usize - @as(usize, start_col - 1)));
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendFilePickerLabel(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    width: u16,
    base_style: []const u8,
) !void {
    const path = item.path;
    const width_usize: usize = width;
    const slash_width: usize = @intFromBool(item.kind == .directory);
    if (display_width.visibleWidth(path) + slash_width <= width_usize) {
        try appendStyledPathRange(alloc, row, item, 0, path.len, base_style);
        if (item.kind == .directory) try row.append(alloc, '/');
        return;
    }

    const basename = std.fs.path.basename(path);
    const basename_start = @intFromPtr(basename.ptr) - @intFromPtr(path.ptr);
    const dirname = std.fs.path.dirname(path) orelse {
        try appendBasenameProjection(alloc, row, item, basename_start, width_usize, base_style);
        return;
    };
    const separator = "/";
    const separator_width = display_width.visibleWidth(separator);
    const minimum_segmented_width = 8;
    if (width_usize < minimum_segmented_width) {
        try appendBasenameProjection(alloc, row, item, basename_start, width_usize, base_style);
        return;
    }

    const directory_budget = @min(display_width.visibleWidth(dirname), @min(@max(width_usize / 3, 3), 12));
    const basename_budget = width_usize - directory_budget - separator_width - slash_width;

    try appendStyledEllipsizedRange(alloc, row, item, 0, dirname.len, directory_budget, .middle, base_style);
    try appendStyledPathRange(alloc, row, item, dirname.len, basename_start, base_style);
    try appendStyledEllipsizedRange(alloc, row, item, basename_start, path.len, basename_budget, .prefix_biased, base_style);
    if (item.kind == .directory) try row.append(alloc, '/');
}

const FileEllipsisPlacement = enum { middle, prefix_biased };

fn appendBasenameProjection(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    basename_start: usize,
    width: usize,
    base_style: []const u8,
) !void {
    if (item.kind == .directory) {
        if (width == 0) return;
        if (width > 1) {
            try appendStyledEllipsizedRange(alloc, row, item, basename_start, item.path.len, width - 1, .prefix_biased, base_style);
        }
        try row.append(alloc, '/');
        return;
    }
    try appendStyledEllipsizedRange(alloc, row, item, basename_start, item.path.len, width, .prefix_biased, base_style);
}

fn appendStyledEllipsizedRange(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    source_start: usize,
    source_end: usize,
    width: usize,
    placement: FileEllipsisPlacement,
    base_style: []const u8,
) !void {
    if (width == 0 or source_start >= source_end) return;
    const source = item.path[source_start..source_end];
    if (display_width.visibleWidth(source) <= width) {
        try appendStyledPathRange(alloc, row, item, source_start, source_end, base_style);
        return;
    }
    if (width == 1) {
        try row.appendSlice(alloc, "…");
        return;
    }

    const content_width = width - 1;
    const prefix_width, const suffix_width = switch (placement) {
        .middle => .{ (content_width + 1) / 2, content_width / 2 },
        .prefix_biased => .{ content_width - content_width / 4, content_width / 4 },
    };
    const prefix = display_width.prefixByWidth(source, prefix_width);
    const suffix = displaySafeSuffixByWidth(source, suffix_width);
    try appendStyledPathRange(alloc, row, item, source_start, source_start + prefix.len, base_style);
    try row.appendSlice(alloc, "…");
    try appendStyledPathRange(alloc, row, item, source_end - suffix.len, source_end, base_style);
}

fn displaySafeSuffixByWidth(source: []const u8, width: usize) []const u8 {
    const suffix = display_width.suffixByWidth(source, width);
    if (suffix.len == 0 or suffix.len == source.len) return suffix;

    var start: usize = 0;
    while (start < suffix.len) {
        const unit = display_width.displayUnitAt(suffix, start);
        if (unit.cell_width != 0) break;
        start += unit.byte_len;
    }
    return suffix[start..];
}

fn appendStyledPathRange(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    source_start: usize,
    source_end: usize,
    base_style: []const u8,
) !void {
    var cursor = source_start;
    for (item.matched_spans) |span| {
        const match_start: usize = span.byte_start;
        const match_end: usize = span.byte_end;
        if (match_end <= source_start) continue;
        if (match_start >= source_end) break;

        const visible_start = @max(match_start, source_start);
        const visible_end = @min(match_end, source_end);
        if (cursor < visible_start) try row.appendSlice(alloc, item.path[cursor..visible_start]);
        try row.appendSlice(alloc, ui_render.bold_style);
        try row.appendSlice(alloc, item.path[visible_start..visible_end]);
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, base_style);
        cursor = visible_end;
    }
    if (cursor < source_end) try row.appendSlice(alloc, item.path[cursor..source_end]);
}

pub fn slashCompletionCommandColumnWidth(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    window: PickerWindow,
) usize {
    var width: usize = 0;
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const label = command_specs.nthSlashCompletionLabel(registry, prefix, match_idx) orelse continue;
        width = @max(width, display_width.visibleWidth(label));
    }
    return width + 2;
}

const MixedSlashCompletionEntry = union(enum) {
    command: usize,
    skill: skill_runtime.Skill,
};

pub fn mixedSlashCompletionCount(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill) usize {
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    if (command_specs.argCompletionAnchor(prefix) != 0) return command_count;
    if (prefix.len == 0 or prefix[0] != '/') return command_count;
    return command_count + skill_runtime.skillMenuFilterQueryCount(skills, .all, prefix[1..]);
}

pub fn mixedSlashCompletionIsSkill(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) bool {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return false) {
        .command => false,
        .skill => true,
    };
}

pub fn nthMixedSlashCompletionSkill(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?skill_runtime.Skill {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => null,
        .skill => |skill| skill,
    };
}

pub fn nthMixedSlashCompletionText(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?[]const u8 {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => |match_idx| command_specs.nthSlashCompletion(registry, prefix, match_idx),
        .skill => |skill| skill.name,
    };
}

pub fn mixedSlashCompletionCommandColumnWidth(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    window: PickerWindow,
) usize {
    var width: usize = 0;
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const label = mixedSlashCompletionLabel(registry, prefix, skills, match_idx) orelse continue;
        width = @max(width, display_width.visibleWidth(label));
    }
    return width + 2;
}

fn mixedSlashCompletionEntry(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?MixedSlashCompletionEntry {
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    if (n < command_count) return .{ .command = n };
    if (command_specs.argCompletionAnchor(prefix) != 0) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    const skill = skill_runtime.skillMenuSkillAtQuery(skills, .all, prefix[1..], n - command_count) orelse return null;
    return .{ .skill = skill };
}

fn mixedSlashCompletionLabel(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?[]const u8 {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => |match_idx| command_specs.nthSlashCompletionLabel(registry, prefix, match_idx),
        .skill => |skill| skill.name,
    };
}

pub fn composeSlashMenuHeaderRow(
    alloc: Allocator,
    prefix: []const u8,
    layout: SlashMenuLayout,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const noun = if (layout.command_count == layout.result_count) "Commands" else "Results";
    var left_buf: [96]u8 = undefined;
    const left = if (std.mem.eql(u8, prefix, "/"))
        std.fmt.bufPrint(&left_buf, "{s} {d} · Type to filter", .{ noun, layout.result_count }) catch noun
    else
        std.fmt.bufPrint(&left_buf, "{s} {d}", .{ noun, layout.result_count }) catch noun;

    var range_buf: [48]u8 = undefined;
    const range = if (layout.result_count > layout.selectable_rows)
        std.fmt.bufPrint(&range_buf, "{d}–{d}", .{ layout.window.start + 1, layout.window.end }) catch ""
    else
        "";

    const content_width: usize = @as(usize, width) -| 1;
    const range_width = display_width.visibleWidth(range);
    const left_width = if (range_width > 0 and content_width > range_width + 2)
        content_width - range_width - 2
    else
        content_width;

    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, left, left_width);
    if (range_width > 0 and content_width > range_width + 2) {
        try appendSpacesToVisibleWidth(alloc, &row, content_width - range_width);
        try row.appendSlice(alloc, range);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const SlashMenuRowContent = struct {
    label: []const u8,
    description: []const u8,
    metadata: []const u8,
};

pub const SlashMenuColumnWidths = struct {
    label: usize,
    metadata: usize,
};

fn slashMenuRowContent(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    include_metadata: bool,
) ?SlashMenuRowContent {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, match_idx) orelse return null) {
        .command => |command_idx| .{
            .label = command_specs.nthSlashCompletionLabel(registry, prefix, command_idx) orelse return null,
            .description = command_specs.nthSlashCompletionDescription(registry, prefix, command_idx) orelse "",
            .metadata = if (include_metadata)
                if (command_specs.nthSlashCompletionCategory(registry, prefix, command_idx)) |category| category.label() else ""
            else
                "",
        },
        .skill => |skill| .{
            .label = skill.name,
            .description = skill.description,
            .metadata = if (include_metadata) skill_runtime.skillSourceShortLabel(skill.source) else "",
        },
    };
}

pub fn mixedSlashMenuColumnWidths(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    window: PickerWindow,
    include_metadata: bool,
) SlashMenuColumnWidths {
    var widths: SlashMenuColumnWidths = .{ .label = 0, .metadata = 0 };
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const content = slashMenuRowContent(registry, prefix, skills, match_idx, include_metadata) orelse continue;
        widths.label = @max(widths.label, display_width.visibleWidth(content.label));
        widths.metadata = @max(widths.metadata, display_width.visibleWidth(content.metadata));
    }
    return widths;
}

pub noinline fn composeSlashMenuOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
    include_metadata: bool,
) !std.ArrayList(u8) {
    const content = slashMenuRowContent(registry, prefix, skills, match_idx, include_metadata) orelse return .empty;

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    // Selection is signaled by brightness alone (like the model picker); no
    // caret marker. The two-column indent stays fixed so rows stay aligned.
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, "  ");

    const content_width: usize = @as(usize, width) -| 1;
    const marker_width: usize = 2;
    if (content_width <= marker_width) {
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    try row_text.appendSingleLineEllipsized(alloc, &row, content.label, content_width - marker_width);

    const label_width = display_width.visibleWidth(content.label);
    const column_gap: usize = 3;
    const description_start = @min(content_width, marker_width + @max(column_widths.label, label_width) + column_gap);
    try appendSpacesToVisibleWidth(alloc, &row, description_start);

    const metadata_width = display_width.visibleWidth(content.metadata);
    const min_description_width: usize = 24;
    const metadata_start = content_width -| column_widths.metadata;
    const metadata_fits = metadata_width > 0 and column_widths.metadata > 0 and column_widths.metadata <= content_width;
    const show_metadata = if (content.description.len > 0)
        metadata_fits and metadata_start >= description_start + min_description_width + column_gap
    else
        metadata_fits and metadata_start >= description_start + column_gap;
    const description_width = if (show_metadata)
        metadata_start - description_start - column_gap
    else
        content_width - description_start;

    if (content.description.len > 0 and description_width > 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, content.description, description_width);
    }
    if (show_metadata) {
        try appendSpacesToVisibleWidth(alloc, &row, metadata_start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, content.metadata);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendSpacesToVisibleWidth(alloc: Allocator, row: *std.ArrayList(u8), target_width: usize) !void {
    var visible = display_width.visibleWidthIgnoringAnsi(row.items);
    while (visible < target_width) : (visible += 1) try row.append(alloc, ' ');
}

pub fn composeSlashCompletionOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    match_idx: usize,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0) return row;

    const label = command_specs.nthSlashCompletionLabel(registry, prefix, match_idx) orelse return row;
    const description = command_specs.nthSlashCompletionDescription(registry, prefix, match_idx) orelse "";
    const label_col: u16 = if (start_col > 1) start_col else 3;
    if (label_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, label_col);

    const before_label_width: usize = label_col - 1;
    if (before_label_width >= width_usize) return row;
    const remaining: u16 = @intCast(width_usize - before_label_width);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, label, remaining);
    try row.appendSlice(alloc, ui_render.reset_style);

    var visible = display_width.visibleWidth(label);
    while (visible < command_width and before_label_width + visible < width_usize) : (visible += 1) {
        try row.append(alloc, ' ');
    }

    if (description.len > 0 and before_label_width + visible < width_usize) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const desc_remaining: u16 = @intCast(width_usize - before_label_width - visible);
        try row_text.appendClipped(alloc, &row, description, desc_remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

pub fn composeMixedSlashCompletionOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, match_idx) orelse return .empty) {
        .command => |command_idx| composeSlashCompletionOptionRow(alloc, registry, prefix, command_idx, selected, start_col, command_width, width),
        .skill => |skill| composeSkillCompletionOptionRow(alloc, skill, selected, start_col, command_width, width),
    };
}

fn composeSkillCompletionOptionRow(
    alloc: Allocator,
    skill: skill_runtime.Skill,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0) return row;

    const label_col: u16 = if (start_col > 1) start_col else 3;
    if (label_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, label_col);

    const before_label_width: usize = label_col - 1;
    if (before_label_width >= width_usize) return row;
    const remaining: u16 = @intCast(width_usize - before_label_width);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, skill.name, remaining);
    try row.appendSlice(alloc, ui_render.reset_style);

    var visible = display_width.visibleWidth(skill.name);
    while (visible < command_width and before_label_width + visible < width_usize) : (visible += 1) {
        try row.append(alloc, ' ');
    }

    const source = skill_runtime.skillSourceShortLabel(skill.source);
    if (before_label_width + visible < width_usize) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const desc_remaining: u16 = @intCast(width_usize - before_label_width - visible);
        try row_text.appendClipped(alloc, &row, source, desc_remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

const picker_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "clear the terminal transcript", .presentation_category = .general },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true },
    .{ .kind = .models, .command = "/models", .help_entry = "/models", .completion_description = "browse available models", .presentation_category = .model },
    .{ .kind = .mcp, .command = "/mcp", .help_entry = "/mcp [list|resource|prompt|add|remove]", .completion_description = "manage MCP servers, resources, and prompts", .presentation_category = .extensions, .has_args = true },
    .{ .kind = .permissions, .command = "/permissions", .help_entry = "/permissions [ask|auto|remember|revoke|yolo|reset]", .completion_description = "choose permission behavior", .presentation_category = .security, .has_args = true },
    .{ .kind = .credits, .command = "/credits", .aliases = &.{"/balance"}, .help_entry = "/credits (/balance)", .completion_description = "show gateway credits balance", .presentation_category = .account },
};
const picker_test_slash_registry = command_specs.SlashRegistry{ .commands = picker_test_slash_specs[0..] };

test "footer composes slash completions as vertical described rows" {
    const alloc = std.testing.allocator;
    const prefix = "/mo";
    const selected: usize = 0;
    const window = edgeScrollPickerWindow(command_specs.slashCompletionCount(picker_test_slash_registry, prefix), selected, 6);
    const command_width = slashCompletionCommandColumnWidth(picker_test_slash_registry, prefix, window);

    var saw_model_row = false;
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        var row = try composeSlashCompletionOptionRow(alloc, picker_test_slash_registry, prefix, match_idx, match_idx == selected, 1, command_width, 80);
        defer row.deinit(alloc);

        saw_model_row = saw_model_row or
            (std.mem.find(u8, row.items, "/model") != null and
                std.mem.find(u8, row.items, "choose what model and reasoning effort to use") != null);
    }
    try std.testing.expect(saw_model_row);
}

test "slash menu layout keeps six selectable rows below its header" {
    const first = slashMenuLayout(picker_test_slash_registry, "/", &.{}, 0, 0, 24, 0, 0).?;
    try std.testing.expect(first.show_header);
    try std.testing.expectEqual(@as(u16, 8), first.row_count);
    try std.testing.expectEqual(@as(u16, 6), first.selectable_rows);
    try std.testing.expectEqual(@as(usize, 0), first.window.start);
    try std.testing.expectEqual(@as(usize, 6), first.window.end);

    const scrolled = slashMenuLayout(picker_test_slash_registry, "/", &.{}, 6, 0, 24, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 1), scrolled.window.start);
    try std.testing.expectEqual(@as(usize, 7), scrolled.window.end);
}

test "slash menu layout prioritizes selection at short heights and excludes arguments" {
    const compact = slashMenuLayout(picker_test_slash_registry, "/", &.{}, 5, 0, 16, 0, 0).?;
    try std.testing.expect(compact.show_header);
    try std.testing.expectEqual(@as(u16, 6), compact.row_count);
    try std.testing.expectEqual(@as(u16, 4), compact.selectable_rows);
    try std.testing.expectEqual(@as(usize, 2), compact.window.start);
    try std.testing.expectEqual(@as(usize, 6), compact.window.end);

    const short = slashMenuLayout(picker_test_slash_registry, "/", &.{}, 4, 0, 6, 0, 0).?;
    try std.testing.expect(!short.show_header);
    try std.testing.expectEqual(@as(u16, 1), short.row_count);
    try std.testing.expectEqual(@as(u16, 1), short.selectable_rows);
    try std.testing.expectEqual(@as(usize, 4), short.window.start);
    try std.testing.expectEqual(@as(usize, 5), short.window.end);
    try std.testing.expect(slashMenuLayout(picker_test_slash_registry, "/permissions ", &.{}, 0, 0, 24, 0, 0) == null);
}

test "slash menu header reports command totals and visible range" {
    const layout = slashMenuLayout(picker_test_slash_registry, "/", &.{}, 0, 0, 24, 0, 0).?;
    var row = try composeSlashMenuHeaderRow(std.testing.allocator, "/", layout, 80);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "Commands 7 · Type to filter") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "1–6") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 80);
}

test "slash menu rows prioritize marker label description and category by width" {
    const wide_layout = slashMenuLayout(picker_test_slash_registry, "/m", &.{}, 0, 0, 24, 0, 0).?;
    const column_widths = mixedSlashMenuColumnWidths(picker_test_slash_registry, "/m", &.{}, wide_layout.window, true);

    var wide = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/m", &.{}, 0, true, column_widths, 100, true);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, wide.items, ui_render.selected_completion_style));
    try std.testing.expect(std.mem.find(u8, wide.items, ui_render.system_notice_label_style) == null);
    try std.testing.expect(std.mem.find(u8, wide.items, "❯") == null);
    try std.testing.expect(std.mem.find(u8, wide.items, "/model") != null);
    try std.testing.expect(std.mem.find(u8, wide.items, "Model") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(wide.items) < 100);

    const description_offset = std.mem.find(u8, wide.items, "choose what model") orelse return error.TestExpectedDescription;
    try std.testing.expectEqual(column_widths.label + 5, display_width.visibleWidthIgnoringAnsi(wide.items[0..description_offset]));
    const model_offset = std.mem.find(u8, wide.items, "Model") orelse return error.TestExpectedMetadata;
    const model_column = display_width.visibleWidthIgnoringAnsi(wide.items[0..model_offset]);

    var extensions = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/m", &.{}, 2, false, column_widths, 100, true);
    defer extensions.deinit(std.testing.allocator);
    const extensions_offset = std.mem.find(u8, extensions.items, "Extensions") orelse return error.TestExpectedMetadata;
    try std.testing.expectEqual(model_column, display_width.visibleWidthIgnoringAnsi(extensions.items[0..extensions_offset]));
    try std.testing.expectEqual(@as(usize, 99), display_width.visibleWidthIgnoringAnsi(extensions.items));

    var narrow = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/m", &.{}, 0, true, column_widths, 42, true);
    defer narrow.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, narrow.items, "❯") == null);
    try std.testing.expect(std.mem.find(u8, narrow.items, "/model") != null);
    try std.testing.expect(std.mem.find(u8, narrow.items, "Model") == null);
    try std.testing.expect(std.mem.find(u8, narrow.items, "…") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow.items) < 42);
    try std.testing.expect(std.mem.findScalar(u8, narrow.items, '\n') == null);
}

test "slash menu hides metadata for commands and skills" {
    const command_layout = slashMenuLayout(picker_test_slash_registry, "/m", &.{}, 0, 0, 24, 0, 0).?;
    const command_widths = mixedSlashMenuColumnWidths(picker_test_slash_registry, "/m", &.{}, command_layout.window, false);

    var command = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/m", &.{}, 0, true, command_widths, 60, false);
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, command.items, "/model") != null);
    try std.testing.expect(std.mem.find(u8, command.items, "choose what model") != null);
    try std.testing.expect(std.mem.find(u8, command.items, "Model") == null);

    const skills = [_]skill_runtime.Skill{.{
        .name = "fx-test-strategy",
        .description = "choose focused regression coverage",
        .path = "/tmp/.codex/skills/fx-test-strategy",
        .source = .global_codex,
    }};
    const skill_layout = slashMenuLayout(picker_test_slash_registry, "/fx-test", &skills, 0, 0, 24, 0, 0).?;
    const skill_widths = mixedSlashMenuColumnWidths(picker_test_slash_registry, "/fx-test", &skills, skill_layout.window, false);
    var skill = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/fx-test", &skills, 0, true, skill_widths, 64, false);
    defer skill.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, skill.items, "choose focused regression coverage") != null);
    try std.testing.expect(std.mem.find(u8, skill.items, "codex") == null);
}

test "slash menu keeps matching skill source labels" {
    const skills = [_]skill_runtime.Skill{.{
        .name = "fx-test-strategy",
        .description = "choose focused regression coverage for the affected Fx behavior",
        .path = "/tmp/.codex/skills/fx-test-strategy",
        .source = .global_codex,
    }};
    const layout = slashMenuLayout(picker_test_slash_registry, "/fx-test", &skills, 0, 0, 24, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 0), layout.command_count);
    try std.testing.expectEqual(@as(usize, 1), layout.result_count);

    var header = try composeSlashMenuHeaderRow(std.testing.allocator, "/fx-test", layout, 80);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "Results 1") != null);

    const column_widths = mixedSlashMenuColumnWidths(picker_test_slash_registry, "/fx-test", &skills, layout.window, true);
    var row = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/fx-test", &skills, 0, true, column_widths, 64, true);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "fx-test-strategy") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "choose focused") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "…") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "codex") != null);
    try std.testing.expectEqual(@as(usize, 63), display_width.visibleWidthIgnoringAnsi(row.items));
    try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
}

test "slash completion option row clips styled descriptions safely" {
    const alloc = std.testing.allocator;
    var row = try composeSlashCompletionOptionRow(alloc, picker_test_slash_registry, "/mo", 0, true, 1, 8, 30);
    defer row.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, row.items, ui_render.selected_completion_style) != null);
    try std.testing.expect(std.mem.find(u8, row.items, ui_render.reset_style) != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 30);
    try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
}

test "slash completion option row aligns argument labels without command prefix" {
    const alloc = std.testing.allocator;
    var row = try composeSlashCompletionOptionRow(alloc, picker_test_slash_registry, "/permissions ", 0, false, 12, 8, 40);
    defer row.deinit(alloc);

    try std.testing.expect(std.mem.startsWith(u8, row.items, "\x1b[12G"));
    try std.testing.expect(std.mem.find(u8, row.items, "ask") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "/permissions") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 40);
}

test "mixed slash completion includes matching skills with source labels" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "fx-test-strategy",
        .description = "coverage help",
        .path = "/tmp/.codex/skills/fx-test-strategy",
        .source = .global_codex,
    }};

    try std.testing.expect(mixedSlashCompletionCount(picker_test_slash_registry, "/fx-test", &skills) > 0);
    const skill = nthMixedSlashCompletionSkill(picker_test_slash_registry, "/fx-test", &skills, 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("fx-test-strategy", skill.name);

    var row = try composeMixedSlashCompletionOptionRow(alloc, picker_test_slash_registry, "/fx-test", &skills, 0, true, 1, 8, 50);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "fx-test-strategy") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "codex") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 50);
}

test "mixed slash completion uses skill relevance order" {
    const skills = [_]skill_runtime.Skill{
        .{
            .name = "metadata-first",
            .description = "zig workflow",
            .path = "/tmp/.fx/skills/metadata-first",
            .source = .global_fx,
        },
        .{
            .name = "zig-best-practices",
            .description = "Zig guidance",
            .path = "/tmp/.codex/skills/zig-best-practices",
            .source = .global_codex,
        },
    };

    try std.testing.expectEqual(@as(usize, 2), mixedSlashCompletionCount(picker_test_slash_registry, "/zig", &skills));
    try std.testing.expectEqualStrings(
        "zig-best-practices",
        nthMixedSlashCompletionSkill(picker_test_slash_registry, "/zig", &skills, 0).?.name,
    );
    try std.testing.expectEqualStrings(
        "metadata-first",
        nthMixedSlashCompletionSkill(picker_test_slash_registry, "/zig", &skills, 1).?.name,
    );
}

test "mixed slash completion ranks substring commands before skill metadata" {
    const specs = [_]command_specs.SlashSpec{
        .{ .kind = .rename_session, .command = "/rename", .help_entry = "/rename <title>", .completion_description = "rename session", .presentation_category = .session },
    };
    const registry = command_specs.SlashRegistry{ .commands = specs[0..] };
    const skills = [_]skill_runtime.Skill{.{
        .name = "workflow-helper",
        .description = "manage named workflows",
        .path = "/tmp/.codex/skills/workflow-helper",
        .source = .global_codex,
    }};

    try std.testing.expectEqual(@as(usize, 2), mixedSlashCompletionCount(registry, "/name", &skills));
    try std.testing.expectEqualStrings("/rename", nthMixedSlashCompletionText(registry, "/name", &skills, 0).?);
    try std.testing.expect(nthMixedSlashCompletionSkill(registry, "/name", &skills, 0) == null);
    try std.testing.expectEqualStrings(
        "workflow-helper",
        nthMixedSlashCompletionSkill(registry, "/name", &skills, 1).?.name,
    );
}

test "registry-aware mixed slash completion maps skills after injected commands" {
    const specs = [_]command_specs.SlashSpec{
        .{ .kind = .help, .command = "/alpha", .help_entry = "/alpha" },
    };
    const registry = command_specs.SlashRegistry{ .commands = specs[0..] };
    const skills = [_]skill_runtime.Skill{.{
        .name = "alpha-skill",
        .description = "injected registry coverage",
        .path = "/tmp/.codex/skills/alpha-skill",
        .source = .global_codex,
    }};

    try std.testing.expectEqual(
        @as(usize, 2),
        mixedSlashCompletionCount(registry, "/a", &skills),
    );
    try std.testing.expect(
        nthMixedSlashCompletionSkill(registry, "/a", &skills, 0) == null,
    );
    const skill = nthMixedSlashCompletionSkill(registry, "/a", &skills, 1) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("alpha-skill", skill.name);
}

test "registry-aware slash presentation preserves aliases" {
    try std.testing.expectEqual(
        @as(usize, 1),
        mixedSlashCompletionCount(picker_test_slash_registry, "/bal", &.{}),
    );
    try std.testing.expectEqualStrings(
        "/balance",
        nthMixedSlashCompletionText(picker_test_slash_registry, "/bal", &.{}, 0).?,
    );
}

test "mixed slash completion keeps skills out of argument completions" {
    const skills = [_]skill_runtime.Skill{.{
        .name = "permissions-helper",
        .description = "permissions help",
        .path = "/tmp/.codex/skills/permissions-helper",
        .source = .global_codex,
    }};

    const command_count = command_specs.slashCompletionCount(picker_test_slash_registry, "/permissions ");
    try std.testing.expect(command_count > 0);
    try std.testing.expectEqual(command_count, mixedSlashCompletionCount(picker_test_slash_registry, "/permissions ", &skills));
    try std.testing.expect(!mixedSlashCompletionIsSkill(picker_test_slash_registry, "/permissions ", &skills, command_count));
    try std.testing.expect(nthMixedSlashCompletionSkill(picker_test_slash_registry, "/permissions ", &skills, command_count) == null);
    try std.testing.expectEqualStrings("/permissions ask", nthMixedSlashCompletionText(picker_test_slash_registry, "/permissions ", &skills, 0).?);
}

test "edge-scroll picker window lets selection reach bottom before scrolling" {
    const first = edgeScrollPickerWindow(20, 0, 6);
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 6), first.end);

    const bottom = edgeScrollPickerWindow(20, 5, 6);
    try std.testing.expectEqual(@as(usize, 0), bottom.start);
    try std.testing.expectEqual(@as(usize, 6), bottom.end);

    const scrolled = edgeScrollPickerWindow(20, 6, 6);
    try std.testing.expectEqual(@as(usize, 1), scrolled.start);
    try std.testing.expectEqual(@as(usize, 7), scrolled.end);
}

test "compose model picker option row aligns bare effort values" {
    var row = try composePickerOptionRow(std.testing.allocator, .model_stage, 23, "high", true, 48);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[23G") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "high") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "[high]") == null);
}

test "file picker rows keep distinguishing basename text when narrow" {
    const alloc = std.testing.allocator;
    const prefix = "deeply-nested-source-directory/";

    var first = try composeFilePickerOptionRow(
        alloc,
        3,
        .{ .path = prefix ++ "alpha-component-15-with-a-very-long-descriptive-name.zig", .kind = .file, .matched_spans = &.{} },
        true,
        40,
    );
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first.items, "alpha-component-15") != null);
    try std.testing.expect(std.mem.find(u8, first.items, prefix) == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(first.items) <= 40);

    var second = try composeFilePickerOptionRow(
        alloc,
        3,
        .{ .path = prefix ++ "alpha-component-16-with-a-very-long-descriptive-name.zig", .kind = .file, .matched_spans = &.{} },
        false,
        40,
    );
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, second.items, "alpha-component-16") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(second.items) <= 40);
}

test "file picker rows retain directory identity for duplicate basenames when narrow" {
    const alloc = std.testing.allocator;
    const basename = "shared-component-id-with-a-very-long-name.zig";

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(alloc);
    try appendFilePickerLabel(
        alloc,
        &first,
        .{ .path = "first-distinguishing-parent-with-long-name/" ++ basename, .kind = .file, .matched_spans = &.{} },
        38,
        "",
    );

    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(alloc);
    try appendFilePickerLabel(
        alloc,
        &second,
        .{ .path = "second-distinguishing-parent-with-long-name/" ++ basename, .kind = .file, .matched_spans = &.{} },
        38,
        "",
    );

    try std.testing.expectEqualStrings("first-…-name/shared-component-i…me.zig", first.items);
    try std.testing.expectEqualStrings("second…-name/shared-component-i…me.zig", second.items);
}

test "file picker tiny rows keep basename context" {
    const alloc = std.testing.allocator;
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);

    try appendFilePickerLabel(
        alloc,
        &row,
        .{ .path = "first-distinguishing-parent/shared-component.zig", .kind = .file, .matched_spans = &.{} },
        4,
        "",
    );

    try std.testing.expectEqualStrings("sha…", row.items);
}

fn expectOrderedSubstrings(haystack: []const u8, needles: []const []const u8) !void {
    var offset: usize = 0;
    for (needles) |needle| {
        const relative = std.mem.find(u8, haystack[offset..], needle) orelse return error.TestUnexpectedResult;
        offset += relative + needle.len;
    }
}

test "typed file picker rows render directory slash and restore base styles around spans" {
    const alloc = std.testing.allocator;
    const spans = [_]file_index.MatchSpan{
        .{ .byte_start = 4, .byte_end = 5 },
        .{ .byte_start = 6, .byte_end = 7 },
    };
    const item: file_index.SearchResult = .{
        .path = "src/main",
        .kind = .directory,
        .matched_spans = &spans,
    };

    var unselected = try composeFilePickerOptionRow(alloc, 1, item, false, 40);
    defer unselected.deinit(alloc);
    try std.testing.expect(std.mem.endsWith(u8, unselected.items, "/" ++ ui_render.reset_style));
    try expectOrderedSubstrings(unselected.items, &.{ ui_render.bold_style, "m", ui_render.reset_style, ui_render.dim_style });
    const first_restore = std.mem.find(u8, unselected.items, ui_render.reset_style ++ "") orelse return error.TestUnexpectedResult;
    try expectOrderedSubstrings(unselected.items[first_restore + ui_render.reset_style.len ..], &.{ ui_render.bold_style, "i", ui_render.reset_style, ui_render.dim_style });
    try std.testing.expectEqual(display_width.visibleWidth(item.path) + 1, display_width.visibleWidthIgnoringAnsi(unselected.items));

    var selected = try composeFilePickerOptionRow(alloc, 1, item, true, 40);
    defer selected.deinit(alloc);
    try expectOrderedSubstrings(selected.items, &.{ ui_render.bold_style, "m", ui_render.reset_style, ui_render.approval_button_inactive_style });
    try std.testing.expectEqual(display_width.visibleWidth(item.path) + 1, display_width.visibleWidthIgnoringAnsi(selected.items));
}

test "typed file picker clipping maps spans to retained source segments" {
    const alloc = std.testing.allocator;
    const path = "first-distinguishing-parent/target-component-with-long-name.zig";
    const target_start = std.mem.find(u8, path, "target").?;
    const parent_span = [_]file_index.MatchSpan{.{ .byte_start = 0, .byte_end = 1 }};
    const basename_span = [_]file_index.MatchSpan{.{
        .byte_start = @intCast(target_start),
        .byte_end = @intCast(target_start + 1),
    }};

    var parent = try composeFilePickerOptionRow(alloc, 1, .{
        .path = path,
        .kind = .file,
        .matched_spans = &parent_span,
    }, false, 38);
    defer parent.deinit(alloc);
    try expectOrderedSubstrings(parent.items, &.{ ui_render.bold_style, "f" });
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(parent.items) <= 38);

    var basename = try composeFilePickerOptionRow(alloc, 1, .{
        .path = path,
        .kind = .file,
        .matched_spans = &basename_span,
    }, false, 38);
    defer basename.deinit(alloc);
    try expectOrderedSubstrings(basename.items, &.{ ui_render.bold_style, "t" });
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(basename.items) <= 38);
}

test "typed file picker highlighting preserves Unicode display clusters" {
    const alloc = std.testing.allocator;
    const path = "docs/Cafe\u{0301}.txt";
    const cluster_start = std.mem.find(u8, path, "e").?;
    const spans = [_]file_index.MatchSpan{.{
        .byte_start = @intCast(cluster_start),
        .byte_end = @intCast(cluster_start + "e\u{0301}".len),
    }};
    var row = try composeFilePickerOptionRow(alloc, 1, .{
        .path = path,
        .kind = .file,
        .matched_spans = &spans,
    }, false, 40);
    defer row.deinit(alloc);

    try expectOrderedSubstrings(row.items, &.{ ui_render.bold_style, "e\u{0301}", ui_render.reset_style, ui_render.dim_style });
    try std.testing.expect(std.unicode.utf8ValidateSlice(row.items));
    try std.testing.expectEqual(display_width.visibleWidth(path), display_width.visibleWidthIgnoringAnsi(row.items));
}

test "typed file picker basename clipping does not detach combining continuations" {
    const alloc = std.testing.allocator;

    var clipped: std.ArrayList(u8) = .empty;
    defer clipped.deinit(alloc);
    try appendFilePickerLabel(
        alloc,
        &clipped,
        .{ .path = "zzabcd\u{0301}e", .kind = .file, .matched_spans = &.{} },
        6,
        "",
    );

    try std.testing.expectEqualStrings("zzab…e", clipped.items);
    try std.testing.expect(std.mem.find(u8, clipped.items, "…\u{0301}") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped.items));
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(clipped.items) <= 6);

    const highlighted_path = "xlongabcd\u{0301}e";
    const cluster_start = std.mem.find(u8, highlighted_path, "d").?;
    const spans = [_]file_index.MatchSpan{.{
        .byte_start = @intCast(cluster_start),
        .byte_end = @intCast(cluster_start + "d\u{0301}".len),
    }};
    var highlighted: std.ArrayList(u8) = .empty;
    defer highlighted.deinit(alloc);
    try appendFilePickerLabel(
        alloc,
        &highlighted,
        .{ .path = highlighted_path, .kind = .file, .matched_spans = &spans },
        9,
        ui_render.dim_style,
    );

    try expectOrderedSubstrings(highlighted.items, &.{
        "xlonga…",
        ui_render.bold_style,
        "d\u{0301}",
        ui_render.reset_style,
        ui_render.dim_style,
        "e",
    });
    try std.testing.expect(std.unicode.utf8ValidateSlice(highlighted.items));
    try std.testing.expectEqual(@as(usize, 9), display_width.visibleWidthIgnoringAnsi(highlighted.items));
}

test "typed file picker parent directory clipping does not detach combining continuations" {
    const alloc = std.testing.allocator;
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);

    try appendFilePickerLabel(
        alloc,
        &row,
        .{ .path = "abcd\u{0301}e/target", .kind = .directory, .matched_spans = &.{} },
        8,
        "",
    );

    try std.testing.expectEqualStrings("a…e/ta…/", row.items);
    try std.testing.expect(std.mem.find(u8, row.items, "…\u{0301}") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(row.items));
    try std.testing.expectEqual(@as(usize, 8), display_width.visibleWidthIgnoringAnsi(row.items));
}

test "typed file picker tiny directory row retains kind identity" {
    var row = try composeFilePickerOptionRow(std.testing.allocator, 1, .{
        .path = "deeply/nested",
        .kind = .directory,
        .matched_spans = &.{},
    }, false, 1);
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_width.visibleWidthIgnoringAnsi(row.items));
    try std.testing.expect(std.mem.find(u8, row.items, "/") != null);
}

test "compose model picker rows render raw catalog model ids" {
    var codex = try composePickerOptionRow(std.testing.allocator, .model_stage, 1, "gpt-5.4", true, 80);
    defer codex.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, codex.items, "gpt-5.4") != null);

    var gateway = try composePickerOptionRow(std.testing.allocator, .model_stage, 1, "anthropic/claude-sonnet-4.6", false, 80);
    defer gateway.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, gateway.items, "anthropic/claude-sonnet-4.6") != null);
}

test "compose model picker status row aligns to active token" {
    var row = try composePickerStatusRow(std.testing.allocator, .model_stage, .fast, false, false, 23, 48);
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[23G") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "no matching mode") != null);
}

test "auth onboarding composes the welcome copy and setup choices" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = .{ .action = .login },
        .active_source = null,
        .include_skip = true,
    };

    try std.testing.expectEqual(@as(u16, 19), authPickerRowCount(view));
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(alloc);
    for (0..authPickerRowCount(view)) |row_index| {
        var row = try composeAuthPickerRow(alloc, view, @intCast(row_index), authPickerRowCount(view), 100);
        defer row.deinit(alloc);
        try screen.appendSlice(alloc, row.items);
        try screen.append(alloc, '\n');
    }

    try std.testing.expect(std.mem.find(u8, screen.items, "Welcome to fx") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "fx can access AI models with an account, subscription, or API key") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "You can change this anytime with /setup.") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "⚠︎ Note: fx is experimental and defaults to auto mode. \x1b]8;id=fx-onboarding;https://fx.sh/docs/stability\x1b\\\x1b[4mLearn more\x1b[24m\x1b]8;;\x1b\\") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Learn more: https://") == null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Sign in with Vercel") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Add an API key") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Esc to set up later · Explore all commands with /help") != null);

    var body_row = try composeAuthPickerRow(alloc, view, 2, authPickerRowCount(view), 100);
    defer body_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, body_row.items, "fx can access AI models") != null);

    var spacer_row = try composeAuthPickerRow(alloc, view, 6, authPickerRowCount(view), 100);
    defer spacer_row.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), display_width.visibleWidthIgnoringAnsi(spacer_row.items));

    var selected_row = try composeAuthPickerRow(alloc, view, 8, authPickerRowCount(view), 100);
    defer selected_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected_row.items, "› Sign in with Vercel") != null);

    var chatgpt_row = try composeAuthPickerRow(alloc, view, 9, authPickerRowCount(view), 100);
    defer chatgpt_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, chatgpt_row.items, "Sign in with Codex") != null);

    var grok_row = try composeAuthPickerRow(alloc, view, 10, authPickerRowCount(view), 100);
    defer grok_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, grok_row.items, "Sign in with Grok") != null);

    var claude_row = try composeAuthPickerRow(alloc, view, 11, authPickerRowCount(view), 100);
    defer claude_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, claude_row.items, "Sign in with Claude") != null);

    var unselected_row = try composeAuthPickerRow(alloc, view, 12, authPickerRowCount(view), 100);
    defer unselected_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, unselected_row.items, "Add an API key") != null);

    var narrow_note = try composeAuthPickerRow(alloc, view, 13, authPickerRowCount(view), 58);
    defer narrow_note.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, narrow_note.items, "https://fx.sh/docs/stability") == null);

    var compact_screen: std.ArrayList(u8) = .empty;
    defer compact_screen.deinit(alloc);
    for (0..3) |row_index| {
        var row = try composeAuthPickerRow(alloc, view, @intCast(row_index), 3, 100);
        defer row.deinit(alloc);
        try compact_screen.appendSlice(alloc, row.items);
        try compact_screen.append(alloc, '\n');
    }
    try std.testing.expect(std.mem.find(u8, compact_screen.items, "Sign in with Vercel") != null);
    try std.testing.expect(std.mem.find(u8, compact_screen.items, "Add an API key") != null);
    try std.testing.expect(std.mem.find(u8, compact_screen.items, "Sign in with Codex") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Sign in with Grok") != null);
}

test "auth picker composes only detected credential sources" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login }),
        .selected_choice = .{ .source = .fx_login },
        .active_source = .fx_login,
        .include_skip = false,
    };
    const row_count = authPickerRowCount(view);
    try std.testing.expectEqual(@as(u16, 9), row_count);

    var header = try composeAuthPickerRow(alloc, view, 0, row_count, 80);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Setup") != null);

    var sign_in = try composeAuthPickerRow(alloc, view, 1, row_count, 80);
    defer sign_in.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, sign_in.items, "Sign in with Vercel") != null);

    var chatgpt = try composeAuthPickerRow(alloc, view, 2, row_count, 80);
    defer chatgpt.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, chatgpt.items, "Sign in with Codex") != null);

    var grok = try composeAuthPickerRow(alloc, view, 3, row_count, 80);
    defer grok.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, grok.items, "Sign in with Grok") != null);

    var claude = try composeAuthPickerRow(alloc, view, 4, row_count, 80);
    defer claude.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, claude.items, "Sign in with Claude") != null);

    var setup = try composeAuthPickerRow(alloc, view, 5, row_count, 80);
    defer setup.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, setup.items, "API key") != null);

    var switch_provider = try composeAuthPickerRow(alloc, view, 6, row_count, 80);
    defer switch_provider.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, switch_provider.items, "Switch provider") != null);

    var change_team = try composeAuthPickerRow(alloc, view, 7, row_count, 80);
    defer change_team.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, change_team.items, "Change team") != null);
    try std.testing.expect(std.mem.find(u8, change_team.items, "sign in first") != null);

    var switch_credential = try composeAuthPickerRow(alloc, view, 8, row_count, 80);
    defer switch_credential.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, switch_credential.items, "Switch credential") != null);
}

test "compact auth picker keeps the selected hub action visible" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login }),
        .selected_choice = .{ .action = .switch_credential },
        .active_source = .ai_gateway_api_key,
        .include_skip = false,
    };

    var row = try composeAuthPickerRow(alloc, view, 0, 1, 80);
    defer row.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, row.items, "Switch credential") != null);
}

test "auth picker renders the staged switch and disabled team screens" {
    const alloc = std.testing.allocator;
    const switch_view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initOne(.stored_key),
        .selected_choice = .{ .source = .stored_key },
        .active_source = .stored_key,
        .include_skip = false,
        .stage = .switch_credential,
    };

    var switch_header = try composeAuthPickerRow(alloc, switch_view, 0, 2, 80);
    defer switch_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, switch_header.items, "Use this credential") != null);

    var switch_source = try composeAuthPickerRow(alloc, switch_view, 1, 2, 80);
    defer switch_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, switch_source.items, credentials.sourceLabel(.stored_key)) != null);
    try std.testing.expect(std.mem.find(u8, switch_source.items, "current") != null);
    try std.testing.expect(
        authPickerDescriptionColumn(switch_view) >
            5 + display_width.visibleWidth(credentials.sourceLabel(.stored_key)),
    );

    const team_view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = .stored_key,
        .include_skip = false,
        .stage = .change_team,
    };
    var team_header = try composeAuthPickerRow(alloc, team_view, 0, 2, 80);
    defer team_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, team_header.items, "Choose a Vercel team") != null);

    var no_teams = try composeAuthPickerRow(alloc, team_view, 1, 2, 80);
    defer no_teams.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, no_teams.items, "No Vercel teams available") != null);

    var search_view = team_view;
    search_view.team_query = "play";
    var search_header = try composeAuthPickerRow(alloc, search_view, 0, 2, 80);
    defer search_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, search_header.items, "Search: play") != null);

    search_view.team_query = "example-internal-team";
    var narrow_search_header = try composeAuthPickerRow(alloc, search_view, 0, 2, 20);
    defer narrow_search_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, narrow_search_header.items, "nternal-team") != null);
    try std.testing.expectEqual(
        @as(u16, 20),
        authPickerQueryCursorColumn(search_view, 20).?,
    );

    var no_matches = try composeAuthPickerRow(alloc, search_view, 1, 2, 80);
    defer no_matches.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, no_matches.items, "No matching Vercel teams") != null);
}

test "api key stage renders only a bounded mask and the configured backend label" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .api_key,
        .api_key_mask_count = 9,
    };

    try std.testing.expectEqual(@as(u16, 4), authPickerRowCount(view));
    var field = try composeAuthPickerRow(alloc, view, 1, 4, 80);
    defer field.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, field.items, "•"));
    try std.testing.expect(std.mem.find(u8, field.items, "FX_API_KEY_RENDER_SENTINEL") == null);

    var backend = try composeAuthPickerRow(alloc, view, 3, 4, 80);
    defer backend.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, backend.items, "Saves to") != null);
    try std.testing.expect(std.mem.find(u8, backend.items, credentials.stored_key_backend_label) != null);
}

test "api key field reads as a text field rather than a selectable row" {
    const alloc = std.testing.allocator;
    var view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .api_key,
        .api_key_mask_count = 0,
    };

    var empty = try composeAuthPickerRow(alloc, view, 1, 4, 80);
    defer empty.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, empty.items, "┃") != null);
    try std.testing.expect(std.mem.find(u8, empty.items, "›") == null);
    const placeholder = std.mem.find(u8, empty.items, "Paste or type a key").?;
    const dim = std.mem.find(u8, empty.items, ui_render.dim_style).?;
    try std.testing.expect(dim < placeholder);

    view.api_key_mask_count = 3;
    var typed = try composeAuthPickerRow(alloc, view, 1, 4, 80);
    defer typed.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, typed.items, "┃") != null);
    try std.testing.expect(std.mem.find(u8, typed.items, ui_render.dim_style) == null);
}

test "sign-in stage renders the complete device authorization screen" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .sign_in,
        .sign_in = .{
            .state = .polling,
            .verification_uri = "https://vercel.test/verify",
            .user_code = "TEST-CODE",
        },
    };

    try std.testing.expectEqual(@as(u16, 7), authPickerRowCount(view));
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(alloc);
    for (0..authPickerRowCount(view)) |row_index| {
        var row = try composeAuthPickerRow(alloc, view, @intCast(row_index), 7, 100);
        defer row.deinit(alloc);
        try screen.appendSlice(alloc, row.items);
        try screen.append(alloc, '\n');
    }
    for ([_][]const u8{
        "Sign in with Vercel",
        "Open   https://vercel.test/verify",
        "Code   TEST-CODE",
        "Waiting for authorization",
        "Enter reopens browser · Esc cancels",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, screen.items, expected) != null);
    }
}

test "Codex sign-in stage renders a bounded clickable authorization action" {
    const alloc = std.testing.allocator;
    const url = "https://auth.openai.test/oauth/authorize?response_type=code&client_id=test&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=full-state";
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .sign_in,
        .sign_in_source = .chatgpt_subscription,
        .sign_in = .{
            .state = .polling,
            .verification_uri = url,
        },
    };

    var row = try composeAuthPickerRow(alloc, view, 2, authPickerRowCount(view), 40);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "   Open   ") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Authorize with Codex") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b]8;") != null);
    try std.testing.expect(std.mem.find(u8, row.items, url) != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b]8;;\x1b\\") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 40);
}

test "partially visible auth picker shows a source window without duplicates" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.full,
        .selected_choice = .{ .source = .fx_login },
        .active_source = .vercel_oidc_token,
        .include_skip = false,
        .stage = .switch_credential,
    };

    var first_source = try composeAuthPickerRow(alloc, view, 1, 3, 80);
    defer first_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first_source.items, "AI_GATEWAY_API_KEY") != null);
    try std.testing.expect(std.mem.find(u8, first_source.items, "fx login") == null);

    var selected_source = try composeAuthPickerRow(alloc, view, 2, 3, 80);
    defer selected_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected_source.items, "fx login") != null);

    var scrolled_view = view;
    scrolled_view.selected_choice = .{ .source = .stored_key };
    var scrolled_first = try composeAuthPickerRow(alloc, scrolled_view, 1, 3, 80);
    defer scrolled_first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, scrolled_first.items, "fx login") != null);

    var scrolled_selected = try composeAuthPickerRow(alloc, scrolled_view, 2, 3, 80);
    defer scrolled_selected.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, scrolled_selected.items, credentials.sourceLabel(.stored_key)) != null);
}

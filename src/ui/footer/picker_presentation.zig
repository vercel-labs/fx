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
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
pub const inline_picker_column_gap_width: usize = 4;
const team_query_prefix = "Vercel team · Search: ";
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
    if (view.stage == .sign_in) {
        return switch (view.sign_in_source) {
            .chatgpt_subscription => 4,
            .grok_subscription => if (view.sign_in_code_visible) 7 else 5,
            else => 7,
        };
    }
    if (view.stage == .api_key) return 4;
    if (view.stage == .root and view.include_skip) return 18;
    if (isSetupListStage(view.stage)) return @intCast(2 + @max(view.choiceCount(), 1));
    return @intCast(1 + @max(view.choiceCount(), 1));
}

fn isSetupListStage(stage: auth_runtime.PickerStage) bool {
    return switch (stage) {
        .root, .connections, .provider, .change_team, .switch_credential => true,
        .sign_in, .api_key => false,
    };
}

fn setupChoiceLabel(view: auth_runtime.PickerView, choice: auth_runtime.Choice) []const u8 {
    return switch (view.stage) {
        .root => switch (choice) {
            .action => |action| switch (action) {
                .connections => "Connections",
                .switch_provider => "Model provider",
                .change_team => "Vercel team",
                .switch_credential => "Credential source",
                .login, .chatgpt_login, .grok_login, .setup, .automatic => "",
            },
            .provider, .source, .team => "",
        },
        .connections => switch (choice) {
            .action => |action| switch (action) {
                .login => "Vercel account",
                .chatgpt_login => "Codex subscription",
                .grok_login => "Grok subscription",
                .setup => "AI Gateway API key",
                .connections, .change_team, .switch_credential, .switch_provider, .automatic => "",
            },
            .provider, .source, .team => "",
        },
        .provider, .change_team, .switch_credential => view.choiceLabel(choice),
        .sign_in, .api_key => "",
    };
}

fn setupChoiceValue(view: auth_runtime.PickerView, choice: auth_runtime.Choice) []const u8 {
    return switch (view.stage) {
        .root => switch (choice) {
            .action => |action| switch (action) {
                .connections => if (view.available_sources.count() > 0) "connected" else "not connected",
                .switch_provider => view.choiceLabel(.{ .provider = view.active_provider }),
                .change_team => if (!view.fx_login_session_available)
                    "sign in to manage"
                else if (view.current_team != null)
                    "selected"
                else
                    "choose a team",
                .switch_credential => if (view.active_source != null)
                    view.activeSourceLabel()
                else
                    "not connected",
                .login, .chatgpt_login, .grok_login, .setup, .automatic => "",
            },
            .provider, .source, .team => "",
        },
        .connections => switch (choice) {
            .action => |action| switch (action) {
                .login => if (view.fx_login_session_available) "connected" else "not connected",
                .chatgpt_login => if (view.available_sources.contains(.chatgpt_subscription)) "connected" else "not connected",
                .grok_login => if (view.available_sources.contains(.grok_subscription)) "connected" else "not connected",
                .setup => if (view.available_sources.contains(.stored_key))
                    "stored"
                else if (view.available_sources.contains(.ai_gateway_api_key))
                    "environment"
                else
                    "not configured",
                .connections, .change_team, .switch_credential, .switch_provider, .automatic => "",
            },
            .provider, .source, .team => "",
        },
        .provider, .change_team, .switch_credential => view.choiceDescription(choice),
        .sign_in, .api_key => "",
    };
}

fn detailValueColumn(width: u16) usize {
    const width_usize: usize = width;
    const minimum = display_width.visibleWidth("  AI Gateway API key") + 2;
    return @min(width_usize, @max(width_usize * 2 / 3, minimum));
}

fn composeSetupChoiceRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    choice: auth_runtime.Choice,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const selected = view.choiceIsSelected(choice);
    const enabled = view.choiceEnabled(choice);
    const style = if (selected and enabled) ui_render.selected_completion_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row.appendSlice(alloc, if (selected and enabled) "› " else "  ");

    const value_col = detailValueColumn(width);
    const label_width = value_col -| 2;
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        setupChoiceLabel(view, choice),
        label_width,
    );
    try row.appendSlice(alloc, ui_render.reset_style);

    if (value_col < width) {
        try row_text.appendSpacesToColumn(alloc, &row, value_col);
        try row.appendSlice(alloc, style);
        try row_text.appendSingleLineEllipsized(
            alloc,
            &row,
            setupChoiceValue(view, choice),
            @as(usize, width) - value_col,
        );
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeSetupHeaderRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    if (view.stage == .change_team) {
        const projection = teamQueryProjection(view.team_query, width);
        try row_text.appendClipped(alloc, &row, projection.prefix, width);
        const remaining: u16 = width -| @as(u16, @intCast(display_width.visibleWidth(projection.prefix)));
        try row_text.appendClipped(alloc, &row, projection.query, remaining);
    } else {
        const heading = switch (view.stage) {
            .root => "Setup",
            .connections => "Connections",
            .provider => "Model provider",
            .switch_credential => "Credential source",
            .sign_in, .api_key, .change_team => unreachable,
        };
        try row_text.appendClipped(alloc, &row, heading, width);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSetupEmptyRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, switch (view.stage) {
        .provider => "  No providers available",
        .change_team => if (view.team_query.len == 0)
            "  No Vercel teams available"
        else
            "  No matching Vercel teams",
        .switch_credential => "  No credentials available",
        .root, .connections, .sign_in, .api_key => "",
    }, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSetupPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (width == 0 or row_index >= row_count) return .empty;
    if (row_count == 1) {
        if (view.stage == .change_team) return composeSetupHeaderRow(alloc, view, width);
        const selected = view.selected_choice orelse return composeSetupEmptyRow(alloc, view, width);
        return composeSetupChoiceRow(alloc, view, selected, width);
    }
    if (row_index == 0) return composeSetupHeaderRow(alloc, view, width);

    const choice_start: u16 = if (row_count >= 3) 2 else 1;
    if (row_index < choice_start) return .empty;
    if (view.choiceCount() == 0) return composeSetupEmptyRow(alloc, view, width);

    const window = pickerWindow(
        view.choiceCount(),
        view.selectedIndex(),
        row_count - choice_start,
    );
    const choice_index = window.start + row_index - choice_start;
    if (choice_index >= window.end) return .empty;
    const choice = view.choiceAt(choice_index) orelse return .empty;
    return composeSetupChoiceRow(alloc, view, choice, width);
}

pub noinline fn composeAuthPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (view.stage == .sign_in) {
        const source_row_index = signInProjectedRowIndex(
            view.sign_in,
            view.sign_in_source,
            view.sign_in_code_visible,
            row_index,
            row_count,
        );
        return composeSignInPickerRow(
            alloc,
            view.sign_in,
            view.sign_in_source,
            view.sign_in_code_visible,
            view.sign_in_code_mask_count,
            source_row_index,
            width,
        );
    }
    if (view.stage == .api_key) {
        return composeApiKeyPickerRow(alloc, view.api_key_mask_count, row_index, width);
    }
    if (view.stage == .root and view.include_skip) {
        return composeOnboardingPickerRow(alloc, view, row_index, row_count, width);
    }
    if (isSetupListStage(view.stage)) {
        return composeSetupPickerRow(alloc, view, row_index, row_count, width);
    }
    unreachable;
}

fn signInProjectedRowIndex(
    snapshot: login_flow.SignInSnapshot,
    source: credentials.Source,
    manual_code_visible: bool,
    row_index: u16,
    row_count: u16,
) u16 {
    const codex_priority = [_]u16{ 2, 0, 3, 1 };
    if (source == .chatgpt_subscription) {
        return prioritizedRowIndex(4, &codex_priority, row_index, row_count);
    }
    const grok_browser_priority = [_]u16{ 2, 3, 0, 4, 1 };
    if (source == .grok_subscription and !manual_code_visible) {
        return prioritizedRowIndex(5, &grok_browser_priority, row_index, row_count);
    }

    const manual_code_priority = [_]u16{ 5, 4, 2, 0, 6, 3, 1 };
    const device_code_priority = [_]u16{ 2, 3, 6, 0, 5, 1, 4 };
    const priority = if (snapshot.accepts_manual_code)
        &manual_code_priority
    else
        &device_code_priority;
    return prioritizedRowIndex(7, priority, row_index, row_count);
}

fn prioritizedRowIndex(
    source_row_count: u16,
    priority: []const u16,
    row_index: u16,
    row_count: u16,
) u16 {
    if (row_count >= source_row_count) return row_index;
    var projected_index: u16 = 0;
    for (0..source_row_count) |source_row| {
        for (priority[0..@min(row_count, priority.len)]) |included_row| {
            if (source_row != included_row) continue;
            if (projected_index == row_index) return @intCast(source_row);
            projected_index += 1;
            break;
        }
    }
    return source_row_count -| 1;
}

const onboarding_note = "   ⚠︎ Note: fx is experimental and defaults to auto mode.";
const onboarding_note_link = onboarding_note ++ " \x1b]8;id=fx-onboarding;https://fx.sh/docs/stability\x1b\\\x1b[4mLearn more\x1b[24m\x1b]8;;\x1b\\";

fn onboardingProjectedRowIndex(view: auth_runtime.PickerView, row_index: u16, row_count: u16) u16 {
    if (row_count >= 18) return row_index;

    const selected_row: u16 = 8 + @as(u16, @intCast(view.selectedIndex()));
    const priority = [_]u16{ selected_row, 11, 9, 10, 8, 15, 7, 12, 5, 0, 2, 3, 6, 13, 14, 1, 4, 16, 17 };

    var projected_index: u16 = 0;
    for (0..18) |source_row| {
        for (priority[0..@min(row_count, priority.len)]) |included_row| {
            if (source_row != included_row) continue;
            if (projected_index == row_index) return @intCast(source_row);
            projected_index += 1;
            break;
        }
    }
    return 17;
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
        12 => if (display_width.visibleWidthIgnoringAnsi(onboarding_note_link) <= width) onboarding_note_link else onboarding_note,
        13, 14 => "",
        15 => "   Esc to set up later · Explore all commands with /help",
        16, 17 => "",
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
    manual_code_visible: bool,
    manual_code_mask_count: usize,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;
    const accepts_manual_code = snapshot.accepts_manual_code;

    const subscription_source = source == .chatgpt_subscription or source == .grok_subscription;
    if (subscription_source and row_index == 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const value_col = detailValueColumn(width);
        const status = switch (snapshot.state) {
            .idle => "Preparing sign-in…",
            .polling => "Waiting for authorization…",
            .succeeded => "Authorization complete",
            .failed => "Sign-in failed",
            .cancelled => "Sign-in cancelled",
        };
        const status_col = @max(
            value_col,
            @as(usize, width) -| display_width.visibleWidth(status),
        );
        try row_text.appendSingleLineEllipsized(
            alloc,
            &row,
            if (source == .chatgpt_subscription) "Sign in with Codex" else "Sign in with Grok",
            value_col,
        );
        if (status_col < width) {
            try row_text.appendSpacesToColumn(alloc, &row, status_col);
            try row_text.appendSingleLineEllipsized(
                alloc,
                &row,
                status,
                @as(usize, width) - status_col,
            );
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    if (subscription_source and row_index == 2) {
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        const prefix = "  Open   ";
        try row_text.appendClipped(alloc, &row, prefix, width);
        const used: u16 = @intCast(@min(display_width.visibleWidth(prefix), width));
        const remaining = width -| used;
        if (remaining > 0) {
            try row.appendSlice(
                alloc,
                if (source == .chatgpt_subscription)
                    "\x1b]8;id=fx-codex-auth;"
                else
                    "\x1b]8;id=fx-grok-auth;",
            );
            try row.appendSlice(alloc, snapshot.verification_uri);
            try row.appendSlice(alloc, "\x1b\\\x1b[4m");
            try row_text.appendClipped(
                alloc,
                &row,
                if (source == .chatgpt_subscription) "Authorize with Codex" else "Authorize with Grok",
                remaining,
            );
            try row.appendSlice(alloc, "\x1b[24m\x1b]8;;\x1b\\");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    if (source == .grok_subscription and !manual_code_visible) {
        try row.appendSlice(alloc, ui_render.dim_style);
        if (row_index == 3) {
            try row_text.appendClipped(
                alloc,
                &row,
                "  Browser didn't return? Press Tab to enter a code",
                width,
            );
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    try row.appendSlice(
        alloc,
        if ((accepts_manual_code and row_index == 5) or
            (!accepts_manual_code and (row_index == 2 or row_index == 3)))
            ui_render.selected_completion_style
        else
            ui_render.dim_style,
    );
    if (source == .grok_subscription and manual_code_visible and row_index == 4) {
        try row_text.appendClipped(alloc, &row, "  Paste the code shown by xAI", width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    if (source == .grok_subscription and manual_code_visible and row_index == 5) {
        const prefix = "  ┃ ";
        try row_text.appendClipped(alloc, &row, prefix, width);
        const used: u16 = @intCast(@min(display_width.visibleWidth(prefix), width));
        if (manual_code_mask_count == 0) {
            try row.appendSlice(alloc, ui_render.dim_style);
            const placeholder = "Paste or type the code";
            try row_text.appendClipped(alloc, &row, placeholder, width -| used);
        } else {
            const visible_mask_count = @min(manual_code_mask_count, width -| used);
            for (0..visible_mask_count) |_| try row.appendSlice(alloc, "•");
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    if (source == .grok_subscription and manual_code_visible and row_index == 6) {
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    var label_buf: [512]u8 = undefined;
    const label = switch (row_index) {
        0 => if (source == .chatgpt_subscription)
            "   Sign in with Codex"
        else if (source == .grok_subscription)
            "   Sign in with Grok"
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
        else
            "   Open the Vercel device authorization page",
        3 => if (snapshot.user_code.len == 0)
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
        6 => if (accepts_manual_code)
            "   Enter submits or reopens browser · Esc cancels"
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
    return slashMenuLayoutForCounts(
        command_count,
        result_count,
        selection_index,
        current_window_start,
        terminal_rows,
        input_extra,
        banner_rows,
    );
}

pub fn preparedSlashMenuLayout(
    prepared: *const PreparedSlashMenu,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (command_specs.argCompletionAnchor(prepared.prefix) != 0) return null;
    return slashMenuLayoutForCounts(
        prepared.commandCount(),
        prepared.resultCount(),
        selection_index,
        current_window_start,
        terminal_rows,
        input_extra,
        banner_rows,
    );
}

fn slashMenuLayoutForCounts(
    command_count: usize,
    result_count: usize,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (result_count == 0) return null;

    const row_budget = inlinePickerRowBudget(terminal_rows, input_extra, banner_rows);
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

pub fn inlinePickerRowBudget(terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    return inlinePickerRowBudgetCapped(
        terminal_rows,
        input_extra,
        banner_rows,
        input_presentation.max_model_picker_rows + 2,
    );
}

pub fn inlinePickerRowBudgetCapped(
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
    max_picker_rows: u16,
) u16 {
    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const minimum_transcript_rows: u16 = 5;
    const available_picker_rows = (terminal_rows -| fixed_rows) -| minimum_transcript_rows;
    return @min(max_picker_rows, @max(available_picker_rows, 1));
}

pub noinline fn composePickerOptionRow(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    return composePickerOptionRowAnnotated(alloc, kind, start_col, item, "", selected, width);
}

const picker_annotation_separator = " · ";

pub noinline fn composePickerOptionRowAnnotated(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    annotation: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    // Model, provider, and model-catalog pickers signal selection by
    // brightness alone, like the question panel; other pickers keep the filled row.
    const selected_style = switch (kind) {
        .model_stage, .provider_stage, .models => ui_render.selected_completion_style,
        .file, .slash, .skills, .help, .settings, .sessions, .mcp, .auth => ui_render.approval_button_inactive_style,
    };
    const base_style = if (selected) selected_style else ui_render.dim_style;
    const available = width_usize - @as(usize, start_col - 1);
    const annotation_width = if (annotation.len == 0)
        0
    else
        display_width.visibleWidth(picker_annotation_separator) + display_width.visibleWidth(annotation);
    const show_annotation = annotation_width > 0 and
        available >= display_width.visibleWidth(item) + annotation_width;
    const label_width = if (show_annotation) available - annotation_width else available;

    try row.appendSlice(alloc, base_style);
    try row_text.appendClipped(alloc, &row, item, @intCast(label_width));
    if (show_annotation) {
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, picker_annotation_separator);
        try row.appendSlice(alloc, annotation);
    }
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
    return composePickerStatusRowWithProvider(alloc, kind, model_stage, .provider, loading, failed, start_col, width);
}

pub fn composePickerStatusRowWithProvider(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    model_stage: picker_state.ModelPickerStage,
    provider_stage: picker_state.ProviderPickerStage,
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
        .provider_stage => switch (provider_stage) {
            .provider => "no matching providers",
            .method => "no matching sign-in methods",
            .team => if (loading) "loading teams..." else if (failed) "unable to load teams" else "no matching teams",
            .key_source => "no matching key sources",
            .api_key => "",
        },
        .models => "no models available",
        .file => if (loading)
            "indexing files..."
        else if (failed)
            "unable to index files"
        else
            "no matching files",
        .slash => unreachable,
        .skills => "no matching skills",
        .help => "no matching commands",
        .settings => "no matching settings",
        .sessions => "no matching sessions",
        .mcp => "no MCP items available",
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

const PreparedSlashMenuEntry = union(enum) {
    command: usize,
    skill: *const skill_runtime.Skill,
};

pub const PreparedSlashMenu = struct {
    registry: command_specs.SlashRegistry = .{},
    prefix: []const u8 = "",
    command_count: usize = 0,
    skill_matches: std.ArrayList(*const skill_runtime.Skill) = .empty,

    pub fn deinit(self: *PreparedSlashMenu, alloc: Allocator) void {
        self.skill_matches.deinit(alloc);
        self.* = .{};
    }

    pub fn commandCount(self: *const PreparedSlashMenu) usize {
        return self.command_count;
    }

    pub fn resultCount(self: *const PreparedSlashMenu) usize {
        return self.command_count + self.skill_matches.items.len;
    }

    fn entryAt(self: *const PreparedSlashMenu, index: usize) ?PreparedSlashMenuEntry {
        if (index < self.command_count) return .{ .command = index };
        const skill_index = index - self.command_count;
        if (skill_index >= self.skill_matches.items.len) return null;
        return .{ .skill = self.skill_matches.items[skill_index] };
    }
};

pub fn prepareSlashMenu(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
) !PreparedSlashMenu {
    var prepared = PreparedSlashMenu{
        .registry = registry,
        .prefix = prefix,
        .command_count = command_specs.slashCompletionCount(registry, prefix),
    };
    errdefer prepared.deinit(alloc);

    if (command_specs.argCompletionAnchor(prefix) != 0 or
        prefix.len == 0 or prefix[0] != '/' or skills.len == 0)
    {
        return prepared;
    }

    try prepared.skill_matches.resize(alloc, skills.len);
    const written = skill_runtime.fillSkillMenuRangeAtQuery(
        skills,
        .all,
        prefix[1..],
        0,
        prepared.skill_matches.items,
    );
    prepared.skill_matches.shrinkRetainingCapacity(written);
    return prepared;
}

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

fn preparedSlashMenuRowContent(
    prepared: *const PreparedSlashMenu,
    match_idx: usize,
    include_metadata: bool,
) ?SlashMenuRowContent {
    return switch (prepared.entryAt(match_idx) orelse return null) {
        .command => |command_idx| .{
            .label = command_specs.nthSlashCompletionLabel(prepared.registry, prepared.prefix, command_idx) orelse return null,
            .description = command_specs.nthSlashCompletionDescription(prepared.registry, prepared.prefix, command_idx) orelse "",
            .metadata = if (include_metadata)
                if (command_specs.nthSlashCompletionCategory(prepared.registry, prepared.prefix, command_idx)) |category| category.label() else ""
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

pub fn preparedSlashMenuColumnWidths(
    prepared: *const PreparedSlashMenu,
    window: PickerWindow,
    include_metadata: bool,
) SlashMenuColumnWidths {
    var widths: SlashMenuColumnWidths = .{ .label = 0, .metadata = 0 };
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const content = preparedSlashMenuRowContent(prepared, match_idx, include_metadata) orelse continue;
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
    return composeSlashMenuRow(alloc, content, selected, column_widths, width);
}

pub noinline fn composePreparedSlashMenuOptionRow(
    alloc: Allocator,
    prepared: *const PreparedSlashMenu,
    match_idx: usize,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
    include_metadata: bool,
) !std.ArrayList(u8) {
    const content = preparedSlashMenuRowContent(prepared, match_idx, include_metadata) orelse return .empty;
    return composeSlashMenuRow(alloc, content, selected, column_widths, width);
}

fn composeSlashMenuRow(
    alloc: Allocator,
    content: SlashMenuRowContent,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
) !std.ArrayList(u8) {
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
    .{ .kind = .mcp, .command = "/mcp", .help_entry = "/mcp [list|resource|prompt|add|remove]", .completion_description = "manage MCP servers, resources, and prompts", .presentation_category = .extensions, .has_args = true },
    .{ .kind = .permissions, .command = "/permissions", .help_entry = "/permissions [ask|auto|remember|revoke|full-access|reset]", .completion_description = "choose permission behavior", .presentation_category = .security, .has_args = true },
    .{ .kind = .credits, .command = "/credits", .aliases = &.{"/balance"}, .help_entry = "/credits (/balance)", .completion_description = "show gateway credits balance", .presentation_category = .account },
    .{ .kind = .settings, .command = "/settings", .help_entry = "/settings", .completion_description = "configure fx", .presentation_category = .general },
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

test "inline picker row budget preserves six roomy choices and shrinks with height" {
    try std.testing.expectEqual(@as(u16, 8), inlinePickerRowBudget(24, 0, 0));
    try std.testing.expectEqual(@as(u16, 6), inlinePickerRowBudget(16, 0, 0));
    try std.testing.expectEqual(@as(u16, 2), inlinePickerRowBudget(16, 0, 4));
    try std.testing.expectEqual(@as(u16, 1), inlinePickerRowBudget(6, 0, 0));
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

    var extensions = try composeSlashMenuOptionRow(std.testing.allocator, picker_test_slash_registry, "/m", &.{}, 1, false, column_widths, 100, true);
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
        .description = "choose focused regression coverage for the affected fx behavior",
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

test "prepared slash menu preserves command-first relevance order" {
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

    var prepared = try prepareSlashMenu(std.testing.allocator, registry, "/name", &skills);
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.commandCount());
    try std.testing.expectEqual(@as(usize, 2), prepared.resultCount());
    const window = edgeScrollPickerWindow(prepared.resultCount(), 0, 6);
    const column_widths = preparedSlashMenuColumnWidths(&prepared, window, true);
    var command_row = try composePreparedSlashMenuOptionRow(std.testing.allocator, &prepared, 0, true, column_widths, 80, true);
    defer command_row.deinit(std.testing.allocator);
    var skill_row = try composePreparedSlashMenuOptionRow(std.testing.allocator, &prepared, 1, false, column_widths, 80, true);
    defer skill_row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, command_row.items, "/rename") != null);
    try std.testing.expect(std.mem.find(u8, skill_row.items, "workflow-helper") != null);
}

test "prepared slash menu keeps skills out of argument completions" {
    const skills = [_]skill_runtime.Skill{.{
        .name = "permissions-helper",
        .description = "permissions help",
        .path = "/tmp/.codex/skills/permissions-helper",
        .source = .global_codex,
    }};

    var prepared = try prepareSlashMenu(std.testing.allocator, picker_test_slash_registry, "/permissions ", &skills);
    defer prepared.deinit(std.testing.allocator);

    const command_count = command_specs.slashCompletionCount(picker_test_slash_registry, "/permissions ");
    try std.testing.expectEqual(command_count, prepared.commandCount());
    try std.testing.expectEqual(command_count, prepared.resultCount());
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

    try std.testing.expectEqual(@as(u16, 18), authPickerRowCount(view));
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

    var unselected_row = try composeAuthPickerRow(alloc, view, 11, authPickerRowCount(view), 100);
    defer unselected_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, unselected_row.items, "Add an API key") != null);

    var narrow_note = try composeAuthPickerRow(alloc, view, 12, authPickerRowCount(view), 58);
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

test "setup root shows prerequisites and active routing values" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initOne(.ai_gateway_api_key),
        .selected_choice = .{ .action = .switch_provider },
        .active_source = .ai_gateway_api_key,
        .include_skip = false,
    };
    const row_count = authPickerRowCount(view);
    try std.testing.expectEqual(@as(u16, 6), row_count);

    var header = try composeAuthPickerRow(alloc, view, 0, row_count, 80);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Setup") != null);

    var provider = try composeAuthPickerRow(alloc, view, 3, row_count, 80);
    defer provider.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, provider.items, "Model provider") != null);
    try std.testing.expect(std.mem.find(u8, provider.items, "Vercel AI Gateway") != null);

    var team = try composeAuthPickerRow(alloc, view, 4, row_count, 80);
    defer team.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, team.items, "Vercel team") != null);
    try std.testing.expect(std.mem.find(u8, team.items, "sign in to manage") != null);

    var credential = try composeAuthPickerRow(alloc, view, 5, row_count, 80);
    defer credential.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, credential.items, "Credential source") != null);
    try std.testing.expect(std.mem.find(u8, credential.items, "AI_GATEWAY_API_KEY") != null);
}

test "setup root fits the inline picker with status and controls" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initMany(&.{ .chatgpt_subscription, .stored_key }),
        .selected_choice = .{ .action = .connections },
        .active_source = .stored_key,
        .active_provider = .codex,
        .include_skip = false,
    };
    const row_count = authPickerRowCount(view);
    try std.testing.expectEqual(@as(u16, 6), row_count);

    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(alloc);
    for (0..row_count) |row_index| {
        var row = try composeAuthPickerRow(alloc, view, @intCast(row_index), row_count, 100);
        defer row.deinit(alloc);
        try screen.appendSlice(alloc, row.items);
        try screen.append(alloc, '\n');
    }

    try std.testing.expect(std.mem.find(u8, screen.items, "Connections") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Model provider") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Vercel team") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Credential source") != null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Enter Open") == null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Esc Close") == null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Routing") == null);
    try std.testing.expect(std.mem.find(u8, screen.items, "Vercel account") == null);

    var gap = try composeAuthPickerRow(alloc, view, 1, row_count, 100);
    defer gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), gap.items.len);

    var header = try composeAuthPickerRow(alloc, view, 0, row_count, 100);
    defer header.deinit(alloc);
    const heading_start = std.mem.find(u8, header.items, "Setup").?;
    try std.testing.expectEqual(
        @as(usize, 0),
        display_width.visibleWidthIgnoringAnsi(header.items[0..heading_start]),
    );

    var selected = try composeAuthPickerRow(alloc, view, 2, row_count, 100);
    defer selected.deinit(alloc);
    const marker_start = std.mem.find(u8, selected.items, "›").?;
    try std.testing.expectEqual(
        @as(usize, 0),
        display_width.visibleWidthIgnoringAnsi(selected.items[0..marker_start]),
    );
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

    try std.testing.expect(std.mem.find(u8, row.items, "Credential source") != null);
}

test "auth picker renders the staged switch and disabled team screens" {
    const alloc = std.testing.allocator;

    const provider_view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = .{ .provider = .gateway },
        .active_source = null,
        .active_provider = .gateway,
        .include_skip = false,
        .stage = .provider,
    };
    const provider_rows = authPickerRowCount(provider_view);
    try std.testing.expectEqual(@as(u16, 5), provider_rows);
    var provider_header = try composeAuthPickerRow(alloc, provider_view, 0, provider_rows, 80);
    defer provider_header.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, provider_header.items, ui_render.dim_style));
    const provider_heading = std.mem.find(u8, provider_header.items, "Model provider").?;
    try std.testing.expectEqual(
        @as(usize, 0),
        display_width.visibleWidthIgnoringAnsi(provider_header.items[0..provider_heading]),
    );
    var provider_gap = try composeAuthPickerRow(alloc, provider_view, 1, provider_rows, 80);
    defer provider_gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), provider_gap.items.len);
    var provider_selected = try composeAuthPickerRow(alloc, provider_view, 2, provider_rows, 80);
    defer provider_selected.deinit(alloc);
    const provider_marker = std.mem.find(u8, provider_selected.items, "›").?;
    try std.testing.expectEqual(
        @as(usize, 0),
        display_width.visibleWidthIgnoringAnsi(provider_selected.items[0..provider_marker]),
    );
    try std.testing.expect(std.mem.find(u8, provider_selected.items, "current") != null);

    const switch_view = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initOne(.stored_key),
        .selected_choice = .{ .source = .stored_key },
        .active_source = .stored_key,
        .include_skip = false,
        .stage = .switch_credential,
    };
    const switch_rows = authPickerRowCount(switch_view);
    try std.testing.expectEqual(@as(u16, 4), switch_rows);
    var switch_header = try composeAuthPickerRow(alloc, switch_view, 0, switch_rows, 80);
    defer switch_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, switch_header.items, "Credential source") != null);

    var switch_gap = try composeAuthPickerRow(alloc, switch_view, 1, switch_rows, 80);
    defer switch_gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), switch_gap.items.len);

    var switch_source = try composeAuthPickerRow(alloc, switch_view, 2, switch_rows, 80);
    defer switch_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, switch_source.items, credentials.sourceLabel(.stored_key)) != null);
    try std.testing.expect(std.mem.find(u8, switch_source.items, "current") != null);

    const team_view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = .stored_key,
        .include_skip = false,
        .stage = .change_team,
    };
    const team_rows = authPickerRowCount(team_view);
    try std.testing.expectEqual(@as(u16, 3), team_rows);
    var team_header = try composeAuthPickerRow(alloc, team_view, 0, team_rows, 80);
    defer team_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, team_header.items, "Vercel team · Search:") != null);

    var team_gap = try composeAuthPickerRow(alloc, team_view, 1, team_rows, 80);
    defer team_gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), team_gap.items.len);

    var no_teams = try composeAuthPickerRow(alloc, team_view, 2, team_rows, 80);
    defer no_teams.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, no_teams.items, "No Vercel teams available") != null);

    var search_view = team_view;
    search_view.team_query = "play";
    var search_header = try composeAuthPickerRow(alloc, search_view, 0, team_rows, 80);
    defer search_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, search_header.items, "Search: play") != null);

    search_view.team_query = "example-internal-team";
    var narrow_search_header = try composeAuthPickerRow(alloc, search_view, 0, team_rows, 20);
    defer narrow_search_header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, narrow_search_header.items, "nternal-team") != null);
    try std.testing.expectEqual(
        @as(u16, 20),
        authPickerQueryCursorColumn(search_view, 20).?,
    );

    var no_matches = try composeAuthPickerRow(alloc, search_view, 2, team_rows, 80);
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
    try std.testing.expect(std.mem.find(u8, row.items, "  Open   ") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Authorize with Codex") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b]8;") != null);
    try std.testing.expect(std.mem.find(u8, row.items, url) != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b]8;;\x1b\\") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 40);
}

fn composeAuthPickerTestGrid(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !vt_emulator.Grid {
    const row_count = authPickerRowCount(view);
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(alloc);
    for (0..row_count) |row_index| {
        if (row_index > 0) try screen.appendSlice(alloc, "\r\n");
        var row = try composeAuthPickerRow(alloc, view, @intCast(row_index), row_count, width);
        defer row.deinit(alloc);
        try screen.appendSlice(alloc, row.items);
    }

    var grid = try vt_emulator.Grid.init(alloc, width, row_count);
    errdefer grid.deinit();
    try grid.feed(screen.items);
    return grid;
}

test "Codex sign-in projects the compact aligned footer through the VT emulator" {
    const alloc = std.testing.allocator;
    const url = "https://issuer.test/oauth/authorize?state=codex-state";
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

    try std.testing.expectEqual(@as(u16, 4), authPickerRowCount(view));
    var grid = try composeAuthPickerTestGrid(alloc, view, 80);
    defer grid.deinit();

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings(
        "Sign in with Codex                                    Waiting for authorization…",
        row.items,
    );
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(2, &row);
    try std.testing.expectEqualStrings("", row.items);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(3, &row);
    try std.testing.expectEqualStrings("  Open   Authorize with Codex", row.items);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(4, &row);
    try std.testing.expectEqualStrings("", row.items);

    const link_cell = grid.cellAt(3, 10).?;
    try std.testing.expect(link_cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings(url, grid.hyperlinkUrl(link_cell.style.hyperlink_id).?);
}

test "Grok sign-in starts with the collapsed browser flow in the VT emulator" {
    const alloc = std.testing.allocator;
    const url = "https://auth.x.ai/oauth2/authorize?state=grok-state";
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .sign_in,
        .sign_in_source = .grok_subscription,
        .sign_in = .{
            .state = .polling,
            .verification_uri = url,
            .accepts_manual_code = true,
        },
    };

    try std.testing.expectEqual(@as(u16, 5), authPickerRowCount(view));
    var grid = try composeAuthPickerTestGrid(alloc, view, 80);
    defer grid.deinit();

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    const expected_rows = [_][]const u8{
        "Sign in with Grok                                     Waiting for authorization…",
        "",
        "  Open   Authorize with Grok",
        "  Browser didn't return? Press Tab to enter a code",
        "",
    };
    for (expected_rows, 1..) |expected, row_index| {
        row.clearRetainingCapacity();
        try grid.rowTextTrimmed(@intCast(row_index), &row);
        try std.testing.expectEqualStrings(expected, row.items);
    }

    const link_cell = grid.cellAt(3, 10).?;
    try std.testing.expect(link_cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings(url, grid.hyperlinkUrl(link_cell.style.hyperlink_id).?);
}

test "Grok manual fallback projects the approved expanded layout through the VT emulator" {
    const alloc = std.testing.allocator;
    const url = "https://auth.x.ai/oauth2/authorize?state=grok-manual-state";
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .sign_in,
        .sign_in_source = .grok_subscription,
        .sign_in = .{
            .state = .polling,
            .verification_uri = url,
            .accepts_manual_code = true,
        },
        .sign_in_code_visible = true,
    };

    try std.testing.expectEqual(@as(u16, 7), authPickerRowCount(view));
    var grid = try composeAuthPickerTestGrid(alloc, view, 80);
    defer grid.deinit();

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    const expected_rows = [_][]const u8{
        "Sign in with Grok                                     Waiting for authorization…",
        "",
        "  Open   Authorize with Grok",
        "",
        "  Paste the code shown by xAI",
        "  ┃ Paste or type the code",
        "",
    };
    for (expected_rows, 1..) |expected, row_index| {
        row.clearRetainingCapacity();
        try grid.rowTextTrimmed(@intCast(row_index), &row);
        try std.testing.expectEqualStrings(expected, row.items);
    }

    const link_cell = grid.cellAt(3, 10).?;
    try std.testing.expect(link_cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings(url, grid.hyperlinkUrl(link_cell.style.hyperlink_id).?);
}

test "compact subscription browser sign-in prioritizes the authorization action" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        source: credentials.Source,
        label: []const u8,
    }{
        .{ .source = .chatgpt_subscription, .label = "Authorize with Codex" },
        .{ .source = .grok_subscription, .label = "Authorize with Grok" },
    };

    for (cases) |case| {
        const view = auth_runtime.PickerView{
            .active = true,
            .available_sources = .empty,
            .selected_choice = null,
            .active_source = null,
            .include_skip = false,
            .stage = .sign_in,
            .sign_in_source = case.source,
            .sign_in = .{
                .state = .polling,
                .verification_uri = "https://issuer.test/authorize",
                .accepts_manual_code = case.source == .grok_subscription,
            },
        };

        var row = try composeAuthPickerRow(alloc, view, 0, 1, 80);
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, case.label) != null);
    }
}

test "compact Grok sign-in keeps masked code entry without duplicate controls" {
    const alloc = std.testing.allocator;
    const view = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
        .stage = .sign_in,
        .sign_in_source = .grok_subscription,
        .sign_in = .{
            .state = .polling,
            .verification_uri = "https://x.ai/authorize",
            .accepts_manual_code = true,
        },
        .sign_in_code_visible = true,
        .sign_in_code_mask_count = 3,
    };

    var row = try composeAuthPickerRow(alloc, view, 0, 1, 80);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "•••") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Enter submits") == null);
    try std.testing.expect(std.mem.find(u8, row.items, "Esc cancels") == null);
    try std.testing.expect(std.mem.find(u8, row.items, ui_render.selected_completion_style) != null);
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

    var first_source = try composeAuthPickerRow(alloc, view, 2, 4, 80);
    defer first_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first_source.items, "AI_GATEWAY_API_KEY") != null);
    try std.testing.expect(std.mem.find(u8, first_source.items, "fx login") == null);

    var selected_source = try composeAuthPickerRow(alloc, view, 3, 4, 80);
    defer selected_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected_source.items, "fx login") != null);

    var scrolled_view = view;
    scrolled_view.selected_choice = .{ .source = .stored_key };
    var scrolled_first = try composeAuthPickerRow(alloc, scrolled_view, 2, 4, 80);
    defer scrolled_first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, scrolled_first.items, "fx login") != null);

    var scrolled_selected = try composeAuthPickerRow(alloc, scrolled_view, 3, 4, 80);
    defer scrolled_selected.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, scrolled_selected.items, credentials.sourceLabel(.stored_key)) != null);
}

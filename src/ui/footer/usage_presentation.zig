//! Draws the `/usage` dashboard from a `usage.Snapshot`, one row at a time,
//! the way `df` prints: lowercase headers (table name bold, column labels
//! dim), numbers right-aligned under them, and the current model in bold
//! behind a `❯`. No color, in any theme. Tables are as wide as their content, never stretched
//! to the terminal; narrow terminals drop columns before clipping names.

const std = @import("std");
const usage = @import("../../usage/usage.zig");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const ModelRow = usage.report.ModelRow;
const Period = usage.Period;

/// Most model rows on screen at once; the window scrolls over the rest.
pub const max_model_rows: usize = 10;

pub const Projection = struct {
    active: bool = false,
    period: Period = .month,
    selected_model: usize = 0,
    model_window_start: usize = 0,
    /// The selected model's detail screen instead of the tables.
    detail: bool = false,
    snapshot: ?*const usage.Snapshot = null,
};

const Line = union(enum) {
    heading,
    blank,
    /// One line of guidance when there is nothing to tabulate.
    message,
    period_header,
    period_row: Period,
    budget_header,
    budget_row,
    model_header,
    model_row: usize,
    /// The models below the window, summed; carries the first one's index.
    more_row: usize,
    no_models,
    detail_period_header,
    detail_period_row: Period,
    tokens_header,
    tokens_row: Period,
    perf_header,
    perf_row: Period,
    codex_plan_header,
    codex_plan_row,
    codex_limit_header,
    /// One window of one limit, in `codexWindows` order.
    codex_limit_row: usize,
    codex_tokens_header,
    codex_tokens_row: CodexSpan,
    codex_model_header,
    /// One of the model list's reserved rows: a model, the "N more" row, the
    /// empty message, or padding that keeps the tables below in place.
    codex_model_line: usize,
    codex_where_header,
    codex_where_row,
    codex_record_header,
    codex_record_row,
    codex_habits_header,
    codex_habits_row,
    /// A team's usage page, or no billing data, in the limit table's place.
    grok_note,
    grok_limit_header,
    grok_limit_row,
    grok_product_header,
    grok_product_row: usize,
    grok_plan_header,
    grok_plan_row,
};

const max_lines = 40;

// ---------------------------------------------------------------- layout

fn listedModels(p: Projection) []const ModelRow {
    const s = p.snapshot orelse return &.{};
    return s.of(p.period).models;
}

fn hasBudget(p: Projection) bool {
    const s = p.snapshot orelse return false;
    return s.budget() != null;
}

/// Nothing to tabulate: not signed in, or nothing cached yet.
fn messageOnly(p: Projection) bool {
    const s = p.snapshot orelse return true;
    if (s.status == .unavailable) return true;
    if (s.scope == .codex) return s.codex_usage == null;
    if (s.scope == .grok) return s.grok_usage == null;
    for (s.views) |v| if (!v.empty()) return false;
    return s.status != .ready;
}

/// A ChatGPT plan through Codex: limits instead of spend.
pub fn isCodex(p: Projection) bool {
    const s = p.snapshot orelse return false;
    return s.scope == .codex;
}

/// A Grok plan: its allowance and credits instead of spend.
pub fn isGrok(p: Projection) bool {
    const s = p.snapshot orelse return false;
    return s.scope == .grok;
}

/// A provider's plan (Codex, Grok) rather than AI Gateway spend: nothing to
/// select or open.
pub fn isPlan(p: Projection) bool {
    return isCodex(p) or isGrok(p);
}

/// The service the numbers come from, for messages.
fn serviceName(p: Projection) []const u8 {
    if (isCodex(p)) return "ChatGPT";
    if (isGrok(p)) return "Grok";
    return "AI Gateway";
}

/// Whether there are tables to move around in; otherwise only Esc applies.
pub fn showsTables(p: Projection) bool {
    return !messageOnly(p);
}

/// Rows of the main view above the model rows.
fn tableRows(p: Projection) usize {
    // heading, blank, period header + 3 rows, blank, [budget header + row,
    // blank], model header.
    return 2 + 4 + 1 + (if (hasBudget(p)) @as(usize, 3) else 0) + 1;
}

const detail_rows: usize = 2 + 4 + 1 + 4 + 1 + 4;

pub fn desiredRowCount(p: Projection) usize {
    if (messageOnly(p)) return 3;
    if (isCodex(p)) return codexRows(p, codexSections(p, max_lines));
    if (isGrok(p)) return grokRows(grokSections(p, max_lines));
    if (p.detail) return detail_rows;
    const models = listedModels(p).len;
    if (models == 0) return tableRows(p) + 1;
    return tableRows(p) + @min(models, max_model_rows) + @intFromBool(models > max_model_rows);
}

/// How many model rows fit when the dashboard gets `visible_rows`, keeping
/// one row for the "N more" line when not every model fits.
pub fn visibleModelItems(p: Projection, visible_rows: u16) usize {
    if (isCodex(p)) return codexModelWindow(p, visible_rows).items;
    const models = listedModels(p).len;
    const area = @as(usize, visible_rows) -| tableRows(p);
    if (models <= @min(area, max_model_rows)) return @max(models, 1);
    return @max(@min(area -| 1, max_model_rows), 1);
}

fn layout(p: Projection, visible_rows: usize, buf: *[max_lines]Line) []const Line {
    var n: usize = 0;
    const push = struct {
        fn f(b: *[max_lines]Line, i: *usize, line: Line) void {
            if (i.* < b.len) {
                b[i.*] = line;
                i.* += 1;
            }
        }
    }.f;
    push(buf, &n, .heading);
    push(buf, &n, .blank);
    if (messageOnly(p)) {
        push(buf, &n, .message);
        return buf[0..n];
    }
    if (isCodex(p)) {
        const sections = codexSections(p, visible_rows);
        if (codexProfile(p) != null) {
            push(buf, &n, .codex_tokens_header);
            for (CodexSpan.all) |span| push(buf, &n, .{ .codex_tokens_row = span });
            push(buf, &n, .blank);
        }
        if (sections.model_table) {
            push(buf, &n, .codex_model_header);
            for (0..sections.model_rows) |slot| push(buf, &n, .{ .codex_model_line = slot });
            push(buf, &n, .blank);
        }
        if (sections.where) {
            push(buf, &n, .codex_where_header);
            push(buf, &n, .codex_where_row);
            push(buf, &n, .blank);
        }
        if (sections.record) {
            push(buf, &n, .codex_record_header);
            push(buf, &n, .codex_record_row);
            push(buf, &n, .blank);
        }
        if (sections.habits) {
            push(buf, &n, .codex_habits_header);
            push(buf, &n, .codex_habits_row);
            push(buf, &n, .blank);
        }
        push(buf, &n, .codex_plan_header);
        push(buf, &n, .codex_plan_row);
        const windows = codexWindowCount(p);
        if (windows > 0) {
            push(buf, &n, .blank);
            push(buf, &n, .codex_limit_header);
            for (0..windows) |i| push(buf, &n, .{ .codex_limit_row = i });
        }
        return buf[0..n];
    }
    if (isGrok(p)) {
        const sections = grokSections(p, visible_rows);
        if (sections.note) {
            push(buf, &n, .grok_note);
            push(buf, &n, .blank);
        }
        if (sections.limit) {
            push(buf, &n, .grok_limit_header);
            push(buf, &n, .grok_limit_row);
            push(buf, &n, .blank);
        }
        if (sections.products > 0) {
            push(buf, &n, .grok_product_header);
            for (0..sections.products) |i| push(buf, &n, .{ .grok_product_row = i });
            push(buf, &n, .blank);
        }
        push(buf, &n, .grok_plan_header);
        push(buf, &n, .grok_plan_row);
        return buf[0..n];
    }
    if (p.detail) {
        push(buf, &n, .detail_period_header);
        for (Period.all) |period| push(buf, &n, .{ .detail_period_row = period });
        push(buf, &n, .blank);
        push(buf, &n, .tokens_header);
        for (Period.all) |period| push(buf, &n, .{ .tokens_row = period });
        push(buf, &n, .blank);
        push(buf, &n, .perf_header);
        for (Period.all) |period| push(buf, &n, .{ .perf_row = period });
        return buf[0..n];
    }
    push(buf, &n, .period_header);
    for (Period.all) |period| push(buf, &n, .{ .period_row = period });
    push(buf, &n, .blank);
    if (hasBudget(p)) {
        push(buf, &n, .budget_header);
        push(buf, &n, .budget_row);
        push(buf, &n, .blank);
    }
    push(buf, &n, .model_header);
    const models = listedModels(p).len;
    if (models == 0) {
        push(buf, &n, .no_models);
        return buf[0..n];
    }
    const visible = visibleModelItems(p, @intCast(@min(visible_rows, std.math.maxInt(u16))));
    const start = @min(p.model_window_start, models -| visible);
    const end = @min(start + visible, models);
    for (start..end) |index| push(buf, &n, .{ .model_row = index });
    if (end < models) push(buf, &n, .{ .more_row = end });
    return buf[0..n];
}

pub fn composeRow(alloc: Allocator, p: Projection, row_index: u16, visible_rows: u16, width: u16) !std.ArrayList(u8) {
    var buf: [max_lines]Line = undefined;
    const lines = layout(p, visible_rows, &buf);
    if (row_index >= lines.len or row_index >= visible_rows) return .empty;
    const limit: usize = width;
    return switch (lines[row_index]) {
        .heading => composeHeading(alloc, p, limit),
        .blank => .empty,
        .message => composeMessage(alloc, p, limit),
        .period_header => composeCells(alloc, &period_header, .header, "", limit),
        .period_row => |period| composePeriodRow(alloc, p, period, limit),
        .budget_header => composeBudgetHeader(alloc, limit),
        .budget_row => composeBudgetRow(alloc, p, limit),
        .model_header => composeModelHeader(alloc, p, limit),
        .model_row => |index| composeModelRow(alloc, p, index, limit),
        .more_row => |first| composeMoreRow(alloc, p, first, limit),
        .no_models => row_text.composeTextRow(alloc, noModelsText(p.period), width, ui_render.dim_style, 2),
        .detail_period_header => composeCells(alloc, &detail_period_header, .header, "", limit),
        .detail_period_row => |period| composeDetailPeriodRow(alloc, p, period, limit),
        .tokens_header => composeCells(alloc, if (limit >= wideTokensWidth()) &tokens_header_wide else &tokens_header_narrow, .header, "", limit),
        .tokens_row => |period| composeTokensRow(alloc, p, period, limit),
        .perf_header => composeCells(alloc, if (limit >= widePerfWidth()) &perf_header_wide else &perf_header_narrow, .header, "", limit),
        .perf_row => |period| composePerfRow(alloc, p, period, limit),
        .codex_plan_header => composeCodexPlanHeader(alloc, p, limit),
        .codex_plan_row => composeCodexPlanRow(alloc, p, limit),
        .codex_limit_header => composeCodexLimitHeader(alloc, p, limit),
        .codex_limit_row => |index| composeCodexLimitRow(alloc, p, index, limit),
        .codex_tokens_header => composeCells(alloc, &codex_tokens_header, .header, "", limit),
        .codex_tokens_row => |span| composeCodexTokensRow(alloc, p, span, limit),
        .codex_model_header => composeCodexModelHeader(alloc, p, limit),
        .codex_model_line => |slot| composeCodexModelLine(alloc, p, slot, visible_rows, limit),
        .codex_where_header => composeCodexWhere(alloc, p, .header, limit),
        .codex_where_row => composeCodexWhere(alloc, p, .data, limit),
        .codex_record_header => composeColumns(alloc, &record_columns, null, limit),
        .codex_record_row => composeCodexRecordRow(alloc, p, limit),
        .codex_habits_header => composeColumns(alloc, &habits_columns, null, limit),
        .codex_habits_row => composeCodexHabitsRow(alloc, p, limit),
        .grok_note => composeGrokNote(alloc, p, limit),
        .grok_limit_header => composeCells(alloc, &grok_limit_header, .header, "", limit),
        .grok_limit_row => composeGrokLimitRow(alloc, p, limit),
        .grok_product_header => composeGrokProductHeader(alloc, p, limit),
        .grok_product_row => |index| composeGrokProductRow(alloc, p, index, limit),
        .grok_plan_header => composeGrokPlanHeader(alloc, p, limit),
        .grok_plan_row => composeGrokPlanRow(alloc, p, limit),
    };
}

// ----------------------------------------------------------------- cells

const Cell = struct {
    text: []const u8,
    width: usize,
    left: bool = false,
};

const Kind = enum {
    /// A table's header row: the first cell (the table name) bold, the
    /// column labels dim.
    header,
    /// More column labels on the same header row: all dim.
    header_labels,
    data,
};

/// Appends `cells` padded to their widths, stopping before a cell that would
/// pass `limit` columns. Headers style the first cell bold and the rest dim;
/// data rows use `row_style` throughout.
fn composeCells(alloc: Allocator, cells: []const Cell, kind: Kind, row_style: []const u8, limit: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (row_style.len > 0) try row.appendSlice(alloc, row_style);
    _ = try appendCells(alloc, &row, cells, kind, 0, limit);
    if (row_style.len > 0) try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendCells(alloc: Allocator, row: *std.ArrayList(u8), cells: []const Cell, kind: Kind, used_start: usize, limit: usize) !usize {
    var used = used_start;
    for (cells, 0..) |cell, i| {
        if (used + cell.width > limit) break;
        const pad = cell.width -| display_width.visibleWidth(cell.text);
        const style: []const u8 = switch (kind) {
            .header => if (i == 0) ui_render.bold_style else ui_render.dim_style,
            .header_labels => ui_render.dim_style,
            .data => "",
        };
        if (!cell.left) try row.appendNTimes(alloc, ' ', pad);
        if (style.len > 0) try row.appendSlice(alloc, style);
        try row.appendSlice(alloc, cell.text);
        if (style.len > 0) try row.appendSlice(alloc, ui_render.reset_style);
        if (cell.left) try row.appendNTimes(alloc, ' ', pad);
        used += cell.width;
    }
    return used;
}

/// Model names and labels come from the network and the credential: keep
/// them on one line, and show `?` for anything fx would escape on a terminal
/// (control bytes, C1 controls, bidi and zero-width characters, invalid
/// UTF-8). Cuts only between characters, so `buf` always holds whole ones.
fn safeText(buf: []u8, text: []const u8) []const u8 {
    var in: usize = 0;
    var out: usize = 0;
    while (in < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[in]) catch 1;
        const end = @min(in + len, text.len);
        const piece = text[in..end];
        const keep = piece.len == len and text_utils.isTerminalSafe(piece);
        const n = if (keep) piece.len else 1;
        if (out + n > buf.len) break;
        if (keep) @memcpy(buf[out..][0..n], piece) else buf[out] = '?';
        out += n;
        in = end;
    }
    return buf[0..out];
}

// ---------------------------------------------------------------- heading

/// `usage: <who>` on the left; the status ("updated 2m ago", "updating…",
/// a failure) in the right corner. A narrow terminal shortens the left part
/// first and drops the status only when even a short name would not fit.
fn composeHeading(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var left_buf: [320]u8 = undefined;
    const left = headingLeft(&left_buf, p);
    var status_buf: [96]u8 = undefined;
    const status = headingStatus(&status_buf, p);
    const prefix_width: usize = "usage: ".len;
    const min_left: usize = 12;
    const status_width = display_width.visibleWidth(status);
    const show_status = status_width > 0 and prefix_width + min_left + 2 + status_width <= limit;
    const left_room = if (show_status) limit - prefix_width - 2 - status_width else limit -| prefix_width;

    try row.print(alloc, "{s}usage:{s} ", .{ ui_render.bold_style, ui_render.reset_style });
    const left_start = row.items.len;
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, left, left_room);
    if (show_status) {
        const used = prefix_width + display_width.visibleWidth(row.items[left_start..]);
        try row.appendNTimes(alloc, ' ', limit - used - status_width);
        // A failure reads in normal weight; routine freshness stays dim.
        const failed = if (p.snapshot) |snap| snap.status == .failed else false;
        if (failed) {
            try row.appendSlice(alloc, status);
        } else {
            try row.print(alloc, "{s}{s}{s}", .{ ui_render.dim_style, status, ui_render.reset_style });
        }
    }
    return row;
}

/// Whose numbers these are, or on a detail screen which model.
fn headingLeft(buf: []u8, p: Projection) []const u8 {
    const s = p.snapshot orelse return "AI Gateway";
    if (s.status == .unavailable) return switch (s.status.unavailable) {
        .no_gateway_sign_in => "not signed in to AI Gateway",
        .no_team => "fx login has no team",
        .unsupported_provider => "this provider's usage isn't shown yet",
        .refresh_needed => "the sign-in needs a refresh",
    };
    if (p.detail) {
        const models = listedModels(p);
        if (p.selected_model < models.len) {
            var name_buf: [256]u8 = undefined;
            const name = safeText(&name_buf, models[p.selected_model].model);
            return std.mem.print(buf, "{s}, model {d} of {d}", .{ name, p.selected_model + 1, models.len }) catch name;
        }
    }
    if (s.label.len == 0) return "AI Gateway";
    if (codexProfile(p)) |profile| if (profile.name) |name| {
        var label_buf: [128]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        const label = safeText(&label_buf, s.label);
        return std.mem.print(buf, "{s}, {s}", .{ label, safeText(&name_buf, name) }) catch safeText(buf, s.label);
    };
    return safeText(buf, s.label);
}

fn headingStatus(buf: []u8, p: Projection) []const u8 {
    const s = p.snapshot orelse return "fetching…";
    var ago_buf: [32]u8 = undefined;
    const ago: ?[]const u8 = if (s.fetchedAtMs()) |at| agoText(&ago_buf, s.now_ms - at) else null;
    return switch (s.status) {
        .fetching => if (messageOnly(p)) "fetching…" else "updating…",
        .ready => if (ago) |a| std.mem.print(buf, "updated {s}", .{a}) catch "" else "nothing fetched today",
        .failed => |f| blk: {
            var failure_buf: [64]u8 = undefined;
            const failure = failureText(&failure_buf, p, f);
            break :blk if (ago) |a|
                std.mem.print(buf, "{s}, last updated {s}", .{ failure, a }) catch failure
            else
                std.mem.print(buf, "{s}", .{failure}) catch failure;
        },
        .unavailable => "",
    };
}

/// `just now`, `2m ago`, `3h ago`, `2d ago`.
fn agoText(buf: []u8, elapsed_ms: i64) []const u8 {
    const minutes = @divFloor(@max(elapsed_ms, 0), std.time.ms_per_min);
    if (minutes < 1) return "just now";
    const value: u64 = @intCast(if (minutes < 60) minutes else if (minutes < 24 * 60) @divFloor(minutes, 60) else @divFloor(minutes, 24 * 60));
    const unit: []const u8 = if (minutes < 60) "m" else if (minutes < 24 * 60) "h" else "d";
    return std.mem.print(buf, "{d}{s} ago", .{ value, unit }) catch "";
}

fn failureText(buf: []u8, p: Projection, failure: usage.Failure) []const u8 {
    const service = serviceName(p);
    return switch (failure) {
        .network => std.mem.print(buf, "couldn't reach {s}", .{service}) catch "",
        .refused => std.mem.print(buf, "{s} refused this sign-in", .{service}) catch "",
        .not_available => if (isPlan(p)) "usage isn't available for this plan" else "usage reports aren't available for this team",
        .rate_limited => "rate limited, try again shortly",
        .server => std.mem.print(buf, "{s} error", .{service}) catch "",
        .bad_response => std.mem.print(buf, "unexpected {s} response", .{service}) catch "",
        .cache => "couldn't save the usage cache",
    };
}

fn composeMessage(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    var fetching_buf: [48]u8 = undefined;
    const text: []const u8 = blk: {
        const s = p.snapshot orelse break :blk "fetching usage from AI Gateway";
        break :blk switch (s.status) {
            .unavailable => |u| switch (u) {
                .no_gateway_sign_in => "(use /login, or set AI_GATEWAY_API_KEY)",
                .no_team => "(use /login to pick a team)",
                .unsupported_provider => "(use /provider and pick AI Gateway to see AI Gateway usage)",
                .refresh_needed => "(send a message to renew it, then reopen /usage)",
            },
            .fetching => std.mem.print(&fetching_buf, "fetching usage from {s}", .{serviceName(p)}) catch "fetching usage",
            .failed => "(press r to retry)",
            .ready => "no usage yet",
        };
    };
    return row_text.composeTextRow(alloc, text, @intCast(@min(limit, std.math.maxInt(u16))), ui_render.dim_style, 2);
}

fn noModelsText(period: Period) []const u8 {
    return switch (period) {
        .today => "no usage today (UTC)",
        .days_7 => "no usage in the last 7 days",
        .month => "no usage this month",
    };
}

// ---------------------------------------------------------------- period

const period_header = [_]Cell{
    .{ .text = "period", .width = 8, .left = true },
    .{ .text = "spent", .width = 11 },
    .{ .text = "requests", .width = 10 },
    .{ .text = "tokens", .width = 8 },
};

fn composePeriodRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const t = p.snapshot.?.of(period).totals;
    var spent: [32]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = period.label(), .width = 8, .left = true },
        .{ .text = money(&spent, t.total_cost), .width = 11 },
        .{ .text = grouped(&requests, t.request_count), .width = 10 },
        .{ .text = compact(&tokens, t.totalTokens()), .width = 8 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

// ---------------------------------------------------------------- budget

const BudgetColumns = enum { full, no_resets, small };

fn budgetColumns(limit: usize) BudgetColumns {
    if (limit >= 55) return .full;
    if (limit >= 47) return .no_resets;
    return .small;
}

fn composeBudgetHeader(alloc: Allocator, limit: usize) !std.ArrayList(u8) {
    const full = [_]Cell{
        .{ .text = "budget", .width = 6, .left = true },
        .{ .text = "size", .width = 12 },
        .{ .text = "used", .width = 11 },
        .{ .text = "avail", .width = 12 },
        .{ .text = "use%", .width = 6 },
        .{ .text = "", .width = 2 },
        .{ .text = "resets", .width = 6, .left = true },
    };
    const small = [_]Cell{
        .{ .text = "budget", .width = 6, .left = true },
        .{ .text = "used", .width = 11 },
        .{ .text = "avail", .width = 12 },
        .{ .text = "use%", .width = 6 },
    };
    return switch (budgetColumns(limit)) {
        .full => composeCells(alloc, &full, .header, "", limit),
        .no_resets => composeCells(alloc, full[0..5], .header, "", limit),
        .small => composeCells(alloc, &small, .header, "", limit),
    };
}

fn composeBudgetRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const s = p.snapshot.?;
    const b = s.budget().?;
    var size: [32]u8 = undefined;
    var used: [32]u8 = undefined;
    var avail: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;
    var resets_buf: [16]u8 = undefined;
    const pct: u64 = if (b.limit > 0) @intFromFloat(@min(@round(b.spent / b.limit * 100), 999)) else 0;
    const resets: []const u8 = if (s.budgetResetDay()) |day| shortDay(&resets_buf, day) else "-";
    const full = [_]Cell{
        .{ .text = "user", .width = 6, .left = true },
        .{ .text = money(&size, b.limit), .width = 12 },
        .{ .text = money(&used, b.spent), .width = 11 },
        .{ .text = money(&avail, @max(b.limit - b.spent, 0)), .width = 12 },
        .{ .text = std.mem.print(&pct_buf, "{d}%", .{pct}) catch "", .width = 6 },
        .{ .text = "", .width = 2 },
        .{ .text = resets, .width = 6, .left = true },
    };
    const small = [_]Cell{ full[0], full[2], full[3], full[4] };
    return switch (budgetColumns(limit)) {
        .full => composeCells(alloc, &full, .data, "", limit),
        .no_resets => composeCells(alloc, full[0..5], .data, "", limit),
        .small => composeCells(alloc, &small, .data, "", limit),
    };
}

/// `nov 1`.
fn shortDay(buf: []u8, day: i64) []const u8 {
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    const md = usage.report.monthDay(day);
    return std.mem.print(buf, "{s} {d}", .{ months[md.month - 1], md.day }) catch "";
}

// ----------------------------------------------------------------- models

const ModelColumns = enum { full, no_share, small };

const ModelLayout = struct {
    columns: ModelColumns,
    name_width: usize,
};

const gutter: usize = 2;

fn modelColumnsWidth(columns: ModelColumns) usize {
    return switch (columns) {
        .full => 11 + 8 + 10 + 8,
        .no_share => 11 + 10 + 8,
        .small => 11 + 10,
    };
}

/// The name column is as wide as the longest listed name (or the header),
/// so the table never stretches; share, then tokens, give way first.
fn modelLayout(p: Projection, limit: usize) ModelLayout {
    var header_buf: [24]u8 = undefined;
    var name_width = display_width.visibleWidth(modelHeaderText(&header_buf, p.period));
    var safe_buf: [256]u8 = undefined;
    // Measure what is drawn: control bytes are shown as `?`.
    for (listedModels(p)) |model| name_width = @max(name_width, display_width.visibleWidth(safeText(&safe_buf, model.model)));
    const room = limit -| gutter;
    for ([_]ModelColumns{ .full, .no_share, .small }) |columns| {
        if (name_width + modelColumnsWidth(columns) <= room) return .{ .columns = columns, .name_width = name_width };
    }
    return .{ .columns = .small, .name_width = @max(room -| modelColumnsWidth(.small), 8) };
}

fn modelHeaderText(buf: []u8, period: Period) []const u8 {
    return std.mem.print(buf, "model ({s})", .{period.label()}) catch "model";
}

fn modelCells(columns: ModelColumns, spent: []const u8, share: []const u8, requests: []const u8, tokens: []const u8, out: *[4]Cell) []const Cell {
    out[0] = .{ .text = spent, .width = 11 };
    switch (columns) {
        .full => {
            out[1] = .{ .text = share, .width = 8 };
            out[2] = .{ .text = requests, .width = 10 };
            out[3] = .{ .text = tokens, .width = 8 };
            return out[0..4];
        },
        .no_share => {
            out[1] = .{ .text = requests, .width = 10 };
            out[2] = .{ .text = tokens, .width = 8 };
            return out[0..3];
        },
        .small => {
            out[1] = .{ .text = requests, .width = 10 };
            return out[0..2];
        },
    }
}

fn composeModelHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const l = modelLayout(p, limit);
    var header_buf: [24]u8 = undefined;
    var rest: [4]Cell = undefined;
    const numbers = modelCells(l.columns, "spent", "share", "requests", "tokens", &rest);
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendNTimes(alloc, ' ', gutter);
    const name = [_]Cell{.{ .text = modelHeaderText(&header_buf, p.period), .width = l.name_width, .left = true }};
    const used = try appendCells(alloc, &row, &name, .header, gutter, limit);
    _ = try appendCells(alloc, &row, numbers, .header_labels, used, limit);
    return row;
}

fn composeModelRow(alloc: Allocator, p: Projection, index: usize, limit: usize) !std.ArrayList(u8) {
    const models = listedModels(p);
    const model = models[index];
    const total = p.snapshot.?.of(p.period).totals.total_cost;
    const l = modelLayout(p, limit);
    var spent: [32]u8 = undefined;
    var share: [16]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    var rest: [4]Cell = undefined;
    const numbers = modelCells(
        l.columns,
        money(&spent, model.totals.total_cost),
        percent(&share, shareOf(model.totals.total_cost, total)),
        grouped(&requests, model.totals.request_count),
        compact(&tokens, model.totals.totalTokens()),
        &rest,
    );
    const selected = index == p.selected_model;
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (selected) {
        try row.print(alloc, "{s}❯ ", .{ui_render.bold_style});
    } else {
        try row.appendNTimes(alloc, ' ', gutter);
    }
    try appendName(alloc, &row, model.model, l.name_width);
    _ = try appendCells(alloc, &row, numbers, .data, gutter + l.name_width, limit);
    if (selected) try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendName(alloc: Allocator, row: *std.ArrayList(u8), name: []const u8, name_width: usize) !void {
    var safe_buf: [256]u8 = undefined;
    const safe = safeText(&safe_buf, name);
    const start = row.items.len;
    try row_text.appendSingleLineMiddleEllipsized(alloc, row, safe, name_width);
    const shown = display_width.visibleWidth(row.items[start..]);
    try row.appendNTimes(alloc, ' ', name_width -| shown);
}

fn composeMoreRow(alloc: Allocator, p: Projection, first: usize, limit: usize) !std.ArrayList(u8) {
    const models = listedModels(p);
    var sum: usage.report.Totals = .{};
    for (models[first..]) |model| sum.add(model.totals);
    const total = p.snapshot.?.of(p.period).totals.total_cost;
    const l = modelLayout(p, limit);
    var label_buf: [32]u8 = undefined;
    var spent: [32]u8 = undefined;
    var share: [16]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    var rest: [4]Cell = undefined;
    const numbers = modelCells(
        l.columns,
        money(&spent, sum.total_cost),
        percent(&share, shareOf(sum.total_cost, total)),
        grouped(&requests, sum.request_count),
        compact(&tokens, sum.totalTokens()),
        &rest,
    );
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendNTimes(alloc, ' ', gutter);
    try appendName(alloc, &row, std.mem.print(&label_buf, "{d} more", .{models.len - first}) catch "more", l.name_width);
    _ = try appendCells(alloc, &row, numbers, .data, gutter + l.name_width, limit);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

// ----------------------------------------------------------------- detail

fn selectedName(p: Projection) ?[]const u8 {
    const models = listedModels(p);
    return if (p.selected_model < models.len) models[p.selected_model].model else null;
}

/// The selected model's row for `period`, or null when it had no usage then.
fn detailRow(p: Projection, period: Period) ?ModelRow {
    const name = selectedName(p) orelse return null;
    for (p.snapshot.?.of(period).models) |model| {
        if (std.mem.eql(u8, model.model, name)) return model;
    }
    return null;
}

const detail_period_header = [_]Cell{
    .{ .text = "period", .width = 8, .left = true },
    .{ .text = "spent", .width = 11 },
    .{ .text = "share", .width = 8 },
    .{ .text = "requests", .width = 10 },
    .{ .text = "tokens", .width = 8 },
};

fn composeDetailPeriodRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const row = detailRow(p, period);
    const total = p.snapshot.?.of(period).totals.total_cost;
    var spent: [32]u8 = undefined;
    var share: [16]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = period.label(), .width = 8, .left = true },
        .{ .text = if (row) |r| money(&spent, r.totals.total_cost) else "-", .width = 11 },
        .{ .text = if (row) |r| percent(&share, shareOf(r.totals.total_cost, total)) else "-", .width = 8 },
        .{ .text = if (row) |r| grouped(&requests, r.totals.request_count) else "-", .width = 10 },
        .{ .text = if (row) |r| compact(&tokens, r.totals.totalTokens()) else "-", .width = 8 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

const tokens_header_wide = [_]Cell{
    .{ .text = "tokens", .width = 8, .left = true },
    .{ .text = "input", .width = 9 },
    .{ .text = "output", .width = 9 },
    .{ .text = "reasoning", .width = 11 },
    .{ .text = "cache read", .width = 12 },
    .{ .text = "cache write", .width = 13 },
};

const tokens_header_narrow = [_]Cell{
    .{ .text = "tokens", .width = 6, .left = true },
    .{ .text = "in", .width = 7 },
    .{ .text = "out", .width = 7 },
    .{ .text = "reason", .width = 8 },
    .{ .text = "cache rd", .width = 10 },
    .{ .text = "cache wr", .width = 10 },
};

fn cellsWidth(cells: []const Cell) usize {
    var w: usize = 0;
    for (cells) |cell| w += cell.width;
    return w;
}

fn wideTokensWidth() usize {
    return cellsWidth(&tokens_header_wide);
}

fn composeTokensRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const header: []const Cell = if (limit >= wideTokensWidth()) &tokens_header_wide else &tokens_header_narrow;
    const row = detailRow(p, period);
    var bufs: [5][16]u8 = undefined;
    const values = if (row) |r| [5]u64{
        r.totals.input_tokens,
        r.totals.output_tokens,
        r.totals.reasoning_tokens,
        r.totals.cache_read_tokens,
        r.totals.cache_write_tokens,
    } else null;
    var cells: [6]Cell = undefined;
    cells[0] = .{ .text = period.label(), .width = header[0].width, .left = true };
    for (1..6) |i| {
        cells[i] = .{
            .text = if (values) |v| compact(&bufs[i - 1], v[i - 1]) else "-",
            .width = header[i].width,
        };
    }
    return composeCells(alloc, &cells, .data, "", limit);
}

const perf_header_wide = [_]Cell{
    .{ .text = "perf", .width = 8, .left = true },
    .{ .text = "cache hit", .width = 11 },
    .{ .text = "p90 ttft", .width = 10 },
    .{ .text = "p90 tok/s", .width = 11 },
    .{ .text = "errors", .width = 8 },
};

/// 38 columns, so every perf column shows down to 40-column terminals.
const perf_header_narrow = [_]Cell{
    .{ .text = "perf", .width = 5, .left = true },
    .{ .text = "cache hit", .width = 10 },
    .{ .text = "p90 ttft", .width = 9 },
    .{ .text = "tok/s", .width = 7 },
    .{ .text = "errors", .width = 7 },
};

fn widePerfWidth() usize {
    return cellsWidth(&perf_header_wide);
}

fn composePerfRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const header: []const Cell = if (limit >= widePerfWidth()) &perf_header_wide else &perf_header_narrow;
    const t: ?usage.report.Totals = if (detailRow(p, period)) |r| r.totals else null;
    var hit: [16]u8 = undefined;
    var ttft: [16]u8 = undefined;
    var tps: [16]u8 = undefined;
    var errors: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = period.label(), .width = header[0].width, .left = true },
        .{ .text = optionalPercent(&hit, if (t) |v| v.cacheHitPct() else null), .width = header[1].width },
        .{ .text = duration(&ttft, if (t) |v| v.p90TtftMs() else null), .width = header[2].width },
        .{ .text = if (t) |v| (if (v.p90Tps()) |x| std.mem.print(&tps, "{d:.0}", .{x}) catch "-" else "-") else "-", .width = header[3].width },
        .{ .text = optionalPercent(&errors, if (t) |v| v.errorPct() else null), .width = header[4].width },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

// ------------------------------------------------------------------ codex

const CodexWindow = struct {
    limit: *const usage.codex.Limit,
    window: usage.codex.Window,
};

fn codexUsage(p: Projection) ?usage.codex.Usage {
    const s = p.snapshot orelse return null;
    return s.codex_usage;
}

fn codexWindowCount(p: Projection) usize {
    const u = codexUsage(p) orelse return 0;
    var n: usize = 0;
    for (u.limits) |limit| n += @as(usize, @intFromBool(limit.primary != null)) + @intFromBool(limit.secondary != null);
    return n;
}

/// The `index`-th window: each limit's primary, then its secondary.
fn codexWindowAt(p: Projection, index: usize) ?CodexWindow {
    const u = codexUsage(p) orelse return null;
    var n: usize = 0;
    for (u.limits) |*limit| {
        for ([_]?usage.codex.Window{ limit.primary, limit.secondary }) |maybe| {
            const window = maybe orelse continue;
            if (n == index) return .{ .limit = limit, .window = window };
            n += 1;
        }
    }
    return null;
}

fn codexPlanWidth(p: Projection) usize {
    const u = codexUsage(p) orelse return 10;
    return std.math.clamp(display_width.visibleWidth(u.plan) + 2, 10, 24);
}

fn composeCodexPlanHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const cells = [_]Cell{
        .{ .text = "plan", .width = codexPlanWidth(p), .left = true },
        .{ .text = "credits", .width = 11 },
        .{ .text = "spend limit", .width = 14 },
    };
    return composeCells(alloc, &cells, .header, "", limit);
}

fn composeCodexPlanRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const u = codexUsage(p).?;
    const plan_width = codexPlanWidth(p);
    var plan_buf: [64]u8 = undefined;
    var balance_buf: [64]u8 = undefined;
    const plan = safeText(&plan_buf, u.plan);
    const credits: []const u8 = if (u.credits) |c|
        (if (c.unlimited) "unlimited" else if (c.balance) |b| safeText(&balance_buf, b) else if (c.has_credits) "yes" else "none")
    else
        "-";
    const cells = [_]Cell{
        .{ .text = plan[0..@min(plan.len, plan_width - 1)], .width = plan_width, .left = true },
        .{ .text = credits[0..@min(credits.len, 10)], .width = 11 },
        .{ .text = if (u.spend_limit_reached) "reached" else "not reached", .width = 14 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

/// As wide as the longest limit name, plus room between columns.
fn codexNameWidth(p: Projection) usize {
    var width: usize = "limit".len;
    if (codexUsage(p)) |u| for (u.limits) |l| {
        width = @max(width, display_width.visibleWidth(l.name));
    };
    return @min(width, 32) + 2;
}

fn composeCodexLimitHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const cells = [_]Cell{
        .{ .text = "limit", .width = codexNameWidth(p), .left = true },
        .{ .text = "window", .width = 6 },
        .{ .text = "used", .width = 7 },
        .{ .text = "", .width = 2 },
        .{ .text = "resets", .width = 10, .left = true },
    };
    return composeCells(alloc, &cells, .header, "", limit);
}

fn composeCodexLimitRow(alloc: Allocator, p: Projection, index: usize, limit: usize) !std.ArrayList(u8) {
    const w = codexWindowAt(p, index) orelse return .empty;
    const name_width = codexNameWidth(p);
    var name_buf: [64]u8 = undefined;
    var window_buf: [16]u8 = undefined;
    var used_buf: [16]u8 = undefined;
    var resets_buf: [24]u8 = undefined;
    const name = safeText(&name_buf, w.limit.name);
    const now = p.snapshot.?.now_ms;
    const cells = [_]Cell{
        .{ .text = name[0..@min(name.len, name_width - 2)], .width = name_width, .left = true },
        .{ .text = windowLength(&window_buf, w.window.window_seconds), .width = 6 },
        .{ .text = std.mem.print(&used_buf, "{d:.0}%", .{w.window.used_percent}) catch "-", .width = 7 },
        .{ .text = "", .width = 2 },
        .{ .text = if (w.window.resets_at_ms) |at| resetsIn(&resets_buf, at - now) else "-", .width = 10, .left = true },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

// ------------------------------------------------------------------- grok

fn grokUsage(p: Projection) ?usage.grok.Usage {
    const s = p.snapshot orelse return null;
    return s.grok_usage;
}

const GrokSections = struct {
    note: bool = false,
    limit: bool = false,
    products: usize = 0,
};

fn grokRows(sections: GrokSections) usize {
    var rows: usize = 2 + 2; // heading, blank; plan header and row
    if (sections.note) rows += 2;
    if (sections.limit) rows += 3;
    if (sections.products > 0) rows += 2 + sections.products;
    return rows;
}

/// A team's usage page or missing billing replaces the limit and product
/// tables. A short terminal drops the products; the plan stays.
fn grokSections(p: Projection, visible_rows: usize) GrokSections {
    const u = grokUsage(p) orelse return .{};
    if (grokTeamUrl(u) != null or !u.hasBilling()) return .{ .note = true };
    var sections: GrokSections = .{ .limit = u.used_percent != null, .products = u.products.len };
    if (grokRows(sections) > visible_rows) sections.products = 0;
    return sections;
}

fn grokTeamUrl(u: usage.grok.Usage) ?[]const u8 {
    const s = u.settings orelse return null;
    return s.usage_url;
}

fn composeGrokNote(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const u = grokUsage(p).?;
    var buf: [600]u8 = undefined;
    var url_buf: [512]u8 = undefined;
    const text = if (grokTeamUrl(u)) |url|
        std.mem.print(&buf, "usage is managed by your team: {s}", .{safeText(&url_buf, url)}) catch "usage is managed by your team"
    else
        "no billing data for this plan";
    return row_text.composeTextRow(alloc, text, @intCast(@min(limit, std.math.maxInt(u16))), ui_render.dim_style, 2);
}

/// The Codex limit table's columns, so both plans read alike.
const grok_limit_header = [_]Cell{
    .{ .text = "limit", .width = 7, .left = true },
    .{ .text = "window", .width = 6 },
    .{ .text = "used", .width = 7 },
    .{ .text = "", .width = 2 },
    .{ .text = "resets", .width = 10, .left = true },
};

fn composeGrokLimitRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const u = grokUsage(p).?;
    var used_buf: [16]u8 = undefined;
    var resets_buf: [24]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = "grok", .width = 7, .left = true },
        .{ .text = if (u.period) |kind| switch (kind) {
            .weekly => "7d",
            .monthly => "month",
        } else "-", .width = 6 },
        // Floored, as Grok truncates it.
        .{ .text = std.mem.print(&used_buf, "{d:.0}%", .{@floor(u.used_percent orelse 0)}) catch "-", .width = 7 },
        .{ .text = "", .width = 2 },
        .{ .text = if (u.resets_at_ms) |at| resetsIn(&resets_buf, at - p.snapshot.?.now_ms) else "-", .width = 10, .left = true },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

fn grokProductNameWidth(u: usage.grok.Usage) usize {
    var width: usize = "product".len;
    for (u.products) |product| width = @max(width, display_width.visibleWidth(product.name));
    return @min(width, 24) + 2;
}

fn composeGrokProductHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const cells = [_]Cell{
        .{ .text = "product", .width = grokProductNameWidth(grokUsage(p).?), .left = true },
        .{ .text = "used", .width = 7 },
    };
    return composeCells(alloc, &cells, .header, "", limit);
}

fn composeGrokProductRow(alloc: Allocator, p: Projection, index: usize, limit: usize) !std.ArrayList(u8) {
    const u = grokUsage(p).?;
    if (index >= u.products.len) return .empty;
    const product = u.products[index];
    const name_width = grokProductNameWidth(u);
    var name_buf: [64]u8 = undefined;
    var used_buf: [8]u8 = undefined;
    const name = safeText(&name_buf, product.name);
    const cells = [_]Cell{
        .{ .text = name[0..@min(name.len, name_width - 2)], .width = name_width, .left = true },
        .{ .text = usage.codex.formatShare(&used_buf, product.used_percent), .width = 7 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

fn grokPlanWidth(u: usage.grok.Usage) usize {
    const plan = u.plan() orelse "-";
    return std.math.clamp(display_width.visibleWidth(plan) + 2, 10, 24);
}

/// `$1,250.00` for an amount in US cents.
fn centsText(buf: []u8, cents: i64) []const u8 {
    const magnitude: u64 = @intCast(@max(cents, 0));
    var whole: [24]u8 = undefined;
    return std.mem.print(buf, "${s}.{d:0>2}", .{ grouped(&whole, magnitude / 100), magnitude % 100 }) catch "-";
}

/// `$3.00 of $100.00` when pay-as-you-go has a cap, else `off`. Settings
/// that turn it off win over a leftover cap.
fn grokPayg(buf: *[64]u8, u: usage.grok.Usage) []const u8 {
    const cap = u.on_demand_cap_cents orelse 0;
    const turned_off = if (u.settings) |s| (if (s.on_demand_enabled) |on| !on else false) else false;
    if (cap <= 0 or turned_off) return "off";
    var used_buf: [24]u8 = undefined;
    var cap_buf: [24]u8 = undefined;
    return std.mem.print(buf, "{s} of {s}", .{ centsText(&used_buf, u.on_demand_used_cents orelse 0), centsText(&cap_buf, cap) }) catch "-";
}

/// Header and value share one width, so a narrow terminal drops both.
fn grokPaygWidth(u: usage.grok.Usage) usize {
    var buf: [64]u8 = undefined;
    return @max(display_width.visibleWidth(grokPayg(&buf, u)), "pay as you go".len);
}

fn composeGrokPlanHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const u = grokUsage(p).?;
    const cells = [_]Cell{
        .{ .text = "plan", .width = grokPlanWidth(u), .left = true },
        .{ .text = "credits", .width = 11 },
        .{ .text = "", .width = 3 },
        .{ .text = "pay as you go", .width = grokPaygWidth(u), .left = true },
    };
    return composeCells(alloc, &cells, .header, "", limit);
}

fn composeGrokPlanRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const u = grokUsage(p).?;
    const plan_width = grokPlanWidth(u);
    var plan_buf: [64]u8 = undefined;
    var credits_buf: [24]u8 = undefined;
    var payg_buf: [64]u8 = undefined;
    const plan = safeText(&plan_buf, u.plan() orelse "-");
    const credits: []const u8 = if (u.prepaid_cents) |c| (if (c > 0) centsText(&credits_buf, c) else "none") else "-";
    const payg = grokPayg(&payg_buf, u);
    const cells = [_]Cell{
        .{ .text = plan[0..@min(plan.len, plan_width - 1)], .width = plan_width, .left = true },
        .{ .text = credits, .width = 11 },
        .{ .text = "", .width = 3 },
        .{ .text = payg, .width = grokPaygWidth(u), .left = true },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

// Codex activity: tokens by period, usage by model and by surface, and the
// account's records and habits.

const CodexSpan = enum {
    today,
    days_7,
    month,
    lifetime,

    const all = [_]CodexSpan{ .today, .days_7, .month, .lifetime };

    fn label(self: CodexSpan) []const u8 {
        return switch (self) {
            .today => "today",
            .days_7 => "7d",
            .month => "month",
            .lifetime => "lifetime",
        };
    }
};

const Share = usage.codex.Share;
const max_shares = usage.codex.max_shares;

fn codexProfile(p: Projection) ?usage.codex.Profile {
    const u = codexUsage(p) orelse return null;
    return u.profile;
}

/// Whether Tab has periods to switch: the model and surface tables.
pub fn codexHasPeriods(p: Projection) bool {
    const s = p.snapshot orelse return false;
    return isCodex(p) and s.codexBreakdown() != null;
}

fn modelShares(p: Projection, buf: *[max_shares]Share) []Share {
    const s = p.snapshot orelse return buf[0..0];
    return s.codexModelShares(p.period, buf);
}

fn surfaceShares(p: Projection, buf: *[max_shares]Share) []Share {
    const s = p.snapshot orelse return buf[0..0];
    return s.codexSurfaceShares(p.period, buf);
}

fn hasRecord(profile: usage.codex.Profile) bool {
    return profile.peak_day_tokens != null or profile.longest_turn_seconds != null or
        profile.streak_days != null or profile.best_streak_days != null or profile.chats != null;
}

fn hasHabits(profile: usage.codex.Profile) bool {
    return profile.fast_mode_percent != null or profile.reasoning != null;
}

const CodexSections = struct {
    /// The model table, shown whenever ChatGPT sent a breakdown.
    model_table: bool = false,
    /// Rows reserved for the model list. The same in every period, so Tab
    /// never moves the tables below it.
    model_rows: usize = 0,
    where: bool = false,
    record: bool = false,
    habits: bool = false,
};

/// The most models any period lists, and at least the empty message's row.
fn codexMostModels(p: Projection) usize {
    const s = p.snapshot orelse return 1;
    var buf: [max_shares]Share = undefined;
    var most: usize = 1;
    for (Period.all) |period| most = @max(most, s.codexModelShares(period, &buf).len);
    return most;
}

/// Rows the Codex view takes with `sections`.
fn codexRows(p: Projection, sections: CodexSections) usize {
    var rows: usize = 2 + 2; // heading, blank; plan header and row
    if (codexProfile(p) != null) rows += 1 + CodexSpan.all.len + 1;
    if (sections.model_table) rows += 1 + sections.model_rows + 1;
    if (sections.where) rows += 3;
    if (sections.record) rows += 3;
    if (sections.habits) rows += 3;
    const windows = codexWindowCount(p);
    if (windows > 0) rows += 2 + windows;
    return rows;
}

/// What fits in `visible_rows`, the same in every period. A short terminal
/// loses habits first, then records, then the surface table, then model
/// rows, which then scroll; the plan and its limits stay on screen.
fn codexSections(p: Projection, visible_rows: usize) CodexSections {
    var sections: CodexSections = .{};
    if (p.snapshot) |s| if (s.codexBreakdown() != null) {
        var buf: [max_shares]Share = undefined;
        sections.model_table = true;
        sections.model_rows = codexMostModels(p);
        sections.where = s.codexSurfacesAll(&buf).len > 0;
    };
    if (codexProfile(p)) |profile| {
        sections.record = hasRecord(profile);
        sections.habits = hasHabits(profile);
    }
    while (codexRows(p, sections) > visible_rows) {
        if (sections.habits) {
            sections.habits = false;
        } else if (sections.record) {
            sections.record = false;
        } else if (sections.where) {
            sections.where = false;
        } else if (sections.model_rows > 2) {
            sections.model_rows -= 1;
        } else break;
    }
    return sections;
}

/// The models on screen: all of them when they fit, else a scroll window
/// and one "N more" row in the last reserved row.
const ModelWindow = struct {
    start: usize = 0,
    items: usize = 0,
    more: bool = false,
};

fn codexModelWindow(p: Projection, visible_rows: usize) ModelWindow {
    var buf: [max_shares]Share = undefined;
    const count = modelShares(p, &buf).len;
    const rows = codexSections(p, visible_rows).model_rows;
    if (count <= rows) return .{ .items = count };
    const items = @max(rows -| 1, 1);
    return .{ .start = @min(p.model_window_start, count - items), .items = items, .more = true };
}

const codex_tokens_header = [_]Cell{
    .{ .text = "period", .width = 10, .left = true },
    .{ .text = "tokens", .width = 10 },
};

fn composeCodexTokensRow(alloc: Allocator, p: Projection, span: CodexSpan, limit: usize) !std.ArrayList(u8) {
    const s = p.snapshot.?;
    const value: ?u64 = switch (span) {
        .today => s.codexTokens(.today),
        .days_7 => s.codexTokens(.days_7),
        .month => s.codexTokens(.month),
        .lifetime => codexProfile(p).?.lifetime_tokens,
    };
    var buf: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = span.label(), .width = 10, .left = true },
        .{ .text = if (value) |v| tenths(&buf, v) else "-", .width = 10 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

/// A gap, the speed (`standard`, `fast`) and the share.
const model_tail_width: usize = 2 + 8 + 7;

/// As wide as the longest name in any period and the widest header, so Tab
/// never moves the columns.
fn codexModelNameWidth(p: Projection, limit: usize) usize {
    var width: usize = "model (month)".len;
    if (p.snapshot) |s| {
        var buf: [max_shares]Share = undefined;
        var safe_buf: [64]u8 = undefined;
        for (s.codexModelsAll(&buf)) |m| width = @max(width, display_width.visibleWidth(safeText(&safe_buf, m.name)));
    }
    return @max(@min(width, limit -| model_tail_width), 8);
}

fn composeCodexModelHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    var header_buf: [24]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = modelHeaderText(&header_buf, p.period), .width = codexModelNameWidth(p, limit), .left = true },
        .{ .text = "", .width = 2 },
        .{ .text = "speed", .width = 8, .left = true },
        .{ .text = "share", .width = 7 },
    };
    return composeCells(alloc, &cells, .header, "", limit);
}

fn composeCodexModelLine(alloc: Allocator, p: Projection, slot: usize, visible_rows: usize, limit: usize) !std.ArrayList(u8) {
    var buf: [max_shares]Share = undefined;
    const shares = modelShares(p, &buf);
    if (shares.len == 0) {
        if (slot == 0) return row_text.composeTextRow(alloc, codexEmptyText(p.period), @intCast(@min(limit, std.math.maxInt(u16))), ui_render.dim_style, 2);
        return .empty;
    }
    const window = codexModelWindow(p, visible_rows);
    if (slot < window.items) return composeCodexModelRow(alloc, p, shares[window.start + slot], limit);
    if (slot == window.items and window.more) return composeCodexModelMore(alloc, p, shares, window, limit);
    return .empty;
}

fn composeCodexModelRow(alloc: Allocator, p: Projection, share: Share, limit: usize) !std.ArrayList(u8) {
    const name_width = codexModelNameWidth(p, limit);
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try appendName(alloc, &row, share.name, name_width);
    var speed_buf: [8]u8 = undefined;
    var share_buf: [8]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = "", .width = 2 },
        .{ .text = safeText(&speed_buf, share.speed), .width = 8, .left = true },
        .{ .text = usage.codex.formatShare(&share_buf, share.percent), .width = 7 },
    };
    _ = try appendCells(alloc, &row, &cells, .data, name_width, limit);
    return row;
}

/// The models outside the window, summed. The arrow points to where more
/// rows are: down until the window reaches the end, then up.
fn composeCodexModelMore(alloc: Allocator, p: Projection, shares: []const Share, window: ModelWindow, limit: usize) !std.ArrayList(u8) {
    var rest: f64 = 0;
    for (shares, 0..) |s, i| {
        if (i < window.start or i >= window.start + window.items) rest += s.percent;
    }
    const arrow = if (window.start + window.items < shares.len) "↓" else "↑";
    var label_buf: [32]u8 = undefined;
    var share_buf: [8]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = std.mem.print(&label_buf, "{s} {d} more", .{ arrow, shares.len - window.items }) catch "more", .width = codexModelNameWidth(p, limit), .left = true },
        .{ .text = "", .width = 2 + 8 },
        .{ .text = usage.codex.formatShare(&share_buf, rest), .width = 7 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

fn codexEmptyText(period: Period) []const u8 {
    return switch (period) {
        // ChatGPT reports days late, so an empty period may still fill in.
        .today => "no Codex usage reported today",
        .days_7 => "no Codex usage reported in the last 7 days",
        .month => "no Codex usage reported this month",
    };
}

/// Wide enough for `where (month)`, so Tab never shifts the columns.
const where_label_width: usize = 16;

/// The surface table on one header row and one data row. The columns are
/// every surface over the breakdown, largest first, in every period; a
/// period without a surface reads `-`. A narrow terminal drops the
/// smallest surfaces.
fn composeCodexWhere(alloc: Allocator, p: Projection, kind: Kind, limit: usize) !std.ArrayList(u8) {
    const s = p.snapshot.?;
    var column_buf: [max_shares]Share = undefined;
    const columns = s.codexSurfacesAll(&column_buf);
    var current_buf: [max_shares]Share = undefined;
    const current = surfaceShares(p, &current_buf);
    var label_buf: [24]u8 = undefined;
    var name_bufs: [max_shares][64]u8 = undefined;
    var share_bufs: [max_shares][8]u8 = undefined;
    var cells: [max_shares + 1]Cell = undefined;
    cells[0] = .{
        .text = if (kind == .header) (std.mem.print(&label_buf, "where ({s})", .{p.period.label()}) catch "where") else "",
        .width = where_label_width,
        .left = true,
    };
    for (columns, 0..) |column, i| {
        const name = safeText(&name_bufs[i], column.name);
        const value: []const u8 = if (kind == .header) name else blk: {
            for (current) |c| {
                if (std.mem.eql(u8, c.name, column.name)) break :blk usage.codex.formatShare(&share_bufs[i], c.percent);
            }
            break :blk "-";
        };
        cells[i + 1] = .{ .text = value, .width = @max(display_width.visibleWidth(name), 5) + 3 };
    }
    return composeCells(alloc, cells[0 .. columns.len + 1], kind, "", limit);
}

/// A column that gives way on narrow terminals: lower ranks stay longer.
const Column = struct {
    header: []const u8,
    width: usize,
    left: bool = false,
    rank: u8,
};

const record_columns = [_]Column{
    .{ .header = "record", .width = 12, .left = true, .rank = 0 },
    .{ .header = "peak day", .width = 11, .rank = 1 },
    .{ .header = "longest chat", .width = 15, .rank = 3 },
    .{ .header = "streak", .width = 9, .rank = 2 },
    .{ .header = "best streak", .width = 14, .rank = 5 },
    .{ .header = "chats", .width = 10, .rank = 4 },
};

const habits_columns = [_]Column{
    .{ .header = "habits", .width = 12, .left = true, .rank = 0 },
    .{ .header = "fast mode", .width = 12, .rank = 2 },
    .{ .header = "reasoning", .width = 12, .rank = 1 },
};

const max_columns = 8;

/// Which columns fit in `limit`, by rank, keeping their order. Header and
/// data rows share the answer, so their columns always line up.
fn fitColumns(columns: []const Column, limit: usize, keep: []bool) void {
    @memset(keep, false);
    var used: usize = 0;
    var rank: u8 = 0;
    while (rank < max_columns) : (rank += 1) {
        for (columns, 0..) |c, i| {
            if (c.rank == rank and used + c.width <= limit) {
                keep[i] = true;
                used += c.width;
            }
        }
    }
}

/// The header row when `values` is null, else a data row.
fn composeColumns(alloc: Allocator, columns: []const Column, values: ?[]const []const u8, limit: usize) !std.ArrayList(u8) {
    var keep: [max_columns]bool = undefined;
    fitColumns(columns, limit, keep[0..columns.len]);
    var cells: [max_columns]Cell = undefined;
    var n: usize = 0;
    for (columns, 0..) |c, i| {
        if (!keep[i]) continue;
        cells[n] = .{ .text = if (values) |v| v[i] else c.header, .width = c.width, .left = c.left };
        n += 1;
    }
    return composeCells(alloc, cells[0..n], if (values == null) .header else .data, "", limit);
}

fn composeCodexRecordRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const profile = codexProfile(p).?;
    var peak: [16]u8 = undefined;
    var longest: [24]u8 = undefined;
    var streak: [24]u8 = undefined;
    var best: [24]u8 = undefined;
    var chats: [32]u8 = undefined;
    const values = [_][]const u8{
        "",
        if (profile.peak_day_tokens) |v| tenths(&peak, v) else "-",
        turnLength(&longest, profile.longest_turn_seconds),
        dayCount(&streak, profile.streak_days),
        dayCount(&best, profile.best_streak_days),
        if (profile.chats) |v| grouped(&chats, v) else "-",
    };
    return composeColumns(alloc, &record_columns, &values, limit);
}

fn composeCodexHabitsRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const profile = codexProfile(p).?;
    var fast: [16]u8 = undefined;
    var reasoning: [32]u8 = undefined;
    var effort_buf: [8]u8 = undefined;
    const effort: ?[]const u8 = if (profile.reasoning) |r| safeText(&effort_buf, r[0..@min(r.len, 7)]) else null;
    const values = [_][]const u8{
        "",
        wholePercent(&fast, profile.fast_mode_percent),
        if (effort) |e| (if (profile.reasoning_percent) |pct|
            std.mem.print(&reasoning, "{s} {d:.0}%", .{ e, pct }) catch e
        else
            e) else "-",
    };
    return composeColumns(alloc, &habits_columns, &values, limit);
}

/// `950`, `39.9M`, `401.5M`, `315.7B`: one decimal, as Codex shows tokens.
fn tenths(buf: *[16]u8, value: u64) []const u8 {
    const units = [_]struct { div: u64, suffix: []const u8 }{
        .{ .div = 1_000_000_000_000, .suffix = "T" },
        .{ .div = 1_000_000_000, .suffix = "B" },
        .{ .div = 1_000_000, .suffix = "M" },
        .{ .div = 1_000, .suffix = "K" },
    };
    for (units) |u| {
        if (value >= u.div) {
            const scaled = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(u.div));
            return std.mem.print(buf, "{d:.1}{s}", .{ scaled, u.suffix }) catch "";
        }
    }
    return std.mem.print(buf, "{d}", .{value}) catch "";
}

/// `41m`, `30h 41m`.
fn turnLength(buf: []u8, seconds: ?u64) []const u8 {
    const s = seconds orelse return "-";
    const minutes = s / 60;
    if (minutes < 60) return std.mem.print(buf, "{d}m", .{minutes}) catch "-";
    return std.mem.print(buf, "{d}h {d}m", .{ minutes / 60, minutes % 60 }) catch "-";
}

/// `132d`.
fn dayCount(buf: []u8, days: ?u64) []const u8 {
    const d = days orelse return "-";
    return std.mem.print(buf, "{d}d", .{d}) catch "-";
}

/// `67%`.
fn wholePercent(buf: []u8, value: ?f64) []const u8 {
    const v = value orelse return "-";
    return std.mem.print(buf, "{d:.0}%", .{v}) catch "-";
}

/// `5h`, `7d`, `90m`.
fn windowLength(buf: []u8, seconds: i64) []const u8 {
    const day = 24 * 60 * 60;
    if (seconds >= day and @mod(seconds, day) == 0) return std.mem.print(buf, "{d}d", .{@divFloor(seconds, day)}) catch "-";
    if (seconds >= 3600 and @mod(seconds, 3600) == 0) return std.mem.print(buf, "{d}h", .{@divFloor(seconds, 3600)}) catch "-";
    return std.mem.print(buf, "{d}m", .{@divFloor(seconds + 59, 60)}) catch "-";
}

/// `in 12m`, `in 2h 13m`, `in 3d 4h`, `now`.
fn resetsIn(buf: []u8, ms: i64) []const u8 {
    const minutes = @divFloor(ms + std.time.ms_per_min - 1, std.time.ms_per_min);
    if (minutes <= 0) return "now";
    const m: u64 = @intCast(minutes);
    if (m < 60) return std.mem.print(buf, "in {d}m", .{m}) catch "-";
    if (m < 24 * 60) return std.mem.print(buf, "in {d}h {d}m", .{ m / 60, m % 60 }) catch "-";
    return std.mem.print(buf, "in {d}d {d}h", .{ m / (24 * 60), (m % (24 * 60)) / 60 }) catch "-";
}

// ----------------------------------------------------------------- format

fn shareOf(part: f64, whole: f64) ?f64 {
    if (whole <= 0) return null;
    return part / whole * 100;
}

fn percent(buf: []u8, value: ?f64) []const u8 {
    return optionalPercent(buf, value);
}

fn optionalPercent(buf: []u8, value: ?f64) []const u8 {
    const v = value orelse return "-";
    return std.mem.print(buf, "{d:.1}%", .{v}) catch "-";
}

/// `850ms`, `2.1s`.
fn duration(buf: []u8, ms: ?f64) []const u8 {
    const v = ms orelse return "-";
    if (v < 1000) return std.mem.print(buf, "{d:.0}ms", .{v}) catch "-";
    return std.mem.print(buf, "{d:.1}s", .{v / 1000}) catch "-";
}

/// `$1,234.56`, or four decimals below one dollar.
fn money(buf: *[32]u8, value: f64) []const u8 {
    if (value < 1) return std.mem.print(buf, "${d:.4}", .{value}) catch "";
    const cents: u64 = @intFromFloat(@round(value * 100));
    var whole: [24]u8 = undefined;
    const dollars = grouped(&whole, cents / 100);
    return std.mem.print(buf, "${s}.{d:0>2}", .{ dollars, cents % 100 }) catch "";
}

/// `3,665`.
fn grouped(buf: []u8, value: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const raw = std.mem.print(&digits, "{d}", .{value}) catch return "";
    var len: usize = 0;
    for (raw, 0..) |c, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) {
            buf[len] = ',';
            len += 1;
        }
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// `950`, `12K`, `6.9M`, `1.2B`.
fn compact(buf: *[16]u8, value: u64) []const u8 {
    const units = [_]struct { div: u64, suffix: []const u8 }{
        .{ .div = 1_000_000_000_000, .suffix = "T" },
        .{ .div = 1_000_000_000, .suffix = "B" },
        .{ .div = 1_000_000, .suffix = "M" },
        .{ .div = 1_000, .suffix = "K" },
    };
    for (units) |u| {
        if (value >= u.div) {
            const scaled = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(u.div));
            return if (scaled < 10)
                std.mem.print(buf, "{d:.1}{s}", .{ scaled, u.suffix }) catch ""
            else
                std.mem.print(buf, "{d:.0}{s}", .{ scaled, u.suffix }) catch "";
        }
    }
    return std.mem.print(buf, "{d}", .{value}) catch "";
}

// ---------------------------------------------------------------------------
// Tests: every layout is drawn through the VT emulator at terminal widths
// from 40 to 240 columns and read back from the grid.

const testing = std.testing;
const vt_emulator = @import("../../core/terminal/engine.zig");

const test_now: i64 = 20737 * std.time.ms_per_day + 8 * std.time.ms_per_hour + 16 * std.time.ms_per_min;
const test_widths = [_]u16{ 40, 48, 56, 64, 80, 100, 120, 180, 240 };

fn testRow(model: []const u8, cost: f64, requests: u64, tokens: u64) ModelRow {
    return .{ .model = model, .totals = .{
        .request_count = requests,
        .input_tokens = tokens / 100,
        .output_tokens = tokens / 50,
        .reasoning_tokens = tokens / 60,
        .cache_read_tokens = tokens - tokens / 100 - tokens / 50 - tokens / 20,
        .cache_write_tokens = tokens / 20,
        .total_cost = cost,
        .cache_hit_requests = @as(f64, @floatFromInt(requests)) * 0.954,
        .failed_requests = @as(f64, @floatFromInt(requests)) * 0.004,
        .ttft_weighted = 2100 * @as(f64, @floatFromInt(requests)),
        .ttft_requests = requests,
        .tps_weighted = 58 * @as(f64, @floatFromInt(requests)),
        .tps_requests = requests,
    } };
}

const month_models = [_]ModelRow{
    testRow("anthropic/claude-opus-5.5", 6551.12, 43312, 14_500_000_000),
    testRow("openai/gpt-5.6-luna", 14.10, 5396, 41_000_000),
    testRow("openai/gpt-6.1-sol", 11.02, 640, 29_000_000),
    testRow("google/gemini-3.1-flash-lite-image-preview", 9.80, 212, 3_900_000),
    testRow("anthropic/claude-haiku-4.5", 6.12, 363, 9_100_000),
};

fn sumOf(rows: []const ModelRow) usage.report.Totals {
    var t: usage.report.Totals = .{};
    for (rows) |r| t.add(r.totals);
    return t;
}

fn testView(period: Period, rows: []const ModelRow, budget: bool) !usage.View {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    // Allocate before the arena is copied into the result.
    const models = try arena.allocator().dupe(ModelRow, rows);
    return .{
        .arena = arena,
        .period = period,
        .models = models,
        .totals = sumOf(rows),
        .today_current = true,
        .finished_current = true,
        .fetched_at_ms = test_now - 2 * std.time.ms_per_min,
        .budget = if (budget) .{ .limit = 31600, .spent = 6596.55, .period = .monthly } else null,
    };
}

fn testSnapshot(status: usage.Status, budget: bool, month: []const ModelRow) !usage.Snapshot {
    return .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .views = .{
            try testView(.today, month[0..@min(month.len, 3)], budget),
            try testView(.days_7, month[0..@min(month.len, 4)], budget),
            try testView(.month, month, budget),
        },
        .status = status,
        .label = "acme-design-tools-platform (fx login)",
        .now_ms = test_now,
    };
}

/// Draws the whole dashboard into a VT grid of `width` columns and returns
/// every row's trimmed text, one string per row.
const Screen = struct {
    lines: [max_lines][]u8 = undefined,
    count: usize = 0,

    fn deinit(self: *Screen) void {
        for (self.lines[0..self.count]) |line| testing.allocator.free(line);
    }

    fn row(self: *const Screen, index: usize) []const u8 {
        return self.lines[index];
    }

    fn find(self: *const Screen, needle: []const u8) ?usize {
        for (self.lines[0..self.count], 0..) |line, i| {
            if (std.mem.find(u8, line, needle) != null) return i;
        }
        return null;
    }

    fn widest(self: *const Screen) usize {
        return self.widestFrom(0);
    }

    fn widestFrom(self: *const Screen, first: usize) usize {
        var w: usize = 0;
        for (self.lines[first..self.count]) |line| w = @max(w, display_width.visibleWidth(line));
        return w;
    }
};

fn draw(p: Projection, width: u16, visible_rows: u16) !Screen {
    const alloc = testing.allocator;
    const rows: u16 = @intCast(@min(desiredRowCount(p), visible_rows));
    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        var r = try composeRow(alloc, p, index, rows, width);
        defer r.deinit(alloc);
        // A row never passes the terminal width, or the VT would wrap it.
        try testing.expect(display_width.visibleWidthIgnoringAnsi(r.items) <= width);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{index + 1}));
        try grid.feed(r.items);
    }
    var screen: Screen = .{};
    errdefer screen.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    index = 0;
    while (index < rows) : (index += 1) {
        text.clearRetainingCapacity();
        try grid.rowTextTrimmed(index + 1, &text);
        screen.lines[screen.count] = try alloc.dupe(u8, text.items);
        screen.count += 1;
    }
    return screen;
}

/// The column where `needle` ends in `line`, for right-edge alignment.
fn endColumn(line: []const u8, needle: []const u8) ?usize {
    const at = std.mem.find(u8, line, needle) orelse return null;
    return display_width.visibleWidth(line[0 .. at + needle.len]);
}

test "the df view lines its numbers up under the headers at every width" {
    var snapshot = try testSnapshot(.ready, true, &month_models);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        // The label on the left, the freshness in the right corner.
        try testing.expect(std.mem.startsWith(u8, screen.row(0), "usage: acme-de"));
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));
        try testing.expectEqual(@as(usize, width), display_width.visibleWidth(screen.row(0)));
        try testing.expectEqual(width >= 61, std.mem.find(u8, screen.row(0), "acme-design-tools-platform (fx login)") != null);

        // Period table: numbers end where their headers end.
        try testing.expectEqualStrings("period        spent  requests  tokens", screen.row(2));
        const spent_end = endColumn(screen.row(2), "spent").?;
        try testing.expectEqual(spent_end, endColumn(screen.row(3), "$6,576.24").?);
        try testing.expectEqual(spent_end, endColumn(screen.row(5), "$6,592.16").?);
        try testing.expectEqual(endColumn(screen.row(2), "requests").?, endColumn(screen.row(5), "49,923").?);
        try testing.expect(std.mem.startsWith(u8, screen.row(4), "7d "));

        // Budget table, with fewer columns as the terminal narrows.
        const budget = screen.find("budget").?;
        try testing.expectEqual(endColumn(screen.row(budget), "use%").?, endColumn(screen.row(budget + 1), "21%").?);
        try testing.expectEqual(width >= 55, std.mem.find(u8, screen.row(budget + 1), "nov 1") != null);
        try testing.expectEqual(width >= 47, std.mem.find(u8, screen.row(budget), "size") != null);

        // Model table: the current model carries the marker.
        const header = screen.find("model (month)").?;
        try testing.expect(std.mem.startsWith(u8, screen.row(header + 1), "❯ anthropi"));
        try testing.expect(std.mem.startsWith(u8, screen.row(header + 2), "  openai/g"));
        // Names stay whole once the longest fits beside spent and requests.
        try testing.expectEqual(width >= gutter + 42 + modelColumnsWidth(.small), screen.find("google/gemini-3.1-flash-lite-image-preview") != null);
        const model_spent = endColumn(screen.row(header), "spent").?;
        try testing.expectEqual(model_spent, endColumn(screen.row(header + 1), "$6,551.12").?);
        try testing.expectEqual(model_spent, endColumn(screen.row(header + 2), "$14.10").?);
    }
}

test "the df view stays content-sized on wide terminals and drops columns on narrow ones" {
    var snapshot = try testSnapshot(.ready, true, &month_models);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };

    // The longest name (42 columns) plus the four number columns.
    const content_width = gutter + 42 + modelColumnsWidth(.full);
    var at_100 = try draw(p, 100, 40);
    defer at_100.deinit();
    var at_240 = try draw(p, 240, 40);
    defer at_240.deinit();
    // Only the heading spans the terminal, to put the status in the corner.
    try testing.expectEqual(content_width, at_100.widestFrom(1));
    try testing.expectEqual(content_width, at_240.widestFrom(1));
    for (1..at_100.count) |i| try testing.expectEqualStrings(at_100.row(i), at_240.row(i));
    try testing.expect(std.mem.endsWith(u8, at_240.row(0), "updated 2m ago"));
    try testing.expectEqual(@as(usize, 240), display_width.visibleWidth(at_240.row(0)));

    // 80 columns: no room for share beside a 42-column name. 72: tokens go
    // too. The names stay whole in both.
    var at_80 = try draw(p, 80, 40);
    defer at_80.deinit();
    const h80 = at_80.row(at_80.find("model (month)").?);
    try testing.expect(std.mem.find(u8, h80, "share") == null and std.mem.find(u8, h80, "tokens") != null);
    try testing.expect(at_80.find("google/gemini-3.1-flash-lite-image-preview") != null);
    var at_72 = try draw(p, 72, 40);
    defer at_72.deinit();
    const h72 = at_72.row(at_72.find("model (month)").?);
    try testing.expect(std.mem.find(u8, h72, "tokens") == null and std.mem.find(u8, h72, "requests") != null);
    try testing.expect(at_72.find("google/gemini-3.1-flash-lite-image-preview") != null);
    // 40 columns: the long name is clipped in the middle, never wrapped.
    var at_40 = try draw(p, 40, 40);
    defer at_40.deinit();
    try testing.expect(at_40.find("google/gemini-3.1-flash-lite-image-preview") == null);
    try testing.expect(at_40.find("google") != null);
    try testing.expect(at_40.widest() <= 40);
}

test "the detail screen shows one model across today, 7d and month" {
    var snapshot = try testSnapshot(.ready, true, &month_models);
    defer snapshot.deinit();
    // gpt-6.1-sol is listed today; gemini only in 7d and month.
    const p: Projection = .{ .active = true, .snapshot = &snapshot, .detail = true, .selected_model = 3 };
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        try testing.expectEqual(@as(usize, detail_rows), screen.count);
        try testing.expect(std.mem.find(u8, screen.row(0), "model 4 of 5") != null or width < 80);
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));
        if (width >= cellsWidth(&detail_period_header)) {
            try testing.expectEqualStrings("period        spent   share  requests  tokens", screen.row(2));
        } else {
            try testing.expect(std.mem.startsWith(u8, screen.row(2), "period        spent   share  requests"));
        }
        // Not used today: dashes, aligned under the headers.
        try testing.expect(std.mem.startsWith(u8, screen.row(3), "today"));
        try testing.expectEqual(endColumn(screen.row(2), "spent").?, endColumn(screen.row(3), "-").?);
        try testing.expectEqual(endColumn(screen.row(2), "spent").?, endColumn(screen.row(5), "$9.80").?);

        const tokens = screen.find("tokens ").?;
        const wide = width >= 62;
        try testing.expectEqual(wide, std.mem.find(u8, screen.row(tokens), "cache write") != null);
        // The narrow token table needs 48 columns for its last column.
        try testing.expectEqual(!wide and width >= cellsWidth(&tokens_header_narrow), std.mem.find(u8, screen.row(tokens), "cache wr") != null and std.mem.find(u8, screen.row(tokens), "cache write") == null);
        const perf = screen.find("perf").?;
        try testing.expectEqual(endColumn(screen.row(perf), "cache hit").?, endColumn(screen.row(perf + 3), "95.4%").?);
        try testing.expect(std.mem.find(u8, screen.row(perf + 3), "2.1s") != null);
        try testing.expect(std.mem.find(u8, screen.row(perf + 3), "0.4%") != null);
        try testing.expect(screen.widest() <= width);
    }
}

test "the model list scrolls and sums what is below the window" {
    var many: [25]ModelRow = undefined;
    var names: [25][16]u8 = undefined;
    for (&many, 0..) |*row, i| {
        row.* = testRow(std.mem.print(&names[i], "provider/m{d:0>2}", .{i}) catch unreachable, @floatFromInt(100 - i), 10, 1000);
    }
    var snapshot = try testSnapshot(.ready, false, &many);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expectEqual(tableRows(p) + max_model_rows + 1, desiredRowCount(p));
    var screen = try draw(p, 80, 40);
    defer screen.deinit();
    try testing.expect(screen.find("provider/m09") != null);
    try testing.expect(screen.find("provider/m10") == null);
    // m10 through m24: 15 models, $90 down to $76.
    const more = screen.row(screen.find("15 more").?);
    try testing.expect(std.mem.find(u8, more, "$1,245.00") != null);

    // Fewer rows than wanted: the window shrinks, the "more" line stays.
    var short = try draw(p, 80, @intCast(tableRows(p) + 4));
    defer short.deinit();
    try testing.expect(short.find("provider/m02") != null and short.find("provider/m03") == null);
    try testing.expect(short.find("22 more") != null);
}

test "states without numbers say so in one line" {
    var unavailable = try testSnapshot(.{ .unavailable = .no_gateway_sign_in }, false, &.{});
    defer unavailable.deinit();
    var screen = try draw(.{ .active = true, .snapshot = &unavailable }, 80, 40);
    defer screen.deinit();
    try testing.expectEqualStrings("usage: not signed in to AI Gateway", screen.row(0));
    try testing.expectEqualStrings("  (use /login, or set AI_GATEWAY_API_KEY)", screen.row(2));

    var other = try testSnapshot(.{ .unavailable = .unsupported_provider }, false, &.{});
    defer other.deinit();
    var other_screen = try draw(.{ .active = true, .snapshot = &other }, 80, 40);
    defer other_screen.deinit();
    try testing.expectEqualStrings("usage: this provider's usage isn't shown yet", other_screen.row(0));
    try testing.expectEqualStrings("  (use /provider and pick AI Gateway to see AI Gateway usage)", other_screen.row(2));

    var fetching = try testSnapshot(.fetching, false, &.{});
    defer fetching.deinit();
    for (&fetching.views) |*v| {
        v.today_current = false;
        v.finished_current = false;
    }
    var first = try draw(.{ .active = true, .snapshot = &fetching }, 80, 40);
    defer first.deinit();
    try testing.expect(std.mem.startsWith(u8, first.row(0), "usage: acme-design-tools-platform (fx login)  "));
    try testing.expect(std.mem.endsWith(u8, first.row(0), "fetching…"));
    try testing.expectEqual(@as(usize, 80), display_width.visibleWidth(first.row(0)));

    // Signed in, numbers fetched, nothing used today.
    var empty_today = try testSnapshot(.ready, false, &month_models);
    defer empty_today.deinit();
    empty_today.views[0].deinit();
    empty_today.views[0] = try testView(.today, &.{}, false);
    var today = try draw(.{ .active = true, .snapshot = &empty_today, .period = .today }, 80, 40);
    defer today.deinit();
    try testing.expect(today.find("no usage today (UTC)") != null);
    try testing.expect(std.mem.startsWith(u8, today.row(3), "today       $0.0000"));
}

test "the current model is bold and colorless in every theme" {
    var snapshot = try testSnapshot(.ready, false, &month_models);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    const alloc = testing.allocator;
    var row = try composeRow(alloc, p, @intCast(tableRows(p)), 40, 120);
    defer row.deinit(alloc);
    try testing.expect(std.mem.startsWith(u8, row.items, ui_render.bold_style ++ "❯ "));
    // No foreground or background color code anywhere in the row.
    try testing.expect(std.mem.find(u8, row.items, "[3") == null);
    try testing.expect(std.mem.find(u8, row.items, "[4") == null);
    try testing.expect(std.mem.find(u8, row.items, ";3") == null);
}

test "network text cannot inject terminal controls" {
    const evil = [_]ModelRow{testRow("evil/\x1b[2Jmodel", 1, 1, 1)};
    var snapshot = try testSnapshot(.ready, false, &evil);
    defer snapshot.deinit();
    const alloc = testing.allocator;
    var row = try composeRow(alloc, .{ .active = true, .snapshot = &snapshot }, @intCast(tableRows(.{ .active = true, .snapshot = &snapshot })), 40, 80);
    defer row.deinit(alloc);
    try testing.expect(std.mem.find(u8, row.items, "\x1b[2J") == null);
    try testing.expect(std.mem.find(u8, row.items, "evil/?[2Jmodel") != null);
}

test "network text cannot reorder or hide characters on the terminal" {
    const alloc = testing.allocator;
    const names = [_][]const u8{ "evil/\u{9b}31mred", "evil/\u{202e}edoc", "evil/\u{200b}hidden", "evil/\xff\xfebad" };
    for (names) |name| {
        const rows = [_]ModelRow{testRow(name, 1, 1, 1)};
        var snapshot = try testSnapshot(.ready, false, &rows);
        defer snapshot.deinit();
        const p: Projection = .{ .active = true, .snapshot = &snapshot };
        var row = try composeRow(alloc, p, @intCast(tableRows(p)), 40, 80);
        defer row.deinit(alloc);
        for ([_][]const u8{ "\u{9b}", "\u{202e}", "\u{200b}", "\xff", "\xfe" }) |raw| {
            try testing.expect(std.mem.find(u8, row.items, raw) == null);
        }
        try testing.expect(std.mem.find(u8, row.items, "evil/?") != null);
    }
}

test "safe text cuts only between characters" {
    var three: [3]u8 = undefined;
    try testing.expectEqualStrings("ab", safeText(&three, "ab\u{e9}"));
    var four: [4]u8 = undefined;
    try testing.expectEqualStrings("ab\u{e9}", safeText(&four, "ab\u{e9}"));
    try testing.expectEqualStrings("a?b", safeText(&four, "a\u{202e}b"));
}

test "relative times" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("just now", agoText(&buf, 59 * std.time.ms_per_s));
    try testing.expectEqualStrings("2m ago", agoText(&buf, 2 * std.time.ms_per_min));
    try testing.expectEqualStrings("3h ago", agoText(&buf, 3 * std.time.ms_per_hour + 5));
    try testing.expectEqualStrings("2d ago", agoText(&buf, 2 * std.time.ms_per_day));
    try testing.expectEqualStrings("just now", agoText(&buf, -5));
}

fn codexSnapshot(status: usage.Status, value: ?usage.codex.Usage) !usage.Snapshot {
    var snapshot = try testSnapshot(status, false, &.{});
    snapshot.label = "codex (ChatGPT)";
    snapshot.scope = .codex;
    snapshot.codex_usage = value;
    snapshot.codex_at_ms = test_now - 2 * std.time.ms_per_min;
    return snapshot;
}

test "a Codex plan without activity or limit windows shows only the plan" {
    const business: usage.codex.Usage = .{
        .plan = "business",
        .credits = .{ .has_credits = true, .unlimited = true },
    };
    var snapshot = try codexSnapshot(.ready, business);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expect(showsTables(p) and isCodex(p));
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        try testing.expectEqual(@as(usize, 4), screen.count);
        try testing.expectEqualStrings("usage: codex (ChatGPT)", screen.row(0)[0.."usage: codex (ChatGPT)".len]);
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));
        try testing.expectEqualStrings("plan          credits   spend limit", screen.row(2));
        try testing.expectEqualStrings("business    unlimited   not reached", screen.row(3));
        try testing.expect(screen.widest() <= width);
    }
}

test "a Codex plan's windows line up under their headers at every width" {
    const plus: usage.codex.Usage = .{
        .plan = "plus",
        .limits = &.{
            .{
                .name = "codex",
                .primary = .{ .used_percent = 42, .window_seconds = 5 * 3600, .resets_at_ms = test_now + (2 * 60 + 13) * std.time.ms_per_min },
                .secondary = .{ .used_percent = 18, .window_seconds = 7 * 86400, .resets_at_ms = test_now + (3 * 24 + 4) * std.time.ms_per_hour },
            },
            .{
                .name = "code review",
                .reached = true,
                .primary = .{ .used_percent = 100, .window_seconds = 7 * 86400, .resets_at_ms = test_now - 5 },
            },
        },
        .credits = .{ .has_credits = false, .unlimited = false },
        .spend_limit_reached = true,
    };
    var snapshot = try codexSnapshot(.ready, plus);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        try testing.expectEqual(@as(usize, 9), screen.count);
        try testing.expectEqualStrings("plus             none       reached", screen.row(3));
        const header = screen.row(5);
        try testing.expectEqualStrings("limit        window   used  resets", header);
        try testing.expectEqualStrings("codex            5h    42%  in 2h 13m", screen.row(6));
        try testing.expectEqualStrings("codex            7d    18%  in 3d 4h", screen.row(7));
        try testing.expectEqualStrings("code review      7d   100%  now", screen.row(8));
        const window_end = endColumn(header, "window").?;
        try testing.expectEqual(window_end, endColumn(screen.row(6), " 5h").?);
        try testing.expectEqual(window_end, endColumn(screen.row(7), " 7d").?);
        try testing.expectEqual(window_end, endColumn(screen.row(8), " 7d").?);
        try testing.expectEqual(endColumn(header, "used").?, endColumn(screen.row(6), "42%").?);
        try testing.expect(screen.widest() <= width);
    }
}

const test_profile: usage.codex.Profile = .{
    .name = "samdoe",
    .as_of_day = 20737,
    .lifetime_tokens = 315_686_778_511,
    .peak_day_tokens = 11_594_630_891,
    .longest_turn_seconds = 110_473,
    .streak_days = 132,
    .best_streak_days = 132,
    .chats = 11_374,
    .fast_mode_percent = 66.54,
    .reasoning = "xhigh",
    .reasoning_percent = 85.06,
    .days = &.{
        .{ .day = 20736, .tokens = 52_293_426 },
        .{ .day = 20737, .tokens = 39_877_412 },
    },
};

/// Yesterday: nine model and speed pairs, so the month lists six and sums
/// three; today: two models and a sliver.
const test_breakdown: usage.codex.Breakdown = .{ .days = &.{
    .{
        .day = 20736,
        .models = &.{
            .{ .model = "gpt-6-astra", .speed = "fast", .value = 20 },
            .{ .model = "gpt-6.1-sol", .speed = "standard", .value = 1 },
            .{ .model = "gpt-5.6-luna", .speed = "standard", .value = 1 },
            .{ .model = "gpt-5.6-sol", .speed = "standard", .value = 1 },
            .{ .model = "gpt-6-sol", .speed = "standard", .value = 1 },
            .{ .model = "gpt-6-astra", .speed = "standard", .value = 1 },
            .{ .model = "gpt-5.6-luna", .speed = "fast", .value = 1 },
        },
        .surfaces = &.{.{ .surface = "cli", .value = 26 }},
    },
    .{
        .day = 20737,
        .models = &.{
            .{ .model = "gpt-6.1-sol", .speed = "fast", .value = 10 },
            .{ .model = "gpt-6.1-sol", .speed = "standard", .value = 7 },
            .{ .model = "gpt-6-luna", .speed = "standard", .value = 0.005 },
        },
        .surfaces = &.{ .{ .surface = "desktop_app", .value = 10 }, .{ .surface = "cli", .value = 7.005 } },
    },
} };

const test_business: usage.codex.Usage = .{
    .plan = "business",
    .credits = .{ .has_credits = true, .unlimited = true },
    .profile = test_profile,
    .breakdown = test_breakdown,
};

/// The visible column where `needle` starts.
fn startColumn(line: []const u8, needle: []const u8) ?usize {
    const at = std.mem.find(u8, line, needle) orelse return null;
    return display_width.visibleWidth(line[0..at]);
}

/// Like `endColumn`, for the last occurrence.
fn lastEndColumn(line: []const u8, needle: []const u8) ?usize {
    const at = std.mem.findLast(u8, line, needle) orelse return null;
    return display_width.visibleWidth(line[0 .. at + needle.len]);
}

test "the Codex view lines up under its headers at every width" {
    var snapshot = try codexSnapshot(.ready, test_business);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expect(codexHasPeriods(p));
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        try testing.expectEqual(@as(usize, 30), screen.count);
        // The name shortens before the status drops on narrow terminals.
        const full_heading = "usage: codex (ChatGPT), samdoe";
        try testing.expect(std.mem.startsWith(u8, screen.row(0), if (width >= full_heading.len + 2 + "updated 2m ago".len) full_heading else "usage: codex"));
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));
        try testing.expectEqualStrings("period        tokens", screen.row(2));
        try testing.expectEqualStrings("today          39.9M", screen.row(3));
        try testing.expectEqualStrings("lifetime      315.7B", screen.row(6));

        // Models: every one listed, largest first, ties by name.
        const models = screen.row(8);
        try testing.expect(std.mem.startsWith(u8, models, "model (month)"));
        const expected = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "gpt-6-astra", "fast", "46.5%" },
            .{ "gpt-6.1-sol", "fast", "23.3%" },
            .{ "gpt-6.1-sol", "standard", "18.6%" },
            .{ "gpt-5.6-luna", "fast", "2.3%" },
            .{ "gpt-5.6-luna", "standard", "2.3%" },
            .{ "gpt-5.6-sol", "standard", "2.3%" },
            .{ "gpt-6-astra", "standard", "2.3%" },
            .{ "gpt-6-sol", "standard", "2.3%" },
            .{ "gpt-6-luna", "standard", "<0.1%" },
        };
        for (expected, 9..) |e, i| {
            const row = screen.row(i);
            try testing.expect(std.mem.startsWith(u8, row, e[0]));
            try testing.expectEqual(startColumn(models, "speed").?, startColumn(row, e[1]).?);
            try testing.expectEqual(endColumn(models, "share").?, endColumn(row, e[2]).?);
        }
        try testing.expect(screen.find("more") == null);

        // Surfaces: one row, under their names.
        const where = screen.row(19);
        try testing.expect(std.mem.startsWith(u8, where, "where (month)"));
        try testing.expectEqual(endColumn(where, "cli").?, endColumn(screen.row(20), "76.7%").?);
        try testing.expectEqual(endColumn(where, "desktop app").?, endColumn(screen.row(20), "23.3%").?);

        const record = screen.row(22);
        try testing.expect(std.mem.startsWith(u8, record, "record"));
        try testing.expectEqual(endColumn(record, "peak day").?, endColumn(screen.row(23), "11.6B").?);
        try testing.expectEqual(endColumn(record, "streak").?, endColumn(screen.row(23), "132d").?);
        if (width >= 71) {
            try testing.expectEqual(endColumn(record, "longest chat").?, endColumn(screen.row(23), "30h 41m").?);
            try testing.expectEqual(endColumn(record, "best streak").?, lastEndColumn(screen.row(23), "132d").?);
            try testing.expectEqual(endColumn(record, "chats").?, endColumn(screen.row(23), "11,374").?);
        } else {
            try testing.expect(std.mem.find(u8, record, "best streak") == null);
        }

        const habits = screen.row(25);
        try testing.expectEqual(endColumn(habits, "fast mode").?, endColumn(screen.row(26), "67%").?);
        try testing.expectEqual(endColumn(habits, "reasoning").?, endColumn(screen.row(26), "xhigh 85%").?);
        try testing.expect(std.mem.find(u8, habits, "skill") == null);
        try testing.expect(screen.find("top (all time)") == null);

        try testing.expectEqualStrings("plan          credits   spend limit", screen.row(28));
        try testing.expectEqualStrings("business    unlimited   not reached", screen.row(29));
        try testing.expect(screen.widest() <= width);
    }
}

test "Tab changes the Codex model and surface numbers without moving any row or column" {
    var snapshot = try codexSnapshot(.ready, test_business);
    defer snapshot.deinit();
    var month = try draw(.{ .active = true, .snapshot = &snapshot }, 80, 40);
    defer month.deinit();
    for ([_]Period{ .today, .days_7 }) |period| {
        var screen = try draw(.{ .active = true, .period = period, .snapshot = &snapshot }, 80, 40);
        defer screen.deinit();
        try testing.expectEqual(month.count, screen.count);
        // Every table starts on the same row, and the columns stay put.
        for ([_][]const u8{ "where (", "record", "habits", "plan" }) |table| {
            try testing.expectEqual(month.find(table).?, screen.find(table).?);
        }
        try testing.expectEqual(startColumn(month.row(8), "speed").?, startColumn(screen.row(8), "speed").?);
        try testing.expectEqual(endColumn(month.row(19), "desktop app").?, endColumn(screen.row(19), "desktop app").?);
        try testing.expectEqualStrings("today          39.9M", screen.row(3));
    }

    var today = try draw(.{ .active = true, .period = .today, .snapshot = &snapshot }, 80, 40);
    defer today.deinit();
    const models = today.row(8);
    try testing.expect(std.mem.startsWith(u8, models, "model (today)"));
    try testing.expect(std.mem.startsWith(u8, today.row(9), "gpt-6.1-sol"));
    try testing.expectEqual(endColumn(models, "share").?, endColumn(today.row(9), "58.8%").?);
    try testing.expectEqual(endColumn(models, "share").?, endColumn(today.row(10), "41.2%").?);
    try testing.expect(std.mem.startsWith(u8, today.row(11), "gpt-6-luna"));
    try testing.expectEqual(endColumn(models, "share").?, endColumn(today.row(11), "<0.1%").?);
    // The rest of the reserved rows stay blank.
    for (12..18) |i| try testing.expectEqualStrings("", today.row(i));
    // The surface columns keep the month's order; today's numbers fill them.
    const where = today.row(19);
    try testing.expect(std.mem.startsWith(u8, where, "where (today)"));
    try testing.expect(startColumn(where, "cli").? < startColumn(where, "desktop app").?);
    try testing.expectEqual(endColumn(where, "cli").?, endColumn(today.row(20), "41.2%").?);
    try testing.expectEqual(endColumn(where, "desktop app").?, endColumn(today.row(20), "58.8%").?);
}

test "a Codex period without usage says so and keeps its rows" {
    const yesterday_only: usage.codex.Usage = .{
        .plan = "business",
        .profile = test_profile,
        .breakdown = .{ .days = test_breakdown.days[0..1] },
    };
    var snapshot = try codexSnapshot(.ready, yesterday_only);
    defer snapshot.deinit();
    var month = try draw(.{ .active = true, .snapshot = &snapshot }, 80, 40);
    defer month.deinit();
    var screen = try draw(.{ .active = true, .period = .today, .snapshot = &snapshot }, 80, 40);
    defer screen.deinit();
    try testing.expectEqual(month.count, screen.count);
    try testing.expect(std.mem.startsWith(u8, screen.row(8), "model (today)"));
    try testing.expectEqualStrings("  no Codex usage reported today", screen.row(9));
    for (10..16) |i| try testing.expectEqualStrings("", screen.row(i));
    const where = screen.find("where (").?;
    try testing.expectEqual(month.find("where (").?, where);
    try testing.expectEqual(endColumn(screen.row(where), "cli").?, endColumn(screen.row(where + 1), "-").?);
}

test "a short Codex terminal drops habits, records, surfaces, then scrolls the models, never the plan" {
    var snapshot = try codexSnapshot(.ready, test_business);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expectEqual(@as(usize, 30), desiredRowCount(p));
    const plan_row = "business    unlimited   not reached";

    var no_habits = try draw(p, 80, 27);
    defer no_habits.deinit();
    try testing.expect(no_habits.find("habits") == null and no_habits.find("record") != null);
    try testing.expectEqualStrings(plan_row, no_habits.row(26));

    var no_record = try draw(p, 80, 24);
    defer no_record.deinit();
    try testing.expect(no_record.find("record") == null and no_record.find("where (") != null);
    try testing.expectEqualStrings(plan_row, no_record.row(23));

    // Every model still fits once the surfaces go.
    var no_where = try draw(p, 80, 21);
    defer no_where.deinit();
    try testing.expect(no_where.find("where (") == null and no_where.find("more") == null);
    try testing.expectEqualStrings(plan_row, no_where.row(20));

    // Three rows left: two models and a row pointing down to the rest.
    var scrolls = try draw(p, 80, 15);
    defer scrolls.deinit();
    try testing.expectEqual(@as(usize, 2), visibleModelItems(p, 15));
    try testing.expect(std.mem.startsWith(u8, scrolls.row(9), "gpt-6-astra"));
    try testing.expect(std.mem.startsWith(u8, scrolls.row(10), "gpt-6.1-sol"));
    try testing.expect(std.mem.startsWith(u8, scrolls.row(11), "↓ 7 more"));
    try testing.expectEqualStrings(plan_row, scrolls.row(14));

    // Scrolled to the end, the row points back up; a window past the end is
    // pulled back.
    var bottom = try draw(.{ .active = true, .model_window_start = 40, .snapshot = &snapshot }, 80, 15);
    defer bottom.deinit();
    try testing.expect(std.mem.startsWith(u8, bottom.row(9), "gpt-6-sol"));
    try testing.expect(std.mem.startsWith(u8, bottom.row(10), "gpt-6-luna"));
    try testing.expect(std.mem.startsWith(u8, bottom.row(11), "↑ 7 more"));

    // Today's three models fit the same three rows: nothing moves.
    var today = try draw(.{ .active = true, .period = .today, .snapshot = &snapshot }, 80, 15);
    defer today.deinit();
    try testing.expect(today.find("more") == null);
    try testing.expectEqualStrings(plan_row, today.row(14));
}

fn grokSnapshot(status: usage.Status, value: ?usage.grok.Usage) !usage.Snapshot {
    var snapshot = try testSnapshot(status, false, &.{});
    snapshot.label = "grok (xAI)";
    snapshot.scope = .grok;
    snapshot.grok_usage = value;
    snapshot.grok_at_ms = test_now - 2 * std.time.ms_per_min;
    return snapshot;
}

const test_grok: usage.grok.Usage = .{
    .used_percent = 42.7,
    .period = .weekly,
    .resets_at_ms = test_now + 3 * std.time.ms_per_day + 4 * std.time.ms_per_hour,
    .products = &.{ .{ .name = "grok build", .used_percent = 61.2 }, .{ .name = "chat", .used_percent = 3 } },
    .prepaid_cents = 1250,
    .on_demand_used_cents = 300,
    .on_demand_cap_cents = 10000,
    .settings = .{ .plan = "SuperGrok Heavy", .on_demand_enabled = true },
};

test "a Grok plan shows its period's use, products, credits and pay-as-you-go" {
    var snapshot = try grokSnapshot(.ready, test_grok);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expect(showsTables(p) and isGrok(p) and isPlan(p) and !isCodex(p));
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        try testing.expectEqual(@as(usize, 11), screen.count);
        try testing.expect(std.mem.startsWith(u8, screen.row(0), "usage: grok (xAI)"));
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));

        // The limit: the week, floored as Grok reports it, and its reset.
        const limit = screen.row(2);
        try testing.expect(std.mem.startsWith(u8, limit, "limit"));
        const row = screen.row(3);
        try testing.expect(std.mem.startsWith(u8, row, "grok"));
        try testing.expectEqual(endColumn(limit, "window").?, endColumn(row, "7d").?);
        try testing.expectEqual(endColumn(limit, "used").?, endColumn(row, "42%").?);
        try testing.expectEqual(startColumn(limit, "resets").?, startColumn(row, "in 3d 4h").?);

        const products = screen.row(5);
        try testing.expect(std.mem.startsWith(u8, products, "product"));
        try testing.expect(std.mem.startsWith(u8, screen.row(6), "grok build"));
        try testing.expectEqual(endColumn(products, "used").?, endColumn(screen.row(6), "61.2%").?);
        try testing.expectEqual(endColumn(products, "used").?, endColumn(screen.row(7), "3.0%").?);

        const plan = screen.row(9);
        try testing.expect(std.mem.startsWith(u8, plan, "plan"));
        try testing.expect(std.mem.startsWith(u8, screen.row(10), "SuperGrok Heavy"));
        try testing.expectEqual(endColumn(plan, "credits").?, endColumn(screen.row(10), "$12.50").?);
        // Pay-as-you-go needs 47 columns here; narrower drops header and
        // value together.
        if (width >= 47) {
            try testing.expectEqual(startColumn(plan, "pay as you go").?, startColumn(screen.row(10), "$3.00 of $100.00").?);
        } else {
            try testing.expect(std.mem.find(u8, plan, "pay as you go") == null);
            try testing.expect(std.mem.find(u8, screen.row(10), "$3.00") == null);
        }
    }
}

test "a Grok plan without billing data or managed by a team says so instead" {
    const empty: usage.grok.Usage = .{ .settings = .{ .plan = "X Premium+" } };
    var none = try grokSnapshot(.ready, empty);
    defer none.deinit();
    var none_screen = try draw(.{ .active = true, .snapshot = &none }, 80, 40);
    defer none_screen.deinit();
    try testing.expectEqual(@as(usize, 6), none_screen.count);
    try testing.expectEqualStrings("  no billing data for this plan", none_screen.row(2));
    try testing.expect(std.mem.startsWith(u8, none_screen.row(5), "X Premium+"));
    try testing.expect(std.mem.endsWith(u8, none_screen.row(5), "-   off"));

    var managed_value = test_grok;
    managed_value.settings = .{ .plan = "SuperGrok", .usage_url = "https://console.x.ai/team/usage" };
    var managed = try grokSnapshot(.ready, managed_value);
    defer managed.deinit();
    var managed_screen = try draw(.{ .active = true, .snapshot = &managed }, 80, 40);
    defer managed_screen.deinit();
    try testing.expectEqualStrings("  usage is managed by your team: https://console.x.ai/team/usage", managed_screen.row(2));
    try testing.expect(managed_screen.find("limit") == null and managed_screen.find("product") == null);

    // Settings that turn pay-as-you-go off win over a leftover cap.
    var off_value = test_grok;
    off_value.settings = .{ .plan = "SuperGrok", .on_demand_enabled = false };
    var off = try grokSnapshot(.ready, off_value);
    defer off.deinit();
    var off_screen = try draw(.{ .active = true, .snapshot = &off }, 80, 40);
    defer off_screen.deinit();
    try testing.expect(std.mem.endsWith(u8, off_screen.row(10), "$12.50   off"));
}

test "a short Grok terminal drops the products, never the plan" {
    var snapshot = try grokSnapshot(.ready, test_grok);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expectEqual(@as(usize, 11), desiredRowCount(p));
    var screen = try draw(p, 80, 8);
    defer screen.deinit();
    try testing.expect(screen.find("product") == null);
    try testing.expect(std.mem.startsWith(u8, screen.row(3), "grok"));
    try testing.expect(std.mem.startsWith(u8, screen.row(6), "SuperGrok Heavy"));
}

test "Grok states name Grok" {
    var fetching = try grokSnapshot(.fetching, null);
    defer fetching.deinit();
    var first = try draw(.{ .active = true, .snapshot = &fetching }, 80, 40);
    defer first.deinit();
    try testing.expectEqualStrings("  fetching usage from Grok", first.row(2));

    var offline = try grokSnapshot(.{ .failed = .network }, test_grok);
    defer offline.deinit();
    var screen = try draw(.{ .active = true, .snapshot = &offline }, 100, 40);
    defer screen.deinit();
    try testing.expect(std.mem.endsWith(u8, screen.row(0), "couldn't reach Grok, last updated 2m ago"));

    var refused = try grokSnapshot(.{ .failed = .not_available }, test_grok);
    defer refused.deinit();
    var refused_screen = try draw(.{ .active = true, .snapshot = &refused }, 120, 40);
    defer refused_screen.deinit();
    try testing.expect(std.mem.find(u8, refused_screen.row(0), "usage isn't available for this plan") != null);
}

test "Codex states name ChatGPT, not AI Gateway" {
    var fetching = try codexSnapshot(.fetching, null);
    defer fetching.deinit();
    var first = try draw(.{ .active = true, .snapshot = &fetching }, 80, 40);
    defer first.deinit();
    try testing.expect(std.mem.endsWith(u8, first.row(0), "fetching…"));
    try testing.expectEqualStrings("  fetching usage from ChatGPT", first.row(2));

    const pro: usage.codex.Usage = .{ .plan = "pro" };
    var offline = try codexSnapshot(.{ .failed = .network }, pro);
    defer offline.deinit();
    var screen = try draw(.{ .active = true, .snapshot = &offline }, 100, 40);
    defer screen.deinit();
    try testing.expect(std.mem.endsWith(u8, screen.row(0), "couldn't reach ChatGPT, last updated 2m ago"));

    var expired = try testSnapshot(.{ .unavailable = .refresh_needed }, false, &.{});
    defer expired.deinit();
    var expired_screen = try draw(.{ .active = true, .snapshot = &expired }, 80, 40);
    defer expired_screen.deinit();
    try testing.expectEqualStrings("usage: the sign-in needs a refresh", expired_screen.row(0));
    try testing.expectEqualStrings("  (send a message to renew it, then reopen /usage)", expired_screen.row(2));
}

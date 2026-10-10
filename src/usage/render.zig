//! Renderers: every surface's bytes from a `report.View`.
//!
//! - `fx usage` text and JSON, and its failure lines.
//! - The `/usage` dashboard as draw-ready rows, and the usage hint. A row is
//!   a list of ops: a style, a reset, text, or spaces. fx's painter maps the
//!   three styles and the reset to its ANSI codes and writes the rest as is;
//!   every string, number, column, ellipsis, and clip is decided here.
//! - The `fx ask --json` `usage` value and the ACP prompt `usage` and
//!   `usage_update`.
//!
//! Output is byte-identical to what fx printed before this module, quirks
//! included. Nothing here allocates except through the caller's writer.

const std = @import("std");
const report = @import("report.zig");

const View = report.View;
const Scope = report.Scope;
const Totals = report.Totals;
const ModelUsage = report.ModelUsage;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// fx usage

pub const Format = enum { text, json };

/// `fx usage` text (`UsageSnapshot.renderText`).
pub fn cliText(writer: *Writer, view: *const View) Writer.Error!void {
    try writer.print("Usage ({s})\n", .{view.scope.label()});
    switch (view.coverage) {
        .not_started => try writer.writeAll("Tracking has not started.\n"),
        .partial => {
            var date_buf: [24]u8 = undefined;
            // Partial coverage always has a start (report invariant).
            try writer.print("Tracking since {s} (partial window).\n", .{report.formatUtcDate(&date_buf, view.coverage_started_at_ms.?)});
        },
        .full => {},
    }
    switch (view.completeness) {
        .complete => {},
        .pending => try writer.writeAll("Known totals exclude pending Gateway reconciliation.\n"),
        .incomplete => try writer.writeAll("Known totals may be incomplete.\n"),
        .legacy => try writer.writeAll("This session predates complete usage tracking.\n"),
    }

    const totals = view.totals orelse return;
    try writer.print("Total tokens  {d}\nInput         {d}\nOutput        {d}\n", .{ totals.total_tokens, totals.input_tokens, totals.output_tokens });
    try writer.print("Cache         {d} read · {d} write\n", .{ totals.cache_read_tokens, totals.cache_write_tokens });
    if (totals.reasoning_tokens) |reasoning| try writer.print("Reasoning     {d}\n", .{reasoning});
    if (totals.request_count) |requests| try writer.print("Requests      {d}\n", .{requests});
    try writer.print("Spend         ${d:.4}\n", .{totals.total_cost});

    if (view.models.len == 0) return;
    try writer.writeAll("\nBy model\n");
    for (view.models) |model| {
        try writer.writeAll("- ");
        try writeTerminalSafe(writer, model.model);
        try writer.print("  {d} tokens  ${d:.4}\n", .{ model.totals.total_tokens, model.totals.total_cost });
    }
}

/// `fx usage --json` without the trailing newline (`UsageSnapshot.renderJson`).
pub fn cliJson(writer: *Writer, view: *const View) Writer.Error!void {
    try writer.writeAll("{\"kind\":\"usage\",\"schema_version\":1,\"period\":");
    try std.json.Stringify.value(view.scope.cliValue() orelse "session", .{}, writer);
    try writer.print(",\"snapshot_time_ms\":{d},\"window_start_ms\":{d},\"coverage\":{{\"status\":", .{ view.snapshot_time_ms, view.window_start_ms });
    try std.json.Stringify.value(@tagName(view.coverage), .{}, writer);
    try writer.writeAll(",\"started_at_ms\":");
    if (view.coverage_started_at_ms) |started_at_ms| try writer.print("{d}", .{started_at_ms}) else try writer.writeAll("null");
    try writer.print(",\"full_window\":{}}},\"completeness\":", .{view.coverage == .full});
    try std.json.Stringify.value(@tagName(view.completeness), .{}, writer);
    try writer.writeAll(",\"totals\":");
    if (view.totals) |totals| try writeTotalsJson(writer, totals) else try writer.writeAll("null");
    try writer.writeAll(",\"models\":[");
    for (view.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model.model, .{}, writer);
        try writer.writeAll(",\"totals\":");
        try writeTotalsJson(writer, model.totals);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// Exactly what `fx usage` writes to stdout on success: the text, or the
/// JSON plus one newline (`writeFormattedOutput`).
pub fn cliOutput(writer: *Writer, view: *const View, format: Format) Writer.Error!void {
    switch (format) {
        .text => try cliText(writer, view),
        .json => {
            try cliJson(writer, view);
            try writer.writeByte('\n');
        },
    }
}

/// The message for a failed `fx usage`, from fx's error name
/// (`usageFailureMessage`, plus the argument path's `invalid arguments`).
pub fn cliFailureMessage(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "InvalidUsageArgs")) return "invalid arguments";
    if (std.mem.eql(u8, code, "HomeNotSet")) return "HOME is not set";
    if (std.mem.eql(u8, code, "DurablePathUnsafe") or std.mem.eql(u8, code, "PrivateStatePermissionsUnsupported")) {
        return "local usage storage is unsafe";
    }
    return "local usage data is unavailable";
}

/// A failed `fx usage`: JSON goes to stdout as one line, text to stderr as
/// `fx usage: <message>`. Exit code 1 either way. (Invalid arguments
/// without `--json` print fx's usage help instead, which fx owns.)
pub fn cliFailure(writer: *Writer, code: []const u8, format: Format) Writer.Error!void {
    const message = cliFailureMessage(code);
    switch (format) {
        .json => {
            try writer.writeAll("{\"kind\":");
            try std.json.Stringify.value("usage", .{}, writer);
            try writer.writeAll(",\"error\":");
            try std.json.Stringify.value(message, .{}, writer);
            try writer.writeAll(",\"code\":");
            try std.json.Stringify.value(code, .{}, writer);
            try writer.writeAll("}\n");
        },
        .text => try writer.print("fx usage: {s}\n", .{message}),
    }
}

fn writeTotalsJson(writer: *Writer, totals: Totals) Writer.Error!void {
    try writer.print(
        "{{\"total_tokens\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{ totals.total_tokens, totals.input_tokens, totals.output_tokens, totals.cache_read_tokens, totals.cache_write_tokens },
    );
    if (totals.reasoning_tokens) |reasoning| try writer.print("{d}", .{reasoning}) else try writer.writeAll("null");
    try writer.writeAll(",\"request_count\":");
    if (totals.request_count) |requests| try writer.print("{d}", .{requests}) else try writer.writeAll("null");
    try writer.print(",\"spend\":{d}}}", .{totals.total_cost});
}

/// fx's `encodeTerminalSafe` for the bytes a view can hold. View model names
/// are printable ASCII (report validates them), which pass unchanged; any
/// other byte is escaped as `\xNN`, as fx does for control bytes.
fn writeTerminalSafe(writer: *Writer, raw: []const u8) Writer.Error!void {
    for (raw) |byte| {
        if (byte < 0x20 or byte >= 0x7f) try writer.print("\\x{x:0>2}", .{byte}) else try writer.writeByte(byte);
    }
}

// ---------------------------------------------------------------------------
// fx ask --json and ACP

/// The `fx ask --json` `usage` value: main-agent sums, null when unreported.
pub fn writeAskUsage(writer: *Writer, turn: report.TurnUsage) Writer.Error!void {
    try std.json.Stringify.value(.{ .input_tokens = turn.input_tokens, .output_tokens = turn.output_tokens }, .{}, writer);
}

/// The ACP prompt response `usage` object: camelCase keys, present only
/// when reported.
pub fn writeAcpPromptUsage(writer: *Writer, turn: report.TurnUsage) Writer.Error!void {
    try writer.writeByte('{');
    var first = true;
    inline for (.{
        .{ "inputTokens", turn.input_tokens },
        .{ "outputTokens", turn.output_tokens },
        .{ "cacheReadTokens", turn.cache_read_tokens },
        .{ "cacheWriteTokens", turn.cache_write_tokens },
        .{ "reasoningTokens", turn.reasoning_tokens },
    }) |field| {
        if (field[1]) |value| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"{s}\":{d}", .{ field[0], value });
        }
    }
    try writer.writeByte('}');
}

pub const AcpUsageUpdate = struct {
    used: u64,
    size: u64,
    cost: ?f64,
};

/// The ACP `usage_update`, or null when fx sends none: no live context
/// measurement (`used` is the latest call's input plus output) or no known
/// context window. Cost only when the session is complete and finite.
pub fn acpUsageUpdate(session: *const View, live_context_used: ?u64, context_window: ?u64) ?AcpUsageUpdate {
    return .{
        .used = live_context_used orelse return null,
        .size = context_window orelse return null,
        .cost = report.completeCost(session),
    };
}

/// The `session/update` `update` object (`writeUsageUpdate`).
pub fn writeAcpUsageUpdate(writer: *Writer, update: AcpUsageUpdate) Writer.Error!void {
    try writer.print("{{\"sessionUpdate\":\"usage_update\",\"used\":{d},\"size\":{d}", .{ update.used, update.size });
    if (update.cost) |amount| try writer.print(",\"cost\":{{\"amount\":{d},\"currency\":\"USD\"}}", .{amount});
    try writer.writeAll("}");
}

// ---------------------------------------------------------------------------
// Dashboard rows

/// The dashboard's styles. fx maps them to `selected_completion_style`,
/// `dim_style`, `system_notice_label_style`, `warning_style`, and
/// `bold_style`.
pub const Style = enum { title, dim, label, warning, strong };

pub const Op = union(enum) {
    style: Style,
    reset,
    text: []const u8,
    spaces: usize,
};

/// fx's escape codes for the painter.
pub const Palette = struct {
    title: []const u8,
    dim: []const u8,
    label: []const u8,
    warning: []const u8,
    strong: []const u8,
    reset: []const u8,
};

/// Most model rows the dashboard shows.
pub const max_model_rows: usize = 20;

/// The usage hint row, widest first (`composeCompactCommandMenuHintRow`).
pub const hint_variants = [_][]const u8{
    "tab period  ↑↓ model  enter detail  r refresh  esc close",
    "tab period  ↑↓ model  enter  r  esc",
    "tab  ↑↓  enter  r  esc",
};

/// What the dashboard shows (fx's `UsageMenuProjection`).
pub const Dashboard = struct {
    /// The active period: the view's scope when there is a view, otherwise
    /// the scope being loaded (`usage_menu.State.scope`).
    scope: Scope = .session,
    view: ?*const View = null,
    /// A refresh failed: with a view it adds a warning, without one the
    /// dashboard says usage is unavailable.
    refresh_failed: bool = false,
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,
};

/// One dashboard row. Fill with `dashboardRow` and read with `ops`; the text
/// ops point into the row, so read them before the row moves.
pub const Row = struct {
    entries: [max_ops]Entry = undefined,
    len: usize = 0,
    bytes: [text_capacity]u8 = undefined,
    bytes_len: usize = 0,
    /// Visible columns written so far.
    column: usize = 0,
    clip: ?Clip = null,

    const max_ops = 48;
    // One model name, escaped at most four bytes per byte, plus small cells.
    const text_capacity = report.max_model_bytes * 4 + 1024;

    const Entry = union(enum) {
        style: Style,
        reset,
        text: struct { start: usize, len: usize },
        spaces: usize,
    };

    const Clip = struct { remaining: usize, cut: bool };

    pub fn count(self: *const Row) usize {
        return self.len;
    }

    pub fn op(self: *const Row, index: usize) Op {
        return switch (self.entries[index]) {
            .style => |value| .{ .style = value },
            .reset => .reset,
            .text => |span| .{ .text = self.bytes[span.start..][0..span.len] },
            .spaces => |n| .{ .spaces = n },
        };
    }

    /// The row's bytes with fx's escape codes: what fx's compose functions
    /// return for this row.
    pub fn paint(self: *const Row, writer: *Writer, palette: Palette) Writer.Error!void {
        for (0..self.len) |index| switch (self.op(index)) {
            .style => |value| try writer.writeAll(switch (value) {
                .title => palette.title,
                .dim => palette.dim,
                .label => palette.label,
                .warning => palette.warning,
                .strong => palette.strong,
            }),
            .reset => try writer.writeAll(palette.reset),
            .text => |bytes| try writer.writeAll(bytes),
            .spaces => |n| try writer.splatByteAll(' ', n),
        };
    }

    fn push(self: *Row, entry: Entry) void {
        std.debug.assert(self.len < max_ops);
        self.entries[self.len] = entry;
        self.len += 1;
    }

    fn dropped(self: *const Row) bool {
        return if (self.clip) |clip| clip.cut else false;
    }

    fn style(self: *Row, value: Style) void {
        if (!self.dropped()) self.push(.{ .style = value });
    }

    fn reset(self: *Row) void {
        if (!self.dropped()) self.push(.reset);
    }

    /// Writes text, clipped by an open clip region.
    fn text(self: *Row, value: []const u8) void {
        if (self.dropped()) return;
        var shown = value;
        if (self.clip) |*clip| {
            const cells = cellCount(value);
            if (cells > clip.remaining) {
                shown = prefixCells(value, clip.remaining);
                clip.cut = true;
            }
            clip.remaining -= cellCount(shown);
        }
        if (shown.len == 0) return;
        std.debug.assert(self.bytes_len + shown.len <= text_capacity);
        @memcpy(self.bytes[self.bytes_len..][0..shown.len], shown);
        self.push(.{ .text = .{ .start = self.bytes_len, .len = shown.len } });
        self.bytes_len += shown.len;
        self.column += cellCount(shown);
    }

    /// `row_text.appendClipped` over everything until `endClip`: escapes pass
    /// through until the first cell that does not fit, then nothing does.
    fn beginClip(self: *Row, width: usize) void {
        self.clip = .{ .remaining = width, .cut = width == 0 };
    }

    /// Ends the clip region, closing a style the cut left open.
    fn endClip(self: *Row) void {
        const cut = self.dropped();
        self.clip = null;
        if (cut) self.reset();
    }

    /// Clip-aware spaces, for padding inside a clip region.
    fn blank(self: *Row, n: usize) void {
        const spaces_text = " " ** 32;
        var left = n;
        while (left > 0) {
            const chunk = @min(left, spaces_text.len);
            self.text(spaces_text[0..chunk]);
            left -= chunk;
        }
    }

    /// `row_text.appendSingleLineEllipsized`: trailing `…` when it does not fit.
    fn ellipsized(self: *Row, value: []const u8, width: usize) void {
        if (width == 0) return;
        if (cellCount(value) <= width) return self.text(value);
        if (width == 1) return self.text("…");
        self.text(prefixCells(value, width - 1));
        self.text("…");
    }
};

/// Display cells of dashboard text. Every character the dashboard writes
/// (printable ASCII, `❯`, `…`, `↑↓`) is one cell wide in fx.
fn cellCount(text: []const u8) usize {
    var cells: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) cells += 1;
    }
    return cells;
}

fn prefixCells(text: []const u8, cells: usize) []const u8 {
    var seen: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte & 0xc0 != 0x80) {
            if (seen == cells) return text[0..index];
            seen += 1;
        }
    }
    return text;
}

/// Rows the dashboard wants (`desiredRowCount`). Lines never wrap, so the
/// count does not depend on the width.
pub fn dashboardDesiredRows(dashboard: Dashboard, width: u16) u16 {
    _ = width;
    var notes: Notes = .{};
    collectNotes(&notes, dashboard);
    var plan: Plan = .{};
    buildPlan(&plan, dashboard, &notes, null);
    return std.math.cast(u16, plan.len) orelse std.math.maxInt(u16);
}

/// Model rows visible in `visible_rows` (`usageVisibleModelItems`), for
/// keeping the selection on screen.
pub fn dashboardVisibleModelItems(dashboard: Dashboard, visible_rows: u16, width: u16) u16 {
    _ = width;
    const view = dashboard.view orelse return 0;
    if (view.totals == null or view.models.len == 0 or visible_rows == 0) return 0;
    if (visible_rows == 1) return 1;
    var notes: Notes = .{};
    collectNotes(&notes, dashboard);
    var plan: Plan = .{};
    buildPlan(&plan, dashboard, &notes, visible_rows);
    return @intCast(plan.model_rows);
}

/// The usage hint row (`composeCompactCommandMenuHintRow`).
pub fn dashboardHintRow(row: *Row, width: u16) void {
    row.* = .{};
    var hint = hint_variants[hint_variants.len - 1];
    for (hint_variants) |candidate| {
        if (cellCount(candidate) <= width) {
            hint = candidate;
            break;
        }
    }
    row.beginClip(width);
    row.style(.dim);
    row.text(hint);
    row.reset();
    row.endClip();
}

/// Fills `row` with dashboard row `row_index` of `visible_rows` at `width`
/// (`composeCompactCommandMenuRow` for the usage menu). Empty rows have no ops.
pub fn dashboardRow(row: *Row, dashboard: Dashboard, row_index: u16, visible_rows: u16, width: u16) void {
    row.* = .{};
    if (width == 0 or row_index >= visible_rows) return;
    var notes: Notes = .{};
    collectNotes(&notes, dashboard);
    if (visible_rows == 1) return priorityRow(row, dashboard, &notes, width);
    var plan: Plan = .{};
    buildPlan(&plan, dashboard, &notes, visible_rows);
    if (row_index >= plan.len) return;
    drawLine(row, dashboard, &notes, plan.lines[row_index], width);
}

// Notes: the note/warning/hint lines under the table

const max_notes = 4;

const NoteKind = enum { note, warning, hint };

/// The lines that say what the totals leave out, most important first.
/// The text lives in `bufs`, so fill a `Notes` where it stays.
const Notes = struct {
    kinds: [max_notes]NoteKind = undefined,
    lens: [max_notes]usize = undefined,
    bufs: [max_notes][96]u8 = undefined,
    len: usize = 0,
    /// A cost is still missing, so the total cost carries a `*`.
    starred: bool = false,

    fn add(self: *Notes, kind: NoteKind, comptime fmt: []const u8, args: anytype) void {
        if (self.len == max_notes) return;
        const written = std.fmt.bufPrint(&self.bufs[self.len], fmt, args) catch return;
        self.kinds[self.len] = kind;
        self.lens[self.len] = written.len;
        self.len += 1;
    }

    fn text(self: *const Notes, index: usize) []const u8 {
        return self.bufs[index][0..self.lens[index]];
    }
};

/// Nothing when every request is priced: only gaps get a line.
fn collectNotes(notes: *Notes, dashboard: Dashboard) void {
    const view = dashboard.view orelse return;
    const unpriced = view.unpriced;
    const completeness = shownCompleteness(view);
    notes.starred = view.totals != null and view.models.len > 0 and
        (unpriced.lookup_pending > 0 or unpriced.sign_in_cannot_look_up > 0 or completeness == .pending);
    const mark: []const u8 = if (notes.starred) " (*)" else "";
    if (dashboard.refresh_failed) notes.add(.warning, "refresh failed; showing earlier data", .{});
    if (unpriced.sign_in_cannot_look_up > 0) {
        const n = unpriced.sign_in_cannot_look_up;
        notes.add(.warning, "{d} request{s} unpriced{s}: sign-in can't look up costs", .{ n, plural(n), mark });
        notes.add(.hint, "add an AI Gateway API key with 'fx setup'", .{});
    }
    if (unpriced.no_receipt > 0) {
        const n = unpriced.no_receipt;
        notes.add(.warning, "{d} request{s} may be billed with no cost", .{ n, plural(n) });
    } else if (completeness == .incomplete) {
        notes.add(.warning, "totals may be incomplete", .{});
    }
    if (unpriced.lookup_pending > 0) {
        const n = unpriced.lookup_pending;
        notes.add(.note, "{d} request{s} awaiting cost from AI Gateway{s}", .{ n, plural(n), mark });
    } else if (completeness == .pending and unpriced.sign_in_cannot_look_up == 0) {
        notes.add(.note, "some costs are still pending{s}", .{mark});
    }
    if (view.in_flight > 0) notes.add(.note, "{d} request{s} in progress", .{ view.in_flight, plural(view.in_flight) });
    if (completeness == .legacy) notes.add(.note, "session predates usage tracking", .{});
    if (view.coverage == .partial) {
        if (view.coverage_started_at_ms) |started| {
            var date_buf: [16]u8 = undefined;
            notes.add(.note, "tracking since {s}", .{formatIsoDate(&date_buf, started)});
        }
    }
}

fn plural(count: u64) []const u8 {
    return if (count == 1) "" else "s";
}

// Plan: which line goes on which row

const Line = union(enum) {
    periods,
    blank,
    message: []const u8,
    header,
    model: usize,
    detail: usize,
    total,
    breakdown,
    activity,
    note: usize,
};

const max_lines = 9 + max_model_rows + max_notes;

const Plan = struct {
    lines: [max_lines]Line = undefined,
    len: usize = 0,
    model_rows: usize = 0,

    fn add(self: *Plan, line: Line) void {
        std.debug.assert(self.len < max_lines);
        self.lines[self.len] = line;
        self.len += 1;
        if (line == .model) self.model_rows += 1;
    }
};

/// The dashboard's lines, top to bottom. With `visible_rows`, spacing goes
/// first when the models do not fit, then the in/out and activity lines,
/// the column header, and the total while fewer than three models fit, and
/// the model list scrolls to keep the selection on screen.
fn buildPlan(plan: *Plan, dashboard: Dashboard, notes: *const Notes, visible_rows: ?u16) void {
    plan.add(.periods);
    const view = dashboard.view orelse {
        plan.add(.blank);
        plan.add(.{ .message = if (dashboard.refresh_failed) "usage unavailable; press r to retry" else "loading usage" });
        return;
    };
    const activity = view.session_activity != null;
    if (view.totals == null or view.models.len == 0) {
        const message: ?[]const u8 = if (view.totals == null)
            (if (view.completeness == .legacy) null else "no usage yet")
        else
            emptyTableMessage(view);
        const lines = 1 + oneIf(message != null) + oneIf(activity) + notes.len;
        const room = if (visible_rows) |rows| lines + 1 <= rows else true;
        if (room) plan.add(.blank);
        if (message) |value| plan.add(.{ .message = value });
        if (activity) plan.add(.activity);
        for (0..notes.len) |index| plan.add(.{ .note = index });
        return;
    }

    const models = view.models;
    const expanded = oneIf(dashboard.expanded_model != null);
    const all_models = @min(models.len, max_model_rows) + expanded;
    var keep: struct {
        top_blank: bool = true,
        header: bool = true,
        total: bool,
        bottom_blank: bool = true,
        breakdown: bool = true,
        activity: bool,
        notes: usize,

        fn fixed(self: @This()) usize {
            return 1 + oneIf(self.top_blank) + oneIf(self.header) + oneIf(self.total) +
                oneIf(self.bottom_blank) + oneIf(self.breakdown) + oneIf(self.activity) + self.notes;
        }
    } = .{ .total = models.len > 1 or notes.starred, .activity = activity, .notes = notes.len };

    var area: usize = all_models;
    if (visible_rows) |value| {
        const rows: usize = value;
        if (keep.fixed() + all_models > rows) keep.top_blank = false;
        if (keep.fixed() + all_models > rows) keep.bottom_blank = false;
        const few = @min(models.len, 3) + expanded;
        if (keep.fixed() + few > rows) keep.breakdown = false;
        if (keep.fixed() + few > rows) keep.activity = false;
        if (keep.fixed() + few > rows) keep.header = false;
        if (keep.fixed() + few > rows) keep.total = false;
        while (keep.notes > 0 and keep.fixed() + 1 > rows) keep.notes -= 1;
        area = rows -| keep.fixed();
    }

    const selected = @min(dashboard.selected_model, models.len - 1);
    const visible_models = @min(models.len, max_model_rows, @max(area -| expanded, 1));
    const max_start = models.len - visible_models;
    const selection_start = selected -| (visible_models - 1);
    const start = @min(@max(@min(dashboard.model_window_start, selected), selection_start), max_start);

    if (keep.top_blank) plan.add(.blank);
    if (keep.header) plan.add(.header);
    for (start..start + visible_models) |index| {
        plan.add(.{ .model = index });
        if (dashboard.expanded_model == index) plan.add(.{ .detail = index });
    }
    if (keep.total) plan.add(.total);
    if (keep.bottom_blank) plan.add(.blank);
    if (keep.breakdown) plan.add(.breakdown);
    if (keep.activity) plan.add(.activity);
    for (0..keep.notes) |index| plan.add(.{ .note = index });
}

fn oneIf(value: bool) usize {
    return @intFromBool(value);
}

fn drawLine(row: *Row, dashboard: Dashboard, notes: *const Notes, line: Line, width: u16) void {
    switch (line) {
        .periods => periodsRow(row, dashboard.scope, width),
        .blank => {},
        .message => |value| styledRow(row, value, width, .dim),
        .header => tableRow(row, columnsFor(dashboard.view.?, width), .header, "cost", " ", "tokens", "reqs", "model", width),
        .model => |index| modelRow(row, dashboard, index, width),
        .detail => |index| detailRow(row, dashboard.view.?, index, width),
        .total => totalRow(row, dashboard.view.?, notes, width),
        .breakdown => {
            var buf: [160]u8 = undefined;
            styledRow(row, breakdownText(&buf, dashboard.view.?.totals.?), width, null);
        },
        .activity => {
            var buf: [96]u8 = undefined;
            styledRow(row, activityText(&buf, dashboard.view.?.session_activity.?), width, null);
        },
        .note => |index| noteRow(row, notes, index, width),
    }
}

/// One visible row: the selected model, else the first note, else a message.
fn priorityRow(row: *Row, dashboard: Dashboard, notes: *const Notes, width: u16) void {
    const view = dashboard.view orelse
        return styledRow(row, if (dashboard.refresh_failed) "usage unavailable; press r to retry" else "loading usage", width, .dim);
    if (view.totals != null and view.models.len > 0) return modelRow(row, dashboard, @min(dashboard.selected_model, view.models.len - 1), width);
    if (notes.len > 0) return noteRow(row, notes, 0, width);
    styledRow(row, if (view.totals == null) "no usage yet" else emptyTableMessage(view), width, .dim);
}

/// A session view's completeness once its open calls finish: an open call
/// gets its own note instead of an "incomplete" warning.
fn shownCompleteness(view: *const View) report.Completeness {
    return if (view.in_flight > 0) view.settled_completeness else view.completeness;
}

/// What a view with totals but no model rows says.
fn emptyTableMessage(view: *const View) []const u8 {
    if (view.unpriced.count > 0 or shownCompleteness(view) != .complete) return "no priced requests yet";
    return if (view.scope == .session) "no usage yet" else "no usage in this period";
}

fn styledRow(row: *Row, value: []const u8, width: u16, style: ?Style) void {
    if (style) |value_style| row.style(value_style);
    row.ellipsized(value, width);
    if (style != null) row.reset();
}

/// `[session]  24h  7d  30d`: the active period bracketed.
fn periodsRow(row: *Row, active: Scope, width: u16) void {
    row.beginClip(width);
    for (Scope.tab_order, 0..) |scope, index| {
        if (index > 0) row.text("  ");
        row.style(if (scope == active) .title else .dim);
        if (scope == active) row.text("[");
        row.text(periodLabel(scope));
        if (scope == active) row.text("]");
        row.reset();
    }
    row.endClip();
}

fn periodLabel(scope: Scope) []const u8 {
    return switch (scope) {
        .session => "session",
        .hours_24 => "24h",
        .days_7 => "7d",
        .days_30 => "30d",
    };
}

fn noteRow(row: *Row, notes: *const Notes, index: usize, width: u16) void {
    const kind = notes.kinds[index];
    const label: []const u8 = switch (kind) {
        .note => "note:",
        .warning => "warning:",
        .hint => "hint:",
    };
    row.beginClip(width);
    row.style(if (kind == .warning) .warning else .dim);
    row.text(label);
    row.reset();
    row.text(" ");
    row.endClip();
    row.ellipsized(notes.text(index), @as(usize, width) -| row.column);
}

// The table: cost, tokens, requests, then the model in what is left

const marker_cells = 2;
const column_gap = 2;
const min_name_cells = 10;

const Columns = struct {
    cost: usize,
    tokens: ?usize,
    reqs: ?usize,

    /// Where model names start.
    fn model(self: Columns) usize {
        var cells = marker_cells + self.cost + 1;
        if (self.tokens) |value| cells += column_gap + value;
        if (self.reqs) |value| cells += column_gap + value;
        return cells + column_gap;
    }
};

/// Columns as wide as their widest value; narrow rows drop requests, then
/// tokens, before a name gets fewer than `min_name_cells`.
fn columnsFor(view: *const View, width: u16) Columns {
    var columns: Columns = .{ .cost = "cost".len, .tokens = "tokens".len, .reqs = "reqs".len };
    widen(&columns, view.totals.?);
    for (view.models) |model| widen(&columns, model.totals);
    if (width < columns.model() + min_name_cells) columns.reqs = null;
    if (width < columns.model() + min_name_cells) columns.tokens = null;
    return columns;
}

fn widen(columns: *Columns, totals: Totals) void {
    var cost_buf: [32]u8 = undefined;
    var token_buf: [32]u8 = undefined;
    var reqs_buf: [32]u8 = undefined;
    columns.cost = @max(columns.cost, cellCount(formatCost(&cost_buf, totals.total_cost)));
    columns.tokens = @max(columns.tokens.?, cellCount(formatCompact(&token_buf, totals.total_tokens)));
    columns.reqs = @max(columns.reqs.?, cellCount(formatRequests(&reqs_buf, totals.request_count)));
}

const TableRow = enum { header, model, selected, total };

fn tableRow(row: *Row, columns: Columns, kind: TableRow, cost: []const u8, mark: []const u8, tokens: []const u8, reqs: []const u8, name: []const u8, width: u16) void {
    const style: ?Style = switch (kind) {
        .header => .dim,
        .selected => .label,
        .total => .strong,
        .model => null,
    };
    row.beginClip(width);
    if (style) |value| row.style(value);
    row.text(if (kind == .selected) "❯ " else "  ");
    rightAligned(row, cost, columns.cost);
    row.text(mark);
    if (columns.tokens) |cells| {
        row.blank(column_gap);
        rightAligned(row, tokens, cells);
    }
    if (columns.reqs) |cells| {
        row.blank(column_gap);
        rightAligned(row, reqs, cells);
    }
    row.blank(column_gap);
    const cut = row.dropped();
    row.endClip();
    if (!cut) row.ellipsized(name, @as(usize, width) -| row.column);
    if (style != null and !cut) row.reset();
}

fn rightAligned(row: *Row, value: []const u8, cells: usize) void {
    row.blank(cells -| cellCount(value));
    row.text(value);
}

fn modelRow(row: *Row, dashboard: Dashboard, index: usize, width: u16) void {
    const view = dashboard.view.?;
    const model = view.models[index];
    const selected = index == @min(dashboard.selected_model, view.models.len - 1);
    var cost_buf: [32]u8 = undefined;
    var token_buf: [32]u8 = undefined;
    var reqs_buf: [32]u8 = undefined;
    var name_buf: [report.max_model_bytes * 4]u8 = undefined;
    tableRow(
        row,
        columnsFor(view, width),
        if (selected) .selected else .model,
        formatCost(&cost_buf, model.totals.total_cost),
        " ",
        formatCompact(&token_buf, model.totals.total_tokens),
        formatRequests(&reqs_buf, model.totals.request_count),
        escapeName(&name_buf, model.model),
        width,
    );
}

fn totalRow(row: *Row, view: *const View, notes: *const Notes, width: u16) void {
    const totals = view.totals.?;
    var cost_buf: [32]u8 = undefined;
    var token_buf: [32]u8 = undefined;
    var reqs_buf: [32]u8 = undefined;
    tableRow(
        row,
        columnsFor(view, width),
        .total,
        formatCost(&cost_buf, totals.total_cost),
        if (notes.starred) "*" else " ",
        formatCompact(&token_buf, totals.total_tokens),
        formatRequests(&reqs_buf, totals.request_count),
        "total",
        width,
    );
}

/// The expanded model's split, under its name.
fn detailRow(row: *Row, view: *const View, index: usize, width: u16) void {
    var buf: [160]u8 = undefined;
    const detail = detailText(&buf, view.models[index].totals);
    row.beginClip(width);
    row.style(.dim);
    row.blank(columnsFor(view, width).model());
    row.text(detail);
    row.reset();
    row.endClip();
}

fn escapeName(buf: *[report.max_model_bytes * 4]u8, name: []const u8) []const u8 {
    std.debug.assert(name.len <= report.max_model_bytes);
    var writer: Writer = .fixed(buf);
    writeTerminalSafe(&writer, name) catch unreachable;
    return writer.buffered();
}

// Line texts

/// `in 17.2K (4.1K cached, 9.1K written)  out 1.2K (310 reasoning)`; zero
/// and unknown parts are left out.
fn breakdownText(buf: *[160]u8, totals: Totals) []const u8 {
    return writeBreakdown(buf, totals) catch "in/out unavailable";
}

fn writeBreakdown(buf: *[160]u8, totals: Totals) Writer.Error![]const u8 {
    var writer: Writer = .fixed(buf);
    var number: [32]u8 = undefined;
    try writer.print("in {s}", .{formatCompact(&number, totals.input_tokens)});
    const cached = totals.cache_read_tokens;
    const written = totals.cache_write_tokens;
    if (cached > 0 or written > 0) {
        try writer.writeAll(" (");
        if (cached > 0) try writer.print("{s} cached", .{formatCompact(&number, cached)});
        if (cached > 0 and written > 0) try writer.writeAll(", ");
        if (written > 0) try writer.print("{s} written", .{formatCompact(&number, written)});
        try writer.writeAll(")");
    }
    try writer.print("  out {s}", .{formatCompact(&number, totals.output_tokens)});
    if (totals.reasoning_tokens) |reasoning| {
        if (reasoning > 0) try writer.print(" ({s} reasoning)", .{formatCompact(&number, reasoning)});
    }
    return writer.buffered();
}

/// `in 11.6K  cached 4.1K  written 9.1K  out 520  reasoning 310`.
fn detailText(buf: *[160]u8, totals: Totals) []const u8 {
    return writeDetail(buf, totals) catch "detail unavailable";
}

fn writeDetail(buf: *[160]u8, totals: Totals) Writer.Error![]const u8 {
    var writer: Writer = .fixed(buf);
    var number: [32]u8 = undefined;
    try writer.print("in {s}", .{formatCompact(&number, totals.input_tokens)});
    if (totals.cache_read_tokens > 0) try writer.print("  cached {s}", .{formatCompact(&number, totals.cache_read_tokens)});
    if (totals.cache_write_tokens > 0) try writer.print("  written {s}", .{formatCompact(&number, totals.cache_write_tokens)});
    try writer.print("  out {s}", .{formatCompact(&number, totals.output_tokens)});
    if (totals.reasoning_tokens) |reasoning| {
        if (reasoning > 0) try writer.print("  reasoning {s}", .{formatCompact(&number, reasoning)});
    }
    return writer.buffered();
}

/// `api 14s  wall 3m12s  lines +48 -12`, with `?` for what is unknown.
fn activityText(buf: *[96]u8, activity: report.SessionActivity) []const u8 {
    var api_buf: [32]u8 = undefined;
    var wall_buf: [32]u8 = undefined;
    var lines_buf: [48]u8 = undefined;
    const lines = if (activity.code_complete)
        std.fmt.bufPrint(&lines_buf, "+{d} -{d}", .{ activity.lines_added, activity.lines_removed }) catch "?"
    else
        "?";
    return std.fmt.bufPrint(buf, "api {s}  wall {s}  lines {s}", .{
        if (activity.api_duration_complete) formatDuration(&api_buf, activity.api_duration_ms) else "?",
        if (activity.wall_duration_complete) formatDuration(&wall_buf, activity.wall_duration_ms) else "?",
        lines,
    }) catch "activity unavailable";
}

// Formats

/// `1.5K`, `43.6M`, `1B`; whole multiples drop the decimal.
fn formatCompact(buf: *[32]u8, value: u64) []const u8 {
    const units = [_]struct { value: u64, suffix: []const u8 }{
        .{ .value = 1_000_000_000, .suffix = "B" },
        .{ .value = 1_000_000, .suffix = "M" },
        .{ .value = 1_000, .suffix = "K" },
    };
    for (units) |unit| {
        if (value < unit.value) continue;
        if (value % unit.value == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ value / unit.value, unit.suffix }) catch "?";
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(unit.value)), unit.suffix }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

/// `1,234`.
fn formatGrouped(buf: *[32]u8, value: u64) []const u8 {
    var cursor = buf.len;
    var remaining = value;
    var digits: usize = 0;
    while (true) {
        if (digits > 0 and digits % 3 == 0) {
            cursor -= 1;
            buf[cursor] = ',';
        }
        cursor -= 1;
        buf[cursor] = @intCast('0' + remaining % 10);
        remaining /= 10;
        digits += 1;
        if (remaining == 0) break;
    }
    return buf[cursor..];
}

fn formatRequests(buf: *[32]u8, value: ?u64) []const u8 {
    return formatGrouped(buf, value orelse return "?");
}

/// `$12.34` from a dollar up; below it up to four decimals without trailing
/// zeros (`$0.0298`, `$0.412`, `$0.50`), `<$0.0001` for less, `$0` for none.
fn formatCost(buf: *[32]u8, value: f64) []const u8 {
    if (!std.math.isFinite(value) or value < 0) return "$?";
    if (value == 0) return "$0";
    if (value < 0.0001) return "<$0.0001";
    if (value >= 1) return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "$?";
    const text = std.fmt.bufPrint(buf, "${d:.4}", .{value}) catch return "$?";
    const two_decimals = "$0.00".len;
    var end = text.len;
    while (end > two_decimals and text[end - 1] == '0') end -= 1;
    return text[0..end];
}

/// `1h2m3s`, `3m12s`, `14s`.
fn formatDuration(buf: *[32]u8, duration_ms: u64) []const u8 {
    const total_seconds = duration_ms / 1000;
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    if (hours > 0) return std.fmt.bufPrint(buf, "{d}h{d}m{d}s", .{ hours, minutes, seconds }) catch "?";
    if (minutes > 0) return std.fmt.bufPrint(buf, "{d}m{d}s", .{ minutes, seconds }) catch "?";
    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
}

/// `2026-10-09` (UTC).
fn formatIsoDate(buf: *[16]u8, timestamp_ms: i64) []const u8 {
    if (timestamp_ms < 0) return "unknown";
    const seconds: u64 = @intCast(@divFloor(timestamp_ms, std.time.ms_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 }) catch "unknown";
}

// ---------------------------------------------------------------------------
// Dashboard selection (`usage_menu.State`)

/// Which model row is selected and expanded, and the first visible one.
pub const Selection = struct {
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,

    /// After a refresh: keep the selected and expanded models by name when
    /// they still exist (`replaceOwned`).
    pub fn retain(self: Selection, old: ?*const View, new: *const View) Selection {
        const old_selected: ?[]const u8 = if (old) |view|
            if (view.models.len > 0) view.models[@min(self.selected_model, view.models.len - 1)].model else null
        else
            null;
        const old_expanded: ?[]const u8 = if (old) |view|
            if (self.expanded_model) |index| (if (index < view.models.len) view.models[index].model else null) else null
        else
            null;
        const selected = findModel(new.models, old_selected) orelse @min(self.selected_model, new.models.len -| 1);
        return .{
            .selected_model = selected,
            .expanded_model = findModel(new.models, old_expanded),
            .model_window_start = @min(self.model_window_start, selected),
        };
    }

    /// Up (`-1`) or Down (`+1`). False when nothing moved (`moveModel`).
    pub fn move(self: *Selection, delta: i32, model_count: usize, visible_model_rows: usize) bool {
        if (delta == 0 or model_count == 0) return false;
        const next = if (delta > 0) @min(self.selected_model +| 1, model_count - 1) else self.selected_model -| 1;
        if (next == self.selected_model) return false;
        self.selected_model = next;
        self.keepVisible(visible_model_rows);
        return true;
    }

    /// Enter: expand or collapse the selected model (`toggleExpanded`).
    pub fn toggleExpanded(self: *Selection, model_count: usize, visible_model_rows: usize) bool {
        if (model_count == 0) return false;
        const selected = @min(self.selected_model, model_count - 1);
        self.expanded_model = if (self.expanded_model == selected) null else selected;
        self.keepVisible(visible_model_rows);
        return true;
    }

    fn keepVisible(self: *Selection, visible_model_rows: usize) void {
        const visible = @max(visible_model_rows, 1);
        if (self.selected_model < self.model_window_start) {
            self.model_window_start = self.selected_model;
        } else if (self.selected_model >= self.model_window_start +| visible) {
            self.model_window_start = self.selected_model - (visible - 1);
        }
    }
};

fn findModel(models: []const ModelUsage, target: ?[]const u8) ?usize {
    const name = target orelse return null;
    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.model, name)) return index;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const record = @import("codec/record.zig");
const snapshot_codec = @import("codec/snapshot.zig");

/// Captured from an fx binary that predates this module.
const testdata = struct {
    const ledger_final = @embedFile("testdata/u07/ledger-final.jsonl");
    const ledger_torn = @embedFile("testdata/u07/ledger-torn.jsonl");

    const V1Session = struct { id: []const u8, sidecar: []const u8, session: []const u8, marker: []const u8 };
    const v1_sessions = [_]V1Session{
        .{ .id = "-0mOs2ToHDxY", .sidecar = @embedFile("testdata/u07/sidecar--0mOs2ToHDxY.json"), .session = @embedFile("testdata/u07/session--0mOs2ToHDxY.json"), .marker = @embedFile("testdata/u07/marker-v1--0mOs2ToHDxY") },
        .{ .id = "7elup-r3q_tk", .sidecar = @embedFile("testdata/u07/sidecar-7elup-r3q_tk.json"), .session = @embedFile("testdata/u07/session-7elup-r3q_tk.json"), .marker = @embedFile("testdata/u07/marker-v1-7elup-r3q_tk") },
        .{ .id = "Cn0Q2_7cxZ_z", .sidecar = @embedFile("testdata/u07/sidecar-Cn0Q2_7cxZ_z.json"), .session = @embedFile("testdata/u07/session-Cn0Q2_7cxZ_z.json"), .marker = @embedFile("testdata/u07/marker-v1-Cn0Q2_7cxZ_z") },
    };
    const v2_value = @embedFile("testdata/u07/v2-9765RiSMBar-.json");
    const v2_marker = @embedFile("testdata/u07/marker-v2-9765RiSMBar-");

    const Run = struct { scope: Scope, text: []const u8, json: []const u8 };
    fn runs(comptime phase: []const u8) [3]Run {
        return .{
            .{ .scope = .hours_24, .text = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_24h.text.stdout"), .json = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_24h.json.stdout") },
            .{ .scope = .days_7, .text = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_7d.text.stdout"), .json = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_7d.json.stdout") },
            .{ .scope = .days_30, .text = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_30d.text.stdout"), .json = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_30d.json.stdout") },
        };
    }
    const torn_json = @embedFile("testdata/u07/cli/torn.usage_30d.json.stdout");
    const torn_text_stderr = @embedFile("testdata/u07/cli/torn.usage_30d.text.stderr");
};

/// The `snapshot_time_ms` fx stamped on a captured JSON run. The text run
/// just before it is not stamped; the test renders it at the same time.
fn capturedTime(json: []const u8) !i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return parsed.value.object.get("snapshot_time_ms").?.integer;
}

fn expectOutput(view: *const View, format: Format, want: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliOutput(&out.writer, view, format);
    try testing.expectEqualStrings(want, out.written());
}

fn expectRuns(ledger: report.LedgerContents, recovery: report.Recovery, runs: [3]testdata.Run) !void {
    for (runs) |run| {
        const now = try capturedTime(run.json);
        var view = try report.rollingView(testing.allocator, ledger, recovery, run.scope, now, .{});
        defer view.deinit(testing.allocator);
        try expectOutput(&view, .json, run.json);
        try expectOutput(&view, .text, run.text);
    }
}

fn wholeLines(bytes: []const u8) []const u8 {
    return bytes[0 .. (std.mem.lastIndexOfScalar(u8, bytes, '\n') orelse return bytes[0..0]) + 1];
}

test "golden: fx usage after every call settled, from the ledger as it was then" {
    // The torn-tail input is the ledger fx read for these runs plus the
    // planted torn tail (capture.ts writes it right after them).
    var ledger = try report.ProfileLedger.load(testing.allocator, wholeLines(testdata.ledger_torn));
    defer ledger.deinit(testing.allocator);
    try expectRuns(ledger.contents(), .{}, testdata.runs("complete"));
}

fn collectFinalRecovery(collector: *report.RecoveryCollector, v1_newer: ?bool) !void {
    const alloc = testing.allocator;
    for (testdata.v1_sessions) |session| {
        var sidecar = try snapshot_codec.parseSidecar(alloc, session.sidecar);
        defer sidecar.deinit(alloc);
        try testing.expectEqualStrings(session.id, sidecar.session_id);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, session.session, .{});
        defer parsed.deinit();
        const updated_at_ms = parsed.value.object.get("updated_at_ms").?.integer;
        const protected = try record.parseMarker(session.marker);
        // The capture did not keep file times, so v1 freshness is given:
        // null means "use the update time", as fx does without a sidecar time.
        const newer = v1_newer orelse report.v1CheckpointIsNewer(&sidecar.snapshot, updated_at_ms, null, 0, protected);
        try collector.addSession(alloc, &sidecar.snapshot, updated_at_ms, newer);
    }
    var v2 = try snapshot_codec.parseV2Value(alloc, testdata.v2_value);
    defer v2.deinit(alloc);
    const protected = try record.parseMarker(testdata.v2_marker);
    try collector.addSession(alloc, &v2.snapshot, v2.at_ms, report.v2CheckpointIsNewer(&v2.snapshot, v2.at_ms, protected));
}

test "golden: fx usage at the end, from the ledger, three v1 sidecars, and one v2 checkpoint" {
    var ledger = try report.ProfileLedger.load(testing.allocator, testdata.ledger_final);
    defer ledger.deinit(testing.allocator);
    // Every freshness outcome gives the same bytes: the ledger's incidents
    // already make each window incomplete.
    for ([_]?bool{ null, true, false }) |newer| {
        var collector: report.RecoveryCollector = .{};
        defer collector.deinit(testing.allocator);
        try collectFinalRecovery(&collector, newer);
        try testing.expectEqual(@as(usize, 1), collector.facts.items.len);
        try expectRuns(ledger.contents(), collector.recovery(), testdata.runs("final"));
    }
}

test "golden: the final views also count what is unpriced" {
    var ledger = try report.ProfileLedger.load(testing.allocator, testdata.ledger_final);
    defer ledger.deinit(testing.allocator);
    var collector: report.RecoveryCollector = .{};
    defer collector.deinit(testing.allocator);
    try collectFinalRecovery(&collector, null);
    const now = try capturedTime(testdata.runs("final")[0].json);
    var view = try report.rollingView(testing.allocator, ledger.contents(), collector.recovery(), .hours_24, now, .{});
    defer view.deinit(testing.allocator);
    // Unresolved markers: the v1 and v2 401 lookups and the grok fact held
    // by the lock. No receipt: the torn-tail repair and the no-id call
    // (ledger incidents) and the lock-held no-id call (its sidecar).
    try testing.expectEqual(report.Unpriced.fromCounts(3, 0, 3), view.unpriced);
}

test "golden: a torn ledger fails fx usage exactly like fx" {
    try testing.expectError(error.UsageStoreIncomplete, report.ProfileLedger.load(testing.allocator, testdata.ledger_torn));
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliFailure(&out.writer, @errorName(error.UsageStoreIncomplete), .json);
    try testing.expectEqualStrings(testdata.torn_json, out.written());
    out.clearRetainingCapacity();
    try cliFailure(&out.writer, @errorName(error.UsageStoreIncomplete), .text);
    try testing.expectEqualStrings(testdata.torn_text_stderr, out.written());
}

test "cli failure messages follow fx" {
    try testing.expectEqualStrings("HOME is not set", cliFailureMessage("HomeNotSet"));
    try testing.expectEqualStrings("local usage storage is unsafe", cliFailureMessage("DurablePathUnsafe"));
    try testing.expectEqualStrings("local usage storage is unsafe", cliFailureMessage("PrivateStatePermissionsUnsupported"));
    try testing.expectEqualStrings("local usage data is unavailable", cliFailureMessage("InvalidUsageStore"));
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliFailure(&out.writer, "InvalidUsageArgs", .json);
    try testing.expectEqualStrings("{\"kind\":\"usage\",\"error\":\"invalid arguments\",\"code\":\"InvalidUsageArgs\"}\n", out.written());
}

fn testTotals(tokens: u64, cost: f64) Totals {
    return .{ .total_tokens = tokens, .input_tokens = tokens, .output_tokens = 0, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .request_count = 1, .total_cost = cost };
}

test "every coverage and completeness line in fx usage text" {
    var models = [_]ModelUsage{.{ .model = "p/\"quoted\\name", .totals = testTotals(5, 0.00005) }};
    var view: View = .{
        .scope = .days_7,
        .snapshot_time_ms = 1791399023442,
        .window_start_ms = 1790794223442,
        .coverage_started_at_ms = null,
        .coverage = .not_started,
        .completeness = .legacy,
        .totals = null,
        .models = &models,
    };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliText(&out.writer, &view);
    try testing.expectEqualStrings("Usage (7 days)\nTracking has not started.\nThis session predates complete usage tracking.\n", out.written());

    out.clearRetainingCapacity();
    view.coverage = .full;
    view.completeness = .pending;
    view.totals = testTotals(5, 0.00005);
    try cliText(&out.writer, &view);
    try testing.expectEqualStrings(
        "Usage (7 days)\nKnown totals exclude pending Gateway reconciliation.\nTotal tokens  5\nInput         5\nOutput        0\nCache         0 read · 0 write\nRequests      1\nSpend         $0.0001\n\nBy model\n- p/\"quoted\\name  5 tokens  $0.0001\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    view.scope = .session;
    try cliJson(&out.writer, &view);
    try testing.expectEqualStrings(
        "{\"kind\":\"usage\",\"schema_version\":1,\"period\":\"session\",\"snapshot_time_ms\":1791399023442,\"window_start_ms\":1790794223442,\"coverage\":{\"status\":\"full\",\"started_at_ms\":null,\"full_window\":true},\"completeness\":\"pending\",\"totals\":{\"total_tokens\":5,\"input_tokens\":5,\"output_tokens\":0,\"cache_read_tokens\":0,\"cache_write_tokens\":0,\"reasoning_tokens\":null,\"request_count\":1,\"spend\":0.00005},\"models\":[{\"model\":\"p/\\\"quoted\\\\name\",\"totals\":{\"total_tokens\":5,\"input_tokens\":5,\"output_tokens\":0,\"cache_read_tokens\":0,\"cache_write_tokens\":0,\"reasoning_tokens\":null,\"request_count\":1,\"spend\":0.00005}}]}",
        out.written(),
    );
}

test "ask and ACP usage projections" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeAskUsage(&out.writer, .{ .input_tokens = 17, .cache_read_tokens = 3 });
    try testing.expectEqualStrings("{\"input_tokens\":17,\"output_tokens\":null}", out.written());

    out.clearRetainingCapacity();
    try writeAcpPromptUsage(&out.writer, .{ .output_tokens = 5, .reasoning_tokens = 1 });
    try testing.expectEqualStrings("{\"outputTokens\":5,\"reasoningTokens\":1}", out.written());
    out.clearRetainingCapacity();
    try writeAcpPromptUsage(&out.writer, .{});
    try testing.expectEqualStrings("{}", out.written());

    var view: View = .{ .scope = .session, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = testTotals(8, 0.25), .models = &.{} };
    try testing.expectEqual(@as(?AcpUsageUpdate, null), acpUsageUpdate(&view, null, 128000));
    try testing.expectEqual(@as(?AcpUsageUpdate, null), acpUsageUpdate(&view, 8, null));
    out.clearRetainingCapacity();
    try writeAcpUsageUpdate(&out.writer, acpUsageUpdate(&view, 8, 128000).?);
    try testing.expectEqualStrings("{\"sessionUpdate\":\"usage_update\",\"used\":8,\"size\":128000,\"cost\":{\"amount\":0.25,\"currency\":\"USD\"}}", out.written());
    view.completeness = .pending;
    out.clearRetainingCapacity();
    try writeAcpUsageUpdate(&out.writer, acpUsageUpdate(&view, 8, 128000).?);
    try testing.expectEqualStrings("{\"sessionUpdate\":\"usage_update\",\"used\":8,\"size\":128000}", out.written());
}

test "dashboard number formats" {
    var buf: [32]u8 = undefined;
    const compact = [_]struct { u64, []const u8 }{ .{ 0, "0" }, .{ 999, "999" }, .{ 1000, "1K" }, .{ 1500, "1.5K" }, .{ 43_600_000, "43.6M" }, .{ 1_000_000_000, "1B" }, .{ std.math.maxInt(u64), "18446744073.7B" } };
    for (compact) |case| try testing.expectEqualStrings(case[1], formatCompact(&buf, case[0]));
    try testing.expectEqualStrings("1,234,567", formatGrouped(&buf, 1234567));
    try testing.expectEqualStrings("0", formatGrouped(&buf, 0));
    try testing.expectEqualStrings("?", formatRequests(&buf, null));
    const costs = [_]struct { f64, []const u8 }{
        .{ 0, "$0" },      .{ 0.00005, "<$0.0001" }, .{ 0.0298, "$0.0298" },  .{ 0.412, "$0.412" },
        .{ 0.5, "$0.50" }, .{ 0.99996, "$1.00" },    .{ 100.789, "$100.79" }, .{ 1e40, "$?" },
        .{ -1, "$?" },
    };
    for (costs) |case| try testing.expectEqualStrings(case[1], formatCost(&buf, case[0]));
    try testing.expectEqualStrings("1h2m3s", formatDuration(&buf, 3_723_999));
    try testing.expectEqualStrings("2m0s", formatDuration(&buf, 120_000));
    try testing.expectEqualStrings("0s", formatDuration(&buf, 999));
    var date: [16]u8 = undefined;
    try testing.expectEqualStrings("2026-10-07", formatIsoDate(&date, 1791381023000));
}

const test_palette: Palette = .{ .title = "<T>", .dim = "<D>", .label = "<L>", .warning = "<W>", .strong = "<S>", .reset = "</>" };

fn paintRow(dashboard: Dashboard, row_index: u16, visible_rows: u16, width: u16) ![]u8 {
    var row: Row = .{};
    dashboardRow(&row, dashboard, row_index, visible_rows, width);
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try row.paint(&out.writer, test_palette);
    return out.toOwnedSlice();
}

fn expectRow(want: []const u8, dashboard: Dashboard, row_index: u16, visible_rows: u16, width: u16) !void {
    const got = try paintRow(dashboard, row_index, visible_rows, width);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "dashboard periods put the session first and clip on narrow rows" {
    const dashboard: Dashboard = .{};
    try testing.expectEqual(@as(u16, 3), dashboardDesiredRows(dashboard, 80));
    try expectRow("<T>[session]</>  <D>24h</>  <D>7d</>  <D>30d</>", dashboard, 0, 3, 80);
    try expectRow("<T>[session]</>  <D>24</>", dashboard, 0, 3, 13);
    try expectRow("<D>session</>  <D>24h</>  <T>[7d]</>  <D>30d</>", .{ .scope = .days_7 }, 0, 3, 80);
    try expectRow("", dashboard, 1, 3, 80);
    try expectRow("<D>loading usage</>", dashboard, 2, 3, 80);
    try expectRow("<D>usage unavailable; press r to retry</>", .{ .refresh_failed = true }, 2, 3, 80);
    try expectRow("", dashboard, 3, 3, 80);
}

fn tableView(models: []ModelUsage, totals: Totals) View {
    return .{ .scope = .session, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = totals, .models = models };
}

test "dashboard table: costs first, names last, a total for more than one model" {
    var models = [_]ModelUsage{
        .{ .model = "anthropic/claude-haiku-4.5", .totals = .{ .total_tokens = 12_100, .input_tokens = 11_600, .output_tokens = 500, .cache_read_tokens = 4_100, .cache_write_tokens = 9_100, .reasoning_tokens = 310, .request_count = 3, .total_cost = 0.0298 } },
        .{ .model = "openai/gpt-4.1-mini", .totals = .{ .total_tokens = 6_200, .input_tokens = 5_600, .output_tokens = 600, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = 0, .request_count = 2, .total_cost = 0.0112 } },
    };
    var view = tableView(&models, .{ .total_tokens = 18_300, .input_tokens = 17_200, .output_tokens = 1_100, .cache_read_tokens = 4_100, .cache_write_tokens = 9_100, .reasoning_tokens = 310, .request_count = 5, .total_cost = 0.041 });
    view.session_activity = .{ .api_duration_complete = true, .wall_duration_complete = true, .code_complete = true, .api_duration_ms = 14_000, .wall_duration_ms = 192_000, .lines_added = 48, .lines_removed = 12 };
    var dashboard: Dashboard = .{ .view = &view };
    // Periods, blank, header, two models, total, blank, in/out, activity;
    // nothing else when every request is priced.
    try testing.expectEqual(@as(u16, 9), dashboardDesiredRows(dashboard, 80));
    try expectRow("<D>     cost   tokens  reqs  model</>", dashboard, 2, 9, 80);
    try expectRow("<L>❯ $0.0298    12.1K     3  anthropic/claude-haiku-4.5</>", dashboard, 3, 9, 80);
    try expectRow("  $0.0112     6.2K     2  openai/gpt-4.1-mini", dashboard, 4, 9, 80);
    try expectRow("<S>   $0.041    18.3K     5  total</>", dashboard, 5, 9, 80);
    try expectRow("", dashboard, 6, 9, 80);
    try expectRow("in 17.2K (4.1K cached, 9.1K written)  out 1.1K (310 reasoning)", dashboard, 7, 9, 80);
    try expectRow("api 14s  wall 3m12s  lines +48 -12", dashboard, 8, 9, 80);

    // Enter: the split goes under the selected model's name.
    dashboard.expanded_model = 0;
    try testing.expectEqual(@as(u16, 10), dashboardDesiredRows(dashboard, 80));
    try expectRow("<D>                          in 11.6K  cached 4.1K  written 9.1K  out 500  reasoning 310</>", dashboard, 4, 10, 100);

    // Narrow rows drop requests, then tokens, before names get too short.
    dashboard.expanded_model = null;
    try expectRow("<L>❯ $0.0298    12.1K     3  anthropic/cla…</>", dashboard, 3, 9, 40);
    try expectRow("<L>❯ $0.0298    12.1K  anthropic/c…</>", dashboard, 3, 9, 32);
    try expectRow("<L>❯ $0.0298   anthropic/c…</>", dashboard, 3, 9, 24);
}

test "dashboard notes say what the totals leave out" {
    var models = [_]ModelUsage{.{ .model = "p/m", .totals = testTotals(100, 0.01) }};
    var view = tableView(&models, testTotals(100, 0.01));
    var dashboard: Dashboard = .{ .view = &view };
    // One priced model: no total row, no notes.
    try testing.expectEqual(@as(u16, 6), dashboardDesiredRows(dashboard, 80));

    // A cost still on its way: the total appears with a * and a note.
    view.completeness = .pending;
    view.unpriced = report.Unpriced.fromCounts(1, 0, 0);
    try testing.expectEqual(@as(u16, 8), dashboardDesiredRows(dashboard, 80));
    try expectRow("<S>  $0.01*     100     1  total</>", dashboard, 4, 8, 80);
    try expectRow("<D>note:</> 1 request awaiting cost from AI Gateway (*)", dashboard, 7, 8, 80);

    // A refused lookup: a warning and what to do about it.
    view.unpriced = report.Unpriced.fromCounts(0, 3, 0);
    try expectRow("<W>warning:</> 3 requests unpriced (*): sign-in can't look up costs", dashboard, 7, 9, 80);
    try expectRow("<D>hint:</> add an AI Gateway API key with 'fx setup'", dashboard, 8, 9, 80);

    // A call that may be billed with no cost to look up.
    view.completeness = .incomplete;
    view.unpriced = report.Unpriced.fromCounts(0, 0, 1);
    try testing.expectEqual(@as(u16, 7), dashboardDesiredRows(dashboard, 80));
    try expectRow("<W>warning:</> 1 request may be billed with no cost", dashboard, 6, 7, 80);
    view.unpriced = .none;
    try expectRow("<W>warning:</> totals may be incomplete", dashboard, 6, 7, 80);

    // A call in flight gets its own note, not the checkpoint's "incomplete".
    view.in_flight = 1;
    view.settled_completeness = .complete;
    try expectRow("<D>note:</> 1 request in progress", dashboard, 6, 7, 80);
    view.settled_completeness = .incomplete;
    try expectRow("<W>warning:</> totals may be incomplete", dashboard, 6, 8, 80);
    try expectRow("<D>note:</> 1 request in progress", dashboard, 7, 8, 80);
    view.in_flight = 0;

    view.completeness = .complete;
    view.coverage = .partial;
    view.coverage_started_at_ms = 1791381023000;
    try expectRow("<D>note:</> tracking since 2026-10-07", dashboard, 6, 7, 80);
    try expectRow("<D>note:</> tracking since 2026-10-…", dashboard, 6, 7, 30);
    view.coverage = .full;

    dashboard.refresh_failed = true;
    try expectRow("<W>warning:</> refresh failed; showing earlier data", dashboard, 6, 7, 80);
    dashboard.refresh_failed = false;

    view.models = &.{};
    view.totals = testTotals(0, 0);
    try expectRow("<D>no usage yet</>", dashboard, 2, 3, 80);
    view.scope = .days_7;
    try expectRow("<D>no usage in this period</>", dashboard, 2, 3, 80);
    view.unpriced = report.Unpriced.fromCounts(1, 0, 0);
    view.completeness = .pending;
    try expectRow("<D>no priced requests yet</>", dashboard, 2, 4, 80);
    try expectRow("<D>note:</> 1 request awaiting cost from AI Gateway", dashboard, 3, 4, 80);
    view.unpriced = .none;
    view.scope = .session;
    view.completeness = .incomplete;
    view.in_flight = 2;
    view.settled_completeness = .complete;
    try expectRow("<D>no usage yet</>", dashboard, 2, 4, 80);
    try expectRow("<D>note:</> 2 requests in progress", dashboard, 3, 4, 80);
    view.in_flight = 0;
    view.completeness = .complete;

    view.totals = null;
    view.coverage = .not_started;
    try testing.expectEqual(@as(u16, 3), dashboardDesiredRows(dashboard, 80));
    try expectRow("<D>no usage yet</>", dashboard, 2, 3, 80);
    view.completeness = .legacy;
    try expectRow("<D>note:</> session predates usage tracking", dashboard, 2, 3, 80);
}

test "dashboard in a short footer drops spacing first and keeps the selection visible" {
    var models: [25]ModelUsage = undefined;
    var names: [25][16]u8 = undefined;
    for (&models, &names, 0..) |*model, *name, index| {
        model.* = .{ .model = std.fmt.bufPrint(name, "provider/m{d:0>2}", .{index}) catch unreachable, .totals = testTotals(25 - index, 0) };
    }
    var view = tableView(&models, testTotals(325, 0));
    view.scope = .days_30;
    var dashboard: Dashboard = .{ .view = &view, .scope = .days_30 };
    // Periods, blank, header, 20 models, total, blank, in/out.
    const desired = dashboardDesiredRows(dashboard, 80);
    try testing.expectEqual(@as(u16, 26), desired);
    try testing.expectEqual(@as(u16, 20), dashboardVisibleModelItems(dashboard, desired, 80));
    // 12 rows: the blank lines go first.
    try testing.expectEqual(@as(u16, 8), dashboardVisibleModelItems(dashboard, 12, 80));
    try expectRow("<D>  cost   tokens  reqs  model</>", dashboard, 1, 12, 80);
    // 5 rows: in/out and the header go so three models still fit.
    try testing.expectEqual(@as(u16, 3), dashboardVisibleModelItems(dashboard, 5, 80));

    dashboard.selected_model = 24;
    const last = try paintRow(dashboard, 9, 12, 80);
    defer testing.allocator.free(last);
    try testing.expect(std.mem.indexOf(u8, last, "❯") != null and std.mem.indexOf(u8, last, "provider/m24") != null);
    // One row: the selected model.
    const only = try paintRow(dashboard, 0, 1, 80);
    defer testing.allocator.free(only);
    try testing.expect(std.mem.indexOf(u8, only, "provider/m24") != null);
}

test "dashboard hint row picks the widest hint that fits" {
    var row: Row = .{};
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    dashboardHintRow(&row, 80);
    try row.paint(&out.writer, test_palette);
    try testing.expectEqualStrings("<D>tab period  ↑↓ model  enter detail  r refresh  esc close</>", out.written());
    out.clearRetainingCapacity();
    dashboardHintRow(&row, 10);
    try row.paint(&out.writer, test_palette);
    try testing.expectEqualStrings("<D>tab  ↑↓  e</>", out.written());
}

test "selection survives refresh by model name" {
    var old_models = [_]ModelUsage{ .{ .model = "a", .totals = testTotals(3, 0) }, .{ .model = "b", .totals = testTotals(2, 0) } };
    var new_models = [_]ModelUsage{ .{ .model = "b", .totals = testTotals(9, 0) }, .{ .model = "a", .totals = testTotals(3, 0) } };
    const old: View = .{ .scope = .days_30, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = testTotals(5, 0), .models = &old_models };
    var new = old;
    new.models = &new_models;
    const kept = (Selection{ .selected_model = 1, .expanded_model = 0, .model_window_start = 1 }).retain(&old, &new);
    try testing.expectEqual(Selection{ .selected_model = 0, .expanded_model = 1, .model_window_start = 0 }, kept);

    var selection: Selection = .{};
    try testing.expect(selection.move(1, 2, 1));
    try testing.expectEqual(@as(usize, 1), selection.model_window_start);
    try testing.expect(!selection.move(1, 2, 1));
    try testing.expect(selection.toggleExpanded(2, 1));
    try testing.expectEqual(@as(?usize, 1), selection.expanded_model);
    try testing.expect(selection.toggleExpanded(2, 1));
    try testing.expectEqual(@as(?usize, null), selection.expanded_model);
}

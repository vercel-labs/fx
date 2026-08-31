const std = @import("std");
const activity_overlay = @import("activity_overlay.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const frame_layout = @import("frame_layout.zig");
const io_mod = @import("../../core/shared/io.zig");
const paint_plan = @import("paint_plan.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;

pub const FrameCell = struct {
    codepoint: u21,
    width: u8,
    /// If non-zero, the id is owned by this FrameSurface's combining
    /// suffix pool, not by a temporary source grid.
    combining_suffix_id: u32 = 0,
    /// If `style.hyperlink_id != 0`, the id is owned by this
    /// FrameSurface's hyperlink pool, not by a temporary source grid.
    style: vt_emulator.Style,
    owner: paint_plan.CellOwner,
};

pub const SurfaceHyperlink = struct {
    uri: []u8,

    pub fn deinit(self: *SurfaceHyperlink, alloc: Allocator) void {
        alloc.free(self.uri);
    }
};

pub const OwnerWritePolicy = enum {
    same_owner,
    activity_over_transcript,
    diagnostic_overwrite,
};

pub const FrameSurfaceError = error{
    OutOfMemory,
    InvalidGridSize,
    AnsiBandOverflow,
    OutOfBounds,
    OwnerConflict,
    PreservedShellMutation,
    WriteOutsideBand,
    UnownedFxCell,
    CursorOutOfBounds,
    WideCellInvariantViolation,
    MissingHyperlinkResource,
    MissingCombiningSuffixResource,
};

pub const AnsiBandWriteResult = struct {
    rows_touched: u16,
    first_row: u16,
    last_row: u16,
};

const AnsiBandWritePlan = struct {
    start_row: u16,
    max_rows: u16,
    owner: paint_plan.CellOwner,
    policy: OwnerWritePolicy,
    autowrap: bool,

    fn resolve(
        surface: FrameSurface,
        start_row: u16,
        max_rows: u16,
        owner: paint_plan.CellOwner,
        policy: OwnerWritePolicy,
        autowrap: bool,
    ) FrameSurfaceError!AnsiBandWritePlan {
        if (start_row == 0 or max_rows == 0) return error.WriteOutsideBand;
        const end_row = start_row +| max_rows -| 1;
        if (end_row > surface.rows) return error.WriteOutsideBand;

        var dest_row = start_row;
        while (dest_row <= end_row) : (dest_row += 1) {
            if (!surface.ownerPlannedForRow(dest_row, owner, policy)) return error.WriteOutsideBand;
        }

        return .{
            .start_row = start_row,
            .max_rows = max_rows,
            .owner = owner,
            .policy = policy,
            .autowrap = autowrap,
        };
    }

    fn destRow(self: AnsiBandWritePlan, source_row: u16) u16 {
        return self.start_row + source_row - 1;
    }

    fn overflowed(self: AnsiBandWritePlan, grid: vt_emulator.Grid, stats: vt_emulator.FeedStats) bool {
        return stats.scrolled or stats.max_row_touched > self.max_rows or grid.cursor_row > self.max_rows;
    }

    fn result(self: AnsiBandWritePlan, stats: vt_emulator.FeedStats) AnsiBandWriteResult {
        if (stats.max_row_touched == 0) {
            return .{ .rows_touched = 0, .first_row = 0, .last_row = 0 };
        }
        return .{
            .rows_touched = stats.max_row_touched,
            .first_row = self.start_row,
            .last_row = self.start_row + stats.max_row_touched - 1,
        };
    }
};

const AnsiBandFeed = struct {
    grid: vt_emulator.Grid,
    stats: vt_emulator.FeedStats,
};

pub const FrameSurface = struct {
    alloc: Allocator,
    rows: u16,
    cols: u16,
    cells: []FrameCell,
    hyperlinks: std.ArrayList(SurfaceHyperlink) = .empty,
    combining_suffixes: std.ArrayList([]u8) = .empty,
    plan: paint_plan.PaintPlan,
    cursor_target: ?paint_plan.FrameCursorTarget,

    pub fn initFromShadow(alloc: Allocator, plan: paint_plan.PaintPlan, previous: vt_emulator.Grid) FrameSurfaceError!FrameSurface {
        if (plan.layout.rows == 0 or plan.layout.cols == 0) return error.InvalidGridSize;
        if (previous.rows != plan.layout.rows or previous.cols != plan.layout.cols) return error.InvalidGridSize;

        const cell_count = @as(usize, plan.layout.rows) * @as(usize, plan.layout.cols);
        const cells = try alloc.alloc(FrameCell, cell_count);

        var surface = FrameSurface{
            .alloc = alloc,
            .rows = plan.layout.rows,
            .cols = plan.layout.cols,
            .cells = cells,
            .plan = plan,
            .cursor_target = plan.cursor_target,
        };
        errdefer surface.deinit();
        try surface.importHyperlinkPool(previous);
        try surface.importCombiningSuffixPool(previous);

        var row: u16 = 1;
        while (row <= surface.rows) : (row += 1) {
            const owner = surface.initialOwnerForRow(row);
            var col: u16 = 1;
            while (col <= surface.cols) : (col += 1) {
                const idx = surface.index(row, col) orelse return error.OutOfBounds;
                if (owner == .preserved_shell) {
                    const source_cell = previous.cellAt(row, col) orelse return error.InvalidGridSize;
                    surface.cells[idx] = try surface.frameCellFromAuthoritativeGrid(previous, source_cell, owner);
                } else {
                    surface.cells[idx] = blankCell(owner);
                }
            }
        }

        return surface;
    }

    pub fn retainTranscriptBandFromGrid(
        self: *FrameSurface,
        source: vt_emulator.Grid,
        source_area: frame_layout.FrameRect,
    ) FrameSurfaceError!void {
        if (source.rows != self.rows or source.cols != self.cols) return error.InvalidGridSize;
        if (source_area.isEmpty()) return;
        if (!self.plan.transcript_band.containsRow(source_area.top) or
            !self.plan.transcript_band.containsRow(source_area.bottom))
        {
            return error.WriteOutsideBand;
        }

        var row = source_area.top;
        while (row <= source_area.bottom) : (row += 1) {
            var col: u16 = 1;
            while (col <= self.cols) : (col += 1) {
                const idx = self.index(row, col) orelse return error.OutOfBounds;
                const source_cell = source.cellAt(row, col) orelse return error.InvalidGridSize;
                self.cells[idx] = try self.frameCellFromAuthoritativeGrid(
                    source,
                    source_cell,
                    .transcript,
                );
            }
        }
    }

    pub fn deinit(self: *FrameSurface) void {
        self.alloc.free(self.cells);
        for (self.hyperlinks.items) |*link| link.deinit(self.alloc);
        self.hyperlinks.deinit(self.alloc);
        for (self.combining_suffixes.items) |suffix| self.alloc.free(suffix);
        self.combining_suffixes.deinit(self.alloc);
    }

    pub fn cellAt(self: FrameSurface, row: u16, col: u16) ?FrameCell {
        const idx = self.index(row, col) orelse return null;
        return self.cells[idx];
    }

    pub fn hyperlinkUrl(self: FrameSurface, id: u32) ?[]const u8 {
        if (id == 0) return null;
        if (id - 1 >= self.hyperlinks.items.len) return null;
        return self.hyperlinks.items[id - 1].uri;
    }

    pub fn combiningSuffix(self: FrameSurface, id: u32) ?[]const u8 {
        if (id == 0) return null;
        if (id - 1 >= self.combining_suffixes.items.len) return null;
        return self.combining_suffixes.items[id - 1];
    }

    pub fn internHyperlink(self: *FrameSurface, uri: []const u8) FrameSurfaceError!u32 {
        for (self.hyperlinks.items, 0..) |link, idx| {
            if (std.mem.eql(u8, link.uri, uri)) return @intCast(idx + 1);
        }
        const dup = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(dup);
        try self.hyperlinks.append(self.alloc, .{ .uri = dup });
        return @intCast(self.hyperlinks.items.len);
    }

    fn internCombiningSuffix(self: *FrameSurface, bytes: []const u8) FrameSurfaceError!u32 {
        for (self.combining_suffixes.items, 0..) |suffix, idx| {
            if (std.mem.eql(u8, suffix, bytes)) return @intCast(idx + 1);
        }
        const dup = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(dup);
        try self.combining_suffixes.append(self.alloc, dup);
        return @intCast(self.combining_suffixes.items.len);
    }

    pub fn writeCell(self: *FrameSurface, row: u16, col: u16, cell: FrameCell, policy: OwnerWritePolicy) FrameSurfaceError!void {
        const idx = self.index(row, col) orelse return error.OutOfBounds;
        if (cell.width > 2) return error.WideCellInvariantViolation;
        if (cell.width == 2 and col == self.cols) return error.WideCellInvariantViolation;
        if (cell.width == 0 and cell.combining_suffix_id != 0) return error.WideCellInvariantViolation;
        try self.validateWrite(row, col, self.cells[idx].owner, cell.owner, policy);
        self.cells[idx] = cell;
    }

    /// Feeds ANSI bytes through a temporary VT grid, checks for overflow
    /// before copying cells, then remaps grid-local hyperlink IDs into
    /// this surface's hyperlink pool.
    pub fn writeAnsiBand(
        self: *FrameSurface,
        start_row: u16,
        max_rows: u16,
        bytes: []const u8,
        owner: paint_plan.CellOwner,
        policy: OwnerWritePolicy,
    ) FrameSurfaceError!AnsiBandWriteResult {
        return self.writeAnsiBandWithAutowrap(start_row, max_rows, bytes, owner, policy, true);
    }

    /// Feed ANSI bytes with DECAWM disabled. Footer rows are painted as
    /// terminal lines, and fx keeps autowrap disabled session-wide.
    pub fn writeAnsiBandNoWrap(
        self: *FrameSurface,
        start_row: u16,
        max_rows: u16,
        bytes: []const u8,
        owner: paint_plan.CellOwner,
        policy: OwnerWritePolicy,
    ) FrameSurfaceError!AnsiBandWriteResult {
        return self.writeAnsiBandWithAutowrap(start_row, max_rows, bytes, owner, policy, false);
    }

    fn writeAnsiBandWithAutowrap(
        self: *FrameSurface,
        start_row: u16,
        max_rows: u16,
        bytes: []const u8,
        owner: paint_plan.CellOwner,
        policy: OwnerWritePolicy,
        autowrap: bool,
    ) FrameSurfaceError!AnsiBandWriteResult {
        const plan = try AnsiBandWritePlan.resolve(self.*, start_row, max_rows, owner, policy, autowrap);
        var feed = try self.feedAnsiBand(plan, bytes);
        defer feed.grid.deinit();

        try self.copyAnsiBandCells(plan, feed.grid);
        return plan.result(feed.stats);
    }

    fn feedAnsiBand(self: *FrameSurface, plan: AnsiBandWritePlan, bytes: []const u8) FrameSurfaceError!AnsiBandFeed {
        var temp = vt_emulator.Grid.init(self.alloc, self.cols, plan.max_rows +| 1) catch |err| switch (err) {
            error.InvalidGridSize => return error.InvalidGridSize,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer temp.deinit();
        temp.autowrap = plan.autowrap;

        var stats: vt_emulator.FeedStats = .{};
        temp.feedWithStats(bytes, &stats) catch return error.OutOfMemory;
        if (plan.overflowed(temp, stats)) return error.AnsiBandOverflow;

        return .{ .grid = temp, .stats = stats };
    }

    fn copyAnsiBandCells(self: *FrameSurface, plan: AnsiBandWritePlan, source: vt_emulator.Grid) FrameSurfaceError!void {
        var source_row: u16 = 1;
        while (source_row <= plan.max_rows) : (source_row += 1) {
            const dest_row = plan.destRow(source_row);
            var col: u16 = 1;
            while (col <= self.cols) : (col += 1) {
                const source_cell = source.cellAt(source_row, col) orelse return error.InvalidGridSize;
                const frame_cell = try self.frameCellFromGrid(source, source_cell, plan.owner);
                try self.writeCell(dest_row, col, frame_cell, plan.policy);
            }
        }
    }

    pub fn copyToTargetGrid(self: FrameSurface, alloc: Allocator) !vt_emulator.Grid {
        var target = try vt_emulator.Grid.init(alloc, self.cols, self.rows);
        errdefer target.deinit();

        try target.hyperlink_pool.ensureTotalCapacity(alloc, self.hyperlinks.items.len);
        for (self.hyperlinks.items) |link| {
            const dup = try alloc.dupe(u8, link.uri);
            target.hyperlink_pool.appendAssumeCapacity(dup);
        }

        try target.combining_suffix_pool.ensureTotalCapacity(alloc, self.combining_suffixes.items.len);
        for (self.combining_suffixes.items) |suffix| {
            const dup = try alloc.dupe(u8, suffix);
            target.combining_suffix_pool.appendAssumeCapacity(dup);
        }

        for (self.cells, 0..) |cell, idx| {
            target.cells[idx] = .{
                .codepoint = cell.codepoint,
                .width = cell.width,
                .combining_suffix_id = cell.combining_suffix_id,
                .style = cell.style,
            };
        }
        if (self.cursor_target) |cursor| {
            target.cursor_row = cursor.row;
            target.cursor_col = cursor.col;
            target.cursor_visible = cursor.visible;
        }
        return target;
    }

    /// Removes fx-owned color, emphasis, and hyperlink presentation while
    /// preserving glyphs, geometry, ownership, and shell-owned cells.
    pub fn neutralizeFxOwnedPresentation(self: *FrameSurface) void {
        for (self.cells) |*cell| {
            if (cell.owner == .preserved_shell) continue;
            cell.style = .{};
        }
    }

    pub fn validate(self: FrameSurface) FrameSurfaceError!void {
        if (self.cells.len != @as(usize, self.rows) * @as(usize, self.cols)) return error.InvalidGridSize;
        if (self.cursor_target) |cursor| {
            if (cursor.row == 0 or cursor.row > self.rows or cursor.col == 0 or cursor.col > self.cols) {
                return error.CursorOutOfBounds;
            }
        }

        var row: u16 = 1;
        while (row <= self.rows) : (row += 1) {
            var col: u16 = 1;
            while (col <= self.cols) : (col += 1) {
                const cell = self.cellAt(row, col).?;
                if (!self.ownerLegalAt(row, cell.owner)) return error.UnownedFxCell;
                try self.validateWideCell(row, col, cell);
            }
        }
    }

    fn initialOwnerForRow(self: FrameSurface, row: u16) paint_plan.CellOwner {
        if (self.plan.preserved_band.containsRow(row)) return .preserved_shell;
        if (self.plan.blank_band.containsRow(row)) return .gap;
        if (self.plan.activity_band.containsRow(row)) return .activity;
        if (self.plan.footer_gap_band.containsRow(row)) return .gap;
        if (self.plan.footer_band.containsRow(row)) return .footer;
        if (self.plan.transcript_band.containsRow(row)) return .transcript;
        if (self.invalidationContains(row)) return .diagnostic_clear;
        return .preserved_shell;
    }

    fn frameCellFromGrid(self: *FrameSurface, grid: vt_emulator.Grid, cell: vt_emulator.Cell, owner: paint_plan.CellOwner) FrameSurfaceError!FrameCell {
        return .{
            .codepoint = cell.codepoint,
            .width = cell.width,
            .combining_suffix_id = try self.remapCombiningSuffixFromGrid(grid, cell.combining_suffix_id),
            .style = try self.remapStyleFromGrid(grid, cell.style),
            .owner = owner,
        };
    }

    fn importHyperlinkPool(self: *FrameSurface, grid: vt_emulator.Grid) FrameSurfaceError!void {
        std.debug.assert(self.hyperlinks.items.len == 0);
        try self.hyperlinks.ensureTotalCapacity(self.alloc, grid.hyperlink_pool.items.len);
        for (grid.hyperlink_pool.items) |uri| {
            const dup = try self.alloc.dupe(u8, uri);
            self.hyperlinks.appendAssumeCapacity(.{ .uri = dup });
        }
    }

    fn importCombiningSuffixPool(self: *FrameSurface, grid: vt_emulator.Grid) FrameSurfaceError!void {
        std.debug.assert(self.combining_suffixes.items.len == 0);
        try self.combining_suffixes.ensureTotalCapacity(self.alloc, grid.combining_suffix_pool.items.len);
        for (grid.combining_suffix_pool.items) |bytes| {
            const dup = try self.alloc.dupe(u8, bytes);
            self.combining_suffixes.appendAssumeCapacity(dup);
        }
    }

    fn frameCellFromAuthoritativeGrid(
        self: *FrameSurface,
        grid: vt_emulator.Grid,
        cell: vt_emulator.Cell,
        owner: paint_plan.CellOwner,
    ) FrameSurfaceError!FrameCell {
        if (cell.style.hyperlink_id != 0) {
            const source_uri = grid.hyperlinkUrl(cell.style.hyperlink_id) orelse
                return error.MissingHyperlinkResource;
            const imported_uri = self.hyperlinkUrl(cell.style.hyperlink_id) orelse
                return error.MissingHyperlinkResource;
            if (!std.mem.eql(u8, source_uri, imported_uri)) {
                return error.MissingHyperlinkResource;
            }
        }
        if (cell.combining_suffix_id != 0) {
            const source_suffix = grid.combiningSuffix(cell.combining_suffix_id) orelse
                return error.MissingCombiningSuffixResource;
            const imported_suffix = self.combiningSuffix(cell.combining_suffix_id) orelse
                return error.MissingCombiningSuffixResource;
            if (!std.mem.eql(u8, source_suffix, imported_suffix)) {
                return error.MissingCombiningSuffixResource;
            }
        }
        return .{
            .codepoint = cell.codepoint,
            .width = cell.width,
            .combining_suffix_id = cell.combining_suffix_id,
            .style = cell.style,
            .owner = owner,
        };
    }

    fn remapCombiningSuffixFromGrid(self: *FrameSurface, grid: vt_emulator.Grid, id: u32) FrameSurfaceError!u32 {
        if (id == 0) return 0;
        const suffix = grid.combiningSuffix(id) orelse return error.MissingCombiningSuffixResource;
        return self.internCombiningSuffix(suffix);
    }

    fn remapStyleFromGrid(self: *FrameSurface, grid: vt_emulator.Grid, style: vt_emulator.Style) FrameSurfaceError!vt_emulator.Style {
        if (style.hyperlink_id == 0) return style;
        const uri = grid.hyperlinkUrl(style.hyperlink_id) orelse return error.MissingHyperlinkResource;
        var remapped = style;
        remapped.hyperlink_id = try self.internHyperlink(uri);
        return remapped;
    }

    fn validateWrite(
        self: FrameSurface,
        row: u16,
        col: u16,
        current_owner: paint_plan.CellOwner,
        next_owner: paint_plan.CellOwner,
        policy: OwnerWritePolicy,
    ) FrameSurfaceError!void {
        if (current_owner == .preserved_shell) {
            self.traceOwnerViolation(row, col, current_owner, next_owner, policy, "preserved_shell_mutation");
            return error.PreservedShellMutation;
        }
        if (!self.ownerPlannedForRow(row, next_owner, policy)) {
            self.traceOwnerViolation(row, col, current_owner, next_owner, policy, "write_outside_band");
            return error.WriteOutsideBand;
        }
        if (current_owner == next_owner) return;
        if (policy == .activity_over_transcript and
            next_owner == .activity and
            current_owner == .transcript and
            self.activityOverlayRow() == row)
        {
            return;
        }
        if (policy == .diagnostic_overwrite and next_owner == .diagnostic_clear) return;
        self.traceOwnerViolation(row, col, current_owner, next_owner, policy, "owner_conflict");
        return error.OwnerConflict;
    }

    fn traceOwnerViolation(
        self: FrameSurface,
        row: u16,
        col: u16,
        current_owner: paint_plan.CellOwner,
        next_owner: paint_plan.CellOwner,
        policy: OwnerWritePolicy,
        reason: []const u8,
    ) void {
        debug_trace.logf(
            "frame_owner_violation",
            "row={d} col={d} previous_owner={s} next_owner={s} policy={s} reason={s} invalidation={s}",
            .{
                row,
                col,
                @tagName(current_owner),
                @tagName(next_owner),
                @tagName(policy),
                reason,
                firstInvalidationName(self.plan.invalidation),
            },
        );
    }

    fn ownerPlannedForRow(self: FrameSurface, row: u16, owner: paint_plan.CellOwner, policy: OwnerWritePolicy) bool {
        return switch (owner) {
            .preserved_shell => self.plan.preserved_band.containsRow(row),
            .transcript => self.plan.transcript_band.containsRow(row),
            .gap => self.plan.blank_band.containsRow(row) or self.plan.footer_gap_band.containsRow(row),
            .activity => self.plan.activity_band.containsRow(row) or
                (policy == .activity_over_transcript and self.activityOverlayRow() == row),
            .footer => self.plan.footer_band.containsRow(row),
            .diagnostic_clear => self.invalidationContains(row) or policy == .diagnostic_overwrite,
        };
    }

    fn ownerLegalAt(self: FrameSurface, row: u16, owner: paint_plan.CellOwner) bool {
        return switch (owner) {
            .preserved_shell => self.plan.preserved_band.containsRow(row) or !self.anyOwnedBandContains(row),
            .transcript => self.plan.transcript_band.containsRow(row),
            .gap => self.plan.blank_band.containsRow(row) or self.plan.footer_gap_band.containsRow(row),
            .activity => self.plan.activity_band.containsRow(row) or self.activityOverlayRow() == row,
            .footer => self.plan.footer_band.containsRow(row),
            .diagnostic_clear => self.invalidationContains(row),
        };
    }

    fn anyOwnedBandContains(self: FrameSurface, row: u16) bool {
        return self.plan.transcript_band.containsRow(row) or
            self.plan.blank_band.containsRow(row) or
            self.plan.activity_band.containsRow(row) or
            self.plan.footer_gap_band.containsRow(row) or
            self.plan.footer_band.containsRow(row) or
            self.invalidationContains(row);
    }

    fn activityOverlayRow(self: FrameSurface) u16 {
        return switch (self.plan.activity) {
            .overlay_entry => |row| row,
            .none, .transient_row => 0,
        };
    }

    fn invalidationContains(self: FrameSurface, row: u16) bool {
        for (self.plan.invalidation.ranges()) |range| {
            if (row >= range.top and row <= range.bottom) return true;
        }
        return false;
    }

    fn validateWideCell(self: FrameSurface, row: u16, col: u16, cell: FrameCell) FrameSurfaceError!void {
        switch (cell.width) {
            0 => {
                if (col == 1) return error.WideCellInvariantViolation;
                const prev = self.cellAt(row, col - 1).?;
                if (prev.width != 2 or
                    cell.codepoint != 0 or
                    cell.combining_suffix_id != 0 or
                    !cell.style.eql(prev.style))
                {
                    return error.WideCellInvariantViolation;
                }
            },
            1 => {},
            2 => {
                if (col == self.cols) return error.WideCellInvariantViolation;
                const next = self.cellAt(row, col + 1).?;
                if (next.width != 0 or
                    next.codepoint != 0 or
                    next.combining_suffix_id != 0 or
                    !next.style.eql(cell.style))
                {
                    return error.WideCellInvariantViolation;
                }
            },
            else => return error.WideCellInvariantViolation,
        }
    }

    fn index(self: FrameSurface, row: u16, col: u16) ?usize {
        if (row == 0 or row > self.rows) return null;
        if (col == 0 or col > self.cols) return null;
        return (@as(usize, row) - 1) * @as(usize, self.cols) + (@as(usize, col) - 1);
    }
};

fn blankCell(owner: paint_plan.CellOwner) FrameCell {
    return .{
        .codepoint = ' ',
        .width = 1,
        .style = .{},
        .owner = owner,
    };
}

fn firstInvalidationName(set: paint_plan.FrameInvalidationSet) []const u8 {
    if (set.len == 0) return "none";
    return @tagName(set.ranges()[0].reason);
}

fn testPlan(activity: paint_plan.CellOwner) paint_plan.PaintPlan {
    const activity_placement: activity_overlay.ActivityPlacement = if (activity == .activity)
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } }
    else
        .none;
    const activity_band = if (activity == .activity)
        paint_plan.FrameBand{ .top = 4, .bottom = 4, .owner = .activity }
    else
        paint_plan.FrameBand.empty(.activity);

    return .{
        .layout = .{
            .rows = 6,
            .cols = 8,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 5,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
        .footer = .{
            .top = 5,
            .top_divider = 5,
            .banner = 5,
            .banner_active = false,
            .input_base = 5,
            .picker_divider = 5,
            .picker_start = 6,
            .bottom_divider = 5,
            .hint = 6,
            .total_rows = 2,
        },
        .activity = activity_placement,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 4, .owner = .transcript },
        .activity_band = activity_band,
        .footer_band = .{ .top = 5, .bottom = 6, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 5, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn overlayPlan() paint_plan.PaintPlan {
    var plan = testPlan(.transcript);
    plan.activity = .{ .overlay_entry = 3 };
    plan.activity_band = paint_plan.FrameBand.empty(.activity);
    return plan;
}

fn shadowGrid(alloc: Allocator, cols: u16, rows: u16) !vt_emulator.Grid {
    var grid = try vt_emulator.Grid.init(alloc, cols, rows);
    errdefer grid.deinit();
    try grid.feed("\x1b[1;1Hshell");
    return grid;
}

test "frame surface preserves shell rows from shadow" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    try std.testing.expectEqual(@as(u21, 's'), surface.cellAt(1, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.preserved_shell, surface.cellAt(1, 1).?.owner);
}

test "frame surface presentation neutralization preserves shell cells and fx geometry" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    try shadow.feed("\x1b[1;1H\x1b[31mS\x1b]8;;https://shell.example\x1b\\H\x1b]8;;\x1b\\\x1b[0m");
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    _ = try surface.writeAnsiBand(
        2,
        1,
        "\x1b[1;32mF\x1b]8;;https://fx.example\x1b\\X\x1b]8;;\x1b\\\x1b[0m",
        .transcript,
        .same_owner,
    );
    const preserved_before = surface.cellAt(1, 1).?;
    const fx_before = surface.cellAt(2, 1).?;
    try std.testing.expect(!fx_before.style.eql(.{}));

    surface.neutralizeFxOwnedPresentation();

    const preserved_after = surface.cellAt(1, 1).?;
    const fx_after = surface.cellAt(2, 1).?;
    try std.testing.expect(std.meta.eql(preserved_before, preserved_after));
    try std.testing.expectEqual(fx_before.codepoint, fx_after.codepoint);
    try std.testing.expectEqual(fx_before.width, fx_after.width);
    try std.testing.expectEqual(fx_before.combining_suffix_id, fx_after.combining_suffix_id);
    try std.testing.expectEqual(fx_before.owner, fx_after.owner);
    try std.testing.expect(fx_after.style.eql(.{}));
}

test "frame surface initializes transcript footer and activity owners" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.activity), shadow);
    defer surface.deinit();

    try std.testing.expectEqual(paint_plan.CellOwner.transcript, surface.cellAt(2, 1).?.owner);
    try std.testing.expectEqual(paint_plan.CellOwner.activity, surface.cellAt(4, 1).?.owner);
    try std.testing.expectEqual(paint_plan.CellOwner.footer, surface.cellAt(5, 1).?.owner);
}

test "frame surface initializes owned gap rows as blank target cells" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    try shadow.feed("\x1b[3;1Hstale");

    var plan = testPlan(.activity);
    plan.transcript_band.bottom = 2;
    plan.blank_band = .{ .top = 3, .bottom = 3, .owner = .gap };
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    try std.testing.expectEqual(paint_plan.CellOwner.gap, surface.cellAt(3, 1).?.owner);
    try std.testing.expectEqual(@as(u21, ' '), surface.cellAt(3, 1).?.codepoint);
}

test "frame surface rejects preserved shell mutation" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    try std.testing.expectError(error.PreservedShellMutation, surface.writeCell(1, 1, blankCell(.preserved_shell), .same_owner));
}

test "full-terminal scroll invalidation does not allow painting preserved shell rows" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    try plan.invalidation.append(.{ .reason = .terminal_scroll, .top = 1, .bottom = 6 });
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    try std.testing.expectError(error.WriteOutsideBand, surface.writeAnsiBand(1, 1, "fx", .transcript, .same_owner));
    try std.testing.expectEqual(paint_plan.CellOwner.preserved_shell, surface.cellAt(1, 1).?.owner);
}

test "frame surface permits activity over transcript only for overlay policy" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, overlayPlan(), shadow);
    defer surface.deinit();

    const activity_cell = FrameCell{ .codepoint = '*', .width = 1, .style = .{}, .owner = .activity };
    try std.testing.expectError(error.WriteOutsideBand, surface.writeCell(3, 1, activity_cell, .same_owner));
    try surface.writeCell(3, 1, activity_cell, .activity_over_transcript);
    try std.testing.expectEqual(paint_plan.CellOwner.activity, surface.cellAt(3, 1).?.owner);
}

test "frame surface traces owner violations without cell payloads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "frame_owner_violation");

    var shadow = try shadowGrid(alloc, 8, 6);
    defer shadow.deinit();
    var plan = overlayPlan();
    try plan.invalidation.append(.{ .reason = .resize, .top = 2, .bottom = 4 });
    var surface = try FrameSurface.initFromShadow(alloc, plan, shadow);
    defer surface.deinit();

    const activity_cell = FrameCell{ .codepoint = '*', .width = 1, .style = .{}, .owner = .activity };
    try surface.writeCell(3, 1, activity_cell, .activity_over_transcript);
    const transcript_cell = FrameCell{ .codepoint = 's', .width = 1, .style = .{}, .owner = .transcript };
    try std.testing.expectError(error.OwnerConflict, surface.writeCell(3, 1, transcript_cell, .same_owner));

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &file, 8192);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "[frame_owner_violation]") != null);
    try std.testing.expect(std.mem.find(u8, trace, "row=3 col=1") != null);
    try std.testing.expect(std.mem.find(u8, trace, "previous_owner=activity next_owner=transcript") != null);
    try std.testing.expect(std.mem.find(u8, trace, "invalidation=resize") != null);
    try std.testing.expect(std.mem.find(u8, trace, "secret") == null);
    try std.testing.expect(std.mem.find(u8, trace, "transcript text") == null);
}

test "frame surface rejects footer over activity" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.activity), shadow);
    defer surface.deinit();

    try std.testing.expectError(error.WriteOutsideBand, surface.writeCell(4, 1, blankCell(.footer), .same_owner));
}

test "frame surface validates band ownership before parsing ansi bytes" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    try std.testing.expectError(
        error.WriteOutsideBand,
        surface.writeAnsiBand(4, 1, "a\nb\nc", .footer, .same_owner),
    );
    try std.testing.expectEqual(paint_plan.CellOwner.transcript, surface.cellAt(4, 1).?.owner);
    try std.testing.expectEqual(@as(u21, ' '), surface.cellAt(4, 1).?.codepoint);
}

test "frame surface writeAnsiBand copies soft-wrapped continuation rows" {
    var shadow = try shadowGrid(std.testing.allocator, 4, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 4;
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    const result = try surface.writeAnsiBand(2, 2, "abcdef", .transcript, .same_owner);
    try std.testing.expectEqual(@as(u16, 2), result.rows_touched);
    try std.testing.expectEqual(@as(u21, 'a'), surface.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), surface.cellAt(3, 1).?.codepoint);
}

test "frame surface writeAnsiBand fits decomposed text in its display width" {
    var shadow = try shadowGrid(std.testing.allocator, 4, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 4;
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    const result = try surface.writeAnsiBand(
        2,
        1,
        "e\u{0301}e\u{0301}e\u{0301}e\u{0301}",
        .transcript,
        .same_owner,
    );
    try std.testing.expectEqual(@as(u16, 1), result.rows_touched);

    var target = try surface.copyToTargetGrid(std.testing.allocator);
    defer target.deinit();
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try target.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings(
        "e\u{0301}e\u{0301}e\u{0301}e\u{0301}",
        row_text.items,
    );
}

test "frame surface preserves Unicode display-unit suffix bytes" {
    var shadow = try shadowGrid(std.testing.allocator, 10, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 10;
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    const text = "\u{2600}\u{FE0E}\u{1F44D}\u{1F3FD}\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}\u{1F469}\u{200D}\u{1F4BB}";
    const result = try surface.writeAnsiBand(2, 1, text, .transcript, .same_owner);
    try std.testing.expectEqual(@as(u16, 1), result.rows_touched);

    var target = try surface.copyToTargetGrid(std.testing.allocator);
    defer target.deinit();
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try target.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings(text, row_text.items);
}

test "frame surface writeAnsiBand preserves hard-newline rows" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    const result = try surface.writeAnsiBand(2, 2, "a\nb", .transcript, .same_owner);
    try std.testing.expectEqual(@as(u16, 2), result.rows_touched);
    try std.testing.expectEqual(@as(u21, 'a'), surface.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), surface.cellAt(3, 1).?.codepoint);
}

test "frame surface materialized ANSI-only row matches one-row occupancy" {
    const alloc = std.testing.allocator;
    var shadow = try shadowGrid(alloc, 123, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 123;
    var surface = try FrameSurface.initFromShadow(alloc, plan, shadow);
    defer surface.deinit();

    const band = try AnsiBandWritePlan.resolve(
        surface,
        2,
        1,
        .transcript,
        .same_owner,
        true,
    );
    var controls_only = try surface.feedAnsiBand(band, "\x1b[0m");
    defer controls_only.grid.deinit();
    try std.testing.expectEqual(@as(u16, 0), controls_only.stats.max_row_touched);
    try std.testing.expectEqual(@as(u16, 1), controls_only.grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), controls_only.grid.cursor_col);
    try std.testing.expect(!controls_only.grid.pending_wrap);
    try std.testing.expect(!controls_only.stats.scrolled);

    var materialized = try surface.feedAnsiBand(band, "\x1b[0m\x1b[2K");
    defer materialized.grid.deinit();
    try std.testing.expectEqual(@as(u16, 1), materialized.stats.max_row_touched);
    try std.testing.expectEqual(@as(u16, 1), materialized.grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), materialized.grid.cursor_col);
    try std.testing.expect(!materialized.grid.pending_wrap);
    try std.testing.expect(!materialized.stats.scrolled);

    const result = try surface.writeAnsiBand(
        2,
        1,
        "\x1b[0m\x1b[2K",
        .transcript,
        .same_owner,
    );
    try std.testing.expectEqual(@as(u16, 1), result.rows_touched);
    try std.testing.expectEqual(@as(u16, 2), result.first_row);
    try std.testing.expectEqual(@as(u16, 2), result.last_row);
}

test "frame surface writeAnsiBand fails when footer text touches sentinel row" {
    var shadow = try shadowGrid(std.testing.allocator, 4, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 4;
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    try std.testing.expectError(error.AnsiBandOverflow, surface.writeAnsiBand(5, 1, "abcdx", .footer, .same_owner));
}

test "frame surface writeAnsiBandNoWrap clamps printable footer overflow" {
    var shadow = try shadowGrid(std.testing.allocator, 4, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 4;
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    _ = try surface.writeAnsiBandNoWrap(5, 1, "abcdx", .footer, .same_owner);
    try std.testing.expectEqual(@as(u21, 'a'), surface.cellAt(5, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'x'), surface.cellAt(5, 4).?.codepoint);
}

test "frame surface writeAnsiBandNoWrap still rejects hard-newline footer overflow" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    try std.testing.expectError(error.AnsiBandOverflow, surface.writeAnsiBandNoWrap(5, 1, "a\nb", .footer, .same_owner));
}

test "frame surface writeAnsiBand fails when temporary VT scrolls" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    try std.testing.expectError(error.AnsiBandOverflow, surface.writeAnsiBand(5, 1, "a\nb\nc", .footer, .same_owner));
}

test "frame surface remaps OSC 8 hyperlink ids from temporary grid" {
    var shadow = try shadowGrid(std.testing.allocator, 16, 6);
    defer shadow.deinit();
    var plan = testPlan(.transcript);
    plan.layout.cols = 16;
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();

    _ = try surface.writeAnsiBand(2, 1, "\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\", .transcript, .same_owner);
    const cell = surface.cellAt(2, 1).?;
    try std.testing.expect(cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings("https://example.com", surface.hyperlinkUrl(cell.style.hyperlink_id).?);

    var target = try surface.copyToTargetGrid(std.testing.allocator);
    defer target.deinit();
    const target_cell = target.cellAt(2, 1).?;
    try std.testing.expectEqualStrings("https://example.com", target.hyperlinkUrl(target_cell.style.hyperlink_id).?);
}

test "frame surface preserves authoritative hyperlink ids and unused pool slots" {
    var shadow = try shadowGrid(std.testing.allocator, 16, 6);
    defer shadow.deinit();
    try shadow.feed("\x1b]8;;https://unused.example\x1b\\\x1b]8;;\x1b\\");
    try shadow.feed("\x1b[2;1H\x1b]8;;https://active.example\x1b\\X\x1b]8;;\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), shadow.hyperlink_pool.items.len);
    try std.testing.expectEqual(@as(u32, 2), shadow.cellAt(2, 1).?.style.hyperlink_id);

    var plan = testPlan(.transcript);
    plan.layout.cols = 16;
    var surface = try FrameSurface.initFromShadow(
        std.testing.allocator,
        plan,
        shadow,
    );
    defer surface.deinit();
    try surface.retainTranscriptBandFromGrid(shadow, .{ .top = 2, .bottom = 2 });

    const retained = surface.cellAt(2, 1).?;
    try std.testing.expectEqual(@as(u32, 2), retained.style.hyperlink_id);
    try std.testing.expectEqualStrings("https://unused.example", surface.hyperlinkUrl(1).?);
    try std.testing.expectEqualStrings("https://active.example", surface.hyperlinkUrl(2).?);

    var target = try surface.copyToTargetGrid(std.testing.allocator);
    defer target.deinit();
    try std.testing.expectEqual(@as(u32, 2), target.cellAt(2, 1).?.style.hyperlink_id);
    try std.testing.expectEqualStrings("https://unused.example", target.hyperlinkUrl(1).?);
    try std.testing.expectEqualStrings("https://active.example", target.hyperlinkUrl(2).?);
}

test "frame surface rejects invalid authoritative hyperlink ids" {
    var preserved = try shadowGrid(std.testing.allocator, 8, 6);
    defer preserved.deinit();
    preserved.cells[0].style.hyperlink_id = 1;
    try std.testing.expectError(
        error.MissingHyperlinkResource,
        FrameSurface.initFromShadow(
            std.testing.allocator,
            testPlan(.transcript),
            preserved,
        ),
    );

    var retained = try shadowGrid(std.testing.allocator, 8, 6);
    defer retained.deinit();
    retained.cells[8].style.hyperlink_id = 1;
    var surface = try FrameSurface.initFromShadow(
        std.testing.allocator,
        testPlan(.transcript),
        retained,
    );
    defer surface.deinit();
    try std.testing.expectError(
        error.MissingHyperlinkResource,
        surface.retainTranscriptBandFromGrid(retained, .{ .top = 2, .bottom = 2 }),
    );
}

test "frame surface rejects invalid authoritative combining suffix ids" {
    var preserved = try shadowGrid(std.testing.allocator, 8, 6);
    defer preserved.deinit();
    preserved.cells[0].combining_suffix_id = 1;

    try std.testing.expectError(
        error.MissingCombiningSuffixResource,
        FrameSurface.initFromShadow(
            std.testing.allocator,
            testPlan(.transcript),
            preserved,
        ),
    );
}

test "frame surface validates wide cell trailing cells" {
    var shadow = try shadowGrid(std.testing.allocator, 8, 6);
    defer shadow.deinit();
    var surface = try FrameSurface.initFromShadow(std.testing.allocator, testPlan(.transcript), shadow);
    defer surface.deinit();

    _ = try surface.writeAnsiBand(2, 1, "漢", .transcript, .same_owner);
    try std.testing.expectEqual(@as(u8, 2), surface.cellAt(2, 1).?.width);
    try std.testing.expectEqual(@as(u8, 0), surface.cellAt(2, 2).?.width);
    try surface.validate();
}

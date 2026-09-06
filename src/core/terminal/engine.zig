//! Bounded text-terminal engine shared by live terminal sessions, recovery,
//! replay, and deterministic rendering tests. Graphical terminal protocols
//! are intentionally outside this module's contract.

const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const contracts = @import("contracts.zig");

const Allocator = std.mem.Allocator;

pub const checkpoint_schema_revision: u16 = 1;
const checkpoint_magic = "FXTE";
pub const max_reply_effects: usize = 16;
pub const max_reply_effect_bytes: usize = 256;
pub const max_reply_effect_total_bytes: usize = 4096;
const max_csi_params: usize = 16;
const max_csi_intermediates: usize = 2;
const max_string_bytes: usize = 4096;
const max_sync_bytes: usize = 1024 * 1024;
const max_pool_entries: usize = 65_535;
const max_hyperlink_pool_bytes: usize = 4 * 1024 * 1024;
const max_combining_pool_bytes: usize = 4 * 1024 * 1024;

pub const FeedMode = enum {
    native_live,
    tmux_live,
    journal_replay,
};

pub const ProtocolReply = struct {
    bytes: []u8,
};

pub const FeedResult = struct {
    stats: FeedStats = .{},
    replies: std.ArrayList(ProtocolReply) = .empty,
    reply_bytes: usize = 0,

    pub fn deinit(self: *FeedResult, alloc: Allocator) void {
        for (self.replies.items) |reply| alloc.free(reply.bytes);
        self.replies.deinit(alloc);
        self.* = undefined;
    }
};

pub const Color = union(enum) {
    default,
    /// Indexed palette colour (0..255) from `\x1b[3Nm`, `\x1b[4Nm`,
    /// `\x1b[9Nm`, `\x1b[10Nm`, or `\x1b[38;5;N` / `\x1b[48;5;N`.
    indexed: u8,
    /// Truecolor from `\x1b[38;2;R;G;Bm` / `\x1b[48;2;R;G;Bm`.
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |ai| switch (b) {
                .indexed => |bi| ai == bi,
                else => false,
            },
            .rgb => |ar| switch (b) {
                .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
                else => false,
            },
        };
    }
};

pub const StyleFlags = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strike: bool = false,
    _pad: u2 = 0,

    pub fn eql(a: StyleFlags, b: StyleFlags) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    flags: StyleFlags = .{},
    /// Index into `Grid.hyperlink_pool`. `0` means no OSC 8 hyperlink;
    /// IDs `>= 1` map to a URL string the cell should be wrapped with
    /// when re-emitted by `diffBand`. IDs are grid-local; they survive
    /// `Grid.clone` because the pool is dup'd in lockstep.
    hyperlink_id: u32 = 0,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.flags.eql(b.flags) and a.hyperlink_id == b.hyperlink_id;
    }
};

pub const Cell = struct {
    /// Unicode codepoint in this cell. Zero for the trailing half of a
    /// wide (double-width) cell so callers can tell single from wide.
    codepoint: u21 = ' ',
    width: u8 = 1,
    /// Index into `Grid.combining_suffix_pool`. `0` means the lead
    /// codepoint has no remaining display-unit UTF-8 bytes.
    combining_suffix_id: u32 = 0,
    /// Style applied to this cell. Blank cells from erasures inherit
    /// the current bg so a `\x1b[48;5;236m\x1b[K` clears into the
    /// configured background, matching real terminals.
    style: Style = .{},
};

pub const FeedStats = struct {
    max_row_touched: u16 = 0,
    scrolled: bool = false,
    scroll_rows: u16 = 0,

    fn touchRow(self: *FeedStats, row: u16) void {
        self.max_row_touched = @max(self.max_row_touched, row);
    }
};

const State = enum {
    normal,
    escape,
    csi,
    osc,
    dcs,
};

const SavedCursor = struct {
    row: u16,
    col: u16,
    pending_wrap: bool,
    style: Style,
    origin_mode: bool,
};

const SavedScreen = struct {
    rows: u16,
    cols: u16,
    cells: []Cell,
    row_origin: u16,
    cursor_row: u16,
    cursor_col: u16,
    autowrap: bool,
    pending_wrap: bool,
    cursor_visible: bool,
    cursor_shape: contracts.CursorShape,
    cursor_blinking: bool,
    current_style: Style,
    active_hyperlink_params: []const u8,
    last_printable_idx: ?usize,
    scroll_top: u16,
    scroll_bottom: u16,
    origin_mode: bool,
    insert_mode: bool,
    saved_cursor: ?SavedCursor,

    /// Take ownership of the grid's live screen state, including its
    /// `cells` and `active_hyperlink_params` allocations.
    fn capture(grid: Grid) SavedScreen {
        return .{
            .rows = grid.rows,
            .cols = grid.cols,
            .cells = grid.cells,
            .row_origin = grid.row_origin,
            .cursor_row = grid.cursor_row,
            .cursor_col = grid.cursor_col,
            .autowrap = grid.autowrap,
            .pending_wrap = grid.pending_wrap,
            .cursor_visible = grid.cursor_visible,
            .cursor_shape = grid.cursor_shape,
            .cursor_blinking = grid.cursor_blinking,
            .current_style = grid.current_style,
            .active_hyperlink_params = grid.active_hyperlink_params,
            .last_printable_idx = grid.last_printable_idx,
            .scroll_top = grid.scroll_top,
            .scroll_bottom = grid.scroll_bottom,
            .origin_mode = grid.origin_mode,
            .insert_mode = grid.insert_mode,
            .saved_cursor = grid.saved_cursor,
        };
    }

    /// Hand the saved state back to the grid, transferring ownership
    /// of the allocations. The caller frees the grid's previous ones.
    fn restoreTo(saved: SavedScreen, grid: *Grid) void {
        grid.rows = saved.rows;
        grid.cols = saved.cols;
        grid.cells = saved.cells;
        grid.row_origin = saved.row_origin;
        grid.cursor_row = saved.cursor_row;
        grid.cursor_col = saved.cursor_col;
        grid.autowrap = saved.autowrap;
        grid.pending_wrap = saved.pending_wrap;
        grid.cursor_shape = saved.cursor_shape;
        grid.cursor_blinking = saved.cursor_blinking;
        grid.current_style = saved.current_style;
        grid.active_hyperlink_params = saved.active_hyperlink_params;
        grid.last_printable_idx = saved.last_printable_idx;
        grid.scroll_top = saved.scroll_top;
        grid.scroll_bottom = saved.scroll_bottom;
        grid.origin_mode = saved.origin_mode;
        grid.insert_mode = saved.insert_mode;
        grid.saved_cursor = saved.saved_cursor;
    }

    /// Deep copy. New fields are carried automatically; only the two
    /// allocations need duplicating.
    fn dupe(saved: SavedScreen, alloc: Allocator) !SavedScreen {
        var copy = saved;
        copy.cells = try alloc.dupe(Cell, saved.cells);
        errdefer alloc.free(copy.cells);
        copy.active_hyperlink_params = if (saved.active_hyperlink_params.len > 0)
            try alloc.dupe(u8, saved.active_hyperlink_params)
        else
            &.{};
        return copy;
    }
};

inline fn failGrid(err: anytype) @TypeOf(err)!Grid {
    return @errorCast(failGridDynamic(err));
}

noinline fn failGridDynamic(err: anyerror) anyerror!Grid {
    return err;
}

test "grid failures preserve exact error types and identities" {
    const invalid = failGrid(error.InvalidGridSize);
    try std.testing.expect(@TypeOf(invalid) == error{InvalidGridSize}!Grid);
    try std.testing.expectError(error.InvalidGridSize, invalid);
    try std.testing.expectError(error.OutOfMemory, failGrid(error.OutOfMemory));
}

pub const Grid = struct {
    alloc: Allocator,
    rows: u16,
    cols: u16,
    cells: []Cell,
    /// Physical row backing logical terminal row one. Scrolling rotates
    /// this origin instead of shifting the complete cell grid.
    row_origin: u16 = 0,
    /// 1-indexed to match ANSI.
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    autowrap: bool = true,
    /// Lazy-wrap flag: set when the cursor fills the last column. The
    /// next printable write will consume the flag and wrap before
    /// writing. Any cursor-moving sequence (CR, LF, CUP, backspace,
    /// ...) clears it without wrapping.
    pending_wrap: bool = false,
    cursor_visible: bool = true,
    cursor_shape: contracts.CursorShape = .block,
    cursor_blinking: bool = true,
    scroll_top: u16,
    scroll_bottom: u16,
    origin_mode: bool = false,
    insert_mode: bool = false,
    bracketed_paste: bool = false,
    mouse_modes: u16 = 0,
    focus_tracking: bool = false,
    application_cursor_keys: bool = false,
    application_keypad: bool = false,
    keyboard_protocol: bool = false,
    tab_stops: []bool,
    sync_active: bool = false,
    sync_buffer: std.ArrayList(u8) = .empty,
    /// Controls whether DEC-2026 blocks apply atomically or immediately.
    /// Shadow grids disable buffering so clones include in-block clears;
    /// otherwise DECRST could erase content omitted from the subsequent diff.
    defer_sync_updates: bool = true,
    /// Active SGR state. Updated by `\x1b[Nm` and applied to any cell
    /// the cursor writes into (and to the bg of cells cleared by EL/ED).
    current_style: Style = .{},

    state: State = .normal,
    /// CSI parameters accumulated from the digit/';' bytes after `\x1b[`.
    csi_params: [max_csi_params]u16 = [_]u16{0} ** max_csi_params,
    csi_param_count: u8 = 0,
    csi_has_digit: bool = false,
    csi_private: u8 = 0,
    csi_intermediates: [max_csi_intermediates]u8 = [_]u8{0} ** max_csi_intermediates,
    csi_intermediate_count: u8 = 0,
    osc_saw_esc: bool = false,
    /// Captured OSC payload bytes (between `\x1b]` and the terminator).
    /// Retained to interpret OSC 8 (hyperlink) sequences; other OSC
    /// codes are still ignored.
    osc_buffer: std.ArrayList(u8) = .empty,
    dcs_saw_esc: bool = false,
    dcs_buffer: std.ArrayList(u8) = .empty,
    utf8_buffer: [4]u8 = [_]u8{0} ** 4,
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,
    /// Allocator-owned URL strings indexed by `Style.hyperlink_id`.
    /// `id == 0` is the sentinel "no hyperlink" and is NOT stored here
    /// (lookup is `id - 1`).
    hyperlink_pool: std.ArrayList([]u8) = .empty,
    hyperlink_pool_bytes: usize = 0,
    /// Allocator-owned ordered UTF-8 suffixes indexed by
    /// `Cell.combining_suffix_id`. IDs are grid-local.
    combining_suffix_pool: std.ArrayList([]u8) = .empty,
    combining_pool_bytes: usize = 0,
    /// Exact OSC 8 parameter bytes for the currently active hyperlink.
    /// These are presentation state, not part of URI interning.
    active_hyperlink_params: []const u8 = &.{},
    /// Normal terminal buffer state saved by DECSET ?1049. The current
    /// fields represent the alternate buffer while this is non-null.
    saved_normal_screen: ?SavedScreen = null,
    saved_cursor: ?SavedCursor = null,
    /// Lead cell written by the most recent printable input byte
    /// sequence. A following width-zero codepoint modifies this cell.
    last_printable_idx: ?usize = null,
    feed_stats: ?*FeedStats = null,
    feed_mode: FeedMode = .journal_replay,
    feed_result: ?*FeedResult = null,

    pub fn init(alloc: Allocator, cols: u16, rows: u16) !Grid {
        if (cols == 0 or rows == 0) return failGrid(error.InvalidGridSize);
        const cell_count = std.math.mul(
            usize,
            @intCast(cols),
            @intCast(rows),
        ) catch return failGrid(error.InvalidGridSize);
        if (cell_count > contracts.max_render_cells) {
            return failGrid(error.InvalidGridSize);
        }
        const cells = try alloc.alloc(Cell, cell_count);
        errdefer alloc.free(cells);
        @memset(cells, .{});
        const tab_stops = try alloc.alloc(bool, cols);
        initializeTabStops(tab_stops);
        return .{
            .alloc = alloc,
            .rows = rows,
            .cols = cols,
            .cells = cells,
            .scroll_top = 1,
            .scroll_bottom = rows,
            .tab_stops = tab_stops,
        };
    }

    pub fn deinit(self: *Grid) void {
        if (self.saved_normal_screen) |saved| {
            self.alloc.free(saved.cells);
            if (saved.active_hyperlink_params.len > 0) {
                self.alloc.free(saved.active_hyperlink_params);
            }
        }
        self.alloc.free(self.cells);
        self.sync_buffer.deinit(self.alloc);
        self.osc_buffer.deinit(self.alloc);
        self.dcs_buffer.deinit(self.alloc);
        self.alloc.free(self.tab_stops);
        for (self.hyperlink_pool.items) |url| self.alloc.free(url);
        self.hyperlink_pool.deinit(self.alloc);
        for (self.combining_suffix_pool.items) |suffix| self.alloc.free(suffix);
        self.combining_suffix_pool.deinit(self.alloc);
        if (self.active_hyperlink_params.len > 0) {
            self.alloc.free(self.active_hyperlink_params);
        }
    }

    /// Resize the grid. Keeps top-left content, clips anything outside
    /// the new bounds, fills any grown area with blanks. Matches what a
    /// real terminal does when the pane shrinks or grows — content is
    /// not auto-cleared, so the caller (fx) is responsible for
    /// repainting.
    pub fn resize(self: *Grid, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return error.InvalidGridSize;
        if (cols == self.cols and rows == self.rows) return;

        const cell_count = std.math.mul(
            usize,
            @intCast(cols),
            @intCast(rows),
        ) catch return error.InvalidGridSize;
        if (cell_count > contracts.max_render_cells) {
            return error.InvalidGridSize;
        }

        const new_cells = try self.resizedCells(
            self.cells,
            self.cols,
            self.rows,
            self.row_origin,
            cols,
            rows,
        );
        errdefer self.alloc.free(new_cells);
        const normal_cells = if (self.saved_normal_screen) |saved|
            try self.resizedCells(
                saved.cells,
                saved.cols,
                saved.rows,
                saved.row_origin,
                cols,
                rows,
            )
        else
            null;
        errdefer if (normal_cells) |cells| self.alloc.free(cells);
        const new_tab_stops = try self.resizedTabStops(cols);
        errdefer self.alloc.free(new_tab_stops);

        self.alloc.free(self.cells);
        self.alloc.free(self.tab_stops);
        self.cells = new_cells;
        self.tab_stops = new_tab_stops;
        self.cols = cols;
        self.rows = rows;
        self.row_origin = 0;
        if (self.cursor_row > rows) self.cursor_row = rows;
        if (self.cursor_col > cols) self.cursor_col = cols;
        self.last_printable_idx = null;
        self.scroll_top = 1;
        self.scroll_bottom = rows;
        self.origin_mode = false;

        if (self.saved_normal_screen) |*saved| {
            self.alloc.free(saved.cells);
            saved.cells = normal_cells.?;
            saved.rows = rows;
            saved.cols = cols;
            saved.row_origin = 0;
            if (saved.cursor_row > rows) saved.cursor_row = rows;
            if (saved.cursor_col > cols) saved.cursor_col = cols;
            saved.last_printable_idx = null;
            saved.scroll_top = 1;
            saved.scroll_bottom = rows;
            saved.origin_mode = false;
        }
    }

    fn resizedTabStops(self: Grid, cols: u16) ![]bool {
        const stops = try self.alloc.alloc(bool, cols);
        initializeTabStops(stops);
        @memcpy(stops[0..@min(stops.len, self.tab_stops.len)], self.tab_stops[0..@min(stops.len, self.tab_stops.len)]);
        return stops;
    }

    fn resizedCells(
        self: *Grid,
        source: []const Cell,
        source_cols: u16,
        source_rows: u16,
        source_row_origin: u16,
        cols: u16,
        rows: u16,
    ) ![]Cell {
        const cells = try self.alloc.alloc(Cell, @as(usize, cols) * @as(usize, rows));
        errdefer self.alloc.free(cells);
        @memset(cells, .{});

        const copy_rows = @min(source_rows, rows);
        const copy_cols = @min(source_cols, cols);
        var row: u16 = 0;
        while (row < copy_rows) : (row += 1) {
            const source_physical_row = physicalRowIndex(
                source_row_origin,
                row,
                source_rows,
            );
            const src_base: usize = source_physical_row * @as(usize, source_cols);
            const dst_base: usize = @as(usize, row) * @as(usize, cols);
            @memcpy(cells[dst_base .. dst_base + copy_cols], source[src_base .. src_base + copy_cols]);
        }
        repairWideCells(cells, cols, rows);
        return cells;
    }

    fn rowBase(self: Grid, row: u16) usize {
        std.debug.assert(row >= 1 and row <= self.rows);
        const physical_row = physicalRowIndex(
            self.row_origin,
            row - 1,
            self.rows,
        );
        return physical_row * @as(usize, self.cols);
    }

    fn cellIndex(self: Grid, row: u16, col: u16) usize {
        std.debug.assert(col >= 1 and col <= self.cols);
        return self.rowBase(row) + @as(usize, col) - 1;
    }

    fn physicalIndexForLogicalOffset(self: Grid, offset: usize) usize {
        std.debug.assert(offset < self.cells.len);
        const cols: usize = self.cols;
        const logical_row: u16 = @intCast(offset / cols);
        const col = offset % cols;
        const physical_row = physicalRowIndex(
            self.row_origin,
            logical_row,
            self.rows,
        );
        return physical_row * cols + col;
    }

    /// Feeds output through the emulator, preserving partial control sequences.
    /// DEC-2026 blocks are buffered until the matching DECRST when enabled.
    pub fn feed(self: *Grid, bytes: []const u8) !void {
        var result = try self.feedMode(bytes, .journal_replay);
        result.deinit(self.alloc);
    }

    pub fn feedMode(self: *Grid, bytes: []const u8, mode: FeedMode) !FeedResult {
        var result = FeedResult{};
        errdefer result.deinit(self.alloc);
        const previous_stats = self.feed_stats;
        const previous_mode = self.feed_mode;
        const previous_result = self.feed_result;
        self.feed_stats = &result.stats;
        self.feed_mode = mode;
        self.feed_result = &result;
        defer {
            self.feed_stats = previous_stats;
            self.feed_mode = previous_mode;
            self.feed_result = previous_result;
        }
        try self.feedBytes(bytes);
        return result;
    }

    fn feedBytes(self: *Grid, bytes: []const u8) !void {
        var remaining: []const u8 = bytes;
        while (remaining.len > 0) {
            if (!self.defer_sync_updates or !self.sync_active) {
                const consumed = try self.feedDirect(
                    remaining,
                    self.defer_sync_updates,
                );
                remaining = remaining[consumed..];
                if (consumed == 0) return error.InvalidParserState;
                if (!self.defer_sync_updates or !self.sync_active) continue;
                if (remaining.len == 0) break;
            }

            const reset = "\x1b[?2026l";
            if (self.sync_buffer.items.len >= max_sync_bytes) {
                return error.SynchronizedUpdateTooLarge;
            }
            try self.sync_buffer.append(self.alloc, remaining[0]);
            remaining = remaining[1..];
            if (!std.mem.endsWith(u8, self.sync_buffer.items, reset)) {
                continue;
            }

            self.sync_buffer.shrinkRetainingCapacity(
                self.sync_buffer.items.len - reset.len,
            );
            {
                const buffered = try self.alloc.dupe(u8, self.sync_buffer.items);
                defer self.alloc.free(buffered);
                self.sync_buffer.clearRetainingCapacity();
                self.sync_active = false;
                const consumed = try self.feedDirect(buffered, false);
                if (consumed != buffered.len) return error.InvalidParserState;
            }
        }
    }

    pub fn feedWithStats(self: *Grid, bytes: []const u8, stats: *FeedStats) !void {
        const previous_stats = self.feed_stats;
        const previous_mode = self.feed_mode;
        const previous_result = self.feed_result;
        self.feed_stats = stats;
        self.feed_mode = .journal_replay;
        self.feed_result = null;
        defer {
            self.feed_stats = previous_stats;
            self.feed_mode = previous_mode;
            self.feed_result = previous_result;
        }
        try self.feedBytes(bytes);
    }

    fn feedDirect(
        self: *Grid,
        bytes: []const u8,
        stop_on_sync_start: bool,
    ) !usize {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x18 or b == 0x1a) {
                self.cancelControlSequence();
                i += 1;
                continue;
            }
            switch (self.state) {
                .normal => {
                    if (self.utf8_len != 0) {
                        const consumed = try self.completePendingUtf8(bytes[i..]);
                        i += consumed;
                        continue;
                    }
                    if (b == 0x1b) {
                        self.last_printable_idx = null;
                        self.state = .escape;
                        i += 1;
                        continue;
                    }
                    const expected = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    if (expected > 1 and i + expected > bytes.len) {
                        const tail = bytes[i..];
                        @memcpy(self.utf8_buffer[0..tail.len], tail);
                        self.utf8_len = @intCast(tail.len);
                        self.utf8_expected = expected;
                        return bytes.len;
                    }
                    i += try self.writeByte(bytes, i);
                },
                .escape => {
                    try self.dispatchEscape(b);
                    i += 1;
                },
                .csi => {
                    if ((b == '?' or b == '>' or b == '<' or b == '=') and
                        self.csi_param_count == 0 and
                        !self.csi_has_digit and
                        self.csi_intermediate_count == 0)
                    {
                        if (self.csi_private == 0) self.csi_private = b;
                        i += 1;
                        continue;
                    }
                    if (b >= '0' and b <= '9') {
                        const slot = &self.csi_params[self.csi_param_count];
                        slot.* = slot.* *| 10 +| @as(u16, b - '0');
                        self.csi_has_digit = true;
                        i += 1;
                        continue;
                    }
                    if (b == ';' or b == ':') {
                        if (self.csi_param_count + 1 >= self.csi_params.len) {
                            return error.TooManyCsiParameters;
                        }
                        self.csi_param_count += 1;
                        self.csi_has_digit = false;
                        i += 1;
                        continue;
                    }
                    if (b >= 0x20 and b <= 0x2f) {
                        if (self.csi_intermediate_count >= self.csi_intermediates.len) {
                            return error.TooManyCsiIntermediates;
                        }
                        self.csi_intermediates[self.csi_intermediate_count] = b;
                        self.csi_intermediate_count += 1;
                        i += 1;
                        continue;
                    }
                    if (b < 0x40 or b > 0x7e) {
                        self.cancelControlSequence();
                        i += 1;
                        continue;
                    }
                    if (self.csi_has_digit or self.csi_param_count > 0) {
                        self.csi_param_count += 1;
                    }
                    try self.dispatchCsi(b);
                    self.state = .normal;
                    i += 1;
                    if (stop_on_sync_start and self.sync_active) return i;
                },
                .osc => {
                    if (b == 0x07) {
                        try self.dispatchOscAndFinish();
                    } else if (b == 0x1b) {
                        self.osc_saw_esc = true;
                    } else if (self.osc_saw_esc and b == '\\') {
                        try self.dispatchOscAndFinish();
                    } else {
                        if (self.osc_saw_esc) {
                            try appendBounded(&self.osc_buffer, self.alloc, 0x1b, max_string_bytes);
                            self.osc_saw_esc = false;
                        }
                        try appendBounded(&self.osc_buffer, self.alloc, b, max_string_bytes);
                    }
                    i += 1;
                },
                .dcs => {
                    if (b == 0x1b) {
                        self.dcs_saw_esc = true;
                    } else if (self.dcs_saw_esc and b == '\\') {
                        try self.dispatchDcsAndFinish();
                    } else {
                        if (self.dcs_saw_esc) {
                            try appendBounded(&self.dcs_buffer, self.alloc, 0x1b, max_string_bytes);
                            self.dcs_saw_esc = false;
                        }
                        try appendBounded(&self.dcs_buffer, self.alloc, b, max_string_bytes);
                    }
                    i += 1;
                },
            }
        }
        return i;
    }

    fn dispatchEscape(self: *Grid, byte: u8) !void {
        switch (byte) {
            '[' => {
                self.resetCsi();
                self.state = .csi;
            },
            ']' => {
                self.osc_saw_esc = false;
                self.osc_buffer.clearRetainingCapacity();
                self.state = .osc;
            },
            'P' => {
                self.dcs_saw_esc = false;
                self.dcs_buffer.clearRetainingCapacity();
                self.state = .dcs;
            },
            '7' => {
                self.saveCursor();
                self.state = .normal;
            },
            '8' => {
                self.restoreCursor();
                self.state = .normal;
            },
            'D' => {
                self.pending_wrap = false;
                self.advanceRowOrScroll();
                self.state = .normal;
            },
            'E' => {
                self.pending_wrap = false;
                self.cursor_col = 1;
                self.advanceRowOrScroll();
                self.state = .normal;
            },
            'M' => {
                self.pending_wrap = false;
                self.reverseIndex();
                self.state = .normal;
            },
            'H' => {
                self.tab_stops[self.cursor_col - 1] = true;
                self.state = .normal;
            },
            '=' => {
                self.application_keypad = true;
                self.state = .normal;
            },
            '>' => {
                self.application_keypad = false;
                self.state = .normal;
            },
            'c' => {
                self.resetTerminal();
                self.state = .normal;
            },
            '\\' => self.state = .normal,
            else => self.state = .normal,
        }
    }

    fn resetCsi(self: *Grid) void {
        self.csi_params = [_]u16{0} ** max_csi_params;
        self.csi_param_count = 0;
        self.csi_has_digit = false;
        self.csi_private = 0;
        self.csi_intermediates = [_]u8{0} ** max_csi_intermediates;
        self.csi_intermediate_count = 0;
    }

    fn completePendingUtf8(self: *Grid, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;
        if (bytes[0] & 0xc0 != 0x80) {
            self.utf8_len = 0;
            self.utf8_expected = 0;
            _ = try self.writeByte("\xef\xbf\xbd", 0);
            return 0;
        }
        const needed = self.utf8_expected - self.utf8_len;
        const count = @min(bytes.len, needed);
        @memcpy(
            self.utf8_buffer[self.utf8_len .. self.utf8_len + count],
            bytes[0..count],
        );
        self.utf8_len += @intCast(count);
        if (self.utf8_len != self.utf8_expected) return count;
        const complete = self.utf8_buffer[0..self.utf8_len];
        self.utf8_len = 0;
        self.utf8_expected = 0;
        if (!std.unicode.utf8ValidateSlice(complete)) {
            _ = try self.writeByte("\xef\xbf\xbd", 0);
        } else {
            _ = try self.writeByte(complete, 0);
        }
        return count;
    }

    fn dispatchDcsAndFinish(self: *Grid) !void {
        defer self.cancelControlSequence();
        const payload = self.dcs_buffer.items;
        if (!std.mem.startsWith(u8, payload, "$q")) return;
        const query = payload[2..];
        if (std.mem.eql(u8, query, "m")) {
            try self.appendReply("\x1bP1$r0m\x1b\\");
        } else if (std.mem.eql(u8, query, "r")) {
            var buffer: [64]u8 = undefined;
            const reply = try std.fmt.bufPrint(
                &buffer,
                "\x1bP1$r{d};{d}r\x1b\\",
                .{ self.scroll_top, self.scroll_bottom },
            );
            try self.appendReply(reply);
        } else {
            try self.appendReply("\x1bP0$r\x1b\\");
        }
    }

    fn appendReply(self: *Grid, bytes: []const u8) !void {
        if (self.feed_mode != .native_live) return;
        const result = self.feed_result orelse return error.InvalidFeedMode;
        if (bytes.len == 0 or bytes.len > max_reply_effect_bytes or
            result.replies.items.len >= max_reply_effects or
            result.reply_bytes > max_reply_effect_total_bytes - bytes.len)
        {
            return error.ReplyEffectCapacityExceeded;
        }
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);
        try result.replies.append(self.alloc, .{ .bytes = owned });
        result.reply_bytes += bytes.len;
    }

    fn cancelControlSequence(self: *Grid) void {
        self.state = .normal;
        self.resetCsi();
        self.osc_saw_esc = false;
        self.osc_buffer.clearRetainingCapacity();
        self.dcs_saw_esc = false;
        self.dcs_buffer.clearRetainingCapacity();
    }

    fn dispatchOscAndFinish(self: *Grid) !void {
        defer self.cancelControlSequence();
        try self.dispatchOsc();
    }

    /// Handles terminated OSC 8 payloads and ignores other OSC codes.
    /// Empty URIs close the active link; non-empty URIs open one.
    fn dispatchOsc(self: *Grid) !void {
        const payload = self.osc_buffer.items;
        if (payload.len < 2 or payload[0] != '8' or payload[1] != ';') return;
        // Skip params section (between the two `;`).
        var i: usize = 2;
        while (i < payload.len and payload[i] != ';') : (i += 1) {}
        if (i >= payload.len) return;
        const params = payload[2..i];
        const uri = payload[i + 1 ..];
        if (uri.len == 0) {
            self.clearActiveHyperlink();
            return;
        }

        const owned_params = if (params.len > 0)
            try self.alloc.dupe(u8, params)
        else
            &.{};
        errdefer if (owned_params.len > 0) self.alloc.free(owned_params);

        // Reuse an existing pool entry when the same URL appears
        // again so cells under one logical link share an id.
        for (self.hyperlink_pool.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, uri)) {
                self.replaceActiveHyperlinkParams(owned_params);
                self.current_style.hyperlink_id = @intCast(idx + 1);
                return;
            }
        }
        if (uri.len > max_string_bytes or
            self.hyperlink_pool.items.len >= max_pool_entries or
            self.hyperlink_pool_bytes > max_hyperlink_pool_bytes - uri.len)
        {
            return error.HyperlinkPoolCapacityExceeded;
        }
        const dup = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(dup);
        try self.hyperlink_pool.ensureUnusedCapacity(self.alloc, 1);
        self.hyperlink_pool.appendAssumeCapacity(dup);
        self.hyperlink_pool_bytes += dup.len;
        self.replaceActiveHyperlinkParams(owned_params);
        self.current_style.hyperlink_id = @intCast(self.hyperlink_pool.items.len);
    }

    fn clearActiveHyperlink(self: *Grid) void {
        self.replaceActiveHyperlinkParams(&.{});
        self.current_style.hyperlink_id = 0;
    }

    fn replaceActiveHyperlinkParams(self: *Grid, params: []const u8) void {
        if (self.active_hyperlink_params.len > 0) {
            self.alloc.free(self.active_hyperlink_params);
        }
        self.active_hyperlink_params = params;
    }

    /// Look up the URL string for a `Style.hyperlink_id`, or `null` for
    /// the sentinel zero id.
    pub fn hyperlinkUrl(self: Grid, id: u32) ?[]const u8 {
        if (id == 0) return null;
        if (id - 1 >= self.hyperlink_pool.items.len) return null;
        return self.hyperlink_pool.items[id - 1];
    }

    pub fn combiningSuffix(self: Grid, id: u32) ?[]const u8 {
        if (id == 0) return null;
        if (id - 1 >= self.combining_suffix_pool.items.len) return null;
        return self.combining_suffix_pool.items[id - 1];
    }

    fn appendCombiningSuffix(self: *Grid, cell_idx: usize, bytes: []const u8) !void {
        const existing = self.combiningSuffix(self.cells[cell_idx].combining_suffix_id) orelse &.{};
        const combined_len = std.math.add(usize, existing.len, bytes.len) catch
            return error.CombiningPoolCapacityExceeded;
        for (self.combining_suffix_pool.items, 0..) |candidate, idx| {
            if (candidate.len == combined_len and
                std.mem.startsWith(u8, candidate, existing) and
                std.mem.eql(u8, candidate[existing.len..], bytes))
            {
                self.cells[cell_idx].combining_suffix_id = @intCast(idx + 1);
                return;
            }
        }
        if (combined_len > contracts.max_cell_text_bytes or
            self.combining_suffix_pool.items.len >= max_pool_entries or
            self.combining_pool_bytes > max_combining_pool_bytes - combined_len)
        {
            return error.CombiningPoolCapacityExceeded;
        }

        const combined = try self.alloc.alloc(u8, combined_len);
        errdefer self.alloc.free(combined);
        @memcpy(combined[0..existing.len], existing);
        @memcpy(combined[existing.len..], bytes);
        try self.combining_suffix_pool.append(self.alloc, combined);
        self.combining_pool_bytes += combined.len;
        self.cells[cell_idx].combining_suffix_id = @intCast(self.combining_suffix_pool.items.len);
    }

    pub fn atControlSequenceBoundary(self: Grid) bool {
        return self.state == .normal and !self.sync_active;
    }

    pub fn restorePresentationBoundary(
        self: *Grid,
        resume_bytes: []const u8,
        cursor_col: u16,
        pending_wrap: bool,
    ) !void {
        std.debug.assert(self.atControlSequenceBoundary());
        try self.feed(resume_bytes);
        if (!self.atControlSequenceBoundary()) return error.InvalidTranscriptTransition;
        self.cursor_col = @min(@max(cursor_col, 1), self.cols);
        self.pending_wrap = pending_wrap;
    }

    pub fn writePresentationResume(self: Grid, out: *std.Io.Writer) !void {
        var presentation = self.current_style;
        const hyperlink_id = presentation.hyperlink_id;
        presentation.hyperlink_id = 0;
        if (!presentation.eql(.{})) try emitSgrTransition(out, presentation);
        if (hyperlink_id != 0) {
            if (self.hyperlinkUrl(hyperlink_id)) |url| {
                try emitHyperlinkOpen(
                    out,
                    self.active_hyperlink_params,
                    url,
                );
            }
        }
    }

    pub fn writePresentationSteady(self: Grid, out: *std.Io.Writer) !void {
        var presentation = self.current_style;
        const hyperlink_id = presentation.hyperlink_id;
        presentation.hyperlink_id = 0;
        if (hyperlink_id != 0) {
            try emitHyperlinkTransition(out, self, hyperlink_id, 0);
        }
        if (!presentation.eql(.{})) try out.writeAll("\x1b[0m");
        if (self.pending_wrap) try out.writeByte('\r');
    }

    pub fn copyPresentationStateFrom(self: *Grid, source: Grid) !void {
        const params = if (source.active_hyperlink_params.len > 0)
            try self.alloc.dupe(u8, source.active_hyperlink_params)
        else
            &.{};
        self.replaceActiveHyperlinkParams(params);
        self.current_style = source.current_style;
    }

    /// Preserve the normal terminal buffer saved by DECSET ?1049 when
    /// cloning the currently active alternate buffer for a frame commit.
    pub fn copySavedNormalScreenFrom(self: *Grid, source: Grid) !void {
        std.debug.assert(self.saved_normal_screen == null);
        const saved = source.saved_normal_screen orelse return;
        self.saved_normal_screen = try saved.dupe(self.alloc);
    }

    /// Write one control byte or Unicode display unit. Returns the
    /// number of source bytes consumed.
    fn writeByte(self: *Grid, bytes: []const u8, start: usize) !usize {
        const b = bytes[start];

        switch (b) {
            '\n' => {
                self.last_printable_idx = null;
                self.pending_wrap = false;
                self.cursor_col = 1;
                self.advanceRowOrScroll();
                return 1;
            },
            '\r' => {
                self.last_printable_idx = null;
                self.pending_wrap = false;
                self.cursor_col = 1;
                return 1;
            },
            0x08 => {
                self.last_printable_idx = null;
                self.pending_wrap = false;
                if (self.cursor_col > 1) self.cursor_col -= 1;
                return 1;
            },
            '\t' => {
                self.last_printable_idx = null;
                self.pending_wrap = false;
                self.moveTabsForward(1);
                return 1;
            },
            0x07 => {
                self.last_printable_idx = null;
                return 1;
            },
            else => {
                if (b < 0x20) {
                    self.last_printable_idx = null;
                    return 1;
                }
            },
        }

        const unit = display_width.displayUnitAt(bytes, start);
        const decoded = decodeUtf8(bytes, start);
        const codepoint = decoded.codepoint;
        const consumed = unit.byte_len;
        const width: u8 = @intCast(unit.cell_width);

        if (width == 0) {
            if (self.last_printable_idx) |idx| {
                try self.appendCombiningSuffix(idx, bytes[start .. start + consumed]);
            }
            return consumed;
        }
        self.last_printable_idx = null;

        // Apply any deferred wrap before writing.
        if (self.pending_wrap and self.autowrap) {
            self.cursor_col = 1;
            self.advanceRowOrScroll();
        }
        self.pending_wrap = false;

        // Wide char that doesn't fit: wrap early (autowrap) or clamp.
        if (self.cursor_col + width - 1 > self.cols) {
            if (self.autowrap) {
                self.cursor_col = 1;
                self.advanceRowOrScroll();
            } else if (self.cols >= width) {
                self.cursor_col = self.cols - width + 1;
            } else {
                return consumed;
            }
        }

        if (self.cursor_row >= 1 and self.cursor_row <= self.rows and self.cursor_col >= 1 and self.cursor_col <= self.cols) {
            if (self.insert_mode) self.insertCells(width);
            self.markTouchedRow(self.cursor_row);
            const idx = self.cellIndex(self.cursor_row, self.cursor_col);
            self.clearWideGlyphAt(self.cursor_row, self.cursor_col);
            if (width == 2) self.clearWideGlyphAt(self.cursor_row, self.cursor_col + 1);
            self.cells[idx] = .{
                .codepoint = codepoint,
                .width = width,
                .style = self.current_style,
            };
            if (decoded.len < consumed) {
                try self.appendCombiningSuffix(idx, bytes[start + decoded.len .. start + consumed]);
            }
            self.last_printable_idx = idx;
            if (width == 2 and self.cursor_col < self.cols) {
                self.cells[idx + 1] = .{
                    .codepoint = 0,
                    .width = 0,
                    .style = self.current_style,
                };
            }
        }

        if (self.cursor_col + width <= self.cols) {
            self.cursor_col += width;
        } else {
            // Cursor ends at the last column. Defer wrap until the
            // next printable write (lazy-wrap).
            self.cursor_col = self.cols;
            if (self.autowrap) self.pending_wrap = true;
        }

        return consumed;
    }

    fn advanceRowOrScroll(self: *Grid) void {
        if (self.cursor_row == self.scroll_bottom) {
            self.scrollUp(self.scroll_top, self.scroll_bottom, 1);
            return;
        }
        if (self.cursor_row < self.rows) {
            self.cursor_row += 1;
        }
    }

    fn reverseIndex(self: *Grid) void {
        if (self.cursor_row == self.scroll_top) {
            self.scrollDown(self.scroll_top, self.scroll_bottom, 1);
        } else if (self.cursor_row > 1) {
            self.cursor_row -= 1;
        }
    }

    fn scrollUp(self: *Grid, top: u16, bottom: u16, requested: u16) void {
        if (top == 0 or bottom < top or bottom > self.rows) return;
        const count = @min(requested, bottom - top + 1);
        if (count == 0) return;
        if (self.feed_stats) |stats| {
            stats.scrolled = true;
            stats.scroll_rows +|= count;
            stats.touchRow(bottom);
        }
        if (top == 1 and bottom == self.rows and count == 1) {
            self.row_origin += 1;
            if (self.row_origin == self.rows) self.row_origin = 0;
            const last_base = self.rowBase(self.rows);
            @memset(self.cells[last_base .. last_base + self.cols], self.blankCell());
            return;
        }
        var row = top;
        while (row + count <= bottom) : (row += 1) {
            const destination = self.rowBase(row);
            const source = self.rowBase(row + count);
            @memcpy(
                self.cells[destination .. destination + self.cols],
                self.cells[source .. source + self.cols],
            );
        }
        while (row <= bottom) : (row += 1) {
            const base = self.rowBase(row);
            @memset(self.cells[base .. base + self.cols], self.blankCell());
        }
    }

    fn scrollDown(self: *Grid, top: u16, bottom: u16, requested: u16) void {
        if (top == 0 or bottom < top or bottom > self.rows) return;
        const count = @min(requested, bottom - top + 1);
        if (count == 0) return;
        self.markTouchedRows(top, bottom);
        var row = bottom;
        while (row >= top + count) : (row -= 1) {
            const destination = self.rowBase(row);
            const source = self.rowBase(row - count);
            @memcpy(
                self.cells[destination .. destination + self.cols],
                self.cells[source .. source + self.cols],
            );
        }
        var clear_row = top;
        while (clear_row < top + count) : (clear_row += 1) {
            const base = self.rowBase(clear_row);
            @memset(self.cells[base .. base + self.cols], self.blankCell());
        }
    }

    fn param(self: Grid, index: usize, default: u16) u16 {
        if (index >= self.csi_param_count) return default;
        const v = self.csi_params[index];
        if (v == 0 and !self.csi_has_digit and index + 1 == self.csi_param_count) return default;
        return if (v == 0) default else v;
    }

    fn paramRaw(self: Grid, index: usize, default: u16) u16 {
        if (index >= self.csi_param_count) return default;
        return self.csi_params[index];
    }

    fn dispatchCsi(self: *Grid, final: u8) !void {
        switch (final) {
            'H', 'f' => self.positionCursor(
                self.param(0, 1),
                self.param(1, 1),
            ),
            'A' => {
                self.cursor_row = clampSub(
                    self.cursor_row,
                    self.param(0, 1),
                    self.cursorTop(),
                );
                self.pending_wrap = false;
            },
            'B' => {
                self.cursor_row = clamp(
                    self.cursor_row +| self.param(0, 1),
                    self.cursorTop(),
                    self.cursorBottom(),
                );
                self.pending_wrap = false;
            },
            'C' => {
                self.cursor_col = clamp(self.cursor_col +| self.param(0, 1), 1, self.cols);
                self.pending_wrap = false;
            },
            'D' => {
                self.cursor_col = clampSub(self.cursor_col, self.param(0, 1), 1);
                self.pending_wrap = false;
            },
            'E' => {
                self.cursor_row = clamp(
                    self.cursor_row +| self.param(0, 1),
                    self.cursorTop(),
                    self.cursorBottom(),
                );
                self.cursor_col = 1;
                self.pending_wrap = false;
            },
            'F' => {
                self.cursor_row = clampSub(
                    self.cursor_row,
                    self.param(0, 1),
                    self.cursorTop(),
                );
                self.cursor_col = 1;
                self.pending_wrap = false;
            },
            'G', '`' => {
                self.cursor_col = clamp(self.param(0, 1), 1, self.cols);
                self.pending_wrap = false;
            },
            'd' => {
                self.cursor_row = clamp(self.param(0, 1), 1, self.rows);
                self.pending_wrap = false;
            },
            'a' => {
                self.cursor_col = clamp(self.cursor_col +| self.param(0, 1), 1, self.cols);
                self.pending_wrap = false;
            },
            'e' => {
                self.cursor_row = clamp(
                    self.cursor_row +| self.param(0, 1),
                    self.cursorTop(),
                    self.cursorBottom(),
                );
                self.pending_wrap = false;
            },
            'J' => try self.eraseDisplay(self.paramRaw(0, 0)),
            'K' => try self.eraseLine(self.paramRaw(0, 0)),
            '@' => self.insertCells(self.param(0, 1)),
            'P' => self.deleteCells(self.param(0, 1)),
            'X' => self.eraseCells(self.param(0, 1)),
            'L' => self.insertLines(self.param(0, 1)),
            'M' => self.deleteLines(self.param(0, 1)),
            'S' => self.scrollUp(self.scroll_top, self.scroll_bottom, self.param(0, 1)),
            'T' => self.scrollDown(self.scroll_top, self.scroll_bottom, self.param(0, 1)),
            'I' => self.moveTabsForward(self.param(0, 1)),
            'Z' => self.moveTabsBackward(self.param(0, 1)),
            'g' => self.clearTabStops(self.paramRaw(0, 0)),
            'm' => if (self.csi_private == 0) try self.applySgr(),
            'h', 'l' => try self.decSetReset(final == 'h'),
            'n' => try self.deviceStatusReport(),
            'c' => try self.deviceAttributes(),
            'r' => self.setScrollRegion(),
            's' => self.saveCursor(),
            'u' => {
                if (self.csi_private == 0) {
                    self.restoreCursor();
                } else {
                    self.keyboard_protocol = self.csi_private != '<' and
                        self.paramRaw(0, 0) != 0;
                }
            },
            't' => try self.windowQuery(),
            'q' => if (self.csi_intermediate_count == 1 and
                self.csi_intermediates[0] == ' ')
            {
                self.setCursorStyle(self.paramRaw(0, 0));
            },
            else => {},
        }
    }

    fn cursorTop(self: Grid) u16 {
        return if (self.origin_mode) self.scroll_top else 1;
    }

    fn cursorBottom(self: Grid) u16 {
        return if (self.origin_mode) self.scroll_bottom else self.rows;
    }

    fn positionCursor(self: *Grid, row: u16, col: u16) void {
        const top = self.cursorTop();
        const bottom = self.cursorBottom();
        const absolute_row = if (self.origin_mode) top +| (row -| 1) else row;
        self.cursor_row = clamp(absolute_row, top, bottom);
        self.cursor_col = clamp(col, 1, self.cols);
        self.pending_wrap = false;
    }

    fn saveCursor(self: *Grid) void {
        self.saved_cursor = .{
            .row = self.cursor_row,
            .col = self.cursor_col,
            .pending_wrap = self.pending_wrap,
            .style = self.current_style,
            .origin_mode = self.origin_mode,
        };
    }

    fn restoreCursor(self: *Grid) void {
        const saved = self.saved_cursor orelse return;
        self.cursor_row = clamp(saved.row, 1, self.rows);
        self.cursor_col = clamp(saved.col, 1, self.cols);
        self.pending_wrap = saved.pending_wrap;
        self.current_style = saved.style;
        self.origin_mode = saved.origin_mode;
    }

    fn setScrollRegion(self: *Grid) void {
        if (self.csi_private != 0) return;
        const top = clamp(self.param(0, 1), 1, self.rows);
        const bottom = clamp(self.param(1, self.rows), 1, self.rows);
        if (top >= bottom) return;
        self.scroll_top = top;
        self.scroll_bottom = bottom;
        self.positionCursor(1, 1);
    }

    fn insertCells(self: *Grid, requested: u16) void {
        const count = @min(requested, self.cols - self.cursor_col + 1);
        if (count == 0) return;
        self.markTouchedRow(self.cursor_row);
        const base = self.rowBase(self.cursor_row);
        const start = base + self.cursor_col - 1;
        const end = base + self.cols;
        std.mem.copyBackwards(
            Cell,
            self.cells[start + count .. end],
            self.cells[start .. end - count],
        );
        @memset(self.cells[start .. start + count], self.blankCell());
        repairWideCells(self.cells[base .. base + self.cols], self.cols, 1);
        self.pending_wrap = false;
        self.last_printable_idx = null;
    }

    fn deleteCells(self: *Grid, requested: u16) void {
        const count = @min(requested, self.cols - self.cursor_col + 1);
        if (count == 0) return;
        self.markTouchedRow(self.cursor_row);
        const base = self.rowBase(self.cursor_row);
        const start = base + self.cursor_col - 1;
        const end = base + self.cols;
        std.mem.copyForwards(
            Cell,
            self.cells[start .. end - count],
            self.cells[start + count .. end],
        );
        @memset(self.cells[end - count .. end], self.blankCell());
        repairWideCells(self.cells[base .. base + self.cols], self.cols, 1);
        self.pending_wrap = false;
        self.last_printable_idx = null;
    }

    fn eraseCells(self: *Grid, requested: u16) void {
        const count = @min(requested, self.cols - self.cursor_col + 1);
        if (count == 0) return;
        const start = (@as(usize, self.cursor_row) - 1) * self.cols +
            self.cursor_col - 1;
        self.eraseRange(start, start + count);
        self.markTouchedRow(self.cursor_row);
        self.pending_wrap = false;
        self.last_printable_idx = null;
    }

    fn insertLines(self: *Grid, requested: u16) void {
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
        self.scrollDown(self.cursor_row, self.scroll_bottom, requested);
        self.pending_wrap = false;
        self.last_printable_idx = null;
    }

    fn deleteLines(self: *Grid, requested: u16) void {
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
        self.scrollUp(self.cursor_row, self.scroll_bottom, requested);
        self.pending_wrap = false;
        self.last_printable_idx = null;
    }

    fn moveTabsForward(self: *Grid, requested: u16) void {
        var remaining = requested;
        while (remaining != 0) : (remaining -= 1) {
            var column = self.cursor_col +| 1;
            while (column < self.cols and !self.tab_stops[column - 1]) : (column += 1) {}
            self.cursor_col = @min(column, self.cols);
        }
        self.pending_wrap = false;
    }

    fn moveTabsBackward(self: *Grid, requested: u16) void {
        var remaining = requested;
        while (remaining != 0) : (remaining -= 1) {
            if (self.cursor_col <= 1) break;
            var column = self.cursor_col - 1;
            while (column > 1 and !self.tab_stops[column - 1]) : (column -= 1) {}
            self.cursor_col = column;
        }
        self.pending_wrap = false;
    }

    fn clearTabStops(self: *Grid, mode: u16) void {
        switch (mode) {
            0 => self.tab_stops[self.cursor_col - 1] = false,
            3 => @memset(self.tab_stops, false),
            else => {},
        }
    }

    fn deviceStatusReport(self: *Grid) !void {
        const report = self.paramRaw(0, 0);
        if (report == 5 and self.csi_private == 0) {
            try self.appendReply("\x1b[0n");
            return;
        }
        if (report != 6) return;
        const row = if (self.origin_mode)
            self.cursor_row - self.scroll_top + 1
        else
            self.cursor_row;
        var buffer: [64]u8 = undefined;
        const reply = if (self.csi_private == '?')
            try std.fmt.bufPrint(&buffer, "\x1b[?{d};{d}R", .{ row, self.cursor_col })
        else
            try std.fmt.bufPrint(&buffer, "\x1b[{d};{d}R", .{ row, self.cursor_col });
        try self.appendReply(reply);
    }

    fn deviceAttributes(self: *Grid) !void {
        if (self.csi_private == '>') {
            try self.appendReply("\x1b[>0;0;0c");
        } else if (self.csi_private == 0) {
            try self.appendReply("\x1b[?1;2c");
        }
    }

    fn windowQuery(self: *Grid) !void {
        var buffer: [64]u8 = undefined;
        const reply = switch (self.paramRaw(0, 0)) {
            14 => "\x1b[4;0;0t",
            16 => "\x1b[6;0;0t",
            18 => try std.fmt.bufPrint(
                &buffer,
                "\x1b[8;{d};{d}t",
                .{ self.rows, self.cols },
            ),
            19 => try std.fmt.bufPrint(
                &buffer,
                "\x1b[9;{d};{d}t",
                .{ self.rows, self.cols },
            ),
            else => return,
        };
        try self.appendReply(reply);
    }

    fn setCursorStyle(self: *Grid, value: u16) void {
        switch (value) {
            0, 1 => {
                self.cursor_shape = .block;
                self.cursor_blinking = true;
            },
            2 => {
                self.cursor_shape = .block;
                self.cursor_blinking = false;
            },
            3 => {
                self.cursor_shape = .underline;
                self.cursor_blinking = true;
            },
            4 => {
                self.cursor_shape = .underline;
                self.cursor_blinking = false;
            },
            5 => {
                self.cursor_shape = .bar;
                self.cursor_blinking = true;
            },
            6 => {
                self.cursor_shape = .bar;
                self.cursor_blinking = false;
            },
            else => {},
        }
    }

    /// Produce a blank cell in the current erase-style — space
    /// glyph with default fg/flags but the cursor's active bg.
    /// Real terminals extend the current bg into erased cells; fx's
    /// user-message card relies on that behaviour to draw the bar
    /// without having to pad with literal spaces.
    fn blankCell(self: Grid) Cell {
        return .{
            .codepoint = ' ',
            .width = 1,
            .style = .{ .bg = self.current_style.bg },
        };
    }

    fn clearWideGlyphAt(self: *Grid, row: u16, col: u16) void {
        if (row == 0 or row > self.rows or col == 0 or col > self.cols) return;
        const idx = self.cellIndex(row, col);
        const blank = self.blankCell();
        switch (self.cells[idx].width) {
            0 => {
                if (col > 1 and self.cells[idx - 1].width == 2) {
                    self.cells[idx - 1] = blank;
                }
                self.cells[idx] = blank;
            },
            2 => {
                self.cells[idx] = blank;
                if (col < self.cols and self.cells[idx + 1].width == 0) {
                    self.cells[idx + 1] = blank;
                }
            },
            else => {},
        }
    }

    fn eraseRange(self: *Grid, start: usize, end: usize) void {
        std.debug.assert(start <= end and end <= self.cells.len);
        var expanded_start = start;
        var expanded_end = end;
        const cols: usize = self.cols;
        if (expanded_start < expanded_end and
            expanded_start % cols != 0 and
            self.cells[self.physicalIndexForLogicalOffset(expanded_start)].width == 0)
        {
            expanded_start -= 1;
        }
        if (expanded_end > expanded_start and
            expanded_end < self.cells.len and
            expanded_end % cols != 0 and
            self.cells[self.physicalIndexForLogicalOffset(expanded_end - 1)].width == 2)
        {
            expanded_end += 1;
        }
        const blank = self.blankCell();
        var logical = expanded_start;
        while (logical < expanded_end) {
            const col = logical % cols;
            const chunk_len = @min(cols - col, expanded_end - logical);
            const physical = self.physicalIndexForLogicalOffset(logical);
            @memset(self.cells[physical .. physical + chunk_len], blank);
            logical += chunk_len;
        }
    }

    fn eraseDisplay(self: *Grid, mode: u16) !void {
        const total: usize = @as(usize, self.rows) * @as(usize, self.cols);
        switch (mode) {
            0 => {
                self.markTouchedRows(self.cursor_row, self.rows);
                const start = (@as(usize, self.cursor_row) - 1) * @as(usize, self.cols) + (@as(usize, self.cursor_col) - 1);
                self.eraseRange(start, total);
            },
            1 => {
                self.markTouchedRows(1, self.cursor_row);
                const end = (@as(usize, self.cursor_row) - 1) * @as(usize, self.cols) + @as(usize, self.cursor_col);
                self.eraseRange(0, end);
            },
            2 => {
                self.markTouchedRows(1, self.rows);
                self.eraseRange(0, total);
            },
            3 => {
                // ED 3 clears scrollback only; this emulator has no scrollback model.
            },
            else => {},
        }
    }

    fn eraseLine(self: *Grid, mode: u16) !void {
        const row_base = (@as(usize, self.cursor_row) - 1) * @as(usize, self.cols);
        switch (mode) {
            0 => {
                self.markTouchedRow(self.cursor_row);
                const start = row_base + (@as(usize, self.cursor_col) - 1);
                self.eraseRange(start, row_base + @as(usize, self.cols));
            },
            1 => {
                self.markTouchedRow(self.cursor_row);
                const end = row_base + @as(usize, self.cursor_col);
                self.eraseRange(row_base, end);
            },
            2 => {
                self.markTouchedRow(self.cursor_row);
                self.eraseRange(row_base, row_base + @as(usize, self.cols));
            },
            else => {},
        }
    }

    fn markTouchedRow(self: *Grid, row: u16) void {
        if (self.feed_stats) |stats| stats.touchRow(row);
    }

    fn markTouchedRows(self: *Grid, top: u16, bottom: u16) void {
        if (top == 0 or bottom == 0 or bottom < top) return;
        if (self.feed_stats) |stats| stats.touchRow(bottom);
    }

    /// Applies supported SGR attributes and palette, indexed, or truecolor values.
    /// Unknown codes are ignored; an empty parameter list performs a full reset.
    fn applySgr(self: *Grid) !void {
        if (self.csi_param_count == 0) {
            self.resetSgrPresentation();
            return;
        }
        var i: usize = 0;
        while (i < self.csi_param_count) {
            const p = self.csi_params[i];
            switch (p) {
                0 => self.resetSgrPresentation(),
                1 => self.current_style.flags.bold = true,
                2 => self.current_style.flags.dim = true,
                3 => self.current_style.flags.italic = true,
                4 => self.current_style.flags.underline = true,
                7 => self.current_style.flags.reverse = true,
                9 => self.current_style.flags.strike = true,
                22 => {
                    self.current_style.flags.bold = false;
                    self.current_style.flags.dim = false;
                },
                23 => self.current_style.flags.italic = false,
                24 => self.current_style.flags.underline = false,
                27 => self.current_style.flags.reverse = false,
                29 => self.current_style.flags.strike = false,
                30...37 => self.current_style.fg = .{ .indexed = @intCast(p - 30) },
                38 => if (self.extendedColorAt(i)) |ext| {
                    self.current_style.fg = ext.color;
                    i += ext.consumed;
                    continue;
                },
                39 => self.current_style.fg = .default,
                40...47 => self.current_style.bg = .{ .indexed = @intCast(p - 40) },
                48 => if (self.extendedColorAt(i)) |ext| {
                    self.current_style.bg = ext.color;
                    i += ext.consumed;
                    continue;
                },
                49 => self.current_style.bg = .default,
                90...97 => self.current_style.fg = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.current_style.bg = .{ .indexed = @intCast(p - 100 + 8) },
                else => {},
            }
            i += 1;
        }
    }

    fn resetSgrPresentation(self: *Grid) void {
        const hyperlink_id = self.current_style.hyperlink_id;
        self.current_style = .{ .hyperlink_id = hyperlink_id };
    }

    const ExtendedColor = struct { color: Color, consumed: usize };

    /// Parse the extended-color params following SGR 38/48: `;5;N`
    /// (indexed) or `;2;R;G;B` (truecolor), starting at param `i`.
    /// Returns null on a malformed spec so the caller consumes only
    /// the introducer.
    fn extendedColorAt(self: Grid, i: usize) ?ExtendedColor {
        if (i + 1 >= self.csi_param_count) return null;
        switch (self.csi_params[i + 1]) {
            5 => {
                if (i + 2 >= self.csi_param_count) return null;
                const n = self.csi_params[i + 2];
                return .{ .color = .{ .indexed = @intCast(@min(n, 255)) }, .consumed = 3 };
            },
            2 => {
                if (i + 4 >= self.csi_param_count) return null;
                return .{ .color = .{ .rgb = .{
                    .r = @intCast(@min(self.csi_params[i + 2], 255)),
                    .g = @intCast(@min(self.csi_params[i + 3], 255)),
                    .b = @intCast(@min(self.csi_params[i + 4], 255)),
                } }, .consumed = 5 };
            },
            else => return null,
        }
    }

    fn decSetReset(self: *Grid, set: bool) !void {
        if (self.csi_private == 0) {
            var standard_index: usize = 0;
            while (standard_index < self.csi_param_count) : (standard_index += 1) {
                if (self.csi_params[standard_index] == 4) self.insert_mode = set;
            }
            return;
        }
        if (self.csi_private != '?') return;
        var i: usize = 0;
        while (i < self.csi_param_count) : (i += 1) {
            const p = self.csi_params[i];
            switch (p) {
                1 => self.application_cursor_keys = set,
                6 => {
                    self.origin_mode = set;
                    self.positionCursor(1, 1);
                },
                7 => self.autowrap = set,
                25 => self.cursor_visible = set,
                47, 1047, 1049 => if (set)
                    try self.enterAlternateScreen()
                else
                    self.leaveAlternateScreen(),
                1000 => self.setMouseMode(0, set),
                1002 => self.setMouseMode(1, set),
                1003 => self.setMouseMode(2, set),
                1005 => self.setMouseMode(3, set),
                1006 => self.setMouseMode(4, set),
                1015 => self.setMouseMode(5, set),
                1004 => self.focus_tracking = set,
                2004 => self.bracketed_paste = set,
                2026 => self.sync_active = set,
                else => {},
            }
        }
    }

    fn setMouseMode(self: *Grid, bit: u4, set: bool) void {
        const mask = @as(u16, 1) << bit;
        if (set) {
            self.mouse_modes |= mask;
        } else {
            self.mouse_modes &= ~mask;
        }
    }

    fn resetTerminal(self: *Grid) void {
        if (self.saved_normal_screen != null) self.leaveAlternateScreen();
        @memset(self.cells, .{});
        self.row_origin = 0;
        self.cursor_row = 1;
        self.cursor_col = 1;
        self.autowrap = true;
        self.pending_wrap = false;
        self.cursor_visible = true;
        self.cursor_shape = .block;
        self.cursor_blinking = true;
        self.scroll_top = 1;
        self.scroll_bottom = self.rows;
        self.origin_mode = false;
        self.insert_mode = false;
        self.bracketed_paste = false;
        self.mouse_modes = 0;
        self.focus_tracking = false;
        self.application_cursor_keys = false;
        self.application_keypad = false;
        self.keyboard_protocol = false;
        self.sync_active = false;
        self.sync_buffer.clearRetainingCapacity();
        self.current_style = .{};
        self.replaceActiveHyperlinkParams(&.{});
        for (self.hyperlink_pool.items) |url| self.alloc.free(url);
        self.hyperlink_pool.clearRetainingCapacity();
        self.hyperlink_pool_bytes = 0;
        for (self.combining_suffix_pool.items) |suffix| self.alloc.free(suffix);
        self.combining_suffix_pool.clearRetainingCapacity();
        self.combining_pool_bytes = 0;
        self.saved_cursor = null;
        self.last_printable_idx = null;
        self.utf8_len = 0;
        self.utf8_expected = 0;
        initializeTabStops(self.tab_stops);
        self.cancelControlSequence();
    }

    fn enterAlternateScreen(self: *Grid) !void {
        if (self.saved_normal_screen != null) return;

        const alternate_cells = try self.alloc.alloc(
            Cell,
            @as(usize, self.cols) * @as(usize, self.rows),
        );
        @memset(alternate_cells, .{});

        self.saved_normal_screen = SavedScreen.capture(self.*);
        self.cells = alternate_cells;
        self.row_origin = 0;
        self.cursor_row = 1;
        self.cursor_col = 1;
        self.autowrap = true;
        self.pending_wrap = false;
        self.cursor_shape = .block;
        self.cursor_blinking = true;
        self.scroll_top = 1;
        self.scroll_bottom = self.rows;
        self.origin_mode = false;
        self.insert_mode = false;
        self.current_style = .{};
        self.active_hyperlink_params = &.{};
        self.last_printable_idx = null;
        self.saved_cursor = null;
    }

    fn leaveAlternateScreen(self: *Grid) void {
        const saved = self.saved_normal_screen orelse return;
        self.alloc.free(self.cells);
        if (self.active_hyperlink_params.len > 0) {
            self.alloc.free(self.active_hyperlink_params);
        }
        saved.restoreTo(self);
        self.saved_normal_screen = null;
    }

    /// Return a copy of the cell at 1-indexed (row, col), or null if
    /// out of bounds. Used by tests asserting on style (fg/bg/flags),
    /// since `rowText` deliberately discards attributes.
    pub fn cellAt(self: Grid, row: u16, col: u16) ?Cell {
        if (row < 1 or row > self.rows) return null;
        if (col < 1 or col > self.cols) return null;
        return self.cells[self.cellIndex(row, col)];
    }

    /// Return an allocator-owned immutable projection. The caller releases it
    /// with `OwnedRenderSnapshot.deinit` using the same allocator.
    pub fn renderSnapshot(
        self: Grid,
        alloc: Allocator,
    ) !contracts.OwnedRenderSnapshot {
        var text_bytes: usize = 0;
        var row: u16 = 1;
        while (row <= self.rows) : (row += 1) {
            const base = self.rowBase(row);
            var col: u16 = 0;
            while (col < self.cols) : (col += 1) {
                const cell = self.cells[base + col];
                if (cell.width == 0 or isBlankCell(cell)) continue;
                var buffer: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(cell.codepoint, &buffer) catch
                    return error.InvalidRenderCell;
                const suffix_len = if (self.combiningSuffix(cell.combining_suffix_id)) |suffix|
                    suffix.len
                else if (cell.combining_suffix_id == 0)
                    0
                else
                    return error.InvalidRenderCell;
                const cell_bytes = std.math.add(usize, encoded_len, suffix_len) catch
                    return error.RenderSnapshotTooLarge;
                if (cell_bytes > contracts.max_cell_text_bytes) {
                    return error.RenderSnapshotTooLarge;
                }
                text_bytes = std.math.add(usize, text_bytes, cell_bytes) catch
                    return error.RenderSnapshotTooLarge;
            }
        }
        const structural_bytes = std.math.mul(
            usize,
            self.cells.len,
            @sizeOf(contracts.RenderCell),
        ) catch return error.RenderSnapshotTooLarge;
        if (structural_bytes > contracts.max_render_snapshot_bytes or
            text_bytes > contracts.max_render_snapshot_bytes - structural_bytes)
        {
            return error.RenderSnapshotTooLarge;
        }

        const cells = try alloc.alloc(contracts.RenderCell, self.cells.len);
        errdefer alloc.free(cells);
        const text_storage = try alloc.alloc(u8, text_bytes);
        errdefer alloc.free(text_storage);

        var text_offset: usize = 0;
        var output_index: usize = 0;
        row = 1;
        while (row <= self.rows) : (row += 1) {
            const base = self.rowBase(row);
            var col: u16 = 0;
            while (col < self.cols) : (col += 1) {
                const cell = self.cells[base + col];
                const kind: contracts.CellKind = switch (cell.width) {
                    0 => .continuation,
                    2 => .wide,
                    else => if (isBlankCell(cell)) .blank else .single,
                };
                var text: []const u8 = "";
                if (kind == .single or kind == .wide) {
                    var buffer: [4]u8 = undefined;
                    const encoded_len = std.unicode.utf8Encode(cell.codepoint, &buffer) catch
                        return error.InvalidRenderCell;
                    const start = text_offset;
                    @memcpy(text_storage[text_offset .. text_offset + encoded_len], buffer[0..encoded_len]);
                    text_offset += encoded_len;
                    if (self.combiningSuffix(cell.combining_suffix_id)) |suffix| {
                        @memcpy(text_storage[text_offset .. text_offset + suffix.len], suffix);
                        text_offset += suffix.len;
                    }
                    text = text_storage[start..text_offset];
                }
                cells[output_index] = .{
                    .kind = kind,
                    .text = text,
                    .style = renderStyle(cell.style),
                };
                output_index += 1;
            }
        }

        var owned = contracts.OwnedRenderSnapshot{
            .dimensions = .{ .rows = self.rows, .columns = self.cols },
            .cursor = .{
                .row = self.cursor_row - 1,
                .column = self.cursor_col - 1,
                .visible = self.cursor_visible,
                .shape = self.cursor_shape,
                .blinking = self.cursor_blinking,
            },
            .modes = .{
                .alternate_screen = self.saved_normal_screen != null,
                .origin = self.origin_mode,
                .autowrap = self.autowrap,
                .insert = self.insert_mode,
                .bracketed_paste = self.bracketed_paste,
                .mouse_tracking = self.mouse_modes != 0,
                .focus_tracking = self.focus_tracking,
                .application_cursor_keys = self.application_cursor_keys,
                .application_keypad = self.application_keypad,
                .keyboard_protocol = self.keyboard_protocol,
                .synchronized_updates = self.sync_active,
            },
            .cells = cells,
            .text_storage = text_storage,
        };
        errdefer owned.deinit(alloc);
        try owned.view().validate();
        return owned;
    }

    /// Serialize all bounded terminal state. The durable store owns cursor
    /// anchoring and wraps these opaque bytes in its checkpoint envelope.
    pub fn checkpointPayload(self: Grid, alloc: Allocator) ![]u8 {
        try self.validateCheckpointState();
        var encoder = CheckpointEncoder.init(alloc);
        errdefer encoder.deinit();
        try encoder.bytes(checkpoint_magic);
        try encoder.int(u16, checkpoint_schema_revision);
        try encodeGridState(&encoder, self);
        return encoder.finish();
    }

    /// Restore an engine payload without performing any I/O or producing
    /// reply effects. Callers replay later journal bytes observationally.
    pub fn restoreCheckpoint(alloc: Allocator, payload: []const u8) !Grid {
        if (payload.len > contracts.max_checkpoint_payload_bytes) {
            return failGrid(error.CheckpointTooLarge);
        }
        var decoder = CheckpointDecoder.init(payload);
        const magic = try decoder.fixed(checkpoint_magic.len);
        if (!std.mem.eql(u8, magic, checkpoint_magic)) {
            return failGrid(error.InvalidEngineCheckpoint);
        }
        if (try decoder.int(u16) != checkpoint_schema_revision) {
            return failGrid(error.UnsupportedEngineRevision);
        }
        var grid = try decodeGridState(alloc, &decoder);
        errdefer grid.deinit();
        if (!decoder.finished()) return failGrid(error.InvalidEngineCheckpoint);
        try grid.validateCheckpointState();
        return grid;
    }

    fn validateCheckpointState(self: Grid) !void {
        if (self.rows == 0 or self.cols == 0 or
            self.cells.len != @as(usize, self.rows) * @as(usize, self.cols) or
            self.row_origin >= self.rows or
            self.cursor_row == 0 or self.cursor_row > self.rows or
            self.cursor_col == 0 or self.cursor_col > self.cols or
            self.scroll_top == 0 or self.scroll_top > self.scroll_bottom or
            self.scroll_bottom > self.rows or
            self.tab_stops.len != self.cols or
            self.csi_param_count > max_csi_params or
            self.csi_intermediate_count > max_csi_intermediates or
            self.osc_buffer.items.len > max_string_bytes or
            self.dcs_buffer.items.len > max_string_bytes or
            self.sync_buffer.items.len > max_sync_bytes or
            self.utf8_len > self.utf8_expected or
            self.utf8_expected > self.utf8_buffer.len or
            self.hyperlink_pool.items.len > max_pool_entries or
            self.combining_suffix_pool.items.len > max_pool_entries or
            self.active_hyperlink_params.len > max_string_bytes)
        {
            return error.InvalidEngineCheckpoint;
        }
        if ((self.state == .csi and self.csi_param_count >= max_csi_params) or
            (self.state != .osc and self.osc_saw_esc) or
            (self.state != .dcs and self.dcs_saw_esc) or
            self.mouse_modes & ~@as(u16, 0x3f) != 0)
        {
            return error.InvalidEngineCheckpoint;
        }
        try validateUtf8Continuation(self);
        try validatePool(self.hyperlink_pool.items, max_hyperlink_pool_bytes);
        try validatePool(self.combining_suffix_pool.items, max_combining_pool_bytes);
        try validateCells(
            self.cells,
            self.cols,
            self.rows,
            self.hyperlink_pool.items.len,
            self.combining_suffix_pool.items.len,
        );
        try validateStyle(
            self.current_style,
            self.hyperlink_pool.items.len,
        );
        if (self.last_printable_idx) |index| {
            if (index >= self.cells.len or self.cells[index].width == 0) {
                return error.InvalidEngineCheckpoint;
            }
        }
        if (self.saved_cursor) |saved| try validateSavedCursor(saved, self);
        if (self.saved_normal_screen) |saved| {
            if (saved.rows != self.rows or saved.cols != self.cols or
                saved.cells.len != self.cells.len or
                saved.row_origin >= saved.rows or
                saved.cursor_row == 0 or saved.cursor_row > saved.rows or
                saved.cursor_col == 0 or saved.cursor_col > saved.cols or
                saved.scroll_top == 0 or
                saved.scroll_top > saved.scroll_bottom or
                saved.scroll_bottom > saved.rows or
                saved.active_hyperlink_params.len > max_string_bytes)
            {
                return error.InvalidEngineCheckpoint;
            }
            try validateCells(
                saved.cells,
                saved.cols,
                saved.rows,
                self.hyperlink_pool.items.len,
                self.combining_suffix_pool.items.len,
            );
            try validateStyle(saved.current_style, self.hyperlink_pool.items.len);
            if (saved.last_printable_idx) |index| {
                if (index >= saved.cells.len or saved.cells[index].width == 0) {
                    return error.InvalidEngineCheckpoint;
                }
            }
            if (saved.saved_cursor) |cursor| {
                try validateSavedCursorForDimensions(
                    cursor,
                    saved.rows,
                    saved.cols,
                    self.hyperlink_pool.items.len,
                );
            }
        }
    }

    /// Append the visible text for a single row (ANSI attributes are
    /// dropped). Trailing blanks are preserved so positional asserts
    /// are stable.
    pub fn rowText(self: Grid, row: u16, out: *std.ArrayList(u8)) !void {
        if (row == 0 or row > self.rows) return;
        const base = self.rowBase(row);
        var col: u16 = 0;
        var buf: [4]u8 = undefined;
        while (col < self.cols) : (col += 1) {
            const cell = self.cells[base + col];
            if (cell.width == 0) continue;
            const cp = if (cell.codepoint == 0) ' ' else cell.codepoint;
            const n = std.unicode.utf8Encode(cp, &buf) catch 1;
            try out.appendSlice(self.alloc, buf[0..n]);
            if (self.combiningSuffix(cell.combining_suffix_id)) |suffix| {
                try out.appendSlice(self.alloc, suffix);
            }
        }
    }

    /// Append the visible text for a single row, trimmed of trailing
    /// spaces. Useful when asserting "row 5 equals 'foo'".
    pub fn rowTextTrimmed(self: Grid, row: u16, out: *std.ArrayList(u8)) !void {
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(self.alloc);
        try self.rowText(row, &tmp);
        const trimmed = std.mem.trimEnd(u8, tmp.items, " ");
        try out.appendSlice(self.alloc, trimmed);
    }

    /// Append one row with its SGR attributes, excluding OSC hyperlinks and
    /// trailing default cells.
    pub fn rowStyledTextTrimmed(self: Grid, row: u16, out: *std.Io.Writer) !void {
        if (row == 0 or row > self.rows) return;
        var last_col: u16 = 0;
        var col: u16 = 1;
        while (col <= self.cols) : (col += 1) {
            const cell = self.cellAt(row, col).?;
            if (cell.width == 0) continue;
            var style = cell.style;
            style.hyperlink_id = 0;
            const suffix = self.combiningSuffix(cell.combining_suffix_id) orelse &.{};
            if (cell.codepoint != ' ' or suffix.len > 0 or !style.eql(.{})) last_col = col;
        }

        var active_style: Style = .{};
        col = 1;
        while (col <= last_col) : (col += 1) {
            const cell = self.cellAt(row, col).?;
            if (cell.width == 0) continue;
            var style = cell.style;
            style.hyperlink_id = 0;
            if (!active_style.eql(style)) {
                try emitSgrTransition(out, style);
                active_style = style;
            }
            try emitCodepoint(out, cell.codepoint);
            if (self.combiningSuffix(cell.combining_suffix_id)) |suffix| {
                try out.writeAll(suffix);
            }
        }
        if (!active_style.eql(.{})) try out.writeAll("\x1b[0m");
    }

    /// Produce a deep copy of the cell grid. Cursor and parser state
    /// are reset to initial values — the clone is intended as a
    /// frame-buffer snapshot, not a resume point for the emulator.
    pub fn clone(self: Grid, alloc: Allocator) !Grid {
        const cells = try alloc.alloc(Cell, self.cells.len);
        errdefer alloc.free(cells);
        @memcpy(cells, self.cells);

        var pool: std.ArrayList([]u8) = .empty;
        errdefer {
            for (pool.items) |url| alloc.free(url);
            pool.deinit(alloc);
        }
        try pool.ensureTotalCapacity(alloc, self.hyperlink_pool.items.len);
        for (self.hyperlink_pool.items) |url| {
            const dup = try alloc.dupe(u8, url);
            pool.appendAssumeCapacity(dup);
        }

        var suffix_pool: std.ArrayList([]u8) = .empty;
        errdefer {
            for (suffix_pool.items) |suffix| alloc.free(suffix);
            suffix_pool.deinit(alloc);
        }
        try suffix_pool.ensureTotalCapacity(alloc, self.combining_suffix_pool.items.len);
        for (self.combining_suffix_pool.items) |suffix| {
            const dup = try alloc.dupe(u8, suffix);
            suffix_pool.appendAssumeCapacity(dup);
        }

        const tab_stops = try alloc.dupe(bool, self.tab_stops);
        errdefer alloc.free(tab_stops);

        return .{
            .alloc = alloc,
            .rows = self.rows,
            .cols = self.cols,
            .cells = cells,
            .row_origin = self.row_origin,
            .scroll_top = 1,
            .scroll_bottom = self.rows,
            .tab_stops = tab_stops,
            .hyperlink_pool = pool,
            .hyperlink_pool_bytes = self.hyperlink_pool_bytes,
            .combining_suffix_pool = suffix_pool,
            .combining_pool_bytes = self.combining_pool_bytes,
        };
    }

    /// Emits the ANSI diff between equal-sized grids. Wide-glyph continuation
    /// cells affect change detection but are not emitted independently.
    pub fn diffTo(prev: Grid, next: Grid, out: *std.Io.Writer) !void {
        return diffBand(prev, next, 1, next.rows, out);
    }

    /// Diffs only the inclusive row band, preserving terminal content outside it.
    /// Empty bands emit nothing; callers that require a final cursor position
    /// must emit their own CUP sequence.
    pub fn diffBand(
        prev: Grid,
        next: Grid,
        top_row: u16,
        bottom_row: u16,
        out: *std.Io.Writer,
    ) !void {
        std.debug.assert(prev.rows == next.rows);
        std.debug.assert(prev.cols == next.cols);
        if (bottom_row < top_row) return;
        const top = @max(top_row, 1);
        const bot = @min(bottom_row, next.rows);

        var cur_style = prev.current_style;
        var cur_hyperlink = prev.current_style.hyperlink_id;
        var r: u16 = top;
        while (r <= bot) : (r += 1) {
            const prev_base = prev.rowBase(r);
            const next_base = next.rowBase(r);
            var first: u16 = 0;
            var last: u16 = 0;
            var c: u16 = 0;
            while (c < next.cols) : (c += 1) {
                const p = prev.cells[prev_base + c];
                const n = next.cells[next_base + c];
                if (!cellsEqual(prev, p, next, n)) {
                    if (first == 0) first = c + 1;
                    last = c + 1;
                }
            }
            if (first == 0) continue;

            // Cursor-addressed rows must reopen OSC 8 links because tmux ends
            // an active hyperlink at an automatic terminal wrap.
            if (cur_hyperlink != 0) {
                try out.writeAll("\x1b]8;;\x1b\\");
                cur_hyperlink = 0;
            }
            try out.print("\x1b[{d};{d}H", .{ r, first });
            // Repainting one wide glyph across another can leave both cells
            // blank on real terminals unless the old span is erased first.
            if (hasShiftedWideCellOverlap(prev, next, r, first, last)) {
                try out.print("\x1b[{d}X", .{last - first + 1});
            }

            var col: u16 = first;
            while (col <= last) {
                const cell = next.cells[next_base + col - 1];
                if (cell.width == 0) {
                    col += 1;
                    continue;
                }
                if (!cell.style.eql(cur_style)) {
                    try emitSgrTransition(out, cell.style);
                    cur_style = cell.style;
                }
                if (cell.style.hyperlink_id != cur_hyperlink) {
                    try emitHyperlinkTransition(out, next, cur_hyperlink, cell.style.hyperlink_id);
                    cur_hyperlink = cell.style.hyperlink_id;
                }
                if (cell.codepoint == '│') try out.print("\x1b[{d}G", .{col});
                const suffix = next.combiningSuffix(cell.combining_suffix_id);
                const guard_margin_suffix = !prev.autowrap and
                    cell.width == 2 and
                    col + 1 == next.cols and
                    suffix != null;
                // With DECAWM disabled, terminals can drop suffix codepoints
                // from a display unit whose base ends at the right margin.
                if (guard_margin_suffix) try out.writeAll("\x1b[?7h");
                try emitCodepoint(out, cell.codepoint);
                if (suffix) |bytes| {
                    try out.writeAll(bytes);
                }
                if (guard_margin_suffix) try out.writeAll("\x1b[?7l");
                col += cell.width;
            }
        }

        if (!cur_style.eql(.{})) {
            try out.writeAll("\x1b[0m");
        }
        if (cur_hyperlink != 0) {
            try out.writeAll("\x1b]8;;\x1b\\");
        }
    }

    /// Dump the full grid as `| row |\n` lines for golden assertions.
    pub fn snapshot(self: Grid, out: *std.ArrayList(u8)) !void {
        var r: u16 = 1;
        while (r <= self.rows) : (r += 1) {
            try out.append(self.alloc, '|');
            try self.rowText(r, out);
            try out.append(self.alloc, '|');
            try out.append(self.alloc, '\n');
        }
    }
};

const CheckpointEncoder = struct {
    alloc: Allocator,
    output: std.ArrayList(u8) = .empty,

    fn init(alloc: Allocator) CheckpointEncoder {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *CheckpointEncoder) void {
        self.output.deinit(self.alloc);
    }

    fn reserve(self: *CheckpointEncoder, additional: usize) !void {
        if (additional > contracts.max_checkpoint_payload_bytes -|
            self.output.items.len)
        {
            return error.CheckpointTooLarge;
        }
        try self.output.ensureUnusedCapacity(self.alloc, additional);
    }

    fn bytes(self: *CheckpointEncoder, value: []const u8) !void {
        try self.reserve(value.len);
        self.output.appendSliceAssumeCapacity(value);
    }

    fn sizedBytes(self: *CheckpointEncoder, value: []const u8) !void {
        const length = std.math.cast(u32, value.len) orelse
            return error.CheckpointTooLarge;
        try self.int(u32, length);
        try self.bytes(value);
    }

    fn int(self: *CheckpointEncoder, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.bytes(&buffer);
    }

    fn boolean(self: *CheckpointEncoder, value: bool) !void {
        try self.int(u8, @intFromBool(value));
    }

    fn finish(self: *CheckpointEncoder) ![]u8 {
        return self.output.toOwnedSlice(self.alloc);
    }
};

const CheckpointDecoder = struct {
    input: []const u8,
    offset: usize = 0,

    fn init(input: []const u8) CheckpointDecoder {
        return .{ .input = input };
    }

    fn fixed(self: *CheckpointDecoder, length: usize) ![]const u8 {
        if (length > self.input.len -| self.offset) {
            return error.InvalidEngineCheckpoint;
        }
        const start = self.offset;
        self.offset += length;
        return self.input[start..self.offset];
    }

    fn sizedBytes(self: *CheckpointDecoder, maximum: usize) ![]const u8 {
        const length = try self.int(u32);
        if (length > maximum) return error.InvalidEngineCheckpoint;
        return self.fixed(length);
    }

    fn ownedBytes(
        self: *CheckpointDecoder,
        alloc: Allocator,
        maximum: usize,
    ) ![]u8 {
        const value = try self.sizedBytes(maximum);
        if (value.len == 0) return &.{};
        return alloc.dupe(u8, value);
    }

    fn int(self: *CheckpointDecoder, comptime T: type) !T {
        const value = try self.fixed(@sizeOf(T));
        return std.mem.readInt(T, value[0..@sizeOf(T)], .little);
    }

    fn boolean(self: *CheckpointDecoder) !bool {
        return switch (try self.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidEngineCheckpoint,
        };
    }

    fn finished(self: CheckpointDecoder) bool {
        return self.offset == self.input.len;
    }
};

fn encodeGridState(encoder: *CheckpointEncoder, grid: Grid) !void {
    try encoder.int(u16, grid.rows);
    try encoder.int(u16, grid.cols);
    try encodeCells(encoder, grid.cells);
    try encoder.int(u16, grid.row_origin);
    try encoder.int(u16, grid.cursor_row);
    try encoder.int(u16, grid.cursor_col);
    try encoder.boolean(grid.autowrap);
    try encoder.boolean(grid.pending_wrap);
    try encoder.boolean(grid.cursor_visible);
    try encoder.int(u8, @intFromEnum(grid.cursor_shape));
    try encoder.boolean(grid.cursor_blinking);
    try encoder.int(u16, grid.scroll_top);
    try encoder.int(u16, grid.scroll_bottom);
    try encoder.boolean(grid.origin_mode);
    try encoder.boolean(grid.insert_mode);
    try encoder.boolean(grid.bracketed_paste);
    try encoder.int(u16, grid.mouse_modes);
    try encoder.boolean(grid.focus_tracking);
    try encoder.boolean(grid.application_cursor_keys);
    try encoder.boolean(grid.application_keypad);
    try encoder.boolean(grid.keyboard_protocol);
    for (grid.tab_stops) |stop| try encoder.boolean(stop);
    try encoder.boolean(grid.sync_active);
    try encoder.boolean(grid.defer_sync_updates);
    try encoder.sizedBytes(grid.sync_buffer.items);
    try encodeStyle(encoder, grid.current_style);
    try encoder.int(u8, @intFromEnum(grid.state));
    for (grid.csi_params) |param| try encoder.int(u16, param);
    try encoder.int(u8, grid.csi_param_count);
    try encoder.boolean(grid.csi_has_digit);
    try encoder.int(u8, grid.csi_private);
    try encoder.bytes(&grid.csi_intermediates);
    try encoder.int(u8, grid.csi_intermediate_count);
    try encoder.boolean(grid.osc_saw_esc);
    try encoder.sizedBytes(grid.osc_buffer.items);
    try encoder.boolean(grid.dcs_saw_esc);
    try encoder.sizedBytes(grid.dcs_buffer.items);
    try encoder.bytes(&grid.utf8_buffer);
    try encoder.int(u8, grid.utf8_len);
    try encoder.int(u8, grid.utf8_expected);
    try encodePool(encoder, grid.hyperlink_pool.items);
    try encodePool(encoder, grid.combining_suffix_pool.items);
    try encoder.sizedBytes(grid.active_hyperlink_params);
    try encoder.boolean(grid.saved_normal_screen != null);
    if (grid.saved_normal_screen) |saved| try encodeSavedScreen(encoder, saved);
    try encodeOptionalSavedCursor(encoder, grid.saved_cursor);
    try encodeOptionalIndex(encoder, grid.last_printable_idx);
}

fn encodeCells(encoder: *CheckpointEncoder, cells: []const Cell) !void {
    const count = std.math.cast(u32, cells.len) orelse
        return error.CheckpointTooLarge;
    try encoder.int(u32, count);
    for (cells) |cell| {
        try encoder.int(u32, cell.codepoint);
        try encoder.int(u8, cell.width);
        try encoder.int(u32, cell.combining_suffix_id);
        try encodeStyle(encoder, cell.style);
    }
}

fn encodeStyle(encoder: *CheckpointEncoder, style: Style) !void {
    try encodeColor(encoder, style.fg);
    try encodeColor(encoder, style.bg);
    try encoder.int(u8, @bitCast(style.flags));
    try encoder.int(u32, style.hyperlink_id);
}

fn encodeColor(encoder: *CheckpointEncoder, color: Color) !void {
    switch (color) {
        .default => try encoder.int(u8, 0),
        .indexed => |index| {
            try encoder.int(u8, 1);
            try encoder.int(u8, index);
        },
        .rgb => |rgb| {
            try encoder.int(u8, 2);
            try encoder.int(u8, rgb.r);
            try encoder.int(u8, rgb.g);
            try encoder.int(u8, rgb.b);
        },
    }
}

fn encodePool(encoder: *CheckpointEncoder, pool: []const []u8) !void {
    const count = std.math.cast(u32, pool.len) orelse
        return error.CheckpointTooLarge;
    try encoder.int(u32, count);
    for (pool) |value| try encoder.sizedBytes(value);
}

fn encodeSavedScreen(
    encoder: *CheckpointEncoder,
    saved: SavedScreen,
) !void {
    try encoder.int(u16, saved.rows);
    try encoder.int(u16, saved.cols);
    try encodeCells(encoder, saved.cells);
    try encoder.int(u16, saved.row_origin);
    try encoder.int(u16, saved.cursor_row);
    try encoder.int(u16, saved.cursor_col);
    try encoder.boolean(saved.autowrap);
    try encoder.boolean(saved.pending_wrap);
    try encoder.boolean(saved.cursor_visible);
    try encoder.int(u8, @intFromEnum(saved.cursor_shape));
    try encoder.boolean(saved.cursor_blinking);
    try encodeStyle(encoder, saved.current_style);
    try encoder.sizedBytes(saved.active_hyperlink_params);
    try encodeOptionalIndex(encoder, saved.last_printable_idx);
    try encoder.int(u16, saved.scroll_top);
    try encoder.int(u16, saved.scroll_bottom);
    try encoder.boolean(saved.origin_mode);
    try encoder.boolean(saved.insert_mode);
    try encodeOptionalSavedCursor(encoder, saved.saved_cursor);
}

fn encodeOptionalSavedCursor(
    encoder: *CheckpointEncoder,
    cursor: ?SavedCursor,
) !void {
    try encoder.boolean(cursor != null);
    if (cursor) |saved| {
        try encoder.int(u16, saved.row);
        try encoder.int(u16, saved.col);
        try encoder.boolean(saved.pending_wrap);
        try encodeStyle(encoder, saved.style);
        try encoder.boolean(saved.origin_mode);
    }
}

fn encodeOptionalIndex(
    encoder: *CheckpointEncoder,
    index: ?usize,
) !void {
    try encoder.boolean(index != null);
    if (index) |value| {
        const encoded = std.math.cast(u64, value) orelse
            return error.CheckpointTooLarge;
        try encoder.int(u64, encoded);
    }
}

fn decodeGridState(
    alloc: Allocator,
    decoder: *CheckpointDecoder,
) !Grid {
    const rows = try decoder.int(u16);
    const cols = try decoder.int(u16);
    var grid = try Grid.init(alloc, cols, rows);
    errdefer grid.deinit();
    try decodeCells(decoder, grid.cells);
    grid.row_origin = try decoder.int(u16);
    grid.cursor_row = try decoder.int(u16);
    grid.cursor_col = try decoder.int(u16);
    grid.autowrap = try decoder.boolean();
    grid.pending_wrap = try decoder.boolean();
    grid.cursor_visible = try decoder.boolean();
    grid.cursor_shape = try decodeCursorShape(decoder);
    grid.cursor_blinking = try decoder.boolean();
    grid.scroll_top = try decoder.int(u16);
    grid.scroll_bottom = try decoder.int(u16);
    grid.origin_mode = try decoder.boolean();
    grid.insert_mode = try decoder.boolean();
    grid.bracketed_paste = try decoder.boolean();
    grid.mouse_modes = try decoder.int(u16);
    grid.focus_tracking = try decoder.boolean();
    grid.application_cursor_keys = try decoder.boolean();
    grid.application_keypad = try decoder.boolean();
    grid.keyboard_protocol = try decoder.boolean();
    for (grid.tab_stops) |*stop| stop.* = try decoder.boolean();
    grid.sync_active = try decoder.boolean();
    grid.defer_sync_updates = try decoder.boolean();
    grid.sync_buffer = .fromOwnedSlice(try decoder.ownedBytes(
        alloc,
        max_sync_bytes,
    ));
    grid.current_style = try decodeStyle(decoder);
    grid.state = switch (try decoder.int(u8)) {
        0 => .normal,
        1 => .escape,
        2 => .csi,
        3 => .osc,
        4 => .dcs,
        else => return error.InvalidEngineCheckpoint,
    };
    for (&grid.csi_params) |*param| param.* = try decoder.int(u16);
    grid.csi_param_count = try decoder.int(u8);
    grid.csi_has_digit = try decoder.boolean();
    grid.csi_private = try decoder.int(u8);
    @memcpy(
        &grid.csi_intermediates,
        try decoder.fixed(grid.csi_intermediates.len),
    );
    grid.csi_intermediate_count = try decoder.int(u8);
    grid.osc_saw_esc = try decoder.boolean();
    grid.osc_buffer = .fromOwnedSlice(try decoder.ownedBytes(
        alloc,
        max_string_bytes,
    ));
    grid.dcs_saw_esc = try decoder.boolean();
    grid.dcs_buffer = .fromOwnedSlice(try decoder.ownedBytes(
        alloc,
        max_string_bytes,
    ));
    @memcpy(&grid.utf8_buffer, try decoder.fixed(grid.utf8_buffer.len));
    grid.utf8_len = try decoder.int(u8);
    grid.utf8_expected = try decoder.int(u8);
    try decodePool(
        decoder,
        alloc,
        &grid.hyperlink_pool,
        &grid.hyperlink_pool_bytes,
        max_hyperlink_pool_bytes,
    );
    try decodePool(
        decoder,
        alloc,
        &grid.combining_suffix_pool,
        &grid.combining_pool_bytes,
        max_combining_pool_bytes,
    );
    grid.active_hyperlink_params = try decoder.ownedBytes(
        alloc,
        max_string_bytes,
    );
    if (try decoder.boolean()) {
        grid.saved_normal_screen = try decodeSavedScreen(
            decoder,
            alloc,
            grid.cells.len,
        );
    }
    grid.saved_cursor = try decodeOptionalSavedCursor(decoder);
    grid.last_printable_idx = try decodeOptionalIndex(decoder);
    return grid;
}

fn decodeCells(decoder: *CheckpointDecoder, cells: []Cell) !void {
    const count = try decoder.int(u32);
    if (count != cells.len) return error.InvalidEngineCheckpoint;
    for (cells) |*cell| {
        const codepoint = try decoder.int(u32);
        if (codepoint > std.math.maxInt(u21)) {
            return error.InvalidEngineCheckpoint;
        }
        cell.* = .{
            .codepoint = @intCast(codepoint),
            .width = try decoder.int(u8),
            .combining_suffix_id = try decoder.int(u32),
            .style = try decodeStyle(decoder),
        };
    }
}

fn decodeStyle(decoder: *CheckpointDecoder) !Style {
    const fg = try decodeColor(decoder);
    const bg = try decodeColor(decoder);
    const flags = try decoder.int(u8);
    if (flags & 0xc0 != 0) return error.InvalidEngineCheckpoint;
    return .{
        .fg = fg,
        .bg = bg,
        .flags = @bitCast(flags),
        .hyperlink_id = try decoder.int(u32),
    };
}

fn decodeColor(decoder: *CheckpointDecoder) !Color {
    return switch (try decoder.int(u8)) {
        0 => .default,
        1 => .{ .indexed = try decoder.int(u8) },
        2 => .{ .rgb = .{
            .r = try decoder.int(u8),
            .g = try decoder.int(u8),
            .b = try decoder.int(u8),
        } },
        else => error.InvalidEngineCheckpoint,
    };
}

fn decodeCursorShape(decoder: *CheckpointDecoder) !contracts.CursorShape {
    return switch (try decoder.int(u8)) {
        0 => .block,
        1 => .underline,
        2 => .bar,
        else => error.InvalidEngineCheckpoint,
    };
}

fn decodePool(
    decoder: *CheckpointDecoder,
    alloc: Allocator,
    pool: *std.ArrayList([]u8),
    byte_count: *usize,
    maximum_bytes: usize,
) !void {
    const count = try decoder.int(u32);
    if (count > max_pool_entries) return error.InvalidEngineCheckpoint;
    try pool.ensureTotalCapacity(alloc, count);
    var total: usize = 0;
    for (0..count) |_| {
        const value = try decoder.ownedBytes(alloc, max_string_bytes);
        errdefer if (value.len > 0) alloc.free(value);
        if (value.len == 0 or value.len > maximum_bytes -| total) {
            return error.InvalidEngineCheckpoint;
        }
        pool.appendAssumeCapacity(value);
        total += value.len;
    }
    byte_count.* = total;
}

fn decodeSavedScreen(
    decoder: *CheckpointDecoder,
    alloc: Allocator,
    expected_cell_count: usize,
) !SavedScreen {
    const rows = try decoder.int(u16);
    const cols = try decoder.int(u16);
    const count = std.math.mul(
        usize,
        @intCast(rows),
        @intCast(cols),
    ) catch return error.InvalidEngineCheckpoint;
    if (count != expected_cell_count) return error.InvalidEngineCheckpoint;
    const cells = try alloc.alloc(Cell, count);
    errdefer alloc.free(cells);
    try decodeCells(decoder, cells);
    const row_origin = try decoder.int(u16);
    const cursor_row = try decoder.int(u16);
    const cursor_col = try decoder.int(u16);
    const autowrap = try decoder.boolean();
    const pending_wrap = try decoder.boolean();
    const cursor_visible = try decoder.boolean();
    const cursor_shape = try decodeCursorShape(decoder);
    const cursor_blinking = try decoder.boolean();
    const current_style = try decodeStyle(decoder);
    const active_params = try decoder.sizedBytes(max_string_bytes);
    const last_printable_idx = try decodeOptionalIndex(decoder);
    const scroll_top = try decoder.int(u16);
    const scroll_bottom = try decoder.int(u16);
    const origin_mode = try decoder.boolean();
    const insert_mode = try decoder.boolean();
    const saved_cursor = try decodeOptionalSavedCursor(decoder);
    const owned_params = if (active_params.len == 0)
        &.{}
    else
        try alloc.dupe(u8, active_params);
    return .{
        .rows = rows,
        .cols = cols,
        .cells = cells,
        .row_origin = row_origin,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
        .autowrap = autowrap,
        .pending_wrap = pending_wrap,
        .cursor_visible = cursor_visible,
        .cursor_shape = cursor_shape,
        .cursor_blinking = cursor_blinking,
        .current_style = current_style,
        .active_hyperlink_params = owned_params,
        .last_printable_idx = last_printable_idx,
        .scroll_top = scroll_top,
        .scroll_bottom = scroll_bottom,
        .origin_mode = origin_mode,
        .insert_mode = insert_mode,
        .saved_cursor = saved_cursor,
    };
}

fn decodeOptionalSavedCursor(
    decoder: *CheckpointDecoder,
) !?SavedCursor {
    if (!try decoder.boolean()) return null;
    return .{
        .row = try decoder.int(u16),
        .col = try decoder.int(u16),
        .pending_wrap = try decoder.boolean(),
        .style = try decodeStyle(decoder),
        .origin_mode = try decoder.boolean(),
    };
}

fn decodeOptionalIndex(decoder: *CheckpointDecoder) !?usize {
    if (!try decoder.boolean()) return null;
    return std.math.cast(usize, try decoder.int(u64)) orelse
        error.InvalidEngineCheckpoint;
}

fn validatePool(pool: []const []u8, maximum_bytes: usize) !void {
    var total: usize = 0;
    for (pool) |value| {
        if (value.len == 0 or value.len > max_string_bytes or
            value.len > maximum_bytes -| total)
        {
            return error.InvalidEngineCheckpoint;
        }
        total += value.len;
    }
}

fn validateUtf8Continuation(grid: Grid) !void {
    if (grid.utf8_len == 0) {
        if (grid.utf8_expected != 0) return error.InvalidEngineCheckpoint;
        return;
    }
    if (grid.state != .normal or grid.utf8_expected < 2) {
        return error.InvalidEngineCheckpoint;
    }
    const expected = std.unicode.utf8ByteSequenceLength(grid.utf8_buffer[0]) catch
        return error.InvalidEngineCheckpoint;
    if (expected != grid.utf8_expected) return error.InvalidEngineCheckpoint;
    var index: usize = 1;
    while (index < grid.utf8_len) : (index += 1) {
        if (grid.utf8_buffer[index] & 0xc0 != 0x80) {
            return error.InvalidEngineCheckpoint;
        }
    }
}

fn validateCells(
    cells: []const Cell,
    cols: u16,
    rows: u16,
    hyperlink_count: usize,
    combining_count: usize,
) !void {
    if (cells.len != @as(usize, cols) * @as(usize, rows)) {
        return error.InvalidEngineCheckpoint;
    }
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const base = @as(usize, row) * @as(usize, cols);
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const cell = cells[base + col];
            try validateStyle(cell.style, hyperlink_count);
            if (cell.combining_suffix_id > combining_count) {
                return error.InvalidEngineCheckpoint;
            }
            if (cell.codepoint != 0) {
                _ = std.unicode.utf8CodepointSequenceLength(cell.codepoint) catch
                    return error.InvalidEngineCheckpoint;
            }
            switch (cell.width) {
                0 => {
                    if (col == 0 or cell.codepoint != 0 or
                        cell.combining_suffix_id != 0)
                    {
                        return error.InvalidEngineCheckpoint;
                    }
                    const lead = cells[base + col - 1];
                    if (lead.width != 2 or !lead.style.eql(cell.style)) {
                        return error.InvalidEngineCheckpoint;
                    }
                },
                1 => if (cell.codepoint == 0) {
                    return error.InvalidEngineCheckpoint;
                },
                2 => {
                    if (cell.codepoint == 0 or col + 1 >= cols) {
                        return error.InvalidEngineCheckpoint;
                    }
                    const continuation = cells[base + col + 1];
                    if (continuation.width != 0 or
                        continuation.codepoint != 0 or
                        continuation.combining_suffix_id != 0 or
                        !continuation.style.eql(cell.style))
                    {
                        return error.InvalidEngineCheckpoint;
                    }
                },
                else => return error.InvalidEngineCheckpoint,
            }
        }
    }
}

fn validateStyle(style: Style, hyperlink_count: usize) !void {
    if (style.hyperlink_id > hyperlink_count) {
        return error.InvalidEngineCheckpoint;
    }
}

fn validateSavedCursor(cursor: SavedCursor, grid: Grid) !void {
    return validateSavedCursorForDimensions(
        cursor,
        grid.rows,
        grid.cols,
        grid.hyperlink_pool.items.len,
    );
}

fn validateSavedCursorForDimensions(
    cursor: SavedCursor,
    rows: u16,
    cols: u16,
    hyperlink_count: usize,
) !void {
    if (cursor.row == 0 or cursor.row > rows or
        cursor.col == 0 or cursor.col > cols)
    {
        return error.InvalidEngineCheckpoint;
    }
    try validateStyle(cursor.style, hyperlink_count);
}

fn initializeTabStops(stops: []bool) void {
    @memset(stops, false);
    var index: usize = 8;
    while (index < stops.len) : (index += 8) stops[index] = true;
}

fn appendBounded(
    list: *std.ArrayList(u8),
    alloc: Allocator,
    byte: u8,
    limit: usize,
) !void {
    if (list.items.len >= limit) return error.ControlStringTooLarge;
    try list.append(alloc, byte);
}

fn isBlankCell(cell: Cell) bool {
    return cell.width == 1 and
        cell.codepoint == ' ' and
        cell.combining_suffix_id == 0;
}

fn renderStyle(style: Style) contracts.CellStyle {
    return .{
        .foreground = renderColor(style.fg),
        .background = renderColor(style.bg),
        .bold = style.flags.bold,
        .faint = style.flags.dim,
        .italic = style.flags.italic,
        .underline = style.flags.underline,
        .inverse = style.flags.reverse,
        .strikethrough = style.flags.strike,
    };
}

fn renderColor(color: Color) contracts.CellColor {
    return switch (color) {
        .default => .default,
        .indexed => |index| .{ .indexed = index },
        .rgb => |rgb| .{ .rgb = .{
            .red = rgb.r,
            .green = rgb.g,
            .blue = rgb.b,
        } },
    };
}

fn physicalRowIndex(origin: u16, logical_row: u16, rows: u16) usize {
    std.debug.assert(rows > 0);
    std.debug.assert(origin < rows);
    std.debug.assert(logical_row < rows);
    const index = @as(usize, origin) + @as(usize, logical_row);
    return if (index < rows) index else index - rows;
}

fn cellsEqual(a_grid: Grid, a: Cell, b_grid: Grid, b: Cell) bool {
    if (a.codepoint != b.codepoint or a.width != b.width or !a.style.eql(b.style)) {
        return false;
    }
    if (a.combining_suffix_id == 0 or b.combining_suffix_id == 0) {
        return a.combining_suffix_id == b.combining_suffix_id;
    }
    const a_suffix = a_grid.combiningSuffix(a.combining_suffix_id) orelse return false;
    const b_suffix = b_grid.combiningSuffix(b.combining_suffix_id) orelse return false;
    return std.mem.eql(u8, a_suffix, b_suffix);
}

fn hasShiftedWideCellOverlap(
    prev: Grid,
    next: Grid,
    row: u16,
    first: u16,
    last: u16,
) bool {
    const prev_base = prev.rowBase(row);
    const next_base = next.rowBase(row);
    var col = first;
    while (col <= last) : (col += 1) {
        const prev_lead = wideCellLead(prev.cells, prev_base, col);
        const next_lead = wideCellLead(next.cells, next_base, col);
        if (prev_lead != null and next_lead != null and prev_lead.? != next_lead.?) {
            return true;
        }
    }
    return false;
}

fn wideCellLead(cells: []const Cell, row_base: usize, col: u16) ?u16 {
    const idx = row_base + @as(usize, col - 1);
    return switch (cells[idx].width) {
        2 => col,
        0 => if (col > 1 and cells[idx - 1].width == 2) col - 1 else null,
        else => null,
    };
}

/// Transitions between OSC 8 hyperlinks without closing a valid active link first.
fn emitHyperlinkTransition(out: *std.Io.Writer, grid: Grid, prev_id: u32, next_id: u32) !void {
    // OSC 8 permits opening a new link without explicitly closing the active one.
    if (next_id == 0) {
        try out.writeAll("\x1b]8;;\x1b\\");
        return;
    }
    const url = grid.hyperlinkUrl(next_id) orelse {
        if (prev_id != 0) try out.writeAll("\x1b]8;;\x1b\\");
        return;
    };
    try emitHyperlinkOpen(out, &.{}, url);
}

fn emitHyperlinkOpen(
    out: *std.Io.Writer,
    params: []const u8,
    url: []const u8,
) !void {
    try out.writeAll("\x1b]8;");
    try out.writeAll(params);
    try out.writeByte(';');
    try out.writeAll(url);
    try out.writeAll("\x1b\\");
}

/// Resets unknown prior style before applying the target state.
fn emitSgrTransition(out: *std.Io.Writer, next: Style) !void {
    try out.writeAll("\x1b[0m");
    if (next.flags.bold) try out.writeAll("\x1b[1m");
    if (next.flags.dim) try out.writeAll("\x1b[2m");
    if (next.flags.italic) try out.writeAll("\x1b[3m");
    if (next.flags.underline) try out.writeAll("\x1b[4m");
    if (next.flags.reverse) try out.writeAll("\x1b[7m");
    if (next.flags.strike) try out.writeAll("\x1b[9m");
    try emitColor(out, next.fg, .fg);
    try emitColor(out, next.bg, .bg);
}

const ColorChannel = enum { fg, bg };

fn emitColor(out: *std.Io.Writer, color: Color, channel: ColorChannel) !void {
    switch (color) {
        .default => {},
        .indexed => |i| {
            if (i < 8) {
                const base: u16 = if (channel == .fg) 30 else 40;
                try out.print("\x1b[{d}m", .{base + @as(u16, i)});
            } else if (i < 16) {
                const base: u16 = if (channel == .fg) 90 else 100;
                try out.print("\x1b[{d}m", .{base + @as(u16, i) - 8});
            } else {
                const prefix: u16 = if (channel == .fg) 38 else 48;
                try out.print("\x1b[{d};5;{d}m", .{ prefix, i });
            }
        },
        .rgb => |rgb| {
            const prefix: u16 = if (channel == .fg) 38 else 48;
            try out.print("\x1b[{d};2;{d};{d};{d}m", .{ prefix, rgb.r, rgb.g, rgb.b });
        },
    }
}

fn emitCodepoint(out: *std.Io.Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const cp_resolved: u21 = if (cp == 0) ' ' else cp;
    const n = std.unicode.utf8Encode(cp_resolved, &buf) catch blk: {
        buf[0] = ' ';
        break :blk 1;
    };
    try out.writeAll(buf[0..n]);
}

fn clamp(v: u16, lo: u16, hi: u16) u16 {
    if (hi < lo) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn clampSub(v: u16, sub: u16, lo: u16) u16 {
    if (sub >= v) return lo;
    const r = v - sub;
    return if (r < lo) lo else r;
}

const DecodedRune = struct { codepoint: u21, len: usize };

fn decodeUtf8(bytes: []const u8, start: usize) DecodedRune {
    const b = bytes[start];
    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
    if (seq_len <= 1 or start + seq_len > bytes.len) {
        return .{
            .codepoint = if (b < 0x80) b else 0xfffd,
            .len = 1,
        };
    }
    const slice = bytes[start .. start + seq_len];
    const cp = std.unicode.utf8Decode(slice) catch
        return .{ .codepoint = 0xfffd, .len = 1 };
    return .{ .codepoint = cp, .len = seq_len };
}

fn repairWideCells(cells: []Cell, cols: u16, rows: u16) void {
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_base = @as(usize, row) * @as(usize, cols);
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const idx = row_base + @as(usize, col);
            switch (cells[idx].width) {
                0 => {
                    if (col == 0 or
                        cells[idx].codepoint != 0 or
                        cells[idx].combining_suffix_id != 0 or
                        cells[idx - 1].width != 2 or
                        !cells[idx].style.eql(cells[idx - 1].style))
                    {
                        cells[idx] = .{};
                    }
                },
                1 => {},
                2 => {
                    if (col + 1 >= cols or
                        cells[idx + 1].width != 0 or
                        cells[idx + 1].codepoint != 0 or
                        cells[idx + 1].combining_suffix_id != 0 or
                        !cells[idx + 1].style.eql(cells[idx].style))
                    {
                        cells[idx] = .{};
                    }
                },
                else => cells[idx] = .{},
            }
        }
    }
}

const testing = std.testing;

fn expectRow(grid: Grid, row: u16, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try grid.rowTextTrimmed(row, &buf);
    try testing.expectEqualStrings(expected, buf.items);
}

fn expectWideCellInvariant(grid: Grid) !void {
    var row: u16 = 1;
    while (row <= grid.rows) : (row += 1) {
        var col: u16 = 1;
        while (col <= grid.cols) : (col += 1) {
            const cell = grid.cellAt(row, col).?;
            switch (cell.width) {
                0 => {
                    try testing.expect(col > 1);
                    const lead = grid.cellAt(row, col - 1).?;
                    try testing.expectEqual(@as(u8, 2), lead.width);
                    try testing.expectEqual(@as(u21, 0), cell.codepoint);
                    try testing.expect(cell.style.eql(lead.style));
                },
                1 => {},
                2 => {
                    try testing.expect(col < grid.cols);
                    const continuation = grid.cellAt(row, col + 1).?;
                    try testing.expectEqual(@as(u8, 0), continuation.width);
                    try testing.expectEqual(@as(u21, 0), continuation.codepoint);
                    try testing.expect(continuation.style.eql(cell.style));
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }
}

test "plain writes land on the grid" {
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();
    try g.feed("hello");
    try expectRow(g, 1, "hello");
    try testing.expectEqual(@as(u16, 6), g.cursor_col);
    try testing.expectEqual(@as(u16, 1), g.cursor_row);
}

test "CUP moves the cursor" {
    var g = try Grid.init(testing.allocator, 10, 4);
    defer g.deinit();
    try g.feed("\x1b[2;3Hab");
    try expectRow(g, 2, "  ab");
    try testing.expectEqual(@as(u16, 5), g.cursor_col);
    try testing.expectEqual(@as(u16, 2), g.cursor_row);
}

test "LF advances to the next row at column 1" {
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();
    try g.feed("a\nb\nc");
    try expectRow(g, 1, "a");
    try expectRow(g, 2, "b");
    try expectRow(g, 3, "c");
}

test "CR returns to column 1 without advancing row" {
    var g = try Grid.init(testing.allocator, 10, 2);
    defer g.deinit();
    try g.feed("abc\rXY");
    try expectRow(g, 1, "XYc");
}

test "EL 2K clears the whole line" {
    var g = try Grid.init(testing.allocator, 10, 2);
    defer g.deinit();
    try g.feed("hello world");
    try g.feed("\x1b[1;1H\x1b[2K");
    try expectRow(g, 1, "");
}

test "EL K clears cursor to end of line" {
    var g = try Grid.init(testing.allocator, 10, 2);
    defer g.deinit();
    try g.feed("hello");
    try g.feed("\x1b[1;3H\x1b[K");
    try expectRow(g, 1, "he");
}

test "EL 0 expands a continuation boundary to the complete wide glyph" {
    var g = try Grid.init(testing.allocator, 4, 1);
    defer g.deinit();
    try g.feed("ab界");
    try g.feed("\x1b[1;4H\x1b[K");
    try expectWideCellInvariant(g);
    try expectRow(g, 1, "ab");
}

test "EL 1 expands a lead boundary to the complete wide glyph" {
    var g = try Grid.init(testing.allocator, 4, 1);
    defer g.deinit();
    try g.feed("界xy");
    try g.feed("\x1b[1;1H\x1b[1K");
    try expectWideCellInvariant(g);
    try expectRow(g, 1, "  xy");
}

test "ED J clears cursor to end of display" {
    var g = try Grid.init(testing.allocator, 5, 3);
    defer g.deinit();
    try g.feed("\x1b[1;1Haaaaa\x1b[2;1Hbbbbb\x1b[3;1Hccccc");
    try g.feed("\x1b[2;1H\x1b[J");
    try expectRow(g, 1, "aaaaa");
    try expectRow(g, 2, "");
    try expectRow(g, 3, "");
}

test "ED 0 expands a continuation boundary to the complete wide glyph" {
    var g = try Grid.init(testing.allocator, 4, 2);
    defer g.deinit();
    try g.feed("ab界");
    try g.feed("\x1b[1;4H\x1b[J");
    try expectWideCellInvariant(g);
    try expectRow(g, 1, "ab");
    try expectRow(g, 2, "");
}

test "ED 1 expands a lead boundary to the complete wide glyph" {
    var g = try Grid.init(testing.allocator, 4, 2);
    defer g.deinit();
    try g.feed("\x1b[2;1H界xy");
    try g.feed("\x1b[2;1H\x1b[1J");
    try expectWideCellInvariant(g);
    try expectRow(g, 1, "");
    try expectRow(g, 2, "  xy");
}

test "ED 2J clears the entire display" {
    var g = try Grid.init(testing.allocator, 4, 2);
    defer g.deinit();
    try g.feed("\x1b[1;1Hab\x1b[2;1Hcd");
    try g.feed("\x1b[2J");
    try expectRow(g, 1, "");
    try expectRow(g, 2, "");
}

test "autowrap wraps past cols; ?7l disables wrap" {
    var g = try Grid.init(testing.allocator, 4, 3);
    defer g.deinit();
    try g.feed("abcdef");
    try expectRow(g, 1, "abcd");
    try expectRow(g, 2, "ef");

    try g.feed("\x1b[3;1H\x1b[?7lXXXXXYY");
    try expectRow(g, 3, "XXXY");
}

test "horizontal tab clears pending wrap and uses the next absolute stop" {
    var margin = try Grid.init(testing.allocator, 8, 2);
    defer margin.deinit();
    var stats: FeedStats = .{};
    try margin.feedWithStats("12345678\tX", &stats);
    try expectRow(margin, 1, "1234567X");
    try expectRow(margin, 2, "");
    try testing.expectEqual(@as(u16, 1), margin.cursor_row);
    try testing.expectEqual(@as(u16, 8), margin.cursor_col);
    try testing.expect(margin.pending_wrap);
    try testing.expectEqual(@as(u16, 0), stats.scroll_rows);

    var ordinary = try Grid.init(testing.allocator, 16, 1);
    defer ordinary.deinit();
    try ordinary.feed("a\tb");
    try expectRow(ordinary, 1, "a       b");
    try testing.expectEqual(@as(u16, 10), ordinary.cursor_col);
}

test "combining marks preserve base-character wrap geometry" {
    var base = try Grid.init(testing.allocator, 4, 2);
    defer base.deinit();
    var base_stats: FeedStats = .{};
    try base.feedWithStats("eeeee", &base_stats);

    var decomposed = try Grid.init(testing.allocator, 4, 2);
    defer decomposed.deinit();
    var decomposed_stats: FeedStats = .{};
    try decomposed.feedWithStats("e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}", &decomposed_stats);

    try testing.expectEqual(base.cursor_row, decomposed.cursor_row);
    try testing.expectEqual(base.cursor_col, decomposed.cursor_col);
    try testing.expectEqual(base.pending_wrap, decomposed.pending_wrap);
    try testing.expectEqual(base_stats.max_row_touched, decomposed_stats.max_row_touched);
    try testing.expectEqual(base_stats.scrolled, decomposed_stats.scrolled);
    try testing.expectEqual(base_stats.scroll_rows, decomposed_stats.scroll_rows);
}

test "combining marks remain attached to the base cell text" {
    var g = try Grid.init(testing.allocator, 8, 1);
    defer g.deinit();

    try g.feed("e\u{0301}\u{0327}x");

    try expectRow(g, 1, "e\u{0301}\u{0327}x");
    try testing.expectEqual(@as(u16, 3), g.cursor_col);
}

test "repeated combining suffixes reuse grid storage" {
    var g = try Grid.init(testing.allocator, 8, 1);
    defer g.deinit();

    try g.feed("e\u{0301}e\u{0301}e\u{0301}");

    try testing.expectEqual(@as(usize, 1), g.combining_suffix_pool.items.len);
}

test "combining marks survive Grid clone" {
    var source = try Grid.init(testing.allocator, 8, 1);
    defer source.deinit();
    try source.feed("e\u{0301}\u{0327}");

    var cloned = try source.clone(testing.allocator);
    defer cloned.deinit();

    try expectRow(cloned, 1, "e\u{0301}\u{0327}");
}

test "combining suffix clears with overwritten and erased cells" {
    var g = try Grid.init(testing.allocator, 8, 1);
    defer g.deinit();

    try g.feed("e\u{0301}");
    try g.feed("\x1b[1;1Hx");
    try expectRow(g, 1, "x");
    try testing.expectEqual(@as(u32, 0), g.cellAt(1, 1).?.combining_suffix_id);

    try g.feed("\x1b[1;1He\u{0301}\x1b[2K");
    try expectRow(g, 1, "");
    try testing.expectEqual(@as(u32, 0), g.cellAt(1, 1).?.combining_suffix_id);
}

test "combining marks attach to a wide lead at pending wrap" {
    var g = try Grid.init(testing.allocator, 3, 1);
    defer g.deinit();

    try g.feed("a界\u{0301}");

    try expectRow(g, 1, "a界\u{0301}");
    try testing.expect(g.pending_wrap);
    try testing.expectEqual(@as(u16, 3), g.cursor_col);
    try testing.expect(g.cellAt(1, 2).?.combining_suffix_id != 0);
    try testing.expectEqual(@as(u32, 0), g.cellAt(1, 3).?.combining_suffix_id);
}

test "Unicode display units preserve bytes and terminal geometry" {
    const Case = struct {
        text: []const u8,
        width: u8,
    };
    const cases = [_]Case{
        .{ .text = "\u{2600}\u{FE0E}", .width = 1 },
        .{ .text = "\u{231A}\u{FE0E}", .width = 2 },
        .{ .text = "\u{2600}\u{FE0F}", .width = 2 },
        .{ .text = "\u{1F44D}\u{1F3FD}", .width = 2 },
        .{ .text = "\u{1F1FA}\u{1F1F8}", .width = 2 },
        .{ .text = "#\u{FE0F}\u{20E3}", .width = 2 },
        .{ .text = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", .width = 2 },
        .{ .text = "\u{1F469}\u{200D}\u{1F4BB}", .width = 2 },
    };

    for (cases) |case| {
        var grid = try Grid.init(testing.allocator, 16, 1);
        defer grid.deinit();
        try grid.feed("A");
        try grid.feed(case.text);
        try grid.feed("B");

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.append(testing.allocator, 'A');
        try expected.appendSlice(testing.allocator, case.text);
        try expected.append(testing.allocator, 'B');
        try expectRow(grid, 1, expected.items);
        try testing.expectEqual(@as(u16, case.width) + 3, grid.cursor_col);

        const lead = grid.cellAt(1, 2).?;
        try testing.expectEqual(case.width, lead.width);
        const first = decodeUtf8(case.text, 0);
        try testing.expectEqual(first.codepoint, lead.codepoint);
        try testing.expectEqualStrings(
            case.text[first.len..],
            grid.combiningSuffix(lead.combining_suffix_id).?,
        );

        var cloned = try grid.clone(testing.allocator);
        defer cloned.deinit();
        try expectRow(cloned, 1, expected.items);
    }
}

test "Unicode display-unit suffixes clear on overwrite and erase" {
    const cases = [_][]const u8{
        "\u{2600}\u{FE0E}",
        "\u{1F44D}\u{1F3FD}",
        "\u{1F469}\u{200D}\u{1F4BB}",
    };

    for (cases) |text| {
        var grid = try Grid.init(testing.allocator, 8, 1);
        defer grid.deinit();

        try grid.feed(text);
        try grid.feed("\x1b[1;1HX");
        try expectRow(grid, 1, "X");
        try testing.expectEqual(@as(u32, 0), grid.cellAt(1, 1).?.combining_suffix_id);

        try grid.feed("\x1b[1;1H");
        try grid.feed(text);
        try grid.feed("\x1b[1;1H\x1b[2K");
        try expectRow(grid, 1, "");
        try testing.expectEqual(@as(u32, 0), grid.cellAt(1, 1).?.combining_suffix_id);
    }
}

test "Unicode display units survive resize while intact and clear when clipped" {
    const tag_flag = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}";
    var grid = try Grid.init(testing.allocator, 3, 1);
    defer grid.deinit();
    try grid.feed(tag_flag ++ "x");

    try grid.resize(6, 2);
    try expectRow(grid, 1, tag_flag ++ "x");
    try grid.resize(3, 1);
    try expectRow(grid, 1, tag_flag ++ "x");
    try grid.resize(1, 1);
    try expectRow(grid, 1, "");
    try testing.expectEqual(@as(u32, 0), grid.cellAt(1, 1).?.combining_suffix_id);
}

test "SGR is swallowed, text content is preserved" {
    var g = try Grid.init(testing.allocator, 8, 1);
    defer g.deinit();
    try g.feed("\x1b[38;5;240m[sys]\x1b[0m x");
    try expectRow(g, 1, "[sys] x");
}

test "private keyboard mode does not alter SGR presentation" {
    var g = try Grid.init(testing.allocator, 8, 1);
    defer g.deinit();

    try g.feed("\x1b[>4;2m");

    try testing.expect(g.current_style.eql(.{}));
}

test "OSC title is discarded without affecting the grid" {
    var g = try Grid.init(testing.allocator, 6, 1);
    defer g.deinit();
    try g.feed("\x1b]2;my title\x07text");
    try expectRow(g, 1, "text");
}

test "OSC with ST (ESC backslash) terminator is discarded" {
    var g = try Grid.init(testing.allocator, 6, 1);
    defer g.deinit();
    try g.feed("\x1b]11;rgb:0000/0000/0000\x1b\\hello");
    try expectRow(g, 1, "hello");
}

test "DSR 6n is swallowed without side effects" {
    var g = try Grid.init(testing.allocator, 6, 1);
    defer g.deinit();
    try g.feed("\x1b[6n");
    try g.feed("ok");
    try expectRow(g, 1, "ok");
}

test "resize grows keeping top-left content" {
    var g = try Grid.init(testing.allocator, 4, 2);
    defer g.deinit();
    try g.feed("abcd\nef");
    try g.resize(6, 3);
    try expectRow(g, 1, "abcd");
    try expectRow(g, 2, "ef");
    try expectRow(g, 3, "");
    try testing.expectEqual(@as(u16, 6), g.cols);
    try testing.expectEqual(@as(u16, 3), g.rows);
}

test "resize shrinks clipping bottom/right without clearing" {
    var g = try Grid.init(testing.allocator, 6, 3);
    defer g.deinit();
    try g.feed("\x1b[1;1Haaabbb\x1b[2;1Hxxxxxx\x1b[3;1Hyyyyyy");
    try g.resize(4, 2);
    try expectRow(g, 1, "aaab");
    try expectRow(g, 2, "xxxx");
    try testing.expectEqual(@as(u16, 4), g.cols);
    try testing.expectEqual(@as(u16, 2), g.rows);
}

test "resize narrowing clears a wide glyph clipped at the right edge" {
    var g = try Grid.init(testing.allocator, 4, 1);
    defer g.deinit();
    try g.feed("ab界");
    try g.resize(3, 1);
    try expectWideCellInvariant(g);
    try expectRow(g, 1, "ab");
}

test "writes clear any complete wide glyph overlapping the destination" {
    const Case = struct {
        initial: []const u8,
        col: u16,
        replacement: []const u8,
    };
    const cases = [_]Case{
        .{ .initial = "界xy", .col = 1, .replacement = "a" },
        .{ .initial = "界xy", .col = 2, .replacement = "a" },
        .{ .initial = "界zz", .col = 2, .replacement = "界" },
    };
    for (cases) |case| {
        var g = try Grid.init(testing.allocator, 4, 1);
        defer g.deinit();
        try g.feed(case.initial);
        var cursor: [16]u8 = undefined;
        const move = try std.fmt.bufPrint(&cursor, "\x1b[1;{d}H", .{case.col});
        try g.feed(move);
        try g.feed(case.replacement);
        try expectWideCellInvariant(g);
    }
}

test "scroll on LF at last row" {
    var g = try Grid.init(testing.allocator, 4, 2);
    defer g.deinit();
    try g.feed("AAAA\nBBBB");
    try g.feed("\nCCCC");
    try expectRow(g, 1, "BBBB");
    try expectRow(g, 2, "CCCC");
}

test "repeated scroll rotations preserve logical rows through clone resize and erase" {
    var grid = try Grid.init(testing.allocator, 5, 3);
    defer grid.deinit();
    try grid.feed("one\ntwo\nthree\nfour\nfive");

    try expectRow(grid, 1, "three");
    try expectRow(grid, 2, "four");
    try expectRow(grid, 3, "five");

    var cloned = try grid.clone(testing.allocator);
    defer cloned.deinit();
    try testing.expect(gridsEqual(grid, cloned));

    try cloned.feed("\x1b[2;2H\x1b[K");
    try expectRow(cloned, 1, "three");
    try expectRow(cloned, 2, "f");
    try expectRow(cloned, 3, "five");

    try grid.resize(7, 4);
    try expectRow(grid, 1, "three");
    try expectRow(grid, 2, "four");
    try expectRow(grid, 3, "five");
    try expectRow(grid, 4, "");
    try testing.expectEqual(@as(u16, 0), grid.row_origin);
}

test "diff compares logical rows across different physical origins" {
    var previous = try Grid.init(testing.allocator, 5, 3);
    defer previous.deinit();
    try previous.feed("one\ntwo\nthree\nfour");

    var target = try Grid.init(testing.allocator, 5, 3);
    defer target.deinit();
    try target.feed("two\nthree\nfour");
    try target.feed("\x1b[2;2HX");

    var diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diff.deinit();
    try Grid.diffTo(previous, target, &diff.writer);
    try previous.feed(diff.written());

    try testing.expect(gridsEqual(previous, target));
}

test "alternate screen restores a rotated normal grid" {
    var grid = try Grid.init(testing.allocator, 5, 3);
    defer grid.deinit();
    try grid.feed("one\ntwo\nthree\nfour");

    try grid.feed("\x1b[?1049h");
    try grid.feed("alternate");
    try grid.feed("\x1b[?1049l");

    try expectRow(grid, 1, "two");
    try expectRow(grid, 2, "three");
    try expectRow(grid, 3, "four");
}

test "wide and combining cells survive repeated row rotations" {
    var grid = try Grid.init(testing.allocator, 6, 2);
    defer grid.deinit();
    try grid.feed("界e\u{0301}\nplain\n界e\u{0301}");

    try expectWideCellInvariant(grid);
    try expectRow(grid, 1, "plain");
    try expectRow(grid, 2, "界e\u{0301}");
}

test "snapshot renders full grid" {
    var g = try Grid.init(testing.allocator, 3, 2);
    defer g.deinit();
    try g.feed("\x1b[1;1Hab\x1b[2;1Hcd");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try g.snapshot(&buf);
    try testing.expectEqualStrings("|ab |\n|cd |\n", buf.items);
}

test "sync updates buffer until DECRST" {
    var g = try Grid.init(testing.allocator, 4, 2);
    defer g.deinit();

    try g.feed("\x1b[?2026h");
    try g.feed("ab");
    try expectRow(g, 1, "");

    try g.feed("\x1b[?2026l");
    try expectRow(g, 1, "ab");
}

test "alternate screen restores the normal grid after DECRST 1049" {
    var g = try Grid.init(testing.allocator, 8, 2);
    defer g.deinit();

    try g.feed("normal");
    try g.feed("\x1b[?25l\x1b[?1049h");
    try testing.expect(!g.cursor_visible);
    try g.feed("approval");
    try expectRow(g, 1, "approval");

    try g.feed("\x1b[?25h\x1b[?1049l");
    try testing.expect(g.cursor_visible);
    try expectRow(g, 1, "normal");
}

test "alternate screen preserves the resized normal grid after DECRST 1049" {
    var g = try Grid.init(testing.allocator, 8, 2);
    defer g.deinit();

    try g.feed("normal");
    try g.feed("\x1b[?1049h");
    try g.feed("approval");
    try g.resize(12, 3);
    try g.feed("\x1b[2;1Hresized approval");

    try g.feed("\x1b[?1049l");
    try expectRow(g, 1, "normal");
    try testing.expectEqual(@as(u16, 12), g.cols);
    try testing.expectEqual(@as(u16, 3), g.rows);
}

test "partial CSI across feed boundaries" {
    var g = try Grid.init(testing.allocator, 6, 2);
    defer g.deinit();
    try g.feed("\x1b[2;");
    try g.feed("3Hx");
    try expectRow(g, 2, "  x");
}

test "CAN and SUB cancel partial CSI and OSC parser state" {
    var g = try Grid.init(testing.allocator, 12, 2);
    defer g.deinit();

    try g.feed("\x1b[2;");
    try g.feed("\x18\x1b[1;1Hcsi");
    try expectRow(g, 1, "csi");

    try g.feed("\x1b]8;;https://bad.example");
    try g.feed("\x1aplain");
    try expectRow(g, 1, "csiplain");
    try testing.expectEqual(@as(u32, 0), g.current_style.hyperlink_id);
}

test "SGR tracks indexed bg and applies it to written cells" {
    var g = try Grid.init(testing.allocator, 6, 1);
    defer g.deinit();
    try g.feed("\x1b[48;5;236mhi\x1b[0m");
    const c1 = g.cellAt(1, 1).?;
    const c2 = g.cellAt(1, 2).?;
    const c3 = g.cellAt(1, 3).?;
    try testing.expect(c1.style.bg.eql(.{ .indexed = 236 }));
    try testing.expect(c2.style.bg.eql(.{ .indexed = 236 }));
    try testing.expect(c3.style.bg.eql(.default));
}

test "EL with active bg fills cleared cells with that bg" {
    var g = try Grid.init(testing.allocator, 6, 1);
    defer g.deinit();
    try g.feed("\x1b[48;5;236mhi\x1b[K");
    var col: u16 = 1;
    while (col <= 6) : (col += 1) {
        const c = g.cellAt(1, col).?;
        try testing.expect(c.style.bg.eql(.{ .indexed = 236 }));
    }
}

test "SGR 0 resets to default" {
    var g = try Grid.init(testing.allocator, 4, 1);
    defer g.deinit();
    try g.feed("\x1b[1;4;48;5;236mhi\x1b[0mok");
    const hi1 = g.cellAt(1, 1).?;
    try testing.expect(hi1.style.flags.bold);
    try testing.expect(hi1.style.flags.underline);
    try testing.expect(hi1.style.bg.eql(.{ .indexed = 236 }));
    const ok1 = g.cellAt(1, 3).?;
    try testing.expect(!ok1.style.flags.bold);
    try testing.expect(!ok1.style.flags.underline);
    try testing.expect(ok1.style.bg.eql(.default));
}

test "SGR 9 and 29 apply and clear strikethrough" {
    var g = try Grid.init(testing.allocator, 3, 1);
    defer g.deinit();
    try g.feed("\x1b[9mx\x1b[29my");

    try testing.expect(g.cellAt(1, 1).?.style.flags.strike);
    try testing.expect(!g.cellAt(1, 2).?.style.flags.strike);
}

test "presentation boundary resumes and steadies strikethrough" {
    var source = try Grid.init(testing.allocator, 2, 1);
    defer source.deinit();
    try source.feed("\x1b[9mx");

    var resume_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer resume_writer.deinit();
    try source.writePresentationResume(&resume_writer.writer);
    try testing.expectEqualStrings("\x1b[0m\x1b[9m", resume_writer.written());

    var resumed = try Grid.init(testing.allocator, 2, 1);
    defer resumed.deinit();
    try resumed.feed(resume_writer.written());
    try resumed.feed("y");
    try testing.expect(resumed.cellAt(1, 1).?.style.flags.strike);

    var steady_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer steady_writer.deinit();
    try source.writePresentationSteady(&steady_writer.writer);
    try testing.expectEqualStrings("\x1b[0m", steady_writer.written());

    try resumed.feed(steady_writer.written());
    try resumed.feed("z");
    try testing.expect(!resumed.cellAt(1, 2).?.style.flags.strike);
}

test "presentation resume preserves OSC 8 parameters and close clears them" {
    var source = try Grid.init(testing.allocator, 4, 1);
    defer source.deinit();
    try source.feed("\x1b]8;id=fx-42;https://example.com\x1b\\x");

    var resume_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer resume_writer.deinit();
    try source.writePresentationResume(&resume_writer.writer);
    try testing.expectEqualStrings(
        "\x1b]8;id=fx-42;https://example.com\x1b\\",
        resume_writer.written(),
    );

    var steady_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer steady_writer.deinit();
    try source.writePresentationSteady(&steady_writer.writer);
    try testing.expectEqualStrings("\x1b]8;;\x1b\\", steady_writer.written());

    try source.feed("\x1b]8;;\x1b\\");
    var closed_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer closed_writer.deinit();
    try source.writePresentationResume(&closed_writer.writer);
    try testing.expectEqualStrings("", closed_writer.written());
}

test "OSC 8 parameter replacement is atomic on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var source = try Grid.init(alloc, 4, 1);
    defer source.deinit();
    try source.feed("\x1b]8;id=fx-old;https://example.com\x1b\\");
    try source.osc_buffer.ensureTotalCapacity(alloc, 128);

    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        source.feed("\x1b]8;id=fx-new;https://example.com\x1b\\"),
    );
    try testing.expect(source.atControlSequenceBoundary());

    var old_resume_buf: [128]u8 = undefined;
    var old_resume: std.Io.Writer = .fixed(&old_resume_buf);
    try source.writePresentationResume(&old_resume);
    try testing.expectEqualStrings(
        "\x1b]8;id=fx-old;https://example.com\x1b\\",
        old_resume.buffered(),
    );

    failing.fail_index = std.math.maxInt(usize);
    try source.feed("\x1b]8;id=fx-new;https://example.com\x1b\\");
    try testing.expectEqual(@as(usize, 1), source.hyperlink_pool.items.len);

    var new_resume_buf: [128]u8 = undefined;
    var new_resume: std.Io.Writer = .fixed(&new_resume_buf);
    try source.writePresentationResume(&new_resume);
    try testing.expectEqualStrings(
        "\x1b]8;id=fx-new;https://example.com\x1b\\",
        new_resume.buffered(),
    );
}

test "SGR reset preserves active OSC 8 hyperlink until explicit close" {
    var g = try Grid.init(testing.allocator, 4, 1);
    defer g.deinit();
    try g.feed("\x1b]8;;https://example.com\x1b\\\x1b[31mx\x1b[0my\x1b]8;;\x1b\\z");

    const x = g.cellAt(1, 1).?;
    const y = g.cellAt(1, 2).?;
    const z = g.cellAt(1, 3).?;
    try testing.expect(x.style.hyperlink_id != 0);
    try testing.expectEqual(x.style.hyperlink_id, y.style.hyperlink_id);
    try testing.expectEqual(@as(u32, 0), z.style.hyperlink_id);
    try testing.expect(y.style.fg.eql(.default));
}

test "SGR truecolor 38;2;R;G;B" {
    var g = try Grid.init(testing.allocator, 2, 1);
    defer g.deinit();
    try g.feed("\x1b[38;2;10;20;30mx");
    const c = g.cellAt(1, 1).?;
    try testing.expect(c.style.fg.eql(.{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }));
}

test "empty SGR \\x1b[m resets like \\x1b[0m" {
    var g = try Grid.init(testing.allocator, 3, 1);
    defer g.deinit();
    try g.feed("\x1b[1;31mx\x1b[my");
    const x = g.cellAt(1, 1).?;
    try testing.expect(x.style.flags.bold);
    const y = g.cellAt(1, 2).?;
    try testing.expect(!y.style.flags.bold);
    try testing.expect(y.style.fg.eql(.default));
}

fn gridsEqual(a: Grid, b: Grid) bool {
    if (a.rows != b.rows or a.cols != b.cols) return false;
    var row: u16 = 1;
    while (row <= a.rows) : (row += 1) {
        var col: u16 = 1;
        while (col <= a.cols) : (col += 1) {
            if (!cellsEqual(a, a.cellAt(row, col).?, b, b.cellAt(row, col).?)) {
                return false;
            }
        }
    }
    return true;
}

/// Verifies that applying the diff between two grids reproduces the target grid.
fn assertDiffRoundTrip(
    cols: u16,
    rows: u16,
    initial_bytes: []const u8,
    mutate_bytes: []const u8,
) !void {
    var prev = try Grid.init(testing.allocator, cols, rows);
    defer prev.deinit();
    try prev.feed(initial_bytes);

    var next = try prev.clone(testing.allocator);
    defer next.deinit();
    try next.feed(mutate_bytes);

    var diff_buf: std.ArrayList(u8) = .empty;
    defer diff_buf.deinit(testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &diff_buf);
    try Grid.diffTo(prev, next, &writer.writer);
    diff_buf = writer.toArrayList();

    try prev.feed(diff_buf.items);
    try testing.expect(gridsEqual(prev, next));
}

test "diffTo round-trip: single cell change" {
    try assertDiffRoundTrip(10, 2, "hello\nworld", "\x1b[1;3HX");
}

test "diffTo round-trip: multi-row change" {
    try assertDiffRoundTrip(6, 3, "aaa\nbbb\nccc", "\x1b[1;1HZZZ\x1b[3;2HYY");
}

test "diffTo round-trip: bg color added" {
    try assertDiffRoundTrip(6, 1, "hello ", "\x1b[1;1H\x1b[48;5;236mHI\x1b[0m");
}

test "diffTo round-trip: no change yields empty-effect diff" {
    try assertDiffRoundTrip(4, 2, "abcd\nefgh", "");
}

test "diffTo round-trip: full-row replacement" {
    try assertDiffRoundTrip(8, 2, "oldline1\noldline2", "\x1b[1;1Hnewline1\x1b[2;1Hnewline2");
}

test "diffTo round-trip: wide cell replacement" {
    try assertDiffRoundTrip(6, 1, "abcdef", "\x1b[1;2H\xe7\x95\x8c");
}

test "diffTo round-trips exact Unicode display-unit bytes" {
    const cases = [_][]const u8{
        "\u{2600}\u{FE0E}",
        "\u{2600}\u{FE0F}",
        "\u{1F44D}\u{1F3FD}",
        "\u{1F1FA}\u{1F1F8}",
        "#\u{FE0F}\u{20E3}",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "\u{1F469}\u{200D}\u{1F4BB}",
    };
    for (cases) |text| try assertDiffRoundTrip(8, 1, "", text);
}

test "Unicode display diff anchors vertical dividers at their grid columns" {
    var prev = try Grid.init(testing.allocator, 12, 1);
    defer prev.deinit();
    var next = try prev.clone(testing.allocator);
    defer next.deinit();
    try next.feed("│ \u{231A}\u{FE0E}     │");

    var diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diff.deinit();
    try Grid.diffTo(prev, next, &diff.writer);
    try testing.expect(std.mem.find(u8, diff.written(), "\x1b[10G│") != null);
}

test "diffBand emits combining suffix changes" {
    var prev = try Grid.init(testing.allocator, 4, 1);
    defer prev.deinit();
    try prev.feed("e");

    var next = try Grid.init(testing.allocator, 4, 1);
    defer next.deinit();
    try next.feed("e\u{0301}");

    var diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diff.deinit();
    try Grid.diffBand(prev, next, 1, 1, &diff.writer);
    try testing.expect(std.mem.find(u8, diff.written(), "\u{0301}") != null);

    try prev.feed(diff.written());
    try expectRow(prev, 1, "e\u{0301}");
}

test "diffBand clears shifted wide-cell overlap before repaint" {
    var prev = try Grid.init(testing.allocator, 8, 1);
    defer prev.deinit();
    prev.autowrap = false;
    try prev.feed("\x1b[1;3HA🇺🇸B");

    var next = try Grid.init(testing.allocator, 8, 1);
    defer next.deinit();
    next.autowrap = false;
    try next.feed("\x1b[1;3H🇺🇸B ");

    var diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diff.deinit();
    try Grid.diffBand(prev, next, 1, 1, &diff.writer);
    try testing.expect(std.mem.find(u8, diff.written(), "\x1b[1;3H\x1b[4X") != null);

    var ascii = try Grid.init(testing.allocator, 8, 1);
    defer ascii.deinit();
    try ascii.feed("\x1b[1;3Htext");
    var ascii_next = try Grid.init(testing.allocator, 8, 1);
    defer ascii_next.deinit();
    try ascii_next.feed("\x1b[1;3Hnext");

    var ascii_diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer ascii_diff.deinit();
    try Grid.diffBand(ascii, ascii_next, 1, 1, &ascii_diff.writer);
    try testing.expect(std.mem.find(u8, ascii_diff.written(), "\x1b[4X") == null);

    var stationary = try Grid.init(testing.allocator, 8, 1);
    defer stationary.deinit();
    try stationary.feed("\x1b[1;3H🇺🇸");
    var stationary_next = try Grid.init(testing.allocator, 8, 1);
    defer stationary_next.deinit();
    try stationary_next.feed("\x1b[1;3H🇨🇦");

    var stationary_diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stationary_diff.deinit();
    try Grid.diffBand(stationary, stationary_next, 1, 1, &stationary_diff.writer);
    try testing.expect(std.mem.find(u8, stationary_diff.written(), "X") == null);
}

test "diffBand temporarily enables autowrap for a suffixed wide cell at the margin" {
    var prev = try Grid.init(testing.allocator, 6, 2);
    defer prev.deinit();
    prev.autowrap = false;

    var next = try Grid.init(testing.allocator, 6, 2);
    defer next.deinit();
    next.autowrap = false;
    try next.feed("\x1b[1;5H👩‍💻\x1b[2;1HZ");

    var diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diff.deinit();
    try Grid.diffBand(prev, next, 1, 2, &diff.writer);
    try testing.expect(std.mem.find(u8, diff.written(), "\x1b[?7h👩‍💻\x1b[?7l") != null);

    var non_margin_prev = try Grid.init(testing.allocator, 6, 1);
    defer non_margin_prev.deinit();
    non_margin_prev.autowrap = false;
    var non_margin = try Grid.init(testing.allocator, 6, 1);
    defer non_margin.deinit();
    non_margin.autowrap = false;
    try non_margin.feed("\x1b[1;4H👩‍💻");

    var non_margin_diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer non_margin_diff.deinit();
    try Grid.diffBand(non_margin_prev, non_margin, 1, 1, &non_margin_diff.writer);
    try testing.expect(std.mem.find(u8, non_margin_diff.written(), "\x1b[?7h") == null);
    try testing.expect(std.mem.find(u8, non_margin_diff.written(), "👩‍💻") != null);
}

test "diffTo emits \\x1b[0m at end when last style was non-default" {
    var prev = try Grid.init(testing.allocator, 4, 1);
    defer prev.deinit();
    var next = try prev.clone(testing.allocator);
    defer next.deinit();
    try next.feed("\x1b[1;31mAB");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try Grid.diffTo(prev, next, &writer.writer);
    buf = writer.toArrayList();
    try testing.expect(std.mem.find(u8, buf.items, "\x1b[0m") != null);
}

test "OSC 8 hyperlink round-trips through diffBand" {
    var prev = try Grid.init(testing.allocator, 16, 1);
    defer prev.deinit();
    var next = try prev.clone(testing.allocator);
    defer next.deinit();
    try next.feed("\x1b]8;;https://x.com/vercel_dev\x1b\\@vercel_dev\x1b]8;;\x1b\\");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try Grid.diffBand(prev, next, 1, 1, &writer.writer);
    buf = writer.toArrayList();

    try testing.expect(std.mem.find(u8, buf.items, "\x1b]8;;https://x.com/vercel_dev\x1b\\") != null);
    try testing.expect(std.mem.endsWith(u8, buf.items, "\x1b]8;;\x1b\\"));
}

test "diffBand reopens an OSC 8 hyperlink for each emitted row" {
    var prev = try Grid.init(testing.allocator, 4, 2);
    defer prev.deinit();
    var next = try prev.clone(testing.allocator);
    defer next.deinit();
    try next.feed("\x1b]8;;https://example.com\x1b\\abcd\x1b[2;1Hefgh\x1b]8;;\x1b\\");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try Grid.diffBand(prev, next, 1, 2, &writer.writer);
    buf = writer.toArrayList();

    const marker = "\x1b]8;;https://example.com\x1b\\";
    var opens: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, buf.items[start..], marker)) |offset| {
        opens += 1;
        start += offset + marker.len;
    }
    try testing.expectEqual(@as(usize, 2), opens);
}

test "diffBand clears active presentation before plain repaint cells" {
    var previous = try Grid.init(testing.allocator, 8, 2);
    defer previous.deinit();
    previous.defer_sync_updates = false;
    try previous.feed("\x1b]8;;https://active.example\x1b\\\x1b[1m");

    var target = try Grid.init(testing.allocator, 8, 2);
    defer target.deinit();
    target.defer_sync_updates = false;
    try target.feed("q");

    var diff: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diff.deinit();
    try Grid.diffBand(previous, target, 1, 1, &diff.writer);
    try previous.feed(diff.written());

    const cell = previous.cellAt(1, 1).?;
    try testing.expectEqual(@as(u21, 'q'), cell.codepoint);
    try testing.expect(!cell.style.flags.bold);
    try testing.expectEqual(@as(u32, 0), cell.style.hyperlink_id);
    try testing.expect(previous.current_style.eql(.{}));
}

test "OSC 8 hyperlink survives Grid.clone" {
    var src = try Grid.init(testing.allocator, 16, 1);
    defer src.deinit();
    try src.feed("\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\");

    var dup = try src.clone(testing.allocator);
    defer dup.deinit();

    const cell = dup.cellAt(1, 1).?;
    try testing.expect(cell.style.hyperlink_id != 0);
    const url = dup.hyperlinkUrl(cell.style.hyperlink_id).?;
    try testing.expectEqualStrings("https://example.com", url);
}

test "production editing scroll region origin save restore and modes" {
    var grid = try Grid.init(testing.allocator, 8, 4);
    defer grid.deinit();

    try grid.feed("abcdefgh\x1b[1;3H\x1b[2@XY\x1b[P\x1b[2X");
    try expectRow(grid, 1, "abXY  f");

    try grid.feed("\x1b[2;4r\x1b[?6h\x1b[1;1HA\nB\nC\nD");
    try testing.expectEqual(@as(u16, 2), grid.scroll_top);
    try testing.expectEqual(@as(u16, 4), grid.scroll_bottom);
    try testing.expect(grid.origin_mode);
    try expectRow(grid, 2, "B");
    try expectRow(grid, 3, "C");
    try expectRow(grid, 4, "D");

    try grid.feed("\x1b7\x1b[4;5HZ\x1b8Q");
    try testing.expectEqual(@as(u21, 'Q'), grid.cellAt(4, 2).?.codepoint);
    try grid.feed("\x1b[?7l\x1b[4h\x1b[?2004h\x1b[?1000h\x1b[?1004h\x1b[>1u");
    try testing.expect(!grid.autowrap);
    try testing.expect(grid.insert_mode);
    try testing.expect(grid.bracketed_paste);
    try testing.expect(grid.mouse_modes != 0);
    try testing.expect(grid.focus_tracking);
    try testing.expect(grid.keyboard_protocol);
}

test "tabs alternate screen and fragmented UTF-8 preserve cell invariants" {
    var grid = try Grid.init(testing.allocator, 12, 3);
    defer grid.deinit();
    try grid.feed("A\tB\x1bH\r\tC");
    try testing.expectEqual(@as(u21, 'C'), grid.cellAt(1, 9).?.codepoint);
    try grid.feed("\x1b[?1049hALT\x1b[?1049l");
    try testing.expectEqual(@as(u21, 'A'), grid.cellAt(1, 1).?.codepoint);
    try grid.feed("\xe7\x95");
    try grid.feed("\x8ce");
    try grid.feed("\xcc\x81");
    try expectWideCellInvariant(grid);
}

test "fragmented native queries emit one ordered reply and observational modes emit none" {
    var native = try Grid.init(testing.allocator, 80, 24);
    defer native.deinit();
    try native.feed("\x1b[3;7H");
    var first = try native.feedMode("\x1b[6", .native_live);
    defer first.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), first.replies.items.len);
    var second = try native.feedMode("n\x1b[18t", .native_live);
    defer second.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), second.replies.items.len);
    try testing.expectEqualStrings("\x1b[3;7R", second.replies.items[0].bytes);
    try testing.expectEqualStrings("\x1b[8;24;80t", second.replies.items[1].bytes);

    var tmux = try Grid.init(testing.allocator, 80, 24);
    defer tmux.deinit();
    var tmux_result = try tmux.feedMode("\x1b[6n\x1b[18t", .tmux_live);
    defer tmux_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tmux_result.replies.items.len);

    var replay = try Grid.init(testing.allocator, 80, 24);
    defer replay.deinit();
    var replay_result = try replay.feedMode("\x1b[6n\x1b[18t", .journal_replay);
    defer replay_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), replay_result.replies.items.len);
}

test "render snapshot is immutable row-major styled state" {
    var grid = try Grid.init(testing.allocator, 5, 2);
    defer grid.deinit();
    try grid.feed("\x1b[31;44;1mA\xe7\x95\x8c\x1b[?25l\x1b[5 q");
    var snapshot = try grid.renderSnapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);
    try snapshot.view().validate();
    try testing.expectEqual(contracts.CellKind.single, snapshot.cells[0].kind);
    try testing.expect(snapshot.cells[0].style.bold);
    try testing.expectEqual(contracts.CellKind.wide, snapshot.cells[1].kind);
    try testing.expectEqual(contracts.CellKind.continuation, snapshot.cells[2].kind);
    try testing.expect(!snapshot.cursor.visible);
    try testing.expectEqual(contracts.CursorShape.bar, snapshot.cursor.shape);
    try grid.feed("Z");
    try testing.expectEqualStrings("A", snapshot.cells[0].text);
}

test "checkpoint round trip preserves complete fragmented parser state" {
    var live = try Grid.init(testing.allocator, 12, 4);
    defer live.deinit();
    try live.feed("normal\x1b[?1049h\x1b[31mALT\x1b[2;4r\x1b[?6h");
    try live.feed("\x1b]8;;https://example.com\x1b\\X");
    try live.feed("\x1b[12;");

    const payload = try live.checkpointPayload(testing.allocator);
    defer testing.allocator.free(payload);
    var restored = try Grid.restoreCheckpoint(testing.allocator, payload);
    defer restored.deinit();
    const repeated = try restored.checkpointPayload(testing.allocator);
    defer testing.allocator.free(repeated);
    try testing.expectEqualSlices(u8, payload, repeated);

    try live.feed("3H\xe7\x95");
    try restored.feed("3H\xe7\x95");
    const fragmented = try restored.checkpointPayload(testing.allocator);
    defer testing.allocator.free(fragmented);
    var fragmented_restore = try Grid.restoreCheckpoint(
        testing.allocator,
        fragmented,
    );
    defer fragmented_restore.deinit();
    try live.feed("\x8c\x1b[?1049l");
    try restored.feed("\x8c\x1b[?1049l");
    try fragmented_restore.feed("\x8c\x1b[?1049l");
    const expected = try live.checkpointPayload(testing.allocator);
    defer testing.allocator.free(expected);
    const actual = try restored.checkpointPayload(testing.allocator);
    defer testing.allocator.free(actual);
    const fragmented_actual = try fragmented_restore.checkpointPayload(
        testing.allocator,
    );
    defer testing.allocator.free(fragmented_actual);
    try testing.expectEqualSlices(u8, expected, actual);
    try testing.expectEqualSlices(u8, expected, fragmented_actual);
}

test "checkpoint rejects unsupported revision corruption and trailing bytes" {
    var grid = try Grid.init(testing.allocator, 4, 2);
    defer grid.deinit();
    try grid.feed("ok");
    const payload = try grid.checkpointPayload(testing.allocator);
    defer testing.allocator.free(payload);

    const unsupported = try testing.allocator.dupe(u8, payload);
    defer testing.allocator.free(unsupported);
    std.mem.writeInt(u16, unsupported[4..6], checkpoint_schema_revision + 1, .little);
    try testing.expectError(
        error.UnsupportedEngineRevision,
        Grid.restoreCheckpoint(testing.allocator, unsupported),
    );
    try testing.expectError(
        error.InvalidEngineCheckpoint,
        Grid.restoreCheckpoint(testing.allocator, payload[0 .. payload.len - 1]),
    );
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ payload, "x" });
    defer testing.allocator.free(trailing);
    try testing.expectError(
        error.InvalidEngineCheckpoint,
        Grid.restoreCheckpoint(testing.allocator, trailing),
    );
}

test "checkpoint preserves fragmented OSC DCS and synchronized updates" {
    var sync_live = try Grid.init(testing.allocator, 10, 2);
    defer sync_live.deinit();
    try sync_live.feed("\x1b[?2026hbuffered");
    const sync_payload = try sync_live.checkpointPayload(testing.allocator);
    defer testing.allocator.free(sync_payload);
    var sync_restored = try Grid.restoreCheckpoint(
        testing.allocator,
        sync_payload,
    );
    defer sync_restored.deinit();
    try sync_live.feed("\x1b[?2026l");
    try sync_restored.feed("\x1b[?2026l");
    try expectRow(sync_restored, 1, "buffered");

    var strings = try Grid.init(testing.allocator, 10, 2);
    defer strings.deinit();
    try strings.feed("\x1b]8;;https://partial");
    const osc_payload = try strings.checkpointPayload(testing.allocator);
    defer testing.allocator.free(osc_payload);
    var osc_restored = try Grid.restoreCheckpoint(testing.allocator, osc_payload);
    defer osc_restored.deinit();
    try osc_restored.feed(".example\x1b\\X\x1bP$q");
    const dcs_payload = try osc_restored.checkpointPayload(testing.allocator);
    defer testing.allocator.free(dcs_payload);
    var dcs_restored = try Grid.restoreCheckpoint(testing.allocator, dcs_payload);
    defer dcs_restored.deinit();
    var dcs_result = try dcs_restored.feedMode("m\x1b\\", .native_live);
    defer dcs_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), dcs_result.replies.items.len);
    try testing.expectEqualStrings("\x1bP1$r0m\x1b\\", dcs_result.replies.items[0].bytes);
}

test "parser and reply collections enforce fixed bounds" {
    var grid = try Grid.init(testing.allocator, 10, 2);
    defer grid.deinit();
    try testing.expectError(
        error.TooManyCsiParameters,
        grid.feed("\x1b[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1H"),
    );

    var replies = try Grid.init(testing.allocator, 10, 2);
    defer replies.deinit();
    try testing.expectError(
        error.ReplyEffectCapacityExceeded,
        replies.feedMode("\x1b[5n" ** 17, .native_live),
    );

    var osc = try Grid.init(testing.allocator, 10, 2);
    defer osc.deinit();
    const oversized = try testing.allocator.alloc(u8, max_string_bytes + 3);
    defer testing.allocator.free(oversized);
    oversized[0] = 0x1b;
    oversized[1] = ']';
    @memset(oversized[2..], 'x');
    try testing.expectError(error.ControlStringTooLarge, osc.feed(oversized));
}

fn checkOwnedEngineAllocationFailures(alloc: Allocator) !void {
    var grid = try Grid.init(alloc, 12, 3);
    defer grid.deinit();
    var result = try grid.feedMode("\x1b[6n", .native_live);
    defer result.deinit(alloc);
    var snapshot = try grid.renderSnapshot(alloc);
    defer snapshot.deinit(alloc);
    const payload = try grid.checkpointPayload(alloc);
    defer alloc.free(payload);
    var restored = try Grid.restoreCheckpoint(alloc, payload);
    defer restored.deinit();
}

test "owned effects snapshots and checkpoints handle allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkOwnedEngineAllocationFailures,
        .{},
    );
}

test "bounded deterministic parser and checkpoint fuzz" {
    var random = std.Random.DefaultPrng.init(0x46585445);
    const source = random.random();
    var bytes: [96]u8 = undefined;
    for (0..256) |_| {
        source.bytes(&bytes);
        const length = source.uintLessThan(usize, bytes.len + 1);
        var grid = try Grid.init(testing.allocator, 24, 8);
        defer grid.deinit();
        var offset: usize = 0;
        while (offset < length) {
            const fragment = @min(
                length - offset,
                source.uintLessThan(usize, 8) + 1,
            );
            var result = grid.feedMode(
                bytes[offset .. offset + fragment],
                .journal_replay,
            ) catch break;
            result.deinit(testing.allocator);
            offset += fragment;
        }
        const payload = grid.checkpointPayload(testing.allocator) catch continue;
        defer testing.allocator.free(payload);
        var restored = try Grid.restoreCheckpoint(testing.allocator, payload);
        defer restored.deinit();
        const repeated = try restored.checkpointPayload(testing.allocator);
        defer testing.allocator.free(repeated);
        try testing.expectEqualSlices(u8, payload, repeated);
    }
}

test "bounded deterministic corrupt checkpoint fuzz" {
    var base = try Grid.init(testing.allocator, 24, 8);
    defer base.deinit();
    try base.feed("\x1b[31mcheckpoint\xe7\x95\x8c\x1b[?1049hALT");
    const payload = try base.checkpointPayload(testing.allocator);
    defer testing.allocator.free(payload);
    var random = std.Random.DefaultPrng.init(0x46584350);
    const source = random.random();
    for (0..256) |_| {
        const length = source.uintLessThan(usize, payload.len + 17);
        const candidate = try testing.allocator.alloc(u8, length);
        defer testing.allocator.free(candidate);
        source.bytes(candidate);
        const copied = @min(candidate.len, payload.len);
        @memcpy(candidate[0..copied], payload[0..copied]);
        if (candidate.len != 0) {
            const changes = source.uintLessThan(usize, 4) + 1;
            for (0..changes) |_| {
                candidate[source.uintLessThan(usize, candidate.len)] ^=
                    source.int(u8) | 1;
            }
        }
        var restored = Grid.restoreCheckpoint(
            testing.allocator,
            candidate,
        ) catch continue;
        restored.deinit();
    }
}

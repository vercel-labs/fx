//! Bounded styled-cell canvas for terminal Mermaid diagrams.
//!
//! A canvas cell keeps geometry separate from presentation:
//!
//!     route bits ──> junction mask ──> Unicode box glyph
//!                                      │
//!     semantic class ──────────────────┴──> terminal style
//!
//! Wide glyphs occupy one glyph cell followed by empty continuation cells.
//! The continuation cells preserve terminal columns without emitting bytes.

const std = @import("std");
const display_width = @import("../../../core/shared/display_width.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const LineKind = model.LineKind;
const MermaidError = model.MermaidError;

pub const max_cells = 1 << 20;

pub const Styles = struct {
    dim: []const u8 = "",
    reset: []const u8 = "",
};

pub const CellClass = enum { empty, border, text, edge, edge_label };

const Cell = struct {
    glyph: []const u8 = " ",
    class: CellClass = .empty,
    mask: u8 = 0,
    line: LineKind = .solid,
    occupied: bool = false,
};

const up_bit: u8 = 1;
const down_bit: u8 = 2;
const left_bit: u8 = 4;
const right_bit: u8 = 8;

pub const Canvas = struct {
    alloc: Allocator,
    width: usize,
    height: usize,
    cells: []Cell,
    current_line: LineKind = .solid,

    pub fn init(alloc: Allocator, width: usize, height: usize) MermaidError!Canvas {
        if (width == 0 or height == 0 or width > max_cells / height) return error.TooComplex;
        const cells = try alloc.alloc(Cell, width * height);
        @memset(cells, .{});
        return .{ .alloc = alloc, .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Canvas) void {
        self.alloc.free(self.cells);
        self.* = undefined;
    }

    fn at(self: *Canvas, x: usize, y: usize) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[y * self.width + x];
    }

    pub fn markOccupied(self: *Canvas, x: usize, y: usize) void {
        const cell = self.at(x, y) orelse return;
        cell.occupied = true;
    }

    pub fn set(self: *Canvas, x: usize, y: usize, glyph: []const u8, class: CellClass) void {
        const cell = self.at(x, y) orelse return;
        cell.glyph = glyph;
        cell.class = class;
        cell.mask = 0;
    }

    pub fn addBits(self: *Canvas, x: usize, y: usize, bits: u8) void {
        const cell = self.at(x, y) orelse return;
        if (cell.occupied) return;
        const had_mask = cell.mask != 0;
        cell.mask |= bits;
        cell.line = if (had_mask) mergeLineKind(cell.line, self.current_line) else self.current_line;
        if (cell.class != .border) cell.class = .edge;
    }

    pub fn junction(self: *Canvas, x: usize, y: usize, bits: u8) void {
        const cell = self.at(x, y) orelse return;
        if (cell.mask == 0) cell.line = self.current_line;
        cell.mask |= bits;
        if (cell.class != .border) cell.class = .edge;
    }

    pub fn horizontal(self: *Canvas, y: usize, raw_x0: usize, raw_x1: usize) void {
        const x0 = @min(raw_x0, raw_x1);
        const x1 = @max(raw_x0, raw_x1);
        var x = x0;
        while (x <= x1) : (x += 1) {
            var bits: u8 = 0;
            if (x > x0) bits |= left_bit;
            if (x < x1) bits |= right_bit;
            self.addBits(x, y, bits);
        }
    }

    pub fn vertical(self: *Canvas, x: usize, raw_y0: usize, raw_y1: usize) void {
        const y0 = @min(raw_y0, raw_y1);
        const y1 = @max(raw_y0, raw_y1);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var bits: u8 = 0;
            if (y > y0) bits |= up_bit;
            if (y < y1) bits |= down_bit;
            self.addBits(x, y, bits);
        }
    }

    pub fn finalize(self: *Canvas) void {
        for (self.cells) |*cell| {
            if (cell.mask == 0 or !std.mem.eql(u8, cell.glyph, " ")) continue;
            const glyph = maskGlyph(cell.mask);
            cell.glyph = switch (cell.line) {
                .solid => glyph,
                .dotted => dottedGlyph(glyph),
                .thick => thickGlyph(glyph),
            };
        }
    }

    pub fn flipVertical(self: *Canvas) void {
        var y: usize = 0;
        while (y < self.height / 2) : (y += 1) {
            const other = self.height - 1 - y;
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                std.mem.swap(Cell, &self.cells[y * self.width + x], &self.cells[other * self.width + x]);
            }
        }
        for (self.cells) |*cell| cell.glyph = flipGlyphVertical(cell.glyph);
    }

    pub fn flipHorizontal(self: *Canvas) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width / 2) : (x += 1) {
                const other = self.width - 1 - x;
                std.mem.swap(Cell, &self.cells[y * self.width + x], &self.cells[y * self.width + other]);
            }
            for (self.cells[y * self.width .. (y + 1) * self.width]) |*cell| {
                cell.glyph = flipGlyphHorizontal(cell.glyph);
            }
            x = 0;
            while (x < self.width) {
                const class = self.cells[y * self.width + x].class;
                if (class != .text and class != .edge_label) {
                    x += 1;
                    continue;
                }
                const start = x;
                while (x < self.width and self.cells[y * self.width + x].class == class) : (x += 1) {}
                std.mem.reverse(Cell, self.cells[y * self.width + start .. y * self.width + x]);
            }
        }
    }

    pub fn toOwnedBytes(self: *Canvas, styles: Styles) Allocator.Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.alloc);
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var last: usize = 0;
            var x = self.width;
            while (x > 0) {
                x -= 1;
                const cell = self.cells[y * self.width + x];
                if (!std.mem.eql(u8, cell.glyph, " ") and cell.glyph.len > 0) {
                    last = x + 1;
                    break;
                }
            }
            var active_dim = false;
            x = 0;
            while (x < last) : (x += 1) {
                const cell = self.cells[y * self.width + x];
                if (cell.glyph.len == 0) continue;
                const want_dim = (cell.class == .border or cell.class == .edge) and
                    styles.dim.len > 0 and styles.reset.len > 0;
                if (want_dim != active_dim) {
                    try output.appendSlice(self.alloc, if (want_dim) styles.dim else styles.reset);
                    active_dim = want_dim;
                }
                try output.appendSlice(self.alloc, cell.glyph);
            }
            if (active_dim) try output.appendSlice(self.alloc, styles.reset);
            try output.append(self.alloc, '\n');
        }
        return output.toOwnedSlice(self.alloc);
    }
};

pub fn drawText(canvas: *Canvas, text: []const u8, start_x: usize, y: usize, class: CellClass) void {
    var source_index: usize = 0;
    var x = start_x;
    while (source_index < text.len and x < canvas.width and y < canvas.height) {
        const unit = display_width.displayUnitAt(text, source_index);
        if (unit.byte_len == 0) break;
        const cell_width = @max(@as(usize, 1), unit.cell_width);
        if (x + cell_width > canvas.width) break;
        canvas.set(x, y, text[source_index .. source_index + unit.byte_len], class);
        canvas.markOccupied(x, y);
        var continuation: usize = 1;
        while (continuation < cell_width) : (continuation += 1) {
            canvas.set(x + continuation, y, "", class);
            canvas.markOccupied(x + continuation, y);
        }
        x += cell_width;
        source_index += unit.byte_len;
    }
}

fn mergeLineKind(left: LineKind, right: LineKind) LineKind {
    if (left == .thick or right == .thick) return .thick;
    if (left == .dotted and right == .dotted) return .dotted;
    return .solid;
}

fn maskGlyph(mask: u8) []const u8 {
    return switch (mask) {
        0 => " ",
        up_bit, down_bit, up_bit | down_bit => "│",
        left_bit, right_bit, left_bit | right_bit => "─",
        down_bit | right_bit => "┌",
        down_bit | left_bit => "┐",
        up_bit | right_bit => "└",
        up_bit | left_bit => "┘",
        up_bit | down_bit | right_bit => "├",
        up_bit | down_bit | left_bit => "┤",
        down_bit | left_bit | right_bit => "┬",
        up_bit | left_bit | right_bit => "┴",
        else => "┼",
    };
}

fn dottedGlyph(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "─")) return "╌";
    if (std.mem.eql(u8, glyph, "│")) return "╎";
    return glyph;
}

fn thickGlyph(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "─")) return "━";
    if (std.mem.eql(u8, glyph, "│")) return "┃";
    if (std.mem.eql(u8, glyph, "┌")) return "┏";
    if (std.mem.eql(u8, glyph, "┐")) return "┓";
    if (std.mem.eql(u8, glyph, "└")) return "┗";
    if (std.mem.eql(u8, glyph, "┘")) return "┛";
    if (std.mem.eql(u8, glyph, "├")) return "┣";
    if (std.mem.eql(u8, glyph, "┤")) return "┫";
    if (std.mem.eql(u8, glyph, "┬")) return "┳";
    if (std.mem.eql(u8, glyph, "┴")) return "┻";
    if (std.mem.eql(u8, glyph, "┼")) return "╋";
    return glyph;
}

fn flipGlyphVertical(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "┌")) return "└";
    if (std.mem.eql(u8, glyph, "┐")) return "┘";
    if (std.mem.eql(u8, glyph, "└")) return "┌";
    if (std.mem.eql(u8, glyph, "┘")) return "┐";
    if (std.mem.eql(u8, glyph, "╭")) return "╰";
    if (std.mem.eql(u8, glyph, "╮")) return "╯";
    if (std.mem.eql(u8, glyph, "╰")) return "╭";
    if (std.mem.eql(u8, glyph, "╯")) return "╮";
    if (std.mem.eql(u8, glyph, "┬")) return "┴";
    if (std.mem.eql(u8, glyph, "┴")) return "┬";
    if (std.mem.eql(u8, glyph, "┳")) return "┻";
    if (std.mem.eql(u8, glyph, "┻")) return "┳";
    if (std.mem.eql(u8, glyph, "▼")) return "▲";
    if (std.mem.eql(u8, glyph, "▲")) return "▼";
    if (std.mem.eql(u8, glyph, "▽")) return "△";
    if (std.mem.eql(u8, glyph, "△")) return "▽";
    return glyph;
}

fn flipGlyphHorizontal(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "┌")) return "┐";
    if (std.mem.eql(u8, glyph, "┐")) return "┌";
    if (std.mem.eql(u8, glyph, "└")) return "┘";
    if (std.mem.eql(u8, glyph, "┘")) return "└";
    if (std.mem.eql(u8, glyph, "╭")) return "╮";
    if (std.mem.eql(u8, glyph, "╮")) return "╭";
    if (std.mem.eql(u8, glyph, "╰")) return "╯";
    if (std.mem.eql(u8, glyph, "╯")) return "╰";
    if (std.mem.eql(u8, glyph, "├")) return "┤";
    if (std.mem.eql(u8, glyph, "┤")) return "├";
    if (std.mem.eql(u8, glyph, "┣")) return "┫";
    if (std.mem.eql(u8, glyph, "┫")) return "┣";
    if (std.mem.eql(u8, glyph, "◄")) return "▶";
    if (std.mem.eql(u8, glyph, "▶")) return "◄";
    if (std.mem.eql(u8, glyph, "◁")) return "▷";
    if (std.mem.eql(u8, glyph, "▷")) return "◁";
    return glyph;
}

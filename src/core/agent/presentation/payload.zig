const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TableColumnAlign = enum { left, right, center };

pub const TableRow = struct {
    cells: [][]u8,
};

pub const TablePayload = struct {
    rows: []TableRow,
    alignments: []TableColumnAlign,
    column_count: usize,
    /// Set while the table is still streaming: it holds only the rows that
    /// have ended so far, and the next payload for it replaces it.
    partial: bool = false,

    pub fn deinit(self: *TablePayload, alloc: Allocator) void {
        deinitTableRows(alloc, self.rows);
        alloc.free(self.rows);
        alloc.free(self.alignments);
        self.* = undefined;
    }

    pub fn clone(self: TablePayload, alloc: Allocator) !TablePayload {
        const rows = try alloc.alloc(TableRow, self.rows.len);
        var copied_rows: usize = 0;
        errdefer {
            deinitTableRows(alloc, rows[0..copied_rows]);
            alloc.free(rows);
        }

        for (self.rows, 0..) |row, row_index| {
            const cells = try alloc.alloc([]u8, row.cells.len);
            var copied_cells: usize = 0;
            errdefer {
                for (cells[0..copied_cells]) |cell| alloc.free(cell);
                alloc.free(cells);
            }
            for (row.cells, 0..) |cell, cell_index| {
                cells[cell_index] = try alloc.dupe(u8, cell);
                copied_cells += 1;
            }
            rows[row_index] = .{ .cells = cells };
            copied_rows += 1;
        }

        const alignments = try alloc.dupe(TableColumnAlign, self.alignments);
        errdefer alloc.free(alignments);
        return .{
            .rows = rows,
            .alignments = alignments,
            .column_count = self.column_count,
            .partial = self.partial,
        };
    }
};

pub const CodeBlockPayload = struct {
    language: []u8,
    code: []u8,

    pub fn deinit(self: *CodeBlockPayload, alloc: Allocator) void {
        alloc.free(self.language);
        alloc.free(self.code);
        self.* = undefined;
    }

    pub fn clone(self: CodeBlockPayload, alloc: Allocator) !CodeBlockPayload {
        const language = try alloc.dupe(u8, self.language);
        errdefer alloc.free(language);
        return .{
            .language = language,
            .code = try alloc.dupe(u8, self.code),
        };
    }
};

pub const TableCompletion = struct {
    ctx: *anyopaque,
    /// Takes ownership of `table` only when it returns successfully.
    deliver: *const fn (ctx: *anyopaque, table: TablePayload, out: *std.ArrayList(u8)) anyerror!void,
};

pub const CodeBlockCompletion = struct {
    ctx: *anyopaque,
    /// Takes ownership of `block` only when it returns successfully.
    deliver: *const fn (ctx: *anyopaque, block: CodeBlockPayload, out: *std.ArrayList(u8)) anyerror!void,
};

pub const ThematicRuleCompletion = struct {
    ctx: *anyopaque,
    deliver: *const fn (ctx: *anyopaque, out: *std.ArrayList(u8)) anyerror!void,
};

pub const MarkdownCompletions = struct {
    table: ?*const TableCompletion = null,
    /// Receives the rows of a table that is still streaming, marked partial,
    /// each time a row ends. The finished table still goes to `table`.
    table_preview: ?*const TableCompletion = null,
    code: ?*const CodeBlockCompletion = null,
    thematic_rule: ?*const ThematicRuleCompletion = null,
};

pub fn deinitTableRows(alloc: Allocator, rows: []TableRow) void {
    for (rows) |row| {
        for (row.cells) |cell| alloc.free(cell);
        alloc.free(row.cells);
    }
}

pub const FootnoteSink = struct {
    ctx: *anyopaque,
    register: *const fn (ctx: *anyopaque, alloc: Allocator, label: []const u8) anyerror!usize,
};

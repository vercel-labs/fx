//! Bounded graph and sequence layout for terminal Mermaid diagrams.

const std = @import("std");
const display_width = @import("../../../core/shared/display_width.zig");
const model = @import("model.zig");
const canvas_mod = @import("canvas.zig");
const label_text = @import("label.zig");

const Allocator = std.mem.Allocator;
const MermaidError = model.MermaidError;
const Graph = model.Graph;
const Node = model.Node;
const Edge = model.Edge;
const Head = model.Head;
const Sequence = model.Sequence;
const Canvas = canvas_mod.Canvas;
const Styles = canvas_mod.Styles;
const Wrapped = label_text.Wrapped;

const pad = 1;
const gap_x = 3;
const gap_y = 3;

const up_bit: u8 = 1;
const down_bit: u8 = 2;
const left_bit: u8 = 4;
const right_bit: u8 = 8;

const NodeLayout = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize,
    height: usize,
    center_x: usize = 0,
    center_y: usize = 0,
    rank: usize = 0,
    wrapped: Wrapped,

    fn deinit(self: *NodeLayout, alloc: Allocator) void {
        self.wrapped.deinit(alloc);
    }
};

/// Convert the parsed graph into terminal rows:
///
///     graph -> ranks -> node boxes -> routed edges -> glyph canvas -> rows
///
/// Ranking decides topology; coordinates and edge lanes are derived afterward.
pub fn render_graph(alloc: Allocator, graph: *const Graph, max_width: usize, styles: Styles) MermaidError!?[]u8 {
    if (graph.nodes.items.len == 0) return null;
    const ranks = try computeRanks(alloc, graph);
    defer alloc.free(ranks);
    var max_rank: usize = 0;
    for (ranks) |rank| max_rank = @max(max_rank, rank);

    const layouts = try alloc.alloc(NodeLayout, graph.nodes.items.len);
    var initialized: usize = 0;
    defer {
        for (layouts[0..initialized]) |*layout| layout.deinit(alloc);
        alloc.free(layouts);
    }
    for (graph.nodes.items, 0..) |node, index| {
        var wrapped = try label_text.wrap(alloc, node.label);
        errdefer wrapped.deinit(alloc);
        var content_width: usize = 1;
        for (wrapped.lines.items) |line| content_width = @max(content_width, display_width.visibleWidth(line));
        for (node.members.items) |member| content_width = @max(content_width, @min(label_text.wrap_width, display_width.visibleWidth(member)));
        const marker = node.shape == .start or node.shape == .finish;
        layouts[index] = .{
            .width = if (marker) 1 else content_width + 2 * pad + 2,
            .height = if (marker) 1 else wrapped.lines.items.len + 2 + if (node.members.items.len > 0) node.members.items.len + 1 else 0,
            .wrapped = wrapped,
            .rank = ranks[index],
        };
        initialized += 1;
    }

    const rows = try alloc.alloc(std.ArrayList(usize), max_rank + 1);
    defer {
        for (rows) |*row| row.deinit(alloc);
        alloc.free(rows);
    }
    for (rows) |*row| row.* = .empty;
    for (ranks, 0..) |rank, index| try rows[rank].append(alloc, index);

    const vertical = graph.direction == .down or graph.direction == .up;
    var diagram_width: usize = 1;
    var diagram_height: usize = 1;
    if (vertical) {
        var row_widths = try alloc.alloc(usize, rows.len);
        defer alloc.free(row_widths);
        var row_heights = try alloc.alloc(usize, rows.len);
        defer alloc.free(row_heights);
        for (rows, 0..) |row, rank| {
            var width: usize = 0;
            var height: usize = 1;
            for (row.items, 0..) |node_index, position| {
                if (position > 0) width += gap_x;
                width += layouts[node_index].width;
                height = @max(height, layouts[node_index].height);
            }
            row_widths[rank] = width;
            row_heights[rank] = height;
            diagram_width = @max(diagram_width, width);
        }
        var label_margin: usize = 0;
        for (graph.edges.items) |edge| {
            if (edge.label) |label| {
                label_margin = @max(label_margin, @min(label_text.wrap_width, display_width.visibleWidth(label)) + 1);
            }
        }
        diagram_width += label_margin;
        var y: usize = 0;
        for (rows, 0..) |row, rank| {
            var x = (diagram_width - row_widths[rank]) / 2;
            for (row.items) |node_index| {
                layouts[node_index].x = x;
                layouts[node_index].y = y + (row_heights[rank] - layouts[node_index].height) / 2;
                layouts[node_index].center_x = x + layouts[node_index].width / 2;
                layouts[node_index].center_y = layouts[node_index].y + layouts[node_index].height / 2;
                x += layouts[node_index].width + gap_x;
            }
            y += row_heights[rank];
            if (rank < max_rank) y += gap_y;
        }
        diagram_height = y;
    } else {
        var top_margin: usize = 0;
        var rank_gap: usize = gap_x + 2;
        for (graph.edges.items) |edge| {
            if (edge.label) |label| {
                top_margin = 2;
                rank_gap = @max(rank_gap, @min(label_text.wrap_width, display_width.visibleWidth(label)) + 3);
            }
        }
        var col_widths = try alloc.alloc(usize, rows.len);
        defer alloc.free(col_widths);
        var col_heights = try alloc.alloc(usize, rows.len);
        defer alloc.free(col_heights);
        for (rows, 0..) |row, rank| {
            var width: usize = 1;
            var height: usize = 0;
            for (row.items, 0..) |node_index, position| {
                width = @max(width, layouts[node_index].width);
                if (position > 0) height += 1;
                height += layouts[node_index].height;
            }
            col_widths[rank] = width;
            col_heights[rank] = height;
            diagram_height = @max(diagram_height, height);
        }
        var x: usize = 0;
        for (rows, 0..) |row, rank| {
            var y = (diagram_height - col_heights[rank]) / 2;
            for (row.items) |node_index| {
                layouts[node_index].x = x + (col_widths[rank] - layouts[node_index].width) / 2;
                layouts[node_index].y = top_margin + y;
                layouts[node_index].center_x = layouts[node_index].x + layouts[node_index].width / 2;
                layouts[node_index].center_y = layouts[node_index].y + layouts[node_index].height / 2;
                y += layouts[node_index].height + 1;
            }
            x += col_widths[rank];
            if (rank < max_rank) x += rank_gap;
        }
        diagram_width = x;
        diagram_height += top_margin;
    }

    var back_edges: usize = 0;
    for (graph.edges.items) |edge| {
        if (edge.from == edge.to or ranks[edge.to] <= ranks[edge.from]) back_edges += 1;
    }
    var canvas_width = diagram_width;
    var canvas_height = diagram_height;
    if (vertical and back_edges > 0) canvas_width += 2 + back_edges * 2;
    if (!vertical and back_edges > 0) canvas_height += 1 + back_edges * 2;
    if (canvas_width > max_width or canvas_width == 0 or canvas_height == 0 or
        canvas_width > canvas_mod.max_cells / canvas_height)
    {
        return null;
    }

    var canvas = try Canvas.init(alloc, canvas_width, canvas_height);
    defer canvas.deinit();
    for (graph.nodes.items, layouts) |node, layout| drawNode(&canvas, node, layout);

    var back_index: usize = 0;
    for (graph.edges.items) |edge| {
        canvas.current_line = edge.line;
        const from = layouts[edge.from];
        const to = layouts[edge.to];
        if (edge.from == edge.to) {
            drawSelfEdge(&canvas, from, edge);
        } else if (ranks[edge.to] > ranks[edge.from]) {
            if (vertical) drawForwardVertical(&canvas, from, to, edge) else drawForwardHorizontal(&canvas, from, to, edge);
        } else {
            if (vertical) {
                drawBackVertical(&canvas, from, to, edge, diagram_width + 1 + back_index * 2);
            } else {
                drawBackHorizontal(&canvas, from, to, edge, diagram_height + 1 + back_index * 2);
            }
            back_index += 1;
        }
    }
    canvas.finalize();
    if (graph.direction == .up) canvas.flipVertical();
    if (graph.direction == .left) canvas.flipHorizontal();
    return try canvas.toOwnedBytes(styles);
}

fn computeRanks(alloc: Allocator, graph: *const Graph) Allocator.Error![]usize {
    const count = graph.nodes.items.len;
    const ranks = try alloc.alloc(usize, count);
    errdefer alloc.free(ranks);
    @memset(ranks, 0);
    const indegree = try alloc.alloc(usize, count);
    defer alloc.free(indegree);
    @memset(indegree, 0);
    for (graph.edges.items) |edge| if (edge.from != edge.to) {
        indegree[edge.to] += 1;
    };
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(alloc);
    for (indegree, 0..) |degree, index| if (degree == 0) try queue.append(alloc, index);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const node = queue.items[cursor];
        for (graph.edges.items) |edge| {
            if (edge.from != node or edge.from == edge.to) continue;
            ranks[edge.to] = @max(ranks[edge.to], ranks[node] + 1);
            indegree[edge.to] -= 1;
            if (indegree[edge.to] == 0) try queue.append(alloc, edge.to);
        }
    }
    // Cyclic components stay at rank zero. This keeps layout bounded and their
    // edges are routed through the explicit back-edge lanes.
    return ranks;
}

fn drawNode(canvas: *Canvas, node: Node, layout: NodeLayout) void {
    if (node.shape == .start or node.shape == .finish) {
        canvas.set(layout.x, layout.y, if (node.shape == .start) "●" else "◉", .border);
        canvas.markOccupied(layout.x, layout.y);
        return;
    }
    const right = layout.x + layout.width - 1;
    const bottom = layout.y + layout.height - 1;
    const rounded = node.shape == .round or node.shape == .diamond;
    canvas.set(layout.x, layout.y, if (rounded) "╭" else "┌", .border);
    canvas.set(right, layout.y, if (rounded) "╮" else "┐", .border);
    canvas.set(layout.x, bottom, if (rounded) "╰" else "└", .border);
    canvas.set(right, bottom, if (rounded) "╯" else "┘", .border);
    var x = layout.x + 1;
    while (x < right) : (x += 1) {
        canvas.set(x, layout.y, "─", .border);
        canvas.set(x, bottom, "─", .border);
    }
    var y = layout.y + 1;
    while (y < bottom) : (y += 1) {
        canvas.set(layout.x, y, "│", .border);
        canvas.set(right, y, "│", .border);
    }
    y = layout.y;
    while (y <= bottom) : (y += 1) {
        x = layout.x;
        while (x <= right) : (x += 1) {
            canvas.markOccupied(x, y);
        }
    }

    const inner_width = layout.width - 2 * pad - 2;
    for (layout.wrapped.lines.items, 0..) |line, line_index| {
        const text = label_text.fit(line, inner_width);
        const text_width = display_width.visibleWidth(text);
        canvas_mod.drawText(canvas, text, layout.x + 1 + pad + (inner_width -| text_width) / 2, layout.y + 1 + line_index, .text);
    }
    if (node.members.items.len > 0) {
        const divider_y = layout.y + 1 + layout.wrapped.lines.items.len;
        canvas.set(layout.x, divider_y, "├", .border);
        canvas.set(right, divider_y, "┤", .border);
        x = layout.x + 1;
        while (x < right) : (x += 1) canvas.set(x, divider_y, "─", .border);
        for (node.members.items, 0..) |member, member_index| {
            canvas_mod.drawText(canvas, label_text.fit(member, inner_width), layout.x + 1 + pad, divider_y + 1 + member_index, .text);
        }
    }
}

/// A forward vertical edge uses a shared bus between adjacent ranks:
///
///          from
///            │
///       ─────┼─────  bus_y
///            │
///           ▼ to
fn drawForwardVertical(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge) void {
    const start_y = from.y + from.height - 1;
    if (to.y == 0 or to.y <= start_y) return;
    const end_y = to.y - 1;
    const bus_y = start_y + (end_y - start_y) / 2;
    canvas.junction(from.center_x, start_y, down_bit);
    canvas.vertical(from.center_x, start_y, bus_y);
    canvas.horizontal(bus_y, from.center_x, to.center_x);
    canvas.vertical(to.center_x, bus_y, end_y);
    drawHead(canvas, to.center_x, end_y, edge.head_to, "▼", up_bit);
    if (edge.head_from != .none) drawHead(canvas, from.center_x, start_y, edge.head_from, "▲", down_bit);
    if (edge.label) |label| drawEdgeLabel(canvas, label, bus_y, @min(from.center_x, to.center_x) + 1);
}

fn drawForwardHorizontal(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge) void {
    // The same bus geometry as drawForwardVertical, rotated 90 degrees.
    const start_x = from.x + from.width - 1;
    if (to.x == 0 or to.x <= start_x) return;
    const end_x = to.x - 1;
    const bus_x = start_x + (end_x - start_x) / 2;
    canvas.junction(start_x, from.center_y, right_bit);
    canvas.horizontal(from.center_y, start_x, bus_x);
    canvas.vertical(bus_x, from.center_y, to.center_y);
    canvas.horizontal(to.center_y, bus_x, end_x);
    drawHead(canvas, end_x, to.center_y, edge.head_to, "▶", left_bit);
    if (edge.head_from != .none) drawHead(canvas, start_x, from.center_y, edge.head_from, "◄", right_bit);
    if (edge.label) |label| {
        const label_width = end_x -| start_x -| 1;
        const fitted = label_text.fit(label, label_width);
        const label_x = start_x + 1 + (label_width -| display_width.visibleWidth(fitted)) / 2;
        canvas_mod.drawText(canvas, fitted, label_x, @min(from.center_y, to.center_y) -| 2, .edge_label);
    }
}

/// Back edges leave the ranked area through a dedicated side lane so they do
/// not cross node boxes:
///
///     target ◄────┐
///                 │ lane_x
///     source ─────┘
fn drawBackVertical(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge, lane_x: usize) void {
    const from_x = from.x + from.width - 1;
    const to_x = to.x + to.width - 1;
    canvas.junction(from_x, from.center_y, right_bit);
    canvas.horizontal(from.center_y, from_x, lane_x);
    canvas.vertical(lane_x, from.center_y, to.center_y);
    canvas.horizontal(to.center_y, to_x + 1, lane_x);
    drawHead(canvas, to_x + 1, to.center_y, edge.head_to, "◄", right_bit);
    if (edge.label) |label| drawEdgeLabel(canvas, label, @min(from.center_y, to.center_y), lane_x + 1);
}

fn drawBackHorizontal(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge, lane_y: usize) void {
    // Horizontal back edges use a bottom lane instead of a right-side lane.
    const from_y = from.y + from.height - 1;
    const to_y = to.y + to.height - 1;
    canvas.junction(from.center_x, from_y, down_bit);
    canvas.vertical(from.center_x, from_y, lane_y);
    canvas.horizontal(lane_y, from.center_x, to.center_x);
    canvas.vertical(to.center_x, lane_y, to_y + 1);
    drawHead(canvas, to.center_x, to_y + 1, edge.head_to, "▲", down_bit);
    if (edge.label) |label| drawEdgeLabel(canvas, label, lane_y, @min(from.center_x, to.center_x) + 1);
}

fn drawSelfEdge(canvas: *Canvas, node: NodeLayout, edge: Edge) void {
    const right = node.x + node.width - 1;
    if (right + 3 >= canvas.width) return;
    canvas.junction(right, node.center_y, right_bit);
    canvas.horizontal(node.center_y, right, right + 2);
    if (node.center_y + 2 < canvas.height) {
        canvas.vertical(right + 2, node.center_y, node.center_y + 2);
        canvas.horizontal(node.center_y + 2, right, right + 2);
        drawHead(canvas, right + 1, node.center_y + 2, edge.head_to, "◄", right_bit);
        if (edge.label) |label| drawEdgeLabel(canvas, label, node.center_y + 1, right + 3);
    }
}

fn drawHead(canvas: *Canvas, x: usize, y: usize, head: Head, arrow: []const u8, continuation: u8) void {
    if (head == .none) {
        canvas.addBits(x, y, continuation);
        return;
    }
    canvas.set(x, y, switch (head) {
        .none => arrow,
        .arrow => arrow,
        .circle => "o",
        .cross => "×",
        .triangle => if (std.mem.eql(u8, arrow, "▼")) "▽" else if (std.mem.eql(u8, arrow, "▲")) "△" else if (std.mem.eql(u8, arrow, "◄")) "◁" else "▷",
        .diamond_fill => "◆",
        .diamond_open => "◇",
    }, .edge);
}

fn drawEdgeLabel(canvas: *Canvas, label: []const u8, y: usize, x: usize) void {
    if (y >= canvas.height or x >= canvas.width) return;
    canvas_mod.drawText(canvas, label_text.fit(label, @min(label_text.wrap_width, canvas.width - x)), x, y, .edge_label);
}

/// Sequence layout keeps participant centers fixed and advances only the row:
///
///       actor A        actor B
///          │── label ────▶│
///          │              │
///          │◀── reply ────│
pub fn render_sequence(alloc: Allocator, sequence: *const Sequence, max_width: usize, styles: Styles) MermaidError!?[]u8 {
    const count = sequence.labels.items.len;
    if (count == 0) return null;
    const widths = try alloc.alloc(usize, count);
    defer alloc.free(widths);
    const centers = try alloc.alloc(usize, count);
    defer alloc.free(centers);
    for (sequence.labels.items, 0..) |label, index| widths[index] = @min(label_text.wrap_width, display_width.visibleWidth(label)) + 4;
    centers[0] = widths[0] / 2;
    var index: usize = 1;
    while (index < count) : (index += 1) {
        centers[index] = centers[index - 1] + @max(@as(usize, 8), widths[index - 1] / 2 + widths[index] / 2 + 2);
    }
    var canvas_width = centers[count - 1] + (widths[count - 1] + 1) / 2 + 1;
    var rows: usize = 4;
    for (sequence.items.items) |item| {
        rows += switch (item) {
            .message => |message| if (message.from == message.to) 4 else if (message.label != null) 3 else 2,
            .note => 4,
            .divider => 2,
        };
    }
    const bottom_y = rows;
    const canvas_height = bottom_y + 3;
    for (sequence.items.items) |item| switch (item) {
        .message => |message| if (message.from == message.to) {
            const label_width = if (message.label) |label| display_width.visibleWidth(label) else 0;
            canvas_width = @max(canvas_width, centers[message.from] + 6 + label_width);
        },
        .note => |note| {
            const note_width = @min(label_text.wrap_width, display_width.visibleWidth(note.label)) + 4;
            canvas_width = @max(canvas_width, (centers[note.left] + centers[note.right]) / 2 + note_width / 2 + 1);
        },
        .divider => |label| canvas_width = @max(canvas_width, @min(label_text.wrap_width, display_width.visibleWidth(label)) + 4),
    };
    if (canvas_width > max_width or canvas_width > canvas_mod.max_cells / canvas_height) return null;
    var canvas = try Canvas.init(alloc, canvas_width, canvas_height);
    defer canvas.deinit();

    for (sequence.labels.items, 0..) |label, participant| {
        const actor_x = centers[participant] - widths[participant] / 2;
        drawSingleLineBox(&canvas, label, actor_x, 0, widths[participant]);
        drawSingleLineBox(&canvas, label, actor_x, bottom_y, widths[participant]);
        canvas.vertical(centers[participant], 2, bottom_y);
    }

    var y: usize = 4;
    for (sequence.items.items) |item| switch (item) {
        .message => |message| {
            const from_x = centers[message.from];
            const to_x = centers[message.to];
            if (from_x == to_x) {
                canvas.set(from_x + 1, y, if (message.dashed) "╌" else "─", .edge);
                canvas.set(from_x + 2, y, if (message.dashed) "╌" else "─", .edge);
                canvas.set(from_x + 3, y, "╮", .edge);
                canvas.set(from_x + 3, y + 1, "│", .edge);
                canvas.set(from_x + 3, y + 2, "╯", .edge);
                canvas.set(from_x + 2, y + 2, if (message.dashed) "╌" else "─", .edge);
                canvas.set(from_x + 1, y + 2, if (message.cross) "×" else "◄", .edge);
                if (message.label) |label| canvas_mod.drawText(&canvas, label_text.fit(label, label_text.wrap_width), from_x + 5, y + 1, .text);
                y += 4;
            } else {
                const low = @min(from_x, to_x);
                const high = @max(from_x, to_x);
                const arrow_y = y + if (message.label != null) @as(usize, 1) else 0;
                var x = low + 1;
                while (x < high) : (x += 1) canvas.set(x, arrow_y, if (message.dashed) "╌" else "─", .edge);
                const rightward = to_x > from_x;
                canvas.set(if (rightward) to_x - 1 else to_x + 1, arrow_y, if (message.cross) "×" else if (rightward) "▶" else "◄", .edge);
                if (message.label) |label| {
                    const fitted = label_text.fit(label, high - low -| 2);
                    canvas_mod.drawText(&canvas, fitted, low + 1 + (high - low -| 2 -| display_width.visibleWidth(fitted)) / 2, y, .text);
                }
                y += if (message.label != null) 3 else 2;
            }
        },
        .note => |note| {
            const note_width = @min(label_text.wrap_width, display_width.visibleWidth(note.label)) + 4;
            const center = (centers[note.left] + centers[note.right]) / 2;
            drawSingleLineBox(&canvas, note.label, center -| note_width / 2, y, note_width);
            y += 4;
        },
        .divider => |label| {
            var x: usize = 0;
            while (x < canvas.width) : (x += 1) canvas.set(x, y, "─", .edge);
            const fitted = label_text.fit(label, canvas.width -| 4);
            canvas_mod.drawText(&canvas, fitted, 2, y, .edge_label);
            y += 2;
        },
    };
    return try canvas.toOwnedBytes(styles);
}

fn drawSingleLineBox(canvas: *Canvas, label: []const u8, x: usize, y: usize, width: usize) void {
    if (width < 4 or x + width > canvas.width or y + 2 >= canvas.height) return;
    const right = x + width - 1;
    canvas.set(x, y, "┌", .border);
    canvas.set(right, y, "┐", .border);
    canvas.set(x, y + 1, "│", .border);
    canvas.set(right, y + 1, "│", .border);
    canvas.set(x, y + 2, "└", .border);
    canvas.set(right, y + 2, "┘", .border);
    var col = x + 1;
    while (col < right) : (col += 1) {
        canvas.set(col, y, "─", .border);
        canvas.set(col, y + 2, "─", .border);
    }
    var row = y;
    while (row <= y + 2) : (row += 1) {
        col = x;
        while (col <= right) : (col += 1) {
            canvas.markOccupied(col, row);
        }
    }
    const fitted = label_text.fit(label, width - 4);
    const label_width = display_width.visibleWidth(fitted);
    canvas_mod.drawText(canvas, fitted, x + 2 + (width - 4 -| label_width) / 2, y + 1, .text);
}

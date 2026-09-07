//! Parsers for the Mermaid subsets supported by the terminal renderer.
//!
//! Each syntax parser produces the same owned intermediate model:
//!
//!     flowchart ─┐
//!     state ─────┤
//!     class ─────┼──> model.Graph
//!     ER ────────┘
//!     sequence ─────> model.Sequence

const std = @import("std");
const model = @import("model.zig");
const label_text = @import("label.zig");

const Allocator = std.mem.Allocator;
const MermaidError = model.MermaidError;
const Direction = model.Direction;
const Shape = model.Shape;
const Head = model.Head;
const LineKind = model.LineKind;
const Graph = model.Graph;
const Edge = model.Edge;
const Sequence = model.Sequence;

const max_statements = 1024;
const Statements = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Statements, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item);
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

fn splitStatements(alloc: Allocator, source: []const u8) MermaidError!Statements {
    var result: Statements = .{};
    errdefer result.deinit(alloc);
    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        var start: usize = 0;
        var index: usize = 0;
        var quoted = false;
        while (index < raw_line.len) : (index += 1) {
            const byte = raw_line[index];
            if (byte == '"') quoted = !quoted;
            if (!quoted and byte == '%' and index + 1 < raw_line.len and raw_line[index + 1] == '%') {
                try appendStatement(alloc, &result, raw_line[start..index]);
                start = raw_line.len;
                break;
            }
            if (!quoted and byte == ';') {
                try appendStatement(alloc, &result, raw_line[start..index]);
                start = index + 1;
            }
        }
        if (start < raw_line.len) try appendStatement(alloc, &result, raw_line[start..]);
    }
    return result;
}

fn appendStatement(alloc: Allocator, result: *Statements, raw: []const u8) MermaidError!void {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return;
    if (result.items.items.len >= max_statements) return error.TooComplex;
    const owned = try alloc.dupe(u8, value);
    errdefer alloc.free(owned);
    try result.items.append(alloc, owned);
}

// Flowchart syntax.
pub fn parse_flowchart(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;

    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    graph.direction = directionFromHeader(statements.items.items[0]);

    for (statements.items.items[1..]) |statement| {
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "subgraph") or eqlIgnoreCase(first, "end") or
            eqlIgnoreCase(first, "classDef") or eqlIgnoreCase(first, "class") or
            eqlIgnoreCase(first, "style") or eqlIgnoreCase(first, "linkStyle") or
            eqlIgnoreCase(first, "click"))
        {
            continue;
        }
        if (eqlIgnoreCase(first, "direction")) {
            graph.direction = directionFromHeader(statement);
            continue;
        }
        try parseFlowStatement(&graph, statement);
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

const ParsedNode = struct { index: usize, end: usize };

fn parseFlowStatement(graph: *Graph, statement: []const u8) MermaidError!void {
    var cursor: usize = 0;
    var previous = (try parseFlowNode(graph, statement, cursor)) orelse return;
    cursor = previous.end;
    while (cursor < statement.len) {
        const link = parseFlowLink(statement, cursor) orelse break;
        const next = (try parseFlowNode(graph, statement, link.end)) orelse break;
        const owned_label = if (link.label) |label| try label_text.clean(graph.alloc, label) else null;
        errdefer if (owned_label) |label| graph.alloc.free(label);
        try graph.addEdge(.{
            .from = if (link.reverse) next.index else previous.index,
            .to = if (link.reverse) previous.index else next.index,
            .label = owned_label,
            .head_to = if (link.reverse) link.head_from else link.head_to,
            .head_from = if (link.reverse) link.head_to else link.head_from,
            .line = link.line,
        });
        previous = next;
        cursor = next.end;
    }
}

fn parseFlowNode(graph: *Graph, statement: []const u8, raw_start: usize) MermaidError!?ParsedNode {
    var index = skipSpace(statement, raw_start);
    const id_start = index;
    while (index < statement.len and isIdByte(statement[index])) : (index += 1) {}
    if (index == id_start) return null;
    const id = statement[id_start..index];
    var shape: Shape = .rect;
    var label: ?[]const u8 = null;

    if (index < statement.len) {
        const open = statement[index];
        const parsed = switch (open) {
            '[' => parseDelimitedLabel(statement, index, '[', ']', .rect),
            '(' => parseDelimitedLabel(statement, index, '(', ')', .round),
            '{' => parseDelimitedLabel(statement, index, '{', '}', .diamond),
            '>' => parseDelimitedLabel(statement, index, '>', ']', .rect),
            else => null,
        };
        if (parsed) |value| {
            shape = value.shape;
            label = value.label;
            index = value.end;
        }
    }
    return .{ .index = try graph.addNode(id, label, shape), .end = index };
}

const DelimitedLabel = struct { label: []const u8, shape: Shape, end: usize };

fn parseDelimitedLabel(
    source: []const u8,
    start: usize,
    open: u8,
    close: u8,
    shape: Shape,
) ?DelimitedLabel {
    var content_start = start + 1;
    var first_closer = close;
    var second_closer: ?u8 = null;
    if (content_start < source.len and source[content_start] == open) {
        content_start += 1;
        second_closer = close;
    } else if (open == '[' and content_start < source.len and source[content_start] == '(') {
        content_start += 1;
        first_closer = ')';
        second_closer = ']';
    } else if (open == '(' and content_start < source.len and source[content_start] == '[') {
        content_start += 1;
        first_closer = ']';
        second_closer = ')';
    }
    var quoted = false;
    var index = content_start;
    while (index < source.len) : (index += 1) {
        if (source[index] == '"') quoted = !quoted;
        if (quoted or source[index] != first_closer) continue;
        if (second_closer) |second| {
            if (index + 1 >= source.len or source[index + 1] != second) continue;
        }
        return .{
            .label = source[content_start..index],
            .shape = shape,
            .end = index + 1 + @intFromBool(second_closer != null),
        };
    }
    return null;
}

const ParsedLink = struct {
    end: usize,
    label: ?[]const u8,
    head_to: Head,
    head_from: Head,
    line: LineKind,
    reverse: bool,
};

fn parseFlowLink(source: []const u8, raw_start: usize) ?ParsedLink {
    var index = skipSpace(source, raw_start);
    var head_from: Head = .none;
    if (index + 1 < source.len and (source[index] == 'o' or source[index] == 'x') and
        isLinkByte(source[index + 1]))
    {
        head_from = if (source[index] == 'o') .circle else .cross;
        index += 1;
    }
    const op_start = index;
    while (index < source.len and isLinkByte(source[index])) : (index += 1) {}
    if (index == op_start) return null;
    const first_op = source[op_start..index];
    var line = lineKind(first_op);
    var head_to: Head = if (std.mem.findScalar(u8, first_op, '>') != null) .arrow else .none;
    if (head_from == .none and std.mem.startsWith(u8, first_op, "<")) head_from = .arrow;
    const reverse = head_from == .arrow and head_to == .none;
    if (head_to == .none and index < source.len and (source[index] == 'o' or source[index] == 'x')) {
        head_to = if (source[index] == 'o') .circle else .cross;
        index += 1;
    }

    if (index < source.len and source[index] == '|') {
        const label_start = index + 1;
        const label_end = std.mem.findScalarPos(u8, source, label_start, '|') orelse return null;
        return .{
            .end = label_end + 1,
            .label = source[label_start..label_end],
            .head_to = head_to,
            .head_from = head_from,
            .line = line,
            .reverse = reverse,
        };
    }

    if (head_to == .none) {
        const text_start = skipSpace(source, index);
        var op2_start = text_start;
        while (op2_start < source.len and !isLinkByte(source[op2_start])) : (op2_start += 1) {}
        if (op2_start > text_start and op2_start < source.len) {
            var op2_end = op2_start;
            while (op2_end < source.len and isLinkByte(source[op2_end])) : (op2_end += 1) {}
            const second_op = source[op2_start..op2_end];
            if (std.mem.findScalar(u8, second_op, '>') != null) head_to = .arrow;
            if (line == .solid) line = lineKind(second_op);
            return .{
                .end = op2_end,
                .label = std.mem.trim(u8, source[text_start..op2_start], " \t"),
                .head_to = head_to,
                .head_from = head_from,
                .line = line,
                .reverse = reverse,
            };
        }
    }

    return .{
        .end = index,
        .label = null,
        .head_to = head_to,
        .head_from = head_from,
        .line = line,
        .reverse = reverse,
    };
}

// State diagram syntax.
pub fn parse_state(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    var marker_id: usize = 0;
    var in_note = false;

    for (statements.items.items[1..]) |statement| {
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "direction")) {
            graph.direction = directionFromHeader(statement);
            continue;
        }
        if (eqlIgnoreCase(first, "note")) {
            in_note = true;
            continue;
        }
        if (in_note) {
            if (eqlIgnoreCase(first, "end") or eqlIgnoreCase(first, "end note")) in_note = false;
            continue;
        }
        if (eqlIgnoreCase(first, "state")) {
            try parseStateDeclaration(&graph, statement);
            continue;
        }
        if (eqlIgnoreCase(first, "end") or std.mem.eql(u8, statement, "}")) continue;
        if (std.mem.find(u8, statement, "-->") != null or std.mem.find(u8, statement, "--->") != null) {
            try parseStateTransition(&graph, statement, &marker_id);
            continue;
        }
        if (std.mem.findScalar(u8, statement, ':')) |colon| {
            const id = std.mem.trim(u8, statement[0..colon], " \t");
            const label = std.mem.trim(u8, statement[colon + 1 ..], " \t");
            if (id.len > 0 and label.len > 0) _ = try graph.setLabel(id, label, null);
        }
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

fn parseStateDeclaration(graph: *Graph, statement: []const u8) MermaidError!void {
    var rest = std.mem.trim(u8, statement["state".len..], " \t");
    if (rest.len == 0) return;
    if (rest[0] == '"') {
        const close = std.mem.findScalarPos(u8, rest, 1, '"') orelse return;
        const label = rest[1..close];
        const suffix = std.mem.trim(u8, rest[close + 1 ..], " \t");
        if (!startsWithIgnoreCase(suffix, "as ")) return;
        const id = firstWord(std.mem.trim(u8, suffix[3..], " \t"));
        if (id.len > 0) _ = try graph.setLabel(id, label, .round);
        return;
    }
    if (std.mem.find(u8, rest, "<<choice>>")) |choice| {
        rest = std.mem.trim(u8, rest[0..choice], " \t");
        if (rest.len > 0) _ = try graph.addNode(firstWord(rest), null, .diamond);
        return;
    }
    const id = firstWord(rest);
    if (id.len > 0) _ = try graph.addNode(id, null, .round);
}

fn parseStateTransition(graph: *Graph, statement: []const u8, marker_id: *usize) MermaidError!void {
    const arrow = std.mem.find(u8, statement, "-->") orelse std.mem.find(u8, statement, "--->") orelse return;
    var arrow_end = arrow;
    while (arrow_end < statement.len and (statement[arrow_end] == '-' or statement[arrow_end] == '>')) : (arrow_end += 1) {}
    const left_raw = std.mem.trim(u8, statement[0..arrow], " \t");
    var right_raw = std.mem.trim(u8, statement[arrow_end..], " \t");
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, right_raw, ':')) |colon| {
        label = std.mem.trim(u8, right_raw[colon + 1 ..], " \t");
        right_raw = std.mem.trim(u8, right_raw[0..colon], " \t");
    }
    const from = try stateEndpoint(graph, left_raw, true, marker_id);
    const to = try stateEndpoint(graph, right_raw, false, marker_id);
    const owned_label = if (label) |value| try label_text.clean(graph.alloc, value) else null;
    errdefer if (owned_label) |value| graph.alloc.free(value);
    try graph.addEdge(.{ .from = from, .to = to, .label = owned_label });
}

fn stateEndpoint(graph: *Graph, raw: []const u8, source: bool, marker_id: *usize) MermaidError!usize {
    if (std.mem.eql(u8, raw, "[*]")) {
        const id = try std.fmt.allocPrint(graph.alloc, "__mermaid_{s}_{d}", .{ if (source) "start" else "end", marker_id.* });
        defer graph.alloc.free(id);
        marker_id.* += 1;
        return graph.addNode(id, if (source) "●" else "◉", if (source) .start else .finish);
    }
    return graph.addNode(firstWord(raw), null, .round);
}

// Class diagram syntax.
pub fn parse_class(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    var active: ?usize = null;

    for (statements.items.items[1..]) |statement| {
        if (active) |node_index| {
            if (std.mem.eql(u8, statement, "}")) {
                active = null;
            } else {
                try graph.addMember(node_index, statement);
            }
            continue;
        }
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "direction")) {
            graph.direction = directionFromHeader(statement);
            continue;
        }
        if (eqlIgnoreCase(first, "class")) {
            try parseClassDeclaration(&graph, statement, &active);
            continue;
        }
        if (std.mem.startsWith(u8, statement, "<<")) {
            const close = std.mem.find(u8, statement, ">>") orelse continue;
            const annotation = statement[2..close];
            const id = firstWord(std.mem.trim(u8, statement[close + 2 ..], " \t"));
            if (id.len > 0) {
                const node = try graph.addNode(id, null, .rect);
                const text = try std.fmt.allocPrint(graph.alloc, "«{s}»", .{annotation});
                defer graph.alloc.free(text);
                try graph.addMember(node, text);
            }
            continue;
        }
        if (findClassOperator(statement)) |relation| {
            try parseClassRelation(&graph, statement, relation);
            continue;
        }
        if (std.mem.findScalar(u8, statement, ':')) |colon| {
            const id = std.mem.trim(u8, statement[0..colon], " \t");
            const member = statement[colon + 1 ..];
            if (id.len > 0) try graph.addMember(try graph.addNode(id, null, .rect), member);
        }
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

fn parseClassDeclaration(graph: *Graph, statement: []const u8, active: *?usize) MermaidError!void {
    var rest = std.mem.trim(u8, statement["class".len..], " \t");
    const brace = std.mem.findScalar(u8, rest, '{');
    const decl = if (brace) |at| std.mem.trim(u8, rest[0..at], " \t") else rest;
    if (decl.len == 0) return;
    var id = firstWord(decl);
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, decl, '[')) |open| {
        if (std.mem.findScalarPos(u8, decl, open + 1, ']')) |close| {
            id = std.mem.trim(u8, decl[0..open], " \t");
            label = decl[open + 1 .. close];
        }
    }
    const node = try graph.addNode(id, label, .rect);
    if (brace) |at| {
        rest = std.mem.trim(u8, rest[at + 1 ..], " \t");
        if (std.mem.findScalar(u8, rest, '}')) |close| {
            const inner = std.mem.trim(u8, rest[0..close], " \t");
            if (inner.len > 0) try graph.addMember(node, inner);
        } else {
            active.* = node;
        }
    }
}

const Relation = struct { at: usize, op: []const u8 };

fn findClassOperator(statement: []const u8) ?Relation {
    const operators = [_][]const u8{ "<|..", "..|>", "<|--", "--|>", "*--", "--*", "o--", "--o", "..>", "<..", "-->", "<--", "--" };
    var best: ?Relation = null;
    for (operators) |op| {
        if (std.mem.find(u8, statement, op)) |at| {
            if (best == null or at < best.?.at or (at == best.?.at and op.len > best.?.op.len)) {
                best = .{ .at = at, .op = op };
            }
        }
    }
    return best;
}

fn parseClassRelation(graph: *Graph, statement: []const u8, relation: Relation) MermaidError!void {
    const left_part = std.mem.trim(u8, statement[0..relation.at], " \t");
    var right_part = std.mem.trim(u8, statement[relation.at + relation.op.len ..], " \t");
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, right_part, ':')) |colon| {
        label = std.mem.trim(u8, right_part[colon + 1 ..], " \t");
        right_part = std.mem.trim(u8, right_part[0..colon], " \t");
    }
    const left_id = lastIdentifier(left_part);
    const right_id = firstIdentifier(right_part);
    if (left_id.len == 0 or right_id.len == 0) return;
    const from = try graph.addNode(left_id, null, .rect);
    const to = try graph.addNode(right_id, null, .rect);
    var edge = Edge{
        .from = from,
        .to = to,
        .label = if (label) |value| try label_text.clean(graph.alloc, value) else null,
        .line = if (std.mem.findScalar(u8, relation.op, '.') != null) .dotted else .solid,
        .head_to = .none,
    };
    errdefer edge.deinit(graph.alloc);
    if (std.mem.startsWith(u8, relation.op, "<|")) edge.head_from = .triangle;
    if (std.mem.endsWith(u8, relation.op, "|>")) edge.head_to = .triangle;
    if (std.mem.startsWith(u8, relation.op, "*")) edge.head_from = .diamond_fill;
    if (std.mem.endsWith(u8, relation.op, "*")) edge.head_to = .diamond_fill;
    if (std.mem.startsWith(u8, relation.op, "o")) edge.head_from = .diamond_open;
    if (std.mem.endsWith(u8, relation.op, "o")) edge.head_to = .diamond_open;
    if (std.mem.endsWith(u8, relation.op, ">") and edge.head_to == .none) edge.head_to = .arrow;
    if (std.mem.startsWith(u8, relation.op, "<") and edge.head_from == .none) edge.head_from = .arrow;
    try graph.addEdge(edge);
}

// Entity relationship diagram syntax.
pub fn parse_er(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    var active: ?usize = null;

    for (statements.items.items[1..]) |statement| {
        if (active) |node_index| {
            if (std.mem.eql(u8, statement, "}")) {
                active = null;
            } else {
                try graph.addMember(node_index, erAttribute(statement));
            }
            continue;
        }
        if (parseErRelationParts(statement)) |parts| {
            const from = try graph.addNode(parts.left, null, .rect);
            const to = try graph.addNode(parts.right, null, .rect);
            const relation_label = try erRelationLabel(graph.alloc, parts.left_card, parts.label, parts.right_card);
            errdefer if (relation_label) |value| graph.alloc.free(value);
            try graph.addEdge(.{
                .from = from,
                .to = to,
                .label = relation_label,
                .head_to = .none,
                .line = if (std.mem.find(u8, parts.operator, "..") != null) .dotted else .solid,
            });
            continue;
        }
        if (std.mem.findScalar(u8, statement, '{')) |brace| {
            const decl = std.mem.trim(u8, statement[0..brace], " \t");
            const id = firstIdentifier(decl);
            if (id.len > 0) {
                const node = try graph.addNode(id, erAlias(decl), .rect);
                const rest = std.mem.trim(u8, statement[brace + 1 ..], " \t");
                if (std.mem.findScalar(u8, rest, '}')) |close| {
                    const inner = std.mem.trim(u8, rest[0..close], " \t");
                    if (inner.len > 0) try graph.addMember(node, erAttribute(inner));
                } else {
                    active = node;
                }
            }
            continue;
        }
        const id = firstIdentifier(statement);
        if (id.len > 0) _ = try graph.addNode(id, erAlias(statement), .rect);
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

const ErParts = struct {
    left: []const u8,
    left_card: []const u8,
    operator: []const u8,
    right_card: []const u8,
    right: []const u8,
    label: ?[]const u8,
};

fn parseErRelationParts(statement: []const u8) ?ErParts {
    var words = std.mem.tokenizeAny(u8, statement, " \t");
    const left = words.next() orelse return null;
    const op = words.next() orelse return null;
    const right = words.next() orelse return null;
    const split = splitErOperator(op) orelse return null;
    const colon = std.mem.findScalar(u8, statement, ':');
    const label = if (colon) |at| std.mem.trim(u8, statement[at + 1 ..], " \t") else null;
    return .{
        .left = left,
        .left_card = split.left,
        .operator = op,
        .right_card = split.right,
        .right = std.mem.trimEnd(u8, right, ":"),
        .label = label,
    };
}

const ErOperator = struct { left: []const u8, right: []const u8 };

fn splitErOperator(op: []const u8) ?ErOperator {
    const middle = std.mem.find(u8, op, "--") orelse std.mem.find(u8, op, "..") orelse return null;
    if (middle == 0 or middle + 2 >= op.len) return null;
    for (op[0..middle]) |byte| if (!isErCardinalityByte(byte)) return null;
    for (op[middle + 2 ..]) |byte| if (!isErCardinalityByte(byte)) return null;
    return .{ .left = op[0..middle], .right = op[middle + 2 ..] };
}

fn isErCardinalityByte(byte: u8) bool {
    return byte == '|' or byte == 'o' or byte == '{' or byte == '}';
}

fn erRelationLabel(
    alloc: Allocator,
    left: []const u8,
    label: ?[]const u8,
    right: []const u8,
) Allocator.Error!?[]u8 {
    const left_text = erCardinality(left);
    const right_text = erCardinality(right);
    const middle = if (label) |value| try label_text.clean(alloc, value) else null;
    defer if (middle) |value| alloc.free(value);
    const middle_text = middle orelse "";
    if (left_text.len == 0 and middle_text.len == 0 and right_text.len == 0) return null;
    const rendered = if (middle_text.len == 0)
        try std.fmt.allocPrint(alloc, "{s} ↔ {s}", .{ left_text, right_text })
    else
        try std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ left_text, middle_text, right_text });
    return rendered;
}

fn erCardinality(token: []const u8) []const u8 {
    if (std.mem.eql(u8, token, "||")) return "1";
    if (std.mem.eql(u8, token, "o|") or std.mem.eql(u8, token, "|o")) return "0..1";
    if (std.mem.eql(u8, token, "|{") or std.mem.eql(u8, token, "}|")) return "1..*";
    if (std.mem.eql(u8, token, "o{") or std.mem.eql(u8, token, "}o")) return "0..*";
    return token;
}

fn erAlias(statement: []const u8) ?[]const u8 {
    const first_quote = std.mem.findScalar(u8, statement, '"') orelse return null;
    const second_quote = std.mem.findScalarPos(u8, statement, first_quote + 1, '"') orelse return null;
    return statement[first_quote + 1 .. second_quote];
}

fn erAttribute(statement: []const u8) []const u8 {
    return std.mem.trim(u8, statement, " \t");
}

// Sequence diagram syntax.
pub fn parse_sequence(alloc: Allocator, source: []const u8) MermaidError!?Sequence {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var sequence = Sequence.init(alloc);
    errdefer sequence.deinit();
    var autonumber = false;
    var message_number: usize = 0;
    var blocks: std.ArrayList(bool) = .empty;
    defer blocks.deinit(alloc);

    for (statements.items.items[1..]) |statement| {
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "participant") or eqlIgnoreCase(first, "actor")) {
            const rest = std.mem.trim(u8, statement[first.len..], " \t");
            if (findAsciiIgnoreCase(rest, " as ")) |as_pos| {
                _ = try sequence.participant(
                    std.mem.trim(u8, rest[0..as_pos], " \t"),
                    std.mem.trim(u8, rest[as_pos + 4 ..], " \t"),
                );
            } else if (rest.len > 0) {
                _ = try sequence.participant(firstWord(rest), null);
            }
            continue;
        }
        if (eqlIgnoreCase(first, "autonumber")) {
            autonumber = true;
            continue;
        }
        if (eqlIgnoreCase(first, "note")) {
            try parseSequenceNote(&sequence, statement[first.len..]);
            continue;
        }
        if (isSequenceDivider(first)) {
            const continuation = isSequenceDividerContinuation(first);
            if (continuation) {
                if (blocks.items.len == 0 or !blocks.items[blocks.items.len - 1]) continue;
            } else {
                try blocks.append(alloc, true);
            }
            if (sequence.items.items.len >= model.max_edges) return error.TooComplex;
            const label = try label_text.clean(alloc, statement);
            errdefer alloc.free(label);
            try sequence.items.append(alloc, .{ .divider = label });
            continue;
        }
        if (eqlIgnoreCase(first, "end")) {
            const visible = blocks.pop() orelse false;
            if (!visible) continue;
            if (sequence.items.items.len >= model.max_edges) return error.TooComplex;
            const label = try alloc.dupe(u8, "end");
            errdefer alloc.free(label);
            try sequence.items.append(alloc, .{ .divider = label });
            continue;
        }
        if (eqlIgnoreCase(first, "activate") or eqlIgnoreCase(first, "deactivate") or
            eqlIgnoreCase(first, "create") or eqlIgnoreCase(first, "destroy") or
            eqlIgnoreCase(first, "title"))
        {
            continue;
        }
        if (eqlIgnoreCase(first, "rect") or eqlIgnoreCase(first, "box")) {
            try blocks.append(alloc, false);
            continue;
        }
        try parseSequenceMessage(&sequence, statement, autonumber, &message_number);
    }
    if (sequence.labels.items.len == 0) {
        sequence.deinit();
        return null;
    }
    return sequence;
}

const SequenceOperator = struct { at: usize, text: []const u8, dashed: bool, cross: bool };

fn findSequenceOperator(statement: []const u8) ?SequenceOperator {
    const operators = [_]struct { text: []const u8, dashed: bool, cross: bool }{
        .{ .text = "-->>", .dashed = true, .cross = false },
        .{ .text = "->>", .dashed = false, .cross = false },
        .{ .text = "--x", .dashed = true, .cross = true },
        .{ .text = "-x", .dashed = false, .cross = true },
        .{ .text = "--)", .dashed = true, .cross = false },
        .{ .text = "-)", .dashed = false, .cross = false },
        .{ .text = "-->", .dashed = true, .cross = false },
        .{ .text = "->", .dashed = false, .cross = false },
    };
    var best: ?SequenceOperator = null;
    for (operators) |operator| {
        if (std.mem.find(u8, statement, operator.text)) |at| {
            if (best == null or at < best.?.at or
                (at == best.?.at and operator.text.len > best.?.text.len))
            {
                best = .{ .at = at, .text = operator.text, .dashed = operator.dashed, .cross = operator.cross };
            }
        }
    }
    return best;
}

fn parseSequenceMessage(
    sequence: *Sequence,
    statement: []const u8,
    autonumber: bool,
    message_number: *usize,
) MermaidError!void {
    const operator = findSequenceOperator(statement) orelse return;
    const from_id = std.mem.trim(u8, statement[0..operator.at], " \t");
    var right = std.mem.trim(u8, statement[operator.at + operator.text.len ..], " \t+-");
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, right, ':')) |colon| {
        label = std.mem.trim(u8, right[colon + 1 ..], " \t");
        right = std.mem.trim(u8, right[0..colon], " \t");
    }
    if (from_id.len == 0 or right.len == 0) return;
    const from = try sequence.participant(from_id, null);
    const to = try sequence.participant(right, null);
    var owned_label: ?[]u8 = null;
    if (autonumber) {
        message_number.* += 1;
        owned_label = if (label) |value| blk: {
            const clean = try label_text.clean(sequence.alloc, value);
            defer sequence.alloc.free(clean);
            break :blk try std.fmt.allocPrint(sequence.alloc, "{d}. {s}", .{ message_number.*, clean });
        } else try std.fmt.allocPrint(sequence.alloc, "{d}.", .{message_number.*});
    } else if (label) |value| {
        owned_label = try label_text.clean(sequence.alloc, value);
    }
    errdefer if (owned_label) |value| sequence.alloc.free(value);
    if (sequence.items.items.len >= model.max_edges) return error.TooComplex;
    try sequence.items.append(sequence.alloc, .{ .message = .{
        .from = from,
        .to = to,
        .label = owned_label,
        .dashed = operator.dashed,
        .cross = operator.cross,
    } });
}

fn parseSequenceNote(sequence: *Sequence, raw: []const u8) MermaidError!void {
    const rest = std.mem.trim(u8, raw, " \t");
    const colon = std.mem.findScalar(u8, rest, ':') orelse return;
    const anchor = std.mem.trim(u8, rest[0..colon], " \t");
    const label = std.mem.trim(u8, rest[colon + 1 ..], " \t");
    var ids: []const u8 = undefined;
    if (startsWithIgnoreCase(anchor, "over ")) {
        ids = std.mem.trim(u8, anchor[5..], " \t");
    } else if (startsWithIgnoreCase(anchor, "left of ")) {
        ids = std.mem.trim(u8, anchor[8..], " \t");
    } else if (startsWithIgnoreCase(anchor, "right of ")) {
        ids = std.mem.trim(u8, anchor[9..], " \t");
    } else return;
    const comma = std.mem.findScalar(u8, ids, ',');
    const first_id = std.mem.trim(u8, if (comma) |at| ids[0..at] else ids, " \t");
    const second_id = std.mem.trim(u8, if (comma) |at| ids[at + 1 ..] else first_id, " \t");
    const first = try sequence.participant(first_id, null);
    const second = try sequence.participant(second_id, null);
    if (sequence.items.items.len >= model.max_edges) return error.TooComplex;
    const owned_label = try label_text.clean(sequence.alloc, label);
    errdefer sequence.alloc.free(owned_label);
    try sequence.items.append(sequence.alloc, .{ .note = .{
        .left = @min(first, second),
        .right = @max(first, second),
        .label = owned_label,
    } });
}

fn isSequenceDivider(first: []const u8) bool {
    return eqlIgnoreCase(first, "loop") or eqlIgnoreCase(first, "alt") or
        eqlIgnoreCase(first, "opt") or eqlIgnoreCase(first, "par") or
        eqlIgnoreCase(first, "critical") or eqlIgnoreCase(first, "break") or
        eqlIgnoreCase(first, "else") or eqlIgnoreCase(first, "and") or
        eqlIgnoreCase(first, "option");
}

fn isSequenceDividerContinuation(first: []const u8) bool {
    return eqlIgnoreCase(first, "else") or eqlIgnoreCase(first, "and") or
        eqlIgnoreCase(first, "option");
}
// Shared lexical helpers.
fn firstWord(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != '\r' and trimmed[end] != '\n') : (end += 1) {}
    return trimmed[0..end];
}

fn directionFromHeader(header: []const u8) Direction {
    var words = std.mem.tokenizeAny(u8, header, " \t");
    _ = words.next();
    const direction = words.next() orelse return .down;
    if (eqlIgnoreCase(direction, "LR")) return .right;
    if (eqlIgnoreCase(direction, "RL")) return .left;
    if (eqlIgnoreCase(direction, "BT")) return .up;
    return .down;
}

fn skipSpace(source: []const u8, raw_index: usize) usize {
    var index = raw_index;
    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) : (index += 1) {}
    return index;
}

fn isIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isLinkByte(byte: u8) bool {
    return byte == '-' or byte == '.' or byte == '=' or byte == '<' or byte == '>';
}

fn lineKind(operator: []const u8) LineKind {
    if (std.mem.findScalar(u8, operator, '=') != null) return .thick;
    if (std.mem.findScalar(u8, operator, '.') != null) return .dotted;
    return .solid;
}

fn firstIdentifier(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\"");
    var end: usize = 0;
    while (end < trimmed.len and isIdByte(trimmed[end])) : (end += 1) {}
    return trimmed[0..end];
}

fn lastIdentifier(source: []const u8) []const u8 {
    var trimmed = std.mem.trimEnd(u8, source, " \t\"");
    var start = trimmed.len;
    while (start > 0 and isIdByte(trimmed[start - 1])) : (start -= 1) {}
    trimmed = trimmed[start..];
    return trimmed;
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn startsWithIgnoreCase(source: []const u8, prefix: []const u8) bool {
    return source.len >= prefix.len and std.ascii.eqlIgnoreCase(source[0..prefix.len], prefix);
}

fn findAsciiIgnoreCase(source: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var index: usize = 0;
    while (index + needle.len <= source.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(source[index .. index + needle.len], needle)) return index;
    }
    return null;
}

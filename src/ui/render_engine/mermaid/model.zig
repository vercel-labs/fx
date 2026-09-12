//! Owned intermediate representation shared by Mermaid parsers and layouts.
//!
//!     parser borrows source slices
//!              │
//!              ▼
//!     Graph / Sequence duplicate and own strings
//!              │
//!              ├── layout borrows the model
//!              └── deinit releases the complete model

const std = @import("std");
const label_text = @import("label.zig");

const Allocator = std.mem.Allocator;

pub const max_nodes = 128;
pub const max_edges = 512;
const max_members = 8;

pub const MermaidError = Allocator.Error || error{TooComplex};

pub const Direction = enum {
    down,
    up,
    right,
    left,
};

pub const Shape = enum {
    rect,
    round,
    diamond,
    start,
    finish,
};

pub const Head = enum {
    none,
    arrow,
    circle,
    cross,
    triangle,
    diamond_fill,
    diamond_open,
};

pub const LineKind = enum {
    solid,
    dotted,
    thick,
};

pub const Node = struct {
    id: []u8,
    label: []u8,
    shape: Shape,
    members: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Node, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.label);
        for (self.members.items) |member| alloc.free(member);
        self.members.deinit(alloc);
        self.* = undefined;
    }
};

pub const Edge = struct {
    from: usize,
    to: usize,
    label: ?[]u8 = null,
    head_to: Head = .arrow,
    head_from: Head = .none,
    line: LineKind = .solid,

    pub fn deinit(self: *Edge, alloc: Allocator) void {
        if (self.label) |label| alloc.free(label);
        self.* = undefined;
    }
};

pub const Graph = struct {
    alloc: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    index: std.StringHashMap(usize),
    direction: Direction = .down,

    pub fn init(alloc: Allocator) Graph {
        return .{ .alloc = alloc, .index = std.StringHashMap(usize).init(alloc) };
    }

    pub fn deinit(self: *Graph) void {
        self.index.deinit();
        for (self.nodes.items) |*node| node.deinit(self.alloc);
        for (self.edges.items) |*edge| edge.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
        self.edges.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn addNode(self: *Graph, id: []const u8, label: ?[]const u8, shape: Shape) MermaidError!usize {
        if (self.index.get(id)) |index| {
            if (label) |value| {
                const clean = try label_text.clean(self.alloc, value);
                self.alloc.free(self.nodes.items[index].label);
                self.nodes.items[index].label = clean;
                self.nodes.items[index].shape = shape;
            } else if (shape == .diamond or shape == .start or shape == .finish) {
                self.nodes.items[index].shape = shape;
            }
            return index;
        }
        if (self.nodes.items.len >= max_nodes) return error.TooComplex;
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        const owned_label = try label_text.clean(self.alloc, label orelse id);
        errdefer self.alloc.free(owned_label);
        const index = self.nodes.items.len;
        try self.nodes.append(self.alloc, .{
            .id = owned_id,
            .label = owned_label,
            .shape = shape,
        });
        errdefer _ = self.nodes.pop();
        try self.index.put(owned_id, index);
        return index;
    }

    pub fn setLabel(self: *Graph, id: []const u8, label: []const u8, shape: ?Shape) MermaidError!usize {
        const index = try self.addNode(id, null, shape orelse .round);
        const clean = try label_text.clean(self.alloc, label);
        self.alloc.free(self.nodes.items[index].label);
        self.nodes.items[index].label = clean;
        if (shape) |value| self.nodes.items[index].shape = value;
        return index;
    }

    pub fn addMember(self: *Graph, index: usize, raw: []const u8) MermaidError!void {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0) return;
        var node = &self.nodes.items[index];
        if (node.members.items.len >= max_members) {
            if (node.members.items.len == max_members and
                !std.mem.eql(u8, node.members.items[max_members - 1], "…"))
            {
                const ellipsis = try self.alloc.dupe(u8, "…");
                self.alloc.free(node.members.items[max_members - 1]);
                node.members.items[max_members - 1] = ellipsis;
            }
            return;
        }
        const owned = try label_text.clean(self.alloc, text);
        errdefer self.alloc.free(owned);
        try node.members.append(self.alloc, owned);
    }

    pub fn addEdge(self: *Graph, edge: Edge) MermaidError!void {
        if (self.edges.items.len >= max_edges) return error.TooComplex;
        try self.edges.append(self.alloc, edge);
    }
};

pub const SequenceItem = union(enum) {
    message: struct {
        from: usize,
        to: usize,
        label: ?[]u8,
        dashed: bool,
        cross: bool,
    },
    note: struct {
        left: usize,
        right: usize,
        label: []u8,
    },
    divider: []u8,

    fn deinit(self: *SequenceItem, alloc: Allocator) void {
        switch (self.*) {
            .message => |message| if (message.label) |label| alloc.free(label),
            .note => |note| alloc.free(note.label),
            .divider => |label| alloc.free(label),
        }
        self.* = undefined;
    }
};

pub const Sequence = struct {
    alloc: Allocator,
    ids: std.ArrayList([]u8) = .empty,
    labels: std.ArrayList([]u8) = .empty,
    index: std.StringHashMap(usize),
    items: std.ArrayList(SequenceItem) = .empty,

    pub fn init(alloc: Allocator) Sequence {
        return .{ .alloc = alloc, .index = std.StringHashMap(usize).init(alloc) };
    }

    pub fn deinit(self: *Sequence) void {
        self.index.deinit();
        for (self.ids.items) |id| self.alloc.free(id);
        for (self.labels.items) |label| self.alloc.free(label);
        for (self.items.items) |*item| item.deinit(self.alloc);
        self.ids.deinit(self.alloc);
        self.labels.deinit(self.alloc);
        self.items.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn participant(self: *Sequence, id: []const u8, label: ?[]const u8) MermaidError!usize {
        if (self.index.get(id)) |index| {
            if (label) |value| {
                const clean = try label_text.clean(self.alloc, value);
                self.alloc.free(self.labels.items[index]);
                self.labels.items[index] = clean;
            }
            return index;
        }
        if (self.labels.items.len >= max_nodes) return error.TooComplex;
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        const owned_label = try label_text.clean(self.alloc, label orelse id);
        errdefer self.alloc.free(owned_label);
        const index = self.labels.items.len;
        try self.ids.append(self.alloc, owned_id);
        errdefer _ = self.ids.pop();
        try self.labels.append(self.alloc, owned_label);
        errdefer _ = self.labels.pop();
        try self.index.put(owned_id, index);
        return index;
    }
};

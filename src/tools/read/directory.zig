//! A directory read: a two-level listing through the workspace indexer, so
//! git's ignore rules apply inside a repository and `.gitignore` and the
//! usual build folders are skipped elsewhere. Each child folder shows at
//! most 12 entries, then `… N more`; read the sub-path for the rest.
const std = @import("std");
const indexer = @import("../../core/indexer/indexer.zig");

const Allocator = std.mem.Allocator;

const max_top_entries: usize = 200;
const max_child_entries: usize = 12;
const scan_cap: usize = 50_000;

const Node = struct {
    name: []const u8,
    directory: bool,
    children: std.ArrayList(Node) = .empty,
    /// Every entry below this folder, at any depth.
    descendants: usize = 0,
};

/// Lists the absolute directory `root`; `label` names it in the output.
/// Caller owns the result.
pub fn list(alloc: Allocator, root: []const u8, label: []const u8, stop: ?*std.atomic.Value(bool)) ![]u8 {
    var result = indexer.scan(alloc, root, .{ .candidate_cap = scan_cap }, stop) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.RootUnavailable => return error.NotDir,
    };
    defer result.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var top: std.ArrayList(Node) = .empty;
    var index: std.array_hash_map.String(usize) = .empty;
    var files: usize = 0;
    var folders: usize = 0;
    for (result.tree.entries) |entry| {
        if (entry.kind == .file) files += 1 else folders += 1;
        var parts = std.mem.splitScalar(u8, entry.path, '/');
        const first = parts.first();
        const second = parts.next();
        const is_dir_here = second != null or entry.kind == .directory;
        const top_index = index.get(first) orelse blk: {
            try top.append(arena, .{ .name = first, .directory = is_dir_here });
            try index.put(arena, first, top.items.len - 1);
            break :blk top.items.len - 1;
        };
        const parent = &top.items[top_index];
        if (second == null) continue;
        parent.directory = true;
        parent.descendants += 1;
        const child_name = second.?;
        const deeper = parts.next() != null;
        const child = for (parent.children.items) |*known| {
            if (std.mem.eql(u8, known.name, child_name)) break known;
        } else blk: {
            try parent.children.append(arena, .{ .name = child_name, .directory = deeper or entry.kind == .directory });
            break :blk &parent.children.items[parent.children.items.len - 1];
        };
        if (deeper) {
            child.directory = true;
            child.descendants += 1;
        }
    }

    sortNodes(top.items);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Directory {s} · {d} {s}, {d} {s}{s}\n", .{
        label,
        files,
        if (files == 1) "file" else "files",
        folders,
        if (folders == 1) "folder" else "folders",
        if (result.tree.cap_reached or result.tree.incomplete) " (listing capped)" else "",
    });
    for (top.items, 0..) |*node, i| {
        if (i == max_top_entries) {
            try w.print("… {d} more\n", .{top.items.len - i});
            break;
        }
        try writeNode(w, node, "");
        if (!node.directory) continue;
        sortNodes(node.children.items);
        for (node.children.items, 0..) |*child, j| {
            if (j == max_child_entries) {
                try w.print("  … {d} more\n", .{node.children.items.len - j});
                break;
            }
            try writeNode(w, child, "  ");
        }
    }
    if (top.items.len == 0) try w.writeAll("(empty)\n");
    return out.toOwnedSlice();
}

fn writeNode(w: *std.Io.Writer, node: *const Node, indent: []const u8) !void {
    if (!node.directory) return w.print("{s}{s}\n", .{ indent, node.name });
    if (node.descendants == 0) return w.print("{s}{s}/\n", .{ indent, node.name });
    try w.print("{s}{s}/ ({d})\n", .{ indent, node.name, node.descendants });
}

fn sortNodes(nodes: []Node) void {
    std.mem.sort(Node, nodes, {}, struct {
        fn lessThan(_: void, a: Node, b: Node) bool {
            if (a.directory != b.directory) return a.directory;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

test "directory listing groups two levels and caps child folders" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src/core/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/deep/a.zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "build/\n" });
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = "build/out.o", .data = "x" });
    var name_buf: [16]u8 = undefined;
    for (0..14) |i| try tmp.dir.writeFile(io, .{ .sub_path = try std.mem.print(&name_buf, "src/f{d:0>2}.txt", .{i}), .data = "x" });
    const root = try @import("../../core/shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const text = try list(alloc, root, ".", null);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "build") == null);
    try std.testing.expect(std.mem.find(u8, text, "src/ (") != null);
    try std.testing.expect(std.mem.find(u8, text, "  core/ (") != null);
    try std.testing.expect(std.mem.find(u8, text, "  … 4 more\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "\nREADME.md\n") != null);
}

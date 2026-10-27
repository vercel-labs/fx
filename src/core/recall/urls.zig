//! Internal URLs that read_file opens, as proto's `read` does:
//!
//! - `history://` lists the nodes of the calling node's tree;
//! - `history://<id>` renders a node's transcript, newest turns first to go
//!   when it is long, and `history://<id>/turn/<n>` one turn whole;
//! - `agent://<id>` summarizes a node: the fleet's worker row when it is a
//!   worker of the calling node, its state and turns otherwise, and its last
//!   reply.
//!
//! Every node of the tree is readable from every other, as in proto: a
//! worker may read its parent and siblings. Nodes of other trees are not.
//! `artifact://` is not offered: stored tool outputs already open by their
//! handle with read_tool_result.
const std = @import("std");
const types = @import("../shared/types.zig");
const corpus = @import("corpus.zig");
const recall = @import("recall.zig");

const Allocator = std.mem.Allocator;
const NodeView = recall.NodeView;
const NodeInfo = recall.NodeInfo;

/// A transcript keeps its newest turns within this many bytes.
const transcript_bytes = 512 * 1024;
/// A tool output in a transcript keeps this many bytes.
const transcript_output_bytes = 1500;
/// A tool output in a single turn keeps this many bytes.
const turn_output_bytes = 64 * 1024;
const last_reply_bytes = 4000;
const max_listed_nodes = 200;
const max_listed_depth = 4;

pub const isInternalUrl = @import("scheme.zig").isInternalUrl;

pub const Url = union(enum) {
    tree,
    node: []const u8,
    turn: struct { id: []const u8, number: u64 },
    agent: []const u8,
    artifact,
};

/// Null when `path` is no internal URL this version reads.
pub fn parse(path: []const u8) ?Url {
    if (std.mem.startsWith(u8, path, "artifact://")) return .artifact;
    if (std.mem.startsWith(u8, path, "agent://")) {
        const id = std.mem.trimEnd(u8, path["agent://".len..], "/");
        return if (validId(id)) .{ .agent = id } else null;
    }
    if (!std.mem.startsWith(u8, path, "history://")) return null;
    const rest = std.mem.trimEnd(u8, path["history://".len..], "/");
    if (rest.len == 0) return .tree;
    var parts = std.mem.splitScalar(u8, rest, '/');
    const id = parts.next().?;
    if (!validId(id)) return null;
    const keyword = parts.next() orelse return .{ .node = id };
    const digits = parts.next() orelse return null;
    if (parts.next() != null or !std.mem.eql(u8, keyword, "turn")) return null;
    const number = std.fmt.parseUnsigned(u64, digits, 10) catch return null;
    return .{ .turn = .{ .id = id, .number = number } };
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

pub const Resource = union(enum) {
    text: []u8,
    failure: []u8,
};

/// Renders internal URL `path` for the calling node. Caller owns the text.
pub fn read(alloc: Allocator, view: NodeView, path: []const u8) !Resource {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    const failure: ?[]const u8 = switch (parse(path) orelse return .{ .failure = try alloc.print(
        "Unsupported internal URL `{s}`. Use history://, history://<id>, history://<id>/turn/<n> or agent://<id>.",
        .{path},
    ) }) {
        .artifact => "artifact:// is not available: open a stored tool output by its handle with read_tool_result.",
        .tree => blk: {
            try writeTree(arena, &out.writer, view);
            break :blk null;
        },
        .node => |id| try withNode(arena, view, id, &out.writer, writeTranscript, {}),
        .turn => |turn| try withNode(arena, view, turn.id, &out.writer, writeTurn, turn.number),
        .agent => |id| try withNode(arena, view, id, &out.writer, writeAgent, {}),
    };
    if (failure) |text| return .{ .failure = try alloc.dupe(u8, text) };
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

/// Runs `render` on node `id` when it is in the caller's tree; otherwise the
/// failure text.
fn withNode(
    arena: Allocator,
    view: NodeView,
    id: []const u8,
    writer: *std.Io.Writer,
    comptime render: anytype,
    extra: anytype,
) !?[]const u8 {
    const info = try view.source.nodeInfo(arena, id) orelse
        return try arena.print("Unknown node `{s}`. List this tree's nodes with history://.", .{id});
    const root = if (info.parent == null) id else info.root;
    if (!std.mem.eql(u8, root, view.root_id))
        return try arena.print("Node `{s}` is not in this session tree. List the nodes you can read with history://.", .{id});
    return render(arena, view, id, info, writer, extra);
}

fn relation(view: NodeView, id: []const u8, info: NodeInfo) []const u8 {
    if (std.mem.eql(u8, id, view.node_id)) return "this node";
    if (info.parent == null) return "root";
    if (std.mem.eql(u8, info.parent.?, view.node_id)) return "your child";
    return "in this tree";
}

fn writeHeading(writer: *std.Io.Writer, view: NodeView, id: []const u8, info: NodeInfo) !void {
    try writer.print("{s} · depth {d}", .{ relation(view, id, info), info.depth });
    if (info.parent) |parent| try writer.print(" · parent {s}", .{parent});
    try writer.print(" · {d} turn{s} · {s}\n", .{ info.turns, if (info.turns == 1) "" else "s", if (info.running) "running" else "idle" });
}

fn writeTree(arena: Allocator, writer: *std.Io.Writer, view: NodeView) !void {
    try writer.writeAll("# history://\n\nNodes of this session tree. Read a transcript with history://<id>, one turn with history://<id>/turn/<n>, a summary with agent://<id>.\n\n");
    const Item = struct { id: []const u8, depth: usize };
    var stack: std.ArrayList(Item) = .empty;
    try stack.append(arena, .{ .id = view.root_id, .depth = 0 });
    var listed: usize = 0;
    while (stack.pop()) |item| {
        if (listed == max_listed_nodes) {
            try writer.writeAll("… more nodes are not listed.\n");
            break;
        }
        listed += 1;
        for (0..item.depth) |_| try writer.writeAll("  ");
        try writer.print("- {s}", .{item.id});
        if (try view.source.nodeInfo(arena, item.id)) |info| {
            try writer.writeAll(" · ");
            try writeHeading(writer, view, item.id, info);
        } else try writer.writeAll(" · not saved yet\n");
        if (item.depth == max_listed_depth) continue;
        const children = view.source.childIds(arena, item.id) catch &.{};
        var index = children.len;
        while (index > 0) {
            index -= 1;
            try stack.append(arena, .{ .id = children[index], .depth = item.depth + 1 });
        }
    }
}

/// Collects each turn rendered on its own, so the newest that fit are kept.
const TurnTexts = struct {
    arena: Allocator,
    view: NodeView,
    id: []const u8,
    output_bytes: usize,
    only: ?u64 = null,
    texts: std.ArrayList([]const u8) = .empty,
    numbers: std.ArrayList(u64) = .empty,
    last_reply: ?[]const u8 = null,

    fn turn(context: *anyopaque, value: types.HistoryTurn, number: u64) anyerror!void {
        const self: *TurnTexts = @ptrCast(@alignCast(context));
        try self.numbers.append(self.arena, number);
        self.last_reply = switch (value) {
            .assistant => |entry| try self.arena.dupe(u8, corpus.clip(entry.assistant, last_reply_bytes)),
            .interrupted => |entry| if (entry.assistant) |text| try self.arena.dupe(u8, corpus.clip(text, last_reply_bytes)) else self.last_reply,
            .compacted_summary => self.last_reply,
        };
        if (self.only) |wanted| if (wanted != number) return;
        var out: std.Io.Writer.Allocating = .init(self.arena);
        try out.writer.print("## Turn {d}\n", .{number});
        var parts: PartWriter = .{ .self = self, .writer = &out.writer, .number = number };
        try corpus.forEachPart(value, &parts);
        try self.texts.append(self.arena, out.written());
    }

    const PartWriter = struct {
        self: *TurnTexts,
        writer: *std.Io.Writer,
        number: u64,

        pub fn part(parts: *PartWriter, value: corpus.Part) !void {
            const writer = parts.writer;
            switch (value.role) {
                .user, .assistant => try writer.print("[{s}] {s}\n", .{ @tagName(value.role), value.text }),
                .tool => {
                    try writer.print("[{s}] {s}\n", .{ value.tool, corpus.clip(value.text, 2000) });
                    const readable = corpus.readableOutput(parts.self.arena, value.output);
                    const shown = corpus.clip(readable, parts.self.output_bytes);
                    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, shown, "\n"), '\n');
                    while (lines.next()) |line| try writer.print("  {s}\n", .{line});
                    if (shown.len < readable.len) {
                        try writer.print("  … {d} more bytes; whole turn: history://{s}/turn/{d}\n", .{ readable.len - shown.len, parts.self.id, parts.number });
                    }
                    if (value.handle) |handle| {
                        if (std.mem.eql(u8, parts.self.id, parts.self.view.node_id))
                            try writer.print("  (the model saw a preview; whole output: read_tool_result handle \"{s}\")\n", .{handle})
                        else
                            try writer.print("  (the model saw a preview; the whole output is stored with node {s})\n", .{parts.self.id});
                    }
                },
            }
        }
    };
};

fn collect(arena: Allocator, view: NodeView, id: []const u8, output_bytes: usize, only: ?u64) !TurnTexts {
    var texts: TurnTexts = .{ .arena = arena, .view = view, .id = id, .output_bytes = output_bytes, .only = only };
    try view.source.visitTurns(arena, id, .{ .context = &texts, .turn_fn = TurnTexts.turn });
    return texts;
}

fn writeTranscript(arena: Allocator, view: NodeView, id: []const u8, info: NodeInfo, writer: *std.Io.Writer, _: void) !?[]const u8 {
    const texts = try collect(arena, view, id, transcript_output_bytes, null);
    try writer.print("# history://{s}\n\n", .{id});
    try writeHeading(writer, view, id, info);
    const all = texts.texts.items;
    var first = all.len;
    var spent: usize = 0;
    while (first > 0 and spent + all[first - 1].len <= transcript_bytes) : (first -= 1) spent += all[first - 1].len;
    if (first == all.len and first > 0) first -= 1;
    if (all.len == 0) try writer.writeAll("\nNo saved turns yet.\n");
    if (first > 0) try writer.print("\nShowing the newest {d} of {d} turns; read an older one with history://{s}/turn/<n> (turns {d} to {d}).\n", .{ all.len - first, all.len, id, texts.numbers.items[0], texts.numbers.items[first - 1] });
    for (all[first..]) |text| try writer.print("\n{s}", .{text});
    return null;
}

fn writeTurn(arena: Allocator, view: NodeView, id: []const u8, _: NodeInfo, writer: *std.Io.Writer, number: u64) !?[]const u8 {
    const texts = try collect(arena, view, id, turn_output_bytes, number);
    if (texts.texts.items.len == 0) {
        const numbers = texts.numbers.items;
        if (numbers.len == 0) return try arena.print("Node `{s}` has no saved turns yet.", .{id});
        return try arena.print("history://{s} has no turn {d}; its turns run from {d} to {d}.", .{ id, number, numbers[0], numbers[numbers.len - 1] });
    }
    try writer.print("# history://{s}/turn/{d}\n\n{s}", .{ id, number, texts.texts.items[0] });
    return null;
}

fn writeAgent(arena: Allocator, view: NodeView, id: []const u8, info: NodeInfo, writer: *std.Io.Writer, _: void) !?[]const u8 {
    try writer.print("# agent://{s}\n\n", .{id});
    if (try view.source.inspectWorker(arena, id)) |row| try writer.print("{s}\n\n", .{row});
    try writeHeading(writer, view, id, info);
    const texts = try collect(arena, view, id, 0, std.math.maxInt(u64));
    try writer.writeAll("\n## Last reply\n\n");
    try writer.writeAll(texts.last_reply orelse "Nothing produced yet.");
    try writer.print("\n\nFull transcript: history://{s}\n", .{id});
    return null;
}

const testing = std.testing;

test "internal URLs parse to the node, turn and summary they name" {
    try testing.expect(parse("history://").? == .tree);
    try testing.expectEqualStrings("abc-1", parse("history://abc-1/").?.node);
    const turn = parse("history://abc/turn/12").?.turn;
    try testing.expectEqualStrings("abc", turn.id);
    try testing.expectEqual(@as(u64, 12), turn.number);
    try testing.expectEqualStrings("w1", parse("agent://w1").?.agent);
    try testing.expect(parse("history://abc/step/1") == null);
    try testing.expect(parse("history://../etc") == null);
    try testing.expect(parse("src/main.zig") == null);
    try testing.expect(isInternalUrl("agent://x") and !isInternalUrl("./agent://x"));
}

const TreeFake = struct {
    turns: []const types.HistoryTurn,

    fn source(self: *TreeFake) recall.Source {
        return .{ .context = self, .vtable = &.{ .visit_turns = visitTurns, .node_info = nodeInfo, .child_ids = childIds, .inspect_worker = inspectWorker } };
    }

    fn visitTurns(context: *anyopaque, _: Allocator, id: []const u8, sink: recall.TurnSink) anyerror!void {
        const self: *TreeFake = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, id, "w1")) return;
        for (self.turns, 1..) |turn, number| try sink.turn(turn, number + 4);
    }

    fn nodeInfo(_: *anyopaque, _: Allocator, id: []const u8) anyerror!?NodeInfo {
        if (std.mem.eql(u8, id, "root")) return .{ .root = "root", .parent = null, .depth = 0, .version = 1, .turns = 3, .running = true };
        if (std.mem.eql(u8, id, "w1")) return .{ .root = "root", .parent = "root", .depth = 1, .version = 1, .turns = 2, .running = false };
        if (std.mem.eql(u8, id, "stranger")) return .{ .root = "other", .parent = "other", .depth = 1, .version = 1, .turns = 1, .running = false };
        return null;
    }

    fn childIds(_: *anyopaque, _: Allocator, id: []const u8) anyerror![]const []const u8 {
        return if (std.mem.eql(u8, id, "root")) &.{"w1"} else &.{};
    }

    fn inspectWorker(_: *anyopaque, arena: Allocator, id: []const u8) anyerror!?[]const u8 {
        return try arena.print("Worker `{s}` (label `parser`)", .{id});
    }
};

fn expectText(resource: Resource, needles: []const []const u8) !void {
    defer switch (resource) {
        inline else => |text| testing.allocator.free(text),
    };
    const text = switch (resource) {
        .text => |value| value,
        .failure => |value| {
            std.debug.print("unexpected failure: {s}\n", .{value});
            return error.TestUnexpectedResult;
        },
    };
    for (needles) |needle| if (std.mem.find(u8, text, needle) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        return error.TestExpectedEqual;
    };
}

test "history and agent URLs render the tree, a transcript, a turn and a worker summary" {
    var calls = [_]types.ToolCall{.{ .id = "c1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" }};
    var results = [_]types.PersistedToolResult{.{ .tool_call_id = @constCast("c1"), .tool_name = @constCast("shell"), .status = .success, .output = @constCast("a.txt\nb.txt"), .output_bytes = 11, .stored_output_bytes = 11 }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const turns = [_]types.HistoryTurn{
        corpus.testTurn("list files", &steps, "Two files."),
        corpus.testTurn("parse them", &.{}, "Parsed both; the tokenizer had an off-by-one."),
    };
    var fake: TreeFake = .{ .turns = &turns };
    var cache = recall.Cache.init(testing.allocator);
    defer cache.deinit();
    const view: NodeView = .{ .source = fake.source(), .cache = &cache, .root_id = "root", .node_id = "root" };

    try expectText(try read(testing.allocator, view, "history://"), &.{ "- root · this node · depth 0 · 3 turns · running", "  - w1 · your child · depth 1 · parent root · 2 turns · idle" });
    try expectText(try read(testing.allocator, view, "history://w1"), &.{ "# history://w1", "## Turn 5\n[user] list files\n[shell] {\"command\":\"ls\"}\n  a.txt\n  b.txt\n[assistant] Two files.", "## Turn 6" });
    try expectText(try read(testing.allocator, view, "history://w1/turn/6"), &.{"# history://w1/turn/6\n\n## Turn 6\n[user] parse them"});
    try expectText(try read(testing.allocator, view, "agent://w1"), &.{ "Worker `w1` (label `parser`)", "## Last reply\n\nParsed both; the tokenizer had an off-by-one.", "Full transcript: history://w1" });

    const missing = try read(testing.allocator, view, "history://w1/turn/9");
    defer testing.allocator.free(missing.failure);
    try testing.expectEqualStrings("history://w1 has no turn 9; its turns run from 5 to 6.", missing.failure);
    const stranger = try read(testing.allocator, view, "agent://stranger");
    defer testing.allocator.free(stranger.failure);
    try testing.expect(std.mem.startsWith(u8, stranger.failure, "Node `stranger` is not in this session tree."));
    const unknown = try read(testing.allocator, view, "history://nobody");
    defer testing.allocator.free(unknown.failure);
    try testing.expect(std.mem.startsWith(u8, unknown.failure, "Unknown node `nobody`."));
}

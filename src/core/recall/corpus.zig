//! A node's history as recall searches it: one entry per user message,
//! assistant message, and tool call with its result, numbered `#0`, `#1`, ...
//! in the order the node saw them. Entries come from the node's saved turns,
//! compacted ones included, so a detail compaction dropped from the context
//! is still found. Memory is bounded: each entry keeps at most
//! `max_entry_bytes`, and the oldest entries leave the index once the whole
//! exceeds `max_index_bytes`.
const std = @import("std");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const max_entry_bytes: usize = 32 * 1024;
pub const max_index_bytes: usize = 48 * 1024 * 1024;

pub const Role = enum { user, assistant, tool };

/// One searchable message. Strings are owned by the index.
pub const Entry = struct {
    /// The `#N` the agent types to expand it.
    index: usize,
    turn: u64,
    role: Role,
    /// The tool's name for a tool entry.
    tool: []const u8 = "",
    text: []const u8,
    /// Words in `text`, for BM25's length normalization.
    words: u32 = 0,
    /// The handle of the whole stored output, readable with
    /// read_tool_result, when the model saw only a preview.
    handle: ?[]const u8 = null,
    /// The file an edit_file or write_file call changed.
    path: ?[]const u8 = null,

    pub fn label(entry: Entry) []const u8 {
        return switch (entry.role) {
            .user => "user",
            .assistant => "assistant",
            .tool => entry.tool,
        };
    }
};

/// One part of a turn, borrowed from it.
pub const Part = struct {
    role: Role,
    tool: []const u8 = "",
    /// User or assistant text; a tool call's arguments.
    text: []const u8,
    /// A tool call's result as the model saw it.
    output: []const u8 = "",
    handle: ?[]const u8 = null,
};

/// Calls `visitor.part(part)` for each part of `turn` in the order the
/// model saw them: the prompt, then each step's text and tool calls with
/// steering given after it, then the closing reply.
pub fn forEachPart(turn: types.HistoryTurn, visitor: anytype) !void {
    const user, const reply, const execution = switch (turn) {
        .assistant => |entry| .{ entry.user.text, @as(?[]const u8, entry.assistant), entry.execution },
        .interrupted => |entry| .{ entry.user.text, @as(?[]const u8, entry.assistant), entry.execution },
        .compacted_summary => return,
    };
    if (user.len > 0) try visitor.part(.{ .role = .user, .text = user });
    for (execution.tool_steps, 0..) |step, index| {
        try steeringAfter(execution.steering, index, visitor);
        if (step.assistant) |text| if (text.len > 0) try visitor.part(.{ .role = .assistant, .text = text });
        for (step.tool_calls) |call| {
            const result = findResult(step.tool_results, call.id);
            try visitor.part(.{
                .role = .tool,
                .tool = call.name,
                .text = call.arguments_json,
                .output = if (result) |value| value.output else "",
                .handle = if (result) |value| if (value.truncated) value.output_handle else null else null,
            });
        }
    }
    try steeringAfter(execution.steering, execution.tool_steps.len, visitor);
    if (reply) |text| if (text.len > 0) try visitor.part(.{ .role = .assistant, .text = text });
}

/// A tool output as a person reads it: a command result's captured text
/// instead of the JSON envelope the model saw it in; any other output as it
/// is. Allocated in `arena` when decoded.
pub fn readableOutput(arena: Allocator, output: []const u8) []const u8 {
    if (output.len < 2 or output[0] != '{') return output;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch return output;
    if (value != .object) return output;
    for ([_][]const u8{ "output_delta", "output" }) |field| {
        const text = value.object.get(field) orelse continue;
        if (text == .string) return text.string;
    }
    return output;
}

fn steeringAfter(steering: []const types.PersistedSteering, steps: usize, visitor: anytype) !void {
    for (steering) |item| if (item.after_tool_step_count == steps) try visitor.part(.{ .role = .user, .text = item.text });
}

fn findResult(results: []const types.PersistedToolResult, id: []const u8) ?types.PersistedToolResult {
    for (results) |result| if (std.mem.eql(u8, result.tool_call_id, id)) return result;
    return null;
}

/// Reads up to `max_bytes` of a stored output by handle; null when it
/// cannot. The text is owned by `arena`.
pub const StoredReader = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, arena: Allocator, handle: []const u8, max_bytes: usize) ?[]const u8,

    fn read(self: StoredReader, arena: Allocator, handle: []const u8, max_bytes: usize) ?[]const u8 {
        return self.read_fn(self.context, arena, handle, max_bytes);
    }
};

/// The searchable entries of one node at one log position. Owns its strings.
pub const Index = struct {
    alloc: Allocator,
    id: []u8,
    version: u64,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    /// Entries left out, oldest first, to stay within `max_index_bytes`.
    dropped: usize = 0,
    /// The next `#N`.
    next: usize = 0,

    pub fn init(alloc: Allocator, id: []const u8, version: u64) !Index {
        return .{ .alloc = alloc, .id = try alloc.dupe(u8, id), .version = version };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.alloc);
        self.alloc.free(self.id);
        self.* = undefined;
    }

    fn freeEntry(self: *Index, entry: Entry) void {
        self.alloc.free(entry.text);
        self.alloc.free(entry.tool);
        if (entry.handle) |handle| self.alloc.free(handle);
        if (entry.path) |path| self.alloc.free(path);
    }

    /// Adds `turn`'s parts. `stored` reads whole outputs the model saw
    /// only a preview of; null searches the previews.
    pub fn addTurn(self: *Index, turn: types.HistoryTurn, number: u64, stored: ?StoredReader) !void {
        var adder: Adder = .{ .index = self, .turn = number, .stored = stored };
        try forEachPart(turn, &adder);
        // Drop whole entries from the oldest end; the index stays a suffix.
        var cut: usize = 0;
        while (self.bytes > max_index_bytes and cut < self.entries.items.len) : (cut += 1) {
            const entry = self.entries.items[cut];
            self.bytes -= entry.text.len;
            self.freeEntry(entry);
        }
        if (cut > 0) {
            self.entries.replaceRangeAssumeCapacity(0, cut, &.{});
            self.dropped += cut;
        }
    }

    /// The entry numbered `#index`, if the index still holds it.
    pub fn find(self: *const Index, index: usize) ?Entry {
        if (index < self.dropped or index >= self.next) return null;
        return self.entries.items[index - self.dropped];
    }

    const Adder = struct {
        index: *Index,
        turn: u64,
        stored: ?StoredReader,

        pub fn part(self: *Adder, value: Part) !void {
            const index = self.index;
            const alloc = index.alloc;
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const output = whole: {
                const handle = value.handle orelse break :whole value.output;
                const reader = self.stored orelse break :whole value.output;
                break :whole reader.read(scratch.allocator(), handle, max_entry_bytes) orelse value.output;
            };
            const readable = readableOutput(scratch.allocator(), output);
            const joined = if (value.role == .tool)
                try scratch.allocator().print("{s}\n{s}", .{ value.text, readable })
            else
                value.text;
            const text = try alloc.dupe(u8, clip(joined, max_entry_bytes));
            errdefer alloc.free(text);
            const handle = if (value.handle) |handle| try alloc.dupe(u8, handle) else null;
            errdefer if (handle) |owned| alloc.free(owned);
            const path = if (value.role == .tool) try filePath(alloc, value.tool, value.text) else null;
            errdefer if (path) |owned| alloc.free(owned);
            const tool = try alloc.dupe(u8, clip(value.tool, 64));
            errdefer alloc.free(tool);
            try index.entries.append(alloc, .{
                .index = index.next,
                .turn = self.turn,
                .role = value.role,
                .tool = tool,
                .text = text,
                .words = wordCount(text),
                .handle = handle,
                .path = path,
            });
            index.next += 1;
            index.bytes += text.len;
        }
    };
};

/// The `path` argument of an edit_file or write_file call.
fn filePath(alloc: Allocator, tool: []const u8, arguments: []const u8) !?[]u8 {
    if (!std.mem.eql(u8, tool, "edit_file") and !std.mem.eql(u8, tool, "write_file")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path = parsed.value.object.get("path") orelse return null;
    if (path != .string) return null;
    return try alloc.dupe(u8, path.string);
}

pub fn clip(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    return text[0..text_utils.utf8BackwardBoundary(text, max_bytes)];
}

fn wordCount(text: []const u8) u32 {
    var count: u32 = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |_| count +|= 1;
    return count;
}

const testing = std.testing;

pub fn testTurn(user: []const u8, steps: []types.ToolExecutionStep, reply: []const u8) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast(user) },
        .assistant = @constCast(reply),
        .execution = .{ .tool_steps = steps },
    } };
}

test "a turn's parts come in the order the model saw them, with steering after its step" {
    var calls = [_]types.ToolCall{.{ .id = "c1", .name = "edit_file", .arguments_json = "{\"path\":\"src/a.zig\",\"new_string\":\"retry\"}" }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("c1"),
        .tool_name = @constCast("edit_file"),
        .status = .success,
        .output = @constCast("preview"),
        .output_handle = @constCast("h1"),
        .truncated = true,
        .output_bytes = 9,
        .stored_output_bytes = 9,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .assistant = @constCast("looking"), .tool_calls = &calls, .tool_results = &results }};
    var steering = [_]types.PersistedSteering{.{ .text = @constCast("also tests"), .after_tool_step_count = 1 }};
    var turn = testTurn("fix it", &steps, "done");
    turn.assistant.execution.steering = &steering;

    var index = try Index.init(testing.allocator, "node", 1);
    defer index.deinit();
    const Reader = struct {
        fn read(_: *anyopaque, arena: Allocator, handle: []const u8, _: usize) ?[]const u8 {
            return arena.print("whole output of {s}", .{handle}) catch null;
        }
    };
    var context: u8 = 0;
    try index.addTurn(turn, 7, .{ .context = &context, .read_fn = Reader.read });
    const labels = [_][]const u8{ "user", "assistant", "edit_file", "user", "assistant" };
    try testing.expectEqual(labels.len, index.entries.items.len);
    for (labels, index.entries.items, 0..) |want, entry, n| {
        try testing.expectEqualStrings(want, entry.label());
        try testing.expectEqual(n, entry.index);
        try testing.expectEqual(@as(u64, 7), entry.turn);
    }
    const tool = index.find(2).?;
    try testing.expectEqualStrings("src/a.zig", tool.path.?);
    try testing.expectEqualStrings("h1", tool.handle.?);
    try testing.expect(std.mem.endsWith(u8, tool.text, "whole output of h1"));
}

test "a command result reads as its captured text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("build id: Z\n1", readableOutput(arena.allocator(), "{\"exit_code\":0,\"output_delta\":\"build id: Z\\n1\"}"));
    try testing.expectEqualStrings("{\"rows\":3}", readableOutput(arena.allocator(), "{\"rows\":3}"));
    try testing.expectEqualStrings("plain", readableOutput(arena.allocator(), "plain"));
}

test "the index keeps the newest entries within its byte bound" {
    var index = try Index.init(testing.allocator, "node", 1);
    defer index.deinit();
    const big = try testing.allocator.alloc(u8, max_entry_bytes);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    const turns = max_index_bytes / max_entry_bytes + 3;
    for (0..turns) |n| try index.addTurn(testTurn(big, &.{}, ""), n + 1, null);
    try testing.expect(index.bytes <= max_index_bytes);
    try testing.expectEqual(@as(usize, 3), index.dropped);
    try testing.expect(index.find(0) == null);
    try testing.expectEqual(@as(u64, 4), index.find(3).?.turn);
    try testing.expectEqual(turns - 1, index.find(turns - 1).?.index);
}

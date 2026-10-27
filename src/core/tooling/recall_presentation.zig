//! The settled row of a `recall` call, read back from its result so a live
//! turn and a replayed one look the same: the query and how many entries
//! matched, then the top hits as continuation rows.
//!
//!   ● Recalled "retry storms" · 3 matches
//!     #12 assistant · Use exponential backoff for retry storms.
//!     #40 shell · {"command":"rg backoff"}
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const shown_hits = 3;
const hit_bytes = 100;
const query_bytes = 60;

pub fn isRecallCall(call: types.ToolCall) bool {
    return std.mem.eql(u8, call.name, "recall");
}

/// Null when `call` is no recall call or `output` is not a recall result.
/// Caller owns the text.
pub fn statusLine(alloc: Allocator, call: types.ToolCall, output: []const u8) Allocator.Error!?[]u8 {
    if (!isRecallCall(call)) return null;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const raw_query = std.mem.trim(u8, tool_args.optionalStringArg(args, "query") orelse "", " \t\r\n");
    const query = (try text_utils.encodeTerminalSafeInline(arena, raw_query, query_bytes)).bytes;
    const line = compose(arena, query, output) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    } orelse return null;
    return try alloc.dupe(u8, line);
}

fn compose(arena: Allocator, query: []const u8, output: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    const header = lines.first();
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    if (std.mem.startsWith(u8, header, "Session history (")) {
        const count = numberAfter(header, "Session history (") orelse return null;
        try writer.print("Recalled session history · {d} entries", .{count});
    } else if (std.mem.startsWith(u8, header, "No matches for ")) {
        try writer.print("Recalled \"{s}\" · no matches", .{query});
    } else if (std.mem.startsWith(u8, header, "Found ")) {
        const count = numberAfter(header, "Found ") orelse return null;
        try writer.print("Recalled \"{s}\" · {d} {s}", .{ query, count, if (count == 1) "match" else "matches" });
        try writeHits(arena, writer, &lines);
    } else if (std.mem.startsWith(u8, header, "Page ")) {
        const open = std.mem.findScalar(u8, header, '(') orelse return null;
        const count = numberAfter(header[open..], "(") orelse return null;
        try writer.print("Recalled \"{s}\" · {d} matches · {s}", .{ query, count, std.mem.trimEnd(u8, header[0..open], " ") });
        try writeHits(arena, writer, &lines);
    } else if (std.mem.startsWith(u8, header, "#")) {
        const label = try hitLabel(arena, header) orelse return null;
        try writer.print("Recalled {s}", .{label});
    } else return null;
    return out.written();
}

fn numberAfter(text: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseUnsigned(usize, rest[0..end], 10) catch null;
}

fn writeHits(arena: Allocator, writer: *std.Io.Writer, lines: *std.mem.SplitIterator(u8, .scalar)) !void {
    var shown: usize = 0;
    while (lines.next()) |line| {
        if (shown == shown_hits) break;
        if (!std.mem.startsWith(u8, line, "#")) continue;
        const label = try hitLabel(arena, line) orelse continue;
        try writer.print("\n{s}", .{label});
        shown += 1;
    }
}

/// `#12 [assistant] text` as `#12 assistant · text`, clipped and
/// terminal-safe.
fn hitLabel(arena: Allocator, line: []const u8) !?[]const u8 {
    const open = std.mem.find(u8, line, " [") orelse return null;
    const close = std.mem.findScalarPos(u8, line, open, ']') orelse return null;
    const rest = std.mem.trim(u8, line[close + 1 ..], " ");
    const joined = if (rest.len == 0)
        try arena.print("{s} {s}", .{ line[0..open], line[open + 2 .. close] })
    else
        try arena.print("{s} {s} · {s}", .{ line[0..open], line[open + 2 .. close], rest });
    return (try text_utils.encodeTerminalSafeInline(arena, joined, hit_bytes)).bytes;
}

const testing = std.testing;

fn expectLine(arguments: []const u8, output: []const u8, want: ?[]const u8) !void {
    const call: types.ToolCall = .{ .id = "c", .name = "recall", .arguments_json = arguments };
    const got = try statusLine(testing.allocator, call, output);
    defer if (got) |text| testing.allocator.free(text);
    if (want) |text| try testing.expectEqualStrings(text, got.?) else try testing.expect(got == null);
}

test "a recall row names the query, the match count and the top hits" {
    try expectLine(
        "{\"query\":\"retry storms\"}",
        "Found 2 matches for \"retry storms\":\n\n#12 [assistant] Use exponential backoff for retry storms.\n  use history://n/turn/4\n\n#40 [shell] {\"command\":\"rg retry\"}\n  use history://n/turn/9",
        "Recalled \"retry storms\" · 2 matches\n#12 assistant · Use exponential backoff for retry storms.\n#40 shell · {\"command\":\"rg retry\"}",
    );
    try expectLine("{\"query\":\"deploy\",\"page\":2}", "Page 2/3 (12 matches) for \"deploy\":\n\n#3 [user] deploy", "Recalled \"deploy\" · 12 matches · Page 2/3\n#3 user · deploy");
    try expectLine("{\"query\":\"k8s\"}", "No matches for \"k8s\" in session history.", "Recalled \"k8s\" · no matches");
    try expectLine("{}", "Session history (40 entries):\n\n#39 [user] turn 9 · hi", "Recalled session history · 40 entries");
    try expectLine("{\"query\":\"#12\"}", "#12 [assistant] turn 4\nfull text", "Recalled #12 assistant · turn 4");
    try expectLine("{}", "Searching session history failed: Io", null);
    const other: types.ToolCall = .{ .id = "c", .name = "read_file", .arguments_json = "{}" };
    try testing.expect((try statusLine(testing.allocator, other, "Found 1 match")) == null);
}

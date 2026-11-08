const std = @import("std");
const result_store = @import("../session/result_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const compactor = @import("../compactor/compactor.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");

const Allocator = std.mem.Allocator;

/// Longest search text a row repeats, after terminal-safe encoding.
const max_query_label_bytes = 60;

/// A handle as `validate` resolves it: without surrounding whitespace, plus
/// the `.txt` a stored result or image handle may omit.
const HandleNormalization = struct {
    trimmed: []const u8,
    suffix: []const u8,
};

pub fn classifyHandleNormalization(handle: []const u8) HandleNormalization {
    const trimmed = std.mem.trim(u8, handle, " \t\r\n");
    const suffix = if ((std.mem.startsWith(u8, trimmed, "result-") or result_store.isImageHandle(trimmed)) and
        std.mem.findScalar(u8, trimmed, '.') == null)
        ".txt"
    else
        "";
    return .{ .trimmed = trimmed, .suffix = suffix };
}

/// What a call asks for, read the way the tool's `decode` and `validate` read it,
/// so its row can say what the agent is reading.
const RequestView = struct {
    kind: Kind,
    /// The handle without surrounding whitespace. Empty for a history search.
    handle: []const u8 = "",
    query: []const u8 = "",

    const Kind = enum { range, query, images, record, history_search };
};

/// A `request` sent as JSON text is decoded in `alloc`, as `decode` reads it,
/// and the view's strings live in `alloc` or `args`.
fn requestView(alloc: Allocator, args: std.json.ObjectMap) Allocator.Error!?RequestView {
    const object = if (args.get("request")) |request|
        try tool_args.requestWrapperObject(alloc, request) orelse return null
    else
        args;
    if (object.get("search") != null) return .{ .kind = .history_search };
    const handle = switch (object.get("handle") orelse return null) {
        .string => |value| std.mem.trim(u8, value, " \t\r\n"),
        else => return null,
    };
    if (handle.len == 0) return null;
    var record_buffer: compactor.RecordFileBuffer = undefined;
    if (compactor.recordFile(&record_buffer, handle) != null) return .{ .kind = .record, .handle = handle };
    if (result_store.isImageHandle(handle)) return .{ .kind = .images, .handle = handle };
    if (object.get("query")) |query| {
        if (query == .string and query.string.len > 0) {
            return .{ .kind = .query, .handle = handle, .query = query.string };
        }
    }
    return .{ .kind = .range, .handle = handle };
}

fn parseArguments(alloc: Allocator, arguments_json: []const u8) Allocator.Error!?std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

fn outputNoun(handle: []const u8, command: []const u8, other: []const u8) []const u8 {
    return if (command_replay_store.isReplayHandle(handle)) command else other;
}

fn recordNoun(kind: u8) []const u8 {
    return switch (std.ascii.toUpper(kind)) {
        'M' => "turn",
        'T' => "tool call",
        else => "compaction",
    };
}

fn readPresentation(
    action_label: []const u8,
    completed_action_label: []const u8,
    label_arg_default: []const u8,
) tool_dispatch.CallPresentation {
    return .{
        .activity_kind = .read,
        .action_label = action_label,
        .completed_action_label = completed_action_label,
        .label_arg_kind = .none,
        .label_arg_default = label_arg_default,
    };
}

/// What `presentation` decodes a `request` sent as JSON text in. A presentation
/// callback has no allocator, and a call that asks for a handle or a search
/// needs far less. A request whose decoded form does not fit in this buffer, or
/// that is nested more deeply than the request depth limit, keeps the generic
/// row.
const presentation_buffer_bytes = 4096;

/// Labels a call by what it reads instead of one shared "tool result" label.
/// The resolved row text from `displayTarget` replaces the default object.
pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    var buffer: [presentation_buffer_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const view = (requestView(fixed.allocator(), args) catch return null) orelse return null;
    return switch (view.kind) {
        .range => readPresentation("Reading", "Read", outputNoun(view.handle, "more command output", "more output")),
        .query => readPresentation("Searching", "Searched", outputNoun(view.handle, "command output", "saved output")),
        .images => readPresentation("Reloading", "Reloaded", "saved images"),
        .record => readPresentation("Opening", "Opened", "earlier conversation"),
        .history_search => readPresentation("Searching", "Searched", "earlier conversation"),
    };
}

/// The saved output a call reads, with the suffix `validate` restores, or null
/// for a history search, a saved record, or arguments `decode` rejects. The
/// caller owns the returned handle.
pub fn requestedHandle(alloc: Allocator, arguments_json: []const u8) Allocator.Error!?[]u8 {
    var parsed = (try parseArguments(alloc, arguments_json)) orelse return null;
    defer parsed.deinit();
    const view = (try requestView(parsed.arena.allocator(), parsed.value.object)) orelse return null;
    switch (view.kind) {
        .record, .history_search => return null,
        .range, .query, .images => {},
    }
    const normalization = classifyHandleNormalization(view.handle);
    return try std.mem.concat(alloc, u8, &.{ normalization.trimmed, normalization.suffix });
}

/// The row text for what a call reads: the output of the earlier call that
/// `source` names, the text it searches for, or the saved record it opens.
/// Returns null when the default object from `presentation` already says it.
/// `source` must be terminal-safe. The caller owns the returned text.
pub fn displayTarget(
    alloc: Allocator,
    arguments_json: []const u8,
    source: ?[]const u8,
) Allocator.Error!?[]u8 {
    var parsed = (try parseArguments(alloc, arguments_json)) orelse return null;
    defer parsed.deinit();
    const view = (try requestView(parsed.arena.allocator(), parsed.value.object)) orelse return null;
    switch (view.kind) {
        .range => {
            const name = source orelse return null;
            return try alloc.print("more output from {s}", .{name});
        },
        .query => {
            var query = try text_utils.encodeTerminalSafe(alloc, view.query, max_query_label_bytes);
            defer query.deinit(alloc);
            if (source) |name| return try alloc.print("{s} output for \"{s}\"", .{ name, query.bytes });
            return try alloc.print("{s} for \"{s}\"", .{
                outputNoun(view.handle, "command output", "saved output"),
                query.bytes,
            });
        },
        // `requestView` admits only a record ID: one letter, then digits.
        .record => return try alloc.print("earlier {s} {c}{s}", .{
            recordNoun(view.handle[0]),
            std.ascii.toUpper(view.handle[0]),
            view.handle[1..],
        }),
        .images, .history_search => return null,
    }
}

fn expectPresentation(arguments_json: []const u8, action_label: []const u8, completed_action_label: []const u8, label_arg_default: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, arguments_json, .{});
    defer parsed.deinit();
    const resolved = presentation(parsed.value.object) orelse return error.TestExpectedPresentation;
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.none, resolved.label_arg_kind);
    try std.testing.expectEqualStrings(action_label, resolved.action_label);
    try std.testing.expectEqualStrings(completed_action_label, resolved.completed_action_label);
    try std.testing.expectEqualStrings(label_arg_default, resolved.label_arg_default);
}

fn expectDisplayTarget(arguments_json: []const u8, source: ?[]const u8, expected: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    const target = try displayTarget(alloc, arguments_json, source);
    defer if (target) |value| alloc.free(value);
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, target orelse return error.TestExpectedDisplayTarget);
    } else {
        try std.testing.expect(target == null);
    }
}

test "read_tool_result rows name what each request reads" {
    const replay = "fx-command-replay-0123.bin";
    try expectPresentation("{\"request\":{\"handle\":\"" ++ replay ++ "\"}}", "Reading", "Read", "more command output");
    try expectPresentation("{\"handle\":\"result-x.txt\",\"start_byte\":9}", "Reading", "Read", "more output");
    try expectPresentation("{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}", "Searching", "Searched", "command output");
    try expectPresentation("{\"handle\":\"result-x\",\"query\":\"error:\"}", "Searching", "Searched", "saved output");
    // An empty query reads a range, as `decode` treats it.
    try expectPresentation("{\"handle\":\"result-x\",\"query\":\"\"}", "Reading", "Read", "more output");
    try expectPresentation("{\"request\":{\"handle\":\"image-result-abc\"}}", "Reloading", "Reloaded", "saved images");
    try expectPresentation("{\"request\":{\"handle\":\" t5 \"}}", "Opening", "Opened", "earlier conversation");
    try expectPresentation("{\"request\":{\"search\":[\"retry budget\"]}}", "Searching", "Searched", "earlier conversation");

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"request\":\"handle\"}", .{});
    defer parsed.deinit();
    try std.testing.expect(presentation(parsed.value.object) == null);
}

test "read_tool_result display targets name the source, query, and record" {
    const replay = "fx-command-replay-0123.bin";
    try expectDisplayTarget("{\"request\":{\"handle\":\"" ++ replay ++ "\"}}", "zig build test", "more output from zig build test");
    try expectDisplayTarget("{\"request\":{\"handle\":\"" ++ replay ++ "\"}}", null, null);
    try expectDisplayTarget(
        "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}",
        "zig build test",
        "zig build test output for \"error:\"",
    );
    try expectDisplayTarget("{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}", null, "command output for \"error:\"");
    try expectDisplayTarget("{\"handle\":\"result-x\",\"query\":\"needle\"}", null, "saved output for \"needle\"");
    try expectDisplayTarget("{\"request\":{\"handle\":\"t5\"}}", "ignored", "earlier tool call T5");
    try expectDisplayTarget("{\"request\":{\"handle\":\"M12\"}}", null, "earlier turn M12");
    try expectDisplayTarget("{\"request\":{\"handle\":\"l2\"}}", null, "earlier compaction L2");
    try expectDisplayTarget("{\"request\":{\"handle\":\"image-result-abc\"}}", "vision", null);
    try expectDisplayTarget("{\"request\":{\"search\":\"retry\"}}", null, null);
    try expectDisplayTarget("not json", "zig build test", null);
}

test "read_tool_result display targets keep search text terminal-safe and short" {
    const alloc = std.testing.allocator;
    const target = (try displayTarget(alloc, "{\"handle\":\"result-x\",\"query\":\"\\u001b[31mred" ++ text_utils.repeat("x", 120) ++ "\"}", null)).?;
    defer alloc.free(target);
    try std.testing.expect(std.mem.findScalar(u8, target, 0x1b) == null);
    try std.testing.expect(target.len < "saved output for \"\"".len + max_query_label_bytes + 1);
}

test "read_tool_result requested handles match what validate opens" {
    const alloc = std.testing.allocator;
    const restored = (try requestedHandle(alloc, "{\"request\":{\"handle\":\" result-shell-abc \"}}")).?;
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("result-shell-abc.txt", restored);
    const replay = (try requestedHandle(alloc, "{\"handle\":\"fx-command-replay-0123.bin\",\"query\":\"x\"}")).?;
    defer alloc.free(replay);
    try std.testing.expectEqualStrings("fx-command-replay-0123.bin", replay);
    try std.testing.expect(try requestedHandle(alloc, "{\"request\":{\"handle\":\"T5\"}}") == null);
    try std.testing.expect(try requestedHandle(alloc, "{\"request\":{\"search\":[\"x\"]}}") == null);
    try std.testing.expect(try requestedHandle(alloc, "[]") == null);
}

test "read_tool_result rows read a request sent as JSON text like its object form" {
    const replay = "fx-command-replay-0123.bin";
    try expectPresentation("{\"request\":\"{\\\"search\\\":[\\\"retry budget\\\"]}\"}", "Searching", "Searched", "earlier conversation");
    try expectPresentation("{\"request\":\"{\\\"handle\\\":\\\"" ++ replay ++ "\\\"}\"}", "Reading", "Read", "more command output");
    try expectPresentation("{\"request\":\"{\\\"handle\\\":\\\"result-x\\\",\\\"query\\\":\\\"error:\\\"}\"}", "Searching", "Searched", "saved output");
    try expectPresentation("{\"request\":\"{\\\"handle\\\":\\\" t5 \\\"}\"}", "Opening", "Opened", "earlier conversation");
    try expectPresentation("{\"request\":\"{\\\"handle\\\":\\\"image-result-abc\\\"}\"}", "Reloading", "Reloaded", "saved images");
}

/// The arguments of a handle call whose request is JSON text that nests
/// `levels` levels deep: the call's object, and `levels - 1` arrays in `pad`.
fn textNestedRequest(alloc: Allocator, levels: usize) ![]u8 {
    const open = try alloc.alloc(u8, levels - 1);
    defer alloc.free(open);
    @memset(open, '[');
    const close = try alloc.alloc(u8, levels - 1);
    defer alloc.free(close);
    @memset(close, ']');
    return try alloc.print("{{\"request\":\"{{\\\"handle\\\":\\\"result-x\\\",\\\"pad\\\":{s}{s}}}\"}}", .{ open, close });
}

/// The arguments of a handle search whose request is JSON text with a query
/// of `query_bytes` bytes.
fn textQueryRequest(alloc: Allocator, query_bytes: usize) ![]u8 {
    const query = try alloc.alloc(u8, query_bytes);
    defer alloc.free(query);
    @memset(query, 'x');
    return try alloc.print("{{\"request\":\"{{\\\"handle\\\":\\\"result-x\\\",\\\"query\\\":\\\"{s}\\\"}}\"}}", .{query});
}

/// The arguments of a history search for `phrases` short phrases, whose
/// request is the search's JSON text when `as_text` is set and its object
/// otherwise.
fn searchRequest(alloc: Allocator, phrases: usize, as_text: bool) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    for (0..phrases) |index| {
        const phrase = try alloc.print("{s}\"phrase {d:0>2}\"", .{ if (index == 0) "" else ",", index });
        defer alloc.free(phrase);
        try list.appendSlice(alloc, phrase);
    }
    const search = try alloc.print("{{\"search\":[{s}]}}", .{list.items});
    defer alloc.free(search);
    if (!as_text) return try alloc.print("{{\"request\":{s}}}", .{search});
    const quoted = try std.json.Stringify.valueAlloc(alloc, search, .{});
    defer alloc.free(quoted);
    return try alloc.print("{{\"request\":{s}}}", .{quoted});
}

test "read_tool_result rows keep the generic row for JSON text that does not fit the 4 KiB buffer" {
    const alloc = std.testing.allocator;

    // Text that decodes in the buffer is read, and text that does not leaves
    // the row as the generic one, as for any request the row cannot read.
    const inside = try textQueryRequest(alloc, 1500);
    defer alloc.free(inside);
    try expectPresentation(inside, "Searching", "Searched", "saved output");
    const outside = try textQueryRequest(alloc, 5000);
    defer alloc.free(outside);
    var parsed_outside = try std.json.parseFromSlice(std.json.Value, alloc, outside, .{});
    defer parsed_outside.deinit();
    try std.testing.expect(presentation(parsed_outside.value.object) == null);
}

test "read_tool_result rows keep the generic row for a search list whose decoded form does not fit the buffer" {
    const alloc = std.testing.allocator;

    // 30 short phrases are under 2 KiB of text, yet the list does not fit the
    // buffer once decoded: the decoded form decides the row, not the text's size.
    const long_text = try searchRequest(alloc, 30, true);
    defer alloc.free(long_text);
    try std.testing.expect(long_text.len < 2048);
    var parsed_long = try std.json.parseFromSlice(std.json.Value, alloc, long_text, .{});
    defer parsed_long.deinit();
    try std.testing.expect(presentation(parsed_long.value.object) == null);

    // The same search as an object has no text to decode, and a short list as
    // text fits, so the buffer is the only reason the long one falls back.
    const as_object = try searchRequest(alloc, 30, false);
    defer alloc.free(as_object);
    try expectPresentation(as_object, "Searching", "Searched", "earlier conversation");
    const short_text = try searchRequest(alloc, 3, true);
    defer alloc.free(short_text);
    try expectPresentation(short_text, "Searching", "Searched", "earlier conversation");
}

test "read_tool_result handles read JSON text nested up to 64 levels and no deeper" {
    const alloc = std.testing.allocator;

    const at_limit = try textNestedRequest(alloc, 64);
    defer alloc.free(at_limit);
    const handle = (try requestedHandle(alloc, at_limit)) orelse return error.TestExpectedHandle;
    defer alloc.free(handle);
    try std.testing.expectEqualStrings("result-x.txt", handle);

    // One level more is not read, like any other text the tool does not read.
    const past_limit = try textNestedRequest(alloc, 65);
    defer alloc.free(past_limit);
    try std.testing.expect(try requestedHandle(alloc, past_limit) == null);
    try std.testing.expect(try displayTarget(alloc, past_limit, null) == null);

    // The row's own decode leaves the same text as the generic row.
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, past_limit, .{});
    defer parsed.deinit();
    try std.testing.expect(presentation(parsed.value.object) == null);
}

test "read_tool_result handles and display targets read JSON text of any size within the bound" {
    const alloc = std.testing.allocator;
    const handle = (try requestedHandle(alloc, "{\"request\":\"{\\\"handle\\\":\\\" result-shell-abc \\\"}\"}")) orelse
        return error.TestExpectedHandle;
    defer alloc.free(handle);
    try std.testing.expectEqualStrings("result-shell-abc.txt", handle);
    try std.testing.expect(try requestedHandle(alloc, "{\"request\":\"{\\\"search\\\":[\\\"x\\\"]}\"}") == null);

    try expectDisplayTarget("{\"request\":\"{\\\"handle\\\":\\\"result-x\\\",\\\"query\\\":\\\"needle\\\"}\"}", null, "saved output for \"needle\"");
    // Past the 4 KiB the row's own decode allows, these have a heap to read in.
    const large = try textQueryRequest(alloc, 10_000);
    defer alloc.free(large);
    const target = (try displayTarget(alloc, large, null)) orelse return error.TestExpectedDisplayTarget;
    defer alloc.free(target);
    try std.testing.expect(std.mem.startsWith(u8, target, "saved output for \"xxxx"));
    const large_handle = (try requestedHandle(alloc, large)) orelse return error.TestExpectedHandle;
    defer alloc.free(large_handle);
    try std.testing.expectEqualStrings("result-x.txt", large_handle);
}

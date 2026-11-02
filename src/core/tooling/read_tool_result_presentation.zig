const std = @import("std");
const result_store = @import("../session/result_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const compactor = @import("../compactor/compactor.zig");
const text_utils = @import("../shared/text_utils.zig");
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

fn requestView(args: std.json.ObjectMap) ?RequestView {
    const object = if (args.get("request")) |request| switch (request) {
        .object => |value| value,
        else => return null,
    } else args;
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

/// Labels a call by what it reads instead of one shared "tool result" label.
/// The resolved row text from `displayTarget` replaces the default object.
pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const view = requestView(args) orelse return null;
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
    const view = requestView(parsed.value.object) orelse return null;
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
    const view = requestView(parsed.value.object) orelse return null;
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

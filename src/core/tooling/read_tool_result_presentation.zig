const std = @import("std");
const result_store = @import("../session/result_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const compactor = @import("../compactor/compactor.zig");
const json_depth = @import("../shared/json_depth.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");

const Allocator = std.mem.Allocator;

/// Longest search text a row repeats, after terminal-safe encoding.
const max_query_label_bytes = 60;

/// Room for a handle that a `request` written as JSON text spells with
/// escapes, which `presentation` decodes on the stack. A handle written with
/// escapes that decodes to more keeps the tool's default label. No handle comes
/// near it: a replay handle is at most 128 bytes and a record ID is a letter
/// and a number. A handle without escapes is read in the text, whatever its
/// length.
pub const max_escaped_handle_bytes = 1024;

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

fn requestView(alloc: Allocator, args: std.json.ObjectMap) Allocator.Error!?RequestView {
    const object = (try tool_args.unwrapRequest(alloc, args)) orelse return null;
    if (object.get("search") != null) return .{ .kind = .history_search };
    const handle = switch (object.get("handle") orelse return null) {
        .string => |value| std.mem.trim(u8, value, " \t\r\n"),
        else => return null,
    };
    if (handle.len == 0) return null;
    const query = if (object.get("query")) |value| (if (value == .string) value.string else "") else "";
    const kind = handleKind(handle, query.len > 0);
    return .{ .kind = kind, .handle = handle, .query = if (kind == .query) query else "" };
}

/// What a call with this handle asks for: a saved record, saved images, a
/// search of the output, or a range of it. `has_query` is whether `query` is a
/// string that is not empty.
fn handleKind(handle: []const u8, has_query: bool) RequestView.Kind {
    var record_buffer: compactor.RecordFileBuffer = undefined;
    if (compactor.recordFile(&record_buffer, handle) != null) return .record;
    if (result_store.isImageHandle(handle)) return .images;
    return if (has_query) .query else .range;
}

/// What the row needs from a request: its kind and handle, without any text
/// that a label repeats.
const PresentedRequest = struct {
    kind: RequestView.Kind,
    handle: []const u8,
};

/// The fields of a request written as JSON text that choose its row's label.
const TextFields = struct {
    /// `search` is there, whatever its value.
    search: bool = false,
    /// `handle` is there: a string that decodes to no more than the buffer
    /// holds is in `handle`, anything else leaves it null.
    has_handle: bool = false,
    handle: ?[]const u8 = null,
    /// `query` is there: `query_text` is whether it is a string that is not
    /// empty.
    has_query: bool = false,
    query_text: bool = false,
};

/// The request `request_text` holds, read the way `tool_args.unwrapRequest`
/// and `requestView` read it, but in place, so the row's label does not depend
/// on how long the text is. The hook has no allocator, and the stack buffer
/// that once held a parse of the text (4096 bytes, which a parse of a two-field
/// request outgrew at about 2.2 KB) gave a long text the default label.
///
/// - Nothing is allocated. The scan reads `search`, `handle` and `query` at the
///   top of the text and skips every other value with `std.json.Scanner`.
/// - Its work is linear in the text and its memory is fixed: the scanner's
///   nesting list and, for a handle written with escapes, `handle_buffer`. A
///   handle without escapes is a slice of the text. One written with escapes
///   that decodes to more than `max_escaped_handle_bytes` keeps the default
///   label.
/// - Text that nests deeper than tool input may (`json_depth.max_depth`, 64
///   levels, checked first), is not valid JSON, has anything after its object,
///   or is not an object names nothing.
/// - A parse refuses a text that repeats a field, at any depth, because
///   `std.json` fails on a duplicate by default. The scan sees a repeat of a
///   field it reads, and the text then names nothing. It does not see a repeat
///   of another field, since that takes memory in proportion to the number of
///   fields. Such a text gets the label of what it reads, though decode refuses
///   the call.
///
/// The result may point into `handle_buffer`.
fn scanRequestText(request_text: []const u8, handle_buffer: *[max_escaped_handle_bytes]u8) ?PresentedRequest {
    if (json_depth.exceeds(request_text)) return null;
    // The scanner's allocator holds one bit for each level of nesting: 8 bytes
    // for 64 levels, in a list that grows by one cache line (128 bytes on the
    // targets fx builds for) past what it needs. If a target needed more, the
    // scan would find no label, and the 64-level test would fail.
    var nesting: [512]u8 = undefined;
    var nesting_allocator = std.heap.FixedBufferAllocator.init(&nesting);
    var scanner = std.json.Scanner.initCompleteInput(nesting_allocator.allocator(), request_text);
    defer scanner.deinit();
    const fields = scanFields(&scanner, handle_buffer) catch return null;
    if (fields.search) return .{ .kind = .history_search, .handle = "" };
    const handle = std.mem.trim(u8, fields.handle orelse return null, " \t\r\n");
    if (handle.len == 0) return null;
    return .{ .kind = handleKind(handle, fields.query_text), .handle = handle };
}

/// The longest name of a field the row reads.
const longest_field_name = "handle".len;

/// The fields the row reads in the object the scanner is at the start of, read
/// to the end of the text. Any error means the text names nothing, including
/// `error.DuplicateField` for a repeat of a field it reads.
fn scanFields(scanner: *std.json.Scanner, handle_buffer: []u8) !TextFields {
    switch (try scanner.next()) {
        .object_begin => {},
        else => return error.NotObject,
    }
    var fields: TextFields = .{};
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .object_end => {
                _ = try scanner.next();
                break;
            },
            .string => {},
            else => return error.SyntaxError,
        }
        var name_buffer: [longest_field_name]u8 = undefined;
        const name = try readString(scanner, &name_buffer) orelse "";
        // A field that repeats makes a parse of the text fail, so the text
        // names nothing.
        if (std.mem.eql(u8, name, "search")) {
            if (fields.search) return error.DuplicateField;
            fields.search = true;
            try scanner.skipValue();
        } else if (std.mem.eql(u8, name, "handle")) {
            if (fields.has_handle) return error.DuplicateField;
            fields.has_handle = true;
            fields.handle = switch (try scanner.peekNextTokenType()) {
                .string => try readString(scanner, handle_buffer),
                else => blk: {
                    try scanner.skipValue();
                    break :blk null;
                },
            };
        } else if (std.mem.eql(u8, name, "query")) {
            if (fields.has_query) return error.DuplicateField;
            fields.has_query = true;
            fields.query_text = switch (try scanner.peekNextTokenType()) {
                .string => try stringIsNotEmpty(scanner),
                else => blk: {
                    try scanner.skipValue();
                    break :blk false;
                },
            };
        } else {
            try scanner.skipValue();
        }
    }
    // A parse of the text ends where its object ends.
    switch (try scanner.next()) {
        .end_of_document => {},
        else => return error.SyntaxError,
    }
    return fields;
}

/// The string at the scanner: its text when it has no escape, else its decoded
/// bytes in `buffer`. Null when it decodes to more than `buffer` holds. The
/// string's tokens are as `std.json.Token` describes: any number of partial
/// pieces, then the last piece as `.string`.
fn readString(scanner: *std.json.Scanner, buffer: []u8) !?[]const u8 {
    var len: usize = 0;
    var fits = true;
    var escaped = false;
    while (true) switch (try scanner.next()) {
        .string => |last| {
            if (!escaped) return last;
            appendPiece(buffer, &len, &fits, last);
            return if (fits) buffer[0..len] else null;
        },
        .partial_string => |text| {
            escaped = true;
            appendPiece(buffer, &len, &fits, text);
        },
        inline .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => |bytes| {
            escaped = true;
            appendPiece(buffer, &len, &fits, &bytes);
        },
        else => return error.SyntaxError,
    };
}

fn appendPiece(buffer: []u8, len: *usize, fits: *bool, piece: []const u8) void {
    if (!fits.* or piece.len > buffer.len - len.*) {
        fits.* = false;
        return;
    }
    @memcpy(buffer[len.*..][0..piece.len], piece);
    len.* += piece.len;
}

/// Whether the string at the scanner has any byte, which is so for any string
/// with an escape in it.
fn stringIsNotEmpty(scanner: *std.json.Scanner) !bool {
    var escaped = false;
    while (true) switch (try scanner.next()) {
        .string => |last| return escaped or last.len > 0,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => escaped = true,
        else => return error.SyntaxError,
    };
}

/// The request a call's `request` wrapper or its own arguments hold, read
/// without allocating. Text the model wrote as JSON is scanned in place.
fn presentedRequest(args: std.json.ObjectMap, handle_buffer: *[max_escaped_handle_bytes]u8) ?PresentedRequest {
    if (args.get("request")) |request| {
        if (request == .string) return scanRequestText(request.string, handle_buffer);
    }
    // An object, or the arguments themselves: nothing is read from text, so
    // nothing is allocated.
    var no_memory: [0]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    const view = (requestView(fixed.allocator(), args) catch return null) orelse return null;
    return .{ .kind = view.kind, .handle = view.handle };
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
    // The hook passes no allocator, and every label below is static text, so
    // a request written as JSON text is scanned in place.
    var handle_buffer: [max_escaped_handle_bytes]u8 = undefined;
    const request = presentedRequest(args, &handle_buffer) orelse return null;
    return switch (request.kind) {
        .range => readPresentation("Reading", "Read", outputNoun(request.handle, "more command output", "more output")),
        .query => readPresentation("Searching", "Searched", outputNoun(request.handle, "command output", "saved output")),
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

test "read_tool_result rows read a request sent as JSON text as they read an object" {
    const alloc = std.testing.allocator;
    const replay = "fx-command-replay-0123.bin";
    const query_text = "{\"request\":\"{\\\"handle\\\":\\\"" ++ replay ++ "\\\",\\\"query\\\":\\\"error:\\\"}\"}";
    try expectPresentation(query_text, "Searching", "Searched", "command output");
    try expectPresentation("{\"request\":\"{\\\"handle\\\":\\\"result-x\\\"}\"}", "Reading", "Read", "more output");
    try expectPresentation("{\"request\":\"{\\\"handle\\\":\\\" t5 \\\"}\"}", "Opening", "Opened", "earlier conversation");
    try expectPresentation("{\"request\":\"{\\\"search\\\":[\\\"retry budget\\\"]}\"}", "Searching", "Searched", "earlier conversation");
    try expectDisplayTarget(query_text, "zig build test", "zig build test output for \"error:\"");
    try expectDisplayTarget("{\"request\":\"{\\\"handle\\\":\\\"t5\\\"}\"}", null, "earlier tool call T5");
    const restored = (try requestedHandle(alloc, "{\"request\":\"{\\\"handle\\\":\\\" result-shell-abc \\\"}\"}")).?;
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("result-shell-abc.txt", restored);

    // Text that is not one object names nothing, as decode refuses it.
    for ([_][]const u8{
        "{\"request\":\"[1]\"}",
        "{\"request\":\"null\"}",
        "{\"request\":\"\"}",
        "{\"request\":\"\\\"{\\\\\\\"handle\\\\\\\":\\\\\\\"h\\\\\\\"}\\\"\"}",
    }) |arguments_json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{});
        defer parsed.deinit();
        try std.testing.expect(presentation(parsed.value.object) == null);
        try std.testing.expect(try requestedHandle(alloc, arguments_json) == null);
        try expectDisplayTarget(arguments_json, "zig build test", null);
    }
}

fn filled(arena: Allocator, size: usize) ![]u8 {
    const text = try arena.alloc(u8, size);
    @memset(text, 'q');
    return text;
}

fn repeated(arena: Allocator, piece: []const u8, count: usize) ![]u8 {
    const text = try arena.alloc(u8, piece.len * count);
    for (0..count) |index| @memcpy(text[index * piece.len ..][0..piece.len], piece);
    return text;
}

fn expectSamePresentation(expected: ?tool_dispatch.CallPresentation, actual: ?tool_dispatch.CallPresentation) !void {
    const want = expected orelse return try std.testing.expect(actual == null);
    const got = actual orelse return error.TestExpectedPresentation;
    try std.testing.expectEqual(want.activity_kind, got.activity_kind);
    try std.testing.expectEqualStrings(want.action_label, got.action_label);
    try std.testing.expectEqualStrings(want.completed_action_label, got.completed_action_label);
    try std.testing.expectEqualStrings(want.label_arg_default, got.label_arg_default);
}

/// The row's label for `request_text` sent as JSON text is the label of the
/// object a full parse finds in it, or none when decode refuses the text.
fn expectTextLabelsAsObject(request_text: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args_json = try std.json.Stringify.valueAlloc(arena, .{ .request = request_text }, .{});
    const args = (try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{})).object;
    const from_text = presentation(args);
    const object = (try tool_args.unwrapRequest(arena, args)) orelse return try std.testing.expect(from_text == null);
    const object_json = try std.json.Stringify.valueAlloc(arena, .{ .request = std.json.Value{ .object = object } }, .{});
    const object_args = (try std.json.parseFromSliceLeaky(std.json.Value, arena, object_json, .{})).object;
    try expectSamePresentation(presentation(object_args), from_text);
}

test "read_tool_result rows name what a request text longer than 4 KiB reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A query as long as a model can make it, and for every other kind of
    // call a field that no row reads, so the text is as long.
    for ([_]usize{ 3000, 4000, 4096, 4200, 64 * 1024, 1024 * 1024 }) |size| {
        const padding = try filled(arena, size);
        const cases = [_]struct { request: []const u8, action: []const u8, completed: []const u8, noun: []const u8 }{
            .{
                .request = try std.json.Stringify.valueAlloc(arena, .{ .handle = "fx-command-replay-0123.bin", .query = padding }, .{}),
                .action = "Searching",
                .completed = "Searched",
                .noun = "command output",
            },
            .{
                .request = try std.json.Stringify.valueAlloc(arena, .{ .handle = "result-x", .query = padding }, .{}),
                .action = "Searching",
                .completed = "Searched",
                .noun = "saved output",
            },
            .{
                .request = try std.json.Stringify.valueAlloc(arena, .{ .handle = "result-x", .start_byte = 9, .note = padding }, .{}),
                .action = "Reading",
                .completed = "Read",
                .noun = "more output",
            },
            .{
                .request = try std.json.Stringify.valueAlloc(arena, .{ .handle = "t5", .note = padding }, .{}),
                .action = "Opening",
                .completed = "Opened",
                .noun = "earlier conversation",
            },
            .{
                .request = try std.json.Stringify.valueAlloc(arena, .{ .handle = "image-result-abc", .note = padding }, .{}),
                .action = "Reloading",
                .completed = "Reloaded",
                .noun = "saved images",
            },
            .{
                .request = try std.json.Stringify.valueAlloc(arena, .{ .search = [_][]const u8{ "retry budget", padding } }, .{}),
                .action = "Searching",
                .completed = "Searched",
                .noun = "earlier conversation",
            },
        };
        for (cases) |case| {
            const arguments_json = try std.json.Stringify.valueAlloc(arena, .{ .request = case.request }, .{});
            try expectPresentation(arguments_json, case.action, case.completed, case.noun);
            // The row text and the source link read the same text.
            const restored = try requestedHandle(std.testing.allocator, arguments_json);
            defer if (restored) |handle| std.testing.allocator.free(handle);
            try std.testing.expect((restored != null) == !std.mem.startsWith(u8, case.noun, "earlier"));
        }
    }
}

test "read_tool_result rows read a request text as the full parse reads it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const padding = try filled(arena, 5000);
    const bracket_levels_63 = text_utils.repeat("[", 63) ++ text_utils.repeat("]", 63);
    const bracket_levels_64 = text_utils.repeat("[", 64) ++ text_utils.repeat("]", 64);
    var many_keys: std.Io.Writer.Allocating = .init(arena);
    try many_keys.writer.writeByte('{');
    for (0..3000) |index| try many_keys.writer.print("\"key{d}\":{d},", .{ index, index });
    try many_keys.writer.writeAll("\"handle\":\"t5\"}");

    const texts = [_][]const u8{
        // Text that is not one object, short and long.
        "",
        "   ",
        "7",
        "null",
        "true",
        "[1]",
        "\"{}\"",
        "{",
        "}",
        "{}",
        "{\"handle\"",
        "{\"handle\":",
        try arena.print("[{s}1]", .{try repeated(arena, "1,", 3000)}),
        try arena.print("\"{s}\"", .{padding}),
        // Text after the object, a syntax error after the fields, and escapes that are not valid.
        "{\"handle\":\"t5\"} x",
        "{\"handle\":\"t5\"}{}",
        "{\"handle\":\"t5\",}",
        "{\"handle\":\"t5\"\"x\":1}",
        "{\"handle\":\"t5\",\"x\":\"\\q\"}",
        "{\"handle\":\"t5\",\"x\":\"\\ud800\"}",
        "{\"handle\":\"t5\",\"x\":\"\\ud800\\u0041\"}",
        try arena.print("{{\"handle\":\"t5\",\"pad\":\"{s}\"}} {{}}", .{padding}),
        try arena.print("{{\"handle\":\"t5\",\"pad\":\"{s}", .{padding}),
        try arena.print("{{\"handle\":\"t5\",\"pad\":[{s}1,]}}", .{try repeated(arena, "1,", 2000)}),
        try arena.print("{{\"handle\":\"t5\",\"pad\":\"{s}\\ud800\"}}", .{padding}),
        // Nesting: 64 levels are read, 65 are refused, whatever the length.
        "{\"handle\":\"result-x\",\"deep\":" ++ bracket_levels_63 ++ "}",
        "{\"handle\":\"result-x\",\"deep\":" ++ bracket_levels_64 ++ "}",
        try arena.print("{{\"pad\":\"{s}\",\"handle\":\"result-x\",\"deep\":{s}}}", .{ padding, bracket_levels_63 }),
        try arena.print("{{\"pad\":\"{s}\",\"handle\":\"result-x\",\"deep\":{s}}}", .{ padding, bracket_levels_64 }),
        // A field the row reads that repeats is refused, as a parse refuses it, and a key or a handle written with escapes is decoded.
        "{\"handle\":\"result-x\",\"handle\":\"t5\"}",
        "{\"handle\":\"t5\",\"handle\":\"result-x\"}",
        "{\"handle\":\"t5\",\"handle\":7}",
        "{\"handle\":7,\"handle\":\"t5\"}",
        "{\"handle\":\"result-x\",\"query\":\"a\",\"query\":\"\"}",
        "{\"handle\":\"result-x\",\"query\":\"\",\"query\":\"a\"}",
        "{\"handle\":\"result-x\",\"query\":\"a\",\"query\":7}",
        "{\"search\":[\"a\"],\"search\":[\"b\"]}",
        "{\"h\\u0061ndle\":\"result-x\",\"qu\\u0065ry\":\"e\"}",
        "{\"s\\u0065arch\":[\"x\"]}",
        "{\"handle\":\"result-\\u0078\"}",
        "{\"handle\":\"fx-command-replay-\\u0030.bin\"}",
        "{\"handle\":\"image-result-\\ud83d\\ude00\"}",
        "{\"handle\":\" \\tt5\\n\"}",
        "{\"handle\":\"r\\u00e9sum\\u00e9\"}",
        // What the row reads: search first, a handle that is a string and not blank, a query that is a non-empty string.
        "{\"search\":null}",
        "{\"handle\":7,\"search\":[]}",
        "{\"handle\":\"result-x\",\"search\":\"x\"}",
        "{\"handle\":7}",
        "{\"handle\":\"\"}",
        "{\"handle\":\" \\t\\r\\n\"}",
        "{\"handle\":null}",
        "{\"handle\":\"result-x\",\"query\":\"\"}",
        "{\"handle\":\"result-x\",\"query\":\"\\u0041\"}",
        "{\"handle\":\"result-x\",\"query\":\"\\n\"}",
        "{\"handle\":\"result-x\",\"query\":null}",
        "{\"handle\":\"result-x\",\"query\":[\"a\"]}",
        "{\"query\":\"a\"}",
        // Long values nothing reads, quotes and brackets inside strings, many keys, and plenty of white space.
        try arena.print("{{\"note\":\"}}]{{[\\\"\\\\\",\"handle\":\"t5\",\"pad\":\"{s}\"}}", .{padding}),
        try arena.print("{{\"pad\":{{\"a\":[{{\"b\":\"{s}\"}}]}},\"handle\":\"result-x\",\"query\":\"{s}\"}}", .{ padding, padding }),
        many_keys.written(),
        try arena.print("{s}{{\"handle\":\"t5\"}}{s}", .{ try repeated(arena, " \n\t\r", 1500), try repeated(arena, " \n\t\r", 1500) }),
        try arena.print("{{\"handle\":\"{s}\"}}", .{padding}),
        try arena.print("{{\"handle\":\"image-result-{s}\"}}", .{padding}),
    };
    for (texts, 0..) |text, index| expectTextLabelsAsObject(text) catch |err| {
        std.debug.print("request text {d} ({d} bytes) is read differently: {s}\n", .{ index, text.len, text[0..@min(text.len, 100)] });
        return err;
    };

    // Some of those, read to the end, name what they read.
    const query_args = try std.json.Stringify.valueAlloc(arena, .{ .request = try arena.print("{{\"pad\":\"{s}\",\"handle\":\"result-x\",\"query\":\"e\"}}", .{padding}) }, .{});
    try expectPresentation(query_args, "Searching", "Searched", "saved output");
    // A query counts when it holds any byte, written with an escape or not, and not when it is empty.
    for ([_]struct { query: []const u8, searching: bool }{
        .{ .query = "\"\"", .searching = false },
        .{ .query = "\"a\"", .searching = true },
        .{ .query = "\"\\u0041\"", .searching = true },
        .{ .query = "\"\\n\"", .searching = true },
    }) |case| {
        const request = try arena.print("{{\"handle\":\"result-x\",\"query\":{s}}}", .{case.query});
        const arguments_json = try std.json.Stringify.valueAlloc(arena, .{ .request = request }, .{});
        if (case.searching) {
            try expectPresentation(arguments_json, "Searching", "Searched", "saved output");
        } else {
            try expectPresentation(arguments_json, "Reading", "Read", "more output");
        }
    }
    const deep_args = try std.json.Stringify.valueAlloc(arena, .{ .request = "{\"handle\":\"result-x\",\"deep\":" ++ bracket_levels_63 ++ "}" }, .{});
    try expectPresentation(deep_args, "Reading", "Read", "more output");
    const too_deep_args = try std.json.Stringify.valueAlloc(arena, .{ .request = "{\"handle\":\"result-x\",\"deep\":" ++ bracket_levels_64 ++ "}" }, .{});
    var too_deep = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, too_deep_args, .{});
    defer too_deep.deinit();
    try std.testing.expect(presentation(too_deep.value.object) == null);
}

test "read_tool_result rows name a text that repeats a field they do not read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A parse of these texts fails on the repeat, so decode refuses the call.
    // The row keeps no memory for fields it does not read, so it names what the
    // call reads: this is the one way it reads a text differently.
    for ([_][]const u8{
        "{\"handle\":\"t5\",\"x\":1,\"x\":2}",
        "{\"handle\":\"t5\",\"x\":{\"a\":1,\"a\":2}}",
    }) |text| {
        const arguments_json = try std.json.Stringify.valueAlloc(arena, .{ .request = text }, .{});
        try expectPresentation(arguments_json, "Opening", "Opened", "earlier conversation");
        const args = (try std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{})).object;
        try std.testing.expect(try tool_args.unwrapRequest(arena, args) == null);
    }
}

test "read_tool_result rows keep the default label for a handle with escapes past its room" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix_len = "result-".len;
    // Each escape decodes to one byte, so the handle decodes to exactly `length`.
    for ([_]usize{ max_escaped_handle_bytes - 1, max_escaped_handle_bytes, max_escaped_handle_bytes + 1, 4 * max_escaped_handle_bytes }) |length| {
        const text = try arena.print("{{\"handle\":\"result-{s}\"}}", .{try repeated(arena, "\\u0078", length - prefix_len)});
        const arguments_json = try std.json.Stringify.valueAlloc(arena, .{ .request = text }, .{});
        if (length <= max_escaped_handle_bytes) {
            try expectPresentation(arguments_json, "Reading", "Read", "more output");
        } else {
            const args = (try std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{})).object;
            try std.testing.expect(presentation(args) == null);
        }
    }
    // A handle without escapes is read in the text, however long it is.
    const plain = try arena.print("{{\"handle\":\"result-{s}\"}}", .{try filled(arena, 8 * max_escaped_handle_bytes)});
    try expectPresentation(try std.json.Stringify.valueAlloc(arena, .{ .request = plain }, .{}), "Reading", "Read", "more output");
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

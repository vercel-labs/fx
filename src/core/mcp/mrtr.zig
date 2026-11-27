//! Multi Round-Trip Requests (MRTR): reading the input requests of a 2026 round
//! for the question UI. The engine (`src/mcp/protocol/mrtr.zig`) is the one
//! reader of the round: it splits it into keys, requests and state. Here each
//! request's form is read from the slices it found, and the key stays the raw
//! JSON string token the server wrote, so the answer goes back under it as it
//! came.

const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const elicitation = @import("elicitation.zig");
const json_decode = @import("../shared/json_decode.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_requests: usize = 32,
    max_name_bytes: usize = 256,
    max_json_bytes: usize = 128 * 1024,
    max_string_bytes: usize = 64 * 1024,
    max_collection_items: usize = 256,
    max_depth: usize = 32,
};

pub const Error = error{
    InvalidInputRequired,
    InvalidInputResponses,
    UnsupportedInputRequest,
    MetadataLimitExceeded,
} || Allocator.Error || std.Io.Writer.Error;

const UnsupportedMethod = enum { sampling, roots };
const ElicitationRequest = elicitation.Request;

const RequestPayload = union(enum) {
    unsupported: UnsupportedMethod,
    elicitation_create: ElicitationRequest,

    fn deinit(self: *RequestPayload, alloc: Allocator) void {
        switch (self.*) {
            .unsupported => {},
            .elicitation_create => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }

    pub fn method(self: RequestPayload) []const u8 {
        return switch (self) {
            .unsupported => |method_name| switch (method_name) {
                .sampling => "sampling/createMessage",
                .roots => "roots/list",
            },
            .elicitation_create => "elicitation/create",
        };
    }
};

pub const InputRequest = struct {
    /// A JSON string token, as the answer writes it.
    key: []u8,
    payload: RequestPayload,

    pub fn deinit(self: *InputRequest, alloc: Allocator) void {
        alloc.free(self.key);
        self.payload.deinit(alloc);
        self.* = undefined;
    }
};

/// One input request of a round as the engine read it, slices of the server's
/// own bytes that the caller keeps valid. `key` is a JSON string token, quotes
/// and escapes as written. `raw` is the request object and `params` its
/// `params`, null when it has none.
pub const RawRequest = struct {
    pub const Kind = enum { elicitation, sampling, roots };

    key: []const u8,
    kind: Kind,
    raw: []const u8,
    params: ?[]const u8,
};

/// The requests of a question: `raw` when the engine's round gave them, else
/// `json`, the text form a 2025 question and a test give.
pub fn readRequests(
    alloc: Allocator,
    raw: []const RawRequest,
    json: []const u8,
    wire: elicitation.Wire,
    limits: Limits,
) Error![]InputRequest {
    if (raw.len == 0) return parseRequestJsonForWire(alloc, json, wire, limits);
    return readRawRequests(alloc, raw, wire, limits);
}

/// Reads the form of each request in `raw`. The round gets the answer the text form gets: the size limit is on the
/// round as that form writes it, `{key:request,...}`, and every request is checked against `validateJsonBounds`'s
/// bounds by `scanRequestBounds`, which reads its text once and builds no tree, before any request's form is read.
fn readRawRequests(
    alloc: Allocator,
    raw: []const RawRequest,
    wire: elicitation.Wire,
    limits: Limits,
) Error![]InputRequest {
    var bytes: usize = 2 + raw.len - 1;
    for (raw) |request| bytes += request.key.len + 1 + request.raw.len;
    if (bytes > limits.max_json_bytes) return error.MetadataLimitExceeded;
    var exceeded = false;
    for (raw) |request| {
        if (try keyLength(alloc, request.key) > limits.max_name_bytes) exceeded = true;
        if (try scanRequestBounds(alloc, request.raw, limits)) exceeded = true;
    }
    if (exceeded) return error.MetadataLimitExceeded;
    if (raw.len > limits.max_requests) return error.InvalidInputRequired;

    const requests = try alloc.alloc(InputRequest, raw.len);
    var parsed_count: usize = 0;
    errdefer {
        for (requests[0..parsed_count]) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    for (raw) |request| {
        if (try keyLength(alloc, request.key) == 0) return error.InvalidInputRequired;
        const key = try alloc.dupe(u8, request.key);
        errdefer alloc.free(key);
        const payload: RequestPayload = switch (request.kind) {
            .sampling => .{ .unsupported = .sampling },
            .roots => .{ .unsupported = .roots },
            .elicitation => try parseElicitationParams(alloc, request.params orelse return error.InvalidInputRequired, wire, limits),
        };
        requests[parsed_count] = .{ .key = key, .payload = payload };
        parsed_count += 1;
    }
    return requests;
}

/// The bytes of the name a key token spells once decoded. The token is only decoded to be measured.
fn keyLength(alloc: Allocator, token: []const u8) Error!usize {
    var scratch: std.heap.ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const name = json_decode.parseFromSliceLeaky([]const u8, scratch.allocator(), token, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInputRequired,
    };
    return name.len;
}

const BoundsFrame = struct {
    object: bool,
    members: usize = 0,
    expect_key: bool = true,
    names: std.StringHashMapUnmanaged(void) = .empty,
};

/// Whether the JSON text of one request goes past a bound of `validateJsonBounds`, read as the tree
/// `parseRequestJsonForWire` builds from it: a value deeper than `max_depth` (the request is level 1), a string or
/// a number of more than `max_string_bytes`, a name of more than `max_name_bytes`, or an array or object of more
/// than `max_collection_items`. Text that is no JSON, or an object that repeats a name, is `InvalidInputRequired`,
/// as it is when the tree is built, and it is found whatever else the text holds. One pass over the text, with
/// memory in proportion to it: no tree.
fn scanRequestBounds(alloc: Allocator, text: []const u8, limits: Limits) Error!bool {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(a, text);
    var frames: std.ArrayList(BoundsFrame) = .empty;
    var name: std.ArrayList(u8) = .empty;
    var exceeded = false;
    var scalar_bytes: usize = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInputRequired,
        };
        const naming = frames.items.len > 0 and frames.items[frames.items.len - 1].object and
            frames.items[frames.items.len - 1].expect_key;
        switch (token) {
            .end_of_document => return exceeded,
            .object_begin, .array_begin => {
                if (startValue(frames.items, limits)) exceeded = true;
                try frames.append(a, .{ .object = token == .object_begin });
            },
            .object_end, .array_end => {
                const frame = frames.pop().?;
                if (frame.members > limits.max_collection_items) exceeded = true;
                endValue(frames.items);
            },
            .partial_string => |piece| {
                scalar_bytes +|= piece.len;
                if (naming) try name.appendSlice(a, piece);
            },
            .partial_string_escaped_1 => |piece| {
                scalar_bytes +|= piece.len;
                if (naming) try name.appendSlice(a, &piece);
            },
            .partial_string_escaped_2 => |piece| {
                scalar_bytes +|= piece.len;
                if (naming) try name.appendSlice(a, &piece);
            },
            .partial_string_escaped_3 => |piece| {
                scalar_bytes +|= piece.len;
                if (naming) try name.appendSlice(a, &piece);
            },
            .partial_string_escaped_4 => |piece| {
                scalar_bytes +|= piece.len;
                if (naming) try name.appendSlice(a, &piece);
            },
            .string => |piece| {
                scalar_bytes +|= piece.len;
                if (naming) {
                    try name.appendSlice(a, piece);
                    const frame = &frames.items[frames.items.len - 1];
                    if (name.items.len > limits.max_name_bytes) exceeded = true;
                    const added = try frame.names.getOrPut(a, try a.dupe(u8, name.items));
                    if (added.found_existing) return error.InvalidInputRequired;
                    frame.members += 1;
                    frame.expect_key = false;
                    name.clearRetainingCapacity();
                } else {
                    if (startValue(frames.items, limits) or scalar_bytes > limits.max_string_bytes) exceeded = true;
                    endValue(frames.items);
                }
                scalar_bytes = 0;
            },
            .partial_number => |piece| scalar_bytes +|= piece.len,
            .number => |piece| {
                scalar_bytes +|= piece.len;
                if (startValue(frames.items, limits) or scalar_bytes > limits.max_string_bytes) exceeded = true;
                endValue(frames.items);
                scalar_bytes = 0;
            },
            .true, .false, .null => {
                if (startValue(frames.items, limits)) exceeded = true;
                endValue(frames.items);
            },
            .allocated_number, .allocated_string => return error.InvalidInputRequired,
        }
    }
}

/// A value starts inside `frames`: whether it is deeper than `max_depth`, and one more item of an array.
fn startValue(frames: []BoundsFrame, limits: Limits) bool {
    if (frames.len > 0 and !frames[frames.len - 1].object) frames[frames.len - 1].members += 1;
    return frames.len + 1 > limits.max_depth;
}

/// A value inside `frames` is over: an object then waits for its next name.
fn endValue(frames: []BoundsFrame) void {
    if (frames.len > 0 and frames[frames.len - 1].object) frames[frames.len - 1].expect_key = true;
}

pub fn parseRequestJsonForWire(
    alloc: Allocator,
    input_requests_json: []const u8,
    wire: elicitation.Wire,
    limits: Limits,
) Error![]InputRequest {
    if (input_requests_json.len > limits.max_json_bytes) return error.MetadataLimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, input_requests_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInputRequired,
    };
    defer parsed.deinit();
    try validateJsonBounds(parsed.value, limits, 0);
    return parseRequestMap(alloc, parsed.value, limits, wire);
}

fn parseRequestMap(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
    wire: elicitation.Wire,
) Error![]InputRequest {
    if (value != .object or value.object.count() > limits.max_requests) {
        return error.InvalidInputRequired;
    }
    const requests = try alloc.alloc(InputRequest, value.object.count());
    var parsed_count: usize = 0;
    errdefer {
        for (requests[0..parsed_count]) |*request| request.deinit(alloc);
        alloc.free(requests);
    }

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.len == 0 or entry.key_ptr.len > limits.max_name_bytes) {
            return error.InvalidInputRequired;
        }
        const request = entry.value_ptr.*;
        if (request != .object) return error.InvalidInputRequired;
        const method = request.object.get("method") orelse return error.InvalidInputRequired;
        if (method != .string) return error.InvalidInputRequired;

        const key = try std.json.Stringify.valueAlloc(alloc, entry.key_ptr.*, .{});
        errdefer alloc.free(key);
        const payload: RequestPayload = if (std.mem.eql(u8, method.string, "sampling/createMessage"))
            .{ .unsupported = .sampling }
        else if (std.mem.eql(u8, method.string, "roots/list"))
            .{ .unsupported = .roots }
        else if (std.mem.eql(u8, method.string, "elicitation/create"))
            try parseElicitationRequest(alloc, request, limits, wire)
        else
            return error.InvalidInputRequired;
        requests[parsed_count] = .{ .key = key, .payload = payload };
        parsed_count += 1;
    }
    return requests;
}

fn parseElicitationRequest(
    alloc: Allocator,
    request: std.json.Value,
    limits: Limits,
    wire: elicitation.Wire,
) Error!RequestPayload {
    const params = request.object.get("params") orelse return error.InvalidInputRequired;
    if (params != .object) return error.InvalidInputRequired;
    const params_json = try stringifyBounded(alloc, params, limits.max_json_bytes);
    defer alloc.free(params_json);
    return parseElicitationParams(alloc, params_json, wire, limits);
}

fn parseElicitationParams(
    alloc: Allocator,
    params_json: []const u8,
    wire: elicitation.Wire,
    limits: Limits,
) Error!RequestPayload {
    return .{ .elicitation_create = elicitation.parseRequest(
        alloc,
        wire,
        params_json,
        .{
            .max_request_bytes = limits.max_json_bytes,
            .max_response_bytes = limits.max_json_bytes,
            .max_message_bytes = limits.max_string_bytes,
            .max_schema_bytes = limits.max_json_bytes,
            .max_fields = limits.max_collection_items,
            .max_options = limits.max_collection_items,
            .max_name_bytes = limits.max_name_bytes,
            .max_label_bytes = limits.max_string_bytes,
            .max_string_bytes = limits.max_string_bytes,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return error.MetadataLimitExceeded,
        else => return error.InvalidInputRequired,
    } };
}

fn validateJsonBounds(value: std.json.Value, limits: Limits, depth: usize) Error!void {
    if (depth > limits.max_depth) return error.MetadataLimitExceeded;
    switch (value) {
        .string, .number_string => |text| {
            if (text.len > limits.max_string_bytes) return error.MetadataLimitExceeded;
        },
        .array => |array| {
            if (array.items.len > limits.max_collection_items) return error.MetadataLimitExceeded;
            for (array.items) |item| try validateJsonBounds(item, limits, depth + 1);
        },
        .object => |object| {
            if (object.count() > limits.max_collection_items) return error.MetadataLimitExceeded;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.len > limits.max_name_bytes) return error.MetadataLimitExceeded;
                try validateJsonBounds(entry.value_ptr.*, limits, depth + 1);
            }
        },
        else => {},
    }
}

fn stringifyBounded(
    alloc: Allocator,
    value: std.json.Value,
    max_bytes: usize,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch
        return error.OutOfMemory;
    if (out.written().len > max_bytes) return error.MetadataLimitExceeded;
    return try out.toOwnedSlice();
}

const form_params = "{\"message\":\"Continue?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"confirmed\":{\"type\":\"boolean\"}},\"required\":[\"confirmed\"]}}";
const form_request = "{\"method\":\"elicitation/create\",\"params\":" ++ form_params ++ "}";

fn formRaw(key: []const u8) RawRequest {
    return .{ .key = key, .kind = .elicitation, .raw = form_request, .params = form_params };
}

fn freeRequests(alloc: Allocator, requests: []InputRequest) void {
    for (requests) |*request| request.deinit(alloc);
    alloc.free(requests);
}

test "the keys of a round the engine read stay the tokens the server wrote, in order" {
    const alloc = std.testing.allocator;
    // An escape, a non-ASCII character, an astral code point as a surrogate pair, a quote, a backslash and a slash.
    const keys = [_][]const u8{
        "\"\\u0061b\"",
        "\"caf\\u00e9 \\ud83d\\ude00 é 😀\"",
        "\"q\\\"u\\\\o\\/te\"",
        "\"plain\"",
    };
    var raw: [keys.len]RawRequest = undefined;
    for (keys, &raw) |key, *request| request.* = formRaw(key);
    const requests = try readRequests(alloc, &raw, "", .modern_mcp, .{});
    defer freeRequests(alloc, requests);
    try std.testing.expectEqual(keys.len, requests.len);
    for (keys, requests) |key, request| {
        try std.testing.expectEqualStrings(key, request.key);
        try std.testing.expectEqualStrings("elicitation/create", request.payload.method());
        try std.testing.expectEqualStrings(form_params, request.payload.elicitation_create.raw_params_json);
    }
}

test "a request that is no form is kept as the kind the engine read, with its key" {
    const alloc = std.testing.allocator;
    const raw = [_]RawRequest{
        .{ .key = "\"s\\u0061mple\"", .kind = .sampling, .raw = "{\"method\":\"sampling/createMessage\",\"params\":{}}", .params = "{}" },
        .{ .key = "\"roots\"", .kind = .roots, .raw = "{\"method\":\"roots/list\"}", .params = null },
    };
    const requests = try readRequests(alloc, &raw, "", .modern_mcp, .{});
    defer freeRequests(alloc, requests);
    try std.testing.expectEqualStrings("\"s\\u0061mple\"", requests[0].key);
    try std.testing.expectEqualStrings("sampling/createMessage", requests[0].payload.method());
    try std.testing.expectEqualStrings("roots/list", requests[1].payload.method());
}

test "a round the engine read is refused when a key or a form is not one fx can show" {
    const alloc = std.testing.allocator;
    const long_key = "\"" ++ text_utils.repeat("k", 257) ++ "\"";
    const ok_key = "\"" ++ text_utils.repeat("k", 256) ++ "\"";
    try std.testing.expectError(error.MetadataLimitExceeded, readRequests(alloc, &.{formRaw(long_key)}, "", .modern_mcp, .{}));
    const kept = try readRequests(alloc, &.{formRaw(ok_key)}, "", .modern_mcp, .{});
    freeRequests(alloc, kept);
    // The name counts once decoded: 256 bytes written as escapes are 256 bytes of name, and 257 are too many.
    try std.testing.expectError(error.MetadataLimitExceeded, readRequests(alloc, &.{formRaw("\"" ++ text_utils.repeat("\\u006b", 257) ++ "\"")}, "", .modern_mcp, .{}));
    for ([_][]const u8{ "\"\"", "\"\\ud800\"", "\"\\u00\"", "k" }) |key| {
        try std.testing.expectError(error.InvalidInputRequired, readRequests(alloc, &.{formRaw(key)}, "", .modern_mcp, .{}));
    }
    const no_params: RawRequest = .{ .key = "\"k\"", .kind = .elicitation, .raw = "{\"method\":\"elicitation/create\"}", .params = null };
    try std.testing.expectError(error.InvalidInputRequired, readRequests(alloc, &.{no_params}, "", .modern_mcp, .{}));
    const not_object: RawRequest = .{ .key = "\"k\"", .kind = .elicitation, .raw = "{\"method\":\"elicitation/create\",\"params\":[]}", .params = "[]" };
    try std.testing.expectError(error.InvalidInputRequired, readRequests(alloc, &.{not_object}, "", .modern_mcp, .{}));
}

fn repeatIn(a: Allocator, piece: []const u8, count: usize) ![]u8 {
    const out = try a.alloc(u8, piece.len * count);
    for (0..count) |index| @memcpy(out[index * piece.len ..][0..piece.len], piece);
    return out;
}

fn nestedIn(a: Allocator, depth: usize) ![]u8 {
    const open = try repeatIn(a, "[", depth);
    const close = try repeatIn(a, "]", depth);
    return a.print("{s}0{s}", .{ open, close });
}

/// The answer a request gets from the text form and from the engine's slices, by the name of its error.
fn answerNames(alloc: Allocator, params_tail: []const u8, request_tail: []const u8) ![2][]const u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try a.print("{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{\"n\":{{\"type\":\"boolean\"}}}}}}{s}}}", .{params_tail});
    const request = try a.print("{{\"method\":\"elicitation/create\",\"params\":{s}{s}}}", .{ params, request_tail });
    const text = try a.print("{{\"k\":{s}}}", .{request});
    var names: [2][]const u8 = undefined;
    if (parseRequestJsonForWire(alloc, text, .modern_mcp, .{})) |requests| {
        freeRequests(alloc, requests);
        names[0] = "ok";
    } else |err| names[0] = @errorName(err);
    const raw = [_]RawRequest{.{ .key = "\"k\"", .kind = .elicitation, .raw = request, .params = params }};
    if (readRequests(alloc, &raw, "", .modern_mcp, .{})) |requests| {
        freeRequests(alloc, requests);
        names[1] = "ok";
    } else |err| names[1] = @errorName(err);
    return names;
}

fn expectAnswer(expected: []const u8, params_tail: []const u8, request_tail: []const u8) !void {
    const names = try answerNames(std.testing.allocator, params_tail, request_tail);
    try std.testing.expectEqualStrings(expected, names[0]);
    try std.testing.expectEqualStrings(expected, names[1]);
}

test "a round of the engine's slices gets the answer the text form gets at the depth bound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The round is level 0, the request 1, its params or one more member of it 2, and a member's value 3 or 2. A value
    // may sit at level 32, and nothing deeper.
    for ([_]struct { depth: usize, in_params: bool, expected: []const u8 }{
        .{ .depth = 29, .in_params = true, .expected = "ok" },
        .{ .depth = 30, .in_params = true, .expected = "MetadataLimitExceeded" },
        .{ .depth = 30, .in_params = false, .expected = "ok" },
        .{ .depth = 31, .in_params = false, .expected = "MetadataLimitExceeded" },
    }) |case| {
        const member = try a.print(",\"x\":{s}", .{try nestedIn(a, case.depth)});
        try expectAnswer(case.expected, if (case.in_params) member else "", if (case.in_params) "" else member);
    }
}

test "a round of the engine's slices gets the answer the text form gets at the string and number bound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bound = 64 * 1024;
    // A string counts the bytes it spells once decoded. A string of 64 KiB written as escapes alone is larger than the
    // round may be, so each case writes plain text first and escapes after it.
    for ([_]struct { plain: usize, piece: []const u8, count: usize, expected: []const u8 }{
        .{ .plain = bound, .piece = "", .count = 0, .expected = "ok" },
        .{ .plain = bound - 1, .piece = "s", .count = 2, .expected = "MetadataLimitExceeded" },
        .{ .plain = bound - 2000, .piece = "\\u00e9", .count = 1000, .expected = "ok" },
        .{ .plain = bound - 2000, .piece = "\\u00e9", .count = 1001, .expected = "MetadataLimitExceeded" },
        .{ .plain = bound - 2000, .piece = "\\n", .count = 2000, .expected = "ok" },
        .{ .plain = bound - 2000, .piece = "\\n", .count = 2001, .expected = "MetadataLimitExceeded" },
    }) |case| {
        const plain = try repeatIn(a, "s", case.plain);
        const member = try a.print(",\"x\":\"{s}{s}\"", .{ plain, try repeatIn(a, case.piece, case.count) });
        try expectAnswer(case.expected, member, "");
    }
    for ([_]struct { digits: usize, expected: []const u8 }{
        .{ .digits = bound, .expected = "ok" },
        .{ .digits = bound + 1, .expected = "MetadataLimitExceeded" },
    }) |case| {
        const member = try a.print(",\"x\":{s}", .{try repeatIn(a, "1", case.digits)});
        try expectAnswer(case.expected, member, "");
    }
}

test "a round of the engine's slices gets the answer the text form gets at the collection and name bound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { items: usize, expected: []const u8 }{
        .{ .items = 256, .expected = "ok" },
        .{ .items = 257, .expected = "MetadataLimitExceeded" },
    }) |case| {
        const zeros = try repeatIn(a, "0,", case.items);
        const array = try a.print(",\"x\":[{s}]", .{zeros[0 .. zeros.len - 1]});
        try expectAnswer(case.expected, array, "");
        try expectAnswer(case.expected, "", array);
        var members: std.ArrayList(u8) = .empty;
        for (0..case.items) |index| try members.print(a, "{s}\"k{d}\":0", .{ if (index == 0) "" else ",", index });
        const object = try a.print(",\"x\":{{{s}}}", .{members.items});
        try expectAnswer(case.expected, object, "");
        try expectAnswer(case.expected, "", object);
    }
    // A name of 256 bytes in an object fx does not read is kept, and one of 257 is not, written plain or with escapes.
    for ([_]struct { piece: []const u8, count: usize, expected: []const u8 }{
        .{ .piece = "k", .count = 256, .expected = "ok" },
        .{ .piece = "k", .count = 257, .expected = "MetadataLimitExceeded" },
        .{ .piece = "\\u006b", .count = 256, .expected = "ok" },
        .{ .piece = "\\u006b", .count = 257, .expected = "MetadataLimitExceeded" },
    }) |case| {
        const member = try a.print(",\"x\":{{\"{s}\":0}}", .{try repeatIn(a, case.piece, case.count)});
        try expectAnswer(case.expected, member, "");
    }
}

test "a round of the engine's slices gets the answer the text form gets for a repeated name and for text that is no JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A repeated name is refused wherever it sits, written the same way or not, and it wins over a bound that is passed.
    const deep = try a.print(",\"y\":{s}", .{try nestedIn(a, 40)});
    for ([_]struct { params_tail: []const u8, request_tail: []const u8 }{
        .{ .params_tail = ",\"x\":{\"a\":0,\"a\":1}", .request_tail = "" },
        .{ .params_tail = "", .request_tail = ",\"x\":1,\"x\":2" },
        .{ .params_tail = "", .request_tail = ",\"x\":1,\"\\u0078\":2" },
        .{ .params_tail = "", .request_tail = ",\"x\":{\"a\\u0062\":0,\"ab\":1}" },
        .{ .params_tail = ",\"x\":[{\"a\":0,\"a\":1}]", .request_tail = "" },
    }) |case| {
        try expectAnswer("InvalidInputRequired", case.params_tail, case.request_tail);
        const both = try a.print("{s}{s}", .{ case.request_tail, deep });
        try expectAnswer("InvalidInputRequired", case.params_tail, both);
    }
    // The same name in two objects, or at two levels, is no repeat.
    try expectAnswer("ok", ",\"x\":{\"a\":0},\"y\":{\"a\":0,\"b\":{\"a\":0}}", ",\"z\":{\"a\":0}");
    // A string that spells half a surrogate pair is no JSON text, and is refused before a bound is read.
    try expectAnswer("InvalidInputRequired", ",\"x\":\"\\ud800\"", "");
    try expectAnswer("InvalidInputRequired", ",\"x\":\"\\ud800\"", deep);
}

test "a round larger than the text form allows is refused whatever its requests are" {
    const alloc = std.testing.allocator;
    const padded = "{\"method\":\"roots/list\",\"pad\":\"" ++ text_utils.repeat("p", 4096) ++ "\"}";
    var raw: [32]RawRequest = undefined;
    var keys: [32][8]u8 = undefined;
    for (&raw, &keys, 0..) |*request, *key, index| {
        key.* = "\"k000\"  ".*;
        _ = std.mem.print(key[2..5], "{d:0>3}", .{index}) catch unreachable;
        request.* = .{ .key = key[0..6], .kind = .roots, .raw = padded, .params = null };
    }
    try std.testing.expectError(error.MetadataLimitExceeded, readRequests(alloc, &raw, "", .modern_mcp, .{}));
    const few = try readRequests(alloc, raw[0..16], "", .modern_mcp, .{});
    freeRequests(alloc, few);
}

test "the text form still answers as it did: its keys are written back as tokens" {
    const alloc = std.testing.allocator;
    const requests = try readRequests(alloc, &.{}, "{\"a\\u0062\":{\"method\":\"roots/list\"},\"c\":{\"method\":\"sampling/createMessage\",\"params\":{}}}", .modern_mcp, .{});
    defer freeRequests(alloc, requests);
    // A key is read once and written as std.json writes it, so an escape in the text form comes back as the character.
    try std.testing.expectEqualStrings("\"ab\"", requests[0].key);
    try std.testing.expectEqualStrings("\"c\"", requests[1].key);
    try std.testing.expectError(error.InvalidInputRequired, readRequests(alloc, &.{}, "{\"bad\":{\"method\":\"custom/request\",\"params\":{}}}", .modern_mcp, .{}));
}

test "reading a round releases memory when an allocation fails" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkAllocationFailures,
        .{},
    );
}

fn checkAllocationFailures(alloc: Allocator) !void {
    const raw = [_]RawRequest{ formRaw("\"form\""), formRaw("\"caf\\u00e9\"") };
    const requests = readRequests(alloc, &raw, "", .modern_mcp, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    freeRequests(alloc, requests);
    const from_text = try readRequests(alloc, &.{}, "{\"form\":" ++ form_request ++ "}", .modern_mcp, .{});
    freeRequests(alloc, from_text);
}

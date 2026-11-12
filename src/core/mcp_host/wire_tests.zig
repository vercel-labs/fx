//! Fuzz target for the MCP engine's wire decoder. The engine in `src/mcp/`
//! imports only the standard library and its own files, so the target that
//! feeds it generated server lines lives here with the host.

const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");

const wire = mcp.wire;
const Allocator = std.mem.Allocator;
const testing = std.testing;

test "MCP wire decoding returns only whole JSON values from valid input" {
    try testing.fuzz({}, fuzzWire, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").mcp_wire.*),
    });
}

const fuzz_keys = [_][]const u8{
    "\"jsonrpc\"", "\"id\"",      "\"method\"", "\"params\"",       "\"result\"", "\"error\"", "\"resultType\"",
    "\"code\"",    "\"message\"", "\"data\"",   "\"\\u006dethod\"", "\"x\"",
};

const fuzz_values = [_][]const u8{
    "\"2.0\"",            "\"1.0\"",                   "1",           "0",    "-1",  "9007199254740991", "18446744073709551616",
    "\"42\"",             "\"042\"",                   "null",        "true", "1.5", "1e3",              "\"tools/list\"",
    "\"a\\\\b\"",         "\"\\u00e9\\ud83d\\ude00\"", "\"\\ud800\"", "\"\"", "{}",  "[]",               "[1,\"a\",{}]",
    "\"input_required\"", "-32601",
};

const fuzz_spaces = [_][]const u8{ "", " ", "\t", "\n", "\r\n" };

fn appendFuzzObject(alloc: Allocator, smith: *testing.Smith, out: *std.ArrayList(u8), depth: u8) !void {
    try out.append(alloc, '{');
    for (0..smith.valueRangeAtMost(u8, 0, 6)) |index| {
        if (index > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
        try out.appendSlice(alloc, fuzz_keys[smith.index(fuzz_keys.len)]);
        try out.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
        try out.append(alloc, ':');
        try out.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
        if (depth < 2 and smith.valueRangeAtMost(u8, 0, 3) == 0) {
            try appendFuzzObject(alloc, smith, out, depth + 1);
        } else {
            try out.appendSlice(alloc, fuzz_values[smith.index(fuzz_values.len)]);
        }
        try out.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
    }
    try out.append(alloc, '}');
}

const fuzz_results = [_][]const u8{ "{}", "{\"tools\":[]}", "{\"resultType\":\"input_required\",\"x\":1}", "{ \"a\" : [1, {\"b\":null}] }" };
const fuzz_methods = [_][]const u8{ "\"ping\"", "\"notifications/tools/list_changed\"", "\"elicitation/create\"" };

const FuzzField = struct { key: []const u8, value: []const u8 };

/// Builds a message `decode` must accept and checks that it returns exactly
/// the values that went in.
fn fuzzWellFormedWire(alloc: Allocator, smith: *testing.Smith) !void {
    var id_text: [24]u8 = undefined;
    const id_number: u64 = smith.value(u32);
    const id = if (smith.value(bool))
        try std.mem.print(&id_text, "{d}", .{id_number})
    else
        try std.mem.print(&id_text, "\"{d}\"", .{id_number});
    var error_text: [64]u8 = undefined;
    const error_object = try std.mem.print(&error_text, "{{\"code\":{d},\"message\":\"no\\nway\"}}", .{smith.value(i32)});

    var fields: [6]FuzzField = undefined;
    var count: usize = 0;
    fields[count] = .{ .key = "\"jsonrpc\"", .value = "\"2.0\"" };
    count += 1;
    const kind = smith.valueRangeAtMost(u8, 0, 3);
    switch (kind) {
        0, 1 => {
            fields[count] = .{ .key = "\"id\"", .value = id };
            count += 1;
            fields[count] = if (kind == 0)
                .{ .key = "\"result\"", .value = fuzz_results[smith.index(fuzz_results.len)] }
            else
                .{ .key = "\"error\"", .value = error_object };
            count += 1;
        },
        else => {
            if (kind == 3) {
                fields[count] = .{ .key = "\"id\"", .value = id };
                count += 1;
            }
            fields[count] = .{ .key = "\"method\"", .value = fuzz_methods[smith.index(fuzz_methods.len)] };
            count += 1;
            if (smith.value(bool)) {
                fields[count] = .{ .key = "\"params\"", .value = fuzz_results[smith.index(fuzz_results.len)] };
                count += 1;
            }
        },
    }
    // Fields the decoder skips: an unknown key and a key written with escapes.
    if (smith.value(bool)) {
        fields[count] = .{ .key = if (smith.value(bool)) "\"x\"" else "\"\\u0078\"", .value = "[1,{\"y\":null}]" };
        count += 1;
    }
    var index = count;
    while (index > 1) : (index -= 1) std.mem.swap(FuzzField, &fields[index - 1], &fields[smith.index(index)]);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    var starts: [6]usize = undefined;
    try line.append(alloc, '{');
    for (fields[0..count], 0..) |field, position| {
        if (position > 0) try line.append(alloc, ',');
        try line.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
        try line.appendSlice(alloc, field.key);
        try line.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
        try line.append(alloc, ':');
        try line.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
        starts[position] = line.items.len;
        try line.appendSlice(alloc, field.value);
        try line.appendSlice(alloc, fuzz_spaces[smith.index(fuzz_spaces.len)]);
    }
    try line.append(alloc, '}');

    const message = try wire.decode(line.items);
    const sliceOf = struct {
        fn get(items: []const u8, all: []const FuzzField, at: []const usize, key: []const u8) []const u8 {
            for (all, at[0..all.len]) |field, start| {
                if (std.mem.eql(u8, field.key, key)) return items[start .. start + field.value.len];
            }
            unreachable;
        }
    }.get;
    switch (kind) {
        0, 1 => {
            const response = message.response;
            try testing.expectEqual(@as(?wire.RequestId, id_number), response.id);
            switch (response.body) {
                .result => |result| {
                    try testing.expectEqual(@as(u8, 0), kind);
                    try testing.expect(result.raw.ptr == sliceOf(line.items, fields[0..count], &starts, "\"result\"").ptr);
                    try testing.expectEqualStrings(sliceOf(line.items, fields[0..count], &starts, "\"result\""), result.raw);
                },
                .failure => |failure| {
                    try testing.expectEqual(@as(u8, 1), kind);
                    try testing.expectEqualStrings("\"no\\nway\"", failure.message);
                },
            }
        },
        2 => {
            const method = sliceOf(line.items, fields[0..count], &starts, "\"method\"");
            try testing.expectEqualStrings(method[1 .. method.len - 1], message.notification.method);
        },
        else => {
            try testing.expectEqualStrings(id, message.request.id);
            const method = sliceOf(line.items, fields[0..count], &starts, "\"method\"");
            try testing.expectEqualStrings(method[1 .. method.len - 1], message.request.method);
        },
    }
}

fn fuzzWire(_: void, smith: *testing.Smith) !void {
    const alloc = testing.allocator;
    if (smith.value(bool)) return fuzzWellFormedWire(alloc, smith);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try appendFuzzObject(alloc, smith, &input, 0);
    // Sometimes break the line: a byte or a piece goes in somewhere.
    for (0..smith.valueRangeAtMost(u8, 0, 2)) |_| {
        const at = smith.index(input.items.len + 1);
        if (smith.value(bool)) {
            try input.insert(alloc, at, smith.value(u8));
        } else {
            try input.insertSlice(alloc, at, fuzz_values[smith.index(fuzz_values.len)]);
        }
    }
    const line = input.items;
    const valid = try std.json.validate(alloc, line);

    if (wire.decode(line)) |message| {
        try testing.expect(valid);
        switch (message) {
            .response => |response| switch (response.body) {
                .result => |result| try expectFuzzObject(alloc, line, result.raw),
                .failure => |failure| {
                    try expectFuzzString(alloc, line, failure.message);
                    if (failure.data) |data| try expectFuzzValue(alloc, line, data);
                },
            },
            .notification => |notification| {
                try expectFuzzMethod(line, notification.method);
                if (notification.params) |params| try expectFuzzObject(alloc, line, params);
            },
            .request => |request| {
                try expectFuzzValue(alloc, line, request.id);
                try expectFuzzMethod(line, request.method);
                if (request.params) |params| try expectFuzzObject(alloc, line, params);
            },
        }
    } else |_| {}

    // Walking the whole line field by field reaches the end only when the
    // line is valid JSON.
    var fields: wire.Fields = undefined;
    fields.init(line) catch return;
    while (true) {
        const field = (fields.next() catch return) orelse break;
        try expectFuzzString(alloc, line, field.key);
        try expectFuzzValue(alloc, line, field.value);
    }
    try testing.expect(valid);
}

/// A returned slice is one whole JSON value inside the line, with nothing
/// around it.
fn expectFuzzValue(alloc: Allocator, line: []const u8, value: []const u8) anyerror!void {
    try testing.expect(value.len > 0);
    try testing.expect(@intFromPtr(value.ptr) >= @intFromPtr(line.ptr));
    try testing.expect(@intFromPtr(value.ptr) + value.len <= @intFromPtr(line.ptr) + line.len);
    try testing.expect(!std.ascii.isWhitespace(value[0]) and !std.ascii.isWhitespace(value[value.len - 1]));
    try testing.expect(try std.json.validate(alloc, value));
    if (value[0] == '"') {
        try expectFuzzStringText(alloc, value);
    } else if (value[0] == '[') {
        var elements: wire.Elements = undefined;
        try elements.init(value);
        while (try elements.next()) |element| try expectFuzzValue(alloc, line, element);
    } else if (value[0] == '{') {
        try expectFuzzObject(alloc, line, value);
    }
}

fn expectFuzzObject(alloc: Allocator, line: []const u8, object: []const u8) anyerror!void {
    try testing.expectEqual(@as(u8, '{'), object[0]);
    try testing.expect(try std.json.validate(alloc, object));
    var fields: wire.Fields = undefined;
    try fields.init(object);
    while (try fields.next()) |field| {
        try expectFuzzString(alloc, line, field.key);
        try expectFuzzValue(alloc, line, field.value);
    }
}

fn expectFuzzString(alloc: Allocator, line: []const u8, raw: []const u8) anyerror!void {
    try testing.expectEqual(@as(u8, '"'), raw[0]);
    try expectFuzzValue(alloc, line, raw);
}

/// `decodeString` reads a string token the way `std.json` does.
fn expectFuzzStringText(alloc: Allocator, raw: []const u8) !void {
    const expected = try std.json.parseFromSlice([]const u8, alloc, raw, .{});
    defer expected.deinit();
    const decoded = (try wire.decodeString(alloc, raw)) orelse return error.TestExpectedString;
    defer if (wire.plainString(raw) == null) alloc.free(decoded);
    try testing.expectEqualStrings(expected.value, decoded);
}

/// A method is a string written without escapes, returned without quotes.
fn expectFuzzMethod(line: []const u8, method: []const u8) !void {
    try testing.expect(std.mem.findScalar(u8, method, '\\') == null);
    try testing.expect(std.mem.findScalar(u8, method, '"') == null);
    try testing.expect(@intFromPtr(method.ptr) > @intFromPtr(line.ptr));
    try testing.expectEqual(@as(u8, '"'), (method.ptr - 1)[0]);
}

// ---- Elicitation answers: the same string, written with different escapes ----

/// A fuzz input is one byte string that this reads as a script: where the string
/// sits in a form, whether the answer holds the same string, how many code
/// points it has, and for each one a code point and how each side spells it.
const EscapeScript = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(s: *EscapeScript) u8 {
        if (s.at >= s.bytes.len) return 0;
        defer s.at += 1;
        return s.bytes[s.at];
    }
};

/// Code points that sit on the edges of the escape rules: a short escape, a
/// control, ASCII, two- and three-byte UTF-8, and the first and last of the
/// astral planes, which JSON writes as a surrogate pair.
const escape_code_points = [_]u21{
    'a', 'A', 0xe9, '/', '"', '\\', '\n', 0x00, 0x1f, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x1f600, 0x10ffff,
};

fn escapeCodePoint(s: *EscapeScript) u21 {
    const selector = s.next();
    if (selector & 0x80 == 0) return escape_code_points[selector % escape_code_points.len];
    const code_point: u21 = (@as(u21, selector & 0x7f) << 8) | s.next();
    return if (code_point >= 0xd800 and code_point <= 0xdfff) code_point + 0x800 else code_point;
}

fn appendHex4(alloc: Allocator, out: *std.ArrayList(u8), unit: u16, upper: bool) !void {
    const digits = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    try out.appendSlice(alloc, "\\u");
    var shift: u4 = 12;
    while (true) : (shift -= 4) {
        try out.append(alloc, digits[(unit >> shift) & 0xf]);
        if (shift == 0) break;
    }
}

/// `code_points` as a JSON string token. Each is written the way `style` says:
/// plainly when JSON allows it, as a `\uXXXX` escape in either case of hex
/// digit (a surrogate pair above U+FFFF), or as a short escape when there is one.
fn appendSpelled(alloc: Allocator, out: *std.ArrayList(u8), code_points: []const u21, s: *EscapeScript) !void {
    try out.append(alloc, '"');
    for (code_points) |code_point| {
        const style = s.next() % 4;
        const short: ?u8 = switch (code_point) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            0x08 => 'b',
            0x0c => 'f',
            0x0a => 'n',
            0x0d => 'r',
            0x09 => 't',
            else => null,
        };
        const needs_escape = code_point < 0x20 or code_point == '"' or code_point == '\\';
        const plain_ok = !needs_escape;
        if ((style == 0 and plain_ok) or (style == 3 and short == null and plain_ok)) {
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code_point, &encoded) catch unreachable;
            try out.appendSlice(alloc, encoded[0..n]);
        } else if ((style == 0 or style == 3) and short != null) {
            try out.appendSlice(alloc, &.{ '\\', short.? });
        } else {
            const upper = style == 2;
            if (code_point >= 0x10000) {
                const v = code_point - 0x10000;
                try appendHex4(alloc, out, @intCast(0xd800 + (v >> 10)), upper);
                try appendHex4(alloc, out, @intCast(0xdc00 + (v & 0x3ff)), upper);
            } else try appendHex4(alloc, out, @intCast(code_point), upper);
        }
    }
    try out.append(alloc, '"');
}

/// The string `token` holds, as `std.json` reads it: the host reads a form and
/// an answer with it.
fn decodedByStdJson(arena: Allocator, token: []const u8) ![]const u8 {
    return std.json.parseFromSliceLeaky([]const u8, arena, token, .{});
}

fn fuzzEscapedStrings(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    var script: EscapeScript = .{ .bytes = buffer[0..len] };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const place = script.next() % 3;
    const same = script.next() % 2 == 0;
    const count = script.next() % 12 + 1;
    var server_points: [12]u21 = undefined;
    for (server_points[0..count]) |*code_point| code_point.* = escapeCodePoint(&script);
    var answer_points = server_points;
    if (!same) {
        // One code point differs, or the answer is a code point shorter.
        const change = escapeCodePoint(&script);
        if (change == answer_points[count - 1]) {
            if (count == 1) return;
        } else answer_points[count - 1] = change;
    }
    const answer_count = if (!same and answer_points[count - 1] == server_points[count - 1]) count - 1 else count;

    var server: std.ArrayList(u8) = .empty;
    try appendSpelled(arena, &server, server_points[0..count], &script);
    var answer: std.ArrayList(u8) = .empty;
    try appendSpelled(arena, &answer, answer_points[0..answer_count], &script);

    const properties = switch (place) {
        0 => try arena.print("{{{s}:{{\"type\":\"boolean\"}}}}", .{server.items}),
        1 => try arena.print("{{\"c\":{{\"type\":\"string\",\"enum\":[{s},\"zz\"]}}}}", .{server.items}),
        else => try arena.print("{{\"c\":{{\"type\":\"string\",\"oneOf\":[{{\"const\":{s}}},{{\"const\":\"zz\"}}]}}}}", .{server.items}),
    };
    const content = switch (place) {
        0 => try arena.print("{{{s}:true}}", .{answer.items}),
        else => try arena.print("{{\"c\":{s}}}", .{answer.items}),
    };
    const params = try arena.print("{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{s}}}}}", .{properties});

    var form: mcp.elicitation.Form = .{};
    const request = mcp.elicitation.parse(params, &form) catch return;
    const accepted = if (mcp.elicitation.check(request.mode, &form, .{ .action = .accept, .content = content })) true else |_| false;

    // The law: the engine accepts the answer exactly when the two strings are
    // the same string once decoded, as `std.json` decodes them.
    const want = try decodedByStdJson(arena, server.items);
    const got = try decodedByStdJson(arena, answer.items);
    const matches = std.mem.eql(u8, want, got) or (place != 0 and std.mem.eql(u8, got, "zz"));
    if (accepted != matches) {
        std.debug.print("the engine {s} {s}, std.json says {s}: server wrote {s}, answer wrote {s}\n", .{
            if (accepted) "accepted" else "refused",
            if (place == 0) "a key" else "a choice",
            if (matches) "they match" else "they differ",
            server.items,
            answer.items,
        });
        return error.TestUnexpectedResult;
    }
}

test "the engine's equality of a form's strings and an answer's matches std.json's decoded equality" {
    try testing.fuzz({}, fuzzEscapedStrings, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").mcp_elicitation_escapes.*),
    });
}

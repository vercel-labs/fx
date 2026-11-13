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

test "the engine reads an object's field names as std.json decodes them" {
    try testing.fuzz({}, fuzzMemberNames, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").mcp_object_fields.*),
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

// ---- objectFields: the same name, written with different escapes ----

/// A fuzz input is one byte string that this reads as a script: how many members
/// the object has, and for each its name (one the reader asks for, a name that
/// only looks like one, or an unasked name), how each letter is written, and its
/// value.
const MemberScript = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(s: *MemberScript) u8 {
        if (s.at >= s.bytes.len) return 0;
        defer s.at += 1;
        return s.bytes[s.at];
    }
};

/// The names the reader asks for, as the engine asks for them.
const member_names = [_][]const u8{ "mode", "isError", "id", "requestState" };

/// Values that stay one token however the object is scanned.
const member_values = [_][]const u8{ "true", "false", "7", "\"s\"", "{\"a\":[1,{\"b\":null}]}", "[]", "\"\\u00e9\\\\\"" };

/// Code points that make a name look like another one without being it: NUL,
/// a letter that is none of the asked names', a dotless i, an accent, an
/// astral code point.
const member_marks = [_]u21{ 0x00, 'x', 0x131, 0xe9, 0x1f600 };

fn appendMemberHex(alloc: Allocator, out: *std.ArrayList(u8), unit: u16, upper: bool) !void {
    const digits = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    try out.appendSlice(alloc, "\\u");
    var shift: u4 = 12;
    while (true) : (shift -= 4) {
        try out.append(alloc, digits[(unit >> shift) & 0xf]);
        if (shift == 0) break;
    }
}

/// `points` as a JSON string token. A code point is written plainly when JSON
/// allows it and the style says so, otherwise as a `\uXXXX` escape in either
/// case of hex digit, or as a surrogate pair above U+FFFF.
fn appendMemberName(alloc: Allocator, out: *std.ArrayList(u8), points: []const u21, s: *MemberScript) !void {
    try out.append(alloc, '"');
    for (points) |point| {
        const style = s.next() % 4;
        const plain_ok = point >= 0x20 and point != '"' and point != '\\';
        if (style == 0 and plain_ok) {
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(point, &encoded) catch unreachable;
            try out.appendSlice(alloc, encoded[0..n]);
        } else if (point >= 0x10000) {
            const v = point - 0x10000;
            try appendMemberHex(alloc, out, @intCast(0xd800 + (v >> 10)), style == 2);
            try appendMemberHex(alloc, out, @intCast(0xdc00 + (v & 0x3ff)), style == 2);
        } else try appendMemberHex(alloc, out, @intCast(point), style == 2);
    }
    try out.append(alloc, '"');
}

/// The fields `std.json` is asked for: it refuses a field written twice,
/// however either one is spelled, and skips every other name.
const MemberFields = struct {
    mode: ?std.json.Value = null,
    isError: ?std.json.Value = null,
    id: ?std.json.Value = null,
    requestState: ?std.json.Value = null,
};

fn fuzzMemberNames(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    var script: MemberScript = .{ .bytes = buffer[0..len] };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var object: std.ArrayList(u8) = .empty;
    try object.append(arena, '{');
    var counts: [member_names.len]u8 = @splat(0);
    var wanted: [member_names.len]?[]const u8 = @splat(null);
    const members = script.next() % 6 + 1;
    for (0..members) |position| {
        var points: [16]u21 = undefined;
        var n: usize = 0;
        const kind = script.next() % 6;
        var asked: ?usize = null;
        switch (kind) {
            0...3 => {
                asked = script.next() % member_names.len;
                for (member_names[asked.?]) |c| {
                    points[n] = c;
                    n += 1;
                }
            },
            4 => {
                // A name that only looks like an asked one.
                const base = member_names[script.next() % member_names.len];
                const op = script.next() % 4;
                const mark = member_marks[script.next() % member_marks.len];
                const at = script.next() % base.len;
                if (op == 0) {
                    points[n] = mark;
                    n += 1;
                }
                for (base, 0..) |c, i| {
                    if (op == 2 and i == base.len - 1) break;
                    if (op == 3 and i == at) {
                        points[n] = mark;
                    } else points[n] = c;
                    n += 1;
                }
                if (op == 1) {
                    points[n] = mark;
                    n += 1;
                }
            },
            else => {
                points[0] = if (script.next() % 2 == 0) 'x' else 'y';
                n = 1;
            },
        }
        const value = member_values[script.next() % member_values.len];
        if (position > 0) try object.append(arena, ',');
        try object.appendSlice(arena, fuzz_spaces[script.next() % fuzz_spaces.len]);
        try appendMemberName(arena, &object, points[0..n], &script);
        try object.append(arena, ':');
        try object.appendSlice(arena, value);
        if (asked) |i| {
            counts[i] += 1;
            wanted[i] = value;
        }
    }
    try object.append(arena, '}');

    var duplicated = false;
    for (counts) |c| duplicated = duplicated or c > 1;

    var found: [member_names.len]?[]const u8 = undefined;
    const engine: wire.DecodeError!void = wire.objectFields(object.items, &member_names, &found);

    // The law: the engine refuses the object exactly when std.json refuses it for
    // a field written twice, and otherwise reads each field as std.json decodes it.
    const typed = std.json.parseFromSliceLeaky(MemberFields, arena, object.items, .{ .ignore_unknown_fields = true });
    if (typed) |fields| {
        if (engine) |_| {} else |err| return memberDisagrees(object.items, "refused ({s}) an object std.json reads", .{@errorName(err)});
        if (duplicated) return memberDisagrees(object.items, "std.json read an object with a repeated name", .{});
        const std_values = [member_names.len]?std.json.Value{ fields.mode, fields.isError, fields.id, fields.requestState };
        for (std_values, found, wanted, member_names) |from_std, from_engine, want, name| {
            if ((from_std == null) != (from_engine == null)) {
                return memberDisagrees(object.items, "disagrees on whether {s} is there: engine {s}", .{ name, if (from_engine == null) "no" else "yes" });
            }
            if (from_engine) |raw| {
                if (!std.mem.eql(u8, raw, want.?)) return memberDisagrees(object.items, "read {s} as {s}", .{ name, raw });
                const again = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
                const a = try std.json.Stringify.valueAlloc(arena, again, .{});
                const b = try std.json.Stringify.valueAlloc(arena, from_std.?, .{});
                if (!std.mem.eql(u8, a, b)) return memberDisagrees(object.items, "read {s} as a different value than std.json", .{name});
            }
        }
    } else |std_err| {
        if (std_err != error.DuplicateField) return memberDisagrees(object.items, "std.json refused it for another reason: {s}", .{@errorName(std_err)});
        if (!duplicated) return memberDisagrees(object.items, "std.json refused an object with no repeated name", .{});
        if (engine) |_| return memberDisagrees(object.items, "accepted an object std.json refuses for a repeated name", .{}) else |err| {
            if (err != error.DuplicateField) return memberDisagrees(object.items, "refused with {s}, not DuplicateField", .{@errorName(err)});
        }
    }
}

fn memberDisagrees(object: []const u8, comptime what: []const u8, args: anytype) error{TestUnexpectedResult} {
    std.debug.print("the engine " ++ what ++ ": object " ++ "{s}\n", args ++ .{object});
    return error.TestUnexpectedResult;
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

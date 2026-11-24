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
/// astral code point, and the four that JSON can write as a short escape.
const member_marks = [_]u21{ 0x00, 'x', 0x131, 0xe9, 0x1f600, '/', '"', '\\', '\n' };

fn appendMemberHex(alloc: Allocator, out: *std.ArrayList(u8), unit: u16, upper: bool) !void {
    const digits = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    try out.appendSlice(alloc, "\\u");
    var shift: u4 = 12;
    while (true) : (shift -= 4) {
        try out.append(alloc, digits[(unit >> shift) & 0xf]);
        if (shift == 0) break;
    }
}

/// The letter of the short escape JSON has for `point`, if it has one.
fn shortEscape(point: u21) ?u8 {
    return switch (point) {
        '"' => '"',
        '\\' => '\\',
        '/' => '/',
        0x08 => 'b',
        0x0c => 'f',
        '\n' => 'n',
        '\r' => 'r',
        '\t' => 't',
        else => null,
    };
}

/// `points` as a JSON string token. A code point is written plainly when JSON
/// allows it and the style says so, as its short escape (`\/`, `\"`, `\\`, `\n`)
/// when it has one and the style says so, otherwise as a `\uXXXX` escape in
/// either case of hex digit, or as a surrogate pair above U+FFFF.
fn appendMemberName(alloc: Allocator, out: *std.ArrayList(u8), points: []const u21, s: *MemberScript) !void {
    try out.append(alloc, '"');
    for (points) |point| {
        const style = s.next() % 4;
        const plain_ok = point >= 0x20 and point != '"' and point != '\\';
        if (style == 3) if (shortEscape(point)) |letter| {
            try out.appendSlice(alloc, &.{ '\\', letter });
            continue;
        };
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
    var key_spans: [6][2]usize = undefined;
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
        const key_start = object.items.len;
        try appendMemberName(arena, &object, points[0..n], &script);
        key_spans[position] = .{ key_start, object.items.len };
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

    // The law for the two-token form that `mrtr.zig` uses: two keys are one name exactly when
    // std.json decodes them to the same text, however each is spelled.
    for (0..members) |i| for (i + 1..members) |j| {
        const a = object.items[key_spans[i][0]..key_spans[i][1]];
        const b = object.items[key_spans[j][0]..key_spans[j][1]];
        const text_a = try std.json.parseFromSliceLeaky([]const u8, arena, a, .{});
        const text_b = try std.json.parseFromSliceLeaky([]const u8, arena, b, .{});
        const same = std.mem.eql(u8, text_a, text_b);
        if (wire.sameString(a, b) != same) {
            return memberDisagrees(object.items, "says sameString({s}, {s}) is {s}, and std.json decodes the keys {s}", .{ a, b, if (same) "false" else "true", if (same) "alike" else "apart" });
        }
    };

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
    try testing.expectEqual(expectedResponseId(alloc, line), wire.responseId(line));

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

const envelope_names = [_][]const u8{ "jsonrpc", "id", "method", "params", "result", "error" };

/// What `wire.responseId` must read from `line`, found by walking it member by member with a plain `std.json.Scanner`,
/// without the engine's reader: the top-level `id` read before the line went wrong, and none when the line writes `id` twice,
/// has a `method`, or goes wrong inside its `params` (`tests/tla/mcp/Request.tla` `RefusedNaming`). An `id` nested in a value,
/// or after the bad part, is never read. The fuzzed lines nest only a few levels, so the engine's own depth limit does not come in.
fn expectedResponseId(alloc: Allocator, line: []const u8) ?wire.RequestId {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(arena, line);
    const opened = scanner.next() catch return null;
    if (opened != .object_begin) return null;
    var id: ?wire.RequestId = null;
    var seen: [envelope_names.len]bool = @splat(false);
    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_always) catch return id;
        const key = switch (token) {
            .allocated_string => |name| name,
            else => return id,
        };
        const wanted = for (envelope_names, 0..) |name, index| {
            if (std.mem.eql(u8, key, name)) break index;
        } else null;
        const is_id = if (wanted) |index| std.mem.eql(u8, envelope_names[index], "id") else false;
        const is_method = if (wanted) |index| std.mem.eql(u8, envelope_names[index], "method") else false;
        const is_params = if (wanted) |index| std.mem.eql(u8, envelope_names[index], "params") else false;
        if (wanted) |index| {
            if (seen[index]) return if (is_id or is_method or is_params) null else id;
            seen[index] = true;
        }
        if (is_method) return null;
        if (is_id) {
            const value = scanner.next() catch return null;
            id = switch (value) {
                .number, .string => |digits| wire.decimal(digits),
                else => return null,
            };
            continue;
        }
        scanner.skipValue() catch return if (is_params) null else id;
    }
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

    // The same two strings as names in one form. Two names that decode alike are one name, so a form that holds both
    // is unreadable; and a `required` name that decodes like a property's key finds that property.
    const want = try decodedByStdJson(arena, server.items);
    const got = try decodedByStdJson(arena, answer.items);
    const alike = std.mem.eql(u8, want, got);
    const twice = try arena.print("{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{{s}:{{\"type\":\"boolean\"}},{s}:{{\"type\":\"boolean\"}}}}}}}}", .{ server.items, answer.items });
    const named = try arena.print("{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{{s}:{{\"type\":\"boolean\"}}}},\"required\":[{s}]}}}}", .{ server.items, answer.items });
    for ([_]struct { params: []const u8, what: []const u8, readable_when_alike: bool }{
        .{ .params = twice, .what = "two property names", .readable_when_alike = false },
        .{ .params = named, .what = "a property name and a required name", .readable_when_alike = true },
    }) |shape| {
        var shape_form: mcp.elicitation.Form = .{};
        const readable = if (mcp.elicitation.parse(shape.params, &shape_form)) |_| true else |_| false;
        if (readable != (alike == shape.readable_when_alike)) {
            std.debug.print("the engine read {s} as {s}, and std.json decodes them {s}: server wrote {s}, answer wrote {s}\n", .{
                shape.what,
                if (readable) "readable" else "unreadable",
                if (alike) "alike" else "apart",
                server.items,
                answer.items,
            });
            return error.TestUnexpectedResult;
        }
    }

    // The length of a string. A form that limits a string to as many code points as `std.json` decodes from the
    // server's string takes that string, and refuses a string one code point longer or shorter. The answer the
    // script made is taken exactly when it decodes to that many code points.
    const limit = std.unicode.utf8CountCodepoints(want) catch unreachable;
    var longer: std.ArrayList(u8) = .empty;
    try longer.appendSlice(arena, server.items[0 .. server.items.len - 1]);
    try longer.appendSlice(arena, "a\"");
    var shorter: std.ArrayList(u8) = .empty;
    try appendSpelled(arena, &shorter, server_points[0 .. count - 1], &script);
    const lengths = try arena.print(
        "{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{\"c\":{{\"type\":\"string\",\"minLength\":{d},\"maxLength\":{d}}}}}}}}}",
        .{ limit, limit },
    );
    var length_form: mcp.elicitation.Form = .{};
    const length_request = mcp.elicitation.parse(lengths, &length_form) catch {
        std.debug.print("the engine could not read a form whose string has a length of {d}\n", .{limit});
        return error.TestUnexpectedResult;
    };
    for ([_]struct { token: []const u8, points: usize }{
        .{ .token = server.items, .points = limit },
        .{ .token = longer.items, .points = limit + 1 },
        .{ .token = shorter.items, .points = limit - 1 },
        .{ .token = answer.items, .points = try std.unicode.utf8CountCodepoints(got) },
    }) |candidate| {
        const text = try arena.print("{{\"c\":{s}}}", .{candidate.token});
        const taken = if (mcp.elicitation.check(length_request.mode, &length_form, .{ .action = .accept, .content = text })) true else |_| false;
        if (taken != (candidate.points == limit)) {
            std.debug.print("the engine {s} a string of {d} code points where {d} are allowed: server wrote {s}, the string was {s}\n", .{
                if (taken) "accepted" else "refused",
                candidate.points,
                limit,
                server.items,
                candidate.token,
            });
            return error.TestUnexpectedResult;
        }
    }

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
    const matches = alike or (place != 0 and std.mem.eql(u8, got, "zz"));
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

test "the engine's equality and length limits of a form's strings and an answer's match std.json's decoded strings" {
    try testing.fuzz({}, fuzzEscapedStrings, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").mcp_elicitation_escapes.*),
    });
}

// ---- the grace for a refused line that names no request ----
//
// `src/mcp/core/request.zig` holds the rules, and `tests/tla/mcp/Request.tla` states them.

test "a fuzzed run of requests, lines that name no request, replies, progress and timers ends each request once and ends only a silent request that has a grace as malformed" {
    try testing.fuzz({}, fuzzGrace, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").mcp_request_grace.*),
    });
}

/// Each byte is one step: its last decimal digit picks the step and the rest picks a request, so a
/// saved input reads as a short script. 0 to 2 send a normal request, initialize or a listen; 3 is a
/// refused line that names no request, on the connection (an even request number) or on one request's
/// stream (an odd one); 4 fires a grace timer; 5 answers a request; 6 is progress;
/// 7 fires a request's idle timer; 8 cancels; 9 loses the transport.
fn fuzzGrace(_: void, smith: *testing.Smith) !void {
    const request = mcp.core.request;
    var slots: [4]request.Slot = undefined;
    var table: request.Table = .init(&slots, .{ .refused_ms = 30_000 });
    var out: request.Output = .{};
    var raw: [160]u8 = undefined;
    const len = smith.slice(&raw);
    // What the rules say each request holds, by id: a grace, or an ending already delivered.
    var armed: [256]bool = @splat(false);
    var ended: [256]bool = @splat(false);
    var kinds: [256]request.Kind = @splat(.normal);
    var timers: [16]request.Timer = undefined;
    var timer_count: usize = 0;

    for (raw[0..len]) |byte| {
        const pick = byte % 10;
        const arg: request.Id = byte / 10 % 8;
        var fresh: usize = 0;
        var was_progress: u32 = 0;
        const index = @min(arg + 1, 255);
        switch (pick) {
            0, 1, 2 => {
                const kind: request.Kind = switch (pick) {
                    0 => .normal,
                    1 => .initialize,
                    else => .listen,
                };
                table.step(.{ .send = kind }, &out) catch |err| switch (err) {
                    error.TooManyInFlight => continue,
                    else => return err,
                };
                const id = out.effects()[0].write_request.id;
                kinds[@intCast(id)] = kind;
            },
            3 => {
                const scope: ?request.Id = if (arg % 2 == 0) null else index;
                for (table.slots) |slot| fresh += @intFromBool(slot.used and slot.kind == .normal and !armed[@intCast(slot.id)] and (scope == null or slot.id == scope.?));
                try table.step(.{ .refused_line = scope }, &out);
                // One timer covers every request the line finds without a grace, and none when it finds none.
                var arms: usize = 0;
                for (out.effects()) |effect| switch (effect) {
                    .arm_timer => |arm| arms += @intFromBool(arm.timer.kind == .refused),
                    else => {},
                };
                try testing.expectEqual(@as(usize, @intFromBool(fresh > 0)), arms);
                for (table.slots) |slot| if (slot.used and slot.kind == .normal and (scope == null or slot.id == scope.?)) {
                    armed[@intCast(slot.id)] = true;
                };
            },
            4 => {
                if (timer_count == 0) continue;
                try table.step(.{ .timer_fired = timers[@intCast(arg % timer_count)] }, &out);
            },
            5 => try table.step(.{ .response_received = .{ .id = index, .response = .result } }, &out),
            6 => {
                was_progress = table.progressCount(index);
                try table.step(.{ .progress_received = .{ .token = index, .value = @floatFromInt(arg) } }, &out);
                // Progress that the table accepts clears the request's grace.
                if (table.progressCount(index) != was_progress) armed[@intCast(index)] = false;
            },
            7 => {
                const generation: u32 = for (table.slots) |slot| {
                    if (slot.used and slot.id == index) break slot.idle_generation;
                } else 1;
                try table.step(.{ .timer_fired = .{ .id = index, .kind = .idle, .generation = generation } }, &out);
            },
            8 => table.step(.{ .cancel_requested = index }, &out) catch |err| switch (err) {
                error.InitializeNotCancellable => continue,
                else => return err,
            },
            else => try table.step(.{ .transport_lost = index }, &out),
        }
        for (out.effects()) |effect| switch (effect) {
            .deliver => |d| {
                const at: usize = @intCast(d.id);
                try testing.expect(!ended[at]);
                ended[at] = true;
                if (d.outcome == .malformed) {
                    try testing.expect(armed[at]);
                    try testing.expect(kinds[at] == .normal);
                }
                armed[at] = false;
            },
            .arm_timer => |arm| if (arm.timer.kind == .refused and timer_count < timers.len) {
                timers[timer_count] = arm.timer;
                timer_count += 1;
            },
            else => {},
        };
    }
}

test "a WWW-Authenticate challenge is read within its bounds on fuzzed bytes" {
    try testing.fuzz({}, fuzzChallenge, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "Bearer error=\"invalid_token\", error_description=\"No authorization provided\", resource_metadata=\"https://x.example/.well-known/oauth-protected-resource\"",
            "Basic realm=\"a\", Bearer error=\"insufficient_scope\", scope=\"a b\"",
            "Bearer error_description=\"a \\\"quoted\\\" \\\\ b\"",
            "Bearer resource_metadata=\"u\"",
            "Bearer error=, error_description=\"unterminated",
        }) ++ @import("fuzz_corpus").mcp_challenge.*),
    });
}

/// What a server's challenge can make the engine keep, whatever its bytes:
/// every value lies inside the header, the error and its description stay
/// under their bounds, a step-up is named only when the header says so, and
/// reading the same header twice gives the same answer. The words shown to
/// the person are made terminal-safe at the place they are printed
/// (`login_words.zig`), not here.
fn fuzzChallenge(_: void, smith: *testing.Smith) anyerror!void {
    const discovery = mcp.auth.discovery;
    var buffer: [2048]u8 = undefined;
    const value = buffer[0..smith.slice(&buffer)];
    var first: std.heap.ArenaAllocator = .init(testing.allocator);
    defer first.deinit();
    var second: std.heap.ArenaAllocator = .init(testing.allocator);
    defer second.deinit();
    const a = try discovery.parseChallenge(first.allocator(), value);
    const b = try discovery.parseChallenge(second.allocator(), value);
    try testing.expectEqual(a == null, b == null);
    const c = a orelse return;
    const d = b.?;
    try expectSameText(c.resource_metadata, d.resource_metadata, value.len);
    try expectSameText(c.scope, d.scope, value.len);
    try testing.expectEqual(c.insufficient_scope, d.insufficient_scope);
    // The error a server names and its description, kept for the words fx shows:
    // bounded where they are kept, so a huge header can't fill a screen or a log.
    try expectSameText(c.error_code, d.error_code, discovery.max_error_bytes);
    try expectSameText(c.description, d.description, discovery.max_description_bytes);
    try testing.expectEqual(@as(usize, 240), discovery.max_description_bytes);
    // Cut at a character, never inside one, when the bytes were UTF-8.
    if (c.description) |text| if (std.unicode.utf8ValidateSlice(value)) try testing.expect(std.unicode.utf8ValidateSlice(text));
    // A step-up is named only when the header spells the name where a value can hold it.
    if (c.insufficient_scope) try testing.expect(spellsStepUp(value));
}

/// Whether `value` spells `insufficient_scope` where the parser could read it as one value: as the plain
/// bytes (an unquoted token, or a quoted string without escapes), or inside a quoted string whose
/// escapes spell it, such as `"insuffic\ient_scope"` (RFC 9110 5.6.4: a backslash and the byte after
/// it). A backslash outside a quoted string is part of the value, and an escaped backslash (`\\`) is a
/// backslash in it, so neither spells the name. A quoted string may also run to the end of the header.
fn spellsStepUp(value: []const u8) bool {
    const name = "insufficient_scope";
    if (std.mem.find(u8, value, name) != null) return true;
    for (value, 0..) |byte, quote| {
        if (byte != '"') continue;
        var at = quote + 1;
        var matched: usize = 0;
        while (matched < name.len and at < value.len) : (matched += 1) {
            if (value[at] == '\\' and at + 1 < value.len and value[at + 1] == name[matched]) {
                at += 2;
            } else if (value[at] == name[matched]) {
                at += 1;
            } else break;
        }
        if (matched == name.len and (at == value.len or value[at] == '"')) return true;
    }
    return false;
}

test "the step-up law reads escapes only inside a quoted string" {
    // The name, plain or quoted.
    try testing.expect(spellsStepUp("Bearer error=insufficient_scope"));
    try testing.expect(spellsStepUp("Bearer error=\"insufficient_scope\", scope=\"a\""));
    // A quoted-pair spells it: the same word.
    try testing.expect(spellsStepUp("Bearer error=\"insuffic\\ient_scope\""));
    try testing.expect(spellsStepUp("Bearer error=\"\\insufficient_scope\""));
    // The header the fuzzer found, after a first challenge that was not one, and a quoted string with no end.
    try testing.expect(spellsStepUp("\"alm=\"a\", Bearer error=\"insuffic\\ient_scope\",Q="));
    try testing.expect(spellsStepUp("Bearer error=\"insuffic\\ient_scope"));
    // An escaped backslash is a backslash in the value, so it does not spell the name.
    try testing.expect(!spellsStepUp("Bearer error=\"insuffic\\\\ient_scope\""));
    // Outside a quoted string a backslash is part of the value.
    try testing.expect(!spellsStepUp("Bearer error=insuffic\\ient_scope"));
    try testing.expect(!spellsStepUp("Bearer error=x, scope=insuffic\\ient_scope"));
    // A backslash before a byte the name does not have there, or none of the name at all.
    try testing.expect(!spellsStepUp("Bearer error=\"insuffic\\xient_scope\""));
    try testing.expect(!spellsStepUp("Bearer error=\"invalid_token\""));
}

fn expectSameText(x: ?[]const u8, y: ?[]const u8, bound: usize) !void {
    try testing.expectEqual(x == null, y == null);
    if (x) |text| {
        try testing.expectEqualStrings(y.?, text);
        try testing.expect(text.len <= bound);
    }
}

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
/// refused line that names no request; 4 fires a grace timer; 5 answers a request; 6 is progress;
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
                for (table.slots) |slot| fresh += @intFromBool(slot.used and slot.kind == .normal and !armed[@intCast(slot.id)]);
                try table.step(.refused_line, &out);
                // One timer covers every request the line finds without a grace, and none when it finds none.
                var arms: usize = 0;
                for (out.effects()) |effect| switch (effect) {
                    .arm_timer => |arm| arms += @intFromBool(arm.timer.kind == .refused),
                    else => {},
                };
                try testing.expectEqual(@as(usize, @intFromBool(fresh > 0)), arms);
                for (table.slots) |slot| if (slot.used and slot.kind == .normal) {
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

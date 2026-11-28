//! Wire payloads for ACP v2 Preview. The server must not negotiate v2 until
//! the session runtime can uphold these payloads' insertion and replay rules.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");

const Writer = std.Io.Writer;
const writeJsonStr = jsonrpc.writeJsonStr;
const max_idempotency_key_characters = 255;

pub const PromptReceipt = struct {
    message_id: []const u8,

    pub fn write(self: PromptReceipt, writer: *Writer) !void {
        try writer.writeAll("{\"messageId\":");
        try writeJsonStr(self.message_id, writer);
        try writer.writeByte('}');
    }
};

pub fn writeAcceptedMessage(writer: *Writer, receipt: PromptReceipt, content: []const std.json.Value) !void {
    try writer.writeAll("{\"sessionUpdate\":\"user_message\",\"messageId\":");
    try writeJsonStr(receipt.message_id, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeByte('}');
}

pub fn idempotencyKey(params: std.json.ObjectMap) error{InvalidIdempotencyKey}!?[]const u8 {
    return validateIdempotencyKey(params.get("idempotencyKey") orelse .null);
}

fn validateIdempotencyKey(value: std.json.Value) error{InvalidIdempotencyKey}!?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |key| blk: {
            if (key.len == 0 or key.len > 4 * max_idempotency_key_characters)
                return error.InvalidIdempotencyKey;
            const count = std.unicode.utf8CountCodepoints(key) catch
                return error.InvalidIdempotencyKey;
            if (count > max_idempotency_key_characters) return error.InvalidIdempotencyKey;
            break :blk key;
        },
        else => error.InvalidIdempotencyKey,
    };
}

pub const ForegroundState = union(enum) {
    running,
    requires_action,
    unknown,
    idle: IdleOutcome,

    pub const IdleOutcome = union(enum) {
        no_reason,
        stopped: acp_types.StopReason,
        failed: jsonrpc.RpcError,
    };

    pub fn write(self: ForegroundState, writer: *Writer) !void {
        try writer.writeAll("{\"sessionUpdate\":\"state_update\",\"state\":");
        try writeJsonStr(@tagName(self), writer);
        switch (self) {
            .running, .requires_action, .unknown => {},
            .idle => |outcome| switch (outcome) {
                .no_reason => {},
                .stopped => |reason| if (stopReason(reason)) |wire_reason| {
                    try writer.writeAll(",\"stopReason\":");
                    try writeJsonStr(wire_reason, writer);
                },
                .failed => |err| {
                    try writer.writeAll(",\"stopReason\":\"error\",\"error\":");
                    // Use the same error encoding as a JSON-RPC error response.
                    try jsonrpc.writeErrorObject(writer, err);
                },
            },
        }
        try writer.writeByte('}');
    }
};

fn stopReason(reason: acp_types.StopReason) ?[]const u8 {
    return switch (reason) {
        .end_turn => "end_turn",
        .max_output_tokens => "max_tokens",
        .max_model_turns => "max_turn_requests",
        .refused => "refusal",
        .cancelled => "cancelled",
        // Yield is a libfx host outcome, not an ACP stop reason.
        .yielded => null,
    };
}

pub const replay_complete = "{\"sessionUpdate\":\"replay_complete\"}";

test "ACP Preview reports prompt insertion separately from foreground state" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try (PromptReceipt{ .message_id = "input-\"1\"" }).write(&out.writer);
    try std.testing.expectEqualStrings("{\"messageId\":\"input-\\\"1\\\"\"}", out.written());

    out.clearRetainingCapacity();
    try (ForegroundState{ .running = {} }).write(&out.writer);
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"state_update\",\"state\":\"running\"}", out.written());

    out.clearRetainingCapacity();
    try (ForegroundState{ .idle = .{ .stopped = .max_model_turns } }).write(&out.writer);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"state_update\",\"state\":\"idle\",\"stopReason\":\"max_turn_requests\"}",
        out.written(),
    );
}

test "ACP Preview accepted message echoes the receipt ID and content" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "[{\"type\":\"text\",\"text\":\"two\\nlines\"}]", .{});
    defer parsed.deinit();
    var out: Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeAcceptedMessage(&out.writer, .{ .message_id = "input-1" }, parsed.value.array.items);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"user_message\",\"messageId\":\"input-1\",\"content\":[{\"type\":\"text\",\"text\":\"two\\nlines\"}]}",
        out.written(),
    );
}

test "ACP Preview idle update carries a post-insertion error" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try (ForegroundState{ .idle = .{ .failed = .{
        .code = jsonrpc.ErrorCode.internal_error,
        .message = "turn ended\nwith an error",
        .data = .{ .code = "test", .model = "fixture", .capability = "test" },
    } } }).write(&out.writer);
    const obj = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer obj.deinit();
    try std.testing.expectEqualStrings("idle", obj.value.object.get("state").?.string);
    try std.testing.expectEqualStrings("error", obj.value.object.get("stopReason").?.string);
    const err = obj.value.object.get("error").?.object;
    try std.testing.expectEqual(jsonrpc.ErrorCode.internal_error, err.get("code").?.integer);
    try std.testing.expectEqualStrings("turn ended\nwith an error", err.get("message").?.string);
    try std.testing.expectEqualStrings("fixture", err.get("data").?.object.get("model").?.string);
}

test "ACP Preview rejects malformed idempotency keys instead of treating them as absent" {
    const alloc = std.testing.allocator;
    const samples = [_]struct { json: []const u8, expected: error{InvalidIdempotencyKey}!?[]const u8 }{
        .{ .json = "{}", .expected = null },
        .{ .json = "{\"idempotencyKey\":null}", .expected = null },
        .{ .json = "{\"idempotencyKey\":\"Case sensitive\"}", .expected = "Case sensitive" },
        .{ .json = "{\"idempotencyKey\":\"\"}", .expected = error.InvalidIdempotencyKey },
        .{ .json = "{\"idempotencyKey\":9}", .expected = error.InvalidIdempotencyKey },
    };
    for (samples) |sample| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, sample.json, .{});
        defer parsed.deinit();
        const decoded = idempotencyKey(parsed.value.object);
        if (sample.expected) |expected| {
            if (expected) |key| {
                try std.testing.expectEqualStrings(key, (try decoded).?);
            } else {
                try std.testing.expectEqual(@as(?[]const u8, null), try decoded);
            }
        } else |err| {
            try std.testing.expectError(err, decoded);
        }
    }
    const accepted = repeatedTestKey(255);
    try std.testing.expectEqualStrings(&accepted, (try validateIdempotencyKey(.{ .string = &accepted })).?);
    try std.testing.expectError(error.InvalidIdempotencyKey, validateIdempotencyKey(.{ .string = &repeatedTestKey(256) }));
}

fn repeatedTestKey(comptime count: usize) [count * 2]u8 {
    var bytes: [count * 2]u8 = undefined;
    for (0..count) |i| {
        bytes[2 * i] = 0xc3;
        bytes[2 * i + 1] = 0xa9;
    }
    return bytes;
}

fn fuzzKey(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4 * max_idempotency_key_characters + 1]u8 = undefined;
    const key = bytes[0..smith.slice(&bytes)];
    const accepted = validateIdempotencyKey(.{ .string = key }) catch return;
    try std.testing.expectEqualStrings(key, accepted.?);
    const count = try std.unicode.utf8CountCodepoints(key);
    try std.testing.expect(count >= 1 and count <= max_idempotency_key_characters);
}

test "ACP Preview accepts only bounded Unicode idempotency keys on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzKey, .{
        .corpus = &(@import("fuzz_seed").slices(.{ "", "first", &repeatedTestKey(255), &repeatedTestKey(256), "\xff" }) ++
            @import("fuzz_corpus").acp_preview_idempotency_key.*),
    });
}

const std = @import("std");
const types = @import("../../shared/types.zig");
const session_codec = @import("../../session/session_codec.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic = "FXCP";
const version: u16 = 1;
const header_bytes: usize = 4 + 2 + 2 + 4 + Sha256.digest_length;
pub const max_checkpoint_bytes: usize = 4 * 1024 * 1024;
pub const max_history_turns: usize = 1024;

pub const Error = Allocator.Error || error{
    CheckpointTooLarge,
    CorruptCheckpoint,
    InvalidCheckpoint,
    UnsupportedCheckpointVersion,
};

pub const Decoded = struct {
    history: []types.HistoryTurn,
    usage: types.Usage,

    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

pub fn encode(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    usage: types.Usage,
) Error![]u8 {
    if (history.len > max_history_turns) return error.CheckpointTooLarge;
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    payload.writer.writeAll("{\"history\":[") catch return error.OutOfMemory;
    for (history, 0..) |turn, index| {
        if (index > 0) payload.writer.writeByte(',') catch return error.OutOfMemory;
        session_codec.writeHistoryTurn(&payload.writer, turn) catch
            return error.OutOfMemory;
        if (payload.written().len > max_checkpoint_bytes - header_bytes) {
            return error.CheckpointTooLarge;
        }
    }
    payload.writer.writeAll("],\"usage\":") catch return error.OutOfMemory;
    std.json.Stringify.value(usage, .{}, &payload.writer) catch return error.OutOfMemory;
    payload.writer.writeByte('}') catch return error.OutOfMemory;
    if (payload.written().len > max_checkpoint_bytes - header_bytes) {
        return error.CheckpointTooLarge;
    }

    const out = try alloc.alloc(u8, header_bytes + payload.written().len);
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u16, out[4..6], version, .little);
    std.mem.writeInt(u16, out[6..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(payload.written().len), .little);
    Sha256.hash(payload.written(), out[12..header_bytes], .{});
    @memcpy(out[header_bytes..], payload.written());
    return out;
}

pub fn decode(alloc: Allocator, bytes: []const u8) Error!Decoded {
    if (bytes.len < header_bytes or bytes.len > max_checkpoint_bytes) {
        return error.CorruptCheckpoint;
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.CorruptCheckpoint;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) {
        return error.UnsupportedCheckpointVersion;
    }
    if (std.mem.readInt(u16, bytes[6..8], .little) != 0) {
        return error.CorruptCheckpoint;
    }
    const payload_len: usize = std.mem.readInt(u32, bytes[8..12], .little);
    if (payload_len != bytes.len - header_bytes) return error.CorruptCheckpoint;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_bytes..], &digest, .{});
    if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest, bytes[12..header_bytes].*)) {
        return error.CorruptCheckpoint;
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        bytes[header_bytes..],
        .{},
    ) catch return error.InvalidCheckpoint;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCheckpoint;
    const history_value = parsed.value.object.get("history") orelse
        return error.InvalidCheckpoint;
    const usage_value = parsed.value.object.get("usage") orelse
        return error.InvalidCheckpoint;
    if (history_value != .array or history_value.array.items.len > max_history_turns) {
        return error.InvalidCheckpoint;
    }
    const history = try alloc.alloc(types.HistoryTurn, history_value.array.items.len);
    var decoded_count: usize = 0;
    errdefer {
        for (history[0..decoded_count]) |turn| types.freeHistoryTurn(alloc, turn);
        alloc.free(history);
    }
    for (history_value.array.items, 0..) |turn_value, index| {
        history[index] = session_codec.parseHistoryTurn(alloc, turn_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCheckpoint,
        };
        decoded_count += 1;
    }
    const usage = std.json.parseFromValueLeaky(types.Usage, alloc, usage_value, .{}) catch
        return error.InvalidCheckpoint;
    return .{ .history = history, .usage = usage };
}

test "kernel checkpoint round trips history and usage" {
    const alloc = std.testing.allocator;
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("hello") },
        .assistant = @constCast("world"),
    } }};
    const bytes = try encode(alloc, &history, .{ .input_tokens = 3, .output_tokens = 2 });
    defer alloc.free(bytes);
    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), decoded.history.len);
    try std.testing.expectEqualStrings("hello", decoded.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("world", decoded.history[0].assistant.assistant);
    try std.testing.expectEqual(@as(?u64, 3), decoded.usage.input_tokens);
}

test "kernel checkpoint rejects corruption and unsupported versions" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, &.{}, .{});
    defer alloc.free(bytes);

    const corrupt = try alloc.dupe(u8, bytes);
    defer alloc.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.CorruptCheckpoint, decode(alloc, corrupt));

    const unsupported = try alloc.dupe(u8, bytes);
    defer alloc.free(unsupported);
    std.mem.writeInt(u16, unsupported[4..6], version + 1, .little);
    try std.testing.expectError(
        error.UnsupportedCheckpointVersion,
        decode(alloc, unsupported),
    );
}

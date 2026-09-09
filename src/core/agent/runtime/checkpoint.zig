const std = @import("std");
const types = @import("../../shared/types.zig");
const session_codec = @import("../../session/session_codec.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic = "FXCP";
const version: u16 = 2;
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
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null,

    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        if (self.recovery_checkpoint) |*pending| pending.deinit(alloc);
        self.* = undefined;
    }
};

pub fn encode(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    usage: types.Usage,
) Error![]u8 {
    return encodeWithRecovery(alloc, history, usage, null);
}

pub fn encodeWithRecovery(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    usage: types.Usage,
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint,
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
    if (recovery_checkpoint) |pending| {
        payload.writer.writeAll(",\"recovery_checkpoint\":") catch return error.OutOfMemory;
        session_codec.writeRecoveryCheckpoint(&payload.writer, pending) catch |err| return switch (err) {
            error.InvalidDurableField => error.InvalidCheckpoint,
            else => error.OutOfMemory,
        };
    }
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
    const encoded_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (encoded_version != 1 and encoded_version != version) {
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
    var recovery_checkpoint = if (parsed.value.object.get("recovery_checkpoint")) |value| pending: {
        if (encoded_version == 1) return error.InvalidCheckpoint;
        break :pending session_codec.parseRecoveryCheckpoint(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCheckpoint,
        };
    } else null;
    errdefer if (recovery_checkpoint) |*pending| pending.deinit(alloc);
    if (recovery_checkpoint != null) {
        // Reuse the shared session codec's semantic validation rather than a
        // second set of SDK recovery/authority checks. This borrowed envelope
        // is validation-only; synthetic session metadata is never persisted.
        session_codec.validateState(.{
            .id = @constCast("libfx"),
            .origin_workspace_root = @constCast("/"),
            .workspace_root = @constCast("/"),
            .created_at_ms = 0,
            .updated_at_ms = 0,
            .conversation_language = .literal("en"),
            .preferences = .{ .model = @constCast("libfx/checkpoint"), .effort = .auto, .fast_mode = false },
            .history = history,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .recovery_checkpoint = recovery_checkpoint,
        }) catch return error.InvalidCheckpoint;
    }
    return .{ .history = history, .usage = usage, .recovery_checkpoint = recovery_checkpoint };
}

/// Status projection only. The orchestrator still admits every actual resume.
pub fn canResume(pending: session_codec.RecoveryCheckpoint) bool {
    const suspension = @import("suspension.zig");
    return pending.disposition == .continuable and suspension.decide(.{
        .boundary = .resume_request,
        .tool = @enumFromInt(@intFromEnum(pending.tool_state)),
        .checkpoint = .durable,
    }) == .resume_request;
}

test "kernel checkpoint carries pending shared recovery without creating history" {
    const alloc = std.testing.allocator;
    var pending: session_codec.RecoveryCheckpoint = .{
        .turn_id = 7,
        .user = .{ .text = @constCast("pending prompt") },
        .assistant_source = @constCast("partial response"),
        .cause = .system_resumed,
        .action = .paused,
        .tool_state = .uncertain,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 1,
    };
    const bytes = try encodeWithRecovery(alloc, &.{}, .{}, pending);
    defer alloc.free(bytes);
    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), decoded.history.len);
    try std.testing.expectEqualStrings("pending prompt", decoded.recovery_checkpoint.?.user.text);
    try std.testing.expectEqual(session_codec.RecoveryToolState.uncertain, decoded.recovery_checkpoint.?.tool_state);
    try std.testing.expect(!canResume(decoded.recovery_checkpoint.?));

    pending.turn_id = 0;
    const invalid = try encodeWithRecovery(alloc, &.{}, .{}, pending);
    defer alloc.free(invalid);
    try std.testing.expectError(error.InvalidCheckpoint, decode(alloc, invalid));
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    try std.testing.expectError(error.InvalidCheckpoint, decode(alloc, bytes));
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

test "kernel checkpoint decodes version one history-only bytes" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, &.{}, .{});
    defer alloc.free(bytes);
    // V1 used this exact header and payload shape, without recovery_checkpoint.
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    try std.testing.expect(decoded.recovery_checkpoint == null);
    try std.testing.expectEqual(@as(usize, 0), decoded.history.len);
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

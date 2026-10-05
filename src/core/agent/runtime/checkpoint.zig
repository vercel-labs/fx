const std = @import("std");
const types = @import("../../shared/types.zig");
const session_codec = @import("../../session/session_codec.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic = "FXCP";
/// Version 2 stores inline image bytes raw in a blob section after the JSON.
/// Its little-endian payload is:
///   u32 json_len | json | u32 blob_count | (u32 blob_len | blob)*
const version: u16 = 2;
/// Version 1 embedded inline image bytes as base64 inside a JSON-only payload.
const json_only_version: u16 = 1;
const header_bytes: usize = 4 + 2 + 2 + 4 + Sha256.digest_length;
const length_bytes: usize = 4;
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
    const payload_limit = max_checkpoint_bytes - header_bytes;
    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    var blobs: std.ArrayList([]const u8) = .empty;
    defer blobs.deinit(alloc);
    const image_blobs: session_codec.ImageBlobs = .{ .alloc = alloc, .items = &blobs };
    var blob_section_bytes: usize = 0;

    json.writer.writeAll("{\"history\":[") catch return error.OutOfMemory;
    for (history, 0..) |turn, index| {
        if (index > 0) json.writer.writeByte(',') catch return error.OutOfMemory;
        const first_new_blob = blobs.items.len;
        session_codec.writeHistoryTurnWithImageBlobs(&json.writer, turn, image_blobs) catch |err| switch (err) {
            error.InvalidSessionFormat => return error.InvalidCheckpoint,
            else => return error.OutOfMemory,
        };
        for (blobs.items[first_new_blob..]) |blob| blob_section_bytes +|= length_bytes +| blob.len;
        if (payloadBytes(json.written().len, blob_section_bytes) > payload_limit) {
            return error.CheckpointTooLarge;
        }
    }
    json.writer.writeAll("],\"usage\":") catch return error.OutOfMemory;
    std.json.Stringify.value(usage, .{}, &json.writer) catch return error.OutOfMemory;
    json.writer.writeByte('}') catch return error.OutOfMemory;
    const payload_len = payloadBytes(json.written().len, blob_section_bytes);
    if (payload_len > payload_limit) return error.CheckpointTooLarge;

    // Every length below is bounded by payload_limit, so each fits in a u32.
    const out = try alloc.alloc(u8, header_bytes + payload_len);
    var cursor: usize = header_bytes;
    writeSection(out, &cursor, json.written());
    writeLength(out, &cursor, blobs.items.len);
    for (blobs.items) |blob| writeSection(out, &cursor, blob);
    std.debug.assert(cursor == out.len);

    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u16, out[4..6], version, .little);
    std.mem.writeInt(u16, out[6..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(payload_len), .little);
    Sha256.hash(out[header_bytes..], out[12..header_bytes], .{});
    return out;
}

fn payloadBytes(json_len: usize, blob_section_bytes: usize) usize {
    return length_bytes +| json_len +| length_bytes +| blob_section_bytes;
}

fn writeLength(out: []u8, cursor: *usize, value: usize) void {
    std.mem.writeInt(u32, out[cursor.*..][0..length_bytes], @intCast(value), .little);
    cursor.* += length_bytes;
}

fn writeSection(out: []u8, cursor: *usize, bytes: []const u8) void {
    writeLength(out, cursor, bytes.len);
    @memcpy(out[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

pub fn decode(alloc: Allocator, bytes: []const u8) Error!Decoded {
    if (bytes.len < header_bytes or bytes.len > max_checkpoint_bytes) {
        return error.CorruptCheckpoint;
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.CorruptCheckpoint;
    const checkpoint_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (checkpoint_version != version and checkpoint_version != json_only_version) {
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
    const payload = bytes[header_bytes..];
    if (checkpoint_version == json_only_version) return decodeJson(alloc, payload, null);

    var reader: PayloadReader = .{ .bytes = payload };
    const json = reader.section() orelse return error.CorruptCheckpoint;
    const blob_count = reader.length() orelse return error.CorruptCheckpoint;
    // Every blob needs at least its length prefix.
    if (blob_count > reader.remaining() / length_bytes) return error.CorruptCheckpoint;
    const blobs = try alloc.alloc([]const u8, blob_count);
    defer alloc.free(blobs);
    for (blobs) |*blob| blob.* = reader.section() orelse return error.CorruptCheckpoint;
    if (reader.remaining() != 0) return error.CorruptCheckpoint;
    var blob_reader: session_codec.ImageBlobReader = .{ .blobs = blobs };
    return decodeJson(alloc, json, &blob_reader);
}

/// Reads length-prefixed sections from a version 2 payload. Returned slices
/// borrow from `bytes`.
const PayloadReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn remaining(self: PayloadReader) usize {
        return self.bytes.len - self.offset;
    }

    fn length(self: *PayloadReader) ?usize {
        if (self.remaining() < length_bytes) return null;
        const value = std.mem.readInt(u32, self.bytes[self.offset..][0..length_bytes], .little);
        self.offset += length_bytes;
        return value;
    }

    fn section(self: *PayloadReader) ?[]const u8 {
        const len = self.length() orelse return null;
        if (len > self.remaining()) return null;
        const bytes = self.bytes[self.offset..][0..len];
        self.offset += len;
        return bytes;
    }
};

fn decodeJson(alloc: Allocator, json: []const u8, image_blobs: ?*session_codec.ImageBlobReader) Error!Decoded {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json,
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
        history[index] = session_codec.parseHistoryTurnWithImageBlobs(alloc, turn_value, image_blobs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCheckpoint,
        };
        decoded_count += 1;
    }
    if (image_blobs) |blobs| {
        if (!blobs.consumedAll()) return error.InvalidCheckpoint;
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

test "kernel checkpoint reports invalid presentation authority" {
    const alloc = std.testing.allocator;
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("edit-1"),
        .tool_name = @constCast("edit_file"),
        .status = .success,
        .output = @constCast("edited"),
        .output_bytes = 6,
        .stored_output_bytes = 6,
        .committed_file_presentation = .{
            .path = "src/a.zig",
            .kind = .edited,
            .lines = &.{},
            .additions = 1,
            .deletions = 1,
            .truncated = false,
            .previous_content = "before",
            .after_content = "after",
            .content_handle = "diff-0123456789abcdef-0123456789abcdef.json",
        },
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_results = &results }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("edit") },
        .assistant = @constCast("edited"),
        .execution = .{ .tool_steps = &steps },
    } }};
    try std.testing.expectError(error.InvalidCheckpoint, encode(alloc, &history, .{}));
}

test "kernel checkpoint round trips inline prompt images" {
    const alloc = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\nkernel-checkpoint";
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(png, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var images = [_]types.ImageAttachment{.{
        .id = 5,
        .path = @constCast("inline://image-5"),
        .media_type = @constCast("image/png"),
        .snapshot_sha256 = @constCast(&digest_hex),
        .inline_data = @constCast(png),
    }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("look [Image #5]"), .images = &images },
        .assistant = @constCast("a red square"),
    } }};
    const bytes = try encode(alloc, &history, .{});
    defer alloc.free(bytes);

    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    const restored = decoded.history[0].assistant.user.images[0];
    try std.testing.expectEqual(@as(usize, 5), restored.id);
    try std.testing.expectEqual(@as(?[]const u8, null), restored.snapshot_path);
    try std.testing.expectEqualStrings(png, restored.inline_data.?);
    try std.testing.expectEqualStrings(&digest_hex, restored.snapshot_sha256.?);
}

test "kernel checkpoint bound applies to history carrying inline images" {
    const alloc = std.testing.allocator;
    const oversized = try alloc.alloc(u8, max_checkpoint_bytes);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    @memcpy(oversized[0..8], "\x89PNG\r\n\x1a\n");
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("inline://image-1"),
        .media_type = @constCast("image/png"),
        .inline_data = oversized,
    }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("[Image #1]"), .images = &images },
        .assistant = @constCast("done"),
    } }};
    try std.testing.expectError(error.CheckpointTooLarge, encode(alloc, &history, .{}));
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

fn resealForTest(bytes: []u8) void {
    std.mem.writeInt(u32, bytes[8..12], @intCast(bytes.len - header_bytes), .little);
    Sha256.hash(bytes[header_bytes..], bytes[12..header_bytes], .{});
}

const TestImageHistory = struct {
    digest_hex: [Sha256.digest_length * 2]u8,
    images: [1]types.ImageAttachment,
    history: [1]types.HistoryTurn,

    fn init(self: *TestImageHistory, png: []const u8) void {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(png, &digest, .{});
        self.digest_hex = std.fmt.bytesToHex(digest, .lower);
        self.images = .{.{
            .id = 2,
            .path = @constCast("inline://image-2"),
            .media_type = @constCast("image/png"),
            .snapshot_sha256 = &self.digest_hex,
            .inline_data = @constCast(png),
        }};
        self.history = .{.{ .assistant = .{
            .user = .{ .text = @constCast("[Image #2]"), .images = &self.images },
            .assistant = @constCast("ok"),
        } }};
    }
};

test "kernel checkpoint stores inline image bytes raw beside the JSON" {
    const alloc = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\nraw-checkpoint-bytes";
    var fixture: TestImageHistory = undefined;
    fixture.init(png);
    const bytes = try encode(alloc, &fixture.history, .{});
    defer alloc.free(bytes);

    try std.testing.expectEqual(version, std.mem.readInt(u16, bytes[4..6], .little));
    // The only blob is the image itself, unencoded, at the end of the payload.
    try std.testing.expect(std.mem.endsWith(u8, bytes, png));
    try std.testing.expect(std.mem.find(u8, bytes, "\"inline_blob\":0") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"inline_data\"") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"encoding\":\"base64\"") == null);

    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(png, decoded.history[0].assistant.user.images[0].inline_data.?);
}

test "kernel checkpoint decodes version 1 checkpoints with base64 images" {
    const alloc = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\nlegacy-checkpoint";
    var fixture: TestImageHistory = undefined;
    fixture.init(png);
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"history\":[");
    try session_codec.writeHistoryTurn(&payload.writer, fixture.history[0]);
    try payload.writer.writeAll("],\"usage\":");
    try std.json.Stringify.value(types.Usage{}, .{}, &payload.writer);
    try payload.writer.writeByte('}');

    const legacy = try alloc.alloc(u8, header_bytes + payload.written().len);
    defer alloc.free(legacy);
    @memcpy(legacy[0..magic.len], magic);
    std.mem.writeInt(u16, legacy[4..6], json_only_version, .little);
    std.mem.writeInt(u16, legacy[6..8], 0, .little);
    @memcpy(legacy[header_bytes..], payload.written());
    resealForTest(legacy);
    try std.testing.expect(std.mem.find(u8, legacy, "\"encoding\":\"base64\"") != null);

    var decoded = try decode(alloc, legacy);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(png, decoded.history[0].assistant.user.images[0].inline_data.?);
}

test "kernel checkpoint rejects malformed blob sections" {
    const alloc = std.testing.allocator;
    var fixture: TestImageHistory = undefined;
    fixture.init("\x89PNG\r\n\x1a\nblob-section");
    const bytes = try encode(alloc, &fixture.history, .{});
    defer alloc.free(bytes);

    const dangling = try alloc.dupe(u8, bytes);
    defer alloc.free(dangling);
    const reference = "\"inline_blob\":";
    const at = std.mem.find(u8, dangling, reference).? + reference.len;
    dangling[at] = '7';
    resealForTest(dangling);
    try std.testing.expectError(error.InvalidCheckpoint, decode(alloc, dangling));

    const truncated = try alloc.dupe(u8, bytes[0 .. bytes.len - 1]);
    defer alloc.free(truncated);
    resealForTest(truncated);
    try std.testing.expectError(error.CorruptCheckpoint, decode(alloc, truncated));

    const trailing = try alloc.alloc(u8, bytes.len + 1);
    defer alloc.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;
    resealForTest(trailing);
    try std.testing.expectError(error.CorruptCheckpoint, decode(alloc, trailing));
}

test "kernel checkpoint requires each image blob once, in order" {
    const alloc = std.testing.allocator;
    var first: TestImageHistory = undefined;
    first.init("\x89PNG\r\n\x1a\nfirst-blob");
    var second: TestImageHistory = undefined;
    second.init("\x89PNG\r\n\x1a\nsecond-blob");
    const history = [_]types.HistoryTurn{ first.history[0], second.history[0] };
    const bytes = try encode(alloc, &history, .{});
    defer alloc.free(bytes);
    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nsecond-blob", decoded.history[1].assistant.user.images[0].inline_data.?);

    const reference = "\"inline_blob\":";
    const first_digit = std.mem.find(u8, bytes, reference ++ "0").? + reference.len;
    const second_digit = std.mem.find(u8, bytes, reference ++ "1").? + reference.len;

    const swapped = try alloc.dupe(u8, bytes);
    defer alloc.free(swapped);
    swapped[first_digit] = '1';
    swapped[second_digit] = '0';
    resealForTest(swapped);
    try std.testing.expectError(error.InvalidCheckpoint, decode(alloc, swapped));

    const duplicated = try alloc.dupe(u8, bytes);
    defer alloc.free(duplicated);
    duplicated[second_digit] = '0';
    resealForTest(duplicated);
    try std.testing.expectError(error.InvalidCheckpoint, decode(alloc, duplicated));

    const extra_blob = "\x89PNG\r\n\x1a\nunreferenced";
    const unreferenced = try alloc.alloc(u8, bytes.len + length_bytes + extra_blob.len);
    defer alloc.free(unreferenced);
    @memcpy(unreferenced[0..bytes.len], bytes);
    var offset = bytes.len;
    writeSection(unreferenced, &offset, extra_blob);
    const json_len = std.mem.readInt(u32, bytes[header_bytes..][0..length_bytes], .little);
    const count_at = header_bytes + length_bytes + json_len;
    std.mem.writeInt(u32, unreferenced[count_at..][0..length_bytes], 3, .little);
    resealForTest(unreferenced);
    try std.testing.expectError(error.InvalidCheckpoint, decode(alloc, unreferenced));
}

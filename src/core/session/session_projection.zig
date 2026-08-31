const std = @import("std");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const model_provider = @import("../config/model_provider.zig");
const session_event = @import("session_event.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const manifest_max_bytes: usize = 64 * 1024;
pub const checkpoint_max_bytes: usize = 32 * 1024 * 1024;
pub const Digest = [Sha256.digest_length]u8;

pub const Manifest = struct {
    id: []u8,
    authority_id: session_event.Identifier,
    log_generation: session_event.Identifier,
    created_at_ms: i64,
    updated_at_ms: i64,
    origin_workspace_root: []u8,
    workspace_root: []u8,
    conversation_language: session.ConversationLanguage,
    history_len: u64,
    total_input_tokens: u64,
    total_output_tokens: u64,
    last_event_seq: u64,
    event_log_bytes: u64,
    event_log_stat_fingerprint: Digest,
    generation_base_seq: u64,
    generation_base_bytes: u64,
    checkpoint_seq: ?u64,
    checkpoint_sha256: ?Digest,
    preferences: session_codec.DurableSessionPreferences,

    pub fn deinit(self: *Manifest, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin_workspace_root);
        alloc.free(self.workspace_root);
        self.preferences.deinit(alloc);
        self.* = undefined;
    }
};

pub const EventFileKind = enum(u8) {
    regular = 1,
    directory = 2,
    symbolic_link = 3,
    other = 255,
};

pub const EventFileStat = struct {
    device: u64,
    inode: u64,
    kind: EventFileKind,
    mode: u64,
    link_count: u64,
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,
};

pub const Checkpoint = struct {
    session_id: []u8,
    log_generation: session_event.Identifier,
    through_seq: u64,
    through_event_id: session_event.Identifier,
    through_event_log_bytes: u64,
    state: session_codec.DurableSessionState,

    pub fn deinit(self: *Checkpoint, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.state.deinit(alloc);
        self.* = undefined;
    }
};

inline fn failCheckpoint(err: anytype) @TypeOf(err)!Checkpoint {
    return @errorCast(failCheckpointDynamic(err));
}

noinline fn failCheckpointDynamic(err: anyerror) anyerror!Checkpoint {
    return err;
}

test "checkpoint failures preserve exact error types and identities" {
    const invalid = failCheckpoint(error.InvalidCheckpoint);
    try std.testing.expect(
        @TypeOf(invalid) == error{InvalidCheckpoint}!Checkpoint,
    );
    try std.testing.expectError(error.InvalidCheckpoint, invalid);
    try std.testing.expectError(
        error.CheckpointTooLarge,
        failCheckpoint(error.CheckpointTooLarge),
    );
    try std.testing.expectError(error.OutOfMemory, failCheckpoint(error.OutOfMemory));
}

pub const EventBoundary = struct {
    log_generation: session_event.Identifier,
    seq: u64,
    event_id: session_event.Identifier,
    event_log_bytes: u64,
    semantic: bool,
};

pub fn encodeManifest(alloc: Allocator, manifest: Manifest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll(
        "{\"schema_version\":3,\"storage_format\":\"event_log_v1\",\"id\":",
    );
    try writeJsonString(&out.writer, manifest.id);
    try out.writer.writeAll(",\"authority_id\":");
    try writeHexString(&out.writer, &manifest.authority_id);
    try out.writer.writeAll(",\"log_generation\":");
    try writeHexString(&out.writer, &manifest.log_generation);
    try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
        manifest.created_at_ms,
        manifest.updated_at_ms,
    });
    try out.writer.writeAll(",\"origin_workspace_root\":");
    try writeJsonString(&out.writer, manifest.origin_workspace_root);
    try out.writer.writeAll(",\"workspace_root\":");
    try writeJsonString(&out.writer, manifest.workspace_root);
    try out.writer.writeAll(",\"conversation_language\":");
    try writeJsonString(&out.writer, manifest.conversation_language.view());
    try out.writer.print(
        ",\"history_len\":{d},\"total_input_tokens\":{d},\"total_output_tokens\":{d},\"last_event_seq\":{d},\"event_log_bytes\":{d},\"event_log_stat_fingerprint\":",
        .{
            manifest.history_len,
            manifest.total_input_tokens,
            manifest.total_output_tokens,
            manifest.last_event_seq,
            manifest.event_log_bytes,
        },
    );
    try writeHexString(&out.writer, &manifest.event_log_stat_fingerprint);
    try out.writer.print(",\"generation_base_seq\":{d},\"generation_base_bytes\":{d},\"checkpoint_seq\":", .{
        manifest.generation_base_seq,
        manifest.generation_base_bytes,
    });
    if (manifest.checkpoint_seq) |seq| {
        try out.writer.print("{d}", .{seq});
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"checkpoint_sha256\":");
    if (manifest.checkpoint_sha256) |digest| {
        try writeHexString(&out.writer, &digest);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"preferences\":");
    try writePreferences(&out.writer, manifest.preferences);
    try out.writer.writeByte('}');

    if (out.written().len > manifest_max_bytes) return error.ManifestTooLarge;
    try validateManifest(manifest);
    return try out.toOwnedSlice();
}

pub fn decodeManifest(alloc: Allocator, bytes: []const u8) !Manifest {
    if (bytes.len == 0 or bytes.len > manifest_max_bytes) return error.ManifestTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();
    const root = try exactObject(parsed.value, &.{
        "schema_version",
        "storage_format",
        "id",
        "authority_id",
        "log_generation",
        "created_at_ms",
        "updated_at_ms",
        "origin_workspace_root",
        "workspace_root",
        "conversation_language",
        "history_len",
        "total_input_tokens",
        "total_output_tokens",
        "last_event_seq",
        "event_log_bytes",
        "event_log_stat_fingerprint",
        "generation_base_seq",
        "generation_base_bytes",
        "checkpoint_seq",
        "checkpoint_sha256",
        "preferences",
    });
    if (try requireU64(root, "schema_version") != 3 or
        !std.mem.eql(u8, try requireString(root, "storage_format"), "event_log_v1"))
    {
        return error.InvalidManifest;
    }
    const id = try dupeString(alloc, root, "id");
    errdefer alloc.free(id);
    const origin = try dupeString(alloc, root, "origin_workspace_root");
    errdefer alloc.free(origin);
    const current = try dupeString(alloc, root, "workspace_root");
    errdefer alloc.free(current);
    const preferences = try parsePreferences(
        alloc,
        root.get("preferences") orelse return error.InvalidManifest,
    );
    errdefer {
        var owned = preferences;
        owned.deinit(alloc);
    }
    const manifest = Manifest{
        .id = id,
        .authority_id = try parseIdentifier(try requireString(root, "authority_id")),
        .log_generation = try parseIdentifier(try requireString(root, "log_generation")),
        .created_at_ms = try requireI64(root, "created_at_ms"),
        .updated_at_ms = try requireI64(root, "updated_at_ms"),
        .origin_workspace_root = origin,
        .workspace_root = current,
        .conversation_language = session_codec.parseConversationLanguage(
            try requireString(root, "conversation_language"),
        ) catch return error.InvalidManifest,
        .history_len = try requireU64(root, "history_len"),
        .total_input_tokens = try requireU64(root, "total_input_tokens"),
        .total_output_tokens = try requireU64(root, "total_output_tokens"),
        .last_event_seq = try requireU64(root, "last_event_seq"),
        .event_log_bytes = try requireU64(root, "event_log_bytes"),
        .event_log_stat_fingerprint = try parseDigest(
            try requireString(root, "event_log_stat_fingerprint"),
        ),
        .generation_base_seq = try requireU64(root, "generation_base_seq"),
        .generation_base_bytes = try requireU64(root, "generation_base_bytes"),
        .checkpoint_seq = try optionalU64(root.get("checkpoint_seq") orelse
            return error.InvalidManifest),
        .checkpoint_sha256 = try optionalDigest(root.get("checkpoint_sha256") orelse
            return error.InvalidManifest),
        .preferences = preferences,
    };
    try validateManifest(manifest);
    return manifest;
}

pub fn eventFileStatFingerprint(stat: EventFileStat, expected_size: u64) !Digest {
    if (stat.kind != .regular or stat.link_count != 1 or stat.size != expected_size) {
        return error.InvalidEventFileStat;
    }

    var encoded: [8 * 5 + 16 * 2 + 1]u8 = undefined;
    var offset: usize = 0;
    encoded[offset] = @intFromEnum(stat.kind);
    offset += 1;
    writeInt(&encoded, &offset, u64, stat.device);
    writeInt(&encoded, &offset, u64, stat.inode);
    writeInt(&encoded, &offset, u64, stat.mode);
    writeInt(&encoded, &offset, u64, stat.link_count);
    writeInt(&encoded, &offset, u64, stat.size);
    writeInt(&encoded, &offset, i128, stat.mtime_ns);
    writeInt(&encoded, &offset, i128, stat.ctime_ns);

    var hasher = Sha256.init(.{});
    hasher.update("fx:event-file-stat:v1\x00");
    hasher.update(encoded[0..offset]);
    return hasher.finalResult();
}

pub fn isManifestStale(manifest: Manifest, current: EventFileStat) bool {
    const current_fingerprint = eventFileStatFingerprint(current, manifest.event_log_bytes) catch
        return true;
    return !std.mem.eql(
        u8,
        &manifest.event_log_stat_fingerprint,
        &current_fingerprint,
    );
}

pub fn stateMatchesManifest(
    state: session_codec.DurableSessionState,
    manifest: Manifest,
) bool {
    return std.mem.eql(u8, state.id, manifest.id) and
        std.mem.eql(
            u8,
            state.origin_workspace_root,
            manifest.origin_workspace_root,
        ) and
        std.mem.eql(u8, state.workspace_root, manifest.workspace_root) and
        state.created_at_ms == manifest.created_at_ms and
        state.updated_at_ms == manifest.updated_at_ms and
        std.mem.eql(
            u8,
            state.conversation_language.view(),
            manifest.conversation_language.view(),
        ) and
        state.history.len == manifest.history_len and
        state.total_input_tokens == manifest.total_input_tokens and
        state.total_output_tokens == manifest.total_output_tokens and
        durablePreferencesEqual(state.preferences, manifest.preferences);
}

fn durablePreferencesEqual(
    left: session_codec.DurableSessionPreferences,
    right: session_codec.DurableSessionPreferences,
) bool {
    return std.mem.eql(u8, left.model, right.model) and
        left.provider == right.provider and
        left.effort.eql(right.effort) and
        left.fast_mode == right.fast_mode;
}

pub fn encodeCheckpoint(alloc: Allocator, checkpoint: Checkpoint) ![]u8 {
    try validateCheckpoint(checkpoint);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try writeJsonString(&out.writer, checkpoint.session_id);
    try out.writer.writeAll(",\"log_generation\":");
    try writeHexString(&out.writer, &checkpoint.log_generation);
    try out.writer.print(",\"through_seq\":{d},\"through_event_id\":", .{
        checkpoint.through_seq,
    });
    try writeHexString(&out.writer, &checkpoint.through_event_id);
    try out.writer.print(",\"through_event_log_bytes\":{d},\"state\":", .{
        checkpoint.through_event_log_bytes,
    });
    _ = try session_codec.encodeState(checkpoint.state, &out.writer);
    try out.writer.writeByte('}');

    if (out.written().len > checkpoint_max_bytes) return error.CheckpointTooLarge;
    return try out.toOwnedSlice();
}

pub fn decodeCheckpoint(alloc: Allocator, bytes: []const u8) !Checkpoint {
    return decodeCheckpointImpl(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return failCheckpoint(error.OutOfMemory),
        error.CheckpointTooLarge => return failCheckpoint(error.CheckpointTooLarge),
        else => return failCheckpoint(error.InvalidCheckpoint),
    };
}

fn decodeCheckpointImpl(alloc: Allocator, bytes: []const u8) !Checkpoint {
    if (bytes.len == 0 or bytes.len > checkpoint_max_bytes) return error.CheckpointTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCheckpoint,
    };
    defer parsed.deinit();
    const root = try exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
        "state",
    });
    if (try requireU64(root, "schema_version") != 1) return error.InvalidCheckpoint;

    var state_json: std.Io.Writer.Allocating = .init(alloc);
    defer state_json.deinit();
    try std.json.Stringify.value(
        root.get("state") orelse return error.InvalidCheckpoint,
        .{},
        &state_json.writer,
    );
    var state_source = std.Io.Reader.fixed(state_json.written());
    var state = session_codec.decodeState(alloc, &state_source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCheckpoint,
    };
    errdefer state.deinit(alloc);
    const session_id = try dupeString(alloc, root, "session_id");
    errdefer alloc.free(session_id);
    const checkpoint = Checkpoint{
        .session_id = session_id,
        .log_generation = try parseIdentifier(try requireString(root, "log_generation")),
        .through_seq = try requireU64(root, "through_seq"),
        .through_event_id = try parseIdentifier(try requireString(root, "through_event_id")),
        .through_event_log_bytes = try requireU64(root, "through_event_log_bytes"),
        .state = state,
    };
    try validateCheckpoint(checkpoint);
    return checkpoint;
}

pub fn validateCheckpointReference(
    manifest: Manifest,
    checkpoint_bytes: []const u8,
    checkpoint: Checkpoint,
    watermark: EventBoundary,
    checkpoint_boundary: EventBoundary,
) !void {
    const expected_hash = manifest.checkpoint_sha256 orelse return error.StaleCheckpoint;
    if (!std.mem.eql(u8, &sha256(checkpoint_bytes), &expected_hash)) {
        return error.CheckpointHashMismatch;
    }
    if (manifest.checkpoint_seq == null or
        manifest.checkpoint_seq.? != checkpoint.through_seq or
        !std.mem.eql(u8, checkpoint.session_id, manifest.id) or
        !std.mem.eql(u8, &checkpoint.log_generation, &manifest.log_generation) or
        !std.mem.eql(u8, &watermark.log_generation, &manifest.log_generation) or
        !std.mem.eql(u8, &checkpoint_boundary.log_generation, &manifest.log_generation))
    {
        return error.StaleCheckpoint;
    }
    if (!checkpoint_boundary.semantic or
        checkpoint_boundary.seq != checkpoint.through_seq or
        checkpoint_boundary.event_log_bytes != checkpoint.through_event_log_bytes or
        !std.mem.eql(u8, &checkpoint_boundary.event_id, &checkpoint.through_event_id))
    {
        return error.InvalidCheckpointBoundary;
    }
    if (!watermark.semantic or
        watermark.seq != manifest.last_event_seq or
        watermark.event_log_bytes != manifest.event_log_bytes or
        checkpoint.through_seq > watermark.seq or
        checkpoint.through_event_log_bytes > watermark.event_log_bytes)
    {
        return error.StaleCheckpoint;
    }
    if (!std.mem.eql(u8, checkpoint.state.id, manifest.id)) {
        return error.StaleCheckpoint;
    }
}

pub fn sha256(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn validateManifest(manifest: Manifest) !void {
    const state = session_codec.DurableSessionState{
        .id = manifest.id,
        .origin_workspace_root = manifest.origin_workspace_root,
        .workspace_root = manifest.workspace_root,
        .created_at_ms = manifest.created_at_ms,
        .updated_at_ms = manifest.updated_at_ms,
        .conversation_language = manifest.conversation_language,
        .preferences = manifest.preferences,
        .history = &.{},
        .total_input_tokens = manifest.total_input_tokens,
        .total_output_tokens = manifest.total_output_tokens,
    };
    session_codec.validateState(state) catch return error.InvalidManifest;
    if (manifest.last_event_seq == 0 or manifest.event_log_bytes == 0 or
        manifest.generation_base_seq == 0 or
        manifest.generation_base_seq > manifest.last_event_seq or
        manifest.generation_base_bytes == 0 or
        manifest.generation_base_bytes > manifest.event_log_bytes or
        ((manifest.checkpoint_seq == null) != (manifest.checkpoint_sha256 == null)) or
        (manifest.checkpoint_seq != null and
            (manifest.checkpoint_seq.? == 0 or
                manifest.checkpoint_seq.? > manifest.last_event_seq)))
    {
        return error.InvalidManifest;
    }
}

fn validateCheckpoint(checkpoint: Checkpoint) !void {
    session_codec.validateState(checkpoint.state) catch return error.InvalidCheckpoint;
    if (checkpoint.through_seq == 0 or checkpoint.through_event_log_bytes == 0 or
        !std.mem.eql(u8, checkpoint.session_id, checkpoint.state.id))
    {
        return error.InvalidCheckpoint;
    }
}

fn writePreferences(
    writer: *std.Io.Writer,
    preferences: session_codec.DurableSessionPreferences,
) !void {
    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, preferences.model);
    try writer.writeAll(",\"effort\":");
    try writeJsonString(writer, preferences.effort.label());
    try writer.print(",\"fast_mode\":{s},\"provider\":", .{
        if (preferences.fast_mode) "true" else "false",
    });
    try writeJsonString(writer, @tagName(preferences.provider));
    try writer.writeByte('}');
}

fn parsePreferences(alloc: Allocator, value: std.json.Value) !session_codec.DurableSessionPreferences {
    const raw_object = if (value == .object) value.object else return error.InvalidManifest;
    const object = if (raw_object.get("provider") != null)
        try exactObject(value, &.{ "provider", "model", "effort", "fast_mode" })
    else
        try exactObject(value, &.{ "model", "effort", "fast_mode" });
    const model = try dupeString(alloc, object, "model");
    errdefer alloc.free(model);
    return .{
        .provider = if (object.get("provider")) |provider_value| blk: {
            if (provider_value != .string) return error.InvalidManifest;
            break :blk model_provider.parse(provider_value.string) orelse return error.InvalidManifest;
        } else .gateway,
        .model = model,
        .effort = types.ReasoningEffort.parse(try requireString(object, "effort")) orelse
            return error.InvalidManifest,
        .fast_mode = try requireBool(object, "fast_mode"),
    };
}

fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    if (value != .object or value.object.count() != keys.len) return error.InvalidManifest;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidManifest;
    }
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidManifest;
    if (value != .string) return error.InvalidManifest;
    return value.string;
}

fn dupeString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return try alloc.dupe(u8, try requireString(object, key));
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidManifest;
    if (value != .bool) return error.InvalidManifest;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidManifest;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch
            error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidManifest;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidManifest,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn optionalU64(value: std.json.Value) !?u64 {
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidManifest,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn optionalDigest(value: std.json.Value) !?Digest {
    return switch (value) {
        .null => null,
        .string => |hex| try parseDigest(hex),
        else => error.InvalidManifest,
    };
}

fn parseIdentifier(hex: []const u8) !session_event.Identifier {
    return parseHex(session_event.Identifier, hex);
}

fn parseDigest(hex: []const u8) !Digest {
    return parseHex(Digest, hex);
}

fn parseHex(comptime T: type, hex: []const u8) !T {
    if (hex.len != @sizeOf(T) * 2) return error.InvalidManifest;
    var value: T = undefined;
    _ = std.fmt.hexToBytes(&value, hex) catch return error.InvalidManifest;
    const canonical = std.fmt.bytesToHex(value, .lower);
    if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidManifest;
    return value;
}

fn writeHexString(writer: *std.Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    try writer.writeByte('"');
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
    try writer.writeByte('"');
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try std.json.Stringify.value(bytes, .{}, writer);
}

fn writeInt(
    destination: []u8,
    offset: *usize,
    comptime T: type,
    value: T,
) void {
    const width = @sizeOf(T);
    std.mem.writeInt(T, destination[offset.*..][0..width], value, .big);
    offset.* += width;
}

test "manifest serialization is deterministic and capped" {
    const alloc = std.testing.allocator;
    const manifest = testManifest();

    const first = try encodeManifest(alloc, manifest);
    defer alloc.free(first);
    const second = try encodeManifest(alloc, manifest);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first.len <= manifest_max_bytes);
    try std.testing.expect(first[first.len - 1] != '\n');

    var decoded = try decodeManifest(alloc, first);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(manifest.id, decoded.id);
    try std.testing.expectEqualSlices(u8, &manifest.log_generation, &decoded.log_generation);
    try std.testing.expectEqual(manifest.last_event_seq, decoded.last_event_seq);

    const oversized_model = try alloc.alloc(u8, manifest_max_bytes);
    defer alloc.free(oversized_model);
    @memset(oversized_model, 'm');
    var oversized = manifest;
    oversized.preferences.model = oversized_model;
    try std.testing.expectError(error.ManifestTooLarge, encodeManifest(alloc, oversized));
}

test "manifest decode semantic validation failure frees owned fields once" {
    const alloc = std.testing.allocator;
    const manifest = testManifest();
    const bytes = try encodeManifest(alloc, manifest);
    defer alloc.free(bytes);

    var invalid = try alloc.dupe(u8, bytes);
    defer alloc.free(invalid);
    const needle = "\"last_event_seq\":9";
    const replacement = "\"last_event_seq\":0";
    const pos = std.mem.find(u8, invalid, needle) orelse return error.TestUnexpectedResult;
    @memcpy(invalid[pos..][0..replacement.len], replacement);

    try std.testing.expectError(error.InvalidManifest, decodeManifest(alloc, invalid));
}

test "checkpoint decode semantic validation failure frees owned fields once" {
    const alloc = std.testing.allocator;
    const state = session_codec.DurableSessionState{
        .id = @constCast("session-1"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model-a"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = @constCast(&.{}),
        .total_input_tokens = 3,
        .total_output_tokens = 4,
    };
    const checkpoint = Checkpoint{
        .session_id = state.id,
        .log_generation = testIdentifier(0x10),
        .through_seq = 32,
        .through_event_id = testIdentifier(0x20),
        .through_event_log_bytes = 2048,
        .state = state,
    };
    const bytes = try encodeCheckpoint(alloc, checkpoint);
    defer alloc.free(bytes);

    var invalid = try alloc.dupe(u8, bytes);
    defer alloc.free(invalid);
    const needle = "\"session_id\":\"session-1\"";
    const replacement = "\"session_id\":\"session-2\"";
    const pos = std.mem.find(u8, invalid, needle) orelse return error.TestUnexpectedResult;
    @memcpy(invalid[pos..][0..replacement.len], replacement);

    try std.testing.expectError(error.InvalidCheckpoint, decodeCheckpoint(alloc, invalid));
}

test "event stat fingerprint detects same-size replacement and metadata-only change" {
    const original = EventFileStat{
        .device = 1,
        .inode = 2,
        .kind = .regular,
        .mode = 0o100600,
        .link_count = 1,
        .size = 4096,
        .mtime_ns = 10,
        .ctime_ns = 20,
    };
    const original_hash = try eventFileStatFingerprint(original, 4096);

    var replacement = original;
    replacement.inode += 1;
    const replacement_hash = try eventFileStatFingerprint(replacement, 4096);
    try std.testing.expect(!std.mem.eql(u8, &original_hash, &replacement_hash));

    var touched = original;
    touched.ctime_ns += 1;
    const touched_hash = try eventFileStatFingerprint(touched, 4096);
    try std.testing.expect(!std.mem.eql(u8, &original_hash, &touched_hash));

    var hard_linked = original;
    hard_linked.link_count = 2;
    try std.testing.expectError(error.InvalidEventFileStat, eventFileStatFingerprint(hard_linked, 4096));

    var wrong_size = original;
    wrong_size.size += 1;
    try std.testing.expectError(error.InvalidEventFileStat, eventFileStatFingerprint(wrong_size, 4096));
}

test "checkpoint validation rejects stale corrupt and non-semantic boundaries" {
    const alloc = std.testing.allocator;
    const state = session_codec.DurableSessionState{
        .id = @constCast("session-1"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model-a"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = @constCast(&.{}),
        .total_input_tokens = 3,
        .total_output_tokens = 4,
    };
    const checkpoint = Checkpoint{
        .session_id = state.id,
        .log_generation = testIdentifier(0x10),
        .through_seq = 32,
        .through_event_id = testIdentifier(0x20),
        .through_event_log_bytes = 2048,
        .state = state,
    };
    const bytes = try encodeCheckpoint(alloc, checkpoint);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= checkpoint_max_bytes);
    const checkpoint_hash = sha256(bytes);
    var decoded_checkpoint = try decodeCheckpoint(alloc, bytes);
    defer decoded_checkpoint.deinit(alloc);
    try std.testing.expectEqualStrings(checkpoint.session_id, decoded_checkpoint.session_id);
    try std.testing.expectEqual(checkpoint.through_seq, decoded_checkpoint.through_seq);
    try std.testing.expectEqualStrings(
        checkpoint.state.preferences.model,
        decoded_checkpoint.state.preferences.model,
    );

    var manifest = testManifest();
    manifest.log_generation = checkpoint.log_generation;
    manifest.checkpoint_seq = checkpoint.through_seq;
    manifest.checkpoint_sha256 = checkpoint_hash;
    manifest.last_event_seq = 40;
    manifest.event_log_bytes = 4096;

    const watermark = EventBoundary{
        .log_generation = checkpoint.log_generation,
        .seq = 40,
        .event_id = testIdentifier(0x30),
        .event_log_bytes = 4096,
        .semantic = true,
    };
    const checkpoint_boundary = EventBoundary{
        .log_generation = checkpoint.log_generation,
        .seq = checkpoint.through_seq,
        .event_id = checkpoint.through_event_id,
        .event_log_bytes = checkpoint.through_event_log_bytes,
        .semantic = true,
    };
    try validateCheckpointReference(manifest, bytes, checkpoint, watermark, checkpoint_boundary);

    var corrupt = try alloc.dupe(u8, bytes);
    defer alloc.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(
        error.CheckpointHashMismatch,
        validateCheckpointReference(manifest, corrupt, checkpoint, watermark, checkpoint_boundary),
    );

    var old_generation = checkpoint_boundary;
    old_generation.log_generation = testIdentifier(0x40);
    try std.testing.expectError(
        error.StaleCheckpoint,
        validateCheckpointReference(manifest, bytes, checkpoint, watermark, old_generation),
    );

    var provisional_boundary = checkpoint_boundary;
    provisional_boundary.semantic = false;
    try std.testing.expectError(
        error.InvalidCheckpointBoundary,
        validateCheckpointReference(manifest, bytes, checkpoint, watermark, provisional_boundary),
    );
}

test "manifest stat comparison marks projections stale without changing canonical time" {
    var manifest = testManifest();
    const stat = EventFileStat{
        .device = 1,
        .inode = 2,
        .kind = .regular,
        .mode = 0o100600,
        .link_count = 1,
        .size = manifest.event_log_bytes,
        .mtime_ns = 10,
        .ctime_ns = 20,
    };
    manifest.event_log_stat_fingerprint = try eventFileStatFingerprint(stat, manifest.event_log_bytes);
    try std.testing.expect(!isManifestStale(manifest, stat));

    var touched = stat;
    touched.mtime_ns += 1;
    try std.testing.expect(isManifestStale(manifest, touched));
    try std.testing.expectEqual(@as(i64, 200), manifest.updated_at_ms);
}

fn testManifest() Manifest {
    return .{
        .id = @constCast("session-1"),
        .authority_id = testIdentifier(0x01),
        .log_generation = testIdentifier(0x11),
        .created_at_ms = 100,
        .updated_at_ms = 200,
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history_len = 4,
        .total_input_tokens = 10,
        .total_output_tokens = 20,
        .last_event_seq = 9,
        .event_log_bytes = 4096,
        .event_log_stat_fingerprint = [_]u8{0x55} ** 32,
        .generation_base_seq = 1,
        .generation_base_bytes = 512,
        .checkpoint_seq = null,
        .checkpoint_sha256 = null,
        .preferences = .{
            .model = @constCast("model-a"),
            .effort = types.ReasoningEffort.literal("medium"),
            .fast_mode = true,
        },
    };
}

fn testIdentifier(seed: u8) session_event.Identifier {
    var value: session_event.Identifier = undefined;
    for (&value, 0..) |*byte, i| byte.* = seed +% @as(u8, @intCast(i));
    return value;
}

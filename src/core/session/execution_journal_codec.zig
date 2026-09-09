const std = @import("std");

const Allocator = std.mem.Allocator;
const max_sequence: u64 = 9_007_199_254_740_991;
pub const max_entry_bytes: usize = 32 * 1024 * 1024;
const max_json_depth: usize = 64;
const Error = Allocator.Error || error{
    InvalidSequence,
    EntryTooLarge,
    InvalidUtf8,
    InvalidJson,
    InvalidVersion,
    InvalidKind,
    InvalidHash,
};

pub const Kind = enum {
    turn_start,
    model_step,
    tool_result,
    turn_end,
    checkpoint,
};

pub const Entry = struct {
    seq: u64,
    kind: Kind,
    bytes: []const u8,
    hash: [64]u8,
};

/// Owns entry.bytes and the parsed payload arena. Both remain valid until deinit;
/// no returned slice borrows from the caller's input buffer.
pub const OwnedEntry = struct {
    entry: Entry,
    payload: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *OwnedEntry, alloc: Allocator) void {
        self.payload.deinit();
        alloc.free(self.entry.bytes);
        self.* = undefined;
    }
};

/// Copies and validates the versioned JSON envelope; the execution owner validates
/// the kind-specific body. Release the returned entry with the same allocator.
pub fn create(alloc: Allocator, seq: u64, kind: Kind, bytes: []const u8) Error!OwnedEntry {
    try validate_bounds(seq, bytes);
    return parse_owned(alloc, seq, kind, bytes, digest(seq, kind, bytes));
}

/// Validates an externally stored entry without reserializing its JSON body.
/// Release the returned entry with the same allocator.
pub fn decode(
    alloc: Allocator,
    seq: u64,
    kind_text: []const u8,
    bytes: []const u8,
    hash_text: []const u8,
) Error!OwnedEntry {
    try validate_bounds(seq, bytes);
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.InvalidKind;
    if (hash_text.len != 64) return error.InvalidHash;
    for (hash_text) |byte| {
        if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) {
            return error.InvalidHash;
        }
    }
    const hash = digest(seq, kind, bytes);
    if (!std.mem.eql(u8, &hash, hash_text)) return error.InvalidHash;
    return parse_owned(alloc, seq, kind, bytes, hash);
}

/// SHA-256 of decimal sequence, newline, kind, newline, and the exact input bytes.
/// This allocation-free operation does not validate the envelope.
pub fn digest(seq: u64, kind: Kind, bytes: []const u8) [64]u8 {
    var sequence_buffer: [20]u8 = undefined;
    // Every u64 decimal representation fits in 20 bytes.
    const sequence = std.fmt.bufPrint(&sequence_buffer, "{d}", .{seq}) catch unreachable;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(sequence);
    hasher.update("\n");
    hasher.update(@tagName(kind));
    hasher.update("\n");
    hasher.update(bytes);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

fn validate_bounds(seq: u64, bytes: []const u8) Error!void {
    if (seq == 0 or seq > max_sequence) return error.InvalidSequence;
    try validateJsonBounds(bytes);
}

/// Bounds JSON bytes before allocation, including JSON carried inside an opaque
/// string field. Grammar and schema validation remain the caller's responsibility.
pub fn validateJsonBounds(bytes: []const u8) Error!void {
    if (bytes.len > max_entry_bytes) return error.EntryTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;

    // Bound container depth before allocation; the JSON parser still owns grammar
    // validation. Quoted delimiters do not contribute to structural nesting.
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                if (depth == max_json_depth) return error.InvalidJson;
                depth += 1;
            },
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
}

fn parse_owned(
    alloc: Allocator,
    seq: u64,
    kind: Kind,
    bytes: []const u8,
    hash: [64]u8,
) Error!OwnedEntry {
    const owned_bytes = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned_bytes);
    var payload = std.json.parseFromSlice(std.json.Value, alloc, owned_bytes, .{
        .allocate = .alloc_always,
        .max_value_len = max_entry_bytes,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer payload.deinit();

    if (payload.value != .object) return error.InvalidJson;
    const version = payload.value.object.get("v") orelse return error.InvalidVersion;
    if (version != .integer) return error.InvalidVersion;
    if (version.integer == 1) {
        if (payload.value.object.contains("nativeBase")) return error.InvalidVersion;
    } else if (version.integer == 2 and kind == .checkpoint) {
        const base = payload.value.object.get("nativeBase") orelse return error.InvalidVersion;
        if (base != .object) return error.InvalidVersion;
        const base_version = base.object.get("v") orelse return error.InvalidVersion;
        if (base_version != .integer or base_version.integer != 1) return error.InvalidVersion;
        const state = base.object.get("stateJson") orelse return error.InvalidVersion;
        const id = base.object.get("id") orelse return error.InvalidVersion;
        const context = base.object.get("contextJson") orelse return error.InvalidVersion;
        if (state != .string or id != .string or context != .string) return error.InvalidVersion;
    } else return error.InvalidVersion;
    const payload_kind = payload.value.object.get("kind") orelse return error.InvalidKind;
    if (payload_kind != .string or !std.mem.eql(u8, payload_kind.string, @tagName(kind))) {
        return error.InvalidKind;
    }
    return .{
        .entry = .{ .seq = seq, .kind = kind, .bytes = owned_bytes, .hash = hash },
        .payload = payload,
    };
}

test "journal codec hashes the exact entry frame" {
    // Independently calculated with Python hashlib.sha256 over the wire frame.
    const start = digest(1, .turn_start, "{\"v\":1,\"kind\":\"turn_start\"}");
    try std.testing.expectEqualStrings(
        "20509104dca7f4ebf2c58e4cf3e125241a4e31e7f833a499db9a1ee9797df7c4",
        &start,
    );
    const ending = digest(max_sequence, .turn_end, " { \"kind\":\"turn_end\", \"v\":1, \"text\":\"done\\n\" }\n");
    try std.testing.expectEqualStrings(
        "a5f0c334c827b27d1bedc8f737d5b4c4c00d0074629eb169a80888e5c67f5080",
        &ending,
    );
}

test "journal codec owns raw bytes and decoded strings" {
    const alloc = std.testing.allocator;
    const original = " {\"v\":1,\"kind\":\"tool_result\",\"text\":\"snow \\u96ea\\n\",\"nested\":{\"ok\":true}}\n";
    const source = try alloc.dupe(u8, original);
    defer alloc.free(source);
    var created = try create(alloc, 42, .tool_result, source);
    defer created.deinit(alloc);
    @memset(source, 'x');

    try std.testing.expectEqualStrings(original, created.entry.bytes);
    try std.testing.expectEqualStrings("snow 雪\n", created.payload.value.object.get("text").?.string);
    var decoded = try decode(alloc, 42, "tool_result", created.entry.bytes, &created.entry.hash);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(Kind.tool_result, decoded.entry.kind);
    try std.testing.expectEqual(@as(u64, 42), decoded.entry.seq);
    try std.testing.expectEqualStrings(original, decoded.entry.bytes);
    try std.testing.expectEqualStrings(&created.entry.hash, &decoded.entry.hash);
    try std.testing.expect(created.entry.bytes.ptr != decoded.entry.bytes.ptr);
}

test "journal codec accepts every entry kind and inclusive sequence bounds" {
    const alloc = std.testing.allocator;
    inline for (comptime std.meta.tags(Kind)) |kind| {
        const bytes = comptime "{\"v\":1,\"kind\":\"" ++ @tagName(kind) ++ "\"}";
        var first = try create(alloc, 1, kind, bytes);
        defer first.deinit(alloc);
        var last = try decode(alloc, max_sequence, @tagName(kind), bytes, &digest(max_sequence, kind, bytes));
        defer last.deinit(alloc);
        try std.testing.expectEqual(kind, last.entry.kind);
    }
}

test "journal codec rejects malformed JSON and ambiguous fields" {
    const malformed = [_][]const u8{
        "",
        "null",
        "[]",
        "{",
        "{\"v\":1,\"kind\":\"turn_start\",}",
        "{\"v\":1,\"v\":1,\"kind\":\"turn_start\"}",
        "{\"v\":1,\"kind\":\"turn_start\",\"kind\":\"turn_start\"}",
        "{\"v\":1,\"kind\":\"turn_start\"}{}",
        "{\"v\":1,\"kind\":\"turn_start\",\"text\":\"\\ud800\"}",
    };
    for (malformed) |bytes| {
        try std.testing.expectError(error.InvalidJson, create(std.testing.allocator, 1, .turn_start, bytes));
        try std.testing.expectError(error.InvalidJson, decode(std.testing.allocator, 1, "turn_start", bytes, &digest(1, .turn_start, bytes)));
    }
}

test "journal codec rejects invalid version and kind without interpreting the body" {
    for ([_][]const u8{
        "{\"kind\":\"turn_start\"}",
        "{\"v\":0,\"kind\":\"turn_start\"}",
        "{\"v\":2,\"kind\":\"turn_start\"}",
        "{\"v\":1.0,\"kind\":\"turn_start\"}",
        "{\"v\":1e0,\"kind\":\"turn_start\"}",
        "{\"v\":\"1\",\"kind\":\"turn_start\"}",
        "{\"v\":true,\"kind\":\"turn_start\"}",
    }) |bytes| {
        try std.testing.expectError(error.InvalidVersion, create(std.testing.allocator, 1, .turn_start, bytes));
    }
    for ([_][]const u8{
        "{\"v\":1}",
        "{\"v\":1,\"kind\":null}",
        "{\"v\":1,\"kind\":\"unknown\"}",
        "{\"v\":1,\"kind\":\"turn_end\"}",
    }) |bytes| {
        try std.testing.expectError(error.InvalidKind, create(std.testing.allocator, 1, .turn_start, bytes));
    }
}

test "journal codec checks external bounds and UTF8 before allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    const bytes = "{\"v\":1,\"kind\":\"turn_start\"}";
    for ([_]u64{ 0, max_sequence + 1, std.math.maxInt(u64) }) |seq| {
        try std.testing.expectError(error.InvalidSequence, create(alloc, seq, .turn_start, bytes));
        try std.testing.expectError(error.InvalidSequence, decode(alloc, seq, "turn_start", bytes, &digest(seq, .turn_start, bytes)));
    }
    for ([_][]const u8{
        "{\"v\":1,\"kind\":\"turn_start\",\"text\":\"\xff\"}",
        "{\"v\":1,\"kind\":\"turn_start\",\"text\":\"\xc0\xaf\"}",
        "{\"v\":1,\"kind\":\"turn_start\",\"text\":\"\xed\xa0\x80\"}",
    }) |invalid| {
        try std.testing.expectError(error.InvalidUtf8, create(alloc, 1, .turn_start, invalid));
        try std.testing.expectError(error.InvalidUtf8, decode(alloc, 1, "turn_start", invalid, &digest(1, .turn_start, invalid)));
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "journal codec bounds the raw entry at thirty-two MiB" {
    const alloc = std.testing.allocator;
    const buffer = try alloc.alloc(u8, max_entry_bytes + 1);
    defer alloc.free(buffer);
    @memset(buffer, ' ');
    const body = "{\"v\":1,\"kind\":\"checkpoint\"}";
    @memcpy(buffer[0..body.len], body);
    var entry = try create(alloc, 1, .checkpoint, buffer[0..max_entry_bytes]);
    defer entry.deinit(alloc);
    try std.testing.expectEqual(max_entry_bytes, entry.entry.bytes.len);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.EntryTooLarge, create(failing.allocator(), 1, .checkpoint, buffer));
    try std.testing.expectError(error.EntryTooLarge, decode(failing.allocator(), 1, "checkpoint", buffer, &entry.entry.hash));
    try std.testing.expect(!failing.has_induced_failure);
}

test "journal codec bounds JSON container nesting before allocation" {
    const alloc = std.testing.allocator;
    inline for (.{ .{ "[", "]" }, .{ "{\"x\":", "}" } }) |container| {
        const prefix = "{\"v\":1,\"kind\":\"checkpoint\",\"value\":";
        const boundary = prefix ++ (container[0] ** 63) ++ "null" ++ (container[1] ** 63) ++ "}";
        var entry = try create(alloc, 1, .checkpoint, boundary);
        defer entry.deinit(alloc);
        var decoded = try decode(alloc, 1, "checkpoint", boundary, &entry.entry.hash);
        defer decoded.deinit(alloc);

        const deeper = prefix ++ (container[0] ** 64) ++ "null" ++ (container[1] ** 64) ++ "}";
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        try std.testing.expectError(error.InvalidJson, create(failing.allocator(), 1, .checkpoint, deeper));
        try std.testing.expectError(error.InvalidJson, decode(failing.allocator(), 1, "checkpoint", deeper, &digest(1, .checkpoint, deeper)));
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "journal codec ignores quoted brackets and escaped quotes when bounding depth" {
    const bytes = "{\"v\":1,\"kind\":\"checkpoint\",\"text\":\"\\\"\\\\\\\"" ++
        ("[{" ** 64) ++ ("}]" ** 64) ++ "\",\"tail\":\"\\\\\"}";
    var entry = try create(std.testing.allocator, 1, .checkpoint, bytes);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"\\\"" ++ ("[{" ** 64) ++ ("}]" ** 64), entry.payload.value.object.get("text").?.string);
    try std.testing.expectEqualStrings("\\", entry.payload.value.object.get("tail").?.string);
}

test "journal codec rejects altered or noncanonical hashes before allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    const bytes = "{\"v\":1,\"kind\":\"turn_start\"}";
    const hash = digest(1, .turn_start, bytes);
    var uppercase = hash;
    for (&uppercase) |*byte| byte.* = std.ascii.toUpper(byte.*);
    for ([_][]const u8{ "", hash[0..63], &uppercase, "g" ** 64, "0" ** 64, "0" ** 65 }) |invalid| {
        try std.testing.expectError(error.InvalidHash, decode(alloc, 1, "turn_start", bytes, invalid));
    }
    try std.testing.expectError(error.InvalidHash, decode(alloc, 2, "turn_start", bytes, &hash));
    try std.testing.expectError(error.InvalidHash, decode(alloc, 1, "turn_end", bytes, &hash));
    try std.testing.expectError(error.InvalidHash, decode(alloc, 1, "turn_start", bytes ++ " ", &hash));
    try std.testing.expectError(error.InvalidKind, decode(alloc, 1, "TURN_START", bytes, &hash));
    try std.testing.expectError(error.InvalidKind, decode(alloc, 1, "", bytes, &hash));
    try std.testing.expect(!failing.has_induced_failure);
}

test "journal codec releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            const bytes = "{\"v\":1,\"kind\":\"model_step\",\"text\":\"a\\tb\",\"calls\":[{\"id\":\"call_1\"}]}";
            var created = try create(alloc, 1, .model_step, bytes);
            defer created.deinit(alloc);
            var decoded = try decode(alloc, created.entry.seq, "model_step", created.entry.bytes, &created.entry.hash);
            defer decoded.deinit(alloc);
        }
    }.run, .{});
    for ([_][]const u8{
        "{\"v\":1,\"kind\":\"turn_start\",\"text\":\"a\\tb\"",
        "{\"v\":2,\"kind\":\"turn_start\"}",
        "{\"v\":1,\"kind\":\"turn_end\"}",
    }) |bytes| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(alloc: Allocator, invalid: []const u8) !void {
                var entry = create(alloc, 1, .turn_start, invalid) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidJson, error.InvalidVersion, error.InvalidKind => return,
                    else => return err,
                };
                defer entry.deinit(alloc);
                return error.ExpectedInvalidEntry;
            }
        }.run, .{bytes});
    }
}

//! Byte-exact codecs for the generation fact and incident shapes session
//! snapshots share with older fx binaries.
//!
//! Every writer emits exactly the bytes older binaries emit, and every parser
//! accepts and rejects exactly what they accept and reject.
//!
//! Parsers take `std.json.Value`s and return owned values; free them with
//! `deinit`. Writers borrow their input and validate it first, so nothing
//! this file writes is rejected by this file's parsers.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Longest accepted model name in a generation fact.
pub const max_model_bytes: usize = 1024;

const generation_id_prefix = "gen_";
const generation_id_len = 30;

/// Completeness a durable incident can record. Snapshot parsers reject
/// `complete` and `legacy`, so they are not representable here.
pub const IncidentCompleteness = enum { pending, incomplete };

pub const Incident = struct {
    occurred_at_ms: i64,
    completeness: IncidentCompleteness,
};

/// One authoritative AI Gateway generation. Parsed values own `id` and
/// `model`; free with `deinit`. Caller-built values may borrow them.
pub const GenerationFact = struct {
    id: []const u8,
    created_at_ms: i64,
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64 = 0,
    total_cost: f64,

    pub fn deinit(self: *GenerationFact, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.model);
        self.* = undefined;
    }

    /// Exact equality. Costs compare with `==`.
    pub fn eql(a: GenerationFact, b: GenerationFact) bool {
        return std.mem.eql(u8, a.id, b.id) and
            a.created_at_ms == b.created_at_ms and
            std.mem.eql(u8, a.model, b.model) and
            a.input_tokens == b.input_tokens and
            a.output_tokens == b.output_tokens and
            a.cache_read_tokens == b.cache_read_tokens and
            a.cache_write_tokens == b.cache_write_tokens and
            a.reasoning_tokens == b.reasoning_tokens and
            a.billable_web_search_calls == b.billable_web_search_calls and
            a.total_cost == b.total_cost;
    }
};

pub const FactError = error{InvalidGenerationFact};

// ---------------------------------------------------------------------------
// Validation

/// `gen_` plus 26 Crockford base32 characters (no I, L, O, U).
pub fn validGenerationId(id: []const u8) bool {
    if (id.len != generation_id_len or !std.mem.startsWith(u8, id, generation_id_prefix)) return false;
    for (id[generation_id_prefix.len..]) |char| if (!crockford[char]) return false;
    return true;
}

const crockford: [256]bool = blk: {
    var table: [256]bool = @splat(false);
    for ("0123456789ABCDEFGHJKMNPQRSTVWXYZ") |char| table[char] = true;
    break :blk table;
};

pub fn validateFact(fact: GenerationFact) FactError!void {
    if (!validGenerationId(fact.id) or
        fact.created_at_ms < 0 or
        fact.model.len == 0 or
        fact.model.len > max_model_bytes or
        !std.math.isFinite(fact.total_cost) or
        fact.total_cost < 0 or
        fact.cache_read_tokens > fact.input_tokens or
        fact.cache_write_tokens > fact.input_tokens)
    {
        return error.InvalidGenerationFact;
    }
    if (fact.reasoning_tokens) |reasoning| {
        if (reasoning > fact.output_tokens) return error.InvalidGenerationFact;
    }
    for (fact.model) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidGenerationFact;
    }
}

// ---------------------------------------------------------------------------
// Generation fact (10 keys written, 9 or 10 accepted)

/// Writes the fact object snapshot backlogs share with older binaries.
pub fn writeFact(writer: *std.Io.Writer, fact: GenerationFact) (std.Io.Writer.Error || FactError)!void {
    try validateFact(fact);
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(fact.id, .{}, writer);
    try writer.print(",\"created_at_ms\":{d},\"model\":", .{fact.created_at_ms});
    try std.json.Stringify.value(fact.model, .{}, writer);
    try writer.print(
        ",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{ fact.input_tokens, fact.output_tokens, fact.cache_read_tokens, fact.cache_write_tokens },
    );
    try writeOptionalU64(writer, fact.reasoning_tokens);
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"total_cost\":{d}}}",
        .{ fact.billable_web_search_calls, fact.total_cost },
    );
}

/// Parses a fact object. Accepts 9 or 10 keys and, like fx today, checks only
/// the names it reads: a 10th key with any name passes, and a missing
/// `billable_web_search_calls` reads as 0. The caller owns the result.
pub fn parseFact(alloc: Allocator, value: std.json.Value) (Allocator.Error || FactError)!GenerationFact {
    if (value != .object or (value.object.count() != 9 and value.object.count() != 10)) {
        return error.InvalidGenerationFact;
    }
    const id_value = value.object.get("id") orelse return error.InvalidGenerationFact;
    const model_value = value.object.get("model") orelse return error.InvalidGenerationFact;
    const reasoning_value = value.object.get("reasoning_tokens") orelse return error.InvalidGenerationFact;
    if (id_value != .string or model_value != .string) return error.InvalidGenerationFact;
    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const model = try alloc.dupe(u8, model_value.string);
    errdefer alloc.free(model);
    const fact = GenerationFact{
        .id = id,
        .created_at_ms = try factI64(value.object.get("created_at_ms")),
        .model = model,
        .input_tokens = try factU64(value.object.get("input_tokens")),
        .output_tokens = try factU64(value.object.get("output_tokens")),
        .cache_read_tokens = try factU64(value.object.get("cache_read_tokens")),
        .cache_write_tokens = try factU64(value.object.get("cache_write_tokens")),
        .reasoning_tokens = if (reasoning_value == .null) null else try factU64(reasoning_value),
        .billable_web_search_calls = if (value.object.get("billable_web_search_calls")) |field|
            try factU64(field)
        else
            0,
        .total_cost = try factCost(value.object.get("total_cost")),
    };
    try validateFact(fact);
    return fact;
}

fn factU64(value: ?std.json.Value) FactError!u64 {
    return jsonU64(value) orelse error.InvalidGenerationFact;
}

fn factI64(value: ?std.json.Value) FactError!i64 {
    return std.math.cast(i64, try factU64(value)) orelse error.InvalidGenerationFact;
}

fn factCost(value: ?std.json.Value) FactError!f64 {
    const actual = value orelse return error.InvalidGenerationFact;
    const number: f64 = switch (actual) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return error.InvalidGenerationFact,
        else => return error.InvalidGenerationFact,
    };
    if (!std.math.isFinite(number) or number < 0) return error.InvalidGenerationFact;
    return number;
}

// ---------------------------------------------------------------------------
// Shared number helpers

/// Non-negative integer from `.integer` or a base-10 `.number_string`.
fn jsonU64(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) std.math.cast(u64, number) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) std.Io.Writer.Error!void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("null");
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "fx vector: generation fact codec round trip" {
    // generation_fact_codec.zig "codec round trips the shared generation fact shape"
    const alloc = testing.allocator;
    const expected = GenerationFact{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 42,
        .model = "provider/model",
        .input_tokens = 8,
        .output_tokens = 3,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = null,
        .billable_web_search_calls = 4,
        .total_cost = 0.25,
    };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeFact(&encoded.writer, expected);
    try testing.expectEqualStrings(
        "{\"id\":\"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"created_at_ms\":42,\"model\":\"provider/model\",\"input_tokens\":8,\"output_tokens\":3,\"cache_read_tokens\":2,\"cache_write_tokens\":1,\"reasoning_tokens\":null,\"billable_web_search_calls\":4,\"total_cost\":0.25}",
        encoded.written(),
    );
    for ([_]bool{ true, false }) |parse_numbers| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{ .parse_numbers = parse_numbers });
        defer parsed.deinit();
        var decoded = try parseFact(alloc, parsed.value);
        defer decoded.deinit(alloc);
        try testing.expect(GenerationFact.eql(expected, decoded));
    }
    try testing.expect(std.mem.indexOf(u8, encoded.written(), "request_count") == null);
}

test "generation ids are gen_ plus 26 Crockford base32 characters" {
    try testing.expect(validGenerationId("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"));
    try testing.expect(validGenerationId("gen_0123456789ABCDEFGHJKMNPQRS"));
    try testing.expect(validGenerationId("gen_TVWXYZ00000000000000000000"));
    for ([_]u8{ 'I', 'L', 'O', 'U', 'a', '-', '_' }) |bad| {
        var id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV".*;
        id[29] = bad;
        try testing.expect(!validGenerationId(&id));
    }
    try testing.expect(!validGenerationId("gen_01ARZ3NDEKTSV4RRFFQ69G5FA"));
    try testing.expect(!validGenerationId("gen_01ARZ3NDEKTSV4RRFFQ69G5FAVV"));
    try testing.expect(!validGenerationId("Gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"));
    // Every byte value, against the alphabet's ranges.
    for (0..256) |byte| {
        const char: u8 = @intCast(byte);
        const want = switch (char) {
            '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => true,
            else => false,
        };
        var id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV".*;
        id[4] = char;
        try testing.expectEqual(want, validGenerationId(&id));
    }
}

const std = @import("std");
const lexical_relevance = @import("../shared/lexical_relevance.zig");

pub const OwnedSearchQueryInput = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,

    pub fn deinit(self: *OwnedSearchQueryInput, alloc: std.mem.Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }
};

pub const OwnedSearchQueryDecode = union(enum) {
    failure: []u8,
    input: *OwnedSearchQueryInput,
};

pub noinline fn decodeOwnedSearchQuery(
    alloc: std.mem.Allocator,
    args_json: []const u8,
    tool_name: []const u8,
) error{OutOfMemory}!OwnedSearchQueryDecode {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try prefixedFailure(alloc, tool_name, " arguments must be valid JSON") },
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try prefixedFailure(alloc, tool_name, " arguments must be an object") };
    }
    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try prefixedFailure(alloc, tool_name, " field \"query\" is required") };
    };
    if (query_value != .string) {
        return .{ .failure = try prefixedFailure(alloc, tool_name, " field \"query\" must be a string") };
    }
    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return .{ .failure = try prefixedFailure(alloc, tool_name, " query must not exceed 4096 bytes") };
    }

    const query = try alloc.dupe(u8, query_value.string);
    errdefer alloc.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
    };
    const input = try alloc.create(OwnedSearchQueryInput);
    input.* = .{ .query = query, .prepared = prepared };
    return .{ .input = input };
}

pub fn destroyOwnedSearchQueryInput(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const input: *OwnedSearchQueryInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

noinline fn prefixedFailure(
    alloc: std.mem.Allocator,
    prefix: []const u8,
    suffix: []const u8,
) error{OutOfMemory}![]u8 {
    const len = std.math.add(usize, prefix.len, suffix.len) catch return error.OutOfMemory;
    const message = try alloc.alloc(u8, len);
    @memcpy(message[0..prefix.len], prefix);
    @memcpy(message[prefix.len..], suffix);
    return message;
}

pub fn parseToolArgsObject(alloc: std.mem.Allocator, args_json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
    // The returned object map is backed by the parse allocation; callers should
    // use an arena or allocator lifetime that outlives all borrowed values.
    if (parsed.value != .object) return error.InvalidToolArguments;
    return parsed.value.object;
}

pub fn normalizeCompositeObjectValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    if (value.* != .string) return;
    const decoded = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        value.string,
        .{ .allocate = .alloc_always },
    );
    if (decoded != .object) return error.InvalidCompositeArgument;
    value.* = decoded;
}

pub fn requiredStringArg(args: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = args.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

pub fn optionalStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Tool schemas that require every field tell the model to send null for the
/// fields its selected action does not use. Models routinely serialize that null
/// as the literal text "null", so readers treat it as the absence it expresses.
pub fn isNullPlaceholderText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, &std.ascii.whitespace), "null");
}

/// Reads an optional string argument from a schema whose unused fields arrive as
/// nulls, so textual null placeholders read as absent instead of as a value.
pub fn nullablePlaceholderStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const text = optionalStringArg(args, key) orelse return null;
    if (isNullPlaceholderText(text)) return null;
    return text;
}

pub fn optionalBoolArg(args: std.json.ObjectMap, key: []const u8) ?bool {
    const value = args.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn optionalIntArg(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = args.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

test "parseToolArgsObject parses object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\"}");

    try std.testing.expectEqualStrings("src/main.zig", args.get("path").?.string);
}

test "parseToolArgsObject rejects non-object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidToolArguments, parseToolArgsObject(arena, "[]"));
}

test "requiredStringArg rejects missing and wrong-type values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\",\"count\":3}");

    try std.testing.expectEqualStrings("src/main.zig", try requiredStringArg(args, "path"));
    try std.testing.expectError(error.InvalidToolArguments, requiredStringArg(args, "missing"));
    try std.testing.expectError(error.InvalidToolArguments, requiredStringArg(args, "count"));
}

test "optional typed args return payloads only for matching tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"name\":\"fx\",\"enabled\":true,\"count\":3,\"other\":1.25}");

    try std.testing.expectEqualStrings("fx", optionalStringArg(args, "name").?);
    try std.testing.expect(optionalStringArg(args, "missing") == null);
    try std.testing.expect(optionalStringArg(args, "enabled") == null);

    try std.testing.expectEqual(true, optionalBoolArg(args, "enabled").?);
    try std.testing.expect(optionalBoolArg(args, "missing") == null);
    try std.testing.expect(optionalBoolArg(args, "name") == null);

    try std.testing.expectEqual(@as(i64, 3), optionalIntArg(args, "count").?);
    try std.testing.expect(optionalIntArg(args, "missing") == null);
    try std.testing.expect(optionalIntArg(args, "other") == null);
}

test "null placeholder reads treat textual nulls as absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(
        arena,
        "{\"cwd\":\"null\",\"profile\":\" NULL \",\"shell\":null,\"command\":\"echo null\",\"dir\":\"nullify\"}",
    );

    try std.testing.expect(nullablePlaceholderStringArg(args, "cwd") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "profile") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "shell") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "missing") == null);
    try std.testing.expectEqualStrings("echo null", nullablePlaceholderStringArg(args, "command").?);
    try std.testing.expectEqualStrings("nullify", nullablePlaceholderStringArg(args, "dir").?);
    try std.testing.expectEqualStrings("null", optionalStringArg(args, "cwd").?);
}

test "composite object normalization preserves objects and decodes JSON strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var object = std.json.Value{ .object = try parseToolArgsObject(
        arena,
        "{\"kind\":\"executable\",\"path\":\"/bin/bash\"}",
    ) };
    try normalizeCompositeObjectValue(arena, &object);
    try std.testing.expectEqualStrings("/bin/bash", object.object.get("path").?.string);

    var encoded = std.json.Value{ .string = "{\"kind\":\"executable\",\"path\":\"/bin/zsh\"}" };
    try normalizeCompositeObjectValue(arena, &encoded);
    try std.testing.expectEqualStrings("/bin/zsh", encoded.object.get("path").?.string);

    var invalid = std.json.Value{ .string = "[]" };
    try std.testing.expectError(
        error.InvalidCompositeArgument,
        normalizeCompositeObjectValue(arena, &invalid),
    );
}

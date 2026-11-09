const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");

pub fn parseToolArgsObject(alloc: std.mem.Allocator, args_json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
    // The returned object map is backed by the parse allocation; callers should
    // use an arena or allocator lifetime that outlives all borrowed values.
    if (parsed.value != .object) return error.InvalidToolArguments;
    return parsed.value.object;
}

/// Some models send an object argument as JSON text. This reads the text back
/// into the object it names, allocated in `alloc`, and leaves any other value
/// as it is. Text that is not an object is error.InvalidCompositeArgument.
pub fn normalizeCompositeObjectValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    return normalizeCompositeValue(alloc, value, .object);
}

/// The array counterpart of normalizeCompositeObjectValue.
pub fn normalizeCompositeArrayValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    return normalizeCompositeValue(alloc, value, .array);
}

fn normalizeCompositeValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
    kind: std.meta.Tag(std.json.Value),
) !void {
    if (value.* != .string) return;
    const decoded = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        value.string,
        .{ .allocate = .alloc_always },
    );
    if (std.meta.activeTag(decoded) != kind) return error.InvalidCompositeArgument;
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

/// Reads a built-in tool's JSON arguments. The first problem becomes the
/// failure text the model receives, such as `read_file requires string field
/// "path"`, and the read returns error.InvalidArguments; `takeFailure` hands
/// that text, allocated in `alloc`, to the tool's decode result.
pub const ArgsDecoder = struct {
    alloc: std.mem.Allocator,
    tool: []const u8,
    failure: ?[]u8 = null,

    const Error = std.mem.Allocator.Error || error{InvalidArguments};

    /// The parsed arguments, which must be an object; the caller deinits them.
    /// Any parse error, out of memory included, reads as invalid JSON.
    pub fn parse(self: *ArgsDecoder, args_json: []const u8) Error!std.json.Parsed(std.json.Value) {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, args_json, .{}) catch
            return self.fail("{s} arguments must be valid JSON", .{self.tool});
        errdefer parsed.deinit();
        if (parsed.value != .object) return self.fail("{s} arguments must be an object", .{self.tool});
        return parsed;
    }

    pub fn requiredString(self: *ArgsDecoder, args: std.json.ObjectMap, key: []const u8) Error![]const u8 {
        const value = args.get(key) orelse return self.fail("{s} requires string field \"{s}\"", .{ self.tool, key });
        if (value != .string) return self.stringFailure(key);
        return value.string;
    }

    /// A missing field and JSON null both read as not given.
    pub fn optionalString(self: *ArgsDecoder, args: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
        const value = args.get(key) orelse return null;
        return switch (value) {
            .null => null,
            .string => |text| text,
            else => self.stringFailure(key),
        };
    }

    fn stringFailure(self: *ArgsDecoder, key: []const u8) Error {
        return self.fail("{s} field \"{s}\" must be a string", .{ self.tool, key });
    }

    /// Records the failure text and returns error.InvalidArguments.
    fn fail(self: *ArgsDecoder, comptime fmt: []const u8, args: anytype) Error {
        self.failure = try self.alloc.print(fmt, args);
        return error.InvalidArguments;
    }

    /// The recorded failure text, owned by the caller, for error.InvalidArguments;
    /// an allocation failure stays an error.
    pub fn takeFailure(self: *ArgsDecoder, err: Error) std.mem.Allocator.Error![]u8 {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => {
                const failure = self.failure.?;
                self.failure = null;
                return failure;
            },
        };
    }
};

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

test "composite array normalization preserves arrays and decodes JSON strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var array = try std.json.parseFromSliceLeaky(std.json.Value, arena, "[1,2]", .{});
    try normalizeCompositeArrayValue(arena, &array);
    try std.testing.expectEqual(@as(usize, 2), array.array.items.len);

    var encoded = std.json.Value{ .string = "[{\"question\":\"Q\"}]" };
    try normalizeCompositeArrayValue(arena, &encoded);
    try std.testing.expectEqualStrings("Q", encoded.array.items[0].object.get("question").?.string);

    var number = std.json.Value{ .integer = 3 };
    try normalizeCompositeArrayValue(arena, &number);
    try std.testing.expectEqual(@as(i64, 3), number.integer);

    var object_text = std.json.Value{ .string = "{}" };
    try std.testing.expectError(
        error.InvalidCompositeArgument,
        normalizeCompositeArrayValue(arena, &object_text),
    );
    var not_json = std.json.Value{ .string = "not json" };
    try std.testing.expectError(
        error.SyntaxError,
        normalizeCompositeArrayValue(arena, &not_json),
    );
}

fn expectDecoderFailure(expected: []const u8, comptime read: fn (*ArgsDecoder, std.json.ObjectMap) ArgsDecoder.Error!void, args_json: []const u8) !void {
    const alloc = std.testing.allocator;
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = decoder.parse(args_json) catch |err| {
        const failure = try decoder.takeFailure(err);
        defer alloc.free(failure);
        return std.testing.expectEqualStrings(expected, failure);
    };
    defer parsed.deinit();
    read(&decoder, parsed.value.object) catch |err| {
        const failure = try decoder.takeFailure(err);
        defer alloc.free(failure);
        try std.testing.expectEqual(null, decoder.failure);
        return std.testing.expectEqualStrings(expected, failure);
    };
    return error.TestExpectedFailure;
}

fn readNothing(_: *ArgsDecoder, _: std.json.ObjectMap) ArgsDecoder.Error!void {
    return error.InvalidArguments;
}

fn readRequiredPath(decoder: *ArgsDecoder, args: std.json.ObjectMap) ArgsDecoder.Error!void {
    _ = try decoder.requiredString(args, "path");
}

fn readOptionalPath(decoder: *ArgsDecoder, args: std.json.ObjectMap) ArgsDecoder.Error!void {
    _ = try decoder.optionalString(args, "path");
}

test "ArgsDecoder reports each argument problem as the tool's failure text" {
    try expectDecoderFailure("demo_tool arguments must be valid JSON", readNothing, "{");
    try expectDecoderFailure("demo_tool arguments must be an object", readNothing, "[1]");
    try expectDecoderFailure("demo_tool requires string field \"path\"", readRequiredPath, "{}");
    try expectDecoderFailure("demo_tool field \"path\" must be a string", readRequiredPath, "{\"path\":7}");
    try expectDecoderFailure("demo_tool field \"path\" must be a string", readRequiredPath, "{\"path\":null}");
    try expectDecoderFailure("demo_tool field \"path\" must be a string", readOptionalPath, "{\"path\":[]}");
}

test "ArgsDecoder reads present strings and treats missing or null optional strings as absent" {
    const alloc = std.testing.allocator;
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = try decoder.parse("{\"path\":\"a.txt\",\"mode\":null}");
    defer parsed.deinit();
    const args = parsed.value.object;
    try std.testing.expectEqualStrings("a.txt", try decoder.requiredString(args, "path"));
    try std.testing.expectEqualStrings("a.txt", (try decoder.optionalString(args, "path")).?);
    try std.testing.expectEqual(null, try decoder.optionalString(args, "mode"));
    try std.testing.expectEqual(null, try decoder.optionalString(args, "include"));
    try std.testing.expectEqual(null, decoder.failure);
}

fn decodeRequiredPathAllocation(alloc: std.mem.Allocator) !void {
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = decoder.parse("{\"path\":3}") catch |err| {
        alloc.free(try decoder.takeFailure(err));
        return;
    };
    defer parsed.deinit();
    _ = decoder.requiredString(parsed.value.object, "path") catch |err| {
        alloc.free(try decoder.takeFailure(err));
        return;
    };
    return error.TestExpectedFailure;
}

test "ArgsDecoder keeps allocation failures as errors and leaks nothing" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, decodeRequiredPathAllocation, .{});
}

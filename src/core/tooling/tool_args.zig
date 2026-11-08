const std = @import("std");
const json_depth = @import("../shared/json_depth.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");

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

/// The longest `request` wrapper text that is read back into the object it
/// names.
pub const max_request_text_bytes: usize = 64 * 1024;

/// Returns the object a model's `request` wrapper holds: the object itself,
/// or the object its JSON text names, decoded in `alloc`, when the text is at
/// most max_request_text_bytes long and nests no deeper than
/// json_depth.max_depth, the limit on JSON from a provider. Deeper text is not
/// decoded: std.json.Stringify aborts fx past 256 levels when the call is
/// written back out. Returns null for any other value, so the caller handles
/// the call as it was sent.
pub fn requestWrapperObject(
    alloc: std.mem.Allocator,
    request: std.json.Value,
) std.mem.Allocator.Error!?std.json.ObjectMap {
    switch (request) {
        .object => |object| return object,
        .string => |text| if (text.len > max_request_text_bytes or json_depth.exceeds(text)) return null,
        else => return null,
    }
    var decoded = request;
    normalizeCompositeObjectValue(alloc, &decoded) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    return decoded.object;
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

/// `{"command":"<filler>"}` exactly `len` bytes long.
fn requestTextOfLength(alloc: std.mem.Allocator, len: usize) ![]u8 {
    const prefix = "{\"command\":\"";
    const suffix = "\"}";
    const text = try alloc.alloc(u8, len);
    @memcpy(text[0..prefix.len], prefix);
    @memset(text[prefix.len .. len - suffix.len], 'a');
    @memcpy(text[len - suffix.len ..], suffix);
    return text;
}

test "request wrapper reads an object or the bounded JSON text of one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const object = std.json.Value{ .object = try parseToolArgsObject(arena, "{\"action\":\"run\"}") };
    const same = (try requestWrapperObject(arena, object)).?;
    try std.testing.expectEqual(object.object.keys().ptr, same.keys().ptr);

    const decoded = (try requestWrapperObject(arena, .{ .string = "{\"action\":\"run\",\"command\":\"true\"}" })).?;
    try std.testing.expectEqualStrings("run", decoded.get("action").?.string);
    try std.testing.expectEqualStrings("true", decoded.get("command").?.string);

    for ([_]std.json.Value{
        .{ .string = "run" },
        .{ .string = "" },
        .{ .string = "[]" },
        .{ .string = "null" },
        .{ .string = "\"{}\"" },
        .{ .string = "{" },
        .{ .string = "{} {}" },
        .{ .integer = 3 },
        .{ .bool = true },
        .null,
        .{ .array = .init(arena) },
    }) |value| {
        try std.testing.expectEqual(@as(?std.json.ObjectMap, null), try requestWrapperObject(arena, value));
    }

    const at_bound = try requestTextOfLength(arena, max_request_text_bytes);
    const read = (try requestWrapperObject(arena, .{ .string = at_bound })).?;
    try std.testing.expectEqual(max_request_text_bytes - "{\"command\":\"\"}".len, read.get("command").?.string.len);
    const past_bound = try requestTextOfLength(arena, max_request_text_bytes + 1);
    try std.testing.expectEqual(@as(?std.json.ObjectMap, null), try requestWrapperObject(arena, .{ .string = past_bound }));
}

/// `{"a":...}` nested `levels` levels deep: the value of `a` holds `levels - 1`
/// more levels of `kind` (`{` or `[`) around a 0.
fn nestedRequestText(alloc: std.mem.Allocator, levels: usize, kind: u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(alloc, "{\"a\":");
    for (1..levels) |_| try text.appendSlice(alloc, if (kind == '{') "{\"a\":" else "[");
    try text.append(alloc, '0');
    for (1..levels) |_| try text.append(alloc, if (kind == '{') '}' else ']');
    try text.append(alloc, '}');
    return text.toOwnedSlice(alloc);
}

test "request wrapper reads text nested up to 64 levels and refuses deeper text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The levels below are the limit on JSON from a provider.
    try std.testing.expectEqual(@as(usize, 64), json_depth.max_depth);

    for ([_]u8{ '{', '[' }) |kind| {
        for ([_]usize{ 1, 2, 63, 64 }) |levels| {
            const text = try nestedRequestText(arena, levels, kind);
            const read = (try requestWrapperObject(arena, .{ .string = text })) orelse
                return error.TestExpectedRead;
            try std.testing.expect(read.get("a") != null);
        }
        // 255 and 256 are the levels where std.json.Stringify aborts a safe build.
        for ([_]usize{ 65, 66, 100, 255, 256, 300, 5000 }) |levels| {
            const text = try nestedRequestText(arena, levels, kind);
            try std.testing.expectEqual(@as(?std.json.ObjectMap, null), try requestWrapperObject(arena, .{ .string = text }));
        }
    }

    // Brackets and braces inside a string are not nesting.
    const brackets = try arena.alloc(u8, 2000);
    for (brackets, 0..) |*byte, index| byte.* = if (index % 2 == 0) '[' else '{';
    const quoted = try std.mem.concat(arena, u8, &.{ "{\"command\":\"", brackets, "\"}" });
    const read = (try requestWrapperObject(arena, .{ .string = quoted })) orelse return error.TestExpectedRead;
    try std.testing.expectEqualStrings(brackets, read.get("command").?.string);
}

test "request wrapper reads text exactly when it nests at most 64 levels" {
    // The runner's --seed replays a failing run.
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();
    var read_count: usize = 0;
    var refused_count: usize = 0;
    for (0..300) |_| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const levels = random.intRangeAtMost(usize, 1, 90);
        var text: std.ArrayList(u8) = .empty;
        var closers: std.ArrayList(u8) = .empty;
        for (0..levels) |level| {
            // The outermost level is an object, so text that is read is an object.
            if (level == 0 or random.boolean()) {
                try text.appendSlice(arena, "{\"k\":");
                try closers.append(arena, '}');
            } else {
                try text.append(arena, '[');
                try closers.append(arena, ']');
            }
        }
        try text.append(arena, '0');
        std.mem.reverse(u8, closers.items);
        try text.appendSlice(arena, closers.items);

        const read = try requestWrapperObject(arena, .{ .string = text.items });
        try std.testing.expectEqual(levels <= 64, read != null);
        if (levels <= 64) read_count += 1 else refused_count += 1;
    }
    try std.testing.expect(read_count > 0);
    try std.testing.expect(refused_count > 0);
}

const request_text_charset = "az09 _\"\\{}[]:,\n\t";

fn randomRequestText(alloc: std.mem.Allocator, random: std.Random, len: usize) std.mem.Allocator.Error![]u8 {
    const text = try alloc.alloc(u8, len);
    for (text) |*byte| byte.* = request_text_charset[random.uintLessThan(usize, request_text_charset.len)];
    return text;
}

/// A seeded JSON value up to `depth` levels of arrays and objects deep.
fn randomRequestValue(alloc: std.mem.Allocator, random: std.Random, depth: u8) std.mem.Allocator.Error!std.json.Value {
    switch (random.uintLessThan(u8, if (depth == 0) 4 else 6)) {
        0 => return .null,
        1 => return .{ .bool = random.boolean() },
        2 => return .{ .integer = random.int(i32) },
        3 => return .{ .string = try randomRequestText(alloc, random, random.uintLessThan(usize, 24)) },
        4 => {
            var array = std.json.Array.init(alloc);
            for (0..random.uintLessThan(usize, 4)) |_| try array.append(try randomRequestValue(alloc, random, depth - 1));
            return .{ .array = array };
        },
        else => return randomRequestObject(alloc, random, depth - 1),
    }
}

fn randomRequestObject(alloc: std.mem.Allocator, random: std.Random, depth: u8) std.mem.Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    for (0..random.uintLessThan(usize, 5)) |_| {
        const key = try randomRequestText(alloc, random, random.uintLessThan(usize, 8));
        try object.put(alloc, key, try randomRequestValue(alloc, random, depth));
    }
    return .{ .object = object };
}

test "request wrapper round-trips seeded objects and refuses every other value" {
    // The runner's --seed replays a failing run.
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();
    var decoded: usize = 0;
    var refused_objects: usize = 0;
    for (0..400) |iteration| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const at_bound = iteration % 8 == 0;
        var value = if (at_bound or random.boolean())
            try randomRequestObject(arena, random, 3)
        else
            try randomRequestValue(arena, random, 3);
        if (at_bound) {
            // Pad the text to one byte under the bound, the bound, or one
            // byte over it, in turn. Each `a` adds one byte.
            try value.object.put(arena, "pad", .{ .string = "" });
            const unpadded = (try std.json.Stringify.valueAlloc(arena, value, .{})).len;
            const target = max_request_text_bytes - 1 + (iteration / 8) % 3;
            const pad = try arena.alloc(u8, target - unpadded);
            @memset(pad, 'a');
            try value.object.put(arena, "pad", .{ .string = pad });
        }
        const text = try std.json.Stringify.valueAlloc(arena, value, .{});
        if (at_bound) try std.testing.expectEqual(max_request_text_bytes - 1 + (iteration / 8) % 3, text.len);
        const read = try requestWrapperObject(arena, .{ .string = text });
        if (value == .object and text.len <= max_request_text_bytes) {
            const again = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = read.? }, .{});
            try std.testing.expectEqualStrings(text, again);
            decoded += 1;
        } else {
            try std.testing.expectEqual(@as(?std.json.ObjectMap, null), read);
            if (value == .object) refused_objects += 1;
        }
        if (value == .object) {
            try std.testing.expectEqual(value.object.keys().ptr, (try requestWrapperObject(arena, value)).?.keys().ptr);
        }
    }
    try std.testing.expect(decoded > 0);
    try std.testing.expect(refused_objects > 0);
}

fn fuzzRequestWrapperText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_request_text_bytes + 1]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];
    // Text that is not UTF-8 fails the argument parse before a request
    // wrapper is read, so it never reaches this decode.
    if (!std.unicode.utf8ValidateSlice(text)) return;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const object = (try requestWrapperObject(arena, .{ .string = text })) orelse return;
    try std.testing.expect(text.len <= max_request_text_bytes);
    try std.testing.expect(!json_depth.exceeds(text));
    // The call fx stores is the decoded object's own text, which must read
    // back as the same object.
    const stored = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = object }, .{});
    if (stored.len > max_request_text_bytes) return;
    const reread = (try requestWrapperObject(arena, .{ .string = stored })).?;
    const restored = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = reread }, .{});
    try std.testing.expectEqualStrings(stored, restored);
}

test "request wrapper text decodes to a bounded object or is refused on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzRequestWrapperText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"action\":\"run\",\"command\":\"printf ok\"}",
            "{\"handle\":\"h.txt\",\"query\":\"needle\"}",
            "{\"a\":{\"b\":[1,2.5,{\"c\":null}]},\"d\":\"\\u0000\"}",
            "{\"n\":1e400,\"m\":-0.0}",
            "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]",
            // Past the 64-level limit and the 256 levels where std.json.Stringify
            // aborts a safe build.
            "{\"a\":" ++ text_utils.repeat("{\"a\":", 299) ++ "0" ++ text_utils.repeat("}", 300),
            "\"{}\"",
            "{",
            "",
        }) ++ @import("fuzz_corpus").request_wrapper_text.*),
    });
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

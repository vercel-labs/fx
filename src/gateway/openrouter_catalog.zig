//! OpenRouter's live model list (D146). `GET <base>/models` is public; the
//! models that take tools are returned to the app registry, which owns their
//! provider-keyed persistence and capability lookup.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const http = @import("client.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

const max_models = 2048;
const max_body_bytes = 16 * 1024 * 1024;
const reasoning_efforts = [_]types.ReasoningEffort{ .literal("low"), .literal("medium"), .literal("high") };

/// Models from one fetch or the cache. `models` and their ids live in `arena`.
pub const Fetched = struct {
    models: []const definitions.ModelMetadata = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Fetched, alloc: Allocator) void {
        if (self.arena) |arena| {
            arena.deinit();
            alloc.destroy(arena);
        }
        self.* = .{};
    }
};

/// The live list from `base_url`. Runtime owns stale-snapshot retention and
/// durable persistence when the network fails.
pub fn fetch(alloc: Allocator, base_url: []const u8, cancel_flag: ?*std.atomic.Value(bool)) Fetched {
    return fetchOrError(alloc, base_url, cancel_flag) catch .{};
}

fn fetchOrError(alloc: Allocator, base_url: []const u8, cancel_flag: ?*std.atomic.Value(bool)) !Fetched {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    var result: Fetched = .{ .arena = arena };
    errdefer result.deinit(alloc);
    const a = arena.allocator();
    const url = try a.print("{s}/models", .{base_url});
    var local_cancel = std.atomic.Value(bool).init(false);
    const live: ?[]u8 = if (http.fetchGatewayJsonAtUrlCancellable(a, null, null, url, cancel_flag orelse &local_cancel, 10_000)) |response| switch (response) {
        .success => |bytes| bytes,
        .http_status => null,
    } else |_| null;
    if (live) |bytes| result.models = try parse(a, bytes);
    // Runtime-owned provider snapshots retain the previous catalog after a
    // failed refresh. This adapter deliberately has no second profile or
    // process cache, so every live result follows the same publication path.
    return result;
}

/// Keeps models that take tools. Strings borrow from `arena`.
pub fn parse(arena: Allocator, bytes: []const u8) ![]const definitions.ModelMetadata {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always }) catch return &.{};
    if (root != .object) return &.{};
    const data = root.object.get("data") orelse return &.{};
    if (data != .array) return &.{};
    var models: std.ArrayList(definitions.ModelMetadata) = .empty;
    for (data.array.items) |item| {
        if (models.items.len >= max_models) break;
        if (item != .object) continue;
        const id = item.object.get("id") orelse continue;
        if (id != .string) continue;
        definitions.validate_model_id(id.string) catch continue;
        if (!hasString(item.object.get("supported_parameters"), "tools")) continue;
        var metadata: definitions.ModelMetadata = .{ .id = id.string, .supports_tool_use = true };
        metadata.name = stringValue(item.object.get("name"));
        metadata.description = stringValue(item.object.get("description"));
        metadata.cost = parseCost(item.object.get("pricing"));
        metadata.intelligence = numberValue(item.object.get("intelligence") orelse item.object.get("int"));
        metadata.recommended = boolValue(item.object.get("recommended"));
        metadata.beta = boolValue(item.object.get("beta"));
        metadata.released = integerValue(item.object.get("released") orelse item.object.get("created"));
        metadata.context_window = positive(item.object.get("context_length"));
        if (item.object.get("top_provider")) |top| if (top == .object) {
            metadata.max_output_tokens = positive(top.object.get("max_completion_tokens"));
        };
        if (metadata.context_window != null and metadata.max_output_tokens != null and metadata.max_output_tokens.? >= metadata.context_window.?) metadata.max_output_tokens = null;
        if (item.object.get("architecture")) |architecture| if (architecture == .object) {
            metadata.supports_vision = hasString(architecture.object.get("input_modalities"), "image");
        };
        if (hasString(item.object.get("supported_parameters"), "reasoning")) metadata.reasoning_efforts = &reasoning_efforts;
        try models.append(arena, metadata);
    }
    return models.items;
}

fn hasString(value: ?std.json.Value, wanted: []const u8) bool {
    const list = value orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, wanted)) return true;
    return false;
}

fn positive(value: ?std.json.Value) ?u32 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0 or present.integer > std.math.maxInt(u32)) return null;
    return @intCast(present.integer);
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string and present.string.len > 0) present.string else null;
}

fn boolValue(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return if (present == .bool) present.bool else false;
}

fn integerValue(value: ?std.json.Value) i64 {
    const present = value orelse return 0;
    return if (present == .integer and present.integer >= 0 and present.integer <= std.math.maxInt(i64)) @intCast(present.integer) else 0;
}

fn numberValue(value: ?std.json.Value) ?f64 {
    const present = value orelse return null;
    const number: f64 = switch (present) {
        .integer => @floatFromInt(present.integer),
        .float => present.float,
        .string => std.fmt.parseFloat(f64, present.string) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(number) and number >= 0) number else null;
}

fn parseCost(value: ?std.json.Value) ?definitions.ModelCost {
    const object = value orelse return null;
    if (object != .object) return null;
    var cost: definitions.ModelCost = .{};
    var found = false;
    if (numberValue(object.object.get("prompt"))) |rate| {
        cost.input = rate * 1_000_000;
        found = true;
    }
    if (numberValue(object.object.get("completion"))) |rate| {
        cost.output = rate * 1_000_000;
        found = true;
    }
    if (numberValue(object.object.get("input_cache_read") orelse object.object.get("cache_read"))) |rate| {
        cost.cache_read = rate * 1_000_000;
        found = true;
    }
    if (numberValue(object.object.get("input_cache_write") orelse object.object.get("cache_write"))) |rate| {
        cost.cache_write = rate * 1_000_000;
        found = true;
    }
    return if (found) cost else null;
}

test "OpenRouter catalog keeps tool models with their limits and modalities" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const models = try parse(arena_state.allocator(),
        \\{"data":[{"id":"anthropic/claude-sonnet-5.5","name":"Claude Sonnet","description":"A capable model","pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.000001","input_cache_write":"0.000002"},"intelligence":88,"recommended":true,"beta":true,"released":123,"context_length":1000000,"top_provider":{"max_completion_tokens":64000},"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools","reasoning","max_tokens"]},
        \\{"id":"some/chat-only","context_length":8192,"supported_parameters":["max_tokens"]},
        \\{"id":"x-ai/grok-code","context_length":256000,"top_provider":{"max_completion_tokens":null},"architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]},
        \\{"id":"","supported_parameters":["tools"]},"junk"]}
    );
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-5.5", models[0].id);
    try std.testing.expectEqual(@as(?u32, 1_000_000), models[0].context_window);
    try std.testing.expectEqual(@as(?u32, 64_000), models[0].max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), models[0].supports_vision);
    try std.testing.expectEqualStrings("Claude Sonnet", models[0].name.?);
    try std.testing.expectEqualStrings("A capable model", models[0].description.?);
    try std.testing.expectEqual(@as(f64, 3), models[0].cost.?.input);
    try std.testing.expectEqual(@as(f64, 15), models[0].cost.?.output);
    try std.testing.expectEqual(@as(f64, 1), models[0].cost.?.cache_read);
    try std.testing.expectEqual(@as(f64, 2), models[0].cost.?.cache_write);
    try std.testing.expectEqual(@as(?f64, 88), models[0].intelligence);
    try std.testing.expect(models[0].recommended);
    try std.testing.expect(models[0].beta);
    try std.testing.expectEqual(@as(i64, 123), models[0].released);
    try std.testing.expectEqual(@as(usize, 3), models[0].reasoning_efforts.len);
    try std.testing.expect(models[1].max_output_tokens == null);
    try std.testing.expectEqual(@as(?bool, false), models[1].supports_vision);
    try std.testing.expectEqual(@as(usize, 0), models[1].reasoning_efforts.len);
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena_state.allocator(), "not json")).len);
}

//! OpenRouter's live model list (D146). `GET <base>/models` is public; the
//! models that take tools are kept, cached in the profile, and answer
//! capability lookups for models outside the preset's starter list.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const http = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

pub const cache_file_name = "openrouter-models.json";
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

/// The live list from `base_url`, refreshing the cache, or the cached list
/// when the network fails. Empty when neither is available.
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
    if (live) |bytes| {
        result.models = try parse(a, bytes);
        if (result.models.len != 0) writeCache(a, bytes) catch {};
        return result;
    }
    const cached = (try readCache(a)) orelse return result;
    result.models = try parse(a, cached);
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

fn cachePath(alloc: Allocator) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    return try std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, cache_file_name });
}

fn writeCache(arena: Allocator, bytes: []const u8) !void {
    const path = (try cachePath(arena)) orelse return;
    try io_mod.writeFileAtomic(arena, path, bytes);
}

fn readCache(arena: Allocator) !?[]u8 {
    const path = (try cachePath(arena)) orelse return null;
    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch return null;
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(arena, &file, max_body_bytes);
}

var lookup_mutex: std.Io.Mutex = .init;
var lookup_loaded = false;
var lookup_cache: Fetched = .{};

/// Capabilities of `model` from the cached catalog, loaded once per process.
/// The result borrows process-lifetime storage.
pub fn lookup(model: []const u8) ?definitions.ModelMetadata {
    const io = io_mod.getIo();
    lookup_mutex.lockUncancelable(io);
    defer lookup_mutex.unlock(io);
    if (!lookup_loaded) {
        lookup_loaded = true;
        lookup_cache = loadCached(std.heap.c_allocator) catch .{};
    }
    for (lookup_cache.models) |metadata| if (std.mem.eql(u8, metadata.id, model)) return metadata;
    return null;
}

fn loadCached(alloc: Allocator) !Fetched {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    var result: Fetched = .{ .arena = arena };
    errdefer result.deinit(alloc);
    const bytes = (try readCache(arena.allocator())) orelse return result;
    result.models = try parse(arena.allocator(), bytes);
    return result;
}

test "OpenRouter catalog keeps tool models with their limits and modalities" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const models = try parse(arena_state.allocator(),
        \\{"data":[{"id":"anthropic/claude-sonnet-5.5","context_length":1000000,"top_provider":{"max_completion_tokens":64000},"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools","reasoning","max_tokens"]},
        \\{"id":"some/chat-only","context_length":8192,"supported_parameters":["max_tokens"]},
        \\{"id":"x-ai/grok-code","context_length":256000,"top_provider":{"max_completion_tokens":null},"architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]},
        \\{"id":"","supported_parameters":["tools"]},"junk"]}
    );
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-5.5", models[0].id);
    try std.testing.expectEqual(@as(?u32, 1_000_000), models[0].context_window);
    try std.testing.expectEqual(@as(?u32, 64_000), models[0].max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), models[0].supports_vision);
    try std.testing.expectEqual(@as(usize, 3), models[0].reasoning_efforts.len);
    try std.testing.expect(models[1].max_output_tokens == null);
    try std.testing.expectEqual(@as(?bool, false), models[1].supports_vision);
    try std.testing.expectEqual(@as(usize, 0), models[1].reasoning_efforts.len);
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena_state.allocator(), "not json")).len);
}

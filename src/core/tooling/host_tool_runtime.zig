const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set = @import("tool_set.zig");

const Allocator = std.mem.Allocator;

pub const max_tools: usize = 64;
pub const max_name_bytes: usize = 64;
pub const max_description_bytes: usize = 64 * 1024;
pub const max_schema_bytes: usize = 64 * 1024;

pub const ParseError = Allocator.Error || error{
    TooManyHostTools,
    InvalidHostTool,
    InvalidHostToolName,
    DuplicateHostToolName,
    UnsupportedProviderTool,
    HostToolDescriptionTooLarge,
    HostToolSchemaTooLarge,
};

pub const Runtime = struct {
    backing: ?Allocator = null,
    arena: ?*std.heap.ArenaAllocator = null,
    tools: []const tool_dispatch.Tool = &.{},
    order: []const []const u8 = &.{},
    dynamic_tools: []const stream_provider.DynamicFunctionTool = &.{},

    pub fn init(backing: Allocator, value: ?std.json.Value) ParseError!Runtime {
        return initWithProviderRegistry(backing, value, .{});
    }

    pub fn initWithProviderRegistry(
        backing: Allocator,
        value: ?std.json.Value,
        provider_registry: tool_dispatch.Registry,
    ) ParseError!Runtime {
        const tools_value = value orelse return .{};
        if (tools_value != .array) return error.InvalidHostTool;
        if (tools_value.array.items.len > max_tools) return error.TooManyHostTools;
        if (tools_value.array.items.len == 0) return .{};

        var dynamic_count: usize = 0;
        for (tools_value.array.items) |entry| {
            if (entry != .object) return error.InvalidHostTool;
            const provider_executed = if (entry.object.get("providerExecuted")) |value_| switch (value_) {
                .bool => |enabled| enabled,
                else => return error.InvalidHostTool,
            } else false;
            if (!provider_executed) dynamic_count += 1;
        }

        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer mem_utils.deinit_arena(arena.*);
        const alloc = arena.allocator();

        const tools = try alloc.alloc(tool_dispatch.Tool, tools_value.array.items.len);
        const order = try alloc.alloc([]const u8, tools.len);
        const dynamic_tools = try alloc.alloc(stream_provider.DynamicFunctionTool, dynamic_count);
        var dynamic_index: usize = 0;

        for (tools_value.array.items, 0..) |entry, index| {
            const name_value = entry.object.get("name") orelse return error.InvalidHostTool;
            if (name_value != .string) return error.InvalidHostTool;
            if (!validName(name_value.string)) return error.InvalidHostToolName;
            for (order[0..index]) |prior| {
                if (std.mem.eql(u8, prior, name_value.string)) {
                    return error.DuplicateHostToolName;
                }
            }

            const provider_executed = if (entry.object.get("providerExecuted")) |value_| value_.bool else false;
            if (provider_executed) {
                const registered = provider_registry.lookup(name_value.string) orelse
                    return error.UnsupportedProviderTool;
                if (!registered.provider_executed or registered.write_provider_advertisement_fn == null) {
                    return error.UnsupportedProviderTool;
                }
                order[index] = registered.name;
                tools[index] = registered.*;
                continue;
            }

            const description_value = entry.object.get("description") orelse return error.InvalidHostTool;
            const schema_value = entry.object.get("inputSchema") orelse return error.InvalidHostTool;
            // A tool that writes is a fence: earlier calls finish before it
            // starts, and later calls wait for it.
            const writes = if (entry.object.get("writes")) |value_| switch (value_) {
                .bool => |declared| declared,
                else => return error.InvalidHostTool,
            } else false;
            if (description_value != .string or schema_value != .object) return error.InvalidHostTool;
            if (description_value.string.len > max_description_bytes) {
                return error.HostToolDescriptionTooLarge;
            }

            const name = try alloc.dupe(u8, name_value.string);
            const description = try alloc.dupe(u8, description_value.string);
            var schema_out: std.Io.Writer.Allocating = .init(alloc);
            defer schema_out.deinit();
            std.json.Stringify.value(schema_value, .{}, &schema_out.writer) catch
                return error.OutOfMemory;
            if (schema_out.written().len > max_schema_bytes) {
                return error.HostToolSchemaTooLarge;
            }
            const schema_json = try schema_out.toOwnedSlice();
            const schema = std.json.parseFromSliceLeaky(
                std.json.Value,
                alloc,
                schema_json,
                .{},
            ) catch return error.InvalidHostTool;

            order[index] = name;
            dynamic_tools[dynamic_index] = .{
                .name = name,
                .description = description,
                .input_schema = schema,
            };
            dynamic_index += 1;
            tools[index] = .{
                .name = name,
                .description = "",
                .model_schema = .{ .name = name, .description = "" },
                .model_visible = false,
                .host_concurrent = !writes,
                .executor_kind = .host,
                .activity_kind = .command,
                .action_label = "Running",
                .completed_action_label = "Ran",
                .decode = decode,
                .call = call,
                .reads_only_fn = readsOnly,
                .irreversible_fn = irreversible,
            };
        }

        return .{
            .backing = backing,
            .arena = arena,
            .tools = tools,
            .order = order,
            .dynamic_tools = dynamic_tools,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.arena) |arena| {
            const backing = self.backing.?;
            mem_utils.deinit_arena(arena.*);
            backing.destroy(arena);
        }
        self.* = .{};
    }

    pub fn toolSet(self: *const Runtime) tool_set.ToolSet {
        return .{
            .registry = .{ .tools = self.tools },
            .order = self.order,
            .read_only_tool_names = self.order,
        };
    }
};

/// Retains a provider tool's model and Gateway contracts without linking its
/// unreachable local executor into minimal libfx builds.
pub fn providerProjection(tool: tool_dispatch.Tool) tool_dispatch.Tool {
    std.debug.assert(tool.provider_executed);
    std.debug.assert(tool.write_provider_advertisement_fn != null);
    var projected = tool;
    projected.validate = null;
    projected.decode = decode;
    projected.call = call;
    projected.reads_only_fn = readsOnly;
    projected.irreversible_fn = irreversible;
    return projected;
}

const RawInput = struct {
    json: []u8,
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn rawInputDeinit(raw: *anyopaque, alloc: Allocator) void {
    const input: *RawInput = @ptrCast(@alignCast(raw));
    alloc.free(input.json);
    alloc.destroy(input);
}

fn decode(
    ctx: tool_dispatch.DispatchContext,
    arguments_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, arguments_json, .{}) catch
        return error.InvalidToolArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;

    const input = try ctx.allocator.create(RawInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .json = try ctx.allocator.dupe(u8, arguments_json) };
    return .{ .input = .{ .ptr = input, .deinit_fn = rawInputDeinit } };
}

fn call(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.host_tool_provider orelse return .{
        .failure = try ctx.allocator.dupe(u8, "Host tool executor is unavailable"),
    };
    return provider.call(
        ctx.allocator,
        ctx.tool_call_name,
        ctx.tool_call_id,
        input.as(RawInput).json,
        ctx.max_tool_result_bytes,
        ctx.cancel_flag,
    );
}

fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn irreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn writeTestProviderAdvertisement(
    _: Allocator,
    writer: *std.Io.Writer,
) tool_dispatch.ProviderAdvertisementError!void {
    try writer.writeAll("{\"type\":\"provider\",\"id\":\"gateway.test_search\",\"name\":\"test_search\",\"args\":{}}");
}

const test_provider_tool = tool_dispatch.Tool{
    .name = "web_search",
    .description = "Search the web",
    .model_schema = .{ .name = "web_search", .description = "Search the web" },
    .write_provider_advertisement_fn = writeTestProviderAdvertisement,
    .provider_executed = true,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = irreversible,
};

test "host tool runtime validates and preserves raw schemas" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\[{"name":"lookup","description":"Look up a value","inputSchema":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}}]
    ,
        .{},
    );
    defer parsed.deinit();
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), runtime.tools.len);
    try std.testing.expect(runtime.toolSet().registry.lookup("lookup") != null);
    try std.testing.expectEqualStrings("lookup", runtime.dynamic_tools[0].name);
    try std.testing.expect(runtime.dynamic_tools[0].input_schema.object.get("properties") != null);
}

test "host tool runtime projects registered provider tools without host executors" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\[{"name":"lookup","description":"Look up a value","inputSchema":{}},{"name":"web_search","providerExecuted":true}]
    ,
        .{},
    );
    defer parsed.deinit();
    var runtime = try Runtime.initWithProviderRegistry(
        alloc,
        parsed.value,
        .{ .tools = &.{test_provider_tool} },
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 2), runtime.tools.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.dynamic_tools.len);
    try std.testing.expectEqualStrings("lookup", runtime.dynamic_tools[0].name);
    const provider = runtime.toolSet().registry.lookup("web_search").?;
    try std.testing.expect(provider.provider_executed);
    try std.testing.expect(provider.write_provider_advertisement_fn != null);
}

test "host tool runtime rejects unknown provider tools" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\[{"name":"unknown","providerExecuted":true}]
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.UnsupportedProviderTool,
        Runtime.initWithProviderRegistry(alloc, parsed.value, .{ .tools = &.{test_provider_tool} }),
    );
}

test "host tool runtime preserves long MCP descriptions" {
    const alloc = std.testing.allocator;
    const description = "Tool parameter guidance. " ** 100;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "[{\"name\":\"lookup\",\"description\":\"" ++ description ++ "\",\"inputSchema\":{}}]",
        .{},
    );
    defer parsed.deinit();
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();
    try std.testing.expectEqualStrings(description, runtime.dynamic_tools[0].description);
}

test "host tool runtime bounds descriptions at 64 KiB" {
    const alloc = std.testing.allocator;
    const description = try alloc.alloc(u8, 64 * 1024 + 1);
    defer alloc.free(description);
    @memset(description, 'a');
    for ([_]usize{ 64 * 1024, 64 * 1024 + 1 }) |length| {
        const json = try std.fmt.allocPrint(alloc, "[{{\"name\":\"lookup\",\"description\":\"{s}\",\"inputSchema\":{{}}}}]", .{description[0..length]});
        defer alloc.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        if (length == 64 * 1024) {
            var runtime = try Runtime.init(alloc, parsed.value);
            defer runtime.deinit();
            try std.testing.expectEqualStrings(description[0..length], runtime.dynamic_tools[0].description);
        } else {
            try std.testing.expectError(error.HostToolDescriptionTooLarge, Runtime.init(alloc, parsed.value));
        }
    }
}

test "host tools run concurrently unless they declare writes" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[{"name":"read","description":"Read","inputSchema":{}},
        \\ {"name":"write","description":"Write","inputSchema":{},"writes":true}]
    , .{});
    defer parsed.deinit();
    var runtime = try Runtime.init(std.testing.allocator, parsed.value);
    defer runtime.deinit();
    try std.testing.expect(runtime.tools[0].host_concurrent);
    try std.testing.expect(!runtime.tools[1].host_concurrent);

    const invalid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[{"name":"write","description":"Write","inputSchema":{},"writes":"yes"}]
    , .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidHostTool, Runtime.init(std.testing.allocator, invalid.value));
}

test "host tool runtime rejects duplicate and invalid names" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        \\[{"name":"bad name","description":"bad","inputSchema":{}}]
        ,
        \\[{"name":"same","description":"one","inputSchema":{}},{"name":"same","description":"two","inputSchema":{}}]
        ,
    };
    for (cases) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            if (std.mem.indexOf(u8, json, "bad name") != null)
                error.InvalidHostToolName
            else
                error.DuplicateHostToolName,
            Runtime.init(alloc, parsed.value),
        );
    }
}

const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
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
        const tools_value = value orelse return .{};
        if (tools_value != .array) return error.InvalidHostTool;
        if (tools_value.array.items.len > max_tools) return error.TooManyHostTools;
        if (tools_value.array.items.len == 0) return .{};

        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const tools = try alloc.alloc(tool_dispatch.Tool, tools_value.array.items.len);
        const order = try alloc.alloc([]const u8, tools.len);
        const dynamic_tools = try alloc.alloc(stream_provider.DynamicFunctionTool, tools.len);

        for (tools_value.array.items, 0..) |entry, index| {
            if (entry != .object) return error.InvalidHostTool;
            const name_value = entry.object.get("name") orelse return error.InvalidHostTool;
            const description_value = entry.object.get("description") orelse return error.InvalidHostTool;
            const schema_value = entry.object.get("inputSchema") orelse return error.InvalidHostTool;
            if (name_value != .string or description_value != .string or schema_value != .object) {
                return error.InvalidHostTool;
            }
            if (!validName(name_value.string)) return error.InvalidHostToolName;
            if (description_value.string.len > max_description_bytes) {
                return error.HostToolDescriptionTooLarge;
            }
            for (order[0..index]) |prior| {
                if (std.mem.eql(u8, prior, name_value.string)) {
                    return error.DuplicateHostToolName;
                }
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
            dynamic_tools[index] = .{
                .name = name,
                .description = description,
                .input_schema = schema,
            };
            tools[index] = .{
                .name = name,
                .description = "",
                .model_schema = .{ .name = name, .description = "" },
                .model_visible = false,
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
            arena.deinit();
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

const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const max_source_bytes: usize = 64 * 1024;

pub const Input = struct {
    source: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.source);
        self.* = .{ .source = &.{} };
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        ctx.allocator,
        args_json,
        .{},
    ) catch {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "code arguments must be valid JSON",
        ) };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "code arguments must be an object",
        ) };
    }
    if (parsed.value.object.count() != 1) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "code accepts only field \"source\"",
        ) };
    }
    const source = parsed.value.object.get("source") orelse {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "code requires string field \"source\"",
        ) };
    };
    if (source != .string) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "code field \"source\" must be a string",
        ) };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .source = try ctx.allocator.dupe(u8, source.string) };
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = inputDeinit,
    } };
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const source = erased.as(Input).source;
    if (source.len == 0) {
        return try ctx.allocator.dupe(u8, "code source must not be empty");
    }
    if (source.len > max_source_bytes) {
        return try ctx.allocator.dupe(u8, "code source exceeds 65536 bytes");
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "code is available only through the agent runtime",
    ) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

test "code input rejects unknown fields and oversized source" {
    const tool = tool_dispatch.Tool{
        .name = "code",
        .description = "test",
        .model_schema = .{
            .name = "code",
            .description = "test",
            .input_schema = .{},
        },
        .executor_kind = .code,
        .decode = decode,
        .validate = validate,
        .call = call,
        .reads_only_fn = readsOnly,
        .irreversible_fn = isIrreversible,
    };
    const registry = tool_dispatch.Registry{ .tools = &.{tool} };
    const ctx = tool_dispatch.DispatchContext{
        .allocator = std.testing.allocator,
    };

    var status_detail: ?[]u8 = null;
    defer if (status_detail) |detail| std.testing.allocator.free(detail);
    var extra = try tool_dispatch.dispatchAuthorizedToolCall(
        ctx,
        registry,
        .{
            .id = "extra",
            .name = "code",
            .arguments_json = "{\"source\":\"return 1\",\"extra\":true}",
        },
        &status_detail,
    );
    defer extra.deinit(std.testing.allocator);
    try std.testing.expectEqual(.failure, extra.status);

    const source = try std.testing.allocator.alloc(u8, max_source_bytes + 1);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    const input = Input{ .source = source };
    const failure = (try validate(
        ctx,
        .{
            .ptr = @constCast(&input),
            .deinit_fn = inputDeinit,
        },
    )).?;
    defer std.testing.allocator.free(failure);
    try std.testing.expectEqualStrings(
        "code source exceeds 65536 bytes",
        failure,
    );
}

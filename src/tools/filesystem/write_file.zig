const std = @import("std");
const file_mutation_contract = @import("../../core/tooling/file_mutation_contract.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");

const Allocator = std.mem.Allocator;
const max_content_bytes: usize = 4 * 1024 * 1024;

/// Typed input for the built-in write_file tool.
pub const Input = struct {
    path: []u8,
    content: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.content);
        self.* = .{ .path = &.{}, .content = &.{} };
    }
};

/// Decodes write_file JSON into an owned Input released by ToolInput.deinit.
pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "write_file" };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const path = args.requiredString(parsed.value.object, "path") catch |err| return .{ .failure = try args.takeFailure(err) };
    const content = args.requiredString(parsed.value.object, "content") catch |err| return .{ .failure = try args.takeFailure(err) };

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    const owned_path = try ctx.allocator.dupe(u8, path);
    errdefer ctx.allocator.free(owned_path);
    const owned_content = try ctx.allocator.dupe(u8, content);
    errdefer ctx.allocator.free(owned_content);
    input.* = .{
        .path = owned_path,
        .content = owned_content,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn takeFileMutationInput(
    tool_input: tool_dispatch.ToolInput,
    alloc: Allocator,
) file_mutation_contract.FileMutationInput {
    const input = tool_input.as(Input);
    const moved = file_mutation_contract.WriteInput{
        .path = input.path,
        .content = input.content,
    };
    alloc.destroy(input);
    return .{ .write = moved };
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    tool_input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = tool_input.as(Input);
    if (input.path.len > std.Io.Dir.max_path_bytes) {
        return try ctx.allocator.dupe(
            u8,
            "file mutation preparation failed: path exceeds the preparation limit",
        );
    }
    if (input.content.len > max_content_bytes) {
        return try ctx.allocator.dupe(
            u8,
            "write_file failed: content exceeds the 4 MiB preparation limit",
        );
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "write_file execution requires canonical tool runtime authorization",
    ) };
}

/// Reports that write_file mutates filesystem state.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Reports that write_file can destroy prior file content.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

test "write_file decodes invalid argument shapes as failures" {
    const cases = [_]struct {
        json: []const u8,
        reason: []const u8,
    }{
        .{ .json = "{", .reason = "write_file arguments must be valid JSON" },
        .{ .json = "[]", .reason = "write_file arguments must be an object" },
        .{ .json = "{\"content\":\"x\"}", .reason = "write_file requires string field \"path\"" },
        .{ .json = "{\"path\":1,\"content\":\"x\"}", .reason = "write_file field \"path\" must be a string" },
        .{ .json = "{\"path\":\"/tmp/x\"}", .reason = "write_file requires string field \"content\"" },
        .{ .json = "{\"path\":\"/tmp/x\",\"content\":1}", .reason = "write_file field \"content\" must be a string" },
    };

    for (cases) |case| {
        const decoded = try decode(
            .{ .allocator = std.testing.allocator },
            case.json,
        );
        switch (decoded) {
            .failure => |reason| {
                defer std.testing.allocator.free(reason);
                try std.testing.expectEqualStrings(case.reason, reason);
            },
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestExpectedDecodeFailure;
            },
        }
    }
}

test "write_file decodes owned typed input" {
    const decoded = try decode(
        .{ .allocator = std.testing.allocator },
        "{\"path\":\"file.txt\",\"content\":\"hello\\n\"}",
    );
    const erased = switch (decoded) {
        .input => |input| input,
        .failure => |reason| {
            defer std.testing.allocator.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
    defer erased.deinit(std.testing.allocator);
    const input = erased.as(Input);
    try std.testing.expectEqualStrings("file.txt", input.path);
    try std.testing.expectEqualStrings("hello\n", input.content);
    try std.testing.expect(
        try validate(.{ .allocator = std.testing.allocator }, erased) == null,
    );
}

test "write_file validation enforces path and content preparation limits" {
    const alloc = std.testing.allocator;
    const oversized_path = try alloc.alloc(u8, std.Io.Dir.max_path_bytes + 1);
    defer alloc.free(oversized_path);
    @memset(oversized_path, 'p');
    const oversized_content = try alloc.alloc(u8, 4 * 1024 * 1024 + 1);
    defer alloc.free(oversized_content);
    @memset(oversized_content, 'x');

    const cases = [_]struct {
        input: Input,
        reason: []const u8,
    }{
        .{
            .input = .{
                .path = oversized_path,
                .content = @constCast("content"),
            },
            .reason = "file mutation preparation failed: path exceeds the preparation limit",
        },
        .{
            .input = .{
                .path = @constCast("file.txt"),
                .content = oversized_content,
            },
            .reason = "write_file failed: content exceeds the 4 MiB preparation limit",
        },
    };

    for (cases) |case| {
        var input = case.input;
        const erased = tool_dispatch.ToolInput{
            .ptr = &input,
            .deinit_fn = noopInputDeinit,
        };
        const reason = try validate(.{ .allocator = alloc }, erased) orelse
            return error.TestExpectedValidationFailure;
        defer alloc.free(reason);
        try std.testing.expectEqualStrings(case.reason, reason);
    }
}

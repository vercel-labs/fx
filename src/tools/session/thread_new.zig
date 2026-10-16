//! `thread_new`: the model starts a named thread with a task, when the user
//! asks for one. It returns at once; the thread works on its own.

const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const subagent_domain = @import("../../core/subagent/domain.zig");
const thread_tool_provider = @import("../../core/threads/thread_tool_provider.zig");

const Allocator = std.mem.Allocator;

pub const max_task_bytes = subagent_domain.max_message_bytes;

pub const Input = struct {
    name: []u8,
    task: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.task);
        self.* = .{ .name = &.{}, .task = &.{} };
    }
};

fn failure(ctx: tool_dispatch.DispatchContext, comptime text: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, text) };
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx, "thread_new arguments must be valid JSON"),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failure(ctx, "thread_new arguments must be an object");
    const object = parsed.value.object;
    for (object.keys()) |key| {
        if (!std.mem.eql(u8, key, "name") and !std.mem.eql(u8, key, "task")) {
            return failure(ctx, "thread_new accepts only \"name\" and \"task\"");
        }
    }
    const name_value = object.get("name") orelse return failure(ctx, "thread_new requires string field \"name\"");
    if (name_value != .string) return failure(ctx, "thread_new field \"name\" must be a string");
    if (name_value.string.len == 0) return failure(ctx, "thread_new field \"name\" must not be empty");
    const task_value = object.get("task") orelse return failure(ctx, "thread_new requires string field \"task\"");
    if (task_value != .string) return failure(ctx, "thread_new field \"task\" must be a string");
    if (std.mem.trim(u8, task_value.string, " \t\r\n").len == 0) {
        return failure(ctx, "thread_new field \"task\" must not be empty");
    }
    if (task_value.string.len > max_task_bytes) {
        return failure(ctx, "thread_new field \"task\" is too long");
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    const name = try ctx.allocator.dupe(u8, name_value.string);
    errdefer ctx.allocator.free(name);
    input.* = .{ .name = name, .task = try ctx.allocator.dupe(u8, task_value.string) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.thread_provider orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "Threads are not available in this session.") };
    const input = erased.as(Input);
    const result = try provider.execute(
        ctx.allocator,
        .{ .new = .{ .name = input.name, .task = input.task } },
        ctx.tool_call_id,
    );
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const Fixture = struct {
    seen_name: ?[]const u8 = null,
    seen_task: ?[]const u8 = null,
    invocation_id: ?[]const u8 = null,

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: thread_tool_provider.Request,
        invocation_id: []const u8,
    ) thread_tool_provider.ExecuteError!thread_tool_provider.Result {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        switch (request) {
            .new => |s| {
                self.seen_name = s.name;
                self.seen_task = s.task;
                self.invocation_id = invocation_id;
            },
            .read, .send => unreachable,
        }
        return .{ .status = .success, .body = try alloc.dupe(u8, "started") };
    }
};

fn expectDecodeFailure(args_json: []const u8) !void {
    const alloc = std.testing.allocator;
    switch (try decode(.{ .allocator = alloc }, args_json)) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| alloc.free(message),
    }
}

test "decode requires a name and a non-empty task" {
    for ([_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"name\":\"a\"}",
        "{\"task\":\"hi\"}",
        "{\"name\":\"\",\"task\":\"hi\"}",
        "{\"name\":\"a\",\"task\":\"  \"}",
        "{\"name\":1,\"task\":\"hi\"}",
        "{\"name\":\"a\",\"task\":2}",
        "{\"name\":\"a\",\"task\":\"hi\",\"create\":true}",
    }) |bad| try expectDecodeFailure(bad);
}

test "decode rejects an oversized task" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, max_task_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'x');
    const json = try alloc.print("{{\"name\":\"a\",\"task\":\"{s}\"}}", .{big});
    defer alloc.free(json);
    try expectDecodeFailure(json);
}

test "call forwards the name, task, and call id without waiting" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{};
    const decoded = try decode(.{ .allocator = alloc }, "{\"name\":\"fix-auth\",\"task\":\"also check logout\"}");
    const input = decoded.input;
    defer input.deinit(alloc);
    const result = try call(.{
        .allocator = alloc,
        .tool_call_id = "call-9",
        .thread_provider = .{ .context = &fixture, .execute_fn = Fixture.execute },
    }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("started", result.success);
    try std.testing.expectEqualStrings("fix-auth", fixture.seen_name.?);
    try std.testing.expectEqualStrings("also check logout", fixture.seen_task.?);
    try std.testing.expectEqualStrings("call-9", fixture.invocation_id.?);
}

test "call without a provider reports threads unavailable" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"name\":\"a\",\"task\":\"hi\"}");
    const input = decoded.input;
    defer input.deinit(alloc);
    const result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expect(result == .failure);
}

test "thread_new is not read only" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"name\":\"a\",\"task\":\"hi\"}");
    const input = decoded.input;
    defer input.deinit(alloc);
    try std.testing.expect(!readsOnly(input));
}

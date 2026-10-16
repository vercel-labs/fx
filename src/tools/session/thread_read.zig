//! `thread_read`: the model's read-only view of the user's threads.

const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const thread_tool_provider = @import("../../core/threads/thread_tool_provider.zig");
const thread_tools = @import("../../core/threads/thread_tools.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    /// Null lists every thread.
    name: ?[]u8 = null,
    lines: usize = thread_tools.default_read_lines,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.name) |name| alloc.free(name);
        self.* = .{};
    }
};

fn failure(ctx: tool_dispatch.DispatchContext, comptime text: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, text) };
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx, "thread_read arguments must be valid JSON"),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failure(ctx, "thread_read arguments must be an object");
    const object = parsed.value.object;
    for (object.keys()) |key| {
        if (!std.mem.eql(u8, key, "name") and !std.mem.eql(u8, key, "lines")) {
            return failure(ctx, "thread_read accepts only \"name\" and \"lines\"");
        }
    }

    var lines: usize = thread_tools.default_read_lines;
    if (object.get("lines")) |value| switch (value) {
        .null => {},
        .integer => |n| {
            if (n < 1) return failure(ctx, "thread_read field \"lines\" must be a positive integer");
            lines = @min(@as(usize, @intCast(n)), thread_tools.max_read_lines);
        },
        else => return failure(ctx, "thread_read field \"lines\" must be a positive integer"),
    };

    var name: ?[]const u8 = null;
    if (object.get("name")) |value| switch (value) {
        .null => {},
        .string => |text| {
            if (text.len == 0) return failure(ctx, "thread_read field \"name\" must not be empty; omit it to list threads");
            name = text;
        },
        else => return failure(ctx, "thread_read field \"name\" must be a string"),
    };

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .name = if (name) |n| try ctx.allocator.dupe(u8, n) else null, .lines = lines };
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
        .{ .read = .{ .name = input.name, .lines = input.lines } },
        ctx.tool_call_id,
    );
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const Fixture = struct {
    seen_name: ?[]const u8 = null,
    seen_lines: usize = 0,
    reads: usize = 0,

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: thread_tool_provider.Request,
        _: []const u8,
    ) thread_tool_provider.ExecuteError!thread_tool_provider.Result {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        switch (request) {
            .read => |r| {
                self.reads += 1;
                self.seen_name = r.name;
                self.seen_lines = r.lines;
            },
            .send, .new => unreachable,
        }
        return .{ .status = .success, .body = try alloc.dupe(u8, "listed") };
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

test "decode defaults to listing with 40 lines and clamps to the feed size" {
    const alloc = std.testing.allocator;
    var cases = [_]struct { json: []const u8, name: ?[]const u8, lines: usize }{
        .{ .json = "{}", .name = null, .lines = 40 },
        .{ .json = "{\"name\":\"fix-auth\"}", .name = "fix-auth", .lines = 40 },
        .{ .json = "{\"name\":\"fix-auth\",\"lines\":5}", .name = "fix-auth", .lines = 5 },
        .{ .json = "{\"lines\":9999}", .name = null, .lines = 400 },
        .{ .json = "{\"name\":null,\"lines\":null}", .name = null, .lines = 40 },
    };
    for (&cases) |case| {
        switch (try decode(.{ .allocator = alloc }, case.json)) {
            .failure => |message| {
                alloc.free(message);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                const typed = input.as(Input);
                try std.testing.expectEqual(case.lines, typed.lines);
                if (case.name) |expected| {
                    try std.testing.expectEqualStrings(expected, typed.name.?);
                } else try std.testing.expect(typed.name == null);
            },
        }
    }
}

test "decode rejects malformed arguments" {
    for ([_][]const u8{
        "not json",
        "[]",
        "{\"name\":3}",
        "{\"name\":\"\"}",
        "{\"lines\":0}",
        "{\"lines\":-1}",
        "{\"lines\":\"5\"}",
        "{\"lines\":2.5}",
        "{\"extra\":true}",
    }) |bad| try expectDecodeFailure(bad);
}

test "call forwards a read request and returns the provider text" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{};
    const decoded = try decode(.{ .allocator = alloc }, "{\"name\":\"a\",\"lines\":7}");
    const input = decoded.input;
    defer input.deinit(alloc);
    const result = try call(.{
        .allocator = alloc,
        .tool_call_id = "call-1",
        .thread_provider = .{ .context = &fixture, .execute_fn = Fixture.execute },
    }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("listed", result.success);
    try std.testing.expectEqualStrings("a", fixture.seen_name.?);
    try std.testing.expectEqual(@as(usize, 7), fixture.seen_lines);
}

test "call without a provider reports threads unavailable" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{}");
    const input = decoded.input;
    defer input.deinit(alloc);
    const result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expect(result == .failure);
}

test "thread_read is read only" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{}");
    const input = decoded.input;
    defer input.deinit(alloc);
    try std.testing.expect(readsOnly(input));
    try std.testing.expect(!isIrreversible(input));
}

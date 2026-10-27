//! The `recall` tool: search over this node's own history, compacted turns
//! included (`src/core/recall/recall.zig`).
const std = @import("std");
const recall = @import("../../core/recall/recall.zig");
const result_store = @import("../../core/session/result_store.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    query: []u8 = &.{},
    page: usize = 1,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "recall arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "recall arguments must be an object") };
    const args = parsed.value.object;
    var iterator = args.iterator();
    while (iterator.next()) |field| {
        const name = field.key_ptr.*;
        if (!std.mem.eql(u8, name, "query") and !std.mem.eql(u8, name, "page"))
            return .{ .failure = try ctx.allocator.print("recall takes only \"query\" and \"page\"; remove \"{s}\"", .{name}) };
    }
    const query: []const u8 = if (args.get("query")) |value| switch (value) {
        .string => |text| text,
        .null => "",
        else => return .{ .failure = try ctx.allocator.dupe(u8, "recall field \"query\" must be a string") },
    } else "";
    const page: usize = if (args.get("page")) |value| switch (value) {
        .integer => |number| if (number >= 1) @intCast(number) else return .{ .failure = try ctx.allocator.dupe(u8, "recall field \"page\" must be a positive integer") },
        .null => 1,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "recall field \"page\" must be a positive integer") },
    } else 1;
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = try ctx.allocator.dupe(u8, query), .page = page };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const view = ctx.node_view orelse return .{
        .failure = try ctx.allocator.dupe(u8, "Session history is unavailable for recall: this run has no saved session."),
    };
    const stored: ?recall.StoredReader = if (ctx.session_child_capability) |capability|
        .{ .context = capability, .read_fn = readStored }
    else
        null;
    const output = recall.search(ctx.allocator, view, .{ .query = input.query, .page = input.page }, stored) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.print("Searching session history failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

fn readStored(context: *anyopaque, arena: Allocator, handle: []const u8, max_bytes: usize) ?[]const u8 {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    return result_store.readHeadManaged(arena, capability, handle, max_bytes) catch null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "recall decodes its query and page and rejects anything else" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"retry storms\",\"page\":2}");
    defer decoded.input.deinit(alloc);
    try std.testing.expectEqualStrings("retry storms", decoded.input.as(Input).query);
    try std.testing.expectEqual(@as(usize, 2), decoded.input.as(Input).page);

    const empty = try decode(.{ .allocator = alloc }, "{}");
    defer empty.input.deinit(alloc);
    try std.testing.expectEqualStrings("", empty.input.as(Input).query);

    const extra = try decode(.{ .allocator = alloc }, "{\"query\":\"x\",\"scope\":\"all\"}");
    defer alloc.free(extra.failure);
    try std.testing.expectEqualStrings("recall takes only \"query\" and \"page\"; remove \"scope\"", extra.failure);
    const zero = try decode(.{ .allocator = alloc }, "{\"page\":0}");
    defer alloc.free(zero.failure);
    try std.testing.expect(std.mem.endsWith(u8, zero.failure, "must be a positive integer"));
}

test "recall without a node host says why" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"x\"}");
    defer decoded.input.deinit(alloc);
    const result = try call(.{ .allocator = alloc }, decoded.input);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, result.failure, "Session history is unavailable"));
}

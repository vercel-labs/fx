//! The `checklist` tool (D230): one operation on the session's checklist
//! per call. The list itself lives in the session runtime
//! (`core/checklist/store.zig`).
const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const checklist_store = @import("../../core/checklist/store.zig");

const Allocator = std.mem.Allocator;

const Input = struct { args_json: []u8 };

/// Keeps the arguments whole: the store reads them under its lock, where
/// it knows whether the list holds tasks, to repair a missing `op`.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .args_json = try ctx.allocator.dupe(u8, args_json) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    alloc.free(input.args_json);
    alloc.destroy(input);
}

pub const unavailable = "The checklist is not available in this host.";

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const store = ctx.checklist orelse return .{ .failure = try ctx.allocator.dupe(u8, unavailable) };
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const outcome = try store.run(scratch.allocator(), input.args_json);
    const text = try ctx.allocator.dupe(u8, outcome.text);
    return if (outcome.failed) .{ .failure = text } else .{ .success = text };
}

/// A checklist call changes only the session's own plan.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "the checklist tool runs against the session store and fails without one" {
    const testing = std.testing;
    var store: checklist_store.Store = .{ .gpa = testing.allocator };
    defer store.deinit();
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = testing.allocator, .checklist = &store };
    const decoded = try decode(ctx, "{\"op\":\"init\",\"list\":[{\"phase\":\"Fix\",\"items\":[\"Find the bug\",\"Run tests\"]}]}");
    defer decoded.input.deinit(testing.allocator);
    const result = try call(ctx, decoded.input);
    defer testing.allocator.free(result.success);
    try testing.expect(std.mem.startsWith(u8, result.success, "Initialized 2 tasks in 1 phases"));

    const bare: tool_dispatch.DispatchContext = .{ .allocator = testing.allocator };
    const missing = try call(bare, decoded.input);
    defer testing.allocator.free(missing.failure);
    try testing.expectEqualStrings(unavailable, missing.failure);
}

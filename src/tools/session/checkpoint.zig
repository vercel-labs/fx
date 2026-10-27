//! The `checkpoint` and `rewind` tools (D120). Both read the running turn's
//! messages to learn whether a checkpoint is open; the agent loop drops the
//! exploration after a successful rewind's step (`checkpoint_rewind.zig`).
const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const checkpoint_rewind = @import("../../core/agent/runtime/checkpoint_rewind.zig");

const Allocator = std.mem.Allocator;

/// The goal of a `checkpoint`, or the report of a `rewind`.
const Input = struct { text: []u8 };

fn decodeField(ctx: tool_dispatch.DispatchContext, args_json: []const u8, comptime tool: []const u8, comptime field: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const text = try checkpoint_rewind.stringArg(scratch.allocator(), args_json, field) orelse return .{ .failure = try ctx.allocator.dupe(u8, tool ++ " requires string field \"" ++ field ++ "\"") };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .text = try ctx.allocator.dupe(u8, std.mem.trim(u8, text, " \t\r\n")) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    alloc.free(input.text);
    alloc.destroy(input);
}

pub fn decodeCheckpoint(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return decodeField(ctx, args_json, "checkpoint", "goal");
}

pub fn decodeRewind(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return decodeField(ctx, args_json, "rewind", "report");
}

/// Opens a checkpoint on the running turn, at most one at a time.
pub fn callCheckpoint(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (input.text.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, checkpoint_rewind.empty_goal) };
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    if (try checkpoint_rewind.scan(scratch.allocator(), ctx.current_turn_messages) == .open) {
        return .{ .failure = try ctx.allocator.dupe(u8, checkpoint_rewind.already_open) };
    }
    return .{ .success = try checkpoint_rewind.checkpointResult(ctx.allocator, input.text) };
}

/// Accepts the report that replaces the exploration since the open
/// checkpoint. The agent loop drops that exploration once this step ends.
pub fn callRewind(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const goal = switch (try checkpoint_rewind.scan(scratch.allocator(), ctx.current_turn_messages)) {
        .open => |open| open.goal,
        .rewound => return .{ .failure = try ctx.allocator.dupe(u8, checkpoint_rewind.already_rewound) },
        .none => return .{ .failure = try ctx.allocator.dupe(u8, checkpoint_rewind.no_checkpoint) },
    };
    if (input.text.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, checkpoint_rewind.empty_report) };
    // A rewind abandons the children its exploration spawned, so none may
    // still run (`tests/tla/session_manager/Checkpoint.tla` NoRewindWhileBusy).
    if (ctx.subtree_busy) |busy| if (busy.busy_fn(busy.ctx)) {
        return .{ .failure = try ctx.allocator.dupe(u8, checkpoint_rewind.subtree_busy) };
    };
    return .{ .success = try checkpoint_rewind.rewindResult(ctx.allocator, goal, input.text) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

// -- Tests -------------------------------------------------------------------

const testing = std.testing;
const types = @import("../../core/shared/types.zig");

fn run(messages: []const types.ChatMessage, busy: ?tool_dispatch.SubtreeBusy, rewind: bool, args: []const u8) !tool_dispatch.ToolResult {
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = testing.allocator, .current_turn_messages = messages, .subtree_busy = busy };
    const decoded = try (if (rewind) decodeRewind(ctx, args) else decodeCheckpoint(ctx, args));
    const input = decoded.input;
    defer input.deinit(testing.allocator);
    return if (rewind) callRewind(ctx, input) else callCheckpoint(ctx, input);
}

test "checkpoint opens once per turn and rewind needs it open" {
    const open = [_]types.ToolCall{.{ .id = "c1", .name = "checkpoint", .arguments_json = "{\"goal\":\"map the parser\"}" }};
    const with_checkpoint = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &open },
        .{ .role = .tool, .tool_call_id = "c1", .tool_name = "checkpoint", .content = "ok", .tool_result_status = .success },
    };
    const first = try run(&.{}, null, false, "{\"goal\":\" map the parser \"}");
    defer first.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, first.success, "Checkpoint: map the parser\n"));
    const second = try run(&with_checkpoint, null, false, "{\"goal\":\"again\"}");
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings(checkpoint_rewind.already_open, second.failure);

    const orphan = try run(&.{}, null, true, "{\"report\":\"x\"}");
    defer orphan.deinit(testing.allocator);
    try testing.expectEqualStrings(checkpoint_rewind.no_checkpoint, orphan.failure);
    const empty = try run(&with_checkpoint, null, true, "{\"report\":\"  \"}");
    defer empty.deinit(testing.allocator);
    try testing.expectEqualStrings(checkpoint_rewind.empty_report, empty.failure);
    const rewound = try run(&with_checkpoint, null, true, "{\"report\":\"the parser is LL(1)\"}");
    defer rewound.deinit(testing.allocator);
    try testing.expect(std.mem.find(u8, rewound.success, "checkpoint \"map the parser\"") != null);
    try testing.expect(std.mem.endsWith(u8, rewound.success, "Report:\nthe parser is LL(1)"));
}

test "rewind is refused while a worker or child node runs" {
    const Busy = struct {
        fn yes(_: *anyopaque) bool {
            return true;
        }
    };
    var anchor: u8 = 0;
    const open = [_]types.ToolCall{.{ .id = "c1", .name = "checkpoint", .arguments_json = "{\"goal\":\"g\"}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &open },
        .{ .role = .tool, .tool_call_id = "c1", .tool_name = "checkpoint", .content = "ok", .tool_result_status = .success },
    };
    const refused = try run(&messages, .{ .ctx = &anchor, .busy_fn = Busy.yes }, true, "{\"report\":\"r\"}");
    defer refused.deinit(testing.allocator);
    try testing.expectEqualStrings(checkpoint_rewind.subtree_busy, refused.failure);
}

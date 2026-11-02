//! RTK affects provider requests only. Saved execution memory, permission
//! evidence, presentation, and replay handles remain owned by their callers.
const std = @import("std");
const types = @import("../../shared/types.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const rtk = @import("../../tooling/rtk.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");

const Allocator = std.mem.Allocator;

/// Borrows unchanged messages and owns changed slices in the request arena.
/// The caller releases that arena as a whole. This function performs no I/O.
pub fn projectMessages(arena: Allocator, registry: tool_dispatch.Registry, advertised_names: []const []const u8, source: []const types.ChatMessage) Allocator.Error![]const types.ChatMessage {
    var reader_advertised = false;
    for (advertised_names) |name| if (std.mem.eql(u8, name, "read_tool_result")) {
        reader_advertised = true;
        break;
    };
    if (!reader_advertised) return source;
    const shell = registry.lookup("shell") orelse return source;
    const reader = registry.lookup("read_tool_result") orelse return source;
    if (shell.executor_kind != .terminal or reader.executor_kind != .read_tool_result) return source;
    var projected: ?[]types.ChatMessage = null;
    var calls: []const types.ToolCall = &.{};
    for (source, 0..) |message, index| {
        if (message.role != .tool) {
            calls = if (message.role == .assistant) message.tool_calls else &.{};
            continue;
        }
        if (message.tool_result_status != .success or message.provider_replay != null or
            !std.mem.eql(u8, message.tool_name orelse "", "shell")) continue;
        const id = message.tool_call_id orelse continue;
        var matched: ?types.ToolCall = null;
        var matches: usize = 0;
        for (calls) |call| if (std.mem.eql(u8, call.id, id)) {
            matched = call;
            matches += 1;
        };
        if (matches != 1) continue;
        const call = matched.?;
        if (call.argument_integrity != .valid or call.provider_result != null or
            call.provenance != .fx_local or !std.mem.eql(u8, call.name, "shell")) continue;
        const view = try projectResult(arena, call, message) orelse continue;
        if (projected == null) projected = try arena.dupe(types.ChatMessage, source);
        projected.?[index].content = view;
    }
    return projected orelse source;
}

fn projectResult(arena: Allocator, call: types.ToolCall, message: types.ChatMessage) Allocator.Error!?[]const u8 {
    const memory = message.tool_result_memory orelse return null;
    if (memory.truncated or memory.review_feedback or memory.tool_images.len != 0) return null;
    const replay = memory.command_output_replay orelse return null;
    const handle = switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => return null,
    };
    if (handle.len == 0 or handle.len > command_replay_store.max_public_handle_bytes) return null;
    for (handle) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return null;
    }
    const content = message.content orelse return null;
    if (content.len > 256 * 1024 or call.arguments_json.len > 16 * 1024) return null;
    var args = std.json.parseFromSlice(std.json.Value, arena, call.arguments_json, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer args.deinit();
    var input = args.value;
    if (input != .object) return null;
    if (input.object.count() == 1) if (input.object.get("request")) |request| {
        input = request;
    };
    if (input != .object or !stringEquals(input.object, "action", "run")) return null;
    if (!absentOrFalse(input.object, "tty")) return null;
    const command = input.object.get("command") orelse return null;
    if (command != .string) return null;

    var result = std.json.parseFromSlice(std.json.Value, arena, content, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer result.deinit();
    if (result.value != .object) return null;
    const object = &result.value.object;
    if (!stringEquals(object.*, "state", "completed")) return null;
    const exit_code = object.get("exit_code") orelse return null;
    if (exit_code != .integer or exit_code.integer != 0) return null;
    if (!stringEquals(object.*, "full_output_handle", handle)) return null;
    for ([_][]const u8{ "output_truncated", "output_incomplete", "output_terminal_safe", "termination_indeterminate" }) |flag| {
        if (!absentOrFalse(object.*, flag)) return null;
    }
    for ([_][]const u8{ "signal", "error" }) |key| {
        if (object.get(key)) |value| if (value != .null) return null;
    }
    if (object.get("backend")) |_| {
        if (!stringEquals(object.*, "backend", "captured")) return null;
    }
    const delta = object.get("output_delta") orelse return null;
    if (delta != .string) return null;
    const reduced = try rtk.reduce(arena, command.string, delta.string) orelse return null;
    defer arena.free(reduced);
    // Update this copy of the wire view only; all metadata and the exact
    // recovery handle survive without changing the canonical tool result.
    try object.put(result.arena.allocator(), "output_delta", .{ .string = reduced });
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    std.json.Stringify.value(result.value, .{}, &out.writer) catch return error.OutOfMemory;
    if (out.written().len >= content.len) return null;
    return try out.toOwnedSlice();
}

fn stringEquals(object: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn absentOrFalse(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    return value == .null or (value == .bool and !value.bool);
}

const test_shell = tool_dispatch.Tool{
    .name = "shell",
    .description = "shell",
    .model_schema = .{ .name = "shell", .description = "shell" },
    .executor_kind = .terminal,
    .decode = undefined,
    .call = undefined,
    .reads_only_fn = undefined,
    .irreversible_fn = undefined,
};
const test_reader = blk: {
    var reader = test_shell;
    reader.name = "read_tool_result";
    reader.executor_kind = .read_tool_result;
    break :blk reader;
};
const test_registry = tool_dispatch.Registry{ .tools = &.{ test_shell, test_reader } };

fn fixture(arena: Allocator) ![2]types.ChatMessage {
    var raw: std.Io.Writer.Allocating = .init(arena);
    for (0..30) |index| try raw.writer.print("test suite::important_test_{d} ... ok\n", .{index});
    try raw.writer.writeAll("warning: keep this diagnostic\ntest result: ok. 30 passed\n");
    var encoded: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .state = "completed",
        .exit_code = @as(i32, 0),
        .duration_ms = @as(u64, 12),
        .full_output_handle = "command-rtk.bin",
        .output_delta = raw.written(),
    }, .{}, &encoded.writer);
    return .{
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "run-1",
            .name = "shell",
            .arguments_json = "{\"action\":\"run\",\"command\":\"cargo test\"}",
        }} },
        .{
            .role = .tool,
            .tool_call_id = "run-1",
            .tool_name = "shell",
            .content = encoded.written(),
            .tool_result_status = .success,
            .tool_result_memory = .{ .command_output_replay = .{ .available = .{ .handle = "command-rtk.bin", .framed_bytes = raw.written().len } } },
        },
    };
}

test "rtk projection changes only the request view and preserves replay metadata" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    const source = try fixture(arena);
    const original = try arena.dupe(u8, source[1].content.?);
    const view = try projectMessages(arena, test_registry, &.{"read_tool_result"}, &source);
    try std.testing.expect(view.ptr != source[0..].ptr);
    try std.testing.expectEqualStrings(original, source[1].content.?);
    try std.testing.expect(view[1].content.?.len < source[1].content.?.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, view[1].content.?, .{});
    try std.testing.expectEqualStrings("command-rtk.bin", parsed.value.object.get("full_output_handle").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("exit_code").?.integer);
    try std.testing.expectEqual(@as(i64, 12), parsed.value.object.get("duration_ms").?.integer);
    try std.testing.expect(std.mem.find(u8, parsed.value.object.get("output_delta").?.string, "30 passing test lines omitted") != null);
    try std.testing.expect(std.mem.find(u8, view[1].content.?, "keep this diagnostic") != null);
    try std.testing.expectEqualStrings("command-rtk.bin", view[1].tool_result_memory.?.command_output_replay.?.available.handle);
    const again = try projectMessages(arena, test_registry, &.{"read_tool_result"}, view);
    try std.testing.expectEqual(view.ptr, again.ptr);
}

test "rtk projection leaves failures incomplete output unsafe encodings and foreign handles intact" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    const good = try fixture(arena);
    const cases = [_]struct { key: []const u8, value: std.json.Value }{
        .{ .key = "state", .value = .{ .string = "running" } },
        .{ .key = "exit_code", .value = .{ .integer = 1 } },
        .{ .key = "signal", .value = .{ .integer = 9 } },
        .{ .key = "error", .value = .{ .string = "TimeoutExpired" } },
        .{ .key = "output_truncated", .value = .{ .bool = true } },
        .{ .key = "output_incomplete", .value = .{ .bool = true } },
        .{ .key = "output_terminal_safe", .value = .{ .bool = true } },
        .{ .key = "backend", .value = .{ .string = "tty" } },
        .{ .key = "full_output_handle", .value = .{ .string = "another-command.bin" } },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, good[1].content.?, .{});
        var root = parsed.value;
        try root.object.put(arena, case.key, case.value);
        var text: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(root, .{}, &text.writer);
        var source = good;
        source[1].content = text.written();
        const view = try projectMessages(arena, test_registry, &.{"read_tool_result"}, &source);
        try std.testing.expectEqual(source[0..].ptr, view.ptr);
    }
    var failed = good;
    failed[1].tool_result_status = .failure;
    try std.testing.expectEqual(failed[0..].ptr, (try projectMessages(arena, test_registry, &.{"read_tool_result"}, &failed)).ptr);
    var missing = good;
    missing[1].tool_result_memory = null;
    try std.testing.expectEqual(missing[0..].ptr, (try projectMessages(arena, test_registry, &.{"read_tool_result"}, &missing)).ptr);
    var truncated = good;
    truncated[1].tool_result_memory.?.truncated = true;
    try std.testing.expectEqual(truncated[0..].ptr, (try projectMessages(arena, test_registry, &.{"read_tool_result"}, &truncated)).ptr);
}

test "rtk projection never rewrites raw result reads custom host tools or unmatched calls" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var source = try fixture(arena);
    source[1].tool_name = "read_tool_result";
    try std.testing.expectEqual(source[0..].ptr, (try projectMessages(arena, test_registry, &.{"read_tool_result"}, &source)).ptr);
    source[1].tool_name = "shell";
    source[1].tool_call_id = "foreign";
    try std.testing.expectEqual(source[0..].ptr, (try projectMessages(arena, test_registry, &.{"read_tool_result"}, &source)).ptr);
    source[1].tool_call_id = "run-1";
    try std.testing.expectEqual(source[0..].ptr, (try projectMessages(arena, test_registry, &.{}, &source)).ptr);
    var host_shell = test_shell;
    host_shell.executor_kind = .host;
    try std.testing.expectEqual(source[0..].ptr, (try projectMessages(arena, .{ .tools = &.{ host_shell, test_reader } }, &.{"read_tool_result"}, &source)).ptr);
    try std.testing.expectEqual(source[0..].ptr, (try projectMessages(arena, .{ .tools = &.{test_shell} }, &.{"read_tool_result"}, &source)).ptr);
}

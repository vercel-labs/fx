//! Responses completion evidence protects native tool execution from truncated or failed streams.
const std = @import("std");
const wire = @import("wire.zig");
const events = @import("sse_events.zig");
const stream_result = @import("stream_result.zig");
const replay = @import("replay.zig");
const max_calls = 128;
const max_output_items = 1024;
const max_identity_bytes = 1024;
const completed_status = "completed";
const function_type = "function_call";
const reasoning_type = "reasoning";
const finish_stop = "stop";
const finish_tools = "tool_calls";
const terminal_delete_byte = 0x7f;
const event_errors = [_][]const u8{ "error", "response.failed", "response.incomplete" };
const event_text_delta = "response.output_text.delta";
const event_reasoning_summary_delta = "response.reasoning_summary_text.delta";
const event_reasoning_delta = "response.reasoning_text.delta";
const event_item_added = "response.output_item.added";
const event_item_done = "response.output_item.done";
const event_arguments_delta = "response.function_call_arguments.delta";
const event_arguments_done = "response.function_call_arguments.done";
const event_completed = "response.completed";

// Provider output indexes include non-call items, so native call indexes must be dense.
const Call = struct { output_index: usize, item_id: []const u8, finalized: bool = false };

/// Result owns canonical accumulators; temporary framing, identities and JSON never escape this call.
pub fn consume(result: *stream_result.Context, reader: *std.Io.Reader) !void {
    var arena = std.heap.ArenaAllocator.init(result.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    var calls: std.ArrayList(Call) = .empty;
    var framing = events.Reader.init(result.alloc, reader, result.cancel);
    defer framing.deinit();
    while (try framing.next()) |data| {
        defer result.alloc.free(data);
        var parsed = try std.json.parseFromSlice(wire.Value, result.alloc, data, .{});
        defer parsed.deinit();
        const event = parsed.value;
        const kind = try wire.text(try wire.field(event, "type"));
        for (event_errors) |failed| if (std.mem.eql(u8, kind, failed)) return error.ProviderFailed;
        if (std.mem.eql(u8, kind, event_text_delta)) {
            try result.append_content(try wire.text(try wire.field(event, "delta")));
        } else if (std.mem.eql(u8, kind, event_reasoning_summary_delta) or std.mem.eql(u8, kind, event_reasoning_delta)) {
            try result.append_reasoning(try wire.text(try wire.field(event, "delta")));
        } else if (std.mem.eql(u8, kind, event_item_added) or std.mem.eql(u8, kind, event_item_done)) {
            const item = try wire.field(event, "item");
            if (std.mem.eql(u8, try wire.text(try wire.field(item, "type")), function_type)) {
                const index = try output_index(try wire.field(event, "output_index"));
                const dense = try admit_call(alloc, result, &calls, index, item);
                if (std.mem.eql(u8, kind, event_item_done)) {
                    try terminal_item(item);
                    try finalize_arguments(result, &calls.items[dense], dense, try wire.text(try wire.field(item, "arguments")));
                }
            }
        } else if (std.mem.eql(u8, kind, event_arguments_delta) or std.mem.eql(u8, kind, event_arguments_done)) {
            const index = try output_index(try wire.field(event, "output_index"));
            const dense = lookup(calls.items, index) orelse return error.InvalidResponse;
            if (!std.mem.eql(u8, try wire.text(try wire.field(event, "item_id")), calls.items[dense].item_id)) return error.InvalidResponse;
            if (std.mem.eql(u8, kind, event_arguments_delta)) {
                if (calls.items[dense].finalized) return error.InvalidResponse;
                try result.append_arguments(dense, try wire.text(try wire.field(event, "delta")));
            } else try finalize_arguments(result, &calls.items[dense], dense, try wire.text(try wire.field(event, "arguments")));
        } else if (std.mem.eql(u8, kind, event_completed)) {
            const response = try wire.field(event, "response");
            if (!std.mem.eql(u8, try wire.text(try wire.field(response, "status")), completed_status)) return error.ProviderFailed;
            for ([_][]const u8{ "error", "incomplete_details" }) |field| if (response.object.get(field)) |value| if (value != .null) return error.ProviderFailed;
            const output = try wire.field(response, "output");
            if (output != .array or output.array.items.len > max_output_items) return error.InvalidResponse;
            var reasoning: std.json.Array = .init(alloc);
            var terminal_calls: usize = 0;
            for (output.array.items, 0..) |item, index| {
                try terminal_item(item);
                const item_type = try wire.text(try wire.field(item, "type"));
                if (std.mem.eql(u8, item_type, function_type)) {
                    const dense = try admit_call(alloc, result, &calls, index, item);
                    try finalize_arguments(result, &calls.items[dense], dense, try wire.text(try wire.field(item, "arguments")));
                    terminal_calls += 1;
                } else if (std.mem.eql(u8, item_type, reasoning_type)) {
                    // Ciphertext is replayed only after the provider confirms the whole response.
                    try replay.responses_item(item);
                    if (reasoning.items.len >= max_calls) return error.ResponseTooLarge;
                    try reasoning.append(item);
                }
            }
            if (terminal_calls != calls.items.len) return error.InvalidResponse;
            if (reasoning.items.len > 0) try result.set_replay(try replay.envelope(alloc, .responses, .{ .array = reasoning }));
            if (response.object.get("usage")) |usage| if (usage != .null) {
                result.input_tokens = try token_count(try wire.field(usage, "input_tokens"));
                result.output_tokens = try token_count(try wire.field(usage, "output_tokens"));
            };
            result.finish = if (calls.items.len > 0) finish_tools else finish_stop;
            return;
        }
    }
    return error.IncompleteResponse;
}

/// A completed response cannot authorize an unfinished item hidden inside its output snapshot.
fn terminal_item(item: wire.Value) !void {
    if (item != .object) return error.InvalidResponse;
    if (item.object.get("status")) |status| if (!std.mem.eql(u8, try wire.text(status), completed_status)) return error.InvalidResponse;
}

/// An output slot cannot change identities or alias another call when terminal snapshots arrive.
fn admit_call(alloc: wire.Allocator, result: *stream_result.Context, calls: *std.ArrayList(Call), index: usize, item: wire.Value) !usize {
    const item_id = try wire.text(try wire.field(item, "id"));
    try validate_identity(item_id);
    const call_id = try wire.text(try wire.field(item, "call_id"));
    const name = try wire.text(try wire.field(item, "name"));
    const dense = lookup(calls.items, index) orelse new: {
        if (calls.items.len >= max_calls) return error.InvalidResponse;
        for (calls.items, 0..) |call, other| {
            if (std.mem.eql(u8, call.item_id, item_id) or std.mem.eql(u8, result.calls.items[other].id, call_id)) return error.InvalidResponse;
        }
        const next = calls.items.len;
        try calls.append(alloc, .{ .output_index = index, .item_id = try alloc.dupe(u8, item_id) });
        break :new next;
    };
    if (!std.mem.eql(u8, calls.items[dense].item_id, item_id)) return error.InvalidResponse;
    try result.set_call(dense, call_id, name);
    return dense;
}

/// Final snapshots can fill an undeltaed call, but cannot replace streamed arguments.
fn finalize_arguments(result: *stream_result.Context, call: *Call, dense: usize, arguments: []const u8) !void {
    const current = result.calls.items[dense].arguments.items;
    if (current.len == 0 and !call.finalized) try result.append_arguments(dense, arguments) else if (!std.mem.eql(u8, current, arguments)) return error.InvalidResponse;
    call.finalized = true;
}

/// Bounded indexes prevent hostile sparse identities from allocating sparse result storage.
fn output_index(value: wire.Value) !usize {
    if (value != .integer or value.integer < 0 or value.integer >= max_output_items) return error.InvalidResponse;
    return @intCast(value.integer);
}

/// Exact output-slot matching keeps reasoning and message gaps outside native call indexes.
fn lookup(calls: []const Call, index: usize) ?usize {
    for (calls, 0..) |call, dense| if (call.output_index == index) return dense;
    return null;
}

/// Item identities have the same terminal-safe budget as canonical tool identities.
fn validate_identity(value: []const u8) !void {
    if (value.len == 0 or value.len > max_identity_bytes) return error.InvalidResponse;
    for (value) |byte| if (std.ascii.isControl(byte) or byte == terminal_delete_byte) return error.InvalidResponse;
}

/// Negative or fractional usage cannot corrupt native persisted token totals.
fn token_count(value: wire.Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}

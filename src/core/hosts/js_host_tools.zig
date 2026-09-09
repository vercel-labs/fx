const std = @import("std");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_content = @import("../tooling/tool_content.zig");
const types = @import("../shared/types.zig");
const image_data = @import("../images/image_data.zig");

const Allocator = std.mem.Allocator;
const bridge_max_result_bytes: usize = 64 * 1024;

extern "fx" fn fx_host_tool_call(
    name_ptr: [*]const u8,
    name_len: usize,
    arguments_ptr: [*]const u8,
    arguments_len: usize,
    output_ptr: [*]u8,
    output_cap: usize,
    status_ptr: *u8,
    context_ptr: [*]const u8,
    context_len: usize,
) i32;

extern "fx" fn fx_host_tool_result_read(offset: usize, ptr: [*]u8, cap: usize) i32;
extern "fx" fn fx_host_tool_result_release() void;

pub fn provider(cancel_uncertain: *std.atomic.Value(bool)) tool_dispatch.HostToolProvider {
    return .{
        .context = @ptrCast(cancel_uncertain),
        .call_fn = call,
    };
}

fn call(
    raw_context: *anyopaque,
    alloc: Allocator,
    name: []const u8,
    arguments_json: []const u8,
    max_result_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool),
    journal_context: ?types.JournalToolContext,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = try alloc.dupe(u8, "Host tool cancelled before executor entry; not executed") };
    const cap = @min(max_result_bytes, bridge_max_result_bytes);
    if (cap == 0) return .{ .failure = try alloc.dupe(u8, "Host tool result limit is zero") };
    const output = try alloc.alloc(u8, cap);
    defer alloc.free(output);
    // An omitted/invalid host status must not default to successful completion.
    var status: u8 = 255;
    const context_json = try std.json.Stringify.valueAlloc(alloc, journal_context, .{});
    defer alloc.free(context_json);
    const raw = fx_host_tool_call(
        name.ptr,
        name.len,
        arguments_json.ptr,
        arguments_json.len,
        output.ptr,
        output.len,
        &status,
        context_json.ptr,
        context_json.len,
    );
    if (raw == -5) {
        // Sticky host-owned evidence survives core's cancellation/history path,
        // regardless of whether a durable recovery sink is installed.
        const cancel_uncertain: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw_context));
        cancel_uncertain.store(true, .seq_cst);
        if (cancel_flag) |flag| flag.store(true, .seq_cst);
        return error.HostToolOutcomeUncertain;
    }
    if (raw == -2) {
        if (cancel_flag) |flag| flag.store(true, .seq_cst);
        return .{ .failure = try alloc.dupe(u8, "Host tool cancelled before executor entry; not executed") };
    }
    // -4 denotes executor uncertainty. All other transport/result errors are
    // conservative too: a failed bridge is not proof that no effect occurred.
    if (raw < 0) return error.HostToolOutcomeUncertain;
    defer fx_host_tool_result_release();
    const len: usize = @intCast(raw);
    if (status == 2 or status == 3) {
        if (len > image_data.max_result_frame_bytes) return error.HostToolOutcomeUncertain;
        const encoded = if (len <= output.len) output[0..len] else read: {
            const collected = try alloc.alloc(u8, len);
            errdefer alloc.free(collected);
            var offset: usize = 0;
            while (offset < len) {
                if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
                const count = fx_host_tool_result_read(offset, collected[offset..].ptr, @min(64 * 1024, len - offset));
                if (count <= 0 or @as(usize, @intCast(count)) > len - offset) {
                    return error.HostToolOutcomeUncertain;
                }
                offset += @intCast(count);
            }
            break :read collected;
        };
        defer if (len > output.len) alloc.free(encoded);
        var result = tool_content.parseRichResult(alloc, encoded, max_result_bytes, status == 3) catch return error.HostToolOutcomeUncertain;
        if (result != .rich) {
            result.deinit(alloc);
            return error.HostToolOutcomeUncertain;
        }
        return result;
    }
    if (len > output.len or status > 1) return error.HostToolOutcomeUncertain;
    const owned = try alloc.dupe(u8, output[0..len]);
    return if (status == 1) .{ .failure = owned } else .{ .success = owned };
}

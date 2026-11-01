const std = @import("std");
const prompt_history_provider = @import("prompt_history_provider.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const initial_capacity: usize = 4 * 1024;
const max_response_bytes: usize = 1024 * 1024;

extern "fx" fn fx_prompt_history_available() i32;

extern "fx" fn fx_prompt_history_load(
    workspace_ptr: [*]const u8,
    workspace_len: usize,
    limit: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) i32;

extern "fx" fn fx_prompt_history_append(
    timestamp_ms: i64,
    workspace_ptr: [*]const u8,
    workspace_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
) i32;

extern "fx" fn fx_prompt_history_clear(
    workspace_ptr: [*]const u8,
    workspace_len: usize,
) i32;

pub fn available() bool {
    return fx_prompt_history_available() == 1;
}

pub const provider = prompt_history_provider.Provider{
    .load_recent_fn = loadRecent,
    .append_fn = append,
    .clear_workspace_fn = clearWorkspace,
    .display_name = "embedding SDK",
};

fn loadRecent(
    _: ?*anyopaque,
    alloc: Allocator,
    workspace_root: []const u8,
    limit: usize,
) ![]prompt_history_provider.LoadedEntry {
    var capacity = initial_capacity;
    while (capacity <= max_response_bytes) : (capacity *= 2) {
        const buffer = try alloc.alloc(u8, capacity);
        const result = fx_prompt_history_load(
            workspace_root.ptr,
            workspace_root.len,
            limit,
            buffer.ptr,
            buffer.len,
        );
        if (result == -2) {
            alloc.free(buffer);
            continue;
        }
        if (result < 0) {
            alloc.free(buffer);
            return error.PromptHistoryHostFailure;
        }
        const length: usize = @intCast(result);
        if (length > buffer.len) {
            alloc.free(buffer);
            return error.PromptHistoryHostFailure;
        }
        defer alloc.free(buffer);
        const parsed = try json_decode.parseFromSlice([]const []const u8, alloc, buffer[0..length], .{});
        defer parsed.deinit();
        const entries = try alloc.alloc(prompt_history_provider.LoadedEntry, parsed.value.len);
        errdefer alloc.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| alloc.free(entry.text);
        for (parsed.value, 0..) |text, index| {
            entries[index] = .{ .text = try alloc.dupe(u8, text) };
            initialized += 1;
        }
        return entries;
    }
    return error.PromptHistoryResponseTooLarge;
}

fn append(
    _: ?*anyopaque,
    _: Allocator,
    timestamp_ms: i64,
    workspace_root: []const u8,
    text: []const u8,
) !prompt_history_provider.AppendOutcome {
    return switch (fx_prompt_history_append(
        timestamp_ms,
        workspace_root.ptr,
        workspace_root.len,
        text.ptr,
        text.len,
    )) {
        0 => .appended,
        1 => .duplicate,
        2 => .record_too_large,
        else => error.PromptHistoryHostFailure,
    };
}

fn clearWorkspace(
    _: ?*anyopaque,
    _: Allocator,
    workspace_root: []const u8,
) !void {
    if (fx_prompt_history_clear(workspace_root.ptr, workspace_root.len) != 0) {
        return error.PromptHistoryHostFailure;
    }
}

const std = @import("std");

pub const max_command_bytes: usize = 64 * 1024;

extern "fx" fn fx_attached_api_next(out_ptr: [*]u8, out_cap: usize) i32;
extern "fx" fn fx_attached_api_discard() void;
extern "fx" fn fx_attached_api_emit(event_ptr: [*]const u8, event_len: usize) i32;

pub fn next(alloc: std.mem.Allocator) !?[]u8 {
    var sentinel: [1]u8 = undefined;
    const required = fx_attached_api_next(&sentinel, 0);
    if (required == 0) return null;
    if (required < 0) return error.AttachedApiHostFailure;

    const len: usize = @intCast(required);
    if (len > max_command_bytes) {
        fx_attached_api_discard();
        return error.AttachedApiCommandTooLarge;
    }

    const command = try alloc.alloc(u8, len);
    errdefer alloc.free(command);
    const copied = fx_attached_api_next(command.ptr, command.len);
    if (copied != required) return error.AttachedApiHostFailure;
    return command;
}

pub fn emit(event: []const u8) !void {
    if (fx_attached_api_emit(event.ptr, event.len) != 0) {
        return error.AttachedApiHostFailure;
    }
}

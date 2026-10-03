const std = @import("std");

const Allocator = std.mem.Allocator;
const max_message_bytes: usize = 64 * 1024;
const max_messages: usize = 64;
const max_id_bytes: usize = 128;

extern "fx" fn fx_steering_take(output_ptr: [*]u8, output_cap: usize) i32;
extern "fx" fn fx_steering_close() void;

pub fn close() void {
    fx_steering_close();
}

/// One steer the host handed over, with the input id a journaled session
/// records it under.
pub const Taken = struct {
    id: ?[]u8,
    text: []u8,
};

/// Drains host-owned libfx steering into allocator-owned entries. The host
/// writes each as its id, a newline, then the text; an empty id means none.
pub fn takeAll(alloc: Allocator) ![]Taken {
    const scratch = try alloc.alloc(u8, max_id_bytes + 1 + max_message_bytes);
    defer alloc.free(scratch);
    var taken: std.ArrayList(Taken) = .empty;
    errdefer {
        for (taken.items) |entry| {
            if (entry.id) |id| alloc.free(id);
            alloc.free(entry.text);
        }
        taken.deinit(alloc);
    }

    for (0..max_messages) |_| {
        const raw = fx_steering_take(scratch.ptr, scratch.len);
        if (raw == 0) break;
        if (raw < 0) return error.HostSteeringFailed;
        const len: usize = @intCast(raw);
        if (len > scratch.len) return error.HostSteeringFailed;
        const framed = scratch[0..len];
        const split = std.mem.findScalar(u8, framed, '\n') orelse return error.HostSteeringFailed;
        if (split > max_id_bytes or framed.len - split - 1 > max_message_bytes) return error.HostSteeringFailed;
        try taken.ensureUnusedCapacity(alloc, 1);
        const id = if (split == 0) null else try alloc.dupe(u8, framed[0..split]);
        errdefer if (id) |value| alloc.free(value);
        taken.appendAssumeCapacity(.{ .id = id, .text = try alloc.dupe(u8, framed[split + 1 ..]) });
    }
    if (taken.items.len == 0) {
        taken.deinit(alloc);
        return &.{};
    }
    return taken.toOwnedSlice(alloc);
}

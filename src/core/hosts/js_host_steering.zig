const std = @import("std");

const Allocator = std.mem.Allocator;
const max_message_bytes: usize = 64 * 1024;
const max_messages: usize = 64;
const max_id_bytes: usize = 128;

extern "fx" fn fx_steering_take(output_ptr: [*]u8, output_cap: usize) i32;
extern "fx" fn fx_steering_close() void;
extern "fx" fn fx_steering_state() i32;
/// Resolves to 0 once the host has handed in the inputs it stored since it
/// last read them, each steer among them queued, or to a negative value when
/// that read failed.
extern "fx" fn fx_take_inputs() i32;

pub fn close() void {
    fx_steering_close();
}

/// Waits while a host that stores the session's inputs hands in the ones it
/// has not read yet; the steers among them are then queued for `takeAll`.
pub fn takeInputs() error{HostInputsFailed}!void {
    if (fx_take_inputs() != 0) return error.HostInputsFailed;
}

/// The host's steering for the running turn: closed once the turn takes no
/// more, as when the user cancels it, or how many steers wait for a boundary
/// and whether one that cannot join the turn waits to run next.
pub const State = union(enum) {
    closed,
    open: struct { queued: usize, handoff: bool },
};

/// The host reports -1 when closed, -2 when closed because the user
/// cancelled the turn, else twice the queued count, plus one for a pending
/// handoff.
pub fn state() State {
    const raw = fx_steering_state();
    if (raw < 0) return .closed;
    const value: usize = @intCast(raw);
    return .{ .open = .{ .queued = value >> 1, .handoff = value & 1 == 1 } };
}

/// Whether the host closed the running turn's steering because the user
/// cancelled the turn. The web core reads the cancel itself only once it
/// reads its input again, which can be after the turn ended.
pub fn cancelled() bool {
    return fx_steering_state() == -2;
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

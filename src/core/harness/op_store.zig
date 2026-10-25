//! `store.*`: values the agent chose to keep, as lines of its node's
//! session log over blobs of that session (D99), so they follow its forks
//! and rewinds and survive detaching and supervisor restarts. Python
//! pickles each value (dill, else pickle) and the host stores the bytes; a
//! value travels as base64.
const std = @import("std");
const protocol = @import("protocol.zig");

/// The node's store, which the session layer installs when it opens a
/// session (`src/core/session/python_state.zig`), so the harness never
/// depends on the session manager.
pub const Backend = struct {
    set: *const fn (alloc: std.mem.Allocator, node_id: []const u8, key: []const u8, value: []const u8) anyerror!void,
    get: *const fn (alloc: std.mem.Allocator, node_id: []const u8, key: []const u8) anyerror!?[]u8,
    del: *const fn (alloc: std.mem.Allocator, node_id: []const u8, key: []const u8) anyerror!bool,
    keys: *const fn (alloc: std.mem.Allocator, node_id: []const u8) anyerror![][]u8,
};
pub var backend: ?Backend = null;
pub const max_value_bytes: usize = 1 << 20;
pub const max_keys: usize = 1024;
pub const max_store_bytes: u64 = 64 << 20;

const Encoder = std.base64.standard.Encoder;
const Decoder = std.base64.standard.Decoder;

pub const set = struct {
    pub const name = "store.set";
    pub const Args = struct { key: []const u8, value: []const u8 };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const id = nodeId(call) orelse return noStore(call);
        const size = Decoder.calcSizeForSlice(args.value) catch return call.fail(.bad_request, "store.set needs a base64 value", .{});
        if (size > max_value_bytes) return tooLarge(call, args.key, size);
        const bytes = try call.arena.alloc(u8, size);
        Decoder.decode(bytes, args.value) catch return call.fail(.bad_request, "store.set needs a base64 value", .{});
        (backend orelse return noStore(call)).set(call.arena, id, args.key, bytes) catch |err| return failure(call, args.key, size, err);
        return call.ok(.{ .key = args.key, .bytes = size });
    }
};

pub const get = struct {
    pub const name = "store.get";
    pub const Args = struct { key: []const u8 };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const id = nodeId(call) orelse return noStore(call);
        const bytes = (backend orelse return noStore(call)).get(call.arena, id, args.key) catch |err| return failure(call, args.key, 0, err);
        const value = bytes orelse return call.ok(.{ .found = false });
        const text = try call.arena.alloc(u8, Encoder.calcSize(value.len));
        return call.ok(.{ .found = true, .value = Encoder.encode(text, value) });
    }
};

pub const del = struct {
    pub const name = "store.del";
    pub const Args = struct { key: []const u8 };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const id = nodeId(call) orelse return noStore(call);
        const removed = (backend orelse return noStore(call)).del(call.arena, id, args.key) catch |err| return failure(call, args.key, 0, err);
        return call.ok(.{ .removed = removed });
    }
};

pub const keys = struct {
    pub const name = "store.keys";
    pub const Args = struct {};

    pub fn handle(call: *protocol.Call, _: Args) !protocol.Reply {
        const id = nodeId(call) orelse return noStore(call);
        const list = (backend orelse return noStore(call)).keys(call.arena, id) catch |err| return failure(call, "", 0, err);
        return call.ok(list);
    }
};

/// The node's saved session id: the store needs a log to live in.
fn nodeId(call: *protocol.Call) ?[]const u8 {
    return call.lease.kernel_session_id;
}

fn noStore(call: *protocol.Call) !protocol.Reply {
    return call.fail(.unavailable, "harness.store needs a saved session; this agent's session is not saved", .{});
}

fn tooLarge(call: *protocol.Call, key: []const u8, size: usize) !protocol.Reply {
    return call.fail(.refused, "the value for {s} is {d} bytes pickled; harness.store keeps values up to {d} bytes. Keep a smaller value, or write it to a file and store the path", .{ key, size, max_value_bytes });
}

fn failure(call: *protocol.Call, key: []const u8, size: usize, err: anyerror) !protocol.Reply {
    return switch (err) {
        error.OutOfMemory => err,
        error.NoSession => call.fail(.unavailable, "this agent's session is not open in this host, so harness.store cannot reach it", .{}),
        error.InvalidKey => call.fail(.bad_request, "a store key is 1 to {d} bytes of UTF-8 text", .{256}),
        error.ValueTooLarge => tooLarge(call, key, size),
        error.TooManyKeys => call.fail(.refused, "harness.store already holds {d} keys; delete one first", .{max_keys}),
        error.StoreFull => call.fail(.refused, "harness.store would hold more than {d} MiB; delete values first", .{max_store_bytes >> 20}),
        else => call.fail(.internal, "harness.store failed: {s}", .{@errorName(err)}),
    };
}

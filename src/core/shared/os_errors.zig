//! The OS error codes behind `error.Unexpected` on the network, for `/trace`.
//!
//! Zig 0.17's `std.Io.Threaded` reports a socket or resolver errno that it
//! has no name for as `error.Unexpected`, and in release builds it does the
//! same for an errno it treats as a bug, such as `EINVAL` from `recvmsg`. The
//! errno is lost there, so a model request that fails this way says only
//! "Unexpected". `wrap` checks each network read, write, receive, send, and
//! DNS lookup: when one returns `error.Unexpected`, it notes the errno that
//! the call left in libc's `errno` on the same thread, or no errno for a
//! lookup. fx's own connect in `net_connect.zig` notes its errno here itself.
//!
//! No open upstream issue asks std to keep this errno. The GitHub issue
//! "Preserve platform error codes" (https://github.com/ziglang/zig/issues/2389)
//! was closed in 2020, and Codeberg has no open issue for it.
//!
//! The newest `capacity` notes are kept, process-wide and lock-protected.
//! `diagnostics.resetSession` clears them. Imports only the standard library.
const std = @import("std");
const builtin = @import("builtin");

/// Every fx build links libc, whose `errno` holds the code after the call.
const supported = builtin.link_libc and switch (builtin.target.os.tag) {
    .macos, .linux => true,
    else => false,
};

/// Notes kept, newest last.
pub const capacity = 16;

/// The call that returned `error.Unexpected`.
pub const Call = enum {
    /// A DNS lookup, noted without an errno. getaddrinfo reports its own
    /// codes and sets errno for only some of them, so the errno left after
    /// a lookup can be older than the lookup.
    lookup,
    connect,
    read,
    write,
    receive,
    send,
};

pub const Note = struct {
    /// Wall-clock time of the failure, in milliseconds since the epoch.
    at_ms: i64 = 0,
    call: Call = .read,
    /// The errno, or 0 when the call left none.
    errno: u16 = 0,

    /// The errno's name without its `E`, such as `INVAL`, or null when it
    /// is 0 or has no name on this OS.
    pub fn errnoName(self: Note) ?[]const u8 {
        if (self.errno == 0) return null;
        const err = std.enums.fromInt(std.posix.E, self.errno) orelse return null;
        // Linux's `E` is non-exhaustive, so `@tagName` would panic on a
        // code it has no name for.
        return std.enums.tagName(std.posix.E, err);
    }
};

var mutex: std.Io.Mutex = .init;
var notes: [capacity]Note = @splat(.{});
var head: usize = 0;
var stored: usize = 0;
/// Notes this session, including those no longer kept.
var total: u64 = 0;

/// Keeps a note of `call` failing with `errno`.
pub fn note(io: std.Io, call: Call, errno: u16) void {
    const now = std.Io.Timestamp.now(io, .real);
    const entry: Note = .{
        .at_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
        .call = call,
        .errno = errno,
    };
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    notes[head] = entry;
    head = (head + 1) % capacity;
    if (stored < capacity) stored += 1;
    total +|= 1;
}

/// Copies the newest kept notes into `out`, oldest first.
pub fn snapshot(io: std.Io, out: []Note) usize {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const n = @min(stored, out.len);
    for (out[0..n], 0..) |*slot, i| slot.* = notes[(head + capacity - n + i) % capacity];
    return n;
}

/// Notes this session, including those no longer kept.
pub fn count(io: std.Io) u64 {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return total;
}

pub fn reset(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    head = 0;
    stored = 0;
    total = 0;
}

/// libc's `errno` on this thread right after std returned `error.Unexpected`,
/// or 0 when it is not known. With `std.options.unexpected_error_tracing`, as
/// in Debug builds, std first prints the code and a stack trace, which can
/// change `errno`, so this is 0 there.
pub fn errnoAfterUnexpected() u16 {
    if (comptime !supported or std.options.unexpected_error_tracing) return 0;
    return std.math.cast(u16, std.c._errno().*) orelse 0;
}

// Installed before threads start, like `net_connect.wrap`.
var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_inner: ?*const std.Io.VTable = null;

/// `inner` with its `operate` and `netLookup` checked for `error.Unexpected`.
/// The vtable is process storage, so every call must pass the same `inner`
/// vtable.
pub fn wrap(inner: std.Io) std.Io {
    if (comptime !supported) return inner;
    if (wrapped_inner) |vtable| {
        std.debug.assert(vtable == inner.vtable);
    } else {
        wrapped_vtable = inner.vtable.*;
        wrapped_vtable.operate = operate;
        wrapped_vtable.netLookup = netLookup;
        wrapped_inner = inner.vtable;
    }
    return .{ .userdata = inner.userdata, .vtable = &wrapped_vtable };
}

fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    const inner = wrapped_inner.?;
    const result = try inner.operate(userdata, operation);
    // Read before anything else can set errno again.
    if (unexpectedCall(result)) |call| note(.{ .userdata = userdata, .vtable = inner }, call, errnoAfterUnexpected());
    return result;
}

fn netLookup(
    userdata: ?*anyopaque,
    host_name: std.Io.net.HostName,
    resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult),
    options: std.Io.net.HostName.LookupOptions,
) std.Io.net.HostName.LookupError!void {
    const inner = wrapped_inner.?;
    return inner.netLookup(userdata, host_name, resolved, options) catch |err| {
        if (err == error.Unexpected) note(.{ .userdata = userdata, .vtable = inner }, .lookup, 0);
        return err;
    };
}

/// The network call whose result is `error.Unexpected`, or null.
fn unexpectedCall(result: std.Io.Operation.Result) ?Call {
    return switch (result) {
        .net_read => |r| if (r) |_| null else |err| if (err == error.Unexpected) .read else null,
        .net_write => |r| if (r) |_| null else |err| if (err == error.Unexpected) .write else null,
        .net_receive => |r| if (r[0]) |err| if (err == error.Unexpected) .receive else null else null,
        .net_send => |r| if (r[0]) |err| if (err == error.Unexpected) .send else null else null,
        else => null,
    };
}

test "notes keep the call and errno and drop the oldest past capacity" {
    const io = std.testing.io;
    reset(io);
    defer reset(io);
    note(io, .connect, @backingInt(std.posix.E.HOSTDOWN));
    for (0..capacity) |_| note(io, .read, @backingInt(std.posix.E.INVAL));

    var out: [capacity]Note = undefined;
    try std.testing.expectEqual(@as(usize, capacity), snapshot(io, &out));
    try std.testing.expectEqual(@as(u64, capacity + 1), count(io));
    for (out) |kept| {
        try std.testing.expectEqual(Call.read, kept.call);
        try std.testing.expectEqualStrings("INVAL", kept.errnoName().?);
        try std.testing.expect(kept.at_ms > 0);
    }
}

test "an errno without a name has no name" {
    try std.testing.expectEqual(@as(?[]const u8, null), (Note{ .errno = 0 }).errnoName());
    try std.testing.expectEqual(@as(?[]const u8, null), (Note{ .errno = std.math.maxInt(u16) }).errnoName());
}

test "only network results that are error.Unexpected are noted" {
    try std.testing.expectEqual(@as(?Call, .read), unexpectedCall(.{ .net_read = error.Unexpected }));
    try std.testing.expectEqual(@as(?Call, null), unexpectedCall(.{ .net_read = error.ConnectionResetByPeer }));
    try std.testing.expectEqual(@as(?Call, null), unexpectedCall(.{ .net_read = .{ .data_len = 1 } }));
    try std.testing.expectEqual(@as(?Call, .write), unexpectedCall(.{ .net_write = error.Unexpected }));
    try std.testing.expectEqual(@as(?Call, null), unexpectedCall(.{ .net_write = 3 }));
    try std.testing.expectEqual(@as(?Call, .receive), unexpectedCall(.{ .net_receive = .{ error.Unexpected, 0 } }));
    try std.testing.expectEqual(@as(?Call, null), unexpectedCall(.{ .net_receive = .{ null, 1 } }));
    try std.testing.expectEqual(@as(?Call, .send), unexpectedCall(.{ .net_send = .{ error.Unexpected, 0 } }));
    try std.testing.expectEqual(@as(?Call, null), unexpectedCall(.{ .file_read_streaming = error.Unexpected }));
}

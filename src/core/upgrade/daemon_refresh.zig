//! After an update, moves an idle supervisor onto the new binary (D142).
//! Detached sessions outlive the terminal and the update; the supervisor
//! stops only when no session is working, no heartbeat is armed, and no
//! other terminal is attached. Otherwise it keeps the previous binary until
//! its own idle exit, and the next terminal starts the new one.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const client_mod = @import("../supervisor/client.zig");
const protocol = @import("../supervisor/protocol.zig");
const update_snapshot = @import("update_snapshot.zig");

const Allocator = std.mem.Allocator;

pub const Supervisor = update_snapshot.Supervisor;

/// What a `ping` said, reduced to the decision's inputs.
pub const Pong = struct {
    executable: []const u8,
    executable_inode: ?u64,
    busy: ?bool,
    clients: ?u32,
};

pub const Decision = enum { current, restart, wait, deferred, unknown };

/// `current_inode` is the inode now at the supervisor's executable path, or
/// null when it is gone. A previous terminal may still be closing, so a
/// second client is worth waiting for while attempts remain.
pub fn decide(pong: Pong, current_inode: ?u64, attempts_left: bool) Decision {
    const running_inode = pong.executable_inode orelse return .unknown;
    const busy = pong.busy orelse return .unknown;
    const clients = pong.clients orelse return .unknown;
    if (pong.executable.len == 0) return .unknown;
    if (current_inode) |inode| if (inode == running_inode) return .current;
    if (busy) return .deferred;
    if (clients > 1) return if (attempts_left) .wait else .deferred;
    return .restart;
}

/// Pings the supervisor and stops it when it runs a replaced binary and
/// nothing holds it. Never starts one.
pub fn refresh(alloc: Allocator) Supervisor {
    var client = client_mod.Client.init(alloc) catch return .none;
    defer client.deinit();
    const attempts = 40;
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        var response = client.request(alloc, .ping) catch return .none;
        defer response.deinit();
        const parsed = std.json.parseFromValueLeaky(protocol.Pong, response.arena.allocator(), response.value, .{ .ignore_unknown_fields = true }) catch return .unknown;
        if (!parsed.ok or parsed.version != protocol.version) return .unknown;
        const pong: Pong = .{
            .executable = parsed.executable,
            .executable_inode = parsed.executable_inode,
            .busy = parsed.busy,
            .clients = parsed.clients,
        };
        switch (decide(pong, inodeOf(pong.executable), attempt + 1 < attempts)) {
            .current => return .current,
            .deferred => return .deferred,
            .unknown => return .unknown,
            .wait => io_mod.sleep(50 * std.time.ns_per_ms),
            .restart => return stop(alloc, &client),
        }
    }
    return .deferred;
}

fn stop(alloc: Allocator, client: *client_mod.Client) Supervisor {
    var response = client.request(alloc, .shutdown) catch return .unknown;
    response.deinit();
    // The socket goes away once it has saved its sessions.
    const deadline = io_mod.milliTimestamp() + 10_000;
    while (io_mod.milliTimestamp() < deadline) {
        var ping = client.request(alloc, .ping) catch return .restarted;
        ping.deinit();
        io_mod.sleep(50 * std.time.ns_per_ms);
    }
    return .deferred;
}

fn inodeOf(path: []const u8) ?u64 {
    if (path.len == 0) return null;
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return null;
    return @intCast(stat.inode);
}

test "the supervisor restarts only when its binary changed and nothing holds it" {
    const base: Pong = .{ .executable = "/Users/example/.local/bin/proto-fx", .executable_inode = 7, .busy = false, .clients = 1 };
    try std.testing.expectEqual(Decision.current, decide(base, 7, true));
    try std.testing.expectEqual(Decision.restart, decide(base, 8, true));
    try std.testing.expectEqual(Decision.restart, decide(base, null, true));

    var busy = base;
    busy.busy = true;
    try std.testing.expectEqual(Decision.deferred, decide(busy, 8, true));

    var attached = base;
    attached.clients = 2;
    try std.testing.expectEqual(Decision.wait, decide(attached, 8, true));
    try std.testing.expectEqual(Decision.deferred, decide(attached, 8, false));

    // An older supervisor does not report what the decision needs.
    var old = base;
    old.busy = null;
    try std.testing.expectEqual(Decision.unknown, decide(old, 8, true));
}

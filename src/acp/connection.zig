//! A connection of this `fx acp` process: its id, and whether a second connection
//! can exist. Waiting input (a late steer, a queued prompt, a queued steer) records
//! the connection that sent it. A withdrawal matches the connection and the request
//! id together, because request ids are chosen per connection, so the id alone
//! cannot tell two clients apart. With one connection every entry carries the same
//! id, and matching gives the answer it always gave.

const std = @import("std");
const builtin = @import("builtin");
const host_target = @import("../core/hosts/target.zig");

/// Whether a second connection can exist. A second connection comes only through the
/// leader socket, which is served exactly where this holds: the same condition as
/// `leader_supported` in `server.zig`. WebAssembly has no socket and one connection.
pub const follow_supported = !host_target.is_wasm and (builtin.os.tag == .macos or builtin.os.tag == .linux);

/// The id of one connection of this process. Where `follow_supported` is false there
/// is one connection and nothing is shared, so the id is zero-size.
pub const ConnectionId = if (follow_supported) u64 else void;

/// The id no connection has. Input queued without a sender carries it. Connection ids
/// start at 1, so no connection ever has this one.
pub const no_connection: ConnectionId = if (follow_supported) 0 else {};

/// The process's connection counter. Only `newConnectionId` advances it.
var connection_ids: if (follow_supported) std.atomic.Value(u64) else void = if (follow_supported) std.atomic.Value(u64).init(1) else {};

/// A new connection's id. Every connection of the process gets a different one.
pub fn newConnectionId() ConnectionId {
    if (comptime !follow_supported) return {};
    return connection_ids.fetchAdd(1, .monotonic);
}

/// The number of a connection's client id, `c<number>`. WebAssembly has one connection, so its
/// number is 1.
pub fn clientNumber(id: ConnectionId) u64 {
    if (comptime !follow_supported) return 1;
    return id;
}

/// Whether two waiting entries came from the same connection. With one connection
/// (WebAssembly) every entry does, so the answer is always true there.
pub fn sameConnection(a: ConnectionId, b: ConnectionId) bool {
    if (comptime !follow_supported) return true;
    return a == b;
}

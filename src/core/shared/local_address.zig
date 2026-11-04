//! Whether a socket's local address still belongs to this machine.
//!
//! When the network changes, for example to another Wi-Fi network or a new
//! DHCP lease, a connection opened from the old address can never answer
//! again, and the kernel does not close it. Binding a scratch datagram socket
//! to the address fails with `EADDRNOTAVAIL` once no interface holds it.
//! Other targets than macOS and Linux never report an address missing.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = switch (builtin.target.os.tag) {
    .macos, .linux => true,
    else => false,
};

/// A socket address and its length, as `getsockname` and `bind` use them.
pub const Address = if (supported) struct {
    storage: std.posix.sockaddr.storage,
    len: std.posix.socklen_t,
} else void;

/// Tests make `missing` report every address missing.
pub var test_missing: bool = false;

/// The socket's local IP address, or null for a socket without one or one
/// `getsockname` refuses.
pub fn of(handle: anytype) ?Address {
    if (comptime !supported) return null;
    var address: Address = .{ .storage = undefined, .len = @sizeOf(std.posix.sockaddr.storage) };
    if (std.posix.errno(std.posix.system.getsockname(handle, @ptrCast(&address.storage), &address.len)) != .SUCCESS) return null;
    if (address.storage.family != std.posix.AF.INET and address.storage.family != std.posix.AF.INET6) return null;
    return address;
}

/// Whether no interface holds `address` any more. Binds a scratch datagram
/// socket to it with port 0. Any failure other than `EADDRNOTAVAIL`, such as
/// running out of descriptors, says nothing about the address, so it reports
/// the address present.
pub fn missing(address: Address) bool {
    if (comptime !supported) return false;
    if (builtin.is_test and test_missing) return true;
    var storage = address.storage;
    if (storage.family == std.posix.AF.INET) {
        @as(*std.posix.sockaddr.in, @ptrCast(&storage)).port = 0;
    } else if (storage.family == std.posix.AF.INET6) {
        @as(*std.posix.sockaddr.in6, @ptrCast(&storage)).port = 0;
    } else return false;
    // Darwin's socket() takes no SOCK_CLOEXEC; `std.posix.SOCK.CLOEXEC`
    // there is a flag for std's own wrappers, and the kernel refuses it.
    const flags = std.posix.SOCK.DGRAM | if (builtin.target.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const rc = std.posix.system.socket(storage.family, flags, 0);
    if (std.posix.errno(rc) != .SUCCESS) return false;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = std.posix.system.close(fd);
    if (builtin.target.os.tag != .linux) _ = std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    while (true) switch (std.posix.errno(std.posix.system.bind(fd, @ptrCast(&storage), address.len))) {
        .INTR => continue,
        .ADDRNOTAVAIL => return true,
        else => return false,
    };
}

fn ip4(octets: [4]u8) Address {
    var storage = std.mem.zeroes(std.posix.sockaddr.storage);
    const in: std.posix.sockaddr.in = .{ .port = 0, .addr = @bitCast(octets) };
    @memcpy(std.mem.asBytes(&storage)[0..@sizeOf(std.posix.sockaddr.in)], std.mem.asBytes(&in));
    return .{ .storage = storage, .len = @sizeOf(std.posix.sockaddr.in) };
}

test "an address no interface holds is missing, and loopback is present" {
    if (comptime !supported) return error.SkipZigTest;
    try std.testing.expect(!missing(ip4(.{ 127, 0, 0, 1 })));
    // 192.0.2.0/24 is reserved for documentation, so no machine holds it.
    try std.testing.expect(missing(ip4(.{ 192, 0, 2, 1 })));
}

test "a live connection's own address is present" {
    if (comptime !supported) return error.SkipZigTest;
    const io = std.testing.io;
    var listen_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const peer = std.Io.net.IpAddress{ .ip4 = .loopback(server.socket.address.getPort()) };
    // The listen backlog completes the connect without any server accept.
    var stream = try peer.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    const address = of(stream.socket.handle) orelse return error.TestExpectedAddress;
    try std.testing.expectEqual(@as(@TypeOf(address.storage.family), std.posix.AF.INET), address.storage.family);
    try std.testing.expect(!missing(address));
}

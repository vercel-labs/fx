//! A test `std.Io` that refuses to open the two keychain files std's macOS
//! trust scan reads, as a sandbox that denies them does, so no test reads
//! them. It can refuse the public CA bundle the loader falls back to as well
//! (`tls_roots.zig`). Tests only.

const std = @import("std");
const io_mod = @import("io.zig");

const keychain_files = [_][]const u8{
    "/System/Library/Keychains/SystemRootCertificates.keychain",
    "/Library/Keychains/System.keychain",
};
const public_bundle = "/etc/ssl/cert.pem";

var vtable: std.Io.VTable = undefined;
var refuse_public_bundle = false;

/// An Io for one client, such as `client.io`. It stays valid until the next
/// call.
pub fn io(public_bundle_too: bool) std.Io {
    refuse_public_bundle = public_bundle_too;
    vtable = std.testing.io.vtable.*;
    vtable.dirOpenFile = open;
    return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
}

pub const Installed = struct {
    previous: ?std.Io,

    /// Puts back the Io that `install` replaced.
    pub fn deinit(self: *Installed) void {
        io_mod.restoreIoForTest(self.previous);
        self.* = undefined;
    }
};

/// Makes every `io_mod.getIo()` caller, such as the client of an open job,
/// see the refusing Io from now until `deinit`. One at a time.
pub fn install(public_bundle_too: bool) Installed {
    return .{ .previous = io_mod.replaceIoForTest(io(public_bundle_too)) };
}

fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    for (keychain_files) |file| if (std.mem.eql(u8, path, file)) return error.PermissionDenied;
    if (refuse_public_bundle and std.mem.eql(u8, path, public_bundle)) return error.PermissionDenied;
    return std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
}

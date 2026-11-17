//! A HOME holding a stored fx login, for tests of code that reads the sign-in
//! every fx process shares. The keychain is off, so nothing reaches the
//! developer's own login.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const StoredLoginHome = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    map: std.process.Environ.Map,
    home: []u8,

    /// Installs an empty HOME; `self` must stay in place until `deinit`.
    pub fn install(self: *StoredLoginHome, alloc: Allocator) !void {
        self.* = .{ .alloc = alloc, .tmp = std.testing.tmpDir(.{}), .map = std.process.Environ.Map.init(alloc), .home = &.{} };
        errdefer self.tmp.cleanup();
        errdefer self.map.deinit();
        self.home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, "");
        errdefer alloc.free(self.home);
        try self.tmp.dir.createDirPath(io_mod.getIo(), ".fx");
        try self.map.put("FX_DISABLE_KEYCHAIN", "1");
        try self.map.put("HOME", self.home);
        io_mod.setEnvironMap(&self.map);
    }

    /// Saves a login for `team` that expires at `expires_at_ms`, as another fx
    /// process's refresh or sign-in would.
    pub fn store(self: *StoredLoginHome, token: []const u8, team: []const u8, expires_at_ms: i64) !void {
        var buf: [512]u8 = undefined;
        const json = try std.mem.print(&buf, "{{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\"," ++
            "\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_at_ms\":{d}," ++
            "\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\",\"team_id\":\"{s}\"}}", .{ token, expires_at_ms, team });
        try self.tmp.dir.writeFile(io_mod.getIo(), .{
            .sub_path = ".fx/auth.json",
            .data = json,
            .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
        });
    }

    pub fn deinit(self: *StoredLoginHome) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
    }
};

/// Far enough ahead that no test sees the login expire.
pub const far_future_ms: i64 = 4_102_444_800_000;

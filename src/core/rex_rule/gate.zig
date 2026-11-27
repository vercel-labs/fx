//! Decides whether fx may run Rex's command at all. `envAllows` checks the
//! values the caller passes in and touches no disk. `rexPath` checks the rex
//! file on disk, so the caller can run it off the main loop.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

pub const Env = struct {
    rex_bin_dir: ?[]const u8, // REX_BIN_DIR
    rex_block: ?[]const u8, // REX_BLOCK
    rex_server: ?[]const u8, // REX_SERVER
    xdg_config_home: ?[]const u8, // XDG_CONFIG_HOME
    home: ?[]const u8, // HOME
    token_ok: bool, // fx kept a valid OSC7577_TOKEN
};

pub const EnvPass = struct {
    rex_bin_dir: []const u8,
    block: []const u8,
    config_dir: []const u8,
};

const trace_scope = "rex_rule";
const rex_name = "rex";
const rex_config_name = "rex";
const config_parent_name = ".config";
const block_min_len = 1;
const block_max_len = 128;
const server_prefix = "unix://";
const any_exec_bits = 0o111;
const group_or_other_write_bits = 0o022;
const root_uid: std.c.uid_t = 0;

/// The checks on the values only, with no disk access. Caller owns the copies
/// in the result, allocated with `alloc`. Null when any check fails.
pub fn envAllows(alloc: std.mem.Allocator, env: Env) ?EnvPass {
    return envAllowsChecked(alloc, env) catch |err| {
        refuse(@errorName(err));
        return null;
    };
}

fn envAllowsChecked(alloc: std.mem.Allocator, env: Env) !?EnvPass {
    if (comptime !supportedOs()) {
        refuse("os");
        return null;
    }
    if (std.c.getuid() == root_uid) {
        refuse("root");
        return null;
    }
    if (!env.token_ok) {
        refuse("token");
        return null;
    }
    if (!validBlock(env.rex_block)) {
        refuse("block");
        return null;
    }
    if (!validServer(env.rex_server)) {
        refuse("server");
        return null;
    }
    const bin_dir = io_mod.absolutePath(env.rex_bin_dir) orelse {
        refuse("bin dir");
        return null;
    };
    const config_dir = (try configDirAlloc(alloc, env)) orelse {
        refuse("config dir");
        return null;
    };
    errdefer alloc.free(config_dir);
    const bin_owned = try alloc.dupe(u8, bin_dir);
    errdefer alloc.free(bin_owned);
    const block_owned = try alloc.dupe(u8, env.rex_block.?);
    return .{ .rex_bin_dir = bin_owned, .block = block_owned, .config_dir = config_dir };
}

/// The file checks on `<rex_bin_dir>/rex`: a regular file with an execute bit,
/// no group or other write bit, owned by fx's user or root, and outside
/// `workspace_root`. Returns its real path, owned by the caller (allocated with
/// `alloc`). Null when any check fails.
pub fn rexPath(alloc: std.mem.Allocator, rex_bin_dir: []const u8, workspace_root: []const u8) ?[]const u8 {
    return rexPathChecked(alloc, rex_bin_dir, workspace_root) catch |err| {
        refuse(@errorName(err));
        return null;
    };
}

fn rexPathChecked(alloc: std.mem.Allocator, rex_bin_dir: []const u8, workspace_root: []const u8) !?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const real = (try checkedRexPath(scratch.allocator(), rex_bin_dir, workspace_root, std.c.getuid())) orelse return null;
    return try alloc.dupe(u8, real);
}

fn supportedOs() bool {
    return builtin.target.os.tag == .macos or builtin.target.os.tag == .linux;
}

fn refuse(check: []const u8) void {
    debug_trace.logf(trace_scope, "rex gate closed check={s}", .{check});
}

fn validBlock(block: ?[]const u8) bool {
    const text = block orelse return false;
    if (text.len < block_min_len or text.len > block_max_len) return false;
    for (text) |byte| {
        if (!isBlockByte(byte)) return false;
    }
    return true;
}

fn isBlockByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '_' or byte == '.' or byte == '-';
}

fn validServer(server: ?[]const u8) bool {
    const text = server orelse return false;
    return std.mem.startsWith(u8, text, server_prefix);
}

/// Returns the config folder that Rex reads, owned by `alloc`. Null when neither
/// XDG_CONFIG_HOME nor HOME is an absolute path.
fn configDirAlloc(alloc: std.mem.Allocator, env: Env) !?[]const u8 {
    if (io_mod.absolutePath(env.xdg_config_home)) |xdg| {
        return try std.Io.Dir.path.join(alloc, &.{ xdg, rex_config_name });
    }
    if (io_mod.absolutePath(env.home)) |home| {
        return try std.Io.Dir.path.join(alloc, &.{ home, config_parent_name, rex_config_name });
    }
    return null;
}

/// Checks the rex file and returns its real path, which lives in `a`.
fn checkedRexPath(a: std.mem.Allocator, bin_dir: []const u8, workspace_root: []const u8, uid: std.c.uid_t) !?[]const u8 {
    const rex = try std.Io.Dir.path.join(a, &.{ bin_dir, rex_name });
    const stat = (try statNoFollow(a, rex)) orelse {
        refuse("rex missing");
        return null;
    };
    if ((stat.mode & std.c.S.IFMT) != std.c.S.IFREG) {
        refuse("rex is not a regular file");
        return null;
    }
    if ((stat.mode & any_exec_bits) == 0) {
        refuse("rex is not executable");
        return null;
    }
    if ((stat.mode & group_or_other_write_bits) != 0) {
        refuse("rex is writable by group or others");
        return null;
    }
    if (stat.uid != uid and stat.uid != root_uid) {
        refuse("rex has another owner");
        return null;
    }

    const real_rex = io_mod.realpathAlloc(a, rex) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            refuse("rex real path");
            return null;
        },
    };
    const workspace_real = io_mod.realpathAlloc(a, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            refuse("workspace root");
            return null;
        },
    };
    if (isInside(real_rex, workspace_real)) {
        refuse("rex inside workspace root");
        return null;
    }
    return real_rex;
}

const PathStat = struct {
    mode: u32,
    uid: u32,
};

/// Stats `path` itself: a symlink in the last part is not followed. Null when the stat fails.
fn statNoFollow(a: std.mem.Allocator, path: []const u8) !?PathStat {
    const path_z = try a.dupeSentinel(u8, path, 0);
    if (comptime builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        var buf = std.mem.zeroes(linux.Statx);
        if (linux.errno(linux.statx(linux.AT.FDCWD, path_z.ptr, linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &buf)) != .SUCCESS) return null;
        return .{ .mode = buf.mode, .uid = buf.uid };
    } else {
        var buf = std.mem.zeroes(std.c.Stat);
        if (std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &buf, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
        return .{ .mode = buf.mode, .uid = buf.uid };
    }
}

/// True when `path` is `root` or lies below it. `/a/bc` is not inside `/a/b`.
fn isInside(path: []const u8, root: []const u8) bool {
    const base = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path.len == base.len or path[base.len] == '/';
}

const testing = std.testing;

const Layout = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn create() !Layout {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const root = try io_mod.dirRealpathAlloc(arena.allocator(), tmp.dir, ".");
        return .{ .tmp = tmp, .arena = arena, .root = root };
    }

    fn deinit(self: *Layout) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn join(self: *Layout, name: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena.allocator(), &.{ self.root, name });
    }

    /// Creates `bin/rex` with exactly `mode`, whatever the umask says.
    fn writeRex(self: *Layout, mode: std.posix.mode_t) !void {
        try self.tmp.dir.createDirPath(io_mod.getIo(), "bin");
        try self.writeFileMode("bin/rex", mode);
    }

    fn writeFileMode(self: *Layout, sub_path: []const u8, mode: std.posix.mode_t) !void {
        const io = io_mod.getIo();
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "#!/bin/sh\n" });
        try self.tmp.dir.setFilePermissions(io, sub_path, std.Io.File.Permissions.fromMode(mode), .{});
    }

    fn goodEnv(self: *Layout) !Env {
        return .{
            .rex_bin_dir = try self.join("bin"),
            .rex_block = "fx-resume.1",
            .rex_server = "unix:///tmp/rex.sock",
            .xdg_config_home = null,
            .home = try self.join("home"),
            .token_ok = true,
        };
    }
};

fn freePass(pass: EnvPass) void {
    testing.allocator.free(pass.rex_bin_dir);
    testing.allocator.free(pass.block);
    testing.allocator.free(pass.config_dir);
}

test "rex resume gate env check accepts the good values and copies them" {
    var layout = try Layout.create();
    defer layout.deinit();
    const env = try layout.goodEnv();

    const pass = envAllows(testing.allocator, env) orelse return error.TestUnexpectedNull;
    defer freePass(pass);
    try testing.expectEqualStrings(try layout.join("bin"), pass.rex_bin_dir);
    try testing.expectEqualStrings("fx-resume.1", pass.block);
    try testing.expectEqualStrings(try layout.join("home/.config/rex"), pass.config_dir);
}

test "rex resume gate env check refuses a relative rex bin dir" {
    var layout = try Layout.create();
    defer layout.deinit();
    var env = try layout.goodEnv();
    env.rex_bin_dir = "bin";
    try testing.expect(envAllows(testing.allocator, env) == null);
}

test "rex resume gate env check refuses a missing token" {
    var layout = try Layout.create();
    defer layout.deinit();
    var env = try layout.goodEnv();
    env.token_ok = false;
    try testing.expect(envAllows(testing.allocator, env) == null);
}

test "rex resume gate env check refuses an empty, malformed, or too long block" {
    var layout = try Layout.create();
    defer layout.deinit();
    var env = try layout.goodEnv();

    env.rex_block = "";
    try testing.expect(envAllows(testing.allocator, env) == null);
    env.rex_block = "bad block";
    try testing.expect(envAllows(testing.allocator, env) == null);
    env.rex_block = "a/b";
    try testing.expect(envAllows(testing.allocator, env) == null);
    const too_long: [block_max_len + 1]u8 = @splat('a');
    env.rex_block = &too_long;
    try testing.expect(envAllows(testing.allocator, env) == null);
    env.rex_block = null;
    try testing.expect(envAllows(testing.allocator, env) == null);
}

test "rex resume gate env check refuses a tcp server and a missing server" {
    var layout = try Layout.create();
    defer layout.deinit();
    var env = try layout.goodEnv();

    env.rex_server = "tcp://127.0.0.1:7577";
    try testing.expect(envAllows(testing.allocator, env) == null);
    env.rex_server = null;
    try testing.expect(envAllows(testing.allocator, env) == null);
}

test "rex resume gate env check falls back to HOME when XDG_CONFIG_HOME is relative" {
    var layout = try Layout.create();
    defer layout.deinit();
    var env = try layout.goodEnv();
    env.xdg_config_home = "relative/config";

    const pass = envAllows(testing.allocator, env) orelse return error.TestUnexpectedNull;
    defer freePass(pass);
    try testing.expectEqualStrings(try layout.join("home/.config/rex"), pass.config_dir);
}

test "rex resume gate env check refuses when neither HOME nor XDG_CONFIG_HOME is absolute" {
    var layout = try Layout.create();
    defer layout.deinit();
    var env = try layout.goodEnv();
    env.home = null;
    try testing.expect(envAllows(testing.allocator, env) == null);
    env.home = "relative/home";
    try testing.expect(envAllows(testing.allocator, env) == null);
}

test "rex resume gate file check accepts a plain executable rex and returns its real path" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.writeRex(0o755);
    try layout.tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const path = rexPath(testing.allocator, try layout.join("bin"), try layout.join("workspace")) orelse return error.TestUnexpectedNull;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(try layout.join("bin/rex"), path);
}

test "rex resume gate file check refuses a missing rex" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.tmp.dir.createDirPath(io_mod.getIo(), "bin");
    try testing.expect(rexPath(testing.allocator, try layout.join("bin"), layout.root) == null);
}

test "rex resume gate file check refuses a rex that is not executable" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.writeRex(0o644);
    try testing.expect(rexPath(testing.allocator, try layout.join("bin"), layout.root) == null);
}

test "rex resume gate file check refuses a rex that group or others can write" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.writeRex(0o775);
    try testing.expect(rexPath(testing.allocator, try layout.join("bin"), layout.root) == null);
}

test "rex resume gate file check refuses a symlinked rex" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.tmp.dir.createDirPath(io_mod.getIo(), "bin");
    try layout.writeFileMode("bin/real_rex", 0o755);
    try layout.tmp.dir.symLink(io_mod.getIo(), "real_rex", "bin/rex", .{});
    try testing.expect(rexPath(testing.allocator, try layout.join("bin"), layout.root) == null);
}

test "rex resume gate file check refuses a rex inside the workspace root" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.writeRex(0o755);
    try testing.expect(rexPath(testing.allocator, try layout.join("bin"), try layout.join("bin")) == null);
}

test "rex resume gate file check does not treat a sibling with a shared prefix as inside" {
    var layout = try Layout.create();
    defer layout.deinit();
    try layout.writeRex(0o755);
    try layout.tmp.dir.createDirPath(io_mod.getIo(), "bi");

    const path = rexPath(testing.allocator, try layout.join("bin"), try layout.join("bi")) orelse return error.TestUnexpectedNull;
    testing.allocator.free(path);
}

//! Decides whether fx may run Rex's command at all. `envTarget` checks the
//! values the caller passes in and touches no disk. `rexPath` checks the rex
//! file on disk, so the caller runs it off the main loop.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const pathing = @import("../workspace/pathing.zig");

/// The Rex values of fx's environment. Rex sets all three in its terminals.
pub const Env = struct {
    rex_bin_dir: ?[]const u8, // REX_BIN_DIR
    rex_block: ?[]const u8, // REX_BLOCK
    rex_server: ?[]const u8, // REX_SERVER
};

/// Where fx runs `rex`, and the pane it runs in. Borrows from `Env`.
pub const Target = struct {
    rex_bin_dir: []const u8,
    block: []const u8,
};

const trace_scope = "rex_rename";
const rex_name = "rex";
const block_max_len = 128;
const server_prefix = "unix://";
const any_exec_bits = 0o111;
const group_or_other_write_bits = 0o022;
const root_uid: std.c.uid_t = 0;

/// The checks on the values only, with no disk access. Null when fx does not
/// run in a Rex terminal on this machine.
pub fn envTarget(env: Env) ?Target {
    if (comptime !supportedOs()) return refuse("os");
    if (!validBlock(env.rex_block)) return refuse("block");
    const server = env.rex_server orelse return refuse("server");
    if (!std.mem.startsWith(u8, server, server_prefix)) return refuse("server");
    const bin_dir = io_mod.absolutePath(env.rex_bin_dir) orelse return refuse("bin dir");
    return .{ .rex_bin_dir = bin_dir, .block = env.rex_block.? };
}

/// The file checks on `<rex_bin_dir>/rex`: a regular file with an execute
/// bit, no group or other write bit, owned by fx's user or root, and outside
/// `workspace_root`, so a repository cannot make fx run its own `rex`.
/// Returns its real path, owned by the caller. Null when a check fails.
pub fn rexPath(alloc: std.mem.Allocator, rex_bin_dir: []const u8, workspace_root: []const u8) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const real = checkedRexPath(scratch.allocator(), rex_bin_dir, workspace_root, std.c.getuid()) catch |err| {
        debug_trace.logf(trace_scope, "rex gate closed check=rex path error={s}", .{@errorName(err)});
        return null;
    } orelse return null;
    return alloc.dupe(u8, real) catch |err| {
        debug_trace.logf(trace_scope, "rex gate closed check=rex path error={s}", .{@errorName(err)});
        return null;
    };
}

fn supportedOs() bool {
    return builtin.target.os.tag == .macos or builtin.target.os.tag == .linux;
}

fn refuse(check: []const u8) ?Target {
    debug_trace.logf(trace_scope, "rex gate closed check={s}", .{check});
    return null;
}

fn refusePath(check: []const u8) ?[]const u8 {
    debug_trace.logf(trace_scope, "rex gate closed check={s}", .{check});
    return null;
}

/// A Rex block ID such as `block:01a2...`. It never starts with `-`, so `rex`
/// cannot read it as a flag.
fn validBlock(block: ?[]const u8) bool {
    const text = block orelse return false;
    if (text.len == 0 or text.len > block_max_len) return false;
    if (text[0] == '-') return false;
    for (text) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '_' or byte == '.' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

/// Checks the rex file and returns its real path, which lives in `a`.
fn checkedRexPath(a: std.mem.Allocator, bin_dir: []const u8, workspace_root: []const u8, uid: std.c.uid_t) !?[]const u8 {
    const rex = try std.Io.Dir.path.join(a, &.{ bin_dir, rex_name });
    const stat = (try statNoFollow(a, rex)) orelse return refusePath("rex missing");
    if ((stat.mode & std.c.S.IFMT) != std.c.S.IFREG) return refusePath("rex is not a regular file");
    if ((stat.mode & any_exec_bits) == 0) return refusePath("rex is not executable");
    if ((stat.mode & group_or_other_write_bits) != 0) return refusePath("rex is writable by group or others");
    if (stat.uid != uid and stat.uid != root_uid) return refusePath("rex has another owner");

    const real_rex = io_mod.realpathAlloc(a, rex) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refusePath("rex real path"),
    };
    const workspace_real = io_mod.realpathAlloc(a, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refusePath("workspace root"),
    };
    if (pathing.pathInside(workspace_real, real_rex)) return refusePath("rex inside workspace root");
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

const testing = std.testing;

test "fx runs rex only in a Rex terminal with a unix socket and a plain block ID" {
    const good: Env = .{ .rex_bin_dir = "/opt/rex/bin", .rex_block = "block:01a2-b3", .rex_server = "unix:///tmp/rex.sock" };
    const target = envTarget(good).?;
    try testing.expectEqualStrings("/opt/rex/bin", target.rex_bin_dir);
    try testing.expectEqualStrings("block:01a2-b3", target.block);

    var env = good;
    env.rex_block = null;
    try testing.expect(envTarget(env) == null);
    env.rex_block = "-s";
    try testing.expect(envTarget(env) == null);
    env.rex_block = "block 1";
    try testing.expect(envTarget(env) == null);
    env.rex_block = "";
    try testing.expect(envTarget(env) == null);

    env = good;
    env.rex_server = "tcp://host:1";
    try testing.expect(envTarget(env) == null);
    env.rex_server = null;
    try testing.expect(envTarget(env) == null);

    env = good;
    env.rex_bin_dir = "relative/bin";
    try testing.expect(envTarget(env) == null);
    env.rex_bin_dir = null;
    try testing.expect(envTarget(env) == null);
}

test "rex must be a private executable file outside the workspace" {
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "work");
    const root = try io_mod.dirRealpathAlloc(a, tmp.dir, ".");
    const bin = try std.Io.Dir.path.join(a, &.{ root, "bin" });
    const work = try std.Io.Dir.path.join(a, &.{ root, "work" });

    try testing.expect(rexPath(testing.allocator, bin, work) == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "bin/rex", .data = "#!/bin/sh\n" });
    try tmp.dir.setFilePermissions(io, "bin/rex", std.Io.File.Permissions.fromMode(0o644), .{});
    try testing.expect(rexPath(testing.allocator, bin, work) == null);

    try tmp.dir.setFilePermissions(io, "bin/rex", std.Io.File.Permissions.fromMode(0o775), .{});
    try testing.expect(rexPath(testing.allocator, bin, work) == null);

    try tmp.dir.setFilePermissions(io, "bin/rex", std.Io.File.Permissions.fromMode(0o755), .{});
    const real = rexPath(testing.allocator, bin, work).?;
    defer testing.allocator.free(real);
    try testing.expect(std.mem.endsWith(u8, real, "/bin/rex"));

    // The same file seen from a workspace that holds it is refused.
    try testing.expect(rexPath(testing.allocator, bin, root) == null);
}

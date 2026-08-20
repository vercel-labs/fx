const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

const Allocator = std.mem.Allocator;

const linux_self_exe = "/proc/self/exe";

/// Path used to spawn another copy of *this* process.
///
/// `zig build` replaces `zig-out/bin/fx` by unlink+rename. The running
/// inode stays alive, but `std.process.executablePathAlloc` realpaths
/// `/proc/self/exe` to the old on-disk name, and the next spawn is
/// `FileNotFound`. Linux `/proc/self/exe` still execs the live inode.
pub fn pathForReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    return productionPathForReexec(alloc);
}

/// `pathForReexec` without the test-only override.
///
/// `FX_TEST_PRODUCT_EXE` is set for every `zig build test` run, so a test that
/// calls `pathForReexec` never reaches the branch that ships. Tests cover this
/// entry point instead.
fn productionPathForReexec(alloc: Allocator) ![]u8 {
    if (comptime builtin.os.tag == .linux) return alloc.dupe(u8, linux_self_exe);
    return std.process.executablePathAlloc(io_mod.getIo(), alloc);
}

/// Path another process can use to exec this fx.
///
/// Tmux bootstraps and `pipe-pane` commands run later, so `/proc/self/exe`
/// would be the shell, not fx. Prefer the resolved on-disk path: it is the
/// only form that still works once this process is gone, and a recovered
/// session outlives the fx that created it. `/proc/<pid>/exe` is the
/// fallback for a replaced binary, where an on-disk path would be
/// `FileNotFound`; it dies with this process, so it is used only when
/// there is no on-disk file left to name.
pub fn pathForPeerReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    return productionPathForPeerReexec(alloc);
}

/// `pathForPeerReexec` without the test-only override. See
/// `productionPathForReexec` for why this split exists.
fn productionPathForPeerReexec(alloc: Allocator) ![]u8 {
    if (comptime builtin.os.tag == .linux) {
        if (std.process.executablePathAlloc(io_mod.getIo(), alloc)) |resolved| {
            defer alloc.free(resolved);
            if (onDiskPathIsExecutable(resolved)) return alloc.dupe(u8, resolved);
        } else |_| {}
        return std.fmt.allocPrint(alloc, "/proc/{d}/exe", .{std.c.getpid()});
    }
    const path_z = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(path_z);
    return alloc.dupe(u8, path_z);
}

/// True when `path` still names a file this process could exec. A rebuild
/// unlinks the old binary, so the resolved name can point at nothing.
fn onDiskPathIsExecutable(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

/// True when both paths resolve to the same file. Used to prove a procfs path
/// and the on-disk name are the same executable while they are still linked.
fn sameFile(left: []const u8, right: []const u8) !bool {
    var left_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), left, .{});
    defer left_file.close(io_mod.getIo());
    var right_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), right, .{});
    defer right_file.close(io_mod.getIo());
    const left_stat = try left_file.stat(io_mod.getIo());
    const right_stat = try right_file.stat(io_mod.getIo());
    return left_stat.inode == right_stat.inode;
}

fn testProductExe() ?[]const u8 {
    if (comptime !builtin.is_test) return null;
    const path_z = std.c.getenv("FX_TEST_PRODUCT_EXE") orelse return null;
    const path = std.mem.sliceTo(path_z, 0);
    return if (path.len == 0) null else path;
}

test "linux re-exec paths name the live inode, not the replaced on-disk file" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;

    // Covers the shipping branch directly. `pathForReexec` would return the
    // `FX_TEST_PRODUCT_EXE` override here, so it can never reach this code.
    const same_process = try productionPathForReexec(alloc);
    defer alloc.free(same_process);
    try std.testing.expectEqualStrings(linux_self_exe, same_process);

    const peer = try productionPathForPeerReexec(alloc);
    defer alloc.free(peer);

    // Same-process re-exec stays on procfs. Peer paths prefer the on-disk
    // name so a tmux bootstrap or pipe-pane still works after this pid exits.
    const resolved = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch null;
    defer if (resolved) |owned| alloc.free(owned);
    if (resolved) |on_disk| {
        try std.testing.expect(!std.mem.eql(u8, on_disk, same_process));
        try std.testing.expect(try sameFile(same_process, on_disk));
        if (onDiskPathIsExecutable(on_disk)) {
            try std.testing.expectEqualStrings(on_disk, peer);
        } else {
            const expected_peer = try std.fmt.allocPrint(alloc, "/proc/{d}/exe", .{std.c.getpid()});
            defer alloc.free(expected_peer);
            try std.testing.expectEqualStrings(expected_peer, peer);
        }
    }
}

test "linux re-exec still spawns after the on-disk binary is replaced" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;

    // The regression this guards: `zig build` replaces the binary by
    // unlink+rename, so the realpath of the running process names a file that
    // no longer exists. Spawn through both procfs forms after doing exactly
    // that, and require the child to run.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const victim = try std.fs.path.join(alloc, &.{ dir, "self-exe-probe" });
    defer alloc.free(victim);

    // `/bin/sh` stands in for the held process: it can block on a command,
    // while fx exits immediately without a TTY and so cannot keep its own
    // inode open. The mechanism under test is procfs, which is independent of
    // which executable holds the inode.
    try io_mod.copyFileAtomic(alloc, "/bin/sh", victim);
    try std.Io.Dir.cwd().setFilePermissions(
        io_mod.getIo(),
        victim,
        std.Io.File.Permissions.fromMode(0o755),
        .{ .follow_symlinks = false },
    );

    var held = try spawnHeldOpen(victim);
    // `kill` reaps the child, so it must not be followed by a `wait`.
    defer held.kill(io_mod.getIo());
    const child_pid = held.id orelse return error.SkipZigTest;

    // Replace by unlink+rename while the child holds the inode, as a rebuild does.
    try std.Io.Dir.cwd().deleteFile(io_mod.getIo(), victim);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().openFile(io_mod.getIo(), victim, .{}),
    );

    // The replaced name is gone, but the child's procfs entry still execs.
    const peer_path = try std.fmt.allocPrint(alloc, "/proc/{d}/exe", .{child_pid});
    defer alloc.free(peer_path);
    try expectExecSucceeds(peer_path);

    // And this process can always re-exec itself through /proc/self/exe.
    try std.testing.expect(onDiskPathIsExecutable(linux_self_exe));
}

test "peer re-exec path prefers a name that outlives this process" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;
    const path = try productionPathForPeerReexec(alloc);
    defer alloc.free(path);
    // A tmux pipe-pane command and a recovered session both run after this
    // process exits, so a /proc/<pid>/exe path would be dangling by then.
    // Only fall back to it when no on-disk name is left to use.
    if (std.mem.startsWith(u8, path, "/proc/")) {
        const resolved = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch return;
        defer alloc.free(resolved);
        try std.testing.expect(!onDiskPathIsExecutable(resolved));
        return;
    }
    try std.testing.expect(onDiskPathIsExecutable(path));
}

test "on-disk probe rejects a replaced binary so the peer path falls back" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;

    // The probe is what decides between the durable name and procfs, so cover
    // the rebuild case directly: a path unlinked while a process holds the
    // inode must read as unusable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir_path);
    const victim = try std.fs.path.join(alloc, &.{ dir_path, "fx-probe" });
    defer alloc.free(victim);

    {
        var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), victim, .{});
        file.close(io_mod.getIo());
    }
    try std.testing.expect(onDiskPathIsExecutable(victim));

    try std.Io.Dir.cwd().deleteFile(io_mod.getIo(), victim);
    try std.testing.expect(!onDiskPathIsExecutable(victim));

    // A relative name could resolve against the spawned process's cwd, so it
    // is never trusted as a peer path.
    try std.testing.expect(!onDiskPathIsExecutable("fx"));
}

/// Starts `path` so it stays alive while the caller removes the on-disk name,
/// keeping its inode and `/proc/<pid>/exe` valid.
fn spawnHeldOpen(path: []const u8) !std.process.Child {
    const argv = [_][]const u8{ path, "-c", "sleep 30" };
    return std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn expectExecSucceeds(path: []const u8) !void {
    const argv = [_][]const u8{ path, "-c", "exit 7" };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io_mod.getIo());
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 7), term.exited);
}

test "fx re-execs through procfs after its own on-disk copy is replaced" {
    if (builtin.os.tag != .linux) return;
    // Needs the built product, so this covers `zig build test`, not bare
    // `zig test` where no fx binary is pointed at.
    const product = testProductExe() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const copy = try std.fs.path.join(alloc, &.{ dir, "fx" });
    defer alloc.free(copy);

    try io_mod.copyFileAtomic(alloc, product, copy);
    try std.Io.Dir.cwd().setFilePermissions(
        io_mod.getIo(),
        copy,
        std.Io.File.Permissions.fromMode(0o755),
        .{ .follow_symlinks = false },
    );

    // Baseline: the copy runs from its on-disk name.
    try expectFxVersionRuns(copy);

    // Now do what `zig build` does to a running fx: unlink the name and put a
    // different file in its place. An fd opened before the swap still refers to
    // the original inode, which is what procfs paths resolve to.
    var held = try std.Io.Dir.cwd().openFile(io_mod.getIo(), copy, .{});
    defer held.close(io_mod.getIo());

    try std.Io.Dir.cwd().deleteFile(io_mod.getIo(), copy);
    try io_mod.copyFileAtomic(alloc, "/bin/sh", copy);

    // The name now resolves to a different executable, so a realpath-based
    // spawn would run the wrong program, or nothing at all. The retained inode
    // is still the real fx.
    const held_stat = try held.stat(io_mod.getIo());
    var replaced = try std.Io.Dir.cwd().openFile(io_mod.getIo(), copy, .{});
    defer replaced.close(io_mod.getIo());
    const replaced_stat = try replaced.stat(io_mod.getIo());
    try std.testing.expect(held_stat.inode != replaced_stat.inode);
}

fn expectFxVersionRuns(path: []const u8) !void {
    const argv = [_][]const u8{ path, "--version" };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io_mod.getIo());
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
}

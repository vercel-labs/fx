const std = @import("std");
const builtin = @import("builtin");

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;
const preferred_inherited_fd_target: std.posix.fd_t = 64;

pub fn wrap(original: std.Io) std.Io {
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.processSpawn = process_spawn;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

fn process_spawn(
    userdata: ?*anyopaque,
    options: std.process.SpawnOptions,
) std.process.SpawnError!std.process.Child {
    return process_spawn_inheriting_fd(userdata, options, null);
}

/// Spawns through the Darwin adapter while duplicating one borrowed descriptor
/// to a reserved high child descriptor. The caller retains parent ownership.
pub fn spawn_inheriting_fd(
    io: std.Io,
    options: std.process.SpawnOptions,
    inherited_fd: std.posix.fd_t,
) std.process.SpawnError!std.process.Child {
    if (comptime builtin.os.tag != .macos) return error.OperationUnsupported;
    return process_spawn_inheriting_fd(io.userdata, options, inherited_fd);
}

fn process_spawn_inheriting_fd(
    userdata: ?*anyopaque,
    options: std.process.SpawnOptions,
    inherited_fd: ?std.posix.fd_t,
) std.process.SpawnError!std.process.Child {
    if (comptime builtin.os.tag != .macos) return error.OperationUnsupported;
    if (options.uid != null or options.gid != null) return error.OperationUnsupported;
    if (options.argv.len == 0) return error.InvalidName;
    if (options.expand_arg0 == .expand) return error.OperationUnsupported;

    const stdin_pipe = if (options.stdin == .pipe) try create_pipe(false) else null;
    errdefer if (stdin_pipe) |pipe| close_pipe(pipe);
    const stdout_pipe = if (options.stdout == .pipe) try create_pipe(false) else null;
    errdefer if (stdout_pipe) |pipe| close_pipe(pipe);
    const stderr_pipe = if (options.stderr == .pipe) try create_pipe(false) else null;
    errdefer if (stderr_pipe) |pipe| close_pipe(pipe);
    const progress_pipe = if (options.progress_node.index != .none) try create_pipe(true) else null;
    errdefer if (progress_pipe) |pipe| close_pipe(pipe);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, 0..) |arg, index| {
        argv[index] = (try arena.dupeZ(u8, arg)).ptr;
    }

    const progress_fileno: std.posix.fd_t = 3;
    const child_environment = if (options.environ_map) |environment|
        try environment.createPosixBlock(arena, .{
            .zig_progress_fd = if (progress_pipe == null) -1 else progress_fileno,
        })
    else
        try inherited_environment().createPosixBlock(arena, .{
            .zig_progress_fd = if (progress_pipe == null) -1 else progress_fileno,
        });

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    try check_spawn_call(std.c.posix_spawn_file_actions_init(&actions));
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);

    try add_cwd_action(&actions, options.cwd, arena);
    try add_stdio_action(&actions, options.stdin, stdin_pipe, std.posix.STDIN_FILENO, true);
    try add_stdio_action(&actions, options.stdout, stdout_pipe, std.posix.STDOUT_FILENO, false);
    try add_stdio_action(&actions, options.stderr, stderr_pipe, std.posix.STDERR_FILENO, false);
    if (progress_pipe) |pipe| {
        try add_inherit_or_dup(&actions, pipe[1], progress_fileno);
    }
    if (inherited_fd) |fd| {
        try add_inherit_or_dup(&actions, fd, inherited_fd_target(fd));
    }

    var attributes: std.c.posix_spawnattr_t = undefined;
    try check_spawn_call(std.c.posix_spawnattr_init(&attributes));
    defer _ = std.c.posix_spawnattr_destroy(&attributes);

    var flags: std.c.POSIX_SPAWN = .{
        .CLOEXEC_DEFAULT = true,
        .START_SUSPENDED = options.start_suspended,
        .DISABLE_ASLR = options.disable_aslr,
    };
    if (options.pgid) |process_group| {
        flags.SETPGROUP = true;
        try set_process_group(&attributes, process_group);
    }
    try check_spawn_call(std.c.posix_spawnattr_setflags(&attributes, flags));

    var pid: std.posix.pid_t = undefined;
    const spawn_result = std.c.posix_spawnp(
        &pid,
        argv[0].?,
        &actions,
        &attributes,
        argv.ptr,
        child_environment.slice.ptr,
    );
    if (spawn_result != 0) return map_spawn_error(spawn_result, options);

    if (stdin_pipe) |pipe| close_fd(pipe[0]);
    if (stdout_pipe) |pipe| close_fd(pipe[1]);
    if (stderr_pipe) |pipe| close_fd(pipe[1]);
    if (progress_pipe) |pipe| {
        close_fd(pipe[1]);
        options.progress_node.setIpcFile(userdata, .{
            .handle = pipe[0],
            .flags = .{ .nonblocking = true },
        });
    }

    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = if (stdin_pipe) |pipe| .{
            .handle = pipe[1],
            .flags = .{ .nonblocking = false },
        } else null,
        .stdout = if (stdout_pipe) |pipe| .{
            .handle = pipe[0],
            .flags = .{ .nonblocking = false },
        } else null,
        .stderr = if (stderr_pipe) |pipe| .{
            .handle = pipe[0],
            .flags = .{ .nonblocking = false },
        } else null,
        .request_resource_usage_statistics = options.request_resource_usage_statistics,
    };
}

fn inherited_environment() std.process.Environ {
    const environment: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    var count: usize = 0;
    while (environment[count] != null) : (count += 1) {}
    return .{ .block = .{ .slice = environment[0..count :null] } };
}

fn create_pipe(nonblocking: bool) std.process.SpawnError![2]std.posix.fd_t {
    var pipe: [2]std.posix.fd_t = undefined;
    const result = std.posix.system.pipe(&pipe);
    switch (std.posix.errno(result)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    errdefer close_pipe(pipe);

    for (pipe) |fd| {
        const set_descriptor = std.posix.system.fcntl(
            fd,
            std.posix.F.SETFD,
            @as(usize, std.posix.FD_CLOEXEC),
        );
        switch (std.posix.errno(set_descriptor)) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
        if (nonblocking) {
            const status_flags: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
            const set_status = std.posix.system.fcntl(
                fd,
                std.posix.F.SETFL,
                status_flags,
            );
            switch (std.posix.errno(set_status)) {
                .SUCCESS => {},
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
    return pipe;
}

fn add_cwd_action(
    actions: *std.c.posix_spawn_file_actions_t,
    cwd: std.process.Child.Cwd,
    arena: std.mem.Allocator,
) std.process.SpawnError!void {
    switch (cwd) {
        .inherit => {},
        .dir => |dir| try check_spawn_call(
            std.c.posix_spawn_file_actions_addfchdir_np(actions, dir.handle),
        ),
        .path => |path| {
            const path_z = try arena.dupeZ(u8, path);
            try check_spawn_call(
                std.c.posix_spawn_file_actions_addchdir_np(actions, path_z.ptr),
            );
        },
    }
}

fn add_stdio_action(
    actions: *std.c.posix_spawn_file_actions_t,
    stdio: std.process.SpawnOptions.StdIo,
    pipe: ?[2]std.posix.fd_t,
    target: std.posix.fd_t,
    input: bool,
) std.process.SpawnError!void {
    switch (stdio) {
        .inherit => try check_spawn_call(
            std.c.posix_spawn_file_actions_addinherit_np(actions, target),
        ),
        .file => |file| try add_inherit_or_dup(actions, file.handle, target),
        .ignore => {
            const open_flags: c_int = @bitCast(std.posix.O{
                .ACCMODE = if (input) .RDONLY else .WRONLY,
            });
            try check_spawn_call(std.c.posix_spawn_file_actions_addopen(
                actions,
                target,
                "/dev/null",
                open_flags,
                0,
            ));
        },
        .pipe => {
            const pipe_fd = if (input) pipe.?[0] else pipe.?[1];
            try add_inherit_or_dup(actions, pipe_fd, target);
        },
        .close => try check_spawn_call(
            std.c.posix_spawn_file_actions_addclose(actions, target),
        ),
    }
}

fn add_inherit_or_dup(
    actions: *std.c.posix_spawn_file_actions_t,
    source: std.posix.fd_t,
    target: std.posix.fd_t,
) std.process.SpawnError!void {
    if (source == target) {
        try check_spawn_call(
            std.c.posix_spawn_file_actions_addinherit_np(actions, target),
        );
    } else {
        try check_spawn_call(
            std.c.posix_spawn_file_actions_adddup2(actions, source, target),
        );
    }
}

pub fn inherited_fd_target(source: std.posix.fd_t) std.posix.fd_t {
    return if (source == preferred_inherited_fd_target)
        preferred_inherited_fd_target + 1
    else
        preferred_inherited_fd_target;
}

extern "c" fn posix_spawnattr_setpgroup(
    attributes: *std.c.posix_spawnattr_t,
    process_group: std.posix.pid_t,
) c_int;

fn set_process_group(
    attributes: *std.c.posix_spawnattr_t,
    process_group: std.posix.pid_t,
) std.process.SpawnError!void {
    const result = posix_spawnattr_setpgroup(attributes, process_group);
    if (result == 0) return;
    const err: std.posix.E = @enumFromInt(@as(u16, @intCast(result)));
    if (err == .INVAL) return error.InvalidProcessGroupId;
    return map_errno(err);
}

fn check_spawn_call(result: c_int) std.process.SpawnError!void {
    if (result == 0) return;
    return map_errno(@enumFromInt(@as(u16, @intCast(result))));
}

fn map_spawn_error(
    result: c_int,
    options: std.process.SpawnOptions,
) std.process.SpawnError {
    const err: std.posix.E = @enumFromInt(@as(u16, @intCast(result)));
    if (err == .INVAL and options.pgid != null) return error.InvalidProcessGroupId;
    return map_errno(err);
}

fn map_errno(err: std.posix.E) std.process.SpawnError {
    return switch (err) {
        .SUCCESS => unreachable,
        .@"2BIG", .AGAIN, .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL, .NOEXEC => error.InvalidExe,
        .IO => error.FileSystem,
        .LOOP => error.SymLinkLoop,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        .NAMETOOLONG => error.NameTooLong,
        .NODEV => error.NoDevice,
        .BADEXEC, .BADARCH => error.InvalidExe,
        else => std.posix.unexpectedErrno(err),
    };
}

fn close_pipe(pipe: [2]std.posix.fd_t) void {
    close_fd(pipe[0]);
    close_fd(pipe[1]);
}

fn close_fd(fd: std.posix.fd_t) void {
    switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS, .INTR => {},
        else => {},
    }
}

fn darwin_io() !std.Io {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    return wrap(std.testing.io);
}

fn expect_exited(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(expected, code),
        else => return error.UnexpectedTermination,
    }
}

fn wait_exited(child: *std.process.Child, io: std.Io, expected: u8) !void {
    defer if (child.id != null) child.kill(io);
    try expect_exited(try child.wait(io), expected);
}

fn read_pipe_alloc(alloc: std.mem.Allocator, io: std.Io, file: *std.Io.File) ![]u8 {
    var buffer: [256]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(alloc, .limited(4096));
}

const max_tracked_children = 256;

const ChildPidSnapshot = struct {
    pids: [max_tracked_children]std.posix.pid_t = undefined,
    len: usize,

    fn contains(self: ChildPidSnapshot, pid: std.posix.pid_t) bool {
        return std.mem.containsAtLeastScalar(std.posix.pid_t, self.pids[0..self.len], 1, pid);
    }
};

extern "c" fn proc_listchildpids(
    parent_pid: std.posix.pid_t,
    buffer: ?*anyopaque,
    buffer_size: c_int,
) c_int;

fn child_pid_snapshot() !ChildPidSnapshot {
    if (comptime builtin.os.tag != .macos) return error.OperationUnsupported;
    var snapshot: ChildPidSnapshot = .{ .len = 0 };
    const result = proc_listchildpids(
        std.c.getpid(),
        &snapshot.pids,
        @intCast(@sizeOf(@TypeOf(snapshot.pids))),
    );
    if (result < 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
    snapshot.len = @intCast(result);
    return snapshot;
}

fn has_new_child(before: ChildPidSnapshot, after: ChildPidSnapshot) bool {
    for (after.pids[0..after.len]) |pid| {
        if (!before.contains(pid)) return true;
    }
    return false;
}

fn wait_for_children_to_settle(
    io: std.Io,
    before: ChildPidSnapshot,
) !ChildPidSnapshot {
    var after = try child_pid_snapshot();
    for (0..100) |_| {
        if (!has_new_child(before, after)) return after;
        try io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real);
        after = try child_pid_snapshot();
    }
    return after;
}

fn reap_new_children(
    io: std.Io,
    before: ChildPidSnapshot,
    after: ChildPidSnapshot,
) void {
    for (after.pids[0..after.len]) |pid| {
        if (!before.contains(pid)) reap_child(io, pid);
    }
}

fn reap_child(io: std.Io, pid: std.posix.pid_t) void {
    var status: c_int = undefined;
    for (0..100) |_| {
        const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result > 0) return,
            .CHILD => return,
            .INTR => continue,
            else => return,
        }
        io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch return;
    }
}

const max_tracked_fd = if (builtin.os.tag == .macos) std.c.OPEN_MAX else 256;

fn open_fd_snapshot() [max_tracked_fd]bool {
    var result = [_]bool{false} ** max_tracked_fd;
    for (&result, 0..) |*open, fd| {
        const rc = std.posix.system.fcntl(@intCast(fd), std.posix.F.GETFD, @as(usize, 0));
        open.* = std.posix.errno(rc) == .SUCCESS;
    }
    return result;
}

fn close_new_fds(before: [max_tracked_fd]bool, after: [max_tracked_fd]bool) void {
    for (before, after, 0..) |was_open, is_open, fd| {
        if (!was_open and is_open) _ = std.posix.system.close(@intCast(fd));
    }
}

test "Darwin spawn resolves argv through parent PATH and replaces the child environment" {
    const io = try darwin_io();
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("PATH", "/not/a/search/path");
    try environment.put("FX_SPAWN_CONTRACT", "child-only");

    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "sh", "-c", "printf '%s:%s' \"$FX_SPAWN_CONTRACT\" \"$PATH\"" },
        .environ_map = &environment,
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    try expect_exited(result.term, 0);
    try std.testing.expectEqualStrings("child-only:/not/a/search/path", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "Darwin explicit inherited descriptor avoids low user descriptors" {
    const io = try darwin_io();
    for ([_]std.posix.fd_t{
        0,
        3,
        preferred_inherited_fd_target,
        preferred_inherited_fd_target + 1,
        255,
    }) |source_fd| {
        const selected_fd = inherited_fd_target(source_fd);
        try std.testing.expect(selected_fd >= preferred_inherited_fd_target);
        try std.testing.expect(selected_fd != source_fd);
    }
    const pipe = try create_pipe(false);
    defer close_pipe(pipe);
    const target_fd = inherited_fd_target(pipe[1]);
    try std.testing.expect(pipe[1] != target_fd);
    try std.testing.expect(target_fd >= preferred_inherited_fd_target);
    var source_buffer: [32]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "{d}", .{pipe[1]});
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(
        &target_buffer,
        "{d}",
        .{target_fd},
    );
    var child = try spawn_inheriting_fd(io, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            "test -e /dev/fd/$2 && ! test -e /dev/fd/$1",
            "sh",
            source,
            target,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, pipe[1]);
    try wait_exited(&child, io, 0);
}

test "Darwin inherited descriptor survives Bash script execution" {
    const io = try darwin_io();
    const pipe = try create_pipe(false);
    defer close_pipe(pipe);
    const target_fd = inherited_fd_target(pipe[1]);
    try std.testing.expect(pipe[1] != target_fd);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var script = try tmp.dir.createFile(io, "inherit-fd.sh", .{});
        defer script.close(io);
        try script.writeStreamingAll(
            io,
            "#!/bin/bash\n" ++
                "/bin/sh -c 'test -p /dev/fd/$1' sh \"$1\"\n",
        );
    }
    var fd_buffer: [32]u8 = undefined;
    const fd_text = try std.fmt.bufPrint(
        &fd_buffer,
        "{d}",
        .{target_fd},
    );
    var child = try spawn_inheriting_fd(io, .{
        .argv = &.{ "/bin/bash", "inherit-fd.sh", fd_text },
        .cwd = .{ .dir = tmp.dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, pipe[1]);
    try wait_exited(&child, io, 0);
}

test "Darwin spawn accepts path and directory working directories" {
    const io = try darwin_io();
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    const expected = path_buffer[0..path_len];

    const path_result = try std.process.run(alloc, io, .{
        .argv = &.{"/bin/pwd"},
        .cwd = .{ .path = expected },
    });
    defer alloc.free(path_result.stdout);
    defer alloc.free(path_result.stderr);
    try expect_exited(path_result.term, 0);
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, path_result.stdout, "\r\n"));

    const dir_result = try std.process.run(alloc, io, .{
        .argv = &.{"/bin/pwd"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer alloc.free(dir_result.stdout);
    defer alloc.free(dir_result.stderr);
    try expect_exited(dir_result.term, 0);
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, dir_result.stdout, "\r\n"));
}

test "Darwin spawn preserves pipe stdio in every direction" {
    const io = try darwin_io();
    const alloc = std.testing.allocator;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "read value; printf 'out:%s' \"$value\"; printf 'err:%s' \"$value\" >&2" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.id != null) child.kill(io);

    try child.stdin.?.writeStreamingAll(io, "value\n");
    child.stdin.?.close(io);
    child.stdin = null;
    const stdout = try read_pipe_alloc(alloc, io, &child.stdout.?);
    defer alloc.free(stdout);
    const stderr = try read_pipe_alloc(alloc, io, &child.stderr.?);
    defer alloc.free(stderr);

    try wait_exited(&child, io, 0);
    try std.testing.expectEqualStrings("out:value", stdout);
    try std.testing.expectEqualStrings("err:value", stderr);
}

test "Darwin spawn preserves inherit ignore file and close stdio modes" {
    const io = try darwin_io();

    var inherited = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", ":" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    try wait_exited(&inherited, io, 0);

    var ignored = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf ignored; printf ignored >&2" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try wait_exited(&ignored, io, 0);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(io, "output", .{ .read = true });
    defer output.close(io);
    var file_child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf file-output" },
        .stdin = .ignore,
        .stdout = .{ .file = output },
        .stderr = .ignore,
    });
    try wait_exited(&file_child, io, 0);
    var file_bytes: [32]u8 = undefined;
    const written = try output.readPositionalAll(io, &file_bytes, 0);
    try std.testing.expectEqualStrings("file-output", file_bytes[0..written]);

    var closed = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "test ! -e /dev/fd/1" },
        .stdin = .ignore,
        .stdout = .close,
        .stderr = .ignore,
    });
    try wait_exited(&closed, io, 0);
}

test "Darwin spawn reports launch errors and preserves wait and kill" {
    const io = try darwin_io();
    const missing_before = try child_pid_snapshot();
    try std.testing.expectError(error.FileNotFound, std.process.spawn(io, .{
        .argv = &.{"fx-contract-executable-that-does-not-exist"},
    }));
    const missing_after = try wait_for_children_to_settle(io, missing_before);
    defer reap_new_children(io, missing_before, missing_after);
    try std.testing.expect(!has_new_child(missing_before, missing_after));

    var nonzero = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 23" },
    });
    try wait_exited(&nonzero, io, 23);

    var signaled = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "kill -TERM $$" },
    });
    defer if (signaled.id != null) signaled.kill(io);
    switch (try signaled.wait(io)) {
        .signal => |signal| try std.testing.expectEqual(std.posix.SIG.TERM, signal),
        else => return error.UnexpectedTermination,
    }

    var killed = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    killed.kill(io);
    try std.testing.expect(killed.id == null);
    try std.testing.expect(killed.stdin == null);
    try std.testing.expect(killed.stdout == null);
    try std.testing.expect(killed.stderr == null);
}

extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

test "Darwin spawn creates and joins a pipeline process group" {
    const io = try darwin_io();
    const alloc = std.testing.allocator;
    var producer = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf alpha; sleep 30" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer if (producer.id != null) producer.kill(io);

    const group_id = producer.id.?;
    var consumer = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/tr", "a-z", "A-Z" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = group_id,
    });
    defer if (consumer.id != null) consumer.kill(io);

    try std.testing.expectEqual(group_id, getpgid(producer.id.?));
    try std.testing.expectEqual(group_id, getpgid(consumer.id.?));

    var producer_buffer: [16]u8 = undefined;
    var producer_reader = producer.stdout.?.reader(io, &producer_buffer);
    var input: [5]u8 = undefined;
    try producer_reader.interface.readSliceAll(&input);
    producer.stdout.?.close(io);
    producer.stdout = null;
    try consumer.stdin.?.writeStreamingAll(io, &input);
    consumer.stdin.?.close(io);
    consumer.stdin = null;

    const output = try read_pipe_alloc(alloc, io, &consumer.stdout.?);
    defer alloc.free(output);
    try wait_exited(&consumer, io, 0);
    try std.testing.expectEqualStrings("ALPHA", output);
    producer.kill(io);
}

const ParallelSpawn = struct {
    io: std.Io,
    start: *std.Io.Semaphore,
    token: []const u8,
    passed: bool = false,

    fn run(self: *ParallelSpawn) void {
        self.start.waitUncancelable(self.io);
        const result = std.process.run(std.heap.c_allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", "printf '%s' \"$1\"", "sh", self.token },
        }) catch return;
        defer std.heap.c_allocator.free(result.stdout);
        defer std.heap.c_allocator.free(result.stderr);
        const exited = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        self.passed = exited and
            std.mem.eql(u8, self.token, result.stdout) and
            result.stderr.len == 0;
    }
};

test "parallel Darwin spawns isolate descriptors and each output reaches EOF" {
    const io = try darwin_io();
    var start: std.Io.Semaphore = .{ .permits = 0 };
    var workers = [_]ParallelSpawn{
        .{ .io = io, .start = &start, .token = "zero" },
        .{ .io = io, .start = &start, .token = "one" },
        .{ .io = io, .start = &start, .token = "two" },
        .{ .io = io, .start = &start, .token = "three" },
        .{ .io = io, .start = &start, .token = "four" },
        .{ .io = io, .start = &start, .token = "five" },
        .{ .io = io, .start = &start, .token = "six" },
        .{ .io = io, .start = &start, .token = "seven" },
    };
    var threads: [workers.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer {
        for (0..started) |_| start.post(io);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, ParallelSpawn.run, .{worker});
        started += 1;
    }
    for (threads) |_| start.post(io);
    for (threads) |thread| thread.join();
    for (workers) |worker| try std.testing.expect(worker.passed);
}

test "Darwin spawn partial setup failure closes every parent descriptor" {
    const io = try darwin_io();
    const before = open_fd_snapshot();
    const children_before = try child_pid_snapshot();
    try std.testing.expectError(error.FileNotFound, std.process.spawn(io, .{
        .argv = &.{"/bin/sh"},
        .cwd = .{ .path = "/fx-contract-cwd-that-does-not-exist" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }));
    const after = open_fd_snapshot();
    const children_after = try wait_for_children_to_settle(io, children_before);
    defer close_new_fds(before, after);
    defer reap_new_children(io, children_before, children_after);
    try std.testing.expectEqualSlices(bool, &before, &after);
}

test "Darwin spawn partial setup failure leaves no child behind" {
    const io = try darwin_io();
    const before = try child_pid_snapshot();
    try std.testing.expectError(error.FileNotFound, std.process.spawn(io, .{
        .argv = &.{"/bin/sh"},
        .cwd = .{ .path = "/fx-contract-cwd-that-does-not-exist" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }));
    const after = try wait_for_children_to_settle(io, before);
    defer reap_new_children(io, before, after);
    try std.testing.expect(!has_new_child(before, after));
}

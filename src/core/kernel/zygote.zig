//! The kernel fork server. One pre-warmed, single-threaded Python per
//! interpreter path (`runtime.py --zygote`) has imported the runtime's modules
//! and forks each new kernel, so kernels share those pages and skip the imports.
//!
//! Handoff: this side creates the kernel's three pipes and sends the child ends
//! by SCM_RIGHTS over a socketpair that is the zygote's stdin, with the kernel's
//! cwd and environment. The zygote forks, the child wires the pipes to fds 0-2
//! and runs runtime.py's `main` as a direct spawn would, and the reply names the
//! child's pid. The zygote reaps its children; `process.zig` owns signals, stop
//! and exit detection. A dead zygote is reaped and replaced on the next request,
//! and any failure leaves the caller to spawn the kernel directly.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const memory = @import("memory.zig");
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;
const now = io_mod.monotonicMilliTimestamp;

pub const enable_env = "PROTO_FX_KERNEL_ZYGOTE";
/// Must match the zygote's ready line, which carries runtime.py's protocol version.
const protocol_version = @import("protocol.zig").version;
/// Two failures this close together, each a failed start or a request that
/// failed on a fresh zygote, disable the zygote for as long.
const failure_window_ms = 60_000;

/// The kernel's ends of its pipes, as this process sees them, and its pid.
pub const Forked = struct {
    pid: std.posix.pid_t,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
};

const Zygote = struct {
    python: []u8,
    runtime: []u8,
    /// Serializes requests and guards the fields below.
    lock: std.Io.Mutex = .init,
    pid: std.posix.pid_t = 0,
    socket: fd_t = -1,
    failures: u8 = 0,
    failed_at: i64 = 0,
};

var registry_lock: std.Io.Mutex = .init;
var registry: std.ArrayList(*Zygote) = .empty;

/// Whether kernels should fork from a zygote; `PROTO_FX_KERNEL_ZYGOTE=0` turns
/// it off and every kernel spawns directly.
pub fn enabled() bool {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return false;
    const raw = io_mod.getenv(enable_env) orelse return true;
    return !std.mem.eql(u8, raw, "0");
}

/// Forks a kernel from the zygote for `python`, starting or replacing the
/// zygote as needed. On error nothing is left open and the caller spawns directly.
pub fn fork(alloc: Allocator, python: []const u8, runtime: []const u8, cwd: []const u8, env: *const std.process.Environ.Map) !Forked {
    if (!enabled()) return error.ZygoteDisabled;
    const zygote = try lookup(python, runtime);
    const io = io_mod.getIo();
    zygote.lock.lockUncancelable(io);
    defer zygote.lock.unlock(io);
    if (zygote.failures >= 2 and now() - zygote.failed_at < failure_window_ms) return error.ZygoteDisabled;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        reapIfExited(zygote);
        if (zygote.pid == 0) start(alloc, zygote, env) catch |err| {
            zygote.failures +|= 1;
            zygote.failed_at = now();
            debug_trace.logf("kernel", "zygote start failed: {s}", .{@errorName(err)});
            return err;
        };
        if (request(alloc, zygote, cwd, env)) |forked| {
            zygote.failures = 0;
            return forked;
        } else |err| {
            debug_trace.logf("kernel", "zygote fork failed: {s}", .{@errorName(err)});
            // A zygote that broke mid-request is replaced once; the retry tells
            // a dead zygote from a request it cannot serve.
            stopLocked(zygote);
            if (attempt > 0) {
                zygote.failures +|= 1;
                zygote.failed_at = now();
                return err;
            }
        }
    }
}

/// Stops every zygote. Running kernels are unaffected. The pool calls this
/// once no kernel has been live for a while, so an idle process holds no Python.
pub fn stopAll() void {
    const io = io_mod.getIo();
    registry_lock.lockUncancelable(io);
    defer registry_lock.unlock(io);
    for (registry.items) |zygote| {
        zygote.lock.lockUncancelable(io);
        stopLocked(zygote);
        zygote.lock.unlock(io);
    }
}

/// The pids of running zygotes, for the memory budget. Returns how many it wrote.
pub fn pids(out: []std.posix.pid_t) usize {
    const io = io_mod.getIo();
    registry_lock.lockUncancelable(io);
    defer registry_lock.unlock(io);
    var count: usize = 0;
    for (registry.items) |zygote| {
        if (count == out.len) break;
        // A zygote mid-request keeps its pid; skipping it for one sample is harmless.
        if (!zygote.lock.tryLock()) continue;
        defer zygote.lock.unlock(io);
        if (zygote.pid == 0) continue;
        out[count] = zygote.pid;
        count += 1;
    }
    return count;
}

fn lookup(python: []const u8, runtime: []const u8) !*Zygote {
    const io = io_mod.getIo();
    registry_lock.lockUncancelable(io);
    defer registry_lock.unlock(io);
    for (registry.items) |zygote| {
        if (std.mem.eql(u8, zygote.python, python) and std.mem.eql(u8, zygote.runtime, runtime)) return zygote;
    }
    // Zygotes live for the process, so they use the process allocator.
    const gpa = std.heap.c_allocator;
    try registry.ensureUnusedCapacity(gpa, 1);
    const zygote = try gpa.create(Zygote);
    errdefer gpa.destroy(zygote);
    const owned_python = try gpa.dupe(u8, python);
    errdefer gpa.free(owned_python);
    zygote.* = .{ .python = owned_python, .runtime = try gpa.dupe(u8, runtime) };
    registry.appendAssumeCapacity(zygote);
    return zygote;
}

fn start(alloc: Allocator, zygote: *Zygote, env: *const std.process.Environ.Map) !void {
    const io = io_mod.getIo();
    const pair = try socketPair();
    const spawned = std.process.spawn(io, .{
        .argv = &.{ zygote.python, "-u", zygote.runtime, "--zygote" },
        .environ_map = env,
        .stdin = .{ .file = .{ .handle = pair[1], .flags = .{ .nonblocking = false } } },
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    // The zygote holds its own end now.
    closeFd(pair[1]);
    const child = spawned catch |err| {
        closeFd(pair[0]);
        return err;
    };
    // Only pipes need the Child's cleanup, and the zygote has none: it is
    // owned by pid from here on, and reaped by `stopLocked` or `reapIfExited`.
    zygote.pid = child.id.?;
    zygote.socket = pair[0];
    errdefer stopLocked(zygote);
    var buf: [256]u8 = undefined;
    const line = try readLine(zygote.socket, &buf, 15_000);
    const ready = try std.json.parseFromSlice(struct { ready: i64 }, alloc, line, .{ .ignore_unknown_fields = true });
    defer ready.deinit();
    if (ready.value.ready != protocol_version) return error.ZygoteProtocolMismatch;
    debug_trace.logf("kernel", "zygote started pid={d} python={s}", .{ zygote.pid, zygote.python });
}

fn request(alloc: Allocator, zygote: *Zygote, cwd: []const u8, env: *const std.process.Environ.Map) !Forked {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var jw: std.json.Stringify = .{ .writer = &body.writer };
    try jw.beginObject();
    try jw.objectField("cwd");
    try jw.write(cwd);
    try jw.objectField("env");
    try jw.beginObject();
    for (env.keys(), env.values()) |key, value| {
        try jw.objectField(key);
        try jw.write(value);
    }
    try jw.endObject();
    try jw.endObject();
    const payload = body.written();

    const stdin = try pipe();
    errdefer closeFd(stdin[1]);
    defer closeFd(stdin[0]);
    const stdout = try pipe();
    errdefer closeFd(stdout[0]);
    defer closeFd(stdout[1]);
    const stderr = try pipe();
    errdefer closeFd(stderr[0]);
    defer closeFd(stderr[1]);

    var header: [8]u8 = undefined;
    std.mem.writeInt(u64, &header, payload.len, .little);
    try sendWithFds(zygote.socket, &header, .{ stdin[0], stdout[1], stderr[1] });
    try writeAll(zygote.socket, payload);
    var buf: [256]u8 = undefined;
    const line = try readLine(zygote.socket, &buf, 10_000);
    const reply = try std.json.parseFromSlice(struct { pid: i64 = 0, @"error": ?[]const u8 = null }, alloc, line, .{ .ignore_unknown_fields = true });
    defer reply.deinit();
    if (reply.value.pid <= 0) return error.ZygoteForkFailed;
    return .{
        .pid = @intCast(reply.value.pid),
        .stdin = .{ .handle = stdin[1], .flags = .{ .nonblocking = false } },
        .stdout = .{ .handle = stdout[0], .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = stderr[0], .flags = .{ .nonblocking = false } },
    };
}

/// Caller holds the zygote's lock. Closing the socket makes the zygote exit;
/// the kill covers one that is stuck, and the wait reaps it.
fn stopLocked(zygote: *Zygote) void {
    if (zygote.socket >= 0) closeFd(zygote.socket);
    zygote.socket = -1;
    if (zygote.pid == 0) return;
    std.posix.kill(zygote.pid, .KILL) catch {};
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(zygote.pid, &status, 0);
        if (rc >= 0 or std.posix.errno(rc) != .INTR) break;
    }
    debug_trace.logf("kernel", "zygote stopped pid={d}", .{zygote.pid});
    zygote.pid = 0;
}

/// Caller holds the zygote's lock. A zygote that died, for example to kill -9,
/// is reaped here so the next request starts a replacement.
fn reapIfExited(zygote: *Zygote) void {
    if (zygote.pid == 0) return;
    var status: c_int = 0;
    if (std.c.waitpid(zygote.pid, &status, std.c.W.NOHANG) != zygote.pid) return;
    debug_trace.logf("kernel", "zygote pid={d} exited; replacing it", .{zygote.pid});
    zygote.pid = 0;
    if (zygote.socket >= 0) closeFd(zygote.socket);
    zygote.socket = -1;
}

fn socketPair() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    const cloexec: c_uint = if (builtin.target.os.tag == .linux) std.c.SOCK.CLOEXEC else 0;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | cloexec, 0, &fds) != 0) return error.ZygoteSocketFailed;
    for (fds) |fd| setCloexec(fd);
    return fds;
}

/// Both ends close on exec, so no other spawned process holds a kernel's pipe
/// open past the kernel's exit. The ends the zygote receives become the
/// kernel's fds 0-2 by dup2, which clears the flag there.
fn pipe() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (builtin.target.os.tag == .linux) {
        if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.KernelPipeSetupFailed;
    } else {
        if (std.c.pipe(&fds) != 0) return error.KernelPipeSetupFailed;
        for (fds) |fd| setCloexec(fd);
    }
    return fds;
}

fn setCloexec(fd: fd_t) void {
    _ = std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
}

fn closeFd(fd: fd_t) void {
    _ = std.c.close(fd);
}

fn sendWithFds(socket: fd_t, bytes: []const u8, fds: [3]fd_t) !void {
    const Control = extern struct { header: std.c.cmsghdr, fds: [3]c_int };
    var control: Control = undefined;
    @memset(std.mem.asBytes(&control), 0);
    control.header.len = @intCast(@offsetOf(Control, "fds") + @sizeOf([3]c_int));
    control.header.level = std.c.SOL.SOCKET;
    control.header.type = std.c.SCM.RIGHTS;
    control.fds = fds;
    const iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var message: std.c.msghdr_const = std.mem.zeroes(std.c.msghdr_const);
    message.iov = &iov;
    message.iovlen = 1;
    message.control = &control;
    message.controllen = @sizeOf(Control);
    while (true) {
        const rc = std.c.sendmsg(socket, &message, 0);
        if (rc == bytes.len) return;
        if (rc >= 0) return error.ZygoteShortWrite;
        if (std.posix.errno(rc) != .INTR) return error.ZygotePipeClosed;
    }
}

fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc > 0) {
            written += @intCast(rc);
        } else if (rc < 0 and std.posix.errno(rc) == .INTR) {
            continue;
        } else return error.ZygotePipeClosed;
    }
}

/// One reply line without its newline. The zygote writes nothing between replies.
fn readLine(fd: fd_t, buf: []u8, timeout_ms: i64) ![]const u8 {
    const deadline = now() + timeout_ms;
    var len: usize = 0;
    while (true) {
        const left = deadline - now();
        if (left <= 0) return error.ZygoteTimedOut;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(@min(left, 1000))) == 0) continue;
        if (len == buf.len) return error.ZygoteReplyTooLong;
        const rc = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (rc == 0) return error.ZygoteExited;
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR or std.posix.errno(rc) == .AGAIN) continue;
            return error.ZygoteExited;
        }
        len += @intCast(rc);
        if (std.mem.findScalar(u8, buf[0..len], '\n')) |end| return buf[0..end];
    }
}

test "a zygote request carries three descriptors and a length prefix" {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const pair = try socketPair();
    defer closeFd(pair[0]);
    defer closeFd(pair[1]);
    const a = try pipe();
    defer closeFd(a[0]);
    defer closeFd(a[1]);
    try sendWithFds(pair[0], "12345678", .{ a[0], a[1], a[0] });
    // The receiver gets the bytes and three fresh descriptors.
    var data: [8]u8 = undefined;
    const Control = extern struct { header: std.c.cmsghdr, fds: [3]c_int };
    var control: Control = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &data, .len = data.len }};
    var message: std.c.msghdr = std.mem.zeroes(std.c.msghdr);
    message.iov = &iov;
    message.iovlen = 1;
    message.control = &control;
    message.controllen = @sizeOf(Control);
    try std.testing.expectEqual(@as(isize, 8), std.c.recvmsg(pair[1], &message, 0));
    try std.testing.expectEqualStrings("12345678", &data);
    try std.testing.expectEqual(@as(c_int, std.c.SCM.RIGHTS), control.header.type);
    for (control.fds) |fd| {
        try std.testing.expect(fd > 2);
        closeFd(fd);
    }
    try std.testing.expect(memory.startToken(std.c.getpid()) != null);
}

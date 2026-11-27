//! The `fx mcp call` bridge: the shell around the pure core in
//! `mcp_call.zig`. A command that fx's shell tool runs can call the
//! session's MCP tools through it, so a large result can go to a file
//! instead of into the model's context.
//!
//! Each command the shell tool runs registers as an owner with its own token
//! for as long as it runs. The shell call that follows the command lends the
//! bridge its permission check and MCP call
//! (`../tooling/mcp_call_capability.zig`), so a call meets the same rules,
//! prompt, review, and access as a direct one by the same agent: first the
//! call that started the command, then each `interact` on its session. A
//! command can outlive the call that started it, when that call yields or
//! steering arrives, and its requests then wait before admission for the next
//! call that follows it. The bridge listens on one Unix socket in a private
//! directory while any command is registered, and closes it after the last one
//! ends.
//!
//! The core decides everything: admission, the order of the permission
//! check and the call, one call and one reply per request, and what to let
//! go and log when a client or owner leaves. This file only runs its
//! effects and reports their results as events, under one mutex, so the
//! core has one writer. `tests/tla/mcp_call/` checks the core against its
//! model.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const command_runner = @import("../execution/command_runner.zig");
const capability_mod = @import("../tooling/mcp_call_capability.zig");
const mcp_call = @import("mcp_call.zig");
const wire = @import("mcp_call_wire.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;

/// Bridge state lives for the process, so it uses the process allocator.
pub const supported = capability_mod.supported;

const gpa = std.heap.c_allocator;
/// Connections served at once; more are closed unread.
const max_connections = 64;
const poll_ms = 100;
/// The longest a wait on a wake pipe sleeps when no wake byte comes. A stop or
/// a request's end always writes one, so this bounds only a wake that is lost.
const wake_safety_poll_ms = 1000;
/// How long a client may take to send its request line.
const request_deadline_ms: i64 = 10_000;

/// A test's follow-wait limit in milliseconds, or 0 for none. Atomic, because
/// serving tasks read it while the test sets it.
var test_follow_wait_ms: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {};
/// While set, a waiting request that wakes holds before it checks again, so a
/// test can make a follower return first, as a zero-wait `interact` can.
var test_hold_recheck: if (builtin.is_test) std.atomic.Value(bool) else void = if (builtin.is_test) .init(false) else {};

fn followWaitMs() u32 {
    if (builtin.is_test) {
        const ms = test_follow_wait_ms.load(.acquire);
        if (ms > 0) return ms;
    }
    return parseFollowWaitMs(io_mod.getenv("FX_TEST_MCP_CALL_FOLLOW_WAIT_MS"));
}

/// The follow-wait limit `text` names in milliseconds, or `mcp_call.follow_wait_ms`
/// when it is absent, not a number, or not a positive one that fits.
fn parseFollowWaitMs(text: ?[]const u8) u32 {
    const value = text orelse return mcp_call.follow_wait_ms;
    const ms = std.fmt.parseInt(u32, value, 10) catch return mcp_call.follow_wait_ms;
    return if (ms > 0) ms else mcp_call.follow_wait_ms;
}

/// One running command, registered as an owner. It ends when the command
/// has ended and no shell call follows it (`finishLocked`).
pub const Registration = struct {
    owner: mcp_call.OwnerId,
    /// The agent whose command registered this owner (`Capability.agent`).
    agent: u64,
    /// What the shell call that follows the command lends, or null while
    /// none does. Guarded by the bridge mutex.
    capability: ?capability_mod.Capability,
    /// Whether a shell call follows the command: from `register` or
    /// `follow` until `unfollow`. Guarded by the bridge mutex.
    followed: bool = true,
    /// Whether the command still runs, until `commandEnded`. Guarded by the
    /// bridge mutex.
    command_running: bool = true,
    /// The owner's requests the bridge is working on. While above zero the
    /// shell call that follows the command does not yield
    /// (`managed_execution` `yield_hold`).
    hold: std.atomic.Value(u32) = .init(0),
    /// Requests whose work borrows `capability`. Guarded by the bridge mutex.
    in_use: u32 = 0,
    /// The command sent a request that the bridge admitted. Guarded by the
    /// bridge mutex.
    called: bool = false,
    /// The owner's requests in the follow wait (`admit`). The registration
    /// stays until they leave it. Guarded by the bridge mutex.
    waiters: u32 = 0,
    /// How many times a shell call has followed the command. Guarded by the
    /// bridge mutex.
    follows: u64 = 0,
    /// Waiting requests the latest `follow` woke that have not checked again.
    /// That follower's `unfollow` waits for them. Guarded by the bridge mutex.
    rechecks_due: u32 = 0,
    token_hex: [wire.token_hex_len]u8,
    variables: [2]command_runner.EnvironmentVariable = undefined,

    /// The variables a command needs to reach the bridge as this owner.
    /// Valid while the command runs or a shell call follows it.
    pub fn environment(self: *const Registration) []const command_runner.EnvironmentVariable {
        return &self.variables;
    }
};

/// A request being served, so a `cancel` effect can reach its call.
const Live = struct {
    id: mcp_call.RequestId,
    cancel: std.atomic.Value(bool) = .init(false),
};

const Phase = enum { idle, running, stopping };

const Bridge = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    /// One permission prompt at a time: an agent's worker shows one.
    prompt: std.Io.Mutex = .init,
    state: mcp_call.State = .init(mcp_call.default_capacity),
    phase: Phase = .idle,
    dir_path: ?[]u8 = null,
    socket_path: ?[]u8 = null,
    listener: ?std.Io.net.Server = null,
    /// The accept loop, awaited when the bridge stops.
    accept_task: ?std.Io.Future(void) = null,
    /// One task per open connection, cancelled and awaited when the bridge
    /// stops. Only the accept loop adds to it.
    connection_tasks: std.Io.Group = .init,
    stop: std.atomic.Value(bool) = .init(false),
    registrations: std.ArrayList(*Registration) = .empty,
    live: std.ArrayList(*Live) = .empty,
    next_owner: u32 = 1,
    connections: u32 = 0,
    /// The pipe that ends the accept loop's wait: read end, then write end.
    /// It lives as long as the listener, and `closeListenerLocked` closes it.
    wake: ?[2]posix.fd_t = null,
    /// Passes of the accept loop's wait in this run. A test waits for one.
    accept_waits: u32 = 0,
    /// Passes of a request-line wait in this run. A test waits for one.
    request_polls: u32 = 0,
    /// Requests that entered a pre-admission follow wait in this run. A test waits for one.
    waiting_follows: u32 = 0,
};

var bridge: Bridge = .{};

/// Registers a command a shell call is about to start, starting the bridge
/// if this is the first, with that call as its follower. The caller must
/// `unfollow` before `capability` goes away, and `commandEnded` must follow
/// the command's end (`managed_execution` `EndNotice`).
pub fn register(capability: capability_mod.Capability) !*Registration {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    while (bridge.phase == .stopping) bridge.changed.waitUncancelable(io, &bridge.mutex);
    if (bridge.phase == .idle) try startLocked(io);
    // The core holds the bridge's own registration and its owners.
    if (bridge.registrations.items.len + 1 >= mcp_call.max_owners) return error.McpCallBridgeFull;
    try bridge.registrations.ensureUnusedCapacity(gpa, 1);
    const registration = try gpa.create(Registration);
    var token: mcp_call.Token = undefined;
    io.random(&token);
    registration.* = .{
        .owner = nextOwnerLocked(),
        .agent = capability.agent,
        .capability = capability,
        .token_hex = wire.tokenHex(token),
    };
    registration.variables = .{
        .{ .name = wire.socket_env, .value = bridge.socket_path.? },
        .{ .name = wire.token_env, .value = &registration.token_hex },
    };
    bridge.registrations.appendAssumeCapacity(registration);
    _ = step(.{ .owner_added = .{ .owner = registration.owner, .token = token } });
    _ = step(.{ .owner_followed = registration.owner });
    return registration;
}

/// The id `follow` and `commandEnded` take for `registration`'s command.
pub fn commandId(registration: *const Registration) u64 {
    return @backingInt(registration.owner);
}

/// Lends `capability` to the command `id` names while a later shell call,
/// an `interact` on its session, follows it. Returns null when the command
/// has ended, is not registered, another call follows it, or `capability`
/// belongs to another agent. The caller must `unfollow` the registration it
/// returns before `capability` goes away.
pub fn follow(id: u64, capability: capability_mod.Capability) ?*Registration {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    const registration = findLocked(id) orelse return null;
    if (registration.followed or !registration.command_running) return null;
    if (capability.agent != registration.agent) {
        debug_trace.logf("mcp-call", "a shell call of another agent does not follow this command owner={d} owner_agent={d} caller_agent={d}", .{ id, registration.agent, capability.agent });
        return null;
    }
    std.debug.assert(registration.in_use == 0);
    registration.followed = true;
    registration.capability = capability;
    registration.follows +%= 1;
    registration.rechecks_due = registration.waiters;
    _ = step(.{ .owner_followed = registration.owner });
    bridge.changed.broadcast(io);
    return registration;
}

/// How a shell call that follows a command ends.
pub const FollowEnd = enum {
    /// It returned: its wait ended, or the command ended.
    returned,
    /// Its turn was cancelled, so the call it lends stops too.
    cancelled,
};

/// Ends a shell call's following of its command. A follower that returns
/// first lets the requests its `follow` woke check again, so a zero-wait
/// `interact` still runs them. When the command still runs, its token stays
/// valid and this returns once no request borrows the call's capability. When
/// the command has ended, this finishes the registration.
pub fn unfollow(registration: *Registration, end: FollowEnd) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    switch (end) {
        .returned => while (registration.rechecks_due > 0) {
            if (builtin.is_test) {
                test_hold_recheck.store(false, .release);
                bridge.changed.broadcast(io);
            }
            bridge.changed.waitUncancelable(io, &bridge.mutex);
        },
        .cancelled => registration.rechecks_due = 0,
    }
    _ = step(.{ .owner_unfollowed = .{ .owner = registration.owner, .cancel = end == .cancelled } });
    while (registration.in_use > 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
    registration.capability = null;
    registration.followed = false;
    if (registration.command_running) {
        bridge.mutex.unlock(io);
        return;
    }
    finishLocked(io, registration);
}

/// Records that the command `id` names has ended: revokes its token, frees the
/// registration once no shell call follows it, and stops the bridge after the
/// last one. A duplicate call or one for a gone registration does nothing.
pub fn commandEnded(id: u64) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    const registration = findLocked(id) orelse {
        bridge.mutex.unlock(io);
        return;
    };
    if (!registration.command_running) {
        bridge.mutex.unlock(io);
        return;
    }
    registration.command_running = false;
    _ = step(.{ .owner_removed = registration.owner });
    bridge.changed.broadcast(io);
    if (registration.followed) {
        // A follower's `unfollow` drains any borrowed work and calls `finishLocked`.
        bridge.mutex.unlock(io);
        return;
    }
    finishLocked(io, registration);
}

fn findLocked(id: u64) ?*Registration {
    for (bridge.registrations.items) |registration| {
        if (commandId(registration) == id) return registration;
    }
    return null;
}

/// Ends a registration once its command has ended and no shell call follows it.
/// Its waiting requests leave first: the core now refuses them as unauthorized.
/// Called with `bridge.mutex` held, which it releases.
fn finishLocked(io: std.Io, registration: *Registration) void {
    while (registration.in_use > 0 or registration.waiters > 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
    for (bridge.registrations.items, 0..) |item, index| {
        if (item == registration) {
            _ = bridge.registrations.swapRemove(index);
            break;
        }
    }
    const last = bridge.registrations.items.len == 0;
    var accept_task: ?std.Io.Future(void) = null;
    if (last) {
        _ = step(.stopped);
        bridge.phase = .stopping;
        bridge.stop.store(true, .release);
        if (bridge.wake) |wake| writeWakeByte(wake[1]);
        bridge.changed.broadcast(io);
        accept_task = bridge.accept_task;
        bridge.accept_task = null;
    }
    bridge.mutex.unlock(io);
    gpa.destroy(registration);
    if (!last) return;
    // The wake byte ends the accept loop's wait at once; after it ends nothing adds
    // a connection. No owner is left, so the connections still open are
    // unadmitted ones; cancelling ends their wait for a request line.
    if (accept_task) |*task| task.await(io);
    bridge.connection_tasks.cancel(io);
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    closeListenerLocked(io);
    bridge.stop.store(false, .release);
    bridge.phase = .idle;
    bridge.changed.broadcast(io);
}

/// Whether the command of `registration` has sent a request that the
/// bridge admitted. Valid while a shell call follows `registration`.
pub fn commandCalled(registration: *Registration) bool {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    return registration.called;
}

fn nextOwnerLocked() mcp_call.OwnerId {
    while (true) {
        const candidate = bridge.next_owner;
        bridge.next_owner +%= 1;
        if (candidate == 0) continue;
        const owner: mcp_call.OwnerId = @fromBackingInt(candidate);
        for (bridge.registrations.items) |registration| {
            if (registration.owner == owner) break;
        } else return owner;
    }
}

fn startLocked(io: std.Io) !void {
    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const hex = std.fmt.bytesToHex(suffix, .lower);
    const tmp = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
    // A Unix socket path is at most 104 bytes on macOS.
    const base = if (tmp.len + 40 < 100) tmp else "/tmp";
    const dir_path = try gpa.print("{s}/fx-mcp-{s}", .{ base, &hex });
    errdefer gpa.free(dir_path);
    const socket_path = try gpa.print("{s}/s", .{dir_path});
    errdefer gpa.free(socket_path);
    try std.Io.Dir.cwd().createDir(io, dir_path, .fromMode(0o700));
    errdefer std.Io.Dir.cwd().deleteDir(io, dir_path) catch {};
    const address = try std.Io.net.UnixAddress.init(socket_path);
    // Ignored: listen may fail before the file exists, and the start already fails with its own error.
    errdefer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    var listener = try address.listen(io, .{});
    errdefer listener.deinit(io);
    // Errdefers run in reverse: the listener closes, then the socket file goes, then the directory, which needs to be empty.
    // Close-on-exec, so the commands fx starts do not inherit the wake pipe.
    const wake = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer closeWake(wake);
    bridge.listener = listener;
    bridge.wake = wake;
    bridge.accept_waits = 0;
    bridge.request_polls = 0;
    bridge.waiting_follows = 0;
    bridge.stop.store(false, .release);
    bridge.accept_task = std.Io.concurrent(io, acceptLoop, .{}) catch |err| {
        bridge.listener = null;
        bridge.wake = null;
        return err;
    };
    bridge.dir_path = dir_path;
    bridge.socket_path = socket_path;
    var main_token: mcp_call.Token = undefined;
    io.random(&main_token);
    // The bridge's own registration: no command ever receives this token.
    _ = step(.{ .started = main_token });
    bridge.phase = .running;
    debug_trace.logf("mcp-call", "bridge listening socket={s}", .{socket_path});
}

/// Writes the byte that ends a wait on a wake pipe. Each pipe gets one byte, so
/// it never fills and the write does not block. A failed write leaves the wait
/// to its safety poll, so it is only logged, with the errno name.
fn writeWakeByte(write_end: posix.fd_t) void {
    const byte = [1]u8{0};
    const rc = std.c.write(write_end, &byte, 1);
    if (rc == 1) return;
    const reason = if (rc < 0) @tagName(std.posix.errno(rc)) else "short write";
    debug_trace.logf("mcp-call", "bridge wake not written err={s}; the wait ends at its safety poll", .{reason});
}

fn closeWake(wake: [2]posix.fd_t) void {
    _ = std.c.close(wake[0]);
    _ = std.c.close(wake[1]);
}

fn closeListenerLocked(io: std.Io) void {
    if (bridge.listener) |*listener| listener.deinit(io);
    bridge.listener = null;
    if (bridge.wake) |wake| closeWake(wake);
    bridge.wake = null;
    if (bridge.socket_path) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| debug_trace.logf("mcp-call", "bridge socket not removed err={s}", .{@errorName(err)});
        gpa.free(path);
    }
    if (bridge.dir_path) |path| {
        std.Io.Dir.cwd().deleteDir(io, path) catch |err| debug_trace.logf("mcp-call", "bridge directory not removed err={s}", .{@errorName(err)});
        gpa.free(path);
    }
    bridge.socket_path = null;
    bridge.dir_path = null;
    debug_trace.logf("mcp-call", "bridge closed", .{});
}

/// Takes the core's new state and runs the effects that are not the
/// serving task's own: cancels, withdrawals, and logs. `event` names the core
/// event that led to them.
fn applyLocked(out: mcp_call.Output, event: []const u8) void {
    bridge.state = out.state;
    for (out.effects()) |effect| switch (effect) {
        .cancel => |id| {
            debug_trace.logf("mcp-call", "request={d} running call cancelled after {s}; its result is dropped", .{ @backingInt(id), event });
            for (bridge.live.items) |live| {
                if (live.id == id) live.cancel.store(true, .release);
            }
            // Wakes what waits on the bridge for a cancel, such as the test fake's long call.
            bridge.changed.broadcast(io_mod.getIo());
        },
        .withdraw => |id| debug_trace.logf("mcp-call", "request={d} client or owner gone; its permission prompt stays until answered, and nothing runs", .{@backingInt(id)}),
        .log => |log| debug_trace.logf("mcp-call", "request={d} dropped={s}", .{ @backingInt(log.id), @tagName(log.drop) }),
        .refuse, .authorize, .call, .reply => {},
    };
}

fn step(event: mcp_call.Event) mcp_call.Output {
    const out = mcp_call.step(bridge.state, event);
    applyLocked(out, @tagName(event));
    return out;
}

fn acceptLoop() void {
    const io = io_mod.getIo();
    const listener = &bridge.listener.?;
    const wake_read = bridge.wake.?[0];
    while (!bridge.stop.load(.acquire)) {
        bridge.mutex.lockUncancelable(io);
        bridge.accept_waits += 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
        var fds = [_]posix.pollfd{
            .{ .fd = listener.socket.handle, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = wake_read, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, wake_safety_poll_ms) catch |err| {
            debug_trace.logf("mcp-call", "bridge accept loop ended err={s}", .{@errorName(err)});
            return;
        };
        if (fds[1].revents != 0) {
            if (fds[0].revents != 0) debug_trace.logf("mcp-call", "bridge accept loop ends on stop; a connection that arrived with the stop is not accepted", .{});
            return;
        }
        if (ready == 0) continue;
        const stream = listener.accept(io) catch |err| {
            debug_trace.logf("mcp-call", "bridge accept failed err={s}", .{@errorName(err)});
            continue;
        };
        bridge.mutex.lockUncancelable(io);
        const room = bridge.connections < max_connections;
        if (room) bridge.connections += 1;
        bridge.mutex.unlock(io);
        if (!room) {
            debug_trace.logf("mcp-call", "bridge connection dropped: {d} already open", .{max_connections});
            stream.close(io);
            continue;
        }
        bridge.connection_tasks.concurrent(io, serve, .{ stream, wake_read }) catch |err| {
            debug_trace.logf("mcp-call", "bridge connection dropped: no task err={s}", .{@errorName(err)});
            finishConnection(io, stream);
            continue;
        };
    }
}

fn finishConnection(io: std.Io, stream: std.Io.net.Stream) void {
    stream.close(io);
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    bridge.connections -= 1;
    bridge.changed.broadcast(io);
}

const ReadError = error{ TooLarge, Silent, Closed, ReadFailed, OutOfMemory, Canceled };

/// Reads one request line within the deadline, without its newline. Ends
/// with `error.Canceled` when the bridge stops first: the wake byte that
/// `finishLocked` writes ends the wait at once.
fn readRequestLine(arena: Allocator, fd: posix.socket_t, wake_read: posix.fd_t) ReadError![]const u8 {
    const io = io_mod.getIo();
    var line: std.ArrayList(u8) = .empty;
    const deadline = io_mod.milliTimestamp() + request_deadline_ms;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        try io.checkCancel();
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.Silent;
        bridge.mutex.lockUncancelable(io);
        bridge.request_polls += 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
        var fds = [_]posix.pollfd{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = wake_read, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, @intCast(@min(remaining, wake_safety_poll_ms))) catch return error.ReadFailed;
        if (fds[1].revents != 0) return error.Canceled;
        if (ready == 0 or fds[0].revents == 0) continue;
        const rc = std.c.recv(fd, &chunk, chunk.len, 0);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR or posix.errno(rc) == .AGAIN) continue;
            return error.ReadFailed;
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.Closed;
        if (std.mem.findScalar(u8, chunk[0..n], '\n')) |end| {
            if (line.items.len + end > wire.max_request_bytes) return error.TooLarge;
            try line.appendSlice(arena, chunk[0..end]);
            return line.items;
        }
        if (line.items.len + n > wire.max_request_bytes) return error.TooLarge;
        try line.appendSlice(arena, chunk[0..n]);
    }
}

/// Writes one reply. Returns whether the client got all of it.
fn writeReply(stream: std.Io.net.Stream, status: wire.Status, reason: ?wire.Reason, bytes: []const u8) bool {
    const io = io_mod.getIo();
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    wire.writeHeader(&writer.interface, .{ .status = status, .reason = reason, .bytes = bytes.len }) catch return false;
    writer.interface.writeAll(bytes) catch return false;
    writer.interface.flush() catch return false;
    return true;
}

fn refusalMessage(reason: wire.Reason) []const u8 {
    return switch (reason) {
        .closed => "The fx session that started this command has ended.",
        .unauthorized => "This command was not started by fx's shell tool, or it has ended.",
        .unsupported_version => "This fx mcp call is from another fx version than the running session. Run the fx that started the session, or restart the session with this one.",
        .busy => "Too many fx mcp call requests are running in this session. Nothing ran; try again when one finishes.",
        .malformed => "The request was not an fx mcp call request. Send requests with the fx that started the session.",
        .too_large => "The request is over 1 MiB. Pass smaller arguments.",
    };
}

/// What a client the core refused is told. A request that no shell call
/// followed in time goes out as `unauthorized` (`wire.Reason.fromRefusal`),
/// so its words come from here.
fn refusalText(refusal: mcp_call.Refusal) []const u8 {
    return switch (refusal) {
        .not_followed => "This call did not run, because no fx shell call checked on its command for 2 minutes. Check on the command with shell interact, then run the call again.",
        else => refusalMessage(wire.Reason.fromRefusal(refusal)),
    };
}

/// What a client socket shows after a poll.
const Peek = union(enum) {
    /// The client closed or reset its end.
    gone,
    /// Nothing to read.
    quiet,
    /// The client sent bytes after its request line.
    bytes,
    /// The peek itself failed.
    failed: posix.E,
};

/// Peeks at client socket `fd`, given the events a poll reported on it.
fn peekClient(fd: posix.socket_t, revents: i16) Peek {
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) return .gone;
    if ((revents & posix.POLL.IN) == 0) return .quiet;
    var probe: [1]u8 = undefined;
    const rc = std.c.recv(fd, &probe, 1, posix.MSG.PEEK | posix.MSG.DONTWAIT);
    if (rc == 0) return .gone;
    if (rc < 0) {
        const err = posix.errno(rc);
        return if (err == .AGAIN or err == .INTR) .quiet else .{ .failed = err };
    }
    return .bytes;
}

/// Whether a waiting request's client has left, so the request ends without
/// a reply. A poll or peek that fails ends it too. Logs which happened.
fn waitingClientGone(fd: posix.socket_t) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, 0) catch |err| {
        debug_trace.logf("mcp-call", "waiting request dropped: its client could not be polled err={s}", .{@errorName(err)});
        return true;
    };
    if (ready == 0) return false;
    switch (peekClient(fd, fds[0].revents)) {
        .quiet, .bytes => return false,
        .gone => {
            debug_trace.logf("mcp-call", "waiting request dropped: its client disconnected before a shell call followed", .{});
            return true;
        },
        .failed => |err| {
            debug_trace.logf("mcp-call", "waiting request dropped: its client could not be peeked err={s}", .{@tagName(err)});
            return true;
        },
    }
}

fn ownerIdForTokenLocked(token: mcp_call.Token) u32 {
    for (bridge.state.owners) |slot| {
        const owner = slot orelse continue;
        if (std.crypto.timing_safe.eql(mcp_call.Token, owner.token, token)) return @backingInt(owner.id);
    }
    return 0;
}

/// Watches a served connection and reports its client leaving.
const Watch = struct {
    fd: posix.socket_t,
    id: mcp_call.RequestId,
    /// The pipe that ends `run`: read end, then write end. `serve` closes it.
    wake: [2]posix.fd_t,
    done: std.atomic.Value(bool) = .init(false),
    /// Set once the watch has logged why it cannot watch its client: bytes sent after the request line, or a failed peek. Each watch logs one such line.
    extra_logged: bool = false,

    fn run(self: *Watch) void {
        const io = io_mod.getIo();
        while (!self.done.load(.acquire)) {
            var fds = [_]posix.pollfd{
                .{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake[0], .events = posix.POLL.IN, .revents = 0 },
            };
            const ready = posix.poll(&fds, wake_safety_poll_ms) catch |err| {
                debug_trace.logf("mcp-call", "request={d} disconnect watch ended: poll failed err={s}", .{ @backingInt(self.id), @errorName(err) });
                return;
            };
            if (fds[1].revents != 0) return;
            if (ready == 0) continue;
            const seen = peekClient(self.fd, fds[0].revents);
            if (seen == .gone) {
                bridge.mutex.lockUncancelable(io);
                _ = step(.{ .client_gone = self.id });
                bridge.mutex.unlock(io);
                return;
            }
            // The client sent more than its one line: not ours to read. Log it once,
            // then wait on the wake byte alone, so the unread bytes do not spin this loop.
            if (!self.extra_logged and seen != .quiet) {
                self.extra_logged = true;
                switch (seen) {
                    .failed => |err| debug_trace.logf("mcp-call", "request={d} disconnect watch could not peek the client err={s}; it checks again every 100 ms", .{ @backingInt(self.id), @tagName(err) }),
                    else => debug_trace.logf("mcp-call", "request={d} client sent bytes after its request line; the watch leaves them unread", .{@backingInt(self.id)}),
                }
            }
            var wake_only = [_]posix.pollfd{.{ .fd = self.wake[0], .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&wake_only, poll_ms) catch |err| {
                debug_trace.logf("mcp-call", "request={d} disconnect watch ended: poll failed err={s}", .{ @backingInt(self.id), @errorName(err) });
                return;
            };
            if (wake_only[0].revents != 0) return;
        }
    }
};

/// A request the core admitted. `admit` returns it with `bridge.mutex` held
/// and room for its entry in `bridge.live`.
const Admitted = struct {
    work: mcp_call.Work,
    registration: *Registration,
};

/// A request in the follow wait, counted on its command's registration, so a
/// follower that returns at once still lets it check again (`unfollow`).
const Waiting = struct {
    registration: ?*Registration,
    started_ms: i64,
    /// The registration's `follows` when this request last checked.
    seen_follows: u64,
};

/// Admits `request`, and while no shell call follows its command, waits before
/// admission up to the follow-wait limit. Returns with `bridge.mutex` held when
/// the core admits the request. Otherwise it answers the client when one is
/// owed, releases the mutex, and returns null.
fn admit(io: std.Io, stream: std.Io.net.Stream, request: wire.Request) ?Admitted {
    const token: mcp_call.Token = request.token orelse @splat(0);
    const limit_ms = followWaitMs();
    var waiting: ?Waiting = null;
    bridge.mutex.lockUncancelable(io);
    while (true) {
        // Room for the request's entry, taken in the same lock hold as its
        // admission, so a request served while this one waited cannot take it.
        bridge.live.ensureUnusedCapacity(gpa, 1) catch {
            leaveWaitLocked(io, &waiting);
            bridge.mutex.unlock(io);
            debug_trace.logf("mcp-call", "bridge request dropped op={s}: no memory for its entry", .{@tagName(request.operation)});
            _ = writeReply(stream, .failed, null, "fx could not take this request: out of memory.");
            return null;
        };
        if (waiting) |*current| {
            if (waitingClientGone(stream.socket.handle)) {
                leaveWaitLocked(io, &waiting);
                bridge.mutex.unlock(io);
                return null;
            }
            noteRecheckLocked(io, current);
        }
        const out = step(.{ .request = .{ .token = token, .version = request.version } });
        const outcome: union(enum) { authorized: mcp_call.Work, refused: mcp_call.Refusal, none } = for (out.effects()) |effect| switch (effect) {
            .authorize => |value| break .{ .authorized = value },
            .refuse => |refusal| break .{ .refused = refusal },
            else => {},
        } else .none;
        switch (outcome) {
            .authorized => |work| {
                leaveWaitLocked(io, &waiting);
                const registration = for (bridge.registrations.items) |item| {
                    if (item.owner == work.owner) break item;
                } else unreachable; // the core admits only registered owners
                return .{ .work = work, .registration = registration };
            },
            .refused => |refusal| {
                if (refusal != .not_followed) {
                    leaveWaitLocked(io, &waiting);
                    bridge.mutex.unlock(io);
                    refuse(stream, request.operation, refusal);
                    return null;
                }
                if (waiting == null) {
                    waiting = startWaitLocked(io, token);
                    if (waitingClientGone(stream.socket.handle)) {
                        leaveWaitLocked(io, &waiting);
                        bridge.mutex.unlock(io);
                        return null;
                    }
                }
                const elapsed_ms = io_mod.awakeMilliTimestamp() - waiting.?.started_ms;
                if (mcp_call.followWaitOver(elapsed_ms, limit_ms)) {
                    leaveWaitLocked(io, &waiting);
                    bridge.mutex.unlock(io);
                    refuse(stream, request.operation, .not_followed);
                    return null;
                }
                const slice_ms: i64 = @max(1, @min(@as(i64, limit_ms) - elapsed_ms, poll_ms));
                bridge.changed.waitTimeout(io, &bridge.mutex, .{ .duration = .{ .raw = .fromMilliseconds(slice_ms), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => {
                        leaveWaitLocked(io, &waiting);
                        bridge.mutex.unlock(io);
                        debug_trace.logf("mcp-call", "waiting request dropped op={s}: the bridge stopped", .{@tagName(request.operation)});
                        return null;
                    },
                };
                if (builtin.is_test) {
                    while (test_hold_recheck.load(.acquire)) {
                        bridge.changed.waitTimeout(io, &bridge.mutex, .{ .duration = .{ .raw = .fromMilliseconds(poll_ms), .clock = .awake } }) catch break;
                    }
                }
            },
            .none => {
                leaveWaitLocked(io, &waiting);
                bridge.mutex.unlock(io);
                debug_trace.logf("mcp-call", "bridge request dropped op={s}: the core neither admitted nor refused it", .{@tagName(request.operation)});
                return null;
            },
        }
    }
}

/// Starts a request's follow wait. Called with `bridge.mutex` held.
fn startWaitLocked(io: std.Io, token: mcp_call.Token) Waiting {
    const owner_id = ownerIdForTokenLocked(token);
    const registration = for (bridge.registrations.items) |item| {
        if (@backingInt(item.owner) == owner_id) break item;
    } else null;
    if (registration) |item| item.waiters += 1;
    debug_trace.logf("mcp-call", "request waits for a shell call to follow its command owner={d}", .{owner_id});
    bridge.waiting_follows += 1;
    bridge.changed.broadcast(io);
    return .{
        .registration = registration,
        .started_ms = io_mod.awakeMilliTimestamp(),
        .seen_follows = if (registration) |item| item.follows else 0,
    };
}

/// Records that a waiting request checks again after a follow woke it, so the
/// follower's `unfollow` can go on. Called with `bridge.mutex` held.
fn noteRecheckLocked(io: std.Io, current: *Waiting) void {
    const registration = current.registration orelse return;
    if (registration.follows == current.seen_follows) return;
    current.seen_follows = registration.follows;
    registration.rechecks_due -|= 1;
    bridge.changed.broadcast(io);
}

/// Ends a request's follow wait, if it has one. Called with `bridge.mutex` held.
fn leaveWaitLocked(io: std.Io, waiting: *?Waiting) void {
    if (waiting.*) |*current| {
        noteRecheckLocked(io, current);
        if (current.registration) |registration| registration.waiters -= 1;
        bridge.changed.broadcast(io);
    }
    waiting.* = null;
}

/// Answers a request the core refused, and logs why.
fn refuse(stream: std.Io.net.Stream, operation: wire.Operation, refusal: mcp_call.Refusal) void {
    debug_trace.logf("mcp-call", "bridge refused op={s} reason={s}", .{ @tagName(operation), @tagName(refusal) });
    _ = writeReply(stream, .refused, wire.Reason.fromRefusal(refusal), refusalText(refusal));
}

// finishLocked awaits this task before closeListenerLocked closes wake_read.
fn serve(stream: std.Io.net.Stream, wake_read: posix.fd_t) void {
    const io = io_mod.getIo();
    defer finishConnection(io, stream);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = readRequestLine(arena, stream.socket.handle, wake_read) catch |err| {
        debug_trace.logf("mcp-call", "bridge request not read err={s}", .{@errorName(err)});
        if (err == error.TooLarge) _ = writeReply(stream, .refused, .too_large, refusalMessage(.too_large));
        if (err == error.Silent) _ = writeReply(stream, .refused, .malformed, refusalMessage(.malformed));
        return;
    };
    const request = wire.parseRequest(arena, line) catch |err| {
        debug_trace.logf("mcp-call", "bridge request malformed err={s}", .{@errorName(err)});
        _ = writeReply(stream, .refused, .malformed, refusalMessage(.malformed));
        return;
    };

    const admitted = admit(io, stream, request) orelse return;
    const registration = admitted.registration;
    const work = admitted.work;
    const capability = registration.capability.?;
    var live: Live = .{ .id = work.id };
    bridge.live.appendAssumeCapacity(&live);
    registration.in_use += 1;
    registration.called = true;
    _ = registration.hold.fetchAdd(1, .acq_rel);
    bridge.mutex.unlock(io);
    defer {
        bridge.mutex.lockUncancelable(io);
        for (bridge.live.items, 0..) |item, index| {
            if (item == &live) {
                _ = bridge.live.swapRemove(index);
                break;
            }
        }
        _ = registration.hold.fetchSub(1, .acq_rel);
        registration.in_use -= 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
    }

    var watch: Watch = .{ .fd = stream.socket.handle, .id = work.id, .wake = undefined };
    var watcher: ?std.Io.Future(void) = null;
    if (std.Io.Threaded.pipe2(.{ .CLOEXEC = true })) |wake| {
        watch.wake = wake;
        watcher = std.Io.concurrent(io, Watch.run, .{&watch}) catch |err| blk: {
            debug_trace.logf("mcp-call", "request={d} runs without a disconnect watch err={s}", .{ @backingInt(work.id), @errorName(err) });
            closeWake(wake);
            break :blk null;
        };
    } else |err| {
        debug_trace.logf("mcp-call", "request={d} runs without a disconnect watch: no wake pipe err={s}", .{ @backingInt(work.id), @errorName(err) });
    }
    defer if (watcher) |*task| {
        watch.done.store(true, .release);
        writeWakeByte(watch.wake[1]);
        task.await(io);
        closeWake(watch.wake);
    };

    const request_id = arena.print("fx-mcp-call-{d}", .{@backingInt(work.id)}) catch "fx-mcp-call";
    // A lookup reads tool metadata only, like the agent's own toolbox
    // search, so it has no permission check to wait for.
    const authorization: capability_mod.Authorization = switch (request.operation) {
        .call => |value| blk: {
            bridge.prompt.lockUncancelable(io);
            defer bridge.prompt.unlock(io);
            break :blk capability.authorize(arena, request_id, value.tool, value.arguments_json) catch |err|
                .{ .deny = arena.print("The permission check for {f} failed: {s}", .{ text_utils.terminalSafe(value.tool), @errorName(err) }) catch "The permission check failed." };
        },
        .list, .search, .help => .{ .allow = .{} },
    };
    bridge.mutex.lockUncancelable(io);
    const decided = step(.{ .authorized = .{ .id = work.id, .decision = if (authorization == .allow) .allow else .deny } });
    bridge.mutex.unlock(io);

    var reply: ?struct { status: wire.Status, bytes: []const u8 } = null;
    for (decided.effects()) |effect| switch (effect) {
        .call => {
            const outcome = runOperation(arena, capability, request_id, request.operation, authorization.allow, &live.cancel) catch |err|
                capability_mod.CallOutcome{ .status = .failed, .bytes = arena.print("The MCP call failed: {s}", .{@errorName(err)}) catch "The MCP call failed." };
            bridge.mutex.lockUncancelable(io);
            const finished = step(.{ .call_finished = .{ .id = work.id, .outcome = switch (outcome.status) {
                .ok => .ok,
                .tool_error => .tool_error,
                .failed => .failed,
            } } });
            bridge.mutex.unlock(io);
            for (finished.effects()) |done| switch (done) {
                .reply => |value| reply = .{ .status = switch (value.outcome) {
                    .ok => .ok,
                    .tool_error => .tool_error,
                    .failed => .failed,
                    .denied => .denied,
                }, .bytes = outcome.bytes },
                else => {},
            };
            // The core logs a dropped result unless the call failed, as a
            // cancelled call does, so that drop is logged here.
            if (reply == null and outcome.status == .failed) debug_trace.logf("mcp-call", "request={d} failed result dropped: its client, command, follower, or session ended first", .{@backingInt(work.id)});
        },
        .reply => reply = .{ .status = .denied, .bytes = authorization.deny },
        else => {},
    };
    const answer = reply orelse return;
    const delivered = writeReply(stream, answer.status, null, answer.bytes);
    bridge.mutex.lockUncancelable(io);
    _ = step(.{ .reply_done = .{ .id = work.id, .delivery = if (delivered) .delivered else .lost } });
    bridge.mutex.unlock(io);
}

/// Runs an admitted request's work: its MCP call, or its lookup.
fn runOperation(
    arena: Allocator,
    capability: capability_mod.Capability,
    request_id: []const u8,
    operation: wire.Operation,
    allowed: @FieldType(capability_mod.Authorization, "allow"),
    cancel: *std.atomic.Value(bool),
) anyerror!capability_mod.CallOutcome {
    if (operation.lookup()) |question| return capability.lookup(arena, question, cancel);
    return capability.call(arena, request_id, operation.call.tool, operation.call.arguments_json, allowed, cancel);
}

/// A capability whose permission check and call the test controls.
const FakeTool = struct {
    agent: u64 = 0,
    allow: bool = true,
    /// The permission check ends in an error instead of a decision.
    fail: bool = false,
    /// While set, the permission check waits, as for a prompt.
    gate: std.atomic.Value(bool) = .init(false),
    authorizing: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),
    /// While set, a call runs until it is cancelled, as a long MCP call does.
    long_call: std.atomic.Value(bool) = .init(false),
    calling: std.atomic.Value(bool) = .init(false),

    fn capability(self: *FakeTool) capability_mod.Capability {
        return .{ .context = @ptrCast(self), .agent = self.agent, .authorize_fn = authorize, .call_fn = run, .lookup_fn = lookup };
    }

    fn lookup(raw: *anyopaque, arena: Allocator, question: capability_mod.Lookup, cancel: *std.atomic.Value(bool)) anyerror!capability_mod.CallOutcome {
        _ = .{ raw, cancel };
        return switch (question) {
            .list, .search, .help => |text| .{ .status = .ok, .bytes = try arena.print("{s} {s}\n", .{ @tagName(question), text }) },
        };
    }

    fn authorize(raw: *anyopaque, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8) anyerror!capability_mod.Authorization {
        _ = .{ arena, request_id, tool, arguments_json };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        self.authorizing.store(true, .release);
        while (self.gate.load(.acquire)) io_mod.sleep(5 * std.time.ns_per_ms);
        if (self.fail) return error.PermissionCheckFailed;
        return if (self.allow) .{ .allow = .{} } else .{ .deny = "Denied by the test." };
    }

    fn run(raw: *anyopaque, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8, allowed: @FieldType(capability_mod.Authorization, "allow"), cancel: *std.atomic.Value(bool)) anyerror!capability_mod.CallOutcome {
        _ = .{ request_id, allowed };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.calling.store(true, .release);
        if (self.long_call.load(.acquire)) {
            const io = io_mod.getIo();
            bridge.mutex.lockUncancelable(io);
            defer bridge.mutex.unlock(io);
            // A cancel sets the flag under the bridge mutex and wakes this wait (`applyLocked`).
            while (!cancel.load(.acquire)) {
                bridge.changed.waitTimeout(io, &bridge.mutex, .{ .duration = .{ .raw = .fromMilliseconds(wake_safety_poll_ms), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return err,
                };
            }
        }
        if (cancel.load(.acquire)) return .{ .status = .failed, .bytes = "Cancelled by the test." };
        return .{ .status = .ok, .bytes = try arena.print("{s} {s}\n", .{ tool, arguments_json }) };
    }
};

fn waitFor(flag: *const std.atomic.Value(bool)) !void {
    var waited: u32 = 0;
    while (!flag.load(.acquire)) : (waited += 1) {
        if (waited > 1000) return error.TestTimedOut;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
}

const client = @import("mcp_call_client.zig");

fn endCommandAndUnfollow(registration: *Registration) void {
    commandEnded(commandId(registration));
    unfollow(registration, .returned);
}

test "a shell call's command reaches its MCP tool, and a forged token reaches nothing" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    defer endCommandAndUnfollow(registration);
    const variables = registration.environment();
    try std.testing.expectEqualStrings(wire.socket_env, variables[0].name);
    const socket_path = variables[0].value;
    const token = wire.parseToken(variables[1].value).?;

    const reply = try client.call(arena, std.testing.io, socket_path, token, .{ .call = .{ .tool = "mcp_linear_list_issues", .arguments_json = "{\"team\":\"ENG\"}" } });
    try std.testing.expectEqual(wire.Status.ok, reply.header.status);
    try std.testing.expectEqualStrings("mcp_linear_list_issues {\"team\":\"ENG\"}\n", reply.bytes);

    const forged = try client.call(arena, std.testing.io, socket_path, @splat(7), .{ .call = .{ .tool = "mcp_linear_list_issues", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.refused, forged.header.status);
    try std.testing.expectEqual(wire.Reason.unauthorized, forged.header.reason.?);
    try std.testing.expectEqual(@as(u32, 1), tool.calls.load(.acquire));
}

test "a denied call does not run" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{ .allow = false };
    const registration = try register(tool.capability());
    defer endCommandAndUnfollow(registration);
    const variables = registration.environment();
    const reply = try client.call(arena, std.testing.io, variables[0].value, wire.parseToken(variables[1].value).?, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.denied, reply.header.status);
    try std.testing.expectEqualStrings("Denied by the test.", reply.bytes);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a failed permission check names the tool as visible escapes, not raw bytes" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{ .fail = true };
    const registration = try register(tool.capability());
    defer endCommandAndUnfollow(registration);
    const variables = registration.environment();
    // The name is a word from a command line, so it can hold any byte.
    const reply = try client.call(arena, std.testing.io, variables[0].value, wire.parseToken(variables[1].value).?, .{ .call = .{ .tool = "mcp_s_\x1b]0;x\x07\x00t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.denied, reply.header.status);
    try std.testing.expectEqualStrings("The permission check for mcp_s_\\x1b]0;x\\x07\\x00t failed: PermissionCheckFailed", reply.bytes);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a lookup answers without a permission check, and a forged token gets none" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A permission check would wait forever, and would deny.
    var tool: FakeTool = .{ .allow = false };
    tool.gate.store(true, .release);
    defer tool.gate.store(false, .release);
    const registration = try register(tool.capability());
    defer endCommandAndUnfollow(registration);
    const variables = registration.environment();
    const token = wire.parseToken(variables[1].value).?;
    for ([_]wire.Operation{ .{ .list = "linear" }, .{ .search = "open issues" }, .{ .help = "mcp_linear_list_issues" } }) |operation| {
        const reply = try client.call(arena, std.testing.io, variables[0].value, token, operation);
        try std.testing.expectEqual(wire.Status.ok, reply.header.status);
        try std.testing.expectEqualStrings(try arena.print("{s} {s}\n", .{ @tagName(operation), operation.subject() }), reply.bytes);
        const forged = try client.call(arena, std.testing.io, variables[0].value, @splat(7), operation);
        try std.testing.expectEqual(wire.Reason.unauthorized, forged.header.reason.?);
    }
    try std.testing.expect(!tool.authorizing.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a registration records once its command has called the bridge" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    defer endCommandAndUnfollow(registration);
    const variables = registration.environment();
    try std.testing.expect(!commandCalled(registration));
    const reply = try client.call(arena, std.testing.io, variables[0].value, wire.parseToken(variables[1].value).?, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.ok, reply.header.status);
    try std.testing.expect(commandCalled(registration));
}

test "a call after its command ended says why" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const first = try register(tool.capability());
    const second = try register(tool.capability());
    defer endCommandAndUnfollow(second);
    const socket_path = try arena.dupe(u8, first.environment()[0].value);
    const token = wire.parseToken(first.environment()[1].value).?;
    endCommandAndUnfollow(first);
    const reply = try client.call(arena, std.testing.io, socket_path, token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.refused, reply.header.status);
    try std.testing.expectEqual(wire.Reason.unauthorized, reply.header.reason.?);
    try std.testing.expect(std.mem.find(u8, reply.bytes, "has ended") != null);
    try std.testing.expect(std.mem.find(u8, reply.bytes, "each check as its own shell call") == null);
}

test "refusals explain why the call did not run without short-checks advice" {
    const refusals = [_]mcp_call.Refusal{ .closed, .unauthorized, .not_followed };
    for (refusals) |refusal| {
        const text = refusalText(refusal);
        try std.testing.expect(std.mem.find(u8, text, "each check as its own shell call") == null);
    }
    try std.testing.expectEqualStrings("The fx session that started this command has ended.", refusalText(.closed));
    try std.testing.expectEqualStrings("This command was not started by fx's shell tool, or it has ended.", refusalText(.unauthorized));
    try std.testing.expectEqualStrings(
        "This call did not run, because no fx shell call checked on its command for 2 minutes. Check on the command with shell interact, then run the call again.",
        refusalText(.not_followed),
    );
}

test "a command that leaves while its call waits for permission runs nothing, and holds the yield meanwhile" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    tool.gate.store(true, .release);
    const registration = try register(tool.capability());
    const id = commandId(registration);
    const variables = registration.environment();
    const address = try std.Io.net.UnixAddress.init(variables[0].value);
    const stream = try address.connect(io);
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try wire.writeRequest(&writer.interface, wire.parseToken(variables[1].value).?, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try writer.interface.flush();
    try waitFor(&tool.authorizing);
    try std.testing.expectEqual(@as(u32, 1), registration.hold.load(.acquire));
    stream.close(io);
    // The watcher notices within its poll interval; the prompt stays.
    io_mod.sleep(4 * poll_ms * std.time.ns_per_ms);
    tool.gate.store(false, .release);
    commandEnded(id);
    unfollow(registration, .returned);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "the bridge removes its socket after the last command ends" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    const first = try register(tool.capability());
    const second = try register(tool.capability());
    const id1 = commandId(first);
    const id2 = commandId(second);
    const socket_path = try arena_state.allocator().dupe(u8, first.environment()[0].value);
    try std.testing.expectEqualStrings(socket_path, second.environment()[0].value);
    unfollow(first, .returned);
    unfollow(second, .returned);
    try std.Io.Dir.cwd().access(io, socket_path, .{});
    commandEnded(id1);
    try std.Io.Dir.cwd().access(io, socket_path, .{});
    commandEnded(id2);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, socket_path, .{}));
}

/// Waits until a counter on the bridge has moved past zero, or fails after five
/// seconds. A timed wait on the bridge's condition, not a sleep.
fn waitForCount(io: std.Io, count: *const u32) !void {
    const deadline = io_mod.milliTimestamp() + 5_000;
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    while (count.* == 0) {
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.TestTimedOut;
        bridge.changed.waitTimeout(io, &bridge.mutex, .{ .duration = .{ .raw = .fromMilliseconds(remaining), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => |e| return e,
        };
    }
}

test "the bridge ends its accept loop when it stops, not at the loop's safety poll" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    // The stop below must be the one that would sit out a full safety poll,
    // so wait until the accept loop has begun its wait.
    waitForCount(io, &bridge.accept_waits) catch |err| {
        endCommandAndUnfollow(registration);
        return err;
    };
    const started = io_mod.milliTimestamp();
    endCommandAndUnfollow(registration);
    // Without the wake byte this stop waits out wake_safety_poll_ms (1000 ms),
    // so the bound is half of it.
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
}

test "the bridge stops at once, and ends a silent client's connection with it" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    const address = try std.Io.net.UnixAddress.init(registration.environment()[0].value);
    const stream = try address.connect(io);
    defer stream.close(io);
    // The stop must find the connection inside its request-line wait, so wait
    // until the connection has begun one.
    waitForCount(io, &bridge.request_polls) catch |err| {
        endCommandAndUnfollow(registration);
        return err;
    };
    const started = io_mod.milliTimestamp();
    endCommandAndUnfollow(registration);
    // Without the wake byte this stop waits for the request poll's safety timeout (wake_safety_poll_ms).
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
    try std.testing.expectEqual(@as(u32, 0), bridge.connections);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a client that stays connected after its lookup does not hold the bridge's stop" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    var stopped = false;
    errdefer if (!stopped) endCommandAndUnfollow(registration);
    const variables = registration.environment();
    const address = try std.Io.net.UnixAddress.init(variables[0].value);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try wire.writeRequest(&writer.interface, wire.parseToken(variables[1].value).?, .{ .help = "mcp_linear_list_issues" });
    try writer.interface.flush();
    // Read the whole reply and keep the socket open: the request's watch must end
    // without the client leaving.
    var read_buffer: [wire.max_header_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.TestUnexpectedResult;
    const header = try wire.parseHeader(arena, line);
    try std.testing.expectEqual(wire.Status.ok, header.status);
    _ = try reader.interface.readAllocAll(arena, @intCast(header.bytes));
    const started = io_mod.milliTimestamp();
    stopped = true;
    endCommandAndUnfollow(registration);
    // endCommandAndUnfollow waits for this request's watch to end, which needs the watch's
    // wake byte. Without it the watch would wait out wake_safety_poll_ms (1000 ms).
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
    try std.testing.expectEqual(@as(u32, 0), bridge.connections);
}

const PendingCall = struct {
    arena_state: std.heap.ArenaAllocator,
    socket_path: []const u8,
    token: mcp_call.Token,
    reply: ?client.Reply = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *PendingCall) void {
        defer self.done.store(true, .release);
        self.reply = client.call(self.arena_state.allocator(), io_mod.getIo(), self.socket_path, self.token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } }) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn waitForConnectionsZero(io: std.Io) !void {
    const deadline = io_mod.milliTimestamp() + 5_000;
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    while (bridge.connections > 0) {
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.TestTimedOut;
        bridge.changed.waitTimeout(io, &bridge.mutex, .{ .duration = .{ .raw = .fromMilliseconds(remaining), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => |e| return e,
        };
    }
}

test "a command's token stays valid after its shell call returns" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var started: FakeTool = .{};
    var later: FakeTool = .{};
    const registration = try register(started.capability());
    const id = commandId(registration);
    errdefer commandEnded(id);
    const socket_path = try arena.dupe(u8, registration.environment()[0].value);
    const token = wire.parseToken(registration.environment()[1].value).?;
    unfollow(registration, .returned);

    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    {
        defer unfollow(followed, .returned);
        const reply = try client.call(arena, std.testing.io, socket_path, token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
        try std.testing.expectEqual(wire.Status.ok, reply.header.status);
        try std.testing.expectEqualStrings("mcp_s_t {}\n", reply.bytes);
    }
    try std.testing.expectEqual(@as(u32, 0), started.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), later.calls.load(.acquire));
    commandEnded(id);
}

test "a request that comes while no shell call follows waits and the next follower runs it" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var started: FakeTool = .{};
    var later: FakeTool = .{};
    const registration = try register(started.capability());
    const id = commandId(registration);
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = wire.parseToken(registration.environment()[1].value).?,
    };
    defer pending.arena_state.deinit();
    unfollow(registration, .returned);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    defer thread.join();
    errdefer commandEnded(id);
    try waitForCount(io, &bridge.waiting_follows);
    try std.testing.expect(!pending.done.load(.acquire));
    try std.testing.expect(!started.authorizing.load(.acquire));
    try std.testing.expect(!later.authorizing.load(.acquire));

    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    errdefer unfollow(followed, .returned);
    try std.testing.expectEqual(registration, followed);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.ok, pending.reply.?.header.status);
    try std.testing.expectEqualStrings("mcp_s_t {}\n", pending.reply.?.bytes);
    try std.testing.expectEqual(@as(u32, 0), started.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), later.calls.load(.acquire));
    try std.testing.expect(commandCalled(followed));
    try std.testing.expectEqual(@as(?*Registration, null), follow(id, started.capability()));
    commandEnded(id);
    unfollow(followed, .returned);
}

test "a waiting request never runs after the command ends" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    const other = try register(tool.capability());
    defer {
        commandEnded(commandId(other));
        unfollow(other, .returned);
    }
    const registration = try register(tool.capability());
    const id = commandId(registration);
    const token = wire.parseToken(registration.environment()[1].value).?;
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = token,
    };
    defer pending.arena_state.deinit();
    unfollow(registration, .returned);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    {
        errdefer {
            commandEnded(id);
            thread.join();
        }
        try waitForCount(io, &bridge.waiting_follows);
    }

    commandEnded(id);
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.refused, pending.reply.?.header.status);
    try std.testing.expectEqual(wire.Reason.unauthorized, pending.reply.?.header.reason.?);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
    const late = try client.call(arena_state.allocator(), io, other.environment()[0].value, token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Reason.unauthorized, late.header.reason.?);
    try std.testing.expectEqual(@as(?*Registration, null), follow(id, tool.capability()));
}

test "a follower's cancel cancels the call it runs and keeps the token" {
    if (!supported) return error.SkipZigTest;
    var tool: FakeTool = .{};
    tool.long_call.store(true, .release);
    const registration = try register(tool.capability());
    const id = commandId(registration);
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = wire.parseToken(registration.environment()[1].value).?,
    };
    defer pending.arena_state.deinit();
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    defer thread.join();
    {
        errdefer {
            commandEnded(id);
            unfollow(registration, .cancelled);
        }
        try waitFor(&tool.calling);
    }

    unfollow(registration, .cancelled);
    errdefer commandEnded(id);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), pending.err);
    var later: FakeTool = .{};
    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    {
        defer unfollow(followed, .returned);
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const reply = try client.call(arena_state.allocator(), std.testing.io, followed.environment()[0].value, wire.parseToken(followed.environment()[1].value).?, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
        try std.testing.expectEqual(wire.Status.ok, reply.header.status);
    }
    try std.testing.expectEqual(@as(u32, 1), later.calls.load(.acquire));
    commandEnded(id);
}

test "a waiting request whose client leaves never runs" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    const id = commandId(registration);
    errdefer commandEnded(id);
    const variables = registration.environment();
    const socket_path = variables[0].value;
    const token = wire.parseToken(variables[1].value).?;
    unfollow(registration, .returned);

    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try wire.writeRequest(&writer.interface, token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try writer.interface.flush();
    try waitForCount(io, &bridge.waiting_follows);
    stream.close(io);
    try waitForConnectionsZero(io);

    const followed = follow(id, tool.capability()) orelse return error.TestUnexpectedResult;
    commandEnded(id);
    unfollow(followed, .returned);
    try std.testing.expect(!tool.authorizing.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

/// The refusal reasons that `fx mcp call` in fx v0.0.18 knows. That client
/// reads a reply with any other reason as a lost connection that may have run
/// the call, and exits 1.
const v0_0_18_reasons = [_][]const u8{ "closed", "unauthorized", "unsupported_version", "busy", "malformed", "too_large" };

test "a request that waits past the limit gets a refusal fx v0.0.18 clients can read" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prev_limit = test_follow_wait_ms.load(.acquire);
    test_follow_wait_ms.store(20, .release);
    defer test_follow_wait_ms.store(prev_limit, .release);
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    const id = commandId(registration);
    defer commandEnded(id);
    const socket_path = try arena_state.allocator().dupe(u8, registration.environment()[0].value);
    const token = wire.parseToken(registration.environment()[1].value).?;
    unfollow(registration, .returned);

    const reply = try client.call(arena_state.allocator(), std.testing.io, socket_path, token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.refused, reply.header.status);
    const reason = @tagName(reply.header.reason.?);
    for (v0_0_18_reasons) |known| {
        if (std.mem.eql(u8, known, reason)) break;
    } else {
        std.debug.print("reason {s} is not one fx v0.0.18 knows\n", .{reason});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.find(u8, reply.bytes, "2 minutes") != null);
    try std.testing.expect(std.mem.find(u8, reply.bytes, "shell interact") != null);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "the follow-wait limit is two minutes unless a positive number of milliseconds is given" {
    try std.testing.expectEqual(mcp_call.follow_wait_ms, parseFollowWaitMs(null));
    try std.testing.expectEqual(@as(u32, 300), parseFollowWaitMs("300"));
    try std.testing.expectEqual(mcp_call.follow_wait_ms, parseFollowWaitMs("0"));
    try std.testing.expectEqual(mcp_call.follow_wait_ms, parseFollowWaitMs("-5"));
    try std.testing.expectEqual(mcp_call.follow_wait_ms, parseFollowWaitMs("abc"));
    try std.testing.expectEqual(mcp_call.follow_wait_ms, parseFollowWaitMs(""));
    try std.testing.expectEqual(mcp_call.follow_wait_ms, parseFollowWaitMs("99999999999"));
}

test "a shell call of another agent does not follow a command, so its calls keep waiting" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var subagent: FakeTool = .{ .agent = 1 };
    var parent: FakeTool = .{ .agent = 0 };
    const registration = try register(subagent.capability());
    const id = commandId(registration);
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = wire.parseToken(registration.environment()[1].value).?,
    };
    defer pending.arena_state.deinit();
    unfollow(registration, .returned);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    defer thread.join();
    errdefer commandEnded(id);
    try waitForCount(io, &bridge.waiting_follows);

    if (follow(id, parent.capability())) |wrong| {
        unfollow(wrong, .returned);
        return error.TestExpectedEqual;
    }
    try std.testing.expect(!pending.done.load(.acquire));
    try std.testing.expect(!parent.authorizing.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), parent.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), subagent.calls.load(.acquire));

    const followed = follow(id, subagent.capability()) orelse return error.TestUnexpectedResult;
    errdefer unfollow(followed, .returned);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.ok, pending.reply.?.header.status);
    try std.testing.expectEqual(@as(u32, 1), subagent.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), parent.calls.load(.acquire));
    commandEnded(id);
    unfollow(followed, .returned);
}

test "a waiting request admitted after the live list filled meanwhile still runs" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var started: FakeTool = .{};
    var later: FakeTool = .{};
    const registration = try register(started.capability());
    const id = commandId(registration);
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = wire.parseToken(registration.environment()[1].value).?,
    };
    defer pending.arena_state.deinit();
    unfollow(registration, .returned);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    defer thread.join();
    defer commandEnded(id);
    try waitForCount(io, &bridge.waiting_follows);

    // Other requests take every free entry of the live list while this one
    // waits, as served requests of other commands can.
    bridge.mutex.lockUncancelable(io);
    const fillers = std.testing.allocator.alloc(Live, bridge.live.capacity - bridge.live.items.len) catch |err| {
        bridge.mutex.unlock(io);
        return err;
    };
    for (fillers, 0..) |*filler, index| {
        filler.* = .{ .id = @fromBackingInt(std.math.maxInt(u64) - index) };
        bridge.live.appendAssumeCapacity(filler);
    }
    bridge.mutex.unlock(io);
    defer {
        bridge.mutex.lockUncancelable(io);
        for (fillers) |*filler| {
            for (bridge.live.items, 0..) |item, index| {
                if (item == filler) {
                    _ = bridge.live.swapRemove(index);
                    break;
                }
            }
        }
        bridge.mutex.unlock(io);
        std.testing.allocator.free(fillers);
    }

    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    defer unfollow(followed, .returned);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.ok, pending.reply.?.header.status);
    try std.testing.expectEqual(@as(u32, 1), later.calls.load(.acquire));
}

test "a follower that returns at once still runs the request that waited for it" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var started: FakeTool = .{};
    var later: FakeTool = .{};
    const registration = try register(started.capability());
    const id = commandId(registration);
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = wire.parseToken(registration.environment()[1].value).?,
    };
    defer pending.arena_state.deinit();
    unfollow(registration, .returned);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    defer thread.join();
    defer commandEnded(id);
    try waitForCount(io, &bridge.waiting_follows);

    // The waiting request wakes at the follow but holds before it checks
    // again, so the follower returns first, as a zero-wait interact can.
    test_hold_recheck.store(true, .release);
    defer test_hold_recheck.store(false, .release);
    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    unfollow(followed, .returned);
    test_hold_recheck.store(false, .release);
    commandEnded(id);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.ok, pending.reply.?.header.status);
    try std.testing.expectEqual(@as(u32, 1), later.calls.load(.acquire));
}

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
//! steering arrives, and its requests then wait for the next call that
//! follows it. The bridge listens on one Unix socket in a private directory
//! while any command is registered, and closes it after the last one ends.
//!
//! The core decides everything: admission, the order of the permission
//! check and the call, one call and one reply per request, and what to let
//! go and log when a client or owner leaves. This file only runs its
//! effects and reports their results as events, under one mutex, so the
//! core has one writer. `tests/tla/mcp_call/` checks the core against its
//! model.
const std = @import("std");
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
/// The accept loop's wait when no wake byte comes. A stop always writes one,
/// so this bounds only a wake that is lost.
const accept_safety_poll_ms = 1000;
/// How long a client may take to send its request line.
const request_deadline_ms: i64 = 10_000;

/// One running command, registered as an owner. It ends when the command
/// has ended and no shell call follows it (`finishLocked`).
pub const Registration = struct {
    owner: mcp_call.OwnerId,
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
    /// Requests being served, waiting ones included. Guarded by the bridge
    /// mutex.
    in_use: u32 = 0,
    /// Requests whose work borrows `capability`. Guarded by the bridge mutex.
    borrowing: u32 = 0,
    /// Requests admitted for this owner so far. Guarded by the bridge mutex.
    requests: u32 = 0,
    token_hex: [wire.token_hex_len]u8,
    variables: [2]command_runner.EnvironmentVariable = undefined,

    /// The variables a command needs to reach the bridge as this owner.
    /// Valid while a shell call follows the command.
    pub fn environment(self: *const Registration) []const command_runner.EnvironmentVariable {
        return &self.variables;
    }
};

/// A request being served, so a `cancel` effect can reach its call and a
/// `withdraw` effect a request that waits for a shell call.
const Live = struct {
    id: mcp_call.RequestId,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Its client or owner left. Guarded by the bridge mutex.
    withdrawn: bool = false,
    /// The registration whose capability its work uses. Guarded by the
    /// bridge mutex.
    lender: ?*const Registration = null,
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
};

var bridge: Bridge = .{};

/// Registers a command a shell call is about to start, starting the bridge
/// if this is the first, with that call as its follower. The call must
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
    registration.* = .{ .owner = nextOwnerLocked(), .capability = capability, .token_hex = wire.tokenHex(token) };
    registration.variables = .{
        .{ .name = wire.socket_env, .value = bridge.socket_path.? },
        .{ .name = wire.token_env, .value = &registration.token_hex },
    };
    bridge.registrations.appendAssumeCapacity(registration);
    applyLocked(mcp_call.step(bridge.state, .{ .owner_added = .{ .owner = registration.owner, .token = token } }));
    return registration;
}

/// The id `follow` and `commandEnded` take for `registration`'s command.
pub fn commandId(registration: *const Registration) u64 {
    return @backingInt(registration.owner);
}

/// Lends `capability` to the command `id` names while a later shell call,
/// an `interact` on its session, follows it. Returns null when the command
/// has ended, is not registered, or another call follows it; its requests
/// then do not use `capability`. The call must `unfollow` the registration
/// it returns before `capability` goes away.
pub fn follow(id: u64, capability: capability_mod.Capability) ?*Registration {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    const registration = findLocked(id) orelse return null;
    if (registration.followed or !registration.command_running) return null;
    // The last follower's `unfollow` waited until nothing borrowed its
    // capability, so no request still uses one.
    std.debug.assert(registration.borrowing == 0);
    registration.followed = true;
    registration.capability = capability;
    bridge.changed.broadcast(io);
    return registration;
}

/// Ends a shell call's following of its command. When the command still
/// runs, its token stays in force and this returns once no request uses
/// the call's capability; a later request waits for the next call that
/// follows the command. When the command has ended, it ends the
/// registration (`finishLocked`). When `cancelled`, the call is being
/// cancelled, so the MCP calls its capability runs are cancelled too; a
/// prompt one shows stays until it is answered.
pub fn unfollow(registration: *Registration, cancelled: bool) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    // No request takes the capability from here on.
    registration.capability = null;
    if (cancelled) {
        for (bridge.live.items) |live| {
            if (live.lender == registration) live.cancel.store(true, .release);
        }
    }
    while (registration.borrowing > 0 and registration.command_running) bridge.changed.waitUncancelable(io, &bridge.mutex);
    registration.followed = false;
    if (registration.command_running) {
        bridge.mutex.unlock(io);
        return;
    }
    finishLocked(io, registration);
}

/// Records that the command `id` names has ended. It ends the registration
/// at once when no shell call follows the command, and otherwise leaves
/// that to the call's `unfollow`. A second call for the same command, or one
/// for a registration that is gone, does nothing.
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
    if (registration.followed) {
        // A follower's `unfollow` may wait for its borrowers; it ends the
        // registration now.
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
        return;
    }
    finishLocked(io, registration);
}

/// Whether the command `registration` names has sent a request, so the
/// shell call that returns while it runs can tell the agent its requests
/// wait for the next call that follows it.
pub fn hasRequests(registration: *Registration) bool {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    return registration.requests > 0;
}

fn findLocked(id: u64) ?*Registration {
    for (bridge.registrations.items) |registration| {
        if (commandId(registration) == id) return registration;
    }
    return null;
}

/// Ends a registration that neither its command nor a shell call holds: its
/// token is revoked, a running call is cancelled, a request that waits for a
/// shell call ends, and a waiting prompt stays until it is answered. Returns
/// once no request is left. Stops the bridge after the last one. Called with
/// the bridge mutex held, which it releases.
fn finishLocked(io: std.Io, registration: *Registration) void {
    applyLocked(mcp_call.step(bridge.state, .{ .owner_removed = registration.owner }));
    while (registration.in_use > 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
    for (bridge.registrations.items, 0..) |item, index| {
        if (item == registration) {
            _ = bridge.registrations.swapRemove(index);
            break;
        }
    }
    const last = bridge.registrations.items.len == 0;
    var accept_task: ?std.Io.Future(void) = null;
    if (last) {
        applyLocked(mcp_call.step(bridge.state, .stopped));
        bridge.phase = .stopping;
        bridge.stop.store(true, .release);
        if (bridge.wake) |wake| wakeAcceptLoop(wake[1]);
        accept_task = bridge.accept_task;
        bridge.accept_task = null;
    }
    bridge.mutex.unlock(io);
    gpa.destroy(registration);
    if (!last) return;
    // The wake byte ends the accept loop's wait at once. No owner is left, so
    // the connections still open are unadmitted ones; cancelling ends their
    // wait for a request line.
    if (accept_task) |*task| task.await(io);
    bridge.connection_tasks.cancel(io);
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    closeListenerLocked(io);
    bridge.stop.store(false, .release);
    bridge.phase = .idle;
    bridge.changed.broadcast(io);
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
    var listener = try address.listen(io, .{});
    errdefer listener.deinit(io);
    // Close-on-exec, so the commands fx starts do not inherit the wake pipe.
    const wake = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer closeWake(wake);
    bridge.listener = listener;
    bridge.wake = wake;
    bridge.accept_waits = 0;
    bridge.stop.store(false, .release);
    bridge.accept_task = std.Io.concurrent(io, acceptLoop, .{}) catch |err| {
        bridge.listener = null;
        bridge.wake = null;
        std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        return err;
    };
    bridge.dir_path = dir_path;
    bridge.socket_path = socket_path;
    var main_token: mcp_call.Token = undefined;
    io.random(&main_token);
    // The bridge's own registration: no command ever receives this token.
    applyLocked(mcp_call.step(bridge.state, .{ .started = main_token }));
    bridge.phase = .running;
    debug_trace.logf("mcp-call", "bridge listening socket={s}", .{socket_path});
}

/// Writes the byte that ends the accept loop's wait. Each run has its own pipe,
/// so the one byte never fills it and the write does not block. A failed write
/// leaves the loop to its safety poll, so it is only logged.
fn wakeAcceptLoop(write_end: posix.fd_t) void {
    const byte = [1]u8{0};
    if (std.c.write(write_end, &byte, 1) != 1) {
        debug_trace.logf("mcp-call", "bridge wake not written; the accept loop ends at its safety poll", .{});
    }
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
/// serving task's own: cancels, withdrawals, and logs.
fn applyLocked(out: mcp_call.Output) void {
    bridge.state = out.state;
    for (out.effects()) |effect| switch (effect) {
        .cancel => |id| {
            for (bridge.live.items) |live| {
                if (live.id == id) live.cancel.store(true, .release);
            }
        },
        .withdraw => |id| {
            // A request that waits for a shell call to follow its command
            // ends now; one whose prompt shows ends when it is answered.
            for (bridge.live.items) |live| {
                if (live.id == id) live.withdrawn = true;
            }
            bridge.changed.broadcast(io_mod.getIo());
            debug_trace.logf("mcp-call", "request={d} client or owner gone; its permission prompt stays until answered, and nothing runs", .{@backingInt(id)});
        },
        .log => |log| debug_trace.logf("mcp-call", "request={d} dropped={s}", .{ @backingInt(log.id), @tagName(log.drop) }),
        .refuse, .authorize, .call, .reply => {},
    };
}

fn step(event: mcp_call.Event) mcp_call.Output {
    const out = mcp_call.step(bridge.state, event);
    applyLocked(out);
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
        const ready = posix.poll(&fds, accept_safety_poll_ms) catch |err| {
            debug_trace.logf("mcp-call", "bridge accept loop ended err={s}", .{@errorName(err)});
            return;
        };
        if (fds[1].revents != 0) return;
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
        bridge.connection_tasks.concurrent(io, serve, .{stream}) catch |err| {
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
}

const ReadError = error{ TooLarge, Silent, Closed, ReadFailed, OutOfMemory, Canceled };

/// Reads one request line within the deadline, without its newline. Ends
/// with `error.Canceled` when the bridge stops first.
fn readRequestLine(arena: Allocator, fd: posix.socket_t) ReadError![]const u8 {
    const io = io_mod.getIo();
    var line: std.ArrayList(u8) = .empty;
    const deadline = io_mod.milliTimestamp() + request_deadline_ms;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        try io.checkCancel();
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.Silent;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, @intCast(@min(remaining, poll_ms))) catch return error.ReadFailed;
        if (ready == 0) continue;
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
        .closed => "The command fx's shell tool started for this call has ended. Run fx mcp call from a command in a new shell call.",
        .unauthorized => "This command was not started by fx's shell tool, or the command that was has ended. Run fx mcp call from a command fx's shell tool runs, while that command runs.",
        .unsupported_version => "This fx mcp call is from another fx version than the running session. Run the fx that started the session, or restart the session with this one.",
        .busy => "Too many fx mcp call requests are running in this session. Nothing ran; try again when one finishes.",
        .malformed => "The request was not an fx mcp call request. Send requests with the fx that started the session.",
        .too_large => "The request is over 1 MiB. Pass smaller arguments.",
    };
}

/// Watches a served connection and reports its client leaving.
const Watch = struct {
    fd: posix.socket_t,
    id: mcp_call.RequestId,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        const io = io_mod.getIo();
        while (!self.done.load(.acquire)) {
            var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, poll_ms) catch return;
            if (ready == 0) continue;
            var probe: [1]u8 = undefined;
            const rc = std.c.recv(self.fd, &probe, 1, posix.MSG.PEEK | posix.MSG.DONTWAIT);
            const hung_up = (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0;
            if (rc == 0 or hung_up) {
                bridge.mutex.lockUncancelable(io);
                _ = step(.{ .client_gone = self.id });
                bridge.mutex.unlock(io);
                return;
            }
            // The client sent more than its one line: not ours to read.
            io_mod.sleep(poll_ms * std.time.ns_per_ms);
        }
    }
};

fn serve(stream: std.Io.net.Stream) void {
    const io = io_mod.getIo();
    defer finishConnection(io, stream);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = readRequestLine(arena, stream.socket.handle) catch |err| {
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

    // Admission. A missing or garbled token is one no owner holds.
    var live: Live = undefined;
    var registration: *Registration = undefined;
    bridge.mutex.lockUncancelable(io);
    bridge.live.ensureUnusedCapacity(gpa, 1) catch {
        bridge.mutex.unlock(io);
        _ = writeReply(stream, .failed, null, "fx could not take this request: out of memory.");
        return;
    };
    const admitted = step(.{ .request = .{ .token = request.token orelse @splat(0), .version = request.version } });
    const work: mcp_call.Work = for (admitted.effects()) |effect| switch (effect) {
        .authorize => |value| break value,
        .refuse => |refusal| {
            bridge.mutex.unlock(io);
            const reason = wire.Reason.fromRefusal(refusal);
            debug_trace.logf("mcp-call", "bridge refused op={s} reason={s}", .{ @tagName(request.operation), @tagName(reason) });
            _ = writeReply(stream, .refused, reason, refusalMessage(reason));
            return;
        },
        else => {},
    } else {
        bridge.mutex.unlock(io);
        return;
    };
    registration = for (bridge.registrations.items) |item| {
        if (item.owner == work.owner) break item;
    } else unreachable; // the core admits only registered owners
    live = .{ .id = work.id };
    bridge.live.appendAssumeCapacity(&live);
    registration.in_use += 1;
    registration.requests +|= 1;
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

    var watch: Watch = .{ .fd = stream.socket.handle, .id = work.id };
    var watcher: ?std.Io.Future(void) = std.Io.concurrent(io, Watch.run, .{&watch}) catch |err| blk: {
        debug_trace.logf("mcp-call", "request={d} runs without a disconnect watch err={s}", .{ @backingInt(work.id), @errorName(err) });
        break :blk null;
    };
    defer if (watcher) |*task| {
        watch.done.store(true, .release);
        task.await(io);
    };

    // The command can outlive the shell call that started it. Its request
    // then waits for the next call that follows it, or ends when its client
    // or owner leaves first.
    bridge.mutex.lockUncancelable(io);
    while (registration.capability == null and !live.withdrawn) bridge.changed.waitUncancelable(io, &bridge.mutex);
    const lent: ?capability_mod.Capability = if (live.withdrawn) null else registration.capability;
    if (lent != null) {
        registration.borrowing += 1;
        live.lender = registration;
    }
    if (lent == null) _ = step(.{ .authorized = .{ .id = work.id, .decision = .deny } });
    bridge.mutex.unlock(io);
    const capability = lent orelse return;
    defer {
        bridge.mutex.lockUncancelable(io);
        registration.borrowing -= 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
    }

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
        return .{ .context = @ptrCast(self), .authorize_fn = authorize, .call_fn = run, .lookup_fn = lookup };
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
        while (self.long_call.load(.acquire) and !cancel.load(.acquire)) io_mod.sleep(5 * std.time.ns_per_ms);
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

/// What happens when a command ends while the shell call that started it
/// follows it: the call returns, and the registration ends with it.
fn unregister(registration: *Registration) void {
    commandEnded(commandId(registration));
    unfollow(registration, false);
}

/// One `fx mcp call` from a command, sent on its own thread, since it waits
/// while no shell call follows the command.
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

fn waitForHold(registration: *const Registration, count: u32) !void {
    var waited: u32 = 0;
    while (registration.hold.load(.acquire) != count) : (waited += 1) {
        if (waited > 1000) return error.TestTimedOut;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
}

test "a command's call waits while no shell call follows it, and the next call that follows it serves the call" {
    if (!supported) return error.SkipZigTest;
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
    // The call that started the command returns while it runs, as when it
    // yields or steering arrives.
    unfollow(registration, false);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    defer thread.join();
    // A failed check ends the command, which lets the waiting call go.
    errdefer commandEnded(id);
    try waitForHold(registration, 1);
    io_mod.sleep(3 * poll_ms * std.time.ns_per_ms);
    try std.testing.expect(!pending.done.load(.acquire));
    try std.testing.expect(!started.authorizing.load(.acquire));
    try std.testing.expect(!later.authorizing.load(.acquire));

    // An `interact` on its session follows the command, and the call runs
    // with that call's permission check and access.
    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    errdefer unfollow(followed, false);
    try std.testing.expectEqual(registration, followed);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.ok, pending.reply.?.header.status);
    try std.testing.expectEqualStrings("mcp_s_t {}\n", pending.reply.?.bytes);
    try std.testing.expectEqual(@as(u32, 0), started.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), later.calls.load(.acquire));
    try std.testing.expect(hasRequests(followed));
    // A second call cannot follow the command while one does.
    try std.testing.expectEqual(@as(?*Registration, null), follow(id, started.capability()));
    unregister(followed);
}

test "a cancelled shell call cancels the call it runs for its command, and the command keeps its token" {
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
        // A failed check ends the command, which cancels the call.
        errdefer unregister(registration);
        try waitFor(&tool.calling);
    }

    // The turn is cancelled while the call runs, as with Esc during an
    // `interact` that follows the command.
    unfollow(registration, true);
    // The command still runs; a failed check ends it.
    errdefer commandEnded(id);
    try waitFor(&pending.done);
    try std.testing.expectEqual(@as(?anyerror, null), pending.err);
    try std.testing.expectEqual(wire.Status.failed, pending.reply.?.header.status);
    try std.testing.expectEqualStrings("Cancelled by the test.", pending.reply.?.bytes);
    // Its token is still in force, so a later call can follow the command.
    var later: FakeTool = .{};
    const followed = follow(id, later.capability()) orelse return error.TestUnexpectedResult;
    unregister(followed);
}

test "the end of a command no shell call follows lets its waiting call go and revokes its token" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    // Another command keeps the bridge open, so the revoked token is refused
    // rather than finding no socket.
    const other = try register(tool.capability());
    defer unregister(other);
    const registration = try register(tool.capability());
    const id = commandId(registration);
    const token = wire.parseToken(registration.environment()[1].value).?;
    var pending: PendingCall = .{
        .arena_state = .init(std.testing.allocator),
        .socket_path = registration.environment()[0].value,
        .token = token,
    };
    defer pending.arena_state.deinit();
    unfollow(registration, false);
    const thread = try std.Thread.spawn(.{}, PendingCall.run, .{&pending});
    {
        errdefer {
            commandEnded(id);
            thread.join();
        }
        try waitForHold(registration, 1);
    }

    commandEnded(id);
    thread.join();
    // The request ended without running; its client gets no reply.
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), pending.err);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
    // The ended command's token reaches nothing, and no call follows it.
    const late = try client.call(arena_state.allocator(), std.testing.io, other.environment()[0].value, token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Reason.unauthorized, late.header.reason.?);
    try std.testing.expectEqual(@as(?*Registration, null), follow(id, tool.capability()));
    commandEnded(id);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a shell call's command reaches its MCP tool, and a forged token reaches nothing" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    defer unregister(registration);
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
    defer unregister(registration);
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
    defer unregister(registration);
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
    defer unregister(registration);
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

test "a command that leaves while its call waits for permission runs nothing, and holds the yield meanwhile" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    tool.gate.store(true, .release);
    const registration = try register(tool.capability());
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
    unregister(registration);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "the bridge removes its socket after the last shell call" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    const first = try register(tool.capability());
    const second = try register(tool.capability());
    const socket_path = try arena_state.allocator().dupe(u8, first.environment()[0].value);
    try std.testing.expectEqualStrings(socket_path, second.environment()[0].value);
    unregister(first);
    try std.Io.Dir.cwd().access(io, socket_path, .{});
    unregister(second);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, socket_path, .{}));
}

test "the bridge ends its accept loop when it stops, not at the loop's safety poll" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    // Wait until the loop has begun its wait, so the stop below is the one
    // that would sit out a full poll. The loop counts each pass and broadcasts.
    bridge.mutex.lockUncancelable(io);
    while (bridge.accept_waits == 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
    bridge.mutex.unlock(io);
    const started = io_mod.milliTimestamp();
    unregister(registration);
    // Without the wake byte this stop waits out accept_safety_poll_ms (1000 ms),
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
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (true) {
        bridge.mutex.lockUncancelable(io);
        const open = bridge.connections;
        bridge.mutex.unlock(io);
        if (open == 1) break;
        if (io_mod.milliTimestamp() > deadline) return error.TestTimedOut;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    const started = io_mod.milliTimestamp();
    unregister(registration);
    // The connection's wait for a request line ended with the bridge, well
    // before its own deadline.
    try std.testing.expect(io_mod.milliTimestamp() - started < request_deadline_ms / 2);
    try std.testing.expectEqual(@as(u32, 0), bridge.connections);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

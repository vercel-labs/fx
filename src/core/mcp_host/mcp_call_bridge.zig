//! The `fx mcp call` bridge: the shell around the pure core in
//! `mcp_call.zig`. A command that fx's shell tool runs can call the
//! session's MCP tools through it, so a large result can go to a file
//! instead of into the model's context.
//!
//! Each command fx's shell runs registers as an owner with its own token,
//! from the shell call that starts it until its process ends. A shell call
//! of the same agent lends the owner its permission check and MCP call
//! (`../tooling/mcp_call_capability.zig`): the run call that starts the
//! command, while it waits for it, and then each interact that watches it.
//! A call therefore meets the same rules, prompt, review, and access as a
//! direct one by that agent, in that call's turn. While no shell call lends,
//! as after the run call yields, the command's calls wait. The bridge listens
//! on one Unix socket in a private directory while any command is
//! registered, and closes it after the last one ends.
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
/// How long a client may take to send its request line.
const request_deadline_ms: i64 = 10_000;

/// One command fx's shell runs, registered as an owner from the shell call
/// that starts it until its process ends. Fields other than `hold` are
/// guarded by the bridge mutex.
pub const Registration = struct {
    owner: mcp_call.OwnerId,
    /// Never reused, so a late `commandEnded` or `lend` finds nothing rather
    /// than a later command.
    id: u64,
    /// The capability of the shell call that lends to this owner, or null
    /// while none does. It is set exactly while the core counts the owner
    /// lent.
    lender: ?capability_mod.Capability,
    /// A shell call holds the registration: the run call that started the
    /// command, or an interact that lends to it. That call ends its hold with
    /// `release`, or the registration with `unregister`.
    held: bool = true,
    /// The command ended while a call held it; `release` ends the owner.
    ended: bool = false,
    /// `unregister` has begun.
    removing: bool = false,
    /// The owner's requests the bridge is working on, waiting ones included.
    /// While above zero the holding shell call does not yield
    /// (`managed_execution` `yield_hold`).
    hold: std.atomic.Value(u32) = .init(0),
    /// Requests whose work borrows the lender's capability.
    borrowing: u32 = 0,
    /// Requests being served that point at this registration.
    serving: u32 = 0,
    token_hex: [wire.token_hex_len]u8,
    variables: [2]command_runner.EnvironmentVariable = undefined,

    /// The variables a command needs to reach the bridge as this owner.
    /// Valid until `unregister`.
    pub fn environment(self: *const Registration) []const command_runner.EnvironmentVariable {
        return &self.variables;
    }
};

/// A request being served, so the core's effects can reach it: `cancel` its
/// call, and for a request that waits for a lender, `authorize` or
/// `withdraw` it. `lender`, `authorized`, and `withdrawn` are guarded by the
/// bridge mutex.
const Live = struct {
    id: mcp_call.RequestId,
    cancel: std.atomic.Value(bool) = .init(false),
    /// The capability its work borrows, taken when its check starts.
    lender: ?capability_mod.Capability = null,
    /// A lend moved it on to its check.
    authorized: bool = false,
    /// Its client or owner left before its check started.
    withdrawn: bool = false,
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
    next_registration: u64 = 1,
    connections: u32 = 0,
};

var bridge: Bridge = .{};

/// Registers the command a running shell call starts, lent that call's
/// `capability`, starting the bridge if this is the first. The caller holds
/// the registration: it must `release` or `unregister` it before
/// `capability` goes away.
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
    registration.* = .{ .owner = nextOwnerLocked(), .id = bridge.next_registration, .lender = capability, .token_hex = wire.tokenHex(token) };
    bridge.next_registration += 1;
    registration.variables = .{
        .{ .name = wire.socket_env, .value = bridge.socket_path.? },
        .{ .name = wire.token_env, .value = &registration.token_hex },
    };
    bridge.registrations.appendAssumeCapacity(registration);
    applyLocked(mcp_call.step(bridge.state, .{ .owner_added = .{ .owner = registration.owner, .token = token } }));
    return registration;
}

/// Ends a command's registration: its token is revoked, a running call is
/// cancelled, a waiting prompt stays until it is answered, and a call that
/// waits for a lender is refused. Returns once no request points at the
/// registration. Stops the bridge after the last one.
pub fn unregister(registration: *Registration) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    removeAndUnlock(io, registration);
}

/// The shell call that holds `registration` returns while its command still
/// runs. The lend ends, and the command's later calls wait for the next shell
/// call that watches it. Returns once nothing borrows the returning call's
/// capability. When the command ended meanwhile, its registration ends here.
pub fn release(registration: *Registration) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    std.debug.assert(registration.held and !registration.removing);
    applyLocked(mcp_call.step(bridge.state, .{ .lend_ended = registration.owner }));
    registration.lender = null;
    while (registration.borrowing > 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
    registration.held = false;
    if (registration.ended) return removeAndUnlock(io, registration);
    bridge.mutex.unlock(io);
}

/// Lends a shell call's `capability` to the command whose registration `id`
/// names, until that call's `release`: the command's waiting calls and later
/// ones run as that call. Null when the command has ended or another call
/// holds it.
pub fn lend(id: u64, capability: capability_mod.Capability) ?*Registration {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    const registration = findLocked(id) orelse return null;
    if (registration.held or registration.ended or registration.removing) return null;
    registration.held = true;
    registration.lender = capability;
    applyLocked(mcp_call.step(bridge.state, .{ .lent = registration.owner }));
    return registration;
}

/// The process of the command whose registration `id` names has ended. Its
/// registration ends now, or, while a shell call holds it, when that call
/// releases it. An id that names nothing, as after the run call ended the
/// registration itself, changes nothing.
pub fn commandEnded(id: u64) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    const registration = findLocked(id) orelse return bridge.mutex.unlock(io);
    if (registration.removing) return bridge.mutex.unlock(io);
    if (registration.held) {
        registration.ended = true;
        return bridge.mutex.unlock(io);
    }
    removeAndUnlock(io, registration);
}

fn findLocked(id: u64) ?*Registration {
    for (bridge.registrations.items) |item| {
        if (item.id == id) return item;
    }
    return null;
}

/// `unregister` with the bridge mutex held. Returns with it released.
fn removeAndUnlock(io: std.Io, registration: *Registration) void {
    registration.removing = true;
    applyLocked(mcp_call.step(bridge.state, .{ .owner_removed = registration.owner }));
    while (registration.borrowing > 0 or registration.serving > 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
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
        accept_task = bridge.accept_task;
        bridge.accept_task = null;
    }
    bridge.mutex.unlock(io);
    gpa.destroy(registration);
    if (!last) return;
    // The accept loop sees `stop` within a poll; after it ends nothing adds
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
    bridge.listener = listener;
    bridge.stop.store(false, .release);
    bridge.accept_task = std.Io.concurrent(io, acceptLoop, .{}) catch |err| {
        bridge.listener = null;
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

fn closeListenerLocked(io: std.Io) void {
    if (bridge.listener) |*listener| listener.deinit(io);
    bridge.listener = null;
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
/// serving task's own: cancels, withdrawals, logs, and the checks a lend
/// starts for requests that waited. A request being admitted is not in
/// `bridge.live` yet, so its own `authorize` or `wait` stays with its task.
fn applyLocked(out: mcp_call.Output) void {
    bridge.state = out.state;
    var woke = false;
    for (out.effects()) |effect| switch (effect) {
        .cancel => |id| {
            for (bridge.live.items) |live| {
                if (live.id == id) live.cancel.store(true, .release);
            }
        },
        .withdraw => |id| {
            for (bridge.live.items) |live| {
                if (live.id != id) continue;
                live.withdrawn = true;
                woke = true;
            }
            debug_trace.logf("mcp-call", "request={d} client or owner gone; its permission prompt stays until answered, and nothing runs", .{@backingInt(id)});
        },
        // A lend moved a waiting request on. It borrows the new lender now,
        // under the same lock, so that lender cannot return before it does.
        .authorize => |work| {
            const registration = ownerLocked(work.owner) orelse continue;
            for (bridge.live.items) |live| {
                if (live.id != work.id) continue;
                live.authorized = true;
                live.lender = registration.lender;
                registration.borrowing += 1;
                woke = true;
            }
        },
        .log => |log| debug_trace.logf("mcp-call", "request={d} dropped={s}", .{ @backingInt(log.id), @tagName(log.drop) }),
        .refuse, .wait, .call, .reply => {},
    };
    if (woke) bridge.changed.broadcast(io_mod.getIo());
}

fn ownerLocked(owner: mcp_call.OwnerId) ?*Registration {
    for (bridge.registrations.items) |item| {
        if (item.owner == owner) return item;
    }
    return null;
}

fn step(event: mcp_call.Event) mcp_call.Output {
    const out = mcp_call.step(bridge.state, event);
    applyLocked(out);
    return out;
}

fn acceptLoop() void {
    const io = io_mod.getIo();
    const listener = &bridge.listener.?;
    while (!bridge.stop.load(.acquire)) {
        var fds = [_]posix.pollfd{.{ .fd = listener.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, poll_ms) catch |err| {
            debug_trace.logf("mcp-call", "bridge accept loop ended err={s}", .{@errorName(err)});
            return;
        };
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
        .closed => "The command that started this call has ended, or its fx session has. Run fx mcp call from a command fx's shell tool runs.",
        .unauthorized => "This command was not started by fx's shell tool, or the command that started it has ended. Run fx mcp call from a command fx's shell tool runs.",
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
    const Admission = union(enum) {
        /// A shell call lends to the owner: the check starts now.
        now: mcp_call.Work,
        /// None does: the request waits for one.
        later: mcp_call.Work,
    };
    const admission: Admission = for (admitted.effects()) |effect| switch (effect) {
        .authorize => |value| break .{ .now = value },
        .wait => |value| break .{ .later = value },
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
    const work = switch (admission) {
        inline else => |value| value,
    };
    registration = ownerLocked(work.owner) orelse unreachable; // the core admits only registered owners
    live = .{ .id = work.id };
    if (admission == .now) {
        live.lender = registration.lender;
        registration.borrowing += 1;
    }
    bridge.live.appendAssumeCapacity(&live);
    registration.serving += 1;
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
        if (live.lender != null) registration.borrowing -= 1;
        registration.serving -= 1;
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

    const request_id = arena.print("fx-mcp-call-{d}", .{@backingInt(work.id)}) catch "fx-mcp-call";
    // No shell call watches the command now, as after its run call yielded:
    // the request waits for the next one, or for its client or command to
    // end. Like a permission prompt, it has no deadline.
    if (admission == .later) {
        bridge.mutex.lockUncancelable(io);
        while (!live.authorized and !live.withdrawn) bridge.changed.waitUncancelable(io, &bridge.mutex);
        const started = live.authorized and !live.withdrawn;
        const owner_gone = registration.removing;
        bridge.mutex.unlock(io);
        if (!started) {
            debug_trace.logf("mcp-call", "request={d} ended while it waited for a shell call to watch its command; nothing ran", .{@backingInt(work.id)});
            bridge.mutex.lockUncancelable(io);
            _ = step(.{ .authorized = .{ .id = work.id, .decision = .deny } });
            bridge.mutex.unlock(io);
            if (owner_gone) _ = writeReply(stream, .refused, .closed, refusalMessage(.closed));
            return;
        }
    }
    const capability = live.lender.?;

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
        _ = .{ request_id, allowed, cancel };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
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

/// A command's `fx mcp call` on its own thread, as a blocked command's is.
const Caller = struct {
    socket: []const u8,
    token: mcp_call.Token,
    done: std.atomic.Value(bool) = .init(false),
    /// The reply's status, or null when the call ended without one, as
    /// when the bridge had already closed.
    status: ?wire.Status = null,
    reason: ?wire.Reason = null,
    thread: ?std.Thread = null,

    fn start(self: *Caller) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Caller) void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena_state.deinit();
        if (client.call(arena_state.allocator(), std.testing.io, self.socket, self.token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } })) |reply| {
            self.status = reply.header.status;
            self.reason = reply.header.reason;
        } else |_| {}
        self.done.store(true, .release);
    }

    fn join(self: *Caller) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

fn callerFor(arena: Allocator, registration: *const Registration) !Caller {
    const variables = registration.environment();
    return .{ .socket = try arena.dupe(u8, variables[0].value), .token = wire.parseToken(variables[1].value).? };
}

/// The requests the core holds waiting for a lender.
fn waitingCount() usize {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    var count: usize = 0;
    for (bridge.state.slots) |slot| {
        if (slot) |entry| if (entry.stage == .waiting) {
            count += 1;
        };
    }
    return count;
}

fn waitForWaiting(want: usize) !void {
    var waited: u32 = 0;
    while (waitingCount() != want) : (waited += 1) {
        if (waited > 1000) return error.TestTimedOut;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
}

fn bridgeIsIdle() bool {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    return bridge.phase == .idle and bridge.registrations.items.len == 0 and bridge.live.items.len == 0 and bridge.connections == 0;
}

test "a command's call waits while no shell call lends to it, and runs as the next one that does" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var run_tool: FakeTool = .{};
    var watch_tool: FakeTool = .{};
    const registration = try register(run_tool.capability());
    const id = registration.id;
    var caller = try callerFor(arena_state.allocator(), registration);
    // The run call returns while the command runs on.
    release(registration);
    try caller.start();
    try waitForWaiting(1);
    // Nothing asks a permission check while no shell call watches, and the
    // next watcher's wait holds for the call.
    io_mod.sleep(4 * poll_ms * std.time.ns_per_ms);
    try std.testing.expect(!run_tool.authorizing.load(.acquire) and !watch_tool.authorizing.load(.acquire));
    try std.testing.expect(!caller.done.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), registration.hold.load(.acquire));
    // An interact lends: the call runs as that call, and only once.
    const lent = lend(id, watch_tool.capability()).?;
    caller.join();
    try std.testing.expectEqual(wire.Status.ok, caller.status.?);
    try std.testing.expectEqual(@as(u32, 1), watch_tool.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), run_tool.calls.load(.acquire));
    // A second watcher while one lends lends nothing.
    try std.testing.expect(lend(id, run_tool.capability()) == null);
    release(lent);
    commandEnded(id);
    try std.testing.expect(bridgeIsIdle());
    // A late notice, or a lend after the end, finds nothing.
    commandEnded(id);
    try std.testing.expect(lend(id, watch_tool.capability()) == null);
}

test "a lend ends only after the call it lent to does, and a command that ended meanwhile ends then" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    tool.gate.store(true, .release);
    const registration = try register(tool.capability());
    var caller = try callerFor(arena_state.allocator(), registration);
    try caller.start();
    try waitFor(&tool.authorizing);
    // The command ends while the run call still holds it: the owner stays
    // until that call lets go.
    commandEnded(registration.id);
    try std.Io.Dir.cwd().access(std.testing.io, caller.socket, .{});
    const Releaser = struct {
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), held: *Registration) void {
            release(held);
            self.done.store(true, .release);
        }
    };
    var releaser: Releaser = .{};
    const thread = try std.Thread.spawn(.{}, Releaser.run, .{ &releaser, registration });
    io_mod.sleep(4 * poll_ms * std.time.ns_per_ms);
    // The permission check still borrows the returning call's capability.
    try std.testing.expect(!releaser.done.load(.acquire));
    tool.gate.store(false, .release);
    caller.join();
    thread.join();
    try std.testing.expectEqual(wire.Status.ok, caller.status.?);
    try std.testing.expectEqual(@as(u32, 1), tool.calls.load(.acquire));
    try std.testing.expect(bridgeIsIdle());
}

test "a waiting call whose client leaves, or whose command ends, runs no check" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    const id = registration.id;
    var caller = try callerFor(arena_state.allocator(), registration);
    release(registration);
    // A client sends its request and leaves while it waits.
    const address = try std.Io.net.UnixAddress.init(caller.socket);
    const stream = try address.connect(io);
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try wire.writeRequest(&writer.interface, caller.token, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try writer.interface.flush();
    try waitForWaiting(1);
    stream.close(io);
    try waitForWaiting(0);
    // Another waits until its command ends, and is told so.
    try caller.start();
    try waitForWaiting(1);
    commandEnded(id);
    caller.join();
    try std.testing.expectEqual(wire.Status.refused, caller.status.?);
    try std.testing.expectEqual(wire.Reason.closed, caller.reason.?);
    try std.testing.expect(!tool.authorizing.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
    try std.testing.expect(bridgeIsIdle());
}

test "an interact on one command serves only that command's waiting call" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var first_tool: FakeTool = .{};
    var second_tool: FakeTool = .{};
    const first = try register(first_tool.capability());
    const second = try register(second_tool.capability());
    const first_id = first.id;
    const second_id = second.id;
    var first_caller = try callerFor(arena_state.allocator(), first);
    var second_caller = try callerFor(arena_state.allocator(), second);
    release(first);
    release(second);
    try first_caller.start();
    try second_caller.start();
    try waitForWaiting(2);
    const lent = lend(first_id, first_tool.capability()).?;
    first_caller.join();
    try std.testing.expectEqual(wire.Status.ok, first_caller.status.?);
    try waitForWaiting(1);
    try std.testing.expect(!second_caller.done.load(.acquire));
    try std.testing.expect(!second_tool.authorizing.load(.acquire));
    release(lent);
    commandEnded(second_id);
    second_caller.join();
    try std.testing.expectEqual(wire.Reason.closed, second_caller.reason.?);
    try std.testing.expectEqual(@as(u32, 0), second_tool.calls.load(.acquire));
    commandEnded(first_id);
    try std.testing.expect(bridgeIsIdle());
}

/// Rounds of racing lends, releases, command ends, and calls, each round
/// seeded so a failure replays. Every call ends, each one that ran was
/// answered `ok`, and the bridge is idle after every round.
fn raceRounds(rounds: usize, commands: usize, callers_per_command: usize, seed: u64) !void {
    const Lender = struct {
        fn run(ids: []const u64, tool: *FakeTool, round_seed: u64, stop: *std.atomic.Value(bool)) void {
            var prng = std.Random.DefaultPrng.init(round_seed);
            const random = prng.random();
            while (!stop.load(.acquire)) {
                const id = ids[random.uintLessThan(usize, ids.len)];
                if (lend(id, tool.capability())) |registration| {
                    io_mod.sleep(random.uintLessThan(u64, 3 * std.time.ns_per_ms));
                    release(registration);
                }
                io_mod.sleep(random.uintLessThan(u64, std.time.ns_per_ms));
            }
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..rounds) |round| {
        _ = arena_state.reset(.retain_capacity);
        var tool: FakeTool = .{};
        const ids = try arena.alloc(u64, commands);
        const callers = try arena.alloc(Caller, commands * callers_per_command);
        for (ids, 0..) |*id, index| {
            const registration = try register(tool.capability());
            id.* = registration.id;
            for (callers[index * callers_per_command ..][0..callers_per_command]) |*caller| caller.* = try callerFor(arena, registration);
            release(registration);
        }
        for (callers) |*caller| try caller.start();
        var stop = std.atomic.Value(bool).init(false);
        const lenders = [_]std.Thread{
            try std.Thread.spawn(.{}, Lender.run, .{ ids, &tool, seed +% round *% 2 +% 1, &stop }),
            try std.Thread.spawn(.{}, Lender.run, .{ ids, &tool, seed +% round *% 2 +% 2, &stop }),
        };
        // The commands end in a random order, at random moments.
        const order = try arena.dupe(u64, ids);
        random.shuffle(u64, order);
        for (order) |id| {
            io_mod.sleep(random.uintLessThan(u64, 4 * std.time.ns_per_ms));
            commandEnded(id);
        }
        stop.store(true, .release);
        for (lenders) |thread| thread.join();
        var answered_ok: u32 = 0;
        for (callers) |*caller| {
            caller.join();
            if (caller.status == .ok) answered_ok += 1;
        }
        std.testing.expectEqual(answered_ok, tool.calls.load(.acquire)) catch |err| {
            std.debug.print("race round {d} (seed {d}) answered {d} ok for {d} calls\n", .{ round, seed, answered_ok, tool.calls.load(.acquire) });
            return err;
        };
        if (!bridgeIsIdle()) {
            std.debug.print("race round {d} (seed {d}) left the bridge busy\n", .{ round, seed });
            return error.TestUnexpectedResult;
        }
    }
}

test "racing lends, releases, command ends, and calls leave every call answered and the bridge idle" {
    if (!supported) return error.SkipZigTest;
    // FX_MCP_CALL_STRESS=1 runs ten times the rounds, with 16 commands of 4
    // callers each, well past the bridge's 8 slots.
    var environ = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer environ.deinit();
    if (environ.get("FX_MCP_CALL_STRESS") != null) return raceRounds(400, 16, 4, 20261110);
    try raceRounds(40, 4, 2, 20261110);
}

/// One core event from fuzzed bytes, over two owners, three tokens, and a
/// small id range, so lends, late answers, and garbage ones come often.
fn fuzzedEvent(smith: *std.testing.Smith) mcp_call.Event {
    const tokens = [_]mcp_call.Token{ @splat(0x11), @splat(0x22), @splat(0xff) };
    const owner: mcp_call.OwnerId = if (smith.valueRangeAtMost(u8, 0, 7) == 0) .main else @fromBackingInt(1);
    const id: mcp_call.RequestId = @fromBackingInt(smith.valueRangeAtMost(u64, 0, 7));
    return switch (smith.valueRangeAtMost(u8, 0, 11)) {
        0 => .{ .started = tokens[smith.valueRangeAtMost(u8, 0, 1)] },
        1 => .stopped,
        2 => .{ .owner_added = .{ .owner = owner, .token = tokens[smith.valueRangeAtMost(u8, 0, 1)] } },
        3 => .{ .owner_removed = owner },
        4 => .{ .lent = owner },
        5 => .{ .lend_ended = owner },
        6, 7 => .{ .request = .{ .token = tokens[smith.valueRangeAtMost(u8, 0, 2)], .version = if (smith.valueRangeAtMost(u8, 0, 4) == 0) 2 else 1 } },
        8 => .{ .authorized = .{ .id = id, .decision = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .allow else .deny } },
        9 => .{ .call_finished = .{ .id = id, .outcome = switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => .ok,
            1 => .tool_error,
            else => .failed,
        } } },
        10 => .{ .reply_done = .{ .id = id, .delivery = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .delivered else .lost } },
        else => .{ .client_gone = id },
    };
}

fn stageIn(state: *const mcp_call.State, id: mcp_call.RequestId) ?mcp_call.Stage {
    for (state.slots) |slot| {
        if (slot) |entry| if (entry.id == id) return entry.stage;
    }
    return null;
}

fn ownerIn(state: *const mcp_call.State, owner: mcp_call.OwnerId) ?mcp_call.Owner {
    for (state.owners) |slot| {
        if (slot) |registered| if (registered.id == owner) return registered;
    }
    return null;
}

/// The lend laws of `tests/tla/mcp_call/spec/McpCall.tla` after every step
/// of a fuzzed sequence: AuthorizeOnlyWhileLent, WaitingOnlyUnlent, and the
/// bounds and one-call-per-request laws they lean on.
fn fuzzLendLaws(_: void, smith: *std.testing.Smith) !void {
    var state = mcp_call.State.init(2);
    var called: [64]bool = @splat(false);
    var steps: usize = 0;
    while (steps < 64 and !smith.eos()) : (steps += 1) {
        const before = state;
        const event = fuzzedEvent(smith);
        const out = mcp_call.step(state, event);
        state = out.state;
        try std.testing.expect(out.len <= state.capacity);
        var held: usize = 0;
        for (state.slots) |slot| {
            const entry = slot orelse continue;
            held += 1;
            try std.testing.expect(@backingInt(entry.id) < state.next);
            const owner = ownerIn(&state, entry.owner);
            switch (entry.stage) {
                .waiting => try std.testing.expect(owner != null and !owner.?.lent),
                .authorizing, .calling => try std.testing.expect(owner != null),
                .replying, .abandoned_auth, .abandoned_call => {},
            }
        }
        try std.testing.expect(held <= state.capacity);
        for (out.effects()) |effect| switch (effect) {
            .authorize => |work| {
                try std.testing.expect(ownerIn(&state, work.owner).?.lent);
                try std.testing.expectEqual(mcp_call.Stage.authorizing, stageIn(&state, work.id).?);
                if (event == .request) {
                    try std.testing.expectEqual(before.next, @backingInt(work.id));
                } else {
                    try std.testing.expect(event == .lent);
                    try std.testing.expectEqual(mcp_call.Stage.waiting, stageIn(&before, work.id).?);
                }
            },
            .wait => |work| {
                try std.testing.expect(event == .request);
                try std.testing.expectEqual(before.next, @backingInt(work.id));
                try std.testing.expect(!ownerIn(&state, work.owner).?.lent);
            },
            .call => |work| {
                try std.testing.expect(event == .authorized and event.authorized.decision == .allow);
                try std.testing.expectEqual(mcp_call.Stage.authorizing, stageIn(&before, work.id).?);
                const n: usize = @intCast(@backingInt(work.id));
                try std.testing.expect(!called[n]);
                called[n] = true;
            },
            .refuse, .withdraw, .cancel, .reply, .log => {},
        };
    }
}

test "the bridge core keeps its lend laws on fuzzed event sequences" {
    try std.testing.fuzz({}, fuzzLendLaws, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
            "lend, end the lend, and lend again while calls wait",
        }) ++ @import("fuzz_corpus").mcp_call_lend.*),
    });
}

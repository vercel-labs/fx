//! The `fx mcp call` bridge: the shell around the pure core in
//! `core.zig`. A command that fx's shell tool runs can call the
//! session's MCP tools through it, so a large result can go to a file
//! instead of into the model's context.
//!
//! Each running shell call registers as an owner with its own token and
//! lends the bridge its permission check and MCP call
//! (`capability.zig`), so a call meets the same rules,
//! prompt, review, and access as a direct one by the same agent. The bridge
//! listens on one Unix socket in a private directory while any shell call is
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
const capability_mod = @import("capability.zig");
const edit_blocks = @import("edit_blocks.zig");
const mcp_call = @import("core.zig");
const wire = @import("wire.zig");

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

/// One running shell call, registered as an owner.
pub const Registration = struct {
    owner: mcp_call.OwnerId,
    capability: capability_mod.Capability,
    /// The owner's requests the bridge is working on. While above zero the
    /// shell call does not yield (`managed_execution` `yield_hold`).
    hold: std.atomic.Value(u32) = .init(0),
    /// Requests whose work borrows `capability`. Guarded by the bridge mutex.
    in_use: u32 = 0,
    token_hex: [wire.token_hex_len]u8,
    variables: [2]command_runner.EnvironmentVariable = undefined,

    /// The variables a command needs to reach the bridge as this owner.
    /// Valid until `unregister`.
    pub fn environment(self: *const Registration) []const command_runner.EnvironmentVariable {
        return &self.variables;
    }
};

/// The names of the variables `Registration.environment` adds to a command. The
/// bash session never saves these variables, so each name is listed for it.
pub const variable_names = [_][]const u8{ wire.socket_env, wire.token_env };

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
    /// Requests the core admitted in this run. A test waits for them.
    admitted: u32 = 0,
    /// Requests the core withdrew while they waited for their permission check.
    /// A test waits for them.
    withdrawn: u32 = 0,
};

var bridge: Bridge = .{};

/// Registers a running shell call, starting the bridge if this is the
/// first. The caller must `unregister` before `capability` goes away.
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

/// Ends a shell call's registration: its token is revoked, a running call
/// is cancelled, and a waiting prompt stays until it is answered. Returns
/// once nothing borrows its capability. Stops the bridge after the last one.
pub fn unregister(registration: *Registration) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
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
        if (bridge.wake) |wake| writeWakeByte(wake[1]);
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
    bridge.admitted = 0;
    bridge.withdrawn = 0;
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
    applyLocked(mcp_call.step(bridge.state, .{ .started = main_token }));
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
/// serving task's own: cancels, withdrawals, and logs.
fn applyLocked(out: mcp_call.Output) void {
    bridge.state = out.state;
    for (out.effects()) |effect| switch (effect) {
        .cancel => |id| {
            for (bridge.live.items) |live| {
                if (live.id == id) live.cancel.store(true, .release);
            }
        },
        .authorize => {
            bridge.admitted += 1;
            bridge.changed.broadcast(io_mod.getIo());
        },
        .withdraw => |id| {
            bridge.withdrawn += 1;
            bridge.changed.broadcast(io_mod.getIo());
            debug_trace.logf("mcp-call", "request={d} client or owner gone; nothing runs, and a permission prompt that is already open stays until answered", .{@backingInt(id)});
        },
        .log => |log| debug_trace.logf("mcp-call", "request={d} dropped={s}", .{ @backingInt(log.id), @tagName(log.drop) }),
        .refuse, .call, .reply => {},
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
}

const ReadError = error{ TooLarge, Silent, Closed, ReadFailed, OutOfMemory, Canceled };

/// Reads one request line within the deadline, without its newline. Ends
/// with `error.Canceled` when the bridge stops first: the wake byte that
/// `unregister` writes ends the wait at once.
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
        .closed => "The fx session's shell call that started this command has ended. Run fx mcp call from a command in a new shell call.",
        .unauthorized => "This command was not started by a running fx shell call, or that call has ended. Run fx mcp call from a command fx's shell tool runs, not from one left running in the background.",
        .unsupported_version => "This fx mcp call is from another fx version than the running session. Run the fx that started the session, or restart the session with this one.",
        .busy => "Too many fx mcp call requests are running in this session. Nothing ran; try again when one finishes.",
        .malformed => "The request was not an fx mcp call request. Send requests with the fx that started the session.",
        .too_large => "The request is over 1 MiB. Pass smaller arguments.",
        .file_tool_unavailable => "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, while that program runs.",
    };
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
            var probe: [1]u8 = undefined;
            const rc = std.c.recv(self.fd, &probe, 1, posix.MSG.PEEK | posix.MSG.DONTWAIT);
            const hung_up = (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0;
            if (rc == 0 or hung_up) {
                bridge.mutex.lockUncancelable(io);
                _ = step(.{ .client_gone = self.id });
                bridge.mutex.unlock(io);
                return;
            }
            // The client sent more than its one line: not ours to read. Log it once,
            // then wait on the wake byte alone, so the unread bytes do not spin this loop.
            if (!self.extra_logged) {
                self.extra_logged = true;
                if (rc < 0) {
                    debug_trace.logf("mcp-call", "request={d} disconnect watch could not peek the client err={s}; it checks again every 100 ms", .{ @backingInt(self.id), @tagName(posix.errno(rc)) });
                } else {
                    debug_trace.logf("mcp-call", "request={d} client sent bytes after its request line; the watch leaves them unread", .{@backingInt(self.id)});
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

// unregister awaits this task before closeListenerLocked closes wake_read.
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
    // Only the bash tool's programs get file changes. Another registration's
    // are denied as the core's deny, and the client is told why.
    const file_refused = switch (request.operation) {
        .edit, .write => registration.capability.authorize_file_fn == null,
        .call, .list, .search, .help => false,
    };
    const authorization: capability_mod.Authorization = if (file_refused) .{ .deny = refusalMessage(.file_tool_unavailable) } else switch (request.operation) {
        .call, .edit, .write => authorizeGated(io, registration, work.id, arena, request_id, request.operation),
        .list, .search, .help => .{ .allow = .{} },
    };
    bridge.mutex.lockUncancelable(io);
    const decided = step(.{ .authorized = .{ .id = work.id, .decision = if (authorization == .allow) .allow else .deny } });
    bridge.mutex.unlock(io);

    var reply: ?struct { status: wire.Status, reason: ?wire.Reason = null, bytes: []const u8 } = null;
    for (decided.effects()) |effect| switch (effect) {
        .call => {
            const outcome = runOperation(arena, registration.capability, request_id, request.operation, authorization.allow, &live.cancel) catch |err|
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
        .reply => {
            if (file_refused) {
                reply = .{ .status = .refused, .reason = .file_tool_unavailable, .bytes = authorization.deny };
            } else {
                reply = .{ .status = .denied, .bytes = authorization.deny };
            }
        },
        else => {},
    };
    const answer = reply orelse return;
    const delivered = writeReply(stream, answer.status, answer.reason, answer.bytes);
    bridge.mutex.lockUncancelable(io);
    _ = step(.{ .reply_done = .{ .id = work.id, .delivery = if (delivered) .delivered else .lost } });
    bridge.mutex.unlock(io);
}

/// Decides a request that calls an MCP tool or changes a file. One permission
/// prompt runs at a time, so the request waits here for the prompt lock; if its
/// client left while it waited, no prompt opens for it.
fn authorizeGated(
    io: std.Io,
    registration: *Registration,
    id: mcp_call.RequestId,
    arena: Allocator,
    request_id: []const u8,
    operation: wire.Operation,
) capability_mod.Authorization {
    bridge.prompt.lockUncancelable(io);
    defer bridge.prompt.unlock(io);
    // The client may have left while this request waited for the lock. Then
    // no prompt opens for it, and the core frees its slot with the answer.
    bridge.mutex.lockUncancelable(io);
    const waiting = mcp_call.awaitingPermission(&bridge.state, id);
    bridge.mutex.unlock(io);
    if (!waiting) return .{ .deny = "The request left before its permission check." };
    const checked = switch (operation) {
        .call => |value| registration.capability.authorize(arena, request_id, value.tool, value.arguments_json),
        .edit => |value| registration.capability.authorizeFile(arena, request_id, .{ .edit = value }),
        .write => |value| registration.capability.authorizeFile(arena, request_id, .{ .write = value }),
        .list, .search, .help => unreachable, // lookups have no permission check
    };
    return checked catch |err| .{ .deny = arena.print("The permission check for {f} failed: {s}", .{ text_utils.terminalSafe(operation.subject()), @errorName(err) }) catch "The permission check failed." };
}

/// Runs an admitted request's work: its MCP call, its file change, or its lookup.
fn runOperation(
    arena: Allocator,
    capability: capability_mod.Capability,
    request_id: []const u8,
    operation: wire.Operation,
    allowed: @FieldType(capability_mod.Authorization, "allow"),
    cancel: *std.atomic.Value(bool),
) anyerror!capability_mod.CallOutcome {
    if (operation.lookup()) |question| return capability.lookup(arena, question, cancel);
    return switch (operation) {
        .call => |value| capability.call(arena, request_id, value.tool, value.arguments_json, allowed, cancel),
        // A file change's authority holds its call, so the tool and arguments are empty.
        .edit, .write => capability.call(arena, request_id, operation.subject(), "", allowed, cancel),
        .list, .search, .help => unreachable, // answered by the lookup above
    };
}

/// A capability whose permission check and call the test controls.
const FakeTool = struct {
    allow: bool = true,
    /// The permission check ends in an error instead of a decision.
    fail: bool = false,
    /// While set, the permission check waits, as for a prompt.
    gate: std.atomic.Value(bool) = .init(false),
    authorizing: std.atomic.Value(bool) = .init(false),
    /// Permission checks begun. Guarded by the bridge mutex, which signals each one.
    authorize_calls: u32 = 0,
    /// File permission checks begun. Guarded by the bridge mutex, like `authorize_calls`.
    file_authorize_calls: u32 = 0,
    calls: std.atomic.Value(u32) = .init(0),
    /// File changes run. The fake changes nothing.
    file_calls: std.atomic.Value(u32) = .init(0),
    /// The registration offers no file handler, as a shell command's does.
    no_files: bool = false,

    fn capability(self: *FakeTool) capability_mod.Capability {
        return .{ .context = @ptrCast(self), .authorize_fn = authorize, .authorize_file_fn = if (self.no_files) null else authorizeFile, .call_fn = run, .lookup_fn = lookup };
    }

    fn authorizeFile(raw: *anyopaque, arena: Allocator, request_id: []const u8, file: capability_mod.FileRequest) anyerror!capability_mod.Authorization {
        _ = .{ arena, request_id, file };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        self.authorizing.store(true, .release);
        const io = io_mod.getIo();
        bridge.mutex.lockUncancelable(io);
        self.file_authorize_calls += 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
        while (self.gate.load(.acquire)) io_mod.sleep(5 * std.time.ns_per_ms);
        if (self.fail) return error.PermissionCheckFailed;
        return if (self.allow) .{ .allow = .{ .prepared = @ptrCast(self) } } else .{ .deny = "Denied by the test." };
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
        const io = io_mod.getIo();
        bridge.mutex.lockUncancelable(io);
        self.authorize_calls += 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
        while (self.gate.load(.acquire)) io_mod.sleep(5 * std.time.ns_per_ms);
        if (self.fail) return error.PermissionCheckFailed;
        return if (self.allow) .{ .allow = .{} } else .{ .deny = "Denied by the test." };
    }

    fn run(raw: *anyopaque, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8, allowed: @FieldType(capability_mod.Authorization, "allow"), cancel: *std.atomic.Value(bool)) anyerror!capability_mod.CallOutcome {
        _ = .{ request_id, cancel };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        if (allowed.prepared != null) {
            _ = self.file_calls.fetchAdd(1, .acq_rel);
            return .{ .status = .ok, .bytes = try arena.print("file {s}\n", .{tool}) };
        }
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

const client = @import("client.zig");

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

test "a request that leaves while it waits for the prompt lock opens no prompt" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    tool.gate.store(true, .release);
    const registration = try register(tool.capability());
    var unregistered = false;
    // Declared first, so it runs last: the gate opens before unregister waits for the requests.
    defer if (!unregistered) unregister(registration);
    defer tool.gate.store(false, .release);
    const variables = registration.environment();
    const address = try std.Io.net.UnixAddress.init(variables[0].value);
    const token = wire.parseToken(variables[1].value).?;

    // Client A's call takes the prompt lock, and its permission check waits on the gate.
    const first = try address.connect(io);
    defer first.close(io);
    var first_buffer: [512]u8 = undefined;
    var first_writer = first.writer(io, &first_buffer);
    try wire.writeRequest(&first_writer.interface, token, .{ .call = .{ .tool = "mcp_s_first", .arguments_json = "{}" } });
    try first_writer.interface.flush();
    try waitAtLeast(io, &bridge.admitted, 1);
    try waitAtLeast(io, &tool.authorize_calls, 1);

    // Client B's call waits for that lock, and then its client leaves.
    const second = try address.connect(io);
    var second_buffer: [512]u8 = undefined;
    var second_writer = second.writer(io, &second_buffer);
    try wire.writeRequest(&second_writer.interface, token, .{ .call = .{ .tool = "mcp_s_second", .arguments_json = "{}" } });
    try second_writer.interface.flush();
    try waitAtLeast(io, &bridge.admitted, 2);
    second.close(io);
    try waitAtLeast(io, &bridge.withdrawn, 1);

    // A's prompt answers now, and B is withdrawn, so it must not open a prompt when the
    // lock is free. Wait for both requests to end: a stop would withdraw A first.
    tool.gate.store(false, .release);
    try waitAtMost(io, &registration.in_use, 0);
    unregister(registration);
    unregistered = true;
    try std.testing.expectEqual(@as(u32, 1), tool.authorize_calls);
    try std.testing.expectEqual(@as(u32, 1), tool.calls.load(.acquire));

    var read_buffer: [wire.max_header_bytes]u8 = undefined;
    var reader = first.reader(io, &read_buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.TestUnexpectedResult;
    const header = try wire.parseHeader(arena, line);
    try std.testing.expectEqual(wire.Status.ok, header.status);
    const bytes = try reader.interface.readAllocAll(arena, @intCast(header.bytes));
    try std.testing.expectEqualStrings("mcp_s_first {}\n", bytes);
}

test "an edit and a write go through their permission check, then their call" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    defer unregister(registration);
    const variables = registration.environment();
    const socket_path = variables[0].value;
    const token = wire.parseToken(variables[1].value).?;
    const blocks = [_]edit_blocks.Edit{
        .{ .search = "a\n", .replace = "b\n" },
        .{ .search = "c\n", .replace = "" },
    };

    const edit = try client.call(arena, std.testing.io, socket_path, token, .{ .edit = .{ .path = "notes.txt", .blocks = &blocks } });
    try std.testing.expectEqual(wire.Status.ok, edit.header.status);
    try std.testing.expectEqualStrings("file notes.txt\n", edit.bytes);

    const write = try client.call(arena, std.testing.io, socket_path, token, .{ .write = .{ .path = "new.txt", .content = "" } });
    try std.testing.expectEqual(wire.Status.ok, write.header.status);
    try std.testing.expectEqualStrings("file new.txt\n", write.bytes);

    try std.testing.expectEqual(@as(u32, 2), fileAuthorizeCount(std.testing.io, &tool));
    try std.testing.expectEqual(@as(u32, 2), tool.file_calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a file change on a registration with no file handler is refused as fx tool's, and no check runs" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{ .no_files = true };
    const registration = try register(tool.capability());
    defer unregister(registration);
    const variables = registration.environment();
    const socket_path = variables[0].value;
    const token = wire.parseToken(variables[1].value).?;
    const blocks = [_]edit_blocks.Edit{.{ .search = "a\n", .replace = "b\n" }};

    const edit = try client.call(arena, std.testing.io, socket_path, token, .{ .edit = .{ .path = "notes.txt", .blocks = &blocks } });
    try std.testing.expectEqual(wire.Status.refused, edit.header.status);
    try std.testing.expectEqual(wire.Reason.file_tool_unavailable, edit.header.reason.?);
    const write = try client.call(arena, std.testing.io, socket_path, token, .{ .write = .{ .path = "new.txt", .content = "x" } });
    try std.testing.expectEqual(wire.Reason.file_tool_unavailable, write.header.reason.?);

    try std.testing.expectEqual(@as(u32, 0), fileAuthorizeCount(std.testing.io, &tool));
    try std.testing.expectEqual(@as(u32, 0), tool.file_calls.load(.acquire));
}

test "an edit whose client leaves while its permission check waits applies nothing" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    tool.gate.store(true, .release);
    const registration = try register(tool.capability());
    var unregistered = false;
    // Declared first, so it runs last: the gate opens before unregister waits for the requests.
    defer if (!unregistered) unregister(registration);
    defer tool.gate.store(false, .release);
    const variables = registration.environment();
    const address = try std.Io.net.UnixAddress.init(variables[0].value);
    const blocks = [_]edit_blocks.Edit{.{ .search = "a\n", .replace = "b\n" }};
    const stream = try address.connect(io);
    errdefer stream.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try wire.writeRequest(&writer.interface, wire.parseToken(variables[1].value).?, .{ .edit = .{ .path = "notes.txt", .blocks = &blocks } });
    try writer.interface.flush();
    try waitAtLeast(io, &tool.file_authorize_calls, 1);

    // The check waits on the gate, as for a prompt. The client leaves, and the
    // request is withdrawn, so the change must never run.
    stream.close(io);
    try waitAtLeast(io, &bridge.withdrawn, 1);
    tool.gate.store(false, .release);
    try waitAtMost(io, &registration.in_use, 0);
    unregister(registration);
    unregistered = true;
    try std.testing.expectEqual(@as(u32, 0), tool.file_calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

/// The file permission checks a fake tool has begun, read under the bridge mutex.
fn fileAuthorizeCount(io: std.Io, tool: *const FakeTool) u32 {
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    return tool.file_authorize_calls;
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

/// Waits until a counter on the bridge has moved past zero, or fails after five
/// seconds. A timed wait on the bridge's condition, not a sleep.
fn waitForCount(io: std.Io, count: *const u32) !void {
    return waitAtLeast(io, count, 1);
}

/// Waits until a counter on the bridge reaches `at_least`, or fails after five
/// seconds. A timed wait on the bridge's condition, not a sleep.
fn waitAtLeast(io: std.Io, count: *const u32, at_least: u32) !void {
    return waitUntil(io, count, at_least, true);
}

/// Waits until a counter on the bridge falls to `at_most` or less, or fails after
/// five seconds. A timed wait on the bridge's condition, not a sleep.
fn waitAtMost(io: std.Io, count: *const u32, at_most: u32) !void {
    return waitUntil(io, count, at_most, false);
}

fn waitUntil(io: std.Io, count: *const u32, limit: u32, rising: bool) !void {
    const deadline = io_mod.milliTimestamp() + 5_000;
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    while (if (rising) count.* < limit else count.* > limit) {
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
        unregister(registration);
        return err;
    };
    const started = io_mod.milliTimestamp();
    unregister(registration);
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
        unregister(registration);
        return err;
    };
    const started = io_mod.milliTimestamp();
    unregister(registration);
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
    errdefer if (!stopped) unregister(registration);
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
    unregister(registration);
    // unregister waits for this request's watch to end, which needs the watch's
    // wake byte. Without it the watch would wait out wake_safety_poll_ms (1000 ms).
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
    try std.testing.expectEqual(@as(u32, 0), bridge.connections);
}

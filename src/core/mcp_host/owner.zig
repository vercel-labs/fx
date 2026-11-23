//! The MCP owner process: one per profile, running every shared server once
//! for all fx sessions (`tests/tla/mcp_host/SharedServers.tla`). It is started
//! detached as `fx --fx-internal-mcp-owner <fx_home>` (`run`), or on a thread
//! by a test (`serve`).
//!
//! It takes an advisory lock under `<fx_home>/run`, and a second owner that
//! finds the lock taken exits at once. Holding it, it listens on a private
//! socket and runs one `owner_core.zig` route table and one `mcp.engine` with
//! the idle gate, one slot per share key. A reader thread turns each client's
//! frames into events and a writer thread drains a bounded queue per client.
//! When its last client leaves, the route table disconnects the server of
//! every key it alone held, and 500 ms later the owner exits: close the
//! listening socket, delete the socket file, then release the lock. SIGTERM
//! and the `stop` flag end it the same way, and the engine's deinit stops
//! every server it still runs.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp = @import("../../mcp/mcp.zig");
const core = @import("owner_core.zig");
const wire = @import("owner_wire.zig");
const idle_control = @import("idle_control.zig");

const Allocator = std.mem.Allocator;
const engine = mcp.engine;

/// The internal mode's flag; exactly one argument follows it, fx's home.
pub const mode = "--fx-internal-mcp-owner";
pub const run_dir_name = "run";
pub const socket_name = "mcp-owner-v1.sock";
pub const lock_name = "mcp-owner-v1.lock";
/// How long the owner waits for a client to reconnect after the last one left.
pub const exit_grace_ms: i64 = 500;
const poll_ms = 20;

/// The most shell events waiting for the owner loop. A session that sends
/// frames faster than the loop takes them loses its own connection rather
/// than growing this list without a limit.
const max_pending_events: usize = 4096;

pub fn isModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), mode);
}

var signal_stop = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    signal_stop.store(true, .release);
}

fn installSignals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

/// The process entry. It detaches from the session that started it, never
/// pins a repository's directory, and serves until it is stopped.
pub fn run(alloc: Allocator, fx_home: []const u8, client_version: []const u8) !void {
    _ = std.c.setsid();
    // The owner must not hold a repo's directory after its last session ends.
    _ = std.c.chdir("/");
    installSignals();
    var stop = std.atomic.Value(bool).init(false);
    serve(io_mod.getIo(), alloc, fx_home, &stop, client_version) catch |err| switch (err) {
        // Another owner is alive, or still exiting and holding the lock.
        error.LockBusy => return,
        else => return err,
    };
}

/// A frame a reader keeps until its event is stepped; strings it carries are
/// owned, because the frame's arena goes before the owner thread reads them.
const ShellEvent = union(enum) {
    core: core.Event,
    /// A registration, with the config it will run: kept until the route
    /// table accepts the key, because a refused key stores nothing.
    register: struct { registered: core.Registered, config: OwnedConfig },
    call: struct { client: core.ClientId, id: u32, key: core.Key, tool: []u8, arguments: ?[]u8 },
    respond: struct { client: core.ClientId, id: u32, values: []u8 },
    answer: struct { client: core.ClientId, key: core.Key, slot: u8, n: u32, action: mcp.elicitation.Action, content: ?[]u8 },

    fn event(e: *const ShellEvent) core.Event {
        return switch (e.*) {
            .core => |only| only,
            .register => |register| .{ .registered = register.registered },
            .call => |call| .{ .call = .{ .client = call.client, .id = call.id, .key = call.key, .tool = call.tool, .arguments = call.arguments } },
            .respond => |respond| .{ .respond = .{ .client = respond.client, .id = respond.id, .values = respond.values } },
            .answer => |answer| .{ .answer = .{ .client = answer.client, .key = answer.key, .slot = answer.slot, .n = answer.n, .action = answer.action, .content = answer.content } },
        };
    }

    /// The config this event carried, when the route table took its key
    /// (`register_slot`): the only case that stores one.
    fn acceptedConfig(e: *ShellEvent, effects: []const core.Effect) ?*OwnedConfig {
        const register = switch (e.*) {
            .register => |*r| r,
            else => return null,
        };
        for (effects) |effect| switch (effect) {
            .register_slot => |slot| {
                if (std.mem.eql(u8, &slot.key, &register.registered.key)) return &register.config;
            },
            else => {},
        };
        return null;
    }

    fn deinit(e: *ShellEvent, gpa: Allocator) void {
        switch (e.*) {
            .core => {},
            .register => |*register| register.config.deinit(gpa),
            .call => |call| {
                gpa.free(call.tool);
                if (call.arguments) |arguments| gpa.free(arguments);
            },
            .respond => |respond| gpa.free(respond.values),
            .answer => |answer| if (answer.content) |content| gpa.free(content),
        }
        e.* = undefined;
    }
};

const Connection = struct {
    owner: *Owner,
    /// Set before the connection is in the table, so a reader that finds it
    /// there sees it whole.
    id: core.ClientId,
    stream: std.Io.net.Stream,
    /// This connection's reader and writer, as tasks of its own group: the
    /// owner cancels and awaits both to end a connection, and a task that
    /// cannot start lets the one that did end the same way.
    tasks: std.Io.Group = .init,
    /// How many of its tasks still run. Atomic, and the only lifetime field
    /// read off `o.mutex`: each task drops it as it ends.
    running: std.atomic.Value(u8) = .init(0),
    /// Guards everything below on this connection: the queue, its byte count,
    /// `closed`, and `gone`. Every thread that touches them holds it.
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty,
    queued_bytes: usize = 0,
    closed: bool = false,
    /// Set once, so the route table hears about the close once.
    gone: bool = false,
    /// The route table applied this client's leave. Only the owner loop writes
    /// it, and only while it holds `Owner.mutex`, which is also how the reaper
    /// reads it.
    left_applied: bool = false,
    /// The owner loop ended this connection's tasks, once, after it took the
    /// client out of the route table. Written only by the loop, under
    /// `Owner.mutex`, so a second leave ends nothing twice.
    cancelled: bool = false,

    fn endTask(c: *Connection) void {
        _ = c.running.fetchSub(1, .acq_rel);
    }
};

const Owner = struct {
    io: std.Io,
    gpa: Allocator,
    stop: *std.atomic.Value(bool),
    /// The fx version every server this owner runs is told, the one a session
    /// that runs its own copy sends, so sharing changes nothing a server sees.
    client_version: []const u8,
    /// Test seam: makes the next connection's reader or writer task fail to
    /// start, so the path that hands the connection to the reaper runs. Null
    /// in the owner.
    fail_task_start: ?Task = null,
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(ShellEvent) = .empty,
    connections: [core.max_clients]?*Connection = @splat(null),
    open: u32 = 0,
    last_open_ms: i64 = 0,
    /// Each registered key's config, owned here until the owner exits.
    /// Readers add one from their own threads, so `configs_mutex` guards
    /// every look and change; the owner loop reads under it too, since a put
    /// may rehash and move the entries.
    configs: std.array_hash_map.String(OwnedConfig) = .empty,
    configs_mutex: std.Io.Mutex = .init,
    /// The engine's configs, in slot order. Their strings live in
    /// `engine_arena`, because the scratch arena that builds one is reset
    /// before the next event.
    engine_configs: std.ArrayList(engine.Config) = .empty,
    engine_arena: std.heap.ArenaAllocator,

    fn stopping(o: *Owner) bool {
        return o.stop.load(.acquire) or signal_stop.load(.acquire);
    }

    fn now(o: *const Owner) i64 {
        _ = o;
        return std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds();
    }

    fn push(o: *Owner, event: ShellEvent) void {
        var dropped = event;
        // A leave is never dropped for the cap: without it the connection's id
        // is never freed, its calls stay in the route table, and the reaper
        // waits for a leave that never comes. At most one leave per client
        // waits here, so the list holds at most one per connection past its
        // cap and no more.
        const leave = leaveOf(event);
        o.mutex.lockUncancelable(o.io);
        if (leave) |id| {
            for (o.events.items) |pending| if (leaveOf(pending)) |held| if (held == id) {
                // The list already holds this client's leave.
                o.mutex.unlock(o.io);
                dropped.deinit(o.gpa);
                return;
            };
        }
        if (o.events.items.len < max_pending_events or leave != null) {
            o.events.append(o.gpa, event) catch |err| {
                o.mutex.unlock(o.io);
                dropped.deinit(o.gpa);
                debug_trace.logf("mcp-owner", "owner event dropped reason=out of memory client={?d} err={s}", .{ if (clientOf(event)) |id| @backingInt(id) else null, @errorName(err) });
                return;
            };
            o.mutex.unlock(o.io);
            return;
        }
        const pending = o.events.items.len;
        o.mutex.unlock(o.io);
        // The list is at its cap: this frame's session is sending faster than
        // the owner loop takes its events, so that one connection goes and its
        // session runs every server itself from now on.
        const client = clientOf(dropped);
        dropped.deinit(o.gpa);
        debug_trace.logf("mcp-owner", "owner event dropped reason=pending events at their cap client={?d} pending={d}", .{ if (client) |id| @backingInt(id) else null, pending });
        if (client) |id| if (o.connectionOf(id)) |conn| o.disconnect(conn);
    }

    /// The client a leave event is for.
    fn leaveOf(event: ShellEvent) ?core.ClientId {
        return switch (event) {
            .core => |e| switch (e) {
                .gone => |id| id,
                else => null,
            },
            else => null,
        };
    }

    /// The client a shell event came from, for a trace line when it is dropped.
    fn clientOf(event: ShellEvent) ?core.ClientId {
        return switch (event) {
            .call => |c| c.client,
            .respond => |r| r.client,
            .answer => |a| a.client,
            .register => |r| r.registered.client,
            .core => |e| switch (e) {
                .hello => |id| id,
                .registered => |r| r.client,
                .unregister => |u| u.client,
                .gone => |id| id,
                .bye => |id| id,
                .need => |n| n.client,
                .call => |c| c.client,
                .cancel => |c| c.client,
                .respond => |r| r.client,
                .answer => |a| a.client,
                else => null,
            },
        };
    }

    fn takeEvents(o: *Owner, into: *std.ArrayList(ShellEvent)) void {
        o.mutex.lockUncancelable(o.io);
        defer o.mutex.unlock(o.io);
        const taken = o.events;
        o.events = into.*;
        into.* = taken;
    }

    /// The connection `id` names, or null. The caller may keep the pointer
    /// after the lock is released: the owner frees a connection only once its
    /// leave is applied and both its tasks have ended, and a caller still
    /// using it is one of those tasks or the loop that applies the leave.
    fn connectionOf(o: *Owner, id: core.ClientId) ?*Connection {
        const index = @backingInt(id);
        if (index == 0 or index > core.max_clients) return null;
        o.mutex.lockUncancelable(o.io);
        defer o.mutex.unlock(o.io);
        return o.connections[index - 1];
    }

    fn addConnection(o: *Owner, stream: std.Io.net.Stream) !void {
        // Before any lock: an out-of-memory return must not leave one held.
        // The connection owns the stream from here, so every later failure
        // closes it through the connection itself.
        const conn = o.gpa.create(Connection) catch |err| {
            stream.close(o.io);
            return err;
        };
        // This function frees it only until the table holds it. After that the
        // reaper alone frees it, so no failure path can free a connection the
        // table or a task still names.
        var mine = true;
        errdefer if (mine) o.gpa.destroy(conn);
        conn.* = .{ .owner = o, .id = undefined, .stream = stream };

        o.mutex.lockUncancelable(o.io);
        const slot = o.freeSlotLocked() orelse {
            o.mutex.unlock(o.io);
            stream.close(o.io);
            return error.TooManyClients;
        };
        conn.id = @fromBackingInt(@intCast(slot + 1));
        o.connections[slot] = conn;
        o.open += 1;
        o.last_open_ms = o.now();
        o.mutex.unlock(o.io);
        mine = false;

        // A client checks the wire version before it says anything else, so
        // the owner names itself first.
        if (wire.encode(o.gpa, wire.OwnerMessage{ .welcome = .{ .owner = @intCast(std.c.getpid()) } })) |frame| {
            o.enqueue(conn, frame, "welcome");
        } else |_| {}

        o.startTasks(conn);
    }

    const Task = enum { reader, writer };

    /// Both of a connection's tasks go in its own group. If the second cannot
    /// start, the group is cancelled and awaited, which ends the first even
    /// when it is blocked in a read: the socket is never closed under it.
    fn startTasks(o: *Owner, conn: *Connection) void {
        conn.running.store(2, .release);
        if (o.fail_task_start == .reader) {
            o.fail_task_start = null;
            return o.taskStartFailed(conn, .reader, "test");
        }
        conn.tasks.concurrent(o.io, readerTask, .{conn}) catch |err| return o.taskStartFailed(conn, .reader, @errorName(err));
        if (o.fail_task_start == .writer) {
            o.fail_task_start = null;
            return o.taskStartFailed(conn, .writer, "test");
        }
        conn.tasks.concurrent(o.io, writerTask, .{conn}) catch |err| return o.taskStartFailed(conn, .writer, @errorName(err));
    }

    /// A connection whose tasks could not both start: no task owns the one
    /// that did not, so it goes the way a closed connection goes. `running`
    /// drops to the tasks that really started, its leave is told once, and the
    /// reaper cancels the group, closes the stream, and frees it.
    fn taskStartFailed(o: *Owner, conn: *Connection, which: Task, why: []const u8) void {
        debug_trace.logf("mcp-owner", "owner connection task not started client={d} which={s} err={s}", .{ @backingInt(conn.id), @tagName(which), why });
        switch (which) {
            .reader => {
                // Neither task started: nothing to cancel, and the reaper
                // frees it once its leave is applied.
                _ = conn.running.fetchSub(2, .acq_rel);
                o.disconnect(conn);
            },
            .writer => {
                // The writer never started, so it is not a task that can end
                // itself: `running` still counts it while the group is
                // cancelled, which keeps the reaper from freeing the
                // connection under the cancel. Marked as the cancel `markLeft`
                // would run, so the leave never cancels the group twice.
                o.mutex.lockUncancelable(o.io);
                const cancel = !conn.cancelled;
                conn.cancelled = true;
                o.mutex.unlock(o.io);
                // The reader is blocked in the socket: cancel ends it there,
                // and its own end drops `running` to 0.
                if (cancel) conn.tasks.cancel(o.io);
                _ = conn.running.fetchSub(1, .acq_rel);
                o.disconnect(conn);
            },
        }
    }

    /// An id nothing holds any more: its connection's tasks ended and the
    /// route table applied its leave, so no route, call, or question can still
    /// name it.
    fn freeSlotLocked(o: *Owner) ?usize {
        for (o.connections, 0..) |maybe, index| if (maybe == null) return index;
        return null;
    }

    /// Frees every connection whose tasks ended and whose leave the route
    /// table applied, and lets its id be used again. The table and each
    /// connection's lifetime are read, and the slot cleared, under `o.mutex`;
    /// the group's await, the socket close, and the free run after it, where
    /// no thread can find the connection any more.
    fn reapConnections(o: *Owner) void {
        var reaped: [core.max_clients]*Connection = undefined;
        var count: usize = 0;
        o.mutex.lockUncancelable(o.io);
        for (o.connections, 0..) |maybe, index| {
            const conn = maybe orelse continue;
            if (!conn.left_applied or conn.running.load(.acquire) != 0) continue;
            o.connections[index] = null;
            reaped[count] = conn;
            count += 1;
        }
        o.mutex.unlock(o.io);
        for (reaped[0..count]) |conn| {
            // Both tasks ran: the group has nothing left to wait for.
            conn.tasks.await(o.io) catch {};
            for (conn.queue.items) |frame| o.gpa.free(frame);
            conn.queue.deinit(o.gpa);
            conn.stream.close(o.io);
            o.gpa.destroy(conn);
        }
    }

    /// Marks the route table's part of this client's leave as applied, and ends
    /// the connection's tasks. Only the owner loop calls it: the owner is not
    /// one of those tasks, so the loop is the only place that can cancel them
    /// once the client is out of the route table. A reader blocked in the
    /// socket ends there, the reaper frees the connection after the close, and
    /// the session reads EOF.
    fn markLeft(o: *Owner, id: core.ClientId) void {
        var ended: ?*Connection = null;
        o.mutex.lockUncancelable(o.io);
        const index = @backingInt(id);
        if (index != 0 and index <= core.max_clients) if (o.connections[index - 1]) |conn| {
            conn.left_applied = true;
            if (!conn.cancelled and conn.running.load(.acquire) != 0) {
                conn.cancelled = true;
                ended = conn;
            }
        };
        o.mutex.unlock(o.io);
        // Outside the lock: the cancel waits for both tasks, and one of them
        // may need this lock or the connection's to end.
        if (ended) |conn| conn.tasks.cancel(o.io);
    }

    /// Marks the connection closed, tells the route table once, and wakes its
    /// writer so it can end and close the socket.
    fn disconnect(o: *Owner, conn: *Connection) void {
        var tell = false;
        conn.mutex.lockUncancelable(o.io);
        if (!conn.gone) {
            conn.gone = true;
            tell = true;
        }
        conn.closed = true;
        conn.changed.broadcast(o.io);
        conn.mutex.unlock(o.io);
        if (!tell) return;
        o.push(.{ .core = .{ .gone = conn.id } });
        o.mutex.lockUncancelable(o.io);
        o.open -|= 1;
        o.last_open_ms = o.now();
        o.mutex.unlock(o.io);
    }

    fn enqueue(o: *Owner, conn: *Connection, frame: []u8, what: []const u8) void {
        conn.mutex.lockUncancelable(o.io);
        // Two frames of the largest size a server can produce, so a reader
        // that falls behind gets one whole frame rather than a cut one.
        const over = conn.queued_bytes + frame.len > 2 * wire.max_frame_bytes;
        if (conn.closed or over) {
            if (!conn.closed and over) debug_trace.logf("mcp-owner", "owner client disconnected reason=write queue over its cap client={d} frame={s} bytes={d}", .{ @backingInt(conn.id), what, frame.len });
            conn.closed = true;
            conn.changed.broadcast(o.io);
            conn.mutex.unlock(o.io);
            o.gpa.free(frame);
            // A queue over its cap ends this client's connection; `disconnect`
            // reads `gone` under its own lock, so two writers never tell the
            // route table twice.
            if (over) o.disconnect(conn);
            return;
        }
        conn.queue.append(o.gpa, frame) catch |err| {
            conn.mutex.unlock(o.io);
            o.gpa.free(frame);
            // What this frame carried (a call's end, a status, a tool page) is
            // gone with it; the session hears nothing more for it.
            debug_trace.logf("mcp-owner", "owner frame dropped reason=queue append err={s} client={d} frame={s} bytes={d}", .{ @errorName(err), @backingInt(conn.id), what, frame.len });
            return;
        };
        conn.queued_bytes += frame.len;
        conn.changed.signal(o.io);
        conn.mutex.unlock(o.io);
    }

    fn closeAll(o: *Owner) void {
        // The table is read under the same lock that fills it; the work below
        // runs after, where nothing can add a connection any more.
        var conns: [core.max_clients]*Connection = undefined;
        var count: usize = 0;
        o.mutex.lockUncancelable(o.io);
        for (o.connections) |maybe| {
            const conn = maybe orelse continue;
            conns[count] = conn;
            count += 1;
        }
        o.connections = @splat(null);
        o.mutex.unlock(o.io);
        for (conns[0..count]) |conn| {
            // Cancel ends a reader blocked in the socket and a writer waiting
            // for a frame, and waits for both, so the socket is never closed
            // under a read.
            conn.tasks.cancel(o.io);
            for (conn.queue.items) |frame| o.gpa.free(frame);
            conn.queue.deinit(o.gpa);
            conn.stream.close(o.io);
            o.gpa.destroy(conn);
        }
    }

    /// Frees what the owner holds at exit, including the events its loop never
    /// took: each carries strings owned here, and a stop can leave any number
    /// waiting.
    fn deinit(o: *Owner) void {
        const gpa = o.gpa;
        o.engine_configs.deinit(gpa);
        for (o.events.items) |*event| event.deinit(gpa);
        o.events.deinit(gpa);
        var iterator = o.configs.iterator();
        while (iterator.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        o.configs.deinit(gpa);
    }
};

/// A registered server's config, owned by the owner process.
const OwnedConfig = struct {
    argv: [][]u8,
    env: [][2][]u8,
    cwd: ?[]u8,
    timeouts: ?wire.ServerConfig.Timeouts,
    auth: struct {
        client_id: ?[]u8 = null,
        client_secret: ?[]u8 = null,
        client_metadata_url: ?[]u8 = null,
        resource: ?[]u8 = null,
        scopes: ?[]u8 = null,
        client_name: []u8,
    },

    fn deinit(c: *OwnedConfig, gpa: Allocator) void {
        for (c.argv) |arg| gpa.free(arg);
        gpa.free(c.argv);
        for (c.env) |pair| {
            gpa.free(pair[0]);
            gpa.free(pair[1]);
        }
        gpa.free(c.env);
        if (c.cwd) |cwd| gpa.free(cwd);
        inline for (.{ "client_id", "client_secret", "client_metadata_url", "resource", "scopes" }) |field| {
            if (@field(c.auth, field)) |value| gpa.free(value);
        }
        gpa.free(c.auth.client_name);
        c.* = undefined;
    }

    /// Empties this config and returns what it held, so exactly one owner
    /// frees it: `deinit` on the emptied value frees nothing.
    fn take(c: *OwnedConfig) OwnedConfig {
        const held = c.*;
        c.* = .{ .argv = &.{}, .env = &.{}, .cwd = null, .timeouts = null, .auth = .{ .client_name = &.{} } };
        return held;
    }
};

fn ownConfig(gpa: Allocator, config: wire.ServerConfig) Allocator.Error!OwnedConfig {
    var owned: OwnedConfig = .{
        .argv = &.{},
        .env = &.{},
        .cwd = null,
        .timeouts = config.timeouts,
        .auth = .{ .client_name = &.{} },
    };
    errdefer owned.deinit(gpa);
    owned.argv = try gpa.alloc([]u8, config.argv.len);
    for (config.argv, owned.argv) |arg, *copy| copy.* = try gpa.dupe(u8, arg);
    owned.env = try gpa.alloc([2][]u8, config.env.len);
    for (config.env, owned.env) |entry, *pair| {
        pair.* = .{ try gpa.dupe(u8, entry.name), try gpa.dupe(u8, entry.value) };
    }
    if (config.cwd) |cwd| owned.cwd = try gpa.dupe(u8, cwd);
    inline for (.{ "client_id", "client_secret", "client_metadata_url", "resource", "scopes" }) |field| {
        if (@field(config.auth, field)) |value| @field(owned.auth, field) = try gpa.dupe(u8, value);
    }
    owned.auth.client_name = try gpa.dupe(u8, config.auth.client_name);
    return owned;
}

fn engineConfig(arena: Allocator, key: core.Key, config: *const OwnedConfig) Allocator.Error!engine.Config {
    const argv = try arena.alloc([]const u8, config.argv.len);
    for (config.argv, argv) |arg, *copy| copy.* = arg;
    const map = try arena.create(std.process.Environ.Map);
    map.* = .init(arena);
    for (config.env) |pair| try map.put(pair[0], pair[1]);
    var auth: @FieldType(engine.Config, "auth") = .{ .client_name = config.auth.client_name };
    inline for (.{ "client_id", "client_secret", "client_metadata_url", "resource", "scopes" }) |field| {
        @field(auth, field) = @field(config.auth, field);
    }
    const timeouts: ?mcp.core.request.Timeouts = if (config.timeouts) |t| .{
        .start_ms = t.start_ms,
        .idle_ms = t.idle_ms,
        .hard_ms = t.hard_ms,
        .reset_idle_on_progress = t.reset_idle_on_progress,
        .refresh_ms = t.refresh_ms,
        .refused_ms = t.refused_ms,
    } else null;
    return .{
        .name = try arena.dupe(u8, &key),
        .transport = .{ .stdio = .{ .argv = argv, .environ_map = map, .cwd = config.cwd } },
        .auth = auth,
        .timeouts = timeouts,
    };
}

fn allowAll(_: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) bool {
    return true;
}

fn logStderr(_: *anyopaque, server: []const u8, line: []const u8) void {
    // The `mcp` scope, as the session's own server log uses: the servers run
    // here now, and a person tracing MCP should see them wherever they run.
    debug_trace.logf("mcp", "MCP server stderr server={s} line={s}", .{ server, line[0..@min(line.len, 512)] });
}

fn keyFromName(name: []const u8) ?core.Key {
    if (name.len != 32) return null;
    var key: core.Key = undefined;
    @memcpy(&key, name);
    return key;
}

fn slotOf(owner: *Owner, key: core.Key) ?usize {
    for (owner.engine_configs.items, 0..) |config, index| {
        if (std.mem.eql(u8, config.name, &key)) return index;
    }
    return null;
}

/// Stores a config whose key the route table accepted, taking ownership of its
/// strings. Only `register_slot` reaches this, so a registration the route
/// table refused, or one for a key it already runs, stores nothing: the map
/// cannot grow past the key limits.
fn storeConfig(owner: *Owner, key: core.Key, config: OwnedConfig) void {
    const name = owner.gpa.dupe(u8, &key) catch {
        var copy = config;
        copy.deinit(owner.gpa);
        debug_trace.logf("mcp-owner", "owner config dropped reason=out of memory key={s}", .{key[0..]});
        return;
    };
    owner.configs_mutex.lockUncancelable(owner.io);
    defer owner.configs_mutex.unlock(owner.io);
    if (owner.configs.contains(&key)) {
        owner.gpa.free(name);
        var copy = config;
        copy.deinit(owner.gpa);
        return;
    }
    owner.configs.put(owner.gpa, name, config) catch {
        owner.gpa.free(name);
        var copy = config;
        copy.deinit(owner.gpa);
        debug_trace.logf("mcp-owner", "owner config dropped reason=out of memory key={s}", .{key[0..]});
    };
}
/// Serves until the last client has been gone for `exit_grace_ms` or `stop`
/// is set. `error.LockBusy` means another owner holds the lock.
pub fn serve(io: std.Io, gpa: Allocator, fx_home: []const u8, stop: *std.atomic.Value(bool), client_version: []const u8) !void {
    const run_dir = try std.Io.Dir.path.join(gpa, &.{ fx_home, run_dir_name });
    defer gpa.free(run_dir);
    std.Io.Dir.cwd().createDir(io, run_dir, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir: io_mod.VerifiedDir = .{ .dir = try std.Io.Dir.openDirAbsolute(io, run_dir, .{ .iterate = true }) };
    defer dir.close();
    var held = io_mod.acquireTimedAdvisoryLock(&dir, lock_name, 0) catch |err| switch (err) {
        error.LockBusy => return error.LockBusy,
        else => return err,
    };
    defer held.release();

    const socket_path = try std.Io.Dir.path.join(gpa, &.{ run_dir, socket_name });
    defer gpa.free(socket_path);
    // A socket file an owner that was killed left behind; often there is none.
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    var address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(io, .{});
    var listening = true;
    defer if (listening) listener.deinit(io);
    // Another user must not connect to this socket. A run directory the owner
    // made 0700 still keeps them out when this mode can't be set, so the
    // failure is logged rather than ignored or fatal.
    std.Io.Dir.cwd().setFilePermissions(io, socket_path, .fromMode(0o600), .{ .follow_symlinks = false }) catch |err| {
        debug_trace.logf("mcp-owner", "owner socket not private reason=set mode err={s}", .{@errorName(err)});
    };

    var owner: Owner = .{ .io = io, .gpa = gpa, .stop = stop, .client_version = client_version, .engine_arena = .init(gpa) };
    defer owner.engine_arena.deinit();
    owner.last_open_ms = owner.now();
    var loop = io.concurrent(ownerLoopTask, .{&owner}) catch |err| {
        listener.deinit(io);
        listening = false;
        // The socket this start just made may exist to remove; nothing depends
        // on the removal, since the lock is released as this returns.
        std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        return err;
    };

    while (!owner.stopping()) {
        var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, poll_ms) catch 0;
        if (ready == 0) continue;
        const stream = listener.accept(io) catch |err| {
            if (owner.stopping()) break;
            debug_trace.logf("mcp-owner", "owner accept failed err={s}", .{@errorName(err)});
            continue;
        };
        // The connection owns the stream once it is taken, and closes it on
        // any failure of its own.
        owner.addConnection(stream) catch |err| {
            debug_trace.logf("mcp-owner", "owner connection refused err={s}", .{@errorName(err)});
        };
    }

    // The order is fixed: the listening socket closes, the owner loop ends
    // (and with it the engine, which stops every server), each connection's
    // tasks are cancelled and awaited, its socket closes, the socket file
    // goes, and the lock is released as this function returns.
    listener.deinit(io);
    listening = false;
    owner.stop.store(true, .release);
    loop.await(io) catch {}; // It ends on the stop flag; a cancel of it lands here, with nothing left to do.
    owner.closeAll();
    // The owner is stopping: the socket it served may already be gone, and the
    // next owner deletes any file left here before it listens.
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    owner.deinit();
}

fn ownerLoopTask(owner: *Owner) std.Io.Cancelable!void {
    ownerLoop(owner);
}

fn ownerLoop(owner: *Owner) void {
    const io = owner.io;
    const gpa = owner.gpa;
    var engine_value: engine.Engine = undefined;
    engine_value.init(io, gpa, .{ .context = owner, .allow = allowAll, .log = logStderr }, .{
        .client = .{ .info = .{ .name = "fx", .version = owner.client_version }, .capabilities = "{\"elicitation\":{\"form\":{},\"url\":{}}}" },
        .gate = mcp.core.engine.limitsFor(idle_control.idleMs()),
    }, &.{}) catch |err| {
        debug_trace.logf("mcp-owner", "owner engine did not start err={s}", .{@errorName(err)});
        owner.stop.store(true, .release);
        return;
    };
    defer engine_value.deinit();
    var state: core.State = .{};
    var taken: std.ArrayList(ShellEvent) = .empty;
    defer taken.deinit(gpa);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    while (!owner.stopping()) {
        // Effects can push events too (`issued`, `issue_failed`); they are
        // stepped before the engine is read, so a call never looks orphaned.
        while (true) {
            taken.clearRetainingCapacity();
            owner.takeEvents(&taken);
            if (taken.items.len == 0) break;
            for (taken.items) |*shell_event| {
                const event = shell_event.event();
                // The route table applied this client's leave: its id can be
                // used again once its tasks have ended too.
                if (event == .gone) owner.markLeft(event.gone);
                var output: core.Output = .{};
                core.step(&state, event, &output);
                // A key the route table took stores its config now, before the
                // engine config is built from it; a refused key stores none.
                if (shell_event.acceptedConfig(output.effects())) |config| storeConfig(owner, shell_event.register.registered.key, config.take());
                _ = scratch.reset(.retain_capacity);
                apply(owner, &state, &engine_value, &scratch, output.effects());
                shell_event.deinit(gpa);
            }
        }
        if (engine_value.next(poll_ms)) |maybe| {
            if (maybe) |event| {
                stepEngineEvent(owner, &state, &engine_value, &scratch, event);
            }
        } else |err| {
            debug_trace.logf("mcp-owner", "owner engine step failed err={s}", .{@errorName(err)});
        }
        owner.reapConnections();
        owner.mutex.lockUncancelable(io);
        const open = owner.open;
        const last = owner.last_open_ms;
        owner.mutex.unlock(io);
        if (open == 0 and owner.now() - last >= exit_grace_ms) owner.stop.store(true, .release);
    }
}

/// What a frame that could not be built was about, for its trace line.
fn frameAbout(a: Allocator, message: wire.OwnerMessage) Allocator.Error![]const u8 {
    return switch (message) {
        .welcome => |m| a.print("owner={d}", .{m.owner}),
        .phase => |m| a.print("key={s}", .{m.key[0..]}),
        .tools => |m| a.print("key={s}", .{m.key[0..]}),
        .question => |m| a.print("key={s} slot={d}", .{ m.key[0..], m.slot }),
        .elicitation_complete => |m| a.print("key={s} slot={d}", .{ m.key[0..], m.slot }),
        .elicit_withdrawn => |m| a.print("key={s} slot={d}", .{ m.key[0..], m.slot }),
        .stopped_idle => |m| a.print("key={s}", .{m.key[0..]}),
        .refused => |m| if (m.key) |key| a.print("key={s} reason={s}", .{ key[0..], @tagName(m.reason) }) else a.print("call={?d} reason={s}", .{ m.call, @tagName(m.reason) }),
        .status => |m| a.print("key={s}", .{m.key[0..]}),
        .called => |m| a.print("call={d}", .{m.id}),
        .progress => |m| a.print("call={d}", .{m.id}),
        .input => |m| a.print("call={d}", .{m.id}),
    };
}

/// A frame to send in place of one that can't be built: a call's end as a
/// small failure, so its session ends the call rather than waiting out its
/// deadline. Null when nothing can stand in.
fn frameThatEndsTheCall(message: wire.OwnerMessage) ?wire.OwnerMessage {
    return switch (message) {
        .called => |m| .{
            .called = .{
                .id = m.id,
                .outcome = .malformed,
                // The answer existed, so the call ran unless the owner said it
                // didn't.
                .maybe_ran = m.maybe_ran or m.outcome == .result or m.outcome == .failure,
                .timed_out = false,
            },
        },
        else => null,
    };
}

/// Sends one frame. A frame that can't be built is logged with what it was
/// about, and a call's end is replaced by one the session can read.
fn sendFrame(owner: *Owner, conn: *Connection, message: wire.OwnerMessage, a: Allocator) void {
    const what = @tagName(std.meta.activeTag(message));
    const frame = wire.encode(owner.gpa, message) catch |err| {
        debug_trace.logf("mcp-owner", "owner frame dropped kind={s} {s} err={s}", .{ what, frameAbout(a, message) catch "?", @errorName(err) });
        const end = frameThatEndsTheCall(message) orelse return;
        const small = wire.encode(owner.gpa, end) catch return;
        owner.enqueue(conn, small, "called");
        return;
    };
    owner.enqueue(conn, frame, what);
}

fn apply(owner: *Owner, state: *core.State, engine_value: *engine.Engine, scratch: *std.heap.ArenaAllocator, effects: []const core.Effect) void {
    const a = scratch.allocator();
    for (effects) |effect| switch (effect) {
        .send => |send| {
            const conn = owner.connectionOf(send.to) orelse {
                continue;
            };
            sendFrame(owner, conn, send.message, a);
        },
        .broadcast => |broadcast| {
            const clients = core.clientsOf(state, broadcast.key) orelse continue;
            var index: usize = 0;
            while (index < core.max_clients) : (index += 1) {
                if (!clients.isSet(index)) continue;
                const id: core.ClientId = @fromBackingInt(@as(u32, @intCast(index + 1)));
                const conn = owner.connectionOf(id) orelse continue;
                const message = broadcastMessage(owner, engine_value, a, broadcast.key, broadcast.what) orelse continue;
                sendFrame(owner, conn, message, a);
            }
        },
        .register_slot => |slot| {
            // Under the map's lock until the engine config is built: a reader
            // may add another key meanwhile, and a put may move the entries.
            owner.configs_mutex.lockUncancelable(owner.io);
            const config = owner.configs.getPtr(&slot.key) orelse {
                owner.configs_mutex.unlock(owner.io);
                continue;
            };
            if (slotOf(owner, slot.key) != null) {
                owner.configs_mutex.unlock(owner.io);
                continue;
            }
            const built = engineConfig(owner.engine_arena.allocator(), slot.key, config) catch {
                owner.configs_mutex.unlock(owner.io);
                continue;
            };
            owner.configs_mutex.unlock(owner.io);
            owner.engine_configs.append(owner.gpa, built) catch continue;
            engine_value.reload(owner.engine_configs.items) catch |err| {
                debug_trace.logf("mcp-owner", "owner server not registered err={s}", .{@errorName(err)});
            };
        },
        .need => |need| {
            engine_value.needTools(&need.key) catch |err| {
                debug_trace.logf("mcp-owner", "owner tool list not started err={s}", .{@errorName(err)});
            };
        },
        .call => |call| {
            const handle = engine_value.call(&call.key, call.tool, call.arguments) catch |err| {
                debug_trace.logf("mcp-owner", "owner call not issued err={s}", .{@errorName(err)});
                owner.push(.{ .core = .{ .issue_failed = .{ .call = call.call } } });
                continue;
            };
            owner.push(.{ .core = .{ .issued = .{ .call = call.call, .handle = handle } } });
        },
        .cancel => |cancel| {
            // A session asked to end its call: say when the engine didn't take
            // the cancel, since the call then runs on for its deadline.
            engine_value.cancel(cancel.handle) catch |err| {
                debug_trace.logf("mcp-owner", "owner cancel not sent err={s}", .{@errorName(err)});
            };
        },
        .respond => |respond| {
            const values = std.json.parseFromSliceLeaky([]const []const u8, a, respond.values, .{}) catch |err| {
                // The session's answer to a 2026 input request can't be read:
                // end the call instead of leaving it waiting for input it will
                // never get.
                debug_trace.logf("mcp-owner", "owner respond dropped reason=malformed values handle={d} err={s}", .{ respond.handle, @errorName(err) });
                engine_value.cancel(respond.handle) catch |cancel_err| {
                    debug_trace.logf("mcp-owner", "owner cancel not sent handle={d} err={s}", .{ respond.handle, @errorName(cancel_err) });
                };
                continue;
            };
            // A session's answer to a 2026 input request, dropped when the
            // engine doesn't take it: the call then ends as unsupported input.
            engine_value.respond(respond.handle, values) catch |err| {
                debug_trace.logf("mcp-owner", "owner respond not sent err={s}", .{@errorName(err)});
            };
        },
        .answer => |answer| engine_value.answerElicitation(&answer.key, .{ .slot = answer.slot, .n = answer.n }, .{ .action = answer.action, .content = answer.content }) catch |err| {
            debug_trace.logf("mcp-owner", "owner answer not sent err={s}", .{@errorName(err)});
        },
        .disconnect => |disconnect| {
            engine_value.disconnect(&disconnect.key) catch |err| {
                debug_trace.logf("mcp-owner", "owner server not disconnected err={s}", .{@errorName(err)});
            };
        },
        .refuse => |refuse| {
            const conn = owner.connectionOf(refuse.to) orelse continue;
            // One refused request, not one lost connection: the session falls
            // back for this server or this call and keeps every other key.
            debug_trace.logf("mcp-owner", "owner request refused reason={s} client={d} key={?s}", .{ @tagName(refuse.reason), @backingInt(refuse.to), if (refuse.key) |key| key[0..] else null });
            sendFrame(owner, conn, .{ .refused = .{
                .reason = refuse.reason,
                .key = refuse.key,
                .call = refuse.call,
            } }, scratch.allocator());
        },
        .log => |log| debug_trace.logf("mcp-owner", "owner dropped user state what={s} client={?d}", .{ @tagName(log.what), if (log.client) |c| @backingInt(c) else null }),
    };
}

fn broadcastMessage(owner: *Owner, engine_value: *engine.Engine, a: Allocator, key: core.Key, what: core.Broadcast) ?wire.OwnerMessage {
    return switch (what) {
        .phase => |phase| .{ .phase = .{ .key = key, .phase = phase } },
        .tools => |tools| .{
            .tools = .{
                .key = key,
                .ok = tools.ok,
                .fresh = tools.fresh,
                .needs_auth = tools.needs_auth,
                // The engine lends the words until its next refusal; the frame
                // copies them, as it copies the list.
                .list_refusal = refusalMessage(owner, engine_value, a, key),
                .tools = toolsJson(owner, engine_value, a, key),
            },
        },
        .status => statusMessage(owner, engine_value, a, key) orelse return null,
        .stopped_idle => .{ .stopped_idle = .{ .key = key } },
        .elicitation_complete => |slot| .{ .elicitation_complete = .{ .key = key, .slot = slot } },
        .elicit_withdrawn => |slot| .{ .elicit_withdrawn = .{ .key = key, .slot = slot } },
    };
}

fn statusMessage(owner: *Owner, engine_value: *engine.Engine, a: Allocator, key: core.Key) ?wire.OwnerMessage {
    // A status asked for before the engine has the slot (registration, before
    // the first need) has nothing to say; a made-up idle phase would overwrite
    // the phase the phases before it told the client.
    const index = slotOf(owner, key) orelse {
        debug_trace.logf("mcp-owner", "owner status dropped reason=no engine slot yet", .{});
        return null;
    };
    const status = engine_value.status(index);
    var tail_buf: [mcp.stdio.tail_max]u8 = undefined;
    const tail = engine_value.stderrTail(index, &tail_buf);
    return .{ .status = .{
        .key = key,
        .phase = status.phase,
        .version = if (status.version) |v| a.dupe(u8, v) catch null else null,
        .last_error = if (status.last_error) |e| a.dupe(u8, e) catch null else null,
        .stderr_tail = if (tail) |t| a.dupe(u8, t) catch null else null,
        .instructions = if (engine_value.instructions(&key)) |text| a.dupe(u8, text) catch null else null,
        .exit_code = if (status.exit) |e| (switch (e) {
            .code => |c| c,
            .signal => null,
        }) else null,
        .exit_signal = if (status.exit) |e| (switch (e) {
            .signal => |n| n,
            .code => null,
        }) else null,
        .stray_line = if (status.stray_line) |line| a.dupe(u8, line) catch null else null,
        .list_refusal = if (status.list_refusal) |words| a.dupe(u8, words) catch null else null,
    } };
}

/// Why the engine refused this server's last tool list, copied for the frame:
/// null while it refused none. A session reads it in its own slot's status.
fn refusalMessage(owner: *Owner, engine_value: *engine.Engine, a: Allocator, key: core.Key) ?[]const u8 {
    const index = slotOf(owner, key) orelse return null;
    const words = engine_value.status(index).list_refusal orelse return null;
    return a.dupe(u8, words) catch null;
}

fn toolsJson(owner: *Owner, engine_value: *engine.Engine, a: Allocator, key: core.Key) []const u8 {
    _ = owner;
    const list = engine_value.toolList(&key) catch return "[]";
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return "[]";
    for (0..list.len()) |i| {
        if (i > 0) out.append(a, ',') catch return "[]";
        out.appendSlice(a, list.get(i).raw) catch return "[]";
    }
    out.append(a, ']') catch return "[]";
    return out.items;
}

/// One engine event, stepped and applied in the same iteration so the strings
/// it borrows from the engine stay valid.
fn stepEngineEvent(owner: *Owner, state: *core.State, engine_value: *engine.Engine, scratch: *std.heap.ArenaAllocator, event: engine.Event) void {
    _ = scratch.reset(.retain_capacity);
    const a = scratch.allocator();
    const key = keyFromName(event.server) orelse return;
    // What the clients know about the server goes out first: a phase or a
    // listing frame ends a session's waiting request, and that session builds
    // its failure text from this status, so the status must be there before
    // the frame that reads it.
    var status_output: core.Output = .{};
    core.step(state, .{ .engine_status = .{ .key = key } }, &status_output);
    apply(owner, state, engine_value, scratch, status_output.effects());
    var core_event: ?core.Event = null;
    switch (event.kind) {
        .phase => |phase| core_event = .{ .engine_phase = .{ .key = key, .phase = phase } },
        .called => |called| {
            var answer: ?[]const u8 = null;
            if (called.answer) |call| {
                // Only out of memory fails here. The call still ends, without
                // its answer's detail, and this line says why none came.
                answer = std.json.Stringify.valueAlloc(a, call, .{}) catch |err| blk: {
                    debug_trace.logf("mcp-owner", "owner call answer dropped reason=out of memory err={s}", .{@errorName(err)});
                    break :blk null;
                };
            }
            core_event = .{ .engine_called = .{
                .handle = called.call,
                .outcome = called.outcome,
                .maybe_ran = called.maybe_ran,
                .timed_out = called.timed_out,
                .oversized = called.oversized,
                .answer = answer,
                .refused_bytes = called.refused_bytes,
                .refused_body = called.refused_body,
            } };
        },
        .progress => |progress| core_event = .{ .engine_progress = .{
            .handle = progress.call,
            .progress = progress.progress,
            .total = progress.total,
            .message = if (progress.message) |message| a.dupe(u8, message) catch null else null,
        } },
        .input => |input| core_event = .{ .engine_input = .{ .handle = input.call, .requests = requestsJson(a, input.requests) } },
        .server => |server| switch (server) {
            .tools => |tools| core_event = .{ .engine_tools = .{ .key = key, .ok = tools.ok, .fresh = tools.fresh, .needs_auth = tools.needs_auth } },
            .elicit => |elicit| {
                const version = if (slotOf(owner, key)) |index| engine_value.status(index).version else null;
                core_event = .{ .engine_question = .{
                    .key = key,
                    .slot = elicit.id.slot,
                    .n = elicit.id.n,
                    .kind = if (std.mem.find(u8, elicit.params, "\"mode\":\"url\"") != null) .url else .form,
                    .params = a.dupe(u8, elicit.params) catch return,
                    .version = if (version) |v| a.dupe(u8, v) catch null else null,
                    .required = elicit.required,
                } };
            },
            .elicitation_complete => |slot| core_event = .{ .engine_elicitation_complete = .{ .key = key, .slot = slot } },
            .elicit_withdrawn => |slot| core_event = .{ .engine_elicitation_withdrawn = .{ .key = key, .slot = slot } },
            else => {},
        },
        .stopped_idle => core_event = .{ .engine_stopped_idle = .{ .key = key } },
    }
    if (core_event) |e| {
        var output: core.Output = .{};
        core.step(state, e, &output);
        apply(owner, state, engine_value, scratch, output.effects());
    }
}

fn requestsJson(a: Allocator, requests: []const mcp.mrtr.Request) []const u8 {
    // The whole request, so the session reads back what the server wrote: its
    // key, kind, params, and request object.
    var out: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(requests, .{}, &out.writer) catch return "[]";
    return out.written();
}

/// One connection's reader, as a task: a read blocked on its socket ends with
/// `error.Canceled` when the owner cancels it, with no need to close the
/// socket under it.
fn readerTask(conn: *Connection) std.Io.Cancelable!void {
    defer conn.endTask();
    readerLoop(conn) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        conn.owner.disconnect(conn);
    };
}

fn readerLoop(conn: *Connection) !void {
    const owner = conn.owner;
    var header: [wire.header_bytes]u8 = undefined;
    while (true) {
        try readExact(conn, &header);
        const length = wire.readLength(&header) catch return error.Malformed;
        const payload = owner.gpa.alloc(u8, length) catch return error.OutOfMemory;
        defer owner.gpa.free(payload);
        try readExact(conn, payload);
        var arena = std.heap.ArenaAllocator.init(owner.gpa);
        defer arena.deinit();
        const message = wire.decode(arena.allocator(), payload) catch return error.Malformed;
        switch (message) {
            .client => |client| switch (client) {
                .hello => owner.push(.{ .core = .{ .hello = conn.id } }),
                .register => |register| {
                    // The config travels with the event: it is stored only
                    // when the route table takes the key, so a refused or
                    // over-limit registration never grows `configs`.
                    const owned = ownConfig(owner.gpa, register.config) catch {
                        debug_trace.logf("mcp-owner", "owner registration dropped reason=out of memory client={d}", .{@backingInt(conn.id)});
                        return error.OutOfMemory;
                    };
                    owner.push(.{ .register = .{
                        .registered = .{ .client = conn.id, .key = register.key, .ask_form = register.ask_form, .ask_url = register.ask_url },
                        .config = owned,
                    } });
                },
                .need => |need| owner.push(.{ .core = .{ .need = .{ .client = conn.id, .key = need.key } } }),
                .unregister => |left| owner.push(.{ .core = .{ .unregister = .{ .client = conn.id, .key = left.key } } }),
                .call => |call| {
                    const tool = owner.gpa.dupe(u8, call.tool) catch return error.OutOfMemory;
                    const arguments = if (call.arguments) |args| owner.gpa.dupe(u8, args) catch {
                        owner.gpa.free(tool);
                        return error.OutOfMemory;
                    } else null;
                    owner.push(.{ .call = .{ .client = conn.id, .id = call.id, .key = call.key, .tool = tool, .arguments = arguments } });
                },
                .cancel => |cancel| owner.push(.{ .core = .{ .cancel = .{ .client = conn.id, .id = cancel.id } } }),
                .respond => |respond| {
                    const values = owner.gpa.dupe(u8, respond.values) catch return error.OutOfMemory;
                    owner.push(.{ .respond = .{ .client = conn.id, .id = respond.id, .values = values } });
                },
                .answer => |answer| {
                    const content = if (answer.content) |text| owner.gpa.dupe(u8, text) catch return error.OutOfMemory else null;
                    owner.push(.{ .answer = .{ .client = conn.id, .key = answer.key, .slot = answer.slot, .n = answer.n, .action = answer.action, .content = content } });
                },
                .bye => {
                    owner.push(.{ .core = .{ .bye = conn.id } });
                    return error.Left;
                },
            },
            // The owner's messages are not for it.
            .owner => return error.WrongDirection,
        }
    }
}

/// One connection's writer, as a task. It waits for a frame or for the
/// connection to close, and both that wait and a write can be cancelled.
fn writerTask(conn: *Connection) std.Io.Cancelable!void {
    defer conn.endTask();
    const owner = conn.owner;
    const io = owner.io;
    var buffer: [4096]u8 = undefined;
    while (true) {
        conn.mutex.lockUncancelable(io);
        while (conn.queue.items.len == 0 and !conn.closed) {
            conn.changed.wait(io, &conn.mutex) catch |err| {
                conn.mutex.unlock(io);
                return err;
            };
        }
        if (conn.queue.items.len == 0 and conn.closed) {
            conn.mutex.unlock(io);
            return;
        }
        const frame = conn.queue.orderedRemove(0);
        conn.queued_bytes -= frame.len;
        conn.mutex.unlock(io);
        defer owner.gpa.free(frame);
        var writer = conn.stream.writer(io, &buffer);
        writer.interface.writeAll(frame) catch {
            const cause = writer.err orelse error.WriteFailed;
            if (cause == error.Canceled) return error.Canceled;
            debug_trace.logf("mcp-owner", "owner write failed client={d} err={s}", .{ @backingInt(conn.id), @errorName(cause) });
            owner.disconnect(conn);
            return;
        };
        writer.interface.flush() catch {
            const cause = writer.err orelse error.WriteFailed;
            if (cause == error.Canceled) return error.Canceled;
            debug_trace.logf("mcp-owner", "owner write failed client={d} err={s}", .{ @backingInt(conn.id), @errorName(cause) });
            owner.disconnect(conn);
            return;
        };
    }
}

fn readExact(conn: *Connection, buffer: []u8) !void {
    const io = conn.owner.io;
    var read: usize = 0;
    while (read < buffer.len) {
        var data = [_][]u8{buffer[read..]};
        const result = try conn.stream.readWithControl(io, &data, &.{});
        if (result.data_len == 0) return error.Closed;
        read += result.data_len;
    }
}

const testing = std.testing;
const fake_server = @import("fake_server.zig");

const test_key: core.Key = "00112233445566778899aabbccddeeff".*;
/// What a test owner tells every server it runs, in place of the fx version.
pub const test_client_version = "0.0.0-test";

fn socketPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, run_dir_name, socket_name });
}

fn serveThread(io: std.Io, gpa: Allocator, home: []const u8, stop: *std.atomic.Value(bool)) void {
    serve(io, gpa, home, stop, test_client_version) catch |err| {
        debug_trace.logf("mcp-owner", "test owner ended err={s}", .{@errorName(err)});
    };
}

const TestClient = struct {
    stream: std.Io.net.Stream,
    closed: bool = false,
    next: u32 = 1,

    fn connect(path: []const u8) !TestClient {
        const address = try std.Io.net.UnixAddress.init(path);
        return .{ .stream = try address.connect(testing.io) };
    }

    fn send(c: *TestClient, message: wire.ClientMessage) !void {
        const frame = try wire.encode(testing.allocator, message);
        defer testing.allocator.free(frame);
        try writeAllFd(c.stream.socket.handle, frame);
    }

    /// The next frame, skipping the welcome the owner opens with.
    fn receive(c: *TestClient, arena: Allocator, timeout_ms: i64) !wire.Message {
        const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + timeout_ms;
        while (true) {
            const left = deadline - std.Io.Clock.awake.now(testing.io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = c.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = try std.posix.poll(&fds, @intCast(@min(left, 50)));
            if (ready == 0) continue;
            break;
        }
        var header: [wire.header_bytes]u8 = undefined;
        try readExactFd(c.stream.socket.handle, &header);
        const length = try wire.readLength(&header);
        const payload = try arena.alloc(u8, length);
        try readExactFd(c.stream.socket.handle, payload);
        return try wire.decode(arena, payload);
    }

    /// The first `called` for call `id`, skipping other frames.
    fn called(c: *TestClient, arena: Allocator, id: u32, timeout_ms: i64) !wire.OwnerMessage {
        const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + timeout_ms;
        while (true) {
            const left = deadline - std.Io.Clock.awake.now(testing.io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            const message = c.receive(arena, left) catch |err| return err;
            switch (message) {
                .owner => |owner| switch (owner) {
                    .called => |call| if (call.id == id) return owner,
                    .welcome => continue,
                    else => {},
                },
                .client => return error.UnexpectedMessage,
            }
        }
    }

    fn close(c: *TestClient) void {
        if (c.closed) return;
        c.closed = true;
        c.stream.close(testing.io);
    }
};

fn readExactFd(fd: std.posix.socket_t, buffer: []u8) !void {
    var read: usize = 0;
    while (read < buffer.len) {
        const n = std.posix.read(fd, buffer[read..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.Closed;
        read += n;
    }
}

fn writeAllFd(fd: std.posix.socket_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) {
            const errno = std.posix.errno(rc);
            if (errno == .INTR or errno == .AGAIN) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.Closed;
        written += @intCast(rc);
    }
}

var home_count = std.atomic.Value(u32).init(0);

var socket_count = std.atomic.Value(u32).init(0);

/// A connected pair of Unix sockets: the accepted end for a connection the
/// owner may close, and the peer the caller keeps open and closes itself. The
/// listening socket is closed before this returns.
fn testSocketPair(tag: []const u8) !struct { server: std.Io.net.Stream, peer: std.Io.net.Stream } {
    const io = testing.io;
    const n = socket_count.fetchAdd(1, .monotonic);
    var buffer: [129]u8 = undefined;
    const path = try std.fmt.bufPrint(buffer[0..128], "/tmp/fx-owner-{s}-{d}-{d}.sock", .{ tag, std.c.getpid(), n });
    buffer[path.len] = 0;
    const path_z = buffer[0..path.len :0];
    // A file an earlier run left; there need not be one.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {}; // Cleanup only: nothing is asserted on it.
    var address = try std.Io.net.UnixAddress.init(path_z);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const peer = try address.connect(io);
    const server = listener.accept(io) catch |err| {
        peer.close(io);
        return err;
    };
    return .{ .server = server, .peer = peer };
}

/// A short fx home, because a Unix socket path is limited to 103 bytes and a
/// test's tmpDir path is longer than that.
fn shortHome(alloc: Allocator) ![]u8 {
    const n = home_count.fetchAdd(1, .monotonic);
    const path = try alloc.print("/tmp/fx-owner-test-{d}-{d}", .{ std.c.getpid(), n });
    // A folder left by an earlier run of this test; there need not be one.
    std.Io.Dir.cwd().deleteTree(testing.io, path) catch {};
    try std.Io.Dir.cwd().createDir(testing.io, path, .fromMode(0o700));
    return path;
}

fn removeHome(alloc: Allocator, path: []u8) void {
    // Cleanup only: a folder that won't go leaves nothing the test asserts on,
    // and /tmp clears it.
    std.Io.Dir.cwd().deleteTree(testing.io, path) catch {};
    alloc.free(path);
}

fn waitForSocket(path: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const address = std.Io.net.UnixAddress.init(path) catch |err| return err;
        if (address.connect(testing.io)) |stream| {
            stream.close(testing.io);
            return;
        } else |_| {
            // Polls for the socket the test's owner thread is opening.
            testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }
    return error.SocketNeverAppeared;
}

fn pidFromAnswer(answer: []const u8) !std.posix.pid_t {
    const at = std.mem.find(u8, answer, "pid=") orelse return error.NoPid;
    const digits = answer[at + 4 ..];
    const end = std.mem.findNone(u8, digits, "0123456789") orelse digits.len;
    return std.fmt.parseInt(std.posix.pid_t, digits[0..end], 10);
}

fn running(pid: std.posix.pid_t) !bool {
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return err,
    };
    return true;
}

fn registerFor(c: *TestClient, server: []const u8) !void {
    try c.send(.{ .hello = .{ .pid = 1 } });
    try c.send(.{ .register = .{
        .key = test_key,
        .config = .{ .argv = &.{server}, .timeouts = .{ .start_ms = 15_000 } },
        .ask_form = true,
        .ask_url = true,
    } });
}

test "cancelling a connection's reader ends it without closing the socket" {
    // The owner relies on this: a reader blocked in a socket read ends when
    // its task is cancelled, so a socket is never closed under the read.
    const io = testing.io;
    const path = "/tmp/fx-owner-cancel-test.sock";
    std.Io.Dir.cwd().deleteFile(io, path) catch {}; // A file an earlier run left; often there is none.
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {}; // Cleanup only: nothing is asserted on it.
    var address = try std.Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const peer = try address.connect(io);
    defer peer.close(io);
    const stream = try listener.accept(io);
    var closed = false;
    defer if (!closed) stream.close(io);

    const Attempt = struct {
        err: ?anyerror = null,
        in_read: std.atomic.Value(bool) = .init(false),

        fn run(s: std.Io.net.Stream, attempt: *@This()) void {
            var buffer: [64]u8 = undefined;
            var data = [_][]u8{buffer[0..]};
            attempt.in_read.store(true, .release);
            _ = s.readWithControl(testing.io, &data, &.{}) catch |err| {
                attempt.err = err;
                return;
            };
        }
    };
    var attempt: Attempt = .{};
    var task = try io.concurrent(Attempt.run, .{ stream, &attempt });
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5_000;
    while (!attempt.in_read.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return error.ReaderNeverStarted;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try io.sleep(.fromMilliseconds(100), .awake);
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    task.cancel(io);
    try testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - started < 2_000);
    try testing.expect(attempt.err != null and attempt.err.? == error.Canceled);
    // The descriptor is still open: the peer's bytes still arrive.
    try testing.expect(std.c.write(peer.socket.handle, "hi".ptr, 2) == 2);
    var buffer: [8]u8 = undefined;
    var data = [_][]u8{buffer[0..]};
    const result = try stream.readWithControl(io, &data, &.{});
    try testing.expectEqualStrings("hi", buffer[0..result.data_len]);
    closed = true;
    stream.close(io);
}

test "an owner takes 300 connections in turn and still serves a new one" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    // More connections than the table holds: each one's state is freed and
    // its id used again once both its tasks ended and the leave was applied.
    for (0..300) |_| {
        var client = try TestClient.connect(path);
        defer client.close();
        try registerFor(&client, fixture.server);
        try client.send(.bye);
        // The owner loop ends the tasks and applies the leave on its next turn.
        try testing.io.sleep(.fromMilliseconds(30), .awake);
    }

    var client = try TestClient.connect(path);
    defer client.close();
    try registerFor(&client, fixture.server);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try client.send(.{ .call = .{ .key = test_key, .id = 1, .tool = "echo", .arguments = "{\"text\":\"pid\"}" } });
    const called = try client.called(a, 1, 10_000);
    try testing.expectEqual(engine.Outcome.result, called.called.outcome);

    client.close();
    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "the event list's cap drops the frame and still takes the connection's leave" {
    const alloc = testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var owner: Owner = .{ .io = testing.io, .gpa = alloc, .stop = &stop, .client_version = test_client_version, .engine_arena = .init(alloc) };
    defer owner.engine_arena.deinit();
    defer owner.deinit();
    const pair = try testSocketPair("cap");
    defer pair.peer.close(testing.io);
    const conn = try alloc.create(Connection);
    conn.* = .{ .owner = &owner, .id = @fromBackingInt(1), .stream = pair.server };
    owner.connections[0] = conn;

    for (0..max_pending_events) |_| owner.push(.{ .core = .{ .hello = conn.id } });
    try testing.expectEqual(max_pending_events, owner.events.items.len);
    try testing.expect(!conn.gone);
    // One more from this client: the frame is dropped and the connection that
    // overran the cap goes, so its session runs every server itself.
    owner.push(.{ .core = .{ .hello = conn.id } });
    try testing.expect(conn.gone and conn.closed);
    // Its leave is the one event the cap never drops: without it the id would
    // never be freed and the connection never reaped.
    try testing.expectEqual(max_pending_events + 1, owner.events.items.len);
    try testing.expectEqual(conn.id, switch (owner.events.items[max_pending_events]) {
        .core => |e| switch (e) {
            .gone => |id| id,
            else => return error.NotALeave,
        },
        else => return error.NotALeave,
    });
    owner.push(.{ .core = .{ .gone = conn.id } });
    try testing.expectEqual(max_pending_events + 1, owner.events.items.len);

    // The loop stepped the leave and both tasks are gone: the reaper frees it
    // and lets its id be used again.
    owner.markLeft(conn.id);
    conn.running.store(0, .release);
    owner.reapConnections();
    try testing.expect(owner.connections[0] == null);
}

test "a connection whose reader cannot start is reaped, not freed under the table" {
    const alloc = testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var owner: Owner = .{ .io = testing.io, .gpa = alloc, .stop = &stop, .client_version = test_client_version, .engine_arena = .init(alloc) };
    owner.fail_task_start = .reader;
    defer owner.engine_arena.deinit();
    defer owner.deinit();
    const pair = try testSocketPair("no-reader");
    defer pair.peer.close(testing.io);

    try owner.addConnection(pair.server);
    // It is still in the table, alive, with no task running and its leave
    // waiting: the reaper owns it from here.
    const conn = owner.connections[0] orelse return error.ConnectionGone;
    try testing.expect(conn.gone and conn.closed);
    try testing.expectEqual(@as(u8, 0), conn.running.load(.acquire));
    owner.markLeft(conn.id);
    owner.reapConnections();
    try testing.expect(owner.connections[0] == null);
}

test "a connection whose writer cannot start ends its reader and is reaped" {
    const alloc = testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var owner: Owner = .{ .io = testing.io, .gpa = alloc, .stop = &stop, .client_version = test_client_version, .engine_arena = .init(alloc) };
    owner.fail_task_start = .writer;
    defer owner.engine_arena.deinit();
    defer owner.deinit();
    const pair = try testSocketPair("no-writer");
    defer pair.peer.close(testing.io);

    try owner.addConnection(pair.server);
    const conn = owner.connections[0] orelse return error.ConnectionGone;
    try testing.expect(conn.gone and conn.closed);
    // The writer failure cancelled the group itself, and marked that cancel,
    // so the leave below never cancels it a second time.
    try testing.expect(conn.cancelled);
    // The reader task ended by the group's cancel: no task runs, and the
    // reader never read from the stream after it was freed.
    try testing.expectEqual(@as(u8, 0), conn.running.load(.acquire));
    owner.markLeft(conn.id);
    owner.reapConnections();
    try testing.expect(owner.connections[0] == null);
}

test "a client the owner disconnects is ended, reaped, and its id used again" {
    const alloc = testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var owner: Owner = .{ .io = testing.io, .gpa = alloc, .stop = &stop, .client_version = test_client_version, .engine_arena = .init(alloc) };
    defer owner.engine_arena.deinit();
    defer owner.deinit();
    const first = try testSocketPair("owner-drop-1");
    defer first.peer.close(testing.io);
    try owner.addConnection(first.server);
    const conn = owner.connections[0] orelse return error.ConnectionGone;

    // The owner's own limit, not the session's: a client that overruns the
    // event list is dropped by the owner itself.
    for (0..max_pending_events) |_| owner.push(.{ .core = .{ .hello = conn.id } });
    owner.push(.{ .core = .{ .hello = conn.id } });
    try testing.expect(conn.gone and conn.closed);

    // The loop steps the leave and ends both tasks, so the reader stops even
    // though it is blocked in the socket.
    owner.markLeft(conn.id);
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (conn.running.load(.acquire) != 0) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > deadline) return error.TasksNeverEnded;
        // Polls for the cancel to end the reader in its socket read.
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    owner.reapConnections();
    try testing.expect(owner.connections[0] == null);
    // The session's end sees the close, so it learns the connection is gone:
    // it reads what the owner sent first (the welcome), then end of file.
    var buffer: [64]u8 = undefined;
    const eof_deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (true) {
        var data = [_][]u8{buffer[0..]};
        const read = try first.peer.readWithControl(testing.io, &data, &.{});
        if (read.data_len == 0) break;
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > eof_deadline) return error.NoEof;
    }

    // Its id is free again: the next client gets the one the first had.
    const second = try testSocketPair("owner-drop-2");
    defer second.peer.close(testing.io);
    try owner.addConnection(second.server);
    const next = owner.connections[0] orelse return error.ConnectionGone;
    try testing.expectEqual(@as(usize, 1), @backingInt(next.id));
    owner.markLeft(next.id);
    owner.reapConnections();
    try testing.expect(owner.connections[0] == null);
}

test "a registration the route table refuses stores no config, so the map stays at the key limit" {
    const alloc = testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var owner: Owner = .{ .io = testing.io, .gpa = alloc, .stop = &stop, .client_version = test_client_version, .engine_arena = .init(alloc) };
    defer owner.engine_arena.deinit();
    defer owner.deinit();
    const id: core.ClientId = @fromBackingInt(1);
    var state: core.State = .{};
    var hello: core.Output = .{};
    core.step(&state, .{ .hello = id }, &hello);
    // Two keys past the limit: the route table refuses those, and a refused
    // registration must store nothing, or one client could grow `configs`
    // without a cap.
    for (0..core.max_keys_per_client + 2) |n| {
        var key: core.Key = undefined;
        @memcpy(&key, &test_key);
        std.mem.writeInt(u32, key[28..32], @intCast(n), .big);
        var event: ShellEvent = .{ .register = .{
            .registered = .{ .client = id, .key = key, .ask_form = true, .ask_url = true },
            .config = try ownConfig(alloc, .{ .argv = &.{"server"} }),
        } };
        var output: core.Output = .{};
        core.step(&state, event.event(), &output);
        if (event.acceptedConfig(output.effects())) |config| storeConfig(&owner, key, config.take());
        event.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, core.max_keys_per_client), owner.configs.count());
}

test "an event still queued when the owner stops is freed with its strings" {
    const alloc = testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var owner: Owner = .{ .io = testing.io, .gpa = alloc, .stop = &stop, .client_version = test_client_version, .engine_arena = .init(alloc) };
    defer owner.engine_arena.deinit();
    const tool = try alloc.dupe(u8, "echo");
    const arguments = try alloc.dupe(u8, "{}");
    owner.push(.{ .call = .{ .client = @fromBackingInt(1), .id = 1, .key = test_key, .tool = tool, .arguments = arguments } });
    // A stop can land with events the loop never takes: their strings are this
    // allocator's, so one left behind fails this test as a leak.
    owner.deinit();
}

test "two clients registered for one key share one server process" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var first = try TestClient.connect(path);
    defer first.close();
    var second = try TestClient.connect(path);
    defer second.close();
    try registerFor(&first, fixture.server);
    try registerFor(&second, fixture.server);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // Let both registrations arrive before the calls, so they share the slot.
    // A registration has no answer to wait for, so a fixed window is the only
    // way to know the owner has both.
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    try first.send(.{ .call = .{ .key = test_key, .id = first.next, .tool = "echo", .arguments = "{\"text\":\"pid\"}" } });
    const one = try first.called(a, first.next, 10_000);
    try second.send(.{ .call = .{ .key = test_key, .id = 1, .tool = "echo", .arguments = "{\"text\":\"pid\"}" } });
    const two = try second.called(a, 1, 10_000);
    const first_pid = try pidFromAnswer(one.called.answer.?);
    const second_pid = try pidFromAnswer(two.called.answer.?);
    try testing.expectEqual(first_pid, second_pid);

    // Leaving: close both, stop the owner.
    first.close();
    second.close();
    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "a client's 33rd key is refused for that key, and the connection keeps the rest" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    defer {
        stop.store(true, .release);
        thread.join();
    }
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var client = try TestClient.connect(path);
    defer client.close();
    try client.send(.{ .hello = .{ .pid = 1 } });

    // Each key is its own launch config, so the owner gives each its own slot.
    const hex = "0123456789abcdef";
    var keys: [core.max_keys_per_client]core.Key = undefined;
    var buffer: [40]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        key.* = "00000000000000000000000000000000".*;
        key.*[30] = hex[i / 16];
        key.*[31] = hex[i % 16];
        // The first key's server exists, so its need is answered at once; the
        // others never start, because a registration alone starts nothing.
        const server = if (i == 0) fixture.server else try std.mem.print(&buffer, "/nonexistent/server-{d}", .{i});
        try client.send(.{ .register = .{
            .key = key.*,
            .config = .{ .argv = &.{server}, .timeouts = .{ .start_ms = 15_000 } },
            .ask_form = false,
            .ask_url = false,
        } });
    }
    // One more than a client may hold: the owner refuses that key and says
    // which, instead of dropping the connection.
    const extra: core.Key = "ffffffffffffffffffffffffffffffff".*;
    try client.send(.{ .register = .{
        .key = extra,
        .config = .{ .argv = &.{"/nonexistent/server-extra"}, .timeouts = .{ .start_ms = 15_000 } },
        .ask_form = false,
        .ask_url = false,
    } });

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var refused = false;
    const refusal_deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 15_000;
    refusal: while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < refusal_deadline) {
        const message = client.receive(a, 1_000) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        switch (message) {
            .owner => |owner| switch (owner) {
                .refused => |said| {
                    try testing.expectEqual(wire.Refused.too_many_keys, said.reason);
                    try testing.expectEqual(extra, said.key.?);
                    refused = true;
                    break :refusal;
                },
                else => {},
            },
            .client => return error.UnexpectedMessage,
        }
    }
    try testing.expect(refused);

    // The connection still works: its first key's need reaches the owner, and
    // its answer comes back on the same socket.
    try client.send(.{ .need = .{ .key = keys[0] } });
    var answered = false;
    const served_deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 20_000;
    served: while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < served_deadline) {
        const message = client.receive(a, 1_000) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        switch (message) {
            .owner => |owner| switch (owner) {
                .tools => |page| if (std.mem.eql(u8, &page.key, &keys[0])) {
                    // The owner answered this key on the same connection, so
                    // the refusal cost it nothing.
                    try testing.expect(page.ok);
                    answered = true;
                    break :served;
                },
                else => {},
            },
            .client => return error.UnexpectedMessage,
        }
    }
    try testing.expect(answered);
}

test "a client that leaves during a slow call does not end the other client's call" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var caller = try TestClient.connect(path);
    defer caller.close();
    var leaving = try TestClient.connect(path);
    try registerFor(&caller, fixture.server);
    try registerFor(&leaving, fixture.server);
    // Both registrations must reach the owner before a call goes out; a
    // registration has no answer to wait for.
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    // The fake never answers a call that mentions "slow".
    try caller.send(.{ .call = .{ .key = test_key, .id = 1, .tool = "echo", .arguments = "{\"text\":\"slow\"}" } });
    // The call must be in flight when the other client leaves, and the owner
    // tells the session nothing when it takes the call.
    testing.io.sleep(.fromMilliseconds(200), .awake) catch {};
    leaving.close();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    // Nothing ended the caller's call.
    _ = caller.called(arena.allocator(), 1, 400) catch |err| switch (err) {
        error.Timeout => {},
        else => return err,
    };
    // It ends when its own caller cancels it.
    try caller.send(.{ .cancel = .{ .id = 1 } });
    const ended = try caller.called(arena.allocator(), 1, 5_000);
    try testing.expectEqual(engine.Outcome.cancelled, ended.called.outcome);

    caller.close();
    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "a server stops when its last client leaves, and the owner returns" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var client = try TestClient.connect(path);
    try registerFor(&client, fixture.server);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    try client.send(.{ .call = .{ .key = test_key, .id = 1, .tool = "echo", .arguments = "{\"text\":\"pid\"}" } });
    const called = try client.called(arena.allocator(), 1, 10_000);
    const pid = try pidFromAnswer(called.called.answer.?);

    // The session says goodbye; the owner disconnects the key and stops the server.
    try client.send(.bye);
    client.close();
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (try running(pid)) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > deadline) return error.ServerStillRunning;
        // Polls the server process's exit, bounded by the deadline above.
        testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    const before = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    thread.join();
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - before <= 2_000);
}

test "a second owner on one fx home returns at once with the lock busy" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var second = std.atomic.Value(bool).init(false);
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try testing.expectError(error.LockBusy, serve(testing.io, alloc, home, &second, test_client_version));
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 1_000);

    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "stopping the owner with a connected client returns within 2 s, and the client sees the connection end" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);
    var client = try TestClient.connect(path);
    // The owner closes its side of this socket below, so close the raw
    // descriptor rather than asking the io to close an already ended stream.
    defer _ = std.c.close(client.stream.socket.handle);
    try client.send(.{ .hello = .{ .pid = 1 } });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    // The welcome, so the owner has taken this connection.
    _ = try client.receive(arena.allocator(), 5_000);

    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    stop.store(true, .release);
    thread.join();
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started <= 2_000);
    // The client's side ended: its next read returns zero.
    var byte: [1]u8 = undefined;
    try testing.expectEqual(0, try std.posix.read(client.stream.socket.handle, &byte));
}

test "a registered client hears connecting and ready before the tool list" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var client = try TestClient.connect(path);
    defer client.close();
    try registerFor(&client, fixture.server);
    try client.send(.{ .need = .{ .key = test_key } });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var saw_connecting = false;
    var saw_ready = false;
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 10_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const message = client.receive(arena.allocator(), 200) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        switch (message) {
            .owner => |owner| switch (owner) {
                .phase => |phase| {
                    if (phase.phase == .connecting) saw_connecting = true;
                    if (phase.phase == .ready) saw_ready = true;
                },
                .tools => {
                    try testing.expect(saw_connecting);
                    try testing.expect(saw_ready);
                    client.close();
                    stop.store(true, .release);
                    thread.join();
                    joined = true;
                    return;
                },
                else => {},
            },
            .client => {},
        }
    }
    return error.NoToolsFrame;
}

test "a call's end that cannot be built is replaced by one that ends the call" {
    // The answer did not fit a frame, so the session gets a small end instead
    // of waiting out the call's deadline.
    const end = frameThatEndsTheCall(.{ .called = .{ .id = 9, .outcome = .result, .maybe_ran = false, .timed_out = false, .answer = "{}" } }).?;
    try testing.expectEqual(@as(u32, 9), end.called.id);
    try testing.expectEqual(engine.Outcome.malformed, end.called.outcome);
    try testing.expect(end.called.maybe_ran);
    try testing.expect(end.called.answer == null);
    const frame = try wire.encode(testing.allocator, end);
    defer testing.allocator.free(frame);
    try testing.expect(frame.len < 1024);
    // A message that names no call has nothing to stand in.
    try testing.expect(frameThatEndsTheCall(.{ .progress = .{ .id = 9, .progress = 0.5 } }) == null);
}

test "a failing server's status reaches a client before the phase frame that ends its wait" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc);
    defer removeHome(alloc, home);
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try socketPath(alloc, home);
    defer alloc.free(path);
    try waitForSocket(path);

    var client = try TestClient.connect(path);
    defer client.close();
    try client.send(.{ .hello = .{ .pid = 1 } });
    try client.send(.{
        .register = .{
            .key = test_key,
            // A server that exits at once: the session waiting on it ends its
            // request on the phase frame, with the failure text it was told.
            .config = .{ .argv = &.{ "sh", "-c", "exit 7" }, .timeouts = .{ .start_ms = 15_000 } },
            .ask_form = false,
            .ask_url = false,
        },
    });
    try client.send(.{ .need = .{ .key = test_key } });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var status_seen = false;
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 20_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const message = client.receive(arena.allocator(), 500) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        switch (message) {
            .owner => |owner| switch (owner) {
                .status => |status| {
                    if (std.mem.eql(u8, &status.key, &test_key) and status.last_error != null and status.exit_code != null) status_seen = true;
                },
                .phase => |phase| {
                    if (phase.phase != .backoff and phase.phase != .failed) continue;
                    try testing.expect(status_seen);
                    client.close();
                    stop.store(true, .release);
                    thread.join();
                    joined = true;
                    return;
                },
                else => {},
            },
            .client => {},
        }
    }
    return error.NoFailedPhaseFrame;
}

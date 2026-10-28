//! Same-executable detached session owner. Existing ACP hosts run the native
//! fx engine, each on its session's executor thread (`session.zig`).
//!
//! The accept loop only accepts: each client connection gets its own pump
//! thread (`Conn`), which answers supervisor-wide requests itself and hands
//! every session request, with its connection, to that session's executor.
//! A slow client, open, or command therefore never stalls another. Routing
//! (registry membership, the saved-session index, list watchers) happens
//! under `route_mutex`. The registry (`sessions`, `last_attached_id`) and
//! the state file change only under `registry_mutex`; a session's own record
//! changes only through `commit`, which saves it first.
//!
//! An unused supervisor exits by itself: once no client is connected and no
//! session has running work or an armed heartbeat for `idle_env`
//! milliseconds, it shuts down as `daemon stop` does. It also stops when its
//! socket is removed, and leaves without saving when its state directory is.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const acp_config = @import("../cli/acp_runner.zig");
const session_adapter = @import("../session/session_adapter.zig");
const session_store = @import("../session/session_store.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const Channel = @import("channel.zig").Channel;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Record = session_mod.Record;
const Allocator = std.mem.Allocator;
extern "c" fn setsid() c_int;

const max_sessions = 128;
/// How long `list` reuses the store's saved-session index, which is also how
/// often a watched list looks for sessions saved elsewhere. A commit
/// invalidates the index at once.
const saved_index_ttl_ms = 2_000;

/// The state file, `sessions.json`.
const SavedState = struct {
    version: u32 = 1,
    sessions: []const SavedRow = &.{},
    last_attached_id: ?[]const u8 = null,
};

const SavedRow = struct {
    id: []const u8,
    name: []const u8 = "session",
    cwd: []const u8,
    stopped: bool = false,
    heartbeat: protocol.Heartbeat = .{},
    updated_at_ms: i64 = 0,
    owned: bool = true,

    fn of(id: []const u8, cwd: []const u8, record: *const Record) SavedRow {
        return .{
            .id = id,
            .name = record.name,
            .cwd = cwd,
            .stopped = record.stopped,
            .heartbeat = record.heartbeat,
            .updated_at_ms = record.updated_at_ms,
            .owned = record.reopens(),
        };
    }
};

/// The ids of root sessions the store holds a conversation for.
const SavedIndex = struct {
    ids: std.StringHashMapUnmanaged(void) = .empty,
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    refreshed_ms: i64 = 0,

    fn deinit(self: *SavedIndex, alloc: Allocator) void {
        self.ids.deinit(alloc);
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        self.* = .{};
    }

    pub fn contains(self: *const SavedIndex, id: []const u8) bool {
        return self.ids.contains(id);
    }
};

/// One client connection and the thread that pumps it. The thread, the
/// daemon's connection list, jobs that answer on it, and the session and list
/// watches it holds each keep a reference; the last release frees it.
pub const Conn = struct {
    daemon: *Daemon,
    stream: std.Io.net.Stream,
    channel: Channel,
    refs: std.atomic.Value(u32) = .init(2),
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    watched_mutex: std.Io.Mutex = .init,
    /// The session this connection last attached to, which pushes to it.
    watched: ?[]u8 = null,

    pub fn retain(self: *Conn) *Conn {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Conn) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.daemon.alloc;
        self.channel.deinit();
        if (self.watched) |id| alloc.free(id);
        alloc.destroy(self);
    }

    pub fn isOpen(self: *Conn) bool {
        return !self.channel.isClosed();
    }

    /// Answers request `id`, or a one-shot request (null `id`) and then
    /// hangs up.
    pub fn reply(self: *Conn, arena: Allocator, id: ?u64, bytes: []const u8) void {
        const request_id = id orelse {
            self.channel.send(bytes) catch {};
            return self.channel.finish();
        };
        const framed = protocol.encode(arena, protocol.ReplyFrame{ .id = request_id, .response = .{ .bytes = bytes } }) catch return;
        self.channel.send(framed) catch {};
    }

    pub fn push(self: *Conn, arena: Allocator, topic: protocol.Topic, body: []const u8) !void {
        try self.channel.send(try protocol.encode(arena, protocol.UpdateFrame{ .update = topic, .body = .{ .bytes = body } }));
    }

    /// Records `id` as the watched session. Returns the session watched
    /// before, if another; the caller owns it.
    pub fn watchSession(self: *Conn, alloc: Allocator, id: []const u8) !?[]u8 {
        const owned = try alloc.dupe(u8, id);
        self.watched_mutex.lockUncancelable(io_mod.getIo());
        defer self.watched_mutex.unlock(io_mod.getIo());
        const previous = self.watched;
        self.watched = owned;
        const old = previous orelse return null;
        if (!std.mem.eql(u8, old, id)) return old;
        alloc.free(old);
        return null;
    }

    fn main(self: *Conn) void {
        self.channel.pump(self.stream, self) catch {};
        self.channel.shutDown();
        self.daemon.forget(self);
        self.stream.close(io_mod.getIo());
        self.done.store(true, .release);
        self.release();
    }

    /// The pump's frame handler.
    pub fn frame(self: *Conn, bytes: []const u8) void {
        self.daemon.route(self, bytes);
    }
};

/// Where a request's answer goes: the request `id` on a kept-open
/// connection, or a one-shot exchange when `id` is null.
const Reply = struct { conn: *Conn, id: ?u64 = null };

/// One request with the connection that waits for its answer. The request
/// borrows `arena`. A null `reply` is the supervisor's own request.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    request: protocol.Request,
    /// Holds a reference on its connection.
    reply: ?Reply = null,
    /// A failed open records the failure on the session instead of only
    /// answering, as a restore at startup does.
    record_failure: bool = false,

    pub fn destroy(self: *Job, alloc: Allocator) void {
        if (self.reply) |reply| reply.conn.release();
        self.arena.deinit();
        alloc.destroy(self);
    }

    pub fn answer(self: *Job, bytes: []const u8) void {
        const reply = self.reply orelse return;
        reply.conn.reply(self.arena.allocator(), reply.id, bytes);
    }

    /// The connection that may watch what this request reads: only a
    /// kept-open one.
    pub fn watcher(self: *const Job) ?*Conn {
        const reply = self.reply orelse return null;
        return if (reply.id != null) reply.conn else null;
    }
};

pub fn answerFailure(job: *Job, message: []const u8) void {
    job.answer(protocol.encode(job.arena.allocator(), protocol.Failure{ .@"error" = message }) catch return);
}

pub const Daemon = struct {
    alloc: Allocator,
    cfg: acp_config.Config,
    home: []const u8,
    state_path: []const u8,
    incarnation: []const u8,
    registry_mutex: std.Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,
    last_attached_id: ?[]u8 = null,
    stopping: std.atomic.Value(bool) = .init(false),
    saved_index: SavedIndex = .{},
    saved_index_stale: std.atomic.Value(bool) = .init(true),

    route_mutex: std.Io.Mutex = .init,
    /// Accept-loop owned; each entry holds a reference.
    connections: std.ArrayList(*Conn) = .empty,
    /// Guarded by `route_mutex`; each entry holds a reference.
    list_watchers: std.ArrayList(*Conn) = .empty,
    /// Bumped whenever a listed session may look different.
    list_version: std.atomic.Value(u64) = .init(0),
    list_pushed: struct { version: u64 = 0, at_ms: i64 = 0, digest: u64 = 0 } = .{},
    /// Open connections, the asking one included, for `ping` (D142).
    clients: std.atomic.Value(u32) = .init(0),
    /// The binary this supervisor runs and its inode at startup. `proto-fx
    /// update` compares them with the file now at that path (D142).
    executable: []const u8 = "",
    executable_inode: ?u64 = null,

    fn deinit(self: *Daemon) void {
        // Stop every executor before freeing any session: a running one may
        // still save the registry, which reads every session.
        for (self.sessions.items) |session| session.stopExecutor();
        for (self.sessions.items) |session| session.destroy();
        self.sessions.deinit(self.alloc);
        for (self.list_watchers.items) |conn| conn.release();
        self.list_watchers.deinit(self.alloc);
        self.connections.deinit(self.alloc);
        if (self.last_attached_id) |id| self.alloc.free(id);
        self.saved_index.deinit(self.alloc);
    }

    /// Whether anything keeps the supervisor from exiting idle: a client
    /// connection, or a session with running work or an armed heartbeat
    /// (`Session.holds_daemon`). An idle kernel does not: shutdown saves its
    /// globals and the next use restores them. Holds `route_mutex`.
    fn holdsOpen(self: *Daemon) bool {
        if (self.connections.items.len > 0) return true;
        for (self.sessions.items) |session| if (session.holds_daemon.load(.acquire)) return true;
        return false;
    }

    /// Answers `ping` with what `proto-fx update` needs to decide whether
    /// this supervisor may restart on a new binary. Holds `route_mutex`.
    fn pong(self: *Daemon) protocol.Pong {
        var busy = false;
        for (self.sessions.items) |session| busy = busy or session.holds_daemon.load(.acquire);
        return .{
            .executable = self.executable,
            .executable_inode = self.executable_inode,
            .busy = busy,
            .clients = self.clients.load(.acquire),
        };
    }

    pub fn noteListChange(self: *Daemon) void {
        _ = self.list_version.fetchAdd(1, .release);
    }

    pub fn find(self: *Daemon, id: []const u8) ?*Session {
        self.registry_mutex.lockUncancelable(io_mod.getIo());
        defer self.registry_mutex.unlock(io_mod.getIo());
        for (self.sessions.items) |session| if (session.idEquals(id)) return session;
        return null;
    }

    /// Saves the registry with `next` in place of `session`'s record, then
    /// makes it current; `attach` also records `session` as the one the user
    /// last attached. Takes ownership of `next`: on failure nothing changes.
    pub fn commit(self: *Daemon, session: *Session, next: *Record, attach: bool) !void {
        defer next.deinit(self.alloc);
        self.registry_mutex.lockUncancelable(io_mod.getIo());
        defer self.registry_mutex.unlock(io_mod.getIo());
        const attached = if (attach) session.id else self.last_attached_id;
        try self.persistLocked(.{ .session = session, .record = next }, attached);
        if (attach and !(self.last_attached_id != null and std.mem.eql(u8, self.last_attached_id.?, session.id))) {
            const id = try self.alloc.dupe(u8, session.id);
            if (self.last_attached_id) |old| self.alloc.free(old);
            self.last_attached_id = id;
        }
        session.record_mutex.lockUncancelable(io_mod.getIo());
        std.mem.swap(Record, &session.record, next);
        session.record_mutex.unlock(io_mod.getIo());
        self.saved_index_stale.store(true, .release);
        session.noteRecordChange();
    }

    fn persist(self: *Daemon) !void {
        self.registry_mutex.lockUncancelable(io_mod.getIo());
        defer self.registry_mutex.unlock(io_mod.getIo());
        try self.persistLocked(null, self.last_attached_id);
    }

    const Replacement = struct { session: *Session, record: *const Record };

    /// Writes the state file. Holds `registry_mutex`; each other session's
    /// record is read under its own lock.
    fn persistLocked(self: *Daemon, replacement: ?Replacement, last_attached_id: ?[]const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var rows: std.ArrayList(SavedRow) = .empty;
        for (self.sessions.items) |session| {
            if (replacement) |swap| if (swap.session == session) {
                try rows.append(arena, try dupeRow(arena, SavedRow.of(session.id, session.cwd, swap.record)));
                continue;
            };
            session.record_mutex.lockUncancelable(io_mod.getIo());
            defer session.record_mutex.unlock(io_mod.getIo());
            if (session.id.len == 0) continue;
            try rows.append(arena, try dupeRow(arena, SavedRow.of(session.id, session.cwd, &session.record)));
        }
        const bytes = try std.json.Stringify.valueAlloc(arena, SavedState{ .sessions = rows.items, .last_attached_id = last_attached_id }, .{});
        try io_mod.writeFileAtomic(self.alloc, self.state_path, bytes);
    }

    fn dupeRow(arena: Allocator, row: SavedRow) !SavedRow {
        var copy = row;
        copy.id = try arena.dupe(u8, row.id);
        copy.name = try arena.dupe(u8, row.name);
        copy.cwd = try arena.dupe(u8, row.cwd);
        copy.heartbeat.prompt = try arena.dupe(u8, row.heartbeat.prompt);
        return copy;
    }

    /// Adds a session to the registry. A saved-only discovery row makes room
    /// when the registry is full, so it never blocks a new live session.
    fn register(self: *Daemon, id: []const u8, cwd: []const u8, name: []const u8) !*Session {
        const session = try Session.create(self, id, cwd, name);
        errdefer session.destroy();
        self.registry_mutex.lockUncancelable(io_mod.getIo());
        defer self.registry_mutex.unlock(io_mod.getIo());
        if (self.sessions.items.len >= max_sessions) {
            for (self.sessions.items, 0..) |entry, index| {
                if (!entry.hasExecutor() and !entry.record.stopped and entry.record.failure == null) {
                    _ = self.sessions.orderedRemove(index);
                    entry.destroy();
                    break;
                }
            } else return error.SessionLimit;
        }
        try self.sessions.append(self.alloc, session);
        return session;
    }

    /// Drops sessions whose first open failed or that were deleted, then
    /// saves the registry without them. Their executors have ended or are
    /// ending. Holds `route_mutex`, so no request reaches a dropped one.
    fn reapRetired(self: *Daemon) void {
        var reaped = false;
        var index: usize = 0;
        while (index < self.sessions.items.len) {
            const session = self.sessions.items[index];
            if (!session.retired.load(.acquire)) {
                index += 1;
                continue;
            }
            self.registry_mutex.lockUncancelable(io_mod.getIo());
            _ = self.sessions.orderedRemove(index);
            if (self.last_attached_id) |attached| if (session.id.len > 0 and std.mem.eql(u8, attached, session.id)) {
                self.alloc.free(attached);
                self.last_attached_id = null;
            };
            self.registry_mutex.unlock(io_mod.getIo());
            session.destroy();
            reaped = true;
        }
        if (!reaped) return;
        self.saved_index_stale.store(true, .release);
        self.noteListChange();
        self.persist() catch |err| std.debug.print("proto-fx: saving the session registry failed: {s}\n", .{@errorName(err)});
    }

    /// Refreshes the saved-session index when it is stale, adds a row for
    /// each saved session the registry lacks, and drops idle rows whose
    /// conversation is gone: a launch whose first prompt never arrived, or a
    /// session the user deleted.
    fn discoverSaved(self: *Daemon) !void {
        const now = io_mod.milliTimestamp();
        if (!self.saved_index_stale.swap(false, .acq_rel) and now - self.saved_index.refreshed_ms < saved_index_ttl_ms) return;
        errdefer self.saved_index_stale.store(true, .release);
        var store = try session_adapter.Store.open(self.alloc, self.home);
        defer store.deinit(self.alloc);
        const cancel = std.atomic.Value(bool).init(false);
        var next: SavedIndex = .{ .summaries = try session_adapter.listSummaries(&store, self.alloc, null, &cancel), .refreshed_ms = now };
        errdefer next.deinit(self.alloc);
        for (next.summaries.items) |summary| try next.ids.put(self.alloc, summary.id, {});
        self.saved_index.deinit(self.alloc);
        self.saved_index = next;

        var pruned = false;
        var index: usize = 0;
        while (index < self.sessions.items.len) {
            const session = self.sessions.items[index];
            if (session.hasExecutor() or session.id.len == 0 or self.saved_index.contains(session.id)) {
                index += 1;
                continue;
            }
            self.registry_mutex.lockUncancelable(io_mod.getIo());
            _ = self.sessions.orderedRemove(index);
            if (self.last_attached_id) |attached| if (std.mem.eql(u8, attached, session.id)) {
                self.alloc.free(attached);
                self.last_attached_id = null;
            };
            self.registry_mutex.unlock(io_mod.getIo());
            session.destroy();
            pruned = true;
        }
        if (pruned) try self.persist();
        for (self.saved_index.summaries.items) |summary| {
            if (self.sessions.items.len >= max_sessions) break;
            if (self.find(summary.id) != null) continue;
            const cwd = summary.workspace_root orelse summary.origin_workspace_root orelse continue;
            _ = try self.register(summary.id, cwd, summary.title orelse "session");
        }
    }

    /// Sends the session list to its watchers when it changed. Holds
    /// `route_mutex`.
    fn pushList(self: *Daemon) void {
        if (self.list_watchers.items.len == 0) return;
        const version = self.list_version.load(.acquire);
        const now = io_mod.milliTimestamp();
        if (version == self.list_pushed.version and now - self.list_pushed.at_ms < saved_index_ttl_ms) return;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const bytes = self.list(arena) catch return;
        const digest = std.hash.Wyhash.hash(0, bytes);
        const changed = digest != self.list_pushed.digest;
        self.list_pushed = .{ .version = version, .at_ms = now, .digest = digest };
        if (!changed) return;
        for (self.list_watchers.items) |conn| conn.push(arena, .list, bytes) catch {};
    }

    /// Holds `route_mutex`.
    fn watchList(self: *Daemon, conn: *Conn) !void {
        for (self.list_watchers.items) |watcher| if (watcher == conn) return;
        try self.list_watchers.append(self.alloc, conn.retain());
    }

    /// Holds `route_mutex`.
    fn unwatchList(self: *Daemon, conn: *Conn) void {
        for (self.list_watchers.items, 0..) |watcher, index| if (watcher == conn) {
            _ = self.list_watchers.swapRemove(index);
            return conn.release();
        };
    }

    /// Drops everything `conn` watches once it closed.
    fn forget(self: *Daemon, conn: *Conn) void {
        self.route_mutex.lockUncancelable(io_mod.getIo());
        defer self.route_mutex.unlock(io_mod.getIo());
        self.unwatchList(conn);
        conn.watched_mutex.lockUncancelable(io_mod.getIo());
        const watched = conn.watched;
        conn.watched_mutex.unlock(io_mod.getIo());
        const id = watched orelse return;
        if (self.find(id)) |session| session.watchers.forget(self.alloc, conn);
    }

    /// Starts a pump thread for a new connection.
    fn serve(self: *Daemon, stream: std.Io.net.Stream) !void {
        const conn = try self.alloc.create(Conn);
        errdefer self.alloc.destroy(conn);
        conn.* = .{ .daemon = self, .stream = stream, .channel = try Channel.init(self.alloc) };
        errdefer conn.channel.deinit();
        try self.connections.ensureUnusedCapacity(self.alloc, 1);
        conn.thread = try std.Thread.spawn(.{}, Conn.main, .{conn});
        self.connections.appendAssumeCapacity(conn);
        _ = self.clients.fetchAdd(1, .release);
    }

    /// Tells every client the stop is intentional, then closes the
    /// connections. A client that does not read within a second is cut off.
    fn closeConnections(self: *Daemon) void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        for (self.connections.items) |conn| {
            conn.push(arena_state.allocator(), .stopped, "{\"ok\":true}") catch {};
            conn.channel.finish();
        }
        const deadline = io_mod.milliTimestamp() + 1_000;
        for (self.connections.items) |conn| {
            while (!conn.done.load(.acquire) and io_mod.milliTimestamp() < deadline) io_mod.sleep(10 * std.time.ns_per_ms);
        }
        self.reapConnections(true);
    }

    /// Joins the threads of connections that ended, or of every connection
    /// once `all` closes them.
    fn reapConnections(self: *Daemon, all: bool) void {
        var index: usize = 0;
        while (index < self.connections.items.len) {
            const conn = self.connections.items[index];
            if (all) conn.channel.shutDown() else if (!conn.done.load(.acquire)) {
                index += 1;
                continue;
            }
            conn.thread.?.join();
            _ = self.connections.swapRemove(index);
            _ = self.clients.fetchSub(1, .release);
            conn.release();
        }
    }

    fn list(self: *Daemon, arena: Allocator) ![]const u8 {
        try self.discoverSaved();
        var rows: std.ArrayList(protocol.SessionSummary) = .empty;
        for (self.sessions.items) |session| {
            if (!session.listable(&self.saved_index)) continue;
            try rows.append(arena, try session.summary(arena));
        }
        self.registry_mutex.lockUncancelable(io_mod.getIo());
        defer self.registry_mutex.unlock(io_mod.getIo());
        const attached = if (self.last_attached_id) |id| try arena.dupe(u8, id) else null;
        return protocol.encode(arena, protocol.SessionList{ .sessions = rows.items, .last_attached_id = attached });
    }

    /// Restores the registry from the state file. Sessions this supervisor
    /// owned reopen on their executors; a failure is recorded on the session.
    fn restore(self: *Daemon) !void {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), self.state_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(self.alloc, &file, 16 * 1024 * 1024);
        defer self.alloc.free(bytes);
        const parsed = try std.json.parseFromSlice(SavedState, self.alloc, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        for (parsed.value.sessions) |row| {
            if (row.id.len == 0 or self.find(row.id) != null) continue;
            const session = try self.register(row.id, row.cwd, row.name);
            session.record.updated_at_ms = row.updated_at_ms;
            session.record.stopped = row.stopped;
            session.record.heartbeat = row.heartbeat;
            session.record.heartbeat.prompt = if (row.heartbeat.prompt.len > 0) try self.alloc.dupe(u8, row.heartbeat.prompt) else "";
            if (!row.stopped and row.owned) {
                const job = try newJob(self.alloc);
                job.request = .{ .create = .{ .cwd = session.cwd, .@"resume" = session.id } };
                job.record_failure = true;
                session.submit(job);
            }
        }
        if (parsed.value.last_attached_id) |id| if (self.find(id) != null) {
            self.last_attached_id = try self.alloc.dupe(u8, id);
        };
    }

    /// Answers one request frame from `conn`. Session requests move, with
    /// the connection, to that session's executor; the rest are answered
    /// here, on the connection's thread.
    fn route(self: *Daemon, conn: *Conn, bytes: []const u8) void {
        const job = newJob(self.alloc) catch return;
        job.reply = .{ .conn = conn.retain() };
        const arena = job.arena.allocator();
        const answer: ?[]const u8 = self.routeJob(job, bytes) catch |err| (protocol.encode(arena, protocol.Failure{ .@"error" = @errorName(err) }) catch null);
        if (answer) |reply| {
            job.answer(reply);
            job.destroy(self.alloc);
        }
    }

    /// Returns the answer for a request handled here, or null when `job`
    /// moved to an executor.
    fn routeJob(self: *Daemon, job: *Job, bytes: []const u8) !?[]const u8 {
        const arena = job.arena.allocator();
        job.request = protocol.parseInbound(arena, bytes, &job.reply.?.id) catch return error.InvalidRequest;
        self.route_mutex.lockUncancelable(io_mod.getIo());
        defer self.route_mutex.unlock(io_mod.getIo());
        switch (job.request) {
            .ping => return try protocol.encode(arena, self.pong()),
            .shutdown => {
                self.stopping.store(true, .release);
                return try protocol.encode(arena, protocol.Ack{});
            },
            .list => |request| {
                const listed = try self.list(arena);
                if (request.watch) if (job.watcher()) |conn| try self.watchList(conn);
                return listed;
            },
            .unwatch => |request| if (request.topic == .list) {
                if (job.watcher()) |conn| self.unwatchList(conn);
                return try protocol.encode(arena, protocol.Ack{});
            },
            // A delete runs on the session's executor (`session_delete.zig`);
            // one the registry no longer holds is already gone, unless the
            // saved index still lists it.
            .delete => |request| if (self.find(request.session_id) == null) {
                if (self.saved_index.contains(request.session_id)) return try protocol.encode(arena, protocol.Failure{ .@"error" = "The supervisor has not loaded this session, so it was not deleted." });
                return try protocol.encode(arena, protocol.Ack{});
            },
            .create => |*request| {
                if (request.@"resume") |query| if (query.len > 0 and self.find(query) == null) {
                    // A resume may name a unique start of a session's id.
                    self.saved_index_stale.store(true, .release);
                    self.discoverSaved() catch {};
                    var ids: std.ArrayList([]const u8) = .empty;
                    for (self.sessions.items) |session| if (session.id.len > 0) try ids.append(arena, session.id);
                    switch (matchIdPrefix(ids.items, query)) {
                        .found => |id| request.@"resume" = try arena.dupe(u8, id),
                        .ambiguous => |count| return try protocol.encode(arena, protocol.Failure{ .@"error" = try arena.print("{d} saved sessions have ids that start with {s}; give more of the id.", .{ count, query }) }),
                        .none => return try protocol.encode(arena, protocol.Failure{ .@"error" = try arena.print("No saved session has an id that starts with {s}. List them with `proto-fx sessions`.", .{query}) }),
                    }
                };
                const existing = if (request.@"resume") |id| self.find(id) else null;
                const session = existing orelse new: {
                    const root = try io_mod.realpathAlloc(arena, request.cwd);
                    break :new try self.register("", root, request.name);
                };
                session.submit(job);
                return null;
            },
            else => {},
        }
        const session = self.find(job.request.sessionId() orelse return error.SessionNotFound) orelse return error.SessionNotFound;
        session.submit(job);
        return null;
    }
};

const PrefixMatch = union(enum) { found: []const u8, none, ambiguous: usize };

/// The one id `query` starts, or why there is none.
fn matchIdPrefix(ids: []const []const u8, query: []const u8) PrefixMatch {
    var found: ?[]const u8 = null;
    var count: usize = 0;
    for (ids) |id| if (std.mem.startsWith(u8, id, query)) {
        if (found) |seen| if (std.mem.eql(u8, seen, id)) continue;
        found = id;
        count += 1;
    };
    if (count > 1) return .{ .ambiguous = count };
    return if (found) |id| .{ .found = id } else .none;
}

fn newJob(alloc: Allocator) !*Job {
    const job = try alloc.create(Job);
    job.* = .{ .arena = std.heap.ArenaAllocator.init(alloc), .request = .ping };
    return job;
}

/// Runs until a shutdown request, an idle timeout, or the removal of its
/// socket or state directory. The caller initializes std.Io/env first.
pub fn run(alloc: Allocator, cfg: acp_config.Config) !void {
    _ = setsid();
    const io = io_mod.getIo();
    const dir_path = try client.stateDir(alloc);
    defer alloc.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
    const lock = try dir.createFile(io, "owner.lock", .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(io);
    if (!try lock.tryLock(io, .exclusive)) return error.DaemonAlreadyRunning;
    defer lock.unlock(io);
    const socket_path = try client.socketPath(alloc);
    defer alloc.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| if (err != error.FileNotFound) return err;
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    const anchor = try Anchor.init(dir_path, socket_path);
    const state_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(state_path);
    const incarnation = try alloc.print("{d}-{d}", .{ io_mod.milliTimestamp(), std.c.getpid() });
    defer alloc.free(incarnation);
    var daemon = Daemon{ .alloc = alloc, .cfg = cfg, .home = io_mod.homeDir() orelse return error.HomeUnavailable, .state_path = state_path, .incarnation = incarnation };
    // Executors close their hosts as the registry is freed.
    defer daemon.deinit();
    const executable = std.process.executablePathAlloc(io, alloc) catch null;
    defer if (executable) |path| alloc.free(path);
    if (executable) |path| {
        daemon.executable = path;
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| daemon.executable_inode = @intCast(stat.inode) else |_| {}
    }
    try daemon.restore();
    try daemon.discoverSaved();
    if (comptime builtin.optimize == .debug) armDebugPanic();
    const idle_limit_ms = idleLimitMs(io_mod.getenv(idle_env));
    var idle_since = io_mod.milliTimestamp();
    var log_checked_ms: i64 = 0;
    const exit: Exit = while (true) {
        if (daemon.stopping.load(.acquire)) break .requested;
        daemon.reapConnections(false);
        const now = io_mod.milliTimestamp();
        if (now - log_checked_ms >= 5_000) {
            log_checked_ms = now;
            client.boundOwnLog();
        }
        {
            daemon.route_mutex.lockUncancelable(io);
            defer daemon.route_mutex.unlock(io);
            daemon.reapRetired();
            daemon.pushList();
            if (daemon.holdsOpen()) idle_since = now;
        }
        if (idle_limit_ms > 0 and now - idle_since >= idle_limit_ms) break .idle;
        switch (anchor.check()) {
            .present => {},
            .socket_removed => break .socket_removed,
            .state_removed => break .state_removed,
        }
        var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 200) == 0) continue;
        const stream = try listener.accept(io);
        daemon.serve(stream) catch stream.close(io);
    };
    // No request routes after this.
    daemon.closeConnections();
    if (exit == .state_removed) {
        // Saving, or closing hosts that snapshot kernels and write logs,
        // would recreate the profile someone deleted. Leave at once: the
        // kernels and tool processes watch for their owner to exit.
        std.debug.print("proto-fx: the supervisor state directory was removed; exiting without saving\n", .{});
        std.c._exit(0);
    }
    // Save while the hosts are still open: each live, saved session is
    // owned and reopens on the next start.
    try daemon.persist();
}

/// Debug builds only: names a delay in milliseconds after which the
/// supervisor panics, to reproduce a supervisor that keeps crashing.
const debug_panic_env = "PROTO_FX_DEBUG_DAEMON_PANIC_MS";

fn armDebugPanic() void {
    const raw = io_mod.getenv(debug_panic_env) orelse return;
    const delay_ms = std.fmt.parseInt(u32, raw, 10) catch return;
    const thread = std.Thread.spawn(.{}, debugPanic, .{delay_ms}) catch return;
    thread.detach();
}

fn debugPanic(delay_ms: u32) void {
    io_mod.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
    @panic("debug supervisor panic (" ++ debug_panic_env ++ ")");
}

/// Why the accept loop ended. Every reason but `state_removed` shuts down
/// the way `daemon stop` does.
const Exit = enum { requested, idle, socket_removed, state_removed };

/// Names how long an unused supervisor waits before it exits; 0 disables it.
pub const idle_env = "PROTO_FX_DAEMON_IDLE_MS";
const default_idle_ms: i64 = 10 * 60 * 1000;

fn idleLimitMs(raw: ?[]const u8) i64 {
    const text = raw orelse return default_idle_ms;
    return std.fmt.parseInt(i64, text, 10) catch default_idle_ms;
}

/// The supervisor's socket and state directory as it created them. Another
/// file at either path, or none, means this supervisor can no longer be
/// reached or can no longer save.
const Anchor = struct {
    dir_path: []const u8,
    dir_inode: std.Io.File.INode,
    socket_path: []const u8,
    socket_inode: std.Io.File.INode,

    const Check = enum { present, socket_removed, state_removed };

    fn init(dir_path: []const u8, socket_path: []const u8) !Anchor {
        return .{
            .dir_path = dir_path,
            .dir_inode = try statPath(dir_path) orelse return error.FileNotFound,
            .socket_path = socket_path,
            .socket_inode = try statPath(socket_path) orelse return error.FileNotFound,
        };
    }

    fn check(self: *const Anchor) Check {
        if (same(self.socket_path, self.socket_inode)) return .present;
        return if (same(self.dir_path, self.dir_inode)) .socket_removed else .state_removed;
    }

    /// An unreadable path counts as unchanged: only a missing or replaced
    /// one ends the supervisor.
    fn same(path: []const u8, inode: std.Io.File.INode) bool {
        const current = statPath(path) catch return true;
        return if (current) |found| found == inode else false;
    }

    fn statPath(path: []const u8) !?std.Io.File.INode {
        const found = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        return found.inode;
    }
};

test "the idle limit defaults to ten minutes and zero disables it" {
    try std.testing.expectEqual(default_idle_ms, idleLimitMs(null));
    try std.testing.expectEqual(default_idle_ms, idleLimitMs("soon"));
    try std.testing.expectEqual(@as(i64, 1500), idleLimitMs("1500"));
    try std.testing.expectEqual(@as(i64, 0), idleLimitMs("0"));
}

test "a delete runs on the executor: refused while in use or busy, else saved stopped and reaped" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const session_delete = @import("session_delete.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const state_path = try std.Io.Dir.path.join(alloc, &.{ home, "sessions.json" });
    defer alloc.free(state_path);
    var daemon = Daemon{ .alloc = alloc, .cfg = undefined, .home = home, .state_path = state_path, .incarnation = "test" };
    defer daemon.deinit();

    const session = try daemon.register("S1", "/w", "one");
    daemon.last_attached_id = try alloc.dupe(u8, "S1");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = session_delete.Refusal.busy.text();

    // A turn keeps it, and so does an armed heartbeat.
    session.record.running = true;
    try std.testing.expect(std.mem.find(u8, try session_delete.run(session, a), refused) != null);
    session.record.running = false;
    session.record.heartbeat.interval_ms = 60_000;
    session.record.heartbeat.paused = false;
    try std.testing.expect(std.mem.find(u8, try session_delete.run(session, a), session_delete.Refusal.heartbeat.text()) != null);
    session.record.heartbeat.paused = true;
    try std.testing.expect(!session.retired.load(.acquire));

    // The last attached session is no longer special; with no viewer and no
    // work it goes, and the registry drops it.
    try std.testing.expectEqualStrings("{\"ok\":true}", try session_delete.run(session, a));
    try std.testing.expect(session.retired.load(.acquire));
    daemon.reapRetired();
    try std.testing.expect(daemon.find("S1") == null);
    try std.testing.expect(daemon.last_attached_id == null);
    const saved = try tmp.dir.readFileAlloc(io, "sessions.json", alloc, .limited(1 << 16));
    defer alloc.free(saved);
    try std.testing.expect(std.mem.find(u8, saved, "S1") == null);
}

test "an anchor tells a removed socket from a removed state directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    try tmp.dir.createDirPath(io, "state");
    const dir_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "state");
    defer alloc.free(dir_path);
    const socket_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "control.sock" });
    defer alloc.free(socket_path);
    (try std.Io.Dir.cwd().createFile(io, socket_path, .{})).close(io);
    const anchor = try Anchor.init(dir_path, socket_path);
    try std.testing.expectEqual(Anchor.Check.present, anchor.check());
    try std.Io.Dir.deleteFileAbsolute(io, socket_path);
    try std.testing.expectEqual(Anchor.Check.socket_removed, anchor.check());
    try tmp.dir.deleteTree(io, "state");
    try std.testing.expectEqual(Anchor.Check.state_removed, anchor.check());
}

test "a resume id may be any unique start of a saved session's id" {
    const ids = [_][]const u8{ "G8ln8216A_wA", "G8lnZZ00b_x1", "PZjgRexiAKt6" };
    try std.testing.expectEqualStrings("PZjgRexiAKt6", matchIdPrefix(&ids, "PZjgRexi").found);
    try std.testing.expectEqualStrings("G8ln8216A_wA", matchIdPrefix(&ids, "G8ln8216").found);
    try std.testing.expectEqual(@as(usize, 2), matchIdPrefix(&ids, "G8ln").ambiguous);
    try std.testing.expect(matchIdPrefix(&ids, "nope") == .none);
}

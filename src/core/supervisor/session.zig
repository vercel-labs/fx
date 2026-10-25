//! One detached session and the executor thread that owns its host.
//!
//! The executor is the host's only owner (`acp.PersistentHost`): it runs
//! every request for this session in order, the heartbeat, and the child
//! approval pump, and it is the thread that opens and closes the host. The
//! accept loop only reads the session's `Record`, under `record_mutex`, and
//! hands requests over with their connection. The host's writer callback,
//! `publish`, may run on any host thread, so the event log has its own lock.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const acp = @import("../../acp/server.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const child_state = @import("../subagent/child_state.zig");
const live_presentation = @import("../subagent/live_presentation.zig");
const types = @import("../shared/types.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const Daemon = @import("server.zig").Daemon;
const Allocator = std.mem.Allocator;

const event_bytes_limit = 2 * 1024 * 1024;
const max_pending = 64;
const max_prompt_bytes = 1024 * 1024;
const max_heartbeat_prompt_bytes = 64 * 1024;
const max_heartbeat_interval_ms: u64 = 365 * 24 * 60 * 60 * 1000;
const tick_ms = 200;

pub const Record = @import("record.zig").Record;

const Pending = struct { id: i64, frame: []u8 };
const PendingCommand = struct { id: i64, name: []u8 };

/// One request with the connection that waits for its answer. The request
/// borrows `arena`. A null `reply` is the supervisor's own request.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    request: protocol.Request,
    reply: ?std.Io.net.Stream = null,
    /// A failed open records the failure on the session instead of only
    /// answering, as a restore at startup does.
    record_failure: bool = false,

    pub fn destroy(self: *Job, alloc: Allocator) void {
        if (self.reply) |stream| stream.close(io_mod.getIo());
        self.arena.deinit();
        alloc.destroy(self);
    }
};

pub const Session = struct {
    daemon: *Daemon,
    /// Fixed for the session's life once an open sets it; read it from
    /// another thread under `record_mutex`.
    id: []u8 = &.{},
    cwd: []u8,
    record_mutex: std.Io.Mutex = .init,
    record: Record,

    jobs_mutex: std.Io.Mutex = .init,
    jobs_cond: std.Io.Condition = .init,
    jobs: std.ArrayList(*Job) = .empty,
    quit: bool = false,
    thread: ?std.Thread = null,
    /// A new session whose open failed. The accept loop reaps it.
    retired: std.atomic.Value(bool) = .init(false),

    // Executor-owned.
    host: ?*acp.PersistentHost = null,
    next_request: i64 = 10,
    history_json: ?[]u8 = null,
    history_sequence: u64 = 0,
    history_dirty: bool = true,
    next_tick_ms: i64 = 0,

    // Guarded by `events_mutex`; `publish` runs on host threads.
    events_mutex: std.Io.Mutex = .init,
    events: std.ArrayList(Event) = .empty,
    event_bytes: usize = 0,
    sequence: u64 = 0,
    pending: std.ArrayList(Pending) = .empty,
    commands: std.ArrayList(PendingCommand) = .empty,
    heartbeat_request: ?i64 = null,
    capture: ?Capture = null,

    const Event = struct { sequence: u64, frame: []u8 };
    const Capture = struct { id: i64, frame: ?[]u8 = null };

    pub fn create(daemon: *Daemon, id: []const u8, cwd: []const u8, name: []const u8) !*Session {
        const alloc = daemon.alloc;
        const self = try alloc.create(Session);
        errdefer alloc.destroy(self);
        var record = try Record.init(alloc, name);
        errdefer record.deinit(alloc);
        const owned_cwd = try alloc.dupe(u8, cwd);
        errdefer alloc.free(owned_cwd);
        const owned_id = try alloc.dupe(u8, id);
        self.* = .{ .daemon = daemon, .id = owned_id, .cwd = owned_cwd, .record = record, .next_tick_ms = io_mod.milliTimestamp() };
        return self;
    }

    /// Stops the executor, which closes the host, then frees everything.
    pub fn destroy(self: *Session) void {
        const alloc = self.daemon.alloc;
        self.stopExecutor();
        for (self.events.items) |event| alloc.free(event.frame);
        self.events.deinit(alloc);
        self.clearPending();
        self.pending.deinit(alloc);
        for (self.commands.items) |command| alloc.free(command.name);
        self.commands.deinit(alloc);
        self.jobs.deinit(alloc);
        if (self.history_json) |history| alloc.free(history);
        alloc.free(self.id);
        alloc.free(self.cwd);
        self.record.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn idEquals(self: *Session, id: []const u8) bool {
        self.record_mutex.lockUncancelable(io_mod.getIo());
        defer self.record_mutex.unlock(io_mod.getIo());
        return self.id.len > 0 and std.mem.eql(u8, self.id, id);
    }

    pub fn hasExecutor(self: *const Session) bool {
        return self.thread != null;
    }

    /// Queues `job` for the executor, starting it on first use. Takes
    /// ownership of `job` even on failure.
    pub fn submit(self: *Session, job: *Job) void {
        const alloc = self.daemon.alloc;
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, executorMain, .{self}) catch |err| {
                answerFailure(job, @errorName(err));
                job.destroy(alloc);
                return;
            };
        }
        self.jobs_mutex.lockUncancelable(io_mod.getIo());
        defer self.jobs_mutex.unlock(io_mod.getIo());
        self.jobs.append(alloc, job) catch {
            answerFailure(job, "OutOfMemory");
            job.destroy(alloc);
            return;
        };
        self.jobs_cond.signal(io_mod.getIo());
    }

    pub fn stopExecutor(self: *Session) void {
        const thread = self.thread orelse return;
        self.jobs_mutex.lockUncancelable(io_mod.getIo());
        self.quit = true;
        self.jobs_cond.signal(io_mod.getIo());
        self.jobs_mutex.unlock(io_mod.getIo());
        thread.join();
        self.thread = null;
    }

    const Next = union(enum) { job: *Job, tick, quit };

    fn next(self: *Session) Next {
        const io = io_mod.getIo();
        self.jobs_mutex.lockUncancelable(io);
        defer self.jobs_mutex.unlock(io);
        while (true) {
            if (self.quit) return .quit;
            if (self.jobs.items.len > 0) return .{ .job = self.jobs.orderedRemove(0) };
            const wait_ms = self.next_tick_ms - io_mod.milliTimestamp();
            if (wait_ms <= 0) return .tick;
            self.jobs_cond.waitTimeout(io, &self.jobs_mutex, .{ .duration = .{
                .raw = .fromMilliseconds(wait_ms),
                .clock = .awake,
            } }) catch {};
        }
    }

    fn executorMain(self: *Session) void {
        while (true) {
            switch (self.next()) {
                .quit => break,
                .job => |job| self.run(job),
                .tick => {},
            }
            const now = io_mod.milliTimestamp();
            if (now >= self.next_tick_ms) {
                self.tick(now);
                self.next_tick_ms = now + tick_ms;
            }
            if (self.retired.load(.acquire)) break;
        }
        // Requests that arrived after shutdown began get an answer.
        self.jobs_mutex.lockUncancelable(io_mod.getIo());
        const left = self.jobs.toOwnedSlice(self.daemon.alloc) catch &.{};
        self.jobs_mutex.unlock(io_mod.getIo());
        defer self.daemon.alloc.free(left);
        for (left) |job| {
            answerFailure(job, "SupervisorStopping");
            job.destroy(self.daemon.alloc);
        }
        self.closeHost();
    }

    fn run(self: *Session, job: *Job) void {
        const arena = job.arena.allocator();
        const bytes = self.handle(arena, job) catch |err| protocol.encode(arena, protocol.Failure{ .@"error" = @errorName(err) }) catch "";
        if (job.reply) |stream| client.writeFrame(stream, bytes) catch {};
        job.destroy(self.daemon.alloc);
        self.refreshRecord() catch |err| std.debug.print("proto-fx: session record refresh failed: {s}\n", .{@errorName(err)});
    }

    fn handle(self: *Session, arena: Allocator, job: *Job) ![]const u8 {
        switch (job.request) {
            .create => |request| return self.open(arena, request.@"resume", job.record_failure),
            .attach => |request| {
                const include_history = request.include_history orelse (request.after_sequence == 0);
                // Background polls observe a stop; only a deliberate attach
                // reopens a stopped or saved session.
                if (include_history) return self.open(arena, self.id, false);
                return self.snapshot(arena, request.after_sequence, false);
            },
            .mode => |request| return self.nativeCall(arena, "session/set_mode", .{ .sessionId = self.id, .modeId = request.mode }),
            .model => |request| {
                if ((self.host orelse return error.SessionStopped).busy()) return error.SessionBusy;
                return self.nativeCall(arena, "session/set_config_option", .{ .sessionId = self.id, .configId = "model", .value = request.model });
            },
            // A frontend command that only sets a host config option names it
            // here; the host validates the value and answers.
            .option => |request| return self.nativeCall(arena, "session/set_config_option", .{
                .sessionId = self.id,
                .configId = request.config_id,
                .value = request.value,
            }),
            .command => |request| return self.hostCommand(arena, request),
            .rename => |request| return self.rename(arena, request.name),
            .kernel => |request| {
                const info = try (self.host orelse return error.SessionStopped).kernelControl(arena, request.action);
                return protocol.encode(arena, protocol.KernelState{ .kernel = .{ .state = info.state, .diagnostics = info.diagnostics } });
            },
            .prompt => |request| {
                const request_id = try self.prompt(request.text, .user);
                return protocol.encode(arena, protocol.PromptAdmitted{ .request_id = request_id });
            },
            .cancel => {
                const host = self.host orelse return error.SessionStopped;
                _ = try self.dispatch("session/cancel", .{ .sessionId = self.id }, .none);
                self.clearPending();
                host.refreshChildApprovals();
                return protocol.encode(arena, protocol.Ack{});
            },
            .permission => |request| {
                try self.answerPermission(request.request_id, request.option);
                return protocol.encode(arena, protocol.Ack{});
            },
            .stop => return self.stop(arena),
            .heartbeat => |request| return self.heartbeat(arena, request),
            .children => return self.children(arena),
            .history => |request| return self.historyView(arena, request),
            .ping, .shutdown, .list => return error.UnknownCommand,
        }
    }

    // -- host ownership ------------------------------------------------------

    /// Opens the host if it is closed, marks this session the one the user
    /// last attached, and answers with a full snapshot.
    fn open(self: *Session, arena: Allocator, resume_id: ?[]const u8, record_failure: bool) ![]const u8 {
        if (self.host == null) self.openHost(if (resume_id) |id| if (id.len > 0) id else null else null) catch |err| {
            if (self.id.len == 0) {
                self.retired.store(true, .release);
            } else if (record_failure) {
                var next_record = try self.record.clone(self.daemon.alloc);
                if (next_record.failure) |old| self.daemon.alloc.free(old);
                next_record.failure = self.daemon.alloc.dupe(u8, @errorName(err)) catch null;
                self.daemon.commit(self, &next_record, false) catch {};
                std.debug.print("proto-fx: cannot restore session {s}: {s}\n", .{ self.id, @errorName(err) });
            }
            return err;
        };
        var next_record = try self.liveRecord();
        next_record.stopped = false;
        if (next_record.failure) |failure| self.daemon.alloc.free(failure);
        next_record.failure = null;
        try self.daemon.commit(self, &next_record, !record_failure);
        return self.snapshot(arena, 0, true);
    }

    fn openHost(self: *Session, resume_id: ?[]const u8) !void {
        const alloc = self.daemon.alloc;
        var cfg = self.daemon.cfg;
        cfg.home_override = self.daemon.home;
        cfg.workspace_root_override = self.cwd;
        const host = try acp.PersistentHost.init(alloc, cfg, self, publish);
        errdefer host.deinit();
        host.state.native_presentation = true;
        self.host = host;
        errdefer self.host = null;
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const initialized = try self.call(arena, "initialize", .{
            .protocolVersion = 1,
            .clientCapabilities = .{},
            .clientInfo = .{ .name = "proto-fx", .version = "phase1" },
        });
        if (!host.state.initialized) {
            logStartupFailure(arena, initialized);
            return error.SessionInitializationFailed;
        }
        // The host already appends this workspace's project servers. The
        // profile's own servers are opt-in per session, and a detached session
        // should behave like the local TUI, so ask for them explicitly.
        const no_servers = [_]struct {}{};
        const meta = .{ .fx = .{ .profileMcpServers = true } };
        const opened = if (resume_id) |id|
            try self.call(arena, "session/load", .{ .sessionId = id, .cwd = self.cwd, .mcpServers = no_servers, ._meta = meta })
        else
            try self.call(arena, "session/new", .{ .cwd = self.cwd, .mcpServers = no_servers, ._meta = meta });
        const active = host.state.active_session orelse {
            logStartupFailure(arena, opened);
            return error.SessionOpenFailed;
        };
        if (self.id.len == 0) {
            const id = try alloc.dupe(u8, active.session_id);
            self.record_mutex.lockUncancelable(io_mod.getIo());
            self.id = id;
            self.record_mutex.unlock(io_mod.getIo());
        }
        self.history_dirty = true;
        try self.refreshHistory();
    }

    /// Closes the host on its owner thread. Deinit cancels the turn and any
    /// host job and joins them, so nothing runs on the host afterwards.
    fn closeHost(self: *Session) void {
        const host = self.host orelse return;
        host.deinit();
        self.host = null;
        self.clearPending();
        self.history_dirty = true;
    }

    fn logStartupFailure(arena: Allocator, response: ?[]const u8) void {
        const bytes = response orelse return;
        const Response = struct { @"error": ?struct { message: []const u8 = "unknown ACP error" } = null };
        const parsed = std.json.parseFromSliceLeaky(Response, arena, bytes, .{ .ignore_unknown_fields = true }) catch return;
        if (parsed.@"error") |failure| std.debug.print("proto-fx: session startup: {s}\n", .{failure.message});
    }

    const Track = union(enum) {
        none,
        /// Keep the response the host writes before dispatchFrame returns.
        capture,
        heartbeat,
        /// Turn the answer, whenever it comes, into a command result event.
        command: []const u8,
    };

    /// Sends one request to the host and returns its id.
    fn dispatch(self: *Session, method: []const u8, params: anytype, track: Track) !i64 {
        const host = self.host orelse return error.SessionStopped;
        const alloc = self.daemon.alloc;
        const id = self.next_request;
        self.next_request += 1;
        const frame = try std.json.Stringify.valueAlloc(alloc, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{ .emit_null_optional_fields = false });
        defer alloc.free(frame);
        switch (track) {
            .none => {},
            .capture => {
                self.events_mutex.lockUncancelable(io_mod.getIo());
                defer self.events_mutex.unlock(io_mod.getIo());
                self.capture = .{ .id = id };
            },
            .heartbeat => {
                self.events_mutex.lockUncancelable(io_mod.getIo());
                defer self.events_mutex.unlock(io_mod.getIo());
                self.heartbeat_request = id;
            },
            .command => |name| {
                const owned = try alloc.dupe(u8, name);
                errdefer alloc.free(owned);
                self.events_mutex.lockUncancelable(io_mod.getIo());
                defer self.events_mutex.unlock(io_mod.getIo());
                try self.commands.append(alloc, .{ .id = id, .name = owned });
            },
        }
        errdefer self.untrack(id);
        try host.dispatchFrame(frame);
        return id;
    }

    fn untrack(self: *Session, id: i64) void {
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        if (self.capture) |capture| if (capture.id == id) {
            if (capture.frame) |frame| self.daemon.alloc.free(frame);
            self.capture = null;
        };
        if (self.heartbeat_request == id) self.heartbeat_request = null;
        for (self.commands.items, 0..) |command, index| if (command.id == id) {
            self.daemon.alloc.free(command.name);
            _ = self.commands.orderedRemove(index);
            break;
        };
    }

    /// Sends a request the host answers before dispatchFrame returns and
    /// returns that answer, copied into `arena`, or null if none came.
    fn call(self: *Session, arena: Allocator, method: []const u8, params: anytype) !?[]const u8 {
        const id = try self.dispatch(method, params, .capture);
        self.events_mutex.lockUncancelable(io_mod.getIo());
        const captured = self.capture;
        self.capture = null;
        self.events_mutex.unlock(io_mod.getIo());
        const capture = captured orelse return null;
        std.debug.assert(capture.id == id);
        const frame = capture.frame orelse return null;
        defer self.daemon.alloc.free(frame);
        return try arena.dupe(u8, frame);
    }

    /// A host request whose answer is the response: `{ok, result}` or a failure.
    fn nativeCall(self: *Session, arena: Allocator, method: []const u8, params: anytype) ![]const u8 {
        const bytes = (try self.call(arena, method, params)) orelse return error.NativeCommandIncomplete;
        const Response = struct {
            result: ?std.json.Value = null,
            @"error": ?struct { message: []const u8 = "NativeCommandFailed" } = null,
        };
        const response = try std.json.parseFromSliceLeaky(Response, arena, bytes, .{ .ignore_unknown_fields = true });
        if (response.@"error") |failure| return protocol.encode(arena, protocol.Failure{ .@"error" = failure.message });
        return protocol.encode(arena, protocol.NativeResult(std.json.Value){ .result = response.result orelse return error.NativeCommandIncomplete });
    }

    /// Hands one frontend command to the host. The host owns its effect and
    /// its answer, which reaches the frontend through the event stream.
    fn hostCommand(self: *Session, arena: Allocator, request: protocol.HostCommand) ![]const u8 {
        if ((self.host orelse return error.SessionStopped).busy()) {
            return protocol.encode(arena, protocol.Failure{ .@"error" = "Session is busy" });
        }
        _ = try self.dispatch("fx/command", .{
            .sessionId = self.id,
            .command = request.name,
            .action = request.action,
            .path = request.path,
            .line = request.line,
        }, .{ .command = request.name });
        return protocol.encode(arena, protocol.CommandAccepted{});
    }

    const PromptOrigin = enum { user, heartbeat };

    fn prompt(self: *Session, text: []const u8, origin: PromptOrigin) !i64 {
        if (text.len == 0 or text.len > max_prompt_bytes) return error.InvalidPrompt;
        const host = self.host orelse return error.SessionStopped;
        // Steering may join a running turn; a host job owns the session.
        if (host.busy() and host.state.active_prompt == null) return error.SessionBusy;
        try self.refreshHistory();
        self.history_dirty = true;
        {
            self.record_mutex.lockUncancelable(io_mod.getIo());
            defer self.record_mutex.unlock(io_mod.getIo());
            self.record.updated_at_ms = io_mod.milliTimestamp();
        }
        const blocks = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }};
        return self.dispatch("session/prompt", .{
            .sessionId = self.id,
            .prompt = &blocks,
            ._meta = .{ .fx = .{ .steer = true } },
        }, if (origin == .heartbeat) .heartbeat else .none);
    }

    fn answerPermission(self: *Session, request_id: i64, option: protocol.PermissionOption) !void {
        const host = self.host orelse return error.SessionStopped;
        {
            self.events_mutex.lockUncancelable(io_mod.getIo());
            defer self.events_mutex.unlock(io_mod.getIo());
            if (self.pendingIndex(request_id) == null) return error.RequestAlreadyAnswered;
        }
        const frame = try std.json.Stringify.valueAlloc(self.daemon.alloc, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{ .outcome = .{ .outcome = "selected", .optionId = @tagName(option) } },
        }, .{});
        defer self.daemon.alloc.free(frame);
        try host.dispatchFrame(frame);
        // A rejected reply must not consume the visible request before its
        // owner accepted it. Child retirement may have removed it already.
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        if (self.pendingIndex(request_id)) |index| self.daemon.alloc.free(self.pending.orderedRemove(index).frame);
    }

    fn pendingIndex(self: *const Session, id: i64) ?usize {
        for (self.pending.items, 0..) |entry, index| if (entry.id == id) return index;
        return null;
    }

    fn clearPending(self: *Session) void {
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        for (self.pending.items) |entry| self.daemon.alloc.free(entry.frame);
        self.pending.clearRetainingCapacity();
        self.heartbeat_request = null;
    }

    pub fn pendingCount(self: *Session) usize {
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        return self.pending.items.len;
    }

    fn stop(self: *Session, arena: Allocator) ![]const u8 {
        var next_record = try self.record.clone(self.daemon.alloc);
        next_record.stopped = true;
        next_record.heartbeat.paused = true;
        next_record.live = false;
        next_record.running = false;
        try self.daemon.commit(self, &next_record, false);
        self.closeHost();
        return protocol.encode(arena, protocol.Ack{});
    }

    /// Renames through the session's own store, so `fx sessions` and every
    /// other viewer show the same title.
    fn rename(self: *Session, arena: Allocator, raw: []const u8) ![]const u8 {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0 or name.len > session_display_metadata.max_title_bytes) return error.InvalidName;
        const host = self.host orelse return error.SessionStopped;
        const active = if (host.state.active_session) |*session| session else return error.NoActiveSession;
        const v2 = active.v2 orelse return error.SessionPersistenceUnavailable;
        {
            active.session_write_mutex.lockUncancelable(io_mod.getIo());
            defer active.session_write_mutex.unlock(io_mod.getIo());
            try v2.rename(name);
        }
        var next_record = try self.record.clone(self.daemon.alloc);
        next_record.setName(self.daemon.alloc, name) catch |err| {
            next_record.deinit(self.daemon.alloc);
            return err;
        };
        try self.daemon.commit(self, &next_record, false);
        return protocol.encode(arena, protocol.Ack{});
    }

    fn heartbeat(self: *Session, arena: Allocator, request: protocol.HeartbeatRequest) ![]const u8 {
        const alloc = self.daemon.alloc;
        if (request.action == .status) return protocol.encode(arena, protocol.HeartbeatState{ .heartbeat = self.record.heartbeat });
        var next_record = try self.record.clone(alloc);
        var committed = false;
        defer if (!committed) next_record.deinit(alloc);
        const now = io_mod.milliTimestamp();
        switch (request.action) {
            .status => unreachable,
            .set => {
                const interval = request.interval_ms orelse return error.IntervalRequired;
                if (interval < 1000 or interval > max_heartbeat_interval_ms) return error.InvalidInterval;
                const text = request.prompt orelse return error.PromptRequired;
                if (text.len == 0 or text.len > max_heartbeat_prompt_bytes) return error.InvalidPrompt;
                next_record.setHeartbeat(alloc, .{
                    .prompt = try alloc.dupe(u8, text),
                    .interval_ms = interval,
                    .next_run_ms = now + @as(i64, @intCast(interval)),
                    .paused = false,
                });
            },
            .pause => next_record.heartbeat.paused = true,
            .@"resume" => {
                if (next_record.heartbeat.interval_ms == 0) return error.HeartbeatNotConfigured;
                next_record.heartbeat.paused = false;
                next_record.heartbeat.next_run_ms = now + @as(i64, @intCast(next_record.heartbeat.interval_ms));
            },
            .clear => next_record.setHeartbeat(alloc, .{}),
        }
        committed = true;
        try self.daemon.commit(self, &next_record, false);
        if (request.action != .@"resume") self.withdrawHeartbeat();
        return protocol.encode(arena, protocol.HeartbeatState{ .heartbeat = self.record.heartbeat });
    }

    /// Takes back a heartbeat prompt still waiting to steer the turn.
    fn withdrawHeartbeat(self: *Session) void {
        const host = self.host orelse return;
        self.events_mutex.lockUncancelable(io_mod.getIo());
        const request = self.heartbeat_request;
        self.events_mutex.unlock(io_mod.getIo());
        const id = request orelse return;
        if (host.withdrawSteeringRequest(id)) {
            self.events_mutex.lockUncancelable(io_mod.getIo());
            defer self.events_mutex.unlock(io_mod.getIo());
            if (self.heartbeat_request == id) self.heartbeat_request = null;
        }
    }

    fn tick(self: *Session, now: i64) void {
        const host = self.host orelse return;
        host.pumpChildApprovals() catch |err| {
            std.debug.print("proto-fx: child approval projection failed: {s}\n", .{@errorName(err)});
        };
        const beat = self.record.heartbeat;
        if (!beat.paused and beat.interval_ms > 0 and !self.record.stopped and now >= beat.next_run_ms) {
            // Coalesce to one admitted fire. Steering interrupts only a
            // streaming reply; tools, compaction and approvals wait safely.
            self.events_mutex.lockUncancelable(io_mod.getIo());
            const waiting = self.heartbeat_request != null;
            self.events_mutex.unlock(io_mod.getIo());
            if (!waiting) self.fireHeartbeat(now);
        }
        self.refreshRecord() catch |err| std.debug.print("proto-fx: session record refresh failed: {s}\n", .{@errorName(err)});
    }

    fn fireHeartbeat(self: *Session, now: i64) void {
        const alloc = self.daemon.alloc;
        const admitted = if (self.prompt(self.record.heartbeat.prompt, .heartbeat)) |_| true else |err| blk: {
            std.debug.print("proto-fx: heartbeat admission failed: {s}\n", .{@errorName(err)});
            break :blk false;
        };
        var next_record = self.record.clone(alloc) catch return;
        next_record.heartbeat.next_run_ms = now + @as(i64, @intCast(next_record.heartbeat.interval_ms));
        if (admitted) next_record.heartbeat.run_count += 1;
        self.daemon.commit(self, &next_record, false) catch |err| std.debug.print("proto-fx: heartbeat save failed: {s}\n", .{@errorName(err)});
    }

    /// The record as the live host shows it now. Caller owns the result.
    fn liveRecord(self: *Session) !Record {
        const alloc = self.daemon.alloc;
        var next_record = try self.record.clone(alloc);
        errdefer next_record.deinit(alloc);
        const host = self.host orelse {
            next_record.live = false;
            next_record.saved = false;
            next_record.running = false;
            return next_record;
        };
        next_record.live = true;
        next_record.running = host.busy();
        const active = if (host.state.active_session) |*session| session else return next_record;
        alloc.free(next_record.model);
        next_record.model = &.{};
        next_record.model = try alloc.dupe(u8, active.model);
        alloc.free(next_record.mode);
        next_record.mode = &.{};
        next_record.mode = try alloc.dupe(u8, active.mode);
        const v2 = active.v2 orelse return next_record;
        next_record.saved = v2.saved();
        if (next_record.saved) {
            // The store titles a session from its first prompt, and keeps a
            // name the user chose; the supervisor shows the same title.
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const info = try v2.info(arena_state.allocator());
            if (info.title) |title| try next_record.setName(alloc, title);
            if (info.updated_ms > next_record.updated_at_ms) next_record.updated_at_ms = info.updated_ms;
        }
        return next_record;
    }

    /// Brings the record up to date with the host. A change to a saved field
    /// is persisted before it is shown.
    fn refreshRecord(self: *Session) !void {
        const alloc = self.daemon.alloc;
        var next_record = try self.liveRecord();
        const persisted_change = next_record.reopens() != self.record.reopens() or !std.mem.eql(u8, next_record.name, self.record.name);
        if (persisted_change) return self.daemon.commit(self, &next_record, false);
        self.record_mutex.lockUncancelable(io_mod.getIo());
        defer self.record_mutex.unlock(io_mod.getIo());
        std.mem.swap(Record, &self.record, &next_record);
        next_record.deinit(alloc);
    }

    // -- views ---------------------------------------------------------------

    /// The summary the accept loop lists. Locks the record; strings borrow
    /// `arena`.
    pub fn summary(self: *Session, arena: Allocator) !protocol.SessionSummary {
        const pending = self.pendingCount();
        self.record_mutex.lockUncancelable(io_mod.getIo());
        defer self.record_mutex.unlock(io_mod.getIo());
        return summaryOf(arena, self.id, self.cwd, &self.record, pending);
    }

    fn summaryOf(arena: Allocator, id: []const u8, cwd: []const u8, record: *const Record, pending: usize) !protocol.SessionSummary {
        var heartbeat_copy = record.heartbeat;
        heartbeat_copy.prompt = try arena.dupe(u8, record.heartbeat.prompt);
        return .{
            .id = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, record.name),
            .cwd = try arena.dupe(u8, cwd),
            .model = try arena.dupe(u8, record.model),
            .mode = if (record.mode.len > 0) try arena.dupe(u8, record.mode) else "auto",
            .status = record.status(pending),
            .heartbeat = heartbeat_copy,
            .error_message = if (record.failure) |failure| try arena.dupe(u8, failure) else null,
            .updated_at_ms = record.updated_at_ms,
        };
    }

    /// Whether the browser lists this session: a live one once its first
    /// turn is on disk, another while the store still holds its conversation.
    pub fn listable(self: *Session, saved_ids: anytype) bool {
        self.record_mutex.lockUncancelable(io_mod.getIo());
        defer self.record_mutex.unlock(io_mod.getIo());
        if (self.record.live) return self.record.saved;
        return self.id.len > 0 and saved_ids.contains(self.id);
    }

    // Serialize completed history only when the host is idle. During a turn
    // this is the immutable pre-turn checkpoint; events supply its live tail.
    fn refreshHistory(self: *Session) !void {
        const host = self.host orelse return;
        if (host.busy() or !self.history_dirty) return;
        const active = if (host.state.active_session) |*session| session else return;
        var arena = std.heap.ArenaAllocator.init(self.daemon.alloc);
        defer arena.deinit();
        const history = try active.session_rt.snapshotHistory(arena.allocator());
        const owned = try std.json.Stringify.valueAlloc(self.daemon.alloc, history, .{});
        if (self.history_json) |old| self.daemon.alloc.free(old);
        self.history_json = owned;
        self.events_mutex.lockUncancelable(io_mod.getIo());
        self.history_sequence = self.sequence;
        self.events_mutex.unlock(io_mod.getIo());
        self.history_dirty = false;
    }

    fn snapshot(self: *Session, arena: Allocator, after: u64, include_history: bool) ![]const u8 {
        try self.refreshHistory();
        const pending_count = self.pendingCount();
        const session_summary = try summaryOf(arena, self.id, self.cwd, &self.record, pending_count);
        const checkpoint = if (include_history) self.history_sequence else after;
        const Frame = protocol.RawJson;
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        var events: std.ArrayList(protocol.Event(Frame)) = .empty;
        for (self.events.items) |event| {
            if (event.sequence <= checkpoint) continue;
            try events.append(arena, .{ .sequence = event.sequence, .frame = .{ .bytes = event.frame } });
        }
        const pending = try arena.alloc(Frame, self.pending.items.len);
        for (self.pending.items, pending) |entry, *out| out.* = .{ .bytes = entry.frame };
        return protocol.encode(arena, protocol.Snapshot(Frame, Frame){
            .incarnation = self.daemon.incarnation,
            .session_id = self.id,
            .session = session_summary,
            .history_sequence = if (include_history) self.history_sequence else null,
            .history = if (include_history) .{ .bytes = self.history_json orelse "[]" } else null,
            .sequence = self.sequence,
            .oldest_sequence = if (self.events.items.len > 0) self.events.items[0].sequence else self.sequence,
            .events = events.items,
            .pending = pending,
        });
    }

    fn children(self: *Session, arena: Allocator) ![]const u8 {
        const host = self.host orelse return error.SessionStopped;
        var rows: std.ArrayList(protocol.Child) = .empty;
        if (host.state.subagent_v2_children) |registry_children| {
            const store = child_state.Store{ .children = registry_children, .parent_id = self.id };
            const registry = try store.load(arena);
            for (registry.children) |*child| {
                try rows.append(arena, .{
                    .id = child.id,
                    .parent_id = self.id,
                    .name = child.agentName() orelse "subagent",
                    .status = childStatus(child, false),
                    .detail = if (child.active) |active| active.message else child.instructions(),
                });
            }
        }
        return protocol.encode(arena, protocol.Children{ .children = rows.items });
    }

    fn childStatus(child: *const child_state.Child, live_active: bool) []const u8 {
        if (live_active and child.phase == .idle) return "running";
        if (child.phase == .finished) if (child.last_outcome) |outcome| return @tagName(outcome);
        return @tagName(child.phase);
    }

    fn historyView(self: *Session, arena: Allocator, request: protocol.History) ![]const u8 {
        const host = self.host orelse return error.SessionStopped;
        const child_id = request.child_id orelse {
            try self.refreshHistory();
            return protocol.encode(arena, protocol.RootHistory(protocol.RawJson){ .history = .{ .bytes = self.history_json orelse "[]" } });
        };
        const registry_children = host.state.subagent_v2_children orelse return error.ChildNotFound;
        const store = child_state.Store{ .children = registry_children, .parent_id = self.id };
        const registry = try store.load(arena);
        for (registry.children) |*row| {
            if (!std.mem.eql(u8, row.id, child_id)) continue;
            const work_id = if (row.active) |active| active.id else row.last_work_id orelse "";
            const changed_work = !std.mem.eql(u8, request.work_id orelse "", work_id);
            const live = if (host.state.subagent_host) |child_host|
                try child_host.managed.snapshotPresentation(arena, child_id, work_id, request.after_live_sequence, request.include_history or changed_work)
            else
                null;
            const live_active = live != null or row.phase == .running or row.phase == .awaiting_approval;
            const tail: live_presentation.Snapshot = live orelse .{};
            const live_reset = request.include_history or changed_work or tail.reset or request.live_active != live_active;
            var turns: ?[]const types.HistoryTurn = null;
            if (live_reset) {
                // Current-work commits and compaction can race this read.
                // Work identity keeps them out of the immutable prior history
                // until settlement replaces the live tail.
                const saved: []types.HistoryTurn = host.state.sessions_v2.?.childHistory(arena, child_id) catch |err| switch (err) {
                    error.NotFound, error.FileNotFound => if (live_active) &.{} else return err,
                    else => return err,
                };
                var kept: std.ArrayList(types.HistoryTurn) = .empty;
                for (saved) |turn| {
                    if (live_active and historyBelongsToWork(turn, work_id)) continue;
                    try kept.append(arena, turn);
                }
                turns = kept.items;
            }
            return protocol.encode(arena, protocol.ChildHistory(protocol.RawJson){
                .child_id = child_id,
                .work_id = work_id,
                .live_active = live_active,
                .live_sequence = tail.sequence,
                .oldest_live_sequence = tail.oldest_sequence,
                .live_reset = live_reset,
                .name = row.agentName() orelse "subagent",
                .status = childStatus(row, live_active),
                .last_outcome = if (row.last_outcome) |outcome| @tagName(outcome) else null,
                .last_failure = if (row.last_failure) |*failure| failure.view() else null,
                .active_prompt = if (live_active) if (row.active) |active| active.message else null else null,
                .history = turns,
                .live_events = .{ .bytes = tail.events_json },
            });
        }
        return error.ChildNotFound;
    }

    // -- the host's writer ---------------------------------------------------

    /// Receives every frame the host writes, from any host thread. Answers
    /// the supervisor waits for are routed to it; requests and notifications
    /// join the replay log, and requests stay pending until answered.
    fn publish(raw: ?*anyopaque, frame: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const alloc = self.daemon.alloc;
        const trimmed = std.mem.trim(u8, frame, "\r\n");
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const Head = struct {
            id: ?std.json.Value = null,
            method: ?[]const u8 = null,
            params: ?struct { request_id: ?i64 = null } = null,
            result: ?std.json.Value = null,
            @"error": ?struct { message: []const u8 = "The session command failed" } = null,
        };
        const parsed: ?Head = std.json.parseFromSliceLeaky(Head, arena, trimmed, .{ .ignore_unknown_fields = true }) catch null;

        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        // A frame this cannot read is still a frame the viewer may.
        const head = parsed orelse return self.appendEvent(boundedFrame(trimmed));
        const id: ?i64 = if (head.id) |value| if (value == .integer) value.integer else null else null;
        if (head.method == null) {
            const response_id = id orelse return;
            if (self.capture) |*capture| if (capture.id == response_id) {
                if (capture.frame == null) capture.frame = try alloc.dupe(u8, trimmed);
                return;
            };
            if (self.heartbeat_request == response_id) self.heartbeat_request = null;
            for (self.commands.items, 0..) |command, index| {
                if (command.id != response_id) continue;
                defer alloc.free(command.name);
                _ = self.commands.orderedRemove(index);
                const result = try protocol.encode(arena, .{
                    .method = protocol.command_result_method,
                    .params = protocol.CommandResult(std.json.Value){
                        .name = command.name,
                        .ok = head.@"error" == null,
                        .result = head.result,
                        .@"error" = if (head.@"error") |failure| failure.message else null,
                    },
                });
                return self.appendEvent(result);
            }
            return;
        }
        if (std.mem.eql(u8, head.method.?, protocol.permission_retired_method)) {
            if (head.params) |params| if (params.request_id) |retired| if (self.pendingIndex(retired)) |index| {
                alloc.free(self.pending.orderedRemove(index).frame);
            };
        }
        // Requests survive the replay window: a detached approval waits.
        if (id) |request_id| if (self.pending.items.len < max_pending) {
            const copy = try alloc.dupe(u8, trimmed);
            errdefer alloc.free(copy);
            try self.pending.append(alloc, .{ .id = request_id, .frame = copy });
        };
        try self.appendEvent(boundedFrame(trimmed));
    }

    fn boundedFrame(frame: []const u8) []const u8 {
        if (frame.len <= event_bytes_limit) return frame;
        return "{\"method\":\"" ++ protocol.replay_gap_method ++ "\",\"params\":{\"reason\":\"large event is available in saved history\"}}";
    }

    /// Appends one frame to the bounded replay log. Holds `events_mutex`.
    fn appendEvent(self: *Session, frame: []const u8) !void {
        const alloc = self.daemon.alloc;
        const copy = try alloc.dupe(u8, frame);
        errdefer alloc.free(copy);
        while (self.events.items.len > 0 and self.event_bytes + copy.len > event_bytes_limit) {
            const oldest = self.events.orderedRemove(0);
            self.event_bytes -= oldest.frame.len;
            alloc.free(oldest.frame);
        }
        try self.events.ensureUnusedCapacity(alloc, 1);
        self.sequence += 1;
        self.events.appendAssumeCapacity(.{ .sequence = self.sequence, .frame = copy });
        self.event_bytes += copy.len;
    }
};

pub fn answerFailure(job: *Job, message: []const u8) void {
    const stream = job.reply orelse return;
    const bytes = protocol.encode(job.arena.allocator(), protocol.Failure{ .@"error" = message }) catch return;
    client.writeFrame(stream, bytes) catch {};
}

fn historyBelongsToWork(turn: types.HistoryTurn, work_id: []const u8) bool {
    const saved_work = switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    } orelse return false;
    return std.mem.eql(u8, saved_work, work_id);
}

//! Same-executable detached session owner. Existing ACP hosts run the native fx engine.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const acp = @import("../../acp/server.zig");
const acp_config = @import("../cli/acp_runner.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");
const session_adapter = @import("../session/session_adapter.zig");
const child_state = @import("../subagent/child_state.zig");
const live_presentation = @import("../subagent/live_presentation.zig");
const types = @import("../shared/types.zig");
const client = @import("client.zig");
const Allocator = std.mem.Allocator;
extern "c" fn setsid() c_int;

const max_sessions = 128;
const event_bytes_limit = 2 * 1024 * 1024;
const Event = struct { sequence: u64, frame: []u8 };
const Heartbeat = struct {
    prompt: []const u8 = "",
    interval_ms: u64 = 0,
    next_run_ms: i64 = 0,
    paused: bool = true,
    run_count: u64 = 0,
};

const Session = struct {
    daemon: *Daemon,
    id: []u8 = &.{},
    name: []u8,
    cwd: []u8,
    host: ?*acp.PersistentHost = null,
    stopped: bool = false,
    updated_at_ms: i64 = 0,
    failure: ?[]u8 = null,
    heartbeat: Heartbeat = .{},
    next_request: i64 = 10,
    events_mutex: std.Io.Mutex = .init,
    events: std.ArrayList(Event) = .empty,
    pending: std.ArrayList([]u8) = .empty,
    event_bytes: usize = 0,
    sequence: u64 = 0,
    history_json: ?[]u8 = null,
    history_sequence: u64 = 0,
    history_dirty: bool = true,
    heartbeat_request: ?i64 = null,

    fn publish(raw: ?*anyopaque, frame: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const alloc = self.daemon.alloc;
        const bounded = if (frame.len > event_bytes_limit)
            "{\"method\":\"proto/replay_gap\",\"params\":{\"reason\":\"large event is available in saved history\"}}"
        else
            std.mem.trim(u8, frame, "\r\n");
        const copy = try alloc.dupe(u8, bounded);
        errdefer alloc.free(copy);
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        self.sequence += 1;
        // Keep requests independently of the replay window: detached approvals survive.
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, copy, .{}) catch null;
        defer if (parsed) |*value| value.deinit();
        if (parsed) |value| {
            if (stringField(value.value, "method")) |method| {
                if (std.mem.eql(u8, method, "proto/permission_retired")) {
                    if (objectField(value.value, "params")) |params| if (objectField(params, "request_id")) |id| {
                        var index: usize = 0;
                        while (index < self.pending.items.len) {
                            const old = std.json.parseFromSlice(std.json.Value, alloc, self.pending.items[index], .{}) catch {
                                index += 1;
                                continue;
                            };
                            defer old.deinit();
                            const old_id = objectField(old.value, "id");
                            if (id == .integer and old_id != null and old_id.? == .integer and old_id.?.integer == id.integer) {
                                alloc.free(self.pending.orderedRemove(index));
                                break;
                            }
                            index += 1;
                        }
                    };
                }
            }
            if (value.value == .object and !value.value.object.contains("method")) {
                if (value.value.object.get("id")) |id| {
                    if (id == .integer and self.heartbeat_request == id.integer) self.heartbeat_request = null;
                }
            }
            if (value.value == .object and value.value.object.contains("method") and value.value.object.contains("id")) {
                if (self.pending.items.len < 64) {
                    const pending = try alloc.dupe(u8, copy);
                    errdefer alloc.free(pending);
                    try self.pending.append(alloc, pending);
                }
            }
        }
        while (self.events.items.len > 0 and self.event_bytes + copy.len > event_bytes_limit) {
            const oldest = self.events.orderedRemove(0);
            self.event_bytes -= oldest.frame.len;
            alloc.free(oldest.frame);
        }
        try self.events.append(alloc, .{ .sequence = self.sequence, .frame = copy });
        self.event_bytes += copy.len;
    }

    fn dispatch(self: *Session, method: []const u8, params: anytype) !i64 {
        const host = self.host orelse return error.SessionStopped;
        const id = self.next_request;
        self.next_request += 1;
        var out: std.Io.Writer.Allocating = .init(self.daemon.alloc);
        defer out.deinit();
        try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{}, &out.writer);
        try host.dispatchFrame(out.written());
        return id;
    }

    fn open(self: *Session, resume_id: ?[]const u8) !void {
        var cfg = self.daemon.cfg;
        cfg.home_override = self.daemon.home;
        cfg.workspace_root_override = self.cwd;
        const host = try acp.PersistentHost.init(self.daemon.alloc, cfg, self, publish);
        errdefer host.deinit();
        host.state.native_presentation = true;
        self.host = host;
        errdefer self.host = null;
        _ = try self.dispatch("initialize", .{
            .protocolVersion = 1,
            .clientCapabilities = .{},
            .clientInfo = .{ .name = "proto-fx", .version = "phase1" },
        });
        if (!host.state.initialized) {
            self.logOpenFailure();
            return error.SessionInitializationFailed;
        }
        if (resume_id) |id| {
            _ = try self.dispatch("session/load", .{ .sessionId = id, .cwd = self.cwd, .mcpServers = [_]struct {}{} });
        } else {
            _ = try self.dispatch("session/new", .{ .cwd = self.cwd, .mcpServers = [_]struct {}{} });
        }
        const active = host.state.active_session orelse {
            self.logOpenFailure();
            return error.SessionOpenFailed;
        };
        if (active.v2) |saved| try saved.retainForBackground();
        if (self.id.len == 0) self.id = try self.daemon.alloc.dupe(u8, active.session_id);
        self.stopped = false;
        if (self.failure) |failure| self.daemon.alloc.free(failure);
        self.failure = null;
        self.history_dirty = true;
        try self.refreshHistory();
    }

    fn logOpenFailure(self: *Session) void {
        for (self.events.items) |event| {
            const parsed = std.json.parseFromSlice(std.json.Value, self.daemon.alloc, event.frame, .{}) catch continue;
            defer parsed.deinit();
            if (objectField(parsed.value, "error")) |failure| {
                std.debug.print("proto-fx: session startup: {s}\n", .{stringField(failure, "message") orelse "unknown ACP error"});
            }
        }
    }

    fn prompt(self: *Session, text: []const u8) !i64 {
        if (text.len == 0 or text.len > 1024 * 1024) return error.InvalidPrompt;
        try self.refreshHistory();
        if (std.mem.eql(u8, self.name, "session")) {
            const line = std.mem.trim(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], " \t\r");
            var end = @min(line.len, 96);
            while (end > 0 and end < line.len and line[end] & 0xc0 == 0x80) end -= 1;
            if (end > 0) {
                const name = try self.daemon.alloc.dupe(u8, line[0..end]);
                self.daemon.alloc.free(self.name);
                self.name = name;
                try self.daemon.persist();
            }
        }
        self.updated_at_ms = io_mod.milliTimestamp();
        self.history_dirty = true;
        const blocks = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }};
        return self.dispatch("session/prompt", .{ .sessionId = self.id, .prompt = &blocks, ._meta = .{ .fx = .{ .steer = true } } });
    }

    // Serialize completed history only when the worker has been joined. During a
    // turn this is the immutable pre-turn checkpoint; events supply its live tail.
    fn refreshHistory(self: *Session) !void {
        const host = self.host orelse return;
        if (host.busy() or !self.history_dirty) return;
        var arena = std.heap.ArenaAllocator.init(self.daemon.alloc);
        defer arena.deinit();
        const history = try host.state.active_session.?.session_rt.snapshotHistory(arena.allocator());
        var out: std.Io.Writer.Allocating = .init(self.daemon.alloc);
        defer out.deinit();
        try std.json.Stringify.value(history, .{}, &out.writer);
        const owned = try self.daemon.alloc.dupe(u8, out.written());
        if (self.history_json) |old| self.daemon.alloc.free(old);
        self.history_json = owned;
        self.history_sequence = self.sequence;
        self.history_dirty = false;
    }

    fn clearPending(self: *Session) void {
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        for (self.pending.items) |frame| self.daemon.alloc.free(frame);
        self.pending.clearRetainingCapacity();
        self.heartbeat_request = null;
    }

    fn withdrawHeartbeat(self: *Session) void {
        const host = self.host orelse return;
        self.events_mutex.lockUncancelable(io_mod.getIo());
        const request = self.heartbeat_request;
        self.events_mutex.unlock(io_mod.getIo());
        const id = request orelse return;
        if (host.withdrawSteeringRequest(id)) {
            self.events_mutex.lockUncancelable(io_mod.getIo());
            if (self.heartbeat_request == id) self.heartbeat_request = null;
            self.events_mutex.unlock(io_mod.getIo());
        }
    }

    fn nativeCommand(self: *Session, method: []const u8, params: anytype, w: *std.Io.Writer) !void {
        const request = try self.dispatch(method, params);
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        for (self.events.items) |event| {
            const parsed = std.json.parseFromSlice(std.json.Value, self.daemon.alloc, event.frame, .{}) catch continue;
            defer parsed.deinit();
            const id = objectField(parsed.value, "id") orelse continue;
            if (id != .integer or id.integer != request) continue;
            if (objectField(parsed.value, "error")) |failure| {
                return std.json.Stringify.value(.{ .ok = false, .@"error" = stringField(failure, "message") orelse "NativeCommandFailed" }, .{}, w);
            }
            if (objectField(parsed.value, "result") != null) return w.writeAll("{\"ok\":true}");
        }
        return error.NativeCommandIncomplete;
    }

    fn status(self: *Session) []const u8 {
        if (self.failure != null) return "error";
        if (self.stopped) return "stopped";
        if (self.host) |host| {
            const busy = host.busy();
            self.events_mutex.lockUncancelable(io_mod.getIo());
            defer self.events_mutex.unlock(io_mod.getIo());
            if (self.pending.items.len > 0) return "awaiting_approval";
            return if (busy) "running" else "idle";
        }
        return "saved";
    }

    fn summary(self: *Session, w: *std.Io.Writer) !void {
        const model = if (self.host) |host| if (host.state.active_session) |active| active.model else "" else "";
        try std.json.Stringify.value(.{
            .id = self.id,
            .name = self.name,
            .cwd = self.cwd,
            .model = model,
            .mode = if (self.host) |host| if (host.state.active_session) |active| active.mode else "auto" else "auto",
            .status = self.status(),
            .heartbeat = self.heartbeat,
            .error_message = self.failure,
            .updated_at_ms = self.updated_at_ms,
        }, .{}, w);
    }

    fn snapshot(self: *Session, w: *std.Io.Writer, after: u64, include_history: bool) !void {
        try self.refreshHistory();
        try w.writeAll("{\"ok\":true,\"incarnation\":");
        try jsonrpc.writeJsonStr(self.daemon.incarnation, w);
        try w.writeAll(",\"native_presentation\":true,\"session_id\":");
        try jsonrpc.writeJsonStr(self.id, w);
        try w.writeAll(",\"session\":");
        try self.summary(w);
        if (include_history) {
            try w.print(",\"history_sequence\":{d},\"history\":", .{self.history_sequence});
            try w.writeAll(self.history_json orelse "[]");
        }
        const checkpoint = if (include_history) self.history_sequence else after;
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        const oldest = if (self.events.items.len > 0) self.events.items[0].sequence else self.sequence;
        try w.print(",\"sequence\":{d},\"oldest_sequence\":{d},\"events\":[", .{ self.sequence, oldest });
        var comma = false;
        for (self.events.items) |event| {
            if (event.sequence <= checkpoint) continue;
            if (comma) try w.writeByte(',');
            comma = true;
            try w.print("{{\"sequence\":{d},\"frame\":", .{event.sequence});
            try w.writeAll(event.frame);
            try w.writeByte('}');
        }
        try w.writeAll("],\"pending\":[");
        for (self.pending.items, 0..) |frame, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(frame);
        }
        try w.writeAll("]}");
    }

    fn answer(self: *Session, frame: std.json.Value) !void {
        if (frame != .object) return error.InvalidFrame;
        const id = frame.object.get("id") orelse return error.InvalidFrame;
        if (id != .integer or frame.object.contains("method") or frame.object.contains("result") == frame.object.contains("error")) return error.InvalidFrame;
        var out: std.Io.Writer.Allocating = .init(self.daemon.alloc);
        defer out.deinit();
        try std.json.Stringify.value(frame, .{}, &out.writer);
        const host = self.host orelse return error.SessionStopped;
        self.events_mutex.lockUncancelable(io_mod.getIo());
        var found: ?usize = null;
        for (self.pending.items, 0..) |pending, i| {
            const parsed = std.json.parseFromSlice(std.json.Value, self.daemon.alloc, pending, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value.object.get("id")) |pending_id| {
                if (pending_id == .integer and pending_id.integer == id.integer) {
                    found = i;
                    break;
                }
            }
        }
        self.events_mutex.unlock(io_mod.getIo());
        if (found == null) return error.RequestAlreadyAnswered;
        try host.dispatchFrame(out.written());
        // An invalid/stale reply must not consume the visible request before
        // its authoritative owner has accepted it. Child retirement may have
        // already removed this row during dispatch.
        self.events_mutex.lockUncancelable(io_mod.getIo());
        defer self.events_mutex.unlock(io_mod.getIo());
        for (self.pending.items, 0..) |pending, index| {
            const parsed = std.json.parseFromSlice(std.json.Value, self.daemon.alloc, pending, .{}) catch continue;
            defer parsed.deinit();
            const pending_id = objectField(parsed.value, "id") orelse continue;
            if (pending_id == .integer and pending_id.integer == id.integer) {
                self.daemon.alloc.free(self.pending.orderedRemove(index));
                break;
            }
        }
    }

    fn deinit(self: *Session) void {
        const alloc = self.daemon.alloc;
        if (self.host) |host| host.deinit();
        for (self.events.items) |event| alloc.free(event.frame);
        self.events.deinit(alloc);
        for (self.pending.items) |frame| alloc.free(frame);
        self.pending.deinit(alloc);
        if (self.history_json) |history| alloc.free(history);
        if (self.id.len > 0) alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.cwd);
        if (self.failure) |failure| alloc.free(failure);
        if (self.heartbeat.prompt.len > 0) alloc.free(self.heartbeat.prompt);
        alloc.destroy(self);
    }
};

const Daemon = struct {
    alloc: Allocator,
    cfg: acp_config.Config,
    home: []const u8,
    state_path: []const u8,
    incarnation: []const u8,
    sessions: std.ArrayList(*Session) = .empty,
    stopping: bool = false,
    last_attached_id: ?[]u8 = null,

    fn markAttached(self: *Daemon, session: *Session) !void {
        if (self.last_attached_id) |old| if (std.mem.eql(u8, old, session.id)) return;
        const id = try self.alloc.dupe(u8, session.id);
        if (self.last_attached_id) |old| self.alloc.free(old);
        self.last_attached_id = id;
    }

    fn find(self: *Daemon, id: []const u8) ?*Session {
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, id)) return session;
        return null;
    }

    fn allocateSession(self: *Daemon, cwd: []const u8, name: []const u8) !*Session {
        if (self.sessions.items.len >= max_sessions) {
            // Saved-only discovery rows must never prevent a new live session.
            for (self.sessions.items, 0..) |entry, index| {
                if (entry.host == null and !entry.stopped and entry.failure == null) {
                    _ = self.sessions.orderedRemove(index);
                    entry.deinit();
                    break;
                }
            } else return error.SessionLimit;
        }
        const root = try self.alloc.dupe(u8, cwd);
        errdefer self.alloc.free(root);
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const session = try self.alloc.create(Session);
        session.* = .{ .daemon = self, .cwd = root, .name = owned_name, .updated_at_ms = io_mod.milliTimestamp() };
        return session;
    }

    fn create(self: *Daemon, cwd: []const u8, name: []const u8, resume_id: ?[]const u8) !*Session {
        if (resume_id) |id| if (self.find(id)) |existing| {
            if (existing.host == null) try existing.open(id);
            return existing;
        };
        const root = try io_mod.realpathAlloc(self.alloc, cwd);
        defer self.alloc.free(root);
        const session = try self.allocateSession(root, name);
        errdefer session.deinit();
        try self.sessions.ensureUnusedCapacity(self.alloc, 1);
        try session.open(resume_id);
        self.sessions.appendAssumeCapacity(session);
        return session;
    }

    fn discoverSaved(self: *Daemon) !void {
        var store = try session_adapter.Store.open(self.alloc, self.home);
        defer store.deinit(self.alloc);
        const cancel = std.atomic.Value(bool).init(false);
        var summaries = try session_adapter.listSummaries(&store, self.alloc, null, &cancel);
        defer {
            for (summaries.items) |*summary| summary.deinit(self.alloc);
            summaries.deinit(self.alloc);
        }
        for (summaries.items) |summary| {
            if (self.sessions.items.len >= max_sessions) break;
            if (self.find(summary.id) != null) continue;
            const cwd = summary.workspace_root orelse summary.origin_workspace_root orelse continue;
            const session = try self.allocateSession(cwd, summary.title orelse "session");
            errdefer session.deinit();
            session.id = try self.alloc.dupe(u8, summary.id);
            try self.sessions.append(self.alloc, session);
        }
    }

    fn persist(self: *Daemon) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"version\":1,\"sessions\":[");
        for (self.sessions.items, 0..) |session, index| {
            if (index != 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(.{ .id = session.id, .name = session.name, .cwd = session.cwd, .stopped = session.stopped, .heartbeat = session.heartbeat, .updated_at_ms = session.updated_at_ms, .owned = session.host != null or session.stopped or session.failure != null }, .{}, &out.writer);
        }
        try out.writer.writeAll("],\"last_attached_id\":");
        try std.json.Stringify.value(self.last_attached_id, .{}, &out.writer);
        try out.writer.writeByte('}');
        try io_mod.writeFileAtomic(self.alloc, self.state_path, out.written());
    }

    fn restore(self: *Daemon) !void {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), self.state_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(self.alloc, &file, 16 * 1024 * 1024);
        defer self.alloc.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, bytes, .{});
        defer parsed.deinit();
        const rows = objectField(parsed.value, "sessions") orelse return error.InvalidDaemonState;
        if (rows != .array) return error.InvalidDaemonState;
        for (rows.array.items) |row| {
            const id = stringField(row, "id") orelse continue;
            const cwd = stringField(row, "cwd") orelse continue;
            const name = stringField(row, "name") orelse "session";
            const session = try self.allocateSession(cwd, name);
            errdefer session.deinit();
            session.id = try self.alloc.dupe(u8, id);
            session.updated_at_ms = @intCast(uintField(row, "updated_at_ms") orelse 0);
            if (objectField(row, "heartbeat")) |heartbeat| {
                const prompt = stringField(heartbeat, "prompt") orelse "";
                session.heartbeat = .{
                    .prompt = if (prompt.len > 0) try self.alloc.dupe(u8, prompt) else "",
                    .interval_ms = uintField(heartbeat, "interval_ms") orelse 0,
                    .next_run_ms = @intCast(uintField(heartbeat, "next_run_ms") orelse 0),
                    .paused = boolField(heartbeat, "paused") orelse true,
                    .run_count = uintField(heartbeat, "run_count") orelse 0,
                };
            }
            if (boolField(row, "stopped") orelse false) {
                session.stopped = true;
            } else if (boolField(row, "owned") orelse true) {
                session.open(id) catch |err| {
                    session.failure = try self.alloc.dupe(u8, @errorName(err));
                    std.debug.print("proto-fx: cannot restore session {s}: {s}\n", .{ id, @errorName(err) });
                };
            }
            try self.sessions.append(self.alloc, session);
        }
        if (stringField(parsed.value, "last_attached_id")) |id| {
            if (self.find(id)) |session| try self.markAttached(session);
        }
    }

    fn tick(self: *Daemon) void {
        const now = io_mod.milliTimestamp();
        var changed = false;
        for (self.sessions.items) |session| {
            if (session.host) |host| host.pumpChildApprovals() catch |err| {
                std.debug.print("proto-fx: child approval projection failed: {s}\n", .{@errorName(err)});
            };
            const heartbeat = &session.heartbeat;
            if (heartbeat.paused or heartbeat.interval_ms == 0 or session.stopped or session.host == null) continue;
            if (now < heartbeat.next_run_ms) continue;
            // Coalesce to one admitted fire. Existing steering interrupts only a
            // streaming reply; tools, compaction and approvals wait safely.
            session.events_mutex.lockUncancelable(io_mod.getIo());
            const waiting = session.heartbeat_request != null;
            if (!waiting) session.heartbeat_request = session.next_request;
            session.events_mutex.unlock(io_mod.getIo());
            if (waiting) continue;
            _ = session.prompt(heartbeat.prompt) catch |err| {
                session.events_mutex.lockUncancelable(io_mod.getIo());
                session.heartbeat_request = null;
                session.events_mutex.unlock(io_mod.getIo());
                std.debug.print("proto-fx: heartbeat admission failed: {s}\n", .{@errorName(err)});
                heartbeat.next_run_ms = now + @as(i64, @intCast(heartbeat.interval_ms));
                changed = true;
                continue;
            };
            heartbeat.next_run_ms = now + @as(i64, @intCast(heartbeat.interval_ms));
            heartbeat.run_count += 1;
            changed = true;
        }
        if (changed) self.persist() catch |err| std.debug.print("proto-fx: heartbeat save failed: {s}\n", .{@errorName(err)});
    }

    fn handle(self: *Daemon, value: std.json.Value, w: *std.Io.Writer, arena: Allocator) !void {
        const command = stringField(value, "command") orelse return error.CommandRequired;
        if (std.mem.eql(u8, command, "ping")) return w.writeAll("{\"ok\":true,\"version\":1}");
        if (std.mem.eql(u8, command, "shutdown")) {
            self.stopping = true;
            return w.writeAll("{\"ok\":true}");
        }
        if (std.mem.eql(u8, command, "list")) {
            try self.discoverSaved();
            try w.writeAll("{\"ok\":true,\"sessions\":[");
            for (self.sessions.items, 0..) |session, index| {
                if (index != 0) try w.writeByte(',');
                try session.summary(w);
            }
            try w.writeAll("],\"last_attached_id\":");
            try std.json.Stringify.value(self.last_attached_id, .{}, w);
            return w.writeByte('}');
        }
        if (std.mem.eql(u8, command, "create")) {
            const session = try self.create(stringField(value, "cwd") orelse return error.CwdRequired, stringField(value, "name") orelse "session", stringField(value, "resume"));
            try self.markAttached(session);
            try self.persist();
            return session.snapshot(w, 0, true);
        }
        const id = stringField(value, "session_id") orelse return error.SessionIdRequired;
        const session = self.find(id) orelse return error.SessionNotFound;
        if (std.mem.eql(u8, command, "attach")) {
            const after = uintField(value, "after_sequence") orelse 0;
            const include_history = boolField(value, "include_history") orelse (after == 0);
            // Background frontend polls observe a stop; only a deliberate
            // attachment reopens the stopped/saved session.
            if (session.host == null and include_history) {
                try session.open(session.id);
                try self.persist();
            }
            if (include_history) {
                try self.markAttached(session);
                try self.persist();
            }
            return session.snapshot(w, after, include_history);
        }
        if (std.mem.eql(u8, command, "mode")) {
            return session.nativeCommand("session/set_mode", .{ .sessionId = id, .modeId = stringField(value, "mode") orelse return error.ModeRequired }, w);
        }
        if (std.mem.eql(u8, command, "model")) {
            if ((session.host orelse return error.SessionStopped).busy()) return error.SessionBusy;
            return session.nativeCommand("session/set_config_option", .{ .sessionId = id, .configId = "model", .value = stringField(value, "model") orelse return error.ModelRequired }, w);
        }
        if (std.mem.eql(u8, command, "rename")) {
            const name = std.mem.trim(u8, stringField(value, "name") orelse return error.NameRequired, " \t\r\n");
            if (name.len == 0 or name.len > 256) return error.InvalidName;
            const owned = try self.alloc.dupe(u8, name);
            self.alloc.free(session.name);
            session.name = owned;
            try self.persist();
            return w.writeAll("{\"ok\":true}");
        }
        if (std.mem.eql(u8, command, "kernel")) {
            const info = try (session.host orelse return error.SessionStopped).kernelControl(arena, stringField(value, "action") orelse "status");
            return std.json.Stringify.value(.{ .ok = true, .kernel = info }, .{}, w);
        }
        if (std.mem.eql(u8, command, "prompt")) {
            const request_id = try session.prompt(stringField(value, "text") orelse return error.PromptRequired);
            return std.json.Stringify.value(.{ .ok = true, .admitted = true, .request_id = request_id }, .{}, w);
        }
        if (std.mem.eql(u8, command, "cancel")) {
            _ = try session.dispatch("session/cancel", .{ .sessionId = id });
            session.clearPending();
            session.host.?.refreshChildApprovals();
            return w.writeAll("{\"ok\":true}");
        }
        if (std.mem.eql(u8, command, "rpc")) {
            try session.answer(objectField(value, "frame") orelse return error.FrameRequired);
            return w.writeAll("{\"ok\":true}");
        }
        if (std.mem.eql(u8, command, "stop")) {
            session.heartbeat.paused = true;
            session.stopped = true;
            try self.persist();
            if (session.host) |host| host.deinit();
            session.host = null;
            session.clearPending();
            return w.writeAll("{\"ok\":true}");
        }
        if (std.mem.eql(u8, command, "heartbeat")) {
            const action = stringField(value, "action") orelse "set";
            if (std.mem.eql(u8, action, "status")) return std.json.Stringify.value(.{ .ok = true, .heartbeat = session.heartbeat }, .{}, w);
            if (std.mem.eql(u8, action, "set")) {
                const interval = uintField(value, "interval_ms") orelse return error.IntervalRequired;
                if (interval < 1000 or interval > 365 * 24 * 60 * 60 * 1000) return error.InvalidInterval;
                const prompt = stringField(value, "prompt") orelse return error.PromptRequired;
                if (prompt.len == 0 or prompt.len > 65536) return error.InvalidPrompt;
                const owned = try self.alloc.dupe(u8, prompt);
                session.withdrawHeartbeat();
                if (session.heartbeat.prompt.len > 0) self.alloc.free(session.heartbeat.prompt);
                session.heartbeat = .{ .prompt = owned, .interval_ms = interval, .next_run_ms = io_mod.milliTimestamp() + @as(i64, @intCast(interval)), .paused = false };
            } else if (std.mem.eql(u8, action, "pause")) {
                session.heartbeat.paused = true;
                session.withdrawHeartbeat();
            } else if (std.mem.eql(u8, action, "resume")) {
                if (session.heartbeat.interval_ms == 0) return error.HeartbeatNotConfigured;
                session.heartbeat.paused = false;
                session.heartbeat.next_run_ms = io_mod.milliTimestamp() + @as(i64, @intCast(session.heartbeat.interval_ms));
            } else if (std.mem.eql(u8, action, "clear")) {
                session.withdrawHeartbeat();
                if (session.heartbeat.prompt.len > 0) self.alloc.free(session.heartbeat.prompt);
                session.heartbeat = .{};
            } else return error.InvalidHeartbeatAction;
            try self.persist();
            return std.json.Stringify.value(.{ .ok = true, .heartbeat = session.heartbeat }, .{}, w);
        }
        const host = session.host orelse return error.SessionStopped;
        if (std.mem.eql(u8, command, "children")) {
            try w.writeAll("{\"ok\":true,\"children\":[");
            if (host.state.subagent_v2_children) |children| {
                const store = child_state.Store{ .children = children, .parent_id = session.id };
                var registry = try store.load(arena);
                defer registry.deinit(arena);
                for (registry.children, 0..) |child, index| {
                    if (index != 0) try w.writeByte(',');
                    try std.json.Stringify.value(.{
                        .id = child.id,
                        .parent_id = id,
                        .name = child.agentName() orelse "subagent",
                        .status = if (child.phase == .finished) if (child.last_outcome) |outcome| @tagName(outcome) else @tagName(child.phase) else @tagName(child.phase),
                        .detail = if (child.active) |active| active.message else child.instructions(),
                        .depth = @as(u8, 1),
                    }, .{}, w);
                }
            }
            return w.writeAll("]}");
        }
        if (std.mem.eql(u8, command, "history")) {
            if (stringField(value, "child_id")) |child_id| {
                const children = host.state.subagent_v2_children orelse return error.ChildNotFound;
                const store = child_state.Store{ .children = children, .parent_id = session.id };
                var registry = try store.load(arena);
                defer registry.deinit(arena);
                for (registry.children) |row| {
                    if (!std.mem.eql(u8, row.id, child_id)) continue;
                    const work_id = if (row.active) |active| active.id else row.last_work_id orelse "";
                    const after = uintField(value, "after_live_sequence") orelse 0;
                    const include_history = boolField(value, "include_history") orelse true;
                    const changed_work = !std.mem.eql(u8, stringField(value, "work_id") orelse "", work_id);
                    const live = if (host.state.subagent_host) |child_host|
                        try child_host.managed.snapshotPresentation(arena, child_id, work_id, after, include_history or changed_work)
                    else
                        null;
                    const live_active = live != null or row.phase == .running or row.phase == .awaiting_approval;
                    const snapshot: live_presentation.Snapshot = live orelse .{};
                    const live_reset = include_history or changed_work or snapshot.reset or
                        (boolField(value, "live_active") orelse false) != live_active;
                    var metadata: std.Io.Writer.Allocating = .init(arena);
                    defer metadata.deinit();
                    try std.json.Stringify.value(.{
                        .ok = true,
                        .child_id = child_id,
                        .work_id = work_id,
                        .live_active = live_active,
                        .live_sequence = snapshot.sequence,
                        .oldest_live_sequence = snapshot.oldest_sequence,
                        .live_reset = live_reset,
                        .name = row.agentName() orelse "subagent",
                        .status = if (live_active and row.phase == .idle) "running" else if (row.phase == .finished) if (row.last_outcome) |outcome| @tagName(outcome) else @tagName(row.phase) else @tagName(row.phase),
                        .last_outcome = if (row.last_outcome) |outcome| @tagName(outcome) else null,
                        .last_failure = if (row.last_failure) |failure| failure.view() else null,
                        .active_prompt = if (live_active) if (row.active) |active| active.message else null else null,
                    }, .{}, &metadata.writer);
                    const encoded = metadata.written();
                    try w.writeAll(encoded[0 .. encoded.len - 1]);
                    if (live_reset) {
                        // Current-work commits/compaction can race this read.
                        // Work identity excludes them from the immutable prior
                        // history view until settlement replaces the live tail.
                        const history: []types.HistoryTurn = host.state.sessions_v2.?.childHistory(arena, child_id) catch |err| switch (err) {
                            error.NotFound, error.FileNotFound => if (live_active) &.{} else return err,
                            else => return err,
                        };
                        try w.writeAll(",\"history\":[");
                        var comma = false;
                        for (history) |turn| {
                            if (live_active and historyBelongsToWork(turn, work_id)) continue;
                            if (comma) try w.writeByte(',');
                            comma = true;
                            try std.json.Stringify.value(turn, .{}, w);
                        }
                        try w.writeByte(']');
                    }
                    try w.writeAll(",\"live_events\":");
                    try w.writeAll(snapshot.events_json);
                    return w.writeByte('}');
                }
                return error.ChildNotFound;
            }
            try session.refreshHistory();
            try w.writeAll("{\"ok\":true,\"history\":");
            try w.writeAll(session.history_json orelse "[]");
            return w.writeByte('}');
        }
        return error.UnknownCommand;
    }
};

fn historyBelongsToWork(turn: types.HistoryTurn, work_id: []const u8) bool {
    const saved_work = switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    } orelse return false;
    return std.mem.eql(u8, saved_work, work_id);
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = objectField(value, key) orelse return null;
    return if (field == .string) field.string else null;
}
fn uintField(value: std.json.Value, key: []const u8) ?u64 {
    const field = objectField(value, key) orelse return null;
    return if (field == .integer and field.integer >= 0) @intCast(field.integer) else null;
}
fn boolField(value: std.json.Value, key: []const u8) ?bool {
    const field = objectField(value, key) orelse return null;
    return if (field == .bool) field.bool else null;
}

/// Runs until an explicit shutdown request. The caller initializes std.Io/env first.
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
    const state_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(state_path);
    const incarnation = try alloc.print("{d}-{d}", .{ io_mod.milliTimestamp(), std.c.getpid() });
    defer alloc.free(incarnation);
    var daemon = Daemon{ .alloc = alloc, .cfg = cfg, .home = io_mod.homeDir() orelse return error.HomeUnavailable, .state_path = state_path, .incarnation = incarnation };
    defer {
        for (daemon.sessions.items) |session| session.deinit();
        daemon.sessions.deinit(alloc);
        if (daemon.last_attached_id) |id| alloc.free(id);
    }
    try daemon.restore();
    try daemon.discoverSaved();
    while (!daemon.stopping) {
        daemon.tick();
        var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 200) == 0) continue;
        const stream = try listener.accept(io);
        defer stream.close(io);
        const send_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&send_timeout));
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const request_alloc = arena.allocator();
        const bytes = client.readFrame(request_alloc, stream, 2000) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, request_alloc, bytes, .{}) catch {
            client.writeFrame(stream, "{\"ok\":false,\"error\":\"InvalidJson\"}") catch {};
            continue;
        };
        var out: std.Io.Writer.Allocating = .init(request_alloc);
        daemon.handle(parsed.value, &out.writer, request_alloc) catch |err| {
            out.clearRetainingCapacity();
            try std.json.Stringify.value(.{ .ok = false, .@"error" = @errorName(err) }, .{}, &out.writer);
        };
        client.writeFrame(stream, out.written()) catch {};
    }
    try daemon.persist();
}

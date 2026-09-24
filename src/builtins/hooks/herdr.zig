//! Best-effort reporter for the herdr agent multiplexer.
//!
//! Inside a herdr pane the interactive session reports its status and session
//! to herdr, then releases the pane on exit. A background thread owns the
//! socket, so a slow or missing herdr server never blocks fx; callers only
//! record the latest status. Every request carries a strictly increasing
//! `seq`, so herdr ignores a report that arrives after a newer one.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");

/// What herdr shows for the pane.
pub const Status = enum {
    idle,
    working,
    awaiting_approval,
    awaiting_answer,

    fn state(self: Status) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .awaiting_approval, .awaiting_answer => "blocked",
        };
    }

    fn message(self: Status) ?[]const u8 {
        return switch (self) {
            .idle, .working => null,
            .awaiting_approval => "Waiting for approval",
            .awaiting_answer => "Waiting for an answer",
        };
    }
};

/// Why the pane's session is being reported. herdr moves a pane to a
/// different session only when the report names a recognized start source.
pub const SessionStart = enum {
    startup,
    new,
    resumed,

    fn wireName(self: SessionStart) []const u8 {
        return switch (self) {
            .startup => "startup",
            .new => "new",
            .resumed => "resume",
        };
    }
};

/// Maximum wait for herdr's one-line reply.
const response_timeout = std.posix.timeval{ .sec = 0, .usec = 250_000 };
/// fx session ids are short; a longer id is not reported.
const max_session_id_bytes = 128;

// Third-party reporters use the `custom:` source prefix.
const source = "custom:fx";
const agent_name = "fx";

const Environment = struct {
    herdr_env: ?[]const u8,
    socket_path: ?[]const u8,
    pane_id: ?[]const u8,
    fx_herdr: ?[]const u8,
};

const Request = union(enum) {
    report: struct { status: Status, session_id: []const u8 },
    session: struct { session_id: []const u8, start: SessionStart },
    release,
};

pub const Client = struct {
    enabled: bool = false,
    alloc: ?std.mem.Allocator = null,
    /// Owned; immutable while the sender thread runs.
    socket_path: []u8 = &.{},
    pane_id: []u8 = &.{},
    thread: ?std.Thread = null,
    /// Last status handed to the sender. Only the publishing thread uses it.
    published: ?Status = null,

    /// Guards the fields below it.
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending_status: ?Status = null,
    pending_session: ?SessionStart = null,
    session_id_buf: [max_session_id_bytes]u8 = undefined,
    session_id_len: usize = 0,
    stopping: bool = false,

    /// Used by the sender thread, then by `deinit` after the join.
    next_id: u64 = 1,
    last_seq: u64 = 0,

    pub fn initFromEnv(self: *Client, alloc: std.mem.Allocator) void {
        if (comptime host_target.is_wasm) return;
        const env: Environment = .{
            .herdr_env = io_mod.getenv("HERDR_ENV"),
            .socket_path = io_mod.getenv("HERDR_SOCKET_PATH"),
            .pane_id = io_mod.getenv("HERDR_PANE_ID"),
            .fx_herdr = io_mod.getenv("FX_HERDR"),
        };
        if (!shouldEnable(env)) {
            debug_trace.logf("herdr", "disabled herdr_env={s} socket={s} pane={s} fx_herdr={s}", .{
                env.herdr_env orelse "(unset)",
                env.socket_path orelse "(unset)",
                env.pane_id orelse "(unset)",
                env.fx_herdr orelse "(unset)",
            });
            return;
        }
        self.start(alloc, env.socket_path.?, env.pane_id.?);
    }

    fn start(self: *Client, alloc: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) void {
        if (comptime host_target.is_wasm) return;
        const path_copy = alloc.dupe(u8, socket_path) catch return;
        const pane_copy = alloc.dupe(u8, pane_id) catch {
            alloc.free(path_copy);
            return;
        };
        self.alloc = alloc;
        self.socket_path = path_copy;
        self.pane_id = pane_copy;
        self.thread = std.Thread.spawn(.{}, runSender, .{self}) catch |err| {
            debug_trace.logf("herdr", "disabled sender_spawn_err={s}", .{@errorName(err)});
            self.freeOwned();
            return;
        };
        self.enabled = true;
        debug_trace.logf("herdr", "enabled socket={s} pane_id={s}", .{ path_copy, pane_copy });
    }

    /// Stops the sender, then releases the pane so herdr stops showing fx.
    /// The release is sent only after the sender exits, so no report can
    /// follow it and reclaim the pane.
    pub fn deinit(self: *Client) void {
        if (self.thread) |thread| {
            const io = io_mod.getIo();
            self.mutex.lockUncancelable(io);
            self.stopping = true;
            self.cond.signal(io);
            self.mutex.unlock(io);
            thread.join();
            self.thread = null;
            self.send(.release);
        }
        self.freeOwned();
    }

    fn freeOwned(self: *Client) void {
        if (self.alloc) |alloc| {
            if (self.socket_path.len > 0) alloc.free(self.socket_path);
            if (self.pane_id.len > 0) alloc.free(self.pane_id);
        }
        self.socket_path = &.{};
        self.pane_id = &.{};
        self.alloc = null;
        self.enabled = false;
    }

    /// Records the pane's latest status for the sender. Never waits on herdr;
    /// a status equal to the last one published is ignored.
    pub fn publish(self: *Client, status: Status) void {
        if (!self.enabled) return;
        if (self.published == status) return;
        self.published = status;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.pending_status = status;
        self.cond.signal(io);
    }

    /// Reports fx's active session so herdr can resume it in this pane after a
    /// restart. Later status reports carry the same session.
    pub fn reportSession(self: *Client, session_id: []const u8, start_source: SessionStart) void {
        if (!self.enabled or session_id.len == 0) return;
        if (session_id.len > max_session_id_bytes) {
            debug_trace.logf("herdr", "session id not reported len={d}", .{session_id.len});
            return;
        }
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        @memcpy(self.session_id_buf[0..session_id.len], session_id);
        self.session_id_len = session_id.len;
        self.pending_session = start_source;
        self.cond.signal(io);
    }

    fn runSender(self: *Client) void {
        const io = io_mod.getIo();
        var session_id_buf: [max_session_id_bytes]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (!self.stopping and self.pending_status == null and self.pending_session == null) {
                self.cond.waitUncancelable(io, &self.mutex);
            }
            if (self.stopping) {
                if (self.pending_status) |status| {
                    debug_trace.logf("herdr", "dropped status={s} reason=exit", .{@tagName(status)});
                }
                self.mutex.unlock(io);
                return;
            }
            const session_start = self.pending_session;
            const status = self.pending_status;
            self.pending_session = null;
            self.pending_status = null;
            const session_id = session_id_buf[0..self.session_id_len];
            @memcpy(session_id, self.session_id_buf[0..self.session_id_len]);
            self.mutex.unlock(io);

            if (session_start) |start_source| {
                self.send(.{ .session = .{ .session_id = session_id, .start = start_source } });
            }
            if (status) |next| {
                self.send(.{ .report = .{ .status = next, .session_id = session_id } });
            }
        }
    }

    fn send(self: *Client, request: Request) void {
        if (comptime host_target.is_wasm) return;
        self.sendRequest(request) catch |err| {
            debug_trace.logf("herdr", "send failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
        };
    }

    fn sendRequest(self: *Client, request: Request) !void {
        const io = io_mod.getIo();
        const id = self.next_id;
        self.next_id += 1;
        self.last_seq = nextSeq(self.last_seq, io_mod.nanoTimestamp());
        const seq = self.last_seq;

        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        var stream = try address.connect(io);
        defer stream.close(io);
        applyResponseTimeout(stream);

        var buffer: [1024]u8 = undefined;
        var stream_writer = stream.writer(io, &buffer);
        const w = &stream_writer.interface;
        switch (request) {
            .report => |r| try writeReportAgent(w, id, self.pane_id, r.status, seq, r.session_id),
            .session => |s| try writeReportAgentSession(w, id, self.pane_id, seq, s.session_id, s.start),
            .release => try writeReleaseAgent(w, id, self.pane_id, seq),
        }
        try w.flush();
        drainResponse(stream);
        debug_trace.logf("herdr", "sent {s} seq={d} pane_id={s}", .{ @tagName(request), seq, self.pane_id });
    }
};

fn shouldEnable(env: Environment) bool {
    if (env.fx_herdr) |val| {
        if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false")) return false;
    }
    const herdr_env = env.herdr_env orelse return false;
    if (!std.mem.eql(u8, herdr_env, "1")) return false;
    const path = env.socket_path orelse return false;
    const pane = env.pane_id orelse return false;
    return path.len > 0 and socketPathFits(path) and pane.len > 0;
}

/// Zig accepts Unix socket paths longer than the platform's `sun_path` and
/// then overruns it on connect, so such paths never reach the sender.
fn socketPathFits(path: []const u8) bool {
    const sun_path_len = @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len;
    return path.len < sun_path_len;
}

/// herdr keeps the last `seq` per pane and source across fx processes and its
/// own restarts, so sequence numbers follow the wall clock and never repeat.
fn nextSeq(last: u64, now_ns: i128) u64 {
    const now: u64 = std.math.cast(u64, now_ns) orelse if (now_ns < 0) 0 else std.math.maxInt(u64);
    return @max(last +| 1, now);
}

fn applyResponseTimeout(stream: std.Io.net.Stream) void {
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&response_timeout),
    ) catch {};
}

/// Waits briefly for herdr's single-line reply before closing, bounded by
/// SO_RCVTIMEO so a hung peer cannot hold the sender.
fn drainResponse(stream: std.Io.net.Stream) void {
    var buffer: [512]u8 = undefined;
    var stream_reader = stream.reader(io_mod.getIo(), &buffer);
    _ = stream_reader.interface.takeDelimiterInclusive('\n') catch {};
}

/// herdr's JSON-RPC requires the request id to be a string, not a number.
fn writeRequestStart(w: *std.Io.Writer, id: u64, method: []const u8, pane_id: []const u8) !void {
    try w.print("{{\"id\":\"{d}\",\"method\":", .{id});
    try jsonrpc.writeJsonStr(method, w);
    try w.writeAll(",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
}

fn writeReportAgent(
    w: *std.Io.Writer,
    id: u64,
    pane_id: []const u8,
    status: Status,
    seq: u64,
    session_id: []const u8,
) !void {
    try writeRequestStart(w, id, "pane.report_agent", pane_id);
    try w.writeAll(",\"state\":");
    try jsonrpc.writeJsonStr(status.state(), w);
    if (status.message()) |text| {
        try w.writeAll(",\"message\":");
        try jsonrpc.writeJsonStr(text, w);
    }
    try w.print(",\"seq\":{d}", .{seq});
    // herdr drops a pane's session when a state report arrives without one.
    if (session_id.len > 0) {
        try w.writeAll(",\"agent_session_id\":");
        try jsonrpc.writeJsonStr(session_id, w);
    }
    try w.writeAll("}}\n");
}

fn writeReportAgentSession(
    w: *std.Io.Writer,
    id: u64,
    pane_id: []const u8,
    seq: u64,
    session_id: []const u8,
    start: SessionStart,
) !void {
    try writeRequestStart(w, id, "pane.report_agent_session", pane_id);
    try w.print(",\"seq\":{d}", .{seq});
    try w.writeAll(",\"agent_session_id\":");
    try jsonrpc.writeJsonStr(session_id, w);
    try w.writeAll(",\"session_start_source\":");
    try jsonrpc.writeJsonStr(start.wireName(), w);
    try w.writeAll("}}\n");
}

fn writeReleaseAgent(w: *std.Io.Writer, id: u64, pane_id: []const u8, seq: u64) !void {
    try writeRequestStart(w, id, "pane.release_agent", pane_id);
    try w.print(",\"seq\":{d}", .{seq});
    try w.writeAll("}}\n");
}

fn testEnvironment(overrides: struct {
    herdr_env: ?[]const u8 = "1",
    socket_path: ?[]const u8 = "/tmp/herdr.sock",
    pane_id: ?[]const u8 = "w1:p1",
    fx_herdr: ?[]const u8 = null,
}) Environment {
    return .{
        .herdr_env = overrides.herdr_env,
        .socket_path = overrides.socket_path,
        .pane_id = overrides.pane_id,
        .fx_herdr = overrides.fx_herdr,
    };
}

test "shouldEnable requires HERDR_ENV=1, a socket path, and a pane id" {
    try std.testing.expect(shouldEnable(testEnvironment(.{})));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .herdr_env = null })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .herdr_env = "0" })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .herdr_env = "true" })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .socket_path = null })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .socket_path = "" })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .socket_path = "/tmp/" ++ "s" ** 200 })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .pane_id = null })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .pane_id = "" })));
}

test "shouldEnable honors FX_HERDR opt-out" {
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .fx_herdr = "0" })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .fx_herdr = "false" })));
    try std.testing.expect(!shouldEnable(testEnvironment(.{ .fx_herdr = "FALSE" })));
    try std.testing.expect(shouldEnable(testEnvironment(.{ .fx_herdr = "1" })));
}

test "nextSeq follows the wall clock and stays strictly increasing" {
    try std.testing.expectEqual(@as(u64, 1_000), nextSeq(0, 1_000));
    try std.testing.expectEqual(@as(u64, 1_001), nextSeq(1_000, 1_000));
    try std.testing.expectEqual(@as(u64, 1_001), nextSeq(1_000, 500));
    try std.testing.expectEqual(@as(u64, 1), nextSeq(0, -5));
    try std.testing.expectEqual(std.math.maxInt(u64), nextSeq(std.math.maxInt(u64), 0));
}

test "report_agent carries state, blocked message, seq, and session" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgent(&out.writer, 7, "w1:p1", .awaiting_approval, 42, "session-42");
    try std.testing.expectEqualStrings(
        "{\"id\":\"7\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"blocked\"," ++
            "\"message\":\"Waiting for approval\",\"seq\":42,\"agent_session_id\":\"session-42\"}}\n",
        out.written(),
    );
}

test "report_agent omits message and session when absent" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgent(&out.writer, 1, "w1:p1", .working, 9, "");
    try std.testing.expectEqualStrings(
        "{\"id\":\"1\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"working\",\"seq\":9}}\n",
        out.written(),
    );
}

test "report_agent escapes pane id" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgent(&out.writer, 2, "pane\"x", .awaiting_answer, 3, "");
    try std.testing.expectEqualStrings(
        "{\"id\":\"2\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"pane\\\"x\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"blocked\"," ++
            "\"message\":\"Waiting for an answer\",\"seq\":3}}\n",
        out.written(),
    );
}

test "report_agent_session serializes session identity and start source" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgentSession(&out.writer, 3, "w1:p1", 5, "session-42", .resumed);
    try std.testing.expectEqualStrings(
        "{\"id\":\"3\",\"method\":\"pane.report_agent_session\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"seq\":5,\"agent_session_id\":\"session-42\"," ++
            "\"session_start_source\":\"resume\"}}\n",
        out.written(),
    );
}

test "release_agent names the reporting source and agent" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReleaseAgent(&out.writer, 4, "w1:p1", 6);
    try std.testing.expectEqualStrings(
        "{\"id\":\"4\",\"method\":\"pane.release_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"seq\":6}}\n",
        out.written(),
    );
}

test "disabled client ignores status and session reports" {
    var client: Client = .{};
    client.publish(.working);
    client.reportSession("session-1", .startup);
    try std.testing.expect(client.published == null);
    try std.testing.expect(client.pending_status == null);
    try std.testing.expect(client.pending_session == null);
    client.deinit();
}

/// Records one request line per connection until it reads `stop_line`.
const FakeHerdr = struct {
    const stop_line = "stop\n";

    server: std.Io.net.Server,
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,

    fn run(self: *FakeHerdr) void {
        const io = std.testing.io;
        while (true) {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);
            var read_buf: [2048]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            const line = reader.interface.takeDelimiterInclusive('\n') catch continue;
            if (std.mem.eql(u8, line, stop_line)) return;
            var write_buf: [64]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            writer.interface.writeAll("{\"id\":\"1\",\"result\":{}}\n") catch {};
            writer.interface.flush() catch {};
            const copy = std.testing.allocator.dupe(u8, line) catch return;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.lines.append(std.testing.allocator, copy) catch std.testing.allocator.free(copy);
        }
    }

    fn hasLine(self: *FakeHerdr, needle: []const u8) bool {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        for (self.lines.items) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) return true;
        }
        return false;
    }

    fn stop(address: *const std.Io.net.UnixAddress) !void {
        const io = std.testing.io;
        var stream = try address.connect(io);
        defer stream.close(io);
        var buf: [16]u8 = undefined;
        var writer = stream.writer(io, &buf);
        try writer.interface.writeAll(stop_line);
        try writer.interface.flush();
    }

    fn deinit(self: *FakeHerdr) void {
        for (self.lines.items) |line| std.testing.allocator.free(line);
        self.lines.deinit(std.testing.allocator);
        self.server.deinit(std.testing.io);
    }
};

test "client reports in order off the caller thread and releases last" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    // Test temp directories can exceed the platform's socket path limit.
    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/fx-herdr-{d}.sock", .{io_mod.nanoTimestamp()});
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);

    var herdr: FakeHerdr = .{ .server = try address.listen(io, .{}) };
    defer herdr.deinit();
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    const server_thread = try std.Thread.spawn(.{}, FakeHerdr.run, .{&herdr});

    var client: Client = .{};
    client.start(alloc, socket_path, "w1:p1");
    try std.testing.expect(client.enabled);
    client.reportSession("session-42", .startup);
    client.publish(.working);
    client.publish(.working);
    client.publish(.awaiting_approval);
    client.publish(.idle);
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (!herdr.hasLine("\"state\":\"idle\"") and io_mod.milliTimestamp() < deadline_ms) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    client.deinit();
    try FakeHerdr.stop(&address);
    server_thread.join();

    const lines = herdr.lines.items;
    try std.testing.expect(lines.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "\"method\":\"pane.report_agent_session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[lines.len - 1], "\"method\":\"pane.release_agent\"") != null);
    // A newer status may replace one the sender has not taken yet, but the
    // last report always carries the latest status and the session.
    const final_report = lines[lines.len - 2];
    try std.testing.expect(std.mem.indexOf(u8, final_report, "\"state\":\"idle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_report, "\"agent_session_id\":\"session-42\"") != null);
    var last_seq: u64 = 0;
    for (lines) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?.object;
        try std.testing.expectEqualStrings("custom:fx", params.get("source").?.string);
        try std.testing.expectEqualStrings("fx", params.get("agent").?.string);
        const seq: u64 = @intCast(params.get("seq").?.integer);
        try std.testing.expect(seq > last_seq);
        last_seq = seq;
    }
}

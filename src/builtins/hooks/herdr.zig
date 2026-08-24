//! Best-effort lifecycle reporter for the herdr agent multiplexer.
//!
//! Each report uses a short-lived Unix socket. Failures and reply timeouts are
//! ignored so the integration cannot block or terminate an fx session.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");

pub const State = enum { idle, working, blocked };

// herdr protocol limits custom status to 32 bytes.
const custom_status_max = 32;
/// Maximum wait for herdr's one-line reply.
const response_timeout = std.posix.timeval{ .sec = 0, .usec = 250_000 };

// Third-party reporters use the `custom:` source prefix.
const source = "custom:fx";
const agent_name = "fx";

const Request = union(enum) {
    report: struct { state: State, custom_status: ?[]const u8 },
    session: []const u8,
    /// null clears the pane label.
    pane_rename: ?[]const u8,
    /// null clears the agent name.
    agent_rename: ?[]const u8,
    clear_authority,
};

pub const Client = struct {
    enabled: bool = false,
    mutex: std.Io.Mutex = .init,
    alloc: ?std.mem.Allocator = null,
    socket_path: []u8 = &.{},
    pane_id: []u8 = &.{},
    next_id: u64 = 1,

    pub fn shouldEnable(
        fx_herdr: ?[]const u8,
        socket_path: ?[]const u8,
        pane_id: ?[]const u8,
    ) bool {
        if (fx_herdr) |val| {
            if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false"))
                return false;
        }
        const path = socket_path orelse return false;
        const pane = pane_id orelse return false;
        return path.len > 0 and pane.len > 0;
    }

    pub fn initFromEnv(self: *Client, alloc: std.mem.Allocator) void {
        const socket_path = io_mod.getenv("HERDR_SOCKET_PATH");
        const pane_id = io_mod.getenv("HERDR_PANE_ID");
        if (!shouldEnable(io_mod.getenv("FX_HERDR"), socket_path, pane_id)) {
            debug_trace.logf("herdr", "disabled socket={s} pane={s} fx_herdr={s}", .{
                socket_path orelse "(unset)",
                pane_id orelse "(unset)",
                io_mod.getenv("FX_HERDR") orelse "(unset)",
            });
            return;
        }

        const path_copy = alloc.dupe(u8, socket_path.?) catch return;
        const pane_copy = alloc.dupe(u8, pane_id.?) catch {
            alloc.free(path_copy);
            return;
        };
        self.alloc = alloc;
        self.socket_path = path_copy;
        self.pane_id = pane_copy;
        self.enabled = true;
        debug_trace.logf("herdr", "enabled socket={s} pane_id={s}", .{ path_copy, pane_copy });
    }

    pub fn deinit(self: *Client) void {
        // Clear herdr's pane before freeing paths so exit does not leave a
        // stale idle "fx" label behind.
        self.release();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.alloc) |alloc| {
            if (self.socket_path.len > 0) alloc.free(self.socket_path);
            if (self.pane_id.len > 0) alloc.free(self.pane_id);
        }
        self.socket_path = &.{};
        self.pane_id = &.{};
        self.alloc = null;
        self.enabled = false;
    }

    /// Report a semantic lifecycle state. `custom_status` is a short (<=32 byte)
    /// activity label shown in herdr's UI; pass null to omit it.
    pub fn reportState(self: *Client, state: State, custom_status: ?[]const u8) void {
        self.send(.{ .report = .{ .state = state, .custom_status = clampStatus(custom_status) } });
    }

    /// Report fx's session id so herdr can associate the pane with a resumable
    /// session. Does not affect herdr's semantic state.
    pub fn reportSession(self: *Client, session_id: []const u8) void {
        if (session_id.len == 0) return;
        self.send(.{ .session = session_id });
    }

    /// Name the pane/agent so herdr lists fx even while idle. Best-effort;
    /// called once at startup after the first state report.
    pub fn announce(self: *Client) void {
        self.sendAll(&.{
            .{ .pane_rename = agent_name },
            .{ .agent_rename = agent_name },
        });
    }

    /// Remove fx from the pane on exit: drop the reported agent and clear the
    /// label/name. Without this the pane keeps showing "fx" after fx is gone.
    pub fn release(self: *Client) void {
        self.sendAll(&.{
            .{ .agent_rename = null },
            .clear_authority,
            .{ .pane_rename = null },
        });
    }

    fn send(self: *Client, request: Request) void {
        self.sendAll(&.{request});
    }

    fn sendAll(self: *Client, requests: []const Request) void {
        if (comptime host_target.is_wasm) return;
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (requests) |request| {
            self.sendLocked(request) catch |err| {
                debug_trace.logf(
                    "herdr",
                    "send failed kind={s} err={s}",
                    .{ @tagName(request), @errorName(err) },
                );
            };
        }
    }

    fn sendLocked(self: *Client, request: Request) !void {
        const io = io_mod.getIo();
        var stream = try self.connectLocked();
        defer stream.close(io);
        applyResponseTimeout(stream);

        var buffer: [1024]u8 = undefined;
        var stream_writer = stream.writer(io, &buffer);
        const w = &stream_writer.interface;
        const id = self.takeIdLocked();
        switch (request) {
            .report => |r| try writeReportAgent(w, id, self.pane_id, r.state, r.custom_status),
            .session => |session_id| try writeReportAgentSession(w, id, self.pane_id, session_id),
            .pane_rename => |label| try writeRename(w, id, "pane.rename", "pane_id", self.pane_id, "label", label),
            .agent_rename => |name| try writeRename(w, id, "agent.rename", "target", self.pane_id, "name", name),
            .clear_authority => try writeClearAuthority(w, id, self.pane_id),
        }
        try w.flush();
        drainResponse(stream);
        debug_trace.logf("herdr", "sent {s} pane_id={s}", .{ @tagName(request), self.pane_id });
    }

    fn connectLocked(self: *Client) !std.Io.net.Stream {
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        return address.connect(io_mod.getIo());
    }

    fn takeIdLocked(self: *Client) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

fn applyResponseTimeout(stream: std.Io.net.Stream) void {
    if (comptime builtin.os.tag == .windows) return;
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&response_timeout),
    ) catch {};
}

fn clampStatus(custom_status: ?[]const u8) ?[]const u8 {
    const status = custom_status orelse return null;
    if (status.len == 0) return null;
    return status[0..@min(status.len, custom_status_max)];
}

/// Wait briefly for herdr's single-line response before closing. herdr applies
/// each request as it reads it; waiting serializes rapid-fire reports so a
/// later one cannot race ahead of an earlier one. Bounded by SO_RCVTIMEO so a
/// hung peer cannot block forever.
fn drainResponse(stream: std.Io.net.Stream) void {
    var buffer: [512]u8 = undefined;
    var stream_reader = stream.reader(io_mod.getIo(), &buffer);
    _ = stream_reader.interface.takeDelimiterInclusive('\n') catch {};
}

/// herdr's JSON-RPC requires the request id to be a string, not a number.
fn writeId(w: *std.Io.Writer, id: u64) !void {
    try w.writeAll("{\"id\":\"");
    try w.print("{d}", .{id});
    try w.writeAll("\"");
}

fn writeReportAgent(
    w: *std.Io.Writer,
    id: u64,
    pane_id: []const u8,
    state: State,
    custom_status: ?[]const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
    try w.writeAll(",\"state\":");
    try jsonrpc.writeJsonStr(@tagName(state), w);
    if (custom_status) |status| {
        try w.writeAll(",\"custom_status\":");
        try jsonrpc.writeJsonStr(status, w);
    }
    try w.writeAll("}}\n");
}

fn writeReportAgentSession(
    w: *std.Io.Writer,
    id: u64,
    pane_id: []const u8,
    session_id: []const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.report_agent_session\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
    try w.writeAll(",\"agent_session_id\":");
    try jsonrpc.writeJsonStr(session_id, w);
    try w.writeAll("}}\n");
}

fn writeRename(
    w: *std.Io.Writer,
    id: u64,
    method: []const u8,
    target_key: []const u8,
    target: []const u8,
    value_key: []const u8,
    value: ?[]const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":");
    try jsonrpc.writeJsonStr(method, w);
    try w.writeAll(",\"params\":{");
    try jsonrpc.writeJsonStr(target_key, w);
    try w.writeAll(":");
    try jsonrpc.writeJsonStr(target, w);
    try w.writeAll(",");
    try jsonrpc.writeJsonStr(value_key, w);
    try w.writeAll(":");
    if (value) |v| try jsonrpc.writeJsonStr(v, w) else try w.writeAll("null");
    try w.writeAll("}}\n");
}

fn writeClearAuthority(w: *std.Io.Writer, id: u64, pane_id: []const u8) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.clear_agent_authority\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll("}}\n");
}

test "shouldEnable requires both socket path and pane id" {
    try std.testing.expect(Client.shouldEnable(null, "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(!Client.shouldEnable(null, null, "w1:p1"));
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/herdr.sock", null));
    try std.testing.expect(!Client.shouldEnable(null, "", "w1:p1"));
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/herdr.sock", ""));
}

test "shouldEnable honors FX_HERDR opt-out" {
    try std.testing.expect(!Client.shouldEnable("0", "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(!Client.shouldEnable("false", "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(!Client.shouldEnable("FALSE", "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(Client.shouldEnable("1", "/tmp/herdr.sock", "w1:p1"));
}

test "report_agent serializes a single newline-delimited json line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgent(&out.writer, 7, "w1:p1", .working, "editing");
    try std.testing.expectEqualStrings(
        "{\"id\":\"7\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"working\"," ++
            "\"custom_status\":\"editing\"}}\n",
        out.written(),
    );
}

test "report_agent omits custom_status when null" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgent(&out.writer, 1, "w1:p1", .idle, null);
    try std.testing.expectEqualStrings(
        "{\"id\":\"1\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"idle\"}}\n",
        out.written(),
    );
}

test "report_agent escapes pane id" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgent(&out.writer, 2, "pane\"x", .blocked, null);
    try std.testing.expectEqualStrings(
        "{\"id\":\"2\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"pane\\\"x\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"blocked\"}}\n",
        out.written(),
    );
}

test "pane.rename labels the pane" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRename(&out.writer, 4, "pane.rename", "pane_id", "w1:p1", "label", "fx");
    try std.testing.expectEqualStrings(
        "{\"id\":\"4\",\"method\":\"pane.rename\",\"params\":{\"pane_id\":\"w1:p1\",\"label\":\"fx\"}}\n",
        out.written(),
    );
}

test "agent.rename names the agent" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRename(&out.writer, 5, "agent.rename", "target", "w1:p1", "name", "fx");
    try std.testing.expectEqualStrings(
        "{\"id\":\"5\",\"method\":\"agent.rename\",\"params\":{\"target\":\"w1:p1\",\"name\":\"fx\"}}\n",
        out.written(),
    );
}

test "rename with null value clears the label" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRename(&out.writer, 6, "pane.rename", "pane_id", "w1:p1", "label", null);
    try std.testing.expectEqualStrings(
        "{\"id\":\"6\",\"method\":\"pane.rename\",\"params\":{\"pane_id\":\"w1:p1\",\"label\":null}}\n",
        out.written(),
    );
}

test "clear_agent_authority removes fx from the pane" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeClearAuthority(&out.writer, 7, "w1:p1");
    try std.testing.expectEqualStrings(
        "{\"id\":\"7\",\"method\":\"pane.clear_agent_authority\",\"params\":{\"pane_id\":\"w1:p1\",\"source\":\"custom:fx\"}}\n",
        out.written(),
    );
}

test "report_agent_session serializes session identity" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReportAgentSession(&out.writer, 3, "w1:p1", "session-42");
    try std.testing.expectEqualStrings(
        "{\"id\":\"3\",\"method\":\"pane.report_agent_session\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"agent_session_id\":\"session-42\"}}\n",
        out.written(),
    );
}

test "clampStatus caps to 32 bytes and normalizes empty" {
    try std.testing.expect(clampStatus(null) == null);
    try std.testing.expect(clampStatus("") == null);
    const long = "0123456789012345678901234567890123456789";
    const clamped = clampStatus(long).?;
    try std.testing.expectEqual(@as(usize, custom_status_max), clamped.len);
}

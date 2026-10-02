//! Best-effort sidebar status reporter for the cmux terminal.
//!
//! Each report uses a short-lived connection to cmux's control socket.
//! Failures and reply timeouts are ignored so the integration cannot block or
//! terminate an fx session.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const hooks = @import("../../core/hooks/hooks.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");

pub const State = enum { idle, working, needs_input, failed };

/// Sidebar status key. cmux keys status pills by owner so tools do not
/// overwrite each other's entries.
const status_key = "fx";
const notification_title = "fx";
/// cmux authenticates socket callers with a per-terminal capability token.
const capability_command = "_cmux_capability_v1";
/// Maximum wait for cmux's one-line reply.
const response_timeout = std.posix.timeval{ .sec = 0, .usec = 250_000 };

/// Matches the pills cmux renders for its first-party agent integrations.
const Pill = struct {
    /// A single socket token; multi-word values are single-quoted.
    value: []const u8,
    icon: []const u8,
    color: []const u8,
    priority: ?u8 = null,
};

fn pillFor(state: State) Pill {
    return switch (state) {
        .working => .{ .value = "Running", .icon = "bolt.fill", .color = "#4C8DFF" },
        .idle => .{ .value = "Idle", .icon = "pause.circle.fill", .color = "#8E8E93" },
        .needs_input => .{ .value = "'Needs input'", .icon = "bell.fill", .color = "#4C8DFF", .priority = 100 },
        .failed => .{ .value = "Error", .icon = "exclamationmark.triangle.fill", .color = "#FF453A", .priority = 100 },
    };
}

const Attention = struct {
    subtitle: []const u8,
    body: []const u8,
};

/// Notification text never includes prompts, tool arguments, or output.
fn attentionText(kind: hooks.AttentionKind) Attention {
    return switch (kind) {
        .permission => .{ .subtitle = "Permission needed", .body = "fx is waiting for approval" },
        .question => .{ .subtitle = "Question", .body = "fx is waiting for your answer" },
        .route_recovery => .{ .subtitle = "Needs attention", .body = "fx needs a decision to continue" },
    };
}

const Request = union(enum) {
    set_status: State,
    clear_status,
    notify: hooks.AttentionKind,
};

pub const Client = struct {
    enabled: bool = false,
    mutex: std.Io.Mutex = .init,
    alloc: ?std.mem.Allocator = null,
    socket_path: []u8 = &.{},
    workspace_id: []u8 = &.{},
    /// Empty when cmux runs without socket capabilities.
    capability: []u8 = &.{},
    /// Last state cmux acknowledged; repeated reports are skipped.
    last_state: ?State = null,
    next_id: u64 = 1,

    /// Workspace IDs and capability tokens are written verbatim into the
    /// socket line, so anything outside a conservative token alphabet disables
    /// the integration instead of risking a malformed command.
    pub fn shouldEnable(
        fx_cmux: ?[]const u8,
        socket_path: ?[]const u8,
        workspace_id: ?[]const u8,
        capability: ?[]const u8,
    ) bool {
        if (fx_cmux) |val| {
            if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false"))
                return false;
        }
        const path = socket_path orelse return false;
        const workspace = workspace_id orelse return false;
        if (path.len == 0 or !isSocketToken(workspace)) return false;
        if (capability) |token| {
            if (token.len > 0 and !isSocketToken(token)) return false;
        }
        return true;
    }

    pub fn initFromEnv(self: *Client, alloc: std.mem.Allocator) void {
        const socket_path = io_mod.getenv("CMUX_SOCKET_PATH");
        const workspace_id = io_mod.getenv("CMUX_WORKSPACE_ID");
        const capability = io_mod.getenv("CMUX_SOCKET_CAPABILITY");
        if (!shouldEnable(io_mod.getenv("FX_CMUX"), socket_path, workspace_id, capability)) {
            debug_trace.logf("cmux", "disabled socket={s} workspace={s} fx_cmux={s}", .{
                socket_path orelse "(unset)",
                workspace_id orelse "(unset)",
                io_mod.getenv("FX_CMUX") orelse "(unset)",
            });
            return;
        }

        const path_copy = alloc.dupe(u8, socket_path.?) catch return;
        const workspace_copy = alloc.dupe(u8, workspace_id.?) catch {
            alloc.free(path_copy);
            return;
        };
        const capability_copy = alloc.dupe(u8, capability orelse "") catch {
            alloc.free(path_copy);
            alloc.free(workspace_copy);
            return;
        };
        self.alloc = alloc;
        self.socket_path = path_copy;
        self.workspace_id = workspace_copy;
        self.capability = capability_copy;
        self.enabled = true;
        debug_trace.logf("cmux", "enabled socket={s} workspace={s}", .{ path_copy, workspace_copy });
    }

    pub fn deinit(self: *Client) void {
        // Clear the sidebar pill before freeing paths so exit does not leave a
        // stale "fx" status behind.
        self.release();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.alloc) |alloc| {
            if (self.socket_path.len > 0) alloc.free(self.socket_path);
            if (self.workspace_id.len > 0) alloc.free(self.workspace_id);
            if (self.capability.len > 0) alloc.free(self.capability);
        }
        self.socket_path = &.{};
        self.workspace_id = &.{};
        self.capability = &.{};
        self.alloc = null;
        self.last_state = null;
        self.enabled = false;
    }

    /// Show `state` as fx's sidebar pill in the current cmux workspace.
    pub fn reportState(self: *Client, state: State) void {
        if (comptime host_target.is_wasm) return;
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.last_state == state) return;
        self.sendLocked(.{ .set_status = state }) catch |err| {
            logSendFailure(.set_status, err);
            return;
        };
        self.last_state = state;
    }

    /// Post a cmux notification for a prompt that is waiting on the user.
    /// cmux suppresses the desktop banner when the workspace is focused.
    pub fn notifyAttention(self: *Client, kind: hooks.AttentionKind) void {
        self.send(.{ .notify = kind });
    }

    /// Remove fx's pill on exit.
    pub fn release(self: *Client) void {
        if (comptime host_target.is_wasm) return;
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.sendLocked(.clear_status) catch |err| logSendFailure(.clear_status, err);
        self.last_state = null;
    }

    fn send(self: *Client, request: Request) void {
        if (comptime host_target.is_wasm) return;
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.sendLocked(request) catch |err| logSendFailure(request, err);
    }

    fn sendLocked(self: *Client, request: Request) !void {
        const io = io_mod.getIo();
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        var stream = try address.connect(io);
        defer stream.close(io);
        applyResponseTimeout(stream);

        var buffer: [1024]u8 = undefined;
        var stream_writer = stream.writer(io, &buffer);
        const w = &stream_writer.interface;
        try writeCapability(w, self.capability);
        switch (request) {
            .set_status => |state| try writeSetStatus(w, self.workspace_id, state),
            .clear_status => try writeClearStatus(w, self.workspace_id),
            .notify => |kind| try writeNotify(w, self.takeIdLocked(), self.workspace_id, kind),
        }
        try w.flush();

        var reply_buffer: [512]u8 = undefined;
        const reply = readReply(stream, &reply_buffer);
        if (replyIsError(reply)) {
            debug_trace.logf("cmux", "rejected {s} reply={s}", .{ @tagName(request), reply });
            return error.CmuxRejected;
        }
        debug_trace.logf("cmux", "sent {s}", .{@tagName(request)});
    }

    fn takeIdLocked(self: *Client) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

fn logSendFailure(request: std.meta.Tag(Request), err: anyerror) void {
    debug_trace.logf("cmux", "send failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
}

fn isSocketToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':'))
            return false;
    }
    return true;
}

fn applyResponseTimeout(stream: std.Io.net.Stream) void {
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&response_timeout),
    ) catch {};
}

/// Wait briefly for cmux's single-line reply before closing. Waiting
/// serializes rapid reports so a later one cannot race ahead of an earlier
/// one. Bounded by SO_RCVTIMEO so a hung peer cannot block forever. Returns
/// an empty slice when no reply arrives.
fn readReply(stream: std.Io.net.Stream, buffer: []u8) []const u8 {
    var stream_reader = stream.reader(io_mod.getIo(), buffer);
    const line = stream_reader.interface.takeDelimiterExclusive('\n') catch return "";
    return line;
}

/// Text commands reply `ERROR: ...`; JSON-RPC commands reply `"ok":false`.
fn replyIsError(reply: []const u8) bool {
    return std.mem.startsWith(u8, reply, "ERROR") or
        std.mem.find(u8, reply, "\"ok\":false") != null;
}

fn writeCapability(w: *std.Io.Writer, capability: []const u8) !void {
    if (capability.len == 0) return;
    try w.print("{s} {s} ", .{ capability_command, capability });
}

fn writeSetStatus(w: *std.Io.Writer, workspace_id: []const u8, state: State) !void {
    const pill = pillFor(state);
    try w.print("set_status {s} {s} --icon={s} --color={s}", .{ status_key, pill.value, pill.icon, pill.color });
    if (pill.priority) |priority| try w.print(" --priority={d}", .{priority});
    try w.print(" --tab={s}\n", .{workspace_id});
}

fn writeClearStatus(w: *std.Io.Writer, workspace_id: []const u8) !void {
    try w.print("clear_status {s} --tab={s}\n", .{ status_key, workspace_id });
}

fn writeNotify(
    w: *std.Io.Writer,
    id: u64,
    workspace_id: []const u8,
    kind: hooks.AttentionKind,
) !void {
    const text = attentionText(kind);
    try w.print("{{\"id\":\"fx-{d}\",\"method\":\"notification.create_for_caller\",\"params\":{{", .{id});
    try w.writeAll("\"prefer_tty\":false,\"preferred_workspace_id\":");
    try jsonrpc.writeJsonStr(workspace_id, w);
    try w.writeAll(",\"title\":");
    try jsonrpc.writeJsonStr(notification_title, w);
    try w.writeAll(",\"subtitle\":");
    try jsonrpc.writeJsonStr(text.subtitle, w);
    try w.writeAll(",\"body\":");
    try jsonrpc.writeJsonStr(text.body, w);
    try w.writeAll("}}\n");
}

const test_workspace = "E68D9717-EEEC-49AB-B02C-0627C8983155";

test "shouldEnable requires a socket path and a workspace id" {
    try std.testing.expect(Client.shouldEnable(null, "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(!Client.shouldEnable(null, null, test_workspace, null));
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/cmux.sock", null, null));
    try std.testing.expect(!Client.shouldEnable(null, "", test_workspace, null));
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/cmux.sock", "", null));
}

test "shouldEnable honors FX_CMUX opt-out" {
    try std.testing.expect(!Client.shouldEnable("0", "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(!Client.shouldEnable("false", "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(!Client.shouldEnable("FALSE", "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(Client.shouldEnable("1", "/tmp/cmux.sock", test_workspace, null));
}

test "shouldEnable rejects values that would break the socket line" {
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/cmux.sock", "ws 1", null));
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/cmux.sock", "ws\n1", null));
    try std.testing.expect(!Client.shouldEnable(null, "/tmp/cmux.sock", test_workspace, "tok en"));
    try std.testing.expect(Client.shouldEnable(null, "/tmp/cmux.sock", "workspace:2", "v1.abc_DEF-1.x"));
    try std.testing.expect(Client.shouldEnable(null, "/tmp/cmux.sock", test_workspace, ""));
}

test "set_status serializes each state as one capability-prefixed line" {
    const cases = [_]struct { state: State, expected: []const u8 }{
        .{ .state = .working, .expected = "_cmux_capability_v1 v1.tok set_status fx Running --icon=bolt.fill --color=#4C8DFF --tab=" ++ test_workspace ++ "\n" },
        .{ .state = .idle, .expected = "_cmux_capability_v1 v1.tok set_status fx Idle --icon=pause.circle.fill --color=#8E8E93 --tab=" ++ test_workspace ++ "\n" },
        .{ .state = .needs_input, .expected = "_cmux_capability_v1 v1.tok set_status fx 'Needs input' --icon=bell.fill --color=#4C8DFF --priority=100 --tab=" ++ test_workspace ++ "\n" },
        .{ .state = .failed, .expected = "_cmux_capability_v1 v1.tok set_status fx Error --icon=exclamationmark.triangle.fill --color=#FF453A --priority=100 --tab=" ++ test_workspace ++ "\n" },
    };
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try writeCapability(&out.writer, "v1.tok");
        try writeSetStatus(&out.writer, test_workspace, case.state);
        try std.testing.expectEqualStrings(case.expected, out.written());
    }
}

test "clear_status omits the capability prefix when cmux has none" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCapability(&out.writer, "");
    try writeClearStatus(&out.writer, test_workspace);
    try std.testing.expectEqualStrings("clear_status fx --tab=" ++ test_workspace ++ "\n", out.written());
}

test "notify serializes an attention notification without user content" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeNotify(&out.writer, 3, test_workspace, .permission);
    try std.testing.expectEqualStrings(
        "{\"id\":\"fx-3\",\"method\":\"notification.create_for_caller\",\"params\":{" ++
            "\"prefer_tty\":false,\"preferred_workspace_id\":\"" ++ test_workspace ++ "\"," ++
            "\"title\":\"fx\",\"subtitle\":\"Permission needed\",\"body\":\"fx is waiting for approval\"}}\n",
        out.written(),
    );
}

test "replyIsError detects text and JSON-RPC failures" {
    try std.testing.expect(!replyIsError("OK"));
    try std.testing.expect(!replyIsError(""));
    try std.testing.expect(!replyIsError("{\"ok\":true,\"id\":\"fx-1\"}"));
    try std.testing.expect(replyIsError("ERROR: Unknown command 'x'"));
    try std.testing.expect(replyIsError("{\"ok\":false,\"error\":{}}"));
}

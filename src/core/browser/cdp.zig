//! The Chrome DevTools Protocol session layer over one browser connection
//! (D195). Commands carry ids and an optional flat `sessionId`; responses are
//! matched by id, and events wait in a bounded queue until a caller takes
//! them. One thread drives a connection at a time.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const websocket = @import("websocket.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Events kept for callers that have not asked yet. Older ones drop first.
const max_queued_events = 4096;

pub const Error = error{
    /// The browser answered with a protocol error; `Connection.last_error` says why.
    CdpError,
    Timeout,
    Cancelled,
    ConnectionClosed,
    OutOfMemory,
    InvalidResponse,
};

/// What carries messages. The real one is a WebSocket; tests script one.
pub const Transport = struct {
    ctx: *anyopaque,
    send_fn: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
    receive_fn: *const fn (*anyopaque, Allocator, i64, ?*std.atomic.Value(bool)) anyerror!?[]u8,
    close_fn: ?*const fn (*anyopaque, Allocator) void = null,
};

pub fn websocketTransport(client: *websocket.Client) Transport {
    const Impl = struct {
        fn send(ctx: *anyopaque, alloc: Allocator, bytes: []const u8) anyerror!void {
            const self: *websocket.Client = @ptrCast(@alignCast(ctx));
            try self.sendText(alloc, bytes);
        }
        fn receive(ctx: *anyopaque, alloc: Allocator, timeout_ms: i64, cancel: ?*std.atomic.Value(bool)) anyerror!?[]u8 {
            const self: *websocket.Client = @ptrCast(@alignCast(ctx));
            return self.receive(alloc, timeout_ms, cancel);
        }
        fn close(ctx: *anyopaque, alloc: Allocator) void {
            const self: *websocket.Client = @ptrCast(@alignCast(ctx));
            self.close(alloc);
        }
    };
    return .{ .ctx = client, .send_fn = Impl.send, .receive_fn = Impl.receive, .close_fn = Impl.close };
}

/// An event message, owned by the connection until taken.
pub const Event = struct {
    raw: []u8,
    parsed: std.json.Parsed(Value),

    pub fn method(self: *const Event) []const u8 {
        return stringField(self.parsed.value, "method") orelse "";
    }

    pub fn sessionId(self: *const Event) ?[]const u8 {
        return stringField(self.parsed.value, "sessionId");
    }

    pub fn params(self: *const Event) ?Value {
        return if (self.parsed.value == .object) self.parsed.value.object.get("params") else null;
    }

    pub fn deinit(self: *Event, alloc: Allocator) void {
        self.parsed.deinit();
        alloc.free(self.raw);
    }
};

/// A command's `result`, owned by the caller.
pub const Result = struct {
    parsed: std.json.Parsed(Value),
    raw: []u8,

    pub fn value(self: *const Result) Value {
        if (self.parsed.value == .object) {
            if (self.parsed.value.object.get("result")) |result| return result;
        }
        return .null;
    }

    pub fn deinit(self: *Result, alloc: Allocator) void {
        self.parsed.deinit();
        alloc.free(self.raw);
    }
};

pub const Connection = struct {
    alloc: Allocator,
    transport: Transport,
    next_id: u64 = 1,
    events: std.ArrayList(Event) = .empty,
    /// Answers that arrived while a caller waited for another id.
    early: std.AutoHashMapUnmanaged(u64, Result) = .empty,
    /// Ids whose answers nobody waits for.
    ignored: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The message of the last protocol error, owned.
    last_error: ?[]u8 = null,
    cancel: ?*std.atomic.Value(bool) = null,
    closed: bool = false,
    /// Called for each event as it arrives, before it is queued. Returning
    /// true consumes it. Used to answer dialogs while any call waits.
    on_event: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque, *Connection, *const Event) bool } = null,

    pub fn init(alloc: Allocator, transport: Transport) Connection {
        return .{ .alloc = alloc, .transport = transport };
    }

    pub fn deinit(self: *Connection) void {
        for (self.events.items) |*event| event.deinit(self.alloc);
        self.events.deinit(self.alloc);
        var it = self.early.valueIterator();
        while (it.next()) |result| result.deinit(self.alloc);
        self.early.deinit(self.alloc);
        self.ignored.deinit(self.alloc);
        if (self.last_error) |message| self.alloc.free(message);
        if (self.transport.close_fn) |close| close(self.transport.ctx, self.alloc);
    }

    /// Sends a command and returns its id. `params_json` is a JSON object or empty.
    pub fn send(self: *Connection, session_id: ?[]const u8, method: []const u8, params_json: []const u8) Error!u64 {
        if (self.closed) return error.ConnectionClosed;
        const id = self.next_id;
        self.next_id += 1;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
        std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
        if (params_json.len > 0) {
            w.writeAll(",\"params\":") catch return error.OutOfMemory;
            w.writeAll(params_json) catch return error.OutOfMemory;
        }
        if (session_id) |sid| {
            w.writeAll(",\"sessionId\":") catch return error.OutOfMemory;
            std.json.Stringify.value(sid, .{}, w) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
        self.transport.send_fn(self.transport.ctx, self.alloc, out.written()) catch {
            self.closed = true;
            return error.ConnectionClosed;
        };
        return id;
    }

    /// Sends a command whose answer is dropped when it arrives.
    pub fn sendIgnored(self: *Connection, session_id: ?[]const u8, method: []const u8, params_json: []const u8) Error!void {
        const id = try self.send(session_id, method, params_json);
        try self.ignored.put(self.alloc, id, {});
    }

    /// Sends a command and waits up to `timeout_ms` for its result.
    pub fn call(self: *Connection, session_id: ?[]const u8, method: []const u8, params_json: []const u8, timeout_ms: i64) Error!Result {
        const id = try self.send(session_id, method, params_json);
        return self.wait(id, timeout_ms);
    }

    /// Waits for the answer to `id`.
    pub fn wait(self: *Connection, id: u64, timeout_ms: i64) Error!Result {
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        while (true) {
            if (self.early.fetchRemove(id)) |entry| {
                var result = entry.value;
                if (try self.takeError(&result)) return error.CdpError;
                return result;
            }
            const left = deadline - io_mod.monotonicMilliTimestamp();
            if (left <= 0) {
                self.ignored.put(self.alloc, id, {}) catch {};
                return error.Timeout;
            }
            try self.pump(left);
        }
    }

    /// Answers whether `result` is a protocol error, keeping its message.
    fn takeError(self: *Connection, result: *Result) Error!bool {
        const root = result.parsed.value;
        const err_value = if (root == .object) root.object.get("error") else null;
        if (err_value == null) return false;
        const message = if (err_value.? == .object) stringField(err_value.?, "message") orelse "protocol error" else "protocol error";
        if (self.last_error) |old| self.alloc.free(old);
        self.last_error = self.alloc.dupe(u8, message) catch null;
        result.deinit(self.alloc);
        return true;
    }

    /// Reads and routes at most one message, waiting up to `timeout_ms`.
    pub fn pump(self: *Connection, timeout_ms: i64) Error!void {
        if (self.closed) return error.ConnectionClosed;
        const raw = (self.transport.receive_fn(self.transport.ctx, self.alloc, timeout_ms, self.cancel) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.closed = true;
                return error.ConnectionClosed;
            },
        }) orelse return;
        try self.route(raw);
    }

    /// Takes ownership of one received message and files it.
    pub fn route(self: *Connection, raw: []u8) Error!void {
        var keep_raw = false;
        defer if (!keep_raw) self.alloc.free(raw);
        var parsed = std.json.parseFromSlice(Value, self.alloc, raw, .{}) catch return;
        var keep_parsed = false;
        defer if (!keep_parsed) parsed.deinit();
        if (parsed.value != .object) return;
        if (parsed.value.object.get("id")) |id_value| {
            if (id_value != .integer or id_value.integer < 0) return;
            const id: u64 = @intCast(id_value.integer);
            if (self.ignored.remove(id)) return;
            try self.early.put(self.alloc, id, .{ .parsed = parsed, .raw = raw });
            keep_raw = true;
            keep_parsed = true;
            return;
        }
        if (parsed.value.object.get("method") == null) return;
        var event: Event = .{ .raw = raw, .parsed = parsed };
        keep_raw = true;
        keep_parsed = true;
        if (self.on_event) |hook| {
            if (hook.func(hook.ctx, self, &event)) {
                event.deinit(self.alloc);
                return;
            }
        }
        if (self.events.items.len >= max_queued_events) {
            var oldest = self.events.orderedRemove(0);
            oldest.deinit(self.alloc);
        }
        self.events.append(self.alloc, event) catch |err| {
            event.deinit(self.alloc);
            return err;
        };
    }

    /// Removes and returns the first queued event matching `method` (and
    /// `session_id` when given), waiting up to `timeout_ms` for one.
    pub fn waitEvent(self: *Connection, session_id: ?[]const u8, method: []const u8, timeout_ms: i64) Error!?Event {
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        while (true) {
            if (self.takeEvent(session_id, method)) |event| return event;
            const left = deadline - io_mod.monotonicMilliTimestamp();
            if (left <= 0) return null;
            try self.pump(left);
        }
    }

    pub fn takeEvent(self: *Connection, session_id: ?[]const u8, method: []const u8) ?Event {
        for (self.events.items, 0..) |*event, index| {
            if (!std.mem.eql(u8, event.method(), method)) continue;
            if (session_id) |sid| {
                const got = event.sessionId() orelse continue;
                if (!std.mem.eql(u8, got, sid)) continue;
            }
            return self.events.orderedRemove(index);
        }
        return null;
    }

    /// Drops queued events of `session_id` (all sessions when null).
    pub fn dropEvents(self: *Connection, session_id: ?[]const u8) void {
        var index: usize = 0;
        while (index < self.events.items.len) {
            const event = &self.events.items[index];
            const matches = if (session_id) |sid| if (event.sessionId()) |got| std.mem.eql(u8, got, sid) else false else true;
            if (matches) {
                var removed = self.events.orderedRemove(index);
                removed.deinit(self.alloc);
            } else index += 1;
        }
    }

    /// Reads whatever has already arrived without waiting.
    pub fn drain(self: *Connection) Error!void {
        var rounds: usize = 0;
        while (rounds < 256) : (rounds += 1) {
            const before = self.events.items.len + self.early.count();
            try self.pump(0);
            if (self.events.items.len + self.early.count() == before) return;
        }
    }

    pub fn lastError(self: *const Connection) []const u8 {
        return self.last_error orelse "unknown protocol error";
    }
};

pub fn stringField(value: Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

pub fn intField(value: Value, name: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn floatField(value: Value, name: []const u8) ?f64 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

/// Writes `text` as a JSON string. The caller owns the result.
pub fn jsonString(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(text, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ---- tests -------------------------------------------------------------------

const Script = struct {
    alloc: Allocator,
    sent: std.ArrayList([]u8) = .empty,
    inbox: std.ArrayList([]const u8) = .empty,

    fn transport(self: *Script) Transport {
        return .{ .ctx = self, .send_fn = send, .receive_fn = receive };
    }

    fn send(ctx: *anyopaque, alloc: Allocator, bytes: []const u8) anyerror!void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        try self.sent.append(self.alloc, try alloc.dupe(u8, bytes));
    }

    fn receive(ctx: *anyopaque, alloc: Allocator, _: i64, _: ?*std.atomic.Value(bool)) anyerror!?[]u8 {
        const self: *Script = @ptrCast(@alignCast(ctx));
        if (self.inbox.items.len == 0) return null;
        const next = self.inbox.orderedRemove(0);
        return try alloc.dupe(u8, next);
    }

    fn deinit(self: *Script) void {
        for (self.sent.items) |bytes| self.alloc.free(bytes);
        self.sent.deinit(self.alloc);
        self.inbox.deinit(self.alloc);
    }
};

test "cdp commands carry ids and session ids, and answers route by id past events" {
    const alloc = std.testing.allocator;
    var script: Script = .{ .alloc = alloc };
    defer script.deinit();
    var conn = Connection.init(alloc, script.transport());
    defer conn.deinit();

    try script.inbox.append(alloc, "{\"method\":\"Page.loadEventFired\",\"params\":{},\"sessionId\":\"S1\"}");
    try script.inbox.append(alloc, "{\"id\":2,\"result\":{\"late\":true}}");
    try script.inbox.append(alloc, "{\"id\":1,\"result\":{\"value\":42}}");
    var result = try conn.call("S1", "Runtime.evaluate", "{\"expression\":\"6*7\"}", 1000);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 42), intField(result.value(), "value").?);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"6*7\"},\"sessionId\":\"S1\"}",
        script.sent.items[0],
    );
    // The early answer for id 2 waits for its caller.
    try std.testing.expect(conn.early.contains(2));
    var event = conn.takeEvent("S1", "Page.loadEventFired").?;
    event.deinit(alloc);
    try std.testing.expect(conn.takeEvent(null, "Page.loadEventFired") == null);
}

test "cdp protocol errors keep their message and ignored answers are dropped" {
    const alloc = std.testing.allocator;
    var script: Script = .{ .alloc = alloc };
    defer script.deinit();
    var conn = Connection.init(alloc, script.transport());
    defer conn.deinit();
    try conn.sendIgnored(null, "Page.handleJavaScriptDialog", "{\"accept\":true}");
    try script.inbox.append(alloc, "{\"id\":1,\"result\":{}}");
    try script.inbox.append(alloc, "{\"id\":2,\"error\":{\"code\":-32000,\"message\":\"No node with given id\"}}");
    try std.testing.expectError(error.CdpError, conn.call(null, "DOM.resolveNode", "{}", 1000));
    try std.testing.expectEqualStrings("No node with given id", conn.lastError());
    try std.testing.expectEqual(@as(u32, 0), conn.early.count());
}

test "cdp waits time out and event hooks consume events" {
    const alloc = std.testing.allocator;
    var script: Script = .{ .alloc = alloc };
    defer script.deinit();
    var conn = Connection.init(alloc, script.transport());
    defer conn.deinit();
    const Hook = struct {
        seen: usize = 0,
        fn func(ctx: *anyopaque, _: *Connection, event: *const Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!std.mem.eql(u8, event.method(), "Page.javascriptDialogOpening")) return false;
            self.seen += 1;
            return true;
        }
    };
    var hook: Hook = .{};
    conn.on_event = .{ .ctx = &hook, .func = Hook.func };
    try script.inbox.append(alloc, "{\"method\":\"Page.javascriptDialogOpening\",\"params\":{\"message\":\"hi\"}}");
    try std.testing.expectError(error.Timeout, conn.call(null, "Page.navigate", "{}", 5));
    try std.testing.expectEqual(@as(usize, 1), hook.seen);
    try std.testing.expectEqual(@as(usize, 0), conn.events.items.len);
}

//! One browser the browser tool drives for a session node (D195 to D197):
//! its backend (a browser fx launched, or an existing CDP endpoint), the CDP
//! connection, the named tabs, and the hidden controller page that runs the
//! model's scripts.
//!
//! Page lifecycle events never wait in the connection's queue: a hook counts
//! navigations and loads per tab, answers dialogs, and files the controller's
//! binding calls and console lines, so any wait sees them.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const cdp = @import("cdp.zig");
const launch = @import("launch.zig");
const websocket = @import("websocket.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_tab_name = "main";
pub const default_viewport: Viewport = .{ .width = 1280, .height = 800 };
/// How long one protocol command may take before the browser counts as stuck.
pub const command_timeout_ms: i64 = 15_000;

pub const Viewport = struct { width: u32, height: u32, scale: f64 = 1 };

pub const DialogPolicy = enum { accept, dismiss };

pub const Tab = struct {
    name: []u8,
    target_id: []u8,
    session_id: []u8,
    /// fx created this tab and closes it; a borrowed tab is only detached.
    owned: bool,
    dialogs: DialogPolicy = .accept,
    /// Main-frame navigations committed, loads finished, DOM ready, loads started.
    navigations: u64 = 0,
    loads: u64 = 0,
    dom_ready: u64 = 0,
    starts: u64 = 0,
    /// Backend DOM node ids of the last observation; id N is index N-1.
    elements: std.ArrayList(i64) = .empty,

    fn deinit(self: *Tab, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.target_id);
        alloc.free(self.session_id);
        self.elements.deinit(alloc);
    }
};

pub const Backend = union(enum) {
    launched: launch.Process,
    /// An endpoint someone else runs; fx never stops it.
    connected: []u8,
};

pub const Controller = struct {
    target_id: []u8,
    session_id: []u8,
};

pub const Browser = struct {
    alloc: Allocator,
    backend: Backend,
    client: *websocket.Client,
    conn: cdp.Connection,
    /// "headless Chrome for Testing" or "connected http://127.0.0.1:9222".
    label: []u8,
    tabs: std.ArrayList(*Tab) = .empty,
    controller: ?Controller = null,
    /// Binding payloads from the controller, oldest first, owned.
    bindings: std.ArrayList([]u8) = .empty,
    /// Console lines, dialog notices and page errors for the current run, owned.
    notes: std.ArrayList([]u8) = .empty,
    /// Whether the controller should file console lines (only while a run is active).
    collecting: bool = false,

    /// Connects to `ws_url`. On failure the backend is left to the caller.
    pub fn connect(alloc: Allocator, ws_url: []const u8, backend: Backend, label: []const u8) !*Browser {
        const client = try alloc.create(websocket.Client);
        errdefer alloc.destroy(client);
        client.* = try websocket.Client.connect(alloc, ws_url);
        const self = try alloc.create(Browser);
        self.* = .{
            .alloc = alloc,
            .backend = backend,
            .client = client,
            .conn = cdp.Connection.init(alloc, cdp.websocketTransport(client)),
            .label = alloc.dupe(u8, label) catch |err| {
                alloc.destroy(self);
                client.close(alloc);
                return err;
            },
        };
        self.conn.on_event = .{ .ctx = self, .func = onEvent };
        return self;
    }

    /// Closes the tabs fx opened, the controller, the connection, and a
    /// launched browser's process. Borrowed tabs stay open.
    pub fn close(self: *Browser) void {
        const alloc = self.alloc;
        self.conn.cancel = null;
        if (!self.conn.closed) {
            for (self.tabs.items) |tab| {
                if (tab.owned) self.closeTarget(tab.target_id);
            }
            self.dropController();
            if (self.backend == .launched) {
                // A graceful close lets the browser flush its profile first.
                self.conn.sendIgnored(null, "Browser.close", "") catch {};
                _ = self.conn.waitEvent(null, "Never.happens", 300) catch {};
            }
        }
        for (self.tabs.items) |tab| {
            tab.deinit(alloc);
            alloc.destroy(tab);
        }
        self.tabs.deinit(alloc);
        self.clearBindings();
        self.bindings.deinit(alloc);
        self.clearNotes();
        self.notes.deinit(alloc);
        self.conn.deinit();
        alloc.destroy(self.client);
        switch (self.backend) {
            .launched => |*process| process.stop(alloc),
            .connected => |url| alloc.free(url),
        }
        alloc.free(self.label);
        alloc.destroy(self);
    }

    pub fn alive(self: *const Browser) bool {
        return !self.conn.closed;
    }

    pub fn findTab(self: *Browser, name: []const u8) ?*Tab {
        for (self.tabs.items) |tab| if (std.mem.eql(u8, tab.name, name)) return tab;
        return null;
    }

    fn tabForSession(self: *Browser, session_id: []const u8) ?*Tab {
        for (self.tabs.items) |tab| if (std.mem.eql(u8, tab.session_id, session_id)) return tab;
        return null;
    }

    /// Sends a command and returns its result, mapping protocol errors to
    /// `error.CdpError` with `conn.lastError()` holding the message.
    pub fn call(self: *Browser, session_id: ?[]const u8, method: []const u8, params: anytype) !cdp.Result {
        const json = try paramsJson(self.alloc, params);
        defer self.alloc.free(json);
        return self.conn.call(session_id, method, json, command_timeout_ms);
    }

    pub fn callIgnored(self: *Browser, session_id: ?[]const u8, method: []const u8, params: anytype) !void {
        const json = try paramsJson(self.alloc, params);
        defer self.alloc.free(json);
        try self.conn.sendIgnored(session_id, method, json);
    }

    fn closeTarget(self: *Browser, target_id: []const u8) void {
        var result = self.call(null, "Target.closeTarget", .{ .targetId = target_id }) catch return;
        result.deinit(self.alloc);
    }

    /// Creates a page target and attaches a flat session to it.
    fn createPage(self: *Browser, hidden: bool) !struct { target_id: []u8, session_id: []u8 } {
        var created = if (hidden)
            self.call(null, "Target.createTarget", .{ .url = "about:blank", .background = true, .hidden = true }) catch
                try self.call(null, "Target.createTarget", .{ .url = "about:blank", .background = true })
        else
            try self.call(null, "Target.createTarget", .{ .url = "about:blank" });
        defer created.deinit(self.alloc);
        const target_id = try self.alloc.dupe(u8, cdp.stringField(created.value(), "targetId") orelse return error.InvalidResponse);
        errdefer self.alloc.free(target_id);
        var attached = try self.call(null, "Target.attachToTarget", .{ .targetId = target_id, .flatten = true });
        defer attached.deinit(self.alloc);
        const session_id = try self.alloc.dupe(u8, cdp.stringField(attached.value(), "sessionId") orelse return error.InvalidResponse);
        return .{ .target_id = target_id, .session_id = session_id };
    }

    /// Opens a new owned tab named `name` on about:blank.
    pub fn openTab(self: *Browser, name: []const u8, viewport: ?Viewport, dialogs: DialogPolicy) !*Tab {
        const page = try self.createPage(false);
        const tab = try self.alloc.create(Tab);
        tab.* = .{
            .name = self.alloc.dupe(u8, name) catch |err| {
                self.alloc.free(page.target_id);
                self.alloc.free(page.session_id);
                self.alloc.destroy(tab);
                return err;
            },
            .target_id = page.target_id,
            .session_id = page.session_id,
            .owned = true,
            .dialogs = dialogs,
        };
        self.tabs.append(self.alloc, tab) catch |err| {
            tab.deinit(self.alloc);
            self.alloc.destroy(tab);
            return err;
        };
        errdefer self.releaseTab(tab);
        var enabled = try self.call(tab.session_id, "Page.enable", .{});
        enabled.deinit(self.alloc);
        // The headless default is a small window; a launched browser gets a
        // desktop viewport, a borrowed one keeps its own unless asked.
        if (viewport != null or self.backend == .launched) try self.setViewport(tab, viewport orelse default_viewport);
        return tab;
    }

    pub fn setViewport(self: *Browser, tab: *Tab, viewport: Viewport) !void {
        var result = try self.call(tab.session_id, "Emulation.setDeviceMetricsOverride", .{
            .width = viewport.width,
            .height = viewport.height,
            .deviceScaleFactor = viewport.scale,
            .mobile = false,
        });
        result.deinit(self.alloc);
    }

    /// Closes an owned tab (detaches a borrowed one) and forgets it.
    pub fn releaseTab(self: *Browser, tab: *Tab) void {
        if (tab.owned) self.closeTarget(tab.target_id) else {
            var result = self.call(null, "Target.detachFromTarget", .{ .sessionId = tab.session_id }) catch null;
            if (result) |*r| r.deinit(self.alloc);
        }
        for (self.tabs.items, 0..) |item, index| {
            if (item == tab) {
                _ = self.tabs.orderedRemove(index);
                break;
            }
        }
        tab.deinit(self.alloc);
        self.alloc.destroy(tab);
    }

    /// Navigates `tab` and waits for its load (or DOM ready) event.
    pub fn navigate(self: *Browser, tab: *Tab, url: []const u8, wait_dom_only: bool, timeout_ms: i64) !void {
        tab.elements.clearRetainingCapacity();
        const loads = tab.loads;
        const ready = tab.dom_ready;
        var result = try self.call(tab.session_id, "Page.navigate", .{ .url = url });
        defer result.deinit(self.alloc);
        if (cdp.stringField(result.value(), "errorText")) |text| {
            self.setError(text);
            return error.NavigationFailed;
        }
        // A same-document navigation (a #fragment) fires no load.
        if (cdp.stringField(result.value(), "loaderId") == null) return;
        try self.waitCounter(if (wait_dom_only) &tab.dom_ready else &tab.loads, if (wait_dom_only) ready else loads, timeout_ms);
    }

    /// Pumps events until `counter` moves past `start`.
    pub fn waitCounter(self: *Browser, counter: *const u64, start: u64, timeout_ms: i64) !void {
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        while (counter.* == start) {
            const left = deadline - io_mod.monotonicMilliTimestamp();
            if (left <= 0) return error.Timeout;
            try self.conn.pump(@min(left, 100));
        }
    }

    /// After an input action: if the page started loading within a short
    /// grace period, waits for that load to finish.
    pub fn settleAfterAction(self: *Browser, tab: *Tab, starts_before: u64, timeout_ms: i64) !void {
        const grace_deadline = io_mod.monotonicMilliTimestamp() + 120;
        while (tab.starts == starts_before) {
            const left = grace_deadline - io_mod.monotonicMilliTimestamp();
            if (left <= 0) return;
            try self.conn.pump(left);
        }
        const loads = tab.loads;
        // The load may already be counted when the start arrived late.
        self.waitCounter(&tab.loads, loads, timeout_ms) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };
    }

    // ---- controller ---------------------------------------------------------

    /// The hidden page that runs scripts, created on first use with the
    /// `prelude` evaluated in it.
    pub fn ensureController(self: *Browser, prelude: []const u8) !Controller {
        if (self.controller) |controller| return controller;
        const page = try self.createPage(true);
        self.controller = .{ .target_id = page.target_id, .session_id = page.session_id };
        errdefer self.dropController();
        const sid = page.session_id;
        var enabled = try self.call(sid, "Runtime.enable", .{});
        enabled.deinit(self.alloc);
        var bound = try self.call(sid, "Runtime.addBinding", .{ .name = "__fxCall" });
        bound.deinit(self.alloc);
        var installed = try self.call(sid, "Runtime.evaluate", .{ .expression = prelude, .returnByValue = true });
        defer installed.deinit(self.alloc);
        if (installed.value() == .object and installed.value().object.get("exceptionDetails") != null) return error.ControllerFailed;
        return self.controller.?;
    }

    /// Closes the controller, which also ends any script it was running.
    pub fn dropController(self: *Browser) void {
        const controller = self.controller orelse return;
        self.controller = null;
        self.closeTarget(controller.target_id);
        self.conn.dropEvents(controller.session_id);
        self.alloc.free(controller.target_id);
        self.alloc.free(controller.session_id);
        self.clearBindings();
    }

    pub fn clearBindings(self: *Browser) void {
        for (self.bindings.items) |payload| self.alloc.free(payload);
        self.bindings.clearRetainingCapacity();
    }

    pub fn clearNotes(self: *Browser) void {
        for (self.notes.items) |item| self.alloc.free(item);
        self.notes.clearRetainingCapacity();
    }

    pub fn note(self: *Browser, comptime fmt: []const u8, args: anytype) void {
        if (self.notes.items.len >= 200) return;
        const text = self.alloc.print(fmt, args) catch return;
        self.notes.append(self.alloc, text) catch self.alloc.free(text);
    }

    pub fn setError(self: *Browser, message: []const u8) void {
        if (self.conn.last_error) |old| self.alloc.free(old);
        self.conn.last_error = self.alloc.dupe(u8, message) catch null;
    }
};

/// Serializes a params struct, leaving out null optionals. The caller owns it.
pub fn paramsJson(alloc: Allocator, params: anytype) ![]u8 {
    // An empty anonymous struct is a tuple, which would print as [].
    if (comptime @typeInfo(@TypeOf(params)).@"struct".field_names.len == 0) return alloc.dupe(u8, "{}");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(params, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn onEvent(ctx: *anyopaque, conn: *cdp.Connection, event: *const cdp.Event) bool {
    const self: *Browser = @ptrCast(@alignCast(ctx));
    _ = conn;
    const method = event.method();
    const session_id = event.sessionId() orelse return false;
    const params = event.params() orelse return false;
    if (self.controller) |controller| if (std.mem.eql(u8, session_id, controller.session_id)) {
        if (std.mem.eql(u8, method, "Runtime.bindingCalled")) {
            const payload = cdp.stringField(params, "payload") orelse return true;
            const owned = self.alloc.dupe(u8, payload) catch return true;
            self.bindings.append(self.alloc, owned) catch self.alloc.free(owned);
            return true;
        }
        if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
            if (self.collecting) noteConsole(self, params);
            return true;
        }
        // Context and other runtime chatter from the controller is not needed.
        return true;
    };
    const tab = self.tabForSession(session_id) orelse return false;
    if (std.mem.eql(u8, method, "Page.frameNavigated")) {
        const frame = if (params == .object) params.object.get("frame") else null;
        if (frame) |f| if (f == .object and f.object.get("parentId") == null) {
            tab.navigations += 1;
            tab.elements.clearRetainingCapacity();
        };
        return true;
    }
    if (std.mem.eql(u8, method, "Page.frameStartedLoading")) {
        if (cdp.stringField(params, "frameId")) |frame_id| if (std.mem.eql(u8, frame_id, tab.target_id)) {
            tab.starts += 1;
        };
        return true;
    }
    if (std.mem.eql(u8, method, "Page.loadEventFired")) {
        tab.loads += 1;
        return true;
    }
    if (std.mem.eql(u8, method, "Page.domContentEventFired")) {
        tab.dom_ready += 1;
        return true;
    }
    if (std.mem.eql(u8, method, "Page.javascriptDialogOpening")) {
        const kind = cdp.stringField(params, "type") orelse "alert";
        const message = cdp.stringField(params, "message") orelse "";
        const accept = tab.dialogs == .accept;
        self.note("[{s} dialog {s}: {s}]", .{ kind, if (accept) "accepted" else "dismissed", message });
        self.callIgnored(tab.session_id, "Page.handleJavaScriptDialog", .{ .accept = accept }) catch {};
        return true;
    }
    if (std.mem.startsWith(u8, method, "Page.")) return true;
    return false;
}

fn noteConsoleArg(writer: *std.Io.Writer, arg: Value) !void {
    if (arg != .object) return;
    if (arg.object.get("value")) |value| switch (value) {
        .string => |text| return writer.writeAll(text),
        else => return std.json.Stringify.value(value, .{}, writer),
    };
    if (cdp.stringField(arg, "description")) |text| return writer.writeAll(text);
    if (cdp.stringField(arg, "type")) |text| return writer.writeAll(text);
}

fn noteConsoleParams(self: *Browser, params: Value) !void {
    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    const args = if (params == .object) params.object.get("args") else null;
    if (args) |list| if (list == .array) for (list.array.items, 0..) |arg, index| {
        if (index > 0) try out.writer.writeByte(' ');
        try noteConsoleArg(&out.writer, arg);
    };
    self.note("{s}", .{out.written()});
}

fn noteConsole(self: *Browser, params: Value) void {
    noteConsoleParams(self, params) catch {};
}

test "browser params leave out null optionals" {
    const alloc = std.testing.allocator;
    const json = try paramsJson(alloc, .{ .url = "about:blank", .hidden = @as(?bool, null), .background = true });
    defer alloc.free(json);
    try std.testing.expectEqualStrings("{\"url\":\"about:blank\",\"background\":true}", json);
}

//! Attached terminal client transport. One kept-open supervisor connection
//! carries every request and the updates the supervisor pushes; its I/O
//! thread keeps socket work off the paint thread. Closing this state releases
//! only client resources, never the supervisor's sessions. Replies and pushes
//! go to `remote_view.zig`; requests come from `remote_backend.zig`, the
//! detached session backend.
const std = @import("std");
const client_mod = @import("../supervisor/client.zig");
const client_protocol = @import("../supervisor/protocol.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const remote_view = @import("remote_view.zig");
const remote_backend = @import("remote_backend.zig");
const Allocator = std.mem.Allocator;
const SnapshotView = remote_view.SnapshotView;
/// What a reply answers. `poll` is a pushed session update, and `resync` the
/// resubscribe after a reconnect.
pub const Kind = enum { startup, startup_last, startup_remembered, attach, poll, resync, list, children, history, submit, cancel, rpc, heartbeat, kernel, rename, config, command, unwatch };
/// A request waiting to be sent, or sent and waiting for its reply.
const Request = struct {
    kind: Kind,
    json: []u8,
    generation: u64,
    id: u64 = 0,
};
fn dropRequests(alloc: Allocator, list: *std.ArrayList(Request)) void {
    for (list.items) |request| alloc.free(request.json);
    list.clearRetainingCapacity();
}
const Link = enum {
    /// No connection yet, or the last one dropped.
    connecting,
    /// Reconnected; the resubscribe has not answered, so queued requests
    /// wait in case the supervisor restarted.
    resyncing,
    ready,
    /// The supervisor stopped on purpose; nothing reconnects.
    stopped,
};
pub const State = struct {
    allocator: ?Allocator = null,
    connection: ?*client_mod.Connection = null,
    link: Link = .connecting,
    connected_once: bool = false,
    /// Requests not sent yet. They go out when the link is ready.
    queue: std.ArrayList(Request) = .empty,
    /// Sent requests awaiting their replies.
    sent: std.ArrayList(Request) = .empty,
    /// What this connection asked the supervisor to push.
    watching: struct { list: bool = false, children: bool = false, child: bool = false } = .{},
    /// The attached root session.
    current_id: []u8 = &.{},
    /// The node below the root that the composer shows, empty at the root.
    /// Any node other than the root is a read-only transcript.
    child_id: []u8 = &.{},
    /// The nodes between the root and `child_id`, nearest the root first;
    /// Left walks back up through them.
    child_ancestors: std.ArrayList([]u8) = .empty,
    generation: u64 = 1,
    sequence: u64 = 0,
    child_history_count: ?usize = null,
    child_work_id: []u8 = &.{},
    child_sequence: u64 = 0,
    child_live_active: bool = false,
    child_prompt: []u8 = &.{},
    child_status: [64]u8 = undefined,
    child_status_len: usize = 0,
    native_turn_offset: u64 = 1,
    native_source_turn_id: ?u64 = null,
    model: []u8 = &.{},
    cwd: []u8 = &.{},
    workspace_label: []u8 = &.{},
    incarnation: []u8 = &.{},
    reconnect_notice: bool = false,
    permission_mode: types.PermissionMode = .ask,
    pending_permission_id: ?i64 = null,
    permission_response_queued: bool = false,
    submitted_text: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.connection) |connection| connection.stop();
        dropRequests(alloc, &self.queue);
        self.queue.deinit(alloc);
        dropRequests(alloc, &self.sent);
        self.sent.deinit(alloc);
        if (self.current_id.len > 0) alloc.free(self.current_id);
        if (self.child_id.len > 0) alloc.free(self.child_id);
        for (self.child_ancestors.items) |id| alloc.free(id);
        self.child_ancestors.deinit(alloc);
        if (self.child_prompt.len > 0) alloc.free(self.child_prompt);
        if (self.child_work_id.len > 0) alloc.free(self.child_work_id);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.cwd.len > 0) alloc.free(self.cwd);
        if (self.workspace_label.len > 0) alloc.free(self.workspace_label);
        if (self.incarnation.len > 0) alloc.free(self.incarnation);
        for (self.submitted_text.items) |text| alloc.free(text);
        self.submitted_text.deinit(alloc);
        self.* = .{};
    }

    /// The node the composer shows: the viewed child, or the root.
    pub fn viewedNodeId(self: *const State) []const u8 {
        return if (self.child_id.len > 0) self.child_id else self.current_id;
    }

    pub fn clearChildTracking(self: *State, alloc: Allocator) void {
        if (self.child_work_id.len > 0) alloc.free(self.child_work_id);
        self.child_work_id = &.{};
        if (self.child_prompt.len > 0) alloc.free(self.child_prompt);
        self.child_prompt = &.{};
        self.child_history_count = null;
        self.child_sequence = 0;
        self.child_live_active = false;
        self.child_status_len = 0;
    }

    /// Whether a prompt for the current view waits to be sent or answered.
    pub fn submissionQueued(self: *const State) bool {
        return self.inFlight(.submit);
    }

    /// Drops every request not yet sent.
    pub fn dropQueued(self: *State) void {
        const alloc = self.allocator orelse return;
        dropRequests(alloc, &self.queue);
    }

    pub fn enqueue(self: *State, kind: Kind, request: client_protocol.Request) !void {
        const alloc = self.allocator orelse return error.RemoteNotInitialized;
        if (self.queue.items.len >= 32) return error.RemoteQueueFull;
        const json = try client_protocol.encode(alloc, request);
        errdefer alloc.free(json);
        try self.queue.append(alloc, .{ .kind = kind, .json = json, .generation = self.generation });
    }

    /// Sends one request now, ahead of the queue. A connection that just
    /// dropped drops it too; its `disconnected` follows.
    fn sendNow(self: *State, kind: Kind, request: client_protocol.Request) !void {
        const alloc = self.allocator orelse return error.RemoteNotInitialized;
        const json = try client_protocol.encode(alloc, request);
        self.transmit(.{ .kind = kind, .json = json, .generation = self.generation }) catch |err| {
            alloc.free(json);
            if (err == error.SupervisorDisconnected) return;
            return err;
        };
    }

    /// Sends `request` and tracks it until its reply. Takes ownership of
    /// `request.json` only on success.
    fn transmit(self: *State, request: Request) !void {
        const alloc = self.allocator orelse return error.RemoteNotInitialized;
        try self.sent.ensureUnusedCapacity(alloc, 1);
        var sent = request;
        sent.id = try self.connection.?.send(request.json);
        self.sent.appendAssumeCapacity(sent);
    }

    /// Sends the queue in order while the link is ready. What a dropped
    /// connection could not take stays queued.
    fn flush(self: *State) !void {
        while (self.link == .ready and self.queue.items.len > 0) {
            self.transmit(self.queue.items[0]) catch |err| {
                if (err == error.SupervisorDisconnected) return;
                return err;
            };
            _ = self.queue.orderedRemove(0);
        }
    }

    /// Removes and returns the sent request `id` answers. Caller frees its json.
    fn answered(self: *State, id: u64) ?Request {
        for (self.sent.items, 0..) |request, index| if (request.id == id) return self.sent.orderedRemove(index);
        return null;
    }

    /// Whether a request of `kind` for the current view is queued or sent.
    fn inFlight(self: *const State, kind: Kind) bool {
        for ([_][]const Request{ self.queue.items, self.sent.items }) |list| {
            for (list) |request| if (request.kind == kind and request.generation == self.generation) return true;
        }
        return false;
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        const View = remote_view.Runtime(App);
        const Backend = remote_backend.Runtime(App);

        pub fn init(app: *App, executable: []const u8, resume_id: ?[]const u8) !void {
            const remote = &app.remote;
            if (remote.connection != null) return;
            remote.connection = try client_mod.Connection.start(app.alloc, executable);
            remote.allocator = app.alloc;
            errdefer remote.deinit(app.alloc);
            if (app.requested_resume) |requested| {
                var target = requested;
                app.requested_resume = null;
                defer target.deinit(app.alloc);
                switch (target) {
                    .pick => {
                        app.input_runtime.session_browser.open(.sessions);
                        try refreshBrowser(app);
                    },
                    .last => try remote.enqueue(.startup_last, .{ .list = .{} }),
                    .remembered => try remote.enqueue(.startup_remembered, .{ .list = .{} }),
                    .id => |id| try remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root, .@"resume" = id } }),
                }
            } else {
                try remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root, .@"resume" = resume_id } });
            }
        }

        /// Loads the browser's rows and watches them: the supervisor pushes
        /// each change until the browser closes or changes scope.
        pub fn refreshBrowser(app: *App) !void {
            if (app.input_runtime.session_browser.scope == .sessions) {
                try app.remote.enqueue(.list, .{ .list = .{ .watch = true } });
                app.remote.watching.list = true;
            } else if (app.remote.current_id.len > 0) {
                try app.remote.enqueue(.children, .{ .children = .{ .session_id = app.remote.current_id, .watch = true } });
                app.remote.watching.children = true;
            } else {
                try app.input_runtime.session_browser.replaceRows(app.alloc, &.{});
            }
        }

        pub fn poll(app: *App) !void {
            const remote = &app.remote;
            const connection = remote.connection orelse return;
            var incoming = connection.take();
            defer {
                for (incoming.items) |*item| item.deinit();
                incoming.deinit(app.alloc);
            }
            for (incoming.items) |item| switch (item) {
                .connected => try connected(app),
                .disconnected => |failure| try disconnected(app, failure),
                .stopped => {
                    remote.link = .stopped;
                    dropRequests(app.alloc, &remote.sent);
                    remote.permission_response_queued = false;
                    try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = "Supervisor stopped. Relaunch proto-fx to reconnect." }, true);
                },
                .frame => |parsed| {
                    const frame = parsed.value;
                    if (frame.id) |id| {
                        const request = remote.answered(id) orelse continue;
                        defer app.alloc.free(request.json);
                        if (request.kind == .resync) remote.link = .ready;
                        if (request.generation != remote.generation) continue;
                        if (request.kind == .rpc) remote.permission_response_queued = false;
                        try applyResponse(app, request.kind, frame.response orelse continue);
                    } else if (frame.update) |topic| {
                        try applyUpdate(app, topic, frame.body orelse continue);
                    }
                },
            };
            try unwatchClosedViews(app);
            try remote.flush();
        }

        /// A connection opened. After an outage, resubscribe from the last
        /// event seen before sending anything queued: if the supervisor
        /// restarted, the snapshot says so and queued requests are dropped.
        fn connected(app: *App) !void {
            const remote = &app.remote;
            if (!remote.connected_once) {
                remote.connected_once = true;
                remote.link = .ready;
                return;
            }
            // The supervisor forgot this connection's watches.
            remote.watching = .{};
            if (remote.current_id.len == 0) {
                remote.link = .ready;
                return;
            }
            remote.link = .resyncing;
            try remote.sendNow(.resync, .{ .attach = .{ .session_id = remote.current_id, .after_sequence = remote.sequence, .include_history = false } });
            if (app.input_runtime.session_browser.active) try refreshBrowser(app);
            if (remote.child_id.len > 0) {
                remote.child_history_count = null;
                try refreshChild(app);
            }
        }

        fn disconnected(app: *App, failure: anyerror) !void {
            const remote = &app.remote;
            remote.link = .connecting;
            // Nothing sent before the outage will be answered.
            dropRequests(app.alloc, &remote.sent);
            remote.permission_response_queued = false;
            if (app.input_runtime.session_browser.active) app.input_runtime.session_browser.fail(@errorName(failure));
            if (!remote.connected_once) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = @errorName(failure) }, true);
                return;
            }
            const body = try app.alloc.print("Lost the connection to the supervisor ({s}). Reconnecting.", .{@errorName(failure)});
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = body }, true);
        }

        /// Applies one pushed update. A session update waits for the reply
        /// that starts its watch, which carries the baseline.
        fn applyUpdate(app: *App, topic: client_protocol.Topic, body: std.json.Value) !void {
            const remote = &app.remote;
            switch (topic) {
                .session => {
                    if (remote.link != .ready or remote.inFlight(.startup) or remote.inFlight(.attach)) return;
                    if (!std.mem.eql(u8, string(body, "session_id") orelse "", remote.current_id)) return;
                    try applyResponse(app, .poll, body);
                },
                .list => try applyResponse(app, .list, body),
                .children => try applyResponse(app, .children, body),
                .child => try applyResponse(app, .history, body),
                .stopped => {},
            }
        }

        /// Stops the pushes for views the user closed.
        fn unwatchClosedViews(app: *App) !void {
            const remote = &app.remote;
            if (remote.link != .ready) return;
            const browser = &app.input_runtime.session_browser;
            if (remote.watching.list and !(browser.active and browser.scope == .sessions)) {
                try remote.enqueue(.unwatch, .{ .unwatch = .{ .topic = .list } });
                remote.watching.list = false;
            }
            if (remote.watching.children and !(browser.active and browser.scope == .subagents)) {
                try remote.enqueue(.unwatch, .{ .unwatch = .{ .topic = .children, .session_id = remote.current_id } });
                remote.watching.children = false;
            }
            if (remote.watching.child and remote.child_id.len == 0) {
                try remote.enqueue(.unwatch, .{ .unwatch = .{ .topic = .child, .session_id = remote.current_id } });
                remote.watching.child = false;
            }
        }

        /// Loads the child transcript from the cursor and watches it.
        pub fn refreshChild(app: *App) !void {
            const remote = &app.remote;
            if (remote.inFlight(.history)) return;
            try remote.enqueue(.history, .{ .history = .{
                .session_id = remote.current_id,
                .child_id = remote.child_id,
                .work_id = if (remote.child_work_id.len > 0) remote.child_work_id else null,
                .after_live_sequence = remote.child_sequence,
                .live_active = remote.child_live_active,
                .include_history = remote.child_history_count == null,
                .watch = true,
            } });
            remote.watching.child = true;
        }

        fn decode(comptime T: type, app: *App, value: std.json.Value) !std.json.Parsed(T) {
            return std.json.parseFromValue(T, app.alloc, value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        }

        fn applyResponse(app: *App, kind: Kind, value: std.json.Value) !void {
            var outcome = try decode(client_protocol.Outcome, app, value);
            defer outcome.deinit();
            if (!outcome.value.ok) {
                const message = outcome.value.@"error" orelse "The local session request failed";
                if (kind == .list or kind == .children) app.input_runtime.session_browser.fail(message);
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = message }, true);
                return;
            }
            switch (kind) {
                .startup, .attach, .poll, .resync => {
                    var snapshot = try decode(SnapshotView, app, value);
                    defer snapshot.deinit();
                    try View.applySnapshot(app, snapshot.value);
                },
                .list => {
                    var listed = try decode(client_protocol.SessionList, app, value);
                    defer listed.deinit();
                    try View.applySessionRows(app, listed.value.sessions);
                },
                .children => {
                    var listed = try decode(client_protocol.Children, app, value);
                    defer listed.deinit();
                    try View.applyChildRows(app, listed.value.children);
                },
                .startup_last, .startup_remembered => {
                    var listed = try decode(client_protocol.SessionList, app, value);
                    defer listed.deinit();
                    var selected: ?[]const u8 = null;
                    if (kind == .startup_remembered) selected = listed.value.last_attached_id;
                    if (selected == null or selected.?.len == 0) {
                        var updated: i64 = -1;
                        for (listed.value.sessions) |row| {
                            if (!std.mem.eql(u8, row.cwd, app.workspace_root)) continue;
                            if (row.updated_at_ms >= updated) {
                                selected = row.id;
                                updated = row.updated_at_ms;
                            }
                        }
                    }
                    if (selected) |id| try Backend.switchSession(app, id) else try Backend.newSession(app);
                },
                .heartbeat => {
                    var state = try decode(client_protocol.HeartbeatState, app, value);
                    defer state.deinit();
                    try View.showHeartbeat(app, state.value.heartbeat);
                },
                .kernel => {
                    var state = try decode(client_protocol.KernelState, app, value);
                    defer state.deinit();
                    try View.showKernel(app, state.value.kernel);
                },
                .history => {
                    var child = try decode(client_protocol.ChildHistory(std.json.Value), app, value);
                    defer child.deinit();
                    try View.applyChildSnapshot(app, child.value);
                },
                .config => try View.notice(app, "session", "Session configuration updated."),
                .rename => try View.notice(app, "session", "Session renamed."),
                .rpc => app.remote.permission_response_queued = false,
                // A session command's result, like a turn's output, arrives
                // as a pushed session update.
                .command, .submit, .cancel, .unwatch => {},
            }
            app.shell.render_requests.request(.footer);
        }
    };
}
pub fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

pub fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    const v = field(value, key) orelse return null;
    return if (v == .string) v.string else null;
}
pub fn integer(value: std.json.Value, key: []const u8) ?i64 {
    const v = field(value, key) orelse return null;
    return if (v == .integer) v.integer else null;
}
pub fn boolean(value: std.json.Value, key: []const u8) bool {
    const v = field(value, key) orelse return false;
    return v == .bool and v.bool;
}
pub fn itemsOf(value: std.json.Value) []const std.json.Value {
    return if (value == .array) value.array.items else &.{};
}

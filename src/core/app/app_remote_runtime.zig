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
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const remote_view = @import("remote_view.zig");
const remote_backend = @import("remote_backend.zig");
const sessions = @import("app_session_runtime.zig");
const Allocator = std.mem.Allocator;
const SnapshotView = remote_view.SnapshotView;
/// What a reply answers. `poll` is a pushed session update, and `resync` the
/// resubscribe after a reconnect.
pub const Kind = enum { startup, startup_last, startup_remembered, attach, poll, resync, list, children, history, history_page, submit, cancel, rpc, heartbeat, kernel, rename, config, command, delete, unwatch };
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
/// One node on the path from the root to the viewed child.
pub const Hop = struct {
    id: []u8,
    name: []u8,

    pub fn deinit(self: Hop, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
    }
};

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
/// One saved-history page in flight. The window it extends lives in `State`.
pub const HistoryLoad = struct {
    active: bool = false,
    generation: u64 = 0,
    sequence: u64 = 0,
    /// The first page replaces the window; an older page prepends to it.
    initial: bool = false,

    fn deinit(self: *HistoryLoad) void {
        self.* = .{};
    }
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
    /// Whether the saved transcript for `current_id` has finished loading.
    history_loaded: bool = false,
    history_load: HistoryLoad = .{},
    /// The saved fragments currently projected, oldest first. An older page
    /// prepends to this window and the whole window is replayed once.
    history_window: std.ArrayList(types.HistoryTurn) = .empty,
    history_window_bytes: usize = 0,
    history_cursor_turn: usize = 0,
    history_cursor_step: usize = 0,
    history_cursor_tail_included: bool = false,
    history_has_older: bool = false,
    /// The node below the root that the composer shows, empty at the root.
    /// A prompt typed there is a message to that node.
    child_id: []u8 = &.{},
    /// Its label: its agent name, or the end of its id.
    child_name: []u8 = &.{},
    /// The nodes between the root and `child_id`, nearest the root first;
    /// Left walks back up through them.
    child_ancestors: std.ArrayList(Hop) = .empty,
    /// The footer's path to the focused node, `root › a › b`; empty at the
    /// root.
    breadcrumb: []u8 = &.{},
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
    /// The session whose host asked `pending_permission_id`.
    pending_permission_session: []u8 = &.{},
    permission_response_queued: bool = false,
    submitted_text: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.connection) |connection| connection.stop();
        dropRequests(alloc, &self.queue);
        self.queue.deinit(alloc);
        dropRequests(alloc, &self.sent);
        self.sent.deinit(alloc);
        self.history_load.deinit();
        self.clearHistoryWindow(alloc);
        self.history_window.deinit(alloc);
        if (self.current_id.len > 0) alloc.free(self.current_id);
        if (self.child_id.len > 0) alloc.free(self.child_id);
        if (self.child_name.len > 0) alloc.free(self.child_name);
        if (self.breadcrumb.len > 0) alloc.free(self.breadcrumb);
        if (self.pending_permission_session.len > 0) alloc.free(self.pending_permission_session);
        for (self.child_ancestors.items) |hop| hop.deinit(alloc);
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

    /// The parent of the viewed child: its nearest ancestor, or the root.
    pub fn viewedParentId(self: *const State) []const u8 {
        return if (self.child_ancestors.last()) |hop| hop.id else self.current_id;
    }

    /// Whether the viewed child's work is running or waiting for an approval.
    pub fn viewedChildRunning(self: *const State) bool {
        const status = self.child_status[0..self.child_status_len];
        return self.child_live_active or std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "awaiting_approval");
    }

    /// Rebuilds `breadcrumb` from the root through the ancestors to the
    /// viewed child.
    pub fn rebuildBreadcrumb(self: *State, alloc: Allocator) !void {
        var path: std.Io.Writer.Allocating = .init(alloc);
        defer path.deinit();
        if (self.child_id.len > 0) {
            try path.writer.writeAll("root");
            for (self.child_ancestors.items) |hop| try path.writer.print(" › {s}", .{hop.name});
            try path.writer.print(" › {s}", .{self.child_name});
        }
        const owned = try path.toOwnedSlice();
        if (self.breadcrumb.len > 0) alloc.free(self.breadcrumb);
        self.breadcrumb = owned;
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

    /// Discards a partial saved-history transfer. The transcript it was
    /// rebuilding is no longer the one the person sees.
    pub fn cancelHistoryLoad(self: *State) void {
        self.history_load.deinit();
    }

    fn clearHistoryWindow(self: *State, alloc: Allocator) void {
        for (self.history_window.items) |turn| types.freeHistoryTurn(alloc, turn);
        self.history_window.clearRetainingCapacity();
        self.history_window_bytes = 0;
        self.history_cursor_turn = 0;
        self.history_cursor_step = 0;
        self.history_cursor_tail_included = false;
        self.history_has_older = false;
    }

    /// Clears the transcript's saved-history window when the attached session
    /// or node changes.
    pub fn resetHistory(self: *State, alloc: Allocator) void {
        self.cancelHistoryLoad();
        self.clearHistoryWindow(alloc);
        self.history_loaded = false;
    }

    /// Starts collecting the first or next saved-history page checkpointed at
    /// `sequence`.
    pub fn beginHistoryLoad(self: *State, sequence: u64, initial: bool) void {
        self.cancelHistoryLoad();
        self.history_load = .{
            .active = true,
            .generation = self.generation,
            .sequence = sequence,
            .initial = initial,
        };
        if (initial) self.history_loaded = false;
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
                // Right lists the children of whichever node the composer shows.
                try app.remote.enqueue(.children, .{ .children = .{ .session_id = app.remote.current_id, .node_id = app.remote.viewedNodeId(), .watch = true } });
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
            if (comptime @hasDecl(@TypeOf(app.shell), "takeFullTranscriptHistoryRequest")) {
                if (app.shell.takeFullTranscriptHistoryRequest()) {
                    debug_trace.logf("session", "full transcript requested older history older={s} loaded={s}", .{
                        if (app.remote.history_has_older) "true" else "false",
                        if (app.remote.history_loaded) "true" else "false",
                    });
                    try Backend.loadOlderHistory(app);
                }
            }
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
            remote.cancelHistoryLoad();
            try remote.sendNow(.resync, .{ .attach = .{
                .session_id = remote.current_id,
                .after_sequence = remote.sequence,
                .include_history = !remote.history_loaded,
            } });
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
            if (remote.history_load.active) {
                remote.cancelHistoryLoad();
                remote.history_loaded = false;
            }
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
                .parent_id = remote.viewedParentId(),
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
                if (kind == .delete) {
                    app.input_runtime.session_browser.cancelDelete();
                    const friendly = if (std.mem.eql(u8, message, "SessionInUse"))
                        "The session is open in another view or another fx process and was not deleted."
                    else if (std.mem.eql(u8, message, "SessionBusy"))
                        "The session is still busy and was not deleted."
                    else if (std.mem.eql(u8, message, "SessionNotFound"))
                        "The session was already deleted."
                    else
                        message;
                    try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = friendly }, true);
                    app.shell.render_requests.request(.footer);
                    return;
                }
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
                    try View.applyChildRows(app, listed.value.node_id, listed.value.children);
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
                    var child = try decode(client_protocol.ChildHistory([]const types.HistoryTurn, std.json.Value), app, value);
                    defer child.deinit();
                    try View.applyChildSnapshot(app, child.value);
                },
                .history_page => try applyHistoryPage(app, value),
                .config => try View.notice(app, "session", "Session configuration updated."),
                .rename => try View.notice(app, "session", "Session renamed."),
                .delete => {
                    app.input_runtime.session_browser.cancelDelete();
                    try View.notice(app, "session", "Session deleted.");
                },
                .rpc => app.remote.permission_response_queued = false,
                // A session command's result, like a turn's output, arrives
                // as a pushed session update.
                .command, .submit, .cancel, .unwatch => {},
            }
            app.shell.render_requests.request(.footer);
        }

        /// Replaces or prepends one saved-history page, then rebuilds the
        /// loaded window once. The page fragments already carry only the
        /// steps and turn text they own, so the replay cannot duplicate a
        /// prompt or final reply.
        fn applyHistoryPage(app: *App, value: std.json.Value) !void {
            var page = try decode(client_protocol.HistoryPage([]const types.HistoryTurn), app, value);
            defer page.deinit();
            const remote = &app.remote;
            if (!remote.history_load.active or remote.history_load.generation != remote.generation) return;
            if (!std.mem.eql(u8, page.value.session_id, remote.current_id)) return;
            debug_trace.logf(
                "session",
                "history page turns={d} start={d}:{d} tail={s} bytes={d} older={s} initial={s}",
                .{
                    page.value.turns.len,
                    page.value.start_turn,
                    page.value.start_step,
                    if (page.value.start_tail_included) "true" else "false",
                    page.value.page_bytes,
                    if (page.value.has_older) "true" else "false",
                    if (remote.history_load.initial) "true" else "false",
                },
            );
            if (page.value.history_sequence != remote.history_load.sequence) {
                // A turn committed while the page loaded. Reload the tail.
                remote.beginHistoryLoad(page.value.history_sequence, true);
                try remote.enqueue(.history_page, .{ .history_page = .{
                    .session_id = remote.current_id,
                } });
                return;
            }

            const initial = remote.history_load.initial;
            if (page.value.turns.len == 0 and !initial) {
                remote.history_load.deinit();
                remote.history_has_older = false;
                try View.notice(app, "session", "No older transcript entries remain.");
                return;
            }
            var window: std.ArrayList(types.HistoryTurn) = .empty;
            errdefer {
                for (window.items) |turn| types.freeHistoryTurn(app.alloc, turn);
                window.deinit(app.alloc);
            }
            for (page.value.turns) |turn| {
                try window.append(app.alloc, try types.dupeHistoryTurn(app.alloc, turn));
            }
            if (!initial) {
                try window.appendSlice(app.alloc, remote.history_window.items);
                remote.history_window.items.len = 0;
                remote.history_window.deinit(app.alloc);
            } else {
                for (remote.history_window.items) |turn| types.freeHistoryTurn(app.alloc, turn);
                remote.history_window.clearRetainingCapacity();
                remote.history_window.deinit(app.alloc);
            }
            remote.history_window = .empty;
            remote.history_load.deinit();

            const sequence = page.value.history_sequence;
            const window_bytes = if (initial)
                page.value.page_bytes
            else
                remote.history_window_bytes +| page.value.page_bytes;
            const full_transcript_active = if (comptime @hasDecl(@TypeOf(app.shell), "fullTranscriptActive"))
                app.shell.fullTranscriptActive()
            else
                false;
            if (!initial and full_transcript_active and
                comptime @hasDecl(@TypeOf(app.shell), "resetTranscriptPreservingFullTranscript"))
            {
                app.shell.resetTranscriptPreservingFullTranscript(app.alloc);
            } else {
                View.resetTranscript(app);
            }
            if (initial and page.value.has_older) {
                try View.notice(app, "session", "Older transcript entries load when you scroll up in the full transcript.");
            }
            remote.history_window = window;
            remote.history_window_bytes = window_bytes;
            remote.history_cursor_turn = page.value.start_turn;
            remote.history_cursor_step = page.value.start_step;
            remote.history_cursor_tail_included = page.value.start_tail_included;
            remote.history_has_older = page.value.has_older;
            remote.history_loaded = true;
            remote.sequence = sequence;
            sessions.Runtime(App).replayRemoteHistoryWindow(
                app,
                remote.history_window.items,
                remote.history_window_bytes,
            ) catch |err| {
                var message_buf: [128]u8 = undefined;
                const message = std.mem.print(
                    &message_buf,
                    "The saved transcript could not be rendered ({s}).",
                    .{@errorName(err)},
                ) catch "The saved transcript could not be rendered.";
                try View.notice(app, "session", message);
            };
            remote.native_turn_offset = app.shell.finalizedToolTurnWatermark() + 1;
            if (!initial and full_transcript_active) {
                if (comptime @hasDecl(@TypeOf(app.shell), "showOldestFullTranscriptPage")) {
                    app.shell.showOldestFullTranscriptPage();
                }
            } else if (initial) {
                // Events that followed the saved checkpoint were held back
                // while the transcript loaded. Ask for them now.
                try remote.sendNow(.resync, .{ .attach = .{
                    .session_id = remote.current_id,
                    .after_sequence = sequence,
                    .include_history = false,
                } });
            }
            app.shell.render_requests.request(.transcript);
            app.shell.render_requests.request(.modal);
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

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
const history_page = @import("../supervisor/history_page.zig");
const remote_view = @import("remote_view.zig");
const remote_backend = @import("remote_backend.zig");
const sessions = @import("app_session_runtime.zig");
const history_prepend = @import("../../ui/transcript/history_prepend.zig");
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
/// One saved-history page in flight.
pub const HistoryLoad = struct {
    active: bool = false,
    /// The view generation that asked; a page for another view is dropped.
    generation: u64 = 0,
    /// The newest page replaces the window; an older one extends it.
    initial: bool = false,

    fn reset(self: *HistoryLoad) void {
        self.* = .{};
    }
};

/// The most saved history the transcript holds. Paging further back stops
/// here, so a client's memory stays bounded however long the session.
pub const history_window_max_bytes: usize = 8 * 1024 * 1024;

/// The saved history the transcript shows: owned fragments, oldest first,
/// from `start` to the end of the first `turn_count` saved turns. Live events
/// after the checkpoint it was loaded at follow it.
pub const HistoryWindow = struct {
    fragments: std.ArrayList(history_page.Fragment) = .empty,
    /// One per fragment once the transcript is built from them: the id of
    /// the first entry the fragment produced.
    first_entry_ids: std.ArrayList(u32) = .empty,
    bytes: usize = 0,
    start: history_page.Cursor = .{},
    turn_count: usize = 0,
    generation: u64 = 0,
    has_older: bool = false,
    /// The lowest entry id the window's entries use. An older page numbers
    /// its entries below it, so ids keep the transcript's order.
    id_floor: u32 = 0,
    /// The older-entries notice above the fragments, if shown.
    notice_entry_id: ?u32 = null,

    pub fn deinit(self: *HistoryWindow, alloc: Allocator) void {
        for (self.fragments.items) |fragment| types.freeHistoryTurn(alloc, fragment.turn);
        self.fragments.deinit(alloc);
        self.first_entry_ids.deinit(alloc);
        self.* = .{};
    }

    /// Drops the fragments whose oldest entries retention pruned from the
    /// transcript, whose oldest remaining entry at or after the window's is
    /// `oldest_entry_id` (null when none remains). The window then starts
    /// at the oldest fragment still shown, so the next older page fetches
    /// exactly what was pruned, and its bytes count only what is shown.
    pub fn dropPruned(self: *HistoryWindow, alloc: Allocator, oldest_entry_id: ?u32) void {
        const ids = self.first_entry_ids.items;
        if (ids.len != self.fragments.items.len) return;
        const pruned = if (oldest_entry_id) |oldest| for (ids, 0..) |id, index| {
            if (id >= oldest) break index;
        } else ids.len else ids.len;
        if (pruned == 0) return;
        for (self.fragments.items[0..pruned]) |fragment| {
            self.bytes -|= history_page.fragmentBytes(fragment);
            types.freeHistoryTurn(alloc, fragment.turn);
        }
        self.fragments.replaceRangeAssumeCapacity(0, pruned, &.{});
        self.first_entry_ids.replaceRangeAssumeCapacity(0, pruned, &.{});
        self.start = if (self.fragments.items.len > 0) .{
            .turn = self.fragments.items[0].turn_index,
            .step = self.fragments.items[0].first_step,
        } else .{ .turn = self.turn_count };
        self.has_older = true;
    }

    /// Owned copies of `fragments`. The caller frees each turn and the list.
    fn copies(alloc: Allocator, fragments: []const history_page.Fragment) !std.ArrayList(history_page.Fragment) {
        var list: std.ArrayList(history_page.Fragment) = .empty;
        errdefer {
            for (list.items) |fragment| types.freeHistoryTurn(alloc, fragment.turn);
            list.deinit(alloc);
        }
        try list.ensureTotalCapacity(alloc, fragments.len);
        for (fragments) |fragment| {
            var copy = fragment;
            copy.turn = try types.dupeHistoryTurn(alloc, fragment.turn);
            list.appendAssumeCapacity(copy);
        }
        return list;
    }
};

/// The first entry id of a remote transcript's newest window. The ids below
/// it number the older pages added above it, each within its own block.
const history_entry_id_base: u32 = 1 << 30;
const older_page_entry_ids: u32 = 1 << 20;
/// How long one loop pass may spend projecting an older page.
const older_page_slice_ns: i128 = 4 * std.time.ns_per_ms;

const older_notice_text = "Older transcript entries load when you page up in the full transcript.";

/// A received older page and where it goes in the window.
pub const OlderPage = struct {
    projection: sessions.OlderHistoryProjection,
    start: history_page.Cursor,
    has_older: bool,
    bytes: usize,
    id_floor: u32,
};

pub const State = struct {
    allocator: ?Allocator = null,
    connection: ?*client_mod.Connection = null,
    link: Link = .connecting,
    connected_once: bool = false,
    /// The connection dropped at least once. The startup banner then sits
    /// in scrollback, so a transcript rebuild does not print it again
    /// (D280).
    outage_seen: bool = false,
    /// Requests not sent yet. They go out when the link is ready.
    queue: std.ArrayList(Request) = .empty,
    /// Sent requests awaiting their replies.
    sent: std.ArrayList(Request) = .empty,
    /// What this connection asked the supervisor to push.
    watching: struct { list: bool = false, children: bool = false, child: bool = false } = .{},
    /// The attached root session.
    current_id: []u8 = &.{},
    /// A notice from startup, such as an available update, shown once the
    /// first session transcript is rebuilt, which would clear it (D143).
    /// Owned.
    pending_notice: ?[]u8 = null,
    pending_notice_tone: types.NoticeTone = .neutral,
    pending_notice_topic: []const u8 = "update",
    /// Whether the saved transcript for `current_id` has finished loading.
    history_loaded: bool = false,
    /// The supervisor's start of the running turn this view last adopted.
    turn_start_adopted: i64 = 0,
    history_load: HistoryLoad = .{},
    history_window: HistoryWindow = .{},
    /// A received older page still being projected.
    older_page: ?OlderPage = null,
    /// The "Loading earlier history" row the full transcript shows while an
    /// older page loads.
    loading_entry_id: ?u32 = null,
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
    /// The attached session's running background jobs, for the footer.
    running_jobs: u32 = 0,
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
    /// A provider `/login` chose while no session was open; the session
    /// that opens next switches to it (D215).
    pending_provider: ?[]u8 = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.pending_provider) |provider| alloc.free(provider);
        self.pending_provider = null;
        if (self.connection) |connection| connection.stop();
        if (self.pending_notice) |notice| alloc.free(notice);
        self.pending_notice = null;
        dropRequests(alloc, &self.queue);
        self.queue.deinit(alloc);
        dropRequests(alloc, &self.sent);
        self.sent.deinit(alloc);
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
        const status = statusPhase(self.child_status[0..self.child_status_len]);
        return self.child_live_active or std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "awaiting_approval");
    }

    /// A node status's phase, without the queued count a worker adds
    /// (`running · 2 queued`, D113).
    pub fn statusPhase(status: []const u8) []const u8 {
        return status[0 .. std.mem.find(u8, status, " · ") orelse status.len];
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
            // A terminated worker, or one with queued turns, says so (D113).
            const status = self.child_status[0..self.child_status_len];
            if (std.mem.eql(u8, status, "terminated") or std.mem.find(u8, status, "queued") != null) try path.writer.print(" · {s}", .{status});
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
        self.history_load.reset();
        if (self.older_page) |*older| older.projection.deinit();
        self.older_page = null;
    }

    /// Whether an older page is loading or being projected.
    pub fn olderHistoryPending(self: *const State) bool {
        return (self.history_load.active and !self.history_load.initial) or self.older_page != null;
    }

    /// Clears the saved-history window when the attached session or node
    /// changes.
    pub fn resetHistory(self: *State, alloc: Allocator) void {
        self.cancelHistoryLoad();
        self.history_window.deinit(alloc);
        self.history_loaded = false;
        self.loading_entry_id = null;
    }

    /// Asks for the newest saved-history page, which replaces the window, or
    /// the page before the window, which extends it.
    pub fn requestHistoryPage(self: *State, initial: bool) !void {
        self.cancelHistoryLoad();
        const window = &self.history_window;
        try self.enqueue(.history_page, .{ .history_page = if (initial) .{
            .session_id = self.current_id,
            .max_bytes = history_page.resume_page_bytes,
        } else .{
            .session_id = self.current_id,
            .before = window.start,
        } });
        self.history_load = .{ .active = true, .generation = self.generation, .initial = initial };
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
    pub fn inFlight(self: *const State, kind: Kind) bool {
        for ([_][]const Request{ self.queue.items, self.sent.items }) |list| {
            for (list) |request| if (request.kind == kind and request.generation == self.generation) return true;
        }
        return false;
    }

    /// Whether a pushed session snapshot may apply now. From an attach until
    /// the resync after the newest history page answers, the replay that
    /// resync returns covers every event; a push could only jump the
    /// sequence past the frames it still owes, such as the running turn's
    /// prompt (D270).
    pub fn acceptsSessionPush(self: *const State) bool {
        if (self.link != .ready) return false;
        if (self.history_load.active and self.history_load.initial) return false;
        return !(self.inFlight(.startup) or self.inFlight(.attach) or self.inFlight(.resync));
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
            try continueOlderPage(app);
            // However an older load ended, its loading row goes with it.
            if (remote.loading_entry_id != null and !remote.olderHistoryPending()) removeLoadingRow(app);
            if (app.shell.takeFullTranscriptHistoryRequest()) try Backend.loadOlderHistory(app);
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
                // An unfinished newest page leaves no transcript to keep.
                if (remote.history_load.initial) remote.history_loaded = false;
                remote.cancelHistoryLoad();
            }
            if (app.input_runtime.session_browser.active) app.input_runtime.session_browser.fail(@errorName(failure));
            if (!remote.connected_once) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = @errorName(failure) }, true);
                return;
            }
            remote.outage_seen = true;
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
                    if (!remote.acceptsSessionPush()) return;
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
                if (kind == .history_page) return failHistoryPage(app, message);
                if (kind == .list or kind == .children) app.input_runtime.session_browser.fail(message);
                // The supervisor words a refused delete itself
                // (`supervisor/session_delete.zig`).
                if (kind == .delete) {
                    app.input_runtime.session_browser.cancelDelete();
                    app.shell.render_requests.request(.footer);
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

        /// A page request failed. The load ends so prompts are not held
        /// back, and the live events after the checkpoint still show.
        fn failHistoryPage(app: *App, message: []const u8) !void {
            const remote = &app.remote;
            if (!remote.history_load.active) return;
            const initial = remote.history_load.initial;
            remote.cancelHistoryLoad();
            const body = try app.alloc.print("The saved transcript could not be loaded ({s}).", .{message});
            defer app.alloc.free(body);
            try View.notice(app, "session", body);
            if (initial) try resync(app, remote.sequence);
        }

        /// Applies one saved-history page. The newest page replaces the
        /// window and rebuilds the transcript, then the live events after
        /// its checkpoint follow. An older page is projected a few fragments
        /// per loop pass and then added above the window; the live turns
        /// already shown stay as they are.
        fn applyHistoryPage(app: *App, value: std.json.Value) !void {
            const started_ns = io_mod.nanoTimestamp();
            defer debug_trace.logf("session", "history page applied us={d}", .{@divTrunc(io_mod.nanoTimestamp() - started_ns, std.time.ns_per_us)});
            var parsed = try decode(client_protocol.HistoryPage([]const history_page.Fragment), app, value);
            defer parsed.deinit();
            const page = parsed.value;
            const remote = &app.remote;
            if (!remote.history_load.active or remote.history_load.generation != remote.generation) return;
            if (!std.mem.eql(u8, page.session_id, remote.current_id)) return;
            const initial = remote.history_load.initial;
            remote.history_load.reset();
            debug_trace.logf(
                "session",
                "history page fragments={d} start={d}:{d} bytes={d} older={} initial={}",
                .{ page.fragments.len, page.start.turn, page.start.step, page.page_bytes, page.has_older, initial },
            );
            if (!initial) return beginOlderPage(app, page) catch |err| failOlderPage(app, err);

            var window: HistoryWindow = .{
                .fragments = try HistoryWindow.copies(app.alloc, page.fragments),
                .bytes = page.page_bytes,
                .start = page.start,
                .turn_count = page.turn_count,
                .generation = page.generation,
                .has_older = page.has_older,
            };
            errdefer window.deinit(app.alloc);
            try window.first_entry_ids.resize(app.alloc, window.fragments.items.len);
            remote.history_window.deinit(app.alloc);
            remote.history_window = window;
            try rebuildTranscript(app);
            try adoptChecklist(app, page.checklist);
            remote.sequence = page.history_sequence;
            try resync(app, page.history_sequence);
        }

        /// The checklist panel follows the session the history belongs to
        /// (D252): its saved plan, or nothing.
        fn adoptChecklist(app: *App, plan: ?[]const u8) !void {
            if (comptime !@hasField(App, "checklist_panel")) return;
            const text = plan orelse {
                app.checklist_panel.adopt(null);
                return;
            };
            var parsed = std.json.parseFromSlice(std.json.Value, app.alloc, text, .{}) catch |err| {
                debug_trace.logf("checklist", "saved plan unreadable err={s}", .{@errorName(err)});
                app.checklist_panel.adopt(null);
                return;
            };
            defer parsed.deinit();
            const entries = if (parsed.value == .object) parsed.value.object.get("entries") else null;
            try app.checklist_panel.adoptPlan(app.alloc, if (entries) |value| itemsOf(value) else &.{});
        }

        fn beginOlderPage(app: *App, page: client_protocol.HistoryPage([]const history_page.Fragment)) !void {
            const remote = &app.remote;
            const window = &remote.history_window;
            if (page.generation != window.generation) {
                // The saved history was rewritten. Start again from the newest.
                return remote.requestHistoryPage(true);
            }
            if (page.fragments.len == 0) {
                window.has_older = false;
                return View.notice(app, "session", "No older transcript entries remain.");
            }
            // One id below the window is the loading row's.
            if (window.id_floor <= older_page_entry_ids + 1) return remote.requestHistoryPage(true);
            const id_floor = window.id_floor - older_page_entry_ids - 1;
            remote.older_page = .{
                .projection = try sessions.Runtime(App).beginOlderHistory(
                    app,
                    page.fragments,
                    id_floor,
                    if (page.has_older) older_notice_text else null,
                ),
                .start = page.start,
                .has_older = page.has_older,
                .bytes = page.page_bytes,
                .id_floor = id_floor,
            };
        }

        /// Projects the received older page for one slice of this loop pass,
        /// and adds it above the window once it is complete.
        fn continueOlderPage(app: *App) !void {
            const remote = &app.remote;
            const older = if (remote.older_page) |*value| value else return;
            const started_ns = io_mod.nanoTimestamp();
            const projected = sessions.Runtime(App).continueOlderHistory(app, &older.projection, started_ns + older_page_slice_ns);
            debug_trace.logf("session", "older page slice fragments={d}/{d} us={d}", .{
                older.projection.next,
                older.projection.fragments.items.len,
                @divTrunc(io_mod.nanoTimestamp() - started_ns, std.time.ns_per_us),
            });
            projected catch |err| return failOlderPage(app, err);
            if (!older.projection.done()) return;
            var taken = older.*;
            remote.older_page = null;
            defer taken.projection.deinit();
            prependOlderPage(app, &taken) catch |err| return failOlderPage(app, err);
            debug_trace.logf("session", "older page prepended entries={d} us={d}", .{
                app.shell.entries.items.len,
                @divTrunc(io_mod.nanoTimestamp() - started_ns, std.time.ns_per_us),
            });
        }

        fn failOlderPage(app: *App, err: anyerror) !void {
            if (app.remote.older_page) |*older| older.projection.deinit();
            app.remote.older_page = null;
            var message_buf: [128]u8 = undefined;
            const message = std.mem.print(&message_buf, "The older transcript entries could not be shown ({s}).", .{@errorName(err)}) catch "The older transcript entries could not be shown.";
            try View.notice(app, "session", message);
        }

        /// Adds a projected older page above the window. The reader stays on
        /// the entry they were reading; one at the top sees it with the new
        /// entries above it.
        fn prependOlderPage(app: *App, older: *OlderPage) !void {
            const remote = &app.remote;
            const window = &remote.history_window;
            const shell = &app.shell;
            const projected = &older.projection;
            const at_top = history_prepend.readerAtTop(shell);
            try window.fragments.ensureUnusedCapacity(app.alloc, projected.fragments.items.len);
            try window.first_entry_ids.ensureUnusedCapacity(app.alloc, projected.first_entry_ids.items.len);
            removeLoadingRow(app);
            if (window.notice_entry_id) |id| history_prepend.removeEntry(shell, app.alloc, id);
            window.notice_entry_id = null;
            const insert_at = history_prepend.firstIndexFrom(shell, window.id_floor);
            const old_top: ?u32 = if (insert_at < shell.entries.items.len) shell.entries.items[insert_at].id() else null;
            sessions.Runtime(App).prependOlderHistory(app, projected, insert_at) catch |err| switch (err) {
                // Ids no longer fit below the window: start again from the newest.
                error.EntryIdsOutOfOrder => return remote.requestHistoryPage(true),
                else => return err,
            };
            window.fragments.replaceRangeAssumeCapacity(0, 0, projected.fragments.items);
            projected.fragments.clearRetainingCapacity();
            window.first_entry_ids.replaceRangeAssumeCapacity(0, 0, projected.first_entry_ids.items);
            window.bytes +|= older.bytes;
            window.start = older.start;
            window.has_older = older.has_older;
            window.id_floor = older.id_floor;
            window.notice_entry_id = projected.notice_entry_id;
            shell.max_retained_transcript_bytes = sessions.Runtime(App).remoteRetentionCap(window.bytes);
            if (at_top) if (old_top) |id| history_prepend.revealEntry(shell, id);
            shell.render_requests.request(.modal);
        }

        /// Shows "Loading earlier history" above the window while an older
        /// page loads, in view when the reader is at the top.
        pub fn showLoadingRow(app: *App) !void {
            const remote = &app.remote;
            const floor = remote.history_window.id_floor;
            if (remote.loading_entry_id != null or floor == 0) return;
            const shell = &app.shell;
            const at_top = history_prepend.readerAtTop(shell);
            try history_prepend.insertNotice(shell, app.alloc, history_prepend.firstIndexFrom(shell, floor), floor - 1, .{
                .topic = "session",
                .tone = .neutral,
                .body = "Loading earlier history…",
            });
            remote.loading_entry_id = floor - 1;
            if (at_top) history_prepend.revealEntry(shell, floor - 1);
        }

        fn removeLoadingRow(app: *App) void {
            const id = app.remote.loading_entry_id orelse return;
            app.remote.loading_entry_id = null;
            history_prepend.removeEntry(&app.shell, app.alloc, id);
        }

        /// Replays the newest window into a cleared transcript, numbering its
        /// entries from `history_entry_id_base` so older pages fit below.
        fn rebuildTranscript(app: *App) !void {
            const remote = &app.remote;
            // Clearing the shown transcript resets the history state too;
            // the window is the content being rebuilt, so it stays.
            const window = remote.history_window;
            remote.history_window = .{};
            View.resetTranscriptContents(app);
            remote.history_window = window;
            remote.history_loaded = true;
            app.shell.next_entry_id = @max(app.shell.next_entry_id, history_entry_id_base);
            const shown = &remote.history_window;
            shown.id_floor = app.shell.next_entry_id;
            sessions.Runtime(App).replayRemoteHistory(app, shown.fragments.items, .{
                .window_bytes = shown.bytes,
                .older_notice = if (shown.has_older) older_notice_text else null,
                .first_entry_ids = shown.first_entry_ids.items,
                .notice_entry_id = &shown.notice_entry_id,
            }) catch |err| {
                shown.first_entry_ids.clearRetainingCapacity();
                var message_buf: [128]u8 = undefined;
                const message = std.mem.print(
                    &message_buf,
                    "The saved transcript could not be rendered ({s}).",
                    .{@errorName(err)},
                ) catch "The saved transcript could not be rendered.";
                try View.notice(app, "session", message);
            };
            remote.native_turn_offset = app.shell.finalizedToolTurnWatermark() + 1;
            if (remote.pending_notice) |body| {
                remote.pending_notice = null;
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{ .topic = remote.pending_notice_topic, .tone = remote.pending_notice_tone, .body = body }, true);
            }
            app.shell.render_requests.request(.transcript);
            app.shell.render_requests.request(.modal);
        }

        /// Asks for the live events after `sequence`, which a history load
        /// held back.
        fn resync(app: *App, sequence: u64) !void {
            try app.remote.sendNow(.resync, .{ .attach = .{
                .session_id = app.remote.current_id,
                .after_sequence = sequence,
                .include_history = false,
            } });
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

test "a window drops the fragments retention pruned and restarts at the oldest shown" {
    const alloc = std.testing.allocator;
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
        .execution = .{ .turn_summary = .{} },
    } };
    var window: HistoryWindow = .{ .turn_count = 7, .start = .{ .turn = 4 } };
    defer window.deinit(alloc);
    const shape = [_]history_page.Fragment{
        .{ .turn = turn, .turn_index = 4 },
        .{ .turn = turn, .turn_index = 5, .has_tail = false },
        .{ .turn = turn, .turn_index = 5, .first_step = 2, .has_user = false },
        .{ .turn = turn, .turn_index = 6 },
    };
    window.fragments = try HistoryWindow.copies(alloc, &shape);
    for (shape) |fragment| window.bytes += history_page.fragmentBytes(fragment);
    try window.first_entry_ids.appendSlice(alloc, &.{ 10, 20, 30, 40 });

    // Nothing pruned: the window is unchanged.
    window.dropPruned(alloc, 10);
    try std.testing.expectEqual(@as(usize, 4), window.fragments.items.len);

    // Retention pruned into the second fragment: the first two leave, and
    // the next older page ends where the shown history begins.
    window.dropPruned(alloc, 25);
    try std.testing.expectEqual(@as(usize, 2), window.fragments.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 30, 40 }, window.first_entry_ids.items);
    try std.testing.expectEqual(history_page.Cursor{ .turn = 5, .step = 2 }, window.start);
    try std.testing.expectEqual(history_page.fragmentBytes(shape[2]) + history_page.fragmentBytes(shape[3]), window.bytes);
    try std.testing.expect(window.has_older);

    // Everything pruned: the window is empty and starts after its turns.
    window.dropPruned(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), window.fragments.items.len);
    try std.testing.expectEqual(history_page.Cursor{ .turn = 7 }, window.start);
    try std.testing.expectEqual(@as(usize, 0), window.bytes);
}

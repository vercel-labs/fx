//! An agent's session state: its open session and store, the picker and
//! fork menu over its sessions, and what its session commands have pending.
//! The agents folder holds one per agent, so this file imports nothing from
//! the screen; `app_session_runtime.zig` runs it.

const std = @import("std");
const builtin = @import("builtin");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_codec = @import("../session/session_codec.zig");
const js_host_session_store = @import("../session/js_host_session_store.zig");
const session_title_generation = @import("../session/session_title_generation.zig");
const session_adapter = @import("../session/session_adapter.zig");
const turn_capture = @import("../workspace/turn_capture.zig");
const session_store = @import("../session/session_store.zig");
const session_catalog_cache = @import("../session/session_catalog_cache.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const BackgroundSessionPolicy = enum {
    carry_forward,
    stop_forget,
};

pub const LiveSessionWait = union(enum) {
    worker: u64,
    geometry: u64,
};

/// Where the picker's next page starts: an owned copy of the listing's
/// continuation.
const PickerContinuation = struct {
    updated_at_ms: i64,
    id: []u8,

    pub fn deinit(self: *PickerContinuation, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn view(self: PickerContinuation) session_store.ResumableSessionContinuation {
        return .{ .updated_at_ms = self.updated_at_ms, .id = self.id };
    }
};

pub const SessionPickerScope = session_catalog.Scope;
pub const SessionPickerAction = session_catalog.PendingAction;

pub const BusyPromptChoice = enum {
    fork,
    back,
};

const SessionPickerBusyPrompt = struct {
    session_id: []u8,
    title: []u8,
    workspace_label: []u8,
    turn_count: usize = 0,
    pid: ?u32 = null,
    selected_yes: bool = true,
    error_message: ?[]u8 = null,

    fn deinit(self: *SessionPickerBusyPrompt, alloc: Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.title);
        alloc.free(self.workspace_label);
        if (self.error_message) |message| alloc.free(message);
        self.* = undefined;
    }

    pub fn setError(self: *SessionPickerBusyPrompt, alloc: Allocator, message: []const u8) !void {
        const owned = try alloc.dupe(u8, message);
        if (self.error_message) |old| alloc.free(old);
        self.error_message = owned;
    }
};

pub const ResumeHandoffIntent = enum {
    none,
    requested,
    upgrade_requested,
};

pub const SessionPicker = struct {
    active: bool = false,
    load_state: session_catalog.LoadState = .loading,
    generation: u64 = 0,
    has_more: bool = false,
    loading_more: bool = false,
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    continuation: ?PickerContinuation = null,
    selected: usize = 0,
    window_start: usize = 0,
    scope: SessionPickerScope = .current_workspace,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    selection_failure: ?session_catalog.ResumeFailure = null,
    pending_action: ?SessionPickerAction = null,
    busy_prompt: ?SessionPickerBusyPrompt = null,

    pub fn deinit(self: *SessionPicker, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        if (self.busy_prompt) |*prompt| prompt.deinit(alloc);
        self.* = .{};
    }

    pub fn appendSummary(
        self: *SessionPicker,
        alloc: Allocator,
        source: *const session_store.SessionSummary,
    ) !void {
        if (!source.hasResumableContent()) return;

        var summary = try session_summary_codec.cloneSessionSummary(alloc, source.*);
        errdefer summary.deinit(alloc);
        try self.summaries.append(alloc, summary);
    }

    pub fn selectedSummary(self: *const SessionPicker) ?*const session_store.SessionSummary {
        if (!self.active or self.load_state != .ready) return null;
        if (self.selected >= self.filteredItemCount()) return null;
        return session_catalog.summaryAt(self.summaries.items, self.query(), self.selected);
    }

    pub fn selectedId(self: *const SessionPicker) ?[]const u8 {
        const summary = self.selectedSummary() orelse return null;
        return summary.id;
    }

    pub fn isLoading(self: *const SessionPicker) bool {
        return self.active and self.load_state == .loading;
    }

    pub fn busyPromptActive(self: *const SessionPicker) bool {
        return self.active and self.busy_prompt != null;
    }

    pub fn actionPending(self: *const SessionPicker) bool {
        return self.active and self.pending_action != null;
    }

    pub fn openBusyPrompt(
        self: *SessionPicker,
        alloc: Allocator,
        session_id: []const u8,
        title: []const u8,
        pid: ?u32,
    ) !void {
        var workspace_label: []const u8 = "";
        var turn_count: usize = 0;
        for (self.summaries.items) |summary| {
            if (std.mem.eql(u8, summary.id, session_id)) {
                workspace_label = std.Io.Dir.path.basename(session_catalog.workspacePath(summary));
                turn_count = summary.history_len;
                break;
            }
        }
        const owned_id = try alloc.dupe(u8, session_id);
        errdefer alloc.free(owned_id);
        const owned_title = try alloc.dupe(u8, title);
        errdefer alloc.free(owned_title);
        const owned_workspace = try alloc.dupe(u8, workspace_label);
        errdefer alloc.free(owned_workspace);
        self.closeBusyPrompt(alloc);
        self.selection_failure = null;
        self.busy_prompt = .{
            .session_id = owned_id,
            .title = owned_title,
            .workspace_label = owned_workspace,
            .turn_count = turn_count,
            .pid = pid,
            .selected_yes = true,
        };
    }

    pub fn closeBusyPrompt(self: *SessionPicker, alloc: Allocator) void {
        if (self.busy_prompt) |*prompt| prompt.deinit(alloc);
        self.busy_prompt = null;
    }

    pub fn toggleBusyPromptChoice(self: *SessionPicker) void {
        if (self.busy_prompt) |*prompt| {
            if (prompt.error_message != null) return;
            prompt.selected_yes = !prompt.selected_yes;
        }
    }

    pub fn selectBusyPromptChoice(self: *SessionPicker, choice: BusyPromptChoice) void {
        if (self.busy_prompt) |*prompt| {
            if (prompt.error_message != null) return;
            prompt.selected_yes = choice == .fork;
        }
    }

    pub fn query(self: *const SessionPicker) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *SessionPicker, query_text: []const u8) void {
        if (self.busy_prompt != null or self.pending_action != null) {
            debug_trace.logf(
                "session",
                "picker query ignored len={d} reason={s}",
                .{ query_text.len, if (self.pending_action != null) "action_pending" else "busy_prompt" },
            );
            return;
        }
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) @memmove(self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected = 0;
        self.window_start = 0;
        self.selection_failure = null;
    }

    pub fn filteredItemCount(self: *const SessionPicker) usize {
        return session_catalog.filteredCount(self.summaries.items, self.query());
    }

    pub fn navigationItemCount(self: *const SessionPicker) usize {
        return self.filteredItemCount() + @intFromBool(self.has_more);
    }

    pub fn isLoadMoreSelected(self: *const SessionPicker) bool {
        return self.active and self.load_state == .ready and self.has_more and
            self.selected == self.filteredItemCount();
    }

    pub fn moveVisibleItems(self: *SessionPicker, delta: i32, visible_items: u16) bool {
        if (!self.active or self.load_state != .ready) return false;
        if (self.busy_prompt != null or self.pending_action != null) return true;
        self.selection_failure = null;
        const count = self.navigationItemCount();
        if (count == 0) return true;
        // Clamp at both ends instead of wrapping: at the top the selection
        // stays on the first session, at the bottom on the last row.
        const current: i32 = @intCast(self.selected % count);
        var next = current + delta;
        if (next < 0) next = 0;
        if (next >= @as(i32, @intCast(count))) next = @as(i32, @intCast(count)) - 1;
        self.selected = @intCast(next);
        self.syncWindowStart(visible_items);
        return true;
    }

    pub fn syncWindowStart(self: *SessionPicker, visible_items: u16) void {
        const session_count = self.filteredItemCount();
        const action_items: u16 = @intFromBool(self.has_more and visible_items > 0);
        const visible_sessions = visible_items -| action_items;
        if (session_count == 0 or visible_sessions == 0) {
            self.window_start = 0;
            return;
        }
        if (self.selected >= session_count) {
            self.window_start = session_count -| visible_sessions;
            return;
        }
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            session_count,
            self.selected,
            visible_sessions,
        );
    }

    fn appendPage(
        self: *SessionPicker,
        alloc: Allocator,
        summaries: []const session_store.SessionSummary,
    ) !void {
        const summary_len = self.summaries.items.len;
        errdefer {
            while (self.summaries.items.len > summary_len) {
                if (self.summaries.pop()) |summary_value| {
                    var summary = summary_value;
                    summary.deinit(alloc);
                }
            }
        }
        for (summaries) |*summary| try self.appendSummary(alloc, summary);
    }
};

/// `/fork`'s menu: the open session's prompts, oldest first (D58).
pub const ForkMenu = struct {
    points: []const session_adapter.Session.ForkPoint = &.{},
    selected: usize = 0,
    /// The first menu line shown. It starts past the end, which shows the
    /// newest prompts, and moves only as far as keeps the selection whole.
    window_start: usize = std.math.maxInt(usize),
    /// Once Enter chose a prompt where the session had subagents: those it
    /// had there, while the menu asks whether the fork takes copies of the
    /// ones it can (D97). Null while the prompts show.
    question: ?[]session_adapter.Child = null,

    pub fn active(self: *const ForkMenu) bool {
        return self.points.len > 0;
    }

    pub fn asking(self: *const ForkMenu) bool {
        return self.question != null;
    }

    /// Moves the selection, stopping at the oldest and the newest prompt.
    /// The question keeps the chosen prompt.
    pub fn move(self: *ForkMenu, delta: i32) void {
        if (self.points.len == 0 or self.asking()) return;
        const next = @as(i64, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.points.len - 1))));
    }

    pub fn close(self: *ForkMenu, alloc: Allocator) void {
        session_adapter.Session.freeForkPoints(alloc, self.points);
        if (self.question) |children| session_adapter.freeChildren(alloc, children);
        self.* = .{};
    }
};

test "the fork menu's question keeps the chosen prompt, and closing frees it (D97)" {
    const alloc = std.testing.allocator;
    const points = try alloc.alloc(session_adapter.Session.ForkPoint, 2);
    points[0] = .{ .turn = 1, .prompt = try alloc.dupe(u8, "first") };
    points[1] = .{ .turn = 2, .prompt = try alloc.dupe(u8, "second") };
    const children = try alloc.alloc(session_adapter.Child, 1);
    children[0] = .{
        .id = try alloc.dupe(u8, "kid"),
        .work_id = try alloc.dupe(u8, "w1"),
        .open = false,
        .outcome = .ok,
        .spawn_data = try alloc.dupe(u8, "{}"),
        .finish_data = null,
        .seq = 4,
    };
    var menu: ForkMenu = .{ .points = points, .selected = 1, .question = children };
    try std.testing.expect(menu.asking());
    menu.move(-1);
    try std.testing.expectEqual(@as(usize, 1), menu.selected);
    menu.close(alloc);
    try std.testing.expect(!menu.active() and !menu.asking());
}

pub const SessionPickerCatalogCache = struct {
    ready: bool = false,
    loaded_at_ns: i128 = 0,
    active_id: ?[]u8 = null,
    catalog: session_catalog_cache.ActionableSessionCatalog = .{},

    pub fn deinit(self: *SessionPickerCatalogCache) void {
        const alloc = std.heap.c_allocator;
        if (self.active_id) |id| alloc.free(id);
        self.catalog.deinit(alloc);
        self.* = .{};
    }

    pub fn matches(
        self: *const SessionPickerCatalogCache,
        active_id: ?[]const u8,
    ) bool {
        return self.ready and optionalStringEql(self.active_id, active_id);
    }

    pub fn isFresh(self: *const SessionPickerCatalogCache) bool {
        const now_ns = io_mod.nanoTimestamp();
        return self.ready and now_ns >= self.loaded_at_ns and
            now_ns - self.loaded_at_ns <= 5 * std.time.ns_per_s;
    }

    pub fn install(
        self: *SessionPickerCatalogCache,
        source: *session_catalog_cache.ActionableSessionCatalog,
        active_id: ?[]const u8,
    ) !void {
        return self.installAt(source, active_id, io_mod.nanoTimestamp());
    }

    fn installAt(
        self: *SessionPickerCatalogCache,
        source: *session_catalog_cache.ActionableSessionCatalog,
        active_id: ?[]const u8,
        loaded_at_ns: i128,
    ) !void {
        const alloc = std.heap.c_allocator;
        const owned_active_id = if (active_id) |id| try alloc.dupe(u8, id) else null;
        errdefer if (owned_active_id) |id| alloc.free(id);
        self.deinit();
        self.* = .{
            .ready = true,
            .loaded_at_ns = loaded_at_ns,
            .active_id = owned_active_id,
            .catalog = source.*,
        };
        source.* = .{};
    }
};

pub fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn replaceSessionPickerPage(
    picker: *SessionPicker,
    alloc: Allocator,
    source: *const session_store.ResumableSessionPage,
) !void {
    var replacement: std.ArrayList(session_store.SessionSummary) = .empty;
    errdefer {
        for (replacement.items) |*summary| summary.deinit(alloc);
        replacement.deinit(alloc);
    }
    for (source.summaries.items) |*summary| {
        if (!summary.hasResumableContent()) continue;
        var copied = try session_summary_codec.cloneSessionSummary(alloc, summary.*);
        replacement.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    for (picker.summaries.items) |*summary| summary.deinit(alloc);
    picker.summaries.deinit(alloc);
    picker.summaries = replacement;
}

pub fn applySessionPickerCatalogPage(
    picker: *SessionPicker,
    alloc: Allocator,
    cache: *const SessionPickerCatalogCache,
    workspace_root: []const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
    append: bool,
) !void {
    const workspace = if (picker.scope == .current_workspace) workspace_root else null;
    // Pages hold only the sessions the search lists, so the search reaches
    // the whole catalog and "Load more" appears only while matches remain.
    const query = picker.query();
    var selected_index: ?usize = null;
    var page_limit = limit;
    if (!append) {
        page_limit = @max(page_limit, picker.summaries.items.len);
        if (picker.selectedId()) |selected_id| {
            var index: usize = 0;
            const listed = session_catalog.pickerFilter(cache.catalog.summaries.items, workspace, query, .resumable);
            for (cache.catalog.summaries.items, 0..) |summary, position| {
                if (!listed.keeps(position)) continue;
                if (std.mem.eql(u8, summary.id, selected_id)) {
                    selected_index = index;
                    page_limit = @max(page_limit, index + 1);
                    break;
                }
                index += 1;
            }
        }
    }
    var page = try session_catalog.resumablePage(
        alloc,
        cache.catalog.summaries.items,
        workspace,
        query,
        continuation,
        page_limit,
    );
    defer page.deinit(alloc);
    var next: ?PickerContinuation = if (page.has_more and page.summaries.items.len > 0) blk: {
        const last = page.summaries.items[page.summaries.items.len - 1];
        break :blk .{
            .updated_at_ms = last.updated_at_ms,
            .id = try alloc.dupe(u8, last.id),
        };
    } else null;
    defer if (next) |*value| value.deinit(alloc);
    const previous_filtered_count = picker.filteredItemCount();
    const selected_load_more = append and
        picker.selected == previous_filtered_count;
    if (append) {
        try picker.appendPage(alloc, page.summaries.items);
    } else {
        try replaceSessionPickerPage(picker, alloc, &page);
    }
    if (picker.continuation) |*prior| prior.deinit(alloc);
    picker.continuation = next;
    next = null;
    picker.has_more = page.has_more;
    picker.loading_more = false;
    picker.load_state = .ready;
    if (!append) {
        if (selected_index) |index| picker.selected = index;
        picker.selected = @min(picker.selected, picker.filteredItemCount() -| 1);
        picker.window_start = @min(picker.window_start, picker.selected);
    } else if (selected_load_more) {
        picker.selected = selectionAfterLoadedPage(
            previous_filtered_count,
            picker.filteredItemCount(),
            picker.has_more,
        );
    }
}

pub fn selectionAfterLoadedPage(
    previous_filtered_count: usize,
    filtered_count: usize,
    has_more: bool,
) usize {
    if (filtered_count > previous_filtered_count) return previous_filtered_count;
    if (has_more) return filtered_count;
    return filtered_count -| 1;
}

pub const SessionPickerLoad = struct {
    pub const PageRequest = struct {
        generation: u64,
        active_id: ?[]u8 = null,

        pub fn init(
            generation: u64,
            active_id: ?[]const u8,
        ) !PageRequest {
            const alloc = std.heap.c_allocator;
            var request: PageRequest = .{ .generation = generation };
            errdefer request.deinit();
            if (active_id) |id| request.active_id = try alloc.dupe(u8, id);
            return request;
        }

        pub fn deinit(self: *PageRequest) void {
            if (self.active_id) |id| std.heap.c_allocator.free(id);
            self.* = undefined;
        }
    };

    /// Where a listing comes from (D26).
    pub const Source = struct { store: *session_adapter.Store, workspace_root: []const u8 };

    pub const Task = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        // Main-loop-owned; worker failures may also set cancel_requested.
        abandoned: bool = false,
        request: PageRequest,
        catalog: ?session_catalog_cache.ActionableSessionCatalog = null,
        /// Shared with the app, which joins this thread before freeing it.
        store: *session_adapter.Store,
        failure: ?anyerror = null,

        fn requestStop(self: *Task) void {
            if (!self.done.load(.acquire) and
                !self.cancel_requested.swap(true, .acq_rel))
            {
                debug_trace.logf(
                    "core",
                    "session picker load cancellation requested generation={d}",
                    .{self.request.generation},
                );
            }
        }

        pub fn deinit(self: *Task) void {
            self.requestStop();
            if (self.thread) |thread| thread.join();
            if (self.catalog) |*catalog| catalog.deinit(std.heap.c_allocator);
            self.request.deinit();
            std.heap.c_allocator.destroy(self);
        }
    };

    task: ?*Task = null,
    pending: ?PageRequest = null,
    next_generation: u64 = 1,

    pub fn deinit(self: *SessionPickerLoad) void {
        self.requestStop();
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    pub fn requestStop(self: *SessionPickerLoad) void {
        if (self.task) |task| task.requestStop();
        if (self.pending) |*pending| {
            debug_trace.logf(
                "core",
                "session picker request dropped reason=shutdown generation={d}",
                .{pending.generation},
            );
            pending.deinit();
            self.pending = null;
        }
    }

    pub fn allocateGeneration(self: *SessionPickerLoad) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }

    pub fn schedule(
        self: *SessionPickerLoad,
        source: Source,
        request: PageRequest,
    ) !void {
        if (self.task != null) {
            self.replacePending(request);
            return;
        }
        try self.start(source, request);
    }

    fn replacePending(self: *SessionPickerLoad, request: PageRequest) void {
        if (self.pending) |*pending| {
            debug_trace.logf(
                "core",
                "session picker request dropped reason=superseded generation={d}",
                .{pending.generation},
            );
            pending.deinit();
        }
        self.pending = request;
    }

    pub fn cancelGeneration(self: *SessionPickerLoad, generation: u64) void {
        if (self.task) |task| {
            if (task.request.generation == generation) {
                task.abandoned = true;
                task.requestStop();
                debug_trace.logf(
                    "core",
                    "session picker request abandoned reason=cancelled generation={d}",
                    .{generation},
                );
            }
        }
        if (self.pending) |pending| {
            if (pending.generation == generation) {
                debug_trace.logf(
                    "core",
                    "session picker request dropped reason=cancelled generation={d}",
                    .{generation},
                );
                var owned = self.pending.?;
                self.pending = null;
                owned.deinit();
            }
        }
    }

    pub fn pendingGeneration(self: *const SessionPickerLoad) ?u64 {
        return if (self.pending) |request| request.generation else null;
    }

    pub fn matchingInitialGeneration(
        self: *const SessionPickerLoad,
        active_id: ?[]const u8,
    ) ?u64 {
        if (self.task) |task| {
            if (!task.abandoned and
                optionalStringEql(task.request.active_id, active_id))
            {
                return task.request.generation;
            }
        }
        if (self.pending) |request| {
            if (optionalStringEql(request.active_id, active_id)) {
                return request.generation;
            }
        }
        return null;
    }

    pub fn startPending(self: *SessionPickerLoad, source: Source) !?u64 {
        const request = self.pending orelse return null;
        self.pending = null;
        const generation = request.generation;
        try self.start(source, request);
        return generation;
    }

    pub fn start(
        self: *SessionPickerLoad,
        source: Source,
        request: PageRequest,
    ) !void {
        std.debug.assert(self.task == null);

        const alloc = std.heap.c_allocator;
        var owned_request = request;
        const task = alloc.create(Task) catch |err| {
            owned_request.deinit();
            return err;
        };
        task.* = .{ .request = owned_request, .store = source.store };
        task.thread = std.Thread.spawn(.{}, threadMain, .{task}) catch |err| {
            task.request.deinit();
            alloc.destroy(task);
            return err;
        };
        self.task = task;
    }

    pub fn takeCompleted(self: *SessionPickerLoad) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task;
    }

    fn threadMain(task: *Task) void {
        defer task.done.store(true, .release);
        const started = io_mod.nanoTimestamp();
        const summaries = session_adapter.listSummaries(
            task.store,
            std.heap.c_allocator,
            task.request.active_id,
            &task.cancel_requested,
        ) catch |err| {
            debug_trace.logf("core", "session picker catalog stopped err={s}", .{@errorName(err)});
            task.failure = err;
            return;
        };
        task.catalog = .{ .summaries = summaries };
        debug_trace.logf("core", "session picker catalog loaded sessions={d} elapsed_us={d}", .{ summaries.items.len, @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_us) });
    }
};

/// Runs session open/fork and durable state decoding off the UI thread so
/// selecting a session in `fx -r` or `/resume` paints a working state at once
/// (`RULES.md` R2.1).
pub const SessionPickerResume = struct {
    pub const Request = struct {
        action: SessionPickerAction,
        session_id: []u8,
        title: []u8,
        workspace_root: []u8,

        pub fn init(
            action: SessionPickerAction,
            session_id: []const u8,
            title: []const u8,
            workspace_root: []const u8,
        ) !Request {
            const alloc = std.heap.c_allocator;
            const id = try alloc.dupe(u8, session_id);
            errdefer alloc.free(id);
            const title_copy = try alloc.dupe(u8, title);
            errdefer alloc.free(title_copy);
            const workspace = try alloc.dupe(u8, workspace_root);
            return .{
                .action = action,
                .session_id = id,
                .title = title_copy,
                .workspace_root = workspace,
            };
        }

        pub fn deinit(self: *Request) void {
            const alloc = std.heap.c_allocator;
            alloc.free(self.session_id);
            alloc.free(self.title);
            alloc.free(self.workspace_root);
            self.* = undefined;
        }
    };

    pub const Prepared = struct {
        v2: *session_adapter.Session,
        resumed: session_adapter.Resumed,
        forked_from: ?[]u8 = null,

        pub fn deinit(self: *Prepared) void {
            const alloc = std.heap.c_allocator;
            self.v2.close();
            self.resumed.deinit(alloc);
            if (self.forked_from) |id| alloc.free(id);
            self.* = undefined;
        }
    };

    pub const Outcome = union(enum) {
        none,
        cancelled,
        busy: struct { pid: ?u32 },
        ready: Prepared,
        failed: anyerror,
    };

    pub const Task = struct {
        future: ?std.Io.Future(void) = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        abandoned: bool = false,
        request: Request,
        /// Shared with Persistence, which awaits this task before freeing store.
        store: *session_adapter.Store,
        outcome: Outcome = .none,

        pub fn requestStop(self: *Task) void {
            self.cancel_requested.store(true, .release);
        }

        /// Removes a newly created fork if the user cancelled or closed the
        /// picker before it was installed, so cancelled forks do not stay listed.
        pub fn discardAbandonedFork(self: *Task) void {
            if (comptime host_target.is_wasm) return;
            if (self.request.action != .forking) return;
            switch (self.outcome) {
                .ready => |*prepared| {
                    var id_buf: [64]u8 = undefined;
                    const raw_id = prepared.v2.id();
                    const copy_len = @min(raw_id.len, id_buf.len);
                    @memcpy(id_buf[0..copy_len], raw_id[0..copy_len]);
                    const fork_id = id_buf[0..copy_len];
                    prepared.deinit();
                    self.outcome = .none;
                    self.store.manager.delete(fork_id) catch |err| {
                        debug_trace.logf(
                            "session",
                            "picker cancelled fork cleanup failed id={s} err={s}",
                            .{ fork_id, @errorName(err) },
                        );
                    };
                },
                else => {},
            }
        }

        pub fn deinit(self: *Task) void {
            self.requestStop();
            if (self.future) |*future| future.await(io_mod.getIo());
            if (comptime !host_target.is_wasm) {
                if (self.abandoned) self.discardAbandonedFork();
                switch (self.outcome) {
                    .ready => |*prepared| prepared.deinit(),
                    else => {},
                }
            }
            self.request.deinit();
            std.heap.c_allocator.destroy(self);
        }

        fn run(self: *Task) void {
            defer self.done.store(true, .release);
            const alloc = std.heap.c_allocator;
            const started = io_mod.nanoTimestamp();
            if (self.cancel_requested.load(.acquire)) {
                self.outcome = .cancelled;
                return;
            }
            const v2 = switch (self.request.action) {
                .opening => session_adapter.Session.resumeSessionWithoutWaiting(
                    alloc,
                    self.store,
                    .{ .id = self.request.session_id },
                    self.request.workspace_root,
                    .app,
                ) catch |err| {
                    if (err == error.SessionBusy) {
                        const pid = self.store.lockHolderPid(self.request.session_id);
                        debug_trace.logf("session", "picker open busy session={s} pid={?d}", .{ self.request.session_id, pid });
                        self.outcome = .{ .busy = .{ .pid = pid } };
                        return;
                    }
                    self.outcome = .{ .failed = err };
                    return;
                },
                .forking => session_adapter.Session.forkLatest(
                    alloc,
                    self.store,
                    self.request.session_id,
                    self.request.workspace_root,
                    .app,
                    if (self.request.title.len > 0) self.request.title else null,
                ) catch |err| {
                    self.outcome = .{ .failed = err };
                    return;
                },
            };
            var v2_owned = true;
            defer if (v2_owned) {
                var id_buf: [64]u8 = undefined;
                const delete_fork = self.request.action == .forking and self.cancel_requested.load(.acquire);
                const raw_id = v2.id();
                const copy_len = @min(raw_id.len, id_buf.len);
                if (delete_fork) @memcpy(id_buf[0..copy_len], raw_id[0..copy_len]);
                v2.close();
                if (delete_fork) {
                    const fork_id = id_buf[0..copy_len];
                    self.store.manager.delete(fork_id) catch |err| {
                        debug_trace.logf(
                            "session",
                            "picker cancelled fork cleanup failed id={s} err={s}",
                            .{ fork_id, @errorName(err) },
                        );
                    };
                }
            };
            if (self.cancel_requested.load(.acquire)) {
                self.outcome = .cancelled;
                return;
            }
            var resumed = v2.durableState(alloc, self.request.workspace_root) catch |err| {
                self.outcome = .{ .failed = err };
                return;
            };
            var resumed_owned = true;
            defer if (resumed_owned) resumed.deinit(alloc);
            if (self.cancel_requested.load(.acquire)) {
                self.outcome = .cancelled;
                return;
            }
            const forked_from: ?[]u8 = if (self.request.action == .forking)
                alloc.dupe(u8, self.request.session_id) catch |err| {
                    self.outcome = .{ .failed = err };
                    return;
                }
            else
                null;
            v2_owned = false;
            resumed_owned = false;
            debug_trace.logf(
                "session",
                "picker prepare ready action={s} session={s} turns={d} elapsed_us={d}",
                .{
                    @tagName(self.request.action),
                    v2.id(),
                    resumed.state.history.len,
                    @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_us),
                },
            );
            self.outcome = .{ .ready = .{
                .v2 = v2,
                .resumed = resumed,
                .forked_from = forked_from,
            } };
        }
    };

    task: ?*Task = null,

    pub fn busy(self: *const SessionPickerResume) bool {
        return self.task != null;
    }

    pub fn start(
        self: *SessionPickerResume,
        store: *session_adapter.Store,
        request: Request,
    ) !void {
        if (comptime host_target.is_wasm) {
            var owned_unused = request;
            owned_unused.deinit();
            return error.SessionPersistenceUnavailable;
        }
        if (self.task != null) return error.SessionPickerResumeBusy;
        const alloc = std.heap.c_allocator;
        var owned = request;
        const task = alloc.create(Task) catch |err| {
            owned.deinit();
            return err;
        };
        task.* = .{ .request = owned, .store = store };
        if (comptime builtin.single_threaded) {
            task.run();
        } else {
            task.future = io_mod.getIo().concurrent(Task.run, .{task}) catch |err| {
                task.request.deinit();
                alloc.destroy(task);
                return err;
            };
        }
        self.task = task;
    }

    pub fn cancel(self: *SessionPickerResume) void {
        if (self.task) |task| {
            task.abandoned = true;
            task.requestStop();
        }
    }

    pub fn takeCompleted(self: *SessionPickerResume) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        if (task.future) |*future| future.await(io_mod.getIo());
        task.future = null;
        self.task = null;
        return task;
    }

    pub fn deinit(self: *SessionPickerResume) void {
        if (self.task) |task| {
            self.task = null;
            task.deinit();
        }
        self.* = .{};
    }
};

pub const TitleGenerationLoad = struct {
    task: ?*session_title_generation.Task = null,
    last: LastResult = .{},
    /// The session whose title request started. The gate checks it, because
    /// a first turn the next prompt interrupts reaches the history only after
    /// that prompt starts (tests/tla/session_title/SessionTitle.tla
    /// AtMostOneTitleRequest).
    started_session_buf: [LastResult.max_session_bytes]u8 = undefined,
    started_session_len: u8 = 0,

    /// Final state of the most recent attempt, retained for diagnostics after
    /// the task itself is destroyed. `detail` is a static string borrowed from
    /// the task; the model and session id are copied into fixed buffers.
    const LastResult = struct {
        status: Status = .none,
        reason: ?session_title_generation.FailureReason = null,
        detail: []const u8 = "",
        elapsed_ms: i64 = -1,
        model_buf: [max_model_bytes]u8 = undefined,
        model_len: u8 = 0,
        session_buf: [max_session_bytes]u8 = undefined,
        session_len: u8 = 0,

        const max_model_bytes = 128;
        const max_session_bytes = 64;

        pub fn model(self: *const LastResult) []const u8 {
            return self.model_buf[0..self.model_len];
        }

        pub fn sessionId(self: *const LastResult) []const u8 {
            return self.session_buf[0..self.session_len];
        }

        fn copyIds(self: *LastResult, session_id: []const u8, title_model: []const u8) void {
            const model_len: u8 = @intCast(@min(title_model.len, max_model_bytes));
            @memcpy(self.model_buf[0..model_len], title_model[0..model_len]);
            self.model_len = model_len;
            const session_len: u8 = @intCast(@min(session_id.len, max_session_bytes));
            @memcpy(self.session_buf[0..session_len], session_id[0..session_len]);
            self.session_len = session_len;
        }
    };

    pub const Status = enum { none, installed, dropped, failed };

    pub fn deinit(self: *TitleGenerationLoad) void {
        if (self.task) |task| {
            debug_trace.logf("session", "event=title_generation_dropped reason=deinit", .{});
            task.destroy();
        }
        self.* = .{};
    }

    pub fn requestStop(self: *TitleGenerationLoad) void {
        if (self.task) |task| task.cancel();
    }

    pub fn start(self: *TitleGenerationLoad, task: *session_title_generation.Task) void {
        if (self.task) |old| {
            debug_trace.logf("session", "event=title_generation_dropped reason=superseded session={s}", .{old.session_id});
            old.destroy();
        }
        self.task = task;
        self.recordStarted(task.session_id);
    }

    /// Whether `session_id` already started a title request.
    pub fn startedFor(self: *const TitleGenerationLoad, session_id: []const u8) bool {
        return self.started_session_len > 0 and
            std.mem.eql(u8, self.started_session_buf[0..self.started_session_len], session_id);
    }

    fn recordStarted(self: *TitleGenerationLoad, session_id: []const u8) void {
        if (session_id.len == 0 or session_id.len > self.started_session_buf.len) {
            debug_trace.logf("session", "event=title_generation_start_unrecorded reason=session_id_len len={d}", .{session_id.len});
            self.started_session_len = 0;
            return;
        }
        @memcpy(self.started_session_buf[0..session_id.len], session_id);
        self.started_session_len = @intCast(session_id.len);
    }

    pub fn recordSpawnFailure(self: *TitleGenerationLoad, session_id: []const u8, model: []const u8, err: anyerror) void {
        self.recordStarted(session_id);
        var last = LastResult{
            .status = .failed,
            .reason = .spawn_failed,
            .detail = @errorName(err),
            .elapsed_ms = 0,
        };
        last.copyIds(session_id, model);
        self.last = last;
    }

    /// Snapshots a finished task's outcome before the caller destroys it.
    pub fn recordFinished(self: *TitleGenerationLoad, task: *session_title_generation.Task) void {
        var last = LastResult{
            .status = switch (task.status) {
                .generated => .installed,
                .pending, .unavailable => .failed,
            },
            .elapsed_ms = if (task.started_at_ms > 0 and task.finished_at_ms >= task.started_at_ms)
                task.finished_at_ms - task.started_at_ms
            else
                -1,
        };
        if (task.status == .unavailable) {
            last.reason = task.failure_reason;
            last.detail = task.failure_detail;
        }
        last.copyIds(task.session_id, task.model);
        self.last = last;
    }

    /// Marks that a generated title was dropped while being applied.
    pub fn recordDropped(self: *TitleGenerationLoad, reason: session_title_generation.FailureReason, detail: []const u8) void {
        if (self.last.status != .installed) return;
        self.last.status = .dropped;
        self.last.reason = reason;
        self.last.detail = detail;
    }

    pub fn takeCompleted(self: *TitleGenerationLoad) ?*session_title_generation.Task {
        const task = self.task orelse return null;
        if (!task.isDone()) return null;
        self.task = null;
        return task;
    }
};

pub fn resumePageLimitForRows(rows: u16) usize {
    // Fill the resume screen: terminal rows minus the composer/divider/hint
    // chrome (4), the menu header (1), the top gap (1), and a trailing
    // "Load more" row (1). Floored so short terminals still page usefully.
    return @max(@as(usize, rows -| 7), session_store.default_resume_page_limit);
}

pub const JsHostSessionStore = struct {
    ctx: ?*anyopaque = null,
    load_fn: *const fn (?*anyopaque, Allocator, []const u8) anyerror!?js_host_session_store.Loaded = if (host_target.is_wasm) loadDefault else loadUnavailable,
    commit_fn: *const fn (?*anyopaque, Allocator, session_codec.DurableSessionState, ?[]const u8) anyerror![]u8 = if (host_target.is_wasm) commitDefault else commitUnavailable,
    list_fn: *const fn (?*anyopaque, Allocator) anyerror![]js_host_session_store.Metadata = if (host_target.is_wasm) listDefault else listUnavailable,

    pub fn load(self: JsHostSessionStore, alloc: Allocator, id: []const u8) !?js_host_session_store.Loaded {
        return self.load_fn(self.ctx, alloc, id);
    }

    pub fn commit(
        self: JsHostSessionStore,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        return self.commit_fn(self.ctx, alloc, state, expected_revision);
    }

    pub fn list(self: JsHostSessionStore, alloc: Allocator) ![]js_host_session_store.Metadata {
        return self.list_fn(self.ctx, alloc);
    }

    fn loadDefault(_: ?*anyopaque, alloc: Allocator, id: []const u8) !?js_host_session_store.Loaded {
        return js_host_session_store.load(alloc, id);
    }

    fn commitDefault(
        _: ?*anyopaque,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        return js_host_session_store.commit(alloc, state, expected_revision);
    }

    fn listDefault(_: ?*anyopaque, alloc: Allocator) ![]js_host_session_store.Metadata {
        return js_host_session_store.list(alloc);
    }

    fn loadUnavailable(_: ?*anyopaque, _: Allocator, _: []const u8) !?js_host_session_store.Loaded {
        return error.SessionStoreUnavailable;
    }

    fn commitUnavailable(
        _: ?*anyopaque,
        _: Allocator,
        _: session_codec.DurableSessionState,
        _: ?[]const u8,
    ) ![]u8 {
        return error.SessionStoreUnavailable;
    }

    fn listUnavailable(_: ?*anyopaque, _: Allocator) ![]js_host_session_store.Metadata {
        return error.SessionStoreUnavailable;
    }
};

const JsHostSessionOwner = struct {
    state: session_codec.DurableSessionState,
    revision: ?[]u8,

    pub fn deinit(self: *JsHostSessionOwner, alloc: Allocator) void {
        self.state.deinit(alloc);
        if (self.revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

pub const PendingCancelledCommand = struct {
    lifecycle_id: types.ToolLifecycleId,
    command_artifact_handle: ?[]u8 = null,

    pub fn matches(self: PendingCancelledCommand, id: types.ToolLifecycleId) bool {
        return self.lifecycle_id.turn_id == id.turn_id and
            std.mem.eql(u8, self.lifecycle_id.call_id, id.call_id);
    }

    pub fn discard(self: *PendingCancelledCommand, alloc: Allocator) void {
        alloc.free(@constCast(self.lifecycle_id.call_id));
        if (self.command_artifact_handle) |handle| alloc.free(handle);
        self.* = undefined;
    }
};

/// The boundaries of the older compaction cycles, found walking back from
/// the held one as Ctrl+O reads older, so each cycle is found once.
pub const TranscriptArchiveBoundaries = struct {
    /// The newest compaction, and whether the transcript window held the
    /// cycle before it, when the walk started: a change starts it over.
    key: ?struct { newest: session_adapter.LogCursor, holds_previous: bool } = null,
    /// Where the held entries start: the end of cycle 1 back.
    held_start: ?session_adapter.LogCursor = null,
    /// `starts[k - 1]` is where cycle `k` back starts, and so where cycle
    /// `k + 1` ends; null at the log's start.
    starts: std.ArrayList(?session_adapter.LogCursor) = .empty,
    /// The first cycle back whose start a damaged log line hid: it and every
    /// older cycle Ctrl+O shows may be missing turns.
    damaged_from: ?u32 = null,

    /// Records that finding where cycle `back` starts stopped at a damaged
    /// line, and returns the start to use: none, the log's start.
    pub fn startOf(self: *TranscriptArchiveBoundaries, back: u32, found: session_adapter.Session.PreviousCompaction) ?session_adapter.LogCursor {
        if (found.damaged and self.damaged_from == null) self.damaged_from = back;
        return found.cursor;
    }

    pub fn damages(self: *const TranscriptArchiveBoundaries, back: u32) bool {
        const from = self.damaged_from orelse return false;
        return back >= from;
    }

    pub fn deinit(self: *TranscriptArchiveBoundaries, alloc: Allocator) void {
        self.starts.deinit(alloc);
        self.* = .{};
    }
};

/// Reads one older compaction cycle of the session log for Ctrl+O on a
/// background thread (`loadTranscriptArchive`), so the main thread only
/// replays the turns it read. One read at a time. The task and its turns use
/// `std.heap.c_allocator`, which any thread can free with.
pub const TranscriptArchiveRead = struct {
    task: ?*Task = null,

    /// What a read is for, which the main thread checks when it finishes.
    pub const Request = struct {
        /// Cycles before the held entries: 1 is the newest older one.
        back: u32,
        /// The compaction line the cycle opens at, or null at the log's start.
        start: ?session_adapter.LogCursor,
        /// The transcript's archive generation when the read started: a
        /// compaction, resume, or drop since then makes the read stale.
        generation: u64,
    };

    pub const Task = struct {
        /// The read's `std.Io` task, which `completed` and `cancel` await.
        future: ?std.Io.Future(void) = null,
        done: std.atomic.Value(bool) = .init(false),
        cancel_requested: std.atomic.Value(bool) = .init(false),
        reader: session_adapter.CycleReader,
        request: Request,
        started_ns: i128,
        read_ns: i128 = 0,
        /// The cycle's turns, oldest first, owned by the task.
        turns: std.ArrayList(types.HistoryTurn) = .empty,
        /// Reading stopped at a damaged line, so turns are missing.
        damaged: bool = false,
        failure: ?anyerror = null,
        /// The main thread's replay of the turns read, which runs a few
        /// turns per loop turn so no frame waits for the whole cycle. The
        /// app owns its state and frees it through `deinit_fn`.
        replay: ?Replay = null,

        pub const Replay = struct {
            state: *anyopaque,
            deinit_fn: *const fn (*anyopaque) void,
        };

        const alloc = std.heap.c_allocator;

        fn run(self: *Task) void {
            defer self.done.store(true, .release);
            const Visitor = struct {
                task: *Task,

                pub fn append(visitor: *@This(), turn: types.HistoryTurn) !void {
                    if (visitor.task.cancel_requested.load(.acquire)) return error.TranscriptArchiveReadCancelled;
                    try visitor.task.turns.ensureUnusedCapacity(alloc, 1);
                    visitor.task.turns.appendAssumeCapacity(try types.dupeHistoryTurn(alloc, turn));
                }
            };
            var visitor = Visitor{ .task = self };
            self.damaged = self.reader.visitHistoryCycle(alloc, self.request.start, &visitor) catch |err| blk: {
                self.failure = err;
                break :blk false;
            };
            self.read_ns = io_mod.nanoTimestamp() - self.started_ns;
        }

        pub fn deinit(self: *Task) void {
            if (self.replay) |replay| replay.deinit_fn(replay.state);
            for (self.turns.items) |turn| types.freeHistoryTurn(alloc, turn);
            self.turns.deinit(alloc);
            self.reader.deinit();
            alloc.destroy(self);
        }
    };

    /// Whether a read for `back` at `generation` is running or waits to be
    /// taken.
    pub fn pendingFor(self: *const TranscriptArchiveRead, back: u32, generation: u64) bool {
        const task = self.task orelse return false;
        return task.request.back == back and task.request.generation == generation;
    }

    pub fn busy(self: *const TranscriptArchiveRead) bool {
        return self.task != null;
    }

    /// Starts reading with `reader`, which the task takes, after stopping
    /// any read already running. Without threads the read runs here.
    pub fn start(self: *TranscriptArchiveRead, reader: session_adapter.CycleReader, request: Request) !void {
        self.cancel();
        var owned_reader = reader;
        const task = Task.alloc.create(Task) catch |err| {
            owned_reader.deinit();
            return err;
        };
        task.* = .{ .reader = owned_reader, .request = request, .started_ns = io_mod.nanoTimestamp() };
        if (comptime builtin.single_threaded or host_target.is_wasm) {
            task.run();
        } else {
            task.future = io_mod.getIo().concurrent(Task.run, .{task}) catch |err| {
                task.deinit();
                return err;
            };
        }
        self.task = task;
    }

    /// The finished read, which stays here, and busy, while the main thread
    /// replays its turns; `finish` frees it.
    pub fn completed(self: *TranscriptArchiveRead) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        if (task.future) |*future| future.await(io_mod.getIo());
        task.future = null;
        return task;
    }

    /// Drops a finished read that started at another archive generation,
    /// which a compaction, resume, drop, or clear made stale. Returns
    /// whether it dropped one.
    pub fn dropIfStale(self: *TranscriptArchiveRead, generation: u64) bool {
        const task = self.completed() orelse return false;
        if (task.request.generation == generation) return false;
        debug_trace.logf("full_transcript_cache", "archive_read_dropped back={d} reason=stale turns={d}", .{ task.request.back, task.turns.items.len });
        self.finish();
        return true;
    }

    /// Frees the finished read `completed` returned.
    pub fn finish(self: *TranscriptArchiveRead) void {
        const task = self.task orelse return;
        std.debug.assert(task.future == null);
        self.task = null;
        task.deinit();
    }

    /// Stops a running read and waits for its task. The turns it read are
    /// dropped; the log keeps them.
    pub fn cancel(self: *TranscriptArchiveRead) void {
        const task = self.task orelse return;
        self.task = null;
        task.cancel_requested.store(true, .release);
        if (task.future) |*future| future.await(io_mod.getIo());
        debug_trace.logf("full_transcript_cache", "archive_read_dropped back={d} reason=cancelled turns={d}", .{ task.request.back, task.turns.items.len });
        task.deinit();
    }
};

pub const Persistence = struct {
    // Serializes event-log mutations with worker usage callbacks. Usage takes
    // its checkpoint mutex first, so callers must not checkpoint while held.
    // UI compaction publication takes worker_mutex before this mutex.
    write_mutex: std.Io.Mutex = .init,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    /// The v2 session's children (D22), borrowed by `subagent_host`.
    v2_children: ?*subagent_child_state.V2Children = null,
    workspace_preferences: ?session_codec.DurableSessionPreferences = null,
    session_preferences: ?session_codec.DurableSessionPreferences = null,
    /// What the session `/new` replaces had saved, read just before that
    /// session closes; the new session starts with it.
    next_session_preferences: ?session_codec.DurableSessionPreferences = null,
    fast_mode_model_bound: bool = false,
    /// `experimental.workspace_capture`, from startup.
    workspace_capture: bool = false,
    /// The current turn's workspace captures (D98).
    turn_capture: turn_capture.TurnCapture = .{},
    /// Forks' capture copies still running or not yet reaped, off the UI
    /// thread (D98); finished at teardown.
    fork_copies: std.ArrayList(*turn_capture.ForkCopy) = .empty,
    js_host_store: JsHostSessionStore = .{},
    js_host_session: ?JsHostSessionOwner = null,
    process_provider_override: ?model_provider.ProviderId = null,
    process_model_override: ?[]u8 = null,
    process_effort_override: ?types.ReasoningEffort = null,
    process_fast_override: ?bool = null,
    process_ultrafast_override: ?bool = null,
    session_picker: SessionPicker = .{},
    session_picker_load: SessionPickerLoad = .{},
    session_picker_resume: SessionPickerResume = .{},
    session_picker_cache: SessionPickerCatalogCache = .{},
    fork_menu: ForkMenu = .{},
    /// How many subagent tasks the last switch stopped, for its notice in
    /// the session it opens (D97).
    switch_stopped_tasks: usize = 0,
    title_generation: TitleGenerationLoad = .{},
    degraded_warning_emitted: bool = false,
    pending_cancelled_command: ?PendingCancelledCommand = null,
    /// Where the older compaction cycles Ctrl+O read start in the session log
    /// (`loadTranscriptArchive`).
    transcript_archive_boundaries: TranscriptArchiveBoundaries = .{},
    /// The background read of the cycle Ctrl+O asked for.
    transcript_archive_read: TranscriptArchiveRead = .{},
    image_snapshot_temp_dir: ?[]u8 = null,
    resume_handoff_intent: ResumeHandoffIntent = .none,
    pending_live_session_policy: ?BackgroundSessionPolicy = null,
    pending_live_session_wait: ?LiveSessionWait = null,
    /// The request the resumed session's newest turn left unfinished, which
    /// `startPendingResume` sends again once the worker runs.
    pending_request_resume: ?types.RecoveryResume = null,
    /// Plain `fx` checks, once its first frame is on screen, whether the
    /// session `fx -c` opens left a turn unfinished.
    interrupted_turn_hint_pending: bool = false,
    shutdown_failure: ?anyerror = null,
    /// On the heap, so the pointer every session keeps survives `App.init`
    /// copying the app after it opens the store (`adoptStore`).
    v2_store: ?*session_adapter.Store = null,
    v2: ?*session_adapter.Session = null,

    /// Fieldwise initialization avoids retaining undefined optional payloads
    /// in a static release-binary template.
    pub fn initInto(storage: *Persistence) void {
        comptime {
            if (@typeInfo(Persistence).@"struct".field_names.len != 37) {
                @compileError("update Persistence.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.write_mutex = .init;
        storage.subagent_host = null;
        storage.v2_children = null;
        storage.workspace_preferences = null;
        storage.session_preferences = null;
        storage.next_session_preferences = null;
        storage.fast_mode_model_bound = false;
        storage.workspace_capture = false;
        storage.turn_capture = .{};
        storage.fork_copies = .empty;
        storage.js_host_store = .{};
        storage.js_host_session = null;
        storage.process_provider_override = null;
        storage.process_model_override = null;
        storage.process_effort_override = null;
        storage.process_fast_override = null;
        storage.process_ultrafast_override = null;
        storage.session_picker = .{};
        storage.session_picker_load = .{};
        storage.session_picker_resume = .{};
        storage.session_picker_cache = .{};
        storage.fork_menu = .{};
        storage.switch_stopped_tasks = 0;
        storage.title_generation = .{};
        storage.degraded_warning_emitted = false;
        storage.pending_cancelled_command = null;
        storage.transcript_archive_boundaries = .{};
        storage.transcript_archive_read = .{};
        storage.image_snapshot_temp_dir = null;
        storage.resume_handoff_intent = .none;
        storage.pending_live_session_policy = null;
        storage.pending_live_session_wait = null;
        storage.pending_request_resume = null;
        storage.interrupted_turn_hint_pending = false;
        storage.shutdown_failure = null;
        storage.v2_store = null;
        storage.v2 = null;
    }

    pub fn deinit(self: *Persistence, alloc: Allocator) void {
        self.deinitWithCatalog(alloc, .free);
    }

    /// Copies a fork's workspace captures as a `std.Io` task, so the fork
    /// never waits on git (D98), and frees the copies already done.
    pub fn startForkCaptureCopy(self: *Persistence, alloc: Allocator, home: []const u8, source_id: []const u8, fork: *session_adapter.Session, copies: []const session_adapter.Session.ChildCopy) void {
        var kept: usize = 0;
        for (self.fork_copies.items) |copy| {
            if (copy.done()) {
                copy.finish();
            } else {
                self.fork_copies.items[kept] = copy;
                kept += 1;
            }
        }
        self.fork_copies.shrinkRetainingCapacity(kept);
        const task = turn_capture.ForkCopy.start(home, source_id, fork, copies) orelse return;
        self.fork_copies.append(alloc, task) catch |err| {
            debug_trace.logf("workspace", "event=workspace_capture_fork_refs_awaited err={s}", .{@errorName(err)});
            task.finish();
        };
    }

    /// Process exit leaves the session picker catalog to the exiting process;
    /// freeing thousands of cached sessions one by one only delays exit.
    pub fn deinitForProcessExit(self: *Persistence, alloc: Allocator) void {
        self.deinitWithCatalog(alloc, .abandon);
    }

    fn deinitWithCatalog(self: *Persistence, alloc: Allocator, catalog: enum { free, abandon }) void {
        if (self.pending_request_resume != null) {
            debug_trace.logf("recovery", "event=resume_dropped reason=deinit", .{});
        }
        if (self.pending_live_session_policy) |policy| {
            debug_trace.logf(
                "session",
                "event=live_session_transition_discard reason=deinit policy={s}",
                .{@tagName(policy)},
            );
        }
        if (self.pending_cancelled_command) |*pending| pending.discard(alloc);
        if (self.image_snapshot_temp_dir) |path| {
            image_attachments.cleanupSnapshotDir(path);
            alloc.free(path);
        }
        if (self.subagent_host) |host| host.deinit();
        if (self.v2_children) |children| {
            children.deinit();
            alloc.destroy(children);
        }
        // Before the session closes: a start capture still running uses it.
        self.turn_capture.deinit();
        if (self.v2) |v2| v2.close();
        for (self.fork_copies.items) |copy| copy.finish();
        self.fork_copies.deinit(alloc);
        if (self.workspace_preferences) |*preferences| preferences.deinit(alloc);
        if (self.session_preferences) |*preferences| preferences.deinit(alloc);
        if (self.next_session_preferences) |*preferences| preferences.deinit(alloc);
        if (self.js_host_session) |*owner| owner.deinit(alloc);
        if (self.process_model_override) |model| alloc.free(model);
        self.session_picker.deinit(alloc);
        self.session_picker_load.deinit();
        self.session_picker_resume.deinit();
        if (catalog == .free) self.session_picker_cache.deinit();
        self.fork_menu.close(alloc);
        self.title_generation.deinit();
        // Before the store, which the read's reader reads through.
        self.transcript_archive_read.cancel();
        self.transcript_archive_boundaries.deinit(alloc);
        // After the picker thread, which lists through it, has joined.
        if (self.v2_store) |store| {
            store.deinit(alloc);
            alloc.destroy(store);
        }
        self.* = undefined;
    }

    /// Takes `store` and keeps it at a stable address. Sessions point at
    /// their store, and `App.init` copies the app after opening it.
    pub fn adoptStore(self: *Persistence, alloc: Allocator, store: session_adapter.Store) !*session_adapter.Store {
        var value = store;
        const owned = alloc.create(session_adapter.Store) catch |err| {
            value.deinit(alloc);
            return err;
        };
        owned.* = value;
        self.v2_store = owned;
        return owned;
    }
};

test "persistence in-place initialization preserves empty ownership" {
    var persistence: Persistence = undefined;
    Persistence.initInto(&persistence);
    defer persistence.deinit(std.testing.allocator);

    try std.testing.expect(persistence.v2_store == null);
    try std.testing.expect(persistence.v2 == null);
    try std.testing.expect(persistence.subagent_host == null);
    try std.testing.expect(!persistence.fast_mode_model_bound);
    try std.testing.expect(!persistence.session_picker.active);
    try std.testing.expect(persistence.session_picker_load.task == null);
    try std.testing.expect(!persistence.session_picker_cache.ready);
    try std.testing.expect(persistence.resume_handoff_intent == .none);
}

/// A saved session with `turns` turns in one compaction cycle, for the
/// Ctrl+O archive read tests.
const ArchiveReadTestHome = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    store: session_adapter.Store,
    session: *session_adapter.Session,
    model: [1]u8 = "m".*,

    fn init(self: *ArchiveReadTestHome, turns: usize) !void {
        const alloc = std.testing.allocator;
        self.* = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }), .home = undefined, .store = undefined, .session = undefined };
        errdefer self.tmp.cleanup();
        self.home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        errdefer alloc.free(self.home);
        self.store = try session_adapter.Store.open(alloc, self.home);
        errdefer self.store.deinit(alloc);
        self.session = try session_adapter.Session.create(alloc, &self.store, "/w", .ask, .{
            .preferences = .{ .model = &self.model, .effort = .auto, .fast_mode = false },
            .language = types.ConversationLanguage.default(),
            .permission_state = .{},
        });
        errdefer self.session.close();
        for (0..turns) |_| {
            try self.session.commitTurn(.{ .assistant = .{
                .user = .{ .text = @constCast("question") },
                .assistant = @constCast("answer"),
            } }, types.ConversationLanguage.default());
        }
    }

    fn deinit(self: *ArchiveReadTestHome) void {
        self.session.close();
        self.store.deinit(std.testing.allocator);
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn start(self: *ArchiveReadTestHome, read: *TranscriptArchiveRead, generation: u64) !void {
        try read.start(try self.session.cycleReader(std.heap.c_allocator), .{ .back = 1, .start = null, .generation = generation });
    }
};

fn waitForArchiveRead(read: *TranscriptArchiveRead) !*TranscriptArchiveRead.Task {
    for (0..5000) |_| {
        if (read.completed()) |task| return task;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestArchiveReadTimedOut;
}

test "a finished Ctrl+O archive read at an older generation is dropped, and one at the current generation stays" {
    var home: ArchiveReadTestHome = undefined;
    try home.init(2);
    defer home.deinit();
    var read: TranscriptArchiveRead = .{};
    defer read.cancel();

    try home.start(&read, 4);
    const task = try waitForArchiveRead(&read);
    try std.testing.expectEqual(@as(?anyerror, null), task.failure);
    try std.testing.expectEqual(@as(usize, 2), task.turns.items.len);
    // Still the transcript's generation: it waits for its replay.
    try std.testing.expect(!read.dropIfStale(4));
    try std.testing.expect(read.busy());
    // A compaction, resume, drop, or clear since then: it goes.
    try std.testing.expect(read.dropIfStale(5));
    try std.testing.expect(!read.busy());
    try std.testing.expect(!read.dropIfStale(5));
}

test "cancelling a running Ctrl+O archive read stops it, and the next read finishes whole" {
    var home: ArchiveReadTestHome = undefined;
    try home.init(300);
    defer home.deinit();
    var read: TranscriptArchiveRead = .{};
    defer read.cancel();

    // Cancelled right after it starts, mostly while it still reads.
    try home.start(&read, 1);
    read.cancel();
    try std.testing.expect(!read.busy());
    try std.testing.expect(read.completed() == null);

    try home.start(&read, 1);
    const task = try waitForArchiveRead(&read);
    try std.testing.expectEqual(@as(?anyerror, null), task.failure);
    try std.testing.expectEqual(@as(usize, 300), task.turns.items.len);
    read.finish();
    try std.testing.expect(!read.busy());
}

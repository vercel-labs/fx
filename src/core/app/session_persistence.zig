//! An agent's session state: its open session and store, the picker and
//! fork menu over its sessions, and what its session commands have pending.
//! The agents folder holds one per agent, so this file imports nothing from
//! the screen; `app_session_runtime.zig` runs it.

const std = @import("std");
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

    pub fn deinit(self: *SessionPicker, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
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

    pub fn selectedId(self: *const SessionPicker) ?[]const u8 {
        if (!self.active or self.load_state != .ready) return null;
        if (self.selected >= self.filteredItemCount()) return null;
        const summary = session_catalog.summaryAt(self.summaries.items, self.query(), self.selected) orelse return null;
        return summary.id;
    }

    pub fn isLoading(self: *const SessionPicker) bool {
        return self.active and self.load_state == .loading;
    }

    pub fn query(self: *const SessionPicker) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *SessionPicker, query_text: []const u8) void {
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

    pub fn active(self: *const ForkMenu) bool {
        return self.points.len > 0;
    }

    /// Moves the selection, stopping at the oldest and the newest prompt.
    pub fn move(self: *ForkMenu, delta: i32) void {
        if (self.points.len == 0) return;
        const next = @as(i64, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.points.len - 1))));
    }

    pub fn close(self: *ForkMenu, alloc: Allocator) void {
        session_adapter.Session.freeForkPoints(alloc, self.points);
        self.* = .{};
    }
};

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

pub const TitleGenerationLoad = struct {
    task: ?*session_title_generation.Task = null,
    last: LastResult = .{},

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
    }

    pub fn recordSpawnFailure(self: *TitleGenerationLoad, session_id: []const u8, model: []const u8, err: anyerror) void {
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
    fast_mode_model_bound: bool = false,
    js_host_store: JsHostSessionStore = .{},
    js_host_session: ?JsHostSessionOwner = null,
    process_provider_override: ?model_provider.ProviderId = null,
    process_model_override: ?[]u8 = null,
    process_effort_override: ?types.ReasoningEffort = null,
    process_fast_override: ?bool = null,
    process_ultrafast_override: ?bool = null,
    session_picker: SessionPicker = .{},
    session_picker_load: SessionPickerLoad = .{},
    session_picker_cache: SessionPickerCatalogCache = .{},
    fork_menu: ForkMenu = .{},
    title_generation: TitleGenerationLoad = .{},
    degraded_warning_emitted: bool = false,
    pending_cancelled_command: ?PendingCancelledCommand = null,
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
            if (@typeInfo(Persistence).@"struct".field_names.len != 29) {
                @compileError("update Persistence.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.write_mutex = .init;
        storage.subagent_host = null;
        storage.v2_children = null;
        storage.workspace_preferences = null;
        storage.session_preferences = null;
        storage.fast_mode_model_bound = false;
        storage.js_host_store = .{};
        storage.js_host_session = null;
        storage.process_provider_override = null;
        storage.process_model_override = null;
        storage.process_effort_override = null;
        storage.process_fast_override = null;
        storage.process_ultrafast_override = null;
        storage.session_picker = .{};
        storage.session_picker_load = .{};
        storage.session_picker_cache = .{};
        storage.fork_menu = .{};
        storage.title_generation = .{};
        storage.degraded_warning_emitted = false;
        storage.pending_cancelled_command = null;
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
        if (self.v2) |v2| v2.close();
        if (self.workspace_preferences) |*preferences| preferences.deinit(alloc);
        if (self.session_preferences) |*preferences| preferences.deinit(alloc);
        if (self.js_host_session) |*owner| owner.deinit(alloc);
        if (self.process_model_override) |model| alloc.free(model);
        self.session_picker.deinit(alloc);
        self.session_picker_load.deinit();
        if (catalog == .free) self.session_picker_cache.deinit();
        self.fork_menu.close(alloc);
        self.title_generation.deinit();
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

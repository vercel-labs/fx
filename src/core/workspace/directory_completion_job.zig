const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const completion = @import("../input/file_completion_state.zig");
const file_index = @import("file_index.zig");
const path_completion = @import("path_completion.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Request = struct {
    id: u64,
    episode: u64,
    scope_epoch: u64,
    at_offset: usize,
    token_start: usize,
    replace_end: usize,
    quoted: bool,
    raw: []u8,
    query: []u8,
    root: []u8,
    home: ?[]u8,

    fn copy(alloc: std.mem.Allocator, id: u64, state: *const completion.State, root: []const u8, home: ?[]const u8) !Request {
        const raw = try alloc.dupe(u8, state.raw_query[0..state.raw_len]);
        errdefer alloc.free(raw);
        const query = try alloc.dupe(u8, state.lookup_query[0..state.lookup_len.?]);
        errdefer alloc.free(query);
        const owned_root = try alloc.dupe(u8, root);
        errdefer alloc.free(owned_root);
        const owned_home = if (home) |bytes| try alloc.dupe(u8, bytes) else null;
        return .{
            .id = id,
            .episode = state.episode,
            .scope_epoch = state.scope_epoch,
            .at_offset = state.at_offset,
            .token_start = state.token_start,
            .replace_end = state.replace_end,
            .quoted = state.quoted,
            .raw = raw,
            .query = query,
            .root = owned_root,
            .home = owned_home,
        };
    }

    fn matches(self: Request, state: *const completion.State) bool {
        return state.active and !state.indexed and state.directory_request == self.id and
            state.episode == self.episode and state.scope_epoch == self.scope_epoch and
            state.at_offset == self.at_offset and state.token_start == self.token_start and
            state.replace_end == self.replace_end and state.quoted == self.quoted and
            state.raw_len == self.raw.len and state.lookup_len == self.query.len and
            std.mem.eql(u8, state.raw_query[0..state.raw_len], self.raw) and
            std.mem.eql(u8, state.lookup_query[0..self.query.len], self.query);
    }

    fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.raw);
        alloc.free(self.query);
        alloc.free(self.root);
        if (self.home) |home| alloc.free(home);
        self.* = undefined;
    }
};

const Task = struct {
    alloc: std.mem.Allocator,
    request: Request,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    // Main-only. Worker output is read only after acquire-observing done.
    abandoned: bool = false,
    rows: ?completion.Rows = null,
    failure: ?(path_completion.Error || error{ Cancelled, OutOfMemory }) = null,

    fn stop(self: *Task) void {
        if (!self.abandoned) {
            self.abandoned = true;
            self.cancel.store(true, .release);
            debug_trace.logf("input", "directory completion cancelled request={d}", .{self.request.id});
        }
    }

    fn deinit(self: *Task) void {
        if (self.thread) |thread| thread.join();
        if (self.rows) |*rows| rows.deinit(self.alloc);
        self.request.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn run(self: *Task) void {
        // All operation scratch and directory handles are gone before publication.
        defer self.done.store(true, .release);
        self.rows = self.lookup() catch |err| {
            self.failure = err;
            return;
        };
        if (self.cancel.load(.acquire)) {
            self.rows.?.deinit(self.alloc);
            self.rows = null;
            self.failure = error.Cancelled;
        }
    }

    fn lookup(self: *Task) !completion.Rows {
        var results: [completion.capacity]file_index.SearchResult = undefined;
        var spans: [completion.capacity * file_index.max_path_len]file_index.MatchSpan = undefined;
        var paths: [completion.capacity * file_index.max_path_len]u8 = undefined;
        const count = try path_completion.completeCancellable(self.request.root, self.request.home, self.request.query, &self.cancel, &results, &spans, &paths);
        if (self.cancel.load(.acquire)) return error.Cancelled;
        return completion.Rows.copy(self.alloc, results[0..count]);
    }
};

/// Main-owned bounded scheduler. The supplied allocator must be safe for concurrent
/// allocation and outlive deinit. Tasks never borrow editor, workspace or index data.
pub const Job = struct {
    task: ?*Task = null,
    pending: ?Request = null,
    next_request: u64 = 1,

    pub fn stop(self: *Job, alloc: std.mem.Allocator) void {
        if (self.task) |task| task.stop();
        self.dropPending(alloc, "stopped");
    }

    pub fn deinit(self: *Job, alloc: std.mem.Allocator) void {
        self.stop(alloc);
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    fn dropPending(self: *Job, alloc: std.mem.Allocator, reason: []const u8) void {
        if (self.pending) |*request| {
            debug_trace.logf("input", "directory completion pending dropped request={d} reason={s}", .{ request.id, reason });
            request.deinit(alloc);
            self.pending = null;
        }
    }

    /// No joins here: ingress, owner changes and scope changes only abandon work.
    pub fn reconcile(self: *Job, alloc: std.mem.Allocator, state: *completion.State, eligible: bool) void {
        if (self.task) |task| {
            if (!eligible or !task.request.matches(state)) task.stop();
        }
        if (self.pending) |request| {
            if (!eligible or !request.matches(state)) self.dropPending(alloc, if (eligible) "superseded" else "hidden");
        }
        if (!eligible and state.directory_request != null) {
            state.directory_request = null;
            state.lookup_dirty = true;
        }
    }

    pub fn schedule(self: *Job, alloc: std.mem.Allocator, state_alloc: std.mem.Allocator, state: *completion.State, root: []const u8, home: ?[]const u8) void {
        const id = self.next_request;
        self.next_request +%= 1;
        state.directory_request = id;
        self.reconcile(alloc, state, true);
        state.stage(state_alloc, .{ .scope_epoch = state.scope_epoch, .state = .ready }, .loading, null);
        const request = Request.copy(alloc, id, state, root, home) catch |err| {
            fail(state_alloc, state, id, err);
            return;
        };
        if (self.task != null) {
            self.pending = request;
        } else self.start(alloc, request) catch |err| fail(state_alloc, state, id, err);
    }

    fn start(self: *Job, alloc: std.mem.Allocator, request: Request) !void {
        try self.startWith(alloc, request, spawn);
    }

    // Spawn injection exercises exactly the allocation/ownership failure path.
    fn startWith(self: *Job, alloc: std.mem.Allocator, request: Request, comptime start_thread: anytype) !void {
        std.debug.assert(self.task == null);
        var owned = request;
        errdefer owned.deinit(alloc);
        const task = try alloc.create(Task);
        errdefer alloc.destroy(task);
        task.* = .{ .alloc = alloc, .request = owned };
        task.thread = try start_thread(task);
        self.task = task;
        debug_trace.logf("input", "directory completion started request={d}", .{request.id});
    }

    fn spawn(task: *Task) !std.Thread {
        return std.Thread.spawn(.{}, Task.run, .{task});
    }

    /// Reaps only published tasks. Copies bounded output to the picker allocator,
    /// stages it (never presents it), then starts at most the latest pending request.
    pub fn harvest(self: *Job, alloc: std.mem.Allocator, state_alloc: std.mem.Allocator, state: *completion.State, eligible: bool) bool {
        self.reconcile(alloc, state, eligible);
        const task = self.task orelse return false;
        if (!task.done.load(.acquire)) return false;
        if (!task.abandoned and task.request.matches(state)) {
            if (task.failure) |err| {
                fail(state_alloc, state, task.request.id, err);
            } else {
                const rows = completion.Rows.copy(state_alloc, task.rows.?.results) catch |err| blk: {
                    fail(state_alloc, state, task.request.id, err);
                    break :blk null;
                };
                if (rows) |owned| {
                    state.directory_request = null;
                    state.stage(state_alloc, .{ .scope_epoch = state.scope_epoch, .state = .ready }, if (owned.results.len == 0) .empty else .ready, owned);
                    debug_trace.logf("input", "file picker prepared revision={d} count={d} indexed=false request={d}", .{ state.next_revision -% 1, owned.results.len, task.request.id });
                }
            }
        } else debug_trace.logf("input", "directory completion stale output dropped request={d} failed={}", .{ task.request.id, task.failure != null });
        task.deinit();
        self.task = null;
        if (self.pending) |request| {
            self.pending = null;
            self.start(alloc, request) catch |err| fail(state_alloc, state, request.id, err);
        }
        return true;
    }

    fn fail(alloc: std.mem.Allocator, state: *completion.State, id: u64, err: anyerror) void {
        debug_trace.logf("input", "directory completion failed request={d} err={s}", .{ id, @errorName(err) });
        if (state.directory_request != id) return;
        state.directory_request = null;
        state.stage(alloc, .{ .scope_epoch = state.scope_epoch, .state = .ready }, .unavailable, null);
    }
};

const picker_path = @import("../input/file_picker_path.zig");

fn bindTest(state: *completion.State, text: []const u8, epoch: u64) void {
    _ = state.reconcile(picker_path.query_at(text, text.len), epoch, false);
}

fn heldTestTask(alloc: std.mem.Allocator, state: *completion.State, id: u64) !*Task {
    state.directory_request = id;
    var request = try Request.copy(alloc, id, state, "/unused", "/captured-home");
    errdefer request.deinit(alloc);
    const task = try alloc.create(Task);
    task.* = .{ .alloc = alloc, .request = request };
    return task;
}

test "directory completion stale success and failure never stage another occurrence" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |failed| {
        var state: completion.State = .{};
        defer state.deinit(alloc);
        bindTest(&state, "@./a", 1);
        var job: Job = .{ .task = try heldTestTask(alloc, &state, 1) };
        defer job.deinit(alloc);
        const task = job.task.?;
        if (failed) task.failure = error.PathUnavailable else task.rows = try completion.Rows.copy(alloc, &.{.{ .path = "./a", .kind = .file, .matched_spans = &.{} }});
        // Same query, new scope, and then original scope: the episode still differs.
        bindTest(&state, "@./a", 2);
        bindTest(&state, "@./a", 1);
        task.done.store(true, .release);
        try std.testing.expect(job.harvest(alloc, alloc, &state, true));
        try std.testing.expect(state.prepared == null);
        try std.testing.expect(state.selected(0) == null);
        try std.testing.expect(job.task == null);
    }
}

test "directory completion supersession keeps one latest copied pending request without joining" {
    const alloc = std.testing.allocator;
    var state: completion.State = .{};
    defer state.deinit(alloc);
    bindTest(&state, "@./old", 1);
    var job: Job = .{ .task = try heldTestTask(alloc, &state, 1), .next_request = 2 };
    defer job.deinit(alloc);
    const old = job.task.?;
    bindTest(&state, "@./b", 2);
    job.schedule(alloc, alloc, &state, "/root-b", "/home-b");
    try std.testing.expect(old.cancel.load(.acquire));
    try std.testing.expect(!old.done.load(.acquire));
    try std.testing.expect(job.task.? == old);
    bindTest(&state, "@./a", 3);
    var root = "/root-a".*;
    var home = "/home-a".*;
    job.schedule(alloc, alloc, &state, &root, &home);
    @memset(&root, 'x');
    @memset(&home, 'x');
    try std.testing.expectEqual(@as(u64, 3), job.pending.?.scope_epoch);
    try std.testing.expectEqualStrings("/root-a", job.pending.?.root);
    try std.testing.expectEqualStrings("/home-a", job.pending.?.home.?);
    try std.testing.expectEqualStrings("./a", job.pending.?.query);
    try std.testing.expect(job.pending.?.matches(&state));
    state.at_offset += 1;
    try std.testing.expect(!job.pending.?.matches(&state));
    state.at_offset -= 1;
    // Hidden owners cancel/drop work immediately, but never join the old task.
    job.reconcile(alloc, &state, false);
    try std.testing.expect(job.pending == null);
    try std.testing.expect(state.directory_request == null);
    try std.testing.expect(state.lookup_dirty);
    try std.testing.expect(job.task.? == old);
    old.failure = error.PathUnavailable;
    old.done.store(true, .release);
    try std.testing.expect(job.harvest(alloc, alloc, &state, false));
    try std.testing.expectEqual(completion.Status.loading, state.view(0, 0).status);
}

fn failSpawn(_: *Task) error{ThreadQuotaExceeded}!std.Thread {
    return error.ThreadQuotaExceeded;
}

fn checkRequestFailures(alloc: std.mem.Allocator) !void {
    var state: completion.State = .{};
    bindTest(&state, "@./path", 1);
    var job: Job = .{};
    defer job.deinit(alloc);
    const request = try Request.copy(alloc, 1, &state, "/root", "/home");
    job.startWith(alloc, request, failSpawn) catch |err| switch (err) {
        error.ThreadQuotaExceeded => return,
        else => return err,
    };
    return error.ExpectedSpawnFailure;
}

test "directory completion request OOM and spawn failure release all inputs" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, checkRequestFailures, .{});
}

test "directory completion scheduling OOM is unavailable and retry owns a fresh request" {
    const alloc = testing_allocator.no_resize;
    var state: completion.State = .{};
    defer state.deinit(alloc);
    bindTest(&state, "@./a", 1);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var job: Job = .{};
    job.schedule(failing.allocator(), alloc, &state, "/root", null);
    try std.testing.expectEqual(completion.Status.unavailable, state.view(0, 0).status);
    try std.testing.expect(state.directory_request == null);
    try std.testing.expect(job.task == null);
    try std.testing.expect(job.pending == null);
    state.retry();
    try std.testing.expect(state.lookup_dirty);
    try std.testing.expectEqual(@as(u64, 2), job.next_request);
}

test "directory completion owned output stages only and cleans harvest OOM" {
    const alloc = testing_allocator.no_resize;
    for ([_]bool{ false, true }) |fail_copy| {
        var state: completion.State = .{};
        defer state.deinit(alloc);
        bindTest(&state, "@./a", 1);
        var job: Job = .{ .task = try heldTestTask(alloc, &state, 1) };
        defer job.deinit(alloc);
        var path = "./alpha".*;
        var spans = [_]file_index.MatchSpan{.{ .byte_start = 2, .byte_end = 3 }};
        job.task.?.rows = try completion.Rows.copy(alloc, &.{.{ .path = &path, .kind = .file, .matched_spans = &spans }});
        @memset(&path, 'x');
        spans[0] = .{ .byte_start = 0, .byte_end = 0 };
        job.task.?.done.store(true, .release);
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        try std.testing.expect(job.harvest(alloc, if (fail_copy) failing.allocator() else alloc, &state, true));
        try std.testing.expect(state.selected(0) == null);
        try std.testing.expect(job.task == null);
        if (fail_copy) {
            try std.testing.expectEqual(completion.Status.unavailable, state.view(0, 0).status);
        } else {
            try std.testing.expectEqualStrings("./alpha", state.view(0, 0).items[0].path);
            try std.testing.expectEqual(@as(u16, 2), state.view(0, 0).items[0].matched_spans[0].byte_start);
            var index: usize = 0;
            var window: usize = 0;
            state.acknowledge(alloc, state.view(0, 0).receipt.?, &index, &window);
            try std.testing.expectEqualStrings("./alpha", state.selected(0).?.path);
        }
    }
}

test "directory completion cancelled operation skips unavailable filesystem and joins on shutdown" {
    const alloc = std.testing.allocator;
    var state: completion.State = .{};
    defer state.deinit(alloc);
    bindTest(&state, "@./missing/", 1);
    const task = try heldTestTask(alloc, &state, 1);
    var job: Job = .{ .task = task };
    task.stop();
    task.thread = try std.Thread.spawn(.{}, Task.run, .{task});
    while (!task.done.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(error.Cancelled, task.failure.?);
    try std.testing.expect(task.rows == null);
    job.deinit(alloc);
    try std.testing.expect(job.task == null);
}

test "directory completion reap starts latest pending only after old task is done" {
    const alloc = std.testing.allocator;
    var state: completion.State = .{};
    defer state.deinit(alloc);
    bindTest(&state, "@./old", 1);
    var job: Job = .{ .task = try heldTestTask(alloc, &state, 1), .next_request = 2 };
    defer job.deinit(alloc);
    bindTest(&state, "@./missing/", 2);
    job.schedule(alloc, alloc, &state, "/nonexistent-directory-completion-test-root", null);
    try std.testing.expect(!job.harvest(alloc, alloc, &state, true));
    try std.testing.expectEqual(@as(u64, 1), job.task.?.request.id);
    job.task.?.failure = error.Cancelled;
    job.task.?.done.store(true, .release);
    try std.testing.expect(job.harvest(alloc, alloc, &state, true));
    try std.testing.expectEqual(@as(u64, 2), job.task.?.request.id);
    try std.testing.expect(job.pending == null);
    // Final join also works with an actual live task, with no harvest required.
    job.stop(alloc);
}

fn checkLookupFailures(alloc: std.mem.Allocator, root: []const u8) !void {
    var state: completion.State = .{};
    bindTest(&state, "@./ch", 1);
    const request = try Request.copy(alloc, 1, &state, root, null);
    var task: Task = .{ .alloc = alloc, .request = request };
    defer task.request.deinit(alloc);
    var rows = try task.lookup();
    defer rows.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), rows.results.len);
    try std.testing.expectEqualStrings("./chosen.txt", rows.results[0].path);
}

test "directory completion output OOM closes operation resources and partial owned rows" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "chosen.txt", .data = "chosen" });
    const root = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, checkLookupFailures, .{root});
}

test "directory completion binding rejects every changed identity fact" {
    const alloc = std.testing.allocator;
    var state: completion.State = .{};
    bindTest(&state, "@./a", 1);
    const task = try heldTestTask(alloc, &state, 7);
    defer task.deinit();
    try std.testing.expect(task.request.matches(&state));
    inline for (.{ "episode", "scope_epoch", "at_offset", "token_start", "replace_end", "raw_len" }) |field| {
        @field(state, field) += 1;
        try std.testing.expect(!task.request.matches(&state));
        @field(state, field) -= 1;
    }
    state.directory_request = 8;
    try std.testing.expect(!task.request.matches(&state));
    state.directory_request = 7;
    state.quoted = !state.quoted;
    try std.testing.expect(!task.request.matches(&state));
    state.quoted = !state.quoted;
    state.raw_query[0] = 'x';
    try std.testing.expect(!task.request.matches(&state));
    try std.testing.expectEqualStrings("./a", task.request.raw);
    state.raw_query[0] = '.';
    state.lookup_query[0] = 'x';
    try std.testing.expect(!task.request.matches(&state));
    try std.testing.expectEqualStrings("./a", task.request.query);
    state.invalidate();
    bindTest(&state, "@./a", 1);
    try std.testing.expect(!task.request.matches(&state));
}

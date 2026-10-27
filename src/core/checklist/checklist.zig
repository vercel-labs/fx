//! The model's checklist (D230): phases of tasks it keeps for the session
//! and moves through as it works, as proto's `checklist` tool does. Tasks
//! are named by their exact content, never by ids. This file owns the
//! state, the request a call makes, and how a request changes the list;
//! `summary.zig` says what the model reads back, `codec.zig` how the list
//! is saved with the session, and `store.zig` holds a session's list.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const tool_name = "checklist";
/// A task's status; the saved and model-facing names are the tag names.
pub const Status = enum { pending, in_progress, completed, abandoned, blocked };

pub fn isClosed(status: Status) bool {
    return status == .completed or status == .abandoned;
}

/// Open work the agent can advance itself; blocked tasks wait on someone else.
pub fn isOpen(status: Status) bool {
    return status == .pending or status == .in_progress;
}

pub const Task = struct {
    content: []const u8,
    status: Status = .pending,
    /// Why a blocked task waits, or null.
    blocker: ?[]const u8 = null,
};

pub const Phase = struct {
    name: []const u8,
    tasks: std.ArrayList(Task) = .empty,
};

/// A checklist and everything it owns, in one arena.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    phases: std.ArrayList(Phase) = .empty,

    pub fn init(gpa: Allocator) List {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A deep copy in a new arena over `gpa`. Caller owns it.
    pub fn clone(self: *const List, gpa: Allocator) Allocator.Error!List {
        var copy: List = .init(gpa);
        errdefer copy.deinit();
        const a = copy.arena.allocator();
        try copy.phases.ensureTotalCapacity(a, self.phases.items.len);
        for (self.phases.items) |phase| {
            var tasks: std.ArrayList(Task) = .empty;
            try tasks.ensureTotalCapacity(a, phase.tasks.items.len);
            for (phase.tasks.items) |task| tasks.appendAssumeCapacity(.{
                .content = try a.dupe(u8, task.content),
                .status = task.status,
                .blocker = if (task.blocker) |text| try a.dupe(u8, text) else null,
            });
            copy.phases.appendAssumeCapacity(.{ .name = try a.dupe(u8, phase.name), .tasks = tasks });
        }
        return copy;
    }

    pub fn taskCount(self: *const List) usize {
        var count: usize = 0;
        for (self.phases.items) |phase| count += phase.tasks.items.len;
        return count;
    }

    pub fn countWhere(self: *const List, comptime predicate: fn (Status) bool) usize {
        var count: usize = 0;
        for (self.phases.items) |phase| for (phase.tasks.items) |task| {
            if (predicate(task.status)) count += 1;
        };
        return count;
    }

    pub fn blockedCount(self: *const List) usize {
        return self.countWhere(isBlocked);
    }

    /// The task the agent works on: the one in progress, or the first pending.
    pub fn nextActionable(self: *const List) ?*const Task {
        var first_pending: ?*const Task = null;
        for (self.phases.items) |*phase| for (phase.tasks.items) |*task| {
            if (task.status == .in_progress) return task;
            if (first_pending == null and task.status == .pending) first_pending = task;
        };
        return first_pending;
    }

    pub fn phaseOf(self: *const List, task: *const Task) ?*const Phase {
        for (self.phases.items) |*phase| for (phase.tasks.items) |*candidate| {
            if (candidate == task) return phase;
        };
        return null;
    }

    pub fn eql(a: *const List, b: *const List) bool {
        if (a.phases.items.len != b.phases.items.len) return false;
        for (a.phases.items, b.phases.items) |pa, pb| {
            if (!std.mem.eql(u8, pa.name, pb.name) or pa.tasks.items.len != pb.tasks.items.len) return false;
            for (pa.tasks.items, pb.tasks.items) |ta, tb| {
                if (ta.status != tb.status or !std.mem.eql(u8, ta.content, tb.content)) return false;
                if ((ta.blocker == null) != (tb.blocker == null)) return false;
                if (ta.blocker) |text| if (!std.mem.eql(u8, text, tb.blocker.?)) return false;
            }
        }
        return true;
    }
};

fn isBlocked(status: Status) bool {
    return status == .blocked;
}

// -- Requests ----------------------------------------------------------------

pub const Op = enum { init, start, done, rm, drop, block, unblock, append, view };

pub const InitEntry = struct {
    phase: []const u8,
    items: []const []const u8,
};

/// One call's arguments, borrowed from the arena they were parsed in.
pub const Request = struct {
    op: Op,
    list: ?[]const InitEntry = null,
    task: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    items: ?[]const []const u8 = null,
    reason: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    request: Request,
    /// Why the arguments are not a request, for the model.
    invalid: []const u8,
};

const RawEntry = struct {
    phase: ?[]const u8 = null,
    items: ?[]const []const u8 = null,
};

const RawRequest = struct {
    op: ?[]const u8 = null,
    list: ?[]const RawEntry = null,
    task: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    items: ?[]const []const u8 = null,
    reason: ?[]const u8 = null,
};

/// Reads a call's arguments in `arena`. A call without `op` that clearly
/// means `init` or `append` is taken as that, as proto repairs it.
/// `has_tasks` says whether the checklist holds tasks already.
pub fn parseRequest(arena: Allocator, args_json: []const u8, has_tasks: bool) Allocator.Error!Parsed {
    const raw = std.json.parseFromSliceLeaky(RawRequest, arena, args_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = try arena.print("Invalid checklist arguments: {s}", .{@errorName(err)}) },
    };
    const op: Op = if (nonEmpty(raw.op)) |name|
        std.meta.stringToEnum(Op, name) orelse return .{ .invalid = try arena.print("Invalid checklist arguments: unknown op \"{s}\"", .{name}) }
    else if (raw.list != null and raw.list.?.len > 0)
        .init
    else if (raw.items != null and raw.items.?.len > 0 and nonEmpty(raw.phase) != null)
        .append
    else if (raw.items != null and raw.items.?.len > 0 and !has_tasks)
        .init
    else
        return .{ .invalid = "Invalid checklist arguments: op is required" };

    var list: ?[]const InitEntry = null;
    if (raw.list) |entries| {
        const out = try arena.alloc(InitEntry, entries.len);
        for (entries, out) |entry, *slot| {
            const phase = nonEmpty(entry.phase) orelse return .{ .invalid = "Invalid checklist arguments: every list entry needs a phase" };
            const items = entry.items orelse return .{ .invalid = "Invalid checklist arguments: every list entry needs items" };
            if (items.len == 0) return .{ .invalid = try arena.print("Invalid checklist arguments: phase \"{s}\" has no items", .{phase}) };
            slot.* = .{ .phase = phase, .items = try trimAll(arena, items) };
        }
        list = out;
    }
    return .{ .request = .{
        .op = op,
        .list = list,
        .task = nonEmpty(raw.task),
        .phase = nonEmpty(raw.phase),
        .items = if (raw.items) |items| try trimAll(arena, items) else null,
        .reason = if (nonEmpty(raw.reason)) |text| try collapseSpace(arena, text) else null,
    } };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = std.mem.trim(u8, value orelse return null, " \t\r\n");
    return if (text.len == 0) null else text;
}

fn trimAll(arena: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| if (nonEmpty(item)) |text| try out.append(arena, text);
    return out.items;
}

fn collapseSpace(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.items;
}

// -- Applying a request ------------------------------------------------------

/// A task a request completed, by its phase and content.
pub const Transition = struct { phase: []const u8, content: []const u8 };

/// What a request did. `list` is a new list in its own arena; `errors`
/// and `completed` live in that arena too. With errors the caller keeps
/// the list it had.
pub const Applied = struct {
    list: List,
    errors: []const []const u8,
    completed: []const Transition,

    pub fn deinit(self: *Applied) void {
        self.list.deinit();
        self.* = undefined;
    }

    pub fn failed(self: *const Applied) bool {
        return self.errors.len > 0;
    }
};

const default_phase = "Tasks";

/// Applies `request` to a copy of `current`. Caller owns the result.
pub fn apply(gpa: Allocator, current: *const List, request: Request) Allocator.Error!Applied {
    var next = try current.clone(gpa);
    errdefer next.deinit();
    const a = next.arena.allocator();
    var errors: std.ArrayList([]const u8) = .empty;
    var ctx: Ctx = .{ .a = a, .list = &next, .errors = &errors };
    switch (request.op) {
        .view => {},
        .init => try ctx.initPhases(request),
        .start => try ctx.start(request),
        .done => for (try ctx.targets(request)) |task| {
            task.status = .completed;
            task.blocker = null;
        },
        .drop => for (try ctx.targets(request)) |task| {
            if (task.status != .completed) task.status = .abandoned;
        },
        .block => if (request.task == null and request.phase == null)
            try errors.append(a, "block requires a task or phase target")
        else for (try ctx.targets(request)) |task| {
            if (task.status != .pending and task.status != .in_progress and task.status != .blocked) continue;
            task.status = .blocked;
            task.blocker = if (request.reason) |text| try a.dupe(u8, text) else null;
        },
        .unblock => if (request.task == null and request.phase == null)
            try errors.append(a, "unblock requires a task or phase target")
        else for (try ctx.targets(request)) |task| {
            if (task.status != .blocked) continue;
            task.status = .pending;
            task.blocker = null;
        },
        .rm => try ctx.remove(request),
        .append => try ctx.append(request),
    }
    normalizeInProgress(&next);
    const completed: []const Transition = if (errors.items.len > 0 or request.op == .view) &.{} else try completions(a, current, &next);
    return .{ .list = next, .errors = errors.items, .completed = completed };
}

const Ctx = struct {
    a: Allocator,
    list: *List,
    errors: *std.ArrayList([]const u8),

    fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try ctx.errors.append(ctx.a, try ctx.a.print(fmt, args));
    }

    fn findTask(ctx: *Ctx, content: []const u8) ?struct { task: *Task, phase: *Phase } {
        for (ctx.list.phases.items) |*phase| for (phase.tasks.items) |*task| {
            if (std.mem.eql(u8, task.content, content)) return .{ .task = task, .phase = phase };
        };
        return null;
    }

    fn findPhase(ctx: *Ctx, name: []const u8) ?*Phase {
        for (ctx.list.phases.items) |*phase| if (std.mem.eql(u8, phase.name, name)) return phase;
        return null;
    }

    fn resolveTask(ctx: *Ctx, content: []const u8) Allocator.Error!?*Task {
        if (ctx.findTask(content)) |hit| return hit.task;
        if (looksLikeId(content)) {
            try ctx.fail("Task \"{s}\" not found. Tasks are named by their content, not by ids: pass the task's full text from the previous result.", .{content});
        } else if (ctx.list.taskCount() == 0) {
            try ctx.fail("Task \"{s}\" not found (the checklist is empty: was it replaced or not created yet?)", .{content});
        } else {
            try ctx.fail("Task \"{s}\" not found", .{content});
        }
        return null;
    }

    fn resolvePhase(ctx: *Ctx, name: []const u8) Allocator.Error!?*Phase {
        if (ctx.findPhase(name)) |phase| return phase;
        try ctx.fail("Phase \"{s}\" not found", .{name});
        return null;
    }

    /// The tasks a request names: one task, or every task of a phase.
    fn targets(ctx: *Ctx, request: Request) Allocator.Error![]*Task {
        var out: std.ArrayList(*Task) = .empty;
        if (request.task) |content| {
            if (try ctx.resolveTask(content)) |task| try out.append(ctx.a, task);
        } else if (request.phase) |name| {
            if (try ctx.resolvePhase(name)) |phase| for (phase.tasks.items) |*task| try out.append(ctx.a, task);
        } else {
            try ctx.fail("{s} requires a task or phase target", .{@tagName(request.op)});
        }
        return out.items;
    }

    fn start(ctx: *Ctx, request: Request) Allocator.Error!void {
        if (request.task != null and request.phase != null) return ctx.fail("start takes a task or a phase, not both", .{});
        const task: *Task = if (request.task) |content|
            (try ctx.resolveTask(content)) orelse return
        else if (request.phase) |name| blk: {
            const phase = (try ctx.resolvePhase(name)) orelse return;
            for (phase.tasks.items) |*candidate| if (candidate.status == .in_progress) break :blk candidate;
            for (phase.tasks.items) |*candidate| if (candidate.status == .pending) break :blk candidate;
            return ctx.fail("Phase \"{s}\" has no pending task to start", .{name});
        } else return ctx.fail("start requires a task or phase target", .{});
        if (isClosed(task.status)) return ctx.fail("Task \"{s}\" is already closed", .{task.content});
        if (task.status == .blocked) return ctx.fail("Task \"{s}\" is blocked; unblock it before starting", .{task.content});
        for (ctx.list.phases.items) |*phase| for (phase.tasks.items) |*candidate| {
            if (candidate.status == .in_progress and candidate != task) candidate.status = .pending;
        };
        task.status = .in_progress;
    }

    fn initPhases(ctx: *Ctx, request: Request) Allocator.Error!void {
        const single = [_]InitEntry{.{ .phase = request.phase orelse default_phase, .items = request.items orelse &.{} }};
        const entries: []const InitEntry = request.list orelse if (request.items != null and request.items.?.len > 0) &single else {
            return ctx.fail("Missing list for init", .{});
        };
        for (entries, 0..) |entry, index| {
            for (entries[0..index]) |earlier| if (std.mem.eql(u8, earlier.phase, entry.phase)) {
                try ctx.fail("Duplicate phase \"{s}\" in init list", .{entry.phase});
                break;
            };
            for (entry.items, 0..) |item, item_index| {
                if (seenBefore(entries, index, item_index, item)) try ctx.fail("Duplicate task \"{s}\" in init list", .{item});
            }
        }
        if (ctx.errors.items.len > 0) return;
        ctx.list.phases = .empty;
        for (entries) |entry| {
            var tasks: std.ArrayList(Task) = .empty;
            for (entry.items) |item| try tasks.append(ctx.a, .{ .content = try ctx.a.dupe(u8, item) });
            try ctx.list.phases.append(ctx.a, .{ .name = try ctx.a.dupe(u8, entry.phase), .tasks = tasks });
        }
    }

    fn append(ctx: *Ctx, request: Request) Allocator.Error!void {
        const name = request.phase orelse return ctx.fail("Missing phase for append", .{});
        const items = request.items orelse &.{};
        if (items.len == 0) return ctx.fail("Missing items for append", .{});
        var duplicate = false;
        for (items, 0..) |item, index| {
            const repeated = for (items[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, item)) break true;
            } else false;
            if (repeated or ctx.findTask(item) != null) {
                try ctx.fail("Task \"{s}\" already exists", .{item});
                duplicate = true;
            }
        }
        if (duplicate) return;
        const phase = ctx.findPhase(name) orelse blk: {
            try ctx.list.phases.append(ctx.a, .{ .name = try ctx.a.dupe(u8, name) });
            break :blk &ctx.list.phases.items[ctx.list.phases.items.len - 1];
        };
        for (items) |item| try phase.tasks.append(ctx.a, .{ .content = try ctx.a.dupe(u8, item) });
    }

    fn remove(ctx: *Ctx, request: Request) Allocator.Error!void {
        if (request.task) |content| {
            const hit = ctx.findTask(content) orelse {
                _ = try ctx.resolveTask(content);
                return;
            };
            const index = (@intFromPtr(hit.task) - @intFromPtr(hit.phase.tasks.items.ptr)) / @sizeOf(Task);
            _ = hit.phase.tasks.orderedRemove(index);
            return;
        }
        if (request.phase) |name| {
            const phase = (try ctx.resolvePhase(name)) orelse return;
            phase.tasks = .empty;
            return;
        }
        for (ctx.list.phases.items) |*phase| phase.tasks = .empty;
    }
};

fn seenBefore(entries: []const InitEntry, entry_index: usize, item_index: usize, item: []const u8) bool {
    for (entries[0 .. entry_index + 1], 0..) |entry, index| {
        const limit = if (index == entry_index) item_index else entry.items.len;
        for (entry.items[0..limit]) |earlier| if (std.mem.eql(u8, earlier, item)) return true;
    }
    return false;
}

fn looksLikeId(content: []const u8) bool {
    if (!std.mem.startsWith(u8, content, "task-") or content.len == "task-".len) return false;
    for (content["task-".len..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// At most one task is in progress, the earliest; with none, the earliest
/// pending task starts. Blocked tasks never start on their own.
pub fn normalizeInProgress(list: *List) void {
    var seen = false;
    for (list.phases.items) |*phase| for (phase.tasks.items) |*task| {
        if (task.status != .in_progress) continue;
        if (seen) task.status = .pending;
        seen = true;
    };
    if (seen) return;
    for (list.phases.items) |*phase| for (phase.tasks.items) |*task| {
        if (task.status == .pending) {
            task.status = .in_progress;
            return;
        }
    };
}

fn completions(a: Allocator, before: *const List, after: *const List) Allocator.Error![]const Transition {
    var out: std.ArrayList(Transition) = .empty;
    for (after.phases.items) |phase| for (phase.tasks.items) |task| {
        if (task.status != .completed) continue;
        const previous = statusIn(before, phase.name, task.content) orelse continue;
        if (previous != .completed) try out.append(a, .{ .phase = phase.name, .content = task.content });
    };
    return out.items;
}

fn statusIn(list: *const List, phase_name: []const u8, content: []const u8) ?Status {
    for (list.phases.items) |phase| {
        if (!std.mem.eql(u8, phase.name, phase_name)) continue;
        for (phase.tasks.items) |task| if (std.mem.eql(u8, task.content, content)) return task.status;
    }
    return null;
}

// -- Tests -------------------------------------------------------------------

const testing = std.testing;

pub fn testList(gpa: Allocator, comptime spec: []const struct { []const u8, []const struct { []const u8, Status } }) !List {
    var list: List = .init(gpa);
    errdefer list.deinit();
    const a = list.arena.allocator();
    inline for (spec) |phase| {
        var tasks: std.ArrayList(Task) = .empty;
        inline for (phase[1]) |task| try tasks.append(a, .{ .content = task[0], .status = task[1] });
        try list.phases.append(a, .{ .name = phase[0], .tasks = tasks });
    }
    return list;
}

fn run(list: *const List, args: []const u8) !Applied {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseRequest(arena.allocator(), args, list.taskCount() > 0);
    return apply(testing.allocator, list, parsed.request);
}

test "a phase start picks its first pending task" {
    var list = try testList(testing.allocator, &.{.{ "Phase", &.{ .{ "first task", .pending }, .{ "closed task", .completed } } }});
    defer list.deinit();
    var applied = try run(&list, "{\"op\":\"start\",\"phase\":\"Phase\"}");
    defer applied.deinit();
    try testing.expectEqual(@as(usize, 0), applied.errors.len);
    try testing.expectEqual(Status.in_progress, applied.list.phases.items[0].tasks.items[0].status);
}

test "closed tasks are never restarted or dropped and a target is required" {
    var list = try testList(testing.allocator, &.{.{ "Phase", &.{ .{ "first task", .pending }, .{ "closed task", .completed } } }});
    defer list.deinit();
    var started = try run(&list, "{\"op\":\"start\",\"task\":\"closed task\"}");
    defer started.deinit();
    try testing.expectEqualStrings("Task \"closed task\" is already closed", started.errors[0]);
    var dropped = try run(&list, "{\"op\":\"drop\",\"task\":\"closed task\"}");
    defer dropped.deinit();
    try testing.expectEqual(Status.completed, dropped.list.phases.items[0].tasks.items[1].status);
    var done = try run(&list, "{\"op\":\"done\"}");
    defer done.deinit();
    try testing.expectEqualStrings("done requires a task or phase target", done.errors[0]);
}

test "init replaces the list, starts the first task, and refuses duplicates" {
    var list = try testList(testing.allocator, &.{.{ "Old", &.{.{ "old task", .pending }} }});
    defer list.deinit();
    var applied = try run(&list, "{\"op\":\"init\",\"list\":[{\"phase\":\"Build\",\"items\":[\"Write parser\",\"Add tests\"]},{\"phase\":\"Ship\",\"items\":[\"Tag release\"]}]}");
    defer applied.deinit();
    try testing.expectEqual(@as(usize, 2), applied.list.phases.items.len);
    try testing.expectEqual(Status.in_progress, applied.list.phases.items[0].tasks.items[0].status);
    try testing.expectEqual(@as(usize, 3), applied.list.taskCount());
    var dup = try run(&list, "{\"op\":\"init\",\"list\":[{\"phase\":\"A\",\"items\":[\"x\"]},{\"phase\":\"A\",\"items\":[\"x\"]}]}");
    defer dup.deinit();
    try testing.expectEqual(@as(usize, 2), dup.errors.len);
}

test "a call without op is read as init or append" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Op.init, (try parseRequest(a, "{\"items\":[\"x\"]}", false)).request.op);
    try testing.expectEqual(Op.append, (try parseRequest(a, "{\"phase\":\"P\",\"items\":[\"x\"]}", true)).request.op);
    try testing.expect((try parseRequest(a, "{\"items\":[\"x\"]}", true)) == .invalid);
    try testing.expect((try parseRequest(a, "{\"op\":\"finish\"}", true)) == .invalid);
}

test "done advances the pointer and reports the completed task once" {
    var list = try testList(testing.allocator, &.{.{ "Phase", &.{ .{ "first task", .in_progress }, .{ "second task", .pending }, .{ "third task", .pending } } }});
    defer list.deinit();
    var applied = try run(&list, "{\"op\":\"done\",\"task\":\"first task\"}");
    defer applied.deinit();
    try testing.expectEqual(Status.in_progress, applied.list.phases.items[0].tasks.items[1].status);
    try testing.expectEqual(@as(usize, 1), applied.completed.len);
    try testing.expectEqualStrings("first task", applied.completed[0].content);
}

test "block holds a task out of the pointer until unblock" {
    var list = try testList(testing.allocator, &.{.{ "Phase", &.{ .{ "a", .in_progress }, .{ "b", .pending } } }});
    defer list.deinit();
    var blocked = try run(&list, "{\"op\":\"block\",\"task\":\"a\",\"reason\":\"  needs   the API key \"}");
    defer blocked.deinit();
    const tasks = blocked.list.phases.items[0].tasks.items;
    try testing.expectEqual(Status.blocked, tasks[0].status);
    try testing.expectEqualStrings("needs the API key", tasks[0].blocker.?);
    try testing.expectEqual(Status.in_progress, tasks[1].status);
    var unblocked = try run(&blocked.list, "{\"op\":\"unblock\",\"task\":\"a\"}");
    defer unblocked.deinit();
    try testing.expectEqual(Status.pending, unblocked.list.phases.items[0].tasks.items[0].status);
    try testing.expectEqual(@as(?[]const u8, null), unblocked.list.phases.items[0].tasks.items[0].blocker);
}

test "append creates its phase, rm removes, and ids get a hint" {
    var list = try testList(testing.allocator, &.{.{ "Phase", &.{.{ "a", .in_progress }} }});
    defer list.deinit();
    var appended = try run(&list, "{\"op\":\"append\",\"phase\":\"Later\",\"items\":[\"b\",\"c\"]}");
    defer appended.deinit();
    try testing.expectEqual(@as(usize, 3), appended.list.taskCount());
    var again = try run(&appended.list, "{\"op\":\"append\",\"phase\":\"Later\",\"items\":[\"a\"]}");
    defer again.deinit();
    try testing.expectEqualStrings("Task \"a\" already exists", again.errors[0]);
    var removed = try run(&appended.list, "{\"op\":\"rm\",\"task\":\"b\"}");
    defer removed.deinit();
    try testing.expectEqual(@as(usize, 2), removed.list.taskCount());
    var cleared = try run(&appended.list, "{\"op\":\"rm\"}");
    defer cleared.deinit();
    try testing.expectEqual(@as(usize, 0), cleared.list.taskCount());
    var by_id = try run(&list, "{\"op\":\"done\",\"task\":\"task-2\"}");
    defer by_id.deinit();
    try testing.expect(std.mem.find(u8, by_id.errors[0], "not by ids") != null);
}

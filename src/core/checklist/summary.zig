//! What the model reads back from a checklist call (D230), in proto's
//! words: `init` prints the tree after its summary, `view` the tree with
//! overall counts, and other changes a short acknowledgement that names
//! the progress and the task now in progress. Errors print only the error
//! and the hint to view. Also the reminder a turn gets when it ends with
//! open tasks (D232).
const std = @import("std");
const checklist = @import("checklist.zig");

const Allocator = std.mem.Allocator;
const List = checklist.List;
const Request = checklist.Request;

pub const view_hint = "Use op:\"view\" to see exact task names.";

/// The result text for `request`, which turned `previous` into `next`.
/// `errors` non-empty means the request failed and `next` is unused.
pub fn resultText(arena: Allocator, previous: *const List, next: *const List, request: Request, errors: []const []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeResult(arena, w, previous, next, request, errors) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return out.written();
}

fn writeResult(arena: Allocator, w: *std.Io.Writer, previous: *const List, next: *const List, request: Request, errors: []const []const u8) (Allocator.Error || std.Io.Writer.Error)!void {
    if (errors.len > 0) {
        for (errors, 0..) |message, index| {
            if (index > 0) try w.writeAll("; ");
            try w.writeAll(message);
        }
        try w.print("\n{s}", .{view_hint});
        return;
    }
    switch (request.op) {
        .view => return writeView(w, next),
        .init => {
            const current = next.nextActionable();
            try w.print("Initialized {d} tasks in {d} phases; in progress: ", .{ next.taskCount(), next.phases.items.len });
            try writeQuotedOrNone(w, if (current) |task| task.content else null);
            try writeTree(w, next);
            return;
        },
        else => return writeAck(arena, w, previous, next, request),
    }
}

fn writeView(w: *std.Io.Writer, list: *const List) std.Io.Writer.Error!void {
    const total = list.taskCount();
    if (total == 0) return w.writeAll("The checklist is empty.");
    const open = list.countWhere(checklist.isOpen);
    const blocked = list.blockedCount();
    try w.print("Overall: {d}/{d} done, {d} open", .{ list.countWhere(checklist.isClosed), total, open });
    if (blocked > 0) try w.print(", {d} blocked", .{blocked});
    try w.writeAll(".\n");
    var current_index: usize = list.phases.items.len - 1;
    for (list.phases.items, 0..) |phase, index| {
        if (hasOpen(phase)) {
            current_index = index;
            break;
        }
    }
    const current = list.phases.items[current_index];
    var done: usize = 0;
    for (current.tasks.items) |task| done += @intFromBool(checklist.isClosed(task.status));
    var worked_ahead = false;
    for (list.phases.items[current_index + 1 ..]) |phase| for (phase.tasks.items) |task| {
        if (checklist.isClosed(task.status)) worked_ahead = true;
    };
    try w.print("Active phase {d}/{d} \"{s}\" ({d}/{d})", .{ current_index + 1, list.phases.items.len, current.name, done, current.tasks.items.len });
    try w.writeAll(if (worked_ahead)
        ": the earliest phase with open tasks. The in-progress pointer moves to the earliest open task on each change, so it can sit behind work done out of order; nothing was reopened."
    else
        ".");
    try writeTree(w, list);
}

fn hasOpen(phase: checklist.Phase) bool {
    for (phase.tasks.items) |task| if (checklist.isOpen(task.status)) return true;
    return false;
}

fn writeTree(w: *std.Io.Writer, list: *const List) std.Io.Writer.Error!void {
    for (list.phases.items) |phase| {
        try w.print("\n  {s}:", .{phase.name});
        for (phase.tasks.items) |task| {
            try w.print("\n    - [{s}] {s}", .{ if (task.status == .completed) "X" else " ", task.content });
            switch (task.status) {
                .in_progress => try w.writeAll(" (in progress)"),
                .abandoned => try w.writeAll(" (dropped)"),
                .blocked => if (task.blocker) |reason| try w.print(" (blocked: {s})", .{reason}) else try w.writeAll(" (blocked)"),
                .pending, .completed => {},
            }
        }
    }
}

fn writeQuotedOrNone(w: *std.Io.Writer, text: ?[]const u8) std.Io.Writer.Error!void {
    if (text) |value| try std.json.Stringify.value(value, .{}, w) else try w.writeAll("none");
}

fn writeTarget(w: *std.Io.Writer, request: Request) std.Io.Writer.Error!void {
    if (request.task) |task| return std.json.Stringify.value(task, .{}, w);
    if (request.phase) |phase| {
        try w.writeAll("phase ");
        return std.json.Stringify.value(phase, .{}, w);
    }
    try w.writeAll("all tasks");
}

const verbs = std.enums.EnumArray(checklist.Op, []const u8).init(.{
    .init = "initialized",
    .start = "started",
    .done = "done",
    .rm = "removed",
    .drop = "dropped",
    .block = "blocked",
    .unblock = "unblocked",
    .append = "appended",
    .view = "viewed",
});

fn writeAck(arena: Allocator, w: *std.Io.Writer, previous: *const List, next: *const List, request: Request) (Allocator.Error || std.Io.Writer.Error)!void {
    _ = arena;
    const total = next.taskCount();
    if (request.op == .rm and request.task == null and request.phase == null and total == 0) return w.writeAll("Removed all tasks.");
    if (request.op == .append) {
        const count = if (request.items) |items| items.len else 0;
        try w.print("appended {d} task{s} to ", .{ count, if (count == 1) "" else "s" });
    } else {
        try w.print("{s} ", .{verbs.get(request.op)});
    }
    try writeTarget(w, request);
    if (request.op == .block) try w.print(": {s}", .{request.reason orelse "no reason given"});
    try w.print(" ({d}/{d} done)", .{ next.countWhere(checklist.isClosed), total });
    const current = next.nextActionable();
    if (completedPhase(previous, next)) |phase| {
        try w.writeAll("; phase ");
        try std.json.Stringify.value(phase.name, .{}, w);
        try w.writeAll(" complete");
        if (current) |task| if (next.phaseOf(task)) |next_phase| {
            try w.writeAll(" → next phase ");
            try std.json.Stringify.value(next_phase.name, .{}, w);
        };
        return;
    }
    try w.writeAll(" → in progress: ");
    try writeQuotedOrNone(w, if (current) |task| task.content else null);
}

/// The first phase this change closed: it had open tasks and now has none.
fn completedPhase(previous: *const List, next: *const List) ?*const checklist.Phase {
    for (next.phases.items) |*phase| {
        const before = for (previous.phases.items) |*candidate| {
            if (std.mem.eql(u8, candidate.name, phase.name)) break candidate;
        } else continue;
        if (!hasOpen(before.*)) continue;
        if (phase.tasks.items.len == 0) continue;
        const all_closed = for (phase.tasks.items) |task| {
            if (!checklist.isClosed(task.status)) break false;
        } else true;
        if (all_closed) return phase;
    }
    return null;
}

// -- The reminder at a turn's end (D232) -------------------------------------

/// Reminders one turn gets before it may end with open tasks, as proto's
/// `checklist.remindersMax` default.
pub const reminder_cap = 3;

/// The hidden reminder `attempt` (1-based) for `list`'s open tasks.
pub fn reminder(arena: Allocator, list: *const List, attempt: usize) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeReminder(w, list, attempt) catch return error.OutOfMemory;
    return out.written();
}

fn writeReminder(w: *std.Io.Writer, list: *const List, attempt: usize) std.Io.Writer.Error!void {
    const open = list.countWhere(checklist.isOpen);
    try w.print("<system-reminder>\nYou stopped with {d} incomplete checklist item{s}:", .{ open, if (open == 1) "" else "s" });
    for (list.phases.items) |phase| {
        if (!hasOpen(phase)) continue;
        try w.print("\n- {s}", .{phase.name});
        for (phase.tasks.items) |task| if (checklist.isOpen(task.status)) try w.print("\n  - {s}", .{task.content});
    }
    try w.print("\n\nContinue working on these tasks, or mark them done, dropped or blocked with the checklist tool if they are settled.\n(Reminder {d}/{d})\n</system-reminder>", .{ attempt, reminder_cap });
}

/// What the person sees, under the `checklist` topic, when the agent is
/// reminded: "2 items still open · reminder 1 of 3".
pub fn reminderNotice(arena: Allocator, list: *const List, attempt: usize) Allocator.Error![]u8 {
    const open = list.countWhere(checklist.isOpen);
    return arena.print("{d} item{s} still open · reminder {d} of {d}", .{ open, if (open == 1) "" else "s", attempt, reminder_cap });
}

// -- Tests -------------------------------------------------------------------

const testing = std.testing;

fn textFor(list: *const List, args: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = (try checklist.parseRequest(a, args, list.taskCount() > 0)).request;
    var applied = try checklist.apply(testing.allocator, list, request);
    defer applied.deinit();
    return testing.allocator.dupe(u8, try resultText(a, list, &applied.list, request, applied.errors));
}

test "a done acknowledgement names only the completed and next tasks" {
    var list = try checklist.testList(testing.allocator, &.{.{ "Phase", &.{ .{ "first task", .in_progress }, .{ "second task", .pending }, .{ "third task", .pending } } }});
    defer list.deinit();
    const text = try textFor(&list, "{\"op\":\"done\",\"task\":\"first task\"}");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("done \"first task\" (1/3 done) → in progress: \"second task\"", text);
}

test "closing a phase names the next phase" {
    var list = try checklist.testList(testing.allocator, &.{
        .{ "Build", &.{.{ "a", .in_progress }} },
        .{ "Ship", &.{.{ "b", .pending }} },
    });
    defer list.deinit();
    const text = try textFor(&list, "{\"op\":\"done\",\"phase\":\"Build\"}");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("done phase \"Build\" (1/2 done); phase \"Build\" complete → next phase \"Ship\"", text);
}

test "init and view print the tree, errors print the hint" {
    var empty: List = .init(testing.allocator);
    defer empty.deinit();
    const init_text = try textFor(&empty, "{\"op\":\"init\",\"items\":[\"Apply fix\",\"Run tests\"]}");
    defer testing.allocator.free(init_text);
    try testing.expectEqualStrings("Initialized 2 tasks in 1 phases; in progress: \"Apply fix\"\n  Tasks:\n    - [ ] Apply fix (in progress)\n    - [ ] Run tests", init_text);
    const view_text = try textFor(&empty, "{\"op\":\"view\"}");
    defer testing.allocator.free(view_text);
    try testing.expectEqualStrings("The checklist is empty.", view_text);
    const error_text = try textFor(&empty, "{\"op\":\"done\",\"task\":\"x\"}");
    defer testing.allocator.free(error_text);
    try testing.expect(std.mem.endsWith(u8, error_text, "\n" ++ view_hint));

    var list = try checklist.testList(testing.allocator, &.{
        .{ "Build", &.{ .{ "a", .in_progress }, .{ "b", .blocked } } },
        .{ "Ship", &.{.{ "c", .completed }} },
    });
    defer list.deinit();
    const viewed = try textFor(&list, "{\"op\":\"view\"}");
    defer testing.allocator.free(viewed);
    try testing.expect(std.mem.startsWith(u8, viewed, "Overall: 1/3 done, 1 open, 1 blocked.\nActive phase 1/2 \"Build\" (0/2): the earliest"));
}

test "the reminder lists open tasks by phase and leaves blocked ones out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list = try checklist.testList(testing.allocator, &.{
        .{ "Build", &.{ .{ "a", .completed }, .{ "b", .in_progress }, .{ "c", .blocked } } },
        .{ "Ship", &.{.{ "d", .pending }} },
    });
    defer list.deinit();
    const text = try reminder(arena.allocator(), &list, 1);
    try testing.expect(std.mem.find(u8, text, "2 incomplete checklist items:\n- Build\n  - b\n- Ship\n  - d\n") != null);
    try testing.expect(std.mem.find(u8, text, "(Reminder 1/3)") != null);
    try testing.expectEqualStrings("2 items still open · reminder 1 of 3", try reminderNotice(arena.allocator(), &list, 1));
}

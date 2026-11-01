//! How a checklist call reads in the transcript (D234), from its
//! arguments and the text it returned: a row that says what changed,
//! "Completed Write parser", and under it the list after `init` and
//! `view` drawn as proto draws its checklist, or the progress and the
//! task now in progress after other changes. Ids never show.
const std = @import("std");
const checklist = @import("checklist.zig");

const Allocator = std.mem.Allocator;

/// Task rows a list shows before "… N more".
pub const max_task_rows = 12;

/// What a body row draws, so the renderer can give each its color.
pub const BodyRole = enum {
    /// A phase heading, "I. Build  1/3".
    phase,
    /// A task with its checkbox.
    task,
    /// Progress, a count of hidden rows, or a failure's reason.
    note,
};

/// One row under the headline: its text, what it draws, and for a task
/// row the status that picks its color.
pub const BodyRow = struct {
    text: []const u8,
    role: BodyRole = .note,
    status: ?checklist.Status = null,
};

pub const View = struct {
    /// The row's own text.
    headline: []const u8,
    /// Rows under it, in order.
    body: []const BodyRow,
};

/// Glyphs before a task, by status.
pub fn glyph(status: checklist.Status) []const u8 {
    return switch (status) {
        .completed => "✓",
        .in_progress => "→",
        .pending => "○",
        .abandoned => "×",
        .blocked => "!",
    };
}

/// Proto's checkbox: filled once the task is done, empty before.
pub fn checkbox(status: checklist.Status) []const u8 {
    return if (status == .completed) "■" else "□";
}

const roman_pairs = [_]struct { usize, []const u8 }{
    .{ 1000, "M" },
    .{ 900, "CM" },
    .{ 500, "D" },
    .{ 400, "CD" },
    .{ 100, "C" },
    .{ 90, "XC" },
    .{ 50, "L" },
    .{ 40, "XL" },
    .{ 10, "X" },
    .{ 9, "IX" },
    .{ 5, "V" },
    .{ 4, "IV" },
    .{ 1, "I" },
};

/// A phase's ordinal as proto numbers phases: 1 → "I", 4 → "IV".
pub fn romanNumeral(arena: Allocator, one_based: usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rem = one_based;
    for (roman_pairs) |pair| {
        while (rem >= pair[0]) {
            try out.appendSlice(arena, pair[1]);
            rem -= pair[0];
        }
    }
    return out.items;
}

/// The rows for a settled call. `failed` calls read by their reason.
pub fn view(arena: Allocator, args_json: []const u8, result: []const u8, failed: bool) Allocator.Error!?View {
    const parsed = checklist.parseRequest(arena, args_json, true) catch return error.OutOfMemory;
    const request = switch (parsed) {
        .request => |value| value,
        .invalid => return if (failed) .{ .headline = "Checklist not updated", .body = try noteBody(arena, try firstLine(arena, result)) } else null,
    };
    if (failed) return .{ .headline = "Checklist not updated", .body = try noteBody(arena, try firstLine(arena, result)) };
    const headline = try headlineFor(arena, request);
    var body: std.ArrayList(BodyRow) = .empty;
    switch (request.op) {
        .init, .view => try appendTree(arena, &body, result),
        else => if (readAck(arena, result)) |ack| {
            if (ack.phase_done) |phase| {
                if (ack.next_phase) |next_phase| {
                    try body.append(arena, .{ .text = try arena.print("{d} of {d} done · {s} complete, next: {s}", .{ ack.done, ack.total, phase, next_phase }) });
                } else {
                    try body.append(arena, .{ .text = try arena.print("{d} of {d} done · {s} complete", .{ ack.done, ack.total, phase }) });
                }
            } else if (ack.next) |next| {
                try body.append(arena, .{ .text = try arena.print("{d} of {d} done · next: {s}", .{ ack.done, ack.total, next }) });
            } else {
                try body.append(arena, .{ .text = try arena.print("{d} of {d} done", .{ ack.done, ack.total }) });
            }
        },
    }
    return .{ .headline = headline, .body = body.items };
}

fn noteBody(arena: Allocator, lines: []const []const u8) Allocator.Error![]const BodyRow {
    const out = try arena.alloc(BodyRow, lines.len);
    for (lines, 0..) |line, index| out[index] = .{ .text = line };
    return out;
}

fn firstLine(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    const line = std.mem.trim(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], " \t\r");
    if (line.len == 0) return &.{};
    const out = try arena.alloc([]const u8, 1);
    out[0] = line;
    return out;
}

fn headlineFor(arena: Allocator, request: checklist.Request) Allocator.Error![]const u8 {
    const task = request.task;
    const phase = request.phase;
    return switch (request.op) {
        .init => blk: {
            var tasks: usize = 0;
            var phases: usize = 1;
            if (request.list) |entries| {
                phases = entries.len;
                for (entries) |entry| tasks += entry.items.len;
            } else if (request.items) |items| tasks = items.len;
            break :blk if (phases > 1)
                arena.print("Planned {d} task{s} in {d} phases", .{ tasks, plural(tasks), phases })
            else
                arena.print("Planned {d} task{s}", .{ tasks, plural(tasks) });
        },
        .view => "Viewed the checklist",
        .start => target(arena, "Started", task, phase),
        .done => target(arena, "Completed", task, phase),
        .drop => target(arena, "Dropped", task, phase),
        .unblock => target(arena, "Unblocked", task, phase),
        .block => blk: {
            const named = try target(arena, "Blocked", task, phase);
            break :blk if (request.reason) |reason| arena.print("{s} · {s}", .{ named, reason }) else named;
        },
        .append => blk: {
            const count = if (request.items) |items| items.len else 0;
            break :blk arena.print("Added {d} task{s} to {s}", .{ count, plural(count), phase orelse "the checklist" });
        },
        .rm => if (task == null and phase == null) "Cleared the checklist" else target(arena, "Removed", task, phase),
    };
}

fn target(arena: Allocator, verb: []const u8, task: ?[]const u8, phase: ?[]const u8) Allocator.Error![]const u8 {
    if (task) |text| return arena.print("{s} {s}", .{ verb, text });
    if (phase) |name| return arena.print("{s} phase {s}", .{ verb, name });
    return verb;
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

/// The list in a result's tree as proto draws its checklist: each phase
/// as "I. Name  done/total" and its tasks under it as tree rows with a
/// checkbox, closed tasks struck through by the renderer. A long list
/// keeps its open tasks and the last closed one above them, then
/// "… N more".
fn appendTree(arena: Allocator, body: *std.ArrayList(BodyRow), result: []const u8) Allocator.Error!void {
    var phases: std.ArrayList(struct { name: []const u8, tasks: std.ArrayList(TreeTask) }) = .empty;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "    - [")) {
            if (phases.items.len == 0) continue;
            try phases.items[phases.items.len - 1].tasks.append(arena, readTask(line["    - [".len..]) orelse continue);
        } else if (std.mem.startsWith(u8, line, "  ") and std.mem.endsWith(u8, line, ":") and line.len > 3 and line[2] != ' ') {
            try phases.append(arena, .{ .name = line[2 .. line.len - 1], .tasks = .empty });
        }
    }
    var total: usize = 0;
    for (phases.items) |phase| total += phase.tasks.items.len;
    const compact = total > max_task_rows;

    // The tasks each phase would show, picked before drawing so the tree
    // branches and the hidden count are known.
    var selections: std.ArrayList(std.ArrayList(TreeTask)) = .empty;
    for (phases.items) |phase| {
        var picked: std.ArrayList(TreeTask) = .empty;
        if (!compact) {
            try picked.appendSlice(arena, phase.tasks.items);
        } else {
            // proto keeps the last closed task above the open ones; with
            // nothing open it keeps the list's head.
            var last_closed: ?TreeTask = null;
            var open: std.ArrayList(TreeTask) = .empty;
            for (phase.tasks.items) |task| {
                if (checklist.isClosed(task.status)) last_closed = task else try open.append(arena, task);
            }
            if (open.items.len == 0) {
                try picked.appendSlice(arena, phase.tasks.items[0..@min(phase.tasks.items.len, max_task_rows)]);
            } else {
                if (last_closed) |task| try picked.append(arena, task);
                for (open.items) |task| {
                    if (picked.items.len == max_task_rows) break;
                    try picked.append(arena, task);
                }
            }
        }
        try selections.append(arena, picked);
    }

    // The row budget then cuts the tail, phase by phase; rows the
    // selection or the budget left out are counted for the trailing note.
    var shown_per_phase: std.ArrayList(usize) = .empty;
    var budget_left: usize = max_task_rows;
    var hidden: usize = 0;
    for (phases.items, selections.items) |phase, picked| {
        const take = @min(picked.items.len, budget_left);
        try shown_per_phase.append(arena, take);
        budget_left -= take;
        hidden += phase.tasks.items.len - take;
    }
    var last_task_phase: usize = 0;
    for (shown_per_phase.items, 0..) |shown, index| if (shown > 0) {
        last_task_phase = index;
    };

    var numbered: usize = 0;
    for (phases.items, 0..) |phase, phase_index| {
        if (phase.tasks.items.len == 0) continue;
        numbered += 1;
        const picked = selections.items[phase_index];
        const shown_count = shown_per_phase.items[phase_index];
        if (phases.items.len > 1) {
            var done: usize = 0;
            for (phase.tasks.items) |task| done += @intFromBool(checklist.isClosed(task.status));
            try body.append(arena, .{
                .text = try arena.print("{s}. {s}  {d}/{d}", .{ try romanNumeral(arena, numbered), phase.name, done, phase.tasks.items.len }),
                .role = .phase,
            });
        }
        const summary_follows = hidden > 0 and phase_index == last_task_phase;
        for (picked.items[0..shown_count], 0..) |task, index| {
            const branch = if (index + 1 == shown_count and !summary_follows) "└─ " else "├─ ";
            const note: []const u8 = if (task.status == .blocked)
                if (task.blocker) |reason| try arena.print(" (blocked: {s})", .{reason}) else " (blocked)"
            else
                "";
            try body.append(arena, .{
                .text = try arena.print("{s}{s} {s}{s}", .{ branch, checkbox(task.status), task.content, note }),
                .role = .task,
                .status = task.status,
            });
        }
    }
    if (hidden > 0) try body.append(arena, .{ .text = try arena.print("└─ … {d} more", .{hidden}) });
}

const TreeTask = struct { content: []const u8, status: checklist.Status, blocker: ?[]const u8 = null };

/// "X] content (in progress)" as `summary.zig` writes a tree line.
fn readTask(rest: []const u8) ?TreeTask {
    if (rest.len < 3 or rest[1] != ']' or rest[2] != ' ') return null;
    var content = rest[3..];
    if (rest[0] == 'X') return .{ .content = content, .status = .completed };
    const suffixes = [_]struct { []const u8, checklist.Status }{
        .{ " (in progress)", .in_progress },
        .{ " (dropped)", .abandoned },
        .{ " (blocked)", .blocked },
    };
    for (suffixes) |suffix| if (std.mem.endsWith(u8, content, suffix[0])) {
        return .{ .content = content[0 .. content.len - suffix[0].len], .status = suffix[1] };
    };
    if (std.mem.endsWith(u8, content, ")")) if (std.mem.findLast(u8, content, " (blocked: ")) |at| {
        content = rest[3..];
        return .{ .content = content[0..at], .status = .blocked, .blocker = content[at + " (blocked: ".len .. content.len - 1] };
    };
    return .{ .content = content, .status = .pending };
}

pub const Ack = struct {
    done: usize,
    total: usize,
    next: ?[]const u8 = null,
    /// The phase the change closed, and the phase that comes next.
    phase_done: ?[]const u8 = null,
    next_phase: ?[]const u8 = null,
};

/// The progress and next task an acknowledgement names.
pub fn readAck(arena: Allocator, text: []const u8) ?Ack {
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, " (")) |open| : (from = open + 2) {
        const close = std.mem.findPos(u8, text, open, " done)") orelse return null;
        const counts = text[open + 2 .. close];
        const slash = std.mem.findScalar(u8, counts, '/') orelse continue;
        const done = std.fmt.parseInt(usize, counts[0..slash], 10) catch continue;
        const total = std.fmt.parseInt(usize, counts[slash + 1 ..], 10) catch continue;
        const tail = text[close + " done)".len ..];
        var ack: Ack = .{ .done = done, .total = total };
        const marker = " → in progress: ";
        if (std.mem.startsWith(u8, tail, marker)) {
            ack.next = std.json.parseFromSliceLeaky([]const u8, arena, tail[marker.len..], .{}) catch null;
        } else if (std.mem.startsWith(u8, tail, "; phase ")) {
            // `; phase "Build" complete → next phase "Ship"`
            const rest = tail["; phase ".len..];
            const end = std.mem.find(u8, rest, " complete") orelse return ack;
            ack.phase_done = std.json.parseFromSliceLeaky([]const u8, arena, rest[0..end], .{}) catch null;
            const next_marker = " complete → next phase ";
            if (std.mem.startsWith(u8, rest[end..], next_marker)) {
                ack.next_phase = std.json.parseFromSliceLeaky([]const u8, arena, rest[end + next_marker.len ..], .{}) catch null;
            }
        }
        return ack;
    }
    return null;
}

test "a change reads by what it did, with progress and the next task" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const done = (try view(a, "{\"op\":\"done\",\"task\":\"Write (parser)\"}", "done \"Write (parser)\" (1/3 done) → in progress: \"Add \\\"tests\\\" (2)\"", false)).?;
    try testing.expectEqualStrings("Completed Write (parser)", done.headline);
    try testing.expectEqualStrings("1 of 3 done · next: Add \"tests\" (2)", done.body[0].text);
    const blocked = (try view(a, "{\"op\":\"block\",\"task\":\"Tag\",\"reason\":\"review\"}", "blocked \"Tag\": review (0/1 done) → in progress: none", false)).?;
    try testing.expectEqualStrings("Blocked Tag · review", blocked.headline);
    try testing.expectEqualStrings("0 of 1 done", blocked.body[0].text);
    const phase = (try view(a, "{\"op\":\"done\",\"task\":\"c\"}", "done \"c\" (3/5 done); phase \"Write files\" complete → next phase \"Verify\"", false)).?;
    try testing.expectEqualStrings("3 of 5 done · Write files complete, next: Verify", phase.body[0].text);
    const failed = (try view(a, "{\"op\":\"done\",\"task\":\"x\"}", "Task \"x\" not found\nUse op:\"view\" to see exact task names.", true)).?;
    try testing.expectEqualStrings("Checklist not updated", failed.headline);
    try testing.expectEqualStrings("Task \"x\" not found", failed.body[0].text);
}

test "init and view show the list as proto's checklist, phases numbered and tasks boxed" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = "Initialized 3 tasks in 2 phases; in progress: \"Write parser\"\n  Build:\n    - [X] Write parser\n    - [ ] Add tests (in progress)\n  Ship:\n    - [ ] Tag release (blocked: waiting on review)";
    const shown = (try view(a, "{\"op\":\"init\",\"list\":[{\"phase\":\"Build\",\"items\":[\"a\",\"b\"]},{\"phase\":\"Ship\",\"items\":[\"c\"]}]}", result, false)).?;
    try testing.expectEqualStrings("Planned 3 tasks in 2 phases", shown.headline);
    try testing.expectEqual(BodyRole.phase, shown.body[0].role);
    try testing.expectEqual(BodyRole.task, shown.body[1].role);
    try testing.expectEqual(checklist.Status.completed, shown.body[1].status.?);
    const joined = try std.mem.join(a, "\n", &.{
        shown.body[0].text,
        shown.body[1].text,
        shown.body[2].text,
        shown.body[3].text,
        shown.body[4].text,
    });
    try testing.expectEqualStrings(
        \\I. Build  1/2
        \\├─ ■ Write parser
        \\└─ □ Add tests
        \\II. Ship  0/1
        \\└─ □ Tag release (blocked: waiting on review)
    , joined);
}

test "a long list keeps its open tasks with the last closed one above them, then a count" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const total = max_task_rows + 1;
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, "Initialized 13 tasks; in progress: \"task 1\"\n  Tasks:\n");
    for (1..total + 1) |index| {
        const status: checklist.Status = if (index == total) .completed else .pending;
        try result.appendSlice(a, switch (status) {
            .completed => "    - [X] ",
            else => "    - [ ] ",
        });
        try result.appendSlice(a, try a.print("task {d}\n", .{index}));
    }
    const shown = (try view(a, "{\"op\":\"view\"}", result.items, false)).?;
    // The last closed task leads, the open tasks follow, the budget cuts
    // the tail, and the count carries the last branch.
    try testing.expectEqualStrings("├─ ■ task 13", shown.body[0].text);
    try testing.expectEqualStrings("├─ □ task 1", shown.body[1].text);
    try testing.expectEqualStrings("├─ □ task 11", shown.body[11].text);
    const last = shown.body[shown.body.len - 1];
    try testing.expectEqualStrings("└─ … 1 more", last.text);
    try testing.expectEqual(@as(usize, max_task_rows + 1), shown.body.len);
}

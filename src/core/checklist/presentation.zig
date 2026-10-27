//! How a checklist call reads in the transcript (D234), from its
//! arguments and the text it returned: a row that says what changed,
//! "Completed Write parser", and under it the list after `init` and
//! `view`, or the progress and the task now in progress after other
//! changes. Ids never show.
const std = @import("std");
const checklist = @import("checklist.zig");

const Allocator = std.mem.Allocator;

/// Task rows a list shows before "… N more".
pub const max_task_rows = 12;

pub const View = struct {
    /// The row's own text.
    headline: []const u8,
    /// Rows under it, in order.
    body: []const []const u8,
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

/// The rows for a settled call. `failed` calls read by their reason.
pub fn view(arena: Allocator, args_json: []const u8, result: []const u8, failed: bool) Allocator.Error!?View {
    const parsed = checklist.parseRequest(arena, args_json, true) catch return error.OutOfMemory;
    const request = switch (parsed) {
        .request => |value| value,
        .invalid => return if (failed) .{ .headline = "Checklist not updated", .body = try firstLine(arena, result) } else null,
    };
    if (failed) return .{ .headline = "Checklist not updated", .body = try firstLine(arena, result) };
    const headline = try headlineFor(arena, request);
    var body: std.ArrayList([]const u8) = .empty;
    switch (request.op) {
        .init, .view => try appendTree(arena, &body, result),
        else => if (readAck(arena, result)) |ack| {
            if (ack.phase_done) |phase| {
                if (ack.next_phase) |next_phase| {
                    try body.append(arena, try arena.print("{d} of {d} done · {s} complete, next: {s}", .{ ack.done, ack.total, phase, next_phase }));
                } else {
                    try body.append(arena, try arena.print("{d} of {d} done · {s} complete", .{ ack.done, ack.total, phase }));
                }
            } else if (ack.next) |next| {
                try body.append(arena, try arena.print("{d} of {d} done · next: {s}", .{ ack.done, ack.total, next }));
            } else {
                try body.append(arena, try arena.print("{d} of {d} done", .{ ack.done, ack.total }));
            }
        },
    }
    return .{ .headline = headline, .body = body.items };
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

/// The list in a result's tree: phase names, then each task under its
/// phase with its glyph. A long list keeps its open tasks and the last
/// closed one before them, then "… N more".
fn appendTree(arena: Allocator, body: *std.ArrayList([]const u8), result: []const u8) Allocator.Error!void {
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
    var shown: usize = 0;
    var hidden: usize = 0;
    var total: usize = 0;
    for (phases.items) |phase| total += phase.tasks.items.len;
    const compact = total > max_task_rows;
    for (phases.items) |phase| {
        if (phase.tasks.items.len == 0) continue;
        if (phases.items.len > 1) {
            var done: usize = 0;
            for (phase.tasks.items) |task| done += @intFromBool(checklist.isClosed(task.status));
            try body.append(arena, try arena.print("{s} · {d}/{d}", .{ phase.name, done, phase.tasks.items.len }));
        }
        const indent = if (phases.items.len > 1) "  " else "";
        for (phase.tasks.items, 0..) |task, index| {
            const keep = !compact or (!checklist.isClosed(task.status)) or lastClosedBeforeOpen(phase.tasks.items, index);
            if (!keep or shown >= max_task_rows) {
                hidden += 1;
                continue;
            }
            shown += 1;
            const note = if (task.blocker) |reason| try arena.print(" · {s}", .{reason}) else "";
            try body.append(arena, try arena.print("{s}{s} {s}{s}", .{ indent, glyph(task.status), task.content, note }));
        }
    }
    if (hidden > 0) try body.append(arena, try arena.print("… {d} more", .{hidden}));
}

fn lastClosedBeforeOpen(tasks: []const TreeTask, index: usize) bool {
    if (index + 1 >= tasks.len) return false;
    return checklist.isClosed(tasks[index].status) and !checklist.isClosed(tasks[index + 1].status);
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
    try testing.expectEqualStrings("1 of 3 done · next: Add \"tests\" (2)", done.body[0]);
    const blocked = (try view(a, "{\"op\":\"block\",\"task\":\"Tag\",\"reason\":\"review\"}", "blocked \"Tag\": review (0/1 done) → in progress: none", false)).?;
    try testing.expectEqualStrings("Blocked Tag · review", blocked.headline);
    try testing.expectEqualStrings("0 of 1 done", blocked.body[0]);
    const phase = (try view(a, "{\"op\":\"done\",\"task\":\"c\"}", "done \"c\" (3/5 done); phase \"Write files\" complete → next phase \"Verify\"", false)).?;
    try testing.expectEqualStrings("3 of 5 done · Write files complete, next: Verify", phase.body[0]);
    const failed = (try view(a, "{\"op\":\"done\",\"task\":\"x\"}", "Task \"x\" not found\nUse op:\"view\" to see exact task names.", true)).?;
    try testing.expectEqualStrings("Checklist not updated", failed.headline);
    try testing.expectEqualStrings("Task \"x\" not found", failed.body[0]);
}

test "init and view show the list by phase with glyphs" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = "Initialized 3 tasks in 2 phases; in progress: \"Write parser\"\n  Build:\n    - [X] Write parser\n    - [ ] Add tests (in progress)\n  Ship:\n    - [ ] Tag release (blocked: waiting on review)";
    const shown = (try view(a, "{\"op\":\"init\",\"list\":[{\"phase\":\"Build\",\"items\":[\"a\",\"b\"]},{\"phase\":\"Ship\",\"items\":[\"c\"]}]}", result, false)).?;
    try testing.expectEqualStrings("Planned 3 tasks in 2 phases", shown.headline);
    const joined = try std.mem.join(a, "\n", shown.body);
    try testing.expectEqualStrings("Build · 1/2\n  ✓ Write parser\n  → Add tests\nShip · 0/1\n  ! Tag release · waiting on review", joined);
}

//! The live checklist above the composer (D252), after proto's checklist
//! widget. The terminal keeps a copy of the session's list here: in
//! process it follows the session runtime's store, detached it follows
//! the ACP plan the session's host sends after each checklist call. While
//! tasks are open the panel shows the progress, the active phase's tasks
//! and the phases after it; once every task is closed it collapses to one
//! line, and the next prompt the person sends puts it away. Which rows show
//! for a row budget is decided here, so the renderer only draws them.
const std = @import("std");
const checklist = @import("checklist.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const List = checklist.List;
const Status = checklist.Status;

/// The most rows the panel takes, header included.
pub const max_rows: u16 = 9;
/// Open tasks of the active phase shown before "N more".
const max_open_tasks = 5;
/// Phases after the active one shown before "N more phases".
const max_later_phases = 3;

pub const State = struct {
    /// The list shown, owned; null when the panel is hidden.
    list: ?List = null,
    /// The store revision `list` reflects, in process.
    revision: u64 = 0,
    /// Set once the person sends a prompt after the list settled; the
    /// panel stays away until the list changes again.
    dismissed: bool = false,

    pub fn deinit(self: *State) void {
        if (self.list) |*list| list.deinit();
        self.* = .{};
    }

    /// Takes ownership of `list`; null or an empty list hides the panel.
    pub fn adopt(self: *State, list: ?List) void {
        if (self.list) |*old| old.deinit();
        self.list = list;
        if (self.list) |*value| if (value.taskCount() == 0) {
            value.deinit();
            self.list = null;
        };
        self.dismissed = false;
    }

    /// Follows an in-process store. True when the panel changed.
    pub fn follow(self: *State, gpa: Allocator, store: *store_mod.Store) Allocator.Error!bool {
        const changed = (try store.snapshotSince(gpa, self.revision)) orelse return false;
        self.revision = changed.revision;
        self.adopt(changed.list);
        return true;
    }

    /// Adopts an ACP plan update's `entries` (D233): fx's own status and
    /// phase from `_meta.fx` when present, else the plan's status.
    pub fn adoptPlan(self: *State, gpa: Allocator, entries: []const std.json.Value) Allocator.Error!void {
        var list: List = .init(gpa);
        errdefer list.deinit();
        const a = list.arena.allocator();
        for (entries) |entry| {
            if (entry != .object) continue;
            const content = stringField(entry, "content") orelse continue;
            const fx = if (entry.object.get("_meta")) |meta| (if (meta == .object) meta.object.get("fx") else null) else null;
            const phase_name = (if (fx) |value| stringField(value, "phase") else null) orelse "Tasks";
            const status = statusOf((if (fx) |value| stringField(value, "status") else null) orelse stringField(entry, "status") orelse "pending");
            const blocker = if (fx) |value| stringField(value, "blocker") else null;
            if (list.phases.items.len == 0 or !std.mem.eql(u8, list.phases.items[list.phases.items.len - 1].name, phase_name)) {
                try list.phases.append(a, .{ .name = try a.dupe(u8, phase_name) });
            }
            const phase = &list.phases.items[list.phases.items.len - 1];
            try phase.tasks.append(a, .{
                .content = try a.dupe(u8, content),
                .status = status,
                .blocker = if (blocker) |text| try a.dupe(u8, text) else null,
            });
        }
        self.adopt(list);
    }

    /// The person sent a prompt: a settled list goes away.
    pub fn promptSent(self: *State) void {
        const list = if (self.list) |*value| value else return;
        if (settled(list)) self.dismissed = true;
    }

    /// The list to draw, or null when the panel is hidden.
    pub fn visible(self: *const State) ?*const List {
        if (self.dismissed) return null;
        return if (self.list) |*list| list else null;
    }
};

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn statusOf(name: []const u8) Status {
    return std.meta.stringToEnum(Status, name) orelse .pending;
}

/// Every task is closed: done or dropped.
pub fn settled(list: *const List) bool {
    return list.taskCount() > 0 and list.countWhere(checklist.isClosed) == list.taskCount();
}

pub const Row = union(enum) {
    /// "Checklist · 2 of 5 done", or the collapsed line once settled.
    header: struct { done: usize, total: usize, dropped: usize, settled: bool },
    /// A phase and its progress; `active` for the one in work.
    phase: struct { name: []const u8, done: usize, total: usize, active: bool },
    task: struct { content: []const u8, status: Status, blocker: ?[]const u8 },
    /// Tasks of the active phase that did not fit.
    more_tasks: usize,
    /// Phases after the shown ones.
    more_phases: usize,
};

/// The rows for `list` within `budget` rows, at most `max_rows`. The rows
/// borrow `list`. A row never wraps, so the count does not depend on the
/// terminal's width.
pub fn rows(list: *const List, budget: u16, out: *[max_rows]Row) []const Row {
    const limit: usize = @min(budget, max_rows);
    if (limit == 0) return out[0..0];
    var count: usize = 0;
    const closed = list.countWhere(checklist.isClosed);
    const dropped = list.countWhere(isDropped);
    const is_settled = settled(list);
    out[0] = .{ .header = .{ .done = closed - dropped, .total = list.taskCount(), .dropped = dropped, .settled = is_settled } };
    count = 1;
    if (is_settled) return out[0..count];

    const active = activePhase(list) orelse return out[0..count];
    const multi = nonEmptyPhases(list) > 1;
    // The rows after the active phase's tasks, kept when room runs short.
    var later_count: usize = 0;
    for (list.phases.items[active + 1 ..]) |phase| later_count += @intFromBool(phase.tasks.items.len > 0);
    const later_shown = @min(later_count, max_later_phases);
    const later_rows = later_shown + @intFromBool(later_count > later_shown);

    const phase = list.phases.items[active];
    if (multi and count < limit) {
        out[count] = .{ .phase = .{ .name = phase.name, .done = closedIn(phase), .total = phase.tasks.items.len, .active = true } };
        count += 1;
    }
    // Task rows: the open ones, a "N more" row when they are cut, and the
    // last closed task before them when there is room.
    const remaining = limit -| count;
    const task_room = remaining - @min(later_rows, remaining / 2);
    var last_closed: ?usize = null;
    var open_total: usize = 0;
    for (phase.tasks.items, 0..) |task, index| {
        if (checklist.isClosed(task.status)) last_closed = index else open_total += 1;
    }
    var open_fit = @min(open_total, max_open_tasks, task_room);
    if (open_fit < open_total and open_fit == task_room) open_fit -|= 1;
    const more = open_total > open_fit;
    const context = last_closed != null and task_room > open_fit + @intFromBool(more);
    var shown: [max_rows]usize = undefined;
    var shown_len: usize = 0;
    if (context) {
        shown[0] = last_closed.?;
        shown_len = 1;
    }
    var open_shown: usize = 0;
    for (phase.tasks.items, 0..) |task, index| {
        if (checklist.isClosed(task.status)) continue;
        if (open_shown == open_fit) break;
        shown[shown_len] = index;
        shown_len += 1;
        open_shown += 1;
    }
    std.mem.sort(usize, shown[0..shown_len], {}, std.sort.asc(usize));
    for (shown[0..shown_len]) |index| {
        const task = phase.tasks.items[index];
        out[count] = .{ .task = .{ .content = task.content, .status = task.status, .blocker = task.blocker } };
        count += 1;
    }
    if (more and count < limit) {
        out[count] = .{ .more_tasks = open_total - open_fit };
        count += 1;
    }
    var phases_shown: usize = 0;
    for (list.phases.items[active + 1 ..]) |later| {
        if (later.tasks.items.len == 0) continue;
        if (phases_shown == later_shown or count >= limit) break;
        out[count] = .{ .phase = .{ .name = later.name, .done = closedIn(later), .total = later.tasks.items.len, .active = false } };
        count += 1;
        phases_shown += 1;
    }
    if (later_count > phases_shown and count < limit) {
        out[count] = .{ .more_phases = later_count - phases_shown };
        count += 1;
    }
    return out[0..count];
}

/// The rows the panel asks for, before any terminal limit.
pub fn wantedRows(list: *const List) u16 {
    var buf: [max_rows]Row = undefined;
    return @intCast(rows(list, max_rows, &buf).len);
}

fn isDropped(status: Status) bool {
    return status == .abandoned;
}

fn closedIn(phase: checklist.Phase) usize {
    var count: usize = 0;
    for (phase.tasks.items) |task| count += @intFromBool(checklist.isClosed(task.status));
    return count;
}

fn nonEmptyPhases(list: *const List) usize {
    var count: usize = 0;
    for (list.phases.items) |phase| count += @intFromBool(phase.tasks.items.len > 0);
    return count;
}

/// The first phase with work not closed, as proto's widget picks it.
fn activePhase(list: *const List) ?usize {
    for (list.phases.items, 0..) |phase, index| {
        for (phase.tasks.items) |task| if (!checklist.isClosed(task.status)) return index;
    }
    return null;
}

test "the panel shows progress, the active phase and what follows, within a budget" {
    const gpa = std.testing.allocator;
    var list = try checklist.testList(gpa, &.{
        .{ "Build", &.{ .{ "Write parser", .completed }, .{ "Add tests", .in_progress }, .{ "Docs", .pending } } },
        .{ "Ship", &.{ .{ "Tag release", .blocked }, .{ "Announce", .pending } } },
        .{ "Later", &.{.{ "Retro", .pending }} },
    });
    defer list.deinit();
    var buf: [max_rows]Row = undefined;
    const all = rows(&list, max_rows, &buf);
    try std.testing.expectEqual(@as(usize, 7), all.len);
    try std.testing.expectEqual(@as(usize, 1), all[0].header.done);
    try std.testing.expectEqual(@as(usize, 6), all[0].header.total);
    try std.testing.expect(all[1].phase.active);
    try std.testing.expectEqualStrings("Write parser", all[2].task.content);
    try std.testing.expectEqualStrings("Docs", all[4].task.content);
    try std.testing.expectEqualStrings("Ship", all[5].phase.name);
    try std.testing.expect(!all[5].phase.active);
    // A short budget keeps the header and the open work first.
    const three = rows(&list, 3, &buf);
    try std.testing.expectEqual(@as(usize, 3), three.len);
    try std.testing.expect(three[0] == .header);
    try std.testing.expect(three[2] == .more_tasks or three[2] == .task);
    try std.testing.expectEqual(@as(usize, 1), rows(&list, 1, &buf).len);
    try std.testing.expectEqual(@as(usize, 0), rows(&list, 0, &buf).len);
}

test "many open tasks show a count of the rest, and a settled list one line" {
    const gpa = std.testing.allocator;
    var list = try checklist.testList(gpa, &.{
        .{ "Work", &.{ .{ "a", .in_progress }, .{ "b", .pending }, .{ "c", .pending }, .{ "d", .pending }, .{ "e", .pending }, .{ "f", .pending }, .{ "g", .pending } } },
    });
    defer list.deinit();
    var buf: [max_rows]Row = undefined;
    const shown = rows(&list, max_rows, &buf);
    try std.testing.expect(shown[shown.len - 1] == .more_tasks);
    try std.testing.expectEqual(@as(usize, 2), shown[shown.len - 1].more_tasks);
    for (shown) |row| try std.testing.expect(row != .phase);

    var done = try checklist.testList(gpa, &.{.{ "Work", &.{ .{ "a", .completed }, .{ "b", .abandoned } } }});
    defer done.deinit();
    const one = rows(&done, max_rows, &buf);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expect(one[0].header.settled);
    try std.testing.expectEqual(@as(usize, 1), one[0].header.dropped);
    try std.testing.expectEqual(@as(usize, 1), one[0].header.done);
}

test "the panel follows a store, reads a plan, and goes away after the next prompt once settled" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var store: store_mod.Store = .{ .gpa = gpa };
    defer store.deinit();
    var state: State = .{};
    defer state.deinit();
    try std.testing.expect(!try state.follow(gpa, &store));
    _ = try store.run(arena.allocator(), "{\"op\":\"init\",\"items\":[\"one\",\"two\"]}");
    try std.testing.expect(try state.follow(gpa, &store));
    try std.testing.expect(!try state.follow(gpa, &store));
    try std.testing.expectEqual(@as(usize, 2), state.visible().?.taskCount());
    state.promptSent();
    try std.testing.expect(state.visible() != null);
    _ = try store.run(arena.allocator(), "{\"op\":\"done\",\"task\":\"one\"}");
    _ = try store.run(arena.allocator(), "{\"op\":\"done\",\"task\":\"two\"}");
    _ = try state.follow(gpa, &store);
    try std.testing.expect(settled(state.visible().?));
    state.promptSent();
    try std.testing.expect(state.visible() == null);

    const plan =
        \\[{"content":"Write parser","status":"completed","_meta":{"fx":{"phase":"Build","status":"completed"}}},
        \\ {"content":"Tag release","status":"pending","_meta":{"fx":{"phase":"Ship","status":"blocked","blocker":"review"}}},
        \\ {"content":"Plain","status":"in_progress"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, plan, .{});
    defer parsed.deinit();
    try state.adoptPlan(gpa, parsed.value.array.items);
    const list = state.visible().?;
    try std.testing.expectEqual(@as(usize, 3), list.phases.items.len);
    try std.testing.expectEqual(Status.blocked, list.phases.items[1].tasks.items[0].status);
    try std.testing.expectEqualStrings("review", list.phases.items[1].tasks.items[0].blocker.?);
    try std.testing.expectEqualStrings("Tasks", list.phases.items[2].name);
    try state.adoptPlan(gpa, &.{});
    try std.testing.expect(state.visible() == null);
}

//! How a checklist is saved with its session (D231): the session log's
//! `checklist` setting holds the whole list as JSON,
//! `{"phases":[{"name":…,"tasks":[{"content":…,"status":…,"blocker":…}]}]}`.
//! Status names are `checklist.Status` tag names.
const std = @import("std");
const checklist = @import("checklist.zig");

const Allocator = std.mem.Allocator;
const List = checklist.List;

const SavedTask = struct {
    content: []const u8,
    status: checklist.Status,
    blocker: ?[]const u8 = null,
};

const SavedPhase = struct {
    name: []const u8,
    tasks: []const SavedTask,
};

const Saved = struct { phases: []const SavedPhase };

/// The JSON for `list`. Caller owns it.
pub fn encode(alloc: Allocator, list: *const List) Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const phases = try a.alloc(SavedPhase, list.phases.items.len);
    for (list.phases.items, phases) |phase, *slot| {
        const tasks = try a.alloc(SavedTask, phase.tasks.items.len);
        for (phase.tasks.items, tasks) |task, *saved| saved.* = .{ .content = task.content, .status = task.status, .blocker = task.blocker };
        slot.* = .{ .name = phase.name, .tasks = tasks };
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(Saved{ .phases = phases }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A list from saved JSON, in a new arena over `gpa`. Caller owns it.
pub fn decode(gpa: Allocator, json: []const u8) error{ OutOfMemory, InvalidChecklist }!List {
    var list: List = .init(gpa);
    errdefer list.deinit();
    const a = list.arena.allocator();
    const saved = std.json.parseFromSliceLeaky(Saved, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidChecklist,
    };
    try list.phases.ensureTotalCapacity(a, saved.phases.len);
    for (saved.phases) |phase| {
        var tasks: std.ArrayList(checklist.Task) = .empty;
        try tasks.ensureTotalCapacity(a, phase.tasks.len);
        for (phase.tasks) |task| tasks.appendAssumeCapacity(.{ .content = task.content, .status = task.status, .blocker = task.blocker });
        list.phases.appendAssumeCapacity(.{ .name = phase.name, .tasks = tasks });
    }
    return list;
}

test "a saved checklist reads back the same" {
    const testing = std.testing;
    var list = try checklist.testList(testing.allocator, &.{
        .{ "Build", &.{ .{ "Write \"parser\"", .completed }, .{ "Add tests", .in_progress } } },
        .{ "Ship", &.{.{ "Tag release", .blocked }} },
    });
    defer list.deinit();
    list.phases.items[1].tasks.items[0].blocker = "waiting on review";
    const json = try encode(testing.allocator, &list);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"phases\":[{\"name\":\"Build\",\"tasks\":[{\"content\":\"Write \\\"parser\\\"\",\"status\":\"completed\"},{\"content\":\"Add tests\",\"status\":\"in_progress\"}]},{\"name\":\"Ship\",\"tasks\":[{\"content\":\"Tag release\",\"status\":\"blocked\",\"blocker\":\"waiting on review\"}]}]}",
        json,
    );
    var back = try decode(testing.allocator, json);
    defer back.deinit();
    try testing.expect(list.eql(&back));
    try testing.expectError(error.InvalidChecklist, decode(testing.allocator, "{\"phases\":[{\"name\":\"x\"}]}"));
    try testing.expectError(error.InvalidChecklist, decode(testing.allocator, "{\"phases\":[{\"name\":\"x\",\"tasks\":[{\"content\":\"y\",\"status\":\"later\"}]}]}"));
}

//! The checklist reminder through the agent loop (D232): a turn that stops
//! with open tasks is reminded once, and a reply that runs no tool after
//! the reminder ends the turn without another.
const std = @import("std");
const types = @import("../../../shared/types.zig");
const test_support = @import("support.zig");
const checklist_store = @import("../../../checklist/store.zig");

const FakeGateway = test_support.FakeGateway;
const FakeCompletion = test_support.FakeCompletion;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PromptFixture = test_support.PromptFixture;
const runFakePrompt = test_support.runFakePrompt;
const logIndex = test_support.logIndex;

test "a turn that stops with open checklist tasks is reminded, then may end" {
    const alloc = std.testing.allocator;
    var store: checklist_store.Store = .{ .gpa = alloc };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    _ = try store.run(arena.allocator(), "{\"op\":\"init\",\"items\":[\"Write parser\",\"Add tests\"]}");

    var gateway = FakeGateway.init(alloc, &[_]FakeCompletion{
        .{ .content = "The parser is written." },
        .{ .content = "Stopping here." },
    });
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.checklist = &store;
    var fixture = PromptFixture{};
    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    const second = gateway.request_bodies.items[1];
    try std.testing.expect(std.mem.find(u8, second, "You stopped with 2 incomplete checklist items") != null);
    try std.testing.expect(std.mem.find(u8, second, "Write parser") != null);
    try std.testing.expect(logIndex(&hooks, "checklist_notice:2 items still open · reminder 1 of 3") != null);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
}

test "a turn whose checklist is closed or that asks the person gets no reminder" {
    const alloc = std.testing.allocator;
    var store: checklist_store.Store = .{ .gpa = alloc };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    _ = try store.run(arena.allocator(), "{\"op\":\"init\",\"items\":[\"Write parser\"]}");

    var asking = FakeGateway.init(alloc, &[_]FakeCompletion{.{ .content = "Which parser library should I use?" }});
    defer asking.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.checklist = &store;
    var fixture = PromptFixture{};
    try runFakePrompt(&asking, &hooks, fixture.config(), fixture.job());
    try std.testing.expectEqual(@as(usize, 1), asking.request_bodies.items.len);

    _ = try store.run(arena.allocator(), "{\"op\":\"done\",\"task\":\"Write parser\"}");
    var done = FakeGateway.init(alloc, &[_]FakeCompletion{.{ .content = "All done." }});
    defer done.deinit();
    var later = FakeAgentRuntimeDeps.init(alloc);
    defer later.deinit();
    later.checklist = &store;
    var later_fixture = PromptFixture{};
    try runFakePrompt(&done, &later, later_fixture.config(), later_fixture.job());
    try std.testing.expectEqual(@as(usize, 1), done.request_bodies.items.len);
    _ = types;
}

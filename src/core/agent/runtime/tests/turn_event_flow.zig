//! `AgentRuntimeDeps.emit` for a front end that still sets the `push_*`
//! sinks: each `TurnEvent` reaches the sink it replaces, in the order the
//! loop emits it, and a sink that frees what it gets gets a copy of the lent
//! event.
const std = @import("std");
const support = @import("support.zig");

fn expectLog(fake: *const support.FakeAgentRuntimeDeps, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, fake.log.items.len);
    for (expected, fake.log.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "emit forwards each turn event to the sink it replaces, in order" {
    var fake: support.FakeAgentRuntimeDeps = .{ .alloc = std.testing.allocator, .enable_interactive_notices = true };
    defer fake.deinit();
    const deps = fake.deps();

    try deps.emit(.{ .text = .{ .assistant_rendered = "hello" } });
    try deps.emit(.{ .worker = .{ .tool_lifecycle = .{ .provisional = .{
        .id = .{ .turn_id = 1, .call_id = "call_1" },
        .tool_name = "read_file",
        .activity_kind = .read,
    } } } });
    try deps.emit(.{ .notice = .{ .plain = "plain only" } });
    try deps.emit(.{ .notice = .{ .semantic = .{ .topic = "skills", .tone = .warning, .body = "rich" }, .plain = "fallback" } });
    try deps.emit(.{ .context_notice = "context" });
    try deps.emit(.{ .worker = .{ .command_output_complete = .{ .turn_id = 1, .call_id = "call_1" } } });
    try deps.emit(.{ .worker = .clear_route_recovery_status });
    try deps.emit(.{ .http_error = .{ .status = .unauthorized, .detail = "refused", .credential_source = null } });
    try deps.emit(.{ .text = .{ .operational = "done" } });

    try expectLog(&fake, &.{
        "text:hello",
        "status:started",
        "system_notice:plain only",
        "interactive_notice:skills:rich",
        "context_notice:context",
        "command_output_complete:1:call_1",
        "event:clear_route_recovery_status",
        "http_error",
        "text:done",
    });
    try std.testing.expectEqualStrings("refused", fake.http_detail.?);
}

test "a front end without interactive notices gets a notice's plain text, and nothing when it has none" {
    var fake: support.FakeAgentRuntimeDeps = .{ .alloc = std.testing.allocator };
    defer fake.deinit();
    const deps = fake.deps();

    try deps.emit(.{ .notice = .{ .semantic = .{ .topic = "system", .tone = .warning, .body = "rich" }, .plain = "fallback" } });
    try deps.emit(.{ .notice = .{ .semantic = .{ .topic = "skills", .tone = .warning, .body = "details" } } });
    // No session sink and no reasoning sink: both are dropped, as the loop
    // dropped them when the sink was null.
    try deps.emit(.{ .session_notice = "once" });
    try deps.emit(.{ .reasoning_delta = "thinking" });

    try expectLog(&fake, &.{"system_notice:fallback"});
}

test "push_event and push_diff_block get a copy of the lent event, which they free" {
    var fake: support.FakeAgentRuntimeDeps = .{ .alloc = std.testing.allocator };
    defer fake.deinit();
    const deps = fake.deps();

    // Lent strings the sink must not free: freeing these would crash.
    var tool = "write_file".*;
    var target = "/work/a.txt".*;
    try deps.emit(.{ .worker = .{ .session_grant = .{ .tool_name = &tool, .target_path = &target } } });
    var preview = "+one\n".*;
    try deps.emit(.{ .worker = .{ .diff_block = .{ .preview = &preview } } });

    try expectLog(&fake, &.{ "event:session_grant:write_file:/work/a.txt", "diff" });
    try std.testing.expectEqualStrings("write_file", &tool);
    try std.testing.expectEqualStrings("+one\n", fake.diff_preview.?);
}

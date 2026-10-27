const std = @import("std");
const hub = @import("hub.zig");
const catalog = @import("catalog.zig");
const types = @import("../shared/types.zig");

const alloc = std.testing.allocator;

fn fixture() !catalog.Snapshot {
    var builder: catalog.Builder = .init(alloc);
    errdefer builder.deinit();
    const cento = try builder.addProvider(.{ .key = "cento", .name = "cento", .detail = "No sign-in needed", .signed_in = true, .active = true, .sign_in = .settings, .can_sign_out = false });
    const router = try builder.addProvider(.{ .key = "openrouter", .name = "OpenRouter", .detail = "Saved key", .signed_in = true, .active = false, .sign_in = .login, .can_sign_out = true });
    const zen = try builder.addProvider(.{ .key = "opencode-go", .name = "OpenCode Go", .detail = "Not signed in", .signed_in = false, .active = false, .sign_in = .login, .can_sign_out = false });
    const efforts = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("high") };
    try builder.addModel(.{ .provider = cento, .id = "claude-cento", .name = "Claude Cento", .current = true, .efforts = &efforts, .roles = &.{.default} });
    try builder.addModel(.{ .provider = cento, .id = "claude-cento-lite", .name = "" });
    try builder.addModel(.{ .provider = router, .id = "anthropic/claude-sonnet-5.5", .name = "Claude Sonnet 5.5" });
    try builder.addModel(.{ .provider = zen, .id = "glm-5.3", .name = "" });
    for (catalog.role_order) |role| try builder.addRole(.{ .role = role, .chain = "the session's model", .cycle_position = if (role == .default) 1 else null });
    try builder.addWebSearch(.{ .id = "exa", .name = "Exa", .excluded = false, .ready = false });
    try builder.addWebSearch(.{ .id = "duckduckgo", .name = "DuckDuckGo", .excluded = false, .ready = true });
    return builder.finish(&.{.default});
}

fn openHub(state: *hub.State, start: hub.Start) !void {
    try state.open(alloc, try fixture(), start);
}

fn typeText(state: *hub.State, text: []const u8) !void {
    for (text) |byte| _ = try state.handle(alloc, .{ .char = byte });
}

test "/model opens on all signed-in models with the current one highlighted" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .models);
    try std.testing.expectEqual(hub.ScopeKind.all_models, state.scope.kind);
    try std.testing.expectEqual(hub.Focus.list, state.focus);
    // The locked provider's model is not listed.
    try std.testing.expectEqual(@as(usize, 3), state.rows.items.len);
    const snapshot = state.snapshot.?;
    try std.testing.expect(snapshot.models[state.selectedModel().?].current);
    try std.testing.expectEqualDeep(hub.Effect{ .select_model = .{ .model = state.selectedModel().? } }, try state.handle(alloc, .enter));
}

test "typing searches fuzzily and Escape clears the query before closing" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .models);
    try typeText(&state, "sonnet");
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    try std.testing.expectEqualStrings("Claude Sonnet 5.5", state.snapshot.?.models[state.selectedModel().?].name);
    _ = try state.handle(alloc, .backspace);
    try std.testing.expectEqualStrings("sonne", state.query());
    try std.testing.expectEqual(hub.Effect.redraw, try state.handle(alloc, .escape));
    try std.testing.expectEqualStrings("", state.query());
    try std.testing.expectEqual(hub.Effect.close, try state.handle(alloc, .escape));
}

test "/provider opens on the active provider in the sidebar" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .providers);
    try std.testing.expectEqual(hub.Focus.scope, state.focus);
    try std.testing.expectEqual(hub.ScopeKind.provider, state.scope.kind);
    try std.testing.expectEqualStrings("cento", state.snapshot.?.providers[state.scope.provider].name);
    // Down walks the sidebar to the next provider and lists its models.
    _ = try state.handle(alloc, .down);
    try std.testing.expectEqualStrings("OpenRouter", state.snapshot.?.providers[state.scope.provider].name);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    // Delete asks before signing out; Enter confirms.
    _ = try state.handle(alloc, .delete);
    try std.testing.expect(state.strip == .sign_out);
    try std.testing.expectEqualDeep(hub.Effect{ .sign_out = state.scope.provider }, try state.handle(alloc, .enter));
    // The locked provider offers sign-in on Enter.
    _ = try state.handle(alloc, .down);
    try std.testing.expectEqualStrings("OpenCode Go", state.snapshot.?.providers[state.scope.provider].name);
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expectEqualDeep(hub.Effect{ .sign_in = state.scope.provider }, try state.handle(alloc, .enter));
    _ = try state.handle(alloc, .down);
    try std.testing.expectEqual(hub.ScopeKind.web_search, state.scope.kind);
    _ = try state.handle(alloc, .down);
    try std.testing.expectEqual(hub.ScopeKind.roles, state.scope.kind);
}

test "assigning from the Roles list picks a model and returns to the role" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .models);
    _ = try state.handle(alloc, .left);
    _ = try state.handle(alloc, .home);
    try std.testing.expectEqual(hub.ScopeKind.roles, state.scope.kind);
    _ = try state.handle(alloc, .right);
    _ = try state.handle(alloc, .down);
    try std.testing.expectEqualDeep(hub.Effect{ .toggle_cycle = .small }, try state.handle(alloc, .{ .char = 'c' }));
    try std.testing.expectEqualDeep(hub.Effect{ .clear_role = .small }, try state.handle(alloc, .{ .char = 'x' }));
    _ = try state.handle(alloc, .enter);
    try std.testing.expectEqual(hub.Role.small, state.assigning.?);
    try std.testing.expectEqual(hub.ScopeKind.all_models, state.scope.kind);
    try typeText(&state, "lite");
    const effect = try state.handle(alloc, .enter);
    try std.testing.expectEqual(hub.Role.small, effect.assign_role.role);
    try std.testing.expectEqualStrings("claude-cento-lite", state.snapshot.?.models[effect.assign_role.model].id);
    try std.testing.expectEqual(hub.ScopeKind.roles, state.scope.kind);
    try std.testing.expectEqual(hub.Role.small, state.snapshot.?.roles[state.rows.items[state.selected]].role);
    // Moving a role in the cycle needs it to be in the cycle.
    try std.testing.expectEqual(hub.Effect.none, try state.handle(alloc, .{ .char = ']' }));
    _ = try state.handle(alloc, .up);
    try std.testing.expectEqualDeep(hub.Effect{ .move_cycle = .{ .role = .default, .later = true } }, try state.handle(alloc, .{ .char = ']' }));
}

test "the role and thinking strips act on the highlighted model" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .models);
    _ = try state.handle(alloc, .role_strip);
    // The first chip is Default, which this model already holds: Enter clears it.
    try std.testing.expectEqualDeep(hub.Effect{ .clear_role = .default }, try state.handle(alloc, .enter));
    _ = try state.handle(alloc, .role_strip);
    _ = try state.handle(alloc, .right);
    const assigned = try state.handle(alloc, .enter);
    try std.testing.expectEqual(hub.Role.small, assigned.assign_role.role);
    _ = try state.handle(alloc, .thinking_strip);
    try std.testing.expectEqual(@as(usize, 3), state.stripCount());
    _ = try state.handle(alloc, .left);
    const chosen = try state.handle(alloc, .enter);
    try std.testing.expect(chosen.select_model.effort.?.eql(types.ReasoningEffort.literal("high")));
    _ = try state.handle(alloc, .thinking_strip);
    try std.testing.expectEqual(hub.Effect.redraw, try state.handle(alloc, .escape));
    try std.testing.expect(state.strip == .none);
}

test "web search rows toggle and move with the highlight" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .providers);
    _ = try state.handle(alloc, .end);
    try std.testing.expectEqual(hub.ScopeKind.web_search, state.scope.kind);
    _ = try state.handle(alloc, .right);
    try std.testing.expectEqualDeep(hub.Effect{ .toggle_web_search = 0 }, try state.handle(alloc, .{ .char = ' ' }));
    try std.testing.expectEqual(hub.Effect.none, try state.handle(alloc, .{ .char = '[' }));
    try std.testing.expectEqualDeep(hub.Effect{ .move_web_search = .{ .index = 0, .later = true } }, try state.handle(alloc, .{ .char = ']' }));
    try std.testing.expectEqual(@as(usize, 1), state.selected);
}

test "a fresher snapshot keeps the scope and the highlighted model" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try openHub(&state, .models);
    _ = try state.handle(alloc, .down);
    const id = state.snapshot.?.models[state.selectedModel().?].id;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..id.len], id);
    try state.replaceSnapshot(alloc, try fixture());
    try std.testing.expectEqualStrings(buf[0..id.len], state.snapshot.?.models[state.selectedModel().?].id);
}

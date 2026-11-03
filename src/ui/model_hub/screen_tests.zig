const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const screen = @import("screen.zig");

const alloc = std.testing.allocator;
const catalog = hub.catalog;

fn fixture() !catalog.Snapshot {
    return fixtureWith(&.{});
}

fn fixtureWith(small_chain: []const catalog.EntryRow) !catalog.Snapshot {
    var builder: catalog.Builder = .init(alloc);
    errdefer builder.deinit();
    const cento = try builder.addProvider(.{ .key = "cento", .name = "cento", .detail = "No sign-in needed", .signed_in = true, .active = true, .sign_in = .settings, .can_sign_out = false });
    const zen = try builder.addProvider(.{ .key = "opencode-zen", .name = "OpenCode Zen", .detail = "Saved key", .signed_in = true, .active = false, .sign_in = .login, .can_sign_out = true });
    const go = try builder.addProvider(.{ .key = "opencode-go", .name = "OpenCode Go", .detail = "Not signed in", .signed_in = false, .active = false, .sign_in = .login, .can_sign_out = false });
    const efforts = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("high") };
    try builder.addModel(.{ .provider = cento, .id = "claude-cento", .name = "", .current = true, .context_window = 1_048_576, .efforts = &efforts, .roles = &.{ .{ .builtin = .default }, .{ .builtin = .small } } });
    try builder.addModel(.{ .provider = cento, .id = "claude-cento-lite", .name = "", .context_window = 200_000 });
    try builder.addModel(.{ .provider = zen, .id = "claude-sonnet-5-5", .name = "Claude Sonnet 5.5 with a very long catalog name that must clip" });
    try builder.addModel(.{ .provider = go, .id = "glm-5.3", .name = "" });
    for (catalog.role_order) |role| try builder.addRole(.{
        .role = .{ .builtin = role },
        .assigned = if (role == .small) "cento · claude-cento" else null,
        .entries = if (role == .small) small_chain else &.{},
        .in_use = if (role == .small and small_chain.len > 1) 1 else null,
        .resolved = "cento · claude-cento",
        .chain = "the session's model",
        .cycle_position = if (role == .default) 1 else null,
    });
    try builder.addWebSearch(.{ .id = "exa", .name = "Exa", .excluded = true, .ready = false });
    try builder.addWebSearch(.{ .id = "duckduckgo", .name = "DuckDuckGo", .excluded = false, .ready = true });
    try builder.addWebSearch(.{ .id = "codex", .name = "Codex", .excluded = false, .ready = false, .needs = "needs sign-in" });
    return builder.finish(&.{ .{ .builtin = .deep }, .{ .builtin = .default }, .{ .builtin = .small } });
}

/// Each painted row's text with styles removed, checked against `cols`.
fn rowsOf(bytes: []const u8, rows: u16, cols: u16, out: [][]u8) !void {
    for (0..rows) |row| {
        var marker_buf: [16]u8 = undefined;
        const marker = try std.mem.print(&marker_buf, "\x1b[{d};1H", .{row + 1});
        const begin = (std.mem.find(u8, bytes, marker) orelse return error.MissingRow) + marker.len;
        var next_buf: [16]u8 = undefined;
        const next = try std.mem.print(&next_buf, "\x1b[{d};1H", .{row + 2});
        const end = std.mem.findPos(u8, bytes, begin, next) orelse bytes.len;
        const segment = bytes[begin..end];
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(segment) <= cols);
        var plain: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < segment.len) {
            if (segment[index] == 0x1b) {
                index = display_width.ansiSequenceEnd(segment, index);
                continue;
            }
            try plain.append(alloc, segment[index]);
            index += 1;
        }
        out[row] = try plain.toOwnedSlice(alloc);
    }
}

fn joined(rows: []const []u8) ![]u8 {
    return std.mem.join(alloc, "\n", rows);
}

fn render(state: *hub.State, rows: u16, cols: u16) ![]u8 {
    var painted = try screen.paint(alloc, state, rows, cols, true);
    defer painted.deinit(alloc);
    const lines = try alloc.alloc([]u8, rows);
    defer {
        for (lines) |line| alloc.free(line);
        alloc.free(lines);
    }
    try rowsOf(painted.bytes, rows, cols, lines);
    return joined(lines);
}

test "the hub shows the sidebar beside every signed-in model at 120 columns" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try state.open(alloc, try fixture(), .models);
    const text = try render(&state, 30, 120);
    defer alloc.free(text);
    for ([_][]const u8{ "Models", "Roles", "All models", "cento", "OpenCode Zen", "OpenCode Go", "Web search", "claude-cento-lite", "Default Small", "1M", "type to search", "ctrl+r role" }) |needle| {
        if (std.mem.find(u8, text, needle) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ needle, text });
            return error.TestExpectedEqual;
        }
    }
    // A provider's settings key is never shown; the locked provider's model is not listed.
    try std.testing.expect(std.mem.find(u8, text, "opencode-zen") == null);
    try std.testing.expect(std.mem.find(u8, text, "glm-5.3") == null);
}

test "below 64 columns the panes take turns and nothing overflows" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try state.open(alloc, try fixture(), .providers);
    const sidebar = try render(&state, 20, 60);
    defer alloc.free(sidebar);
    try std.testing.expect(std.mem.find(u8, sidebar, "Web search") != null);
    try std.testing.expect(std.mem.find(u8, sidebar, "claude-cento-lite") == null);
    _ = try state.handle(alloc, .right);
    const list = try render(&state, 20, 60);
    defer alloc.free(list);
    try std.testing.expect(std.mem.find(u8, list, "‹ cento") != null);
    try std.testing.expect(std.mem.find(u8, list, "claude-cento-lite") != null);
    // Tiny terminals get a one-line explanation instead of a broken frame.
    const tiny = try render(&state, 4, 30);
    defer alloc.free(tiny);
    try std.testing.expect(std.mem.find(u8, tiny, "too small") != null);
}

test "the roles, web search and locked views and the strips render" {
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try state.open(alloc, try fixture(), .models);
    _ = try state.handle(alloc, .role_strip);
    const strip = try render(&state, 24, 120);
    defer alloc.free(strip);
    try std.testing.expect(std.mem.find(u8, strip, "[Default ✓]") != null);
    _ = try state.handle(alloc, .escape);
    _ = try state.handle(alloc, .left);
    _ = try state.handle(alloc, .home);
    const roles = try render(&state, 24, 120);
    defer alloc.free(roles);
    try std.testing.expect(std.mem.find(u8, roles, "Alt+P cycles Deep → Default → Small") != null);
    try std.testing.expect(std.mem.find(u8, roles, "auto → cento · claude-cento") != null);
    try std.testing.expect(std.mem.find(u8, roles, "↻ 1") != null);
    _ = try state.handle(alloc, .end);
    const web = try render(&state, 24, 120);
    defer alloc.free(web);
    try std.testing.expect(std.mem.find(u8, web, "Exa") != null);
    try std.testing.expect(std.mem.find(u8, web, "off") != null);
    try std.testing.expect(std.mem.find(u8, web, "ready") != null);
    // Codex searches through a sign-in, never a key.
    try std.testing.expect(std.mem.find(u8, web, "needs sign-in") != null);
    try std.testing.expect(std.mem.find(u8, web, "needs a key") == null);
    _ = try state.handle(alloc, .up);
    const locked = try render(&state, 24, 120);
    defer alloc.free(locked);
    try std.testing.expect(std.mem.find(u8, locked, "Enter signs in") != null);
    try std.testing.expect(std.mem.find(u8, locked, "glm-5.3") != null);
}

test "a role's chain shows its fallbacks, the one in use and levels, at any width" {
    const efforts = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("high") };
    const chain = [_]catalog.EntryRow{
        .{ .ref = "codex/gpt-5.6-luna", .shown = "Codex · gpt-5.6-luna", .state = .signed_out, .effort = types.ReasoningEffort.literal("low") },
        .{ .ref = "cento/claude-cento-lite", .shown = "cento · claude-cento-lite", .efforts = &efforts, .effort = types.ReasoningEffort.literal("high") },
    };
    var state: hub.State = .{};
    defer state.deinit(alloc);
    try state.open(alloc, try fixtureWith(&chain), .models);
    _ = try state.handle(alloc, .left);
    _ = try state.handle(alloc, .home);
    _ = try state.handle(alloc, .right);
    const wide = try render(&state, 24, 120);
    defer alloc.free(wide);
    for ([_][]const u8{ "Codex · gpt-5.6-luna · low · not signed in", "then 1", "cento · claude-cento-lite · high · in use", "f add fallback" }) |needle| {
        if (std.mem.find(u8, wide, needle) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ needle, wide });
            return error.TestExpectedEqual;
        }
    }
    _ = try state.handle(alloc, .down);
    _ = try state.handle(alloc, .down);
    _ = try state.handle(alloc, .{ .char = 't' });
    const strip = try render(&state, 24, 120);
    defer alloc.free(strip);
    try std.testing.expect(std.mem.find(u8, strip, "Thinking with cento · claude-cento-lite") != null);
    try std.testing.expect(std.mem.find(u8, strip, "[high ✓]") != null);
    // Narrow terminals clip rows instead of overflowing; rowsOf checks every width.
    for ([_]u16{ 40, 52, 70 }) |cols| {
        const narrow = try render(&state, 16, cols);
        alloc.free(narrow);
    }
}

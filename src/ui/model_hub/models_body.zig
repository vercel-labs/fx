//! Model rows for All models and each signed-in provider: the name, a dot
//! on the session's model, role badges, and the context window at the right.

const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const display_width = @import("../../core/shared/display_width.zig");
const ui_render = @import("../render.zig");
const Line = @import("line.zig").Line;

const catalog = hub.catalog;

pub fn status(line: *Line, state: *const hub.State) !void {
    const snapshot = &state.snapshot.?;
    if (state.assigning) |assigning| {
        const entry = assigning.entry orelse {
            try line.put(ui_render.warning_style, "Adding a fallback to ");
            try line.put(ui_render.bold_style, catalog.roleName(assigning.role));
            try line.put(ui_render.dim_style, " · enter adds the highlighted model, esc cancels");
            return;
        };
        try line.put(ui_render.warning_style, if (entry == 0) "Assigning " else "Replacing a fallback of ");
        try line.put(ui_render.bold_style, catalog.roleName(assigning.role));
        try line.put(ui_render.dim_style, " · enter picks the highlighted model, esc cancels");
        return;
    }
    if (state.scope.kind == .provider) {
        const provider = snapshot.providers[state.scope.provider];
        try line.putUntrusted(ui_render.dim_style, provider.name, 32);
        try line.put(ui_render.dim_style, " · ");
        try line.putUntrusted(ui_render.dim_style, provider.detail, 40);
        if (provider.active) try line.put(ui_render.dim_style, " · in use");
        return;
    }
    var signed_in: usize = 0;
    for (snapshot.providers) |provider| signed_in += @intFromBool(provider.signed_in);
    var buf: [96]u8 = undefined;
    const text = std.mem.print(&buf, "Every signed-in model · {d} provider{s}", .{ signed_in, if (signed_in == 1) "" else "s" }) catch "";
    try line.put(ui_render.dim_style, text);
    if (snapshot.loading) try line.put(ui_render.dim_style, " · loading the catalog…");
}

pub fn row(line: *Line, state: *const hub.State, index: usize, highlighted: bool) !void {
    const snapshot = &state.snapshot.?;
    const model = snapshot.models[index];
    const focused = highlighted and state.focus == .list;
    try line.put(ui_render.hint_style, if (focused) " › " else "   ");

    // The right edge: context window.
    var context_buf: [16]u8 = undefined;
    const context = if (model.context_window) |tokens| formatTokens(&context_buf, tokens) else "";
    const right_width = if (context.len > 0 and line.width >= 40) context.len + 2 else 0;

    var badge_width: usize = 0;
    for (model.roles) |role| badge_width += catalog.roleName(role).len + 1;
    const show_provider = state.scope.kind == .all_models and line.width >= 48;
    const provider_name = snapshot.providerName(model.provider);
    const provider_width = if (show_provider) @min(display_width.visibleWidth(provider_name), 16) + 3 else 0;
    const name_budget = line.remaining() -| (right_width + provider_width + (if (model.current) @as(usize, 2) else 0));
    const show_badges = badge_width > 0 and name_budget >= display_width.visibleWidth(model.name) + badge_width + 2;

    if (show_provider) {
        try line.putUntrusted(ui_render.dim_style, provider_name, 16);
        try line.put(ui_render.dim_style, " · ");
    }
    const name_style = if (highlighted) ui_render.selected_completion_style else "";
    try line.putUntrusted(name_style, model.name, if (show_badges) name_budget - badge_width else name_budget);
    if (model.current) try line.put(ui_render.green_style, " ●");
    if (show_badges) for (model.roles) |role| {
        try line.spaces(1);
        try line.put(ui_render.tag_style, catalog.roleName(role));
    };
    if (right_width > 0) _ = try line.putRight(ui_render.dim_style, context, 2);
}

pub fn detail(line: *Line, state: *const hub.State, index: usize) !void {
    const snapshot = &state.snapshot.?;
    const model = snapshot.models[index];
    try line.putUntrusted(ui_render.dim_style, snapshot.providerName(model.provider), 24);
    if (model.context_window) |tokens| {
        var buf: [16]u8 = undefined;
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.dim_style, formatTokens(&buf, tokens));
        try line.put(ui_render.dim_style, " context");
    }
    if (model.efforts.len > 0) {
        try line.put(ui_render.dim_style, " · thinking");
        for (model.efforts) |effort| {
            try line.put(ui_render.dim_style, " ");
            try line.put(ui_render.dim_style, effort.displayLabel());
        }
    }
    if (model.current) try line.put(ui_render.green_style, " · in use");
    for (model.roles) |role| {
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.tag_style, catalog.roleName(role));
    }
}

fn formatTokens(buf: *[16]u8, tokens: u32) []const u8 {
    if (tokens >= 1_000_000) {
        const whole = tokens / 1_000_000;
        const tenth = (tokens % 1_000_000) / 100_000;
        return (if (tenth == 0) std.mem.print(buf, "{d}M", .{whole}) else std.mem.print(buf, "{d}.{d}M", .{ whole, tenth })) catch "";
    }
    if (tokens >= 1_000) return std.mem.print(buf, "{d}K", .{tokens / 1_000}) catch "";
    return std.mem.print(buf, "{d}", .{tokens}) catch "";
}

test "token counts read as K and M" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1M", formatTokens(&buf, 1_048_576));
    try std.testing.expectEqualStrings("200K", formatTokens(&buf, 200_000));
    try std.testing.expectEqualStrings("1.5M", formatTokens(&buf, 1_500_000));
}

//! Model rows for All models and each signed-in provider.  The browser keeps
//! the compact row useful while its detail lines expose the catalog facts
//! Proto uses for deciding between models.

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
            try line.put(ui_render.bold_style, roleLabel(snapshot, assigning.role));
            try line.put(ui_render.dim_style, " · enter adds the highlighted model, esc cancels");
            return;
        };
        try line.put(ui_render.warning_style, if (entry == 0) "Assigning " else "Replacing a fallback of ");
        try line.put(ui_render.bold_style, roleLabel(snapshot, assigning.role));
        try line.put(ui_render.dim_style, " · enter picks the highlighted model, esc cancels");
        return;
    }
    if (state.scope.kind == .provider) {
        const provider = snapshot.providers[state.scope.provider];
        try line.putUntrusted(ui_render.dim_style, provider.name, 32);
        try line.put(ui_render.dim_style, " · ");
        try line.putUntrusted(ui_render.dim_style, provider.detail, 40);
        if (provider.active) try line.put(ui_render.dim_style, " · in use");
        if (provider.refreshing) try line.put(ui_render.warning_style, " · refreshing…");
        if (provider.failure_category) |failure| {
            try line.put(ui_render.red_style, " · refresh failed: ");
            try line.putUntrusted(ui_render.red_style, failure, line.remaining());
        }
        if (provider.failure_status) |http_status| {
            var status_buf: [24]u8 = undefined;
            try line.put(ui_render.red_style, std.mem.print(&status_buf, " ({d})", .{http_status}) catch "");
        }
        if (provider.credential_source) |source| {
            try line.put(ui_render.dim_style, " · credentials: ");
            try line.putUntrusted(ui_render.dim_style, source, line.remaining());
        }
        if (provider.last_success_age_ms orelse provider.last_attempt_age_ms) |age| {
            var age_buf: [32]u8 = undefined;
            const age_text = if (age < 1_000)
                "just now"
            else if (age < 60_000)
                std.mem.print(&age_buf, "{d}s ago", .{@divTrunc(age, 1_000)}) catch ""
            else
                std.mem.print(&age_buf, "{d}m ago", .{@divTrunc(age, 60_000)}) catch "";
            try line.put(ui_render.dim_style, " · catalog ");
            try line.putUntrusted(ui_render.dim_style, age_text, line.remaining());
        }
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

    var context_buf: [24]u8 = undefined;
    var cost_buf: [48]u8 = undefined;
    const context = if (model.context_window) |tokens| formatTokens(&context_buf, tokens) else "";
    const cost = if (model.cost) |value| formatCost(&cost_buf, value) else "";
    const over_context = snapshot.current_context_tokens != null and model.context_window != null and
        snapshot.current_context_tokens.? > model.context_window.?;
    const context_text = if (over_context and context.len > 0) "!" else context;
    const right = if (context_text.len > 0 and cost.len > 0)
        std.mem.print(&cost_buf, "{s}  {s}", .{ context_text, cost }) catch context_text
    else if (context_text.len > 0) context_text else cost;
    const right_width = if (right.len > 0 and line.width >= 40) right.len + 2 else 0;

    var badge_width: usize = 0;
    for (model.roles) |role| badge_width += roleLabel(snapshot, role).len + 1;
    const show_provider = state.scope.kind == .all_models and line.width >= 48;
    const provider_name = snapshot.providerName(model.provider);
    const provider_width = if (show_provider) @min(display_width.visibleWidth(provider_name), 16) + 3 else 0;
    const current_width: usize = if (model.current) 2 else 0;
    const name_budget = line.remaining() -| (right_width + provider_width + current_width);
    const show_badges = badge_width > 0 and name_budget >= display_width.visibleWidth(model.name) + badge_width + 2;

    if (show_provider) {
        try line.putUntrusted(ui_render.dim_style, provider_name, 16);
        try line.put(ui_render.dim_style, " · ");
    }
    const name_style = if (highlighted) ui_render.selected_completion_style else if (over_context) ui_render.dim_style else "";
    try line.putUntrusted(name_style, model.name, if (show_badges) name_budget - badge_width else name_budget);
    if (model.current) try line.put(ui_render.green_style, " ●");
    if (over_context) try line.put(ui_render.warning_style, " !");
    if (show_badges) for (model.roles) |role| {
        try line.spaces(1);
        try line.put(ui_render.tag_style, roleLabel(snapshot, role));
    };
    if (right_width > 0) _ = try line.putRight(ui_render.dim_style, right, 2);
}

pub fn detail(line: *Line, state: *const hub.State, index: usize) !void {
    const snapshot = &state.snapshot.?;
    const model = snapshot.models[index];
    var buf: [256]u8 = undefined;
    var cost_buf: [48]u8 = undefined;
    try line.putUntrusted(ui_render.dim_style, snapshot.providerName(model.provider), 24);
    try line.put(ui_render.dim_style, " · ");
    try line.putUntrusted(ui_render.dim_style, model.id, line.remaining());
    if (model.context_window) |tokens| {
        var context_buf: [24]u8 = undefined;
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.dim_style, formatTokens(&context_buf, tokens));
        try line.put(ui_render.dim_style, " ctx");
    }
    if (model.max_tokens) |tokens| {
        var output_buf: [24]u8 = undefined;
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.dim_style, formatTokens(&output_buf, tokens));
        try line.put(ui_render.dim_style, " out");
    }
    if (model.cost) |cost| {
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.dim_style, formatCost(&cost_buf, cost));
        try line.put(ui_render.dim_style, "/M");
    }
    if (model.has_reasoning or model.efforts.len > 0) try line.put(ui_render.dim_style, " · reasoning");
    if (model.has_vision) try line.put(ui_render.dim_style, " · vision");
    if (model.intelligence) |score| {
        const score_text = std.mem.print(&buf, " · IQ {d}", .{@as(i64, @intFromFloat(score))}) catch "";
        try line.put(ui_render.dim_style, score_text);
    }
    if (model.is_new) try line.put(ui_render.green_style, " · new");
    if (model.is_beta) try line.put(ui_render.warning_style, " · beta");
    if (model.is_recommended) try line.put(ui_render.selected_completion_style, " · recommended");
    if (model.ttft_ms) |ttft| {
        const ttft_text = std.mem.print(&buf, " · ttft {d}ms", .{ttft}) catch "";
        try line.put(ui_render.dim_style, ttft_text);
    }
    if (model.tokens_per_second) |tps| {
        const tps_text = std.mem.print(&buf, " · {d:.1} tok/s", .{tps}) catch "";
        try line.put(ui_render.dim_style, tps_text);
    }
    if (model.released > 0) {
        const released = std.mem.print(&buf, " · released {d}", .{model.released}) catch "";
        try line.put(ui_render.dim_style, released);
    }
    if (model.current) try line.put(ui_render.green_style, " · in use");
    for (model.roles) |role| {
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.tag_style, roleLabel(snapshot, role));
    }
    if (model.description.len > 0) {
        try line.put(ui_render.dim_style, " · ");
        try line.putUntrusted(ui_render.dim_style, model.description, line.remaining());
    }
}

fn roleLabel(snapshot: *const catalog.Snapshot, role: catalog.RoleId) []const u8 {
    for (snapshot.roles) |role_row| {
        if (role_row.role.eql(role)) return if (role_row.label.len > 0) role_row.label else catalog.roleNameId(role);
    }
    return catalog.roleNameId(role);
}

fn formatTokens(buf: *[24]u8, tokens: u32) []const u8 {
    if (tokens >= 1_000_000) {
        const whole = tokens / 1_000_000;
        const tenth = (tokens % 1_000_000) / 100_000;
        return (if (tenth == 0) std.mem.print(buf, "{d}M", .{whole}) else std.mem.print(buf, "{d}.{d}M", .{ whole, tenth })) catch "";
    }
    if (tokens >= 1_000) return std.mem.print(buf, "{d}K", .{tokens / 1_000}) catch "";
    return std.mem.print(buf, "{d}", .{tokens}) catch "";
}

fn formatCost(buf: *[48]u8, cost: catalog.ModelCost) []const u8 {
    if (cost.isFree()) return "free";
    const fmt = struct {
        fn part(value: f64, out: []u8) []const u8 {
            if (!std.math.isFinite(value) or value < 0) return "?";
            if (value > 0 and value < 0.01) return std.fmt.bufPrint(out, "{d:.6}", .{value}) catch "?";
            if (value >= 100) return std.fmt.bufPrint(out, "{d:.0}", .{value}) catch "?";
            if (value >= 10) return std.fmt.bufPrint(out, "{d:.1}", .{value}) catch "?";
            return std.fmt.bufPrint(out, "{d:.2}", .{value}) catch "?";
        }
    };
    var input_buf: [20]u8 = undefined;
    var output_buf: [20]u8 = undefined;
    return std.mem.print(buf, "${s}/${s}", .{ fmt.part(cost.input, &input_buf), fmt.part(cost.output, &output_buf) }) catch "?";
}

test "token counts read as K and M" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1M", formatTokens(&buf, 1_048_576));
    try std.testing.expectEqualStrings("200K", formatTokens(&buf, 200_000));
    try std.testing.expectEqualStrings("1.5M", formatTokens(&buf, 1_500_000));
}

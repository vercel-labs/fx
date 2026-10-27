//! Role rows: each role's name, the model the profile assigns or what it
//! falls back to, and its place in the Alt+P cycle.

const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const ui_render = @import("../render.zig");
const Line = @import("line.zig").Line;

const catalog = hub.catalog;
const name_column = 12;

pub fn status(line: *Line, state: *const hub.State) !void {
    const snapshot = &state.snapshot.?;
    try line.put(ui_render.dim_style, "Alt+P cycles ");
    if (snapshot.cycle.len == 0) {
        try line.put(ui_render.dim_style, "nothing yet · c adds a role");
        return;
    }
    const highlighted = if (state.selected < state.rows.items.len) snapshot.roles[state.rows.items[state.selected]].role else null;
    for (snapshot.cycle, 0..) |role, index| {
        if (index > 0) try line.put(ui_render.dim_style, " → ");
        const style = if (highlighted != null and highlighted.? == role) ui_render.selected_completion_style else ui_render.tag_style;
        try line.put(style, catalog.roleName(role));
    }
}

pub fn row(line: *Line, state: *const hub.State, index: usize, highlighted: bool) !void {
    const role_row = state.snapshot.?.roles[index];
    const focused = highlighted and state.focus == .list;
    try line.put(ui_render.hint_style, if (focused) " › " else "   ");
    if (role_row.assigned != null) try line.put(ui_render.green_style, "▪ ") else try line.put(ui_render.dim_style, "▫ ");
    try line.put(if (highlighted) ui_render.selected_completion_style else "", catalog.roleName(role_row.role));
    try line.padTo(name_column + 5);

    var cycle_buf: [8]u8 = undefined;
    const cycle = if (role_row.cycle_position) |position| std.mem.print(&cycle_buf, "↻ {d}", .{position}) catch "" else "";
    const budget = line.remaining() -| (if (cycle.len > 0) cycle.len + 2 else 0);
    if (role_row.assigned) |assigned| {
        try line.putUntrusted("", assigned, budget);
    } else if (role_row.resolved) |resolved| {
        try line.put(ui_render.dim_style, "auto → ");
        try line.putUntrusted(ui_render.dim_style, resolved, budget -| 7);
    } else {
        try line.put(ui_render.dim_style, "— ");
        try line.put(ui_render.dim_style, role_row.chain);
    }
    if (cycle.len > 0) _ = try line.putRight(ui_render.tag_style, cycle, 2);
}

pub fn detail(line: *Line, state: *const hub.State, index: usize) !void {
    const role_row = state.snapshot.?.roles[index];
    try line.put(ui_render.dim_style, "For ");
    try line.put(ui_render.dim_style, role_row.role.summary());
    if (role_row.assigned != null) return;
    try line.put(ui_render.dim_style, " · unset, it uses ");
    try line.put(ui_render.dim_style, role_row.chain);
}

//! Role rows: each role's name, the model the profile assigns or what it
//! falls back to, and its place in the Alt+P cycle. A role with a chain
//! lists its fallbacks under it, marking the one in use and why the others
//! are passed over (D250), with any thinking level a model carries (D251).

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
    const highlighted = if (state.roleCursor()) |cursor| snapshot.roles[cursor.role_index].role else null;
    var shown: usize = 0;
    for (snapshot.cycle) |role| {
        const hidden = if (snapshot.roleRow(role)) |role_row| role_row.hidden else false;
        if (hidden) continue;
        if (shown > 0) try line.put(ui_render.dim_style, " → ");
        const style = if (highlighted != null and highlighted.?.eql(role)) ui_render.selected_completion_style else ui_render.tag_style;
        try line.put(style, catalog.roleNameId(role));
        shown += 1;
    }
}

pub fn row(line: *Line, state: *const hub.State, id: usize, highlighted: bool) !void {
    const cursor = hub.RoleCursor.decode(id);
    const role_row = state.snapshot.?.roles[cursor.role_index];
    const focused = highlighted and state.focus == .list;
    try line.put(ui_render.hint_style, if (focused) " › " else "   ");
    if (cursor.entry > 0) return fallbackRow(line, role_row, cursor.entry, highlighted);

    if (role_row.assigned != null) try line.put(ui_render.green_style, "▪ ") else try line.put(ui_render.dim_style, "▫ ");
    const role_label = if (role_row.label.len > 0) role_row.label else catalog.roleNameId(role_row.role);
    try line.put(if (highlighted) ui_render.selected_completion_style else "", role_label);
    try line.padTo(name_column + 5);

    var cycle_buf: [8]u8 = undefined;
    const cycle = if (role_row.cycle_position) |position| std.mem.print(&cycle_buf, "↻ {d}", .{position}) catch "" else "";
    const budget = line.remaining() -| (if (cycle.len > 0) cycle.len + 2 else 0);
    if (role_row.entries.len > 0) {
        try entryText(line, role_row, 0, budget);
    } else if (role_row.assigned) |assigned| {
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

fn fallbackRow(line: *Line, role_row: catalog.RoleRow, entry: usize, highlighted: bool) !void {
    try line.spaces(2);
    var number_buf: [8]u8 = undefined;
    const number = std.mem.print(&number_buf, "then {d}", .{entry}) catch "then";
    try line.put(if (highlighted) ui_render.selected_completion_style else ui_render.dim_style, number);
    try line.padTo(name_column + 5);
    try entryText(line, role_row, entry, line.remaining());
}

/// The model, its level, and a word on its state: in use, or why not.
fn entryText(line: *Line, role_row: catalog.RoleRow, index: usize, budget: usize) !void {
    const entry = role_row.entries[index];
    const in_use = role_row.in_use != null and role_row.in_use.? == index;
    const chained = role_row.entries.len > 1;
    const note: []const u8 = switch (entry.state) {
        .ready => if (in_use and chained) "in use" else "",
        .alias => if (in_use and chained) "in use" else "",
        .unknown_model => if (in_use) "in use · not in the catalog" else "not in the catalog",
        .other_provider => "another provider",
        .signed_out => "not signed in",
    };
    const level = if (entry.effort) |effort| effort.label() else "";
    const reserve = (if (level.len > 0) level.len + 3 else 0) + (if (note.len > 0) note.len + 3 else 0);
    const usable_now = entry.state == .ready or entry.state == .alias or in_use;
    try line.putUntrusted(if (usable_now) "" else ui_render.dim_style, entry.shown, budget -| reserve);
    if (level.len > 0) {
        try line.put(ui_render.dim_style, " · ");
        try line.put(ui_render.tag_style, level);
    }
    if (note.len > 0) {
        try line.put(ui_render.dim_style, " · ");
        try line.put(if (in_use) ui_render.green_style else ui_render.dim_style, note);
    }
}

pub fn detail(line: *Line, state: *const hub.State, id: usize) !void {
    const cursor = hub.RoleCursor.decode(id);
    const role_row = state.snapshot.?.roles[cursor.role_index];
    if (cursor.entry > 0) {
        try line.put(ui_render.dim_style, "Used when the models above it are not available");
        return;
    }
    try line.put(ui_render.dim_style, "For ");
    try line.put(ui_render.dim_style, if (role_row.summary.len > 0) role_row.summary else catalog.roleNameId(role_row.role));
    if (role_row.assigned != null) {
        try line.put(ui_render.dim_style, if (role_row.entries.len > 1) " · the first available model is used" else " · f adds a fallback");
        return;
    }
    try line.put(ui_render.dim_style, " · unset, it uses ");
    try line.put(ui_render.dim_style, role_row.chain);
}

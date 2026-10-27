//! The model hub's frame: title, rules, the sidebar of scopes, and the hint
//! row with its chip strips.

const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const types = @import("../../core/shared/types.zig");
const display_width = @import("../../core/shared/display_width.zig");
const ui_render = @import("../render.zig");
const Line = @import("line.zig").Line;

const Allocator = std.mem.Allocator;
const catalog = hub.catalog;

pub fn scopeLabel(state: *const hub.State, scope: hub.Scope) []const u8 {
    return switch (scope.kind) {
        .roles => "Roles",
        .all_models => "All models",
        .provider => state.snapshot.?.providerName(scope.provider),
        .web_search => "Web search",
    };
}

fn annotation(state: *const hub.State, scope: hub.Scope, buf: []u8) []const u8 {
    const snapshot = &state.snapshot.?;
    return switch (scope.kind) {
        .roles => blk: {
            var assigned: usize = 0;
            for (snapshot.roles) |row| assigned += @intFromBool(row.assigned != null);
            break :blk std.mem.print(buf, "{d}/{d}", .{ assigned, snapshot.roles.len }) catch "";
        },
        .all_models => blk: {
            var count: usize = 0;
            for (snapshot.models) |model| count += @intFromBool(snapshot.providers[model.provider].signed_in);
            break :blk std.mem.print(buf, "{d}", .{count}) catch "";
        },
        .provider => blk: {
            const provider = snapshot.providers[scope.provider];
            if (!provider.signed_in or !provider.models_known) break :blk "";
            break :blk std.mem.print(buf, "{d}", .{provider.model_count}) catch "";
        },
        .web_search => blk: {
            var on: usize = 0;
            for (snapshot.web_search) |row| on += @intFromBool(!row.excluded);
            break :blk std.mem.print(buf, "{d} on", .{on}) catch "";
        },
    };
}

pub fn sidebarWidth(state: *const hub.State) u16 {
    var buf: [64]hub.Scope = undefined;
    var widest: usize = 0;
    for (state.scopes(&buf)) |scope| {
        var annotation_buf: [32]u8 = undefined;
        const text = annotation(state, scope, &annotation_buf);
        const dot: usize = if (scope.kind == .provider and state.snapshot.?.providers[scope.provider].active) 2 else 0;
        widest = @max(widest, display_width.visibleWidth(scopeLabel(state, scope)) + display_width.visibleWidth(text) + dot + 6);
    }
    return @intCast(std.math.clamp(widest, 18, 26));
}

pub fn rule(line: *Line, cols: u16, junction: ?u16) !void {
    var col: u16 = 0;
    while (col < cols) : (col += 1) {
        try line.put(ui_render.divider_style, if (junction != null and junction.? == col) "┼" else "─");
    }
}

pub fn title(line: *Line, state: *const hub.State, compact: bool) !void {
    const snapshot = &state.snapshot.?;
    try line.spaces(1);
    if (compact and state.focus == .list) {
        try line.put(ui_render.dim_style, "‹ ");
        try line.putUntrusted(ui_render.bold_style, scopeLabel(state, state.scope), line.remaining());
    } else {
        try line.put(ui_render.bold_style, "Models");
    }
    const current = snapshot.currentModel() orelse return;
    const model = snapshot.models[current];
    var buf: [256]u8 = undefined;
    const effort = snapshot.effort orelse types.ReasoningEffort.auto;
    const summary = if (effort.isDefault())
        std.mem.print(&buf, "{s} · {s}", .{ model.name, snapshot.providerName(model.provider) }) catch return
    else
        std.mem.print(&buf, "{s} · {s} · thinking {s}", .{ model.name, snapshot.providerName(model.provider), effort.displayLabel() }) catch return;
    var encoded_line: Line = .init(line.alloc, line.remaining() -| 4);
    defer encoded_line.deinit();
    try encoded_line.putUntrusted("", summary, encoded_line.width);
    if (encoded_line.used + 4 > line.remaining()) return;
    try line.padTo(line.width - encoded_line.used - 1);
    try line.put(ui_render.dim_style, encoded_line.bytes.items);
}

/// The sidebar: Roles and All models, the providers signed in first, then
/// Web search, with a gap between the groups.
pub fn sidebar(alloc: Allocator, state: *const hub.State, width: u16, height: u16, out: *std.ArrayList(Line)) !void {
    var buf: [64]hub.Scope = undefined;
    const scopes = state.scopes(&buf);
    // Rows with gaps: null is a gap.
    var rows: [96]?usize = undefined;
    var count: usize = 0;
    var selected_row: usize = 0;
    for (scopes, 0..) |scope, index| {
        const gap_before = (scope.kind == .provider and index > 0 and scopes[index - 1].kind != .provider) or
            (scope.kind == .web_search and index > 0);
        if (gap_before and count < rows.len) {
            rows[count] = null;
            count += 1;
        }
        if (count >= rows.len) break;
        if (scope.kind == state.scope.kind and (scope.kind != .provider or scope.provider == state.scope.provider)) selected_row = count;
        rows[count] = index;
        count += 1;
    }
    const visible: usize = height;
    var start: usize = 0;
    if (count > visible) start = @min(selected_row -| (visible / 2), count - visible);
    for (rows[start..@min(count, start + visible)]) |entry| {
        var line: Line = .init(alloc, width);
        errdefer line.deinit();
        if (entry) |index| try sidebarEntry(&line, state, scopes[index]);
        try out.append(alloc, line);
    }
}

fn sidebarEntry(line: *Line, state: *const hub.State, scope: hub.Scope) !void {
    const selected = scope.kind == state.scope.kind and (scope.kind != .provider or scope.provider == state.scope.provider);
    try line.put(ui_render.hint_style, if (selected and state.focus == .scope) " › " else "   ");
    var label_style = if (selected) ui_render.selected_completion_style else "";
    switch (scope.kind) {
        .provider => {
            const provider = state.snapshot.?.providers[scope.provider];
            if (provider.signed_in) try line.put(ui_render.green_style, "▪ ") else {
                try line.put(ui_render.dim_style, "▫ ");
                if (!selected) label_style = ui_render.dim_style;
            }
        },
        else => {},
    }
    var annotation_buf: [32]u8 = undefined;
    const text = annotation(state, scope, &annotation_buf);
    const active = scope.kind == .provider and state.snapshot.?.providers[scope.provider].active;
    const label_budget = line.remaining() -| (display_width.visibleWidth(text) + 1 + @as(usize, if (active) 2 else 0));
    try line.putUntrusted(label_style, scopeLabel(state, scope), label_budget);
    if (active) {
        // The provider in use: a dot before its count.
        const visible = display_width.visibleWidth(text) + 2;
        if (line.remaining() < visible + 1) return;
        try line.padTo(line.width - visible);
        try line.put(ui_render.green_style, "● ");
        try line.put(ui_render.dim_style, text);
        return;
    }
    _ = try line.putRight(ui_render.dim_style, text, 1);
}

/// The hint row: what the keys do here, the open strip, or the hub's notice.
pub fn hints(line: *Line, state: *const hub.State, compact: bool) !void {
    try line.spaces(1);
    switch (state.strip) {
        .none => {},
        .roles => |selected| return roleStrip(line, state, selected),
        .thinking => |selected| return thinkingStrip(line, state, selected),
        .sign_out => |provider| {
            try line.put("", "Sign out of ");
            try line.putUntrusted(ui_render.bold_style, state.snapshot.?.providerName(provider), 32);
            try line.put("", "?  ");
            try line.put(ui_render.hint_style, "enter signs out · any other key keeps it");
            return;
        },
    }
    const text: []const u8 = if (state.focus == .scope) switch (state.scope.kind) {
        .provider => if (compact) "↑↓ · enter open · esc close" else "↑↓ scopes · enter open · → list · ⌫ sign out · type to search · esc close",
        else => if (compact) "↑↓ · enter open · esc close" else "↑↓ scopes · enter or → list · type to search · esc close",
    } else switch (state.scope.kind) {
        .roles => if (compact) "enter pick · x clear · c cycle · [ ] move" else "↑↓ roles · enter pick a model · x clear · c cycle · [ ] reorder · ← sidebar · esc close",
        .web_search => if (compact) "space on/off · [ ] move · ← back" else "↑↓ providers · space on or off · [ ] reorder · ← sidebar · esc close",
        .all_models, .provider => if (state.assigning != null)
            (if (compact) "enter assigns · esc cancels" else "↑↓ models · type to search · enter assigns · esc cancels")
        else if (!state.listsModels())
            (if (compact) "enter sign in · ← back" else "enter signs in · ← sidebar · esc close")
        else if (compact)
            "enter use · ^r role · ^t thinking · ← back"
        else
            "↑↓ models · enter use · ctrl+r role · ctrl+t thinking · type to search · ← sidebar · esc close",
    };
    try line.put(ui_render.hint_style, text);
}

fn roleStrip(line: *Line, state: *const hub.State, selected: usize) !void {
    const model_index = state.selectedModel() orelse return;
    const model = state.snapshot.?.models[model_index];
    try line.put(ui_render.hint_style, "Role for ");
    try line.putUntrusted(ui_render.bold_style, model.name, 28);
    try line.put(ui_render.hint_style, "  ");
    var labels: [catalog.role_order.len][]const u8 = undefined;
    var holds: [catalog.role_order.len]bool = undefined;
    for (catalog.role_order, 0..) |role, index| {
        labels[index] = catalog.roleName(role);
        holds[index] = std.mem.findScalar(hub.Role, model.roles, role) != null;
    }
    try chips(line, &labels, &holds, selected);
}

fn thinkingStrip(line: *Line, state: *const hub.State, selected: usize) !void {
    const model_index = state.selectedModel() orelse return;
    const model = state.snapshot.?.models[model_index];
    try line.put(ui_render.hint_style, "Thinking for ");
    try line.putUntrusted(ui_render.bold_style, model.name, 28);
    try line.put(ui_render.hint_style, "  ");
    var labels: [17][]const u8 = undefined;
    var holds: [17]bool = @splat(false);
    const count = @min(state.stripCount(), labels.len);
    for (0..count) |index| {
        const effort = state.stripEffort(index);
        labels[index] = if (index == 0) "auto" else model.efforts[index - 1].displayLabel();
        holds[index] = state.snapshot.?.effort != null and effort.eql(state.snapshot.?.effort.?) and model.current;
    }
    try chips(line, labels[0..count], holds[0..count], selected);
}

/// Chips with the selected one bracketed; a ✓ marks chips already in
/// effect. When they do not all fit, a window around the selected chip
/// shows, with … at a cut end; a narrow row shows only the selected chip.
fn chips(line: *Line, labels: []const []const u8, holds: []const bool, selected: usize) !void {
    var widths: [32]usize = undefined;
    const count = @min(labels.len, widths.len);
    for (0..count) |index| widths[index] = display_width.visibleWidth(labels[index]) + 3 + @as(usize, if (holds[index]) 2 else 0);
    const budget = line.remaining();
    var start = selected;
    var end = selected + 1;
    var used = widths[selected] + 4;
    if (used > budget) {
        try line.put(ui_render.hint_style, "← ");
        try chip(line, labels[selected], holds[selected], true);
        try line.put(ui_render.hint_style, " →");
        return;
    }
    while (true) {
        var grew = false;
        if (end < count and used + widths[end] <= budget) {
            used += widths[end];
            end += 1;
            grew = true;
        }
        if (start > 0 and used + widths[start - 1] <= budget) {
            start -= 1;
            used += widths[start];
            grew = true;
        }
        if (!grew) break;
    }
    if (start > 0) try line.put(ui_render.hint_style, "… ");
    for (start..end) |index| {
        try chip(line, labels[index], holds[index], index == selected);
        try line.spaces(1);
    }
    if (end < count) try line.put(ui_render.hint_style, "…");
}

fn chip(line: *Line, label: []const u8, held: bool, selected: bool) !void {
    const style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;
    try line.put(style, if (selected) "[" else " ");
    try line.put(style, label);
    if (held) try line.put(ui_render.green_style, " ✓");
    try line.put(style, if (selected) "]" else " ");
}

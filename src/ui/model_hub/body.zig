//! The model hub's right pane: a status line, the search field when the
//! list holds models, the list itself, and a detail line for the
//! highlighted row. Each scope's rows come from its own file.

const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const list_window = @import("../../core/shared/list_window.zig");
const ui_render = @import("../render.zig");
const Line = @import("line.zig").Line;
const models_body = @import("models_body.zig");
const roles_body = @import("roles_body.zig");
const providers_body = @import("providers_body.zig");

const Allocator = std.mem.Allocator;

pub const Placed = struct { window_start: usize = 0, visible_rows: usize = 0 };

pub fn compose(alloc: Allocator, state: *const hub.State, width: u16, height: u16, out: *std.ArrayList(Line)) !Placed {
    const roomy = height >= 8;
    var lines = Lines{ .alloc = alloc, .out = out, .width = width };

    // Status: the hub's last notice, else what this pane shows.
    var status = try lines.next();
    try status.spaces(1);
    if (state.notice().len > 0) {
        try status.put(ui_render.green_style, "✓ ");
        try status.putUntrusted("", state.notice(), status.remaining());
    } else switch (state.scope.kind) {
        .roles => try roles_body.status(status, state),
        .web_search => try providers_body.webStatus(status),
        .all_models, .provider => try models_body.status(status, state),
    }

    const searchable = state.listsModels();
    if (searchable or roomy) {
        var search = try lines.next();
        if (searchable) {
            try search.put(ui_render.hint_style, " ⌕ ");
            if (state.query().len == 0) {
                try search.put(ui_render.dim_style, "type to search");
            } else {
                try search.putUntrusted("", state.query(), search.remaining() -| 1);
                if (state.focus == .list) try search.put(ui_render.selected_completion_style, " ");
            }
        }
    }
    if (roomy) _ = try lines.next();

    const footer_rows: u16 = if (roomy) 2 else 0;
    const used: u16 = @intCast(out.items.len);
    const list_rows: u16 = height -| used -| footer_rows;

    if (!state.listsModels() and state.scope.kind == .provider) {
        try providers_body.lockedView(&lines, state, list_rows);
        try lines.fill(height);
        return .{};
    }

    const count = state.rows.items.len;
    const selected = @min(state.selected, count -| 1);
    const start = list_window.updateEdgeStart(state.window_start, count, selected, @max(list_rows, 1));
    var placed: Placed = .{ .window_start = start, .visible_rows = list_rows };
    if (count == 0) {
        var empty = try lines.next();
        try empty.spaces(3);
        try empty.put(ui_render.dim_style, switch (state.scope.kind) {
            .all_models, .provider => if (state.query().len > 0)
                "No models match."
            else if (state.snapshot.?.loading)
                "Loading models…"
            else
                "No models yet. Sign in to a provider in the sidebar.",
            .roles => "No roles.",
            .web_search => "No web search providers.",
        });
        placed.visible_rows = 0;
    }
    var row = start;
    while (row < count and row < start + list_rows) : (row += 1) {
        const line = try lines.next();
        const highlighted = row == selected or (state.hovered != null and state.hovered.? == row);
        switch (state.scope.kind) {
            .roles => try roles_body.row(line, state, state.rows.items[row], highlighted),
            .web_search => try providers_body.webRow(line, state, state.rows.items[row], highlighted, row),
            .all_models, .provider => try models_body.row(line, state, state.rows.items[row], highlighted),
        }
    }
    if (roomy) {
        try lines.fill(height - 1);
        const detail = try lines.next();
        try detail.spaces(1);
        if (count > 0) switch (state.scope.kind) {
            .roles => try roles_body.detail(detail, state, state.rows.items[selected]),
            .web_search => try providers_body.webDetail(detail, state, state.rows.items[selected]),
            .all_models, .provider => try models_body.detail(detail, state, state.rows.items[selected]),
        };
    }
    try lines.fill(height);
    return placed;
}

pub const Lines = struct {
    alloc: Allocator,
    out: *std.ArrayList(Line),
    width: u16,

    pub fn next(self: *Lines) !*Line {
        try self.out.append(self.alloc, .init(self.alloc, self.width));
        return &self.out.items[self.out.items.len - 1];
    }

    pub fn fill(self: *Lines, height: u16) !void {
        while (self.out.items.len < height) _ = try self.next();
    }
};

//! A provider that lists no models (signed out, or signed in but not yet in
//! use) and the web search bank's rows.

const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const ui_render = @import("../render.zig");
const Line = @import("line.zig").Line;
const Lines = @import("body.zig").Lines;

pub fn lockedView(lines: *Lines, state: *const hub.State, height: u16) !void {
    const snapshot = &state.snapshot.?;
    const provider = snapshot.providers[state.scope.provider];
    const start = lines.out.items.len;
    {
        const line = try lines.next();
        try line.spaces(3);
        if (provider.refreshing) {
            try line.put(ui_render.selected_completion_style, "⟳ refreshing model list…");
        } else if (provider.failure_category) |failure| {
            try line.put(ui_render.dim_style, "last refresh failed: ");
            try line.putUntrusted(ui_render.red_style, failure, line.remaining());
        } else if (provider.signed_in) {
            try line.put(ui_render.selected_completion_style, "› Enter switches the session to it to list its models");
        } else switch (provider.sign_in) {
            .login => try line.put(ui_render.selected_completion_style, "› Enter signs in"),
            .settings => try line.put(ui_render.dim_style, "Its endpoint and key come from settings."),
            .external => try line.put(ui_render.dim_style, "Sign in to it outside proto-fx."),
        }
    }
    if (provider.credential_source) |source| {
        const line = try lines.next();
        try line.spaces(3);
        try line.put(ui_render.dim_style, "credentials: ");
        try line.putUntrusted(ui_render.dim_style, source, line.remaining());
    }
    if (provider.last_success_age_ms) |age| {
        const line = try lines.next();
        try line.spaces(3);
        var age_buf: [64]u8 = undefined;
        const age_text = if (age < 1_000) "just now" else if (age < 60_000) std.mem.print(&age_buf, "{d}s ago", .{@divTrunc(age, 1_000)}) catch "" else std.mem.print(&age_buf, "{d}m ago", .{@divTrunc(age, 60_000)}) catch "";
        try line.put(ui_render.dim_style, "catalog: ");
        try line.putUntrusted(ui_render.dim_style, age_text, line.remaining());
    }
    if (provider.model_count == 0) return;
    _ = try lines.next();
    {
        const line = try lines.next();
        try line.spaces(3);
        var buf: [48]u8 = undefined;
        try line.put(ui_render.dim_style, std.mem.print(&buf, "{d} models once signed in:", .{provider.model_count}) catch "");
    }
    for (snapshot.models) |model| {
        if (model.provider != state.scope.provider) continue;
        if (lines.out.items.len - start >= height) break;
        const line = try lines.next();
        try line.spaces(5);
        try line.putUntrusted(ui_render.dim_style, model.name, line.remaining());
    }
}

pub fn webStatus(line: *Line) !void {
    try line.put(ui_render.dim_style, "Web search tries these in order and skips the ones turned off");
}

pub fn webRow(line: *Line, state: *const hub.State, index: usize, highlighted: bool, position: usize) !void {
    const row = state.snapshot.?.web_search[index];
    const focused = highlighted and state.focus == .list;
    try line.put(ui_render.hint_style, if (focused) " › " else "   ");
    var buf: [8]u8 = undefined;
    try line.put(ui_render.dim_style, std.mem.print(&buf, "{d:>2} ", .{position + 1}) catch "");
    if (row.excluded) {
        try line.put(ui_render.dim_style, "▫ ");
    } else if (row.ready) {
        try line.put(ui_render.green_style, "▪ ");
    } else {
        try line.put(ui_render.dim_style, "▪ ");
    }
    const style = if (highlighted) ui_render.selected_completion_style else if (row.excluded) ui_render.dim_style else "";
    const state_text: []const u8 = if (row.excluded) "off" else if (row.ready) "ready" else row.needs;
    try line.putUntrusted(style, row.name, line.remaining() -| (state_text.len + 2));
    _ = try line.putRight(if (row.ready and !row.excluded) ui_render.green_style else ui_render.dim_style, state_text, 2);
}

pub fn webDetail(line: *Line, state: *const hub.State, index: usize) !void {
    const row = state.snapshot.?.web_search[index];
    try line.putUntrusted(ui_render.dim_style, row.name, 32);
    try line.put(ui_render.dim_style, if (row.excluded) " is off; space turns it back on" else if (row.ready) " is ready to search" else row.needs_detail);
}

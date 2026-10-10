//! Behavior for the columnar `/web` picker.
//!
//! The picker walks left to right: search backend, then fetch backend. Each
//! list column writes its choice into the composer, so the next column anchors
//! under its own argument the way `/provider` does. Enter on fetch applies both
//! sides through the same `/web` command path that labeled and unlabeled
//! payloads already use.

const std = @import("std");
const picker_state = @import("../input/picker_state.zig");
const list_window = @import("../shared/list_window.zig");
const web_tools = @import("../tooling/web_tools.zig");
const session_commands = @import("../session/session_commands.zig");

const WebPickerStage = picker_state.WebPickerStage;
const max_options = web_tools.search_slugs.len;

pub const ColumnBuffer = struct {
    labels: [max_options][]const u8 = undefined,
    annotations: [max_options][]const u8 = undefined,
    count: usize = 0,
};

pub fn supported(comptime App: type) bool {
    return @hasField(App, "input_runtime") and
        @hasField(App, "web_search") and
        @hasField(App, "web_fetch");
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn columnOptions(
            app: *App,
            query: picker_state.WebPickerQuery,
            column: *ColumnBuffer,
        ) usize {
            column.count = 0;
            if (comptime !supported(App)) return 0;
            var count: usize = 0;
            switch (query.stage) {
                .search => {
                    for (web_tools.search_slugs, 0..) |slug, i| {
                        column.labels[i] = slug;
                        column.annotations[i] = if (std.mem.eql(u8, slug, app.web_search.slug()))
                            "current"
                        else
                            "";
                    }
                    count = web_tools.search_slugs.len;
                },
                .fetch => {
                    for (web_tools.fetch_slugs, 0..) |slug, i| {
                        column.labels[i] = slug;
                        column.annotations[i] = if (std.mem.eql(u8, slug, app.web_fetch.slug()))
                            "current"
                        else
                            "";
                    }
                    count = web_tools.fetch_slugs.len;
                },
            }
            column.count = picker_state.filterAnnotatedLabels(
                query.query,
                &column.labels,
                &column.annotations,
                count,
            );
            return column.count;
        }

        pub fn hasQuery(app: *App) bool {
            if (comptime !@hasField(App, "input_runtime")) return false;
            return app.input_runtime.picker.activeWebPickerQuery(&app.input_runtime.edit_state) != null;
        }

        pub fn open(app: *App) !void {
            if (comptime !supported(App)) return;
            try setComposerText(app, "{s}", .{picker_state.web_prefix});
            app.input_runtime.picker.clearWebPickerFlow();
            selectCurrentSearch(app);
            app.shell.render_requests.request(.footer);
        }

        pub fn navigate(app: *App, delta: i32) void {
            if (comptime !supported(App)) return;
            if (!hasQuery(app)) return;
            const query = app.input_runtime.picker.activeWebPickerQuery(&app.input_runtime.edit_state) orelse return;
            var column: ColumnBuffer = .{};
            const count = columnOptions(app, query, &column);
            const picker = &app.input_runtime.picker;
            switch (query.stage) {
                .search => list_window.advanceSelection(
                    &picker.web_search_column_index,
                    &picker.web_search_column_window_start,
                    count,
                    delta,
                ),
                .fetch => list_window.advanceSelection(
                    &picker.web_fetch_column_index,
                    &picker.web_fetch_column_window_start,
                    count,
                    delta,
                ),
            }
        }

        pub fn autocomplete(app: *App) !void {
            if (comptime !supported(App)) return;
            if (!hasQuery(app)) return;
            const query = app.input_runtime.picker.activeWebPickerQuery(&app.input_runtime.edit_state) orelse return;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = selectedLabel(app, query, &column) orelse return;

            const picker = &app.input_runtime.picker;
            const search_slug = try app.alloc.dupe(u8, picker.web_picker_pending_search.items);
            defer app.alloc.free(search_slug);

            switch (query.stage) {
                .search => try setComposerText(app, "{s}{s}", .{ picker_state.web_prefix, selected }),
                .fetch => {
                    try setComposerText(app, "{s}{s} {s}", .{ picker_state.web_prefix, search_slug, selected });
                    try picker.beginWebPickerFlow(app.alloc, search_slug, .fetch);
                },
            }
            app.shell.render_requests.request(.footer);
        }

        pub fn advanceOnSpace(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeWebPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (app.input_runtime.edit_state.cursor != app.input_runtime.edit_state.input.items.len) return false;
            if (std.mem.trim(u8, query.query, " \t").len == 0) return false;
            if (query.stage != .search) return false;

            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            _ = exactLabel(query.query, &column) orelse return false;
            return try submit(app);
        }

        pub fn submit(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeWebPickerQuery(&app.input_runtime.edit_state) orelse return false;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = selectedLabel(app, query, &column) orelse return false;

            switch (query.stage) {
                .search => {
                    const slug = try app.alloc.dupe(u8, selected);
                    defer app.alloc.free(slug);
                    try setComposerText(app, "{s}{s} ", .{ picker_state.web_prefix, slug });
                    try app.input_runtime.picker.beginWebPickerFlow(app.alloc, slug, .fetch);
                    selectCurrentFetch(app);
                    app.shell.render_requests.request(.footer);
                    return true;
                },
                .fetch => {
                    const search_slug = try app.alloc.dupe(u8, app.input_runtime.picker.web_picker_pending_search.items);
                    defer app.alloc.free(search_slug);
                    const rest = try std.fmt.allocPrint(app.alloc, "{s} {s}", .{ search_slug, selected });
                    defer app.alloc.free(rest);
                    app.input_runtime.picker.clearWebPickerFlow();
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                    if (comptime @hasDecl(App, "writeDomainNotice")) {
                        try session_commands.Commands(App).handleWeb(app, rest);
                    } else {
                        app.web_search = web_tools.parseSearch(search_slug) orelse return false;
                        app.web_fetch = web_tools.parseFetch(selected) orelse return false;
                    }
                    app.shell.render_requests.request(.footer);
                    return true;
                },
            }
        }

        pub fn stepBack(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeWebPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (query.stage == .search) return false;

            const search_slug = try app.alloc.dupe(u8, app.input_runtime.picker.web_picker_pending_search.items);
            defer app.alloc.free(search_slug);
            try setComposerText(app, "{s}", .{picker_state.web_prefix});
            app.input_runtime.picker.clearWebPickerFlow();
            syncSearchSelection(app, search_slug);
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn abandon(app: *App) void {
            if (comptime !supported(App)) return;
            if (app.input_runtime.picker.web_picker_stage == .search) return;
            app.input_runtime.picker.clearWebPickerFlow();
        }

        fn selectedLabel(
            app: *App,
            query: picker_state.WebPickerQuery,
            column: *const ColumnBuffer,
        ) ?[]const u8 {
            if (column.count == 0) return null;
            if (exactLabel(query.query, column)) |label| return label;
            const index = currentIndex(app, query.stage) % column.count;
            return column.labels[index];
        }

        fn currentIndex(app: *App, stage: WebPickerStage) usize {
            const picker = &app.input_runtime.picker;
            return switch (stage) {
                .search => picker.web_search_column_index,
                .fetch => picker.web_fetch_column_index,
            };
        }

        fn selectCurrentSearch(app: *App) void {
            syncSearchSelection(app, app.web_search.slug());
        }

        fn selectCurrentFetch(app: *App) void {
            const picker = &app.input_runtime.picker;
            const current = app.web_fetch.slug();
            for (web_tools.fetch_slugs, 0..) |slug, index| {
                if (!std.mem.eql(u8, slug, current)) continue;
                picker.web_fetch_column_index = index;
                picker.web_fetch_column_window_start = 0;
                return;
            }
        }

        fn syncSearchSelection(app: *App, slug: []const u8) void {
            const picker = &app.input_runtime.picker;
            for (web_tools.search_slugs, 0..) |candidate, index| {
                if (!std.mem.eql(u8, candidate, slug)) continue;
                picker.web_search_column_index = index;
                picker.web_search_column_window_start = list_window.updateEdgeStart(
                    0,
                    web_tools.search_slugs.len,
                    index,
                    list_window.default_max_picker_rows,
                );
                return;
            }
        }

        fn setComposerText(app: *App, comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(app.alloc, fmt, args);
            defer app.alloc.free(text);
            try app.input_runtime.textReplacementState().replace(app.alloc, text);
        }
    };
}

fn exactLabel(raw_query: []const u8, column: *const ColumnBuffer) ?[]const u8 {
    const query = std.mem.trim(u8, raw_query, " \t");
    if (query.len == 0) return null;
    for (column.labels[0..column.count]) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, query)) return candidate;
    }
    return null;
}

const core_input_runtime = @import("../input/runtime.zig");
const render_request = @import("../../ui/render_request.zig");

const ColumnTestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    web_search: web_tools.SearchBackend = .exa,
    web_fetch: web_tools.FetchBackend = .local,
    shell: struct { render_requests: render_request.RenderRequestState = .{} } = .{},

    fn init(alloc: std.mem.Allocator) ColumnTestApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *ColumnTestApp) void {
        self.input_runtime.deinit(self.alloc);
    }
};

fn columnFor(app: *ColumnTestApp, stage: WebPickerStage, query: []const u8) ColumnBuffer {
    var column: ColumnBuffer = .{};
    _ = Runtime(ColumnTestApp).columnOptions(app, .{
        .stage = stage,
        .query = query,
        .token_start = 0,
    }, &column);
    return column;
}

test "web search column lists every backend and marks the active one" {
    var app = ColumnTestApp.init(std.testing.allocator);
    defer app.deinit();

    const column = columnFor(&app, .search, "");
    try std.testing.expectEqual(web_tools.search_slugs.len, column.count);
    try std.testing.expectEqualStrings("exa", column.labels[0]);
    try std.testing.expectEqualStrings("current", column.annotations[0]);
    for (column.annotations[1..column.count]) |annotation| {
        try std.testing.expectEqualStrings("", annotation);
    }
}

test "web fetch column marks the active fetch backend" {
    var app = ColumnTestApp.init(std.testing.allocator);
    defer app.deinit();
    app.web_fetch = .browserbase;

    const column = columnFor(&app, .fetch, "");
    try std.testing.expectEqual(@as(usize, 2), column.count);
    try std.testing.expectEqualStrings("local", column.labels[0]);
    try std.testing.expectEqualStrings("", column.annotations[0]);
    try std.testing.expectEqualStrings("browserbase", column.labels[1]);
    try std.testing.expectEqualStrings("current", column.annotations[1]);
}

test "web search column narrows to what was typed" {
    var app = ColumnTestApp.init(std.testing.allocator);
    defer app.deinit();

    const column = columnFor(&app, .search, "ta");
    try std.testing.expectEqual(@as(usize, 1), column.count);
    try std.testing.expectEqualStrings("tako", column.labels[0]);
}

test "web picker search submit opens the fetch column" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.textReplacementState().replace(alloc, "/web ");

    try std.testing.expect(try Runtime(ColumnTestApp).submit(&app));
    try std.testing.expectEqualStrings("/web exa ", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(WebPickerStage.fetch, app.input_runtime.picker.web_picker_stage);
    try std.testing.expectEqualStrings("exa", app.input_runtime.picker.web_picker_pending_search.items);
}

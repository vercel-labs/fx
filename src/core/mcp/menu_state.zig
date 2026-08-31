const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");

pub const Section = enum {
    servers,
    tools,
    resources,
    prompts,
};

pub const Screen = enum {
    browse,
    details,
    preview,
    add,
    arguments,
    info,
    confirm,
};

pub const max_query_bytes: usize = 128;

pub const LoadState = enum {
    idle,
    loading,
    ready,
    failed,
    cancelled,
};

pub const AddTransport = enum { local, http };

pub const Action = enum {
    refresh,
    authenticate,
    logout,
    add_local,
    add_http,
    remove,
    trust_approve,
    trust_reject,
    trust_approve_all,
    trust_reset,
    insert_preview,
};

pub const Request = struct {
    generation: u64,
    section: Section,
    server_index: usize,
    selected_index: usize,
};

pub const ActionRequest = struct {
    generation: u64,
    action: Action,
    selected_index: usize,
};

pub const Effect = union(enum) {
    load_catalog: Request,
    load_preview: Request,
    complete_argument: Request,
    action: ActionRequest,
    cancel: u64,
};

pub const Move = struct {
    delta: i8,
    item_count: usize,
    visible_count: usize,
};

pub const Event = union(enum) {
    open: usize,
    close,
    back,
    move: Move,
    scroll_preview: struct { delta: i8, row_count: usize },
    cycle_section: i8,
    cycle_add_transport,
    move_add_field: struct { delta: i8, field_count: usize },
    move_argument: struct { delta: i8, field_count: usize },
    begin_filter,
    append_filter_byte: u8,
    delete_filter_byte,
    clear_filter_text,
    clear_filter,
    show_details,
    show_add,
    show_arguments: usize,
    show_info,
    show_confirmation: Action,
    begin_preview,
    request_completion,
    request_action: Action,
    catalog_loaded: struct { generation: u64, item_count: usize },
    preview_loaded: u64,
    completion_loaded: u64,
    action_succeeded: u64,
    effect_failed: u64,
    effect_cancelled: u64,
};

pub const State = struct {
    active: bool = false,
    section: Section = .servers,
    screen: Screen = .browse,
    selected_index: usize = 0,
    selected_server_index: usize = 0,
    window_start: usize = 0,
    load_state: LoadState = .idle,
    next_generation: u64 = 1,
    pending_generation: ?u64 = null,
    confirmation_action: ?Action = null,
    add_transport: AddTransport = .local,
    add_field_index: usize = 0,
    argument_index: usize = 0,
    filter_active: bool = false,
    query_len: usize = 0,
    query: [max_query_bytes]u8 = undefined,

    pub fn queryText(self: *const State) []const u8 {
        return self.query[0..self.query_len];
    }
};

const Transition = struct {
    state: State,
    effect: ?Effect = null,
};

fn reduce(current: State, event: Event) Transition {
    var state = current;
    const effect = apply(&state, event);
    return .{ .state = state, .effect = effect };
}

pub fn apply(next: *State, event: Event) ?Effect {
    return switch (event) {
        .open => |server_count| blk: {
            next.* = .{
                .active = true,
                .load_state = .ready,
            };
            clampSelection(next, server_count, server_count);
            break :blk null;
        },
        .close => blk: {
            const pending = next.pending_generation;
            next.* = .{};
            break :blk if (pending) |generation| .{ .cancel = generation } else null;
        },
        .back => if (!next.active)
            null
        else if (next.screen == .browse)
            apply(next, .close)
        else blk: {
            next.screen = .browse;
            next.confirmation_action = null;
            next.argument_index = 0;
            const pending = next.pending_generation;
            next.pending_generation = null;
            if (pending != null) next.load_state = .cancelled;
            break :blk if (pending) |generation| .{ .cancel = generation } else null;
        },
        .move => |move| blk: {
            if (!next.active or move.item_count == 0 or move.delta == 0) {
                break :blk null;
            }
            if (move.delta > 0) {
                next.selected_index = (next.selected_index + 1) % move.item_count;
            } else {
                next.selected_index = if (next.selected_index == 0)
                    move.item_count - 1
                else
                    next.selected_index - 1;
            }
            clampSelection(next, move.item_count, move.visible_count);
            if (next.section == .servers and next.screen == .browse) {
                next.selected_server_index = next.selected_index;
            }
            break :blk null;
        },
        .scroll_preview => |scroll| blk: {
            if (!next.active or next.screen != .preview or scroll.row_count == 0 or scroll.delta == 0) {
                break :blk null;
            }
            if (scroll.delta > 0) {
                next.window_start = @min(next.window_start +| 1, scroll.row_count - 1);
            } else {
                next.window_start -|= 1;
            }
            break :blk null;
        },
        .cycle_section => |delta| blk: {
            if (!next.active or delta == 0) break :blk null;
            const count = @typeInfo(Section).@"enum".fields.len;
            const current_index: usize = @intFromEnum(next.section);
            const section_index = if (delta > 0)
                (current_index + 1) % count
            else if (current_index == 0)
                count - 1
            else
                current_index - 1;
            next.section = @enumFromInt(section_index);
            next.screen = .browse;
            next.selected_index = 0;
            next.window_start = 0;
            next.filter_active = false;
            next.query_len = 0;
            if (next.section == .servers) {
                next.selected_index = next.selected_server_index;
                next.load_state = .ready;
                break :blk null;
            }
            break :blk beginEffect(next, .load_catalog);
        },
        .cycle_add_transport => blk: {
            if (next.active and next.screen == .add) {
                next.add_transport = if (next.add_transport == .local) .http else .local;
                next.add_field_index = 0;
            }
            break :blk null;
        },
        .begin_filter => blk: {
            if (next.active and next.screen == .browse and next.section != .servers) {
                next.filter_active = true;
                next.selected_index = 0;
                next.window_start = 0;
            }
            break :blk null;
        },
        .append_filter_byte => |byte| blk: {
            if (next.filter_active and next.query_len < max_query_bytes and
                byte >= 0x20 and byte < 0x7f)
            {
                next.query[next.query_len] = byte;
                next.query_len += 1;
                next.selected_index = 0;
                next.window_start = 0;
            }
            break :blk null;
        },
        .delete_filter_byte => blk: {
            if (next.filter_active and next.query_len > 0) {
                next.query_len -= 1;
                next.selected_index = 0;
                next.window_start = 0;
            }
            break :blk null;
        },
        .clear_filter_text => blk: {
            if (next.filter_active) {
                next.query_len = 0;
                next.selected_index = 0;
                next.window_start = 0;
            }
            break :blk null;
        },
        .clear_filter => blk: {
            next.filter_active = false;
            next.query_len = 0;
            next.selected_index = 0;
            next.window_start = 0;
            break :blk null;
        },
        .move_add_field => |move| blk: {
            if (!next.active or next.screen != .add or move.field_count == 0 or move.delta == 0) {
                break :blk null;
            }
            if (move.delta > 0) {
                next.add_field_index = (next.add_field_index + 1) % move.field_count;
            } else {
                next.add_field_index = if (next.add_field_index == 0)
                    move.field_count - 1
                else
                    next.add_field_index - 1;
            }
            break :blk null;
        },
        .move_argument => |move| blk: {
            if (!next.active or next.screen != .arguments or move.field_count == 0 or move.delta == 0) {
                break :blk null;
            }
            if (move.delta > 0) {
                next.argument_index = (next.argument_index + 1) % move.field_count;
            } else {
                next.argument_index = if (next.argument_index == 0)
                    move.field_count - 1
                else
                    next.argument_index - 1;
            }
            break :blk null;
        },
        .show_details => blk: {
            if (next.active and next.section == .servers) next.screen = .details;
            break :blk null;
        },
        .show_add => blk: {
            if (next.active) {
                next.screen = .add;
                next.add_field_index = 0;
            }
            break :blk null;
        },
        .show_arguments => |field_count| blk: {
            if (next.active and next.section != .servers and field_count > 0) {
                next.screen = .arguments;
                next.filter_active = false;
                next.argument_index = 0;
            }
            break :blk null;
        },
        .show_info => blk: {
            if (next.active and next.section == .servers) next.screen = .info;
            break :blk null;
        },
        .show_confirmation => |action| blk: {
            if (next.active) {
                next.screen = .confirm;
                next.confirmation_action = action;
            }
            break :blk null;
        },
        .begin_preview => blk: {
            if (!next.active or next.section == .servers) break :blk null;
            next.filter_active = false;
            break :blk beginEffect(next, .load_preview);
        },
        .request_completion => if (!next.active or next.screen != .arguments)
            null
        else
            beginEffect(next, .complete_argument),
        .request_action => |action| blk: {
            if (!next.active or (action == .insert_preview and next.screen != .preview)) {
                break :blk null;
            }
            if (requiresConfirmation(action) and
                (next.screen != .confirm or next.confirmation_action != action))
            {
                break :blk null;
            }
            break :blk beginEffect(next, .{ .action = action });
        },
        .catalog_loaded => |loaded| blk: {
            if (next.pending_generation != loaded.generation) break :blk null;
            next.pending_generation = null;
            next.load_state = .ready;
            next.confirmation_action = null;
            clampSelection(next, loaded.item_count, loaded.item_count);
            next.screen = .browse;
            break :blk null;
        },
        .preview_loaded => |generation| blk: {
            if (next.pending_generation != generation) break :blk null;
            next.pending_generation = null;
            next.load_state = .ready;
            next.screen = .preview;
            next.window_start = 0;
            break :blk null;
        },
        .completion_loaded => |generation| blk: {
            if (next.pending_generation != generation) break :blk null;
            next.pending_generation = null;
            next.load_state = .ready;
            break :blk null;
        },
        .action_succeeded => |generation| blk: {
            if (next.pending_generation != generation) break :blk null;
            next.pending_generation = null;
            next.load_state = .ready;
            next.confirmation_action = null;
            break :blk null;
        },
        .effect_failed => |generation| blk: {
            if (next.pending_generation != generation) break :blk null;
            next.pending_generation = null;
            next.load_state = .failed;
            break :blk null;
        },
        .effect_cancelled => |generation| blk: {
            if (next.pending_generation != generation) break :blk null;
            next.pending_generation = null;
            next.load_state = .cancelled;
            break :blk null;
        },
    };
}

pub fn textMatchesQuery(text: []const u8, query: []const u8) bool {
    return query.len == 0 or text_utils.containsIgnoreCase(text, query);
}

fn requiresConfirmation(action: Action) bool {
    return switch (action) {
        .logout, .remove, .trust_reject, .trust_approve_all, .trust_reset => true,
        .refresh, .authenticate, .add_local, .add_http, .trust_approve, .insert_preview => false,
    };
}

const BeginEffect = union(enum) {
    load_catalog,
    load_preview,
    complete_argument,
    action: Action,
};

fn beginEffect(self: *State, effect: BeginEffect) Effect {
    const generation = self.next_generation;
    self.next_generation +%= 1;
    if (self.next_generation == 0) self.next_generation = 1;
    self.pending_generation = generation;
    self.load_state = .loading;
    return switch (effect) {
        .load_catalog => .{ .load_catalog = .{
            .generation = generation,
            .section = self.section,
            .server_index = self.selected_server_index,
            .selected_index = self.selected_index,
        } },
        .load_preview => .{ .load_preview = .{
            .generation = generation,
            .section = self.section,
            .server_index = self.selected_server_index,
            .selected_index = self.selected_index,
        } },
        .complete_argument => .{ .complete_argument = .{
            .generation = generation,
            .section = self.section,
            .server_index = self.selected_server_index,
            .selected_index = self.selected_index,
        } },
        .action => |action| .{ .action = .{
            .generation = generation,
            .action = action,
            .selected_index = self.selected_index,
        } },
    };
}

fn clampSelection(self: *State, item_count: usize, visible_count: usize) void {
    if (item_count == 0) {
        self.selected_index = 0;
        self.window_start = 0;
        return;
    }
    self.selected_index = @min(self.selected_index, item_count - 1);
    const visible = @max(@min(visible_count, item_count), 1);
    if (self.selected_index < self.window_start) self.window_start = self.selected_index;
    if (self.selected_index >= self.window_start + visible) {
        self.window_start = self.selected_index - visible + 1;
    }
    self.window_start = @min(self.window_start, item_count - visible);
}

test "MCP menu opens without describing an effect" {
    const transition = reduce(.{}, .{ .open = 3 });
    try std.testing.expect(transition.state.active);
    try std.testing.expectEqual(Section.servers, transition.state.section);
    try std.testing.expectEqual(LoadState.ready, transition.state.load_state);
    try std.testing.expect(transition.effect == null);
}

test "MCP menu navigation wraps and keeps the selection visible" {
    var state = reduce(.{}, .{ .open = 5 }).state;
    state = reduce(state, .{ .move = .{ .delta = -1, .item_count = 5, .visible_count = 2 } }).state;
    try std.testing.expectEqual(@as(usize, 4), state.selected_index);
    try std.testing.expectEqual(@as(usize, 3), state.window_start);

    state = reduce(state, .{ .move = .{ .delta = 1, .item_count = 5, .visible_count = 2 } }).state;
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    try std.testing.expectEqual(@as(usize, 0), state.window_start);
}

test "MCP menu section change describes one generated load effect" {
    const opened = reduce(.{}, .{ .open = 1 }).state;
    const transition = reduce(opened, .{ .cycle_section = 1 });
    try std.testing.expectEqual(Section.tools, transition.state.section);
    try std.testing.expectEqual(LoadState.loading, transition.state.load_state);
    try std.testing.expectEqual(@as(?u64, 1), transition.state.pending_generation);
    switch (transition.effect.?) {
        .load_catalog => |request| {
            try std.testing.expectEqual(@as(u64, 1), request.generation);
            try std.testing.expectEqual(Section.tools, request.section);
        },
        .load_preview, .complete_argument, .action, .cancel => return error.TestUnexpectedEffect,
    }
}

test "MCP menu ignores stale effect completion" {
    const opened = reduce(.{}, .{ .open = 1 }).state;
    const loading = reduce(opened, .{ .cycle_section = 1 }).state;
    const stale = reduce(loading, .{ .catalog_loaded = .{ .generation = 99, .item_count = 3 } });
    try std.testing.expectEqual(loading, stale.state);
    try std.testing.expect(stale.effect == null);

    const completed = reduce(loading, .{ .catalog_loaded = .{ .generation = 1, .item_count = 3 } });
    try std.testing.expectEqual(LoadState.ready, completed.state.load_state);
    try std.testing.expectEqual(Screen.browse, completed.state.screen);
    try std.testing.expect(completed.state.pending_generation == null);
}

test "MCP menu close cancels only its pending generation" {
    const opened = reduce(.{}, .{ .open = 1 }).state;
    const loading = reduce(opened, .{ .cycle_section = 1 }).state;
    const transition = reduce(loading, .close);
    try std.testing.expect(!transition.state.active);
    switch (transition.effect.?) {
        .cancel => |generation| try std.testing.expectEqual(@as(u64, 1), generation),
        .load_catalog, .load_preview, .complete_argument, .action => return error.TestUnexpectedEffect,
    }
}

test "MCP menu insert is available only from an explicit preview" {
    const opened = reduce(.{}, .{ .open = 1 }).state;
    try std.testing.expect(reduce(opened, .{ .request_action = .insert_preview }).effect == null);

    var preview = opened;
    preview.screen = .preview;
    const transition = reduce(preview, .{ .request_action = .insert_preview });
    switch (transition.effect.?) {
        .action => |request| try std.testing.expectEqual(Action.insert_preview, request.action),
        .load_catalog, .load_preview, .complete_argument, .cancel => return error.TestUnexpectedEffect,
    }
}

test "MCP menu preview opens only after the matching preview result" {
    var state = reduce(.{}, .{ .open = 1 }).state;
    state.section = .resources;
    const loading = reduce(state, .begin_preview);
    switch (loading.effect.?) {
        .load_preview => |request| try std.testing.expectEqual(@as(u64, 1), request.generation),
        .load_catalog, .complete_argument, .action, .cancel => return error.TestUnexpectedEffect,
    }
    const completed = reduce(loading.state, .{ .preview_loaded = 1 });
    try std.testing.expectEqual(Screen.preview, completed.state.screen);
}

test "MCP menu destructive actions require a matching confirmation" {
    const opened = reduce(.{}, .{ .open = 1 }).state;
    try std.testing.expect(reduce(opened, .{ .request_action = .remove }).effect == null);
    const confirming = reduce(opened, .{ .show_confirmation = .remove }).state;
    const requested = reduce(confirming, .{ .request_action = .remove });
    switch (requested.effect.?) {
        .action => |request| try std.testing.expectEqual(Action.remove, request.action),
        .load_catalog, .load_preview, .complete_argument, .cancel => return error.TestUnexpectedEffect,
    }
}

test "MCP add form transport and field movement are pure and bounded" {
    var state = reduce(.{}, .{ .open = 0 }).state;
    state = reduce(state, .show_add).state;
    try std.testing.expectEqual(Screen.add, state.screen);
    try std.testing.expectEqual(AddTransport.local, state.add_transport);
    state = reduce(state, .cycle_add_transport).state;
    try std.testing.expectEqual(AddTransport.http, state.add_transport);
    state = reduce(state, .{ .move_add_field = .{ .delta = -1, .field_count = 2 } }).state;
    try std.testing.expectEqual(@as(usize, 1), state.add_field_index);
}

test "MCP menu records matching cancellation as a value" {
    var state = reduce(.{}, .{ .open = 1 }).state;
    state = reduce(state, .{ .cycle_section = 1 }).state;
    const cancelled = reduce(state, .{ .effect_cancelled = 1 }).state;
    try std.testing.expectEqual(LoadState.cancelled, cancelled.load_state);
    try std.testing.expect(cancelled.pending_generation == null);
}

test "MCP menu preserves the selected server across catalog sections" {
    var state = reduce(.{}, .{ .open = 3 }).state;
    state = reduce(state, .{ .move = .{
        .delta = 1,
        .item_count = 3,
        .visible_count = 3,
    } }).state;
    try std.testing.expectEqual(@as(usize, 1), state.selected_server_index);
    state = reduce(state, .{ .cycle_section = 1 }).state;
    state = reduce(state, .{ .cycle_section = -1 }).state;
    try std.testing.expectEqual(Section.servers, state.section);
    try std.testing.expectEqual(@as(usize, 1), state.selected_index);
}

test "MCP menu filtering is bounded and resets navigation" {
    var state = reduce(.{}, .{ .open = 1 }).state;
    state = reduce(state, .{ .cycle_section = 1 }).state;
    state = reduce(state, .begin_filter).state;
    try std.testing.expect(state.filter_active);
    for ("query") |byte| state = reduce(state, .{ .append_filter_byte = byte }).state;
    try std.testing.expectEqualStrings("query", state.queryText());
    state.selected_index = 4;
    state.window_start = 3;
    state = reduce(state, .delete_filter_byte).state;
    try std.testing.expectEqualStrings("quer", state.queryText());
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    state = reduce(state, .clear_filter).state;
    try std.testing.expect(!state.filter_active);
    try std.testing.expectEqual(@as(usize, 0), state.query_len);
}

test "MCP argument form completion keeps form state and can be cancelled" {
    var state = reduce(.{}, .{ .open = 1 }).state;
    state = reduce(state, .{ .cycle_section = 1 }).state;
    state = reduce(state, .{ .catalog_loaded = .{ .generation = 1, .item_count = 1 } }).state;
    state = reduce(state, .{ .show_arguments = 2 }).state;
    try std.testing.expectEqual(Screen.arguments, state.screen);
    state = reduce(state, .{ .move_argument = .{ .delta = 1, .field_count = 2 } }).state;
    try std.testing.expectEqual(@as(usize, 1), state.argument_index);
    const loading = reduce(state, .request_completion);
    switch (loading.effect.?) {
        .complete_argument => |request| try std.testing.expectEqual(@as(u64, 2), request.generation),
        .load_catalog, .load_preview, .action, .cancel => return error.TestUnexpectedEffect,
    }
    const completed = reduce(loading.state, .{ .completion_loaded = 2 }).state;
    try std.testing.expectEqual(Screen.arguments, completed.screen);
    try std.testing.expectEqual(LoadState.ready, completed.load_state);

    const loading_again = reduce(completed, .request_completion);
    const backed = reduce(loading_again.state, .back);
    try std.testing.expectEqual(Screen.browse, backed.state.screen);
    switch (backed.effect.?) {
        .cancel => |generation| try std.testing.expectEqual(@as(u64, 3), generation),
        .load_catalog, .load_preview, .complete_argument, .action => return error.TestUnexpectedEffect,
    }
}

test "MCP preview scrolling stays within its visual rows" {
    var state = reduce(.{}, .{ .open = 1 }).state;
    state.screen = .preview;
    state = reduce(state, .{ .scroll_preview = .{ .delta = 1, .row_count = 3 } }).state;
    try std.testing.expectEqual(@as(usize, 1), state.window_start);
    state = reduce(state, .{ .scroll_preview = .{ .delta = 1, .row_count = 3 } }).state;
    state = reduce(state, .{ .scroll_preview = .{ .delta = 1, .row_count = 3 } }).state;
    try std.testing.expectEqual(@as(usize, 2), state.window_start);
    state = reduce(state, .{ .scroll_preview = .{ .delta = -1, .row_count = 3 } }).state;
    try std.testing.expectEqual(@as(usize, 1), state.window_start);
}

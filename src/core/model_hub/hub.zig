//! The model hub (D221): one screen that `/model` and `/provider` open, after
//! proto's `model-hub.ts`. A sidebar of scopes (Roles, All models, each
//! provider, Web search) sits beside the scope's list. Keys move focus
//! between the two panes, search, and act; an action that changes the app
//! comes back as an `Effect` for the app runtime to carry out.
//!
//! The front door for the hub. Outside code imports this file.

const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const types = @import("../shared/types.zig");
pub const catalog = @import("catalog.zig");
pub const edits = @import("edits.zig");

const Allocator = std.mem.Allocator;
pub const Role = model_roles.Role;
pub const Snapshot = catalog.Snapshot;

pub const Focus = enum { scope, list };

pub const ScopeKind = enum { roles, all_models, provider, web_search };

pub const Scope = struct {
    kind: ScopeKind,
    /// The provider's index in the snapshot for `.provider`.
    provider: u16 = 0,

    fn eql(a: Scope, b: Scope) bool {
        return a.kind == b.kind and (a.kind != .provider or a.provider == b.provider);
    }
};

/// Where `/model` and `/provider` open the hub.
pub const Start = enum { models, providers };

/// A row of chips shown in place of the hint line, as proto's strips.
pub const Strip = union(enum) {
    none,
    /// Roles to assign the highlighted model to.
    roles: usize,
    /// Reasoning efforts to use the highlighted model with: `auto` first.
    thinking: usize,
    /// Confirms signing out of a provider.
    sign_out: u16,
};

pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    tab,
    back_tab,
    enter,
    escape,
    backspace,
    delete,
    clear_query,
    role_strip,
    thinking_strip,
    char: u8,
};

pub const Effect = union(enum) {
    none,
    redraw,
    close,
    /// Use this model for the session, with this effort when given.
    select_model: struct { model: usize, effort: ?types.ReasoningEffort = null },
    assign_role: struct { role: Role, model: usize },
    clear_role: Role,
    toggle_cycle: Role,
    move_cycle: struct { role: Role, later: bool },
    sign_in: u16,
    sign_out: u16,
    /// Make a signed-in provider active so its catalog loads.
    activate_provider: u16,
    /// Move a web search provider earlier or later.
    move_web_search: struct { index: usize, later: bool },
    toggle_web_search: usize,
};

pub const max_query_bytes = 128;
const page_rows = 10;

pub const State = struct {
    active: bool = false,
    snapshot: ?Snapshot = null,
    focus: Focus = .list,
    scope: Scope = .{ .kind = .all_models },
    query_buf: [max_query_bytes]u8 = undefined,
    query_len: usize = 0,
    strip: Strip = .none,
    /// The role Enter on a model assigns, from the Roles list.
    assigning: ?Role = null,
    /// The highlighted row of the scope's list.
    selected: usize = 0,
    /// The first visible row, kept by the renderer's last frame.
    window_start: usize = 0,
    /// Rows the list showed last frame; page keys move this far.
    visible_rows: usize = page_rows,
    /// The screen size of the last frame; a change repaints from blank.
    painted_rows: u16 = 0,
    painted_cols: u16 = 0,
    /// Indices into the snapshot for the current list, rebuilt on change.
    rows: std.ArrayList(usize) = .empty,
    /// One line the hub shows after an action, such as what a role is now.
    notice_buf: [160]u8 = undefined,
    notice_len: usize = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.close(alloc);
        self.rows.deinit(alloc);
        self.* = .{};
    }

    /// Opens over `snapshot`, which the hub now owns.
    pub fn open(self: *State, alloc: Allocator, snapshot: Snapshot, start: Start) !void {
        self.close(alloc);
        self.snapshot = snapshot;
        self.active = true;
        switch (start) {
            .models => {
                self.scope = .{ .kind = .all_models };
                self.focus = .list;
            },
            .providers => {
                self.scope = .{ .kind = .provider, .provider = activeProvider(&self.snapshot.?) orelse 0 };
                if (self.snapshot.?.providers.len == 0) self.scope = .{ .kind = .web_search };
                self.focus = .scope;
            },
        }
        try self.rebuild(alloc);
        if (start == .models) self.selectCurrentModel();
    }

    pub fn close(self: *State, alloc: Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
        self.active = false;
        self.strip = .none;
        self.assigning = null;
        self.query_len = 0;
        self.selected = 0;
        self.window_start = 0;
        self.notice_len = 0;
        self.painted_rows = 0;
        self.painted_cols = 0;
        self.rows.clearRetainingCapacity();
        _ = alloc;
    }

    /// Swaps in a fresher snapshot, keeping the scope and the highlighted
    /// model or row where it still exists.
    pub fn replaceSnapshot(self: *State, alloc: Allocator, snapshot: Snapshot) !void {
        var next = snapshot;
        const old = self.snapshot orelse {
            next.deinit();
            return;
        };
        const keep_id: ?[]const u8 = if (self.selectedModel()) |index| old.models[index].id else null;
        const keep_provider: ?[]const u8 = if (self.scope.kind == .provider and self.scope.provider < old.providers.len)
            old.providers[self.scope.provider].key
        else
            null;
        var id_buf: [256]u8 = undefined;
        var key_buf: [64]u8 = undefined;
        const kept_id = if (keep_id) |id| copyInto(&id_buf, id) else null;
        const kept_key = if (keep_provider) |key| copyInto(&key_buf, key) else null;
        const previous_selected = self.selected;
        self.snapshot.?.deinit();
        self.snapshot = next;
        if (kept_key) |key| {
            self.scope = .{ .kind = .all_models };
            for (self.snapshot.?.providers, 0..) |provider, index| {
                if (std.mem.eql(u8, provider.key, key)) self.scope = .{ .kind = .provider, .provider = @intCast(index) };
            }
        }
        try self.rebuild(alloc);
        self.selected = @min(previous_selected, self.rows.items.len -| 1);
        if (kept_id) |id| for (self.rows.items, 0..) |model_index, row| {
            if (self.listsModels() and std.mem.eql(u8, self.snapshot.?.models[model_index].id, id)) self.selected = row;
        };
    }

    pub fn query(self: *const State) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn notice(self: *const State) []const u8 {
        return self.notice_buf[0..self.notice_len];
    }

    pub fn setNotice(self: *State, text: []const u8) void {
        const len = @min(text.len, self.notice_buf.len);
        @memcpy(self.notice_buf[0..len], text[0..len]);
        self.notice_len = len;
    }

    /// The sidebar, in order: Roles, All models, providers, Web search.
    pub fn scopes(self: *const State, out: []Scope) []Scope {
        var count: usize = 0;
        const snapshot = self.snapshot orelse return out[0..0];
        if (count < out.len) out[count] = .{ .kind = .roles };
        count += 1;
        if (count < out.len) out[count] = .{ .kind = .all_models };
        count += 1;
        for (snapshot.providers, 0..) |_, index| {
            if (count >= out.len) break;
            out[count] = .{ .kind = .provider, .provider = @intCast(index) };
            count += 1;
        }
        if (count < out.len) {
            out[count] = .{ .kind = .web_search };
            count += 1;
        }
        return out[0..@min(count, out.len)];
    }

    /// Whether the list holds models, so typing searches it.
    pub fn listsModels(self: *const State) bool {
        return switch (self.scope.kind) {
            .all_models => true,
            .provider => self.providerListsModels(self.scope.provider),
            .roles, .web_search => false,
        };
    }

    fn providerListsModels(self: *const State, index: u16) bool {
        const snapshot = self.snapshot orelse return false;
        if (index >= snapshot.providers.len) return false;
        const provider = snapshot.providers[index];
        return provider.signed_in and provider.models_known;
    }

    /// The model under the highlight, as a snapshot index.
    pub fn selectedModel(self: *const State) ?usize {
        if (!self.listsModels() or self.selected >= self.rows.items.len) return null;
        return self.rows.items[self.selected];
    }

    /// Recomputes the list for the scope and query.
    pub fn rebuild(self: *State, alloc: Allocator) !void {
        self.rows.clearRetainingCapacity();
        const snapshot = &(self.snapshot orelse return);
        switch (self.scope.kind) {
            .roles => for (snapshot.roles, 0..) |_, index| try self.rows.append(alloc, index),
            .web_search => for (snapshot.web_search, 0..) |_, index| try self.rows.append(alloc, index),
            .all_models, .provider => if (self.listsModels()) try self.collectModels(alloc, snapshot),
        }
        if (self.selected >= self.rows.items.len) self.selected = self.rows.items.len -| 1;
    }

    fn collectModels(self: *State, alloc: Allocator, snapshot: *const Snapshot) !void {
        const only: ?u16 = if (self.scope.kind == .provider) self.scope.provider else null;
        const text = std.mem.trim(u8, self.query(), " \t");
        var scores: std.ArrayList(u32) = .empty;
        defer scores.deinit(alloc);
        for (snapshot.models, 0..) |model, index| {
            if (only) |provider| if (model.provider != provider) continue;
            if (!snapshot.providers[model.provider].signed_in) continue;
            const score = catalog.modelSearchScore(snapshot, model, text) orelse continue;
            try self.rows.append(alloc, index);
            try scores.append(alloc, score);
        }
        if (text.len == 0) return;
        // Best match first; ties keep the catalog order.
        const Ctx = struct {
            scores: []const u32,
            rows: []usize,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                if (ctx.scores[a] != ctx.scores[b]) return ctx.scores[a] > ctx.scores[b];
                return ctx.rows[a] < ctx.rows[b];
            }
            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                std.mem.swap(u32, &@constCast(ctx.scores)[a], &@constCast(ctx.scores)[b]);
                std.mem.swap(usize, &ctx.rows[a], &ctx.rows[b]);
            }
        };
        std.sort.insertionContext(0, self.rows.items.len, Ctx{ .scores = scores.items, .rows = self.rows.items });
    }

    fn selectCurrentModel(self: *State) void {
        const snapshot = self.snapshot orelse return;
        for (self.rows.items, 0..) |index, row| {
            if (snapshot.models[index].current) {
                self.selected = row;
                return;
            }
        }
    }

    /// Handles one key. The caller carries out the effect, then refreshes
    /// the snapshot with `replaceSnapshot` when the effect changed the app.
    pub fn handle(self: *State, alloc: Allocator, key: Key) !Effect {
        if (!self.active) return .none;
        if (self.strip != .none) return self.handleStrip(key);
        switch (key) {
            .escape => return self.escape(alloc),
            .tab, .back_tab => {
                self.focus = if (self.focus == .scope) .list else .scope;
                return .redraw;
            },
            else => {},
        }
        self.notice_len = 0;
        return switch (self.focus) {
            .scope => self.handleScope(alloc, key),
            .list => self.handleList(alloc, key),
        };
    }

    fn escape(self: *State, alloc: Allocator) !Effect {
        if (self.assigning) |role| {
            self.assigning = null;
            try self.setScope(alloc, .{ .kind = .roles });
            self.selectRole(role);
            self.focus = .list;
            return .redraw;
        }
        if (self.query_len > 0 and self.listsModels()) {
            self.query_len = 0;
            try self.rebuild(alloc);
            return .redraw;
        }
        return .close;
    }

    fn setScope(self: *State, alloc: Allocator, scope: Scope) !void {
        if (Scope.eql(self.scope, scope)) return;
        self.scope = scope;
        self.selected = 0;
        self.window_start = 0;
        try self.rebuild(alloc);
        if (self.listsModels()) self.selectCurrentModel();
    }

    fn selectRole(self: *State, role: Role) void {
        const snapshot = self.snapshot orelse return;
        for (self.rows.items, 0..) |index, row| if (snapshot.roles[index].role == role) {
            self.selected = row;
        };
    }

    fn handleScope(self: *State, alloc: Allocator, key: Key) !Effect {
        var buf: [64]Scope = undefined;
        const list = self.scopes(&buf);
        if (list.len == 0) return .none;
        var position: usize = 0;
        for (list, 0..) |scope, index| if (Scope.eql(scope, self.scope)) {
            position = index;
        };
        switch (key) {
            .up, .down => {
                const next = if (key == .up) (position + list.len - 1) % list.len else (position + 1) % list.len;
                try self.setScope(alloc, list[next]);
                return .redraw;
            },
            .home, .end => {
                try self.setScope(alloc, if (key == .home) list[0] else list[list.len - 1]);
                return .redraw;
            },
            .right => return self.enterList(),
            .enter => {
                if (self.scope.kind == .provider) {
                    const provider = self.snapshot.?.providers[self.scope.provider];
                    if (!provider.signed_in) return if (provider.sign_in == .settings) .none else .{ .sign_in = self.scope.provider };
                    if (!provider.models_known) return .{ .activate_provider = self.scope.provider };
                }
                return self.enterList();
            },
            .backspace, .delete => {
                if (self.scope.kind != .provider) return .none;
                const provider = self.snapshot.?.providers[self.scope.provider];
                if (!provider.signed_in or !provider.can_sign_out) return .none;
                self.strip = .{ .sign_out = self.scope.provider };
                return .redraw;
            },
            .char => |byte| {
                if (byte < 0x20 or byte == 0x7f) return .none;
                // Typing searches every model, as proto's hub does.
                try self.setScope(alloc, .{ .kind = .all_models });
                self.focus = .list;
                return self.typeChar(alloc, byte);
            },
            else => return .none,
        }
    }

    fn enterList(self: *State) Effect {
        if (self.rows.items.len == 0) return .none;
        self.focus = .list;
        return .redraw;
    }

    fn handleList(self: *State, alloc: Allocator, key: Key) !Effect {
        switch (key) {
            .left => {
                self.focus = .scope;
                return .redraw;
            },
            .up => return self.move(-1, true),
            .down => return self.move(1, true),
            .page_up => return self.move(-@as(i32, @intCast(@max(self.visible_rows, 1))), false),
            .page_down => return self.move(@as(i32, @intCast(@max(self.visible_rows, 1))), false),
            .home => return self.move(-@as(i32, @intCast(self.rows.items.len)), false),
            .end => return self.move(@as(i32, @intCast(self.rows.items.len)), false),
            else => {},
        }
        return switch (self.scope.kind) {
            .roles => self.handleRoles(alloc, key),
            .web_search => self.handleWebSearch(key),
            .all_models, .provider => if (self.listsModels()) self.handleModels(alloc, key) else self.handleScope(alloc, key),
        };
    }

    fn move(self: *State, delta: i32, wrap: bool) Effect {
        const count = self.rows.items.len;
        if (count == 0) return .none;
        const current: i64 = @intCast(self.selected);
        var next = current + delta;
        if (wrap) {
            next = @mod(next, @as(i64, @intCast(count)));
        } else {
            next = std.math.clamp(next, 0, @as(i64, @intCast(count - 1)));
        }
        self.selected = @intCast(next);
        return .redraw;
    }

    fn handleModels(self: *State, alloc: Allocator, key: Key) !Effect {
        switch (key) {
            .enter => {
                const model = self.selectedModel() orelse return .none;
                if (self.assigning) |role| {
                    self.assigning = null;
                    try self.setScope(alloc, .{ .kind = .roles });
                    self.selectRole(role);
                    return .{ .assign_role = .{ .role = role, .model = model } };
                }
                return .{ .select_model = .{ .model = model } };
            },
            .role_strip => {
                if (self.selectedModel() == null or self.assigning != null) return .none;
                self.strip = .{ .roles = 0 };
                return .redraw;
            },
            .thinking_strip => {
                const model = self.selectedModel() orelse return .none;
                if (self.assigning != null) return .none;
                const efforts = self.snapshot.?.models[model].efforts;
                var current: usize = 0;
                for (efforts, 1..) |effort, index| if (self.snapshot.?.effort != null and effort.eql(self.snapshot.?.effort.?)) {
                    current = index;
                };
                self.strip = .{ .thinking = current };
                return .redraw;
            },
            .backspace => {
                if (self.query_len == 0) return .none;
                var end = self.query_len - 1;
                while (end > 0 and (self.query_buf[end] & 0xc0) == 0x80) end -= 1;
                self.query_len = end;
                return self.requery(alloc);
            },
            .clear_query => {
                self.query_len = 0;
                return self.requery(alloc);
            },
            .char => |byte| return self.typeChar(alloc, byte),
            else => return .none,
        }
    }

    fn typeChar(self: *State, alloc: Allocator, byte: u8) !Effect {
        if (byte < 0x20 or byte == 0x7f) return .none;
        if (self.query_len >= self.query_buf.len) return .none;
        self.query_buf[self.query_len] = byte;
        self.query_len += 1;
        return self.requery(alloc);
    }

    fn requery(self: *State, alloc: Allocator) !Effect {
        try self.rebuild(alloc);
        self.selected = 0;
        self.window_start = 0;
        return .redraw;
    }

    fn handleRoles(self: *State, alloc: Allocator, key: Key) !Effect {
        const snapshot = self.snapshot.?;
        if (self.selected >= self.rows.items.len) return .none;
        const role = snapshot.roles[self.rows.items[self.selected]].role;
        switch (key) {
            .enter, .right => {
                self.assigning = role;
                self.query_len = 0;
                try self.setScope(alloc, .{ .kind = .all_models });
                self.focus = .list;
                return .redraw;
            },
            .backspace, .delete => return .{ .clear_role = role },
            .char => |byte| switch (byte) {
                'x' => return .{ .clear_role = role },
                'c' => return .{ .toggle_cycle = role },
                '[', ']' => {
                    if (snapshot.roleRow(role).?.cycle_position == null) return .none;
                    return .{ .move_cycle = .{ .role = role, .later = byte == ']' } };
                },
                else => return self.handleScope(alloc, key),
            },
            else => return .none,
        }
    }

    fn handleWebSearch(self: *State, key: Key) Effect {
        if (self.selected >= self.rows.items.len) return .none;
        const index = self.rows.items[self.selected];
        switch (key) {
            .enter => return .{ .toggle_web_search = index },
            .char => |byte| switch (byte) {
                ' ', 'x' => return .{ .toggle_web_search = index },
                '[', ']' => {
                    const later = byte == ']';
                    if (!later and index == 0) return .none;
                    if (later and index + 1 >= self.snapshot.?.web_search.len) return .none;
                    // The highlight follows the provider it moved.
                    self.selected = if (later) self.selected + 1 else self.selected - 1;
                    return .{ .move_web_search = .{ .index = index, .later = later } };
                },
                else => return .none,
            },
            else => return .none,
        }
    }

    /// The chips of the open strip, as roles or efforts.
    pub fn stripCount(self: *const State) usize {
        return switch (self.strip) {
            .none => 0,
            .roles => catalog.role_order.len,
            .thinking => if (self.selectedModel()) |model| self.snapshot.?.models[model].efforts.len + 1 else 1,
            .sign_out => 2,
        };
    }

    /// The effort chip at `index`: 0 is `auto`.
    pub fn stripEffort(self: *const State, index: usize) types.ReasoningEffort {
        if (index == 0) return .auto;
        const model = self.selectedModel() orelse return .auto;
        const efforts = self.snapshot.?.models[model].efforts;
        return if (index - 1 < efforts.len) efforts[index - 1] else .auto;
    }

    fn handleStrip(self: *State, key: Key) Effect {
        const count = self.stripCount();
        const selected: *usize = switch (self.strip) {
            .roles => |*value| value,
            .thinking => |*value| value,
            .sign_out => {
                switch (key) {
                    .enter => {
                        const provider = self.strip.sign_out;
                        self.strip = .none;
                        return .{ .sign_out = provider };
                    },
                    else => {
                        self.strip = .none;
                        return .redraw;
                    },
                }
            },
            .none => return .none,
        };
        switch (key) {
            .escape => {
                self.strip = .none;
                return .redraw;
            },
            .left, .up, .back_tab => {
                selected.* = (selected.* + count - 1) % count;
                return .redraw;
            },
            .right, .down, .tab => {
                selected.* = (selected.* + 1) % count;
                return .redraw;
            },
            .enter => {
                const model = self.selectedModel() orelse {
                    self.strip = .none;
                    return .redraw;
                };
                const index = selected.*;
                const strip = self.strip;
                self.strip = .none;
                return switch (strip) {
                    .roles => blk: {
                        const role = catalog.role_order[index];
                        const holds = std.mem.findScalar(Role, self.snapshot.?.models[model].roles, role) != null;
                        break :blk if (holds) .{ .clear_role = role } else .{ .assign_role = .{ .role = role, .model = model } };
                    },
                    .thinking => .{ .select_model = .{ .model = model, .effort = self.stripEffort(index) } },
                    else => .redraw,
                };
            },
            else => return .none,
        }
    }
};

fn activeProvider(snapshot: *const Snapshot) ?u16 {
    for (snapshot.providers, 0..) |provider, index| if (provider.active) return @intCast(index);
    return null;
}

fn copyInto(buf: []u8, text: []const u8) ?[]const u8 {
    if (text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

test {
    _ = catalog;
    _ = edits;
    _ = @import("hub_tests.zig");
}

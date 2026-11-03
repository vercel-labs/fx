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
pub const RoleId = model_roles.RoleId;
pub const Snapshot = catalog.Snapshot;
pub const RoleScope = enum { global, workspace };

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
    /// Chooses where role assignments are persisted before role chips open.
    role_scope: usize,
    /// Reasoning efforts to use the highlighted model with: `auto` first.
    thinking: usize,
    /// The thinking level of the highlighted role entry: `auto` first (D251).
    entry_thinking: usize,
    /// Confirms signing out of a provider.
    sign_out: u16,
};

pub const MouseKind = enum { press, motion, release };
pub const Mouse = struct {
    kind: MouseKind,
    row: u16,
    column: u16,
    /// Wheel reports are translated by the input decoder before they reach
    /// the hub; this is reserved for terminals that report them as pointer
    /// events.
    wheel: i8 = 0,
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
    force_refresh,
    mouse: Mouse,
    char: u8,
};

pub const Effect = union(enum) {
    none,
    redraw,
    close,
    /// Use this model for the session, with this effort when given.
    select_model: struct { model: usize, effort: ?types.ReasoningEffort = null },
    /// Changes one role's chain (D250).
    edit_role: struct { role: RoleId, edit: RoleEdit, scope: RoleScope = .global },
    clear_role: RoleId,
    create_role: struct { name: []const u8 },
    rename_role: struct { role: RoleId, name: []const u8 },
    delete_role: RoleId,
    edit_tag: struct { role: RoleId, edit: TagEdit },
    edit_bank: struct { role: RoleId, selectors: []const []const u8 },
    edit_fallback: struct { selector: []const u8, chain: ?[]const u8 },
    refresh_provider: u16,
    toggle_cycle: RoleId,
    move_cycle: struct { role: RoleId, later: bool },
    sign_in: u16,
    sign_out: u16,
    /// Make a signed-in provider active so its catalog loads.
    activate_provider: u16,
    /// Move a web search provider earlier or later.
    move_web_search: struct { index: usize, later: bool },
    toggle_web_search: usize,
};

pub const TagEdit = struct {
    tag: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    color: ?[]const u8 = null,
    hidden: ?bool = null,
    clear: bool = false,
};

/// A change to one role's chain, by entry: 0 is the assignment, later
/// entries its fallbacks.
pub const RoleEdit = union(enum) {
    /// Puts the snapshot's model at `entry`, or appends it when null.
    put: struct { entry: ?usize, model: usize },
    remove: usize,
    move: struct { entry: usize, later: bool },
    /// Null saves the entry without a level, so it keeps the session's.
    thinking: struct { entry: usize, effort: ?types.ReasoningEffort },
};

/// What Enter on a model does while a role waits for one.
pub const Assigning = struct {
    role: RoleId,
    /// The entry the model replaces; null appends a fallback.
    entry: ?usize,
};

/// A Roles list row: the role's own row (entry 0) or one of its fallbacks.
pub const RoleCursor = struct {
    role_index: usize,
    entry: usize,

    const entry_bits = 4;

    pub fn decode(row: usize) RoleCursor {
        return .{ .role_index = row >> entry_bits, .entry = row & ((1 << entry_bits) - 1) };
    }

    fn encode(self: RoleCursor) usize {
        return (self.role_index << entry_bits) | self.entry;
    }

    comptime {
        std.debug.assert(model_roles.max_chain < (1 << entry_bits));
    }
};

const max_query_bytes = 128;
const page_rows = 10;

pub const State = struct {
    active: bool = false,
    snapshot: ?Snapshot = null,
    focus: Focus = .list,
    scope: Scope = .{ .kind = .all_models },
    query_buf: [max_query_bytes]u8 = undefined,
    query_len: usize = 0,
    role_name_buf: [model_roles.max_role_bytes]u8 = undefined,
    role_name_len: usize = 0,
    role_name_mode: enum { none, create, rename, tag } = .none,
    bank_buf: [model_roles.max_chain][]const u8 = undefined,
    bank_len: usize = 0,
    fallback_selector_buf: [model_roles.max_selector_bytes]u8 = undefined,
    fallback_chain_buf: [model_roles.max_ref_bytes]u8 = undefined,
    selected_role_scope: RoleScope = .workspace,
    hovered: ?usize = null,
    hovered_scope: ?Scope = null,
    strip: Strip = .none,
    /// The role Enter on a model assigns, from the Roles list.
    assigning: ?Assigning = null,
    /// The highlighted row of the scope's list.
    selected: usize = 0,
    /// The first visible row, kept by the renderer's last frame.
    window_start: usize = 0,
    /// Rows the list showed last frame; page keys move this far.
    visible_rows: usize = page_rows,
    /// The screen size of the last frame; a change repaints from blank.
    painted_rows: u16 = 0,
    painted_cols: u16 = 0,
    /// Geometry of the last frame, used by native SGR mouse routing.
    layout_rows: u16 = 0,
    layout_cols: u16 = 0,
    layout_sidebar_width: u16 = 0,
    layout_content_rows: u16 = 0,
    layout_body_offset: u16 = 0,
    layout_compact: bool = false,
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
                self.focus = .scope;
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
        self.role_name_len = 0;
        self.role_name_mode = .none;
        self.hovered = null;
        self.hovered_scope = null;
        self.selected = 0;
        self.window_start = 0;
        self.notice_len = 0;
        self.painted_rows = 0;
        self.painted_cols = 0;
        self.layout_rows = 0;
        self.layout_cols = 0;
        self.layout_sidebar_width = 0;
        self.layout_content_rows = 0;
        self.layout_body_offset = 0;
        self.layout_compact = false;
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
            .roles => for (snapshot.roles, 0..) |role_row, index| {
                if (role_row.hidden) continue;
                try self.rows.append(alloc, (RoleCursor{ .role_index = index, .entry = 0 }).encode());
                for (1..@max(role_row.entries.len, 1)) |entry| try self.rows.append(alloc, (RoleCursor{ .role_index = index, .entry = entry }).encode());
            },
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

    /// Handles one SGR mouse event using the last painted frame. A click is
    /// intentionally select-then-activate, matching the browser and roles
    /// pane; motion only records the geometry for a future repaint.
    pub fn handleMouse(self: *State, alloc: Allocator, mouse: Mouse) !Effect {
        if (!self.active) return .none;
        if (mouse.wheel != 0) {
            const sidebar = self.layout_compact or mouse.column < self.layout_sidebar_width;
            if (sidebar) return self.handle(alloc, if (mouse.wheel < 0) .up else .down);
            return self.handle(alloc, if (mouse.wheel < 0) .up else .down);
        }
        if (mouse.kind == .motion) {
            self.updateHover(mouse);
            return .redraw;
        }
        if (mouse.kind == .release) return .redraw;
        if (self.strip != .none and self.layout_rows > 0 and mouse.row + 1 >= self.layout_rows) {
            const count = self.stripCount();
            if (count == 0) return .redraw;
            const col = @as(usize, mouse.column);
            const slot = @min(count - 1, col * count / @max(@as(usize, self.layout_cols), 1));
            switch (self.strip) {
                .role_scope => |*selected| selected.* = slot,
                .roles => |*selected| selected.* = slot,
                .thinking => |*selected| selected.* = slot,
                .entry_thinking => |*selected| selected.* = slot,
                .sign_out => {},
                .none => unreachable,
            }
            return self.handle(alloc, .enter);
        }
        if (self.layout_compact and mouse.row == 1) {
            self.focus = .scope;
            return .redraw;
        }
        const content_row = contentRow(mouse.row) orelse return .none;
        if (content_row >= self.layout_content_rows) return .none;
        if (!self.layout_compact and mouse.column <= self.layout_sidebar_width) {
            var scopes_buf: [64]Scope = undefined;
            const list = self.scopes(&scopes_buf);
            var row: usize = 0;
            for (list, 0..) |scope, index| {
                if (scope.kind == .provider and index > 0 and list[index - 1].kind != .provider) row += 1;
                if (row == content_row) {
                    if (Scope.eql(scope, self.scope)) {
                        self.focus = .list;
                        return .redraw;
                    }
                    try self.setScope(alloc, scope);
                    self.focus = .scope;
                    return .redraw;
                }
                row += 1;
            }
            return .none;
        }
        // Compact mode alternates panes; a body click is a list click only
        // while the list is visible.
        if (self.layout_compact and self.focus != .list) return .none;
        var header: usize = 1; // status line
        if (self.listsModels() or self.layout_content_rows >= 8) header += 1; // search line
        if (self.layout_content_rows >= 8) header += 1; // breathing row
        if (content_row < header) return .none;
        const list_row = content_row - header;
        if (list_row >= self.rows.items.len) return .none;
        const selected = self.selected;
        self.selected = @min(self.rows.items.len - 1, self.window_start + list_row);
        if (self.selected == selected) return self.handle(alloc, .enter);
        return .redraw;
    }

    fn contentRow(row: u16) ?u16 {
        // The renderer writes the first content line at terminal row 3; SGR
        // mouse coordinates are one-based, so row 3 maps to content row 0.
        if (row < 3) return null;
        return row - 3;
    }

    fn updateHover(self: *State, mouse: Mouse) void {
        self.hovered = null;
        self.hovered_scope = null;
        const content_row = contentRow(mouse.row) orelse return;
        if (!self.layout_compact and mouse.column <= self.layout_sidebar_width) {
            var scopes_buf: [64]Scope = undefined;
            const list = self.scopes(&scopes_buf);
            var row: usize = 0;
            for (list, 0..) |scope, index| {
                if (scope.kind == .provider and index > 0 and list[index - 1].kind != .provider) row += 1;
                if (row == content_row) {
                    self.hovered_scope = scope;
                    return;
                }
                row += 1;
            }
            return;
        }
        if (self.layout_compact and self.focus != .list) return;
        var header: usize = 1;
        if (self.listsModels() or self.layout_content_rows >= 8) header += 1;
        if (self.layout_content_rows >= 8) header += 1;
        if (content_row < header) return;
        const row = self.window_start + content_row - header;
        if (row < self.rows.items.len) self.hovered = row;
    }

    /// Handles one key. The caller carries out the effect, then refreshes
    /// the snapshot with `replaceSnapshot` when the effect changed the app.
    pub fn handle(self: *State, alloc: Allocator, key: Key) !Effect {
        if (!self.active) return .none;
        if (self.role_name_mode != .none) return self.handleRoleName(key);
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
        if (key == .force_refresh) {
            const provider = switch (self.scope.kind) {
                .provider => self.scope.provider,
                .all_models => if (self.selectedModel()) |model| self.snapshot.?.models[model].provider else return .none,
                else => return .none,
            };
            if (provider >= self.snapshot.?.providers.len or !self.snapshot.?.providers[provider].signed_in) return .none;
            return .{ .refresh_provider = provider };
        }
        return switch (self.focus) {
            .scope => self.handleScope(alloc, key),
            .list => self.handleList(alloc, key),
        };
    }

    fn escape(self: *State, alloc: Allocator) !Effect {
        if (self.assigning) |assigning| {
            self.assigning = null;
            try self.setScope(alloc, .{ .kind = .roles });
            self.selectRole(assigning.role, assigning.entry orelse 0);
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

    /// Highlights `role`'s row for `entry`, else the role's own row.
    fn selectRole(self: *State, role: RoleId, entry: usize) void {
        const snapshot = self.snapshot orelse return;
        for (self.rows.items, 0..) |id, row| {
            const cursor = RoleCursor.decode(id);
            if (!snapshot.roles[cursor.role_index].role.eql(role)) continue;
            if (cursor.entry == 0) self.selected = row;
            if (cursor.entry == entry) {
                self.selected = row;
                return;
            }
        }
    }

    /// The Roles row under the highlight.
    pub fn roleCursor(self: *const State) ?RoleCursor {
        if (self.scope.kind != .roles or self.selected >= self.rows.items.len) return null;
        return RoleCursor.decode(self.rows.items[self.selected]);
    }

    /// The chain entry under the highlight in the Roles list.
    pub fn selectedEntry(self: *const State) ?catalog.EntryRow {
        const cursor = self.roleCursor() orelse return null;
        const entries = self.snapshot.?.roles[cursor.role_index].entries;
        return if (cursor.entry < entries.len) entries[cursor.entry] else null;
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
                if (self.assigning) |assigning| {
                    self.assigning = null;
                    try self.setScope(alloc, .{ .kind = .roles });
                    const entries = self.snapshot.?.roleRow(assigning.role).?.entries.len;
                    // The highlight lands where the model goes; the refresh keeps it.
                    self.selectRole(assigning.role, 0);
                    self.selected += assigning.entry orelse entries;
                    return .{ .edit_role = .{ .role = assigning.role, .edit = .{ .put = .{ .entry = assigning.entry, .model = model } } } };
                }
                return .{ .select_model = .{ .model = model } };
            },
            .role_strip => {
                if (self.selectedModel() == null or self.assigning != null) return .none;
                self.strip = .{ .role_scope = 0 };
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
            .char => |byte| switch (byte) {
                'F' => return self.startFallback(.model),
                'P' => return self.startFallback(.provider),
                'R' => return self.startFallback(.generic),
                else => return self.typeChar(alloc, byte),
            },
            else => return .none,
        }
    }

    const FallbackKind = enum { model, provider, generic };

    fn startFallback(self: *State, kind: FallbackKind) Effect {
        const model_index = self.selectedModel() orelse return .none;
        const model = self.snapshot.?.models[model_index];
        const provider = self.snapshot.?.providers[model.provider].key;
        const selector = switch (kind) {
            .model => std.mem.print(&self.fallback_selector_buf, "{s}/{s}", .{ provider, model.id }) catch return .none,
            .provider => std.mem.print(&self.fallback_selector_buf, "{s}/*", .{provider}) catch return .none,
            .generic => std.mem.print(&self.fallback_selector_buf, "*", .{}) catch return .none,
        };
        const chain = std.mem.print(&self.fallback_chain_buf, "{s}/{s}", .{ provider, model.id }) catch return .none;
        return .{ .edit_fallback = .{ .selector = selector, .chain = chain } };
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
        const cursor = self.roleCursor() orelse return .none;
        const role_row = snapshot.roles[cursor.role_index];
        const role = role_row.role;
        const own_row = cursor.entry == 0;
        switch (key) {
            .enter, .right => return self.startAssign(alloc, role, if (role_row.entries.len == 0) null else cursor.entry),
            .backspace, .delete => return self.removeEntry(role, own_row, cursor.entry),
            .char => |byte| switch (byte) {
                'x' => return self.removeEntry(role, own_row, cursor.entry),
                'f' => {
                    if (role_row.entries.len >= model_roles.max_chain) {
                        self.setNotice("A role keeps at most 8 models");
                        return .redraw;
                    }
                    return self.startAssign(alloc, role, null);
                },
                't' => {
                    const entry = self.selectedEntry() orelse return .none;
                    if (entry.state == .alias or entry.efforts.len == 0) {
                        self.setNotice("No thinking levels are known for this model");
                        return .redraw;
                    }
                    var current: usize = 0;
                    if (entry.effort) |effort| for (entry.efforts, 1..) |level, index| {
                        if (level.eql(effort)) current = index;
                    };
                    self.strip = .{ .entry_thinking = current };
                    return .redraw;
                },
                'c' => return .{ .toggle_cycle = role },
                'n' => return self.beginRoleName(.create, role),
                'r' => return if (role == .custom) self.beginRoleName(.rename, role) else .none,
                'd' => return if (role == .custom) .{ .delete_role = role } else .{ .clear_role = role },
                'T' => return self.beginRoleName(.tag, role),
                'b' => return self.editBank(role),
                '[', ']' => {
                    const later = byte == ']';
                    if (own_row and role_row.entries.len < 2) {
                        if (role_row.cycle_position == null) return .none;
                        return .{ .move_cycle = .{ .role = role, .later = later } };
                    }
                    // In a chain, [ and ] reorder the models; the first is the assignment.
                    if (!later and cursor.entry == 0) return .none;
                    if (later and cursor.entry + 1 >= role_row.entries.len) return .none;
                    self.selected = if (later) self.selected + 1 else self.selected - 1;
                    return .{ .edit_role = .{ .role = role, .edit = .{ .move = .{ .entry = cursor.entry, .later = later } } } };
                },
                else => return self.handleScope(alloc, key),
            },
            else => return .none,
        }
    }

    fn beginRoleName(self: *State, mode: @TypeOf(self.role_name_mode), role: RoleId) Effect {
        self.role_name_mode = mode;
        self.role_name_len = 0;
        if (mode == .rename) {
            const name = role.label();
            const len = @min(name.len, self.role_name_buf.len);
            @memcpy(self.role_name_buf[0..len], name[0..len]);
            self.role_name_len = len;
        }
        self.setNotice(switch (mode) {
            .create => "Type a role name, then Enter",
            .rename => "Rename role, then Enter",
            .tag => "Type a role tag, then Enter",
            .none => "",
        });
        return .redraw;
    }

    fn handleRoleName(self: *State, key: Key) Effect {
        switch (key) {
            .escape => {
                self.role_name_mode = .none;
                self.role_name_len = 0;
                return .redraw;
            },
            .backspace => {
                if (self.role_name_len > 0) self.role_name_len -= 1;
                return .redraw;
            },
            .enter => {
                const name = self.role_name_buf[0..self.role_name_len];
                const mode = self.role_name_mode;
                self.role_name_mode = .none;
                self.role_name_len = 0;
                if (name.len == 0) return .redraw;
                const cursor = self.roleCursor();
                return switch (mode) {
                    .create => .{ .create_role = .{ .name = name } },
                    .rename => if (cursor) |selected| .{ .rename_role = .{ .role = self.snapshot.?.roles[selected.role_index].role, .name = name } } else .redraw,
                    .tag => if (cursor) |selected| .{ .edit_tag = .{ .role = self.snapshot.?.roles[selected.role_index].role, .edit = .{ .tag = name } } } else .redraw,
                    .none => .redraw,
                };
            },
            .char => |byte| {
                if (byte >= 0x20 and byte != 0x7f and self.role_name_len < self.role_name_buf.len) {
                    self.role_name_buf[self.role_name_len] = byte;
                    self.role_name_len += 1;
                }
                return .redraw;
            },
            else => return .redraw,
        }
    }

    fn editBank(self: *State, role: RoleId) Effect {
        const row = self.snapshot.?.roleRow(role) orelse return .none;
        self.bank_len = 0;
        for (row.entries) |entry| {
            if (self.bank_len == self.bank_buf.len) break;
            self.bank_buf[self.bank_len] = entry.ref;
            self.bank_len += 1;
        }
        return .{ .edit_bank = .{ .role = role, .selectors = self.bank_buf[0..self.bank_len] } };
    }

    fn startAssign(self: *State, alloc: Allocator, role: RoleId, entry: ?usize) !Effect {
        self.assigning = .{ .role = role, .entry = entry };
        self.query_len = 0;
        try self.setScope(alloc, .{ .kind = .all_models });
        self.focus = .list;
        return .redraw;
    }

    /// x on a role clears it; on a fallback, removes that model.
    fn removeEntry(self: *State, role: RoleId, own_row: bool, entry: usize) Effect {
        if (own_row) return .{ .clear_role = role };
        self.selected -|= 1;
        return .{ .edit_role = .{ .role = role, .edit = .{ .remove = entry } } };
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

    fn visibleRole(self: *const State, visible_index: usize) ?RoleId {
        const snapshot = self.snapshot orelse return null;
        var index: usize = 0;
        for (snapshot.roles) |role_row| {
            if (role_row.hidden) continue;
            if (index == visible_index) return role_row.role;
            index += 1;
        }
        return null;
    }

    /// The chips of the open strip, as roles or efforts.
    pub fn stripCount(self: *const State) usize {
        return switch (self.strip) {
            .none => 0,
            .role_scope => 2,
            .roles => blk: {
                const snapshot = self.snapshot orelse break :blk 0;
                var count: usize = 0;
                for (snapshot.roles) |role_row| count += @intFromBool(!role_row.hidden);
                break :blk count;
            },
            .thinking => if (self.selectedModel()) |model| self.snapshot.?.models[model].efforts.len + 1 else 1,
            .entry_thinking => if (self.selectedEntry()) |entry| entry.efforts.len + 1 else 1,
            .sign_out => 2,
        };
    }

    /// The effort chip at `index`: 0 is `auto`.
    pub fn stripEffort(self: *const State, index: usize) types.ReasoningEffort {
        if (index == 0) return .auto;
        if (self.strip == .entry_thinking) {
            const entry = self.selectedEntry() orelse return .auto;
            return if (index - 1 < entry.efforts.len) entry.efforts[index - 1] else .auto;
        }
        const model = self.selectedModel() orelse return .auto;
        const efforts = self.snapshot.?.models[model].efforts;
        return if (index - 1 < efforts.len) efforts[index - 1] else .auto;
    }

    fn handleStrip(self: *State, key: Key) Effect {
        const count = self.stripCount();
        const selected: *usize = switch (self.strip) {
            .role_scope => |*value| value,
            .roles => |*value| value,
            .thinking => |*value| value,
            .entry_thinking => |*value| value,
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
                if (self.strip == .role_scope) {
                    self.selected_role_scope = if (selected.* == 0) .workspace else .global;
                    self.strip = .{ .roles = 0 };
                    return .redraw;
                }
                if (self.strip == .entry_thinking) {
                    const index = selected.*;
                    const effort: ?types.ReasoningEffort = if (index == 0) null else self.stripEffort(index);
                    self.strip = .none;
                    const cursor = self.roleCursor() orelse return .redraw;
                    const role = self.snapshot.?.roles[cursor.role_index].role;
                    return .{ .edit_role = .{ .role = role, .edit = .{ .thinking = .{ .entry = cursor.entry, .effort = effort } } } };
                }
                const model = self.selectedModel() orelse {
                    self.strip = .none;
                    return .redraw;
                };
                const index = selected.*;
                const strip = self.strip;
                self.strip = .none;
                return switch (strip) {
                    .role_scope => .redraw,
                    .roles => blk: {
                        const role = self.visibleRole(index) orelse break :blk .redraw;
                        var holds = false;
                        for (self.snapshot.?.models[model].roles) |candidate| {
                            if (candidate.eql(role)) holds = true;
                        }
                        break :blk if (holds) .{ .clear_role = role } else .{ .edit_role = .{ .role = role, .scope = self.selected_role_scope, .edit = .{ .put = .{ .entry = 0, .model = model } } } };
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

test "mouse rows map to rendered content rows" {
    try std.testing.expectEqual(@as(?u16, null), State.contentRow(2));
    try std.testing.expectEqual(@as(?u16, 0), State.contentRow(3));
    try std.testing.expectEqual(@as(?u16, 4), State.contentRow(7));
}

test {
    _ = catalog;
    _ = edits;
    _ = @import("hub_tests.zig");
}

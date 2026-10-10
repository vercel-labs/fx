//! What the `/usage` dashboard shows and which row is selected. UI state
//! only: the views come from the usage module, which decides what they say.

const std = @import("std");
const usage_mod = @import("usage");

const Allocator = std.mem.Allocator;
const View = usage_mod.View;
const Scope = usage_mod.Scope;

pub const State = struct {
    active: bool = false,
    /// The tab being shown or loaded.
    requested_scope: Scope = .session,
    /// A rolling view, borrowed from the profile's view loader. It stays
    /// valid until the loader's next poll after a newer one is ready.
    borrowed: ?*const View = null,
    /// The session view, owned.
    owned: ?View = null,
    refresh_failed: bool = false,
    selection: usage_mod.render.Selection = .{},

    pub fn view(self: *const State) ?*const View {
        if (self.owned) |*value| return value;
        return self.borrowed;
    }

    /// Opens on `scope` with nothing to show yet.
    pub fn openLoading(self: *State, alloc: Allocator, scope_value: Scope) void {
        self.close(alloc);
        self.* = .{ .active = true, .requested_scope = scope_value };
    }

    /// Opens on `scope` showing that its data is unavailable.
    pub fn openError(self: *State, alloc: Allocator, scope_value: Scope) void {
        self.close(alloc);
        self.* = .{ .active = true, .requested_scope = scope_value, .refresh_failed = true };
    }

    /// Opens on a view: `owned` for the session, otherwise borrowed.
    pub fn open(self: *State, alloc: Allocator, shown: Shown) void {
        self.close(alloc);
        self.active = true;
        self.install(shown);
    }

    /// Switches to `scope` and waits for its data.
    pub fn setLoadingScope(self: *State, alloc: Allocator, scope_value: Scope) void {
        self.dropView(alloc);
        self.refresh_failed = false;
        self.requested_scope = scope_value;
        self.selection = .{};
    }

    /// Replaces the view, keeping the selected and expanded models by name.
    pub fn replace(self: *State, alloc: Allocator, shown: Shown) void {
        const next: *const View = switch (shown) {
            .owned => |*value| value,
            .borrowed => |value| value,
        };
        self.selection = self.selection.retain(self.view(), next);
        self.dropView(alloc);
        self.install(shown);
    }

    pub fn recordRefreshFailure(self: *State, attempted_scope: Scope) void {
        self.refresh_failed = true;
        self.requested_scope = attempted_scope;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.dropView(alloc);
        self.* = .{};
    }

    pub fn moveModel(self: *State, delta: i32, visible_model_rows: usize) bool {
        if (!self.active) return false;
        const shown = self.view() orelse return false;
        return self.selection.move(delta, shown.models.len, visible_model_rows);
    }

    pub fn toggleExpanded(self: *State, visible_model_rows: usize) bool {
        if (!self.active) return false;
        const shown = self.view() orelse return false;
        return self.selection.toggleExpanded(shown.models.len, visible_model_rows);
    }

    pub fn navigationScope(self: *const State) Scope {
        return self.requested_scope;
    }

    /// What the renderer draws.
    pub fn dashboard(self: *const State) usage_mod.render.Dashboard {
        const shown = self.view();
        return .{
            .scope = if (shown) |value| value.scope else self.requested_scope,
            .view = shown,
            .refresh_failed = self.refresh_failed,
            .selected_model = self.selection.selected_model,
            .expanded_model = self.selection.expanded_model,
            .model_window_start = self.selection.model_window_start,
        };
    }

    pub const Shown = union(enum) {
        owned: View,
        borrowed: *const View,
    };

    fn install(self: *State, shown: Shown) void {
        switch (shown) {
            .owned => |value| {
                self.owned = value;
                self.borrowed = null;
                self.requested_scope = value.scope;
            },
            .borrowed => |value| {
                self.owned = null;
                self.borrowed = value;
                self.requested_scope = value.scope;
            },
        }
        self.refresh_failed = false;
    }

    fn dropView(self: *State, alloc: Allocator) void {
        if (self.owned) |*value| value.deinit(alloc);
        self.owned = null;
        self.borrowed = null;
    }
};

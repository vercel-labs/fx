//! The app's model roles (D170): the profile's table, what each role
//! resolves to on the active provider, `/role`, and role cycling.
//!
//! Side calls, turns and fleet workers borrow the model bytes a role
//! resolves to for as long as they run. A change replaces the whole table
//! and keeps the old one until the app exits, so no borrow dangles (D173).
//! The worker thread resolves roles for turns and compaction while the UI
//! thread may assign one, so the table pointer swaps under `mutex`.

const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const provider_runtime = @import("provider_runtime.zig");
const session_backend = @import("session_backend.zig");
const session_commands = @import("../session/session_commands.zig");

const Allocator = std.mem.Allocator;
const Role = model_roles.Role;
const model_provider = @import("../config/model_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");

/// The next role in `cycle_order` whose model differs from the session's.
pub const Step = struct { role: Role, model: []const u8 };

fn cycleStep(view: Host, backward: bool) ?Step {
    const order = view.state.table.cycleOrder();
    if (order.len == 0) return null;
    var start: usize = if (backward) 0 else order.len - 1;
    for (order, 0..) |role, index| {
        const model = view.resolve(role) orelse continue;
        if (std.mem.eql(u8, model, view.current_model)) {
            start = index;
            break;
        }
    }
    var offset: usize = 1;
    while (offset <= order.len) : (offset += 1) {
        const index = if (backward) (start + order.len * 2 - offset) % order.len else (start + offset) % order.len;
        const model = view.resolve(order[index]) orelse continue;
        if (std.mem.eql(u8, model, view.current_model)) continue;
        return .{ .role = order[index], .model = model };
    }
    return null;
}

pub const State = struct {
    table: model_roles.Table = .{},
    /// The profile's default model and the provider it belongs to; owned.
    default_provider: []u8 = &.{},
    default_model: []u8 = &.{},
    /// Tables replaced while the app ran. Their bytes may still be borrowed.
    retired: std.ArrayList(model_roles.Table) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.table.deinit(alloc);
        for (self.retired.items) |*table| table.deinit(alloc);
        self.retired.deinit(alloc);
        if (self.default_provider.len > 0) alloc.free(self.default_provider);
        if (self.default_model.len > 0) alloc.free(self.default_model);
        self.* = .{};
    }

    /// Takes ownership of `table`; records the startup default model.
    pub fn init(self: *State, alloc: Allocator, table: model_roles.Table, provider: []const u8, default_model: []const u8) !void {
        self.deinit(alloc);
        self.table = table;
        self.default_provider = try alloc.dupe(u8, provider);
        self.default_model = try alloc.dupe(u8, default_model);
    }

    /// Replaces the whole table with one reread from the profile, keeping
    /// the old one for borrowers. Takes ownership of `table`.
    pub fn reload(self: *State, alloc: Allocator, table: model_roles.Table) !void {
        var owned = table;
        errdefer owned.deinit(alloc);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = owned;
    }

    /// Replaces `role`'s entry; null clears it.
    pub fn assign(self: *State, alloc: Allocator, role: Role, value: ?[]const u8) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.set(alloc, role, value);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }
};

/// What role resolution needs from its host: the TUI app, `fx ask`, or
/// the ACP server that runs a daemon's sessions.
pub const Host = struct {
    state: *State,
    provider: model_provider.ProviderId,
    /// The session's model; `@default` when the profile has none here.
    current_model: []const u8,
    set: provider_set.Set,
    /// The legacy `review_model` setting or FX_REVIEW_MODEL; empty for none.
    review_model: []const u8 = "",

    /// Resolves `role` on the host's provider. The model borrows the role
    /// table, the profile default, the host's model or a bundle string.
    pub fn resolve(self: Host, role: Role) ?[]const u8 {
        var provider = self.provider;
        const label = provider.label();
        self.state.mutex.lockUncancelable(io_mod.getIo());
        defer self.state.mutex.unlock(io_mod.getIo());
        const default_model = if (self.state.default_model.len > 0 and std.mem.eql(u8, self.state.default_provider, label))
            self.state.default_model
        else
            self.current_model;
        const ref = model_roles.resolve(&self.state.table, role, .{
            .provider = label,
            .default_model = default_model,
            .builtin_smol = self.set.select(provider).title_model,
            // `review_model` was a gateway setting; other providers ignored it.
            .legacy_review = if (self.review_model.len > 0 and provider == .gateway) self.review_model else null,
            .configured = self.set.definitions,
        }) orelse return null;
        const model = ref.on(label);
        if (model == null) debug_trace.logf("config", "model role={s} names provider={s} active={s}; using the consumer default", .{ role.label(), ref.provider.?, label });
        return model;
    }

    /// The model for session titles: the title role, the provider's own
    /// low-cost model, then, as proto does, the session's model (D206).
    /// Null disables generated titles.
    pub fn titleModel(self: Host) ?[]const u8 {
        if (self.resolve(.title) orelse self.set.select(self.provider).title_model) |model| return model;
        if (self.current_model.len == 0 or self.current_model[0] == '@') return null;
        return self.current_model;
    }

    /// The permission reviewer's model; empty keeps the reviewer's default.
    pub fn reviewModel(self: Host) []const u8 {
        // FX_REVIEW_MODEL, a gateway override, outranks the profile's role.
        if (self.provider == .gateway and self.review_model.len > 0 and io_mod.getenv("FX_REVIEW_MODEL") != null) return self.review_model;
        return self.resolve(.review) orelse "";
    }

    /// The compactor's summary model; empty keeps the conversation's model.
    pub fn compactModel(self: Host) []const u8 {
        return self.resolve(.compact) orelse "";
    }

    /// Resolves a fleet worker's `@role` model request.
    pub fn lookup(self: Host, name: []const u8) Lookup {
        const role = Role.parse(name) orelse return .unknown_role;
        return if (self.resolve(role)) |model| .{ .model = model } else .unavailable;
    }

    /// Roles that pick `model`, for the `/model` tags.
    pub fn rolesFor(self: Host, model: []const u8, out: *[model_roles.role_count]Role) usize {
        var count: usize = 0;
        for (model_roles.all_roles) |role| {
            if (role != .default and self.state.table.get(role) == null) continue;
            const picked = self.resolve(role) orelse continue;
            if (!std.mem.eql(u8, picked, model)) continue;
            out[count] = role;
            count += 1;
        }
        return count;
    }
};

pub const Lookup = union(enum) {
    model: []const u8,
    unknown_role,
    /// The role resolves to nothing, or to another provider.
    unavailable,
};

/// The app's host view. In a detached frontend the session's model comes
/// from the backend.
pub fn host(app: anytype) Host {
    const App = @TypeOf(app.*);
    const view_model = if (comptime @hasDecl(App, "backend") or @hasField(App, "backend"))
        session_backend.Ops(App).view(app).model
    else
        null;
    return .{
        .state = @constCast(&app.model_roles),
        .provider = provider_runtime.provider(app),
        .current_model = view_model orelse provider_runtime.model(app),
        .set = app.providerSet(),
        .review_model = app.review_model,
    };
}

pub fn resolveModel(app: anytype, role: Role) ?[]const u8 {
    return host(app).resolve(role);
}

pub fn titleModel(app: anytype) ?[]const u8 {
    return host(app).titleModel();
}

pub fn reviewModel(app: anytype) []const u8 {
    return host(app).reviewModel();
}

pub fn compactModel(app: anytype) []const u8 {
    return host(app).compactModel();
}

pub fn lookup(app: anytype, name: []const u8) Lookup {
    return host(app).lookup(name);
}

pub fn rolesFor(app: anytype, model: []const u8, out: *[model_roles.role_count]Role) usize {
    return host(app).rolesFor(model, out);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const usage = "usage: /role [next|prev|<role> [model|@role|clear]]";

        /// `/role`: lists roles, assigns one, or cycles.
        pub fn handle(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            var words = std.mem.tokenizeAny(u8, trimmed, " \t");
            const first = words.next() orelse return writeTable(app);
            if (std.mem.eql(u8, first, "next")) return cycle(app, false);
            if (std.mem.eql(u8, first, "prev")) return cycle(app, true);
            const role = Role.parse(first) orelse {
                return app.writeDomainNotice(.{ .topic = "role", .tone = .@"error", .body = usage }, true);
            };
            const value_text = std.mem.trim(u8, trimmed[first.len..], " \t");
            if (value_text.len == 0) return assign(app, role, provider_runtime.model(app));
            if (std.mem.eql(u8, value_text, "clear")) return assign(app, role, null);
            return assign(app, role, value_text);
        }

        /// Saves `role` in the profile and applies it.
        pub fn assign(app: *App, role: Role, value: ?[]const u8) !void {
            if (value) |text| model_roles.validateRef(text) catch {
                return app.writeDomainNotice(.{ .topic = "role", .tone = .@"error", .body = "That is not a model reference." }, true);
            };
            const owned = if (value) |text| try app.alloc.dupe(u8, text) else null;
            defer if (owned) |bytes| app.alloc.free(bytes);
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role = .{ .role = role, .value = owned } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            try app.model_roles.assign(app.alloc, role, owned);
            const body = if (owned) |text|
                try app.alloc.print("{s} → {s}", .{ role.label(), text })
            else
                try app.alloc.print("{s} cleared", .{role.label()});
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = body }, true);
        }

        /// Switches the session to the next role's model in `cycle_order`.
        pub fn cycle(app: *App, backward: bool) !void {
            const view = host(app);
            const step = cycleStep(view, backward) orelse {
                return app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = "No other role has a model on this provider. Assign one with /role <role> <model>." }, true);
            };
            const model = try app.alloc.dupe(u8, step.model);
            defer app.alloc.free(model);
            try session_backend.Ops(App).selectModel(app, .{
                .model = model,
                .effort = app.effort,
                .fast_mode = app.fast_mode,
                .ultrafast_mode = app.worker.agent_turn_settings.ultrafast_mode,
            });
            const body = try app.alloc.print("{s} · {s}", .{ step.role.label(), model });
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = body }, true);
        }

        fn writeTable(app: *App) !void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            const table = &app.model_roles.table;
            for (model_roles.all_roles, 0..) |role, index| {
                if (index > 0) try out.writer.writeByte('\n');
                const model = resolveModel(app, role) orelse {
                    try out.writer.print("{s:<9} not set", .{role.label()});
                    continue;
                };
                try out.writer.print("{s:<9} {s}", .{ role.label(), model });
                if (table.get(role)) |raw| {
                    if (!std.mem.eql(u8, raw, model)) try out.writer.print("  {s}", .{raw});
                } else switch (role) {
                    .default => {},
                    .title, .tiny => try out.writer.writeAll("  follows smol"),
                    else => try out.writer.writeAll("  built in"),
                }
            }
            try out.writer.writeAll("\ncycle     ");
            for (table.cycleOrder(), 0..) |role, index| {
                if (index > 0) try out.writer.writeAll(" → ");
                try out.writer.writeAll(role.label());
            }
            try app.writeDomainNotice(.{ .topic = "roles", .tone = .neutral, .body = out.written() }, true);
        }
    };
}

test "state assignment keeps replaced tables alive" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    try state.assign(alloc, .smol, "fast");
    const borrowed = state.table.get(.smol).?;
    try state.assign(alloc, .smol, "faster");
    // The first assignment's bytes stay valid for borrowers.
    try std.testing.expectEqualStrings("fast", borrowed);
    try std.testing.expectEqualStrings("faster", state.table.get(.smol).?);
    try state.assign(alloc, .smol, null);
    try std.testing.expect(state.table.get(.smol) == null);
}

test "cycling steps through roles with distinct models and tags list roles" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    try state.assign(alloc, .smol, "fast");
    try state.assign(alloc, .slow, "deep");
    try state.assign(alloc, .worker, "@smol");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    // Default order: slow, default, smol.
    try std.testing.expectEqualStrings("fast", cycleStep(view, false).?.model);
    view.current_model = "fast";
    try std.testing.expectEqualStrings("deep", cycleStep(view, false).?.model);
    view.current_model = "deep";
    try std.testing.expectEqualStrings("main", cycleStep(view, false).?.model);
    view.current_model = "main";
    try std.testing.expectEqualStrings("deep", cycleStep(view, true).?.model);
    // A model outside the order starts from the first role.
    view.current_model = "other";
    try std.testing.expectEqual(Role.slow, cycleStep(view, false).?.role);

    var roles: [model_roles.role_count]Role = undefined;
    const count = view.rolesFor("fast", &roles);
    try std.testing.expectEqualSlices(Role, &.{ .smol, .worker }, roles[0..count]);
    try std.testing.expectEqual(@as(usize, 1), view.rolesFor("main", &roles));
    try std.testing.expectEqualStrings("fast", view.lookup("worker").model);
    try std.testing.expect(view.lookup("nobody") == .unknown_role);
    try std.testing.expect(view.lookup("compact") == .unavailable);

    var lone: State = .{};
    defer lone.deinit(alloc);
    try lone.init(alloc, .{}, "gateway", "main");
    view.state = &lone;
    view.current_model = "main";
    try std.testing.expect(cycleStep(view, false) == null);
}

test "review falls back to the legacy gateway setting and titles to the bundle" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{ .title_model = "luna" }, .codex = .{}, .grok = .{} }, .review_model = "legacy" };
    try std.testing.expectEqualStrings("legacy", view.reviewModel());
    try std.testing.expectEqualStrings("luna", view.titleModel().?);
    try std.testing.expectEqualStrings("", view.compactModel());
    view.provider = .codex;
    try std.testing.expectEqualStrings("", view.reviewModel());
    try state.assign(alloc, .review, "codex/strict");
    try std.testing.expectEqualStrings("strict", view.reviewModel());
    try state.assign(alloc, .compact, "@smol");
    try state.assign(alloc, .smol, "codex-mini");
    try std.testing.expectEqualStrings("codex-mini", view.compactModel());
    try std.testing.expectEqualStrings("codex-mini", view.titleModel().?);
}

test "a provider without a low-cost model titles with the session's model" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "codex", "main");
    var view: Host = .{ .state = &state, .provider = .codex, .current_model = "gpt-main", .set = .{ .gateway = .{ .title_model = "luna" }, .codex = .{}, .grok = .{} } };
    try std.testing.expectEqualStrings("gpt-main", view.titleModel().?);
    view.current_model = "@default";
    try std.testing.expect(view.titleModel() == null);
}

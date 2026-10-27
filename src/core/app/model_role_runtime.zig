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

const types = @import("../shared/types.zig");

/// The next role in `cycle_order` whose model or thinking level differs
/// from the session's, with the thinking level the role names (D251).
/// As proto does, the cycle continues from the role it last picked while
/// that role still names the session's model. A role without a level is
/// effort-blind, except the default role, which returns to the startup
/// level, so a deep role on the default model still cycles back (D265).
pub const Step = struct { role: Role, model: []const u8, effort: ?types.ReasoningEffort = null };

fn roleEffort(view: Host, role: Role, picked: Picked) ?types.ReasoningEffort {
    if (picked.effort) |effort| return effort;
    return if (role == .default) view.state.default_effort else null;
}

/// Unknown levels on either side compare equal.
fn sameEffort(a: ?types.ReasoningEffort, b: ?types.ReasoningEffort) bool {
    const left = a orelse return true;
    const right = b orelse return true;
    return std.mem.eql(u8, left.label(), right.label());
}

fn cycleStep(view: Host, backward: bool) ?Step {
    const order = view.state.table.cycleOrder();
    if (order.len == 0) return null;
    var start: usize = if (backward) 0 else order.len - 1;
    var current_effort = view.current_effort;
    const last: ?usize = if (view.state.last_cycled) |role| std.mem.findScalar(Role, order, role) else null;
    const resumed = if (last) |index| if (view.pick(order[index])) |picked| std.mem.eql(u8, picked.model, view.current_model) else false else false;
    if (resumed) {
        start = last.?;
        current_effort = roleEffort(view, order[start], view.pick(order[start]).?);
    } else for (order, 0..) |role, index| {
        const picked = view.pick(role) orelse continue;
        if (std.mem.eql(u8, picked.model, view.current_model) and sameEffort(roleEffort(view, role, picked), current_effort)) {
            start = index;
            break;
        }
    }
    var offset: usize = 1;
    while (offset <= order.len) : (offset += 1) {
        const index = if (backward) (start + order.len * 2 - offset) % order.len else (start + offset) % order.len;
        const picked = view.pick(order[index]) orelse continue;
        const effort = roleEffort(view, order[index], picked);
        if (std.mem.eql(u8, picked.model, view.current_model) and sameEffort(effort, current_effort)) continue;
        return .{ .role = order[index], .model = picked.model, .effort = effort };
    }
    return null;
}

pub const State = struct {
    table: model_roles.Table = .{},
    /// The profile's default model and the provider it belongs to; owned.
    default_provider: []u8 = &.{},
    default_model: []u8 = &.{},
    /// The session's startup thinking level, which the default role
    /// returns to when cycling (D265).
    default_effort: ?types.ReasoningEffort = null,
    /// The role Alt+P or `/role next` last switched to.
    last_cycled: ?Role = null,
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

    /// Replaces `cycle_order` (D222).
    pub fn setCycle(self: *State, alloc: Allocator, order: []const Role) !void {
        if (order.len > model_roles.role_count) return error.InvalidCycleOrderValue;
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        @memcpy(next.cycle[0..order.len], order);
        next.cycle_len = order.len;
        next.has_cycle = true;
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
    /// The session's thinking level; null matches roles on model alone.
    current_effort: ?types.ReasoningEffort = null,
    set: provider_set.Set,
    /// The legacy `review_model` setting or FX_REVIEW_MODEL; empty for none.
    review_model: []const u8 = "",
    /// The active provider's catalog, which a fallback chain checks (D250).
    known: ?model_roles.Known = null,

    /// Resolves `role` on the host's provider. The model borrows the role
    /// table, the profile default, the host's model or a bundle string.
    pub fn resolve(self: Host, role: Role) ?[]const u8 {
        return if (self.pick(role)) |picked| picked.model else null;
    }

    /// `resolve` with the thinking level the role's entry names.
    pub fn pick(self: Host, role: Role) ?Picked {
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
            .builtin_small = self.set.select(provider).title_model,
            // `review_model` was a gateway setting; other providers ignored it.
            .legacy_review = if (self.review_model.len > 0 and provider == .gateway) self.review_model else null,
            .configured = self.set.definitions,
            .known = self.known,
        }) orelse return null;
        const model = ref.on(label) orelse {
            debug_trace.logf("config", "model role={s} names provider={s} active={s}; using the consumer default", .{ role.label(), ref.provider.?, label });
            return null;
        };
        return .{ .model = model, .effort = ref.effort };
    }

    /// The model for session titles: the title role, the provider's own
    /// low-cost model, then, as proto does, the session's model (D206).
    /// Null disables generated titles.
    pub fn titleModel(self: Host) ?[]const u8 {
        if (self.resolve(.title) orelse self.set.select(self.provider).title_model) |model| return model;
        if (self.current_model.len == 0 or self.current_model[0] == '@') return null;
        return self.current_model;
    }

    /// The web search side worker's model: the profile's small role when
    /// it sets one on this provider, else the session's model, as before
    /// roles (D213).
    pub fn searchWorkerModel(self: Host) []const u8 {
        const configured = blk: {
            self.state.mutex.lockUncancelable(io_mod.getIo());
            defer self.state.mutex.unlock(io_mod.getIo());
            break :blk self.state.table.get(.small) != null;
        };
        if (!configured) return self.current_model;
        return self.resolve(.small) orelse self.current_model;
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

    /// A stream rule judge's model: the first of `roles` (proto's `tiny`,
    /// `small` by default) that resolves on this provider (D207). Null leaves
    /// the session's model to answer.
    pub fn judgeModel(self: Host, roles: []const []const u8) ?[]const u8 {
        for (roles) |name| {
            const role = Role.parse(name) orelse continue;
            if (self.resolve(role)) |model| return model;
        }
        return null;
    }

    /// Resolves a fleet worker's `@role` model request.
    pub fn lookup(self: Host, name: []const u8) Lookup {
        const role = Role.parse(name) orelse return .unknown_role;
        return if (self.pick(role)) |picked| .{ .model = picked } else .unavailable;
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

pub const Picked = model_roles.Picked;

pub const Lookup = union(enum) {
    model: Picked,
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
        // A detached frontend does not track the backend's level.
        .current_effort = if (comptime @hasField(App, "effort")) if (view_model == null) app.effort else null else null,
        .set = app.providerSet(),
        .review_model = app.review_model,
        .known = if (comptime @hasField(App, "model_cache")) .{ .context = @ptrCast(@constCast(&app.model_cache)), .known_fn = knownInCache(@TypeOf(app.model_cache)) } else null,
    };
}

fn knownInCache(comptime Cache: type) *const fn (?*anyopaque, []const u8) bool {
    return struct {
        fn known(raw: ?*anyopaque, model: []const u8) bool {
            const cache: *Cache = @ptrCast(@alignCast(raw.?));
            return cache.knowsModel(model);
        }
    }.known;
}

pub fn resolveModel(app: anytype, role: Role) ?[]const u8 {
    return host(app).resolve(role);
}

pub fn titleModel(app: anytype) ?[]const u8 {
    return host(app).titleModel();
}

pub fn searchWorkerModel(app: anytype) []const u8 {
    return host(app).searchWorkerModel();
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
        const usage = "usage: /role [next|prev|<role> [model[:level], fallback…|@role|clear]]";

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

        /// Saves `role` in the profile and applies it, without a notice.
        /// False when the reference was refused or the save failed; the
        /// notice saying why is written.
        pub fn save(app: *App, role: Role, value: ?[]const u8) !bool {
            if (value) |text| model_roles.validateChain(text) catch {
                try app.writeDomainNotice(.{ .topic = "role", .tone = .@"error", .body = "That is not a model reference." }, true);
                return false;
            };
            const owned = if (value) |text| try app.alloc.dupe(u8, text) else null;
            defer if (owned) |bytes| app.alloc.free(bytes);
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role = .{ .role = role, .value = owned } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| {
                    try session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false);
                    return false;
                },
                .outcome => {},
            }
            try app.model_roles.assign(app.alloc, role, owned);
            return true;
        }

        /// Saves `role` in the profile and applies it.
        pub fn assign(app: *App, role: Role, value: ?[]const u8) !void {
            if (!try save(app, role, value)) return;
            const owned = value;
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
                .effort = step.effort orelse app.effort,
                .fast_mode = app.fast_mode,
                .ultrafast_mode = app.worker.agent_turn_settings.ultrafast_mode,
            });
            app.model_roles.last_cycled = step.role;
            // A detached session takes the level as its own option.
            if (step.effort) |effort| if (comptime @hasField(App, "backend")) if (app.backend == .detached) {
                const command = try app.alloc.print("/effort {s}", .{effort.label()});
                defer app.alloc.free(command);
                if (comptime @hasDecl(App, "handleCommand")) try app.handleCommand(command);
            };
            const body = if (step.effort) |effort|
                try app.alloc.print("{s} · {s} · {s}", .{ step.role.label(), model, effort.label() })
            else
                try app.alloc.print("{s} · {s}", .{ step.role.label(), model });
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
                    .title, .tiny => try out.writer.writeAll("  follows small"),
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
    try state.assign(alloc, .small, "fast");
    const borrowed = state.table.get(.small).?;
    try state.assign(alloc, .small, "faster");
    // The first assignment's bytes stay valid for borrowers.
    try std.testing.expectEqualStrings("fast", borrowed);
    try std.testing.expectEqualStrings("faster", state.table.get(.small).?);
    try state.assign(alloc, .small, null);
    try std.testing.expect(state.table.get(.small) == null);
}

test "cycling steps through roles with distinct models and tags list roles" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    try state.assign(alloc, .small, "fast");
    try state.assign(alloc, .deep, "careful");
    try state.assign(alloc, .worker, "@small");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    // Default order: deep, default, small.
    try std.testing.expectEqualStrings("fast", cycleStep(view, false).?.model);
    view.current_model = "fast";
    try std.testing.expectEqualStrings("careful", cycleStep(view, false).?.model);
    view.current_model = "careful";
    try std.testing.expectEqualStrings("main", cycleStep(view, false).?.model);
    view.current_model = "main";
    try std.testing.expectEqualStrings("careful", cycleStep(view, true).?.model);
    // A model outside the order starts from the first role.
    view.current_model = "other";
    try std.testing.expectEqual(Role.deep, cycleStep(view, false).?.role);

    var roles: [model_roles.role_count]Role = undefined;
    const count = view.rolesFor("fast", &roles);
    try std.testing.expectEqualSlices(Role, &.{ .small, .worker }, roles[0..count]);
    try std.testing.expectEqual(@as(usize, 1), view.rolesFor("main", &roles));
    try std.testing.expectEqualStrings("fast", view.lookup("worker").model.model);
    try std.testing.expect(view.lookup("nobody") == .unknown_role);
    try std.testing.expect(view.lookup("compact") == .unavailable);

    var lone: State = .{};
    defer lone.deinit(alloc);
    try lone.init(alloc, .{}, "gateway", "main");
    view.state = &lone;
    view.current_model = "main";
    try std.testing.expect(cycleStep(view, false) == null);
}

test "cycling reaches the default role when the deep role differs only in thinking level" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    state.default_effort = .auto;
    try state.assign(alloc, .small, "fast");
    try state.assign(alloc, .deep, "main:high");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .current_effort = .auto, .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    // Order: deep, default, small. The session starts on the default.
    var step = cycleStep(view, false).?;
    try std.testing.expectEqual(Role.small, step.role);
    state.last_cycled = step.role;
    view.current_model = "fast";
    view.current_effort = null;
    step = cycleStep(view, false).?;
    try std.testing.expectEqual(Role.deep, step.role);
    try std.testing.expectEqualStrings("high", step.effort.?.label());
    state.last_cycled = step.role;
    view.current_model = "main";
    view.current_effort = types.ReasoningEffort.literal("high");
    step = cycleStep(view, false).?;
    try std.testing.expectEqual(Role.default, step.role);
    try std.testing.expectEqualStrings("auto", step.effort.?.label());
    // A detached frontend knows no level; the last role still places it.
    view.current_effort = null;
    try std.testing.expectEqual(Role.default, cycleStep(view, false).?.role);
    try std.testing.expectEqual(Role.small, cycleStep(view, true).?.role);
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
    try state.assign(alloc, .compact, "@small");
    try state.assign(alloc, .small, "codex-mini");
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

test "a judge takes the first of its roles that resolves" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "codex", "main");
    const view: Host = .{ .state = &state, .provider = .codex, .current_model = "gpt-main", .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    // No role set and no low-cost model: the session's model answers.
    try std.testing.expect(view.judgeModel(&.{ "tiny", "small" }) == null);
    try state.assign(alloc, .small, "codex-mini");
    try std.testing.expectEqualStrings("codex-mini", view.judgeModel(&.{ "tiny", "small" }).?);
    try state.assign(alloc, .review, "codex-strict");
    try std.testing.expectEqualStrings("codex-strict", view.judgeModel(&.{ "nope", "review", "small" }).?);
}

test "the web search worker takes the profile's small role, else the session's model" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{ .title_model = "luna" }, .codex = .{}, .grok = .{} } };
    // Without a small entry the session's model stays, not the bundle's.
    try std.testing.expectEqualStrings("main", view.searchWorkerModel());
    try state.assign(alloc, .small, "swift");
    try std.testing.expectEqualStrings("swift", view.searchWorkerModel());
    // A small model on another provider leaves the session's model.
    try state.assign(alloc, .small, "codex/mini");
    try std.testing.expectEqualStrings("main", view.searchWorkerModel());
    view.provider = .codex;
    try std.testing.expectEqualStrings("mini", view.searchWorkerModel());
    try state.assign(alloc, .small, null);
    try std.testing.expectEqualStrings("main", view.searchWorkerModel());
}

const std = @import("std");
const agents = @import("../agents/agents.zig");
const session_codec = @import("../session/session_codec.zig");
const builtin = @import("builtin");
const model_provider = @import("../config/model_provider.zig");
const http_pool = @import("../shared/http_pool.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    active_provider: model_provider.ProviderId = .gateway,
    model: std.ArrayList(u8) = .empty,
    definitions: @import("../config/configured_provider.zig").Registry = .{},
    model_requests_blocked: bool = false,
    /// Process-long pooled HTTP client for gateway chat traffic. Heap-allocated
    /// so the pointer stays stable when this Runtime is copied by value; null
    /// when allocation failed (requests then dial per attempt, as before).
    gateway_http_pool: ?*http_pool.HttpPool = null,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    /// Creates the gateway pool once. Safe to call repeatedly. Allocation
    /// failure leaves the pool absent rather than failing the caller.
    pub fn ensureGatewayHttpPool(self: *Self) void {
        if (self.gateway_http_pool != null) return;
        const pool = self.alloc.create(http_pool.HttpPool) catch return;
        pool.* = http_pool.HttpPool.init(self.alloc);
        self.gateway_http_pool = pool;
    }

    pub fn deinit(self: *Self) void {
        if (self.gateway_http_pool) |pool| {
            if (pool.deinit() == .destroyed) self.alloc.destroy(pool);
        }
        self.model.deinit(self.alloc);
        self.definitions.deinit(self.alloc);
        self.* = undefined;
    }

    /// The returned model slice is borrowed until the next mutation or deinit.
    pub fn selection(self: *const Self) model_provider.ProviderSelection {
        return .{
            .provider = self.active_provider,
            .model = self.model.items,
        };
    }

    pub fn replaceModel(self: *Self, value: []const u8) !void {
        var owned = try self.alloc.dupe(u8, value);
        self.adoptOwned(self.active_provider, &owned);
    }

    pub fn replaceSelection(
        self: *Self,
        target_provider: model_provider.ProviderId,
        model_value: []const u8,
    ) !void {
        const bound = try target_provider.bind(self.definitions);
        var owned = try self.alloc.dupe(u8, model_value);
        self.adoptOwned(bound, &owned);
    }

    /// Transfers `owned_model` into the runtime. All fallible preparation must
    /// finish before this no-fail publication boundary.
    pub fn adoptOwned(
        self: *Self,
        target_provider: model_provider.ProviderId,
        owned_model: *[]u8,
    ) void {
        self.model.deinit(self.alloc);
        self.model = .fromOwnedSlice(owned_model.*);
        owned_model.* = &.{};
        self.active_provider = target_provider;
    }
};

pub fn supported(comptime App: type) bool {
    return @hasField(App, "provider_selection") or
        (builtin.is_test and @hasField(App, "selected_model"));
}

/// The model of the agent on screen, for main-loop screen code (D43).
pub fn model(app: anytype) []const u8 {
    return modelOf(app, screenAgentIfTracked(app));
}

/// `agent`'s model: a subagent's own choice (D31), else the app's selection.
pub fn modelOf(app: anytype, agent: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (subagentPreferences(app, agent)) |preferences| return preferences.model;
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().model;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return app.selected_model.items;
    }
    @compileError("app must own provider_selection");
}

/// Whether `App` runs subagents whose model choice is their own (D31).
fn tracksSubagentPreferences(comptime App: type) bool {
    if (!@hasField(App, "main_agent") or !@hasField(App, "screen_owner")) return false;
    const Agent = @FieldType(App, "main_agent");
    if (!@hasField(Agent, "session_persistence")) return false;
    return @hasField(@FieldType(Agent, "session_persistence"), "session_preferences");
}

/// The agent on screen when `app` runs subagents with their own model
/// choices, else nothing to ask about.
fn screenAgentIfTracked(app: anytype) if (tracksSubagentPreferences(@TypeOf(app.*))) @TypeOf(&app.main_agent) else void {
    if (comptime !tracksSubagentPreferences(@TypeOf(app.*))) return {};
    return agents.screenAgentOf(app);
}

/// A subagent's own model choice, kept in its own session's preferences
/// (D31): set when `agent` is a subagent with its session attached. Main's
/// is the app's selection.
fn subagentPreferences(app: anytype, agent: anytype) ?*const session_codec.DurableSessionPreferences {
    if (comptime !tracksSubagentPreferences(@TypeOf(app.*))) return null;
    if (agent == &app.main_agent) return null;
    if (agent.session_persistence.session_preferences) |*preferences| return preferences;
    return null;
}

fn subagentPreferencesMut(app: anytype, agent: anytype) ?*session_codec.DurableSessionPreferences {
    if (comptime !tracksSubagentPreferences(@TypeOf(app.*))) return null;
    if (agent == &app.main_agent) return null;
    if (agent.session_persistence.session_preferences) |*preferences| return preferences;
    return null;
}

/// The provider of the agent on screen, for main-loop screen code (D43).
pub fn provider(app: anytype) model_provider.ProviderId {
    return providerOf(app, screenAgentIfTracked(app));
}

/// `agent`'s provider: a subagent's own choice (D31), else the app's.
pub fn providerOf(app: anytype, agent: anytype) model_provider.ProviderId {
    const App = @TypeOf(app.*);
    if (subagentPreferences(app, agent)) |preferences| return preferences.provider;
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_provider")) {
        return app.selected_provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return .gateway;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceModel(app: anytype, value: []const u8) !void {
    const App = @TypeOf(app.*);
    if (subagentPreferencesMut(app, screenAgentIfTracked(app))) |preferences| {
        const owned = try app.alloc.dupe(u8, value);
        app.alloc.free(preferences.model);
        preferences.model = owned;
        return;
    }
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceModel(value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        const stable = try app.alloc.dupe(u8, value);
        defer app.alloc.free(stable);
        try app.selected_model.ensureTotalCapacity(app.alloc, stable.len);
        app.selected_model.clearRetainingCapacity();
        app.selected_model.appendSliceAssumeCapacity(stable);
        return;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceSelection(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    value: []const u8,
) !void {
    const App = @TypeOf(app.*);
    if (subagentPreferencesMut(app, screenAgentIfTracked(app))) |preferences| {
        try replaceModel(app, value);
        preferences.provider = selected_provider;
        return;
    }
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceSelection(selected_provider, value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        return replaceModel(app, value);
    }
    @compileError("app must own provider_selection");
}

test "provider runtime adopts an owned selection without a fallible publication" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    var gateway_model = try alloc.dupe(u8, "gateway/model");
    runtime.adoptOwned(.gateway, &gateway_model);
    try std.testing.expectEqual(@as(usize, 0), gateway_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, runtime.selection().provider);
    try std.testing.expectEqualStrings("gateway/model", runtime.selection().model);

    var codex_model = try alloc.dupe(u8, "gpt-model");
    runtime.adoptOwned(.codex, &codex_model);
    try std.testing.expectEqual(@as(usize, 0), codex_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.codex, runtime.selection().provider);
    try std.testing.expectEqualStrings("gpt-model", runtime.selection().model);
}

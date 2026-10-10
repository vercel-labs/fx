//! Combines the active catalog with models from other authenticated routes.
//! Qualified IDs keep a model's credential authority attached to its selection.
const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const configured_provider = @import("../config/configured_provider.zig");
const credentials = @import("../auth/credentials.zig");
const host = @import("../hosts/host.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const provider_set = @import("../gateway/provider_set.zig");

pub fn qualifiedSelection(id: []const u8, definitions: configured_provider.Registry) ?model_provider.ProviderSelection {
    const colon = std.mem.findScalar(u8, id, ':') orelse return null;
    if (colon + 1 == id.len) return null;
    const route = (model_provider.parse(id[0..colon]) orelse return null).bind(definitions) catch return null;
    return .{
        .provider = route,
        .model = id[colon + 1 ..],
    };
}

/// All borrowed capabilities must outlive the catalog worker. Only replace this
/// input after the previous cache worker has joined.
pub const Input = struct {
    providers: provider_set.Set,
    active: model_provider.ProviderId,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    workspace_root: []const u8,

    pub fn provider(self: *Input) model_catalog.Provider {
        const active = self.providers.select(self.active).model_catalog.?;
        return .{
            .context = self,
            .fetch_fn = fetch,
            .provider_id = self.active,
            .refresh_interval_ms = active.refresh_interval_ms,
        };
    }

    fn fetch(raw: ?*anyopaque, alloc: std.mem.Allocator, input: model_catalog.FetchInput) std.mem.Allocator.Error!model_catalog.ProviderResult {
        const self: *Input = @ptrCast(@alignCast(raw.?));
        // Keep the active route's fallback and failure semantics intact.
        const active = try self.providers.select(self.active).model_catalog.?.fetch(alloc, input);
        var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = switch (active) {
            .catalog => |catalog| catalog,
            .failure => |failure| return .{ .failure = failure },
        };
        errdefer model_catalog.freeModelCatalog(alloc, &catalog);
        for ([_]model_provider.ProviderId{ .gateway, .codex, .grok }) |route| {
            if (route.eql(self.active)) continue;
            try self.appendRoute(alloc, input, route, &catalog);
        }
        for (self.providers.definitions) |definition| {
            const route = model_provider.parse(definition.id).?.bind(.{ .definitions = self.providers.definitions }) catch continue;
            if (route.eql(self.active)) continue;
            try self.appendRoute(alloc, input, route, &catalog);
        }
        return .{ .catalog = catalog };
    }

    fn appendRoute(self: *Input, alloc: std.mem.Allocator, input: model_catalog.FetchInput, route: model_provider.ProviderId, catalog: *std.ArrayList(model_catalog.ModelCatalogEntry)) !void {
        if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return;
        const target = self.providers.select(route).model_catalog orelse return;
        var settings = config_runtime.loadMergedSettings(alloc, self.workspace_root) catch return;
        defer settings.deinit(alloc);
        var transport = CancellableTransport{ .transport = self.transport, .cancel_flag = input.cancel_flag };
        var credential = (auth_runtime.prepareCredential(
            alloc,
            .{ .context = &transport, .execute_fn = CancellableTransport.execute },
            self.secret_store,
            route,
            if (route == .gateway) settings.credential_source else null,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        }) orelse return;
        defer credential.deinit(alloc);
        var target_input = input;
        target_input.access = credentials.catalogAccessForCredentialAndAccount(credential.source, credential.token, credential.gatewayTeam(), credential.accountId());
        var result = try target.fetch(alloc, target_input);
        if (result == .failure) return;
        defer model_catalog.freeModelCatalog(alloc, &result.catalog);
        try appendQualifiedCatalog(alloc, route, catalog, &result.catalog);
    }
};

const CancellableTransport = struct {
    transport: oauth_transport.Provider,
    cancel_flag: ?*std.atomic.Value(bool),

    fn execute(raw: ?*anyopaque, alloc: std.mem.Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *CancellableTransport = @ptrCast(@alignCast(raw.?));
        var bounded = request;
        bounded.cancel_flag = self.cancel_flag;
        return self.transport.execute(alloc, bounded);
    }
};

fn appendQualifiedCatalog(alloc: std.mem.Allocator, route: model_provider.ProviderId, catalog: *std.ArrayList(model_catalog.ModelCatalogEntry), source: *std.ArrayList(model_catalog.ModelCatalogEntry)) !void {
    try catalog.ensureUnusedCapacity(alloc, source.items.len);
    for (source.items) |*entry| {
        const qualified = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ route.label(), entry.id });
        alloc.free(entry.id);
        entry.id = qualified;
        entry.selection_provider = route;
    }
    catalog.appendSliceAssumeCapacity(source.items);
    source.clearRetainingCapacity();
}

test "connected catalogs keep duplicate model IDs distinct by route" {
    const alloc = std.testing.allocator;
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try catalog.append(alloc, .{ .id = try alloc.dupe(u8, "shared"), .model_type = try alloc.dupe(u8, "language") });
    var other: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    defer model_catalog.freeModelCatalog(alloc, &other);
    try other.append(alloc, .{ .id = try alloc.dupe(u8, "shared"), .context_window = 12345, .model_type = try alloc.dupe(u8, "language") });
    try appendQualifiedCatalog(alloc, .codex, &catalog, &other);
    try std.testing.expectEqual(@as(usize, 0), other.items.len);
    try std.testing.expectEqualStrings("shared", catalog.items[0].id);
    try std.testing.expectEqualStrings("codex:shared", catalog.items[1].id);
    try std.testing.expectEqual(@as(u32, 12345), catalog.items[1].context_window);
    const selection = qualifiedSelection(catalog.items[1].id, .{}).?;
    try std.testing.expectEqual(model_provider.ProviderId.codex, selection.provider);
    try std.testing.expectEqualStrings("shared", selection.model);
    try std.testing.expect(qualifiedSelection("openai/shared", .{}) == null);
    try std.testing.expect(qualifiedSelection("codex:", .{}) == null);
    try std.testing.expect(qualifiedSelection("qwen:32b", .{}) == null);
    try std.testing.expectEqual(model_provider.ProviderId.codex, catalog.items[1].selection_provider.?);
}

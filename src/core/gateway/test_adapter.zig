//! Provider-neutral adapter fixtures shared by core integration tests.

const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const adapter_auth = @import("adapter_auth.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_catalog = @import("model_catalog.zig");
const connection_registry = @import("connection_registry.zig");
const adapter_registry = @import("adapter_registry.zig");
const gateway_system = @import("gateway_system.zig");
const web_search_contract = @import("../tooling/web_search_contract.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;

pub const connection_seed = connection_registry.Seed{
    .id = "test-connection",
    .display_name = "Example Cloud",
    .adapter_id = "test-adapter",
    .endpoint = "https://example.invalid/model",
    .protocol = "test-model-stream",
    .credential_ref = "test-credential",
    .internal_models = .{
        .permission_review = "test/reviewer",
        .vision = "test/vision",
    },
};

fn fetchEmptyCatalog(
    _: ?*anyopaque,
    _: Allocator,
    _: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    return .{ .catalog = .empty };
}

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchEmptyCatalog,
};

fn modelFamily(model: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, model, '/') orelse return "";
    return model[0..slash];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn staticContextWindow(model: []const u8) ?u32 {
    if (std.mem.startsWith(u8, model, "anthropic/")) {
        if (containsIgnoreCase(model, "opus-4.6") or
            containsIgnoreCase(model, "opus-4-6") or
            containsIgnoreCase(model, "opus-4.7") or
            containsIgnoreCase(model, "opus-4-7") or
            containsIgnoreCase(model, "opus-4.8") or
            containsIgnoreCase(model, "opus-4-8") or
            containsIgnoreCase(model, "sonnet-4.6") or
            containsIgnoreCase(model, "sonnet-4-6") or
            containsIgnoreCase(model, "sonnet-5") or
            containsIgnoreCase(model, "fable-5")) return 1_000_000;
        return 200_000;
    }
    if (std.mem.startsWith(u8, model, "openai/")) {
        if (containsIgnoreCase(model, "gpt-5")) return 256_000;
        if (containsIgnoreCase(model, "o1") or
            containsIgnoreCase(model, "o3") or
            containsIgnoreCase(model, "o4")) return 200_000;
        return 128_000;
    }
    if (std.mem.startsWith(u8, model, "xai/")) return 131_072;
    if (std.mem.startsWith(u8, model, "google/")) return 1_000_000;
    return null;
}

fn fallbackDescriptor(_: ?*anyopaque, model: []const u8) model_capabilities.ModelDescriptor {
    var descriptor = model_capabilities.configuredDescriptor(model, .{
        .prompt_caching = std.mem.startsWith(u8, model, "anthropic/"),
        .parallel_tool_calls = if (std.mem.startsWith(u8, model, "xai/")) true else null,
        .context_window = staticContextWindow(model),
    });
    descriptor.provider = modelFamily(model);
    descriptor.source = .@"adapter-static";
    return descriptor;
}

fn catalogDescriptor(_: ?*anyopaque, entry: model_catalog.ModelCatalogEntry) model_capabilities.ModelDescriptor {
    var descriptor = model_catalog.configured_model_descriptor_provider.catalog(entry);
    descriptor.provider = modelFamily(entry.id);
    return descriptor;
}

pub const model_descriptor_provider = model_catalog.ModelDescriptorProvider{
    .fallback_fn = fallbackDescriptor,
    .catalog_fn = catalogDescriptor,
};

fn missingStatus(
    _: *const anyopaque,
    _: Allocator,
    _: connection_registry.Profile,
    _: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.StatusOutcome {
    return .{ .loaded = .{ .store_status = .not_found } };
}

fn noPreferredBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
    return null;
}

fn unavailableSearch(
    _: ?*anyopaque,
    _: Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse {
    return error.TestSearchUnavailable;
}

pub const default_web_search_provider = web_search_provider.Provider{
    .policy = .{},
    .preferred_backends_fn = noPreferredBackends,
    .execute_fn = unavailableSearch,
};

fn finishStream(
    _: *const stream_provider.ProviderAdapter,
    _: Allocator,
    _: stream_provider.AdapterRequest,
    events: stream_provider.EventSink,
) anyerror!void {
    try events.emit(.provider_admitted);
    try events.emit(.{ .finish = .{ .reason = .stop } });
}

pub const provider_adapter = stream_provider.ProviderAdapter{
    .kind = connection_seed.adapter_id,
    .supported_protocol = connection_seed.protocol.?,
    .auth = .{
        .kind = connection_seed.adapter_id,
        .auth_service_label = "Example Cloud",
        .status_fn = missingStatus,
    },
    .model_catalog = model_catalog_provider,
    .model_descriptors = model_descriptor_provider,
    .web_search = default_web_search_provider,
    .provider_tools = &.{.web_search},
    .stream_fn = finishStream,
};

const adapters = [_]stream_provider.ProviderAdapter{provider_adapter};

pub const system = gateway_system.System{
    .connection_seed = connection_seed,
    .adapter_registry = adapter_registry.AdapterRegistry{ .adapters = &adapters },
};

const std = @import("std");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const web_search_slots = @import("web_search_slots.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Inputs = struct {
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
};

pub const PreferredBackendsFn = *const fn (?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId;

/// The provider's backend for a web search slot, or null for a slot the
/// provider does not run itself.
pub const SlotBackendFn = *const fn (web_search_slots.Slot) ?web_search_contract.SearchBackendId;

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    Inputs,
    web_search_contract.ProviderRequest,
    ?web_search_contract.ProgressFn,
    ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse;

pub const Provider = struct {
    context: ?*anyopaque = null,
    policy: web_search_policy.WebSearchPolicy,
    input_overhead_bytes: usize = 0,
    preferred_backends_fn: PreferredBackendsFn,
    /// Set when the provider's backends follow the web search slots.
    slot_backend_fn: ?SlotBackendFn = null,
    execute_fn: ExecuteFn,

    pub fn preferredBackends(self: Provider) !?[]const web_search_contract.SearchBackendId {
        return self.preferred_backends_fn(self.context);
    }

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        inputs: Inputs,
        request: web_search_contract.ProviderRequest,
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !web_search_contract.ProviderResponse {
        return self.execute_fn(self.context, alloc, inputs, request, on_progress, progress_ctx);
    }
};

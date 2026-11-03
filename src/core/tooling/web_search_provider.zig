const std = @import("std");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const Inputs = struct {
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8,
    worker_provider: model_provider.ProviderId = .gateway,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    /// Account of the active subscription credential, when it has one.
    account_id: ?[]const u8 = null,
    /// Messages API prefix of the active configured Anthropic-compatible
    /// connection; its key is `api_key`. Null for every other provider.
    anthropic_base_url: ?[]const u8 = null,
    /// The configured connection sends its key as a bearer token.
    anthropic_bearer: bool = false,
};

pub const PreferredBackendsFn = *const fn (?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId;

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    Inputs,
    web_search_contract.ProviderRequest,
    ?web_search_contract.ProgressFn,
    ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse;

pub const AvailableFn = *const fn (?*anyopaque, Allocator, Inputs) bool;

pub const Provider = struct {
    context: ?*anyopaque = null,
    policy: web_search_policy.WebSearchPolicy,
    input_overhead_bytes: usize = 0,
    preferred_backends_fn: PreferredBackendsFn,
    execute_fn: ExecuteFn,
    /// Whether a search with these credentials has a backend outside native
    /// provider search. Null means never: such a provider, like the gateway
    /// worker, serves only the provider that owns it.
    available_fn: ?AvailableFn = null,

    pub fn available(self: Provider, alloc: Allocator, inputs: Inputs) bool {
        const available_fn = self.available_fn orelse return false;
        return available_fn(self.context, alloc, inputs);
    }

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

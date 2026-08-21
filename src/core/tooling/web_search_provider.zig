const std = @import("std");
const session_usage = @import("../session/session_usage.zig");
const openai_transport = @import("../gateway/openai_transport.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");

const Allocator = std.mem.Allocator;

pub const Inputs = struct {
    api_key: []const u8,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_wire_kind: openai_transport.WireKind = .gateway,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
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

pub const Provider = struct {
    context: ?*anyopaque = null,
    policy: web_search_policy.WebSearchPolicy,
    input_overhead_bytes: usize = 0,
    preferred_backends_fn: PreferredBackendsFn,
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

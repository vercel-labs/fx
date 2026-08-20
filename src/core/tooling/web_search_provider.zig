const std = @import("std");
const session_usage = @import("../session/session_usage.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");

const Allocator = std.mem.Allocator;

pub const Inputs = struct {
    connection_id: []const u8,
    credential: []const u8,
    tenant: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    endpoint: []const u8,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
};

test "web search connection identity has no provider default" {
    const fields = @typeInfo(Inputs).@"struct".fields;
    try std.testing.expectEqualStrings("connection_id", fields[0].name);
    try std.testing.expect(fields[0].default_value_ptr == null);
}

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

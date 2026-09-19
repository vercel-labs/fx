const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Opaque provider-owned identity borrowed for the policy and runtime lifetime.
pub const SearchBackendId = struct {
    value: []const u8,

    pub fn eql(self: SearchBackendId, other: SearchBackendId) bool {
        return std.mem.eql(u8, self.value, other.value);
    }
};

pub const BackendFeatureMode = enum {
    unsupported,
    best_effort,
    pass_through,
    post_filter,
};

pub const BackendCapabilities = struct {
    max_uses: BackendFeatureMode = .unsupported,
    allowed_domains: BackendFeatureMode = .unsupported,
    blocked_domains: BackendFeatureMode = .unsupported,
    ordered_sources: bool = false,
    usage: bool = false,
    terminal_incomplete: bool = false,
    timeout: bool = false,
    cancellation: bool = false,
    result_bounds: BackendFeatureMode = .unsupported,
};

pub const Request = struct {
    /// Host execution metadata, never part of the model-facing tool input.
    execution_model: ?[]const u8 = null,
    query: []const u8,
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
};

pub const ProviderRequest = struct {
    backend: SearchBackendId,
    query: []const u8,
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
    max_uses: u8 = 8,
    max_results: u8 = 10,
    max_output_tokens: u32 = 4096,
    max_output_chars: usize = 100_000,
    timeout_ms: u32 = 30_000,
    cancel_flag: *const std.atomic.Value(bool),
};

pub const Progress = union(enum) {
    query_update: []const u8,
    results_received: struct {
        query: []const u8,
        result_count: usize,
    },
};

pub const ProgressFn = *const fn (*anyopaque, Progress) void;

pub const Source = struct {
    title: []const u8,
    url: []const u8,

    pub fn deinit(self: Source, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.url);
    }
};

pub const SearchBlock = struct {
    tool_use_id: []const u8,
    content: []const Source,

    pub fn deinit(self: SearchBlock, alloc: Allocator) void {
        alloc.free(self.tool_use_id);
        for (self.content) |source| source.deinit(alloc);
        alloc.free(self.content);
    }
};

pub const TerminalIncomplete = struct {
    stop_reason: []const u8,
    message: []const u8,

    pub fn deinit(self: TerminalIncomplete, alloc: Allocator) void {
        alloc.free(self.stop_reason);
        alloc.free(self.message);
    }
};

pub const ResultItem = union(enum) {
    commentary: []const u8,
    search: SearchBlock,
    error_text: []const u8,
    terminal_incomplete: TerminalIncomplete,

    pub fn deinit(self: ResultItem, alloc: Allocator) void {
        switch (self) {
            .commentary => |text| alloc.free(text),
            .search => |search| search.deinit(alloc),
            .error_text => |text| alloc.free(text),
            .terminal_incomplete => |incomplete| incomplete.deinit(alloc),
        }
    }
};

/// Provider output whose content and stop reason are owned by the caller.
pub const ProviderResponse = struct {
    content: []const ResultItem = &.{},
    stop_reason: ?[]const u8 = null,
    usage: ?types.ToolUsage = null,

    pub fn takeContent(self: *ProviderResponse) []const ResultItem {
        const content = self.content;
        self.content = &.{};
        return content;
    }

    pub fn deinit(self: *ProviderResponse, alloc: Allocator) void {
        deinitItems(alloc, self.content);
        if (self.stop_reason) |reason| alloc.free(reason);
        self.* = .{};
    }
};

/// Search output with a borrowed query and owned result allocations. The
/// caller must call `deinit` with the allocator that received the output.
pub const Output = struct {
    query: []const u8,
    results: []const ResultItem,
    incomplete: bool = false,
    duration_ms: u64,
    web_search_requests: u32,

    pub fn deinit(self: *Output, alloc: Allocator) void {
        deinitItems(alloc, self.results);
        self.results = &.{};
    }
};

/// Executor output whose result allocations are owned by the caller.
pub const ExecutionOutput = struct {
    output: Output,
    inner_usage: ?types.ToolUsage = null,

    pub fn deinit(self: *ExecutionOutput, alloc: Allocator) void {
        self.output.deinit(alloc);
        self.* = undefined;
    }
};

fn deinitItems(alloc: Allocator, items: []const ResultItem) void {
    for (items) |item| item.deinit(alloc);
    if (items.len > 0) alloc.free(items);
}

test "backend identity compares provider-owned values" {
    const copied = [_]u8{ 'p', 'r', 'o', 'v', 'i', 'd', 'e', 'r', '.', 'o', 'n', 'e' };
    const expected = SearchBackendId{ .value = "provider.one" };

    try std.testing.expect(expected.eql(.{ .value = &copied }));
    try std.testing.expect(!expected.eql(.{ .value = "provider.two" }));
}

test "provider response transfers ordered results to output" {
    const content = [_]ResultItem{
        .{ .commentary = "researching" },
        .{ .error_text = "bounded failure" },
    };
    var response = ProviderResponse{
        .content = &content,
    };
    const output = Output{
        .query = "zig",
        .results = response.takeContent(),
        .duration_ms = 1,
        .web_search_requests = 0,
    };

    try std.testing.expectEqual(@as(usize, 0), response.content.len);
    try std.testing.expectEqualStrings("researching", output.results[0].commentary);
    try std.testing.expectEqualStrings("bounded failure", output.results[1].error_text);
}

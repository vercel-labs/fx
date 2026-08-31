const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_search_results: usize = 20;
pub const max_search_query_bytes: usize = 512;
pub const max_read_reference_bytes: usize = 512;

pub const SearchRequest = struct {
    query: []const u8,
    limit: usize,
};

pub const ReadRequest = struct {
    reference: []const u8,
    include_execution: bool,
};

pub const Result = union(enum) {
    success: []u8,
    failure: []u8,
};

const SearchFn = *const fn (
    ?*anyopaque,
    Allocator,
    SearchRequest,
) error{OutOfMemory}!Result;

const ReadFn = *const fn (
    ?*anyopaque,
    Allocator,
    ReadRequest,
) error{OutOfMemory}!Result;

/// Host-owned access to canonical session history. The provider fixes the
/// workspace and current session identity; model-supplied arguments cannot
/// broaden either boundary.
pub const Provider = struct {
    context: ?*anyopaque,
    search_fn: SearchFn,
    read_fn: ReadFn,

    pub fn search(
        self: Provider,
        alloc: Allocator,
        request: SearchRequest,
    ) error{OutOfMemory}!Result {
        return self.search_fn(self.context, alloc, request);
    }

    pub fn read(
        self: Provider,
        alloc: Allocator,
        request: ReadRequest,
    ) error{OutOfMemory}!Result {
        return self.read_fn(self.context, alloc, request);
    }
};

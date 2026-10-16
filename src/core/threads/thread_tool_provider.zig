//! Host-facing contract between the `thread_read` and `thread_send` model
//! tools and the runtime that owns the threads. The tools decode and validate
//! model arguments; the provider reaches the subagent host and the registry.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Request = union(enum) {
    /// `name == null` lists every thread. Borrowed from the decoded input.
    read: struct { name: ?[]const u8, lines: usize },
    /// Borrowed from the decoded input.
    send: struct { name: []const u8, message: []const u8 },
    /// Starts a new thread. Borrowed from the decoded input.
    new: struct { name: []const u8, task: []const u8 },
};

pub const Status = enum { success, failure };

/// Owned provider output. The caller frees `body` with the allocator passed to
/// `Provider.execute`. The text is plain, not JSON.
pub const Result = struct {
    status: Status,
    body: []u8,
};

pub const ExecuteError = Allocator.Error || error{Cancelled};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    Request,
    []const u8,
) ExecuteError!Result;

pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        request: Request,
        invocation_id: []const u8,
    ) ExecuteError!Result {
        return self.execute_fn(self.context, alloc, request, invocation_id);
    }
};

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const CommandResult = struct {
    exit_code: i64,
    stdout: []u8,
    stderr: []u8,
    duration_ms: ?u64 = null,

    pub fn deinit(self: *CommandResult, alloc: Allocator) void {
        if (self.stdout.len > 0) {
            alloc.free(self.stdout);
        }
        if (self.stderr.len > 0) {
            alloc.free(self.stderr);
        }
        self.* = undefined;
    }
};

pub const ProviderError = error{
    OutOfMemory,
    DevboxUnavailable,
    InvalidRequest,
    ProcessSpawnFailed,
    Timeout,
    Cancelled,
    WriteFailed,
    ReadFailed,
};

pub const VercelOutcome = union(enum) {
    ok: CommandResult,
    unavailable,
    denied,
    rate_limited,
    request_failed,
};

pub const Control = struct {
    cancel: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

pub const Provider = struct {
    ctx: *anyopaque,
    execute_fn: *const fn (
        ctx: *anyopaque,
        request: []const u8,
        deadline_ms: i64,
        control: Control,
    ) ProviderError!VercelOutcome,
};

pub fn execute(
    provider: Provider,
    alloc: Allocator,
    request: []const u8,
    deadline_ms: i64,
    control: Control,
) ProviderError!VercelOutcome {
    return provider.execute_fn(provider.ctx, request, deadline_ms, control);
}

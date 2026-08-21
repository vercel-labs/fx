const std = @import("std");
const output_contracts = @import("../output/output_contracts.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    credential: ?[]const u8,
    tenant: ?[]const u8,
};

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight fetch returns.
    context: ?*anyopaque = null,
    fetch_fn: *const fn (
        ?*anyopaque,
        Allocator,
        Input,
    ) output_contracts.CreditsSnapshot,

    /// Account usage is limited to balance, credits, and limits. The returned
    /// snapshot owns its populated fields; the caller must call `deinit`.
    pub fn fetch(
        self: Provider,
        alloc: Allocator,
        input: Input,
    ) output_contracts.CreditsSnapshot {
        return self.fetch_fn(self.context, alloc, input);
    }
};

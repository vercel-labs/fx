//! A credits endpoint for tests: it answers only once the test releases it,
//! or once the lookup is cancelled.
const std = @import("std");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");

pub const HeldCredits = struct {
    released: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    saw_input: std.atomic.Value(bool) = .init(false),
    /// Runs until released however it is cancelled, as a sign-in renewal does.
    ignores_cancel: bool = false,
    /// Whether the reply says the team has Token Pass.
    has_pass: bool = false,

    pub fn provider(self: *HeldCredits) gateway_provider.CreditsProvider {
        return .{ .context = self, .fetch_fn = fetch };
    }

    pub fn release(self: *HeldCredits) void {
        self.released.store(true, .seq_cst);
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: std.mem.Allocator,
        input: gateway_provider.CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        const self: *HeldCredits = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.saw_input.store(
            std.mem.eql(u8, input.credential orelse "", "credential") and
                std.mem.eql(u8, input.tenant orelse "", "tenant") and
                input.cancel_flag != null,
            .seq_cst,
        );
        // Stands in for a slow endpoint.
        while (!self.released.load(.seq_cst) and (self.ignores_cancel or !input.cancel_flag.?.load(.seq_cst))) {
            // A failed yield only spins once more.
            std.Thread.yield() catch {};
        }
        if (input.cancel_flag.?.load(.seq_cst)) {
            return .{ .err_message = alloc.dupe(u8, "cancelled") catch null };
        }
        return .{
            .balance = alloc.dupe(u8, "42") catch null,
            .token_pass = if (self.has_pass) .{} else null,
        };
    }
};

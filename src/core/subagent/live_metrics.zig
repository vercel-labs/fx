const std = @import("std");

pub const LiveMetrics = struct {
    input_tokens: std.atomic.Value(u64) = .init(0),

    pub fn snapshot(self: *const LiveMetrics) Snapshot {
        return .{ .input_tokens = self.input_tokens.load(.monotonic) };
    }
};

pub const Snapshot = struct {
    input_tokens: u64 = 0,
};

const std = @import("std");

/// Incrementally estimates raw model or request text without making the result
/// depend on transport chunk boundaries.
pub const StreamingEstimator = struct {
    settled_tokens: u64 = 0,
    span_bytes: u64 = 0,

    pub fn consume(self: *StreamingEstimator, text: []const u8) void {
        for (text) |byte| {
            if (std.ascii.isWhitespace(byte)) {
                self.finishSpan();
            } else {
                self.span_bytes +|= 1;
            }
        }
    }

    pub fn estimate(self: StreamingEstimator) u64 {
        return self.settled_tokens +| estimateSpan(self.span_bytes);
    }

    fn finishSpan(self: *StreamingEstimator) void {
        self.settled_tokens +|= estimateSpan(self.span_bytes);
        self.span_bytes = 0;
    }

    fn estimateSpan(span_bytes: u64) u64 {
        return span_bytes / 4 + @intFromBool(span_bytes % 4 != 0);
    }
};

/// Estimated tokens of one complete text.
pub fn textTokens(text: []const u8) usize {
    var estimator = StreamingEstimator{};
    estimator.consume(text);
    return @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
}

test "StreamingEstimator is invariant across chunk boundaries" {
    const text = "split 你好 inside words";

    var one_shot = StreamingEstimator{};
    one_shot.consume(text);
    const expected = one_shot.estimate();

    for (0..text.len + 1) |split| {
        var fragmented = StreamingEstimator{};
        fragmented.consume(text[0..split]);
        fragmented.consume(text[split..]);
        try std.testing.expectEqual(expected, fragmented.estimate());
    }
}

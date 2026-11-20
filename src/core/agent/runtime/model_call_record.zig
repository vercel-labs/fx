//! The record of one settled model request, which Ctrl+O shows where it
//! happened (`types.ModelCallRecord`). Pure: the caller says when the
//! request started and when it settled.

const std = @import("std");
const types = @import("../../shared/types.zig");
const agent_stream_provider = @import("../stream_provider.zig");

/// Takes each settled request's record from a caller that makes model
/// requests outside the turn loop, such as compaction. The record borrows
/// its strings for the call; a sink that keeps it copies it.
pub const Sink = struct {
    context: *anyopaque,
    record_fn: *const fn (context: *anyopaque, record: types.ModelCallRecord) void,
    /// Who the requests go to, as the record names it.
    provider: []const u8,

    pub fn record(self: Sink, value: types.ModelCallRecord) void {
        self.record_fn(self.context, value);
    }
};

/// The record of a request that settled with a result, borrowing its
/// strings. Provider text that `types.validModelCallText` refuses is left
/// out, so a record never fails its own checks when saved or replayed. A
/// stop asked for while it streamed (`stop_requested`) makes what came so
/// far a cancelled call.
pub fn ofResult(
    provider: []const u8,
    model: []const u8,
    purpose: types.ModelCallPurpose,
    started_ms: i64,
    settled_ms: i64,
    result: *const agent_stream_provider.Result,
    stop_requested: bool,
) types.ModelCallRecord {
    var record: types.ModelCallRecord = .{
        .at_ms = settled_ms,
        .elapsed_ms = elapsed(started_ms, settled_ms),
        .purpose = purpose,
        .provider = provider,
        .model = model,
    };
    switch (result.*) {
        .completed => |*completed| {
            const completion = completed.completion;
            record.generation_id = checked(completion.generation_id);
            record.served_by = checked(completion.resolved_provider);
            if (completion.finish_reason) |reason| record.finish = @tagName(reason);
            record.input_tokens = completion.usage.input_tokens;
            record.output_tokens = completion.usage.output_tokens;
            if (stop_requested) record.outcome = .cancelled;
        },
        .failed => |*failure| {
            record.outcome = .failed;
            record.failure = @tagName(failure.kind);
            if (failure.retry_after_seconds) |seconds| record.retry_after_s = std.math.cast(u32, seconds);
        },
    }
    return record;
}

/// The record of a request that ended in an error instead of a result:
/// cancelled when it was stopped, failed otherwise.
pub fn ofError(
    provider: []const u8,
    model: []const u8,
    purpose: types.ModelCallPurpose,
    started_ms: i64,
    settled_ms: i64,
    cancelled: bool,
    err: anyerror,
) types.ModelCallRecord {
    return .{
        .at_ms = settled_ms,
        .elapsed_ms = elapsed(started_ms, settled_ms),
        .purpose = purpose,
        .outcome = if (cancelled) .cancelled else .failed,
        .provider = provider,
        .model = model,
        .failure = if (cancelled) null else @errorName(err),
    };
}

/// A clock that steps back never makes a negative duration.
fn elapsed(started_ms: i64, settled_ms: i64) u64 {
    return @intCast(@max(settled_ms - started_ms, 0));
}

fn checked(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (types.validModelCallText(value)) value else null;
}

test "a settled request's record keeps its outcome, cost and checked provider ids" {
    var completed: agent_stream_provider.Result = .{ .completed = .{ .completion = .{
        .finish_reason = .stop,
        .generation_id = "gen_01JC7P5XQ2M8VZ",
        .resolved_provider = "bedrock",
        .usage = .{ .input_tokens = 1240, .output_tokens = 56, .cache_read_tokens = 900 },
    } } };
    const record = ofResult("gateway", "anthropic/claude-opus-4.8", .turn, 1_000, 3_140, &completed, false);
    try std.testing.expectEqual(@as(i64, 3_140), record.at_ms);
    try std.testing.expectEqual(@as(u64, 2_140), record.elapsed_ms);
    try std.testing.expectEqual(types.ModelCallOutcome.completed, record.outcome);
    try std.testing.expectEqualStrings("gen_01JC7P5XQ2M8VZ", record.generation_id.?);
    try std.testing.expectEqualStrings("bedrock", record.served_by.?);
    try std.testing.expectEqualStrings("stop", record.finish.?);
    try std.testing.expectEqual(@as(?u64, 1240), record.input_tokens);
    try std.testing.expectEqual(@as(?u64, 56), record.output_tokens);

    var failed: agent_stream_provider.Result = .{ .failed = .{ .kind = .rate_limited, .retry_after_seconds = 4 } };
    const refused = ofResult("codex", "gpt-5.2", .compaction, 5_000, 4_000, &failed, false);
    try std.testing.expectEqual(types.ModelCallOutcome.failed, refused.outcome);
    try std.testing.expectEqualStrings("rate_limited", refused.failure.?);
    try std.testing.expectEqual(@as(?u32, 4), refused.retry_after_s);
    try std.testing.expectEqual(@as(u64, 0), refused.elapsed_ms);
    try std.testing.expectEqual(types.ModelCallPurpose.compaction, refused.purpose);

    // A result that comes back after a stop was asked for is a cancelled
    // call; a failure stays a failure.
    try std.testing.expectEqual(types.ModelCallOutcome.cancelled, ofResult("gateway", "m", .turn, 0, 0, &completed, true).outcome);
    try std.testing.expectEqual(types.ModelCallOutcome.failed, ofResult("gateway", "m", .turn, 0, 0, &failed, true).outcome);
}

test "a settled request's record leaves out provider text that could forge a line" {
    var completed: agent_stream_provider.Result = .{ .completed = .{ .completion = .{
        .generation_id = "gen_\x1b[2Jcleared",
        .resolved_provider = "line\nbreak",
    } } };
    const record = ofResult("gateway", "m", .turn, 0, 0, &completed, false);
    try std.testing.expect(record.generation_id == null);
    try std.testing.expect(record.served_by == null);
    try std.testing.expect(record.finish == null);
}

test "a request that ends in an error is recorded as cancelled or failed" {
    const stopped = ofError("gateway", "m", .turn, 10, 25, true, error.Canceled);
    try std.testing.expectEqual(types.ModelCallOutcome.cancelled, stopped.outcome);
    try std.testing.expect(stopped.failure == null);
    try std.testing.expectEqual(@as(u64, 15), stopped.elapsed_ms);
    const broken = ofError("gateway", "m", .compaction, 10, 25, false, error.ConnectionResetByPeer);
    try std.testing.expectEqual(types.ModelCallOutcome.failed, broken.outcome);
    try std.testing.expectEqualStrings("ConnectionResetByPeer", broken.failure.?);
    try std.testing.expectEqual(types.ModelCallPurpose.compaction, broken.purpose);
}

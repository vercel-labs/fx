const std = @import("std");
const contracts = @import("contracts.zig");
const optimizer = @import("optimizer.zig");
const executor = @import("executor.zig");
const cache_mod = @import("cache.zig");

const hard_max_result_bytes = 16 * 1024 * 1024;

pub const BatchLimits = struct {
    max_result_bytes: usize = 64 * 1024,
};

// Owns result array and every output copy; request strings remain frozen and borrowed.
pub const Execution = struct {
    results: []cache_mod.ReadResult,
    cache_hits: usize,
    cache_misses: usize,
    backing_reads: usize,

    pub fn deinit(self: *Execution, alloc: std.mem.Allocator) void {
        for (self.results) |*result| result.deinit(alloc);
        alloc.free(self.results);
        self.* = undefined;
    }
};

// Independent sequential logical calls. Completed values may be reused between
// batches; this API supplies no broker, in-flight coalescing, or cancellation.
// Reserve every admitted snapshot-read requested window conservatively before
// cache access or output allocation, including windows that later fail dispatch.
// A limit above 16 MiB or an exceeded/overflowed reservation rejects the entire
// batch with an error and no receipts or cache changes. Cache and plan metadata
// have separate bounds; this limit covers caller-owned output copies only.
pub fn execute(alloc: std.mem.Allocator, cache: *cache_mod.Cache, snapshot: *const executor.Snapshot, calls: []const contracts.LogicalCall, limits: BatchLimits) !Execution {
    if (limits.max_result_bytes > hard_max_result_bytes) return error.BatchLimitTooLarge;
    var validation = try optimizer.build_plan(alloc, calls, .disabled);
    defer validation.deinit(alloc);
    var reserved_output_bytes: usize = 0;
    for (validation.logical_calls) |planned| {
        if (planned.status != .admitted or planned.call.request.effect != .snapshot_read) continue;
        reserved_output_bytes = std.math.add(usize, reserved_output_bytes, planned.call.request.args.window.length) catch return error.BatchResultLimitExceeded;
        if (reserved_output_bytes > limits.max_result_bytes) return error.BatchResultLimitExceeded;
    }
    const results = try alloc.alloc(cache_mod.ReadResult, calls.len);
    var initialized: usize = 0;
    errdefer {
        for (results[0..initialized]) |*result| result.deinit(alloc);
        alloc.free(results);
    }
    var hits: usize = 0;
    var misses: usize = 0;
    var backing_reads: usize = 0;
    for (calls, 0..) |call, index| {
        results[index] = try cache.read(alloc, snapshot, call);
        initialized += 1;
        hits += @intFromBool(results[index].cache_hit);
        misses += @intFromBool(results[index].cache_miss);
        backing_reads += results[index].backing_reads;
    }
    return .{ .results = results, .cache_hits = hits, .cache_misses = misses, .backing_reads = backing_reads };
}

test "duplicate logical IDs reject a batch before cache access" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    var cache = try cache_mod.Cache.init(std.testing.allocator, .{ .max_entries = 2, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    const request: contracts.CallBinding = .{
        .id = 1,
        .agent_id = "a",
        .principal_domain = "operator",
        .task_id = "task",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = snapshot.identity(),
        .args = .{ .path = snapshot.path, .window = .{ .offset = 0, .length = 3 }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "fixture-read", .epoch = 1, .generation = 1 },
    };
    const call: contracts.LogicalCall = .{ .request = request, .admission = .{ .admitted = .{ .binding = request, .current_authority = request.authority, .immutable_snapshot = request.snapshot } } };
    try std.testing.expectError(error.DuplicateLogicalId, execute(std.testing.allocator, &cache, &snapshot, &.{ call, call }, .{}));
    try std.testing.expectEqual(@as(usize, 0), cache.stats().entries);
}

test "aggregate valid windows reject before cache access without allocating projected outputs" {
    const source = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", source);
    defer snapshot.deinit(std.testing.allocator);
    var cache = try cache_mod.Cache.init(std.testing.allocator, .{ .max_entries = 2, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var calls: [513]contracts.LogicalCall = undefined;
    for (&calls, 0..) |*call, index| {
        const request: contracts.CallBinding = .{
            .id = @intCast(index + 1),
            .agent_id = "a",
            .principal_domain = "operator",
            .task_id = "task",
            .tool_id = "embedded-content-reader",
            .effect = .snapshot_read,
            .snapshot = snapshot.identity(),
            .args = .{ .path = snapshot.path, .window = .{ .offset = 0, .length = source.len }, .options = "raw" },
            .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
            .output_budget = source.len,
            .authority = .{ .partition = "fixture-read", .epoch = 1, .generation = 1 },
        };
        call.* = .{ .request = request, .admission = .{ .admitted = .{ .binding = request, .current_authority = request.authority, .immutable_snapshot = request.snapshot } } };
    }
    const before = cache.stats();
    try std.testing.expectError(error.BatchResultLimitExceeded, execute(std.testing.allocator, &cache, &snapshot, &calls, .{ .max_result_bytes = hard_max_result_bytes }));
    try std.testing.expectEqual(before.entries, cache.stats().entries);
    try std.testing.expectEqual(before.retained_bytes, cache.stats().retained_bytes);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().hits);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().misses);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().backing_reads);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().rejected);
    try std.testing.expectError(error.BatchLimitTooLarge, execute(std.testing.allocator, &cache, &snapshot, &.{}, .{ .max_result_bytes = hard_max_result_bytes + 1 }));
    calls[0].request.args.window.length = 1;
    calls[0].admission.admitted.binding = calls[0].request;
    calls[1].request.args.window.length = std.math.maxInt(usize);
    calls[1].admission.admitted.binding = calls[1].request;
    try std.testing.expectError(error.BatchResultLimitExceeded, execute(std.testing.allocator, &cache, &snapshot, calls[0..2], .{ .max_result_bytes = hard_max_result_bytes }));
    try std.testing.expectEqual(@as(usize, 0), cache.stats().misses);
    try std.testing.expectEqual(before.retained_bytes, cache.stats().retained_bytes);
    // Denied calls have no output reservation, even with the zero-byte limit.
    calls[0].admission = .denied;
    var denied = try execute(std.testing.allocator, &cache, &snapshot, calls[0..1], .{ .max_result_bytes = 0 });
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), denied.backing_reads);
    try std.testing.expectEqual(contracts.AdmissionStatus.denied, denied.results[0].receipt.admission_status);
}

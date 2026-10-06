const std = @import("std");
const contracts = @import("contracts.zig");
const executor = @import("executor.zig");
const cache_mod = @import("cache.zig");
const cached_executor = @import("cached_executor.zig");

const help =
    \\Usage: agent-cast-cache-demo --fixture PATH
    \\
    \\Capture a real file of 256 bytes to 1 MiB. Run two independent admitted
    \\four-window batches, then a batch of denied, stale, and mismatched calls.
    \\JSON includes complete output bytes and actual hit, miss, and backing counts.
    \\Hits still validate fixture admission, hash the capture, and copy output.
    \\This synchronous experiment does not implement production registry validation.
    \\
    \\  --fixture PATH  Actual file to capture once
    \\  --help          Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "agent-cast-cache-demo: {s}; see --help\n", .{@errorName(err)});
        try std.Io.File.stderr().writeStreamingAll(init.io, message);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const report_alloc = arena.allocator();
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(report_alloc);
    var path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, help);
            return;
        }
        if (!std.mem.eql(u8, args[index], "--fixture")) return error.UnknownArgument;
        index += 1;
        if (index >= args.len) return error.MissingFixturePath;
        if (path != null) return error.DuplicateFixtureOption;
        path = args[index];
    }
    const fixture_path = path orelse return error.MissingFixturePath;
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, fixture_path, alloc, .limited(1024 * 1024 + 1));
    defer alloc.free(file_bytes);
    if (file_bytes.len < 256) return error.FixtureTooSmall;
    var snapshot = try executor.Snapshot.init(alloc, fixture_path, file_bytes);
    defer snapshot.deinit(alloc);
    const limits: cache_mod.Limits = .{ .max_entries = 8, .max_bytes = 32768 };
    const batch_limits: cached_executor.BatchLimits = .{ .max_result_bytes = 4096 };
    var cache = try cache_mod.Cache.init(alloc, limits);
    defer cache.deinit(alloc);

    var cold_calls: [4]contracts.LogicalCall = undefined;
    var hot_calls: [4]contracts.LogicalCall = undefined;
    for (0..4) |window| {
        cold_calls[window] = fixture_call(&snapshot, @intCast(window + 1), "agent-a", window * 64);
        hot_calls[window] = fixture_call(&snapshot, @intCast(window + 5), "agent-b", window * 64);
    }
    var cold = try cached_executor.execute(alloc, &cache, &snapshot, &cold_calls, batch_limits);
    defer cold.deinit(alloc);
    var hot = try cached_executor.execute(alloc, &cache, &snapshot, &hot_calls, batch_limits);
    defer hot.deinit(alloc);
    var rejected_calls = [_]contracts.LogicalCall{
        fixture_call(&snapshot, 9, "denied-agent", 0),
        fixture_call(&snapshot, 10, "stale-agent", 0),
        fixture_call(&snapshot, 11, "mismatched-agent", 0),
    };
    rejected_calls[0].admission = .denied;
    rejected_calls[1].admission.admitted.current_authority.generation += 1;
    rejected_calls[2].admission.admitted.binding.agent_id = "other-agent";
    var blocked = try cached_executor.execute(alloc, &cache, &snapshot, &rejected_calls, batch_limits);
    defer blocked.deinit(alloc);
    try validate_batches(&snapshot, cold, hot, blocked);

    const batches = [_]BatchReport{
        try batch_report(report_alloc, "cold-agent-a", cold),
        try batch_report(report_alloc, "completed-values-agent-b", hot),
        try batch_report(report_alloc, "rejected-consumers", blocked),
    };
    const report = .{
        .experimental_scope = "M2 synchronous owned completed-value cache; exact fresh fixture admissions; no production registry or performance claim",
        .immutable_input_sha256 = @as([]const u8, &snapshot.input_hash_hex),
        .immutable_input_bytes = snapshot.bytes.len,
        .fixture_verified = true,
        .logical_call_count = cold.results.len + hot.results.len + blocked.results.len,
        .limits = limits,
        .batch_limits = batch_limits,
        .cache = cache.stats(),
        .retained_accounting = "allocated entry table plus owned key strings and outputs; allocator bookkeeping and caller-owned output copies excluded",
        .batches = &batches,
    };
    var writer: std.Io.Writer.Allocating = .init(report_alloc);
    defer writer.deinit();
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer.writer);
    try writer.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(init.io, writer.written());
}

fn fixture_call(snapshot: *const executor.Snapshot, id: u64, agent_id: []const u8, offset: usize) contracts.LogicalCall {
    const request: contracts.CallBinding = .{
        .id = id,
        .agent_id = agent_id,
        .principal_domain = "fixture-operator",
        .task_id = "cache-fixture-task",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = snapshot.identity(),
        .args = .{ .path = snapshot.path, .window = .{ .offset = offset, .length = 64 }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "fixture-read", .epoch = 1, .generation = 1 },
    };
    return .{ .request = request, .admission = .{ .admitted = .{ .binding = request, .current_authority = request.authority, .immutable_snapshot = request.snapshot } } };
}

const CallReport = struct {
    logical_id: u64,
    agent_id: []const u8,
    principal_domain: []const u8,
    task_id: []const u8,
    admission_status: []const u8,
    status: []const u8,
    source: []const u8,
    cache_hit: bool,
    cache_miss: bool,
    backing_reads: usize,
    output_bytes: usize,
    output_sha256: []const u8,
    output_hex: []const u8,
};

const BatchReport = struct {
    name: []const u8,
    logical_calls: usize,
    cache_hits: usize,
    cache_misses: usize,
    backing_reads: usize,
    receipts: []CallReport,
};

fn batch_report(alloc: std.mem.Allocator, name: []const u8, execution: cached_executor.Execution) !BatchReport {
    const receipts = try alloc.alloc(CallReport, execution.results.len);
    for (execution.results, 0..) |result, index| {
        const receipt = result.receipt;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(receipt.output, &hash, .{});
        receipts[index] = .{
            .logical_id = receipt.request.id,
            .agent_id = receipt.request.agent_id,
            .principal_domain = receipt.request.principal_domain,
            .task_id = receipt.request.task_id,
            .admission_status = @tagName(receipt.admission_status),
            .status = @tagName(receipt.status),
            .source = @tagName(result.source),
            .cache_hit = result.cache_hit,
            .cache_miss = result.cache_miss,
            .backing_reads = result.backing_reads,
            .output_bytes = receipt.output.len,
            .output_sha256 = try hex_owned(alloc, &hash),
            .output_hex = try hex_owned(alloc, receipt.output),
        };
    }
    return .{ .name = name, .logical_calls = execution.results.len, .cache_hits = execution.cache_hits, .cache_misses = execution.cache_misses, .backing_reads = execution.backing_reads, .receipts = receipts };
}

fn hex_owned(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex = try alloc.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 15];
    }
    return hex;
}

fn validate_batches(snapshot: *const executor.Snapshot, cold: cached_executor.Execution, hot: cached_executor.Execution, blocked: cached_executor.Execution) !void {
    if (cold.results.len != 4 or hot.results.len != 4 or blocked.results.len != 3) return error.FixtureReceiptCountMismatch;
    if (cold.cache_hits != 0 or cold.cache_misses != 4 or cold.backing_reads != 4 or hot.cache_hits != 4 or hot.cache_misses != 0 or hot.backing_reads != 0)
        return error.FixtureProvenanceMismatch;
    for (cold.results, hot.results, 0..) |first, second, index| {
        const expected = snapshot.bytes[index * 64 ..][0..64];
        if (first.receipt.request.id != index + 1 or second.receipt.request.id != index + 5 or
            !std.mem.eql(u8, first.receipt.request.agent_id, "agent-a") or !std.mem.eql(u8, second.receipt.request.agent_id, "agent-b")) return error.FixtureIdentityMismatch;
        if (first.receipt.admission_status != .admitted or second.receipt.admission_status != .admitted or first.receipt.status != .success or second.receipt.status != .success or
            first.source != .backing or second.source != .cache or !std.mem.eql(u8, first.receipt.output, expected) or !std.mem.eql(u8, second.receipt.output, expected)) return error.FixtureOutputMismatch;
    }
    const statuses = [_]contracts.AdmissionStatus{ .denied, .stale_authority, .binding_mismatch };
    for (blocked.results, statuses, 0..) |result, expected, index| {
        if (result.receipt.request.id != index + 9 or result.receipt.admission_status != expected or result.receipt.status != .admission_rejected or
            result.source != .rejected or result.receipt.output.len != 0 or result.cache_hit or result.cache_miss or result.backing_reads != 0) return error.FixtureRejectedCallExecuted;
    }
}

test "batch verification rejects a degenerate empty execution" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    const empty: cached_executor.Execution = .{ .results = &.{}, .cache_hits = 0, .cache_misses = 0, .backing_reads = 0 };
    try std.testing.expectError(error.FixtureReceiptCountMismatch, validate_batches(&snapshot, empty, empty, empty));
}

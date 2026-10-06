const std = @import("std");
const contracts = @import("contracts.zig");
const optimizer = @import("optimizer.zig");
const executor = @import("executor.zig");

pub const Limits = struct { max_entries: usize, max_bytes: usize };
pub const Source = enum { cache, backing, rejected };

// Output is caller-owned. Request strings remain borrowed, alive, and unchanged.
// Destroy this result with the allocator supplied to Cache.read.
pub const ReadResult = struct {
    receipt: contracts.Receipt,
    source: Source,
    cache_hit: bool,
    cache_miss: bool,
    backing_reads: usize,

    pub fn deinit(self: *ReadResult, alloc: std.mem.Allocator) void {
        alloc.free(self.receipt.output);
        self.* = undefined;
    }
};

pub const Stats = struct {
    entries: usize,
    retained_bytes: usize,
    metadata_bytes: usize,
    hits: usize,
    misses: usize,
    backing_reads: usize,
    evictions: usize,
    not_retained: usize,
    rejected: usize,
};

const Entry = struct {
    key: contracts.CallBinding,
    storage: []u8,
    output: []const u8,
};

// Test allocator observing only allocations made by the cache itself.
const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc_fn, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free_fn } };
    }

    fn alloc_fn(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const memory = self.backing.rawAlloc(length, alignment, return_address) orelse return null;
        self.live_bytes += length;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return memory;
    }

    fn free_fn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.live_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, return_address);
    }
};

// Single-owner synchronous fixture cache. All methods use the same allocator.
// Retained bytes charge the allocated Entry table, owned key strings, and output.
// Allocator bookkeeping and the caller's Cache value are outside this nominal limit.
// Eviction is FIFO; hits do not change insertion order. There is no public insertion API.
pub const Cache = struct {
    limits: Limits,
    table: []Entry,
    state: Stats,

    pub fn init(alloc: std.mem.Allocator, limits: Limits) (std.mem.Allocator.Error || error{TooManyEntries})!Cache {
        if (limits.max_entries > 1024) return error.TooManyEntries;
        const capacity = @min(limits.max_entries, limits.max_bytes / @sizeOf(Entry));
        const table = try alloc.alloc(Entry, capacity);
        const metadata_bytes = capacity * @sizeOf(Entry);
        return .{
            .limits = limits,
            .table = table,
            .state = .{ .entries = 0, .retained_bytes = metadata_bytes, .metadata_bytes = metadata_bytes, .hits = 0, .misses = 0, .backing_reads = 0, .evictions = 0, .not_retained = 0, .rejected = 0 },
        };
    }

    pub fn deinit(self: *Cache, alloc: std.mem.Allocator) void {
        for (self.table[0..self.state.entries]) |entry| alloc.free(entry.storage);
        alloc.free(self.table);
        self.* = undefined;
    }

    pub fn stats(self: *const Cache) Stats {
        return self.state;
    }

    // Every lookup revalidates exact fixture admission and the supplied capture.
    // Only the existing registered executor can produce values retained by this cache.
    pub fn read(self: *Cache, alloc: std.mem.Allocator, snapshot: *const executor.Snapshot, call: contracts.LogicalCall) !ReadResult {
        var admission = try optimizer.build_plan(alloc, &.{call}, .disabled);
        defer admission.deinit(alloc);
        const admission_status = admission.logical_calls[0].status;
        if (admission_status != .admitted) {
            self.state.rejected += 1;
            return rejected(call.request, admission_status, .admission_rejected);
        }

        // Empty execution checks the actual captured hash without any backing read.
        var capture_check = try executor.execute(alloc, snapshot, &.{}, .disabled);
        defer capture_check.deinit(alloc);
        if (unsupported_status(snapshot, call.request)) |status| {
            self.state.rejected += 1;
            return rejected(call.request, .admitted, status);
        }

        for (self.table[0..self.state.entries]) |entry| {
            if (same_key(entry.key, call.request)) {
                const output = try alloc.dupe(u8, entry.output);
                self.state.hits += 1;
                return .{
                    .receipt = .{ .request = call.request, .admission_status = .admitted, .physical_group = null, .status = .success, .output = output },
                    .source = .cache,
                    .cache_hit = true,
                    .cache_miss = false,
                    .backing_reads = 0,
                };
            }
        }

        var backing = try executor.execute(alloc, snapshot, &.{call}, .disabled);
        defer backing.deinit(alloc);
        self.state.misses += 1;
        self.state.backing_reads += backing.physical_read_count;
        const receipt = backing.receipts[0];
        const output = try alloc.dupe(u8, receipt.output);
        errdefer alloc.free(output);
        // Retention is optional once a trusted caller-owned result exists.
        if (receipt.status == .success) self.retain(alloc, receipt.request, receipt.output) catch {
            self.state.not_retained += 1;
        };
        var owned_receipt = receipt;
        owned_receipt.output = output;
        // Batch-local group indices are not reused across independent Cache.read calls.
        owned_receipt.physical_group = null;
        return .{ .receipt = owned_receipt, .source = .backing, .cache_hit = false, .cache_miss = true, .backing_reads = backing.physical_read_count };
    }

    fn retain(self: *Cache, alloc: std.mem.Allocator, request: contracts.CallBinding, output: []const u8) !void {
        const storage_bytes = key_storage_bytes(request, output.len) orelse {
            self.state.not_retained += 1;
            return;
        };
        if (self.table.len == 0 or storage_bytes > self.limits.max_bytes - self.state.metadata_bytes) {
            self.state.not_retained += 1;
            return;
        }
        // Evict before allocation so even pending cache storage fits the nominal bound.
        while (self.state.entries == self.table.len or storage_bytes > self.limits.max_bytes - self.state.retained_bytes) self.evict_oldest(alloc);
        const storage = try alloc.alloc(u8, storage_bytes);
        errdefer alloc.free(storage);
        var remaining = storage;
        var key = request;
        key.id = 0;
        key.agent_id = "";
        key.principal_domain = copy_string(&remaining, request.principal_domain);
        key.task_id = copy_string(&remaining, request.task_id);
        key.tool_id = copy_string(&remaining, request.tool_id);
        key.snapshot = .{
            .id = copy_string(&remaining, request.snapshot.?.id),
            .version = copy_string(&remaining, request.snapshot.?.version),
        };
        key.args.path = copy_string(&remaining, request.args.path);
        key.args.options = copy_string(&remaining, request.args.options);
        key.result.schema_id = copy_string(&remaining, request.result.schema_id);
        key.authority.partition = copy_string(&remaining, request.authority.partition);
        const stored_output = copy_string(&remaining, output);
        std.debug.assert(remaining.len == 0);
        self.table[self.state.entries] = .{ .key = key, .storage = storage, .output = stored_output };
        self.state.entries += 1;
        self.state.retained_bytes += storage_bytes;
    }

    fn evict_oldest(self: *Cache, alloc: std.mem.Allocator) void {
        std.debug.assert(self.state.entries > 0);
        const first = self.table[0];
        self.state.retained_bytes -= first.storage.len;
        alloc.free(first.storage);
        self.state.entries -= 1;
        std.mem.copyForwards(Entry, self.table[0..self.state.entries], self.table[1..][0..self.state.entries]);
        self.state.evictions += 1;
    }
};

fn rejected(request: contracts.CallBinding, admission_status: contracts.AdmissionStatus, status: contracts.ReceiptStatus) ReadResult {
    return .{
        .receipt = .{ .request = request, .admission_status = admission_status, .physical_group = null, .status = status, .output = "" },
        .source = .rejected,
        .cache_hit = false,
        .cache_miss = false,
        .backing_reads = 0,
    };
}

fn unsupported_status(snapshot: *const executor.Snapshot, request: contracts.CallBinding) ?contracts.ReceiptStatus {
    if (request.effect != .snapshot_read or !equal(request.tool_id, "embedded-content-reader") or
        !equal(request.args.options, "raw") or !equal(request.result.schema_id, "content") or
        request.result.version != 1 or request.result.encoding != .bytes) return .unsupported_effect;
    const identity = snapshot.identity();
    const requested = request.snapshot orelse return .snapshot_mismatch;
    if (!equal(request.args.path, snapshot.path) or !equal(requested.id, identity.id) or !equal(requested.version, identity.version)) return .snapshot_mismatch;
    if (request.args.window.offset > snapshot.bytes.len or request.args.window.length > snapshot.bytes.len - request.args.window.offset) return .invalid_window;
    if (request.args.window.length > request.output_budget) return .output_budget_exceeded;
    return null;
}

fn same_key(a: contracts.CallBinding, b: contracts.CallBinding) bool {
    return equal(a.principal_domain, b.principal_domain) and equal(a.task_id, b.task_id) and
        equal(a.tool_id, b.tool_id) and a.effect == b.effect and
        equal(a.snapshot.?.id, b.snapshot.?.id) and equal(a.snapshot.?.version, b.snapshot.?.version) and
        equal(a.args.path, b.args.path) and equal(a.args.options, b.args.options) and
        a.args.window.offset == b.args.window.offset and a.args.window.length == b.args.window.length and
        equal(a.result.schema_id, b.result.schema_id) and a.result.version == b.result.version and a.result.encoding == b.result.encoding and
        a.output_budget == b.output_budget and equal(a.authority.partition, b.authority.partition) and
        a.authority.epoch == b.authority.epoch and a.authority.generation == b.authority.generation;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn key_storage_bytes(request: contracts.CallBinding, output_bytes: usize) ?usize {
    const snapshot = request.snapshot orelse return null;
    var total = output_bytes;
    for ([_][]const u8{ request.principal_domain, request.task_id, request.tool_id, snapshot.id, snapshot.version, request.args.path, request.args.options, request.result.schema_id, request.authority.partition }) |value| {
        total = std.math.add(usize, total, value.len) catch return null;
    }
    return total;
}

fn copy_string(remaining: *[]u8, input: []const u8) []const u8 {
    const result = remaining.*[0..input.len];
    @memcpy(result, input);
    remaining.* = remaining.*[input.len..];
    return result;
}

fn fixture(snapshot: *const executor.Snapshot, id: u64, agent: []const u8, offset: usize) contracts.LogicalCall {
    const request: contracts.CallBinding = .{
        .id = id,
        .agent_id = agent,
        .principal_domain = "operator",
        .task_id = "task",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = snapshot.identity(),
        .args = .{ .path = snapshot.path, .window = .{ .offset = offset, .length = 3 }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "fixture-read", .epoch = 1, .generation = 1 },
    };
    return admit(request);
}

fn admit(request: contracts.CallBinding) contracts.LogicalCall {
    return .{ .request = request, .admission = .{ .admitted = .{ .binding = request, .current_authority = request.authority, .immutable_snapshot = request.snapshot } } };
}

test "separately admitted agents receive independent receipts and copied completed values" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdefgh");
    defer snapshot.deinit(std.testing.allocator);
    var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 4, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var first = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 1, "agent-a", 0));
    defer first.deinit(std.testing.allocator);
    var second = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 2, "agent-b", 0));
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.backing, first.source);
    try std.testing.expectEqual(Source.cache, second.source);
    try std.testing.expectEqual(@as(u64, 2), second.receipt.request.id);
    try std.testing.expectEqualStrings("agent-b", second.receipt.request.agent_id);
    try std.testing.expectEqualStrings("abc", second.receipt.output);
    try std.testing.expect(first.receipt.output.ptr != second.receipt.output.ptr);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().backing_reads);
}

test "every key partition isolates reuse and unsupported contracts are never retained" {
    inline for (0..17) |change| {
        var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdefgh");
        defer snapshot.deinit(std.testing.allocator);
        var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 4, .max_bytes = 8192 });
        defer cache.deinit(std.testing.allocator);
        var first = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 1, "a", 0));
        defer first.deinit(std.testing.allocator);
        var request = fixture(&snapshot, 2, "b", 0).request;
        switch (change) {
            0 => request.principal_domain = "other-domain",
            1 => request.task_id = "other-task",
            2 => request.snapshot.?.id = "other-snapshot",
            3 => request.snapshot.?.version = "other-version",
            4 => request.tool_id = "other-tool",
            5 => request.args.path = "other-path",
            6 => request.args.options = "other-options",
            7 => request.args.window.offset = 1,
            8 => request.args.window.length = 2,
            9 => request.result.schema_id = "other-schema",
            10 => request.result.version = 2,
            11 => request.result.encoding = .utf8,
            12 => request.output_budget = 63,
            13 => request.authority.partition = "other-authority",
            14 => request.authority.epoch = 2,
            15 => request.authority.generation = 2,
            16 => request.effect = .opaque_exec,
            else => unreachable,
        }
        var changed = try cache.read(std.testing.allocator, &snapshot, admit(request));
        defer changed.deinit(std.testing.allocator);
        try std.testing.expect(!changed.cache_hit);
        try std.testing.expectEqual(@as(usize, 0), cache.stats().hits);
        if (changed.receipt.status != .success) try std.testing.expectEqual(@as(usize, 1), cache.stats().entries);
    }
}

test "denied stale binding mismatched and uncertified fresh calls cannot see populated values" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdefgh");
    defer snapshot.deinit(std.testing.allocator);
    var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 2, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var first = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 1, "a", 0));
    defer first.deinit(std.testing.allocator);
    inline for (0..4) |change| {
        var call = fixture(&snapshot, 2, "b", 0);
        switch (change) {
            0 => call.admission = .denied,
            1 => call.admission.admitted.current_authority.generation += 1,
            2 => call.admission.admitted.binding.agent_id = "other-agent",
            3 => call.admission.admitted.immutable_snapshot = null,
            else => unreachable,
        }
        var result = try cache.read(std.testing.allocator, &snapshot, call);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Source.rejected, result.source);
        try std.testing.expectEqualStrings("", result.receipt.output);
        try std.testing.expectEqual(@as(usize, 0), result.backing_reads);
        try std.testing.expect(!result.cache_hit and !result.cache_miss);
    }
    try std.testing.expectEqual(@as(usize, 0), cache.stats().hits);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().backing_reads);
}

test "FIFO eviction preserves caller owned output and hits do not refresh order" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdefghij");
    defer snapshot.deinit(std.testing.allocator);
    var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 2, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var a = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 1, "a", 0));
    defer a.deinit(std.testing.allocator);
    var b = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 2, "a", 3));
    defer b.deinit(std.testing.allocator);
    var hit = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 3, "b", 0));
    defer hit.deinit(std.testing.allocator);
    var c = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 4, "a", 6));
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().evictions);
    try std.testing.expectEqualStrings("abc", hit.receipt.output);
    var oldest = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 5, "c", 0));
    defer oldest.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.backing, oldest.source);
    try std.testing.expectEqualStrings("abc", a.receipt.output);
}

test "zero tiny and metadata-only budgets disable retention while returning trusted values" {
    for ([_]Limits{ .{ .max_entries = 0, .max_bytes = 8192 }, .{ .max_entries = 4, .max_bytes = 0 }, .{ .max_entries = 4, .max_bytes = 1 }, .{ .max_entries = 1, .max_bytes = @sizeOf(Entry) } }) |limits| {
        var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
        defer snapshot.deinit(std.testing.allocator);
        var cache = try Cache.init(std.testing.allocator, limits);
        defer cache.deinit(std.testing.allocator);
        var first = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 1, "a", 0));
        defer first.deinit(std.testing.allocator);
        var second = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 2, "b", 0));
        defer second.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("abc", second.receipt.output);
        try std.testing.expectEqual(Source.backing, second.source);
        try std.testing.expectEqual(@as(usize, 0), cache.stats().entries);
        try std.testing.expect(cache.stats().retained_bytes <= limits.max_bytes);
    }
    try std.testing.expectError(error.TooManyEntries, Cache.init(std.testing.allocator, .{ .max_entries = 1025, .max_bytes = std.math.maxInt(usize) }));
}

test "byte accounting evicts before reaching the entry limit and rejects overflow totals" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    const call = fixture(&snapshot, 1, "a", 0);
    const payload_bytes = key_storage_bytes(call.request, 3).?;
    const limits: Limits = .{ .max_entries = 2, .max_bytes = 2 * @sizeOf(Entry) + payload_bytes };
    var cache = try Cache.init(std.testing.allocator, limits);
    defer cache.deinit(std.testing.allocator);
    var a = try cache.read(std.testing.allocator, &snapshot, call);
    defer a.deinit(std.testing.allocator);
    var b = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 2, "a", 3));
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().entries);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().evictions);
    try std.testing.expectEqual(limits.max_bytes, cache.stats().retained_bytes);
    try std.testing.expectEqualStrings("abc", a.receipt.output);
    try std.testing.expectEqual(@as(?usize, null), key_storage_bytes(call.request, std.math.maxInt(usize)));
}

test "optional retention allocation failure preserves successful trusted output" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    var observed_retention_failure = false;
    for (0..32) |allocation_budget| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const alloc = failing.allocator();
        const limits: Limits = .{ .max_entries = 1, .max_bytes = 8192 };
        var cache = try Cache.init(alloc, limits);
        defer cache.deinit(alloc);
        failing.fail_index = failing.alloc_index + allocation_budget;
        var result = cache.read(alloc, &snapshot, fixture(&snapshot, 1, "a", 0)) catch |err| {
            if (err == error.OutOfMemory) continue;
            return err;
        };
        defer result.deinit(alloc);
        if (failing.has_induced_failure) {
            try std.testing.expectEqual(contracts.ReceiptStatus.success, result.receipt.status);
            try std.testing.expectEqualStrings("abc", result.receipt.output);
            try std.testing.expectEqual(Source.backing, result.source);
            try std.testing.expectEqual(@as(usize, 1), result.backing_reads);
            try std.testing.expectEqual(@as(usize, 1), cache.stats().backing_reads);
            try std.testing.expectEqual(@as(usize, 1), cache.stats().not_retained);
            try std.testing.expectEqual(@as(usize, 0), cache.stats().entries);
            try std.testing.expect(cache.stats().retained_bytes <= limits.max_bytes);
            try std.testing.expectEqual(cache.stats().retained_bytes + result.receipt.output.len, failing.allocated_bytes - failing.freed_bytes);
            observed_retention_failure = true;
            break;
        }
    }
    try std.testing.expect(observed_retention_failure);
}

test "byte-driven replacement never allocates cache storage above the nominal limit" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    const first_call = fixture(&snapshot, 1, "a", 0);
    const second_call = fixture(&snapshot, 2, "b", 3);
    var first = try executor.execute(std.testing.allocator, &snapshot, &.{first_call}, .disabled);
    defer first.deinit(std.testing.allocator);
    var second = try executor.execute(std.testing.allocator, &snapshot, &.{second_call}, .disabled);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(contracts.ReceiptStatus.success, first.receipts[0].status);
    try std.testing.expectEqual(contracts.ReceiptStatus.success, second.receipts[0].status);
    const payload_bytes = key_storage_bytes(first_call.request, first.receipts[0].output.len).?;
    const limits: Limits = .{ .max_entries = 2, .max_bytes = 2 * @sizeOf(Entry) + payload_bytes };
    var tracking: TrackingAllocator = .{ .backing = std.testing.allocator };
    const alloc = tracking.allocator();
    var cache = try Cache.init(alloc, limits);
    defer cache.deinit(alloc);
    // Direct private insertion isolates table/key/output allocation peaks from
    // temporary admission work and caller-owned output copies. Values came from
    // the registered reader immediately above.
    try cache.retain(alloc, first.receipts[0].request, first.receipts[0].output);
    try cache.retain(alloc, second.receipts[0].request, second.receipts[0].output);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().entries);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().evictions);
    try std.testing.expectEqual(limits.max_bytes, tracking.peak_bytes);
    try std.testing.expectEqual(cache.stats().retained_bytes, tracking.live_bytes);
    try std.testing.expect(tracking.peak_bytes <= limits.max_bytes);
}

test "optional retention failure after byte-driven eviction still returns trusted output" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    const first_call = fixture(&snapshot, 1, "a", 0);
    const payload_bytes = key_storage_bytes(first_call.request, 3).?;
    const limits: Limits = .{ .max_entries = 2, .max_bytes = 2 * @sizeOf(Entry) + payload_bytes };
    var observed_failure_after_eviction = false;
    for (0..32) |allocation_budget| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const alloc = failing.allocator();
        var cache = try Cache.init(alloc, limits);
        defer cache.deinit(alloc);
        var first = try cache.read(alloc, &snapshot, first_call);
        first.deinit(alloc);
        failing.fail_index = failing.alloc_index + allocation_budget;
        var second = cache.read(alloc, &snapshot, fixture(&snapshot, 2, "b", 3)) catch |err| {
            if (err == error.OutOfMemory) continue;
            return err;
        };
        defer second.deinit(alloc);
        if (failing.has_induced_failure) {
            try std.testing.expectEqual(contracts.ReceiptStatus.success, second.receipt.status);
            try std.testing.expectEqualStrings("def", second.receipt.output);
            try std.testing.expectEqual(Source.backing, second.source);
            try std.testing.expectEqual(@as(usize, 1), cache.stats().evictions);
            try std.testing.expectEqual(@as(usize, 0), cache.stats().entries);
            try std.testing.expectEqual(@as(usize, 1), cache.stats().not_retained);
            try std.testing.expectEqual(@as(usize, 2), cache.stats().backing_reads);
            try std.testing.expect(cache.stats().retained_bytes <= limits.max_bytes);
            try std.testing.expectEqual(cache.stats().retained_bytes + second.receipt.output.len, failing.allocated_bytes - failing.freed_bytes);
            observed_failure_after_eviction = true;
            break;
        }
    }
    try std.testing.expect(observed_failure_after_eviction);
}

test "owned keys survive source mutation and accounting includes key and metadata bytes" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 1, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var task = [_]u8{ 't', 'a', 's', 'k' };
    var request = fixture(&snapshot, 1, "a", 0).request;
    request.task_id = &task;
    var first = try cache.read(std.testing.allocator, &snapshot, admit(request));
    first.deinit(std.testing.allocator);
    task[0] = 'X';
    var second = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 2, "b", 0));
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.cache, second.source);
    const nominal = @sizeOf(Entry) + key_storage_bytes(fixture(&snapshot, 3, "c", 0).request, 3).?;
    try std.testing.expectEqual(nominal, cache.stats().retained_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(Entry)), cache.stats().metadata_bytes);
}

test "actual distinct captured content and paths require independent backing values" {
    var first_snapshot = try executor.Snapshot.init(std.testing.allocator, "file-a", "abcdef");
    defer first_snapshot.deinit(std.testing.allocator);
    var changed_content = try executor.Snapshot.init(std.testing.allocator, "file-a", "XYZdef");
    defer changed_content.deinit(std.testing.allocator);
    var changed_path = try executor.Snapshot.init(std.testing.allocator, "file-b", "abcdef");
    defer changed_path.deinit(std.testing.allocator);
    var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 4, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var a = try cache.read(std.testing.allocator, &first_snapshot, fixture(&first_snapshot, 1, "a", 0));
    defer a.deinit(std.testing.allocator);
    var b = try cache.read(std.testing.allocator, &changed_content, fixture(&changed_content, 2, "b", 0));
    defer b.deinit(std.testing.allocator);
    var c = try cache.read(std.testing.allocator, &changed_path, fixture(&changed_path, 3, "c", 0));
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.backing, b.source);
    try std.testing.expectEqual(Source.backing, c.source);
    try std.testing.expectEqualStrings("XYZ", b.receipt.output);
    try std.testing.expectEqualStrings("abc", c.receipt.output);
    try std.testing.expectEqual(@as(usize, 3), cache.stats().backing_reads);
}

test "failed windows budgets and tampered captures never return or retain cached data" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    var cache = try Cache.init(std.testing.allocator, .{ .max_entries = 2, .max_bytes = 8192 });
    defer cache.deinit(std.testing.allocator);
    var first = try cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 1, "a", 0));
    defer first.deinit(std.testing.allocator);
    var invalid = fixture(&snapshot, 2, "b", 0).request;
    invalid.args.window.length = std.math.maxInt(usize);
    var failed = try cache.read(std.testing.allocator, &snapshot, admit(invalid));
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(contracts.ReceiptStatus.invalid_window, failed.receipt.status);
    invalid = fixture(&snapshot, 3, "b", 0).request;
    invalid.output_budget = 1;
    var budget = try cache.read(std.testing.allocator, &snapshot, admit(invalid));
    defer budget.deinit(std.testing.allocator);
    try std.testing.expectEqual(contracts.ReceiptStatus.output_budget_exceeded, budget.receipt.status);
    try std.testing.expectEqual(@as(usize, 1), cache.stats().entries);
    @constCast(snapshot.bytes)[0] = 'X';
    try std.testing.expectError(error.SnapshotTampered, cache.read(std.testing.allocator, &snapshot, fixture(&snapshot, 4, "b", 0)));
    try std.testing.expectEqual(@as(usize, 0), cache.stats().hits);
}

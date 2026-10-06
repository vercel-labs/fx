const std = @import("std");
const contracts = @import("contracts.zig");
const optimizer = @import("optimizer.zig");

const max_snapshot_bytes = 1024 * 1024;

// Owns captured bytes and path. Keep this value at one address and leave all
// fields unchanged after identity() is used. Outputs borrow this frozen storage.
pub const Snapshot = struct {
    path: []const u8,
    bytes: []const u8,
    input_hash: [32]u8,
    input_hash_hex: [64]u8,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8) (std.mem.Allocator.Error || error{SnapshotTooLarge})!Snapshot {
        if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
        const captured_path = try alloc.dupe(u8, path);
        errdefer alloc.free(captured_path);
        const captured_bytes = try alloc.dupe(u8, bytes);
        errdefer alloc.free(captured_bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(captured_bytes, &hash, .{});
        return .{
            .path = captured_path,
            .bytes = captured_bytes,
            .input_hash = hash,
            .input_hash_hex = hash_hex(hash),
        };
    }

    pub fn identity(self: *const Snapshot) contracts.SnapshotIdentity {
        return .{ .id = "embedded-fixture", .version = &self.input_hash_hex };
    }

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

// Owns plan and receipt arrays; receipt outputs borrow the Snapshot. Destroy this
// before the Snapshot and keep call strings frozen through receipt consumption.
pub const Execution = struct {
    plan: contracts.Plan,
    receipts: []contracts.Receipt,
    physical_read_count: usize,

    pub fn deinit(self: *Execution, alloc: std.mem.Allocator) void {
        self.plan.deinit(alloc);
        alloc.free(self.receipts);
        self.* = undefined;
    }
};

// Builds its own plan and dispatches only the fixed embedded content reader.
// Host admissions are fixture contracts; production permission checks are absent.
pub fn execute(
    alloc: std.mem.Allocator,
    snapshot: *const Snapshot,
    calls: []const contracts.LogicalCall,
    mode: contracts.Mode,
) (std.mem.Allocator.Error || error{ DuplicateLogicalId, TooManyCalls, SnapshotTampered })!Execution {
    var current_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(snapshot.bytes, &current_hash, .{});
    const current_hash_hex = hash_hex(current_hash);
    if (!std.mem.eql(u8, &current_hash, &snapshot.input_hash) or
        !std.mem.eql(u8, &current_hash_hex, &snapshot.input_hash_hex)) return error.SnapshotTampered;

    var plan = try optimizer.build_plan(alloc, calls, mode);
    errdefer plan.deinit(alloc);
    const receipts = try alloc.alloc(contracts.Receipt, plan.logical_calls.len);
    errdefer alloc.free(receipts);
    for (plan.logical_calls, 0..) |planned, index| {
        receipts[index] = .{
            .request = planned.call.request,
            .admission_status = planned.status,
            .physical_group = planned.physical_group,
            .status = .admission_rejected,
            .output = "",
        };
    }

    var physical_read_count: usize = 0;
    for (plan.groups) |group| {
        const request = plan.logical_calls[group.representative].call.request;
        const result = read_snapshot(snapshot, request);
        if (result.status == .success) physical_read_count += 1;
        for (plan.logical_calls, 0..) |planned, index| {
            if (planned.physical_group == group.id) {
                receipts[index].status = result.status;
                receipts[index].output = result.output;
            }
        }
    }
    return .{ .plan = plan, .receipts = receipts, .physical_read_count = physical_read_count };
}

const ReadResult = struct {
    status: contracts.ReceiptStatus,
    output: []const u8 = "",
};

fn read_snapshot(snapshot: *const Snapshot, request: contracts.CallBinding) ReadResult {
    if (request.effect != .snapshot_read or
        !std.mem.eql(u8, request.tool_id, "embedded-content-reader") or
        !std.mem.eql(u8, request.args.options, "raw") or
        !std.mem.eql(u8, request.result.schema_id, "content") or
        request.result.version != 1 or request.result.encoding != .bytes)
        return .{ .status = .unsupported_effect };

    const requested_snapshot = request.snapshot orelse return .{ .status = .snapshot_mismatch };
    const captured_identity = snapshot.identity();
    if (!std.mem.eql(u8, request.args.path, snapshot.path) or
        !std.mem.eql(u8, requested_snapshot.id, captured_identity.id) or
        !std.mem.eql(u8, requested_snapshot.version, captured_identity.version))
        return .{ .status = .snapshot_mismatch };

    const window = request.args.window;
    if (window.offset > snapshot.bytes.len) return .{ .status = .invalid_window };
    if (window.length > snapshot.bytes.len - window.offset) return .{ .status = .invalid_window };
    if (window.length > request.output_budget) return .{ .status = .output_budget_exceeded };
    return .{ .status = .success, .output = snapshot.bytes[window.offset..][0..window.length] };
}

fn hash_hex(hash: [32]u8) [64]u8 {
    const alphabet = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (hash, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 15];
    }
    return hex;
}

fn fixture(snapshot: *const Snapshot, id: u64, agent_id: []const u8, offset: usize, length: usize) contracts.LogicalCall {
    const request: contracts.CallBinding = .{
        .id = id,
        .agent_id = agent_id,
        .principal_domain = "operator",
        .task_id = "fixture-task",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = snapshot.identity(),
        .args = .{ .path = snapshot.path, .window = .{ .offset = offset, .length = length }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "fixture-read", .epoch = 1, .generation = 1 },
    };
    return admit(request);
}

fn admit(request: contracts.CallBinding) contracts.LogicalCall {
    return .{
        .request = request,
        .admission = .{ .admitted = .{
            .binding = request,
            .current_authority = request.authority,
            .immutable_snapshot = request.snapshot,
        } },
    };
}

test "capture owns immutable content and path independent of mutable source buffers" {
    var source = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f' };
    var path = [_]u8{ 'f', 'i', 'l', 'e' };
    var snapshot = try Snapshot.init(std.testing.allocator, &path, &source);
    defer snapshot.deinit(std.testing.allocator);
    source[1] = 'X';
    path[0] = 'X';
    const call = fixture(&snapshot, 1, "agent-a", 1, 3);
    var result = try execute(std.testing.allocator, &snapshot, &.{call}, .enabled);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("file", snapshot.path);
    try std.testing.expectEqualStrings("bcd", result.receipts[0].output);
    try std.testing.expectEqual(@as(usize, 1), result.physical_read_count);
    try std.testing.expectEqual(@intFromPtr(snapshot.bytes.ptr + 1), @intFromPtr(result.receipts[0].output.ptr));
}

test "execution detects mutation of captured bytes before admitting calls" {
    var snapshot = try Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    const call = fixture(&snapshot, 1, "agent-a", 0, 3);
    @constCast(snapshot.bytes)[0] = 'X';
    try std.testing.expectError(error.SnapshotTampered, execute(std.testing.allocator, &snapshot, &.{call}, .enabled));
}

test "windows reject out of range offsets lengths and addition overflow without reading" {
    var snapshot = try Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    const windows = [_]contracts.Window{
        .{ .offset = 7, .length = 0 },
        .{ .offset = 5, .length = 2 },
        .{ .offset = 1, .length = std.math.maxInt(usize) },
        .{ .offset = std.math.maxInt(usize), .length = 2 },
    };
    for (windows) |window| {
        const call = fixture(&snapshot, 1, "agent-a", window.offset, window.length);
        var result = try execute(std.testing.allocator, &snapshot, &.{call}, .enabled);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(contracts.ReceiptStatus.invalid_window, result.receipts[0].status);
        try std.testing.expectEqual(@as(usize, 0), result.physical_read_count);
        try std.testing.expectEqualStrings("", result.receipts[0].output);
    }
}

test "unsupported effects tools options and result contracts reject before dispatch" {
    var snapshot = try Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    inline for (0..9) |change| {
        var request = fixture(&snapshot, 1, "agent-a", 0, 3).request;
        switch (change) {
            0 => request.effect = .mutable_read,
            1 => request.effect = .mutation,
            2 => request.effect = .external,
            3 => request.effect = .opaque_exec,
            4 => request.tool_id = "shell",
            5 => request.args.options = "normalize",
            6 => request.result.schema_id = "other",
            7 => request.result.version = 2,
            8 => request.result.encoding = .utf8,
            else => unreachable,
        }
        var result = try execute(std.testing.allocator, &snapshot, &.{admit(request)}, .enabled);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(contracts.ReceiptStatus.unsupported_effect, result.receipts[0].status);
        try std.testing.expectEqual(@as(usize, 0), result.physical_read_count);
    }
}

test "output budget rejects before content is read" {
    var snapshot = try Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    var request = fixture(&snapshot, 1, "agent-a", 0, 3).request;
    request.output_budget = 2;
    var result = try execute(std.testing.allocator, &snapshot, &.{admit(request)}, .enabled);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(contracts.ReceiptStatus.output_budget_exceeded, result.receipts[0].status);
    try std.testing.expectEqualStrings("", result.receipts[0].output);
    try std.testing.expectEqual(@as(usize, 0), result.physical_read_count);
}

test "snapshot labels and paths must match the captured content identity" {
    var snapshot = try Snapshot.init(std.testing.allocator, "file", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    inline for (0..3) |change| {
        var request = fixture(&snapshot, 1, "agent-a", 0, 3).request;
        switch (change) {
            0 => request.snapshot.?.id = "other",
            1 => request.snapshot.?.version = "unverified-label",
            2 => request.args.path = "other-file",
            else => unreachable,
        }
        var result = try execute(std.testing.allocator, &snapshot, &.{admit(request)}, .enabled);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(contracts.ReceiptStatus.snapshot_mismatch, result.receipts[0].status);
        try std.testing.expectEqual(@as(usize, 0), result.physical_read_count);
    }
}

test "enabled and disabled execution preserve every receipt including denied and stale" {
    var snapshot = try Snapshot.init(std.testing.allocator, "file", "abcdefgh");
    defer snapshot.deinit(std.testing.allocator);
    var calls = [_]contracts.LogicalCall{
        fixture(&snapshot, 1, "agent-a", 0, 4),
        fixture(&snapshot, 2, "agent-b", 0, 4),
        fixture(&snapshot, 3, "agent-a", 4, 4),
        fixture(&snapshot, 4, "agent-b", 4, 4),
        fixture(&snapshot, 5, "denied-agent", 0, 4),
        fixture(&snapshot, 6, "stale-agent", 0, 4),
    };
    calls[4].admission = .denied;
    calls[5].admission.admitted.current_authority.generation += 1;
    var disabled = try execute(std.testing.allocator, &snapshot, &calls, .disabled);
    defer disabled.deinit(std.testing.allocator);
    var enabled = try execute(std.testing.allocator, &snapshot, &calls, .enabled);
    defer enabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), disabled.physical_read_count);
    try std.testing.expectEqual(@as(usize, 2), enabled.physical_read_count);
    try std.testing.expectEqual(@as(usize, 6), enabled.receipts.len);
    for (disabled.receipts, enabled.receipts) |a, b| {
        try std.testing.expectEqual(a.request.id, b.request.id);
        try std.testing.expectEqualStrings(a.request.agent_id, b.request.agent_id);
        try std.testing.expectEqual(a.admission_status, b.admission_status);
        try std.testing.expectEqual(a.status, b.status);
        try std.testing.expectEqualStrings(a.output, b.output);
    }
    try std.testing.expectEqual(contracts.AdmissionStatus.denied, enabled.receipts[4].admission_status);
    try std.testing.expectEqual(contracts.AdmissionStatus.stale_authority, enabled.receipts[5].admission_status);
    try std.testing.expectEqualStrings("", enabled.receipts[4].output);
    try std.testing.expectEqualStrings("", enabled.receipts[5].output);
}
